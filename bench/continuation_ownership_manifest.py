"""Independent codec for durable continuation ownership manifest v1."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_capsule as capsule
from bench import continuation_object_payload_store as payload_store


class OwnershipManifestError(ValueError):
    """The ownership plan, bound checkpoint, or materialization is invalid."""


Record = dict[str, Any]
MAGIC = b"GCOWNV01"
ABI_VERSION = 0x47434F4D00000001
ALLOWED_FLAGS = 0
MAX_SCOPES = 4
MAX_ALLOCATIONS = 16
HEADER_BYTES = 384
SCOPE_BYTES = 96
ALLOCATION_BYTES = 160
FOOTER_BYTES = 32
ENCODED_BYTES = (
    HEADER_BYTES
    + MAX_SCOPES * SCOPE_BYTES
    + MAX_ALLOCATIONS * ALLOCATION_BYTES
    + FOOTER_BYTES
)
MANIFEST_DOMAIN = b"glacier-continuation-ownership-manifest-v1\x00"
MATERIALIZED_OBJECT_DOMAIN = (
    b"glacier-continuation-materialized-object-v1\x00"
)
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
CLAIM_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "logits_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "device_bytes",
    "io_bytes",
    "queue_slots",
)
ALLOCATION_KINDS = {
    "kv_page": 1,
    "output_journal": 2,
    "sampler_state": 3,
    "runtime_object": 4,
}
ALLOCATION_KIND_NAMES = {
    value: name for name, value in ALLOCATION_KINDS.items()
}


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise OwnershipManifestError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise OwnershipManifestError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise OwnershipManifestError("invalid digest")
    return value


def _nonzero_digest(value: bytes) -> bytes:
    value = _digest(value)
    if value == ZERO_DIGEST:
        raise OwnershipManifestError("zero digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _claim(value: Record) -> Record:
    if not isinstance(value, dict) or set(value) != set(CLAIM_FIELDS):
        raise OwnershipManifestError("invalid claim fields")
    result = {}
    for name in CLAIM_FIELDS:
        _u64(value[name])
        result[name] = value[name]
    return result


def _claim_bytes(value: Record) -> bytes:
    claim = _claim(value)
    return b"".join(_u64(claim[name]) for name in CLAIM_FIELDS)


def _claim_is_zero(value: Record) -> bool:
    return all(value[name] == 0 for name in CLAIM_FIELDS)


def _add_claims(left: Record, right: Record) -> Record:
    result = {}
    for name in CLAIM_FIELDS:
        value = left[name] + right[name]
        _u64(value)
        result[name] = value
    return result


def _claim_within(value: Record, ceiling: Record) -> bool:
    return all(value[name] <= ceiling[name] for name in CLAIM_FIELDS)


def zero_claim() -> Record:
    return {name: 0 for name in CLAIM_FIELDS}


def materialized_object_root(kind: str, payload: bytes) -> bytes:
    try:
        kind_value = ALLOCATION_KINDS[kind]
    except (KeyError, TypeError) as exc:
        raise OwnershipManifestError("invalid allocation kind") from exc
    if not isinstance(payload, bytes):
        raise OwnershipManifestError("invalid materialized payload")
    return _hash(
        MATERIALIZED_OBJECT_DOMAIN,
        _u64(kind_value),
        _u64(len(payload)),
        payload,
    )


def manifest_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise OwnershipManifestError("invalid manifest body")
    return _hash(MANIFEST_DOMAIN, body)


def encode(value: Record) -> bytes:
    """Encode and semantically validate one canonical ownership plan."""
    try:
        scopes = value["scopes"]
        allocations = value["allocations"]
        if not isinstance(scopes, list) or not isinstance(allocations, list):
            raise OwnershipManifestError("invalid ownership collections")
        decoded: Record = {
            name: value[name]
            for name in (
                "source_bank_epoch",
                "source_receipt_generation",
                "restore_bank_epoch",
                "request_epoch",
                "publication_next_sequence",
                "checkpoint_generation",
                "owner_key",
                "tree_key",
                "authority_key",
            )
        }
        decoded["parent_claim"] = _claim(value["parent_claim"])
        decoded["tree_ceiling"] = _claim(value["tree_ceiling"])
        decoded["tenant_scope_sha256"] = _digest(
            value["tenant_scope_sha256"]
        )
        decoded["payload_snapshot_sha256"] = _digest(
            value["payload_snapshot_sha256"]
        )
        decoded["challenge_sha256"] = _digest(value["challenge_sha256"])
        decoded["scopes"] = [
            {
                "scope_key": scope["scope_key"],
                "tenant_key": scope["tenant_key"],
                "ceiling": _claim(scope["ceiling"]),
            }
            for scope in scopes
        ]
        decoded["allocations"] = []
        for allocation in allocations:
            payload = allocation["object_bytes"]
            if not isinstance(payload, bytes):
                raise OwnershipManifestError("invalid materialized payload")
            decoded["allocations"].append(
                {
                    "scope_ordinal": allocation["scope_ordinal"],
                    "node_key": allocation["node_key"],
                    "binding_key": allocation["binding_key"],
                    "kind": allocation["kind"],
                    "object_byte_length": len(payload),
                    "claim": _claim(allocation["claim"]),
                    "object_sha256": materialized_object_root(
                        allocation["kind"],
                        payload,
                    ),
                }
            )
    except (KeyError, TypeError) as exc:
        raise OwnershipManifestError("invalid ownership input") from exc
    _validate(decoded)

    prefix = bytearray()
    prefix.extend(MAGIC)
    prefix.extend(_u64(ABI_VERSION))
    prefix.extend(_u64(ENCODED_BYTES))
    prefix.extend(_u32(ALLOWED_FLAGS))
    prefix.extend(_u32(0))
    for name in (
        "source_bank_epoch",
        "source_receipt_generation",
        "restore_bank_epoch",
        "request_epoch",
        "publication_next_sequence",
        "checkpoint_generation",
        "owner_key",
        "tree_key",
        "authority_key",
    ):
        prefix.extend(_u64(decoded[name]))
    prefix.extend(_u64(len(decoded["scopes"])))
    prefix.extend(_u64(len(decoded["allocations"])))
    prefix.extend(_claim_bytes(decoded["parent_claim"]))
    prefix.extend(_claim_bytes(decoded["tree_ceiling"]))
    prefix.extend(decoded["tenant_scope_sha256"])
    prefix.extend(decoded["payload_snapshot_sha256"])
    prefix.extend(decoded["challenge_sha256"])
    prefix.extend(_u64(0))
    if len(prefix) != HEADER_BYTES:
        raise OwnershipManifestError("internal header length mismatch")

    for index in range(MAX_SCOPES):
        if index < len(decoded["scopes"]):
            scope = decoded["scopes"][index]
            prefix.extend(_u64(scope["scope_key"]))
            prefix.extend(_u64(scope["tenant_key"]))
            prefix.extend(_claim_bytes(scope["ceiling"]))
        else:
            prefix.extend(bytes(SCOPE_BYTES))
    for index in range(MAX_ALLOCATIONS):
        if index < len(decoded["allocations"]):
            allocation = decoded["allocations"][index]
            prefix.extend(_u64(allocation["scope_ordinal"]))
            prefix.extend(_u64(allocation["node_key"]))
            prefix.extend(_u64(allocation["binding_key"]))
            prefix.extend(_u64(ALLOCATION_KINDS[allocation["kind"]]))
            prefix.extend(_u64(allocation["object_byte_length"]))
            prefix.extend(_u64(0))
            prefix.extend(_claim_bytes(allocation["claim"]))
            prefix.extend(allocation["object_sha256"])
        else:
            prefix.extend(bytes(ALLOCATION_BYTES))
    if len(prefix) != ENCODED_BYTES - FOOTER_BYTES:
        raise OwnershipManifestError("internal body length mismatch")
    return bytes(prefix) + manifest_root(bytes(prefix))


def decode(encoded: bytes) -> Record:
    """Decode, root-check, and semantically validate the exact fixed wire."""
    if not isinstance(encoded, bytes) or len(encoded) != ENCODED_BYTES:
        raise OwnershipManifestError("invalid ownership length")
    if encoded[:8] != MAGIC:
        raise OwnershipManifestError("invalid ownership magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != ABI_VERSION:
        raise OwnershipManifestError("invalid ownership ABI")
    if struct.unpack_from("<Q", encoded, 16)[0] != ENCODED_BYTES:
        raise OwnershipManifestError("ownership size mismatch")
    if (
        struct.unpack_from("<I", encoded, 24)[0] != ALLOWED_FLAGS
        or struct.unpack_from("<I", encoded, 28)[0] != 0
    ):
        raise OwnershipManifestError("invalid ownership flags")
    if encoded[-FOOTER_BYTES:] != manifest_root(encoded[:-FOOTER_BYTES]):
        raise OwnershipManifestError("ownership root mismatch")

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

    def read_claim() -> Record:
        return {name: read_u64() for name in CLAIM_FIELDS}

    decoded: Record = {}
    for name in (
        "source_bank_epoch",
        "source_receipt_generation",
        "restore_bank_epoch",
        "request_epoch",
        "publication_next_sequence",
        "checkpoint_generation",
        "owner_key",
        "tree_key",
        "authority_key",
    ):
        decoded[name] = read_u64()
    scope_count = read_u64()
    allocation_count = read_u64()
    if scope_count > MAX_SCOPES or allocation_count > MAX_ALLOCATIONS:
        raise OwnershipManifestError("ownership collection overflow")
    decoded["parent_claim"] = read_claim()
    decoded["tree_ceiling"] = read_claim()
    decoded["tenant_scope_sha256"] = read_digest()
    decoded["payload_snapshot_sha256"] = read_digest()
    decoded["challenge_sha256"] = read_digest()
    if read_u64() != 0 or cursor != HEADER_BYTES:
        raise OwnershipManifestError("nonzero ownership header padding")

    decoded["scopes"] = []
    for index in range(MAX_SCOPES):
        start = cursor
        scope = {
            "scope_key": read_u64(),
            "tenant_key": read_u64(),
            "ceiling": read_claim(),
        }
        if index < scope_count:
            decoded["scopes"].append(scope)
        elif any(encoded[start:cursor]):
            raise OwnershipManifestError("nonzero scope padding")
    decoded["allocations"] = []
    for index in range(MAX_ALLOCATIONS):
        start = cursor
        scope_ordinal = read_u64()
        node_key = read_u64()
        binding_key = read_u64()
        kind_value = read_u64()
        object_byte_length = read_u64()
        reserved = read_u64()
        claim = read_claim()
        object_sha256 = read_digest()
        if index < allocation_count:
            try:
                kind = ALLOCATION_KIND_NAMES[kind_value]
            except KeyError as exc:
                raise OwnershipManifestError(
                    "invalid allocation kind"
                ) from exc
            if reserved != 0:
                raise OwnershipManifestError(
                    "nonzero allocation reserved field"
                )
            decoded["allocations"].append(
                {
                    "scope_ordinal": scope_ordinal,
                    "node_key": node_key,
                    "binding_key": binding_key,
                    "kind": kind,
                    "object_byte_length": object_byte_length,
                    "claim": claim,
                    "object_sha256": object_sha256,
                }
            )
        elif any(encoded[start:cursor]):
            raise OwnershipManifestError("nonzero allocation padding")
    if cursor != ENCODED_BYTES - FOOTER_BYTES:
        raise OwnershipManifestError("ownership body length mismatch")
    decoded["manifest_sha256"] = encoded[-FOOTER_BYTES:]
    _validate(decoded)
    return decoded


def verify_bindings(
    capsule_wire: bytes,
    manifest_wire: bytes,
    payload_snapshot_wire: bytes,
) -> Record:
    """Verify capsule resource-state and payload-snapshot bindings."""
    manifest = decode(manifest_wire)
    try:
        capsule_manifest = capsule.decode_manifest(capsule_wire)
        resource_ref = capsule.object_ref(
            capsule.OBJECT_NAMES.index("resource_state"),
            (ABI_VERSION, manifest_wire),
        )
        payload_snapshot = payload_store.decode_snapshot(
            payload_snapshot_wire,
            manifest["tenant_scope_sha256"],
        )
    except (capsule.CapsuleError, payload_store.PayloadStoreError) as exc:
        raise OwnershipManifestError("invalid bound checkpoint") from exc
    config = capsule_manifest["config"]
    if (
        config["request_epoch"] != manifest["request_epoch"]
        or config["publication_sequence"]
        != manifest["publication_next_sequence"]
        or config["checkpoint_generation"]
        != manifest["checkpoint_generation"]
        or config["challenge_sha256"] != manifest["challenge_sha256"]
        or capsule_manifest["refs"]["resource_state"] != resource_ref
        or payload_snapshot["snapshot_sha256"]
        != manifest["payload_snapshot_sha256"]
    ):
        raise OwnershipManifestError("checkpoint binding mismatch")
    return {
        "manifest": manifest,
        "capsule": capsule_manifest,
        "payload_snapshot": payload_snapshot,
    }


def verify_materialized(
    manifest: Record,
    objects: list[tuple[str, bytes]],
) -> None:
    """Reject before lifecycle commit unless all objects match in order."""
    allocations = manifest["allocations"]
    if len(objects) != len(allocations):
        raise OwnershipManifestError("materialized object count mismatch")
    for allocation, (kind, payload) in zip(
        allocations,
        objects,
    ):
        if (
            kind != allocation["kind"]
            or len(payload) != allocation["object_byte_length"]
            or materialized_object_root(kind, payload)
            != allocation["object_sha256"]
        ):
            raise OwnershipManifestError("materialized object mismatch")


def _validate(value: Record) -> None:
    for name in (
        "source_bank_epoch",
        "source_receipt_generation",
        "restore_bank_epoch",
        "request_epoch",
        "publication_next_sequence",
        "checkpoint_generation",
        "owner_key",
        "tree_key",
        "authority_key",
    ):
        _u64(value[name])
    if (
        value["source_bank_epoch"] == 0
        or value["source_receipt_generation"] == 0
        or value["restore_bank_epoch"] == 0
        or value["restore_bank_epoch"] == value["source_bank_epoch"]
        or value["request_epoch"] == 0
        or value["publication_next_sequence"] == 0
        or value["owner_key"] == 0
        or value["tree_key"] == 0
        or value["authority_key"] == 0
    ):
        raise OwnershipManifestError("invalid ownership identity")
    parent_claim = _claim(value["parent_claim"])
    tree_ceiling = _claim(value["tree_ceiling"])
    if _claim_is_zero(parent_claim) or _claim_is_zero(tree_ceiling):
        raise OwnershipManifestError("zero ownership claim")
    _nonzero_digest(value["tenant_scope_sha256"])
    _nonzero_digest(value["payload_snapshot_sha256"])
    _nonzero_digest(value["challenge_sha256"])

    scopes = value["scopes"]
    allocations = value["allocations"]
    if not 0 < len(scopes) <= MAX_SCOPES:
        raise OwnershipManifestError("invalid scope count")
    if not 0 < len(allocations) <= MAX_ALLOCATIONS:
        raise OwnershipManifestError("invalid allocation count")
    scope_keys = set()
    previous_scope: tuple[int, int] | None = None
    for scope in scopes:
        _u64(scope["scope_key"])
        _u64(scope["tenant_key"])
        ceiling = _claim(scope["ceiling"])
        key = (scope["scope_key"], scope["tenant_key"])
        if (
            scope["scope_key"] == 0
            or scope["tenant_key"] == 0
            or _claim_is_zero(ceiling)
            or scope["scope_key"] in scope_keys
            or (previous_scope is not None and key <= previous_scope)
        ):
            raise OwnershipManifestError("noncanonical scope")
        scope_keys.add(scope["scope_key"])
        previous_scope = key

    scope_claims = [zero_claim() for _ in scopes]
    aggregate = zero_claim()
    identities: set[tuple[int, int]] = set()
    bindings: set[int] = set()
    previous_allocation: tuple[int, int, int, int, bytes] | None = None
    for allocation in allocations:
        scope_ordinal = allocation["scope_ordinal"]
        node_key = allocation["node_key"]
        binding_key = allocation["binding_key"]
        kind = allocation["kind"]
        object_byte_length = allocation["object_byte_length"]
        _u64(scope_ordinal)
        _u64(node_key)
        _u64(binding_key)
        _u64(object_byte_length)
        try:
            kind_value = ALLOCATION_KINDS[kind]
        except (KeyError, TypeError) as exc:
            raise OwnershipManifestError("invalid allocation kind") from exc
        claim = _claim(allocation["claim"])
        object_sha256 = _nonzero_digest(allocation["object_sha256"])
        identity = (scope_ordinal, node_key)
        key = (
            scope_ordinal,
            node_key,
            binding_key,
            kind_value,
            object_sha256,
        )
        if (
            scope_ordinal >= len(scopes)
            or node_key == 0
            or binding_key == 0
            or object_byte_length == 0
            or _claim_is_zero(claim)
            or identity in identities
            or binding_key in bindings
            or (
                previous_allocation is not None
                and key <= previous_allocation
            )
        ):
            raise OwnershipManifestError("noncanonical allocation")
        identities.add(identity)
        bindings.add(binding_key)
        previous_allocation = key
        scope_claims[scope_ordinal] = _add_claims(
            scope_claims[scope_ordinal],
            claim,
        )
        aggregate = _add_claims(aggregate, claim)
    for scope, claim in zip(scopes, scope_claims):
        if not _claim_within(claim, scope["ceiling"]):
            raise OwnershipManifestError("scope ceiling exceeded")
    if not _claim_within(aggregate, tree_ceiling):
        raise OwnershipManifestError("tree ceiling exceeded")
