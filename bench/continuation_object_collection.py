"""Independent model for deterministic continuation-object collection plans."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_object_store as object_store


class CollectionError(ValueError):
    """The collection capability, evidence inputs, or store state is invalid."""


Record = dict[str, Any]
ZERO_DIGEST = bytes(32)
GRANT_DOMAIN = b"glacier-continuation-store-collection-grant-v1\x00"
ROOTS_DOMAIN = b"glacier-continuation-store-collection-roots-v1\x00"
LEASES_DOMAIN = b"glacier-continuation-store-collection-leases-v1\x00"
PLAN_DOMAIN = b"glacier-continuation-store-collection-plan-v1\x00"
LEASE_RECEIPT_DOMAIN = b"glacier-continuation-store-lease-receipt-v1\x00"
CLASS_IDS = {
    "reachable": 1,
    "leased": 2,
    "quarantined": 3,
    "collectible": 4,
}


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise CollectionError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise CollectionError("invalid digest")
    return value


def _target_key(target: Record) -> tuple[bytes, int]:
    _u64(target["byte_length"])
    _digest(target["sha256"])
    if target["byte_length"] == 0:
        raise CollectionError("zero-length target")
    return target["sha256"], target["byte_length"]


def _lease_key(receipt: Record) -> tuple[bytes, int, int, bytes]:
    target_key = _target_key(receipt["target"])
    return (
        target_key[0],
        target_key[1],
        receipt["generation"],
        receipt["lease_sha256"],
    )


def canonical_roots(root_references: list[Record]) -> list[Record]:
    return sorted((dict(root) for root in root_references), key=_target_key)


def canonical_lease_receipts(lease_receipts: list[Record]) -> list[Record]:
    return sorted((dict(receipt) for receipt in lease_receipts), key=_lease_key)


def _validate_grant(grant: Record) -> None:
    for name in (
        "authority_epoch",
        "max_root_references",
        "max_lease_receipts",
        "max_slot_scans",
        "max_collectible_entries",
        "max_collectible_bytes",
    ):
        _u64(grant[name])
    for name in (
        "tenant_scope_sha256",
        "bundle_sha256",
        "store_grant_sha256",
        "expected_snapshot_sha256",
        "challenge_sha256",
    ):
        _digest(grant[name])
    if grant["authority_epoch"] == 0 or grant["max_slot_scans"] == 0:
        raise CollectionError("invalid collection grant")


def collection_grant_root(grant: Record) -> bytes:
    _validate_grant(grant)
    hasher = hashlib.sha256()
    for part in (
        GRANT_DOMAIN,
        _u64(grant["authority_epoch"]),
        grant["tenant_scope_sha256"],
        grant["bundle_sha256"],
        grant["store_grant_sha256"],
        grant["expected_snapshot_sha256"],
        _u64(grant["max_root_references"]),
        _u64(grant["max_lease_receipts"]),
        _u64(grant["max_slot_scans"]),
        _u64(grant["max_collectible_entries"]),
        _u64(grant["max_collectible_bytes"]),
        grant["challenge_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


def root_references_root(root_references: list[Record]) -> bytes:
    keys = [_target_key(root) for root in root_references]
    if keys != sorted(keys):
        raise CollectionError("non-canonical root references")
    hasher = hashlib.sha256()
    hasher.update(ROOTS_DOMAIN)
    hasher.update(_u64(len(root_references)))
    for root in root_references:
        hasher.update(_u64(root["byte_length"]))
        hasher.update(root["sha256"])
    return hasher.digest()


def lease_receipt_root(receipt: Record) -> bytes:
    target = receipt["target"]
    _target_key(target)
    _u64(receipt["generation"])
    _digest(receipt["owner_sha256"])
    _u64(receipt["expires_at_tick"])
    _digest(receipt["lifecycle_grant_sha256"])
    if receipt["generation"] == 0 or receipt["expires_at_tick"] == 0:
        raise CollectionError("invalid lease receipt")
    hasher = hashlib.sha256()
    for part in (
        LEASE_RECEIPT_DOMAIN,
        _u64(target["byte_length"]),
        target["sha256"],
        _u64(receipt["generation"]),
        receipt["owner_sha256"],
        _u64(receipt["expires_at_tick"]),
        receipt["lifecycle_grant_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


def lease_receipts_root(lease_receipts: list[Record]) -> bytes:
    keys = [_lease_key(receipt) for receipt in lease_receipts]
    if keys != sorted(keys):
        raise CollectionError("non-canonical lease receipts")
    hasher = hashlib.sha256()
    hasher.update(LEASES_DOMAIN)
    hasher.update(_u64(len(lease_receipts)))
    for receipt in lease_receipts:
        computed = lease_receipt_root(receipt)
        if receipt["lease_sha256"] != computed:
            raise CollectionError("lease receipt mismatch")
        hasher.update(receipt["lease_sha256"])
    return hasher.digest()


def collection_plan_root(receipt: Record, decisions: list[Record]) -> bytes:
    hasher = hashlib.sha256()
    for part in (
        PLAN_DOMAIN,
        receipt["collection_grant_sha256"],
        receipt["snapshot_sha256"],
        receipt["root_references_sha256"],
        receipt["lease_receipts_sha256"],
        _u64(receipt["slot_scans"]),
        _u64(receipt["occupied_entries"]),
        _u64(receipt["root_reference_count"]),
        _u64(receipt["lease_receipt_count"]),
        _u64(receipt["reachable_entries"]),
        _u64(receipt["reachable_references"]),
        _u64(receipt["leased_entries"]),
        _u64(receipt["leased_references"]),
        _u64(receipt["quarantined_entries"]),
        _u64(receipt["quarantined_references"]),
        _u64(receipt["collectible_entries"]),
        _u64(receipt["collectible_bytes"]),
    ):
        hasher.update(part)
    for decision in decisions:
        hasher.update(_u64(decision["slot_index"]))
        hasher.update(_u64(CLASS_IDS[decision["class"]]))
        hasher.update(_u64(decision["target"]["byte_length"]))
        hasher.update(decision["target"]["sha256"])
        hasher.update(_u64(decision["reference_count"]))
        hasher.update(_u64(decision["lease_generation"]))
        hasher.update(_u64(decision["repair_generation"]))
    return hasher.digest()


def _find(store: object_store.Store, target: Record) -> int | None:
    for index, slot in enumerate(store.slots):
        if (
            slot is not None
            and slot["byte_length"] == target["byte_length"]
            and slot["sha256"] == target["sha256"]
        ):
            return index
    return None


def plan_collection(
    store: object_store.Store,
    grant: Record,
    root_references: list[Record],
    lease_receipts: list[Record],
) -> tuple[Record, list[Record]]:
    _validate_grant(grant)
    if store.closed:
        raise CollectionError("store closed")
    if (
        grant["authority_epoch"] != store.grant["authority_epoch"]
        or grant["tenant_scope_sha256"]
        != store.grant["tenant_scope_sha256"]
        or grant["bundle_sha256"] != store.grant["bundle_sha256"]
        or grant["store_grant_sha256"] != store.grant_sha256
    ):
        raise CollectionError("collection scope mismatch")
    if len(root_references) > grant["max_root_references"]:
        raise CollectionError("root reference budget exceeded")
    if len(lease_receipts) > grant["max_lease_receipts"]:
        raise CollectionError("lease receipt budget exceeded")
    if store.capacity > grant["max_slot_scans"]:
        raise CollectionError("slot scan budget exceeded")
    snapshot = store.audit_snapshot_root_v2()
    if snapshot != grant["expected_snapshot_sha256"]:
        raise CollectionError("collection snapshot mismatch")
    roots_sha256 = root_references_root(root_references)
    leases_sha256 = lease_receipts_root(lease_receipts)

    roots_per_slot = [0] * store.capacity
    lease_per_slot = [False] * store.capacity
    for root_reference in root_references:
        index = _find(store, root_reference)
        if index is None:
            raise CollectionError("unknown root reference")
        slot = store.slots[index]
        assert slot is not None
        if slot["state"] == "retired":
            raise CollectionError("retired root reference")
        roots_per_slot[index] += 1
        _u64(roots_per_slot[index])
    for lease_receipt in lease_receipts:
        index = _find(store, lease_receipt["target"])
        if index is None:
            raise CollectionError("unknown lease receipt")
        if lease_per_slot[index]:
            raise CollectionError("duplicate lease receipt")
        slot = store.slots[index]
        assert slot is not None
        if (
            not slot["lease_active"]
            or lease_receipt_root(lease_receipt)
            != lease_receipt["lease_sha256"]
            or lease_receipt["generation"] != slot["lease_generation"]
            or lease_receipt["lease_sha256"] != slot["lease_receipt_sha256"]
        ):
            raise CollectionError("lease receipt mismatch")
        lease_per_slot[index] = True

    decisions: list[Record] = []
    counters = {
        "reachable_entries": 0,
        "reachable_references": 0,
        "leased_entries": 0,
        "leased_references": 0,
        "quarantined_entries": 0,
        "quarantined_references": 0,
        "collectible_entries": 0,
        "collectible_bytes": 0,
    }
    for index, slot in enumerate(store.slots):
        if slot is None:
            continue
        if slot["state"] == "retired":
            if (
                roots_per_slot[index] != 0
                or slot["reference_count"] != 0
                or lease_per_slot[index]
                or slot["lease_active"]
            ):
                raise CollectionError("retired reachability mismatch")
        elif roots_per_slot[index] != slot["reference_count"]:
            raise CollectionError("root multiplicity mismatch")
        if slot["lease_active"] != lease_per_slot[index]:
            raise CollectionError("lease coverage mismatch")
        if slot["state"] == "quarantined":
            classification = "quarantined"
        elif slot["state"] == "retired":
            classification = "collectible"
        elif slot["lease_active"]:
            classification = "leased"
        else:
            classification = "reachable"
        counters[f"{classification}_entries"] += 1
        if classification == "collectible":
            counters["collectible_bytes"] += slot["byte_length"]
        else:
            counters[f"{classification}_references"] += slot["reference_count"]
        decisions.append(
            {
                "slot_index": index,
                "class": classification,
                "target": {
                    "byte_length": slot["byte_length"],
                    "sha256": slot["sha256"],
                },
                "reference_count": slot["reference_count"],
                "lease_generation": slot["lease_generation"],
                "repair_generation": slot["repair_generation"],
            }
        )
    if counters["collectible_entries"] > grant["max_collectible_entries"]:
        raise CollectionError("collectible entry budget exceeded")
    if counters["collectible_bytes"] > grant["max_collectible_bytes"]:
        raise CollectionError("collectible byte budget exceeded")
    receipt: Record = {
        "collection_grant_sha256": collection_grant_root(grant),
        "snapshot_sha256": snapshot,
        "root_references_sha256": roots_sha256,
        "lease_receipts_sha256": leases_sha256,
        "slot_scans": store.capacity,
        "occupied_entries": store.entry_count,
        "root_reference_count": len(root_references),
        "lease_receipt_count": len(lease_receipts),
        **counters,
    }
    receipt["plan_sha256"] = collection_plan_root(receipt, decisions)
    return receipt, decisions


def demo_grant(store: object_store.Store) -> Record:
    return {
        "authority_epoch": store.grant["authority_epoch"],
        "tenant_scope_sha256": store.grant["tenant_scope_sha256"],
        "bundle_sha256": store.grant["bundle_sha256"],
        "store_grant_sha256": store.grant_sha256,
        "expected_snapshot_sha256": store.audit_snapshot_root_v2(),
        "max_root_references": 16,
        "max_lease_receipts": 4,
        "max_slot_scans": store.capacity,
        "max_collectible_entries": 2,
        "max_collectible_bytes": 128,
        "challenge_sha256": bytes((0xE8,)) * 32,
    }
