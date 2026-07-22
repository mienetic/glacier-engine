#!/usr/bin/env python3
"""Same-binary/two-GLRT PairNibble runtime A/B evidence harness.

The baseline is a prepared GLRT with separate gate/up records. The candidate
is a distinct prepared GLRT admitted under ``pair-nibble-required``. Every
observation is a fresh process, ABBA/BAAB blocked, tokenizer-pinned, greedy,
and required to emit exactly the same completion IDs. Telemetry and input
artifacts are fail-closed so this report cannot silently compare fallback or
mutated executions.
"""

from __future__ import annotations

import argparse
import array as array_module
import datetime as dt
import hashlib
import importlib.util
import json
import math
import mmap
import os
import platform
import random
import re
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


def _load_attention_support():
    """Load shared evidence helpers without trusting the caller's sys.path."""
    module_name = "_glacier_pair_nibble_attention_support"
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    path = Path(__file__).resolve().with_name("attention_ab.py")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load benchmark support module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


_attention = _load_attention_support()


def _load_resource_support():
    """Lazily load the strict Darwin resource parser when it is requested."""
    module_name = "_glacier_pair_nibble_resource_support"
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    bench_dir = Path(__file__).resolve().parent
    path = bench_dir / "resource_ab.py"
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load benchmark resource support module: {path}")
    module = importlib.util.module_from_spec(spec)
    previous_attention = sys.modules.get("attention_ab")
    inserted_path = str(bench_dir) not in sys.path
    if inserted_path:
        sys.path.insert(0, str(bench_dir))
    # resource_ab's historical imports are package-local bare imports. Pin its
    # common helper to this driver's already-fingerprinted support instance so
    # both modules share the same fail-closed HarnessError type.
    sys.modules["attention_ab"] = _attention
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    finally:
        if previous_attention is None:
            sys.modules.pop("attention_ab", None)
        else:
            sys.modules["attention_ab"] = previous_attention
        if inserted_path:
            sys.path.remove(str(bench_dir))
    return module


SCHEMA = "glacier.pair-nibble-runtime-ab/result-v1"
VARIANTS = ("separate", "pair-nibble-required")
DEFAULT_SAMPLES_PER_VARIANT = 32
DEFAULT_WARMUPS_PER_VARIANT = 2
DEFAULT_SCHEDULE_SEED = 20_260_721
DEFAULT_BOOTSTRAP_SEED = 0x504149524E494242
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
PREFILL_CHUNK_ROWS = 256
SYSTEM_TIME_BINARY = Path("/usr/bin/time").resolve()
RESOURCE_RATIO_FIELDS = (
    "harness_wall_seconds",
    "time_real_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
    "time_cpu_seconds",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
RESOURCE_REQUIRED_POSITIVE_FIELDS = (
    "time_real_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
    "time_cpu_seconds",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
RESOURCE_MEDIAN_FIELDS = (
    "harness_wall_seconds",
    "time_real_seconds",
    "time_user_seconds",
    "time_sys_seconds",
    "time_cpu_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
RESOURCE_UNITS = {
    "harness_wall_seconds": "seconds",
    "time_real_seconds": "seconds",
    "time_user_seconds": "seconds",
    "time_sys_seconds": "seconds",
    "time_cpu_seconds": "seconds (user + sys)",
    "time_maximum_resident_set_size_bytes": "bytes",
    "time_peak_memory_footprint_bytes": "bytes",
    "time_instructions_retired": "count",
    "time_cycles_elapsed": "count",
}
GLRT_HEADER_SIZE = 512
GLRT_RECORD_SIZE = 160
GLRT_DATA_ALIGNMENT = 64
GLRT_STREAM_NAMES = (
    "packed_weights",
    "scales_f32",
    "scales_f16",
    "scales_f16_rows4",
    "raw",
)
GLRT_STREAM_RANGE_OFFSETS = (40, 56, 72, 88, 104)
GLRT_TENSOR_KINDS = frozenset((*range(16), 255))
GLRT_MLP_UP_KIND = 5
GLRT_MLP_GATE_KIND = 7
GLRT_OTHER_KIND = 255
GLRT_ROLE_TENSOR = 0
GLRT_ROLE_PAIR = 1
GLRT_ENCODING_RAW_F32 = 0
GLRT_ENCODING_INT4 = 1
GLRT_ENCODING_PAIR_NIBBLE = 2
GLRT_PACKED_ROW_MAJOR = 0
GLRT_PACKED_ROWS4_K16 = 1
GLRT_PACKED_NONE = 0xFFFF
GLRT_PAIR_ROWS4_K16 = 0
GLRT_PAIR_NONE = 0xFFFF
GLRT_PROOF_SCHEMA = "glacier.glrt-pair-equivalence/proof-v1"
GREEDY_ARGMAX_ABI = "474c4d4800000002"
_LOW_NIBBLE_TABLE = bytes(value & 0x0F for value in range(256))
_HIGH_NIBBLE_TABLE = bytes(value >> 4 for value in range(256))
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1
PAIR_NIBBLE_STORAGE_ABI = 0x47504E4200000001
PAIR_NIBBLE_EXECUTOR_ABI = 0x47504E4500000005
MAX_I64 = (1 << 63) - 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")

_PAIR_NIBBLE_RE = re.compile(
    r"^[^\S\r\n]*pair_nibble:[^\S\r\n]+policy=(separate|pair-nibble-required)"
    r"[^\S\r\n]+artifact=(separate|pair-nibble|source)"
    r"[^\S\r\n]+selected=(separate|pair-nibble)"
    r"[^\S\r\n]+admissions=([0-9]+)"
    r"[^\S\r\n]+artifact_layers=([0-9]+)"
    r"[^\S\r\n]+selected_layers=([0-9]+)"
    r"[^\S\r\n]+pair_weight_bytes=([0-9]+)"
    r"[^\S\r\n]+pair_scale_bytes=([0-9]+)"
    r"[^\S\r\n]+separate_gate_bytes=([0-9]+)"
    r"[^\S\r\n]+separate_up_bytes=([0-9]+)"
    r"[^\S\r\n]+prefill_m1=([0-9]+)"
    r"[^\S\r\n]+prefill_m4_groups=([0-9]+)"
    r"[^\S\r\n]+prefill_tail_dispatches=([0-9]+)"
    r"[^\S\r\n]+prefill_tail_rows=([0-9]+)"
    r"[^\S\r\n]+decode_m1=([0-9]+)"
    r"[^\S\r\n]+outputless_m1=([0-9]+)"
    r"[^\S\r\n]+activation_rows_quantized=([0-9]+)"
    r"[^\S\r\n]+selected_layer_rows=([0-9]+)"
    r"[^\S\r\n]+checked_dispatches=([0-9]+)"
    r"[^\S\r\n]+sealed_dispatches=([0-9]+)"
    r"[^\S\r\n]+fallbacks=([0-9]+)"
    r"[^\S\r\n]+rejects=([0-9]+)"
    r"[^\S\r\n]+storage_abi=([0-9a-f]{1,16})"
    r"[^\S\r\n]+executor_abi=([0-9a-f]{1,16})[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_DECODE_PLAN_RE = re.compile(
    r"^[^\S\r\n]*decode_plan:[^\S\r\n]+mode=(checked|sealed-required)"
    r"[^\S\r\n]+sets=([0-9]+)"
    r"[^\S\r\n]+set_bytes=([0-9]+)"
    r"[^\S\r\n]+layer_builds=([0-9]+)"
    r"[^\S\r\n]+layer_binds=([0-9]+)"
    r"[^\S\r\n]+checked_dispatches=([0-9]+)"
    r"[^\S\r\n]+sealed_dispatches=([0-9]+)"
    r"[^\S\r\n]+fallbacks=([0-9]+)"
    r"[^\S\r\n]+rejects=([0-9]+)"
    r"[^\S\r\n]+build_ms=([0-9]+(?:\.[0-9]+)?)"
    r"[^\S\r\n]+abi=([0-9a-f]{1,16})[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_TOTAL_RE = re.compile(
    r"^[^\S\r\n]*time:[^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*ms"
    r"[^\S\r\n]*\([^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*tok/s,"
    r"[^\S\r\n]*prefilled[^\S\r\n]+([0-9]+),[^\S\r\n]*prefill=(batch|serial)"
    r"[^\S\r\n]*\)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_GREEDY_OUTPUT_RE = re.compile(
    r"^[^\S\r\n]*greedy_output:[^\S\r\n]+mode="
    r"(materialized|logitless-required)"
    r"[^\S\r\n]+materialized_projections=([0-9]+)"
    r"[^\S\r\n]+logitless_projections=([0-9]+)"
    r"[^\S\r\n]+producer_rows=([0-9]+)"
    r"[^\S\r\n]+tile_output_bytes=([0-9]+)"
    r"[^\S\r\n]+argmax_scan_rows=([0-9]+)"
    r"[^\S\r\n]+scratch_bytes=([0-9]+)"
    r"[^\S\r\n]+materialized_logits_bytes=([0-9]+)"
    r"[^\S\r\n]+steady_state_reclaimed_bytes=([0-9]+)"
    r"[^\S\r\n]+fallbacks=([0-9]+)"
    r"[^\S\r\n]+rejects=([0-9]+)"
    r"[^\S\r\n]+abi=([0-9a-f]{1,16})[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)


HarnessError = _attention.HarnessError
canonical_ids_bytes = _attention.canonical_ids_bytes
parse_ids = _attention.parse_ids
sha256_bytes = _attention.sha256_bytes


@dataclass(frozen=True)
class Config:
    binary: Path
    separate_model: Path
    pair_model: Path
    ids: Path
    output: Path | None
    cwd: Path
    prefill: str = "batch"
    samples_per_variant: int = DEFAULT_SAMPLES_PER_VARIANT
    warmups_per_variant: int = DEFAULT_WARMUPS_PER_VARIANT
    new_tokens: int = 64
    threads: int = 4
    schedule_seed: int = DEFAULT_SCHEDULE_SEED
    bootstrap_seed: int = DEFAULT_BOOTSTRAP_SEED
    bootstrap_resamples: int = DEFAULT_BOOTSTRAP_RESAMPLES
    confidence: float = 0.95
    timeout_seconds: float = 3600.0
    overwrite: bool = False
    binary_sha256: str | None = None
    separate_model_sha256: str | None = None
    pair_model_sha256: str | None = None
    ids_sha256: str | None = None
    darwin_resources: bool = False
    time_binary: Path = Path("/usr/bin/time")
    time_sha256: str | None = None


@dataclass(frozen=True)
class GlrtHeader:
    record_count: int
    data_offset: int
    file_size: int
    source_fingerprint: str
    abi_fingerprint: str
    config_bytes: bytes
    config: Mapping[str, Any]
    header_sha256: str
    index_sha256: str

    def manifest(self) -> dict[str, Any]:
        return {
            "magic": "GLRT",
            "version": 2,
            "header_size": GLRT_HEADER_SIZE,
            "record_size": GLRT_RECORD_SIZE,
            "data_alignment": GLRT_DATA_ALIGNMENT,
            "record_count": self.record_count,
            "index_offset": GLRT_HEADER_SIZE,
            "data_offset": self.data_offset,
            "file_size": self.file_size,
            "source_fingerprint": self.source_fingerprint,
            "abi_fingerprint": self.abi_fingerprint,
            "config": dict(self.config),
            "config_bytes_sha256": sha256_bytes(self.config_bytes),
            "header_sha256": self.header_sha256,
            "index_sha256": self.index_sha256,
        }


@dataclass(frozen=True)
class GlrtRecord:
    index: int
    layer_idx: int
    kind: int
    encoding: int
    packed_layout: int
    group_size: int
    out_f: int
    in_f: int
    flags: int
    payload_crc32: int
    num_elements: int
    ranges: tuple[tuple[int, int], ...]
    role: int
    pair_nibble_layout: int
    stored_payload_digest: str
    descriptor_sha256: str
    canonical_descriptor_sha256: str
    stream_sha256: tuple[str | None, ...]
    payload_concat_sha256: str

    def identity(self) -> tuple[str, int, int]:
        if self.role == GLRT_ROLE_TENSOR:
            return ("tensor", self.layer_idx, self.kind)
        return ("role", self.layer_idx, self.role)

    def canonical_descriptor(self) -> dict[str, Any]:
        return {
            "layer_idx": self.layer_idx,
            "kind": self.kind,
            "encoding": self.encoding,
            "packed_layout": self.packed_layout,
            "group_size": self.group_size,
            "out_f": self.out_f,
            "in_f": self.in_f,
            "flags": self.flags,
            "num_elements": self.num_elements,
            "role": self.role,
            "pair_nibble_layout": self.pair_nibble_layout,
            "stream_lengths": {
                name: self.ranges[index][1]
                for index, name in enumerate(GLRT_STREAM_NAMES)
            },
        }

    def equivalence_manifest(self) -> dict[str, Any]:
        return {
            "identity": list(self.identity()),
            "canonical_descriptor": self.canonical_descriptor(),
            "canonical_descriptor_sha256": self.canonical_descriptor_sha256,
            "payload_crc32": f"{self.payload_crc32:08x}",
            "payload_concat_sha256": self.payload_concat_sha256,
            "stream_sha256": {
                name: self.stream_sha256[index]
                for index, name in enumerate(GLRT_STREAM_NAMES)
            },
        }

    def manifest(self) -> dict[str, Any]:
        return {
            "index": self.index,
            **self.equivalence_manifest(),
            "physical_ranges": {
                name: {"offset": self.ranges[index][0], "len": self.ranges[index][1]}
                for index, name in enumerate(GLRT_STREAM_NAMES)
            },
            "physical_descriptor_sha256": self.descriptor_sha256,
            "stored_descriptor_payload_sha256": self.stored_payload_digest,
            "stored_descriptor_payload_sha256_verified": True,
        }


@dataclass(frozen=True)
class GlrtImage:
    path: Path
    header: GlrtHeader
    records: tuple[GlrtRecord, ...]
    manifest: Mapping[str, Any]
    manifest_sha256: str


def _canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _canonical_json_sha256(value: Any) -> str:
    return sha256_bytes(_canonical_json_bytes(value))


def _mapped_sha256(mapped: mmap.mmap, start: int, length: int) -> str:
    view = memoryview(mapped)[start : start + length]
    try:
        return hashlib.sha256(view).hexdigest()
    finally:
        view.release()


def _mapped_crc32(mapped: mmap.mmap, start: int, length: int, seed: int = 0) -> int:
    view = memoryview(mapped)[start : start + length]
    try:
        return zlib.crc32(view, seed) & MAX_U32
    finally:
        view.release()


def _validate_glrt_record_descriptor(
    *,
    where: str,
    encoding: int,
    packed_layout: int,
    pair_nibble_layout: int,
    role: int,
    group_size: int,
    out_f: int,
    in_f: int,
    num_elements: int,
    ranges: tuple[tuple[int, int], ...],
) -> None:
    if out_f == 0 or in_f == 0 or num_elements != out_f * in_f:
        raise HarnessError(f"{where} has an invalid tensor shape")
    lengths = tuple(item[1] for item in ranges)
    packed_len, scales_f32_len, scales_f16_len, rows4_len, raw_len = lengths
    if encoding == GLRT_ENCODING_RAW_F32:
        if (
            role != GLRT_ROLE_TENSOR
            or packed_layout != GLRT_PACKED_NONE
            or pair_nibble_layout != GLRT_PAIR_NONE
            or group_size != 0
            or raw_len != num_elements * 4
            or any(lengths[index] != 0 for index in range(4))
        ):
            raise HarnessError(f"{where} has an invalid raw-f32 descriptor")
        return
    if encoding == GLRT_ENCODING_INT4:
        groups = (num_elements + group_size - 1) // group_size if group_size else 0
        if (
            role != GLRT_ROLE_TENSOR
            or pair_nibble_layout != GLRT_PAIR_NONE
            or packed_layout == GLRT_PACKED_NONE
            or group_size == 0
            or packed_len != (num_elements + 1) // 2
            or raw_len != 0
            or (scales_f32_len not in (0, groups * 4))
            or (scales_f16_len not in (0, groups * 2))
            or (rows4_len not in (0, groups * 2))
            or (scales_f32_len == scales_f16_len == rows4_len == 0)
        ):
            raise HarnessError(f"{where} has an invalid INT4 descriptor")
        if packed_layout == GLRT_PACKED_ROWS4_K16 and (
            out_f % 4 != 0 or in_f % 16 != 0 or rows4_len == 0
        ):
            raise HarnessError(f"{where} has invalid rows4/K16 geometry")
        return
    if encoding == GLRT_ENCODING_PAIR_NIBBLE:
        groups = out_f * (in_f // group_size) if group_size else 0
        if (
            role != GLRT_ROLE_PAIR
            or packed_layout != GLRT_PACKED_NONE
            or pair_nibble_layout != GLRT_PAIR_ROWS4_K16
            or group_size not in (8, 16)
            or out_f % 4 != 0
            or in_f % 16 != 0
            or in_f % group_size != 0
            or packed_len != num_elements
            or rows4_len != groups * 4
            or scales_f32_len != 0
            or scales_f16_len != 0
            or raw_len != 0
        ):
            raise HarnessError(f"{where} has an invalid PairNibble descriptor")
        return
    raise HarnessError(f"{where} has an unknown encoding")


def parse_glrt_image(path: Path, where: str) -> GlrtImage:
    """Strictly parse and cryptographically verify one current GLRT v2 image."""

    try:
        handle = path.open("rb")
    except OSError as error:
        raise HarnessError(f"cannot open {where}: {error}") from error
    with handle:
        try:
            mapped = mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ)
        except (OSError, ValueError) as error:
            raise HarnessError(f"cannot map {where}: {error}") from error
        with mapped:
            file_size = len(mapped)
            if file_size < GLRT_HEADER_SIZE:
                raise HarnessError(f"{where} has a truncated GLRT header")
            header_bytes = bytes(mapped[:GLRT_HEADER_SIZE])
            if header_bytes[0:4] != b"GLRT":
                raise HarnessError(f"{where} has bad GLRT magic")
            version, header_size, record_size, alignment = struct.unpack_from(
                "<HHHH", header_bytes, 4
            )
            if version != 2:
                raise HarnessError(f"{where} must be a current GLRT v2 image")
            if (
                header_size != GLRT_HEADER_SIZE
                or record_size != GLRT_RECORD_SIZE
                or alignment != GLRT_DATA_ALIGNMENT
            ):
                raise HarnessError(f"{where} has a non-canonical GLRT layout")
            flags = struct.unpack_from("<I", header_bytes, 12)[0]
            record_count, index_offset, data_offset, declared_size = struct.unpack_from(
                "<QQQQ", header_bytes, 16
            )
            if flags != 0 or record_count == 0:
                raise HarnessError(f"{where} has an invalid GLRT header")
            if index_offset != GLRT_HEADER_SIZE or declared_size != file_size:
                raise HarnessError(f"{where} has invalid GLRT file extents")
            index_length = record_count * GLRT_RECORD_SIZE
            index_end = index_offset + index_length
            if (
                index_end > MAX_U64
                or data_offset < index_end
                or data_offset > file_size
                or data_offset % GLRT_DATA_ALIGNMENT != 0
            ):
                raise HarnessError(f"{where} has invalid GLRT index/data extents")
            if header_bytes[140] > 1:
                raise HarnessError(f"{where} has an invalid tied-embedding flag")
            if any(header_bytes[141:144]) or any(header_bytes[160:]):
                raise HarnessError(f"{where} has non-zero GLRT header reserved bytes")
            config_values = struct.unpack_from("<7I", header_bytes, 112)
            rms_bits, rope_bits = struct.unpack_from("<II", header_bytes, 144)
            rms_eps, rope_theta = struct.unpack_from("<ff", header_bytes, 144)
            if any(value == 0 for value in config_values) or not (
                math.isfinite(rms_eps)
                and rms_eps > 0
                and math.isfinite(rope_theta)
                and rope_theta > 0
            ):
                raise HarnessError(f"{where} has an invalid GLRT config snapshot")
            expected_index_crc, expected_header_crc = struct.unpack_from(
                "<II", header_bytes, 152
            )
            header_crc_input = bytearray(header_bytes)
            header_crc_input[156:160] = b"\0\0\0\0"
            if (zlib.crc32(header_crc_input) & MAX_U32) != expected_header_crc:
                raise HarnessError(f"{where} GLRT header CRC mismatch")
            if _mapped_crc32(mapped, index_offset, index_length) != expected_index_crc:
                raise HarnessError(f"{where} GLRT index CRC mismatch")

            config_names = (
                "dim",
                "hidden_dim",
                "layers",
                "vocab",
                "heads",
                "head_dim",
                "kv_heads",
            )
            config: dict[str, Any] = dict(zip(config_names, config_values))
            config.update(
                {
                    "tie_embeddings": bool(header_bytes[140]),
                    "rms_eps": rms_eps,
                    "rms_eps_bits": f"{rms_bits:08x}",
                    "rope_theta": rope_theta,
                    "rope_theta_bits": f"{rope_bits:08x}",
                }
            )
            header = GlrtHeader(
                record_count=record_count,
                data_offset=data_offset,
                file_size=file_size,
                source_fingerprint=header_bytes[48:80].hex(),
                abi_fingerprint=header_bytes[80:112].hex(),
                config_bytes=header_bytes[112:152],
                config=config,
                header_sha256=sha256_bytes(header_bytes),
                index_sha256=_mapped_sha256(mapped, index_offset, index_length),
            )

            records: list[GlrtRecord] = []
            identities: set[tuple[str, int, int]] = set()
            payload_extents: list[tuple[int, int, int, str]] = []
            for index in range(record_count):
                start = index_offset + index * GLRT_RECORD_SIZE
                descriptor = bytes(mapped[start : start + GLRT_RECORD_SIZE])
                if any(descriptor[124:128]):
                    raise HarnessError(
                        f"{where} record {index} has non-zero reserved bytes"
                    )
                layer_idx, kind = struct.unpack_from("<II", descriptor, 0)
                encoding, packed_layout = struct.unpack_from("<HH", descriptor, 8)
                group_size, out_f, in_f, record_flags, payload_crc32 = (
                    struct.unpack_from("<IIIII", descriptor, 12)
                )
                num_elements = struct.unpack_from("<Q", descriptor, 32)[0]
                role, pair_layout = struct.unpack_from("<HH", descriptor, 120)
                if kind not in GLRT_TENSOR_KINDS:
                    raise HarnessError(f"{where} record {index} has a bad tensor kind")
                if encoding not in (
                    GLRT_ENCODING_RAW_F32,
                    GLRT_ENCODING_INT4,
                    GLRT_ENCODING_PAIR_NIBBLE,
                ):
                    raise HarnessError(f"{where} record {index} has a bad encoding")
                if packed_layout not in (
                    GLRT_PACKED_ROW_MAJOR,
                    GLRT_PACKED_ROWS4_K16,
                    GLRT_PACKED_NONE,
                ):
                    raise HarnessError(
                        f"{where} record {index} has a bad packed layout"
                    )
                if role not in (GLRT_ROLE_TENSOR, GLRT_ROLE_PAIR):
                    raise HarnessError(f"{where} record {index} has a bad role")
                if pair_layout not in (GLRT_PAIR_ROWS4_K16, GLRT_PAIR_NONE):
                    raise HarnessError(
                        f"{where} record {index} has a bad PairNibble layout"
                    )
                if record_flags != 0:
                    raise HarnessError(f"{where} record {index} has non-zero flags")

                ranges = tuple(
                    struct.unpack_from("<QQ", descriptor, offset)
                    for offset in GLRT_STREAM_RANGE_OFFSETS
                )
                for stream_index, (offset, length) in enumerate(ranges):
                    if (offset == 0) != (length == 0):
                        raise HarnessError(f"{where} record {index} has a bad range")
                    if length == 0:
                        continue
                    end = offset + length
                    if (
                        end > MAX_U64
                        or offset < data_offset
                        or offset % GLRT_DATA_ALIGNMENT != 0
                        or end > file_size
                    ):
                        raise HarnessError(
                            f"{where} record {index} payload is out of bounds"
                        )
                    payload_extents.append(
                        (offset, end, index, GLRT_STREAM_NAMES[stream_index])
                    )
                _validate_glrt_record_descriptor(
                    where=f"{where} record {index}",
                    encoding=encoding,
                    packed_layout=packed_layout,
                    pair_nibble_layout=pair_layout,
                    role=role,
                    group_size=group_size,
                    out_f=out_f,
                    in_f=in_f,
                    num_elements=num_elements,
                    ranges=ranges,
                )
                identity = (
                    ("tensor", layer_idx, kind)
                    if role == GLRT_ROLE_TENSOR
                    else ("role", layer_idx, role)
                )
                if identity in identities:
                    raise HarnessError(f"{where} contains duplicate record {identity}")
                identities.add(identity)

                crc = 0
                payload_hasher = hashlib.sha256()
                descriptor_payload_hasher = hashlib.sha256(descriptor[:128])
                stream_digests: list[str | None] = []
                for offset, length in ranges:
                    if length == 0:
                        stream_digests.append(None)
                        continue
                    view = memoryview(mapped)[offset : offset + length]
                    try:
                        crc = zlib.crc32(view, crc) & MAX_U32
                        payload_hasher.update(view)
                        descriptor_payload_hasher.update(view)
                        stream_digests.append(hashlib.sha256(view).hexdigest())
                    finally:
                        view.release()
                if crc != payload_crc32:
                    raise HarnessError(f"{where} record {index} payload CRC mismatch")
                stored_digest = descriptor[128:160]
                if not any(stored_digest):
                    raise HarnessError(f"{where} record {index} is missing its digest")
                actual_digest = descriptor_payload_hasher.digest()
                if actual_digest != stored_digest:
                    raise HarnessError(
                        f"{where} record {index} payload digest mismatch"
                    )
                canonical_descriptor = {
                    "layer_idx": layer_idx,
                    "kind": kind,
                    "encoding": encoding,
                    "packed_layout": packed_layout,
                    "group_size": group_size,
                    "out_f": out_f,
                    "in_f": in_f,
                    "flags": record_flags,
                    "num_elements": num_elements,
                    "role": role,
                    "pair_nibble_layout": pair_layout,
                    "stream_lengths": {
                        name: ranges[item][1]
                        for item, name in enumerate(GLRT_STREAM_NAMES)
                    },
                }
                records.append(
                    GlrtRecord(
                        index=index,
                        layer_idx=layer_idx,
                        kind=kind,
                        encoding=encoding,
                        packed_layout=packed_layout,
                        group_size=group_size,
                        out_f=out_f,
                        in_f=in_f,
                        flags=record_flags,
                        payload_crc32=payload_crc32,
                        num_elements=num_elements,
                        ranges=ranges,
                        role=role,
                        pair_nibble_layout=pair_layout,
                        stored_payload_digest=stored_digest.hex(),
                        descriptor_sha256=sha256_bytes(descriptor),
                        canonical_descriptor_sha256=_canonical_json_sha256(
                            canonical_descriptor
                        ),
                        stream_sha256=tuple(stream_digests),
                        payload_concat_sha256=payload_hasher.hexdigest(),
                    )
                )

            payload_extents.sort()
            for previous, current in zip(payload_extents, payload_extents[1:]):
                if previous[1] > current[0]:
                    raise HarnessError(
                        f"{where} has overlapping payloads at records "
                        f"{previous[2]} and {current[2]}"
                    )

    manifest: dict[str, Any] = {
        "header": header.manifest(),
        "records": [record.manifest() for record in records],
    }
    return GlrtImage(
        path=path,
        header=header,
        records=tuple(records),
        manifest=manifest,
        manifest_sha256=_canonical_json_sha256(manifest),
    )


def _record_map(image: GlrtImage) -> dict[tuple[str, int, int], GlrtRecord]:
    return {record.identity(): record for record in image.records}


def _require_separate_record(
    record: GlrtRecord,
    *,
    layer: int,
    kind: int,
    config: Mapping[str, Any],
    where: str,
) -> None:
    expected_elements = int(config["hidden_dim"]) * int(config["dim"])
    lengths = tuple(length for _, length in record.ranges)
    expected_scale_bytes = expected_elements // record.group_size * 2
    if (
        record.layer_idx != layer
        or record.kind != kind
        or record.role != GLRT_ROLE_TENSOR
        or record.encoding != GLRT_ENCODING_INT4
        or record.packed_layout != GLRT_PACKED_ROWS4_K16
        or record.pair_nibble_layout != GLRT_PAIR_NONE
        or record.group_size not in (8, 16)
        or record.out_f != config["hidden_dim"]
        or record.in_f != config["dim"]
        or record.num_elements != expected_elements
        or expected_elements % record.group_size != 0
        or lengths
        != (
            expected_elements // 2,
            0,
            0,
            expected_scale_bytes,
            0,
        )
    ):
        raise HarnessError(f"{where} is not a canonical PairNibble source record")


def _require_pair_record(
    record: GlrtRecord,
    *,
    layer: int,
    config: Mapping[str, Any],
) -> None:
    expected_elements = int(config["hidden_dim"]) * int(config["dim"])
    lengths = tuple(length for _, length in record.ranges)
    expected_scale_bytes = expected_elements // record.group_size * 4
    if (
        record.layer_idx != layer
        or record.kind != GLRT_OTHER_KIND
        or record.role != GLRT_ROLE_PAIR
        or record.encoding != GLRT_ENCODING_PAIR_NIBBLE
        or record.packed_layout != GLRT_PACKED_NONE
        or record.pair_nibble_layout != GLRT_PAIR_ROWS4_K16
        or record.group_size not in (8, 16)
        or record.out_f != config["hidden_dim"]
        or record.in_f != config["dim"]
        or record.num_elements != expected_elements
        or expected_elements % record.group_size != 0
        or lengths != (expected_elements, 0, 0, expected_scale_bytes, 0)
    ):
        raise HarnessError(
            f"candidate layer {layer} is not a canonical PairNibble record"
        )


def _prove_layer_rewrite(
    separate_mapped: mmap.mmap,
    pair_mapped: mmap.mmap,
    gate: GlrtRecord,
    up: GlrtRecord,
    pair: GlrtRecord,
) -> None:
    source_chunk_bytes = 1 << 20
    gate_offset, gate_length = gate.ranges[0]
    up_offset, up_length = up.ranges[0]
    pair_offset, pair_length = pair.ranges[0]
    if gate_length != up_length or pair_length != gate_length * 2:
        raise HarnessError(f"PairNibble layer {pair.layer_idx} weight extents differ")
    for position in range(0, gate_length, source_chunk_bytes):
        length = min(source_chunk_bytes, gate_length - position)
        gate_chunk = separate_mapped[
            gate_offset + position : gate_offset + position + length
        ]
        up_chunk = separate_mapped[up_offset + position : up_offset + position + length]
        pair_chunk = pair_mapped[
            pair_offset + position * 2 : pair_offset + (position + length) * 2
        ]
        pair_even = pair_chunk[0::2]
        pair_odd = pair_chunk[1::2]
        if (
            pair_even.translate(_LOW_NIBBLE_TABLE)
            != gate_chunk.translate(_LOW_NIBBLE_TABLE)
            or pair_odd.translate(_LOW_NIBBLE_TABLE)
            != gate_chunk.translate(_HIGH_NIBBLE_TABLE)
            or pair_even.translate(_HIGH_NIBBLE_TABLE)
            != up_chunk.translate(_LOW_NIBBLE_TABLE)
            or pair_odd.translate(_HIGH_NIBBLE_TABLE)
            != up_chunk.translate(_HIGH_NIBBLE_TABLE)
        ):
            raise HarnessError(
                f"candidate PairNibble weights are not an exact lossless rewrite at layer {pair.layer_idx}"
            )

    gate_scale_offset, gate_scale_length = gate.ranges[3]
    up_scale_offset, up_scale_length = up.ranges[3]
    pair_scale_offset, pair_scale_length = pair.ranges[3]
    if (
        array_module.array("Q").itemsize != 8
        or gate_scale_length != up_scale_length
        or gate_scale_length % 8 != 0
        or pair_scale_length != gate_scale_length * 2
    ):
        raise HarnessError(f"PairNibble layer {pair.layer_idx} scale extents differ")
    block_count = gate_scale_length // 8
    blocks_per_chunk = 1 << 16
    for block_start in range(0, block_count, blocks_per_chunk):
        blocks = min(blocks_per_chunk, block_count - block_start)
        source_start = block_start * 8
        source_length = blocks * 8
        pair_start = block_start * 16
        gate_chunk = separate_mapped[
            gate_scale_offset
            + source_start : gate_scale_offset
            + source_start
            + source_length
        ]
        up_chunk = separate_mapped[
            up_scale_offset
            + source_start : up_scale_offset
            + source_start
            + source_length
        ]
        pair_chunk = pair_mapped[
            pair_scale_offset
            + pair_start : pair_scale_offset
            + pair_start
            + blocks * 16
        ]
        pair_words = array_module.array("Q")
        pair_words.frombytes(pair_chunk)
        if (
            pair_words[0::2].tobytes() != gate_chunk
            or pair_words[1::2].tobytes() != up_chunk
        ):
            raise HarnessError(
                f"candidate PairNibble scales are not an exact bitwise rewrite at layer {pair.layer_idx}"
            )


def prove_glrt_pair_equivalence(
    separate_path: Path,
    pair_path: Path,
    *,
    separate_file_sha256: str,
    pair_file_sha256: str,
) -> dict[str, Any]:
    separate = parse_glrt_image(separate_path, "separate GLRT")
    candidate = parse_glrt_image(pair_path, "PairNibble GLRT")
    if separate.header.config_bytes != candidate.header.config_bytes:
        raise HarnessError("GLRT model config snapshots differ")
    if separate.header.source_fingerprint != candidate.header.source_fingerprint:
        raise HarnessError("GLRT source fingerprints differ")
    if separate.header.abi_fingerprint != candidate.header.abi_fingerprint:
        raise HarnessError("GLRT ABI fingerprints differ")
    if separate.header.abi_fingerprint == "00" * 32:
        raise HarnessError("GLRT ABI fingerprint must be non-zero")

    layers = int(separate.header.config["layers"])
    separate_map = _record_map(separate)
    candidate_map = _record_map(candidate)
    separate_gate_keys = {
        ("tensor", layer, GLRT_MLP_GATE_KIND) for layer in range(layers)
    }
    separate_up_keys = {("tensor", layer, GLRT_MLP_UP_KIND) for layer in range(layers)}
    candidate_pair_keys = {("role", layer, GLRT_ROLE_PAIR) for layer in range(layers)}
    observed_separate_gate = {
        key
        for key in separate_map
        if key[0] == "tensor" and key[2] == GLRT_MLP_GATE_KIND
    }
    observed_separate_up = {
        key for key in separate_map if key[0] == "tensor" and key[2] == GLRT_MLP_UP_KIND
    }
    observed_separate_pair = {key for key in separate_map if key[0] == "role"}
    observed_candidate_gate = {
        key
        for key in candidate_map
        if key[0] == "tensor" and key[2] == GLRT_MLP_GATE_KIND
    }
    observed_candidate_up = {
        key
        for key in candidate_map
        if key[0] == "tensor" and key[2] == GLRT_MLP_UP_KIND
    }
    observed_candidate_pair = {key for key in candidate_map if key[0] == "role"}
    if (
        observed_separate_gate != separate_gate_keys
        or observed_separate_up != separate_up_keys
        or observed_separate_pair
    ):
        raise HarnessError(
            "separate GLRT must contain exactly one gate and one up record per layer and no Pair records"
        )
    if (
        observed_candidate_gate
        or observed_candidate_up
        or observed_candidate_pair != candidate_pair_keys
    ):
        raise HarnessError(
            "PairNibble GLRT must contain exactly one Pair record per layer and no separate gate/up records"
        )

    separate_rewrite_keys = separate_gate_keys | separate_up_keys
    separate_common = {
        key: record
        for key, record in separate_map.items()
        if key not in separate_rewrite_keys
    }
    candidate_common = {
        key: record
        for key, record in candidate_map.items()
        if key not in candidate_pair_keys
    }
    if set(separate_common) != set(candidate_common):
        raise HarnessError("GLRT non-rewrite record sets differ")
    common_manifest: list[dict[str, Any]] = []
    for key in sorted(separate_common):
        baseline_manifest = separate_common[key].equivalence_manifest()
        candidate_manifest = candidate_common[key].equivalence_manifest()
        if baseline_manifest != candidate_manifest:
            raise HarnessError(f"GLRT non-rewrite record differs: {key}")
        common_manifest.append(baseline_manifest)

    layer_manifest: list[dict[str, Any]] = []
    try:
        separate_handle = separate_path.open("rb")
        candidate_handle = pair_path.open("rb")
    except OSError as error:
        raise HarnessError(
            f"cannot reopen GLRT payloads for rewrite proof: {error}"
        ) from error
    with separate_handle, candidate_handle:
        with mmap.mmap(
            separate_handle.fileno(), 0, access=mmap.ACCESS_READ
        ) as separate_mapped, mmap.mmap(
            candidate_handle.fileno(), 0, access=mmap.ACCESS_READ
        ) as candidate_mapped:
            for layer in range(layers):
                gate = separate_map[("tensor", layer, GLRT_MLP_GATE_KIND)]
                up = separate_map[("tensor", layer, GLRT_MLP_UP_KIND)]
                pair = candidate_map[("role", layer, GLRT_ROLE_PAIR)]
                _require_separate_record(
                    gate,
                    layer=layer,
                    kind=GLRT_MLP_GATE_KIND,
                    config=separate.header.config,
                    where=f"separate gate layer {layer}",
                )
                _require_separate_record(
                    up,
                    layer=layer,
                    kind=GLRT_MLP_UP_KIND,
                    config=separate.header.config,
                    where=f"separate up layer {layer}",
                )
                _require_pair_record(
                    pair,
                    layer=layer,
                    config=candidate.header.config,
                )
                if (
                    gate.group_size != up.group_size
                    or pair.group_size != gate.group_size
                ):
                    raise HarnessError(
                        f"PairNibble group size differs at layer {layer}"
                    )
                _prove_layer_rewrite(
                    separate_mapped,
                    candidate_mapped,
                    gate,
                    up,
                    pair,
                )
                layer_item = {
                    "layer": layer,
                    "group_size": gate.group_size,
                    "out_f": gate.out_f,
                    "in_f": gate.in_f,
                    "num_elements_per_branch": gate.num_elements,
                    "gate": gate.equivalence_manifest(),
                    "up": up.equivalence_manifest(),
                    "pair": pair.equivalence_manifest(),
                    "exact_nibble_rewrite": True,
                    "exact_rows4_f16_scale_bit_rewrite": True,
                    "source_weight_bytes": gate.ranges[0][1] + up.ranges[0][1],
                    "pair_weight_bytes": pair.ranges[0][1],
                    "source_scale_bytes": gate.ranges[3][1] + up.ranges[3][1],
                    "pair_scale_bytes": pair.ranges[3][1],
                }
                if (
                    layer_item["source_weight_bytes"] != layer_item["pair_weight_bytes"]
                    or layer_item["source_scale_bytes"]
                    != layer_item["pair_scale_bytes"]
                ):
                    raise HarnessError(
                        f"PairNibble byte ledger differs at layer {layer}"
                    )
                layer_item["rewrite_proof_sha256"] = _canonical_json_sha256(layer_item)
                layer_manifest.append(layer_item)

    byte_ledger = {
        "separate_gate_bytes": sum(
            item["gate"]["canonical_descriptor"]["stream_lengths"]["packed_weights"]
            + item["gate"]["canonical_descriptor"]["stream_lengths"]["scales_f16_rows4"]
            for item in layer_manifest
        ),
        "separate_up_bytes": sum(
            item["up"]["canonical_descriptor"]["stream_lengths"]["packed_weights"]
            + item["up"]["canonical_descriptor"]["stream_lengths"]["scales_f16_rows4"]
            for item in layer_manifest
        ),
        "pair_weight_bytes": sum(item["pair_weight_bytes"] for item in layer_manifest),
        "pair_scale_bytes": sum(item["pair_scale_bytes"] for item in layer_manifest),
    }
    if (
        byte_ledger["separate_gate_bytes"] + byte_ledger["separate_up_bytes"]
        != byte_ledger["pair_weight_bytes"] + byte_ledger["pair_scale_bytes"]
    ):
        raise HarnessError("aggregate PairNibble byte ledger differs")

    proof: dict[str, Any] = {
        "schema": GLRT_PROOF_SCHEMA,
        "status": "exact-lossless-rewrite-verified",
        "separate_file_sha256": separate_file_sha256,
        "pair_file_sha256": pair_file_sha256,
        "header_equivalence": {
            "version": 2,
            "source_fingerprint": separate.header.source_fingerprint,
            "abi_fingerprint": separate.header.abi_fingerprint,
            "config_bytes_sha256": sha256_bytes(separate.header.config_bytes),
            "exact_config_bytes": True,
            "exact_source_fingerprint": True,
            "exact_abi_fingerprint": True,
        },
        "separate_manifest": separate.manifest,
        "separate_manifest_sha256": separate.manifest_sha256,
        "pair_manifest": candidate.manifest,
        "pair_manifest_sha256": candidate.manifest_sha256,
        "common_non_rewrite_records": common_manifest,
        "common_non_rewrite_manifest_sha256": _canonical_json_sha256(common_manifest),
        "layers": layer_manifest,
        "layer_rewrite_manifest_sha256": _canonical_json_sha256(layer_manifest),
        "byte_ledger": byte_ledger,
        "claims": {
            "all_records_structurally_verified": True,
            "all_record_crcs_verified": True,
            "all_descriptor_payload_sha256_verified": True,
            "all_non_rewrite_records_identical": True,
            "exact_gate_up_nibble_rewrite": True,
            "exact_rows4_f16_scale_bit_rewrite": True,
            "optional_scale_mirrors_forbidden_in_separate_sources": True,
        },
    }
    proof["proof_sha256"] = _canonical_json_sha256(proof)
    return proof


def parse_resource_output(value: str) -> dict[str, int | float]:
    """Delegate to resource_ab's complete strict macOS ``time -lp`` parser."""
    return _load_resource_support().parse_time_output(value)


def fingerprint_artifacts(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.separate_model.suffix.lower() != ".glrt":
        raise HarnessError("separate baseline model must be a .glrt path")
    if config.pair_model.suffix.lower() != ".glrt":
        raise HarnessError("PairNibble candidate model must be a .glrt path")
    resource = _load_resource_support()
    declarations = {
        "driver": (Path(__file__).resolve(), None),
        "attention_ab_support": (Path(_attention.__file__).resolve(), None),
        "resource_ab_support": (Path(resource.__file__).resolve(), None),
        "binary": (config.binary, config.binary_sha256),
        "separate_model": (
            config.separate_model,
            config.separate_model_sha256,
        ),
        "pair_model": (config.pair_model, config.pair_model_sha256),
        "prompt_ids": (config.ids, config.ids_sha256),
    }
    if config.darwin_resources:
        declarations["time_binary"] = (config.time_binary, config.time_sha256)
    artifacts = {
        name: _attention.fingerprint(path, name, expected)
        for name, (path, expected) in declarations.items()
    }
    if artifacts["separate_model"]["sha256"] == artifacts["pair_model"]["sha256"]:
        raise HarnessError("separate and PairNibble model bytes must differ")
    return artifacts


def verify_artifacts(
    config: Config, before: Mapping[str, Mapping[str, Any]]
) -> dict[str, dict[str, Any]]:
    after = fingerprint_artifacts(config)
    for name in before:
        if before[name]["identity"] != after[name]["identity"]:
            raise HarnessError(
                f"artifact {name} filesystem identity changed during A/B"
            )
        if before[name]["sha256"] != after[name]["sha256"]:
            raise HarnessError(f"artifact {name} bytes changed during A/B")
    return after


def build_patterns(samples_per_variant: int, seed: int) -> list[str]:
    return _attention.build_patterns(samples_per_variant, seed)


def percentile(values: Sequence[float], probability: float) -> float:
    return _attention.percentile(values, probability)


def paired_ratio(
    samples: Sequence[Mapping[str, Any]],
    field: str,
    *,
    resamples: int,
    seed: int,
    confidence: float,
) -> dict[str, Any]:
    blocks: dict[int, dict[str, list[float]]] = {}
    for sample in samples:
        value = sample["metrics"].get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HarnessError(f"metric {field} is missing or not numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or numeric <= 0:
            raise HarnessError(f"metric {field} must be finite and positive")
        variant = str(sample.get("variant"))
        if variant not in VARIANTS:
            raise HarnessError(f"unknown variant in paired sample: {variant}")
        block = blocks.setdefault(
            int(sample["block_index"]), {mode: [] for mode in VARIANTS}
        )
        block[variant].append(numeric)
    ordered = [blocks[index] for index in sorted(blocks)]
    if not ordered or any(
        len(block[variant]) != 2 for block in ordered for variant in VARIANTS
    ):
        raise HarnessError(
            "paired bootstrap requires two observations per variant per block"
        )

    def ratio(selected: Sequence[Mapping[str, Sequence[float]]]) -> float:
        baseline = [value for block in selected for value in block["separate"]]
        candidate = [
            value for block in selected for value in block["pair-nibble-required"]
        ]
        return statistics.median(baseline) / statistics.median(candidate)

    field_seed = int.from_bytes(
        hashlib.sha256(field.encode("ascii")).digest()[:8], "big"
    )
    rng = random.Random(seed ^ field_seed)
    bootstrap: list[float] = []
    for _ in range(resamples):
        selected = [ordered[rng.randrange(len(ordered))] for _ in ordered]
        bootstrap.append(ratio(selected))
    tail = (1.0 - confidence) / 2.0
    return {
        "direction": "separate_over_pair_nibble; greater than 1 favors PairNibble",
        "estimate": ratio(ordered),
        "confidence": confidence,
        "ci_low": percentile(bootstrap, tail),
        "ci_high": percentile(bootstrap, 1.0 - tail),
        "bootstrap_resamples": resamples,
        "bootstrap_seed": seed,
    }


def _exactly_one_valid(
    output: str, prefix: str, expression: re.Pattern[str], where: str
) -> re.Match[str]:
    prefix_count = len(
        re.findall(rf"^[^\S\r\n]*{re.escape(prefix)}", output, re.I | re.M)
    )
    matches = list(expression.finditer(output))
    if prefix_count != 1 or len(matches) != 1:
        raise HarnessError(f"{where} telemetry is missing, malformed, or duplicated")
    return matches[0]


def _counter(value: str, where: str) -> int:
    result = int(value)
    if result > MAX_I64:
        raise HarnessError(f"{where} exceeds the signed 64-bit evidence bound")
    return result


def _finite_nonnegative(value: str, where: str) -> float:
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise HarnessError(f"{where} must be finite and non-negative")
    return result


def _expected_pair_coverage(
    *, prompt_tokens: int, new_tokens: int, layers: int, prefill: str
) -> dict[str, int]:
    decode_rows = new_tokens - 1
    if prefill == "serial":
        prefill_m1 = prompt_tokens * layers
        prefill_m4_groups = 0
        tail_dispatches = 0
        tail_rows = 0
        prefill_checked = prompt_tokens * layers
    elif prefill == "batch":
        remaining = prompt_tokens
        groups = 0
        tails = 0
        tail_row_count = 0
        checked = 0
        while remaining:
            rows = min(PREFILL_CHUNK_ROWS, remaining)
            groups += rows // 4
            tails += int(rows % 4 != 0)
            tail_row_count += rows % 4
            checked += (rows + 3) // 4
            remaining -= rows
        prefill_m1 = 0
        prefill_m4_groups = groups * layers
        tail_dispatches = tails * layers
        tail_rows = tail_row_count * layers
        prefill_checked = checked * layers
    else:
        raise HarnessError(f"unknown prefill mode: {prefill}")
    decode_m1 = decode_rows * layers
    selected_rows = (prompt_tokens + decode_rows) * layers
    return {
        "prefill_m1": prefill_m1,
        "prefill_m4_groups": prefill_m4_groups,
        "prefill_tail_dispatches": tail_dispatches,
        "prefill_tail_rows": tail_rows,
        "decode_m1": decode_m1,
        "outputless_m1": prefill_m1 + decode_m1,
        "activation_rows_quantized": selected_rows,
        "selected_layer_rows": selected_rows,
        "checked_dispatches": prefill_checked + decode_m1,
        "sealed_dispatches": 0,
    }


def parse_telemetry(
    output: str,
    *,
    variant: str,
    prompt_tokens: int,
    new_tokens: int,
    prefill: str,
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")
    load = _exactly_one_valid(output, "load:", _attention._LOAD_RE, "load")
    ready = _exactly_one_valid(output, "ready:", _attention._READY_RE, "request-ready")
    schedule = _exactly_one_valid(
        output, "schedule:", _attention._SCHEDULE_RE, "schedule"
    )
    phases = _exactly_one_valid(output, "phases:", _attention._PHASES_RE, "phase")
    pair = _exactly_one_valid(output, "pair_nibble:", _PAIR_NIBBLE_RE, "PairNibble")
    plan = _exactly_one_valid(output, "decode_plan:", _DECODE_PLAN_RE, "DecodePlan")
    greedy = _exactly_one_valid(
        output, "greedy_output:", _GREEDY_OUTPUT_RE, "greedy-output"
    )
    total = _exactly_one_valid(output, "time:", _TOTAL_RE, "total-time")

    if load.group(1).lower() != "prepared" or load.group(2).lower() != "glrt":
        raise HarnessError("run did not report a prepared GLRT load")
    if schedule.group(1).lower() != "serial" or schedule.group(2) is not None:
        raise HarnessError("PairNibble A/B requires explicit serial attention")
    layers = _counter(schedule.group(3), "layer count")
    if int(total.group(3)) != prompt_tokens or total.group(4).lower() != prefill:
        raise HarnessError(
            "run did not report the exact prompt count and required prefill mode"
        )

    decode_runs = _counter(phases.group(4), "decode graph count")
    if decode_runs != new_tokens - 1:
        raise HarnessError(
            f"decode graph count was {decode_runs}, expected {new_tokens - 1}"
        )
    phase_counters = tuple(
        _counter(phases.group(index), "phase counter") for index in range(5, 13)
    )
    if any(phase_counters):
        raise HarnessError(
            "serial-attention PairNibble A/B requires zero attention/handoff/legacy-paired counters"
        )

    plan_mode = plan.group(1).lower()
    plan_counters = tuple(
        _counter(plan.group(index), "DecodePlan counter") for index in range(2, 10)
    )
    plan_build_ms = _finite_nonnegative(plan.group(10), "DecodePlan build_ms")
    plan_abi_value = int(plan.group(11), 16)
    if (
        plan_mode != "checked"
        or any(plan_counters)
        or plan_build_ms != 0
        or plan_abi_value == 0
        or plan_abi_value > MAX_U64
    ):
        raise HarnessError(
            "PairNibble A/B requires an idle checked DecodePlan with no sealed/fallback/reject work"
        )

    greedy_names = (
        "materialized_projections",
        "logitless_projections",
        "producer_rows",
        "tile_output_bytes",
        "argmax_scan_rows",
        "scratch_bytes",
        "materialized_logits_bytes",
        "steady_state_reclaimed_bytes",
        "fallbacks",
        "rejects",
    )
    greedy_counters = {
        name: _counter(greedy.group(index), f"greedy-output {name}")
        for index, name in enumerate(greedy_names, start=2)
    }
    greedy_abi_value = int(greedy.group(12), 16)
    greedy_abi = f"{greedy_abi_value:016x}"
    if greedy.group(1).lower() != "materialized" or greedy_abi != GREEDY_ARGMAX_ABI:
        raise HarnessError(
            "PairNibble A/B requires the materialized greedy-output policy and ABI"
        )
    materialized_logits_bytes = greedy_counters["materialized_logits_bytes"]
    expected_greedy = {
        "materialized_projections": new_tokens,
        "logitless_projections": 0,
        "producer_rows": 0,
        "tile_output_bytes": 0,
        "argmax_scan_rows": 0,
        "scratch_bytes": 0,
        "steady_state_reclaimed_bytes": 0,
        "fallbacks": 0,
        "rejects": 0,
    }
    observed_greedy = {name: greedy_counters[name] for name in expected_greedy}
    if (
        observed_greedy != expected_greedy
        or materialized_logits_bytes <= 0
        or materialized_logits_bytes % 4 != 0
    ):
        raise HarnessError(
            f"materialized greedy-output counters were {observed_greedy}, expected {expected_greedy}"
        )

    reported_policy = pair.group(1).lower()
    artifact = pair.group(2).lower()
    selected = pair.group(3).lower()
    names = (
        "admissions",
        "artifact_layers",
        "selected_layers",
        "pair_weight_bytes",
        "pair_scale_bytes",
        "separate_gate_bytes",
        "separate_up_bytes",
        "prefill_m1",
        "prefill_m4_groups",
        "prefill_tail_dispatches",
        "prefill_tail_rows",
        "decode_m1",
        "outputless_m1",
        "activation_rows_quantized",
        "selected_layer_rows",
        "checked_dispatches",
        "sealed_dispatches",
        "fallbacks",
        "rejects",
    )
    counters = {
        name: _counter(pair.group(index), f"PairNibble {name}")
        for index, name in enumerate(names, start=4)
    }
    storage_abi_value = int(pair.group(23), 16)
    executor_abi_value = int(pair.group(24), 16)
    if storage_abi_value != PAIR_NIBBLE_STORAGE_ABI:
        raise HarnessError(
            "PairNibble storage ABI mismatch: "
            f"expected {PAIR_NIBBLE_STORAGE_ABI:016x}, "
            f"got {storage_abi_value:016x}"
        )
    if executor_abi_value != PAIR_NIBBLE_EXECUTOR_ABI:
        raise HarnessError(
            "PairNibble executor ABI mismatch: "
            f"expected {PAIR_NIBBLE_EXECUTOR_ABI:016x}, "
            f"got {executor_abi_value:016x}"
        )

    if variant == "separate":
        if (reported_policy, artifact, selected) != (
            "separate",
            "separate",
            "separate",
        ):
            raise HarnessError(
                "baseline did not report separate policy/artifact/selection"
            )
        expected_zero = {
            "admissions",
            "artifact_layers",
            "selected_layers",
            "pair_weight_bytes",
            "pair_scale_bytes",
            "prefill_m1",
            "prefill_m4_groups",
            "prefill_tail_dispatches",
            "prefill_tail_rows",
            "decode_m1",
            "outputless_m1",
            "activation_rows_quantized",
            "selected_layer_rows",
            "checked_dispatches",
            "sealed_dispatches",
            "fallbacks",
            "rejects",
        }
        if any(counters[name] != 0 for name in expected_zero):
            raise HarnessError("baseline reported non-zero PairNibble counters")
        if counters["separate_gate_bytes"] <= 0 or counters["separate_up_bytes"] <= 0:
            raise HarnessError("baseline must report resident separate gate/up bytes")
    else:
        if (reported_policy, artifact, selected) != (
            "pair-nibble-required",
            "pair-nibble",
            "pair-nibble",
        ):
            raise HarnessError(
                "candidate did not report required PairNibble policy/artifact/selection"
            )
        if counters["admissions"] != 1:
            raise HarnessError("candidate must report exactly one PairNibble admission")
        if (
            counters["artifact_layers"] != layers
            or counters["selected_layers"] != layers
        ):
            raise HarnessError("candidate PairNibble layer coverage is incomplete")
        if counters["pair_weight_bytes"] <= 0 or counters["pair_scale_bytes"] <= 0:
            raise HarnessError("candidate must report resident PairNibble bytes")
        if counters["separate_gate_bytes"] != 0 or counters["separate_up_bytes"] != 0:
            raise HarnessError("candidate retained forbidden separate gate/up bytes")
        if counters["fallbacks"] != 0 or counters["rejects"] != 0:
            raise HarnessError("candidate reported PairNibble fallback/reject work")
        expected_coverage = _expected_pair_coverage(
            prompt_tokens=prompt_tokens,
            new_tokens=new_tokens,
            layers=layers,
            prefill=prefill,
        )
        observed_coverage = {name: counters[name] for name in expected_coverage}
        if observed_coverage != expected_coverage:
            raise HarnessError(
                f"candidate PairNibble coverage was {observed_coverage}, expected {expected_coverage}"
            )

    metrics: dict[str, Any] = {
        "load_ms": _finite_nonnegative(load.group(3), "load_ms"),
        "request_ready_ms": _finite_nonnegative(ready.group(1), "request_ready_ms"),
        "prefill_ms": _finite_nonnegative(phases.group(1), "prefill_ms"),
        "decode_ms": _finite_nonnegative(phases.group(2), "decode_ms"),
        "sampling_ms": _finite_nonnegative(phases.group(3), "sampling_ms"),
        "decode_runs": decode_runs,
        "layers": layers,
        "internal_ms": _finite_nonnegative(total.group(1), "internal_ms"),
        "internal_tokens_per_second": _finite_nonnegative(
            total.group(2), "internal_tokens_per_second"
        ),
        "prefill_mode": total.group(4).lower(),
        "pair_nibble_policy": reported_policy,
        "pair_nibble_artifact": artifact,
        "pair_nibble_selected": selected,
        "pair_nibble_storage_abi": f"{storage_abi_value:016x}",
        "pair_nibble_executor_abi": f"{executor_abi_value:016x}",
        "decode_plan_abi": f"{plan_abi_value:016x}",
        "greedy_output_mode": "materialized",
        "greedy_output_abi": greedy_abi,
        "greedy_materialized_logits_bytes": materialized_logits_bytes,
        "greedy_output_line_sha256": sha256_bytes(
            greedy.group(0).strip().encode("ascii")
        ),
        "pair_nibble_line_sha256": sha256_bytes(pair.group(0).strip().encode("utf-8")),
    }
    metrics.update({f"pair_nibble_{name}": value for name, value in counters.items()})
    metrics.update({f"greedy_{name}": value for name, value in greedy_counters.items()})
    if (
        metrics["prefill_ms"] <= 0
        or metrics["decode_ms"] <= 0
        or metrics["internal_ms"] <= 0
    ):
        raise HarnessError("prefill, decode, and internal timings must be positive")
    resource = _load_resource_support()
    resource._validate_telemetry_precision(output)
    metrics.update(
        resource._validate_internal_metric_relations(
            metrics,
            completion_tokens=new_tokens,
        )
    )
    return metrics


def model_for_variant(config: Config, variant: str) -> Path:
    if variant == "separate":
        return config.separate_model
    if variant == "pair-nibble-required":
        return config.pair_model
    raise HarnessError(f"unknown variant: {variant}")


def build_command(config: Config, variant: str, completion_path: Path) -> list[str]:
    model = model_for_variant(config, variant)
    prefill_policy = (
        ["--require-batch-prefill"]
        if config.prefill == "batch"
        else ["--serial-prefill"]
    )
    return [
        str(config.binary),
        "generate",
        str(model),
        "--ids-file",
        str(config.ids),
        "--n",
        str(config.new_tokens),
        "--threads",
        str(config.threads),
        "--temp",
        "0",
        "--top-k",
        "0",
        "--top-p",
        "1",
        "--seed",
        "0",
        "--eos",
        str(MAX_U32),
        "--require-prepared-image",
        "--serial-attention",
        "--decode-plan",
        "checked",
        "--greedy-output",
        "materialized",
        "--mlp-layout",
        variant,
        "--out-ids-file",
        str(completion_path),
        *prefill_policy,
    ]


def _run_process(
    argv: Sequence[str],
    cwd: Path,
    timeout_seconds: float,
    *,
    environment: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter_ns()
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
            env=None if environment is None else dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError as error:
        raise HarnessError(f"cannot launch Glacier: {error}") from error
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise HarnessError(
            f"Glacier timed out after {timeout_seconds} seconds"
        ) from error
    wall_ms = (time.perf_counter_ns() - started) / 1e6
    capture = _load_resource_support()._capture_process_output(
        output,
        extra_reserved_prefixes=(b"pair_nibble:", b"pair_scratch:"),
    )
    if process.returncode != 0:
        raise HarnessError(
            f"Glacier exited with {process.returncode}:\n{capture['retained_text']}"
        )
    if not math.isfinite(wall_ms) or wall_ms <= 0:
        raise HarnessError("harness wall timing is not finite and positive")
    return {
        **capture,
        "wall_ms": wall_ms,
        "exit_status": process.returncode,
    }


def run_variant(
    config: Config,
    variant: str,
    completion_path: Path,
    prompt_ids: Sequence[int],
    artifact_before: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    _attention.assert_artifact_identities(artifact_before)
    time_path = completion_path.with_name("resource.time")
    if completion_path.exists() or (config.darwin_resources and time_path.exists()):
        raise HarnessError("observation output path unexpectedly exists")
    command = build_command(config, variant, completion_path)
    executed_command = command
    environment = None
    if config.darwin_resources:
        executed_command = [
            str(config.time_binary),
            "-lp",
            "-o",
            str(time_path),
            *command,
        ]
        environment = {"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"}
    process = _run_process(
        executed_command,
        config.cwd,
        config.timeout_seconds,
        environment=environment,
    )
    _attention.assert_artifact_identities(artifact_before)
    if not completion_path.is_file():
        raise HarnessError("Glacier did not create the required completion-ID file")
    try:
        completion_raw = completion_path.read_bytes()
    except OSError as error:
        raise HarnessError(f"cannot read completion IDs: {error}") from error
    completion_ids = parse_ids(completion_raw, "completion output")
    if len(completion_ids) != config.new_tokens:
        raise HarnessError(
            f"completion output had {len(completion_ids)} IDs, expected {config.new_tokens}"
        )
    metrics = parse_telemetry(
        process["telemetry_text"],
        variant=variant,
        prompt_tokens=len(prompt_ids),
        new_tokens=config.new_tokens,
        prefill=config.prefill,
    )
    metrics["harness_wall_ms"] = process["wall_ms"]
    result = {
        "variant": variant,
        "argv": command,
        "metrics": metrics,
        "completion_ids": completion_ids,
        "completion_ids_sha256": sha256_bytes(canonical_ids_bytes(completion_ids)),
        "completion_file_sha256": sha256_bytes(completion_raw),
        "telemetry_sha256": process["output_capture"]["raw_sha256"],
        "telemetry_output": process["retained_text"],
        "output_capture": process["output_capture"],
        "exit_status": process["exit_status"],
    }
    if config.darwin_resources:
        if not time_path.is_file():
            raise HarnessError("time did not create the required resource record")
        try:
            time_raw = time_path.read_bytes()
            time_text = time_raw.decode("ascii", errors="strict")
        except (OSError, UnicodeDecodeError) as error:
            raise HarnessError(f"cannot read resource record: {error}") from error
        resource = _load_resource_support()
        resource._validate_telemetry_precision(process["telemetry_text"])
        resources = parse_resource_output(time_text)
        for field in RESOURCE_REQUIRED_POSITIVE_FIELDS:
            if float(resources[field]) <= 0:
                raise HarnessError(f"resource metric must be positive: {field}")
        harness_wall_seconds = process["wall_ms"] / 1000.0
        relations = resource._validate_metric_relations(
            metrics,
            resources,
            completion_tokens=len(completion_ids),
            harness_wall_seconds=harness_wall_seconds,
        )
        metrics.update(resources)
        metrics.update(relations)
        metrics["harness_wall_seconds"] = harness_wall_seconds
        result.update(
            {
                "timed_argv": executed_command,
                "time_output": time_text,
                "time_output_sha256": sha256_bytes(time_raw),
            }
        )
    return result


def validate_config(config: Config) -> None:
    build_patterns(config.samples_per_variant, config.schedule_seed)
    if config.samples_per_variant > 10_000:
        raise HarnessError("samples per variant must not exceed 10000")
    if not 1 <= config.warmups_per_variant <= 100:
        raise HarnessError("warmups per variant must be in [1, 100]")
    if not 2 <= config.new_tokens <= 1_000_000:
        raise HarnessError("PairNibble A/B new tokens must be in [2, 1000000]")
    if not 1 <= config.threads <= 8:
        raise HarnessError(
            "PairNibble evidence threads must be in the certified range [1, 8]"
        )
    if config.prefill not in ("batch", "serial"):
        raise HarnessError("prefill must be batch or serial")
    if config.prefill == "batch" and config.threads < 2:
        raise HarnessError("batch prefill requires at least two threads")
    if not 100 <= config.bootstrap_resamples <= 1_000_000:
        raise HarnessError("bootstrap resamples must be in [100, 1000000]")
    if not 0 <= config.schedule_seed <= MAX_I64:
        raise HarnessError("schedule seed must be in the signed int64 range")
    if not 0 <= config.bootstrap_seed <= MAX_I64:
        raise HarnessError("bootstrap seed must be in the signed int64 range")
    if not 0.5 <= config.confidence <= 0.999:
        raise HarnessError("confidence must be in [0.5, 0.999]")
    if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
        raise HarnessError("timeout must be finite and positive")
    if not config.cwd.is_dir():
        raise HarnessError(f"cwd is not a directory: {config.cwd}")
    resource = _load_resource_support()
    resource_path = Path(resource.__file__).resolve()
    input_paths = {
        config.binary,
        config.separate_model,
        config.pair_model,
        config.ids,
        Path(__file__).resolve(),
        Path(_attention.__file__).resolve(),
        resource_path,
    }
    expected_input_paths = 7
    if config.darwin_resources:
        configured_paths = {
            "binary": config.binary,
            "separate model": config.separate_model,
            "PairNibble model": config.pair_model,
            "IDs": config.ids,
            "cwd": config.cwd,
            "time binary": config.time_binary,
        }
        if config.output is not None:
            configured_paths["output"] = config.output
        for name, path in configured_paths.items():
            if not path.is_absolute():
                raise HarnessError(
                    f"Darwin resource benchmark path must be absolute ({name}): {path}"
                )
        if (
            platform.system() != "Darwin"
            or config.time_binary.resolve() != SYSTEM_TIME_BINARY
        ):
            raise HarnessError(
                "publishable resource measurements require Darwin /usr/bin/time"
            )
        if not os.access(config.time_binary, os.X_OK):
            raise HarnessError(f"time binary is not executable: {config.time_binary}")
        input_paths.update((resource_path, config.time_binary))
        expected_input_paths += 1
    if len(input_paths) != expected_input_paths:
        raise HarnessError(
            "binary, both models, IDs, drivers, support modules, and time must be distinct files"
        )
    if config.output is not None and config.output in input_paths:
        raise HarnessError("result output must not replace a benchmark input artifact")
    for name, digest in (
        ("binary", config.binary_sha256),
        ("separate model", config.separate_model_sha256),
        ("PairNibble model", config.pair_model_sha256),
        ("IDs", config.ids_sha256),
        ("time", config.time_sha256),
    ):
        if digest is not None and SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"{name} SHA-256 pin must be 64 lowercase hex digits")


def _pair_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    return tuple(
        metrics[name]
        for name in (
            "layers",
            "decode_runs",
            "prefill_mode",
            "pair_nibble_policy",
            "pair_nibble_artifact",
            "pair_nibble_selected",
            "pair_nibble_admissions",
            "pair_nibble_artifact_layers",
            "pair_nibble_selected_layers",
            "pair_nibble_pair_weight_bytes",
            "pair_nibble_pair_scale_bytes",
            "pair_nibble_separate_gate_bytes",
            "pair_nibble_separate_up_bytes",
            "pair_nibble_prefill_m1",
            "pair_nibble_prefill_m4_groups",
            "pair_nibble_prefill_tail_dispatches",
            "pair_nibble_prefill_tail_rows",
            "pair_nibble_decode_m1",
            "pair_nibble_outputless_m1",
            "pair_nibble_activation_rows_quantized",
            "pair_nibble_selected_layer_rows",
            "pair_nibble_checked_dispatches",
            "pair_nibble_sealed_dispatches",
            "pair_nibble_fallbacks",
            "pair_nibble_rejects",
            "pair_nibble_storage_abi",
            "pair_nibble_executor_abi",
            "decode_plan_abi",
        )
    )


def run_benchmark(config: Config) -> dict[str, Any]:
    validate_config(config)
    artifact_before = fingerprint_artifacts(config)
    _attention.assert_artifact_identities(artifact_before)
    glrt_proof = prove_glrt_pair_equivalence(
        config.separate_model,
        config.pair_model,
        separate_file_sha256=str(artifact_before["separate_model"]["sha256"]),
        pair_file_sha256=str(artifact_before["pair_model"]["sha256"]),
    )
    _attention.assert_artifact_identities(artifact_before)
    expected_layers = int(glrt_proof["separate_manifest"]["header"]["config"]["layers"])
    try:
        prompt_ids = parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise HarnessError(f"cannot read prompt IDs: {error}") from error
    if config.prefill == "batch" and len(prompt_ids) < 8:
        raise HarnessError("batch prefill requires at least eight prompt IDs")

    patterns = build_patterns(config.samples_per_variant, config.schedule_seed)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    layers: int | None = None
    storage_abi: str | None = None
    executor_abi: str | None = None
    signatures: dict[str, tuple[Any, ...]] = {}
    with tempfile.TemporaryDirectory(
        prefix="glacier-pair-nibble-runtime-ab."
    ) as temporary:
        run_root = Path(temporary)

        def observe(
            variant: str,
            *,
            warmup: bool,
            sequence_index: int,
            block_index: int,
            position_in_block: int,
            pattern: str,
        ) -> dict[str, Any]:
            nonlocal reference_ids, layers, storage_abi, executor_abi
            sample_root = run_root / (
                f"{'warmup' if warmup else 'sample'}-{sequence_index:03d}-{variant}"
            )
            sample_root.mkdir()
            item = run_variant(
                config,
                variant,
                sample_root / "completion.ids",
                prompt_ids,
                artifact_before,
            )
            item.update(
                {
                    "warmup": warmup,
                    "sequence_index": sequence_index,
                    "block_index": block_index,
                    "position_in_block": position_in_block,
                    "pattern": pattern,
                    "fresh_process": True,
                }
            )
            if reference_ids is None:
                reference_ids = list(item["completion_ids"])
            elif item["completion_ids"] != reference_ids:
                raise HarnessError(
                    "exact completion IDs changed at "
                    f"{'warmup' if warmup else 'sample'} {sequence_index} ({variant})"
                )
            observed_layers = int(item["metrics"]["layers"])
            if observed_layers != expected_layers:
                raise HarnessError(
                    "runtime layer telemetry differs from the verified GLRT config"
                )
            if layers is None:
                layers = observed_layers
            elif observed_layers != layers:
                raise HarnessError("layer count changed during PairNibble A/B")
            observed_storage_abi = str(item["metrics"]["pair_nibble_storage_abi"])
            observed_executor_abi = str(item["metrics"]["pair_nibble_executor_abi"])
            if storage_abi is None:
                storage_abi = observed_storage_abi
                executor_abi = observed_executor_abi
            elif (
                observed_storage_abi != storage_abi
                or observed_executor_abi != executor_abi
            ):
                raise HarnessError("PairNibble ABI changed during A/B")
            signature = _pair_signature(item["metrics"])
            if variant not in signatures:
                signatures[variant] = signature
            elif signatures[variant] != signature:
                raise HarnessError(f"{variant} PairNibble coverage changed during A/B")
            return item

        warmup_order = list(VARIANTS)
        if config.schedule_seed & 1:
            warmup_order.reverse()
        for _ in range(config.warmups_per_variant):
            for position, variant in enumerate(warmup_order):
                warmups.append(
                    observe(
                        variant,
                        warmup=True,
                        sequence_index=len(warmups),
                        block_index=-1,
                        position_in_block=position,
                        pattern="warmup",
                    )
                )
        for block_index, pattern in enumerate(patterns):
            for position, letter in enumerate(pattern):
                variant = "pair-nibble-required" if letter == "A" else "separate"
                samples.append(
                    observe(
                        variant,
                        warmup=False,
                        sequence_index=len(samples),
                        block_index=block_index,
                        position_in_block=position,
                        pattern=pattern,
                    )
                )

    artifact_after = verify_artifacts(config, artifact_before)
    assert reference_ids is not None
    assert layers is not None
    assert storage_abi is not None
    assert executor_abi is not None

    baseline_metrics = next(
        item["metrics"] for item in samples if item["variant"] == "separate"
    )
    candidate_metrics = next(
        item["metrics"] for item in samples if item["variant"] == "pair-nibble-required"
    )
    baseline_mlp_bytes = int(baseline_metrics["pair_nibble_separate_gate_bytes"]) + int(
        baseline_metrics["pair_nibble_separate_up_bytes"]
    )
    candidate_mlp_bytes = int(candidate_metrics["pair_nibble_pair_weight_bytes"]) + int(
        candidate_metrics["pair_nibble_pair_scale_bytes"]
    )
    if baseline_mlp_bytes <= 0 or candidate_mlp_bytes != baseline_mlp_bytes:
        raise HarnessError(
            "separate and PairNibble artifacts do not report equal MLP producer bytes"
        )
    ledger = glrt_proof["byte_ledger"]
    telemetry_ledger = {
        "separate_gate_bytes": int(baseline_metrics["pair_nibble_separate_gate_bytes"]),
        "separate_up_bytes": int(baseline_metrics["pair_nibble_separate_up_bytes"]),
        "pair_weight_bytes": int(candidate_metrics["pair_nibble_pair_weight_bytes"]),
        "pair_scale_bytes": int(candidate_metrics["pair_nibble_pair_scale_bytes"]),
    }
    if telemetry_ledger != ledger:
        raise HarnessError(
            f"runtime PairNibble byte ledger was {telemetry_ledger}, verified artifacts require {ledger}"
        )

    ratio_fields = (
        "prefill_ms",
        "decode_ms",
        "internal_ms",
        *(RESOURCE_RATIO_FIELDS if config.darwin_resources else ()),
    )
    ratios = {
        field: paired_ratio(
            samples,
            field,
            resamples=config.bootstrap_resamples,
            seed=config.bootstrap_seed,
            confidence=config.confidence,
        )
        for field in ratio_fields
    }
    median_fields = (
        "load_ms",
        "request_ready_ms",
        "prefill_ms",
        "decode_ms",
        "sampling_ms",
        "internal_ms",
        "harness_wall_ms",
        *(RESOURCE_MEDIAN_FIELDS if config.darwin_resources else ()),
    )
    medians = {
        variant: {
            field: statistics.median(
                float(sample["metrics"][field])
                for sample in samples
                if sample["variant"] == variant
            )
            for field in median_fields
        }
        for variant in VARIANTS
    }

    binary_sha256 = str(artifact_before["binary"]["sha256"])
    output_capture_contract = (
        _load_resource_support()._process_output_capture_contract()
    )
    output_capture_contract["raw_reserved_prefix_guard"]["additional_prefixes"] = [
        "pair_nibble:",
        "pair_scratch:",
    ]
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "evidence-valid",
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "python": sys.version,
        },
        "process_output_capture_contract": output_capture_contract,
        "contract": {
            "samples_per_variant": config.samples_per_variant,
            "warmups_per_variant": config.warmups_per_variant,
            "prompt_tokens": len(prompt_ids),
            "new_tokens": config.new_tokens,
            "threads": config.threads,
            "prefill": config.prefill,
            "prefill_chunk_rows": PREFILL_CHUNK_ROWS,
            "layers": layers,
            "pair_nibble_storage_abi": storage_abi,
            "pair_nibble_executor_abi": executor_abi,
            "variants": list(VARIANTS),
            "strict_prepared_glrt": True,
            "strict_pair_nibble_required": True,
            "strict_glrt_v2_equivalence_proof_required": True,
            "strict_materialized_greedy_output_required": True,
            "zero_fallbacks_rejects_and_sealed_dispatches_required": True,
            "exact_m1_m4_tail_coverage_required": True,
            "equal_mlp_producer_bytes_required": True,
            "mlp_producer_bytes_per_variant": {
                "separate": baseline_mlp_bytes,
                "pair-nibble-required": candidate_mlp_bytes,
            },
            "same_binary_required": True,
            "binary_sha256_by_variant": {
                variant: binary_sha256 for variant in VARIANTS
            },
            "model_sha256_by_variant": {
                "separate": artifact_before["separate_model"]["sha256"],
                "pair-nibble-required": artifact_before["pair_model"]["sha256"],
            },
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": "pair-nibble-required", "B": "separate"},
            "bootstrap_resamples": config.bootstrap_resamples,
            "exact_completion_ids_required_across_all_invocations": True,
            "darwin_resource_mode": config.darwin_resources,
            "publishable_resource_measurements": config.darwin_resources,
            "resource_wrapper": (
                "/usr/bin/time -lp -o <per-observation-record>"
                if config.darwin_resources
                else None
            ),
            "resource_ratio_fields": (
                list(RESOURCE_RATIO_FIELDS) if config.darwin_resources else []
            ),
        },
        "artifacts_before": artifact_before,
        "artifacts_after": artifact_after,
        "glrt_pair_equivalence": glrt_proof,
        "prompt_ids": {
            "count": len(prompt_ids),
            "normalized_sha256": sha256_bytes(canonical_ids_bytes(prompt_ids)),
        },
        "completion_equivalence": {
            "exact_ids_match": True,
            "token_count": len(reference_ids),
            "token_ids": reference_ids,
            "normalized_sha256": sha256_bytes(canonical_ids_bytes(reference_ids)),
            "distinct_normalized_hashes": sorted(
                {item["completion_ids_sha256"] for item in [*warmups, *samples]}
            ),
        },
        "warmups": warmups,
        "samples": samples,
        "medians": medians,
        "separate_over_pair_nibble": ratios,
        "resource_evidence": {
            "enabled": config.darwin_resources,
            "measurements_publishable": config.darwin_resources,
            "required_platform_and_timer": "Darwin /usr/bin/time",
            "units": RESOURCE_UNITS if config.darwin_resources else {},
            "paired_ratio_fields": (
                list(RESOURCE_RATIO_FIELDS) if config.darwin_resources else []
            ),
        },
    }
    json.dumps(result, allow_nan=False)
    return result


def write_result(
    result: Mapping[str, Any], output: Path | None, overwrite: bool
) -> None:
    _load_resource_support().write_resource_result(result, output, overwrite)


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


def argument_parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Run a tokenizer-pinned same-binary/two-GLRT paired A/B between "
            "separate and strict PairNibble MLP execution."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument(
        "--separate-model",
        "--baseline-model",
        dest="separate_model",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--pair-model",
        "--candidate-model",
        dest="pair_model",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--ids",
        type=Path,
        default=repo_root / "bench" / "eval-qwen2.5.ids",
    )
    parser.add_argument("-o", "--output", required=True, help="result JSON path or '-'")
    parser.add_argument("--cwd", type=Path, default=repo_root)
    parser.add_argument("--prefill", choices=("batch", "serial"), default="batch")
    parser.add_argument(
        "--samples-per-variant",
        "--samples",
        dest="samples_per_variant",
        type=_positive_int,
        default=DEFAULT_SAMPLES_PER_VARIANT,
    )
    parser.add_argument(
        "--warmups-per-variant",
        "--warmups",
        dest="warmups_per_variant",
        type=_positive_int,
        default=DEFAULT_WARMUPS_PER_VARIANT,
    )
    parser.add_argument("-n", "--new-tokens", type=_positive_int, default=64)
    parser.add_argument("-t", "--threads", type=_positive_int, default=4)
    parser.add_argument(
        "--schedule-seed", type=_nonnegative_int, default=DEFAULT_SCHEDULE_SEED
    )
    parser.add_argument(
        "--bootstrap-seed", type=_nonnegative_int, default=DEFAULT_BOOTSTRAP_SEED
    )
    parser.add_argument(
        "--bootstrap-resamples",
        type=_positive_int,
        default=DEFAULT_BOOTSTRAP_RESAMPLES,
    )
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument(
        "--darwin-resources",
        action="store_true",
        help=(
            "wrap every invocation in Darwin /usr/bin/time -lp and include "
            "paired RSS/footprint/CPU/instruction/cycle evidence"
        ),
    )
    parser.add_argument("--time-binary", type=Path, default=Path("/usr/bin/time"))
    parser.add_argument("--binary-sha256")
    parser.add_argument("--separate-model-sha256")
    parser.add_argument("--pair-model-sha256")
    parser.add_argument("--ids-sha256")
    parser.add_argument("--time-sha256")
    parser.add_argument("--overwrite", action="store_true")
    return parser


def config_from_args(args: argparse.Namespace) -> Config:
    output = None if args.output == "-" else Path(args.output).expanduser().resolve()
    return Config(
        binary=args.binary.expanduser().resolve(),
        separate_model=args.separate_model.expanduser().resolve(),
        pair_model=args.pair_model.expanduser().resolve(),
        ids=args.ids.expanduser().resolve(),
        output=output,
        cwd=args.cwd.expanduser().resolve(),
        prefill=args.prefill,
        samples_per_variant=args.samples_per_variant,
        warmups_per_variant=args.warmups_per_variant,
        new_tokens=args.new_tokens,
        threads=args.threads,
        schedule_seed=args.schedule_seed,
        bootstrap_seed=args.bootstrap_seed,
        bootstrap_resamples=args.bootstrap_resamples,
        confidence=args.confidence,
        timeout_seconds=args.timeout_seconds,
        overwrite=args.overwrite,
        binary_sha256=args.binary_sha256,
        separate_model_sha256=args.separate_model_sha256,
        pair_model_sha256=args.pair_model_sha256,
        ids_sha256=args.ids_sha256,
        darwin_resources=args.darwin_resources,
        time_binary=args.time_binary.expanduser().resolve(),
        time_sha256=args.time_sha256,
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = argument_parser().parse_args(argv)
    try:
        config = config_from_args(args)
        if (
            config.output is not None
            and config.output.exists()
            and not config.overwrite
        ):
            raise HarnessError(
                f"output already exists; pass --overwrite to replace it: {config.output}"
            )
        result = run_benchmark(config)
        write_result(result, config.output, config.overwrite)
        return 0
    except (HarnessError, OSError, ValueError) as error:
        sys.stderr.write(f"error: {error}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
