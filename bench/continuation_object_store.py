"""Independent state model for the tenant continuation object store."""

from __future__ import annotations

import hashlib
import struct
from typing import Any, Optional

from bench import continuation_bundle as bundle
from bench import continuation_capsule as capsule


class StoreError(ValueError):
    """The grant, operation, object, accounting, or store state is invalid."""


Record = dict[str, Any]
LOGICAL_INDEX_ENTRY_BYTES = 128
OPERATION_PUT = 1 << 0
OPERATION_GET = 1 << 1
OPERATION_RELEASE = 1 << 2
OPERATION_QUARANTINE = 1 << 3
OPERATION_VERIFY = 1 << 4
ALLOWED_OPERATIONS = (
    OPERATION_PUT
    | OPERATION_GET
    | OPERATION_RELEASE
    | OPERATION_QUARANTINE
    | OPERATION_VERIFY
)
GRANT_DOMAIN = b"glacier-continuation-store-grant-v1\x00"
SNAPSHOT_DOMAIN = b"glacier-continuation-store-snapshot-v1\x00"
ZERO_DIGEST = bytes(32)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise StoreError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise StoreError("invalid digest")
    return value


def _validate_grant(grant: Record) -> None:
    for name in (
        "authority_epoch",
        "allowed_operation_mask",
        "max_entries",
        "max_object_bytes",
        "max_payload_bytes",
        "max_index_bytes",
        "max_references",
    ):
        _u64(grant[name])
    for name in (
        "tenant_scope_sha256",
        "bundle_sha256",
        "challenge_sha256",
    ):
        _digest(grant[name])
    operations = grant["allowed_operation_mask"]
    if (
        grant["authority_epoch"] == 0
        or operations == 0
        or operations & ~ALLOWED_OPERATIONS
        or grant["max_entries"] == 0
        or grant["max_object_bytes"] == 0
        or grant["max_payload_bytes"] == 0
        or grant["max_index_bytes"] == 0
        or grant["max_references"] == 0
        or grant["max_object_bytes"] > grant["max_payload_bytes"]
    ):
        raise StoreError("invalid grant")


def grant_root(grant: Record) -> bytes:
    _validate_grant(grant)
    hasher = hashlib.sha256()
    for part in (
        GRANT_DOMAIN,
        _u64(grant["authority_epoch"]),
        grant["tenant_scope_sha256"],
        grant["bundle_sha256"],
        _u64(grant["allowed_operation_mask"]),
        _u64(grant["max_entries"]),
        _u64(grant["max_object_bytes"]),
        _u64(grant["max_payload_bytes"]),
        _u64(grant["max_index_bytes"]),
        _u64(grant["max_references"]),
        grant["challenge_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


class Store:
    """Bounded single-tenant/single-bundle store conformance model."""

    def __init__(
        self,
        grant: Record,
        expected_authority_epoch: int,
        capacity: int = 16,
        fail_after_new_entries: Optional[int] = None,
    ) -> None:
        _validate_grant(grant)
        if grant["authority_epoch"] != expected_authority_epoch:
            raise StoreError("stale grant")
        if grant["max_entries"] > capacity or capacity <= 0:
            raise StoreError("invalid capacity")
        self.grant = dict(grant)
        self.grant_sha256 = grant_root(grant)
        self.capacity = capacity
        self.slots: list[Optional[Record]] = [None] * capacity
        self.entry_count = 0
        self.live_entries = 0
        self.quarantined_entries = 0
        self.payload_bytes = 0
        self.logical_index_bytes = 0
        self.reference_count = 0
        self.closed = False
        self.fail_after_new_entries = fail_after_new_entries
        self.allocator_insertions = 0

    def _operation(self, operation: int) -> None:
        if self.closed:
            raise StoreError("store closed")
        if not self.grant["allowed_operation_mask"] & operation:
            raise StoreError("denied operation")

    def _find(self, expected: Record) -> Optional[int]:
        for index, slot in enumerate(self.slots):
            if (
                slot is not None
                and slot["byte_length"] == expected["byte_length"]
                and slot["sha256"] == expected["sha256"]
            ):
                return index
        return None

    def put(
        self,
        expected: Record,
        payload: bytes,
        provenance_sha256: bytes,
    ) -> Record:
        self._operation(OPERATION_PUT)
        _digest(provenance_sha256)
        if provenance_sha256 != self.grant["bundle_sha256"]:
            raise StoreError("invalid provenance")
        computed = bundle.blob_ref(self.grant["tenant_scope_sha256"], payload)
        if computed != expected:
            raise StoreError("blob mismatch")
        if expected["byte_length"] > self.grant["max_object_bytes"]:
            raise StoreError("object too large")
        for index, slot in enumerate(self.slots):
            if slot is None or slot["sha256"] != expected["sha256"]:
                continue
            if (
                slot["byte_length"] != expected["byte_length"]
                or slot["payload"] != payload
            ):
                raise StoreError("digest collision")
            if slot["state"] == "quarantined":
                raise StoreError("quarantined")
            if self.reference_count + 1 > self.grant["max_references"]:
                raise StoreError("reference budget exceeded")
            slot["reference_count"] += 1
            self.reference_count += 1
            return {
                "slot_index": index,
                "disposition": "reused",
                "reference_count": slot["reference_count"],
            }

        if self.entry_count >= self.grant["max_entries"]:
            raise StoreError("entry capacity exceeded")
        if (
            self.logical_index_bytes + LOGICAL_INDEX_ENTRY_BYTES
            > self.grant["max_index_bytes"]
        ):
            raise StoreError("index budget exceeded")
        if (
            self.payload_bytes + expected["byte_length"]
            > self.grant["max_payload_bytes"]
        ):
            raise StoreError("payload budget exceeded")
        if self.reference_count + 1 > self.grant["max_references"]:
            raise StoreError("reference budget exceeded")
        if (
            self.fail_after_new_entries is not None
            and self.allocator_insertions >= self.fail_after_new_entries
        ):
            raise StoreError("allocator failure")
        try:
            index = self.slots.index(None)
        except ValueError as error:
            raise StoreError("native capacity exceeded") from error
        owned = memoryview(payload).tobytes()
        self.slots[index] = {
            "state": "live",
            "byte_length": expected["byte_length"],
            "sha256": expected["sha256"],
            "payload": owned,
            "reference_count": 1,
            "provenance_sha256": provenance_sha256,
            "quarantine_reason_sha256": ZERO_DIGEST,
        }
        self.entry_count += 1
        self.live_entries += 1
        self.payload_bytes += expected["byte_length"]
        self.logical_index_bytes += LOGICAL_INDEX_ENTRY_BYTES
        self.reference_count += 1
        self.allocator_insertions += 1
        return {
            "slot_index": index,
            "disposition": "inserted",
            "reference_count": 1,
        }

    def get(self, expected: Record) -> bytes:
        self._operation(OPERATION_GET)
        index = self._find(expected)
        if index is None:
            raise StoreError("not found")
        slot = self.slots[index]
        assert slot is not None
        if slot["state"] == "quarantined":
            raise StoreError("quarantined")
        computed = bundle.blob_ref(
            self.grant["tenant_scope_sha256"], slot["payload"]
        )
        if computed != expected:
            raise StoreError("corrupt payload")
        return memoryview(slot["payload"]).tobytes()

    def release(self, expected: Record) -> None:
        self._operation(OPERATION_RELEASE)
        index = self._find(expected)
        if index is None:
            raise StoreError("not found")
        slot = self.slots[index]
        assert slot is not None
        if slot["reference_count"] > 1:
            slot["reference_count"] -= 1
            self.reference_count -= 1
            return
        self.slots[index] = None
        self.entry_count -= 1
        if slot["state"] == "live":
            self.live_entries -= 1
        else:
            self.quarantined_entries -= 1
        self.payload_bytes -= slot["byte_length"]
        self.logical_index_bytes -= LOGICAL_INDEX_ENTRY_BYTES
        self.reference_count -= 1

    def quarantine(self, expected: Record, reason_sha256: bytes) -> None:
        self._operation(OPERATION_QUARANTINE)
        _digest(reason_sha256)
        index = self._find(expected)
        if index is None:
            raise StoreError("not found")
        slot = self.slots[index]
        assert slot is not None
        if slot["state"] == "quarantined":
            raise StoreError("quarantined")
        slot["state"] = "quarantined"
        slot["quarantine_reason_sha256"] = reason_sha256
        self.live_entries -= 1
        self.quarantined_entries += 1

    def verify_all(self) -> None:
        self._operation(OPERATION_VERIFY)
        entry_count = live = quarantined = payload = index_bytes = references = 0
        seen_roots: set[bytes] = set()
        for slot in self.slots:
            if slot is None:
                continue
            if (
                slot["reference_count"] == 0
                or slot["byte_length"] > self.grant["max_object_bytes"]
                or slot["provenance_sha256"] != self.grant["bundle_sha256"]
                or slot["sha256"] in seen_roots
            ):
                raise StoreError("invalid accounting")
            seen_roots.add(slot["sha256"])
            if slot["state"] == "live":
                if slot["quarantine_reason_sha256"] != ZERO_DIGEST:
                    raise StoreError("invalid live state")
                live += 1
            elif slot["state"] == "quarantined":
                _digest(slot["quarantine_reason_sha256"])
                quarantined += 1
            else:
                raise StoreError("invalid state")
            computed = bundle.blob_ref(
                self.grant["tenant_scope_sha256"], slot["payload"]
            )
            if (
                computed["byte_length"] != slot["byte_length"]
                or computed["sha256"] != slot["sha256"]
            ):
                raise StoreError("corrupt payload")
            entry_count += 1
            payload += slot["byte_length"]
            index_bytes += LOGICAL_INDEX_ENTRY_BYTES
            references += slot["reference_count"]
        if (
            entry_count != self.entry_count
            or live != self.live_entries
            or quarantined != self.quarantined_entries
            or payload != self.payload_bytes
            or index_bytes != self.logical_index_bytes
            or references != self.reference_count
            or entry_count > self.grant["max_entries"]
            or payload > self.grant["max_payload_bytes"]
            or index_bytes > self.grant["max_index_bytes"]
            or references > self.grant["max_references"]
        ):
            raise StoreError("accounting mismatch")

    def snapshot_root(self) -> bytes:
        self.verify_all()
        hasher = hashlib.sha256()
        hasher.update(SNAPSHOT_DOMAIN)
        hasher.update(self.grant_sha256)
        for value in (
            self.entry_count,
            self.live_entries,
            self.quarantined_entries,
            self.payload_bytes,
            self.logical_index_bytes,
            self.reference_count,
        ):
            hasher.update(_u64(value))
        for index, slot in enumerate(self.slots):
            if slot is None:
                continue
            state = 1 if slot["state"] == "live" else 2
            hasher.update(_u64(index))
            hasher.update(_u64(state))
            hasher.update(_u64(slot["byte_length"]))
            hasher.update(slot["sha256"])
            hasher.update(_u64(slot["reference_count"]))
            hasher.update(slot["provenance_sha256"])
            hasher.update(slot["quarantine_reason_sha256"])
        return hasher.digest()

    def _rollback(self, actions: list[Record]) -> None:
        for action in reversed(actions):
            index = action["slot_index"]
            slot = self.slots[index]
            assert slot is not None
            if action["inserted"]:
                self.slots[index] = None
                self.entry_count -= 1
                if slot["state"] == "live":
                    self.live_entries -= 1
                else:
                    self.quarantined_entries -= 1
                self.payload_bytes -= slot["byte_length"]
                self.logical_index_bytes -= LOGICAL_INDEX_ENTRY_BYTES
                self.reference_count -= slot["reference_count"]
                self.allocator_insertions -= 1
            else:
                slot["reference_count"] -= 1
                self.reference_count -= 1

    def import_bundle(
        self,
        bundle_wire: bytes,
        expected_config: Record,
        capsule_wire: bytes,
        objects: dict[str, capsule.Object],
    ) -> Record:
        self._operation(OPERATION_PUT)
        decoded = bundle.decode_and_verify(
            bundle_wire,
            expected_config,
            capsule_wire,
            objects,
        )
        if (
            decoded["envelope_sha256"] != self.grant["bundle_sha256"]
            or decoded["config"]["tenant_scope_sha256"]
            != self.grant["tenant_scope_sha256"]
        ):
            raise StoreError("bundle mismatch")
        actions: list[Record] = []
        unique_entries_added = references_reused = payload_bytes_added = 0
        try:
            for entry, name in zip(decoded["entries"], capsule.OBJECT_NAMES):
                receipt = self.put(
                    {
                        "byte_length": entry["byte_length"],
                        "sha256": entry["blob_sha256"],
                    },
                    objects[name][1],
                    decoded["envelope_sha256"],
                )
                inserted = receipt["disposition"] == "inserted"
                actions.append(
                    {"slot_index": receipt["slot_index"], "inserted": inserted}
                )
                if inserted:
                    unique_entries_added += 1
                    payload_bytes_added += entry["byte_length"]
                else:
                    references_reused += 1
        except Exception:
            self._rollback(actions)
            raise
        return {
            "bundle_sha256": decoded["envelope_sha256"],
            "semantic_references": len(capsule.OBJECT_NAMES),
            "unique_entries_added": unique_entries_added,
            "references_reused": references_reused,
            "payload_bytes_added": payload_bytes_added,
            "entry_count_after": self.entry_count,
            "payload_bytes_after": self.payload_bytes,
            "reference_count_after": self.reference_count,
            "snapshot_sha256": self.snapshot_root(),
        }


def demo_grant(bundle_sha256: bytes) -> Record:
    return {
        "authority_epoch": 11,
        "tenant_scope_sha256": bytes((0x6D,)) * 32,
        "bundle_sha256": bundle_sha256,
        "allowed_operation_mask": ALLOWED_OPERATIONS,
        "max_entries": 12,
        "max_object_bytes": 64,
        "max_payload_bytes": 512,
        "max_index_bytes": 12 * LOGICAL_INDEX_ENTRY_BYTES,
        "max_references": 16,
        "challenge_sha256": bytes((0xF2,)) * 32,
    }


def build_demo() -> Record:
    bundle_demo = bundle.build_demo()
    grant = demo_grant(bundle_demo["encoded"][-32:])
    return {"bundle": bundle_demo, "grant": grant}
