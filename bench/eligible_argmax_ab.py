#!/usr/bin/env python3
"""Retain an honest same-process full/eligible LM-head A/B artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


SCHEMA = "glacier.eligible-argmax-ab/result-v2"
RAW_SCHEMA = "glacier.eligible-argmax-kernel/raw-v2"
GREEDY_ABI = "474c4d4800000002"
ELIGIBILITY_ABI = "474c564900000001"
REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATHS = (
    Path("build.zig"),
    Path("build.zig.zon"),
    Path("src/root.zig"),
    Path("src/config.zig"),
    Path("src/core/tensor.zig"),
    Path("src/core/quant.zig"),
    Path("src/int4_executor.zig"),
    Path("src/int4_weights.zig"),
    Path("src/backends/cpu/int4_matmul.zig"),
    Path("src/backends/cpu/kernels.zig"),
    Path("src/backends/cpu/int4_neon.c"),
    Path("src/model/runtime_image.zig"),
    Path("src/loader.zig"),
    Path("bench/eligible_argmax.zig"),
    Path("bench/eligible_argmax_ab.py"),
    Path("bench/tests/test_eligible_argmax_ab.py"),
)
LINE_RE = re.compile(
    r"^eligible_argmax: schema=(\S+) vocab=(\d+) dim=(\d+) group_size=(\d+) "
    r"threads=(\d+) samples=(\d+) warmups=(\d+) materialized_oracle=(\d+) "
    r"full_winner=(\d+) eligible_materialized_oracle=(\d+) "
    r"eligible_winner=(\d+) eligible_rows=(\d+) producer_rows=(\d+) "
    r"skipped_rows=(\d+) overcomputed_rows=(\d+) producer_runs=(\d+) "
    r"tile_scratch_bytes=(\d+) executor_scratch_bytes=(\d+) "
    r"greedy_abi=([0-9a-f]+) eligibility_abi=([0-9a-f]+) "
    r"optimize=(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) metal_enabled=([01]) "
    r"zig=(\S+) checksum=(\d+)$"
)
HASH_RE = re.compile(r"^mask_sha256: ([0-9a-f]{64})$")
ELIGIBLE_IDS_RE = re.compile(r"^eligible_ids: ([0-9]+(?:,[0-9]+)*)$")
SAMPLES_RE = re.compile(r"^(full_ns|eligible_ns): ([0-9]+(?:,[0-9]+)*)$")
SCHEDULE = "schedule: F,E,E,F repeated-by-round"
SCOPE = (
    "scope: real_glrt_weights deterministic_synthetic_f32_input "
    "isolated_lm_head excludes_load_and_decode"
)


class HarnessError(RuntimeError):
    """Evidence contract failure."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--samples", type=int, default=32)
    parser.add_argument("--warmups", type=int, default=4)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--eligible-rows", type=int, default=64)
    parser.add_argument("--bootstrap-resamples", type=int, default=100_000)
    parser.add_argument("--bootstrap-seed", type=int, default=20260720)
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    return parser.parse_args()


def identity(path: Path) -> dict[str, int]:
    stat = path.stat()
    return {
        "bytes": stat.st_size,
        "ctime_ns": stat.st_ctime_ns,
        "device": stat.st_dev,
        "inode": stat.st_ino,
        "mode": stat.st_mode,
        "mtime_ns": stat.st_mtime_ns,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def artifact(path: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    return {
        "path": str(resolved),
        "identity": identity(resolved),
        "sha256": sha256_file(resolved),
    }


def source_artifacts() -> dict[str, dict[str, Any]]:
    return {str(path): artifact(REPO_ROOT / path) for path in SOURCE_PATHS}


def validate_config(args: argparse.Namespace) -> None:
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        raise HarnessError("--binary must be an executable file")
    if not args.model.is_file() or args.model.suffix != ".glrt":
        raise HarnessError("--model must be an existing .glrt image")
    if args.output.exists():
        raise HarnessError("refusing to replace an existing output artifact")
    if not 2 <= args.samples <= 100_000:
        raise HarnessError("--samples must be in [2, 100000]")
    if not 0 <= args.warmups <= 10_000:
        raise HarnessError("--warmups must be in [0, 10000]")
    if not 1 <= args.threads <= 256:
        raise HarnessError("--threads must be in [1, 256]")
    if args.eligible_rows <= 0:
        raise HarnessError("--eligible-rows must be positive")
    if not 1_000 <= args.bootstrap_resamples <= 1_000_000:
        raise HarnessError("--bootstrap-resamples must be in [1000, 1000000]")
    if args.timeout_seconds <= 0:
        raise HarnessError("--timeout-seconds must be positive")


def parse_samples(value: str, expected: int) -> list[int]:
    samples = [int(item) for item in value.split(",")]
    if len(samples) != expected or any(item <= 0 for item in samples):
        raise HarnessError("raw timing sample count/value contract failed")
    return samples


def parse_stdout(stdout: bytes, expected_samples: int) -> dict[str, Any]:
    try:
        lines = stdout.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as exc:
        raise HarnessError("benchmark stdout was not UTF-8") from exc
    if len(lines) != 7:
        raise HarnessError(f"expected exactly seven output lines, got {len(lines)}")
    match = LINE_RE.fullmatch(lines[0])
    if match is None:
        raise HarnessError("eligible_argmax summary line did not match the ABI")
    values = match.groups()
    if values[0] != RAW_SCHEMA:
        raise HarnessError(f"raw schema was {values[0]!r}, expected {RAW_SCHEMA!r}")
    numeric_names = (
        "vocab",
        "dim",
        "group_size",
        "threads",
        "samples",
        "warmups",
        "materialized_oracle",
        "full_winner",
        "eligible_materialized_oracle",
        "eligible_winner",
        "eligible_rows",
        "producer_rows",
        "skipped_rows",
        "overcomputed_rows",
        "producer_runs",
        "tile_scratch_bytes",
        "executor_scratch_bytes",
    )
    parsed = {name: int(value) for name, value in zip(numeric_names, values[1:18])}
    parsed["greedy_abi"] = values[18]
    parsed["eligibility_abi"] = values[19]
    parsed["optimize"] = values[20]
    parsed["metal_enabled"] = bool(int(values[21]))
    parsed["zig_version"] = values[22]
    parsed["checksum"] = int(values[23])
    hash_match = HASH_RE.fullmatch(lines[1])
    if hash_match is None:
        raise HarnessError("mask hash line did not match the ABI")
    parsed["mask_sha256"] = hash_match.group(1)
    ids_match = ELIGIBLE_IDS_RE.fullmatch(lines[2])
    if ids_match is None:
        raise HarnessError("eligible ID line did not match the ABI")
    parsed["eligible_ids"] = [
        int(value) for value in ids_match.group(1).split(",")
    ]
    sample_map: dict[str, list[int]] = {}
    for line in lines[3:5]:
        sample_match = SAMPLES_RE.fullmatch(line)
        if sample_match is None or sample_match.group(1) in sample_map:
            raise HarnessError("timing line did not match the ABI")
        sample_map[sample_match.group(1)] = parse_samples(
            sample_match.group(2), expected_samples
        )
    if set(sample_map) != {"full_ns", "eligible_ns"}:
        raise HarnessError("both timing variants are required")
    if lines[5] != SCHEDULE or lines[6] != SCOPE:
        raise HarnessError("schedule/scope declaration changed")
    parsed.update(sample_map)
    return parsed


def percentile(sorted_values: Sequence[float], probability: float) -> float:
    if not sorted_values:
        raise HarnessError("cannot take a percentile of no values")
    position = probability * (len(sorted_values) - 1)
    lower = int(position)
    upper = min(lower + 1, len(sorted_values) - 1)
    fraction = position - lower
    return sorted_values[lower] * (1.0 - fraction) + sorted_values[upper] * fraction


def bootstrap_ratio(
    full_ns: Sequence[int],
    eligible_ns: Sequence[int],
    resamples: int,
    seed: int,
) -> dict[str, float]:
    if len(full_ns) != len(eligible_ns) or not full_ns or len(full_ns) % 2 != 0:
        raise HarnessError("an even number of paired timing rounds is required")
    rng = random.Random(seed)
    count = len(full_ns)
    block_count = count // 2
    ratios: list[float] = []
    for _ in range(resamples):
        blocks = [rng.randrange(block_count) for _ in range(block_count)]
        indices = [index for block in blocks for index in (2 * block, 2 * block + 1)]
        full_median = statistics.median(full_ns[index] for index in indices)
        eligible_median = statistics.median(eligible_ns[index] for index in indices)
        ratios.append(full_median / eligible_median)
    ratios.sort()
    return {
        "low_95": percentile(ratios, 0.025),
        "high_95": percentile(ratios, 0.975),
    }


def expected_eligible_ids(vocab: int, oracle: int, count: int) -> list[int]:
    if vocab <= 0 or not 0 <= oracle < vocab or not 1 <= count <= vocab:
        raise HarnessError("eligible-mask geometry was invalid")
    selected = {oracle}
    step = 104_729 % vocab or 1
    while math.gcd(step, vocab) != 1:
        step += 1
        if step == vocab:
            step = 1
    candidate = 17 % vocab
    while len(selected) < count:
        selected.add(candidate)
        candidate = (
            candidate - (vocab - step)
            if candidate >= vocab - step
            else candidate + step
        )
    return sorted(selected)


def mask_sha256(vocab: int, eligible_ids: Sequence[int]) -> str:
    words = [0] * ((vocab + 63) // 64)
    for token in eligible_ids:
        if not 0 <= token < vocab:
            raise HarnessError("eligible ID was outside the vocabulary")
        words[token // 64] |= 1 << (token % 64)
    raw = b"".join(word.to_bytes(8, byteorder=sys.byteorder) for word in words)
    return hashlib.sha256(raw).hexdigest()


def sysctl_value(name: str) -> str | None:
    if platform.system() != "Darwin":
        return None
    completed = subprocess.run(
        ["sysctl", "-n", name],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        text=True,
    )
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and value else None


def publish_no_clobber(output: Path, payload: bytes) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as target:
            target.write(payload)
            target.flush()
            os.fsync(target.fileno())
        try:
            os.link(temporary, output)
        except FileExistsError as exc:
            raise HarnessError("refusing to replace an existing output artifact") from exc
        directory_fd = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    validate_config(args)
    binary_before = artifact(args.binary)
    model_before = artifact(args.model)
    sources_before = source_artifacts()
    command = [
        str(args.binary.resolve()),
        str(args.model.resolve()),
        str(args.samples),
        str(args.warmups),
        str(args.threads),
        str(args.eligible_rows),
    ]
    started = time.monotonic_ns()
    completed = subprocess.run(
        command,
        cwd=Path(__file__).resolve().parent.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=args.timeout_seconds,
        check=False,
    )
    process_ns = time.monotonic_ns() - started
    if completed.returncode != 0:
        raise HarnessError(
            f"benchmark exited {completed.returncode}: "
            f"{completed.stderr.decode('utf-8', errors='replace')}"
        )
    if completed.stderr:
        raise HarnessError("benchmark emitted unexpected stderr")
    parsed = parse_stdout(completed.stdout, args.samples)
    binary_after = artifact(args.binary)
    model_after = artifact(args.model)
    sources_after = source_artifacts()
    if (
        binary_after != binary_before
        or model_after != model_before
        or sources_after != sources_before
    ):
        raise HarnessError("binary, model, or source identity/hash changed during measurement")

    if parsed["threads"] != args.threads or parsed["samples"] != args.samples:
        raise HarnessError("reported execution geometry did not match the command")
    if parsed["warmups"] != args.warmups:
        raise HarnessError("reported warmups did not match the command")
    if parsed["eligible_rows"] != args.eligible_rows:
        raise HarnessError("reported eligible row count did not match the command")
    if parsed["materialized_oracle"] != parsed["full_winner"]:
        raise HarnessError("full producer winner did not match the materialized oracle")
    if parsed["eligible_materialized_oracle"] != parsed["eligible_winner"]:
        raise HarnessError("eligible winner did not match its materialized oracle")
    eligible_ids = parsed["eligible_ids"]
    if (
        len(eligible_ids) != parsed["eligible_rows"]
        or eligible_ids != sorted(set(eligible_ids))
    ):
        raise HarnessError("eligible IDs were not sorted, unique, and fully counted")
    expected_ids = expected_eligible_ids(
        parsed["vocab"],
        parsed["materialized_oracle"],
        args.eligible_rows,
    )
    if eligible_ids != expected_ids:
        raise HarnessError("eligible IDs did not match deterministic mask construction")
    if parsed["eligible_winner"] not in eligible_ids:
        raise HarnessError("eligible winner was absent from the eligible ID set")
    if parsed["eligible_materialized_oracle"] != parsed["materialized_oracle"]:
        raise HarnessError("forced full oracle was not the eligible oracle")
    if mask_sha256(parsed["vocab"], eligible_ids) != parsed["mask_sha256"]:
        raise HarnessError("eligible mask hash did not match reconstructed IDs")
    if parsed["producer_rows"] < parsed["eligible_rows"]:
        raise HarnessError("producer rows cannot be below eligible rows")
    if parsed["producer_rows"] + parsed["skipped_rows"] != parsed["vocab"]:
        raise HarnessError("producer/skipped accounting did not cover the vocabulary")
    if parsed["producer_rows"] - parsed["eligible_rows"] != parsed["overcomputed_rows"]:
        raise HarnessError("overcomputed accounting was inconsistent")
    if parsed["producer_rows"] % 4 != 0 or parsed["producer_runs"] <= 0:
        raise HarnessError("rows4 producer geometry was invalid")
    if parsed["producer_rows"] > 4 * parsed["eligible_rows"]:
        raise HarnessError("rows4 overcompute exceeded three neighbors per eligible row")
    if parsed["producer_runs"] > parsed["producer_rows"] // 4:
        raise HarnessError("producer runs exceeded the number of active rows4 groups")
    minimum_runs = (parsed["producer_rows"] + 63) // 64
    if parsed["producer_runs"] < minimum_runs:
        raise HarnessError("producer runs could not cover all producer rows")
    if parsed["tile_scratch_bytes"] != args.threads * 64 * 4:
        raise HarnessError("tile scratch did not match participants * 64 * sizeof(f32)")
    if parsed["executor_scratch_bytes"] != args.threads * 16:
        raise HarnessError("candidate scratch did not match participants * 16 bytes")
    if parsed["greedy_abi"] != GREEDY_ABI:
        raise HarnessError(
            f"greedy ABI was {parsed['greedy_abi']}, expected {GREEDY_ABI}"
        )
    if parsed["eligibility_abi"] != ELIGIBILITY_ABI:
        raise HarnessError(
            "eligibility ABI was "
            f"{parsed['eligibility_abi']}, expected {ELIGIBILITY_ABI}"
        )
    if parsed["optimize"] != "ReleaseFast" or parsed["metal_enabled"]:
        raise HarnessError("retained timing requires ReleaseFast with Metal disabled")
    expected_checksum = (
        parsed["full_winner"] + parsed["eligible_winner"]
    ) * args.samples % (1 << 64)
    if parsed["checksum"] != expected_checksum:
        raise HarnessError(
            f"timed winner checksum was {parsed['checksum']}, expected {expected_checksum}"
        )

    full_median = float(statistics.median(parsed["full_ns"]))
    eligible_median = float(statistics.median(parsed["eligible_ns"]))
    ratio = full_median / eligible_median
    interval = bootstrap_ratio(
        parsed["full_ns"],
        parsed["eligible_ns"],
        args.bootstrap_resamples,
        args.bootstrap_seed,
    )
    result = {
        "schema": SCHEMA,
        "status": "passed",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "decision": {
            "kind": "measurement-only",
            "promotion_evaluated": False,
            "reason": (
                "This isolates one LM-head API with a deterministic synthetic "
                "activation; it is not an end-to-end decode or llama.cpp comparison."
            ),
        },
        "artifacts_before": {
            "binary": binary_before,
            "model": model_before,
            "sources": sources_before,
        },
        "artifacts_after": {
            "binary": binary_after,
            "model": model_after,
            "sources": sources_after,
        },
        "command": command,
        "host": {
            "machine": platform.machine(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "logical_cpu_count": os.cpu_count(),
            "hardware_model": sysctl_value("hw.model"),
            "cpu_brand": sysctl_value("machdep.cpu.brand_string"),
            "memory_bytes": sysctl_value("hw.memsize"),
        },
        "contract": {
            "same_process": True,
            "same_executor": True,
            "alternating_schedule": "F,E,E,F repeated by round",
            "bootstrap_unit": "two-round F,E,E,F blocks",
            "real_glrt_weights": True,
            "activation": "deterministic synthetic finite f32",
            "scope": "isolated LM-head; model load and full decode excluded",
            "independent_materialized_oracle": True,
            "materialized_oracle_outside_timed_regions": True,
            "full_winner_forced_into_eligible_set": True,
            "exact_winner_required_every_invocation": True,
            "stable_counters_required": True,
            "greedy_abi": parsed["greedy_abi"],
            "eligibility_abi": parsed["eligibility_abi"],
            "mask_sha256": parsed["mask_sha256"],
            "eligible_ids": eligible_ids,
            "bootstrap_resamples": args.bootstrap_resamples,
            "bootstrap_seed": args.bootstrap_seed,
        },
        "geometry": {
            key: parsed[key]
            for key in (
                "vocab",
                "dim",
                "group_size",
                "threads",
                "samples",
                "warmups",
            )
        },
        "build": {
            "optimize": parsed["optimize"],
            "metal_enabled": parsed["metal_enabled"],
            "profile_reported_by_benchmark_binary": True,
            "zig_version": parsed["zig_version"],
        },
        "exactness": {
            "materialized_full_winner": parsed["materialized_oracle"],
            "full_producer_winner": parsed["full_winner"],
            "materialized_eligible_winner": parsed["eligible_materialized_oracle"],
            "eligible_winner": parsed["eligible_winner"],
            "match": True,
            "invocations_checked": 3 + 2 * args.warmups + 2 * args.samples,
            "checksum": parsed["checksum"],
        },
        "work": {
            key: parsed[key]
            for key in (
                "eligible_rows",
                "producer_rows",
                "skipped_rows",
                "overcomputed_rows",
                "producer_runs",
                "tile_scratch_bytes",
                "executor_scratch_bytes",
            )
        },
        "timing": {
            "unit": "ns",
            "full_samples": parsed["full_ns"],
            "eligible_samples": parsed["eligible_ns"],
            "full_median": full_median,
            "eligible_median": eligible_median,
            "full_over_eligible": {
                "point_estimate": ratio,
                **interval,
            },
            "process_elapsed_ns_including_load_hash_and_warmup": process_ns,
        },
        "stdout_sha256": hashlib.sha256(completed.stdout).hexdigest(),
        "limitations": [
            "The activation is deterministic synthetic f32, not a captured hidden state.",
            "Only the LM-head API is timed; transformer layers, sampling, and model load are excluded.",
            "The fixed eligible set is oracle-assisted and forced to contain the full exact winner; certification cost and recall are excluded.",
            "One activation and one mask are reused, so the 256 producer rows can remain cache-hot; this is a fixed-mask isolation, not a rotating workload.",
            "The bootstrap resamples two-round F,E,E,F blocks within one process; fresh-process, captured-state, thermal, and power-state evidence remains open.",
            "Selected source files and the binary are hashed, but the artifact does not prove a complete reproducible source-to-binary dependency closure.",
            "No current llama.cpp result is measured by this artifact.",
            "A speed ratio here cannot be multiplied into an end-to-end claim.",
        ],
    }
    payload = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode("utf-8")
    publish_no_clobber(args.output, payload)
    print(
        json.dumps(
            {
                "output": str(args.output.resolve()),
                "ratio": ratio,
                "low_95": interval["low_95"],
                "high_95": interval["high_95"],
                "winner": parsed["materialized_oracle"],
                "producer_rows": parsed["producer_rows"],
                "skipped_rows": parsed["skipped_rows"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
