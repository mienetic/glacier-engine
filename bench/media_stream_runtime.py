"""Independent oracle for bounded media stream chunk receipts."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media
from bench import media_runtime_lease as lease


class MediaStreamRuntimeError(ValueError):
    """A media stream boundary or chunk receipt is invalid."""


Record = dict[str, Any]
CHUNK_RECEIPT_ABI = 0x474D534300000001
CHUNK_RECEIPT_MAGIC = b"GMSCHN1\x00"
CHUNK_RECEIPT_BODY_BYTES = 320
CHUNK_RECEIPT_BYTES = 352
MAXIMUM_STREAM_CHUNKS = 4
ALLOWED_FLAGS = 0
RECEIPT_DOMAIN = b"glacier-media-stream-chunk-receipt-v1\x00"
U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)
ROOT_FIELDS = (
    "media_object_sha256",
    "transform_plan_sha256",
    "lease_receipt_sha256",
    "output_sha256",
    "publication_commit_sha256",
    "previous_chunk_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaStreamRuntimeError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise MediaStreamRuntimeError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _body(receipt: Record) -> bytes:
    output = bytearray(CHUNK_RECEIPT_BODY_BYTES)
    output[:128] = b"".join(
        (
            CHUNK_RECEIPT_MAGIC,
            _u64(CHUNK_RECEIPT_ABI),
            _u64(CHUNK_RECEIPT_BYTES),
            _u64(ALLOWED_FLAGS),
            *(
                _u64(receipt[field])
                for field in (
                    "kind",
                    "request_epoch",
                    "stream_key",
                    "stream_chunk_index",
                    "publication_sequence",
                    "units_before",
                    "units_after",
                    "output_bytes",
                    "mapping_count",
                    "binding_count",
                    "provisional_binding_count",
                )
            ),
            _u64(0),
        )
    )
    for index, field in enumerate(ROOT_FIELDS):
        start = 128 + index * 32
        output[start : start + 32] = _digest(
            receipt[field],
            allow_zero=field == "previous_chunk_sha256",
        )
    return bytes(output)


def receipt_root(receipt: Record) -> bytes:
    return _hash(RECEIPT_DOMAIN, _body(receipt))


def _receipt(value: Record) -> Record:
    try:
        receipt = {
            field: value[field]
            for field in (
                "kind",
                "request_epoch",
                "stream_key",
                "stream_chunk_index",
                "publication_sequence",
                "units_before",
                "units_after",
                "output_bytes",
                "mapping_count",
                "binding_count",
                "provisional_binding_count",
            )
        }
        for field in ROOT_FIELDS:
            receipt[field] = _digest(
                value[field],
                allow_zero=field == "previous_chunk_sha256",
            )
        receipt["receipt_sha256"] = _digest(value["receipt_sha256"])
    except (KeyError, TypeError):
        raise MediaStreamRuntimeError("invalid chunk receipt") from None
    for field in (
        "kind",
        "request_epoch",
        "stream_key",
        "stream_chunk_index",
        "publication_sequence",
        "units_before",
        "units_after",
        "output_bytes",
        "mapping_count",
        "binding_count",
        "provisional_binding_count",
    ):
        _u64(receipt[field])
    previous_valid = (
        receipt["previous_chunk_sha256"] == ZERO_DIGEST
        if receipt["stream_chunk_index"] == 0
        else receipt["previous_chunk_sha256"] != ZERO_DIGEST
    )
    if (
        receipt["kind"] not in (media.IMAGE, media.AUDIO, media.VIDEO)
        or receipt["request_epoch"] == 0
        or receipt["stream_key"] == 0
        or receipt["stream_chunk_index"] >= MAXIMUM_STREAM_CHUNKS
        or receipt["publication_sequence"] == 0
        or receipt["units_after"] <= receipt["units_before"]
        or receipt["output_bytes"] == 0
        or receipt["mapping_count"] == 0
        or not 0 < receipt["binding_count"] <= lease.MAXIMUM_BINDINGS
        or receipt["provisional_binding_count"]
        != receipt["binding_count"] - 1
        or not previous_valid
        or receipt["receipt_sha256"] != receipt_root(receipt)
    ):
        raise MediaStreamRuntimeError("contradictory chunk receipt")
    return receipt


def encode_receipt(value: Record) -> bytes:
    receipt = _receipt(value)
    return _body(receipt) + receipt["receipt_sha256"]


def decode_receipt(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != CHUNK_RECEIPT_BYTES
        or encoded[:8] != CHUNK_RECEIPT_MAGIC
        or _read(encoded, 8) != CHUNK_RECEIPT_ABI
        or _read(encoded, 16) != CHUNK_RECEIPT_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or _read(encoded, 120) != 0
        or encoded[320:] != _hash(RECEIPT_DOMAIN, encoded[:320])
    ):
        raise MediaStreamRuntimeError("invalid chunk receipt wire")
    receipt = {
        "kind": _read(encoded, 32),
        "request_epoch": _read(encoded, 40),
        "stream_key": _read(encoded, 48),
        "stream_chunk_index": _read(encoded, 56),
        "publication_sequence": _read(encoded, 64),
        "units_before": _read(encoded, 72),
        "units_after": _read(encoded, 80),
        "output_bytes": _read(encoded, 88),
        "mapping_count": _read(encoded, 96),
        "binding_count": _read(encoded, 104),
        "provisional_binding_count": _read(encoded, 112),
        **{
            field: encoded[128 + index * 32 : 160 + index * 32]
            for index, field in enumerate(ROOT_FIELDS)
        },
        "receipt_sha256": encoded[320:352],
    }
    return _receipt(receipt)


def make_chunk_receipt(
    state_before: Record,
    stream_key: int,
    stream_chunk_index: int,
    previous_chunk_sha256: bytes,
    execution_value: Record,
) -> Record:
    execution = lease.decode_receipt(lease.encode_receipt(execution_value))
    units_after = state_before["visible_units"] + execution["logical_units"]
    _u64(units_after)
    receipt = {
        "kind": execution["kind"],
        "request_epoch": execution["request_epoch"],
        "stream_key": stream_key,
        "stream_chunk_index": stream_chunk_index,
        "publication_sequence": execution["media_sequence"],
        "units_before": state_before["visible_units"],
        "units_after": units_after,
        "output_bytes": execution["output_bytes"],
        "mapping_count": execution["mapping_count"],
        "binding_count": execution["binding_count"],
        "provisional_binding_count": execution["provisional_binding_count"],
        "media_object_sha256": state_before["media_object_sha256"],
        "transform_plan_sha256": execution["transform_plan_sha256"],
        "lease_receipt_sha256": execution["receipt_sha256"],
        "output_sha256": execution["output_sha256"],
        "publication_commit_sha256": execution["publication_commit_sha256"],
        "previous_chunk_sha256": _digest(
            previous_chunk_sha256, allow_zero=True
        ),
        "receipt_sha256": ZERO_DIGEST,
    }
    receipt["receipt_sha256"] = receipt_root(receipt)
    verify_chunk_receipt(
        state_before,
        stream_key,
        stream_chunk_index,
        previous_chunk_sha256,
        execution,
        receipt,
    )
    return _receipt(receipt)


def verify_chunk_receipt(
    state_before: Record,
    expected_stream_key: int,
    expected_stream_chunk_index: int,
    expected_previous_chunk_sha256: bytes,
    execution_value: Record,
    receipt_value: Record,
) -> None:
    execution = lease.decode_receipt(lease.encode_receipt(execution_value))
    receipt = _receipt(receipt_value)
    units_after = state_before["visible_units"] + execution["logical_units"]
    _u64(units_after)
    if (
        expected_stream_key == 0
        or receipt["stream_key"] != expected_stream_key
        or receipt["stream_chunk_index"] != expected_stream_chunk_index
        or receipt["request_epoch"] != state_before["request_epoch"]
        or receipt["request_epoch"] != execution["request_epoch"]
        or receipt["kind"] != execution["kind"]
        or receipt["publication_sequence"] != state_before["next_sequence"]
        or receipt["publication_sequence"] != execution["media_sequence"]
        or receipt["units_before"] != state_before["visible_units"]
        or receipt["units_after"] != units_after
        or receipt["output_bytes"] != execution["output_bytes"]
        or receipt["mapping_count"] != execution["mapping_count"]
        or receipt["binding_count"] != execution["binding_count"]
        or receipt["provisional_binding_count"]
        != execution["provisional_binding_count"]
        or receipt["media_object_sha256"]
        != state_before["media_object_sha256"]
        or receipt["transform_plan_sha256"]
        != execution["transform_plan_sha256"]
        or receipt["lease_receipt_sha256"] != execution["receipt_sha256"]
        or receipt["output_sha256"] != execution["output_sha256"]
        or receipt["publication_commit_sha256"]
        != execution["publication_commit_sha256"]
        or receipt["previous_chunk_sha256"]
        != _digest(expected_previous_chunk_sha256, allow_zero=True)
    ):
        raise MediaStreamRuntimeError("chunk receipt mismatch")
