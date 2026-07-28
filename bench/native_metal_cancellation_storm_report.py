#!/usr/bin/env python3
"""Verify the fixed W7b-b3 native Metal cancellation-storm campaign.

The portable Native Workload Report V1 verifier remains authoritative for the
wire layout, record chain, summary arithmetic, and terminal closure.  This
module independently locks the W7b-b3 profile: concurrent host-side
cancel-before-submit lanes, a full-capacity probe while both pins are live,
challenge-selected settlement order, and a real two-lane Metal control pair
after every block.

The cancelled records prove production-adapter cancellation before native
submission.  They do not claim post-submit GPU cancellation, physical command
overlap, device loss, utilization, residency, power, or performance.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
import struct
import sys
from typing import Any, Optional, Sequence, Tuple, Union

from bench import native_metal_workload_report as process_boundary
from bench import native_workload_report as portable


PRODUCER_ABI = 0x4757_434D_0000_0001

BLOCK_COUNT = 8
WAVES_PER_BLOCK = 8
WAVE_RECORD_COUNT = 3
CONTROL_RECORD_COUNT = 2
RECORDS_PER_BLOCK = (
    WAVES_PER_BLOCK * WAVE_RECORD_COUNT + CONTROL_RECORD_COUNT
)
WARMUP_BLOCK_COUNT = 1
MEASURED_BLOCK_COUNT = BLOCK_COUNT - WARMUP_BLOCK_COUNT

EXPECTED_RECORD_COUNT = BLOCK_COUNT * RECORDS_PER_BLOCK
EXPECTED_WARMUP_COUNT = WARMUP_BLOCK_COUNT * RECORDS_PER_BLOCK
EXPECTED_MEASURED_COUNT = MEASURED_BLOCK_COUNT * RECORDS_PER_BLOCK
EXPECTED_TOTAL_CANCELLED = BLOCK_COUNT * WAVES_PER_BLOCK * 2
EXPECTED_TOTAL_CAPACITY_REJECTED = BLOCK_COUNT * WAVES_PER_BLOCK
EXPECTED_TOTAL_COMPLETED = BLOCK_COUNT * CONTROL_RECORD_COUNT
EXPECTED_TOTAL_ADMITTED = (
    EXPECTED_TOTAL_CANCELLED + EXPECTED_TOTAL_COMPLETED
)
EXPECTED_MEASURED_CANCELLED = (
    MEASURED_BLOCK_COUNT * WAVES_PER_BLOCK * 2
)
EXPECTED_MEASURED_CAPACITY_REJECTED = (
    MEASURED_BLOCK_COUNT * WAVES_PER_BLOCK
)
EXPECTED_MEASURED_COMPLETED = (
    MEASURED_BLOCK_COUNT * CONTROL_RECORD_COUNT
)
EXPECTED_MEASURED_ADMITTED = (
    EXPECTED_MEASURED_CANCELLED + EXPECTED_MEASURED_COMPLETED
)

EXPECTED_MAX_IN_FLIGHT = 2
EXPECTED_QUEUE_COUNT = 2
EXPECTED_FLOW_COUNT = 2
EXPECTED_WORK_UNITS = 37 * 64
EXPECTED_LEASE_CHARGED_BYTES = 5_544
EXPECTED_CLOSURE_PERMITS = EXPECTED_TOTAL_ADMITTED
EXPECTED_EVENT_COUNT = BLOCK_COUNT * (WAVES_PER_BLOCK * 11 + 14)
EXPECTED_WIRE_BYTES = (
    portable.MINIMUM_ENCODED_BYTES
    + EXPECTED_RECORD_COUNT * portable.RECORD_WIRE_BYTES
)

WORKLOAD_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-workload-v1\x00"
)
PROFILE_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-profile-v1\x00"
)
SCHEDULE_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-schedule-v1\x00"
)
ARTIFACT_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-artifact-v1\x00"
)
BACKEND_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-backend-v1\x00"
)
RECORD_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-record-v1\x00"
)
ADMITTED_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-admitted-v1\x00"
)
CAPACITY_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-capacity-v1\x00"
)
HOST_SOURCE_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-host-source-v1\x00"
)
BUILD_DOMAIN = (
    b"glacier-w7b-metal-cancellation-storm-native-build-v1\x00"
)

CHALLENGE_ENVIRONMENT = (
    "GLACIER_NATIVE_METAL_CANCELLATION_STORM_REPORT_"
    "CHALLENGE_SHA256"
)

ACTION_CANCEL_LANE0 = 1
ACTION_CANCEL_LANE1 = 2
ACTION_CAPACITY_REJECTED = 3
ACTION_COMPLETED_LANE0 = 4
ACTION_COMPLETED_LANE1 = 5
ACTION_TAGS = (
    ACTION_CANCEL_LANE0,
    ACTION_CANCEL_LANE1,
    ACTION_CAPACITY_REJECTED,
    ACTION_COMPLETED_LANE0,
    ACTION_COMPLETED_LANE1,
)

ROLE_REQUEST = 1
ROLE_TERMINAL = 2
ROLE_COMPLETION = 3
ROLE_TIMING_UNSUPPORTED = 4
ROLE_ALLOCATION_UNSUPPORTED = 5
ROLE_ACTION_EVIDENCE = 6

METAL_DEVICE_INFO_ABI = 0x474D_4449_0000_0001
METAL_DISPATCH_OBSERVATION_ABI = 0x474D_4452_0000_0001
METAL_ASYNC_SUBMISSION_ABI = 0x474D_4153_0000_0001
METAL_ASYNC_COMPLETION_ABI = 0x474D_4143_0000_0001
METAL_ALLOCATION_ADAPTER_ABI = 0x474D_4141_0000_0001
METAL_ALLOCATION_OBSERVATION_ABI = 0x474D_414F_0000_0001
METAL_ALLOCATION_DISPATCH_OBSERVATION_ABI = (
    0x474D_444F_0000_0001
)
METAL_OBSERVER_IMPLEMENTATION_ABI = 0x474D_4F42_0000_0001
METAL_MAXIMUM_ASYNC_DISPATCH_SLOTS = 2

BASE_W6_ARTIFACT_SHA256 = bytes.fromhex(
    "caaac942fa939e74b4e5bdc6015b9155"
    "358470c10beaa611e298a3797105303c"
)
ZERO_DIGEST = bytes(32)

MODE_CLOSED = 0
EVIDENCE_PRODUCTION_NATIVE = 1
COHORT_WARMUP = 0
COHORT_MEASURED = 1
OUTCOME_COMPLETED = 0
OUTCOME_CAPACITY_REJECTED = 1
OUTCOME_FAILED = 2
OUTCOME_CANCELLED = 3
CORRECTNESS_NOT_APPLICABLE = 0
CORRECTNESS_CORRECT = 1
NO_QUEUE_SLOT = 0xFFFF_FFFF

EVENT_ARRIVAL = 1 << 0
EVENT_ADMISSION = 1 << 1
EVENT_FIRST_SERVICE = 1 << 2
EVENT_SUBMIT_RETURN = 1 << 3
EVENT_FIRST_OUTPUT = 1 << 4
EVENT_TERMINAL = 1 << 5
EVENT_SETTLEMENT = 1 << 6
EVENT_PRESENCE_ALL = (1 << portable.EVENT_COUNT) - 1
EVENT_CANCELLED = (
    EVENT_ARRIVAL | EVENT_ADMISSION | EVENT_TERMINAL | EVENT_SETTLEMENT
)
EVENT_CAPACITY_REJECTED = (
    EVENT_ARRIVAL | EVENT_TERMINAL | EVENT_SETTLEMENT
)

AVAILABILITY_MISSING = 0
AVAILABILITY_UNSUPPORTED = 2
AVAILABILITY_PRESENT = 3
METRIC_DEVICE_DURATION_TOTAL_NS = 2
METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES = 3
METRIC_AGGREGATE_REASON_DOMAIN = (
    b"glacier-native-workload-metric-aggregate-reason-v1\x00"
)
MAXIMUM_ABS_ERROR = 2.0e-5
RUNNER_TIMEOUT_SECONDS = 60.0


def _u8(value: int) -> bytes:
    return struct.pack("<B", value)


def _u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def _sha256_parts(*parts: bytes) -> bytes:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
    return digest.digest()


SCHEDULE_TUPLE = (
    PRODUCER_ABI,
    BLOCK_COUNT,
    WAVES_PER_BLOCK,
    WARMUP_BLOCK_COUNT,
    WAVE_RECORD_COUNT,
    CONTROL_RECORD_COUNT,
    EXPECTED_FLOW_COUNT,
    METAL_MAXIMUM_ASYNC_DISPATCH_SLOTS,
    EXPECTED_LEASE_CHARGED_BYTES,
    EXPECTED_CLOSURE_PERMITS,
    *ACTION_TAGS,
)
EXPECTED_SCHEDULE_SHA256 = _sha256_parts(
    SCHEDULE_DOMAIN,
    *(_u64(value) for value in SCHEDULE_TUPLE),
)
EXPECTED_WORKLOAD_SHA256 = _sha256_parts(
    WORKLOAD_DOMAIN,
    _u64(PRODUCER_ABI),
    _u64(64),
    _u64(37),
    _u64(8),
    _u64(EXPECTED_WORK_UNITS),
)
EXPECTED_PROFILE_SHA256 = _sha256_parts(
    PROFILE_DOMAIN,
    EXPECTED_SCHEDULE_SHA256,
    *(_u64(value) for value in SCHEDULE_TUPLE),
)
EXPECTED_ARTIFACT_SHA256 = _sha256_parts(
    ARTIFACT_DOMAIN,
    _u64(PRODUCER_ABI),
    BASE_W6_ARTIFACT_SHA256,
)
EXPECTED_BACKEND_SHA256 = _sha256_parts(
    BACKEND_DOMAIN,
    _u64(PRODUCER_ABI),
    _u64(METAL_DEVICE_INFO_ABI),
    _u64(METAL_DISPATCH_OBSERVATION_ABI),
    _u64(METAL_ASYNC_SUBMISSION_ABI),
    _u64(METAL_ASYNC_COMPLETION_ABI),
    _u64(METAL_ALLOCATION_ADAPTER_ABI),
    _u64(METAL_ALLOCATION_OBSERVATION_ABI),
    _u64(METAL_ALLOCATION_DISPATCH_OBSERVATION_ABI),
)
EXPECTED_HOST_SOURCE_SHA256 = _sha256_parts(
    HOST_SOURCE_DOMAIN,
    _u64(PRODUCER_ABI),
    EXPECTED_SCHEDULE_SHA256,
)
EXPECTED_HOST_CLOCK_SHA256 = hashlib.sha256(
    b"std.time.Timer monotonic nanoseconds/v1"
).digest()
EXPECTED_DEVICE_SOURCE_SHA256 = _sha256_parts(
    b"glacier-metal-observer-source-v1\x00",
    _u64(METAL_OBSERVER_IMPLEMENTATION_ABI),
    b"Metal.framework MTLDevice+MTLCommandBuffer direct adapter/v1",
)
EXPECTED_DEVICE_CLOCK_SHA256 = hashlib.sha256(
    b"MTLCommandBuffer.GPUStartTime+GPUEndTime seconds/v1"
).digest()
EXPECTED_ALLOCATION_AGGREGATE_REASON = _sha256_parts(
    METRIC_AGGREGATE_REASON_DOMAIN,
    _u8(METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES),
    _u8(2),
)


class NativeMetalCancellationStormReportError(ValueError):
    """The wire or process is not the fixed W7b-b3 campaign."""


@dataclass(frozen=True)
class DecodedCancellationStormReport:
    scenario: Any
    records: Tuple[Any, ...]
    summary: Any
    closure: Any
    report_sha256: bytes


@dataclass(frozen=True)
class NativeCancellationStormVerificationResult:
    record_count: int
    warmup_count: int
    measured_count: int
    cancelled_count: int
    completed_count: int
    wire_sha256: bytes
    report_sha256: bytes
    runner_sha256: bytes
    metallib_sha256: bytes
    retained_path: Optional[Path] = None


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise NativeMetalCancellationStormReportError(message)


def _expected_digest(value: bytes, label: str) -> bytes:
    _require(
        isinstance(value, (bytes, bytearray, memoryview)),
        "%s must be bytes" % label,
    )
    digest = bytes(value)
    _require(len(digest) == 32, "%s must be 32 bytes" % label)
    _require(digest != ZERO_DIGEST, "%s must be nonzero" % label)
    return digest


def _native_build_sha256(
    runner_sha256: bytes,
    metallib_sha256: bytes,
) -> bytes:
    runner = _expected_digest(
        runner_sha256,
        "native Metal cancellation-storm runner SHA-256",
    )
    metallib = _expected_digest(
        metallib_sha256,
        "native Metal shader library SHA-256",
    )
    return _sha256_parts(
        BUILD_DOMAIN,
        _u64(PRODUCER_ABI),
        runner,
        metallib,
    )


def _record_root(
    global_wave: int,
    action_tag: int,
    lane: int,
    role: int,
) -> bytes:
    block = global_wave // WAVES_PER_BLOCK
    wave = global_wave % WAVES_PER_BLOCK
    return _sha256_parts(
        RECORD_DOMAIN,
        EXPECTED_PROFILE_SHA256,
        _u64(PRODUCER_ABI),
        _u64(block),
        _u64(wave),
        _u64(action_tag),
        _u64(lane),
        _u64(role),
    )


def _terminal_rank(record: Any, peer: Any) -> int:
    return int(
        record.host.points[5].sequence
        > peer.host.points[5].sequence
    )


def _admitted_commitment(
    record: Any,
    global_wave: int,
    action_tag: int,
    terminal_rank: int,
) -> bytes:
    block = global_wave // WAVES_PER_BLOCK
    wave = global_wave % WAVES_PER_BLOCK
    lane = record.flow_id
    return _sha256_parts(
        ADMITTED_DOMAIN,
        EXPECTED_PROFILE_SHA256,
        _u64(PRODUCER_ABI),
        _u64(block),
        _u64(wave),
        _u64(action_tag),
        _u64(lane),
        _u64(terminal_rank),
        _u64(record.outcome),
        record.roots[0],
        record.roots[2],
        record.roots[7],
        record.roots[8],
        record.allocated_context.reason_sha256,
    )


def _capacity_generation_cursors(global_wave: int) -> Tuple[int, int]:
    block = global_wave // WAVES_PER_BLOCK
    wave = global_wave % WAVES_PER_BLOCK
    return (
        block * 18 + wave * 2 + 3,
        block * 2 + 1,
    )


def _capacity_root(
    global_wave: int,
    role: int,
) -> bytes:
    block = global_wave // WAVES_PER_BLOCK
    wave = global_wave % WAVES_PER_BLOCK
    probe_flow = global_wave & 1
    next_request, next_ticket = _capacity_generation_cursors(global_wave)
    return _sha256_parts(
        CAPACITY_DOMAIN,
        EXPECTED_PROFILE_SHA256,
        _u64(PRODUCER_ABI),
        _u64(block),
        _u64(wave),
        _u64(probe_flow),
        _u64(role),
        _u64(next_request),
        _u64(next_ticket),
    )


def _decode_after_portable_verification(
    encoded: bytes,
) -> DecodedCancellationStormReport:
    try:
        generic = portable.verify_wire(encoded)
    except portable.VerificationError as error:
        raise NativeMetalCancellationStormReportError(
            "portable workload verifier rejected W7b-b3 wire: %s" % error
        ) from error
    _require(
        generic.record_count == EXPECTED_RECORD_COUNT,
        "W7b-b3 campaign record count changed",
    )
    _require(
        generic.warmup_count == EXPECTED_WARMUP_COUNT,
        "W7b-b3 campaign warmup count changed",
    )
    _require(
        generic.measured_count == EXPECTED_MEASURED_COUNT,
        "W7b-b3 campaign measured count changed",
    )

    body_end = len(encoded) - portable.WIRE_DIGEST_BYTES
    body = portable._Reader(encoded[portable.HEADER_BYTES:body_end])
    scenario = portable._read_scenario(body)
    records = tuple(
        portable._read_record(body)
        for _ in range(EXPECTED_RECORD_COUNT)
    )
    summary = portable._read_summary(body)
    closure = portable._read_closure(body)
    report_sha256 = body.digest()
    _require(
        body.position == len(body.data),
        "portable-verified W7b-b3 body has trailing bytes",
    )
    _require(
        report_sha256 == generic.report_sha256,
        "portable result and W7b-b3 report root disagree",
    )
    return DecodedCancellationStormReport(
        scenario,
        records,
        summary,
        closure,
        report_sha256,
    )


def _assert_scenario(
    scenario: Any,
    expected_build_sha256: bytes,
    expected_challenge_sha256: bytes,
) -> None:
    expected_build = _expected_digest(
        expected_build_sha256,
        "expected W7b-b3 build identity",
    )
    expected_challenge = _expected_digest(
        expected_challenge_sha256,
        "expected W7b-b3 challenge",
    )
    _require(
        scenario.mode == MODE_CLOSED,
        "W7b-b3 campaign is not closed-loop",
    )
    _require(
        scenario.evidence == EVIDENCE_PRODUCTION_NATIVE,
        "W7b-b3 campaign is not production-native execution evidence",
    )
    _require(
        scenario.warmup_count == EXPECTED_WARMUP_COUNT
        and scenario.measured_count == EXPECTED_MEASURED_COUNT,
        "W7b-b3 cohort geometry changed",
    )
    _require(
        scenario.max_in_flight == EXPECTED_MAX_IN_FLIGHT
        and scenario.queue_count == EXPECTED_QUEUE_COUNT
        and scenario.flow_count == EXPECTED_FLOW_COUNT,
        "W7b-b3 logical scheduling geometry changed",
    )
    expected_invariant_identities = {
        0: EXPECTED_WORKLOAD_SHA256,
        1: EXPECTED_PROFILE_SHA256,
        2: EXPECTED_ARTIFACT_SHA256,
        3: expected_build,
        5: EXPECTED_BACKEND_SHA256,
        8: EXPECTED_HOST_SOURCE_SHA256,
        9: EXPECTED_HOST_CLOCK_SHA256,
        10: EXPECTED_DEVICE_SOURCE_SHA256,
        11: EXPECTED_DEVICE_CLOCK_SHA256,
        12: expected_challenge,
    }
    for index, expected in expected_invariant_identities.items():
        _require(
            scenario.identities[index] == expected,
            "W7b-b3 scenario identity %d changed" % index,
        )
    dynamic = tuple(scenario.identities[index] for index in (4, 6, 7))
    _require(
        all(identity != ZERO_DIGEST for identity in dynamic),
        "W7b-b3 machine, device, and placement identities must be nonzero",
    )
    _require(
        len(set(dynamic)) == len(dynamic),
        "W7b-b3 machine, device, and placement identities must be distinct",
    )


def _f64_from_bits(bits: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


def _assert_unsupported(
    record: Any,
    global_wave: int,
    action_tag: int,
    terminal_rank: Optional[int] = None,
) -> None:
    _require(
        record.device_timing.availability
        == AVAILABILITY_UNSUPPORTED,
        "W7b-b3 non-submit timing must be unsupported",
    )
    _require(
        record.allocated_context.availability
        == AVAILABILITY_UNSUPPORTED,
        "W7b-b3 non-submit allocation context must be unsupported",
    )
    if terminal_rank is None:
        _require(
            record.device_timing.reason_sha256
            == _capacity_root(
                global_wave,
                ROLE_TIMING_UNSUPPORTED,
            ),
            "W7b-b3 capacity timing reason changed",
        )
        _require(
            record.allocated_context.reason_sha256
            == _capacity_root(
                global_wave,
                ROLE_ALLOCATION_UNSUPPORTED,
            ),
            "W7b-b3 capacity allocation reason changed",
        )
        return

    _require(
        record.allocated_context.reason_sha256
        == _record_root(
            global_wave,
            action_tag,
            record.flow_id,
            ROLE_ACTION_EVIDENCE,
        ),
        "W7b-b3 cancellation evidence identity changed",
    )
    _require(
        record.device_timing.reason_sha256
        == _admitted_commitment(
            record,
            global_wave,
            action_tag,
            terminal_rank,
        ),
        "W7b-b3 admitted cancellation commitment changed",
    )


def _assert_cancelled(
    record: Any,
    peer: Any,
    global_wave: int,
    lane: int,
) -> None:
    action = (
        ACTION_CANCEL_LANE0 if lane == 0 else ACTION_CANCEL_LANE1
    )
    _require(
        record.outcome == OUTCOME_CANCELLED,
        "W7b-b3 cancellation outcome changed",
    )
    _require(
        record.flow_id == lane and record.adapter_queue_slot == lane,
        "W7b-b3 cancellation lane or queue slot changed",
    )
    _require(
        record.correctness == CORRECTNESS_NOT_APPLICABLE
        and record.maximum_abs_error_f64_bits == 0,
        "W7b-b3 cancellation has correctness evidence",
    )
    _require(
        record.host.presence_mask == EVENT_CANCELLED,
        "W7b-b3 cancellation lifecycle mask changed",
    )
    _require(
        tuple(root != ZERO_DIGEST for root in record.roots)
        == (True, False, True, False, False, False, False, True, True),
        "W7b-b3 cancellation roots changed",
    )
    logical = record.logical
    _require(
        logical.bank_acquisitions == 1
        and logical.bank_completions == 1
        and logical.bank_used_before == EXPECTED_LEASE_CHARGED_BYTES
        and logical.bank_used_after_settlement
        == EXPECTED_LEASE_CHARGED_BYTES
        and logical.pin_count_before == 1
        and logical.pin_count_after_settlement == 0
        and logical.dispatch_count_before == 0
        and logical.dispatch_count_after_settlement == 0
        and logical.native_command_count_before == 0
        and logical.native_command_count_after_settlement == 0,
        "W7b-b3 cancellation logical facts changed",
    )
    _assert_unsupported(
        record,
        global_wave,
        action,
        _terminal_rank(record, peer),
    )


def _assert_capacity(
    record: Any,
    global_wave: int,
) -> None:
    expected_flow = global_wave & 1
    _require(
        record.outcome == OUTCOME_CAPACITY_REJECTED,
        "W7b-b3 capacity outcome changed",
    )
    _require(
        record.flow_id == expected_flow
        and record.adapter_queue_slot == NO_QUEUE_SLOT,
        "W7b-b3 capacity flow or slot changed",
    )
    _require(
        record.correctness == CORRECTNESS_NOT_APPLICABLE
        and record.maximum_abs_error_f64_bits == 0,
        "W7b-b3 capacity record has correctness evidence",
    )
    _require(
        record.host.presence_mask == EVENT_CAPACITY_REJECTED,
        "W7b-b3 capacity lifecycle mask changed",
    )
    expected_roots = [ZERO_DIGEST] * 9
    expected_roots[0] = _capacity_root(global_wave, ROLE_REQUEST)
    expected_roots[7] = _capacity_root(global_wave, ROLE_TERMINAL)
    expected_roots[8] = _capacity_root(global_wave, ROLE_COMPLETION)
    _require(
        tuple(record.roots) == tuple(expected_roots),
        "W7b-b3 capacity roots or generation cursors changed",
    )
    _require(
        all(
            value == 0
            for value in (
                record.logical.bank_acquisitions,
                record.logical.bank_completions,
                record.logical.bank_used_before,
                record.logical.bank_used_after_settlement,
                record.logical.pin_count_before,
                record.logical.pin_count_after_settlement,
                record.logical.dispatch_count_before,
                record.logical.dispatch_count_after_settlement,
                record.logical.native_command_count_before,
                record.logical.native_command_count_after_settlement,
            )
        ),
        "W7b-b3 capacity record has logical ownership",
    )
    _assert_unsupported(
        record,
        global_wave,
        ACTION_CAPACITY_REJECTED,
    )


def _assert_completed(record: Any, lane: int) -> None:
    _require(
        record.outcome == OUTCOME_COMPLETED,
        "W7b-b3 Metal control did not complete",
    )
    _require(
        record.correctness == CORRECTNESS_CORRECT,
        "W7b-b3 Metal control did not pass its CPU oracle",
    )
    _require(
        record.flow_id == lane and record.adapter_queue_slot == lane,
        "W7b-b3 Metal control lane or queue slot changed",
    )
    _require(
        record.host.presence_mask == EVENT_PRESENCE_ALL,
        "W7b-b3 Metal control lacks a lifecycle event",
    )
    _require(
        all(root != ZERO_DIGEST for root in record.roots),
        "W7b-b3 Metal control lacks an evidence root",
    )
    error_value = _f64_from_bits(record.maximum_abs_error_f64_bits)
    _require(
        math.isfinite(error_value)
        and 0.0 <= error_value <= MAXIMUM_ABS_ERROR,
        "W7b-b3 Metal control exceeds its CPU-oracle bound",
    )
    _require(
        record.device_timing.availability == AVAILABILITY_PRESENT
        and record.device_timing.duration_ns > 0,
        "W7b-b3 Metal control lacks command-buffer timing",
    )
    _require(
        record.allocated_context.availability == AVAILABILITY_PRESENT
        and record.allocated_context.before_bytes > 0
        and record.allocated_context.after_bytes > 0,
        "W7b-b3 Metal control lacks allocated-size context",
    )
    logical = record.logical
    _require(
        logical.bank_acquisitions == 1
        and logical.bank_completions == 1
        and logical.bank_used_before == EXPECTED_LEASE_CHARGED_BYTES
        and logical.bank_used_after_settlement
        == EXPECTED_LEASE_CHARGED_BYTES
        and logical.pin_count_before == 1
        and logical.pin_count_after_settlement == 0
        and logical.dispatch_count_before == 1
        and logical.dispatch_count_after_settlement == 0
        and logical.native_command_count_before == 1
        and logical.native_command_count_after_settlement == 0,
        "W7b-b3 Metal control logical facts changed",
    )


def _present_sequences(record: Any) -> Tuple[int, ...]:
    return tuple(
        point.sequence
        for index, point in enumerate(record.host.points)
        if record.host.presence_mask & (1 << index)
    )


def _challenge_settlement_first_lane(
    challenge_sha256: bytes,
    global_wave: int,
) -> int:
    return (
        challenge_sha256[global_wave // 8]
        >> (global_wave % 8)
    ) & 1


def _assert_wave_schedule(
    records: Tuple[Any, ...],
    block: int,
    wave: int,
    challenge_sha256: bytes,
) -> None:
    global_wave = block * WAVES_PER_BLOCK + wave
    ordinal = block * RECORDS_PER_BLOCK + wave * WAVE_RECORD_COUNT
    lane0, lane1, capacity = records[ordinal : ordinal + 3]
    sequence_base = block * 102 + wave * 11
    lane0_terminal = lane0.host.points[5].sequence
    lane1_terminal = lane1.host.points[5].sequence
    _require(
        {lane0_terminal, lane1_terminal}
        == {sequence_base + 8, sequence_base + 9},
        "W7b-b3 wave %d terminal observation order changed"
        % global_wave,
    )
    first_settlement = _challenge_settlement_first_lane(
        challenge_sha256,
        global_wave,
    )
    settlement_sequences = [sequence_base + 11] * 2
    settlement_sequences[first_settlement] = sequence_base + 10
    expected = (
        (
            sequence_base + 1,
            sequence_base + 3,
            lane0_terminal,
            settlement_sequences[0],
        ),
        (
            sequence_base + 2,
            sequence_base + 4,
            lane1_terminal,
            settlement_sequences[1],
        ),
        (
            sequence_base + 5,
            sequence_base + 6,
            sequence_base + 7,
        ),
    )
    for record, expected_sequences in zip(
        (lane0, lane1, capacity),
        expected,
    ):
        _require(
            _present_sequences(record) == expected_sequences,
            "W7b-b3 wave %d host schedule changed" % global_wave,
        )
    _require(
        capacity.host.points[6].sequence
        < min(lane0_terminal, lane1_terminal)
        and max(lane0_terminal, lane1_terminal)
        < min(
            lane0.host.points[6].sequence,
            lane1.host.points[6].sequence,
        ),
        "W7b-b3 capacity/terminal/settlement boundary changed",
    )


def _assert_control_schedule(
    records: Tuple[Any, ...],
    block: int,
) -> None:
    ordinal = block * RECORDS_PER_BLOCK + WAVES_PER_BLOCK * 3
    lane0, lane1 = records[ordinal : ordinal + 2]
    sequence_base = block * 102 + WAVES_PER_BLOCK * 11
    expected = (
        tuple(sequence_base + value for value in (1, 3, 5, 7, 9, 11, 14)),
        tuple(sequence_base + value for value in (2, 4, 6, 8, 10, 12, 13)),
    )
    for record, expected_sequences in zip((lane0, lane1), expected):
        _require(
            _present_sequences(record) == expected_sequences,
            "W7b-b3 block %d control schedule changed" % block,
        )
    _require(
        lane1.host.points[6].sequence
        < lane0.host.points[6].sequence,
        "W7b-b3 control pair no longer settles in reverse order",
    )


def _assert_records_and_schedule(
    records: Tuple[Any, ...],
    challenge_sha256: bytes,
) -> None:
    for block in range(BLOCK_COUNT):
        cohort = (
            COHORT_WARMUP if block == 0 else COHORT_MEASURED
        )
        for wave in range(WAVES_PER_BLOCK):
            global_wave = block * WAVES_PER_BLOCK + wave
            ordinal = (
                block * RECORDS_PER_BLOCK + wave * WAVE_RECORD_COUNT
            )
            lane0, lane1, capacity = records[ordinal : ordinal + 3]
            for offset, record in enumerate((lane0, lane1, capacity)):
                _require(
                    record.ordinal == ordinal + offset,
                    "W7b-b3 record ordinal changed",
                )
                _require(
                    record.cohort == cohort,
                    "W7b-b3 record cohort changed",
                )
                _require(
                    record.work_units == EXPECTED_WORK_UNITS,
                    "W7b-b3 record work-unit geometry changed",
                )
                _require(
                    not record.fallback,
                    "W7b-b3 record reported fallback",
                )
            _assert_cancelled(lane0, lane1, global_wave, 0)
            _assert_cancelled(lane1, lane0, global_wave, 1)
            _assert_capacity(capacity, global_wave)
            _assert_wave_schedule(
                records,
                block,
                wave,
                challenge_sha256,
            )

        control_ordinal = (
            block * RECORDS_PER_BLOCK + WAVES_PER_BLOCK * 3
        )
        controls = records[control_ordinal : control_ordinal + 2]
        for lane, record in enumerate(controls):
            _require(
                record.ordinal == control_ordinal + lane,
                "W7b-b3 control ordinal changed",
            )
            _require(
                record.cohort == cohort,
                "W7b-b3 control cohort changed",
            )
            _require(
                record.work_units == EXPECTED_WORK_UNITS
                and not record.fallback,
                "W7b-b3 control geometry changed",
            )
            _assert_completed(record, lane)
        _assert_control_schedule(records, block)

    all_sequences = sorted(
        point.sequence
        for record in records
        for index, point in enumerate(record.host.points)
        if record.host.presence_mask & (1 << index)
    )
    _require(
        all_sequences == list(range(1, EXPECTED_EVENT_COUNT + 1)),
        "W7b-b3 global host event sequence is not exact and gap-free",
    )


def _assert_generation_roots(records: Tuple[Any, ...]) -> None:
    admitted = tuple(
        record
        for record in records
        if record.host.presence_mask & EVENT_ADMISSION
    )
    completed = tuple(
        record for record in records if record.outcome == OUTCOME_COMPLETED
    )
    cancelled = tuple(
        record for record in records if record.outcome == OUTCOME_CANCELLED
    )
    for root_index, expected_count, source, label in (
        (0, EXPECTED_RECORD_COUNT, records, "request"),
        (7, EXPECTED_RECORD_COUNT, records, "terminal"),
        (8, EXPECTED_RECORD_COUNT, records, "completion"),
        (2, EXPECTED_TOTAL_ADMITTED, admitted, "pin"),
        (1, EXPECTED_TOTAL_COMPLETED, completed, "ticket"),
        (3, EXPECTED_TOTAL_COMPLETED, completed, "dispatch"),
        (4, EXPECTED_TOTAL_COMPLETED, completed, "submission"),
    ):
        roots = tuple(record.roots[root_index] for record in source)
        _require(
            len(roots) == expected_count
            and len(set(roots)) == expected_count
            and ZERO_DIGEST not in roots,
            "W7b-b3 %s roots do not prove unique generations" % label,
        )
    for record in cancelled:
        _require(
            all(
                record.roots[index] == ZERO_DIGEST
                for index in (1, 3, 4, 5, 6)
            ),
            "W7b-b3 cancellation has submit/output/oracle evidence",
        )
    capacity = tuple(
        record
        for record in records
        if record.outcome == OUTCOME_CAPACITY_REJECTED
    )
    for record in capacity:
        _require(
            all(
                record.roots[index] == ZERO_DIGEST
                for index in (1, 2, 3, 4, 5, 6)
            ),
            "W7b-b3 capacity record has admitted/submit evidence",
        )
    commitments = tuple(
        record.device_timing.reason_sha256 for record in cancelled
    )
    action_evidence = tuple(
        record.allocated_context.reason_sha256 for record in cancelled
    )
    _require(
        len(set(commitments)) == EXPECTED_TOTAL_CANCELLED
        and ZERO_DIGEST not in commitments,
        "W7b-b3 cancellation commitments are not unique",
    )
    _require(
        len(set(action_evidence)) == EXPECTED_TOTAL_CANCELLED
        and ZERO_DIGEST not in action_evidence,
        "W7b-b3 cancellation evidence roots are not unique",
    )
    capacity_synthetic = {
        root
        for record in capacity
        for root in (
            *record.roots,
            record.device_timing.reason_sha256,
            record.allocated_context.reason_sha256,
        )
        if root != ZERO_DIGEST
    }
    actual_admitted = {
        root
        for record in admitted
        for root in (
            *record.roots,
            record.device_timing.reason_sha256,
            record.allocated_context.reason_sha256,
        )
        if root != ZERO_DIGEST
    }
    _require(
        capacity_synthetic.isdisjoint(actual_admitted),
        "W7b-b3 synthetic capacity evidence aliases admitted evidence",
    )


def _assert_summary(summary: Any, records: Tuple[Any, ...]) -> None:
    _require(
        summary.measured_records == EXPECTED_MEASURED_COUNT,
        "W7b-b3 measured summary count changed",
    )
    _require(
        summary.admitted_count == EXPECTED_MEASURED_ADMITTED
        and summary.completed_count == EXPECTED_MEASURED_COMPLETED
        and summary.cancelled_count == EXPECTED_MEASURED_CANCELLED
        and summary.capacity_rejected_count
        == EXPECTED_MEASURED_CAPACITY_REJECTED
        and summary.failed_count == 0
        and summary.timed_out_count == 0,
        "W7b-b3 measured outcome counts changed",
    )
    _require(
        summary.attempted_work_units
        == EXPECTED_MEASURED_COUNT * EXPECTED_WORK_UNITS
        and summary.completed_work_units
        == EXPECTED_MEASURED_COMPLETED * EXPECTED_WORK_UNITS,
        "W7b-b3 measured work totals changed",
    )
    _require(
        summary.logical_in_flight_high_water
        == EXPECTED_MAX_IN_FLIGHT,
        "W7b-b3 measured logical high-water changed",
    )
    _require(
        summary.flow_completion_min == MEASURED_BLOCK_COUNT
        and summary.flow_completion_max == MEASURED_BLOCK_COUNT
        and summary.flow_completion_spread == 0,
        "W7b-b3 measured completed flows are not balanced 7/7",
    )
    measured_flow_records = tuple(
        sum(
            record.cohort == COHORT_MEASURED
            and record.flow_id == flow
            for record in records
        )
        for flow in range(EXPECTED_FLOW_COUNT)
    )
    _require(
        measured_flow_records == (91, 91),
        "W7b-b3 measured record flows are not balanced 91/91",
    )
    _require(
        summary.fallback_count == 0,
        "W7b-b3 summary reported fallback",
    )
    _require(
        summary.correctness_correct_count == EXPECTED_MEASURED_COMPLETED
        and summary.correctness_incorrect_count == 0,
        "W7b-b3 summary correctness counts changed",
    )
    expected_samples = (
        (summary.admission, EXPECTED_MEASURED_ADMITTED, "admission"),
        (summary.queue, EXPECTED_MEASURED_COMPLETED, "queue"),
        (
            summary.first_output,
            EXPECTED_MEASURED_COMPLETED,
            "first-output",
        ),
        (summary.service, EXPECTED_MEASURED_COMPLETED, "service"),
        (summary.end_to_end, EXPECTED_MEASURED_COUNT, "end-to-end"),
        (
            summary.device_duration,
            EXPECTED_MEASURED_COMPLETED,
            "device-duration",
        ),
    )
    for distribution, count, label in expected_samples:
        _require(
            distribution.sample_count == count,
            "W7b-b3 %s distribution sample count changed" % label,
        )
    _require(
        not summary.allocated_context_max_available
        and summary.allocated_context_max_bytes == 0,
        "W7b-b3 mixed allocation coverage must remain unavailable",
    )
    expected_availability = (
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_PRESENT,
        AVAILABILITY_MISSING,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
    )
    _require(
        tuple(metric.availability for metric in summary.metrics)
        == expected_availability,
        "W7b-b3 metric availability profile changed",
    )
    measured_device_total = sum(
        record.device_timing.duration_ns
        for record in records
        if record.cohort == COHORT_MEASURED
        and record.outcome == OUTCOME_COMPLETED
    )
    device_metric = summary.metrics[METRIC_DEVICE_DURATION_TOTAL_NS]
    _require(
        device_metric.numerator == measured_device_total
        and device_metric.denominator == 1,
        "W7b-b3 measured device-duration total changed",
    )
    allocation_metric = summary.metrics[
        METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES
    ]
    _require(
        allocation_metric.numerator == 0
        and allocation_metric.denominator == 0
        and allocation_metric.reason_sha256
        == EXPECTED_ALLOCATION_AGGREGATE_REASON,
        "W7b-b3 mixed allocation aggregate reason changed",
    )


def _assert_closure(closure: Any) -> None:
    _require(
        closure.bank_count == 0
        and closure.pin_count == 0
        and closure.dispatch_count == 0
        and closure.native_command_count == 0
        and closure.native_buffer_count == 0,
        "W7b-b3 campaign retained live ownership",
    )
    _require(
        closure.acquisitions == EXPECTED_CLOSURE_PERMITS
        and closure.completions == EXPECTED_CLOSURE_PERMITS,
        "W7b-b3 closure permit totals changed",
    )
    _require(
        closure.zero_orphan,
        "W7b-b3 campaign did not close zero-orphan",
    )


def verify_native_wire(
    encoded_value: bytes,
    expected_runner_sha256: bytes,
    expected_metallib_sha256: bytes,
    expected_challenge_sha256: bytes,
) -> NativeCancellationStormVerificationResult:
    runner_sha256 = _expected_digest(
        expected_runner_sha256,
        "expected W7b-b3 runner SHA-256",
    )
    metallib_sha256 = _expected_digest(
        expected_metallib_sha256,
        "expected W7b-b3 Metal library SHA-256",
    )
    challenge_sha256 = _expected_digest(
        expected_challenge_sha256,
        "expected W7b-b3 challenge",
    )
    expected_build_sha256 = _native_build_sha256(
        runner_sha256,
        metallib_sha256,
    )
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "W7b-b3 workload report must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(
        len(encoded) == EXPECTED_WIRE_BYTES == 163_132,
        "W7b-b3 workload report has an unexpected byte length",
    )
    decoded = _decode_after_portable_verification(encoded)
    _assert_scenario(
        decoded.scenario,
        expected_build_sha256,
        challenge_sha256,
    )
    _assert_records_and_schedule(decoded.records, challenge_sha256)
    _assert_generation_roots(decoded.records)
    _assert_summary(decoded.summary, decoded.records)
    _assert_closure(decoded.closure)
    return NativeCancellationStormVerificationResult(
        EXPECTED_RECORD_COUNT,
        EXPECTED_WARMUP_COUNT,
        EXPECTED_MEASURED_COUNT,
        EXPECTED_TOTAL_CANCELLED,
        EXPECTED_TOTAL_COMPLETED,
        hashlib.sha256(encoded).digest(),
        decoded.report_sha256,
        runner_sha256,
        metallib_sha256,
    )


def _boundary_call(function: Any, *args: Any, **kwargs: Any) -> Any:
    try:
        return function(*args, **kwargs)
    except process_boundary.NativeMetalReportError as error:
        raise NativeMetalCancellationStormReportError(str(error)) from error


def verify_runner(
    runner: Union[str, os.PathLike],
    metallib: Union[str, os.PathLike],
    retain_artifact: Optional[Union[str, os.PathLike]] = None,
    timeout_seconds: float = RUNNER_TIMEOUT_SECONDS,
) -> NativeCancellationStormVerificationResult:
    path = os.fspath(runner)
    metallib_path = os.fspath(metallib)
    _require(bool(path), "missing W7b-b3 cancellation-storm runner")
    _require(bool(metallib_path), "missing W7b-b3 Metal shader library")
    runner_sha256 = _boundary_call(
        process_boundary._runner_file_sha256,
        path,
    )
    metallib_sha256 = _boundary_call(
        process_boundary._metallib_file_sha256,
        metallib_path,
    )
    _native_build_sha256(runner_sha256, metallib_sha256)
    challenge_sha256 = os.urandom(32)
    _require(
        challenge_sha256 != ZERO_DIGEST,
        "W7b-b3 random challenge must be nonzero",
    )
    try:
        returncode, stdout, stderr = _boundary_call(
            process_boundary._bounded_runner_output,
            [path],
            timeout_seconds,
            challenge_sha256,
            EXPECTED_WIRE_BYTES,
            CHALLENGE_ENVIRONMENT,
        )
    finally:
        _boundary_call(
            process_boundary._verify_components_unchanged,
            path,
            metallib_path,
            runner_sha256,
            metallib_sha256,
        )
    if returncode != 0:
        detail = stderr[:4096].decode("utf-8", errors="replace")
        raise NativeMetalCancellationStormReportError(
            "W7b-b3 cancellation-storm runner failed (%d): %s"
            % (returncode, detail)
        )
    _require(
        stderr == b"",
        "W7b-b3 cancellation-storm runner wrote to stderr",
    )
    result = verify_native_wire(
        stdout,
        runner_sha256,
        metallib_sha256,
        challenge_sha256,
    )
    if retain_artifact is None:
        return result
    retained_path = _boundary_call(
        process_boundary._write_retained_artifact,
        retain_artifact,
        stdout,
    )
    return NativeCancellationStormVerificationResult(
        result.record_count,
        result.warmup_count,
        result.measured_count,
        result.cancelled_count,
        result.completed_count,
        result.wire_sha256,
        result.report_sha256,
        result.runner_sha256,
        result.metallib_sha256,
        retained_path,
    )


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify one fixed production-native Metal "
            "cancellation-storm report"
        )
    )
    parser.add_argument(
        "--runner",
        required=True,
        help="zero-argument executable that emits the raw W7b-b3 wire",
    )
    parser.add_argument(
        "--metallib",
        required=True,
        help="exact Metal shader library linked into the build identity",
    )
    parser.add_argument(
        "--output",
        help="retain the raw wire atomically only after complete verification",
    )
    arguments = parser.parse_args(argv)
    try:
        result = verify_runner(
            arguments.runner,
            arguments.metallib,
            arguments.output,
        )
    except NativeMetalCancellationStormReportError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    retained = (
        " retained=%s" % result.retained_path
        if result.retained_path is not None
        else ""
    )
    print(
        "ok native-metal-cancellation-storm-report-v1 "
        "records=%d warmup=%d measured=%d cancelled=%d completed=%d "
        "wire_sha256=%s report_sha256=%s runner_sha256=%s "
        "metallib_sha256=%s%s"
        % (
            result.record_count,
            result.warmup_count,
            result.measured_count,
            result.cancelled_count,
            result.completed_count,
            result.wire_sha256.hex(),
            result.report_sha256.hex(),
            result.runner_sha256.hex(),
            result.metallib_sha256.hex(),
            retained,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
