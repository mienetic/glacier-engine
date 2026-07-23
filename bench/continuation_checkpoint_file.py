"""Independent codec and phase-recovery model for checkpoint root switching."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class CheckpointFileError(ValueError):
    """The checkpoint set, selector, or recovery state is invalid."""


Record = dict[str, Any]
SET_ABI = 0x4743534500000001
SELECTOR_ABI = 0x4743535700000001
SET_MAGIC = b"GCSET01\x00"
SELECTOR_MAGIC = b"GCSWIT1\x00"
MAX_OBJECTS = 8
SET_HEADER_BYTES = 128
SET_ENTRY_BYTES = 72
SET_PAYLOAD_OFFSET = SET_HEADER_BYTES + MAX_OBJECTS * SET_ENTRY_BYTES
SET_FOOTER_BYTES = 32
SELECTOR_BYTES = 192
SELECTOR_BODY_BYTES = 160
ALLOWED_FLAGS = 0
ZERO_DIGEST = bytes(32)
SET_DOMAIN = b"glacier-continuation-checkpoint-set-v1\x00"
OBJECT_DOMAIN = b"glacier-continuation-checkpoint-object-v1\x00"
SELECTOR_DOMAIN = b"glacier-continuation-checkpoint-selector-v1\x00"
U64_MAX = (1 << 64) - 1


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise CheckpointFileError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise CheckpointFileError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def object_root(entry: Record) -> bytes:
    data = _object(entry)
    return _hash(
        OBJECT_DOMAIN,
        _u64(data["kind"]),
        _u64(data["ordinal"]),
        _u64(data["abi_version"]),
        _u64(len(data["bytes"])),
        data["bytes"],
    )


def checkpoint_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise CheckpointFileError("invalid checkpoint body")
    return _hash(SET_DOMAIN, body)


def selector_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise CheckpointFileError("invalid selector body")
    return _hash(SELECTOR_DOMAIN, body)


def encode_set(metadata: Record, objects: list[Record]) -> bytes:
    checked = _metadata(metadata)
    entries = [_object(entry) for entry in objects]
    if not 0 < len(entries) <= MAX_OBJECTS:
        raise CheckpointFileError("invalid object count")
    identities = [(entry["kind"], entry["ordinal"]) for entry in entries]
    if identities != sorted(identities) or len(set(identities)) != len(
        identities
    ):
        raise CheckpointFileError("non-canonical object order")
    total = (
        SET_PAYLOAD_OFFSET
        + sum(len(entry["bytes"]) for entry in entries)
        + SET_FOOTER_BYTES
    )
    output = bytearray(total)
    output[:SET_HEADER_BYTES] = b"".join(
        (
            SET_MAGIC,
            _u64(SET_ABI),
            _u64(total),
            _u64(checked["generation"]),
            _u64(checked["request_epoch"]),
            _u64(checked["publication_next_sequence"]),
            _u64(len(entries)),
            _u64(ALLOWED_FLAGS),
            checked["parent_checkpoint_sha256"],
            checked["challenge_sha256"],
        )
    )
    cursor = SET_PAYLOAD_OFFSET
    for index, entry in enumerate(entries):
        offset = SET_HEADER_BYTES + index * SET_ENTRY_BYTES
        output[offset : offset + SET_ENTRY_BYTES] = b"".join(
            (
                _u64(entry["kind"]),
                _u64(entry["ordinal"]),
                _u64(entry["abi_version"]),
                _u64(cursor),
                _u64(len(entry["bytes"])),
                object_root(entry),
            )
        )
        end = cursor + len(entry["bytes"])
        output[cursor:end] = entry["bytes"]
        cursor = end
    output[-SET_FOOTER_BYTES:] = checkpoint_root(
        bytes(output[:-SET_FOOTER_BYTES])
    )
    return bytes(output)


def decode_set(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < SET_PAYLOAD_OFFSET + SET_FOOTER_BYTES
        or encoded[:8] != SET_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != SET_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != len(encoded)
        or struct.unpack_from("<Q", encoded, 56)[0] != ALLOWED_FLAGS
        or encoded[-32:] != checkpoint_root(encoded[:-32])
    ):
        raise CheckpointFileError("invalid checkpoint set")
    count = struct.unpack_from("<Q", encoded, 48)[0]
    if not 0 < count <= MAX_OBJECTS:
        raise CheckpointFileError("invalid object count")
    metadata = _metadata(
        {
            "generation": struct.unpack_from("<Q", encoded, 24)[0],
            "request_epoch": struct.unpack_from("<Q", encoded, 32)[0],
            "publication_next_sequence": struct.unpack_from(
                "<Q", encoded, 40
            )[0],
            "parent_checkpoint_sha256": encoded[64:96],
            "challenge_sha256": encoded[96:128],
        }
    )
    objects: list[Record] = []
    cursor = SET_PAYLOAD_OFFSET
    for index in range(count):
        offset = SET_HEADER_BYTES + index * SET_ENTRY_BYTES
        kind, ordinal, abi_version, payload_offset, payload_bytes = (
            struct.unpack_from("<QQQQQ", encoded, offset)
        )
        end = cursor + payload_bytes
        if (
            kind not in range(1, 8)
            or payload_offset != cursor
            or payload_bytes == 0
            or end > len(encoded) - SET_FOOTER_BYTES
        ):
            raise CheckpointFileError("invalid checkpoint object")
        entry = _object(
            {
                "kind": kind,
                "ordinal": ordinal,
                "abi_version": abi_version,
                "bytes": encoded[cursor:end],
            }
        )
        if encoded[offset + 40 : offset + 72] != object_root(entry):
            raise CheckpointFileError("object root mismatch")
        objects.append(entry)
        cursor = end
    identities = [(entry["kind"], entry["ordinal"]) for entry in objects]
    unused = encoded[
        SET_HEADER_BYTES + count * SET_ENTRY_BYTES : SET_PAYLOAD_OFFSET
    ]
    if (
        identities != sorted(identities)
        or len(set(identities)) != len(identities)
        or any(unused)
        or cursor != len(encoded) - SET_FOOTER_BYTES
    ):
        raise CheckpointFileError("non-canonical checkpoint set")
    return {
        "metadata": metadata,
        "objects": objects,
        "checkpoint_sha256": encoded[-32:],
    }


def prepare_selector(
    previous_selector_sha256: bytes,
    checkpoint_set: bytes,
) -> bytes:
    previous = _digest(previous_selector_sha256)
    decoded = decode_set(checkpoint_set)
    metadata = decoded["metadata"]
    if (
        metadata["generation"] == 1
        and previous != ZERO_DIGEST
        or metadata["generation"] > 1
        and previous == ZERO_DIGEST
    ):
        raise CheckpointFileError("selector lineage mismatch")
    body = b"".join(
        (
            SELECTOR_MAGIC,
            _u64(SELECTOR_ABI),
            _u64(SELECTOR_BYTES),
            _u64(metadata["generation"]),
            _u64(metadata["request_epoch"]),
            _u64(metadata["publication_next_sequence"]),
            _u64(len(checkpoint_set)),
            _u64(ALLOWED_FLAGS),
            previous,
            decoded["checkpoint_sha256"],
            metadata["challenge_sha256"],
        )
    )
    if len(body) != SELECTOR_BODY_BYTES:
        raise CheckpointFileError("selector length mismatch")
    return body + selector_root(body)


def decode_selector(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != SELECTOR_BYTES
        or encoded[:8] != SELECTOR_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != SELECTOR_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != len(encoded)
        or struct.unpack_from("<Q", encoded, 56)[0] != ALLOWED_FLAGS
        or encoded[-32:] != selector_root(encoded[:-32])
    ):
        raise CheckpointFileError("invalid selector")
    result = {
        "generation": struct.unpack_from("<Q", encoded, 24)[0],
        "request_epoch": struct.unpack_from("<Q", encoded, 32)[0],
        "publication_next_sequence": struct.unpack_from(
            "<Q", encoded, 40
        )[0],
        "checkpoint_bytes": struct.unpack_from("<Q", encoded, 48)[0],
        "previous_selector_sha256": encoded[64:96],
        "checkpoint_sha256": encoded[96:128],
        "challenge_sha256": encoded[128:160],
        "selector_sha256": encoded[160:192],
    }
    if (
        result["generation"] == 0
        or result["request_epoch"] == 0
        or result["publication_next_sequence"] == 0
        or result["checkpoint_bytes"]
        < SET_PAYLOAD_OFFSET + SET_FOOTER_BYTES
        or result["checkpoint_sha256"] == ZERO_DIGEST
        or result["challenge_sha256"] == ZERO_DIGEST
        or (
            result["generation"] == 1
            and result["previous_selector_sha256"] != ZERO_DIGEST
        )
        or (
            result["generation"] > 1
            and result["previous_selector_sha256"] == ZERO_DIGEST
        )
    ):
        raise CheckpointFileError("invalid selector semantics")
    return result


def verify_pair(checkpoint_set: bytes, selector: bytes) -> Record:
    decoded_set = decode_set(checkpoint_set)
    decoded_selector = decode_selector(selector)
    metadata = decoded_set["metadata"]
    if (
        decoded_selector["generation"] != metadata["generation"]
        or decoded_selector["request_epoch"] != metadata["request_epoch"]
        or decoded_selector["publication_next_sequence"]
        != metadata["publication_next_sequence"]
        or decoded_selector["checkpoint_bytes"] != len(checkpoint_set)
        or decoded_selector["checkpoint_sha256"]
        != decoded_set["checkpoint_sha256"]
        or decoded_selector["challenge_sha256"]
        != metadata["challenge_sha256"]
    ):
        raise CheckpointFileError("checkpoint/selector mismatch")
    return decoded_selector


def recover(
    active_set: bytes,
    active_selector: bytes,
    successor_set: bytes,
    successor_selector: bytes,
) -> str:
    """Return applied/already_applied for the only two admissible roots."""
    active = verify_pair(active_set, active_selector)
    successor = verify_pair(successor_set, successor_selector)
    successor_metadata = decode_set(successor_set)["metadata"]
    if active["selector_sha256"] == successor["selector_sha256"]:
        return "already_applied"
    if (
        active["selector_sha256"]
        != successor["previous_selector_sha256"]
        or active["checkpoint_sha256"]
        != successor_metadata["parent_checkpoint_sha256"]
        or successor["generation"] != active["generation"] + 1
        or successor["request_epoch"] != active["request_epoch"]
        or successor["publication_next_sequence"]
        < active["publication_next_sequence"]
    ):
        raise CheckpointFileError("foreign recovery state")
    return "applied"


def _metadata(value: Record) -> Record:
    try:
        result = {
            "generation": value["generation"],
            "request_epoch": value["request_epoch"],
            "publication_next_sequence": value[
                "publication_next_sequence"
            ],
            "parent_checkpoint_sha256": _digest(
                value["parent_checkpoint_sha256"]
            ),
            "challenge_sha256": _digest(value["challenge_sha256"]),
        }
    except (KeyError, TypeError) as exc:
        raise CheckpointFileError("invalid metadata") from exc
    for field in (
        "generation",
        "request_epoch",
        "publication_next_sequence",
    ):
        _u64(result[field])
    if (
        result["generation"] == 0
        or result["request_epoch"] == 0
        or result["publication_next_sequence"] == 0
        or result["challenge_sha256"] == ZERO_DIGEST
        or (
            result["generation"] == 1
            and result["parent_checkpoint_sha256"] != ZERO_DIGEST
        )
        or (
            result["generation"] > 1
            and result["parent_checkpoint_sha256"] == ZERO_DIGEST
        )
    ):
        raise CheckpointFileError("invalid metadata semantics")
    return result


def _object(value: Record) -> Record:
    try:
        result = {
            "kind": value["kind"],
            "ordinal": value["ordinal"],
            "abi_version": value["abi_version"],
            "bytes": value["bytes"],
        }
    except (KeyError, TypeError) as exc:
        raise CheckpointFileError("invalid object") from exc
    for field in ("kind", "ordinal", "abi_version"):
        _u64(result[field])
    if (
        result["kind"] not in range(1, 8)
        or result["abi_version"] == 0
        or not isinstance(result["bytes"], bytes)
        or not result["bytes"]
    ):
        raise CheckpointFileError("invalid object semantics")
    return result
