#!/usr/bin/env python3
"""Hash-pinned before/after resource A/B for ``glacier prepare``.

The two arms are distinct Glacier binaries operating on the same portable
model.  Every observation writes a fresh PairNibble GLRT, verifies its complete
SHA-256 identity, and records macOS ``/usr/bin/time -lp`` counters.  Balanced
ABBA/BAAB blocks make the result useful for deciding whether a bounded writer
actually removes peak preparation memory without silently changing the image.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
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

import attention_ab as common
import resource_ab as resource


SCHEMA = "glacier.prepare-resource-ab/result-v1"
ROLES = ("baseline", "candidate")
DEFAULT_SAMPLES_PER_ROLE = 16
DEFAULT_WARMUPS_PER_ROLE = 1
DEFAULT_SCHEDULE_SEED = 20_260_721
DEFAULT_BOOTSTRAP_SEED = 0x5052455041524541
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
SYSTEM_TIME_BINARY = Path("/usr/bin/time").resolve()

_PREPARE_RE = re.compile(
    r"^[^\S\r\n]*prepare:[^\S\r\n]+source=(.*?)"
    r"[^\S\r\n]+output=(.*?)"
    r"[^\S\r\n]+mlp_layout=(separate|pair-nibble)[^\S\r\n]*$",
    re.MULTILINE,
)
_PHASE_RE = re.compile(
    r"^[^\S\r\n]*hash_ms=([0-9]+\.[0-9]{2})"
    r"[^\S\r\n]+materialize_ms=([0-9]+\.[0-9]{2})"
    r"[^\S\r\n]+materialize_cache_state=(post-hash-os-warm)"
    r"[^\S\r\n]+write_ms=([0-9]+\.[0-9]{2})"
    r"[^\S\r\n]+total_ms=([0-9]+\.[0-9]{2})[^\S\r\n]*$",
    re.MULTILINE,
)
_IDENTITY_RE = re.compile(
    r"^[^\S\r\n]*source_sha256=([0-9a-f]{64})"
    r"[^\S\r\n]+provenance_sha256=([0-9a-f]{64})[^\S\r\n]*$",
    re.MULTILINE,
)
_WORKSPACE_RE = re.compile(
    r"^[^\S\r\n]*prepare_workspace:"
    r"[^\S\r\n]+generated_records=([0-9]+)"
    r"[^\S\r\n]+generated_workspace_bytes_total=([0-9]+)"
    r"[^\S\r\n]+generated_workspace_bytes_peak=([0-9]+)[^\S\r\n]*$",
    re.MULTILINE,
)

_RATIO_FIELDS = (
    "hash_ms",
    "materialize_ms",
    "write_ms",
    "total_ms",
    "harness_wall_seconds",
    "time_real_seconds",
    "time_cpu_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
_MEDIAN_FIELDS = (
    *_RATIO_FIELDS,
    "time_user_seconds",
    "time_sys_seconds",
)
_REQUIRED_POSITIVE_RESOURCES = (
    "time_real_seconds",
    "time_cpu_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
_COMMAND_ENVIRONMENT = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
}


@dataclass(frozen=True)
class Config:
    baseline_binary: Path
    candidate_binary: Path
    source: Path
    output: Path | None
    cwd: Path
    time_binary: Path = Path("/usr/bin/time")
    samples_per_role: int = DEFAULT_SAMPLES_PER_ROLE
    warmups_per_role: int = DEFAULT_WARMUPS_PER_ROLE
    schedule_seed: int = DEFAULT_SCHEDULE_SEED
    bootstrap_seed: int = DEFAULT_BOOTSTRAP_SEED
    bootstrap_resamples: int = DEFAULT_BOOTSTRAP_RESAMPLES
    confidence: float = 0.95
    timeout_seconds: float = 3600.0
    overwrite: bool = False
    baseline_sha256: str | None = None
    candidate_sha256: str | None = None
    source_sha256: str | None = None
    sidecar_sha256: str | None = None
    time_sha256: str | None = None
    test_only_allow_non_system_time: bool = False


def build_patterns(samples_per_role: int, seed: int) -> list[str]:
    if samples_per_role < 4 or samples_per_role % 4 != 0:
        raise common.HarnessError(
            "samples per role must be at least 4 and divisible by 4"
        )
    patterns = ["ABBA"] * (samples_per_role // 4)
    patterns += ["BAAB"] * (samples_per_role // 4)
    random.Random(seed).shuffle(patterns)
    return patterns


def parse_prepare_telemetry(
    output: bytes,
    *,
    expected_source: Path,
    expected_output: Path,
    expected_source_sha256: str,
) -> dict[str, Any]:
    """Parse one exact prepare record and reject ambiguous machine output."""

    try:
        text = output.decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise common.HarnessError("prepare telemetry must be ASCII") from error
    prepare = list(_PREPARE_RE.finditer(text))
    phases = list(_PHASE_RE.finditer(text))
    identities = list(_IDENTITY_RE.finditer(text))
    workspaces = list(_WORKSPACE_RE.finditer(text))
    if len(prepare) != 1 or len(phases) != 1 or len(identities) != 1:
        raise common.HarnessError(
            "prepare output must contain exactly one header, phase, and identity record"
        )
    if len(workspaces) > 1:
        raise common.HarnessError("prepare output has duplicate workspace telemetry")
    header = prepare[0]
    if header.group(1) != str(expected_source):
        raise common.HarnessError("prepare telemetry source path mismatch")
    if header.group(2) != str(expected_output):
        raise common.HarnessError("prepare telemetry output path mismatch")
    if header.group(3) != "pair-nibble":
        raise common.HarnessError("prepare did not select the PairNibble layout")
    identity = identities[0]
    if identity.group(1) != expected_source_sha256:
        raise common.HarnessError("prepare telemetry source SHA-256 mismatch")

    numeric = [float(phases[0].group(index)) for index in (1, 2, 4, 5)]
    if any(not math.isfinite(value) or value <= 0 for value in numeric):
        raise common.HarnessError("prepare phase timings must be finite and positive")
    hash_ms, materialize_ms, write_ms, total_ms = numeric
    # Each phase and the enclosing timer are rendered to 0.01 ms.  Sequential
    # phase rounding can exceed the independently rounded total by at most
    # 3*0.005 + 0.005 = 0.020 ms.
    if hash_ms + materialize_ms + write_ms > total_ms + 0.0200001:
        raise common.HarnessError("prepare phases exceed the enclosing total timer")
    workspace = None
    if workspaces:
        workspace_values = tuple(int(workspaces[0].group(index)) for index in (1, 2, 3))
        generated_records, workspace_total, workspace_peak = workspace_values
        if generated_records == 0:
            if workspace_total != 0 or workspace_peak != 0:
                raise common.HarnessError("zero generated records reported non-zero workspace")
        elif workspace_peak == 0 or workspace_total < workspace_peak:
            raise common.HarnessError("generated workspace ledger is inconsistent")
        workspace = {
            "generated_records": generated_records,
            "generated_workspace_bytes_total": workspace_total,
            "generated_workspace_bytes_peak": workspace_peak,
        }
    return {
        "hash_ms": hash_ms,
        "materialize_ms": materialize_ms,
        "write_ms": write_ms,
        "total_ms": total_ms,
        "materialize_cache_state": phases[0].group(3),
        "source_sha256": identity.group(1),
        "provenance_sha256": identity.group(2),
        "workspace": workspace,
    }


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
            raise common.HarnessError(f"metric {field} is missing or not numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or numeric <= 0:
            raise common.HarnessError(f"metric {field} must be finite and positive")
        role = str(sample["role"])
        if role not in ROLES:
            raise common.HarnessError(f"unknown prepare role: {role}")
        block = blocks.setdefault(
            int(sample["block_index"]), {name: [] for name in ROLES}
        )
        block[role].append(numeric)
    ordered = [blocks[index] for index in sorted(blocks)]
    if not ordered or any(
        len(block[role]) != 2 for block in ordered for role in ROLES
    ):
        raise common.HarnessError(
            "paired prepare bootstrap requires two observations per role per block"
        )

    def ratio(selected: Sequence[Mapping[str, Sequence[float]]]) -> float:
        baseline = [item for block in selected for item in block["baseline"]]
        candidate = [item for block in selected for item in block["candidate"]]
        return statistics.median(baseline) / statistics.median(candidate)

    field_seed = int.from_bytes(
        hashlib.sha256(field.encode("ascii")).digest()[:8], "big"
    )
    rng = random.Random(seed ^ field_seed)
    bootstrap = [
        ratio([ordered[rng.randrange(len(ordered))] for _ in ordered])
        for _ in range(resamples)
    ]
    tail = (1.0 - confidence) / 2.0
    estimate = ratio(ordered)
    return {
        "direction": "baseline_over_candidate; greater than 1 favors candidate",
        "estimate": estimate,
        "candidate_relative_change_percent": (1.0 / estimate - 1.0) * 100.0,
        "confidence": confidence,
        "ci_low": common.percentile(bootstrap, tail),
        "ci_high": common.percentile(bootstrap, 1.0 - tail),
        "bootstrap_resamples": resamples,
        "bootstrap_seed": seed,
    }


def _fingerprints(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.baseline_binary, os.X_OK):
        raise common.HarnessError(
            f"baseline binary is not executable: {config.baseline_binary}"
        )
    if not os.access(config.candidate_binary, os.X_OK):
        raise common.HarnessError(
            f"candidate binary is not executable: {config.candidate_binary}"
        )
    if config.source.suffix.lower() != ".glacier":
        raise common.HarnessError("prepare A/B source must be a portable .glacier model")
    declarations = {
        "driver": (Path(__file__).resolve(), None),
        "resource_support": (Path(resource.__file__).resolve(), None),
        "attention_support": (Path(common.__file__).resolve(), None),
        "baseline_binary": (config.baseline_binary, config.baseline_sha256),
        "candidate_binary": (config.candidate_binary, config.candidate_sha256),
        "source": (config.source, config.source_sha256),
        "time_binary": (config.time_binary, config.time_sha256),
    }
    sidecar = Path(str(config.source) + ".json")
    if sidecar.exists():
        declarations["source_sidecar"] = (sidecar, config.sidecar_sha256)
    elif config.sidecar_sha256 is not None:
        raise common.HarnessError(
            f"source sidecar SHA-256 was pinned but the sidecar is absent: {sidecar}"
        )
    return {
        name: common.fingerprint(path, name, expected)
        for name, (path, expected) in declarations.items()
    }


def _verify_fingerprints(
    config: Config, before: Mapping[str, Mapping[str, Any]]
) -> dict[str, dict[str, Any]]:
    after = _fingerprints(config)
    if set(before) != set(after):
        raise common.HarnessError("artifact set changed during prepare A/B")
    for name, prior in before.items():
        if prior["identity"] != after[name]["identity"]:
            raise common.HarnessError(f"artifact {name} identity changed during A/B")
        if prior["sha256"] != after[name]["sha256"]:
            raise common.HarnessError(f"artifact {name} bytes changed during A/B")
    return after


def _assert_absent_sidecar(config: Config, expected_absent: bool) -> None:
    if not expected_absent:
        return
    sidecar = Path(str(config.source) + ".json")
    if sidecar.exists() or sidecar.is_symlink():
        raise common.HarnessError(
            f"source sidecar appeared during prepare A/B: {sidecar}"
        )


def _run_process(
    argv: Sequence[str], *, cwd: Path, timeout_seconds: float
) -> tuple[bytes, float, int]:
    started = time.perf_counter_ns()
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
            env=dict(_COMMAND_ENVIRONMENT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError as error:
        raise common.HarnessError(f"cannot launch timed prepare: {error}") from error
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
        raise common.HarnessError(
            f"timed prepare exceeded {timeout_seconds} seconds"
        ) from error
    wall_seconds = (time.perf_counter_ns() - started) / 1e9
    if process.returncode != 0:
        rendered = output.decode("utf-8", errors="replace")
        raise common.HarnessError(
            f"timed prepare exited with {process.returncode}:\n{rendered}"
        )
    if not math.isfinite(wall_seconds) or wall_seconds <= 0:
        raise common.HarnessError("prepare harness wall time must be positive")
    return output, wall_seconds, process.returncode


def _observe(
    config: Config,
    role: str,
    *,
    prepared_path: Path,
    time_path: Path,
    artifacts: Mapping[str, Mapping[str, Any]],
    sidecar_expected_absent: bool,
) -> dict[str, Any]:
    _assert_absent_sidecar(config, sidecar_expected_absent)
    common.assert_artifact_identities(artifacts)
    if prepared_path.exists() or time_path.exists():
        raise common.HarnessError("observation output path unexpectedly exists")
    binary = (
        config.baseline_binary if role == "baseline" else config.candidate_binary
    )
    glacier_argv = [
        str(binary),
        "prepare",
        str(config.source),
        str(prepared_path),
        "--mlp-layout",
        "pair-nibble-required",
    ]
    timed_argv = [
        str(config.time_binary),
        "-lp",
        "-o",
        str(time_path),
        *glacier_argv,
    ]
    output, wall_seconds, exit_status = _run_process(
        timed_argv, cwd=config.cwd, timeout_seconds=config.timeout_seconds
    )
    common.assert_artifact_identities(artifacts)
    _assert_absent_sidecar(config, sidecar_expected_absent)
    if not prepared_path.is_file():
        raise common.HarnessError("prepare did not create a GLRT image")
    if not time_path.is_file():
        raise common.HarnessError("time did not create a resource record")
    telemetry = parse_prepare_telemetry(
        output,
        expected_source=config.source,
        expected_output=prepared_path,
        expected_source_sha256=str(artifacts["source"]["sha256"]),
    )
    try:
        time_raw = time_path.read_bytes()
        time_text = time_raw.decode("ascii", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise common.HarnessError(f"cannot read time evidence: {error}") from error
    resource_metrics = resource.parse_time_output(time_text)
    for field in _REQUIRED_POSITIVE_RESOURCES:
        if float(resource_metrics[field]) <= 0:
            raise common.HarnessError(f"resource metric must be positive: {field}")
    if telemetry["total_ms"] / 1000.0 > wall_seconds + 1e-9:
        raise common.HarnessError("prepare total timer exceeds harness wall time")
    # /usr/bin/time renders real time to centiseconds; allow one truncation
    # quantum when relating it to the higher-resolution internal total.
    if telemetry["total_ms"] / 1000.0 > resource_metrics["time_real_seconds"] + 0.010:
        raise common.HarnessError("prepare total timer exceeds /usr/bin/time real time")
    prepared = common.fingerprint(prepared_path, "prepared output", None)
    metrics = {
        **telemetry,
        **resource_metrics,
        "harness_wall_seconds": wall_seconds,
    }
    observation = {
        "role": role,
        "glacier_argv": glacier_argv,
        "timed_argv": timed_argv,
        "metrics": metrics,
        "prepared_output": prepared,
        "telemetry_output": output.decode("utf-8", errors="replace"),
        "telemetry_sha256": common.sha256_bytes(output),
        "time_output": time_text,
        "time_output_sha256": common.sha256_bytes(time_raw),
        "exit_status": exit_status,
        "ephemeral_files_removed_after_fingerprint": True,
    }
    try:
        prepared_path.unlink()
        time_path.unlink()
    except OSError as error:
        raise common.HarnessError(
            f"cannot remove fingerprinted observation files: {error}"
        ) from error
    return observation


def _assert_same_output(
    observation: Mapping[str, Any], reference: Mapping[str, Any] | None
) -> Mapping[str, Any]:
    output = observation["prepared_output"]
    if reference is None:
        return output
    if output["bytes"] != reference["bytes"] or output["sha256"] != reference["sha256"]:
        raise common.HarnessError(
            "baseline and candidate prepared images are not byte-identical"
        )
    return reference


def _summaries(samples: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    medians: dict[str, dict[str, float]] = {}
    for role in ROLES:
        role_samples = [item for item in samples if item["role"] == role]
        medians[role] = {
            field: statistics.median(float(item["metrics"][field]) for item in role_samples)
            for field in _MEDIAN_FIELDS
        }
    return medians


def _candidate_workspace_semantics_valid(signature: tuple[int, int, int]) -> bool:
    generated_records, workspace_total, workspace_peak = signature
    return (
        generated_records > 0
        and workspace_peak > 0
        and workspace_total >= workspace_peak
    )


def run_benchmark(config: Config) -> dict[str, Any]:
    if config.warmups_per_role < 0:
        raise common.HarnessError("warmups per role must be non-negative")
    if config.bootstrap_resamples <= 0:
        raise common.HarnessError("bootstrap resamples must be positive")
    if not 0.0 < config.confidence < 1.0:
        raise common.HarnessError("confidence must be between zero and one")
    if config.timeout_seconds <= 0:
        raise common.HarnessError("timeout must be positive")
    patterns = build_patterns(config.samples_per_role, config.schedule_seed)
    strict_time = (
        platform.system() == "Darwin"
        and config.time_binary.resolve() == SYSTEM_TIME_BINARY
        and not config.test_only_allow_non_system_time
    )
    if not strict_time and not config.test_only_allow_non_system_time:
        raise common.HarnessError(
            "publishable prepare resources require macOS /usr/bin/time"
        )

    artifacts_before = _fingerprints(config)
    sidecar_expected_absent = "source_sidecar" not in artifacts_before
    source_sha = str(artifacts_before["source"]["sha256"])
    samples: list[dict[str, Any]] = []
    warmups: list[dict[str, Any]] = []
    reference_output: Mapping[str, Any] | None = None
    with tempfile.TemporaryDirectory(prefix="glacier-prepare-ab-") as raw_temp:
        temporary = Path(raw_temp)
        warmup_rng = random.Random(config.schedule_seed ^ 0x57524D5550)
        for warmup_index in range(config.warmups_per_role):
            order = list(ROLES)
            warmup_rng.shuffle(order)
            for position, role in enumerate(order):
                observation = _observe(
                    config,
                    role,
                    prepared_path=temporary / f"warmup-{warmup_index}-{position}.glrt",
                    time_path=temporary / f"warmup-{warmup_index}-{position}.time",
                    artifacts=artifacts_before,
                    sidecar_expected_absent=sidecar_expected_absent,
                )
                reference_output = _assert_same_output(observation, reference_output)
                observation["warmup_index"] = warmup_index
                observation["position"] = position
                warmups.append(observation)

        sample_index = 0
        for block_index, pattern in enumerate(patterns):
            for position, arm in enumerate(pattern):
                role = "baseline" if arm == "A" else "candidate"
                observation = _observe(
                    config,
                    role,
                    prepared_path=temporary / f"sample-{sample_index}.glrt",
                    time_path=temporary / f"sample-{sample_index}.time",
                    artifacts=artifacts_before,
                    sidecar_expected_absent=sidecar_expected_absent,
                )
                reference_output = _assert_same_output(observation, reference_output)
                observation["sample_index"] = sample_index
                observation["block_index"] = block_index
                observation["position"] = position
                observation["pattern"] = pattern
                samples.append(observation)
                sample_index += 1

    if reference_output is None:
        raise common.HarnessError("prepare A/B produced no output identity")
    provenance = {
        str(item["metrics"]["provenance_sha256"])
        for item in (*warmups, *samples)
    }
    if len(provenance) != 1:
        raise common.HarnessError("prepare provenance changed between observations")
    candidate_workspaces = {
        (
            item["metrics"]["workspace"]["generated_records"],
            item["metrics"]["workspace"]["generated_workspace_bytes_total"],
            item["metrics"]["workspace"]["generated_workspace_bytes_peak"],
        )
        for item in samples
        if item["role"] == "candidate" and item["metrics"]["workspace"] is not None
    }
    candidate_workspace_telemetry_complete = all(
        item["metrics"]["workspace"] is not None
        for item in samples
        if item["role"] == "candidate"
    )
    if candidate_workspace_telemetry_complete and len(candidate_workspaces) != 1:
        raise common.HarnessError("candidate workspace telemetry changed between samples")
    candidate_workspace_semantics_valid = (
        candidate_workspace_telemetry_complete
        and len(candidate_workspaces) == 1
        and _candidate_workspace_semantics_valid(next(iter(candidate_workspaces)))
    )
    artifacts_after = _verify_fingerprints(config, artifacts_before)
    ratios = {
        field: paired_ratio(
            samples,
            field,
            resamples=config.bootstrap_resamples,
            seed=config.bootstrap_seed,
            confidence=config.confidence,
        )
        for field in _RATIO_FIELDS
    }
    binary_growth_percent = (
        artifacts_before["candidate_binary"]["bytes"]
        / artifacts_before["baseline_binary"]["bytes"]
        - 1.0
    ) * 100.0
    gates = {
        "byte_identical_output": True,
        "maximum_rss_ci_low_at_least_1_20": ratios[
            "time_maximum_resident_set_size_bytes"
        ]["ci_low"]
        >= 1.20,
        "total_time_ci_low_at_least_0_95": ratios["total_ms"]["ci_low"] >= 0.95,
        "binary_growth_at_most_2_percent": binary_growth_percent <= 2.0,
        "candidate_workspace_telemetry_complete": candidate_workspace_telemetry_complete,
        "candidate_workspace_semantics_valid": candidate_workspace_semantics_valid,
    }
    gates["pass"] = all(gates.values())
    return {
        "schema": SCHEMA,
        "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "claim_scope": "same-source before/after PairNibble preparation only",
        "cache_regime": "fresh-process/os-warm; source hashed before materialization",
        "measurements_publishable": strict_time,
        "contract": {
            "roles": {
                "baseline": str(config.baseline_binary),
                "candidate": str(config.candidate_binary),
            },
            "source": str(config.source),
            "mlp_layout": "pair-nibble-required",
            "schedule": "balanced ABBA/BAAB blocks",
            "samples_per_role": config.samples_per_role,
            "warmups_per_role": config.warmups_per_role,
            "schedule_seed": config.schedule_seed,
            "bootstrap_seed": config.bootstrap_seed,
            "bootstrap_resamples": config.bootstrap_resamples,
            "confidence": config.confidence,
            "output_equivalence": "complete byte-for-byte SHA-256 and length",
            "ratio_direction": "baseline/candidate; greater than 1 favors candidate",
        },
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "artifacts_before": artifacts_before,
        "artifacts_after": artifacts_after,
        "source_sidecar_contract": {
            "path": str(config.source) + ".json",
            "expected_absent": sidecar_expected_absent,
            "sha256": (
                None
                if sidecar_expected_absent
                else artifacts_before["source_sidecar"]["sha256"]
            ),
        },
        "prepared_output": {
            "bytes": reference_output["bytes"],
            "sha256": reference_output["sha256"],
            "source_sha256": source_sha,
            "provenance_sha256": next(iter(provenance)),
        },
        "candidate_workspace": (
            None
            if not candidate_workspace_telemetry_complete
            else {
                "generated_records": next(iter(candidate_workspaces))[0],
                "generated_workspace_bytes_total": next(iter(candidate_workspaces))[1],
                "generated_workspace_bytes_peak": next(iter(candidate_workspaces))[2],
            }
        ),
        "patterns": patterns,
        "warmups": warmups,
        "samples": samples,
        "medians": _summaries(samples),
        "paired_ratios": ratios,
        "binary_growth_percent": binary_growth_percent,
        "promotion_gate": gates,
    }


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-binary", type=Path, required=True)
    parser.add_argument("--candidate-binary", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--time-binary", type=Path, default=Path("/usr/bin/time"))
    parser.add_argument("--samples-per-role", type=int, default=DEFAULT_SAMPLES_PER_ROLE)
    parser.add_argument("--warmups-per-role", type=int, default=DEFAULT_WARMUPS_PER_ROLE)
    parser.add_argument("--schedule-seed", type=int, default=DEFAULT_SCHEDULE_SEED)
    parser.add_argument("--bootstrap-seed", type=int, default=DEFAULT_BOOTSTRAP_SEED)
    parser.add_argument(
        "--bootstrap-resamples", type=int, default=DEFAULT_BOOTSTRAP_RESAMPLES
    )
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--baseline-sha256")
    parser.add_argument("--candidate-sha256")
    parser.add_argument("--source-sha256")
    parser.add_argument("--sidecar-sha256")
    parser.add_argument("--time-sha256")
    return parser


def _resolve(path: Path, base: Path) -> Path:
    expanded = path.expanduser()
    if not expanded.is_absolute():
        expanded = base / expanded
    return expanded.resolve(strict=False)


def config_from_args(args: argparse.Namespace) -> Config:
    cwd = _resolve(args.cwd, Path.cwd())
    return Config(
        baseline_binary=_resolve(args.baseline_binary, cwd),
        candidate_binary=_resolve(args.candidate_binary, cwd),
        source=_resolve(args.source, cwd),
        output=None if args.output is None else _resolve(args.output, cwd),
        cwd=cwd,
        time_binary=_resolve(args.time_binary, cwd),
        samples_per_role=args.samples_per_role,
        warmups_per_role=args.warmups_per_role,
        schedule_seed=args.schedule_seed,
        bootstrap_seed=args.bootstrap_seed,
        bootstrap_resamples=args.bootstrap_resamples,
        confidence=args.confidence,
        timeout_seconds=args.timeout_seconds,
        overwrite=args.overwrite,
        baseline_sha256=args.baseline_sha256,
        candidate_sha256=args.candidate_sha256,
        source_sha256=args.source_sha256,
        sidecar_sha256=args.sidecar_sha256,
        time_sha256=args.time_sha256,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argument_parser()
    args = parser.parse_args(argv)
    config = config_from_args(args)
    try:
        result = run_benchmark(config)
        resource.write_resource_result(result, config.output, config.overwrite)
    except (common.HarnessError, OSError, ValueError) as error:
        print(f"prepare resource benchmark failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
