"""Independent verifier for canonical durable payload-store snapshots."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_bundle as bundle
from bench import continuation_object_store as object_store


class PayloadStoreError(ValueError):
    """A payload snapshot or reclaim transition is invalid."""


Record = dict[str, Any]
MAGIC = b"GLPAY01\x00"
SCHEMA_VERSION = 1
HEADER_BYTES = 64
ENTRY_HEADER_BYTES = 40
FOOTER_BYTES = 32
MINIMUM_ENCODED_BYTES = HEADER_BYTES + FOOTER_BYTES
DEFAULT_CAPACITY = 16
ZERO_DIGEST = bytes(32)
BODY_DOMAIN = b"glacier-continuation-object-payload-store-body-v1\x00"
SNAPSHOT_DOMAIN = (
    b"glacier-continuation-object-payload-store-snapshot-v1\x00"
)
PREVIEW_DOMAIN = (
    b"glacier-continuation-object-payload-store-reclaim-preview-v1\x00"
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise PayloadStoreError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise PayloadStoreError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _reference_key(reference: Record) -> tuple[bytes, int]:
    return (_digest(reference["sha256"]), reference["byte_length"])


def sort_entries(entries: list[Record]) -> list[Record]:
    return sorted(entries, key=lambda entry: _reference_key(entry["reference"]))


def _validate_entry(tenant_scope_sha256: bytes, entry: Record) -> None:
    try:
        reference = entry["reference"]
        payload = entry["payload"]
        byte_length = reference["byte_length"]
        _u64(byte_length)
        _digest(reference["sha256"])
    except (KeyError, TypeError) as exc:
        raise PayloadStoreError("invalid payload entry") from exc
    if (
        byte_length == 0
        or not isinstance(payload, bytes)
        or len(payload) != byte_length
    ):
        raise PayloadStoreError("invalid payload entry")
    try:
        actual = bundle.blob_ref(tenant_scope_sha256, payload)
    except bundle.BundleError as exc:
        raise PayloadStoreError("invalid payload entry") from exc
    if actual != reference:
        raise PayloadStoreError("payload identity mismatch")


def encode_snapshot(
    tenant_scope_sha256: bytes,
    entries: list[Record],
) -> bytes:
    _digest(tenant_scope_sha256)
    if tenant_scope_sha256 == ZERO_DIGEST:
        raise PayloadStoreError("zero tenant scope")
    if len(entries) > DEFAULT_CAPACITY:
        raise PayloadStoreError("entry capacity exceeded")
    payload_bytes = 0
    previous: tuple[bytes, int] | None = None
    body = bytearray()
    body.extend(MAGIC)
    body.extend(_u64(SCHEMA_VERSION))
    body.extend(tenant_scope_sha256)
    body.extend(_u64(len(entries)))
    for entry in entries:
        _validate_entry(tenant_scope_sha256, entry)
        key = _reference_key(entry["reference"])
        if previous is not None and key <= previous:
            raise PayloadStoreError("entries are not strictly canonical")
        previous = key
        payload_bytes += entry["reference"]["byte_length"]
        _u64(payload_bytes)
    body.extend(_u64(payload_bytes))
    for entry in entries:
        body.extend(_u64(entry["reference"]["byte_length"]))
        body.extend(entry["reference"]["sha256"])
        body.extend(entry["payload"])
    body.extend(_hash(BODY_DOMAIN, bytes(body)))
    return bytes(body)


def decode_snapshot(
    encoded: bytes,
    expected_tenant_scope_sha256: bytes,
) -> Record:
    if not isinstance(encoded, bytes) or len(encoded) < MINIMUM_ENCODED_BYTES:
        raise PayloadStoreError("invalid payload snapshot")
    _digest(expected_tenant_scope_sha256)
    if expected_tenant_scope_sha256 == ZERO_DIGEST:
        raise PayloadStoreError("zero tenant scope")
    if encoded[:8] != MAGIC:
        raise PayloadStoreError("invalid payload magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != SCHEMA_VERSION:
        raise PayloadStoreError("unsupported payload schema")
    tenant_scope_sha256 = encoded[16:48]
    if tenant_scope_sha256 != expected_tenant_scope_sha256:
        raise PayloadStoreError("tenant scope mismatch")
    entry_count = struct.unpack_from("<Q", encoded, 48)[0]
    payload_bytes = struct.unpack_from("<Q", encoded, 56)[0]
    if entry_count > DEFAULT_CAPACITY:
        raise PayloadStoreError("entry capacity exceeded")
    cursor = HEADER_BYTES
    entries = []
    observed_payload_bytes = 0
    previous: tuple[bytes, int] | None = None
    for _ in range(entry_count):
        if cursor + ENTRY_HEADER_BYTES > len(encoded):
            raise PayloadStoreError("truncated payload entry")
        byte_length = struct.unpack_from("<Q", encoded, cursor)[0]
        cursor += 8
        sha256 = encoded[cursor : cursor + 32]
        cursor += 32
        if cursor + byte_length > len(encoded):
            raise PayloadStoreError("truncated payload")
        payload = encoded[cursor : cursor + byte_length]
        cursor += byte_length
        entry = {
            "reference": {
                "byte_length": byte_length,
                "sha256": sha256,
            },
            "payload": payload,
        }
        _validate_entry(tenant_scope_sha256, entry)
        key = _reference_key(entry["reference"])
        if previous is not None and key <= previous:
            raise PayloadStoreError("entries are not strictly canonical")
        previous = key
        entries.append(entry)
        observed_payload_bytes += byte_length
        _u64(observed_payload_bytes)
    if observed_payload_bytes != payload_bytes or cursor + FOOTER_BYTES != len(
        encoded
    ):
        raise PayloadStoreError("payload accounting mismatch")
    body_sha256 = _hash(BODY_DOMAIN, encoded[:cursor])
    if encoded[cursor:] != body_sha256:
        raise PayloadStoreError("payload footer mismatch")
    encoded_sha256 = hashlib.sha256(encoded).digest()
    snapshot_sha256 = _hash(
        SNAPSHOT_DOMAIN,
        tenant_scope_sha256,
        _u64(entry_count),
        _u64(payload_bytes),
        _u64(len(encoded)),
        encoded_sha256,
    )
    return {
        "tenant_scope_sha256": tenant_scope_sha256,
        "entry_count": entry_count,
        "payload_bytes": payload_bytes,
        "encoded_bytes": len(encoded),
        "body_sha256": body_sha256,
        "encoded_sha256": encoded_sha256,
        "snapshot_sha256": snapshot_sha256,
        "entries": entries,
    }


def preview_root(preview: Record) -> bytes:
    return _hash(
        PREVIEW_DOMAIN,
        preview["before"]["snapshot_sha256"],
        preview["after"]["snapshot_sha256"],
        preview["targets_sha256"],
        _u64(preview["freed_entries"]),
        _u64(preview["freed_payload_bytes"]),
    )


def preview_reclaim(
    active: bytes,
    tenant_scope_sha256: bytes,
    targets: list[Record],
) -> Record:
    try:
        targets_sha256 = object_store.retired_targets_root(targets)
    except object_store.StoreError as exc:
        raise PayloadStoreError("invalid reclaim targets") from exc
    before = decode_snapshot(active, tenant_scope_sha256)
    target_keys = {_reference_key(target) for target in targets}
    if len(target_keys) != len(targets):
        raise PayloadStoreError("duplicate reclaim target")
    retained = []
    found = set()
    freed_payload_bytes = 0
    for entry in before["entries"]:
        key = _reference_key(entry["reference"])
        if key in target_keys:
            found.add(key)
            freed_payload_bytes += entry["reference"]["byte_length"]
        else:
            retained.append(entry)
    if found != target_keys:
        raise PayloadStoreError("reclaim target not found")
    candidate = encode_snapshot(tenant_scope_sha256, retained)
    after = decode_snapshot(candidate, tenant_scope_sha256)
    preview = {
        "before": before,
        "after": after,
        "targets_sha256": targets_sha256,
        "freed_entries": len(targets),
        "freed_payload_bytes": freed_payload_bytes,
        "candidate": candidate,
    }
    preview["preview_sha256"] = preview_root(preview)
    return preview


def verify_reclaim_preview(preview: Record) -> None:
    try:
        removed_encoded_bytes = (
            preview["freed_entries"] * ENTRY_HEADER_BYTES
            + preview["freed_payload_bytes"]
        )
        valid = (
            preview["freed_entries"] > 0
            and preview["before"]["tenant_scope_sha256"] != ZERO_DIGEST
            and preview["before"]["tenant_scope_sha256"]
            == preview["after"]["tenant_scope_sha256"]
            and preview["before"]["body_sha256"] != ZERO_DIGEST
            and preview["before"]["encoded_sha256"] != ZERO_DIGEST
            and preview["before"]["snapshot_sha256"] != ZERO_DIGEST
            and preview["after"]["body_sha256"] != ZERO_DIGEST
            and preview["after"]["encoded_sha256"] != ZERO_DIGEST
            and preview["after"]["snapshot_sha256"] != ZERO_DIGEST
            and preview["targets_sha256"] != ZERO_DIGEST
            and preview["before"]["entry_count"]
            >= preview["freed_entries"]
            and preview["before"]["payload_bytes"]
            >= preview["freed_payload_bytes"]
            and preview["before"]["encoded_bytes"]
            >= MINIMUM_ENCODED_BYTES
            and preview["after"]["encoded_bytes"]
            >= MINIMUM_ENCODED_BYTES
            and preview["before"]["encoded_bytes"]
            > preview["after"]["encoded_bytes"]
            and preview["before"]["encoded_bytes"]
            - preview["after"]["encoded_bytes"]
            == removed_encoded_bytes
            and preview["after"]["entry_count"]
            == preview["before"]["entry_count"] - preview["freed_entries"]
            and preview["after"]["payload_bytes"]
            == preview["before"]["payload_bytes"]
            - preview["freed_payload_bytes"]
            and preview["preview_sha256"] == preview_root(preview)
        )
    except (KeyError, TypeError, PayloadStoreError) as exc:
        raise PayloadStoreError("invalid reclaim preview") from exc
    if not valid:
        raise PayloadStoreError("invalid reclaim preview")
