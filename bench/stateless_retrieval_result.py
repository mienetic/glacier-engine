#!/usr/bin/env python3
"""Independent standard-library oracle for the fixed dense retrieval demo.

The demo is deliberately small, but its evidence is not accepted on trust.
This module decodes every wire, authenticates every contextual root, repeats
tenant filtering and exact Q30 top-k search, and reconstructs the complete
model lifecycle result root from the frozen ReferenceFixtureV1 constants.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn, Sequence


DEMO_SCHEMA = "glacier.dense-tensor-retrieval/v1"
VERIFICATION_SCHEMA = "glacier.dense-tensor-retrieval-verification/v1"

MAXIMUM_CORPUS_ITEMS = 64
MAXIMUM_EMBEDDING_DIMENSIONS = 4096
Q30_SCALE = 1 << 30
RETRIEVAL_HIT_BYTES = 96
RETRIEVAL_HIT_BODY_BYTES = 64

BATCH_MAP_MAGIC = b"GSTBMAP1"
BATCH_MAP_ABI = 0x4753_5442_4D00_0001
BATCH_MAP_DOMAIN = b"glacier-stateless-tensor-batch-map-v1\x00"

EMBEDDING_POLICY_MAGIC = b"GSTEMB1\x00"
EMBEDDING_POLICY_ABI = 0x4753_5445_4D00_0001
EMBEDDING_POLICY_BYTES = 112
EMBEDDING_POLICY_DOMAIN = b"glacier-stateless-embedding-policy-v1\x00"
EMBEDDING_MATRIX_DOMAIN = b"glacier-stateless-embedding-matrix-v1\x00"

VISIBILITY_MAGIC = b"GRVIS1\x00\x00"
VISIBILITY_ABI = 0x4752_5649_5300_0001
VISIBILITY_DOMAIN = b"glacier-retrieval-visibility-map-v1\x00"

RETRIEVAL_POLICY_MAGIC = b"GRPOL1\x00\x00"
RETRIEVAL_POLICY_ABI = 0x4752_504F_4C00_0001
RETRIEVAL_POLICY_BYTES = 112
RETRIEVAL_POLICY_DOMAIN = b"glacier-retrieval-policy-v1\x00"

INDEX_MAGIC = b"GRIDX1\x00\x00"
INDEX_ABI = 0x4752_4944_5800_0001
INDEX_BYTES = 256
INDEX_DOMAIN = b"glacier-retrieval-index-v1\x00"

QUERY_BINDING_MAGIC = b"GRQRY1\x00\x00"
QUERY_BINDING_ABI = 0x4752_5152_5900_0001
QUERY_BINDING_BYTES = 320
QUERY_BINDING_DOMAIN = b"glacier-retrieval-query-binding-v1\x00"

RETRIEVAL_HIT_DOMAIN = b"glacier-retrieval-hit-v1\x00"
RETRIEVAL_RESULT_DOMAIN = b"glacier-retrieval-result-v1\x00"
INPUT_BUNDLE_DOMAIN = (
    b"glacier-dense-tensor-retrieval-input-bundle-v1\x00"
)
SOURCE_MAPPING_DOMAIN = (
    b"glacier-dense-tensor-retrieval-source-mapping-v1\x00"
)

ARTIFACT_MAGIC = b"GMART1\x00\x00"
PLAN_MAGIC = b"GMPLAN1\x00"
RESULT_MAGIC = b"GMRES1\x00\x00"
ARTIFACT_ABI = 0x474D_4146_0000_0001
PLAN_ABI = 0x474D_504C_0000_0001
RESULT_ABI = 0x474D_5253_0000_0001
ARTIFACT_DOMAIN = b"glacier-model-artifact-manifest-v1\x00"
PLAN_DOMAIN = b"glacier-model-execution-plan-v1\x00"
RESULT_DOMAIN = b"glacier-model-result-envelope-v1\x00"
PUBLICATION_STATE_DOMAIN = b"glacier-model-publication-state-v1\x00"
PUBLICATION_COMMIT_DOMAIN = b"glacier-model-publication-commit-v1\x00"
ADAPTER_DOMAIN = b"glacier-stateless-model-adapter-v1\x00"

MODEL_FAMILY_RETRIEVAL = 12
OPERATION_RETRIEVE = 15
INPUT_KIND_EMBEDDING_I32 = 8
OUTPUT_KIND_RETRIEVAL_HITS = 13
NUMERICAL_POLICY_EXACT_INTEGER = 1
ARTIFACT_RETRIEVAL_ABI = 0x4452_4554_0000_0001
REFERENCE_ADAPTER_ABI = 0x4744_5254_0000_0001

REFERENCE_CORPUS_IDS = (101, 201, 202, 203)
REFERENCE_QUERY_IDS = (9001,)
REFERENCE_VISIBILITY = (99, 7, 7, 7)
REFERENCE_DIMENSIONS = 2
REFERENCE_TOP_K = 2
REFERENCE_CORPUS_COMPONENTS = (
    Q30_SCALE,
    0,
    0,
    Q30_SCALE,
    0,
    Q30_SCALE,
    -Q30_SCALE,
    0,
)
REFERENCE_QUERY_COMPONENTS = (Q30_SCALE, 0)
REFERENCE_QUERY_TENANT = 7
REFERENCE_REQUEST_EPOCH = 801
REFERENCE_GENERATION = 1
REFERENCE_BANK_EPOCH = 0x4445_4D4F_5254
REFERENCE_OWNER_KEY = 0x4445_4D4F_5257
REFERENCE_RECEIPT_DOMAIN = 0x7265_6365_6970_7431

DEMO_FIELDS = frozenset(
    {
        "schema",
        "corpus_map_hex",
        "query_map_hex",
        "embedding_policy_hex",
        "retrieval_policy_hex",
        "visibility_hex",
        "index_hex",
        "query_binding_hex",
        "packed_weights_hex",
        "query_embedding_hex",
        "retrieval_result_hex",
        "output_sha256",
        "source_mapping_sha256",
        "result_sha256",
        "retrieval_result_sha256",
        "hits",
        "verified",
    }
)
HIT_FIELDS = frozenset({"rank", "item_id", "corpus_ordinal", "score_q30"})
U64_MAX = (1 << 64) - 1
I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
MASK64 = U64_MAX


class OracleError(ValueError):
    """The demo or one of its binary contracts is not canonical."""


@dataclass(frozen=True)
class BatchMapV1:
    encoded: bytes
    item_ids: tuple[int, ...]
    batch_map_sha256: bytes

    @property
    def item_count(self) -> int:
        return len(self.item_ids)


@dataclass(frozen=True)
class EmbeddingPolicyV1:
    encoded: bytes
    embedding_policy_sha256: bytes


@dataclass(frozen=True)
class VisibilityMapV1:
    encoded: bytes
    tenant_scopes: tuple[int, ...]
    corpus_map_sha256: bytes
    visibility_sha256: bytes


@dataclass(frozen=True)
class RetrievalPolicyV1:
    encoded: bytes
    top_k: int
    retrieval_policy_sha256: bytes


@dataclass(frozen=True)
class RetrievalIndexV1:
    encoded: bytes
    generation: int
    corpus_count: int
    dimensions: int
    index_id_sha256: bytes
    corpus_map_sha256: bytes
    visibility_sha256: bytes
    embedding_policy_sha256: bytes
    corpus_embedding_sha256: bytes
    index_descriptor_sha256: bytes


@dataclass(frozen=True)
class QueryBindingV1:
    encoded: bytes
    query_tenant: int
    dimensions: int
    query_object_sha256: bytes
    query_map_sha256: bytes
    embedding_policy_sha256: bytes
    query_embedding_sha256: bytes
    index_descriptor_sha256: bytes
    retrieval_policy_sha256: bytes
    challenge_sha256: bytes
    query_binding_sha256: bytes


@dataclass(frozen=True)
class EmbeddingMatrixV1:
    encoded: bytes
    components: tuple[int, ...]
    item_count: int
    dimensions: int
    embedding_matrix_sha256: bytes


@dataclass(frozen=True)
class RetrievalHitV1:
    rank: int
    item_id: int
    corpus_ordinal: int
    score_q30: int

    def document(self) -> dict[str, int]:
        return {
            "rank": self.rank,
            "item_id": self.item_id,
            "corpus_ordinal": self.corpus_ordinal,
            "score_q30": self.score_q30,
        }


@dataclass(frozen=True)
class RetrievalResultV1:
    encoded: bytes
    hits: tuple[RetrievalHitV1, ...]
    retrieval_result_sha256: bytes


@dataclass(frozen=True)
class VerifiedDemoV1:
    corpus_map: BatchMapV1
    query_map: BatchMapV1
    index: RetrievalIndexV1
    query_binding: QueryBindingV1
    retrieval_result: RetrievalResultV1
    output_sha256: bytes
    source_mapping_sha256: bytes
    result_sha256: bytes


def _reject(message: str) -> NoReturn:
    raise OracleError(message)


def _exact_bytes(value: object, label: str) -> bytes:
    if type(value) is not bytes:
        _reject(f"{label} must be bytes")
    return value


def _exact_int(value: object, label: str) -> int:
    if type(value) is not int:
        _reject(f"{label} must be an integer")
    return value


def _u64(encoded: bytes, offset: int) -> int:
    return int.from_bytes(encoded[offset : offset + 8], "little")


def _le64(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        _reject("value is outside unsigned u64")
    return value.to_bytes(8, "little")


def _put_u64(destination: bytearray, offset: int, value: int) -> None:
    destination[offset : offset + 8] = _le64(value)


def _domain_root(domain: bytes, payload: bytes) -> bytes:
    return hashlib.sha256(domain + payload).digest()


def _nonzero_digest(value: bytes, label: str) -> bytes:
    if len(value) != 32 or value == bytes(32):
        _reject(f"{label} must be a nonzero SHA-256 digest")
    return value


def decode_batch_map(encoded: bytes) -> BatchMapV1:
    encoded = _exact_bytes(encoded, "batch map")
    if len(encoded) < 72 or encoded[:8] != BATCH_MAP_MAGIC:
        _reject("batch map has invalid framing")
    if _u64(encoded, 8) != BATCH_MAP_ABI:
        _reject("batch map has invalid ABI")
    if _u64(encoded, 16) != len(encoded):
        _reject("batch map declared length mismatch")
    count = _u64(encoded, 24)
    if count == 0 or count > MAXIMUM_CORPUS_ITEMS:
        _reject("batch map count is outside the retrieval profile")
    if len(encoded) != 32 + count * 8 + 32:
        _reject("batch map has invalid length")
    root_offset = len(encoded) - 32
    root = _domain_root(BATCH_MAP_DOMAIN, encoded[:root_offset])
    if encoded[root_offset:] != root:
        _reject("batch map root mismatch")
    item_ids = tuple(_u64(encoded, 32 + index * 8) for index in range(count))
    if any(item_id == 0 for item_id in item_ids) or len(set(item_ids)) != count:
        _reject("batch map item IDs must be nonzero and unique")
    return BatchMapV1(encoded, item_ids, root)


def decode_embedding_policy(encoded: bytes) -> EmbeddingPolicyV1:
    encoded = _exact_bytes(encoded, "embedding policy")
    if (
        len(encoded) != EMBEDDING_POLICY_BYTES
        or encoded[:8] != EMBEDDING_POLICY_MAGIC
        or _u64(encoded, 8) != EMBEDDING_POLICY_ABI
        or _u64(encoded, 16) != EMBEDDING_POLICY_BYTES
    ):
        _reject("embedding policy has invalid framing")
    if tuple(_u64(encoded, offset) for offset in range(24, 72, 8)) != (
        1,
        1,
        1,
        1,
        1,
        Q30_SCALE,
    ):
        _reject("embedding policy is not canonical V1")
    if _u64(encoded, 72) != 0:
        _reject("embedding policy reserved field is nonzero")
    root = _domain_root(EMBEDDING_POLICY_DOMAIN, encoded[:80])
    if encoded[80:] != root:
        _reject("embedding policy root mismatch")
    return EmbeddingPolicyV1(encoded, root)


def decode_visibility_map(
    encoded: bytes,
    corpus_map: BatchMapV1,
) -> VisibilityMapV1:
    encoded = _exact_bytes(encoded, "visibility map")
    if len(encoded) < 104 or encoded[:8] != VISIBILITY_MAGIC:
        _reject("visibility map has invalid framing")
    if _u64(encoded, 8) != VISIBILITY_ABI or _u64(encoded, 16) != len(encoded):
        _reject("visibility map ABI or length mismatch")
    count = _u64(encoded, 24)
    if count == 0 or count > MAXIMUM_CORPUS_ITEMS:
        _reject("visibility map count is outside the retrieval profile")
    if len(encoded) != 64 + count * 8 + 32:
        _reject("visibility map has invalid length")
    corpus_root = encoded[32:64]
    if count != corpus_map.item_count or corpus_root != corpus_map.batch_map_sha256:
        _reject("visibility map does not bind the corpus map")
    root_offset = len(encoded) - 32
    root = _domain_root(VISIBILITY_DOMAIN, encoded[:root_offset])
    if encoded[root_offset:] != root:
        _reject("visibility map root mismatch")
    scopes = tuple(_u64(encoded, 64 + index * 8) for index in range(count))
    return VisibilityMapV1(encoded, scopes, corpus_root, root)


def decode_retrieval_policy(encoded: bytes) -> RetrievalPolicyV1:
    encoded = _exact_bytes(encoded, "retrieval policy")
    if (
        len(encoded) != RETRIEVAL_POLICY_BYTES
        or encoded[:8] != RETRIEVAL_POLICY_MAGIC
        or _u64(encoded, 8) != RETRIEVAL_POLICY_ABI
        or _u64(encoded, 16) != RETRIEVAL_POLICY_BYTES
    ):
        _reject("retrieval policy has invalid framing")
    if tuple(_u64(encoded, offset) for offset in range(24, 64, 8)) != (
        1,
        1,
        1,
        1,
        1,
    ):
        _reject("retrieval policy is not canonical V1")
    top_k = _u64(encoded, 64)
    if top_k == 0 or top_k > MAXIMUM_CORPUS_ITEMS:
        _reject("retrieval top_k is outside the profile")
    if _u64(encoded, 72) != 0:
        _reject("retrieval policy reserved field is nonzero")
    root = _domain_root(RETRIEVAL_POLICY_DOMAIN, encoded[:80])
    if encoded[80:] != root:
        _reject("retrieval policy root mismatch")
    return RetrievalPolicyV1(encoded, top_k, root)


def decode_index(encoded: bytes) -> RetrievalIndexV1:
    encoded = _exact_bytes(encoded, "retrieval index")
    if (
        len(encoded) != INDEX_BYTES
        or encoded[:8] != INDEX_MAGIC
        or _u64(encoded, 8) != INDEX_ABI
        or _u64(encoded, 16) != INDEX_BYTES
    ):
        _reject("retrieval index has invalid framing")
    generation = _u64(encoded, 24)
    corpus_count = _u64(encoded, 32)
    dimensions = _u64(encoded, 40)
    if _u64(encoded, 48) != 0 or _u64(encoded, 56) != 0:
        _reject("retrieval index reserved fields are nonzero")
    if (
        generation == 0
        or corpus_count == 0
        or corpus_count > MAXIMUM_CORPUS_ITEMS
        or dimensions == 0
        or dimensions > MAXIMUM_EMBEDDING_DIMENSIONS
    ):
        _reject("retrieval index geometry is invalid")
    digests = tuple(encoded[offset : offset + 32] for offset in range(64, 224, 32))
    for number, digest in enumerate(digests):
        _nonzero_digest(digest, f"retrieval index digest {number}")
    root = _domain_root(INDEX_DOMAIN, encoded[:224])
    if encoded[224:] != root:
        _reject("retrieval index root mismatch")
    return RetrievalIndexV1(
        encoded,
        generation,
        corpus_count,
        dimensions,
        *digests,
        root,
    )


def decode_query_binding(encoded: bytes) -> QueryBindingV1:
    encoded = _exact_bytes(encoded, "query binding")
    if (
        len(encoded) != QUERY_BINDING_BYTES
        or encoded[:8] != QUERY_BINDING_MAGIC
        or _u64(encoded, 8) != QUERY_BINDING_ABI
        or _u64(encoded, 16) != QUERY_BINDING_BYTES
    ):
        _reject("query binding has invalid framing")
    query_tenant = _u64(encoded, 24)
    dimensions = _u64(encoded, 32)
    if any(_u64(encoded, offset) != 0 for offset in (40, 48, 56)):
        _reject("query binding reserved fields are nonzero")
    if dimensions == 0 or dimensions > MAXIMUM_EMBEDDING_DIMENSIONS:
        _reject("query binding dimensions are invalid")
    digests = tuple(encoded[offset : offset + 32] for offset in range(64, 288, 32))
    for number, digest in enumerate(digests):
        _nonzero_digest(digest, f"query binding digest {number}")
    root = _domain_root(QUERY_BINDING_DOMAIN, encoded[:288])
    if encoded[288:] != root:
        _reject("query binding root mismatch")
    return QueryBindingV1(encoded, query_tenant, dimensions, *digests, root)


def decode_embedding_matrix(
    encoded: bytes,
    batch_map: BatchMapV1,
    policy: EmbeddingPolicyV1,
    dimensions: int,
) -> EmbeddingMatrixV1:
    encoded = _exact_bytes(encoded, "embedding matrix")
    dimensions = _exact_int(dimensions, "embedding dimensions")
    if dimensions <= 0 or dimensions > MAXIMUM_EMBEDDING_DIMENSIONS:
        _reject("embedding dimensions are outside the profile")
    expected = batch_map.item_count * dimensions * 4
    if len(encoded) != expected:
        _reject("embedding matrix length does not match its shape")
    components = tuple(
        int.from_bytes(encoded[offset : offset + 4], "little", signed=True)
        for offset in range(0, len(encoded), 4)
    )
    for row_index in range(batch_map.item_count):
        row = components[row_index * dimensions : (row_index + 1) * dimensions]
        if not any(row):
            _reject("embedding matrix contains a zero row")
        if any(abs(component) > Q30_SCALE for component in row):
            _reject("embedding component exceeds the signed Q30 unit bound")
    root = _domain_root(
        EMBEDDING_MATRIX_DOMAIN,
        batch_map.batch_map_sha256
        + policy.embedding_policy_sha256
        + _le64(batch_map.item_count)
        + _le64(dimensions)
        + encoded,
    )
    return EmbeddingMatrixV1(
        encoded,
        components,
        batch_map.item_count,
        dimensions,
        root,
    )


def downscale_q60_to_q30(value: int) -> int:
    """Round signed Q60 to signed Q30, nearest with ties to even."""

    value = _exact_int(value, "Q60 accumulator")
    divisor = 1 << 30
    quotient = value // divisor if value >= 0 else -((-value) // divisor)
    remainder = value - quotient * divisor
    twice = 2 * abs(remainder)
    if twice > divisor or (twice == divisor and abs(quotient) % 2 == 1):
        quotient += -1 if value < 0 else 1
    if quotient < I64_MIN or quotient > I64_MAX:
        _reject("Q30 score overflows signed i64")
    return quotient


def reference_retrieval(
    corpus_map: BatchMapV1,
    visibility: VisibilityMapV1,
    corpus_embedding: EmbeddingMatrixV1,
    index: RetrievalIndexV1,
    query_embedding: EmbeddingMatrixV1,
    policy: RetrievalPolicyV1,
    query_binding: QueryBindingV1,
) -> RetrievalResultV1:
    if (
        corpus_map.item_count != index.corpus_count
        or corpus_embedding.item_count != index.corpus_count
        or query_embedding.item_count != 1
        or corpus_embedding.dimensions != index.dimensions
        or query_embedding.dimensions != index.dimensions
        or query_binding.dimensions != index.dimensions
    ):
        _reject("retrieval composition geometry mismatch")
    eligible: list[tuple[int, int, int]] = []
    dimensions = index.dimensions
    query = query_embedding.components[:dimensions]
    for ordinal, item_id in enumerate(corpus_map.item_ids):
        scope = visibility.tenant_scopes[ordinal]
        if scope != 0 and scope != query_binding.query_tenant:
            continue
        row = corpus_embedding.components[
            ordinal * dimensions : (ordinal + 1) * dimensions
        ]
        score = downscale_q60_to_q30(
            sum(left * right for left, right in zip(query, row))
        )
        eligible.append((item_id, ordinal, score))
    if policy.top_k > len(eligible):
        _reject("retrieval top_k exceeds the visible corpus")
    eligible.sort(key=lambda value: (-value[2], value[1]))
    hits = tuple(
        RetrievalHitV1(rank, item_id, ordinal, score)
        for rank, (item_id, ordinal, score) in enumerate(
            eligible[: policy.top_k]
        )
    )
    output = bytearray(corpus_map.item_count * RETRIEVAL_HIT_BYTES)
    for hit_index, hit in enumerate(hits):
        offset = hit_index * RETRIEVAL_HIT_BYTES
        body = bytearray(RETRIEVAL_HIT_BODY_BYTES)
        body[:32] = struct.pack(
            "<QQQq",
            hit.item_id,
            hit.corpus_ordinal,
            hit.rank,
            hit.score_q30,
        )
        output[offset : offset + RETRIEVAL_HIT_BODY_BYTES] = body
        output[
            offset
            + RETRIEVAL_HIT_BODY_BYTES : offset
            + RETRIEVAL_HIT_BYTES
        ] = hashlib.sha256(
            RETRIEVAL_HIT_DOMAIN
            + index.index_descriptor_sha256
            + query_binding.query_binding_sha256
            + policy.retrieval_policy_sha256
            + body
        ).digest()
    encoded = bytes(output)
    result_root = hashlib.sha256(
        RETRIEVAL_RESULT_DOMAIN
        + index.index_descriptor_sha256
        + query_binding.query_binding_sha256
        + policy.retrieval_policy_sha256
        + _le64(index.corpus_count)
        + _le64(index.dimensions)
        + _le64(policy.top_k)
        + encoded
    ).digest()
    return RetrievalResultV1(encoded, hits, result_root)


def _mix64(value: int) -> int:
    value &= MASK64
    value ^= value >> 30
    value = (value * 0xBF58_476D_1CE4_E5B9) & MASK64
    value ^= value >> 27
    value = (value * 0x94D0_49BB_1331_11EB) & MASK64
    value ^= value >> 31
    return value & MASK64


def _receipt_integrity(claim: tuple[int, ...]) -> int:
    result = _mix64(REFERENCE_RECEIPT_DOMAIN ^ REFERENCE_BANK_EPOCH)
    for value in (0, 1, REFERENCE_OWNER_KEY, *claim):
        result = _mix64(result ^ value)
    return result


def _write_claim(
    destination: bytearray,
    offset: int,
    claim: tuple[int, ...],
) -> None:
    if len(claim) != 10:
        _reject("resource claim must contain ten fields")
    for index, value in enumerate(claim):
        _put_u64(destination, offset + index * 8, value)


def _lifecycle_roots(
    index: RetrievalIndexV1,
    query_binding: QueryBindingV1,
    corpus_map: BatchMapV1,
    query_map: BatchMapV1,
    embedding_policy: EmbeddingPolicyV1,
    retrieval_policy: RetrievalPolicyV1,
    visibility: VisibilityMapV1,
    corpus_embedding: EmbeddingMatrixV1,
    query_embedding: EmbeddingMatrixV1,
    packed_weights: bytes,
    output: bytes,
) -> tuple[bytes, bytes]:
    ownership = hashlib.sha256(b"reference retrieval ownership").digest()
    binding_without_bundle = (
        query_binding.query_object_sha256,
        query_map.batch_map_sha256,
        embedding_policy.embedding_policy_sha256,
        query_embedding.embedding_matrix_sha256,
        index.index_descriptor_sha256,
        corpus_map.batch_map_sha256,
        corpus_embedding.embedding_matrix_sha256,
        retrieval_policy.retrieval_policy_sha256,
        visibility.visibility_sha256,
        query_binding.query_binding_sha256,
        ownership,
        query_binding.challenge_sha256,
    )
    input_bundle = hashlib.sha256(
        INPUT_BUNDLE_DOMAIN + b"".join(binding_without_bundle)
    ).digest()
    all_binding_fields = (
        *binding_without_bundle[:10],
        input_bundle,
        *binding_without_bundle[10:],
    )

    output_bytes = len(output)
    claim = (
        len(packed_weights),
        0,
        len(query_embedding.encoded),
        output_bytes,
        0,
        output_bytes,
        0,
        0,
        0,
        1,
    )
    source_mapping = hashlib.sha256(
        SOURCE_MAPPING_DOMAIN
        + b"".join(all_binding_fields)
        + b"".join(
            _le64(value)
            for value in (
                REFERENCE_REQUEST_EPOCH,
                REFERENCE_GENERATION,
                0,
                1,
                index.dimensions,
                output_bytes,
            )
        )
    ).digest()

    weights_root = hashlib.sha256(packed_weights).digest()
    artifact_body = bytearray(288)
    artifact_body[:8] = ARTIFACT_MAGIC
    for offset, value in (
        (8, ARTIFACT_ABI),
        (16, 320),
        (24, 0),
        (32, MODEL_FAMILY_RETRIEVAL),
        (40, ARTIFACT_RETRIEVAL_ABI),
        (48, INPUT_KIND_EMBEDDING_I32),
        (56, OUTPUT_KIND_RETRIEVAL_HITS),
        (64, NUMERICAL_POLICY_EXACT_INTEGER),
        (72, 1),
        (80, index.dimensions),
        (88, output_bytes),
        (96, len(packed_weights)),
        (104, len(packed_weights)),
        (208, 1),
        (216, 4),
        (224, 1),
    ):
        _put_u64(artifact_body, offset, value)
    artifact_body[112:144] = weights_root
    artifact_body[144:176] = hashlib.sha256(index.encoded).digest()
    artifact_body[176:208] = hashlib.sha256(
        b"fixture-only generated data license"
    ).digest()
    artifact_root = _domain_root(ARTIFACT_DOMAIN, bytes(artifact_body))

    plan_body = bytearray(736)
    plan_body[:8] = PLAN_MAGIC
    for offset, value in (
        (8, PLAN_ABI),
        (16, 768),
        (24, 0),
        (32, MODEL_FAMILY_RETRIEVAL),
        (40, OPERATION_RETRIEVE),
        (48, INPUT_KIND_EMBEDDING_I32),
        (56, OUTPUT_KIND_RETRIEVAL_HITS),
        (64, NUMERICAL_POLICY_EXACT_INTEGER),
        (72, REFERENCE_REQUEST_EPOCH),
        (80, REFERENCE_GENERATION),
        (88, 1),
        (96, index.dimensions),
        (104, output_bytes),
        (112, len(query_embedding.encoded)),
        (120, output_bytes),
        (128, output_bytes),
        (136, 0),
        (144, 0),
        (152, Q30_SCALE),
        (160, len(packed_weights)),
        (640, 4),
        (648, 1),
    ):
        _put_u64(plan_body, offset, value)
    _write_claim(plan_body, 176, claim)
    plan_digests = (
        artifact_root,
        weights_root,
        query_binding.query_object_sha256,
        query_map.batch_map_sha256,
        embedding_policy.embedding_policy_sha256,
        input_bundle,
        query_embedding.embedding_matrix_sha256,
        ownership,
        query_binding.challenge_sha256,
        hashlib.sha256(b"reference retrieval genesis plan").digest(),
        query_binding.query_binding_sha256,
        retrieval_policy.retrieval_policy_sha256,
    )
    for index_value, digest in enumerate(plan_digests):
        start = 256 + index_value * 32
        plan_body[start : start + 32] = digest
    plan_root = _domain_root(PLAN_DOMAIN, bytes(plan_body))

    implementation = hashlib.sha256(
        b"reference exact q30 fixed corpus retrieval v1"
    ).digest()
    adapter_root = hashlib.sha256(
        ADAPTER_DOMAIN
        + b"".join(
            _le64(value)
            for value in (
                REFERENCE_ADAPTER_ABI,
                MODEL_FAMILY_RETRIEVAL,
                OPERATION_RETRIEVE,
                INPUT_KIND_EMBEDDING_I32,
                OUTPUT_KIND_RETRIEVAL_HITS,
                NUMERICAL_POLICY_EXACT_INTEGER,
                1,
                index.dimensions,
                output_bytes,
                0,
            )
        )
        + implementation
    ).digest()
    state_before = hashlib.sha256(
        PUBLICATION_STATE_DOMAIN
        + _le64(REFERENCE_REQUEST_EPOCH)
        + _le64(0)
        + _le64(0)
        + artifact_root
        + bytes(32)
    ).digest()
    output_root = hashlib.sha256(output).digest()
    publication_commit = hashlib.sha256(
        PUBLICATION_COMMIT_DOMAIN
        + state_before
        + plan_root
        + output_root
        + source_mapping
        + bytes(32)
        + adapter_root
        + _le64(0)
    ).digest()

    result_body = bytearray(736)
    result_body[:8] = RESULT_MAGIC
    for offset, value in (
        (8, RESULT_ABI),
        (16, 768),
        (24, 0),
        (32, MODEL_FAMILY_RETRIEVAL),
        (40, OPERATION_RETRIEVE),
        (48, OUTPUT_KIND_RETRIEVAL_HITS),
        (56, NUMERICAL_POLICY_EXACT_INTEGER),
        (64, REFERENCE_REQUEST_EPOCH),
        (72, REFERENCE_GENERATION),
        (80, 0),
        (88, 1),
        (96, output_bytes),
        (104, output_bytes),
        (112, REFERENCE_BANK_EPOCH),
        (120, 0),
        (128, 1),
        (136, REFERENCE_OWNER_KEY),
        (224, _receipt_integrity(claim)),
        (232, 1),
    ):
        _put_u64(result_body, offset, value)
    _write_claim(result_body, 144, claim)
    result_digests = (
        artifact_root,
        plan_root,
        query_binding.query_object_sha256,
        query_map.batch_map_sha256,
        input_bundle,
        query_embedding.embedding_matrix_sha256,
        ownership,
        output_root,
        source_mapping,
        query_binding.challenge_sha256,
        bytes(32),
        state_before,
        publication_commit,
        adapter_root,
    )
    for index_value, digest in enumerate(result_digests):
        start = 240 + index_value * 32
        result_body[start : start + 32] = digest
    return source_mapping, _domain_root(RESULT_DOMAIN, bytes(result_body))


def _require_reference_fixture(
    corpus_map: BatchMapV1,
    query_map: BatchMapV1,
    policy: RetrievalPolicyV1,
    visibility: VisibilityMapV1,
    index: RetrievalIndexV1,
    query_binding: QueryBindingV1,
    corpus_embedding: EmbeddingMatrixV1,
    query_embedding: EmbeddingMatrixV1,
) -> None:
    expected = (
        corpus_map.item_ids == REFERENCE_CORPUS_IDS
        and query_map.item_ids == REFERENCE_QUERY_IDS
        and visibility.tenant_scopes == REFERENCE_VISIBILITY
        and index.generation == REFERENCE_GENERATION
        and index.dimensions == REFERENCE_DIMENSIONS
        and policy.top_k == REFERENCE_TOP_K
        and query_binding.query_tenant == REFERENCE_QUERY_TENANT
        and corpus_embedding.components == REFERENCE_CORPUS_COMPONENTS
        and query_embedding.components == REFERENCE_QUERY_COMPONENTS
        and index.index_id_sha256
        == hashlib.sha256(b"reference fixed corpus index").digest()
        and query_binding.query_object_sha256
        == hashlib.sha256(b"reference retrieval query object").digest()
        and query_binding.challenge_sha256
        == hashlib.sha256(b"reference retrieval challenge").digest()
    )
    if not expected:
        _reject("demo evidence is not the frozen retrieval reference fixture")


def verify_demo_document(document: object) -> VerifiedDemoV1:
    """Verify the exact fixed-corpus retrieval JSON document."""

    if not isinstance(document, dict) or set(document) != DEMO_FIELDS:
        _reject("demo JSON fields do not match the canonical schema")
    if document["schema"] != DEMO_SCHEMA:
        _reject("demo schema mismatch")
    if document["verified"] is not True:
        _reject("demo did not declare verified=true")

    corpus_map_bytes = _canonical_hex(document["corpus_map_hex"], "corpus_map_hex")
    query_map_bytes = _canonical_hex(document["query_map_hex"], "query_map_hex")
    embedding_policy_bytes = _canonical_hex(
        document["embedding_policy_hex"], "embedding_policy_hex"
    )
    retrieval_policy_bytes = _canonical_hex(
        document["retrieval_policy_hex"], "retrieval_policy_hex"
    )
    visibility_bytes = _canonical_hex(document["visibility_hex"], "visibility_hex")
    index_bytes = _canonical_hex(document["index_hex"], "index_hex")
    query_binding_bytes = _canonical_hex(
        document["query_binding_hex"], "query_binding_hex"
    )
    packed_weights = _canonical_hex(
        document["packed_weights_hex"], "packed_weights_hex"
    )
    query_embedding_bytes = _canonical_hex(
        document["query_embedding_hex"], "query_embedding_hex"
    )
    retrieval_result_bytes = _canonical_hex(
        document["retrieval_result_hex"], "retrieval_result_hex"
    )

    corpus_map = decode_batch_map(corpus_map_bytes)
    query_map = decode_batch_map(query_map_bytes)
    embedding_policy = decode_embedding_policy(embedding_policy_bytes)
    retrieval_policy = decode_retrieval_policy(retrieval_policy_bytes)
    visibility = decode_visibility_map(visibility_bytes, corpus_map)
    index = decode_index(index_bytes)
    query_binding = decode_query_binding(query_binding_bytes)
    if query_map.item_count != 1 or query_binding.query_tenant == 0:
        _reject("retrieval requires one query and a nonzero tenant")
    if len(packed_weights) <= INDEX_BYTES or packed_weights[:INDEX_BYTES] != index_bytes:
        _reject("packed weights do not begin with the exact index wire")
    corpus_embedding = decode_embedding_matrix(
        packed_weights[INDEX_BYTES:],
        corpus_map,
        embedding_policy,
        index.dimensions,
    )
    query_embedding = decode_embedding_matrix(
        query_embedding_bytes,
        query_map,
        embedding_policy,
        index.dimensions,
    )

    if (
        index.corpus_count != corpus_map.item_count
        or index.corpus_map_sha256 != corpus_map.batch_map_sha256
        or index.visibility_sha256 != visibility.visibility_sha256
        or index.embedding_policy_sha256
        != embedding_policy.embedding_policy_sha256
        or index.corpus_embedding_sha256
        != corpus_embedding.embedding_matrix_sha256
        or query_binding.dimensions != index.dimensions
        or query_binding.query_map_sha256 != query_map.batch_map_sha256
        or query_binding.embedding_policy_sha256
        != embedding_policy.embedding_policy_sha256
        or query_binding.query_embedding_sha256
        != query_embedding.embedding_matrix_sha256
        or query_binding.index_descriptor_sha256
        != index.index_descriptor_sha256
        or query_binding.retrieval_policy_sha256
        != retrieval_policy.retrieval_policy_sha256
    ):
        _reject("retrieval evidence roots do not compose")

    _require_reference_fixture(
        corpus_map,
        query_map,
        retrieval_policy,
        visibility,
        index,
        query_binding,
        corpus_embedding,
        query_embedding,
    )
    expected_result = reference_retrieval(
        corpus_map,
        visibility,
        corpus_embedding,
        index,
        query_embedding,
        retrieval_policy,
        query_binding,
    )
    if retrieval_result_bytes != expected_result.encoded:
        _reject("retrieval result is not the exact independently recomputed top-k")

    declared_output = _canonical_digest_hex(
        document["output_sha256"], "output_sha256"
    )
    if declared_output != hashlib.sha256(retrieval_result_bytes).digest():
        _reject("output_sha256 does not bind the exact result wire")
    declared_retrieval_root = _canonical_digest_hex(
        document["retrieval_result_sha256"],
        "retrieval_result_sha256",
    )
    if declared_retrieval_root != expected_result.retrieval_result_sha256:
        _reject("retrieval_result_sha256 contextual root mismatch")
    declared_hits = _decode_declared_hits(document["hits"])
    if declared_hits != expected_result.hits:
        _reject("declared hits do not match the verified result wire")

    source_mapping, result_root = _lifecycle_roots(
        index,
        query_binding,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        corpus_embedding,
        query_embedding,
        packed_weights,
        retrieval_result_bytes,
    )
    declared_source = _canonical_digest_hex(
        document["source_mapping_sha256"], "source_mapping_sha256"
    )
    declared_result = _canonical_digest_hex(
        document["result_sha256"], "result_sha256"
    )
    if declared_source != source_mapping:
        _reject("source_mapping_sha256 does not match the frozen plan binding")
    if declared_result != result_root:
        _reject("result_sha256 does not match the canonical result envelope")
    return VerifiedDemoV1(
        corpus_map,
        query_map,
        index,
        query_binding,
        expected_result,
        declared_output,
        declared_source,
        declared_result,
    )


def _decode_declared_hits(value: object) -> tuple[RetrievalHitV1, ...]:
    if not isinstance(value, list):
        _reject("hits must be an array")
    hits: list[RetrievalHitV1] = []
    for item in value:
        if not isinstance(item, dict) or set(item) != HIT_FIELDS:
            _reject("hit fields do not match the canonical schema")
        rank = _bounded_integer(item["rank"], "rank", 0, U64_MAX)
        item_id = _bounded_integer(item["item_id"], "item_id", 0, U64_MAX)
        ordinal = _bounded_integer(
            item["corpus_ordinal"], "corpus_ordinal", 0, U64_MAX
        )
        score = _bounded_integer(item["score_q30"], "score_q30", I64_MIN, I64_MAX)
        hits.append(RetrievalHitV1(rank, item_id, ordinal, score))
    return tuple(hits)


def _bounded_integer(value: object, label: str, low: int, high: int) -> int:
    result = _exact_int(value, label)
    if result < low or result > high:
        _reject(f"{label} is outside its integer range")
    return result


def _canonical_hex(value: object, label: str) -> bytes:
    if not isinstance(value, str) or len(value) % 2:
        _reject(f"{label} must be an even-length lowercase hex string")
    if any(character not in "0123456789abcdef" for character in value):
        _reject(f"{label} must be canonical lowercase hex")
    return bytes.fromhex(value)


def _canonical_digest_hex(value: object, label: str) -> bytes:
    digest = _canonical_hex(value, label)
    if len(digest) != 32:
        _reject(f"{label} must encode exactly 32 bytes")
    return digest


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            _reject(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def _invalid_json_constant(value: str) -> NoReturn:
    _reject(f"non-finite JSON number: {value}")


def _run_demo(
    path: str | os.PathLike[str],
    arguments: Sequence[str],
) -> VerifiedDemoV1:
    executable = os.fspath(path)
    if not executable:
        _reject("demo path must not be empty")
    try:
        completed = subprocess.run(
            [executable, *arguments],
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


def run_demo(path: str | os.PathLike[str]) -> VerifiedDemoV1:
    """Run a standalone retrieval demo with no arguments."""

    return _run_demo(path, ())


def run_shared_demo(path: str | os.PathLike[str]) -> VerifiedDemoV1:
    """Run the shared dense-tensor demo in explicit retrieval mode."""

    return _run_demo(path, ("retrieve",))


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Independently verify the dense-tensor retrieval demo",
    )
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument(
        "--demo",
        type=Path,
        metavar="PATH",
        help="standalone retrieval demo (invoked without arguments)",
    )
    modes.add_argument(
        "--shared-demo",
        type=Path,
        metavar="PATH",
        help="shared dense-tensor demo (invoked with 'retrieve')",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _argument_parser().parse_args(argv)
    try:
        verified = (
            run_demo(arguments.demo)
            if arguments.demo is not None
            else run_shared_demo(arguments.shared_demo)
        )
    except OracleError as error:
        print(f"stateless retrieval verification failed: {error}", file=sys.stderr)
        return 1
    receipt = {
        "schema": VERIFICATION_SCHEMA,
        "hits": len(verified.retrieval_result.hits),
        "output_sha256": verified.output_sha256.hex(),
        "result_sha256": verified.result_sha256.hex(),
        "retrieval_result_sha256": (
            verified.retrieval_result.retrieval_result_sha256.hex()
        ),
        "source_mapping_sha256": verified.source_mapping_sha256.hex(),
        "verified": True,
    }
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
