#!/usr/bin/env python3
"""Run and verify fixed segmented production-native Metal campaigns.

The supervisor keeps one native worker alive for six paced W7 segments,
publishes a crash-atomic checkpoint after every independently verified inner
wire, terminates the phase according to the sealed schedule, then continues
the chain in a fresh process for six more segments. The W7b-a profile uses a
clean phase exit. The bounded W7b-b process-kill profile instead sends a real
``SIGKILL`` after segment six has been verified and retained but before its
manifest prefix is published. RSS is sampled from the worker process and Metal
``currentAllocatedSize`` is recomputed from the completed raw records. Neither
observation is relabelled as device residency or a proof of leak freedom.
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass
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
from typing import Any, Callable, Mapping, Optional, Sequence

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
OFFLINE_VERIFY_TIMEOUT_SECONDS = 30.0
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
PROCESS_KILL_SCHEDULE_DOMAIN = (
    b"glacier-w7b-metal-process-kill-schedule-v1\x00"
)
RSS_SOURCE_BASE_SHA256 = hashlib.sha256(
    b"/bin/ps -o rss= -p <persistent-worker-pid>; rss_kib*1024/v1"
).digest()
SUPERVISOR_CLOCK_SHA256 = hashlib.sha256(
    b"Python time.monotonic_ns supervisor clock/v1"
).digest()

ACTIVE_SELECTOR_NAME = ".glacier-workload-campaign-active-v1"
LOCK_NAME = ".glacier-workload-campaign.lock"
STORE_TEMP_SUFFIX = ".prepared-v1.tmp"
SELECTOR_TEMP_NAME = (
    ".%s%s" % (ACTIVE_SELECTOR_NAME, STORE_TEMP_SUFFIX)
)
PREFIX_BOUNDARY_SCHEMA = (
    "glacier.native-metal-soak/prefix-boundary-v1"
)
PREPARED_FINAL_SCHEMA = (
    "glacier.native-metal-soak/prepared-final-v1"
)
FINALIZED_BOUNDARY_SCHEMA = (
    "glacier.native-metal-soak/finalized-boundary-v1"
)
STORE_SHAPE_DOMAIN = b"glacier-w7b-metal-soak-store-shape-v1\x00"
PREFIX_GRANT_DOMAIN = b"glacier-w7b-metal-soak-prefix-grant-v1\x00"
FINALIZER_GRANT_DOMAIN = (
    b"glacier-w7b-metal-soak-finalizer-grant-v1\x00"
)
STORE_OBJECT_PHASES = (
    "create",
    "write_prefix",
    "write_complete",
    "file_fsync",
    "target_link",
    "temp_unlink",
    "directory_fsync",
)
STORE_SELECTOR_PHASES = (
    "create",
    "write_prefix",
    "write_complete",
    "file_fsync",
    "active_replace",
)
STORE_PUBLICATION_PHASES = tuple(
    (object_kind, operation)
    for object_kind in ("environment", "segment", "manifest")
    for operation in STORE_OBJECT_PHASES
) + tuple(
    ("selector", operation)
    for operation in STORE_SELECTOR_PHASES
) + (("store_root", "directory_fsync"),)
StoreIoHook = Callable[[str, str, str], None]
WorkerFactory = Callable[[str, str, bytes, bytes], Any]


@dataclass
class CampaignBoundaryHandle:
    """A verified boundary whose store remains exclusively locked.

    ``facts`` contains only JSON-serializable public receipts. Grant bytes are
    used to derive the receipt binding and are never retained by this handle or
    written to the campaign store. The caller must keep the handle alive until
    its outer supervisor has emitted the boundary receipt.
    """

    store: CampaignStore
    facts: dict[str, Any]

    def close(self) -> None:
        self.store.close()

    def __enter__(self) -> CampaignBoundaryHandle:
        return self

    def __exit__(
        self,
        _exception_type: object,
        _exception: object,
        _traceback: object,
    ) -> None:
        self.close()


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


def _schedule_sha256(
    supervisor_sha256: bytes,
    forced_process_restart: bool = False,
) -> bytes:
    return _sha256_parts(
        (
            PROCESS_KILL_SCHEDULE_DOMAIN
            if forced_process_restart
            else SCHEDULE_DOMAIN
        ),
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
    forced_process_restart: bool = False,
) -> bytes:
    if (
        forced_process_restart
        and ordinal == RESTART_AFTER_SEGMENT - 1
    ):
        action_tag = campaign.ACTION_FORCED_PHASE_END
    elif _is_phase_terminal(ordinal):
        action_tag = campaign.ACTION_GRACEFUL_PHASE_END
    else:
        action_tag = campaign.ACTION_NORMAL
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
    forced_process_restart: bool = False,
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
        "flags": (
            campaign.PLAN_FLAG_FORCED_PROCESS_RESTART
            if forced_process_restart
            else 0
        ),
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
            self._close_resources()
            raise NativeMetalSoakError(
                "could not open native Metal soak worker pipes"
            )
        try:
            self.selector = selectors.DefaultSelector()
            for stream, kind in (
                (self.process.stdout, "stdout"),
                (self.process.stderr, "stderr"),
            ):
                os.set_blocking(stream.fileno(), False)
                self.selector.register(stream, selectors.EVENT_READ, kind)
        except (KeyError, OSError, ValueError) as error:
            self._terminate()
            self._close_resources()
            raise NativeMetalSoakError(
                "could not register native Metal soak worker pipes: %s"
                % error
            ) from error
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

    def _close_resources(self) -> None:
        selector = getattr(self, "selector", None)
        if selector is not None:
            with contextlib.suppress(Exception):
                selector.close()
        process = getattr(self, "process", None)
        if process is None:
            return
        for stream in (
            process.stdin,
            process.stdout,
            process.stderr,
        ):
            if stream is not None:
                with contextlib.suppress(OSError, ValueError):
                    stream.close()

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
        self._close_resources()

    def kill_for_campaign(self) -> None:
        """Apply the scheduled POSIX process-kill boundary and reap it."""
        _require(not self.closed, "native soak worker is already closed")
        _require(
            self.process.poll() is None,
            "native soak worker exited before its scheduled process kill",
        )
        _require(
            not self.stdout and not self.stderr,
            "native soak worker has stale output before process kill",
        )
        self.closed = True
        try:
            os.kill(self.process.pid, signal.SIGKILL)
        except OSError as error:
            self._terminate()
            raise NativeMetalSoakError(
                "could not apply scheduled native worker SIGKILL: %s"
                % error
            ) from error
        try:
            self.process.wait(timeout=WORKER_EXIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as error:
            self._terminate()
            raise NativeMetalSoakError(
                "native soak worker was not reaped after SIGKILL"
            ) from error
        # Drain any pipe bytes made visible before the signal was delivered.
        for _ in range(4):
            self._read_ready(0.0)
        _require(
            self.process.returncode == -campaign.TERMINATION_SIGNAL_KILL,
            "native soak worker SIGKILL produced status %s"
            % self.process.returncode,
        )
        _require(
            not self.stdout and not self.stderr,
            "native soak worker emitted trailing output at process kill",
        )
        process_boundary._verify_components_unchanged(
            self.worker,
            self.metallib,
            self.worker_sha256,
            self.metallib_sha256,
        )
        self._close_resources()

    def abort(self) -> None:
        self._terminate()
        with contextlib.suppress(Exception):
            process_boundary._verify_components_unchanged(
                self.worker,
                self.metallib,
                self.worker_sha256,
                self.metallib_sha256,
            )
        self._close_resources()


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
    forced_process_restart = bool(
        plan["flags"] & campaign.PLAN_FLAG_FORCED_PROCESS_RESTART
    )
    forced_process_kill = (
        forced_process_restart
        and ordinal == RESTART_AFTER_SEGMENT - 1
    )
    if ordinal == RESTART_AFTER_SEGMENT - 1:
        provenance |= (
            campaign.PROVENANCE_FORCED_OS_PROCESS_KILL
            if forced_process_kill
            else campaign.PROVENANCE_PLANNED_GRACEFUL_RESTART
        )
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
        "exit_code_bits": (
            RUNNING_EXIT_CODE_BITS
            if forced_process_kill
            else 0
            if phase_exited_cleanly
            else RUNNING_EXIT_CODE_BITS
        ),
        "termination_signal": (
            campaign.TERMINATION_SIGNAL_KILL
            if forced_process_kill
            else 0
        ),
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


def _directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _regular_read_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _same_file_identity(
    left: os.stat_result,
    right: os.stat_result,
) -> bool:
    return (
        left.st_dev == right.st_dev
        and left.st_ino == right.st_ino
        and stat.S_IFMT(left.st_mode) == stat.S_IFMT(right.st_mode)
    )


def _entry_exists_at(directory_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _read_regular_at(
    directory_fd: int,
    name: str,
    maximum_bytes: int,
    *,
    expected_device: Optional[int] = None,
    require_private_single_link: bool = False,
) -> bytes:
    _require(
        name not in ("", ".", "..")
        and "/" not in name
        and maximum_bytes > 0,
        "invalid descriptor-relative file read",
    )
    descriptor = os.open(
        name,
        _regular_read_flags(),
        dir_fd=directory_fd,
    )
    try:
        before = os.fstat(descriptor)
        named_before = os.stat(
            name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISREG(before.st_mode)
            and stat.S_ISREG(named_before.st_mode)
            and _same_file_identity(before, named_before)
            and 0 <= before.st_size <= maximum_bytes,
            "campaign object is not a bounded regular file",
        )
        if expected_device is not None:
            _require(
                before.st_dev == expected_device,
                "campaign object crossed filesystem devices",
            )
        if require_private_single_link:
            _require(
                before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) & 0o077 == 0,
                "campaign object is not private and canonical",
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
        named_after = os.stat(
            name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        _require(
            (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
                before.st_nlink,
                stat.S_IMODE(before.st_mode),
            )
            == (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
                after.st_nlink,
                stat.S_IMODE(after.st_mode),
            )
            and _same_file_identity(after, named_after),
            "campaign object changed while being read",
        )
        return b"".join(chunks)
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


def _decode_environment_object(
    name: str,
    data: bytes,
) -> tuple[bytes, dict[str, Any], Any]:
    _require(
        name.endswith(".json")
        and len(name) == 69
        and name[:-5] == name[:-5].lower(),
        "environment object name is not canonical",
    )
    try:
        name_digest = bytes.fromhex(name[:-5])
    except ValueError as error:
        raise NativeMetalSoakError(
            "environment object name is not hexadecimal"
        ) from error
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
    return name_digest, decoded, captured_at


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
    return [
        _decode_environment_object(
            path.name,
            _read_regular_file(path, ENVIRONMENT_OBJECT_MAX_BYTES),
        )
        for path in paths
    ]


def _read_environment_objects_at(
    directory_fd: int,
    expected_identity: tuple[int, int],
) -> list[tuple[bytes, dict[str, Any], Any]]:
    opened = os.fstat(directory_fd)
    _require(
        stat.S_ISDIR(opened.st_mode)
        and (opened.st_dev, opened.st_ino) == expected_identity
        and stat.S_IMODE(opened.st_mode) & 0o077 == 0,
        "environment object directory identity changed",
    )
    names = sorted(os.listdir(directory_fd))
    _require(
        1 <= len(names) <= 2,
        "campaign store has an unexpected environment-object count",
    )
    return [
        _decode_environment_object(
            name,
            _read_regular_at(
                directory_fd,
                name,
                ENVIRONMENT_OBJECT_MAX_BYTES,
                expected_device=expected_identity[0],
                require_private_single_link=True,
            ),
        )
        for name in names
    ]


def _resolve_environment_evidence(
    directory: Path,
    campaign_id_sha256: bytes,
    generation: int,
    expected_environment_sha256: bytes,
) -> tuple[bytes, bytes]:
    return _resolve_environment_objects(
        _read_environment_objects(directory),
        campaign_id_sha256,
        generation,
        expected_environment_sha256,
    )


def _resolve_environment_evidence_at(
    directory_fd: int,
    expected_identity: tuple[int, int],
    campaign_id_sha256: bytes,
    generation: int,
    expected_environment_sha256: bytes,
) -> tuple[bytes, bytes]:
    return _resolve_environment_objects(
        _read_environment_objects_at(
            directory_fd,
            expected_identity,
        ),
        campaign_id_sha256,
        generation,
        expected_environment_sha256,
    )


def _resolve_environment_objects(
    objects: Sequence[tuple[bytes, dict[str, Any], Any]],
    campaign_id_sha256: bytes,
    generation: int,
    expected_environment_sha256: bytes,
) -> tuple[bytes, bytes]:
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


def _private_directory_identity(
    path: Path,
    *,
    expected_device: Optional[int] = None,
    require_private: bool = True,
) -> tuple[int, int]:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        named = path.lstat()
        _require(
            stat.S_ISDIR(opened.st_mode)
            and stat.S_ISDIR(named.st_mode)
            and (opened.st_dev, opened.st_ino)
            == (named.st_dev, named.st_ino),
            "campaign store directory identity changed",
        )
        if expected_device is not None:
            _require(
                opened.st_dev == expected_device,
                "campaign store crosses filesystem devices",
            )
        if require_private:
            _require(
                stat.S_IMODE(opened.st_mode) & 0o077 == 0,
                "campaign store directory is not private",
            )
        return opened.st_dev, opened.st_ino
    finally:
        os.close(descriptor)


class CampaignStore:
    """Crash-atomic content-addressed segment/manifest store."""

    def __init__(
        self,
        root: os.PathLike[str] | str,
        *,
        io_hook: Optional[StoreIoHook] = None,
        expected_active_selector: Optional[bytes] = None,
        expected_objects: Optional[
            Mapping[str, Mapping[str, bytes]]
        ] = None,
        _existing_mode: Optional[str] = None,
    ) -> None:
        self.root = Path(root)
        self.io_hook = io_hook
        self.poisoned = False
        self.existing_unverified = _existing_mode is not None
        self.root_fd = -1
        self.directory_fds: dict[str, int] = {}
        self.directory_identities: dict[str, tuple[int, int]] = {}
        _require(
            _existing_mode in (None, "selected", "prepared-or-selected"),
            "invalid existing campaign-store mode",
        )
        prepared_open = (
            expected_active_selector is not None
            or expected_objects is not None
        )
        _require(
            not (prepared_open and _existing_mode is not None),
            "campaign-store open modes conflict",
        )
        _require(
            (
                expected_active_selector is not None
                and expected_objects is not None
            )
            if prepared_open
            else (
                expected_active_selector is None
                and expected_objects is None
            ),
            "prepared campaign-store inputs are incomplete",
        )
        self.segments = self.root / "segments"
        self.manifests = self.root / "manifests"
        self.environments = self.root / "environments"
        object_directories = (
            self.segments,
            self.manifests,
            self.environments,
        )
        self.lock_path = self.root / LOCK_NAME
        expected_root_names = {
            *(directory.name for directory in object_directories),
            self.lock_path.name,
        }
        if prepared_open:
            _require(
                isinstance(expected_active_selector, bytes)
                and len(expected_active_selector)
                == campaign.SELECTOR_BYTES
                and expected_objects is not None
                and set(expected_objects)
                == {directory.name for directory in object_directories},
                "invalid prepared campaign-store predecessor",
            )
        root_exists = os.path.lexists(self.root)
        complete_empty_store = False
        if root_exists:
            try:
                root_info = self.root.lstat()
            except OSError as error:
                raise NativeMetalSoakError(
                    "campaign store root cannot be inspected"
                ) from error
            _require(
                stat.S_ISDIR(root_info.st_mode),
                "campaign store root is not a real directory",
            )
            root_names = {path.name for path in self.root.iterdir()}
            if _existing_mode is not None:
                allowed_existing_names = (
                    expected_root_names | {ACTIVE_SELECTOR_NAME}
                )
                allowed_prepared_names = allowed_existing_names | {
                    SELECTOR_TEMP_NAME
                }
                _require(
                    root_names == allowed_existing_names
                    or (
                        _existing_mode == "prepared-or-selected"
                        and root_names == allowed_prepared_names
                    ),
                    "existing campaign-store root is not canonical",
                )
                for directory in object_directories:
                    try:
                        _private_directory_identity(
                            directory,
                            require_private=False,
                        )
                    except (OSError, NativeMetalSoakError) as error:
                        raise NativeMetalSoakError(
                            (
                                "campaign store object directory "
                                "is not a real directory"
                            )
                        ) from error
            elif not prepared_open:
                _require(
                    ACTIVE_SELECTOR_NAME not in root_names,
                    (
                        "campaign output directory already has an "
                        "active selector"
                    ),
                )
                for directory in object_directories:
                    if directory.name in root_names:
                        try:
                            _private_directory_identity(
                                directory,
                                require_private=False,
                            )
                        except (OSError, NativeMetalSoakError) as error:
                            raise NativeMetalSoakError(
                                (
                                    "campaign store object directory "
                                    "is not a real directory"
                                )
                            ) from error
                _require(
                    root_names in (set(), expected_root_names),
                    (
                        "campaign output directory is not an empty "
                        "canonical store"
                    ),
                )
                complete_empty_store = root_names == expected_root_names
            else:
                prepared_without_lock = (
                    expected_root_names - {self.lock_path.name}
                ) | {ACTIVE_SELECTOR_NAME}
                if root_names == prepared_without_lock:
                    raise FileNotFoundError(self.lock_path)
                _require(
                    root_names
                    == expected_root_names | {ACTIVE_SELECTOR_NAME},
                    "prepared campaign-store root is not canonical",
                )
        elif prepared_open or _existing_mode is not None:
            raise NativeMetalSoakError(
                "existing campaign-store root does not exist"
            )
        else:
            self.root.mkdir(parents=True, mode=0o700)

        if (
            not prepared_open
            and _existing_mode is None
            and not complete_empty_store
        ):
            os.chmod(self.root, 0o700, follow_symlinks=False)
            for directory in object_directories:
                directory.mkdir(mode=0o700)
                os.chmod(directory, 0o700, follow_symlinks=False)
            _fsync_directory(self.root)

        try:
            self.root_fd = os.open(
                self.root,
                _directory_open_flags(),
            )
            root_opened = os.fstat(self.root_fd)
            root_named = self.root.lstat()
            _require(
                stat.S_ISDIR(root_opened.st_mode)
                and stat.S_ISDIR(root_named.st_mode)
                and _same_file_identity(root_opened, root_named)
                and stat.S_IMODE(root_opened.st_mode) & 0o077 == 0,
                "campaign store root identity changed",
            )
            self.root_identity = (
                root_opened.st_dev,
                root_opened.st_ino,
            )
            for directory in object_directories:
                descriptor = os.open(
                    directory.name,
                    _directory_open_flags(),
                    dir_fd=self.root_fd,
                )
                try:
                    opened = os.fstat(descriptor)
                    named = os.stat(
                        directory.name,
                        dir_fd=self.root_fd,
                        follow_symlinks=False,
                    )
                    _require(
                        stat.S_ISDIR(opened.st_mode)
                        and stat.S_ISDIR(named.st_mode)
                        and _same_file_identity(opened, named)
                        and opened.st_dev == self.root_identity[0]
                        and stat.S_IMODE(opened.st_mode) & 0o077 == 0,
                        (
                            "campaign store object directory is not "
                            "a private real directory"
                        ),
                    )
                except BaseException:
                    os.close(descriptor)
                    raise
                self.directory_fds[directory.name] = descriptor
                self.directory_identities[directory.name] = (
                    opened.st_dev,
                    opened.st_ino,
                )
        except BaseException:
            self._close_namespace_descriptors()
            raise

        if not prepared_open and _existing_mode is None:
            try:
                _require(
                    all(
                        not os.listdir(descriptor)
                        for descriptor in self.directory_fds.values()
                    ),
                    (
                        "campaign output directory is not an empty "
                        "canonical store"
                    ),
                )
            except BaseException:
                self._close_namespace_descriptors()
                raise

        lock_flags = (
            os.O_RDWR
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )
        created_lock = (
            not prepared_open
            and _existing_mode is None
            and not complete_empty_store
        )
        if created_lock:
            lock_flags |= os.O_CREAT | os.O_EXCL
        try:
            lock_descriptor = os.open(
                LOCK_NAME,
                lock_flags,
                0o600,
                dir_fd=self.root_fd,
            )
        except BaseException:
            self._close_namespace_descriptors()
            raise
        try:
            lock_info = os.fstat(lock_descriptor)
            lock_named = os.stat(
                LOCK_NAME,
                dir_fd=self.root_fd,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISREG(lock_info.st_mode)
                and stat.S_ISREG(lock_named.st_mode)
                and lock_info.st_dev == self.root_identity[0]
                and lock_info.st_nlink == 1
                and stat.S_IMODE(lock_info.st_mode) & 0o077 == 0
                and _same_file_identity(lock_info, lock_named),
                (
                    "campaign lock is not a private single-link "
                    "regular file"
                ),
            )
            if created_lock:
                os.fchmod(lock_descriptor, 0o600)
                os.fsync(self.root_fd)
        except BaseException:
            os.close(lock_descriptor)
            self._close_namespace_descriptors()
            raise
        self.lock_identity = (lock_info.st_dev, lock_info.st_ino)
        self.lock = os.fdopen(
            lock_descriptor,
            (
                "r+b"
                if prepared_open or _existing_mode is not None
                else "a+b"
            ),
        )
        try:
            fcntl.flock(
                self.lock.fileno(),
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except OSError as error:
            self.lock.close()
            self._close_namespace_descriptors()
            raise NativeMetalSoakError(
                "campaign store is already locked"
            ) from error
        try:
            self._verify_namespace()
            if _existing_mode is not None:
                expected_names = expected_root_names | {
                    ACTIVE_SELECTOR_NAME
                }
                actual_names = set(os.listdir(self.root_fd))
                _require(
                    actual_names == expected_names
                    or (
                        _existing_mode == "prepared-or-selected"
                        and actual_names
                        == expected_names | {SELECTOR_TEMP_NAME}
                    ),
                    "existing campaign-store root is not canonical",
                )
                _read_regular_at(
                    self.root_fd,
                    ACTIVE_SELECTOR_NAME,
                    campaign.SELECTOR_BYTES,
                    expected_device=self.root_identity[0],
                    require_private_single_link=True,
                )
                if SELECTOR_TEMP_NAME in actual_names:
                    _read_regular_at(
                        self.root_fd,
                        SELECTOR_TEMP_NAME,
                        campaign.SELECTOR_BYTES,
                        expected_device=self.root_identity[0],
                        require_private_single_link=True,
                    )
                self._verify_namespace()
            elif expected_active_selector is None:
                _require(
                    expected_objects is None,
                    "prepared objects require a prepared selector",
                )
                _require(
                    not _entry_exists_at(
                        self.root_fd,
                        ACTIVE_SELECTOR_NAME,
                    ),
                    "campaign output directory already has an active selector",
                )
                _require(
                    set(os.listdir(self.root_fd)) == expected_root_names
                    and all(
                        not os.listdir(descriptor)
                        for descriptor in self.directory_fds.values()
                    ),
                    (
                        "campaign output directory is not an empty "
                        "canonical store"
                    ),
                )
            else:
                _require(
                    set(os.listdir(self.root_fd))
                    == expected_root_names | {ACTIVE_SELECTOR_NAME},
                    "prepared campaign-store root is not canonical",
                )
                _require(
                    _read_regular_at(
                        self.root_fd,
                        ACTIVE_SELECTOR_NAME,
                        campaign.SELECTOR_BYTES,
                        expected_device=self.root_identity[0],
                        require_private_single_link=True,
                    )
                    == expected_active_selector,
                    "prepared campaign-store selector changed",
                )
                for directory in object_directories:
                    objects = expected_objects[directory.name]
                    descriptor = self.directory_fds[directory.name]
                    _require(
                        isinstance(objects, Mapping)
                        and set(objects) == set(os.listdir(descriptor)),
                        (
                            "prepared campaign-store object set "
                            "changed"
                        ),
                    )
                    for name, data in objects.items():
                        _require(
                            isinstance(name, str)
                            and name not in ("", ".", "..")
                            and "/" not in name
                            and isinstance(data, bytes)
                            and _read_regular_at(
                                descriptor,
                                name,
                                len(data),
                                expected_device=self.root_identity[0],
                                require_private_single_link=True,
                            )
                            == data,
                            (
                                "prepared campaign-store object "
                                "changed"
                            ),
                        )
                self._verify_namespace()
        except BaseException:
            with contextlib.suppress(OSError):
                fcntl.flock(self.lock.fileno(), fcntl.LOCK_UN)
            self.lock.close()
            self._close_namespace_descriptors()
            raise

    @classmethod
    def open_prepared(
        cls,
        root: os.PathLike[str] | str,
        *,
        expected_active_selector: bytes,
        expected_objects: Mapping[str, Mapping[str, bytes]],
        io_hook: Optional[StoreIoHook] = None,
    ) -> CampaignStore:
        """Open one exact predecessor for a pre-authorized publication."""
        return cls(
            root,
            io_hook=io_hook,
            expected_active_selector=expected_active_selector,
            expected_objects=expected_objects,
        )

    @classmethod
    def _open_existing_locked(
        cls,
        root: os.PathLike[str] | str,
        *,
        allow_prepared_selector: bool = False,
        io_hook: Optional[StoreIoHook] = None,
    ) -> CampaignStore:
        """Open an existing namespace, but withhold writer authority.

        Only the bounded resume/finalizer entry points below authorize this
        handle after reconstructing and matching an exact grant-bound state.
        """
        return cls(
            root,
            io_hook=io_hook,
            _existing_mode=(
                "prepared-or-selected"
                if allow_prepared_selector
                else "selected"
            ),
        )

    def _authorize_existing_writer(self) -> None:
        _require(
            self.existing_unverified,
            "existing campaign-store writer was already authorized",
        )
        self._guard_namespace()
        self.existing_unverified = False

    def _close_namespace_descriptors(self) -> None:
        for descriptor in self.directory_fds.values():
            with contextlib.suppress(OSError):
                os.close(descriptor)
        self.directory_fds.clear()
        if self.root_fd >= 0:
            with contextlib.suppress(OSError):
                os.close(self.root_fd)
            self.root_fd = -1

    def _verify_namespace(self) -> None:
        _require(
            self.root_fd >= 0,
            "campaign store namespace is closed",
        )
        root_opened = os.fstat(self.root_fd)
        root_named = self.root.lstat()
        _require(
            stat.S_ISDIR(root_opened.st_mode)
            and stat.S_ISDIR(root_named.st_mode)
            and _same_file_identity(root_opened, root_named)
            and (
                root_opened.st_dev,
                root_opened.st_ino,
            )
            == self.root_identity
            and stat.S_IMODE(root_opened.st_mode) & 0o077 == 0,
            "campaign store root namespace changed",
        )
        for name, descriptor in self.directory_fds.items():
            opened = os.fstat(descriptor)
            named = os.stat(
                name,
                dir_fd=self.root_fd,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISDIR(opened.st_mode)
                and stat.S_ISDIR(named.st_mode)
                and _same_file_identity(opened, named)
                and (
                    opened.st_dev,
                    opened.st_ino,
                )
                == self.directory_identities[name]
                and opened.st_dev == self.root_identity[0]
                and stat.S_IMODE(opened.st_mode) & 0o077 == 0,
                "campaign store object-directory namespace changed",
            )
        lock_opened = os.fstat(self.lock.fileno())
        lock_named = os.stat(
            LOCK_NAME,
            dir_fd=self.root_fd,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISREG(lock_opened.st_mode)
            and stat.S_ISREG(lock_named.st_mode)
            and _same_file_identity(lock_opened, lock_named)
            and (
                lock_opened.st_dev,
                lock_opened.st_ino,
            )
            == self.lock_identity
            and lock_opened.st_dev == self.root_identity[0]
            and lock_opened.st_nlink == 1
            and stat.S_IMODE(lock_opened.st_mode) & 0o077 == 0,
            "campaign store lock namespace changed",
        )

    def _guard_namespace(self) -> None:
        try:
            self._verify_namespace()
        except NativeMetalSoakError:
            self.poisoned = True
            raise
        except OSError as error:
            self.poisoned = True
            raise NativeMetalSoakError(
                "campaign store namespace changed"
            ) from error

    def close(self) -> None:
        if not self.lock.closed:
            with contextlib.suppress(OSError):
                fcntl.flock(self.lock.fileno(), fcntl.LOCK_UN)
            self.lock.close()
        self._close_namespace_descriptors()

    def _require_writer(self) -> None:
        _require(
            not self.lock.closed,
            "campaign store writer is closed",
        )
        _require(
            not self.existing_unverified,
            "existing campaign store has not passed grant-bound recovery",
        )
        _require(
            not self.poisoned,
            "campaign store writer is poisoned; use fresh recovery",
        )
        self._guard_namespace()

    def _io(self, timing: str, object_kind: str, operation: str) -> None:
        if self.io_hook is not None:
            self.io_hook(timing, object_kind, operation)

    def _run_io(
        self,
        object_kind: str,
        operation: str,
        action: Callable[[], Any],
    ) -> Any:
        self._guard_namespace()
        self._io("before", object_kind, operation)
        self._guard_namespace()
        result = action()
        self._guard_namespace()
        self._io("after", object_kind, operation)
        self._guard_namespace()
        return result

    def _create_temporary(
        self,
        object_kind: str,
        directory_fd: int,
        temporary_name: str,
    ) -> int:
        self._guard_namespace()
        self._io("before", object_kind, "create")
        self._guard_namespace()
        descriptor = os.open(
            temporary_name,
            (
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0)
            ),
            0o600,
            dir_fd=directory_fd,
        )
        try:
            self._guard_namespace()
            self._io("after", object_kind, "create")
            self._guard_namespace()
        except BaseException:
            os.close(descriptor)
            raise
        return descriptor

    def _immutable(
        self,
        directory: Path,
        name: str,
        data: bytes,
        object_kind: str,
        maximum_store_bytes: int = ARTIFACT_STORE_MAX_BYTES,
    ) -> Path:
        self._require_writer()
        target = directory / name
        directory_fd = self.directory_fds[directory.name]
        if _entry_exists_at(directory_fd, name):
            _require(
                _read_regular_at(
                    directory_fd,
                    name,
                    len(data),
                    expected_device=self.root_identity[0],
                    require_private_single_link=True,
                )
                == data,
                "content-addressed object collision",
            )
            descriptor = os.open(
                name,
                _regular_read_flags(),
                dir_fd=directory_fd,
            )
            try:
                self._guard_namespace()
                info = os.fstat(descriptor)
                _require(
                    stat.S_ISREG(info.st_mode)
                    and info.st_dev == self.root_identity[0]
                    and info.st_nlink == 1
                    and stat.S_IMODE(info.st_mode) & 0o077 == 0,
                    "campaign object is not private and canonical",
                )
                os.fsync(descriptor)
                self._guard_namespace()
            finally:
                os.close(descriptor)
            self._guard_namespace()
            os.fsync(directory_fd)
            self._guard_namespace()
            return target
        self._preflight_target(
            directory_fd,
            name,
            len(data),
            maximum_store_bytes,
            hard_link=True,
        )
        _require(len(data) >= 2, "campaign object is too short")
        temporary_name = ".%s%s" % (name, STORE_TEMP_SUFFIX)
        descriptor: Optional[int] = None
        try:
            descriptor = self._create_temporary(
                object_kind,
                directory_fd,
                temporary_name,
            )
            prefix_bytes = min(4096, len(data) - 1)
            self._run_io(
                object_kind,
                "write_prefix",
                lambda: _write_all(descriptor, data[:prefix_bytes]),
            )
            self._run_io(
                object_kind,
                "write_complete",
                lambda: _write_all(descriptor, data[prefix_bytes:]),
            )
            self._run_io(
                object_kind,
                "file_fsync",
                lambda: os.fsync(descriptor),
            )
            os.close(descriptor)
            descriptor = None
            self._run_io(
                object_kind,
                "target_link",
                lambda: os.link(
                    temporary_name,
                    name,
                    src_dir_fd=directory_fd,
                    dst_dir_fd=directory_fd,
                    follow_symlinks=False,
                ),
            )
            self._run_io(
                object_kind,
                "temp_unlink",
                lambda: os.unlink(
                    temporary_name,
                    dir_fd=directory_fd,
                ),
            )
            self._run_io(
                object_kind,
                "directory_fsync",
                lambda: os.fsync(directory_fd),
            )
        except BaseException:
            self.poisoned = True
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary_name, dir_fd=directory_fd)
            raise
        return target

    def write_environment(
        self,
        snapshot: Mapping[str, Any],
    ) -> bytes:
        self._require_writer()
        data = _canonical_json(snapshot)
        digest = hashlib.sha256(data).digest()
        self._immutable(
            self.environments,
            digest.hex() + ".json",
            data,
            "environment",
        )
        return digest

    def write_segment(self, wire: bytes) -> bytes:
        self._require_writer()
        _require(
            len(wire) == inner.EXPECTED_WIRE_BYTES,
            "segment wire has an unexpected length",
        )
        digest = hashlib.sha256(wire).digest()
        self._immutable(
            self.segments,
            digest.hex() + ".bin",
            wire,
            "segment",
        )
        return digest

    def publish(
        self,
        plan: Mapping[str, Any],
        entries: Sequence[Mapping[str, Any]],
        environment_root_sha256: bytes,
    ) -> tuple[bytes, bytes]:
        self._require_writer()
        manifest_wire = campaign.make_manifest(plan, entries)
        decoded = campaign.verify_manifest(manifest_wire)
        manifest_sha256 = decoded["manifest_sha256"]
        selector_wire = campaign.make_selector(
            decoded,
            environment_root_sha256,
        )
        campaign.verify_selector(
            manifest_wire,
            selector_wire,
            environment_root_sha256,
        )
        manifest_name = manifest_sha256.hex() + ".bin"
        self._preflight_publication(
            manifest_name,
            len(manifest_wire),
            len(selector_wire),
            plan["artifact_store_max_bytes"],
        )
        self._immutable(
            self.manifests,
            manifest_name,
            manifest_wire,
            "manifest",
            plan["artifact_store_max_bytes"],
        )
        try:
            self._prepare_selector(selector_wire)
            self._commit_prepared_selector(selector_wire)
        except BaseException:
            self.poisoned = True
            with contextlib.suppress(FileNotFoundError):
                os.unlink(SELECTOR_TEMP_NAME, dir_fd=self.root_fd)
            raise
        return manifest_wire, selector_wire

    def _prepare_selector(self, selector_wire: bytes) -> None:
        self._require_writer()
        _require(
            isinstance(selector_wire, bytes)
            and len(selector_wire) == campaign.SELECTOR_BYTES,
            "prepared selector has an unexpected length",
        )
        descriptor: Optional[int] = None
        try:
            descriptor = self._create_temporary(
                "selector",
                self.root_fd,
                SELECTOR_TEMP_NAME,
            )
            prefix_bytes = min(4096, len(selector_wire) - 1)
            self._run_io(
                "selector",
                "write_prefix",
                lambda: _write_all(
                    descriptor,
                    selector_wire[:prefix_bytes],
                ),
            )
            self._run_io(
                "selector",
                "write_complete",
                lambda: _write_all(
                    descriptor,
                    selector_wire[prefix_bytes:],
                ),
            )
            self._run_io(
                "selector",
                "file_fsync",
                lambda: os.fsync(descriptor),
            )
            os.close(descriptor)
            descriptor = None
        except BaseException:
            self.poisoned = True
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            with contextlib.suppress(FileNotFoundError):
                os.unlink(SELECTOR_TEMP_NAME, dir_fd=self.root_fd)
            raise

    def _commit_prepared_selector(self, selector_wire: bytes) -> None:
        self._require_writer()
        _require(
            _read_regular_at(
                self.root_fd,
                SELECTOR_TEMP_NAME,
                campaign.SELECTOR_BYTES,
                expected_device=self.root_identity[0],
                require_private_single_link=True,
            )
            == selector_wire,
            "prepared selector candidate changed",
        )
        self._run_io(
            "selector",
            "active_replace",
            lambda: os.replace(
                SELECTOR_TEMP_NAME,
                ACTIVE_SELECTOR_NAME,
                src_dir_fd=self.root_fd,
                dst_dir_fd=self.root_fd,
            ),
        )
        self._run_io(
            "store_root",
            "directory_fsync",
            lambda: os.fsync(self.root_fd),
        )

    def prepare_final_publication(
        self,
        plan: Mapping[str, Any],
        entries: Sequence[Mapping[str, Any]],
        environment_root_sha256: bytes,
    ) -> tuple[bytes, bytes, bytes]:
        """Prepare only the fixed generation-11 to generation-12 switch.

        The immutable successor manifest and the complete 192-byte selector
        candidate are file-synced. The active generation-11 selector is left
        untouched and the root directory is intentionally not synced here.
        """
        self._require_writer()
        _require(
            campaign.SELECTOR_BYTES == 192,
            "fixed campaign selector ABI changed",
        )
        _require(
            len(entries) == SEGMENT_COUNT,
            "prepared final publication is not generation 12",
        )
        predecessor_manifest_wire = campaign.make_manifest(
            plan,
            entries[:-1],
        )
        predecessor_manifest = campaign.verify_manifest(
            predecessor_manifest_wire
        )
        predecessor_selector_wire = _read_regular_at(
            self.root_fd,
            ACTIVE_SELECTOR_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        predecessor_selector = campaign.decode_selector(
            predecessor_selector_wire
        )
        _require(
            predecessor_selector["generation"] == SEGMENT_COUNT - 1
            and predecessor_selector["manifest_sha256"]
            == predecessor_manifest["manifest_sha256"],
            "prepared final predecessor is not exact generation 11",
        )
        retained_predecessor_manifest = _read_regular_at(
            self.directory_fds[self.manifests.name],
            predecessor_manifest["manifest_sha256"].hex() + ".bin",
            plan["encoded_bytes"],
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        _require(
            retained_predecessor_manifest == predecessor_manifest_wire,
            "prepared final predecessor manifest changed",
        )

        manifest_wire = campaign.make_manifest(plan, entries)
        decoded = campaign.verify_manifest(manifest_wire)
        manifest_sha256 = decoded["manifest_sha256"]
        selector_wire = campaign.make_selector(
            decoded,
            environment_root_sha256,
        )
        selector = campaign.verify_selector(
            manifest_wire,
            selector_wire,
            environment_root_sha256,
        )
        _require(
            selector["generation"] == SEGMENT_COUNT,
            "prepared final successor is not generation 12",
        )
        manifest_name = manifest_sha256.hex() + ".bin"
        self._preflight_publication(
            manifest_name,
            len(manifest_wire),
            len(selector_wire),
            plan["artifact_store_max_bytes"],
        )
        self._immutable(
            self.manifests,
            manifest_name,
            manifest_wire,
            "manifest",
            plan["artifact_store_max_bytes"],
        )
        try:
            self._prepare_selector(selector_wire)
        except BaseException:
            self.poisoned = True
            raise
        _require(
            _read_regular_at(
                self.root_fd,
                ACTIVE_SELECTOR_NAME,
                campaign.SELECTOR_BYTES,
                expected_device=self.root_identity[0],
                require_private_single_link=True,
            )
            == predecessor_selector_wire,
            "active selector changed while preparing generation 12",
        )
        return (
            predecessor_selector_wire,
            manifest_wire,
            selector_wire,
        )

    def roll_forward_prepared_final(
        self,
        predecessor_selector_wire: bytes,
        successor_selector_wire: bytes,
    ) -> str:
        """Apply or recognize one exact prepared 11-to-12 selector switch."""
        self._require_writer()
        active = _read_regular_at(
            self.root_fd,
            ACTIVE_SELECTOR_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        if active == predecessor_selector_wire:
            self._commit_prepared_selector(successor_selector_wire)
            return "applied"
        _require(
            active == successor_selector_wire
            and not _entry_exists_at(self.root_fd, SELECTOR_TEMP_NAME),
            "prepared final selector is neither predecessor nor successor",
        )
        self._run_io(
            "store_root",
            "directory_fsync",
            lambda: os.fsync(self.root_fd),
        )
        return "already_applied"

    def _usage(self) -> tuple[int, int]:
        self._guard_namespace()
        total = 0
        count = 0
        try:
            for name in os.listdir(self.root_fd):
                info = os.stat(
                    name,
                    dir_fd=self.root_fd,
                    follow_symlinks=False,
                )
                if name in self.directory_fds:
                    _require(
                        stat.S_ISDIR(info.st_mode)
                        and (info.st_dev, info.st_ino)
                        == self.directory_identities[name],
                        "campaign store directory layout changed",
                    )
                    continue
                _require(
                    stat.S_ISREG(info.st_mode)
                    and info.st_dev == self.root_identity[0]
                    and info.st_nlink == 1
                    and stat.S_IMODE(info.st_mode) & 0o077 == 0,
                    "campaign store has a non-regular file",
                )
                total += info.st_size
                count += 1
            for descriptor in self.directory_fds.values():
                for name in os.listdir(descriptor):
                    info = os.stat(
                        name,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    _require(
                        stat.S_ISREG(info.st_mode)
                        and info.st_dev == self.root_identity[0]
                        and info.st_nlink == 1
                        and stat.S_IMODE(info.st_mode) & 0o077 == 0,
                        "campaign store has a non-regular file",
                    )
                    total += info.st_size
                    count += 1
        except NativeMetalSoakError:
            self.poisoned = True
            raise
        except OSError as error:
            self.poisoned = True
            raise NativeMetalSoakError(
                "campaign store contents changed during accounting"
            ) from error
        self._guard_namespace()
        return total, count

    def _preflight_target(
        self,
        directory_fd: int,
        target_name: str,
        target_bytes: int,
        maximum_store_bytes: int,
        *,
        replacing: bool = False,
        hard_link: bool = False,
    ) -> None:
        _require(
            0 <= target_bytes <= maximum_store_bytes,
            "campaign object exceeds the store byte bound",
        )
        _require(
            target_name not in ("", ".", "..")
            and "/" not in target_name,
            "campaign target name is not canonical",
        )
        total, count = self._usage()
        original_total = total
        original_count = count
        if _entry_exists_at(directory_fd, target_name):
            info = os.stat(
                target_name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
            _require(
                replacing
                and stat.S_ISREG(info.st_mode)
                and info.st_dev == self.root_identity[0],
                "campaign target unexpectedly exists",
            )
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
        if hard_link:
            peak_total = original_total + 2 * target_bytes
            peak_count = original_count + 2
        else:
            peak_total = original_total + target_bytes
            peak_count = original_count + 1
        _require(
            peak_total <= maximum_store_bytes,
            "campaign transaction would exceed its peak byte bound",
        )
        _require(
            peak_count <= ARTIFACT_STORE_MAX_FILES,
            "campaign transaction would exceed its peak file bound",
        )

    def _preflight_publication(
        self,
        manifest_name: str,
        manifest_bytes: int,
        selector_bytes: int,
        maximum_store_bytes: int,
    ) -> None:
        _require(
            manifest_name not in ("", ".", "..")
            and "/" not in manifest_name
            and 0 <= manifest_bytes <= maximum_store_bytes
            and 0 <= selector_bytes <= maximum_store_bytes,
            "campaign publication target is not canonical",
        )
        total, count = self._usage()
        peak_total = total
        peak_count = count
        manifests_fd = self.directory_fds[self.manifests.name]
        if _entry_exists_at(manifests_fd, manifest_name):
            manifest_info = os.stat(
                manifest_name,
                dir_fd=manifests_fd,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISREG(manifest_info.st_mode)
                and manifest_info.st_dev == self.root_identity[0],
                "campaign manifest target unexpectedly exists",
            )
        else:
            peak_total = max(peak_total, total + 2 * manifest_bytes)
            peak_count = max(peak_count, count + 2)
            total += manifest_bytes
            count += 1
        if _entry_exists_at(self.root_fd, ACTIVE_SELECTOR_NAME):
            active_info = os.stat(
                ACTIVE_SELECTOR_NAME,
                dir_fd=self.root_fd,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISREG(active_info.st_mode)
                and active_info.st_dev == self.root_identity[0],
                "campaign selector target unexpectedly exists",
            )
            final_total = total - active_info.st_size + selector_bytes
            final_count = count
        else:
            final_total = total + selector_bytes
            final_count = count + 1
        peak_total = max(peak_total, total + selector_bytes, final_total)
        peak_count = max(peak_count, count + 1, final_count)
        _require(
            peak_total <= maximum_store_bytes,
            "campaign publication exceeds its peak byte bound",
        )
        _require(
            peak_count <= ARTIFACT_STORE_MAX_FILES,
            "campaign publication exceeds its peak file bound",
        )

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
        self._require_writer()
        selector_wire = _read_regular_at(
            self.root_fd,
            ACTIVE_SELECTOR_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        selector = campaign.decode_selector(selector_wire)
        _require(
            selector["generation"] == expected_generation,
            "active selector generation changed",
        )
        manifest_name = selector["manifest_sha256"].hex() + ".bin"
        manifest_wire = _read_regular_at(
            self.directory_fds[self.manifests.name],
            manifest_name,
            expected_plan["encoded_bytes"],
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        manifest = campaign.verify_manifest(manifest_wire)
        campaign.verify_selector(
            manifest_wire,
            selector_wire,
            environment_root_sha256,
        )
        self._guard_namespace()
        _resolve_environment_evidence_at(
            self.directory_fds[self.environments.name],
            self.directory_identities[self.environments.name],
            expected_plan["campaign_id_sha256"],
            expected_generation,
            environment_root_sha256,
        )
        self._guard_namespace()
        _require(
            manifest["plan"] == dict(expected_plan),
            "reopened campaign plan changed",
        )
        _require(
            len(manifest["entries"]) == expected_generation,
            "reopened manifest prefix length changed",
        )
        segments_fd = self.directory_fds[self.segments.name]
        for entry in manifest["entries"]:
            wire = _read_regular_at(
                segments_fd,
                entry["report_wire_sha256"].hex() + ".bin",
                inner.EXPECTED_WIRE_BYTES,
                expected_device=self.root_identity[0],
                require_private_single_link=True,
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
        self._guard_namespace()
        return manifest, selector_wire


def _require_boundary_grant(value: bytes, label: str) -> None:
    _require(
        isinstance(value, bytes)
        and len(value) == 32
        and value != ZERO_DIGEST,
        "%s must be one nonzero 32-byte grant" % label,
    )


def _is_nonzero_hex_digest(value: object) -> bool:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or value != value.lower()
    ):
        return False
    try:
        return bytes.fromhex(value) != ZERO_DIGEST
    except ValueError:
        return False


def _challenge_from_facts(
    facts: Mapping[str, Any],
    field: str,
) -> bytes:
    try:
        value = bytes.fromhex(str(facts[field]))
    except (KeyError, ValueError) as error:
        raise NativeMetalSoakError(
            "%s is not a canonical boundary challenge" % field
        ) from error
    _require_boundary_grant(value, field)
    return value


def _external_grant_use_sha256(
    domain: bytes,
    grant_sha256: bytes,
    predecessor_facts: Mapping[str, Any],
    successor_facts: Mapping[str, Any],
) -> bytes:
    """Bind one campaign-layer grant to the exact state where it was used."""
    _require_boundary_grant(grant_sha256, "external authority grant")
    return _sha256_parts(
        domain,
        grant_sha256,
        _canonical_json(predecessor_facts),
        _canonical_json(successor_facts),
    )


def resume_grant_use_sha256(
    resume_grant_sha256: bytes,
    prefix_facts: Mapping[str, Any],
    prepared_facts: Mapping[str, Any],
) -> bytes:
    """Bind an externally derived resume grant to its exact use."""
    successor = dict(prepared_facts)
    successor.pop("resume_grant_binding_sha256", None)
    return _external_grant_use_sha256(
        PREFIX_GRANT_DOMAIN,
        resume_grant_sha256,
        prefix_facts,
        successor,
    )


def finalizer_grant_use_sha256(
    finalizer_grant_sha256: bytes,
    prepared_facts: Mapping[str, Any],
    finalized_facts: Mapping[str, Any],
) -> bytes:
    """Bind an externally derived finalizer grant to its exact use."""
    successor = dict(finalized_facts)
    successor.pop("finalizer_grant_binding_sha256", None)
    return _external_grant_use_sha256(
        FINALIZER_GRANT_DOMAIN,
        finalizer_grant_sha256,
        prepared_facts,
        successor,
    )


def _store_shape_sha256(
    store: CampaignStore,
    *,
    root_overrides: Optional[Mapping[str, bytes]] = None,
) -> bytes:
    """Hash exact logical names, modes, lengths, and contents under lock."""
    store._guard_namespace()
    overrides = {} if root_overrides is None else dict(root_overrides)
    _require(
        all(
            isinstance(name, str)
            and name not in ("", ".", "..")
            and "/" not in name
            and isinstance(data, bytes)
            for name, data in overrides.items()
        ),
        "campaign store shape override is invalid",
    )
    records: list[dict[str, Any]] = []
    for name in sorted(os.listdir(store.root_fd)):
        if name in overrides:
            continue
        info = os.stat(
            name,
            dir_fd=store.root_fd,
            follow_symlinks=False,
        )
        if name in store.directory_fds:
            _require(
                stat.S_ISDIR(info.st_mode),
                "campaign store shape directory changed",
            )
            records.append(
                {
                    "path": name + "/",
                    "kind": "directory",
                    "mode": stat.S_IMODE(info.st_mode),
                }
            )
            continue
        data = _read_regular_at(
            store.root_fd,
            name,
            ARTIFACT_STORE_MAX_BYTES,
            expected_device=store.root_identity[0],
            require_private_single_link=True,
        )
        records.append(
            {
                "path": name,
                "kind": "file",
                "mode": stat.S_IMODE(info.st_mode),
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    for name, data in sorted(overrides.items()):
        records.append(
            {
                "path": name,
                "kind": "file",
                "mode": 0o600,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    for directory_name, descriptor in sorted(
        store.directory_fds.items()
    ):
        for name in sorted(os.listdir(descriptor)):
            info = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            data = _read_regular_at(
                descriptor,
                name,
                ARTIFACT_STORE_MAX_BYTES,
                expected_device=store.root_identity[0],
                require_private_single_link=True,
            )
            records.append(
                {
                    "path": directory_name + "/" + name,
                    "kind": "file",
                    "mode": stat.S_IMODE(info.st_mode),
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
    records.sort(key=lambda value: value["path"])
    store._guard_namespace()
    return _sha256_parts(
        STORE_SHAPE_DOMAIN,
        _canonical_json({"records": records}),
    )


def _read_selected_campaign(
    store: CampaignStore,
) -> tuple[bytes, dict[str, Any], bytes, dict[str, Any]]:
    selector_wire = _read_regular_at(
        store.root_fd,
        ACTIVE_SELECTOR_NAME,
        campaign.SELECTOR_BYTES,
        expected_device=store.root_identity[0],
        require_private_single_link=True,
    )
    selector = campaign.decode_selector(selector_wire)
    manifest_wire = _read_regular_at(
        store.directory_fds[store.manifests.name],
        selector["manifest_sha256"].hex() + ".bin",
        campaign.encoded_manifest_bytes(SEGMENT_COUNT),
        expected_device=store.root_identity[0],
        require_private_single_link=True,
    )
    manifest = campaign.verify_manifest(manifest_wire)
    campaign.verify_selector(
        manifest_wire,
        selector_wire,
        selector["environment_sha256"],
    )
    return selector_wire, selector, manifest_wire, manifest


def _derive_fixed_retained_plan(
    store: CampaignStore,
    manifest: Mapping[str, Any],
    worker_sha256: bytes,
    metallib_sha256: bytes,
    campaign_challenge_sha256: bytes,
    forced_process_restart: bool,
) -> dict[str, Any]:
    _require_boundary_grant(
        campaign_challenge_sha256,
        "campaign challenge",
    )
    entries = manifest["entries"]
    _require(entries, "retained campaign has no first entry")
    first_wire = _read_regular_at(
        store.directory_fds[store.segments.name],
        entries[0]["report_wire_sha256"].hex() + ".bin",
        inner.EXPECTED_WIRE_BYTES,
        expected_device=store.root_identity[0],
        require_private_single_link=True,
    )
    _verify_retained_entry(
        entries[0],
        first_wire,
        worker_sha256,
        metallib_sha256,
    )
    initial = _initial_plan(
        campaign_challenge_sha256,
        worker_sha256,
        metallib_sha256,
        _schedule_sha256(
            _supervisor_sha256(),
            forced_process_restart,
        ),
        forced_process_restart,
    )
    expected = _seal_plan_from_first_report(
        initial,
        inner._decode_after_portable_verification(first_wire),
    )
    _require(
        manifest["plan"] == expected,
        "retained campaign plan is not the exact fixed plan",
    )
    return expected


def _audit_exact_campaign_objects(
    store: CampaignStore,
    plan: Mapping[str, Any],
    entries: Sequence[Mapping[str, Any]],
    environment_root_sha256: bytes,
    worker_sha256: bytes,
    metallib_sha256: bytes,
    *,
    selector_candidate: Optional[bytes] = None,
) -> None:
    generation = len(entries)
    _require(
        1 <= generation <= SEGMENT_COUNT,
        "campaign audit generation is outside the fixed profile",
    )
    expected_segments: dict[str, bytes] = {}
    segments_fd = store.directory_fds[store.segments.name]
    for entry in entries:
        name = entry["report_wire_sha256"].hex() + ".bin"
        wire = _read_regular_at(
            segments_fd,
            name,
            inner.EXPECTED_WIRE_BYTES,
            expected_device=store.root_identity[0],
            require_private_single_link=True,
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
        expected_segments[name] = wire
    _require(
        set(os.listdir(segments_fd)) == set(expected_segments),
        "retained segment object set is not exact",
    )

    expected_manifests: dict[str, bytes] = {}
    for prefix_generation in range(1, generation + 1):
        wire = campaign.make_manifest(
            plan,
            entries[:prefix_generation],
        )
        decoded = campaign.verify_manifest(wire)
        expected_manifests[
            decoded["manifest_sha256"].hex() + ".bin"
        ] = wire
    manifests_fd = store.directory_fds[store.manifests.name]
    _require(
        set(os.listdir(manifests_fd)) == set(expected_manifests),
        "retained manifest object set is not exact",
    )
    for name, data in expected_manifests.items():
        _require(
            _read_regular_at(
                manifests_fd,
                name,
                len(data),
                expected_device=store.root_identity[0],
                require_private_single_link=True,
            )
            == data,
            "retained manifest prefix changed",
        )

    before_sha256, after_sha256 = _resolve_environment_evidence_at(
        store.directory_fds[store.environments.name],
        store.directory_identities[store.environments.name],
        plan["campaign_id_sha256"],
        generation,
        environment_root_sha256,
    )
    expected_environments = {before_sha256.hex() + ".json"}
    if after_sha256 != ZERO_DIGEST:
        expected_environments.add(after_sha256.hex() + ".json")
    _require(
        set(
            os.listdir(
                store.directory_fds[store.environments.name]
            )
        )
        == expected_environments,
        "retained environment object set is not exact",
    )

    expected_root_names = {
        store.segments.name,
        store.manifests.name,
        store.environments.name,
        LOCK_NAME,
        ACTIVE_SELECTOR_NAME,
    }
    if selector_candidate is not None:
        _require(
            len(selector_candidate) == campaign.SELECTOR_BYTES
            and _read_regular_at(
                store.root_fd,
                SELECTOR_TEMP_NAME,
                campaign.SELECTOR_BYTES,
                expected_device=store.root_identity[0],
                require_private_single_link=True,
            )
            == selector_candidate,
            "prepared selector candidate changed",
        )
        expected_root_names.add(SELECTOR_TEMP_NAME)
    _require(
        set(os.listdir(store.root_fd)) == expected_root_names,
        "campaign store root object set is not exact",
    )
    store._enforce_bound(plan)
    store._guard_namespace()


def _boundary_identity_facts(store: CampaignStore) -> dict[str, Any]:
    return {
        "store_device": store.root_identity[0],
        "store_inode": store.root_identity[1],
        "lock_device": store.lock_identity[0],
        "lock_inode": store.lock_identity[1],
    }


def _reaped_worker_pid(persistent: Any) -> int:
    _require(
        getattr(persistent, "closed", False) is True,
        "worker PID was requested before reap",
    )
    process = getattr(persistent, "process", None)
    value = (
        getattr(process, "pid", None)
        if process is not None
        else getattr(persistent, "pid", None)
    )
    _require(
        isinstance(value, int)
        and not isinstance(value, bool)
        and value > 0,
        "reaped worker PID is unavailable",
    )
    if process is not None:
        _require(
            process.poll() is not None and process.returncode == 0,
            "reaped worker did not have clean exit status zero",
        )
    return value


def _prefix_boundary_facts(
    store: CampaignStore,
    manifest: Mapping[str, Any],
    selector_wire: bytes,
    boundary_challenge_sha256: bytes,
    worker_pid: int,
) -> dict[str, Any]:
    selector = campaign.decode_selector(selector_wire)
    _require(
        selector["generation"] == SEGMENTS_PER_PROCESS,
        "prefix boundary is not generation 6",
    )
    _require(
        isinstance(worker_pid, int)
        and not isinstance(worker_pid, bool)
        and worker_pid > 0,
        "prefix worker PID is invalid",
    )
    facts: dict[str, Any] = {
        "schema": PREFIX_BOUNDARY_SCHEMA,
        "generation": SEGMENTS_PER_PROCESS,
        "next_ordinal": SEGMENTS_PER_PROCESS,
        "worker_reaped": True,
        "worker_pid": worker_pid,
        "worker_exit_code_bits": 0,
        "worker_termination_signal": 0,
        "lock_held": True,
        "boundary_challenge_sha256": (
            boundary_challenge_sha256.hex()
        ),
        "campaign_challenge_sha256": manifest["plan"][
            "campaign_challenge_sha256"
        ].hex(),
        "campaign_id_sha256": manifest["plan"][
            "campaign_id_sha256"
        ].hex(),
        "plan_sha256": campaign.derive_plan_sha256(
            manifest["plan"]
        ).hex(),
        "selector_wire_hex": selector_wire.hex(),
        "selector_sha256": selector["selector_sha256"].hex(),
        "manifest_sha256": manifest["manifest_sha256"].hex(),
        "final_entry_sha256": manifest["entries"][-1][
            "entry_sha256"
        ].hex(),
        "environment_sha256": selector[
            "environment_sha256"
        ].hex(),
        "store_shape_sha256": _store_shape_sha256(store).hex(),
        **_boundary_identity_facts(store),
    }
    return facts


def _prepared_final_facts(
    store: CampaignStore,
    manifest: Mapping[str, Any],
    predecessor_selector_wire: bytes,
    successor_selector_wire: bytes,
    recovery_challenge_sha256: bytes,
    worker_pid: int,
    *,
    prepared_store_shape_sha256: Optional[bytes] = None,
) -> dict[str, Any]:
    predecessor = campaign.decode_selector(
        predecessor_selector_wire
    )
    successor = campaign.decode_selector(successor_selector_wire)
    _require(
        predecessor["generation"] == SEGMENT_COUNT - 1
        and successor["generation"] == SEGMENT_COUNT,
        "prepared selector transition is not 11 to 12",
    )
    _require(
        isinstance(worker_pid, int)
        and not isinstance(worker_pid, bool)
        and worker_pid > 0,
        "prepared worker PID is invalid",
    )
    facts: dict[str, Any] = {
        "schema": PREPARED_FINAL_SCHEMA,
        "selected_generation": SEGMENT_COUNT - 1,
        "candidate_generation": SEGMENT_COUNT,
        "next_publication_phase": 26,
        "worker_reaped": True,
        "worker_pid": worker_pid,
        "worker_exit_code_bits": 0,
        "worker_termination_signal": 0,
        "lock_held": True,
        "selector_file_synced": True,
        "recovery_challenge_sha256": (
            recovery_challenge_sha256.hex()
        ),
        "campaign_challenge_sha256": manifest["plan"][
            "campaign_challenge_sha256"
        ].hex(),
        "candidate_selector_bytes": campaign.SELECTOR_BYTES,
        "candidate_temp_name": SELECTOR_TEMP_NAME,
        "campaign_id_sha256": manifest["plan"][
            "campaign_id_sha256"
        ].hex(),
        "plan_sha256": campaign.derive_plan_sha256(
            manifest["plan"]
        ).hex(),
        "selected_selector_wire_hex": (
            predecessor_selector_wire.hex()
        ),
        "selected_selector_sha256": predecessor[
            "selector_sha256"
        ].hex(),
        "selected_manifest_sha256": predecessor[
            "manifest_sha256"
        ].hex(),
        "candidate_selector_wire_hex": successor_selector_wire.hex(),
        "candidate_selector_sha256": successor[
            "selector_sha256"
        ].hex(),
        "candidate_manifest_sha256": manifest[
            "manifest_sha256"
        ].hex(),
        "candidate_environment_sha256": successor[
            "environment_sha256"
        ].hex(),
        "final_entry_sha256": manifest["entries"][-1][
            "entry_sha256"
        ].hex(),
        "prepared_store_shape_sha256": (
            _store_shape_sha256(store)
            if prepared_store_shape_sha256 is None
            else prepared_store_shape_sha256
        ).hex(),
        **_boundary_identity_facts(store),
    }
    return facts


def _validate_expected_facts(
    expected: Mapping[str, Any],
    observed: Mapping[str, Any],
    label: str,
) -> None:
    _require(
        type(expected) is dict and dict(expected) == dict(observed),
        "%s facts or grant binding changed" % label,
    )


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
    expected_forced_process_restart: Optional[bool] = None,
    require_complete: bool = False,
) -> dict[str, Any]:
    """Offline-verify a retained store without trusting live-run memory."""
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
        forced_process_restart = bool(
            plan["flags"]
            & campaign.PLAN_FLAG_FORCED_PROCESS_RESTART
        )
        if expected_forced_process_restart is not None:
            _require(
                forced_process_restart
                == expected_forced_process_restart,
                "retained campaign restart profile changed",
            )
        _require(
            len(entries) == generation_count,
            "retained campaign generation changed",
        )
        _require(
            not require_complete or generation_count == SEGMENT_COUNT,
            "retained campaign is not complete",
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
            forced_process_restart,
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
            "forced_process_restart": forced_process_restart,
            "forced_process_kills": (
                1 if forced_process_restart and len(entries) >= 6 else 0
            ),
            "output_dir": root,
        }
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def _boundary_components(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    challenge_sha256: bytes,
    forced_process_restart: bool,
) -> tuple[str, str, bytes, bytes, bytes, dict[str, Any]]:
    worker_path = os.fspath(worker)
    metallib_path = os.fspath(metallib)
    _require(worker_path and metallib_path, "missing worker or metallib")
    _require_boundary_grant(challenge_sha256, "campaign challenge")
    worker_sha256 = _file_sha256(worker_path)
    metallib_sha256 = _file_sha256(metallib_path)
    inner._native_build_sha256(worker_sha256, metallib_sha256)
    supervisor_sha256 = _supervisor_sha256()
    initial_plan = _initial_plan(
        challenge_sha256,
        worker_sha256,
        metallib_sha256,
        _schedule_sha256(
            supervisor_sha256,
            forced_process_restart,
        ),
        forced_process_restart,
    )
    return (
        worker_path,
        metallib_path,
        worker_sha256,
        metallib_sha256,
        supervisor_sha256,
        initial_plan,
    )


def run_campaign_prefix(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    output_dir: os.PathLike[str] | str,
    *,
    boundary_generation: int = SEGMENTS_PER_PROCESS,
    campaign_challenge_sha256: bytes,
    boundary_challenge_sha256: bytes,
    forced_process_restart: bool = False,
    io_hook: Optional[StoreIoHook] = None,
    _worker_factory: WorkerFactory = _PersistentWorker,
    _capture_environment: Callable[
        [], tuple[dict[str, Any], bytes]
    ] = _capture_admitted_environment,
) -> CampaignBoundaryHandle:
    """Run ordinals 0..5 and retain the exclusive generation-6 boundary."""
    _require(
        forced_process_restart is False,
        "staged supervisor campaign requires clean worker reap",
    )
    _require(
        boundary_generation == SEGMENTS_PER_PROCESS,
        "campaign prefix boundary must be exact generation 6",
    )
    _require_boundary_grant(
        boundary_challenge_sha256,
        "boundary challenge",
    )
    _require_boundary_grant(
        campaign_challenge_sha256,
        "campaign challenge",
    )
    (
        worker_path,
        metallib_path,
        worker_sha256,
        metallib_sha256,
        supervisor_sha256,
        initial_plan,
    ) = _boundary_components(
        worker,
        metallib,
        campaign_challenge_sha256,
        forced_process_restart,
    )
    campaign_id_sha256 = campaign.derive_campaign_id(initial_plan)
    environment_before, environment_before_sha256 = (
        _capture_environment()
    )
    store = CampaignStore(output_dir, io_hook=io_hook)
    persistent: Optional[Any] = None
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
        persistent = _worker_factory(
            worker_path,
            metallib_path,
            worker_sha256,
            metallib_sha256,
        )
        for ordinal in range(boundary_generation):
            remaining = (
                CAMPAIGN_WALL_TIMEOUT_SECONDS
                - (time.monotonic() - campaign_started)
            )
            _require(
                remaining > 0,
                "native prefix exceeded the campaign wall bound",
            )
            scheduled_action = _scheduled_action_sha256(
                campaign_id_sha256,
                initial_plan["schedule_sha256"],
                persistent.process_source_sha256,
                ordinal,
                _process_generation(ordinal),
                forced_process_restart,
            )
            segment_challenge = campaign.derive_segment_challenge(
                campaign_id_sha256,
                ordinal,
                _process_generation(ordinal),
                previous_entry_sha256,
                previous_report_sha256,
                scheduled_action,
            )
            wire, duration_ns, rss = persistent.request(
                segment_challenge,
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
                segment_challenge,
            )
            decoded = inner._decode_after_portable_verification(wire)
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
                if forced_process_restart:
                    persistent.kill_for_campaign()
                else:
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
            environment_root = environment_sha256(
                campaign_id_sha256,
                len(entries),
                environment_before_sha256,
            )
            store.publish(plan, entries, environment_root)

        _require(
            plan is not None
            and persistent.closed
            and len(entries) == boundary_generation,
            "generation-6 worker was not reaped canonically",
        )
        prefix_worker_pid = _reaped_worker_pid(persistent)
        _require(
            prefix_worker_pid != os.getpid(),
            "prefix worker PID aliases its supervisor",
        )
        checkpoint_environment_root = environment_sha256(
            campaign_id_sha256,
            boundary_generation,
            environment_before_sha256,
        )
        reopened, selector_wire = store.recover(
            plan,
            boundary_generation,
            checkpoint_environment_root,
            worker_sha256,
            metallib_sha256,
        )
        _audit_exact_campaign_objects(
            store,
            plan,
            reopened["entries"],
            checkpoint_environment_root,
            worker_sha256,
            metallib_sha256,
        )
        process_boundary._verify_components_unchanged(
            worker_path,
            metallib_path,
            worker_sha256,
            metallib_sha256,
        )
        _require(
            _supervisor_sha256() == supervisor_sha256,
            "native soak supervisor changed during the prefix",
        )
        facts = _prefix_boundary_facts(
            store,
            reopened,
            selector_wire,
            boundary_challenge_sha256,
            prefix_worker_pid,
        )
        return CampaignBoundaryHandle(store, facts)
    except (
        campaign.CampaignManifestError,
        inner.NativeMetalDisruptionReportError,
        process_boundary.NativeMetalReportError,
        OSError,
    ) as error:
        if persistent is not None and not persistent.closed:
            persistent.abort()
        store.close()
        if isinstance(error, NativeMetalSoakError):
            raise
        raise NativeMetalSoakError(str(error)) from error
    except BaseException:
        if persistent is not None and not persistent.closed:
            persistent.abort()
        store.close()
        raise


def resume_campaign_to_prepared_final(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    output_dir: os.PathLike[str] | str,
    *,
    resume_grant_sha256: bytes,
    expected_prefix_facts: Mapping[str, Any],
    recovery_challenge_sha256: bytes,
    forced_process_restart: bool = False,
    io_hook: Optional[StoreIoHook] = None,
    _worker_factory: WorkerFactory = _PersistentWorker,
    _capture_environment: Callable[
        [], tuple[dict[str, Any], bytes]
    ] = _capture_admitted_environment,
) -> CampaignBoundaryHandle:
    """Resume ordinal 6 and stop with the final selector only prepared."""
    _require(
        forced_process_restart is False,
        "staged supervisor campaign requires clean worker reap",
    )
    _require_boundary_grant(resume_grant_sha256, "resume grant")
    _require_boundary_grant(
        recovery_challenge_sha256,
        "recovery challenge",
    )
    campaign_challenge_sha256 = _challenge_from_facts(
        expected_prefix_facts,
        "campaign_challenge_sha256",
    )
    boundary_challenge_sha256 = _challenge_from_facts(
        expected_prefix_facts,
        "boundary_challenge_sha256",
    )
    (
        worker_path,
        metallib_path,
        worker_sha256,
        metallib_sha256,
        supervisor_sha256,
        initial_plan,
    ) = _boundary_components(
        worker,
        metallib,
        campaign_challenge_sha256,
        forced_process_restart,
    )
    store = CampaignStore._open_existing_locked(
        output_dir,
        io_hook=io_hook,
    )
    persistent: Optional[Any] = None
    try:
        (
            selector_wire,
            selector,
            _manifest_wire,
            manifest,
        ) = _read_selected_campaign(store)
        _require(
            selector["generation"] == SEGMENTS_PER_PROCESS
            and len(manifest["entries"]) == SEGMENTS_PER_PROCESS,
            "resume predecessor is not exact generation 6",
        )
        plan = _derive_fixed_retained_plan(
            store,
            manifest,
            worker_sha256,
            metallib_sha256,
            campaign_challenge_sha256,
            forced_process_restart,
        )
        _audit_exact_campaign_objects(
            store,
            plan,
            manifest["entries"],
            selector["environment_sha256"],
            worker_sha256,
            metallib_sha256,
        )
        observed_prefix_facts = _prefix_boundary_facts(
            store,
            manifest,
            selector_wire,
            boundary_challenge_sha256,
            expected_prefix_facts.get("worker_pid"),
        )
        _validate_expected_facts(
            expected_prefix_facts,
            observed_prefix_facts,
            "resume predecessor",
        )
        store._authorize_existing_writer()
        reopened, _ = store.recover(
            plan,
            SEGMENTS_PER_PROCESS,
            selector["environment_sha256"],
            worker_sha256,
            metallib_sha256,
        )
        entries = list(reopened["entries"])
        previous_entry_sha256 = entries[-1]["entry_sha256"]
        previous_report_sha256 = entries[-1][
            "verified_report_sha256"
        ]
        cumulative_duration_ns = entries[-1][
            "cumulative_duration_ns"
        ]
        environment_objects = _read_environment_objects_at(
            store.directory_fds[store.environments.name],
            store.directory_identities[store.environments.name],
        )
        _require(
            len(environment_objects) == 1,
            "resume predecessor environment set changed",
        )
        (
            environment_before_sha256,
            environment_before,
            _captured_at,
        ) = environment_objects[0]
        campaign_id_sha256 = plan["campaign_id_sha256"]
        _require(
            campaign_id_sha256
            == campaign.derive_campaign_id(initial_plan),
            "resumed campaign identity changed",
        )

        campaign_started = time.monotonic()
        persistent = _worker_factory(
            worker_path,
            metallib_path,
            worker_sha256,
            metallib_sha256,
        )
        predecessor_selector_wire = b""
        successor_manifest: Optional[dict[str, Any]] = None
        successor_selector_wire = b""
        for ordinal in range(
            SEGMENTS_PER_PROCESS,
            SEGMENT_COUNT,
        ):
            remaining = (
                CAMPAIGN_WALL_TIMEOUT_SECONDS
                - (time.monotonic() - campaign_started)
            )
            _require(
                remaining > 0,
                "native resume exceeded the campaign wall bound",
            )
            scheduled_action = _scheduled_action_sha256(
                campaign_id_sha256,
                plan["schedule_sha256"],
                persistent.process_source_sha256,
                ordinal,
                _process_generation(ordinal),
                forced_process_restart,
            )
            segment_challenge = campaign.derive_segment_challenge(
                campaign_id_sha256,
                ordinal,
                _process_generation(ordinal),
                previous_entry_sha256,
                previous_report_sha256,
                scheduled_action,
            )
            wire, duration_ns, rss = persistent.request(
                segment_challenge,
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
                segment_challenge,
            )
            decoded = inner._decode_after_portable_verification(wire)
            _assert_segment_cadence(decoded)
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
            if ordinal < SEGMENT_COUNT - 1:
                environment_root = environment_sha256(
                    campaign_id_sha256,
                    len(entries),
                    environment_before_sha256,
                )
                store.publish(plan, entries, environment_root)
                continue

            environment_after, environment_after_sha256 = (
                _capture_environment()
            )
            _compare_environment_boundaries(
                environment_before,
                environment_after,
            )
            retained_after = store.write_environment(
                environment_after
            )
            _require(
                retained_after == environment_after_sha256,
                "retained after-environment root changed",
            )
            final_environment_root = environment_sha256(
                campaign_id_sha256,
                SEGMENT_COUNT,
                environment_before_sha256,
                environment_after_sha256,
            )
            (
                predecessor_selector_wire,
                successor_manifest_wire,
                successor_selector_wire,
            ) = store.prepare_final_publication(
                plan,
                entries,
                final_environment_root,
            )
            successor_manifest = campaign.verify_manifest(
                successor_manifest_wire
            )

        _require(
            persistent.closed
            and len(entries) == SEGMENT_COUNT
            and successor_manifest is not None
            and len(predecessor_selector_wire)
            == campaign.SELECTOR_BYTES
            and len(successor_selector_wire)
            == campaign.SELECTOR_BYTES,
            "final worker was not reaped before preparation",
        )
        resumed_worker_pid = _reaped_worker_pid(persistent)
        _require(
            resumed_worker_pid != os.getpid()
            and resumed_worker_pid
            != expected_prefix_facts.get("worker_pid"),
            "resumed worker PID aliases an earlier campaign process",
        )
        active_after_prepare = _read_regular_at(
            store.root_fd,
            ACTIVE_SELECTOR_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=store.root_identity[0],
            require_private_single_link=True,
        )
        _require(
            active_after_prepare == predecessor_selector_wire,
            "generation 12 became active during prepare",
        )
        candidate = _read_regular_at(
            store.root_fd,
            SELECTOR_TEMP_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=store.root_identity[0],
            require_private_single_link=True,
        )
        _require(
            candidate == successor_selector_wire,
            "prepared generation-12 selector changed",
        )
        final_environment_root = campaign.decode_selector(
            successor_selector_wire
        )["environment_sha256"]
        _audit_exact_campaign_objects(
            store,
            plan,
            entries,
            final_environment_root,
            worker_sha256,
            metallib_sha256,
            selector_candidate=successor_selector_wire,
        )
        process_boundary._verify_components_unchanged(
            worker_path,
            metallib_path,
            worker_sha256,
            metallib_sha256,
        )
        _require(
            _supervisor_sha256() == supervisor_sha256,
            "native soak supervisor changed during resume",
        )
        facts = _prepared_final_facts(
            store,
            successor_manifest,
            predecessor_selector_wire,
            successor_selector_wire,
            recovery_challenge_sha256,
            resumed_worker_pid,
        )
        facts["resume_grant_binding_sha256"] = (
            resume_grant_use_sha256(
                resume_grant_sha256,
                expected_prefix_facts,
                facts,
            ).hex()
        )
        return CampaignBoundaryHandle(store, facts)
    except (
        campaign.CampaignManifestError,
        inner.NativeMetalDisruptionReportError,
        process_boundary.NativeMetalReportError,
        OSError,
    ) as error:
        if persistent is not None and not persistent.closed:
            persistent.abort()
        store.close()
        if isinstance(error, NativeMetalSoakError):
            raise
        raise NativeMetalSoakError(str(error)) from error
    except BaseException:
        if persistent is not None and not persistent.closed:
            persistent.abort()
        store.close()
        raise


def _decode_prepared_boundary_facts(
    expected: Mapping[str, Any],
    finalizer_grant_sha256: bytes,
) -> tuple[bytes, bytes]:
    _require(
        type(expected) is dict
        and expected.get("schema") == PREPARED_FINAL_SCHEMA,
        "prepared final facts schema changed",
    )
    _require_boundary_grant(finalizer_grant_sha256, "finalizer grant")
    try:
        predecessor = bytes.fromhex(
            str(expected["selected_selector_wire_hex"])
        )
        successor = bytes.fromhex(
            str(expected["candidate_selector_wire_hex"])
        )
    except (KeyError, ValueError) as error:
        raise NativeMetalSoakError(
            "prepared final selector facts are invalid"
        ) from error
    _require(
        len(predecessor) == campaign.SELECTOR_BYTES
        and len(successor) == campaign.SELECTOR_BYTES
        and campaign.decode_selector(predecessor)["generation"]
        == SEGMENT_COUNT - 1
        and campaign.decode_selector(successor)["generation"]
        == SEGMENT_COUNT,
        "prepared final selector transition changed",
    )
    return predecessor, successor


def roll_forward_prepared_final(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    output_dir: os.PathLike[str] | str,
    *,
    finalizer_grant_sha256: bytes,
    expected_prepared_facts: Mapping[str, Any],
    forced_process_restart: bool = False,
    io_hook: Optional[StoreIoHook] = None,
) -> CampaignBoundaryHandle:
    """Fresh-open, finalize only the authorized 11-to-12 switch, and audit."""
    _require(
        forced_process_restart is False,
        "staged supervisor campaign requires clean worker reap",
    )
    _require_boundary_grant(finalizer_grant_sha256, "finalizer grant")
    predecessor_selector_wire, successor_selector_wire = (
        _decode_prepared_boundary_facts(
            expected_prepared_facts,
            finalizer_grant_sha256,
        )
    )
    campaign_challenge_sha256 = _challenge_from_facts(
        expected_prepared_facts,
        "campaign_challenge_sha256",
    )
    recovery_challenge_sha256 = _challenge_from_facts(
        expected_prepared_facts,
        "recovery_challenge_sha256",
    )
    (
        worker_path,
        metallib_path,
        worker_sha256,
        metallib_sha256,
        supervisor_sha256,
        _initial,
    ) = _boundary_components(
        worker,
        metallib,
        campaign_challenge_sha256,
        forced_process_restart,
    )
    store = CampaignStore._open_existing_locked(
        output_dir,
        allow_prepared_selector=True,
        io_hook=io_hook,
    )
    try:
        (
            active_selector_wire,
            active_selector,
            _active_manifest_wire,
            active_manifest,
        ) = _read_selected_campaign(store)
        if active_selector_wire == predecessor_selector_wire:
            _require(
                _entry_exists_at(store.root_fd, SELECTOR_TEMP_NAME)
                and _read_regular_at(
                    store.root_fd,
                    SELECTOR_TEMP_NAME,
                    campaign.SELECTOR_BYTES,
                    expected_device=store.root_identity[0],
                    require_private_single_link=True,
                )
                == successor_selector_wire,
                "prepared final selector residue changed",
            )
            successor = campaign.decode_selector(
                successor_selector_wire
            )
            successor_manifest_wire = _read_regular_at(
                store.directory_fds[store.manifests.name],
                successor["manifest_sha256"].hex() + ".bin",
                campaign.encoded_manifest_bytes(SEGMENT_COUNT),
                expected_device=store.root_identity[0],
                require_private_single_link=True,
            )
            successor_manifest = campaign.verify_manifest(
                successor_manifest_wire
            )
            campaign.verify_selector(
                successor_manifest_wire,
                successor_selector_wire,
                successor["environment_sha256"],
            )
            plan = _derive_fixed_retained_plan(
                store,
                successor_manifest,
                worker_sha256,
                metallib_sha256,
                campaign_challenge_sha256,
                forced_process_restart,
            )
            expected_predecessor_wire = campaign.make_manifest(
                plan,
                successor_manifest["entries"][:-1],
            )
            expected_predecessor = campaign.verify_manifest(
                expected_predecessor_wire
            )
            _require(
                active_selector["generation"] == SEGMENT_COUNT - 1
                and active_manifest["manifest_sha256"]
                == expected_predecessor["manifest_sha256"]
                and active_manifest["entries"]
                == successor_manifest["entries"][:-1],
                "prepared final active predecessor changed",
            )
            _audit_exact_campaign_objects(
                store,
                plan,
                successor_manifest["entries"],
                successor["environment_sha256"],
                worker_sha256,
                metallib_sha256,
                selector_candidate=successor_selector_wire,
            )
            observed_prepared_facts = _prepared_final_facts(
                store,
                successor_manifest,
                predecessor_selector_wire,
                successor_selector_wire,
                recovery_challenge_sha256,
                expected_prepared_facts.get("worker_pid"),
            )
        else:
            _require(
                active_selector_wire == successor_selector_wire
                and active_selector["generation"] == SEGMENT_COUNT
                and not _entry_exists_at(
                    store.root_fd,
                    SELECTOR_TEMP_NAME,
                ),
                "finalizer found neither exact prepared nor successor state",
            )
            successor_manifest = active_manifest
            plan = _derive_fixed_retained_plan(
                store,
                successor_manifest,
                worker_sha256,
                metallib_sha256,
                campaign_challenge_sha256,
                forced_process_restart,
            )
            _audit_exact_campaign_objects(
                store,
                plan,
                successor_manifest["entries"],
                active_selector["environment_sha256"],
                worker_sha256,
                metallib_sha256,
            )
            hypothetical_prepared_shape = _store_shape_sha256(
                store,
                root_overrides={
                    ACTIVE_SELECTOR_NAME: predecessor_selector_wire,
                    SELECTOR_TEMP_NAME: successor_selector_wire,
                },
            )
            observed_prepared_facts = _prepared_final_facts(
                store,
                successor_manifest,
                predecessor_selector_wire,
                successor_selector_wire,
                recovery_challenge_sha256,
                expected_prepared_facts.get("worker_pid"),
                prepared_store_shape_sha256=(
                    hypothetical_prepared_shape
                ),
            )
        expected_prepared_core = dict(expected_prepared_facts)
        resume_grant_binding = expected_prepared_core.pop(
            "resume_grant_binding_sha256",
            None,
        )
        _require(
            _is_nonzero_hex_digest(resume_grant_binding),
            "prepared final resume-grant receipt changed",
        )
        _validate_expected_facts(
            expected_prepared_core,
            observed_prepared_facts,
            "prepared final",
        )
        store._authorize_existing_writer()
        disposition = store.roll_forward_prepared_final(
            predecessor_selector_wire,
            successor_selector_wire,
        )
        (
            final_selector_wire,
            final_selector,
            _final_manifest_wire,
            final_manifest,
        ) = _read_selected_campaign(store)
        _require(
            final_selector_wire == successor_selector_wire
            and final_selector["generation"] == SEGMENT_COUNT,
            "finalizer did not select exact generation 12",
        )
        final_plan = _derive_fixed_retained_plan(
            store,
            final_manifest,
            worker_sha256,
            metallib_sha256,
            campaign_challenge_sha256,
            forced_process_restart,
        )
        _audit_exact_campaign_objects(
            store,
            final_plan,
            final_manifest["entries"],
            final_selector["environment_sha256"],
            worker_sha256,
            metallib_sha256,
        )
        recovered, recovered_selector = store.recover(
            final_plan,
            SEGMENT_COUNT,
            final_selector["environment_sha256"],
            worker_sha256,
            metallib_sha256,
        )
        _require(
            recovered_selector == successor_selector_wire
            and recovered["entries"] == final_manifest["entries"],
            "strict final recovery changed generation 12",
        )
        process_boundary._verify_components_unchanged(
            worker_path,
            metallib_path,
            worker_sha256,
            metallib_sha256,
        )
        _require(
            _supervisor_sha256() == supervisor_sha256,
            "native soak supervisor changed during finalization",
        )
        facts = {
            "schema": FINALIZED_BOUNDARY_SCHEMA,
            "generation": SEGMENT_COUNT,
            "disposition": disposition,
            "strict_audit": True,
            "lock_held": True,
            "campaign_id_sha256": final_plan[
                "campaign_id_sha256"
            ].hex(),
            "plan_sha256": campaign.derive_plan_sha256(
                final_plan
            ).hex(),
            "selector_wire_hex": final_selector_wire.hex(),
            "selector_sha256": final_selector[
                "selector_sha256"
            ].hex(),
            "manifest_sha256": final_manifest[
                "manifest_sha256"
            ].hex(),
            "final_entry_sha256": final_manifest["entries"][-1][
                "entry_sha256"
            ].hex(),
            "environment_sha256": final_selector[
                "environment_sha256"
            ].hex(),
            "store_shape_sha256": _store_shape_sha256(store).hex(),
            **_boundary_identity_facts(store),
        }
        facts["finalizer_grant_binding_sha256"] = (
            finalizer_grant_use_sha256(
                finalizer_grant_sha256,
                expected_prepared_facts,
                facts,
            ).hex()
        )
        return CampaignBoundaryHandle(store, facts)
    except (
        campaign.CampaignManifestError,
        inner.NativeMetalDisruptionReportError,
        process_boundary.NativeMetalReportError,
        OSError,
    ) as error:
        store.close()
        if isinstance(error, NativeMetalSoakError):
            raise
        raise NativeMetalSoakError(str(error)) from error
    except BaseException:
        store.close()
        raise


def verify_campaign(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    output_dir: os.PathLike[str] | str,
    forced_process_restart: bool = False,
) -> dict[str, Any]:
    worker_path = os.fspath(worker)
    metallib_path = os.fspath(metallib)
    _require(worker_path and metallib_path, "missing worker or metallib")
    worker_sha256 = _file_sha256(worker_path)
    metallib_sha256 = _file_sha256(metallib_path)
    inner._native_build_sha256(worker_sha256, metallib_sha256)
    supervisor_sha256 = _supervisor_sha256()
    schedule_sha256 = _schedule_sha256(
        supervisor_sha256,
        forced_process_restart,
    )
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
        forced_process_restart,
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
                        forced_process_restart,
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
                        if (
                            forced_process_restart
                            and ordinal
                            == RESTART_AFTER_SEGMENT - 1
                        ):
                            persistent.kill_for_campaign()
                        else:
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
            cumulative_duration_ns = entries[-1][
                "cumulative_duration_ns"
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
            "forced_process_kills": (
                1 if forced_process_restart else 0
            ),
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


def _force_kill_process_group(
    process: subprocess.Popen[bytes],
) -> None:
    """Remove every descendant in a private watchdog process group."""
    with contextlib.suppress(OSError):
        os.killpg(process.pid, signal.SIGKILL)
    if process.poll() is None:
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=1.0)


def _run_offline_verifier(
    worker: str,
    metallib: str,
    output_dir: str,
    forced_process_restart: bool,
    ephemeral_output: bool,
    repository_root: Path,
    environment: Mapping[str, str],
) -> int:
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--worker",
        os.path.abspath(worker),
        "--metallib",
        os.path.abspath(metallib),
        "--output-dir",
        os.path.abspath(output_dir),
        "--verify-store",
    ]
    if forced_process_restart:
        command.append("--forced-process-restart")
    command.append("--require-complete")
    if ephemeral_output:
        command.append("--ephemeral-output")
    process: Optional[subprocess.Popen[bytes]] = None
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=repository_root,
            env=dict(environment),
            close_fds=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(
                timeout=OFFLINE_VERIFY_TIMEOUT_SECONDS
            )
        except subprocess.TimeoutExpired:
            with contextlib.suppress(OSError):
                os.killpg(process.pid, signal.SIGTERM)
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=1.0)
            _force_kill_process_group(process)
            stdout, stderr = process.communicate()
            if stderr:
                sys.stderr.buffer.write(
                    stderr[:MAX_SUPERVISOR_OUTPUT_BYTES]
                )
            print(
                "error: native Metal campaign offline verification "
                "exceeded %.0fs"
                % OFFLINE_VERIFY_TIMEOUT_SECONDS,
                file=sys.stderr,
            )
            return 1
        returncode = process.returncode
        _force_kill_process_group(process)
        process = None
        if (
            len(stdout) > MAX_SUPERVISOR_OUTPUT_BYTES
            or len(stderr) > MAX_SUPERVISOR_OUTPUT_BYTES
        ):
            print(
                "error: native Metal offline verifier output "
                "exceeded its bound",
                file=sys.stderr,
            )
            return 1
        if stdout:
            sys.stdout.buffer.write(stdout)
        if stderr:
            sys.stderr.buffer.write(stderr)
        return returncode
    except OSError as error:
        print(
            "error: could not start native Metal offline verifier: %s"
            % error,
            file=sys.stderr,
        )
        return 1
    finally:
        if process is not None:
            _force_kill_process_group(process)


def _run_with_watchdog(
    worker: str,
    metallib: str,
    output_dir: Optional[str],
    forced_process_restart: bool = False,
    *,
    _supervised_command: Optional[Sequence[str]] = None,
) -> int:
    temporary: Optional[tempfile.TemporaryDirectory[str]] = None
    output = output_dir
    ephemeral = output is None
    if output is None:
        temporary = tempfile.TemporaryDirectory(
            prefix="glacier-native-metal-soak."
        )
        output = temporary.name
    _require(output is not None, "native campaign output path is missing")
    if _supervised_command is None:
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
        if forced_process_restart:
            command.append("--forced-process-restart")
    else:
        command = list(_supervised_command)
        _require(command, "test supervised command is empty")
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
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=1.0)
            # Always escalate against the process group. The supervisor
            # leader may already have exited while a descendant ignored
            # SIGTERM.
            _force_kill_process_group(process)
            stdout, stderr = process.communicate()
            process = None
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
        returncode = process.returncode
        _force_kill_process_group(process)
        process = None
        if (
            len(stdout) > MAX_SUPERVISOR_OUTPUT_BYTES
            or len(stderr) > MAX_SUPERVISOR_OUTPUT_BYTES
        ):
            print(
                "error: native Metal soak supervisor output exceeded its bound",
                file=sys.stderr,
            )
            return 1
        if returncode != 0:
            if stdout:
                sys.stdout.buffer.write(stdout)
            if stderr:
                sys.stderr.buffer.write(stderr)
            return returncode
        offline_returncode = _run_offline_verifier(
            worker,
            metallib,
            output,
            forced_process_restart,
            ephemeral,
            repository_root,
            environment,
        )
        if offline_returncode != 0:
            return offline_returncode
        if stdout:
            sys.stdout.buffer.write(stdout)
        if stderr:
            sys.stderr.buffer.write(stderr)
        return 0
    except OSError as error:
        print(
            "error: could not start native Metal soak watchdog: %s" % error,
            file=sys.stderr,
        )
        return 1
    finally:
        if process is not None:
            _force_kill_process_group(process)
        if temporary is not None:
            temporary.cleanup()


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run a fixed 12-segment, two-process native Metal campaign"
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
        "--forced-process-restart",
        action="store_true",
        help=(
            "run or require the W7b-b profile that SIGKILLs the first "
            "worker after its sixth verified segment"
        ),
    )
    parser.add_argument(
        "--supervised-child",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--require-complete",
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
        if arguments.supervised_child:
            parser.error(
                "--verify-store cannot use internal supervisor options"
            )
        if arguments.ephemeral_output and not arguments.require_complete:
            parser.error("--ephemeral-output is internal")
        if arguments.output_dir is None:
            parser.error("--verify-store requires --output-dir")
        try:
            result = verify_retained_store(
                arguments.worker,
                arguments.metallib,
                arguments.output_dir,
                arguments.forced_process_restart,
                arguments.require_complete,
            )
            _require(
                not arguments.require_complete or result["complete"],
                "retained campaign is not complete",
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
            "ok %s "
            "status=%s segments=%d processes=%d records=%d completed=%d "
            "forced_process_kills=%d campaign_id_sha256=%s "
            "final_entry_sha256=%s%s"
            % (
                (
                    "native-metal-process-kill-store-v1"
                    if result["forced_process_restart"]
                    else "native-metal-soak-store-v1"
                ),
                "complete" if result["complete"] else "partial",
                result["segments"],
                result["process_generations"],
                result["records"],
                result["completed"],
                result["forced_process_kills"],
                result["campaign_id_sha256"].hex(),
                result["final_entry_sha256"].hex(),
                (
                    " ephemeral=true"
                    if arguments.ephemeral_output
                    else " retained=%s" % result["output_dir"]
                ),
            )
        )
        return 0

    if not arguments.supervised_child:
        if arguments.ephemeral_output or arguments.require_complete:
            parser.error("internal supervisor option used directly")
        return _run_with_watchdog(
            arguments.worker,
            arguments.metallib,
            arguments.output_dir,
            arguments.forced_process_restart,
        )

    if arguments.output_dir is None:
        parser.error("supervised child requires --output-dir")
    if arguments.require_complete:
        parser.error("--require-complete requires --verify-store")
    try:
        result = verify_campaign(
            arguments.worker,
            arguments.metallib,
            arguments.output_dir,
            arguments.forced_process_restart,
        )
    except (NativeMetalSoakError, OSError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1

    print(
        "ok %s "
        "segments=%d processes=%d duration_ns=%d records=%d "
        "completed=%d cancelled=%d failed=%d capacity_rejected=%d "
        "pins=%d events=%d forced_process_kills=%d "
        "campaign_id_sha256=%s "
        "final_entry_sha256=%s%s"
        % (
            (
                "native-metal-process-kill-report-v1"
                if arguments.forced_process_restart
                else "native-metal-soak-report-v1"
            ),
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
            result["forced_process_kills"],
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
