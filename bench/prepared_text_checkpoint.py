"""Independent verifier for canonical prepared-text checkpoint images."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class PreparedTextCheckpointError(ValueError):
    """The checkpoint is malformed or does not match trusted bindings."""


Record = dict[str, Any]
MAGIC = b"GLTCKP01"
CHECKPOINT_ABI = 0x474C544B00000001
CONTIGUOUS_ABI = 0x474C434F00000001
RNG_STATE_ABI = 0x474C435200000001
STATE_COMMITMENT_ABI = 0x474C505300000001
HEADER_BYTES = 544
FOOTER_BYTES = 32
ALLOWED_FLAGS = 0
U64_MAX = (1 << 64) - 1
U32_SPACE = 1 << 32
ZERO_DIGEST = bytes(32)

CHECKPOINT_DOMAIN = b"glacier-prepared-text-checkpoint-state-v1\x00"
LOGICAL_KV_DOMAIN = b"glacier-logical-kv-state-v1\x00"
KV_ROW_DOMAIN = b"glacier-contiguous-kv-row-v1\x00"
RNG_DOMAIN = b"glacier-contiguous-rng-state-v1\x00"
OUTPUT_ROOT_DOMAIN = b"glacier-contiguous-output-root-v1\x00"
STATE_DOMAIN = b"glacier-lane-publication-state-v1\x00"
KV_CHAIN_DOMAIN = b"glacier-lane-publication-kv-v1\x00"
OUTPUT_CHAIN_DOMAIN = b"glacier-lane-publication-output-v1\x00"

ROOT_NAMES = (
    "local_plan_sha256",
    "bound_plan_sha256",
    "artifact_sha256",
    "execution_plan_sha256",
    "residency_binding_sha256",
    "boundary_sha256",
    "transcript_sha256",
    "state_commitment_sha256",
)
CONTEXT_NAMES = (
    "request_epoch",
    "publication_next_sequence",
    "prompt_tokens",
    "max_new_tokens",
    "vocab_size",
    "num_layers",
    "kv_dim",
    "max_kv_positions",
    "kv_positions",
    "output_count",
    "sampling_calls",
)


def _u8(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFF:
        raise PreparedTextCheckpointError("u8 out of range")
    return struct.pack("<B", value)


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value < U32_SPACE:
        raise PreparedTextCheckpointError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise PreparedTextCheckpointError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or value == ZERO_DIGEST
    ):
        raise PreparedTextCheckpointError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def checkpoint_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise PreparedTextCheckpointError("invalid checkpoint body")
    return _hash(CHECKPOINT_DOMAIN, body)


def rng_state_root(words: tuple[int, int, int, int]) -> bytes:
    if not isinstance(words, tuple) or len(words) != 4:
        raise PreparedTextCheckpointError("invalid RNG state")
    return _hash(RNG_DOMAIN, _u64(RNG_STATE_ABI), *map(_u64, words))


def output_state_root(tokens: tuple[int, ...]) -> bytes:
    state = _hash(OUTPUT_ROOT_DOMAIN, _u64(CONTIGUOUS_ABI))
    for index, token in enumerate(tokens):
        state = _hash(
            OUTPUT_CHAIN_DOMAIN,
            _u64(STATE_COMMITMENT_ABI),
            state,
            _u64(index),
            _u32(token),
            _u8(0),
        )
    return state


def logical_kv_root(
    num_layers: int,
    kv_dim: int,
    kv_positions: int,
    canonical_f32_le: bytes,
) -> bytes:
    _validate_kv_payload(
        num_layers,
        kv_dim,
        kv_positions,
        canonical_f32_le,
    )
    return _hash(
        LOGICAL_KV_DOMAIN,
        _u64(num_layers),
        _u64(kv_dim),
        _u64(kv_positions),
        canonical_f32_le,
    )


def _kv_bits_at(
    payload: bytes,
    num_layers: int,
    kv_dim: int,
    kv_positions: int,
    layer: int,
    values: bool,
    position: int,
    dimension: int,
) -> int:
    if (
        not 0 <= layer < num_layers
        or not 0 <= position < kv_positions
        or not 0 <= dimension < kv_dim
    ):
        raise PreparedTextCheckpointError("KV coordinate out of range")
    plane = kv_positions * kv_dim
    element = layer * plane * 2
    if values:
        element += plane
    element += position * kv_dim + dimension
    return struct.unpack_from("<I", payload, element * 4)[0]


def incremental_kv_state_root(
    num_layers: int,
    kv_dim: int,
    kv_positions: int,
    prompt_tokens: int,
    canonical_f32_le: bytes,
) -> bytes:
    _validate_kv_payload(
        num_layers,
        kv_dim,
        kv_positions,
        canonical_f32_le,
    )
    if not 0 < prompt_tokens <= kv_positions:
        raise PreparedTextCheckpointError("invalid prompt/KV split")
    initial = hashlib.sha256()
    initial.update(LOGICAL_KV_DOMAIN)
    initial.update(_u64(num_layers))
    initial.update(_u64(kv_dim))
    initial.update(_u64(prompt_tokens))
    for layer in range(num_layers):
        for values in (False, True):
            for position in range(prompt_tokens):
                for dimension in range(kv_dim):
                    initial.update(
                        _u32(
                            _kv_bits_at(
                                canonical_f32_le,
                                num_layers,
                                kv_dim,
                                kv_positions,
                                layer,
                                values,
                                position,
                                dimension,
                            )
                        )
                    )
    state = initial.digest()
    for position in range(prompt_tokens, kv_positions):
        row = hashlib.sha256()
        row.update(KV_ROW_DOMAIN)
        row.update(_u64(CONTIGUOUS_ABI))
        row.update(_u64(num_layers))
        row.update(_u64(kv_dim))
        row.update(_u64(position))
        for layer in range(num_layers):
            for values in (False, True):
                for dimension in range(kv_dim):
                    row.update(
                        _u32(
                            _kv_bits_at(
                                canonical_f32_le,
                                num_layers,
                                kv_dim,
                                kv_positions,
                                layer,
                                values,
                                position,
                                dimension,
                            )
                        )
                    )
        state = _hash(
            KV_CHAIN_DOMAIN,
            _u64(STATE_COMMITMENT_ABI),
            state,
            _u64(position),
            row.digest(),
        )
    return state


def state_commitment_root(
    kv_positions: int,
    kv_state_sha256: bytes,
    rng_state_sha256: bytes,
    sampling_calls: int,
    output_count: int,
    output_state_sha256: bytes,
) -> bytes:
    return _hash(
        STATE_DOMAIN,
        _u64(STATE_COMMITMENT_ABI),
        _u64(CONTIGUOUS_ABI),
        _u64(kv_positions),
        _digest(kv_state_sha256),
        _u64(RNG_STATE_ABI),
        _digest(rng_state_sha256),
        _u64(sampling_calls),
        _u64(output_count),
        _digest(output_state_sha256),
    )


def encoded_bytes(
    num_layers: int,
    kv_dim: int,
    kv_positions: int,
    output_count: int,
) -> int:
    if min(num_layers, kv_dim, kv_positions, output_count) <= 0:
        raise PreparedTextCheckpointError("zero checkpoint geometry")
    kv_elements = num_layers * 2 * kv_positions * kv_dim
    _u64(kv_elements)
    return HEADER_BYTES + (output_count + kv_elements) * 4 + FOOTER_BYTES


def encode(value: Record) -> bytes:
    try:
        roots = tuple(_digest(value[name]) for name in ROOT_NAMES)
        request_epoch = value["request_epoch"]
        next_sequence = value["publication_next_sequence"]
        prompt_tokens = value["prompt_tokens"]
        max_new_tokens = value["max_new_tokens"]
        vocab_size = value["vocab_size"]
        num_layers = value["num_layers"]
        kv_dim = value["kv_dim"]
        max_kv_positions = value["max_kv_positions"]
        kv_positions = value["kv_positions"]
        tokens = tuple(value["output_tokens"])
        sampling_calls = value["sampling_calls"]
        rng_state = tuple(value["rng_state"])
        payload = value["canonical_kv_f32_le"]
        challenge = _digest(value["challenge_sha256"])
    except (KeyError, TypeError) as exc:
        raise PreparedTextCheckpointError("invalid checkpoint input") from exc
    _validate_scalar_state(
        request_epoch,
        next_sequence,
        prompt_tokens,
        max_new_tokens,
        vocab_size,
        num_layers,
        kv_dim,
        max_kv_positions,
        kv_positions,
        len(tokens),
        sampling_calls,
    )
    _validate_kv_payload(num_layers, kv_dim, kv_positions, payload)
    if any(not isinstance(token, int) or not 0 <= token < vocab_size for token in tokens):
        raise PreparedTextCheckpointError("output token outside vocabulary")
    output_root = output_state_root(tokens)
    rng_root = rng_state_root(rng_state)
    logical_root = logical_kv_root(
        num_layers,
        kv_dim,
        kv_positions,
        payload,
    )
    state_kv_root = incremental_kv_state_root(
        num_layers,
        kv_dim,
        kv_positions,
        prompt_tokens,
        payload,
    )
    if roots[-1] != state_commitment_root(
        kv_positions,
        state_kv_root,
        rng_root,
        sampling_calls,
        len(tokens),
        output_root,
    ):
        raise PreparedTextCheckpointError("state commitment mismatch")
    kv_elements = len(payload) // 4
    required = encoded_bytes(
        num_layers,
        kv_dim,
        kv_positions,
        len(tokens),
    )
    body = b"".join(
        (
            MAGIC,
            _u64(CHECKPOINT_ABI),
            _u64(required),
            _u32(ALLOWED_FLAGS),
            _u32(0),
            *roots,
            _u64(request_epoch),
            _u64(next_sequence),
            _u64(prompt_tokens),
            _u64(max_new_tokens),
            _u64(vocab_size),
            _u64(num_layers),
            _u64(kv_dim),
            _u64(max_kv_positions),
            _u64(kv_positions),
            _u64(len(tokens)),
            _u64(sampling_calls),
            _u64(kv_elements),
            *map(_u64, rng_state),
            output_root,
            rng_root,
            logical_root,
            challenge,
            b"".join(map(_u32, tokens)),
            payload,
        )
    )
    if len(body) != required - FOOTER_BYTES:
        raise PreparedTextCheckpointError("checkpoint length mismatch")
    return body + checkpoint_root(body)


def decode(encoded: bytes, expected: Record) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < HEADER_BYTES + FOOTER_BYTES
    ):
        raise PreparedTextCheckpointError("invalid checkpoint length")
    if encoded[:8] != MAGIC:
        raise PreparedTextCheckpointError("invalid checkpoint magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != CHECKPOINT_ABI:
        raise PreparedTextCheckpointError("invalid checkpoint ABI")
    if struct.unpack_from("<Q", encoded, 16)[0] != len(encoded):
        raise PreparedTextCheckpointError("checkpoint size mismatch")
    if (
        struct.unpack_from("<I", encoded, 24)[0] != ALLOWED_FLAGS
        or struct.unpack_from("<I", encoded, 28)[0] != 0
    ):
        raise PreparedTextCheckpointError("invalid checkpoint flags")
    if encoded[-FOOTER_BYTES:] != checkpoint_root(encoded[:-FOOTER_BYTES]):
        raise PreparedTextCheckpointError("checkpoint root mismatch")
    cursor = 32

    def read_digest() -> bytes:
        nonlocal cursor
        result = encoded[cursor : cursor + 32]
        cursor += 32
        return _digest(result)

    def read_u64() -> int:
        nonlocal cursor
        result = struct.unpack_from("<Q", encoded, cursor)[0]
        cursor += 8
        return result

    roots = {name: read_digest() for name in ROOT_NAMES}
    for name in ROOT_NAMES:
        try:
            trusted = _digest(expected[name])
        except (KeyError, TypeError) as exc:
            raise PreparedTextCheckpointError(
                "missing trusted checkpoint binding"
            ) from exc
        if roots[name] != trusted:
            raise PreparedTextCheckpointError("checkpoint binding mismatch")
    request_epoch = read_u64()
    next_sequence = read_u64()
    prompt_tokens = read_u64()
    max_new_tokens = read_u64()
    vocab_size = read_u64()
    num_layers = read_u64()
    kv_dim = read_u64()
    max_kv_positions = read_u64()
    kv_positions = read_u64()
    output_count = read_u64()
    sampling_calls = read_u64()
    kv_elements = read_u64()
    rng_state = tuple(read_u64() for _ in range(4))
    output_root = read_digest()
    rng_root = read_digest()
    logical_root = read_digest()
    challenge = read_digest()
    if cursor != HEADER_BYTES:
        raise PreparedTextCheckpointError("checkpoint header mismatch")
    context = {
        "request_epoch": request_epoch,
        "publication_next_sequence": next_sequence,
        "prompt_tokens": prompt_tokens,
        "max_new_tokens": max_new_tokens,
        "vocab_size": vocab_size,
        "num_layers": num_layers,
        "kv_dim": kv_dim,
        "max_kv_positions": max_kv_positions,
        "kv_positions": kv_positions,
        "output_count": output_count,
        "sampling_calls": sampling_calls,
    }
    for name in CONTEXT_NAMES:
        try:
            trusted = expected[name]
        except (KeyError, TypeError) as exc:
            raise PreparedTextCheckpointError(
                "missing trusted checkpoint context"
            ) from exc
        if context[name] != trusted:
            raise PreparedTextCheckpointError(
                "checkpoint context mismatch"
            )
    try:
        trusted_challenge = _digest(expected["challenge_sha256"])
    except (KeyError, TypeError) as exc:
        raise PreparedTextCheckpointError(
            "missing trusted checkpoint challenge"
        ) from exc
    if challenge != trusted_challenge:
        raise PreparedTextCheckpointError("checkpoint challenge mismatch")
    _validate_scalar_state(
        request_epoch,
        next_sequence,
        prompt_tokens,
        max_new_tokens,
        vocab_size,
        num_layers,
        kv_dim,
        max_kv_positions,
        kv_positions,
        output_count,
        sampling_calls,
    )
    if kv_elements != num_layers * 2 * kv_positions * kv_dim:
        raise PreparedTextCheckpointError("KV element count mismatch")
    required = encoded_bytes(
        num_layers,
        kv_dim,
        kv_positions,
        output_count,
    )
    if len(encoded) != required:
        raise PreparedTextCheckpointError("checkpoint geometry mismatch")
    output_bytes = output_count * 4
    kv_bytes = kv_elements * 4
    output_payload = encoded[cursor : cursor + output_bytes]
    cursor += output_bytes
    kv_payload = encoded[cursor : cursor + kv_bytes]
    cursor += kv_bytes
    footer = encoded[cursor : cursor + FOOTER_BYTES]
    cursor += FOOTER_BYTES
    if cursor != len(encoded) or footer != checkpoint_root(encoded[:-FOOTER_BYTES]):
        raise PreparedTextCheckpointError("checkpoint footer mismatch")
    tokens = tuple(
        struct.unpack_from("<I", output_payload, index * 4)[0]
        for index in range(output_count)
    )
    if any(token >= vocab_size for token in tokens):
        raise PreparedTextCheckpointError("output token outside vocabulary")
    computed_output = output_state_root(tokens)
    computed_rng = rng_state_root(rng_state)
    computed_logical = logical_kv_root(
        num_layers,
        kv_dim,
        kv_positions,
        kv_payload,
    )
    state_kv = incremental_kv_state_root(
        num_layers,
        kv_dim,
        kv_positions,
        prompt_tokens,
        kv_payload,
    )
    computed_state = state_commitment_root(
        kv_positions,
        state_kv,
        computed_rng,
        sampling_calls,
        output_count,
        computed_output,
    )
    if (
        output_root != computed_output
        or rng_root != computed_rng
        or logical_root != computed_logical
        or roots["state_commitment_sha256"] != computed_state
    ):
        raise PreparedTextCheckpointError("checkpoint state mismatch")
    return {
        **roots,
        **context,
        "kv_element_count": kv_elements,
        "rng_state": rng_state,
        "output_tokens": tokens,
        "canonical_kv_f32_le": kv_payload,
        "output_state_sha256": output_root,
        "rng_state_sha256": rng_root,
        "logical_kv_sha256": logical_root,
        "challenge_sha256": challenge,
        "checkpoint_sha256": footer,
    }


def _validate_scalar_state(
    request_epoch: int,
    next_sequence: int,
    prompt_tokens: int,
    max_new_tokens: int,
    vocab_size: int,
    num_layers: int,
    kv_dim: int,
    max_kv_positions: int,
    kv_positions: int,
    output_count: int,
    sampling_calls: int,
) -> None:
    values = (
        request_epoch,
        next_sequence,
        prompt_tokens,
        max_new_tokens,
        vocab_size,
        num_layers,
        kv_dim,
        max_kv_positions,
        kv_positions,
        output_count,
        sampling_calls,
    )
    for value in values:
        _u64(value)
    if (
        request_epoch == 0
        or not 2 <= vocab_size <= U32_SPACE
        or not 0 < output_count < max_new_tokens
        or next_sequence != output_count
        or sampling_calls != output_count
        or kv_positions != prompt_tokens + output_count - 1
        or max_kv_positions != prompt_tokens + max_new_tokens - 1
        or min(prompt_tokens, num_layers, kv_dim, kv_positions) <= 0
    ):
        raise PreparedTextCheckpointError("invalid checkpoint state")


def _validate_kv_payload(
    num_layers: int,
    kv_dim: int,
    kv_positions: int,
    payload: bytes,
) -> None:
    expected = num_layers * 2 * kv_positions * kv_dim * 4
    if not isinstance(payload, bytes) or len(payload) != expected:
        raise PreparedTextCheckpointError("invalid canonical KV payload")
