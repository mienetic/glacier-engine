"""Process-death campaign for acknowledged prepared-text recovery.

The worker owns inference and the Zig codecs.  This controller owns process
boundaries: it accepts a crash only after one exact, bounded ready frame, then
requires real SIGKILL termination.  Final sink and checkpoint files are parsed
again here with an intentionally small independent wire verifier.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
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
import time
from typing import Callable, Mapping, Sequence, cast


CRASH_READY_SCHEMA = "glacier.prepared-text-recovery/crash-ready-v1"
RESULT_SCHEMA = "glacier.prepared-text-recovery/result-v1"
CAMPAIGN_SCHEMA = "glacier.prepared-text-recovery/campaign-v1"

BOOTSTRAP_CHECKPOINT_PHASES = (
    "bootstrap_checkpoint_archive_write",
    "bootstrap_checkpoint_archive_sync",
    "bootstrap_checkpoint_archive_directory_sync",
    "bootstrap_checkpoint_selector_write",
    "bootstrap_checkpoint_selector_sync",
    "bootstrap_checkpoint_selector_rename",
    "bootstrap_checkpoint_selector_directory_sync",
)
BOOTSTRAP_CHECKPOINT_SELECTED_POINTS = frozenset(
    BOOTSTRAP_CHECKPOINT_PHASES[-2:]
)

SOURCE_CRASH_POINTS = (
    "source_after_recovery_admission",
    "source_sink_ledger_body_write",
    "source_sink_ledger_body_sync",
    "source_sink_ledger_footer_write",
    "source_sink_ledger_file_sync",
    "source_sink_ledger_immutable_rename",
    "source_sink_ledger_directory_sync",
    "source_sink_selector_temp_write",
    "source_sink_selector_temp_sync",
    "source_sink_selector_replace",
    "source_sink_selector_directory_sync",
    "source_after_initial_sink",
    "source_after_step",
    "source_after_handoff_prepare",
    "source_after_exit_commit",
    "source_checkpoint_archive_write",
    "source_checkpoint_archive_sync",
    "source_checkpoint_archive_directory_sync",
    "source_checkpoint_selector_write",
    "source_checkpoint_selector_sync",
    "source_checkpoint_selector_rename",
    "source_checkpoint_selector_directory_sync",
    "source_after_generation_two",
)
SOURCE_SINK_SELECTED_POINTS = frozenset(SOURCE_CRASH_POINTS[9:])
SOURCE_CHECKPOINT_GENERATION_TWO_POINTS = frozenset(
    SOURCE_CRASH_POINTS[20:]
)

AFTER_STEP_BEFORE_SINK = "after_step_before_sink"
SINK_PHASES = (
    "sink_ledger_body_write",
    "sink_ledger_body_sync",
    "sink_ledger_footer_write",
    "sink_ledger_file_sync",
    "sink_ledger_immutable_rename",
    "sink_ledger_directory_sync",
    "sink_selector_temp_write",
    "sink_selector_temp_sync",
    "sink_selector_replace",
    "sink_selector_directory_sync",
)
AFTER_SINK_BEFORE_SELECTOR = "after_sink_before_selector"
CHECKPOINT_PHASES = (
    "checkpoint_archive_write",
    "checkpoint_archive_sync",
    "checkpoint_archive_directory_sync",
    "checkpoint_selector_write",
    "checkpoint_selector_sync",
    "checkpoint_selector_rename",
    "checkpoint_selector_directory_sync",
)
TARGET_CRASH_POINTS = (
    AFTER_STEP_BEFORE_SINK,
    *SINK_PHASES,
    AFTER_SINK_BEFORE_SELECTOR,
    *CHECKPOINT_PHASES,
)
CRASH_POINTS = (
    *BOOTSTRAP_CHECKPOINT_PHASES,
    *SOURCE_CRASH_POINTS,
    *TARGET_CRASH_POINTS,
)
if (
    len(BOOTSTRAP_CHECKPOINT_PHASES) != 7
    or len(SOURCE_CRASH_POINTS) != 23
    or len(TARGET_CRASH_POINTS) != 19
    or len(CRASH_POINTS) != 49
    or len(set(CRASH_POINTS)) != 49
):
    raise RuntimeError("prepared-text crash-point table changed")
SINK_SUCCESSOR_VISIBLE_POINTS = frozenset(
    {
        "sink_selector_replace",
        "sink_selector_directory_sync",
        AFTER_SINK_BEFORE_SELECTOR,
        *CHECKPOINT_PHASES,
    }
)
CHECKPOINT_SUCCESSOR_VISIBLE_POINTS = frozenset(
    {
        "checkpoint_selector_rename",
        "checkpoint_selector_directory_sync",
    }
)

MAX_JSON_FRAME_BYTES = 16 * 1024
MAX_STDERR_BYTES = 16 * 1024
MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
MAX_FIXTURE_BYTES = 64 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 20.0
DEFAULT_MAX_RECOVERY_PROCESSES = 8
TERMINAL_OUTPUT_COUNT = 4
ZERO_DIGEST = bytes(32)
BASELINE_FIXTURE_NAMES = (
    "prepared-text-fixture.safetensors",
    "prepared-text-fixture.glacier",
    "prepared-text-fixture.glrt",
    "prepared-text-terminal-semantic.bin",
)

# Independent prepared-text result-sink wire constants.
SINK_ACTIVE_SELECTOR_NAME = ".glacier-prepared-text-result-sink-active-v1"
SINK_SELECTOR_MAGIC = b"GPRSSEL1"
SINK_SELECTOR_ABI = 0x4750_524C_0000_0002
SINK_SELECTOR_BYTES = 272
SINK_SELECTOR_BODY_BYTES = 240
SINK_SELECTOR_DOMAIN = b"glacier-prepared-text-result-sink-selector-v1\x00"
SINK_LEDGER_MAGIC = b"GPRSLED1"
SINK_LEDGER_ABI = 0x4750_524C_0000_0001
SINK_LEDGER_HEADER_BYTES = 256
SINK_LEDGER_FOOTER_BYTES = 32
SINK_LEDGER_DOMAIN = b"glacier-prepared-text-result-sink-ledger-v1\x00"
ACK_MAGIC = b"GPRSACK1"
ACK_ABI = 0x4750_5253_0000_0001
ACK_BYTES = 424
ACK_BODY_BYTES = 392
ACK_DOMAIN = b"glacier-prepared-text-result-acknowledgement-v1\x00"
DELIVERY_KEY_DOMAIN = b"glacier-prepared-text-result-delivery-key-v1\x00"
SINK_PREFIX_DOMAIN = b"glacier-prepared-text-result-sink-prefix-v1\x00"

# Independent continuation-checkpoint wire constants.
CHECKPOINT_ACTIVE_SELECTOR_NAME = ".glacier-checkpoint-active-v1"
CHECKPOINT_SELECTOR_MAGIC = b"GCSWIT1\x00"
CHECKPOINT_SELECTOR_ABI = 0x4743_5357_0000_0001
CHECKPOINT_SELECTOR_BYTES = 192
CHECKPOINT_SELECTOR_BODY_BYTES = 160
CHECKPOINT_SELECTOR_DOMAIN = b"glacier-continuation-checkpoint-selector-v1\x00"
CHECKPOINT_SET_MAGIC = b"GCSET01\x00"
CHECKPOINT_SET_ABI = 0x4743_5345_0000_0001
CHECKPOINT_SET_HEADER_BYTES = 128
CHECKPOINT_SET_ENTRY_BYTES = 72
CHECKPOINT_SET_MAX_OBJECTS = 8
CHECKPOINT_SET_PAYLOAD_OFFSET = (
    CHECKPOINT_SET_HEADER_BYTES
    + CHECKPOINT_SET_ENTRY_BYTES * CHECKPOINT_SET_MAX_OBJECTS
)
CHECKPOINT_SET_FOOTER_BYTES = 32
CHECKPOINT_SET_DOMAIN = b"glacier-continuation-checkpoint-set-v1\x00"
CHECKPOINT_OBJECT_DOMAIN = b"glacier-continuation-checkpoint-object-v1\x00"
TERMINAL_OUTPUT_TOKENS_ABI = 0x4750_544F_0000_0001

# Independent generation-one source-replay contract constants.
SOURCE_LIVE_MARKER_ABI = 0x4750_544C_0000_0001
SOURCE_LIVE_MARKER = b"glacier-prepared-text-source-live-v1"
SOURCE_REPLAY_CONTRACT_MAGIC = b"GPTREPL1"
SOURCE_REPLAY_CONTRACT_ABI = 0x4750_5452_0000_0001
SOURCE_REPLAY_HEADER_BYTES = 128
SOURCE_REPLAY_FIXED_PAYLOAD_BYTES = 832
SOURCE_REPLAY_PROMPT_OFFSET = 960
SOURCE_REPLAY_FOOTER_BYTES = 32
SOURCE_REPLAY_DOMAIN = b"glacier-prepared-text-source-replay-contract-v1\x00"
SOURCE_PROMPT_DOMAIN = b"glacier-prepared-text-prompt-v1\x00"
SOURCE_TARGET_DOMAIN = b"glacier-prepared-text-source-replay-target-v1\x00"
SOURCE_OWNERSHIP_DOMAIN = b"glacier-prepared-text-ownership-v1\x00"
SOURCE_EXIT_RECEIPT_DOMAIN = (
    b"glacier-lane-weave-qos-source-exit-receipt-v1\x00"
)
RESOURCE_RECEIPT_DOMAIN = (
    b"glacier-lane-weave-qos-resource-receipt-v1\x00"
)
SOURCE_OWNERSHIP_INTENT_ABI = 0x474C_544F_0000_0001
RESOURCE_BANK_ABI = 0x4752_424B_0000_0001
PREPARED_TEXT_PLAN_ABI = 0x474C_5450_0000_0001
PREPARED_TEXT_BOUND_PLAN_ABI = 0x474C_5443_0000_0001
PREPARED_TEXT_ARTIFACT_PROFILE_ABI = 0x474C_5441_0000_0001
SOURCE_EXIT_RECEIPT_ABI = 0x474C_5752_0000_0001
RESOURCE_RECEIPT_INTEGRITY_DOMAIN = 0x7265_6365_6970_7431
LANE_TRANSCRIPT_SNAPSHOT_ABI = 0x474C_5056_0000_0002
LANE_CONTIGUOUS_EXECUTION_ABI = 0x474C_434F_0000_0001
LANE_STATE_COMMITMENT_ABI = 0x474C_5053_0000_0001
LANE_CONTIGUOUS_RNG_STATE_ABI = 0x474C_4352_0000_0001
LANE_STATE_COMMITMENT_DOMAIN = b"glacier-lane-publication-state-v1\x00"
U64_MAX = (1 << 64) - 1

# Independent generation-two source-exit/restart evidence constants.
SOURCE_EXIT_WIRE_MAGIC = b"GPTEXI1\x00"
SOURCE_EXIT_WIRE_ABI = 0x4750_5458_0000_0001
SOURCE_EXIT_WIRE_BYTES = 640
SOURCE_EXIT_WIRE_BODY_BYTES = 608
SOURCE_EXIT_WIRE_DOMAIN = b"glacier-prepared-text-source-exit-wire-v1\x00"
EVIDENCE_ARCHIVE_OBJECT_ABI = 0x4750_5441_0000_0001
RESTART_MANIFEST_MAGIC = b"GLTRST01"
RESTART_MANIFEST_ABI = 0x474C_5458_0000_0001
RESTART_MANIFEST_HEADER_BYTES = 96
RESTART_MANIFEST_FIXED_PAYLOAD_BYTES = 2824
RESTART_MANIFEST_PROMPT_OFFSET = 2920
RESTART_MANIFEST_DOMAIN = b"glacier-prepared-text-restart-manifest-v1\x00"
RESTART_PLAN_DOMAIN = b"glacier-prepared-text-plan-v1\x00"
RESTART_BOUND_PLAN_DOMAIN = b"glacier-prepared-text-bound-plan-v1\x00"
RESTART_PLAN_OFFSET = 120
RESTART_BOUND_PLAN_OFFSET = 408
RESTART_EXECUTION_OFFSET = 896
RESTART_RESIDENCY_OFFSET = 1664
RESTART_EXPECTED_BINDINGS_OFFSET = 1920
RESTART_TARGET_OFFSET = 2744
CHECKPOINT_PAYLOAD_OBJECT_ABI = 0x474C_544B_0000_0001
EXECUTION_PLAN_OBJECT_ABI = 0x474D_504C_0000_0001
EXECUTION_RESIDENCY_OBJECT_ABI = 0x474D_5242_0000_0001
SUCCESSOR_SEGMENT_OBJECT_ABI = 0x474C_5454_0000_0001
MODEL_ARTIFACT_MAGIC = b"GMART1\x00\x00"
MODEL_ARTIFACT_ABI = 0x474D_4146_0000_0001
MODEL_ARTIFACT_BYTES = 320
MODEL_ARTIFACT_BODY_BYTES = 288
MODEL_ARTIFACT_DOMAIN = b"glacier-model-artifact-manifest-v1\x00"
MODEL_EXECUTION_PLAN_MAGIC = b"GMPLAN1\x00"
MODEL_EXECUTION_PLAN_BYTES = 768
MODEL_EXECUTION_PLAN_BODY_BYTES = 736
MODEL_EXECUTION_PLAN_DOMAIN = b"glacier-model-execution-plan-v1\x00"
MODEL_RESIDENCY_MAGIC = b"GMRBND1\x00"
MODEL_RESIDENCY_BYTES = 256
MODEL_RESIDENCY_BODY_BYTES = 224
MODEL_RESIDENCY_DOMAIN = b"glacier-model-execution-residency-binding-v1\x00"
SUCCESSOR_SEGMENT_MAGIC = b"GLTSEG01"
SUCCESSOR_SEGMENT_BYTES = 512
SUCCESSOR_SEGMENT_BODY_BYTES = 480
SUCCESSOR_SEGMENT_DOMAIN = (
    b"glacier-prepared-text-successor-transcript-segment-v1\x00"
)


class CampaignError(RuntimeError):
    """The worker protocol, durable wire, or recovery invariant failed."""


@dataclass(frozen=True)
class SinkWireFacts:
    generation: int
    count: int
    initial_sequence: int
    next_sequence: int
    request_epoch: int
    request_sha256: str
    sink_implementation_sha256: str
    sink_instance_sha256: str
    previous_selector_sha256: str
    ledger_sha256: str
    selector_sha256: str
    acknowledgement_tokens: tuple[int, ...]


@dataclass(frozen=True)
class CheckpointObject:
    kind: int
    ordinal: int
    abi_version: int
    payload: bytes
    object_sha256: bytes


@dataclass(frozen=True)
class CheckpointWireFacts:
    generation: int
    request_epoch: int
    next_sequence: int
    parent_checkpoint_sha256: str
    checkpoint_sha256: str
    challenge_sha256: str
    previous_selector_sha256: str
    selector_sha256: str
    objects: tuple[CheckpointObject, ...]
    terminal_tokens: tuple[int, ...] | None


@dataclass(frozen=True)
class SourceContractFacts:
    encoded: bytes
    contract_sha256: bytes
    prompt_tokens: tuple[int, ...]
    options: tuple[int, int, int]
    scheduling: tuple[int, ...]
    bound_request_epoch: int
    bound_token_domain_sha256: bytes
    bound_token_domain_config_sha256: bytes
    bound_artifact_license_sha256: bytes
    bound_previous_plan_sha256: bytes
    source_runtime: tuple[int, int, int]
    request_epoch: int
    publication_next_sequence: int
    challenge_sha256: bytes
    plan_sha256: bytes
    bound_plan_sha256: bytes
    prompt_sha256: bytes
    artifact_sha256: bytes
    execution_plan_sha256: bytes
    residency_binding_sha256: bytes
    target_wire: bytes
    target_values: tuple[int, ...]
    target_ownership_sha256: bytes
    sink_storage_epoch: int
    sink_capacity: int
    sink_initial_sequence: int
    sink_implementation_sha256: bytes
    sink_instance_sha256: bytes
    sink_empty_ledger_sha256: bytes
    sink_empty_selector_sha256: bytes


@dataclass(frozen=True)
class WireFacts:
    sink: SinkWireFacts | None
    checkpoint: CheckpointWireFacts | None
    source_contract: SourceContractFacts | None = None


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CampaignError(message)


def _is_int(value: object) -> bool:
    return type(value) is int


def _required_int(
    frame: Mapping[str, object],
    name: str,
    *,
    minimum: int = 0,
) -> int:
    value = frame.get(name)
    if not _is_int(value):
        raise CampaignError(f"invalid {name}")
    result = cast(int, value)
    _require(result >= minimum, f"invalid {name}")
    return result


def _required_bool(frame: Mapping[str, object], name: str) -> bool:
    value = frame.get(name)
    _require(type(value) is bool, f"invalid {name}")
    return cast(bool, value)


def _is_digest_hex(
    value: object,
    *,
    allow_zero: bool = True,
) -> bool:
    if type(value) is not str or len(value) != 64:
        return False
    if any(character not in "0123456789abcdef" for character in value):
        return False
    return allow_zero or value != "0" * 64


def _required_digest_hex(
    frame: Mapping[str, object],
    name: str,
    *,
    allow_zero: bool = True,
) -> str:
    value = frame.get(name)
    _require(
        _is_digest_hex(value, allow_zero=allow_zero),
        f"invalid {name}",
    )
    return cast(str, value)


def _pairs_without_duplicates(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise CampaignError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> object:
    raise CampaignError(f"non-canonical JSON constant: {value}")


def _decode_canonical_json(line: bytes) -> dict[str, object]:
    _require(0 < len(line) <= MAX_JSON_FRAME_BYTES, "invalid JSON frame size")
    _require(b"\r" not in line, "JSON frame contains carriage return")
    try:
        text = line.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CampaignError("JSON frame is not UTF-8") from error
    try:
        value = json.loads(
            text,
            object_pairs_hook=_pairs_without_duplicates,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        if isinstance(error, CampaignError):
            raise
        raise CampaignError("invalid JSON frame") from error
    _require(type(value) is dict, "JSON frame is not an object")
    canonical = json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
    )
    _require(text == canonical, "JSON frame is not canonical compact JSON")
    return cast(dict[str, object], value)


def _cleanup_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    for stream in (process.stdout, process.stderr):
        if stream is not None:
            stream.close()


def _capture_one_frame(
    command: Sequence[str],
    *,
    timeout_seconds: float,
    validate_frame: Callable[[dict[str, object]], None],
) -> tuple[dict[str, object], int]:
    _require(bool(command), "empty worker command")
    _require(timeout_seconds > 0, "worker timeout must be positive")
    try:
        process = subprocess.Popen(
            tuple(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
    except OSError as error:
        raise CampaignError(f"cannot start worker: {command[0]}") from error
    assert process.stdout is not None
    assert process.stderr is not None

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    stdout_before_frame = bytearray()
    stderr = bytearray()
    frame: dict[str, object] | None = None
    deadline = time.monotonic() + timeout_seconds
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CampaignError("worker timed out")
            events = selector.select(remaining)
            if not events:
                raise CampaignError("worker timed out")
            for key, _ in events:
                chunk = os.read(key.fd, 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stderr":
                    stderr.extend(chunk)
                    _require(
                        len(stderr) <= MAX_STDERR_BYTES,
                        "worker stderr exceeds bound",
                    )
                    continue
                if frame is not None:
                    raise CampaignError("worker emitted trailing stdout")
                stdout_before_frame.extend(chunk)
                _require(
                    len(stdout_before_frame) <= MAX_JSON_FRAME_BYTES + 1,
                    "worker JSON frame exceeds bound",
                )
                newline = stdout_before_frame.find(b"\n")
                if newline < 0:
                    continue
                _require(
                    newline == len(stdout_before_frame) - 1,
                    "worker emitted more than one stdout frame",
                )
                frame = _decode_canonical_json(bytes(stdout_before_frame[:newline]))
                validate_frame(frame)
                stdout_before_frame.clear()

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CampaignError("worker timed out before exit")
        try:
            return_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise CampaignError("worker did not exit after its frame") from error
        if frame is None:
            raise CampaignError("worker exited without a JSON frame")
        _require(not stdout_before_frame, "worker stdout ended mid-frame")
        _require(not stderr, "worker emitted stderr")
        return frame, return_code
    except BaseException:
        _cleanup_process(process)
        raise
    finally:
        selector.close()
        if process.poll() is not None:
            process.stdout.close()
            process.stderr.close()


_READY_KEYS = (
    "schema",
    "phase",
    "pid",
    "crash_point",
    "input_generation",
    "input_sequence",
    "sink_count",
    "sink_ledger_sha256",
    "sink_selector_sha256",
    "checkpoint_selector_sha256",
)


def _validate_ready_frame(
    frame: dict[str, object],
    *,
    expected_crash_point: str,
    expected_generation: int,
    expected_sequence: int,
) -> None:
    _require(tuple(frame) == _READY_KEYS, "crash-ready frame shape changed")
    _require(frame["schema"] == CRASH_READY_SCHEMA, "wrong ready schema")
    _require(frame["phase"] == "crash_ready", "wrong ready phase")
    _required_int(frame, "pid", minimum=1)
    _require(
        frame["crash_point"] == expected_crash_point,
        "worker reached the wrong crash point",
    )
    _require(
        _required_int(frame, "input_generation") == expected_generation,
        "crash-ready input generation changed",
    )
    _require(
        _required_int(frame, "input_sequence") == expected_sequence,
        "crash-ready input sequence changed",
    )
    sink_count = _required_int(frame, "sink_count")
    sink_ledger = _required_digest_hex(frame, "sink_ledger_sha256")
    sink_selector = _required_digest_hex(frame, "sink_selector_sha256")
    checkpoint_selector = _required_digest_hex(
        frame,
        "checkpoint_selector_sha256",
    )
    zero = "0" * 64

    if expected_crash_point in BOOTSTRAP_CHECKPOINT_PHASES:
        _require(
            expected_generation == 0
            and expected_sequence == 0
            and sink_count == 0
            and sink_ledger == zero
            and sink_selector == zero,
            "bootstrap ready frame exposes impossible sink/input state",
        )
        checkpoint_selected = (
            expected_crash_point in BOOTSTRAP_CHECKPOINT_SELECTED_POINTS
        )
        _require(
            (checkpoint_selector != zero) == checkpoint_selected,
            "bootstrap checkpoint visibility changed",
        )
        return

    if expected_crash_point in SOURCE_CRASH_POINTS:
        _require(
            expected_generation == 1
            and expected_sequence == 1
            and sink_count == 0,
            "source-transition ready frame exposes impossible input state",
        )
        sink_selected = expected_crash_point in SOURCE_SINK_SELECTED_POINTS
        _require(
            (sink_ledger != zero) == sink_selected
            and (sink_selector != zero) == sink_selected
            and checkpoint_selector != zero,
            "source-transition selector visibility changed",
        )
        return

    _require(
        expected_generation >= 2 and expected_sequence > 0,
        "target crash input is not a selected source-exit edge",
    )
    expected_sink_count = (
        expected_sequence
        if expected_crash_point in SINK_SUCCESSOR_VISIBLE_POINTS
        else expected_sequence - 1
    )
    _require(
        sink_count == expected_sink_count,
        "target sink visibility changed",
    )
    _require(
        sink_ledger != zero
        and sink_selector != zero
        and checkpoint_selector != zero,
        "target ready frame contains a zero selected root",
    )


def run_crash_worker(
    command: Sequence[str],
    *,
    expected_crash_point: str,
    expected_generation: int,
    expected_sequence: int,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, object]:
    """Run one crash worker and accept only a gated, real SIGKILL death."""

    _require(expected_crash_point in CRASH_POINTS, "unknown crash point")

    def validate(frame: dict[str, object]) -> None:
        _validate_ready_frame(
            frame,
            expected_crash_point=expected_crash_point,
            expected_generation=expected_generation,
            expected_sequence=expected_sequence,
        )

    frame, return_code = _capture_one_frame(
        command,
        timeout_seconds=timeout_seconds,
        validate_frame=validate,
    )
    _require(
        return_code == -signal.SIGKILL,
        "crash worker did not terminate by SIGKILL",
    )
    return frame


_RESULT_REQUIRED_KEYS = frozenset(
    {
        "schema",
        "mode",
        "pid",
        "input_generation",
        "input_sequence",
        "output_generation",
        "output_sequence",
        "sink_disposition",
        "sink_count",
        "sink_next_sequence",
        "sink_ledger_sha256",
        "sink_selector_sha256",
        "checkpoint_selector_sha256",
        "terminal",
        "ownership_zero",
        "verified",
        "output_tokens",
    }
)


def _validate_result_frame(
    frame: dict[str, object],
    *,
    expected_mode: str,
) -> None:
    _require(
        _RESULT_REQUIRED_KEYS.issubset(frame),
        "result frame is missing required fields",
    )
    _require(frame["schema"] == RESULT_SCHEMA, "wrong result schema")
    _require(frame["mode"] == expected_mode, "wrong result mode")
    _required_int(frame, "pid", minimum=1)
    input_generation = _required_int(frame, "input_generation")
    input_sequence = _required_int(frame, "input_sequence")
    output_generation = _required_int(frame, "output_generation")
    output_sequence = _required_int(frame, "output_sequence")
    _require(
        output_generation >= input_generation and output_sequence >= input_sequence,
        "result moved backwards",
    )
    disposition = frame.get("sink_disposition")
    _require(
        disposition in ("none", "applied", "already_applied", "replayed"),
        "invalid sink disposition",
    )
    count = _required_int(frame, "sink_count")
    next_sequence = _required_int(frame, "sink_next_sequence")
    _require(next_sequence >= count, "invalid sink next sequence")
    _required_digest_hex(frame, "sink_ledger_sha256")
    _required_digest_hex(frame, "sink_selector_sha256")
    _required_digest_hex(frame, "checkpoint_selector_sha256")
    terminal = _required_bool(frame, "terminal")
    _require(_required_bool(frame, "ownership_zero"), "worker leaked ownership")
    _require(_required_bool(frame, "verified"), "worker did not verify result")
    raw_tokens = frame.get("output_tokens")
    _require(type(raw_tokens) is list, "invalid output_tokens")
    tokens = cast(list[object], raw_tokens)
    for token in tokens:
        if not _is_int(token):
            raise CampaignError("output token is outside u32")
        token_value = cast(int, token)
        _require(
            0 <= token_value <= (1 << 32) - 1,
            "output token is outside u32",
        )
    if terminal:
        _require(
            output_sequence == TERMINAL_OUTPUT_COUNT
            and len(tokens) == TERMINAL_OUTPUT_COUNT,
            "terminal result is not the four-token state",
        )
    if "terminal_semantic_sha256" in frame:
        value = frame["terminal_semantic_sha256"]
        if terminal:
            _require(
                _is_digest_hex(value, allow_zero=False),
                "terminal result lacks semantic root",
            )
        else:
            _require(
                value is None or _is_digest_hex(value),
                "invalid nonterminal semantic root",
            )


def run_result_worker(
    command: Sequence[str],
    *,
    expected_mode: str,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, object]:
    """Run one normal worker mode and require one canonical successful result."""

    _require(
        expected_mode
        in (
            "baseline",
            "source",
            "source-bootstrap",
            "source-transition",
            "target",
            "audit",
        ),
        "unknown worker mode",
    )

    def validate(frame: dict[str, object]) -> None:
        _validate_result_frame(frame, expected_mode=expected_mode)

    frame, return_code = _capture_one_frame(
        command,
        timeout_seconds=timeout_seconds,
        validate_frame=validate,
    )
    _require(return_code == 0, "normal worker exited unsuccessfully")
    return frame


def _u64(encoded: bytes, offset: int) -> int:
    _require(offset >= 0 and offset + 8 <= len(encoded), "truncated u64")
    return cast(int, struct.unpack_from("<Q", encoded, offset)[0])


def _hash(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def _checked_claim_host_bytes(
    claim: tuple[int, ...],
    *,
    label: str,
) -> int:
    _require(len(claim) == 10, f"{label} claim field count changed")
    total = 0
    for value in claim[:7]:
        _require(
            total <= U64_MAX - value,
            f"{label} host-byte claim overflows u64",
        )
        total += value
    return total


def _validate_acknowledgement_derived_roots(
    acknowledgement: bytes,
) -> None:
    _require(
        len(acknowledgement) == ACK_BYTES,
        "invalid acknowledgement size",
    )
    request_epoch = _u64(acknowledgement, 32)
    transaction_sequence = _u64(acknowledgement, 40)
    token_id = _u64(acknowledgement, 48)
    application_ordinal = _u64(acknowledgement, 56)
    application_count = _u64(acknowledgement, 64)
    request_sha256 = acknowledgement[72:104]
    expected_delivery_key = _hash(
        DELIVERY_KEY_DOMAIN,
        struct.pack("<Q", ACK_ABI)
        + request_sha256
        + struct.pack("<QQ", request_epoch, transaction_sequence),
    )
    _require(
        acknowledgement[264:296] == expected_delivery_key,
        "acknowledgement delivery key mismatch",
    )
    expected_prefix = _hash(
        SINK_PREFIX_DOMAIN,
        struct.pack(
            "<QQQQQQ",
            ACK_ABI,
            request_epoch,
            transaction_sequence,
            token_id,
            application_ordinal,
            application_count,
        )
        + acknowledgement[72:264]
        + expected_delivery_key
        + acknowledgement[296:360],
    )
    _require(
        acknowledgement[360:392] == expected_prefix,
        "acknowledgement sink prefix mismatch",
    )


def _read_regular_file_or_none(
    path: Path,
    *,
    exact_bytes: int | None = None,
    maximum_bytes: int = MAX_ARTIFACT_BYTES,
) -> bytes | None:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise CampaignError(f"cannot open durable artifact: {path.name}") from error
    try:
        metadata = os.fstat(descriptor)
        _require(stat.S_ISREG(metadata.st_mode), f"{path.name} is not regular")
        _require(metadata.st_nlink == 1, f"{path.name} has multiple links")
        _require(
            0 < metadata.st_size <= maximum_bytes,
            f"{path.name} size is invalid",
        )
        if exact_bytes is not None:
            _require(
                metadata.st_size == exact_bytes,
                f"{path.name} has the wrong size",
            )
        chunks: list[bytes] = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            _require(bool(chunk), f"{path.name} was truncated")
            chunks.append(chunk)
            remaining -= len(chunk)
        _require(not os.read(descriptor, 1), f"{path.name} grew while reading")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _read_regular_file(
    path: Path,
    *,
    exact_bytes: int | None = None,
    maximum_bytes: int = MAX_ARTIFACT_BYTES,
) -> bytes:
    encoded = _read_regular_file_or_none(
        path,
        exact_bytes=exact_bytes,
        maximum_bytes=maximum_bytes,
    )
    if encoded is None:
        raise CampaignError(f"cannot open durable artifact: {path.name}")
    return encoded


def _decode_sink_wire(directory: Path) -> SinkWireFacts | None:
    selector = _read_regular_file_or_none(
        directory / SINK_ACTIVE_SELECTOR_NAME,
        exact_bytes=SINK_SELECTOR_BYTES,
    )
    if selector is None:
        return None
    _require(selector[:8] == SINK_SELECTOR_MAGIC, "invalid sink selector magic")
    _require(_u64(selector, 8) == SINK_SELECTOR_ABI, "invalid sink selector ABI")
    _require(
        _u64(selector, 16) == SINK_SELECTOR_BYTES and _u64(selector, 24) == 0,
        "invalid sink selector header",
    )
    generation = _u64(selector, 32)
    count = _u64(selector, 40)
    initial_sequence = _u64(selector, 48)
    next_sequence = _u64(selector, 56)
    request_epoch = _u64(selector, 64)
    ledger_bytes = _u64(selector, 72)
    request_sha256 = selector[80:112]
    sink_implementation_sha256 = selector[112:144]
    sink_instance_sha256 = selector[144:176]
    previous_selector_sha256 = selector[176:208]
    ledger_sha256 = selector[208:240]
    selector_sha256 = selector[240:272]
    _require(
        selector_sha256 == _hash(SINK_SELECTOR_DOMAIN, selector[:240]),
        "sink selector root mismatch",
    )
    _require(
        generation == count + 1
        and next_sequence == initial_sequence + count
        and ledger_bytes
        == SINK_LEDGER_HEADER_BYTES + count * ACK_BYTES + SINK_LEDGER_FOOTER_BYTES
        and request_epoch > 0,
        "invalid sink selector sequence",
    )
    _require(
        request_sha256 != ZERO_DIGEST
        and sink_implementation_sha256 != ZERO_DIGEST
        and sink_instance_sha256 != ZERO_DIGEST
        and ledger_sha256 != ZERO_DIGEST,
        "zero sink selector identity",
    )
    _require(
        (generation == 1 and previous_selector_sha256 == ZERO_DIGEST)
        or (generation > 1 and previous_selector_sha256 != ZERO_DIGEST),
        "invalid sink selector lineage",
    )

    ledger_name = "prepared-text-result-ledger-" + ledger_sha256.hex() + ".bin"
    ledger = _read_regular_file(
        directory / ledger_name,
        exact_bytes=ledger_bytes,
    )
    _require(ledger[:8] == SINK_LEDGER_MAGIC, "invalid sink ledger magic")
    _require(_u64(ledger, 8) == SINK_LEDGER_ABI, "invalid sink ledger ABI")
    _require(
        _u64(ledger, 16) == SINK_LEDGER_HEADER_BYTES
        and _u64(ledger, 24) == ACK_BYTES
        and _u64(ledger, 32) == len(ledger)
        and _u64(ledger, 40) == count
        and _u64(ledger, 48) == initial_sequence
        and _u64(ledger, 56) == next_sequence
        and _u64(ledger, 64) == request_epoch
        and _u64(ledger, 72) == 0
        and ledger[80:112] == request_sha256
        and ledger[112:144] == sink_implementation_sha256
        and ledger[144:176] == sink_instance_sha256
        and ledger[240:256] == bytes(16),
        "sink ledger does not match selector",
    )
    _require(
        ledger[-32:] == ledger_sha256
        and ledger_sha256 == _hash(SINK_LEDGER_DOMAIN, ledger[:-32]),
        "sink ledger root mismatch",
    )

    previous_ack = ZERO_DIGEST
    previous_prefix = ZERO_DIGEST
    tokens: list[int] = []
    for index in range(count):
        offset = SINK_LEDGER_HEADER_BYTES + index * ACK_BYTES
        acknowledgement = ledger[offset : offset + ACK_BYTES]
        _require(
            len(acknowledgement) == ACK_BYTES
            and acknowledgement[:8] == ACK_MAGIC
            and _u64(acknowledgement, 8) == ACK_ABI
            and _u64(acknowledgement, 16) == ACK_BYTES
            and _u64(acknowledgement, 24) == 0,
            "invalid acknowledgement header",
        )
        token = _u64(acknowledgement, 48)
        _require(token <= (1 << 32) - 1, "acknowledgement token exceeds u32")
        _require(
            _u64(acknowledgement, 32) == request_epoch
            and _u64(acknowledgement, 40) == initial_sequence + index
            and _u64(acknowledgement, 56) == index + 1
            and _u64(acknowledgement, 64) == 1
            and acknowledgement[72:104] == request_sha256
            and acknowledgement[200:232] == sink_implementation_sha256
            and acknowledgement[232:264] == sink_instance_sha256
            and acknowledgement[296:328] == previous_ack
            and acknowledgement[328:360] == previous_prefix,
            "acknowledgement sequence or lineage mismatch",
        )
        _validate_acknowledgement_derived_roots(acknowledgement)
        acknowledgement_root = acknowledgement[392:424]
        _require(
            acknowledgement_root == _hash(ACK_DOMAIN, acknowledgement[:392]),
            "acknowledgement root mismatch",
        )
        previous_ack = acknowledgement_root
        previous_prefix = acknowledgement[360:392]
        _require(previous_prefix != ZERO_DIGEST, "zero sink prefix")
        tokens.append(token)
    _require(
        ledger[176:208] == previous_ack and ledger[208:240] == previous_prefix,
        "sink ledger head mismatch",
    )
    return SinkWireFacts(
        generation=generation,
        count=count,
        initial_sequence=initial_sequence,
        next_sequence=next_sequence,
        request_epoch=request_epoch,
        request_sha256=request_sha256.hex(),
        sink_implementation_sha256=sink_implementation_sha256.hex(),
        sink_instance_sha256=sink_instance_sha256.hex(),
        previous_selector_sha256=previous_selector_sha256.hex(),
        ledger_sha256=ledger_sha256.hex(),
        selector_sha256=selector_sha256.hex(),
        acknowledgement_tokens=tuple(tokens),
    )


def _decode_checkpoint_set(
    checkpoint: bytes,
    *,
    expected_checkpoint_sha256: bytes | None = None,
    selector_sha256: bytes = ZERO_DIGEST,
    previous_selector_sha256: bytes = ZERO_DIGEST,
) -> CheckpointWireFacts:
    _require(
        len(checkpoint)
        >= CHECKPOINT_SET_PAYLOAD_OFFSET + CHECKPOINT_SET_FOOTER_BYTES,
        "checkpoint set is too small",
    )
    _require(
        checkpoint[:8] == CHECKPOINT_SET_MAGIC,
        "invalid checkpoint set magic",
    )
    generation = _u64(checkpoint, 24)
    request_epoch = _u64(checkpoint, 32)
    next_sequence = _u64(checkpoint, 40)
    object_count = _u64(checkpoint, 48)
    parent_checkpoint_sha256 = checkpoint[64:96]
    challenge_sha256 = checkpoint[96:128]
    checkpoint_sha256 = checkpoint[-32:]
    _require(
        _u64(checkpoint, 8) == CHECKPOINT_SET_ABI
        and _u64(checkpoint, 16) == len(checkpoint)
        and generation > 0
        and request_epoch > 0
        and next_sequence > 0
        and _u64(checkpoint, 56) == 0
        and challenge_sha256 != ZERO_DIGEST,
        "invalid checkpoint set header",
    )
    _require(
        (generation == 1 and parent_checkpoint_sha256 == ZERO_DIGEST)
        or (generation > 1 and parent_checkpoint_sha256 != ZERO_DIGEST),
        "invalid checkpoint parent lineage",
    )
    _require(
        1 <= object_count <= CHECKPOINT_SET_MAX_OBJECTS,
        "invalid checkpoint object count",
    )
    _require(
        checkpoint_sha256 != ZERO_DIGEST
        and checkpoint_sha256 == _hash(CHECKPOINT_SET_DOMAIN, checkpoint[:-32])
        and (
            expected_checkpoint_sha256 is None
            or checkpoint_sha256 == expected_checkpoint_sha256
        ),
        "checkpoint set root mismatch",
    )

    cursor = CHECKPOINT_SET_PAYLOAD_OFFSET
    previous_key: tuple[int, int] | None = None
    objects: list[CheckpointObject] = []
    for index in range(object_count):
        entry_offset = CHECKPOINT_SET_HEADER_BYTES + index * CHECKPOINT_SET_ENTRY_BYTES
        kind = _u64(checkpoint, entry_offset)
        ordinal = _u64(checkpoint, entry_offset + 8)
        abi_version = _u64(checkpoint, entry_offset + 16)
        payload_offset = _u64(checkpoint, entry_offset + 24)
        payload_bytes = _u64(checkpoint, entry_offset + 32)
        object_sha256 = checkpoint[entry_offset + 40 : entry_offset + 72]
        _require(
            1 <= kind <= 7
            and abi_version > 0
            and payload_offset == cursor
            and payload_bytes > 0,
            "invalid checkpoint object entry",
        )
        key = (kind, ordinal)
        _require(previous_key is None or previous_key < key, "unordered objects")
        end = cursor + payload_bytes
        _require(
            end <= len(checkpoint) - CHECKPOINT_SET_FOOTER_BYTES,
            "checkpoint object exceeds set",
        )
        payload = checkpoint[cursor:end]
        object_body = (
            struct.pack(
                "<QQQQ",
                kind,
                ordinal,
                abi_version,
                payload_bytes,
            )
            + payload
        )
        _require(
            object_sha256 == _hash(CHECKPOINT_OBJECT_DOMAIN, object_body),
            "checkpoint object root mismatch",
        )
        objects.append(
            CheckpointObject(
                kind=kind,
                ordinal=ordinal,
                abi_version=abi_version,
                payload=payload,
                object_sha256=object_sha256,
            )
        )
        previous_key = key
        cursor = end
    unused_start = (
        CHECKPOINT_SET_HEADER_BYTES + object_count * CHECKPOINT_SET_ENTRY_BYTES
    )
    _require(
        checkpoint[unused_start:CHECKPOINT_SET_PAYLOAD_OFFSET]
        == bytes(CHECKPOINT_SET_PAYLOAD_OFFSET - unused_start)
        and cursor == len(checkpoint) - CHECKPOINT_SET_FOOTER_BYTES,
        "checkpoint directory or payload length is non-canonical",
    )

    terminal_tokens: tuple[int, ...] | None = None
    for terminal_object in objects:
        if (
            terminal_object.kind == 7
            and terminal_object.ordinal == 4
            and terminal_object.abi_version == TERMINAL_OUTPUT_TOKENS_ABI
        ):
            _require(
                len(terminal_object.payload) > 0
                and len(terminal_object.payload) % 4 == 0,
                "invalid terminal output-token object",
            )
            terminal_tokens = tuple(
                struct.unpack(
                    "<" + "I" * (len(terminal_object.payload) // 4),
                    terminal_object.payload,
                )
            )
    return CheckpointWireFacts(
        generation=generation,
        request_epoch=request_epoch,
        next_sequence=next_sequence,
        parent_checkpoint_sha256=parent_checkpoint_sha256.hex(),
        checkpoint_sha256=checkpoint_sha256.hex(),
        challenge_sha256=challenge_sha256.hex(),
        previous_selector_sha256=previous_selector_sha256.hex(),
        selector_sha256=selector_sha256.hex(),
        objects=tuple(objects),
        terminal_tokens=terminal_tokens,
    )


def _decode_checkpoint_wire(directory: Path) -> CheckpointWireFacts | None:
    selector = _read_regular_file_or_none(
        directory / CHECKPOINT_ACTIVE_SELECTOR_NAME,
        exact_bytes=CHECKPOINT_SELECTOR_BYTES,
    )
    if selector is None:
        return None
    _require(
        selector[:8] == CHECKPOINT_SELECTOR_MAGIC,
        "invalid checkpoint selector magic",
    )
    _require(
        _u64(selector, 8) == CHECKPOINT_SELECTOR_ABI,
        "invalid checkpoint selector ABI",
    )
    _require(
        _u64(selector, 16) == CHECKPOINT_SELECTOR_BYTES and _u64(selector, 56) == 0,
        "invalid checkpoint selector header",
    )
    generation = _u64(selector, 24)
    request_epoch = _u64(selector, 32)
    next_sequence = _u64(selector, 40)
    checkpoint_bytes = _u64(selector, 48)
    previous_selector_sha256 = selector[64:96]
    checkpoint_sha256 = selector[96:128]
    challenge_sha256 = selector[128:160]
    selector_sha256 = selector[160:192]
    _require(
        selector_sha256 == _hash(CHECKPOINT_SELECTOR_DOMAIN, selector[:160]),
        "checkpoint selector root mismatch",
    )
    _require(
        generation > 0
        and request_epoch > 0
        and next_sequence > 0
        and checkpoint_bytes
        >= CHECKPOINT_SET_PAYLOAD_OFFSET + CHECKPOINT_SET_FOOTER_BYTES,
        "invalid checkpoint selector sequence",
    )
    _require(
        checkpoint_sha256 != ZERO_DIGEST
        and challenge_sha256 != ZERO_DIGEST
        and (
            (generation == 1 and previous_selector_sha256 == ZERO_DIGEST)
            or (generation > 1 and previous_selector_sha256 != ZERO_DIGEST)
        ),
        "invalid checkpoint selector lineage",
    )
    checkpoint_name = "checkpoint-" + checkpoint_sha256.hex() + ".set"
    checkpoint = _read_regular_file(
        directory / checkpoint_name,
        exact_bytes=checkpoint_bytes,
    )
    decoded = _decode_checkpoint_set(
        checkpoint,
        expected_checkpoint_sha256=checkpoint_sha256,
        selector_sha256=selector_sha256,
        previous_selector_sha256=previous_selector_sha256,
    )
    _require(
        decoded.generation == generation
        and decoded.request_epoch == request_epoch
        and decoded.next_sequence == next_sequence
        and decoded.challenge_sha256 == challenge_sha256.hex(),
        "checkpoint set does not match selector",
    )
    return decoded


def _empty_sink_roots(
    request_sha256: bytes,
    request_epoch: int,
    initial_sequence: int,
    implementation_sha256: bytes,
    instance_sha256: bytes,
) -> tuple[bytes, bytes]:
    ledger = bytearray(SINK_LEDGER_HEADER_BYTES + SINK_LEDGER_FOOTER_BYTES)
    ledger[:8] = SINK_LEDGER_MAGIC
    struct.pack_into("<Q", ledger, 8, SINK_LEDGER_ABI)
    struct.pack_into("<Q", ledger, 16, SINK_LEDGER_HEADER_BYTES)
    struct.pack_into("<Q", ledger, 24, ACK_BYTES)
    struct.pack_into("<Q", ledger, 32, len(ledger))
    struct.pack_into("<Q", ledger, 40, 0)
    struct.pack_into("<Q", ledger, 48, initial_sequence)
    struct.pack_into("<Q", ledger, 56, initial_sequence)
    struct.pack_into("<Q", ledger, 64, request_epoch)
    struct.pack_into("<Q", ledger, 72, 0)
    ledger[80:112] = request_sha256
    ledger[112:144] = implementation_sha256
    ledger[144:176] = instance_sha256
    ledger_root = _hash(SINK_LEDGER_DOMAIN, bytes(ledger[:-32]))
    ledger[-32:] = ledger_root

    selector = bytearray(SINK_SELECTOR_BYTES)
    selector[:8] = SINK_SELECTOR_MAGIC
    struct.pack_into("<Q", selector, 8, SINK_SELECTOR_ABI)
    struct.pack_into("<Q", selector, 16, SINK_SELECTOR_BYTES)
    struct.pack_into("<Q", selector, 24, 0)
    struct.pack_into("<Q", selector, 32, 1)
    struct.pack_into("<Q", selector, 40, 0)
    struct.pack_into("<Q", selector, 48, initial_sequence)
    struct.pack_into("<Q", selector, 56, initial_sequence)
    struct.pack_into("<Q", selector, 64, request_epoch)
    struct.pack_into("<Q", selector, 72, len(ledger))
    selector[80:112] = request_sha256
    selector[112:144] = implementation_sha256
    selector[144:176] = instance_sha256
    selector[208:240] = ledger_root
    selector_root = _hash(SINK_SELECTOR_DOMAIN, bytes(selector[:240]))
    selector[240:272] = selector_root
    return ledger_root, selector_root


def _decode_source_replay_contract(encoded: bytes) -> SourceContractFacts:
    _require(
        len(encoded)
        >= SOURCE_REPLAY_PROMPT_OFFSET + SOURCE_REPLAY_FOOTER_BYTES,
        "source replay contract is too small",
    )
    prompt_count = _u64(encoded, 48)
    prompt_bytes = _u64(encoded, 56)
    _require(
        encoded[:8] == SOURCE_REPLAY_CONTRACT_MAGIC
        and _u64(encoded, 8) == SOURCE_REPLAY_CONTRACT_ABI
        and _u64(encoded, 16) == len(encoded)
        and _u64(encoded, 24) == 0
        and _u64(encoded, 32) == SOURCE_REPLAY_HEADER_BYTES
        and _u64(encoded, 40) == SOURCE_REPLAY_FIXED_PAYLOAD_BYTES
        and prompt_count > 0
        and prompt_bytes == prompt_count * 4
        and len(encoded)
        == SOURCE_REPLAY_PROMPT_OFFSET
        + prompt_bytes
        + SOURCE_REPLAY_FOOTER_BYTES
        and encoded[64:SOURCE_REPLAY_HEADER_BYTES]
        == bytes(SOURCE_REPLAY_HEADER_BYTES - 64),
        "invalid source replay contract header",
    )
    body = encoded[:-SOURCE_REPLAY_FOOTER_BYTES]
    contract_sha256 = _hash(SOURCE_REPLAY_DOMAIN, body)
    _require(
        encoded[-SOURCE_REPLAY_FOOTER_BYTES:] == contract_sha256,
        "source replay contract root mismatch",
    )

    max_new_tokens = _u64(encoded, 128)
    eos_token = _u64(encoded, 136)
    seed = _u64(encoded, 144)
    scheduling = tuple(_u64(encoded, 152 + index * 8) for index in range(6))
    bound_request_epoch = _u64(encoded, 200)
    bound_token_domain_sha256 = encoded[208:240]
    bound_token_domain_config_sha256 = encoded[240:272]
    bound_artifact_license_sha256 = encoded[272:304]
    bound_previous_plan_sha256 = encoded[304:336]
    source_runtime = (
        _u64(encoded, 336),
        _u64(encoded, 344),
        _u64(encoded, 352),
    )
    request_epoch = _u64(encoded, 360)
    publication_next_sequence = _u64(encoded, 368)
    challenge_sha256 = encoded[376:408]
    bindings = tuple(encoded[408 + index * 32 : 440 + index * 32] for index in range(6))
    target_wire = encoded[600:776]
    target_values = tuple(_u64(target_wire, index * 8) for index in range(22))
    target_ownership_sha256 = encoded[776:808]
    sink_storage_epoch = _u64(encoded, 808)
    sink_capacity = _u64(encoded, 816)
    sink_initial_sequence = _u64(encoded, 824)
    sink_implementation_sha256 = encoded[832:864]
    sink_instance_sha256 = encoded[864:896]
    sink_empty_ledger_sha256 = encoded[896:928]
    sink_empty_selector_sha256 = encoded[928:960]
    prompt_wire = encoded[
        SOURCE_REPLAY_PROMPT_OFFSET : -SOURCE_REPLAY_FOOTER_BYTES
    ]
    prompt_tokens = tuple(
        struct.unpack("<" + "I" * prompt_count, prompt_wire)
    )

    _require(
        max_new_tokens > publication_next_sequence > 0
        and eos_token <= (1 << 32) - 1
        and all(value > 0 for value in scheduling[:5])
        and scheduling[4] <= (1 << 16) - 1
        and all(value > 0 for value in source_runtime)
        and request_epoch > 0
        and bound_request_epoch == request_epoch
        and challenge_sha256 != ZERO_DIGEST
        and all(value != ZERO_DIGEST for value in bindings)
        and all(
            value != ZERO_DIGEST
            for value in (
                bound_token_domain_sha256,
                bound_token_domain_config_sha256,
                bound_artifact_license_sha256,
            )
        ),
        "invalid source replay request identity",
    )
    expected_prompt_sha256 = _hash(
        SOURCE_PROMPT_DOMAIN,
        struct.pack("<Q", prompt_count) + prompt_wire,
    )
    _require(
        bindings[2] == expected_prompt_sha256,
        "source replay prompt root mismatch",
    )
    _require(
        all(value > 0 for value in target_values[:12])
        and target_values[3] == scheduling[2] + 1
        and target_values[11] == target_values[3]
        and target_values[2] != source_runtime[2]
        and target_values[4] != scheduling[3]
        and any(value > 0 for value in target_values[12:]),
        "invalid source replay target identity",
    )
    target_claim = target_values[12:]
    _checked_claim_host_bytes(
        target_claim,
        label="source replay target",
    )
    _require(
        max_new_tokens <= U64_MAX // 4
        and target_claim[5] == max_new_tokens * 4
        and target_claim[9] == 1,
        "invalid source replay target claim",
    )
    expected_target_root = _hash(
        SOURCE_TARGET_DOMAIN,
        struct.pack(
            "<QQQ",
            SOURCE_REPLAY_CONTRACT_ABI,
            SOURCE_OWNERSHIP_INTENT_ABI,
            RESOURCE_BANK_ABI,
        )
        + target_wire,
    )
    _require(
        target_ownership_sha256 == expected_target_root,
        "source replay target root mismatch",
    )
    _require(
        sink_storage_epoch > 0
        and sink_capacity == max_new_tokens - publication_next_sequence
        and sink_initial_sequence == publication_next_sequence
        and sink_implementation_sha256 != ZERO_DIGEST
        and sink_instance_sha256 != ZERO_DIGEST,
        "invalid source replay sink shape",
    )
    expected_ledger, expected_selector = _empty_sink_roots(
        bindings[0],
        request_epoch,
        sink_initial_sequence,
        sink_implementation_sha256,
        sink_instance_sha256,
    )
    _require(
        sink_empty_ledger_sha256 == expected_ledger
        and sink_empty_selector_sha256 == expected_selector,
        "source replay empty sink roots mismatch",
    )
    return SourceContractFacts(
        encoded=encoded,
        contract_sha256=contract_sha256,
        prompt_tokens=prompt_tokens,
        options=(max_new_tokens, eos_token, seed),
        scheduling=scheduling,
        bound_request_epoch=bound_request_epoch,
        bound_token_domain_sha256=bound_token_domain_sha256,
        bound_token_domain_config_sha256=bound_token_domain_config_sha256,
        bound_artifact_license_sha256=bound_artifact_license_sha256,
        bound_previous_plan_sha256=bound_previous_plan_sha256,
        source_runtime=source_runtime,
        request_epoch=request_epoch,
        publication_next_sequence=publication_next_sequence,
        challenge_sha256=challenge_sha256,
        plan_sha256=bindings[0],
        bound_plan_sha256=bindings[1],
        prompt_sha256=bindings[2],
        artifact_sha256=bindings[3],
        execution_plan_sha256=bindings[4],
        residency_binding_sha256=bindings[5],
        target_wire=target_wire,
        target_values=target_values,
        target_ownership_sha256=target_ownership_sha256,
        sink_storage_epoch=sink_storage_epoch,
        sink_capacity=sink_capacity,
        sink_initial_sequence=sink_initial_sequence,
        sink_implementation_sha256=sink_implementation_sha256,
        sink_instance_sha256=sink_instance_sha256,
        sink_empty_ledger_sha256=sink_empty_ledger_sha256,
        sink_empty_selector_sha256=sink_empty_selector_sha256,
    )


def _validate_fixed_rooted_wire(
    encoded: bytes,
    *,
    magic: bytes,
    abi: int,
    total_bytes: int,
    body_bytes: int,
    domain: bytes,
    label: str,
) -> bytes:
    _require(
        len(encoded) == total_bytes
        and encoded[:8] == magic
        and _u64(encoded, 8) == abi
        and _u64(encoded, 16) == total_bytes
        and _u64(encoded, 24) == 0,
        f"invalid {label} header",
    )
    root = _hash(domain, encoded[:body_bytes])
    _require(
        root != ZERO_DIGEST and encoded[body_bytes:] == root,
        f"{label} root mismatch",
    )
    return root


def _source_ownership_root(contract: SourceContractFacts) -> bytes:
    scheduling = contract.scheduling
    source_runtime = contract.source_runtime
    _require(
        len(scheduling) == 6 and len(source_runtime) == 3,
        "invalid source ownership inputs",
    )
    return _hash(
        SOURCE_OWNERSHIP_DOMAIN,
        struct.pack(
            "<" + "Q" * 9,
            contract.request_epoch,
            source_runtime[0],
            source_runtime[2],
            *scheduling,
        ),
    )


def _validate_source_execution_bindings(
    execution: bytes,
    contract: SourceContractFacts,
) -> None:
    _require(
        len(execution) == MODEL_EXECUTION_PLAN_BYTES
        and _u64(execution, 72) == contract.request_epoch
        and _u64(execution, 80) == contract.scheduling[2]
        and _u64(execution, 144) == 0
        and execution[320:352] == contract.prompt_sha256
        and execution[352:384]
        == contract.bound_token_domain_sha256
        and execution[384:416]
        == contract.bound_token_domain_config_sha256
        and execution[512:544] == contract.challenge_sha256
        and execution[544:576] == contract.bound_previous_plan_sha256,
        "source execution context differs from source contract",
    )
    _require(
        execution[480:512] == _source_ownership_root(contract),
        "source execution ownership differs from source contract",
    )


def _decode_restart_plan(
    plan: bytes,
    contract: SourceContractFacts,
) -> tuple[bytes, tuple[int, ...]]:
    claim = tuple(_u64(plan, 176 + index * 8) for index in range(10))
    _checked_claim_host_bytes(claim, label="restart plan")
    _require(
        len(plan) == 288
        and _u64(plan, 0) == PREPARED_TEXT_PLAN_ABI
        and plan[8:40] != ZERO_DIGEST
        and plan[40:72] != ZERO_DIGEST
        and _u64(plan, 72) > 0
        and plan[80:112] != ZERO_DIGEST
        and _u64(plan, 112) == len(contract.prompt_tokens)
        and plan[120:152] == contract.prompt_sha256
        and _u64(plan, 152) == contract.options[0]
        and struct.unpack_from("<I", plan, 160)[0] == contract.options[1]
        and plan[164:168] == bytes(4)
        and _u64(plan, 168) == contract.options[2]
        and contract.options[0] <= U64_MAX // 4
        and claim[5] == contract.options[0] * 4
        and claim[9] == 1
        and claim == contract.target_values[12:],
        "invalid restart manifest plan",
    )
    plan_root = _hash(
        RESTART_PLAN_DOMAIN,
        plan[:164] + plan[168:256],
    )
    _require(
        plan[256:288] == plan_root == contract.plan_sha256,
        "restart manifest plan root mismatch",
    )
    return plan_root, claim


def _validate_restart_execution_context(
    plan: bytes,
    execution: bytes,
    execution_root: bytes,
    residency: bytes,
    plan_claim: tuple[int, ...],
) -> None:
    execution_claim = tuple(
        _u64(execution, 176 + index * 8) for index in range(10)
    )
    residency_claim = tuple(
        _u64(residency, 144 + index * 8) for index in range(10)
    )
    _checked_claim_host_bytes(
        execution_claim,
        label="source execution",
    )
    _checked_claim_host_bytes(
        residency_claim,
        label="source execution residency",
    )
    resident_weight_bytes = _u64(residency, 40)
    _require(
        _u64(residency, 32) == 2
        and resident_weight_bytes > 0
        and resident_weight_bytes == _u64(execution, 160)
        and resident_weight_bytes == _u64(plan, 72)
        and residency[48:80] == execution[256:288]
        and residency[80:112] == execution[288:320]
        and residency[112:144] == execution_root
        and residency_claim == plan_claim
        and plan_claim[0] <= U64_MAX - resident_weight_bytes
        and execution_claim
        == (
            plan_claim[0] + resident_weight_bytes,
            *plan_claim[1:],
        )
        and _u64(execution, 128) == residency_claim[3],
        "restart manifest execution residency differs from plan",
    )


def _validate_prepared_bound_profile(
    plan: bytes,
    artifact: bytes,
    execution: bytes,
    contract: SourceContractFacts,
) -> None:
    prompt_bytes = len(contract.prompt_tokens) * 4
    output_bytes = contract.options[0] * 4
    execution_claim = tuple(
        _u64(execution, 176 + index * 8) for index in range(10)
    )
    _require(
        (_u64(artifact, 32), _u64(execution, 32)) == (1, 1)
        and _u64(artifact, 40)
        == PREPARED_TEXT_ARTIFACT_PROFILE_ABI
        and (_u64(artifact, 48), _u64(execution, 48)) == (1, 1)
        and (_u64(artifact, 56), _u64(execution, 56)) == (11, 11)
        and (_u64(artifact, 64), _u64(execution, 64)) == (4, 4)
        and _u64(artifact, 72) == 1
        and _u64(execution, 40) == 13
        and _u64(execution, 88) == 1
        and _u64(execution, 136) == 0
        and _u64(execution, 152) > 0
        and _u64(execution, 152) < contract.options[1]
        and _u64(artifact, 96) == _u64(artifact, 104)
        and _u64(artifact, 208) == 1
        and (_u64(artifact, 216), _u64(execution, 640)) == (4, 4)
        and (_u64(artifact, 224), _u64(execution, 648)) == (4, 4)
        and _u64(execution, 112) == prompt_bytes
        and _u64(execution, 120) == output_bytes
        and execution_claim[0] >= _u64(execution, 160)
        and execution_claim[2] >= prompt_bytes
        and execution_claim[3] >= _u64(execution, 128)
        and execution_claim[5] >= output_bytes
        and artifact[144:176] != ZERO_DIGEST
        and execution[416:448] != ZERO_DIGEST
        and execution[448:480] != ZERO_DIGEST
        and execution[576:608] != ZERO_DIGEST
        and execution[608:640] != ZERO_DIGEST
        and artifact[232:288] == bytes(56)
        and _u64(execution, 168) == 0
        and execution[656:736] == bytes(80),
        "restart manifest prepared execution profile mismatch",
    )


def _validate_restart_expected_source_context(
    expected: bytes,
    source: bytes,
    execution: bytes,
    plan_claim: tuple[int, ...],
    contract: SourceContractFacts,
) -> None:
    _require(
        len(expected) == 376
        and len(source) == 448
        and len(execution) == MODEL_EXECUTION_PLAN_BYTES
        and len(plan_claim) == 10,
        "restart manifest expected/source shape changed",
    )

    request_epoch = _u64(expected, 256)
    publication_next_sequence = _u64(expected, 264)
    prompt_tokens = _u64(expected, 272)
    max_new_tokens = _u64(expected, 280)
    vocab_size = _u64(expected, 288)
    num_layers = _u64(expected, 296)
    kv_dim = _u64(expected, 304)
    max_kv_positions = _u64(expected, 312)
    kv_positions = _u64(expected, 320)
    output_count = _u64(expected, 328)
    sampling_calls = _u64(expected, 336)

    _require(
        expected[0:32] == contract.plan_sha256
        and expected[32:64] == contract.bound_plan_sha256
        and expected[64:96] == contract.artifact_sha256
        and expected[96:128] == contract.execution_plan_sha256
        and expected[128:160] == contract.residency_binding_sha256
        and expected[160:192] == source[32:64]
        and source[32:64] != ZERO_DIGEST
        and expected[192:224] == source[296:328]
        and expected[224:256] == source[264:296]
        and expected[344:376] == contract.challenge_sha256
        and request_epoch == contract.request_epoch
        and publication_next_sequence == contract.publication_next_sequence
        and prompt_tokens == len(contract.prompt_tokens)
        and max_new_tokens == contract.options[0]
        and 2 <= vocab_size <= (1 << 32)
        and num_layers > 0
        and kv_dim > 0
        and output_count > 0
        and output_count < max_new_tokens
        and publication_next_sequence == output_count
        and sampling_calls == output_count
        and contract.options[1] >= vocab_size,
        "restart manifest expected bindings differ from source contract",
    )

    maximum_absolute_output = _u64(execution, 152)
    _require(
        maximum_absolute_output < U64_MAX
        and vocab_size == maximum_absolute_output + 1,
        "restart manifest expected vocabulary binding mismatch",
    )
    _require(
        prompt_tokens <= U64_MAX - (output_count - 1)
        and prompt_tokens <= U64_MAX - (max_new_tokens - 1),
        "restart manifest expected KV position overflows u64",
    )
    calculated_kv_positions = prompt_tokens + output_count - 1
    calculated_max_kv_positions = prompt_tokens + max_new_tokens - 1
    _require(
        kv_positions == calculated_kv_positions
        and max_kv_positions == calculated_max_kv_positions
        and kv_positions <= max_kv_positions,
        "restart manifest expected KV position mismatch",
    )
    _require(
        num_layers <= U64_MAX // 2,
        "restart manifest expected KV extent overflows u64",
    )
    layer_sides = num_layers * 2
    _require(
        layer_sides <= U64_MAX // kv_positions,
        "restart manifest expected KV extent overflows u64",
    )
    positioned_sides = layer_sides * kv_positions
    _require(
        positioned_sides <= U64_MAX // kv_dim,
        "restart manifest expected KV extent overflows u64",
    )

    state = source[120:296]
    source_receipt = source[328:448]
    source_receipt_values = tuple(
        _u64(source_receipt, index * 8) for index in range(15)
    )
    source_receipt_claim = source_receipt_values[4:14]
    _checked_claim_host_bytes(
        source_receipt_claim,
        label="restart source receipt",
    )
    _require(
        source[0:32] == contract.bound_plan_sha256
        and _u64(source, 64) == LANE_TRANSCRIPT_SNAPSHOT_ABI
        and _u64(source, 72) == request_epoch
        and _u64(source, 80) == LANE_CONTIGUOUS_EXECUTION_ABI
        and _u64(source, 88) == _u64(execution, 144)
        and _u64(source, 88) <= _u64(source, 96)
        and _u64(source, 96) != U64_MAX
        and _u64(source, 96) == publication_next_sequence
        and _u64(source, 104) > 0
        and _u64(source, 112) == 0
        and _u64(state, 0) == LANE_STATE_COMMITMENT_ABI
        and _u64(state, 8) == LANE_CONTIGUOUS_EXECUTION_ABI
        and _u64(state, 8) == _u64(source, 80)
        and _u64(state, 16) == kv_positions
        and state[24:56] != ZERO_DIGEST
        and _u64(state, 56) == LANE_CONTIGUOUS_RNG_STATE_ABI
        and state[64:96] != ZERO_DIGEST
        and _u64(state, 96) == sampling_calls
        and _u64(state, 104) == output_count
        and _u64(state, 104) == _u64(source, 96)
        and state[112:144] != ZERO_DIGEST
        and state[144:176]
        == _hash(LANE_STATE_COMMITMENT_DOMAIN, state[:144])
        and source[296:328] != ZERO_DIGEST
        and _u64(execution, 72) == request_epoch
        and _u64(execution, 144) < publication_next_sequence,
        "restart manifest source context mismatch",
    )
    _require(
        source_receipt_values[0] == contract.source_runtime[2]
        and source_receipt_values[1] <= (1 << 32) - 1
        and source_receipt_values[2] > 0
        and source_receipt_values[3] == contract.scheduling[3]
        and source_receipt_claim == plan_claim
        and source_receipt_claim[9] == 1
        and source_receipt_values[14] > 0
        and source_receipt_values[14]
        == _resource_receipt_integrity(source_receipt_values),
        "invalid restart manifest source receipt",
    )


def _decode_restart_manifest(
    encoded: bytes,
    contract: SourceContractFacts,
) -> tuple[bytes, bytes, bytes]:
    _require(
        len(encoded)
        >= RESTART_MANIFEST_PROMPT_OFFSET + SOURCE_REPLAY_FOOTER_BYTES,
        "restart manifest is too small",
    )
    prompt_count = _u64(encoded, 48)
    prompt_bytes = _u64(encoded, 56)
    _require(
        encoded[:8] == RESTART_MANIFEST_MAGIC
        and _u64(encoded, 8) == RESTART_MANIFEST_ABI
        and _u64(encoded, 16) == len(encoded)
        and _u64(encoded, 24) == 0
        and _u64(encoded, 32) == RESTART_MANIFEST_HEADER_BYTES
        and _u64(encoded, 40) == RESTART_MANIFEST_FIXED_PAYLOAD_BYTES
        and prompt_count == len(contract.prompt_tokens)
        and prompt_bytes == prompt_count * 4
        and _u64(encoded, 64) == MODEL_ARTIFACT_BYTES
        and _u64(encoded, 72) == MODEL_EXECUTION_PLAN_BYTES
        and _u64(encoded, 80) == MODEL_RESIDENCY_BYTES
        and _u64(encoded, 88) == 0
        and len(encoded)
        == RESTART_MANIFEST_PROMPT_OFFSET
        + prompt_bytes
        + SOURCE_REPLAY_FOOTER_BYTES,
        "invalid restart manifest header",
    )
    _require(
        encoded[-32:] == _hash(RESTART_MANIFEST_DOMAIN, encoded[:-32]),
        "restart manifest root mismatch",
    )
    _require(
        (
            _u64(encoded, 96),
            struct.unpack_from("<I", encoded, 104)[0],
            _u64(encoded, 112),
        )
        == contract.options
        and encoded[108:112] == bytes(4),
        "restart manifest options differ from source contract",
    )

    plan = encoded[RESTART_PLAN_OFFSET:RESTART_BOUND_PLAN_OFFSET]
    plan_root, plan_claim = _decode_restart_plan(plan, contract)

    bound = encoded[RESTART_BOUND_PLAN_OFFSET:576]
    _require(
        len(bound) == 168
        and _u64(bound, 0) == PREPARED_TEXT_BOUND_PLAN_ABI
        and bound[8:40] == contract.plan_sha256
        and bound[40:72] == contract.bound_token_domain_sha256
        and bound[72:104] == contract.bound_token_domain_config_sha256
        and bound[104:136] == contract.bound_artifact_license_sha256
        and bound[136:168] == contract.bound_plan_sha256,
        "restart manifest bound plan mismatch",
    )

    artifact = encoded[576:RESTART_EXECUTION_OFFSET]
    artifact_root = _validate_fixed_rooted_wire(
        artifact,
        magic=MODEL_ARTIFACT_MAGIC,
        abi=MODEL_ARTIFACT_ABI,
        total_bytes=MODEL_ARTIFACT_BYTES,
        body_bytes=MODEL_ARTIFACT_BODY_BYTES,
        domain=MODEL_ARTIFACT_DOMAIN,
        label="model artifact",
    )
    execution = encoded[RESTART_EXECUTION_OFFSET:RESTART_RESIDENCY_OFFSET]
    execution_root = _validate_fixed_rooted_wire(
        execution,
        magic=MODEL_EXECUTION_PLAN_MAGIC,
        abi=EXECUTION_PLAN_OBJECT_ABI,
        total_bytes=MODEL_EXECUTION_PLAN_BYTES,
        body_bytes=MODEL_EXECUTION_PLAN_BODY_BYTES,
        domain=MODEL_EXECUTION_PLAN_DOMAIN,
        label="execution plan",
    )
    _validate_source_execution_bindings(execution, contract)
    residency = encoded[
        RESTART_RESIDENCY_OFFSET:RESTART_EXPECTED_BINDINGS_OFFSET
    ]
    residency_root = _validate_fixed_rooted_wire(
        residency,
        magic=MODEL_RESIDENCY_MAGIC,
        abi=EXECUTION_RESIDENCY_OBJECT_ABI,
        total_bytes=MODEL_RESIDENCY_BYTES,
        body_bytes=MODEL_RESIDENCY_BODY_BYTES,
        domain=MODEL_RESIDENCY_DOMAIN,
        label="execution residency",
    )
    canonical_bound_plan_root = _hash(
        RESTART_BOUND_PLAN_DOMAIN,
        struct.pack("<Q", PREPARED_TEXT_BOUND_PLAN_ABI)
        + plan_root
        + artifact_root
        + execution_root
        + residency_root
        + contract.bound_token_domain_sha256
        + contract.bound_token_domain_config_sha256
        + contract.bound_artifact_license_sha256,
    )
    _require(
        _u64(artifact, 80) == len(contract.prompt_tokens)
        and _u64(artifact, 88) == contract.options[0]
        and _u64(artifact, 104) == _u64(plan, 72)
        and artifact[112:144] == plan[80:112]
        and artifact[176:208]
        == contract.bound_artifact_license_sha256
        and execution[256:288] == artifact_root
        and execution[288:320] == artifact[112:144]
        and _u64(execution, 96) == _u64(artifact, 80)
        and _u64(execution, 104) == _u64(artifact, 88)
        and _u64(execution, 160) == _u64(artifact, 104)
        and execution[352:384]
        == contract.bound_token_domain_sha256
        and execution[384:416]
        == contract.bound_token_domain_config_sha256
        and contract.bound_plan_sha256 == canonical_bound_plan_root,
        "restart manifest canonical bound plan context mismatch",
    )
    _validate_restart_execution_context(
        plan,
        execution,
        execution_root,
        residency,
        plan_claim,
    )
    _validate_prepared_bound_profile(
        plan,
        artifact,
        execution,
        contract,
    )
    _require(
        artifact_root == contract.artifact_sha256
        and execution_root == contract.execution_plan_sha256
        and residency_root == contract.residency_binding_sha256,
        "restart manifest model roots differ from source contract",
    )

    expected = encoded[
        RESTART_EXPECTED_BINDINGS_OFFSET:2296
    ]
    source = encoded[2296:RESTART_TARGET_OFFSET]
    _validate_restart_expected_source_context(
        expected,
        source,
        execution,
        plan_claim,
        contract,
    )
    source_receipt = source[328:448]
    _require(
        encoded[RESTART_TARGET_OFFSET:RESTART_MANIFEST_PROMPT_OFFSET]
        == contract.target_wire,
        "restart manifest target differs from source contract",
    )
    prompt_wire = encoded[RESTART_MANIFEST_PROMPT_OFFSET:-32]
    _require(
        prompt_wire
        == contract.encoded[
            SOURCE_REPLAY_PROMPT_OFFSET:-SOURCE_REPLAY_FOOTER_BYTES
        ],
        "restart manifest prompt differs from source contract",
    )
    return execution, residency, source_receipt


def _initial_checkpoint_selector_root(
    checkpoint: CheckpointWireFacts,
    checkpoint_bytes: int,
) -> bytes:
    selector = bytearray(CHECKPOINT_SELECTOR_BYTES)
    selector[:8] = CHECKPOINT_SELECTOR_MAGIC
    struct.pack_into("<Q", selector, 8, CHECKPOINT_SELECTOR_ABI)
    struct.pack_into("<Q", selector, 16, CHECKPOINT_SELECTOR_BYTES)
    struct.pack_into("<Q", selector, 24, checkpoint.generation)
    struct.pack_into("<Q", selector, 32, checkpoint.request_epoch)
    struct.pack_into("<Q", selector, 40, checkpoint.next_sequence)
    struct.pack_into("<Q", selector, 48, checkpoint_bytes)
    struct.pack_into("<Q", selector, 56, 0)
    selector[96:128] = bytes.fromhex(checkpoint.checkpoint_sha256)
    selector[128:160] = bytes.fromhex(checkpoint.challenge_sha256)
    return _hash(CHECKPOINT_SELECTOR_DOMAIN, bytes(selector[:160]))


def _decode_source_generation_one(
    checkpoint: CheckpointWireFacts,
) -> SourceContractFacts:
    _require(
        checkpoint.generation == 1
        and checkpoint.parent_checkpoint_sha256 == "0" * 64
        and len(checkpoint.objects) == 2,
        "invalid generation-one source checkpoint",
    )
    marker, contract_object = checkpoint.objects
    _require(
        (marker.kind, marker.ordinal, marker.abi_version)
        == (7, 0, SOURCE_LIVE_MARKER_ABI)
        and marker.payload == SOURCE_LIVE_MARKER
        and (
            contract_object.kind,
            contract_object.ordinal,
            contract_object.abi_version,
        )
        == (7, 1, SOURCE_REPLAY_CONTRACT_ABI),
        "generation-one source objects changed",
    )
    contract = _decode_source_replay_contract(contract_object.payload)
    _require(
        checkpoint.request_epoch == contract.request_epoch
        and checkpoint.next_sequence == contract.publication_next_sequence
        and checkpoint.challenge_sha256 == contract.challenge_sha256.hex(),
        "generation-one source metadata differs from replay contract",
    )
    return contract


def _mix64(value: int) -> int:
    mixed = value & U64_MAX
    mixed ^= mixed >> 30
    mixed = (mixed * 0xBF58_476D_1CE4_E5B9) & U64_MAX
    mixed ^= mixed >> 27
    mixed = (mixed * 0x94D0_49BB_1331_11EB) & U64_MAX
    mixed ^= mixed >> 31
    return mixed


def _resource_receipt_integrity(receipt: tuple[int, ...]) -> int:
    _require(len(receipt) == 15, "source receipt field count changed")
    result = _mix64(
        RESOURCE_RECEIPT_INTEGRITY_DOMAIN ^ receipt[0]
    )
    for value in receipt[1:14]:
        result = _mix64(result ^ value)
    return result


def _canonical_resource_receipt_wire(
    receipt: tuple[int, ...],
) -> bytes:
    _require(
        len(receipt) == 15 and receipt[1] <= (1 << 32) - 1,
        "invalid source receipt slot",
    )
    return (
        struct.pack(
            "<QIQQ",
            receipt[0],
            receipt[1],
            receipt[2],
            receipt[3],
        )
        + struct.pack("<" + "Q" * 10, *receipt[4:14])
        + struct.pack("<Q", receipt[14])
    )


def _source_exit_semantic_root(encoded: bytes) -> bytes:
    identities = tuple(
        _u64(encoded, 32 + index * 8) for index in range(12)
    )
    receipt = tuple(
        _u64(encoded, 128 + index * 8) for index in range(15)
    )
    canonical_receipt = _canonical_resource_receipt_wire(receipt)
    semantic_body = (
        struct.pack(
            "<" + "Q" * 4,
            SOURCE_EXIT_RECEIPT_ABI,
            identities[0],
            identities[1],
            identities[2],
        )
        + struct.pack(
            "<QIQQQQ",
            identities[3],
            identities[4],
            identities[5],
            identities[6],
            identities[7],
            identities[8],
        )
        + struct.pack(
            "<QQQ",
            identities[9],
            identities[10],
            identities[11],
        )
        + canonical_receipt
        + encoded[256:480]
        + struct.pack("<Q", _u64(encoded, 248))
        + encoded[480:512]
    )
    return _hash(SOURCE_EXIT_RECEIPT_DOMAIN, semantic_body)


def _validate_source_exit_semantics(encoded: bytes) -> None:
    identities = tuple(
        _u64(encoded, 32 + index * 8) for index in range(12)
    )
    receipt = tuple(
        _u64(encoded, 128 + index * 8) for index in range(15)
    )
    receipt_claim = receipt[4:14]
    _checked_claim_host_bytes(
        receipt_claim,
        label="source receipt",
    )
    _require(
        all(
            value > 0
            for index, value in enumerate(identities)
            if index != 4
        )
        and identities[3] == identities[0]
        and identities[4] <= (1 << 32) - 1
        and identities[11] != U64_MAX
        and receipt[0] > 0
        and receipt[1] <= (1 << 32) - 1
        and receipt[2] > 0
        and receipt[3] > 0
        and receipt[14] > 0
        and receipt_claim[9] == 1
        and identities[4] == receipt[1]
        and identities[5] == receipt[2]
        and receipt[14] == _resource_receipt_integrity(receipt),
        "invalid structural source-exit receipt",
    )
    _require(
        _u64(encoded, 248) > 0
        and all(
            encoded[offset : offset + 32] != ZERO_DIGEST
            for offset in range(256, 544, 32)
        ),
        "zero structural source-exit evidence",
    )
    canonical_receipt = _canonical_resource_receipt_wire(receipt)
    expected_receipt_sha256 = _hash(
        RESOURCE_RECEIPT_DOMAIN,
        canonical_receipt,
    )
    _require(
        encoded[256:288] == expected_receipt_sha256,
        "source receipt root mismatch",
    )
    _require(
        encoded[512:544]
        == _source_exit_semantic_root(encoded),
        "source-exit semantic root mismatch",
    )


def _validate_source_exit(
    encoded: bytes,
    *,
    contract: SourceContractFacts,
    nested: CheckpointWireFacts,
    nested_checkpoint_payload: bytes,
    nested_segment: bytes,
    source_receipt: bytes,
    predecessor_selector_sha256: bytes,
) -> None:
    _require(
        len(encoded) == SOURCE_EXIT_WIRE_BYTES
        and encoded[:8] == SOURCE_EXIT_WIRE_MAGIC
        and _u64(encoded, 8) == SOURCE_EXIT_WIRE_ABI
        and _u64(encoded, 16) == SOURCE_EXIT_WIRE_BYTES
        and _u64(encoded, 24) == 0
        and encoded[SOURCE_EXIT_WIRE_BODY_BYTES:]
        == _hash(SOURCE_EXIT_WIRE_DOMAIN, encoded[:SOURCE_EXIT_WIRE_BODY_BYTES])
        and encoded[544:SOURCE_EXIT_WIRE_BODY_BYTES]
        == bytes(SOURCE_EXIT_WIRE_BODY_BYTES - 544),
        "invalid source-exit wire",
    )
    _validate_source_exit_semantics(encoded)
    identities = tuple(_u64(encoded, 32 + index * 8) for index in range(12))
    _require(
        all(value > 0 for index, value in enumerate(identities) if index != 4)
        and identities[0] == contract.source_runtime[0]
        and identities[1] == contract.source_runtime[1]
        and identities[3] == identities[0]
        and identities[6] == contract.scheduling[0]
        and identities[7] == contract.scheduling[1]
        and identities[8] == contract.scheduling[2]
        and identities[9] == contract.request_epoch
        and identities[10] == contract.publication_next_sequence,
        "source-exit identity differs from source contract",
    )
    receipt = encoded[128:248]
    _require(
        receipt == source_receipt
        and _u64(receipt, 0) == contract.source_runtime[2]
        and _u64(receipt, 8) <= (1 << 32) - 1
        and _u64(receipt, 16) > 0
        and _u64(receipt, 24) == contract.scheduling[3]
        and _u64(receipt, 112) > 0,
        "source-exit receipt differs from restart manifest",
    )
    digests = tuple(encoded[256 + index * 32 : 288 + index * 32] for index in range(9))
    _require(
        all(value != ZERO_DIGEST for value in digests)
        and len(nested_checkpoint_payload) > 32
        and digests[2] == nested_checkpoint_payload[-32:]
        and digests[3] == nested_segment[-32:]
        and digests[4] == nested_segment[416:448]
        and digests[5] == bytes.fromhex(nested.checkpoint_sha256)
        and digests[6] == predecessor_selector_sha256,
        "source-exit evidence bindings mismatch",
    )


def _decode_source_generation_two(
    directory: Path,
    checkpoint: CheckpointWireFacts,
) -> SourceContractFacts:
    _require(
        checkpoint.generation == 2
        and len(checkpoint.objects) == 3
        and checkpoint.parent_checkpoint_sha256 != "0" * 64,
        "invalid generation-two source checkpoint",
    )
    exit_object, evidence_object, contract_object = checkpoint.objects
    _require(
        (exit_object.kind, exit_object.ordinal, exit_object.abi_version)
        == (6, 0, SOURCE_EXIT_WIRE_ABI)
        and (
            evidence_object.kind,
            evidence_object.ordinal,
            evidence_object.abi_version,
        )
        == (7, 0, EVIDENCE_ARCHIVE_OBJECT_ABI)
        and (
            contract_object.kind,
            contract_object.ordinal,
            contract_object.abi_version,
        )
        == (7, 1, SOURCE_REPLAY_CONTRACT_ABI),
        "generation-two source objects changed",
    )
    contract = _decode_source_replay_contract(contract_object.payload)
    _require(
        checkpoint.request_epoch == contract.request_epoch
        and checkpoint.next_sequence == contract.publication_next_sequence
        and checkpoint.challenge_sha256 == contract.challenge_sha256.hex(),
        "generation-two source metadata differs from replay contract",
    )

    retained_name = (
        "checkpoint-" + checkpoint.parent_checkpoint_sha256 + ".set"
    )
    retained_encoded = _read_regular_file(directory / retained_name)
    retained = _decode_checkpoint_set(
        retained_encoded,
        expected_checkpoint_sha256=bytes.fromhex(
            checkpoint.parent_checkpoint_sha256
        ),
    )
    retained_contract = _decode_source_generation_one(retained)
    _require(
        retained_contract.encoded == contract.encoded,
        "generation-two replay contract differs from retained parent",
    )
    predecessor_selector = _initial_checkpoint_selector_root(
        retained,
        len(retained_encoded),
    )
    _require(
        checkpoint.previous_selector_sha256 == predecessor_selector.hex(),
        "generation-two selector does not retain generation one",
    )

    nested = _decode_checkpoint_set(evidence_object.payload)
    _require(
        nested.generation == 1
        and nested.parent_checkpoint_sha256 == "0" * 64
        and nested.request_epoch == contract.request_epoch
        and nested.next_sequence == contract.publication_next_sequence
        and nested.challenge_sha256 == contract.challenge_sha256.hex()
        and len(nested.objects) == 5,
        "invalid nested restart evidence archive",
    )
    expected_objects = (
        (7, 0, CHECKPOINT_PAYLOAD_OBJECT_ABI),
        (7, 1, EXECUTION_PLAN_OBJECT_ABI),
        (7, 2, EXECUTION_RESIDENCY_OBJECT_ABI),
        (7, 3, SUCCESSOR_SEGMENT_OBJECT_ABI),
        (7, 4, RESTART_MANIFEST_ABI),
    )
    _require(
        tuple(
            (item.kind, item.ordinal, item.abi_version)
            for item in nested.objects
        )
        == expected_objects,
        "nested restart evidence object matrix changed",
    )
    manifest = nested.objects[4].payload
    source_execution, source_residency, source_receipt = _decode_restart_manifest(
        manifest,
        contract,
    )
    successor_execution = nested.objects[1].payload
    successor_execution_root = _validate_fixed_rooted_wire(
        successor_execution,
        magic=MODEL_EXECUTION_PLAN_MAGIC,
        abi=EXECUTION_PLAN_OBJECT_ABI,
        total_bytes=MODEL_EXECUTION_PLAN_BYTES,
        body_bytes=MODEL_EXECUTION_PLAN_BODY_BYTES,
        domain=MODEL_EXECUTION_PLAN_DOMAIN,
        label="successor execution plan",
    )
    successor_residency = nested.objects[2].payload
    successor_residency_root = _validate_fixed_rooted_wire(
        successor_residency,
        magic=MODEL_RESIDENCY_MAGIC,
        abi=EXECUTION_RESIDENCY_OBJECT_ABI,
        total_bytes=MODEL_RESIDENCY_BYTES,
        body_bytes=MODEL_RESIDENCY_BODY_BYTES,
        domain=MODEL_RESIDENCY_DOMAIN,
        label="successor execution residency",
    )
    segment = nested.objects[3].payload
    _require(
        len(segment) == SUCCESSOR_SEGMENT_BYTES
        and segment[:8] == SUCCESSOR_SEGMENT_MAGIC
        and _u64(segment, 8) == SUCCESSOR_SEGMENT_OBJECT_ABI
        and _u64(segment, 16) == 0
        and segment[-32:]
        == _hash(SUCCESSOR_SEGMENT_DOMAIN, segment[:SUCCESSOR_SEGMENT_BODY_BYTES])
        and _u64(segment, 24) == contract.request_epoch
        and _u64(segment, 32) == contract.publication_next_sequence
        and _u64(segment, 40) == contract.options[0]
        and _u64(segment, 48)
        == contract.options[0] - contract.publication_next_sequence
        and _u64(segment, 56) == _u64(manifest, 2400)
        and _u64(segment, 64)
        == len(contract.prompt_tokens)
        + contract.publication_next_sequence
        - 1
        and _u64(segment, 72) == contract.publication_next_sequence
        and _u64(segment, 80) == contract.publication_next_sequence
        and _u64(segment, 88) == _u64(source_execution, 80)
        and _u64(segment, 96) == _u64(source_execution, 80) + 1
        and _u64(segment, 104) == _u64(segment, 96)
        and _u64(segment, 112) == _u64(manifest, 2376)
        and _u64(segment, 120) == _u64(manifest, 2472)
        and segment[128:160] == nested.objects[0].payload[-32:]
        and segment[160:192] == contract.bound_plan_sha256
        and segment[192:224] == contract.execution_plan_sha256
        and segment[224:256] == manifest[2080:2112]
        and segment[256:288] == manifest[2112:2144]
        and segment[288:320] == manifest[2144:2176]
        and segment[320:352] != ZERO_DIGEST
        and segment[352:384] == successor_execution_root
        and segment[384:416] == successor_residency_root
        and segment[416:448] != ZERO_DIGEST
        and segment[448:480] == contract.challenge_sha256,
        "invalid nested successor segment",
    )
    expected_successor_execution = bytearray(source_execution)
    struct.pack_into(
        "<Q",
        expected_successor_execution,
        80,
        _u64(segment, 96),
    )
    struct.pack_into(
        "<Q",
        expected_successor_execution,
        144,
        contract.publication_next_sequence,
    )
    expected_successor_execution[448:480] = segment[320:352]
    expected_successor_execution[480:512] = segment[416:448]
    expected_successor_execution[512:544] = contract.challenge_sha256
    expected_successor_execution[544:576] = contract.execution_plan_sha256
    expected_successor_execution[
        MODEL_EXECUTION_PLAN_BODY_BYTES:
    ] = successor_execution_root
    _require(
        bytes(expected_successor_execution) == successor_execution,
        "successor execution plan is not the exact source derivation",
    )
    expected_successor_residency = bytearray(source_residency)
    expected_successor_residency[112:144] = successor_execution_root
    expected_successor_residency[MODEL_RESIDENCY_BODY_BYTES:] = (
        successor_residency_root
    )
    _require(
        bytes(expected_successor_residency) == successor_residency,
        "successor residency is not the exact source derivation",
    )
    _validate_source_exit(
        exit_object.payload,
        contract=contract,
        nested=nested,
        nested_checkpoint_payload=nested.objects[0].payload,
        nested_segment=segment,
        source_receipt=source_receipt,
        predecessor_selector_sha256=predecessor_selector,
    )
    return contract


def _require_one_ahead_sink_parent(
    sink: SinkWireFacts,
    contract: SourceContractFacts,
) -> None:
    _require(
        sink.generation == 2
        and sink.count == 1
        and sink.initial_sequence == contract.sink_initial_sequence
        and sink.next_sequence == contract.sink_initial_sequence + 1
        and sink.request_epoch == contract.request_epoch
        and sink.request_sha256 == contract.plan_sha256.hex()
        and sink.sink_implementation_sha256
        == contract.sink_implementation_sha256.hex()
        and sink.sink_instance_sha256
        == contract.sink_instance_sha256.hex()
        and sink.previous_selector_sha256
        == contract.sink_empty_selector_sha256.hex(),
        "one-ahead sink identity or source-empty lineage mismatch",
    )


def audit_wire_state(
    directory: Path,
    *,
    require_terminal: bool,
    permit_sink_ahead: bool = False,
    expected_sink_state: str = "selected",
    expected_checkpoint_state: str = "selected",
) -> WireFacts:
    """Independently verify the selected sink/checkpoint roots and sequences."""

    _require(
        expected_sink_state in ("absent", "empty", "selected"),
        "invalid expected sink state",
    )
    _require(
        expected_checkpoint_state
        in ("absent", "source-live", "source-exited", "selected"),
        "invalid expected checkpoint state",
    )
    sink = _decode_sink_wire(directory)
    checkpoint = _decode_checkpoint_wire(directory)
    _require(
        (sink is None) == (expected_sink_state == "absent"),
        "sink active-selector presence changed",
    )
    _require(
        (checkpoint is None) == (expected_checkpoint_state == "absent"),
        "checkpoint active-selector presence changed",
    )
    source_contract: SourceContractFacts | None = None
    if checkpoint is not None:
        if checkpoint.generation == 1:
            source_contract = _decode_source_generation_one(checkpoint)
        elif checkpoint.generation == 2:
            source_contract = _decode_source_generation_two(
                directory,
                checkpoint,
            )
    if expected_checkpoint_state == "source-live":
        _require(
            checkpoint is not None and checkpoint.generation == 1,
            "checkpoint is not the generation-one source-live state",
        )
    elif expected_checkpoint_state == "source-exited":
        _require(
            checkpoint is not None and checkpoint.generation == 2,
            "checkpoint is not the generation-two source-exited state",
        )
    if expected_sink_state == "empty":
        _require(
            sink is not None and sink.count == 0,
            "sink is not the exact empty selection",
        )
        if sink is not None and source_contract is not None:
            _require(
                sink.generation == 1
                and sink.initial_sequence
                == source_contract.sink_initial_sequence
                and sink.next_sequence
                == source_contract.sink_initial_sequence
                and sink.ledger_sha256
                == source_contract.sink_empty_ledger_sha256.hex()
                and sink.selector_sha256
                == source_contract.sink_empty_selector_sha256.hex(),
                "selected empty sink differs from source replay contract",
            )
    _require(
        not (sink is None and checkpoint is not None and checkpoint.generation >= 2),
        "generation two cannot be selected without its exact replay-capable sink state",
    )
    if sink is not None and checkpoint is not None and permit_sink_ahead:
        _require(
            checkpoint.next_sequence
            <= sink.next_sequence
            <= checkpoint.next_sequence + 1,
            "sink is not aligned with or one step ahead of checkpoint",
        )
        if checkpoint.generation == 2 and sink.count == 1:
            _require(
                source_contract is not None,
                "one-ahead source sink lacks replay contract",
            )
            if source_contract is None:
                raise CampaignError("one-ahead source sink lacks contract")
            _require_one_ahead_sink_parent(
                sink,
                source_contract,
            )
    elif sink is not None and checkpoint is not None:
        _require(
            sink.next_sequence == checkpoint.next_sequence,
            "sink/checkpoint next sequence mismatch",
        )
    if require_terminal:
        _require(
            sink is not None and checkpoint is not None,
            "terminal state lacks a selected sink or checkpoint",
        )
        if sink is None or checkpoint is None:
            raise CampaignError("terminal state lacks durable selection")
        terminal_tokens = checkpoint.terminal_tokens
        _require(
            sink.initial_sequence == 1
            and sink.count == TERMINAL_OUTPUT_COUNT - 1
            and sink.next_sequence == TERMINAL_OUTPUT_COUNT,
            "sink is not at the three-result acknowledged suffix",
        )
        _require(
            terminal_tokens is not None
            and len(terminal_tokens) == TERMINAL_OUTPUT_COUNT,
            "checkpoint lacks the four-token terminal object",
        )
        if terminal_tokens is None:
            raise CampaignError("checkpoint lacks terminal tokens")
        _require(
            sink.acknowledgement_tokens == terminal_tokens[sink.initial_sequence :],
            "terminal output suffix differs from acknowledged sink results",
        )
    elif checkpoint is not None:
        _require(
            checkpoint.terminal_tokens is None,
            "source unexpectedly selected terminal progress",
        )
    return WireFacts(
        sink=sink,
        checkpoint=checkpoint,
        source_contract=source_contract,
    )


def _require_frame_matches_wire(
    frame: Mapping[str, object],
    wire: WireFacts,
) -> None:
    checkpoint = wire.checkpoint
    _require(
        checkpoint is not None,
        "worker result lacks a selected checkpoint",
    )
    if checkpoint is None:
        raise CampaignError("worker result lacks a selected checkpoint")
    sink = wire.sink
    if sink is None:
        _require(
            frame["sink_count"] == 0
            and frame["sink_next_sequence"] == 0
            and frame["sink_ledger_sha256"] == "0" * 64
            and frame["sink_selector_sha256"] == "0" * 64
            and frame["checkpoint_selector_sha256"]
            == checkpoint.selector_sha256
            and frame["output_generation"] == checkpoint.generation
            and frame["output_sequence"] == checkpoint.next_sequence
            and frame["output_tokens"] == [],
            "worker bootstrap result does not match durable state",
        )
        return
    _require(
        frame["sink_count"] == sink.count
        and frame["sink_next_sequence"] == sink.next_sequence
        and frame["sink_ledger_sha256"] == sink.ledger_sha256
        and frame["sink_selector_sha256"] == sink.selector_sha256
        and frame["checkpoint_selector_sha256"] == checkpoint.selector_sha256
        and frame["output_generation"] == checkpoint.generation
        and frame["output_sequence"] == checkpoint.next_sequence,
        "worker result does not match independently decoded durable state",
    )
    raw_tokens = frame["output_tokens"]
    assert isinstance(raw_tokens, list)
    tokens = cast(list[int], raw_tokens)
    _require(
        len(tokens) == checkpoint.next_sequence
        and sink.initial_sequence <= sink.next_sequence
        and sink.next_sequence <= len(tokens)
        and tuple(tokens[sink.initial_sequence : sink.next_sequence])
        == sink.acknowledgement_tokens,
        "worker output does not contain the acknowledged sink suffix",
    )
    if checkpoint.terminal_tokens is not None:
        _require(
            tuple(tokens) == checkpoint.terminal_tokens,
            "worker output differs from checkpoint terminal output",
        )


def _require_ready_matches_wire(
    frame: Mapping[str, object],
    wire: WireFacts,
) -> None:
    sink = wire.sink
    checkpoint = wire.checkpoint
    sink_count = 0 if sink is None else sink.count
    sink_ledger = "0" * 64 if sink is None else sink.ledger_sha256
    sink_selector = "0" * 64 if sink is None else sink.selector_sha256
    checkpoint_selector = (
        "0" * 64 if checkpoint is None else checkpoint.selector_sha256
    )
    _require(
        frame["sink_count"] == sink_count
        and frame["sink_ledger_sha256"] == sink_ledger
        and frame["sink_selector_sha256"] == sink_selector
        and frame["checkpoint_selector_sha256"] == checkpoint_selector,
        "crash-ready frame does not match post-death durable state",
    )


def _worker_command(
    worker: Path,
    mode: str,
    directory: Path,
    crash_point: str | None = None,
) -> tuple[str, ...]:
    command = [str(worker), mode, str(directory)]
    if crash_point is not None:
        command.append(crash_point)
    return tuple(command)


def _fresh_directory(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=False)
    except FileExistsError as error:
        raise CampaignError(f"campaign directory already exists: {path}") from error


def _prepare_campaign_root(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=False)
        return
    except FileExistsError:
        pass
    try:
        metadata = path.lstat()
        _require(
            stat.S_ISDIR(metadata.st_mode) and not path.is_symlink(),
            "campaign root is not a real directory",
        )
        _require(not any(path.iterdir()), "campaign root is not empty")
    except OSError as error:
        raise CampaignError("cannot inspect campaign root") from error


def _write_new_regular_file(path: Path, encoded: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise CampaignError(f"cannot create fixture: {path.name}") from error
    try:
        cursor = 0
        while cursor < len(encoded):
            written = os.write(descriptor, encoded[cursor:])
            _require(written > 0, f"short fixture write: {path.name}")
            cursor += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _copy_baseline_fixtures(source: Path, destination: Path) -> None:
    for name in BASELINE_FIXTURE_NAMES:
        encoded = _read_regular_file(
            source / name,
            maximum_bytes=MAX_FIXTURE_BYTES,
        )
        _write_new_regular_file(destination / name, encoded)


def _record_distinct_pid(
    frame: Mapping[str, object],
    seen: set[int],
    role: str,
) -> int:
    pid = _required_int(frame, "pid", minimum=1)
    _require(pid not in seen, f"worker PID was reused by {role}")
    seen.add(pid)
    return pid


def run_campaign(
    worker: Path,
    directory: Path,
    *,
    crash_points: Sequence[str] = CRASH_POINTS,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    max_recovery_processes: int = DEFAULT_MAX_RECOVERY_PROCESSES,
) -> dict[str, object]:
    """Run baseline plus one isolated real-death recovery case per crash point."""

    selected_crash_points = tuple(crash_points)
    _require(
        bool(selected_crash_points)
        and len(set(crash_points)) == len(crash_points)
        and all(point in CRASH_POINTS for point in crash_points),
        "invalid campaign crash-point selection",
    )
    _require(max_recovery_processes > 0, "invalid recovery process bound")
    _require(os.access(worker, os.X_OK), "worker is not executable")
    worker_image = _read_regular_file(
        worker,
        maximum_bytes=MAX_FIXTURE_BYTES,
    )
    worker_sha256 = hashlib.sha256(worker_image).hexdigest()
    _prepare_campaign_root(directory)
    seen_pids: set[int] = set()

    baseline_directory = directory / "baseline"
    _fresh_directory(baseline_directory)
    baseline = run_result_worker(
        _worker_command(worker, "baseline", baseline_directory),
        expected_mode="baseline",
        timeout_seconds=timeout_seconds,
    )
    _record_distinct_pid(baseline, seen_pids, "baseline")
    _require(bool(baseline["terminal"]), "baseline did not reach terminal")
    baseline_tokens = tuple(cast(list[int], baseline["output_tokens"]))
    baseline_semantic = baseline.get("terminal_semantic_sha256")
    _require(
        len(baseline_tokens) == TERMINAL_OUTPUT_COUNT,
        "baseline did not produce the four-token terminal output",
    )

    case_summaries: list[dict[str, object]] = []
    cases_directory = directory / "cases"
    _fresh_directory(cases_directory)
    for ordinal, crash_point in enumerate(selected_crash_points):
        case_directory = cases_directory / f"{ordinal:02d}-{crash_point}"
        _fresh_directory(case_directory)
        _copy_baseline_fixtures(baseline_directory, case_directory)

        setup_pids: list[int] = []

        def run_bootstrap(role: str) -> tuple[dict[str, object], WireFacts]:
            result = run_result_worker(
                _worker_command(worker, "source-bootstrap", case_directory),
                expected_mode="source-bootstrap",
                timeout_seconds=timeout_seconds,
            )
            setup_pids.append(
                _record_distinct_pid(result, seen_pids, role)
            )
            wire = audit_wire_state(
                case_directory,
                require_terminal=False,
                expected_sink_state="absent",
                expected_checkpoint_state="source-live",
            )
            _require_frame_matches_wire(result, wire)
            checkpoint = wire.checkpoint
            _require(
                not bool(result["terminal"])
                and result["input_generation"] == 0
                and result["input_sequence"] == 0
                and result["output_generation"] == 1
                and result["output_sequence"] == 1
                and checkpoint is not None
                and checkpoint.generation == 1
                and checkpoint.next_sequence == 1
                and wire.source_contract is not None,
                "source-bootstrap did not establish exact generation one",
            )
            return result, wire

        def run_source_transition(
            role: str,
        ) -> tuple[dict[str, object], WireFacts]:
            result = run_result_worker(
                _worker_command(worker, "source-transition", case_directory),
                expected_mode="source-transition",
                timeout_seconds=timeout_seconds,
            )
            setup_pids.append(
                _record_distinct_pid(result, seen_pids, role)
            )
            wire = audit_wire_state(
                case_directory,
                require_terminal=False,
                expected_sink_state="empty",
                expected_checkpoint_state="source-exited",
            )
            _require_frame_matches_wire(result, wire)
            sink = wire.sink
            checkpoint = wire.checkpoint
            _require(
                not bool(result["terminal"])
                and result["input_generation"] == 1
                and result["input_sequence"] == 1
                and result["output_generation"] == 2
                and result["output_sequence"] == 1
                and tuple(cast(list[int], result["output_tokens"]))
                == baseline_tokens[:1]
                and sink is not None
                and sink.generation == 1
                and sink.count == 0
                and sink.initial_sequence == 1
                and sink.next_sequence == 1
                and checkpoint is not None
                and checkpoint.generation == 2
                and checkpoint.next_sequence == 1
                and wire.source_contract is not None,
                "source-transition did not establish exact generation two",
            )
            return result, wire

        victim_mode: str
        selected_generation: int
        selected_sequence: int
        ready: dict[str, object]
        post_crash_wire: WireFacts
        sink_visibility: str
        checkpoint_visibility: str

        if crash_point in BOOTSTRAP_CHECKPOINT_PHASES:
            victim_mode = "source-bootstrap"
            selected_generation = 0
            selected_sequence = 0
            ready = run_crash_worker(
                _worker_command(
                    worker,
                    victim_mode,
                    case_directory,
                    crash_point,
                ),
                expected_crash_point=crash_point,
                expected_generation=selected_generation,
                expected_sequence=selected_sequence,
                timeout_seconds=timeout_seconds,
            )
            _record_distinct_pid(
                ready,
                seen_pids,
                f"{crash_point}:victim",
            )
            checkpoint_selected = (
                crash_point in BOOTSTRAP_CHECKPOINT_SELECTED_POINTS
            )
            post_crash_wire = audit_wire_state(
                case_directory,
                require_terminal=False,
                expected_sink_state="absent",
                expected_checkpoint_state=(
                    "source-live" if checkpoint_selected else "absent"
                ),
            )
            _require_ready_matches_wire(ready, post_crash_wire)
            sink_visibility = "absent"
            checkpoint_visibility = (
                "source-live" if checkpoint_selected else "absent"
            )
            run_bootstrap(f"{crash_point}:bootstrap-recovery")
            _, source_wire = run_source_transition(
                f"{crash_point}:source-transition"
            )
        elif crash_point in SOURCE_CRASH_POINTS:
            victim_mode = "source-transition"
            run_bootstrap(f"{crash_point}:bootstrap")
            selected_generation = 1
            selected_sequence = 1
            ready = run_crash_worker(
                _worker_command(
                    worker,
                    victim_mode,
                    case_directory,
                    crash_point,
                ),
                expected_crash_point=crash_point,
                expected_generation=selected_generation,
                expected_sequence=selected_sequence,
                timeout_seconds=timeout_seconds,
            )
            _record_distinct_pid(
                ready,
                seen_pids,
                f"{crash_point}:victim",
            )
            sink_selected = crash_point in SOURCE_SINK_SELECTED_POINTS
            checkpoint_generation_two = (
                crash_point in SOURCE_CHECKPOINT_GENERATION_TWO_POINTS
            )
            post_crash_wire = audit_wire_state(
                case_directory,
                require_terminal=False,
                expected_sink_state=(
                    "empty" if sink_selected else "absent"
                ),
                expected_checkpoint_state=(
                    "source-exited"
                    if checkpoint_generation_two
                    else "source-live"
                ),
            )
            _require_ready_matches_wire(ready, post_crash_wire)
            sink_visibility = "empty" if sink_selected else "absent"
            checkpoint_visibility = (
                "source-exited"
                if checkpoint_generation_two
                else "source-live"
            )
            _, source_wire = run_source_transition(
                f"{crash_point}:source-recovery"
            )
        else:
            victim_mode = "target"
            run_bootstrap(f"{crash_point}:bootstrap")
            _, source_wire = run_source_transition(
                f"{crash_point}:source-transition"
            )
            selected_generation = 2
            selected_sequence = 1
            ready = run_crash_worker(
                _worker_command(
                    worker,
                    victim_mode,
                    case_directory,
                    crash_point,
                ),
                expected_crash_point=crash_point,
                expected_generation=selected_generation,
                expected_sequence=selected_sequence,
                timeout_seconds=timeout_seconds,
            )
            _record_distinct_pid(
                ready,
                seen_pids,
                f"{crash_point}:victim",
            )
            post_crash_wire = audit_wire_state(
                case_directory,
                require_terminal=False,
                permit_sink_ahead=True,
                expected_sink_state="selected",
                expected_checkpoint_state="selected",
            )
            _require_ready_matches_wire(ready, post_crash_wire)
            post_sink = post_crash_wire.sink
            post_checkpoint = post_crash_wire.checkpoint
            if post_sink is None or post_checkpoint is None:
                raise CampaignError("target crash lost selected durable state")
            expected_sink_successor = (
                crash_point in SINK_SUCCESSOR_VISIBLE_POINTS
            )
            expected_checkpoint_successor = (
                crash_point in CHECKPOINT_SUCCESSOR_VISIBLE_POINTS
            )
            _require(
                post_sink.initial_sequence == 1
                and post_sink.count
                == (1 if expected_sink_successor else 0)
                and post_sink.next_sequence
                == (2 if expected_sink_successor else 1)
                and (
                    post_checkpoint.generation,
                    post_checkpoint.next_sequence,
                )
                == (
                    (3, 2)
                    if expected_checkpoint_successor
                    else (2, 1)
                ),
                "target crash visibility matrix changed",
            )
            sink_visibility = (
                "successor" if expected_sink_successor else "previous"
            )
            checkpoint_visibility = (
                "successor"
                if expected_checkpoint_successor
                else "previous"
            )
            source_wire = post_crash_wire

        source_checkpoint = source_wire.checkpoint
        if source_checkpoint is None:
            raise CampaignError("source recovery lacks generation two")
        last_generation = source_checkpoint.generation
        last_sequence = source_checkpoint.next_sequence
        recovery_count = 0
        recovery_pids: list[int] = []
        terminal_result: dict[str, object] | None = None
        while recovery_count < max_recovery_processes:
            recovered = run_result_worker(
                _worker_command(worker, "target", case_directory),
                expected_mode="target",
                timeout_seconds=timeout_seconds,
            )
            recovery_pids.append(
                _record_distinct_pid(
                    recovered,
                    seen_pids,
                    f"{crash_point}:target-{recovery_count}",
                )
            )
            recovery_count += 1
            input_generation = _required_int(recovered, "input_generation")
            input_sequence = _required_int(recovered, "input_sequence")
            output_generation = _required_int(recovered, "output_generation")
            output_sequence = _required_int(recovered, "output_sequence")
            _require(
                (input_generation, input_sequence)
                == (last_generation, last_sequence)
                and output_generation == input_generation + 1
                and output_sequence == input_sequence + 1,
                "fresh target did not select and commit one contiguous edge",
            )
            last_generation = output_generation
            last_sequence = output_sequence
            current_wire = audit_wire_state(
                case_directory,
                require_terminal=bool(recovered["terminal"]),
                expected_sink_state="selected",
                expected_checkpoint_state="selected",
            )
            _require_frame_matches_wire(recovered, current_wire)
            if recovered["terminal"]:
                terminal_result = recovered
                break
        _require(
            terminal_result is not None
            and last_generation == 5
            and last_sequence == TERMINAL_OUTPUT_COUNT,
            "recovery process bound reached before exact generation-five terminal",
        )

        audit = run_result_worker(
            _worker_command(worker, "audit", case_directory),
            expected_mode="audit",
            timeout_seconds=timeout_seconds,
        )
        audit_pid = _record_distinct_pid(
            audit,
            seen_pids,
            f"{crash_point}:audit",
        )
        _require(bool(audit["terminal"]), "audit did not observe terminal")
        final_wire = audit_wire_state(
            case_directory,
            require_terminal=True,
            expected_sink_state="selected",
            expected_checkpoint_state="selected",
        )
        _require_frame_matches_wire(audit, final_wire)
        _require(
            tuple(cast(list[int], audit["output_tokens"])) == baseline_tokens,
            "recovered output differs from baseline",
        )
        if baseline_semantic is not None:
            _require(
                audit.get("terminal_semantic_sha256") == baseline_semantic,
                "recovered terminal semantic differs from baseline",
            )

        case_summaries.append(
            {
                "crash_point": crash_point,
                "victim_mode": victim_mode,
                "ready_pid": ready["pid"],
                "setup_pids": setup_pids,
                "recovery_pids": recovery_pids,
                "audit_pid": audit_pid,
                "post_crash_sink": sink_visibility,
                "post_crash_checkpoint": checkpoint_visibility,
                "input_generation": selected_generation,
                "input_sequence": selected_sequence,
                "terminal_generation": (
                    final_wire.checkpoint.generation
                    if final_wire.checkpoint is not None
                    else 0
                ),
                "terminal_sequence": (
                    final_wire.checkpoint.next_sequence
                    if final_wire.checkpoint is not None
                    else 0
                ),
                "recovery_processes": recovery_count,
                "sink_selector_sha256": (
                    final_wire.sink.selector_sha256
                    if final_wire.sink is not None
                    else "0" * 64
                ),
                "checkpoint_selector_sha256": (
                    final_wire.checkpoint.selector_sha256
                    if final_wire.checkpoint is not None
                    else "0" * 64
                ),
                "verified": True,
            }
        )

    by_point = {
        cast(str, case["crash_point"]): case for case in case_summaries
    }
    selected_bootstrap = tuple(
        point
        for point in selected_crash_points
        if point in BOOTSTRAP_CHECKPOINT_PHASES
    )
    selected_source = tuple(
        point for point in selected_crash_points if point in SOURCE_CRASH_POINTS
    )
    selected_target = tuple(
        point for point in selected_crash_points if point in TARGET_CRASH_POINTS
    )
    _require(
        all(
            by_point[point]["post_crash_checkpoint"]
            == (
                "source-live"
                if point in BOOTSTRAP_CHECKPOINT_SELECTED_POINTS
                else "absent"
            )
            and by_point[point]["post_crash_sink"] == "absent"
            for point in selected_bootstrap
        )
        and all(
            by_point[point]["post_crash_sink"]
            == ("empty" if point in SOURCE_SINK_SELECTED_POINTS else "absent")
            and by_point[point]["post_crash_checkpoint"]
            == (
                "source-exited"
                if point in SOURCE_CHECKPOINT_GENERATION_TWO_POINTS
                else "source-live"
            )
            for point in selected_source
        )
        and all(
            by_point[point]["post_crash_sink"]
            == (
                "successor"
                if point in SINK_SUCCESSOR_VISIBLE_POINTS
                else "previous"
            )
            and by_point[point]["post_crash_checkpoint"]
            == (
                "successor"
                if point in CHECKPOINT_SUCCESSOR_VISIBLE_POINTS
                else "previous"
            )
            for point in selected_target
        ),
        "crash-visibility matrix changed",
    )
    worker_after = _read_regular_file(
        worker,
        maximum_bytes=MAX_FIXTURE_BYTES,
    )
    _require(
        hashlib.sha256(worker_after).hexdigest() == worker_sha256,
        "worker image changed during compile-once campaign",
    )
    bootstrap_checkpoint_selected_count = sum(
        point in BOOTSTRAP_CHECKPOINT_SELECTED_POINTS
        for point in selected_bootstrap
    )
    source_sink_selected_count = sum(
        point in SOURCE_SINK_SELECTED_POINTS for point in selected_source
    )
    source_checkpoint_generation_two_count = sum(
        point in SOURCE_CHECKPOINT_GENERATION_TWO_POINTS
        for point in selected_source
    )
    target_sink_successor_count = sum(
        point in SINK_SUCCESSOR_VISIBLE_POINTS for point in selected_target
    )
    target_checkpoint_successor_count = sum(
        point in CHECKPOINT_SUCCESSOR_VISIBLE_POINTS for point in selected_target
    )
    return {
        "schema": CAMPAIGN_SCHEMA,
        "process_death_count": len(selected_crash_points),
        "crash_point_count": len(selected_crash_points),
        "crash_points": list(selected_crash_points),
        "worker_sha256": worker_sha256,
        "baseline_output_tokens": list(baseline_tokens),
        "baseline_terminal_semantic_sha256": baseline_semantic,
        "bootstrap_checkpoint_absent_count": (
            len(selected_bootstrap) - bootstrap_checkpoint_selected_count
        ),
        "bootstrap_checkpoint_selected_count": (
            bootstrap_checkpoint_selected_count
        ),
        "source_sink_absent_count": (
            len(selected_source) - source_sink_selected_count
        ),
        "source_sink_selected_count": source_sink_selected_count,
        "source_checkpoint_generation_one_count": (
            len(selected_source) - source_checkpoint_generation_two_count
        ),
        "source_checkpoint_generation_two_count": (
            source_checkpoint_generation_two_count
        ),
        "target_sink_previous_count": (
            len(selected_target) - target_sink_successor_count
        ),
        "target_sink_successor_count": target_sink_successor_count,
        "target_checkpoint_previous_count": (
            len(selected_target) - target_checkpoint_successor_count
        ),
        "target_checkpoint_successor_count": (
            target_checkpoint_successor_count
        ),
        "distinct_pid_count": len(seen_pids),
        "cases": case_summaries,
        "verified": True,
    }


def _parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run prepared-text acknowledged recovery death campaign",
    )
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument(
        "--crash-point",
        action="append",
        choices=CRASH_POINTS,
        dest="crash_points",
        help="run only this point (repeatable); defaults to all 49",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
    )
    parser.add_argument(
        "--max-recovery-processes",
        type=int,
        default=DEFAULT_MAX_RECOVERY_PROCESSES,
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    parsed = _parse_arguments(sys.argv[1:] if arguments is None else arguments)
    crash_points = (
        CRASH_POINTS if parsed.crash_points is None else tuple(parsed.crash_points)
    )
    try:
        report = run_campaign(
            parsed.worker.resolve(),
            parsed.directory.resolve(),
            crash_points=crash_points,
            timeout_seconds=parsed.timeout_seconds,
            max_recovery_processes=parsed.max_recovery_processes,
        )
    except CampaignError as error:
        print(f"prepared-text recovery campaign failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
