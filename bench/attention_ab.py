#!/usr/bin/env python3
"""Paired serial/parallel attention A/B benchmark for Glacier GLRT execution."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import random
import re
import signal
import stat
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA = "glacier.attention-ab/result-v3"
VARIANTS = ("serial", "parallel")
DEFAULT_SAMPLES_PER_VARIANT = 20
DEFAULT_WARMUPS_PER_VARIANT = 1
DEFAULT_SCHEDULE_SEED = 20_260_719
DEFAULT_BOOTSTRAP_SEED = 0x415454454E54494F
DEFAULT_BOOTSTRAP_RESAMPLES = 10_000
MAX_U32 = (1 << 32) - 1
MAX_I64 = (1 << 63) - 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")

_LOAD_RE = re.compile(
    r"^[^\S\r\n]*load:[^\S\r\n]+mode=(prepared|materialized)"
    r"[^\S\r\n]+artifact=(glrt|glacier)[^\S\r\n]+ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_READY_RE = re.compile(
    r"^[^\S\r\n]*ready:[^\S\r\n]+phase=request_ready[^\S\r\n]+ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_SCHEDULE_RE = re.compile(
    r"^[^\S\r\n]*schedule:[^\S\r\n]+attention=(serial|parallel)"
    r"(?:[^\S\r\n]+min_context=([1-9][0-9]*))?"
    r"[^\S\r\n]+layers=([1-9][0-9]*)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_PHASES_RE = re.compile(
    r"^[^\S\r\n]*phases:[^\S\r\n]+prefill_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+sampling_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_runs=([0-9]+)"
    r"[^\S\r\n]+attention_graphs=([0-9]+)"
    r"[^\S\r\n]+attention_dispatches=([0-9]+)"
    r"[^\S\r\n]+handoff_graphs=([0-9]+)"
    r"[^\S\r\n]+handoff_dispatches=([0-9]+)"
    r"[^\S\r\n]+fused_gqa_graphs=([0-9]+)"
    r"[^\S\r\n]+fused_gqa_dispatches=([0-9]+)"
    r"[^\S\r\n]+paired_mlp_graphs=([0-9]+)"
    r"[^\S\r\n]+paired_mlp_dispatches=([0-9]+)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_TOTAL_RE = re.compile(
    r"^[^\S\r\n]*time:[^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*ms"
    r"[^\S\r\n]*\([^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*tok/s,"
    r"[^\S\r\n]*prefilled[^\S\r\n]+([0-9]+),[^\S\r\n]*prefill=(batch|serial)"
    r"[^\S\r\n]*\)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)


class HarnessError(RuntimeError):
    """The A/B run is invalid and must not be published as evidence."""


@dataclass(frozen=True)
class Config:
    binary: Path
    model: Path
    ids: Path
    output: Path | None
    cwd: Path
    threshold: int
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
    require_fused_gqa: bool = False
    binary_sha256: str | None = None
    model_sha256: str | None = None
    ids_sha256: str | None = None


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_ids_bytes(ids: Sequence[int]) -> bytes:
    return (" ".join(str(token) for token in ids) + "\n").encode("ascii")


def parse_ids(value: bytes | str, where: str) -> list[int]:
    if isinstance(value, bytes):
        try:
            text = value.decode("ascii")
        except UnicodeDecodeError as error:
            raise HarnessError(f"{where} must contain ASCII token IDs") from error
    else:
        text = value
    fields = text.split()
    if not fields:
        raise HarnessError(f"{where} contains no token IDs")
    result: list[int] = []
    for index, field in enumerate(fields):
        if re.fullmatch(r"0|[1-9][0-9]*", field) is None:
            raise HarnessError(
                f"{where} token {index} is not a canonical unsigned integer"
            )
        token = int(field)
        if token > MAX_U32:
            raise HarnessError(f"{where} token {index} exceeds uint32")
        result.append(token)
    return result


def _file_identity(path: Path, where: str) -> dict[str, int]:
    try:
        item = path.stat()
    except OSError as error:
        raise HarnessError(f"cannot stat {where} at {path}: {error}") from error
    if not stat.S_ISREG(item.st_mode):
        raise HarnessError(f"{where} is not a regular file: {path}")
    return {
        "device": item.st_dev,
        "inode": item.st_ino,
        "bytes": item.st_size,
        "mode": stat.S_IMODE(item.st_mode),
        "mtime_ns": item.st_mtime_ns,
        "ctime_ns": item.st_ctime_ns,
    }


def _hash_file(path: Path, where: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    byte_count = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
                byte_count += len(chunk)
    except OSError as error:
        raise HarnessError(f"cannot hash {where} at {path}: {error}") from error
    return digest.hexdigest(), byte_count


def fingerprint(path: Path, where: str, expected_sha256: str | None) -> dict[str, Any]:
    before = _file_identity(path, where)
    digest, byte_count = _hash_file(path, where)
    after = _file_identity(path, where)
    if before != after or byte_count != after["bytes"]:
        raise HarnessError(f"{where} changed while it was being fingerprinted")
    if expected_sha256 is not None and digest != expected_sha256:
        raise HarnessError(
            f"{where} SHA-256 mismatch: expected {expected_sha256}, got {digest}"
        )
    return {
        "path": str(path),
        "bytes": byte_count,
        "sha256": digest,
        "identity": after,
        "expected_sha256": expected_sha256,
        "expected_sha256_matches": expected_sha256 is None or digest == expected_sha256,
    }


def fingerprint_artifacts(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.model.suffix.lower() != ".glrt":
        raise HarnessError("strict attention A/B requires a .glrt model path")
    declarations = {
        "driver": (Path(__file__).resolve(), None),
        "binary": (config.binary, config.binary_sha256),
        "model": (config.model, config.model_sha256),
        "prompt_ids": (config.ids, config.ids_sha256),
    }
    return {
        name: fingerprint(path, name, expected)
        for name, (path, expected) in declarations.items()
    }


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


def assert_artifact_identities(before: Mapping[str, Mapping[str, Any]]) -> None:
    for name, item in before.items():
        if _file_identity(Path(str(item["path"])), name) != item["identity"]:
            raise HarnessError(
                f"artifact {name} filesystem identity changed during A/B"
            )


def build_patterns(samples_per_variant: int, seed: int) -> list[str]:
    if samples_per_variant < 4 or samples_per_variant % 4 != 0:
        raise HarnessError("samples per variant must be at least 4 and divisible by 4")
    pattern_pairs = samples_per_variant // 4
    patterns = ["ABBA"] * pattern_pairs + ["BAAB"] * pattern_pairs
    random.Random(seed).shuffle(patterns)
    return patterns


def percentile(values: Sequence[float], probability: float) -> float:
    if not values:
        raise HarnessError("cannot calculate a percentile of no values")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


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
        block = blocks.setdefault(
            int(sample["block_index"]), {variant: [] for variant in VARIANTS}
        )
        block[str(sample["variant"])].append(numeric)
    ordered = [blocks[index] for index in sorted(blocks)]
    if not ordered or any(
        len(block[variant]) != 2 for block in ordered for variant in VARIANTS
    ):
        raise HarnessError(
            "paired bootstrap requires two observations per variant per block"
        )

    def ratio(selected: Sequence[Mapping[str, Sequence[float]]]) -> float:
        serial = [value for block in selected for value in block["serial"]]
        parallel = [value for block in selected for value in block["parallel"]]
        return statistics.median(serial) / statistics.median(parallel)

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
        "direction": "serial_over_parallel; greater than 1 favors parallel",
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


def _finite_nonnegative(value: str, where: str) -> float:
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise HarnessError(f"{where} must be finite and non-negative")
    return result


def parse_telemetry(
    output: str,
    *,
    variant: str,
    prompt_tokens: int,
    new_tokens: int,
    threshold: int,
    require_fused_gqa: bool = False,
    require_paired_mlp: bool = False,
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")
    load = _exactly_one_valid(output, "load:", _LOAD_RE, "load")
    ready = _exactly_one_valid(output, "ready:", _READY_RE, "request-ready")
    schedule = _exactly_one_valid(output, "schedule:", _SCHEDULE_RE, "schedule")
    phases = _exactly_one_valid(output, "phases:", _PHASES_RE, "phase")
    total = _exactly_one_valid(output, "time:", _TOTAL_RE, "total-time")
    if load.group(1).lower() != "prepared" or load.group(2).lower() != "glrt":
        raise HarnessError("run did not report a prepared GLRT load")
    if int(total.group(3)) != prompt_tokens or total.group(4).lower() != "batch":
        raise HarnessError(
            "run did not report the exact prompt count and batch prefill"
        )

    decode_runs = int(phases.group(4))
    expected_decode_runs = max(0, new_tokens - 1)
    if decode_runs != expected_decode_runs:
        raise HarnessError(
            f"decode graph count was {decode_runs}, expected {expected_decode_runs}"
        )
    layers = int(schedule.group(3))
    graphs = int(phases.group(5))
    dispatches = int(phases.group(6))
    handoff_graphs = int(phases.group(7))
    handoff_dispatches = int(phases.group(8))
    fused_gqa_graphs = int(phases.group(9))
    fused_gqa_dispatches = int(phases.group(10))
    paired_mlp_graphs = int(phases.group(11))
    paired_mlp_dispatches = int(phases.group(12))
    reported_variant = schedule.group(1).lower()
    reported_threshold = int(schedule.group(2)) if schedule.group(2) else None
    if variant == "serial":
        if reported_variant != "serial" or reported_threshold is not None:
            raise HarnessError("serial run did not report the explicit serial policy")
        expected_graphs = 0
    else:
        if reported_variant != "parallel" or reported_threshold != threshold:
            raise HarnessError("parallel run did not report the required threshold")
        expected_graphs = min(
            decode_runs,
            max(0, prompt_tokens + decode_runs - threshold + 1),
        )
    expected_dispatches = expected_graphs * layers
    if graphs != expected_graphs:
        raise HarnessError(
            f"parallel attention covered {graphs} graphs, expected {expected_graphs}"
        )
    if dispatches != expected_dispatches:
        raise HarnessError(
            f"parallel attention dispatched {dispatches} layers, expected {expected_dispatches}"
        )
    if handoff_graphs != expected_graphs:
        raise HarnessError(
            f"HandoffGraph covered {handoff_graphs} graphs, expected {expected_graphs}"
        )
    if handoff_dispatches != expected_dispatches:
        raise HarnessError(
            f"HandoffGraph dispatched {handoff_dispatches} layers, expected {expected_dispatches}"
        )
    if fused_gqa_graphs not in (0, expected_graphs):
        raise HarnessError(
            f"fused GQA covered {fused_gqa_graphs} graphs, expected zero or {expected_graphs}"
        )
    expected_fused_dispatches = fused_gqa_graphs * layers
    if fused_gqa_dispatches != expected_fused_dispatches:
        raise HarnessError(
            f"fused GQA dispatched {fused_gqa_dispatches} layers, expected {expected_fused_dispatches}"
        )
    if paired_mlp_graphs not in (0, expected_graphs):
        raise HarnessError(
            f"paired MLP covered {paired_mlp_graphs} graphs, expected zero or {expected_graphs}"
        )
    expected_paired_mlp_dispatches = paired_mlp_graphs * layers
    if paired_mlp_dispatches != expected_paired_mlp_dispatches:
        raise HarnessError(
            "paired MLP dispatched "
            f"{paired_mlp_dispatches} layers, expected {expected_paired_mlp_dispatches}"
        )
    if paired_mlp_graphs != 0 and handoff_graphs != expected_graphs:
        raise HarnessError("paired MLP coverage requires complete HandoffGraph coverage")
    if require_fused_gqa and variant == "parallel":
        if expected_graphs == 0:
            raise HarnessError(
                "required fused GQA campaign had no eligible parallel decode graphs"
            )
        if fused_gqa_graphs != expected_graphs:
            raise HarnessError(
                f"required fused GQA covered {fused_gqa_graphs} graphs, expected {expected_graphs}"
            )
    if require_paired_mlp and variant == "parallel":
        if expected_graphs == 0:
            raise HarnessError(
                "required paired MLP campaign had no eligible parallel decode graphs"
            )
        if paired_mlp_graphs != expected_graphs:
            raise HarnessError(
                "required paired MLP covered "
                f"{paired_mlp_graphs} graphs, expected {expected_graphs}"
            )

    metrics: dict[str, Any] = {
        "load_ms": _finite_nonnegative(load.group(3), "load_ms"),
        "request_ready_ms": _finite_nonnegative(ready.group(1), "request_ready_ms"),
        "prefill_ms": _finite_nonnegative(phases.group(1), "prefill_ms"),
        "decode_ms": _finite_nonnegative(phases.group(2), "decode_ms"),
        "sampling_ms": _finite_nonnegative(phases.group(3), "sampling_ms"),
        "decode_runs": decode_runs,
        "parallel_attention_graphs": graphs,
        "parallel_attention_dispatches": dispatches,
        "handoff_graphs": handoff_graphs,
        "handoff_dispatches": handoff_dispatches,
        "fused_gqa_graphs": fused_gqa_graphs,
        "fused_gqa_dispatches": fused_gqa_dispatches,
        "paired_mlp_graphs": paired_mlp_graphs,
        "paired_mlp_dispatches": paired_mlp_dispatches,
        "attention_layers": layers,
        "internal_ms": _finite_nonnegative(total.group(1), "internal_ms"),
        "internal_tokens_per_second": _finite_nonnegative(
            total.group(2), "internal_tokens_per_second"
        ),
    }
    if metrics["prefill_ms"] <= 0 or metrics["internal_ms"] <= 0:
        raise HarnessError("prefill and internal timing must be positive")
    if decode_runs > 0 and metrics["decode_ms"] <= 0:
        raise HarnessError("decode timing must be positive when decode graphs ran")
    for name, value in metrics.items():
        if isinstance(value, int) and value > MAX_I64:
            raise HarnessError(
                f"metric {name} exceeds the signed 64-bit evidence bound"
            )
    return metrics


def build_command(config: Config, variant: str, completion_path: Path) -> list[str]:
    policy = (
        ["--serial-attention"]
        if variant == "serial"
        else ["--parallel-attention-min-context", str(config.threshold)]
    )
    return [
        str(config.binary),
        "generate",
        str(config.model),
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
        "--require-batch-prefill",
        "--require-prepared-image",
        "--out-ids-file",
        str(completion_path),
        *policy,
    ]


def _run_process(
    argv: Sequence[str], cwd: Path, timeout_seconds: float
) -> dict[str, Any]:
    started = time.perf_counter_ns()
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
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
        output, _ = process.communicate()
        raise HarnessError(
            f"Glacier timed out after {timeout_seconds} seconds"
        ) from error
    wall_ms = (time.perf_counter_ns() - started) / 1e6
    decoded = output.decode("utf-8", errors="replace")
    if process.returncode != 0:
        raise HarnessError(f"Glacier exited with {process.returncode}:\n{decoded}")
    if not math.isfinite(wall_ms) or wall_ms <= 0:
        raise HarnessError("harness wall timing is not finite and positive")
    return {"output": decoded, "wall_ms": wall_ms, "exit_status": process.returncode}


def run_variant(
    config: Config,
    variant: str,
    completion_path: Path,
    prompt_ids: Sequence[int],
    artifact_before: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    assert_artifact_identities(artifact_before)
    if completion_path.exists():
        raise HarnessError(f"completion path unexpectedly exists: {completion_path}")
    command = build_command(config, variant, completion_path)
    process = _run_process(command, config.cwd, config.timeout_seconds)
    assert_artifact_identities(artifact_before)
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
        process["output"],
        variant=variant,
        prompt_tokens=len(prompt_ids),
        new_tokens=config.new_tokens,
        threshold=config.threshold,
        require_fused_gqa=config.require_fused_gqa,
        require_paired_mlp=config.require_fused_gqa,
    )
    metrics["harness_wall_ms"] = process["wall_ms"]
    return {
        "variant": variant,
        "argv": command,
        "metrics": metrics,
        "completion_ids": completion_ids,
        "completion_ids_sha256": sha256_bytes(canonical_ids_bytes(completion_ids)),
        "completion_file_sha256": sha256_bytes(completion_raw),
        "telemetry_sha256": sha256_bytes(process["output"].encode("utf-8")),
        "exit_status": process["exit_status"],
    }


def validate_config(config: Config) -> None:
    if config.threshold <= 0 or config.threshold > MAX_I64:
        raise HarnessError("parallel attention threshold must be a positive int64")
    build_patterns(config.samples_per_variant, config.schedule_seed)
    if config.samples_per_variant > 10_000:
        raise HarnessError("samples per variant must not exceed 10000")
    if not 1 <= config.warmups_per_variant <= 100:
        raise HarnessError("warmups per variant must be in [1, 100]")
    if not 1 <= config.new_tokens <= 1_000_000:
        raise HarnessError("new tokens must be in [1, 1000000]")
    if not 1 <= config.threads <= 65_536:
        raise HarnessError("threads must be in [1, 65536]")
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
    input_paths = {
        config.binary,
        config.model,
        config.ids,
        Path(__file__).resolve(),
    }
    if len(input_paths) != 4:
        raise HarnessError("binary, model, IDs, and driver must be distinct files")
    if config.output is not None and config.output in input_paths:
        raise HarnessError("result output must not replace a benchmark input artifact")
    for name, digest in (
        ("binary", config.binary_sha256),
        ("model", config.model_sha256),
        ("ids", config.ids_sha256),
    ):
        if digest is not None and SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"{name} SHA-256 pin must be 64 lowercase hex digits")


def run_benchmark(config: Config) -> dict[str, Any]:
    validate_config(config)
    artifact_before = fingerprint_artifacts(config)
    try:
        prompt_ids = parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise HarnessError(f"cannot read prompt IDs: {error}") from error
    patterns = build_patterns(config.samples_per_variant, config.schedule_seed)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    layers: int | None = None
    with tempfile.TemporaryDirectory(prefix="glacier-attention-ab.") as temporary:
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
            nonlocal reference_ids, layers
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
                    f"exact completion IDs changed at {'warmup' if warmup else 'sample'} {sequence_index} ({variant})"
                )
            observed_layers = int(item["metrics"]["attention_layers"])
            if layers is None:
                layers = observed_layers
            elif observed_layers != layers:
                raise HarnessError(
                    "self-described attention layer count changed during A/B"
                )
            return item

        warmup_order = list(VARIANTS)
        if config.schedule_seed & 1:
            warmup_order.reverse()
        for ordinal in range(config.warmups_per_variant):
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
                variant = "parallel" if letter == "A" else "serial"
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
    ratio_fields = ("prefill_ms", "decode_ms", "internal_ms", "harness_wall_ms")
    ratios = {
        field: paired_ratio(
            samples,
            field,
            resamples=config.bootstrap_resamples,
            seed=config.bootstrap_seed,
            confidence=config.confidence,
        )
        for field in ratio_fields
        if all(float(sample["metrics"][field]) > 0 for sample in samples)
    }
    medians = {
        variant: {
            field: statistics.median(
                float(sample["metrics"][field])
                for sample in samples
                if sample["variant"] == variant
            )
            for field in (
                "prefill_ms",
                "decode_ms",
                "sampling_ms",
                "internal_ms",
                "harness_wall_ms",
            )
        }
        for variant in VARIANTS
    }
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "passed",
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "python": sys.version,
        },
        "contract": {
            "samples_per_variant": config.samples_per_variant,
            "warmups_per_variant": config.warmups_per_variant,
            "prompt_tokens": len(prompt_ids),
            "new_tokens": config.new_tokens,
            "threads": config.threads,
            "parallel_attention_min_context": config.threshold,
            "require_fused_gqa": config.require_fused_gqa,
            "require_paired_mlp": config.require_fused_gqa,
            "attention_layers": layers,
            "strict_prepared_glrt": True,
            "strict_batch_prefill": True,
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": "parallel", "B": "serial"},
            "exact_completion_ids_required_across_all_invocations": True,
        },
        "artifacts_before": artifact_before,
        "artifacts_after": artifact_after,
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
        "serial_over_parallel": ratios,
    }
    # Prove the full result can be represented by strict finite JSON before return.
    json.dumps(result, allow_nan=False)
    return result


def write_result(
    result: Mapping[str, Any], output: Path | None, overwrite: bool
) -> None:
    rendered = (
        json.dumps(
            result,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    )
    if output is None:
        sys.stdout.write(rendered)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and not overwrite:
        raise HarnessError(
            f"output already exists; pass --overwrite to replace it: {output}"
        )
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output.parent,
            prefix=f".{output.name}.",
            delete=False,
        ) as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        if output.exists() and not overwrite:
            raise HarnessError(
                f"output appeared during publication; refusing replacement: {output}"
            )
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
    sys.stderr.write(f"wrote {output}\n")


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
            "Run a tokenizer-pinned, process-cold/os-warm paired A/B between "
            "Glacier serial and thresholded parallel decode attention."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--ids", type=Path, required=True)
    parser.add_argument("-o", "--output", required=True, help="result JSON path or '-'")
    parser.add_argument("--cwd", type=Path, default=repo_root)
    parser.add_argument("--threshold", type=_positive_int, required=True)
    parser.add_argument(
        "--samples-per-variant",
        type=_positive_int,
        default=DEFAULT_SAMPLES_PER_VARIANT,
    )
    parser.add_argument(
        "--warmups-per-variant",
        type=_positive_int,
        default=DEFAULT_WARMUPS_PER_VARIANT,
    )
    parser.add_argument("--new-tokens", type=_positive_int, default=64)
    parser.add_argument("--threads", type=_positive_int, default=4)
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
    parser.add_argument("--binary-sha256")
    parser.add_argument("--model-sha256")
    parser.add_argument("--ids-sha256")
    parser.add_argument(
        "--require-fused-gqa",
        action="store_true",
        help="fail unless every eligible parallel graph executes fused shared-K/V GQA",
    )
    parser.add_argument("--overwrite", action="store_true")
    return parser


def config_from_args(args: argparse.Namespace) -> Config:
    output = None if args.output == "-" else Path(args.output).expanduser().resolve()
    return Config(
        binary=args.binary.expanduser().resolve(),
        model=args.model.expanduser().resolve(),
        ids=args.ids.expanduser().resolve(),
        output=output,
        cwd=args.cwd.expanduser().resolve(),
        threshold=args.threshold,
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
        require_fused_gqa=args.require_fused_gqa,
        binary_sha256=args.binary_sha256,
        model_sha256=args.model_sha256,
        ids_sha256=args.ids_sha256,
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
