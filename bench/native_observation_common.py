"""Platform-neutral host-observation schema and bounded source helpers.

Platform adapters may observe different subsets of the fixed metric universe,
but they all emit the same record shape and availability semantics.  This
module has no platform imports beyond portable Python runtime and filesystem
primitives, so parser and adapter-model tests can run on any host.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Protocol


SCHEMA = "glacier.native-observation/host-v1"
BASELINE_ADAPTER = "runtime-baseline-observer/v1"
AVAILABILITIES = ("present", "missing", "denied", "unsupported")
PHASES = ("probe", "pre_run", "post_run")
I64_MAX = (1 << 63) - 1

MAXIMUM_FILE_READ_BYTES = 1 << 20
MAXIMUM_PROVENANCE_SOURCES = 16
MAXIMUM_PROVENANCE_BYTES = 64 * 1024
MAXIMUM_REASON_BYTES = 1024
NATIVE_REQUIRED_ENV = "GLACIER_REQUIRE_NATIVE_OBSERVER"
NATIVE_PLATFORMS = ("Darwin", "Linux")
CAPTURE_MODES = ("native", "simulated")

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
METRIC_SPEC_BY_NAME = {
    name: (subject, unit, sample_clock_domain, value_clock_domain)
    for (
        name,
        subject,
        unit,
        sample_clock_domain,
        value_clock_domain,
    ) in METRIC_SPECS
}


class ObservationError(RuntimeError):
    """An observation record, source, adapter, or requirement is invalid."""


@dataclass(frozen=True)
class ObservationContext:
    """Validated process and host context passed to a selected adapter."""

    system_name: str
    process_id: int
    process_group_id: int | None
    logical_cpu_count: int | None


class PlatformObserver(Protocol):
    """Minimal injectable interface implemented by platform observers."""

    system_name: str
    adapter_id: str
    direct_metric_names: frozenset[str]

    def collect(
        self,
        phase: str,
        context: ObservationContext,
    ) -> Mapping[str, Mapping[str, Any]]:
        """Collect the adapter's directly handled metric subset."""


BoundedFileReader = Callable[[str, int], bytes]


def sha256_hex(data: bytes) -> str:
    if type(data) is not bytes:
        raise ObservationError("SHA-256 input must be bytes")
    return hashlib.sha256(data).hexdigest()


def bounded_reason(value: str) -> str:
    """Return a deterministic, nonempty UTF-8 reason within the wire bound."""

    if not isinstance(value, str) or not value:
        raise ObservationError("observation reason must be a nonempty string")
    encoded = value.encode("utf-8")
    if len(encoded) <= MAXIMUM_REASON_BYTES:
        return value
    suffix = b"...[truncated]"
    retained = encoded[: MAXIMUM_REASON_BYTES - len(suffix)]
    return retained.decode("utf-8", errors="ignore") + suffix.decode("ascii")


def _canonical_json_bytes(value: Any, where: str) -> bytes:
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")
    except (TypeError, ValueError) as error:
        raise ObservationError(f"{where} is not canonical JSON data") from error
    return encoded


def runtime_provenance(
    adapter_id: str,
    system_name: str,
    api: str,
) -> dict[str, Any]:
    return {
        "adapter": adapter_id,
        "sources": [
            {
                "kind": "runtime-api",
                "api": api,
                "system": system_name,
            }
        ],
    }


def bounded_file_provenance(
    *,
    adapter_id: str,
    path: str,
    parser_schema: str,
    maximum_bytes: int,
    started_monotonic_ns: int,
    finished_monotonic_ns: int,
    content: bytes,
    read_status: str,
) -> dict[str, Any]:
    """Build event evidence whose stable identity excludes event fields."""

    if (
        not isinstance(path, str)
        or not path
        or not isinstance(parser_schema, str)
        or not parser_schema
    ):
        raise ObservationError("bounded-file identity is incomplete")
    if (
        isinstance(maximum_bytes, bool)
        or not isinstance(maximum_bytes, int)
        or not 1 <= maximum_bytes <= MAXIMUM_FILE_READ_BYTES
    ):
        raise ObservationError("bounded-file maximum is invalid")
    if type(content) is not bytes or len(content) > maximum_bytes + 1:
        raise ObservationError("bounded-file event content is outside its bound")
    if read_status not in ("present", "missing", "denied"):
        raise ObservationError("bounded-file read status is invalid")
    if (
        type(started_monotonic_ns) is not int
        or type(finished_monotonic_ns) is not int
        or not 0 <= started_monotonic_ns <= I64_MAX
        or not started_monotonic_ns <= finished_monotonic_ns <= I64_MAX
    ):
        raise ObservationError(
            "bounded-file monotonic interval is invalid"
        )
    return {
        "adapter": adapter_id,
        "sources": [
            {
                "kind": "bounded-file",
                "path": path,
                "parser_schema": parser_schema,
                "maximum_bytes": maximum_bytes,
                "started_monotonic_ns": started_monotonic_ns,
                "finished_monotonic_ns": finished_monotonic_ns,
                "read_status": read_status,
                "content_bytes": len(content),
                "content_sha256": sha256_hex(content),
            }
        ],
    }


def stable_source_descriptor(source: Mapping[str, Any]) -> dict[str, Any]:
    """Project event provenance to a stable source-method descriptor."""

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
        source_id_argv = source.get("source_id_argv", argv)
        if (
            not isinstance(source_id_argv, (list, tuple))
            or not source_id_argv
            or any(
                not isinstance(argument, str) or not argument
                for argument in source_id_argv
            )
        ):
            raise ObservationError(
                "command source identity argv must contain nonempty strings"
            )
        # ``argv`` is event evidence and can contain a PID, sample count, or
        # interval.  New producers provide a normalized identity projection;
        # legacy records without it retain their historical full-argv identity.
        return {"kind": kind, "argv": list(source_id_argv)}
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
    if kind == "bounded-file":
        path = source.get("path")
        parser_schema = source.get("parser_schema")
        maximum_bytes = source.get("maximum_bytes")
        if (
            not isinstance(path, str)
            or not path
            or not isinstance(parser_schema, str)
            or not parser_schema
            or isinstance(maximum_bytes, bool)
            or not isinstance(maximum_bytes, int)
            or not 1 <= maximum_bytes <= MAXIMUM_FILE_READ_BYTES
        ):
            raise ObservationError(
                "bounded-file source identity is incomplete"
            )
        return {
            "kind": kind,
            "path": path,
            "parser_schema": parser_schema,
            "maximum_bytes": maximum_bytes,
        }
    if kind == "native-api":
        system = source.get("system")
        api = source.get("api")
        schema = source.get("schema")
        if any(
            not isinstance(value, str) or not value
            for value in (system, api, schema)
        ):
            raise ObservationError(
                "native API source identity is incomplete"
            )
        return {
            "kind": kind,
            "system": system,
            "api": api,
            "schema": schema,
        }
    raise ObservationError(f"unsupported provenance source kind {kind!r}")


def source_identity_sha256(provenance: Mapping[str, Any]) -> str:
    adapter = provenance.get("adapter")
    sources = provenance.get("sources")
    if not isinstance(adapter, str) or not adapter:
        raise ObservationError("source identity requires an adapter")
    if (
        not isinstance(sources, (list, tuple))
        or not sources
        or len(sources) > MAXIMUM_PROVENANCE_SOURCES
    ):
        raise ObservationError("source identity has an invalid source count")
    descriptors = []
    for source in sources:
        if not isinstance(source, Mapping):
            raise ObservationError("provenance sources must be mappings")
        descriptors.append(stable_source_descriptor(source))
    canonical = _canonical_json_bytes(
        {"adapter": adapter, "sources": descriptors},
        "source identity",
    )
    return sha256_hex(canonical)


def _normalized_provenance(
    provenance: Mapping[str, Any],
) -> dict[str, Any]:
    adapter = provenance.get("adapter")
    sources = provenance.get("sources")
    if not isinstance(adapter, str) or not adapter:
        raise ObservationError("provenance requires an adapter")
    if (
        not isinstance(sources, (list, tuple))
        or not sources
        or len(sources) > MAXIMUM_PROVENANCE_SOURCES
        or any(not isinstance(source, Mapping) for source in sources)
    ):
        raise ObservationError("provenance source count or shape is invalid")
    normalized = {
        "adapter": adapter,
        "sources": [dict(source) for source in sources],
    }
    if (
        len(_canonical_json_bytes(normalized, "provenance"))
        > MAXIMUM_PROVENANCE_BYTES
    ):
        raise ObservationError("provenance exceeds its canonical byte bound")
    source_identity_sha256(normalized)
    return normalized


def make_metric(
    name: str,
    phase: str,
    availability: str,
    value: Any,
    provenance: Mapping[str, Any],
    reason: str | None = None,
) -> dict[str, Any]:
    """Create one canonical host JSON metric with explicit availability."""

    if name not in METRIC_SPEC_BY_NAME:
        raise ObservationError(f"unknown metric {name!r}")
    if phase not in PHASES:
        raise ObservationError(f"invalid metric phase {phase!r}")
    if availability not in AVAILABILITIES:
        raise ObservationError(f"invalid availability {availability!r}")
    if availability == "present" and value is None:
        raise ObservationError(f"present metric {name} must have a value")
    if availability != "present" and value is not None:
        raise ObservationError(f"unavailable metric {name} must not have a value")
    if availability == "present" and reason is not None:
        raise ObservationError(f"present metric {name} must not have a reason")
    if availability != "present" and (
        not isinstance(reason, str)
        or not reason
        or len(reason.encode("utf-8")) > MAXIMUM_REASON_BYTES
    ):
        raise ObservationError(
            f"unavailable metric {name} must have a bounded reason"
        )
    subject, unit, sample_clock_domain, value_clock_domain = (
        METRIC_SPEC_BY_NAME[name]
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
    normalized_provenance = _normalized_provenance(provenance)
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
        "source_identity_sha256": source_identity_sha256(
            normalized_provenance
        ),
        "provenance": normalized_provenance,
        "reason": reason,
        "reason_sha256": (
            sha256_hex(reason.encode("utf-8"))
            if availability != "present" and reason is not None
            else None
        ),
    }


def validate_metric_record(
    value: Mapping[str, Any],
    *,
    expected_system: str | None = None,
) -> dict[str, Any]:
    expected_fields = (
        "name",
        "availability",
        "value",
        "unit",
        "sample_clock_domain",
        "value_clock_domain",
        "phase",
        "subject",
        "source_identity_sha256",
        "provenance",
        "reason",
        "reason_sha256",
    )
    if not isinstance(value, Mapping) or tuple(value) != expected_fields:
        raise ObservationError("metric record fields are not canonical")
    rebuilt = make_metric(
        str(value["name"]),
        str(value["phase"]),
        str(value["availability"]),
        value["value"],
        value["provenance"],
        value["reason"],
    )
    if dict(value) != rebuilt:
        raise ObservationError("metric record contradicts canonical schema")
    if expected_system is not None:
        if not isinstance(expected_system, str) or not expected_system:
            raise ObservationError("expected provenance system is invalid")
        for source in rebuilt["provenance"]["sources"]:
            if (
                "system" in source
                and source.get("system") != expected_system
            ):
                raise ObservationError(
                    "metric provenance carries a foreign system"
                )
    return rebuilt


def read_bounded_file(path: str, maximum_bytes: int) -> bytes:
    """Read at most maximum+1 bytes from one exact path without scanning."""

    if (
        not isinstance(path, str)
        or not path
        or isinstance(maximum_bytes, bool)
        or not isinstance(maximum_bytes, int)
        or not 1 <= maximum_bytes <= MAXIMUM_FILE_READ_BYTES
    ):
        raise ObservationError("bounded file request is invalid")
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        retained = bytearray()
        while len(retained) <= maximum_bytes:
            remaining = maximum_bytes + 1 - len(retained)
            if remaining == 0:
                break
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            retained.extend(chunk)
        return bytes(retained)
    finally:
        os.close(descriptor)


def required_native_platform(
    environ: Mapping[str, str] | None = None,
) -> str | None:
    source = os.environ if environ is None else environ
    raw = source.get(NATIVE_REQUIRED_ENV)
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise ObservationError(
            f"{NATIVE_REQUIRED_ENV} must be a string platform name"
        )
    if not raw.strip():
        return None
    aliases = {name.casefold(): name for name in NATIVE_PLATFORMS}
    try:
        return aliases[raw.strip().casefold()]
    except KeyError as error:
        raise ObservationError(
            f"{NATIVE_REQUIRED_ENV} must name one of "
            f"{', '.join(NATIVE_PLATFORMS)}"
        ) from error


def enforce_native_requirement(
    *,
    actual_system: str,
    observed_system: str,
    capture_mode: str,
    environ: Mapping[str, str] | None = None,
) -> str | None:
    """Reject simulated or foreign-host capture under the strict native gate."""

    required = required_native_platform(environ)
    if required is None:
        return None
    if (
        not isinstance(actual_system, str)
        or not actual_system
        or not isinstance(observed_system, str)
        or not observed_system
        or capture_mode not in CAPTURE_MODES
    ):
        raise ObservationError("native capture identity is invalid")
    if (
        capture_mode != "native"
        or actual_system != required
        or observed_system != required
    ):
        raise ObservationError(
            f"{NATIVE_REQUIRED_ENV}={required} rejects simulated "
            "or foreign-host observation"
        )
    return required
