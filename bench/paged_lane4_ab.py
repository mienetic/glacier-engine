#!/usr/bin/env python3
"""Balanced actual-model P2b/contiguous DecodeLane4 diagnostic campaign."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import statistics
import subprocess
import time
from pathlib import Path


ORDERS = ("contiguous-paged", "paged-contiguous")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--ids", type=Path, required=True)
    parser.add_argument("--terminal-kv", type=int, required=True)
    parser.add_argument("--capacity-kv", type=int, required=True)
    parser.add_argument("--samples-per-order", type=int, default=8)
    parser.add_argument("--warmups-per-order", type=int, default=1)
    parser.add_argument("--bootstrap-resamples", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=20260722)
    parser.add_argument("--head", default="materialized")
    parser.add_argument("--pair-down", default="split-control")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def run_one(args: argparse.Namespace, order: str) -> dict:
    command = [
        str(args.binary),
        str(args.model),
        str(args.ids),
        str(args.terminal_kv),
        str(args.capacity_kv),
        order,
        args.head,
        args.pair_down,
    ]
    env = os.environ.copy()
    env["VECLIB_MAXIMUM_THREADS"] = "4"
    completed = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )
    payload = json.loads(completed.stdout)
    if payload.get("schema") != "glacier.decode-lane4/paged-ab-raw-v1":
        raise RuntimeError("unexpected runner schema")
    if payload.get("state_equal") is not True or payload.get("order") != order:
        raise RuntimeError("runner did not prove exact state/order")
    return payload


def median(values: list[float]) -> float:
    if not values:
        raise RuntimeError("empty sample")
    return float(statistics.median(values))


def adjusted_ratio(by_order: dict[str, list[float]]) -> float:
    return math.sqrt(median(by_order[ORDERS[0]]) * median(by_order[ORDERS[1]]))


def bootstrap_ci(
    by_order: dict[str, list[float]],
    resamples: int,
    seed: int,
) -> tuple[float, float]:
    rng = random.Random(seed)
    draws: list[float] = []
    for _ in range(resamples):
        sampled: dict[str, list[float]] = {}
        for order in ORDERS:
            source = by_order[order]
            sampled[order] = [rng.choice(source) for _ in source]
        draws.append(adjusted_ratio(sampled))
    draws.sort()
    low = draws[int(0.025 * (len(draws) - 1))]
    high = draws[int(0.975 * (len(draws) - 1))]
    return low, high


def stable_identity(payload: dict) -> dict:
    return {
        key: payload[key]
        for key in (
            "runner_sha256",
            "model_sha256",
            "ids_sha256",
            "model_source_sha256",
            "decode_lane4_abi",
            "paged_decode_abi",
            "paged_kv_abi",
            "paged_token_txn_abi",
            "terminal_kv_positions",
            "capacity_kv_positions",
            "prompt_tokens_per_lane",
            "new_tokens_per_lane",
            "head_mode",
            "attention_mode",
            "pair_down_mode",
            "lane_states",
        )
    }


def main() -> None:
    args = parse_args()
    if args.samples_per_order < 2 or args.warmups_per_order < 0:
        raise SystemExit("invalid sample count")
    if args.terminal_kv > args.capacity_kv:
        raise SystemExit("terminal KV exceeds capacity")
    for path in (args.binary, args.model, args.ids):
        if not path.is_file():
            raise SystemExit(f"missing artifact: {path}")

    artifact_before = {
        "binary": sha256_file(args.binary),
        "model": sha256_file(args.model),
        "ids": sha256_file(args.ids),
    }
    for order in ORDERS:
        for _ in range(args.warmups_per_order):
            run_one(args, order)

    # Repeated ABBA blocks give each role every within-process position equally.
    schedule: list[str] = []
    while any(schedule.count(order) < args.samples_per_order for order in ORDERS):
        for order in (
            "contiguous-paged",
            "paged-contiguous",
            "paged-contiguous",
            "contiguous-paged",
        ):
            if schedule.count(order) < args.samples_per_order:
                schedule.append(order)

    observations: list[dict] = []
    identity: dict | None = None
    started = time.time()
    for index, order in enumerate(schedule):
        payload = run_one(args, order)
        current = stable_identity(payload)
        if identity is None:
            identity = current
        elif current != identity:
            raise RuntimeError("artifact/workload/state identity drift")
        observations.append(payload)
        print(
            f"[{index + 1}/{len(schedule)}] {order} "
            f"paged/contiguous={payload['paged_over_contiguous_rate']:.6f}",
            flush=True,
        )

    artifact_after = {
        "binary": sha256_file(args.binary),
        "model": sha256_file(args.model),
        "ids": sha256_file(args.ids),
    }
    if artifact_before != artifact_after:
        raise RuntimeError("artifact changed during campaign")

    ratios = {
        order: [
            float(item["paged_over_contiguous_rate"])
            for item in observations
            if item["order"] == order
        ]
        for order in ORDERS
    }
    point = adjusted_ratio(ratios)
    low, high = bootstrap_ci(ratios, args.bootstrap_resamples, args.seed)
    contiguous_rates = [
        float(item["contiguous"]["tokens_per_second"])
        for item in observations
    ]
    paged_rates = [
        float(item["paged16"]["tokens_per_second"])
        for item in observations
    ]
    first = observations[0]
    capacity = int(first["paged16"]["kv_capacity_bytes"])
    resident = int(first["paged16"]["kv_resident_allocation_bytes"])
    report = {
        "schema": "glacier.decode-lane4/paged-ab-campaign-v1",
        "publishable": False,
        "reason": (
            "balanced-same-machine-timing-and-logical-ledger-only; "
            "no power/thermal/external physical-memory/current-llama quality gate"
        ),
        "generated_unix_seconds": time.time(),
        "elapsed_seconds": time.time() - started,
        "seed": args.seed,
        "bootstrap_resamples": args.bootstrap_resamples,
        "samples_per_order": args.samples_per_order,
        "warmups_per_order": args.warmups_per_order,
        "schedule": schedule,
        "artifacts": artifact_before,
        "identity": identity,
        "summary": {
            "contiguous_median_tokens_per_second": median(contiguous_rates),
            "paged_median_tokens_per_second": median(paged_rates),
            "order_adjusted_paged_over_contiguous_rate": point,
            "bootstrap_95_ci": [low, high],
            "per_order_median_ratios": {
                order: median(ratios[order]) for order in ORDERS
            },
            "paged_capacity_bytes": capacity,
            "paged_resident_allocation_bytes": resident,
            "paged_capacity_over_resident_ratio": capacity / resident,
            "paged_logical_lazy_bytes": capacity - resident,
            "physical_memory_measured": False,
        },
        "observations": observations,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report["summary"], sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
