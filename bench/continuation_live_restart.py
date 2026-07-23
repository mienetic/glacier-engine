"""Independent live-runtime wire and resumed publication-chain verifier."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class LiveRestartError(ValueError):
    """The runtime state or resumed publication is invalid."""


Record = dict[str, Any]
MAGIC = b"GCLIVE01"
RUNTIME_STATE_ABI = 0x47434C5200000001
RESUME_RECEIPT_ABI = 0x47434C4300000001
RUNTIME_STATE_BYTES = 304
RUNTIME_STATE_BODY_BYTES = 272
MAX_OUTPUT_TOKENS = 16
ALLOWED_FLAGS = 0
RUNTIME_STATE_DOMAIN = b"glacier-continuation-live-runtime-state-v1\x00"
OUTPUT_STATE_DOMAIN = b"glacier-continuation-live-output-v1\x00"
RESUME_RECEIPT_DOMAIN = (
    b"glacier-continuation-live-resume-receipt-v1\x00"
)
PAGE_MAP_ROOT_ABI = 0x47504D5200000001
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise LiveRestartError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise LiveRestartError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise LiveRestartError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def runtime_state_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise LiveRestartError("invalid runtime body")
    return _hash(RUNTIME_STATE_DOMAIN, body)


def output_state_root(tokens: list[int]) -> bytes:
    return _hash(
        OUTPUT_STATE_DOMAIN,
        _u64(len(tokens)),
        *(_u32(token) for token in tokens),
    )


def encode(state: Record) -> bytes:
    checked = _state(state)
    body = b"".join(
        (
            MAGIC,
            _u64(RUNTIME_STATE_ABI),
            _u64(RUNTIME_STATE_BYTES),
            _u32(ALLOWED_FLAGS),
            _u32(0),
            _u64(checked["request_epoch"]),
            _u64(checked["publication_next_sequence"]),
            _u64(checked["checkpoint_generation"]),
            _u64(checked["kv_tokens"]),
            _u64(checked["output_token_count"]),
            _u64(checked["sampling_calls"]),
            *(_u64(word) for word in checked["rng_state"]),
            checked["previous_commit_sha256"],
            checked["logical_kv_sha256"],
            checked["challenge_sha256"],
            *(_u32(token) for token in checked["output_tokens"]),
        )
    )
    if len(body) != RUNTIME_STATE_BODY_BYTES:
        raise LiveRestartError("internal runtime length mismatch")
    return body + runtime_state_root(body)


def decode(encoded: bytes) -> Record:
    if not isinstance(encoded, bytes) or len(encoded) != RUNTIME_STATE_BYTES:
        raise LiveRestartError("invalid runtime length")
    if encoded[:8] != MAGIC:
        raise LiveRestartError("invalid runtime magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != RUNTIME_STATE_ABI:
        raise LiveRestartError("invalid runtime ABI")
    if struct.unpack_from("<Q", encoded, 16)[0] != len(encoded):
        raise LiveRestartError("runtime size mismatch")
    if (
        struct.unpack_from("<I", encoded, 24)[0] != ALLOWED_FLAGS
        or struct.unpack_from("<I", encoded, 28)[0] != 0
    ):
        raise LiveRestartError("invalid runtime flags")
    if encoded[-32:] != runtime_state_root(encoded[:-32]):
        raise LiveRestartError("runtime root mismatch")

    cursor = 32

    def read_u64() -> int:
        nonlocal cursor
        result = struct.unpack_from("<Q", encoded, cursor)[0]
        cursor += 8
        return result

    def read_digest() -> bytes:
        nonlocal cursor
        result = encoded[cursor : cursor + 32]
        cursor += 32
        return result

    state: Record = {
        "request_epoch": read_u64(),
        "publication_next_sequence": read_u64(),
        "checkpoint_generation": read_u64(),
        "kv_tokens": read_u64(),
        "output_token_count": read_u64(),
        "sampling_calls": read_u64(),
        "rng_state": [read_u64() for _ in range(4)],
        "previous_commit_sha256": read_digest(),
        "logical_kv_sha256": read_digest(),
        "challenge_sha256": read_digest(),
        "output_tokens": [
            struct.unpack_from("<I", encoded, cursor + index * 4)[0]
            for index in range(MAX_OUTPUT_TOKENS)
        ],
    }
    cursor += MAX_OUTPUT_TOKENS * 4
    if cursor != RUNTIME_STATE_BODY_BYTES:
        raise LiveRestartError("runtime header mismatch")
    return _state(state)


def resume_receipt_root(receipt: Record) -> bytes:
    before = _root(receipt["root_before"])
    after = _root(receipt["root_after"])
    return _hash(
        RESUME_RECEIPT_DOMAIN,
        _u64(RESUME_RECEIPT_ABI),
        _u64(receipt["request_epoch"]),
        _u64(receipt["transaction_sequence"]),
        _u64(receipt["permit_generation"]),
        _u64(receipt["checkpoint_generation"]),
        _u32(receipt["token_id"]),
        _root_bytes(before),
        _root_bytes(after),
        _digest(receipt["logical_kv_before_sha256"]),
        _digest(receipt["logical_kv_after_sha256"]),
        *(_u64(word) for word in receipt["rng_before"]),
        *(_u64(word) for word in receipt["rng_after"]),
        _u64(receipt["sampling_calls_before"]),
        _u64(receipt["sampling_calls_after"]),
        _u64(receipt["output_before"]),
        _u64(receipt["output_after"]),
        _digest(receipt["output_sha256"]),
        _digest(receipt["previous_commit_sha256"]),
        _digest(receipt["challenge_sha256"]),
    )


def advance(
    state: Record,
    *,
    token_id: int,
    rng_after: list[int],
    sampling_calls_after: int,
    root_before: Record,
    root_after: Record,
    logical_kv_after_sha256: bytes,
    permit_generation: int,
) -> tuple[Record, Record]:
    """Verify and derive one no-duplicate resumed publication."""
    current = _state(state)
    before = _root(root_before)
    after = _root(root_after)
    _u32(token_id)
    if (
        current["publication_next_sequence"] == U64_MAX
        or current["kv_tokens"] == U64_MAX
        or current["sampling_calls"] == U64_MAX
        or current["output_token_count"] >= MAX_OUTPUT_TOKENS
        or len(rng_after) != 4
        or not all(isinstance(word, int) for word in rng_after)
        or sampling_calls_after
        not in {
            current["sampling_calls"],
            current["sampling_calls"] + 1,
        }
        or (
            sampling_calls_after == current["sampling_calls"]
            and rng_after != current["rng_state"]
        )
        or before["committed_len"] != current["kv_tokens"]
        or after["committed_len"] != current["kv_tokens"] + 1
        or before["cache_instance"] != after["cache_instance"]
        or before["generation"] >= after["generation"]
        or permit_generation == 0
    ):
        raise LiveRestartError("invalid resumed publication")
    logical_after = _digest(logical_kv_after_sha256)
    outputs = list(current["output_tokens"])
    output_before = current["output_token_count"]
    outputs[output_before] = token_id
    output_after = output_before + 1
    receipt: Record = {
        "request_epoch": current["request_epoch"],
        "transaction_sequence": current["publication_next_sequence"],
        "permit_generation": permit_generation,
        "checkpoint_generation": current["checkpoint_generation"],
        "token_id": token_id,
        "root_before": before,
        "root_after": after,
        "logical_kv_before_sha256": current["logical_kv_sha256"],
        "logical_kv_after_sha256": logical_after,
        "rng_before": list(current["rng_state"]),
        "rng_after": list(rng_after),
        "sampling_calls_before": current["sampling_calls"],
        "sampling_calls_after": sampling_calls_after,
        "output_before": output_before,
        "output_after": output_after,
        "output_sha256": output_state_root(outputs[:output_after]),
        "previous_commit_sha256": current["previous_commit_sha256"],
        "challenge_sha256": current["challenge_sha256"],
    }
    receipt["commit_sha256"] = resume_receipt_root(receipt)
    next_state = {
        **current,
        "publication_next_sequence": (
            current["publication_next_sequence"] + 1
        ),
        "kv_tokens": current["kv_tokens"] + 1,
        "output_token_count": output_after,
        "sampling_calls": sampling_calls_after,
        "rng_state": list(rng_after),
        "previous_commit_sha256": receipt["commit_sha256"],
        "logical_kv_sha256": logical_after,
        "output_tokens": outputs,
    }
    return _state(next_state), receipt


def _state(value: Record) -> Record:
    try:
        outputs = list(value["output_tokens"])
        rng = list(value["rng_state"])
        result: Record = {
            "request_epoch": value["request_epoch"],
            "publication_next_sequence": value[
                "publication_next_sequence"
            ],
            "checkpoint_generation": value["checkpoint_generation"],
            "kv_tokens": value["kv_tokens"],
            "output_token_count": value["output_token_count"],
            "sampling_calls": value["sampling_calls"],
            "rng_state": rng,
            "previous_commit_sha256": _digest(
                value["previous_commit_sha256"]
            ),
            "logical_kv_sha256": _digest(value["logical_kv_sha256"]),
            "challenge_sha256": _digest(value["challenge_sha256"]),
            "output_tokens": outputs,
        }
    except (KeyError, TypeError) as exc:
        raise LiveRestartError("invalid runtime state") from exc
    for name in (
        "request_epoch",
        "publication_next_sequence",
        "checkpoint_generation",
        "kv_tokens",
        "output_token_count",
        "sampling_calls",
    ):
        _u64(result[name])
    if (
        len(rng) != 4
        or any(not isinstance(word, int) for word in rng)
        or len(outputs) != MAX_OUTPUT_TOKENS
    ):
        raise LiveRestartError("invalid runtime vectors")
    for word in rng:
        _u64(word)
    for token in outputs:
        _u32(token)
    count = result["output_token_count"]
    if (
        result["request_epoch"] == 0
        or result["publication_next_sequence"] == 0
        or result["checkpoint_generation"] == 0
        or result["kv_tokens"] == 0
        or not 0 < count <= MAX_OUTPUT_TOKENS
        or count > result["kv_tokens"]
        or rng == [0, 0, 0, 0]
        or result["previous_commit_sha256"] == ZERO_DIGEST
        or result["logical_kv_sha256"] == ZERO_DIGEST
        or result["challenge_sha256"] == ZERO_DIGEST
        or any(outputs[count:])
    ):
        raise LiveRestartError("invalid runtime semantics")
    return result


def _root(value: Record) -> Record:
    try:
        result = {
            name: value[name]
            for name in (
                "abi_version",
                "cache_instance",
                "generation",
                "committed_len",
                "committed_pages",
            )
        }
        result["ownership_sha256"] = _digest(
            value["ownership_sha256"]
        )
    except (KeyError, TypeError) as exc:
        raise LiveRestartError("invalid page root") from exc
    for name in result:
        if name != "ownership_sha256":
            _u64(result[name])
    if (
        result["abi_version"] != PAGE_MAP_ROOT_ABI
        or result["cache_instance"] == 0
        or result["generation"] == 0
        or result["ownership_sha256"] == ZERO_DIGEST
    ):
        raise LiveRestartError("invalid page root")
    return result


def _root_bytes(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u64(value["cache_instance"]),
            _u64(value["generation"]),
            _u64(value["committed_len"]),
            _u64(value["committed_pages"]),
            value["ownership_sha256"],
        )
    )
