#!/usr/bin/env python3
"""Validate the descriptive-only Prism 2+2 successor screen."""

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


SCHEMA = "glacier-prism-rows4-2x2-screen-v1"
VARIANTS = ("p2", "p4", "p2_lut")
CONFIGS = tuple((variant, group) for variant in VARIANTS for group in (8, 16))
FIELDS = [
    "run_id",
    "variant",
    "group_size",
    "sample",
    "pattern",
    "position",
    "method",
    "ns",
    "prepare_ns",
]


class ReportError(RuntimeError):
    """The retained screen does not match its declared contract."""


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


def parse_raw(
    path: Path, samples: int
) -> tuple[int, dict[tuple[str, int], dict[int, dict[str, Any]]]]:
    grouped: dict[tuple[str, int], dict[int, dict[str, Any]]] = {
        key: defaultdict(lambda: {"rows": [], "prepare_ns": None})
        for key in CONFIGS
    }
    run_ids: set[int] = set()
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != FIELDS:
            raise ReportError(f"unexpected columns: {reader.fieldnames!r}")
        for row_number, row in enumerate(reader, 2):
            if None in row:
                raise ReportError(f"extra raw column at row {row_number}")
            try:
                run_id = int(row["run_id"])
                key = (row["variant"], int(row["group_size"]))
                sample = int(row["sample"])
                position = int(row["position"])
                ns = float(row["ns"])
                prepare_ns = (
                    float(row["prepare_ns"]) if row["prepare_ns"] else None
                )
            except (TypeError, ValueError) as exc:
                raise ReportError(f"invalid value at raw row {row_number}") from exc
            pattern = row["pattern"]
            method = row["method"]
            if (
                run_id <= 0
                or key not in grouped
                or not 0 <= sample < samples
                or pattern not in ("AB", "BA")
                or not 0 <= position < 2
                or method not in ("A", "B")
                or not math.isfinite(ns)
                or ns <= 0
            ):
                raise ReportError(f"out-of-contract raw row {row_number}")
            if key[0] == "p2_lut":
                if prepare_ns is None or not math.isfinite(prepare_ns) or prepare_ns <= 0:
                    raise ReportError(f"missing LUT preparation at row {row_number}")
            elif prepare_ns is not None:
                raise ReportError(f"unexpected preparation timing at row {row_number}")
            run_ids.add(run_id)
            grouped[key][sample]["rows"].append(
                (position, pattern, method, ns)
            )
            existing_prepare = grouped[key][sample]["prepare_ns"]
            if prepare_ns is not None:
                if existing_prepare is not None and existing_prepare != prepare_ns:
                    raise ReportError(f"mixed preparation timing at row {row_number}")
                grouped[key][sample]["prepare_ns"] = prepare_ns
    if len(run_ids) != 1:
        raise ReportError(f"raw evidence has run IDs {sorted(run_ids)!r}")
    for key in CONFIGS:
        if set(grouped[key]) != set(range(samples)):
            raise ReportError(f"{key} does not contain exactly {samples} samples")
        for sample in range(samples):
            rows = sorted(grouped[key][sample]["rows"])
            expected_pattern = "AB" if sample % 2 == 0 else "BA"
            if [row[0] for row in rows] != [0, 1]:
                raise ReportError(f"{key} sample {sample} positions are incomplete")
            if any(row[1] != expected_pattern for row in rows):
                raise ReportError(f"{key} sample {sample} pattern is not alternating")
            if "".join(row[2] for row in rows) != expected_pattern:
                raise ReportError(f"{key} sample {sample} method order is invalid")
    return run_ids.pop(), grouped


def parse_verification(
    path: Path, run_id: int, samples: int, inner: int
) -> dict[str, Any]:
    lines = path.read_text(encoding="utf-8").splitlines()
    expected = [
        f"VERIFY_2X2_PASS,{phase},out=4864,in=896,g={group},bit_exact"
        for group in (8, 16)
        for phase in ("before", "after")
    ]
    if lines[:4] != expected:
        raise ReportError("verification log lacks the ordered bit-exact checks")
    terminal = re.fullmatch(
        rf"SCREEN_2X2_DONE,samples=(\d+),inner=(\d+),sink=(\d+),run_id={run_id}",
        lines[-1] if lines else "",
    )
    if terminal is None or (int(terminal.group(1)), int(terminal.group(2))) != (
        samples,
        inner,
    ):
        raise ReportError("verification terminal record does not match arguments")
    if len(lines) != 5:
        raise ReportError("verification log contains missing or extra records")
    return {
        "bit_exact": True,
        "checks": expected,
        "terminal_record": lines[-1],
    }


def describe(values: list[float]) -> dict[str, Any]:
    ordered = sorted(values)
    return {
        "count": len(values),
        "median_ns": statistics.median(ordered),
        "min_ns": ordered[0],
        "max_ns": ordered[-1],
    }


def summarize(
    variant: str,
    samples: dict[int, dict[str, Any]],
) -> dict[str, Any]:
    legacy: list[float] = []
    successor: list[float] = []
    prepare: list[float] = []
    for sample in sorted(samples):
        by_method = {row[2]: row[3] for row in samples[sample]["rows"]}
        legacy.append(by_method["A"])
        successor.append(by_method["B"])
        if samples[sample]["prepare_ns"] is not None:
            prepare.append(samples[sample]["prepare_ns"])
    legacy_median = statistics.median(legacy)
    successor_median = statistics.median(successor)
    speedup = legacy_median / successor_median
    threshold = 1.0 / 1.03 if variant == "p4" else 1.45
    result: dict[str, Any] = {
        "confidence_interval": None,
        "descriptive_only": True,
        "legacy": describe(legacy),
        "point_threshold_pass": speedup >= threshold,
        "required_speedup": threshold,
        "successor": describe(successor),
        "successor_over_legacy": successor_median / legacy_median,
        "speedup_legacy_over_successor": speedup,
    }
    if prepare:
        prepare_median = statistics.median(prepare)
        result["activation_lut_prepare"] = describe(prepare)
        result["one_projection_speedup_including_prepare"] = legacy_median / (
            successor_median + prepare_median
        )
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--verification-log", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--inner", type=int, default=3)
    parser.add_argument("--compile-command", required=True)
    parser.add_argument("--screen-command", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.samples <= 0 or args.samples > 64 or args.samples % 2 or args.inner <= 0:
        raise ReportError("samples must be positive/even/<=64 and inner positive")
    root = Path(__file__).resolve().parents[1]
    run_id, grouped = parse_raw(args.raw, args.samples)
    verification = parse_verification(
        args.verification_log, run_id, args.samples, args.inner
    )
    results = {
        f"{variant}_g{group}": summarize(variant, grouped[(variant, group)])
        for variant, group in CONFIGS
    }
    sources = [
        root / "src/backends/cpu/int4_neon.c",
        root / "src/backends/cpu/progressive_int4_neon.c",
        root / "bench/prism_rows4_kernel.c",
        root / "bench/prism_rows4_2x2_kernel.c",
        Path(__file__).resolve(),
    ]
    report = {
        "architecture": {
            "layout": "separate prefix2 and residual2 byte ranges; four little-lane 2-bit codes per byte over rows4/K16 physical order",
            "p2_value": "4 * prefix_code - 6",
            "p2_residual_pointer": False,
            "p4_value": "(prefix_code << 2 | residual_code) - 7",
        },
        "artifact_contract": {
            "baseline_bytes_per_weight": 0.5,
            "p2_bytes_per_weight": 0.25,
            "p4_bytes_per_weight": 0.5,
            "p4_weight_payload_overhead_fraction": 0.0,
        },
        "commands": {
            "compile": args.compile_command,
            "screen": args.screen_command,
        },
        "evidence": {
            "binary_sha256": sha256(args.binary),
            "raw_csv": str(args.raw),
            "raw_sha256": sha256(args.raw),
            "source_sha256": {
                str(path.relative_to(root)): sha256(path) for path in sources
            },
            "verification_log": str(args.verification_log),
            "verification_sha256": sha256(args.verification_log),
        },
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "geometry": {
            "in_features": 896,
            "inner_iterations": args.inner,
            "out_features": 4864,
            "paired_samples": args.samples,
            "schedule": "alternating AB/BA; one legacy and one successor measurement per sample",
        },
        "host": {
            "clang": command_output(["clang", "--version"]),
            "machine": platform.machine(),
            "macos": command_output(["sw_vers"]),
            "processor": command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "uname": platform.uname()._asdict(),
        },
        "result": "stop_direct_dense",
        "results": results,
        "run_id": run_id,
        "schema": SCHEMA,
        "statistical_scope": {
            "bootstrap_resamples": 0,
            "confidence_interval": None,
            "claim": "descriptive screen only; cannot satisfy a CI-based pass gate",
        },
        "successor_decision": {
            "direct_dense_kernel": "stop",
            "shadow_pack": "unimplemented architecture hypothesis; no performance claim",
        },
        "verification": verification,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")
    print(f"{args.output}: result=stop_direct_dense run_id={run_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
