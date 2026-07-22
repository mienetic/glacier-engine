#!/usr/bin/env python3
"""Same-binary materialized/logitless-required greedy-output A/B benchmark."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import platform
import random
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


def _load_attention_support():
    """Load sibling benchmark support without relying on the caller's path."""
    module_name = "_glacier_greedy_attention_ab_support"
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

SCHEMA = "glacier.greedy-output-ab/result-v2"
VARIANTS = ("materialized", "logitless-required")
DEFAULT_SAMPLES_PER_VARIANT = 32
DEFAULT_WARMUPS_PER_VARIANT = 2
DEFAULT_THRESHOLD = 128
DEFAULT_SCHEDULE_SEED = 20_260_720
DEFAULT_BOOTSTRAP_SEED = 0x4752454544594F55
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1
MAX_I64 = (1 << 63) - 1
GREEDY_ARGMAX_ABI = "474c4d4800000002"
SHA256_RE = re.compile(r"[0-9a-f]{64}")

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
    model: Path
    ids: Path
    output: Path | None
    cwd: Path
    threshold: int = DEFAULT_THRESHOLD
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


def fingerprint_artifacts(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.model.suffix.lower() != ".glrt":
        raise HarnessError("strict greedy-output A/B requires a .glrt model path")
    declarations = {
        "driver": (Path(__file__).resolve(), None),
        "attention_ab_support": (Path(_attention.__file__).resolve(), None),
        "binary": (config.binary, config.binary_sha256),
        "model": (config.model, config.model_sha256),
        "prompt_ids": (config.ids, config.ids_sha256),
    }
    return {
        name: _attention.fingerprint(path, name, expected)
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
        materialized = [
            value for block in selected for value in block["materialized"]
        ]
        logitless = [
            value for block in selected for value in block["logitless-required"]
        ]
        return statistics.median(materialized) / statistics.median(logitless)

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
        "direction": (
            "materialized_over_logitless; greater than 1 favors "
            "logitless-required"
        ),
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


def parse_telemetry(
    output: str,
    *,
    variant: str,
    prompt_tokens: int,
    new_tokens: int,
    threshold: int,
    require_fused_gqa: bool = False,
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")

    metrics = _attention.parse_telemetry(
        output,
        variant="parallel",
        prompt_tokens=prompt_tokens,
        new_tokens=new_tokens,
        threshold=threshold,
        require_fused_gqa=require_fused_gqa,
        require_paired_mlp=require_fused_gqa,
    )
    phase = _exactly_one_valid(
        output, "phases:", _attention._PHASES_RE, "stable phase"
    )
    greedy = _exactly_one_valid(
        output, "greedy_output:", _GREEDY_OUTPUT_RE, "greedy-output"
    )
    reported_variant = greedy.group(1).lower()
    if reported_variant != variant:
        raise HarnessError(
            f"greedy-output mode was {reported_variant}, expected {variant}"
        )

    materialized = _counter(greedy.group(2), "materialized projections")
    logitless = _counter(greedy.group(3), "logitless projections")
    producer_rows = _counter(greedy.group(4), "producer rows")
    tile_output_bytes = _counter(greedy.group(5), "tile-output bytes")
    argmax_scan_rows = _counter(greedy.group(6), "argmax scan rows")
    scratch_bytes = _counter(greedy.group(7), "greedy scratch bytes")
    materialized_logits_bytes = _counter(
        greedy.group(8), "materialized logits bytes"
    )
    reclaimed_bytes = _counter(greedy.group(9), "steady-state reclaimed bytes")
    fallbacks = _counter(greedy.group(10), "greedy-output fallbacks")
    rejects = _counter(greedy.group(11), "greedy-output rejects")
    abi_value = int(greedy.group(12), 16)
    if abi_value == 0 or abi_value > MAX_U64:
        raise HarnessError("greedy-output ABI must be a non-zero uint64")
    abi = f"{abi_value:016x}"
    if abi != GREEDY_ARGMAX_ABI:
        raise HarnessError(
            f"greedy-output ABI was {abi}, expected {GREEDY_ARGMAX_ABI}"
        )

    decode_runs = int(metrics["decode_runs"])
    layers = int(metrics["attention_layers"])
    expected_dispatches = decode_runs * layers
    if decode_runs <= 0:
        raise HarnessError("greedy-output A/B requires at least one decode graph")
    if (
        int(metrics["parallel_attention_graphs"]) != decode_runs
        or int(metrics["handoff_graphs"]) != decode_runs
        or int(metrics["parallel_attention_dispatches"]) != expected_dispatches
        or int(metrics["handoff_dispatches"]) != expected_dispatches
    ):
        raise HarnessError(
            "greedy-output A/B requires complete parallel HandoffGraph coverage"
        )
    if fallbacks != 0 or rejects != 0:
        raise HarnessError(
            "successful greedy-output evidence must have zero fallbacks/rejects"
        )
    if materialized_logits_bytes <= 0:
        raise HarnessError("materialized logits bytes must be positive")
    if materialized_logits_bytes % 4 != 0:
        raise HarnessError("materialized logits bytes must contain whole f32 rows")
    vocab_rows = materialized_logits_bytes // 4

    if variant == "materialized":
        expected = {
            "materialized_projections": new_tokens,
            "logitless_projections": 0,
            "producer_rows": 0,
            "tile_output_bytes": 0,
            "argmax_scan_rows": 0,
            "scratch_bytes": 0,
            "steady_state_reclaimed_bytes": 0,
        }
    else:
        expected = {
            "materialized_projections": 1,
            "logitless_projections": new_tokens - 1,
            "producer_rows": (new_tokens - 1) * vocab_rows,
            "tile_output_bytes": 0,
            "argmax_scan_rows": 0,
            "scratch_bytes": scratch_bytes,
            "steady_state_reclaimed_bytes": materialized_logits_bytes,
        }
        if scratch_bytes <= 0:
            raise HarnessError("logitless-required must report positive scratch bytes")
        if scratch_bytes >= materialized_logits_bytes:
            raise HarnessError(
                "logitless scratch payload must be smaller than reclaimed logits payload"
            )
    observed = {
        "materialized_projections": materialized,
        "logitless_projections": logitless,
        "producer_rows": producer_rows,
        "tile_output_bytes": tile_output_bytes,
        "argmax_scan_rows": argmax_scan_rows,
        "scratch_bytes": scratch_bytes,
        "steady_state_reclaimed_bytes": reclaimed_bytes,
    }
    if observed != expected:
        raise HarnessError(
            f"greedy-output counters for {variant} were {observed}, expected {expected}"
        )

    metrics.update(
        {
            "greedy_output_mode": reported_variant,
            "greedy_materialized_projections": materialized,
            "greedy_logitless_projections": logitless,
            "greedy_producer_rows": producer_rows,
            "greedy_tile_output_bytes": tile_output_bytes,
            "greedy_argmax_scan_rows": argmax_scan_rows,
            "greedy_scratch_bytes": scratch_bytes,
            "greedy_materialized_logits_bytes": materialized_logits_bytes,
            "greedy_steady_state_reclaimed_bytes": reclaimed_bytes,
            "greedy_fallbacks": fallbacks,
            "greedy_rejects": rejects,
            "greedy_output_abi": abi,
            "stable_phase_line_sha256": sha256_bytes(
                phase.group(0).strip().encode("utf-8")
            ),
            "greedy_output_line_sha256": sha256_bytes(
                greedy.group(0).strip().encode("utf-8")
            ),
        }
    )
    return metrics


def build_command(config: Config, variant: str, completion_path: Path) -> list[str]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")
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
        "--parallel-attention-min-context",
        str(config.threshold),
        "--decode-plan",
        "checked",
        "--greedy-output",
        variant,
        "--out-ids-file",
        str(completion_path),
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
        process.communicate()
        raise HarnessError(
            f"Glacier timed out after {timeout_seconds} seconds"
        ) from error
    wall_ms = (time.perf_counter_ns() - started) / 1e6
    decoded = output.decode("utf-8", errors="replace")
    if process.returncode != 0:
        raise HarnessError(f"Glacier exited with {process.returncode}:\n{decoded}")
    if not math.isfinite(wall_ms) or wall_ms <= 0:
        raise HarnessError("harness wall timing is not finite and positive")
    return {
        "output": decoded,
        "raw_output_sha256": sha256_bytes(output),
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
    if completion_path.exists():
        raise HarnessError(f"completion path unexpectedly exists: {completion_path}")
    command = build_command(config, variant, completion_path)
    process = _run_process(command, config.cwd, config.timeout_seconds)
    _attention.assert_artifact_identities(artifact_before)
    if not completion_path.is_file():
        raise HarnessError("Glacier did not create the required completion-ID file")
    try:
        completion_raw = completion_path.read_bytes()
        completion_path.unlink()
    except OSError as error:
        raise HarnessError(f"cannot consume completion IDs: {error}") from error
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
    )
    metrics["harness_wall_ms"] = process["wall_ms"]
    return {
        "variant": variant,
        "argv": command,
        "metrics": metrics,
        "completion_ids": completion_ids,
        "completion_ids_sha256": sha256_bytes(canonical_ids_bytes(completion_ids)),
        "completion_file_sha256": sha256_bytes(completion_raw),
        "telemetry_sha256": process["raw_output_sha256"],
        "exit_status": process["exit_status"],
    }


def validate_config(config: Config) -> None:
    if config.threshold <= 0 or config.threshold > MAX_I64:
        raise HarnessError("parallel attention threshold must be a positive int64")
    if config.samples_per_variant > 10_000:
        raise HarnessError("samples per variant must not exceed 10000")
    build_patterns(config.samples_per_variant, config.schedule_seed)
    if not 1 <= config.warmups_per_variant <= 100:
        raise HarnessError("warmups per variant must be in [1, 100]")
    if not 2 <= config.new_tokens <= 1_000_000:
        raise HarnessError("greedy-output A/B new tokens must be in [2, 1000000]")
    if not 2 <= config.threads <= 65_536:
        raise HarnessError("strict greedy-output A/B threads must be in [2, 65536]")
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
        Path(_attention.__file__).resolve(),
    }
    if len(input_paths) != 5:
        raise HarnessError(
            "binary, model, IDs, driver, and support module must be distinct files"
        )
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
    if len(prompt_ids) + 1 < config.threshold:
        raise HarnessError(
            "parallel threshold would leave early decode graphs outside the A/B path"
        )
    patterns = build_patterns(config.samples_per_variant, config.schedule_seed)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    layers: int | None = None
    greedy_output_abi: str | None = None
    materialized_logits_bytes: int | None = None
    logitless_scratch_bytes: int | None = None
    phase_signature: tuple[int, ...] | None = None
    with tempfile.TemporaryDirectory(prefix="glacier-greedy-output-ab.") as temporary:
        completion_path = Path(temporary) / "completion.ids"

        def observe(
            variant: str,
            *,
            warmup: bool,
            sequence_index: int,
            block_index: int,
            position_in_block: int,
            pattern: str,
        ) -> dict[str, Any]:
            nonlocal reference_ids
            nonlocal layers
            nonlocal greedy_output_abi
            nonlocal materialized_logits_bytes
            nonlocal logitless_scratch_bytes
            nonlocal phase_signature
            item = run_variant(
                config,
                variant,
                completion_path,
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
            observed_layers = int(item["metrics"]["attention_layers"])
            if layers is None:
                layers = observed_layers
            elif observed_layers != layers:
                raise HarnessError("attention layer count changed during A/B")
            observed_abi = str(item["metrics"]["greedy_output_abi"])
            if greedy_output_abi is None:
                greedy_output_abi = observed_abi
            elif observed_abi != greedy_output_abi:
                raise HarnessError("greedy-output ABI changed during A/B")
            observed_logits_bytes = int(
                item["metrics"]["greedy_materialized_logits_bytes"]
            )
            if materialized_logits_bytes is None:
                materialized_logits_bytes = observed_logits_bytes
            elif observed_logits_bytes != materialized_logits_bytes:
                raise HarnessError("materialized logits bytes changed during A/B")
            if variant == "logitless-required":
                observed_scratch = int(item["metrics"]["greedy_scratch_bytes"])
                if logitless_scratch_bytes is None:
                    logitless_scratch_bytes = observed_scratch
                elif observed_scratch != logitless_scratch_bytes:
                    raise HarnessError("logitless scratch bytes changed during A/B")
            observed_signature = tuple(
                int(item["metrics"][field])
                for field in (
                    "decode_runs",
                    "parallel_attention_graphs",
                    "parallel_attention_dispatches",
                    "handoff_graphs",
                    "handoff_dispatches",
                    "fused_gqa_graphs",
                    "fused_gqa_dispatches",
                    "paired_mlp_graphs",
                    "paired_mlp_dispatches",
                )
            )
            if phase_signature is None:
                phase_signature = observed_signature
            elif observed_signature != phase_signature:
                raise HarnessError("stable phase coverage changed during A/B")
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
                variant = "logitless-required" if letter == "A" else "materialized"
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
    assert greedy_output_abi is not None
    assert materialized_logits_bytes is not None
    assert logitless_scratch_bytes is not None

    ratio_fields = ("decode_ms", "internal_ms", "harness_wall_ms")
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
        "prefill_ms",
        "decode_ms",
        "sampling_ms",
        "internal_ms",
        "harness_wall_ms",
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
    latency_failures: list[str] = []
    for field in ratio_fields:
        if float(ratios[field]["ci_low"]) < 1.0:
            latency_failures.append(f"{field}.ci_low < 1.00")
    if float(ratios["decode_ms"]["estimate"]) < 1.02:
        latency_failures.append("decode_ms.estimate < 1.02")
    latency_gate = {
        "status": "passed" if not latency_failures else "failed",
        "requirements": {
            "decode_ms_ci_low_min": 1.0,
            "internal_ms_ci_low_min": 1.0,
            "harness_wall_ms_ci_low_min": 1.0,
            "decode_ms_estimate_min": 1.02,
        },
        "failures": latency_failures,
    }
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
        "contract": {
            "samples_per_variant": config.samples_per_variant,
            "warmups_per_variant": config.warmups_per_variant,
            "prompt_tokens": len(prompt_ids),
            "new_tokens": config.new_tokens,
            "threads": config.threads,
            "parallel_attention_min_context": config.threshold,
            "decode_plan_mode": "checked",
            "require_fused_gqa": config.require_fused_gqa,
            "require_paired_mlp": config.require_fused_gqa,
            "attention_layers": layers,
            "expected_decode_runs": config.new_tokens - 1,
            "expected_materialized_projections": config.new_tokens,
            "expected_logitless_projections": config.new_tokens - 1,
            "expected_producer_rows": (
                (config.new_tokens - 1) * (materialized_logits_bytes // 4)
            ),
            "required_tile_output_bytes": 0,
            "required_argmax_scan_rows": 0,
            "greedy_output_abi": greedy_output_abi,
            "materialized_logits_bytes": materialized_logits_bytes,
            "logitless_scratch_bytes": logitless_scratch_bytes,
            "greedy_output_modes": list(VARIANTS),
            "strict_logitless_required": True,
            "zero_fallbacks_and_rejects_required": True,
            "strict_prepared_glrt": True,
            "strict_batch_prefill": True,
            "temperature_zero": True,
            "eos_disabled_with_uint32_max": True,
            "complete_parallel_handoff_coverage_required": True,
            "stable_phase_telemetry_required": True,
            "exact_greedy_output_telemetry_required": True,
            "same_binary_required": True,
            "binary_sha256_by_variant": {
                variant: binary_sha256 for variant in VARIANTS
            },
            "only_greedy_output_policy_varies": True,
            "constant_completion_output_path": True,
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": "logitless-required", "B": "materialized"},
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
        "materialized_over_logitless": ratios,
        "promotion_gates": {
            "latency": latency_gate,
            "overall_status": (
                "pending-resource-and-size-gates"
                if not latency_failures
                else "failed"
            ),
            "external_gates_required": [
                "TG512 upper regression bound <= 1%",
                "CPU/instruction interval resolves in favor of logitless-required",
                "peak memory <= 1% regression",
                "same-strip-policy production binary size budget",
            ],
        },
    }
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
        if overwrite:
            os.replace(temporary, output)
        else:
            try:
                os.link(temporary, output, follow_symlinks=False)
            except FileExistsError as error:
                raise HarnessError(
                    f"output already exists; refusing replacement: {output}"
                ) from error
            temporary.unlink()
        temporary = None
        directory_descriptor = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
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
            "Run a tokenizer-pinned, same-binary paired A/B between materialized "
            "and strict logitless-required greedy LM-head execution."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument(
        "--ids",
        type=Path,
        default=repo_root / "bench" / "eval-qwen2.5.ids",
        help="prompt IDs (defaults to the pinned 176-token Qwen fixture)",
    )
    parser.add_argument("-o", "--output", required=True, help="result JSON path or '-'")
    parser.add_argument("--cwd", type=Path, default=repo_root)
    parser.add_argument("--threshold", type=_positive_int, default=DEFAULT_THRESHOLD)
    parser.add_argument(
        "--samples-per-variant",
        "--samples-per-mode",
        dest="samples_per_variant",
        type=_positive_int,
        default=DEFAULT_SAMPLES_PER_VARIANT,
    )
    parser.add_argument(
        "--warmups-per-variant",
        "--warmups-per-mode",
        dest="warmups_per_variant",
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
        help="fail unless every decode graph uses fused shared-K/V GQA",
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
        if config.output is not None and config.output.exists() and not config.overwrite:
            raise HarnessError(
                f"output already exists; pass --overwrite to replace it: {config.output}"
            )
        result = run_benchmark(config)
        write_result(result, config.output, config.overwrite)
        return 0
    except KeyboardInterrupt:
        sys.stderr.write("error: benchmark interrupted\n")
        return 130
    except Exception as error:  # Keep the command-line boundary traceback-free.
        message = str(error) or type(error).__name__
        sys.stderr.write(f"error: {message}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
