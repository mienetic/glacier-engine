"""Host-process death campaign for durable GLRT publication.

The caller supplies a prebuilt Zig worker.  This controller never builds it.
It owns the process boundary, sends real ``SIGKILL`` only after a bounded
canonical ready frame, and independently validates the tiny two-record GLRT v2
fixture before and after recovery.

The resulting evidence is intentionally limited to host process death and the
worker's file/directory sync protocol.  It does not emulate or claim physical
power-loss persistence.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
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
from typing import Callable, Mapping, Sequence, cast
import zlib


READY_SCHEMA = "glacier.runtime-image-durable-recovery/ready-v1"
RESULT_SCHEMA = "glacier.runtime-image-durable-recovery/result-v1"
CAMPAIGN_SCHEMA = "glacier.runtime-image-durable-recovery/campaign-v1"

CRASH_PHASES = (
    "provider_mid_record",
    "stale_candidate_removed",
    "candidate_created",
    "candidate_encoded",
    "candidate_synced",
    "candidate_validated",
    "target_replaced",
    "directory_committed",
)
PRE_RENAME_PHASES = frozenset(CRASH_PHASES[:6])
COMPLETE_CANDIDATE_PHASES = frozenset(
    ("candidate_encoded", "candidate_synced", "candidate_validated")
)
CANDIDATE_VISIBLE_PHASES = frozenset(
    (
        "provider_mid_record",
        "candidate_created",
        "candidate_encoded",
        "candidate_synced",
        "candidate_validated",
    )
)
STALE_ON_RECOVERY_PHASES = CANDIDATE_VISIBLE_PHASES

DEFAULT_TIMEOUT_SECONDS = 20.0
TARGET_NAME = "durable-fixture.glrt"
MAX_JSON_FRAME_BYTES = 16 * 1024
MAX_STDERR_BYTES = 16 * 1024
MAX_GLRT_BYTES = 1024 * 1024
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1

GLRT_HEADER_SIZE = 512
GLRT_RECORD_SIZE = 160
GLRT_ALIGNMENT = 64
GLRT_RECORD_COUNT = 2
GLRT_INDEX_OFFSET = GLRT_HEADER_SIZE
GLRT_DATA_OFFSET = 832
GLRT_FILE_SIZE = 1024
STREAM_RANGE_OFFSETS = (40, 56, 72, 88, 104)
TENSOR_KINDS = frozenset((*range(16), 255))
PACKED_NONE = 0xFFFF
PAIR_NONE = 0xFFFF

PUBLICATION_ABI = 0x474C_5250_0000_0001
PUBLICATION_PLAN_DOMAIN = b"glacier-runtime-image-publication-plan-v1\x00"
RESERVED_PREFIX = ".glacier-glrt-"
LOCK_NAME = ".glacier-glrt-publication.lock-v1"
CANDIDATE_NAME = ".glacier-glrt-publication.candidate-v1"

READY_KEYS = (
    "schema",
    "phase",
    "pid",
    "crash_point",
    "target_name",
    "publication_plan_sha256",
    "host_process_recovery",
    "power_loss_emulated",
)
RESULT_KEYS = (
    "schema",
    "mode",
    "pid",
    "target_name",
    "disposition",
    "source_fingerprint",
    "abi_fingerprint",
    "container_bytes",
    "container_sha256",
    "publication_plan_sha256",
    "generated_records",
    "generated_workspace_bytes_total",
    "generated_workspace_bytes_peak",
    "stale_candidate_removed",
    "host_process_recovery",
    "power_loss_emulated",
    "verified",
)


class CampaignError(RuntimeError):
    """The worker protocol, GLRT wire, or recovery invariant failed."""


@dataclass(frozen=True)
class RecordFacts:
    """Independently decoded fields that bind one GLRT record plan and body."""

    layer_idx: int
    kind: int
    role: int
    encoding: int
    packed_layout: int
    pair_layout: int
    group_size: int
    out_f: int
    in_f: int
    num_elements: int
    flags: int
    stream_lengths: tuple[int, int, int, int, int]
    payload_crc32: int
    payload_digest: str
    descriptor_sha256: str


@dataclass(frozen=True)
class GlrtFacts:
    """Byte-exact and semantic facts from one independently verified GLRT."""

    container_bytes: int
    container_sha256: str
    source_fingerprint: str
    abi_fingerprint: str
    config_values: tuple[int, int, int, int, int, int, int]
    tie_embeddings: bool
    rms_eps_bits: int
    rope_theta_bits: int
    index_sha256: str
    records: tuple[RecordFacts, RecordFacts]


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CampaignError(message)


def _is_int(value: object) -> bool:
    return type(value) is int


def _required_u64(frame: Mapping[str, object], name: str, *, minimum: int = 0) -> int:
    value = frame.get(name)
    _require(_is_int(value), f"invalid {name}")
    result = cast(int, value)
    _require(minimum <= result <= MAX_U64, f"invalid {name}")
    return result


def _required_bool(frame: Mapping[str, object], name: str) -> bool:
    value = frame.get(name)
    _require(type(value) is bool, f"invalid {name}")
    return cast(bool, value)


def _required_digest(
    frame: Mapping[str, object],
    name: str,
    *,
    allow_zero: bool = False,
) -> str:
    value = frame.get(name)
    _require(type(value) is str, f"invalid {name}")
    digest = cast(str, value)
    _require(
        len(digest) == 64
        and all(character in "0123456789abcdef" for character in digest),
        f"invalid {name}",
    )
    _require(allow_zero or digest != "0" * 64, f"zero {name}")
    return digest


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
    _require(b"\r" not in line, "JSON frame contains a carriage return")
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
    canonical = json.dumps(value, ensure_ascii=True, separators=(",", ":"))
    _require(text == canonical, "JSON frame is not canonical compact JSON")
    return cast(dict[str, object], value)


def decode_canonical_json_line(line: bytes) -> dict[str, object]:
    """Public test helper for one newline-free bounded canonical JSON object."""

    return _decode_canonical_json(line)


def _cleanup_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            stream.close()


def _spawn(
    command: Sequence[str],
    *,
    blocking_stdin: bool,
) -> subprocess.Popen[bytes]:
    _require(bool(command), "empty worker command")
    try:
        return subprocess.Popen(
            tuple(command),
            stdin=subprocess.PIPE if blocking_stdin else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            close_fds=True,
        )
    except OSError as error:
        raise CampaignError(f"cannot start worker: {command[0]}") from error


def _capture_normal_frame(
    command: Sequence[str],
    *,
    timeout_seconds: float,
) -> tuple[dict[str, object], int, int]:
    process = _spawn(command, blocking_stdin=False)
    assert process.stdout is not None
    assert process.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    stdout = bytearray()
    stderr = bytearray()
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
                target = stdout if key.data == "stdout" else stderr
                target.extend(chunk)
                limit = (
                    MAX_JSON_FRAME_BYTES + 1
                    if key.data == "stdout"
                    else MAX_STDERR_BYTES
                )
                _require(len(target) <= limit, f"worker {key.data} exceeds bound")

        remaining = deadline - time.monotonic()
        _require(remaining > 0, "worker timed out before exit")
        try:
            return_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise CampaignError("worker did not exit") from error
        _require(not stderr, "worker emitted stderr")
        _require(
            stdout.endswith(b"\n") and stdout.count(b"\n") == 1,
            "worker did not emit exactly one JSON line",
        )
        return _decode_canonical_json(bytes(stdout[:-1])), return_code, process.pid
    except BaseException:
        _cleanup_process(process)
        raise
    finally:
        selector.close()
        if process.poll() is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def _capture_ready_and_sigkill(
    command: Sequence[str],
    *,
    timeout_seconds: float,
    validate: Callable[[dict[str, object], int], None],
) -> dict[str, object]:
    """Accept one ready frame, then send and prove one real SIGKILL."""

    process = _spawn(command, blocking_stdin=True)
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    stdout = bytearray()
    stderr = bytearray()
    deadline = time.monotonic() + timeout_seconds
    try:
        frame: dict[str, object] | None = None
        while frame is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CampaignError("victim timed out before ready")
            events = selector.select(remaining)
            if not events:
                raise CampaignError("victim timed out before ready")
            for key, _ in events:
                chunk = os.read(key.fd, 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    if key.data == "stdout":
                        raise CampaignError("victim exited before ready")
                    continue
                if key.data == "stderr":
                    stderr.extend(chunk)
                    _require(
                        len(stderr) <= MAX_STDERR_BYTES,
                        "victim stderr exceeds bound",
                    )
                    raise CampaignError("victim emitted stderr before ready")
                stdout.extend(chunk)
                _require(
                    len(stdout) <= MAX_JSON_FRAME_BYTES + 1,
                    "victim ready frame exceeds bound",
                )
                newline = stdout.find(b"\n")
                if newline < 0:
                    continue
                _require(
                    newline == len(stdout) - 1,
                    "victim emitted trailing stdout before SIGKILL",
                )
                frame = _decode_canonical_json(bytes(stdout[:newline]))
                validate(frame, process.pid)
                break

        _require(process.poll() is None, "victim exited after its ready frame")
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError as error:
            raise CampaignError("victim disappeared before SIGKILL") from error
        remaining = deadline - time.monotonic()
        _require(remaining > 0, "victim timed out during SIGKILL")
        try:
            return_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise CampaignError("victim did not terminate after SIGKILL") from error
        _require(
            return_code == -signal.SIGKILL,
            "victim did not terminate by SIGKILL",
        )
        trailing_stdout = process.stdout.read(MAX_JSON_FRAME_BYTES + 1)
        trailing_stderr = process.stderr.read(MAX_STDERR_BYTES + 1)
        _require(not trailing_stdout, "victim emitted stdout after ready")
        _require(not stderr and not trailing_stderr, "victim emitted stderr")
        return frame
    except BaseException:
        _cleanup_process(process)
        raise
    finally:
        selector.close()
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


def _validate_ready_frame(
    frame: dict[str, object],
    *,
    process_pid: int,
    expected_phase: str,
    expected_plan_sha256: str,
) -> None:
    _require(tuple(frame) == READY_KEYS, "ready frame shape changed")
    _require(frame["schema"] == READY_SCHEMA, "wrong ready schema")
    _require(frame["phase"] == "victim_ready", "wrong ready phase")
    _require(
        _required_u64(frame, "pid", minimum=1) == process_pid,
        "ready PID does not identify the victim",
    )
    _require(frame["crash_point"] == expected_phase, "wrong crash point")
    _require(frame["target_name"] == TARGET_NAME, "wrong ready target")
    _require(
        _required_digest(frame, "publication_plan_sha256")
        == expected_plan_sha256,
        "ready publication plan changed",
    )
    _require(
        _required_bool(frame, "host_process_recovery"),
        "worker did not claim host-process recovery",
    )
    _require(
        not _required_bool(frame, "power_loss_emulated"),
        "worker claimed power-loss emulation",
    )


def _validate_result_frame(
    frame: dict[str, object],
    *,
    expected_process_pid: int,
    expected_mode: str,
    expected_disposition: str,
    expected_plan_sha256: str | None,
    expected_stale_candidate_removed: bool,
) -> None:
    _require(tuple(frame) == RESULT_KEYS, "result frame shape changed")
    _require(frame["schema"] == RESULT_SCHEMA, "wrong result schema")
    _require(frame["mode"] == expected_mode, "wrong result mode")
    _require(
        _required_u64(frame, "pid", minimum=1) == expected_process_pid,
        "result PID does not identify the worker",
    )
    _require(frame["target_name"] == TARGET_NAME, "wrong result target")
    _require(
        frame["disposition"] == expected_disposition,
        "wrong publication disposition",
    )
    _required_digest(frame, "source_fingerprint")
    _required_digest(frame, "abi_fingerprint")
    _required_u64(frame, "container_bytes", minimum=1)
    _required_digest(frame, "container_sha256")
    plan = frame["publication_plan_sha256"]
    if expected_plan_sha256 is None:
        _require(plan is None, "audit unexpectedly reported a publication plan")
    else:
        _require(
            _required_digest(frame, "publication_plan_sha256")
            == expected_plan_sha256,
            "result publication plan changed",
        )

    generated_records = _required_u64(frame, "generated_records")
    generated_total = _required_u64(
        frame,
        "generated_workspace_bytes_total",
    )
    generated_peak = _required_u64(frame, "generated_workspace_bytes_peak")
    expected_stats = (2, 32, 16) if expected_mode == "recover" else (0, 0, 0)
    _require(
        (generated_records, generated_total, generated_peak) == expected_stats,
        "worker generation ledger changed",
    )
    _require(
        _required_bool(frame, "stale_candidate_removed")
        == expected_stale_candidate_removed,
        "stale-candidate receipt changed",
    )
    _require(
        _required_bool(frame, "host_process_recovery"),
        "worker did not claim host-process recovery",
    )
    _require(
        not _required_bool(frame, "power_loss_emulated"),
        "worker claimed power-loss emulation",
    )
    _require(_required_bool(frame, "verified"), "worker did not verify its result")


def _run_result_worker(
    worker: Path,
    mode: str,
    directory: Path,
    *,
    timeout_seconds: float,
    expected_disposition: str,
    expected_plan_sha256: str | None,
    expected_stale_candidate_removed: bool = False,
) -> dict[str, object]:
    frame, return_code, process_pid = _capture_normal_frame(
        (str(worker), mode, str(directory), TARGET_NAME),
        timeout_seconds=timeout_seconds,
    )
    _require(return_code == 0, f"{mode} worker exited unsuccessfully")
    _validate_result_frame(
        frame,
        expected_process_pid=process_pid,
        expected_mode=mode,
        expected_disposition=expected_disposition,
        expected_plan_sha256=expected_plan_sha256,
        expected_stale_candidate_removed=expected_stale_candidate_removed,
    )
    return frame


def _run_victim(
    worker: Path,
    directory: Path,
    phase: str,
    *,
    timeout_seconds: float,
    expected_plan_sha256: str,
) -> dict[str, object]:
    _require(phase in CRASH_PHASES, "unknown crash phase")

    def validate(frame: dict[str, object], process_pid: int) -> None:
        _validate_ready_frame(
            frame,
            process_pid=process_pid,
            expected_phase=phase,
            expected_plan_sha256=expected_plan_sha256,
        )

    return _capture_ready_and_sigkill(
        (str(worker), "victim", str(directory), TARGET_NAME, phase),
        timeout_seconds=timeout_seconds,
        validate=validate,
    )


def _read_regular_file(path: Path) -> bytes:
    """Read one immutable bounded regular file without following a final link."""

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise CampaignError(f"cannot open {path.name}") from error
    try:
        before = os.fstat(descriptor)
        _require(stat.S_ISREG(before.st_mode), f"{path.name} is not regular")
        _require(before.st_nlink == 1, f"{path.name} has multiple links")
        _require(
            before.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0,
            f"{path.name} is group/world writable",
        )
        _require(
            GLRT_HEADER_SIZE <= before.st_size <= MAX_GLRT_BYTES,
            f"{path.name} size is outside the GLRT bound",
        )
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            _require(bool(chunk), f"{path.name} was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        _require(not os.read(descriptor, 1), f"{path.name} grew while reading")
        after = os.fstat(descriptor)
        _require(
            (
                before.st_dev,
                before.st_ino,
                before.st_mode,
                before.st_nlink,
                before.st_size,
                before.st_mtime_ns,
            )
            == (
                after.st_dev,
                after.st_ino,
                after.st_mode,
                after.st_nlink,
                after.st_size,
                after.st_mtime_ns,
            ),
            f"{path.name} changed while reading",
        )
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _validate_fixture_record(
    *,
    index: int,
    layer_idx: int,
    kind: int,
    role: int,
    encoding: int,
    packed_layout: int,
    pair_layout: int,
    group_size: int,
    out_f: int,
    in_f: int,
    num_elements: int,
    flags: int,
    ranges: tuple[tuple[int, int], ...],
) -> None:
    common = role == 0 and pair_layout == PAIR_NONE and flags == 0
    if index == 0:
        _require(
            common
            and (layer_idx, kind) == (0, 10)
            and encoding == 0
            and packed_layout == PACKED_NONE
            and group_size == 0
            and (out_f, in_f, num_elements) == (1, 4, 4)
            and ranges
            == (
                (0, 0),
                (0, 0),
                (0, 0),
                (0, 0),
                (GLRT_DATA_OFFSET, 16),
            ),
            "record 0 is not the canonical raw-f32 fixture record",
        )
        return
    _require(
        common
        and (layer_idx, kind) == (0, 1)
        and encoding == 1
        and packed_layout == 0
        and group_size == 16
        and (out_f, in_f, num_elements) == (1, 16, 16)
        and ranges
        == (
            (896, 8),
            (960, 4),
            (0, 0),
            (0, 0),
            (0, 0),
        ),
        "record 1 is not the canonical INT4 fixture record",
    )


def parse_glrt_v2(path: Path) -> GlrtFacts:
    """Strictly parse and hash-check the campaign's current GLRT v2 fixture."""

    encoded = _read_regular_file(path)
    _require(len(encoded) == GLRT_FILE_SIZE, "fixture GLRT has the wrong size")
    header = encoded[:GLRT_HEADER_SIZE]
    _require(header[:4] == b"GLRT", "bad GLRT magic")
    version, header_size, record_size, alignment = struct.unpack_from(
        "<HHHH",
        header,
        4,
    )
    _require(version == 2, "fixture is not GLRT v2")
    _require(
        (header_size, record_size, alignment)
        == (GLRT_HEADER_SIZE, GLRT_RECORD_SIZE, GLRT_ALIGNMENT),
        "non-canonical GLRT layout",
    )
    flags = struct.unpack_from("<I", header, 12)[0]
    record_count, index_offset, data_offset, declared_size = struct.unpack_from(
        "<QQQQ",
        header,
        16,
    )
    _require(flags == 0, "GLRT flags are non-zero")
    _require(record_count == GLRT_RECORD_COUNT, "wrong GLRT fixture record count")
    _require(
        (index_offset, data_offset, declared_size)
        == (GLRT_INDEX_OFFSET, GLRT_DATA_OFFSET, GLRT_FILE_SIZE),
        "wrong GLRT fixture extents",
    )
    source_fingerprint = header[48:80]
    abi_fingerprint = header[80:112]
    _require(any(source_fingerprint), "zero GLRT source fingerprint")
    _require(any(abi_fingerprint), "zero GLRT ABI fingerprint")

    config_values = cast(
        tuple[int, int, int, int, int, int, int],
        struct.unpack_from("<7I", header, 112),
    )
    _require(all(value > 0 for value in config_values), "invalid GLRT config")
    _require(header[140] in (0, 1), "invalid tied-embedding flag")
    _require(not any(header[141:144]), "non-zero GLRT config padding")
    rms_eps_bits, rope_theta_bits = struct.unpack_from("<II", header, 144)
    rms_eps, rope_theta = struct.unpack_from("<ff", header, 144)
    _require(
        math.isfinite(rms_eps)
        and rms_eps > 0
        and math.isfinite(rope_theta)
        and rope_theta > 0,
        "invalid GLRT floating config",
    )
    expected_index_crc, expected_header_crc = struct.unpack_from("<II", header, 152)
    header_crc_input = bytearray(header)
    header_crc_input[156:160] = b"\0\0\0\0"
    _require(
        zlib.crc32(header_crc_input) & MAX_U32 == expected_header_crc,
        "GLRT header CRC mismatch",
    )
    _require(not any(header[160:]), "non-zero GLRT header reserved bytes")

    index_end = index_offset + record_count * record_size
    _require(index_end == data_offset, "GLRT index/data boundary changed")
    index = encoded[index_offset:index_end]
    _require(
        zlib.crc32(index) & MAX_U32 == expected_index_crc,
        "GLRT index CRC mismatch",
    )

    records: list[RecordFacts] = []
    payload_extents: list[tuple[int, int]] = []
    for record_index in range(GLRT_RECORD_COUNT):
        start = index_offset + record_index * GLRT_RECORD_SIZE
        descriptor = encoded[start : start + GLRT_RECORD_SIZE]
        _require(
            not any(descriptor[124:128]),
            f"record {record_index} has non-zero reserved bytes",
        )
        layer_idx, kind = struct.unpack_from("<II", descriptor, 0)
        encoding, packed_layout = struct.unpack_from("<HH", descriptor, 8)
        group_size, out_f, in_f, record_flags, payload_crc32 = struct.unpack_from(
            "<IIIII",
            descriptor,
            12,
        )
        num_elements = struct.unpack_from("<Q", descriptor, 32)[0]
        role, pair_layout = struct.unpack_from("<HH", descriptor, 120)
        _require(kind in TENSOR_KINDS, f"record {record_index} has a bad kind")
        _require(role == 0, f"record {record_index} has a bad role")
        ranges = tuple(
            struct.unpack_from("<QQ", descriptor, offset)
            for offset in STREAM_RANGE_OFFSETS
        )
        for offset, length in ranges:
            _require(
                (offset == 0) == (length == 0),
                f"record {record_index} has a half-empty range",
            )
            if length == 0:
                continue
            end = offset + length
            _require(
                offset >= data_offset
                and offset % GLRT_ALIGNMENT == 0
                and end <= len(encoded),
                f"record {record_index} payload is out of bounds",
            )
            payload_extents.append((offset, end))

        _validate_fixture_record(
            index=record_index,
            layer_idx=layer_idx,
            kind=kind,
            role=role,
            encoding=encoding,
            packed_layout=packed_layout,
            pair_layout=pair_layout,
            group_size=group_size,
            out_f=out_f,
            in_f=in_f,
            num_elements=num_elements,
            flags=record_flags,
            ranges=ranges,
        )
        crc = 0
        digest = hashlib.sha256(descriptor[:128])
        for offset, length in ranges:
            if length == 0:
                continue
            payload = encoded[offset : offset + length]
            crc = zlib.crc32(payload, crc) & MAX_U32
            digest.update(payload)
        _require(crc == payload_crc32, f"record {record_index} payload CRC mismatch")
        stored_digest = descriptor[128:160]
        _require(any(stored_digest), f"record {record_index} has a zero digest")
        _require(
            digest.digest() == stored_digest,
            f"record {record_index} payload digest mismatch",
        )
        records.append(
            RecordFacts(
                layer_idx=layer_idx,
                kind=kind,
                role=role,
                encoding=encoding,
                packed_layout=packed_layout,
                pair_layout=pair_layout,
                group_size=group_size,
                out_f=out_f,
                in_f=in_f,
                num_elements=num_elements,
                flags=record_flags,
                stream_lengths=cast(
                    tuple[int, int, int, int, int],
                    tuple(length for _, length in ranges),
                ),
                payload_crc32=payload_crc32,
                payload_digest=stored_digest.hex(),
                descriptor_sha256=hashlib.sha256(descriptor).hexdigest(),
            )
        )

    payload_extents.sort()
    for previous, current in zip(payload_extents, payload_extents[1:]):
        _require(previous[1] <= current[0], "GLRT payload extents overlap")
    covered = bytearray(GLRT_FILE_SIZE)
    covered[:GLRT_DATA_OFFSET] = b"\1" * GLRT_DATA_OFFSET
    for start, end in payload_extents:
        covered[start:end] = b"\1" * (end - start)
    _require(
        all(byte == 0 for byte, used in zip(encoded, covered) if not used),
        "GLRT alignment padding is non-zero",
    )

    return GlrtFacts(
        container_bytes=len(encoded),
        container_sha256=hashlib.sha256(encoded).hexdigest(),
        source_fingerprint=source_fingerprint.hex(),
        abi_fingerprint=abi_fingerprint.hex(),
        config_values=config_values,
        tie_embeddings=bool(header[140]),
        rms_eps_bits=rms_eps_bits,
        rope_theta_bits=rope_theta_bits,
        index_sha256=hashlib.sha256(index).hexdigest(),
        records=cast(tuple[RecordFacts, RecordFacts], tuple(records)),
    )


def _publication_plan_sha256(target_name: str, facts: GlrtFacts) -> str:
    """Independently reproduce the public publication-plan commitment."""

    target = target_name.encode("utf-8")
    digest = hashlib.sha256()
    digest.update(PUBLICATION_PLAN_DOMAIN)
    digest.update(struct.pack("<Q", PUBLICATION_ABI))
    digest.update(struct.pack("<Q", len(target)))
    digest.update(target)
    digest.update(struct.pack("<Q", 2))
    digest.update(bytes.fromhex(facts.source_fingerprint))
    digest.update(bytes.fromhex(facts.abi_fingerprint))
    for value in facts.config_values:
        digest.update(struct.pack("<I", value))
    digest.update(struct.pack("<I", facts.rms_eps_bits))
    digest.update(struct.pack("<I", facts.rope_theta_bits))
    digest.update(struct.pack("<B", int(facts.tie_embeddings)))
    digest.update(struct.pack("<Q", len(facts.records)))
    for record in facts.records:
        digest.update(struct.pack("<II", record.layer_idx, record.kind))
        digest.update(
            struct.pack(
                "<HHHH",
                record.role,
                record.encoding,
                record.packed_layout,
                record.pair_layout,
            )
        )
        digest.update(struct.pack("<III", record.group_size, record.out_f, record.in_f))
        digest.update(struct.pack("<Q", record.num_elements))
        digest.update(struct.pack("<I", record.flags))
        for length in record.stream_lengths:
            digest.update(struct.pack("<Q", length))
    return digest.hexdigest()


def _reserved_names(target_name: str) -> tuple[str, str]:
    _require(target_name == TARGET_NAME, "unexpected fixture target")
    return LOCK_NAME, CANDIDATE_NAME


def _audit_namespace(
    directory: Path,
    *,
    candidate_expected: bool,
) -> tuple[Path, Path]:
    lock_name, candidate_name = _reserved_names(TARGET_NAME)
    expected = {TARGET_NAME, lock_name}
    if candidate_expected:
        expected.add(candidate_name)
    try:
        entries = {entry.name: entry for entry in os.scandir(directory)}
    except OSError as error:
        raise CampaignError("cannot inspect campaign namespace") from error
    _require(set(entries) == expected, "campaign namespace contains unexpected entries")
    for name, entry in entries.items():
        metadata = entry.stat(follow_symlinks=False)
        _require(stat.S_ISREG(metadata.st_mode), f"{name} is not regular")
        _require(metadata.st_nlink == 1, f"{name} has multiple links")
        _require(
            metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0,
            f"{name} is group/world writable",
        )
        if name == lock_name:
            _require(
                metadata.st_mode & 0o077 == 0,
                "stable lock permissions are not private",
            )
            _require(metadata.st_size == 0, "stable lock contents changed")
        elif name == candidate_name:
            _require(
                metadata.st_mode & 0o077 == 0,
                "candidate permissions are not private",
            )
            _require(
                metadata.st_size <= MAX_GLRT_BYTES,
                "candidate exceeds the fixture bound",
            )
    return directory / TARGET_NAME, directory / candidate_name


def _require_frame_matches_facts(
    frame: Mapping[str, object],
    facts: GlrtFacts,
) -> None:
    _require(
        frame["source_fingerprint"] == facts.source_fingerprint,
        "worker/source fingerprint mismatch",
    )
    _require(
        frame["abi_fingerprint"] == facts.abi_fingerprint,
        "worker/ABI fingerprint mismatch",
    )
    _require(
        frame["container_bytes"] == facts.container_bytes,
        "worker/container size mismatch",
    )
    _require(
        frame["container_sha256"] == facts.container_sha256,
        "worker/container digest mismatch",
    )


def _make_case_directory(root: Path, name: str) -> Path:
    path = root / name
    try:
        path.mkdir(mode=0o700)
    except OSError as error:
        raise CampaignError(f"cannot create campaign case: {name}") from error
    return path


def _require_exact(actual: GlrtFacts, expected: GlrtFacts, where: str) -> None:
    _require(actual == expected, f"{where} is not the byte-exact expected image")


def run_campaign(
    *,
    worker: Path,
    directory: Path,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, object]:
    """Run all eight primary crash phases and return canonicalizable evidence."""

    _require(os.name == "posix", "the SIGKILL campaign requires a POSIX host")
    _require(timeout_seconds > 0 and math.isfinite(timeout_seconds), "bad timeout")
    _require(directory.is_dir(), "campaign directory does not exist")
    _require(not directory.is_symlink(), "campaign directory is a symlink")
    _require(
        directory.stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0,
        "campaign directory is group/world writable",
    )
    _require(not any(directory.iterdir()), "campaign directory must be empty")

    baseline = _make_case_directory(directory, "baseline")
    seed_frame, seed_return_code, seed_pid = _capture_normal_frame(
        (str(worker), "seed", str(baseline), TARGET_NAME),
        timeout_seconds=timeout_seconds,
    )
    _require(seed_return_code == 0, "baseline seed worker exited unsuccessfully")
    predecessor_path, _ = _audit_namespace(baseline, candidate_expected=False)
    predecessor = parse_glrt_v2(predecessor_path)
    predecessor_plan = _publication_plan_sha256(TARGET_NAME, predecessor)
    _validate_result_frame(
        seed_frame,
        expected_process_pid=seed_pid,
        expected_mode="seed",
        expected_disposition="published",
        expected_plan_sha256=predecessor_plan,
        expected_stale_candidate_removed=False,
    )
    _require_frame_matches_facts(seed_frame, predecessor)

    successor_frame, successor_return_code, successor_pid = _capture_normal_frame(
        (str(worker), "recover", str(baseline), TARGET_NAME),
        timeout_seconds=timeout_seconds,
    )
    _require(
        successor_return_code == 0,
        "baseline recover worker exited unsuccessfully",
    )
    successor_path, _ = _audit_namespace(baseline, candidate_expected=False)
    successor = parse_glrt_v2(successor_path)
    successor_plan = _publication_plan_sha256(TARGET_NAME, successor)
    _validate_result_frame(
        successor_frame,
        expected_process_pid=successor_pid,
        expected_mode="recover",
        expected_disposition="published",
        expected_plan_sha256=successor_plan,
        expected_stale_candidate_removed=False,
    )
    _require_frame_matches_facts(successor_frame, successor)
    _require(
        predecessor.container_sha256 != successor.container_sha256
        and predecessor.source_fingerprint != successor.source_fingerprint,
        "fixture predecessor and successor are not distinct",
    )
    _require(predecessor_plan != successor_plan, "fixture publication plans collide")

    audit_frame = _run_result_worker(
        worker,
        "audit",
        baseline,
        timeout_seconds=timeout_seconds,
        expected_disposition="observed",
        expected_plan_sha256=None,
    )
    _require_frame_matches_facts(audit_frame, successor)
    final_baseline_path, _ = _audit_namespace(baseline, candidate_expected=False)
    _require_exact(
        parse_glrt_v2(final_baseline_path),
        successor,
        "baseline final audit",
    )

    cases: list[dict[str, object]] = []
    for phase_index, phase in enumerate(CRASH_PHASES):
        case = _make_case_directory(
            directory,
            f"case-{phase_index:02d}-{phase.replace('_', '-')}",
        )
        case_seed = _run_result_worker(
            worker,
            "seed",
            case,
            timeout_seconds=timeout_seconds,
            expected_disposition="published",
            expected_plan_sha256=predecessor_plan,
        )
        _require_frame_matches_facts(case_seed, predecessor)
        target_path, _ = _audit_namespace(case, candidate_expected=False)
        _require_exact(parse_glrt_v2(target_path), predecessor, f"{phase} seed")

        setup_sigkill = phase == "stale_candidate_removed"
        if setup_sigkill:
            _run_victim(
                worker,
                case,
                "candidate_created",
                timeout_seconds=timeout_seconds,
                expected_plan_sha256=successor_plan,
            )
            setup_target, _ = _audit_namespace(case, candidate_expected=True)
            _require_exact(
                parse_glrt_v2(setup_target),
                predecessor,
                "stale-candidate setup target",
            )

        _run_victim(
            worker,
            case,
            phase,
            timeout_seconds=timeout_seconds,
            expected_plan_sha256=successor_plan,
        )
        candidate_expected = phase in CANDIDATE_VISIBLE_PHASES
        target_path, candidate_path = _audit_namespace(
            case,
            candidate_expected=candidate_expected,
        )
        after_kill = parse_glrt_v2(target_path)
        expected_after_kill = (
            predecessor if phase in PRE_RENAME_PHASES else successor
        )
        _require_exact(after_kill, expected_after_kill, f"{phase} post-kill target")
        if phase in COMPLETE_CANDIDATE_PHASES:
            _require_exact(
                parse_glrt_v2(candidate_path),
                successor,
                f"{phase} complete candidate",
            )

        expected_disposition = (
            "published" if phase in PRE_RENAME_PHASES else "already_current"
        )
        expected_stale = phase in STALE_ON_RECOVERY_PHASES
        recovered = _run_result_worker(
            worker,
            "recover",
            case,
            timeout_seconds=timeout_seconds,
            expected_disposition=expected_disposition,
            expected_plan_sha256=successor_plan,
            expected_stale_candidate_removed=expected_stale,
        )
        _require_frame_matches_facts(recovered, successor)
        recovered_path, _ = _audit_namespace(case, candidate_expected=False)
        _require_exact(
            parse_glrt_v2(recovered_path),
            successor,
            f"{phase} recovery",
        )

        retry = _run_result_worker(
            worker,
            "recover",
            case,
            timeout_seconds=timeout_seconds,
            expected_disposition="already_current",
            expected_plan_sha256=successor_plan,
        )
        _require_frame_matches_facts(retry, successor)
        retry_path, _ = _audit_namespace(case, candidate_expected=False)
        _require_exact(parse_glrt_v2(retry_path), successor, f"{phase} retry")

        final_audit = _run_result_worker(
            worker,
            "audit",
            case,
            timeout_seconds=timeout_seconds,
            expected_disposition="observed",
            expected_plan_sha256=None,
        )
        _require_frame_matches_facts(final_audit, successor)
        final_path, _ = _audit_namespace(case, candidate_expected=False)
        _require_exact(parse_glrt_v2(final_path), successor, f"{phase} final audit")

        cases.append(
            {
                "phase": phase,
                "post_kill_target": (
                    "predecessor" if phase in PRE_RENAME_PHASES else "successor"
                ),
                "candidate_after_kill": candidate_expected,
                "recovery_disposition": expected_disposition,
                "recovery_removed_stale_candidate": expected_stale,
                "setup_sigkill": setup_sigkill,
                "verified": True,
            }
        )

    _require(len(cases) == 8, "primary crash campaign cardinality changed")
    _require(
        sum(bool(case["setup_sigkill"]) for case in cases) == 1,
        "stale-candidate setup cardinality changed",
    )
    return {
        "schema": CAMPAIGN_SCHEMA,
        "target_name": TARGET_NAME,
        "primary_sigkill_count": 8,
        "setup_sigkill_count": 1,
        "normal_exit_count": 35,
        "host_process_recovery": True,
        "power_loss_emulated": False,
        "predecessor": {
            "source_fingerprint": predecessor.source_fingerprint,
            "container_bytes": predecessor.container_bytes,
            "container_sha256": predecessor.container_sha256,
            "publication_plan_sha256": predecessor_plan,
        },
        "successor": {
            "source_fingerprint": successor.source_fingerprint,
            "container_bytes": successor.container_bytes,
            "container_sha256": successor.container_sha256,
            "publication_plan_sha256": successor_plan,
        },
        "cases": cases,
        "verified": True,
    }


def _timeout_argument(value: str) -> float:
    try:
        result = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("timeout must be a number") from error
    if not math.isfinite(result) or not 0.1 <= result <= 300.0:
        raise argparse.ArgumentTypeError("timeout must be between 0.1 and 300 seconds")
    return result


def _resolve_worker(raw: str) -> Path:
    try:
        path = Path(raw).expanduser().resolve(strict=True)
        metadata = path.stat()
    except OSError as error:
        raise CampaignError("worker executable does not exist") from error
    _require(stat.S_ISREG(metadata.st_mode), "worker is not a regular file")
    _require(os.access(path, os.X_OK), "worker is not executable")
    return path


def _prepare_output_directory(raw: str) -> Path:
    path = Path(raw).expanduser()
    _require(not path.is_symlink(), "campaign output is a symlink")
    try:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise CampaignError("cannot create campaign directory") from error
    _require(resolved.is_dir(), "campaign output is not a directory")
    _require(not any(resolved.iterdir()), "campaign output must be empty")
    return resolved


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run the eight-phase durable GLRT host-process-death campaign "
            "against a caller-built worker."
        )
    )
    parser.add_argument(
        "--worker",
        required=True,
        metavar="PATH",
        help="prebuilt runtime_image_durable_worker executable (never built here)",
    )
    parser.add_argument(
        "--directory",
        metavar="PATH",
        help="new or empty retained evidence directory (temporary if omitted)",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=_timeout_argument,
        default=DEFAULT_TIMEOUT_SECONDS,
        metavar="SECONDS",
        help=f"per-process timeout (default: {DEFAULT_TIMEOUT_SECONDS:g})",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        worker = _resolve_worker(args.worker)
        if args.directory is not None:
            root = _prepare_output_directory(args.directory)
            report = run_campaign(
                worker=worker,
                directory=root,
                timeout_seconds=args.timeout_seconds,
            )
        else:
            with tempfile.TemporaryDirectory(
                prefix="glacier-runtime-image-durable-"
            ) as raw_root:
                root = Path(raw_root).resolve(strict=True)
                report = run_campaign(
                    worker=worker,
                    directory=root,
                    timeout_seconds=args.timeout_seconds,
                )
        print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
        return 0
    except (CampaignError, OSError) as error:
        print(f"runtime-image durable recovery failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
