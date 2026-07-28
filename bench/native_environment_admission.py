#!/usr/bin/env python3
"""Require a bounded, stable native environment admission window.

This helper deliberately makes only an admission claim.  It does not measure
temperature, frequency, power, or performance.  Success requires two
consecutive, explicit admissions from :mod:`bench.lane4_evidence`, separated
by the configured interval.  A rejected observation clears the whole streak.

The deadline bounds calls that return; Python cannot preempt an arbitrary
injected capture callable that never returns.  The production capture uses
bounded subprocess probes.
"""

from __future__ import annotations

import argparse
import copy
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
import math
import sys
import time
from typing import Any

from bench import lane4_evidence


DEFAULT_TIMEOUT_SECONDS = 180.0
DEFAULT_INTERVAL_SECONDS = 10.0
REQUIRED_CONSECUTIVE_SAMPLES = 2


class NativeEnvironmentAdmissionError(RuntimeError):
    """Stable native environment admission could not be established."""


class NativeEnvironmentAdmissionTimeout(NativeEnvironmentAdmissionError):
    """The bounded admission window ended without a stable streak."""


@dataclass(frozen=True)
class StableAdmissionResult:
    """The exact winning streak and bounded-observation summary."""

    captures: tuple[dict[str, Any], dict[str, Any]]
    attempt_count: int
    rejected_count: int
    elapsed_seconds: float


Capture = Callable[[], object]
Clock = Callable[[], float]
Sleeper = Callable[[float], None]


def _positive_finite(value: object, label: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        raise NativeEnvironmentAdmissionError(
            "%s must be a positive finite number" % label
        )
    return float(value)


def _validate_parameters(
    timeout_seconds: object,
    interval_seconds: object,
    consecutive_samples: object,
) -> tuple[float, float]:
    timeout = _positive_finite(timeout_seconds, "timeout_seconds")
    interval = _positive_finite(interval_seconds, "interval_seconds")
    if interval >= timeout:
        raise NativeEnvironmentAdmissionError(
            "interval_seconds must be less than timeout_seconds"
        )
    if (
        isinstance(consecutive_samples, bool)
        or not isinstance(consecutive_samples, int)
        or consecutive_samples != REQUIRED_CONSECUTIVE_SAMPLES
    ):
        raise NativeEnvironmentAdmissionError(
            "consecutive_samples must be exactly %d" % REQUIRED_CONSECUTIVE_SAMPLES
        )
    return timeout, interval


def _read_clock(
    monotonic: Clock,
    *,
    previous: float | None = None,
) -> float:
    try:
        value = monotonic()
    except Exception as error:
        raise NativeEnvironmentAdmissionError(
            "monotonic clock failed closed: %s" % error
        ) from error
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise NativeEnvironmentAdmissionError(
            "monotonic clock returned a non-finite value"
        )
    result = float(value)
    if previous is not None and result < previous:
        raise NativeEnvironmentAdmissionError("monotonic clock moved backwards")
    return result


def _snapshot_rejections(value: object) -> tuple[str, ...]:
    if not isinstance(value, Mapping):
        return ("capture is not a mapping",)
    try:
        schema = value.get("schema")
        measurement_admitted = value.get("measurement_admitted")
        reasons = value.get("reasons")
        power_source = value.get("power_source")
        low_power_mode = value.get("low_power_mode_enabled")
        thermal_state = value.get("thermal_state")
        foundation_thermal_state = value.get("foundation_thermal_state")
    except Exception as error:
        return ("capture mapping could not be inspected: %s" % error,)

    failures = []
    if schema != lane4_evidence.ENVIRONMENT_SCHEMA:
        failures.append("environment schema is not admitted")
    if measurement_admitted is not True:
        failures.append("measurement_admitted is not true")
    if type(reasons) is not list or reasons:
        failures.append("reasons is not an exact empty list")
    if power_source != "AC Power":
        failures.append("power source is not AC Power")
    if low_power_mode is not False:
        failures.append("Low Power Mode is enabled or unknown")
    if thermal_state != "nominal":
        failures.append("pmset thermal state is not nominal")
    if foundation_thermal_state != "nominal":
        failures.append("Foundation thermal state is not nominal")
    return tuple(failures)


def _copy_capture(value: object) -> dict[str, Any]:
    try:
        copied = copy.deepcopy(dict(value))  # type: ignore[arg-type]
    except Exception as error:
        raise NativeEnvironmentAdmissionError(
            "admitted capture could not be retained: %s" % error
        ) from error
    if not isinstance(copied, dict):
        raise NativeEnvironmentAdmissionError(
            "admitted capture copy is not a dictionary"
        )
    return copied


def _timeout(
    timeout_seconds: float,
    attempt_count: int,
    streak_count: int,
    last_rejections: tuple[str, ...],
) -> NativeEnvironmentAdmissionTimeout:
    detail = (
        "; last rejection: %s" % ", ".join(last_rejections) if last_rejections else ""
    )
    return NativeEnvironmentAdmissionTimeout(
        "stable native environment admission timed out within %.3fs "
        "after %d capture(s), final streak %d/%d%s"
        % (
            timeout_seconds,
            attempt_count,
            streak_count,
            REQUIRED_CONSECUTIVE_SAMPLES,
            detail,
        )
    )


def _sleep_until(
    target: float,
    deadline: float,
    now: float,
    *,
    monotonic: Clock,
    sleep: Sleeper,
) -> float:
    while now < target:
        if target >= deadline:
            raise NativeEnvironmentAdmissionTimeout(
                "stable native environment admission has no time "
                "for another full sample interval"
            )
        duration = target - now
        try:
            sleep(duration)
        except Exception as error:
            raise NativeEnvironmentAdmissionError(
                "admission interval sleep failed closed: %s" % error
            ) from error
        observed = _read_clock(monotonic, previous=now)
        if observed <= now:
            raise NativeEnvironmentAdmissionError(
                "monotonic clock made no progress during admission sleep"
            )
        if observed >= deadline:
            raise NativeEnvironmentAdmissionTimeout(
                "stable native environment admission reached its deadline "
                "during the sample interval"
            )
        now = observed
    return now


def wait_for_stable_admission(
    *,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    interval_seconds: float = DEFAULT_INTERVAL_SECONDS,
    consecutive_samples: int = REQUIRED_CONSECUTIVE_SAMPLES,
    capture: Capture = lane4_evidence.capture_environment,
    monotonic: Clock = time.monotonic,
    sleep: Sleeper = time.sleep,
) -> StableAdmissionResult:
    """Wait for the fixed two-sample stable native admission profile.

    A normal nonadmitted capture clears the current streak and is retried
    within the deadline.  An escaped capture, clock, or sleep exception aborts
    immediately because ignoring uncertain probe execution would not be
    fail-closed.
    """

    timeout, interval = _validate_parameters(
        timeout_seconds,
        interval_seconds,
        consecutive_samples,
    )
    started = _read_clock(monotonic)
    deadline = started + timeout
    if not math.isfinite(deadline):
        raise NativeEnvironmentAdmissionError(
            "timeout produces a non-finite monotonic deadline"
        )

    now = started
    attempts = 0
    rejected = 0
    streak: list[dict[str, Any]] = []
    last_rejections: tuple[str, ...] = ()

    while now < deadline:
        try:
            captured = capture()
        except Exception as error:
            raise NativeEnvironmentAdmissionError(
                "native environment capture failed closed: %s" % error
            ) from error
        attempts += 1
        finished = _read_clock(monotonic, previous=now)
        if finished >= deadline:
            raise _timeout(
                timeout,
                attempts,
                len(streak),
                last_rejections,
            )

        failures = _snapshot_rejections(captured)
        if failures:
            rejected += 1
            streak.clear()
            last_rejections = failures
        else:
            streak.append(_copy_capture(captured))
            last_rejections = ()
            if len(streak) == REQUIRED_CONSECUTIVE_SAMPLES:
                return StableAdmissionResult(
                    captures=(streak[0], streak[1]),
                    attempt_count=attempts,
                    rejected_count=rejected,
                    elapsed_seconds=finished - started,
                )

        target = finished + interval
        if target >= deadline:
            raise _timeout(
                timeout,
                attempts,
                len(streak),
                last_rejections,
            )
        now = _sleep_until(
            target,
            deadline,
            finished,
            monotonic=monotonic,
            sleep=sleep,
        )

    raise _timeout(
        timeout,
        attempts,
        len(streak),
        last_rejections,
    )


def main(
    argv: Sequence[str] | None = None,
    *,
    capture: Capture = lane4_evidence.capture_environment,
    monotonic: Clock = time.monotonic,
    sleep: Sleeper = time.sleep,
) -> int:
    parser = argparse.ArgumentParser(
        description=("Require two bounded consecutive native environment admissions")
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
    )
    parser.add_argument(
        "--interval-seconds",
        type=float,
        default=DEFAULT_INTERVAL_SECONDS,
    )
    parser.add_argument(
        "--consecutive-samples",
        type=int,
        default=REQUIRED_CONSECUTIVE_SAMPLES,
        help="fixed profile value; must be exactly 2",
    )
    arguments = parser.parse_args(argv)
    try:
        result = wait_for_stable_admission(
            timeout_seconds=arguments.timeout_seconds,
            interval_seconds=arguments.interval_seconds,
            consecutive_samples=arguments.consecutive_samples,
            capture=capture,
            monotonic=monotonic,
            sleep=sleep,
        )
    except NativeEnvironmentAdmissionError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    print(
        "ok native-environment-admission-v1 "
        "samples=%d attempts=%d rejected=%d elapsed_seconds=%.3f"
        % (
            REQUIRED_CONSECUTIVE_SAMPLES,
            result.attempt_count,
            result.rejected_count,
            result.elapsed_seconds,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
