"""Independent deterministic storage model for ActionOutbox W4b-c.

The retained report in this module is logical crash-storage evidence.  It
models write, sync, truncate, process loss, snapshot fencing, and explicit
tail repair without opening a real file.  Host filesystem and subprocess
observations belong in a separate adapter test and must not be inferred from
this report.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import dataclass
from functools import lru_cache
import hashlib
import hmac
import json
from pathlib import Path
import struct
import subprocess
from typing import Any, Mapping, Sequence

from bench import action_outbox_conformance as protocol


class ActionOutboxStoreError(RuntimeError):
    """The storage snapshot, authority, phase, or report is invalid."""


class InjectedFault(ActionOutboxStoreError):
    """A deterministic storage call returned an intentionally uncertain result."""


Digest = bytes
Record = dict[str, Any]

U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)

STORE_ABI = 0x4754_4F53_0000_0001
REPORT_ABI = 0x4754_4F44_0000_0001

BODY_WRITE = "body_write"
BODY_SYNC = "body_sync"
FOOTER_WRITE = "footer_write"
FOOTER_SYNC = "footer_sync"
APPEND_PHASES = (BODY_WRITE, BODY_SYNC, FOOTER_WRITE, FOOTER_SYNC)
APPEND_PHASE_VALUES = {name: index + 1 for index, name in enumerate(APPEND_PHASES)}

REPAIR_TRUNCATE = "repair_truncate"
REPAIR_SYNC = "repair_sync"
REPAIR_PHASES = (REPAIR_TRUNCATE, REPAIR_SYNC)
REPAIR_PHASE_VALUES = {name: index + 1 for index, name in enumerate(REPAIR_PHASES)}

TIMING_BEFORE = "before"
TIMING_AFTER = "after"
FAULT_TIMINGS = (TIMING_BEFORE, TIMING_AFTER)
FAULT_TIMING_VALUES = {name: index + 1 for index, name in enumerate(FAULT_TIMINGS)}

PERSIST_LOWER = "lower"
PERSIST_UPPER = "upper"
PERSIST_CHOICES = (PERSIST_LOWER, PERSIST_UPPER)
PERSIST_CHOICE_VALUES = {name: index + 1 for index, name in enumerate(PERSIST_CHOICES)}

OPEN_CLEAN = 1
REPAIR_REQUIRED = 2

REPAIRABLE_STATUSES = frozenset(
    {
        protocol.RECOVERY_SHORT_BODY_TAIL,
        protocol.RECOVERY_BODY_WITHOUT_FOOTER,
        protocol.RECOVERY_PARTIAL_FOOTER_TAIL,
    }
)


def _valid_tail_shape(status: int, discarded_tail_bytes: int) -> bool:
    if status == protocol.RECOVERY_CLEAN:
        return discarded_tail_bytes == 0
    if status == protocol.RECOVERY_SHORT_BODY_TAIL:
        return 0 < discarded_tail_bytes < protocol.RECORD_BODY_BYTES
    if status == protocol.RECOVERY_BODY_WITHOUT_FOOTER:
        return discarded_tail_bytes == protocol.RECORD_BODY_BYTES
    if status == protocol.RECOVERY_PARTIAL_FOOTER_TAIL:
        return protocol.RECORD_BODY_BYTES < discarded_tail_bytes < protocol.RECORD_BYTES
    return False


CONTENT_SNAPSHOT_DOMAIN = b"glacier-action-outbox-store-content-snapshot-v1\x00"
LEASE_BINDING_DOMAIN = b"glacier-action-outbox-store-lease-binding-v1\x00"
REPAIR_PLAN_DOMAIN = b"glacier-action-outbox-store-repair-plan-v1\x00"
APPEND_PHASE_CASE_DOMAIN = b"glacier-action-outbox-store-append-phase-case-v1\x00"
APPEND_PHASE_MATRIX_DOMAIN = b"glacier-action-outbox-store-append-phase-matrix-v1\x00"
PARTIAL_WRITE_CASE_DOMAIN = b"glacier-action-outbox-store-partial-write-case-v1\x00"
PARTIAL_WRITE_MATRIX_DOMAIN = b"glacier-action-outbox-store-partial-write-matrix-v1\x00"
REPAIR_TAIL_CASE_DOMAIN = b"glacier-action-outbox-store-repair-tail-case-v1\x00"
REPAIR_TAIL_MATRIX_DOMAIN = b"glacier-action-outbox-store-repair-tail-matrix-v1\x00"
REPAIR_FAULT_CASE_DOMAIN = b"glacier-action-outbox-store-repair-fault-case-v1\x00"
REPAIR_FAULT_MATRIX_DOMAIN = b"glacier-action-outbox-store-repair-fault-matrix-v1\x00"
REPORT_DOMAIN = b"glacier-action-outbox-store-conformance-report-v1\x00"

SNAPSHOT_FIELDS = (
    "abi_version",
    "header_sha256",
    "observed_bytes",
    "maximum_bytes",
    "stream_sha256",
    "recovery_status",
    "committed_bytes",
    "discarded_tail_bytes",
    "committed_records",
    "final_chain_sha256",
    "state_sha256",
    "ledger_sha256",
    "snapshot_sha256",
)
LEASE_FIELDS = (
    "abi_version",
    "storage_epoch",
    "lease_generation",
    "snapshot_sha256",
    "lease_sha256",
)
REPAIR_PLAN_FIELDS = (
    "abi_version",
    "lease_sha256",
    "recovery_status",
    "observed_bytes",
    "committed_bytes",
    "discarded_tail_bytes",
    "final_chain_sha256",
    "state_sha256",
    "ledger_sha256",
    "plan_sha256",
)

REPORT_SCHEMA = "glacier.action-outbox-store-conformance/v1"
REPORT_FIELDS = (
    "schema",
    "report_abi",
    "store_abi",
    "protocol_report_abi",
    "header_bytes",
    "record_body_bytes",
    "commit_footer_bytes",
    "record_bytes",
    "maximum_file_bytes",
    "journal_bytes",
    "record_count",
    "action_count",
    "append_phase_case_count",
    "partial_write_case_count",
    "repair_tail_case_count",
    "repair_fault_case_count",
    "header_sha256",
    "protocol_report_sha256",
    "journal_sha256",
    "initial_snapshot_sha256",
    "uncertain_snapshot_sha256",
    "final_snapshot_sha256",
    "append_phase_matrix_sha256",
    "partial_write_matrix_sha256",
    "repair_tail_matrix_sha256",
    "repair_fault_matrix_sha256",
    "final_chain_sha256",
    "final_state_sha256",
    "ledger_sha256",
    "report_sha256",
    "append_phases",
    "repair_phases",
    "ledger",
)
MAXIMUM_JSON_BYTES = 1024 * 1024


def _u8(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= 0xFF:
        raise ActionOutboxStoreError("u8 out of range")
    return bytes((value,))


def _u64(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise ActionOutboxStoreError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: Any, where: str, *, allow_zero: bool = False) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise ActionOutboxStoreError(f"{where} is not a digest")
    if not allow_zero and hmac.compare_digest(value, ZERO_DIGEST):
        raise ActionOutboxStoreError(f"{where} is zero")
    return value


def _hex_digest(value: Any, where: str) -> Digest:
    if type(value) is not str or len(value) != 64:
        raise ActionOutboxStoreError(f"{where} is not canonical hex")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise ActionOutboxStoreError(f"{where} is not canonical hex") from error
    if decoded.hex() != value:
        raise ActionOutboxStoreError(f"{where} is not canonical hex")
    return _digest(decoded, where)


def _hex_u64(value: Any, where: str) -> int:
    if type(value) is not str or len(value) != 16:
        raise ActionOutboxStoreError(f"{where} is not canonical u64 hex")
    try:
        decoded = int(value, 16)
    except ValueError as error:
        raise ActionOutboxStoreError(f"{where} is not canonical u64 hex") from error
    if f"{decoded:016x}" != value:
        raise ActionOutboxStoreError(f"{where} is not canonical u64 hex")
    return decoded


def _sha(domain: bytes, *parts: bytes) -> Digest:
    if type(domain) is not bytes or not domain.endswith(b"\x00"):
        raise ActionOutboxStoreError("invalid hash domain")
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        if type(part) is not bytes:
            raise ActionOutboxStoreError("hash input is not bytes")
        hasher.update(part)
    return hasher.digest()


def _strict_record(value: Any, fields: Sequence[str], where: str) -> Record:
    if not isinstance(value, dict) or tuple(value) != tuple(fields):
        raise ActionOutboxStoreError(f"{where} has noncanonical fields")
    return value


def maximum_file_bytes(header: Mapping[str, Any]) -> int:
    maximum_records = header.get("maximum_records")
    if type(maximum_records) is not int or not 0 < maximum_records <= U64_MAX:
        raise ActionOutboxStoreError("invalid maximum record count")
    result = protocol.HEADER_BYTES + maximum_records * protocol.RECORD_BYTES
    if result > U64_MAX:
        raise ActionOutboxStoreError("maximum file length overflow")
    return result


def content_snapshot(
    stream: bytes,
    expected_header_sha256: Digest,
    maximum_bytes: int,
) -> Record:
    header_root = _digest(expected_header_sha256, "expected header")
    if (
        type(stream) is not bytes
        or type(maximum_bytes) is not int
        or not protocol.HEADER_BYTES <= len(stream) <= maximum_bytes <= U64_MAX
    ):
        raise ActionOutboxStoreError("invalid storage content")
    recovered = protocol.recover(stream, header_root)
    ledger_root = protocol.ledger_sha256(recovered["ledger"])
    stream_root = hashlib.sha256(stream).digest()
    result: Record = {
        "abi_version": STORE_ABI,
        "header_sha256": header_root,
        "observed_bytes": len(stream),
        "maximum_bytes": maximum_bytes,
        "stream_sha256": stream_root,
        "recovery_status": recovered["status"],
        "committed_bytes": recovered["committed_bytes"],
        "discarded_tail_bytes": recovered["discarded_tail_bytes"],
        "committed_records": recovered["ledger"]["committed_records"],
        "final_chain_sha256": recovered["final_chain_sha256"],
        "state_sha256": recovered["state_sha256"],
        "ledger_sha256": ledger_root,
        "snapshot_sha256": ZERO_DIGEST,
    }
    result["snapshot_sha256"] = content_snapshot_sha256(result)
    return validate_content_snapshot(result)


def content_snapshot_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        CONTENT_SNAPSHOT_DOMAIN,
        _u64(value["abi_version"]),
        _digest(value["header_sha256"], "snapshot header"),
        _u64(value["observed_bytes"]),
        _u64(value["maximum_bytes"]),
        _digest(value["stream_sha256"], "snapshot stream"),
        _u8(value["recovery_status"]),
        _u64(value["committed_bytes"]),
        _u64(value["discarded_tail_bytes"]),
        _u64(value["committed_records"]),
        _digest(value["final_chain_sha256"], "snapshot final chain"),
        _digest(value["state_sha256"], "snapshot state"),
        _digest(value["ledger_sha256"], "snapshot ledger"),
    )


def validate_content_snapshot(value: Any) -> Record:
    result = _strict_record(value, SNAPSHOT_FIELDS, "content snapshot")
    if (
        result["abi_version"] != STORE_ABI
        or type(result["recovery_status"]) is not int
        or result["recovery_status"] not in protocol.RECOVERY_NAMES
        or type(result["observed_bytes"]) is not int
        or type(result["maximum_bytes"]) is not int
        or type(result["committed_bytes"]) is not int
        or type(result["discarded_tail_bytes"]) is not int
        or type(result["committed_records"]) is not int
    ):
        raise ActionOutboxStoreError("invalid content snapshot")
    committed_payload = result["committed_bytes"] - protocol.HEADER_BYTES
    if (
        not protocol.HEADER_BYTES
        <= result["committed_bytes"]
        <= result["observed_bytes"]
        <= result["maximum_bytes"]
        or committed_payload % protocol.RECORD_BYTES != 0
        or result["committed_records"] != committed_payload // protocol.RECORD_BYTES
        or result["discarded_tail_bytes"]
        != result["observed_bytes"] - result["committed_bytes"]
        or not _valid_tail_shape(
            result["recovery_status"],
            result["discarded_tail_bytes"],
        )
    ):
        raise ActionOutboxStoreError("invalid content snapshot")
    for name in (
        "header_sha256",
        "stream_sha256",
        "final_chain_sha256",
        "state_sha256",
        "ledger_sha256",
        "snapshot_sha256",
    ):
        _digest(result[name], f"snapshot {name}")
    if not hmac.compare_digest(
        result["snapshot_sha256"],
        content_snapshot_sha256(result),
    ):
        raise ActionOutboxStoreError("content snapshot root mismatch")
    return deepcopy(result)


def make_lease_binding(
    snapshot_value: Any,
    storage_epoch: int,
    lease_generation: int,
) -> Record:
    snapshot = validate_content_snapshot(snapshot_value)
    result: Record = {
        "abi_version": STORE_ABI,
        "storage_epoch": storage_epoch,
        "lease_generation": lease_generation,
        "snapshot_sha256": snapshot["snapshot_sha256"],
        "lease_sha256": ZERO_DIGEST,
    }
    result["lease_sha256"] = lease_binding_sha256(result)
    return validate_lease_binding(result)


def lease_binding_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        LEASE_BINDING_DOMAIN,
        _u64(value["abi_version"]),
        _u64(value["storage_epoch"]),
        _u64(value["lease_generation"]),
        _digest(value["snapshot_sha256"], "lease snapshot"),
    )


def validate_lease_binding(value: Any) -> Record:
    result = _strict_record(value, LEASE_FIELDS, "lease binding")
    if (
        result["abi_version"] != STORE_ABI
        or type(result["storage_epoch"]) is not int
        or type(result["lease_generation"]) is not int
        or not 0 < result["storage_epoch"] <= U64_MAX
        or not 0 < result["lease_generation"] <= U64_MAX
    ):
        raise ActionOutboxStoreError("invalid lease binding")
    _digest(result["snapshot_sha256"], "lease snapshot")
    _digest(result["lease_sha256"], "lease root")
    if not hmac.compare_digest(result["lease_sha256"], lease_binding_sha256(result)):
        raise ActionOutboxStoreError("lease root mismatch")
    return deepcopy(result)


def make_repair_plan(snapshot_value: Any, lease_value: Any) -> Record:
    snapshot = validate_content_snapshot(snapshot_value)
    lease = validate_lease_binding(lease_value)
    if (
        snapshot["recovery_status"] not in REPAIRABLE_STATUSES
        or snapshot["discarded_tail_bytes"] == 0
        or not hmac.compare_digest(
            snapshot["snapshot_sha256"],
            lease["snapshot_sha256"],
        )
    ):
        raise ActionOutboxStoreError("snapshot cannot receive repair authority")
    result: Record = {
        "abi_version": STORE_ABI,
        "lease_sha256": lease["lease_sha256"],
        "recovery_status": snapshot["recovery_status"],
        "observed_bytes": snapshot["observed_bytes"],
        "committed_bytes": snapshot["committed_bytes"],
        "discarded_tail_bytes": snapshot["discarded_tail_bytes"],
        "final_chain_sha256": snapshot["final_chain_sha256"],
        "state_sha256": snapshot["state_sha256"],
        "ledger_sha256": snapshot["ledger_sha256"],
        "plan_sha256": ZERO_DIGEST,
    }
    result["plan_sha256"] = repair_plan_sha256(result)
    return validate_repair_plan(result)


def repair_plan_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        REPAIR_PLAN_DOMAIN,
        _u64(value["abi_version"]),
        _digest(value["lease_sha256"], "repair lease"),
        _u8(value["recovery_status"]),
        _u64(value["observed_bytes"]),
        _u64(value["committed_bytes"]),
        _u64(value["discarded_tail_bytes"]),
        _digest(value["final_chain_sha256"], "repair final chain"),
        _digest(value["state_sha256"], "repair state"),
        _digest(value["ledger_sha256"], "repair ledger"),
    )


def validate_repair_plan(value: Any) -> Record:
    result = _strict_record(value, REPAIR_PLAN_FIELDS, "repair plan")
    if (
        result["abi_version"] != STORE_ABI
        or type(result["recovery_status"]) is not int
        or result["recovery_status"] not in REPAIRABLE_STATUSES
        or type(result["observed_bytes"]) is not int
        or type(result["committed_bytes"]) is not int
        or type(result["discarded_tail_bytes"]) is not int
        or not protocol.HEADER_BYTES
        <= result["committed_bytes"]
        < result["observed_bytes"]
        <= U64_MAX
        or result["discarded_tail_bytes"]
        != result["observed_bytes"] - result["committed_bytes"]
        or not _valid_tail_shape(
            result["recovery_status"],
            result["discarded_tail_bytes"],
        )
    ):
        raise ActionOutboxStoreError("invalid repair plan")
    for name in (
        "lease_sha256",
        "final_chain_sha256",
        "state_sha256",
        "ledger_sha256",
        "plan_sha256",
    ):
        _digest(result[name], f"repair {name}")
    if not hmac.compare_digest(result["plan_sha256"], repair_plan_sha256(result)):
        raise ActionOutboxStoreError("repair plan root mismatch")
    return deepcopy(result)


@dataclass(frozen=True)
class Fault:
    """One deterministic before/after storage-call failure."""

    call_index: int
    timing: str
    write_prefix: int | None = None


class DeterministicStorage:
    """Fixed-capacity bytes with one generation and one sync watermark."""

    def __init__(
        self,
        initial: bytes,
        expected_header_sha256: Digest,
        maximum_bytes: int,
        storage_epoch: int,
    ) -> None:
        if type(initial) is not bytes or not 0 < storage_epoch <= U64_MAX:
            raise ActionOutboxStoreError("invalid deterministic storage")
        self.expected_header_sha256 = _digest(
            expected_header_sha256,
            "storage header",
        )
        self.maximum_bytes = maximum_bytes
        self.storage_epoch = storage_epoch
        content_snapshot(initial, self.expected_header_sha256, maximum_bytes)
        self.backing = bytearray(maximum_bytes)
        self.backing[: len(initial)] = initial
        self.length = len(initial)
        self.synced_length = len(initial)
        self.next_generation = 1
        self.active_generation = 0
        self.expected_phase = BODY_WRITE
        self.fault: Fault | None = None
        self.call_index = 0
        self.trace: list[str] = []
        self.append_generation = 0
        self.append_snapshot_sha256 = ZERO_DIGEST
        self.repair_generation = 0
        self.repair_snapshot_sha256 = ZERO_DIGEST
        self.repair_target_bytes = 0

    @property
    def bytes(self) -> bytes:
        return bytes(self.backing[: self.length])

    def acquire(self) -> Lease:
        if self.active_generation != 0:
            raise ActionOutboxStoreError("exclusive storage lease is busy")
        if self.next_generation > U64_MAX:
            raise ActionOutboxStoreError("lease generation exhausted")
        generation = self.next_generation
        self.next_generation += 1
        self.active_generation = generation
        self.expected_phase = BODY_WRITE
        self.fault = None
        self.call_index = 0
        self.trace.clear()
        self._clear_authority()
        snapshot = content_snapshot(
            self.bytes,
            self.expected_header_sha256,
            self.maximum_bytes,
        )
        return Lease(self, generation, snapshot)

    def set_fault(self, fault: Fault | None) -> None:
        if fault is not None:
            if (
                type(fault.call_index) is not int
                or fault.call_index < 0
                or fault.timing not in FAULT_TIMINGS
                or (
                    fault.write_prefix is not None
                    and (type(fault.write_prefix) is not int or fault.write_prefix < 0)
                )
            ):
                raise ActionOutboxStoreError("invalid deterministic fault")
        self.fault = fault
        self.call_index = 0
        self.trace.clear()

    def crash_bounds(self) -> tuple[int, int]:
        return (
            min(self.length, self.synced_length),
            max(self.length, self.synced_length),
        )

    def crash_persist(self, persisted_bytes: int) -> None:
        lower, upper = self.crash_bounds()
        if type(persisted_bytes) is not int or not lower <= persisted_bytes <= upper:
            raise ActionOutboxStoreError("invalid crash persistence point")
        self.length = persisted_bytes
        self.synced_length = persisted_bytes
        self.active_generation = 0
        self.expected_phase = BODY_WRITE
        self.fault = None
        self.call_index = 0
        self.trace.clear()
        self._clear_authority()

    def _clear_authority(self) -> None:
        self.append_generation = 0
        self.append_snapshot_sha256 = ZERO_DIGEST
        self.repair_generation = 0
        self.repair_snapshot_sha256 = ZERO_DIGEST
        self.repair_target_bytes = 0

    def _validate_generation(self, generation: int) -> None:
        if generation == 0 or generation != self.active_generation:
            raise ActionOutboxStoreError("stale or inactive storage authority")

    def _actual_snapshot(self) -> Record:
        return content_snapshot(
            self.bytes,
            self.expected_header_sha256,
            self.maximum_bytes,
        )

    def _validate_snapshot(self, expected_snapshot_sha256: Digest) -> None:
        actual = self._actual_snapshot()
        if not hmac.compare_digest(
            actual["snapshot_sha256"],
            expected_snapshot_sha256,
        ):
            raise ActionOutboxStoreError("storage snapshot changed")

    def _begin(self, generation: int, phase: str, *, write: bool) -> Fault | None:
        self._validate_generation(generation)
        if self.expected_phase != phase:
            raise ActionOutboxStoreError("invalid storage phase")
        self.trace.append(phase)
        call_index = self.call_index
        self.call_index += 1
        fault = self.fault
        if fault is None or fault.call_index != call_index:
            return None
        if not write and fault.write_prefix is not None:
            raise ActionOutboxStoreError("write prefix on non-write call")
        if fault.timing == TIMING_BEFORE:
            if fault.write_prefix is not None:
                raise ActionOutboxStoreError("write prefix on before-call fault")
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
            if fault.write_prefix > len(payload):
                raise ActionOutboxStoreError("partial write exceeds payload")
            write_length = fault.write_prefix
        if self.length + write_length > self.maximum_bytes:
            raise ActionOutboxStoreError("storage capacity exceeded")
        self.backing[self.length : self.length + write_length] = payload[:write_length]
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

    def _truncate(self, generation: int, target_bytes: int) -> None:
        fault = self._begin(generation, REPAIR_TRUNCATE, write=False)
        if (
            self.repair_generation != generation
            or self.repair_target_bytes != target_bytes
            or not protocol.HEADER_BYTES <= target_bytes < self.length
        ):
            raise ActionOutboxStoreError("repair target changed")
        self.length = target_bytes
        self.expected_phase = REPAIR_SYNC
        if fault is not None:
            raise InjectedFault(REPAIR_TRUNCATE)


class Lease:
    """One exclusive generation bound to exact observed content."""

    def __init__(
        self,
        storage: DeterministicStorage,
        generation: int,
        snapshot: Record,
    ) -> None:
        self.storage = storage
        self.generation = generation
        self.snapshot = validate_content_snapshot(snapshot)
        self.binding = make_lease_binding(
            self.snapshot,
            storage.storage_epoch,
            generation,
        )
        self.state = "ready"

    def append_capability(self) -> AppendCapability:
        self.storage._validate_generation(self.generation)
        if (
            self.state != "ready"
            or self.snapshot["recovery_status"] != protocol.RECOVERY_CLEAN
            or self.storage.expected_phase != BODY_WRITE
        ):
            raise ActionOutboxStoreError("lease cannot mint append authority")
        self.storage._validate_snapshot(self.snapshot["snapshot_sha256"])
        self.storage.append_generation = self.generation
        self.storage.append_snapshot_sha256 = self.snapshot["snapshot_sha256"]
        return AppendCapability(self)

    def prepare_repair(self) -> RepairCapability:
        self.storage._validate_generation(self.generation)
        if self.state != "ready" or self.storage.expected_phase != BODY_WRITE:
            raise ActionOutboxStoreError("lease cannot enter repair")
        self.storage._validate_snapshot(self.snapshot["snapshot_sha256"])
        plan = make_repair_plan(self.snapshot, self.binding)
        self.state = "repair_ready"
        self.storage.append_generation = 0
        self.storage.append_snapshot_sha256 = ZERO_DIGEST
        self.storage.repair_generation = self.generation
        self.storage.repair_snapshot_sha256 = self.snapshot["snapshot_sha256"]
        self.storage.repair_target_bytes = plan["committed_bytes"]
        self.storage.expected_phase = REPAIR_TRUNCATE
        return RepairCapability(self, plan)

    def _advance_snapshot(self, snapshot: Record) -> None:
        self.storage._validate_generation(self.generation)
        self.snapshot = validate_content_snapshot(snapshot)
        self.binding = make_lease_binding(
            self.snapshot,
            self.storage.storage_epoch,
            self.generation,
        )
        self.storage.append_snapshot_sha256 = self.snapshot["snapshot_sha256"]

    def release(self) -> None:
        self.storage._validate_generation(self.generation)
        self.storage.active_generation = 0
        self.storage.expected_phase = BODY_WRITE
        self.storage.fault = None
        self.storage._clear_authority()
        self.state = "closed"
        self.generation = 0


class AppendCapability:
    """Body/footer-only authority for one clean lease snapshot."""

    def __init__(self, lease: Lease) -> None:
        self.lease = lease
        self.generation = lease.generation
        self.snapshot_sha256 = lease.snapshot["snapshot_sha256"]

    def validate(self) -> None:
        storage = self.lease.storage
        self._validate_authority()
        if self.lease.state != "ready":
            raise ActionOutboxStoreError("append authority is stale")
        storage._validate_snapshot(self.snapshot_sha256)

    def _validate_authority(self) -> None:
        storage = self.lease.storage
        storage._validate_generation(self.generation)
        if storage.append_generation != self.generation or not hmac.compare_digest(
            storage.append_snapshot_sha256,
            self.snapshot_sha256,
        ):
            raise ActionOutboxStoreError("append authority is stale")

    def append_body(self, payload: bytes) -> None:
        self.validate()
        if len(payload) != protocol.RECORD_BODY_BYTES:
            raise ActionOutboxStoreError("invalid record body")
        self.lease.storage._append(
            self.generation,
            BODY_WRITE,
            BODY_SYNC,
            payload,
        )

    def sync_body(self) -> None:
        self._validate_authority()
        self.lease.storage._sync(
            self.generation,
            BODY_SYNC,
            FOOTER_WRITE,
        )

    def append_footer(self, payload: bytes) -> None:
        self._validate_authority()
        if len(payload) != protocol.COMMIT_FOOTER_BYTES:
            raise ActionOutboxStoreError("invalid commit footer")
        self.lease.storage._append(
            self.generation,
            FOOTER_WRITE,
            FOOTER_SYNC,
            payload,
        )

    def sync_footer(self) -> None:
        self._validate_authority()
        self.lease.storage._sync(
            self.generation,
            FOOTER_SYNC,
            BODY_WRITE,
        )

    def advance(self, snapshot: Record) -> None:
        self.lease._advance_snapshot(snapshot)
        self.snapshot_sha256 = self.lease.snapshot["snapshot_sha256"]


class RepairCapability:
    """Truncate/sync-only authority for one incomplete tail."""

    def __init__(self, lease: Lease, plan: Record) -> None:
        self.lease = lease
        self.generation = lease.generation
        self.plan = validate_repair_plan(plan)

    def validate(self) -> None:
        storage = self.lease.storage
        storage._validate_generation(self.generation)
        if (
            self.lease.state not in {"repair_ready", "repair_active"}
            or storage.repair_generation != self.generation
            or not hmac.compare_digest(
                storage.repair_snapshot_sha256,
                self.lease.snapshot["snapshot_sha256"],
            )
            or not hmac.compare_digest(
                self.plan["lease_sha256"],
                self.lease.binding["lease_sha256"],
            )
        ):
            raise ActionOutboxStoreError("repair authority is stale")

    def truncate(self) -> None:
        self.validate()
        self.lease.storage._validate_snapshot(
            self.lease.snapshot["snapshot_sha256"],
        )
        self.lease.storage._truncate(
            self.generation,
            self.plan["committed_bytes"],
        )
        self.lease.state = "repair_active"

    def sync(self) -> None:
        self.validate()
        self.lease.storage._sync(
            self.generation,
            REPAIR_SYNC,
            BODY_WRITE,
        )
        self.lease.state = "repair_complete"


class Writer:
    """Protocol-preflighted append writer that poisons on uncertain I/O."""

    def __init__(
        self,
        capability: AppendCapability,
        header: Mapping[str, Any],
    ) -> None:
        self.capability = capability
        self.header = header
        self.state = "ready"

    def append_record(self, encoded_record: bytes) -> Record:
        if self.state != "ready":
            raise ActionOutboxStoreError("writer must be reopened")
        self.capability.validate()
        snapshot = self.capability.lease.snapshot
        sequence = snapshot["committed_records"] + 1
        body, footer = protocol.append_plan(
            self.header,
            sequence,
            snapshot["final_chain_sha256"],
            encoded_record,
        )
        storage = self.capability.lease.storage
        prospective_bytes = storage.bytes + encoded_record
        prospective = content_snapshot(
            prospective_bytes,
            storage.expected_header_sha256,
            storage.maximum_bytes,
        )
        if (
            prospective["recovery_status"] != protocol.RECOVERY_CLEAN
            or prospective["committed_records"] != sequence
        ):
            raise ActionOutboxStoreError("append preflight changed")

        self.state = "poisoned"
        self.capability.append_body(body)
        self.capability.sync_body()
        self.capability.append_footer(footer)
        self.capability.sync_footer()
        actual = content_snapshot(
            storage.bytes,
            storage.expected_header_sha256,
            storage.maximum_bytes,
        )
        if actual != prospective:
            raise ActionOutboxStoreError("committed append differs from preflight")
        self.capability.advance(actual)
        self.state = "ready"
        return {
            "sequence": sequence,
            "committed_bytes": actual["committed_bytes"],
            "final_chain_sha256": actual["final_chain_sha256"],
            "state_sha256": actual["state_sha256"],
            "ledger_sha256": actual["ledger_sha256"],
            "body_sync_exercised": True,
            "footer_sync_exercised": True,
        }


class Repairer:
    """Explicit incomplete-tail repair that requires fresh reopen afterward."""

    def __init__(self, capability: RepairCapability) -> None:
        self.capability = capability
        self.state = "ready"

    def apply(self) -> Record:
        if self.state != "ready":
            raise ActionOutboxStoreError("repairer must be reopened")
        self.capability.validate()
        plan = self.capability.plan
        self.state = "poisoned"
        self.capability.truncate()
        self.capability.sync()
        storage = self.capability.lease.storage
        repaired = content_snapshot(
            storage.bytes,
            storage.expected_header_sha256,
            storage.maximum_bytes,
        )
        if (
            repaired["recovery_status"] != protocol.RECOVERY_CLEAN
            or repaired["observed_bytes"] != plan["committed_bytes"]
            or not hmac.compare_digest(
                repaired["final_chain_sha256"],
                plan["final_chain_sha256"],
            )
            or not hmac.compare_digest(
                repaired["state_sha256"],
                plan["state_sha256"],
            )
            or not hmac.compare_digest(
                repaired["ledger_sha256"],
                plan["ledger_sha256"],
            )
        ):
            raise ActionOutboxStoreError("repair result changed committed prefix")
        self.state = "complete"
        return {
            "original_bytes": plan["observed_bytes"],
            "committed_bytes": plan["committed_bytes"],
            "discarded_tail_bytes": plan["discarded_tail_bytes"],
            "final_chain_sha256": plan["final_chain_sha256"],
            "state_sha256": plan["state_sha256"],
            "ledger_sha256": plan["ledger_sha256"],
            "truncate_exercised": True,
            "sync_exercised": True,
        }


@dataclass(frozen=True)
class ReferenceInputs:
    """Immutable byte inputs derived from the portable semantic campaign."""

    header: Mapping[str, Any]
    header_sha256: Digest
    storage_epoch: int
    maximum_bytes: int
    encoded: bytes
    record_bytes: tuple[bytes, ...]
    protocol_report: Mapping[str, Any]


@lru_cache(maxsize=1)
def reference_inputs() -> ReferenceInputs:
    campaign = protocol.reference_campaign()
    report = protocol.build_report()
    header = campaign["header"]
    encoded = campaign["encoded"]
    records = tuple(
        encoded[
            protocol.HEADER_BYTES
            + index * protocol.RECORD_BYTES : protocol.HEADER_BYTES
            + (index + 1) * protocol.RECORD_BYTES
        ]
        for index in range(len(campaign["records"]))
    )
    if (
        b"".join((encoded[: protocol.HEADER_BYTES], *records)) != encoded
        or len(records) != report["record_count"]
    ):
        raise ActionOutboxStoreError("portable campaign framing changed")
    return ReferenceInputs(
        header=header,
        header_sha256=header["header_sha256"],
        storage_epoch=header["outbox_epoch"],
        maximum_bytes=maximum_file_bytes(header),
        encoded=encoded,
        record_bytes=records,
        protocol_report=report,
    )


def _prefix(inputs: ReferenceInputs, committed_records: int) -> bytes:
    if not 0 <= committed_records <= len(inputs.record_bytes):
        raise ActionOutboxStoreError("prefix record count out of range")
    end = protocol.HEADER_BYTES + committed_records * protocol.RECORD_BYTES
    return inputs.encoded[:end]


def _matrix_sha256(domain: bytes, leaves: Sequence[Digest]) -> Digest:
    return _sha(domain, _u64(len(leaves)), *leaves)


def append_phase_matrix_sha256(inputs: ReferenceInputs) -> tuple[int, Digest]:
    leaves: list[Digest] = []
    for sequence, encoded_record in enumerate(inputs.record_bytes, start=1):
        initial = _prefix(inputs, sequence - 1)
        for call_index, phase in enumerate(APPEND_PHASES):
            storage = DeterministicStorage(
                initial,
                inputs.header_sha256,
                inputs.maximum_bytes,
                inputs.storage_epoch,
            )
            lease = storage.acquire()
            writer = Writer(lease.append_capability(), inputs.header)
            storage.set_fault(Fault(call_index, TIMING_AFTER))
            try:
                writer.append_record(encoded_record)
            except InjectedFault:
                pass
            else:
                raise ActionOutboxStoreError("append phase did not fault")
            if writer.state != "poisoned":
                raise ActionOutboxStoreError("uncertain append did not poison writer")
            persisted = storage.crash_bounds()[1]
            storage.crash_persist(persisted)
            reopened = storage.acquire()
            snapshot = reopened.snapshot
            leaves.append(
                _sha(
                    APPEND_PHASE_CASE_DOMAIN,
                    _u64(sequence),
                    _u8(APPEND_PHASE_VALUES[phase]),
                    _u64(persisted),
                    _u8(snapshot["recovery_status"]),
                    _u64(snapshot["committed_bytes"]),
                    _u64(snapshot["discarded_tail_bytes"]),
                    _u64(snapshot["committed_records"]),
                    snapshot["final_chain_sha256"],
                    snapshot["state_sha256"],
                    snapshot["ledger_sha256"],
                    snapshot["snapshot_sha256"],
                )
            )
            reopened.release()
    return len(leaves), _matrix_sha256(APPEND_PHASE_MATRIX_DOMAIN, leaves)


def partial_write_matrix_sha256(inputs: ReferenceInputs) -> tuple[int, Digest]:
    leaves: list[Digest] = []
    target_sequence = 4
    initial = _prefix(inputs, target_sequence - 1)
    encoded_record = inputs.record_bytes[target_sequence - 1]

    for prefix in range(protocol.RECORD_BODY_BYTES + 1):
        persisted_bytes = initial + encoded_record[:prefix]
        snapshot = content_snapshot(
            persisted_bytes,
            inputs.header_sha256,
            inputs.maximum_bytes,
        )
        leaves.append(
            _sha(
                PARTIAL_WRITE_CASE_DOMAIN,
                _u8(1),
                _u64(prefix),
                _u64(len(persisted_bytes)),
                _u8(snapshot["recovery_status"]),
                _u64(snapshot["committed_bytes"]),
                _u64(snapshot["discarded_tail_bytes"]),
                _u64(snapshot["committed_records"]),
                snapshot["final_chain_sha256"],
                snapshot["state_sha256"],
                snapshot["ledger_sha256"],
                snapshot["snapshot_sha256"],
            )
        )

    for prefix in range(protocol.COMMIT_FOOTER_BYTES + 1):
        persisted_bytes = (
            initial
            + encoded_record[: protocol.RECORD_BODY_BYTES]
            + encoded_record[
                protocol.RECORD_BODY_BYTES : protocol.RECORD_BODY_BYTES + prefix
            ]
        )
        snapshot = content_snapshot(
            persisted_bytes,
            inputs.header_sha256,
            inputs.maximum_bytes,
        )
        leaves.append(
            _sha(
                PARTIAL_WRITE_CASE_DOMAIN,
                _u8(2),
                _u64(prefix),
                _u64(len(persisted_bytes)),
                _u8(snapshot["recovery_status"]),
                _u64(snapshot["committed_bytes"]),
                _u64(snapshot["discarded_tail_bytes"]),
                _u64(snapshot["committed_records"]),
                snapshot["final_chain_sha256"],
                snapshot["state_sha256"],
                snapshot["ledger_sha256"],
                snapshot["snapshot_sha256"],
            )
        )
    return len(leaves), _matrix_sha256(PARTIAL_WRITE_MATRIX_DOMAIN, leaves)


def repair_tail_matrix_sha256(inputs: ReferenceInputs) -> tuple[int, Digest]:
    leaves: list[Digest] = []
    target_sequence = 4
    initial = _prefix(inputs, target_sequence - 1)
    encoded_record = inputs.record_bytes[target_sequence - 1]
    expected_after = _prefix(inputs, target_sequence)
    expected_after_snapshot = content_snapshot(
        expected_after,
        inputs.header_sha256,
        inputs.maximum_bytes,
    )
    repaired_snapshot = content_snapshot(
        initial,
        inputs.header_sha256,
        inputs.maximum_bytes,
    )

    for tail_bytes in range(1, protocol.RECORD_BYTES):
        pre_snapshot = content_snapshot(
            initial + encoded_record[:tail_bytes],
            inputs.header_sha256,
            inputs.maximum_bytes,
        )
        lease = make_lease_binding(
            pre_snapshot,
            inputs.storage_epoch,
            1,
        )
        plan = make_repair_plan(pre_snapshot, lease)
        leaves.append(
            _sha(
                REPAIR_TAIL_CASE_DOMAIN,
                _u64(tail_bytes),
                pre_snapshot["snapshot_sha256"],
                plan["plan_sha256"],
                repaired_snapshot["snapshot_sha256"],
                expected_after_snapshot["snapshot_sha256"],
            )
        )
    return len(leaves), _matrix_sha256(REPAIR_TAIL_MATRIX_DOMAIN, leaves)


def repair_fault_matrix_sha256(inputs: ReferenceInputs) -> tuple[int, Digest]:
    leaves: list[Digest] = []
    target_sequence = 4
    initial = _prefix(inputs, target_sequence - 1)
    encoded_record = inputs.record_bytes[target_sequence - 1]
    torn = initial + encoded_record[: protocol.RECORD_BODY_BYTES + 7]

    for call_index, phase in enumerate(REPAIR_PHASES):
        for timing in FAULT_TIMINGS:
            for persistence in PERSIST_CHOICES:
                storage = DeterministicStorage(
                    torn,
                    inputs.header_sha256,
                    inputs.maximum_bytes,
                    inputs.storage_epoch,
                )
                lease = storage.acquire()
                pre_snapshot = lease.snapshot
                capability = lease.prepare_repair()
                plan = capability.plan
                repairer = Repairer(capability)
                storage.set_fault(Fault(call_index, timing))
                try:
                    repairer.apply()
                except InjectedFault:
                    pass
                else:
                    raise ActionOutboxStoreError("repair phase did not fault")
                if repairer.state != "poisoned":
                    raise ActionOutboxStoreError("uncertain repair did not poison")
                lower, upper = storage.crash_bounds()
                persisted = lower if persistence == PERSIST_LOWER else upper
                storage.crash_persist(persisted)
                reopened = storage.acquire()
                snapshot = reopened.snapshot
                action = (
                    OPEN_CLEAN
                    if snapshot["recovery_status"] == protocol.RECOVERY_CLEAN
                    else REPAIR_REQUIRED
                )
                leaves.append(
                    _sha(
                        REPAIR_FAULT_CASE_DOMAIN,
                        _u8(REPAIR_PHASE_VALUES[phase]),
                        _u8(FAULT_TIMING_VALUES[timing]),
                        _u8(PERSIST_CHOICE_VALUES[persistence]),
                        _u64(persisted),
                        _u8(action),
                        pre_snapshot["snapshot_sha256"],
                        plan["plan_sha256"],
                        snapshot["snapshot_sha256"],
                    )
                )
                reopened.release()
    return len(leaves), _matrix_sha256(REPAIR_FAULT_MATRIX_DOMAIN, leaves)


def semantic_report_sha256(value: Mapping[str, Any]) -> Digest:
    if tuple(value) != REPORT_FIELDS or value["schema"] != REPORT_SCHEMA:
        raise ActionOutboxStoreError("report has noncanonical fields")
    if _hex_u64(value["report_abi"], "report ABI") != REPORT_ABI:
        raise ActionOutboxStoreError("report ABI changed")
    if _hex_u64(value["store_abi"], "store ABI") != STORE_ABI:
        raise ActionOutboxStoreError("store ABI changed")
    protocol_abi = _hex_u64(value["protocol_report_abi"], "protocol report ABI")
    if protocol_abi != protocol.REPORT_ABI:
        raise ActionOutboxStoreError("protocol report ABI changed")

    numeric_names = (
        "header_bytes",
        "record_body_bytes",
        "commit_footer_bytes",
        "record_bytes",
        "maximum_file_bytes",
        "journal_bytes",
        "record_count",
        "action_count",
        "append_phase_case_count",
        "partial_write_case_count",
        "repair_tail_case_count",
        "repair_fault_case_count",
    )
    root_names = (
        "header_sha256",
        "protocol_report_sha256",
        "journal_sha256",
        "initial_snapshot_sha256",
        "uncertain_snapshot_sha256",
        "final_snapshot_sha256",
        "append_phase_matrix_sha256",
        "partial_write_matrix_sha256",
        "repair_tail_matrix_sha256",
        "repair_fault_matrix_sha256",
        "final_chain_sha256",
        "final_state_sha256",
        "ledger_sha256",
    )
    parts: list[bytes] = [
        _u64(REPORT_ABI),
        _u64(STORE_ABI),
        _u64(protocol_abi),
        *(_u64(value[name]) for name in numeric_names),
        *(_hex_digest(value[name], f"report {name}") for name in root_names),
    ]
    append_phases = value["append_phases"]
    repair_phases = value["repair_phases"]
    if append_phases != list(APPEND_PHASES) or repair_phases != list(REPAIR_PHASES):
        raise ActionOutboxStoreError("report phase order changed")
    parts.extend(_u8(APPEND_PHASE_VALUES[name]) for name in append_phases)
    parts.extend(_u8(REPAIR_PHASE_VALUES[name]) for name in repair_phases)
    ledger = _strict_record(value["ledger"], protocol.LEDGER_FIELDS, "report ledger")
    parts.extend(_u64(ledger[name]) for name in protocol.LEDGER_FIELDS)
    return _sha(REPORT_DOMAIN, *parts)


@lru_cache(maxsize=1)
def _build_report_cached() -> Record:
    inputs = reference_inputs()
    final_recovery = protocol.recover(inputs.encoded, inputs.header_sha256)
    initial_snapshot = content_snapshot(
        _prefix(inputs, 0),
        inputs.header_sha256,
        inputs.maximum_bytes,
    )
    uncertain_snapshot = content_snapshot(
        _prefix(inputs, 3),
        inputs.header_sha256,
        inputs.maximum_bytes,
    )
    final_snapshot = content_snapshot(
        inputs.encoded,
        inputs.header_sha256,
        inputs.maximum_bytes,
    )
    append_count, append_root = append_phase_matrix_sha256(inputs)
    partial_count, partial_root = partial_write_matrix_sha256(inputs)
    repair_tail_count, repair_tail_root = repair_tail_matrix_sha256(inputs)
    repair_fault_count, repair_fault_root = repair_fault_matrix_sha256(inputs)
    source = inputs.protocol_report
    report: Record = {
        "schema": REPORT_SCHEMA,
        "report_abi": f"{REPORT_ABI:016x}",
        "store_abi": f"{STORE_ABI:016x}",
        "protocol_report_abi": source["report_abi"],
        "header_bytes": protocol.HEADER_BYTES,
        "record_body_bytes": protocol.RECORD_BODY_BYTES,
        "commit_footer_bytes": protocol.COMMIT_FOOTER_BYTES,
        "record_bytes": protocol.RECORD_BYTES,
        "maximum_file_bytes": inputs.maximum_bytes,
        "journal_bytes": len(inputs.encoded),
        "record_count": len(inputs.record_bytes),
        "action_count": len(final_recovery["states"]),
        "append_phase_case_count": append_count,
        "partial_write_case_count": partial_count,
        "repair_tail_case_count": repair_tail_count,
        "repair_fault_case_count": repair_fault_count,
        "header_sha256": inputs.header_sha256.hex(),
        "protocol_report_sha256": source["report_sha256"],
        "journal_sha256": hashlib.sha256(inputs.encoded).hexdigest(),
        "initial_snapshot_sha256": initial_snapshot["snapshot_sha256"].hex(),
        "uncertain_snapshot_sha256": uncertain_snapshot["snapshot_sha256"].hex(),
        "final_snapshot_sha256": final_snapshot["snapshot_sha256"].hex(),
        "append_phase_matrix_sha256": append_root.hex(),
        "partial_write_matrix_sha256": partial_root.hex(),
        "repair_tail_matrix_sha256": repair_tail_root.hex(),
        "repair_fault_matrix_sha256": repair_fault_root.hex(),
        "final_chain_sha256": final_recovery["final_chain_sha256"].hex(),
        "final_state_sha256": final_recovery["state_sha256"].hex(),
        "ledger_sha256": protocol.ledger_sha256(final_recovery["ledger"]).hex(),
        "report_sha256": "",
        "append_phases": list(APPEND_PHASES),
        "repair_phases": list(REPAIR_PHASES),
        "ledger": {
            name: final_recovery["ledger"][name] for name in protocol.LEDGER_FIELDS
        },
    }
    report["report_sha256"] = semantic_report_sha256(report).hex()
    if tuple(report) != REPORT_FIELDS:
        raise ActionOutboxStoreError("report field order changed")
    return report


def build_report() -> Record:
    return deepcopy(_build_report_cached())


def render_report(value: Mapping[str, Any] | None = None) -> str:
    report = build_report() if value is None else value
    try:
        return (
            json.dumps(
                report,
                ensure_ascii=True,
                allow_nan=False,
                separators=(",", ":"),
            )
            + "\n"
        )
    except (TypeError, ValueError) as error:
        raise ActionOutboxStoreError("report is not canonical JSON data") from error


def validate_report(value: Any) -> Record:
    expected = build_report()
    if (
        not isinstance(value, dict)
        or tuple(value) != REPORT_FIELDS
        or value != expected
        or render_report(value) != render_report(expected)
        or value["report_sha256"] != semantic_report_sha256(value).hex()
    ):
        raise ActionOutboxStoreError(
            "report contradicts independent deterministic storage replay"
        )
    return deepcopy(expected)


def load_json_exact(encoded: bytes, where: str) -> Record:
    if (
        type(encoded) is not bytes
        or not 0 < len(encoded) <= MAXIMUM_JSON_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise ActionOutboxStoreError(f"{where} is not one canonical JSON line")

    def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
        result: Record = {}
        for key, value in pairs:
            if key in result:
                raise ActionOutboxStoreError(f"{where} contains duplicate fields")
            result[key] = value
        return result

    def reject_number(_: str) -> None:
        raise ActionOutboxStoreError(f"{where} contains a non-integer number")

    try:
        decoded = json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=object_pairs,
            parse_constant=reject_number,
            parse_float=reject_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActionOutboxStoreError(f"{where} is invalid JSON") from error
    if (
        not isinstance(decoded, dict)
        or render_report(decoded).encode("ascii") != encoded
    ):
        raise ActionOutboxStoreError(f"{where} is not canonical JSON")
    return decoded


def verify_runner(runner: Path, fixture: Path) -> None:
    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise ActionOutboxStoreError("retained fixture is stale")
    completed = subprocess.run(
        (str(runner),),
        check=False,
        capture_output=True,
        timeout=60,
    )
    if completed.returncode != 0 or completed.stderr:
        raise ActionOutboxStoreError("ActionOutbox storage runner failed")
    runner_value = load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise ActionOutboxStoreError(
            "runner contradicts independent deterministic storage replay"
        )


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path)
    parser.add_argument("--fixture", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_args(argv)
    if (arguments.runner is None) != (arguments.fixture is None):
        raise ActionOutboxStoreError("--runner and --fixture must be supplied together")
    if arguments.runner is not None:
        verify_runner(arguments.runner, arguments.fixture)
    else:
        print(render_report(), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
