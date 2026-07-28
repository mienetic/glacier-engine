#!/usr/bin/env python3
"""Independent verifier for Glacier's normalized dense-embedding demo.

The verifier is intentionally standard-library only.  It imports only the
independent BatchMap decoder shared with the earlier dense-tensor oracle; all
embedding policy, projection, normalization, matrix, and demo checks are
implemented here from frozen constants.

``source_mapping_sha256`` and ``result_sha256`` are checked for canonical,
nonzero digest encoding.  The compact demo does not emit enough lifecycle or
plan evidence to reconstruct those two roots, so this verifier deliberately
does not claim to recompute them.  It does independently recompute the dense
projection, exact Q30 normalization, output digest, and embedding-matrix root.
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

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bench.stateless_tensor_result import decode_batch_map


DEMO_SCHEMA = "glacier.dense-tensor-embedding/v1"
VERIFICATION_SCHEMA = "glacier.dense-tensor-embedding-verification/v1"

EMBEDDING_MAX_BATCH_ITEMS = 64
MAXIMUM_INPUT_FEATURES = 4096
MAXIMUM_OUTPUT_DIMENSIONS = 256

EMBEDDING_POLICY_MAGIC = b"GSTEMB1\x00"
EMBEDDING_POLICY_ABI = 0x4753_5445_4D00_0001
EMBEDDING_POLICY_BYTES = 112
EMBEDDING_POLICY_DOMAIN = b"glacier-stateless-embedding-policy-v1\x00"

NORMALIZATION_Q30_L2 = 1
COMPONENT_SIGNED_I32_LE = 1
NORM_EXACT_SQUARED_THRESHOLD = 1
ROUND_NEAREST_TIES_TO_EVEN = 1
ZERO_VECTOR_REJECT = 1
Q30_SCALE = 1 << 30

EMBEDDING_MATRIX_DOMAIN = b"glacier-stateless-embedding-matrix-v1\x00"

I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1
I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
U64_MAX = (1 << 64) - 1

DEMO_FIELDS = frozenset(
    {
        "schema",
        "batch_map_hex",
        "embedding_policy_hex",
        "embedding_hex",
        "weights_hex",
        "tensor_hex",
        "input_features",
        "output_dimensions",
        "source_mapping_sha256",
        "result_sha256",
        "output_sha256",
        "embedding_sha256",
        "rows",
        "verified",
    }
)
ROW_FIELDS = frozenset({"item_id", "input_ordinal", "components"})


class OracleError(ValueError):
    """A wire, shape, projection, or demo record violates the contract."""


@dataclass(frozen=True)
class EmbeddingPolicyV1:
    encoded: bytes
    normalization: int
    component_format: int
    norm_algorithm: int
    rounding: int
    zero_policy: int
    scale: int
    embedding_policy_sha256: bytes


@dataclass(frozen=True)
class EmbeddingRowV1:
    item_id: int
    input_ordinal: int
    components: tuple[int, ...]

    def document(self) -> dict[str, object]:
        return {
            "item_id": self.item_id,
            "input_ordinal": self.input_ordinal,
            "components": list(self.components),
        }


@dataclass(frozen=True)
class EmbeddingMatrixV1:
    encoded: bytes
    rows: tuple[EmbeddingRowV1, ...]
    item_count: int
    output_dimensions: int
    embedding_sha256: bytes


@dataclass(frozen=True)
class VerifiedDemoV1:
    batch_map: object
    embedding_policy: EmbeddingPolicyV1
    embedding_matrix: EmbeddingMatrixV1
    weights: bytes
    tensor: bytes
    input_features: int
    output_dimensions: int
    source_mapping_sha256: bytes
    result_sha256: bytes
    output_sha256: bytes
    embedding_sha256: bytes


def _reject(message: str) -> NoReturn:
    raise OracleError(message)


def _u64(encoded: bytes, offset: int) -> int:
    return int.from_bytes(encoded[offset : offset + 8], "little", signed=False)


def _domain_root(domain: bytes, payload: bytes) -> bytes:
    return hashlib.sha256(domain + payload).digest()


def decode_embedding_policy(encoded: bytes) -> EmbeddingPolicyV1:
    """Decode the sole canonical normalized-embedding policy V1."""

    encoded = _exact_bytes(encoded, "embedding policy")
    if len(encoded) != EMBEDDING_POLICY_BYTES:
        _reject("embedding policy has invalid length")
    if encoded[:8] != EMBEDDING_POLICY_MAGIC:
        _reject("embedding policy has invalid magic")
    if _u64(encoded, 8) != EMBEDDING_POLICY_ABI:
        _reject("embedding policy has invalid ABI")
    if _u64(encoded, 16) != EMBEDDING_POLICY_BYTES:
        _reject("embedding policy declared length mismatch")

    normalization = _u64(encoded, 24)
    component_format = _u64(encoded, 32)
    norm_algorithm = _u64(encoded, 40)
    rounding = _u64(encoded, 48)
    zero_policy = _u64(encoded, 56)
    scale = _u64(encoded, 64)
    if _u64(encoded, 72) != 0:
        _reject("embedding policy reserved field is nonzero")
    if (
        normalization != NORMALIZATION_Q30_L2
        or component_format != COMPONENT_SIGNED_I32_LE
        or norm_algorithm != NORM_EXACT_SQUARED_THRESHOLD
        or rounding != ROUND_NEAREST_TIES_TO_EVEN
        or zero_policy != ZERO_VECTOR_REJECT
        or scale != Q30_SCALE
    ):
        _reject("embedding policy is not the canonical V1 policy")

    root_offset = EMBEDDING_POLICY_BYTES - 32
    expected_root = _domain_root(
        EMBEDDING_POLICY_DOMAIN,
        encoded[:root_offset],
    )
    if encoded[root_offset:] != expected_root:
        _reject("embedding policy root mismatch")
    return EmbeddingPolicyV1(
        encoded=encoded,
        normalization=normalization,
        component_format=component_format,
        norm_algorithm=norm_algorithm,
        rounding=rounding,
        zero_policy=zero_policy,
        scale=scale,
        embedding_policy_sha256=expected_root,
    )


def round_sqrt_ratio_nearest_even(
    target: int,
    denominator: int,
    maximum: int,
) -> int:
    """Return round-to-even(sqrt(target / denominator)) with integers only.

    ``maximum`` bounds the binary search and is part of the caller's proof
    that the requested square root is representable.  Keeping this primitive
    public makes the midpoint/tie rule directly testable without relying on
    floating-point approximations.
    """

    target = _exact_int(target, "target")
    denominator = _exact_int(denominator, "denominator")
    maximum = _exact_int(maximum, "maximum")
    if target < 0 or denominator <= 0 or maximum < 0:
        _reject("squared-ratio arguments are outside their valid range")
    if target > maximum * maximum * denominator:
        _reject("squared ratio exceeds its declared maximum")

    low = 0
    high = maximum
    while low < high:
        midpoint = (low + high + 1) // 2
        if midpoint * midpoint * denominator <= target:
            low = midpoint
        else:
            high = midpoint - 1

    floor_value = low
    if floor_value == maximum:
        return floor_value
    midpoint_left = (2 * floor_value + 1) ** 2 * denominator
    midpoint_right = 4 * target
    if midpoint_left < midpoint_right:
        return floor_value + 1
    if midpoint_left == midpoint_right and floor_value % 2 == 1:
        return floor_value + 1
    return floor_value


def normalize_q30_l2(raw_components: Sequence[int]) -> tuple[int, ...]:
    """Normalize one nonzero signed-i64 vector to exact signed Q30."""

    if isinstance(raw_components, (str, bytes, bytearray, memoryview)):
        _reject("raw components must be an integer sequence")
    try:
        raw = tuple(raw_components)
    except TypeError as error:
        raise OracleError("raw components must be an integer sequence") from error
    if not raw or len(raw) > MAXIMUM_OUTPUT_DIMENSIONS:
        _reject("raw component count is outside the embedding profile")
    for component in raw:
        if type(component) is not int or not I64_MIN <= component <= I64_MAX:
            _reject("raw component is outside signed i64")

    sum_of_squares = sum(component * component for component in raw)
    if sum_of_squares == 0:
        _reject("zero projection row cannot be L2-normalized")

    normalized: list[int] = []
    scale_squared = Q30_SCALE * Q30_SCALE
    for component in raw:
        magnitude = abs(component)
        target = magnitude * magnitude * scale_squared
        rounded = round_sqrt_ratio_nearest_even(
            target,
            sum_of_squares,
            Q30_SCALE,
        )
        normalized.append(-rounded if component < 0 else rounded)
    return tuple(normalized)


def reference_embedding(
    batch_map: bytes | object,
    weights: bytes,
    tensor: bytes,
    input_features: int,
    output_dimensions: int,
) -> tuple[EmbeddingRowV1, ...]:
    """Project i16 rows through a D-by-F i8 matrix and normalize to Q30."""

    batch = (
        decode_batch_map(batch_map)
        if type(batch_map) is bytes
        else batch_map
    )
    if not (
        hasattr(batch, "item_count")
        and hasattr(batch, "item_ids")
        and hasattr(batch, "batch_map_sha256")
    ):
        _reject("batch_map must be encoded bytes or a decoded BatchMap V1")
    weights = _exact_bytes(weights, "weights")
    tensor = _exact_bytes(tensor, "tensor")
    input_features = _profile_dimension(
        input_features,
        "input_features",
        MAXIMUM_INPUT_FEATURES,
    )
    output_dimensions = _profile_dimension(
        output_dimensions,
        "output_dimensions",
        MAXIMUM_OUTPUT_DIMENSIONS,
    )
    item_count = _exact_int(batch.item_count, "batch item count")
    if item_count <= 0 or item_count > EMBEDDING_MAX_BATCH_ITEMS:
        _reject("batch exceeds retained embedding profile")
    if len(weights) != output_dimensions * input_features:
        _reject("i8 weight matrix length does not match D-by-F shape")
    expected_tensor_bytes = item_count * input_features * 2
    if len(tensor) != expected_tensor_bytes:
        _reject("i16 tensor length does not match B-by-F shape")

    signed_weights = tuple(
        value if value < 128 else value - 256 for value in weights
    )
    rows: list[EmbeddingRowV1] = []
    for ordinal in range(item_count):
        raw_components: list[int] = []
        tensor_row_offset = ordinal * input_features * 2
        for dimension in range(output_dimensions):
            weight_row_offset = dimension * input_features
            accumulator = 0
            for feature in range(input_features):
                value_offset = tensor_row_offset + feature * 2
                value = int.from_bytes(
                    tensor[value_offset : value_offset + 2],
                    "little",
                    signed=True,
                )
                product = (
                    value
                    * signed_weights[weight_row_offset + feature]
                )
                candidate = accumulator + product
                if candidate < I64_MIN or candidate > I64_MAX:
                    _reject("embedding projection overflows signed i64")
                accumulator = candidate
            raw_components.append(accumulator)
        components = normalize_q30_l2(raw_components)
        rows.append(
            EmbeddingRowV1(
                item_id=batch.item_ids[ordinal],
                input_ordinal=ordinal,
                components=components,
            )
        )
    return tuple(rows)


def encode_embedding_rows(rows: Sequence[EmbeddingRowV1]) -> bytes:
    """Encode verified row components as compact row-major signed i32 LE."""

    encoded = bytearray()
    for row in rows:
        for component in row.components:
            if (
                type(component) is not int
                or not I32_MIN <= component <= I32_MAX
            ):
                _reject("embedding component is outside signed i32")
            encoded.extend(component.to_bytes(4, "little", signed=True))
    return bytes(encoded)


def embedding_matrix_sha256(
    batch_map_sha256: bytes,
    embedding_policy_sha256: bytes,
    item_count: int,
    output_dimensions: int,
    encoded: bytes,
) -> bytes:
    """Compute the domain-separated identity of one compact matrix."""

    batch_map_sha256 = _exact_digest(
        batch_map_sha256,
        "batch_map_sha256",
    )
    embedding_policy_sha256 = _exact_digest(
        embedding_policy_sha256,
        "embedding_policy_sha256",
    )
    item_count = _profile_dimension(
        item_count,
        "item_count",
        EMBEDDING_MAX_BATCH_ITEMS,
    )
    output_dimensions = _profile_dimension(
        output_dimensions,
        "output_dimensions",
        MAXIMUM_OUTPUT_DIMENSIONS,
    )
    encoded = _exact_bytes(encoded, "embedding")
    expected_length = item_count * output_dimensions * 4
    if len(encoded) != expected_length:
        _reject("embedding matrix length does not match B-by-D shape")
    preimage = (
        batch_map_sha256
        + embedding_policy_sha256
        + item_count.to_bytes(8, "little")
        + output_dimensions.to_bytes(8, "little")
        + encoded
    )
    return _domain_root(EMBEDDING_MATRIX_DOMAIN, preimage)


def decode_embedding_matrix(
    encoded: bytes,
    batch_map: bytes | object,
    embedding_policy: bytes | EmbeddingPolicyV1,
    output_dimensions: int,
) -> EmbeddingMatrixV1:
    """Decode compact B-by-D i32 LE components and validate their bounds."""

    encoded = _exact_bytes(encoded, "embedding")
    batch = (
        decode_batch_map(batch_map)
        if type(batch_map) is bytes
        else batch_map
    )
    if not (
        hasattr(batch, "item_count")
        and hasattr(batch, "item_ids")
        and hasattr(batch, "batch_map_sha256")
    ):
        _reject("batch_map must be encoded bytes or a decoded BatchMap V1")
    policy = (
        embedding_policy
        if isinstance(embedding_policy, EmbeddingPolicyV1)
        else decode_embedding_policy(embedding_policy)
    )
    output_dimensions = _profile_dimension(
        output_dimensions,
        "output_dimensions",
        MAXIMUM_OUTPUT_DIMENSIONS,
    )
    item_count = _exact_int(batch.item_count, "batch item count")
    if item_count <= 0 or item_count > EMBEDDING_MAX_BATCH_ITEMS:
        _reject("batch exceeds retained embedding profile")
    expected_length = item_count * output_dimensions * 4
    if len(encoded) != expected_length:
        _reject("embedding matrix length does not match B-by-D shape")

    rows: list[EmbeddingRowV1] = []
    for ordinal in range(item_count):
        row_offset = ordinal * output_dimensions * 4
        components = tuple(
            int.from_bytes(
                encoded[
                    row_offset
                    + dimension * 4 : row_offset
                    + (dimension + 1) * 4
                ],
                "little",
                signed=True,
            )
            for dimension in range(output_dimensions)
        )
        if any(abs(component) > Q30_SCALE for component in components):
            _reject("embedding component exceeds signed Q30 unit bound")
        if not any(components):
            _reject("embedding row is the forbidden zero vector")
        rows.append(
            EmbeddingRowV1(
                item_id=batch.item_ids[ordinal],
                input_ordinal=ordinal,
                components=components,
            )
        )

    root = embedding_matrix_sha256(
        batch.batch_map_sha256,
        policy.embedding_policy_sha256,
        item_count,
        output_dimensions,
        encoded,
    )
    return EmbeddingMatrixV1(
        encoded=encoded,
        rows=tuple(rows),
        item_count=item_count,
        output_dimensions=output_dimensions,
        embedding_sha256=root,
    )


def verify_demo_document(document: object) -> VerifiedDemoV1:
    """Verify the exact, download-free normalized-embedding demo record."""

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
        document["embedding_policy_hex"],
        "embedding_policy_hex",
    )
    embedding_bytes = _canonical_hex(
        document["embedding_hex"],
        "embedding_hex",
    )
    weights = _canonical_hex(document["weights_hex"], "weights_hex")
    tensor = _canonical_hex(document["tensor_hex"], "tensor_hex")
    input_features = _profile_dimension(
        document["input_features"],
        "input_features",
        MAXIMUM_INPUT_FEATURES,
    )
    output_dimensions = _profile_dimension(
        document["output_dimensions"],
        "output_dimensions",
        MAXIMUM_OUTPUT_DIMENSIONS,
    )
    source_mapping_sha256 = _canonical_nonzero_digest_hex(
        document["source_mapping_sha256"],
        "source_mapping_sha256",
    )
    result_sha256 = _canonical_nonzero_digest_hex(
        document["result_sha256"],
        "result_sha256",
    )
    output_sha256 = _canonical_digest_hex(
        document["output_sha256"],
        "output_sha256",
    )
    declared_embedding_sha256 = _canonical_digest_hex(
        document["embedding_sha256"],
        "embedding_sha256",
    )

    batch = decode_batch_map(batch_bytes)
    if batch.item_count > EMBEDDING_MAX_BATCH_ITEMS:
        _reject("demo batch exceeds retained embedding profile")
    policy = decode_embedding_policy(policy_bytes)
    matrix = decode_embedding_matrix(
        embedding_bytes,
        batch,
        policy,
        output_dimensions,
    )
    expected_rows = reference_embedding(
        batch,
        weights,
        tensor,
        input_features,
        output_dimensions,
    )
    if matrix.rows != expected_rows:
        _reject(
            "embedding matrix does not match independently recomputed "
            "projection and normalization"
        )
    if hashlib.sha256(embedding_bytes).digest() != output_sha256:
        _reject("output_sha256 does not bind the exact embedding bytes")
    if matrix.embedding_sha256 != declared_embedding_sha256:
        _reject("embedding_sha256 does not bind the canonical matrix")

    declared_rows = _decode_declared_rows(
        document["rows"],
        batch.item_count,
        output_dimensions,
    )
    if declared_rows != matrix.rows:
        _reject("declared rows do not match the verified embedding matrix")
    return VerifiedDemoV1(
        batch_map=batch,
        embedding_policy=policy,
        embedding_matrix=matrix,
        weights=weights,
        tensor=tensor,
        input_features=input_features,
        output_dimensions=output_dimensions,
        source_mapping_sha256=source_mapping_sha256,
        result_sha256=result_sha256,
        output_sha256=output_sha256,
        embedding_sha256=declared_embedding_sha256,
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


def _profile_dimension(value: object, label: str, maximum: int) -> int:
    decoded = _exact_int(value, label)
    if decoded <= 0 or decoded > maximum:
        _reject(f"{label} is outside the retained embedding profile")
    return decoded


def _exact_digest(value: object, label: str) -> bytes:
    decoded = _exact_bytes(value, label)
    if len(decoded) != 32:
        _reject(f"{label} must contain exactly 32 bytes")
    return decoded


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


def _decode_declared_rows(
    value: object,
    item_count: int,
    output_dimensions: int,
) -> tuple[EmbeddingRowV1, ...]:
    if not isinstance(value, list) or len(value) != item_count:
        _reject("rows must contain exactly one entry per batch item")
    rows: list[EmbeddingRowV1] = []
    for expected_ordinal, document in enumerate(value):
        if not isinstance(document, dict) or set(document) != ROW_FIELDS:
            _reject("declared row fields do not match the canonical schema")
        item_id = _exact_int(document["item_id"], "item_id")
        input_ordinal = _exact_int(
            document["input_ordinal"],
            "input_ordinal",
        )
        if not 0 < item_id <= U64_MAX:
            _reject("declared item_id is outside nonzero u64")
        if input_ordinal != expected_ordinal:
            _reject("declared rows are not in canonical input order")
        components_document = document["components"]
        if (
            not isinstance(components_document, list)
            or len(components_document) != output_dimensions
        ):
            _reject("declared component count does not match dimensions")
        components: list[int] = []
        for component in components_document:
            component = _exact_int(component, "component")
            if not -Q30_SCALE <= component <= Q30_SCALE:
                _reject("declared component exceeds signed Q30 unit bound")
            components.append(component)
        if not any(components):
            _reject("declared row is the forbidden zero vector")
        rows.append(
            EmbeddingRowV1(item_id, input_ordinal, tuple(components))
        )
    return tuple(rows)


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
        description="Independently verify the dense-tensor embedding demo",
    )
    parser.add_argument(
        "--demo",
        required=True,
        type=Path,
        metavar="PATH",
        help="path to glacier-dense-tensor-embedding-demo",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _argument_parser()
    arguments = parser.parse_args(argv)
    try:
        verified = run_demo(arguments.demo)
    except OracleError as error:
        print(f"stateless embedding verification failed: {error}", file=sys.stderr)
        return 1
    receipt = {
        "schema": VERIFICATION_SCHEMA,
        "items": verified.embedding_matrix.item_count,
        "dimensions": verified.output_dimensions,
        "source_mapping_sha256": verified.source_mapping_sha256.hex(),
        "result_sha256": verified.result_sha256.hex(),
        "output_sha256": verified.output_sha256.hex(),
        "embedding_sha256": verified.embedding_sha256.hex(),
        "verified": True,
    }
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
