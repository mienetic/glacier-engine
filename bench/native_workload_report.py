#!/usr/bin/env python3
"""Independent verifier for the native workload report V1 binary wire.

The verifier deliberately consumes only the fixed little-endian wire.  It does
not import the Zig implementation and has no JSON compatibility path.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import struct
import subprocess
import sys
from dataclasses import dataclass, replace
from typing import Iterable, List, Optional, Sequence, Tuple


MAGIC = b"GW6RPT01"
SCENARIO_ABI = 0x4757365300000001
RECORD_ABI = 0x4757365200000001
SUMMARY_ABI = 0x4757365500000001
CLOSURE_ABI = 0x4757364300000001
REPORT_ABI = 0x4757365000000001
WIRE_ABI = 0x4757365700000001

MAX_RECORDS = 256
NO_QUEUE_SLOT = 0xFFFFFFFF
WIRE_FLAGS = 1
EVENT_COUNT = 7
METRIC_COUNT = 12
EVENT_PRESENCE_ALL = (1 << EVENT_COUNT) - 1
EVENT_ARRIVAL = 1 << 0
EVENT_ADMISSION = 1 << 1
EVENT_FIRST_SERVICE = 1 << 2
EVENT_SUBMIT_RETURN = 1 << 3
EVENT_FIRST_OUTPUT = 1 << 4
EVENT_TERMINAL = 1 << 5
EVENT_SETTLEMENT = 1 << 6
CAPACITY_REJECTED_PRESENCE = (
    EVENT_ARRIVAL | EVENT_TERMINAL | EVENT_SETTLEMENT
)

HEADER_BYTES = 40
SCENARIO_WIRE_BYTES = 484
RECORD_WIRE_BYTES = 772
DISTRIBUTION_WIRE_BYTES = 40
METRIC_WIRE_BYTES = 120
SUMMARY_WIRE_BYTES = 1856
CLOSURE_WIRE_BYTES = 80
REPORT_ROOT_WIRE_BYTES = 32
WIRE_DIGEST_BYTES = 64
MINIMUM_ENCODED_BYTES = (
    HEADER_BYTES
    + SCENARIO_WIRE_BYTES
    + SUMMARY_WIRE_BYTES
    + CLOSURE_WIRE_BYTES
    + REPORT_ROOT_WIRE_BYTES
    + WIRE_DIGEST_BYTES
)
MAX_ENCODED_BYTES = MINIMUM_ENCODED_BYTES + MAX_RECORDS * RECORD_WIRE_BYTES
RUNNER_TIMEOUT_SECONDS = 30

SCENARIO_DOMAIN = b"glacier-native-workload-scenario-v1\x00"
RECORD_DOMAIN = b"glacier-native-workload-record-v1\x00"
SUMMARY_DOMAIN = b"glacier-native-workload-summary-v1\x00"
CLOSURE_DOMAIN = b"glacier-native-workload-closure-v1\x00"
REPORT_DOMAIN = b"glacier-native-workload-report-v1\x00"
BODY_DOMAIN = b"glacier-native-workload-body-wire-v1\x00"
FOOTER_DOMAIN = b"glacier-native-workload-footer-wire-v1\x00"
METRIC_REASON_DOMAIN = b"glacier-native-workload-metric-unsupported-v1\x00"
METRIC_AGGREGATE_REASON_DOMAIN = (
    b"glacier-native-workload-metric-aggregate-reason-v1\x00"
)

MODE_VALUES = frozenset((0, 1))
EVIDENCE_VALUES = frozenset((0, 1))
SUMMARY_ALGORITHM_VALUES = frozenset((0,))
COHORT_VALUES = frozenset((0, 1))
OUTCOME_VALUES = frozenset(range(5))
CORRECTNESS_VALUES = frozenset(range(3))
AVAILABILITY_VALUES = frozenset(range(4))
METRIC_KIND_VALUES = frozenset(range(METRIC_COUNT))

COHORT_WARMUP = 0
COHORT_MEASURED = 1
OUTCOME_COMPLETED = 0
OUTCOME_CAPACITY_REJECTED = 1
OUTCOME_FAILED = 2
OUTCOME_CANCELLED = 3
OUTCOME_TIMED_OUT = 4
CORRECTNESS_NOT_APPLICABLE = 0
AVAILABILITY_MISSING = 0
AVAILABILITY_DENIED = 1
AVAILABILITY_UNSUPPORTED = 2
AVAILABILITY_PRESENT = 3
METRIC_DEVICE_DURATION_TOTAL_NS = 2
METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES = 3
METRIC_PHYSICAL_QUEUE_DEPTH = 5
METRIC_PHYSICAL_PARALLELISM = 11

ZERO_DIGEST = b"\x00" * 32
MAX_U64 = (1 << 64) - 1


class VerificationError(ValueError):
    """The supplied process output is not a valid native workload report."""


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


def _hash_parts(domain: bytes, parts: Iterable[bytes]) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _nonzero_digest(value: bytes) -> bool:
    return value != ZERO_DIGEST


def _add_u64(left: int, right: int, label: str) -> int:
    value = left + right
    _require(value <= MAX_U64, "%s overflows u64" % label)
    return value


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        _require(
            length >= 0 and end <= len(self.data),
            "truncated wire at byte %d" % self.position,
        )
        value = self.data[self.position : end]
        self.position = end
        return value

    def u8(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> bytes:
        return self.take(32)

    def reserved(self, length: int) -> None:
        _require(
            self.take(length) == b"\x00" * length,
            "reserved bytes are nonzero",
        )

    def boolean(self) -> bool:
        value = self.u8()
        _require(value in (0, 1), "invalid boolean value")
        return bool(value)

    def enum(self, allowed: frozenset, label: str) -> int:
        value = self.u8()
        _require(value in allowed, "invalid %s enum" % label)
        return value


@dataclass(frozen=True)
class Scenario:
    abi_version: int
    mode: int
    evidence: int
    summary_algorithm: int
    warmup_count: int
    measured_count: int
    max_in_flight: int
    queue_count: int
    flow_count: int
    identities: Tuple[bytes, ...]
    scenario_sha256: bytes


@dataclass(frozen=True)
class EventPoint:
    ns: int
    sequence: int


@dataclass(frozen=True)
class HostEvents:
    presence_mask: int
    points: Tuple[EventPoint, ...]


@dataclass(frozen=True)
class DeviceTiming:
    availability: int
    raw_start_f64_bits: int
    raw_end_f64_bits: int
    duration_ns: int
    source_sha256: bytes
    clock_sha256: bytes
    reason_sha256: bytes


@dataclass(frozen=True)
class AllocatedContext:
    availability: int
    before_bytes: int
    after_bytes: int
    source_sha256: bytes
    reason_sha256: bytes


@dataclass(frozen=True)
class LogicalFacts:
    bank_acquisitions: int
    bank_completions: int
    bank_used_before: int
    bank_used_after_settlement: int
    pin_count_before: int
    pin_count_after_settlement: int
    dispatch_count_before: int
    dispatch_count_after_settlement: int
    native_command_count_before: int
    native_command_count_after_settlement: int


@dataclass(frozen=True)
class Record:
    abi_version: int
    ordinal: int
    cohort: int
    outcome: int
    correctness: int
    fallback: bool
    flow_id: int
    work_units: int
    adapter_queue_slot: int
    host: HostEvents
    roots: Tuple[bytes, ...]
    maximum_abs_error_f64_bits: int
    device_timing: DeviceTiming
    allocated_context: AllocatedContext
    logical: LogicalFacts
    previous_record_sha256: bytes
    record_sha256: bytes


@dataclass(frozen=True)
class Distribution:
    sample_count: int
    p50_ns: int
    p95_ns: int
    p99_ns: int
    max_ns: int


@dataclass(frozen=True)
class Metric:
    kind: int
    availability: int
    numerator: int
    denominator: int
    source_sha256: bytes
    clock_sha256: bytes
    reason_sha256: bytes


@dataclass(frozen=True)
class Summary:
    abi_version: int
    measured_records: int
    admitted_count: int
    completed_count: int
    capacity_rejected_count: int
    failed_count: int
    cancelled_count: int
    timed_out_count: int
    attempted_work_units: int
    completed_work_units: int
    interval_start_ns: int
    interval_end_ns: int
    interval_numerator_ns: int
    interval_denominator: int
    throughput_completed_work_numerator: int
    throughput_interval_denominator_ns: int
    admission: Distribution
    queue: Distribution
    first_output: Distribution
    service: Distribution
    end_to_end: Distribution
    device_duration: Distribution
    logical_in_flight_high_water: int
    flow_completion_min: int
    flow_completion_max: int
    flow_completion_spread: int
    fallback_count: int
    correctness_correct_count: int
    correctness_incorrect_count: int
    allocated_context_max_available: bool
    allocated_context_max_bytes: int
    metrics: Tuple[Metric, ...]
    summary_sha256: bytes


@dataclass(frozen=True)
class Closure:
    abi_version: int
    bank_count: int
    pin_count: int
    dispatch_count: int
    native_command_count: int
    native_buffer_count: int
    acquisitions: int
    completions: int
    zero_orphan: bool
    closure_sha256: bytes


@dataclass(frozen=True)
class VerificationResult:
    record_count: int
    warmup_count: int
    measured_count: int
    report_sha256: bytes


def _scenario_hash(value: Scenario) -> bytes:
    parts = [
        _u64(value.abi_version),
        _u8(value.mode),
        _u8(value.evidence),
        _u8(value.summary_algorithm),
        _u32(value.warmup_count),
        _u32(value.measured_count),
        _u32(value.max_in_flight),
        _u32(value.queue_count),
        _u32(value.flow_count),
    ]
    parts.extend(value.identities)
    return _hash_parts(SCENARIO_DOMAIN, parts)


def _record_hash(scenario_sha256: bytes, value: Record) -> bytes:
    parts = [
        scenario_sha256,
        _u64(value.abi_version),
        _u32(value.ordinal),
        _u8(value.cohort),
        _u8(value.outcome),
        _u8(value.correctness),
        _u8(int(value.fallback)),
        _u32(value.flow_id),
        _u64(value.work_units),
        _u32(value.adapter_queue_slot),
        _u8(value.host.presence_mask),
    ]
    for point in value.host.points:
        parts.extend((_u64(point.ns), _u64(point.sequence)))
    parts.extend(value.roots)
    parts.extend(
        (
            _u64(value.maximum_abs_error_f64_bits),
            _u8(value.device_timing.availability),
            _u64(value.device_timing.raw_start_f64_bits),
            _u64(value.device_timing.raw_end_f64_bits),
            _u64(value.device_timing.duration_ns),
            value.device_timing.source_sha256,
            value.device_timing.clock_sha256,
            value.device_timing.reason_sha256,
            _u8(value.allocated_context.availability),
            _u64(value.allocated_context.before_bytes),
            _u64(value.allocated_context.after_bytes),
            value.allocated_context.source_sha256,
            value.allocated_context.reason_sha256,
            _u32(value.logical.bank_acquisitions),
            _u32(value.logical.bank_completions),
            _u64(value.logical.bank_used_before),
            _u64(value.logical.bank_used_after_settlement),
            _u32(value.logical.pin_count_before),
            _u32(value.logical.pin_count_after_settlement),
            _u32(value.logical.dispatch_count_before),
            _u32(value.logical.dispatch_count_after_settlement),
            _u32(value.logical.native_command_count_before),
            _u32(value.logical.native_command_count_after_settlement),
            value.previous_record_sha256,
        )
    )
    return _hash_parts(RECORD_DOMAIN, parts)


def _distribution_parts(value: Distribution) -> Tuple[bytes, ...]:
    return (
        _u32(value.sample_count),
        _u64(value.p50_ns),
        _u64(value.p95_ns),
        _u64(value.p99_ns),
        _u64(value.max_ns),
    )


def _metric_parts(value: Metric) -> Tuple[bytes, ...]:
    return (
        _u8(value.kind),
        _u8(value.availability),
        _u64(value.numerator),
        _u64(value.denominator),
        value.source_sha256,
        value.clock_sha256,
        value.reason_sha256,
    )


def _summary_hash(value: Summary) -> bytes:
    parts: List[bytes] = [
        _u64(value.abi_version),
        _u32(value.measured_records),
        _u32(value.admitted_count),
        _u32(value.completed_count),
        _u32(value.capacity_rejected_count),
        _u32(value.failed_count),
        _u32(value.cancelled_count),
        _u32(value.timed_out_count),
        _u64(value.attempted_work_units),
        _u64(value.completed_work_units),
        _u64(value.interval_start_ns),
        _u64(value.interval_end_ns),
        _u64(value.interval_numerator_ns),
        _u64(value.interval_denominator),
        _u64(value.throughput_completed_work_numerator),
        _u64(value.throughput_interval_denominator_ns),
    ]
    for distribution in (
        value.admission,
        value.queue,
        value.first_output,
        value.service,
        value.end_to_end,
        value.device_duration,
    ):
        parts.extend(_distribution_parts(distribution))
    parts.extend(
        (
            _u32(value.logical_in_flight_high_water),
            _u32(value.flow_completion_min),
            _u32(value.flow_completion_max),
            _u32(value.flow_completion_spread),
            _u32(value.fallback_count),
            _u32(value.correctness_correct_count),
            _u32(value.correctness_incorrect_count),
            _u8(int(value.allocated_context_max_available)),
            _u64(value.allocated_context_max_bytes),
        )
    )
    for metric in value.metrics:
        parts.extend(_metric_parts(metric))
    return _hash_parts(SUMMARY_DOMAIN, parts)


def _closure_hash(value: Closure) -> bytes:
    return _hash_parts(
        CLOSURE_DOMAIN,
        (
            _u64(value.abi_version),
            _u32(value.bank_count),
            _u32(value.pin_count),
            _u32(value.dispatch_count),
            _u32(value.native_command_count),
            _u32(value.native_buffer_count),
            _u64(value.acquisitions),
            _u64(value.completions),
            _u8(int(value.zero_orphan)),
        ),
    )


def _report_hash(
    scenario_sha256: bytes,
    records: Sequence[Record],
    summary_sha256: bytes,
    closure_sha256: bytes,
) -> bytes:
    terminal_record = (
        records[-1].record_sha256 if records else scenario_sha256
    )
    return _hash_parts(
        REPORT_DOMAIN,
        (
            _u64(REPORT_ABI),
            scenario_sha256,
            _u32(len(records)),
            terminal_record,
            summary_sha256,
            closure_sha256,
        ),
    )


def _read_scenario(reader: _Reader) -> Scenario:
    start = reader.position
    abi_version = reader.u64()
    mode = reader.enum(MODE_VALUES, "mode")
    evidence = reader.enum(EVIDENCE_VALUES, "evidence")
    algorithm = reader.enum(
        SUMMARY_ALGORITHM_VALUES, "summary algorithm"
    )
    reader.reserved(1)
    warmup_count = reader.u32()
    measured_count = reader.u32()
    max_in_flight = reader.u32()
    queue_count = reader.u32()
    flow_count = reader.u32()
    reader.reserved(4)
    identities = tuple(reader.digest() for _ in range(13))
    scenario_sha256 = reader.digest()
    _require(
        reader.position - start == SCENARIO_WIRE_BYTES,
        "invalid scenario layout",
    )
    return Scenario(
        abi_version,
        mode,
        evidence,
        algorithm,
        warmup_count,
        measured_count,
        max_in_flight,
        queue_count,
        flow_count,
        identities,
        scenario_sha256,
    )


def _read_record(reader: _Reader) -> Record:
    start = reader.position
    abi_version = reader.u64()
    ordinal = reader.u32()
    cohort = reader.enum(COHORT_VALUES, "cohort")
    outcome = reader.enum(OUTCOME_VALUES, "outcome")
    correctness = reader.enum(CORRECTNESS_VALUES, "correctness")
    fallback = reader.boolean()
    flow_id = reader.u32()
    work_units = reader.u64()
    adapter_queue_slot = reader.u32()
    presence_mask = reader.u8()
    reader.reserved(3)
    points = tuple(
        EventPoint(reader.u64(), reader.u64()) for _ in range(EVENT_COUNT)
    )
    roots = tuple(reader.digest() for _ in range(9))
    maximum_abs_error_f64_bits = reader.u64()
    timing_availability = reader.enum(
        AVAILABILITY_VALUES, "device timing availability"
    )
    reader.reserved(7)
    device_timing = DeviceTiming(
        timing_availability,
        reader.u64(),
        reader.u64(),
        reader.u64(),
        reader.digest(),
        reader.digest(),
        reader.digest(),
    )
    allocation_availability = reader.enum(
        AVAILABILITY_VALUES, "allocated context availability"
    )
    reader.reserved(7)
    allocated_context = AllocatedContext(
        allocation_availability,
        reader.u64(),
        reader.u64(),
        reader.digest(),
        reader.digest(),
    )
    logical = LogicalFacts(
        reader.u32(),
        reader.u32(),
        reader.u64(),
        reader.u64(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
    )
    previous_record_sha256 = reader.digest()
    record_sha256 = reader.digest()
    _require(
        reader.position - start == RECORD_WIRE_BYTES,
        "invalid record layout",
    )
    return Record(
        abi_version,
        ordinal,
        cohort,
        outcome,
        correctness,
        fallback,
        flow_id,
        work_units,
        adapter_queue_slot,
        HostEvents(presence_mask, points),
        roots,
        maximum_abs_error_f64_bits,
        device_timing,
        allocated_context,
        logical,
        previous_record_sha256,
        record_sha256,
    )


def _read_distribution(reader: _Reader) -> Distribution:
    sample_count = reader.u32()
    reader.reserved(4)
    return Distribution(
        sample_count,
        reader.u64(),
        reader.u64(),
        reader.u64(),
        reader.u64(),
    )


def _read_metric(reader: _Reader) -> Metric:
    kind = reader.enum(METRIC_KIND_VALUES, "metric kind")
    availability = reader.enum(
        AVAILABILITY_VALUES, "metric availability"
    )
    reader.reserved(6)
    return Metric(
        kind,
        availability,
        reader.u64(),
        reader.u64(),
        reader.digest(),
        reader.digest(),
        reader.digest(),
    )


def _read_summary(reader: _Reader) -> Summary:
    start = reader.position
    abi_version = reader.u64()
    measured_records = reader.u32()
    admitted_count = reader.u32()
    completed_count = reader.u32()
    capacity_rejected_count = reader.u32()
    failed_count = reader.u32()
    cancelled_count = reader.u32()
    timed_out_count = reader.u32()
    attempted_work_units = reader.u64()
    completed_work_units = reader.u64()
    interval_start_ns = reader.u64()
    interval_end_ns = reader.u64()
    interval_numerator_ns = reader.u64()
    interval_denominator = reader.u64()
    throughput_completed_work_numerator = reader.u64()
    throughput_interval_denominator_ns = reader.u64()
    distributions = tuple(_read_distribution(reader) for _ in range(6))
    logical_in_flight_high_water = reader.u32()
    flow_completion_min = reader.u32()
    flow_completion_max = reader.u32()
    flow_completion_spread = reader.u32()
    fallback_count = reader.u32()
    correctness_correct_count = reader.u32()
    correctness_incorrect_count = reader.u32()
    allocated_context_max_available = reader.boolean()
    reader.reserved(7)
    allocated_context_max_bytes = reader.u64()
    metrics = tuple(_read_metric(reader) for _ in range(METRIC_COUNT))
    summary_sha256 = reader.digest()
    _require(
        reader.position - start == SUMMARY_WIRE_BYTES,
        "invalid summary layout",
    )
    return Summary(
        abi_version,
        measured_records,
        admitted_count,
        completed_count,
        capacity_rejected_count,
        failed_count,
        cancelled_count,
        timed_out_count,
        attempted_work_units,
        completed_work_units,
        interval_start_ns,
        interval_end_ns,
        interval_numerator_ns,
        interval_denominator,
        throughput_completed_work_numerator,
        throughput_interval_denominator_ns,
        distributions[0],
        distributions[1],
        distributions[2],
        distributions[3],
        distributions[4],
        distributions[5],
        logical_in_flight_high_water,
        flow_completion_min,
        flow_completion_max,
        flow_completion_spread,
        fallback_count,
        correctness_correct_count,
        correctness_incorrect_count,
        allocated_context_max_available,
        allocated_context_max_bytes,
        metrics,
        summary_sha256,
    )


def _read_closure(reader: _Reader) -> Closure:
    start = reader.position
    closure = Closure(
        reader.u64(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
        reader.u32(),
        reader.u64(),
        reader.u64(),
        reader.boolean(),
        ZERO_DIGEST,
    )
    reader.reserved(3)
    closure = replace(closure, closure_sha256=reader.digest())
    _require(
        reader.position - start == CLOSURE_WIRE_BYTES,
        "invalid closure layout",
    )
    return closure


def _validate_scenario(value: Scenario) -> None:
    _require(value.abi_version == SCENARIO_ABI, "invalid scenario ABI")
    _require(
        value.summary_algorithm == 0,
        "unsupported summary algorithm",
    )
    _require(value.measured_count > 0, "measured cohort is empty")
    _require(value.max_in_flight > 0, "max_in_flight is zero")
    _require(value.queue_count > 0, "queue_count is zero")
    _require(value.flow_count > 0, "flow_count is zero")
    _require(value.flow_count <= MAX_RECORDS, "flow_count exceeds bound")
    _require(
        value.warmup_count + value.measured_count <= MAX_RECORDS,
        "scenario record count exceeds bound",
    )
    _require(
        all(_nonzero_digest(identity) for identity in value.identities),
        "scenario identity is zero",
    )
    _require(
        value.scenario_sha256 == _scenario_hash(value),
        "scenario digest mismatch",
    )


def _bits_to_f64(bits: int) -> float:
    return struct.unpack("<d", _u64(bits))[0]


def _finite_nonnegative_bits(bits: int) -> bool:
    value = _bits_to_f64(bits)
    return math.isfinite(value) and value >= 0.0


def _device_duration_ns(start_bits: int, end_bits: int) -> Optional[int]:
    if not _finite_nonnegative_bits(start_bits):
        return None
    if not _finite_nonnegative_bits(end_bits):
        return None
    start = _bits_to_f64(start_bits)
    end = _bits_to_f64(end_bits)
    if end <= start:
        return None
    duration = (end - start) * 1_000_000_000.0
    if (
        not math.isfinite(duration)
        or duration < 1.0
        or duration >= float(MAX_U64)
    ):
        return None
    result = int(duration)
    return result if result != 0 else None


def _validate_host(host: HostEvents) -> None:
    _require(
        host.presence_mask & ~EVENT_PRESENCE_ALL == 0,
        "unknown host event presence bit",
    )
    previous_ns = 0
    previous_sequence = 0
    have_previous = False
    for index, point in enumerate(host.points):
        present = bool(host.presence_mask & (1 << index))
        if not present:
            _require(
                point.ns == 0 and point.sequence == 0,
                "absent host event has data",
            )
            continue
        _require(point.sequence != 0, "host event sequence is zero")
        if have_previous:
            _require(
                point.ns >= previous_ns,
                "host event timestamps are not causal",
            )
            _require(
                point.sequence > previous_sequence,
                "host event sequences are not causal",
            )
        previous_ns = point.ns
        previous_sequence = point.sequence
        have_previous = True


def _validate_device_timing(
    value: DeviceTiming, scenario: Scenario
) -> None:
    device_source = scenario.identities[10]
    device_clock = scenario.identities[11]
    _require(
        value.source_sha256 == device_source,
        "device timing source identity mismatch",
    )
    _require(
        value.clock_sha256 == device_clock,
        "device timing clock identity mismatch",
    )
    if value.availability == AVAILABILITY_PRESENT:
        _require(
            _finite_nonnegative_bits(value.raw_start_f64_bits)
            and _finite_nonnegative_bits(value.raw_end_f64_bits),
            "device timing has invalid f64 bits",
        )
        _require(
            _device_duration_ns(
                value.raw_start_f64_bits, value.raw_end_f64_bits
            )
            == value.duration_ns,
            "device timing duration mismatch",
        )
        _require(
            _nonzero_digest(value.source_sha256)
            and _nonzero_digest(value.clock_sha256),
            "present device timing identity is zero",
        )
        _require(
            value.reason_sha256 == ZERO_DIGEST,
            "present device timing has a reason",
        )
    else:
        _require(
            value.raw_start_f64_bits == 0
            and value.raw_end_f64_bits == 0
            and value.duration_ns == 0,
            "unavailable device timing has measurements",
        )
        _require(
            _nonzero_digest(value.source_sha256)
            and _nonzero_digest(value.clock_sha256)
            and _nonzero_digest(value.reason_sha256),
            "unavailable device timing lacks evidence",
        )


def _validate_allocated_context(
    value: AllocatedContext, scenario: Scenario
) -> None:
    _require(
        value.source_sha256 == scenario.identities[10],
        "allocated context source identity mismatch",
    )
    if value.availability == AVAILABILITY_PRESENT:
        _require(
            _nonzero_digest(value.source_sha256),
            "present allocated context source is zero",
        )
        _require(
            value.reason_sha256 == ZERO_DIGEST,
            "present allocated context has a reason",
        )
    else:
        _require(
            value.before_bytes == 0 and value.after_bytes == 0,
            "unavailable allocated context has measurements",
        )
        _require(
            _nonzero_digest(value.source_sha256)
            and _nonzero_digest(value.reason_sha256),
            "unavailable allocated context lacks evidence",
        )


def _validate_logical(value: LogicalFacts) -> None:
    _require(
        value.bank_acquisitions == value.bank_completions,
        "logical bank acquisitions are not locally completed",
    )
    _require(
        value.bank_used_after_settlement == value.bank_used_before,
        "logical bank use is not restored at settlement",
    )
    _require(
        value.pin_count_after_settlement == 0,
        "logical pins remain after settlement",
    )
    _require(
        value.dispatch_count_after_settlement == 0,
        "logical dispatches remain after settlement",
    )
    _require(
        value.native_command_count_after_settlement == 0,
        "logical commands remain after settlement",
    )


def _logical_is_zero(value: LogicalFacts) -> bool:
    return all(
        item == 0
        for item in (
            value.bank_acquisitions,
            value.bank_completions,
            value.bank_used_before,
            value.bank_used_after_settlement,
            value.pin_count_before,
            value.pin_count_after_settlement,
            value.dispatch_count_before,
            value.dispatch_count_after_settlement,
            value.native_command_count_before,
            value.native_command_count_after_settlement,
        )
    )


def _validate_record_fields(record: Record, scenario: Scenario) -> None:
    _require(record.abi_version == RECORD_ABI, "invalid record ABI")
    _require(record.work_units > 0, "record work_units is zero")
    _require(record.flow_id < scenario.flow_count, "record flow is out of range")
    _validate_host(record.host)

    mask = record.host.presence_mask
    has_admission = bool(mask & EVENT_ADMISSION)
    has_service = bool(mask & EVENT_FIRST_SERVICE)
    has_submit = bool(mask & EVENT_SUBMIT_RETURN)
    has_output = bool(mask & EVENT_FIRST_OUTPUT)
    _require(
        not has_service or has_admission,
        "service exists without admission",
    )
    _require(not has_submit or has_service, "submit exists without service")
    _require(not has_output or has_submit, "output exists without submit")
    _require(
        not record.fallback or has_admission,
        "fallback exists without admission",
    )
    _require(
        record.device_timing.availability != AVAILABILITY_PRESENT
        or has_submit,
        "present device timing exists without submit",
    )
    _require(
        record.allocated_context.availability != AVAILABILITY_PRESENT
        or has_admission,
        "present allocated context exists without admission",
    )
    _require(
        has_admission == (record.logical.bank_acquisitions != 0),
        "bank acquisition eligibility disagrees with admission",
    )
    _require(
        record.logical.pin_count_before == 0 or has_admission,
        "logical pin exists without admission",
    )
    _require(
        (
            record.logical.dispatch_count_before == 0
            and record.logical.native_command_count_before == 0
        )
        or has_submit,
        "logical dispatch or command exists without submit",
    )

    root_present = tuple(_nonzero_digest(root) for root in record.roots)
    if record.outcome == OUTCOME_COMPLETED:
        _require(mask == EVENT_PRESENCE_ALL, "completed event set is incomplete")
        _require(
            record.adapter_queue_slot != NO_QUEUE_SLOT,
            "completed record has no queue",
        )
        _require(
            record.correctness != CORRECTNESS_NOT_APPLICABLE,
            "completed record lacks correctness",
        )
        _require(all(root_present), "completed record root is missing")
        _require(
            _finite_nonnegative_bits(record.maximum_abs_error_f64_bits),
            "completed maximum error is invalid",
        )
    elif record.outcome == OUTCOME_CAPACITY_REJECTED:
        _require(
            mask == CAPACITY_REJECTED_PRESENCE,
            "capacity rejection event set is invalid",
        )
        _require(
            record.adapter_queue_slot == NO_QUEUE_SLOT,
            "capacity rejection has a queue",
        )
        _require(not record.fallback, "capacity rejection uses fallback")
        _require(
            record.correctness == CORRECTNESS_NOT_APPLICABLE,
            "capacity rejection has correctness",
        )
        _require(
            record.maximum_abs_error_f64_bits == 0,
            "capacity rejection has maximum error",
        )
        _require(
            root_present
            == (True, False, False, False, False, False, False, True, True),
            "capacity rejection roots are invalid",
        )
        _require(
            _logical_is_zero(record.logical),
            "capacity rejection has logical work facts",
        )
    else:
        _require(
            mask & CAPACITY_REJECTED_PRESENCE
            == CAPACITY_REJECTED_PRESENCE,
            "terminal record lacks mandatory events",
        )
        _require(
            record.maximum_abs_error_f64_bits == 0,
            "non-completed record has maximum error",
        )
        _require(
            root_present[0] and root_present[7] and root_present[8],
            "terminal record lacks mandatory roots",
        )
        _require(
            has_admission == root_present[2],
            "pin root disagrees with admission",
        )
        _require(
            has_submit == root_present[1],
            "ticket root disagrees with submit",
        )
        _require(
            has_submit == root_present[3] == root_present[4],
            "dispatch/submission roots disagree with submit",
        )
        _require(
            has_output == root_present[5] == root_present[6],
            "output/oracle roots disagree with output",
        )
        _require(
            has_output
            == (record.correctness != CORRECTNESS_NOT_APPLICABLE),
            "correctness disagrees with output",
        )

    if has_admission:
        _require(
            record.adapter_queue_slot != NO_QUEUE_SLOT,
            "admitted record has no queue",
        )
        _require(
            record.adapter_queue_slot < scenario.queue_count,
            "record queue is out of range",
        )
    else:
        _require(
            record.adapter_queue_slot == NO_QUEUE_SLOT,
            "unadmitted record has a queue",
        )

    _validate_device_timing(record.device_timing, scenario)
    _validate_allocated_context(record.allocated_context, scenario)
    _validate_logical(record.logical)


def _logical_high_water(
    records: Sequence[Record], measured_only: bool
) -> int:
    high_water = 0
    for candidate in records:
        if (
            (measured_only and candidate.cohort != COHORT_MEASURED)
            or not candidate.host.presence_mask & EVENT_ADMISSION
        ):
            continue
        sequence = candidate.host.points[1].sequence
        active = 0
        for record in records:
            if (
                (measured_only and record.cohort != COHORT_MEASURED)
                or not record.host.presence_mask & EVENT_ADMISSION
            ):
                continue
            if (
                record.host.points[1].sequence
                <= sequence
                < record.host.points[6].sequence
            ):
                active += 1
        high_water = max(high_water, active)
    return high_water


def _validate_campaign(
    scenario: Scenario, records: Sequence[Record]
) -> None:
    for previous, current in zip(records, records[1:]):
        _require(
            previous.host.points[0].sequence
            < current.host.points[0].sequence,
            "adjacent record arrivals are not sequence ordered",
        )

    if scenario.warmup_count:
        final_warmup_settlement = max(
            record.host.points[6].sequence
            for record in records[: scenario.warmup_count]
        )
        first_measured_arrival = min(
            record.host.points[0].sequence
            for record in records[scenario.warmup_count :]
        )
        _require(
            final_warmup_settlement < first_measured_arrival,
            "warmup and measured campaigns overlap",
        )

    _require(
        _logical_high_water(records, measured_only=False)
        <= scenario.max_in_flight,
        "campaign logical in-flight exceeds scenario maximum",
    )
    for left_index, left in enumerate(records):
        if not left.host.presence_mask & EVENT_ADMISSION:
            continue
        for right in records[left_index + 1 :]:
            if (
                not right.host.presence_mask & EVENT_ADMISSION
                or left.adapter_queue_slot != right.adapter_queue_slot
            ):
                continue
            overlaps = (
                left.host.points[1].sequence
                < right.host.points[6].sequence
                and right.host.points[1].sequence
                < left.host.points[6].sequence
            )
            _require(
                not overlaps,
                "adapter queue slot intervals overlap",
            )


def _validate_records(scenario: Scenario, records: Sequence[Record]) -> None:
    _require(
        len(records) == scenario.warmup_count + scenario.measured_count,
        "record count disagrees with scenario",
    )
    previous = scenario.scenario_sha256
    global_events: List[Tuple[int, int]] = []
    for index, record in enumerate(records):
        _validate_record_fields(record, scenario)
        _require(record.ordinal == index, "record ordinal is not canonical")
        expected_cohort = (
            COHORT_WARMUP
            if index < scenario.warmup_count
            else COHORT_MEASURED
        )
        _require(record.cohort == expected_cohort, "record cohort mismatch")
        _require(
            record.previous_record_sha256 == previous,
            "record chain predecessor mismatch",
        )
        _require(
            record.record_sha256
            == _record_hash(scenario.scenario_sha256, record),
            "record digest mismatch",
        )
        previous = record.record_sha256
        for event_index, point in enumerate(record.host.points):
            if not (record.host.presence_mask & (1 << event_index)):
                continue
            global_events.append((point.sequence, point.ns))
    global_events.sort()
    for previous, current in zip(global_events, global_events[1:]):
        _require(
            previous[0] != current[0],
            "host event sequence is globally duplicated",
        )
        _require(
            previous[1] <= current[1],
            "host event sequence contradicts timestamp order",
        )
    _validate_campaign(scenario, records)


def _nearest_rank(values: Sequence[int], percentile: int) -> int:
    ordered = sorted(values)
    rank = (percentile * len(ordered) + 99) // 100
    return ordered[rank - 1]


def _distribution(values: Sequence[int]) -> Distribution:
    if not values:
        return Distribution(0, 0, 0, 0, 0)
    return Distribution(
        len(values),
        _nearest_rank(values, 50),
        _nearest_rank(values, 95),
        _nearest_rank(values, 99),
        _nearest_rank(values, 100),
    )


def _latency_values(
    records: Sequence[Record], kind: str
) -> List[int]:
    values: List[int] = []
    for record in records:
        if record.cohort != COHORT_MEASURED:
            continue
        points = record.host.points
        mask = record.host.presence_mask
        if kind == "admission" and mask & EVENT_ADMISSION:
            values.append(points[1].ns - points[0].ns)
        elif kind == "queue" and mask & EVENT_FIRST_SERVICE:
            values.append(points[2].ns - points[1].ns)
        elif kind == "first_output" and mask & EVENT_FIRST_OUTPUT:
            values.append(points[4].ns - points[0].ns)
        elif kind == "service" and mask & EVENT_FIRST_SERVICE:
            values.append(points[5].ns - points[2].ns)
        elif kind == "end_to_end":
            values.append(points[6].ns - points[0].ns)
        elif (
            kind == "device_duration"
            and record.device_timing.availability == AVAILABILITY_PRESENT
        ):
            values.append(record.device_timing.duration_ns)
    return values


def _metric_aggregate_reason(kind: int, reason: int) -> bytes:
    return _hash_parts(
        METRIC_AGGREGATE_REASON_DOMAIN, (_u8(kind), _u8(reason))
    )


def _aggregate_availability(
    records: Sequence[Record], plane: str
) -> Tuple[int, bytes]:
    eligible = 0
    present = 0
    first_availability: Optional[int] = None
    first_reason = ZERO_DIGEST
    homogeneous = True
    for record in records:
        if record.cohort != COHORT_MEASURED:
            continue
        eligible_for_plane = (
            bool(record.host.presence_mask & EVENT_SUBMIT_RETURN)
            if plane == "device_timing"
            else bool(record.host.presence_mask & EVENT_ADMISSION)
        )
        if not eligible_for_plane:
            continue
        eligible += 1
        if plane == "device_timing":
            availability = record.device_timing.availability
            reason = record.device_timing.reason_sha256
        else:
            availability = record.allocated_context.availability
            reason = record.allocated_context.reason_sha256
        if availability == AVAILABILITY_PRESENT:
            present += 1
            continue
        if first_availability is None:
            first_availability = availability
            first_reason = reason
        elif first_availability != availability or first_reason != reason:
            homogeneous = False
    kind = (
        METRIC_DEVICE_DURATION_TOTAL_NS
        if plane == "device_timing"
        else METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES
    )
    if eligible == 0:
        return (
            AVAILABILITY_MISSING,
            _metric_aggregate_reason(kind, 1),
        )
    if present == eligible:
        return (AVAILABILITY_PRESENT, ZERO_DIGEST)
    if present == 0 and homogeneous:
        _require(
            first_availability is not None,
            "availability aggregation is inconsistent",
        )
        return (first_availability, first_reason)
    return (
        AVAILABILITY_MISSING,
        _metric_aggregate_reason(kind, 2),
    )


def _metric_domains(scenario: Scenario, kind: int) -> Tuple[bytes, bytes]:
    host_source = scenario.identities[8]
    host_clock = scenario.identities[9]
    device_source = scenario.identities[10]
    device_clock = scenario.identities[11]
    if kind in (0, 1):
        return (host_source, host_clock)
    if kind == METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES:
        return (device_source, host_clock)
    return (device_source, device_clock)


def _unsupported_metric(scenario: Scenario, kind: int) -> Metric:
    source, clock = _metric_domains(scenario, kind)
    return Metric(
        kind,
        AVAILABILITY_UNSUPPORTED,
        0,
        0,
        source,
        clock,
        _hash_parts(METRIC_REASON_DOMAIN, (_u8(kind),)),
    )


def _availability_metric(
    scenario: Scenario,
    kind: int,
    availability: int,
    reason: bytes,
    present_numerator: int,
) -> Metric:
    source, clock = _metric_domains(scenario, kind)
    if availability == AVAILABILITY_PRESENT:
        return Metric(
            kind,
            availability,
            present_numerator,
            1,
            source,
            clock,
            ZERO_DIGEST,
        )
    return Metric(kind, availability, 0, 0, source, clock, reason)


def _recompute_summary(
    scenario: Scenario, records: Sequence[Record]
) -> Summary:
    measured = [
        record for record in records if record.cohort == COHORT_MEASURED
    ]
    _require(measured, "measured cohort is empty")
    admitted_count = 0
    outcome_counts = [0] * 5
    attempted_work_units = 0
    completed_work_units = 0
    fallback_count = 0
    correctness_correct_count = 0
    correctness_incorrect_count = 0
    interval_start_ns: Optional[int] = None
    interval_end_ns = 0
    device_total = 0
    allocated_context_max_bytes = 0

    for record in measured:
        attempted_work_units = _add_u64(
            attempted_work_units, record.work_units, "attempted work"
        )
        if record.host.presence_mask & EVENT_ADMISSION:
            admitted_count += 1
        outcome_counts[record.outcome] += 1
        if record.outcome == OUTCOME_COMPLETED:
            completed_work_units = _add_u64(
                completed_work_units, record.work_units, "completed work"
            )
        if record.fallback:
            fallback_count += 1
        if record.correctness == 1:
            correctness_correct_count += 1
        elif record.correctness == 2:
            correctness_incorrect_count += 1
        arrival = record.host.points[0].ns
        settlement = record.host.points[6].ns
        interval_start_ns = (
            arrival
            if interval_start_ns is None
            else min(interval_start_ns, arrival)
        )
        interval_end_ns = max(interval_end_ns, settlement)
        if (
            record.host.presence_mask & EVENT_ADMISSION
            and record.allocated_context.availability
            == AVAILABILITY_PRESENT
        ):
            allocated_context_max_bytes = max(
                allocated_context_max_bytes,
                record.allocated_context.before_bytes,
                record.allocated_context.after_bytes,
            )

    _require(interval_start_ns is not None, "measurement interval is absent")
    _require(
        interval_end_ns > interval_start_ns,
        "measurement interval is not positive",
    )
    interval_numerator_ns = interval_end_ns - interval_start_ns
    device_availability, device_reason = _aggregate_availability(
        records, "device_timing"
    )
    if device_availability == AVAILABILITY_PRESENT:
        for record in measured:
            if (
                record.host.presence_mask & EVENT_SUBMIT_RETURN
                and record.device_timing.availability
                == AVAILABILITY_PRESENT
            ):
                device_total = _add_u64(
                    device_total,
                    record.device_timing.duration_ns,
                    "device duration total",
                )
    allocation_availability, allocation_reason = _aggregate_availability(
        records, "allocated_context"
    )
    allocated_context_max_available = (
        allocation_availability == AVAILABILITY_PRESENT
    )
    if not allocated_context_max_available:
        allocated_context_max_bytes = 0

    high_water = _logical_high_water(records, measured_only=True)
    _require(
        high_water <= scenario.max_in_flight,
        "logical in-flight exceeds scenario maximum",
    )
    completions_per_flow = [
        sum(
            1
            for record in measured
            if record.flow_id == flow
            and record.outcome == OUTCOME_COMPLETED
        )
        for flow in range(scenario.flow_count)
    ]
    flow_min = min(completions_per_flow)
    flow_max = max(completions_per_flow)

    metrics = [
        _unsupported_metric(scenario, kind)
        for kind in range(METRIC_COUNT)
    ]
    metrics[METRIC_DEVICE_DURATION_TOTAL_NS] = _availability_metric(
        scenario,
        METRIC_DEVICE_DURATION_TOTAL_NS,
        device_availability,
        device_reason,
        device_total,
    )
    metrics[
        METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES
    ] = _availability_metric(
        scenario,
        METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES,
        allocation_availability,
        allocation_reason,
        allocated_context_max_bytes,
    )

    summary = Summary(
        SUMMARY_ABI,
        scenario.measured_count,
        admitted_count,
        outcome_counts[OUTCOME_COMPLETED],
        outcome_counts[OUTCOME_CAPACITY_REJECTED],
        outcome_counts[OUTCOME_FAILED],
        outcome_counts[OUTCOME_CANCELLED],
        outcome_counts[OUTCOME_TIMED_OUT],
        attempted_work_units,
        completed_work_units,
        interval_start_ns,
        interval_end_ns,
        interval_numerator_ns,
        1,
        completed_work_units,
        interval_numerator_ns,
        _distribution(_latency_values(records, "admission")),
        _distribution(_latency_values(records, "queue")),
        _distribution(_latency_values(records, "first_output")),
        _distribution(_latency_values(records, "service")),
        _distribution(_latency_values(records, "end_to_end")),
        _distribution(_latency_values(records, "device_duration")),
        high_water,
        flow_min,
        flow_max,
        flow_max - flow_min,
        fallback_count,
        correctness_correct_count,
        correctness_incorrect_count,
        allocated_context_max_available,
        allocated_context_max_bytes,
        tuple(metrics),
        ZERO_DIGEST,
    )
    return replace(summary, summary_sha256=_summary_hash(summary))


def _validate_closure(
    closure: Closure, records: Sequence[Record]
) -> None:
    _require(closure.abi_version == CLOSURE_ABI, "invalid closure ABI")
    _require(
        closure.bank_count == 0
        and closure.pin_count == 0
        and closure.dispatch_count == 0
        and closure.native_command_count == 0
        and closure.native_buffer_count == 0,
        "closure retains live resources",
    )
    _require(
        closure.acquisitions == closure.completions,
        "closure acquisitions and completions disagree",
    )
    _require(closure.zero_orphan, "closure is not orphan-free")
    _require(
        closure.closure_sha256 == _closure_hash(closure),
        "closure digest mismatch",
    )
    acquisitions = 0
    completions = 0
    for record in records:
        acquisitions = _add_u64(
            acquisitions,
            record.logical.bank_acquisitions,
            "closure acquisition sum",
        )
        completions = _add_u64(
            completions,
            record.logical.bank_completions,
            "closure completion sum",
        )
    _require(
        acquisitions == closure.acquisitions
        and completions == closure.completions,
        "closure totals disagree with records",
    )


def verify_wire(encoded: bytes) -> VerificationResult:
    """Parse and fully verify one native workload report V1 wire."""

    _require(
        isinstance(encoded, (bytes, bytearray, memoryview)),
        "wire must be bytes",
    )
    wire = bytes(encoded)
    _require(
        len(wire) >= MINIMUM_ENCODED_BYTES,
        "wire is shorter than the minimum encoding",
    )
    _require(
        len(wire) <= MAX_ENCODED_BYTES,
        "wire exceeds the maximum encoding",
    )
    reader = _Reader(wire)
    _require(reader.take(len(MAGIC)) == MAGIC, "invalid wire magic")
    _require(reader.u64() == WIRE_ABI, "invalid wire ABI")
    _require(reader.u64() == len(wire), "declared wire length mismatch")
    flags = reader.u32()
    _require(flags == WIRE_FLAGS, "invalid wire flags")
    reader.reserved(4)
    record_count = reader.u32()
    _require(record_count <= MAX_RECORDS, "record count exceeds bound")
    reader.reserved(4)
    _require(reader.position == HEADER_BYTES, "invalid header layout")
    expected_length = (
        MINIMUM_ENCODED_BYTES + record_count * RECORD_WIRE_BYTES
    )
    _require(len(wire) == expected_length, "record count/length mismatch")

    body_end = len(wire) - WIRE_DIGEST_BYTES
    stored_body_digest = wire[body_end : body_end + 32]
    stored_footer_digest = wire[body_end + 32 : body_end + 64]
    _require(
        stored_body_digest
        == _domain_hash(BODY_DOMAIN, wire[HEADER_BYTES:body_end]),
        "body digest mismatch",
    )
    _require(
        stored_footer_digest
        == _domain_hash(FOOTER_DOMAIN, wire[: body_end + 32]),
        "footer digest mismatch",
    )

    scenario = _read_scenario(reader)
    records = tuple(_read_record(reader) for _ in range(record_count))
    summary = _read_summary(reader)
    closure = _read_closure(reader)
    report_sha256 = reader.digest()
    _require(reader.position == body_end, "body layout mismatch")

    _validate_scenario(scenario)
    _require(
        record_count == scenario.warmup_count + scenario.measured_count,
        "header record count disagrees with scenario",
    )
    _validate_records(scenario, records)
    expected_summary = _recompute_summary(scenario, records)
    _require(summary == expected_summary, "summary is not reproducible")
    for kind in range(
        METRIC_PHYSICAL_QUEUE_DEPTH, METRIC_PHYSICAL_PARALLELISM + 1
    ):
        _require(
            summary.metrics[kind]
            == _unsupported_metric(scenario, kind),
            "physical metric is not forced unsupported",
        )
    _validate_closure(closure, records)
    _require(
        report_sha256
        == _report_hash(
            scenario.scenario_sha256,
            records,
            summary.summary_sha256,
            closure.closure_sha256,
        ),
        "report digest mismatch",
    )
    return VerificationResult(
        record_count,
        scenario.warmup_count,
        scenario.measured_count,
        report_sha256,
    )


def verify_runner(
    path: str,
    expected_wire_sha256: Optional[bytes] = None,
) -> VerificationResult:
    """Run a native producer and verify its raw stdout as the sole report."""

    try:
        completed = subprocess.run(
            [path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=RUNNER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError("runner could not be executed: %s" % error)
    _require(completed.returncode == 0, "runner exited nonzero")
    _require(completed.stderr == b"", "runner wrote to stderr")
    if expected_wire_sha256 is not None:
        _require(
            hashlib.sha256(completed.stdout).digest()
            == expected_wire_sha256,
            "runner wire digest mismatch",
        )
    return verify_wire(completed.stdout)


def _sha256_argument(value: str) -> bytes:
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "expected SHA-256 must be hexadecimal"
        ) from error
    if len(decoded) != 32:
        raise argparse.ArgumentTypeError(
            "expected SHA-256 must contain exactly 64 hexadecimal digits"
        )
    return decoded


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify a native workload report V1 runner"
    )
    parser.add_argument(
        "--runner",
        required=True,
        help="executable that emits exactly one raw report on stdout",
    )
    parser.add_argument(
        "--expected-wire-sha256",
        type=_sha256_argument,
        help="optional exact SHA-256 for a deterministic reference wire",
    )
    arguments = parser.parse_args(argv)
    try:
        result = verify_runner(
            arguments.runner,
            arguments.expected_wire_sha256,
        )
    except VerificationError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    print(
        "ok native-workload-report-v1 records=%d warmup=%d measured=%d "
        "report_sha256=%s"
        % (
            result.record_count,
            result.warmup_count,
            result.measured_count,
            result.report_sha256.hex(),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
