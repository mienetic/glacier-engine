"""Independent paged-KV page-image codec and generation-remap verifier."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class PagedKVRestoreError(ValueError):
    """A page image, source ownership chain, or target remap is invalid."""


Record = dict[str, Any]
MAGIC = b"GCKVPG01"
PAGE_IMAGE_ABI = 0x47434B5000000001
PAGE_MAP_ROOT_ABI = 0x47504D5200000001
PAGE_REF_ABI = 0x4750524600000001
PAGE_POSITIONS = 16
HEADER_BYTES = 208
FOOTER_BYTES = 32
ALLOWED_FLAGS = 0
PAGE_IMAGE_DOMAIN = b"glacier-continuation-paged-kv-page-image-v1\x00"
EMPTY_OWNERSHIP_DOMAIN = b"glacier-paged-kv-ownership-v1\x00"
APPEND_OWNERSHIP_DOMAIN = b"glacier-paged-kv-root-append-v1\x00"
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise PagedKVRestoreError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise PagedKVRestoreError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise PagedKVRestoreError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def empty_ownership(
    cache_instance: int,
    num_layers: int,
    dim: int,
    max_seq: int,
) -> bytes:
    if (
        cache_instance == 0
        or num_layers == 0
        or dim == 0
        or max_seq == 0
    ):
        raise PagedKVRestoreError("invalid empty ownership geometry")
    return _hash(
        EMPTY_OWNERSHIP_DOMAIN,
        _u64(cache_instance),
        _u64(num_layers),
        _u64(dim),
        _u64(max_seq),
        _u64(PAGE_POSITIONS),
    )


def append_ownership(before: bytes, page_ref: Record) -> bytes:
    _digest(before)
    _validate_page_ref(page_ref)
    return _hash(
        APPEND_OWNERSHIP_DOMAIN,
        before,
        _u64(page_ref["abi_version"]),
        _u64(page_ref["cache_instance"]),
        _u64(page_ref["logical_page"]),
        _u64(page_ref["ownership_generation"]),
    )


def page_image_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise PagedKVRestoreError("invalid page image body")
    return _hash(PAGE_IMAGE_DOMAIN, body)


def encoded_bytes(num_layers: int, dim: int, committed_rows: int) -> int:
    if (
        num_layers == 0
        or dim == 0
        or not 0 < committed_rows <= PAGE_POSITIONS
    ):
        raise PagedKVRestoreError("invalid page image geometry")
    elements = num_layers * 2 * committed_rows * dim
    _u64(elements)
    return HEADER_BYTES + elements * 4 + FOOTER_BYTES


def encode(value: Record) -> bytes:
    """Encode canonical little-endian f32 payload bytes."""
    try:
        source_root = _root(value["source_root"])
        source_ref = _page_ref(value["source_ref"])
        num_layers = value["num_layers"]
        dim = value["dim"]
        max_seq = value["max_seq"]
        committed_rows = value["committed_rows"]
        payload = value["canonical_f32_le"]
        challenge = _digest(value["challenge_sha256"])
    except (KeyError, TypeError) as exc:
        raise PagedKVRestoreError("invalid page image input") from exc
    required = encoded_bytes(num_layers, dim, committed_rows)
    element_count = (required - HEADER_BYTES - FOOTER_BYTES) // 4
    if (
        not isinstance(payload, bytes)
        or len(payload) != element_count * 4
        or challenge == ZERO_DIGEST
    ):
        raise PagedKVRestoreError("invalid canonical page payload")
    _validate_image_identity(
        source_root,
        source_ref,
        num_layers,
        dim,
        max_seq,
        committed_rows,
    )
    prefix = b"".join(
        (
            MAGIC,
            _u64(PAGE_IMAGE_ABI),
            _u64(required),
            _u32(ALLOWED_FLAGS),
            _u32(0),
            _root_bytes(source_root),
            _u64(num_layers),
            _u64(dim),
            _u64(max_seq),
            _page_ref_bytes(source_ref),
            _u64(committed_rows),
            _u64(element_count),
            challenge,
            payload,
        )
    )
    if len(prefix) != required - FOOTER_BYTES:
        raise PagedKVRestoreError("internal page image length mismatch")
    return prefix + page_image_root(prefix)


def decode(encoded: bytes, expected_challenge_sha256: bytes) -> Record:
    """Decode and verify one exact page image."""
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < HEADER_BYTES + FOOTER_BYTES
    ):
        raise PagedKVRestoreError("invalid page image length")
    if encoded[:8] != MAGIC:
        raise PagedKVRestoreError("invalid page image magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != PAGE_IMAGE_ABI:
        raise PagedKVRestoreError("invalid page image ABI")
    if struct.unpack_from("<Q", encoded, 16)[0] != len(encoded):
        raise PagedKVRestoreError("page image size mismatch")
    if (
        struct.unpack_from("<I", encoded, 24)[0] != ALLOWED_FLAGS
        or struct.unpack_from("<I", encoded, 28)[0] != 0
    ):
        raise PagedKVRestoreError("invalid page image flags")
    if encoded[-FOOTER_BYTES:] != page_image_root(encoded[:-FOOTER_BYTES]):
        raise PagedKVRestoreError("page image root mismatch")

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

    source_root = {
        "abi_version": read_u64(),
        "cache_instance": read_u64(),
        "generation": read_u64(),
        "committed_len": read_u64(),
        "committed_pages": read_u64(),
        "ownership_sha256": read_digest(),
    }
    num_layers = read_u64()
    dim = read_u64()
    max_seq = read_u64()
    source_ref = {
        "abi_version": read_u64(),
        "cache_instance": read_u64(),
        "logical_page": read_u64(),
        "ownership_generation": read_u64(),
    }
    committed_rows = read_u64()
    element_count = read_u64()
    challenge = read_digest()
    if cursor != HEADER_BYTES:
        raise PagedKVRestoreError("page image header mismatch")
    required = encoded_bytes(num_layers, dim, committed_rows)
    if len(encoded) != required:
        raise PagedKVRestoreError("page image geometry length mismatch")
    payload_bytes = element_count * 4
    if payload_bytes != len(encoded) - HEADER_BYTES - FOOTER_BYTES:
        raise PagedKVRestoreError("page element count mismatch")
    payload = encoded[cursor : cursor + payload_bytes]
    _validate_image_identity(
        source_root,
        source_ref,
        num_layers,
        dim,
        max_seq,
        committed_rows,
    )
    if (
        _digest(expected_challenge_sha256) == ZERO_DIGEST
        or challenge != expected_challenge_sha256
    ):
        raise PagedKVRestoreError("page challenge mismatch")
    return {
        "source_root": source_root,
        "num_layers": num_layers,
        "dim": dim,
        "max_seq": max_seq,
        "source_ref": source_ref,
        "committed_rows": committed_rows,
        "payload_element_count": element_count,
        "canonical_f32_le": payload,
        "challenge_sha256": challenge,
        "image_sha256": encoded[-FOOTER_BYTES:],
    }


def verify_and_remap(
    page_images: list[bytes],
    expected_challenge_sha256: bytes,
    target_cache_instance: int,
) -> Record:
    """Verify one complete source chain and derive fresh target generations."""
    if not page_images or target_cache_instance == 0:
        raise PagedKVRestoreError("invalid checkpoint page set")
    images = [
        decode(image, expected_challenge_sha256) for image in page_images
    ]
    source_root = images[0]["source_root"]
    num_layers = images[0]["num_layers"]
    dim = images[0]["dim"]
    max_seq = images[0]["max_seq"]
    source_ownership = empty_ownership(
        source_root["cache_instance"],
        num_layers,
        dim,
        max_seq,
    )
    target_ownership = empty_ownership(
        target_cache_instance,
        num_layers,
        dim,
        max_seq,
    )
    target_refs = []
    for index, image in enumerate(images):
        if (
            image["source_root"] != source_root
            or image["num_layers"] != num_layers
            or image["dim"] != dim
            or image["max_seq"] != max_seq
            or image["source_ref"]["logical_page"] != index
        ):
            raise PagedKVRestoreError("foreign checkpoint page")
        source_ownership = append_ownership(
            source_ownership,
            image["source_ref"],
        )
        target_ref = {
            "abi_version": PAGE_REF_ABI,
            "cache_instance": target_cache_instance,
            "logical_page": index,
            "ownership_generation": index + 1,
        }
        target_refs.append(target_ref)
        target_ownership = append_ownership(target_ownership, target_ref)
    if (
        source_root["committed_pages"] != len(images)
        or source_ownership != source_root["ownership_sha256"]
    ):
        raise PagedKVRestoreError("source ownership chain mismatch")
    return {
        "source_root": source_root,
        "target_root": {
            "abi_version": PAGE_MAP_ROOT_ABI,
            "cache_instance": target_cache_instance,
            "generation": 2,
            "committed_len": source_root["committed_len"],
            "committed_pages": source_root["committed_pages"],
            "ownership_sha256": target_ownership,
        },
        "target_refs": target_refs,
        "restored_pages": len(images),
    }


def _root(value: Record) -> Record:
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
    for name in result:
        _u64(result[name])
    result["ownership_sha256"] = _digest(value["ownership_sha256"])
    return result


def _page_ref(value: Record) -> Record:
    result = {
        name: value[name]
        for name in (
            "abi_version",
            "cache_instance",
            "logical_page",
            "ownership_generation",
        )
    }
    for name in result:
        _u64(result[name])
    return result


def _validate_page_ref(value: Record) -> None:
    if (
        value["abi_version"] != PAGE_REF_ABI
        or value["cache_instance"] == 0
        or value["ownership_generation"] == 0
    ):
        raise PagedKVRestoreError("invalid page ref")


def _validate_image_identity(
    source_root: Record,
    source_ref: Record,
    num_layers: int,
    dim: int,
    max_seq: int,
    committed_rows: int,
) -> None:
    for scalar in (num_layers, dim, max_seq, committed_rows):
        _u64(scalar)
    expected_pages = (
        source_root["committed_len"] + PAGE_POSITIONS - 1
    ) // PAGE_POSITIONS
    logical_start = source_ref["logical_page"] * PAGE_POSITIONS
    expected_rows = min(
        PAGE_POSITIONS,
        source_root["committed_len"] - logical_start,
    )
    if (
        source_root["abi_version"] != PAGE_MAP_ROOT_ABI
        or source_root["cache_instance"] == 0
        or source_root["generation"] == 0
        or source_root["committed_len"] == 0
        or source_root["committed_len"] > max_seq
        or source_root["committed_pages"] == 0
        or source_root["committed_pages"] != expected_pages
        or source_root["ownership_sha256"] == ZERO_DIGEST
        or source_ref["abi_version"] != PAGE_REF_ABI
        or source_ref["cache_instance"] != source_root["cache_instance"]
        or source_ref["logical_page"] >= source_root["committed_pages"]
        or source_ref["ownership_generation"] == 0
        or num_layers == 0
        or dim == 0
        or max_seq == 0
        or committed_rows != expected_rows
    ):
        raise PagedKVRestoreError("invalid page image identity")


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


def _page_ref_bytes(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u64(value["cache_instance"]),
            _u64(value["logical_page"]),
            _u64(value["ownership_generation"]),
        )
    )
