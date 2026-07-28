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
CRASH_POINTS = (
    AFTER_STEP_BEFORE_SINK,
    *SINK_PHASES,
    AFTER_SINK_BEFORE_SELECTOR,
    *CHECKPOINT_PHASES,
)
if len(CRASH_POINTS) != 19 or len(set(CRASH_POINTS)) != 19:
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


class CampaignError(RuntimeError):
    """The worker protocol, durable wire, or recovery invariant failed."""


@dataclass(frozen=True)
class SinkWireFacts:
    generation: int
    count: int
    initial_sequence: int
    next_sequence: int
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
    checkpoint_sha256: str
    selector_sha256: str
    objects: tuple[CheckpointObject, ...]
    terminal_tokens: tuple[int, ...] | None


@dataclass(frozen=True)
class WireFacts:
    sink: SinkWireFacts
    checkpoint: CheckpointWireFacts


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
    return value


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
        _required_int(frame, "input_generation", minimum=1) == expected_generation,
        "crash-ready input generation changed",
    )
    _require(
        _required_int(frame, "input_sequence") == expected_sequence,
        "crash-ready input sequence changed",
    )
    sink_count = _required_int(frame, "sink_count")
    _require(
        expected_sequence > 0
        and sink_count in (expected_sequence - 1, expected_sequence),
        "crash-ready sink count is outside the selected edge",
    )
    _required_digest_hex(frame, "sink_ledger_sha256", allow_zero=False)
    _required_digest_hex(frame, "sink_selector_sha256", allow_zero=False)
    _required_digest_hex(
        frame,
        "checkpoint_selector_sha256",
        allow_zero=False,
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
        expected_mode in ("baseline", "source", "target", "audit"),
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
    return struct.unpack_from("<Q", encoded, offset)[0]


def _hash(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


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


def _read_regular_file(
    path: Path,
    *,
    exact_bytes: int | None = None,
    maximum_bytes: int = MAX_ARTIFACT_BYTES,
) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
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


def _decode_sink_wire(directory: Path) -> SinkWireFacts:
    selector = _read_regular_file(
        directory / SINK_ACTIVE_SELECTOR_NAME,
        exact_bytes=SINK_SELECTOR_BYTES,
    )
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
        ledger_sha256=ledger_sha256.hex(),
        selector_sha256=selector_sha256.hex(),
        acknowledgement_tokens=tuple(tokens),
    )


def _decode_checkpoint_wire(directory: Path) -> CheckpointWireFacts:
    selector = _read_regular_file(
        directory / CHECKPOINT_ACTIVE_SELECTOR_NAME,
        exact_bytes=CHECKPOINT_SELECTOR_BYTES,
    )
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
    _require(
        checkpoint[:8] == CHECKPOINT_SET_MAGIC,
        "invalid checkpoint set magic",
    )
    _require(
        _u64(checkpoint, 8) == CHECKPOINT_SET_ABI
        and _u64(checkpoint, 16) == len(checkpoint)
        and _u64(checkpoint, 24) == generation
        and _u64(checkpoint, 32) == request_epoch
        and _u64(checkpoint, 40) == next_sequence
        and _u64(checkpoint, 56) == 0
        and checkpoint[96:128] == challenge_sha256,
        "checkpoint set does not match selector",
    )
    parent_checkpoint_sha256 = checkpoint[64:96]
    _require(
        (generation == 1 and parent_checkpoint_sha256 == ZERO_DIGEST)
        or (generation > 1 and parent_checkpoint_sha256 != ZERO_DIGEST),
        "invalid checkpoint parent lineage",
    )
    object_count = _u64(checkpoint, 48)
    _require(
        1 <= object_count <= CHECKPOINT_SET_MAX_OBJECTS,
        "invalid checkpoint object count",
    )
    _require(
        checkpoint[-32:] == checkpoint_sha256
        and checkpoint_sha256 == _hash(CHECKPOINT_SET_DOMAIN, checkpoint[:-32]),
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
        checkpoint_sha256=checkpoint_sha256.hex(),
        selector_sha256=selector_sha256.hex(),
        objects=tuple(objects),
        terminal_tokens=terminal_tokens,
    )


def audit_wire_state(
    directory: Path,
    *,
    require_terminal: bool,
    permit_sink_ahead: bool = False,
) -> WireFacts:
    """Independently verify the selected sink/checkpoint roots and sequences."""

    sink = _decode_sink_wire(directory)
    checkpoint = _decode_checkpoint_wire(directory)
    if permit_sink_ahead:
        _require(
            checkpoint.next_sequence
            <= sink.next_sequence
            <= checkpoint.next_sequence + 1,
            "sink is not aligned with or one step ahead of checkpoint",
        )
    else:
        _require(
            sink.next_sequence == checkpoint.next_sequence,
            "sink/checkpoint next sequence mismatch",
        )
    if require_terminal:
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
    else:
        _require(
            checkpoint.terminal_tokens is None,
            "source unexpectedly selected terminal progress",
        )
    return WireFacts(sink=sink, checkpoint=checkpoint)


def _require_frame_matches_wire(
    frame: Mapping[str, object],
    wire: WireFacts,
) -> None:
    _require(
        frame["sink_count"] == wire.sink.count
        and frame["sink_next_sequence"] == wire.sink.next_sequence
        and frame["sink_ledger_sha256"] == wire.sink.ledger_sha256
        and frame["sink_selector_sha256"] == wire.sink.selector_sha256
        and frame["checkpoint_selector_sha256"] == wire.checkpoint.selector_sha256
        and frame["output_generation"] == wire.checkpoint.generation
        and frame["output_sequence"] == wire.checkpoint.next_sequence,
        "worker result does not match independently decoded durable state",
    )
    raw_tokens = frame["output_tokens"]
    assert isinstance(raw_tokens, list)
    tokens = cast(list[int], raw_tokens)
    _require(
        len(tokens) == wire.checkpoint.next_sequence
        and wire.sink.initial_sequence <= wire.sink.next_sequence
        and wire.sink.next_sequence <= len(tokens)
        and tuple(tokens[wire.sink.initial_sequence : wire.sink.next_sequence])
        == wire.sink.acknowledgement_tokens,
        "worker output does not contain the acknowledged sink suffix",
    )
    if wire.checkpoint.terminal_tokens is not None:
        _require(
            tuple(tokens) == wire.checkpoint.terminal_tokens,
            "worker output differs from checkpoint terminal output",
        )


def _require_ready_matches_wire(
    frame: Mapping[str, object],
    wire: WireFacts,
) -> None:
    _require(
        frame["sink_count"] == wire.sink.count
        and frame["sink_ledger_sha256"] == wire.sink.ledger_sha256
        and frame["sink_selector_sha256"] == wire.sink.selector_sha256
        and frame["checkpoint_selector_sha256"] == wire.checkpoint.selector_sha256,
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

    case_summaries: list[dict[str, object]] = []
    cases_directory = directory / "cases"
    _fresh_directory(cases_directory)
    for ordinal, crash_point in enumerate(crash_points):
        case_directory = cases_directory / f"{ordinal:02d}-{crash_point}"
        _fresh_directory(case_directory)
        _copy_baseline_fixtures(baseline_directory, case_directory)
        source = run_result_worker(
            _worker_command(worker, "source", case_directory),
            expected_mode="source",
            timeout_seconds=timeout_seconds,
        )
        _record_distinct_pid(source, seen_pids, f"{crash_point}:source")
        _require(not bool(source["terminal"]), "source unexpectedly terminal")
        source_wire = audit_wire_state(case_directory, require_terminal=False)
        _require_frame_matches_wire(source, source_wire)
        _require(
            source_wire.sink.initial_sequence == 1
            and source_wire.sink.count == 0
            and source_wire.sink.next_sequence == 1
            and source_wire.checkpoint.generation == 2
            and source_wire.checkpoint.next_sequence == 1,
            "source did not establish the generation-2/sequence-1 bootstrap",
        )
        selected_generation = source_wire.checkpoint.generation
        selected_sequence = source_wire.checkpoint.next_sequence

        ready = run_crash_worker(
            _worker_command(
                worker,
                "target",
                case_directory,
                crash_point,
            ),
            expected_crash_point=crash_point,
            expected_generation=selected_generation,
            expected_sequence=selected_sequence,
            timeout_seconds=timeout_seconds,
        )
        _record_distinct_pid(ready, seen_pids, f"{crash_point}:victim")

        post_crash_wire = audit_wire_state(
            case_directory,
            require_terminal=False,
            permit_sink_ahead=True,
        )
        _require_ready_matches_wire(ready, post_crash_wire)
        checkpoint_pair = (
            post_crash_wire.checkpoint.generation,
            post_crash_wire.checkpoint.next_sequence,
        )
        _require(
            checkpoint_pair
            in (
                (selected_generation, selected_sequence),
                (selected_generation + 1, selected_sequence + 1),
            ),
            "post-death checkpoint is not the predecessor or exact successor",
        )
        _require(
            post_crash_wire.sink.initial_sequence == 1
            and post_crash_wire.sink.count in (selected_sequence - 1, selected_sequence)
            and post_crash_wire.sink.next_sequence
            == post_crash_wire.sink.initial_sequence + post_crash_wire.sink.count,
            "post-death sink is not the predecessor or exact successor",
        )
        checkpoint_visibility = (
            "previous"
            if checkpoint_pair == (selected_generation, selected_sequence)
            else "successor"
        )
        sink_visibility = (
            "previous"
            if post_crash_wire.sink.count == selected_sequence - 1
            else "successor"
        )

        recovery_count = 0
        recovery_pids: list[int] = []
        terminal_result: dict[str, object] | None = None
        last_generation, last_sequence = checkpoint_pair
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
                    f"{crash_point}:recovery-{recovery_count}",
                )
            )
            recovery_count += 1
            input_generation = _required_int(recovered, "input_generation")
            input_sequence = _required_int(recovered, "input_sequence")
            output_generation = _required_int(recovered, "output_generation")
            output_sequence = _required_int(recovered, "output_sequence")
            _require(
                (input_generation, input_sequence) == (last_generation, last_sequence)
                and output_generation == input_generation + 1
                and output_sequence == input_sequence + 1,
                "fresh recovery process did not select/commit one contiguous edge",
            )
            last_generation = output_generation
            last_sequence = output_sequence
            current_wire = audit_wire_state(
                case_directory,
                require_terminal=bool(recovered["terminal"]),
            )
            _require_frame_matches_wire(recovered, current_wire)
            if recovered["terminal"]:
                terminal_result = recovered
                break
        _require(
            terminal_result is not None,
            "recovery process bound reached before terminal",
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
        final_wire = audit_wire_state(case_directory, require_terminal=True)
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
                "ready_pid": ready["pid"],
                "source_pid": source["pid"],
                "recovery_pids": recovery_pids,
                "audit_pid": audit_pid,
                "post_crash_sink": sink_visibility,
                "post_crash_checkpoint": checkpoint_visibility,
                "input_generation": selected_generation,
                "input_sequence": selected_sequence,
                "terminal_generation": final_wire.checkpoint.generation,
                "terminal_sequence": final_wire.checkpoint.next_sequence,
                "recovery_processes": recovery_count,
                "sink_selector_sha256": final_wire.sink.selector_sha256,
                "checkpoint_selector_sha256": (final_wire.checkpoint.selector_sha256),
                "verified": True,
            }
        )

    sink_previous_count = sum(
        case["post_crash_sink"] == "previous" for case in case_summaries
    )
    checkpoint_previous_count = sum(
        case["post_crash_checkpoint"] == "previous" for case in case_summaries
    )
    expected_sink_successor_count = sum(
        point in SINK_SUCCESSOR_VISIBLE_POINTS for point in selected_crash_points
    )
    expected_checkpoint_successor_count = sum(
        point in CHECKPOINT_SUCCESSOR_VISIBLE_POINTS for point in selected_crash_points
    )
    _require(
        len(case_summaries) - sink_previous_count == expected_sink_successor_count
        and len(case_summaries) - checkpoint_previous_count
        == expected_checkpoint_successor_count,
        "previous/successor crash-visibility matrix changed",
    )
    return {
        "schema": CAMPAIGN_SCHEMA,
        "process_death_count": len(selected_crash_points),
        "crash_point_count": len(crash_points),
        "crash_points": list(crash_points),
        "baseline_output_tokens": list(baseline_tokens),
        "baseline_terminal_semantic_sha256": baseline_semantic,
        "sink_previous_count": sink_previous_count,
        "sink_successor_count": len(case_summaries) - sink_previous_count,
        "checkpoint_previous_count": checkpoint_previous_count,
        "checkpoint_successor_count": len(case_summaries) - checkpoint_previous_count,
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
        help="run only this point (repeatable); defaults to all 19",
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
