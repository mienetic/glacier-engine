"""Independent codec and verifier for continuation bundle v1."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_capsule as capsule


class BundleError(ValueError):
    """The bundle, capsule composition, or canonical blob table is invalid."""


Record = dict[str, Any]
MAGIC = b"GCBNDV01"
WIRE_ABI = 0x4743424E00000001
FLAG_REQUIRE_ALL_OBJECTS = 1 << 0
FLAG_TENANT_BOUND_BLOBS = 1 << 1
FLAG_CANONICAL_ORDINALS = 1 << 2
REQUIRED_FLAGS = (
    FLAG_REQUIRE_ALL_OBJECTS
    | FLAG_TENANT_BOUND_BLOBS
    | FLAG_CANONICAL_ORDINALS
)
HEADER_BYTES = 240
ENTRY_BYTES = 96
ENCODED_BYTES = HEADER_BYTES + len(capsule.OBJECT_NAMES) * ENTRY_BYTES + 32
BLOB_DOMAIN = b"glacier-continuation-bundle-blob-v1\x00"
ENVELOPE_DOMAIN = b"glacier-continuation-bundle-wire-v1\x00"
ZERO_DIGEST = bytes(32)


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise BundleError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise BundleError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise BundleError("invalid digest")
    if not allow_zero and value == ZERO_DIGEST:
        raise BundleError("zero digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _validate_config(config: Record) -> None:
    _digest(config["tenant_scope_sha256"])
    _digest(config["capsule_sha256"])
    _u64(config["bundle_generation"])
    _digest(config["challenge_sha256"])
    parent = _digest(config["parent_bundle_sha256"], allow_zero=True)
    has_parent = parent != ZERO_DIGEST
    if (config["bundle_generation"] == 0 and has_parent) or (
        config["bundle_generation"] != 0 and not has_parent
    ):
        raise BundleError("invalid parent lineage")


def blob_ref(tenant_scope_sha256: bytes, payload: bytes) -> Record:
    _digest(tenant_scope_sha256)
    if not isinstance(payload, bytes) or not payload:
        raise BundleError("invalid blob payload")
    byte_length = len(payload)
    _u64(byte_length)
    return {
        "byte_length": byte_length,
        "sha256": _hash(
            BLOB_DOMAIN,
            tenant_scope_sha256,
            _u64(byte_length),
            payload,
        ),
    }


def encode(
    config: Record,
    capsule_wire: bytes,
    objects: dict[str, capsule.Object],
) -> bytes:
    """Encode the canonical fixed-size tenant bundle manifest."""
    _validate_config(config)
    try:
        decoded_capsule = capsule.decode_manifest(capsule_wire)
        if decoded_capsule["envelope_sha256"] != config["capsule_sha256"]:
            raise BundleError("capsule root mismatch")
        capsule.decode_and_verify(
            capsule_wire,
            decoded_capsule["config"],
            objects,
        )
    except capsule.CapsuleError as error:
        raise BundleError("capsule composition mismatch") from error

    entries: list[Record] = []
    logical_payload_bytes = 0
    unique_blob_count = 0
    unique_blob_bytes = 0
    for index, name in enumerate(capsule.OBJECT_NAMES):
        abi_version, payload = objects[name]
        typed_ref = capsule.object_ref(index, objects[name])
        storage_ref = blob_ref(config["tenant_scope_sha256"], payload)
        logical_payload_bytes += storage_ref["byte_length"]
        _u64(logical_payload_bytes)

        ordinal = None
        for previous_index, previous in enumerate(entries):
            if previous["blob_sha256"] != storage_ref["sha256"]:
                continue
            previous_payload = objects[
                capsule.OBJECT_NAMES[previous_index]
            ][1]
            if (
                previous["byte_length"] != storage_ref["byte_length"]
                or previous_payload != payload
            ):
                raise BundleError("blob digest collision")
            ordinal = previous["blob_ordinal"]
            break
        if ordinal is None:
            ordinal = unique_blob_count
            unique_blob_count += 1
            unique_blob_bytes += storage_ref["byte_length"]
            _u64(unique_blob_count)
            _u64(unique_blob_bytes)
        entries.append(
            {
                "kind": index,
                "abi_version": abi_version,
                "byte_length": typed_ref["byte_length"],
                "blob_ordinal": ordinal,
                "typed_sha256": typed_ref["sha256"],
                "blob_sha256": storage_ref["sha256"],
            }
        )

    capsule_storage_ref = blob_ref(
        config["tenant_scope_sha256"],
        capsule_wire,
    )
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(ENCODED_BYTES),
            _u32(REQUIRED_FLAGS),
            _u32(0),
            _u64(len(capsule_wire)),
            _u64(len(capsule.OBJECT_NAMES)),
            _u64(logical_payload_bytes),
            _u64(unique_blob_count),
            _u64(unique_blob_bytes),
            _u64(config["bundle_generation"]),
            config["tenant_scope_sha256"],
            config["capsule_sha256"],
            capsule_storage_ref["sha256"],
            config["challenge_sha256"],
            config["parent_bundle_sha256"],
            *(
                part
                for entry in entries
                for part in (
                    _u64(entry["kind"]),
                    _u64(entry["abi_version"]),
                    _u64(entry["byte_length"]),
                    _u64(entry["blob_ordinal"]),
                    entry["typed_sha256"],
                    entry["blob_sha256"],
                )
            ),
        )
    )
    if len(prefix) != ENCODED_BYTES - 32:
        raise BundleError("internal encoded length mismatch")
    return prefix + _hash(ENVELOPE_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if length < 0 or end > len(self.data):
            raise BundleError("truncated bundle")
        value = self.data[self.position : end]
        self.position = end
        return value

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> bytes:
        return self.take(32)


def decode_manifest(encoded: bytes) -> Record:
    """Validate the envelope, totals, kinds, and canonical blob ordinals."""
    if not isinstance(encoded, bytes) or len(encoded) != ENCODED_BYTES:
        raise BundleError("invalid bundle length")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC:
        raise BundleError("invalid magic")
    if reader.u64() != WIRE_ABI:
        raise BundleError("invalid ABI")
    if reader.u64() != ENCODED_BYTES:
        raise BundleError("invalid declared length")
    if reader.u32() != REQUIRED_FLAGS or reader.u32() != 0:
        raise BundleError("invalid flags")
    capsule_wire_length = reader.u64()
    object_count = reader.u64()
    logical_payload_bytes = reader.u64()
    unique_blob_count = reader.u64()
    unique_blob_bytes = reader.u64()
    bundle_generation = reader.u64()
    tenant_scope_sha256 = reader.digest()
    capsule_sha256 = reader.digest()
    capsule_blob_sha256 = reader.digest()
    challenge_sha256 = reader.digest()
    parent_bundle_sha256 = reader.digest()
    if reader.position != HEADER_BYTES:
        raise BundleError("invalid header length")
    config = {
        "tenant_scope_sha256": tenant_scope_sha256,
        "capsule_sha256": capsule_sha256,
        "bundle_generation": bundle_generation,
        "challenge_sha256": challenge_sha256,
        "parent_bundle_sha256": parent_bundle_sha256,
    }
    _validate_config(config)
    if (
        capsule_wire_length != capsule.ENCODED_BYTES
        or object_count != len(capsule.OBJECT_NAMES)
        or logical_payload_bytes == 0
        or not 0 < unique_blob_count <= len(capsule.OBJECT_NAMES)
        or not 0 < unique_blob_bytes <= logical_payload_bytes
    ):
        raise BundleError("invalid totals")
    _digest(capsule_blob_sha256)

    entries: list[Record] = []
    computed_logical_bytes = 0
    computed_unique_count = 0
    computed_unique_bytes = 0
    for expected_kind, name in enumerate(capsule.OBJECT_NAMES):
        kind = reader.u64()
        entry = {
            "kind": kind,
            "name": name,
            "abi_version": reader.u64(),
            "byte_length": reader.u64(),
            "blob_ordinal": reader.u64(),
            "typed_sha256": reader.digest(),
            "blob_sha256": reader.digest(),
        }
        if kind != expected_kind:
            raise BundleError("noncanonical object kind")
        if entry["abi_version"] == 0 or entry["byte_length"] == 0:
            raise BundleError("invalid entry")
        _digest(entry["typed_sha256"])
        _digest(entry["blob_sha256"])
        computed_logical_bytes += entry["byte_length"]
        _u64(computed_logical_bytes)

        prior_ordinal = None
        for previous in entries:
            if previous["blob_sha256"] != entry["blob_sha256"]:
                continue
            if previous["byte_length"] != entry["byte_length"]:
                raise BundleError("invalid blob identity")
            prior_ordinal = previous["blob_ordinal"]
            break
        expected_ordinal = (
            computed_unique_count if prior_ordinal is None else prior_ordinal
        )
        if entry["blob_ordinal"] != expected_ordinal:
            raise BundleError("noncanonical blob ordinal")
        if prior_ordinal is None:
            computed_unique_count += 1
            computed_unique_bytes += entry["byte_length"]
            _u64(computed_unique_count)
            _u64(computed_unique_bytes)
        entries.append(entry)

    if (
        computed_logical_bytes != logical_payload_bytes
        or computed_unique_count != unique_blob_count
        or computed_unique_bytes != unique_blob_bytes
    ):
        raise BundleError("totals mismatch")
    envelope_sha256 = reader.digest()
    if reader.position != len(encoded):
        raise BundleError("trailing bundle bytes")
    if envelope_sha256 != _hash(ENVELOPE_DOMAIN, encoded[:-32]):
        raise BundleError("envelope mismatch")
    return {
        "config": config,
        "capsule_wire_length": capsule_wire_length,
        "capsule_blob_sha256": capsule_blob_sha256,
        "logical_payload_bytes": logical_payload_bytes,
        "unique_blob_count": unique_blob_count,
        "unique_blob_bytes": unique_blob_bytes,
        "deduplicated_payload_bytes": (
            logical_payload_bytes - unique_blob_bytes
        ),
        "entries": entries,
        "envelope_sha256": envelope_sha256,
    }


def decode_and_verify(
    encoded: bytes,
    expected_config: Record,
    capsule_wire: bytes,
    objects: dict[str, capsule.Object],
) -> Record:
    """Verify expected bundle identity, capsule bytes, and all object bytes."""
    decoded = decode_manifest(encoded)
    _validate_config(expected_config)
    if decoded["config"] != expected_config:
        raise BundleError("bundle config substitution")
    try:
        decoded_capsule = capsule.decode_manifest(capsule_wire)
    except capsule.CapsuleError as error:
        raise BundleError("invalid capsule") from error
    if decoded_capsule["envelope_sha256"] != expected_config["capsule_sha256"]:
        raise BundleError("capsule root mismatch")
    capsule_storage_ref = blob_ref(
        expected_config["tenant_scope_sha256"],
        capsule_wire,
    )
    if (
        capsule_storage_ref["byte_length"]
        != decoded["capsule_wire_length"]
        or capsule_storage_ref["sha256"] != decoded["capsule_blob_sha256"]
    ):
        raise BundleError("capsule blob mismatch")
    try:
        capsule.decode_and_verify(
            capsule_wire,
            decoded_capsule["config"],
            objects,
        )
    except capsule.CapsuleError as error:
        raise BundleError("object composition mismatch") from error
    if encode(expected_config, capsule_wire, objects) != encoded:
        raise BundleError("bundle composition mismatch")
    return decoded


def reseal_for_test(encoded: bytes) -> bytes:
    if len(encoded) != ENCODED_BYTES:
        raise BundleError("invalid bundle length")
    return encoded[:-32] + _hash(ENVELOPE_DOMAIN, encoded[:-32])


def demo_capsule_config() -> Record:
    return {
        "execution_abi": 0x4341455800000001,
        "request_epoch": 0x4341525100000001,
        "publication_sequence": 5,
        "checkpoint_generation": 0,
        "kv_tokens": 37,
        "output_tokens": 5,
        "challenge_sha256": bytes((0xA8,)) * 32,
        "parent_capsule_sha256": capsule.ZERO_DIGEST,
    }


def demo_objects() -> dict[str, capsule.Object]:
    shared = b"shared-static-identity-v1"
    return {
        "model": (0x43414D4F00000001, shared),
        "tokenizer": (0x4341544B00000001, shared),
        "execution_plan": (
            0x4341504C00000001,
            b"plan-v1:cpu:threads=4:strict",
        ),
        "resource_state": (
            0x4341525300000001,
            b"resource-v1:bank=17:kv=4096:output=64",
        ),
        "lane_state": (
            0x43414C4E00000001,
            b"lane-v1:request=41:service=11",
        ),
        "kv_state": (
            0x43414B5600000001,
            b"kv-v1:positions=37:root=bundle",
        ),
        "sampler_state": (
            0x4341534D00000001,
            b"sampler-v1:rng=01020304:calls=5",
        ),
        "output_state": (
            0x43414F5500000001,
            b"output-v1:tokens=901,902,903,904,905",
        ),
        "publication_receipt": (
            0x4341505200000001,
            b"publication-v1:sequence=5:commit=bundle",
        ),
    }


def demo_bundle_config(capsule_sha256: bytes) -> Record:
    return {
        "tenant_scope_sha256": bytes((0x6D,)) * 32,
        "capsule_sha256": capsule_sha256,
        "bundle_generation": 0,
        "challenge_sha256": bytes((0xE3,)) * 32,
        "parent_bundle_sha256": ZERO_DIGEST,
    }


def build_demo() -> Record:
    capsule_config = demo_capsule_config()
    objects = demo_objects()
    capsule_wire = capsule.encode(capsule_config, objects)
    bundle_config = demo_bundle_config(capsule_wire[-32:])
    encoded = encode(bundle_config, capsule_wire, objects)
    return {
        "capsule_config": capsule_config,
        "objects": objects,
        "capsule_wire": capsule_wire,
        "bundle_config": bundle_config,
        "encoded": encoded,
    }
