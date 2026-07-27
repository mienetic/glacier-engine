#!/usr/bin/env python3
"""Verify one bounded production Metal workload report.

The portable :mod:`bench.native_workload_report` module remains the authority
for the W6 V1 wire and summary semantics.  This module adds only the fixed
native Metal campaign profile and a bounded process-capture boundary.

The report proves internally composed evidence for one native campaign.  It
does not authenticate the producer or claim physical GPU parallelism,
utilization, residency, power, energy, thermals, frequency, or comparative
performance.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from typing import Any, List, Optional, Sequence, Tuple, Union

from bench import native_workload_report as portable


EXPECTED_RECORD_COUNT = 20
EXPECTED_WARMUP_COUNT = 4
EXPECTED_MEASURED_COUNT = 16
EXPECTED_MAX_IN_FLIGHT = 2
EXPECTED_QUEUE_COUNT = 2
EXPECTED_FLOW_COUNT = 2
EXPECTED_WORK_UNITS = 37 * 64
EXPECTED_LEASE_CHARGED_BYTES = 5_544
EXPECTED_WIRE_BYTES = (
    portable.MINIMUM_ENCODED_BYTES
    + EXPECTED_RECORD_COUNT * portable.RECORD_WIRE_BYTES
)

CHALLENGE_ENVIRONMENT = (
    "GLACIER_NATIVE_METAL_WORKLOAD_REPORT_CHALLENGE_SHA256"
)
PRODUCER_ABI = 0x4757_364D_0000_0001
BUILD_DOMAIN = b"glacier-w6-metal-native-build-v1\x00"
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


def _u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def _sha256_parts(*parts: bytes) -> bytes:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
    return digest.digest()


EXPECTED_WORKLOAD_SHA256 = _sha256_parts(
    b"glacier-w6-metal-native-workload-v1\x00",
    _u64(PRODUCER_ABI),
    _u64(64),
    _u64(37),
    _u64(8),
    _u64(EXPECTED_WORK_UNITS),
)
EXPECTED_PROFILE_SHA256 = _sha256_parts(
    b"glacier-w6-metal-native-profile-v1\x00",
    _u64(PRODUCER_ABI),
    _u64(EXPECTED_WARMUP_COUNT // EXPECTED_FLOW_COUNT),
    _u64(EXPECTED_MEASURED_COUNT // EXPECTED_FLOW_COUNT),
    _u64(EXPECTED_FLOW_COUNT),
    _u64(METAL_MAXIMUM_ASYNC_DISPATCH_SLOTS),
    _u64(EXPECTED_LEASE_CHARGED_BYTES),
)
# This is the producer's exact fixed payload-and-oracle root: the domain,
# producer ABI, generated packed weights, f32 scale bits, two lane inputs, and
# f32 fused-multiply-add CPU oracles in canonical lane order.
EXPECTED_ARTIFACT_SHA256 = bytes.fromhex(
    "caaac942fa939e74b4e5bdc6015b9155"
    "358470c10beaa611e298a3797105303c"
)
EXPECTED_BACKEND_SHA256 = _sha256_parts(
    b"glacier-w6-metal-production-backend-v1\x00",
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
    b"std.time.Timer.read+global-sequence/metal-workload-v1"
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
ZERO_DIGEST = bytes(32)

MODE_CLOSED = 0
EVIDENCE_PRODUCTION_NATIVE = 1
COHORT_WARMUP = 0
COHORT_MEASURED = 1
OUTCOME_COMPLETED = 0
CORRECTNESS_CORRECT = 1
AVAILABILITY_UNSUPPORTED = 2
AVAILABILITY_PRESENT = 3
EVENT_PRESENCE_ALL = (1 << portable.EVENT_COUNT) - 1

METRIC_CPU_TIME_NS = 0
METRIC_PROCESS_RSS_BYTES = 1
METRIC_DEVICE_DURATION_TOTAL_NS = 2
METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES = 3
METRIC_UTILIZATION_PPM = 4
METRIC_PHYSICAL_QUEUE_DEPTH = 5
METRIC_RESIDENCY_BYTES = 6
METRIC_POWER_MICROWATTS = 7
METRIC_ENERGY_MICROJOULES = 8
METRIC_TEMPERATURE_MILLIDEGREES_C = 9
METRIC_FREQUENCY_HZ = 10
METRIC_PHYSICAL_PARALLELISM = 11

MAXIMUM_ABS_ERROR = 2.0e-5
RUNNER_TIMEOUT_SECONDS = 60.0
RUNNER_TERMINATE_GRACE_SECONDS = 0.25
MAX_STDOUT_BYTES = EXPECTED_WIRE_BYTES
MAX_STDERR_BYTES = 64 * 1024


class NativeMetalReportError(ValueError):
    """The process output is not the fixed production Metal campaign."""


@dataclass(frozen=True)
class DecodedNativeReport:
    """Portable-verified component view used for native profile checks."""

    scenario: Any
    records: Tuple[Any, ...]
    summary: Any
    closure: Any
    report_sha256: bytes


@dataclass(frozen=True)
class NativeVerificationResult:
    """Addressable identity returned after all generic and profile checks."""

    record_count: int
    warmup_count: int
    measured_count: int
    wire_sha256: bytes
    report_sha256: bytes
    runner_sha256: bytes
    metallib_sha256: bytes
    retained_path: Optional[Path] = None


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise NativeMetalReportError(message)


def _f64_from_bits(bits: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


def _decode_after_portable_verification(
    encoded: bytes,
) -> DecodedNativeReport:
    """Return the portable parser's typed components after full verification.

    The private readers are deliberately used only after ``verify_wire`` has
    authenticated the complete fixed layout, hashes, chain, summary, and
    closure.  This keeps one semantic implementation while avoiding a second
    native-only wire parser.
    """

    generic = portable.verify_wire(encoded)
    _require(
        generic.record_count == EXPECTED_RECORD_COUNT,
        "native campaign record count changed",
    )
    _require(
        generic.warmup_count == EXPECTED_WARMUP_COUNT,
        "native campaign warmup count changed",
    )
    _require(
        generic.measured_count == EXPECTED_MEASURED_COUNT,
        "native campaign measured count changed",
    )

    body_end = len(encoded) - portable.WIRE_DIGEST_BYTES
    body = portable._Reader(encoded[portable.HEADER_BYTES:body_end])
    scenario = portable._read_scenario(body)
    records = tuple(
        portable._read_record(body) for _ in range(generic.record_count)
    )
    summary = portable._read_summary(body)
    closure = portable._read_closure(body)
    report_sha256 = body.digest()
    _require(
        body.position == len(body.data),
        "portable-verified native body has trailing bytes",
    )
    _require(
        report_sha256 == generic.report_sha256,
        "portable result and decoded report root disagree",
    )
    return DecodedNativeReport(
        scenario,
        records,
        summary,
        closure,
        report_sha256,
    )


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
    """Derive the producer build identity from both executable components."""

    runner = _expected_digest(
        runner_sha256,
        "native Metal report runner SHA-256",
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


def _assert_scenario(
    scenario: Any,
    expected_build_sha256: bytes,
    expected_challenge_sha256: bytes,
) -> None:
    expected_build = _expected_digest(
        expected_build_sha256,
        "expected native runner build identity",
    )
    expected_challenge = _expected_digest(
        expected_challenge_sha256,
        "expected native campaign challenge",
    )
    _require(scenario.mode == MODE_CLOSED, "native campaign must be closed-loop")
    _require(
        scenario.evidence == EVIDENCE_PRODUCTION_NATIVE,
        "native campaign is not production-native evidence",
    )
    _require(
        scenario.warmup_count == EXPECTED_WARMUP_COUNT,
        "native campaign warmup count changed",
    )
    _require(
        scenario.measured_count == EXPECTED_MEASURED_COUNT,
        "native campaign measured count changed",
    )
    _require(
        scenario.max_in_flight == EXPECTED_MAX_IN_FLIGHT,
        "native campaign logical in-flight bound changed",
    )
    _require(
        scenario.queue_count == EXPECTED_QUEUE_COUNT,
        "native campaign adapter queue count changed",
    )
    _require(
        scenario.flow_count == EXPECTED_FLOW_COUNT,
        "native campaign flow count changed",
    )
    _require(
        scenario.identities[0] == EXPECTED_WORKLOAD_SHA256,
        "native campaign workload identity changed",
    )
    _require(
        scenario.identities[1] == EXPECTED_PROFILE_SHA256,
        "native campaign profile identity changed",
    )
    _require(
        scenario.identities[2] == EXPECTED_ARTIFACT_SHA256,
        "native campaign artifact identity changed",
    )
    _require(
        scenario.identities[3] == expected_build,
        "native campaign runner build identity changed",
    )
    _require(
        scenario.identities[5] == EXPECTED_BACKEND_SHA256,
        "native campaign backend identity changed",
    )
    _require(
        scenario.identities[8] == EXPECTED_HOST_SOURCE_SHA256,
        "native campaign host source identity changed",
    )
    _require(
        scenario.identities[9] == EXPECTED_HOST_CLOCK_SHA256,
        "native campaign host clock identity changed",
    )
    _require(
        scenario.identities[10] == EXPECTED_DEVICE_SOURCE_SHA256,
        "native campaign device source identity changed",
    )
    _require(
        scenario.identities[11] == EXPECTED_DEVICE_CLOCK_SHA256,
        "native campaign device clock identity changed",
    )
    _require(
        scenario.identities[12] == expected_challenge,
        "native campaign challenge does not match this invocation",
    )
    dynamic_identities = (
        scenario.identities[4],
        scenario.identities[6],
        scenario.identities[7],
    )
    _require(
        all(identity != ZERO_DIGEST for identity in dynamic_identities),
        "native machine, device, and placement identities must be nonzero",
    )
    _require(
        len(set(dynamic_identities)) == len(dynamic_identities),
        "native machine, device, and placement identities must be distinct",
    )


def _assert_record(record: Any, ordinal: int) -> None:
    expected_cohort = (
        COHORT_WARMUP
        if ordinal < EXPECTED_WARMUP_COUNT
        else COHORT_MEASURED
    )
    expected_lane = ordinal % EXPECTED_FLOW_COUNT
    _require(record.ordinal == ordinal, "native record ordinal changed")
    _require(
        record.cohort == expected_cohort,
        "native record cohort changed",
    )
    _require(
        record.outcome == OUTCOME_COMPLETED,
        "native campaign contains a non-completed request",
    )
    _require(
        record.correctness == CORRECTNESS_CORRECT,
        "native request did not pass its CPU oracle",
    )
    _require(not record.fallback, "native request reported fallback")
    _require(record.flow_id == expected_lane, "native record flow changed")
    _require(
        record.adapter_queue_slot == expected_lane,
        "native record adapter queue slot changed",
    )
    _require(
        record.work_units == EXPECTED_WORK_UNITS,
        "native record work-unit geometry changed",
    )
    _require(
        record.host.presence_mask == EVENT_PRESENCE_ALL,
        "native completed record lacks a lifecycle event",
    )

    maximum_abs_error = _f64_from_bits(
        record.maximum_abs_error_f64_bits
    )
    _require(
        math.isfinite(maximum_abs_error)
        and 0.0 <= maximum_abs_error <= MAXIMUM_ABS_ERROR,
        "native record exceeds the fixed CPU-oracle error bound",
    )
    _require(
        record.device_timing.availability == AVAILABILITY_PRESENT,
        "native record lacks direct command-buffer timing",
    )
    _require(
        record.device_timing.duration_ns > 0,
        "native record has an empty command-buffer duration",
    )
    _require(
        record.allocated_context.availability == AVAILABILITY_PRESENT,
        "native record lacks allocated-size context",
    )

    logical = record.logical
    _require(
        logical.bank_acquisitions == 1
        and logical.bank_completions == 1,
        "native record must acquire and complete one dispatch permit",
    )
    _require(
        logical.bank_used_before == EXPECTED_LEASE_CHARGED_BYTES
        and logical.bank_used_after_settlement
        == EXPECTED_LEASE_CHARGED_BYTES,
        "native record no longer binds the persistent 5,544-byte lease",
    )
    _require(
        logical.pin_count_before == 1
        and logical.pin_count_after_settlement == 0,
        "native record pin facts changed",
    )
    _require(
        logical.dispatch_count_before == 1
        and logical.dispatch_count_after_settlement == 0,
        "native record dispatch facts changed",
    )
    _require(
        logical.native_command_count_before == 1
        and logical.native_command_count_after_settlement == 0,
        "native record command facts changed",
    )


def _assert_pair_lifecycle(records: Tuple[Any, ...]) -> None:
    for pair_start in range(0, len(records), EXPECTED_FLOW_COUNT):
        first = records[pair_start]
        second = records[pair_start + 1]
        latest_submit = max(
            first.host.points[3].sequence,
            second.host.points[3].sequence,
        )
        earliest_terminal = min(
            first.host.points[5].sequence,
            second.host.points[5].sequence,
        )
        _require(
            latest_submit < earliest_terminal,
            "native pair was not fully submitted before terminal observation",
        )
        _require(
            second.host.points[6].sequence
            < first.host.points[6].sequence,
            "native pair no longer settles slot 1 before slot 0",
        )
        if pair_start + EXPECTED_FLOW_COUNT < len(records):
            next_first = records[pair_start + EXPECTED_FLOW_COUNT]
            _require(
                max(
                    first.host.points[6].sequence,
                    second.host.points[6].sequence,
                )
                < next_first.host.points[0].sequence,
                "native slot pair was reused before both prior requests settled",
            )


def _assert_generation_roots(records: Tuple[Any, ...]) -> None:
    # Output and oracle roots may repeat when a fixed lane input is replayed.
    # Request, ticket, pin, dispatch, submission, terminal, and completion
    # roots must advance on every generation-fenced reuse.
    for root_index, label in (
        (0, "request"),
        (1, "ticket"),
        (2, "pin"),
        (3, "dispatch"),
        (4, "submission"),
        (7, "terminal"),
        (8, "completion"),
    ):
        roots = [record.roots[root_index] for record in records]
        _require(
            len(set(roots)) == EXPECTED_RECORD_COUNT,
            "native %s roots do not prove generation-fenced reuse" % label,
        )


def _assert_summary(summary: Any, records: Tuple[Any, ...]) -> None:
    _require(
        summary.measured_records == EXPECTED_MEASURED_COUNT,
        "native measured summary count changed",
    )
    _require(
        summary.admitted_count == EXPECTED_MEASURED_COUNT
        and summary.completed_count == EXPECTED_MEASURED_COUNT,
        "native measured cohort did not admit and complete every request",
    )
    _require(
        summary.capacity_rejected_count == 0
        and summary.failed_count == 0
        and summary.cancelled_count == 0
        and summary.timed_out_count == 0,
        "native measured cohort contains a terminal failure",
    )
    expected_work = EXPECTED_MEASURED_COUNT * EXPECTED_WORK_UNITS
    _require(
        summary.attempted_work_units == expected_work
        and summary.completed_work_units == expected_work,
        "native measured work totals changed",
    )
    _require(
        summary.logical_in_flight_high_water == EXPECTED_MAX_IN_FLIGHT,
        "native campaign did not exercise logical in-flight two",
    )
    _require(
        summary.flow_completion_min == EXPECTED_MEASURED_COUNT // 2
        and summary.flow_completion_max == EXPECTED_MEASURED_COUNT // 2
        and summary.flow_completion_spread == 0,
        "native measured flows are not balanced 8/8",
    )
    _require(summary.fallback_count == 0, "native summary reported fallback")
    _require(
        summary.correctness_correct_count == EXPECTED_MEASURED_COUNT
        and summary.correctness_incorrect_count == 0,
        "native summary correctness counts changed",
    )
    for distribution, label in (
        (summary.admission, "admission"),
        (summary.queue, "queue"),
        (summary.first_output, "first-output"),
        (summary.service, "service"),
        (summary.end_to_end, "end-to-end"),
        (summary.device_duration, "device-duration"),
    ):
        _require(
            distribution.sample_count == EXPECTED_MEASURED_COUNT,
            "native %s distribution lost measured samples" % label,
        )
    _require(
        summary.allocated_context_max_available,
        "native allocated-size aggregate is unavailable",
    )

    expected_availability = (
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_PRESENT,
        AVAILABILITY_PRESENT,
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
        "native metric availability profile changed",
    )
    device_total = sum(
        record.device_timing.duration_ns
        for record in records
        if record.cohort == COHORT_MEASURED
    )
    _require(
        summary.metrics[METRIC_DEVICE_DURATION_TOTAL_NS].numerator
        == device_total
        and summary.metrics[
            METRIC_DEVICE_DURATION_TOTAL_NS
        ].denominator
        == 1,
        "native device-duration metric changed",
    )
    _require(
        summary.metrics[
            METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES
        ].numerator
        == summary.allocated_context_max_bytes
        and summary.metrics[
            METRIC_CURRENT_ALLOCATED_SIZE_MAX_BYTES
        ].denominator
        == 1,
        "native allocated-size metric changed",
    )


def _assert_closure(closure: Any) -> None:
    _require(
        closure.bank_count == 0
        and closure.pin_count == 0
        and closure.dispatch_count == 0
        and closure.native_command_count == 0
        and closure.native_buffer_count == 0,
        "native campaign retained live ownership",
    )
    _require(
        closure.acquisitions == EXPECTED_RECORD_COUNT
        and closure.completions == EXPECTED_RECORD_COUNT,
        "native campaign closure permit totals changed",
    )
    _require(closure.zero_orphan, "native campaign did not close zero-orphan")


def verify_native_wire(
    encoded_value: bytes,
    expected_runner_sha256: bytes,
    expected_metallib_sha256: bytes,
    expected_challenge_sha256: bytes,
) -> NativeVerificationResult:
    """Verify generic W6 semantics and the exact production Metal profile."""

    runner_sha256 = _expected_digest(
        expected_runner_sha256,
        "expected native Metal report runner SHA-256",
    )
    metallib_sha256 = _expected_digest(
        expected_metallib_sha256,
        "expected native Metal shader library SHA-256",
    )
    expected_build_sha256 = _native_build_sha256(
        runner_sha256,
        metallib_sha256,
    )
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "native workload report must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(
        len(encoded) == EXPECTED_WIRE_BYTES,
        "native workload report has an unexpected byte length",
    )
    try:
        decoded = _decode_after_portable_verification(encoded)
    except portable.VerificationError as error:
        raise NativeMetalReportError(
            "portable workload verifier rejected native wire: %s" % error
        ) from error

    _assert_scenario(
        decoded.scenario,
        expected_build_sha256,
        expected_challenge_sha256,
    )
    for ordinal, record in enumerate(decoded.records):
        _assert_record(record, ordinal)
    _assert_pair_lifecycle(decoded.records)
    _assert_generation_roots(decoded.records)
    _assert_summary(decoded.summary, decoded.records)
    _assert_closure(decoded.closure)

    return NativeVerificationResult(
        EXPECTED_RECORD_COUNT,
        EXPECTED_WARMUP_COUNT,
        EXPECTED_MEASURED_COUNT,
        hashlib.sha256(encoded).digest(),
        decoded.report_sha256,
        runner_sha256,
        metallib_sha256,
    )


def _terminate_runner(process: subprocess.Popen[bytes]) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGTERM)
            return
        except (ProcessLookupError, PermissionError):
            pass
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        pass


def _kill_runner(process: subprocess.Popen[bytes]) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
            return
        except (ProcessLookupError, PermissionError):
            pass
    if process.poll() is not None:
        return
    try:
        process.kill()
    except ProcessLookupError:
        pass


def _bounded_runner_output(
    command: Sequence[str],
    timeout_seconds: float = RUNNER_TIMEOUT_SECONDS,
    challenge_sha256: Optional[bytes] = None,
    max_stdout_bytes: int = MAX_STDOUT_BYTES,
    challenge_environment: str = CHALLENGE_ENVIRONMENT,
) -> Tuple[int, bytes, bytes]:
    """Capture both pipes with strict bounds and terminate the process group."""

    try:
        valid_timeout = (
            not isinstance(timeout_seconds, bool)
            and math.isfinite(timeout_seconds)
            and timeout_seconds > 0
        )
    except (OverflowError, TypeError):
        valid_timeout = False
    if not valid_timeout:
        raise NativeMetalReportError("runner timeout must be positive")
    _require(
        not isinstance(max_stdout_bytes, bool)
        and isinstance(max_stdout_bytes, int)
        and max_stdout_bytes > 0,
        "runner stdout bound must be a positive integer",
    )
    _require(
        isinstance(challenge_environment, str)
        and bool(challenge_environment)
        and "=" not in challenge_environment
        and "\x00" not in challenge_environment,
        "runner challenge environment name is invalid",
    )
    _require(
        bool(command)
        and all(isinstance(item, str) and item for item in command),
        "missing or invalid native runner command",
    )
    environment = {"LC_ALL": "C", "PATH": os.defpath}
    if challenge_sha256 is not None:
        challenge = _expected_digest(
            challenge_sha256,
            "native runner challenge",
        )
        environment[challenge_environment] = challenge.hex()
    try:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            close_fds=True,
            start_new_session=os.name == "posix",
        )
    except (OSError, TypeError, ValueError) as error:
        raise NativeMetalReportError(
            "could not start native Metal report runner: %s" % error
        ) from error
    if process.stdout is None or process.stderr is None:
        _kill_runner(process)
        raise NativeMetalReportError("could not capture native runner output")

    stdout = bytearray()
    stderr = bytearray()
    failure: List[Tuple[str, str]] = []
    failure_lock = threading.Lock()
    wake = threading.Event()
    readers_done = [threading.Event(), threading.Event()]

    def fail(kind: str, detail: str) -> None:
        with failure_lock:
            if not failure:
                failure.append((kind, detail))
                _terminate_runner(process)
        wake.set()

    def drain(
        stream: Any,
        destination: bytearray,
        maximum: int,
        name: str,
        done: threading.Event,
    ) -> None:
        try:
            while True:
                remaining = maximum + 1 - len(destination)
                if remaining <= 0:
                    fail("bound", name)
                    return
                chunk = stream.read(min(64 * 1024, remaining))
                if not chunk:
                    return
                destination.extend(chunk)
                if len(destination) > maximum:
                    fail("bound", name)
                    return
        except (OSError, ValueError) as error:
            fail("capture", "%s: %s" % (name, error))
        finally:
            done.set()
            wake.set()

    threads = [
        threading.Thread(
            target=drain,
            args=(
                process.stdout,
                stdout,
                max_stdout_bytes,
                "stdout",
                readers_done[0],
            ),
            daemon=True,
        ),
        threading.Thread(
            target=drain,
            args=(
                process.stderr,
                stderr,
                MAX_STDERR_BYTES,
                "stderr",
                readers_done[1],
            ),
            daemon=True,
        ),
    ]
    for thread in threads:
        thread.start()

    deadline = time.monotonic() + timeout_seconds
    timed_out = False
    while True:
        if failure:
            break
        if (
            process.poll() is not None
            and readers_done[0].is_set()
            and readers_done[1].is_set()
        ):
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            _terminate_runner(process)
            break
        wake.wait(min(remaining, 0.01))
        wake.clear()

    if timed_out or failure:
        _terminate_runner(process)
        try:
            process.wait(timeout=RUNNER_TERMINATE_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            _kill_runner(process)
            try:
                process.wait(timeout=RUNNER_TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired as error:
                raise NativeMetalReportError(
                    "native Metal report runner could not be killed"
                ) from error
        if os.name == "posix":
            # The leader can exit while a descendant still owns a pipe.
            _kill_runner(process)
        for stream in (process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass

    for thread in threads:
        thread.join(timeout=RUNNER_TERMINATE_GRACE_SECONDS)
    if any(thread.is_alive() for thread in threads):
        for stream in (process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass
        for thread in threads:
            thread.join(timeout=RUNNER_TERMINATE_GRACE_SECONDS)
    if any(thread.is_alive() for thread in threads):
        raise NativeMetalReportError("native runner pipes did not close")
    for stream in (process.stdout, process.stderr):
        try:
            stream.close()
        except OSError:
            pass

    if timed_out:
        raise NativeMetalReportError(
            "native Metal report runner exceeded %gs timeout"
            % timeout_seconds
        )
    if failure:
        kind, detail = failure[0]
        if kind == "bound":
            maximum = (
                max_stdout_bytes if detail == "stdout" else MAX_STDERR_BYTES
            )
            raise NativeMetalReportError(
                "native runner %s exceeded %d byte bound"
                % (detail, maximum)
            )
        raise NativeMetalReportError(
            "native runner output capture failed: %s" % detail
        )
    return process.returncode, bytes(stdout), bytes(stderr)


def _write_retained_artifact(
    path_value: Union[str, os.PathLike],
    data: bytes,
) -> Path:
    """Atomically replace one explicitly requested artifact after validation."""

    path = Path(path_value)
    _require(path.name not in ("", ".", ".."), "invalid retained artifact path")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".%s." % path.name,
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, str(path))
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return path


def _component_file_sha256(
    path: Union[str, os.PathLike],
    label: str,
) -> bytes:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as source:
            while True:
                chunk = source.read(64 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        raise NativeMetalReportError(
            "could not hash native Metal %s: %s" % (label, error)
        ) from error
    return digest.digest()


def _runner_file_sha256(path: Union[str, os.PathLike]) -> bytes:
    return _component_file_sha256(path, "report runner")


def _metallib_file_sha256(path: Union[str, os.PathLike]) -> bytes:
    return _component_file_sha256(path, "shader library")


def _verify_components_unchanged(
    runner_path: Union[str, os.PathLike],
    metallib_path: Union[str, os.PathLike],
    runner_sha256: bytes,
    metallib_sha256: bytes,
) -> None:
    """Re-hash both producer components even if one post-read fails."""

    runner_after: Optional[bytes] = None
    metallib_after: Optional[bytes] = None
    failures: List[str] = []
    try:
        runner_after = _runner_file_sha256(runner_path)
    except NativeMetalReportError as error:
        failures.append(str(error))
    try:
        metallib_after = _metallib_file_sha256(metallib_path)
    except NativeMetalReportError as error:
        failures.append(str(error))
    if failures:
        raise NativeMetalReportError(
            "could not re-hash native Metal producer components: %s"
            % "; ".join(failures)
        )
    _require(
        runner_after == runner_sha256,
        "native Metal report runner changed during execution",
    )
    _require(
        metallib_after == metallib_sha256,
        "native Metal shader library changed during execution",
    )


def verify_runner(
    runner: Union[str, os.PathLike],
    metallib: Union[str, os.PathLike],
    retain_artifact: Optional[Union[str, os.PathLike]] = None,
    timeout_seconds: float = RUNNER_TIMEOUT_SECONDS,
) -> NativeVerificationResult:
    """Run exactly one zero-argument producer and verify its sole raw stdout."""

    path = os.fspath(runner)
    metallib_path = os.fspath(metallib)
    _require(bool(path), "missing native Metal report runner")
    _require(bool(metallib_path), "missing native Metal shader library")
    runner_sha256 = _runner_file_sha256(path)
    metallib_sha256 = _metallib_file_sha256(metallib_path)
    # Derive before process creation so invalid component identities fail
    # before executing untrusted producer code.
    _native_build_sha256(runner_sha256, metallib_sha256)
    challenge_sha256 = os.urandom(32)
    _require(
        challenge_sha256 != ZERO_DIGEST,
        "native campaign random challenge must be nonzero",
    )
    try:
        returncode, stdout, stderr = _bounded_runner_output(
            [path],
            timeout_seconds,
            challenge_sha256,
        )
    finally:
        _verify_components_unchanged(
            path,
            metallib_path,
            runner_sha256,
            metallib_sha256,
        )
    if returncode != 0:
        detail = stderr[:4096].decode("utf-8", errors="replace")
        raise NativeMetalReportError(
            "native Metal report runner failed (%d): %s"
            % (returncode, detail)
        )
    _require(stderr == b"", "native Metal report runner wrote to stderr")
    result = verify_native_wire(
        stdout,
        runner_sha256,
        metallib_sha256,
        challenge_sha256,
    )
    if retain_artifact is None:
        return result
    retained_path = _write_retained_artifact(retain_artifact, stdout)
    return NativeVerificationResult(
        result.record_count,
        result.warmup_count,
        result.measured_count,
        result.wire_sha256,
        result.report_sha256,
        result.runner_sha256,
        result.metallib_sha256,
        retained_path,
    )


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify one bounded production-native Metal workload report"
        )
    )
    parser.add_argument(
        "--runner",
        required=True,
        help="zero-argument executable that emits only the raw W6 V1 wire",
    )
    parser.add_argument(
        "--metallib",
        required=True,
        help="exact Metal shader library loaded by the report executable",
    )
    parser.add_argument(
        "--output",
        help="optional path atomically written only after complete verification",
    )
    arguments = parser.parse_args(argv)
    try:
        result = verify_runner(
            arguments.runner,
            arguments.metallib,
            arguments.output,
        )
    except (NativeMetalReportError, OSError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1

    suffix = (
        ""
        if result.retained_path is None
        else " retained=%s" % result.retained_path
    )
    print(
        "ok native-metal-workload-report-v1 "
        "records=%d warmup=%d measured=%d wire_sha256=%s "
        "report_sha256=%s runner_sha256=%s metallib_sha256=%s%s"
        % (
            result.record_count,
            result.warmup_count,
            result.measured_count,
            result.wire_sha256.hex(),
            result.report_sha256.hex(),
            result.runner_sha256.hex(),
            result.metallib_sha256.hex(),
            suffix,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
