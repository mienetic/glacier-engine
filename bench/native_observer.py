#!/usr/bin/env python3
"""Bounded, read-only native host observation with explicit availability.

The adapter records only directly observed values. A value that cannot be
observed is ``None`` and carries one of ``missing``, ``denied``, or
``unsupported``; it is never replaced with a numeric zero. Raw command output
is retained only as byte counts and SHA-256 digests in provenance.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import threading
import time
from typing import Any, Callable, Mapping, Sequence


SCHEMA = "glacier.native-observation/macos-v1"
ADAPTER = "macos-read-only-command-observer/v1"
AVAILABILITIES = ("present", "missing", "denied", "unsupported")
PHASES = ("probe", "pre_run", "post_run")
PHASE_ALIASES = {
    "probe": "probe",
    "pre_run": "pre_run",
    "pre-run": "pre_run",
    "before": "pre_run",
    "post_run": "post_run",
    "post-run": "post_run",
    "after": "post_run",
}
MAX_TOP_ITERATIONS = 64
MAX_TOP_WINDOW_SECONDS = 60.0
MAX_PROBE_OUTPUT_BYTES = 1 << 20
I64_MAX = (1 << 63) - 1
POWER_SOURCE_UNKNOWN = 0
POWER_SOURCE_AC = 1
POWER_SOURCE_BATTERY = 2
THERMAL_NOMINAL = 0
THERMAL_CONSTRAINED = 1

PMSET = "/usr/bin/pmset"
VM_STAT = "/usr/bin/vm_stat"
TOP = "/usr/bin/top"
PS = "/bin/ps"
SYSCTL = "/usr/sbin/sysctl"

CommandRunner = Callable[
    [Sequence[str], float], subprocess.CompletedProcess[Any]
]


class ObservationError(RuntimeError):
    """A native observation request or strict parser failed."""


# name, subject, unit, sample clock domain, time-value clock domain
METRIC_SPECS = (
    (
        "host_monotonic_time",
        "host",
        "nanoseconds",
        "host_monotonic",
        "host_monotonic",
    ),
    ("host_logical_cpu_count", "host", "count", "host_monotonic", None),
    ("host_cpu_busy_ppm", "host", "ppm", "host_monotonic", None),
    ("host_external_cpu_ppm", "host", "ppm", "host_monotonic", None),
    ("host_cpu_idle_ppm", "host", "ppm", "host_monotonic", None),
    ("process_resident_bytes", "process", "bytes", "host_monotonic", None),
    (
        "host_available_memory_bytes",
        "host",
        "bytes",
        "host_monotonic",
        None,
    ),
    ("host_swap_used_bytes", "host", "bytes", "host_monotonic", None),
    ("host_power_source", "host", "count", "host_monotonic", None),
    ("host_low_power_mode", "host", "boolean", "host_monotonic", None),
    (
        "host_thermal_constraint",
        "host",
        "count",
        "host_monotonic",
        None,
    ),
)
_METRIC_SPEC_BY_NAME = {
    name: (subject, unit, sample_clock_domain, value_clock_domain)
    for (
        name,
        subject,
        unit,
        sample_clock_domain,
        value_clock_domain,
    ) in METRIC_SPECS
}


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _default_command_runner(
    argv: Sequence[str], timeout_seconds: float
) -> subprocess.CompletedProcess[bytes]:
    process = subprocess.Popen(
        list(argv),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"LC_ALL": "C", "PATH": os.defpath},
    )
    assert process.stdout is not None
    assert process.stderr is not None
    overflow = threading.Event()

    class Capture:
        def __init__(self) -> None:
            self.retained = bytearray()
            self.total_bytes = 0
            self.sha256 = hashlib.sha256()

    stdout_capture = Capture()
    stderr_capture = Capture()

    def drain(stream: Any, capture: Capture) -> None:
        while True:
            chunk = stream.read(64 * 1024)
            if not chunk:
                return
            capture.total_bytes += len(chunk)
            capture.sha256.update(chunk)
            remaining = MAX_PROBE_OUTPUT_BYTES + 1 - len(
                capture.retained
            )
            if remaining > 0:
                capture.retained.extend(chunk[:remaining])
            if capture.total_bytes > MAX_PROBE_OUTPUT_BYTES:
                overflow.set()
                try:
                    process.kill()
                except ProcessLookupError:
                    pass

    stdout_thread = threading.Thread(
        target=drain,
        args=(process.stdout, stdout_capture),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=drain,
        args=(process.stderr, stderr_capture),
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()
    timed_out = False
    try:
        returncode = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        returncode = process.wait()
    stdout_thread.join()
    stderr_thread.join()
    process.stdout.close()
    process.stderr.close()
    stdout = bytes(stdout_capture.retained)
    stderr = bytes(stderr_capture.retained)
    if timed_out:
        raise subprocess.TimeoutExpired(
            list(argv),
            timeout_seconds,
            output=stdout,
            stderr=stderr,
        )
    completed = subprocess.CompletedProcess(
        list(argv),
        returncode,
        stdout=stdout,
        stderr=stderr,
    )
    completed.glacier_output_exceeded = overflow.is_set()
    completed.glacier_stdout_bytes = stdout_capture.total_bytes
    completed.glacier_stderr_bytes = stderr_capture.total_bytes
    completed.glacier_stdout_sha256 = stdout_capture.sha256.hexdigest()
    completed.glacier_stderr_sha256 = stderr_capture.sha256.hexdigest()
    return completed


def _as_bytes(value: bytes | str | None) -> bytes:
    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    return value.encode("utf-8", errors="replace")


def _as_text(value: bytes) -> str:
    return value.decode("utf-8", errors="replace")


def _permission_message(value: bytes) -> bool:
    lowered = _as_text(value).lower()
    return "permission denied" in lowered or "operation not permitted" in lowered


def _probe_command(
    argv: Sequence[str],
    timeout_seconds: float,
    runner: CommandRunner,
) -> dict[str, Any]:
    """Run one fixed read-only command and retain bounded audit evidence."""

    command = list(argv)
    started_at_utc = _utc_now()
    started_ns = time.monotonic_ns()
    stdout = b""
    stderr = b""
    exit_status: int | None = None
    availability = "present"
    reason: str | None = None
    completed: subprocess.CompletedProcess[Any] | None = None
    try:
        completed = runner(command, timeout_seconds)
        stdout = _as_bytes(completed.stdout)
        stderr = _as_bytes(completed.stderr)
        exit_status = completed.returncode
        output_exceeded = bool(
            getattr(completed, "glacier_output_exceeded", False)
        )
        if (
            output_exceeded
            or len(stdout) > MAX_PROBE_OUTPUT_BYTES
            or len(stderr) > MAX_PROBE_OUTPUT_BYTES
        ):
            availability = "missing"
            reason = (
                "probe output exceeded the retained observation bound of "
                f"{MAX_PROBE_OUTPUT_BYTES} bytes"
            )
        elif exit_status != 0:
            availability = (
                "denied"
                if _permission_message(stderr) or _permission_message(stdout)
                else "missing"
            )
            reason = (
                f"probe exited {exit_status}; "
                f"stdout_bytes={len(stdout)}; stderr_bytes={len(stderr)}"
            )
    except PermissionError as exc:
        availability = "denied"
        reason = f"probe access was denied: {exc}"
    except FileNotFoundError as exc:
        availability = "unsupported"
        reason = f"probe executable is unavailable: {exc}"
    except subprocess.TimeoutExpired as exc:
        availability = "missing"
        stdout = _as_bytes(exc.stdout)
        stderr = _as_bytes(exc.stderr)
        reason = f"probe exceeded its {timeout_seconds:g} second timeout"
    except OSError as exc:
        availability = "denied" if exc.errno in (1, 13) else "missing"
        reason = f"probe failed: {exc}"
    except subprocess.SubprocessError as exc:
        availability = "missing"
        reason = f"probe failed: {exc}"

    finished_ns = time.monotonic_ns()
    stdout_bytes = (
        int(getattr(completed, "glacier_stdout_bytes", len(stdout)))
        if completed is not None
        else len(stdout)
    )
    stderr_bytes = (
        int(getattr(completed, "glacier_stderr_bytes", len(stderr)))
        if completed is not None
        else len(stderr)
    )
    stdout_sha256 = (
        str(getattr(completed, "glacier_stdout_sha256", _sha256(stdout)))
        if completed is not None
        else _sha256(stdout)
    )
    stderr_sha256 = (
        str(getattr(completed, "glacier_stderr_sha256", _sha256(stderr)))
        if completed is not None
        else _sha256(stderr)
    )
    provenance = {
        "adapter": ADAPTER,
        "sources": [
            {
                "kind": "command",
                "argv": command,
                "started_at_utc": started_at_utc,
                "finished_at_utc": _utc_now(),
                "started_monotonic_ns": started_ns,
                "finished_monotonic_ns": finished_ns,
                "timeout_seconds": timeout_seconds,
                "exit_status": exit_status,
                "stdout_bytes": stdout_bytes,
                "stdout_sha256": stdout_sha256,
                "stderr_bytes": stderr_bytes,
                "stderr_sha256": stderr_sha256,
            }
        ],
    }
    return {
        "availability": availability,
        "text": _as_text(stdout) if availability == "present" else None,
        "reason": reason,
        "provenance": provenance,
    }


def probe_command_strict(
    argv: Sequence[str],
    timeout_seconds: float,
    runner: CommandRunner = _default_command_runner,
) -> tuple[str, dict[str, Any]]:
    """Compatibility helper for callers that fail closed on a probe error."""

    result = _probe_command(argv, timeout_seconds, runner)
    if result["availability"] != "present":
        raise ObservationError(
            f"machine-state probe {argv[0]} failed: {result['reason']}"
        )
    return str(result["text"]), dict(result["provenance"])


def _parse_pmset_battery(text: str) -> dict[str, Any]:
    source_match = re.search(r"Now drawing from '([^']+)'", text)
    if source_match is None:
        raise ObservationError("pmset did not report the active power source")
    source = source_match.group(1).strip()

    battery_match = re.search(
        r"(?m)^\s*-[^\n]*?\s+(\d{1,3})%;\s*([^;\n]+);[^\n]*present:\s*(true|false)",
        text,
        re.IGNORECASE,
    )
    if battery_match is None and "InternalBattery" in text:
        raise ObservationError(
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
            raise ObservationError("pmset reported an invalid battery percentage")
        battery_status = battery_match.group(2).strip().lower()
    return {
        "source": source,
        "on_ac_power": source == "AC Power",
        "battery_present": battery_present,
        "battery_percent": battery_percent,
        "battery_status": battery_status,
        "battery_full": battery_percent == 100 if battery_present else None,
    }


def _parse_pmset_settings(custom_text: str, source: str) -> dict[str, Any]:
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
        raise ObservationError(
            f"pmset did not report lowpowermode for active source {source!r}"
        )
    normalized_settings = dict(sorted(active_settings.items()))
    settings_bytes = json.dumps(
        normalized_settings, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "low_power_mode": int(low_power_text),
        "active_settings": normalized_settings,
        "active_settings_sha256": _sha256(settings_bytes),
    }


def parse_pmset_power(battery_text: str, custom_text: str) -> dict[str, Any]:
    """Parse the strict power fields consumed by the paired harness."""

    battery = _parse_pmset_battery(battery_text)
    settings = _parse_pmset_settings(custom_text, str(battery["source"]))
    return {**battery, **settings}


def parse_pmset_thermal(
    text: str, logical_cpu_count: int | None
) -> dict[str, Any]:
    """Parse constraint signals without inferring a CPU temperature."""

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
        "status": (
            "constrained"
            if constrained
            else ("nominal" if available else "unavailable")
        ),
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
            raise ObservationError(f"vm_stat did not report {source_name}")
        result[output_name] = int(match.group(1))
    return result


def parse_vm_available_bytes(text: str) -> tuple[int, str]:
    """Return a transparent reclaimable-memory estimate from ``vm_stat``."""

    page_size_match = re.search(r"(?im)page size of\s+(\d+)\s+bytes", text)
    if page_size_match is None:
        raise ObservationError("vm_stat did not report its page size")
    page_size = int(page_size_match.group(1))
    if page_size <= 0:
        raise ObservationError("vm_stat reported an invalid page size")

    pages: dict[str, int] = {}
    names = ("Pages free", "Pages inactive", "Pages speculative")
    for name in names:
        match = re.search(rf"(?m)^{re.escape(name)}:\s+(\d+)\.\s*$", text)
        if match is not None:
            pages[name] = int(match.group(1))
    if "Pages free" not in pages:
        raise ObservationError("vm_stat did not report Pages free")
    available_bytes = sum(pages.values()) * page_size
    if available_bytes > I64_MAX:
        raise ObservationError("vm_stat available-memory estimate overflowed i64")
    formula = "+".join(name for name in names if name in pages)
    return available_bytes, f"({formula})*page_size"


def parse_swap_used_bytes(text: str) -> int:
    match = re.search(
        r"(?i)\bused\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT])\b",
        text,
    )
    if match is None:
        raise ObservationError("sysctl vm.swapusage did not report used swap")
    scale = {
        "K": 1 << 10,
        "M": 1 << 20,
        "G": 1 << 30,
        "T": 1 << 40,
    }[match.group(2).upper()]
    value = float(match.group(1)) * scale
    if not math.isfinite(value) or value < 0.0 or value > I64_MAX:
        raise ObservationError("sysctl vm.swapusage reported invalid used swap")
    return int(round(value))


def parse_process_rss_bytes(text: str) -> int:
    match = re.fullmatch(r"\s*(\d+)\s*", text)
    if match is None:
        raise ObservationError("ps did not report one RSS value")
    value = int(match.group(1)) * 1024
    if value > I64_MAX:
        raise ObservationError("ps RSS value overflowed i64")
    return value


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
        raise ObservationError(
            "top did not report matched Load Avg and CPU usage samples"
        )
    return load1, idle


def parse_external_cpu_processes(
    text: str,
    *,
    benchmark_pgid: int,
    harness_pid: int,
    sampler_pid: int,
    logical_cpu_count: int,
) -> dict[str, Any]:
    """Parse macOS ``ps`` rows and exclude the observed workload group."""

    if logical_cpu_count <= 0:
        raise ObservationError(
            "external CPU monitor requires a positive logical CPU count"
        )
    external: list[dict[str, Any]] = []
    parsed_rows = 0
    excluded_rows = 0
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        match = re.fullmatch(
            r"\s*(\d+)\s+(\d+)\s+(\d+)\s+"
            r"([0-9]+(?:\.[0-9]+)?)\s+(.+?)\s*",
            line,
        )
        if match is None:
            raise ObservationError(
                f"external CPU ps row {line_number} could not be parsed"
            )
        parsed_rows += 1
        pid = int(match.group(1))
        ppid = int(match.group(2))
        pgid = int(match.group(3))
        cpu_percent = float(match.group(4))
        if not math.isfinite(cpu_percent) or cpu_percent < 0.0:
            raise ObservationError(
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
        raise ObservationError("external CPU ps probe returned no process rows")
    external.sort(
        key=lambda row: float(
            row["cpu_percent_of_one_logical_cpu"]
        ),
        reverse=True,
    )
    external_sum = sum(
        float(row["cpu_percent_of_one_logical_cpu"])
        for row in external
    )
    return {
        "parsed_process_rows": parsed_rows,
        "excluded_process_rows": excluded_rows,
        "external_active_process_rows": len(external),
        "external_cpu_percent_of_one_logical_cpu_sum": external_sum,
        "external_cpu_capacity_percent": external_sum
        / logical_cpu_count,
        "top_external_processes": external[:8],
    }


def _runtime_provenance(system_name: str, api: str) -> dict[str, Any]:
    return {
        "adapter": ADAPTER,
        "sources": [{"kind": "runtime-api", "api": api, "system": system_name}],
    }


def _stable_source_descriptor(source: Mapping[str, Any]) -> dict[str, Any]:
    kind = source.get("kind")
    if kind == "command":
        argv = source.get("argv")
        if (
            not isinstance(argv, (list, tuple))
            or not argv
            or any(not isinstance(argument, str) for argument in argv)
        ):
            raise ObservationError(
                "command source identity requires nonempty string argv"
            )
        return {"kind": kind, "argv": list(argv)}
    if kind == "runtime-api":
        api = source.get("api")
        system = source.get("system")
        if (
            not isinstance(api, str)
            or not api
            or not isinstance(system, str)
            or not system
        ):
            raise ObservationError(
                "runtime source identity requires api and system"
            )
        return {"kind": kind, "api": api, "system": system}
    if kind == "deterministic-transform":
        expression = source.get("expression")
        if not isinstance(expression, str) or not expression:
            raise ObservationError(
                "transform source identity requires an expression"
            )
        return {"kind": kind, "expression": expression}
    raise ObservationError(f"unsupported provenance source kind {kind!r}")


def _source_identity_sha256(provenance: Mapping[str, Any]) -> str:
    adapter = provenance.get("adapter")
    sources = provenance.get("sources")
    if not isinstance(adapter, str) or not adapter:
        raise ObservationError("source identity requires an adapter")
    if not isinstance(sources, (list, tuple)) or not sources:
        raise ObservationError("source identity requires at least one source")
    descriptors = []
    for source in sources:
        if not isinstance(source, Mapping):
            raise ObservationError("provenance sources must be mappings")
        descriptors.append(_stable_source_descriptor(source))
    canonical = json.dumps(
        {"adapter": adapter, "sources": descriptors},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return _sha256(canonical)


def _derived_provenance(
    provenance: Mapping[str, Any], expression: str
) -> dict[str, Any]:
    sources = [dict(source) for source in provenance["sources"]]
    sources.append({"kind": "deterministic-transform", "expression": expression})
    return {"adapter": provenance["adapter"], "sources": sources}


def _combined_provenance(*probes: Mapping[str, Any]) -> dict[str, Any]:
    sources: list[dict[str, Any]] = []
    for probe in probes:
        sources.extend(
            dict(source) for source in probe["provenance"]["sources"]
        )
    return {"adapter": ADAPTER, "sources": sources}


def _combined_failure(*probes: Mapping[str, Any]) -> tuple[str, str]:
    availabilities = [str(probe["availability"]) for probe in probes]
    if "denied" in availabilities:
        availability = "denied"
    elif "missing" in availabilities:
        availability = "missing"
    else:
        availability = "unsupported"
    reasons = [
        str(probe["reason"]) for probe in probes if probe.get("reason") is not None
    ]
    return availability, "; ".join(reasons) or "observation source is unavailable"


def _metric(
    name: str,
    phase: str,
    availability: str,
    value: Any,
    provenance: Mapping[str, Any],
    reason: str | None = None,
) -> dict[str, Any]:
    if name not in _METRIC_SPEC_BY_NAME:
        raise ObservationError(f"unknown metric {name!r}")
    if availability not in AVAILABILITIES:
        raise ObservationError(f"invalid availability {availability!r}")
    if availability == "present" and value is None:
        raise ObservationError(f"present metric {name} must have a value")
    if availability != "present" and value is not None:
        raise ObservationError(f"unavailable metric {name} must not have a value")
    if availability == "present" and reason is not None:
        raise ObservationError(f"present metric {name} must not have a reason")
    if availability != "present" and (
        not isinstance(reason, str) or not reason
    ):
        raise ObservationError(f"unavailable metric {name} must have a reason")
    subject, unit, sample_clock_domain, value_clock_domain = (
        _METRIC_SPEC_BY_NAME[name]
    )
    if availability == "present":
        if isinstance(value, bool) or not isinstance(value, int):
            raise ObservationError(f"present metric {name} must be an i64")
        minimum_value = -273_150 if unit == "milli_celsius" else 0
        if not minimum_value <= value <= I64_MAX:
            raise ObservationError(
                f"present metric {name} must be an i64 in "
                f"[{minimum_value}, {I64_MAX}]"
            )
        if name == "host_logical_cpu_count" and value < 1:
            raise ObservationError(
                "host_logical_cpu_count must be at least 1"
            )
        if unit == "boolean" and value not in (0, 1):
            raise ObservationError(
                f"boolean metric {name} must be 0 or 1"
            )
        if unit == "ppm" and value > 1_000_000:
            raise ObservationError(
                f"ppm metric {name} must not exceed 1000000"
            )
    normalized_provenance = {
        "adapter": provenance["adapter"],
        "sources": [dict(source) for source in provenance["sources"]],
    }
    return {
        "name": name,
        "availability": availability,
        "value": value,
        "unit": unit,
        "sample_clock_domain": sample_clock_domain,
        "value_clock_domain": (
            value_clock_domain if availability == "present" else None
        ),
        "phase": phase,
        "subject": subject,
        "source_identity_sha256": _source_identity_sha256(
            normalized_provenance
        ),
        "provenance": normalized_provenance,
        "reason": reason,
        "reason_sha256": (
            _sha256(reason.encode("utf-8"))
            if availability != "present"
            else None
        ),
    }


def _unavailable_metric(
    name: str, phase: str, *probes: Mapping[str, Any]
) -> dict[str, Any]:
    availability, reason = _combined_failure(*probes)
    return _metric(
        name,
        phase,
        availability,
        None,
        _combined_provenance(*probes),
        reason,
    )


def _parse_missing_metric(
    name: str,
    phase: str,
    probe: Mapping[str, Any],
    reason: str,
) -> dict[str, Any]:
    return _metric(
        name,
        phase,
        "missing",
        None,
        probe["provenance"],
        reason,
    )


def _validate_capture_bounds(
    phase: str, top_iterations: int, sample_interval_seconds: float
) -> str:
    canonical_phase = PHASE_ALIASES.get(phase)
    if canonical_phase is None:
        raise ObservationError(f"phase must be one of {', '.join(PHASES)}")
    if (
        isinstance(top_iterations, bool)
        or not isinstance(top_iterations, int)
        or not 1 <= top_iterations <= MAX_TOP_ITERATIONS
    ):
        raise ObservationError(
            f"top_iterations must be an integer in [1, {MAX_TOP_ITERATIONS}]"
        )
    if (
        isinstance(sample_interval_seconds, bool)
        or not isinstance(sample_interval_seconds, (int, float))
        or not math.isfinite(float(sample_interval_seconds))
        or float(sample_interval_seconds) <= 0.0
    ):
        raise ObservationError("sample_interval_seconds must be finite and positive")
    window = (top_iterations - 1) * float(sample_interval_seconds)
    if window > MAX_TOP_WINDOW_SECONDS:
        raise ObservationError(
            f"top observation window must not exceed {MAX_TOP_WINDOW_SECONDS:g} seconds"
        )
    return canonical_phase


def _collect_darwin_metrics(
    *,
    phase: str,
    cpu_count: int | None,
    process_id: int,
    process_group_id: int,
    top_iterations: int,
    sample_interval_seconds: float,
    runner: CommandRunner,
) -> dict[str, dict[str, Any]]:
    battery_probe = _probe_command((PMSET, "-g", "batt"), 10.0, runner)
    settings_probe = _probe_command((PMSET, "-g", "custom"), 10.0, runner)
    thermal_probe = _probe_command((PMSET, "-g", "therm"), 10.0, runner)
    vm_probe = _probe_command((VM_STAT,), 10.0, runner)
    swap_probe = _probe_command((SYSCTL, "-n", "vm.swapusage"), 10.0, runner)
    rss_probe = _probe_command(
        (PS, "-o", "rss=", "-p", str(process_id)), 10.0, runner
    )
    external_cpu_probe = _probe_command(
        (
            PS,
            "-A",
            "-o",
            "pid=,ppid=,pgid=,pcpu=,comm=",
        ),
        10.0,
        runner,
    )
    top_window = (top_iterations - 1) * float(sample_interval_seconds)
    top_probe = _probe_command(
        (
            TOP,
            "-l",
            str(top_iterations),
            "-s",
            f"{sample_interval_seconds:g}",
            "-n",
            "0",
        ),
        top_window + 30.0,
        runner,
    )
    result: dict[str, dict[str, Any]] = {}

    battery: dict[str, Any] | None = None
    battery_parse_reason: str | None = None
    if battery_probe["availability"] != "present":
        result["host_power_source"] = _unavailable_metric(
            "host_power_source", phase, battery_probe
        )
    else:
        try:
            battery = _parse_pmset_battery(str(battery_probe["text"]))
        except ObservationError as exc:
            battery_parse_reason = (
                f"pmset battery output could not be parsed: {exc}"
            )
            result["host_power_source"] = _parse_missing_metric(
                "host_power_source",
                phase,
                battery_probe,
                battery_parse_reason,
            )
        else:
            power_source_code = {
                "AC Power": POWER_SOURCE_AC,
                "Battery Power": POWER_SOURCE_BATTERY,
            }.get(str(battery["source"]), POWER_SOURCE_UNKNOWN)
            result["host_power_source"] = _metric(
                "host_power_source",
                phase,
                "present",
                power_source_code,
                _derived_provenance(
                    battery_probe["provenance"],
                    "unknown=0,ac_power=1,battery_power=2",
                ),
            )

    if battery is None and battery_parse_reason is not None:
        result["host_low_power_mode"] = _metric(
            "host_low_power_mode",
            phase,
            "missing",
            None,
            _combined_provenance(battery_probe, settings_probe),
            battery_parse_reason,
        )
    elif battery is None or settings_probe["availability"] != "present":
        result["host_low_power_mode"] = _unavailable_metric(
            "host_low_power_mode", phase, battery_probe, settings_probe
        )
    else:
        try:
            settings = _parse_pmset_settings(
                str(settings_probe["text"]), str(battery["source"])
            )
            low_power_mode = int(settings["low_power_mode"])
            if low_power_mode not in (0, 1):
                raise ObservationError("pmset lowpowermode must be 0 or 1")
        except ObservationError as exc:
            result["host_low_power_mode"] = _parse_missing_metric(
                "host_low_power_mode",
                phase,
                settings_probe,
                f"pmset settings could not be parsed: {exc}",
            )
        else:
            result["host_low_power_mode"] = _metric(
                "host_low_power_mode",
                phase,
                "present",
                low_power_mode,
                _combined_provenance(battery_probe, settings_probe),
            )

    if thermal_probe["availability"] != "present":
        result["host_thermal_constraint"] = _unavailable_metric(
            "host_thermal_constraint", phase, thermal_probe
        )
    else:
        thermal = parse_pmset_thermal(
            str(thermal_probe["text"]), cpu_count
        )
        if thermal["signal_available"]:
            thermal_code = (
                THERMAL_CONSTRAINED
                if thermal["constrained"]
                else THERMAL_NOMINAL
            )
            result["host_thermal_constraint"] = _metric(
                "host_thermal_constraint",
                phase,
                "present",
                thermal_code,
                _derived_provenance(
                    thermal_probe["provenance"],
                    "nominal=0,constrained=1",
                ),
            )
        else:
            result["host_thermal_constraint"] = _parse_missing_metric(
                "host_thermal_constraint",
                phase,
                thermal_probe,
                "pmset did not report numeric CPU constraint signals",
            )

    if top_probe["availability"] != "present":
        for name in ("host_cpu_busy_ppm", "host_cpu_idle_ppm"):
            result[name] = _unavailable_metric(name, phase, top_probe)
    else:
        try:
            _load1, idle_samples = parse_top_state(str(top_probe["text"]))
            final_idle = float(idle_samples[-1])
            if not 0.0 <= final_idle <= 100.0:
                raise ObservationError("top CPU idle percent is outside [0, 100]")
            idle_ppm = int(round(final_idle * 10_000.0))
        except ObservationError as exc:
            reason = f"top output could not be parsed: {exc}"
            for name in ("host_cpu_busy_ppm", "host_cpu_idle_ppm"):
                result[name] = _parse_missing_metric(
                    name, phase, top_probe, reason
                )
        else:
            result["host_cpu_idle_ppm"] = _metric(
                "host_cpu_idle_ppm",
                phase,
                "present",
                idle_ppm,
                _derived_provenance(
                    top_probe["provenance"],
                    "round(final_cpu_idle_percent*10000)",
                ),
            )
            result["host_cpu_busy_ppm"] = _metric(
                "host_cpu_busy_ppm",
                phase,
                "present",
                1_000_000 - idle_ppm,
                _derived_provenance(
                    top_probe["provenance"],
                    "1000000-round(final_cpu_idle_percent*10000)",
                ),
            )

    if external_cpu_probe["availability"] != "present":
        result["host_external_cpu_ppm"] = _unavailable_metric(
            "host_external_cpu_ppm",
            phase,
            external_cpu_probe,
        )
    elif not isinstance(cpu_count, int) or cpu_count <= 0:
        result["host_external_cpu_ppm"] = _parse_missing_metric(
            "host_external_cpu_ppm",
            phase,
            external_cpu_probe,
            "external CPU normalization requires a positive logical CPU count",
        )
    else:
        try:
            external = parse_external_cpu_processes(
                str(external_cpu_probe["text"]),
                benchmark_pgid=process_group_id,
                harness_pid=process_id,
                sampler_pid=0,
                logical_cpu_count=cpu_count,
            )
            external_ppm = round(
                float(external["external_cpu_capacity_percent"])
                * 10_000
            )
            if not 0 <= external_ppm <= 1_000_000:
                raise ObservationError(
                    "external CPU capacity fell outside [0, 100%]"
                )
        except ObservationError as exc:
            result["host_external_cpu_ppm"] = _parse_missing_metric(
                "host_external_cpu_ppm",
                phase,
                external_cpu_probe,
                f"external CPU process sample could not be parsed: {exc}",
            )
        else:
            result["host_external_cpu_ppm"] = _metric(
                "host_external_cpu_ppm",
                phase,
                "present",
                external_ppm,
                _derived_provenance(
                    external_cpu_probe["provenance"],
                    "round(sum(external_pcpu)/logical_cpu_count*10000)",
                ),
            )

    if rss_probe["availability"] != "present":
        result["process_resident_bytes"] = _unavailable_metric(
            "process_resident_bytes", phase, rss_probe
        )
    else:
        try:
            rss_bytes = parse_process_rss_bytes(str(rss_probe["text"]))
        except ObservationError as exc:
            result["process_resident_bytes"] = _parse_missing_metric(
                "process_resident_bytes",
                phase,
                rss_probe,
                f"process RSS could not be parsed: {exc}",
            )
        else:
            result["process_resident_bytes"] = _metric(
                "process_resident_bytes",
                phase,
                "present",
                rss_bytes,
                _derived_provenance(rss_probe["provenance"], "rss_kib*1024"),
            )

    if vm_probe["availability"] != "present":
        result["host_available_memory_bytes"] = _unavailable_metric(
            "host_available_memory_bytes", phase, vm_probe
        )
    else:
        try:
            available_bytes, formula = parse_vm_available_bytes(
                str(vm_probe["text"])
            )
        except ObservationError as exc:
            result["host_available_memory_bytes"] = _parse_missing_metric(
                "host_available_memory_bytes",
                phase,
                vm_probe,
                f"vm_stat available memory could not be parsed: {exc}",
            )
        else:
            result["host_available_memory_bytes"] = _metric(
                "host_available_memory_bytes",
                phase,
                "present",
                available_bytes,
                _derived_provenance(vm_probe["provenance"], formula),
            )

    if swap_probe["availability"] != "present":
        result["host_swap_used_bytes"] = _unavailable_metric(
            "host_swap_used_bytes", phase, swap_probe
        )
    else:
        try:
            swap_used_bytes = parse_swap_used_bytes(str(swap_probe["text"]))
        except ObservationError as exc:
            result["host_swap_used_bytes"] = _parse_missing_metric(
                "host_swap_used_bytes",
                phase,
                swap_probe,
                f"swap usage could not be parsed: {exc}",
            )
        else:
            result["host_swap_used_bytes"] = _metric(
                "host_swap_used_bytes",
                phase,
                "present",
                swap_used_bytes,
                swap_probe["provenance"],
            )
    return result


def capture_observation(
    phase: str,
    *,
    runner: CommandRunner = _default_command_runner,
    system_name: str | None = None,
    logical_cpu_count: int | None = None,
    process_id: int | None = None,
    process_group_id: int | None = None,
    top_iterations: int = 2,
    sample_interval_seconds: float = 1.0,
) -> dict[str, Any]:
    """Capture one fixed-universe observation without starting a workload."""

    phase = _validate_capture_bounds(
        phase, top_iterations, sample_interval_seconds
    )
    system = system_name if system_name is not None else platform.system()
    cpu_count = os.cpu_count() if logical_cpu_count is None else logical_cpu_count
    pid = os.getpid() if process_id is None else process_id
    if (
        isinstance(pid, bool)
        or not isinstance(pid, int)
        or not 1 <= pid <= (1 << 31) - 1
    ):
        raise ObservationError("process_id must be a positive 31-bit integer")
    if process_group_id is None:
        try:
            pgid = os.getpgid(pid)
        except (OSError, ProcessLookupError):
            pgid = pid
    else:
        pgid = process_group_id
    if (
        isinstance(pgid, bool)
        or not isinstance(pgid, int)
        or not 1 <= pgid <= (1 << 31) - 1
    ):
        raise ObservationError(
            "process_group_id must be a positive 31-bit integer"
        )

    started_ns = time.monotonic_ns()
    default_provenance = _runtime_provenance(system, "adapter-capability")
    records = {
        name: _metric(
            name,
            phase,
            "unsupported",
            None,
            default_provenance,
            f"{ADAPTER} does not directly observe this metric on {system}",
        )
        for (
            name,
            _subject,
            _unit,
            _sample_clock_domain,
            _value_clock_domain,
        ) in METRIC_SPECS
    }
    records["host_monotonic_time"] = _metric(
        "host_monotonic_time",
        phase,
        "present",
        started_ns,
        _runtime_provenance(system, "time.monotonic_ns"),
    )
    if (
        isinstance(cpu_count, int)
        and not isinstance(cpu_count, bool)
        and cpu_count > 0
    ):
        records["host_logical_cpu_count"] = _metric(
            "host_logical_cpu_count",
            phase,
            "present",
            cpu_count,
            _runtime_provenance(system, "os.cpu_count"),
        )
    else:
        records["host_logical_cpu_count"] = _metric(
            "host_logical_cpu_count",
            phase,
            "missing",
            None,
            _runtime_provenance(system, "os.cpu_count"),
            "the runtime did not report a positive logical CPU count",
        )

    if system == "Darwin":
        records.update(
            _collect_darwin_metrics(
                phase=phase,
                cpu_count=cpu_count if isinstance(cpu_count, int) else None,
                process_id=pid,
                process_group_id=pgid,
                top_iterations=top_iterations,
                sample_interval_seconds=sample_interval_seconds,
                runner=runner,
            )
        )

    finished_ns = time.monotonic_ns()
    metrics = [
        records[name]
        for (
            name,
            _subject,
            _unit,
            _sample_clock_domain,
            _value_clock_domain,
        ) in METRIC_SPECS
    ]
    availability_counts = {
        availability: sum(
            metric["availability"] == availability for metric in metrics
        )
        for availability in AVAILABILITIES
    }
    return {
        "schema": SCHEMA,
        "adapter": ADAPTER,
        "phase": phase,
        "system": system,
        "observed_process_id": pid,
        "captured_at_utc": _utc_now(),
        "capture_interval": {
            "sample_clock_domain": "host_monotonic",
            "started_ns": started_ns,
            "finished_ns": finished_ns,
        },
        "availability_counts": availability_counts,
        "metrics": metrics,
        "claim_scope": "native-observation-only",
    }


def metric_by_name(
    observation: Mapping[str, Any], name: str
) -> Mapping[str, Any]:
    """Return one metric from a capture, rejecting duplicates and absence."""

    matches = [
        metric
        for metric in observation.get("metrics", [])
        if isinstance(metric, Mapping) and metric.get("name") == name
    ]
    if len(matches) != 1:
        raise ObservationError(f"expected exactly one metric named {name!r}")
    return matches[0]
