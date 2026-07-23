"""Independent oracle for materialized multimodal processor-cache bundles."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media
from bench import media_processor_state as processor


class MediaProcessorCacheError(ValueError):
    """A processor-cache bundle, binding, or successor is invalid."""


Record = dict[str, Any]
CACHE_BUNDLE_ABI = 0x474D504300000001
CACHE_BUNDLE_MAGIC = b"GMPCCH1\x00"
CACHE_COUNT = processor.PROCESSOR_COUNT
CACHE_BUNDLE_HEADER_BYTES = 256
CACHE_ENTRY_BYTES = 64
CACHE_DIRECTORY_BYTES = CACHE_COUNT * CACHE_ENTRY_BYTES
CACHE_PAYLOAD_OFFSET = CACHE_BUNDLE_HEADER_BYTES + CACHE_DIRECTORY_BYTES
CACHE_BUNDLE_FOOTER_BYTES = 32
ALLOWED_FLAGS = 0
CACHE_BUNDLE_DOMAIN = b"glacier-media-processor-cache-bundle-v1\x00"
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
KINDS = (media.IMAGE, media.AUDIO, media.VIDEO)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaProcessorCacheError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise MediaProcessorCacheError("invalid digest")
    return value


def bundle_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise MediaProcessorCacheError("invalid cache bundle body")
    return hashlib.sha256(CACHE_BUNDLE_DOMAIN + body).digest()


def encode_bundle(
    processor_bundle: Record,
    plan: Record,
    payloads: list[bytes],
) -> bytes:
    try:
        checked_processor = processor.decode_bundle(
            processor.encode_bundle(
                processor_bundle["states"],
                processor_bundle["sync"],
            )
        )
        generation = checked_processor["sync"]["generation"]
        request_epoch = checked_processor["sync"]["request_epoch"]
        challenge = checked_processor["sync"]["challenge_sha256"]
        processor_bundle_sha256 = _digest(
            plan["processor_bundle_sha256"]
        )
        previous_cache_bundle_sha256 = _digest(
            plan["previous_cache_bundle_sha256"],
            allow_zero=True,
        )
        source_bank_epoch = plan["source_bank_epoch"]
        restore_bank_epoch = plan["restore_bank_epoch"]
        restore_owner_key_base = plan["restore_owner_key_base"]
        restore_tree_key_base = plan["restore_tree_key_base"]
        restore_authority_key_base = plan[
            "restore_authority_key_base"
        ]
        tenant_key = plan["tenant_key"]
        publication_next_sequence = plan[
            "publication_next_sequence"
        ]
    except (KeyError, TypeError):
        raise MediaProcessorCacheError("invalid cache bundle plan") from None
    scalar_values = (
        source_bank_epoch,
        restore_bank_epoch,
        restore_owner_key_base,
        restore_tree_key_base,
        restore_authority_key_base,
        tenant_key,
        publication_next_sequence,
    )
    for value in scalar_values:
        _u64(value)
    if (
        len(payloads) != CACHE_COUNT
        or min(scalar_values) == 0
        or source_bank_epoch == restore_bank_epoch
        or processor_bundle_sha256
        != checked_processor["bundle_sha256"]
        or (
            generation == 1
            and previous_cache_bundle_sha256 != ZERO_DIGEST
        )
        or (
            generation != 1
            and previous_cache_bundle_sha256 == ZERO_DIGEST
        )
    ):
        raise MediaProcessorCacheError("invalid cache bundle plan")

    checked_payloads: list[bytes] = []
    digests: list[bytes] = []
    for state, payload in zip(checked_processor["states"], payloads):
        if not isinstance(payload, bytes) or (
            len(payload) != state["cache_bytes"]
        ):
            raise MediaProcessorCacheError("invalid cache payload")
        digest = hashlib.sha256(payload).digest()
        if digest != state["cache_content_sha256"]:
            raise MediaProcessorCacheError("cache state mismatch")
        checked_payloads.append(payload)
        digests.append(digest)

    total_cache_bytes = sum(map(len, checked_payloads))
    _u64(total_cache_bytes)
    total_bytes = (
        CACHE_PAYLOAD_OFFSET
        + total_cache_bytes
        + CACHE_BUNDLE_FOOTER_BYTES
    )
    output = bytearray(total_bytes)
    output[:64] = b"".join(
        (
            CACHE_BUNDLE_MAGIC,
            _u64(CACHE_BUNDLE_ABI),
            _u64(total_bytes),
            _u64(ALLOWED_FLAGS),
            _u64(generation),
            _u64(request_epoch),
            _u64(CACHE_COUNT),
            _u64(0),
        )
    )
    output[64:96] = challenge
    output[96:128] = processor_bundle_sha256
    output[128:160] = checked_processor["sync"]["sync_sha256"]
    output[160:192] = previous_cache_bundle_sha256
    output[192:256] = b"".join(
        (
            _u64(restore_bank_epoch),
            _u64(restore_owner_key_base),
            _u64(restore_tree_key_base),
            _u64(restore_authority_key_base),
            _u64(tenant_key),
            _u64(publication_next_sequence),
            _u64(total_cache_bytes),
            _u64(source_bank_epoch),
        )
    )
    cursor = CACHE_PAYLOAD_OFFSET
    for index, (payload, digest) in enumerate(
        zip(checked_payloads, digests)
    ):
        entry_offset = (
            CACHE_BUNDLE_HEADER_BYTES + index * CACHE_ENTRY_BYTES
        )
        output[entry_offset : entry_offset + CACHE_ENTRY_BYTES] = b"".join(
            (
                _u64(KINDS[index]),
                _u64(cursor),
                _u64(len(payload)),
                _u64(0),
                digest,
            )
        )
        output[cursor : cursor + len(payload)] = payload
        cursor += len(payload)
    output[-CACHE_BUNDLE_FOOTER_BYTES:] = bundle_root(
        bytes(output[:-CACHE_BUNDLE_FOOTER_BYTES])
    )
    encoded = bytes(output)
    decode_bundle(encoded)
    return encoded


def decode_bundle(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded)
        < CACHE_PAYLOAD_OFFSET + CACHE_BUNDLE_FOOTER_BYTES
        or encoded[:8] != CACHE_BUNDLE_MAGIC
        or _read(encoded, 8) != CACHE_BUNDLE_ABI
        or _read(encoded, 16) != len(encoded)
        or _read(encoded, 24) != ALLOWED_FLAGS
        or _read(encoded, 48) != CACHE_COUNT
        or _read(encoded, 56) != 0
    ):
        raise MediaProcessorCacheError("invalid cache bundle wire")
    generation = _read(encoded, 32)
    request_epoch = _read(encoded, 40)
    challenge = _digest(encoded[64:96])
    processor_bundle_sha256 = _digest(encoded[96:128])
    sync_sha256 = _digest(encoded[128:160])
    previous_cache_bundle_sha256 = _digest(
        encoded[160:192],
        allow_zero=True,
    )
    restore_bank_epoch = _read(encoded, 192)
    restore_owner_key_base = _read(encoded, 200)
    restore_tree_key_base = _read(encoded, 208)
    restore_authority_key_base = _read(encoded, 216)
    tenant_key = _read(encoded, 224)
    publication_next_sequence = _read(encoded, 232)
    total_cache_bytes = _read(encoded, 240)
    source_bank_epoch = _read(encoded, 248)
    if (
        generation == 0
        or request_epoch == 0
        or min(
            source_bank_epoch,
            restore_bank_epoch,
            restore_owner_key_base,
            restore_tree_key_base,
            restore_authority_key_base,
            tenant_key,
            publication_next_sequence,
            total_cache_bytes,
        )
        == 0
        or source_bank_epoch == restore_bank_epoch
        or (
            generation == 1
            and previous_cache_bundle_sha256 != ZERO_DIGEST
        )
        or (
            generation != 1
            and previous_cache_bundle_sha256 == ZERO_DIGEST
        )
        or bundle_root(encoded[:-CACHE_BUNDLE_FOOTER_BYTES])
        != encoded[-CACHE_BUNDLE_FOOTER_BYTES:]
    ):
        raise MediaProcessorCacheError("contradictory cache bundle")

    cursor = CACHE_PAYLOAD_OFFSET
    payloads: list[bytes] = []
    digests: list[bytes] = []
    for index, kind in enumerate(KINDS):
        entry_offset = (
            CACHE_BUNDLE_HEADER_BYTES + index * CACHE_ENTRY_BYTES
        )
        payload_len = _read(encoded, entry_offset + 16)
        if (
            _read(encoded, entry_offset) != kind
            or _read(encoded, entry_offset + 8) != cursor
            or payload_len == 0
            or _read(encoded, entry_offset + 24) != 0
            or cursor + payload_len
            > len(encoded) - CACHE_BUNDLE_FOOTER_BYTES
        ):
            raise MediaProcessorCacheError("invalid cache directory")
        digest = _digest(encoded[entry_offset + 32 : entry_offset + 64])
        payload = encoded[cursor : cursor + payload_len]
        if hashlib.sha256(payload).digest() != digest:
            raise MediaProcessorCacheError("cache payload root mismatch")
        digests.append(digest)
        payloads.append(payload)
        cursor += payload_len
    if (
        cursor != len(encoded) - CACHE_BUNDLE_FOOTER_BYTES
        or sum(map(len, payloads)) != total_cache_bytes
    ):
        raise MediaProcessorCacheError("incomplete cache bundle")
    return {
        "generation": generation,
        "request_epoch": request_epoch,
        "challenge_sha256": challenge,
        "processor_bundle_sha256": processor_bundle_sha256,
        "sync_sha256": sync_sha256,
        "previous_cache_bundle_sha256": previous_cache_bundle_sha256,
        "source_bank_epoch": source_bank_epoch,
        "restore_bank_epoch": restore_bank_epoch,
        "restore_owner_key_base": restore_owner_key_base,
        "restore_tree_key_base": restore_tree_key_base,
        "restore_authority_key_base": restore_authority_key_base,
        "tenant_key": tenant_key,
        "publication_next_sequence": publication_next_sequence,
        "total_cache_bytes": total_cache_bytes,
        "cache_sha256": digests,
        "payloads": payloads,
        "bundle_sha256": encoded[-CACHE_BUNDLE_FOOTER_BYTES:],
    }


def validate_binding(
    cache_bundle: Record,
    processor_bundle: Record,
    expected_processor_bundle_sha256: bytes,
) -> None:
    checked_cache = decode_bundle(
        encode_decoded_bundle(cache_bundle)
    )
    checked_processor = processor.decode_bundle(
        processor.encode_bundle(
            processor_bundle["states"],
            processor_bundle["sync"],
        )
    )
    if (
        checked_cache["processor_bundle_sha256"]
        != _digest(expected_processor_bundle_sha256)
        or checked_cache["generation"]
        != checked_processor["sync"]["generation"]
        or checked_cache["request_epoch"]
        != checked_processor["sync"]["request_epoch"]
        or checked_cache["challenge_sha256"]
        != checked_processor["sync"]["challenge_sha256"]
        or checked_cache["sync_sha256"]
        != checked_processor["sync"]["sync_sha256"]
    ):
        raise MediaProcessorCacheError("processor/cache metadata mismatch")
    for state, payload, digest in zip(
        checked_processor["states"],
        checked_cache["payloads"],
        checked_cache["cache_sha256"],
    ):
        if (
            len(payload) != state["cache_bytes"]
            or digest != state["cache_content_sha256"]
        ):
            raise MediaProcessorCacheError("processor/cache state mismatch")


def validate_successor(previous: Record, successor: Record) -> None:
    prior = decode_bundle(encode_decoded_bundle(previous))
    next_bundle = decode_bundle(encode_decoded_bundle(successor))
    if (
        next_bundle["generation"] != prior["generation"] + 1
        or next_bundle["request_epoch"] != prior["request_epoch"]
        or next_bundle["previous_cache_bundle_sha256"]
        != prior["bundle_sha256"]
        or next_bundle["challenge_sha256"]
        != prior["challenge_sha256"]
        or next_bundle["restore_bank_epoch"]
        == prior["restore_bank_epoch"]
        or next_bundle["source_bank_epoch"]
        != prior["restore_bank_epoch"]
    ):
        raise MediaProcessorCacheError("invalid cache successor")


def encode_decoded_bundle(value: Record) -> bytes:
    try:
        total_bytes = (
            CACHE_PAYLOAD_OFFSET
            + value["total_cache_bytes"]
            + CACHE_BUNDLE_FOOTER_BYTES
        )
        output = bytearray(total_bytes)
        output[:64] = b"".join(
            (
                CACHE_BUNDLE_MAGIC,
                _u64(CACHE_BUNDLE_ABI),
                _u64(total_bytes),
                _u64(ALLOWED_FLAGS),
                _u64(value["generation"]),
                _u64(value["request_epoch"]),
                _u64(CACHE_COUNT),
                _u64(0),
            )
        )
        output[64:96] = _digest(value["challenge_sha256"])
        output[96:128] = _digest(value["processor_bundle_sha256"])
        output[128:160] = _digest(value["sync_sha256"])
        output[160:192] = _digest(
            value["previous_cache_bundle_sha256"],
            allow_zero=True,
        )
        output[192:256] = b"".join(
            _u64(value[field])
            for field in (
                "restore_bank_epoch",
                "restore_owner_key_base",
                "restore_tree_key_base",
                "restore_authority_key_base",
                "tenant_key",
                "publication_next_sequence",
                "total_cache_bytes",
                "source_bank_epoch",
            )
        )
        cursor = CACHE_PAYLOAD_OFFSET
        for index, (payload, digest) in enumerate(
            zip(value["payloads"], value["cache_sha256"])
        ):
            offset = (
                CACHE_BUNDLE_HEADER_BYTES + index * CACHE_ENTRY_BYTES
            )
            output[offset : offset + CACHE_ENTRY_BYTES] = b"".join(
                (
                    _u64(KINDS[index]),
                    _u64(cursor),
                    _u64(len(payload)),
                    _u64(0),
                    _digest(digest),
                )
            )
            output[cursor : cursor + len(payload)] = payload
            cursor += len(payload)
        output[-CACHE_BUNDLE_FOOTER_BYTES:] = _digest(
            value["bundle_sha256"]
        )
    except (KeyError, TypeError):
        raise MediaProcessorCacheError("invalid decoded cache bundle") from None
    return bytes(output)
