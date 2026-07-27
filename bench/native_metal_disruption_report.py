#!/usr/bin/env python3
"""Verify the fixed W7 production-native Metal disruption campaign.

The W6 wire verifier remains the authority for binary layout, record-chain,
summary, metric, and closure semantics.  This module adds the exact W7
250-record profile and a bounded zero-argument process boundary.  The
cancelled, malformed-pre-submit, and capacity outcomes are controlled
software disruptions around real production-adapter GPU commands; they are
not physical device-loss, driver-failure, utilization, residency, power, or
performance evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
from pathlib import Path
import struct
import sys
from dataclasses import dataclass
from typing import Any, Optional, Sequence, Tuple, Union

from bench import native_metal_workload_report as process_boundary
from bench import native_workload_report as portable


WARMUP_EPOCH_COUNT = 2
MEASURED_EPOCH_COUNT = 48
EPOCH_COUNT = WARMUP_EPOCH_COUNT + MEASURED_EPOCH_COUNT
RECORDS_PER_EPOCH = 5
EXPECTED_WARMUP_COUNT = WARMUP_EPOCH_COUNT * RECORDS_PER_EPOCH
EXPECTED_MEASURED_COUNT = MEASURED_EPOCH_COUNT * RECORDS_PER_EPOCH
EXPECTED_RECORD_COUNT = EPOCH_COUNT * RECORDS_PER_EPOCH
EXPECTED_MAX_IN_FLIGHT = 2
EXPECTED_QUEUE_COUNT = 2
EXPECTED_FLOW_COUNT = 2
EXPECTED_WORK_UNITS = 37 * 64
EXPECTED_LEASE_CHARGED_BYTES = 5_544
EXPECTED_WIRE_BYTES = (
    portable.MINIMUM_ENCODED_BYTES
    + EXPECTED_RECORD_COUNT * portable.RECORD_WIRE_BYTES
)

EXPECTED_TOTAL_COMPLETED = EPOCH_COUNT * 2
EXPECTED_TOTAL_ADMITTED = EPOCH_COUNT * 4
EXPECTED_MEASURED_COMPLETED = MEASURED_EPOCH_COUNT * 2
EXPECTED_MEASURED_CANCELLED = MEASURED_EPOCH_COUNT
EXPECTED_MEASURED_FAILED = MEASURED_EPOCH_COUNT
EXPECTED_MEASURED_CAPACITY_REJECTED = MEASURED_EPOCH_COUNT
EXPECTED_MEASURED_ADMITTED = MEASURED_EPOCH_COUNT * 4
EXPECTED_CLOSURE_PERMITS = EPOCH_COUNT * 4

PRODUCER_ABI = 0x4757_374D_0000_0001
BUILD_DOMAIN = b"glacier-w7-metal-native-build-v1\x00"
WORKLOAD_DOMAIN = b"glacier-w7-metal-native-workload-v1\x00"
PROFILE_DOMAIN = (
    b"glacier-w7-metal-controlled-disruption-profile-v1\x00"
)
ARTIFACT_DOMAIN = (
    b"glacier-w7-metal-controlled-disruption-artifact-v1\x00"
)
BACKEND_DOMAIN = b"glacier-w7-metal-production-backend-v1\x00"
SCHEDULE_DOMAIN = (
    b"glacier-w7-metal-controlled-disruption-schedule-v1\x00"
)
SYNTHETIC_RECORD_DOMAIN = (
    b"glacier-w7-metal-controlled-disruption-record-v1\x00"
)
ADMITTED_COMMITMENT_DOMAIN = (
    b"glacier-w7-metal-controlled-disruption-admitted-v1\x00"
)
CAPACITY_ROOT_DOMAIN = (
    b"glacier-w7-metal-controlled-disruption-capacity-v1\x00"
)
CHALLENGE_ENVIRONMENT = (
    "GLACIER_NATIVE_METAL_DISRUPTION_REPORT_CHALLENGE_SHA256"
)

ACTION_CANCEL = 1
ACTION_MALFORMED_PRE_SUBMIT = 2
ACTION_COMPLETED_LANE0 = 3
ACTION_COMPLETED_LANE1 = 4
ACTION_CAPACITY_REJECTED = 5
ACTION_TAGS = (
    ACTION_CANCEL,
    ACTION_MALFORMED_PRE_SUBMIT,
    ACTION_COMPLETED_LANE0,
    ACTION_COMPLETED_LANE1,
    ACTION_CAPACITY_REJECTED,
)
OUTCOME_PATTERN = (3, 2, 0, 0, 1)

ROLE_REQUEST = 1
ROLE_TERMINAL = 2
ROLE_COMPLETION = 3
ROLE_TIMING_UNSUPPORTED = 4
ROLE_ALLOCATION_UNSUPPORTED = 5
ROLE_ACTION_EVIDENCE = 6

DETAIL_CANCELLED_BEFORE_SUBMIT = 1
DETAIL_INVALID_HOST_LENGTHS = 2

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
EVENT_ADMITTED_NO_SUBMIT = (
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
    WARMUP_EPOCH_COUNT,
    MEASURED_EPOCH_COUNT,
    RECORDS_PER_EPOCH,
    EXPECTED_FLOW_COUNT,
    METAL_MAXIMUM_ASYNC_DISPATCH_SLOTS,
    EXPECTED_LEASE_CHARGED_BYTES,
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
EXPECTED_HOST_SOURCE_SHA256 = hashlib.sha256(
    b"std.time.Timer.read+global-sequence/metal-disruption-v1"
).digest()
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


class NativeMetalDisruptionReportError(ValueError):
    """The wire or process is not the fixed W7 Metal disruption campaign."""


@dataclass(frozen=True)
class DecodedDisruptionReport:
    scenario: Any
    records: Tuple[Any, ...]
    summary: Any
    closure: Any
    report_sha256: bytes


@dataclass(frozen=True)
class NativeDisruptionVerificationResult:
    record_count: int
    warmup_count: int
    measured_count: int
    completed_count: int
    wire_sha256: bytes
    report_sha256: bytes
    runner_sha256: bytes
    metallib_sha256: bytes
    retained_path: Optional[Path] = None


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise NativeMetalDisruptionReportError(message)


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
        "native Metal disruption runner SHA-256",
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


def _synthetic_root(
    epoch: int,
    action_tag: int,
    role: int,
) -> bytes:
    return _sha256_parts(
        SYNTHETIC_RECORD_DOMAIN,
        EXPECTED_PROFILE_SHA256,
        _u64(PRODUCER_ABI),
        _u64(epoch),
        _u64(action_tag),
        _u64(role),
    )

def _admitted_commitment(
    record: Any,
    epoch: int,
    action_tag: int,
    detail_tag: int,
) -> bytes:
    return _sha256_parts(
        ADMITTED_COMMITMENT_DOMAIN,
        EXPECTED_PROFILE_SHA256,
        _u64(PRODUCER_ABI),
        _u64(epoch),
        _u64(action_tag),
        _u64(detail_tag),
        _u64(record.outcome),
        _u64(record.flow_id),
        record.roots[0],
        record.roots[2],
        record.roots[7],
        record.roots[8],
        record.allocated_context.reason_sha256,
    )


def _capacity_root(
    epoch: int,
    role: int,
) -> bytes:
    return _sha256_parts(
        CAPACITY_ROOT_DOMAIN,
        EXPECTED_PROFILE_SHA256,
        _u64(PRODUCER_ABI),
        _u64(epoch),
        _u64(ACTION_CAPACITY_REJECTED),
        _u64(role),
        _u64(epoch * 4 + 5),
        _u64(epoch * 2 + 3),
    )


def _decode_after_portable_verification(
    encoded: bytes,
) -> DecodedDisruptionReport:
    try:
        generic = portable.verify_wire(encoded)
    except portable.VerificationError as error:
        raise NativeMetalDisruptionReportError(
            "portable workload verifier rejected W7 wire: %s" % error
        ) from error
    _require(
        generic.record_count == EXPECTED_RECORD_COUNT,
        "W7 campaign record count changed",
    )
    _require(
        generic.warmup_count == EXPECTED_WARMUP_COUNT,
        "W7 campaign warmup count changed",
    )
    _require(
        generic.measured_count == EXPECTED_MEASURED_COUNT,
        "W7 campaign measured count changed",
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
        "portable-verified W7 body has trailing bytes",
    )
    _require(
        report_sha256 == generic.report_sha256,
        "portable result and W7 report root disagree",
    )
    return DecodedDisruptionReport(
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
        "expected W7 build identity",
    )
    expected_challenge = _expected_digest(
        expected_challenge_sha256,
        "expected W7 challenge",
    )
    _require(scenario.mode == MODE_CLOSED, "W7 campaign is not closed-loop")
    _require(
        scenario.evidence == EVIDENCE_PRODUCTION_NATIVE,
        "W7 campaign is not production-native execution evidence",
    )
    _require(
        scenario.warmup_count == EXPECTED_WARMUP_COUNT
        and scenario.measured_count == EXPECTED_MEASURED_COUNT,
        "W7 cohort geometry changed",
    )
    _require(
        scenario.max_in_flight == EXPECTED_MAX_IN_FLIGHT
        and scenario.queue_count == EXPECTED_QUEUE_COUNT
        and scenario.flow_count == EXPECTED_FLOW_COUNT,
        "W7 logical scheduling geometry changed",
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
            "W7 scenario identity %d changed" % index,
        )
    dynamic = tuple(scenario.identities[index] for index in (4, 6, 7))
    _require(
        all(identity != ZERO_DIGEST for identity in dynamic),
        "W7 machine, device, and placement identities must be nonzero",
    )
    _require(
        len(set(dynamic)) == len(dynamic),
        "W7 machine, device, and placement identities must be distinct",
    )


def _f64_from_bits(bits: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


def _assert_unavailable(
    record: Any,
    epoch: int,
    action_tag: int,
    admitted_detail_tag: Optional[int] = None,
) -> None:
    _require(
        record.device_timing.availability
        == AVAILABILITY_UNSUPPORTED,
        "W7 non-submit timing must be unsupported",
    )
    _require(
        record.allocated_context.availability
        == AVAILABILITY_UNSUPPORTED,
        "W7 non-submit allocation context must be unsupported",
    )
    if admitted_detail_tag is None:
        _require(
            record.device_timing.reason_sha256
            == _synthetic_root(
                epoch,
                action_tag,
                ROLE_TIMING_UNSUPPORTED,
            ),
            "W7 non-submit timing reason changed",
        )
        _require(
            record.allocated_context.reason_sha256
            == _synthetic_root(
                epoch,
                action_tag,
                ROLE_ALLOCATION_UNSUPPORTED,
            ),
            "W7 non-submit allocation reason changed",
        )
        return

    action_evidence = record.allocated_context.reason_sha256
    _require(
        action_evidence != ZERO_DIGEST,
        "W7 admitted action evidence is missing",
    )
    if action_tag == ACTION_CANCEL:
        _require(
            action_evidence
            == _synthetic_root(
                epoch,
                action_tag,
                ROLE_ACTION_EVIDENCE,
            ),
            "W7 cancellation evidence identity changed",
        )
    else:
        synthetic_capacity = {
            _capacity_root(epoch, role)
            for role in (
                ROLE_REQUEST,
                ROLE_TERMINAL,
                ROLE_COMPLETION,
            )
        }
        synthetic_capacity.update(
            {
                _synthetic_root(
                    epoch,
                    ACTION_CAPACITY_REJECTED,
                    role,
                )
                for role in (
                    ROLE_TIMING_UNSUPPORTED,
                    ROLE_ALLOCATION_UNSUPPORTED,
                )
            }
        )
        _require(
            action_evidence not in synthetic_capacity,
            "W7 malformed rejection receipt is synthetic",
        )
    _require(
        record.device_timing.reason_sha256
        == _admitted_commitment(
            record,
            epoch,
            action_tag,
            admitted_detail_tag,
        ),
        "W7 admitted action/evidence commitment changed",
    )


def _assert_synthetic_terminal_roots(
    record: Any,
    epoch: int,
) -> None:
    for root_index, role, label in (
        (0, ROLE_REQUEST, "request"),
        (7, ROLE_TERMINAL, "terminal"),
        (8, ROLE_COMPLETION, "completion"),
    ):
        _require(
            record.roots[root_index]
            == _capacity_root(epoch, role),
            "W7 synthetic %s root changed" % label,
        )


def _assert_admitted_no_submit(
    record: Any,
    epoch: int,
    action_tag: int,
    expected_outcome: int,
    expected_flow: int,
    expected_detail: int,
) -> None:
    _require(
        record.outcome == expected_outcome,
        "W7 admitted non-submit outcome changed",
    )
    _require(
        record.flow_id == expected_flow
        and record.adapter_queue_slot == 0,
        "W7 admitted non-submit flow or slot changed",
    )
    _require(
        record.correctness == CORRECTNESS_NOT_APPLICABLE,
        "W7 admitted non-submit record has correctness",
    )
    _require(
        record.host.presence_mask == EVENT_ADMITTED_NO_SUBMIT,
        "W7 admitted non-submit event mask changed",
    )
    _require(
        tuple(root != ZERO_DIGEST for root in record.roots)
        == (True, False, True, False, False, False, False, True, True),
        "W7 admitted non-submit roots changed",
    )
    synthetic_capacity = {
        _capacity_root(epoch, role)
        for role in (
            ROLE_REQUEST,
            ROLE_TERMINAL,
            ROLE_COMPLETION,
        )
    }
    _require(
        not synthetic_capacity.intersection(
            (
                record.roots[0],
                record.roots[2],
                record.roots[7],
                record.roots[8],
            )
        ),
        "W7 admitted roots alias synthetic capacity evidence",
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
        "W7 admitted non-submit logical facts changed",
    )
    _assert_unavailable(
        record,
        epoch,
        action_tag,
        expected_detail,
    )


def _assert_completed(
    record: Any,
    expected_lane: int,
) -> None:
    _require(
        record.outcome == OUTCOME_COMPLETED,
        "W7 GPU lane did not complete",
    )
    _require(
        record.correctness == CORRECTNESS_CORRECT,
        "W7 GPU lane did not pass its CPU oracle",
    )
    _require(
        record.flow_id == expected_lane
        and record.adapter_queue_slot == expected_lane,
        "W7 GPU lane or queue slot changed",
    )
    _require(
        record.host.presence_mask == EVENT_PRESENCE_ALL,
        "W7 completed GPU record lacks a lifecycle event",
    )
    _require(
        all(root != ZERO_DIGEST for root in record.roots),
        "W7 completed GPU record lacks a root",
    )
    error_value = _f64_from_bits(record.maximum_abs_error_f64_bits)
    _require(
        math.isfinite(error_value)
        and 0.0 <= error_value <= MAXIMUM_ABS_ERROR,
        "W7 completed GPU record exceeds its CPU-oracle bound",
    )
    _require(
        record.device_timing.availability == AVAILABILITY_PRESENT
        and record.device_timing.duration_ns > 0,
        "W7 completed GPU record lacks command-buffer timing",
    )
    _require(
        record.allocated_context.availability == AVAILABILITY_PRESENT
        and record.allocated_context.before_bytes > 0
        and record.allocated_context.after_bytes > 0,
        "W7 completed GPU record lacks allocated-size context",
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
        "W7 completed GPU logical facts changed",
    )


def _assert_capacity_rejected(
    record: Any,
    epoch: int,
) -> None:
    _require(
        record.outcome == OUTCOME_CAPACITY_REJECTED,
        "W7 capacity probe outcome changed",
    )
    _require(
        record.flow_id == 0
        and record.adapter_queue_slot == NO_QUEUE_SLOT,
        "W7 capacity probe flow or slot changed",
    )
    _require(
        record.correctness == CORRECTNESS_NOT_APPLICABLE,
        "W7 capacity probe has correctness",
    )
    _require(
        record.host.presence_mask == EVENT_CAPACITY_REJECTED,
        "W7 capacity probe event mask changed",
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
        "W7 capacity probe has logical ownership",
    )
    _assert_synthetic_terminal_roots(
        record,
        epoch,
    )
    _assert_unavailable(
        record,
        epoch,
        ACTION_CAPACITY_REJECTED,
    )


def _assert_record(
    record: Any,
    ordinal: int,
) -> None:
    epoch = ordinal // RECORDS_PER_EPOCH
    position = ordinal % RECORDS_PER_EPOCH
    expected_cohort = (
        COHORT_WARMUP
        if epoch < WARMUP_EPOCH_COUNT
        else COHORT_MEASURED
    )
    _require(record.ordinal == ordinal, "W7 record ordinal changed")
    _require(record.cohort == expected_cohort, "W7 record cohort changed")
    _require(
        record.work_units == EXPECTED_WORK_UNITS,
        "W7 record work-unit geometry changed",
    )
    _require(not record.fallback, "W7 record reported fallback")
    _require(
        record.outcome == OUTCOME_PATTERN[position],
        "W7 five-record outcome pattern changed",
    )
    if position == 0:
        _assert_admitted_no_submit(
            record,
            epoch,
            ACTION_CANCEL,
            OUTCOME_CANCELLED,
            0,
            DETAIL_CANCELLED_BEFORE_SUBMIT,
        )
    elif position == 1:
        _assert_admitted_no_submit(
            record,
            epoch,
            ACTION_MALFORMED_PRE_SUBMIT,
            OUTCOME_FAILED,
            1,
            DETAIL_INVALID_HOST_LENGTHS,
        )
    elif position == 2:
        _assert_completed(record, 0)
    elif position == 3:
        _assert_completed(record, 1)
    else:
        _assert_capacity_rejected(record, epoch)


def _present_sequences(record: Any) -> Tuple[int, ...]:
    return tuple(
        point.sequence
        for index, point in enumerate(record.host.points)
        if record.host.presence_mask & (1 << index)
    )


def _assert_epoch_schedule(records: Tuple[Any, ...]) -> None:
    for epoch in range(EPOCH_COUNT):
        base = epoch * 25 + 1
        start = epoch * RECORDS_PER_EPOCH
        cancelled, failed, lane0, lane1, capacity = records[
            start : start + RECORDS_PER_EPOCH
        ]
        expected = (
            (base + 0, base + 1, base + 2, base + 3),
            (base + 4, base + 5, base + 6, base + 7),
            (
                base + 8,
                base + 10,
                base + 12,
                base + 14,
                base + 19,
                base + 21,
                base + 24,
            ),
            (
                base + 9,
                base + 11,
                base + 13,
                base + 15,
                base + 20,
                base + 22,
                base + 23,
            ),
            (base + 16, base + 17, base + 18),
        )
        for record, expected_sequences in zip(
            (cancelled, failed, lane0, lane1, capacity),
            expected,
        ):
            _require(
                _present_sequences(record) == expected_sequences,
                "W7 epoch %d event schedule changed" % epoch,
            )
        _require(
            cancelled.host.points[6].sequence
            < failed.host.points[0].sequence
            and failed.host.points[6].sequence
            < lane0.host.points[0].sequence,
            "W7 cancel/reject settlement no longer precedes GPU arrival",
        )
        _require(
            max(
                lane0.host.points[3].sequence,
                lane1.host.points[3].sequence,
            )
            < capacity.host.points[0].sequence
            < min(
                lane0.host.points[5].sequence,
                lane1.host.points[5].sequence,
            ),
            "W7 capacity probe is outside the active GPU pair",
        )
        _require(
            lane1.host.points[6].sequence
            < lane0.host.points[6].sequence,
            "W7 GPU pair no longer settles lane 1 before lane 0",
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
            "W7 %s roots do not prove unique generations" % label,
        )
    admitted_commitments = tuple(
        record.device_timing.reason_sha256
        for record in admitted
        if record.outcome in (OUTCOME_CANCELLED, OUTCOME_FAILED)
    )
    rejection_receipts = tuple(
        record.allocated_context.reason_sha256
        for record in admitted
        if record.outcome == OUTCOME_FAILED
    )
    _require(
        len(admitted_commitments) == EPOCH_COUNT * 2
        and len(set(admitted_commitments)) == EPOCH_COUNT * 2
        and ZERO_DIGEST not in admitted_commitments,
        "W7 admitted action commitments are not unique",
    )
    _require(
        len(rejection_receipts) == EPOCH_COUNT
        and len(set(rejection_receipts)) == EPOCH_COUNT
        and ZERO_DIGEST not in rejection_receipts,
        "W7 malformed rejection receipts are not unique",
    )
    synthetic_capacity_roots = {
        root
        for epoch in range(EPOCH_COUNT)
        for root in (
            _capacity_root(epoch, ROLE_REQUEST),
            _capacity_root(epoch, ROLE_TERMINAL),
            _capacity_root(epoch, ROLE_COMPLETION),
            _synthetic_root(
                epoch,
                ACTION_CAPACITY_REJECTED,
                ROLE_TIMING_UNSUPPORTED,
            ),
            _synthetic_root(
                epoch,
                ACTION_CAPACITY_REJECTED,
                ROLE_ALLOCATION_UNSUPPORTED,
            ),
        )
    }
    actual_non_capacity_roots = {
        root
        for record in records
        if record.outcome != OUTCOME_CAPACITY_REJECTED
        for root in record.roots
        if root != ZERO_DIGEST
    }
    actual_non_capacity_roots.update(rejection_receipts)
    _require(
        synthetic_capacity_roots.isdisjoint(
            actual_non_capacity_roots,
        ),
        "W7 actual evidence aliases synthetic capacity evidence",
    )


def _assert_summary(summary: Any, records: Tuple[Any, ...]) -> None:
    _require(
        summary.measured_records == EXPECTED_MEASURED_COUNT,
        "W7 measured summary count changed",
    )
    _require(
        summary.admitted_count == EXPECTED_MEASURED_ADMITTED
        and summary.completed_count == EXPECTED_MEASURED_COMPLETED
        and summary.cancelled_count == EXPECTED_MEASURED_CANCELLED
        and summary.failed_count == EXPECTED_MEASURED_FAILED
        and summary.capacity_rejected_count
        == EXPECTED_MEASURED_CAPACITY_REJECTED
        and summary.timed_out_count == 0,
        "W7 measured outcome counts changed",
    )
    _require(
        summary.attempted_work_units
        == EXPECTED_MEASURED_COUNT * EXPECTED_WORK_UNITS
        and summary.completed_work_units
        == EXPECTED_MEASURED_COMPLETED * EXPECTED_WORK_UNITS,
        "W7 measured work totals changed",
    )
    _require(
        summary.logical_in_flight_high_water
        == EXPECTED_MAX_IN_FLIGHT,
        "W7 measured logical high-water changed",
    )
    _require(
        summary.flow_completion_min == MEASURED_EPOCH_COUNT
        and summary.flow_completion_max == MEASURED_EPOCH_COUNT
        and summary.flow_completion_spread == 0,
        "W7 measured GPU flows are not balanced 48/48",
    )
    _require(summary.fallback_count == 0, "W7 summary reported fallback")
    _require(
        summary.correctness_correct_count == EXPECTED_MEASURED_COMPLETED
        and summary.correctness_incorrect_count == 0,
        "W7 summary correctness counts changed",
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
            "W7 %s distribution sample count changed" % label,
        )
    _require(
        not summary.allocated_context_max_available
        and summary.allocated_context_max_bytes == 0,
        "W7 mixed allocation coverage must remain unavailable",
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
        "W7 metric availability profile changed",
    )
    measured_device_total = sum(
        record.device_timing.duration_ns
        for record in records
        if record.cohort == COHORT_MEASURED
        and record.outcome == OUTCOME_COMPLETED
    )
    device_metric = summary.metrics[
        METRIC_DEVICE_DURATION_TOTAL_NS
    ]
    _require(
        device_metric.numerator == measured_device_total
        and device_metric.denominator == 1,
        "W7 measured device-duration total changed",
    )
    allocation_metric = summary.metrics[
        METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES
    ]
    _require(
        allocation_metric.numerator == 0
        and allocation_metric.denominator == 0
        and allocation_metric.reason_sha256
        == EXPECTED_ALLOCATION_AGGREGATE_REASON,
        "W7 mixed allocation aggregate reason changed",
    )


def _assert_closure(closure: Any) -> None:
    _require(
        closure.bank_count == 0
        and closure.pin_count == 0
        and closure.dispatch_count == 0
        and closure.native_command_count == 0
        and closure.native_buffer_count == 0,
        "W7 campaign retained live ownership",
    )
    _require(
        closure.acquisitions == EXPECTED_CLOSURE_PERMITS
        and closure.completions == EXPECTED_CLOSURE_PERMITS,
        "W7 closure permit totals changed",
    )
    _require(closure.zero_orphan, "W7 campaign did not close zero-orphan")


def verify_native_wire(
    encoded_value: bytes,
    expected_runner_sha256: bytes,
    expected_metallib_sha256: bytes,
    expected_challenge_sha256: bytes,
) -> NativeDisruptionVerificationResult:
    runner_sha256 = _expected_digest(
        expected_runner_sha256,
        "expected W7 runner SHA-256",
    )
    metallib_sha256 = _expected_digest(
        expected_metallib_sha256,
        "expected W7 Metal library SHA-256",
    )
    expected_build_sha256 = _native_build_sha256(
        runner_sha256,
        metallib_sha256,
    )
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "W7 workload report must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(
        len(encoded) == EXPECTED_WIRE_BYTES,
        "W7 workload report has an unexpected byte length",
    )
    decoded = _decode_after_portable_verification(encoded)
    _assert_scenario(
        decoded.scenario,
        expected_build_sha256,
        expected_challenge_sha256,
    )
    for ordinal, record in enumerate(decoded.records):
        _assert_record(record, ordinal)
    _assert_epoch_schedule(decoded.records)
    _assert_generation_roots(decoded.records)
    _assert_summary(decoded.summary, decoded.records)
    _assert_closure(decoded.closure)
    return NativeDisruptionVerificationResult(
        EXPECTED_RECORD_COUNT,
        EXPECTED_WARMUP_COUNT,
        EXPECTED_MEASURED_COUNT,
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
        raise NativeMetalDisruptionReportError(str(error)) from error


def verify_runner(
    runner: Union[str, os.PathLike],
    metallib: Union[str, os.PathLike],
    retain_artifact: Optional[Union[str, os.PathLike]] = None,
    timeout_seconds: float = RUNNER_TIMEOUT_SECONDS,
) -> NativeDisruptionVerificationResult:
    path = os.fspath(runner)
    metallib_path = os.fspath(metallib)
    _require(bool(path), "missing W7 Metal disruption runner")
    _require(bool(metallib_path), "missing W7 Metal shader library")
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
        "W7 campaign random challenge must be nonzero",
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
        raise NativeMetalDisruptionReportError(
            "W7 Metal disruption runner failed (%d): %s"
            % (returncode, detail)
        )
    _require(stderr == b"", "W7 Metal disruption runner wrote to stderr")
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
    return NativeDisruptionVerificationResult(
        result.record_count,
        result.warmup_count,
        result.measured_count,
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
            "Verify one fixed production-native Metal disruption report"
        )
    )
    parser.add_argument(
        "--runner",
        required=True,
        help="zero-argument executable that emits the raw W7 report wire",
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
    except NativeMetalDisruptionReportError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    retained = (
        " retained=%s" % result.retained_path
        if result.retained_path is not None
        else ""
    )
    print(
        "ok native-metal-disruption-report-v1 "
        "records=%d warmup=%d measured=%d completed=%d "
        "wire_sha256=%s report_sha256=%s runner_sha256=%s "
        "metallib_sha256=%s%s"
        % (
            result.record_count,
            result.warmup_count,
            result.measured_count,
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
