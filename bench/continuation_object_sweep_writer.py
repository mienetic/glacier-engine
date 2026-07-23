"""Independent least-authority sweep writer and crash-storage model."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct
from typing import Any

from bench import continuation_object_sweep_record as record


class SweepWriterError(RuntimeError):
    """The capability, writer phase, snapshot, or repair policy is invalid."""


class InjectedFault(SweepWriterError):
    """One deterministic I/O call had an intentionally uncertain result."""


ABI_VERSION = 0x4743_5357_0000_0001
SNAPSHOT_DOMAIN = b"glacier-continuation-sweep-writer-snapshot-v1\x00"
BODY_WRITE = "body_write"
BODY_SYNC = "body_sync"
FOOTER_WRITE = "footer_write"
FOOTER_SYNC = "footer_sync"
REPAIR_TRUNCATE = "repair_truncate"
REPAIR_SYNC = "repair_sync"
APPEND_PHASES = (BODY_WRITE, BODY_SYNC, FOOTER_WRITE, FOOTER_SYNC)
REPAIR_PHASES = (REPAIR_TRUNCATE, REPAIR_SYNC)


@dataclass(frozen=True)
class Fault:
    call_index: int
    timing: str
    write_prefix: int | None = None


Snapshot = dict[str, Any]
RecoveryPlan = dict[str, Any]


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise SweepWriterError("u64 out of range")
    return struct.pack("<Q", value)


def make_snapshot(
    storage_epoch: int,
    lease_generation: int,
    stream: bytes,
    max_bytes: int,
) -> Snapshot:
    if (
        not isinstance(stream, bytes)
        or storage_epoch == 0
        or lease_generation == 0
        or len(stream) > max_bytes
    ):
        raise SweepWriterError("invalid storage snapshot input")
    stream_sha256 = hashlib.sha256(stream).digest()
    snapshot_sha256 = hashlib.sha256(
        b"".join(
            (
                SNAPSHOT_DOMAIN,
                _u64(ABI_VERSION),
                _u64(storage_epoch),
                _u64(lease_generation),
                _u64(len(stream)),
                _u64(max_bytes),
                stream_sha256,
            )
        )
    ).digest()
    return {
        "abi": ABI_VERSION,
        "storage_epoch": storage_epoch,
        "lease_generation": lease_generation,
        "observed_bytes": len(stream),
        "max_bytes": max_bytes,
        "stream_sha256": stream_sha256,
        "snapshot_sha256": snapshot_sha256,
    }


def validate_snapshot(snapshot: Snapshot, stream: bytes) -> None:
    try:
        expected = make_snapshot(
            snapshot["storage_epoch"],
            snapshot["lease_generation"],
            stream,
            snapshot["max_bytes"],
        )
    except (KeyError, TypeError) as exc:
        raise SweepWriterError("invalid storage snapshot") from exc
    if snapshot != expected:
        raise SweepWriterError("storage snapshot mismatch")


def plan_recovery(
    stream: bytes,
    anchor: dict[str, Any],
    snapshot: Snapshot,
) -> RecoveryPlan:
    validate_snapshot(snapshot, stream)
    classification = record.classify_recovery(stream, anchor)
    status = classification["status"]
    if status == "clean":
        action = "open_clean"
    elif status in (
        "short_body_tail",
        "body_without_footer",
        "partial_footer_tail",
    ):
        action = "repair_incomplete_tail"
    elif status == "corrupt_record":
        action = "reject_corrupt"
    else:
        raise SweepWriterError("unknown recovery classification")
    return {
        "action": action,
        "snapshot_sha256": snapshot["snapshot_sha256"],
        "classification": classification,
        "truncate_to_bytes": classification["committed_bytes"],
        "discard_tail_bytes": classification["tail_bytes"],
    }


class DeterministicStorage:
    """Fixed-capacity model with an exclusive generation and sync watermark."""

    def __init__(self, initial: bytes, max_bytes: int, storage_epoch: int) -> None:
        if (
            not isinstance(initial, bytes)
            or storage_epoch == 0
            or len(initial) > max_bytes
        ):
            raise SweepWriterError("invalid deterministic storage")
        self.backing = bytearray(max_bytes)
        self.backing[: len(initial)] = initial
        self.length = len(initial)
        self.synced_length = len(initial)
        self.storage_epoch = storage_epoch
        self.next_generation = 1
        self.active_generation = 0
        self.expected_phase = BODY_WRITE
        self.fault: Fault | None = None
        self.call_index = 0
        self.trace: list[str] = []
        self.append_generation = 0
        self.append_snapshot_sha256 = bytes(32)
        self.repair_generation = 0
        self.repair_snapshot_sha256 = bytes(32)
        self.repair_expected_bytes = 0
        self.repair_target_bytes = 0

    @property
    def bytes(self) -> bytes:
        return bytes(self.backing[: self.length])

    def acquire(self) -> Lease:
        if self.active_generation != 0:
            raise SweepWriterError("exclusive lease is busy")
        if self.next_generation > 0xFFFFFFFFFFFFFFFF:
            raise SweepWriterError("lease generation exhausted")
        generation = self.next_generation
        self.next_generation += 1
        self.active_generation = generation
        self.expected_phase = BODY_WRITE
        self.fault = None
        self.call_index = 0
        self.trace.clear()
        self._clear_append_authorization()
        self._clear_repair_authorization()
        return Lease(
            self,
            generation,
            make_snapshot(
                self.storage_epoch,
                generation,
                self.bytes,
                len(self.backing),
            ),
        )

    def set_fault(self, fault: Fault | None) -> None:
        if fault is not None and fault.timing not in ("before", "after"):
            raise SweepWriterError("invalid fault timing")
        self.fault = fault
        self.call_index = 0
        self.trace.clear()

    def _clear_repair_authorization(self) -> None:
        self.repair_generation = 0
        self.repair_snapshot_sha256 = bytes(32)
        self.repair_expected_bytes = 0
        self.repair_target_bytes = 0

    def _clear_append_authorization(self) -> None:
        self.append_generation = 0
        self.append_snapshot_sha256 = bytes(32)

    def validate(self, generation: int) -> None:
        if generation == 0 or self.active_generation != generation:
            raise SweepWriterError("stale or inactive capability")

    def crash_bounds(self) -> tuple[int, int]:
        return (
            min(self.length, self.synced_length),
            max(self.length, self.synced_length),
        )

    def crash_persist(self, persisted_bytes: int) -> None:
        lower, upper = self.crash_bounds()
        if not lower <= persisted_bytes <= upper:
            raise SweepWriterError("invalid crash persistence point")
        self.length = persisted_bytes
        self.synced_length = persisted_bytes
        self.active_generation = 0
        self.expected_phase = BODY_WRITE
        self.fault = None
        self.call_index = 0
        self._clear_append_authorization()
        self._clear_repair_authorization()

    def _begin(self, generation: int, phase: str, *, write: bool) -> Fault | None:
        self.validate(generation)
        if self.expected_phase != phase:
            raise SweepWriterError("invalid I/O order")
        self.trace.append(phase)
        call_index = self.call_index
        self.call_index += 1
        fault = self.fault
        if fault is None or fault.call_index != call_index:
            return None
        if not write and fault.write_prefix is not None:
            raise SweepWriterError("write prefix on sync operation")
        if fault.timing == "before":
            if fault.write_prefix is not None:
                raise SweepWriterError("write prefix on before fault")
            raise InjectedFault(phase)
        return fault

    def _append(
        self,
        generation: int,
        phase: str,
        next_phase: str,
        payload: bytes,
    ) -> None:
        fault = self._begin(generation, phase, write=True)
        write_length = len(payload)
        if fault is not None and fault.write_prefix is not None:
            if not 0 <= fault.write_prefix <= len(payload):
                raise SweepWriterError("invalid partial write length")
            write_length = fault.write_prefix
        if self.length + write_length > len(self.backing):
            raise SweepWriterError("storage capacity exceeded")
        self.backing[self.length : self.length + write_length] = payload[
            :write_length
        ]
        self.length += write_length
        if write_length == len(payload):
            self.expected_phase = next_phase
        if fault is not None:
            raise InjectedFault(phase)

    def _sync(self, generation: int, phase: str, next_phase: str) -> None:
        fault = self._begin(generation, phase, write=False)
        self.synced_length = self.length
        self.expected_phase = next_phase
        if fault is not None:
            raise InjectedFault(phase)


class AppendCapability:
    def __init__(self, lease: Lease) -> None:
        self._storage = lease.storage
        self._generation = lease.generation
        self.snapshot = lease.snapshot

    def validate(self, expected_current_bytes: int) -> None:
        self._storage.validate(self._generation)
        if (
            self._storage.append_generation != self._generation
            or self._storage.append_snapshot_sha256
            != self.snapshot["snapshot_sha256"]
            or self._storage.length != expected_current_bytes
        ):
            raise SweepWriterError("append capability snapshot is stale")

    def append_body(self, payload: bytes) -> None:
        if len(payload) != record.BODY_BYTES:
            raise SweepWriterError("invalid body write")
        self._storage._append(
            self._generation, BODY_WRITE, BODY_SYNC, payload
        )

    def sync_body(self) -> None:
        self._storage._sync(self._generation, BODY_SYNC, FOOTER_WRITE)

    def append_footer(self, payload: bytes) -> None:
        if len(payload) != record.COMMIT_FOOTER_BYTES:
            raise SweepWriterError("invalid footer write")
        self._storage._append(
            self._generation, FOOTER_WRITE, FOOTER_SYNC, payload
        )

    def sync_footer(self) -> None:
        self._storage._sync(self._generation, FOOTER_SYNC, BODY_WRITE)


class RepairCapability:
    def __init__(self, lease: Lease, plan: RecoveryPlan) -> None:
        self._storage = lease.storage
        self._generation = lease.generation
        self.snapshot = lease.snapshot
        self.expected_current_bytes = self.snapshot["observed_bytes"]
        self.target_bytes = plan["truncate_to_bytes"]
        self.discarded_tail_bytes = plan["discard_tail_bytes"]
        self.final_record_sha256 = plan["classification"][
            "final_record_sha256"
        ]

    def validate(self) -> None:
        self._storage.validate(self._generation)

    def truncate(self) -> None:
        if (
            self._storage.repair_generation != self._generation
            or self._storage.repair_snapshot_sha256
            != self.snapshot["snapshot_sha256"]
        ):
            raise SweepWriterError("repair capability is not bound")
        fault = self._storage._begin(
            self._generation, REPAIR_TRUNCATE, write=False
        )
        if (
            self._storage.length != self._storage.repair_expected_bytes
            or not 0
            <= self._storage.repair_target_bytes
            <= self._storage.repair_expected_bytes
        ):
            raise SweepWriterError("repair target does not match storage")
        self._storage.length = self._storage.repair_target_bytes
        self._storage.expected_phase = REPAIR_SYNC
        if fault is not None:
            raise InjectedFault(REPAIR_TRUNCATE)

    def sync(self) -> None:
        self._storage._sync(self._generation, REPAIR_SYNC, BODY_WRITE)


class Lease:
    def __init__(
        self,
        storage: DeterministicStorage,
        generation: int,
        snapshot: Snapshot,
    ) -> None:
        self.storage = storage
        self.generation = generation
        self.snapshot = snapshot

    def append_capability(self) -> AppendCapability:
        self.storage.validate(self.generation)
        if (
            self.storage.expected_phase != BODY_WRITE
            or self.storage.length != self.snapshot["observed_bytes"]
        ):
            raise SweepWriterError("lease cannot mint append capability")
        if self.storage.append_generation not in (0, self.generation):
            raise SweepWriterError("foreign append capability is active")
        if (
            self.storage.append_generation == self.generation
            and self.storage.append_snapshot_sha256
            != self.snapshot["snapshot_sha256"]
        ):
            raise SweepWriterError("append snapshot binding changed")
        self.storage.append_generation = self.generation
        self.storage.append_snapshot_sha256 = self.snapshot[
            "snapshot_sha256"
        ]
        return AppendCapability(self)

    def prepare_repair(
        self,
        stream: bytes,
        anchor: dict[str, Any],
    ) -> RepairCapability:
        self.storage.validate(self.generation)
        if self.storage.expected_phase != BODY_WRITE:
            raise SweepWriterError("lease cannot enter repair phase")
        plan = plan_recovery(stream, anchor, self.snapshot)
        if plan["action"] == "open_clean":
            raise SweepWriterError("repair is not required")
        if plan["action"] == "reject_corrupt":
            raise SweepWriterError("corrupt evidence cannot receive repair")
        self.storage._clear_append_authorization()
        self.storage.expected_phase = REPAIR_TRUNCATE
        self.storage.repair_generation = self.generation
        self.storage.repair_snapshot_sha256 = self.snapshot[
            "snapshot_sha256"
        ]
        self.storage.repair_expected_bytes = self.snapshot["observed_bytes"]
        self.storage.repair_target_bytes = plan["truncate_to_bytes"]
        return RepairCapability(self, plan)

    def release(self) -> None:
        self.storage.validate(self.generation)
        self.storage.active_generation = 0
        self.generation = 0


class Writer:
    def __init__(
        self,
        capability: AppendCapability,
        record_epoch: int,
        next_sequence: int,
        previous_record_sha256: bytes,
        committed_bytes: int,
        sequence_exhausted: bool,
    ) -> None:
        self.capability = capability
        self.record_epoch = record_epoch
        self.next_sequence = next_sequence
        self.previous_record_sha256 = previous_record_sha256
        self.committed_bytes = committed_bytes
        self.sequence_exhausted = sequence_exhausted
        self.state = "ready"

    @classmethod
    def open_clean(
        cls,
        stream: bytes,
        anchor: dict[str, Any],
        capability: AppendCapability,
    ) -> Writer:
        capability.validate(capability.snapshot["observed_bytes"])
        plan = plan_recovery(stream, anchor, capability.snapshot)
        if plan["action"] == "repair_incomplete_tail":
            raise SweepWriterError("incomplete tail requires explicit repair")
        if plan["action"] == "reject_corrupt":
            raise SweepWriterError("corrupt evidence cannot be opened")
        classification = plan["classification"]
        committed = classification["committed_records"]
        exhausted = committed != 0 and classification["last_sequence"] == 0xFFFFFFFFFFFFFFFF
        if committed == 0:
            next_sequence = anchor["next_sequence"]
        elif exhausted:
            next_sequence = classification["last_sequence"]
        else:
            next_sequence = classification["last_sequence"] + 1
        return cls(
            capability,
            anchor["record_epoch"],
            next_sequence,
            classification["final_record_sha256"],
            classification["committed_bytes"],
            exhausted,
        )

    def append_record(self, encoded: bytes) -> dict[str, Any]:
        if self.state != "ready":
            raise SweepWriterError("writer must be reopened")
        self.capability.validate(self.committed_bytes)
        if self.sequence_exhausted:
            raise SweepWriterError("record sequence exhausted")
        decoded = record.decode(encoded)
        value = decoded["input"]
        if (
            value["record_epoch"] != self.record_epoch
            or value["sequence"] != self.next_sequence
            or value["previous_record_sha256"] != self.previous_record_sha256
        ):
            raise SweepWriterError("record does not match writer position")
        if self.committed_bytes + len(encoded) > self.capability.snapshot["max_bytes"]:
            raise SweepWriterError("storage capacity exceeded")
        append_plan = record.append_plan(encoded)
        self.state = "poisoned"
        self.capability.append_body(append_plan["body"])
        self.capability.sync_body()
        self.capability.append_footer(append_plan["commit_footer"])
        self.capability.sync_footer()
        self.committed_bytes += len(encoded)
        self.previous_record_sha256 = decoded["record_sha256"]
        self.sequence_exhausted = self.next_sequence == 0xFFFFFFFFFFFFFFFF
        if not self.sequence_exhausted:
            self.next_sequence += 1
        self.state = "ready"
        return {
            "sequence": value["sequence"],
            "committed_bytes": self.committed_bytes,
            "record_sha256": decoded["record_sha256"],
            "next_sequence_exhausted": self.sequence_exhausted,
            "body_sync_exercised": True,
            "footer_sync_exercised": True,
        }


class Repairer:
    def __init__(self, capability: RepairCapability, plan: RecoveryPlan) -> None:
        self.capability = capability
        self.plan = plan
        self.state = "ready"

    @classmethod
    def create(
        cls,
        stream: bytes,
        anchor: dict[str, Any],
        capability: RepairCapability,
    ) -> Repairer:
        capability.validate()
        plan = plan_recovery(stream, anchor, capability.snapshot)
        if plan["action"] == "open_clean":
            raise SweepWriterError("repair is not required")
        if plan["action"] == "reject_corrupt":
            raise SweepWriterError("corrupt evidence cannot receive repair")
        if (
            capability.expected_current_bytes
            != capability.snapshot["observed_bytes"]
            or capability.target_bytes != plan["truncate_to_bytes"]
            or capability.discarded_tail_bytes != plan["discard_tail_bytes"]
            or capability.final_record_sha256
            != plan["classification"]["final_record_sha256"]
        ):
            raise SweepWriterError("repair capability binding mismatch")
        return cls(capability, plan)

    def apply(self) -> dict[str, Any]:
        if self.state != "ready":
            raise SweepWriterError("repairer is not ready")
        self.capability.validate()
        self.state = "poisoned"
        self.capability.truncate()
        self.capability.sync()
        self.state = "complete"
        return {
            "original_bytes": self.capability.snapshot["observed_bytes"],
            "committed_bytes": self.plan["truncate_to_bytes"],
            "discarded_tail_bytes": self.plan["discard_tail_bytes"],
            "final_record_sha256": self.plan["classification"][
                "final_record_sha256"
            ],
            "truncate_exercised": True,
            "sync_exercised": True,
        }
