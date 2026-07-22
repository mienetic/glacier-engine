#!/usr/bin/env python3
"""Validate and report the isolated Prism rows4/K16 production-kernel gate."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import platform
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Sequence

import numpy as np


SCHEMA = "glacier-prism-rows4-m1-gate-v1"
CONFIGS = (("p2", 8), ("p2", 16), ("p4", 8), ("p4", 16))
FIELDS = [
    "run_id",
    "gate",
    "group_size",
    "block",
    "pattern",
    "position",
    "method",
    "ns",
]


class ReportError(RuntimeError):
    """The evidence violates the fail-closed benchmark contract."""


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
        raise ReportError(f"metadata command failed: {argv!r}") from exc
    return [line for line in result.stdout.strip().splitlines() if line]


def distribution(values: np.ndarray[Any, np.dtype[np.float64]]) -> dict[str, Any]:
    return {
        "count": int(values.size),
        "median_ns": float(np.median(values)),
        "min_ns": float(np.min(values)),
        "max_ns": float(np.max(values)),
        "p10_ns": float(np.quantile(values, 0.10)),
        "p90_ns": float(np.quantile(values, 0.90)),
        "p99_ns": float(np.quantile(values, 0.99)),
    }


def parse_raw(
    path: Path, blocks: int
) -> tuple[int, dict[tuple[str, int], dict[int, dict[str, list[float]]]]]:
    grouped: dict[tuple[str, int], dict[int, dict[str, list[float]]]] = {
        key: defaultdict(lambda: {"A": [], "B": []}) for key in CONFIGS
    }
    run_ids: set[int] = set()
    schedules: dict[tuple[str, int], dict[int, tuple[str, list[str]]]] = {
        key: {} for key in CONFIGS
    }
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != FIELDS:
            raise ReportError(f"unexpected raw columns: {reader.fieldnames!r}")
        for row_number, row in enumerate(reader, 2):
            if None in row:
                raise ReportError(f"extra raw column at row {row_number}")
            try:
                run_id = int(row["run_id"])
                key = (row["gate"], int(row["group_size"]))
                block = int(row["block"])
                position = int(row["position"])
                ns = float(row["ns"])
            except (TypeError, ValueError) as exc:
                raise ReportError(f"invalid raw value at row {row_number}") from exc
            pattern = row["pattern"]
            method = row["method"]
            if (
                run_id <= 0
                or key not in grouped
                or not 0 <= block < blocks
                or pattern not in ("ABBA", "BAAB")
                or method not in ("A", "B")
                or not 0 <= position < 4
                or not math.isfinite(ns)
                or ns <= 0
            ):
                raise ReportError(f"out-of-contract raw row {row_number}")
            run_ids.add(run_id)
            grouped[key][block][method].append(ns)
            schedule = schedules[key].setdefault(block, (pattern, [""] * 4))
            if schedule[0] != pattern or schedule[1][position]:
                raise ReportError(f"duplicate/mixed schedule at row {row_number}")
            schedule[1][position] = method
    if len(run_ids) != 1:
        raise ReportError(f"raw evidence has run IDs {sorted(run_ids)!r}")
    for key in CONFIGS:
        if set(grouped[key]) != set(range(blocks)):
            raise ReportError(f"{key} does not contain exactly {blocks} blocks")
        pattern_counts = {"ABBA": 0, "BAAB": 0}
        for block in range(blocks):
            pattern, observed = schedules[key].get(block, ("", []))
            if "".join(observed) != pattern:
                raise ReportError(f"{key} block {block} schedule mismatch")
            if len(grouped[key][block]["A"]) != 2 or len(
                grouped[key][block]["B"]
            ) != 2:
                raise ReportError(f"{key} block {block} is not paired 2A/2B")
            pattern_counts[pattern] += 1
        if pattern_counts != {"ABBA": blocks // 2, "BAAB": blocks // 2}:
            raise ReportError(f"{key} schedule is unbalanced: {pattern_counts!r}")
    return run_ids.pop(), grouped


def parse_verification(
    path: Path, run_id: int, blocks: int, inner: int
) -> dict[str, Any]:
    lines = path.read_text(encoding="utf-8").splitlines()
    matrix_pattern = re.compile(
        r"VERIFY_PASS,matrix,out=(\d+),in=(\d+),g=(8|16),"
        rf"p2\+p4,bit_exact,run_id={run_id}"
    )
    full_pattern = re.compile(
        r"VERIFY_PASS,(before|after),out=4864,in=896,g=(8|16),"
        rf"p2\+p4,bit_exact,run_id={run_id}"
    )
    matrix: list[dict[str, int]] = []
    full: list[dict[str, Any]] = []
    for line in lines:
        if match := matrix_pattern.fullmatch(line):
            matrix.append(
                {
                    "out_features": int(match.group(1)),
                    "in_features": int(match.group(2)),
                    "group_size": int(match.group(3)),
                }
            )
        elif match := full_pattern.fullmatch(line):
            full.append({"phase": match.group(1), "group_size": int(match.group(2))})
    expected_matrix = [
        {"out_features": out_f, "in_features": in_f, "group_size": group_size}
        for out_f, in_f in ((4, 16), (12, 64), (20, 80), (36, 896))
        for group_size in (8, 16)
    ]
    expected_full = [
        {"phase": phase, "group_size": group_size}
        for group_size in (8, 16)
        for phase in ("before", "after")
    ]
    if matrix != expected_matrix or full != expected_full:
        raise ReportError("verification log lacks the ordered correctness matrix")
    done = re.fullmatch(
        r"BENCH_DONE,blocks=(\d+),inner=(\d+),weights=(\d+),"
        r"p2_bytes_per_weight=0\.25,p4_bytes_per_weight=0\.5,"
        rf"sink=(\d+),run_id={run_id}",
        lines[-1] if lines else "",
    )
    if done is None:
        raise ReportError("verification log lacks the matching BENCH_DONE record")
    if (int(done.group(1)), int(done.group(2)), int(done.group(3))) != (
        blocks,
        inner,
        4864 * 896,
    ):
        raise ReportError("BENCH_DONE parameters do not match report arguments")
    if len(lines) != len(expected_matrix) + len(expected_full) + 1:
        raise ReportError("verification log contains missing or extra records")
    return {
        "bit_exact": True,
        "full_fixture_checks": full,
        "matrix": matrix,
        "ordered_pass_count": len(matrix) + len(full),
        "terminal_record": lines[-1],
    }


def summarize(
    blocks_data: dict[int, dict[str, list[float]]],
    *,
    resamples: int,
    seed: int,
    threshold: float,
) -> dict[str, Any]:
    legacy = np.asarray(
        [statistics.median(blocks_data[i]["A"]) for i in sorted(blocks_data)],
        dtype=np.float64,
    )
    prism = np.asarray(
        [statistics.median(blocks_data[i]["B"]) for i in sorted(blocks_data)],
        dtype=np.float64,
    )
    speedup = float(np.median(legacy) / np.median(prism))
    rng = np.random.default_rng(seed)
    bootstrap = np.empty(resamples, dtype=np.float64)
    chunk = 1000
    for start in range(0, resamples, chunk):
        count = min(chunk, resamples - start)
        indices = rng.integers(0, len(legacy), size=(count, len(legacy)))
        bootstrap[start : start + count] = np.median(
            legacy[indices], axis=1
        ) / np.median(prism[indices], axis=1)
    lower, upper = np.quantile(bootstrap, (0.025, 0.975))
    return {
        "bootstrap": {
            "confidence": 0.95,
            "lower_speedup": float(lower),
            "resamples": resamples,
            "seed": seed,
            "upper_speedup": float(upper),
        },
        "gate_pass": bool(lower >= threshold),
        "legacy": distribution(legacy),
        "prism": distribution(prism),
        "prism_over_legacy": float(1.0 / speedup),
        "required_lower_speedup": threshold,
        "speedup_legacy_over_prism": speedup,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--verification-log", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--blocks", type=int, default=256)
    parser.add_argument("--inner", type=int, default=3)
    parser.add_argument("--resamples", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=0x47505253)
    parser.add_argument("--compile-command", required=True)
    parser.add_argument("--benchmark-command", required=True)
    parser.add_argument("--require-pass", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.blocks <= 0 or args.blocks % 2 or args.inner <= 0 or args.resamples <= 0:
        raise ReportError("blocks must be positive/even; inner/resamples must be positive")
    root = Path(__file__).resolve().parents[1]
    run_id, grouped = parse_raw(args.raw, args.blocks)
    verification = parse_verification(
        args.verification_log, run_id, args.blocks, args.inner
    )
    results: dict[str, Any] = {}
    for index, key in enumerate(CONFIGS):
        tier, group_size = key
        threshold = 1.45 if tier == "p2" else 1.0 / 1.03
        results[f"{tier}_g{group_size}"] = summarize(
            grouped[key],
            resamples=args.resamples,
            seed=args.seed + index,
            threshold=threshold,
        )
    stage_pass = all(result["gate_pass"] for result in results.values())
    source_paths = [
        root / "src/backends/cpu/int4_neon.c",
        root / "src/backends/cpu/progressive_int4_neon.c",
        root / "bench/prism_rows4_kernel.c",
        Path(__file__).resolve(),
    ]
    report = {
        "artifact_contract": {
            "baseline_bytes_per_weight": 0.5,
            "p2_bytes_per_weight": 0.25,
            "p4_bytes_per_weight": 0.5,
            "p4_weight_payload_overhead_fraction": 0.0,
        },
        "commands": {
            "benchmark": args.benchmark_command,
            "compile": args.compile_command,
        },
        "evidence": {
            "binary_sha256": sha256(args.binary),
            "raw_csv": str(args.raw),
            "raw_sha256": sha256(args.raw),
            "source_sha256": {
                str(path.relative_to(root)): sha256(path) for path in source_paths
            },
            "verification_log": str(args.verification_log),
            "verification_sha256": sha256(args.verification_log),
        },
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "geometry": {
            "in_features": 896,
            "inner_iterations": args.inner,
            "out_features": 4864,
            "paired_blocks": args.blocks,
        },
        "host": {
            "clang": command_output(["clang", "--version"]),
            "machine": platform.machine(),
            "macos": command_output(["sw_vers"]),
            "processor": command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "uname": platform.uname()._asdict(),
        },
        "result": "pass" if stage_pass else "stop",
        "results": results,
        "run_id": run_id,
        "schema": SCHEMA,
        "stage_b_kernel_gate_pass": stage_pass,
        "verification": verification,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")
    print(
        f"{args.output}: result={report['result']} run_id={run_id} "
        f"configs={len(results)}"
    )
    return int(args.require_pass and not stage_pass)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
