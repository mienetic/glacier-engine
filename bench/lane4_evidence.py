#!/usr/bin/env python3
"""Fail-closed admission and validation for DecodeLane4 measurements.

This module deliberately does not run a benchmark or calculate a speedup.  It
provides two narrower pieces that can exist before the DecodeLane4 runner API:

* ``probe`` requires AC power, unconstrained ``pmset`` performance, and a
  hash-pinned Foundation ``ProcessInfo`` probe reporting nominal thermal state
  with Low Power Mode disabled. Unknown states are rejected.
* ``validate`` checks an already-produced M1x4-versus-B4 raw evidence envelope.
  It enforces the same runner/model, equal worker budget, four independent
  logical requests, balanced ABBA/BAAB blocks, exact per-lane state equality,
  full canonical token IDs, and an admitted environment snapshot on both sides
  of every observation. The 128/512/2048/4096 matrix names terminal committed
  KV positions, not prompt lengths; a 64-token run therefore uses
  ``prompt = terminal - 64 + 1``.

Passing ``probe`` only admits the environment. Passing ``validate`` proves the
shape and internal consistency of a future runner envelope, not that today's
runner emits those events. Until grounded runner telemetry exists, raw timing,
resource, and performance analysis remain unavailable and non-publishable. The
output never reports a speedup.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


RAW_SCHEMA = "glacier.decode-lane4/raw-evidence-v2"
ENVIRONMENT_SCHEMA = "glacier.decode-lane4/environment-v1"
GATE_SCHEMA = "glacier.decode-lane4/evidence-gate-v2"
COMPARISON = "same-binary-m1x4-vs-b4"
EXPECTED_TERMINAL_KV_POSITIONS = (128, 512, 2048, 4096)
WIDTH = 4
TOTAL_WORKER_THREADS = 4
NEW_TOKENS_PER_LANE = 64
MIN_BLOCKS_PER_PATTERN = 8
MIN_OBSERVATIONS_PER_ARM = 32
MODE_M1X4 = "m1x4"
MODE_B4 = "b4"
MODE_FOR_LETTER = {"A": MODE_M1X4, "B": MODE_B4}
VALID_PATTERNS = ("ABBA", "BAAB")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
PMSET = "/usr/bin/pmset"
SYSCTL = "/usr/sbin/sysctl"
SWIFT = "/usr/bin/swift"
PROCESS_INFO_SCHEMA = "glacier.decode-lane4/process-info-v1"
FOUNDATION_PROBE_SOURCE = Path(__file__).with_name("lane4_process_info.swift")
FOUNDATION_PROBE_SOURCE_SHA256 = (
    "631c45bad5f6dd2c24e268f97cbccbca5661277f8ad03103db872990bff1979c"
)
DECODE_LANE4_ABI = 0x4744_4C34_0000_0002
RESOURCE_BANK_ABI = 0x4752_424B_0000_0001
GENERATION_STATE_ABI = 0x4747_5354_0000_0001
GENERATION_RNG_ABI = 0x584F_5332_3536_0001
OUTPUT_TOKEN_HASH_ABI = "glacier-output-token-state-v1"
OUTPUT_TOKEN_HASH_DOMAIN = OUTPUT_TOKEN_HASH_ABI.encode("ascii") + b"\x00"
WORKLOAD_ABI = 0x474C_3457_0000_0001
M1X4_EXECUTION_ABI = 0x474D_3145_0000_0001
M1X4_CONCURRENCY_ABI = 0x474D_3143_0000_0001
MONOTONIC_CLOCK_ABI = "monotonic-nanoseconds/v1"
CLAIM_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "logits_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "device_bytes",
    "io_bytes",
    "queue_slots",
)
HOST_CLAIM_FIELDS = CLAIM_FIELDS[:7]
LIMIT_FIELDS = ("host_bytes",) + CLAIM_FIELDS
U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1


class EvidenceError(RuntimeError):
    """The evidence is malformed or violates the comparison contract."""


CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


def _default_command_runner(argv: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=10,
        env={
            key: value
            for key, value in os.environ.items()
            if key in {"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ"}
        },
    )


def _run_probe_command(
    runner: CommandRunner, argv: Sequence[str]
) -> tuple[str | None, str | None]:
    try:
        completed = runner(argv)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"{' '.join(argv)} failed: {exc}"
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "no output"
        return None, f"{' '.join(argv)} exited {completed.returncode}: {detail}"
    return completed.stdout, None


def parse_pmset_battery(text: str) -> dict[str, Any]:
    """Parse ``pmset -g batt`` without treating an unknown state as AC."""

    source_match = re.search(r"Now drawing from '([^']+)'", text)
    source = source_match.group(1) if source_match else None
    lower = text.lower()
    if "discharging" in lower:
        battery_state = "discharging"
    elif "charged" in lower:
        battery_state = "charged"
    elif "charging" in lower:
        battery_state = "charging"
    elif "no batteries" in lower:
        battery_state = "not_present"
    else:
        battery_state = "unknown"

    reasons: list[str] = []
    if source != "AC Power":
        reasons.append(
            "power source is not explicitly AC Power"
            if source is not None
            else "pmset did not report a power source"
        )
    if battery_state == "discharging":
        reasons.append("battery is discharging")
    if battery_state == "unknown":
        reasons.append("battery state is unknown")
    return {
        "power_source": source or "unknown",
        "battery_state": battery_state,
        "admitted": not reasons,
        "reasons": reasons,
    }


def parse_pmset_thermal(text: str) -> dict[str, Any]:
    """Accept only an explicit no-warning/100%-limit thermal state."""

    lower = text.lower()
    no_thermal_warning = "no thermal warning level has been recorded" in lower
    no_performance_warning = "no performance warning level has been recorded" in lower
    numeric_limits = {
        name.lower(): int(value)
        for name, value in re.findall(
            r"(?im)^\s*(CPU_Speed_Limit|Scheduler_Limit|Available_CPUs)"
            r"\s*=\s*(\d+)\s*$",
            text,
        )
    }
    non_full_limits = sorted(
        name
        for name, value in numeric_limits.items()
        if name in {"cpu_speed_limit", "scheduler_limit"} and value != 100
    )
    explicit_warning = bool(
        re.search(r"(?im)^\s*(thermal|performance) warning level\s*=", text)
    )

    reasons: list[str] = []
    if not no_thermal_warning:
        reasons.append("thermal no-warning state was not explicit")
    if not no_performance_warning:
        reasons.append("performance no-warning state was not explicit")
    if explicit_warning:
        reasons.append("pmset reported an explicit warning level")
    if non_full_limits:
        reasons.append("pmset did not report a full CPU or scheduler limit")
    return {
        "thermal_state": "nominal" if not reasons else "unknown_or_constrained",
        "cpu_speed_limit_percent": numeric_limits.get("cpu_speed_limit"),
        "scheduler_limit_percent": numeric_limits.get("scheduler_limit"),
        "available_cpus": numeric_limits.get("available_cpus"),
        "admitted": not reasons,
        "reasons": reasons,
    }


def parse_process_info_probe(text: str) -> dict[str, Any]:
    """Parse the hash-pinned Foundation ProcessInfo probe fail-closed."""

    reasons: list[str] = []
    try:
        value = json.loads(
            text,
            object_pairs_hook=_json_no_duplicates,
            parse_constant=_reject_json_constant,
        )
        payload = _mapping(value, "Foundation ProcessInfo output")
    except (EvidenceError, json.JSONDecodeError) as exc:
        return {
            "foundation_thermal_state": "unknown",
            "low_power_mode_enabled": None,
            "admitted": False,
            "reasons": [f"Foundation ProcessInfo output is invalid: {exc}"],
        }
    expected_fields = {"schema", "thermal_state", "low_power_mode_enabled"}
    if set(payload) != expected_fields:
        reasons.append("Foundation ProcessInfo output fields do not match the pinned ABI")
    if payload.get("schema") != PROCESS_INFO_SCHEMA:
        reasons.append("Foundation ProcessInfo schema does not match")
    thermal_state = payload.get("thermal_state")
    if thermal_state not in {"nominal", "fair", "serious", "critical", "unknown"}:
        thermal_state = "unknown"
        reasons.append("Foundation thermal state is invalid")
    low_power_mode = payload.get("low_power_mode_enabled")
    if not isinstance(low_power_mode, bool):
        low_power_mode = None
        reasons.append("Foundation Low Power Mode state is invalid")
    if thermal_state != "nominal":
        reasons.append("Foundation thermal state is not nominal")
    if low_power_mode is not False:
        reasons.append("Foundation Low Power Mode is enabled or unknown")
    return {
        "foundation_thermal_state": thermal_state,
        "low_power_mode_enabled": low_power_mode,
        "admitted": not reasons,
        "reasons": reasons,
    }


def _probe_file_sha256(path: Path) -> tuple[str | None, str | None]:
    try:
        if not path.is_file():
            return None, f"Foundation probe source is not a regular file: {path}"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        return None, f"Foundation probe source cannot be hashed: {exc}"
    if digest != FOUNDATION_PROBE_SOURCE_SHA256:
        return digest, "Foundation probe source SHA-256 does not match the pinned ABI"
    return digest, None


def _foundation_runner_sha256() -> tuple[str | None, str | None]:
    try:
        path = Path(SWIFT)
        if not path.is_file():
            return None, f"Foundation probe runner is not a regular file: {path}"
        return hashlib.sha256(path.read_bytes()).hexdigest(), None
    except OSError as exc:
        return None, f"Foundation probe runner cannot be hashed: {exc}"


def _host_descriptor(cpu_brand: str, boot_session: str | None) -> dict[str, Any]:
    descriptor = {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "cpu_brand": cpu_brand,
        "logical_cpu_count": os.cpu_count(),
        # Hashing the boot-session UUID proves one physical boot without
        # publishing the host identifier itself.
        "boot_session_sha256": (
            hashlib.sha256(boot_session.encode("ascii")).hexdigest()
            if boot_session is not None
            else None
        ),
    }
    canonical = json.dumps(
        descriptor, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")
    descriptor["fingerprint_sha256"] = hashlib.sha256(canonical).hexdigest()
    return descriptor


def capture_environment(runner: CommandRunner = _default_command_runner) -> dict[str, Any]:
    """Capture a measurement boundary snapshot, failing closed on uncertainty."""

    reasons: list[str] = []
    battery_text: str | None = None
    thermal_text: str | None = None
    process_info_text: str | None = None
    foundation_probe_source_sha256: str | None = None
    foundation_probe_runner_sha256: str | None = None
    cpu_brand = platform.processor() or "unknown"
    boot_session: str | None = None

    if platform.system() != "Darwin":
        reasons.append("measurement admission requires Darwin pmset")
    else:
        battery_text, error = _run_probe_command(runner, (PMSET, "-g", "batt"))
        if error is not None:
            reasons.append(error)
        thermal_text, error = _run_probe_command(runner, (PMSET, "-g", "therm"))
        if error is not None:
            reasons.append(error)
        brand_text, _error = _run_probe_command(
            runner, (SYSCTL, "-n", "machdep.cpu.brand_string")
        )
        if brand_text and brand_text.strip():
            cpu_brand = brand_text.strip()
        boot_text, error = _run_probe_command(
            runner, (SYSCTL, "-n", "kern.bootsessionuuid")
        )
        if error is not None:
            reasons.append(error)
        elif boot_text and boot_text.strip():
            boot_session = boot_text.strip()
        else:
            reasons.append("sysctl did not report a boot-session UUID")
        foundation_probe_source_sha256, error = _probe_file_sha256(
            FOUNDATION_PROBE_SOURCE
        )
        if error is not None:
            reasons.append(error)
        foundation_probe_runner_sha256, runner_error = (
            _foundation_runner_sha256()
        )
        if runner_error is not None:
            reasons.append(runner_error)
        if error is None and foundation_probe_runner_sha256 is not None:
            process_info_text, error = _run_probe_command(
                runner, (SWIFT, str(FOUNDATION_PROBE_SOURCE))
            )
            if error is not None:
                reasons.append(error)
            source_after, source_error = _probe_file_sha256(FOUNDATION_PROBE_SOURCE)
            if source_error is not None or source_after != foundation_probe_source_sha256:
                reasons.append(
                    source_error
                    or "Foundation probe source changed while the probe was running"
                )

    power = (
        parse_pmset_battery(battery_text)
        if battery_text is not None
        else {
            "power_source": "unknown",
            "battery_state": "unknown",
            "admitted": False,
            "reasons": [],
        }
    )
    thermal = (
        parse_pmset_thermal(thermal_text)
        if thermal_text is not None
        else {
            "thermal_state": "unknown_or_constrained",
            "cpu_speed_limit_percent": None,
            "scheduler_limit_percent": None,
            "available_cpus": None,
            "admitted": False,
            "reasons": [],
        }
    )
    process_info = (
        parse_process_info_probe(process_info_text)
        if process_info_text is not None
        else {
            "foundation_thermal_state": "unknown",
            "low_power_mode_enabled": None,
            "admitted": False,
            "reasons": [],
        }
    )
    reasons.extend(power["reasons"])
    reasons.extend(thermal["reasons"])
    reasons.extend(process_info["reasons"])
    if (
        thermal["available_cpus"] is not None
        and thermal["available_cpus"] != os.cpu_count()
    ):
        reasons.append("pmset reported fewer or more available CPUs than the host")
    admitted = (
        not reasons
        and power["admitted"]
        and thermal["admitted"]
        and process_info["admitted"]
    )
    return {
        "schema": ENVIRONMENT_SCHEMA,
        "captured_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": _host_descriptor(cpu_brand, boot_session),
        "power_source": power["power_source"],
        "battery_state": power["battery_state"],
        "thermal_state": thermal["thermal_state"],
        "foundation_thermal_state": process_info["foundation_thermal_state"],
        "low_power_mode_enabled": process_info["low_power_mode_enabled"],
        "cpu_speed_limit_percent": thermal["cpu_speed_limit_percent"],
        "scheduler_limit_percent": thermal["scheduler_limit_percent"],
        "available_cpus": thermal["available_cpus"],
        "raw_pmset_battery_sha256": (
            hashlib.sha256(battery_text.encode("utf-8")).hexdigest()
            if battery_text is not None
            else None
        ),
        "raw_pmset_thermal_sha256": (
            hashlib.sha256(thermal_text.encode("utf-8")).hexdigest()
            if thermal_text is not None
            else None
        ),
        "raw_foundation_process_info_sha256": (
            hashlib.sha256(process_info_text.encode("utf-8")).hexdigest()
            if process_info_text is not None
            else None
        ),
        "foundation_probe_source_sha256": foundation_probe_source_sha256,
        "foundation_probe_runner_sha256": foundation_probe_runner_sha256,
        "measurement_admitted": admitted,
        "reasons": reasons,
        "claim_scope": "environment-admission-only",
        "performance_claim": "not_evaluated",
        "promotion_decision": "not_evaluated",
        "measurements_publishable": False,
    }


def _mapping(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise EvidenceError(f"{where} must be an object with string keys")
    return value


def _array(value: Any, where: str, length: int | None = None) -> list[Any]:
    if not isinstance(value, list):
        raise EvidenceError(f"{where} must be an array")
    if length is not None and len(value) != length:
        raise EvidenceError(f"{where} must contain exactly {length} items")
    return value


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise EvidenceError(f"{where} must be a non-empty string without NUL")
    return value


def _integer(value: Any, where: str, minimum: int, maximum: int) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not minimum <= value <= maximum
    ):
        raise EvidenceError(f"{where} must be an integer in [{minimum}, {maximum}]")
    return value


def _sha256(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if SHA256_RE.fullmatch(result) is None:
        raise EvidenceError(f"{where} must be a 64-character SHA-256 digest")
    return result


def _required(obj: Mapping[str, Any], key: str, where: str) -> Any:
    if key not in obj:
        raise EvidenceError(f"{where}.{key} is required")
    return obj[key]


def _exact_keys(obj: Mapping[str, Any], expected: Iterable[str], where: str) -> None:
    expected_set = set(expected)
    missing = sorted(expected_set - set(obj))
    unknown = sorted(set(obj) - expected_set)
    if missing or unknown:
        details: list[str] = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if unknown:
            details.append("unknown " + ", ".join(unknown))
        raise EvidenceError(f"{where} fields are not exact: {'; '.join(details)}")


def _parse_utc(value: Any, where: str) -> dt.datetime:
    text = _string(value, where)
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        raise EvidenceError(f"{where} must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise EvidenceError(f"{where} must include a UTC offset")
    return parsed.astimezone(dt.timezone.utc)


def _fingerprint_file(
    path_value: Any,
    expected_value: Any,
    where: str,
    *,
    executable: bool = False,
) -> dict[str, Any]:
    path = Path(_string(path_value, f"{where}.path")).expanduser().resolve(strict=False)
    expected = _sha256(expected_value, f"{where}.sha256")
    try:
        info = path.stat()
    except OSError as exc:
        raise EvidenceError(f"{where}.path cannot be read: {exc}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise EvidenceError(f"{where}.path must name a regular file")
    if executable and info.st_mode & 0o111 == 0:
        raise EvidenceError(f"{where}.path must be executable")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise EvidenceError(f"{where}.path cannot be hashed: {exc}") from exc
    actual = digest.hexdigest()
    if actual != expected:
        raise EvidenceError(f"{where}.sha256 does not match the current file")
    return {"path": str(path), "sha256": actual, "size_bytes": info.st_size}


def _validate_environment(
    value: Any,
    where: str,
    *,
    expected_foundation_runner_sha256: str,
) -> tuple[tuple[str, str, str], dt.datetime]:
    snapshot = _mapping(value, where)
    _exact_keys(
        snapshot,
        {
            "schema",
            "captured_at_utc",
            "host",
            "power_source",
            "battery_state",
            "thermal_state",
            "foundation_thermal_state",
            "low_power_mode_enabled",
            "cpu_speed_limit_percent",
            "scheduler_limit_percent",
            "available_cpus",
            "raw_pmset_battery_sha256",
            "raw_pmset_thermal_sha256",
            "raw_foundation_process_info_sha256",
            "foundation_probe_source_sha256",
            "foundation_probe_runner_sha256",
            "measurement_admitted",
            "reasons",
            "claim_scope",
            "performance_claim",
            "promotion_decision",
            "measurements_publishable",
        },
        where,
    )
    if snapshot.get("schema") != ENVIRONMENT_SCHEMA:
        raise EvidenceError(f"{where}.schema must be {ENVIRONMENT_SCHEMA!r}")
    captured = _parse_utc(
        _required(snapshot, "captured_at_utc", where),
        f"{where}.captured_at_utc",
    )
    host = _mapping(_required(snapshot, "host", where), f"{where}.host")
    _exact_keys(
        host,
        {
            "system",
            "release",
            "machine",
            "cpu_brand",
            "logical_cpu_count",
            "boot_session_sha256",
            "fingerprint_sha256",
        },
        f"{where}.host",
    )
    host_descriptor = {
        "system": _string(
            _required(host, "system", f"{where}.host"), f"{where}.host.system"
        ),
        "release": _string(
            _required(host, "release", f"{where}.host"), f"{where}.host.release"
        ),
        "machine": _string(
            _required(host, "machine", f"{where}.host"), f"{where}.host.machine"
        ),
        "cpu_brand": _string(
            _required(host, "cpu_brand", f"{where}.host"),
            f"{where}.host.cpu_brand",
        ),
        "logical_cpu_count": _integer(
            _required(host, "logical_cpu_count", f"{where}.host"),
            f"{where}.host.logical_cpu_count",
            1,
            1 << 20,
        ),
        "boot_session_sha256": _sha256(
            _required(host, "boot_session_sha256", f"{where}.host"),
            f"{where}.host.boot_session_sha256",
        ),
    }
    if host_descriptor["system"] != "Darwin" or host_descriptor["machine"] != "arm64":
        raise EvidenceError(f"{where}.host must be Darwin arm64")
    fingerprint = _sha256(
        _required(host, "fingerprint_sha256", f"{where}.host"),
        f"{where}.host.fingerprint_sha256",
    )
    canonical_host = json.dumps(
        host_descriptor, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")
    if hashlib.sha256(canonical_host).hexdigest() != fingerprint:
        raise EvidenceError(f"{where}.host.fingerprint_sha256 is inconsistent")
    if snapshot.get("power_source") != "AC Power":
        raise EvidenceError(f"{where}.power_source must be 'AC Power'")
    if snapshot.get("battery_state") in {"discharging", "unknown", None}:
        raise EvidenceError(f"{where}.battery_state is not admitted")
    if snapshot.get("thermal_state") != "nominal":
        raise EvidenceError(f"{where}.thermal_state must be 'nominal'")
    if snapshot.get("foundation_thermal_state") != "nominal":
        raise EvidenceError(f"{where}.foundation_thermal_state must be 'nominal'")
    if snapshot.get("low_power_mode_enabled") is not False:
        raise EvidenceError(f"{where}.low_power_mode_enabled must be false")
    for field in ("cpu_speed_limit_percent", "scheduler_limit_percent"):
        value = snapshot.get(field)
        if value is not None and _integer(value, f"{where}.{field}", 0, 100) != 100:
            raise EvidenceError(f"{where}.{field} must be 100 when reported")
    available_cpus = snapshot.get("available_cpus")
    if available_cpus is not None and (
        _integer(
            available_cpus,
            f"{where}.available_cpus",
            1,
            1 << 20,
        )
        != host_descriptor["logical_cpu_count"]
    ):
        raise EvidenceError(f"{where}.available_cpus does not match the host")
    _sha256(
        _required(snapshot, "raw_pmset_battery_sha256", where),
        f"{where}.raw_pmset_battery_sha256",
    )
    _sha256(
        _required(snapshot, "raw_pmset_thermal_sha256", where),
        f"{where}.raw_pmset_thermal_sha256",
    )
    _sha256(
        _required(snapshot, "raw_foundation_process_info_sha256", where),
        f"{where}.raw_foundation_process_info_sha256",
    )
    foundation_source_sha = _sha256(
        _required(snapshot, "foundation_probe_source_sha256", where),
        f"{where}.foundation_probe_source_sha256",
    )
    if foundation_source_sha != FOUNDATION_PROBE_SOURCE_SHA256:
        raise EvidenceError(f"{where}.foundation_probe_source_sha256 is not pinned")
    foundation_runner_sha = _sha256(
        _required(snapshot, "foundation_probe_runner_sha256", where),
        f"{where}.foundation_probe_runner_sha256",
    )
    if foundation_runner_sha != expected_foundation_runner_sha256:
        raise EvidenceError(f"{where}.foundation_probe_runner_sha256 changed")
    if snapshot.get("measurement_admitted") is not True:
        raise EvidenceError(f"{where}.measurement_admitted must be true")
    reasons = _array(_required(snapshot, "reasons", where), f"{where}.reasons")
    if reasons:
        raise EvidenceError(f"{where}.reasons must be empty")
    if snapshot.get("performance_claim") != "not_evaluated":
        raise EvidenceError(f"{where}.performance_claim must be 'not_evaluated'")
    if snapshot.get("promotion_decision") != "not_evaluated":
        raise EvidenceError(f"{where}.promotion_decision must be 'not_evaluated'")
    if snapshot.get("measurements_publishable") is not False:
        raise EvidenceError(f"{where}.measurements_publishable must remain false")
    if snapshot.get("claim_scope") != "environment-admission-only":
        raise EvidenceError(f"{where}.claim_scope must be environment-admission-only")
    return (fingerprint, foundation_source_sha, foundation_runner_sha), captured


def canonical_token_ids_sha256(token_ids: Sequence[int]) -> str:
    """Match ``generate.tokenSequenceSha256`` exactly."""

    digest = hashlib.sha256()
    digest.update(OUTPUT_TOKEN_HASH_DOMAIN)
    digest.update(len(token_ids).to_bytes(8, "little"))
    for token in token_ids:
        digest.update(token.to_bytes(4, "little"))
    return digest.hexdigest()


def canonical_workload_sha256(workload_without_sha256: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        workload_without_sha256,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")
    return hashlib.sha256(encoded).hexdigest()


def _validate_model_topology(value: Any) -> tuple[int, int, tuple[int, ...]]:
    topology = _mapping(value, "root.contract.model_topology")
    _exact_keys(
        topology,
        {"layer_count", "vocab_size", "qkv_distinct_group_passes_by_layer"},
        "root.contract.model_topology",
    )
    layer_count = _integer(
        topology["layer_count"],
        "root.contract.model_topology.layer_count",
        1,
        1 << 20,
    )
    vocab_size = _integer(
        topology["vocab_size"],
        "root.contract.model_topology.vocab_size",
        1,
        1 << 32,
    )
    passes_value = _array(
        topology["qkv_distinct_group_passes_by_layer"],
        "root.contract.model_topology.qkv_distinct_group_passes_by_layer",
        layer_count,
    )
    passes = tuple(
        _integer(
            item,
            "root.contract.model_topology."
            f"qkv_distinct_group_passes_by_layer[{index}]",
            1,
            2,
        )
        for index, item in enumerate(passes_value)
    )
    return layer_count, vocab_size, passes


def _validate_workloads(
    value: Any,
    *,
    vocab_size: int,
) -> dict[int, str]:
    workloads = _mapping(
        value, "root.contract.workloads_by_terminal_kv_positions"
    )
    if set(workloads) != {
        str(terminal) for terminal in EXPECTED_TERMINAL_KV_POSITIONS
    }:
        raise EvidenceError(
            "root.contract.workloads_by_terminal_kv_positions must cover the "
            "exact terminal KV matrix"
        )
    result: dict[int, str] = {}
    for terminal in EXPECTED_TERMINAL_KV_POSITIONS:
        where = f"root.contract.workloads_by_terminal_kv_positions.{terminal}"
        workload = _mapping(workloads[str(terminal)], where)
        _exact_keys(
            workload,
            {
                "abi_version",
                "terminal_kv_positions",
                "prompt_token_ids_by_lane",
                "seeds",
                "request_options",
                "execution_options",
                "sha256",
            },
            where,
        )
        if (
            _integer(
                workload["abi_version"],
                f"{where}.abi_version",
                1,
                U64_MAX,
            )
            != WORKLOAD_ABI
        ):
            raise EvidenceError(f"{where}.abi_version is unsupported")
        if (
            _integer(
                workload["terminal_kv_positions"],
                f"{where}.terminal_kv_positions",
                terminal,
                terminal,
            )
            != terminal
        ):
            raise EvidenceError(f"{where}.terminal_kv_positions is inconsistent")
        prompt_length = terminal - NEW_TOKENS_PER_LANE + 1
        prompts = _array(
            workload["prompt_token_ids_by_lane"],
            f"{where}.prompt_token_ids_by_lane",
            WIDTH,
        )
        normalized_prompts: list[tuple[int, ...]] = []
        for lane, prompt_value in enumerate(prompts):
            prompt = _array(
                prompt_value,
                f"{where}.prompt_token_ids_by_lane[{lane}]",
                prompt_length,
            )
            normalized_prompts.append(
                tuple(
                    _integer(
                        token,
                        f"{where}.prompt_token_ids_by_lane[{lane}][{index}]",
                        0,
                        vocab_size - 1,
                    )
                    for index, token in enumerate(prompt)
                )
            )
        seeds = _array(workload["seeds"], f"{where}.seeds", WIDTH)
        normalized_seeds = tuple(
            _integer(seed, f"{where}.seeds[{lane}]", 0, U64_MAX)
            for lane, seed in enumerate(seeds)
        )
        if len(set(zip(normalized_prompts, normalized_seeds))) != WIDTH:
            raise EvidenceError(f"{where} must bind four distinct logical requests")

        request_options = _mapping(
            workload["request_options"], f"{where}.request_options"
        )
        _exact_keys(
            request_options,
            {
                "max_new_tokens",
                "eos_policy",
                "eos_token",
                "forced_token_ids_by_lane",
                "sampler",
            },
            f"{where}.request_options",
        )
        if (
            _integer(
                request_options["max_new_tokens"],
                f"{where}.request_options.max_new_tokens",
                NEW_TOKENS_PER_LANE,
                NEW_TOKENS_PER_LANE,
            )
            != NEW_TOKENS_PER_LANE
        ):
            raise EvidenceError(f"{where}.request_options.max_new_tokens must be 64")
        if (
            _string(
                request_options["eos_policy"],
                f"{where}.request_options.eos_policy",
            )
            != "disabled-u32-max"
        ):
            raise EvidenceError(f"{where}.request_options.eos_policy must disable EOS")
        if (
            _integer(
                request_options["eos_token"],
                f"{where}.request_options.eos_token",
                U32_MAX,
                U32_MAX,
            )
            != U32_MAX
        ):
            raise EvidenceError(f"{where}.request_options.eos_token must be u32 max")
        forced = _array(
            request_options["forced_token_ids_by_lane"],
            f"{where}.request_options.forced_token_ids_by_lane",
            WIDTH,
        )
        if any(
            _array(
                item,
                f"{where}.request_options.forced_token_ids_by_lane[{lane}]",
            )
            for lane, item in enumerate(forced)
        ):
            raise EvidenceError(f"{where}.request_options forced tokens must be empty")
        sampler = _mapping(
            request_options["sampler"], f"{where}.request_options.sampler"
        )
        _exact_keys(
            sampler,
            {"temperature_f32_bits", "top_k", "top_p_f32_bits"},
            f"{where}.request_options.sampler",
        )
        normalized_sampler = {
            "temperature_f32_bits": _integer(
                sampler["temperature_f32_bits"],
                f"{where}.request_options.sampler.temperature_f32_bits",
                0,
                U32_MAX,
            ),
            "top_k": _integer(
                sampler["top_k"],
                f"{where}.request_options.sampler.top_k",
                0,
                U32_MAX,
            ),
            "top_p_f32_bits": _integer(
                sampler["top_p_f32_bits"],
                f"{where}.request_options.sampler.top_p_f32_bits",
                0,
                U32_MAX,
            ),
        }
        if normalized_sampler != {
            "temperature_f32_bits": 0,
            "top_k": 0,
            "top_p_f32_bits": 0x3F80_0000,
        }:
            raise EvidenceError(f"{where}.request_options.sampler must be greedy")

        execution_options = _mapping(
            workload["execution_options"], f"{where}.execution_options"
        )
        expected_execution_options = {
            "m1_threads_per_request": 1,
            "m1_runner_workers": WIDTH,
            "b4_thread_participants": TOTAL_WORKER_THREADS,
            "artifact_policy": "prepared-pair-nibble-required",
            "decode_frame_policy": "compact-pair-required",
            "concurrency_abi": M1X4_CONCURRENCY_ABI,
            "clock_abi": MONOTONIC_CLOCK_ABI,
        }
        _exact_keys(
            execution_options,
            expected_execution_options,
            f"{where}.execution_options",
        )
        normalized_execution_options = {
            "m1_threads_per_request": _integer(
                execution_options["m1_threads_per_request"],
                f"{where}.execution_options.m1_threads_per_request",
                1,
                TOTAL_WORKER_THREADS,
            ),
            "m1_runner_workers": _integer(
                execution_options["m1_runner_workers"],
                f"{where}.execution_options.m1_runner_workers",
                1,
                TOTAL_WORKER_THREADS,
            ),
            "b4_thread_participants": _integer(
                execution_options["b4_thread_participants"],
                f"{where}.execution_options.b4_thread_participants",
                1,
                TOTAL_WORKER_THREADS,
            ),
            "artifact_policy": _string(
                execution_options["artifact_policy"],
                f"{where}.execution_options.artifact_policy",
            ),
            "decode_frame_policy": _string(
                execution_options["decode_frame_policy"],
                f"{where}.execution_options.decode_frame_policy",
            ),
            "concurrency_abi": _integer(
                execution_options["concurrency_abi"],
                f"{where}.execution_options.concurrency_abi",
                1,
                U64_MAX,
            ),
            "clock_abi": _string(
                execution_options["clock_abi"],
                f"{where}.execution_options.clock_abi",
            ),
        }
        if normalized_execution_options != expected_execution_options:
            raise EvidenceError(f"{where}.execution_options do not match the contract")

        expected_sha = _sha256(workload["sha256"], f"{where}.sha256")
        canonical = {key: item for key, item in workload.items() if key != "sha256"}
        if canonical_workload_sha256(canonical) != expected_sha:
            raise EvidenceError(f"{where}.sha256 is not canonical")
        result[terminal] = expected_sha
    return result


def _validate_lane_state(
    value: Any,
    where: str,
    expected_lane: int,
    *,
    expected_prompt_tokens: int,
    expected_terminal_kv_positions: int,
    expected_new_tokens: int,
    vocab_size: int,
) -> tuple[Any, ...]:
    state = _mapping(value, where)
    _exact_keys(
        state,
        {
            "abi_version",
            "rng_abi",
            "lane",
            "prompt_tokens",
            "published_tokens",
            "kv_positions",
            "sampling_calls",
            "complete",
            "token_ids",
            "output_sha256",
            "kv_sha256",
            "rng_state",
        },
        where,
    )
    if (
        _integer(
            _required(state, "abi_version", where),
            f"{where}.abi_version",
            1,
            (1 << 64) - 1,
        )
        != GENERATION_STATE_ABI
    ):
        raise EvidenceError(f"{where}.abi_version does not match generation-state v1")
    if (
        _integer(
            _required(state, "rng_abi", where),
            f"{where}.rng_abi",
            1,
            (1 << 64) - 1,
        )
        != GENERATION_RNG_ABI
    ):
        raise EvidenceError(f"{where}.rng_abi does not match Xoshiro256 state v1")
    lane = _integer(_required(state, "lane", where), f"{where}.lane", 0, WIDTH - 1)
    if lane != expected_lane:
        raise EvidenceError(f"{where}.lane must be {expected_lane}")
    prompt_tokens = _integer(
        _required(state, "prompt_tokens", where),
        f"{where}.prompt_tokens",
        1,
        1 << 30,
    )
    published_tokens = _integer(
        _required(state, "published_tokens", where),
        f"{where}.published_tokens",
        1,
        1 << 30,
    )
    kv_positions = _integer(
        _required(state, "kv_positions", where),
        f"{where}.kv_positions",
        1,
        1 << 30,
    )
    sampling_calls = _integer(
        _required(state, "sampling_calls", where),
        f"{where}.sampling_calls",
        0,
        1 << 30,
    )
    if _required(state, "complete", where) is not True:
        raise EvidenceError(f"{where}.complete must be true")
    token_ids_value = _array(
        _required(state, "token_ids", where), f"{where}.token_ids"
    )
    token_ids = tuple(
        _integer(token, f"{where}.token_ids[{index}]", 0, vocab_size - 1)
        for index, token in enumerate(token_ids_value)
    )
    if len(token_ids) != published_tokens:
        raise EvidenceError(f"{where}.token_ids length must equal published_tokens")
    output_sha = _sha256(
        _required(state, "output_sha256", where), f"{where}.output_sha256"
    )
    if canonical_token_ids_sha256(token_ids) != output_sha:
        raise EvidenceError(f"{where}.output_sha256 is not the canonical full-ID digest")
    kv_sha = _sha256(_required(state, "kv_sha256", where), f"{where}.kv_sha256")
    rng = _array(_required(state, "rng_state", where), f"{where}.rng_state", WIDTH)
    rng_state = tuple(
        _integer(item, f"{where}.rng_state[{index}]", 0, (1 << 64) - 1)
        for index, item in enumerate(rng)
    )
    if prompt_tokens != expected_prompt_tokens:
        raise EvidenceError(
            f"{where}.prompt_tokens must be {expected_prompt_tokens} for the terminal KV target"
        )
    if published_tokens != expected_new_tokens:
        raise EvidenceError(f"{where}.published_tokens must be {expected_new_tokens}")
    if sampling_calls != expected_new_tokens:
        raise EvidenceError(f"{where}.sampling_calls must be {expected_new_tokens}")
    if kv_positions != expected_terminal_kv_positions:
        raise EvidenceError(
            f"{where}.kv_positions must equal terminal target "
            f"{expected_terminal_kv_positions}"
        )
    return (
        GENERATION_STATE_ABI,
        GENERATION_RNG_ABI,
        lane,
        prompt_tokens,
        published_tokens,
        kv_positions,
        sampling_calls,
        token_ids,
        output_sha,
        kv_sha,
        rng_state,
    )


def _validate_execution_counters(
    value: Any,
    where: str,
    *,
    mode: str,
    terminal: int,
    layer_count: int,
    qkv_group_passes: Sequence[int],
    lane4_abi: int,
) -> None:
    counters = _mapping(value, where)
    if mode == MODE_B4:
        expected = {
            "abi_version": lane4_abi,
            "layer_count": layer_count,
            "token_graphs": terminal,
            "layer_m4_graphs": terminal * layer_count,
            "projection_m4_dispatches": 5 * terminal * layer_count,
            "qkv_projection_dispatches": 3 * terminal * layer_count,
            "qkv_activation_quantizations": terminal * sum(qkv_group_passes),
            "qkv_quantization_reuses": terminal
            * (3 * layer_count - sum(qkv_group_passes)),
            "weight_stationary_norm_dispatches": (
                2 * terminal * layer_count + NEW_TOKENS_PER_LANE
            ),
            "lane_parallel_attention_dispatches": terminal * layer_count,
            "lane_parallel_attention_tasks": WIDTH * terminal * layer_count,
            "lane_attention_enqueue_rejects": 0,
            "pair_m4_dispatches": terminal * layer_count,
            "lm_head_m4_dispatches": NEW_TOKENS_PER_LANE,
            "active_lane_steps": WIDTH * terminal,
            "padded_lane_steps": 0,
            "fallbacks": 0,
            "admitted_cohorts": 1,
            "cohort_width": WIDTH,
            "thread_participants": TOTAL_WORKER_THREADS,
        }
        _exact_keys(counters, expected, where)
        for key, expected_value in expected.items():
            actual = _integer(counters[key], f"{where}.{key}", 0, (1 << 63) - 1)
            if actual != expected_value:
                raise EvidenceError(
                    f"{where}.{key} must be {expected_value}, got {actual}"
                )
        return

    expected_per_lane = [terminal] * WIDTH
    expected_layer_per_lane = [terminal * layer_count] * WIDTH
    expected_projection_per_lane = [5 * terminal * layer_count] * WIDTH
    expected_qkv_per_lane = [3 * terminal * layer_count] * WIDTH
    expected_pair_per_lane = [terminal * layer_count] * WIDTH
    expected_lm_per_lane = [NEW_TOKENS_PER_LANE] * WIDTH
    expected_fields = {
        "abi_version",
        "layer_count",
        "token_graphs_per_lane",
        "layer_graphs_per_lane",
        "projection_dispatches_per_lane",
        "qkv_projection_dispatches_per_lane",
        "pair_dispatches_per_lane",
        "lm_head_dispatches_per_lane",
        "active_lane_steps",
        "padded_lane_steps",
    }
    _exact_keys(counters, expected_fields, where)
    if (
        _integer(counters["abi_version"], f"{where}.abi_version", 1, (1 << 64) - 1)
        != M1X4_EXECUTION_ABI
    ):
        raise EvidenceError(f"{where}.abi_version is not M1x4 execution v1")
    if _integer(counters["layer_count"], f"{where}.layer_count", 1, 1 << 20) != layer_count:
        raise EvidenceError(f"{where}.layer_count changed")
    array_expectations = {
        "token_graphs_per_lane": expected_per_lane,
        "layer_graphs_per_lane": expected_layer_per_lane,
        "projection_dispatches_per_lane": expected_projection_per_lane,
        "qkv_projection_dispatches_per_lane": expected_qkv_per_lane,
        "pair_dispatches_per_lane": expected_pair_per_lane,
        "lm_head_dispatches_per_lane": expected_lm_per_lane,
    }
    for key, expected in array_expectations.items():
        values = _array(counters[key], f"{where}.{key}", WIDTH)
        normalized = [
            _integer(item, f"{where}.{key}[{index}]", 0, (1 << 63) - 1)
            for index, item in enumerate(values)
        ]
        if normalized != expected:
            raise EvidenceError(f"{where}.{key} does not match terminal/layer count")
    if (
        _integer(
            counters["active_lane_steps"],
            f"{where}.active_lane_steps",
            0,
            (1 << 63) - 1,
        )
        != WIDTH * terminal
    ):
        raise EvidenceError(f"{where}.active_lane_steps must be {WIDTH * terminal}")
    if _integer(counters["padded_lane_steps"], f"{where}.padded_lane_steps", 0, 0) != 0:
        raise EvidenceError(f"{where}.padded_lane_steps must be zero")


def _validate_run_interval(value: Any, where: str) -> tuple[int, int]:
    interval = _mapping(value, where)
    _exact_keys(interval, {"clock_abi", "start_ns", "end_ns"}, where)
    if interval["clock_abi"] != MONOTONIC_CLOCK_ABI:
        raise EvidenceError(f"{where}.clock_abi is unsupported")
    start = _integer(interval["start_ns"], f"{where}.start_ns", 0, (1 << 63) - 1)
    end = _integer(interval["end_ns"], f"{where}.end_ns", 1, (1 << 63) - 1)
    if start >= end:
        raise EvidenceError(f"{where} must have positive monotonic duration")
    return start, end


def _validate_m1_concurrency(
    value: Any,
    where: str,
    *,
    run_start_ns: int,
    run_end_ns: int,
) -> None:
    evidence = _mapping(value, where)
    _exact_keys(
        evidence,
        {"abi_version", "clock_abi", "start_barrier", "lane_intervals"},
        where,
    )
    if (
        _integer(evidence["abi_version"], f"{where}.abi_version", 1, (1 << 64) - 1)
        != M1X4_CONCURRENCY_ABI
    ):
        raise EvidenceError(f"{where}.abi_version is unsupported")
    if evidence["clock_abi"] != MONOTONIC_CLOCK_ABI:
        raise EvidenceError(f"{where}.clock_abi is unsupported")
    barrier_where = f"{where}.start_barrier"
    barrier = _mapping(evidence["start_barrier"], barrier_where)
    _exact_keys(
        barrier,
        {
            "owner",
            "parties",
            "arrival_count",
            "release_count",
            "epoch",
            "release_ns",
        },
        barrier_where,
    )
    if barrier["owner"] != "runner":
        raise EvidenceError(f"{barrier_where}.owner must be runner")
    for key, expected in {
        "parties": WIDTH,
        "arrival_count": WIDTH,
        "release_count": 1,
    }.items():
        if _integer(barrier[key], f"{barrier_where}.{key}", 0, WIDTH) != expected:
            raise EvidenceError(f"{barrier_where}.{key} must be {expected}")
    epoch = _integer(barrier["epoch"], f"{barrier_where}.epoch", 1, (1 << 64) - 1)
    release_ns = _integer(
        barrier["release_ns"], f"{barrier_where}.release_ns", 0, (1 << 63) - 1
    )
    if not run_start_ns <= release_ns < run_end_ns:
        raise EvidenceError(f"{barrier_where}.release_ns is outside the run")

    intervals = _array(evidence["lane_intervals"], f"{where}.lane_intervals", WIDTH)
    ready_values: list[int] = []
    start_values: list[int] = []
    end_values: list[int] = []
    for lane, item in enumerate(intervals):
        lane_where = f"{where}.lane_intervals[{lane}]"
        interval = _mapping(item, lane_where)
        _exact_keys(
            interval,
            {"lane", "barrier_epoch", "ready_ns", "start_ns", "end_ns"},
            lane_where,
        )
        if _integer(interval["lane"], f"{lane_where}.lane", 0, WIDTH - 1) != lane:
            raise EvidenceError(f"{lane_where}.lane must be {lane}")
        if (
            _integer(
                interval["barrier_epoch"],
                f"{lane_where}.barrier_epoch",
                1,
                (1 << 64) - 1,
            )
            != epoch
        ):
            raise EvidenceError(f"{lane_where}.barrier_epoch changed")
        ready = _integer(
            interval["ready_ns"], f"{lane_where}.ready_ns", 0, (1 << 63) - 1
        )
        start = _integer(
            interval["start_ns"], f"{lane_where}.start_ns", 0, (1 << 63) - 1
        )
        end = _integer(
            interval["end_ns"], f"{lane_where}.end_ns", 1, (1 << 63) - 1
        )
        if not run_start_ns <= ready <= release_ns <= start < end <= run_end_ns:
            raise EvidenceError(f"{lane_where} does not obey the runner barrier")
        ready_values.append(ready)
        start_values.append(start)
        end_values.append(end)
    if release_ns < max(ready_values):
        raise EvidenceError(f"{barrier_where} released before all four arrivals")
    if max(start_values) >= min(end_values):
        raise EvidenceError(f"{where} does not prove all-four execution overlap")


def _zero_claim() -> dict[str, int]:
    return {field: 0 for field in CLAIM_FIELDS}


def _validate_claim(value: Any, where: str) -> dict[str, int]:
    claim = _mapping(value, where)
    _exact_keys(claim, CLAIM_FIELDS, where)
    return {
        field: _integer(claim[field], f"{where}.{field}", 0, U64_MAX)
        for field in CLAIM_FIELDS
    }


def _add_claims(claims: Sequence[Mapping[str, int]]) -> dict[str, int]:
    aggregate = {
        field: sum(claim[field] for claim in claims) for field in CLAIM_FIELDS
    }
    if any(value > U64_MAX for value in aggregate.values()):
        raise EvidenceError("resource claim aggregate overflows u64")
    return aggregate


def _host_claim_bytes(claim: Mapping[str, int]) -> int:
    total = sum(claim[field] for field in HOST_CLAIM_FIELDS)
    if total > U64_MAX:
        raise EvidenceError("resource host-byte aggregate overflows u64")
    return total


def _validate_limits(value: Any, where: str) -> dict[str, int]:
    limits = _mapping(value, where)
    _exact_keys(limits, LIMIT_FIELDS, where)
    return {
        field: _integer(limits[field], f"{where}.{field}", 0, U64_MAX)
        for field in LIMIT_FIELDS
    }


def _validate_bank_snapshot(value: Any, where: str) -> dict[str, Any]:
    snapshot = _mapping(value, where)
    scalar_fields = {
        "abi_version",
        "bank_epoch",
        "peak_host_bytes",
        "active_reservations",
        "committed_receipts",
        "successful_reservations",
        "successful_commits",
        "cancellations",
        "releases",
        "rejected_capacity",
        "rejected_slots",
    }
    _exact_keys(snapshot, scalar_fields | {"limits", "used", "peak"}, where)
    result: dict[str, Any] = {
        field: _integer(snapshot[field], f"{where}.{field}", 0, U64_MAX)
        for field in scalar_fields
    }
    result["limits"] = _validate_limits(snapshot["limits"], f"{where}.limits")
    result["used"] = _validate_claim(snapshot["used"], f"{where}.used")
    result["peak"] = _validate_claim(snapshot["peak"], f"{where}.peak")
    return result


def _validate_resource_bank_evidence(
    value: Any,
    where: str,
    *,
    mode: str,
    resource_bank_abi: int,
) -> int:
    evidence = _mapping(value, where)
    _exact_keys(
        evidence,
        {"abi_version", "scope", "limits", "receipts", "snapshots"},
        where,
    )
    if (
        _integer(evidence["abi_version"], f"{where}.abi_version", 1, (1 << 64) - 1)
        != resource_bank_abi
    ):
        raise EvidenceError(f"{where}.abi_version changed")
    if evidence["scope"] != "fresh-bank-per-observation/v1":
        raise EvidenceError(f"{where}.scope must be fresh-bank-per-observation/v1")
    receipt_count = WIDTH if mode == MODE_M1X4 else 1
    receipts_value = _array(evidence["receipts"], f"{where}.receipts", receipt_count)
    claims: list[dict[str, int]] = []
    owner_keys: set[int] = set()
    integrities: set[int] = set()
    bank_epoch: int | None = None
    for index, item in enumerate(receipts_value):
        receipt_where = f"{where}.receipts[{index}]"
        receipt = _mapping(item, receipt_where)
        _exact_keys(
            receipt,
            {
                "bank_epoch",
                "slot_index",
                "generation",
                "owner_key",
                "integrity",
                "claim",
            },
            receipt_where,
        )
        epoch = _integer(
            receipt["bank_epoch"], f"{receipt_where}.bank_epoch", 1, (1 << 64) - 1
        )
        if bank_epoch is None:
            bank_epoch = epoch
        elif epoch != bank_epoch:
            raise EvidenceError(f"{receipt_where}.bank_epoch changed")
        if (
            _integer(
                receipt["slot_index"], f"{receipt_where}.slot_index", 0, (1 << 32) - 1
            )
            != index
        ):
            raise EvidenceError(f"{receipt_where}.slot_index must be {index}")
        if (
            _integer(
                receipt["generation"], f"{receipt_where}.generation", 1, (1 << 64) - 1
            )
            != index + 1
        ):
            raise EvidenceError(
                f"{receipt_where}.generation must follow the fresh bank global "
                f"sequence ({index + 1})"
            )
        owner_key = _integer(
            receipt["owner_key"], f"{receipt_where}.owner_key", 1, (1 << 64) - 1
        )
        integrity = _integer(
            receipt["integrity"], f"{receipt_where}.integrity", 1, (1 << 64) - 1
        )
        owner_keys.add(owner_key)
        integrities.add(integrity)
        claim = _validate_claim(receipt["claim"], f"{receipt_where}.claim")
        expected_slots = 1 if mode == MODE_M1X4 else WIDTH
        if claim["queue_slots"] != expected_slots:
            raise EvidenceError(
                f"{receipt_where}.claim.queue_slots must be {expected_slots}"
            )
        if _host_claim_bytes(claim) == 0:
            raise EvidenceError(f"{receipt_where}.claim must charge host resources")
        claims.append(claim)
    if len(owner_keys) != receipt_count or len(integrities) != receipt_count:
        raise EvidenceError(f"{where} receipt identities must be unique")
    assert bank_epoch is not None
    aggregate = _add_claims(claims)
    if aggregate["queue_slots"] != WIDTH:
        raise EvidenceError(f"{where} must charge four logical queue slots")
    aggregate_host = _host_claim_bytes(aggregate)
    limits = _validate_limits(evidence["limits"], f"{where}.limits")
    expected_limits = {"host_bytes": aggregate_host, **aggregate}
    if limits != expected_limits:
        raise EvidenceError(f"{where}.limits must equal the aggregate hard cap")

    snapshots = _mapping(evidence["snapshots"], f"{where}.snapshots")
    _exact_keys(snapshots, {"before", "committed", "released"}, f"{where}.snapshots")
    before = _validate_bank_snapshot(snapshots["before"], f"{where}.snapshots.before")
    committed = _validate_bank_snapshot(
        snapshots["committed"], f"{where}.snapshots.committed"
    )
    released = _validate_bank_snapshot(
        snapshots["released"], f"{where}.snapshots.released"
    )
    zero = _zero_claim()
    expected_scalar_before = {
        "abi_version": resource_bank_abi,
        "bank_epoch": bank_epoch,
        "peak_host_bytes": 0,
        "active_reservations": 0,
        "committed_receipts": 0,
        "successful_reservations": 0,
        "successful_commits": 0,
        "cancellations": 0,
        "releases": 0,
        "rejected_capacity": 0,
        "rejected_slots": 0,
    }
    expected_scalar_committed = {
        **expected_scalar_before,
        "peak_host_bytes": aggregate_host,
        "committed_receipts": receipt_count,
        "successful_reservations": receipt_count,
        "successful_commits": receipt_count,
    }
    expected_scalar_released = {
        **expected_scalar_committed,
        "committed_receipts": 0,
        "releases": receipt_count,
    }
    for label, snapshot, expected_scalars, expected_used, expected_peak in (
        ("before", before, expected_scalar_before, zero, zero),
        ("committed", committed, expected_scalar_committed, aggregate, aggregate),
        ("released", released, expected_scalar_released, zero, aggregate),
    ):
        if snapshot["limits"] != limits:
            raise EvidenceError(f"{where}.snapshots.{label}.limits changed")
        if snapshot["used"] != expected_used or snapshot["peak"] != expected_peak:
            raise EvidenceError(f"{where}.snapshots.{label} claim state is invalid")
        actual_scalars = {
            key: snapshot[key] for key in expected_scalars
        }
        if actual_scalars != expected_scalars:
            raise EvidenceError(f"{where}.snapshots.{label} counters are invalid")
    return aggregate_host


def _validate_rss_non_admissible(value: Any, where: str) -> None:
    evidence = _mapping(value, where)
    expected = {
        "classification": "non-admissible",
        "method": "none",
        "samples": [],
    }
    _exact_keys(evidence, expected, where)
    if evidence != expected:
        raise EvidenceError(f"{where} must remain explicitly non-admissible")


def _validate_observation(
    value: Any,
    where: str,
    *,
    runner_sha: str,
    model_sha: str,
    lane4_abi: int,
    resource_bank_abi: int,
    new_tokens_per_lane: int,
    workload_sha_by_terminal: Mapping[int, str],
    foundation_runner_sha: str,
    layer_count: int,
    vocab_size: int,
    qkv_group_passes: Sequence[int],
) -> dict[str, Any]:
    observation = _mapping(value, where)
    _exact_keys(
        observation,
        {
            "terminal_kv_positions",
            "mode",
            "sequence_index",
            "block_index",
            "position_in_block",
            "pattern",
            "runner_sha256",
            "model_sha256",
            "workload_sha256",
            "lane4_abi",
            "resource_bank_abi",
            "process_count",
            "lane_count",
            "worker_threads",
            "request_threads",
            "execution_counters",
            "run_interval_monotonic_ns",
            "m1_concurrency",
            "resource_bank_evidence",
            "logical_host_claim_bytes",
            "rss_evidence",
            "environment_before",
            "environment_after",
            "started_at_utc",
            "ended_at_utc",
            "lane_states",
            "published_tokens_total",
        },
        where,
    )
    terminal_kv_positions = _integer(
        _required(observation, "terminal_kv_positions", where),
        f"{where}.terminal_kv_positions",
        1,
        1 << 30,
    )
    if terminal_kv_positions not in EXPECTED_TERMINAL_KV_POSITIONS:
        raise EvidenceError(
            f"{where}.terminal_kv_positions is outside the required matrix"
        )
    expected_prompt_tokens = terminal_kv_positions - new_tokens_per_lane + 1
    if expected_prompt_tokens <= 0:
        raise EvidenceError(f"{where} terminal KV target cannot fit the workload")
    mode = _string(_required(observation, "mode", where), f"{where}.mode")
    if mode not in {MODE_M1X4, MODE_B4}:
        raise EvidenceError(f"{where}.mode must be 'm1x4' or 'b4'")
    sequence_index = _integer(
        _required(observation, "sequence_index", where),
        f"{where}.sequence_index",
        0,
        1 << 30,
    )
    block_index = _integer(
        _required(observation, "block_index", where),
        f"{where}.block_index",
        0,
        1 << 30,
    )
    position = _integer(
        _required(observation, "position_in_block", where),
        f"{where}.position_in_block",
        0,
        3,
    )
    pattern = _string(_required(observation, "pattern", where), f"{where}.pattern")
    if pattern not in VALID_PATTERNS:
        raise EvidenceError(f"{where}.pattern must be ABBA or BAAB")

    if _sha256(observation.get("runner_sha256"), f"{where}.runner_sha256") != runner_sha:
        raise EvidenceError(f"{where}.runner_sha256 changed within the campaign")
    if _sha256(observation.get("model_sha256"), f"{where}.model_sha256") != model_sha:
        raise EvidenceError(f"{where}.model_sha256 changed within the campaign")
    if (
        _sha256(observation.get("workload_sha256"), f"{where}.workload_sha256")
        != workload_sha_by_terminal[terminal_kv_positions]
    ):
        raise EvidenceError(
            f"{where}.workload_sha256 does not match its terminal KV target"
        )
    if _integer(observation.get("lane4_abi"), f"{where}.lane4_abi", 0, (1 << 64) - 1) != lane4_abi:
        raise EvidenceError(f"{where}.lane4_abi changed within the campaign")
    if (
        _integer(
            observation.get("resource_bank_abi"),
            f"{where}.resource_bank_abi",
            1,
            (1 << 64) - 1,
        )
        != resource_bank_abi
    ):
        raise EvidenceError(f"{where}.resource_bank_abi changed within the campaign")
    if _integer(observation.get("process_count"), f"{where}.process_count", 1, 1) != 1:
        raise EvidenceError(f"{where}.process_count must be one")
    if _integer(observation.get("lane_count"), f"{where}.lane_count", WIDTH, WIDTH) != WIDTH:
        raise EvidenceError(f"{where}.lane_count must be four")
    if (
        _integer(
            observation.get("worker_threads"),
            f"{where}.worker_threads",
            TOTAL_WORKER_THREADS,
            TOTAL_WORKER_THREADS,
        )
        != TOTAL_WORKER_THREADS
    ):
        raise EvidenceError(f"{where}.worker_threads must be four")
    request_threads = _array(
        _required(observation, "request_threads", where), f"{where}.request_threads"
    )
    expected_threads = [1, 1, 1, 1] if mode == MODE_M1X4 else [4]
    normalized_threads = [
        _integer(item, f"{where}.request_threads[{index}]", 1, TOTAL_WORKER_THREADS)
        for index, item in enumerate(request_threads)
    ]
    if normalized_threads != expected_threads:
        raise EvidenceError(
            f"{where}.request_threads must be {expected_threads!r} for {mode}"
        )
    _validate_execution_counters(
        observation["execution_counters"],
        f"{where}.execution_counters",
        mode=mode,
        terminal=terminal_kv_positions,
        layer_count=layer_count,
        qkv_group_passes=qkv_group_passes,
        lane4_abi=lane4_abi,
    )
    run_start_ns, run_end_ns = _validate_run_interval(
        observation["run_interval_monotonic_ns"],
        f"{where}.run_interval_monotonic_ns",
    )
    if mode == MODE_M1X4:
        _validate_m1_concurrency(
            observation["m1_concurrency"],
            f"{where}.m1_concurrency",
            run_start_ns=run_start_ns,
            run_end_ns=run_end_ns,
        )
    elif observation["m1_concurrency"] is not None:
        raise EvidenceError(f"{where}.m1_concurrency must be null for B4")
    aggregate_host = _validate_resource_bank_evidence(
        observation["resource_bank_evidence"],
        f"{where}.resource_bank_evidence",
        mode=mode,
        resource_bank_abi=resource_bank_abi,
    )
    if (
        _integer(
            observation["logical_host_claim_bytes"],
            f"{where}.logical_host_claim_bytes",
            1,
            (1 << 63) - 1,
        )
        != aggregate_host
    ):
        raise EvidenceError(f"{where}.logical_host_claim_bytes is inconsistent")
    _validate_rss_non_admissible(
        observation["rss_evidence"], f"{where}.rss_evidence"
    )

    before_host, before_time = _validate_environment(
        _required(observation, "environment_before", where),
        f"{where}.environment_before",
        expected_foundation_runner_sha256=foundation_runner_sha,
    )
    after_host, after_time = _validate_environment(
        _required(observation, "environment_after", where),
        f"{where}.environment_after",
        expected_foundation_runner_sha256=foundation_runner_sha,
    )
    started = _parse_utc(observation.get("started_at_utc"), f"{where}.started_at_utc")
    ended = _parse_utc(observation.get("ended_at_utc"), f"{where}.ended_at_utc")
    if before_host != after_host:
        raise EvidenceError(f"{where} moved between hosts")
    if not before_time <= started <= ended <= after_time:
        raise EvidenceError(
            f"{where} environment snapshots must bracket the observation"
        )

    states = _array(
        _required(observation, "lane_states", where),
        f"{where}.lane_states",
        WIDTH,
    )
    state_signature = tuple(
        _validate_lane_state(
            item,
            f"{where}.lane_states[{lane}]",
            lane,
            expected_prompt_tokens=expected_prompt_tokens,
            expected_terminal_kv_positions=terminal_kv_positions,
            expected_new_tokens=new_tokens_per_lane,
            vocab_size=vocab_size,
        )
        for lane, item in enumerate(states)
    )
    published_total = sum(state[4] for state in state_signature)
    if (
        _integer(
            observation.get("published_tokens_total"),
            f"{where}.published_tokens_total",
            1,
            1 << 31,
        )
        != published_total
    ):
        raise EvidenceError(f"{where}.published_tokens_total is inconsistent")
    return {
        "terminal_kv_positions": terminal_kv_positions,
        "mode": mode,
        "sequence_index": sequence_index,
        "block_index": block_index,
        "position": position,
        "pattern": pattern,
        "host": before_host,
        "state_signature": state_signature,
        "environment_before_time": before_time,
        "environment_after_time": after_time,
        "run_start_ns": run_start_ns,
        "run_end_ns": run_end_ns,
    }


def _validate_balanced_schedule(observations: Sequence[Mapping[str, Any]]) -> None:
    sequence_indices = sorted(item["sequence_index"] for item in observations)
    if sequence_indices != list(range(len(observations))):
        raise EvidenceError("observation sequence_index values must be contiguous")
    chronological = sorted(observations, key=lambda item: item["sequence_index"])
    for previous, current in zip(chronological, chronological[1:]):
        if previous["environment_after_time"] > current["environment_before_time"]:
            raise EvidenceError("timed observations must be sequential, not overlapping")
        if previous["run_end_ns"] > current["run_start_ns"]:
            raise EvidenceError("monotonic run intervals must not overlap")

    for terminal in EXPECTED_TERMINAL_KV_POSITIONS:
        context_items = [
            item
            for item in observations
            if item["terminal_kv_positions"] == terminal
        ]
        blocks: dict[int, list[Mapping[str, Any]]] = {}
        for item in context_items:
            blocks.setdefault(item["block_index"], []).append(item)
        if sorted(blocks) != list(range(len(blocks))):
            raise EvidenceError(
                f"terminal KV {terminal} block indexes must be contiguous"
            )
        if len(blocks) < MIN_BLOCKS_PER_PATTERN * 2 or len(blocks) % 2 != 0:
            raise EvidenceError(
                f"terminal KV {terminal} requires at least "
                f"{MIN_BLOCKS_PER_PATTERN * 2} balanced blocks"
            )
        patterns: list[str] = []
        for block_index, block in sorted(blocks.items()):
            if len(block) != 4:
                raise EvidenceError(
                    f"terminal KV {terminal} block {block_index} must contain four observations"
                )
            ordered = sorted(block, key=lambda item: item["position"])
            if [item["position"] for item in ordered] != [0, 1, 2, 3]:
                raise EvidenceError(
                    f"terminal KV {terminal} block {block_index} positions must be 0..3"
                )
            block_sequence = [item["sequence_index"] for item in ordered]
            if block_sequence != list(
                range(block_sequence[0], block_sequence[0] + WIDTH)
            ):
                raise EvidenceError(
                    f"terminal KV {terminal} block {block_index} must be consecutive in time"
                )
            if len({item["pattern"] for item in ordered}) != 1:
                raise EvidenceError(
                    f"terminal KV {terminal} block {block_index} changed pattern"
                )
            pattern = ordered[0]["pattern"]
            modes = [item["mode"] for item in ordered]
            expected_modes = [MODE_FOR_LETTER[letter] for letter in pattern]
            if modes != expected_modes:
                raise EvidenceError(
                    f"terminal KV {terminal} block {block_index} does not follow {pattern}"
                )
            patterns.append(pattern)
        abba_blocks = patterns.count("ABBA")
        baab_blocks = patterns.count("BAAB")
        if (
            abba_blocks != baab_blocks
            or abba_blocks < MIN_BLOCKS_PER_PATTERN
            or baab_blocks < MIN_BLOCKS_PER_PATTERN
        ):
            raise EvidenceError(
                f"terminal KV {terminal} requires at least 8 ABBA and 8 BAAB blocks"
            )
        per_arm_observations = 2 * abba_blocks + 2 * baab_blocks
        if per_arm_observations < MIN_OBSERVATIONS_PER_ARM:
            raise EvidenceError(
                f"terminal KV {terminal} requires 32 observations per arm"
            )


def validate_raw_evidence(value: Any) -> dict[str, Any]:
    """Validate raw evidence without calculating or endorsing performance."""

    raw = _mapping(value, "root")
    _exact_keys(raw, {"schema", "comparison", "contract", "artifacts", "observations"}, "root")
    if raw.get("schema") != RAW_SCHEMA:
        raise EvidenceError(f"root.schema must be {RAW_SCHEMA!r}")
    if raw.get("comparison") != COMPARISON:
        raise EvidenceError(f"root.comparison must be {COMPARISON!r}")
    contract = _mapping(_required(raw, "contract", "root"), "root.contract")
    _exact_keys(
        contract,
        {
            "width",
            "terminal_kv_positions",
            "minimum_blocks_per_pattern",
            "minimum_observations_per_arm_per_terminal",
            "total_worker_threads",
            "comparison_policy",
            "cache_regime",
            "lane4_abi",
            "resource_bank_abi",
            "new_tokens_per_lane",
            "generation_state_abi",
            "generation_rng_abi",
            "output_token_hash_abi",
            "model_topology",
            "workloads_by_terminal_kv_positions",
        },
        "root.contract",
    )
    if _integer(contract.get("width"), "root.contract.width", WIDTH, WIDTH) != WIDTH:
        raise EvidenceError("root.contract.width must be four")
    if contract.get("terminal_kv_positions") != list(
        EXPECTED_TERMINAL_KV_POSITIONS
    ):
        raise EvidenceError(
            "root.contract.terminal_kv_positions must be "
            f"{list(EXPECTED_TERMINAL_KV_POSITIONS)!r}"
        )
    if (
        _integer(
            contract.get("minimum_blocks_per_pattern"),
            "root.contract.minimum_blocks_per_pattern",
            MIN_BLOCKS_PER_PATTERN,
            MIN_BLOCKS_PER_PATTERN,
        )
        != MIN_BLOCKS_PER_PATTERN
    ):
        raise EvidenceError("root.contract.minimum_blocks_per_pattern must be eight")
    if (
        _integer(
            contract.get("minimum_observations_per_arm_per_terminal"),
            "root.contract.minimum_observations_per_arm_per_terminal",
            MIN_OBSERVATIONS_PER_ARM,
            MIN_OBSERVATIONS_PER_ARM,
        )
        != MIN_OBSERVATIONS_PER_ARM
    ):
        raise EvidenceError(
            "root.contract.minimum_observations_per_arm_per_terminal must be 32"
        )
    if (
        _integer(
            contract.get("total_worker_threads"),
            "root.contract.total_worker_threads",
            TOTAL_WORKER_THREADS,
            TOTAL_WORKER_THREADS,
        )
        != TOTAL_WORKER_THREADS
    ):
        raise EvidenceError("root.contract.total_worker_threads must be four")
    if contract.get("comparison_policy") != "one-runner-one-model-process/v1":
        raise EvidenceError("root.contract.comparison_policy is unsupported")
    if contract.get("cache_regime") != "same-process-shared-prepared-weights":
        raise EvidenceError(
            "root.contract.cache_regime must be same-process-shared-prepared-weights"
        )
    lane4_abi = _integer(
        _required(contract, "lane4_abi", "root.contract"),
        "root.contract.lane4_abi",
        1,
        (1 << 64) - 1,
    )
    if lane4_abi != DECODE_LANE4_ABI:
        raise EvidenceError("root.contract.lane4_abi is not DecodeLane4 v2")
    resource_bank_abi = _integer(
        _required(contract, "resource_bank_abi", "root.contract"),
        "root.contract.resource_bank_abi",
        1,
        (1 << 64) - 1,
    )
    if resource_bank_abi != RESOURCE_BANK_ABI:
        raise EvidenceError("root.contract.resource_bank_abi is not ResourceBank v1")
    new_tokens_per_lane = _integer(
        _required(contract, "new_tokens_per_lane", "root.contract"),
        "root.contract.new_tokens_per_lane",
        1,
        1 << 30,
    )
    if new_tokens_per_lane != NEW_TOKENS_PER_LANE:
        raise EvidenceError("root.contract.new_tokens_per_lane must be 64")
    if (
        _integer(
            _required(contract, "generation_state_abi", "root.contract"),
            "root.contract.generation_state_abi",
            1,
            (1 << 64) - 1,
        )
        != GENERATION_STATE_ABI
    ):
        raise EvidenceError("root.contract.generation_state_abi is unsupported")
    if (
        _integer(
            _required(contract, "generation_rng_abi", "root.contract"),
            "root.contract.generation_rng_abi",
            1,
            (1 << 64) - 1,
        )
        != GENERATION_RNG_ABI
    ):
        raise EvidenceError("root.contract.generation_rng_abi is unsupported")
    if contract.get("output_token_hash_abi") != OUTPUT_TOKEN_HASH_ABI:
        raise EvidenceError("root.contract.output_token_hash_abi is unsupported")
    layer_count, vocab_size, qkv_group_passes = _validate_model_topology(
        contract["model_topology"]
    )
    workload_sha_by_terminal = _validate_workloads(
        contract["workloads_by_terminal_kv_positions"],
        vocab_size=vocab_size,
    )

    artifacts = _mapping(_required(raw, "artifacts", "root"), "root.artifacts")
    _exact_keys(
        artifacts,
        {"runner", "model", "foundation_probe_source", "foundation_probe_runner"},
        "root.artifacts",
    )
    runner_obj = _mapping(_required(artifacts, "runner", "root.artifacts"), "root.artifacts.runner")
    model_obj = _mapping(_required(artifacts, "model", "root.artifacts"), "root.artifacts.model")
    foundation_source_obj = _mapping(
        _required(artifacts, "foundation_probe_source", "root.artifacts"),
        "root.artifacts.foundation_probe_source",
    )
    foundation_runner_obj = _mapping(
        _required(artifacts, "foundation_probe_runner", "root.artifacts"),
        "root.artifacts.foundation_probe_runner",
    )
    for artifact_name, artifact in (
        ("runner", runner_obj),
        ("model", model_obj),
        ("foundation_probe_source", foundation_source_obj),
        ("foundation_probe_runner", foundation_runner_obj),
    ):
        _exact_keys(
            artifact,
            {"path", "sha256"},
            f"root.artifacts.{artifact_name}",
        )
    runner = _fingerprint_file(
        _required(runner_obj, "path", "root.artifacts.runner"),
        _required(runner_obj, "sha256", "root.artifacts.runner"),
        "root.artifacts.runner",
        executable=True,
    )
    model = _fingerprint_file(
        _required(model_obj, "path", "root.artifacts.model"),
        _required(model_obj, "sha256", "root.artifacts.model"),
        "root.artifacts.model",
    )
    foundation_source = _fingerprint_file(
        _required(
            foundation_source_obj,
            "path",
            "root.artifacts.foundation_probe_source",
        ),
        _required(
            foundation_source_obj,
            "sha256",
            "root.artifacts.foundation_probe_source",
        ),
        "root.artifacts.foundation_probe_source",
    )
    if foundation_source["path"] != str(FOUNDATION_PROBE_SOURCE.resolve()):
        raise EvidenceError(
            "root.artifacts.foundation_probe_source.path must be the pinned source"
        )
    if foundation_source["sha256"] != FOUNDATION_PROBE_SOURCE_SHA256:
        raise EvidenceError(
            "root.artifacts.foundation_probe_source.sha256 is not the pinned ABI"
        )
    foundation_runner = _fingerprint_file(
        _required(
            foundation_runner_obj,
            "path",
            "root.artifacts.foundation_probe_runner",
        ),
        _required(
            foundation_runner_obj,
            "sha256",
            "root.artifacts.foundation_probe_runner",
        ),
        "root.artifacts.foundation_probe_runner",
        executable=True,
    )

    raw_observations = _array(_required(raw, "observations", "root"), "root.observations")
    observations = [
        _validate_observation(
            item,
            f"root.observations[{index}]",
            runner_sha=runner["sha256"],
            model_sha=model["sha256"],
            lane4_abi=lane4_abi,
            resource_bank_abi=resource_bank_abi,
            new_tokens_per_lane=new_tokens_per_lane,
            workload_sha_by_terminal=workload_sha_by_terminal,
            foundation_runner_sha=foundation_runner["sha256"],
            layer_count=layer_count,
            vocab_size=vocab_size,
            qkv_group_passes=qkv_group_passes,
        )
        for index, item in enumerate(raw_observations)
    ]
    _validate_balanced_schedule(observations)
    hosts = {item["host"] for item in observations}
    if len(hosts) != 1:
        raise EvidenceError("all observations must remain on one host configuration")
    for terminal in EXPECTED_TERMINAL_KV_POSITIONS:
        signatures = {
            item["state_signature"]
            for item in observations
            if item["terminal_kv_positions"] == terminal
        }
        if len(signatures) != 1:
            raise EvidenceError(
                f"terminal KV {terminal} does not have exact stable M1x4/B4 lane state"
            )

    return {
        "schema": GATE_SCHEMA,
        "status": "passed",
        "comparison": COMPARISON,
        "checked_observations": len(observations),
        "checked_terminal_kv_positions": list(EXPECTED_TERMINAL_KV_POSITIONS),
        "minimum_observations_per_arm_per_terminal": MIN_OBSERVATIONS_PER_ARM,
        "runner": runner,
        "model": model,
        "foundation_probe_source": foundation_source,
        "foundation_probe_runner": foundation_runner,
        "environment_and_contract_gate_passed": True,
        "exact_lane_state_gate_passed": True,
        "evidence_contract_shape_validated": True,
        "grounded_runner_telemetry_available": False,
        "evidence_availability": "unavailable-no-grounded-runner-in-v2",
        "raw_measurements_admissible_for_separate_analysis": False,
        "performance_analysis_available": False,
        "resource_analysis_available": False,
        "resource_measurements_admissible": False,
        "rss_measurement_classification": "non-admissible",
        "p99_latency_admissible": False,
        "measurements_publishable": False,
        "performance_claim": "not_evaluated",
        "promotion_decision": "not_evaluated",
        "energy_measured": False,
        "limitations": [
            "AC, pmset constraints, Foundation thermal state, and Low Power Mode "
            "are sampled only at observation boundaries.",
            "This validator does not calculate confidence intervals or speedup.",
            "The current runner does not emit the complete barrier, interval, and "
            "ResourceBank receipt/snapshot event stream required to ground this "
            "contract.",
            "A passing envelope is not a performance or quality claim.",
        ],
    }


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(
                handle,
                object_pairs_hook=_json_no_duplicates,
                parse_constant=_reject_json_constant,
            )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot load {path}: {exc}") from exc


def _json_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise EvidenceError(f"non-finite JSON value is forbidden: {value}")


def _write_json(value: Mapping[str, Any], output: str | None) -> None:
    rendered = json.dumps(
        value, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False
    ) + "\n"
    if output is None or output == "-":
        sys.stdout.write(rendered)
        return
    destination = Path(output).expanduser().resolve(strict=False)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail-closed environment/evidence gate for DecodeLane4"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    probe = subparsers.add_parser(
        "probe", help="probe AC and thermal admission without running a benchmark"
    )
    probe.add_argument("-o", "--output", help="JSON output path, or '-' for stdout")
    validate = subparsers.add_parser(
        "validate", help="validate a raw evidence envelope without claiming a result"
    )
    validate.add_argument("evidence", help="path to raw evidence JSON")
    validate.add_argument("-o", "--output", help="JSON output path, or '-' for stdout")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "probe":
            result = capture_environment()
            _write_json(result, args.output)
            return 0 if result["measurement_admitted"] else 1
        result = validate_raw_evidence(
            _load_json(Path(args.evidence).expanduser().resolve(strict=False))
        )
        _write_json(result, args.output)
        return 0
    except EvidenceError as exc:
        failure = {
            "schema": GATE_SCHEMA,
            "status": "failed",
            "environment_and_contract_gate_passed": False,
            "evidence_contract_shape_validated": False,
            "grounded_runner_telemetry_available": False,
            "evidence_availability": "unavailable-no-grounded-runner-in-v2",
            "raw_measurements_admissible_for_separate_analysis": False,
            "performance_analysis_available": False,
            "resource_analysis_available": False,
            "resource_measurements_admissible": False,
            "rss_measurement_classification": "non-admissible",
            "p99_latency_admissible": False,
            "measurements_publishable": False,
            "performance_claim": "not_evaluated",
            "promotion_decision": "not_evaluated",
            "error": str(exc),
        }
        _write_json(failure, getattr(args, "output", None))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
