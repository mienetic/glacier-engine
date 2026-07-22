#!/usr/bin/env python3
"""Hash-pinned macOS resource A/B for Glacier decode execution policies.

The harness starts a fresh Glacier process for every observation, wraps it in
``/usr/bin/time -lp``, and retains exact completion, telemetry, ordering,
artifact, and resource-counter evidence. Strict same-binary modes fail closed
on incomplete fused, DecodePlan, or greedy-output telemetry.
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
import secrets
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
import decode_plan_ab as decode_plan
import greedy_output_ab as greedy_output


SCHEMA = "glacier.resource-ab/result-v2"
ROLES = ("baseline", "candidate")
DEFAULT_SAMPLES_PER_ROLE = 16
DEFAULT_WARMUPS_PER_ROLE = 1
DEFAULT_SCHEDULE_SEED = 20_260_730
DEFAULT_BOOTSTRAP_SEED = 0x5245534F55524345
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000

_CLOCK_RE = re.compile(r"^(real|user|sys) ([0-9]+\.[0-9]{2})$")
_COUNTER_RE = re.compile(r"^\s*([0-9]+)\s+([a-z][a-z ]*[a-z])\s*$")
_PHASE_PRECISION_RE = re.compile(
    r"^[^\S\r\n]*phases:[^\S\r\n]+prefill_ms=[0-9]+\.[0-9]{3}"
    r"[^\S\r\n]+decode_ms=[0-9]+\.[0-9]{3}"
    r"[^\S\r\n]+sampling_ms=[0-9]+\.[0-9]{3}[^\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_TOTAL_PRECISION_RE = re.compile(
    r"^[^\S\r\n]*time:[^\S\r\n]*[0-9]+\.[0-9]{2}"
    r"[^\S\r\n]*ms[^\S\r\n]*\([^\S\r\n]*[0-9]+\.[0-9]"
    r"[^\S\r\n]*tok/s,[^\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)
_TELEMETRY_PREFIXES = (
    b"load:",
    b"ready:",
    b"schedule:",
    b"phases:",
    b"prefill_phase:",
    b"decode_frame:",
    b"pair_scratch:",
    b"pair_prefill_frame:",
    b"decode_plan:",
    b"greedy_output:",
    b"time:",
)

# The emitter prints three phase values to 0.001 ms and the encompassing
# generation timer to 0.01 ms. If the underlying phase sum is no greater than
# the encompassing timer, independent rounding can make the printed sum exceed
# it by at most 3 * 0.0005 + 0.005 = 0.0065 ms.
_PHASE_INTERNAL_ROUNDING_TOLERANCE_MS = 0.0065
_INTERNAL_TIME_HALF_QUANTUM_MS = 0.005
_INTERNAL_TPS_HALF_QUANTUM = 0.05

# Apple's /usr/bin/time -p emits real time at centisecond precision. The
# enclosing harness includes launching/reaping /usr/bin/time and draining its
# pipe, for which a fixed 250 ms allowance is intentionally conservative but
# still catches a mismatched or stale resource record.
_TIME_REAL_EMISSION_QUANTUM_SECONDS = 0.010
_TIME_WRAPPER_OVERHEAD_TOLERANCE_SECONDS = 0.250
# The child timer and Python's enclosing monotonic clock are independent
# Darwin clock reads.  Under a long, CPU-saturated PP2048 process the printed
# child duration has been observed 23.6 ms ahead of the enclosing reading even
# though subprocess.run necessarily encloses it.  Bound that cross-clock plus
# centisecond-emission lead explicitly; this is intentionally much smaller
# than the allowance for launching, reaping, and draining the wrapper.
_OUTER_WALL_CLOCK_LEAD_TOLERANCE_SECONDS = 0.050
_RELATION_EPSILON = 1e-12

_TIME_COUNTERS = {
    "maximum resident set size": "time_maximum_resident_set_size_bytes",
    "average shared memory size": "time_average_shared_memory_size_bytes",
    "average unshared data size": "time_average_unshared_data_size_bytes",
    "average unshared stack size": "time_average_unshared_stack_size_bytes",
    "page reclaims": "time_page_reclaims",
    "page faults": "time_page_faults",
    "swaps": "time_swaps",
    "block input operations": "time_block_input_operations",
    "block output operations": "time_block_output_operations",
    "messages sent": "time_messages_sent",
    "messages received": "time_messages_received",
    "signals received": "time_signals_received",
    "voluntary context switches": "time_voluntary_context_switches",
    "involuntary context switches": "time_involuntary_context_switches",
    "instructions retired": "time_instructions_retired",
    "cycles elapsed": "time_cycles_elapsed",
    "peak memory footprint": "time_peak_memory_footprint_bytes",
}

_RESOURCE_UNITS = {
    "time_real_seconds": "seconds",
    "time_user_seconds": "seconds",
    "time_sys_seconds": "seconds",
    "time_cpu_seconds": "seconds (user + sys)",
    **{
        key: "bytes" if key.endswith("_bytes") else "count"
        for key in _TIME_COUNTERS.values()
    },
}

_RATIO_FIELDS = (
    "prefill_ms",
    "decode_ms",
    "internal_ms",
    "harness_wall_seconds",
    "time_real_seconds",
    "time_cpu_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_instructions_retired",
    "time_cycles_elapsed",
    "time_peak_memory_footprint_bytes",
)

_MEDIAN_FIELDS = (
    "prefill_ms",
    "decode_ms",
    "sampling_ms",
    "internal_ms",
    "harness_wall_seconds",
    "time_real_seconds",
    "time_user_seconds",
    "time_sys_seconds",
    "time_cpu_seconds",
    *_TIME_COUNTERS.values(),
)

_COMMAND_ENVIRONMENT = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
}
_SYSTEM_TIME_BINARY = Path("/usr/bin/time").resolve()


@dataclass(frozen=True)
class Config:
    baseline_binary: Path
    candidate_binary: Path
    model: Path
    ids: Path
    output: Path | None
    cwd: Path
    time_binary: Path = Path("/usr/bin/time")
    serial_vs_fused: bool = False
    decode_plan_ab: bool = False
    greedy_output_ab: bool = False
    threshold: int = 128
    samples_per_role: int = DEFAULT_SAMPLES_PER_ROLE
    warmups_per_role: int = DEFAULT_WARMUPS_PER_ROLE
    new_tokens: int = 64
    threads: int = 4
    schedule_seed: int = DEFAULT_SCHEDULE_SEED
    bootstrap_seed: int = DEFAULT_BOOTSTRAP_SEED
    bootstrap_resamples: int = DEFAULT_BOOTSTRAP_RESAMPLES
    confidence: float = 0.95
    timeout_seconds: float = 3600.0
    overwrite: bool = False
    baseline_sha256: str | None = None
    candidate_sha256: str | None = None
    model_sha256: str | None = None
    ids_sha256: str | None = None
    time_sha256: str | None = None
    # Programmatic-only injection for parser/integration tests. Resource
    # measurements created with this escape hatch are marked non-publishable.
    test_only_allow_non_system_time: bool = False


def parse_time_output(value: str) -> dict[str, int | float]:
    """Parse one complete macOS ``/usr/bin/time -lp`` record."""

    clocks: dict[str, float] = {}
    counters: dict[str, int] = {}
    for line_number, raw in enumerate(value.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        clock = _CLOCK_RE.fullmatch(line)
        if clock is not None:
            key = f"time_{clock.group(1)}_seconds"
            if key in clocks:
                raise common.HarnessError(f"duplicate time clock {key}")
            numeric = float(clock.group(2))
            if not math.isfinite(numeric) or numeric < 0:
                raise common.HarnessError(f"invalid time clock {key}")
            clocks[key] = numeric
            continue
        counter = _COUNTER_RE.fullmatch(raw)
        if counter is None:
            raise common.HarnessError(
                f"malformed /usr/bin/time -lp line {line_number}: {raw!r}"
            )
        label = counter.group(2)
        key = _TIME_COUNTERS.get(label)
        if key is None:
            raise common.HarnessError(
                f"unknown /usr/bin/time -lp counter on line {line_number}: {label}"
            )
        if key in counters:
            raise common.HarnessError(f"duplicate /usr/bin/time counter {label}")
        numeric = int(counter.group(1))
        if numeric > common.MAX_I64:
            raise common.HarnessError(f"/usr/bin/time counter exceeds int64: {label}")
        counters[key] = numeric

    expected_clocks = {"time_real_seconds", "time_user_seconds", "time_sys_seconds"}
    missing_clocks = sorted(expected_clocks - clocks.keys())
    missing_counters = sorted(set(_TIME_COUNTERS.values()) - counters.keys())
    if missing_clocks or missing_counters:
        missing = [*missing_clocks, *missing_counters]
        raise common.HarnessError(
            f"incomplete /usr/bin/time -lp record; missing {', '.join(missing)}"
        )
    result: dict[str, int | float] = {**clocks, **counters}
    result["time_cpu_seconds"] = (
        clocks["time_user_seconds"] + clocks["time_sys_seconds"]
    )
    return result


def _validate_telemetry_precision(output: str) -> None:
    """Require the emitter precision used by the rounding proofs below."""

    if len(list(_PHASE_PRECISION_RE.finditer(output))) != 1:
        raise common.HarnessError(
            "phase telemetry must use three fractional millisecond digits"
        )
    if len(list(_TOTAL_PRECISION_RE.finditer(output))) != 1:
        raise common.HarnessError(
            "total telemetry must use two millisecond and one tok/s fractional digits"
        )


def _validate_metric_relations(
    telemetry: Mapping[str, Any],
    resources: Mapping[str, Any],
    *,
    completion_tokens: int,
    harness_wall_seconds: float,
) -> dict[str, float]:
    """Validate independently reported metrics against shared clock semantics.

    Glacier's ``internal_ms`` encloses generation, while the phase timers cover
    only prefill, decode graphs, and token selection. Uninstrumented generation
    overhead is therefore allowed; only a phase sum that exceeds the enclosing
    timer beyond the emitter's maximum rounding error is invalid.

    The CLI computes tok/s as completion-token count divided by the same
    unrounded internal duration. We compare the intervals admitted by its
    printed 0.01 ms and 0.1 tok/s quantization instead of using an arbitrary
    percentage tolerance.
    """

    derived = _validate_internal_metric_relations(
        telemetry,
        completion_tokens=completion_tokens,
    )

    internal_ms = float(telemetry["internal_ms"])
    time_real_seconds = float(resources["time_real_seconds"])
    wall_lower = max(
        0.0,
        time_real_seconds - _OUTER_WALL_CLOCK_LEAD_TOLERANCE_SECONDS,
    )
    wall_upper = (
        time_real_seconds
        + _TIME_REAL_EMISSION_QUANTUM_SECONDS
        + _TIME_WRAPPER_OVERHEAD_TOLERANCE_SECONDS
    )
    if (
        harness_wall_seconds + _RELATION_EPSILON < wall_lower
        or harness_wall_seconds - _RELATION_EPSILON > wall_upper
    ):
        raise common.HarnessError(
            "/usr/bin/time real duration is inconsistent with its enclosing "
            "harness wall timer and the 0.050 s lead/0.250 s wrapper "
            "allowances: "
            f"real={time_real_seconds:.9f}s wall={harness_wall_seconds:.9f}s"
        )

    internal_seconds = internal_ms / 1000.0
    internal_half_quantum_seconds = _INTERNAL_TIME_HALF_QUANTUM_MS / 1000.0
    if (
        internal_seconds
        > time_real_seconds
        + _TIME_REAL_EMISSION_QUANTUM_SECONDS
        + internal_half_quantum_seconds
        + _RELATION_EPSILON
    ):
        raise common.HarnessError(
            "internal generation timer exceeds the enclosing /usr/bin/time "
            "real duration beyond truncation tolerance"
        )
    if (
        internal_seconds
        > harness_wall_seconds
        + _OUTER_WALL_CLOCK_LEAD_TOLERANCE_SECONDS
        + internal_half_quantum_seconds
        + _RELATION_EPSILON
    ):
        raise common.HarnessError(
            "internal generation timer exceeds the enclosing harness wall timer"
        )

    return {
        **derived,
        "time_real_minus_harness_wall_seconds": (
            time_real_seconds - harness_wall_seconds
        ),
    }


def _validate_internal_metric_relations(
    telemetry: Mapping[str, Any],
    *,
    completion_tokens: int,
) -> dict[str, float]:
    """Validate phase nesting and tok/s without requiring a resource wrapper."""

    if completion_tokens <= 0:
        raise common.HarnessError("completion token count must be positive")
    phase_sum_ms = sum(
        float(telemetry[field]) for field in ("prefill_ms", "decode_ms", "sampling_ms")
    )
    internal_ms = float(telemetry["internal_ms"])
    if (
        phase_sum_ms - internal_ms
        > _PHASE_INTERNAL_ROUNDING_TOLERANCE_MS + _RELATION_EPSILON
    ):
        raise common.HarnessError(
            "phase timing sum exceeds the enclosing internal timer beyond "
            "the 0.0065 ms rounding tolerance"
        )

    elapsed_low_ms = max(
        math.nextafter(0.0, 1.0),
        internal_ms - _INTERNAL_TIME_HALF_QUANTUM_MS,
    )
    elapsed_high_ms = internal_ms + _INTERNAL_TIME_HALF_QUANTUM_MS
    implied_tps_low = completion_tokens * 1000.0 / elapsed_high_ms
    implied_tps_high = completion_tokens * 1000.0 / elapsed_low_ms
    reported_tps = float(telemetry["internal_tokens_per_second"])
    reported_tps_low = max(0.0, reported_tps - _INTERNAL_TPS_HALF_QUANTUM)
    reported_tps_high = reported_tps + _INTERNAL_TPS_HALF_QUANTUM
    intervals_disjoint = (
        implied_tps_high + _RELATION_EPSILON < reported_tps_low
        or reported_tps_high + _RELATION_EPSILON < implied_tps_low
    )
    if intervals_disjoint:
        raise common.HarnessError(
            "reported tok/s is inconsistent with completion count and the "
            "shared internal timer"
        )

    return {
        "phase_sum_ms": phase_sum_ms,
        "phase_sum_minus_internal_ms": phase_sum_ms - internal_ms,
        "internal_tps_implied_from_reported_ms": (
            completion_tokens * 1000.0 / internal_ms
        ),
    }


def build_measurement_order(
    samples_per_role: int, seed: int
) -> tuple[list[str], list[dict[str, int | str]]]:
    """Build deterministic balanced ABBA/BAAB blocks.

    A is candidate and B is baseline. Equal numbers of ABBA and BAAB blocks
    balance first/last position as well as total observations.
    """

    patterns = common.build_patterns(samples_per_role, seed)
    order: list[dict[str, int | str]] = []
    for block_index, pattern in enumerate(patterns):
        for position, letter in enumerate(pattern):
            order.append(
                {
                    "block_index": block_index,
                    "position_in_block": position,
                    "pattern": pattern,
                    "letter": letter,
                    "role": "candidate" if letter == "A" else "baseline",
                }
            )
    return patterns, order


def _policy(config: Config, role: str) -> str:
    if role not in ROLES:
        raise common.HarnessError(f"unknown resource A/B role: {role}")
    if config.greedy_output_ab:
        return (
            greedy_output.VARIANTS[1]
            if role == "candidate"
            else greedy_output.VARIANTS[0]
        )
    if config.decode_plan_ab:
        return "sealed-required" if role == "candidate" else "checked"
    if role == "candidate" and config.serial_vs_fused:
        return "fused"
    return "serial"


def build_glacier_command(
    config: Config, role: str, completion_path: Path
) -> list[str]:
    policy = _policy(config, role)
    if config.decode_plan_ab:
        attention = ["--parallel-attention-min-context", str(config.threshold)]
        plan_policy = ["--decode-plan", policy]
        greedy_policy: list[str] = []
    elif config.greedy_output_ab:
        attention = ["--parallel-attention-min-context", str(config.threshold)]
        plan_policy = ["--decode-plan", "checked"]
        greedy_policy = ["--greedy-output", policy]
    else:
        attention = (
            ["--serial-attention"]
            if policy == "serial"
            else ["--parallel-attention-min-context", str(config.threshold)]
        )
        plan_policy = []
        greedy_policy = []
    binary = config.baseline_binary if role == "baseline" else config.candidate_binary
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
        str(completion_path),
        *attention,
        *plan_policy,
        *greedy_policy,
    ]


def _validate(config: Config) -> None:
    selected_modes = sum(
        (config.serial_vs_fused, config.decode_plan_ab, config.greedy_output_ab)
    )
    if selected_modes > 1:
        raise common.HarnessError(
            "serial-vs-fused, decode-plan-ab, and greedy-output-ab are "
            "mutually exclusive"
        )
    if config.samples_per_role > 10_000:
        raise common.HarnessError("samples per role must not exceed 10000")
    common.build_patterns(config.samples_per_role, config.schedule_seed)
    if not 1 <= config.warmups_per_role <= 100:
        raise common.HarnessError("warmups per role must be in [1, 100]")
    if not 1 <= config.new_tokens <= 1_000_000:
        raise common.HarnessError("new tokens must be in [1, 1000000]")
    if not 1 <= config.threads <= 65_536:
        raise common.HarnessError("threads must be in [1, 65536]")
    if config.decode_plan_ab and (config.threads < 2 or config.new_tokens < 2):
        raise common.HarnessError(
            "decode-plan resource A/B requires at least 2 threads and 2 new tokens"
        )
    if config.greedy_output_ab and (config.threads < 2 or config.new_tokens < 2):
        raise common.HarnessError(
            "greedy-output resource A/B requires at least 2 threads and 2 new tokens"
        )
    if not 1 <= config.threshold <= common.MAX_I64:
        raise common.HarnessError("parallel attention threshold must be positive int64")
    if not 0 <= config.schedule_seed <= common.MAX_I64:
        raise common.HarnessError("schedule seed must be in the signed int64 range")
    if not 0 <= config.bootstrap_seed <= common.MAX_I64:
        raise common.HarnessError("bootstrap seed must be in the signed int64 range")
    if not 100 <= config.bootstrap_resamples <= 1_000_000:
        raise common.HarnessError("bootstrap resamples must be in [100, 1000000]")
    if not 0.5 <= config.confidence <= 0.999:
        raise common.HarnessError("confidence must be in [0.5, 0.999]")
    if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
        raise common.HarnessError("timeout must be finite and positive")
    if not config.cwd.is_dir():
        raise common.HarnessError(f"cwd is not a directory: {config.cwd}")
    if config.model.suffix.lower() != ".glrt":
        raise common.HarnessError("strict resource A/B requires a .glrt model")

    configured_paths = {
        "baseline binary": config.baseline_binary,
        "candidate binary": config.candidate_binary,
        "model": config.model,
        "prompt IDs": config.ids,
        "cwd": config.cwd,
        "time binary": config.time_binary,
    }
    if config.output is not None:
        configured_paths["output"] = config.output
    for name, configured_path in configured_paths.items():
        if not configured_path.is_absolute():
            raise common.HarnessError(
                f"programmatic resource A/B path must be absolute ({name}): "
                f"{configured_path}"
            )
    if config.greedy_output_ab and config.baseline_binary != config.candidate_binary:
        raise common.HarnessError(
            "greedy-output resource A/B requires the same binary path for both roles"
        )

    strict_system_time = (
        platform.system() == "Darwin"
        and config.time_binary.resolve() == _SYSTEM_TIME_BINARY
    )
    if not strict_system_time and not config.test_only_allow_non_system_time:
        raise common.HarnessError(
            "publishable resource measurements require Darwin /usr/bin/time; "
            "custom timers are test-only"
        )

    fixed_inputs = {
        config.model,
        config.ids,
        config.time_binary,
        Path(__file__).resolve(),
        Path(common.__file__).resolve(),
    }
    if config.decode_plan_ab:
        fixed_inputs.add(Path(decode_plan.__file__).resolve())
    if config.greedy_output_ab:
        fixed_inputs.add(Path(greedy_output.__file__).resolve())
    expected_fixed_inputs = (
        5 + int(config.decode_plan_ab) + int(config.greedy_output_ab)
    )
    if len(fixed_inputs) != expected_fixed_inputs:
        raise common.HarnessError("model, IDs, time, and drivers must be distinct")
    for binary in (config.baseline_binary, config.candidate_binary):
        if binary in fixed_inputs:
            raise common.HarnessError("benchmark binaries must not alias other inputs")
    if config.output is not None and config.output in {
        *fixed_inputs,
        config.baseline_binary,
        config.candidate_binary,
    }:
        raise common.HarnessError("result output must not replace an input artifact")
    for name, executable in (
        ("baseline binary", config.baseline_binary),
        ("candidate binary", config.candidate_binary),
        ("time binary", config.time_binary),
    ):
        if not os.access(executable, os.X_OK):
            raise common.HarnessError(f"{name} is not executable: {executable}")
    for name, digest in (
        ("baseline", config.baseline_sha256),
        ("candidate", config.candidate_sha256),
        ("model", config.model_sha256),
        ("ids", config.ids_sha256),
        ("time", config.time_sha256),
    ):
        if digest is not None and common.SHA256_RE.fullmatch(digest) is None:
            raise common.HarnessError(
                f"{name} SHA-256 pin must be 64 lowercase hex digits"
            )


def _fingerprints(config: Config) -> dict[str, dict[str, Any]]:
    fingerprints = {
        "baseline_binary": common.fingerprint(
            config.baseline_binary, "baseline binary", config.baseline_sha256
        ),
        "candidate_binary": common.fingerprint(
            config.candidate_binary, "candidate binary", config.candidate_sha256
        ),
        "model": common.fingerprint(config.model, "model", config.model_sha256),
        "prompt_ids": common.fingerprint(config.ids, "prompt IDs", config.ids_sha256),
        "time_binary": common.fingerprint(
            config.time_binary, "time binary", config.time_sha256
        ),
        "driver": common.fingerprint(Path(__file__).resolve(), "driver", None),
        "shared_driver": common.fingerprint(
            Path(common.__file__).resolve(), "shared driver", None
        ),
    }
    if config.decode_plan_ab:
        fingerprints["decode_plan_driver"] = common.fingerprint(
            Path(decode_plan.__file__).resolve(), "decode plan driver", None
        )
    if config.greedy_output_ab:
        fingerprints["greedy_output_driver"] = common.fingerprint(
            Path(greedy_output.__file__).resolve(), "greedy-output driver", None
        )
    return fingerprints


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


def _validate_comparison_artifacts(
    config: Config, artifacts: Mapping[str, Mapping[str, Any]]
) -> None:
    if (
        config.serial_vs_fused or config.decode_plan_ab or config.greedy_output_ab
    ) and artifacts["baseline_binary"]["sha256"] != artifacts["candidate_binary"][
        "sha256"
    ]:
        raise common.HarnessError(
            "same-binary policy A/B requires byte-identical baseline and "
            "candidate binaries; use the default mode for a cross-binary control"
        )


def _process_output_capture_contract() -> dict[str, Any]:
    return {
        "stream": "combined_stdout_stderr",
        "raw_evidence": "SHA-256 over exact captured bytes",
        "retained_human_text": {
            "encoding": "utf-8",
            "errors": "replace",
            "purpose": "human-readable evidence only; never parsed as telemetry",
        },
        "telemetry_projection": {
            "encoding": "ascii",
            "errors": "replace each non-ASCII byte with U+FFFD",
            "purpose": (
                "strict telemetry parsing; U+FFFD is outside the telemetry "
                "grammar, so non-ASCII inside a required line fails closed"
            ),
        },
        "raw_reserved_prefix_guard": {
            "record_delimiter": "LF byte only",
            "leading_whitespace": "ASCII space or tab only",
            "policy": (
                "reject exact reserved telemetry lines containing non-ASCII or "
                "control bytes; reject any tainted colon-delimited leading label "
                "and any no-colon tainted label that reduces to a reserved stem"
            ),
        },
    }


def _is_prefix_taint(byte: int) -> bool:
    return byte >= 0x80 or byte < 0x20 or byte == 0x7F


def _validate_raw_telemetry_envelope(
    output: bytes,
    *,
    extra_reserved_prefixes: Sequence[bytes] = (),
) -> None:
    """Reject tainted machine-record lines without constraining model payload."""

    prefixes = (*_TELEMETRY_PREFIXES, *extra_reserved_prefixes)
    if any(
        not prefix.endswith(b":")
        or prefix.lower() != prefix
        or any(byte >= 0x80 or byte < 0x20 or byte == 0x7F for byte in prefix)
        for prefix in prefixes
    ):
        raise common.HarnessError("reserved telemetry prefixes must be lowercase ASCII")

    for line_number, line in enumerate(output.split(b"\n"), start=1):
        candidate = line.lstrip(b" \t")
        folded = candidate.lower()
        exact_prefix = next(
            (prefix for prefix in prefixes if folded.startswith(prefix)),
            None,
        )
        if exact_prefix is not None:
            if any(
                byte >= 0x80 or (byte < 0x20 and byte != 0x09) or byte == 0x7F
                for byte in candidate
            ):
                raise common.HarnessError(
                    "reserved telemetry line contains a non-ASCII/control byte "
                    f"at raw line {line_number}"
                )
            continue

        colon = candidate.find(b":")
        if colon >= 0:
            leading_label = candidate[: colon + 1]
            tainted_label = any(_is_prefix_taint(byte) for byte in leading_label)
        else:
            leading_label = candidate.split(None, 1)[0] if candidate else b""
            without_taint = bytes(
                byte for byte in leading_label if not _is_prefix_taint(byte)
            ).lower()
            tainted_label = any(
                _is_prefix_taint(byte) for byte in leading_label
            ) and any(without_taint == prefix[:-1] for prefix in prefixes)
        if tainted_label:
            raise common.HarnessError(
                "tainted leading output label could hide a reserved telemetry "
                f"prefix at raw line {line_number}"
            )


def _capture_process_output(
    output: bytes,
    *,
    extra_reserved_prefixes: Sequence[bytes] = (),
) -> dict[str, Any]:
    raw_byte_count = len(output)
    raw_sha256 = common.sha256_bytes(output)
    _validate_raw_telemetry_envelope(
        output,
        extra_reserved_prefixes=extra_reserved_prefixes,
    )
    retained_text = output.decode("utf-8", errors="replace")
    telemetry_text = output.decode("ascii", errors="replace")
    non_ascii_byte_count = sum(byte >= 0x80 for byte in output)
    replacement_count = telemetry_text.count("\ufffd")
    if len(telemetry_text) != len(output) or replacement_count != non_ascii_byte_count:
        raise common.HarnessError(
            "ASCII telemetry projection did not preserve every non-ASCII byte "
            "as a rejection marker"
        )
    return {
        "output_raw": output,
        "retained_text": retained_text,
        "telemetry_text": telemetry_text,
        "output_capture": {
            "raw_byte_count": raw_byte_count,
            "raw_sha256": raw_sha256,
            "non_ascii_byte_count": non_ascii_byte_count,
            "retained_human_text_sha256": common.sha256_bytes(
                retained_text.encode("utf-8")
            ),
            "retained_human_text_replacement_characters": retained_text.count("\ufffd"),
            "telemetry_projection_sha256": common.sha256_bytes(
                telemetry_text.encode("utf-8")
            ),
            "telemetry_projection_rejection_markers": replacement_count,
        },
    }


def _run_timed_process(
    argv: Sequence[str], cwd: Path, timeout_seconds: float
) -> dict[str, Any]:
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
        raise common.HarnessError(f"cannot launch timed Glacier: {error}") from error
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
        raise common.HarnessError(
            f"timed Glacier process exceeded {timeout_seconds} seconds"
        ) from error
    wall_seconds = (time.perf_counter_ns() - started) / 1e9
    capture = _capture_process_output(output)
    if process.returncode != 0:
        raise common.HarnessError(
            f"timed Glacier exited with {process.returncode}:\n"
            f"{capture['retained_text']}"
        )
    if not math.isfinite(wall_seconds) or wall_seconds <= 0:
        raise common.HarnessError("harness wall timing must be finite and positive")
    return {
        **capture,
        "wall_seconds": wall_seconds,
        "exit_status": process.returncode,
    }


def _observe(
    config: Config,
    role: str,
    completion_path: Path,
    time_path: Path,
    prompt_ids: Sequence[int],
    artifacts: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    common.assert_artifact_identities(artifacts)
    if completion_path.exists() or time_path.exists():
        raise common.HarnessError("observation output path unexpectedly exists")
    glacier_argv = build_glacier_command(config, role, completion_path)
    timed_argv = [
        str(config.time_binary),
        "-lp",
        "-o",
        str(time_path),
        *glacier_argv,
    ]
    process = _run_timed_process(timed_argv, config.cwd, config.timeout_seconds)
    common.assert_artifact_identities(artifacts)
    if not completion_path.is_file():
        raise common.HarnessError("Glacier did not create completion IDs")
    if not time_path.is_file():
        raise common.HarnessError("time did not create the required resource record")
    try:
        completion_raw = completion_path.read_bytes()
        time_raw = time_path.read_bytes()
        time_text = time_raw.decode("ascii", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise common.HarnessError(
            f"cannot read observation evidence: {error}"
        ) from error
    completion_ids = common.parse_ids(completion_raw, "completion output")
    if len(completion_ids) != config.new_tokens:
        raise common.HarnessError(
            f"completion output had {len(completion_ids)} IDs, expected {config.new_tokens}"
        )

    policy = _policy(config, role)
    _validate_telemetry_precision(process["telemetry_text"])
    if config.decode_plan_ab:
        telemetry = decode_plan.parse_telemetry(
            process["telemetry_text"],
            variant=policy,
            prompt_tokens=len(prompt_ids),
            new_tokens=config.new_tokens,
            threshold=config.threshold,
            require_fused_gqa=False,
        )
    elif config.greedy_output_ab:
        telemetry = greedy_output.parse_telemetry(
            process["telemetry_text"],
            variant=policy,
            prompt_tokens=len(prompt_ids),
            new_tokens=config.new_tokens,
            threshold=config.threshold,
            require_fused_gqa=True,
        )
    else:
        telemetry = common.parse_telemetry(
            process["telemetry_text"],
            variant="serial" if policy == "serial" else "parallel",
            prompt_tokens=len(prompt_ids),
            new_tokens=config.new_tokens,
            threshold=config.threshold,
            require_fused_gqa=policy == "fused",
            require_paired_mlp=policy == "fused",
        )
    resources = parse_time_output(time_text)
    for required_positive in (
        "time_real_seconds",
        "time_cpu_seconds",
        "time_maximum_resident_set_size_bytes",
        "time_instructions_retired",
        "time_cycles_elapsed",
        "time_peak_memory_footprint_bytes",
    ):
        if float(resources[required_positive]) <= 0:
            raise common.HarnessError(
                f"resource metric must be positive: {required_positive}"
            )
    relations = _validate_metric_relations(
        telemetry,
        resources,
        completion_tokens=len(completion_ids),
        harness_wall_seconds=process["wall_seconds"],
    )
    metrics = {
        **telemetry,
        **resources,
        **relations,
        "harness_wall_seconds": process["wall_seconds"],
    }
    return {
        "role": role,
        "policy": policy,
        "glacier_argv": glacier_argv,
        "timed_argv": timed_argv,
        "metrics": metrics,
        "completion_ids": completion_ids,
        "completion_ids_sha256": common.sha256_bytes(
            common.canonical_ids_bytes(completion_ids)
        ),
        "completion_file_sha256": common.sha256_bytes(completion_raw),
        "telemetry_sha256": process["output_capture"]["raw_sha256"],
        "time_output_sha256": common.sha256_bytes(time_raw),
        "telemetry_output": process["retained_text"],
        "output_capture": process["output_capture"],
        "time_output": time_text,
        "exit_status": process["exit_status"],
    }


def paired_ratio(
    samples: Sequence[Mapping[str, Any]],
    field: str,
    *,
    resamples: int,
    seed: int,
    confidence: float,
) -> dict[str, Any]:
    """Bootstrap the median baseline/candidate ratio by balanced block."""

    blocks: dict[int, dict[str, list[float]]] = {}
    for sample in samples:
        value = sample["metrics"].get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise common.HarnessError(f"metric {field} is missing or not numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or numeric <= 0:
            raise common.HarnessError(f"metric {field} must be finite and positive")
        block = blocks.setdefault(
            int(sample["block_index"]), {role: [] for role in ROLES}
        )
        block[str(sample["role"])].append(numeric)
    ordered = [blocks[index] for index in sorted(blocks)]
    if not ordered or any(len(block[role]) != 2 for block in ordered for role in ROLES):
        raise common.HarnessError(
            "paired resource bootstrap requires two observations per role per block"
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


def _resource_evidence_scope(measurements_publishable: bool) -> dict[str, Any]:
    """Bound the result to the claims this single-fixture probe can support."""

    return {
        "claim_scope": "resource_evidence_only",
        "measurements_publishable": measurements_publishable,
        "quality_certified": False,
        "energy_measured": False,
        "thermal_state_controlled": False,
        "thermal_state_measured": False,
        "single_fixture": True,
        "decision_role": "evidence_only",
        "promotion_decision": "not_evaluated",
    }


def _contract(
    config: Config,
    *,
    prompt_tokens: int,
    layers: int,
    patterns: Sequence[str],
    greedy_output_abi: str | None = None,
    materialized_logits_bytes: int | None = None,
    logitless_scratch_bytes: int | None = None,
    phase_signature: tuple[int, ...] | None = None,
) -> dict[str, Any]:
    strict_system_time = (
        platform.system() == "Darwin"
        and config.time_binary.resolve() == _SYSTEM_TIME_BINARY
        and not config.test_only_allow_non_system_time
    )
    contract: dict[str, Any] = {
        "comparison": (
            "same-binary-materialized-vs-logitless-required"
            if config.greedy_output_ab
            else (
                "same-binary-checked-vs-sealed-required"
                if config.decode_plan_ab
                else (
                    "same-binary-serial-vs-fused"
                    if config.serial_vs_fused
                    else "serial-vs-serial"
                )
            )
        ),
        "same_binary_required": (
            config.serial_vs_fused or config.decode_plan_ab or config.greedy_output_ab
        ),
        "policies": {role: _policy(config, role) for role in ROLES},
        "samples_per_role": config.samples_per_role,
        "warmups_per_role": config.warmups_per_role,
        "prompt_tokens": prompt_tokens,
        "new_tokens": config.new_tokens,
        "threads": config.threads,
        "cwd": str(config.cwd),
        "timeout_seconds": config.timeout_seconds,
        "parallel_attention_min_context": (
            config.threshold
            if (
                config.serial_vs_fused
                or config.decode_plan_ab
                or config.greedy_output_ab
            )
            else None
        ),
        "require_fused_gqa": config.serial_vs_fused,
        "require_paired_mlp": config.serial_vs_fused,
        "strict_decode_plan": config.decode_plan_ab,
        "strict_greedy_output": config.greedy_output_ab,
        "attention_layers": layers,
        "strict_prepared_glrt": True,
        "strict_batch_prefill": True,
        "strict_macos_time_lp": strict_system_time,
        "resource_evidence_scope": _resource_evidence_scope(strict_system_time),
        "time_provider": (
            "darwin-/usr/bin/time" if strict_system_time else "test-only-injected"
        ),
        "fresh_process_per_observation": True,
        "cache_regime": "process-cold/cache-uncontrolled-after-excluded-warmups",
        "os_cache_state_controlled": False,
        "os_cache_state_measured": False,
        "schedule_seed": config.schedule_seed,
        "patterns": list(patterns),
        "letter_mapping": {"A": "candidate", "B": "baseline"},
        "exact_completion_ids_required_across_all_invocations": True,
        "bootstrap": {
            "seed": config.bootstrap_seed,
            "resamples": config.bootstrap_resamples,
            "confidence": config.confidence,
            "unit": "balanced ABBA/BAAB block",
        },
        "time_flags": ["-lp", "-o", "{resource_record}"],
        "command_environment": dict(_COMMAND_ENVIRONMENT),
        "process_output_capture": _process_output_capture_contract(),
        "resource_metric_units": dict(_RESOURCE_UNITS),
        "ratio_fields": list(_RATIO_FIELDS),
        "relational_validation": {
            "phase_sum_relation": (
                "prefill_ms + decode_ms + sampling_ms <= internal_ms + "
                "rounding_tolerance; internal_ms may include uninstrumented "
                "generation overhead"
            ),
            "phase_internal_rounding_tolerance_ms": (
                _PHASE_INTERNAL_ROUNDING_TOLERANCE_MS
            ),
            "throughput_numerator": "exact completion token count",
            "throughput_denominator": "same unrounded internal generation timer",
            "internal_time_half_quantum_ms": _INTERNAL_TIME_HALF_QUANTUM_MS,
            "internal_tps_half_quantum": _INTERNAL_TPS_HALF_QUANTUM,
            "time_real_emission": (
                "Apple /usr/bin/time -p emits child elapsed time to "
                "centisecond precision"
            ),
            "time_real_emission_quantum_seconds": (
                _TIME_REAL_EMISSION_QUANTUM_SECONDS
            ),
            "time_wrapper_overhead_tolerance_seconds": (
                _TIME_WRAPPER_OVERHEAD_TOLERANCE_SECONDS
            ),
            "outer_wall_clock_lead_tolerance_seconds": (
                _OUTER_WALL_CLOCK_LEAD_TOLERANCE_SECONDS
            ),
        },
    }
    if config.greedy_output_ab:
        if (
            greedy_output_abi is None
            or materialized_logits_bytes is None
            or logitless_scratch_bytes is None
            or phase_signature is None
        ):
            raise common.HarnessError(
                "greedy-output resource contract is missing invariant telemetry"
            )
        contract.update(
            {
                "decode_plan_mode": "checked",
                "greedy_output_abi": greedy_output_abi,
                "materialized_logits_bytes": materialized_logits_bytes,
                "logitless_scratch_bytes": logitless_scratch_bytes,
                "expected_materialized_projections": config.new_tokens,
                "expected_logitless_projections": config.new_tokens - 1,
                "expected_producer_rows": (
                    (config.new_tokens - 1) * (materialized_logits_bytes // 4)
                ),
                "required_tile_output_bytes": 0,
                "required_argmax_scan_rows": 0,
                "strict_logitless_required": True,
                "zero_greedy_fallbacks_and_rejects_required": True,
                "exact_greedy_output_telemetry_required": True,
                "same_binary_path_required": True,
                "only_greedy_output_policy_varies": True,
                "constant_observation_output_paths": True,
                "require_fused_gqa": True,
                "require_paired_mlp": True,
                "stable_phase_signature_required": True,
                "phase_signature": list(phase_signature),
                "temperature_zero": True,
                "eos_disabled_with_uint32_max": True,
            }
        )
    return contract


def run_benchmark(config: Config) -> dict[str, Any]:
    _validate(config)
    artifacts_before = _fingerprints(config)
    _validate_comparison_artifacts(config, artifacts_before)
    try:
        prompt_ids = common.parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise common.HarnessError(f"cannot read prompt IDs: {error}") from error
    if config.serial_vs_fused:
        decode_runs = config.new_tokens - 1
        eligible = min(
            decode_runs,
            max(0, len(prompt_ids) + decode_runs - config.threshold + 1),
        )
        if eligible == 0:
            raise common.HarnessError(
                "serial-vs-fused campaign has no eligible parallel decode graphs"
            )
    if (config.decode_plan_ab or config.greedy_output_ab) and len(
        prompt_ids
    ) + 1 < config.threshold:
        raise common.HarnessError(
            "strict policy resource A/B threshold excludes the first decode graph"
        )

    patterns, order = build_measurement_order(
        config.samples_per_role, config.schedule_seed
    )
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    layers: int | None = None
    greedy_output_abi: str | None = None
    materialized_logits_bytes: int | None = None
    logitless_scratch_bytes: int | None = None
    phase_signature: tuple[int, ...] | None = None
    with tempfile.TemporaryDirectory(prefix="glacier-resource-ab.") as temporary:
        run_root = Path(temporary)

        def observe(
            role: str,
            *,
            warmup: bool,
            sequence_index: int,
            block_index: int,
            position: int,
            pattern: str,
        ) -> dict[str, Any]:
            nonlocal reference_ids
            nonlocal layers
            nonlocal greedy_output_abi
            nonlocal materialized_logits_bytes
            nonlocal logitless_scratch_bytes
            nonlocal phase_signature
            if config.greedy_output_ab:
                completion_path = run_root / "completion.ids"
                time_path = run_root / "time.txt"
            else:
                sample_root = run_root / (
                    f"{'warmup' if warmup else 'sample'}-{sequence_index:03d}-{role}"
                )
                sample_root.mkdir()
                completion_path = sample_root / "completion.ids"
                time_path = sample_root / "time.txt"
            item = _observe(
                config,
                role,
                completion_path,
                time_path,
                prompt_ids,
                artifacts_before,
            )
            if config.greedy_output_ab:
                try:
                    completion_path.unlink()
                    time_path.unlink()
                except OSError as error:
                    raise common.HarnessError(
                        f"cannot recycle greedy-output evidence paths: {error}"
                    ) from error
            item.update(
                {
                    "warmup": warmup,
                    "sequence_index": sequence_index,
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
                    f"exact completion IDs changed at {role} observation {sequence_index}"
                )
            observed_layers = int(item["metrics"]["attention_layers"])
            if layers is None:
                layers = observed_layers
            elif observed_layers != layers:
                raise common.HarnessError(
                    "self-described attention layer count changed during resource A/B"
                )
            if config.greedy_output_ab:
                observed_abi = str(item["metrics"]["greedy_output_abi"])
                if greedy_output_abi is None:
                    greedy_output_abi = observed_abi
                elif observed_abi != greedy_output_abi:
                    raise common.HarnessError(
                        "greedy-output ABI changed during resource A/B"
                    )
                observed_logits_bytes = int(
                    item["metrics"]["greedy_materialized_logits_bytes"]
                )
                if materialized_logits_bytes is None:
                    materialized_logits_bytes = observed_logits_bytes
                elif observed_logits_bytes != materialized_logits_bytes:
                    raise common.HarnessError(
                        "materialized logits bytes changed during resource A/B"
                    )
                if role == "candidate":
                    observed_scratch = int(item["metrics"]["greedy_scratch_bytes"])
                    if logitless_scratch_bytes is None:
                        logitless_scratch_bytes = observed_scratch
                    elif observed_scratch != logitless_scratch_bytes:
                        raise common.HarnessError(
                            "logitless scratch bytes changed during resource A/B"
                        )
                observed_signature = tuple(
                    int(item["metrics"][field])
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
                    phase_signature = observed_signature
                elif observed_signature != phase_signature:
                    raise common.HarnessError(
                        "stable phase coverage changed during resource A/B"
                    )
            return item

        warmup_start = list(ROLES)
        if config.schedule_seed & 1:
            warmup_start.reverse()
        for ordinal in range(config.warmups_per_role):
            warmup_order = (
                warmup_start if ordinal % 2 == 0 else list(reversed(warmup_start))
            )
            for position, role in enumerate(warmup_order):
                warmups.append(
                    observe(
                        role,
                        warmup=True,
                        sequence_index=len(warmups),
                        block_index=-1,
                        position=position,
                        pattern="warmup",
                    )
                )
        for slot in order:
            samples.append(
                observe(
                    str(slot["role"]),
                    warmup=False,
                    sequence_index=len(samples),
                    block_index=int(slot["block_index"]),
                    position=int(slot["position_in_block"]),
                    pattern=str(slot["pattern"]),
                )
            )

    artifacts_after = _verify_fingerprints(config, artifacts_before)
    assert reference_ids is not None
    assert layers is not None
    medians = {
        role: {
            field: statistics.median(
                float(sample["metrics"][field])
                for sample in samples
                if sample["role"] == role
            )
            for field in _MEDIAN_FIELDS
        }
        for role in ROLES
    }
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
    contract = _contract(
        config,
        prompt_tokens=len(prompt_ids),
        layers=layers,
        patterns=patterns,
        greedy_output_abi=greedy_output_abi,
        materialized_logits_bytes=materialized_logits_bytes,
        logitless_scratch_bytes=logitless_scratch_bytes,
        phase_signature=phase_signature,
    )
    contract_sha256 = common.sha256_bytes(
        json.dumps(
            contract,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    )
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "passed",
        "resource_evidence_scope": contract["resource_evidence_scope"],
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "python": sys.version,
        },
        "contract": contract,
        "contract_sha256": contract_sha256,
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


def _fsync_directory(descriptor: int, directory: Path) -> None:
    try:
        os.fsync(descriptor)
    except OSError as error:
        raise common.HarnessError(
            f"cannot fsync result directory: {directory}: {error}"
        ) from error


def _open_exclusive_temporary(directory_descriptor: int) -> tuple[str, int]:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    for _ in range(128):
        leaf = f".glacier-resource-ab.{secrets.token_hex(16)}.tmp"
        try:
            descriptor = os.open(
                leaf,
                flags,
                0o600,
                dir_fd=directory_descriptor,
            )
        except FileExistsError:
            continue
        except OSError as error:
            raise common.HarnessError(
                f"cannot create exclusive result temporary: {error}"
            ) from error
        return leaf, descriptor
    raise common.HarnessError("cannot allocate a unique result temporary name")


def write_resource_result(
    result: Mapping[str, Any], output: Path | None, overwrite: bool
) -> None:
    """Atomically publish a result, with race-safe no-replace semantics.

    A fully written and fsynced same-directory temporary is hard-linked into
    place when overwrite is disabled. The link either creates the destination
    name or fails with EEXIST, so concurrent creators can never replace one
    another and readers can never observe partial JSON.
    """

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

    if output.name in ("", ".", ".."):
        raise common.HarnessError(f"result output must name a file: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    directory_flags = (
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        directory_descriptor = os.open(output.parent, directory_flags)
    except OSError as error:
        raise common.HarnessError(
            f"cannot open result directory: {output.parent}: {error}"
        ) from error
    temporary_leaf: str | None = None
    try:
        temporary_leaf, temporary_descriptor = _open_exclusive_temporary(
            directory_descriptor
        )
        try:
            temporary_handle = os.fdopen(temporary_descriptor, "wb")
        except BaseException:
            os.close(temporary_descriptor)
            raise
        try:
            with temporary_handle:
                temporary_handle.write(rendered.encode("utf-8"))
                temporary_handle.flush()
                os.fsync(temporary_handle.fileno())
        except OSError as error:
            raise common.HarnessError(
                f"cannot write and fsync result temporary: {error}"
            ) from error

        if overwrite:
            try:
                os.replace(
                    temporary_leaf,
                    output.name,
                    src_dir_fd=directory_descriptor,
                    dst_dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise common.HarnessError(
                    f"cannot atomically replace result at {output}: {error}"
                ) from error
        else:
            try:
                os.link(
                    temporary_leaf,
                    output.name,
                    src_dir_fd=directory_descriptor,
                    dst_dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError as error:
                raise common.HarnessError(
                    f"output already exists; refusing replacement: {output}"
                ) from error
            except OSError as error:
                raise common.HarnessError(
                    f"cannot atomically publish result at {output}: {error}"
                ) from error
            os.unlink(temporary_leaf, dir_fd=directory_descriptor)
        temporary_leaf = None
        _fsync_directory(directory_descriptor, output.parent)
    finally:
        try:
            if temporary_leaf is not None:
                try:
                    os.unlink(temporary_leaf, dir_fd=directory_descriptor)
                except FileNotFoundError:
                    pass
        finally:
            os.close(directory_descriptor)
    sys.stderr.write(f"wrote {output}\n")


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return parsed


def argument_parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Run a hash-pinned, exact-ID macOS /usr/bin/time -lp A/B between "
            "Glacier binaries. The default is serial-vs-serial; opt in to "
            "strict same-binary policy execution with --serial-vs-fused or "
            "--decode-plan-ab or --greedy-output-ab."
        )
    )
    parser.add_argument("--baseline-binary", type=Path, required=True)
    parser.add_argument("--candidate-binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--ids", type=Path, required=True)
    parser.add_argument("-o", "--output", required=True, help="result JSON or '-'")
    parser.add_argument("--cwd", type=Path, default=repo_root)
    policy_group = parser.add_mutually_exclusive_group()
    policy_group.add_argument(
        "--serial-vs-fused",
        action="store_true",
        help=(
            "run one byte-identical binary with serial attention as baseline "
            "and strict fused GQA as candidate; otherwise both roles use "
            "serial attention"
        ),
    )
    policy_group.add_argument(
        "--decode-plan-ab",
        action="store_true",
        help=(
            "run one byte-identical binary with checked DecodePlan dispatch as "
            "baseline and strict sealed-required dispatch as candidate"
        ),
    )
    policy_group.add_argument(
        "--greedy-output-ab",
        action="store_true",
        help=(
            "run one binary with materialized greedy LM-head output as baseline "
            "and strict logitless-required output as candidate"
        ),
    )
    parser.add_argument("--threshold", type=_positive_int, default=128)
    parser.add_argument(
        "--samples-per-role", type=_positive_int, default=DEFAULT_SAMPLES_PER_ROLE
    )
    parser.add_argument(
        "--warmups-per-role", type=_positive_int, default=DEFAULT_WARMUPS_PER_ROLE
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
    parser.add_argument("--baseline-sha256")
    parser.add_argument("--candidate-sha256")
    parser.add_argument("--model-sha256")
    parser.add_argument("--ids-sha256")
    parser.add_argument("--time-sha256")
    parser.add_argument("--overwrite", action="store_true")
    return parser


def config_from_args(args: argparse.Namespace) -> Config:
    output = None if args.output == "-" else Path(args.output).expanduser().resolve()
    return Config(
        baseline_binary=args.baseline_binary.expanduser().resolve(),
        candidate_binary=args.candidate_binary.expanduser().resolve(),
        model=args.model.expanduser().resolve(),
        ids=args.ids.expanduser().resolve(),
        output=output,
        cwd=args.cwd.expanduser().resolve(),
        time_binary=_SYSTEM_TIME_BINARY,
        serial_vs_fused=args.serial_vs_fused,
        decode_plan_ab=args.decode_plan_ab,
        greedy_output_ab=args.greedy_output_ab,
        threshold=args.threshold,
        samples_per_role=args.samples_per_role,
        warmups_per_role=args.warmups_per_role,
        new_tokens=args.new_tokens,
        threads=args.threads,
        schedule_seed=args.schedule_seed,
        bootstrap_seed=args.bootstrap_seed,
        bootstrap_resamples=args.bootstrap_resamples,
        confidence=args.confidence,
        timeout_seconds=args.timeout_seconds,
        overwrite=args.overwrite,
        baseline_sha256=args.baseline_sha256,
        candidate_sha256=args.candidate_sha256,
        model_sha256=args.model_sha256,
        ids_sha256=args.ids_sha256,
        time_sha256=args.time_sha256,
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
            raise common.HarnessError(
                f"output already exists; pass --overwrite to replace it: {config.output}"
            )
        result = run_benchmark(config)
        write_resource_result(result, config.output, config.overwrite)
        return 0
    except (
        common.HarnessError,
        decode_plan.HarnessError,
        greedy_output.HarnessError,
        OSError,
        ValueError,
    ) as error:
        print(f"resource benchmark failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
