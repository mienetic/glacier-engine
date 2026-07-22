#!/usr/bin/env python3
"""Validate and summarize the PairNibble persistent-executor tile campaign."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path


PARTICIPANTS = (1, 2, 4, 8)
GROUP_SIZES = (8, 16)
TILE_ROWS = (16, 32, 64, 128, 256)
RUNS = 3
ROUNDS = 2
SAMPLES = 101
WARMUPS = 20
OUT_FEATURES = 4864
IN_FEATURES = 896


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(sorted_values: list[float], probability: float) -> float:
    if not sorted_values:
        raise ValueError("empty percentile")
    position = probability * (len(sorted_values) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return sorted_values[lower]
    weight = position - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def bootstrap_run_median_ratio(
    baseline: list[float],
    candidate: list[float],
    resamples: int,
    seed: int,
) -> dict[str, float | int | str]:
    if len(baseline) != RUNS or len(candidate) != RUNS:
        raise ValueError("bootstrap requires exactly three run medians")
    generator = random.Random(seed)
    ratios: list[float] = []
    for _ in range(resamples):
        indices = [generator.randrange(RUNS) for _ in range(RUNS)]
        base = median([baseline[index] for index in indices])
        other = median([candidate[index] for index in indices])
        ratios.append(other / base)
    ratios.sort()
    return {
        "bootstrap_unit": "paired_run_median",
        "resamples": resamples,
        "seed": seed,
        "candidate_over_tile64_median": median(ratios),
        "ci95_low": percentile(ratios, 0.025),
        "ci95_high": percentile(ratios, 0.975),
    }


def parse_raw(
    path: Path,
) -> tuple[int, dict[tuple[int, int, int, int, int], list[float]]]:
    grouped: dict[tuple[int, int, int, int, int], list[float]] = defaultdict(list)
    run_ids: set[int] = set()
    coordinates: set[tuple[int, int, int, int, int, int]] = set()
    row_count = 0
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        expected_fields = [
            "run_id",
            "run_index",
            "participants",
            "group_size",
            "tile_rows",
            "claims",
            "round",
            "sample",
            "position",
            "elapsed_ns",
        ]
        if reader.fieldnames != expected_fields:
            raise ValueError(f"unexpected CSV header: {reader.fieldnames}")
        for row in reader:
            row_count += 1
            run_id = int(row["run_id"])
            run_index = int(row["run_index"])
            participants = int(row["participants"])
            group_size = int(row["group_size"])
            tile_rows = int(row["tile_rows"])
            claims = int(row["claims"])
            round_index = int(row["round"])
            sample = int(row["sample"])
            position = int(row["position"])
            elapsed_ns = float(row["elapsed_ns"])
            if run_index not in range(RUNS):
                raise ValueError(f"invalid run index: {run_index}")
            if participants not in PARTICIPANTS:
                raise ValueError(f"invalid participants: {participants}")
            if group_size not in GROUP_SIZES:
                raise ValueError(f"invalid group size: {group_size}")
            if tile_rows not in TILE_ROWS or tile_rows % 4 != 0:
                raise ValueError(f"invalid tile rows: {tile_rows}")
            if claims != (OUT_FEATURES + tile_rows - 1) // tile_rows:
                raise ValueError(f"invalid claim count: {claims}")
            if round_index not in range(ROUNDS) or sample not in range(SAMPLES):
                raise ValueError("invalid balanced-round coordinate")
            expected_position = TILE_ROWS.index(tile_rows)
            if round_index == 1:
                expected_position = len(TILE_ROWS) - 1 - expected_position
            if position != expected_position:
                raise ValueError("unbalanced tile order")
            if not math.isfinite(elapsed_ns) or elapsed_ns <= 0:
                raise ValueError(f"invalid elapsed_ns: {elapsed_ns}")
            coordinate = (
                run_index,
                participants,
                group_size,
                tile_rows,
                round_index,
                sample,
            )
            if coordinate in coordinates:
                raise ValueError(f"duplicate campaign coordinate: {coordinate}")
            coordinates.add(coordinate)
            run_ids.add(run_id)
            grouped[
                (participants, group_size, tile_rows, run_index, round_index)
            ].append(elapsed_ns)
    expected_rows = (
        len(PARTICIPANTS) * len(GROUP_SIZES) * len(TILE_ROWS) * RUNS * ROUNDS * SAMPLES
    )
    if row_count != expected_rows:
        raise ValueError(f"expected {expected_rows} rows, found {row_count}")
    if len(run_ids) != 1:
        raise ValueError(f"expected one campaign run_id, found {sorted(run_ids)}")
    expected_coordinates = {
        (run_index, participants, group_size, tile_rows, round_index, sample)
        for run_index in range(RUNS)
        for participants in PARTICIPANTS
        for group_size in GROUP_SIZES
        for tile_rows in TILE_ROWS
        for round_index in range(ROUNDS)
        for sample in range(SAMPLES)
    }
    if coordinates != expected_coordinates:
        missing = sorted(expected_coordinates - coordinates)[:3]
        extra = sorted(coordinates - expected_coordinates)[:3]
        raise ValueError(
            f"campaign coordinate mismatch; missing={missing}, extra={extra}"
        )
    for key, values in grouped.items():
        if len(values) != SAMPLES:
            raise ValueError(
                f"expected {SAMPLES} values for {key}, found {len(values)}"
            )
    return next(iter(run_ids)), grouped


def validate_verification(path: Path, run_id: int) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    expected: list[str | None] = [
        (
            f"CAMPAIGN,run_id={run_id},out={OUT_FEATURES},in={IN_FEATURES},"
            f"participants={'_'.join(map(str, PARTICIPANTS))},runs={RUNS},"
            f"rounds={ROUNDS},samples={SAMPLES},warmups={WARMUPS}"
        ),
        "MAIN_QOS,status=0",
    ]
    for participants in PARTICIPANTS:
        for group_size in GROUP_SIZES:
            for run_index in range(RUNS):
                expected.append(
                    f"VERIFY_PASS,run_id={run_id},run={run_index},"
                    f"t{participants},g{group_size},"
                    f"tile{'_'.join(map(str, TILE_ROWS))},bit_exact"
                )
            expected.append(
                f"WORKER_QOS,g{group_size},participants={participants},failures=0"
            )
    # The sink value is deliberately data-dependent, but its line and unsigned
    # decimal field remain ordered and exact.
    expected.extend([None, "CAMPAIGN_PASS"])
    if len(lines) != len(expected):
        raise ValueError(
            f"verification line count mismatch: expected {len(expected)}, "
            f"found {len(lines)}"
        )
    for index, (actual, wanted) in enumerate(zip(lines, expected)):
        if wanted is None:
            prefix = "SINK,value="
            if not actual.startswith(prefix) or not actual[len(prefix) :].isdigit():
                raise ValueError(f"invalid sink line at {index}: {actual!r}")
        elif actual != wanted:
            raise ValueError(
                f"verification line {index} mismatch: expected {wanted!r}, "
                f"found {actual!r}"
            )


def recommend_tiles(
    run_medians: dict[tuple[int, int, int], list[float]],
) -> tuple[dict[str, int], dict[str, int]]:
    """Choose from paired same-run ratios, never independent run medians."""
    recommendations_by_group: dict[str, int] = {}
    recommendations_by_participants: dict[str, int] = {}
    for participants in PARTICIPANTS:
        paired_scores: dict[int, list[float]] = defaultdict(list)
        for group_size in GROUP_SIZES:
            baseline = run_medians[(participants, group_size, 64)]
            paired_ratio_by_tile: dict[int, float] = {}
            for tile_rows in TILE_ROWS:
                candidate = run_medians[(participants, group_size, tile_rows)]
                if len(candidate) != RUNS or len(baseline) != RUNS:
                    raise ValueError("recommendation requires complete run medians")
                paired_ratio_by_tile[tile_rows] = median(
                    [candidate[index] / baseline[index] for index in range(RUNS)]
                )
            best_tile = min(
                TILE_ROWS,
                key=lambda tile: paired_ratio_by_tile[tile],
            )
            recommendations_by_group[f"t{participants}_g{group_size}"] = best_tile
            for tile_rows in TILE_ROWS:
                paired_scores[tile_rows].append(paired_ratio_by_tile[tile_rows])
        recommendations_by_participants[str(participants)] = min(
            TILE_ROWS,
            key=lambda tile: math.prod(paired_scores[tile])
            ** (1.0 / len(paired_scores[tile])),
        )
    return recommendations_by_group, recommendations_by_participants


def project_measured_tiles(
    recommendations_by_group: dict[str, int],
) -> tuple[dict[str, int], dict[str, int]]:
    """Project 1..max measured participants by nearest measured topology.

    Equal-distance ties deliberately select the lower participant count so the
    runtime policy is deterministic and does not imply unmeasured interpolation.
    """
    projected: dict[str, int] = {}
    source_by_participant: dict[str, int] = {}
    for participants in range(1, max(PARTICIPANTS) + 1):
        measured = min(
            PARTICIPANTS, key=lambda value: (abs(value - participants), value)
        )
        source_by_participant[str(participants)] = measured
        for group_size in GROUP_SIZES:
            projected[f"t{participants}_g{group_size}"] = recommendations_by_group[
                f"t{measured}_g{group_size}"
            ]
    return projected, source_by_participant


def repo_relative(path: Path, repository: Path) -> str:
    try:
        return path.resolve().relative_to(repository.resolve()).as_posix()
    except ValueError as error:
        raise ValueError(f"source is outside repository: {path}") from error


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("verification", type=Path)
    parser.add_argument("harness", type=Path)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source", action="append", type=Path, default=[])
    parser.add_argument("--compiler-version", required=True)
    parser.add_argument("--compile-command", required=True)
    parser.add_argument("--run-command", required=True)
    parser.add_argument("--cpu", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--bootstrap-resamples", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=0x47504E45)
    args = parser.parse_args()
    if args.bootstrap_resamples <= 0:
        raise ValueError("bootstrap resamples must be positive")

    run_id, grouped = parse_raw(args.raw)
    validate_verification(args.verification, run_id)
    statistics_by_key: dict[str, object] = {}
    run_medians: dict[tuple[int, int, int], list[float]] = {}
    for participants in PARTICIPANTS:
        for group_size in GROUP_SIZES:
            for tile_rows in TILE_ROWS:
                per_run: list[float] = []
                all_values: list[float] = []
                for run_index in range(RUNS):
                    values: list[float] = []
                    for round_index in range(ROUNDS):
                        values.extend(
                            grouped[
                                (
                                    participants,
                                    group_size,
                                    tile_rows,
                                    run_index,
                                    round_index,
                                )
                            ]
                        )
                    per_run.append(median(values))
                    all_values.extend(values)
                all_values.sort()
                run_medians[(participants, group_size, tile_rows)] = per_run
                key = f"t{participants}_g{group_size}_tile{tile_rows}"
                statistics_by_key[key] = {
                    "claims": (OUT_FEATURES + tile_rows - 1) // tile_rows,
                    "samples": len(all_values),
                    "run_medians_ns": per_run,
                    "median_of_run_medians_ns": median(per_run),
                    "all_samples_median_ns": median(all_values),
                    "p25_ns": percentile(all_values, 0.25),
                    "p75_ns": percentile(all_values, 0.75),
                }

    comparisons: dict[str, object] = {}
    recommendations_by_group, recommendations_by_participants = recommend_tiles(
        run_medians
    )
    projected_by_group, projection_sources = project_measured_tiles(
        recommendations_by_group
    )
    for participants in PARTICIPANTS:
        for group_size in GROUP_SIZES:
            baseline = run_medians[(participants, group_size, 64)]
            for tile_rows in TILE_ROWS:
                if tile_rows == 64:
                    continue
                candidate = run_medians[(participants, group_size, tile_rows)]
                comparison_seed = (
                    args.seed ^ (participants << 24) ^ (group_size << 16) ^ tile_rows
                )
                comparisons[
                    f"t{participants}_g{group_size}_tile{tile_rows}_over_tile64"
                ] = bootstrap_run_median_ratio(
                    baseline,
                    candidate,
                    args.bootstrap_resamples,
                    comparison_seed,
                )

    repository = Path.cwd()
    source_hashes = {
        repo_relative(path, repository): sha256(path) for path in args.source
    }
    source_hashes[repo_relative(args.harness, repository)] = sha256(args.harness)
    source_hashes[repo_relative(Path(__file__), repository)] = sha256(Path(__file__))
    report = {
        "schema": "glacier.pair-nibble-executor-tile.v1",
        "status": "pass",
        "run_id": run_id,
        "exact_verification": True,
        "configuration": {
            "out_features": OUT_FEATURES,
            "in_features": IN_FEATURES,
            "participants": list(PARTICIPANTS),
            "group_sizes": list(GROUP_SIZES),
            "tile_rows": list(TILE_ROWS),
            "campaign_runs": RUNS,
            "balanced_rounds_per_run": ROUNDS,
            "samples_per_round_per_config": SAMPLES,
            "samples_per_config": RUNS * ROUNDS * SAMPLES,
            "qos": "QOS_CLASS_USER_INTERACTIVE",
            "bootstrap_resamples": args.bootstrap_resamples,
            "bootstrap_seed": args.seed,
        },
        "environment": {
            "cpu": args.cpu,
            "os": args.os,
            "compiler_version": args.compiler_version,
            "compile_command": args.compile_command,
            "run_command": args.run_command,
        },
        "hashes_sha256": {
            "raw_csv": sha256(args.raw),
            "verification_log": sha256(args.verification),
            "benchmark_binary": sha256(args.binary),
            "sources": source_hashes,
        },
        "statistics": statistics_by_key,
        "comparisons": comparisons,
        "recommendation": {
            "selection_method": (
                "lowest median paired per-run latency ratio; cross-group uses "
                "the geometric mean of those paired ratios"
            ),
            "measured_participants": list(PARTICIPANTS),
            "by_participants_and_group": recommendations_by_group,
            "cross_group_by_participants": recommendations_by_participants,
            "runtime_projection": {
                "method": (
                    "nearest measured participant count; equal-distance ties "
                    "select the lower participant count"
                ),
                "source_participant_by_participant": projection_sources,
                "by_participants_and_group": projected_by_group,
            },
        },
    }
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
