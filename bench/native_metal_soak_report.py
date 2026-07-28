#!/usr/bin/env python3
"""Run and verify the fixed segmented production-native Metal soak campaign.

The supervisor keeps one native worker alive for six paced W7 segments,
publishes a crash-atomic checkpoint after every independently verified inner
wire, requires a clean worker exit, then resumes the chain in a fresh process
for six more segments. RSS is sampled from the worker process and Metal
``currentAllocatedSize`` is recomputed from the completed raw records. Neither
observation is relabelled as device residency or a proof of leak freedom.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any, Mapping, Optional, Sequence

from bench import lane4_evidence
from bench import native_metal_disruption_report as inner
from bench import native_metal_workload_report as process_boundary
from bench import native_observer
from bench import native_workload_campaign as campaign


class NativeMetalSoakError(ValueError):
    """The fixed W7b native campaign could not be proven."""


SEGMENT_COUNT = 12
SEGMENTS_PER_PROCESS = 6
RESTART_AFTER_SEGMENT = 6
EPOCHS_PER_SEGMENT = inner.EPOCH_COUNT
RECORDS_PER_EPOCH = inner.RECORDS_PER_EPOCH
WARMUP_EPOCHS_PER_SEGMENT = inner.WARMUP_EPOCH_COUNT
MEASURED_EPOCHS_PER_SEGMENT = inner.MEASURED_EPOCH_COUNT
COMPLETED_PER_EPOCH = inner.EXPECTED_FLOW_COUNT
CANCELLED_PER_EPOCH = 1
FAILED_PER_EPOCH = 1
CAPACITY_REJECTED_PER_EPOCH = 1
PINS_PER_EPOCH = 4
EVENTS_PER_EPOCH = 25
EPOCH_CADENCE_NS = 100_000_000
MINIMUM_SEGMENT_DURATION_NS = (
    EPOCHS_PER_SEGMENT * EPOCH_CADENCE_NS
)
MAXIMUM_SEGMENT_DURATION_NS = 15_000_000_000
CAMPAIGN_WALL_TIMEOUT_SECONDS = 180.0
WORKER_EXIT_TIMEOUT_SECONDS = 5.0
RSS_SAMPLE_INTERVAL_SECONDS = 0.05
MINIMUM_RSS_SAMPLES = 10
RSS_GROWTH_BOUND_BYTES = 64 * 1024 * 1024
DEVICE_ALLOCATION_GROWTH_BOUND_BYTES = 64 * 1024 * 1024
ARTIFACT_STORE_MAX_BYTES = 4 * 1024 * 1024
ARTIFACT_STORE_MAX_FILES = 32
ENVIRONMENT_OBJECT_MAX_BYTES = 64 * 1024
MAX_STDERR_BYTES = 64 * 1024
MAX_SUPERVISOR_OUTPUT_BYTES = 64 * 1024
RUNNING_EXIT_CODE_BITS = (1 << 64) - 1
ZERO_DIGEST = bytes(32)

EXPECTED_RECORDS_PER_SEGMENT = (
    EPOCHS_PER_SEGMENT * RECORDS_PER_EPOCH
)
EXPECTED_WARMUP_RECORDS_PER_SEGMENT = (
    WARMUP_EPOCHS_PER_SEGMENT * RECORDS_PER_EPOCH
)
EXPECTED_MEASURED_RECORDS_PER_SEGMENT = (
    MEASURED_EPOCHS_PER_SEGMENT * RECORDS_PER_EPOCH
)
EXPECTED_COMPLETED_PER_SEGMENT = (
    EPOCHS_PER_SEGMENT * COMPLETED_PER_EPOCH
)
EXPECTED_CANCELLED_PER_SEGMENT = (
    EPOCHS_PER_SEGMENT * CANCELLED_PER_EPOCH
)
EXPECTED_FAILED_PER_SEGMENT = (
    EPOCHS_PER_SEGMENT * FAILED_PER_EPOCH
)
EXPECTED_CAPACITY_PER_SEGMENT = (
    EPOCHS_PER_SEGMENT * CAPACITY_REJECTED_PER_EPOCH
)
EXPECTED_PINS_PER_SEGMENT = EPOCHS_PER_SEGMENT * PINS_PER_EPOCH
EXPECTED_EVENTS_PER_SEGMENT = EPOCHS_PER_SEGMENT * EVENTS_PER_EPOCH

EXPECTED_TOTAL_RECORDS = SEGMENT_COUNT * EXPECTED_RECORDS_PER_SEGMENT
EXPECTED_TOTAL_WARMUP_RECORDS = (
    SEGMENT_COUNT * EXPECTED_WARMUP_RECORDS_PER_SEGMENT
)
EXPECTED_TOTAL_MEASURED_RECORDS = (
    SEGMENT_COUNT * EXPECTED_MEASURED_RECORDS_PER_SEGMENT
)
EXPECTED_TOTAL_COMPLETED = (
    SEGMENT_COUNT * EXPECTED_COMPLETED_PER_SEGMENT
)
EXPECTED_TOTAL_CANCELLED = (
    SEGMENT_COUNT * EXPECTED_CANCELLED_PER_SEGMENT
)
EXPECTED_TOTAL_FAILED = SEGMENT_COUNT * EXPECTED_FAILED_PER_SEGMENT
EXPECTED_TOTAL_CAPACITY = SEGMENT_COUNT * EXPECTED_CAPACITY_PER_SEGMENT
EXPECTED_TOTAL_PINS = SEGMENT_COUNT * EXPECTED_PINS_PER_SEGMENT
EXPECTED_TOTAL_EVENTS = SEGMENT_COUNT * EXPECTED_EVENTS_PER_SEGMENT

SCHEDULE_DOMAIN = b"glacier-w7b-metal-soak-schedule-v1\x00"
RSS_SOURCE_BASE_SHA256 = hashlib.sha256(
    b"/bin/ps -o rss= -p <persistent-worker-pid>; rss_kib*1024/v1"
).digest()
SUPERVISOR_CLOCK_SHA256 = hashlib.sha256(
    b"Python time.monotonic_ns supervisor clock/v1"
).digest()

ACTIVE_SELECTOR_NAME = ".glacier-workload-campaign-active-v1"
LOCK_NAME = ".glacier-workload-campaign.lock"


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise NativeMetalSoakError(message)


def _u64(value: int) -> bytes:
    _require(
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= (1 << 64) - 1,
        "value is outside u64",
    )
    return struct.pack("<Q", value)


def _sha256_parts(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _file_sha256(path: os.PathLike[str] | str) -> bytes:
    return process_boundary._component_file_sha256(path, "soak component")


def _canonical_json(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _supervisor_sha256() -> bytes:
    return _file_sha256(Path(__file__).resolve())


def _schedule_sha256(supervisor_sha256: bytes) -> bytes:
    return _sha256_parts(
        SCHEDULE_DOMAIN,
        supervisor_sha256,
        *(
            _u64(value)
            for value in (
                inner.PRODUCER_ABI,
                SEGMENT_COUNT,
                SEGMENTS_PER_PROCESS,
                RESTART_AFTER_SEGMENT,
                EPOCHS_PER_SEGMENT,
                RECORDS_PER_EPOCH,
                WARMUP_EPOCHS_PER_SEGMENT,
                MEASURED_EPOCHS_PER_SEGMENT,
                COMPLETED_PER_EPOCH,
                CANCELLED_PER_EPOCH,
                FAILED_PER_EPOCH,
                CAPACITY_REJECTED_PER_EPOCH,
                PINS_PER_EPOCH,
                EVENTS_PER_EPOCH,
                EPOCH_CADENCE_NS,
                MINIMUM_SEGMENT_DURATION_NS,
                MAXIMUM_SEGMENT_DURATION_NS,
                RSS_GROWTH_BOUND_BYTES,
                DEVICE_ALLOCATION_GROWTH_BOUND_BYTES,
            )
        ),
    )


def _scheduled_action_sha256(
    campaign_id_sha256: bytes,
    schedule_sha256: bytes,
    process_source_sha256: bytes,
    ordinal: int,
    process_generation: int,
) -> bytes:
    action_tag = 2 if _is_phase_terminal(ordinal) else 1
    return campaign.derive_scheduled_action(
        campaign_id_sha256,
        schedule_sha256,
        ordinal,
        process_generation,
        action_tag,
        process_source_sha256,
    )


def environment_sha256(
    campaign_id_sha256: bytes,
    generation: int,
    before_sha256: bytes,
    after_sha256: bytes = ZERO_DIGEST,
) -> bytes:
    _require(
        len(campaign_id_sha256) == 32
        and campaign_id_sha256 != ZERO_DIGEST,
        "invalid campaign identity for environment root",
    )
    _require(
        len(before_sha256) == 32 and before_sha256 != ZERO_DIGEST,
        "invalid before-environment identity",
    )
    _require(
        len(after_sha256) == 32,
        "invalid after-environment identity",
    )
    return campaign.derive_environment_sha256(
        campaign_id_sha256,
        generation,
        before_sha256,
        after_sha256,
    )


def _capture_admitted_environment() -> tuple[dict[str, Any], bytes]:
    try:
        snapshot = lane4_evidence.capture_environment()
    except Exception as error:
        raise NativeMetalSoakError(
            "native environment admission probe failed: %s" % error
        ) from error
    _require(
        snapshot.get("measurement_admitted") is True
        and snapshot.get("reasons") == [],
        "native environment was not admitted: %s"
        % snapshot.get("reasons"),
    )
    _require(
        snapshot.get("power_source") == "AC Power",
        "native soak requires AC power",
    )
    _require(
        snapshot.get("low_power_mode_enabled") is False,
        "native soak requires low-power mode disabled",
    )
    _require(
        snapshot.get("thermal_state") == "nominal"
        and snapshot.get("foundation_thermal_state") == "nominal",
        "native soak requires nominal thermal state",
    )
    encoded = _canonical_json(snapshot)
    return snapshot, hashlib.sha256(encoded).digest()


def _compare_environment_boundaries(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
) -> None:
    _require(
        before.get("host", {}).get("fingerprint_sha256")
        == after.get("host", {}).get("fingerprint_sha256"),
        "host identity changed across the campaign",
    )
    for field in (
        "power_source",
        "low_power_mode_enabled",
        "thermal_state",
        "foundation_thermal_state",
        "available_cpus",
        "foundation_probe_source_sha256",
        "foundation_probe_runner_sha256",
    ):
        _require(
            before.get(field) == after.get(field),
            "environment field %s changed across the campaign" % field,
        )


def _process_generation(ordinal: int) -> int:
    return 1 if ordinal < RESTART_AFTER_SEGMENT else 2


def _is_phase_terminal(ordinal: int) -> bool:
    return ordinal in (
        RESTART_AFTER_SEGMENT - 1,
        SEGMENT_COUNT - 1,
    )


def _initial_plan(
    campaign_challenge_sha256: bytes,
    worker_sha256: bytes,
    metallib_sha256: bytes,
    schedule_sha256: bytes,
) -> dict[str, Any]:
    build_sha256 = inner._native_build_sha256(
        worker_sha256,
        metallib_sha256,
    )
    # Native machine/device/placement identities are intentionally left zero
    # until the first challenged report supplies them. Campaign ID derivation
    # excludes those dynamic fields, avoiding an unretained preflight run.
    return {
        "abi_version": campaign.MANIFEST_ABI,
        "encoded_bytes": campaign.encoded_manifest_bytes(SEGMENT_COUNT),
        "flags": campaign.ALLOWED_FLAGS,
        "segment_count": SEGMENT_COUNT,
        "restart_after_segment": RESTART_AFTER_SEGMENT,
        "epochs_per_segment": EPOCHS_PER_SEGMENT,
        "records_per_epoch": RECORDS_PER_EPOCH,
        "warmup_epochs_per_segment": WARMUP_EPOCHS_PER_SEGMENT,
        "measured_epochs_per_segment": MEASURED_EPOCHS_PER_SEGMENT,
        "completed_per_epoch": COMPLETED_PER_EPOCH,
        "cancelled_per_epoch": CANCELLED_PER_EPOCH,
        "failed_per_epoch": FAILED_PER_EPOCH,
        "capacity_rejected_per_epoch": CAPACITY_REJECTED_PER_EPOCH,
        "pins_per_epoch": PINS_PER_EPOCH,
        "events_per_epoch": EVENTS_PER_EPOCH,
        "epoch_cadence_ns": EPOCH_CADENCE_NS,
        "minimum_segment_duration_ns": MINIMUM_SEGMENT_DURATION_NS,
        "maximum_segment_duration_ns": MAXIMUM_SEGMENT_DURATION_NS,
        "report_wire_bytes": inner.EXPECTED_WIRE_BYTES,
        "artifact_store_max_bytes": ARTIFACT_STORE_MAX_BYTES,
        "rss_growth_bound_bytes": RSS_GROWTH_BOUND_BYTES,
        "total_epochs": SEGMENT_COUNT * EPOCHS_PER_SEGMENT,
        "total_records": EXPECTED_TOTAL_RECORDS,
        "total_warmup_records": EXPECTED_TOTAL_WARMUP_RECORDS,
        "total_measured_records": EXPECTED_TOTAL_MEASURED_RECORDS,
        "total_completed": EXPECTED_TOTAL_COMPLETED,
        "total_cancelled": EXPECTED_TOTAL_CANCELLED,
        "total_failed": EXPECTED_TOTAL_FAILED,
        "total_capacity_rejected": EXPECTED_TOTAL_CAPACITY,
        "total_pin_acquisitions": EXPECTED_TOTAL_PINS,
        "device_allocation_growth_bound_bytes": (
            DEVICE_ALLOCATION_GROWTH_BOUND_BYTES
        ),
        "total_events": EXPECTED_TOTAL_EVENTS,
        "campaign_challenge_sha256": campaign_challenge_sha256,
        "workload_sha256": inner.EXPECTED_WORKLOAD_SHA256,
        "schedule_sha256": schedule_sha256,
        "artifact_sha256": inner.EXPECTED_ARTIFACT_SHA256,
        "build_sha256": build_sha256,
        "runner_sha256": worker_sha256,
        "backend_library_sha256": metallib_sha256,
        "machine_sha256": ZERO_DIGEST,
        "backend_sha256": ZERO_DIGEST,
        "device_sha256": ZERO_DIGEST,
        "placement_sha256": ZERO_DIGEST,
        "campaign_id_sha256": ZERO_DIGEST,
    }


def _seal_plan_from_first_report(
    initial_plan: Mapping[str, Any],
    decoded: Any,
) -> dict[str, Any]:
    result = dict(initial_plan)
    identities = decoded.scenario.identities
    result.update(
        {
            "machine_sha256": identities[4],
            "backend_sha256": identities[5],
            "device_sha256": identities[6],
            "placement_sha256": identities[7],
        }
    )
    expected_id = campaign.derive_campaign_id(initial_plan)
    result["campaign_id_sha256"] = expected_id
    sealed = campaign.seal_plan(result)
    _require(
        sealed["campaign_id_sha256"] == expected_id,
        "dynamic native identities changed the campaign ID",
    )
    return sealed


class _PersistentWorker:
    def __init__(
        self,
        worker: str,
        metallib: str,
        worker_sha256: bytes,
        metallib_sha256: bytes,
    ) -> None:
        self.worker = worker
        self.metallib = metallib
        self.worker_sha256 = worker_sha256
        self.metallib_sha256 = metallib_sha256
        environment = {"LC_ALL": "C", "PATH": os.defpath}
        try:
            self.process = subprocess.Popen(
                [worker],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                close_fds=True,
                # The CLI watchdog places the supervisor and workers in one
                # private process group so one deadline can terminate both.
                start_new_session=False,
                bufsize=0,
            )
        except (OSError, TypeError, ValueError) as error:
            raise NativeMetalSoakError(
                "could not start native Metal soak worker: %s" % error
            ) from error
        if (
            self.process.stdin is None
            or self.process.stdout is None
            or self.process.stderr is None
        ):
            self._terminate()
            raise NativeMetalSoakError(
                "could not open native Metal soak worker pipes"
            )
        self.selector = selectors.DefaultSelector()
        for stream, kind in (
            (self.process.stdout, "stdout"),
            (self.process.stderr, "stderr"),
        ):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, kind)
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.closed = False
        self.segment_count = 0
        self.process_source_sha256 = _sha256_parts(
            b"glacier-w7b-metal-soak-worker-process-v1\x00",
            RSS_SOURCE_BASE_SHA256,
            self.worker_sha256,
            self.metallib_sha256,
            _u64(self.process.pid),
            _u64(time.monotonic_ns()),
        )

    def _terminate(self) -> None:
        process = getattr(self, "process", None)
        if process is None or process.poll() is not None:
            return
        try:
            process.terminate()
        except OSError:
            pass
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except OSError:
                pass
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=1.0)

    def _read_ready(self, timeout: float) -> None:
        for key, _events in self.selector.select(timeout):
            stream = key.fileobj
            try:
                chunk = os.read(stream.fileno(), 64 * 1024)
            except BlockingIOError:
                continue
            if not chunk:
                with contextlib.suppress(Exception):
                    self.selector.unregister(stream)
                continue
            destination = (
                self.stdout if key.data == "stdout" else self.stderr
            )
            destination.extend(chunk)
            maximum = (
                8 + inner.EXPECTED_WIRE_BYTES
                if key.data == "stdout"
                else MAX_STDERR_BYTES
            )
            _require(
                len(destination) <= maximum,
                "native soak worker %s exceeded %d bytes"
                % (key.data, maximum),
            )

    def _sample_rss(self) -> Optional[int]:
        try:
            completed = subprocess.run(
                ["/bin/ps", "-o", "rss=", "-p", str(self.process.pid)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"LC_ALL": "C", "PATH": os.defpath},
                timeout=0.5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if completed.returncode != 0 or completed.stderr:
            return None
        try:
            return native_observer.parse_process_rss_bytes(
                completed.stdout.decode("ascii")
            )
        except (UnicodeDecodeError, native_observer.ObservationError):
            return None

    def _required_rss(self, deadline: float) -> int:
        while time.monotonic() < deadline:
            value = self._sample_rss()
            if value is not None and value > 0:
                return value
            if self.process.poll() is not None:
                break
            time.sleep(0.02)
        raise NativeMetalSoakError(
            "native worker RSS was unavailable before segment"
        )

    def request(
        self,
        challenge_sha256: bytes,
        timeout_seconds: float,
    ) -> tuple[bytes, int, tuple[int, int, int, int]]:
        _require(not self.closed, "native soak worker is closed")
        _require(
            len(challenge_sha256) == 32
            and challenge_sha256 != ZERO_DIGEST,
            "invalid native soak segment challenge",
        )
        _require(
            0 < timeout_seconds <= MAXIMUM_SEGMENT_DURATION_NS / 1e9,
            "invalid native soak segment timeout",
        )
        _require(
            self.process.poll() is None,
            "native soak worker exited before segment",
        )
        _require(
            not self.stdout and not self.stderr,
            "native soak worker has stale output",
        )
        before = self._required_rss(time.monotonic() + 2.0)
        samples = [before]
        started_ns = time.monotonic_ns()
        deadline = time.monotonic() + timeout_seconds
        try:
            self.process.stdin.write(
                challenge_sha256.hex().encode("ascii") + b"\n"
            )
            self.process.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as error:
            raise NativeMetalSoakError(
                "could not send native soak challenge: %s" % error
            ) from error

        expected_frame_bytes = 8 + inner.EXPECTED_WIRE_BYTES
        next_sample = time.monotonic()
        while len(self.stdout) < expected_frame_bytes:
            now = time.monotonic()
            if now >= deadline:
                raise NativeMetalSoakError(
                    "native soak segment exceeded %.1fs timeout"
                    % timeout_seconds
                )
            self._read_ready(min(0.02, deadline - now))
            _require(
                not self.stderr,
                "native soak worker wrote to stderr",
            )
            _require(
                self.process.poll() is None,
                "native soak worker exited before emitting a frame",
            )
            now = time.monotonic()
            if now >= next_sample:
                sample = self._sample_rss()
                if sample is not None and sample > 0:
                    samples.append(sample)
                next_sample = now + RSS_SAMPLE_INTERVAL_SECONDS
            if len(self.stdout) >= 8:
                declared = struct.unpack_from("<Q", self.stdout, 0)[0]
                _require(
                    declared == inner.EXPECTED_WIRE_BYTES,
                    "native soak worker declared an unexpected wire length",
                )

        _require(
            len(self.stdout) == expected_frame_bytes,
            "native soak worker emitted bytes outside one frame",
        )
        finished_ns = time.monotonic_ns()
        after = self._sample_rss()
        _require(
            after is not None and after > 0,
            "native worker RSS was unavailable after segment",
        )
        samples.append(after)
        _require(
            len(samples) >= MINIMUM_RSS_SAMPLES,
            "native soak segment retained too few RSS samples",
        )
        wire = bytes(self.stdout[8:])
        self.stdout.clear()
        self.segment_count += 1
        return (
            wire,
            finished_ns - started_ns,
            (before, max(samples), after, len(samples)),
        )

    def close_cleanly(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            self.process.stdin.close()
        except OSError as error:
            self._terminate()
            raise NativeMetalSoakError(
                "could not close native worker stdin: %s" % error
            ) from error
        deadline = time.monotonic() + WORKER_EXIT_TIMEOUT_SECONDS
        while self.process.poll() is None and time.monotonic() < deadline:
            self._read_ready(0.02)
        if self.process.poll() is None:
            self._terminate()
            raise NativeMetalSoakError(
                "native soak worker did not exit after clean EOF"
            )
        # Drain pipe bytes made visible just before process exit.
        for _ in range(4):
            self._read_ready(0.0)
        _require(
            self.process.returncode == 0,
            "native soak worker exited with status %s"
            % self.process.returncode,
        )
        _require(
            not self.stdout and not self.stderr,
            "native soak worker emitted trailing output",
        )
        process_boundary._verify_components_unchanged(
            self.worker,
            self.metallib,
            self.worker_sha256,
            self.metallib_sha256,
        )
        with contextlib.suppress(Exception):
            self.selector.close()

    def abort(self) -> None:
        self._terminate()
        with contextlib.suppress(Exception):
            process_boundary._verify_components_unchanged(
                self.worker,
                self.metallib,
                self.worker_sha256,
                self.metallib_sha256,
            )
        with contextlib.suppress(Exception):
            self.selector.close()


def _completed_allocation_context(
    decoded: Any,
) -> tuple[int, int, int, bytes]:
    contexts = [
        record.allocated_context
        for record in decoded.records
        if record.outcome == inner.OUTCOME_COMPLETED
    ]
    _require(
        len(contexts) == EXPECTED_COMPLETED_PER_SEGMENT,
        "completed allocation-context count changed",
    )
    _require(
        all(
            value.availability == inner.AVAILABILITY_PRESENT
            and value.before_bytes > 0
            and value.after_bytes > 0
            and value.reason_sha256 == ZERO_DIGEST
            for value in contexts
        ),
        "completed Metal allocation context is unavailable",
    )
    sources = {value.source_sha256 for value in contexts}
    _require(
        len(sources) == 1 and ZERO_DIGEST not in sources,
        "Metal allocation context source changed within a segment",
    )
    return (
        contexts[0].before_bytes,
        max(
            max(value.before_bytes, value.after_bytes)
            for value in contexts
        ),
        contexts[-1].after_bytes,
        next(iter(sources)),
    )


def _assert_segment_cadence(decoded: Any) -> None:
    """Prove every paced epoch starts no earlier than its absolute target."""
    for epoch in range(EPOCHS_PER_SEGMENT):
        first = decoded.records[epoch * RECORDS_PER_EPOCH]
        _require(
            bool(first.host.presence_mask & 1),
            "paced epoch has no first host event",
        )
        target_ns = (epoch + 1) * EPOCH_CADENCE_NS
        _require(
            first.host.points[0].ns >= target_ns,
            "native segment epoch %d started before its cadence target"
            % epoch,
        )


def _verify_retained_entry(
    entry: Mapping[str, Any],
    wire: bytes,
    worker_sha256: bytes,
    metallib_sha256: bytes,
) -> None:
    """Bind every duplicated outer fact to the retained verified inner wire."""
    result = inner.verify_native_wire(
        wire,
        worker_sha256,
        metallib_sha256,
        entry["segment_challenge_sha256"],
    )
    decoded = inner._decode_after_portable_verification(wire)
    _assert_segment_cadence(decoded)
    identities = decoded.scenario.identities
    expected_digests = {
        "report_wire_sha256": result.wire_sha256,
        "verified_report_sha256": result.report_sha256,
        "scenario_sha256": decoded.scenario.scenario_sha256,
        "closure_sha256": decoded.closure.closure_sha256,
        "build_sha256": identities[3],
        "machine_sha256": identities[4],
        "backend_sha256": identities[5],
        "device_sha256": identities[6],
        "placement_sha256": identities[7],
        "host_source_sha256": identities[8],
        "host_clock_sha256": identities[9],
    }
    for field, expected in expected_digests.items():
        _require(
            entry[field] == expected,
            "retained inner wire disagrees with outer %s" % field,
        )
    (
        device_before,
        device_max,
        device_after,
        device_source,
    ) = _completed_allocation_context(decoded)
    expected_allocation = {
        "device_allocation_before_bytes": device_before,
        "device_allocation_max_bytes": device_max,
        "device_allocation_after_bytes": device_after,
        "device_allocation_source_sha256": device_source,
    }
    for field, expected in expected_allocation.items():
        _require(
            entry[field] == expected,
            "retained inner wire disagrees with outer %s" % field,
        )


def _entry_value(
    plan: Mapping[str, Any],
    decoded: Any,
    verification: inner.NativeDisruptionVerificationResult,
    ordinal: int,
    previous_entry_sha256: bytes,
    previous_report_sha256: bytes,
    scheduled_action_sha256: bytes,
    duration_ns: int,
    cumulative_duration_ns: int,
    rss: tuple[int, int, int, int],
    rss_source_sha256: bytes,
    phase_exited_cleanly: bool,
) -> dict[str, Any]:
    rss_before, rss_max, rss_after, _sample_count = rss
    (
        device_before,
        device_max,
        device_after,
        device_source,
    ) = _completed_allocation_context(decoded)
    identities = decoded.scenario.identities
    provenance = campaign.BASE_PROVENANCE_BITS
    if ordinal == RESTART_AFTER_SEGMENT - 1:
        provenance |= campaign.PROVENANCE_PLANNED_GRACEFUL_RESTART
    return {
        "abi_version": campaign.ATTEMPT_ABI,
        "ordinal": ordinal,
        "process_generation": _process_generation(ordinal),
        "disposition": campaign.DISPOSITION_COMPLETE,
        "provenance_bits": provenance,
        "epoch_count": EPOCHS_PER_SEGMENT,
        "record_count": EXPECTED_RECORDS_PER_SEGMENT,
        "warmup_record_count": EXPECTED_WARMUP_RECORDS_PER_SEGMENT,
        "measured_record_count": EXPECTED_MEASURED_RECORDS_PER_SEGMENT,
        "completed_count": EXPECTED_COMPLETED_PER_SEGMENT,
        "cancelled_count": EXPECTED_CANCELLED_PER_SEGMENT,
        "failed_count": EXPECTED_FAILED_PER_SEGMENT,
        "capacity_rejected_count": EXPECTED_CAPACITY_PER_SEGMENT,
        "pin_acquisitions": EXPECTED_PINS_PER_SEGMENT,
        "pin_completions": EXPECTED_PINS_PER_SEGMENT,
        "event_count": EXPECTED_EVENTS_PER_SEGMENT,
        "report_wire_bytes": inner.EXPECTED_WIRE_BYTES,
        "duration_ns": duration_ns,
        "cumulative_duration_ns": cumulative_duration_ns,
        "cumulative_records": (ordinal + 1)
        * EXPECTED_RECORDS_PER_SEGMENT,
        "cumulative_completed": (ordinal + 1)
        * EXPECTED_COMPLETED_PER_SEGMENT,
        "rss_availability": campaign.AVAILABILITY_PRESENT,
        "rss_before_bytes": rss_before,
        "rss_max_bytes": rss_max,
        "rss_after_bytes": rss_after,
        "device_allocation_availability": campaign.AVAILABILITY_PRESENT,
        "device_allocation_before_bytes": device_before,
        "device_allocation_max_bytes": device_max,
        "device_allocation_after_bytes": device_after,
        "exit_code_bits": 0
        if phase_exited_cleanly
        else RUNNING_EXIT_CODE_BITS,
        "termination_signal": 0,
        "reserved": 0,
        "segment_challenge_sha256": identities[12],
        "previous_entry_sha256": previous_entry_sha256,
        "previous_verified_report_sha256": previous_report_sha256,
        "scheduled_action_sha256": scheduled_action_sha256,
        "report_wire_sha256": verification.wire_sha256,
        "verified_report_sha256": verification.report_sha256,
        "scenario_sha256": decoded.scenario.scenario_sha256,
        "closure_sha256": decoded.closure.closure_sha256,
        "build_sha256": identities[3],
        "machine_sha256": identities[4],
        "backend_sha256": identities[5],
        "device_sha256": identities[6],
        "placement_sha256": identities[7],
        "host_source_sha256": identities[8],
        "host_clock_sha256": identities[9],
        "rss_source_sha256": rss_source_sha256,
        "rss_unavailable_reason_sha256": ZERO_DIGEST,
        "device_allocation_source_sha256": device_source,
        "device_allocation_unavailable_reason_sha256": ZERO_DIGEST,
        "entry_sha256": ZERO_DIGEST,
    }


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write")
        view = view[written:]


def _read_regular_file(path: Path, maximum_bytes: int) -> bytes:
    _require(maximum_bytes > 0, "invalid file read bound")
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        before = os.fstat(descriptor)
        _require(
            stat.S_ISREG(before.st_mode)
            and 0 <= before.st_size <= maximum_bytes,
            "campaign object is not a bounded regular file",
        )
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            _require(chunk != b"", "campaign object was truncated")
            chunks.append(chunk)
            remaining -= len(chunk)
        _require(
            os.read(descriptor, 1) == b"",
            "campaign object grew while being read",
        )
        after = os.fstat(descriptor)
        _require(
            (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
            )
            == (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
            ),
            "campaign object changed while being read",
        )
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _read_environment_objects(
    directory: Path,
) -> list[tuple[bytes, dict[str, Any], Any]]:
    _require(
        directory.is_dir() and not directory.is_symlink(),
        "environment object directory is not a real directory",
    )
    paths = sorted(directory.iterdir(), key=lambda value: value.name)
    _require(
        1 <= len(paths) <= 2,
        "campaign store has an unexpected environment-object count",
    )
    result: list[tuple[bytes, dict[str, Any], Any]] = []
    for path in paths:
        _require(
            path.name.endswith(".json")
            and len(path.name) == 69
            and path.name[:-5] == path.name[:-5].lower(),
            "environment object name is not canonical",
        )
        try:
            name_digest = bytes.fromhex(path.name[:-5])
        except ValueError as error:
            raise NativeMetalSoakError(
                "environment object name is not hexadecimal"
            ) from error
        data = _read_regular_file(path, ENVIRONMENT_OBJECT_MAX_BYTES)
        _require(
            hashlib.sha256(data).digest() == name_digest,
            "environment object content address changed",
        )
        try:
            decoded = json.loads(data.decode("ascii"))
            _require(
                isinstance(decoded, dict)
                and _canonical_json(decoded) == data,
                "environment object is not canonical JSON",
            )
            (_host, captured_at) = lane4_evidence._validate_environment(
                decoded,
                "retained_environment",
                expected_foundation_runner_sha256=decoded.get(
                    "foundation_probe_runner_sha256",
                    "",
                ),
            )
        except (
            UnicodeDecodeError,
            ValueError,
            TypeError,
            lane4_evidence.EvidenceError,
        ) as error:
            if isinstance(error, NativeMetalSoakError):
                raise
            raise NativeMetalSoakError(
                "retained environment object is invalid: %s" % error
            ) from error
        result.append((name_digest, decoded, captured_at))
    return result


def _resolve_environment_evidence(
    directory: Path,
    campaign_id_sha256: bytes,
    generation: int,
    expected_environment_sha256: bytes,
) -> tuple[bytes, bytes]:
    objects = _read_environment_objects(directory)
    if generation < SEGMENT_COUNT:
        _require(
            len(objects) == 1,
            "partial checkpoint must retain one environment boundary",
        )
        candidates = [(objects[0], None)]
    else:
        _require(
            generation == SEGMENT_COUNT and len(objects) == 2,
            "final checkpoint must retain two environment boundaries",
        )
        candidates = [
            (before, after)
            for before in objects
            for after in objects
            if before[0] != after[0]
        ]

    matches: list[
        tuple[
            tuple[bytes, dict[str, Any], Any],
            Optional[tuple[bytes, dict[str, Any], Any]],
        ]
    ] = []
    for before, after in candidates:
        after_digest = ZERO_DIGEST if after is None else after[0]
        if (
            environment_sha256(
                campaign_id_sha256,
                generation,
                before[0],
                after_digest,
            )
            == expected_environment_sha256
        ):
            matches.append((before, after))
    _require(
        len(matches) == 1,
        "environment root does not uniquely resolve retained boundaries",
    )
    before, after = matches[0]
    if after is not None:
        _require(
            before[2] < after[2],
            "environment boundary timestamps are not increasing",
        )
        _compare_environment_boundaries(before[1], after[1])
        return before[0], after[0]
    return before[0], ZERO_DIGEST


class CampaignStore:
    """Crash-atomic content-addressed segment/manifest store."""

    def __init__(self, root: os.PathLike[str] | str) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        _require(
            self.root.is_dir() and not self.root.is_symlink(),
            "campaign store root is not a real directory",
        )
        self.segments = self.root / "segments"
        self.manifests = self.root / "manifests"
        self.environments = self.root / "environments"
        for directory in (
            self.segments,
            self.manifests,
            self.environments,
        ):
            directory.mkdir(exist_ok=True)
            _require(
                directory.is_dir() and not directory.is_symlink(),
                "campaign store object directory is not a real directory",
            )
        _fsync_directory(self.root)
        self.lock_path = self.root / LOCK_NAME
        lock_descriptor = os.open(
            self.lock_path,
            os.O_RDWR
            | os.O_CREAT
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        if not stat.S_ISREG(os.fstat(lock_descriptor).st_mode):
            os.close(lock_descriptor)
            raise NativeMetalSoakError(
                "campaign lock is not a regular file"
            )
        self.lock = os.fdopen(lock_descriptor, "a+b")
        try:
            fcntl.flock(
                self.lock.fileno(),
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except OSError as error:
            self.lock.close()
            raise NativeMetalSoakError(
                "campaign store is already locked"
            ) from error
        active = self.root / ACTIVE_SELECTOR_NAME
        try:
            _require(
                not os.path.lexists(active),
                "campaign output directory already has an active selector",
            )
            expected_root_names = {
                self.segments.name,
                self.manifests.name,
                self.environments.name,
                self.lock_path.name,
            }
            _require(
                {path.name for path in self.root.iterdir()}
                == expected_root_names
                and all(
                    not any(directory.iterdir())
                    for directory in (
                        self.segments,
                        self.manifests,
                        self.environments,
                    )
                ),
                "campaign output directory is not an empty canonical store",
            )
        except BaseException:
            with contextlib.suppress(OSError):
                fcntl.flock(self.lock.fileno(), fcntl.LOCK_UN)
            self.lock.close()
            raise

    def close(self) -> None:
        if self.lock.closed:
            return
        with contextlib.suppress(OSError):
            fcntl.flock(self.lock.fileno(), fcntl.LOCK_UN)
        self.lock.close()

    def _immutable(
        self,
        directory: Path,
        name: str,
        data: bytes,
        maximum_store_bytes: int = ARTIFACT_STORE_MAX_BYTES,
    ) -> Path:
        target = directory / name
        if os.path.lexists(target):
            _require(
                target.is_file()
                and not target.is_symlink()
                and _read_regular_file(target, len(data)) == data,
                "content-addressed object collision",
            )
            return target
        self._preflight_target(
            target,
            len(data),
            maximum_store_bytes,
        )
        temporary = directory / (
            ".%s.%d.%s.tmp"
            % (name, os.getpid(), os.urandom(8).hex())
        )
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        try:
            _write_all(descriptor, data)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.link(
                temporary,
                target,
                follow_symlinks=False,
            )
            temporary.unlink()
            _fsync_directory(directory)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()
            raise
        return target

    def write_environment(
        self,
        snapshot: Mapping[str, Any],
    ) -> bytes:
        data = _canonical_json(snapshot)
        digest = hashlib.sha256(data).digest()
        self._immutable(
            self.environments,
            digest.hex() + ".json",
            data,
        )
        return digest

    def write_segment(self, wire: bytes) -> bytes:
        _require(
            len(wire) == inner.EXPECTED_WIRE_BYTES,
            "segment wire has an unexpected length",
        )
        digest = hashlib.sha256(wire).digest()
        self._immutable(
            self.segments,
            digest.hex() + ".bin",
            wire,
        )
        return digest

    def publish(
        self,
        plan: Mapping[str, Any],
        entries: Sequence[Mapping[str, Any]],
        environment_root_sha256: bytes,
    ) -> tuple[bytes, bytes]:
        manifest_wire = campaign.make_manifest(plan, entries)
        decoded = campaign.verify_manifest(manifest_wire)
        manifest_sha256 = decoded["manifest_sha256"]
        self._immutable(
            self.manifests,
            manifest_sha256.hex() + ".bin",
            manifest_wire,
            plan["artifact_store_max_bytes"],
        )
        selector_wire = campaign.make_selector(
            decoded,
            environment_root_sha256,
        )
        campaign.verify_selector(
            manifest_wire,
            selector_wire,
            environment_root_sha256,
        )
        active = self.root / ACTIVE_SELECTOR_NAME
        previous_selector = (
            _read_regular_file(active, campaign.SELECTOR_BYTES)
            if os.path.lexists(active)
            else None
        )
        self._preflight_target(
            active,
            len(selector_wire),
            plan["artifact_store_max_bytes"],
            replacing=True,
        )
        temporary = self.root / (
            ".%s.%d.%s.tmp"
            % (ACTIVE_SELECTOR_NAME, os.getpid(), os.urandom(8).hex())
        )
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        try:
            _write_all(descriptor, selector_wire)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.replace(temporary, active)
            _fsync_directory(self.root)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()
            raise
        try:
            self._enforce_bound(plan)
        except BaseException:
            self._restore_selector(active, previous_selector)
            raise
        return manifest_wire, selector_wire

    def _usage(self) -> tuple[int, int]:
        total = 0
        count = 0
        expected_directories = {
            self.segments.resolve(),
            self.manifests.resolve(),
            self.environments.resolve(),
        }
        discovered_directories: set[Path] = set()
        for directory, subdirectories, files in os.walk(
            self.root,
            followlinks=False,
        ):
            directory_path = Path(directory)
            for name in subdirectories:
                path = directory_path / name
                _require(
                    path.is_dir() and not path.is_symlink(),
                    "campaign store has a non-real directory",
                )
                discovered_directories.add(path.resolve())
            for filename in files:
                path = directory_path / filename
                info = path.lstat()
                _require(
                    stat.S_ISREG(info.st_mode),
                    "campaign store has a non-regular file",
                )
                total += info.st_size
                count += 1
        _require(
            discovered_directories == expected_directories,
            "campaign store directory layout changed",
        )
        return total, count

    def _preflight_target(
        self,
        target: Path,
        target_bytes: int,
        maximum_store_bytes: int,
        *,
        replacing: bool = False,
    ) -> None:
        _require(
            0 <= target_bytes <= maximum_store_bytes,
            "campaign object exceeds the store byte bound",
        )
        total, count = self._usage()
        if os.path.lexists(target):
            _require(
                replacing
                and target.is_file()
                and not target.is_symlink(),
                "campaign target unexpectedly exists",
            )
            info = target.lstat()
            total -= info.st_size
        else:
            count += 1
        total += target_bytes
        _require(
            total <= maximum_store_bytes,
            "campaign store would exceed its byte bound",
        )
        _require(
            count <= ARTIFACT_STORE_MAX_FILES,
            "campaign store would exceed its file bound",
        )

    def _restore_selector(
        self,
        active: Path,
        previous_selector: Optional[bytes],
    ) -> None:
        if previous_selector is None:
            with contextlib.suppress(FileNotFoundError):
                active.unlink()
            _fsync_directory(self.root)
            return
        temporary = self.root / (
            ".%s.rollback.%d.%s.tmp"
            % (ACTIVE_SELECTOR_NAME, os.getpid(), os.urandom(8).hex())
        )
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        try:
            _write_all(descriptor, previous_selector)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.replace(temporary, active)
            _fsync_directory(self.root)
        finally:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()

    def _enforce_bound(self, plan: Mapping[str, Any]) -> None:
        total, count = self._usage()
        _require(
            total <= plan["artifact_store_max_bytes"],
            "campaign store exceeded its byte bound",
        )
        _require(
            count <= ARTIFACT_STORE_MAX_FILES,
            "campaign store exceeded its file bound",
        )

    def recover(
        self,
        expected_plan: Mapping[str, Any],
        expected_generation: int,
        environment_root_sha256: bytes,
        worker_sha256: bytes,
        metallib_sha256: bytes,
    ) -> tuple[dict[str, Any], bytes]:
        selector_wire = _read_regular_file(
            self.root / ACTIVE_SELECTOR_NAME,
            campaign.SELECTOR_BYTES,
        )
        selector = campaign.decode_selector(selector_wire)
        _require(
            selector["generation"] == expected_generation,
            "active selector generation changed",
        )
        manifest_path = self.manifests / (
            selector["manifest_sha256"].hex() + ".bin"
        )
        manifest_wire = _read_regular_file(
            manifest_path,
            expected_plan["encoded_bytes"],
        )
        manifest = campaign.verify_manifest(manifest_wire)
        campaign.verify_selector(
            manifest_wire,
            selector_wire,
            environment_root_sha256,
        )
        _resolve_environment_evidence(
            self.environments,
            expected_plan["campaign_id_sha256"],
            expected_generation,
            environment_root_sha256,
        )
        _require(
            manifest["plan"] == dict(expected_plan),
            "reopened campaign plan changed",
        )
        _require(
            len(manifest["entries"]) == expected_generation,
            "reopened manifest prefix length changed",
        )
        for entry in manifest["entries"]:
            wire_path = (
                self.segments
                / (entry["report_wire_sha256"].hex() + ".bin")
            )
            wire = _read_regular_file(
                wire_path,
                inner.EXPECTED_WIRE_BYTES,
            )
            _require(
                hashlib.sha256(wire).digest()
                == entry["report_wire_sha256"],
                "retained segment content address changed",
            )
            _verify_retained_entry(
                entry,
                wire,
                worker_sha256,
                metallib_sha256,
            )
        self._enforce_bound(expected_plan)
        return manifest, selector_wire


def _require_exact_regular_objects(
    directory: Path,
    expected: Mapping[str, bytes],
) -> None:
    _require(
        directory.is_dir() and not directory.is_symlink(),
        "campaign object directory is not a real directory",
    )
    actual = {path.name: path for path in directory.iterdir()}
    _require(
        set(actual) == set(expected),
        "campaign object set is not canonical",
    )
    for name, data in expected.items():
        _require(
            _read_regular_file(actual[name], len(data)) == data,
            "campaign object %s changed" % name,
        )


def verify_retained_store(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    output_dir: os.PathLike[str] | str,
) -> dict[str, Any]:
    """Offline-verify a completed store without trusting live-run memory."""
    worker_path = os.fspath(worker)
    metallib_path = os.fspath(metallib)
    root = Path(output_dir)
    _require(
        root.is_dir() and not root.is_symlink(),
        "retained campaign root is not a real directory",
    )
    segments = root / "segments"
    manifests = root / "manifests"
    environments = root / "environments"
    lock_path = root / LOCK_NAME
    active = root / ACTIVE_SELECTOR_NAME
    _require(
        {path.name for path in root.iterdir()}
        == {
            segments.name,
            manifests.name,
            environments.name,
            lock_path.name,
            active.name,
        },
        "retained campaign root layout is not canonical",
    )
    lock_descriptor = os.open(
        lock_path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        _require(
            stat.S_ISREG(os.fstat(lock_descriptor).st_mode),
            "retained campaign lock is not a regular file",
        )
        try:
            fcntl.flock(
                lock_descriptor,
                fcntl.LOCK_SH | fcntl.LOCK_NB,
            )
        except OSError as error:
            raise NativeMetalSoakError(
                "retained campaign store is still being written"
            ) from error
        selector_wire = _read_regular_file(
            active,
            campaign.SELECTOR_BYTES,
        )
        selector = campaign.decode_selector(selector_wire)
        _require(
            selector["segment_count"] == SEGMENT_COUNT,
            "retained campaign is not the fixed soak profile",
        )
        generation_count = selector["generation"]
        manifest_path = manifests / (
            selector["manifest_sha256"].hex() + ".bin"
        )
        manifest_wire = _read_regular_file(
            manifest_path,
            campaign.encoded_manifest_bytes(SEGMENT_COUNT),
        )
        manifest = campaign.verify_manifest(manifest_wire)
        campaign.verify_selector(
            manifest_wire,
            selector_wire,
            selector["environment_sha256"],
        )
        plan = manifest["plan"]
        entries = manifest["entries"]
        _require(
            len(entries) == generation_count,
            "retained campaign generation changed",
        )

        worker_sha256 = _file_sha256(worker_path)
        metallib_sha256 = _file_sha256(metallib_path)
        first_wire = _read_regular_file(
            segments
            / (entries[0]["report_wire_sha256"].hex() + ".bin"),
            inner.EXPECTED_WIRE_BYTES,
        )
        _verify_retained_entry(
            entries[0],
            first_wire,
            worker_sha256,
            metallib_sha256,
        )
        first_decoded = inner._decode_after_portable_verification(
            first_wire
        )
        expected_initial = _initial_plan(
            plan["campaign_challenge_sha256"],
            worker_sha256,
            metallib_sha256,
            plan["schedule_sha256"],
        )
        expected_plan = _seal_plan_from_first_report(
            expected_initial,
            first_decoded,
        )
        _require(
            plan == expected_plan,
            "retained campaign plan is not the fixed soak plan",
        )

        expected_segments: dict[str, bytes] = {}
        for entry in entries:
            wire = _read_regular_file(
                segments
                / (entry["report_wire_sha256"].hex() + ".bin"),
                inner.EXPECTED_WIRE_BYTES,
            )
            _verify_retained_entry(
                entry,
                wire,
                worker_sha256,
                metallib_sha256,
            )
            expected_segments[
                entry["report_wire_sha256"].hex() + ".bin"
            ] = wire
        _require_exact_regular_objects(segments, expected_segments)

        expected_manifests: dict[str, bytes] = {}
        for generation in range(1, generation_count + 1):
            checkpoint_wire = campaign.make_manifest(
                plan,
                entries[:generation],
            )
            checkpoint = campaign.verify_manifest(checkpoint_wire)
            expected_manifests[
                checkpoint["manifest_sha256"].hex() + ".bin"
            ] = checkpoint_wire
        _require_exact_regular_objects(manifests, expected_manifests)

        before_sha256, after_sha256 = _resolve_environment_evidence(
            environments,
            plan["campaign_id_sha256"],
            generation_count,
            selector["environment_sha256"],
        )
        expected_environment_names = {before_sha256.hex() + ".json"}
        if after_sha256 != ZERO_DIGEST:
            expected_environment_names.add(
                after_sha256.hex() + ".json"
            )
        _require(
            {path.name for path in environments.iterdir()}
            == expected_environment_names,
            "retained environment object set is not canonical",
        )

        total_bytes = 0
        total_files = 0
        for directory, subdirectories, files in os.walk(
            root,
            followlinks=False,
        ):
            _require(
                all(
                    not (Path(directory) / name).is_symlink()
                    for name in subdirectories
                ),
                "retained campaign has a symlinked directory",
            )
            for name in files:
                info = (Path(directory) / name).lstat()
                _require(
                    stat.S_ISREG(info.st_mode),
                    "retained campaign has a non-regular file",
                )
                total_bytes += info.st_size
                total_files += 1
        _require(
            total_bytes <= plan["artifact_store_max_bytes"]
            and total_files <= ARTIFACT_STORE_MAX_FILES,
            "retained campaign exceeds its artifact bound",
        )
        process_boundary._verify_components_unchanged(
            worker_path,
            metallib_path,
            worker_sha256,
            metallib_sha256,
        )
        _require(
            _read_regular_file(active, campaign.SELECTOR_BYTES)
            == selector_wire,
            "active selector changed during offline verification",
        )
        return {
            "segments": len(entries),
            "process_generations": max(
                entry["process_generation"] for entry in entries
            ),
            "complete": len(entries) == SEGMENT_COUNT,
            "records": entries[-1]["cumulative_records"],
            "completed": entries[-1]["cumulative_completed"],
            "campaign_id_sha256": plan["campaign_id_sha256"],
            "final_entry_sha256": entries[-1]["entry_sha256"],
            "output_dir": root,
        }
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def verify_campaign(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    output_dir: os.PathLike[str] | str,
) -> dict[str, Any]:
    worker_path = os.fspath(worker)
    metallib_path = os.fspath(metallib)
    _require(worker_path and metallib_path, "missing worker or metallib")
    worker_sha256 = _file_sha256(worker_path)
    metallib_sha256 = _file_sha256(metallib_path)
    inner._native_build_sha256(worker_sha256, metallib_sha256)
    supervisor_sha256 = _supervisor_sha256()
    schedule_sha256 = _schedule_sha256(supervisor_sha256)
    authority_challenge = os.urandom(32)
    _require(authority_challenge != ZERO_DIGEST, "random challenge is zero")

    environment_before, environment_before_sha256 = (
        _capture_admitted_environment()
    )
    initial_plan = _initial_plan(
        authority_challenge,
        worker_sha256,
        metallib_sha256,
        schedule_sha256,
    )
    campaign_id_sha256 = campaign.derive_campaign_id(initial_plan)

    store = CampaignStore(output_dir)
    try:
        retained_before = store.write_environment(environment_before)
        _require(
            retained_before == environment_before_sha256,
            "retained before-environment root changed",
        )
        entries: list[dict[str, Any]] = []
        plan: Optional[dict[str, Any]] = None
        cumulative_duration_ns = 0
        previous_entry_sha256 = ZERO_DIGEST
        previous_report_sha256 = ZERO_DIGEST
        campaign_started = time.monotonic()

        for phase in range(2):
            phase_start = phase * SEGMENTS_PER_PROCESS
            persistent = _PersistentWorker(
                worker_path,
                metallib_path,
                worker_sha256,
                metallib_sha256,
            )
            try:
                for offset in range(SEGMENTS_PER_PROCESS):
                    ordinal = phase_start + offset
                    remaining = (
                        CAMPAIGN_WALL_TIMEOUT_SECONDS
                        - (time.monotonic() - campaign_started)
                    )
                    _require(
                        remaining > 0,
                        "native soak exceeded the campaign wall bound",
                    )
                    scheduled_action = _scheduled_action_sha256(
                        campaign_id_sha256,
                        schedule_sha256,
                        persistent.process_source_sha256,
                        ordinal,
                        _process_generation(ordinal),
                    )
                    challenge = campaign.derive_segment_challenge(
                        campaign_id_sha256,
                        ordinal,
                        _process_generation(ordinal),
                        previous_entry_sha256,
                        previous_report_sha256,
                        scheduled_action,
                    )
                    wire, duration_ns, rss = persistent.request(
                        challenge,
                        min(
                            MAXIMUM_SEGMENT_DURATION_NS / 1e9,
                            remaining,
                        ),
                    )
                    _require(
                        MINIMUM_SEGMENT_DURATION_NS
                        <= duration_ns
                        <= MAXIMUM_SEGMENT_DURATION_NS,
                        "native segment duration is outside the plan",
                    )
                    verification = inner.verify_native_wire(
                        wire,
                        worker_sha256,
                        metallib_sha256,
                        challenge,
                    )
                    decoded = inner._decode_after_portable_verification(
                        wire
                    )
                    _assert_segment_cadence(decoded)
                    if plan is None:
                        plan = _seal_plan_from_first_report(
                            initial_plan,
                            decoded,
                        )
                        _require(
                            plan["campaign_id_sha256"]
                            == campaign_id_sha256,
                            "sealed campaign identity changed",
                        )
                    store.write_segment(wire)
                    cumulative_duration_ns += duration_ns

                    phase_terminal = _is_phase_terminal(ordinal)
                    if phase_terminal:
                        persistent.close_cleanly()
                    value = _entry_value(
                        plan,
                        decoded,
                        verification,
                        ordinal,
                        previous_entry_sha256,
                        previous_report_sha256,
                        scheduled_action,
                        duration_ns,
                        cumulative_duration_ns,
                        rss,
                        persistent.process_source_sha256,
                        phase_terminal,
                    )
                    entry = campaign.make_entry(plan, value)
                    entries.append(entry)
                    previous_entry_sha256 = entry["entry_sha256"]
                    previous_report_sha256 = entry[
                        "verified_report_sha256"
                    ]

                    after_sha256 = ZERO_DIGEST
                    environment_after: Optional[dict[str, Any]] = None
                    if ordinal == SEGMENT_COUNT - 1:
                        (
                            environment_after,
                            after_sha256,
                        ) = _capture_admitted_environment()
                        _compare_environment_boundaries(
                            environment_before,
                            environment_after,
                        )
                        retained_after = store.write_environment(
                            environment_after
                        )
                        _require(
                            retained_after == after_sha256,
                            "retained after-environment root changed",
                        )
                    environment_root = environment_sha256(
                        campaign_id_sha256,
                        len(entries),
                        environment_before_sha256,
                        after_sha256,
                    )
                    store.publish(plan, entries, environment_root)
                _require(
                    persistent.closed,
                    "phase worker was not closed at its terminal segment",
                )
            except BaseException:
                persistent.abort()
                raise

            _require(plan is not None, "native campaign has no sealed plan")
            expected_generation = (phase + 1) * SEGMENTS_PER_PROCESS
            checkpoint_environment_root = environment_sha256(
                campaign_id_sha256,
                expected_generation,
                environment_before_sha256,
                after_sha256
                if expected_generation == SEGMENT_COUNT
                else ZERO_DIGEST,
            )
            reopened, _selector = store.recover(
                plan,
                expected_generation,
                checkpoint_environment_root,
                worker_sha256,
                metallib_sha256,
            )
            entries = list(reopened["entries"])
            previous_entry_sha256 = entries[-1]["entry_sha256"]
            previous_report_sha256 = entries[-1][
                "verified_report_sha256"
            ]

        _require(plan is not None, "native campaign did not seal a plan")
        _require(
            len(entries) == SEGMENT_COUNT
            and cumulative_duration_ns
            >= SEGMENT_COUNT * MINIMUM_SEGMENT_DURATION_NS,
            "native campaign did not reach its fixed duration",
        )
        _require(
            entries[-1]["cumulative_records"] == EXPECTED_TOTAL_RECORDS
            and entries[-1]["cumulative_completed"]
            == EXPECTED_TOTAL_COMPLETED,
            "native campaign aggregate changed",
        )
        _require(
            _supervisor_sha256() == supervisor_sha256,
            "native soak supervisor changed during the campaign",
        )
        return {
            "segments": len(entries),
            "process_generations": 2,
            "duration_ns": cumulative_duration_ns,
            "records": EXPECTED_TOTAL_RECORDS,
            "completed": EXPECTED_TOTAL_COMPLETED,
            "cancelled": EXPECTED_TOTAL_CANCELLED,
            "failed": EXPECTED_TOTAL_FAILED,
            "capacity_rejected": EXPECTED_TOTAL_CAPACITY,
            "pins": EXPECTED_TOTAL_PINS,
            "events": EXPECTED_TOTAL_EVENTS,
            "campaign_id_sha256": campaign_id_sha256,
            "final_entry_sha256": entries[-1]["entry_sha256"],
            "output_dir": Path(output_dir),
        }
    except (
        campaign.CampaignManifestError,
        inner.NativeMetalDisruptionReportError,
        process_boundary.NativeMetalReportError,
        OSError,
    ) as error:
        if isinstance(error, NativeMetalSoakError):
            raise
        raise NativeMetalSoakError(str(error)) from error
    finally:
        store.close()


def _run_with_watchdog(
    worker: str,
    metallib: str,
    output_dir: Optional[str],
) -> int:
    temporary: Optional[tempfile.TemporaryDirectory[str]] = None
    output = output_dir
    ephemeral = output is None
    if output is None:
        temporary = tempfile.TemporaryDirectory(
            prefix="glacier-native-metal-soak."
        )
        output = temporary.name
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--worker",
        os.path.abspath(worker),
        "--metallib",
        os.path.abspath(metallib),
        "--output-dir",
        os.path.abspath(output),
        "--supervised-child",
    ]
    if ephemeral:
        command.append("--ephemeral-output")
    repository_root = Path(__file__).resolve().parent.parent
    environment = {
        "LC_ALL": "C",
        "PATH": os.defpath,
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": str(repository_root),
    }
    process: Optional[subprocess.Popen[bytes]] = None
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=repository_root,
            env=environment,
            close_fds=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(
                timeout=CAMPAIGN_WALL_TIMEOUT_SECONDS
            )
        except subprocess.TimeoutExpired:
            with contextlib.suppress(OSError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=1.0)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(OSError):
                    os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
            if stderr:
                sys.stderr.buffer.write(
                    stderr[:MAX_SUPERVISOR_OUTPUT_BYTES]
                )
            print(
                "error: native Metal soak exceeded the %.0fs "
                "whole-run watchdog"
                % CAMPAIGN_WALL_TIMEOUT_SECONDS,
                file=sys.stderr,
            )
            return 1
        if (
            len(stdout) > MAX_SUPERVISOR_OUTPUT_BYTES
            or len(stderr) > MAX_SUPERVISOR_OUTPUT_BYTES
        ):
            print(
                "error: native Metal soak supervisor output exceeded its bound",
                file=sys.stderr,
            )
            return 1
        if stdout:
            sys.stdout.buffer.write(stdout)
        if stderr:
            sys.stderr.buffer.write(stderr)
        return process.returncode
    except OSError as error:
        print(
            "error: could not start native Metal soak watchdog: %s" % error,
            file=sys.stderr,
        )
        return 1
    finally:
        if process is not None and process.poll() is None:
            with contextlib.suppress(OSError):
                os.killpg(process.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=1.0)
        if temporary is not None:
            temporary.cleanup()


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run the fixed 12-segment, two-process native Metal soak gate"
        )
    )
    parser.add_argument(
        "--worker",
        required=True,
        help="persistent native Metal soak worker executable",
    )
    parser.add_argument(
        "--metallib",
        required=True,
        help="exact Metal shader library bound into every inner report",
    )
    parser.add_argument(
        "--output-dir",
        help=(
            "retain the verified content-addressed campaign store; "
            "the directory must not already contain an active selector"
        ),
    )
    parser.add_argument(
        "--verify-store",
        action="store_true",
        help=(
            "offline-verify a completed retained campaign instead of "
            "running native work"
        ),
    )
    parser.add_argument(
        "--supervised-child",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--ephemeral-output",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args(argv)

    if arguments.verify_store:
        if arguments.supervised_child or arguments.ephemeral_output:
            parser.error(
                "--verify-store cannot use internal supervisor options"
            )
        if arguments.output_dir is None:
            parser.error("--verify-store requires --output-dir")
        try:
            result = verify_retained_store(
                arguments.worker,
                arguments.metallib,
                arguments.output_dir,
            )
        except (
            NativeMetalSoakError,
            campaign.CampaignManifestError,
            inner.NativeMetalDisruptionReportError,
            process_boundary.NativeMetalReportError,
            OSError,
        ) as error:
            print("error: %s" % error, file=sys.stderr)
            return 1
        print(
            "ok native-metal-soak-store-v1 "
            "status=%s segments=%d processes=%d records=%d completed=%d "
            "campaign_id_sha256=%s final_entry_sha256=%s retained=%s"
            % (
                "complete" if result["complete"] else "partial",
                result["segments"],
                result["process_generations"],
                result["records"],
                result["completed"],
                result["campaign_id_sha256"].hex(),
                result["final_entry_sha256"].hex(),
                result["output_dir"],
            )
        )
        return 0

    if not arguments.supervised_child:
        if arguments.ephemeral_output:
            parser.error("--ephemeral-output is internal")
        return _run_with_watchdog(
            arguments.worker,
            arguments.metallib,
            arguments.output_dir,
        )

    if arguments.output_dir is None:
        parser.error("supervised child requires --output-dir")
    try:
        result = verify_campaign(
            arguments.worker,
            arguments.metallib,
            arguments.output_dir,
        )
    except (NativeMetalSoakError, OSError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1

    print(
        "ok native-metal-soak-report-v1 "
        "segments=%d processes=%d duration_ns=%d records=%d "
        "completed=%d cancelled=%d failed=%d capacity_rejected=%d "
        "pins=%d events=%d campaign_id_sha256=%s "
        "final_entry_sha256=%s%s"
        % (
            result["segments"],
            result["process_generations"],
            result["duration_ns"],
            result["records"],
            result["completed"],
            result["cancelled"],
            result["failed"],
            result["capacity_rejected"],
            result["pins"],
            result["events"],
            result["campaign_id_sha256"].hex(),
            result["final_entry_sha256"].hex(),
            " retained=%s" % result["output_dir"]
            if not arguments.ephemeral_output
            else "",
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
