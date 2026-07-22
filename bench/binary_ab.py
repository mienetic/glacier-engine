#!/usr/bin/env python3
"""Hash-pinned ABBA comparison of two Glacier binaries under one policy."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import re
import statistics
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

import attention_ab as common


SCHEMA = "glacier.binary-ab/result-v1"
ROLES = ("baseline", "candidate")
_LEGACY_PHASES_RE = re.compile(
    r"^[^\S\r\n]*phases:[^\S\r\n]+prefill_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+sampling_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_runs=([0-9]+)"
    r"[^\S\r\n]+attention_graphs=([0-9]+)"
    r"[^\S\r\n]+attention_dispatches=([0-9]+)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_HANDOFF_PHASES_RE = re.compile(
    r"^[^\S\r\n]*phases:[^\S\r\n]+prefill_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+sampling_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_runs=([0-9]+)"
    r"[^\S\r\n]+attention_graphs=([0-9]+)"
    r"[^\S\r\n]+attention_dispatches=([0-9]+)"
    r"[^\S\r\n]+handoff_graphs=([0-9]+)"
    r"[^\S\r\n]+handoff_dispatches=([0-9]+)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_FUSED_PHASES_RE = re.compile(
    r"^[^\S\r\n]*phases:[^\S\r\n]+prefill_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+sampling_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_runs=([0-9]+)"
    r"[^\S\r\n]+attention_graphs=([0-9]+)"
    r"[^\S\r\n]+attention_dispatches=([0-9]+)"
    r"[^\S\r\n]+handoff_graphs=([0-9]+)"
    r"[^\S\r\n]+handoff_dispatches=([0-9]+)"
    r"[^\S\r\n]+fused_gqa_graphs=([0-9]+)"
    r"[^\S\r\n]+fused_gqa_dispatches=([0-9]+)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)


@dataclass(frozen=True)
class Config:
    baseline_binary: Path
    candidate_binary: Path
    model: Path
    ids: Path
    output: Path | None
    cwd: Path
    samples_per_variant: int = 32
    warmups_per_variant: int = 1
    new_tokens: int = 64
    threads: int = 4
    schedule_seed: int = common.DEFAULT_SCHEDULE_SEED
    bootstrap_seed: int = common.DEFAULT_BOOTSTRAP_SEED
    bootstrap_resamples: int = common.DEFAULT_BOOTSTRAP_RESAMPLES
    confidence: float = 0.95
    timeout_seconds: float = 3600.0
    overwrite: bool = False
    baseline_sha256: str | None = None
    candidate_sha256: str | None = None
    model_sha256: str | None = None
    ids_sha256: str | None = None
    parallel_attention_min_context: int | None = None


def _validate(config: Config) -> None:
    if config.samples_per_variant > 10_000:
        raise common.HarnessError("samples per variant must not exceed 10000")
    common.build_patterns(config.samples_per_variant, config.schedule_seed)
    threshold = config.parallel_attention_min_context
    if threshold is not None and (
        isinstance(threshold, bool) or threshold <= 0 or threshold > common.MAX_I64
    ):
        raise common.HarnessError(
            "parallel attention minimum context must be a positive int64"
        )
    if not 1 <= config.warmups_per_variant <= 100:
        raise common.HarnessError("warmups per variant must be in [1, 100]")
    if not 1 <= config.new_tokens <= 1_000_000:
        raise common.HarnessError("new tokens must be in [1, 1000000]")
    if not 1 <= config.threads <= 65_536:
        raise common.HarnessError("threads must be in [1, 65536]")
    if not 100 <= config.bootstrap_resamples <= 1_000_000:
        raise common.HarnessError("bootstrap resamples must be in [100, 1000000]")
    if not 0.5 <= config.confidence <= 0.999:
        raise common.HarnessError("confidence must be in [0.5, 0.999]")
    if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
        raise common.HarnessError("timeout must be finite and positive")
    if not config.cwd.is_dir():
        raise common.HarnessError(f"cwd is not a directory: {config.cwd}")
    paths = {
        config.baseline_binary,
        config.candidate_binary,
        config.model,
        config.ids,
        Path(__file__).resolve(),
        Path(common.__file__).resolve(),
    }
    if len(paths) != 6:
        raise common.HarnessError("benchmark inputs and drivers must be distinct files")
    if config.output is not None and config.output in paths:
        raise common.HarnessError("result output must not replace an input artifact")
    for name, digest in (
        ("baseline", config.baseline_sha256),
        ("candidate", config.candidate_sha256),
        ("model", config.model_sha256),
        ("ids", config.ids_sha256),
    ):
        if digest is not None and common.SHA256_RE.fullmatch(digest) is None:
            raise common.HarnessError(
                f"{name} SHA-256 pin must be 64 lowercase hex digits"
            )


def _fingerprints(config: Config) -> dict[str, dict[str, Any]]:
    return {
        "baseline_binary": common.fingerprint(
            config.baseline_binary, "baseline binary", config.baseline_sha256
        ),
        "candidate_binary": common.fingerprint(
            config.candidate_binary, "candidate binary", config.candidate_sha256
        ),
        "model": common.fingerprint(config.model, "model", config.model_sha256),
        "prompt_ids": common.fingerprint(config.ids, "prompt IDs", config.ids_sha256),
        "driver": common.fingerprint(Path(__file__).resolve(), "driver", None),
        "shared_driver": common.fingerprint(
            Path(common.__file__).resolve(), "shared driver", None
        ),
    }


def _verify_fingerprints(
    config: Config, before: Mapping[str, Mapping[str, Any]]
) -> dict[str, dict[str, Any]]:
    after = _fingerprints(config)
    for name in before:
        if before[name]["identity"] != after[name]["identity"]:
            raise common.HarnessError(f"{name} identity changed during benchmark")
        if before[name]["sha256"] != after[name]["sha256"]:
            raise common.HarnessError(f"{name} hash changed during benchmark")
    return after


def _command(config: Config, role: str, completion: Path) -> list[str]:
    binary = config.baseline_binary if role == "baseline" else config.candidate_binary
    policy = (
        ["--serial-attention"]
        if config.parallel_attention_min_context is None
        else [
            "--parallel-attention-min-context",
            str(config.parallel_attention_min_context),
        ]
    )
    return [
        str(binary),
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
        str(common.MAX_U32),
        "--require-batch-prefill",
        "--require-prepared-image",
        "--out-ids-file",
        str(completion),
        *policy,
    ]


def _normalize_telemetry(
    output: str,
    *,
    allow_missing_paired_mlp: bool,
    allow_pre_fused: bool,
) -> tuple[str, str]:
    phase_prefixes = len(re.findall(r"^[^\S\r\n]*phases:", output, re.I | re.M))
    if "paired_mlp_graphs=" in output or "paired_mlp_dispatches=" in output:
        matches = list(common._PHASES_RE.finditer(output))
        if phase_prefixes != 1 or len(matches) != 1:
            raise common.HarnessError(
                "paired-MLP phase telemetry is missing, malformed, or duplicated"
            )
        return output, "paired-mlp-v4"
    if "fused_gqa_graphs=" in output or "fused_gqa_dispatches=" in output:
        matches = list(_FUSED_PHASES_RE.finditer(output))
        if phase_prefixes != 1 or len(matches) != 1:
            raise common.HarnessError(
                "fused-GQA phase telemetry is missing, malformed, or duplicated"
            )
        if not allow_missing_paired_mlp:
            raise common.HarnessError(
                "current binary must emit native paired-MLP phase telemetry"
            )
        match = matches[0]
        normalized = (
            output[: match.start()]
            + match.group(0).rstrip()
            + " paired_mlp_graphs=0 paired_mlp_dispatches=0"
            + output[match.end() :]
        )
        return normalized, "fused-gqa-v3+paired-zero"
    if "handoff_graphs=" in output or "handoff_dispatches=" in output:
        matches = list(_HANDOFF_PHASES_RE.finditer(output))
        if phase_prefixes != 1 or len(matches) != 1:
            raise common.HarnessError(
                "handoff phase telemetry is missing, malformed, or duplicated"
            )
        if not allow_missing_paired_mlp or not allow_pre_fused:
            raise common.HarnessError(
                "current or parallel binary must emit fused-GQA and paired-MLP phase telemetry"
            )
        match = matches[0]
        normalized = (
            output[: match.start()]
            + match.group(0).rstrip()
            + " fused_gqa_graphs=0 fused_gqa_dispatches=0"
            + " paired_mlp_graphs=0 paired_mlp_dispatches=0"
            + output[match.end() :]
        )
        return normalized, "handoff-v2+fused-paired-zero"
    matches = list(_LEGACY_PHASES_RE.finditer(output))
    if phase_prefixes != 1 or len(matches) != 1:
        raise common.HarnessError(
            "legacy phase telemetry is missing, malformed, or duplicated"
        )
    if not allow_missing_paired_mlp or not allow_pre_fused:
        raise common.HarnessError(
            "current or parallel binary must emit fused-GQA and paired-MLP phase telemetry"
        )
    match = matches[0]
    normalized = (
        output[: match.start()]
        + match.group(0).rstrip()
        + " handoff_graphs=0 handoff_dispatches=0"
        + " fused_gqa_graphs=0 fused_gqa_dispatches=0"
        + " paired_mlp_graphs=0 paired_mlp_dispatches=0"
        + output[match.end() :]
    )
    return normalized, "legacy-v1+handoff-fused-paired-zero"


def _normalize_serial_telemetry(output: str) -> tuple[str, str]:
    return _normalize_telemetry(
        output,
        allow_missing_paired_mlp=True,
        allow_pre_fused=True,
    )


def _observe(
    config: Config,
    role: str,
    completion: Path,
    prompt_ids: Sequence[int],
    artifacts: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    common.assert_artifact_identities(artifacts)
    if completion.exists():
        raise common.HarnessError(f"completion path unexpectedly exists: {completion}")
    argv = _command(config, role, completion)
    process = common._run_process(argv, config.cwd, config.timeout_seconds)
    common.assert_artifact_identities(artifacts)
    if not completion.is_file():
        raise common.HarnessError("Glacier did not create the completion-ID file")
    raw_ids = completion.read_bytes()
    completion_ids = common.parse_ids(raw_ids, "completion output")
    if len(completion_ids) != config.new_tokens:
        raise common.HarnessError(
            f"completion output had {len(completion_ids)} IDs, expected {config.new_tokens}"
        )
    threshold = config.parallel_attention_min_context
    normalized, telemetry_format = _normalize_telemetry(
        process["output"],
        allow_missing_paired_mlp=role == "baseline",
        allow_pre_fused=role == "baseline" and threshold is None,
    )
    if threshold is None:
        telemetry_variant = "serial"
        telemetry_threshold = 1
        require_fused_gqa = False
        require_paired_mlp = False
    else:
        telemetry_variant = "parallel"
        telemetry_threshold = threshold
        require_fused_gqa = True
        # The predecessor may use the exact old fused-GQA record. Any binary
        # that emits the current native record must prove that its typed
        # paired-MLP handoff covered every eligible graph and model layer.
        require_paired_mlp = telemetry_format == "paired-mlp-v4"
    metrics = common.parse_telemetry(
        normalized,
        variant=telemetry_variant,
        prompt_tokens=len(prompt_ids),
        new_tokens=config.new_tokens,
        threshold=telemetry_threshold,
        require_fused_gqa=require_fused_gqa,
        require_paired_mlp=require_paired_mlp,
    )
    metrics["harness_wall_ms"] = process["wall_ms"]
    return {
        # common.paired_ratio uses these stable labels as role aliases. The
        # actual attention policy is identical for both roles and is recorded
        # independently in the contract and each observation.
        "variant": "serial" if role == "baseline" else "parallel",
        "role": role,
        "attention_policy": telemetry_variant,
        "argv": argv,
        "metrics": metrics,
        "telemetry_format": telemetry_format,
        "telemetry_sha256": common.sha256_bytes(process["output"].encode()),
        "completion_ids": completion_ids,
        "completion_ids_sha256": common.sha256_bytes(
            common.canonical_ids_bytes(completion_ids)
        ),
        "completion_file_sha256": common.sha256_bytes(raw_ids),
        "exit_status": process["exit_status"],
    }


def run_benchmark(config: Config) -> dict[str, Any]:
    _validate(config)
    artifacts_before = _fingerprints(config)
    try:
        prompt_ids = common.parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise common.HarnessError(f"cannot read prompt IDs: {error}") from error
    patterns = common.build_patterns(config.samples_per_variant, config.schedule_seed)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    with tempfile.TemporaryDirectory(prefix="glacier-binary-ab.") as temporary:
        run_root = Path(temporary)

        def observe(
            role: str,
            *,
            warmup: bool,
            block_index: int,
            position: int,
            pattern: str,
        ) -> dict[str, Any]:
            nonlocal reference_ids
            sequence = len(warmups) if warmup else len(samples)
            sample_root = (
                run_root / f"{'warmup' if warmup else 'sample'}-{sequence:03d}-{role}"
            )
            sample_root.mkdir()
            item = _observe(
                config,
                role,
                sample_root / "completion.ids",
                prompt_ids,
                artifacts_before,
            )
            item.update(
                {
                    "warmup": warmup,
                    "sequence_index": sequence,
                    "block_index": block_index,
                    "position_in_block": position,
                    "pattern": pattern,
                    "fresh_process": True,
                }
            )
            if reference_ids is None:
                reference_ids = list(item["completion_ids"])
            elif item["completion_ids"] != reference_ids:
                raise common.HarnessError(
                    f"exact completion IDs changed at {role} observation {sequence}"
                )
            return item

        warmup_order = list(ROLES)
        if config.schedule_seed & 1:
            warmup_order.reverse()
        for _ in range(config.warmups_per_variant):
            for position, role in enumerate(warmup_order):
                warmups.append(
                    observe(
                        role,
                        warmup=True,
                        block_index=-1,
                        position=position,
                        pattern="warmup",
                    )
                )
        for block_index, pattern in enumerate(patterns):
            for position, letter in enumerate(pattern):
                role = "candidate" if letter == "A" else "baseline"
                samples.append(
                    observe(
                        role,
                        warmup=False,
                        block_index=block_index,
                        position=position,
                        pattern=pattern,
                    )
                )

    artifacts_after = _verify_fingerprints(config, artifacts_before)
    assert reference_ids is not None
    ratio_fields = ("prefill_ms", "decode_ms", "internal_ms", "harness_wall_ms")
    ratios: dict[str, Any] = {}
    for field in ratio_fields:
        ratio = common.paired_ratio(
            samples,
            field,
            resamples=config.bootstrap_resamples,
            seed=config.bootstrap_seed,
            confidence=config.confidence,
        )
        ratio["direction"] = "baseline_over_candidate; greater than 1 favors candidate"
        ratios[field] = ratio
    medians = {
        role: {
            field: statistics.median(
                float(sample["metrics"][field])
                for sample in samples
                if sample["role"] == role
            )
            for field in ratio_fields
        }
        for role in ROLES
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
            "attention_policy": (
                "serial"
                if config.parallel_attention_min_context is None
                else "parallel"
            ),
            "parallel_attention_min_context": config.parallel_attention_min_context,
            "require_fused_gqa": config.parallel_attention_min_context is not None,
            "require_candidate_paired_mlp": (
                config.parallel_attention_min_context is not None
            ),
            "require_native_paired_mlp": (
                config.parallel_attention_min_context is not None
            ),
            "allow_exact_baseline_pre_paired_telemetry": True,
            "strict_prepared_glrt": True,
            "strict_batch_prefill": True,
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": "candidate", "B": "baseline"},
            "exact_completion_ids_required_across_all_invocations": True,
        },
        "artifacts_before": artifacts_before,
        "artifacts_after": artifacts_after,
        "prompt_ids": {
            "count": len(prompt_ids),
            "normalized_sha256": common.sha256_bytes(
                common.canonical_ids_bytes(prompt_ids)
            ),
        },
        "completion_equivalence": {
            "exact_ids_match": True,
            "token_count": len(reference_ids),
            "token_ids": reference_ids,
            "normalized_sha256": common.sha256_bytes(
                common.canonical_ids_bytes(reference_ids)
            ),
            "distinct_normalized_hashes": sorted(
                {item["completion_ids_sha256"] for item in [*warmups, *samples]}
            ),
        },
        "warmups": warmups,
        "samples": samples,
        "medians": medians,
        "baseline_over_candidate": ratios,
    }
    json.dumps(result, allow_nan=False)
    return result


def parse_args(argv: Sequence[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(
        description="Compare two pinned Glacier binaries under the same attention policy."
    )
    parser.add_argument("--baseline-binary", type=Path, required=True)
    parser.add_argument("--candidate-binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--ids", type=Path, required=True)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--samples-per-variant", type=int, default=32)
    parser.add_argument("--warmups-per-variant", type=int, default=1)
    parser.add_argument("--new-tokens", type=int, default=64)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument(
        "--schedule-seed", type=int, default=common.DEFAULT_SCHEDULE_SEED
    )
    parser.add_argument(
        "--bootstrap-seed", type=int, default=common.DEFAULT_BOOTSTRAP_SEED
    )
    parser.add_argument(
        "--bootstrap-resamples", type=int, default=common.DEFAULT_BOOTSTRAP_RESAMPLES
    )
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument(
        "--parallel-attention-min-context",
        type=int,
        help=(
            "run both binaries with the same parallel threshold and require "
            "full fused-GQA coverage; omitted means explicit serial attention"
        ),
    )
    parser.add_argument("--baseline-sha256")
    parser.add_argument("--candidate-sha256")
    parser.add_argument("--model-sha256")
    parser.add_argument("--ids-sha256")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args(argv)
    return Config(
        baseline_binary=args.baseline_binary.resolve(),
        candidate_binary=args.candidate_binary.resolve(),
        model=args.model.resolve(),
        ids=args.ids.resolve(),
        output=args.output.resolve(),
        cwd=args.cwd.resolve(),
        samples_per_variant=args.samples_per_variant,
        warmups_per_variant=args.warmups_per_variant,
        new_tokens=args.new_tokens,
        threads=args.threads,
        schedule_seed=args.schedule_seed,
        bootstrap_seed=args.bootstrap_seed,
        bootstrap_resamples=args.bootstrap_resamples,
        confidence=args.confidence,
        timeout_seconds=args.timeout_seconds,
        parallel_attention_min_context=args.parallel_attention_min_context,
        overwrite=args.overwrite,
        baseline_sha256=args.baseline_sha256,
        candidate_sha256=args.candidate_sha256,
        model_sha256=args.model_sha256,
        ids_sha256=args.ids_sha256,
    )


def main(argv: Sequence[str] | None = None) -> int:
    try:
        config = parse_args(argv)
        result = run_benchmark(config)
        common.write_result(result, config.output, config.overwrite)
        if config.output is not None:
            print(f"wrote {config.output}")
        return 0
    except (common.HarnessError, OSError, ValueError) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
