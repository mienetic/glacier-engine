#!/usr/bin/env python3
"""Run and verify one bounded event-blocked Metal worker-death campaign.

The victim is linked to the fault-only Metal shim.  It publishes one fixed
ready frame only after observing a submitted, nonterminal command buffer at a
deterministic shared-event barrier.  This controller validates that frame,
sends ``SIGKILL`` to the victim PID only, requires exact process and pipe
closure, and then runs a distinct production-linked W6 worker as a fresh
device-usability control.

The resulting outer wire embeds the ready frame, OS-kill receipt, and complete
W6 wire.  It proves neither active-kernel interruption nor victim-result
recovery, physical device loss, process-state preservation, or complete
driver/resource reclamation.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
import selectors
import signal
import struct
import subprocess
import sys
import time
from typing import Any, Callable, Mapping, Optional, Sequence, Tuple, Union

from bench import native_metal_workload_report as w6


ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1

READY_FRAME_ABI = 0x4757_494B_0000_0001
READY_FRAME_BYTES = 512
READY_SCALAR_COUNT = 16
READY_DIGEST_COUNT = 12
READY_FRAME_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-ready-frame-v1\x00"
)
VICTIM_BUILD_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-victim-build-v1\x00"
)
VICTIM_BACKEND_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-backend-v1\x00"
)
VICTIM_CHALLENGE_ENVIRONMENT = (
    "GLACIER_NATIVE_METAL_INFLIGHT_PROCESS_KILL_CHALLENGE_SHA256"
)

READY_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "pid",
    "barrier_generation",
    "command_generation",
    "submission_disposition",
    "command_buffer_status",
    "commit_invoked",
    "completion_observed",
    "shared_event_signaled_value",
    "encoded_signal_value",
    "encoded_wait_value",
    "live_native_buffer_count",
    "live_native_command_count",
    "active_allocation_reference_count",
)
READY_DIGEST_FIELDS = (
    "challenge_sha256",
    "victim_sha256",
    "metallib_sha256",
    "build_sha256",
    "machine_sha256",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "ticket_sha256",
    "pin_sha256",
    "submission_sha256",
    "frame_sha256",
)

SUBMISSION_DISPOSITION_SUBMITTED = 1
COMMAND_BUFFER_STATUS_COMMITTED = 2
COMMAND_BUFFER_STATUS_SCHEDULED = 3
EXPECTED_SHARED_EVENT_VALUE = 1
EXPECTED_ENCODED_SIGNAL_VALUE = 1
EXPECTED_ENCODED_WAIT_VALUE = 2
EXPECTED_LIVE_NATIVE_BUFFER_COUNT = 4
EXPECTED_LIVE_NATIVE_COMMAND_COUNT = 1
EXPECTED_ACTIVE_ALLOCATION_REFERENCE_COUNT = 4
BARRIER_PLAN_ABI = 0x474D_4942_0000_0001
BARRIER_FACTS_ABI = 0x474D_4946_0000_0001
METAL_DEVICE_INFO_ABI = 0x474D_4449_0000_0001
METAL_ASYNC_SUBMISSION_ABI = 0x474D_4153_0000_0001
METAL_ALLOCATION_ADAPTER_ABI = 0x474D_4141_0000_0001

KILL_RECEIPT_ABI = 0x4757_494B_0000_0002
KILL_RECEIPT_BYTES = 256
KILL_RECEIPT_SCALAR_COUNT = 8
KILL_RECEIPT_DIGEST_COUNT = 6
KILL_RECEIPT_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-kill-receipt-v1\x00"
)
KILL_RECEIPT_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "pid",
    "termination_signal",
    "returncode_bits",
    "stdout_bytes",
    "stderr_bytes",
)
KILL_RECEIPT_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "victim_challenge_sha256",
    "ready_frame_sha256",
    "victim_sha256",
    "metallib_sha256",
    "receipt_sha256",
)

REPORT_ABI = 0x4757_4952_0000_0001
REPORT_HEADER_BYTES = 640
REPORT_HEADER_SCALAR_COUNT = 16
REPORT_HEADER_DIGEST_COUNT = 16
REPORT_FOOTER_BYTES = 64
REPORT_FLAGS = 0
REPORT_HEADER_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-report-header-v1\x00"
)
REPORT_BODY_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-report-body-v1\x00"
)
REPORT_ROOT_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-report-root-v1\x00"
)
SCHEDULE_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-schedule-v1\x00"
)
COMPONENT_SET_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-component-set-v1\x00"
)
VICTIM_CHALLENGE_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-victim-challenge-v1\x00"
)
RECOVERY_CHALLENGE_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-recovery-challenge-v1\x00"
)

REPORT_HEADER_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "header_bytes",
    "ready_frame_bytes",
    "kill_receipt_bytes",
    "recovery_wire_bytes",
    "victim_count",
    "blocked_command_count",
    "sigkill_count",
    "recovery_record_count",
    "recovery_completed_count",
    "recovery_work_units",
    "flow_count",
    "queue_count",
    "reserved",
)
REPORT_HEADER_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "schedule_sha256",
    "victim_challenge_sha256",
    "recovery_challenge_sha256",
    "victim_sha256",
    "victim_metallib_sha256",
    "victim_build_sha256",
    "recovery_runner_sha256",
    "recovery_metallib_sha256",
    "recovery_build_sha256",
    "ready_frame_sha256",
    "kill_receipt_sha256",
    "recovery_wire_sha256",
    "recovery_report_sha256",
    "component_set_sha256",
    "header_sha256",
)

EXPECTED_VICTIM_COUNT = 1
EXPECTED_BLOCKED_COMMAND_COUNT = 1
EXPECTED_SIGKILL_COUNT = 1
EXPECTED_RECOVERY_RECORD_COUNT = w6.EXPECTED_RECORD_COUNT
EXPECTED_RECOVERY_COMPLETED_COUNT = w6.EXPECTED_RECORD_COUNT
EXPECTED_RECOVERY_WORK_UNITS = (
    w6.EXPECTED_RECORD_COUNT * w6.EXPECTED_WORK_UNITS
)
EXPECTED_FLOW_COUNT = w6.EXPECTED_FLOW_COUNT
EXPECTED_QUEUE_COUNT = w6.EXPECTED_QUEUE_COUNT
EXPECTED_RECOVERY_WIRE_BYTES = w6.EXPECTED_WIRE_BYTES
EXPECTED_REPORT_BYTES = (
    REPORT_HEADER_BYTES
    + READY_FRAME_BYTES
    + KILL_RECEIPT_BYTES
    + EXPECTED_RECOVERY_WIRE_BYTES
    + REPORT_FOOTER_BYTES
)

SCHEDULE_TUPLE = (
    REPORT_ABI,
    READY_FRAME_ABI,
    KILL_RECEIPT_ABI,
    REPORT_HEADER_BYTES,
    READY_FRAME_BYTES,
    KILL_RECEIPT_BYTES,
    EXPECTED_RECOVERY_WIRE_BYTES,
    EXPECTED_VICTIM_COUNT,
    EXPECTED_BLOCKED_COMMAND_COUNT,
    EXPECTED_SIGKILL_COUNT,
    EXPECTED_RECOVERY_RECORD_COUNT,
    EXPECTED_RECOVERY_COMPLETED_COUNT,
    EXPECTED_RECOVERY_WORK_UNITS,
    EXPECTED_FLOW_COUNT,
    EXPECTED_QUEUE_COUNT,
    EXPECTED_SHARED_EVENT_VALUE,
    EXPECTED_ENCODED_SIGNAL_VALUE,
    EXPECTED_ENCODED_WAIT_VALUE,
    EXPECTED_LIVE_NATIVE_BUFFER_COUNT,
    EXPECTED_LIVE_NATIVE_COMMAND_COUNT,
    EXPECTED_ACTIVE_ALLOCATION_REFERENCE_COUNT,
)

RUNNER_TIMEOUT_SECONDS = 60.0
VICTIM_READY_TIMEOUT_SECONDS = 20.0
VICTIM_KILL_TIMEOUT_SECONDS = 5.0
MAX_STDERR_BYTES = 64 * 1024


class NativeMetalInflightProcessKillReportError(ValueError):
    """The process evidence or outer report is not the fixed W7b-b4 profile."""


@dataclass(frozen=True)
class ReadyFrame:
    scalars: Mapping[str, int]
    digests: Mapping[str, bytes]
    encoded: bytes


@dataclass(frozen=True)
class KillReceipt:
    scalars: Mapping[str, int]
    digests: Mapping[str, bytes]
    encoded: bytes


@dataclass(frozen=True)
class DecodedReport:
    header_scalars: Mapping[str, int]
    header_digests: Mapping[str, bytes]
    ready_frame: ReadyFrame
    kill_receipt: KillReceipt
    recovery_wire: bytes
    body_sha256: bytes
    report_sha256: bytes
    encoded: bytes


@dataclass(frozen=True)
class InflightProcessKillVerificationResult:
    victim_pid: int
    termination_signal: int
    blocked_command_count: int
    recovery_record_count: int
    recovery_completed_count: int
    wire_sha256: bytes
    report_sha256: bytes
    victim_sha256: bytes
    recovery_runner_sha256: bytes
    retained_path: Optional[Path] = None


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise NativeMetalInflightProcessKillReportError(message)


def _u64(value: int) -> bytes:
    _require(
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= U64_MAX,
        "value is outside u64",
    )
    return struct.pack("<Q", value)


def _sha256_parts(*parts: bytes) -> bytes:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
    return digest.digest()


def _digest(value: Any, label: str, *, nonzero: bool = True) -> bytes:
    _require(
        isinstance(value, (bytes, bytearray, memoryview)),
        "%s must be bytes" % label,
    )
    result = bytes(value)
    _require(len(result) == 32, "%s must be 32 bytes" % label)
    if nonzero:
        _require(result != ZERO_DIGEST, "%s must be nonzero" % label)
    return result


EXPECTED_SCHEDULE_SHA256 = _sha256_parts(
    SCHEDULE_DOMAIN,
    *(_u64(value) for value in SCHEDULE_TUPLE),
)


def _component_set_sha256(
    victim_sha256: bytes,
    victim_metallib_sha256: bytes,
    recovery_runner_sha256: bytes,
    recovery_metallib_sha256: bytes,
) -> bytes:
    return _sha256_parts(
        COMPONENT_SET_DOMAIN,
        _digest(victim_sha256, "victim component"),
        _digest(victim_metallib_sha256, "victim metallib"),
        _digest(recovery_runner_sha256, "recovery runner"),
        _digest(recovery_metallib_sha256, "recovery metallib"),
    )


def derive_victim_challenge(
    campaign_challenge_sha256: bytes,
    component_set_sha256: bytes,
) -> bytes:
    return _sha256_parts(
        VICTIM_CHALLENGE_DOMAIN,
        _digest(campaign_challenge_sha256, "campaign challenge"),
        EXPECTED_SCHEDULE_SHA256,
        _digest(component_set_sha256, "component set"),
    )


def derive_recovery_challenge(
    campaign_challenge_sha256: bytes,
    component_set_sha256: bytes,
    ready_frame_sha256: bytes,
    kill_receipt_sha256: bytes,
) -> bytes:
    result = _sha256_parts(
        RECOVERY_CHALLENGE_DOMAIN,
        _digest(campaign_challenge_sha256, "campaign challenge"),
        EXPECTED_SCHEDULE_SHA256,
        _digest(component_set_sha256, "component set"),
        _digest(ready_frame_sha256, "ready frame root"),
        _digest(kill_receipt_sha256, "kill receipt root"),
    )
    _require(
        result
        != derive_victim_challenge(
            campaign_challenge_sha256,
            component_set_sha256,
        ),
        "victim and recovery challenges alias",
    )
    return result


def victim_build_sha256(
    victim_sha256: bytes,
    metallib_sha256: bytes,
) -> bytes:
    return _sha256_parts(
        VICTIM_BUILD_DOMAIN,
        _u64(READY_FRAME_ABI),
        _u64(BARRIER_PLAN_ABI),
        _u64(BARRIER_FACTS_ABI),
        _digest(victim_sha256, "victim component"),
        _digest(metallib_sha256, "victim metallib"),
    )


def expected_victim_backend_sha256() -> bytes:
    return _sha256_parts(
        VICTIM_BACKEND_DOMAIN,
        _u64(READY_FRAME_ABI),
        _u64(METAL_DEVICE_INFO_ABI),
        _u64(METAL_ASYNC_SUBMISSION_ABI),
        _u64(METAL_ALLOCATION_ADAPTER_ABI),
        _u64(BARRIER_PLAN_ABI),
        _u64(BARRIER_FACTS_ABI),
    )


def decode_ready_frame(
    encoded_value: bytes,
    *,
    expected_pid: Optional[int] = None,
    expected_challenge_sha256: Optional[bytes] = None,
    expected_victim_sha256: Optional[bytes] = None,
    expected_metallib_sha256: Optional[bytes] = None,
    expected_build_sha256: Optional[bytes] = None,
) -> ReadyFrame:
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "ready frame must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(
        len(encoded) == READY_FRAME_BYTES,
        "ready frame length changed",
    )
    scalar_bytes = READY_SCALAR_COUNT * 8
    scalar_values = struct.unpack(
        "<%dQ" % READY_SCALAR_COUNT,
        encoded[:scalar_bytes],
    )
    scalars = dict(zip(READY_SCALAR_FIELDS, scalar_values))
    digests = {
        field: encoded[
            scalar_bytes + index * 32 : scalar_bytes + (index + 1) * 32
        ]
        for index, field in enumerate(READY_DIGEST_FIELDS)
    }
    _require(
        scalars["abi_version"] == READY_FRAME_ABI,
        "ready frame ABI changed",
    )
    _require(
        scalars["encoded_bytes"] == READY_FRAME_BYTES,
        "ready frame encoded length field changed",
    )
    _require(scalars["flags"] == 0, "ready frame flags changed")
    _require(
        0 < scalars["pid"] < U64_MAX,
        "ready frame PID is invalid",
    )
    if expected_pid is not None:
        _require(
            scalars["pid"] == expected_pid,
            "ready frame PID does not match victim process",
        )
    _require(
        0 < scalars["barrier_generation"] < U64_MAX
        and 0 < scalars["command_generation"] < U64_MAX,
        "ready frame generations are invalid",
    )
    _require(
        scalars["submission_disposition"]
        == SUBMISSION_DISPOSITION_SUBMITTED,
        "victim did not report a submitted command",
    )
    _require(
        scalars["command_buffer_status"]
        in (
            COMMAND_BUFFER_STATUS_COMMITTED,
            COMMAND_BUFFER_STATUS_SCHEDULED,
        ),
        "victim command buffer was not committed or scheduled",
    )
    _require(
        scalars["commit_invoked"] == 1
        and scalars["completion_observed"] == 0,
        "victim commit/completion facts changed",
    )
    _require(
        scalars["shared_event_signaled_value"]
        == EXPECTED_SHARED_EVENT_VALUE
        and scalars["encoded_signal_value"]
        == EXPECTED_ENCODED_SIGNAL_VALUE
        and scalars["encoded_wait_value"]
        == EXPECTED_ENCODED_WAIT_VALUE,
        "victim shared-event barrier facts changed",
    )
    _require(
        scalars["live_native_buffer_count"]
        == EXPECTED_LIVE_NATIVE_BUFFER_COUNT
        and scalars["live_native_command_count"]
        == EXPECTED_LIVE_NATIVE_COMMAND_COUNT
        and scalars["active_allocation_reference_count"]
        == EXPECTED_ACTIVE_ALLOCATION_REFERENCE_COUNT,
        "victim live ownership facts changed",
    )
    for field in READY_DIGEST_FIELDS:
        if field != "frame_sha256":
            _digest(digests[field], "ready.%s" % field)
    _require(
        len(
            {
                digests["machine_sha256"],
                digests["backend_sha256"],
                digests["device_sha256"],
                digests["placement_sha256"],
            }
        )
        == 4,
        "ready machine/backend/device/placement identities alias",
    )
    _require(
        len(
            {
                digests["ticket_sha256"],
                digests["pin_sha256"],
                digests["submission_sha256"],
            }
        )
        == 3,
        "ready ticket/pin/submission roots alias",
    )
    _require(
        digests["build_sha256"]
        == victim_build_sha256(
            digests["victim_sha256"],
            digests["metallib_sha256"],
        ),
        "ready victim build identity changed",
    )
    _require(
        digests["backend_sha256"] == expected_victim_backend_sha256(),
        "ready victim backend identity changed",
    )
    _require(
        digests["frame_sha256"]
        == _sha256_parts(READY_FRAME_DOMAIN, encoded[:480]),
        "ready frame root mismatch",
    )
    for actual, expected, label in (
        (
            digests["challenge_sha256"],
            expected_challenge_sha256,
            "challenge",
        ),
        (digests["victim_sha256"], expected_victim_sha256, "victim"),
        (
            digests["metallib_sha256"],
            expected_metallib_sha256,
            "metallib",
        ),
        (digests["build_sha256"], expected_build_sha256, "build"),
    ):
        if expected is not None:
            _require(
                actual == _digest(expected, "expected %s" % label),
                "ready %s identity changed" % label,
            )
    return ReadyFrame(scalars, digests, encoded)


def _make_kill_receipt(
    *,
    campaign_challenge_sha256: bytes,
    victim_challenge_sha256: bytes,
    ready_frame: ReadyFrame,
    victim_sha256: bytes,
    metallib_sha256: bytes,
    returncode: int,
    stdout_bytes: int,
    stderr_bytes: int,
) -> KillReceipt:
    _require(returncode == -signal.SIGKILL, "victim was not killed by SIGKILL")
    _require(
        stdout_bytes == READY_FRAME_BYTES and stderr_bytes == 0,
        "victim pipe closure facts changed",
    )
    scalars = (
        KILL_RECEIPT_ABI,
        KILL_RECEIPT_BYTES,
        0,
        ready_frame.scalars["pid"],
        signal.SIGKILL,
        returncode & U64_MAX,
        stdout_bytes,
        stderr_bytes,
    )
    digest_values = (
        _digest(campaign_challenge_sha256, "campaign challenge"),
        _digest(victim_challenge_sha256, "victim challenge"),
        ready_frame.digests["frame_sha256"],
        _digest(victim_sha256, "victim component"),
        _digest(metallib_sha256, "victim metallib"),
    )
    prefix = b"".join(
        (*(_u64(value) for value in scalars), *digest_values)
    )
    _require(
        len(prefix) == KILL_RECEIPT_BYTES - 32,
        "kill receipt prefix geometry changed",
    )
    encoded = prefix + _sha256_parts(KILL_RECEIPT_DOMAIN, prefix)
    return decode_kill_receipt(
        encoded,
        expected_campaign_challenge_sha256=campaign_challenge_sha256,
        expected_victim_challenge_sha256=victim_challenge_sha256,
        expected_ready_frame_sha256=ready_frame.digests["frame_sha256"],
        expected_victim_sha256=victim_sha256,
        expected_metallib_sha256=metallib_sha256,
    )


def decode_kill_receipt(
    encoded_value: bytes,
    *,
    expected_campaign_challenge_sha256: Optional[bytes] = None,
    expected_victim_challenge_sha256: Optional[bytes] = None,
    expected_ready_frame_sha256: Optional[bytes] = None,
    expected_victim_sha256: Optional[bytes] = None,
    expected_metallib_sha256: Optional[bytes] = None,
) -> KillReceipt:
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "kill receipt must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(
        len(encoded) == KILL_RECEIPT_BYTES,
        "kill receipt length changed",
    )
    scalar_bytes = KILL_RECEIPT_SCALAR_COUNT * 8
    values = struct.unpack(
        "<%dQ" % KILL_RECEIPT_SCALAR_COUNT,
        encoded[:scalar_bytes],
    )
    scalars = dict(zip(KILL_RECEIPT_SCALAR_FIELDS, values))
    digests = {
        field: encoded[
            scalar_bytes + index * 32 : scalar_bytes + (index + 1) * 32
        ]
        for index, field in enumerate(KILL_RECEIPT_DIGEST_FIELDS)
    }
    _require(
        scalars["abi_version"] == KILL_RECEIPT_ABI
        and scalars["encoded_bytes"] == KILL_RECEIPT_BYTES
        and scalars["flags"] == 0,
        "kill receipt header changed",
    )
    _require(
        0 < scalars["pid"] < U64_MAX,
        "kill receipt PID is invalid",
    )
    _require(
        scalars["termination_signal"] == signal.SIGKILL
        and scalars["returncode_bits"]
        == ((-signal.SIGKILL) & U64_MAX),
        "kill receipt does not prove SIGKILL wait status",
    )
    _require(
        scalars["stdout_bytes"] == READY_FRAME_BYTES
        and scalars["stderr_bytes"] == 0,
        "kill receipt pipe facts changed",
    )
    for field in KILL_RECEIPT_DIGEST_FIELDS:
        _digest(digests[field], "kill.%s" % field)
    _require(
        digests["receipt_sha256"]
        == _sha256_parts(
            KILL_RECEIPT_DOMAIN,
            encoded[: KILL_RECEIPT_BYTES - 32],
        ),
        "kill receipt root mismatch",
    )
    for actual, expected, label in (
        (
            digests["campaign_challenge_sha256"],
            expected_campaign_challenge_sha256,
            "campaign challenge",
        ),
        (
            digests["victim_challenge_sha256"],
            expected_victim_challenge_sha256,
            "victim challenge",
        ),
        (
            digests["ready_frame_sha256"],
            expected_ready_frame_sha256,
            "ready frame",
        ),
        (digests["victim_sha256"], expected_victim_sha256, "victim"),
        (
            digests["metallib_sha256"],
            expected_metallib_sha256,
            "metallib",
        ),
    ):
        if expected is not None:
            _require(
                actual == _digest(expected, "expected %s" % label),
                "kill receipt %s identity changed" % label,
            )
    return KillReceipt(scalars, digests, encoded)


def _validate_timeout(value: float, label: str) -> float:
    try:
        valid = (
            not isinstance(value, bool)
            and math.isfinite(value)
            and value > 0
        )
    except (OverflowError, TypeError):
        valid = False
    _require(valid, "%s must be positive" % label)
    return float(value)


def _isolated_environment(name: str, challenge_sha256: bytes) -> dict[str, str]:
    _require(
        isinstance(name, str)
        and name
        and "=" not in name
        and "\x00" not in name,
        "challenge environment name is invalid",
    )
    return {
        "LC_ALL": "C",
        "PATH": os.defpath,
        name: _digest(challenge_sha256, "process challenge").hex(),
    }


def _cleanup_process(process: Any) -> None:
    if process.poll() is not None:
        return
    try:
        process.kill()
    except (OSError, ProcessLookupError):
        return
    try:
        process.wait(timeout=1.0)
    except (OSError, subprocess.TimeoutExpired):
        pass


def _run_victim_boundary(
    victim: Union[str, os.PathLike],
    victim_challenge_sha256: bytes,
    victim_sha256: bytes,
    metallib_sha256: bytes,
    *,
    expected_build_sha256: Optional[bytes] = None,
    ready_timeout_seconds: float = VICTIM_READY_TIMEOUT_SECONDS,
    kill_timeout_seconds: float = VICTIM_KILL_TIMEOUT_SECONDS,
    popen_factory: Callable[..., Any] = subprocess.Popen,
    kill_function: Callable[[int, int], None] = os.kill,
) -> Tuple[ReadyFrame, int, bytes, bytes]:
    path = os.fspath(victim)
    _require(bool(path), "missing victim executable")
    ready_timeout = _validate_timeout(
        ready_timeout_seconds,
        "victim ready timeout",
    )
    kill_timeout = _validate_timeout(
        kill_timeout_seconds,
        "victim kill timeout",
    )
    try:
        process = popen_factory(
            [path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_isolated_environment(
                VICTIM_CHALLENGE_ENVIRONMENT,
                victim_challenge_sha256,
            ),
            close_fds=True,
        )
    except (OSError, TypeError, ValueError) as error:
        raise NativeMetalInflightProcessKillReportError(
            "could not start event-blocked victim: %s" % error
        ) from error
    if process.stdout is None or process.stderr is None:
        _cleanup_process(process)
        raise NativeMetalInflightProcessKillReportError(
            "could not capture victim pipes"
        )

    output = bytearray()
    errors = bytearray()
    stdout_eof = False
    stderr_eof = False
    selector = selectors.DefaultSelector()
    try:
        os.set_blocking(process.stdout.fileno(), False)
        os.set_blocking(process.stderr.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + ready_timeout
        while len(output) < READY_FRAME_BYTES:
            _require(
                process.poll() is None,
                "victim exited before publishing its ready frame",
            )
            remaining = deadline - time.monotonic()
            _require(remaining > 0, "victim ready frame timed out")
            events = selector.select(min(remaining, 0.05))
            for key, _mask in events:
                try:
                    chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    if key.data == "stdout":
                        stdout_eof = True
                    else:
                        stderr_eof = True
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stdout":
                    output.extend(chunk)
                    _require(
                        len(output) <= READY_FRAME_BYTES,
                        "victim wrote extra bytes before kill",
                    )
                else:
                    errors.extend(chunk)
                    _require(
                        len(errors) <= MAX_STDERR_BYTES,
                        "victim stderr exceeded its bound",
                    )
            _require(
                not stdout_eof,
                "victim stdout closed before PID-only kill",
            )
            _require(
                not stderr_eof,
                "victim stderr closed before PID-only kill",
            )

        # Re-probe every pipe once the fixed frame is complete.  A producer
        # that wrote exactly 512 bytes and then exited can otherwise leave a
        # readable EOF event queued just after the final data event.
        while True:
            pending = selector.select(0)
            if not pending:
                break
            for key, _mask in pending:
                try:
                    chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    if key.data == "stdout":
                        stdout_eof = True
                    else:
                        stderr_eof = True
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stdout":
                    output.extend(chunk)
                    _require(
                        len(output) <= READY_FRAME_BYTES,
                        "victim wrote extra bytes before kill",
                    )
                else:
                    errors.extend(chunk)
                    _require(
                        len(errors) <= MAX_STDERR_BYTES,
                        "victim stderr exceeded its bound",
                    )
        _require(
            not stdout_eof,
            "victim stdout closed before PID-only kill",
        )
        _require(
            not stderr_eof,
            "victim stderr closed before PID-only kill",
        )

        ready = decode_ready_frame(
            bytes(output),
            expected_pid=process.pid,
            expected_challenge_sha256=victim_challenge_sha256,
            expected_victim_sha256=victim_sha256,
            expected_metallib_sha256=metallib_sha256,
            expected_build_sha256=expected_build_sha256,
        )
        _require(
            process.poll() is None,
            "victim exited before PID-only kill",
        )
        try:
            kill_function(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError) as error:
            raise NativeMetalInflightProcessKillReportError(
                "could not send PID-only SIGKILL: %s" % error
            ) from error

        deadline = time.monotonic() + kill_timeout
        while not (stdout_eof and stderr_eof and process.poll() is not None):
            remaining = deadline - time.monotonic()
            _require(remaining > 0, "victim did not close after SIGKILL")
            for key, _mask in selector.select(min(remaining, 0.05)):
                try:
                    chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    if key.data == "stdout":
                        stdout_eof = True
                    else:
                        stderr_eof = True
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stdout":
                    output.extend(chunk)
                    _require(
                        len(output) <= READY_FRAME_BYTES,
                        "victim wrote extra stdout bytes",
                    )
                else:
                    errors.extend(chunk)
                    _require(
                        len(errors) <= MAX_STDERR_BYTES,
                        "victim stderr exceeded its bound",
                    )
        returncode = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        _require(
            returncode == -signal.SIGKILL,
            "victim wait status was not -SIGKILL",
        )
        _require(
            bytes(output) == ready.encoded,
            "victim stdout changed after ready validation",
        )
        _require(errors == b"", "victim wrote to stderr")
        return ready, returncode, bytes(output), bytes(errors)
    except BaseException:
        _cleanup_process(process)
        raise
    finally:
        selector.close()
        for stream in (process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass


def _header_prefix(
    scalars: Sequence[int],
    digests_without_header: Sequence[bytes],
) -> bytes:
    _require(
        len(scalars) == REPORT_HEADER_SCALAR_COUNT,
        "outer header scalar count changed",
    )
    _require(
        len(digests_without_header) == REPORT_HEADER_DIGEST_COUNT - 1,
        "outer header digest count changed",
    )
    return b"".join(
        (
            *(_u64(value) for value in scalars),
            *(_digest(value, "outer header digest") for value in digests_without_header),
        )
    )


def _make_outer_report(
    *,
    campaign_challenge_sha256: bytes,
    component_set_sha256: bytes,
    ready_frame: ReadyFrame,
    kill_receipt: KillReceipt,
    recovery_challenge_sha256: bytes,
    recovery_runner_sha256: bytes,
    recovery_metallib_sha256: bytes,
    recovery_wire: bytes,
) -> bytes:
    recovery_result = w6.verify_native_wire(
        recovery_wire,
        recovery_runner_sha256,
        recovery_metallib_sha256,
        recovery_challenge_sha256,
    )
    recovery_build_sha256 = w6._native_build_sha256(
        recovery_runner_sha256,
        recovery_metallib_sha256,
    )
    scalars = (
        REPORT_ABI,
        EXPECTED_REPORT_BYTES,
        REPORT_FLAGS,
        REPORT_HEADER_BYTES,
        READY_FRAME_BYTES,
        KILL_RECEIPT_BYTES,
        EXPECTED_RECOVERY_WIRE_BYTES,
        EXPECTED_VICTIM_COUNT,
        EXPECTED_BLOCKED_COMMAND_COUNT,
        EXPECTED_SIGKILL_COUNT,
        EXPECTED_RECOVERY_RECORD_COUNT,
        EXPECTED_RECOVERY_COMPLETED_COUNT,
        EXPECTED_RECOVERY_WORK_UNITS,
        EXPECTED_FLOW_COUNT,
        EXPECTED_QUEUE_COUNT,
        0,
    )
    digest_values = (
        _digest(campaign_challenge_sha256, "campaign challenge"),
        EXPECTED_SCHEDULE_SHA256,
        ready_frame.digests["challenge_sha256"],
        _digest(recovery_challenge_sha256, "recovery challenge"),
        ready_frame.digests["victim_sha256"],
        ready_frame.digests["metallib_sha256"],
        ready_frame.digests["build_sha256"],
        _digest(recovery_runner_sha256, "recovery runner"),
        _digest(recovery_metallib_sha256, "recovery metallib"),
        recovery_build_sha256,
        ready_frame.digests["frame_sha256"],
        kill_receipt.digests["receipt_sha256"],
        hashlib.sha256(recovery_wire).digest(),
        recovery_result.report_sha256,
        _digest(component_set_sha256, "component set"),
    )
    prefix = _header_prefix(scalars, digest_values)
    _require(
        len(prefix) == REPORT_HEADER_BYTES - 32,
        "outer header prefix geometry changed",
    )
    header = prefix + _sha256_parts(REPORT_HEADER_DOMAIN, prefix)
    body = b"".join(
        (
            header,
            ready_frame.encoded,
            kill_receipt.encoded,
            recovery_wire,
        )
    )
    body_sha256 = _sha256_parts(REPORT_BODY_DOMAIN, body)
    report_sha256 = _sha256_parts(
        REPORT_ROOT_DOMAIN,
        header[-32:],
        ready_frame.digests["frame_sha256"],
        kill_receipt.digests["receipt_sha256"],
        hashlib.sha256(recovery_wire).digest(),
        recovery_result.report_sha256,
        body_sha256,
    )
    encoded = body + body_sha256 + report_sha256
    _require(
        len(encoded) == EXPECTED_REPORT_BYTES,
        "outer report encoded length changed",
    )
    verify_outer_wire(encoded)
    return encoded


def verify_outer_wire(
    encoded_value: bytes,
    *,
    expected_components: Optional[Mapping[str, bytes]] = None,
) -> DecodedReport:
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "outer report must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(
        len(encoded) == EXPECTED_REPORT_BYTES,
        "outer report length changed",
    )
    header = encoded[:REPORT_HEADER_BYTES]
    scalar_bytes = REPORT_HEADER_SCALAR_COUNT * 8
    scalar_values = struct.unpack(
        "<%dQ" % REPORT_HEADER_SCALAR_COUNT,
        header[:scalar_bytes],
    )
    scalars = dict(zip(REPORT_HEADER_SCALAR_FIELDS, scalar_values))
    digests = {
        field: header[
            scalar_bytes + index * 32 : scalar_bytes + (index + 1) * 32
        ]
        for index, field in enumerate(REPORT_HEADER_DIGEST_FIELDS)
    }
    expected_scalars = (
        REPORT_ABI,
        EXPECTED_REPORT_BYTES,
        REPORT_FLAGS,
        REPORT_HEADER_BYTES,
        READY_FRAME_BYTES,
        KILL_RECEIPT_BYTES,
        EXPECTED_RECOVERY_WIRE_BYTES,
        EXPECTED_VICTIM_COUNT,
        EXPECTED_BLOCKED_COMMAND_COUNT,
        EXPECTED_SIGKILL_COUNT,
        EXPECTED_RECOVERY_RECORD_COUNT,
        EXPECTED_RECOVERY_COMPLETED_COUNT,
        EXPECTED_RECOVERY_WORK_UNITS,
        EXPECTED_FLOW_COUNT,
        EXPECTED_QUEUE_COUNT,
        0,
    )
    _require(
        scalar_values == expected_scalars,
        "outer report scalar profile changed",
    )
    for field in REPORT_HEADER_DIGEST_FIELDS:
        _digest(digests[field], "outer.%s" % field)
    _require(
        digests["schedule_sha256"] == EXPECTED_SCHEDULE_SHA256,
        "outer report schedule changed",
    )
    _require(
        digests["header_sha256"]
        == _sha256_parts(
            REPORT_HEADER_DOMAIN,
            header[: REPORT_HEADER_BYTES - 32],
        ),
        "outer header root mismatch",
    )
    frame_start = REPORT_HEADER_BYTES
    frame_end = frame_start + READY_FRAME_BYTES
    kill_end = frame_end + KILL_RECEIPT_BYTES
    recovery_end = kill_end + EXPECTED_RECOVERY_WIRE_BYTES
    ready = decode_ready_frame(
        encoded[frame_start:frame_end],
        expected_challenge_sha256=digests["victim_challenge_sha256"],
        expected_victim_sha256=digests["victim_sha256"],
        expected_metallib_sha256=digests["victim_metallib_sha256"],
        expected_build_sha256=digests["victim_build_sha256"],
    )
    kill_receipt = decode_kill_receipt(
        encoded[frame_end:kill_end],
        expected_campaign_challenge_sha256=digests[
            "campaign_challenge_sha256"
        ],
        expected_victim_challenge_sha256=digests[
            "victim_challenge_sha256"
        ],
        expected_ready_frame_sha256=digests["ready_frame_sha256"],
        expected_victim_sha256=digests["victim_sha256"],
        expected_metallib_sha256=digests["victim_metallib_sha256"],
    )
    _require(
        kill_receipt.scalars["pid"] == ready.scalars["pid"],
        "ready and kill receipt PIDs disagree",
    )
    recovery_wire = encoded[kill_end:recovery_end]
    try:
        recovery_result = w6.verify_native_wire(
            recovery_wire,
            digests["recovery_runner_sha256"],
            digests["recovery_metallib_sha256"],
            digests["recovery_challenge_sha256"],
        )
        recovery_decoded = w6._decode_after_portable_verification(
            recovery_wire
        )
    except w6.NativeMetalReportError as error:
        raise NativeMetalInflightProcessKillReportError(
            "fresh production W6 wire was rejected: %s" % error
        ) from error
    _require(
        ready.digests["machine_sha256"]
        == recovery_decoded.scenario.identities[4]
        and ready.digests["device_sha256"]
        == recovery_decoded.scenario.identities[6]
        and ready.digests["placement_sha256"]
        == recovery_decoded.scenario.identities[7],
        "victim and fresh W6 machine/device/placement identities disagree",
    )
    _require(
        digests["recovery_build_sha256"]
        == w6._native_build_sha256(
            digests["recovery_runner_sha256"],
            digests["recovery_metallib_sha256"],
        ),
        "outer recovery build identity changed",
    )
    _require(
        digests["ready_frame_sha256"] == ready.digests["frame_sha256"]
        and digests["kill_receipt_sha256"]
        == kill_receipt.digests["receipt_sha256"]
        and digests["recovery_wire_sha256"]
        == hashlib.sha256(recovery_wire).digest()
        and digests["recovery_report_sha256"]
        == recovery_result.report_sha256,
        "outer embedded evidence roots disagree",
    )
    expected_component_set = _component_set_sha256(
        digests["victim_sha256"],
        digests["victim_metallib_sha256"],
        digests["recovery_runner_sha256"],
        digests["recovery_metallib_sha256"],
    )
    _require(
        digests["component_set_sha256"] == expected_component_set,
        "outer component-set root changed",
    )
    _require(
        digests["victim_challenge_sha256"]
        == derive_victim_challenge(
            digests["campaign_challenge_sha256"],
            expected_component_set,
        ),
        "outer victim challenge derivation changed",
    )
    _require(
        digests["recovery_challenge_sha256"]
        == derive_recovery_challenge(
            digests["campaign_challenge_sha256"],
            expected_component_set,
            digests["ready_frame_sha256"],
            digests["kill_receipt_sha256"],
        ),
        "outer recovery challenge derivation changed",
    )
    if expected_components is not None:
        expected_keys = {
            "victim_sha256",
            "victim_metallib_sha256",
            "recovery_runner_sha256",
            "recovery_metallib_sha256",
        }
        _require(
            set(expected_components) == expected_keys,
            "expected component identity keys changed",
        )
        for key in expected_keys:
            _require(
                digests[key]
                == _digest(expected_components[key], "expected %s" % key),
                "outer %s changed" % key,
            )
    body = encoded[:recovery_end]
    body_sha256 = encoded[recovery_end : recovery_end + 32]
    report_sha256 = encoded[recovery_end + 32 :]
    _require(
        body_sha256 == _sha256_parts(REPORT_BODY_DOMAIN, body),
        "outer body root mismatch",
    )
    _require(
        report_sha256
        == _sha256_parts(
            REPORT_ROOT_DOMAIN,
            digests["header_sha256"],
            digests["ready_frame_sha256"],
            digests["kill_receipt_sha256"],
            digests["recovery_wire_sha256"],
            digests["recovery_report_sha256"],
            body_sha256,
        ),
        "outer report root mismatch",
    )
    return DecodedReport(
        scalars,
        digests,
        ready,
        kill_receipt,
        recovery_wire,
        body_sha256,
        report_sha256,
        encoded,
    )


def _component_file_sha256(
    path: Union[str, os.PathLike],
    label: str,
) -> bytes:
    try:
        return w6._component_file_sha256(path, label)
    except w6.NativeMetalReportError as error:
        raise NativeMetalInflightProcessKillReportError(str(error)) from error


def _snapshot_components(
    victim: Union[str, os.PathLike],
    victim_metallib: Union[str, os.PathLike],
    recovery_runner: Union[str, os.PathLike],
    recovery_metallib: Union[str, os.PathLike],
) -> dict[str, bytes]:
    return {
        "victim_sha256": _component_file_sha256(victim, "victim"),
        "victim_metallib_sha256": _component_file_sha256(
            victim_metallib,
            "victim metallib",
        ),
        "recovery_runner_sha256": _component_file_sha256(
            recovery_runner,
            "recovery runner",
        ),
        "recovery_metallib_sha256": _component_file_sha256(
            recovery_metallib,
            "recovery metallib",
        ),
    }


def _verify_components_unchanged(
    paths: Mapping[str, Union[str, os.PathLike]],
    expected: Mapping[str, bytes],
) -> None:
    failures = []
    for key, path in paths.items():
        try:
            actual = _component_file_sha256(path, key)
        except NativeMetalInflightProcessKillReportError as error:
            failures.append(str(error))
            continue
        if actual != expected[key]:
            failures.append("%s changed during execution" % key)
    _require(
        not failures,
        "producer components changed: %s" % "; ".join(failures),
    )


def _run_recovery_worker(
    runner: Union[str, os.PathLike],
    challenge_sha256: bytes,
    runner_sha256: bytes,
    metallib_sha256: bytes,
    timeout_seconds: float,
) -> bytes:
    try:
        returncode, stdout, stderr = w6._bounded_runner_output(
            [os.fspath(runner)],
            timeout_seconds,
            challenge_sha256,
            EXPECTED_RECOVERY_WIRE_BYTES,
            w6.CHALLENGE_ENVIRONMENT,
        )
    except w6.NativeMetalReportError as error:
        raise NativeMetalInflightProcessKillReportError(str(error)) from error
    if returncode != 0:
        detail = stderr[:4096].decode("utf-8", errors="replace")
        raise NativeMetalInflightProcessKillReportError(
            "fresh production W6 runner failed (%d): %s"
            % (returncode, detail)
        )
    _require(stderr == b"", "fresh production W6 runner wrote to stderr")
    try:
        w6.verify_native_wire(
            stdout,
            runner_sha256,
            metallib_sha256,
            challenge_sha256,
        )
    except w6.NativeMetalReportError as error:
        raise NativeMetalInflightProcessKillReportError(str(error)) from error
    return stdout


def run_campaign(
    victim: Union[str, os.PathLike],
    victim_metallib: Union[str, os.PathLike],
    recovery_runner: Union[str, os.PathLike],
    recovery_metallib: Union[str, os.PathLike],
    retain_artifact: Optional[Union[str, os.PathLike]] = None,
    *,
    timeout_seconds: float = RUNNER_TIMEOUT_SECONDS,
    campaign_challenge_sha256: Optional[bytes] = None,
    expected_victim_build_sha256: Optional[bytes] = None,
) -> InflightProcessKillVerificationResult:
    timeout = _validate_timeout(timeout_seconds, "campaign timeout")
    paths = {
        "victim_sha256": victim,
        "victim_metallib_sha256": victim_metallib,
        "recovery_runner_sha256": recovery_runner,
        "recovery_metallib_sha256": recovery_metallib,
    }
    components = _snapshot_components(
        victim,
        victim_metallib,
        recovery_runner,
        recovery_metallib,
    )
    component_set = _component_set_sha256(
        components["victim_sha256"],
        components["victim_metallib_sha256"],
        components["recovery_runner_sha256"],
        components["recovery_metallib_sha256"],
    )
    campaign_challenge = (
        os.urandom(32)
        if campaign_challenge_sha256 is None
        else _digest(campaign_challenge_sha256, "campaign challenge")
    )
    _require(
        campaign_challenge != ZERO_DIGEST,
        "campaign challenge must be nonzero",
    )
    victim_challenge = derive_victim_challenge(
        campaign_challenge,
        component_set,
    )
    try:
        ready, returncode, stdout, stderr = _run_victim_boundary(
            victim,
            victim_challenge,
            components["victim_sha256"],
            components["victim_metallib_sha256"],
            expected_build_sha256=expected_victim_build_sha256,
            ready_timeout_seconds=min(timeout, VICTIM_READY_TIMEOUT_SECONDS),
            kill_timeout_seconds=min(timeout, VICTIM_KILL_TIMEOUT_SECONDS),
        )
    finally:
        _verify_components_unchanged(paths, components)
    kill_receipt = _make_kill_receipt(
        campaign_challenge_sha256=campaign_challenge,
        victim_challenge_sha256=victim_challenge,
        ready_frame=ready,
        victim_sha256=components["victim_sha256"],
        metallib_sha256=components["victim_metallib_sha256"],
        returncode=returncode,
        stdout_bytes=len(stdout),
        stderr_bytes=len(stderr),
    )
    recovery_challenge = derive_recovery_challenge(
        campaign_challenge,
        component_set,
        ready.digests["frame_sha256"],
        kill_receipt.digests["receipt_sha256"],
    )
    try:
        recovery_wire = _run_recovery_worker(
            recovery_runner,
            recovery_challenge,
            components["recovery_runner_sha256"],
            components["recovery_metallib_sha256"],
            timeout,
        )
    finally:
        _verify_components_unchanged(paths, components)
    encoded = _make_outer_report(
        campaign_challenge_sha256=campaign_challenge,
        component_set_sha256=component_set,
        ready_frame=ready,
        kill_receipt=kill_receipt,
        recovery_challenge_sha256=recovery_challenge,
        recovery_runner_sha256=components["recovery_runner_sha256"],
        recovery_metallib_sha256=components["recovery_metallib_sha256"],
        recovery_wire=recovery_wire,
    )
    decoded = verify_outer_wire(
        encoded,
        expected_components=components,
    )
    retained_path: Optional[Path] = None
    if retain_artifact is not None:
        try:
            retained_path = w6._write_retained_artifact(
                retain_artifact,
                encoded,
            )
        except w6.NativeMetalReportError as error:
            raise NativeMetalInflightProcessKillReportError(
                str(error)
            ) from error
    return InflightProcessKillVerificationResult(
        ready.scalars["pid"],
        signal.SIGKILL,
        EXPECTED_BLOCKED_COMMAND_COUNT,
        EXPECTED_RECOVERY_RECORD_COUNT,
        EXPECTED_RECOVERY_COMPLETED_COUNT,
        hashlib.sha256(encoded).digest(),
        decoded.report_sha256,
        components["victim_sha256"],
        components["recovery_runner_sha256"],
        retained_path,
    )


def verify_report_file(
    path_value: Union[str, os.PathLike],
) -> InflightProcessKillVerificationResult:
    path = Path(path_value)
    _require(
        path.is_file() and not path.is_symlink(),
        "outer report path is not a regular file",
    )
    before = path.stat()
    _require(
        before.st_size == EXPECTED_REPORT_BYTES,
        "outer report file length changed",
    )
    encoded = path.read_bytes()
    after = path.stat()
    _require(
        (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        == (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ),
        "outer report file changed while reading",
    )
    decoded = verify_outer_wire(encoded)
    return InflightProcessKillVerificationResult(
        decoded.ready_frame.scalars["pid"],
        signal.SIGKILL,
        EXPECTED_BLOCKED_COMMAND_COUNT,
        EXPECTED_RECOVERY_RECORD_COUNT,
        EXPECTED_RECOVERY_COMPLETED_COUNT,
        hashlib.sha256(encoded).digest(),
        decoded.report_sha256,
        decoded.header_digests["victim_sha256"],
        decoded.header_digests["recovery_runner_sha256"],
        path,
    )


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run or independently verify the fixed event-blocked "
            "Metal worker-death report"
        )
    )
    parser.add_argument("--victim")
    parser.add_argument("--victim-metallib")
    parser.add_argument("--recovery-runner")
    parser.add_argument("--recovery-metallib")
    parser.add_argument("--verify")
    parser.add_argument("--output")
    arguments = parser.parse_args(argv)
    try:
        if arguments.verify:
            _require(
                not any(
                    (
                        arguments.victim,
                        arguments.victim_metallib,
                        arguments.recovery_runner,
                        arguments.recovery_metallib,
                        arguments.output,
                    )
                ),
                "--verify cannot be combined with campaign arguments",
            )
            result = verify_report_file(arguments.verify)
        else:
            _require(
                all(
                    (
                        arguments.victim,
                        arguments.victim_metallib,
                        arguments.recovery_runner,
                        arguments.recovery_metallib,
                    )
                ),
                "campaign component arguments are required",
            )
            result = run_campaign(
                arguments.victim,
                arguments.victim_metallib,
                arguments.recovery_runner,
                arguments.recovery_metallib,
                arguments.output,
            )
    except NativeMetalInflightProcessKillReportError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    retained = (
        " retained=%s" % result.retained_path
        if result.retained_path is not None
        else ""
    )
    print(
        "ok native-metal-inflight-process-kill-report-v1 "
        "pid=%d signal=%d blocked=%d recovery_records=%d "
        "recovery_completed=%d wire_sha256=%s report_sha256=%s%s"
        % (
            result.victim_pid,
            result.termination_signal,
            result.blocked_command_count,
            result.recovery_record_count,
            result.recovery_completed_count,
            result.wire_sha256.hex(),
            result.report_sha256.hex(),
            retained,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
