"""Host-process-death campaign for durable Safetensors conversion.

The caller supplies a prebuilt Zig worker.  This controller never builds it.
On POSIX it stops each victim with a real ``SIGKILL`` after accepting one
bounded canonical ready frame.  Before every recovery it independently parses
the visible ``.glacier`` target and admits only the byte-exact predecessor or
successor allowed by the publication boundary.

The evidence covers host process death and the worker's file/directory sync
protocol.  It does not emulate or claim physical power-loss persistence,
storage-controller cache persistence, or remote-filesystem semantics.
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
import time
from typing import Callable, Mapping, Sequence, cast
import zlib


READY_SCHEMA = "glacier.model-conversion-durable-recovery/ready-v1"
RESULT_SCHEMA = "glacier.model-conversion-durable-recovery/result-v1"
CAMPAIGN_SCHEMA = "glacier.model-conversion-durable-recovery/campaign-v1"

CRASH_PHASES = (
    "stale_candidate_removed",
    "candidate_created",
    "candidate_page_progress",
    "candidate_encoded",
    "candidate_synced",
    "candidate_validated",
    "target_replaced",
    "directory_committed",
)
PRE_RENAME_PHASES = frozenset(CRASH_PHASES[:6])
CANDIDATE_VISIBLE_PHASES = frozenset(CRASH_PHASES[1:6])
COMPLETE_CANDIDATE_PHASES = frozenset(
    ("candidate_encoded", "candidate_synced", "candidate_validated")
)
STALE_ON_RECOVERY_PHASES = CANDIDATE_VISIBLE_PHASES

DEFAULT_TIMEOUT_SECONDS = 20.0
SOURCE_NAME = "model-conversion-source.safetensors"
TARGET_NAME = "model-conversion-output.glacier"
LOCK_NAME = ".glacier-conversion-publication.lock-v1"
CANDIDATE_NAME = ".glacier-conversion-publication.candidate-v1"

MAX_JSON_FRAME_BYTES = 16 * 1024
MAX_STDERR_BYTES = 16 * 1024
MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_GLACIER_BYTES = 4 * 1024 * 1024
MAX_PAGES = 4096
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1

GLACIER_MAGIC = b"GLAC"
GLACIER_VERSION = 1
GLACIER_HEADER_SIZE = 256
GLACIER_HEADER_PACKED_SIZE = 56
PAGE_ENTRY_SIZE = 64
PAGE_SIZE_BYTES = 1 << 18
PAGE_SIZE_LOG2 = 18
CONVERSION_WORKSPACE_BYTES_PEAK = 64 * 1024
QUANT_PAYLOAD_MAGIC = 0x514F4954
QUANT_SUB_HEADER_SIZE = 16
TENSOR_KINDS = frozenset((*range(16), 255))
RAW_PRECISION_BYTES = {0: 2, 1: 2, 6: 4}
QUANT_PRECISIONS = frozenset((2, 3))

METADATA_SCHEMA = "glacier.model-conversion/v1"
FIXTURE_ARCHITECTURE = "durable-recovery-fixture-v1"
METADATA_CREATED_BY = "glacier-convert 0.2.0"
METADATA_KEYS = (
    "schema",
    "architecture",
    "num_pages",
    "page_size_bytes",
    "source_bytes",
    "source_sha256",
    "conversion_profile_sha256",
    "conversion_plan_sha256",
    "created_by",
)

PUBLICATION_ABI = 0x474C_4450_0000_0002
CONVERSION_PROFILE_ABI = 0x474C_4350_0000_0001
CONVERSION_PLAN_ABI = 0x474C_434E_0000_0001
PUBLICATION_PLAN_DOMAIN = b"glacier-conversion-publication-plan-v2\x00"

READY_KEYS = (
    "schema",
    "mode",
    "pid",
    "disposition",
    "phase",
    "crash_point",
    "source_name",
    "target_name",
    "source_bytes",
    "source_sha256",
    "publication_plan_sha256",
    "host_process_recovery",
    "power_loss_emulated",
)
RESULT_KEYS = (
    "schema",
    "mode",
    "pid",
    "disposition",
    "source_name",
    "target_name",
    "source_bytes",
    "output_bytes",
    "num_pages",
    "conversion_workspace_bytes_peak",
    "source_sha256",
    "output_sha256",
    "conversion_profile_sha256",
    "conversion_plan_sha256",
    "publication_plan_sha256",
    "stale_candidate_removed",
    "verified",
    "host_process_recovery",
    "power_loss_emulated",
)


class CampaignError(RuntimeError):
    """The worker protocol, GLAC wire, or recovery invariant failed."""


@dataclass(frozen=True)
class SourceIdentity:
    """Byte-exact identity of the fixture source."""

    source_bytes: int
    source_sha256: str


@dataclass(frozen=True)
class PageFacts:
    """Strictly decoded page-index and payload facts."""

    page_id: int
    layer_idx: int
    tensor_kind: int
    row_start: int
    row_end: int
    precision: int
    quant_group: int
    data_offset: int
    data_len: int
    crc32: int
    payload_sha256: str


@dataclass(frozen=True)
class GlacierFacts:
    """Semantic roots plus full identity of one admitted GLAC v1 file."""

    container_bytes: int
    container_sha256: str
    metadata_sha256: str
    architecture: str
    num_pages: int
    page_size_bytes: int
    source_bytes: int
    source_sha256: str
    conversion_profile_sha256: str
    conversion_plan_sha256: str
    pages: tuple[PageFacts, ...]


@dataclass(frozen=True)
class BoundaryExpectation:
    """Allowed namespace state at one durable publication boundary."""

    post_kill_target: str
    candidate_visible: bool
    candidate_complete: bool
    recovery_disposition: str
    recovery_removes_stale_candidate: bool


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CampaignError(message)


def _is_int(value: object) -> bool:
    return type(value) is int


def _required_u64(
    frame: Mapping[str, object],
    name: str,
    *,
    minimum: int = 0,
) -> int:
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


def _decode_canonical_json(encoded: bytes, *, where: str) -> dict[str, object]:
    _require(0 < len(encoded) <= MAX_JSON_FRAME_BYTES, f"invalid {where} size")
    _require(b"\r" not in encoded and b"\n" not in encoded, f"{where} has newline")
    try:
        text = encoded.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CampaignError(f"{where} is not UTF-8") from error
    try:
        value = json.loads(
            text,
            object_pairs_hook=_pairs_without_duplicates,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        if isinstance(error, CampaignError):
            raise
        raise CampaignError(f"invalid {where}") from error
    _require(type(value) is dict, f"{where} is not an object")
    canonical = json.dumps(value, ensure_ascii=True, separators=(",", ":"))
    _require(text == canonical, f"{where} is not canonical compact JSON")
    return cast(dict[str, object], value)


def decode_canonical_json_line(line: bytes) -> dict[str, object]:
    """Decode one newline-free, bounded, canonical JSON worker frame."""

    return _decode_canonical_json(line, where="JSON frame")


def _safe_regular_bytes(
    path: Path,
    *,
    minimum_bytes: int,
    maximum_bytes: int,
) -> bytes:
    """Read one pinned regular file without following its final path link."""

    flags = os.O_RDONLY
    for option in ("O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK"):
        flags |= cast(int, getattr(os, option, 0))
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
            minimum_bytes <= before.st_size <= maximum_bytes,
            f"{path.name} size is outside its bound",
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
        fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        _require(
            tuple(getattr(before, field) for field in fields)
            == tuple(getattr(after, field) for field in fields),
            f"{path.name} changed while reading",
        )
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def source_identity(path: Path) -> SourceIdentity:
    """Hash the bounded fixture source independently of the Zig worker."""

    encoded = _safe_regular_bytes(
        path,
        minimum_bytes=9,
        maximum_bytes=MAX_SOURCE_BYTES,
    )
    return SourceIdentity(
        source_bytes=len(encoded),
        source_sha256=hashlib.sha256(encoded).hexdigest(),
    )


def _metadata_digest(value: Mapping[str, object], name: str) -> str:
    return _required_digest(value, name)


def _parse_metadata(
    encoded: bytes,
    *,
    expected_num_pages: int,
) -> tuple[dict[str, object], str]:
    metadata = _decode_canonical_json(encoded, where="GLAC metadata")
    _require(tuple(metadata) == METADATA_KEYS, "GLAC metadata roots changed")
    _require(metadata["schema"] == METADATA_SCHEMA, "wrong metadata schema")
    _require(
        metadata["architecture"] == FIXTURE_ARCHITECTURE,
        "wrong metadata architecture",
    )
    _require(
        metadata["created_by"] == METADATA_CREATED_BY,
        "wrong metadata producer",
    )
    _require(
        _required_u64(metadata, "num_pages", minimum=1) == expected_num_pages,
        "metadata page count mismatch",
    )
    _require(
        _required_u64(metadata, "page_size_bytes", minimum=1)
        == PAGE_SIZE_BYTES,
        "metadata page size mismatch",
    )
    _required_u64(metadata, "source_bytes", minimum=1)
    _metadata_digest(metadata, "source_sha256")
    _metadata_digest(metadata, "conversion_profile_sha256")
    _metadata_digest(metadata, "conversion_plan_sha256")
    return metadata, hashlib.sha256(encoded).hexdigest()


def _page_geometry(
    *,
    row_start: int,
    row_end: int,
    precision: int,
    quant_group: int,
) -> int:
    _require(row_end > row_start, "invalid page row range")
    element_count = row_end - row_start
    if precision in RAW_PRECISION_BYTES:
        _require(quant_group == 0, "raw page has a quantization group")
        expected = element_count * RAW_PRECISION_BYTES[precision]
        _require(expected <= PAGE_SIZE_BYTES, "raw page geometry is too large")
        return expected
    _require(precision in QUANT_PRECISIONS, "unsupported page precision")
    _require(0 < quant_group <= 255, "invalid quantization group")
    _require(
        element_count <= PAGE_SIZE_BYTES // 4,
        "quantized page geometry is too large",
    )
    group_count = (
        element_count // quant_group
        + int(element_count % quant_group != 0)
    )
    scales_bytes = group_count * 4
    packed_bytes = (
        element_count
        if precision == 2
        else element_count // 2 + int(element_count % 2 != 0)
    )
    return QUANT_SUB_HEADER_SIZE + scales_bytes + packed_bytes


def _validate_quant_header(
    payload: bytes,
    *,
    precision: int,
    quant_group: int,
    element_count: int,
) -> None:
    _require(
        len(payload) >= QUANT_SUB_HEADER_SIZE,
        "truncated quantized page header",
    )
    magic, encoded_elements, encoded_group = struct.unpack_from(
        "<III",
        payload,
        0,
    )
    encoded_precision = payload[12]
    _require(magic == QUANT_PAYLOAD_MAGIC, "bad quantized page magic")
    _require(
        encoded_elements == element_count
        and encoded_group == quant_group,
        "quantized page geometry mismatch",
    )
    expected_precision = 0 if precision == 2 else 1
    _require(
        encoded_precision == expected_precision,
        "quantized page precision mismatch",
    )
    _require(
        not any(payload[13:16]),
        "quantized page reserved bytes are non-zero",
    )


def parse_glacier_v1(path: Path) -> GlacierFacts:
    """Strictly parse, CRC-check, and hash one portable GLAC v1 artifact."""

    encoded = _safe_regular_bytes(
        path,
        minimum_bytes=GLACIER_HEADER_SIZE,
        maximum_bytes=MAX_GLACIER_BYTES,
    )
    _require(encoded[:4] == GLACIER_MAGIC, "bad GLAC magic")
    version, header_size = struct.unpack_from("<HH", encoded, 4)
    _require(version == GLACIER_VERSION, "wrong GLAC version")
    _require(header_size == GLACIER_HEADER_SIZE, "wrong GLAC header size")
    (
        meta_offset,
        meta_len,
        num_pages,
        page_index_offset,
        page_data_offset,
    ) = struct.unpack_from("<QQQQQ", encoded, 8)
    page_size_log2, reserved = struct.unpack_from("<II", encoded, 48)
    _require(page_size_log2 == PAGE_SIZE_LOG2, "wrong GLAC page size")
    _require(reserved == 0, "GLAC header reserved field is non-zero")
    _require(
        not any(encoded[GLACIER_HEADER_PACKED_SIZE:GLACIER_HEADER_SIZE]),
        "GLAC header reserved bytes are non-zero",
    )
    _require(meta_offset == GLACIER_HEADER_SIZE, "bad metadata offset")
    _require(0 < meta_len <= MAX_JSON_FRAME_BYTES, "bad metadata length")
    _require(0 < num_pages <= MAX_PAGES, "bad page count")
    meta_end = meta_offset + meta_len
    _require(meta_end <= len(encoded), "truncated GLAC metadata")
    _require(page_index_offset == meta_end, "non-contiguous GLAC metadata")
    index_bytes = num_pages * PAGE_ENTRY_SIZE
    index_end = page_index_offset + index_bytes
    _require(index_end <= len(encoded), "truncated GLAC page index")
    _require(page_data_offset == index_end, "non-contiguous GLAC page index")

    metadata, metadata_sha256 = _parse_metadata(
        encoded[meta_offset:meta_end],
        expected_num_pages=num_pages,
    )

    pages: list[PageFacts] = []
    expected_data_offset = page_data_offset
    for index in range(num_pages):
        entry_offset = page_index_offset + index * PAGE_ENTRY_SIZE
        entry = encoded[entry_offset : entry_offset + PAGE_ENTRY_SIZE]
        (
            page_id,
            layer_idx,
            tensor_kind,
            row_start,
            row_end,
            precision,
            quant_group,
            reserved1,
            data_offset,
            data_len,
            crc32,
            reserved2,
            reserved3,
        ) = struct.unpack("<QIIQQBBHQQIII", entry)
        _require(page_id == index, f"page {index} has a non-canonical ID")
        _require(tensor_kind in TENSOR_KINDS, f"page {index} has a bad kind")
        _require(
            reserved1 == reserved2 == reserved3 == 0,
            f"page {index} reserved fields are non-zero",
        )
        expected_len = _page_geometry(
            row_start=row_start,
            row_end=row_end,
            precision=precision,
            quant_group=quant_group,
        )
        _require(
            data_len == expected_len,
            f"page {index} geometry does not bind its payload length",
        )
        _require(
            data_offset == expected_data_offset,
            f"page {index} payload is not contiguous",
        )
        payload_end = data_offset + data_len
        _require(payload_end <= len(encoded), f"page {index} is truncated")
        payload = encoded[data_offset:payload_end]
        if precision in QUANT_PRECISIONS:
            _validate_quant_header(
                payload,
                precision=precision,
                quant_group=quant_group,
                element_count=row_end - row_start,
            )
        _require(
            zlib.crc32(payload) & MAX_U32 == crc32,
            f"page {index} CRC mismatch",
        )
        pages.append(
            PageFacts(
                page_id=page_id,
                layer_idx=layer_idx,
                tensor_kind=tensor_kind,
                row_start=row_start,
                row_end=row_end,
                precision=precision,
                quant_group=quant_group,
                data_offset=data_offset,
                data_len=data_len,
                crc32=crc32,
                payload_sha256=hashlib.sha256(payload).hexdigest(),
            )
        )
        expected_data_offset = payload_end
    _require(
        expected_data_offset == len(encoded),
        "GLAC container has trailing bytes",
    )

    return GlacierFacts(
        container_bytes=len(encoded),
        container_sha256=hashlib.sha256(encoded).hexdigest(),
        metadata_sha256=metadata_sha256,
        architecture=cast(str, metadata["architecture"]),
        num_pages=num_pages,
        page_size_bytes=_required_u64(metadata, "page_size_bytes"),
        source_bytes=_required_u64(metadata, "source_bytes"),
        source_sha256=_metadata_digest(metadata, "source_sha256"),
        conversion_profile_sha256=_metadata_digest(
            metadata,
            "conversion_profile_sha256",
        ),
        conversion_plan_sha256=_metadata_digest(
            metadata,
            "conversion_plan_sha256",
        ),
        pages=tuple(pages),
    )


def _validate_worker_fixture(facts: GlacierFacts) -> None:
    """Bind the generic parser to the worker's three-page fixture model."""

    _require(facts.num_pages == 3, "worker fixture page count changed")
    expected_classification = ((1, 1), (2, 6), (0, 0))
    for index, (page, classification) in enumerate(
        zip(facts.pages, expected_classification)
    ):
        _require(
            (page.layer_idx, page.tensor_kind) == classification,
            f"worker fixture page {index} classification changed",
        )
        _require(
            (
                page.row_start,
                page.row_end,
                page.precision,
                page.quant_group,
                page.data_len,
            )
            == (0, 65_536, 6, 0, PAGE_SIZE_BYTES),
            f"worker fixture page {index} geometry changed",
        )


def publication_plan_sha256(
    source: SourceIdentity,
    *,
    target_name: str = TARGET_NAME,
) -> str:
    """Independently reproduce the durable conversion publication plan."""

    target = target_name.encode("utf-8")
    architecture = FIXTURE_ARCHITECTURE.encode("utf-8")
    digest = hashlib.sha256()
    digest.update(PUBLICATION_PLAN_DOMAIN)
    digest.update(struct.pack("<Q", PUBLICATION_ABI))
    digest.update(struct.pack("<Q", CONVERSION_PROFILE_ABI))
    digest.update(struct.pack("<Q", CONVERSION_PLAN_ABI))
    digest.update(struct.pack("<Q", len(target)))
    digest.update(target)
    digest.update(struct.pack("<H", GLACIER_VERSION))
    digest.update(struct.pack("<Q", source.source_bytes))
    digest.update(bytes.fromhex(source.source_sha256))
    digest.update(struct.pack("<Q", PAGE_SIZE_BYTES))
    digest.update(struct.pack("<Q", len(architecture)))
    digest.update(architecture)
    digest.update(struct.pack("<B", 0))
    return digest.hexdigest()


def boundary_expectation(phase: str) -> BoundaryExpectation:
    """Return the only namespace state admitted after a kill at ``phase``."""

    _require(phase in CRASH_PHASES, "unknown crash phase")
    before_rename = phase in PRE_RENAME_PHASES
    candidate_visible = phase in CANDIDATE_VISIBLE_PHASES
    return BoundaryExpectation(
        post_kill_target="predecessor" if before_rename else "successor",
        candidate_visible=candidate_visible,
        candidate_complete=phase in COMPLETE_CANDIDATE_PHASES,
        recovery_disposition="published" if before_rename else "already_current",
        recovery_removes_stale_candidate=(
            phase in STALE_ON_RECOVERY_PHASES
        ),
    )


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
        frame = decode_canonical_json_line(bytes(stdout[:-1]))
        return frame, return_code, process.pid
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
                frame = decode_canonical_json_line(bytes(stdout[:newline]))
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


def validate_ready_frame(
    frame: dict[str, object],
    *,
    process_pid: int,
    expected_phase: str,
    expected_source: SourceIdentity,
    expected_plan_sha256: str,
) -> None:
    """Validate the complete ready-frame schema and recovery scope."""

    _require(tuple(frame) == READY_KEYS, "ready frame shape changed")
    _require(frame["schema"] == READY_SCHEMA, "wrong ready schema")
    _require(frame["mode"] == "victim", "wrong ready mode")
    _require(frame["disposition"] == "ready", "wrong ready disposition")
    _require(frame["phase"] == "victim_ready", "wrong ready phase")
    _require(
        _required_u64(frame, "pid", minimum=1) == process_pid,
        "ready PID does not identify the victim",
    )
    _require(frame["crash_point"] == expected_phase, "wrong crash point")
    _require(frame["source_name"] == SOURCE_NAME, "wrong ready source")
    _require(frame["target_name"] == TARGET_NAME, "wrong ready target")
    _require(
        _required_u64(frame, "source_bytes", minimum=1)
        == expected_source.source_bytes,
        "ready source size changed",
    )
    _require(
        _required_digest(frame, "source_sha256")
        == expected_source.source_sha256,
        "ready source digest changed",
    )
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


def validate_result_frame(
    frame: dict[str, object],
    *,
    expected_process_pid: int,
    expected_mode: str,
    expected_disposition: str,
    expected_source: SourceIdentity,
    expected_artifact: GlacierFacts,
    expected_plan_sha256: str,
    expected_stale_candidate_removed: bool,
) -> None:
    """Validate the complete result schema against independent file facts."""

    _require(tuple(frame) == RESULT_KEYS, "result frame shape changed")
    _require(frame["schema"] == RESULT_SCHEMA, "wrong result schema")
    _require(frame["mode"] == expected_mode, "wrong result mode")
    _require(
        _required_u64(frame, "pid", minimum=1) == expected_process_pid,
        "result PID does not identify the worker",
    )
    _require(
        frame["disposition"] == expected_disposition,
        "wrong publication disposition",
    )
    _require(frame["source_name"] == SOURCE_NAME, "wrong result source")
    _require(frame["target_name"] == TARGET_NAME, "wrong result target")
    _require(
        _required_u64(frame, "source_bytes", minimum=1)
        == expected_source.source_bytes
        == expected_artifact.source_bytes,
        "result source size mismatch",
    )
    _require(
        _required_u64(frame, "output_bytes", minimum=1)
        == expected_artifact.container_bytes,
        "result output size mismatch",
    )
    _require(
        _required_u64(frame, "num_pages", minimum=1)
        == expected_artifact.num_pages,
        "result page count mismatch",
    )
    expected_workspace = (
        0
        if expected_mode == "audit"
        else CONVERSION_WORKSPACE_BYTES_PEAK
    )
    _require(
        _required_u64(frame, "conversion_workspace_bytes_peak")
        == expected_workspace,
        "result conversion workspace changed",
    )
    _require(
        _required_digest(frame, "source_sha256")
        == expected_source.source_sha256
        == expected_artifact.source_sha256,
        "result source digest mismatch",
    )
    _require(
        _required_digest(frame, "output_sha256")
        == expected_artifact.container_sha256,
        "result output digest mismatch",
    )
    _require(
        _required_digest(frame, "conversion_profile_sha256")
        == expected_artifact.conversion_profile_sha256,
        "result conversion profile changed",
    )
    _require(
        _required_digest(frame, "conversion_plan_sha256")
        == expected_artifact.conversion_plan_sha256,
        "result conversion plan changed",
    )
    _require(
        _required_digest(frame, "publication_plan_sha256")
        == expected_plan_sha256,
        "result publication plan changed",
    )
    _require(
        _required_bool(frame, "stale_candidate_removed")
        == expected_stale_candidate_removed,
        "stale-candidate receipt changed",
    )
    _require(_required_bool(frame, "verified"), "worker did not verify its result")
    _require(
        _required_bool(frame, "host_process_recovery"),
        "worker did not claim host-process recovery",
    )
    _require(
        not _required_bool(frame, "power_loss_emulated"),
        "worker claimed power-loss emulation",
    )


def _run_result_worker(
    worker: Path,
    mode: str,
    directory: Path,
    *,
    timeout_seconds: float,
) -> tuple[dict[str, object], int]:
    frame, return_code, process_pid = _capture_normal_frame(
        (str(worker), mode, str(directory)),
        timeout_seconds=timeout_seconds,
    )
    _require(return_code == 0, f"{mode} worker exited unsuccessfully")
    return frame, process_pid


def _run_victim(
    worker: Path,
    directory: Path,
    phase: str,
    *,
    timeout_seconds: float,
    expected_source: SourceIdentity,
    expected_plan_sha256: str,
) -> dict[str, object]:
    _require(phase in CRASH_PHASES, "unknown crash phase")

    def validate(frame: dict[str, object], process_pid: int) -> None:
        validate_ready_frame(
            frame,
            process_pid=process_pid,
            expected_phase=phase,
            expected_source=expected_source,
            expected_plan_sha256=expected_plan_sha256,
        )

    return _capture_ready_and_sigkill(
        (str(worker), "victim", str(directory), phase),
        timeout_seconds=timeout_seconds,
        validate=validate,
    )


def _audit_namespace(
    directory: Path,
    *,
    candidate_expected: bool,
) -> tuple[Path, Path, Path]:
    expected = {SOURCE_NAME, TARGET_NAME, LOCK_NAME}
    if candidate_expected:
        expected.add(CANDIDATE_NAME)
    try:
        entries = {entry.name: entry for entry in os.scandir(directory)}
    except OSError as error:
        raise CampaignError("cannot inspect campaign namespace") from error
    _require(set(entries) == expected, "campaign namespace has extra entries")
    for name, entry in entries.items():
        metadata = entry.stat(follow_symlinks=False)
        _require(stat.S_ISREG(metadata.st_mode), f"{name} is not regular")
        _require(metadata.st_nlink == 1, f"{name} has multiple links")
        _require(
            metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0,
            f"{name} is group/world writable",
        )
        if name in (LOCK_NAME, CANDIDATE_NAME, SOURCE_NAME):
            _require(
                metadata.st_mode & 0o077 == 0,
                f"{name} permissions are not private",
            )
        if name == LOCK_NAME:
            _require(metadata.st_size == 0, "stable lock contents changed")
        elif name == CANDIDATE_NAME:
            _require(
                metadata.st_size <= MAX_GLACIER_BYTES,
                "candidate exceeds the artifact bound",
            )
        elif name == SOURCE_NAME:
            _require(
                9 <= metadata.st_size <= MAX_SOURCE_BYTES,
                "fixture source exceeds its bound",
            )
        else:
            _require(
                GLACIER_HEADER_SIZE <= metadata.st_size <= MAX_GLACIER_BYTES,
                "target exceeds the artifact bound",
            )
    return (
        directory / SOURCE_NAME,
        directory / TARGET_NAME,
        directory / CANDIDATE_NAME,
    )


def _make_case_directory(root: Path, name: str) -> Path:
    path = root / name
    try:
        path.mkdir(mode=0o700)
    except OSError as error:
        raise CampaignError(f"cannot create campaign case: {name}") from error
    return path


def _require_source_matches(
    actual: SourceIdentity,
    artifact: GlacierFacts,
    where: str,
) -> None:
    _require(
        (
            actual.source_bytes,
            actual.source_sha256,
        )
        == (
            artifact.source_bytes,
            artifact.source_sha256,
        ),
        f"{where} source does not match metadata roots",
    )


def _require_exact(
    actual: GlacierFacts,
    expected: GlacierFacts,
    where: str,
) -> None:
    _require(actual == expected, f"{where} is not the byte-exact expected image")


def _validate_normal_result(
    frame: dict[str, object],
    *,
    process_pid: int,
    mode: str,
    disposition: str,
    source: SourceIdentity,
    artifact: GlacierFacts,
    plan_sha256: str,
    stale_candidate_removed: bool = False,
) -> None:
    validate_result_frame(
        frame,
        expected_process_pid=process_pid,
        expected_mode=mode,
        expected_disposition=disposition,
        expected_source=source,
        expected_artifact=artifact,
        expected_plan_sha256=plan_sha256,
        expected_stale_candidate_removed=stale_candidate_removed,
    )


def _identity_summary(
    source: SourceIdentity,
    artifact: GlacierFacts,
    plan_sha256: str,
) -> dict[str, object]:
    return {
        "source_bytes": source.source_bytes,
        "source_sha256": source.source_sha256,
        "container_bytes": artifact.container_bytes,
        "num_pages": artifact.num_pages,
        "container_sha256": artifact.container_sha256,
        "metadata_sha256": artifact.metadata_sha256,
        "conversion_profile_sha256": artifact.conversion_profile_sha256,
        "conversion_plan_sha256": artifact.conversion_plan_sha256,
        "publication_plan_sha256": plan_sha256,
    }


def run_campaign(
    *,
    worker: Path,
    directory: Path,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, object]:
    """Run all eight primary crash phases and return JSON-ready evidence."""

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
    seed_frame, seed_pid = _run_result_worker(
        worker,
        "seed",
        baseline,
        timeout_seconds=timeout_seconds,
    )
    seed_source_path, seed_target_path, _ = _audit_namespace(
        baseline,
        candidate_expected=False,
    )
    predecessor_source = source_identity(seed_source_path)
    predecessor = parse_glacier_v1(seed_target_path)
    _validate_worker_fixture(predecessor)
    _require_source_matches(predecessor_source, predecessor, "predecessor")
    predecessor_plan = publication_plan_sha256(predecessor_source)
    _validate_normal_result(
        seed_frame,
        process_pid=seed_pid,
        mode="seed",
        disposition="published",
        source=predecessor_source,
        artifact=predecessor,
        plan_sha256=predecessor_plan,
    )

    successor_frame, successor_pid = _run_result_worker(
        worker,
        "recover",
        baseline,
        timeout_seconds=timeout_seconds,
    )
    successor_source_path, successor_target_path, _ = _audit_namespace(
        baseline,
        candidate_expected=False,
    )
    successor_source = source_identity(successor_source_path)
    successor = parse_glacier_v1(successor_target_path)
    _validate_worker_fixture(successor)
    _require_source_matches(successor_source, successor, "successor")
    successor_plan = publication_plan_sha256(successor_source)
    _validate_normal_result(
        successor_frame,
        process_pid=successor_pid,
        mode="recover",
        disposition="published",
        source=successor_source,
        artifact=successor,
        plan_sha256=successor_plan,
    )
    _require(
        predecessor_source != successor_source
        and predecessor.container_sha256 != successor.container_sha256
        and predecessor.conversion_plan_sha256
        != successor.conversion_plan_sha256,
        "predecessor and successor identities are not distinct",
    )
    _require(
        predecessor_plan != successor_plan,
        "predecessor and successor publication plans collide",
    )

    audit_frame, audit_pid = _run_result_worker(
        worker,
        "audit",
        baseline,
        timeout_seconds=timeout_seconds,
    )
    _validate_normal_result(
        audit_frame,
        process_pid=audit_pid,
        mode="audit",
        disposition="observed",
        source=successor_source,
        artifact=successor,
        plan_sha256=successor_plan,
    )
    _, audited_target_path, _ = _audit_namespace(
        baseline,
        candidate_expected=False,
    )
    _require_exact(
        parse_glacier_v1(audited_target_path),
        successor,
        "baseline audit",
    )

    cases: list[dict[str, object]] = []
    for phase_index, phase in enumerate(CRASH_PHASES):
        boundary = boundary_expectation(phase)
        case = _make_case_directory(
            directory,
            f"case-{phase_index:02d}-{phase.replace('_', '-')}",
        )
        case_seed_frame, case_seed_pid = _run_result_worker(
            worker,
            "seed",
            case,
            timeout_seconds=timeout_seconds,
        )
        case_source_path, case_target_path, _ = _audit_namespace(
            case,
            candidate_expected=False,
        )
        case_predecessor_source = source_identity(case_source_path)
        _require(
            case_predecessor_source == predecessor_source,
            f"{phase} seed source identity changed",
        )
        _require_exact(
            parse_glacier_v1(case_target_path),
            predecessor,
            f"{phase} seed target",
        )
        _validate_normal_result(
            case_seed_frame,
            process_pid=case_seed_pid,
            mode="seed",
            disposition="published",
            source=predecessor_source,
            artifact=predecessor,
            plan_sha256=predecessor_plan,
        )

        setup_sigkill = phase == "stale_candidate_removed"
        if setup_sigkill:
            _run_victim(
                worker,
                case,
                "candidate_created",
                timeout_seconds=timeout_seconds,
                expected_source=successor_source,
                expected_plan_sha256=successor_plan,
            )
            setup_source_path, setup_target_path, _ = _audit_namespace(
                case,
                candidate_expected=True,
            )
            _require(
                source_identity(setup_source_path) == successor_source,
                "stale-candidate setup source changed",
            )
            _require_exact(
                parse_glacier_v1(setup_target_path),
                predecessor,
                "stale-candidate setup target",
            )

        _run_victim(
            worker,
            case,
            phase,
            timeout_seconds=timeout_seconds,
            expected_source=successor_source,
            expected_plan_sha256=successor_plan,
        )
        killed_source_path, killed_target_path, killed_candidate_path = (
            _audit_namespace(
                case,
                candidate_expected=boundary.candidate_visible,
            )
        )
        _require(
            source_identity(killed_source_path) == successor_source,
            f"{phase} post-kill source changed",
        )

        # This strict independent parse occurs before recovery.  Equality with
        # exactly one boundary-approved baseline is the admission decision.
        after_kill = parse_glacier_v1(killed_target_path)
        allowed_target = (
            predecessor
            if boundary.post_kill_target == "predecessor"
            else successor
        )
        _require_exact(after_kill, allowed_target, f"{phase} post-kill target")
        if boundary.candidate_complete:
            _require_exact(
                parse_glacier_v1(killed_candidate_path),
                successor,
                f"{phase} complete candidate",
            )

        recovered_frame, recovered_pid = _run_result_worker(
            worker,
            "recover",
            case,
            timeout_seconds=timeout_seconds,
        )
        _validate_normal_result(
            recovered_frame,
            process_pid=recovered_pid,
            mode="recover",
            disposition=boundary.recovery_disposition,
            source=successor_source,
            artifact=successor,
            plan_sha256=successor_plan,
            stale_candidate_removed=(
                boundary.recovery_removes_stale_candidate
            ),
        )
        recovered_source_path, recovered_target_path, _ = _audit_namespace(
            case,
            candidate_expected=False,
        )
        _require(
            source_identity(recovered_source_path) == successor_source,
            f"{phase} recovery source changed",
        )
        _require_exact(
            parse_glacier_v1(recovered_target_path),
            successor,
            f"{phase} recovery target",
        )

        retry_frame, retry_pid = _run_result_worker(
            worker,
            "recover",
            case,
            timeout_seconds=timeout_seconds,
        )
        _validate_normal_result(
            retry_frame,
            process_pid=retry_pid,
            mode="recover",
            disposition="already_current",
            source=successor_source,
            artifact=successor,
            plan_sha256=successor_plan,
        )
        _, retry_target_path, _ = _audit_namespace(
            case,
            candidate_expected=False,
        )
        _require_exact(
            parse_glacier_v1(retry_target_path),
            successor,
            f"{phase} second recovery target",
        )

        final_frame, final_pid = _run_result_worker(
            worker,
            "audit",
            case,
            timeout_seconds=timeout_seconds,
        )
        _validate_normal_result(
            final_frame,
            process_pid=final_pid,
            mode="audit",
            disposition="observed",
            source=successor_source,
            artifact=successor,
            plan_sha256=successor_plan,
        )
        _, final_target_path, _ = _audit_namespace(
            case,
            candidate_expected=False,
        )
        _require_exact(
            parse_glacier_v1(final_target_path),
            successor,
            f"{phase} final audit target",
        )

        cases.append(
            {
                "phase": phase,
                "post_kill_target": boundary.post_kill_target,
                "candidate_after_kill": boundary.candidate_visible,
                "complete_candidate_after_kill": boundary.candidate_complete,
                "recovery_disposition": boundary.recovery_disposition,
                "recovery_removed_stale_candidate": (
                    boundary.recovery_removes_stale_candidate
                ),
                "second_recovery_disposition": "already_current",
                "fixed_candidate_after_recovery": False,
                "setup_sigkill": setup_sigkill,
                "verified": True,
            }
        )

    _require(len(cases) == len(CRASH_PHASES), "campaign cardinality changed")
    _require(
        sum(bool(case["setup_sigkill"]) for case in cases) == 1,
        "stale-candidate setup cardinality changed",
    )
    return {
        "schema": CAMPAIGN_SCHEMA,
        "source_name": SOURCE_NAME,
        "target_name": TARGET_NAME,
        "crash_phases": list(CRASH_PHASES),
        "primary_sigkill_count": len(CRASH_PHASES),
        "setup_sigkill_count": 1,
        "normal_exit_count": 35,
        "host_process_recovery": True,
        "power_loss_emulated": False,
        "predecessor": _identity_summary(
            predecessor_source,
            predecessor,
            predecessor_plan,
        ),
        "successor": _identity_summary(
            successor_source,
            successor,
            successor_plan,
        ),
        "cases": cases,
        "verified": True,
    }


def _timeout_argument(value: str) -> float:
    try:
        result = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("timeout must be a number") from error
    if not math.isfinite(result) or not 0.1 <= result <= 300.0:
        raise argparse.ArgumentTypeError(
            "timeout must be between 0.1 and 300 seconds"
        )
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
            "Run the eight-phase durable model-conversion host-process-death "
            "campaign against a caller-built worker."
        )
    )
    parser.add_argument(
        "--worker",
        required=True,
        metavar="PATH",
        help=(
            "prebuilt model_conversion_durable_worker executable "
            "(never built here)"
        ),
    )
    parser.add_argument(
        "--directory",
        required=True,
        metavar="PATH",
        help="new or empty retained evidence directory",
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
        root = _prepare_output_directory(args.directory)
        report = run_campaign(
            worker=worker,
            directory=root,
            timeout_seconds=args.timeout_seconds,
        )
        print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
        return 0
    except (CampaignError, OSError) as error:
        print(f"model conversion durable recovery failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
