from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import copy
import io
import math
import unittest

from bench import lane4_evidence
from bench import native_environment_admission as admission


def _admitted() -> dict:
    return {
        "schema": lane4_evidence.ENVIRONMENT_SCHEMA,
        "measurement_admitted": True,
        "reasons": [],
        "power_source": "AC Power",
        "low_power_mode_enabled": False,
        "thermal_state": "nominal",
        "foundation_thermal_state": "nominal",
        "nested": {"generation": 1},
    }


def _rejected() -> dict:
    value = _admitted()
    value["measurement_admitted"] = False
    value["reasons"] = ["thermal state was not admitted"]
    return value


class _FakeTime:
    def __init__(self, now: float = 0.0) -> None:
        self.now = now
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, duration: float) -> None:
        self.sleeps.append(duration)
        self.now += duration


class _CaptureSequence:
    def __init__(self, *values: object) -> None:
        self.values = list(values)
        self.call_count = 0

    def __call__(self) -> object:
        self.call_count += 1
        if not self.values:
            raise AssertionError("capture called outside its test bound")
        value = self.values.pop(0)
        if isinstance(value, BaseException):
            raise value
        return value


class NativeEnvironmentAdmissionTests(unittest.TestCase):
    def test_frozen_defaults_are_exact(self) -> None:
        self.assertEqual(admission.DEFAULT_TIMEOUT_SECONDS, 180.0)
        self.assertEqual(admission.DEFAULT_INTERVAL_SECONDS, 10.0)
        self.assertEqual(admission.REQUIRED_CONSECUTIVE_SAMPLES, 2)

    def test_two_consecutive_admissions_succeed_after_one_interval(
        self,
    ) -> None:
        fake_time = _FakeTime()
        capture = _CaptureSequence(_admitted(), _admitted())
        result = admission.wait_for_stable_admission(
            capture=capture,
            monotonic=fake_time.monotonic,
            sleep=fake_time.sleep,
        )
        self.assertEqual(result.attempt_count, 2)
        self.assertEqual(result.rejected_count, 0)
        self.assertEqual(result.elapsed_seconds, 10.0)
        self.assertEqual(fake_time.sleeps, [10.0])
        self.assertEqual(capture.call_count, 2)
        self.assertEqual(len(result.captures), 2)

    def test_nonadmitted_capture_resets_the_complete_streak(self) -> None:
        fake_time = _FakeTime()
        capture = _CaptureSequence(
            _admitted(),
            _rejected(),
            _admitted(),
            _admitted(),
        )
        result = admission.wait_for_stable_admission(
            timeout_seconds=40.0,
            interval_seconds=5.0,
            capture=capture,
            monotonic=fake_time.monotonic,
            sleep=fake_time.sleep,
        )
        self.assertEqual(result.attempt_count, 4)
        self.assertEqual(result.rejected_count, 1)
        self.assertEqual(result.elapsed_seconds, 15.0)
        self.assertEqual(fake_time.sleeps, [5.0, 5.0, 5.0])

    def test_every_required_snapshot_fact_is_fail_closed(self) -> None:
        cases: list[object] = []
        for field, value in (
            ("schema", "foreign-schema"),
            ("measurement_admitted", 1),
            ("reasons", ()),
            ("reasons", ["not admitted"]),
            ("power_source", "Battery Power"),
            ("low_power_mode_enabled", 0),
            ("thermal_state", "fair"),
            ("foundation_thermal_state", "serious"),
        ):
            changed = _admitted()
            changed[field] = value
            cases.append(changed)
        missing = _admitted()
        del missing["foundation_thermal_state"]
        cases.extend((missing, None, "not a mapping"))

        for invalid in cases:
            with self.subTest(invalid=invalid):
                fake_time = _FakeTime()
                capture = _CaptureSequence(
                    _admitted(),
                    invalid,
                    _admitted(),
                    _admitted(),
                )
                result = admission.wait_for_stable_admission(
                    timeout_seconds=20.0,
                    interval_seconds=2.0,
                    capture=capture,
                    monotonic=fake_time.monotonic,
                    sleep=fake_time.sleep,
                )
                self.assertEqual(result.attempt_count, 4)
                self.assertEqual(result.rejected_count, 1)

    def test_repeated_rejection_times_out_with_bounded_attempts(self) -> None:
        fake_time = _FakeTime()
        capture_count = 0

        def capture() -> dict:
            nonlocal capture_count
            capture_count += 1
            return _rejected()

        with self.assertRaises(admission.NativeEnvironmentAdmissionTimeout) as caught:
            admission.wait_for_stable_admission(
                timeout_seconds=31.0,
                interval_seconds=10.0,
                capture=capture,
                monotonic=fake_time.monotonic,
                sleep=fake_time.sleep,
            )
        self.assertEqual(capture_count, 4)
        self.assertEqual(fake_time.sleeps, [10.0, 10.0, 10.0])
        self.assertLess(fake_time.now, 31.0)
        self.assertIn("after 4 capture(s)", str(caught.exception))

    def test_capture_exception_aborts_and_preserves_the_cause(self) -> None:
        fake_time = _FakeTime()
        failure = OSError("probe unavailable")
        capture = _CaptureSequence(_admitted(), failure, _admitted())
        with self.assertRaises(admission.NativeEnvironmentAdmissionError) as caught:
            admission.wait_for_stable_admission(
                capture=capture,
                monotonic=fake_time.monotonic,
                sleep=fake_time.sleep,
            )
        self.assertIs(caught.exception.__cause__, failure)
        self.assertEqual(capture.call_count, 2)
        self.assertEqual(fake_time.sleeps, [10.0])

    def test_capture_interrupt_is_not_swallowed(self) -> None:
        fake_time = _FakeTime()
        capture = _CaptureSequence(KeyboardInterrupt())
        with self.assertRaises(KeyboardInterrupt):
            admission.wait_for_stable_admission(
                capture=capture,
                monotonic=fake_time.monotonic,
                sleep=fake_time.sleep,
            )

    def test_invalid_parameters_are_rejected_before_capture(self) -> None:
        captures = 0

        def capture() -> dict:
            nonlocal captures
            captures += 1
            return _admitted()

        invalid_timing = (
            0,
            -1,
            math.nan,
            math.inf,
            True,
            "10",
        )
        for value in invalid_timing:
            with self.subTest(timeout=value):
                with self.assertRaises(admission.NativeEnvironmentAdmissionError):
                    admission.wait_for_stable_admission(
                        timeout_seconds=value,  # type: ignore[arg-type]
                        capture=capture,
                    )
            with self.subTest(interval=value):
                with self.assertRaises(admission.NativeEnvironmentAdmissionError):
                    admission.wait_for_stable_admission(
                        interval_seconds=value,  # type: ignore[arg-type]
                        capture=capture,
                    )
        for timeout, interval in ((10.0, 10.0), (10.0, 11.0)):
            with self.subTest(timeout=timeout, interval=interval):
                with self.assertRaises(admission.NativeEnvironmentAdmissionError):
                    admission.wait_for_stable_admission(
                        timeout_seconds=timeout,
                        interval_seconds=interval,
                        capture=capture,
                    )
        for samples in (1, 3, True, 2.0):
            with self.subTest(samples=samples):
                with self.assertRaises(admission.NativeEnvironmentAdmissionError):
                    admission.wait_for_stable_admission(
                        consecutive_samples=samples,  # type: ignore[arg-type]
                        capture=capture,
                    )
        self.assertEqual(captures, 0)

    def test_nonfinite_backward_and_failed_clocks_fail_closed(self) -> None:
        cases = (
            lambda: math.nan,
            lambda: math.inf,
        )
        for monotonic in cases:
            with self.subTest(monotonic=monotonic):
                with self.assertRaises(admission.NativeEnvironmentAdmissionError):
                    admission.wait_for_stable_admission(
                        monotonic=monotonic,
                    )

        values = iter((10.0, 9.0))
        with self.assertRaisesRegex(
            admission.NativeEnvironmentAdmissionError,
            "backwards",
        ):
            admission.wait_for_stable_admission(
                capture=lambda: _admitted(),
                monotonic=lambda: next(values),
                sleep=lambda _duration: None,
            )

        failure = RuntimeError("clock read failed")

        def failed_clock() -> float:
            raise failure

        with self.assertRaises(admission.NativeEnvironmentAdmissionError) as caught:
            admission.wait_for_stable_admission(monotonic=failed_clock)
        self.assertIs(caught.exception.__cause__, failure)

    def test_sleep_exception_and_no_clock_progress_fail_closed(self) -> None:
        fake_time = _FakeTime()
        failure = OSError("sleep interrupted")

        def failed_sleep(_duration: float) -> None:
            raise failure

        with self.assertRaises(admission.NativeEnvironmentAdmissionError) as caught:
            admission.wait_for_stable_admission(
                capture=lambda: _admitted(),
                monotonic=fake_time.monotonic,
                sleep=failed_sleep,
            )
        self.assertIs(caught.exception.__cause__, failure)

        with self.assertRaisesRegex(
            admission.NativeEnvironmentAdmissionError,
            "no progress",
        ):
            admission.wait_for_stable_admission(
                capture=lambda: _admitted(),
                monotonic=lambda: 0.0,
                sleep=lambda _duration: None,
            )

    def test_short_sleep_is_repeated_before_the_second_capture(self) -> None:
        fake_time = _FakeTime()
        first_sleep = True
        captures_at: list[float] = []

        def capture() -> dict:
            captures_at.append(fake_time.now)
            return _admitted()

        def short_once(duration: float) -> None:
            nonlocal first_sleep
            fake_time.sleeps.append(duration)
            if first_sleep:
                fake_time.now += 4.0
                first_sleep = False
            else:
                fake_time.now += duration

        result = admission.wait_for_stable_admission(
            timeout_seconds=30.0,
            interval_seconds=10.0,
            capture=capture,
            monotonic=fake_time.monotonic,
            sleep=short_once,
        )
        self.assertEqual(result.attempt_count, 2)
        self.assertEqual(captures_at, [0.0, 10.0])
        self.assertEqual(fake_time.sleeps, [10.0, 6.0])

    def test_capture_finishing_at_deadline_cannot_succeed(self) -> None:
        fake_time = _FakeTime()
        capture_count = 0

        def capture() -> dict:
            nonlocal capture_count
            capture_count += 1
            fake_time.now = 20.0
            return _admitted()

        with self.assertRaises(admission.NativeEnvironmentAdmissionTimeout):
            admission.wait_for_stable_admission(
                timeout_seconds=20.0,
                interval_seconds=1.0,
                capture=capture,
                monotonic=fake_time.monotonic,
                sleep=fake_time.sleep,
            )
        self.assertEqual(capture_count, 1)
        self.assertEqual(fake_time.sleeps, [])

    def test_winning_captures_are_deep_copied(self) -> None:
        fake_time = _FakeTime()
        reused = _admitted()
        original = copy.deepcopy(reused)
        result = admission.wait_for_stable_admission(
            capture=lambda: reused,
            monotonic=fake_time.monotonic,
            sleep=fake_time.sleep,
        )
        reused["nested"]["generation"] = 99
        reused["thermal_state"] = "critical"
        self.assertEqual(result.captures[0], original)
        self.assertEqual(result.captures[1], original)

    def test_cli_success_forwards_the_frozen_profile(self) -> None:
        fake_time = _FakeTime()
        capture = _CaptureSequence(_admitted(), _admitted())
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            returncode = admission.main(
                [
                    "--timeout-seconds",
                    "30",
                    "--interval-seconds",
                    "2",
                    "--consecutive-samples",
                    "2",
                ],
                capture=capture,
                monotonic=fake_time.monotonic,
                sleep=fake_time.sleep,
            )
        self.assertEqual(returncode, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(
            stdout.getvalue(),
            "ok native-environment-admission-v1 "
            "samples=2 attempts=2 rejected=0 elapsed_seconds=2.000\n",
        )

    def test_cli_timeout_and_probe_error_are_nonzero(self) -> None:
        for capture in (
            lambda: _rejected(),
            _CaptureSequence(OSError("probe failed")),
        ):
            with self.subTest(capture=capture):
                fake_time = _FakeTime()
                stdout = io.StringIO()
                stderr = io.StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    returncode = admission.main(
                        [
                            "--timeout-seconds",
                            "3",
                            "--interval-seconds",
                            "1",
                        ],
                        capture=capture,
                        monotonic=fake_time.monotonic,
                        sleep=fake_time.sleep,
                    )
                self.assertEqual(returncode, 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertTrue(stderr.getvalue().startswith("error: "))

    def test_cli_rejects_nonprofile_sample_count(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            returncode = admission.main(
                ["--consecutive-samples", "1"],
            )
        self.assertEqual(returncode, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn(
            "consecutive_samples must be exactly 2",
            stderr.getvalue(),
        )

    def test_argparse_type_error_exits_two(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as caught:
                admission.main(["--timeout-seconds", "not-a-number"])
        self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
