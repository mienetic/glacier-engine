#!/usr/bin/env python3
"""Paired end-to-end Glacier/llama.cpp benchmark harness.

The harness intentionally uses only the Python standard library.  It launches a
new process for every observation, leaves the operating-system cache alone, and
balances local machine drift with paired ABBA/BAAB blocks.  It is designed for
macOS because peak RSS is collected from ``/usr/bin/time -l``. Publishable mode
also re-admits machine state before every observation and rejects unmatched or
contaminated engine pairs; it deliberately does not infer CPU temperature.

Run ``python3 bench/paired_abba.py --help`` for the command-line interface.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import random
import re
import signal
import stat
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import ExitStack
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA = "glacier.paired-bench/v1"
CACHE_REGIME = "process-cold/os-warm"
DEFAULT_SAMPLES_PER_ENGINE = 32
DEFAULT_SCHEDULE_SEED = 20_260_719
DEFAULT_BOOTSTRAP_SEED = 0x474C4143494552
DEFAULT_BOOTSTRAP_RESAMPLES = 10_000
MACHINE_STATE_SCHEMA = "glacier.machine-state-admission/v1"
DEFAULT_MACHINE_STATE_WINDOW_SECONDS = 60.0
DEFAULT_MACHINE_STATE_SAMPLE_INTERVAL_SECONDS = 5.0
DEFAULT_IN_RUN_CPU_SAMPLE_INTERVAL_SECONDS = 0.5
DEFAULT_MIN_IN_RUN_CPU_SAMPLES = 3
DEFAULT_MAX_EXTERNAL_CPU_CAPACITY_MEDIAN_PERCENT = 10.0
DEFAULT_MAX_EXTERNAL_CPU_CAPACITY_SAMPLE_PERCENT = 20.0
DEFAULT_MAX_MATCHED_EXTERNAL_CPU_CAPACITY_MEDIAN_DELTA = 5.0
DEFAULT_MAX_MATCHED_EXTERNAL_CPU_CAPACITY_MAX_DELTA = 10.0
ENGINE_NAMES = ("glacier", "llama")
TOKENIZER_NAMES = ("hf", "llama")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
CRITICAL_FILE_SUFFIXES = frozenset(
    {
        ".bin",
        ".dylib",
        ".gguf",
        ".glacier",
        ".ids",
        ".json",
        ".metal",
        ".mlmodel",
        ".model",
        ".onnx",
        ".pt",
        ".pth",
        ".py",
        ".safetensors",
        ".so",
        ".tflite",
        ".txt",
    }
)
INHERITED_ENV_ALLOWLIST = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TZ")
PERFORMANCE_ENV_PREFIXES = (
    "LLAMA_ARG_",
    "GGML",
    "OMP",
    "VECLIB",
    "DYLD_",
    "LD_",
)
SENSITIVE_ENV_NAME_PARTS = (
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "API_KEY",
    "CREDENTIAL",
    "AUTH",
)


class HarnessError(RuntimeError):
    """A manifest or execution error that makes the comparison invalid."""


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _mapping(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HarnessError(f"{where} must be an object")
    if not all(isinstance(key, str) for key in value):
        raise HarnessError(f"{where} keys must be strings")
    return value


def _reject_unknown(obj: Mapping[str, Any], allowed: Iterable[str], where: str) -> None:
    unknown = sorted(set(obj) - set(allowed))
    if unknown:
        raise HarnessError(f"{where} has unknown field(s): {', '.join(unknown)}")


def _required(obj: Mapping[str, Any], key: str, where: str) -> Any:
    if key not in obj:
        raise HarnessError(f"{where}.{key} is required")
    return obj[key]


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise HarnessError(f"{where} must be a non-empty string")
    if "\x00" in value:
        raise HarnessError(f"{where} must not contain NUL")
    return value


def _boolean(value: Any, where: str) -> bool:
    if not isinstance(value, bool):
        raise HarnessError(f"{where} must be a boolean")
    return value


def _integer(value: Any, where: str, minimum: int, maximum: int) -> int:
    if not _is_int(value) or not minimum <= value <= maximum:
        raise HarnessError(f"{where} must be an integer in [{minimum}, {maximum}]")
    return value


def _number(value: Any, where: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise HarnessError(f"{where} must be a number")
    result = float(value)
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise HarnessError(f"{where} must be finite and in [{minimum}, {maximum}]")
    return result


def _validate_machine_state(value: Any) -> dict[str, Any]:
    """Validate the fail-closed machine-state policy for timed comparisons."""

    obj = _mapping(value, "manifest.machine_state")
    allowed = {
        "mode",
        "window_seconds",
        "sample_interval_seconds",
        "max_load1",
        "min_cpu_idle_median_percent",
        "min_cpu_idle_sample_percent",
        "max_matched_load1_delta",
        "max_matched_cpu_idle_median_delta",
        "in_run_cpu_sample_interval_seconds",
        "min_in_run_cpu_samples",
        "max_external_cpu_capacity_median_percent",
        "max_external_cpu_capacity_sample_percent",
        "max_matched_external_cpu_capacity_median_delta",
        "max_matched_external_cpu_capacity_max_delta",
    }
    _reject_unknown(obj, allowed, "manifest.machine_state")
    mode = _string(obj.get("mode", "publishable"), "manifest.machine_state.mode")
    if mode not in ("publishable", "disabled"):
        raise HarnessError(
            "manifest.machine_state.mode must be 'publishable' or 'disabled'"
        )
    if mode == "disabled":
        extra = sorted(set(obj) - {"mode"})
        if extra:
            raise HarnessError(
                "disabled manifest.machine_state may contain only mode; "
                f"unexpected: {', '.join(extra)}"
            )
        return {"mode": "disabled", "publication_eligible": False}

    window = _number(
        obj.get("window_seconds", DEFAULT_MACHINE_STATE_WINDOW_SECONDS),
        "manifest.machine_state.window_seconds",
        60.0,
        600.0,
    )
    interval = _number(
        obj.get(
            "sample_interval_seconds", DEFAULT_MACHINE_STATE_SAMPLE_INTERVAL_SECONDS
        ),
        "manifest.machine_state.sample_interval_seconds",
        1.0,
        5.0,
    )
    if not interval.is_integer():
        raise HarnessError(
            "manifest.machine_state.sample_interval_seconds must be a whole "
            "number supported by macOS top"
        )
    if interval > window:
        raise HarnessError(
            "manifest.machine_state.sample_interval_seconds must not exceed window_seconds"
        )
    return {
        "mode": "publishable",
        "publication_eligible": True,
        "window_seconds": window,
        "sample_interval_seconds": interval,
        "max_load1": _number(
            obj.get("max_load1", 1.0),
            "manifest.machine_state.max_load1",
            0.0,
            1.0,
        ),
        "min_cpu_idle_median_percent": _number(
            obj.get("min_cpu_idle_median_percent", 90.0),
            "manifest.machine_state.min_cpu_idle_median_percent",
            90.0,
            100.0,
        ),
        "min_cpu_idle_sample_percent": _number(
            obj.get("min_cpu_idle_sample_percent", 80.0),
            "manifest.machine_state.min_cpu_idle_sample_percent",
            80.0,
            100.0,
        ),
        "max_matched_load1_delta": _number(
            obj.get("max_matched_load1_delta", 0.25),
            "manifest.machine_state.max_matched_load1_delta",
            0.0,
            0.25,
        ),
        "max_matched_cpu_idle_median_delta": _number(
            obj.get("max_matched_cpu_idle_median_delta", 5.0),
            "manifest.machine_state.max_matched_cpu_idle_median_delta",
            0.0,
            5.0,
        ),
        "in_run_cpu_sample_interval_seconds": _number(
            obj.get(
                "in_run_cpu_sample_interval_seconds",
                DEFAULT_IN_RUN_CPU_SAMPLE_INTERVAL_SECONDS,
            ),
            "manifest.machine_state.in_run_cpu_sample_interval_seconds",
            0.25,
            DEFAULT_IN_RUN_CPU_SAMPLE_INTERVAL_SECONDS,
        ),
        "min_in_run_cpu_samples": _integer(
            obj.get("min_in_run_cpu_samples", DEFAULT_MIN_IN_RUN_CPU_SAMPLES),
            "manifest.machine_state.min_in_run_cpu_samples",
            DEFAULT_MIN_IN_RUN_CPU_SAMPLES,
            10_000,
        ),
        "max_external_cpu_capacity_median_percent": _number(
            obj.get(
                "max_external_cpu_capacity_median_percent",
                DEFAULT_MAX_EXTERNAL_CPU_CAPACITY_MEDIAN_PERCENT,
            ),
            "manifest.machine_state.max_external_cpu_capacity_median_percent",
            0.0,
            DEFAULT_MAX_EXTERNAL_CPU_CAPACITY_MEDIAN_PERCENT,
        ),
        "max_external_cpu_capacity_sample_percent": _number(
            obj.get(
                "max_external_cpu_capacity_sample_percent",
                DEFAULT_MAX_EXTERNAL_CPU_CAPACITY_SAMPLE_PERCENT,
            ),
            "manifest.machine_state.max_external_cpu_capacity_sample_percent",
            0.0,
            DEFAULT_MAX_EXTERNAL_CPU_CAPACITY_SAMPLE_PERCENT,
        ),
        "max_matched_external_cpu_capacity_median_delta": _number(
            obj.get(
                "max_matched_external_cpu_capacity_median_delta",
                DEFAULT_MAX_MATCHED_EXTERNAL_CPU_CAPACITY_MEDIAN_DELTA,
            ),
            "manifest.machine_state.max_matched_external_cpu_capacity_median_delta",
            0.0,
            DEFAULT_MAX_MATCHED_EXTERNAL_CPU_CAPACITY_MEDIAN_DELTA,
        ),
        "max_matched_external_cpu_capacity_max_delta": _number(
            obj.get(
                "max_matched_external_cpu_capacity_max_delta",
                DEFAULT_MAX_MATCHED_EXTERNAL_CPU_CAPACITY_MAX_DELTA,
            ),
            "manifest.machine_state.max_matched_external_cpu_capacity_max_delta",
            0.0,
            DEFAULT_MAX_MATCHED_EXTERNAL_CPU_CAPACITY_MAX_DELTA,
        ),
        "requirements": {
            "ac_power": True,
            "battery_full_if_present": True,
            "low_power_mode_off": True,
            "thermal_unconstrained_if_signal_available": True,
            "zero_pageout_swapin_swapout_delta": True,
            "per_observation_readmission": True,
            "adjacent_cross_engine_state_matching": True,
            "in_run_external_cpu_monitor": True,
        },
    }


def _sha_pin(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if SHA256_RE.fullmatch(result) is None:
        raise HarnessError(f"{where} must be a 64-character SHA-256 hex digest")
    return result


def _json_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise HarnessError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise HarnessError(f"non-finite JSON number is not allowed: {value}")


def _resolve_path(value: str, base: Path) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = base / path
    return path.resolve(strict=False)


def _validate_argv(value: Any, where: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise HarnessError(f"{where} must be a non-empty array")
    return [_string(item, f"{where}[{index}]") for index, item in enumerate(value)]


def _validate_env(value: Any, where: str) -> dict[str, str]:
    if value is None:
        return {}
    obj = _mapping(value, where)
    result: dict[str, str] = {}
    for key, item in obj.items():
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise HarnessError(f"{where} has invalid environment name: {key!r}")
        if any(part in key.upper() for part in SENSITIVE_ENV_NAME_PARTS):
            raise HarnessError(
                f"{where}.{key} looks sensitive; secrets are forbidden in benchmark manifests"
            )
        if key not in INHERITED_ENV_ALLOWLIST and not key.startswith(
            PERFORMANCE_ENV_PREFIXES
        ):
            raise HarnessError(
                f"{where}.{key} is not an allowed reproducibility/performance variable; "
                "secrets and arbitrary environment values are forbidden in benchmark manifests"
            )
        result[key] = _string(item, f"{where}.{key}")
    return result


def _validate_common_command(value: Any, where: str) -> dict[str, Any]:
    obj = _mapping(value, where)
    result: dict[str, Any] = {
        "argv": _validate_argv(_required(obj, "argv", where), f"{where}.argv"),
        "cwd": _string(obj.get("cwd", "{repo_root}"), f"{where}.cwd"),
        "env": _validate_env(obj.get("env"), f"{where}.env"),
        "stdin": obj.get("stdin", "none"),
        "timeout_seconds": _number(
            obj.get("timeout_seconds", 3600),
            f"{where}.timeout_seconds",
            0.001,
            86_400,
        ),
    }
    if result["stdin"] not in ("none", "canonical_text"):
        raise HarnessError(f"{where}.stdin must be 'none' or 'canonical_text'")
    return result


def _validate_tokenizer_command(value: Any, where: str) -> dict[str, Any]:
    obj = _mapping(value, where)
    _reject_unknown(
        obj,
        {"argv", "cwd", "env", "stdin", "timeout_seconds", "ids_format", "ids_stream"},
        where,
    )
    result = _validate_common_command(obj, where)
    result["ids_format"] = _string(
        _required(obj, "ids_format", where), f"{where}.ids_format"
    )
    result["ids_stream"] = _string(
        obj.get("ids_stream", "stdout"), f"{where}.ids_stream"
    )
    if result["ids_format"] not in ("plain", "json-array"):
        raise HarnessError(f"{where}.ids_format must be 'plain' or 'json-array'")
    if result["ids_stream"] not in ("stdout", "stderr"):
        raise HarnessError(f"{where}.ids_stream must be 'stdout' or 'stderr'")
    return result


def _validate_id_extractor(value: Any, where: str) -> dict[str, Any]:
    obj = _mapping(value, where)
    _reject_unknown(
        obj,
        {"argv", "cwd", "env", "timeout_seconds", "ids_format", "ids_stream"},
        where,
    )
    result = _validate_common_command(obj, where)
    result.pop("stdin")
    result["ids_format"] = _string(
        _required(obj, "ids_format", where), f"{where}.ids_format"
    )
    result["ids_stream"] = _string(
        obj.get("ids_stream", "stdout"), f"{where}.ids_stream"
    )
    if result["ids_format"] not in ("plain", "json-array"):
        raise HarnessError(f"{where}.ids_format must be 'plain' or 'json-array'")
    if result["ids_stream"] not in ("stdout", "stderr"):
        raise HarnessError(f"{where}.ids_stream must be 'stdout' or 'stderr'")
    return result


def _validate_completion(value: Any, where: str) -> dict[str, Any]:
    obj = _mapping(value, where)
    _reject_unknown(
        obj,
        {
            "source",
            "path",
            "format",
            "ids_format",
            "strip_exactly_one_final_lf",
            "token_id_extractor",
        },
        where,
    )
    source = _string(_required(obj, "source", where), f"{where}.source")
    output_format = _string(_required(obj, "format", where), f"{where}.format")
    if source not in ("stdout", "stderr", "file"):
        raise HarnessError(f"{where}.source must be 'stdout', 'stderr', or 'file'")
    if output_format not in ("raw", "token_ids"):
        raise HarnessError(f"{where}.format must be 'raw' or 'token_ids'")
    result: dict[str, Any] = {"source": source, "format": output_format}
    if source == "file":
        result["path"] = _string(_required(obj, "path", where), f"{where}.path")
    elif "path" in obj:
        raise HarnessError(f"{where}.path is only valid when source is 'file'")
    if output_format == "token_ids":
        result["ids_format"] = _string(
            _required(obj, "ids_format", where), f"{where}.ids_format"
        )
        if result["ids_format"] not in ("plain", "json-array"):
            raise HarnessError(f"{where}.ids_format must be 'plain' or 'json-array'")
        if "token_id_extractor" in obj or "strip_exactly_one_final_lf" in obj:
            raise HarnessError(
                f"{where} token_ids output must not declare a text token_id_extractor or LF transform"
            )
    else:
        if "ids_format" in obj:
            raise HarnessError(f"{where}.ids_format is only valid for token_ids output")
        result["strip_exactly_one_final_lf"] = _boolean(
            _required(obj, "strip_exactly_one_final_lf", where),
            f"{where}.strip_exactly_one_final_lf",
        )
        result["token_id_extractor"] = _validate_id_extractor(
            _required(obj, "token_id_extractor", where), f"{where}.token_id_extractor"
        )
    return result


def _validate_engine_command(value: Any, where: str) -> dict[str, Any]:
    obj = _mapping(value, where)
    _reject_unknown(
        obj,
        {
            "argv",
            "cwd",
            "env",
            "stdin",
            "timeout_seconds",
            "completion",
            "require_stable_completion_hash",
        },
        where,
    )
    result = _validate_common_command(obj, where)
    result["completion"] = _validate_completion(
        _required(obj, "completion", where), f"{where}.completion"
    )
    result["require_stable_completion_hash"] = _boolean(
        obj.get("require_stable_completion_hash", True),
        f"{where}.require_stable_completion_hash",
    )
    if not result["require_stable_completion_hash"]:
        raise HarnessError(f"{where}.require_stable_completion_hash must be true")
    return result


def load_manifest(path: Path) -> dict[str, Any]:
    """Load, strictly validate, and resolve a v1 manifest."""

    manifest_path = path.expanduser().resolve(strict=True)
    try:
        raw = json.loads(
            manifest_path.read_text(encoding="utf-8"),
            object_pairs_hook=_json_no_duplicates,
            parse_constant=_reject_json_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot read manifest {manifest_path}: {exc}") from exc
    obj = _mapping(raw, "manifest")
    _reject_unknown(
        obj,
        {
            "schema",
            "name",
            "repo_root",
            "cache_regime",
            "samples_per_engine",
            "warmup_runs_per_engine",
            "schedule_seed",
            "workload",
            "artifacts",
            "tokenizer_preflight",
            "engines",
            "machine_state",
            "statistics",
            "metadata",
        },
        "manifest",
    )
    if _required(obj, "schema", "manifest") != SCHEMA:
        raise HarnessError(f"manifest.schema must be {SCHEMA!r}")

    manifest_dir = manifest_path.parent
    repo_root = _resolve_path(
        _string(obj.get("repo_root", ".."), "manifest.repo_root"), manifest_dir
    )
    name = _string(_required(obj, "name", "manifest"), "manifest.name")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) is None:
        raise HarnessError(
            "manifest.name may contain only letters, digits, '.', '_', and '-'"
        )
    cache_regime = obj.get("cache_regime", CACHE_REGIME)
    if cache_regime != CACHE_REGIME:
        raise HarnessError(
            f"manifest.cache_regime must be {CACHE_REGIME!r}; this harness never drops OS caches"
        )
    samples = _integer(
        obj.get("samples_per_engine", DEFAULT_SAMPLES_PER_ENGINE),
        "manifest.samples_per_engine",
        4,
        10_000,
    )
    if samples % 4 != 0:
        raise HarnessError(
            "manifest.samples_per_engine must be divisible by 4 so ABBA and BAAB blocks are balanced"
        )
    warmups = _integer(
        obj.get("warmup_runs_per_engine", 1),
        "manifest.warmup_runs_per_engine",
        1,
        100,
    )
    schedule_seed = _integer(
        obj.get("schedule_seed", DEFAULT_SCHEDULE_SEED),
        "manifest.schedule_seed",
        0,
        (1 << 63) - 1,
    )
    machine_state = _validate_machine_state(
        obj.get("machine_state", {"mode": "publishable"})
    )
    if machine_state["mode"] == "publishable" and samples < 32:
        raise HarnessError(
            "publishable machine-state mode requires samples_per_engine >= 32 "
            "for at least eight ABBA and eight BAAB blocks"
        )

    workload = _mapping(_required(obj, "workload", "manifest"), "manifest.workload")
    _reject_unknown(
        workload,
        {
            "canonical_text",
            "pinned_token_ids",
            "completion_tokens",
            "completion_equivalence",
            "glacier_prefill_mode",
            "require_fused_gqa",
        },
        "manifest.workload",
    )
    completion_equivalence = _string(
        _required(workload, "completion_equivalence", "manifest.workload"),
        "manifest.workload.completion_equivalence",
    )
    if completion_equivalence not in ("stable-only", "exact-token-ids"):
        raise HarnessError(
            "manifest.workload.completion_equivalence must be 'stable-only' or 'exact-token-ids'"
        )
    glacier_prefill_mode = _string(
        _required(workload, "glacier_prefill_mode", "manifest.workload"),
        "manifest.workload.glacier_prefill_mode",
    )
    if glacier_prefill_mode not in ("batch", "serial"):
        raise HarnessError(
            "manifest.workload.glacier_prefill_mode must be 'batch' or 'serial'"
        )
    require_fused_gqa = _boolean(
        workload.get("require_fused_gqa", False),
        "manifest.workload.require_fused_gqa",
    )
    text_cfg = _mapping(
        _required(workload, "canonical_text", "manifest.workload"),
        "manifest.workload.canonical_text",
    )
    _reject_unknown(
        text_cfg,
        {"path", "strip_exactly_one_final_lf", "source_sha256", "canonical_sha256"},
        "manifest.workload.canonical_text",
    )
    ids_cfg = _mapping(
        _required(workload, "pinned_token_ids", "manifest.workload"),
        "manifest.workload.pinned_token_ids",
    )
    _reject_unknown(
        ids_cfg, {"path", "format", "sha256"}, "manifest.workload.pinned_token_ids"
    )
    ids_format = _string(
        ids_cfg.get("format", "plain"), "manifest.workload.pinned_token_ids.format"
    )
    if ids_format not in ("plain", "json-array"):
        raise HarnessError(
            "manifest.workload.pinned_token_ids.format must be 'plain' or 'json-array'"
        )

    artifacts_obj = _mapping(obj.get("artifacts", {}), "manifest.artifacts")
    artifacts: dict[str, dict[str, Any]] = {}
    reserved = {
        "manifest_dir",
        "repo_root",
        "canonical_text_path",
        "pinned_token_ids_path",
        "sample_dir",
        "engine",
        "sample_index",
    }
    for key, item in artifacts_obj.items():
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) is None or key in reserved:
            raise HarnessError(
                f"manifest.artifacts has invalid or reserved name: {key!r}"
            )
        artifact = _mapping(item, f"manifest.artifacts.{key}")
        _reject_unknown(
            artifact, {"path", "kind", "sha256"}, f"manifest.artifacts.{key}"
        )
        kind = _string(
            _required(artifact, "kind", f"manifest.artifacts.{key}"),
            f"manifest.artifacts.{key}.kind",
        )
        if kind not in ("executable", "model", "tokenizer", "file"):
            raise HarnessError(
                f"manifest.artifacts.{key}.kind must be executable, model, tokenizer, or file"
            )
        expected_sha = artifact.get("sha256")
        artifacts[key] = {
            "path": str(
                _resolve_path(
                    _string(
                        _required(artifact, "path", f"manifest.artifacts.{key}"),
                        f"manifest.artifacts.{key}.path",
                    ),
                    manifest_dir,
                )
            ),
            "kind": kind,
            "expected_sha256": _sha_pin(
                expected_sha, f"manifest.artifacts.{key}.sha256"
            )
            if expected_sha is not None
            else None,
        }

    preflight_obj = _mapping(
        _required(obj, "tokenizer_preflight", "manifest"),
        "manifest.tokenizer_preflight",
    )
    _reject_unknown(preflight_obj, set(TOKENIZER_NAMES), "manifest.tokenizer_preflight")
    preflight = {
        name_: _validate_tokenizer_command(
            _required(preflight_obj, name_, "manifest.tokenizer_preflight"),
            f"manifest.tokenizer_preflight.{name_}",
        )
        for name_ in TOKENIZER_NAMES
    }

    engines_obj = _mapping(_required(obj, "engines", "manifest"), "manifest.engines")
    _reject_unknown(engines_obj, set(ENGINE_NAMES), "manifest.engines")
    engines = {
        name_: _validate_engine_command(
            _required(engines_obj, name_, "manifest.engines"),
            f"manifest.engines.{name_}",
        )
        for name_ in ENGINE_NAMES
    }
    glacier_argv = engines["glacier"]["argv"]
    if require_fused_gqa and "--require-prepared-image" not in glacier_argv:
        raise HarnessError(
            "manifest.workload.require_fused_gqa requires --require-prepared-image"
        )
    if "--require-prepared-image" in glacier_argv:
        serial_attention_flags = glacier_argv.count("--serial-attention")
        parallel_attention_flags = glacier_argv.count(
            "--parallel-attention-min-context"
        )
        if serial_attention_flags + parallel_attention_flags != 1:
            raise HarnessError(
                "strict prepared Glacier manifests must declare exactly one "
                "--serial-attention or --parallel-attention-min-context policy"
            )
        if require_fused_gqa and parallel_attention_flags != 1:
            raise HarnessError(
                "manifest.workload.require_fused_gqa requires "
                "--parallel-attention-min-context"
            )
        if parallel_attention_flags == 1:
            flag_index = glacier_argv.index("--parallel-attention-min-context")
            if flag_index + 1 >= len(glacier_argv):
                raise HarnessError(
                    "--parallel-attention-min-context requires a positive integer"
                )
            try:
                attention_threshold = int(glacier_argv[flag_index + 1])
            except ValueError as error:
                raise HarnessError(
                    "--parallel-attention-min-context requires a positive integer"
                ) from error
            if attention_threshold <= 0:
                raise HarnessError(
                    "--parallel-attention-min-context requires a positive integer"
                )
    if completion_equivalence == "exact-token-ids":
        extracted = [
            name_
            for name_ in ENGINE_NAMES
            if engines[name_]["completion"]["format"] != "token_ids"
        ]
        if extracted:
            raise HarnessError(
                "exact-token-ids mode requires native token_ids completion output "
                "from both engines; decoded text cannot prove the engine's actual "
                "token sequence (raw extractor used by: " + ", ".join(extracted) + ")"
            )

    statistics_obj = _mapping(obj.get("statistics", {}), "manifest.statistics")
    _reject_unknown(
        statistics_obj,
        {"bootstrap_resamples", "bootstrap_seed", "confidence"},
        "manifest.statistics",
    )
    statistics_cfg = {
        "bootstrap_resamples": _integer(
            statistics_obj.get("bootstrap_resamples", DEFAULT_BOOTSTRAP_RESAMPLES),
            "manifest.statistics.bootstrap_resamples",
            100,
            1_000_000,
        ),
        "bootstrap_seed": _integer(
            statistics_obj.get("bootstrap_seed", DEFAULT_BOOTSTRAP_SEED),
            "manifest.statistics.bootstrap_seed",
            0,
            (1 << 63) - 1,
        ),
        "confidence": _number(
            statistics_obj.get("confidence", 0.95),
            "manifest.statistics.confidence",
            0.5,
            0.999,
        ),
    }
    if "metadata" in obj:
        _mapping(obj["metadata"], "manifest.metadata")

    source_sha = text_cfg.get("source_sha256")
    canonical_sha = text_cfg.get("canonical_sha256")
    ids_sha = ids_cfg.get("sha256")
    resolved = {
        "raw_manifest": raw,
        "manifest_path": str(manifest_path),
        "manifest_dir": str(manifest_dir),
        "repo_root": str(repo_root),
        "name": name,
        "cache_regime": cache_regime,
        "samples_per_engine": samples,
        "warmup_runs_per_engine": warmups,
        "schedule_seed": schedule_seed,
        "workload": {
            "canonical_text": {
                "path": str(
                    _resolve_path(
                        _string(
                            _required(
                                text_cfg, "path", "manifest.workload.canonical_text"
                            ),
                            "manifest.workload.canonical_text.path",
                        ),
                        manifest_dir,
                    )
                ),
                "strip_exactly_one_final_lf": _boolean(
                    text_cfg.get("strip_exactly_one_final_lf", False),
                    "manifest.workload.canonical_text.strip_exactly_one_final_lf",
                ),
                "source_sha256": _sha_pin(
                    source_sha, "manifest.workload.canonical_text.source_sha256"
                )
                if source_sha is not None
                else None,
                "canonical_sha256": _sha_pin(
                    canonical_sha, "manifest.workload.canonical_text.canonical_sha256"
                )
                if canonical_sha is not None
                else None,
            },
            "pinned_token_ids": {
                "path": str(
                    _resolve_path(
                        _string(
                            _required(
                                ids_cfg, "path", "manifest.workload.pinned_token_ids"
                            ),
                            "manifest.workload.pinned_token_ids.path",
                        ),
                        manifest_dir,
                    )
                ),
                "format": ids_format,
                "sha256": _sha_pin(ids_sha, "manifest.workload.pinned_token_ids.sha256")
                if ids_sha is not None
                else None,
            },
            "completion_tokens": _integer(
                _required(workload, "completion_tokens", "manifest.workload"),
                "manifest.workload.completion_tokens",
                1,
                1_000_000,
            ),
            "completion_equivalence": completion_equivalence,
            "glacier_prefill_mode": glacier_prefill_mode,
            "require_fused_gqa": require_fused_gqa,
        },
        "artifacts": artifacts,
        "tokenizer_preflight": preflight,
        "engines": engines,
        "machine_state": machine_state,
        "statistics": statistics_cfg,
        "metadata": obj.get("metadata", {}),
    }
    _validate_placeholders(resolved)
    _validate_publishable_artifact_bindings(resolved)
    return resolved


def _all_command_strings(config: Mapping[str, Any]) -> Iterable[tuple[str, str]]:
    for section in ("tokenizer_preflight", "engines"):
        for engine, command in config[section].items():
            prefix = f"manifest.{section}.{engine}"
            for index, arg in enumerate(command["argv"]):
                yield f"{prefix}.argv[{index}]", arg
            yield f"{prefix}.cwd", command["cwd"]
            for key, value in command["env"].items():
                yield f"{prefix}.env.{key}", value
            completion = command.get("completion")
            if completion is not None and "path" in completion:
                yield f"{prefix}.completion.path", completion["path"]
            extractor = completion.get("token_id_extractor") if completion else None
            if extractor is not None:
                for index, arg in enumerate(extractor["argv"]):
                    yield f"{prefix}.completion.token_id_extractor.argv[{index}]", arg
                yield f"{prefix}.completion.token_id_extractor.cwd", extractor["cwd"]
                for key, value in extractor["env"].items():
                    yield f"{prefix}.completion.token_id_extractor.env.{key}", value


def _validate_placeholders(config: Mapping[str, Any]) -> None:
    allowed = {
        "manifest_dir",
        "repo_root",
        "canonical_text_path",
        "pinned_token_ids_path",
        "sample_dir",
        "engine",
        "sample_index",
        *config["artifacts"].keys(),
    }
    for where, value in _all_command_strings(config):
        for match in PLACEHOLDER_RE.finditer(value):
            if match.group(1) not in allowed:
                raise HarnessError(
                    f"{where} uses unknown placeholder {{{match.group(1)}}}"
                )


def _exact_placeholder(value: str) -> str | None:
    match = PLACEHOLDER_RE.fullmatch(value)
    return match.group(1) if match is not None else None


def _is_confined_sample_output(value: str) -> bool:
    prefix = "{sample_dir}/"
    if not value.startswith(prefix) or PLACEHOLDER_RE.findall(value) != ["sample_dir"]:
        return False
    remainder = value[len(prefix) :]
    return bool(remainder) and all(
        part not in ("", ".", "..") for part in remainder.split("/")
    )


def _looks_like_critical_file_operand(
    value: str, command: Mapping[str, Any], config: Mapping[str, Any]
) -> bool:
    """Conservatively identify literal path operands that bypass artifact hashing."""

    candidate = value
    if candidate.startswith("-") and "=" in candidate:
        candidate = candidate.split("=", 1)[1]
    if not candidate:
        return False
    if (
        "/" in candidate
        or "\\" in candidate
        or candidate.startswith((".", "~"))
        or Path(candidate).suffix.lower() in CRITICAL_FILE_SUFFIXES
    ):
        return True
    if PLACEHOLDER_RE.search(candidate) is not None:
        return False

    cwd = command["cwd"]
    base: Path | None = None
    if cwd == "{repo_root}":
        base = Path(config["repo_root"])
    elif cwd == "{manifest_dir}":
        base = Path(config["manifest_dir"])
    elif Path(cwd).is_absolute() and PLACEHOLDER_RE.search(cwd) is None:
        base = Path(cwd)
    if base is None or candidate.startswith("-"):
        return False
    try:
        return (base / candidate).is_file()
    except OSError:
        return True


def _validate_publishable_file_operand(
    value: str,
    where: str,
    command: Mapping[str, Any],
    config: Mapping[str, Any],
    *,
    allow_sample_output: bool,
) -> None:
    """Require a file-valued command token to name one exact, hashed object."""

    placeholder = _exact_placeholder(value)
    if placeholder in config["artifacts"]:
        return
    if placeholder in ("canonical_text_path", "pinned_token_ids_path"):
        return
    if allow_sample_output and _is_confined_sample_output(value):
        return

    artifact_references = [
        name for name in PLACEHOLDER_RE.findall(value) if name in config["artifacts"]
    ]
    fixture_references = [
        name
        for name in PLACEHOLDER_RE.findall(value)
        if name in ("canonical_text_path", "pinned_token_ids_path")
    ]
    if artifact_references or fixture_references:
        raise HarnessError(
            f"{where} must use a fingerprinted file placeholder as the entire operand"
        )
    if _looks_like_critical_file_operand(value, command, config):
        raise HarnessError(
            f"{where} is an unbound critical file operand; declare it in "
            "manifest.artifacts and use its placeholder"
        )


def _validate_publishable_command_artifact_bindings(
    command: Mapping[str, Any], where: str, config: Mapping[str, Any]
) -> None:
    executable = _exact_placeholder(command["argv"][0])
    if executable not in config["artifacts"]:
        raise HarnessError(
            f"{where}.argv[0] must be exactly one declared artifact placeholder"
        )
    if config["artifacts"][executable]["kind"] != "executable":
        raise HarnessError(
            f"{where}.argv[0] artifact {{{executable}}} must have kind 'executable'"
        )

    for index, argument in enumerate(command["argv"][1:], start=1):
        _validate_publishable_file_operand(
            argument,
            f"{where}.argv[{index}]",
            command,
            config,
            allow_sample_output=True,
        )
    for name, value in command["env"].items():
        _validate_publishable_file_operand(
            value,
            f"{where}.env.{name}",
            command,
            config,
            allow_sample_output=False,
        )


def _validate_publishable_artifact_bindings(config: Mapping[str, Any]) -> None:
    """Fail closed unless publishable commands execute only fingerprinted artifacts."""

    if config["machine_state"]["mode"] != "publishable":
        return
    for name, command in config["tokenizer_preflight"].items():
        _validate_publishable_command_artifact_bindings(
            command, f"manifest.tokenizer_preflight.{name}", config
        )
    for name, command in config["engines"].items():
        where = f"manifest.engines.{name}"
        _validate_publishable_command_artifact_bindings(command, where, config)
        completion = command["completion"]
        if completion.get("source") == "file" and not _is_confined_sample_output(
            completion["path"]
        ):
            raise HarnessError(
                f"{where}.completion.path must be confined below {{sample_dir}}"
            )
        extractor = completion.get("token_id_extractor")
        if extractor is not None:
            _validate_publishable_command_artifact_bindings(
                extractor, f"{where}.completion.token_id_extractor", config
            )


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _file_identity(path: Path, description: str) -> dict[str, int]:
    try:
        item = path.stat()
    except OSError as exc:
        raise HarnessError(f"cannot stat {description} at {path}: {exc}") from exc
    if not stat.S_ISREG(item.st_mode):
        raise HarnessError(f"{description} is not a regular file: {path}")
    return {
        "device": item.st_dev,
        "inode": item.st_ino,
        "bytes": item.st_size,
        "mode": stat.S_IMODE(item.st_mode),
        "mtime_ns": item.st_mtime_ns,
        "ctime_ns": item.st_ctime_ns,
    }


def _hash_file(path: Path, description: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    byte_count = 0
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                byte_count += len(chunk)
    except OSError as exc:
        raise HarnessError(f"cannot hash {description} at {path}: {exc}") from exc
    return digest.hexdigest(), byte_count


def fingerprint_artifacts(config: Mapping[str, Any]) -> dict[str, Any]:
    """Hash artifacts and bind each digest to a stable filesystem identity."""

    results: dict[str, Any] = {}
    for name, declaration in config["artifacts"].items():
        path = Path(declaration["path"])
        before = _file_identity(path, f"artifact {name}")
        if declaration["kind"] == "executable" and not os.access(path, os.X_OK):
            raise HarnessError(f"artifact {name} is not executable: {path}")
        started = time.perf_counter_ns()
        actual, byte_count = _hash_file(path, f"artifact {name}")
        after = _file_identity(path, f"artifact {name}")
        if before != after or byte_count != after["bytes"]:
            raise HarnessError(
                f"artifact {name} changed while it was being fingerprinted"
            )
        expected = declaration["expected_sha256"]
        if expected is not None and actual != expected:
            raise HarnessError(
                f"artifact {name} SHA-256 mismatch: expected {expected}, got {actual}"
            )
        results[name] = {
            "path": str(path),
            "kind": declaration["kind"],
            "bytes": byte_count,
            "sha256": actual,
            "identity": after,
            "expected_sha256": expected,
            "expected_sha256_matches": expected is None or actual == expected,
            "fingerprint_seconds": (time.perf_counter_ns() - started) / 1e9,
        }
    return results


def verify_artifacts_unchanged(
    config: Mapping[str, Any],
    fingerprints: Mapping[str, Any],
    phase: str,
    *,
    full_hash: bool,
) -> dict[str, Any]:
    """Reject artifact replacement/mutation after the initial fingerprint."""

    checked: dict[str, Any] = {}
    for name, declaration in config["artifacts"].items():
        if name not in fingerprints:
            raise HarnessError(f"{phase}: artifact {name} has no initial fingerprint")
        path = Path(declaration["path"])
        expected = fingerprints[name]
        before = _file_identity(path, f"artifact {name}")
        if before != expected["identity"]:
            raise HarnessError(f"{phase}: artifact {name} filesystem identity changed")
        item: dict[str, Any] = {"identity": before, "full_hash_checked": full_hash}
        if full_hash:
            digest, byte_count = _hash_file(path, f"artifact {name}")
            after = _file_identity(path, f"artifact {name}")
            if before != after:
                raise HarnessError(
                    f"{phase}: artifact {name} changed during post-run hashing"
                )
            if byte_count != expected["bytes"] or digest != expected["sha256"]:
                raise HarnessError(f"{phase}: artifact {name} content changed")
            item.update({"bytes": byte_count, "sha256": digest})
        checked[name] = item
    return {"phase": phase, "full_hash_checked": full_hash, "artifacts": checked}


def materialize_runtime_fixtures(
    work_dir: Path, canonical: bytes, pinned_ids: Sequence[int]
) -> tuple[Path, Path, dict[str, Any]]:
    """Write fixtures in a dedicated read-only directory and bind identities."""

    fixture_dir = work_dir / "runtime-fixtures"
    fixture_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
    canonical_path = fixture_dir / "canonical.txt"
    pinned_path = fixture_dir / "pinned-token-ids.txt"
    normalized_ids = _canonical_ids_bytes(pinned_ids)
    for path, payload in ((canonical_path, canonical), (pinned_path, normalized_ids)):
        try:
            with path.open("xb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            path.chmod(0o444)
        except OSError as exc:
            raise HarnessError(
                f"cannot materialize immutable runtime fixture {path}: {exc}"
            ) from exc
    fixture_dir.chmod(0o555)
    directory_stat = fixture_dir.stat()
    return (
        canonical_path,
        pinned_path,
        {
            "directory_path": str(fixture_dir),
            "directory_identity": {
                "device": directory_stat.st_dev,
                "inode": directory_stat.st_ino,
                "mode": stat.S_IMODE(directory_stat.st_mode),
                "mtime_ns": directory_stat.st_mtime_ns,
                "ctime_ns": directory_stat.st_ctime_ns,
            },
            "canonical_text_path": str(canonical_path),
            "canonical_text_sha256": sha256_bytes(canonical),
            "canonical_text_identity": _file_identity(
                canonical_path, "canonical runtime fixture"
            ),
            "normalized_pinned_ids_path": str(pinned_path),
            "normalized_pinned_ids_bytes": len(normalized_ids),
            "normalized_pinned_ids_sha256": sha256_bytes(normalized_ids),
            "normalized_pinned_ids_identity": _file_identity(
                pinned_path, "normalized token-ID runtime fixture"
            ),
            "file_mode": "0444",
            "directory_mode": "0555",
        },
    )


def _runtime_fixture_directory_identity(path: Path) -> dict[str, int]:
    try:
        item = path.stat()
    except OSError as exc:
        raise HarnessError(
            f"cannot stat runtime fixture directory {path}: {exc}"
        ) from exc
    if not stat.S_ISDIR(item.st_mode):
        raise HarnessError(f"runtime fixture directory was replaced: {path}")
    return {
        "device": item.st_dev,
        "inode": item.st_ino,
        "mode": stat.S_IMODE(item.st_mode),
        "mtime_ns": item.st_mtime_ns,
        "ctime_ns": item.st_ctime_ns,
    }


def verify_runtime_fixtures(
    runtime_fixture: Mapping[str, Any],
    canonical: bytes,
    pinned_ids: Sequence[int],
    phase: str,
) -> dict[str, Any]:
    """Byte-compare and rehash both immutable fixtures around every launch."""

    directory = Path(runtime_fixture["directory_path"])
    directory_identity = _runtime_fixture_directory_identity(directory)
    if directory_identity != runtime_fixture["directory_identity"]:
        raise HarnessError(f"{phase}: runtime fixture directory identity changed")
    expected = (
        (
            "canonical text",
            Path(runtime_fixture["canonical_text_path"]),
            canonical,
            runtime_fixture["canonical_text_identity"],
            runtime_fixture["canonical_text_sha256"],
        ),
        (
            "normalized token IDs",
            Path(runtime_fixture["normalized_pinned_ids_path"]),
            _canonical_ids_bytes(pinned_ids),
            runtime_fixture["normalized_pinned_ids_identity"],
            runtime_fixture["normalized_pinned_ids_sha256"],
        ),
    )
    checked: dict[str, Any] = {}
    for label, path, expected_bytes, expected_identity, expected_hash in expected:
        before = _file_identity(path, f"{label} runtime fixture")
        if before != expected_identity:
            raise HarnessError(f"{phase}: {label} runtime fixture identity changed")
        try:
            actual_bytes = path.read_bytes()
        except OSError as exc:
            raise HarnessError(
                f"{phase}: cannot read {label} runtime fixture: {exc}"
            ) from exc
        after = _file_identity(path, f"{label} runtime fixture")
        actual_hash = sha256_bytes(actual_bytes)
        if before != after or after != expected_identity:
            raise HarnessError(
                f"{phase}: {label} runtime fixture changed while checked"
            )
        if actual_bytes != expected_bytes or actual_hash != expected_hash:
            raise HarnessError(f"{phase}: {label} runtime fixture content changed")
        checked[label] = {
            "bytes": len(actual_bytes),
            "sha256": actual_hash,
            "identity": after,
        }
    return {"phase": phase, "fixtures": checked}


def restore_runtime_fixture_permissions(runtime_fixture: Mapping[str, Any]) -> None:
    """Make the protected fixture tree removable by TemporaryDirectory cleanup."""

    directory = Path(runtime_fixture["directory_path"])
    try:
        directory.chmod(0o700)
    except OSError:
        return
    for key in ("canonical_text_path", "normalized_pinned_ids_path"):
        try:
            Path(runtime_fixture[key]).chmod(0o600)
        except OSError:
            pass


def canonicalize_text(
    source: bytes, strip_exactly_one_final_lf: bool
) -> tuple[bytes, bool]:
    """Apply the sole permitted text transform: optionally remove one final LF."""

    if strip_exactly_one_final_lf and source.endswith(b"\n"):
        return source[:-1], True
    return source, False


def parse_token_ids(data: bytes | str, ids_format: str) -> list[int]:
    """Parse the *entire* tokenizer stream, rejecting incidental text."""

    try:
        text = data.decode("utf-8") if isinstance(data, bytes) else data
    except UnicodeDecodeError as exc:
        raise HarnessError(f"token IDs are not UTF-8: {exc}") from exc
    if ids_format == "json-array":
        try:
            value = json.loads(text, parse_constant=_reject_json_constant)
        except (json.JSONDecodeError, HarnessError) as exc:
            raise HarnessError(f"invalid JSON token ID array: {exc}") from exc
        if not isinstance(value, list):
            raise HarnessError("JSON token IDs must be an array")
        ids = value
    elif ids_format == "plain":
        stripped = text.strip()
        if not stripped:
            raise HarnessError("token ID stream is empty")
        pieces = stripped.split()
        if any(re.fullmatch(r"[0-9]+", piece) is None for piece in pieces):
            raise HarnessError(
                "plain token IDs must contain only unsigned decimal integers and whitespace"
            )
        ids = [int(piece, 10) for piece in pieces]
    else:
        raise HarnessError(f"unsupported token ID format: {ids_format}")
    if not ids:
        raise HarnessError("token ID list is empty")
    for index, item in enumerate(ids):
        if not _is_int(item) or not 0 <= item <= 0xFFFFFFFF:
            raise HarnessError(f"token ID at index {index} is not a u32 integer")
    return list(ids)


def _canonical_ids_bytes(ids: Sequence[int]) -> bytes:
    return (" ".join(str(item) for item in ids) + "\n").encode("ascii")


def load_fixture(config: Mapping[str, Any]) -> tuple[bytes, list[int], dict[str, Any]]:
    text_cfg = config["workload"]["canonical_text"]
    ids_cfg = config["workload"]["pinned_token_ids"]
    text_path = Path(text_cfg["path"])
    ids_path = Path(ids_cfg["path"])
    try:
        source = text_path.read_bytes()
        ids_raw = ids_path.read_bytes()
    except OSError as exc:
        raise HarnessError(f"cannot read benchmark fixture: {exc}") from exc
    try:
        source.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise HarnessError(f"canonical text fixture is not UTF-8: {exc}") from exc
    source_hash = sha256_bytes(source)
    if (
        text_cfg["source_sha256"] is not None
        and source_hash != text_cfg["source_sha256"]
    ):
        raise HarnessError(
            f"canonical text source SHA-256 mismatch: expected {text_cfg['source_sha256']}, got {source_hash}"
        )
    canonical, stripped = canonicalize_text(
        source, text_cfg["strip_exactly_one_final_lf"]
    )
    canonical_hash = sha256_bytes(canonical)
    if (
        text_cfg["canonical_sha256"] is not None
        and canonical_hash != text_cfg["canonical_sha256"]
    ):
        raise HarnessError(
            f"canonical text SHA-256 mismatch: expected {text_cfg['canonical_sha256']}, got {canonical_hash}"
        )
    ids_raw_hash = sha256_bytes(ids_raw)
    if ids_cfg["sha256"] is not None and ids_raw_hash != ids_cfg["sha256"]:
        raise HarnessError(
            f"pinned token IDs SHA-256 mismatch: expected {ids_cfg['sha256']}, got {ids_raw_hash}"
        )
    ids = parse_token_ids(ids_raw, ids_cfg["format"])
    fixture = {
        "source_text_path": str(text_path),
        "source_text_bytes": len(source),
        "source_text_sha256": source_hash,
        "strip_exactly_one_final_lf": text_cfg["strip_exactly_one_final_lf"],
        "terminal_lf_was_stripped": stripped,
        "canonical_text_bytes": len(canonical),
        "canonical_text_sha256": canonical_hash,
        "pinned_token_ids_path": str(ids_path),
        "pinned_token_ids_raw_sha256": ids_raw_hash,
        "pinned_token_count": len(ids),
        "pinned_token_ids_normalized_sha256": sha256_bytes(_canonical_ids_bytes(ids)),
        "pinned_token_ids": ids,
    }
    return canonical, ids, fixture


def build_schedule(samples_per_engine: int, seed: int) -> list[dict[str, Any]]:
    """Return equal numbers of deterministically shuffled ABBA and BAAB blocks."""

    if samples_per_engine < 4 or samples_per_engine % 4 != 0:
        raise HarnessError("samples_per_engine must be positive and divisible by 4")
    block_count = samples_per_engine // 2
    patterns = ["ABBA"] * (block_count // 2) + ["BAAB"] * (block_count // 2)
    random.Random(seed).shuffle(patterns)
    names = {"A": "glacier", "B": "llama"}
    ordinals = {name: 0 for name in ENGINE_NAMES}
    schedule: list[dict[str, Any]] = []
    sequence = 0
    for block_index, pattern in enumerate(patterns):
        for position, letter in enumerate(pattern):
            engine = names[letter]
            ordinals[engine] += 1
            schedule.append(
                {
                    "sequence_index": sequence,
                    "block_index": block_index,
                    "position_in_block": position,
                    "pattern": pattern,
                    "engine": engine,
                    "engine_sample_index": ordinals[engine] - 1,
                }
            )
            sequence += 1
    assert all(value == samples_per_engine for value in ordinals.values())
    return schedule


def _replace_placeholders(value: str, context: Mapping[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in context:
            raise HarnessError(f"placeholder {{{name}}} is unavailable in this command")
        return context[name]

    return PLACEHOLDER_RE.sub(replace, value)


def _command_context(
    config: Mapping[str, Any],
    canonical_path: Path,
    pinned_ids_path: Path,
    sample_dir: Path,
    engine: str,
    sample_index: int,
) -> dict[str, str]:
    return {
        "manifest_dir": config["manifest_dir"],
        "repo_root": config["repo_root"],
        "canonical_text_path": str(canonical_path),
        "pinned_token_ids_path": str(pinned_ids_path),
        "sample_dir": str(sample_dir),
        "engine": engine,
        "sample_index": str(sample_index),
        **{name: artifact["path"] for name, artifact in config["artifacts"].items()},
    }


def expand_command(
    config: Mapping[str, Any],
    command: Mapping[str, Any],
    canonical_path: Path,
    pinned_ids_path: Path,
    sample_dir: Path,
    engine: str,
    sample_index: int,
) -> tuple[list[str], Path, dict[str, str], dict[str, str]]:
    context = _command_context(
        config, canonical_path, pinned_ids_path, sample_dir, engine, sample_index
    )
    argv = [_replace_placeholders(arg, context) for arg in command["argv"]]
    cwd_text = _replace_placeholders(command["cwd"], context)
    cwd = _resolve_path(cwd_text, Path(config["manifest_dir"]))
    configured_env = {
        key: _replace_placeholders(value, context)
        for key, value in command["env"].items()
    }
    env = {key: os.environ[key] for key in INHERITED_ENV_ALLOWLIST if key in os.environ}
    env.setdefault("PATH", os.defpath)
    env.update(configured_env)
    return argv, cwd, env, context


def environment_snapshot(env: Mapping[str, str]) -> dict[str, Any]:
    """Record the sanitized effective environment without leaking arbitrary values."""

    visible: dict[str, str] = {}
    redacted: dict[str, dict[str, str]] = {}
    for key, value in sorted(env.items()):
        if key in INHERITED_ENV_ALLOWLIST or key.startswith(PERFORMANCE_ENV_PREFIXES):
            visible[key] = value
        else:
            redacted[key] = {
                "value": "<redacted>",
                "sha256": sha256_bytes(value.encode("utf-8")),
            }
    encoded = json.dumps(dict(sorted(env.items())), separators=(",", ":")).encode(
        "utf-8"
    )
    return {
        "policy": "minimal allowlist plus manifest-declared env",
        "visible": visible,
        "redacted": redacted,
        "effective_env_sha256": sha256_bytes(encoded),
    }


def _decode_log(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def _first_difference(
    expected: Sequence[int], actual: Sequence[int]
) -> dict[str, Any] | None:
    for index, (left, right) in enumerate(zip(expected, actual)):
        if left != right:
            return {"index": index, "expected": left, "actual": right}
    if len(expected) != len(actual):
        index = min(len(expected), len(actual))
        return {
            "index": index,
            "expected": expected[index] if index < len(expected) else None,
            "actual": actual[index] if index < len(actual) else None,
            "expected_length": len(expected),
            "actual_length": len(actual),
        }
    return None


def _run_process(
    argv: Sequence[str],
    cwd: Path,
    env: Mapping[str, str],
    stdin_bytes: bytes | None,
    timeout_seconds: float,
    process_observer: ExternalCpuSampler | None = None,
    after_process_exit: Any = None,
) -> dict[str, Any]:
    started = time.perf_counter_ns()
    child_finished = started
    observer_evidence: dict[str, Any] | None = None
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=str(cwd),
            env=dict(env),
            stdin=subprocess.PIPE if stdin_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            start_new_session=os.name == "posix",
        )
        if process_observer is not None:
            process_observer.start(process.pid)
        try:
            stdout, stderr = process.communicate(
                input=stdin_bytes, timeout=timeout_seconds
            )
            timed_out = False
            launch_error = None
        except subprocess.TimeoutExpired:
            timed_out = True
            launch_error = f"timeout after {timeout_seconds:.3f} seconds"
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
            except ProcessLookupError:
                pass
            # communicate() both waits for the process and drains the pipes.
            # Descendants inherited the fresh POSIX process group and are
            # killed before this wait, so they cannot retain either pipe.
            stdout, stderr = process.communicate()
        exit_status: int | None = process.returncode
    except (OSError, ValueError) as exc:
        stdout = b""
        stderr = b""
        exit_status = None
        timed_out = False
        launch_error = f"{type(exc).__name__}: {exc}"
    finally:
        # Freeze the engine wall clock before waiting for a sampler probe that
        # may already be in flight. Sampler shutdown is evidence overhead, not
        # engine runtime.
        child_finished = time.perf_counter_ns()
        if process_observer is not None:
            process_observer.request_stop()
        try:
            if after_process_exit is not None:
                after_process_exit()
        finally:
            if process_observer is not None:
                observer_evidence = process_observer.stop()
    elapsed = (child_finished - started) / 1e9
    result = {
        "exit_status": exit_status,
        "timed_out": timed_out,
        "launch_error": launch_error,
        "harness_wall_seconds": elapsed,
        "stdout_bytes": stdout,
        "stderr_bytes": stderr,
    }
    if observer_evidence is not None:
        result["process_observer"] = observer_evidence
    return result


def run_tokenizer_preflight(
    config: Mapping[str, Any],
    canonical: bytes,
    pinned_ids: Sequence[int],
    canonical_path: Path,
    pinned_ids_path: Path,
    runtime_fixture: Mapping[str, Any],
    artifact_fingerprints: Mapping[str, Any],
    work_dir: Path,
) -> dict[str, Any]:
    """Run both tokenizers and compare normalized full lists before any timing."""

    results: dict[str, Any] = {}
    parsed: dict[str, list[int]] = {}
    for tokenizer_name in TOKENIZER_NAMES:
        command = config["tokenizer_preflight"][tokenizer_name]
        sample_dir = work_dir / f"preflight-{tokenizer_name}"
        sample_dir.mkdir(parents=True, exist_ok=False)
        argv, cwd, env, _ = expand_command(
            config,
            command,
            canonical_path,
            pinned_ids_path,
            sample_dir,
            tokenizer_name,
            -1,
        )
        stdin_bytes = canonical if command["stdin"] == "canonical_text" else None
        verify_runtime_fixtures(
            runtime_fixture,
            canonical,
            pinned_ids,
            f"before {tokenizer_name} tokenizer preflight",
        )
        verify_artifacts_unchanged(
            config,
            artifact_fingerprints,
            f"before {tokenizer_name} tokenizer preflight",
            full_hash=False,
        )
        process = _run_process(argv, cwd, env, stdin_bytes, command["timeout_seconds"])
        verify_runtime_fixtures(
            runtime_fixture,
            canonical,
            pinned_ids,
            f"after {tokenizer_name} tokenizer preflight",
        )
        verify_artifacts_unchanged(
            config,
            artifact_fingerprints,
            f"after {tokenizer_name} tokenizer preflight",
            full_hash=False,
        )
        stdout = process.pop("stdout_bytes")
        stderr = process.pop("stderr_bytes")
        item: dict[str, Any] = {
            "tokenizer": tokenizer_name,
            "argv": argv,
            "cwd": str(cwd),
            "configured_env": command["env"],
            "effective_environment": environment_snapshot(env),
            "stdin": command["stdin"],
            **process,
            "stdout_sha256": sha256_bytes(stdout),
            "stderr_sha256": sha256_bytes(stderr),
            "raw_stdout": _decode_log(stdout),
            "raw_stderr": _decode_log(stderr),
            "ids_format": command["ids_format"],
            "ids_stream": command["ids_stream"],
        }
        if process["exit_status"] == 0 and process["launch_error"] is None:
            stream = stdout if command["ids_stream"] == "stdout" else stderr
            try:
                ids = parse_token_ids(stream, command["ids_format"])
                parsed[tokenizer_name] = ids
                difference = _first_difference(pinned_ids, ids)
                item.update(
                    {
                        "token_count": len(ids),
                        "token_ids": ids,
                        "normalized_sha256": sha256_bytes(_canonical_ids_bytes(ids)),
                        "matches_pinned_ids": difference is None,
                        "first_difference": difference,
                    }
                )
            except HarnessError as exc:
                item["parse_error"] = str(exc)
                item["matches_pinned_ids"] = False
        else:
            item["matches_pinned_ids"] = False
        results[tokenizer_name] = item
    cross_difference = (
        _first_difference(parsed["hf"], parsed["llama"])
        if all(name in parsed for name in TOKENIZER_NAMES)
        else None
    )
    passed = all(results[name].get("matches_pinned_ids") for name in TOKENIZER_NAMES)
    if all(name in parsed for name in TOKENIZER_NAMES):
        passed = passed and cross_difference is None
    else:
        passed = False
    return {
        "passed": passed,
        "comparison": {
            "full_integer_lists_compared": True,
            "pinned_token_count": len(pinned_ids),
            "tokenizers_match_each_other": cross_difference is None
            and all(name in parsed for name in TOKENIZER_NAMES),
            "first_cross_tokenizer_difference": cross_difference,
        },
        "commands": results,
    }


_TIME_REAL_RE = re.compile(r"(?m)^\s*([0-9]+(?:\.[0-9]+)?)\s+real\b")
_MAX_RSS_RE = re.compile(r"(?m)^\s*([0-9]+)\s+maximum resident set size\s*$")
_PEAK_FOOTPRINT_RE = re.compile(r"(?m)^\s*([0-9]+)\s+peak memory footprint\s*$")
_GLACIER_TIME_RE = re.compile(
    r"^[^\S\r\n]*time:[^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*ms"
    r"[^\S\r\n]*\([^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*tok/s,"
    r"[^\S\r\n]*prefilled[^\S\r\n]+([0-9]+),[^\S\r\n]*prefill=(batch|serial)"
    r"[^\S\r\n]*\)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_GLACIER_LOAD_RE = re.compile(
    r"^[^\S\r\n]*load:[^\S\r\n]+mode=(prepared|materialized)"
    r"[^\S\r\n]+artifact=(glrt|glacier)[^\S\r\n]+ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_GLACIER_READY_RE = re.compile(
    r"^[^\S\r\n]*ready:[^\S\r\n]+phase=request_ready[^\S\r\n]+ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_GLACIER_PHASES_RE = re.compile(
    r"^[^\S\r\n]*phases:[^\S\r\n]+prefill_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+sampling_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+decode_runs=([0-9]+)"
    r"[^\S\r\n]+attention_graphs=([0-9]+)"
    r"[^\S\r\n]+attention_dispatches=([0-9]+)"
    r"[^\S\r\n]+handoff_graphs=([0-9]+)"
    r"[^\S\r\n]+handoff_dispatches=([0-9]+)"
    r"[^\S\r\n]+fused_gqa_graphs=([0-9]+)"
    r"[^\S\r\n]+fused_gqa_dispatches=([0-9]+)"
    r"[^\S\r\n]+paired_mlp_graphs=([0-9]+)"
    r"[^\S\r\n]+paired_mlp_dispatches=([0-9]+)"
    r"[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_GLACIER_SCHEDULE_RE = re.compile(
    r"^[^\S\r\n]*schedule:[^\S\r\n]+attention=(serial|parallel)"
    r"(?:[^\S\r\n]+min_context=([1-9][0-9]*))?"
    r"[^\S\r\n]+layers=([1-9][0-9]*)[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_GLACIER_PHASES_PREFIX_RE = re.compile(
    r"^[^\S\r\n]*phases:", re.IGNORECASE | re.MULTILINE
)
_GLACIER_SCHEDULE_PREFIX_RE = re.compile(
    r"^[^\S\r\n]*schedule:", re.IGNORECASE | re.MULTILINE
)
_LLAMA_MODEL_READY_RE = re.compile(
    r"^[^\S\r\n]*([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)"
    r"[^\S\r\n]+I[^\r\n]*llama_completion:[^\r\n]*llama threadpool init\b",
    re.IGNORECASE | re.MULTILINE,
)
_LLAMA_PROMPT_RE = re.compile(
    r"^[^\S\r\n]*(?:(?:[0-9]+(?:\.[0-9]+){3}[^\S\r\n]+[A-Z][^\S\r\n]+)?"
    r"(?:common_perf_print|llama_perf_context_print):[^\S\r\n]*)?prompt eval time"
    r"[^\S\r\n]*=[^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*ms"
    r"[^\S\r\n]*/[^\S\r\n]*([0-9]+)[^\S\r\n]+tokens?"
    r"(?:[^\S\r\n]*\([^\r\n]*?([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+tokens per second\))?"
    r"[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_LLAMA_EVAL_RE = re.compile(
    r"^[^\S\r\n]*(?:(?:[0-9]+(?:\.[0-9]+){3}[^\S\r\n]+[A-Z][^\S\r\n]+)?"
    r"(?:common_perf_print|llama_perf_context_print):[^\S\r\n]*)?eval time"
    r"[^\S\r\n]*=[^\S\r\n]*([0-9]+(?:\.[0-9]+)?)[^\S\r\n]*ms"
    r"[^\S\r\n]*/[^\S\r\n]*([0-9]+)[^\S\r\n]+runs?"
    r"(?:[^\S\r\n]*\([^\r\n]*?([0-9]+(?:\.[0-9]+)?|inf)[^\S\r\n]+tokens per second\))?"
    r"[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)


def parse_time_l(output: str) -> dict[str, Any]:
    """Parse one isolated ``/usr/bin/time -l`` record fail-closed."""

    real_matches = list(_TIME_REAL_RE.finditer(output))
    rss_matches = list(_MAX_RSS_RE.finditer(output))
    footprint_matches = list(_PEAK_FOOTPRINT_RE.finditer(output))
    if len(real_matches) != 1:
        raise HarnessError(
            "/usr/bin/time -l evidence must contain exactly one real record; "
            f"found {len(real_matches)}"
        )
    if len(rss_matches) != 1:
        raise HarnessError(
            "/usr/bin/time -l evidence must contain exactly one maximum resident "
            f"set size record; found {len(rss_matches)}"
        )
    if len(footprint_matches) > 1:
        raise HarnessError(
            "/usr/bin/time -l evidence contains duplicated peak memory footprint "
            f"records; found {len(footprint_matches)}"
        )
    real = real_matches[0]
    rss = rss_matches[0]
    footprint = footprint_matches[0] if footprint_matches else None
    return {
        "time_l_wall_seconds": float(real.group(1)),
        "peak_rss_bytes": int(rss.group(1)),
        "peak_memory_footprint_bytes": int(footprint.group(1)) if footprint else None,
    }


def _prepare_time_l_output(sample_dir: Path) -> tuple[Path, dict[str, int]]:
    """Atomically create a private time-output file directly in ``sample_dir``."""

    try:
        resolved_sample_dir = sample_dir.resolve(strict=True)
    except OSError as exc:
        raise HarnessError(f"cannot resolve sample directory {sample_dir}: {exc}") from exc
    if not resolved_sample_dir.is_dir():
        raise HarnessError(f"sample directory is not a directory: {resolved_sample_dir}")
    try:
        descriptor, path_text = tempfile.mkstemp(
            prefix=".time-l-", suffix=".txt", dir=resolved_sample_dir
        )
    except OSError as exc:
        raise HarnessError(
            f"cannot create isolated /usr/bin/time output in {resolved_sample_dir}: {exc}"
        ) from exc
    path = Path(path_text)
    try:
        item = os.fstat(descriptor)
        if not stat.S_ISREG(item.st_mode):
            raise HarnessError(f"isolated /usr/bin/time output is not regular: {path}")
        if path.parent != resolved_sample_dir or not _is_within(
            path, resolved_sample_dir
        ):
            raise HarnessError(
                f"isolated /usr/bin/time output escaped sample directory: {path}"
            )
        identity = {
            "device": item.st_dev,
            "inode": item.st_ino,
            "mode": stat.S_IMODE(item.st_mode),
        }
    finally:
        os.close(descriptor)
    return path, identity


def _read_time_l_output(
    path: Path, created_identity: Mapping[str, int]
) -> tuple[bytes, dict[str, int]]:
    """Read the bound time-output inode without following a replacement symlink."""

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise HarnessError(f"cannot open isolated /usr/bin/time output {path}: {exc}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise HarnessError(f"isolated /usr/bin/time output is not regular: {path}")
        if (
            before.st_dev != created_identity["device"]
            or before.st_ino != created_identity["inode"]
        ):
            raise HarnessError(
                "isolated /usr/bin/time output filesystem identity changed"
            )
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            data = handle.read()
        after = os.fstat(descriptor)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(getattr(before, name) != getattr(after, name) for name in stable_fields):
            raise HarnessError(
                "isolated /usr/bin/time output changed while being read"
            )
        try:
            path_item = path.lstat()
        except OSError as exc:
            raise HarnessError(
                f"cannot re-stat isolated /usr/bin/time output {path}: {exc}"
            ) from exc
        if (
            not stat.S_ISREG(path_item.st_mode)
            or any(
                getattr(path_item, name) != getattr(after, name)
                for name in stable_fields
            )
        ):
            raise HarnessError(
                "isolated /usr/bin/time output path was replaced after execution"
            )
        identity = {
            "device": after.st_dev,
            "inode": after.st_ino,
            "bytes": after.st_size,
            "mode": stat.S_IMODE(after.st_mode),
            "mtime_ns": after.st_mtime_ns,
            "ctime_ns": after.st_ctime_ns,
        }
        return data, identity
    finally:
        os.close(descriptor)


def metric_evidence_errors(metrics: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    for metric_name, metric_value in metrics.items():
        if isinstance(metric_value, float) and not math.isfinite(metric_value):
            errors.append(
                f"metric {metric_name} is non-finite and cannot be benchmark evidence"
            )
        elif (
            isinstance(metric_value, int)
            and not isinstance(metric_value, bool)
            and abs(metric_value) > (1 << 63) - 1
        ):
            errors.append(
                f"metric {metric_name} exceeds the signed 64-bit evidence bound"
            )
    return errors


def glacier_attention_evidence_errors(
    argv: Sequence[str],
    internals: Mapping[str, Any],
    *,
    prompt_tokens: int,
    decode_runs: int,
    require_fused_gqa: bool = False,
    require_paired_mlp: bool = False,
) -> list[str]:
    """Validate strict prepared-run attention policy and dispatch evidence."""

    errors: list[str] = []
    serial_flags = argv.count("--serial-attention")
    parallel_flags = argv.count("--parallel-attention-min-context")
    if serial_flags + parallel_flags != 1:
        errors.append(
            "strict prepared Glacier execution requires exactly one explicit attention policy"
        )
        return errors

    schedule_lines = internals.get("glacier_attention_schedule_line_count")
    valid_schedule_lines = internals.get("glacier_attention_schedule_valid_line_count")
    if schedule_lines != 1 or valid_schedule_lines != 1:
        errors.append(
            "required Glacier attention schedule telemetry is missing, malformed, or duplicated"
        )

    schedule = internals.get("glacier_attention_schedule")
    threshold = internals.get("glacier_attention_min_context")
    layers = internals.get("glacier_attention_layers")
    attention_graphs = internals.get("glacier_parallel_attention_graphs")
    attention_dispatches = internals.get("glacier_parallel_attention_dispatches")
    handoff_graphs = internals.get("glacier_handoff_graphs")
    handoff_dispatches = internals.get("glacier_handoff_dispatches")
    fused_gqa_graphs = internals.get("glacier_fused_gqa_graphs")
    fused_gqa_dispatches = internals.get("glacier_fused_gqa_dispatches")
    paired_mlp_graphs = internals.get("glacier_paired_mlp_graphs")
    paired_mlp_dispatches = internals.get("glacier_paired_mlp_dispatches")

    if not _is_int(layers) or layers <= 0:
        errors.append(
            "Glacier attention schedule did not report a positive layer count"
        )

    if serial_flags == 1:
        if schedule != "serial":
            errors.append(
                "Glacier attention schedule telemetry did not confirm --serial-attention"
            )
        if threshold is not None:
            errors.append(
                "serial Glacier attention must not report a parallel threshold"
            )
        if attention_graphs != 0:
            errors.append("serial Glacier attention reported parallel decode graphs")
        if attention_dispatches != 0:
            errors.append("serial Glacier attention reported parallel dispatches")
        if handoff_graphs != 0:
            errors.append(
                "serial Glacier attention reported HandoffGraph decode graphs"
            )
        if handoff_dispatches != 0:
            errors.append("serial Glacier attention reported HandoffGraph dispatches")
        if fused_gqa_graphs != 0:
            errors.append("serial Glacier attention reported fused GQA decode graphs")
        if fused_gqa_dispatches != 0:
            errors.append("serial Glacier attention reported fused GQA dispatches")
        if paired_mlp_graphs != 0:
            errors.append("serial Glacier attention reported paired MLP decode graphs")
        if paired_mlp_dispatches != 0:
            errors.append("serial Glacier attention reported paired MLP dispatches")
        if require_fused_gqa:
            errors.append(
                "required Glacier fused GQA campaign requires parallel attention"
            )
        if require_paired_mlp:
            errors.append(
                "required Glacier paired MLP campaign requires parallel attention"
            )
        return errors

    flag_index = argv.index("--parallel-attention-min-context")
    expected_threshold: int | None = None
    if flag_index + 1 < len(argv):
        try:
            expected_threshold = int(argv[flag_index + 1])
        except ValueError:
            pass
    if expected_threshold is None or expected_threshold <= 0:
        errors.append("required Glacier parallel attention threshold is invalid")
        return errors
    if schedule != "parallel" or threshold != expected_threshold:
        errors.append(
            "Glacier attention schedule telemetry did not match the required parallel threshold"
        )

    eligible_attention_graphs = min(
        decode_runs,
        max(0, prompt_tokens + decode_runs - expected_threshold + 1),
    )
    if attention_graphs != eligible_attention_graphs:
        errors.append(
            f"Glacier parallel attention covered {attention_graphs} decode graphs, expected {eligible_attention_graphs}"
        )
    if _is_int(layers) and layers > 0:
        expected_dispatches = eligible_attention_graphs * layers
        if attention_dispatches != expected_dispatches:
            errors.append(
                f"Glacier parallel attention dispatched {attention_dispatches} layers, expected {expected_dispatches}"
            )
        if handoff_graphs != eligible_attention_graphs:
            errors.append(
                f"Glacier HandoffGraph covered {handoff_graphs} decode graphs, expected {eligible_attention_graphs}"
            )
        if handoff_dispatches != expected_dispatches:
            errors.append(
                f"Glacier HandoffGraph dispatched {handoff_dispatches} layers, expected {expected_dispatches}"
            )
        if fused_gqa_graphs not in (0, eligible_attention_graphs):
            errors.append(
                f"Glacier fused GQA covered {fused_gqa_graphs} decode graphs, expected zero or {eligible_attention_graphs}"
            )
        expected_fused_dispatches = (
            fused_gqa_graphs * layers if _is_int(fused_gqa_graphs) else None
        )
        if fused_gqa_dispatches != expected_fused_dispatches:
            errors.append(
                f"Glacier fused GQA dispatched {fused_gqa_dispatches} layers, expected {expected_fused_dispatches}"
            )
        if require_fused_gqa:
            if eligible_attention_graphs == 0:
                errors.append(
                    "required Glacier fused GQA campaign had no eligible parallel decode graphs"
                )
            elif fused_gqa_graphs != eligible_attention_graphs:
                errors.append(
                    f"required Glacier fused GQA covered {fused_gqa_graphs} decode graphs, expected {eligible_attention_graphs}"
                )
        if paired_mlp_graphs not in (0, eligible_attention_graphs):
            errors.append(
                f"Glacier paired MLP covered {paired_mlp_graphs} decode graphs, expected zero or {eligible_attention_graphs}"
            )
        expected_paired_mlp_dispatches = (
            paired_mlp_graphs * layers if _is_int(paired_mlp_graphs) else None
        )
        if paired_mlp_dispatches != expected_paired_mlp_dispatches:
            errors.append(
                f"Glacier paired MLP dispatched {paired_mlp_dispatches} layers, expected {expected_paired_mlp_dispatches}"
            )
        if (
            paired_mlp_graphs == eligible_attention_graphs
            and eligible_attention_graphs > 0
            and handoff_graphs != eligible_attention_graphs
        ):
            errors.append("Glacier paired MLP coverage requires full HandoffGraph coverage")
        if require_paired_mlp:
            if eligible_attention_graphs == 0:
                errors.append(
                    "required Glacier paired MLP campaign had no eligible parallel decode graphs"
                )
            elif paired_mlp_graphs != eligible_attention_graphs:
                errors.append(
                    f"required Glacier paired MLP covered {paired_mlp_graphs} decode graphs, expected {eligible_attention_graphs}"
                )
    return errors


def parse_engine_internal(engine: str, output: str) -> dict[str, Any]:
    if engine == "glacier":
        matches = list(_GLACIER_TIME_RE.finditer(output))
        if not matches:
            return {}
        match = matches[-1]
        result: dict[str, Any] = {
            "glacier_internal_ms": float(match.group(1)),
            "glacier_internal_tokens_per_second": float(match.group(2)),
            "glacier_prefilled_tokens": int(match.group(3)),
            "glacier_prefill_mode": match.group(4).lower(),
            "glacier_telemetry_line_count": len(matches),
        }
        loads = list(_GLACIER_LOAD_RE.finditer(output))
        if loads:
            load = loads[-1]
            result.update(
                {
                    "glacier_load_mode": load.group(1).lower(),
                    "glacier_load_artifact": load.group(2).lower(),
                    "glacier_load_ms": float(load.group(3)),
                    "glacier_load_telemetry_line_count": len(loads),
                }
            )
        ready_matches = list(_GLACIER_READY_RE.finditer(output))
        if ready_matches:
            ready = ready_matches[-1]
            result.update(
                {
                    "glacier_request_ready_ms": float(ready.group(1)),
                    "glacier_request_ready_telemetry_line_count": len(ready_matches),
                    "model_ready_ms": float(ready.group(1)),
                }
            )
        phase_line_count = len(_GLACIER_PHASES_PREFIX_RE.findall(output))
        phase_matches = list(_GLACIER_PHASES_RE.finditer(output))
        result.update(
            {
                "glacier_phase_telemetry_line_count": phase_line_count,
                "glacier_phase_telemetry_valid_line_count": len(phase_matches),
            }
        )
        if phase_matches:
            phases = phase_matches[-1]
            result.update(
                {
                    "glacier_prefill_phase_ms": float(phases.group(1)),
                    "glacier_decode_phase_ms": float(phases.group(2)),
                    "glacier_sampling_ms": float(phases.group(3)),
                    "glacier_decode_graph_runs": int(phases.group(4)),
                    "glacier_parallel_attention_graphs": int(phases.group(5)),
                    "glacier_parallel_attention_dispatches": int(phases.group(6)),
                    "glacier_handoff_graphs": int(phases.group(7)),
                    "glacier_handoff_dispatches": int(phases.group(8)),
                    "glacier_fused_gqa_graphs": int(phases.group(9)),
                    "glacier_fused_gqa_dispatches": int(phases.group(10)),
                    "glacier_paired_mlp_graphs": int(phases.group(11)),
                    "glacier_paired_mlp_dispatches": int(phases.group(12)),
                }
            )
        schedule_line_count = len(_GLACIER_SCHEDULE_PREFIX_RE.findall(output))
        schedule_matches = list(_GLACIER_SCHEDULE_RE.finditer(output))
        result.update(
            {
                "glacier_attention_schedule_line_count": schedule_line_count,
                "glacier_attention_schedule_valid_line_count": len(schedule_matches),
            }
        )
        if schedule_matches:
            schedule = schedule_matches[-1]
            result.update(
                {
                    "glacier_attention_schedule": schedule.group(1).lower(),
                    "glacier_attention_min_context": int(schedule.group(2))
                    if schedule.group(2)
                    else None,
                    "glacier_attention_layers": int(schedule.group(3)),
                }
            )
        return result
    prompts = list(_LLAMA_PROMPT_RE.finditer(output))
    evaluations = list(_LLAMA_EVAL_RE.finditer(output))
    prompt = prompts[-1] if prompts else None
    evaluation = evaluations[-1] if evaluations else None
    result: dict[str, Any] = {}
    if prompt:
        result.update(
            {
                "llama_prompt_eval_ms": float(prompt.group(1)),
                "llama_prompt_eval_tokens": int(prompt.group(2)),
                "llama_prompt_eval_tokens_per_second": float(prompt.group(3))
                if prompt.group(3)
                else None,
                "llama_prompt_telemetry_line_count": len(prompts),
            }
        )
    if evaluation:
        eval_ms = float(evaluation.group(1))
        eval_runs = int(evaluation.group(2))
        reported_tps = evaluation.group(3)
        eval_tps_status: str | None = None
        if reported_tps and reported_tps.lower() == "inf":
            eval_tps = None
            eval_tps_status = (
                "unresolved_zero_duration"
                if eval_ms == 0.0 and eval_runs == 1
                else "invalid_non_finite"
            )
        else:
            eval_tps = float(reported_tps) if reported_tps else None
        result.update(
            {
                "llama_eval_ms": eval_ms,
                "llama_eval_runs": eval_runs,
                "llama_eval_tokens_per_second": eval_tps,
                "llama_eval_telemetry_line_count": len(evaluations),
            }
        )
        if eval_tps_status is not None:
            result["llama_eval_tokens_per_second_status"] = eval_tps_status
    ready_matches = list(_LLAMA_MODEL_READY_RE.finditer(output))
    if ready_matches:
        ready = ready_matches[-1]
        # llama.cpp timestamps are minutes.seconds.milliseconds.microseconds.
        ready_ms = (
            (int(ready.group(1)) * 60 + int(ready.group(2))) * 1000
            + int(ready.group(3))
            + int(ready.group(4)) / 1000.0
        )
        result.update(
            {
                "llama_model_ready_ms": ready_ms,
                "llama_model_ready_telemetry_line_count": len(ready_matches),
                "model_ready_ms": ready_ms,
            }
        )
    return result


def _is_within(path: Path, directory: Path) -> bool:
    try:
        return os.path.commonpath((str(path), str(directory))) == str(directory)
    except ValueError:
        return False


def _completion_bytes(
    completion: Mapping[str, Any],
    context: Mapping[str, str],
    cwd: Path,
    sample_dir: Path,
    stdout: bytes,
    stderr: bytes,
) -> tuple[bytes | None, str | None, str | None]:
    source = completion["source"]
    if source == "stdout":
        return stdout, "stdout", None
    if source == "stderr":
        return stderr, "stderr", None
    path_text = _replace_placeholders(completion["path"], context)
    path = _resolve_path(path_text, cwd)
    resolved_sample_dir = sample_dir.resolve(strict=False)
    if not _is_within(path, resolved_sample_dir):
        return (
            None,
            str(path),
            "completion file must be inside {sample_dir} to prevent stale data",
        )
    try:
        return path.read_bytes(), str(path), None
    except OSError as exc:
        return None, str(path), f"cannot read completion file: {exc}"


def _run_completion_extractor(
    config: Mapping[str, Any],
    extractor: Mapping[str, Any],
    completion_data: bytes,
    canonical: bytes,
    pinned_ids: Sequence[int],
    canonical_path: Path,
    pinned_ids_path: Path,
    runtime_fixture: Mapping[str, Any],
    artifact_fingerprints: Mapping[str, Any],
    sample_dir: Path,
    engine: str,
    sample_index: int,
) -> tuple[list[int] | None, dict[str, Any]]:
    extractor_dir = sample_dir / "completion-extractor"
    extractor_dir.mkdir(parents=True, exist_ok=False)
    argv, cwd, env, _ = expand_command(
        config,
        extractor,
        canonical_path,
        pinned_ids_path,
        extractor_dir,
        engine,
        sample_index,
    )
    verify_runtime_fixtures(
        runtime_fixture, canonical, pinned_ids, f"before {engine} completion extractor"
    )
    verify_artifacts_unchanged(
        config,
        artifact_fingerprints,
        f"before {engine} completion extractor",
        full_hash=False,
    )
    process = _run_process(
        argv, cwd, env, completion_data, extractor["timeout_seconds"]
    )
    verify_runtime_fixtures(
        runtime_fixture, canonical, pinned_ids, f"after {engine} completion extractor"
    )
    verify_artifacts_unchanged(
        config,
        artifact_fingerprints,
        f"after {engine} completion extractor",
        full_hash=False,
    )
    stdout = process.pop("stdout_bytes")
    stderr = process.pop("stderr_bytes")
    result: dict[str, Any] = {
        "argv": argv,
        "cwd": str(cwd),
        "configured_env": extractor["env"],
        "effective_environment": environment_snapshot(env),
        **process,
        "ids_format": extractor["ids_format"],
        "ids_stream": extractor["ids_stream"],
        "input_bytes": len(completion_data),
        "input_sha256": sha256_bytes(completion_data),
        "stdout_sha256": sha256_bytes(stdout),
        "stderr_sha256": sha256_bytes(stderr),
        "raw_stdout": _decode_log(stdout),
        "raw_stderr": _decode_log(stderr),
    }
    if process["exit_status"] != 0 or process["launch_error"] is not None:
        result["error"] = "completion token-ID extractor failed"
        return None, result
    stream = stdout if extractor["ids_stream"] == "stdout" else stderr
    try:
        ids = parse_token_ids(stream, extractor["ids_format"])
    except HarnessError as exc:
        result["error"] = str(exc)
        return None, result
    result.update(
        {
            "token_count": len(ids),
            "token_ids": ids,
            "normalized_sha256": sha256_bytes(_canonical_ids_bytes(ids)),
            "error": None,
        }
    )
    return ids, result


def run_timed_sample(
    config: Mapping[str, Any],
    canonical: bytes,
    canonical_path: Path,
    pinned_ids_path: Path,
    expected_pinned_ids: Sequence[int],
    runtime_fixture: Mapping[str, Any],
    artifact_fingerprints: Mapping[str, Any],
    sample_dir: Path,
    schedule_entry: Mapping[str, Any],
    *,
    warmup: bool,
    process_observer: ExternalCpuSampler | None = None,
    after_timed_child: Any = None,
    deferred_completion_queue: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    engine = schedule_entry["engine"]
    command = config["engines"][engine]
    sample_dir.mkdir(parents=True, exist_ok=False)
    argv, cwd, env, context = expand_command(
        config,
        command,
        canonical_path,
        pinned_ids_path,
        sample_dir,
        engine,
        int(schedule_entry["engine_sample_index"]),
    )
    time_output_path, time_output_created_identity = _prepare_time_l_output(sample_dir)
    timed_argv = [
        "/usr/bin/time",
        "-l",
        "-o",
        str(time_output_path),
        *argv,
    ]
    stdin_bytes = canonical if command["stdin"] == "canonical_text" else None
    verify_runtime_fixtures(
        runtime_fixture,
        canonical,
        expected_pinned_ids,
        f"before {engine} engine launch",
    )
    verify_artifacts_unchanged(
        config,
        artifact_fingerprints,
        f"before {engine} engine launch",
        full_hash=False,
    )
    process = _run_process(
        timed_argv,
        cwd,
        env,
        stdin_bytes,
        command["timeout_seconds"],
        process_observer,
        after_timed_child,
    )
    # Machine-state publication mode passes the hook into _run_process so
    # post-state is captured after child exit, after new monitor samples are
    # stopped, and before a blocking monitor join or asymmetric extractor.
    verify_runtime_fixtures(
        runtime_fixture, canonical, expected_pinned_ids, f"after {engine} engine launch"
    )
    verify_artifacts_unchanged(
        config,
        artifact_fingerprints,
        f"after {engine} engine launch",
        full_hash=False,
    )
    stdout = process.pop("stdout_bytes")
    stderr = process.pop("stderr_bytes")
    stdout_text = _decode_log(stdout)
    stderr_text = _decode_log(stderr)
    time_evidence_errors: list[str] = []
    time_output = b""
    time_output_identity: dict[str, int] | None = None
    try:
        time_output, time_output_identity = _read_time_l_output(
            time_output_path, time_output_created_identity
        )
    except HarnessError as exc:
        time_evidence_errors.append(str(exc))
    time_output_text = _decode_log(time_output)
    if not time_evidence_errors:
        try:
            time_metrics = parse_time_l(time_output_text)
        except HarnessError as exc:
            time_evidence_errors.append(str(exc))
            time_metrics = {
                "time_l_wall_seconds": None,
                "peak_rss_bytes": None,
                "peak_memory_footprint_bytes": None,
            }
    else:
        time_metrics = {
            "time_l_wall_seconds": None,
            "peak_rss_bytes": None,
            "peak_memory_footprint_bytes": None,
        }
    telemetry_stream = stdout_text if engine == "glacier" else stderr_text
    internals = parse_engine_internal(engine, telemetry_stream)
    completion_data, completion_location, completion_error = _completion_bytes(
        command["completion"], context, cwd, sample_dir, stdout, stderr
    )
    completion_result: dict[str, Any] = {
        "source": command["completion"]["source"],
        "location": completion_location,
        "format": command["completion"]["format"],
        "error": completion_error,
    }
    deferred_completion: dict[str, Any] | None = None
    if completion_data is not None:
        completion_result["raw_bytes"] = len(completion_data)
        completion_result["raw_sha256"] = sha256_bytes(completion_data)
        if command["completion"]["format"] == "token_ids":
            try:
                ids = parse_token_ids(
                    completion_data, command["completion"]["ids_format"]
                )
                normalized = _canonical_ids_bytes(ids)
                completion_result.update(
                    {
                        "token_count": len(ids),
                        "token_ids": ids,
                        "normalized_sha256": sha256_bytes(normalized),
                        "comparison_sha256": sha256_bytes(normalized),
                    }
                )
            except HarnessError as exc:
                completion_result["error"] = str(exc)
        else:
            extractor_input, stripped = canonicalize_text(
                completion_data,
                command["completion"]["strip_exactly_one_final_lf"],
            )
            completion_result["text_transform"] = {
                "strip_exactly_one_final_lf": command["completion"][
                    "strip_exactly_one_final_lf"
                ],
                "terminal_lf_was_stripped": stripped,
                "extractor_input_bytes": len(extractor_input),
                "extractor_input_sha256": sha256_bytes(extractor_input),
            }
            if deferred_completion_queue is not None:
                completion_result.update(
                    {
                        "validation_pending": True,
                        "extraction_timing": "after-all-timed-observations",
                        "token_id_extractor": {
                            "status": "deferred",
                            "ids_format": command["completion"][
                                "token_id_extractor"
                            ]["ids_format"],
                            "ids_stream": command["completion"][
                                "token_id_extractor"
                            ]["ids_stream"],
                        },
                    }
                )
                deferred_completion = {
                    "config": config,
                    "extractor": command["completion"]["token_id_extractor"],
                    "extractor_input": extractor_input,
                    "canonical": canonical,
                    "expected_pinned_ids": expected_pinned_ids,
                    "canonical_path": canonical_path,
                    "pinned_ids_path": pinned_ids_path,
                    "runtime_fixture": runtime_fixture,
                    "artifact_fingerprints": artifact_fingerprints,
                    "sample_dir": sample_dir,
                    "engine": engine,
                    "engine_sample_index": int(
                        schedule_entry["engine_sample_index"]
                    ),
                }
            else:
                ids, extractor_result = _run_completion_extractor(
                    config,
                    command["completion"]["token_id_extractor"],
                    extractor_input,
                    canonical,
                    expected_pinned_ids,
                    canonical_path,
                    pinned_ids_path,
                    runtime_fixture,
                    artifact_fingerprints,
                    sample_dir,
                    engine,
                    int(schedule_entry["engine_sample_index"]),
                )
                completion_result["token_id_extractor"] = extractor_result
                if ids is not None:
                    normalized = _canonical_ids_bytes(ids)
                    completion_result.update(
                        {
                            "token_count": len(ids),
                            "token_ids": ids,
                            "normalized_sha256": sha256_bytes(normalized),
                            "comparison_sha256": sha256_bytes(normalized),
                        }
                    )
                else:
                    completion_result["error"] = extractor_result.get(
                        "error", "completion token-ID extraction failed"
                    )

    completion_tokens = config["workload"]["completion_tokens"]
    expected_prompt_tokens = len(expected_pinned_ids)
    metrics: dict[str, Any] = {
        "wall_seconds": process["harness_wall_seconds"],
        **time_metrics,
        "effective_completion_tokens_per_second": completion_tokens
        / process["harness_wall_seconds"],
        **internals,
    }
    if engine == "glacier" and "glacier_internal_ms" in internals:
        metrics["internal_completion_ms"] = internals["glacier_internal_ms"]
        metrics["internal_completion_tokens_per_second"] = completion_tokens / (
            internals["glacier_internal_ms"] / 1000.0
        )
    elif engine == "llama":
        prompt_ms = internals.get("llama_prompt_eval_ms")
        eval_ms = internals.get("llama_eval_ms")
        if prompt_ms is not None and eval_ms is not None:
            metrics["internal_completion_ms"] = prompt_ms + eval_ms
            metrics["internal_completion_tokens_per_second"] = completion_tokens / (
                (prompt_ms + eval_ms) / 1000.0
            )
    if engine == "glacier":
        prefill_ms = internals.get("glacier_prefill_phase_ms")
        decode_ms = internals.get("glacier_decode_phase_ms")
        decode_runs = internals.get("glacier_decode_graph_runs")
    else:
        prefill_ms = internals.get("llama_prompt_eval_ms")
        decode_ms = internals.get("llama_eval_ms")
        decode_runs = internals.get("llama_eval_runs")
    if prefill_ms is not None:
        metrics["prefill_phase_ms"] = prefill_ms
        if prefill_ms > 0:
            metrics["prefill_tokens_per_second"] = expected_prompt_tokens / (
                prefill_ms / 1000.0
            )
    if decode_ms is not None and decode_runs is not None:
        metrics["decode_graph_runs"] = decode_runs
        if decode_ms > 0 and decode_runs > 0:
            metrics["decode_phase_ms"] = decode_ms
            metrics["decode_graph_tokens_per_second"] = decode_runs / (
                decode_ms / 1000.0
            )
    if "internal_completion_ms" in metrics:
        non_internal = (
            metrics["wall_seconds"] - metrics["internal_completion_ms"] / 1000.0
        )
        if non_internal > 0:
            metrics["non_internal_seconds"] = non_internal

    validation_errors: list[str] = list(time_evidence_errors)
    validation_errors.extend(metric_evidence_errors(metrics))
    completion_count = completion_result.get("token_count")
    if deferred_completion is None:
        if completion_count is None:
            validation_errors.append(
                "completion token count is unavailable; raw bytes never prove generated-token count"
            )
        elif completion_count != completion_tokens:
            validation_errors.append(
                f"completion token count was {completion_count}, expected {completion_tokens}"
            )
    if engine == "glacier":
        if (
            "glacier_internal_ms" not in internals
            or "glacier_prefilled_tokens" not in internals
        ):
            validation_errors.append(
                "required Glacier internal time/prefill telemetry is missing"
            )
        elif internals.get("glacier_telemetry_line_count") != 1:
            validation_errors.append(
                "required Glacier internal timing telemetry is duplicated"
            )
        elif internals["glacier_prefilled_tokens"] != expected_prompt_tokens:
            actual = internals["glacier_prefilled_tokens"]
            validation_errors.append(
                f"Glacier prefilled {actual} tokens, expected {expected_prompt_tokens}"
            )
        expected_prefill_mode = config["workload"]["glacier_prefill_mode"]
        if internals.get("glacier_prefill_mode") != expected_prefill_mode:
            validation_errors.append(
                f"Glacier prefill mode was {internals.get('glacier_prefill_mode')!r}, "
                f"expected {expected_prefill_mode!r}"
            )
        require_fused_gqa = config["workload"]["require_fused_gqa"]
        strict_prepared = "--require-prepared-image" in argv
        if require_fused_gqa and not strict_prepared:
            validation_errors.append(
                "manifest.workload.require_fused_gqa requires --require-prepared-image"
            )
        if strict_prepared or require_fused_gqa:
            if (
                internals.get("glacier_load_mode") != "prepared"
                or internals.get("glacier_load_artifact") != "glrt"
            ):
                validation_errors.append(
                    "required prepared GLRT load telemetry is missing or mismatched"
                )
            if internals.get("glacier_load_telemetry_line_count") != 1:
                validation_errors.append(
                    "required Glacier load telemetry is missing or duplicated"
                )
            if internals.get("glacier_request_ready_telemetry_line_count") != 1:
                validation_errors.append(
                    "required Glacier request-ready telemetry is missing or duplicated"
                )
            if internals.get("glacier_phase_telemetry_line_count") != 1:
                validation_errors.append(
                    "required Glacier phase telemetry is missing or duplicated"
                )
            if internals.get("glacier_phase_telemetry_valid_line_count") != 1:
                validation_errors.append(
                    "required Glacier phase telemetry is malformed"
                )
            expected_decode_runs = max(0, completion_tokens - 1)
            actual_decode_runs = internals.get("glacier_decode_graph_runs")
            if actual_decode_runs != expected_decode_runs:
                validation_errors.append(
                    f"Glacier decode graph count was {actual_decode_runs}, expected {expected_decode_runs} for {completion_tokens} completions"
                )
            if internals.get("glacier_prefill_phase_ms", 0) <= 0:
                validation_errors.append(
                    "Glacier prefill phase must be present and positive"
                )
            if (
                expected_decode_runs > 0
                and internals.get("glacier_decode_phase_ms", 0) <= 0
            ):
                validation_errors.append(
                    "Glacier decode phase must be positive when decode graphs ran"
                )
            validation_errors.extend(
                glacier_attention_evidence_errors(
                    argv,
                    internals,
                    prompt_tokens=expected_prompt_tokens,
                    decode_runs=expected_decode_runs,
                    require_fused_gqa=require_fused_gqa,
                    require_paired_mlp=require_fused_gqa,
                )
            )
    else:
        if "llama_prompt_eval_tokens" not in internals:
            validation_errors.append(
                "required llama.cpp prompt eval count telemetry is missing"
            )
        elif internals["llama_prompt_eval_tokens"] != expected_prompt_tokens:
            actual = internals["llama_prompt_eval_tokens"]
            validation_errors.append(
                f"llama.cpp prompt-evaluated {actual} tokens, expected {expected_prompt_tokens}"
            )
        if internals.get("llama_prompt_telemetry_line_count") != 1:
            validation_errors.append(
                "llama.cpp prompt eval telemetry is missing or duplicated"
            )
        if "llama_eval_runs" not in internals:
            validation_errors.append(
                "required llama.cpp eval count telemetry is missing"
            )
        else:
            expected_eval_runs = 1 if completion_tokens == 1 else completion_tokens - 1
            actual = internals["llama_eval_runs"]
            if actual != expected_eval_runs:
                validation_errors.append(
                    f"llama.cpp eval count was {actual}, expected {expected_eval_runs} for {completion_tokens} completions"
                )
        if internals.get("llama_eval_telemetry_line_count") != 1:
            validation_errors.append(
                "llama.cpp eval telemetry is missing or duplicated"
            )
        if (
            internals.get("llama_eval_tokens_per_second_status")
            == "invalid_non_finite"
        ):
            validation_errors.append(
                "llama.cpp infinite eval throughput is valid only for a 0 ms, one-run measurement"
            )
        paired_prepared = (
            "--require-prepared-image" in config["engines"]["glacier"]["argv"]
        )
        if (
            paired_prepared
            and internals.get("llama_model_ready_telemetry_line_count") != 1
        ):
            validation_errors.append(
                "llama.cpp model-ready telemetry is missing or duplicated"
            )

    success = (
        process["exit_status"] == 0
        and process["launch_error"] is None
        and time_metrics["peak_rss_bytes"] is not None
        and completion_result.get("error") is None
        and (
            deferred_completion is not None
            or completion_result.get("comparison_sha256") is not None
        )
        and not validation_errors
    )
    sample = {
        **dict(schedule_entry),
        "warmup": warmup,
        "success": success,
        "cache_regime": CACHE_REGIME,
        "fresh_process": True,
        "argv": argv,
        "timed_argv": timed_argv,
        "cwd": str(cwd),
        "configured_env": command["env"],
        "effective_environment": environment_snapshot(env),
        "stdin": command["stdin"],
        "exit_status": process["exit_status"],
        "timed_out": process["timed_out"],
        "launch_error": process["launch_error"],
        "stdout_sha256": sha256_bytes(stdout),
        "stderr_sha256": sha256_bytes(stderr),
        "raw_stdout": stdout_text,
        "raw_stderr": stderr_text,
        "time_l_evidence": {
            "output_path": str(time_output_path),
            "output_bytes": len(time_output),
            "output_sha256": sha256_bytes(time_output),
            "raw_output": time_output_text,
            "created_file_identity": time_output_created_identity,
            "observed_file_identity": time_output_identity,
            "validation_errors": time_evidence_errors,
        },
        "completion": completion_result,
        "completion_validation_pending": deferred_completion is not None,
        "validation_errors": validation_errors,
        "metrics": metrics,
    }
    if deferred_completion is not None:
        deferred_completion["sample"] = sample
        deferred_completion_queue.append(deferred_completion)
    return sample


def finalize_deferred_completions(
    queue: Sequence[Mapping[str, Any]], completion_tokens: int
) -> list[dict[str, Any]]:
    """Run raw-text tokenization only after every timed observation has ended."""

    failures: list[dict[str, Any]] = []
    for record in queue:
        sample = record["sample"]
        completion = sample["completion"]
        try:
            ids, extractor_result = _run_completion_extractor(
                record["config"],
                record["extractor"],
                record["extractor_input"],
                record["canonical"],
                record["expected_pinned_ids"],
                record["canonical_path"],
                record["pinned_ids_path"],
                record["runtime_fixture"],
                record["artifact_fingerprints"],
                record["sample_dir"],
                record["engine"],
                record["engine_sample_index"],
            )
        except (HarnessError, OSError) as exc:
            ids = None
            extractor_result = {
                "error": f"deferred completion extractor failed closed: {exc}"
            }
        completion["token_id_extractor"] = extractor_result
        completion["validation_pending"] = False
        completion["extraction_timing"] = "after-all-timed-observations"
        validation_errors: list[str] = []
        if ids is None:
            error = extractor_result.get(
                "error", "deferred completion token-ID extraction failed"
            )
            completion["error"] = error
            validation_errors.append(error)
        else:
            normalized = _canonical_ids_bytes(ids)
            completion.update(
                {
                    "token_count": len(ids),
                    "token_ids": ids,
                    "normalized_sha256": sha256_bytes(normalized),
                    "comparison_sha256": sha256_bytes(normalized),
                    "error": None,
                }
            )
            if len(ids) != completion_tokens:
                validation_errors.append(
                    f"completion token count was {len(ids)}, "
                    f"expected {completion_tokens}"
                )
        sample["completion_validation_pending"] = False
        sample["validation_errors"].extend(validation_errors)
        sample["success"] = bool(sample["success"]) and not validation_errors
        if validation_errors:
            failures.append(
                {
                    "sequence_index": sample["sequence_index"],
                    "engine": sample["engine"],
                    "warmup": sample["warmup"],
                    "validation_errors": validation_errors,
                }
            )
    return failures


def percentile(values: Sequence[float | int], probability: float) -> float:
    if not values:
        raise HarnessError("cannot calculate a percentile of an empty sequence")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def distribution_summary(values: Sequence[float | int]) -> dict[str, Any]:
    return {
        "n": len(values),
        "median": float(statistics.median(values)),
        "p5": percentile(values, 0.05),
        "p95": percentile(values, 0.95),
        "min": float(min(values)),
        "max": float(max(values)),
    }


RATIO_METRICS = {
    "wall_seconds": "lower",
    "peak_rss_bytes": "lower",
    "effective_completion_tokens_per_second": "higher",
    "internal_completion_ms": "lower",
    "internal_completion_tokens_per_second": "higher",
    "model_ready_ms": "lower",
    "non_internal_seconds": "lower",
    "prefill_phase_ms": "lower",
    "prefill_tokens_per_second": "higher",
    "decode_phase_ms": "lower",
    "decode_graph_tokens_per_second": "higher",
}


def _ratio(glacier: Sequence[float], llama: Sequence[float], direction: str) -> float:
    glacier_median = float(statistics.median(glacier))
    llama_median = float(statistics.median(llama))
    if glacier_median <= 0 or llama_median <= 0:
        raise HarnessError("ratio inputs must be positive")
    return (
        llama_median / glacier_median
        if direction == "lower"
        else glacier_median / llama_median
    )


def paired_bootstrap_ratio(
    samples: Sequence[Mapping[str, Any]],
    metric: str,
    direction: str,
    *,
    resamples: int,
    seed: int,
    confidence: float,
) -> dict[str, Any] | None:
    blocks: dict[int, dict[str, list[float]]] = {}
    for sample in samples:
        value = sample["metrics"].get(metric)
        if value is None or float(value) <= 0:
            return None
        block = blocks.setdefault(
            int(sample["block_index"]), {name: [] for name in ENGINE_NAMES}
        )
        block[sample["engine"]].append(float(value))
    if not blocks or any(
        len(item[name]) != 2 for item in blocks.values() for name in ENGINE_NAMES
    ):
        return None
    ordered_blocks = [blocks[index] for index in sorted(blocks)]
    glacier_all = [value for block in ordered_blocks for value in block["glacier"]]
    llama_all = [value for block in ordered_blocks for value in block["llama"]]
    point = _ratio(glacier_all, llama_all, direction)
    metric_seed = int.from_bytes(
        hashlib.sha256(metric.encode("utf-8")).digest()[:8], "big"
    )
    rng = random.Random(seed ^ metric_seed)
    bootstrapped: list[float] = []
    block_count = len(ordered_blocks)
    for _ in range(resamples):
        glacier: list[float] = []
        llama: list[float] = []
        for _ in range(block_count):
            block = ordered_blocks[rng.randrange(block_count)]
            glacier.extend(block["glacier"])
            llama.extend(block["llama"])
        bootstrapped.append(_ratio(glacier, llama, direction))
    alpha = (1.0 - confidence) / 2.0
    return {
        "estimate": point,
        "ci_low": percentile(bootstrapped, alpha),
        "ci_high": percentile(bootstrapped, 1.0 - alpha),
        "confidence": confidence,
        "favorable_to_glacier_above": 1.0,
        "direction": (
            "llama_median / glacier_median"
            if direction == "lower"
            else "glacier_median / llama_median"
        ),
        "method": "deterministic paired block bootstrap of median ratio",
        "paired_blocks": block_count,
        "resamples": resamples,
        "seed": seed ^ metric_seed,
    }


def summarize_samples(
    config: Mapping[str, Any], samples: Sequence[Mapping[str, Any]]
) -> dict[str, Any]:
    per_engine: dict[str, Any] = {}
    for engine in ENGINE_NAMES:
        engine_samples = [sample for sample in samples if sample["engine"] == engine]
        metric_names = (
            sorted(
                set.intersection(
                    *(
                        {
                            key
                            for key, value in sample["metrics"].items()
                            if isinstance(value, (int, float)) and value is not None
                        }
                        for sample in engine_samples
                    )
                )
            )
            if engine_samples
            else []
        )
        metric_summaries = {
            metric: distribution_summary(
                [sample["metrics"][metric] for sample in engine_samples]
            )
            for metric in metric_names
        }
        hashes = sorted(
            {
                sample["completion"].get("comparison_sha256")
                for sample in engine_samples
                if sample["completion"].get("comparison_sha256") is not None
            }
        )
        id_lists = [sample["completion"].get("token_ids") for sample in engine_samples]
        ids_are_stable = bool(id_lists) and all(
            ids is not None and ids == id_lists[0] for ids in id_lists
        )
        per_engine[engine] = {
            "sample_count": len(engine_samples),
            "metrics": metric_summaries,
            "completion_hashes": hashes,
            "completion_is_stable": ids_are_stable,
            "stability_comparison": "full normalized token-ID lists",
        }
    stats_cfg = config["statistics"]
    ratios: dict[str, Any] = {}
    for metric, direction in RATIO_METRICS.items():
        result = paired_bootstrap_ratio(
            samples,
            metric,
            direction,
            resamples=stats_cfg["bootstrap_resamples"],
            seed=stats_cfg["bootstrap_seed"],
            confidence=stats_cfg["confidence"],
        )
        if result is not None:
            ratios[metric] = result
    equivalence_mode = config["workload"]["completion_equivalence"]
    stable = all(per_engine[engine]["completion_is_stable"] for engine in ENGINE_NAMES)
    exact_match: bool | None = None
    first_difference: dict[str, Any] | None = None
    if equivalence_mode == "exact-token-ids" and stable:
        representative = {
            engine: next(
                sample["completion"]["token_ids"]
                for sample in samples
                if sample["engine"] == engine
            )
            for engine in ENGINE_NAMES
        }
        first_difference = _first_difference(
            representative["glacier"], representative["llama"]
        )
        exact_match = first_difference is None
    equivalence = {
        "mode": equivalence_mode,
        "each_engine_is_stable": stable,
        "cross_engine_token_ids_compared": equivalence_mode == "exact-token-ids",
        "cross_engine_token_ids_match": exact_match,
        "first_cross_engine_difference": first_difference,
        "performance_only": equivalence_mode == "stable-only",
        "output_equivalence_certified": equivalence_mode == "exact-token-ids"
        and exact_match is True,
        # One completion fixture can certify its own output boundary, not the
        # model's broader quality. Held-out PPL/KLD/task gates are separate.
        "quality_certified": False,
        "note": (
            "Stable-only mode verifies deterministic exact token counts per engine but does not "
            "claim cross-quantization output equivalence or quality certification."
            if equivalence_mode == "stable-only"
            else "Exact mode requires native generated-ID lists to match for this fixture; "
            "it does not replace held-out PPL/KLD/task quality gates."
        ),
    }
    return {
        "per_engine": per_engine,
        "glacier_advantage_ratios": ratios,
        "completion_equivalence": equivalence,
        "percentile_method": "linear interpolation at rank (n - 1) * p",
    }


def _probe_command(
    argv: Sequence[str], timeout_seconds: float
) -> tuple[str, dict[str, Any]]:
    """Run a read-only host probe and return parsed text plus auditable provenance."""

    started_at = dt.datetime.now(dt.timezone.utc).isoformat()
    started = time.perf_counter_ns()
    try:
        completed = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"LC_ALL": "C", "PATH": os.defpath},
            timeout=timeout_seconds,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HarnessError(f"machine-state probe {argv[0]} failed: {exc}") from exc
    elapsed = (time.perf_counter_ns() - started) / 1e9
    stdout = completed.stdout
    stderr = completed.stderr
    evidence = {
        "argv": list(argv),
        "started_at_utc": started_at,
        "finished_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "exit_status": completed.returncode,
        "elapsed_seconds": elapsed,
        "stdout_bytes": len(stdout),
        "stdout_sha256": sha256_bytes(stdout),
        "stderr_bytes": len(stderr),
        "stderr_sha256": sha256_bytes(stderr),
    }
    if completed.returncode != 0:
        message = _decode_log(stderr).strip()
        raise HarnessError(
            f"machine-state probe {' '.join(argv)} exited {completed.returncode}: {message}"
        )
    return _decode_log(stdout), evidence


def parse_pmset_power(battery_text: str, custom_text: str) -> dict[str, Any]:
    source_match = re.search(r"Now drawing from '([^']+)'", battery_text)
    if source_match is None:
        raise HarnessError("pmset did not report the active power source")
    source = source_match.group(1).strip()

    battery_match = re.search(
        r"(?m)^\s*-[^\n]*?\s+(\d{1,3})%;\s*([^;\n]+);[^\n]*present:\s*(true|false)",
        battery_text,
        re.IGNORECASE,
    )
    if battery_match is None and "InternalBattery" in battery_text:
        raise HarnessError(
            "pmset reported an InternalBattery line that could not be parsed"
        )
    if battery_match is None:
        battery_present = False
        battery_percent: int | None = None
        battery_status: str | None = None
    else:
        battery_present = battery_match.group(3).lower() == "true"
        battery_percent = int(battery_match.group(1))
        if not 0 <= battery_percent <= 100:
            raise HarnessError("pmset reported an invalid battery percentage")
        battery_status = battery_match.group(2).strip().lower()

    active_section: str | None = None
    active_settings: dict[str, str] = {}
    for line in custom_text.splitlines():
        section_match = re.fullmatch(r"([^\s].* Power):", line.rstrip())
        if section_match is not None:
            active_section = section_match.group(1)
            continue
        if active_section == source:
            setting_match = re.fullmatch(r"\s*(\S+)\s+(.+?)\s*", line)
            if setting_match is not None:
                active_settings[setting_match.group(1).lower()] = setting_match.group(
                    2
                )
    low_power_text = active_settings.get("lowpowermode")
    if low_power_text is None or re.fullmatch(r"\d+", low_power_text) is None:
        raise HarnessError(
            f"pmset did not report lowpowermode for active source {source!r}"
        )
    low_power_mode = int(low_power_text)
    normalized_settings = dict(sorted(active_settings.items()))
    settings_bytes = json.dumps(
        normalized_settings, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "source": source,
        "on_ac_power": source == "AC Power",
        "battery_present": battery_present,
        "battery_percent": battery_percent,
        "battery_status": battery_status,
        "battery_full": battery_percent == 100 if battery_present else None,
        "low_power_mode": low_power_mode,
        "active_settings": normalized_settings,
        "active_settings_sha256": sha256_bytes(settings_bytes),
    }


def parse_pmset_thermal(text: str, logical_cpu_count: int | None) -> dict[str, Any]:
    """Parse throttle signals from pmset; this deliberately does not infer temperature."""

    values: dict[str, int] = {}
    for name in ("CPU_Scheduler_Limit", "CPU_Available_CPUs", "CPU_Speed_Limit"):
        match = re.search(rf"(?m)^\s*{name}\s*=\s*(\d+)\s*$", text)
        if match is not None:
            values[name] = int(match.group(1))
    available = bool(values)
    constrained = False
    if available:
        constrained = (
            values.get("CPU_Scheduler_Limit", 100) < 100
            or values.get("CPU_Speed_Limit", 100) < 100
            or (
                logical_cpu_count is not None
                and "CPU_Available_CPUs" in values
                and values["CPU_Available_CPUs"] < logical_cpu_count
            )
        )
    return {
        "signal_available": available,
        "constrained": constrained if available else None,
        "status": "constrained"
        if constrained
        else ("nominal" if available else "unavailable"),
        "signals": values,
        "temperature_measured": False,
    }


def parse_vm_stat(text: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for output_name, source_name in (
        ("pageouts", "Pageouts"),
        ("swapins", "Swapins"),
        ("swapouts", "Swapouts"),
    ):
        match = re.search(rf'(?m)^"?{source_name}"?:\s+(\d+)\.\s*$', text)
        if match is None:
            raise HarnessError(f"vm_stat did not report {source_name}")
        result[output_name] = int(match.group(1))
    return result


def parse_top_state(text: str) -> tuple[list[float], list[float]]:
    load1 = [
        float(match.group(1))
        for match in re.finditer(r"(?m)^Load Avg:\s*([0-9]+(?:\.[0-9]+)?),", text)
    ]
    idle = [
        float(match.group(1))
        for match in re.finditer(
            r"(?m)^CPU usage:\s*[^\n]*?([0-9]+(?:\.[0-9]+)?)% idle\s*$",
            text,
        )
    ]
    if not load1 or not idle or len(load1) != len(idle):
        raise HarnessError("top did not report matched Load Avg and CPU usage samples")
    return load1, idle


def parse_external_cpu_processes(
    text: str,
    *,
    benchmark_pgid: int,
    harness_pid: int,
    sampler_pid: int,
    logical_cpu_count: int,
) -> dict[str, Any]:
    """Parse ``ps`` rows and isolate CPU use outside the benchmark process group.

    macOS ``ps pcpu`` is expressed as a percentage of one logical CPU.  The
    normalized capacity value therefore divides the sum by the host logical-CPU
    count.  It is a sampled, smoothed signal rather than exact scheduler-tick
    attribution; publication mode pairs it with the pre-window load/idle gate.
    """

    if logical_cpu_count <= 0:
        raise HarnessError("external CPU monitor requires a positive logical CPU count")
    external: list[dict[str, Any]] = []
    parsed_rows = 0
    excluded_rows = 0
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        match = re.fullmatch(
            r"\s*(\d+)\s+(\d+)\s+(\d+)\s+([0-9]+(?:\.[0-9]+)?)\s+(.+?)\s*",
            line,
        )
        if match is None:
            raise HarnessError(
                f"external CPU ps row {line_number} could not be parsed"
            )
        parsed_rows += 1
        pid = int(match.group(1))
        ppid = int(match.group(2))
        pgid = int(match.group(3))
        cpu_percent = float(match.group(4))
        if not math.isfinite(cpu_percent) or cpu_percent < 0.0:
            raise HarnessError(
                f"external CPU ps row {line_number} has invalid CPU percent"
            )
        if (
            pgid == benchmark_pgid
            or pid in (harness_pid, sampler_pid)
            or ppid == harness_pid
        ):
            excluded_rows += 1
            continue
        if cpu_percent > 0.0:
            external.append(
                {
                    "pid": pid,
                    "ppid": ppid,
                    "pgid": pgid,
                    "cpu_percent_of_one_logical_cpu": cpu_percent,
                    "command": match.group(5),
                }
            )
    if parsed_rows == 0:
        raise HarnessError("external CPU ps probe returned no process rows")
    external.sort(
        key=lambda row: float(row["cpu_percent_of_one_logical_cpu"]), reverse=True
    )
    external_sum = sum(
        float(row["cpu_percent_of_one_logical_cpu"]) for row in external
    )
    return {
        "parsed_process_rows": parsed_rows,
        "excluded_process_rows": excluded_rows,
        "external_active_process_rows": len(external),
        "external_cpu_percent_of_one_logical_cpu_sum": external_sum,
        "external_cpu_capacity_percent": external_sum / logical_cpu_count,
        "top_external_processes": external[:8],
    }


def _read_external_cpu_sample(
    *, benchmark_pgid: int, harness_pid: int, logical_cpu_count: int
) -> dict[str, Any]:
    """Collect one fail-closed external-process CPU sample with provenance."""

    argv = ["/bin/ps", "-A", "-o", "pid=,ppid=,pgid=,pcpu=,comm="]
    started_at = dt.datetime.now(dt.timezone.utc).isoformat()
    started = time.perf_counter_ns()
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"LC_ALL": "C", "PATH": os.defpath},
            shell=False,
        )
        stdout, stderr = process.communicate(timeout=5.0)
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        if process is not None:
            process.kill()
            stdout, stderr = process.communicate()
        else:
            stdout, stderr = b"", b""
        raise HarnessError("external CPU ps probe timed out") from exc
    except OSError as exc:
        raise HarnessError(f"external CPU ps probe failed: {exc}") from exc
    elapsed = (time.perf_counter_ns() - started) / 1e9
    assert process is not None
    provenance = {
        "argv": argv,
        "started_at_utc": started_at,
        "finished_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "elapsed_seconds": elapsed,
        "exit_status": process.returncode,
        "timed_out": timed_out,
        "stdout_bytes": len(stdout),
        "stdout_sha256": sha256_bytes(stdout),
        "stderr_bytes": len(stderr),
        "stderr_sha256": sha256_bytes(stderr),
    }
    if process.returncode != 0:
        raise HarnessError(
            "external CPU ps probe exited "
            f"{process.returncode}: {_decode_log(stderr).strip()}"
        )
    parsed = parse_external_cpu_processes(
        _decode_log(stdout),
        benchmark_pgid=benchmark_pgid,
        harness_pid=harness_pid,
        sampler_pid=process.pid,
        logical_cpu_count=logical_cpu_count,
    )
    return {**parsed, "provenance": provenance}


class ExternalCpuSampler:
    """Sample external process CPU while one benchmark process group runs."""

    def __init__(self, policy: Mapping[str, Any]):
        self.interval_seconds = float(policy["in_run_cpu_sample_interval_seconds"])
        self.logical_cpu_count = os.cpu_count() or 0
        self.harness_pid = os.getpid()
        self.benchmark_pgid: int | None = None
        self._samples: list[dict[str, Any]] = []
        self._errors: list[str] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._started_at_utc: str | None = None
        self._finished_at_utc: str | None = None
        self._shutdown_elapsed_seconds: float | None = None
        self._loop_exit_reason: str | None = None

    def start(self, benchmark_pgid: int) -> None:
        if self._thread is not None:
            self._errors.append("external CPU monitor was started more than once")
            return
        self.benchmark_pgid = int(benchmark_pgid)
        self._started_at_utc = dt.datetime.now(dt.timezone.utc).isoformat()
        self._thread = threading.Thread(
            target=self._sample_loop,
            name="glacier-external-cpu-sampler",
            daemon=True,
        )
        try:
            self._thread.start()
        except RuntimeError as exc:
            self._errors.append(f"external CPU monitor thread failed to start: {exc}")
            self._thread = None

    def _sample_loop(self) -> None:
        assert self.benchmark_pgid is not None
        next_sample = time.monotonic()
        try:
            while True:
                sample = _read_external_cpu_sample(
                    benchmark_pgid=self.benchmark_pgid,
                    harness_pid=self.harness_pid,
                    logical_cpu_count=self.logical_cpu_count,
                )
                self._samples.append(sample)
                next_sample += self.interval_seconds
                if self._stop.wait(max(0.0, next_sample - time.monotonic())):
                    self._loop_exit_reason = "requested-stop"
                    return
        except (HarnessError, ValueError) as exc:
            self._loop_exit_reason = "probe-error"
            self._errors.append(str(exc))
        except Exception as exc:  # fail closed on an unexpected worker failure
            self._loop_exit_reason = "unexpected-error"
            self._errors.append(
                "external CPU monitor worker failed unexpectedly: "
                f"{type(exc).__name__}: {exc}"
            )
        finally:
            if self._loop_exit_reason is None:
                self._loop_exit_reason = "abnormal-exit"
                self._errors.append(
                    "external CPU monitor worker exited without a terminal reason"
                )

    def request_stop(self) -> None:
        """Prevent new samples without blocking on a probe already in flight."""

        self._stop.set()

    def stop(self) -> dict[str, Any]:
        stop_started = time.perf_counter_ns()
        self.request_stop()
        if self._thread is None:
            self._errors.append(
                "external CPU monitor did not start because the child did not launch"
            )
        else:
            self._thread.join(timeout=7.0)
            if self._thread.is_alive():
                self._errors.append("external CPU monitor thread did not stop")
        self._finished_at_utc = dt.datetime.now(dt.timezone.utc).isoformat()
        self._shutdown_elapsed_seconds = (
            time.perf_counter_ns() - stop_started
        ) / 1e9
        return self.evidence()

    def evidence(self) -> dict[str, Any]:
        values = [
            float(sample["external_cpu_capacity_percent"])
            for sample in self._samples
        ]
        return {
            "monitor": "ps-pgid-exclusion/v1",
            "signal_semantics": (
                "sum of sampled ps pcpu outside the benchmark PGID, harness PID, "
                "direct harness probe children and sampler PID, divided by logical "
                "CPU count; pcpu is smoothed"
            ),
            "benchmark_pgid": self.benchmark_pgid,
            "harness_pid": self.harness_pid,
            "logical_cpu_count": self.logical_cpu_count,
            "sample_interval_seconds": self.interval_seconds,
            "started_at_utc": self._started_at_utc,
            "finished_at_utc": self._finished_at_utc,
            "shutdown_elapsed_seconds": self._shutdown_elapsed_seconds,
            "worker_exit_reason": self._loop_exit_reason,
            "sample_count": len(values),
            "external_cpu_capacity_percent_samples": values,
            "external_cpu_capacity_median_percent": (
                float(statistics.median(values)) if values else None
            ),
            "external_cpu_capacity_max_percent": max(values) if values else None,
            "samples": list(self._samples),
            "monitor_errors": list(self._errors),
        }


def external_cpu_observation_errors(
    evidence: Mapping[str, Any], policy: Mapping[str, Any]
) -> list[str]:
    errors = [
        f"in-run external CPU monitor: {message}"
        for message in evidence.get("monitor_errors", [])
    ]
    sample_count = int(evidence.get("sample_count", 0))
    required = int(policy["min_in_run_cpu_samples"])
    if sample_count < required:
        errors.append(
            f"in-run external CPU monitor retained {sample_count} samples, "
            f"minimum {required}"
        )
        return errors
    median = float(evidence["external_cpu_capacity_median_percent"])
    maximum = float(evidence["external_cpu_capacity_max_percent"])
    median_limit = float(policy["max_external_cpu_capacity_median_percent"])
    sample_limit = float(policy["max_external_cpu_capacity_sample_percent"])
    if median > median_limit:
        errors.append(
            f"in-run external CPU median was {median:.6g}%, "
            f"limit {median_limit:.6g}%"
        )
    if maximum > sample_limit:
        errors.append(
            f"in-run external CPU maximum was {maximum:.6g}%, "
            f"limit {sample_limit:.6g}%"
        )
    return errors


def external_cpu_envelope(evidence: Mapping[str, Any]) -> dict[str, float]:
    return {
        "external_cpu_capacity_median_percent": float(
            evidence["external_cpu_capacity_median_percent"]
        ),
        "external_cpu_capacity_max_percent": float(
            evidence["external_cpu_capacity_max_percent"]
        ),
    }


def matched_external_cpu_errors(
    anchor: Mapping[str, Any], candidate: Mapping[str, Any], policy: Mapping[str, Any]
) -> list[str]:
    errors: list[str] = []
    for key, policy_key in (
        (
            "external_cpu_capacity_median_percent",
            "max_matched_external_cpu_capacity_median_delta",
        ),
        (
            "external_cpu_capacity_max_percent",
            "max_matched_external_cpu_capacity_max_delta",
        ),
    ):
        delta = abs(float(anchor[key]) - float(candidate[key]))
        limit = float(policy[policy_key])
        if delta > limit:
            errors.append(
                f"matched state: {key} delta {delta:.6g}% exceeds {limit:.6g}%"
            )
    return errors


def _read_power_state() -> dict[str, Any]:
    battery_text, battery_probe = _probe_command(["/usr/bin/pmset", "-g", "batt"], 10.0)
    custom_text, custom_probe = _probe_command(["/usr/bin/pmset", "-g", "custom"], 10.0)
    return {
        **parse_pmset_power(battery_text, custom_text),
        "provenance": {"battery": battery_probe, "settings": custom_probe},
    }


def _read_thermal_state() -> dict[str, Any]:
    text, probe = _probe_command(["/usr/bin/pmset", "-g", "therm"], 10.0)
    return {
        **parse_pmset_thermal(text, os.cpu_count()),
        "provenance": probe,
    }


def _read_vm_state() -> dict[str, Any]:
    text, probe = _probe_command(["/usr/bin/vm_stat"], 10.0)
    return {**parse_vm_stat(text), "provenance": probe}


def _counter_deltas(
    before: Mapping[str, Any], after: Mapping[str, Any]
) -> dict[str, int]:
    return {
        name: int(after[name]) - int(before[name])
        for name in ("pageouts", "swapins", "swapouts")
    }


def collect_machine_state_admission(policy: Mapping[str, Any]) -> dict[str, Any]:
    """Sample a quiet window immediately before one benchmark observation."""

    started_at = dt.datetime.now(dt.timezone.utc).isoformat()
    power_before = _read_power_state()
    thermal_before = _read_thermal_state()
    vm_before = _read_vm_state()
    interval = float(policy["sample_interval_seconds"])
    requested_window = float(policy["window_seconds"])
    top_iterations = max(2, math.ceil(requested_window / interval) + 1)
    effective_window = (top_iterations - 1) * interval
    top_text, top_probe = _probe_command(
        [
            "/usr/bin/top",
            "-l",
            str(top_iterations),
            "-s",
            f"{interval:g}",
            "-n",
            "0",
        ],
        effective_window + 30.0,
    )
    load1, idle = parse_top_state(top_text)
    if len(load1) < top_iterations:
        raise HarnessError(
            f"top returned {len(load1)} samples, expected {top_iterations}"
        )
    # The first top report is an initialization sample; the following reports
    # cover the requested interval window.
    load1 = load1[-(top_iterations - 1) :]
    idle = idle[-(top_iterations - 1) :]
    vm_after = _read_vm_state()
    thermal_after = _read_thermal_state()
    power_after = _read_power_state()
    return {
        "schema": MACHINE_STATE_SCHEMA,
        "started_at_utc": started_at,
        "finished_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "window": {
            "requested_seconds": requested_window,
            "effective_seconds": effective_window,
            "sample_interval_seconds": interval,
            "sample_count": len(load1),
            "load1_samples": load1,
            "load1_median": float(statistics.median(load1)),
            "load1_max": max(load1),
            "cpu_idle_percent_samples": idle,
            "cpu_idle_median_percent": float(statistics.median(idle)),
            "cpu_idle_min_percent": min(idle),
            "provenance": top_probe,
        },
        "before": {
            "power": power_before,
            "thermal": thermal_before,
            "vm": vm_before,
        },
        "after": {
            "power": power_after,
            "thermal": thermal_after,
            "vm": vm_after,
        },
        "window_vm_deltas": _counter_deltas(vm_before, vm_after),
    }


def collect_machine_state_post_observation() -> dict[str, Any]:
    return {
        "collected_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "thermal": _read_thermal_state(),
        "power": _read_power_state(),
        "vm": _read_vm_state(),
    }


def _power_state_errors(power: Mapping[str, Any], where: str) -> list[str]:
    errors: list[str] = []
    if power.get("on_ac_power") is not True:
        errors.append(f"{where}: active power source is not AC Power")
    if power.get("low_power_mode") != 0:
        errors.append(f"{where}: low-power mode is not off")
    if power.get("battery_present") and power.get("battery_full") is not True:
        errors.append(f"{where}: battery is present but not at 100%")
    battery_status = power.get("battery_status")
    if isinstance(battery_status, str) and "discharging" in battery_status.lower():
        errors.append(f"{where}: battery reports discharging")
    return errors


def _thermal_state_errors(thermal: Mapping[str, Any], where: str) -> list[str]:
    if thermal.get("signal_available") and thermal.get("constrained") is not False:
        return [f"{where}: pmset reports a constrained CPU thermal/power signal"]
    return []


def machine_state_admission_errors(
    admission: Mapping[str, Any], policy: Mapping[str, Any]
) -> list[str]:
    errors: list[str] = []
    for boundary in ("before", "after"):
        errors.extend(_power_state_errors(admission[boundary]["power"], boundary))
        errors.extend(_thermal_state_errors(admission[boundary]["thermal"], boundary))
    before_power = admission["before"]["power"]
    after_power = admission["after"]["power"]
    for key in (
        "source",
        "battery_present",
        "battery_full",
        "battery_status",
        "low_power_mode",
        "active_settings_sha256",
    ):
        if before_power.get(key) != after_power.get(key):
            errors.append(f"admission window: power field {key} changed")
    if admission["before"]["thermal"].get("status") != admission["after"][
        "thermal"
    ].get("status"):
        errors.append("admission window: thermal constraint status changed")
    for name, delta in admission["window_vm_deltas"].items():
        if delta != 0:
            errors.append(f"admission window: {name} delta was {delta}, expected 0")
    window = admission["window"]
    if float(window["load1_max"]) > float(policy["max_load1"]):
        errors.append(
            f"admission window: max load1 was {window['load1_max']}, "
            f"limit {policy['max_load1']}"
        )
    if float(window["cpu_idle_median_percent"]) < float(
        policy["min_cpu_idle_median_percent"]
    ):
        errors.append(
            "admission window: median CPU idle was "
            f"{window['cpu_idle_median_percent']}%, minimum "
            f"{policy['min_cpu_idle_median_percent']}%"
        )
    if float(window["cpu_idle_min_percent"]) < float(
        policy["min_cpu_idle_sample_percent"]
    ):
        errors.append(
            f"admission window: minimum CPU idle was {window['cpu_idle_min_percent']}%, "
            f"minimum {policy['min_cpu_idle_sample_percent']}%"
        )
    return errors


def machine_state_envelope(admission: Mapping[str, Any]) -> dict[str, Any]:
    power = admission["after"]["power"]
    thermal = admission["after"]["thermal"]
    window = admission["window"]
    return {
        "power_source": power["source"],
        "battery_present": power["battery_present"],
        "battery_full": power["battery_full"],
        "battery_status": power["battery_status"],
        "low_power_mode": power["low_power_mode"],
        "active_settings_sha256": power["active_settings_sha256"],
        "thermal_status": thermal["status"],
        "load1_median": window["load1_median"],
        "load1_max": window["load1_max"],
        "cpu_idle_median_percent": window["cpu_idle_median_percent"],
    }


def matched_machine_state_errors(
    anchor: Mapping[str, Any], candidate: Mapping[str, Any], policy: Mapping[str, Any]
) -> list[str]:
    errors: list[str] = []
    for key in (
        "power_source",
        "battery_present",
        "battery_full",
        "battery_status",
        "low_power_mode",
        "active_settings_sha256",
        "thermal_status",
    ):
        if anchor.get(key) != candidate.get(key):
            errors.append(
                f"matched state: {key} differs from paired engine observation"
            )
    load_limit = float(policy["max_matched_load1_delta"])
    for key in ("load1_median", "load1_max"):
        delta = abs(float(anchor[key]) - float(candidate[key]))
        if delta > load_limit:
            errors.append(f"matched state: {key} delta {delta} exceeds {load_limit}")
    idle_delta = abs(
        float(anchor["cpu_idle_median_percent"])
        - float(candidate["cpu_idle_median_percent"])
    )
    idle_limit = float(policy["max_matched_cpu_idle_median_delta"])
    if idle_delta > idle_limit:
        errors.append(
            f"matched state: CPU idle median delta {idle_delta}% exceeds {idle_limit}%"
        )
    return errors


def observation_contamination_errors(
    admission: Mapping[str, Any], post: Mapping[str, Any]
) -> tuple[list[str], dict[str, int]]:
    errors = _power_state_errors(post["power"], "post-observation")
    errors.extend(_thermal_state_errors(post["thermal"], "post-observation"))
    admitted_power = admission["after"]["power"]
    for key in (
        "source",
        "battery_present",
        "battery_full",
        "battery_status",
        "low_power_mode",
        "active_settings_sha256",
    ):
        if admitted_power.get(key) != post["power"].get(key):
            errors.append(f"observation: power field {key} changed")
    if admission["after"]["thermal"].get("status") != post["thermal"].get("status"):
        errors.append("observation: thermal constraint status changed")
    deltas = _counter_deltas(admission["after"]["vm"], post["vm"])
    for name, delta in deltas.items():
        if delta != 0:
            errors.append(f"observation: {name} delta was {delta}, expected 0")
    return errors, deltas


def _host_info() -> dict[str, Any]:
    return {
        "platform": platform.platform(),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "logical_cpu_count": os.cpu_count(),
        "python": sys.version,
    }


def _base_result(
    config: Mapping[str, Any],
    fixture: Mapping[str, Any],
    schedule: Sequence[Mapping[str, Any]],
    mode: str,
) -> dict[str, Any]:
    return {
        "schema": "glacier.paired-bench/result-v1",
        "status": "pending",
        "mode": mode,
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "benchmark_name": config["name"],
        "cache_regime": CACHE_REGIME,
        "cache_policy": {
            "fresh_process_per_observation": True,
            "os_cache_is_warm": True,
            "drop_caches_attempted": False,
            "note": "No cache purge or drop-cache operation exists in this harness.",
        },
        "environment_policy": {
            "inherited_allowlist": list(INHERITED_ENV_ALLOWLIST),
            "performance_environment_must_be_manifest_declared": True,
            "relevant_prefixes_recorded": list(PERFORMANCE_ENV_PREFIXES),
        },
        "machine_state_policy": {
            "schema": MACHINE_STATE_SCHEMA,
            "resolved": config["machine_state"],
            "timed_comparison_publication_eligible": False,
            "note": (
                "Every timed observation is admitted independently and adjacent "
                "cross-engine observations are matched. External process CPU is "
                "sampled during each timed child with benchmark-PGID exclusion. "
                "Actual CPU temperature and frequency are not measured."
                if config["machine_state"]["mode"] == "publishable"
                else "Machine-state admission was explicitly disabled; timed results are not publication eligible."
            ),
        },
        "host": _host_info(),
        "raw_manifest": config["raw_manifest"],
        "resolved_manifest": {
            key: value for key, value in config.items() if key not in {"raw_manifest"}
        },
        "fixture": dict(fixture),
        "schedule": list(schedule),
        "samples": [],
    }


def dry_run(config: Mapping[str, Any]) -> dict[str, Any]:
    canonical, _pinned_ids, fixture = load_fixture(config)
    schedule = build_schedule(config["samples_per_engine"], config["schedule_seed"])
    result = _base_result(config, fixture, schedule, "dry-run")
    fake_root = Path(tempfile.gettempdir()) / "glacier-paired-abba-dry-run"
    canonical_path = fake_root / "canonical.txt"
    pinned_ids_path = fake_root / "pinned-token-ids.txt"
    commands: dict[str, Any] = {"tokenizer_preflight": {}, "engines": {}}
    for section in commands:
        names = TOKENIZER_NAMES if section == "tokenizer_preflight" else ENGINE_NAMES
        for name in names:
            command = config[section][name]
            sample_dir = fake_root / f"sample-{name}-000"
            argv, cwd, effective_env, _context = expand_command(
                config,
                command,
                canonical_path,
                pinned_ids_path,
                sample_dir,
                name,
                0,
            )
            commands[section][name] = {
                "argv": argv,
                "cwd": str(cwd),
                "configured_env": command["env"],
                "effective_environment": environment_snapshot(effective_env),
                "stdin": command["stdin"],
                "would_execute": False,
            }
            extractor = command.get("completion", {}).get("token_id_extractor")
            if extractor is not None:
                extractor_argv, extractor_cwd, _extractor_env, _ = expand_command(
                    config,
                    extractor,
                    canonical_path,
                    pinned_ids_path,
                    sample_dir / "completion-extractor",
                    name,
                    0,
                )
                commands[section][name]["completion_token_id_extractor"] = {
                    "argv": extractor_argv,
                    "cwd": str(extractor_cwd),
                    "would_execute": False,
                }
    result["dry_run_commands"] = commands
    result["canonical_text_preview_bytes"] = len(canonical)
    result["status"] = "passed"
    return result


def _machine_state_failure_sample(
    schedule_entry: Mapping[str, Any],
    *,
    warmup: bool,
    evidence: Mapping[str, Any],
    errors: Sequence[str],
) -> dict[str, Any]:
    return {
        **dict(schedule_entry),
        "warmup": warmup,
        "success": False,
        "not_executed": True,
        "validation_errors": list(errors),
        "machine_state": dict(evidence),
    }


def run_machine_gated_sample(
    config: Mapping[str, Any],
    canonical: bytes,
    canonical_path: Path,
    pinned_ids_path: Path,
    expected_pinned_ids: Sequence[int],
    runtime_fixture: Mapping[str, Any],
    artifact_fingerprints: Mapping[str, Any],
    sample_dir: Path,
    schedule_entry: Mapping[str, Any],
    *,
    warmup: bool,
    match_anchor: Mapping[str, Any] | None,
    deferred_completion_queue: list[dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    policy = config["machine_state"]
    if policy["mode"] == "disabled":
        sample = run_timed_sample(
            config,
            canonical,
            canonical_path,
            pinned_ids_path,
            expected_pinned_ids,
            runtime_fixture,
            artifact_fingerprints,
            sample_dir,
            schedule_entry,
            warmup=warmup,
            deferred_completion_queue=deferred_completion_queue,
        )
        sample["machine_state"] = {
            "schema": MACHINE_STATE_SCHEMA,
            "mode": "disabled",
            "publication_eligible": False,
        }
        return sample, None

    try:
        admission = collect_machine_state_admission(policy)
    except HarnessError as exc:
        evidence = {
            "schema": MACHINE_STATE_SCHEMA,
            "mode": "publishable",
            "admitted": False,
            "probe_error": str(exc),
        }
        return (
            _machine_state_failure_sample(
                schedule_entry,
                warmup=warmup,
                evidence=evidence,
                errors=[f"machine-state admission probe failed closed: {exc}"],
            ),
            None,
        )

    envelope = machine_state_envelope(admission)
    errors = machine_state_admission_errors(admission, policy)
    pair_match: dict[str, Any]
    if match_anchor is None:
        pair_match = {"role": "anchor", "matched": None}
    else:
        match_errors: list[str] = []
        if match_anchor["engine"] == schedule_entry["engine"]:
            match_errors.append(
                "matched state: adjacent observations must use different engines"
            )
        if int(match_anchor["sequence_index"]) + 1 != int(
            schedule_entry["sequence_index"]
        ):
            match_errors.append(
                "matched state: engine observations are not adjacent in the schedule"
            )
        match_errors.extend(
            matched_machine_state_errors(match_anchor["envelope"], envelope, policy)
        )
        errors.extend(match_errors)
        pair_match = {
            "role": "candidate",
            "matched": not match_errors,
            "anchor_sequence_index": match_anchor["sequence_index"],
            "anchor_engine": match_anchor["engine"],
            "anchor_envelope": match_anchor["envelope"],
        }
    machine_evidence: dict[str, Any] = {
        "schema": MACHINE_STATE_SCHEMA,
        "mode": "publishable",
        "admitted": not errors,
        "admission": admission,
        "envelope": envelope,
        "pair_match": pair_match,
        "admission_errors": list(errors),
    }
    if errors:
        return (
            _machine_state_failure_sample(
                schedule_entry,
                warmup=warmup,
                evidence=machine_evidence,
                errors=errors,
            ),
            None,
        )

    post_capture: dict[str, Any] = {"hook_called": False}

    def capture_immediate_post_state() -> None:
        post_capture["hook_called"] = True
        try:
            post_capture["post"] = collect_machine_state_post_observation()
        except (HarnessError, OSError) as exc:
            post_capture["probe_error"] = str(exc)

    external_cpu_sampler = ExternalCpuSampler(policy)
    sample = run_timed_sample(
        config,
        canonical,
        canonical_path,
        pinned_ids_path,
        expected_pinned_ids,
        runtime_fixture,
        artifact_fingerprints,
        sample_dir,
        schedule_entry,
        warmup=warmup,
        process_observer=external_cpu_sampler,
        after_timed_child=capture_immediate_post_state,
        deferred_completion_queue=deferred_completion_queue,
    )
    in_run_cpu = external_cpu_sampler.evidence()
    in_run_cpu_errors = external_cpu_observation_errors(in_run_cpu, policy)
    in_run_cpu.update(
        {
            "passed": not in_run_cpu_errors,
            "validation_errors": list(in_run_cpu_errors),
        }
    )
    contamination_errors = list(in_run_cpu_errors)
    vm_deltas: dict[str, int] | None = None
    post = post_capture.get("post")
    if post is not None:
        contamination_errors, vm_deltas = observation_contamination_errors(
            admission, post
        )
        contamination_errors = [*in_run_cpu_errors, *contamination_errors]
    elif "probe_error" in post_capture:
        contamination_errors.append(
            "post-observation machine-state probe failed closed: "
            f"{post_capture['probe_error']}"
        )
    else:
        contamination_errors.append(
            "post-observation machine-state hook did not run immediately after "
            "the timed child"
        )

    in_run_match_errors: list[str] = []
    if match_anchor is not None:
        pair_match["pre_observation_matched"] = pair_match["matched"]
        pair_match["anchor_in_run_cpu_envelope"] = match_anchor[
            "in_run_cpu_envelope"
        ]
        if in_run_cpu_errors:
            pair_match["in_run_external_cpu_matched"] = False
            pair_match["matched"] = False
        else:
            in_run_match_errors = matched_external_cpu_errors(
                match_anchor["in_run_cpu_envelope"],
                external_cpu_envelope(in_run_cpu),
                policy,
            )
            contamination_errors.extend(in_run_match_errors)
            pair_match["in_run_external_cpu_matched"] = not in_run_match_errors
            pair_match["matched"] = (
                bool(pair_match["matched"]) and not in_run_match_errors
            )

    machine_evidence.update(
        {
            "in_run_external_cpu": in_run_cpu,
            "post_observation_hook_called": bool(post_capture["hook_called"]),
            "observation_vm_deltas": vm_deltas,
            "observation_contaminated": bool(contamination_errors),
            "contamination_errors": contamination_errors,
            "publication_eligible": not contamination_errors,
        }
    )
    if post is not None:
        machine_evidence["post_observation"] = post
    if "probe_error" in post_capture:
        machine_evidence["post_observation_probe_error"] = post_capture[
            "probe_error"
        ]
    sample["machine_state"] = machine_evidence
    if contamination_errors:
        sample["validation_errors"].extend(contamination_errors)
        sample["success"] = False
    new_anchor = (
        {
            "sequence_index": schedule_entry["sequence_index"],
            "engine": schedule_entry["engine"],
            "envelope": envelope,
            "in_run_cpu_envelope": external_cpu_envelope(in_run_cpu),
        }
        if match_anchor is None and sample["success"]
        else None
    )
    return sample, new_anchor


def run_harness(config: Mapping[str, Any], *, preflight_only: bool) -> dict[str, Any]:
    canonical, pinned_ids, fixture = load_fixture(config)
    schedule = build_schedule(config["samples_per_engine"], config["schedule_seed"])
    mode = "preflight-only" if preflight_only else "benchmark"
    result = _base_result(config, fixture, schedule, mode)
    deferred_completion_queue: list[dict[str, Any]] = []
    result["artifact_fingerprints"] = fingerprint_artifacts(config)
    with (
        tempfile.TemporaryDirectory(prefix="glacier-paired-abba-") as work_text,
        ExitStack() as fixture_cleanup,
    ):
        work_dir = Path(work_text)
        canonical_path, pinned_ids_path, runtime_fixture = materialize_runtime_fixtures(
            work_dir, canonical, pinned_ids
        )
        fixture_cleanup.callback(restore_runtime_fixture_permissions, runtime_fixture)
        result["runtime_fixture"] = runtime_fixture
        preflight = run_tokenizer_preflight(
            config,
            canonical,
            pinned_ids,
            canonical_path,
            pinned_ids_path,
            runtime_fixture,
            result["artifact_fingerprints"],
            work_dir,
        )
        result["tokenizer_preflight"] = preflight
        if not preflight["passed"]:
            result["status"] = "failed"
            result["failure_reason"] = (
                "tokenizer preflight did not match the pinned full token ID list"
            )
            return result
        if preflight_only:
            result["runtime_fixture_post_run_verification"] = verify_runtime_fixtures(
                runtime_fixture,
                canonical,
                pinned_ids,
                "final preflight-only verification",
            )
            result["artifact_post_run_verification"] = verify_artifacts_unchanged(
                config,
                result["artifact_fingerprints"],
                "final preflight-only verification",
                full_hash=True,
            )
            result["status"] = "passed"
            return result

        if platform.system() != "Darwin":
            raise HarnessError("timed benchmark mode requires macOS /usr/bin/time -l")
        if not Path("/usr/bin/time").is_file():
            raise HarnessError("timed benchmark mode requires /usr/bin/time")

        warmup_schedule: list[dict[str, Any]] = []
        warmup_samples: list[dict[str, Any]] = []
        warmup_machine_anchors: dict[int, dict[str, Any]] = {}
        warmup_order = list(ENGINE_NAMES)
        if config["schedule_seed"] & 1:
            warmup_order.reverse()
        for ordinal in range(config["warmup_runs_per_engine"]):
            for engine in warmup_order:
                entry = {
                    "sequence_index": len(warmup_schedule),
                    "block_index": -1,
                    "position_in_block": len(warmup_schedule),
                    "pattern": "warmup",
                    "engine": engine,
                    "engine_sample_index": ordinal,
                }
                warmup_schedule.append(entry)
                anchor = warmup_machine_anchors.get(ordinal)
                sample, new_anchor = run_machine_gated_sample(
                    config,
                    canonical,
                    canonical_path,
                    pinned_ids_path,
                    pinned_ids,
                    runtime_fixture,
                    result["artifact_fingerprints"],
                    work_dir / f"warmup-{len(warmup_samples):03d}-{engine}",
                    entry,
                    warmup=True,
                    match_anchor=anchor,
                    deferred_completion_queue=deferred_completion_queue,
                )
                if new_anchor is not None:
                    warmup_machine_anchors[ordinal] = new_anchor
                warmup_samples.append(sample)
                if not sample["success"]:
                    result["warmup_schedule"] = warmup_schedule
                    result["warmup_samples"] = warmup_samples
                    result["status"] = "failed"
                    result["failure_reason"] = (
                        f"{engine} warmup failed; timed samples were not started"
                    )
                    return result
        result["warmup_schedule"] = warmup_schedule
        result["warmup_samples"] = warmup_samples

        samples: list[dict[str, Any]] = []
        timed_machine_anchors: dict[tuple[int, int], dict[str, Any]] = {}
        for entry in schedule:
            pair_key = (
                int(entry["block_index"]),
                int(entry["position_in_block"]) // 2,
            )
            anchor = timed_machine_anchors.get(pair_key)
            sample, new_anchor = run_machine_gated_sample(
                config,
                canonical,
                canonical_path,
                pinned_ids_path,
                pinned_ids,
                runtime_fixture,
                result["artifact_fingerprints"],
                work_dir / f"sample-{entry['sequence_index']:03d}-{entry['engine']}",
                entry,
                warmup=False,
                match_anchor=anchor,
                deferred_completion_queue=deferred_completion_queue,
            )
            if new_anchor is not None:
                timed_machine_anchors[pair_key] = new_anchor
            samples.append(sample)
            result["samples"] = samples
            if not sample["success"]:
                result["status"] = "failed"
                result["failure_reason"] = (
                    f"timed sample {entry['sequence_index']} ({entry['engine']}) failed; "
                    "remaining schedule was not run"
                )
                return result

        deferred_failures = finalize_deferred_completions(
            deferred_completion_queue, config["workload"]["completion_tokens"]
        )
        result["deferred_completion_extraction"] = {
            "mode": "after-all-timed-observations",
            "queued_samples": len(deferred_completion_queue),
            "passed": not deferred_failures,
            "failures": deferred_failures,
            "note": (
                "Raw-text token-ID extractors run only after the complete timed "
                "schedule, so post-processing cannot perturb a later arm."
            ),
        }
        if deferred_failures:
            result["status"] = "failed"
            result["failure_reason"] = (
                "deferred completion token-ID validation failed; no timed "
                "summary was produced"
            )
            return result

        result["runtime_fixture_post_run_verification"] = verify_runtime_fixtures(
            runtime_fixture, canonical, pinned_ids, "final benchmark verification"
        )
        result["artifact_post_run_verification"] = verify_artifacts_unchanged(
            config,
            result["artifact_fingerprints"],
            "final benchmark verification",
            full_hash=True,
        )
        result["summary"] = summarize_samples(config, samples)
        unstable = [
            engine
            for engine in ENGINE_NAMES
            if config["engines"][engine]["require_stable_completion_hash"]
            and not result["summary"]["per_engine"][engine]["completion_is_stable"]
        ]
        if unstable:
            result["status"] = "failed"
            result["failure_reason"] = (
                "non-deterministic completion hashes for: " + ", ".join(unstable)
            )
        elif (
            config["workload"]["completion_equivalence"] == "exact-token-ids"
            and result["summary"]["completion_equivalence"][
                "cross_engine_token_ids_match"
            ]
            is not True
        ):
            result["status"] = "failed"
            result["failure_reason"] = (
                "exact-token-ids mode found different normalized generated-ID lists"
            )
        else:
            result["status"] = "passed"
            result["machine_state_policy"]["timed_comparison_publication_eligible"] = (
                config["machine_state"]["mode"] == "publishable"
            )
        return result


def _write_json(result: Mapping[str, Any], output: str | None) -> None:
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
    if output is None or output == "-":
        sys.stdout.write(rendered)
        return
    path = Path(output).expanduser().resolve(strict=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
    sys.stderr.write(f"wrote {path}\n")


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run a tokenizer-pinned, process-cold/os-warm paired ABBA benchmark "
            "between Glacier and llama.cpp."
        )
    )
    parser.add_argument(
        "manifest", help="path to a glacier.paired-bench/v1 JSON manifest"
    )
    parser.add_argument("-o", "--output", help="result JSON path, or '-' for stdout")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="validate fixtures, resolve commands, and print the schedule without executing commands",
    )
    mode.add_argument(
        "--preflight-only",
        action="store_true",
        help="run and compare both tokenizers, but do not execute completion benchmarks",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        config = load_manifest(Path(args.manifest))
        if args.dry_run:
            result = dry_run(config)
        else:
            result = run_harness(config, preflight_only=args.preflight_only)
        _write_json(result, args.output)
        return 0 if result["status"] == "passed" else 1
    except HarnessError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
