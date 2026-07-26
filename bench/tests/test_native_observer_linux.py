import errno
import hashlib
import os
import platform
import unittest
from unittest import mock

from bench import native_observation_common as common
from bench import native_observer as observer
from bench import native_observer_linux as linux


def _context() -> common.ObservationContext:
    return common.ObservationContext(
        system_name="Linux",
        process_id=4242,
        process_group_id=None,
        logical_cpu_count=8,
    )


def _clock() -> object:
    values = iter((100, 200))
    return lambda: next(values)


class LinuxMeminfoParserTests(unittest.TestCase):
    def test_parses_exact_mem_available_kib_as_bytes(self):
        self.assertEqual(
            linux.parse_mem_available_bytes(
                b"MemTotal: 100 kB\nMemAvailable:\t42 kB \n"
            ),
            42 * 1024,
        )
        self.assertEqual(
            linux.parse_mem_available_bytes(b"MemAvailable: 0 kB\n"),
            0,
        )
        maximum_safe = common.I64_MAX // 1024
        self.assertEqual(
            linux.parse_mem_available_bytes(
                f"MemAvailable: {maximum_safe} kB\n".encode("ascii")
            ),
            maximum_safe * 1024,
        )

    def test_rejects_substitution_malformed_duplicate_and_overflow(self):
        invalid = (
            b"",
            b"MemFree: 12 kB\n",
            b"MemAvailable: 12 MB\n",
            b"MemAvailable: -1 kB\n",
            b"MemAvailable: +1 kB\n",
            b"MemAvailable: 1.5 kB\n",
            b"MemAvailable: 1 kB trailing\n",
            b"memavailable: 1 kB\n",
            b"MemAvailable: 1 kB\nMemAvailable: 2 kB\n",
            b"MemAvailable: 1 kB\nMemAvailable: malformed\n",
            b"MemAvailable: \xff kB\n",
            (
                f"MemAvailable: {common.I64_MAX // 1024 + 1} kB\n"
            ).encode("ascii"),
            b"MemAvailable: " + b"9" * 5000 + b" kB\n",
            b"MemAvailable: " + b"0" * 5000 + b" kB\n",
            b"x" * (linux.MAX_MEMINFO_BYTES + 1),
        )
        for content in invalid:
            with self.subTest(content=content[:80]):
                with self.assertRaises(common.ObservationError):
                    linux.parse_mem_available_bytes(content)


class LinuxObserverTests(unittest.TestCase):
    def test_present_metric_uses_fixed_bounded_source(self):
        calls = []

        def read(path, maximum_bytes):
            calls.append((path, maximum_bytes))
            return b"MemTotal: 1000 kB\nMemAvailable: 321 kB\n"

        metric = linux.LinuxObserver(
            reader=read,
            monotonic_ns=_clock(),
        ).collect("pre_run", _context())["host_available_memory_bytes"]

        self.assertEqual(
            calls,
            [(linux.MEMINFO_PATH, linux.MAX_MEMINFO_BYTES)],
        )
        self.assertEqual(metric["availability"], "present")
        self.assertEqual(metric["value"], 321 * 1024)
        self.assertEqual(metric["unit"], "bytes")
        self.assertEqual(metric["phase"], "pre_run")
        source = metric["provenance"]["sources"][0]
        self.assertEqual(source["kind"], "bounded-file")
        self.assertEqual(source["path"], "/proc/meminfo")
        self.assertEqual(source["maximum_bytes"], linux.MAX_MEMINFO_BYTES)
        self.assertEqual(source["started_monotonic_ns"], 100)
        self.assertEqual(source["finished_monotonic_ns"], 200)
        self.assertEqual(source["read_status"], "present")
        self.assertNotIn("content", source)

    def test_identity_is_stable_while_event_evidence_changes(self):
        def collect(content, started):
            values = iter((started, started + 1))
            return linux.LinuxObserver(
                reader=lambda _path, _maximum: content,
                monotonic_ns=lambda: next(values),
            ).collect("probe", _context())[
                "host_available_memory_bytes"
            ]

        first = collect(b"MemAvailable: 10 kB\n", 10)
        second = collect(b"MemAvailable: 20 kB\n", 20)
        self.assertEqual(
            first["source_identity_sha256"],
            second["source_identity_sha256"],
        )
        self.assertNotEqual(first["value"], second["value"])
        self.assertNotEqual(
            first["provenance"]["sources"][0]["content_sha256"],
            second["provenance"]["sources"][0]["content_sha256"],
        )

    def test_rejects_invalid_bounded_file_clock_intervals(self):
        for timestamps in (
            (True, 2),
            (-1, 2),
            (2, 1),
            (1, common.I64_MAX + 1),
        ):
            with self.subTest(timestamps=timestamps):
                values = iter(timestamps)
                adapter = linux.LinuxObserver(
                    reader=lambda _path, _maximum: (
                        b"MemAvailable: 1 kB\n"
                    ),
                    monotonic_ns=lambda: next(values),
                )
                with self.assertRaisesRegex(
                    common.ObservationError,
                    "monotonic interval",
                ):
                    adapter.collect("probe", _context())

    def test_read_failures_and_malformed_content_are_explicit(self):
        cases = (
            (
                lambda _path, _maximum: (_ for _ in ()).throw(
                    PermissionError("denied")
                ),
                "denied",
            ),
            (
                lambda _path, _maximum: (_ for _ in ()).throw(
                    FileNotFoundError("absent")
                ),
                "missing",
            ),
            (
                lambda _path, _maximum: (_ for _ in ()).throw(
                    OSError(errno.EPERM, "denied")
                ),
                "denied",
            ),
            (
                lambda _path, _maximum: (_ for _ in ()).throw(
                    OSError(errno.EIO, "failed")
                ),
                "missing",
            ),
            (lambda _path, _maximum: "not bytes", "missing"),
            (lambda _path, _maximum: b"MemFree: 1 kB\n", "missing"),
            (
                lambda _path, _maximum: (
                    b"MemAvailable: " + b"9" * 5000 + b" kB\n"
                ),
                "missing",
            ),
            (
                lambda _path, _maximum: b"x"
                * (linux.MAX_MEMINFO_BYTES + 2),
                "missing",
            ),
        )
        for reader, expected in cases:
            with self.subTest(expected=expected, reader=reader):
                metric = linux.LinuxObserver(
                    reader=reader,
                    monotonic_ns=_clock(),
                ).collect("probe", _context())[
                    "host_available_memory_bytes"
                ]
                self.assertEqual(metric["availability"], expected)
                self.assertIsNone(metric["value"])
                self.assertTrue(metric["reason"])
                self.assertEqual(
                    metric["reason_sha256"],
                    hashlib.sha256(
                        metric["reason"].encode("utf-8")
                    ).hexdigest(),
                )
                source = metric["provenance"]["sources"][0]
                self.assertLessEqual(
                    source["content_bytes"],
                    linux.MAX_MEMINFO_BYTES + 1,
                )

    def test_dispatcher_accepts_injected_cross_host_linux_adapter(self):
        adapter = linux.LinuxObserver(
            reader=lambda _path, _maximum: b"MemAvailable: 512 kB\n",
            monotonic_ns=_clock(),
        )

        def unexpected(_argv, _timeout):
            raise AssertionError("Linux adapter must not run macOS commands")

        with mock.patch.object(
            observer.platform,
            "system",
            return_value="Darwin",
        ), mock.patch.dict(
            os.environ,
            {common.NATIVE_REQUIRED_ENV: ""},
        ):
            snapshot = observer.capture_observation(
                "probe",
                runner=unexpected,
                platform_adapter=adapter,
                logical_cpu_count=4,
                process_id=4242,
            )
        memory = observer.metric_by_name(
            snapshot, "host_available_memory_bytes"
        )
        self.assertEqual(snapshot["schema"], observer.HOST_SCHEMA)
        self.assertEqual(snapshot["system"], "Linux")
        self.assertEqual(snapshot["actual_system"], "Darwin")
        self.assertEqual(snapshot["adapter"], linux.ADAPTER)
        self.assertEqual(snapshot["capture_mode"], "simulated")
        self.assertFalse(snapshot["publication_eligible"])
        self.assertEqual(
            snapshot["claim_scope"],
            "simulated-observation-only",
        )
        self.assertEqual(len(snapshot["metrics"]), len(observer.METRIC_SPECS))
        self.assertEqual(memory["availability"], "present")
        self.assertEqual(memory["value"], 512 * 1024)
        self.assertEqual(
            memory["provenance"]["adapter"],
            linux.ADAPTER,
        )
        self.assertEqual(
            observer.metric_by_name(
                snapshot, "host_logical_cpu_count"
            )["value"],
            4,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_power_source")[
                "availability"
            ],
            "unsupported",
        )

    def test_strict_native_requirement_rejects_cross_host_injection(self):
        adapter = linux.LinuxObserver(
            reader=lambda _path, _maximum: b"MemAvailable: 1 kB\n",
            monotonic_ns=_clock(),
        )
        with mock.patch.object(
            observer.platform,
            "system",
            return_value="Darwin",
        ), mock.patch.dict(
            os.environ,
            {common.NATIVE_REQUIRED_ENV: "Darwin"},
        ):
            with self.assertRaisesRegex(
                common.ObservationError,
                "rejects simulated",
            ):
                observer.capture_observation(
                    "probe",
                    platform_adapter=adapter,
                    logical_cpu_count=4,
                    process_id=4242,
                )

    def test_unimplemented_native_baseline_is_nonpublishable(self):
        with mock.patch.object(
            observer.platform,
            "system",
            return_value="FreeBSD",
        ), mock.patch.dict(
            os.environ,
            {common.NATIVE_REQUIRED_ENV: ""},
        ):
            snapshot = observer.capture_observation(
                "probe",
                logical_cpu_count=4,
                process_id=4242,
            )
        self.assertEqual(snapshot["actual_system"], "FreeBSD")
        self.assertEqual(snapshot["system"], "FreeBSD")
        self.assertEqual(snapshot["capture_mode"], "native")
        self.assertFalse(snapshot["publication_eligible"])
        self.assertEqual(snapshot["adapter"], observer.BASELINE_ADAPTER)

    def test_dispatcher_rejects_incomplete_or_foreign_adapter_output(self):
        class BadAdapter:
            system_name = "Linux"
            adapter_id = "bad-linux-adapter/v1"
            direct_metric_names = frozenset(
                ("host_available_memory_bytes",)
            )

            def __init__(self, foreign=False):
                self.foreign = foreign

            def collect(self, phase, _context):
                if not self.foreign:
                    return {}
                return {
                    "host_available_memory_bytes": common.make_metric(
                        "host_available_memory_bytes",
                        phase,
                        "present",
                        1,
                        common.runtime_provenance(
                            "foreign-adapter/v1",
                            "Linux",
                            "test",
                        ),
                    )
                }

        with mock.patch.dict(
            os.environ,
            {common.NATIVE_REQUIRED_ENV: ""},
        ):
            with self.assertRaisesRegex(
                common.ObservationError, "exact declared"
            ):
                observer.capture_observation(
                    "probe",
                    platform_adapter=BadAdapter(),
                    logical_cpu_count=4,
                    process_id=4242,
                )
            with self.assertRaisesRegex(
                common.ObservationError, "foreign provenance"
            ):
                observer.capture_observation(
                    "probe",
                    platform_adapter=BadAdapter(foreign=True),
                    logical_cpu_count=4,
                    process_id=4242,
                )

    def test_dispatcher_rejects_foreign_system_provenance(self):
        class ForeignSystemAdapter:
            system_name = "Linux"
            adapter_id = "test-linux-adapter/v1"
            direct_metric_names = frozenset(
                ("host_available_memory_bytes",)
            )

            def collect(self, phase, _context):
                return {
                    "host_available_memory_bytes": common.make_metric(
                        "host_available_memory_bytes",
                        phase,
                        "present",
                        1,
                        common.runtime_provenance(
                            self.adapter_id,
                            "Windows",
                            "test",
                        ),
                    )
                }

        with mock.patch.dict(
            os.environ,
            {common.NATIVE_REQUIRED_ENV: ""},
        ):
            with self.assertRaisesRegex(
                common.ObservationError,
                "foreign system",
            ):
                observer.capture_observation(
                    "probe",
                    platform_adapter=ForeignSystemAdapter(),
                    logical_cpu_count=4,
                    process_id=4242,
                )


class PlatformNeutralContractTests(unittest.TestCase):
    def test_long_probe_errors_remain_bounded_unavailable_metrics(self):
        def denied(_argv, _timeout):
            raise PermissionError("é" * 2000)

        snapshot = observer.capture_observation(
            "probe",
            runner=denied,
            system_name="Darwin",
            logical_cpu_count=4,
            process_id=42,
            process_group_id=42,
        )
        for name in (
            "host_power_source",
            "host_low_power_mode",
            "host_available_memory_bytes",
        ):
            metric = observer.metric_by_name(snapshot, name)
            self.assertEqual(metric["availability"], "denied")
            self.assertLessEqual(
                len(metric["reason"].encode("utf-8")),
                common.MAXIMUM_REASON_BYTES,
            )

    def test_command_identity_can_exclude_dynamic_event_argv(self):
        first = {
            "adapter": "test-command-adapter/v1",
            "sources": [
                {
                    "kind": "command",
                    "argv": ["/bin/ps", "-p", "101"],
                    "source_id_argv": [
                        "/bin/ps",
                        "-p",
                        "<observed-process-id>",
                    ],
                    "started_monotonic_ns": 1,
                }
            ],
        }
        second = {
            "adapter": "test-command-adapter/v1",
            "sources": [
                {
                    "kind": "command",
                    "argv": ["/bin/ps", "-p", "202"],
                    "source_id_argv": [
                        "/bin/ps",
                        "-p",
                        "<observed-process-id>",
                    ],
                    "started_monotonic_ns": 2,
                }
            ],
        }
        self.assertEqual(
            common.source_identity_sha256(first),
            common.source_identity_sha256(second),
        )
        legacy = {
            "adapter": "legacy-command-adapter/v1",
            "sources": [{"kind": "command", "argv": ["/bin/true"]}],
        }
        self.assertRegex(
            common.source_identity_sha256(legacy),
            r"^[0-9a-f]{64}$",
        )

    def test_native_requirement_is_strict_and_host_checked(self):
        self.assertIsNone(common.required_native_platform({}))
        self.assertEqual(
            common.required_native_platform(
                {common.NATIVE_REQUIRED_ENV: " linux "}
            ),
            "Linux",
        )
        with self.assertRaises(common.ObservationError):
            common.required_native_platform(
                {common.NATIVE_REQUIRED_ENV: "plan9"}
            )
        with self.assertRaises(common.ObservationError):
            common.required_native_platform(
                {common.NATIVE_REQUIRED_ENV: 1}
            )
        for unsupported in ("Windows", "FreeBSD"):
            with self.subTest(unsupported=unsupported):
                with self.assertRaises(common.ObservationError):
                    common.required_native_platform(
                        {common.NATIVE_REQUIRED_ENV: unsupported}
                    )
        self.assertEqual(
            common.enforce_native_requirement(
                actual_system="Linux",
                observed_system="Linux",
                capture_mode="native",
                environ={common.NATIVE_REQUIRED_ENV: "Linux"},
            ),
            "Linux",
        )
        with self.assertRaisesRegex(
            common.ObservationError,
            "rejects simulated",
        ):
            common.enforce_native_requirement(
                actual_system="Darwin",
                observed_system="Linux",
                capture_mode="simulated",
                environ={common.NATIVE_REQUIRED_ENV: "Darwin"},
            )
        required = common.required_native_platform()
        if required is not None:
            self.assertEqual(
                platform.system(),
                required,
                f"{common.NATIVE_REQUIRED_ENV} requires a native {required} job",
            )

    def test_native_linux_smoke_or_skip(self):
        required = common.required_native_platform()
        if platform.system() != "Linux":
            if required == "Linux":
                self.fail(
                    f"{common.NATIVE_REQUIRED_ENV}=Linux requires a Linux host"
                )
            self.skipTest("native /proc/meminfo smoke requires Linux")
        snapshot = observer.capture_observation("probe")
        metric = observer.metric_by_name(
            snapshot, "host_available_memory_bytes"
        )
        self.assertEqual(snapshot["adapter"], linux.ADAPTER)
        self.assertEqual(snapshot["actual_system"], "Linux")
        self.assertEqual(snapshot["capture_mode"], "native")
        self.assertTrue(snapshot["publication_eligible"])
        self.assertEqual(
            snapshot["claim_scope"],
            "native-observation-only",
        )
        self.assertEqual(metric["availability"], "present")
        source = metric["provenance"]["sources"][0]
        self.assertEqual(source["path"], "/proc/meminfo")
        self.assertEqual(source["maximum_bytes"], linux.MAX_MEMINFO_BYTES)


if __name__ == "__main__":
    unittest.main()
