#!/usr/bin/env python3
"""Validate and summarize the retained PairNibble producer microbenchmark.

The C harness owns measurement and bit-exact before/after checks. This script
fails closed on the shared raw/log run ID, complete ordered verification log
and balanced ABBA/BAAB CSV contract, then calculates the exact paired-block
estimator and deterministic NumPy PCG64 bootstrap used by the retained report.
It deliberately reports a conditional hot-cache micro-screen, not a
whole-layer or end-to-end confidence interval.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import platform
import re
import shlex
import statistics
import subprocess
from collections import defaultdict
from pathlib import Path
from typing import Any, Sequence

import numpy as np


SCHEMA = "glacier-pair-nibble-qwen-mlp-microbenchmark-v3"
CONFIGS = ((8, 1), (8, 4), (16, 1), (16, 4))


class ReportError(RuntimeError):
    """The raw evidence or report arguments violate the retained contract."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_output(argv: Sequence[str]) -> list[str]:
    try:
        result = subprocess.run(
            argv,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ReportError(f"metadata command failed: {shlex.join(argv)}") from exc
    return [line for line in result.stdout.strip().splitlines() if line]


def optional_command(argv: Sequence[str]) -> list[str] | None:
    try:
        return command_output(argv)
    except ReportError:
        return None


def encode_report(report: dict[str, Any]) -> str:
    try:
        return json.dumps(report, allow_nan=False, indent=2, sort_keys=True) + "\n"
    except ValueError as exc:
        raise ReportError("report contains a non-finite numeric value") from exc


def percentile(values: Sequence[float], probability: float) -> float:
    if not values:
        raise ReportError("cannot summarize an empty distribution")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * probability
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def distribution(values: Sequence[float]) -> dict[str, Any]:
    median = float(statistics.median(values))
    deviations = [abs(value - median) for value in values]
    return {
        "count": len(values),
        "mad_ns": float(statistics.median(deviations)),
        "max_ns": float(max(values)),
        "median_ns": median,
        "min_ns": float(min(values)),
        "p10_ns": percentile(values, 0.10),
        "p90_ns": percentile(values, 0.90),
        "p99_ns": percentile(values, 0.99),
    }


def ratio_for_blocks(
    block_a: np.ndarray[Any, np.dtype[np.float64]],
    block_b: np.ndarray[Any, np.dtype[np.float64]],
) -> float:
    return float(np.median(block_a) / np.median(block_b))


def bootstrap_ratios(
    block_a: np.ndarray[Any, np.dtype[np.float64]],
    block_b: np.ndarray[Any, np.dtype[np.float64]],
    *,
    resamples: int,
    seed: int,
) -> np.ndarray[Any, np.dtype[np.float64]]:
    rng = np.random.default_rng(seed)
    output = np.empty(resamples, dtype=np.float64)
    block_count = len(block_a)
    chunk_size = 1000
    for start in range(0, resamples, chunk_size):
        count = min(chunk_size, resamples - start)
        indices = rng.integers(0, block_count, size=(count, block_count))
        output[start : start + count] = np.median(block_a[indices], axis=1) / np.median(
            block_b[indices], axis=1
        )
    return output


def parse_rows(path: Path, blocks: int) -> dict[tuple[int, int], list[dict[str, Any]]]:
    expected_fields = [
        "run_id",
        "group_size",
        "batch",
        "block",
        "pattern",
        "position",
        "method",
        "ns_per_producer",
    ]
    grouped: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != expected_fields:
            raise ReportError(f"unexpected CSV columns: {reader.fieldnames!r}")
        for row_number, row in enumerate(reader, 2):
            try:
                parsed = {
                    "run_id": int(row["run_id"]),
                    "group_size": int(row["group_size"]),
                    "batch": int(row["batch"]),
                    "block": int(row["block"]),
                    "pattern": row["pattern"],
                    "position": int(row["position"]),
                    "method": row["method"],
                    "ns": float(row["ns_per_producer"]),
                }
            except (TypeError, ValueError) as exc:
                raise ReportError(f"invalid CSV value at row {row_number}") from exc
            key = (parsed["group_size"], parsed["batch"])
            if key not in CONFIGS or not 0 <= parsed["block"] < blocks:
                raise ReportError(f"unexpected configuration/block at row {row_number}")
            if parsed["run_id"] <= 0:
                raise ReportError(f"invalid run ID at row {row_number}")
            if parsed["pattern"] not in ("ABBA", "BAAB") or parsed["method"] not in (
                "A",
                "B",
            ):
                raise ReportError(f"unexpected schedule value at row {row_number}")
            if (
                not 0 <= parsed["position"] < 4
                or not math.isfinite(parsed["ns"])
                or parsed["ns"] <= 0
            ):
                raise ReportError(f"invalid position/timing at row {row_number}")
            grouped[key].append(parsed)
    return grouped


def validate_schedule(rows: list[dict[str, Any]], blocks: int) -> None:
    if len(rows) != blocks * 4:
        raise ReportError(f"expected {blocks * 4} rows, found {len(rows)}")
    by_block: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_block[row["block"]].append(row)
    if set(by_block) != set(range(blocks)):
        raise ReportError("block indices are incomplete")
    pattern_counts = {"ABBA": 0, "BAAB": 0}
    for block, samples in by_block.items():
        ordered = sorted(samples, key=lambda sample: sample["position"])
        if [sample["position"] for sample in ordered] != [0, 1, 2, 3]:
            raise ReportError(f"block {block} positions are not exactly 0..3")
        patterns = {sample["pattern"] for sample in ordered}
        if len(patterns) != 1:
            raise ReportError(f"block {block} mixes schedule labels")
        pattern = patterns.pop()
        methods = "".join(sample["method"] for sample in ordered)
        if methods != pattern:
            raise ReportError(f"block {block} methods do not match {pattern}")
        pattern_counts[pattern] += 1
    if pattern_counts != {"ABBA": blocks // 2, "BAAB": blocks // 2}:
        raise ReportError(f"unbalanced schedule: {pattern_counts!r}")


def validate_verification_log(
    path: Path, *, blocks: int, inner_m1: int, inner_m4: int, run_id: int
) -> dict[str, Any]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ReportError("verification log is unreadable UTF-8") from exc
    expected = [
        f"VERIFY_PASS,{when},g{group_size},b{batch},bit_exact,run_id={run_id}"
        for group_size, batch in CONFIGS
        for when in ("before", "after")
    ]
    if lines[: len(expected)] != expected:
        raise ReportError("verification log lacks the exact ordered PASS set")
    if len(lines) != len(expected) + 1:
        raise ReportError("verification log has missing or extra records")
    done = re.fullmatch(
        r"BENCH_DONE,blocks=(\d+),inner_m1=(\d+),inner_m4=(\d+),"
        r"qos=user_interactive,sink=(\d+),run_id=(\d+)",
        lines[-1],
    )
    if done is None:
        raise ReportError("verification log lacks a valid BENCH_DONE record")
    observed = tuple(int(value) for value in done.groups()[:3])
    required = (blocks, inner_m1, inner_m4)
    if observed != required:
        raise ReportError(
            f"verification run parameters {observed!r} do not match {required!r}"
        )
    if int(done.group(5)) != run_id:
        raise ReportError("verification run ID does not match raw CSV")
    return {
        "bench_done": lines[-1],
        "ordered_bit_exact_passes": len(expected),
        "run_id": run_id,
    }


def summarize_config(
    rows: list[dict[str, Any]],
    group_size: int,
    batch: int,
    *,
    blocks: int,
    resamples: int,
    seed: int,
    direct_threshold: float,
    coefficients: int,
) -> dict[str, Any]:
    validate_schedule(rows, blocks)
    raw_a = [row["ns"] for row in rows if row["method"] == "A"]
    raw_b = [row["ns"] for row in rows if row["method"] == "B"]
    per_block: dict[int, dict[str, list[float]]] = defaultdict(
        lambda: {"A": [], "B": []}
    )
    patterns: dict[int, str] = {}
    for row in rows:
        per_block[row["block"]][row["method"]].append(row["ns"])
        patterns[row["block"]] = row["pattern"]
    block_a = np.asarray(
        [statistics.mean(per_block[index]["A"]) for index in range(blocks)],
        dtype=np.float64,
    )
    block_b = np.asarray(
        [statistics.mean(per_block[index]["B"]) for index in range(blocks)],
        dtype=np.float64,
    )
    point = ratio_for_blocks(block_a, block_b)
    bootstrap = bootstrap_ratios(block_a, block_b, resamples=resamples, seed=seed)
    low, high = np.quantile(bootstrap, (0.025, 0.975))

    def subset_ratio(indices: Sequence[int]) -> float:
        chosen = np.asarray(indices, dtype=np.int64)
        return ratio_for_blocks(block_a[chosen], block_b[chosen])

    pattern_results: dict[str, Any] = {}
    for pattern in ("ABBA", "BAAB"):
        indices = [index for index in range(blocks) if patterns[index] == pattern]
        pattern_results[pattern] = {
            "blocks": len(indices),
            "speed_ratio": subset_ratio(indices),
        }
    return {
        "batch": batch,
        "canonical_calls_per_producer": 2,
        "canonical_two_calls": distribution(raw_a),
        "direct_gate": {
            "entire_95pct_ci_clears": bool(low >= direct_threshold),
            "point_estimate_clears": bool(point >= direct_threshold),
            "scope": (
                "M1 direct-producer admission"
                if batch == 1
                else "M4 explicit artifact-admission only"
            ),
            "threshold": direct_threshold,
        },
        "group_size": group_size,
        "logical_coefficients_per_branch": coefficients,
        "pair_calls_per_producer": 1,
        "pair_dual_call": distribution(raw_b),
        "paired_block_estimator": {
            "bootstrap_95pct_ci": [float(low), float(high)],
            "bootstrap_probability_ratio_ge_direct_threshold": float(
                np.mean(bootstrap >= direct_threshold)
            ),
            "bootstrap_resamples": resamples,
            "bootstrap_seed": seed,
            "definition": (
                "median(block mean of 2 canonical timings) / "
                "median(block mean of 2 pair timings)"
            ),
            "paired_block_win_rate": float(np.mean(block_a > block_b)),
            "percent_faster": (point - 1.0) * 100.0,
            "speed_ratio": point,
        },
        "paired_blocks": blocks,
        "raw_measurements_per_method": len(raw_a),
        "raw_median_speed_ratio": float(
            statistics.median(raw_a) / statistics.median(raw_b)
        ),
        "stability": {
            "abba_baab_pattern_results": pattern_results,
            "first_half_speed_ratio": subset_ratio(range(0, blocks // 2)),
            "second_half_speed_ratio": subset_ratio(range(blocks // 2, blocks)),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--verification-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--benchmark-binary", type=Path, required=True)
    parser.add_argument("--benchmark-source", type=Path, required=True)
    parser.add_argument("--kernel-source", type=Path, required=True)
    parser.add_argument("--compiler-command", required=True)
    parser.add_argument("--run-command", required=True)
    parser.add_argument("--blocks", type=int, default=256)
    parser.add_argument("--inner-m1", type=int, default=16)
    parser.add_argument("--inner-m4", type=int, default=8)
    parser.add_argument("--resamples", type=int, default=100_000)
    parser.add_argument("--base-seed", type=int, default=3_223_171_079)
    parser.add_argument("--m1-threshold", type=float, default=1.15)
    parser.add_argument("--m4-admission-threshold", type=float, default=1.05)
    parser.add_argument("--whole-mlp-threshold", type=float, default=1.15)
    parser.add_argument("--out-features", type=int, default=4864)
    parser.add_argument("--in-features", type=int, default=896)
    parser.add_argument("--generated-utc")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.blocks <= 0 or args.blocks % 2 or args.resamples <= 0:
        raise ReportError("blocks must be positive/even and resamples positive")
    thresholds = (
        args.m1_threshold,
        args.m4_admission_threshold,
        args.whole_mlp_threshold,
    )
    if any(not math.isfinite(value) or value <= 0 for value in thresholds):
        raise ReportError("all gate thresholds must be finite and positive")
    for path in (
        args.raw,
        args.verification_log,
        args.benchmark_binary,
        args.benchmark_source,
        args.kernel_source,
    ):
        if not path.is_file():
            raise ReportError(f"missing artifact: {path}")
    grouped = parse_rows(args.raw, args.blocks)
    if set(grouped) != set(CONFIGS):
        raise ReportError(f"missing configuration(s): {set(CONFIGS) - set(grouped)}")
    run_ids = {row["run_id"] for rows in grouped.values() for row in rows}
    if len(run_ids) != 1:
        raise ReportError("raw CSV mixes benchmark run IDs")
    run_id = run_ids.pop()
    coefficients = args.out_features * args.in_features
    verification = validate_verification_log(
        args.verification_log,
        blocks=args.blocks,
        inner_m1=args.inner_m1,
        inner_m4=args.inner_m4,
        run_id=run_id,
    )
    script_path = Path(__file__).resolve()
    try:
        script_display = script_path.relative_to(Path.cwd().resolve())
    except ValueError:
        script_display = script_path
    results = [
        summarize_config(
            grouped[config],
            *config,
            blocks=args.blocks,
            resamples=args.resamples,
            seed=args.base_seed + index,
            direct_threshold=(
                args.m1_threshold if config[1] == 1 else args.m4_admission_threshold
            ),
            coefficients=coefficients,
        )
        for index, config in enumerate(CONFIGS)
    ]
    compiler_tokens = shlex.split(args.compiler_command)
    generated_utc = args.generated_utc or dt.datetime.now(dt.timezone.utc).isoformat()
    report = {
        "analysis": {
            "numpy_version": np.__version__,
            "script": str(script_display),
            "script_sha256": sha256(script_path),
        },
        "artifacts": {
            "benchmark_binary": {
                "path": str(args.benchmark_binary),
                "sha256": sha256(args.benchmark_binary),
            },
            "benchmark_source": {
                "path": str(args.benchmark_source),
                "sha256": sha256(args.benchmark_source),
            },
            "kernel_source": {
                "path": str(args.kernel_source),
                "sha256": sha256(args.kernel_source),
            },
            "raw_csv": {
                "data_rows": sum(len(rows) for rows in grouped.values()),
                "path": str(args.raw),
                "sha256": sha256(args.raw),
            },
            "verification_log": {
                "lines": verification["ordered_bit_exact_passes"] + 1,
                "path": str(args.verification_log),
                "sha256": sha256(args.verification_log),
            },
        },
        "compiler": {
            "command": args.compiler_command,
            "fast_math": any(
                token in ("-ffast-math", "-Ofast") for token in compiler_tokens
            ),
            "flags": [token for token in compiler_tokens if token.startswith("-")],
            "version": command_output([compiler_tokens[0], "cc", "--version"]),
            "zig_version": command_output([compiler_tokens[0], "version"])[0],
        },
        "evidence_scope": {
            "claim": "conditional hot-cache producer micro-screen",
            "excludes": [
                "cold sequential layer traversal",
                "address-color and data-seed population uncertainty",
                "whole MLP and whole engine",
                "non-DOTPROD execution",
            ],
        },
        "gate_definition": {
            "direct_strict_clear": (
                "paired point estimate and entire paired-bootstrap 95% CI are "
                ">= the batch-specific direct threshold"
            ),
            "m1_direct_threshold": args.m1_threshold,
            "m4_explicit_artifact_admission_threshold": (
                args.m4_admission_threshold
            ),
            "production_default_status": "not evaluated by this microbenchmark",
            "whole_mlp_production_threshold": args.whole_mlp_threshold,
        },
        "generated_utc": generated_utc,
        "machine": {
            "architecture": platform.machine(),
            "cpu": (
                optional_command(["sysctl", "-n", "machdep.cpu.brand_string"])
                or ["unknown"]
            )[0],
            "logical_cpus": int(
                (optional_command(["sysctl", "-n", "hw.logicalcpu"]) or ["0"])[0]
            ),
            "memory_bytes": int(
                (optional_command(["sysctl", "-n", "hw.memsize"]) or ["0"])[0]
            ),
            "model": (optional_command(["sysctl", "-n", "hw.model"]) or ["unknown"])[0],
            "os": optional_command(["sw_vers"]),
            "qos": "QOS_CLASS_USER_INTERACTIVE; harness exits nonzero if rejected",
        },
        "results": results,
        "run": {
            "abba_blocks_per_configuration": args.blocks // 2,
            "baab_blocks_per_configuration": args.blocks // 2,
            "balanced_blocks_per_configuration": args.blocks,
            "batches": [1, 4],
            "command": args.run_command,
            "geometry": {
                "in_features": args.in_features,
                "out_features": args.out_features,
            },
            "group_sizes": [8, 16],
            "inner_iterations": {
                "batch_1": args.inner_m1,
                "batch_4": args.inner_m4,
            },
            "method_A": "two canonical separate branch calls",
            "method_B": "one dual-output PairNibble call",
            "pattern_seeded_shuffle": True,
            "run_id": run_id,
            "timer": "mach_continuous_time",
            "verification": {
                "bench_done": verification["bench_done"],
                "contract": (
                    "raw CSV and retained log share one run ID; the log has "
                    "ordered bit-exact before/after PASS for g8/g16 M1/M4 "
                    "and matching BENCH_DONE"
                ),
                "ordered_bit_exact_passes": verification[
                    "ordered_bit_exact_passes"
                ],
            },
            "warmup_pairs_per_configuration": 10,
        },
        "schema": SCHEMA,
    }
    args.output.write_text(encode_report(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
