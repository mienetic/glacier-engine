#!/usr/bin/env python3
"""Retained same-binary post-head/pre-head eligible-vocabulary A/B."""

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
    """Load sibling support without depending on the caller's import path."""
    module_name = "_glacier_eligibility_attention_ab_support"
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

SCHEMA = "glacier.eligibility-generation-ab/result-v1"
VARIANTS = ("domain-posthead-required", "domain-prehead-required")
DOMAINS = ("rotating64-v1", "static64-v1")
DEFAULT_DOMAIN = "rotating64-v1"
DEFAULT_SAMPLES_PER_VARIANT = 32
DEFAULT_WARMUPS_PER_VARIANT = 2
DEFAULT_THRESHOLD = 128
DEFAULT_SCHEDULE_SEED = 20_260_720
DEFAULT_BOOTSTRAP_SEED = 0x454C494749424C45
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
DOMAIN_ROWS = 64
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1
MAX_I64 = (1 << 63) - 1
GREEDY_ARGMAX_ABI = "474c4d4800000002"
ELIGIBILITY_PROVIDER_ABI = "474c564300000001"
ELIGIBILITY_EXECUTOR_ABI = "474c564900000001"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATHS = (
    Path("build.zig"),
    Path("build.zig.zon"),
    Path("src/root.zig"),
    Path("src/cli/main.zig"),
    Path("src/generate.zig"),
    Path("src/sampling.zig"),
    Path("src/int4_executor.zig"),
    Path("src/int4_weights.zig"),
    Path("src/loader.zig"),
    Path("src/backends/cpu/int4_matmul.zig"),
    Path("src/backends/cpu/kernels.zig"),
    Path("src/backends/cpu/int4_neon.c"),
)

_GREEDY_OUTPUT_RE = re.compile(
    r"^[^\S\r\n]*greedy_output:[^\S\r\n]+mode="
    r"(domain-posthead-required|domain-prehead-required)"
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
_ELIGIBLE_VOCAB_RE = re.compile(
    r"^[^\S\r\n]*eligible_vocab:[^\S\r\n]+mode="
    r"(posthead-required|prehead-required)"
    r"[^\S\r\n]+domain=(rotating64-v1|static64-v1)"
    r"[^\S\r\n]+provider_calls=([0-9]+)"
    r"[^\S\r\n]+certificates=([0-9]+)"
    r"[^\S\r\n]+posthead_projections=([0-9]+)"
    r"[^\S\r\n]+prehead_projections=([0-9]+)"
    r"[^\S\r\n]+eligible_rows=([0-9]+)"
    r"[^\S\r\n]+materialized_dot_rows=([0-9]+)"
    r"[^\S\r\n]+producer_rows=([0-9]+)"
    r"[^\S\r\n]+skipped_rows=([0-9]+)"
    r"[^\S\r\n]+overcomputed_rows=([0-9]+)"
    r"[^\S\r\n]+producer_runs=([0-9]+)"
    r"[^\S\r\n]+full_logits_rows_written=([0-9]+)"
    r"[^\S\r\n]+full_logits_peak_bytes=([0-9]+)"
    r"[^\S\r\n]+staging_mask_bytes=([0-9]+)"
    r"[^\S\r\n]+sealed_mask_bytes=([0-9]+)"
    r"[^\S\r\n]+executor_candidate_bytes=([0-9]+)"
    r"[^\S\r\n]+executor_tile_scratch_bytes=([0-9]+)"
    r"[^\S\r\n]+provider_ms=([0-9]+(?:\.[0-9]+)?)"
    r"[^\S\r\n]+verification_ms=([0-9]+(?:\.[0-9]+)?)"
    r"[^\S\r\n]+published_tokens=([0-9]+)"
    r"[^\S\r\n]+fallbacks=([0-9]+)"
    r"[^\S\r\n]+rejects=([0-9]+)"
    r"[^\S\r\n]+policy_sha256=([0-9a-f]{64})"
    r"[^\S\r\n]+last_mask_sha256=([0-9a-f]{64})"
    r"[^\S\r\n]+trace_sha256=([0-9a-f]{64})"
    r"[^\S\r\n]+provider_abi=([0-9a-f]{1,16})"
    r"[^\S\r\n]+executor_abi=([0-9a-f]{1,16})[^\S\r\n]*$",
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
    domain: str = DEFAULT_DOMAIN
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


def _fingerprint_declarations(
    declarations: Mapping[str, tuple[Path, str | None]],
) -> dict[str, dict[str, Any]]:
    return {
        name: _attention.fingerprint(path, name, expected)
        for name, (path, expected) in declarations.items()
    }


def fingerprint_sets(
    config: Config,
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.model.suffix.lower() != ".glrt":
        raise HarnessError("strict eligibility A/B requires a .glrt model path")
    artifacts = _fingerprint_declarations(
        {
            "driver": (Path(__file__).resolve(), None),
            "attention_ab_support": (Path(_attention.__file__).resolve(), None),
            "binary": (config.binary, config.binary_sha256),
            "model": (config.model, config.model_sha256),
            "prompt_ids": (config.ids, config.ids_sha256),
        }
    )
    sources = _fingerprint_declarations(
        {str(path): (REPO_ROOT / path, None) for path in SOURCE_PATHS}
    )
    return artifacts, sources


def _combined_fingerprints(
    artifacts: Mapping[str, Mapping[str, Any]],
    sources: Mapping[str, Mapping[str, Any]],
) -> dict[str, Mapping[str, Any]]:
    return {
        **{f"artifact:{name}": item for name, item in artifacts.items()},
        **{f"source:{name}": item for name, item in sources.items()},
    }


def verify_fingerprint_sets(
    config: Config,
    artifacts_before: Mapping[str, Mapping[str, Any]],
    sources_before: Mapping[str, Mapping[str, Any]],
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    artifacts_after, sources_after = fingerprint_sets(config)
    before = _combined_fingerprints(artifacts_before, sources_before)
    after = _combined_fingerprints(artifacts_after, sources_after)
    for name, item in before.items():
        if item["identity"] != after[name]["identity"]:
            raise HarnessError(f"{name} filesystem identity changed during A/B")
        if item["sha256"] != after[name]["sha256"]:
            raise HarnessError(f"{name} bytes changed during A/B")
    return artifacts_after, sources_after


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
    """Bootstrap whole ABBA/BAAB blocks, retaining both repeats per arm."""
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
            "paired bootstrap requires two observations per variant per full block"
        )

    def ratio(selected: Sequence[Mapping[str, Sequence[float]]]) -> float:
        post = [
            value for block in selected for value in block["domain-posthead-required"]
        ]
        pre = [
            value for block in selected for value in block["domain-prehead-required"]
        ]
        return statistics.median(post) / statistics.median(pre)

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
        "direction": "posthead_over_prehead; greater than 1 favors prehead",
        "estimate": ratio(ordered),
        "confidence": confidence,
        "ci_low": percentile(bootstrap, tail),
        "ci_high": percentile(bootstrap, 1.0 - tail),
        "bootstrap_unit": "complete_balanced_abba_or_baab_block",
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


def _abi(value: str, expected: str, where: str) -> str:
    numeric = int(value, 16)
    if numeric == 0 or numeric > MAX_U64:
        raise HarnessError(f"{where} ABI must be a non-zero uint64")
    canonical = f"{numeric:016x}"
    if canonical != expected:
        raise HarnessError(f"{where} ABI was {canonical}, expected {expected}")
    return canonical


def parse_telemetry(
    output: str,
    *,
    variant: str,
    domain: str,
    prompt_tokens: int,
    new_tokens: int,
    threshold: int,
    require_fused_gqa: bool = False,
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")
    if domain not in DOMAINS:
        raise HarnessError(f"unknown eligible domain: {domain}")
    metrics = _attention.parse_telemetry(
        output,
        variant="parallel",
        prompt_tokens=prompt_tokens,
        new_tokens=new_tokens,
        threshold=threshold,
        require_fused_gqa=require_fused_gqa,
        require_paired_mlp=require_fused_gqa,
    )
    phase = _exactly_one_valid(output, "phases:", _attention._PHASES_RE, "stable phase")
    greedy = _exactly_one_valid(
        output, "greedy_output:", _GREEDY_OUTPUT_RE, "greedy-output"
    )
    eligible = _exactly_one_valid(
        output, "eligible_vocab:", _ELIGIBLE_VOCAB_RE, "eligible-vocabulary"
    )
    reported_variant = greedy.group(1).lower()
    if reported_variant != variant:
        raise HarnessError(
            f"greedy-output mode was {reported_variant}, expected {variant}"
        )
    expected_eligible_mode = variant.removeprefix("domain-")
    if eligible.group(1).lower() != expected_eligible_mode:
        raise HarnessError(
            f"eligible-vocabulary mode was {eligible.group(1)}, "
            f"expected {expected_eligible_mode}"
        )
    if eligible.group(2).lower() != domain:
        raise HarnessError(
            f"eligible domain was {eligible.group(2)}, expected {domain}"
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
    greedy_values = {
        name: _counter(greedy.group(index), f"greedy {name}")
        for index, name in enumerate(greedy_names, start=2)
    }
    greedy_abi = _abi(greedy.group(12), GREEDY_ARGMAX_ABI, "greedy-output")

    eligible_names = (
        "provider_calls",
        "certificates",
        "posthead_projections",
        "prehead_projections",
        "eligible_rows",
        "materialized_dot_rows",
        "producer_rows",
        "skipped_rows",
        "overcomputed_rows",
        "producer_runs",
        "full_logits_rows_written",
        "full_logits_peak_bytes",
        "staging_mask_bytes",
        "sealed_mask_bytes",
        "executor_candidate_bytes",
        "executor_tile_scratch_bytes",
    )
    eligible_values = {
        name: _counter(eligible.group(index), f"eligible {name}")
        for index, name in enumerate(eligible_names, start=3)
    }
    provider_ms = float(eligible.group(19))
    verification_ms = float(eligible.group(20))
    if not math.isfinite(provider_ms) or provider_ms < 0:
        raise HarnessError("provider_ms must be finite and non-negative")
    if not math.isfinite(verification_ms) or verification_ms < 0:
        raise HarnessError("verification_ms must be finite and non-negative")
    published_tokens = _counter(eligible.group(21), "published tokens")
    eligible_fallbacks = _counter(eligible.group(22), "eligible fallbacks")
    eligible_rejects = _counter(eligible.group(23), "eligible rejects")
    provider_abi = _abi(
        eligible.group(27), ELIGIBILITY_PROVIDER_ABI, "eligibility-provider"
    )
    executor_abi = _abi(
        eligible.group(28), ELIGIBILITY_EXECUTOR_ABI, "eligibility-executor"
    )

    if greedy_values["fallbacks"] or greedy_values["rejects"]:
        raise HarnessError("greedy-output evidence requires zero fallbacks/rejects")
    if eligible_fallbacks or eligible_rejects:
        raise HarnessError(
            "eligible-vocabulary evidence requires zero fallbacks/rejects"
        )
    expected_heads = new_tokens
    expected_eligible_rows = expected_heads * DOMAIN_ROWS
    if expected_eligible_rows > MAX_I64:
        raise HarnessError("requested eligible-row evidence exceeds int64")
    common_observed = {
        "provider_calls": eligible_values["provider_calls"],
        "certificates": eligible_values["certificates"],
        "eligible_rows": eligible_values["eligible_rows"],
        "published_tokens": published_tokens,
    }
    common_expected = {
        "provider_calls": expected_heads,
        "certificates": expected_heads,
        "eligible_rows": expected_eligible_rows,
        "published_tokens": expected_heads,
    }
    if common_observed != common_expected:
        raise HarnessError(
            f"eligible head/certificate counters were {common_observed}, "
            f"expected {common_expected}"
        )

    if variant == "domain-posthead-required":
        logits_bytes = greedy_values["materialized_logits_bytes"]
        if logits_bytes <= 0 or logits_bytes % 4:
            raise HarnessError("post-head full logits must be positive whole f32 rows")
        vocab_rows = logits_bytes // 4
        expected_greedy = {
            "materialized_projections": expected_heads,
            "logitless_projections": 0,
            "producer_rows": 0,
            "tile_output_bytes": 0,
            "argmax_scan_rows": 0,
            "scratch_bytes": 0,
            "materialized_logits_bytes": vocab_rows * 4,
            "steady_state_reclaimed_bytes": 0,
            "fallbacks": 0,
            "rejects": 0,
        }
        expected_eligible = {
            "posthead_projections": expected_heads,
            "prehead_projections": 0,
            "materialized_dot_rows": expected_heads * vocab_rows,
            "producer_rows": 0,
            "skipped_rows": 0,
            "overcomputed_rows": 0,
            "producer_runs": 0,
            "full_logits_rows_written": expected_heads * vocab_rows,
            "full_logits_peak_bytes": vocab_rows * 4,
            "executor_candidate_bytes": 0,
            "executor_tile_scratch_bytes": 0,
        }
    else:
        producer_rows = eligible_values["producer_rows"]
        skipped_rows = eligible_values["skipped_rows"]
        total_rows = producer_rows + skipped_rows
        if total_rows > MAX_I64 or total_rows % expected_heads:
            raise HarnessError(
                "pre-head producer+skipped rows must divide into N heads"
            )
        vocab_rows = total_rows // expected_heads
        if not expected_eligible_rows <= producer_rows <= expected_heads * 256:
            raise HarnessError("pre-head producer rows must be 64..256 per head")
        expected_overcomputed = producer_rows - expected_eligible_rows
        producer_runs = eligible_values["producer_runs"]
        if not expected_heads <= producer_runs <= expected_eligible_rows:
            raise HarnessError("pre-head producer runs must be 1..64 per head")
        scratch_bytes = greedy_values["scratch_bytes"]
        tile_scratch_bytes = eligible_values["executor_tile_scratch_bytes"]
        if scratch_bytes <= 0 or tile_scratch_bytes <= 0:
            raise HarnessError(
                "pre-head execution must report positive bounded scratch"
            )
        expected_greedy = {
            "materialized_projections": 0,
            "logitless_projections": expected_heads,
            "producer_rows": producer_rows,
            "tile_output_bytes": 0,
            "argmax_scan_rows": 0,
            "scratch_bytes": scratch_bytes,
            "materialized_logits_bytes": 0,
            "steady_state_reclaimed_bytes": 0,
            "fallbacks": 0,
            "rejects": 0,
        }
        expected_eligible = {
            "posthead_projections": 0,
            "prehead_projections": expected_heads,
            "materialized_dot_rows": 0,
            "producer_rows": producer_rows,
            "skipped_rows": skipped_rows,
            "overcomputed_rows": expected_overcomputed,
            "producer_runs": producer_runs,
            "full_logits_rows_written": 0,
            "full_logits_peak_bytes": 0,
            "executor_candidate_bytes": scratch_bytes,
            "executor_tile_scratch_bytes": tile_scratch_bytes,
        }
    if vocab_rows < DOMAIN_ROWS:
        raise HarnessError("reported vocabulary is smaller than the 64-row domain")
    expected_total_rows = expected_heads * vocab_rows
    computed_dot_rows = (
        eligible_values["materialized_dot_rows"] + eligible_values["producer_rows"]
    )
    if computed_dot_rows + eligible_values["skipped_rows"] != expected_total_rows:
        raise HarnessError("dot rows plus skipped rows must equal N times vocabulary")
    if greedy_values != expected_greedy:
        raise HarnessError(
            f"greedy-output counters for {variant} were {greedy_values}, "
            f"expected {expected_greedy}"
        )
    observed_eligible = {name: eligible_values[name] for name in expected_eligible}
    if observed_eligible != expected_eligible:
        raise HarnessError(
            f"eligible-vocabulary counters for {variant} were {observed_eligible}, "
            f"expected {expected_eligible}"
        )
    expected_mask_bytes = ((vocab_rows + 63) // 64) * 8
    if (
        eligible_values["staging_mask_bytes"] != expected_mask_bytes
        or eligible_values["sealed_mask_bytes"] != expected_mask_bytes
    ):
        raise HarnessError("staging/sealed mask bytes do not match vocabulary geometry")

    decode_runs = int(metrics["decode_runs"])
    layers = int(metrics["attention_layers"])
    expected_dispatches = decode_runs * layers
    if decode_runs <= 0:
        raise HarnessError("eligibility A/B requires at least one decode graph")
    if (
        int(metrics["parallel_attention_graphs"]) != decode_runs
        or int(metrics["handoff_graphs"]) != decode_runs
        or int(metrics["parallel_attention_dispatches"]) != expected_dispatches
        or int(metrics["handoff_dispatches"]) != expected_dispatches
    ):
        raise HarnessError(
            "eligibility A/B requires complete parallel HandoffGraph coverage"
        )

    metrics.update(
        {
            **{f"greedy_{name}": value for name, value in greedy_values.items()},
            **{f"eligible_{name}": value for name, value in eligible_values.items()},
            "greedy_output_mode": reported_variant,
            "greedy_output_abi": greedy_abi,
            "eligible_vocab_mode": eligible.group(1).lower(),
            "eligible_domain": eligible.group(2).lower(),
            "eligible_provider_ms": provider_ms,
            "eligible_verification_ms": verification_ms,
            "eligible_published_tokens": published_tokens,
            "eligible_fallbacks": eligible_fallbacks,
            "eligible_rejects": eligible_rejects,
            "eligible_policy_sha256": eligible.group(24).lower(),
            "eligible_last_mask_sha256": eligible.group(25).lower(),
            "eligible_trace_sha256": eligible.group(26).lower(),
            "eligible_provider_abi": provider_abi,
            "eligible_executor_abi": executor_abi,
            "eligible_vocabulary_rows": vocab_rows,
            "eligible_mask_bytes": expected_mask_bytes,
            "eligible_total_dot_rows": computed_dot_rows,
            "stable_phase_line_sha256": sha256_bytes(
                phase.group(0).strip().encode("utf-8")
            ),
            "greedy_output_line_sha256": sha256_bytes(
                greedy.group(0).strip().encode("utf-8")
            ),
            "eligible_vocab_line_sha256": sha256_bytes(
                eligible.group(0).strip().encode("utf-8")
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
        "--eligible-domain",
        config.domain,
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
    frozen_inputs: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    _attention.assert_artifact_identities(frozen_inputs)
    if completion_path.exists():
        raise HarnessError(f"completion path unexpectedly exists: {completion_path}")
    command = build_command(config, variant, completion_path)
    process = _run_process(command, config.cwd, config.timeout_seconds)
    _attention.assert_artifact_identities(frozen_inputs)
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
            f"completion output had {len(completion_ids)} IDs, "
            f"expected {config.new_tokens}"
        )
    metrics = parse_telemetry(
        process["output"],
        variant=variant,
        domain=config.domain,
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
    if config.domain not in DOMAINS:
        raise HarnessError(f"eligible domain must be one of {DOMAINS}")
    if config.threshold <= 0 or config.threshold > MAX_I64:
        raise HarnessError("parallel attention threshold must be a positive int64")
    if config.samples_per_variant > 10_000:
        raise HarnessError("samples per variant must not exceed 10000")
    build_patterns(config.samples_per_variant, config.schedule_seed)
    if not 1 <= config.warmups_per_variant <= 100:
        raise HarnessError("warmups per variant must be in [1, 100]")
    if not 2 <= config.new_tokens <= 1_000_000:
        raise HarnessError("eligibility A/B new tokens must be in [2, 1000000]")
    if not 2 <= config.threads <= 65_536:
        raise HarnessError("strict eligibility A/B threads must be in [2, 65536]")
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
        *(REPO_ROOT / path for path in SOURCE_PATHS),
    }
    expected_input_count = 5 + len(SOURCE_PATHS)
    if len(input_paths) != expected_input_count:
        raise HarnessError("benchmark input and source-manifest paths must be distinct")
    if config.output is not None and config.output in input_paths:
        raise HarnessError("result output must not replace an input/source artifact")
    for name, digest in (
        ("binary", config.binary_sha256),
        ("model", config.model_sha256),
        ("ids", config.ids_sha256),
    ):
        if digest is not None and SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"{name} SHA-256 pin must be 64 lowercase hex digits")


def _structural_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    fields = (
        "greedy_materialized_projections",
        "greedy_logitless_projections",
        "greedy_producer_rows",
        "greedy_scratch_bytes",
        "greedy_materialized_logits_bytes",
        "eligible_provider_calls",
        "eligible_certificates",
        "eligible_posthead_projections",
        "eligible_prehead_projections",
        "eligible_eligible_rows",
        "eligible_materialized_dot_rows",
        "eligible_producer_rows",
        "eligible_skipped_rows",
        "eligible_overcomputed_rows",
        "eligible_producer_runs",
        "eligible_full_logits_rows_written",
        "eligible_full_logits_peak_bytes",
        "eligible_staging_mask_bytes",
        "eligible_sealed_mask_bytes",
        "eligible_executor_candidate_bytes",
        "eligible_executor_tile_scratch_bytes",
        "eligible_published_tokens",
        "eligible_vocabulary_rows",
    )
    return tuple(metrics[field] for field in fields)


def run_benchmark(config: Config) -> dict[str, Any]:
    validate_config(config)
    artifacts_before, sources_before = fingerprint_sets(config)
    frozen_inputs = _combined_fingerprints(artifacts_before, sources_before)
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
    common_identity: tuple[str, ...] | None = None
    layers: int | None = None
    phase_signature: tuple[int, ...] | None = None
    structural_signatures: dict[str, tuple[Any, ...]] = {}
    vocabulary_rows_from_posthead_logits: int | None = None
    inferred_vocabulary_rows: int | None = None
    normalized_command: tuple[str, ...] | None = None
    with tempfile.TemporaryDirectory(
        prefix="glacier-eligibility-generation-ab."
    ) as tmp:
        completion_path = Path(tmp) / "completion.ids"

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
            nonlocal common_identity
            nonlocal layers
            nonlocal phase_signature
            nonlocal vocabulary_rows_from_posthead_logits
            nonlocal inferred_vocabulary_rows
            nonlocal normalized_command
            item = run_variant(
                config, variant, completion_path, prompt_ids, frozen_inputs
            )
            item.update(
                {
                    "warmup": warmup,
                    "sequence_index": sequence_index,
                    "block_index": block_index,
                    "position_in_block": position_in_block,
                    "pattern": pattern,
                    "fresh_process": True,
                    "included_in_statistics": not warmup,
                }
            )
            metrics = item["metrics"]
            if reference_ids is None:
                reference_ids = list(item["completion_ids"])
            elif item["completion_ids"] != reference_ids:
                raise HarnessError(
                    "exact completion IDs changed at "
                    f"{'warmup' if warmup else 'sample'} {sequence_index} ({variant})"
                )
            observed_identity = tuple(
                str(metrics[field])
                for field in (
                    "eligible_domain",
                    "eligible_policy_sha256",
                    "eligible_last_mask_sha256",
                    "eligible_trace_sha256",
                    "greedy_output_abi",
                    "eligible_provider_abi",
                    "eligible_executor_abi",
                )
            )
            if common_identity is None:
                common_identity = observed_identity
            elif observed_identity != common_identity:
                raise HarnessError(
                    "domain policy/mask trace/ABI identity changed during A/B"
                )
            observed_vocab = int(metrics["eligible_vocabulary_rows"])
            if inferred_vocabulary_rows is None:
                inferred_vocabulary_rows = observed_vocab
            elif observed_vocab != inferred_vocabulary_rows:
                raise HarnessError("vocabulary geometry changed during A/B")
            if variant == "domain-posthead-required":
                baseline_vocab = int(metrics["greedy_materialized_logits_bytes"]) // 4
                if vocabulary_rows_from_posthead_logits is None:
                    vocabulary_rows_from_posthead_logits = baseline_vocab
                elif baseline_vocab != vocabulary_rows_from_posthead_logits:
                    raise HarnessError(
                        "post-head full-logit vocabulary changed during A/B"
                    )
            observed_layers = int(metrics["attention_layers"])
            if layers is None:
                layers = observed_layers
            elif observed_layers != layers:
                raise HarnessError("attention layer count changed during A/B")
            observed_phase = tuple(
                int(metrics[field])
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
                phase_signature = observed_phase
            elif observed_phase != phase_signature:
                raise HarnessError("stable phase coverage changed during A/B")
            signature = _structural_signature(metrics)
            previous = structural_signatures.setdefault(variant, signature)
            if signature != previous:
                raise HarnessError(f"structural telemetry changed for {variant}")
            normalized = list(item["argv"])
            normalized[normalized.index("--greedy-output") + 1] = VARIANTS[0]
            observed_command = tuple(normalized)
            if normalized_command is None:
                normalized_command = observed_command
            elif observed_command != normalized_command:
                raise HarnessError("an option other than the A/B output policy changed")
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
                variant = VARIANTS[1] if letter == "A" else VARIANTS[0]
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

    artifacts_after, sources_after = verify_fingerprint_sets(
        config, artifacts_before, sources_before
    )
    assert reference_ids is not None
    assert common_identity is not None
    assert layers is not None
    assert vocabulary_rows_from_posthead_logits is not None
    assert inferred_vocabulary_rows is not None
    if inferred_vocabulary_rows != vocabulary_rows_from_posthead_logits:
        raise HarnessError(
            "pre-head geometry did not match V derived from post-head full logits"
        )
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
        "eligible_provider_ms",
        "eligible_verification_ms",
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
    post_signature = structural_signatures[VARIANTS[0]]
    pre_signature = structural_signatures[VARIANTS[1]]
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
            "warmups_excluded_from_statistics": True,
            "prompt_tokens": len(prompt_ids),
            "new_tokens": config.new_tokens,
            "lm_heads": config.new_tokens,
            "eligible_rows_per_head": DOMAIN_ROWS,
            "eligible_domain": config.domain,
            "threads": config.threads,
            "parallel_attention_min_context": config.threshold,
            "decode_plan_mode": "checked",
            "attention_layers": layers,
            "expected_decode_runs": config.new_tokens - 1,
            "vocabulary_rows": vocabulary_rows_from_posthead_logits,
            "vocabulary_source": "posthead_materialized_logits_bytes_divided_by_f32_bytes",
            "expected_total_vocabulary_rows_per_arm": (
                config.new_tokens * vocabulary_rows_from_posthead_logits
            ),
            "producer_rows_per_prehead_bounds": [DOMAIN_ROWS, 256],
            "strict_prepared_glrt": True,
            "strict_batch_prefill": True,
            "temperature_zero": True,
            "eos_disabled_with_uint32_max": True,
            "zero_fallbacks_and_rejects_required": True,
            "zero_prehead_full_logits_required": True,
            "same_binary_required": True,
            "binary_sha256_by_variant": {
                variant: artifacts_before["binary"]["sha256"] for variant in VARIANTS
            },
            "same_domain_policy_last_mask_trace_and_abis_required": True,
            "greedy_output_abi": common_identity[4],
            "eligibility_provider_abi": common_identity[5],
            "eligibility_executor_abi": common_identity[6],
            "only_greedy_output_policy_varies": True,
            "constant_completion_output_path": True,
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": VARIANTS[1], "B": VARIANTS[0]},
            "bootstrap_unit": "complete_balanced_abba_or_baab_block",
            "exact_completion_ids_required_across_all_invocations": True,
            "structural_signature_sha256_by_variant": {
                VARIANTS[0]: sha256_bytes(repr(post_signature).encode("ascii")),
                VARIANTS[1]: sha256_bytes(repr(pre_signature).encode("ascii")),
            },
        },
        "artifacts_before": artifacts_before,
        "artifacts_after": artifacts_after,
        "source_manifest_before": sources_before,
        "source_manifest_after": sources_after,
        "domain_identity": {
            "domain": common_identity[0],
            "policy_sha256": common_identity[1],
            "last_mask_sha256": common_identity[2],
            "trace_sha256": common_identity[3],
        },
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
        "posthead_over_prehead": ratios,
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
            temporary.unlink(missing_ok=True)
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
    parser = argparse.ArgumentParser(
        description=(
            "Run a same-binary paired A/B between required post-head and "
            "pre-head execution of one caller-certified vocabulary domain."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument(
        "--ids",
        type=Path,
        default=REPO_ROOT / "bench" / "eval-qwen2.5.ids",
        help="prompt IDs (defaults to the pinned 176-token Qwen fixture)",
    )
    parser.add_argument("-o", "--output", required=True, help="result JSON path or '-'")
    parser.add_argument("--cwd", type=Path, default=REPO_ROOT)
    parser.add_argument("--eligible-domain", choices=DOMAINS, default=DEFAULT_DOMAIN)
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
        domain=args.eligible_domain,
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
    except KeyboardInterrupt:
        sys.stderr.write("error: benchmark interrupted\n")
        return 130
    except Exception as error:  # Keep the command-line boundary traceback-free.
        message = str(error) or type(error).__name__
        sys.stderr.write(f"error: {message}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
