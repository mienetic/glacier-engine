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
from bench import native_workload_report


MAGIC = b"GF1LOAD1"
OUTER_ABI = 0x4746314C00000001
RETENTION_CAPACITY_MAGIC = b"GF1CAP01"
RETENTION_CAPACITY_OUTER_ABI = 0x4746314300000001
QUEUED_RECEIVE_TIMEOUT_MAGIC = b"GF1QRT01"
QUEUED_RECEIVE_TIMEOUT_OUTER_ABI = 0x4746315100000001
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
MAX_RUNNER_STDERR_BYTES = 64 * 1024
RUNNER_TIMEOUT_SECONDS = 120.0
PUBLISHABLE_EXTERNAL_CPU_PPM = 200_000
MAX_EXTERNAL_CPU_PPM = 500_000
MAX_EXTERNAL_CPU_DRIFT_PPM = 150_000
MAX_BOUNDARY_CPU_DRIFT_PPM = 300_000

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
BACKEND_ID = b"glacier-prepared-text-unary-cpu-backend/v1"
DEVICE_ID = b"host-cpu-device-physical-metrics-unavailable/v1"
PLACEMENT_ID = b"managed-concurrent-loopback-2-worker-8-pending/v1"
QUEUED_RECEIVE_TIMEOUT_PLACEMENT_ID = (
    b"managed-concurrent-loopback-2-worker-6-pending/v1"
)
HOST_SOURCE_ID = b"f1-native-load-parent-child-observers/v1"
DEVICE_SOURCE_ID = b"f1-native-load-device-observer-unsupported/v1"
DEVICE_CLOCK_ID = b"f1-native-load-device-clock-unsupported/v1"
PROCESS_GENERATION = 0x4753505200000116
RETENTION_CAPACITY_PROCESS_GENERATION = 0x4753505200000117
QUEUED_RECEIVE_TIMEOUT_PROCESS_GENERATION = 0x4753505200000118
ZERO_DIGEST = b"\x00" * 32
NO_QUEUE_SLOT = (1 << 32) - 1
OUTCOME_COMPLETED = 0
OUTCOME_CAPACITY_REJECTED = 1
OUTCOME_TIMED_OUT = 4
CAPACITY_REJECTED_PRESENCE = 0x61
SUCCESSFUL_PROFILE_NAME = "successful-v1"
RETENTION_CAPACITY_PROFILE_NAME = "retention-capacity-v1"
QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME = "queued-receive-timeout-v1"
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
CAMPAIGN_PROFILES = {
    SUCCESSFUL_PROFILE.name: SUCCESSFUL_PROFILE,
    RETENTION_CAPACITY_PROFILE.name: RETENTION_CAPACITY_PROFILE,
    QUEUED_RECEIVE_TIMEOUT_PROFILE.name: QUEUED_RECEIVE_TIMEOUT_PROFILE,
}


def _campaign_profile(name: str) -> CampaignProfile:
    try:
        return CAMPAIGN_PROFILES[name]
    except KeyError as error:
        raise VerificationError("unsupported native load profile: %s" % name) from error


def _expected_outcome(campaign: CampaignProfile, ordinal: int) -> int:
    _require(0 <= ordinal < RECORD_COUNT, "record ordinal is out of range")
    if campaign.name == SUCCESSFUL_PROFILE_NAME:
        return OUTCOME_COMPLETED
    if campaign.name == RETENTION_CAPACITY_PROFILE_NAME:
        return (
            OUTCOME_COMPLETED
            if ordinal < campaign.service_completed_records
            else OUTCOME_CAPACITY_REJECTED
        )
    if ordinal < WARMUP_COUNT:
        return OUTCOME_COMPLETED
    epoch_lane = (ordinal - WARMUP_COUNT) % FLOW_COUNT
    return OUTCOME_COMPLETED if epoch_lane < 2 else OUTCOME_TIMED_OUT


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
    admission_p99_ns: int
    queue_p99_ns: int
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
    if campaign.name == SUCCESSFUL_PROFILE_NAME:
        _require(outcome == OUTCOME_COMPLETED, "sidecar reserved byte is nonzero")
    elif campaign.name == RETENTION_CAPACITY_PROFILE_NAME:
        _require(
            outcome in {OUTCOME_COMPLETED, OUTCOME_CAPACITY_REJECTED},
            "sidecar outcome is invalid",
        )
    else:
        _require(
            outcome in {OUTCOME_COMPLETED, OUTCOME_TIMED_OUT},
            "sidecar outcome is invalid",
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
    )


def _parse_outer(
    encoded: bytes,
    *,
    profile_name: str = SUCCESSFUL_PROFILE_NAME,
) -> tuple[tuple[Sidecar, ...], tuple[int, ...], bytes]:
    campaign = _campaign_profile(profile_name)
    _require(type(encoded) is bytes, "outer envelope must be bytes")
    _require(len(encoded) == OUTER_BYTES, "outer envelope length is not fixed")
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
    _require(sidecar_bytes == SIDECAR_BYTES, "sidecar size mismatch")
    _require(closure_bytes == CLOSURE_BYTES, "closure size mismatch")
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
        cursor += SIDECAR_BYTES
    closure = struct.unpack_from("<%dQ" % CLOSURE_U64_COUNT, encoded, cursor)
    cursor += CLOSURE_BYTES
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

    def distribution_p99(distribution_index: int) -> int:
        return struct.unpack_from("<Q", summary, 100 + distribution_index * 40 + 24)[0]

    measured_terminal = sorted(
        record.points[5][0] - record.points[0][0]
        for record in records[WARMUP_COUNT:]
    )
    terminal_rank = math.ceil(0.99 * len(measured_terminal))
    terminal_p99 = measured_terminal[terminal_rank - 1]

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
        distribution_p99(0),
        distribution_p99(1),
        distribution_p99(2),
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
    _require(len(closure) == CLOSURE_U64_COUNT, "closure field count mismatch")
    if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        _require(
            closure == QUEUED_RECEIVE_TIMEOUT_CLOSURE,
            "queued receive timeout closure mismatch",
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
    _require(closure[27] > 0, "event stream is empty")


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
            0,
            1,
            WARMUP_COUNT,
            MEASURED_COUNT,
            campaign.max_in_flight,
            campaign.queue_count,
            FLOW_COUNT,
        ),
        "inner scenario is not the fixed native load profile",
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
    requests: set[bytes] = set()
    handles: set[bytes] = set()
    work_sequences: set[int] = set()
    response_evidence: set[bytes] = set()
    lifecycle_ordinals: set[int] = set()
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
        _require(sidecar.slot_generation > 0, "slot generation is zero")
        _require(
            0 <= sidecar.slot_index < campaign.queue_count,
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
            _require(record.queue_slot == sidecar.slot_index, "queue slot/owner mismatch")
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
        stdout_limit=OUTER_BYTES,
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
    _require(len(stdout) == OUTER_BYTES, "producer output length is not fixed")
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
    manifest = {
        "schema": "glacier.native-unary-server-load-capture/v1",
        "status": "verified",
        "profile": campaign.name,
        "publication_eligible": publication_eligible,
        "claim_scope": (
            "native-loopback-unary-retention-capacity-and-serialized-fixture-only"
            if campaign.name == RETENTION_CAPACITY_PROFILE_NAME
            else (
                "native-loopback-unary-queued-receive-timeout-and-serialized-fixture-only"
                if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                else "native-loopback-unary-transport-and-serialized-fixture-only"
            )
        ),
        "producer": {
            "sha256": build_before.hex(),
            "size_bytes": executable.stat().st_size,
        },
        "machine": machine_descriptor,
        "challenge_sha256": challenge.hex(),
        "report": {
            "sha256": verified.outer_sha256.hex(),
            "bytes": len(encoded),
            "inner_report_sha256": verified.inner_result.report_sha256.hex(),
            "warmup_records": WARMUP_COUNT,
            "measured_records": MEASURED_COUNT,
            "completed_work_units": verified.profile.completed_work_units,
            "interval_ns": verified.profile.interval_ns,
            "throughput_numerator": verified.profile.throughput_numerator,
            "throughput_denominator_ns": verified.profile.throughput_denominator_ns,
            "admission_p99_ns": verified.profile.admission_p99_ns,
            "queue_p99_ns": verified.profile.queue_p99_ns,
            "http_first_byte_p99_ns": verified.profile.first_byte_p99_ns,
            **(
                {
                    "queued_timeout_terminal_observation_p99_ns": (
                        verified.profile.terminal_p99_ns
                    ),
                }
                if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                else {
                    "terminal_response_p99_ns": verified.profile.terminal_p99_ns,
                }
            ),
            "outcomes": {
                "completed": campaign.measured_completed,
                "capacity_rejected": campaign.measured_capacity_rejected,
                "failed": 0,
                "cancelled": 0,
                "timed_out": campaign.measured_timed_out,
            },
        },
        "environment": {
            "stable_pre_run_admission": stable_captures,
            "pre_run_native_observation": before,
            "post_run_admission": post_admission,
            "post_run_native_observation": after,
            "cpu_boundary": cpu_boundary,
        },
        "limitations": [
            "HTTP first-byte is not first-token latency.",
            "The tiny deterministic fixture is not representative large-model inference.",
            "The request mutex serializes model admission, execution, and retirement.",
            (
                "Capacity rejection proves retained-record saturation, not active-work or transport-queue saturation."
                if campaign.name == RETENTION_CAPACITY_PROFILE_NAME
                else (
                    "Queued receive timeout proves the fixed accept-origin queued-expiry profile, not full-request timeout or application overload."
                    if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                    else "The successful profile contains no capacity-rejection evidence."
                )
            ),
            (
                "Queued sockets are never server-parsed; request-to-lease binding is a deterministic "
                "single-outstanding client-plan/transmit correlation, not server-parsed request attestation."
                if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                else "Every retained request root is correlated under its profile-specific producer ABI."
            ),
            (
                "The queued-timeout campaign is deterministic closed-loop pressure, not open-loop, "
                "transient, or general overload evidence; W6 queue latency and throughput include "
                "completed work only."
                if campaign.name == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                else "The campaign mode is closed-loop."
            ),
            "Logical queue and in-flight facts do not prove physical CPU parallelism.",
            "No GPU performance, fairness, power, energy, temperature, or foreign-OS result is inferred.",
            "AC and nominal constraint signals do not prove fixed clock frequency or a measured temperature.",
        ],
    }
    return encoded, manifest, verified


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify the bounded F1 native unary load campaign")
    parser.add_argument("producer", help="path to glacier-unary-server-process-test")
    parser.add_argument(
        "--profile",
        choices=tuple(CAMPAIGN_PROFILES),
        default=SUCCESSFUL_PROFILE_NAME,
        help="fixed native-load evidence profile",
    )
    parser.add_argument("--output", help="optional verified binary envelope output")
    parser.add_argument("--manifest-output", help="optional verified capture-manifest JSON output")
    parser.add_argument("--timeout-seconds", type=float, default=RUNNER_TIMEOUT_SECONDS)
    parser.add_argument(
        "--admission-interval-seconds",
        type=float,
        default=native_environment_admission.DEFAULT_INTERVAL_SECONDS,
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        encoded, manifest, verified = run_campaign(
            Path(arguments.producer),
            timeout_seconds=arguments.timeout_seconds,
            admission_interval_seconds=arguments.admission_interval_seconds,
            profile_name=arguments.profile,
        )
        if arguments.output:
            _atomic_write(Path(arguments.output), encoded)
        if arguments.manifest_output:
            _atomic_write(Path(arguments.manifest_output), _canonical_json(manifest))
    except (OSError, VerificationError, native_observer.ObservationError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    profile = verified.profile
    terminal_metric_name = (
        "queued_timeout_terminal_observation_p99_ns"
        if arguments.profile == QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
        else "terminal_response_p99_ns"
    )
    print(
        "ok native-unary-server-load-v1 profile=%s "
        "records=%d warmup=%d measured=%d "
        "http_first_byte_p99_ns=%d %s=%d "
        "throughput=%d/%dns publication_eligible=%s"
        % (
            arguments.profile,
            RECORD_COUNT,
            WARMUP_COUNT,
            MEASURED_COUNT,
            profile.first_byte_p99_ns,
            terminal_metric_name,
            profile.terminal_p99_ns,
            profile.throughput_numerator,
            profile.throughput_denominator_ns,
            str(manifest["publication_eligible"]).lower(),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
