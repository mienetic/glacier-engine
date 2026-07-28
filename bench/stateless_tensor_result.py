#!/usr/bin/env python3
"""Independent verifier for Glacier's stateless dense-tensor result wires.

This module is intentionally standard-library only.  It neither imports
Glacier nor derives constants from Zig sources, so it can detect drift in the
other implementation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn, Sequence


DEMO_SCHEMA = "glacier.dense-tensor-reranker/v1"

MAXIMUM_ITEM_COUNT = 4096
MAXIMUM_INPUT_FEATURES = 4096
RERANKER_MAX_BATCH_ITEMS = 64

BATCH_MAP_MAGIC = b"GSTBMAP1"
BATCH_MAP_ABI = 0x4753_5442_4D00_0001
BATCH_MAP_HEADER_BYTES = 32
BATCH_MAP_ITEM_BYTES = 8
BATCH_MAP_FOOTER_BYTES = 32
BATCH_MAP_DOMAIN = b"glacier-stateless-tensor-batch-map-v1\x00"

SCORE_POLICY_MAGIC = b"GSTPOL1\x00"
SCORE_POLICY_ABI = 0x4753_5450_4F00_0001
SCORE_POLICY_BYTES = 88
SCORE_POLICY_DOMAIN = b"glacier-stateless-tensor-score-policy-v1\x00"

RANKED_ELEMENT_BODY_BYTES = 32
RANKED_ELEMENT_BYTES = 64
RANKED_ELEMENT_DOMAIN = b"glacier-stateless-tensor-ranked-element-v1\x00"

NORMALIZATION_NONE = 1
SCORE_DESCENDING = 1
INPUT_ORDINAL_ASCENDING = 1

I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
U64_MAX = (1 << 64) - 1

DEMO_FIELDS = frozenset(
    {
        "schema",
        "batch_map_hex",
        "score_policy_hex",
        "ranked_result_hex",
        "weights_hex",
        "tensor_hex",
        "input_features",
        "source_mapping_sha256",
        "result_sha256",
        "output_sha256",
        "items",
        "verified",
    }
)
ITEM_FIELDS = frozenset({"item_id", "input_ordinal", "rank", "score"})


class OracleError(ValueError):
    """A wire or demo record violates the independently frozen contract."""


@dataclass(frozen=True)
class BatchMapV1:
    encoded: bytes
    item_ids: tuple[int, ...]
    batch_map_sha256: bytes

    @property
    def item_count(self) -> int:
        return len(self.item_ids)


@dataclass(frozen=True)
class ScorePolicyV1:
    encoded: bytes
    normalization: int
    order: int
    tie_break: int
    score_policy_sha256: bytes


@dataclass(frozen=True)
class RankedItemV1:
    item_id: int
    input_ordinal: int
    rank: int
    score: int

    def document(self) -> dict[str, int]:
        return {
            "item_id": self.item_id,
            "input_ordinal": self.input_ordinal,
            "rank": self.rank,
            "score": self.score,
        }


@dataclass(frozen=True)
class RankedResultV1:
    encoded: bytes
    items: tuple[RankedItemV1, ...]
    batch_map_sha256: bytes
    score_policy_sha256: bytes


@dataclass(frozen=True)
class VerifiedDemoV1:
    batch_map: BatchMapV1
    score_policy: ScorePolicyV1
    ranked_result: RankedResultV1
    weights: bytes
    tensor: bytes
    input_features: int
    source_mapping_sha256: bytes
    result_sha256: bytes
    output_sha256: bytes


def _reject(message: str) -> NoReturn:
    raise OracleError(message)


def _u64(encoded: bytes, offset: int) -> int:
    return int.from_bytes(encoded[offset : offset + 8], "little", signed=False)


def _i64(encoded: bytes, offset: int) -> int:
    return int.from_bytes(encoded[offset : offset + 8], "little", signed=True)


def _root(domain: bytes, payload: bytes) -> bytes:
    return hashlib.sha256(domain + payload).digest()


def decode_batch_map(encoded: bytes) -> BatchMapV1:
    """Decode and fully validate one canonical BatchMap V1."""

    encoded = _exact_bytes(encoded, "batch map")
    minimum = (
        BATCH_MAP_HEADER_BYTES
        + BATCH_MAP_ITEM_BYTES
        + BATCH_MAP_FOOTER_BYTES
    )
    if len(encoded) < minimum:
        _reject("batch map has invalid length")
    if encoded[:8] != BATCH_MAP_MAGIC:
        _reject("batch map has invalid magic")
    if _u64(encoded, 8) != BATCH_MAP_ABI:
        _reject("batch map has invalid ABI")
    if _u64(encoded, 16) != len(encoded):
        _reject("batch map declared length mismatch")

    item_count = _u64(encoded, 24)
    if item_count == 0 or item_count > MAXIMUM_ITEM_COUNT:
        _reject("batch map has invalid item count")
    expected_length = (
        BATCH_MAP_HEADER_BYTES
        + item_count * BATCH_MAP_ITEM_BYTES
        + BATCH_MAP_FOOTER_BYTES
    )
    if len(encoded) != expected_length:
        _reject("batch map item count does not match exact length")

    root_offset = len(encoded) - BATCH_MAP_FOOTER_BYTES
    expected_root = _root(BATCH_MAP_DOMAIN, encoded[:root_offset])
    if encoded[root_offset:] != expected_root:
        _reject("batch map root mismatch")

    item_ids = tuple(
        _u64(encoded, BATCH_MAP_HEADER_BYTES + index * BATCH_MAP_ITEM_BYTES)
        for index in range(item_count)
    )
    if any(item_id == 0 for item_id in item_ids):
        _reject("batch map contains zero item ID")
    if len(set(item_ids)) != len(item_ids):
        _reject("batch map contains duplicate item ID")
    return BatchMapV1(encoded, item_ids, expected_root)


def decode_score_policy(encoded: bytes) -> ScorePolicyV1:
    """Decode the sole canonical ScorePolicy V1."""

    encoded = _exact_bytes(encoded, "score policy")
    if len(encoded) != SCORE_POLICY_BYTES:
        _reject("score policy has invalid length")
    if encoded[:8] != SCORE_POLICY_MAGIC:
        _reject("score policy has invalid magic")
    if _u64(encoded, 8) != SCORE_POLICY_ABI:
        _reject("score policy has invalid ABI")
    if _u64(encoded, 16) != SCORE_POLICY_BYTES:
        _reject("score policy declared length mismatch")

    normalization = _u64(encoded, 24)
    order = _u64(encoded, 32)
    tie_break = _u64(encoded, 40)
    if _u64(encoded, 48) != 0:
        _reject("score policy reserved field is nonzero")
    if (
        normalization != NORMALIZATION_NONE
        or order != SCORE_DESCENDING
        or tie_break != INPUT_ORDINAL_ASCENDING
    ):
        _reject("score policy is not the canonical V1 policy")

    root_offset = SCORE_POLICY_BYTES - 32
    expected_root = _root(SCORE_POLICY_DOMAIN, encoded[:root_offset])
    if encoded[root_offset:] != expected_root:
        _reject("score policy root mismatch")
    return ScorePolicyV1(
        encoded,
        normalization,
        order,
        tie_break,
        expected_root,
    )


def decode_ranked_result(
    encoded: bytes,
    batch_map: bytes | BatchMapV1,
    score_policy: bytes | ScorePolicyV1,
) -> RankedResultV1:
    """Validate all element roots and the complete ranked permutation."""

    encoded = _exact_bytes(encoded, "ranked result")
    batch = (
        batch_map
        if isinstance(batch_map, BatchMapV1)
        else decode_batch_map(batch_map)
    )
    policy = (
        score_policy
        if isinstance(score_policy, ScorePolicyV1)
        else decode_score_policy(score_policy)
    )
    expected_length = batch.item_count * RANKED_ELEMENT_BYTES
    if len(encoded) != expected_length:
        _reject("ranked result has invalid exact length")

    items: list[RankedItemV1] = []
    for index in range(batch.item_count):
        offset = index * RANKED_ELEMENT_BYTES
        body = encoded[offset : offset + RANKED_ELEMENT_BODY_BYTES]
        stored_root = encoded[
            offset + RANKED_ELEMENT_BODY_BYTES : offset + RANKED_ELEMENT_BYTES
        ]
        expected_root = hashlib.sha256(
            RANKED_ELEMENT_DOMAIN
            + batch.batch_map_sha256
            + policy.score_policy_sha256
            + body
        ).digest()
        if stored_root != expected_root:
            _reject(f"ranked result element {index} root mismatch")
        items.append(
            RankedItemV1(
                item_id=_u64(body, 0),
                input_ordinal=_u64(body, 8),
                rank=_u64(body, 16),
                score=_i64(body, 24),
            )
        )

    ordinals: set[int] = set()
    for index, item in enumerate(items):
        if item.rank != index:
            _reject("ranked result rank is not its canonical position")
        if item.input_ordinal >= batch.item_count:
            _reject("ranked result input ordinal is out of range")
        if item.input_ordinal in ordinals:
            _reject("ranked result contains duplicate input ordinal")
        ordinals.add(item.input_ordinal)
        if item.item_id == 0 or batch.item_ids[item.input_ordinal] != item.item_id:
            _reject("ranked result item ID does not match its batch ordinal")
        if index:
            previous = items[index - 1]
            if previous.score < item.score:
                _reject("ranked result scores are not descending")
            if (
                previous.score == item.score
                and previous.input_ordinal >= item.input_ordinal
            ):
                _reject("ranked result violates the canonical tie break")

    if ordinals != set(range(batch.item_count)):
        _reject("ranked result is not a full batch-map permutation")
    return RankedResultV1(
        encoded,
        tuple(items),
        batch.batch_map_sha256,
        policy.score_policy_sha256,
    )


def reference_rerank(
    batch_map: bytes | BatchMapV1,
    weights: bytes,
    tensor: bytes,
    input_features: int,
) -> tuple[RankedItemV1, ...]:
    """Score i16-LE rows by one i8 query, checking every i64 addition."""

    batch = (
        batch_map
        if isinstance(batch_map, BatchMapV1)
        else decode_batch_map(batch_map)
    )
    weights = _exact_bytes(weights, "weights")
    tensor = _exact_bytes(tensor, "tensor")
    input_features = _exact_int(input_features, "input_features")
    if input_features <= 0 or input_features > MAXIMUM_INPUT_FEATURES:
        _reject("input_features is outside the retained fixture bounds")
    if len(weights) != input_features:
        _reject("i8 query length does not match input_features")
    expected_tensor_bytes = batch.item_count * input_features * 2
    if len(tensor) != expected_tensor_bytes:
        _reject("i16 tensor length does not match batch shape")

    query = tuple(value if value < 128 else value - 256 for value in weights)
    scored: list[tuple[int, int]] = []
    for ordinal in range(batch.item_count):
        accumulator = 0
        row_offset = ordinal * input_features * 2
        for feature, weight in enumerate(query):
            value_offset = row_offset + feature * 2
            value = int.from_bytes(
                tensor[value_offset : value_offset + 2],
                "little",
                signed=True,
            )
            product = value * weight
            candidate = accumulator + product
            if candidate < I64_MIN or candidate > I64_MAX:
                _reject("rerank score overflows signed i64")
            accumulator = candidate
        scored.append((ordinal, accumulator))

    scored.sort(key=lambda value: (-value[1], value[0]))
    return tuple(
        RankedItemV1(
            item_id=batch.item_ids[ordinal],
            input_ordinal=ordinal,
            rank=rank,
            score=score,
        )
        for rank, (ordinal, score) in enumerate(scored)
    )


def verify_demo_document(document: object) -> VerifiedDemoV1:
    """Verify the exact, download-free demo JSON contract."""

    if not isinstance(document, dict):
        _reject("demo JSON root must be an object")
    if set(document) != DEMO_FIELDS:
        _reject("demo JSON fields do not match the canonical schema")
    if document["schema"] != DEMO_SCHEMA:
        _reject("demo schema mismatch")
    if document["verified"] is not True:
        _reject("demo did not declare verified=true")

    batch_bytes = _canonical_hex(document["batch_map_hex"], "batch_map_hex")
    policy_bytes = _canonical_hex(
        document["score_policy_hex"],
        "score_policy_hex",
    )
    result_bytes = _canonical_hex(
        document["ranked_result_hex"],
        "ranked_result_hex",
    )
    weights = _canonical_hex(document["weights_hex"], "weights_hex")
    tensor = _canonical_hex(document["tensor_hex"], "tensor_hex")
    output_sha256 = _canonical_digest_hex(
        document["output_sha256"],
        "output_sha256",
    )
    source_mapping_sha256 = _canonical_nonzero_digest_hex(
        document["source_mapping_sha256"],
        "source_mapping_sha256",
    )
    result_sha256 = _canonical_nonzero_digest_hex(
        document["result_sha256"],
        "result_sha256",
    )
    input_features = _exact_int(document["input_features"], "input_features")

    batch = decode_batch_map(batch_bytes)
    if batch.item_count > RERANKER_MAX_BATCH_ITEMS:
        _reject("demo batch exceeds retained reranker profile")
    policy = decode_score_policy(policy_bytes)
    result = decode_ranked_result(result_bytes, batch, policy)
    expected_items = reference_rerank(
        batch,
        weights,
        tensor,
        input_features,
    )
    if result.items != expected_items:
        _reject("ranked result does not match independently recomputed scores")
    if hashlib.sha256(result_bytes).digest() != output_sha256:
        _reject("output_sha256 does not bind the exact ranked-result wire")

    declared_items = _decode_declared_items(document["items"])
    if declared_items != result.items:
        _reject("declared items do not match the verified ranked-result wire")
    return VerifiedDemoV1(
        batch,
        policy,
        result,
        weights,
        tensor,
        input_features,
        source_mapping_sha256,
        result_sha256,
        output_sha256,
    )


def run_demo(path: str | os.PathLike[str]) -> VerifiedDemoV1:
    """Run one demo executable and verify its single canonical JSON line."""

    executable = os.fspath(path)
    if not executable:
        _reject("demo path must not be empty")
    try:
        completed = subprocess.run(
            [executable],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OracleError(f"could not run demo: {error}") from error
    if completed.returncode != 0:
        _reject(f"demo exited with status {completed.returncode}")
    if completed.stderr:
        _reject("demo wrote unexpected stderr")
    stdout = completed.stdout
    if (
        not stdout
        or not stdout.endswith(b"\n")
        or stdout.count(b"\n") != 1
        or b"\r" in stdout
    ):
        _reject("demo must emit exactly one LF-terminated JSON line")
    try:
        line = stdout[:-1].decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise OracleError("demo output is not UTF-8") from error
    try:
        document = json.loads(
            line,
            object_pairs_hook=_unique_object,
            parse_constant=_invalid_json_constant,
        )
    except (json.JSONDecodeError, OracleError) as error:
        raise OracleError(f"invalid demo JSON: {error}") from error
    return verify_demo_document(document)


def _exact_bytes(value: object, label: str) -> bytes:
    if type(value) is not bytes:
        _reject(f"{label} must be bytes")
    return value


def _exact_int(value: object, label: str) -> int:
    if type(value) is not int:
        _reject(f"{label} must be an integer")
    return value


def _canonical_hex(value: object, label: str) -> bytes:
    if not isinstance(value, str) or len(value) % 2 != 0:
        _reject(f"{label} must be an even-length lowercase hex string")
    if any(character not in "0123456789abcdef" for character in value):
        _reject(f"{label} must be canonical lowercase hex")
    return bytes.fromhex(value)


def _canonical_digest_hex(value: object, label: str) -> bytes:
    decoded = _canonical_hex(value, label)
    if len(decoded) != 32:
        _reject(f"{label} must encode exactly 32 bytes")
    return decoded


def _canonical_nonzero_digest_hex(value: object, label: str) -> bytes:
    decoded = _canonical_digest_hex(value, label)
    if decoded == bytes(32):
        _reject(f"{label} must be nonzero")
    return decoded


def _decode_declared_items(value: object) -> tuple[RankedItemV1, ...]:
    if not isinstance(value, list):
        _reject("items must be an array")
    decoded: list[RankedItemV1] = []
    for document in value:
        if not isinstance(document, dict) or set(document) != ITEM_FIELDS:
            _reject("declared item fields do not match the canonical schema")
        item_id = _exact_int(document["item_id"], "item_id")
        input_ordinal = _exact_int(document["input_ordinal"], "input_ordinal")
        rank = _exact_int(document["rank"], "rank")
        score = _exact_int(document["score"], "score")
        if not 0 <= item_id <= U64_MAX:
            _reject("declared item_id is outside u64")
        if not 0 <= input_ordinal <= U64_MAX:
            _reject("declared input_ordinal is outside u64")
        if not 0 <= rank <= U64_MAX:
            _reject("declared rank is outside u64")
        if not I64_MIN <= score <= I64_MAX:
            _reject("declared score is outside i64")
        decoded.append(RankedItemV1(item_id, input_ordinal, rank, score))
    return tuple(decoded)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            _reject(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def _invalid_json_constant(value: str) -> NoReturn:
    _reject(f"non-finite JSON number: {value}")


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Independently verify the dense-tensor reranker demo",
    )
    parser.add_argument(
        "--demo",
        required=True,
        type=Path,
        metavar="PATH",
        help="path to glacier-dense-tensor-reranker-demo",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _argument_parser()
    arguments = parser.parse_args(argv)
    try:
        verified = run_demo(arguments.demo)
    except OracleError as error:
        print(f"stateless tensor verification failed: {error}", file=sys.stderr)
        return 1
    receipt = {
        "schema": "glacier.dense-tensor-reranker-verification/v1",
        "items": verified.batch_map.item_count,
        "source_mapping_sha256": verified.source_mapping_sha256.hex(),
        "result_sha256": verified.result_sha256.hex(),
        "output_sha256": verified.output_sha256.hex(),
        "verified": True,
    }
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
