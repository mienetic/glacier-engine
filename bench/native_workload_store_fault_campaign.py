#!/usr/bin/env python3
"""Deterministic W7b-b2 durable-publication fault campaign.

This module exercises the generic ``native_workload_campaign`` manifest and
selector with a two-generation synthetic fixture.  It performs real POSIX file
operations and real subprocess ``SIGKILL`` boundaries, but it opens no device
and makes no native CPU, GPU, model-execution, physical-storage-pressure, or
power-loss claim.

The fixed publication transition is generation one to generation two:

* one final environment object;
* one report-wire object;
* one immutable manifest; and
* one active selector.

The three immutable objects expose seven ordered phases each: candidate create,
prefix write, full write, file sync, target link, candidate unlink, and object
directory sync.  The selector exposes six phases: candidate create, prefix
write, full write, file sync, atomic replacement, and root-directory sync.

For every phase the parent can run a writer child that either dies with a real
``SIGKILL`` after the OS operation succeeds or receives a deterministic
``EIO``/``ENOSPC`` before the operation.  A separately opened exclusive lease
classifies only exact known residue, rolls the explicit prepared transaction
forward, and rejects unknown, corrupt, symlinked, or foreign-hard-linked state.
Two fresh recovery processes and a fresh strict verifier process follow every
fault case.

The error adapter is deliberately synthetic.  Completed operations are real
host-filesystem calls, but injected errors are not evidence that the kernel,
filesystem, controller, or physical medium produced those errors.  Process
death plus ``fsync`` calls is not power-loss or reboot durability evidence.
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping, Optional, Sequence

from bench import native_workload_campaign as campaign


class StoreFaultCampaignError(ValueError):
    """The durable-publication campaign could not be proven."""


class InjectedStoreFault(OSError):
    """One deterministic pre-operation error from the campaign adapter."""

    def __init__(self, error_number: int, phase_id: int) -> None:
        super().__init__(
            error_number,
            "injected %s before phase %d"
            % (errno.errorcode.get(error_number, "errno"), phase_id),
        )
        self.phase_id = phase_id


ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
MIB = 1024 * 1024

SEGMENT_COUNT = 2
RESTART_AFTER_SEGMENT = 1
REPORT_WIRE_BYTES = 195_556
STORE_MAX_BYTES = 1 * MIB
STORE_MAX_FILES = 32

ROOT_MODE = 0o700
DIRECTORY_MODE = 0o700
FILE_MODE = 0o600

ACTIVE_SELECTOR_NAME = ".glacier-workload-campaign-active-v1"
LOCK_NAME = ".glacier-workload-campaign.lock"
STORE_TEMP_SUFFIX = ".prepared-v1.tmp"
SEGMENTS_NAME = "segments"
MANIFESTS_NAME = "manifests"
ENVIRONMENTS_NAME = "environments"

PREPARED_PUBLICATION_DOMAIN = (
    b"glacier-native-workload-store-prepared-publication-v1\x00"
)
STORE_SHAPE_DOMAIN = b"glacier-native-workload-store-shape-v1\x00"
CASE_RECORD_DOMAIN = b"glacier-native-workload-store-fault-campaign-case-record-v1\x00"
MATRIX_DOMAIN = b"glacier-native-workload-store-fault-matrix-v1\x00"
FIXTURE_DOMAIN = b"glacier-native-workload-store-fault-fixture-v1\x00"
REPORT_CHALLENGE_DOMAIN = b"glacier-native-workload-store-fault-report-challenge-v1\x00"
REPORT_SCHEDULE_DOMAIN = b"glacier-native-workload-store-fault-report-schedule-v1\x00"
REPORT_ROLE_DOMAIN = b"glacier-native-workload-store-fault-report-role-v1\x00"
SOURCE_SNAPSHOT_DOMAIN = b"glacier-native-workload-store-fault-source-snapshot-v1\x00"
REPORT_CASE_CHALLENGE_DOMAIN = (
    b"glacier-native-workload-store-fault-report-case-challenge-v1\x00"
)
REPORT_CONTROL_RECEIPT_DOMAIN = (
    b"glacier-native-workload-store-fault-control-receipt-v1\x00"
)
REPORT_RECOVERY_RESULT_DOMAIN = (
    b"glacier-native-workload-store-fault-recovery-result-v1\x00"
)
MACHINE_PROFILE_DOMAIN = b"glacier-native-workload-store-fault-machine-profile-v1\x00"
FILESYSTEM_PROFILE_DOMAIN = (
    b"glacier-native-workload-store-fault-filesystem-profile-v1\x00"
)

FAULT_NONE = "none"
FAULT_SIGKILL = "sigkill-after"
FAULT_EIO = "eio-before"
FAULT_ENOSPC = "enospc-before"
FAULT_MODES = (FAULT_SIGKILL, FAULT_EIO, FAULT_ENOSPC)

CHILD_INJECTED_ERRNO_EXIT = 74
CHILD_UNEXPECTED_SUCCESS_EXIT = 75
CHILD_PROTOCOL_EXIT = 76
CHILD_TIMEOUT_SECONDS = 20.0
MAX_CHILD_OUTPUT_BYTES = 64 * 1024
MAX_SOURCE_COMPONENT_BYTES = 8 * MIB
SOURCE_COMPONENT_KEYS = frozenset(
    {
        "campaign_module_sha256",
        "campaign_codec_sha256",
        "store_adapter_sha256",
        "lane4_evidence_sha256",
        "metal_disruption_report_sha256",
        "metal_workload_report_sha256",
        "native_observation_common_sha256",
        "native_observer_sha256",
        "native_observer_linux_sha256",
        "portable_workload_report_sha256",
        "report_codec_sha256",
    }
)
STORE_ADAPTER_GRAPH_KEYS = (
    "store_adapter_sha256",
    "campaign_codec_sha256",
    "lane4_evidence_sha256",
    "metal_disruption_report_sha256",
    "metal_workload_report_sha256",
    "native_observation_common_sha256",
    "native_observer_sha256",
    "native_observer_linux_sha256",
    "portable_workload_report_sha256",
)


@dataclass(frozen=True)
class PublicationPhase:
    phase_id: int
    name: str
    object_kind: str
    operation: str


def _object_phases(
    first_id: int,
    object_kind: str,
) -> tuple[PublicationPhase, ...]:
    names = (
        ("temp-create", "create"),
        ("prefix-write", "write-prefix"),
        ("full-write", "write-remainder"),
        ("file-fsync", "fsync-file"),
        ("target-link", "link"),
        ("temp-unlink", "unlink"),
        ("directory-fsync", "fsync-directory"),
    )
    return tuple(
        PublicationPhase(
            first_id + offset,
            "%s-%s" % (object_kind, suffix),
            object_kind,
            operation,
        )
        for offset, (suffix, operation) in enumerate(names)
    )


PHASES = (
    _object_phases(1, "environment")
    + _object_phases(8, "segment")
    + _object_phases(15, "manifest")
    + (
        PublicationPhase(22, "selector-temp-create", "selector", "create"),
        PublicationPhase(
            23,
            "selector-prefix-write",
            "selector",
            "write-prefix",
        ),
        PublicationPhase(
            24,
            "selector-full-write",
            "selector",
            "write-remainder",
        ),
        PublicationPhase(
            25,
            "selector-file-fsync",
            "selector",
            "fsync-file",
        ),
        PublicationPhase(
            26,
            "selector-replace",
            "selector",
            "replace",
        ),
        PublicationPhase(
            27,
            "store-root-directory-sync",
            "store_root",
            "directory_sync",
        ),
    )
)
PHASE_BY_ID = {phase.phase_id: phase for phase in PHASES}
STORE_HOOK_PHASES = {
    (object_kind, operation): PHASE_BY_ID[first_id + offset]
    for object_kind, first_id in (
        ("environment", 1),
        ("segment", 8),
        ("manifest", 15),
    )
    for offset, operation in enumerate(
        (
            "create",
            "write_prefix",
            "write_complete",
            "file_fsync",
            "target_link",
            "temp_unlink",
            "directory_fsync",
        )
    )
}
STORE_HOOK_PHASES.update(
    {
        ("selector", "create"): PHASE_BY_ID[22],
        ("selector", "write_prefix"): PHASE_BY_ID[23],
        ("selector", "write_complete"): PHASE_BY_ID[24],
        ("selector", "file_fsync"): PHASE_BY_ID[25],
        ("selector", "active_replace"): PHASE_BY_ID[26],
        ("store_root", "directory_fsync"): PHASE_BY_ID[27],
    }
)

if tuple(PHASE_BY_ID) != tuple(range(1, 28)):
    raise RuntimeError("store-fault phase table is not contiguous")


@dataclass(frozen=True)
class ObjectSpec:
    object_kind: str
    directory_name: str
    target_name: str
    data: bytes
    phases: tuple[PublicationPhase, ...]
    transaction_sha256: bytes

    @property
    def temporary_name(self) -> str:
        return ".%s%s" % (self.target_name, STORE_TEMP_SUFFIX)

    @property
    def prefix_bytes(self) -> int:
        return _prefix_bytes(len(self.data))


@dataclass(frozen=True)
class DeterministicFixture:
    plan: Mapping[str, Any]
    entries: tuple[Mapping[str, Any], Mapping[str, Any]]
    environment_before: bytes
    environment_after: bytes
    report_one: bytes
    report_two: bytes
    manifest_one: bytes
    manifest_two: bytes
    selector_one: bytes
    selector_two: bytes
    environment_before_sha256: bytes
    environment_after_sha256: bytes
    environment_root_one_sha256: bytes
    environment_root_two_sha256: bytes
    fixture_sha256: bytes


@dataclass(frozen=True)
class PreparedPublicationV1:
    fixture: DeterministicFixture
    previous_generation: int
    successor_generation: int
    previous_manifest_sha256: bytes
    successor_manifest_sha256: bytes
    previous_selector_sha256: bytes
    successor_selector_sha256: bytes
    plan_sha256: bytes
    transaction_sha256: bytes
    object_specs: tuple[ObjectSpec, ObjectSpec, ObjectSpec]
    selector_spec: ObjectSpec


@dataclass(frozen=True)
class Classification:
    selected_generation: int
    object_states: tuple[str, str, str]
    selector_temp_state: str
    known_residue_files: int
    known_residue_bytes: int
    shape_sha256: bytes


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise StoreFaultCampaignError(message)


def _digest(label: str) -> bytes:
    return hashlib.sha256(
        b"glacier-native-workload-store-fault-fixture-label-v1\x00"
        + label.encode("ascii")
    ).digest()


def _sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def _u64(value: int) -> bytes:
    _require(
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= U64_MAX,
        "value is outside u64",
    )
    return value.to_bytes(8, "little")


def _hash_parts(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _deterministic_bytes(label: str, size: int) -> bytes:
    _require(size > 1, "deterministic object is too small")
    result = bytearray()
    counter = 0
    while len(result) < size:
        result.extend(
            _hash_parts(
                FIXTURE_DOMAIN,
                label.encode("ascii"),
                _u64(counter),
            )
        )
        counter += 1
    return bytes(result[:size])


def _prefix_bytes(size: int) -> int:
    _require(size > 1, "fault object cannot expose a partial prefix")
    return min(4096, size - 1)


def _canonical_json_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _jsonable(value: Any) -> Any:
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Mapping):
        return {
            str(key): _jsonable(item)
            for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
        }
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _canonical_record_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        _jsonable(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")


def _make_plan() -> dict[str, Any]:
    epochs = 2
    records_per_epoch = 4
    warmup_epochs = 1
    measured_epochs = 1
    values: dict[str, Any] = {
        "abi_version": campaign.MANIFEST_ABI,
        "encoded_bytes": campaign.encoded_manifest_bytes(SEGMENT_COUNT),
        "flags": 0,
        "segment_count": SEGMENT_COUNT,
        "restart_after_segment": RESTART_AFTER_SEGMENT,
        "epochs_per_segment": epochs,
        "records_per_epoch": records_per_epoch,
        "warmup_epochs_per_segment": warmup_epochs,
        "measured_epochs_per_segment": measured_epochs,
        "completed_per_epoch": 1,
        "cancelled_per_epoch": 1,
        "failed_per_epoch": 1,
        "capacity_rejected_per_epoch": 1,
        "pins_per_epoch": 2,
        "events_per_epoch": 4,
        "epoch_cadence_ns": 1_000_000,
        "minimum_segment_duration_ns": 2_000_000,
        "maximum_segment_duration_ns": 5_000_000,
        "report_wire_bytes": REPORT_WIRE_BYTES,
        "artifact_store_max_bytes": STORE_MAX_BYTES,
        "rss_growth_bound_bytes": MIB,
        "total_epochs": SEGMENT_COUNT * epochs,
        "total_records": SEGMENT_COUNT * epochs * records_per_epoch,
        "total_warmup_records": (SEGMENT_COUNT * warmup_epochs * records_per_epoch),
        "total_measured_records": (SEGMENT_COUNT * measured_epochs * records_per_epoch),
        "total_completed": SEGMENT_COUNT * epochs,
        "total_cancelled": SEGMENT_COUNT * epochs,
        "total_failed": SEGMENT_COUNT * epochs,
        "total_capacity_rejected": SEGMENT_COUNT * epochs,
        "total_pin_acquisitions": SEGMENT_COUNT * epochs * 2,
        "device_allocation_growth_bound_bytes": MIB,
        "total_events": SEGMENT_COUNT * epochs * 4,
        "campaign_challenge_sha256": _digest("campaign-challenge"),
        "workload_sha256": _digest("workload"),
        "schedule_sha256": _digest("schedule"),
        "artifact_sha256": _digest("artifact"),
        "build_sha256": _digest("build"),
        "runner_sha256": _digest("runner"),
        "backend_library_sha256": _digest("backend-library"),
        "machine_sha256": _digest("machine"),
        "backend_sha256": _digest("backend"),
        "device_sha256": _digest("device"),
        "placement_sha256": _digest("placement"),
        "campaign_id_sha256": ZERO_DIGEST,
    }
    return campaign.seal_plan(values)


def _make_entries(
    plan: Mapping[str, Any],
    report_wires: Sequence[bytes],
) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
    _require(
        len(report_wires) == SEGMENT_COUNT
        and all(len(wire) == REPORT_WIRE_BYTES for wire in report_wires),
        "invalid report fixture",
    )
    result: list[Mapping[str, Any]] = []
    previous_entry = ZERO_DIGEST
    previous_report = ZERO_DIGEST
    cumulative_duration = 0
    per_segment_records = int(plan["epochs_per_segment"]) * int(
        plan["records_per_epoch"]
    )
    per_segment_completed = int(plan["epochs_per_segment"]) * int(
        plan["completed_per_epoch"]
    )
    for ordinal, report_wire in enumerate(report_wires):
        generation = 1 if ordinal < RESTART_AFTER_SEGMENT else 2
        restart_boundary = ordinal + 1 == RESTART_AFTER_SEGMENT
        final_boundary = ordinal + 1 == SEGMENT_COUNT
        action = (
            campaign.ACTION_GRACEFUL_PHASE_END
            if restart_boundary or final_boundary
            else campaign.ACTION_NORMAL
        )
        provenance = campaign.BASE_PROVENANCE_BITS
        if restart_boundary:
            provenance |= campaign.PROVENANCE_PLANNED_GRACEFUL_RESTART
        rss_source = _digest("rss-source-%d" % generation)
        scheduled_action = campaign.derive_scheduled_action(
            plan["campaign_id_sha256"],
            plan["schedule_sha256"],
            ordinal,
            generation,
            action,
            rss_source,
        )
        segment_challenge = campaign.derive_segment_challenge(
            plan["campaign_id_sha256"],
            ordinal,
            generation,
            previous_entry,
            previous_report,
            scheduled_action,
        )
        duration = int(plan["minimum_segment_duration_ns"]) + ordinal
        cumulative_duration += duration
        rss_availability = campaign.AVAILABILITY_UNSUPPORTED
        device_availability = campaign.AVAILABILITY_UNSUPPORTED
        device_source = _digest("device-allocation-source")
        verified_report_sha256 = _digest("verified-report-%d" % ordinal)
        value: dict[str, Any] = {
            "abi_version": campaign.ATTEMPT_ABI,
            "ordinal": ordinal,
            "process_generation": generation,
            "disposition": campaign.DISPOSITION_COMPLETE,
            "provenance_bits": provenance,
            "epoch_count": plan["epochs_per_segment"],
            "record_count": per_segment_records,
            "warmup_record_count": (
                int(plan["warmup_epochs_per_segment"]) * int(plan["records_per_epoch"])
            ),
            "measured_record_count": (
                int(plan["measured_epochs_per_segment"])
                * int(plan["records_per_epoch"])
            ),
            "completed_count": per_segment_completed,
            "cancelled_count": (
                int(plan["epochs_per_segment"]) * int(plan["cancelled_per_epoch"])
            ),
            "failed_count": (
                int(plan["epochs_per_segment"]) * int(plan["failed_per_epoch"])
            ),
            "capacity_rejected_count": (
                int(plan["epochs_per_segment"])
                * int(plan["capacity_rejected_per_epoch"])
            ),
            "pin_acquisitions": (
                int(plan["epochs_per_segment"]) * int(plan["pins_per_epoch"])
            ),
            "pin_completions": (
                int(plan["epochs_per_segment"]) * int(plan["pins_per_epoch"])
            ),
            "event_count": (
                int(plan["epochs_per_segment"]) * int(plan["events_per_epoch"])
            ),
            "report_wire_bytes": REPORT_WIRE_BYTES,
            "duration_ns": duration,
            "cumulative_duration_ns": cumulative_duration,
            "cumulative_records": (ordinal + 1) * per_segment_records,
            "cumulative_completed": ((ordinal + 1) * per_segment_completed),
            "rss_availability": rss_availability,
            "rss_before_bytes": 0,
            "rss_max_bytes": 0,
            "rss_after_bytes": 0,
            "device_allocation_availability": device_availability,
            "device_allocation_before_bytes": 0,
            "device_allocation_max_bytes": 0,
            "device_allocation_after_bytes": 0,
            "exit_code_bits": 0 if restart_boundary or final_boundary else U64_MAX,
            "termination_signal": 0,
            "reserved": 0,
            "scheduled_action_sha256": scheduled_action,
            "segment_challenge_sha256": segment_challenge,
            "previous_entry_sha256": previous_entry,
            "previous_verified_report_sha256": previous_report,
            "report_wire_sha256": _sha256(report_wire),
            "verified_report_sha256": verified_report_sha256,
            "scenario_sha256": _digest("scenario-%d" % ordinal),
            "closure_sha256": _digest("closure"),
            "build_sha256": plan["build_sha256"],
            "machine_sha256": plan["machine_sha256"],
            "backend_sha256": plan["backend_sha256"],
            "device_sha256": plan["device_sha256"],
            "placement_sha256": plan["placement_sha256"],
            "host_source_sha256": _digest("host-source"),
            "host_clock_sha256": _digest("host-clock"),
            "rss_source_sha256": rss_source,
            "rss_unavailable_reason_sha256": (
                campaign.derive_metric_unavailable_reason(
                    plan["campaign_id_sha256"],
                    ordinal,
                    rss_availability,
                    rss_source,
                )
            ),
            "device_allocation_source_sha256": device_source,
            "device_allocation_unavailable_reason_sha256": (
                campaign.derive_device_allocation_unavailable_reason(
                    plan["campaign_id_sha256"],
                    ordinal,
                    device_availability,
                    device_source,
                )
            ),
            "entry_sha256": ZERO_DIGEST,
        }
        entry = campaign.make_entry(plan, value)
        result.append(entry)
        previous_entry = entry["entry_sha256"]
        previous_report = verified_report_sha256
    return result[0], result[1]


def make_fixture() -> DeterministicFixture:
    """Build and independently round-trip the fixed two-generation fixture."""
    plan = _make_plan()
    report_one = _deterministic_bytes("report-one", REPORT_WIRE_BYTES)
    report_two = _deterministic_bytes("report-two", REPORT_WIRE_BYTES)
    entries = _make_entries(plan, (report_one, report_two))
    manifest_one = campaign.make_manifest(plan, entries[:1])
    manifest_two = campaign.make_manifest(plan, entries)
    decoded_one = campaign.verify_manifest(manifest_one)
    decoded_two = campaign.verify_manifest(manifest_two)

    environment_before = _canonical_json_bytes(
        {
            "fixture": "native-workload-store-fault",
            "generation": 1,
            "kind": "before",
            "native_execution": False,
        }
    )
    environment_after = _canonical_json_bytes(
        {
            "fixture": "native-workload-store-fault",
            "generation": 2,
            "kind": "after",
            "native_execution": False,
        }
    )
    before_sha256 = _sha256(environment_before)
    after_sha256 = _sha256(environment_after)
    environment_root_one = campaign.derive_environment_sha256(
        plan["campaign_id_sha256"],
        1,
        before_sha256,
        ZERO_DIGEST,
    )
    environment_root_two = campaign.derive_environment_sha256(
        plan["campaign_id_sha256"],
        2,
        before_sha256,
        after_sha256,
    )
    selector_one = campaign.make_selector(
        decoded_one,
        environment_root_one,
    )
    selector_two = campaign.make_selector(
        decoded_two,
        environment_root_two,
    )
    campaign.verify_selector(
        manifest_one,
        selector_one,
        environment_root_one,
    )
    campaign.verify_selector(
        manifest_two,
        selector_two,
        environment_root_two,
    )
    fixture_sha256 = _hash_parts(
        FIXTURE_DOMAIN,
        campaign.derive_plan_sha256(plan),
        entries[0]["entry_sha256"],
        entries[1]["entry_sha256"],
        before_sha256,
        after_sha256,
        _sha256(report_one),
        _sha256(report_two),
        decoded_one["manifest_sha256"],
        decoded_two["manifest_sha256"],
        campaign.decode_selector(selector_one)["selector_sha256"],
        campaign.decode_selector(selector_two)["selector_sha256"],
    )
    return DeterministicFixture(
        plan=plan,
        entries=entries,
        environment_before=environment_before,
        environment_after=environment_after,
        report_one=report_one,
        report_two=report_two,
        manifest_one=manifest_one,
        manifest_two=manifest_two,
        selector_one=selector_one,
        selector_two=selector_two,
        environment_before_sha256=before_sha256,
        environment_after_sha256=after_sha256,
        environment_root_one_sha256=environment_root_one,
        environment_root_two_sha256=environment_root_two,
        fixture_sha256=fixture_sha256,
    )


def prepare_publication(
    fixture: Optional[DeterministicFixture] = None,
) -> PreparedPublicationV1:
    """Seal the exact generation-one to generation-two publication."""
    fixture = make_fixture() if fixture is None else fixture
    decoded_one = campaign.verify_manifest(fixture.manifest_one)
    decoded_two = campaign.verify_manifest(fixture.manifest_two)
    selector_one = campaign.decode_selector(fixture.selector_one)
    selector_two = campaign.decode_selector(fixture.selector_two)
    plan_sha256 = campaign.derive_plan_sha256(fixture.plan)
    transaction_sha256 = _hash_parts(
        PREPARED_PUBLICATION_DOMAIN,
        fixture.plan["campaign_id_sha256"],
        plan_sha256,
        _u64(1),
        _u64(2),
        decoded_one["manifest_sha256"],
        decoded_two["manifest_sha256"],
        selector_one["selector_sha256"],
        selector_two["selector_sha256"],
        fixture.environment_after_sha256,
        _u64(len(fixture.environment_after)),
        _sha256(fixture.report_two),
        _u64(len(fixture.report_two)),
        _sha256(fixture.manifest_two),
        _u64(len(fixture.manifest_two)),
        _u64(STORE_MAX_BYTES),
        _u64(STORE_MAX_FILES),
    )
    object_specs = (
        ObjectSpec(
            "environment",
            ENVIRONMENTS_NAME,
            fixture.environment_after_sha256.hex() + ".json",
            fixture.environment_after,
            _object_phases(1, "environment"),
            transaction_sha256,
        ),
        ObjectSpec(
            "segment",
            SEGMENTS_NAME,
            _sha256(fixture.report_two).hex() + ".bin",
            fixture.report_two,
            _object_phases(8, "segment"),
            transaction_sha256,
        ),
        ObjectSpec(
            "manifest",
            MANIFESTS_NAME,
            decoded_two["manifest_sha256"].hex() + ".bin",
            fixture.manifest_two,
            _object_phases(15, "manifest"),
            transaction_sha256,
        ),
    )
    selector_spec = ObjectSpec(
        "selector",
        ".",
        ACTIVE_SELECTOR_NAME,
        fixture.selector_two,
        PHASES[21:],
        transaction_sha256,
    )
    result = PreparedPublicationV1(
        fixture=fixture,
        previous_generation=1,
        successor_generation=2,
        previous_manifest_sha256=decoded_one["manifest_sha256"],
        successor_manifest_sha256=decoded_two["manifest_sha256"],
        previous_selector_sha256=selector_one["selector_sha256"],
        successor_selector_sha256=selector_two["selector_sha256"],
        plan_sha256=plan_sha256,
        transaction_sha256=transaction_sha256,
        object_specs=object_specs,
        selector_spec=selector_spec,
    )
    validate_prepared_publication(result)
    return result


def validate_prepared_publication(
    prepared: PreparedPublicationV1,
) -> None:
    fixture = prepared.fixture
    canonical_fixture = make_fixture()
    _require(
        fixture == canonical_fixture,
        "prepared fixture is not the exact canonical fixture",
    )
    _require(
        prepared.previous_generation == 1 and prepared.successor_generation == 2,
        "prepared generation transition changed",
    )
    manifest_one = campaign.verify_manifest(fixture.manifest_one)
    manifest_two = campaign.verify_manifest(fixture.manifest_two)
    _require(
        manifest_one["plan"] == manifest_two["plan"] == dict(fixture.plan),
        "prepared plan changed",
    )
    _require(
        manifest_two["entries"][:1] == manifest_one["entries"]
        and len(manifest_one["entries"]) == 1
        and len(manifest_two["entries"]) == 2,
        "prepared manifest is not an exact successor",
    )
    _require(
        _sha256(fixture.report_one) == manifest_one["entries"][0]["report_wire_sha256"]
        and _sha256(fixture.report_two)
        == manifest_two["entries"][1]["report_wire_sha256"],
        "prepared report wire changed",
    )
    selector_one = campaign.verify_selector(
        fixture.manifest_one,
        fixture.selector_one,
        fixture.environment_root_one_sha256,
    )
    selector_two = campaign.verify_selector(
        fixture.manifest_two,
        fixture.selector_two,
        fixture.environment_root_two_sha256,
    )
    plan_sha256 = campaign.derive_plan_sha256(fixture.plan)
    _require(
        prepared.previous_manifest_sha256 == manifest_one["manifest_sha256"]
        and prepared.successor_manifest_sha256 == manifest_two["manifest_sha256"]
        and prepared.previous_selector_sha256 == selector_one["selector_sha256"]
        and prepared.successor_selector_sha256 == selector_two["selector_sha256"],
        "prepared manifest or selector root changed",
    )
    _require(
        prepared.plan_sha256 == plan_sha256,
        "prepared plan root changed",
    )
    rebuilt = _hash_parts(
        PREPARED_PUBLICATION_DOMAIN,
        fixture.plan["campaign_id_sha256"],
        plan_sha256,
        _u64(1),
        _u64(2),
        manifest_one["manifest_sha256"],
        manifest_two["manifest_sha256"],
        selector_one["selector_sha256"],
        selector_two["selector_sha256"],
        fixture.environment_after_sha256,
        _u64(len(fixture.environment_after)),
        _sha256(fixture.report_two),
        _u64(len(fixture.report_two)),
        _sha256(fixture.manifest_two),
        _u64(len(fixture.manifest_two)),
        _u64(STORE_MAX_BYTES),
        _u64(STORE_MAX_FILES),
    )
    _require(
        rebuilt == prepared.transaction_sha256,
        "prepared publication root changed",
    )
    expected_object_specs = (
        ObjectSpec(
            "environment",
            ENVIRONMENTS_NAME,
            fixture.environment_after_sha256.hex() + ".json",
            fixture.environment_after,
            _object_phases(1, "environment"),
            rebuilt,
        ),
        ObjectSpec(
            "segment",
            SEGMENTS_NAME,
            _sha256(fixture.report_two).hex() + ".bin",
            fixture.report_two,
            _object_phases(8, "segment"),
            rebuilt,
        ),
        ObjectSpec(
            "manifest",
            MANIFESTS_NAME,
            manifest_two["manifest_sha256"].hex() + ".bin",
            fixture.manifest_two,
            _object_phases(15, "manifest"),
            rebuilt,
        ),
    )
    expected_selector_spec = ObjectSpec(
        "selector",
        ".",
        ACTIVE_SELECTOR_NAME,
        fixture.selector_two,
        PHASES[21:],
        rebuilt,
    )
    _require(
        prepared.object_specs == expected_object_specs,
        "prepared object specifications changed",
    )
    _require(
        prepared.selector_spec == expected_selector_spec,
        "prepared selector specification changed",
    )
    expected_prepared = PreparedPublicationV1(
        fixture=canonical_fixture,
        previous_generation=1,
        successor_generation=2,
        previous_manifest_sha256=manifest_one["manifest_sha256"],
        successor_manifest_sha256=manifest_two["manifest_sha256"],
        previous_selector_sha256=selector_one["selector_sha256"],
        successor_selector_sha256=selector_two["selector_sha256"],
        plan_sha256=plan_sha256,
        transaction_sha256=rebuilt,
        object_specs=expected_object_specs,
        selector_spec=expected_selector_spec,
    )
    _require(
        prepared == expected_prepared,
        "prepared publication is not the exact canonical transaction",
    )


class FaultController:
    """Inject exactly one pre-operation errno or one post-operation SIGKILL."""

    def __init__(self, phase_id: int, mode: str) -> None:
        _require(
            phase_id in PHASE_BY_ID or (phase_id == 0 and mode == FAULT_NONE),
            "invalid fault phase",
        )
        _require(
            mode in (FAULT_NONE,) + FAULT_MODES,
            "invalid fault mode",
        )
        self.phase_id = phase_id
        self.mode = mode
        self.triggered = False

    def before(self, phase: PublicationPhase) -> None:
        if phase.phase_id != self.phase_id:
            return
        if self.mode == FAULT_EIO:
            self.triggered = True
            raise InjectedStoreFault(errno.EIO, phase.phase_id)
        if self.mode == FAULT_ENOSPC:
            self.triggered = True
            raise InjectedStoreFault(errno.ENOSPC, phase.phase_id)

    def after(self, phase: PublicationPhase) -> None:
        if phase.phase_id != self.phase_id:
            return
        if self.mode == FAULT_SIGKILL:
            self.triggered = True
            os.kill(os.getpid(), signal.SIGKILL)
            raise AssertionError("SIGKILL returned")

    def require_triggered(self) -> None:
        if self.mode != FAULT_NONE:
            _require(self.triggered, "configured fault did not trigger")

    def store_hook(
        self,
        timing: str,
        object_kind: str,
        operation: str,
    ) -> None:
        phase = STORE_HOOK_PHASES.get((object_kind, operation))
        _require(phase is not None, "production store hook phase changed")
        if timing == "before":
            self.before(phase)
        elif timing == "after":
            self.after(phase)
        else:
            raise StoreFaultCampaignError("production store hook timing changed")


def _directory_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _regular_read_flags() -> int:
    return os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


def _regular_write_flags(*, create: bool = False) -> int:
    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    if create:
        flags |= os.O_CREAT | os.O_EXCL
    return flags


def _write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError(errno.EIO, "short write")
        view = view[written:]


def _same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        left.st_dev == right.st_dev
        and left.st_ino == right.st_ino
        and stat.S_IFMT(left.st_mode) == stat.S_IFMT(right.st_mode)
    )


def _inspect_private_directory(
    descriptor: int,
    expected_device: Optional[int] = None,
) -> os.stat_result:
    info = os.fstat(descriptor)
    _require(stat.S_ISDIR(info.st_mode), "store directory is not a directory")
    _require(
        stat.S_IMODE(info.st_mode) == DIRECTORY_MODE,
        "store directory is not owner-private",
    )
    if expected_device is not None:
        _require(
            info.st_dev == expected_device,
            "store directory crossed a filesystem boundary",
        )
    return info


def _inspect_regular_at(
    directory_fd: int,
    name: str,
    *,
    expected_device: int,
    allowed_links: Iterable[int] = (1,),
) -> os.stat_result:
    entry = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    _require(stat.S_ISREG(entry.st_mode), "store entry is not a regular file")
    _require(
        stat.S_IMODE(entry.st_mode) == FILE_MODE,
        "store entry is not owner-private",
    )
    _require(
        entry.st_dev == expected_device,
        "store entry crossed a filesystem boundary",
    )
    _require(
        entry.st_nlink in set(allowed_links),
        "store entry has a foreign hard link",
    )
    descriptor = os.open(name, _regular_read_flags(), dir_fd=directory_fd)
    try:
        opened = os.fstat(descriptor)
        _require(
            _same_identity(entry, opened),
            "store entry identity changed while opening",
        )
    finally:
        os.close(descriptor)
    return entry


def _read_regular_at(
    directory_fd: int,
    name: str,
    *,
    expected_device: int,
    maximum_bytes: int,
    allowed_links: Iterable[int] = (1,),
) -> bytes:
    _require(maximum_bytes >= 0, "invalid read bound")
    entry = os.stat(
        name,
        dir_fd=directory_fd,
        follow_symlinks=False,
    )
    allowed_link_set = set(allowed_links)
    _require(
        stat.S_ISREG(entry.st_mode)
        and stat.S_IMODE(entry.st_mode) == FILE_MODE
        and entry.st_dev == expected_device
        and entry.st_nlink in allowed_link_set
        and 0 <= entry.st_size <= maximum_bytes,
        "store entry is not a bounded private regular file",
    )
    descriptor = os.open(name, _regular_read_flags(), dir_fd=directory_fd)
    try:
        before = os.fstat(descriptor)
        _require(
            _same_identity(entry, before)
            and stat.S_ISREG(before.st_mode)
            and stat.S_IMODE(before.st_mode) == FILE_MODE
            and before.st_dev == expected_device
            and before.st_nlink in allowed_link_set
            and 0 <= before.st_size <= maximum_bytes,
            "store entry identity changed while opening",
        )
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            _require(chunk != b"", "store entry was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        _require(
            os.read(descriptor, 1) == b"",
            "store entry grew while reading",
        )
        after = os.fstat(descriptor)
        _require(
            (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_nlink,
            )
            == (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_nlink,
            ),
            "store entry changed while reading",
        )
        return b"".join(chunks)
    finally:
        os.close(descriptor)


class StoreLease:
    """Descriptor-relative exclusive writer/recovery or shared audit lease."""

    def __init__(self, root: os.PathLike[str] | str, exclusive: bool) -> None:
        self.root_path = Path(root)
        self.root_fd = -1
        self.lock_fd = -1
        self.directory_fds: dict[str, int] = {}
        self.closed = False
        self.poisoned = False
        try:
            self.root_fd = os.open(self.root_path, _directory_flags())
            root_info = _inspect_private_directory(self.root_fd)
            self.root_device = root_info.st_dev
            root_entry = os.stat(
                self.root_path,
                follow_symlinks=False,
            )
            _require(
                _same_identity(root_entry, root_info),
                "store-root identity changed while opening",
            )
            self.root_identity = (root_info.st_dev, root_info.st_ino)
            self.directory_identities: dict[str, tuple[int, int]] = {}
            for name in (
                SEGMENTS_NAME,
                MANIFESTS_NAME,
                ENVIRONMENTS_NAME,
            ):
                descriptor = os.open(
                    name,
                    _directory_flags(),
                    dir_fd=self.root_fd,
                )
                try:
                    _inspect_private_directory(
                        descriptor,
                        self.root_device,
                    )
                    entry = os.stat(
                        name,
                        dir_fd=self.root_fd,
                        follow_symlinks=False,
                    )
                    _require(
                        _same_identity(entry, os.fstat(descriptor)),
                        "object-directory identity changed",
                    )
                except BaseException:
                    os.close(descriptor)
                    raise
                self.directory_fds[name] = descriptor
                self.directory_identities[name] = (
                    entry.st_dev,
                    entry.st_ino,
                )
            self.lock_fd = os.open(
                LOCK_NAME,
                (_regular_write_flags() if exclusive else _regular_read_flags()),
                dir_fd=self.root_fd,
            )
            lock_info = _inspect_regular_at(
                self.root_fd,
                LOCK_NAME,
                expected_device=self.root_device,
            )
            _require(
                _same_identity(lock_info, os.fstat(self.lock_fd)),
                "lock identity changed during acquisition",
            )
            operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
            try:
                fcntl.flock(self.lock_fd, operation | fcntl.LOCK_NB)
            except OSError as error:
                raise StoreFaultCampaignError(
                    "campaign store is already locked"
                ) from error
            locked_entry = os.stat(
                LOCK_NAME,
                dir_fd=self.root_fd,
                follow_symlinks=False,
            )
            _require(
                _same_identity(locked_entry, os.fstat(self.lock_fd)),
                "lock namespace changed after acquisition",
            )
            self.lock_identity = (
                lock_info.st_dev,
                lock_info.st_ino,
            )
            self.exclusive = exclusive
        except BaseException:
            self.close()
            raise

    @classmethod
    def create_seed(
        cls,
        root: os.PathLike[str] | str,
        prepared: PreparedPublicationV1,
    ) -> None:
        validate_prepared_publication(prepared)
        root_path = Path(root)
        _require(not os.path.lexists(root_path), "seed root already exists")
        os.mkdir(root_path, ROOT_MODE)
        os.chmod(root_path, ROOT_MODE, follow_symlinks=False)
        root_fd = os.open(root_path, _directory_flags())
        lock_fd = -1
        directory_fds: dict[str, int] = {}
        try:
            _inspect_private_directory(root_fd)
            for name in (
                SEGMENTS_NAME,
                MANIFESTS_NAME,
                ENVIRONMENTS_NAME,
            ):
                os.mkdir(name, DIRECTORY_MODE, dir_fd=root_fd)
                os.chmod(
                    name,
                    DIRECTORY_MODE,
                    dir_fd=root_fd,
                    follow_symlinks=False,
                )
                descriptor = os.open(name, _directory_flags(), dir_fd=root_fd)
                try:
                    _inspect_private_directory(
                        descriptor,
                        os.fstat(root_fd).st_dev,
                    )
                except BaseException:
                    os.close(descriptor)
                    raise
                directory_fds[name] = descriptor
            lock_fd = os.open(
                LOCK_NAME,
                _regular_write_flags(create=True),
                FILE_MODE,
                dir_fd=root_fd,
            )
            os.fchmod(lock_fd, FILE_MODE)
            os.fsync(lock_fd)
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.fsync(root_fd)

            fixture = prepared.fixture
            seed_specs = (
                (
                    directory_fds[ENVIRONMENTS_NAME],
                    fixture.environment_before_sha256.hex() + ".json",
                    fixture.environment_before,
                ),
                (
                    directory_fds[SEGMENTS_NAME],
                    _sha256(fixture.report_one).hex() + ".bin",
                    fixture.report_one,
                ),
                (
                    directory_fds[MANIFESTS_NAME],
                    prepared.previous_manifest_sha256.hex() + ".bin",
                    fixture.manifest_one,
                ),
            )
            for directory_fd, name, data in seed_specs:
                _seed_immutable(
                    directory_fd,
                    name,
                    data,
                    os.fstat(root_fd).st_dev,
                )
            _seed_selector(
                root_fd,
                fixture.selector_one,
                prepared.transaction_sha256,
                os.fstat(root_fd).st_dev,
            )
        except BaseException:
            if lock_fd >= 0:
                with contextlib.suppress(OSError):
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
            for descriptor in directory_fds.values():
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            if lock_fd >= 0:
                with contextlib.suppress(OSError):
                    os.close(lock_fd)
            with contextlib.suppress(OSError):
                os.close(root_fd)
            raise
        else:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
            for descriptor in directory_fds.values():
                os.close(descriptor)
            os.close(root_fd)

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.lock_fd >= 0:
            with contextlib.suppress(OSError):
                fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                os.close(self.lock_fd)
            self.lock_fd = -1
        for descriptor in self.directory_fds.values():
            with contextlib.suppress(OSError):
                os.close(descriptor)
        self.directory_fds.clear()
        if self.root_fd >= 0:
            with contextlib.suppress(OSError):
                os.close(self.root_fd)
            self.root_fd = -1

    def __enter__(self) -> StoreLease:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _verify_lock(self) -> None:
        _require(not self.closed, "store lease is closed")
        root_entry = os.stat(
            self.root_path,
            follow_symlinks=False,
        )
        _require(
            (root_entry.st_dev, root_entry.st_ino) == self.root_identity
            and _same_identity(root_entry, os.fstat(self.root_fd)),
            "store-root namespace changed",
        )
        for name, descriptor in self.directory_fds.items():
            entry = os.stat(
                name,
                dir_fd=self.root_fd,
                follow_symlinks=False,
            )
            _require(
                (entry.st_dev, entry.st_ino) == self.directory_identities[name]
                and _same_identity(entry, os.fstat(descriptor)),
                "object-directory namespace changed",
            )
        entry = _inspect_regular_at(
            self.root_fd,
            LOCK_NAME,
            expected_device=self.root_device,
        )
        _require(
            (entry.st_dev, entry.st_ino) == self.lock_identity
            and _same_identity(entry, os.fstat(self.lock_fd)),
            "lock namespace changed",
        )

    def publish_prepared(
        self,
        prepared: PreparedPublicationV1,
        fault: FaultController,
    ) -> dict[str, Any]:
        _require(self.exclusive, "publication requires an exclusive lease")
        _require(not self.poisoned, "store lease is poisoned")
        validate_prepared_publication(prepared)
        self._verify_lock()
        before = self.classify(prepared)
        _require(
            before.selected_generation == prepared.previous_generation
            and before.object_states == ("absent", "absent", "absent")
            and before.selector_temp_state == "absent",
            "publication did not start from the canonical previous generation",
        )
        self._preflight_peak(prepared)
        try:
            for spec in prepared.object_specs:
                self._publish_new_object(spec, fault)
            self._publish_selector(prepared, fault)
            fault.require_triggered()
            after = self.classify(prepared)
            _require(
                after.selected_generation == prepared.successor_generation,
                "clean publication did not select its successor",
            )
            return {
                "disposition": "applied",
                "selected_generation": after.selected_generation,
                "shape_sha256": after.shape_sha256,
            }
        except BaseException:
            self.poisoned = True
            raise

    def recover_prepared(
        self,
        prepared: PreparedPublicationV1,
    ) -> dict[str, Any]:
        _require(self.exclusive, "recovery requires an exclusive lease")
        _require(not self.poisoned, "store lease is poisoned")
        validate_prepared_publication(prepared)
        self._verify_lock()
        raw = self.classify(prepared)
        try:
            if raw.selected_generation == prepared.successor_generation:
                self._ensure_successor_objects(prepared)
                os.fsync(self.root_fd)
                final = self.classify(prepared)
                _require(
                    final.selected_generation == prepared.successor_generation,
                    "selected successor changed during recovery",
                )
                disposition = "already_applied"
            else:
                self._preflight_peak(prepared)
                for spec in prepared.object_specs:
                    self._ensure_object(spec)
                self._ensure_selector(prepared)
                final = self.classify(prepared)
                _require(
                    final.selected_generation == prepared.successor_generation,
                    "recovery did not select its successor",
                )
                disposition = "applied"
            strict = self.verify_strict(prepared, generation=2)
            return {
                "disposition": disposition,
                "raw_generation": raw.selected_generation,
                "raw_shape_sha256": raw.shape_sha256,
                "raw_object_states": raw.object_states,
                "raw_selector_temp_state": raw.selector_temp_state,
                "known_residue_files": raw.known_residue_files,
                "known_residue_bytes": raw.known_residue_bytes,
                "selected_generation": strict["selected_generation"],
                "final_shape_sha256": strict["shape_sha256"],
                "transaction_sha256": prepared.transaction_sha256,
            }
        except BaseException:
            self.poisoned = True
            raise

    def classify(
        self,
        prepared: PreparedPublicationV1,
    ) -> Classification:
        self._verify_lock()
        root_names = set(os.listdir(self.root_fd))
        selector_temp = _selector_temp_name(prepared)
        required_root = {
            SEGMENTS_NAME,
            MANIFESTS_NAME,
            ENVIRONMENTS_NAME,
            LOCK_NAME,
            ACTIVE_SELECTOR_NAME,
        }
        allowed_root = required_root | {selector_temp}
        _require(
            required_root <= root_names <= allowed_root,
            "store root contains unknown or missing entries",
        )
        active = _read_regular_at(
            self.root_fd,
            ACTIVE_SELECTOR_NAME,
            expected_device=self.root_device,
            maximum_bytes=campaign.SELECTOR_BYTES,
        )
        if active == prepared.fixture.selector_one:
            generation = prepared.previous_generation
        elif active == prepared.fixture.selector_two:
            generation = prepared.successor_generation
        else:
            raise StoreFaultCampaignError(
                "active selector is neither the prepared previous nor successor"
            )

        expected_base = _expected_object_sets(prepared, generation=1)
        candidate_by_directory: dict[str, ObjectSpec] = {
            spec.directory_name: spec for spec in prepared.object_specs
        }
        object_states: list[str] = []
        incomplete_seen = False
        residue_files = 0
        residue_bytes = 0
        for spec in prepared.object_specs:
            directory_fd = self.directory_fds[spec.directory_name]
            names = set(os.listdir(directory_fd))
            base_names = set(expected_base[spec.directory_name])
            allowed = base_names | {spec.target_name, spec.temporary_name}
            _require(
                base_names <= names <= allowed,
                "%s directory contains unknown or missing entries" % spec.object_kind,
            )
            for base_name, base_data in expected_base[spec.directory_name].items():
                _require(
                    _read_regular_at(
                        directory_fd,
                        base_name,
                        expected_device=self.root_device,
                        maximum_bytes=len(base_data),
                    )
                    == base_data,
                    "base %s object changed" % spec.object_kind,
                )
            state, files, byte_count = self._classify_object_residue(spec)
            object_states.append(state)
            residue_files += files
            residue_bytes += byte_count
            if incomplete_seen:
                _require(
                    state == "absent",
                    "publication residue is not an ordered prefix",
                )
            elif state != "target":
                incomplete_seen = True

        selector_temp_state = "absent"
        if selector_temp in root_names:
            selector_data = _read_regular_at(
                self.root_fd,
                selector_temp,
                expected_device=self.root_device,
                maximum_bytes=len(prepared.fixture.selector_two),
            )
            selector_temp_state = _prefix_state(
                selector_data,
                prepared.fixture.selector_two,
            )
            residue_files += 1
            residue_bytes += len(selector_data)

        if generation == prepared.successor_generation:
            _require(
                tuple(object_states) == ("target", "target", "target")
                and selector_temp_state == "absent",
                "selected successor has incomplete publication residue",
            )
        else:
            if selector_temp_state != "absent":
                _require(
                    tuple(object_states) == ("target", "target", "target"),
                    "selector residue precedes immutable objects",
                )
            candidate = candidate_by_directory
            _require(
                len(candidate) == 3,
                "candidate directory mapping changed",
            )
        self._enforce_usage(prepared)
        shape_sha256 = self._shape_sha256()
        self._verify_lock()
        return Classification(
            selected_generation=generation,
            object_states=(
                object_states[0],
                object_states[1],
                object_states[2],
            ),
            selector_temp_state=selector_temp_state,
            known_residue_files=residue_files,
            known_residue_bytes=residue_bytes,
            shape_sha256=shape_sha256,
        )

    def verify_strict(
        self,
        prepared: PreparedPublicationV1,
        *,
        generation: int,
    ) -> dict[str, Any]:
        validate_prepared_publication(prepared)
        self._verify_lock()
        _require(generation in (1, 2), "invalid strict generation")
        fixture = prepared.fixture
        root_names = set(os.listdir(self.root_fd))
        _require(
            root_names
            == {
                SEGMENTS_NAME,
                MANIFESTS_NAME,
                ENVIRONMENTS_NAME,
                LOCK_NAME,
                ACTIVE_SELECTOR_NAME,
            },
            "strict store root is not canonical",
        )
        expected = _expected_object_sets(prepared, generation=generation)
        for directory_name, objects in expected.items():
            directory_fd = self.directory_fds[directory_name]
            _require(
                set(os.listdir(directory_fd)) == set(objects),
                "strict %s object set changed" % directory_name,
            )
            for name, data in objects.items():
                _require(
                    _read_regular_at(
                        directory_fd,
                        name,
                        expected_device=self.root_device,
                        maximum_bytes=len(data),
                    )
                    == data,
                    "strict %s object changed" % directory_name,
                )
        expected_selector = (
            fixture.selector_one if generation == 1 else fixture.selector_two
        )
        selector_wire = _read_regular_at(
            self.root_fd,
            ACTIVE_SELECTOR_NAME,
            expected_device=self.root_device,
            maximum_bytes=campaign.SELECTOR_BYTES,
        )
        _require(
            selector_wire == expected_selector,
            "strict active selector changed",
        )
        manifest_wire = (
            fixture.manifest_one if generation == 1 else fixture.manifest_two
        )
        environment_root = (
            fixture.environment_root_one_sha256
            if generation == 1
            else fixture.environment_root_two_sha256
        )
        decoded = campaign.verify_manifest(manifest_wire)
        selector = campaign.verify_selector(
            manifest_wire,
            selector_wire,
            environment_root,
        )
        reports = (
            (fixture.report_one,)
            if generation == 1
            else (fixture.report_one, fixture.report_two)
        )
        _require(
            all(
                len(wire) == entry["report_wire_bytes"]
                and _sha256(wire) == entry["report_wire_sha256"]
                for wire, entry in zip(reports, decoded["entries"])
            ),
            "strict report binding changed",
        )
        self._enforce_usage(prepared)
        result = {
            "selected_generation": selector["generation"],
            "manifest_sha256": decoded["manifest_sha256"],
            "selector_sha256": selector["selector_sha256"],
            "final_entry_sha256": decoded["entries"][-1]["entry_sha256"],
            "shape_sha256": self._shape_sha256(),
            "transaction_sha256": prepared.transaction_sha256,
        }
        self._verify_lock()
        return result

    def _classify_object_residue(
        self,
        spec: ObjectSpec,
    ) -> tuple[str, int, int]:
        directory_fd = self.directory_fds[spec.directory_name]
        names = set(os.listdir(directory_fd))
        target_present = spec.target_name in names
        temporary_present = spec.temporary_name in names
        if not target_present and not temporary_present:
            return "absent", 0, 0
        if temporary_present:
            temporary_info = _inspect_regular_at(
                directory_fd,
                spec.temporary_name,
                expected_device=self.root_device,
                allowed_links=(1, 2),
            )
            temporary_data = _read_regular_at(
                directory_fd,
                spec.temporary_name,
                expected_device=self.root_device,
                maximum_bytes=len(spec.data),
                allowed_links=(1, 2),
            )
            temporary_state = _prefix_state(temporary_data, spec.data)
        else:
            temporary_info = None
            temporary_data = b""
            temporary_state = "absent"
        if target_present:
            target_info = _inspect_regular_at(
                directory_fd,
                spec.target_name,
                expected_device=self.root_device,
                allowed_links=(1, 2),
            )
            target_data = _read_regular_at(
                directory_fd,
                spec.target_name,
                expected_device=self.root_device,
                maximum_bytes=len(spec.data),
                allowed_links=(1, 2),
            )
            _require(
                target_data == spec.data,
                "%s target object is corrupt" % spec.object_kind,
            )
            if temporary_present:
                _require(
                    temporary_info is not None
                    and _same_identity(temporary_info, target_info)
                    and temporary_info.st_nlink == 2
                    and target_info.st_nlink == 2
                    and temporary_data == spec.data,
                    "%s target/temp pair is a foreign hard link" % spec.object_kind,
                )
                return "linked", 2, len(spec.data) * 2
            _require(
                target_info.st_nlink == 1,
                "%s target has a foreign hard link" % spec.object_kind,
            )
            return "target", 1, len(spec.data)
        _require(
            temporary_info is not None and temporary_info.st_nlink == 1,
            "%s temporary object has a foreign hard link" % spec.object_kind,
        )
        return temporary_state, 1, len(temporary_data)

    def _publish_new_object(
        self,
        spec: ObjectSpec,
        fault: FaultController,
    ) -> None:
        directory_fd = self.directory_fds[spec.directory_name]
        phases = spec.phases
        fault.before(phases[0])
        descriptor = os.open(
            spec.temporary_name,
            _regular_write_flags(create=True),
            FILE_MODE,
            dir_fd=directory_fd,
        )
        os.fchmod(descriptor, FILE_MODE)
        fault.after(phases[0])
        try:
            prefix = spec.prefix_bytes
            fault.before(phases[1])
            _write_all(descriptor, spec.data[:prefix])
            fault.after(phases[1])
            fault.before(phases[2])
            _write_all(descriptor, spec.data[prefix:])
            fault.after(phases[2])
            fault.before(phases[3])
            os.fsync(descriptor)
            fault.after(phases[3])
        finally:
            os.close(descriptor)
        fault.before(phases[4])
        os.link(
            spec.temporary_name,
            spec.target_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        fault.after(phases[4])
        linked_temp = os.stat(
            spec.temporary_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        linked_target = os.stat(
            spec.target_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        _require(
            _same_identity(linked_temp, linked_target) and linked_temp.st_nlink == 2,
            "new immutable object link identity changed",
        )
        fault.before(phases[5])
        os.unlink(spec.temporary_name, dir_fd=directory_fd)
        fault.after(phases[5])
        final_info = _inspect_regular_at(
            directory_fd,
            spec.target_name,
            expected_device=self.root_device,
        )
        _require(
            final_info.st_nlink == 1,
            "immutable target retained an extra link",
        )
        fault.before(phases[6])
        os.fsync(directory_fd)
        fault.after(phases[6])

    def _publish_selector(
        self,
        prepared: PreparedPublicationV1,
        fault: FaultController,
    ) -> None:
        spec = prepared.selector_spec
        phases = spec.phases
        temporary_name = _selector_temp_name(prepared)
        fault.before(phases[0])
        descriptor = os.open(
            temporary_name,
            _regular_write_flags(create=True),
            FILE_MODE,
            dir_fd=self.root_fd,
        )
        os.fchmod(descriptor, FILE_MODE)
        fault.after(phases[0])
        try:
            prefix = spec.prefix_bytes
            fault.before(phases[1])
            _write_all(descriptor, spec.data[:prefix])
            fault.after(phases[1])
            fault.before(phases[2])
            _write_all(descriptor, spec.data[prefix:])
            fault.after(phases[2])
            fault.before(phases[3])
            os.fsync(descriptor)
            fault.after(phases[3])
        finally:
            os.close(descriptor)
        _require(
            _read_regular_at(
                self.root_fd,
                ACTIVE_SELECTOR_NAME,
                expected_device=self.root_device,
                maximum_bytes=campaign.SELECTOR_BYTES,
            )
            == prepared.fixture.selector_one,
            "active selector changed before replacement",
        )
        fault.before(phases[4])
        os.replace(
            temporary_name,
            ACTIVE_SELECTOR_NAME,
            src_dir_fd=self.root_fd,
            dst_dir_fd=self.root_fd,
        )
        fault.after(phases[4])
        _require(
            _read_regular_at(
                self.root_fd,
                ACTIVE_SELECTOR_NAME,
                expected_device=self.root_device,
                maximum_bytes=campaign.SELECTOR_BYTES,
            )
            == prepared.fixture.selector_two,
            "active selector did not become the successor",
        )
        fault.before(phases[5])
        os.fsync(self.root_fd)
        fault.after(phases[5])

    def _ensure_object(self, spec: ObjectSpec) -> None:
        state, _files, _bytes = self._classify_object_residue(spec)
        directory_fd = self.directory_fds[spec.directory_name]
        if state == "linked":
            os.unlink(spec.temporary_name, dir_fd=directory_fd)
            os.fsync(directory_fd)
            state = "target"
        if state == "target":
            descriptor = os.open(
                spec.target_name,
                _regular_write_flags(),
                dir_fd=directory_fd,
            )
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            os.fsync(directory_fd)
            return
        if state != "absent":
            descriptor = os.open(
                spec.temporary_name,
                _regular_write_flags(),
                dir_fd=directory_fd,
            )
            try:
                info = os.fstat(descriptor)
                _require(
                    stat.S_ISREG(info.st_mode)
                    and stat.S_IMODE(info.st_mode) == FILE_MODE
                    and info.st_nlink == 1,
                    "recovery temporary object changed",
                )
                os.ftruncate(descriptor, 0)
                os.lseek(descriptor, 0, os.SEEK_SET)
                _write_all(descriptor, spec.data)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        else:
            descriptor = os.open(
                spec.temporary_name,
                _regular_write_flags(create=True),
                FILE_MODE,
                dir_fd=directory_fd,
            )
            try:
                os.fchmod(descriptor, FILE_MODE)
                _write_all(descriptor, spec.data)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        os.link(
            spec.temporary_name,
            spec.target_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        os.unlink(spec.temporary_name, dir_fd=directory_fd)
        os.fsync(directory_fd)
        _require(
            _read_regular_at(
                directory_fd,
                spec.target_name,
                expected_device=self.root_device,
                maximum_bytes=len(spec.data),
            )
            == spec.data,
            "recovered immutable object changed",
        )

    def _ensure_selector(
        self,
        prepared: PreparedPublicationV1,
    ) -> None:
        temporary_name = _selector_temp_name(prepared)
        root_names = set(os.listdir(self.root_fd))
        if temporary_name in root_names:
            descriptor = os.open(
                temporary_name,
                _regular_write_flags(),
                dir_fd=self.root_fd,
            )
            try:
                info = os.fstat(descriptor)
                _require(
                    stat.S_ISREG(info.st_mode)
                    and stat.S_IMODE(info.st_mode) == FILE_MODE
                    and info.st_nlink == 1,
                    "selector recovery candidate changed",
                )
                os.ftruncate(descriptor, 0)
                os.lseek(descriptor, 0, os.SEEK_SET)
                _write_all(descriptor, prepared.fixture.selector_two)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        else:
            descriptor = os.open(
                temporary_name,
                _regular_write_flags(create=True),
                FILE_MODE,
                dir_fd=self.root_fd,
            )
            try:
                os.fchmod(descriptor, FILE_MODE)
                _write_all(descriptor, prepared.fixture.selector_two)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        _require(
            _read_regular_at(
                self.root_fd,
                ACTIVE_SELECTOR_NAME,
                expected_device=self.root_device,
                maximum_bytes=campaign.SELECTOR_BYTES,
            )
            == prepared.fixture.selector_one,
            "recovery previous selector changed",
        )
        os.replace(
            temporary_name,
            ACTIVE_SELECTOR_NAME,
            src_dir_fd=self.root_fd,
            dst_dir_fd=self.root_fd,
        )
        os.fsync(self.root_fd)
        _require(
            _read_regular_at(
                self.root_fd,
                ACTIVE_SELECTOR_NAME,
                expected_device=self.root_device,
                maximum_bytes=campaign.SELECTOR_BYTES,
            )
            == prepared.fixture.selector_two,
            "recovery successor selector changed",
        )

    def _ensure_successor_objects(
        self,
        prepared: PreparedPublicationV1,
    ) -> None:
        for spec in prepared.object_specs:
            state, _files, _bytes = self._classify_object_residue(spec)
            _require(
                state == "target",
                "selected successor is missing an immutable object",
            )
            directory_fd = self.directory_fds[spec.directory_name]
            descriptor = os.open(
                spec.target_name,
                _regular_write_flags(),
                dir_fd=directory_fd,
            )
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            os.fsync(directory_fd)

    def _preflight_peak(
        self,
        prepared: PreparedPublicationV1,
    ) -> None:
        total_bytes, total_files = self._usage()
        new_bytes = sum(len(spec.data) for spec in prepared.object_specs)
        new_files = len(prepared.object_specs)
        selector_bytes = len(prepared.fixture.selector_two)
        # The immutable hard-link phase temporarily exposes both names for the
        # same inode, and this campaign deliberately bounds named-file bytes.
        peak_bytes = (
            total_bytes
            + new_bytes
            + max(len(spec.data) for spec in prepared.object_specs)
            + selector_bytes
        )
        peak_files = total_files + new_files + 1
        _require(
            peak_bytes <= STORE_MAX_BYTES and peak_files <= STORE_MAX_FILES,
            "prepared publication exceeds its transient store bound",
        )

    def _usage(self) -> tuple[int, int]:
        total_bytes = 0
        total_files = 0
        descriptors = [self.root_fd] + list(self.directory_fds.values())
        for descriptor in descriptors:
            for name in os.listdir(descriptor):
                info = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if stat.S_ISDIR(info.st_mode):
                    continue
                _require(
                    stat.S_ISREG(info.st_mode),
                    "store usage encountered a non-regular entry",
                )
                total_bytes += info.st_size
                total_files += 1
        return total_bytes, total_files

    def _enforce_usage(
        self,
        prepared: PreparedPublicationV1,
    ) -> None:
        total_bytes, total_files = self._usage()
        _require(
            total_bytes <= int(prepared.fixture.plan["artifact_store_max_bytes"])
            and total_files <= STORE_MAX_FILES,
            "campaign store exceeds its declared bound",
        )

    def _shape_sha256(self) -> bytes:
        records: list[dict[str, Any]] = []
        locations: list[tuple[str, int, str, os.stat_result]] = []
        for directory_name, descriptor in (
            (".", self.root_fd),
            (ENVIRONMENTS_NAME, self.directory_fds[ENVIRONMENTS_NAME]),
            (MANIFESTS_NAME, self.directory_fds[MANIFESTS_NAME]),
            (SEGMENTS_NAME, self.directory_fds[SEGMENTS_NAME]),
        ):
            for name in sorted(os.listdir(descriptor)):
                info = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if stat.S_ISDIR(info.st_mode):
                    continue
                _require(
                    stat.S_ISREG(info.st_mode),
                    "store shape encountered a non-regular entry",
                )
                key = (info.st_dev, info.st_ino)
                locations.append((directory_name, descriptor, name, info))
        sorted_locations = sorted(
            locations,
            key=lambda item: (item[0], item[2]),
        )
        link_groups: dict[tuple[int, int], int] = {}
        for directory_name, descriptor, name, info in sorted_locations:
            key = (info.st_dev, info.st_ino)
            if key not in link_groups:
                link_groups[key] = len(link_groups) + 1
            data = _read_regular_at(
                descriptor,
                name,
                expected_device=self.root_device,
                maximum_bytes=STORE_MAX_BYTES,
                allowed_links=(1, 2),
            )
            records.append(
                {
                    "path": (
                        name if directory_name == "." else directory_name + "/" + name
                    ),
                    "mode": stat.S_IMODE(info.st_mode),
                    "size": info.st_size,
                    "nlink": info.st_nlink,
                    "link_group": link_groups[key],
                    "content_sha256": _sha256(data).hex(),
                }
            )
        return _hash_parts(
            STORE_SHAPE_DOMAIN,
            _canonical_record_bytes({"files": records}),
        )


def _prefix_state(observed: bytes, expected: bytes) -> str:
    _require(
        len(observed) in (0, _prefix_bytes(len(expected)), len(expected))
        and observed == expected[: len(observed)],
        "temporary object is not an exact controlled prefix",
    )
    if len(observed) == 0:
        return "empty"
    if len(observed) == len(expected):
        return "full"
    return "prefix"


def _selector_temp_name(prepared: PreparedPublicationV1) -> str:
    return ".%s%s" % (ACTIVE_SELECTOR_NAME, STORE_TEMP_SUFFIX)


def _seed_immutable(
    directory_fd: int,
    name: str,
    data: bytes,
    root_device: int,
) -> None:
    temporary = ".%s.seed.tmp" % name
    descriptor = os.open(
        temporary,
        _regular_write_flags(create=True),
        FILE_MODE,
        dir_fd=directory_fd,
    )
    try:
        os.fchmod(descriptor, FILE_MODE)
        _write_all(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.link(
        temporary,
        name,
        src_dir_fd=directory_fd,
        dst_dir_fd=directory_fd,
        follow_symlinks=False,
    )
    os.unlink(temporary, dir_fd=directory_fd)
    os.fsync(directory_fd)
    _require(
        _read_regular_at(
            directory_fd,
            name,
            expected_device=root_device,
            maximum_bytes=len(data),
        )
        == data,
        "seed immutable object changed",
    )


def _seed_selector(
    root_fd: int,
    selector: bytes,
    transaction_sha256: bytes,
    root_device: int,
) -> None:
    temporary = ".%s.%s.seed.tmp" % (
        ACTIVE_SELECTOR_NAME,
        transaction_sha256.hex(),
    )
    descriptor = os.open(
        temporary,
        _regular_write_flags(create=True),
        FILE_MODE,
        dir_fd=root_fd,
    )
    try:
        os.fchmod(descriptor, FILE_MODE)
        _write_all(descriptor, selector)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(
        temporary,
        ACTIVE_SELECTOR_NAME,
        src_dir_fd=root_fd,
        dst_dir_fd=root_fd,
    )
    os.fsync(root_fd)
    _require(
        _read_regular_at(
            root_fd,
            ACTIVE_SELECTOR_NAME,
            expected_device=root_device,
            maximum_bytes=campaign.SELECTOR_BYTES,
        )
        == selector,
        "seed selector changed",
    )


def _expected_object_sets(
    prepared: PreparedPublicationV1,
    *,
    generation: int,
) -> dict[str, dict[str, bytes]]:
    fixture = prepared.fixture
    result = {
        ENVIRONMENTS_NAME: {
            fixture.environment_before_sha256.hex()
            + ".json": fixture.environment_before,
        },
        SEGMENTS_NAME: {
            _sha256(fixture.report_one).hex() + ".bin": fixture.report_one,
        },
        MANIFESTS_NAME: {
            prepared.previous_manifest_sha256.hex() + ".bin": fixture.manifest_one,
        },
    }
    if generation == 2:
        result[ENVIRONMENTS_NAME][fixture.environment_after_sha256.hex() + ".json"] = (
            fixture.environment_after
        )
        result[SEGMENTS_NAME][_sha256(fixture.report_two).hex() + ".bin"] = (
            fixture.report_two
        )
        result[MANIFESTS_NAME][prepared.successor_manifest_sha256.hex() + ".bin"] = (
            fixture.manifest_two
        )
    return result


def create_seed_store(
    root: os.PathLike[str] | str,
    prepared: Optional[PreparedPublicationV1] = None,
) -> PreparedPublicationV1:
    """Create and strictly verify a canonical generation-one store."""
    prepared = prepare_publication() if prepared is None else prepared
    StoreLease.create_seed(root, prepared)
    with StoreLease(root, exclusive=False) as lease:
        strict = lease.verify_strict(prepared, generation=1)
        _require(
            strict["selected_generation"] == 1,
            "seed store did not select generation one",
        )
    return prepared


def recover_store(
    root: os.PathLike[str] | str,
    prepared: Optional[PreparedPublicationV1] = None,
) -> dict[str, Any]:
    """Fresh-open and roll one exact prepared transition forward."""
    prepared = prepare_publication() if prepared is None else prepared
    with StoreLease(root, exclusive=True) as lease:
        return lease.recover_prepared(prepared)


def verify_store(
    root: os.PathLike[str] | str,
    prepared: Optional[PreparedPublicationV1] = None,
    *,
    generation: int = 2,
) -> dict[str, Any]:
    """Fresh-open and strictly audit one canonical generation."""
    prepared = prepare_publication() if prepared is None else prepared
    with StoreLease(root, exclusive=False) as lease:
        return lease.verify_strict(prepared, generation=generation)


def expected_raw_generation(phase_id: int, fault_mode: str) -> int:
    """Return the exact selected generation before recovery."""
    _require(phase_id in PHASE_BY_ID, "invalid expected-state phase")
    _require(fault_mode in FAULT_MODES, "invalid expected-state mode")
    if fault_mode == FAULT_SIGKILL:
        return 1 if phase_id <= 25 else 2
    return 1 if phase_id <= 26 else 2


def _module_command(*arguments: str) -> tuple[str, ...]:
    return (
        sys.executable,
        "-m",
        "bench.native_workload_store_fault_campaign",
        *arguments,
    )


def _run_child(arguments: Sequence[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        tuple(arguments),
        check=False,
        capture_output=True,
        text=True,
        timeout=CHILD_TIMEOUT_SECONDS,
    )
    _require(
        len(result.stdout.encode("utf-8")) <= MAX_CHILD_OUTPUT_BYTES
        and len(result.stderr.encode("utf-8")) <= MAX_CHILD_OUTPUT_BYTES,
        "child output exceeded its bound",
    )
    return result


def _parse_child_result(
    result: subprocess.CompletedProcess[str],
    schema: str,
) -> dict[str, Any]:
    _require(result.returncode == 0, "child process failed: %s" % result.stderr)
    _require(result.stderr == "", "child process wrote stderr")
    lines = result.stdout.splitlines()
    _require(len(lines) == 1, "child output is not one record")
    try:
        decoded = json.loads(lines[0])
    except (TypeError, ValueError) as error:
        raise StoreFaultCampaignError("child output is not JSON") from error
    _require(
        isinstance(decoded, dict)
        and decoded.get("schema") == schema
        and decoded.get("verified") is True,
        "child output schema changed",
    )
    return decoded


def _writer_case(
    root: Path,
    phase: PublicationPhase,
    fault_mode: str,
) -> tuple[int, int]:
    result = _run_child(
        _module_command(
            "_child-write",
            str(root),
            str(phase.phase_id),
            fault_mode,
        )
    )
    if fault_mode == FAULT_SIGKILL:
        _require(
            result.returncode == -signal.SIGKILL,
            "writer was not terminated by SIGKILL",
        )
        _require(
            result.stdout == "" and result.stderr == "",
            "killed writer emitted output",
        )
        return U64_MAX, int(signal.SIGKILL)
    expected_exit = CHILD_INJECTED_ERRNO_EXIT
    _require(
        result.returncode == expected_exit,
        "injected writer returned an unexpected status: %s" % result.stderr,
    )
    _require(result.stderr == "", "injected writer wrote stderr")
    lines = result.stdout.splitlines()
    _require(len(lines) == 1, "injected writer output changed")
    record = json.loads(lines[0])
    expected_errno = errno.EIO if fault_mode == FAULT_EIO else errno.ENOSPC
    _require(
        record
        == {
            "errno": expected_errno,
            "phase_id": phase.phase_id,
            "schema": "glacier.native-workload-store-fault/injected-v1",
            "verified": True,
        },
        "injected writer evidence changed",
    )
    return expected_exit, 0


def _fresh_recover(root: Path) -> dict[str, Any]:
    result = _run_child(_module_command("_child-recover", str(root)))
    return _parse_child_result(
        result,
        "glacier.native-workload-store-fault/recovery-v1",
    )


def _fresh_verify(root: Path) -> dict[str, Any]:
    result = _run_child(_module_command("_child-verify", str(root)))
    return _parse_child_result(
        result,
        "glacier.native-workload-store-fault/strict-v1",
    )


def _clean_writer(root: Path) -> tuple[int, int]:
    result = _run_child(
        _module_command(
            "_child-write",
            str(root),
            "0",
            FAULT_NONE,
        )
    )
    _parse_child_result(
        result,
        "glacier.native-workload-store-fault/writer-v1",
    )
    return 0, 0


def _case_root(
    record: Mapping[str, Any],
) -> bytes:
    return _hash_parts(CASE_RECORD_DOMAIN, _canonical_record_bytes(record))


def _matrix_schedule_sha256() -> bytes:
    return _hash_parts(
        REPORT_SCHEDULE_DOMAIN,
        _canonical_record_bytes(
            {
                "fault_modes": list(FAULT_MODES),
                "phases": [
                    {
                        "id": phase.phase_id,
                        "name": phase.name,
                        "object_kind": phase.object_kind,
                        "operation": phase.operation,
                    }
                    for phase in PHASES
                ],
            }
        ),
    )


def _machine_profile_sha256() -> bytes:
    uname = platform.uname()
    return _hash_parts(
        MACHINE_PROFILE_DOMAIN,
        _canonical_record_bytes(
            {
                "system": uname.system,
                "release": uname.release,
                "machine": uname.machine,
                "python_implementation": platform.python_implementation(),
                "python_version": platform.python_version(),
            }
        ),
    )


def _filesystem_profile_sha256(path: Path) -> bytes:
    filesystem = os.statvfs(path)
    entry = path.stat()
    return _hash_parts(
        FILESYSTEM_PROFILE_DOMAIN,
        _canonical_record_bytes(
            {
                "device": entry.st_dev,
                "block_size": filesystem.f_bsize,
                "fragment_size": filesystem.f_frsize,
                "name_max": filesystem.f_namemax,
                "flags": filesystem.f_flag,
            }
        ),
    )


def _source_component_paths() -> dict[str, Path]:
    module_source = Path(__file__).resolve()
    source_root = module_source.parent
    return {
        "campaign_module_sha256": module_source,
        "campaign_codec_sha256": Path(campaign.__file__).resolve(),
        "store_adapter_sha256": (source_root / "native_metal_soak_report.py").resolve(),
        "lane4_evidence_sha256": (source_root / "lane4_evidence.py").resolve(),
        "metal_disruption_report_sha256": (
            source_root / "native_metal_disruption_report.py"
        ).resolve(),
        "metal_workload_report_sha256": (
            source_root / "native_metal_workload_report.py"
        ).resolve(),
        "native_observation_common_sha256": (
            source_root / "native_observation_common.py"
        ).resolve(),
        "native_observer_sha256": (source_root / "native_observer.py").resolve(),
        "native_observer_linux_sha256": (
            source_root / "native_observer_linux.py"
        ).resolve(),
        "portable_workload_report_sha256": (
            source_root / "native_workload_report.py"
        ).resolve(),
        "report_codec_sha256": (
            source_root / "native_workload_store_fault_report.py"
        ).resolve(),
    }


def _source_snapshot_sha256(snapshot: Mapping[str, bytes]) -> bytes:
    _require(
        type(snapshot) is dict
        and set(snapshot) == SOURCE_COMPONENT_KEYS
        and all(
            _is_digest(value) and value != ZERO_DIGEST for value in snapshot.values()
        ),
        "source snapshot schema changed",
    )
    return _hash_parts(
        SOURCE_SNAPSHOT_DOMAIN,
        _canonical_record_bytes(snapshot),
    )


def _snapshot_source_components() -> dict[str, bytes]:
    paths = _source_component_paths()
    _require(
        type(paths) is dict and set(paths) == SOURCE_COMPONENT_KEYS,
        "source component path table changed",
    )
    snapshot = {
        name: _sha256(
            _read_bounded_regular_file(
                path,
                minimum_bytes=1,
                maximum_bytes=MAX_SOURCE_COMPONENT_BYTES,
            )
        )
        for name, path in paths.items()
    }
    _source_snapshot_sha256(snapshot)
    return snapshot


def _verify_source_components_unchanged(
    expected: Mapping[str, bytes],
) -> None:
    _source_snapshot_sha256(expected)
    _require(
        _snapshot_source_components() == expected,
        "source component changed during campaign execution",
    )


def _source_role_sha256(role: str, source_sha256: bytes) -> bytes:
    _require(_is_digest(source_sha256), "source role digest changed")
    return _hash_parts(
        REPORT_ROLE_DOMAIN,
        role.encode("ascii"),
        source_sha256,
    )


def _source_graph_sha256(
    role: str,
    snapshot: Mapping[str, bytes],
    component_keys: Sequence[str],
) -> bytes:
    _source_snapshot_sha256(snapshot)
    _require(
        len(component_keys) > 0
        and len(set(component_keys)) == len(component_keys)
        and set(component_keys).issubset(SOURCE_COMPONENT_KEYS),
        "source graph component table changed",
    )
    parts: list[bytes] = [role.encode("ascii")]
    for name in component_keys:
        parts.extend((name.encode("ascii"), b"\x00", snapshot[name]))
    return _hash_parts(REPORT_ROLE_DOMAIN, *parts)


def _report_source_identities(
    snapshot: Mapping[str, bytes],
) -> dict[str, bytes]:
    _source_snapshot_sha256(snapshot)
    campaign_module_sha256 = snapshot["campaign_module_sha256"]
    return {
        "worker_sha256": _source_role_sha256(
            "writer-child",
            campaign_module_sha256,
        ),
        "campaign_codec_sha256": snapshot["campaign_codec_sha256"],
        "store_adapter_sha256": _source_graph_sha256(
            "production-campaign-store-dependency-graph",
            snapshot,
            STORE_ADAPTER_GRAPH_KEYS,
        ),
        "fault_injector_sha256": _source_role_sha256(
            "fault-controller",
            campaign_module_sha256,
        ),
        "supervisor_sha256": _source_role_sha256(
            "matrix-supervisor",
            campaign_module_sha256,
        ),
        "offline_verifier_sha256": _source_graph_sha256(
            "campaign-and-report-verifier",
            snapshot,
            (
                "campaign_module_sha256",
                "report_codec_sha256",
            ),
        ),
    }


def run_matrix(
    work_root: Optional[os.PathLike[str] | str] = None,
    *,
    retain_cases: bool = False,
) -> dict[str, Any]:
    """Run 81 fault cases plus one clean control and return report inputs.

    Every case starts from a newly seeded generation-one store.  The writer,
    first recovery, second recovery, and strict verifier are distinct
    subprocesses.  Case directories are processed sequentially and removed
    after verification unless ``retain_cases`` is explicitly requested.
    """
    _require(
        not retain_cases or work_root is not None,
        "retaining cases requires an explicit work root",
    )
    source_snapshot = _snapshot_source_components()
    source_snapshot_sha256 = _source_snapshot_sha256(source_snapshot)
    prepared = prepare_publication()
    _verify_source_components_unchanged(source_snapshot)
    owned_parent: Optional[tempfile.TemporaryDirectory[str]] = None
    if work_root is None:
        owned_parent = tempfile.TemporaryDirectory(prefix="glacier-store-fault-matrix-")
        parent = Path(owned_parent.name)
    else:
        parent_path = Path(work_root)
        _require(
            parent_path.is_dir() and not parent_path.is_symlink(),
            "matrix work root is not a real directory",
        )
        parent = Path(
            tempfile.mkdtemp(
                prefix="glacier-store-fault-matrix-",
                dir=parent_path,
            )
        )
        os.chmod(parent, ROOT_MODE)

    records: list[dict[str, Any]] = []
    previous_case_sha256 = ZERO_DIGEST
    applied = 0
    already_applied = 0
    raw_previous = 0
    raw_successor = 0
    canonical_before_sha256: Optional[bytes] = None
    canonical_after_sha256: Optional[bytes] = None
    machine_sha256 = _machine_profile_sha256()
    filesystem_profile_sha256 = _filesystem_profile_sha256(parent)
    try:
        ordinal = 0
        for fault_mode in FAULT_MODES:
            for phase in PHASES:
                _verify_source_components_unchanged(source_snapshot)
                case_directory = parent / (
                    "case-%03d-%s-%02d" % (ordinal, fault_mode, phase.phase_id)
                )
                create_seed_store(case_directory, prepared)
                if canonical_before_sha256 is None:
                    canonical_before_sha256 = verify_store(
                        case_directory,
                        prepared,
                        generation=1,
                    )["shape_sha256"]
                exit_code_bits, termination_signal = _writer_case(
                    case_directory,
                    phase,
                    fault_mode,
                )
                _verify_source_components_unchanged(source_snapshot)
                first = _fresh_recover(case_directory)
                _verify_source_components_unchanged(source_snapshot)
                second = _fresh_recover(case_directory)
                _verify_source_components_unchanged(source_snapshot)
                strict = _fresh_verify(case_directory)
                _verify_source_components_unchanged(source_snapshot)
                expected_generation = expected_raw_generation(
                    phase.phase_id,
                    fault_mode,
                )
                _require(
                    first["raw_generation"] == expected_generation,
                    "raw generation disagrees with the exact phase model",
                )
                expected_disposition = (
                    "applied" if expected_generation == 1 else "already_applied"
                )
                _require(
                    first["disposition"] == expected_disposition,
                    "first recovery disposition changed",
                )
                _require(
                    second["disposition"] == "already_applied"
                    and second["raw_generation"] == 2,
                    "second recovery is not idempotent",
                )
                _require(
                    strict["selected_generation"] == 2
                    and strict["transaction_sha256"]
                    == prepared.transaction_sha256.hex(),
                    "fresh strict verifier rejected the successor",
                )
                if canonical_after_sha256 is None:
                    canonical_after_sha256 = bytes.fromhex(strict["shape_sha256"])
                else:
                    _require(
                        bytes.fromhex(strict["shape_sha256"]) == canonical_after_sha256,
                        "canonical successor shape changed across cases",
                    )
                core_record: dict[str, Any] = {
                    "case_ordinal": ordinal,
                    "fault_mode": fault_mode,
                    "phase_id": phase.phase_id,
                    "phase_name": phase.name,
                    "object_kind": phase.object_kind,
                    "operation": phase.operation,
                    "expected_raw_generation": expected_generation,
                    "observed_raw_generation": first["raw_generation"],
                    "writer_exit_code_bits": exit_code_bits,
                    "writer_termination_signal": termination_signal,
                    "first_recovery_disposition": first["disposition"],
                    "second_recovery_disposition": second["disposition"],
                    "known_residue_files": first["known_residue_files"],
                    "known_residue_bytes": first["known_residue_bytes"],
                    "raw_shape_sha256": bytes.fromhex(first["raw_shape_sha256"]),
                    "final_shape_sha256": bytes.fromhex(strict["shape_sha256"]),
                    "final_manifest_sha256": bytes.fromhex(strict["manifest_sha256"]),
                    "final_selector_sha256": bytes.fromhex(strict["selector_sha256"]),
                    "final_entry_sha256": bytes.fromhex(strict["final_entry_sha256"]),
                    "transaction_sha256": prepared.transaction_sha256,
                    "previous_case_sha256": previous_case_sha256,
                }
                case_sha256 = _case_root(core_record)
                record = dict(core_record)
                record["case_sha256"] = case_sha256
                records.append(record)
                previous_case_sha256 = case_sha256
                if first["disposition"] == "applied":
                    applied += 1
                else:
                    already_applied += 1
                if expected_generation == 1:
                    raw_previous += 1
                else:
                    raw_successor += 1
                ordinal += 1
                if not retain_cases:
                    shutil.rmtree(case_directory)

        clean_directory = parent / ("case-%03d-clean" % ordinal)
        _verify_source_components_unchanged(source_snapshot)
        create_seed_store(clean_directory, prepared)
        exit_code_bits, termination_signal = _clean_writer(clean_directory)
        _verify_source_components_unchanged(source_snapshot)
        first = _fresh_recover(clean_directory)
        _verify_source_components_unchanged(source_snapshot)
        second = _fresh_recover(clean_directory)
        _verify_source_components_unchanged(source_snapshot)
        strict = _fresh_verify(clean_directory)
        _verify_source_components_unchanged(source_snapshot)
        _require(
            first["raw_generation"] == 2
            and first["disposition"] == "already_applied"
            and second["disposition"] == "already_applied"
            and strict["selected_generation"] == 2,
            "clean control changed",
        )
        clean_core: dict[str, Any] = {
            "case_ordinal": ordinal,
            "fault_mode": FAULT_NONE,
            "phase_id": 0,
            "phase_name": "clean-control",
            "object_kind": "transaction",
            "operation": "complete",
            "expected_raw_generation": 2,
            "observed_raw_generation": first["raw_generation"],
            "writer_exit_code_bits": exit_code_bits,
            "writer_termination_signal": termination_signal,
            "first_recovery_disposition": first["disposition"],
            "second_recovery_disposition": second["disposition"],
            "known_residue_files": first["known_residue_files"],
            "known_residue_bytes": first["known_residue_bytes"],
            "raw_shape_sha256": bytes.fromhex(first["raw_shape_sha256"]),
            "final_shape_sha256": bytes.fromhex(strict["shape_sha256"]),
            "final_manifest_sha256": bytes.fromhex(strict["manifest_sha256"]),
            "final_selector_sha256": bytes.fromhex(strict["selector_sha256"]),
            "final_entry_sha256": bytes.fromhex(strict["final_entry_sha256"]),
            "transaction_sha256": prepared.transaction_sha256,
            "previous_case_sha256": previous_case_sha256,
        }
        clean_sha256 = _case_root(clean_core)
        clean_record = dict(clean_core)
        clean_record["case_sha256"] = clean_sha256
        records.append(clean_record)
        previous_case_sha256 = clean_sha256
        if not retain_cases:
            shutil.rmtree(clean_directory)

        _require(
            len(records) == 82
            and applied == 77
            and already_applied == 4
            and raw_previous == 77
            and raw_successor == 4,
            "fault matrix accounting changed",
        )
        _require(
            canonical_before_sha256 is not None
            and canonical_after_sha256 is not None
            and canonical_before_sha256 != canonical_after_sha256,
            "canonical store transition was not established",
        )
        _verify_source_components_unchanged(source_snapshot)
        matrix_sha256 = _hash_parts(
            MATRIX_DOMAIN,
            prepared.fixture.fixture_sha256,
            prepared.transaction_sha256,
            b"".join(record["case_sha256"] for record in records),
        )
        result: dict[str, Any] = {
            "schema": "glacier.native-workload-store-fault/report-input-v1",
            "fixture_sha256": prepared.fixture.fixture_sha256,
            "campaign_id_sha256": prepared.fixture.plan["campaign_id_sha256"],
            "plan_sha256": prepared.plan_sha256,
            "transaction_sha256": prepared.transaction_sha256,
            "previous_manifest_sha256": (prepared.previous_manifest_sha256),
            "successor_manifest_sha256": (prepared.successor_manifest_sha256),
            "previous_selector_sha256": (prepared.previous_selector_sha256),
            "successor_selector_sha256": (prepared.successor_selector_sha256),
            "records": records,
            "fault_cases": 81,
            "clean_controls": 1,
            "sigkill_cases": 27,
            "eio_cases": 27,
            "enospc_cases": 27,
            "first_recovery_applied": applied,
            "first_recovery_already_applied": already_applied + 1,
            "raw_previous_generations": raw_previous,
            "raw_successor_generations": raw_successor + 1,
            "second_recovery_already_applied": 82,
            "strict_verified_cases": 82,
            "final_case_sha256": previous_case_sha256,
            "matrix_sha256": matrix_sha256,
            "canonical_store_before_sha256": (canonical_before_sha256),
            "canonical_store_after_sha256": canonical_after_sha256,
            "machine_sha256": machine_sha256,
            "filesystem_profile_sha256": filesystem_profile_sha256,
            "source_snapshot": source_snapshot,
            "source_snapshot_sha256": source_snapshot_sha256,
            "host_process_execution": True,
            "host_filesystem_operations": True,
            "workload_execution": False,
            "gpu_execution": False,
            "synthetic_errno": True,
            "physical_storage_fault": False,
            "power_loss_emulated": False,
        }
        result["report_input_sha256"] = _hash_parts(
            REPORT_CHALLENGE_DOMAIN,
            _canonical_record_bytes(result),
        )
        _verify_source_components_unchanged(source_snapshot)
        return result
    finally:
        if owned_parent is not None:
            owned_parent.cleanup()
        elif not retain_cases:
            with contextlib.suppress(FileNotFoundError):
                shutil.rmtree(parent)
        _verify_source_components_unchanged(source_snapshot)


def _report_phase_values(
    report: Any,
    prepared: PreparedPublicationV1,
    phase: PublicationPhase,
) -> tuple[int, int, int, int]:
    object_kind = {
        "segment": report.OBJECT_SEGMENT,
        "environment": report.OBJECT_ENVIRONMENT,
        "manifest": report.OBJECT_MANIFEST,
        "selector": report.OBJECT_SELECTOR,
        "store_root": report.OBJECT_STORE_ROOT,
    }[phase.object_kind]
    if phase.operation == "create":
        operation = report.OPERATION_CREATE
    elif phase.operation in ("write-prefix", "write-remainder"):
        operation = report.OPERATION_WRITE
    elif phase.operation == "fsync-file":
        operation = report.OPERATION_FILE_SYNC
    elif phase.operation == "link":
        operation = report.OPERATION_LINK
    elif phase.operation == "unlink":
        operation = report.OPERATION_UNLINK
    elif phase.operation == "replace":
        operation = report.OPERATION_REPLACE
    elif phase.operation in ("fsync-directory", "directory_sync"):
        operation = report.OPERATION_DIRECTORY_SYNC
    else:
        _require(
            False,
            "report phase operation changed",
        )
        raise AssertionError("unreachable")
    occurrence = 2 if phase.operation == "write-remainder" else 1
    requested = 0
    if operation == report.OPERATION_WRITE:
        if phase.object_kind == "selector":
            spec = prepared.selector_spec
        else:
            spec = next(
                value
                for value in prepared.object_specs
                if value.object_kind == phase.object_kind
            )
        requested = (
            spec.prefix_bytes if occurrence == 1 else len(spec.data) - spec.prefix_bytes
        )
    return object_kind, operation, occurrence, requested


REPORT_INPUT_KEYS = frozenset(
    {
        "schema",
        "fixture_sha256",
        "campaign_id_sha256",
        "plan_sha256",
        "transaction_sha256",
        "previous_manifest_sha256",
        "successor_manifest_sha256",
        "previous_selector_sha256",
        "successor_selector_sha256",
        "records",
        "fault_cases",
        "clean_controls",
        "sigkill_cases",
        "eio_cases",
        "enospc_cases",
        "first_recovery_applied",
        "first_recovery_already_applied",
        "raw_previous_generations",
        "raw_successor_generations",
        "second_recovery_already_applied",
        "strict_verified_cases",
        "final_case_sha256",
        "matrix_sha256",
        "canonical_store_before_sha256",
        "canonical_store_after_sha256",
        "machine_sha256",
        "filesystem_profile_sha256",
        "source_snapshot",
        "source_snapshot_sha256",
        "host_process_execution",
        "host_filesystem_operations",
        "workload_execution",
        "gpu_execution",
        "synthetic_errno",
        "physical_storage_fault",
        "power_loss_emulated",
        "report_input_sha256",
    }
)

REPORT_INPUT_RECORD_KEYS = frozenset(
    {
        "case_ordinal",
        "fault_mode",
        "phase_id",
        "phase_name",
        "object_kind",
        "operation",
        "expected_raw_generation",
        "observed_raw_generation",
        "writer_exit_code_bits",
        "writer_termination_signal",
        "first_recovery_disposition",
        "second_recovery_disposition",
        "known_residue_files",
        "known_residue_bytes",
        "raw_shape_sha256",
        "final_shape_sha256",
        "final_manifest_sha256",
        "final_selector_sha256",
        "final_entry_sha256",
        "transaction_sha256",
        "previous_case_sha256",
        "case_sha256",
    }
)


def _is_digest(value: object) -> bool:
    return type(value) is bytes and len(value) == 32


def verify_report_input_v1(
    report_input: Mapping[str, Any],
) -> Mapping[str, Any]:
    """Verify the exact live-run input before constructing a binary report.

    The binary report is structural, self-asserted evidence.  This gate binds
    it to the full live runner result whose subprocess and OS-event checks
    already succeeded; decoding the binary alone does not replay those events.
    """
    _require(
        type(report_input) is dict
        and set(report_input) == REPORT_INPUT_KEYS
        and report_input["schema"]
        == "glacier.native-workload-store-fault/report-input-v1",
        "report input top-level schema changed",
    )
    prepared = prepare_publication()
    expected_identities = {
        "fixture_sha256": prepared.fixture.fixture_sha256,
        "campaign_id_sha256": prepared.fixture.plan["campaign_id_sha256"],
        "plan_sha256": prepared.plan_sha256,
        "transaction_sha256": prepared.transaction_sha256,
        "previous_manifest_sha256": prepared.previous_manifest_sha256,
        "successor_manifest_sha256": prepared.successor_manifest_sha256,
        "previous_selector_sha256": prepared.previous_selector_sha256,
        "successor_selector_sha256": prepared.successor_selector_sha256,
    }
    _require(
        all(
            _is_digest(report_input[name]) and report_input[name] == expected
            for name, expected in expected_identities.items()
        ),
        "report input prepared identity changed",
    )
    digest_names = (
        "final_case_sha256",
        "matrix_sha256",
        "canonical_store_before_sha256",
        "canonical_store_after_sha256",
        "machine_sha256",
        "filesystem_profile_sha256",
        "source_snapshot_sha256",
        "report_input_sha256",
    )
    _require(
        all(_is_digest(report_input[name]) for name in digest_names)
        and report_input["canonical_store_before_sha256"]
        != report_input["canonical_store_after_sha256"],
        "report input digest identity changed",
    )
    source_snapshot = report_input["source_snapshot"]
    _require(
        type(source_snapshot) is dict
        and set(source_snapshot) == SOURCE_COMPONENT_KEYS
        and all(
            _is_digest(value) and value != ZERO_DIGEST
            for value in source_snapshot.values()
        )
        and report_input["source_snapshot_sha256"]
        == _source_snapshot_sha256(source_snapshot),
        "report input source snapshot changed",
    )
    expected_counts = {
        "fault_cases": 81,
        "clean_controls": 1,
        "sigkill_cases": 27,
        "eio_cases": 27,
        "enospc_cases": 27,
        "first_recovery_applied": 77,
        "first_recovery_already_applied": 5,
        "raw_previous_generations": 77,
        "raw_successor_generations": 5,
        "second_recovery_already_applied": 82,
        "strict_verified_cases": 82,
    }
    _require(
        all(
            type(report_input[name]) is int and report_input[name] == expected
            for name, expected in expected_counts.items()
        ),
        "report input accounting changed",
    )
    expected_claims = {
        "host_process_execution": True,
        "host_filesystem_operations": True,
        "workload_execution": False,
        "gpu_execution": False,
        "synthetic_errno": True,
        "physical_storage_fault": False,
        "power_loss_emulated": False,
    }
    _require(
        all(
            type(report_input[name]) is bool and report_input[name] is expected
            for name, expected in expected_claims.items()
        ),
        "report input claim boundary changed",
    )
    records = report_input["records"]
    _require(
        type(records) is list and len(records) == 82,
        "report input record count changed",
    )
    schedule: list[tuple[str, Optional[PublicationPhase]]] = [
        (fault_mode, phase) for fault_mode in FAULT_MODES for phase in PHASES
    ]
    schedule.append((FAULT_NONE, None))
    previous_case_sha256 = ZERO_DIGEST
    expected_final_shape = report_input["canonical_store_after_sha256"]
    expected_final_entry = prepared.fixture.entries[1]["entry_sha256"]
    for ordinal, (record, coordinate) in enumerate(zip(records, schedule)):
        fault_mode, phase = coordinate
        _require(
            type(record) is dict and set(record) == REPORT_INPUT_RECORD_KEYS,
            "report input case schema changed",
        )
        integer_names = (
            "case_ordinal",
            "phase_id",
            "expected_raw_generation",
            "observed_raw_generation",
            "writer_exit_code_bits",
            "writer_termination_signal",
            "known_residue_files",
            "known_residue_bytes",
        )
        string_names = (
            "fault_mode",
            "phase_name",
            "object_kind",
            "operation",
            "first_recovery_disposition",
            "second_recovery_disposition",
        )
        case_digest_names = (
            "raw_shape_sha256",
            "final_shape_sha256",
            "final_manifest_sha256",
            "final_selector_sha256",
            "final_entry_sha256",
            "transaction_sha256",
            "previous_case_sha256",
            "case_sha256",
        )
        _require(
            all(type(record[name]) is int for name in integer_names),
            "report input case integer type changed at ordinal %d" % ordinal,
        )
        _require(
            all(type(record[name]) is str for name in string_names),
            "report input case string type changed at ordinal %d" % ordinal,
        )
        _require(
            all(_is_digest(record[name]) for name in case_digest_names),
            "report input case digest type changed at ordinal %d" % ordinal,
        )
        _require(
            record["case_ordinal"] == ordinal
            and 0 <= record["known_residue_files"] <= STORE_MAX_FILES
            and 0 <= record["known_residue_bytes"] <= STORE_MAX_BYTES,
            "report input case bound changed at ordinal %d" % ordinal,
        )
        if phase is None:
            expected_generation = 2
            expected_phase_values = (
                0,
                "clean-control",
                "transaction",
                "complete",
            )
            expected_exit = 0
            expected_signal = 0
        else:
            expected_generation = expected_raw_generation(
                phase.phase_id,
                fault_mode,
            )
            expected_phase_values = (
                phase.phase_id,
                phase.name,
                phase.object_kind,
                phase.operation,
            )
            expected_exit = (
                U64_MAX if fault_mode == FAULT_SIGKILL else CHILD_INJECTED_ERRNO_EXIT
            )
            expected_signal = int(signal.SIGKILL) if fault_mode == FAULT_SIGKILL else 0
        expected_first_disposition = (
            "applied" if expected_generation == 1 else "already_applied"
        )
        _require(
            record["fault_mode"] == fault_mode
            and (
                record["phase_id"],
                record["phase_name"],
                record["object_kind"],
                record["operation"],
            )
            == expected_phase_values
            and record["expected_raw_generation"] == expected_generation
            and record["observed_raw_generation"] == expected_generation
            and record["writer_exit_code_bits"] == expected_exit
            and record["writer_termination_signal"] == expected_signal
            and record["first_recovery_disposition"] == expected_first_disposition
            and record["second_recovery_disposition"] == "already_applied",
            "report input case schedule or outcome changed",
        )
        _require(
            record["raw_shape_sha256"] != ZERO_DIGEST
            and (
                expected_generation == 1
                or record["raw_shape_sha256"] == expected_final_shape
            )
            and record["final_shape_sha256"] == expected_final_shape
            and record["final_manifest_sha256"] == prepared.successor_manifest_sha256
            and record["final_selector_sha256"] == prepared.successor_selector_sha256
            and record["final_entry_sha256"] == expected_final_entry
            and record["transaction_sha256"] == prepared.transaction_sha256,
            "report input case final identity changed",
        )
        core_record = dict(record)
        case_sha256 = core_record.pop("case_sha256")
        _require(
            record["previous_case_sha256"] == previous_case_sha256
            and case_sha256 == _case_root(core_record),
            "report input case hash chain changed",
        )
        previous_case_sha256 = case_sha256
    _require(
        report_input["final_case_sha256"] == previous_case_sha256,
        "report input final case root changed",
    )
    expected_matrix_sha256 = _hash_parts(
        MATRIX_DOMAIN,
        prepared.fixture.fixture_sha256,
        prepared.transaction_sha256,
        b"".join(record["case_sha256"] for record in records),
    )
    _require(
        report_input["matrix_sha256"] == expected_matrix_sha256,
        "report input matrix root changed",
    )
    root_input = dict(report_input)
    report_input_sha256 = root_input.pop("report_input_sha256")
    _require(
        report_input_sha256
        == _hash_parts(
            REPORT_CHALLENGE_DOMAIN,
            _canonical_record_bytes(root_input),
        ),
        "report input self root changed",
    )
    return report_input


def _campaign_report_cases(
    report_input: Mapping[str, Any],
) -> Sequence[Mapping[str, Any]]:
    records = report_input["records"]
    _require(
        isinstance(records, Sequence)
        and len(records) == 82
        and records[-1]["fault_mode"] == FAULT_NONE,
        "matrix report input lacks its clean control",
    )
    fault_records = records[:-1]
    expected_coordinates = [
        (fault_mode, phase.phase_id) for fault_mode in FAULT_MODES for phase in PHASES
    ]
    _require(
        [(record["fault_mode"], record["phase_id"]) for record in fault_records]
        == expected_coordinates,
        "matrix report input schedule changed",
    )
    return fault_records


def encode_report_v1(
    report_input: Mapping[str, Any],
) -> bytes:
    """Encode structurally validated, self-asserted live-run evidence."""
    verify_report_input_v1(report_input)
    source_snapshot = report_input["source_snapshot"]
    _verify_source_components_unchanged(source_snapshot)
    from bench import native_workload_store_fault_report as report

    _verify_source_components_unchanged(source_snapshot)
    prepared = prepare_publication()
    _verify_source_components_unchanged(source_snapshot)
    fault_records = _campaign_report_cases(report_input)
    schedule_sha256 = _matrix_schedule_sha256()
    source_identities = _report_source_identities(source_snapshot)
    selector_before_wire = prepared.fixture.selector_one
    selector_after_wire = prepared.fixture.selector_two
    selector_before_wire_sha256 = _sha256(selector_before_wire)
    selector_after_wire_sha256 = _sha256(selector_after_wire)
    canonical_before = report_input["canonical_store_before_sha256"]
    canonical_after = report_input["canonical_store_after_sha256"]
    observed_before = sum(
        record["observed_raw_generation"] == 1 for record in fault_records
    )
    observed_after = len(fault_records) - observed_before
    expected_after = sum(
        record["phase_id"] == 27
        or (record["fault_mode"] == FAULT_SIGKILL and record["phase_id"] == 26)
        for record in fault_records
    )
    expected_before = len(fault_records) - expected_after
    header_seed: dict[str, Any] = {
        "abi_version": report.REPORT_ABI,
        "encoded_bytes": report.encoded_report_bytes(len(fault_records)),
        "flags": 0,
        "case_count": len(fault_records),
        "case_bytes": report.CASE_BYTES,
        "selector_bytes": report.SELECTOR_BYTES,
        "generation_before": 1,
        "generation_after": 2,
        "failpoint_count": len(fault_records),
        "errno_case_count": 54,
        "signal_case_count": 27,
        "expected_before_only_count": expected_before,
        "expected_after_only_count": expected_after,
        "expected_either_count": 0,
        "observed_before_count": observed_before,
        "observed_after_count": observed_after,
        "recovered_before_count": 0,
        "recovered_after_count": len(fault_records),
        "synthetic_fault_count": 54,
        "real_signal_count": 27,
        "store_max_bytes": STORE_MAX_BYTES,
        "store_max_files": STORE_MAX_FILES,
        "total_trigger_count": len(fault_records),
        "reserved": 0,
        # This outer matrix root also commits the separately executed clean
        # control, while schedule_sha256 remains the predeclared case order.
        "matrix_challenge_sha256": report_input["matrix_sha256"],
        "schedule_sha256": schedule_sha256,
        "matrix_id_sha256": ZERO_DIGEST,
        "campaign_id_sha256": prepared.fixture.plan["campaign_id_sha256"],
        "plan_sha256": prepared.plan_sha256,
        "manifest_before_sha256": (prepared.previous_manifest_sha256),
        "manifest_after_sha256": (prepared.successor_manifest_sha256),
        "selector_before_wire_sha256": selector_before_wire_sha256,
        "selector_after_wire_sha256": selector_after_wire_sha256,
        "canonical_store_before_sha256": canonical_before,
        "canonical_store_after_sha256": canonical_after,
        "transition_entry_sha256": prepared.fixture.entries[1]["entry_sha256"],
        "worker_sha256": source_identities["worker_sha256"],
        "backend_library_sha256": _hash_parts(
            REPORT_ROLE_DOMAIN,
            b"no-device-backend-library",
        ),
        "campaign_codec_sha256": source_identities["campaign_codec_sha256"],
        "store_adapter_sha256": source_identities["store_adapter_sha256"],
        "fault_injector_sha256": source_identities["fault_injector_sha256"],
        "supervisor_sha256": source_identities["supervisor_sha256"],
        "offline_verifier_sha256": source_identities["offline_verifier_sha256"],
        "machine_sha256": report_input["machine_sha256"],
        "backend_sha256": _hash_parts(
            REPORT_ROLE_DOMAIN,
            b"backend-not-observed",
        ),
        "device_sha256": _hash_parts(
            REPORT_ROLE_DOMAIN,
            b"device-not-observed",
        ),
        "placement_sha256": _hash_parts(
            REPORT_ROLE_DOMAIN,
            b"placement-not-observed",
        ),
        "filesystem_profile_sha256": report_input["filesystem_profile_sha256"],
    }
    _verify_source_components_unchanged(source_snapshot)
    header = report.seal_header(
        header_seed,
        selector_before_wire,
        selector_after_wire,
    )
    _verify_source_components_unchanged(source_snapshot)
    cases: list[dict[str, Any]] = []
    previous_case = ZERO_DIGEST
    clean_control_sha256 = report_input["records"][-1]["case_sha256"]
    for ordinal, record in enumerate(fault_records):
        _verify_source_components_unchanged(source_snapshot)
        phase = PHASE_BY_ID[record["phase_id"]]
        (
            object_kind,
            operation_kind,
            occurrence,
            requested,
        ) = _report_phase_values(report, prepared, phase)
        signal_fault = record["fault_mode"] == FAULT_SIGKILL
        eio_fault = record["fault_mode"] == FAULT_EIO
        expected_mask = (
            report.EXPECTED_AFTER
            if phase.phase_id == 27 or (signal_fault and phase.phase_id == 26)
            else report.EXPECTED_BEFORE
        )
        observed_state = (
            report.SELECTOR_STATE_BEFORE
            if record["observed_raw_generation"] == 1
            else report.SELECTOR_STATE_AFTER
        )
        if observed_state == report.SELECTOR_STATE_AFTER:
            _require(
                record["raw_shape_sha256"] == canonical_after,
                "selected successor was not a canonical raw store",
            )
            disposition = report.RECOVERY_UNCHANGED_AFTER
        else:
            disposition = report.RECOVERY_CLEANED_TO_AFTER
        case_seed: dict[str, Any] = {
            "abi_version": report.CASE_ABI,
            "encoded_bytes": report.CASE_BYTES,
            "flags": 0,
            "ordinal": ordinal,
            "object_kind": object_kind,
            "operation_kind": operation_kind,
            "timing": (report.TIMING_AFTER if signal_fault else report.TIMING_BEFORE),
            "occurrence": occurrence,
            "fault_kind": (
                report.FAULT_FORCED_SIGNAL
                if signal_fault
                else report.FAULT_INJECTED_ERRNO
            ),
            "error_class": (
                report.ERROR_NONE
                if signal_fault
                else report.ERROR_IO
                if eio_fault
                else report.ERROR_STORAGE_FULL
            ),
            "native_error_domain": (
                report.ERROR_DOMAIN_NONE
                if signal_fault
                else report.ERROR_DOMAIN_POSIX_ERRNO
            ),
            "native_error_code": (
                0 if signal_fault else errno.EIO if eio_fault else errno.ENOSPC
            ),
            "injected_signal": signal.SIGKILL if signal_fault else 0,
            "bytes_requested": 0 if signal_fault else requested,
            "bytes_completed": 0,
            "child_exit_code_bits": record["writer_exit_code_bits"],
            "child_termination_signal": record["writer_termination_signal"],
            "provenance_bits": (
                report.SIGNAL_PROVENANCE_BITS
                if signal_fault
                else report.ERRNO_PROVENANCE_BITS
            ),
            "expected_state_mask": expected_mask,
            "observed_selector_state": observed_state,
            "recovered_selector_state": report.SELECTOR_STATE_AFTER,
            "recovery_disposition": disposition,
            "trigger_count": 1,
            "reserved": 0,
            "case_challenge_sha256": _hash_parts(
                REPORT_CASE_CHALLENGE_DOMAIN,
                report_input["matrix_sha256"],
                _u64(ordinal),
                record["fault_mode"].encode("ascii"),
                _u64(phase.phase_id),
            ),
            "failpoint_sha256": ZERO_DIGEST,
            "observed_selector_wire_sha256": (
                selector_before_wire_sha256
                if observed_state == report.SELECTOR_STATE_BEFORE
                else selector_after_wire_sha256
            ),
            "raw_store_snapshot_sha256": record["raw_shape_sha256"],
            "recovered_selector_wire_sha256": (selector_after_wire_sha256),
            "recovered_store_snapshot_sha256": canonical_after,
            "fault_control_receipt_sha256": _hash_parts(
                REPORT_CONTROL_RECEIPT_DOMAIN,
                _canonical_record_bytes(record),
            ),
            "recovery_result_sha256": _hash_parts(
                REPORT_RECOVERY_RESULT_DOMAIN,
                _canonical_record_bytes(record),
                clean_control_sha256,
            ),
            "previous_case_sha256": previous_case,
            "case_sha256": ZERO_DIGEST,
        }
        sealed = report.seal_case(header, case_seed)
        cases.append(sealed)
        previous_case = sealed["case_sha256"]
        _verify_source_components_unchanged(source_snapshot)
    _verify_source_components_unchanged(source_snapshot)
    encoded = report.make_report(
        header,
        selector_before_wire,
        selector_after_wire,
        cases,
    )
    _verify_source_components_unchanged(source_snapshot)
    verify_campaign_report_v1(encoded)
    _verify_source_components_unchanged(source_snapshot)
    return encoded


def verify_campaign_report_v1(encoded: bytes) -> Mapping[str, Any]:
    """Verify both the generic wire and this campaign's exact 81-case order."""
    from bench import native_workload_store_fault_report as report

    decoded = report.verify_report(encoded)
    header = decoded["header"]
    prepared = prepare_publication()
    _require(
        header["generation_before"] == 1
        and header["generation_after"] == 2
        and header["case_count"] == 81
        and header["errno_case_count"] == 54
        and header["signal_case_count"] == 27
        and header["expected_before_only_count"] == 77
        and header["expected_after_only_count"] == 4
        and header["expected_either_count"] == 0
        and header["observed_before_count"] == 77
        and header["observed_after_count"] == 4
        and header["recovered_after_count"] == 81
        and header["store_max_bytes"] == STORE_MAX_BYTES
        and header["store_max_files"] == STORE_MAX_FILES
        and header["schedule_sha256"] == _matrix_schedule_sha256(),
        "store-fault report header is not the fixed campaign",
    )
    _require(
        decoded["selector_before_wire"] == prepared.fixture.selector_one
        and decoded["selector_after_wire"] == prepared.fixture.selector_two
        and header["campaign_id_sha256"] == prepared.fixture.plan["campaign_id_sha256"]
        and header["plan_sha256"] == prepared.plan_sha256,
        "store-fault report prepared transition changed",
    )
    expected_coordinates = [
        (fault_mode, phase) for fault_mode in FAULT_MODES for phase in PHASES
    ]
    for ordinal, (fault_case, (fault_mode, phase)) in enumerate(
        zip(decoded["cases"], expected_coordinates)
    ):
        (
            object_kind,
            operation_kind,
            occurrence,
            _requested,
        ) = _report_phase_values(report, prepared, phase)
        signal_fault = fault_mode == FAULT_SIGKILL
        eio_fault = fault_mode == FAULT_EIO
        expected_generation = expected_raw_generation(
            phase.phase_id,
            fault_mode,
        )
        expected_case_challenge = _hash_parts(
            REPORT_CASE_CHALLENGE_DOMAIN,
            header["matrix_challenge_sha256"],
            _u64(ordinal),
            fault_mode.encode("ascii"),
            _u64(phase.phase_id),
        )
        _require(
            fault_case["case_challenge_sha256"] == expected_case_challenge,
            "store-fault report case challenge changed",
        )
        _require(
            fault_case["object_kind"] == object_kind
            and fault_case["operation_kind"] == operation_kind
            and fault_case["occurrence"] == occurrence
            and fault_case["timing"]
            == (report.TIMING_AFTER if signal_fault else report.TIMING_BEFORE)
            and fault_case["fault_kind"]
            == (
                report.FAULT_FORCED_SIGNAL
                if signal_fault
                else report.FAULT_INJECTED_ERRNO
            )
            and fault_case["native_error_code"]
            == (0 if signal_fault else errno.EIO if eio_fault else errno.ENOSPC)
            and fault_case["bytes_requested"] == (0 if signal_fault else _requested)
            and fault_case["observed_selector_state"]
            == (
                report.SELECTOR_STATE_BEFORE
                if expected_generation == 1
                else report.SELECTOR_STATE_AFTER
            ),
            "store-fault report case schedule changed",
        )
    return decoded


def _child_write(root: str, phase_id: int, fault_mode: str) -> int:
    from bench import native_metal_soak_report as production_store

    prepared = prepare_publication()
    fault = FaultController(phase_id, fault_mode)
    store: Optional[production_store.CampaignStore] = None
    try:
        store = production_store.CampaignStore.open_prepared(
            root,
            expected_active_selector=prepared.fixture.selector_one,
            expected_objects=_expected_object_sets(
                prepared,
                generation=1,
            ),
            io_hook=fault.store_hook,
        )
        environment_value = json.loads(
            prepared.fixture.environment_after.decode("ascii")
        )
        _require(
            store.write_environment(environment_value)
            == prepared.fixture.environment_after_sha256,
            "production store environment root changed",
        )
        _require(
            store.write_segment(prepared.fixture.report_two)
            == _sha256(prepared.fixture.report_two),
            "production store segment root changed",
        )
        manifest_wire, selector_wire = store.publish(
            prepared.fixture.plan,
            prepared.fixture.entries,
            prepared.fixture.environment_root_two_sha256,
        )
        _require(
            manifest_wire == prepared.fixture.manifest_two
            and selector_wire == prepared.fixture.selector_two,
            "production store publication changed",
        )
        fault.require_triggered()
        store.close()
        store = None
        result = verify_store(root, prepared, generation=2)
    except InjectedStoreFault as error:
        expected_errno = (
            errno.EIO
            if fault_mode == FAULT_EIO
            else errno.ENOSPC
            if fault_mode == FAULT_ENOSPC
            else 0
        )
        if (
            error.errno != expected_errno
            or error.phase_id != phase_id
            or not fault.triggered
        ):
            return CHILD_PROTOCOL_EXIT
        print(
            json.dumps(
                {
                    "errno": error.errno,
                    "phase_id": error.phase_id,
                    "schema": ("glacier.native-workload-store-fault/injected-v1"),
                    "verified": True,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return CHILD_INJECTED_ERRNO_EXIT
    finally:
        if store is not None:
            store.close()
    if fault_mode != FAULT_NONE:
        return CHILD_UNEXPECTED_SUCCESS_EXIT
    print(
        json.dumps(
            {
                "schema": "glacier.native-workload-store-fault/writer-v1",
                "selected_generation": result["selected_generation"],
                "shape_sha256": result["shape_sha256"].hex(),
                "transaction_sha256": prepared.transaction_sha256.hex(),
                "verified": True,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def _child_recover(root: str) -> int:
    result = recover_store(root)
    print(
        json.dumps(
            {
                "schema": "glacier.native-workload-store-fault/recovery-v1",
                **_jsonable(result),
                "verified": True,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def _child_verify(root: str) -> int:
    result = verify_store(root, generation=2)
    print(
        json.dumps(
            {
                "schema": "glacier.native-workload-store-fault/strict-v1",
                **_jsonable(result),
                "verified": True,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def _write_report_atomic(path: Path, encoded: bytes) -> None:
    _require(path.name not in ("", ".", ".."), "invalid report path")
    parent = path.parent
    _require(
        parent.is_dir() and not parent.is_symlink(),
        "report parent is not a real directory",
    )
    if os.path.lexists(path):
        info = path.lstat()
        _require(
            stat.S_ISREG(info.st_mode) and not path.is_symlink(),
            "report output is not a regular file",
        )
    temporary = parent / (".%s.prepared-v1.tmp" % path.name)
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        FILE_MODE,
    )
    try:
        try:
            os.fchmod(descriptor, FILE_MODE)
            _write_all(descriptor, encoded)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)
        directory = os.open(parent, _directory_flags())
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()
        raise


def _stable_file_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        stat.S_IFMT(info.st_mode),
        stat.S_IMODE(info.st_mode),
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _read_bounded_regular_file(
    path: Path,
    *,
    minimum_bytes: int,
    maximum_bytes: int,
) -> bytes:
    """Read one bounded regular file through one stable no-follow descriptor."""
    _require(
        path.name not in ("", ".", "..") and 0 <= minimum_bytes <= maximum_bytes,
        "invalid bounded-file request",
    )
    _require(
        getattr(os, "O_NOFOLLOW", 0) != 0,
        "platform lacks no-follow file opens",
    )
    parent_fd = os.open(path.parent, _directory_flags())
    descriptor = -1
    try:
        descriptor = os.open(
            path.name,
            _regular_read_flags(),
            dir_fd=parent_fd,
        )
        before = os.fstat(descriptor)
        _require(
            stat.S_ISREG(before.st_mode)
            and minimum_bytes <= before.st_size <= maximum_bytes,
            "report input is not a bounded regular file",
        )
        namespace_before = os.stat(
            path.name,
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
        _require(
            _stable_file_identity(namespace_before) == _stable_file_identity(before),
            "report input namespace changed before reading",
        )
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            _require(chunk != b"", "report input was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        _require(
            os.read(descriptor, 1) == b"",
            "report input grew while reading",
        )
        after = os.fstat(descriptor)
        namespace_after = os.stat(
            path.name,
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
        _require(
            _stable_file_identity(before) == _stable_file_identity(after),
            "report input changed while reading",
        )
        _require(
            _stable_file_identity(namespace_after) == _stable_file_identity(after),
            "report input namespace changed while reading",
        )
        return b"".join(chunks)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)


def _read_report_file(path: Path) -> bytes:
    from bench import native_workload_store_fault_report as report

    return _read_bounded_regular_file(
        path,
        minimum_bytes=report.FIXED_BYTES + report.CASE_BYTES,
        maximum_bytes=(report.FIXED_BYTES + report.MAX_CASES * report.CASE_BYTES),
    )


def _report_receipt_from_encoded(encoded: bytes) -> dict[str, Any]:
    decoded = verify_campaign_report_v1(encoded)
    header = decoded["header"]
    return {
        "schema": "glacier.native-workload-store-fault/report-verifier-v1",
        "case_count": header["case_count"],
        "encoded_bytes": len(encoded),
        "encoded_sha256": _sha256(encoded).hex(),
        "generation_before": header["generation_before"],
        "generation_after": header["generation_after"],
        "matrix_challenge_sha256": header["matrix_challenge_sha256"].hex(),
        "matrix_id_sha256": header["matrix_id_sha256"].hex(),
        "report_sha256": decoded["report_sha256"].hex(),
        "verified": True,
    }


def _child_verify_report(path: str) -> int:
    report_path = Path(path)
    encoded = _read_report_file(report_path)
    print(
        json.dumps(
            _report_receipt_from_encoded(encoded),
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def _parse_zig_report_receipt(
    result: subprocess.CompletedProcess[str],
) -> dict[str, Any]:
    _require(
        result.returncode == 0 and result.stderr == "",
        "fresh Zig report verifier rejected the report",
    )
    lines = result.stdout.splitlines()
    _require(
        len(lines) == 1 and result.stdout.endswith("\n"),
        "fresh Zig report verifier receipt is not one record",
    )
    fields = lines[0].split(" ")
    _require(
        len(fields) == 4
        and fields[0] == "verified=true"
        and fields[1].startswith("cases=")
        and fields[2].startswith("generation=")
        and fields[3].startswith("report_sha256="),
        "fresh Zig report verifier receipt schema changed",
    )
    case_text = fields[1].removeprefix("cases=")
    generation_text = fields[2].removeprefix("generation=")
    generation_parts = generation_text.split("->")
    report_sha256 = fields[3].removeprefix("report_sha256=")
    _require(
        case_text.isascii()
        and case_text.isdigit()
        and str(int(case_text)) == case_text
        and len(generation_parts) == 2
        and all(
            part.isascii() and part.isdigit() and str(int(part)) == part
            for part in generation_parts
        )
        and len(report_sha256) == 64
        and all(character in "0123456789abcdef" for character in report_sha256),
        "fresh Zig report verifier receipt value changed",
    )
    return {
        "case_count": int(case_text),
        "generation_before": int(generation_parts[0]),
        "generation_after": int(generation_parts[1]),
        "report_sha256": report_sha256,
    }


def _verify_report_fresh(
    path: Path,
    zig_verifier: Optional[str],
    *,
    expected_encoded: bytes,
    expected_matrix_challenge_sha256: bytes,
    expected_case_count: int,
    expected_source_snapshot: Mapping[str, bytes],
) -> dict[str, Any]:
    _verify_source_components_unchanged(expected_source_snapshot)
    expected = _report_receipt_from_encoded(expected_encoded)
    _verify_source_components_unchanged(expected_source_snapshot)
    _require(
        expected["matrix_challenge_sha256"] == expected_matrix_challenge_sha256.hex()
        and expected["case_count"] == expected_case_count,
        "encoded report does not belong to the completed matrix",
    )
    _verify_source_components_unchanged(expected_source_snapshot)
    _require(
        _read_report_file(path) == expected_encoded,
        "current report file does not match the encoded report",
    )
    _verify_source_components_unchanged(expected_source_snapshot)
    python_result = _run_child(_module_command("_child-verify-report", str(path)))
    _verify_source_components_unchanged(expected_source_snapshot)
    receipt = _parse_child_result(
        python_result,
        ("glacier.native-workload-store-fault/report-verifier-v1"),
    )
    _require(
        receipt == expected,
        "fresh Python report verifier receipt does not match the encoded report",
    )
    if zig_verifier is not None:
        _verify_source_components_unchanged(expected_source_snapshot)
        zig_result = _run_child((zig_verifier, str(path)))
        _verify_source_components_unchanged(expected_source_snapshot)
        zig_receipt = _parse_zig_report_receipt(zig_result)
        _require(
            zig_receipt["case_count"] == expected["case_count"]
            and zig_receipt["generation_before"] == expected["generation_before"]
            and zig_receipt["generation_after"] == expected["generation_after"]
            and zig_receipt["report_sha256"] == expected["report_sha256"],
            "fresh Zig report verifier receipt does not match the encoded report",
        )
    _verify_source_components_unchanged(expected_source_snapshot)
    _require(
        _read_report_file(path) == expected_encoded,
        "current report file changed during fresh verification",
    )
    _verify_source_components_unchanged(expected_source_snapshot)
    return receipt


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run the deterministic native-workload durable-publication "
            "fault campaign; this is POSIX filesystem evidence, not GPU or "
            "physical-storage-fault evidence"
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run-matrix")
    run_parser.add_argument("--work-root")
    run_parser.add_argument("--retain-cases", action="store_true")
    run_parser.add_argument("--output")
    run_parser.add_argument("--zig-verifier")

    child_write = subparsers.add_parser("_child-write")
    child_write.add_argument("root")
    child_write.add_argument("phase_id", type=int)
    child_write.add_argument(
        "fault_mode",
        choices=(FAULT_NONE,) + FAULT_MODES,
    )
    child_recover = subparsers.add_parser("_child-recover")
    child_recover.add_argument("root")
    child_verify = subparsers.add_parser("_child-verify")
    child_verify.add_argument("root")
    child_verify_report = subparsers.add_parser("_child-verify-report")
    child_verify_report.add_argument("path")

    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "_child-write":
            return _child_write(
                arguments.root,
                arguments.phase_id,
                arguments.fault_mode,
            )
        if arguments.command == "_child-recover":
            return _child_recover(arguments.root)
        if arguments.command == "_child-verify":
            return _child_verify(arguments.root)
        if arguments.command == "_child-verify-report":
            return _child_verify_report(arguments.path)
        result = run_matrix(
            arguments.work_root,
            retain_cases=arguments.retain_cases,
        )
        encoded_report = encode_report_v1(result)
        retained_output = (
            Path(arguments.output).absolute() if arguments.output is not None else None
        )
        temporary_report: Optional[tempfile.TemporaryDirectory[str]] = None
        if retained_output is None:
            temporary_report = tempfile.TemporaryDirectory(
                prefix="glacier-store-fault-report-"
            )
            report_path = Path(temporary_report.name) / "report.bin"
        else:
            report_path = retained_output
        try:
            _verify_source_components_unchanged(result["source_snapshot"])
            _write_report_atomic(report_path, encoded_report)
            _verify_source_components_unchanged(result["source_snapshot"])
            report_receipt = _verify_report_fresh(
                report_path,
                arguments.zig_verifier,
                expected_encoded=encoded_report,
                expected_matrix_challenge_sha256=result["matrix_sha256"],
                expected_case_count=result["fault_cases"],
                expected_source_snapshot=result["source_snapshot"],
            )
            _verify_source_components_unchanged(result["source_snapshot"])
        finally:
            if temporary_report is not None:
                temporary_report.cleanup()
        _verify_source_components_unchanged(result["source_snapshot"])
        print(
            json.dumps(
                {
                    "schema": ("glacier.native-workload-store-fault/matrix-v1"),
                    "fault_cases": result["fault_cases"],
                    "clean_controls": result["clean_controls"],
                    "sigkill_cases": result["sigkill_cases"],
                    "eio_cases": result["eio_cases"],
                    "enospc_cases": result["enospc_cases"],
                    "first_recovery_applied": result["first_recovery_applied"],
                    "first_recovery_already_applied": result[
                        "first_recovery_already_applied"
                    ],
                    "second_recovery_already_applied": result[
                        "second_recovery_already_applied"
                    ],
                    "strict_verified_cases": result["strict_verified_cases"],
                    "report_case_count": report_receipt["case_count"],
                    "encoded_bytes": report_receipt["encoded_bytes"],
                    "encoded_sha256": report_receipt["encoded_sha256"],
                    "report_sha256": report_receipt["report_sha256"],
                    "source_snapshot_sha256": result["source_snapshot_sha256"].hex(),
                    "matrix_sha256": result["matrix_sha256"].hex(),
                    "report_input_sha256": result["report_input_sha256"].hex(),
                    "host_process_execution": True,
                    "host_filesystem_operations": True,
                    "workload_execution": False,
                    "gpu_execution": False,
                    "synthetic_errno": True,
                    "physical_storage_fault": False,
                    "power_loss_emulated": False,
                    "verified": True,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 0
    except (
        StoreFaultCampaignError,
        campaign.CampaignManifestError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(_main())
