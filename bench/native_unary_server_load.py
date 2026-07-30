#!/usr/bin/env python3
"""Run and independently verify the bounded F1 native unary load campaign.

The producer emits one fixed binary envelope: transport-correlation sidecars,
an exact terminal closure, and an embedded Native Workload Report V1 wire.
This verifier checks both layers and samples the host at the campaign
boundaries.  It never relabels HTTP first-byte latency as first-token latency,
and it makes no GPU, physical-parallelism, fairness, or foreign-OS claim.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import secrets
import selectors
import signal
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any, Mapping, Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bench import lane4_evidence
from bench import native_environment_admission
from bench import native_observer
from bench import native_observer_linux
from bench import native_workload_report
from bench import native_unary_server_load_publication as publication


MAGIC = b"GF1LOAD1"
OUTER_ABI = 0x4746314C00000001
RETENTION_CAPACITY_MAGIC = b"GF1CAP01"
RETENTION_CAPACITY_OUTER_ABI = 0x4746314300000001
QUEUED_RECEIVE_TIMEOUT_MAGIC = b"GF1QRT01"
QUEUED_RECEIVE_TIMEOUT_OUTER_ABI = 0x4746315100000001
OPEN_LOOP_TRANSIENT_PRESSURE_MAGIC = b"GF1OLP01"
OPEN_LOOP_TRANSIENT_PRESSURE_OUTER_ABI = 0x4746314F00000001
HEADER_BYTES = 40
SIDECAR_BYTES = 296
CLOSURE_U64_COUNT = 28
CLOSURE_BYTES = CLOSURE_U64_COUNT * 8
OUTER_DIGEST_BYTES = 64
RECORD_COUNT = 72
WARMUP_COUNT = 8
MEASURED_COUNT = 64
FLOW_COUNT = 8
WORKER_COUNT = 2
PENDING_CAPACITY = 8
QUEUE_COUNT = WORKER_COUNT + PENDING_CAPACITY
INNER_BYTES = (
    native_workload_report.MINIMUM_ENCODED_BYTES
    + RECORD_COUNT * native_workload_report.RECORD_WIRE_BYTES
)
OUTER_BYTES = (
    HEADER_BYTES
    + RECORD_COUNT * SIDECAR_BYTES
    + CLOSURE_BYTES
    + INNER_BYTES
    + OUTER_DIGEST_BYTES
)
OPEN_LOOP_SCHEDULE_STRUCT = struct.Struct("<IBBHQQQ")
OPEN_LOOP_SCHEDULE_BYTES = OPEN_LOOP_SCHEDULE_STRUCT.size
OPEN_LOOP_SIDECAR_BYTES = SIDECAR_BYTES + OPEN_LOOP_SCHEDULE_BYTES
OPEN_LOOP_CLOSURE_U64_COUNT = 44
OPEN_LOOP_CLOSURE_BYTES = OPEN_LOOP_CLOSURE_U64_COUNT * 8
OPEN_LOOP_OUTER_BYTES = (
    HEADER_BYTES
    + RECORD_COUNT * OPEN_LOOP_SIDECAR_BYTES
    + OPEN_LOOP_CLOSURE_BYTES
    + INNER_BYTES
    + OUTER_DIGEST_BYTES
)
MAX_RUNNER_STDERR_BYTES = 64 * 1024
RUNNER_TIMEOUT_SECONDS = 120.0
PUBLISHABLE_EXTERNAL_CPU_PPM = 200_000
MAX_EXTERNAL_CPU_PPM = 500_000
MAX_EXTERNAL_CPU_DRIFT_PPM = 150_000
MAX_BOUNDARY_CPU_DRIFT_PPM = 300_000
PUBLICATION_CONTEXT_SCHEMA = (
    "glacier.native-unary-server-load-publication-context/v1"
)
PUBLICATION_ELIGIBILITY_POLICY = (
    "glacier.native-unary-server-load-publication-eligibility/v1"
)
PRE_ENVIRONMENT_DOMAIN = (
    b"glacier-native-unary-load-pre-environment-v1\x00"
)
POST_ENVIRONMENT_DOMAIN = (
    b"glacier-native-unary-load-post-environment-v1\x00"
)
LINUX_ATTRIBUTION_UNAVAILABLE = (
    "linux_external_cpu_attribution_unavailable"
)
DARWIN_PRE_EXTERNAL_CPU_ABOVE_BOUND = (
    "darwin_pre_run_external_cpu_above_publishable_bound"
)
DARWIN_POST_EXTERNAL_CPU_ABOVE_BOUND = (
    "darwin_post_run_external_cpu_above_publishable_bound"
)
DARWIN_ADMISSION_FIELDS = {
    "schema",
    "captured_at_utc",
    "host",
    "power_source",
    "battery_state",
    "thermal_state",
    "foundation_thermal_state",
    "low_power_mode_enabled",
    "cpu_speed_limit_percent",
    "scheduler_limit_percent",
    "available_cpus",
    "raw_pmset_battery_sha256",
    "raw_pmset_thermal_sha256",
    "raw_foundation_process_info_sha256",
    "foundation_probe_source_sha256",
    "foundation_probe_runner_sha256",
    "measurement_admitted",
    "reasons",
    "claim_scope",
    "performance_claim",
    "promotion_decision",
    "measurements_publishable",
}

BODY_DOMAIN = b"glacier-f1-native-unary-load-body-v1\x00"
FOOTER_DOMAIN = b"glacier-f1-native-unary-load-footer-v1\x00"
RETENTION_CAPACITY_BODY_DOMAIN = (
    b"glacier-f1-native-unary-retention-capacity-body-v1\x00"
)
RETENTION_CAPACITY_FOOTER_DOMAIN = (
    b"glacier-f1-native-unary-retention-capacity-footer-v1\x00"
)
QUEUED_RECEIVE_TIMEOUT_BODY_DOMAIN = (
    b"glacier-f1-native-unary-queued-receive-timeout-body-v1\x00"
)
QUEUED_RECEIVE_TIMEOUT_FOOTER_DOMAIN = (
    b"glacier-f1-native-unary-queued-receive-timeout-footer-v1\x00"
)
OPEN_LOOP_TRANSIENT_PRESSURE_BODY_DOMAIN = (
    b"glacier-f1-native-unary-open-loop-transient-pressure-body-v1\x00"
)
OPEN_LOOP_TRANSIENT_PRESSURE_FOOTER_DOMAIN = (
    b"glacier-f1-native-unary-open-loop-transient-pressure-footer-v1\x00"
)
PIN_DOMAIN = b"glacier-f1-native-unary-load-pin-v1\x00"
DISPATCH_DOMAIN = b"glacier-f1-native-unary-load-dispatch-v1\x00"
SUBMISSION_DOMAIN = b"glacier-f1-native-unary-load-submission-v1\x00"
ORACLE_DOMAIN = b"glacier-f1-native-unary-load-oracle-v1\x00"
# Producer-side ABI identity only: the offline verifier does not retain the
# raw HTTP bytes needed to recompute this opaque digest.
RETENTION_CAPACITY_RESPONSE_EVIDENCE_DOMAIN = (
    b"glacier-f1-native-unary-retention-capacity-http-response-v1\x00"
)
RETENTION_CAPACITY_RESPONSE_SEMANTICS_DOMAIN = (
    b"glacier-f1-native-unary-retention-capacity-http-semantics-v1\x00"
)
RETENTION_CAPACITY_TERMINAL_DOMAIN = (
    b"glacier-f1-native-unary-retention-capacity-terminal-v1\x00"
)
RETENTION_CAPACITY_COMPLETION_DOMAIN = (
    b"glacier-f1-native-unary-retention-capacity-completion-v1\x00"
)
QUEUED_RECEIVE_TIMEOUT_HTTP_REQUEST_DOMAIN = (
    b"glacier-f1-native-unary-queued-receive-timeout-http-request-v1\x00"
)
QUEUED_RECEIVE_TIMEOUT_TRANSPORT_SEMANTICS_DOMAIN = (
    b"glacier-f1-native-unary-queued-receive-timeout-transport-semantics-v1\x00"
)
QUEUED_RECEIVE_TIMEOUT_TERMINAL_DOMAIN = (
    b"glacier-f1-native-unary-queued-receive-timeout-terminal-v1\x00"
)
QUEUED_RECEIVE_TIMEOUT_COMPLETION_DOMAIN = (
    b"glacier-f1-native-unary-queued-receive-timeout-completion-v1\x00"
)

WORKLOAD_ID = b"glacier-f1-native-unary-load-workload/v1"
PROFILE_ID = (
    b"glacier-f1-native-unary-load-profile/"
    b"8-warmup-64-measured-8-flow-2-worker/v1"
)
RETENTION_CAPACITY_PROFILE_ID = (
    b"glacier-f1-native-unary-load-profile/"
    b"retention-capacity-8-warmup-32-completed-32-rejected-"
    b"8-flow-2-worker-40-record/v1"
)
QUEUED_RECEIVE_TIMEOUT_PROFILE_ID = (
    b"glacier-f1-native-unary-load-profile/"
    b"queued-receive-timeout-8-warmup-16-completed-48-timed-out-"
    b"8-flow-2-worker-6-pending-2000000000ns-timeout-"
    b"4000000000ns-observation-cap-3000000000ns-queue-cap-"
    b"1000000000ns-settlement-cap/v1"
)
OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_ID = (
    b"glacier-f1-native-unary-load-profile/"
    b"open-loop-transient-pressure-8-warmup-16-baseline-32-pressure-"
    b"16-recovery-8-flow-2-worker-8-pending-128-backlog-"
    b"25000000ns-baseline-step-500000000ns-gate-arm-"
    b"600000000ns-pressure-start-5000000ns-pressure-step-"
    b"1000000000ns-fixed-release-1800000000ns-recovery-start-"
    b"25000000ns-recovery-step-100000000ns-lateness-cap-"
    b"100000000ns-recovery-slack/v1"
)
BACKEND_ID = b"glacier-prepared-text-unary-cpu-backend/v1"
DEVICE_ID = b"host-cpu-device-physical-metrics-unavailable/v1"
PLACEMENT_ID = b"managed-concurrent-loopback-2-worker-8-pending/v1"
QUEUED_RECEIVE_TIMEOUT_PLACEMENT_ID = (
    b"managed-concurrent-loopback-2-worker-6-pending/v1"
)
OPEN_LOOP_TRANSIENT_PRESSURE_PLACEMENT_ID = (
    b"managed-concurrent-loopback-2-worker-8-pending-128-backlog/v1"
)
HOST_SOURCE_ID = b"f1-native-load-parent-child-observers/v1"
DEVICE_SOURCE_ID = b"f1-native-load-device-observer-unsupported/v1"
DEVICE_CLOCK_ID = b"f1-native-load-device-clock-unsupported/v1"
PROCESS_GENERATION = 0x4753505200000116
RETENTION_CAPACITY_PROCESS_GENERATION = 0x4753505200000117
QUEUED_RECEIVE_TIMEOUT_PROCESS_GENERATION = 0x4753505200000118
OPEN_LOOP_TRANSIENT_PRESSURE_PROCESS_GENERATION = 0x4753505200000119
ZERO_DIGEST = b"\x00" * 32
NO_QUEUE_SLOT = (1 << 32) - 1
OUTCOME_COMPLETED = 0
OUTCOME_CAPACITY_REJECTED = 1
OUTCOME_TIMED_OUT = 4
CAPACITY_REJECTED_PRESENCE = 0x61
SUCCESSFUL_PROFILE_NAME = "successful-v1"
RETENTION_CAPACITY_PROFILE_NAME = "retention-capacity-v1"
QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME = "queued-receive-timeout-v1"
OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME = (
    "open-loop-transient-pressure-v1"
)
RETENTION_CAPACITY_COMPLETED_RECORDS = 40
RETENTION_CAPACITY_MEASURED_COMPLETED = 32
RETENTION_CAPACITY_MEASURED_REJECTED = 32
RETENTION_CAPACITY_ERROR_CODE = 11
RETENTION_CAPACITY_RETRY_DISPOSITION = 1
RETENTION_CAPACITY_HTTP_STATUS = 429
QUEUED_RECEIVE_TIMEOUT_MEASURED_COMPLETED = 16
QUEUED_RECEIVE_TIMEOUT_MEASURED_TIMED_OUT = 48
QUEUED_RECEIVE_TIMEOUT_SERVICE_COMPLETED_RECORDS = 24
QUEUED_RECEIVE_TIMEOUT_WORKER_COUNT = 2
QUEUED_RECEIVE_TIMEOUT_PENDING_CAPACITY = 6
QUEUED_RECEIVE_TIMEOUT_QUEUE_COUNT = 8
QUEUED_RECEIVE_TIMEOUT_MAX_IN_FLIGHT = 8
QUEUED_RECEIVE_TIMEOUT_NS = 2_000_000_000
QUEUED_RECEIVE_TIMEOUT_MAX_TERMINAL_NS = 4_000_000_000
QUEUED_RECEIVE_TIMEOUT_MAX_QUEUE_RESIDENCE_NS = 3_000_000_000
QUEUED_RECEIVE_TIMEOUT_MAX_SETTLEMENT_PROPAGATION_NS = 1_000_000_000
QUEUED_RECEIVE_TIMEOUT_EVENT_KIND = 6
QUEUED_RECEIVE_TIMEOUT_PHASE = 8
OPEN_LOOP_PHASE_WARMUP = 0
OPEN_LOOP_PHASE_BASELINE = 1
OPEN_LOOP_PHASE_PRESSURE = 2
OPEN_LOOP_PHASE_RECOVERY = 3
OPEN_LOOP_SCHEDULE_FLAG_MEASURED = 1
OPEN_LOOP_BASELINE_COUNT = 16
OPEN_LOOP_PRESSURE_COUNT = 32
OPEN_LOOP_RECOVERY_COUNT = 16
OPEN_LOOP_BASELINE_START = WARMUP_COUNT
OPEN_LOOP_PRESSURE_START = (
    OPEN_LOOP_BASELINE_START + OPEN_LOOP_BASELINE_COUNT
)
OPEN_LOOP_RECOVERY_START = (
    OPEN_LOOP_PRESSURE_START + OPEN_LOOP_PRESSURE_COUNT
)
OPEN_LOOP_BASELINE_STEP_NS = 25_000_000
OPEN_LOOP_PRESSURE_START_OFFSET_NS = 600_000_000
OPEN_LOOP_PRESSURE_STEP_NS = 5_000_000
OPEN_LOOP_RECOVERY_START_OFFSET_NS = 1_800_000_000
OPEN_LOOP_RECOVERY_STEP_NS = 25_000_000
OPEN_LOOP_GATE_ARM_OFFSET_NS = 500_000_000
OPEN_LOOP_FIXED_RELEASE_OFFSET_NS = 1_000_000_000
OPEN_LOOP_LAUNCH_LATENESS_CAP_NS = 100_000_000
OPEN_LOOP_RECOVERY_SLACK_NS = 100_000_000
OPEN_LOOP_LISTEN_BACKLOG = 128
OPEN_LOOP_LOGICAL_ACTOR_COUNT = MEASURED_COUNT
NO_WORKER_INDEX = (1 << 8) - 1
QUEUED_RECEIVE_TIMEOUT_CLOSURE = (
    72,
    24,
    48,
    72,
    24,
    6,
    2,
    8,
    8,
    0,
    0,
    48,
    0,
    0,
    0,
    0,
    0,
    0,
    24,
    24,
    0,
    0,
    0,
    1,
    1,
    1,
    0,
    184,
)

SIDECAR_STRUCT = struct.Struct(
    "<II11Q4BI32s32s32s32s32s32s"
)
HEADER_STRUCT = struct.Struct("<8sQQIIII")


class VerificationError(ValueError):
    """The native load output or its environment is not admissible."""


@dataclass(frozen=True)
class CampaignProfile:
    name: str
    producer_mode: str
    magic: bytes
    outer_abi: int
    body_domain: bytes
    footer_domain: bytes
    profile_id: bytes
    process_generation: int
    measured_completed: int
    measured_capacity_rejected: int
    measured_timed_out: int
    service_completed_records: int
    max_in_flight: int
    queue_count: int
    worker_count: int
    pending_capacity: int
    placement_id: bytes
    scenario_mode: int = 0
    sidecar_bytes: int = SIDECAR_BYTES
    closure_u64_count: int = CLOSURE_U64_COUNT

    @property
    def connection_capacity(self) -> int:
        return self.worker_count + self.pending_capacity

    @property
    def closure_bytes(self) -> int:
        return self.closure_u64_count * 8

    @property
    def outer_bytes(self) -> int:
        return (
            HEADER_BYTES
            + RECORD_COUNT * self.sidecar_bytes
            + self.closure_bytes
            + INNER_BYTES
            + OUTER_DIGEST_BYTES
        )

    @property
    def has_open_loop_schedule(self) -> bool:
        return self.name == OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME


SUCCESSFUL_PROFILE = CampaignProfile(
    name=SUCCESSFUL_PROFILE_NAME,
    producer_mode="--native-load",
    magic=MAGIC,
    outer_abi=OUTER_ABI,
    body_domain=BODY_DOMAIN,
    footer_domain=FOOTER_DOMAIN,
    profile_id=PROFILE_ID,
    process_generation=PROCESS_GENERATION,
    measured_completed=MEASURED_COUNT,
    measured_capacity_rejected=0,
    measured_timed_out=0,
    service_completed_records=RECORD_COUNT,
    max_in_flight=FLOW_COUNT,
    queue_count=QUEUE_COUNT,
    worker_count=WORKER_COUNT,
    pending_capacity=PENDING_CAPACITY,
    placement_id=PLACEMENT_ID,
)
RETENTION_CAPACITY_PROFILE = CampaignProfile(
    name=RETENTION_CAPACITY_PROFILE_NAME,
    producer_mode="--native-load-retention-capacity",
    magic=RETENTION_CAPACITY_MAGIC,
    outer_abi=RETENTION_CAPACITY_OUTER_ABI,
    body_domain=RETENTION_CAPACITY_BODY_DOMAIN,
    footer_domain=RETENTION_CAPACITY_FOOTER_DOMAIN,
    profile_id=RETENTION_CAPACITY_PROFILE_ID,
    process_generation=RETENTION_CAPACITY_PROCESS_GENERATION,
    measured_completed=RETENTION_CAPACITY_MEASURED_COMPLETED,
    measured_capacity_rejected=RETENTION_CAPACITY_MEASURED_REJECTED,
    measured_timed_out=0,
    service_completed_records=RETENTION_CAPACITY_COMPLETED_RECORDS,
    max_in_flight=FLOW_COUNT,
    queue_count=QUEUE_COUNT,
    worker_count=WORKER_COUNT,
    pending_capacity=PENDING_CAPACITY,
    placement_id=PLACEMENT_ID,
)
QUEUED_RECEIVE_TIMEOUT_PROFILE = CampaignProfile(
    name=QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME,
    producer_mode="--native-load-queued-receive-timeout",
    magic=QUEUED_RECEIVE_TIMEOUT_MAGIC,
    outer_abi=QUEUED_RECEIVE_TIMEOUT_OUTER_ABI,
    body_domain=QUEUED_RECEIVE_TIMEOUT_BODY_DOMAIN,
    footer_domain=QUEUED_RECEIVE_TIMEOUT_FOOTER_DOMAIN,
    profile_id=QUEUED_RECEIVE_TIMEOUT_PROFILE_ID,
    process_generation=QUEUED_RECEIVE_TIMEOUT_PROCESS_GENERATION,
    measured_completed=QUEUED_RECEIVE_TIMEOUT_MEASURED_COMPLETED,
    measured_capacity_rejected=0,
    measured_timed_out=QUEUED_RECEIVE_TIMEOUT_MEASURED_TIMED_OUT,
    service_completed_records=QUEUED_RECEIVE_TIMEOUT_SERVICE_COMPLETED_RECORDS,
    max_in_flight=QUEUED_RECEIVE_TIMEOUT_MAX_IN_FLIGHT,
    queue_count=QUEUED_RECEIVE_TIMEOUT_QUEUE_COUNT,
    worker_count=QUEUED_RECEIVE_TIMEOUT_WORKER_COUNT,
    pending_capacity=QUEUED_RECEIVE_TIMEOUT_PENDING_CAPACITY,
    placement_id=QUEUED_RECEIVE_TIMEOUT_PLACEMENT_ID,
)
OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE = CampaignProfile(
    name=OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME,
    producer_mode="--native-load-open-loop-transient-pressure",
    magic=OPEN_LOOP_TRANSIENT_PRESSURE_MAGIC,
    outer_abi=OPEN_LOOP_TRANSIENT_PRESSURE_OUTER_ABI,
    body_domain=OPEN_LOOP_TRANSIENT_PRESSURE_BODY_DOMAIN,
    footer_domain=OPEN_LOOP_TRANSIENT_PRESSURE_FOOTER_DOMAIN,
    profile_id=OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_ID,
    process_generation=OPEN_LOOP_TRANSIENT_PRESSURE_PROCESS_GENERATION,
    measured_completed=MEASURED_COUNT,
    measured_capacity_rejected=0,
    measured_timed_out=0,
    service_completed_records=RECORD_COUNT,
    max_in_flight=OPEN_LOOP_LOGICAL_ACTOR_COUNT,
    queue_count=OPEN_LOOP_LOGICAL_ACTOR_COUNT,
    worker_count=WORKER_COUNT,
    pending_capacity=PENDING_CAPACITY,
    placement_id=OPEN_LOOP_TRANSIENT_PRESSURE_PLACEMENT_ID,
    scenario_mode=1,
    sidecar_bytes=OPEN_LOOP_SIDECAR_BYTES,
    closure_u64_count=OPEN_LOOP_CLOSURE_U64_COUNT,
)
CAMPAIGN_PROFILES = {
    SUCCESSFUL_PROFILE.name: SUCCESSFUL_PROFILE,
    RETENTION_CAPACITY_PROFILE.name: RETENTION_CAPACITY_PROFILE,
    QUEUED_RECEIVE_TIMEOUT_PROFILE.name: QUEUED_RECEIVE_TIMEOUT_PROFILE,
    OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE.name: (
        OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE
    ),
}


def _campaign_profile(name: str) -> CampaignProfile:
    try:
        return CAMPAIGN_PROFILES[name]
    except KeyError as error:
        raise VerificationError("unsupported native load profile: %s" % name) from error


def _expected_outcome(campaign: CampaignProfile, ordinal: int) -> int:
    _require(0 <= ordinal < RECORD_COUNT, "record ordinal is out of range")
    if campaign.name in {
        SUCCESSFUL_PROFILE_NAME,
        OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME,
    }:
        return OUTCOME_COMPLETED
    if campaign.name == RETENTION_CAPACITY_PROFILE_NAME:
        return (
            OUTCOME_COMPLETED
            if ordinal < campaign.service_completed_records
            else OUTCOME_CAPACITY_REJECTED
        )
    if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        if ordinal < WARMUP_COUNT:
            return OUTCOME_COMPLETED
        epoch_lane = (ordinal - WARMUP_COUNT) % FLOW_COUNT
        return (
            OUTCOME_COMPLETED
            if epoch_lane < 2
            else OUTCOME_TIMED_OUT
        )
    raise VerificationError(
        "unsupported native load outcome profile: %s" % campaign.name
    )


def _expected_flow(campaign: CampaignProfile, ordinal: int) -> int | None:
    if campaign.name != QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        return None
    if ordinal < WARMUP_COUNT:
        return ordinal
    measured_ordinal = ordinal - WARMUP_COUNT
    epoch = measured_ordinal // FLOW_COUNT
    epoch_lane = measured_ordinal % FLOW_COUNT
    return (epoch + epoch_lane) % FLOW_COUNT


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def _u8(value: int) -> bytes:
    return struct.pack("<B", value)


def _u32(value: int) -> bytes:
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def _domain_hash(domain: bytes, payload: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    digest.update(payload)
    return digest.digest()


def _hash_parts(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _identity(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def _host_clock_identity(system: str) -> bytes:
    if system == "Darwin":
        return _identity(b"darwin-clock-uptime-raw/v1")
    if system == "Linux":
        return _identity(b"linux-clock-monotonic-raw/v1")
    return _identity(b"posix-clock-monotonic/v1")


@dataclass(frozen=True)
class OpenLoopSchedule:
    planned_ordinal: int
    phase: int
    flags: int
    reserved: int
    scheduled_offset_ns: int
    launch_lateness_ns: int
    transmit_complete_ns: int


@dataclass(frozen=True)
class Sidecar:
    ordinal: int
    response_bytes: int
    enqueue_ordinal: int
    dispatch_ordinal: int
    retired_ordinal: int
    enqueue_ns: int
    dispatch_ns: int
    published_ns: int
    retired_ns: int
    work_sequence: int
    process_generation: int
    connection_sequence: int
    slot_generation: int
    slot_index: int
    worker_index: int
    content_byte: int
    output_token: int
    request_sha256: bytes
    response_handle_sha256: bytes
    handle_sha256: bytes
    output_sha256: bytes
    terminal_sha256: bytes
    completion_sha256: bytes
    outcome: int = OUTCOME_COMPLETED
    schedule: OpenLoopSchedule | None = None


@dataclass(frozen=True)
class InnerRecord:
    ordinal: int
    cohort: int
    outcome: int
    correctness: int
    fallback: int
    flow_id: int
    work_units: int
    queue_slot: int
    presence_mask: int
    points: tuple[tuple[int, int], ...]
    roots: tuple[bytes, ...]


@dataclass(frozen=True)
class InnerProfile:
    mode: int
    evidence: int
    warmup_count: int
    measured_count: int
    max_in_flight: int
    queue_count: int
    flow_count: int
    identities: tuple[bytes, ...]
    records: tuple[InnerRecord, ...]
    completed_work_units: int
    interval_ns: int
    throughput_numerator: int
    throughput_denominator_ns: int
    admission_sample_count: int
    admission_p99_ns: int
    queue_sample_count: int
    queue_p99_ns: int
    first_byte_sample_count: int
    first_byte_p99_ns: int
    terminal_p99_ns: int


@dataclass(frozen=True)
class VerifiedEnvelope:
    inner_result: native_workload_report.VerificationResult
    profile: InnerProfile
    sidecars: tuple[Sidecar, ...]
    closure: tuple[int, ...]
    outer_sha256: bytes


def _parse_sidecar_exact(
    encoded: bytes,
    offset: int,
    campaign: CampaignProfile = SUCCESSFUL_PROFILE,
) -> Sidecar:
    (
        ordinal,
        response_bytes,
        enqueue_ordinal,
        dispatch_ordinal,
        retired_ordinal,
        enqueue_ns,
        dispatch_ns,
        published_ns,
        retired_ns,
        work_sequence,
        process_generation,
        connection_sequence,
        slot_generation,
        slot_index,
        worker_index,
        content_byte,
        outcome,
        output_token,
        request_sha256,
        response_handle_sha256,
        handle_sha256,
        output_sha256,
        terminal_sha256,
        completion_sha256,
    ) = SIDECAR_STRUCT.unpack_from(encoded, offset)
    if campaign.name in {
        SUCCESSFUL_PROFILE_NAME,
        OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME,
    }:
        _require(outcome == OUTCOME_COMPLETED, "sidecar reserved byte is nonzero")
    elif campaign.name == RETENTION_CAPACITY_PROFILE_NAME:
        _require(
            outcome in {OUTCOME_COMPLETED, OUTCOME_CAPACITY_REJECTED},
            "sidecar outcome is invalid",
        )
    elif campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        _require(
            outcome in {OUTCOME_COMPLETED, OUTCOME_TIMED_OUT},
            "sidecar outcome is invalid",
        )
    else:
        raise VerificationError(
            "unsupported sidecar profile: %s" % campaign.name
        )
    schedule: OpenLoopSchedule | None = None
    if campaign.has_open_loop_schedule:
        schedule = OpenLoopSchedule(
            *OPEN_LOOP_SCHEDULE_STRUCT.unpack_from(
                encoded,
                offset + SIDECAR_BYTES,
            )
        )
    return Sidecar(
        ordinal,
        response_bytes,
        enqueue_ordinal,
        dispatch_ordinal,
        retired_ordinal,
        enqueue_ns,
        dispatch_ns,
        published_ns,
        retired_ns,
        work_sequence,
        process_generation,
        connection_sequence,
        slot_generation,
        slot_index,
        worker_index,
        content_byte,
        output_token,
        request_sha256,
        response_handle_sha256,
        handle_sha256,
        output_sha256,
        terminal_sha256,
        completion_sha256,
        outcome,
        schedule,
    )


def _parse_outer(
    encoded: bytes,
    *,
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> tuple[tuple[Sidecar, ...], tuple[int, ...], bytes]:
    campaign = _campaign_profile(profile_name)
    _require(type(encoded) is bytes, "outer envelope must be bytes")
    _require(
        len(encoded) == campaign.outer_bytes,
        "outer envelope length is not fixed",
    )
    (
        magic,
        abi,
        declared_length,
        record_count,
        sidecar_bytes,
        closure_bytes,
        inner_bytes,
    ) = HEADER_STRUCT.unpack_from(encoded, 0)
    _require(magic == campaign.magic, "invalid outer magic")
    _require(abi == campaign.outer_abi, "invalid outer ABI")
    _require(declared_length == len(encoded), "outer length mismatch")
    _require(record_count == RECORD_COUNT, "outer record count mismatch")
    _require(
        sidecar_bytes == campaign.sidecar_bytes,
        "sidecar size mismatch",
    )
    _require(
        closure_bytes == campaign.closure_bytes,
        "closure size mismatch",
    )
    _require(inner_bytes == INNER_BYTES, "inner report size mismatch")

    body_end = len(encoded) - OUTER_DIGEST_BYTES
    stored_body = encoded[body_end : body_end + 32]
    stored_footer = encoded[body_end + 32 :]
    _require(
        stored_body
        == _domain_hash(
            campaign.body_domain,
            encoded[HEADER_BYTES:body_end],
        ),
        "outer body digest mismatch",
    )
    _require(
        stored_footer
        == _domain_hash(
            campaign.footer_domain,
            encoded[: body_end + 32],
        ),
        "outer footer digest mismatch",
    )
    cursor = HEADER_BYTES
    sidecars = []
    for index in range(RECORD_COUNT):
        sidecar = _parse_sidecar_exact(encoded, cursor, campaign)
        _require(sidecar.ordinal == index, "sidecar ordinal is not canonical")
        sidecars.append(sidecar)
        cursor += campaign.sidecar_bytes
    closure = struct.unpack_from(
        "<%dQ" % campaign.closure_u64_count,
        encoded,
        cursor,
    )
    cursor += campaign.closure_bytes
    inner = encoded[cursor : cursor + INNER_BYTES]
    cursor += INNER_BYTES
    _require(cursor == body_end, "outer body layout mismatch")
    return tuple(sidecars), tuple(closure), inner


def _parse_inner_profile(inner: bytes) -> InnerProfile:
    scenario_offset = native_workload_report.HEADER_BYTES
    scenario = inner[
        scenario_offset : scenario_offset
        + native_workload_report.SCENARIO_WIRE_BYTES
    ]
    _require(len(scenario) == native_workload_report.SCENARIO_WIRE_BYTES, "truncated scenario")
    mode = scenario[8]
    evidence = scenario[9]
    warmup, measured, maximum, queue_count, flow_count = struct.unpack_from(
        "<5I", scenario, 12
    )
    _require(scenario[11] == 0 and scenario[32:36] == b"\x00" * 4, "scenario reserved bytes are nonzero")
    identities = tuple(
        scenario[36 + index * 32 : 68 + index * 32]
        for index in range(13)
    )

    records = []
    records_offset = scenario_offset + native_workload_report.SCENARIO_WIRE_BYTES
    for index in range(RECORD_COUNT):
        offset = records_offset + index * native_workload_report.RECORD_WIRE_BYTES
        record = inner[offset : offset + native_workload_report.RECORD_WIRE_BYTES]
        _require(len(record) == native_workload_report.RECORD_WIRE_BYTES, "truncated inner record")
        ordinal = struct.unpack_from("<I", record, 8)[0]
        cohort, outcome, correctness, fallback = record[12:16]
        flow_id = struct.unpack_from("<I", record, 16)[0]
        work_units = struct.unpack_from("<Q", record, 20)[0]
        queue_slot = struct.unpack_from("<I", record, 28)[0]
        presence_mask = record[32]
        points = tuple(
            struct.unpack_from("<QQ", record, 36 + event * 16)
            for event in range(7)
        )
        roots = tuple(record[148 + root * 32 : 180 + root * 32] for root in range(9))
        records.append(
            InnerRecord(
                ordinal,
                cohort,
                outcome,
                correctness,
                fallback,
                flow_id,
                work_units,
                queue_slot,
                presence_mask,
                points,
                roots,
            )
        )

    summary_offset = records_offset + RECORD_COUNT * native_workload_report.RECORD_WIRE_BYTES
    summary = inner[
        summary_offset : summary_offset
        + native_workload_report.SUMMARY_WIRE_BYTES
    ]
    completed_work_units = struct.unpack_from("<Q", summary, 44)[0]
    interval_ns = struct.unpack_from("<Q", summary, 68)[0]
    throughput_numerator = struct.unpack_from("<Q", summary, 84)[0]
    throughput_denominator = struct.unpack_from("<Q", summary, 92)[0]

    def distribution_sample_and_p99(
        distribution_index: int,
    ) -> tuple[int, int]:
        offset = 100 + distribution_index * 40
        return (
            struct.unpack_from("<I", summary, offset)[0],
            struct.unpack_from("<Q", summary, offset + 24)[0],
        )

    measured_terminal = sorted(
        record.points[5][0] - record.points[0][0]
        for record in records[WARMUP_COUNT:]
    )
    terminal_rank = math.ceil(0.99 * len(measured_terminal))
    terminal_p99 = measured_terminal[terminal_rank - 1]
    admission_sample_count, admission_p99 = (
        distribution_sample_and_p99(0)
    )
    queue_sample_count, queue_p99 = distribution_sample_and_p99(1)
    first_byte_sample_count, first_byte_p99 = (
        distribution_sample_and_p99(2)
    )

    return InnerProfile(
        mode,
        evidence,
        warmup,
        measured,
        maximum,
        queue_count,
        flow_count,
        identities,
        tuple(records),
        completed_work_units,
        interval_ns,
        throughput_numerator,
        throughput_denominator,
        admission_sample_count,
        admission_p99,
        queue_sample_count,
        queue_p99,
        first_byte_sample_count,
        first_byte_p99,
        terminal_p99,
    )


def _pin_root(sidecar: Sidecar) -> bytes:
    return _hash_parts(
        PIN_DOMAIN,
        _u64(sidecar.process_generation),
        _u64(sidecar.connection_sequence),
        _u8(sidecar.slot_index),
        _u64(sidecar.slot_generation),
    )


def _dispatch_root(sidecar: Sidecar, pin: bytes) -> bytes:
    return _hash_parts(
        DISPATCH_DOMAIN,
        pin,
        _u64(sidecar.enqueue_ordinal),
        _u64(sidecar.enqueue_ns),
        _u64(sidecar.dispatch_ordinal),
        _u64(sidecar.dispatch_ns),
        _u8(sidecar.worker_index),
    )


def _submission_root(sidecar: Sidecar, pin: bytes) -> bytes:
    return _hash_parts(
        SUBMISSION_DOMAIN,
        sidecar.request_sha256,
        sidecar.handle_sha256,
        pin,
        _u64(sidecar.work_sequence),
        _u64(sidecar.published_ns),
    )


def _oracle_root(sidecar: Sidecar) -> bytes:
    return _hash_parts(
        ORACLE_DOMAIN,
        _u32(sidecar.output_token),
        _u8(sidecar.content_byte),
    )


def _retention_capacity_terminal_root(sidecar: Sidecar) -> bytes:
    return _hash_parts(
        RETENTION_CAPACITY_TERMINAL_DOMAIN,
        sidecar.request_sha256,
        _u8(RETENTION_CAPACITY_ERROR_CODE),
        _u8(RETENTION_CAPACITY_RETRY_DISPOSITION),
        _u32(RETENTION_CAPACITY_HTTP_STATUS),
    )


def _retention_capacity_response_semantic_root(sidecar: Sidecar) -> bytes:
    return _hash_parts(
        RETENTION_CAPACITY_RESPONSE_SEMANTICS_DOMAIN,
        sidecar.request_sha256,
        _u8(RETENTION_CAPACITY_ERROR_CODE),
        _u8(RETENTION_CAPACITY_RETRY_DISPOSITION),
        _u32(RETENTION_CAPACITY_HTTP_STATUS),
        _u32(sidecar.response_bytes),
    )


def _retention_capacity_completion_root(sidecar: Sidecar) -> bytes:
    return _hash_parts(
        RETENTION_CAPACITY_COMPLETION_DOMAIN,
        sidecar.request_sha256,
        sidecar.response_handle_sha256,
        sidecar.output_sha256,
        _u32(sidecar.response_bytes),
        sidecar.terminal_sha256,
    )


def _queued_receive_timeout_request_evidence(
    raw_head: bytes,
    raw_body: bytes,
) -> bytes:
    _require(type(raw_head) is bytes, "raw HTTP head must be bytes")
    _require(type(raw_body) is bytes, "raw HTTP body must be bytes")
    return _hash_parts(
        QUEUED_RECEIVE_TIMEOUT_HTTP_REQUEST_DOMAIN,
        raw_head,
        raw_body,
    )


def _queued_receive_timeout_semantic_root(sidecar: Sidecar) -> bytes:
    return _hash_parts(
        QUEUED_RECEIVE_TIMEOUT_TRANSPORT_SEMANTICS_DOMAIN,
        sidecar.request_sha256,
        _u8(QUEUED_RECEIVE_TIMEOUT_EVENT_KIND),
        _u8(QUEUED_RECEIVE_TIMEOUT_PHASE),
        _u8(NO_WORKER_INDEX),
        _u64(QUEUED_RECEIVE_TIMEOUT_NS),
        _u64(sidecar.process_generation),
        _u64(sidecar.connection_sequence),
        _u8(sidecar.slot_index),
        _u64(sidecar.slot_generation),
        _u64(sidecar.enqueue_ordinal),
        _u64(sidecar.enqueue_ns),
        _u64(sidecar.retired_ordinal),
        _u64(sidecar.retired_ns),
        _u32(sidecar.response_bytes),
    )


def _queued_receive_timeout_terminal_root(
    sidecar: Sidecar,
) -> bytes:
    return _hash_parts(
        QUEUED_RECEIVE_TIMEOUT_TERMINAL_DOMAIN,
        sidecar.request_sha256,
        sidecar.output_sha256,
    )


def _queued_receive_timeout_completion_root(
    sidecar: Sidecar,
) -> bytes:
    return _hash_parts(
        QUEUED_RECEIVE_TIMEOUT_COMPLETION_DOMAIN,
        sidecar.request_sha256,
        sidecar.response_handle_sha256,
        sidecar.output_sha256,
        _u32(sidecar.response_bytes),
        sidecar.terminal_sha256,
    )


def _verify_closure(
    closure: tuple[int, ...],
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> None:
    campaign = _campaign_profile(profile_name)
    _require(
        len(closure) == campaign.closure_u64_count,
        "closure field count mismatch",
    )
    if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        _require(
            closure == QUEUED_RECEIVE_TIMEOUT_CLOSURE,
            "queued receive timeout closure mismatch",
        )
        return
    if campaign.name == OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME:
        _require(
            closure[0:7] == (72, 72, 0, 72, 72, 8, 2),
            "open-loop connection and pressure closure mismatch",
        )
        _require(
            closure[7] == closure[8]
            and 1 <= closure[7] <= closure[0],
            "open-loop backpressure is absent or unbalanced",
        )
        _require(
            closure[9:17] == (0,) * 8,
            "open-loop transport closure retains failure or ownership",
        )
        _require(
            closure[17:23] == (0, 72, 72, 0, 0, 0),
            "open-loop service closure mismatch",
        )
        _require(
            closure[23:27] == (1, 1, 1, 0),
            "open-loop scheduler/Bank/thread closure mismatch",
        )
        _require(
            closure[27]
            == RECORD_COUNT * 3 + closure[7] + closure[8],
            "open-loop event stream closure mismatch",
        )
        return
    _require(closure[0:5] == (72, 72, 0, 72, 72), "connection conservation mismatch")
    _require(
        1 <= closure[5] <= campaign.pending_capacity,
        "queue high-water is invalid",
    )
    _require(
        1 <= closure[6] <= campaign.worker_count,
        "running high-water is invalid",
    )
    _require(closure[7] == closure[8], "backpressure is not balanced")
    _require(
        closure[7] <= closure[0],
        "backpressure activations exceed accepted connections",
    )
    _require(closure[9:17] == (0,) * 8, "transport closure retains failure or ownership")
    _require(
        closure[17:23]
        == (
            0,
            campaign.service_completed_records,
            campaign.service_completed_records,
            0,
            0,
            0,
        ),
        "service closure mismatch",
    )
    _require(closure[23:27] == (1, 1, 1, 0), "scheduler/Bank/thread closure mismatch")
    _require(
        closure[27] == RECORD_COUNT * 3 + closure[7] + closure[8],
        "event stream closure mismatch",
    )


def _open_loop_expected_schedule(
    planned_ordinal: int,
) -> tuple[int, int, int]:
    _require(
        0 <= planned_ordinal < RECORD_COUNT,
        "open-loop planned ordinal is out of range",
    )
    if planned_ordinal < WARMUP_COUNT:
        return OPEN_LOOP_PHASE_WARMUP, 0, 0
    if planned_ordinal < OPEN_LOOP_PRESSURE_START:
        phase_ordinal = planned_ordinal - OPEN_LOOP_BASELINE_START
        return (
            OPEN_LOOP_PHASE_BASELINE,
            OPEN_LOOP_SCHEDULE_FLAG_MEASURED,
            phase_ordinal * OPEN_LOOP_BASELINE_STEP_NS,
        )
    if planned_ordinal < OPEN_LOOP_RECOVERY_START:
        phase_ordinal = planned_ordinal - OPEN_LOOP_PRESSURE_START
        return (
            OPEN_LOOP_PHASE_PRESSURE,
            OPEN_LOOP_SCHEDULE_FLAG_MEASURED,
            OPEN_LOOP_PRESSURE_START_OFFSET_NS
            + phase_ordinal * OPEN_LOOP_PRESSURE_STEP_NS,
        )
    phase_ordinal = planned_ordinal - OPEN_LOOP_RECOVERY_START
    return (
        OPEN_LOOP_PHASE_RECOVERY,
        OPEN_LOOP_SCHEDULE_FLAG_MEASURED,
        OPEN_LOOP_RECOVERY_START_OFFSET_NS
        + phase_ordinal * OPEN_LOOP_RECOVERY_STEP_NS,
    )


def _open_loop_phase_report(
    entries: Sequence[
        tuple[Sidecar, InnerRecord, OpenLoopSchedule]
    ],
    *,
    planned_first: int,
    scheduled_first_ns: int,
    scheduled_last_ns: int,
) -> dict[str, int]:
    arrivals = [record.points[0][0] for _, record, _ in entries]
    lateness = [schedule.launch_lateness_ns for _, _, schedule in entries]
    actual_first = min(arrivals)
    actual_last = max(arrivals)
    actual_span = actual_last - actual_first
    scheduled_span = scheduled_last_ns - scheduled_first_ns
    _require(actual_span > 0, "open-loop actual phase span is not positive")
    return {
        "planned_records": len(entries),
        "planned_ordinal_first": planned_first,
        "planned_ordinal_last": planned_first + len(entries) - 1,
        "scheduled_offset_first_ns": scheduled_first_ns,
        "scheduled_offset_last_ns": scheduled_last_ns,
        "scheduled_launch_span_ns": scheduled_span,
        "actual_client_launch_first_ns": actual_first,
        "actual_client_launch_last_ns": actual_last,
        "actual_client_launch_span_ns": actual_span,
        "max_launch_lateness_ns": max(lateness),
        "offered_launch_rate_numerator": len(entries) - 1,
        "offered_launch_rate_denominator_ns": scheduled_span,
        "achieved_launch_rate_numerator": len(entries) - 1,
        "achieved_launch_rate_denominator_ns": actual_span,
    }


def _verify_open_loop_evidence(
    sidecars: tuple[Sidecar, ...],
    records: tuple[InnerRecord, ...],
    closure: tuple[int, ...],
) -> dict[str, Any]:
    _require(
        len(sidecars) == RECORD_COUNT
        and len(records) == RECORD_COUNT
        and len(closure) == OPEN_LOOP_CLOSURE_U64_COUNT,
        "open-loop evidence shape mismatch",
    )
    anchor_ns = closure[28]
    _require(anchor_ns > 0, "open-loop schedule anchor is absent")
    _require(
        closure[29:33]
        == (
            MEASURED_COUNT,
            OPEN_LOOP_BASELINE_COUNT,
            OPEN_LOOP_PRESSURE_COUNT,
            OPEN_LOOP_RECOVERY_COUNT,
        ),
        "open-loop phase count closure mismatch",
    )

    planned: dict[
        int,
        tuple[Sidecar, InnerRecord, OpenLoopSchedule],
    ] = {}
    phase_entries: dict[
        int,
        list[tuple[Sidecar, InnerRecord, OpenLoopSchedule]],
    ] = {
        OPEN_LOOP_PHASE_BASELINE: [],
        OPEN_LOOP_PHASE_PRESSURE: [],
        OPEN_LOOP_PHASE_RECOVERY: [],
    }
    for sidecar, record in zip(sidecars, records):
        schedule = sidecar.schedule
        _require(
            type(schedule) is OpenLoopSchedule,
            "open-loop schedule sidecar is absent",
        )
        assert schedule is not None
        scalar_values = (
            schedule.planned_ordinal,
            schedule.phase,
            schedule.flags,
            schedule.reserved,
            schedule.scheduled_offset_ns,
            schedule.launch_lateness_ns,
            schedule.transmit_complete_ns,
        )
        _require(
            all(type(value) is int for value in scalar_values),
            "open-loop schedule scalar type is invalid",
        )
        _require(
            schedule.planned_ordinal not in planned,
            "open-loop planned ordinal is duplicated",
        )
        expected_phase, expected_flags, expected_offset = (
            _open_loop_expected_schedule(schedule.planned_ordinal)
        )
        _require(
            (
                schedule.phase,
                schedule.flags,
                schedule.reserved,
                schedule.scheduled_offset_ns,
            )
            == (
                expected_phase,
                expected_flags,
                0,
                expected_offset,
            ),
            "open-loop schedule geometry mismatch",
        )
        expected_cohort = (
            0
            if expected_phase == OPEN_LOOP_PHASE_WARMUP
            else 1
        )
        _require(
            record.cohort == expected_cohort,
            "open-loop schedule phase/cohort mismatch",
        )
        actual_launch_ns = record.points[0][0]
        _require(
            actual_launch_ns > 0
            and schedule.transmit_complete_ns >= actual_launch_ns
            and schedule.transmit_complete_ns <= record.points[4][0],
            "open-loop transmit boundary is not causal",
        )
        if expected_phase == OPEN_LOOP_PHASE_WARMUP:
            _require(
                schedule.launch_lateness_ns == 0,
                "open-loop warmup retains scheduled lateness",
            )
            _require(
                record.flow_id == schedule.planned_ordinal,
                "open-loop warmup flow schedule mismatch",
            )
        else:
            scheduled_launch_ns = anchor_ns + expected_offset
            _require(
                scheduled_launch_ns <= (1 << 64) - 1,
                "open-loop scheduled launch overflows u64",
            )
            _require(
                actual_launch_ns >= scheduled_launch_ns,
                "open-loop request launched before its schedule",
            )
            _require(
                schedule.launch_lateness_ns
                == actual_launch_ns - scheduled_launch_ns,
                "open-loop launch lateness mismatch",
            )
            _require(
                schedule.launch_lateness_ns
                <= OPEN_LOOP_LAUNCH_LATENESS_CAP_NS,
                "open-loop launch lateness exceeds fixed cap",
            )
            _require(
                record.flow_id
                == (schedule.planned_ordinal - WARMUP_COUNT)
                % FLOW_COUNT,
                "open-loop measured flow schedule mismatch",
            )
            phase_entries[expected_phase].append(
                (sidecar, record, schedule)
            )
        planned[schedule.planned_ordinal] = (
            sidecar,
            record,
            schedule,
        )
    _require(
        set(planned) == set(range(RECORD_COUNT)),
        "open-loop planned ordinal set is not canonical",
    )
    actual_order = [
        (
            record.points[0][0],
            sidecar.schedule.planned_ordinal,
        )
        for sidecar, record in zip(sidecars, records)
        if sidecar.schedule is not None
    ]
    _require(
        actual_order == sorted(actual_order),
        "open-loop records are not actual-launch ordered",
    )

    warmups = [planned[index] for index in range(WARMUP_COUNT)]
    for previous, current in zip(warmups, warmups[1:]):
        _require(
            previous[1].points[6][0]
            <= current[1].points[0][0],
            "open-loop warmups are not sequential",
        )

    expected_phase_counts = {
        OPEN_LOOP_PHASE_BASELINE: OPEN_LOOP_BASELINE_COUNT,
        OPEN_LOOP_PHASE_PRESSURE: OPEN_LOOP_PRESSURE_COUNT,
        OPEN_LOOP_PHASE_RECOVERY: OPEN_LOOP_RECOVERY_COUNT,
    }
    for phase, expected_count in expected_phase_counts.items():
        _require(
            len(phase_entries[phase]) == expected_count,
            "open-loop measured phase count mismatch",
        )

    baseline = phase_entries[OPEN_LOOP_PHASE_BASELINE]
    pressure = phase_entries[OPEN_LOOP_PHASE_PRESSURE]
    recovery = phase_entries[OPEN_LOOP_PHASE_RECOVERY]
    pressure_fifo = sorted(
        (sidecar.enqueue_ordinal, sidecar.dispatch_ordinal)
        for sidecar, _, _ in pressure
    )
    _require(
        all(
            previous[1] < current[1]
            for previous, current in zip(
                pressure_fifo,
                pressure_fifo[1:],
            )
        ),
        "open-loop pressure dispatch violates FIFO enqueue order",
    )
    baseline_arrivals = [record.points[0][0] for _, record, _ in baseline]
    pressure_arrivals = [record.points[0][0] for _, record, _ in pressure]
    recovery_arrivals = [record.points[0][0] for _, record, _ in recovery]
    _require(
        max(baseline_arrivals) < min(pressure_arrivals)
        and max(pressure_arrivals) < min(recovery_arrivals),
        "open-loop measured phases overlap",
    )

    baseline_report = _open_loop_phase_report(
        baseline,
        planned_first=OPEN_LOOP_BASELINE_START,
        scheduled_first_ns=0,
        scheduled_last_ns=(
            (OPEN_LOOP_BASELINE_COUNT - 1)
            * OPEN_LOOP_BASELINE_STEP_NS
        ),
    )
    pressure_report = _open_loop_phase_report(
        pressure,
        planned_first=OPEN_LOOP_PRESSURE_START,
        scheduled_first_ns=OPEN_LOOP_PRESSURE_START_OFFSET_NS,
        scheduled_last_ns=(
            OPEN_LOOP_PRESSURE_START_OFFSET_NS
            + (OPEN_LOOP_PRESSURE_COUNT - 1)
            * OPEN_LOOP_PRESSURE_STEP_NS
        ),
    )
    recovery_report = _open_loop_phase_report(
        recovery,
        planned_first=OPEN_LOOP_RECOVERY_START,
        scheduled_first_ns=OPEN_LOOP_RECOVERY_START_OFFSET_NS,
        scheduled_last_ns=(
            OPEN_LOOP_RECOVERY_START_OFFSET_NS
            + (OPEN_LOOP_RECOVERY_COUNT - 1)
            * OPEN_LOOP_RECOVERY_STEP_NS
        ),
    )
    _require(
        closure[33:36]
        == (
            baseline_report["actual_client_launch_span_ns"],
            pressure_report["actual_client_launch_span_ns"],
            recovery_report["actual_client_launch_span_ns"],
        ),
        "open-loop actual phase span closure mismatch",
    )
    _require(
        closure[36:39]
        == (
            baseline_report["max_launch_lateness_ns"],
            pressure_report["max_launch_lateness_ns"],
            recovery_report["max_launch_lateness_ns"],
        ),
        "open-loop launch lateness closure mismatch",
    )

    gate_arm_due_ns = anchor_ns + OPEN_LOOP_GATE_ARM_OFFSET_NS
    release_due_ns = anchor_ns + OPEN_LOOP_FIXED_RELEASE_OFFSET_NS
    _require(
        release_due_ns
        <= (1 << 64) - 1 - OPEN_LOOP_LAUNCH_LATENESS_CAP_NS,
        "open-loop release schedule overflows u64",
    )
    pressure_ready_ns = closure[39]
    release_ns = closure[40]
    _require(
        gate_arm_due_ns
        <= pressure_ready_ns
        <= release_due_ns,
        "open-loop pressure gate readiness is outside its window",
    )
    _require(
        release_due_ns
        <= release_ns
        <= release_due_ns + OPEN_LOOP_LAUNCH_LATENESS_CAP_NS,
        "open-loop fixed release is outside its window",
    )
    baseline_settled_ns = max(
        record.points[6][0] for _, record, _ in baseline
    )
    _require(
        baseline_settled_ns <= gate_arm_due_ns,
        "open-loop baseline did not settle before gate arm",
    )
    _require(
        pressure_ready_ns
        >= min(sidecar.enqueue_ns for sidecar, _, _ in pressure),
        "open-loop pressure readiness precedes pressure admission",
    )
    pressure_transmit_max_ns = max(
        schedule.transmit_complete_ns for _, _, schedule in pressure
    )
    _require(
        pressure_transmit_max_ns <= release_ns,
        "open-loop pressure transmit crossed fixed release",
    )
    pressure_decision_min_ns = min(
        sidecar.published_ns for sidecar, _, _ in pressure
    )
    pressure_retirement_min_ns = min(
        sidecar.retired_ns for sidecar, _, _ in pressure
    )
    pressure_terminal_min_ns = min(
        record.points[5][0] for _, record, _ in pressure
    )
    pressure_joined_settlement_min_ns = min(
        record.points[6][0] for _, record, _ in pressure
    )
    _require(
        min(
            pressure_decision_min_ns,
            pressure_retirement_min_ns,
            pressure_terminal_min_ns,
            pressure_joined_settlement_min_ns,
        )
        >= release_ns,
        "open-loop pressure gate was bypassed",
    )

    pressure_server_settled_ns = max(
        sidecar.retired_ns for sidecar, _, _ in pressure
    )
    pressure_joined_settled_ns = max(
        record.points[6][0] for _, record, _ in pressure
    )
    _require(
        closure[41] == pressure_server_settled_ns
        and closure[42] == pressure_joined_settled_ns,
        "open-loop pressure settlement closure mismatch",
    )
    recovery_first_ns = min(recovery_arrivals)
    pressure_settled_ns = max(
        pressure_server_settled_ns,
        pressure_joined_settled_ns,
    )
    _require(
        recovery_first_ns >= pressure_settled_ns,
        "open-loop recovery overlaps pressure settlement",
    )
    recovery_slack_ns = recovery_first_ns - pressure_settled_ns
    _require(
        closure[43] == recovery_slack_ns
        and recovery_slack_ns >= OPEN_LOOP_RECOVERY_SLACK_NS,
        "open-loop recovery slack is below the fixed bound",
    )

    return {
        "schema": (
            "glacier.native-unary-open-loop-transient-pressure/v1"
        ),
        "arrival_policy": "scheduled-open-loop",
        "warmup_records": WARMUP_COUNT,
        "measured_records": MEASURED_COUNT,
        "schedule_anchor_ns": anchor_ns,
        "launch_lateness_cap_ns": (
            OPEN_LOOP_LAUNCH_LATENESS_CAP_NS
        ),
        "phases": {
            "baseline": baseline_report,
            "pressure": pressure_report,
            "recovery": recovery_report,
        },
        "pressure_gate": {
            "arm_offset_ns": OPEN_LOOP_GATE_ARM_OFFSET_NS,
            "ready_ns": pressure_ready_ns,
            "fixed_release_offset_ns": (
                OPEN_LOOP_FIXED_RELEASE_OFFSET_NS
            ),
            "release_ns": release_ns,
            "transmit_complete_max_ns": pressure_transmit_max_ns,
            "server_decision_min_ns": pressure_decision_min_ns,
            "server_retirement_min_ns": pressure_retirement_min_ns,
            "client_terminal_min_ns": pressure_terminal_min_ns,
            "joined_settlement_min_ns": (
                pressure_joined_settlement_min_ns
            ),
            "queue_high_water": closure[5],
            "running_high_water": closure[6],
            "backpressure_cycles": closure[7],
        },
        "recovery": {
            "scheduled_start_offset_ns": (
                OPEN_LOOP_RECOVERY_START_OFFSET_NS
            ),
            "pressure_server_settled_ns": (
                pressure_server_settled_ns
            ),
            "pressure_joined_settled_ns": (
                pressure_joined_settled_ns
            ),
            "actual_client_launch_first_ns": recovery_first_ns,
            "slack_ns": recovery_slack_ns,
            "minimum_slack_ns": OPEN_LOOP_RECOVERY_SLACK_NS,
        },
    }


def _verify_profile(
    sidecars: tuple[Sidecar, ...],
    closure: tuple[int, ...],
    profile: InnerProfile,
    *,
    expected_build: bytes,
    expected_machine: bytes,
    expected_challenge: bytes,
    system: str,
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> None:
    campaign = _campaign_profile(profile_name)
    _require(
        (
            profile.mode,
            profile.evidence,
            profile.warmup_count,
            profile.measured_count,
            profile.max_in_flight,
            profile.queue_count,
            profile.flow_count,
        )
        == (
            campaign.scenario_mode,
            1,
            WARMUP_COUNT,
            MEASURED_COUNT,
            campaign.max_in_flight,
            campaign.queue_count,
            FLOW_COUNT,
        ),
        "inner scenario is not the fixed native load profile",
    )
    _require(
        (
            profile.admission_sample_count,
            profile.queue_sample_count,
            profile.first_byte_sample_count,
        )
        == (campaign.measured_completed,) * 3,
        "completed timing sample count mismatch",
    )
    expected_identities = {
        0: _identity(WORKLOAD_ID),
        1: _identity(campaign.profile_id),
        3: expected_build,
        4: expected_machine,
        5: _identity(BACKEND_ID),
        6: _identity(DEVICE_ID),
        7: _identity(campaign.placement_id),
        8: _identity(HOST_SOURCE_ID),
        9: _host_clock_identity(system),
        10: _identity(DEVICE_SOURCE_ID),
        11: _identity(DEVICE_CLOCK_ID),
        12: expected_challenge,
    }
    for index, expected in expected_identities.items():
        _require(profile.identities[index] == expected, "scenario identity %d mismatch" % index)
    _require(profile.identities[2] != ZERO_DIGEST, "artifact identity is absent")
    _verify_closure(closure, campaign.name)
    _require(
        len(sidecars) == RECORD_COUNT and len(profile.records) == RECORD_COUNT,
        "profile record count mismatch",
    )

    owners: set[tuple[int, int, int, int]] = set()
    connection_sequences: set[int] = set()
    slot_generations: dict[int, list[tuple[int, int]]] = {}
    requests: set[bytes] = set()
    handles: set[bytes] = set()
    work_sequences: set[int] = set()
    response_evidence: set[bytes] = set()
    lifecycle_ordinals: set[int] = set()
    lifecycle_events: list[tuple[int, int]] = []
    measured_completed_per_flow = [0] * FLOW_COUNT
    measured_rejected_per_flow = [0] * FLOW_COUNT
    measured_timed_out_per_flow = [0] * FLOW_COUNT
    for index, (sidecar, record) in enumerate(zip(sidecars, profile.records)):
        _require(record.ordinal == index and sidecar.ordinal == index, "record order mismatch")
        expected_cohort = 0 if index < WARMUP_COUNT else 1
        _require(record.cohort == expected_cohort, "cohort mismatch")
        expected_outcome = _expected_outcome(campaign, index)
        _require(
            sidecar.outcome == expected_outcome
            and record.outcome == expected_outcome,
            "sidecar and record outcome mismatch",
        )
        _require(0 <= record.flow_id < FLOW_COUNT, "flow id is out of range")
        expected_flow = _expected_flow(campaign, index)
        if expected_flow is not None:
            _require(
                record.flow_id == expected_flow,
                "queued receive timeout flow schedule mismatch",
            )
        if record.cohort == 1:
            if expected_outcome == OUTCOME_COMPLETED:
                measured_completed_per_flow[record.flow_id] += 1
            elif expected_outcome == OUTCOME_CAPACITY_REJECTED:
                measured_rejected_per_flow[record.flow_id] += 1
            else:
                measured_timed_out_per_flow[record.flow_id] += 1
        _require(
            sidecar.process_generation == campaign.process_generation,
            "process generation mismatch",
        )
        _require(sidecar.connection_sequence > 0, "connection sequence is zero")
        _require(
            sidecar.connection_sequence not in connection_sequences,
            "connection sequence is duplicated",
        )
        _require(sidecar.slot_generation > 0, "slot generation is zero")
        _require(
            0 <= sidecar.slot_index < campaign.connection_capacity,
            "slot index is out of range",
        )
        owner = (
            sidecar.process_generation,
            sidecar.connection_sequence,
            sidecar.slot_index,
            sidecar.slot_generation,
        )
        _require(owner not in owners, "transport owner is duplicated")
        _require(sidecar.request_sha256 not in requests, "request root is duplicated")
        _require(sidecar.request_sha256 != ZERO_DIGEST, "request root is absent")
        owners.add(owner)
        connection_sequences.add(sidecar.connection_sequence)
        slot_generations.setdefault(sidecar.slot_index, []).append(
            (sidecar.connection_sequence, sidecar.slot_generation)
        )
        requests.add(sidecar.request_sha256)
        if expected_outcome == OUTCOME_COMPLETED:
            _require(
                0 < sidecar.response_bytes <= 16 * 1024,
                "response byte count is invalid",
            )
            _require(
                0 <= sidecar.worker_index < campaign.worker_count,
                "worker index is out of range",
            )
            _require(
                0
                < sidecar.enqueue_ordinal
                < sidecar.dispatch_ordinal
                < sidecar.retired_ordinal,
                "lifecycle ordinals are not causal",
            )
            _require(
                0
                < sidecar.enqueue_ns
                <= sidecar.dispatch_ns
                <= sidecar.published_ns
                <= sidecar.retired_ns,
                "server observations are not monotonic",
            )
            lifecycle_ordinals.update(
                (
                    sidecar.enqueue_ordinal,
                    sidecar.dispatch_ordinal,
                    sidecar.retired_ordinal,
                )
            )
            lifecycle_events.extend(
                (
                    (sidecar.enqueue_ordinal, sidecar.enqueue_ns),
                    (sidecar.dispatch_ordinal, sidecar.dispatch_ns),
                    (sidecar.retired_ordinal, sidecar.retired_ns),
                )
            )
            _require(
                record.points[6][0] >= sidecar.retired_ns,
                "joined settlement precedes retirement",
            )
            _require(
                (
                    record.correctness,
                    record.fallback,
                    record.work_units,
                    record.presence_mask,
                )
                == (1, 0, 1, 0x7F),
                "record is not one correct completed request",
            )
            if campaign.has_open_loop_schedule:
                schedule = sidecar.schedule
                _require(
                    type(schedule) is OpenLoopSchedule,
                    "open-loop schedule sidecar is absent",
                )
                assert schedule is not None
                logical_actor_slot = (
                    schedule.planned_ordinal
                    if schedule.planned_ordinal < WARMUP_COUNT
                    else schedule.planned_ordinal - WARMUP_COUNT
                )
                _require(
                    0
                    <= logical_actor_slot
                    < OPEN_LOOP_LOGICAL_ACTOR_COUNT
                    and record.queue_slot == logical_actor_slot,
                    "open-loop logical actor slot mismatch",
                )
            else:
                _require(
                    record.queue_slot == sidecar.slot_index,
                    "queue slot/owner mismatch",
                )
            _require(
                sidecar.output_token == sidecar.content_byte,
                "fixture output token/content mismatch",
            )
            _require(
                sidecar.response_handle_sha256 == sidecar.handle_sha256,
                "HTTP response handle/work handle mismatch",
            )
            _require(sidecar.handle_sha256 != ZERO_DIGEST, "handle root is absent")
            _require(sidecar.output_sha256 != ZERO_DIGEST, "output root is absent")
            _require(sidecar.work_sequence > 0, "work sequence is zero")
            _require(sidecar.handle_sha256 not in handles, "handle root is duplicated")
            _require(
                sidecar.work_sequence not in work_sequences,
                "work sequence is duplicated",
            )
            handles.add(sidecar.handle_sha256)
            work_sequences.add(sidecar.work_sequence)
            _require(
                record.points[1][0] == sidecar.enqueue_ns,
                "accept/enqueue timestamp mismatch",
            )
            _require(
                record.points[2][0] == sidecar.dispatch_ns,
                "queue timestamp mismatch",
            )
            _require(
                record.points[3][0] == sidecar.published_ns,
                "publication timestamp mismatch",
            )
            pin = _pin_root(sidecar)
            expected_roots = (
                sidecar.request_sha256,
                sidecar.handle_sha256,
                pin,
                _dispatch_root(sidecar, pin),
                _submission_root(sidecar, pin),
                sidecar.output_sha256,
                _oracle_root(sidecar),
                sidecar.terminal_sha256,
                sidecar.completion_sha256,
            )
        elif expected_outcome == OUTCOME_CAPACITY_REJECTED:
            _require(
                0 < sidecar.response_bytes <= 16 * 1024,
                "response byte count is invalid",
            )
            _require(
                0 <= sidecar.worker_index < campaign.worker_count,
                "worker index is out of range",
            )
            _require(
                0
                < sidecar.enqueue_ordinal
                < sidecar.dispatch_ordinal
                < sidecar.retired_ordinal,
                "lifecycle ordinals are not causal",
            )
            _require(
                0
                < sidecar.enqueue_ns
                <= sidecar.dispatch_ns
                <= sidecar.published_ns
                <= sidecar.retired_ns,
                "server observations are not monotonic",
            )
            lifecycle_ordinals.update(
                (
                    sidecar.enqueue_ordinal,
                    sidecar.dispatch_ordinal,
                    sidecar.retired_ordinal,
                )
            )
            lifecycle_events.extend(
                (
                    (sidecar.enqueue_ordinal, sidecar.enqueue_ns),
                    (sidecar.dispatch_ordinal, sidecar.dispatch_ns),
                    (sidecar.retired_ordinal, sidecar.retired_ns),
                )
            )
            _require(
                record.points[6][0] >= sidecar.retired_ns,
                "joined settlement precedes retirement",
            )
            _require(
                (
                    record.correctness,
                    record.fallback,
                    record.work_units,
                    record.queue_slot,
                    record.presence_mask,
                )
                == (0, 0, 1, NO_QUEUE_SLOT, CAPACITY_REJECTED_PRESENCE),
                "capacity rejection record shape mismatch",
            )
            _require(
                all(
                    record.points[event] == (0, 0)
                    for event in (1, 2, 3, 4)
                ),
                "capacity rejection claims absent lifecycle events",
            )
            _require(
                0
                < record.points[0][0]
                <= sidecar.enqueue_ns
                <= sidecar.dispatch_ns
                <= sidecar.published_ns
                <= record.points[5][0]
                <= record.points[6][0],
                "capacity rejection observations are not monotonic",
            )
            _require(
                sidecar.work_sequence == 0
                and sidecar.handle_sha256 == ZERO_DIGEST
                and sidecar.output_token == 0
                and sidecar.content_byte == 0,
                "capacity rejection retains work payload",
            )
            _require(
                sidecar.response_handle_sha256 != ZERO_DIGEST,
                "capacity rejection response evidence is absent",
            )
            _require(
                sidecar.response_handle_sha256 not in response_evidence,
                "capacity rejection response evidence is duplicated",
            )
            response_evidence.add(sidecar.response_handle_sha256)
            _require(
                sidecar.output_sha256
                == _retention_capacity_response_semantic_root(sidecar),
                "capacity rejection response semantic root mismatch",
            )
            _require(
                sidecar.terminal_sha256
                == _retention_capacity_terminal_root(sidecar),
                "capacity rejection terminal root mismatch",
            )
            _require(
                sidecar.completion_sha256
                == _retention_capacity_completion_root(sidecar),
                "capacity rejection completion root mismatch",
            )
            expected_roots = (
                sidecar.request_sha256,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                sidecar.terminal_sha256,
                sidecar.completion_sha256,
            )
        else:
            _require(
                expected_outcome == OUTCOME_TIMED_OUT,
                "unsupported expected outcome",
            )
            # For this profile, retired_* are wire aliases for the single
            # queued_receive_timeout terminal event, not a second retirement.
            _require(
                sidecar.response_bytes == 0,
                "queued timeout claims response bytes",
            )
            _require(
                sidecar.dispatch_ordinal == 0
                and sidecar.dispatch_ns == 0
                and sidecar.worker_index == NO_WORKER_INDEX,
                "queued timeout claims worker dispatch",
            )
            _require(
                0
                < sidecar.enqueue_ordinal
                < sidecar.retired_ordinal,
                "queued timeout lifecycle ordinals are not causal",
            )
            _require(
                0
                < sidecar.enqueue_ns
                <= sidecar.published_ns
                == sidecar.retired_ns,
                "queued timeout server observations are not monotonic",
            )
            lifecycle_ordinals.update(
                (sidecar.enqueue_ordinal, sidecar.retired_ordinal)
            )
            lifecycle_events.extend(
                (
                    (sidecar.enqueue_ordinal, sidecar.enqueue_ns),
                    (sidecar.retired_ordinal, sidecar.retired_ns),
                )
            )
            _require(
                (
                    record.correctness,
                    record.fallback,
                    record.work_units,
                    record.queue_slot,
                    record.presence_mask,
                )
                == (0, 0, 1, NO_QUEUE_SLOT, CAPACITY_REJECTED_PRESENCE),
                "queued timeout record shape mismatch",
            )
            _require(
                all(
                    record.points[event] == (0, 0)
                    for event in (1, 2, 3, 4)
                ),
                "queued timeout claims absent workload events",
            )
            _require(
                0
                < record.points[0][0]
                <= sidecar.enqueue_ns
                <= sidecar.retired_ns
                <= record.points[5][0]
                <= record.points[6][0],
                "queued timeout observations are not monotonic",
            )
            _require(
                QUEUED_RECEIVE_TIMEOUT_NS
                <= sidecar.retired_ns - record.points[0][0]
                <= QUEUED_RECEIVE_TIMEOUT_MAX_TERMINAL_NS,
                "queued receive timeout terminal observation is outside fixed bound",
            )
            _require(
                sidecar.retired_ns - sidecar.enqueue_ns
                <= QUEUED_RECEIVE_TIMEOUT_MAX_QUEUE_RESIDENCE_NS,
                "queued receive timeout queue residence exceeds fixed bound",
            )
            _require(
                record.points[6][0] - sidecar.retired_ns
                <= QUEUED_RECEIVE_TIMEOUT_MAX_SETTLEMENT_PROPAGATION_NS,
                "queued receive timeout peer-close/no-response transport "
                "settlement propagation exceeds fixed bound",
            )
            _require(
                0
                < record.points[0][1]
                < record.points[5][1]
                < record.points[6][1],
                "queued timeout event sequence is not causal",
            )
            _require(
                sidecar.work_sequence == 0
                and sidecar.handle_sha256 == ZERO_DIGEST
                and sidecar.output_token == 0
                and sidecar.content_byte == 0,
                "queued timeout retains work payload",
            )
            _require(
                sidecar.response_handle_sha256 != ZERO_DIGEST,
                "queued timeout request evidence is absent",
            )
            _require(
                sidecar.response_handle_sha256 not in response_evidence,
                "queued timeout request evidence is duplicated",
            )
            response_evidence.add(sidecar.response_handle_sha256)
            _require(
                sidecar.output_sha256
                == _queued_receive_timeout_semantic_root(sidecar),
                "queued timeout transport semantic root mismatch",
            )
            _require(
                sidecar.terminal_sha256
                == _queued_receive_timeout_terminal_root(sidecar),
                "queued timeout terminal root mismatch",
            )
            _require(
                sidecar.completion_sha256
                == _queued_receive_timeout_completion_root(sidecar),
                "queued timeout completion root mismatch",
            )
            expected_roots = (
                sidecar.request_sha256,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                ZERO_DIGEST,
                sidecar.terminal_sha256,
                sidecar.completion_sha256,
            )
        _require(record.roots == expected_roots, "transport root composition mismatch")
    expected_lifecycle_ordinals = (
        campaign.service_completed_records * 3
        + (
            (RECORD_COUNT - campaign.service_completed_records) * 2
            if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            else (RECORD_COUNT - campaign.service_completed_records) * 3
        )
    )
    _require(
        len(lifecycle_ordinals) == expected_lifecycle_ordinals,
        "lifecycle ordinal is duplicated",
    )
    _require(max(lifecycle_ordinals) <= closure[27], "lifecycle ordinal exceeds event closure")
    _require(
        closure[27] - len(lifecycle_ordinals) == closure[7] + closure[8],
        "unretained lifecycle event count mismatch",
    )
    ordered_lifecycle_events = sorted(lifecycle_events)
    for previous, current in zip(
        ordered_lifecycle_events,
        ordered_lifecycle_events[1:],
    ):
        _require(
            previous[1] <= current[1],
            "lifecycle ordinal contradicts timestamp order",
        )
    _require(
        connection_sequences == set(range(1, RECORD_COUNT + 1)),
        "connection sequence is not canonical",
    )
    for generations in slot_generations.values():
        ordered_generations = [
            generation for _, generation in sorted(generations)
        ]
        _require(
            ordered_generations
            == list(range(1, len(ordered_generations) + 1)),
            "slot generation is not canonical",
        )
    _require(
        work_sequences
        == set(range(1, campaign.service_completed_records + 1)),
        "work sequence is not canonical",
    )
    if campaign.has_open_loop_schedule:
        _verify_open_loop_evidence(
            sidecars,
            profile.records,
            closure,
        )
    expected_completed_per_flow = campaign.measured_completed // FLOW_COUNT
    expected_rejected_per_flow = (
        campaign.measured_capacity_rejected // FLOW_COUNT
    )
    expected_timed_out_per_flow = campaign.measured_timed_out // FLOW_COUNT
    _require(
        measured_completed_per_flow
        == [expected_completed_per_flow] * FLOW_COUNT,
        "measured completed flow balance mismatch",
    )
    _require(
        measured_rejected_per_flow
        == [expected_rejected_per_flow] * FLOW_COUNT,
        "measured rejected flow balance mismatch",
    )
    _require(
        measured_timed_out_per_flow
        == [expected_timed_out_per_flow] * FLOW_COUNT,
        "measured timed-out flow balance mismatch",
    )
    _require(
        (
            profile.completed_work_units,
            profile.throughput_numerator,
            profile.throughput_denominator_ns,
        )
        == (
            campaign.measured_completed,
            campaign.measured_completed,
            profile.interval_ns,
        ),
        "throughput identity mismatch",
    )


def verify_envelope(
    encoded: bytes,
    *,
    expected_build: bytes,
    expected_machine: bytes,
    expected_challenge: bytes,
    system: str,
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> VerifiedEnvelope:
    sidecars, closure, inner = _parse_outer(
        encoded,
        profile_name=profile_name,
    )
    try:
        inner_result = native_workload_report.verify_wire(inner)
    except native_workload_report.VerificationError as error:
        raise VerificationError("embedded workload report rejected: %s" % error) from error
    profile = _parse_inner_profile(inner)
    _verify_profile(
        sidecars,
        closure,
        profile,
        expected_build=expected_build,
        expected_machine=expected_machine,
        expected_challenge=expected_challenge,
        system=system,
        profile_name=profile_name,
    )
    return VerifiedEnvelope(
        inner_result,
        profile,
        sidecars,
        closure,
        hashlib.sha256(encoded).digest(),
    )


def _metric(observation: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    try:
        return native_observer.metric_by_name(observation, name)
    except native_observer.ObservationError as error:
        raise VerificationError("native observation is missing %s: %s" % (name, error)) from error


def _present_metric(observation: Mapping[str, Any], name: str) -> int:
    metric = _metric(observation, name)
    _require(metric.get("availability") == "present", "%s is unavailable" % name)
    value = metric.get("value")
    _require(type(value) is int and value >= 0, "%s value is invalid" % name)
    return value


def _machine_from_darwin_capture(capture: Mapping[str, Any]) -> tuple[dict[str, Any], bytes]:
    host = capture.get("host")
    _require(isinstance(host, Mapping), "Darwin admission has no host descriptor")
    fingerprint = host.get("fingerprint_sha256")
    _require(isinstance(fingerprint, str) and len(fingerprint) == 64, "host fingerprint is invalid")
    return dict(host), bytes.fromhex(fingerprint)


def _linux_machine_descriptor() -> tuple[dict[str, Any], bytes]:
    boot_root: str | None = None
    try:
        boot_value = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
        if boot_value:
            boot_root = hashlib.sha256(boot_value.encode("ascii")).hexdigest()
    except OSError:
        pass
    descriptor = {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor() or "unknown",
        "logical_cpu_count": os.cpu_count(),
        "boot_session_sha256": boot_root,
    }
    canonical = json.dumps(descriptor, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")
    root = hashlib.sha256(canonical).digest()
    descriptor["fingerprint_sha256"] = root.hex()
    return descriptor, root


def _validate_native_boundaries(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
    *,
    system: str,
) -> dict[str, Any]:
    _require(before.get("claim_scope") == "native-observation-only", "pre-run observation is simulated")
    _require(after.get("claim_scope") == "native-observation-only", "post-run observation is simulated")
    _require(before.get("system") == system == after.get("system"), "observation system changed")
    _require(before.get("adapter") == after.get("adapter"), "observation adapter changed")
    logical_before = _present_metric(before, "host_logical_cpu_count")
    logical_after = _present_metric(after, "host_logical_cpu_count")
    _require(logical_before == logical_after, "logical CPU count changed")
    if system == "Linux":
        return {
            "logical_cpu_count": logical_before,
            "cpu_load_observation_available": False,
            "cpu_publication_eligible": False,
        }
    busy_before = _present_metric(before, "host_cpu_busy_ppm")
    busy_after = _present_metric(after, "host_cpu_busy_ppm")
    external_before = _present_metric(before, "host_external_cpu_ppm")
    external_after = _present_metric(after, "host_external_cpu_ppm")
    _require(
        external_before <= MAX_EXTERNAL_CPU_PPM
        and external_after <= MAX_EXTERNAL_CPU_PPM,
        "external CPU load exceeds the fixed admission bound",
    )
    _require(
        abs(external_after - external_before) <= MAX_EXTERNAL_CPU_DRIFT_PPM,
        "external CPU boundary drift exceeds the fixed bound",
    )
    _require(
        abs(busy_after - busy_before) <= MAX_BOUNDARY_CPU_DRIFT_PPM,
        "CPU busy boundary drift exceeds the fixed bound",
    )
    if system == "Darwin":
        _require(_present_metric(before, "host_power_source") == 1, "pre-run power source is not AC")
        _require(_present_metric(after, "host_power_source") == 1, "post-run power source is not AC")
        _require(_present_metric(before, "host_low_power_mode") == 0, "pre-run Low Power Mode is enabled")
        _require(_present_metric(after, "host_low_power_mode") == 0, "post-run Low Power Mode is enabled")
        for observation, label in ((before, "pre-run"), (after, "post-run")):
            thermal = _metric(observation, "host_thermal_constraint")
            if thermal.get("availability") == "present":
                _require(thermal.get("value") == 0, "%s thermal state is constrained" % label)
    return {
        "logical_cpu_count": logical_before,
        "cpu_load_observation_available": True,
        "cpu_publication_eligible": (
            external_before <= PUBLISHABLE_EXTERNAL_CPU_PPM
            and external_after <= PUBLISHABLE_EXTERNAL_CPU_PPM
        ),
        "busy_before_ppm": busy_before,
        "busy_after_ppm": busy_after,
        "external_before_ppm": external_before,
        "external_after_ppm": external_after,
    }


def _capture_native_observation(phase: str) -> dict[str, Any]:
    return native_observer.capture_observation(
        phase,
        process_id=os.getpid(),
        process_group_id=os.getpgrp(),
        top_iterations=2,
        sample_interval_seconds=1.0,
    )


def _kill_bounded_process(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError:
            pass
        process.wait()


def _bounded_capture(
    command: Sequence[str],
    *,
    stdout_limit: int,
    stderr_limit: int,
    timeout_seconds: float,
    env: Mapping[str, str],
) -> tuple[int, bytes, bytes]:
    _require(os.name == "posix", "bounded process capture requires POSIX")
    _require(stdout_limit >= 0, "stdout bound is invalid")
    _require(stderr_limit >= 0, "stderr bound is invalid")
    _require(
        math.isfinite(timeout_seconds) and timeout_seconds > 0,
        "process timeout is invalid",
    )
    try:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(env),
            start_new_session=True,
        )
    except OSError as error:
        raise VerificationError(
            "native load producer failed to start: %s" % error
        ) from error
    selector: selectors.BaseSelector | None = None
    try:
        stdout_stream = process.stdout
        stderr_stream = process.stderr
        if stdout_stream is None or stderr_stream is None:
            raise VerificationError(
                "native load producer pipes are unavailable"
            )

        output = bytearray()
        errors = bytearray()
        selector = selectors.DefaultSelector()
        selector.register(
            stdout_stream,
            selectors.EVENT_READ,
            ("stdout", output, stdout_limit),
        )
        selector.register(
            stderr_stream,
            selectors.EVENT_READ,
            ("stderr", errors, stderr_limit),
        )
        deadline = time.monotonic() + timeout_seconds
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise VerificationError("native load producer timed out")
            ready = selector.select(remaining)
            if not ready:
                raise VerificationError("native load producer timed out")
            for key, _ in ready:
                label, destination, limit = key.data
                remaining_capacity = limit - len(destination)
                chunk = os.read(
                    key.fileobj.fileno(),
                    min(64 * 1024, remaining_capacity + 1),
                )
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                if len(chunk) > remaining_capacity:
                    raise VerificationError(
                        "producer %s exceeded the fixed bound" % label
                    )
                destination.extend(chunk)

        remaining = deadline - time.monotonic()
        if remaining <= 0 and process.poll() is None:
            raise VerificationError("native load producer timed out")
        try:
            returncode = process.wait(timeout=max(0.0, remaining))
        except subprocess.TimeoutExpired as error:
            raise VerificationError(
                "native load producer timed out"
            ) from error
        return returncode, bytes(output), bytes(errors)
    except BaseException:
        _kill_bounded_process(process)
        raise
    finally:
        if selector is not None:
            selector.close()
        for stream in (process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def _run_producer(
    executable: Path,
    challenge: bytes,
    build_sha256: bytes,
    machine_sha256: bytes,
    timeout_seconds: float,
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> bytes:
    campaign = _campaign_profile(profile_name)
    returncode, stdout, stderr = _bounded_capture(
        [
            str(executable),
            campaign.producer_mode,
            challenge.hex(),
            build_sha256.hex(),
            machine_sha256.hex(),
        ],
        stdout_limit=campaign.outer_bytes,
        stderr_limit=MAX_RUNNER_STDERR_BYTES,
        timeout_seconds=timeout_seconds,
        env={"LC_ALL": "C", "PATH": os.defpath},
    )
    _require(
        returncode == 0,
        "producer exited %d: %s"
        % (returncode, stderr.decode("utf-8", "replace")),
    )
    _require(stderr == b"", "producer emitted stderr")
    _require(
        len(stdout) == campaign.outer_bytes,
        "producer output length is not fixed",
    )
    return stdout


def _atomic_write(path: Path, data: bytes) -> None:
    destination = path.expanduser().resolve(strict=False)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".%s." % destination.name, delete=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _canonical_json(value: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)
        + "\n"
    ).encode("utf-8")


def _exact_mapping(
    value: object,
    expected_keys: set[str],
    label: str,
) -> Mapping[str, Any]:
    _require(isinstance(value, Mapping), "%s is not a mapping" % label)
    _require(set(value) == expected_keys, "%s fields are not exact" % label)
    return value


def _hex_sha256(value: object, label: str) -> bytes:
    _require(
        isinstance(value, str)
        and len(value) == 64
        and value == value.lower(),
        "%s is not canonical SHA-256 hex" % label,
    )
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise VerificationError(
            "%s is not canonical SHA-256 hex" % label
        ) from error
    _require(len(decoded) == 32, "%s is not SHA-256" % label)
    return decoded


def _require_canonical_equal(
    actual: object,
    expected: object,
    message: str,
) -> None:
    try:
        equal = (
            publication.canonical_json_bytes(actual)
            == publication.canonical_json_bytes(expected)
        )
    except publication.PublicationError as error:
        raise VerificationError(message) from error
    _require(equal, message)


def _verified_utc(value: object, label: str) -> dt.datetime:
    _require(
        type(value) is str and bool(value),
        "%s timestamp is invalid" % label,
    )
    try:
        parsed = dt.datetime.fromisoformat(value)
    except ValueError as error:
        raise VerificationError(
            "%s timestamp is invalid" % label
        ) from error
    _require(
        parsed.tzinfo is not None
        and parsed.utcoffset() == dt.timedelta(0)
        and parsed.isoformat() == value,
        "%s timestamp is not canonical UTC" % label,
    )
    return parsed


def _verified_machine_fingerprint(
    value: object,
    *,
    system: str,
) -> bytes:
    fields = (
        {
            "system",
            "release",
            "machine",
            "cpu_brand",
            "logical_cpu_count",
            "boot_session_sha256",
            "fingerprint_sha256",
        }
        if system == "Darwin"
        else {
            "system",
            "release",
            "machine",
            "processor",
            "logical_cpu_count",
            "boot_session_sha256",
            "fingerprint_sha256",
        }
    )
    machine = _exact_mapping(value, fields, "machine")
    _require(machine.get("system") == system, "machine system mismatch")
    for field in (
        "release",
        "machine",
        "cpu_brand" if system == "Darwin" else "processor",
    ):
        _require(
            isinstance(machine.get(field), str) and bool(machine[field]),
            "machine %s is invalid" % field,
        )
    logical_cpu_count = machine.get("logical_cpu_count")
    _require(
        type(logical_cpu_count) is int
        and 1 <= logical_cpu_count <= (1 << 20),
        "machine logical CPU count is invalid",
    )
    boot_session = machine.get("boot_session_sha256")
    if boot_session is not None:
        _hex_sha256(boot_session, "machine boot session")
    descriptor = {
        key: machine[key]
        for key in fields
        if key != "fingerprint_sha256"
    }
    canonical = json.dumps(
        descriptor,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")
    fingerprint = hashlib.sha256(canonical).digest()
    _require(
        _hex_sha256(
            machine.get("fingerprint_sha256"),
            "machine fingerprint",
        )
        == fingerprint,
        "machine fingerprint is inconsistent",
    )
    return fingerprint


def _verify_retained_native_observation(
    value: object,
    *,
    system: str,
    phase: str,
) -> Mapping[str, Any]:
    expected_fields = {
        "schema",
        "adapter",
        "phase",
        "system",
        "observed_process_id",
        "captured_at_utc",
        "capture_interval",
        "availability_counts",
        "metrics",
        "claim_scope",
    }
    if system == "Linux":
        expected_fields |= {
            "actual_system",
            "capture_mode",
            "publication_eligible",
        }
    observation = _exact_mapping(
        value,
        expected_fields,
        "%s native observation" % phase,
    )
    expected_schema = (
        native_observer.SCHEMA
        if system == "Darwin"
        else native_observer.HOST_SCHEMA
    )
    expected_adapter = (
        native_observer.ADAPTER
        if system == "Darwin"
        else native_observer_linux.ADAPTER
    )
    _require(
        observation["schema"] == expected_schema
        and observation["adapter"] == expected_adapter
        and observation["phase"] == phase
        and observation["system"] == system
        and observation["claim_scope"] == "native-observation-only",
        "%s native observation identity is invalid" % phase,
    )
    if system == "Linux":
        _require(
            observation["actual_system"] == "Linux"
            and observation["capture_mode"] == "native"
            and observation["publication_eligible"] is True,
            "%s Linux observation is not a native capture" % phase,
        )
    process_id = observation["observed_process_id"]
    _require(
        type(process_id) is int
        and 1 <= process_id <= (1 << 31) - 1,
        "%s observed process id is invalid" % phase,
    )
    _verified_utc(
        observation["captured_at_utc"],
        "%s observation" % phase,
    )
    interval = _exact_mapping(
        observation["capture_interval"],
        {"sample_clock_domain", "started_ns", "finished_ns"},
        "%s capture interval" % phase,
    )
    started_ns = interval["started_ns"]
    finished_ns = interval["finished_ns"]
    _require(
        interval["sample_clock_domain"] == "host_monotonic"
        and type(started_ns) is int
        and type(finished_ns) is int
        and 0 <= started_ns <= finished_ns <= native_observer.I64_MAX,
        "%s capture interval is invalid" % phase,
    )
    metrics = observation["metrics"]
    _require(
        type(metrics) is list
        and len(metrics) == len(native_observer.METRIC_SPECS),
        "%s metric set is not fixed" % phase,
    )
    canonical_metrics: list[dict[str, Any]] = []
    metric_fields = (
        "name",
        "availability",
        "value",
        "unit",
        "sample_clock_domain",
        "value_clock_domain",
        "phase",
        "subject",
        "source_identity_sha256",
        "provenance",
        "reason",
        "reason_sha256",
    )
    for metric, specification in zip(
        metrics,
        native_observer.METRIC_SPECS,
        strict=True,
    ):
        retained_metric = _exact_mapping(
            metric,
            set(metric_fields),
            "%s metric record" % phase,
        )
        ordered_metric = {
            field: retained_metric[field]
            for field in metric_fields
        }
        try:
            canonical = (
                native_observer._common.validate_metric_record(
                    ordered_metric,
                    expected_system=system,
                )
            )
        except native_observer.ObservationError as error:
            raise VerificationError(
                "%s metric record is invalid: %s" % (phase, error)
            ) from error
        _require(
            canonical["name"] == specification[0]
            and canonical["phase"] == phase
            and canonical["provenance"]["adapter"]
            == expected_adapter,
            "%s metric identity is invalid" % phase,
        )
        _require_canonical_equal(
            metric,
            canonical,
            "%s metric record is not type-exact" % phase,
        )
        canonical_metrics.append(canonical)
    availability_counts = _exact_mapping(
        observation["availability_counts"],
        set(native_observer.AVAILABILITIES),
        "%s availability counts" % phase,
    )
    expected_counts = {
        availability: sum(
            metric["availability"] == availability
            for metric in canonical_metrics
        )
        for availability in native_observer.AVAILABILITIES
    }
    _require_canonical_equal(
        availability_counts,
        expected_counts,
        "%s availability counts are inconsistent" % phase,
    )
    return observation


def _publication_environment_roots(
    environment: Mapping[str, Any],
) -> tuple[bytes, bytes]:
    pre = {
        "stable_pre_run_admission": environment[
            "stable_pre_run_admission"
        ],
        "native_observation": environment[
            "pre_run_native_observation"
        ],
    }
    post = {
        "post_run_admission": environment["post_run_admission"],
        "native_observation": environment[
            "post_run_native_observation"
        ],
    }
    return (
        publication.canonical_json_sha256(
            pre,
            domain=PRE_ENVIRONMENT_DOMAIN,
        ),
        publication.canonical_json_sha256(
            post,
            domain=POST_ENVIRONMENT_DOMAIN,
        ),
    )


def _publication_eligibility(
    system: str,
    cpu_boundary: Mapping[str, Any],
) -> dict[str, Any]:
    reasons: list[str] = []
    if system == "Linux":
        reasons.append(LINUX_ATTRIBUTION_UNAVAILABLE)
    else:
        if (
            cpu_boundary.get("external_before_ppm", 1 << 60)
            > PUBLISHABLE_EXTERNAL_CPU_PPM
        ):
            reasons.append(DARWIN_PRE_EXTERNAL_CPU_ABOVE_BOUND)
        if (
            cpu_boundary.get("external_after_ppm", 1 << 60)
            > PUBLISHABLE_EXTERNAL_CPU_PPM
        ):
            reasons.append(DARWIN_POST_EXTERNAL_CPU_ABOVE_BOUND)
    eligible = not reasons
    retained_eligible = cpu_boundary.get(
        "cpu_publication_eligible"
    )
    _require(
        type(retained_eligible) is bool
        and retained_eligible == eligible,
        "CPU publication eligibility is inconsistent",
    )
    return {
        "policy": PUBLICATION_ELIGIBILITY_POLICY,
        "decision": "eligible" if eligible else "ineligible",
        "reasons": reasons,
        "publishable_external_cpu_ppm": PUBLISHABLE_EXTERNAL_CPU_PPM,
    }


def _claim_scope(campaign: CampaignProfile) -> str:
    if campaign.name == RETENTION_CAPACITY_PROFILE_NAME:
        return (
            "native-loopback-unary-retention-capacity-and-"
            "serialized-fixture-only"
        )
    if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        return (
            "native-loopback-unary-queued-receive-timeout-and-"
            "serialized-fixture-only"
        )
    if campaign.name == OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME:
        return (
            "native-loopback-unary-open-loop-transient-pressure-and-"
            "serialized-fixture-only"
        )
    return "native-loopback-unary-transport-and-serialized-fixture-only"


def _report_manifest(
    campaign: CampaignProfile,
    encoded: bytes,
    verified: VerifiedEnvelope,
) -> dict[str, Any]:
    return {
        "sha256": verified.outer_sha256.hex(),
        "bytes": len(encoded),
        "inner_report_sha256": (
            verified.inner_result.report_sha256.hex()
        ),
        "warmup_records": WARMUP_COUNT,
        "measured_records": MEASURED_COUNT,
        "completed_work_units": verified.profile.completed_work_units,
        "interval_ns": verified.profile.interval_ns,
        "throughput_numerator": verified.profile.throughput_numerator,
        "throughput_denominator_ns": (
            verified.profile.throughput_denominator_ns
        ),
        **_completed_timing_fields(verified.profile),
        **(
            {
                "queued_timeout_terminal_observation_p99_ns": (
                    verified.profile.terminal_p99_ns
                ),
            }
            if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            else {
                "terminal_response_p99_ns": (
                    verified.profile.terminal_p99_ns
                ),
            }
        ),
        "outcomes": {
            "completed": campaign.measured_completed,
            "capacity_rejected": campaign.measured_capacity_rejected,
            "failed": 0,
            "cancelled": 0,
            "timed_out": campaign.measured_timed_out,
        },
        **(
            {
                "open_loop": _verify_open_loop_evidence(
                    verified.sidecars,
                    verified.profile.records,
                    verified.closure,
                )
            }
            if campaign.has_open_loop_schedule
            else {}
        ),
    }


def _manifest_limitations(
    campaign: CampaignProfile,
) -> list[str]:
    return [
        "HTTP first-byte is not first-token latency.",
        (
            "The tiny deterministic fixture is not representative "
            "large-model inference."
        ),
        (
            "The request mutex serializes model admission, execution, "
            "and retirement."
        ),
        (
            "Capacity rejection proves retained-record saturation, not "
            "active-work or transport-queue saturation."
            if campaign.name == RETENTION_CAPACITY_PROFILE_NAME
            else (
                "Queued receive timeout proves the fixed accept-origin "
                "queued-expiry profile, not full-request timeout or "
                "application overload."
                if campaign.name
                == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                else (
                    "The fixed scheduled open-loop profile proves "
                    "bounded client launch and loopback queue pressure "
                    "for one synthetic fixture, not an uncontrolled "
                    "arrival process or production capacity limit."
                    if campaign.name
                    == OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME
                    else (
                        "The successful profile contains no "
                        "capacity-rejection evidence."
                    )
                )
            )
        ),
        (
            "Queued sockets are never server-parsed; request-to-lease "
            "binding is a deterministic single-outstanding "
            "client-plan/transmit correlation, not server-parsed request "
            "attestation."
            if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            else (
                "Every retained request root is correlated under its "
                "profile-specific producer ABI."
            )
        ),
        (
            "The queued-timeout campaign is deterministic closed-loop "
            "pressure, not open-loop, transient, or general overload "
            "evidence; W6 queue latency and throughput include completed "
            "work only."
            if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            else (
                "Offered and achieved open-loop rates describe client "
                "attempt launches; W6 throughput remains completed work "
                "over the measured settlement interval."
                if campaign.name
                == OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME
                else "The campaign mode is closed-loop."
            )
        ),
        (
            "Logical queue and in-flight facts do not prove physical CPU "
            "parallelism."
        ),
        (
            "No GPU performance, fairness, power, energy, temperature, "
            "or foreign-OS result is inferred."
        ),
        (
            "AC and nominal constraint signals do not prove fixed clock "
            "frequency or a measured temperature."
        ),
    ]


def _completed_timing_fields(profile: InnerProfile) -> dict[str, int]:
    return {
        "completed_arrival_to_fifo_enqueue_sample_count": (
            profile.admission_sample_count
        ),
        "completed_arrival_to_fifo_enqueue_p99_ns": (
            profile.admission_p99_ns
        ),
        "completed_fifo_enqueue_to_worker_dispatch_sample_count": (
            profile.queue_sample_count
        ),
        "completed_fifo_enqueue_to_worker_dispatch_p99_ns": (
            profile.queue_p99_ns
        ),
        "completed_http_first_positive_read_sample_count": (
            profile.first_byte_sample_count
        ),
        "completed_http_first_positive_read_p99_ns": (
            profile.first_byte_p99_ns
        ),
    }


def run_campaign(
    executable: Path,
    *,
    timeout_seconds: float = RUNNER_TIMEOUT_SECONDS,
    admission_interval_seconds: float = native_environment_admission.DEFAULT_INTERVAL_SECONDS,
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> tuple[bytes, dict[str, Any], VerifiedEnvelope]:
    campaign = _campaign_profile(profile_name)
    system = platform.system()
    _require(system in {"Darwin", "Linux"}, "native load supports Darwin and Linux hosts")
    executable = executable.expanduser().resolve(strict=True)
    _require(executable.is_file(), "producer is not a regular file")
    _require(math.isfinite(timeout_seconds) and timeout_seconds > 0, "timeout must be positive")
    build_before = hashlib.sha256(executable.read_bytes()).digest()

    stable_captures: list[dict[str, Any]] = []
    if system == "Darwin":
        try:
            stable = native_environment_admission.wait_for_stable_admission(
                timeout_seconds=max(30.0, admission_interval_seconds * 4.0),
                interval_seconds=admission_interval_seconds,
            )
        except native_environment_admission.NativeEnvironmentAdmissionError as error:
            raise VerificationError("stable Darwin environment admission failed: %s" % error) from error
        stable_captures = [stable.captures[0], stable.captures[1]]
        machine_descriptor, machine_sha256 = _machine_from_darwin_capture(stable.captures[-1])
    else:
        machine_descriptor, machine_sha256 = _linux_machine_descriptor()

    before = _capture_native_observation("pre_run")
    challenge = secrets.token_bytes(32)
    encoded = _run_producer(
        executable,
        challenge,
        build_before,
        machine_sha256,
        timeout_seconds,
        campaign.name,
    )
    build_after = hashlib.sha256(executable.read_bytes()).digest()
    _require(build_after == build_before, "producer changed during the campaign")
    after = _capture_native_observation("post_run")
    cpu_boundary = _validate_native_boundaries(before, after, system=system)

    post_admission: dict[str, Any] | None = None
    publication_eligible = False
    if system == "Darwin":
        post_admission = lane4_evidence.capture_environment()
        _require(post_admission.get("measurement_admitted") is True, "post-run Darwin environment is not admitted")
        _require(post_admission.get("reasons") == [], "post-run admission has rejection reasons")
        post_host = post_admission.get("host")
        _require(isinstance(post_host, Mapping), "post-run host descriptor is missing")
        _require(
            post_host.get("fingerprint_sha256") == machine_descriptor["fingerprint_sha256"],
            "host or boot identity changed during the campaign",
        )
        publication_eligible = bool(cpu_boundary["cpu_publication_eligible"])

    verified = verify_envelope(
        encoded,
        expected_build=build_before,
        expected_machine=machine_sha256,
        expected_challenge=challenge,
        system=system,
        profile_name=campaign.name,
    )
    producer = {
        "sha256": build_before.hex(),
        "size_bytes": executable.stat().st_size,
    }
    environment = {
        "stable_pre_run_admission": stable_captures,
        "pre_run_native_observation": before,
        "post_run_admission": post_admission,
        "post_run_native_observation": after,
        "cpu_boundary": cpu_boundary,
    }
    pre_environment_sha256, post_environment_sha256 = (
        _publication_environment_roots(environment)
    )
    eligibility = _publication_eligibility(system, cpu_boundary)
    _require(
        publication_eligible
        == (eligibility["decision"] == "eligible"),
        "publication decision is inconsistent",
    )
    publication_context = {
        "schema": PUBLICATION_CONTEXT_SCHEMA,
        "profile": campaign.name,
        "envelope": {
            "sha256": verified.outer_sha256.hex(),
            "bytes": len(encoded),
        },
        "producer": producer,
        "system": system,
        "machine_fingerprint_sha256": machine_sha256.hex(),
        "challenge_hex": challenge.hex(),
        "challenge_sha256": hashlib.sha256(challenge).hexdigest(),
        "pre_environment_sha256": pre_environment_sha256.hex(),
        "post_environment_sha256": post_environment_sha256.hex(),
        "eligibility": eligibility,
    }
    manifest = {
        "schema": "glacier.native-unary-server-load-capture/v1",
        "status": "verified",
        "profile": campaign.name,
        "publication_eligible": publication_eligible,
        "claim_scope": _claim_scope(campaign),
        "producer": producer,
        "machine": machine_descriptor,
        # Compatibility: this historical field contains the challenge bytes,
        # not their digest.  Publication context names both values precisely.
        "challenge_sha256": challenge.hex(),
        "publication_context": publication_context,
        "report": _report_manifest(campaign, encoded, verified),
        "environment": environment,
        "limitations": _manifest_limitations(campaign),
    }
    return encoded, manifest, verified


def _verify_admitted_darwin_environment(
    value: object,
    *,
    machine_fingerprint: bytes,
    foundation_runner_sha256: str,
    label: str,
) -> None:
    snapshot = _exact_mapping(
        value,
        DARWIN_ADMISSION_FIELDS,
        label,
    )
    _require(
        not native_environment_admission._snapshot_rejections(snapshot),
        "%s is not an admitted Darwin environment" % label,
    )
    _verified_utc(snapshot["captured_at_utc"], label)
    _require(
        snapshot["battery_state"]
        in {"charged", "charging", "not_present"}
        and snapshot["claim_scope"] == "environment-admission-only"
        and snapshot["performance_claim"] == "not_evaluated"
        and snapshot["promotion_decision"] == "not_evaluated"
        and snapshot["measurements_publishable"] is False,
        "%s admission semantics are invalid" % label,
    )
    host_fingerprint = _verified_machine_fingerprint(
        snapshot.get("host"),
        system="Darwin",
    )
    _require(
        host_fingerprint == machine_fingerprint,
        "%s machine fingerprint mismatch" % label,
    )
    logical_cpu_count = snapshot["host"]["logical_cpu_count"]
    for field in ("cpu_speed_limit_percent", "scheduler_limit_percent"):
        retained = snapshot[field]
        _require(
            retained is None or type(retained) is int and retained == 100,
            "%s %s is invalid" % (label, field),
        )
    available_cpus = snapshot["available_cpus"]
    _require(
        available_cpus is None
        or type(available_cpus) is int
        and available_cpus == logical_cpu_count,
        "%s available CPUs are inconsistent" % label,
    )
    for field in (
        "raw_pmset_battery_sha256",
        "raw_pmset_thermal_sha256",
        "raw_foundation_process_info_sha256",
        "foundation_probe_source_sha256",
        "foundation_probe_runner_sha256",
    ):
        _hex_sha256(snapshot[field], "%s %s" % (label, field))
    _require(
        snapshot["foundation_probe_source_sha256"]
        == lane4_evidence.FOUNDATION_PROBE_SOURCE_SHA256
        and snapshot["foundation_probe_runner_sha256"]
        == foundation_runner_sha256,
        "%s probe identity is inconsistent" % label,
    )


def _verify_publication_environment(
    value: object,
    *,
    system: str,
    machine_fingerprint: bytes,
    machine_logical_cpu_count: int,
) -> tuple[dict[str, Any], bytes, bytes]:
    environment = _exact_mapping(
        value,
        {
            "stable_pre_run_admission",
            "pre_run_native_observation",
            "post_run_admission",
            "post_run_native_observation",
            "cpu_boundary",
        },
        "publication environment",
    )
    stable = environment["stable_pre_run_admission"]
    post_admission = environment["post_run_admission"]
    if system == "Darwin":
        _require(
            type(stable) is list and len(stable) == 2,
            "Darwin publication requires two stable pre-run captures",
        )
        first_capture = _exact_mapping(
            stable[0],
            DARWIN_ADMISSION_FIELDS,
            "stable pre-run capture 0",
        )
        foundation_runner_sha256 = first_capture[
            "foundation_probe_runner_sha256"
        ]
        _hex_sha256(
            foundation_runner_sha256,
            "stable pre-run Foundation runner",
        )
        for index, capture in enumerate(stable):
            _verify_admitted_darwin_environment(
                capture,
                machine_fingerprint=machine_fingerprint,
                foundation_runner_sha256=foundation_runner_sha256,
                label="stable pre-run capture %d" % index,
            )
        _verify_admitted_darwin_environment(
            post_admission,
            machine_fingerprint=machine_fingerprint,
            foundation_runner_sha256=foundation_runner_sha256,
            label="post-run admission",
        )
    else:
        _require(
            stable == [] and post_admission is None,
            "Linux publication must not claim Darwin admission",
        )
    before = _verify_retained_native_observation(
        environment["pre_run_native_observation"],
        system=system,
        phase="pre_run",
    )
    after = _verify_retained_native_observation(
        environment["post_run_native_observation"],
        system=system,
        phase="post_run",
    )
    _require(
        before["observed_process_id"] == after["observed_process_id"]
        and before["capture_interval"]["finished_ns"]
        <= after["capture_interval"]["started_ns"],
        "native publication observation sequence is inconsistent",
    )
    cpu_boundary = _validate_native_boundaries(
        before,
        after,
        system=system,
    )
    _require_canonical_equal(
        environment["cpu_boundary"],
        cpu_boundary,
        "retained CPU boundary is inconsistent",
    )
    _require(
        cpu_boundary["logical_cpu_count"]
        == machine_logical_cpu_count,
        "observation logical CPU count does not match the machine",
    )
    pre_root, post_root = _publication_environment_roots(environment)
    return cpu_boundary, pre_root, post_root


def verify_publication_bundle(
    bundle: publication.PublicationBundle,
) -> VerifiedEnvelope:
    _require(
        type(bundle) is publication.PublicationBundle,
        "publication bundle type is invalid",
    )
    try:
        reconstructed = publication.decode_bundle(
            publication.encode_bundle(
                bundle.envelope,
                bundle.manifest,
            )
        )
    except publication.PublicationError as error:
        raise VerificationError(
            "publication bundle reconstruction failed: %s" % error
        ) from error
    for field in (
        "manifest_bytes",
        "envelope_sha256",
        "manifest_sha256",
        "publication_identity_sha256",
        "bundle_sha256",
    ):
        _require(
            getattr(bundle, field) == getattr(reconstructed, field),
            "publication bundle %s is inconsistent" % field,
        )
    bundle = reconstructed
    manifest = _exact_mapping(
        bundle.manifest,
        {
            "schema",
            "status",
            "profile",
            "publication_eligible",
            "claim_scope",
            "producer",
            "machine",
            "challenge_sha256",
            "publication_context",
            "report",
            "environment",
            "limitations",
        },
        "publication manifest",
    )
    _require(
        manifest["schema"]
        == "glacier.native-unary-server-load-capture/v1"
        and manifest["status"] == "verified",
        "publication manifest schema or status is invalid",
    )
    context = _exact_mapping(
        manifest["publication_context"],
        {
            "schema",
            "profile",
            "envelope",
            "producer",
            "system",
            "machine_fingerprint_sha256",
            "challenge_hex",
            "challenge_sha256",
            "pre_environment_sha256",
            "post_environment_sha256",
            "eligibility",
        },
        "publication context",
    )
    _require(
        context["schema"] == PUBLICATION_CONTEXT_SCHEMA,
        "publication context schema is invalid",
    )
    profile_name = context["profile"]
    _require(
        isinstance(profile_name, str),
        "publication profile is invalid",
    )
    campaign = _campaign_profile(profile_name)
    system = context["system"]
    _require(
        system in {"Darwin", "Linux"},
        "publication system is unsupported",
    )
    envelope_context = _exact_mapping(
        context["envelope"],
        {"sha256", "bytes"},
        "publication envelope context",
    )
    _require(
        type(envelope_context["bytes"]) is int
        and envelope_context["bytes"] == len(bundle.envelope),
        "publication envelope byte count mismatch",
    )
    envelope_sha256 = _hex_sha256(
        envelope_context["sha256"],
        "publication envelope digest",
    )
    _require(
        envelope_sha256
        == bundle.envelope_sha256
        == hashlib.sha256(bundle.envelope).digest(),
        "publication envelope digest mismatch",
    )
    producer = _exact_mapping(
        context["producer"],
        {"sha256", "size_bytes"},
        "publication producer",
    )
    expected_build = _hex_sha256(
        producer["sha256"],
        "publication producer digest",
    )
    _require(
        type(producer["size_bytes"]) is int
        and producer["size_bytes"] > 0,
        "publication producer size is invalid",
    )
    challenge_hex = context["challenge_hex"]
    expected_challenge = _hex_sha256(
        challenge_hex,
        "publication challenge",
    )
    _require(
        _hex_sha256(
            context["challenge_sha256"],
            "publication challenge digest",
        )
        == hashlib.sha256(expected_challenge).digest(),
        "publication challenge digest mismatch",
    )
    machine_fingerprint = _hex_sha256(
        context["machine_fingerprint_sha256"],
        "publication machine fingerprint",
    )
    machine = manifest["machine"]
    _require(
        _verified_machine_fingerprint(
            machine,
            system=system,
        )
        == machine_fingerprint,
        "publication machine fingerprint mismatch",
    )

    # These are the only inputs supplied to the embedded envelope verifier.
    # No current-host probe, producer path, or ambient platform value enters
    # offline verification.
    verified = verify_envelope(
        bundle.envelope,
        expected_build=expected_build,
        expected_machine=machine_fingerprint,
        expected_challenge=expected_challenge,
        system=system,
        profile_name=campaign.name,
    )

    cpu_boundary, pre_root, post_root = (
        _verify_publication_environment(
            manifest["environment"],
            system=system,
            machine_fingerprint=machine_fingerprint,
            machine_logical_cpu_count=machine[
                "logical_cpu_count"
            ],
        )
    )
    _require(
        _hex_sha256(
            context["pre_environment_sha256"],
            "pre-run environment root",
        )
        == pre_root
        and _hex_sha256(
            context["post_environment_sha256"],
            "post-run environment root",
        )
        == post_root,
        "publication environment root mismatch",
    )
    eligibility = _publication_eligibility(system, cpu_boundary)
    _require_canonical_equal(
        context["eligibility"],
        eligibility,
        "publication eligibility context mismatch",
    )
    eligible = eligibility["decision"] == "eligible"
    _require(
        type(manifest["publication_eligible"]) is bool
        and manifest["publication_eligible"] == eligible,
        "publication eligibility decision mismatch",
    )
    _require(
        manifest["profile"] == campaign.name
        and manifest["challenge_sha256"] == challenge_hex
        and manifest["claim_scope"] == _claim_scope(campaign),
        "publication context does not match legacy manifest fields",
    )
    _require_canonical_equal(
        manifest["producer"],
        producer,
        "publication producer alias mismatch",
    )
    _require_canonical_equal(
        manifest["report"],
        _report_manifest(campaign, bundle.envelope, verified),
        "publication report summary mismatch",
    )
    _require_canonical_equal(
        manifest["limitations"],
        _manifest_limitations(campaign),
        "publication limitations mismatch",
    )
    return verified


def verify_publication(encoded: bytes) -> VerifiedEnvelope:
    try:
        bundle = publication.decode_bundle(encoded)
    except publication.PublicationError as error:
        raise VerificationError(
            "native load publication bundle rejected: %s" % error
        ) from error
    return verify_publication_bundle(bundle)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify the bounded F1 native unary load campaign")
    parser.add_argument(
        "producer",
        nargs="?",
        help="path to glacier-unary-server-process-test",
    )
    parser.add_argument(
        "--profile",
        choices=tuple(CAMPAIGN_PROFILES),
        default=SUCCESSFUL_PROFILE_NAME,
        help="fixed native-load evidence profile",
    )
    parser.add_argument("--output", help="optional verified binary envelope output")
    parser.add_argument("--manifest-output", help="optional verified capture-manifest JSON output")
    parser.add_argument(
        "--publication-output",
        help="optional atomic envelope-plus-context publication bundle",
    )
    parser.add_argument(
        "--verify-publication",
        help="offline verification of one retained publication bundle",
    )
    parser.add_argument("--timeout-seconds", type=float, default=RUNNER_TIMEOUT_SECONDS)
    parser.add_argument(
        "--admission-interval-seconds",
        type=float,
        default=native_environment_admission.DEFAULT_INTERVAL_SECONDS,
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    publication_identity: bytes | None = None
    try:
        if arguments.verify_publication:
            _require(
                arguments.producer is None,
                "offline publication verification accepts no producer",
            )
            _require(
                not arguments.output
                and not arguments.manifest_output
                and not arguments.publication_output,
                "offline publication verification accepts no output path",
            )
            bundle = publication.read_bundle(
                Path(arguments.verify_publication)
            )
            verified = verify_publication_bundle(bundle)
            manifest = bundle.manifest
            encoded = bundle.envelope
            profile_name = manifest["profile"]
            publication_identity = (
                bundle.publication_identity_sha256
            )
        else:
            _require(
                arguments.producer is not None,
                "native load producer path is required",
            )
            encoded, manifest, verified = run_campaign(
                Path(arguments.producer),
                timeout_seconds=arguments.timeout_seconds,
                admission_interval_seconds=arguments.admission_interval_seconds,
                profile_name=arguments.profile,
            )
            profile_name = arguments.profile
            if arguments.output:
                _atomic_write(Path(arguments.output), encoded)
            if arguments.manifest_output:
                _atomic_write(
                    Path(arguments.manifest_output),
                    _canonical_json(manifest),
                )
            if arguments.publication_output:
                published = publication.encode_bundle(
                    encoded,
                    manifest,
                )
                bundle = publication.decode_bundle(published)
                verify_publication_bundle(bundle)
                publication.atomic_write(
                    Path(arguments.publication_output),
                    published,
                )
                publication_identity = (
                    bundle.publication_identity_sha256
                )
    except (
        OSError,
        VerificationError,
        native_observer.ObservationError,
        publication.PublicationError,
    ) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    profile = verified.profile
    terminal_metric_name = (
        "queued_timeout_terminal_observation_p99_ns"
        if profile_name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
        else "terminal_response_p99_ns"
    )
    print(
        "ok native-unary-server-load-v1 profile=%s "
        "records=%d warmup=%d measured=%d "
        "completed_arrival_to_fifo_enqueue_p99_ns=%d "
        "completed_arrival_to_fifo_enqueue_sample_count=%d "
        "completed_fifo_enqueue_to_worker_dispatch_p99_ns=%d "
        "completed_fifo_enqueue_to_worker_dispatch_sample_count=%d "
        "completed_http_first_positive_read_p99_ns=%d "
        "completed_http_first_positive_read_sample_count=%d %s=%d "
        "throughput=%d/%dns publication_eligible=%s%s"
        % (
            profile_name,
            RECORD_COUNT,
            WARMUP_COUNT,
            MEASURED_COUNT,
            profile.admission_p99_ns,
            profile.admission_sample_count,
            profile.queue_p99_ns,
            profile.queue_sample_count,
            profile.first_byte_p99_ns,
            profile.first_byte_sample_count,
            terminal_metric_name,
            profile.terminal_p99_ns,
            profile.throughput_numerator,
            profile.throughput_denominator_ns,
            str(manifest["publication_eligible"]).lower(),
            (
                " publication_identity_sha256="
                + publication_identity.hex()
                if publication_identity is not None
                else ""
            ),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
