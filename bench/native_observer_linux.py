"""Bounded Linux host observer for ``/proc/meminfo`` MemAvailable."""

from __future__ import annotations

import errno
import re
import time
from typing import Any, Callable, Mapping

try:
    from bench import native_observation_common as common
except ImportError:  # pragma: no cover - direct script/import compatibility
    import native_observation_common as common


SYSTEM_NAME = "Linux"
ADAPTER = "linux-procfs-read-only-observer/v1"
MEMINFO_PATH = "/proc/meminfo"
MEMINFO_PARSER_SCHEMA = "linux-proc-meminfo-v1"
MAX_MEMINFO_BYTES = 64 * 1024
MAX_MEM_AVAILABLE_KIB = common.I64_MAX // 1024
MAX_MEM_AVAILABLE_DIGITS = len(str(MAX_MEM_AVAILABLE_KIB))
DIRECT_METRIC_NAMES = frozenset(("host_available_memory_bytes",))

MonotonicClock = Callable[[], int]


def parse_mem_available_bytes(content: bytes) -> int:
    """Parse exactly one ``MemAvailable`` KiB field and return bytes."""

    if type(content) is not bytes:
        raise common.ObservationError("proc meminfo input must be bytes")
    if not content or len(content) > MAX_MEMINFO_BYTES:
        raise common.ObservationError(
            "proc meminfo input is empty or exceeds its bound"
        )
    try:
        text = content.decode("ascii")
    except UnicodeDecodeError as error:
        raise common.ObservationError(
            "proc meminfo is not strict ASCII"
        ) from error
    candidates = [
        line
        for line in text.splitlines()
        if re.match(r"^MemAvailable(?:\s|:|$)", line)
    ]
    if len(candidates) != 1:
        if len(candidates) > 1:
            raise common.ObservationError(
                "proc meminfo contains duplicate MemAvailable fields"
            )
        raise common.ObservationError(
            "proc meminfo does not contain MemAvailable"
        )
    match = re.fullmatch(
        r"MemAvailable:[ \t]+([0-9]+)[ \t]+kB[ \t]*",
        candidates[0],
    )
    if match is None:
        raise common.ObservationError(
            "proc meminfo MemAvailable has an invalid shape or unit"
        )
    digits = match.group(1)
    maximum = str(MAX_MEM_AVAILABLE_KIB)
    if (
        len(digits) > MAX_MEM_AVAILABLE_DIGITS
        or (
            len(digits) == MAX_MEM_AVAILABLE_DIGITS
            and digits > maximum
        )
    ):
        raise common.ObservationError(
            "proc meminfo MemAvailable overflows i64 bytes"
        )
    try:
        kibibytes = int(digits)
    except ValueError as error:
        raise common.ObservationError(
            "proc meminfo MemAvailable is not a bounded integer"
        ) from error
    return kibibytes * 1024


class LinuxObserver:
    """Injectable Linux adapter with one bounded read-only metric source."""

    system_name = SYSTEM_NAME
    adapter_id = ADAPTER
    direct_metric_names = DIRECT_METRIC_NAMES

    def __init__(
        self,
        *,
        reader: common.BoundedFileReader = common.read_bounded_file,
        monotonic_ns: MonotonicClock = time.monotonic_ns,
    ) -> None:
        self._reader = reader
        self._monotonic_ns = monotonic_ns

    def _provenance(
        self,
        *,
        started_ns: int,
        finished_ns: int,
        content: bytes,
        read_status: str,
    ) -> dict[str, Any]:
        return common.bounded_file_provenance(
            adapter_id=self.adapter_id,
            path=MEMINFO_PATH,
            parser_schema=MEMINFO_PARSER_SCHEMA,
            maximum_bytes=MAX_MEMINFO_BYTES,
            started_monotonic_ns=started_ns,
            finished_monotonic_ns=finished_ns,
            content=content,
            read_status=read_status,
        )

    def collect(
        self,
        phase: str,
        context: common.ObservationContext,
    ) -> Mapping[str, Mapping[str, Any]]:
        if phase not in common.PHASES:
            raise common.ObservationError("Linux observer phase is invalid")
        if context.system_name != self.system_name:
            raise common.ObservationError(
                "Linux observer received a foreign platform context"
            )
        started_ns = self._monotonic_ns()
        content = b""
        availability = "present"
        reason: str | None = None
        try:
            content = self._reader(MEMINFO_PATH, MAX_MEMINFO_BYTES)
            if type(content) is not bytes:
                availability = "missing"
                reason = "proc meminfo reader did not return bytes"
                content = b""
            elif len(content) > MAX_MEMINFO_BYTES:
                availability = "missing"
                reason = (
                    "proc meminfo exceeded the retained "
                    f"{MAX_MEMINFO_BYTES} byte bound"
                )
                content = content[: MAX_MEMINFO_BYTES + 1]
        except PermissionError:
            availability = "denied"
            reason = "proc meminfo read was denied"
        except FileNotFoundError:
            availability = "missing"
            reason = "proc meminfo is unavailable on this Linux host"
        except OSError as error:
            availability = (
                "denied"
                if error.errno in (errno.EPERM, errno.EACCES)
                else "missing"
            )
            reason = (
                "proc meminfo read was denied"
                if availability == "denied"
                else "proc meminfo read failed"
            )
        finished_ns = self._monotonic_ns()
        provenance = self._provenance(
            started_ns=started_ns,
            finished_ns=finished_ns,
            content=content,
            read_status=availability,
        )
        if availability != "present":
            assert reason is not None
            metric = common.make_metric(
                "host_available_memory_bytes",
                phase,
                availability,
                None,
                provenance,
                reason,
            )
            return {"host_available_memory_bytes": metric}
        try:
            available_bytes = parse_mem_available_bytes(content)
        except common.ObservationError as error:
            metric = common.make_metric(
                "host_available_memory_bytes",
                phase,
                "missing",
                None,
                provenance,
                f"proc meminfo could not be parsed: {error}",
            )
        else:
            metric = common.make_metric(
                "host_available_memory_bytes",
                phase,
                "present",
                available_bytes,
                provenance,
            )
        return {"host_available_memory_bytes": metric}
