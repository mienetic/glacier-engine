import hashlib
import importlib.util
import json
import platform
import subprocess
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "native_observer.py"
SPEC = importlib.util.spec_from_file_location("native_observer", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)


BATTERY = (
    "Now drawing from 'AC Power'\n"
    " -InternalBattery-0 (id=1)\t100%; charged; present: true\n"
)
SETTINGS = (
    "Battery Power:\n"
    " lowpowermode 1\n"
    "AC Power:\n"
    " lowpowermode 0\n"
    " tcpkeepalive 1\n"
)
THERMAL = (
    "CPU_Scheduler_Limit = 100\n"
    "CPU_Available_CPUs = 8\n"
    "CPU_Speed_Limit = 100\n"
)
VM = (
    "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
    "Pages free: 100.\n"
    "Pages inactive: 200.\n"
    "Pages speculative: 50.\n"
    'Pageouts: 10.\n"Swapins": 20.\n"Swapouts": 30.\n'
)
SWAP = "total = 2048.00M  used = 128.50M  free = 1919.50M  (encrypted)\n"
RSS = " 65536\n"
TOP = (
    "Load Avg: 0.20, 0.30, 0.40\n"
    "CPU usage: 2.0% user, 1.0% sys, 97.0% idle\n"
    "Load Avg: 0.40, 0.30, 0.20\n"
    "CPU usage: 4.0% user, 2.0% sys, 94.0% idle\n"
)


class NativeObserverTests(unittest.TestCase):
    def _runner(self, overrides=None):
        responses = {
            (observer.PMSET, "-g", "batt"): BATTERY,
            (observer.PMSET, "-g", "custom"): SETTINGS,
            (observer.PMSET, "-g", "therm"): THERMAL,
            (observer.VM_STAT,): VM,
            (observer.SYSCTL, "-n", "vm.swapusage"): SWAP,
            (observer.PS, "-o", "rss=", "-p", "4242"): RSS,
            (
                observer.PS,
                "-A",
                "-o",
                "pid=,ppid=,pgid=,pcpu=,comm=",
            ): (
                "100 1 100 20.0 external-worker\n"
                "4242 1 4242 50.0 harness\n"
                "4243 4242 4242 10.0 sampler\n"
            ),
            (
                observer.TOP,
                "-l",
                "2",
                "-s",
                "1",
                "-n",
                "0",
            ): TOP,
        }
        if overrides:
            responses.update(overrides)

        def run(argv, _timeout_seconds):
            output = responses[tuple(argv)]
            return subprocess.CompletedProcess(
                argv, 0, stdout=output.encode("utf-8"), stderr=b""
            )

        return run

    def test_darwin_capture_has_fixed_explicit_metric_records(self):
        snapshot = observer.capture_observation(
            "pre-run",
            runner=self._runner(),
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )

        self.assertEqual(snapshot["schema"], observer.SCHEMA)
        self.assertEqual(snapshot["claim_scope"], "native-observation-only")
        self.assertEqual(
            len(snapshot["metrics"]),
            len(observer.METRIC_SPECS),
        )
        self.assertEqual(
            [metric["name"] for metric in snapshot["metrics"]],
            [
                name
                for (
                    name,
                    _subject,
                    _unit,
                    _sample_clock,
                    _value_clock,
                ) in observer.METRIC_SPECS
            ],
        )
        for metric in snapshot["metrics"]:
            self.assertEqual(
                set(metric),
                {
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
                },
            )
            self.assertIn(metric["availability"], observer.AVAILABILITIES)
            self.assertEqual(metric["phase"], "pre_run")
            self.assertIn(metric["subject"], {"host", "process"})
            self.assertTrue(metric["unit"])
            self.assertEqual(
                metric["sample_clock_domain"],
                "host_monotonic",
            )
            if (
                metric["name"] == "host_monotonic_time"
                and metric["availability"] == "present"
            ):
                self.assertEqual(
                    metric["value_clock_domain"],
                    "host_monotonic",
                )
            else:
                self.assertIsNone(metric["value_clock_domain"])
            self.assertEqual(metric["provenance"]["adapter"], observer.ADAPTER)
            self.assertTrue(metric["provenance"]["sources"])
            self.assertRegex(
                metric["source_identity_sha256"],
                r"^[0-9a-f]{64}$",
            )
            if metric["availability"] == "present":
                self.assertIsNotNone(metric["value"])
                self.assertIsInstance(metric["value"], int)
                self.assertNotIsInstance(metric["value"], bool)
                self.assertIsNone(metric["reason"])
                self.assertIsNone(metric["reason_sha256"])
            else:
                self.assertIsNone(metric["value"])
                self.assertTrue(metric["reason"])
                self.assertEqual(
                    metric["reason_sha256"],
                    hashlib.sha256(metric["reason"].encode("utf-8")).hexdigest(),
                )

        self.assertEqual(
            observer.metric_by_name(snapshot, "host_power_source")["value"],
            observer.POWER_SOURCE_AC,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_low_power_mode")["value"],
            0,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_low_power_mode")["unit"],
            "boolean",
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_thermal_constraint")[
                "value"
            ],
            observer.THERMAL_NOMINAL,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_cpu_idle_ppm")["value"],
            940_000,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_cpu_busy_ppm")["value"],
            60_000,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_external_cpu_ppm")["value"],
            25_000,
        )
        self.assertEqual(
            observer.metric_by_name(
                snapshot, "host_available_memory_bytes"
            )["value"],
            350 * 4096,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_swap_used_bytes")["value"],
            int(128.5 * (1 << 20)),
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "process_resident_bytes")["value"],
            65536 * 1024,
        )
        self.assertEqual(
            sum(snapshot["availability_counts"].values()),
            len(snapshot["metrics"]),
        )

    def test_command_provenance_retains_hash_not_raw_output(self):
        snapshot = observer.capture_observation(
            "probe",
            runner=self._runner(),
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        metric = observer.metric_by_name(snapshot, "host_power_source")
        source = metric["provenance"]["sources"][0]
        self.assertEqual(source["argv"], [observer.PMSET, "-g", "batt"])
        self.assertEqual(source["stdout_bytes"], len(BATTERY.encode("utf-8")))
        self.assertEqual(
            source["stdout_sha256"],
            hashlib.sha256(BATTERY.encode("utf-8")).hexdigest(),
        )
        self.assertNotIn("stdout", source)

    def test_source_identity_is_stable_while_provenance_changes(self):
        first = observer.capture_observation(
            "probe",
            runner=self._runner(),
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        second = observer.capture_observation(
            "probe",
            runner=self._runner(
                {
                    (observer.PMSET, "-g", "batt"): BATTERY + "\n",
                }
            ),
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        first_power = observer.metric_by_name(first, "host_power_source")
        second_power = observer.metric_by_name(second, "host_power_source")
        self.assertEqual(
            first_power["source_identity_sha256"],
            second_power["source_identity_sha256"],
        )
        self.assertNotEqual(
            first_power["provenance"],
            second_power["provenance"],
        )
        self.assertNotEqual(
            first_power["provenance"]["sources"][0]["stdout_sha256"],
            second_power["provenance"]["sources"][0]["stdout_sha256"],
        )

        provenance = observer._runtime_provenance(  # noqa: SLF001
            "Darwin",
            "example.runtime_api",
        )
        first_transform = observer._metric(  # noqa: SLF001
            "host_available_memory_bytes",
            "probe",
            "present",
            1,
            observer._derived_provenance(  # noqa: SLF001
                provenance,
                "pages*page_size",
            ),
        )
        second_transform = observer._metric(  # noqa: SLF001
            "host_available_memory_bytes",
            "probe",
            "present",
            1,
            observer._derived_provenance(  # noqa: SLF001
                provenance,
                "(pages+cached)*page_size",
            ),
        )
        self.assertNotEqual(
            first_transform["source_identity_sha256"],
            second_transform["source_identity_sha256"],
        )

    def test_reason_digest_is_bound_only_to_unavailable_records(self):
        denied_reason = "permission denied by test policy"
        denied = observer._metric(  # noqa: SLF001
            "host_power_source",
            "probe",
            "denied",
            None,
            observer._runtime_provenance(  # noqa: SLF001
                "Darwin",
                "example.power_api",
            ),
            denied_reason,
        )
        self.assertEqual(
            denied["reason_sha256"],
            hashlib.sha256(denied_reason.encode("utf-8")).hexdigest(),
        )

        present = observer._metric(  # noqa: SLF001
            "host_power_source",
            "probe",
            "present",
            observer.POWER_SOURCE_AC,
            observer._runtime_provenance(  # noqa: SLF001
                "Darwin",
                "example.power_api",
            ),
        )
        self.assertIsNone(present["reason"])
        self.assertIsNone(present["reason_sha256"])
        with self.assertRaisesRegex(observer.ObservationError, "reason"):
            observer._metric(  # noqa: SLF001
                "host_power_source",
                "probe",
                "present",
                observer.POWER_SOURCE_AC,
                observer._runtime_provenance(  # noqa: SLF001
                    "Darwin",
                    "example.power_api",
                ),
                "present records cannot carry reasons",
            )

    def test_logical_cpu_count_must_be_positive(self):
        with self.assertRaisesRegex(observer.ObservationError, "at least 1"):
            observer._metric(  # noqa: SLF001
                "host_logical_cpu_count",
                "probe",
                "present",
                0,
                observer._runtime_provenance(  # noqa: SLF001
                    "Darwin",
                    "os.cpu_count",
                ),
            )

    def test_failed_probe_reason_never_retains_raw_output(self):
        secret = b"SECRET_RAW_PAYLOAD"

        def failed(argv, _timeout_seconds):
            return subprocess.CompletedProcess(
                argv,
                7,
                stdout=secret,
                stderr=secret,
            )

        result = observer._probe_command(  # noqa: SLF001
            (observer.PMSET, "-g", "batt"),
            1.0,
            failed,
        )
        self.assertEqual(result["availability"], "missing")
        self.assertNotIn(secret.decode("ascii"), str(result))
        source = result["provenance"]["sources"][0]
        self.assertEqual(
            source["stdout_sha256"],
            hashlib.sha256(secret).hexdigest(),
        )
        self.assertEqual(
            source["stderr_sha256"],
            hashlib.sha256(secret).hexdigest(),
        )

    def test_default_runner_enforces_output_bound_while_draining(self):
        completed = observer._default_command_runner(  # noqa: SLF001
            (
                sys.executable,
                "-c",
                "import sys; "
                "sys.stdout.buffer.write(b'x' * (2 * 1024 * 1024)); "
                "sys.stdout.buffer.flush()",
            ),
            5.0,
        )
        self.assertTrue(completed.glacier_output_exceeded)
        self.assertGreater(
            completed.glacier_stdout_bytes,
            observer.MAX_PROBE_OUTPUT_BYTES,
        )
        self.assertLessEqual(
            len(completed.stdout),
            observer.MAX_PROBE_OUTPUT_BYTES + 1,
        )

    def test_denied_probe_is_distinct_from_unsupported(self):
        def denied(_argv, _timeout_seconds):
            raise PermissionError("policy denied")

        snapshot = observer.capture_observation(
            "post-run",
            runner=denied,
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        for name in (
            "host_power_source",
            "host_thermal_constraint",
            "host_available_memory_bytes",
            "host_cpu_idle_ppm",
            "host_swap_used_bytes",
            "process_resident_bytes",
        ):
            metric = observer.metric_by_name(snapshot, name)
            self.assertEqual(metric["availability"], "denied")
            self.assertIsNone(metric["value"])

    def test_state_encodings_do_not_infer_missing_thermal(self):
        battery_runner = self._runner(
            {
                (observer.PMSET, "-g", "batt"): (
                    "Now drawing from 'Battery Power'\n"
                    " -InternalBattery-0\t70%; discharging; present: true\n"
                ),
                (observer.PMSET, "-g", "custom"): (
                    "Battery Power:\n lowpowermode 1\n"
                ),
                (observer.PMSET, "-g", "therm"): (
                    "Note: No thermal warning level has been recorded\n"
                ),
            }
        )
        snapshot = observer.capture_observation(
            "before",
            runner=battery_runner,
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        self.assertEqual(snapshot["phase"], "pre_run")
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_power_source")["value"],
            observer.POWER_SOURCE_BATTERY,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_low_power_mode")["value"],
            1,
        )
        thermal = observer.metric_by_name(
            snapshot, "host_thermal_constraint"
        )
        self.assertEqual(thermal["availability"], "missing")
        self.assertIsNone(thermal["value"])

        unknown_runner = self._runner(
            {
                (observer.PMSET, "-g", "batt"): (
                    "Now drawing from 'UPS Power'\n"
                ),
                (observer.PMSET, "-g", "custom"): (
                    "UPS Power:\n lowpowermode 0\n"
                ),
            }
        )
        unknown = observer.capture_observation(
            "after",
            runner=unknown_runner,
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        self.assertEqual(unknown["phase"], "post_run")
        self.assertEqual(
            observer.metric_by_name(unknown, "host_power_source")["value"],
            observer.POWER_SOURCE_UNKNOWN,
        )

    def test_malformed_probe_output_is_missing_not_zero(self):
        runner = self._runner(
            {
                (observer.PMSET, "-g", "batt"): (
                    "malformed battery source\n"
                ),
                (observer.VM_STAT,): "Pageouts: 0.\n",
                (
                    observer.TOP,
                    "-l",
                    "2",
                    "-s",
                    "1",
                    "-n",
                    "0",
                ): "not a top sample\n",
            }
        )
        snapshot = observer.capture_observation(
            "pre_run",
            runner=runner,
            system_name="Darwin",
            logical_cpu_count=8,
            process_id=4242,
        )
        for name in (
            "host_power_source",
            "host_low_power_mode",
            "host_available_memory_bytes",
            "host_cpu_busy_ppm",
            "host_cpu_idle_ppm",
        ):
            metric = observer.metric_by_name(snapshot, name)
            self.assertEqual(metric["availability"], "missing")
            self.assertIsNone(metric["value"])

    def test_non_darwin_capture_does_not_run_macos_commands(self):
        calls = []

        def unexpected(argv, _timeout_seconds):
            calls.append(list(argv))
            raise AssertionError("runner must not be called")

        snapshot = observer.capture_observation(
            "probe",
            runner=unexpected,
            system_name="Linux",
            logical_cpu_count=4,
        )
        self.assertEqual(calls, [])
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_logical_cpu_count")["value"],
            4,
        )
        self.assertEqual(
            observer.metric_by_name(snapshot, "host_power_source")[
                "availability"
            ],
            "unsupported",
        )

    @unittest.skipUnless(
        platform.system() == "Darwin",
        "native command probes are retained only on macOS",
    )
    def test_native_macos_smoke_retains_every_explicit_state(self):
        snapshot = observer.capture_observation("probe")
        self.assertEqual(snapshot["system"], "Darwin")
        self.assertEqual(
            len(snapshot["metrics"]),
            len(observer.METRIC_SPECS),
        )
        self.assertEqual(
            observer.metric_by_name(
                snapshot,
                "host_monotonic_time",
            )["availability"],
            "present",
        )
        self.assertEqual(
            observer.metric_by_name(
                snapshot,
                "host_logical_cpu_count",
            )["availability"],
            "present",
        )
        for metric in snapshot["metrics"]:
            self.assertIn(
                metric["availability"],
                observer.AVAILABILITIES,
            )
            if metric["availability"] == "present":
                self.assertIsInstance(metric["value"], int)
            else:
                self.assertIsNone(metric["value"])
                self.assertTrue(metric["reason"])

    def test_capture_bounds_and_parser_fail_closed(self):
        with self.assertRaisesRegex(observer.ObservationError, "phase"):
            observer.capture_observation("unknown")
        with self.assertRaisesRegex(observer.ObservationError, "top_iterations"):
            observer.capture_observation("probe", top_iterations=65)
        with self.assertRaisesRegex(observer.ObservationError, "window"):
            observer.capture_observation(
                "probe",
                top_iterations=64,
                sample_interval_seconds=2.0,
            )
        with self.assertRaisesRegex(observer.ObservationError, "Swapins"):
            observer.parse_vm_stat("Pageouts: 0.\n")
        with self.assertRaisesRegex(observer.ObservationError, "matched"):
            observer.parse_top_state("Load Avg: 0.2, 0.3, 0.4\n")

    def test_strict_parsers_preserve_existing_machine_state_shape(self):
        power = observer.parse_pmset_power(BATTERY, SETTINGS)
        expected_settings = {"lowpowermode": "0", "tcpkeepalive": "1"}
        expected_sha = hashlib.sha256(
            json.dumps(
                expected_settings, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        ).hexdigest()
        self.assertEqual(power["source"], "AC Power")
        self.assertTrue(power["battery_full"])
        self.assertEqual(power["low_power_mode"], 0)
        self.assertEqual(power["active_settings_sha256"], expected_sha)
        self.assertEqual(
            observer.parse_vm_stat(VM),
            {"pageouts": 10, "swapins": 20, "swapouts": 30},
        )
        self.assertEqual(
            observer.parse_top_state(TOP),
            ([0.2, 0.4], [97.0, 94.0]),
        )


if __name__ == "__main__":
    unittest.main()
