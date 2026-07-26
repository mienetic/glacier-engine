from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest

from bench import native_metal_readiness as readiness


class NativeMetalReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.report = readiness.make_test_report()

    def _refresh_dispatch(self, report: dict[str, object]) -> None:
        report["dispatch_receipt_sha256"] = (
            readiness.dispatch_receipt_sha256(report)
        )
        report["diagnostic_dispatch_receipt_sha256"] = report[
            "dispatch_receipt_sha256"
        ]
        self._refresh_diagnostic(report)

    def _refresh_diagnostic(self, report: dict[str, object]) -> None:
        report["report_sha256"] = readiness.diagnostic_report_sha256(report)

    def _run_python(self, source: str, timeout: float = 2.0) -> None:
        with self.assertRaises(readiness.ReadinessError):
            readiness.run_runner(
                [sys.executable, "-c", source],
                timeout_seconds=timeout,
            )

    def test_valid_report(self) -> None:
        readiness.validate_report(self.report)

    def test_macos_v1_schema_is_exactly_87_fields(self) -> None:
        self.assertEqual(len(readiness.REPORT_FIELDS), 87)
        self.assertNotIn(
            "device_current_allocated_size",
            readiness.REPORT_FIELDS,
        )
        for field in (
            "workload_evidence_abi",
            "max_abs_error_bits",
            "live_weights_before",
            "workload_live_weights_after",
            "completed_dispatches_before",
            "completed_dispatches_after",
            "oracle_output_sha256",
            "correctness_sha256",
            "ownership_sha256",
        ):
            self.assertIn(field, readiness.REPORT_FIELDS)

    def test_cross_language_hashes_match_literal_golden_vectors(self) -> None:
        expected = {
            "device": (
                "be9c2378b9196e721d2a36ffad2bb32c8fba0d582b15056c582778a302fc4c79"
            ),
            "placement": (
                "aba47510afd1734e37f5982b57f9369a6bba4bf6cac99a799a1aff6ba53b0b0a"
            ),
            "machine": (
                "ba06a19e2181e936fffaa13c63b92c5e2f1a1c2dc5363d153bd4cfb27896a61a"
            ),
            "dispatch": (
                "c2863e80a14afbe53c7b9f41fe937a56163459ba641eb8f25c18fba83753b94d"
            ),
            "diagnostic": (
                "5f6d06fbfc0245a75a607a79b96db278b98bb785da8b421b4d13e9ca188eecd4"
            ),
            "correctness": (
                "64089fd31d454ecce9509fc924b1ed052d487fbb5bb809ad79413acb08151d79"
            ),
            "ownership": (
                "5121d8ce71343a7fb8e3e6d035e09275b537955b39c19667e15cbec0e0b76a3a"
            ),
        }
        actual = {
            "device": readiness.device_identity_sha256(self.report),
            "placement": readiness.placement_identity_sha256(self.report),
            "machine": readiness.machine_identity_sha256(self.report),
            "dispatch": readiness.dispatch_receipt_sha256(self.report),
            "diagnostic": readiness.diagnostic_report_sha256(self.report),
            "correctness": readiness.correctness_sha256(self.report),
            "ownership": readiness.ownership_sha256(self.report),
        }
        self.assertEqual(actual, expected)

    def test_canonical_fixture_identities_are_literal_and_immutable(self) -> None:
        expected = {
            "workload_profile_sha256": (
                "a1691691219ec553d28d58ac39f33a65017d3260d940b438aace52c86eaf99c3"
            ),
            "artifact_sha256": (
                "9ee185ded4aeeac487ca406ecae81d68935148cfde73df71cfd878fdaf66ec82"
            ),
            "build_sha256": (
                "bd0389d07ff127c70355a0bd7c8856e99082fb990a4f977ea31f513f57d53b26"
            ),
            "backend_sha256": (
                "14cf39adceb28668e532854cfbada5d8592254ea25fc8e9ba036b9ab104b6b4a"
            ),
            "challenge_sha256": (
                "9c49f428550922edde0c5c3d41169c6c69c09ab6deb69f89fe9d1f00b02f05f0"
            ),
            "oracle_output_sha256": (
                "d7b9092893a9d7eef234474531202509f2884dedf8ba956166a93b2bd2fb909a"
            ),
        }
        for field, value in expected.items():
            with self.subTest(field=field):
                self.assertEqual(self.report[field], value)
                report = copy.deepcopy(self.report)
                report[field] = report["output_sha256"]
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_valid_runner_output(self) -> None:
        encoded = json.dumps(self.report, separators=(",", ":"))
        actual = readiness.run_runner(
            [
                sys.executable,
                "-c",
                "import sys; print(sys.argv[1])",
                encoded,
            ]
        )
        self.assertEqual(actual, self.report)

    def test_exact_field_set_rejects_missing_and_unknown(self) -> None:
        for mutation in ("missing", "unknown"):
            with self.subTest(mutation=mutation):
                report = copy.deepcopy(self.report)
                if mutation == "missing":
                    del report["machine_sha256"]
                else:
                    report["unexpected"] = 1
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_duplicate_keys_rejected_at_every_object_depth(self) -> None:
        encoded = json.dumps(self.report, separators=(",", ":"))
        duplicate_top = (
            '{"schema":"duplicate",' + encoded.removeprefix("{")
        ).encode("utf-8")
        duplicate_nested = b'{"unknown":{"key":1,"key":2}}'
        for payload in (duplicate_top, duplicate_nested):
            with self.subTest(payload=payload[:32]):
                with self.assertRaises(readiness.ReadinessError):
                    readiness._parse_report(payload)

    def test_nonstandard_json_numbers_rejected(self) -> None:
        for value in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(value=value):
                with self.assertRaises(readiness.ReadinessError):
                    readiness._parse_report(
                        ('{"value":' + value + "}").encode("ascii")
                    )

    def test_json_integer_digit_bound_is_python39_safe(self) -> None:
        value = "9" * (readiness.MAX_JSON_INTEGER_DIGITS + 1)
        with self.assertRaises(readiness.ReadinessError):
            readiness._parse_report(
                ('{"value":' + value + "}").encode("ascii")
            )

    def test_sha256_requires_strict_lowercase_ascii(self) -> None:
        invalid = (
            "ab" * 31 + "  ",
            "g" * 64,
            "A" * 64,
            "é" * 64,
            "0" * 64,
        )
        for value in invalid:
            with self.subTest(value=value[:8]):
                report = copy.deepcopy(self.report)
                report["output_sha256"] = value
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_performance_claim_rejected(self) -> None:
        report = copy.deepcopy(self.report)
        report["performance_claim"] = True
        with self.assertRaises(readiness.ReadinessError):
            readiness.validate_report(report)

    def test_workload_semantics_fail_closed(self) -> None:
        for field, value in (
            ("decision", "nonpublishable"),
            ("workload_status", "failed"),
            ("correctness", "failed"),
            ("zero_orphans", "failed"),
            ("fallback", "present"),
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = value
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_zero_nan_infinite_or_reversed_gpu_time_rejected(self) -> None:
        start = self.report["gpu_start_time_bits"]
        invalid = (
            ("gpu_duration_nanoseconds", 0),
            ("gpu_end_time_bits", start),
            (
                "gpu_start_time_bits",
                struct.unpack("<Q", struct.pack("<d", float("nan")))[0],
            ),
            (
                "gpu_end_time_bits",
                struct.unpack("<Q", struct.pack("<d", float("inf")))[0],
            ),
            (
                "gpu_end_time_bits",
                struct.unpack("<Q", struct.pack("<d", 1.0e308))[0],
            ),
        )
        for field, value in invalid:
            with self.subTest(field=field, value=value):
                report = copy.deepcopy(self.report)
                report[field] = value
                self._refresh_dispatch(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_device_substitution_rejected_with_outer_roots_recomputed(
        self,
    ) -> None:
        report = copy.deepcopy(self.report)
        report["device_registry_id"] += 1
        report["dispatch_device_registry_id"] += 1
        report["diagnostic_device_registry_id"] += 1
        # Rehashing both outer receipts is not enough: the verifier derives
        # device and placement identities independently from fixed-width data.
        self._refresh_dispatch(report)
        with self.assertRaises(readiness.ReadinessError):
            readiness.validate_report(report)

    def test_device_and_placement_alias_substitution_rejected(self) -> None:
        for field in (
            "receipt_device_sha256",
            "diagnostic_device_sha256",
            "receipt_placement_sha256",
            "diagnostic_placement_sha256",
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = report["artifact_sha256"]
                self._refresh_diagnostic(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_registry_aliases_must_bind_to_raw_device(self) -> None:
        for field in (
            "dispatch_device_registry_id",
            "diagnostic_device_registry_id",
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] += 1
                self._refresh_dispatch(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_machine_root_binds_cpu_count_and_device(self) -> None:
        report = copy.deepcopy(self.report)
        report["logical_cpu_count"] += 1
        self._refresh_diagnostic(report)
        with self.assertRaises(readiness.ReadinessError):
            readiness.validate_report(report)

    def test_descriptor_plan_and_evidence_aliases_must_match(self) -> None:
        for field in (
            "plan_descriptor_sha256",
            "report_descriptor_sha256",
            "diagnostic_descriptor_sha256",
            "report_plan_sha256",
            "diagnostic_plan_sha256",
            "diagnostic_probe_bundle_sha256",
            "diagnostic_pre_run_bundle_sha256",
            "diagnostic_post_run_bundle_sha256",
            "report_workload_receipt_sha256",
            "diagnostic_workload_receipt_sha256",
            "diagnostic_run_report_sha256",
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = report["artifact_sha256"]
                self._refresh_diagnostic(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_dispatch_root_substitution_rejected(self) -> None:
        report = copy.deepcopy(self.report)
        report["current_allocated_after"] += 1
        self._refresh_diagnostic(report)
        with self.assertRaises(readiness.ReadinessError):
            readiness.validate_report(report)

    def test_allocation_samples_must_be_nonzero(self) -> None:
        for field in ("current_allocated_before", "current_allocated_after"):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = 0
                self._refresh_dispatch(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_command_status_and_ordinal_are_exact(self) -> None:
        for field, value in (
            ("command_status", 3),
            ("dispatch_ordinal", 2),
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = value
                self._refresh_dispatch(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_workload_evidence_semantics_and_hashes_fail_closed(self) -> None:
        for field, value, refresh in (
            (
                "workload_evidence_abi",
                readiness.WORKLOAD_EVIDENCE_ABI + 1,
                None,
            ),
            (
                "max_abs_error_bits",
                struct.unpack("<I", struct.pack("<f", float("nan")))[0],
                None,
            ),
            ("live_weights_before", 1, "ownership"),
            ("workload_live_weights_after", 1, "ownership"),
            ("completed_dispatches_before", 1, "ownership"),
            ("completed_dispatches_after", 2, "ownership"),
            (
                "correctness_sha256",
                self.report["artifact_sha256"],
                None,
            ),
            (
                "ownership_sha256",
                self.report["artifact_sha256"],
                None,
            ),
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = value
                if refresh == "ownership":
                    report["ownership_sha256"] = readiness.ownership_sha256(
                        report
                    )
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_workload_cardinality_is_exact(self) -> None:
        for field, value in (
            ("workload_invocations", 2),
            ("profile_count", 0),
            ("item_count", 2),
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = value
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_reason_accounting_and_metric_sets_are_exact(self) -> None:
        for field, value in (
            ("missing_observation_count", 1),
            ("unsupported_observation_count", 23),
            ("unavailable_reason_count", 25),
            ("present_reason_count", 1),
            ("direct_metric_bits", 0),
            ("unsupported_metric_bits", 0),
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = value
                self._refresh_diagnostic(report)
                with self.assertRaises(readiness.ReadinessError):
                    readiness.validate_report(report)

    def test_fake_supported_metric_rejected(self) -> None:
        report = copy.deepcopy(self.report)
        report["unsupported_metrics"].remove(
            "accelerator_resident_bytes"
        )
        with self.assertRaises(readiness.ReadinessError):
            readiness.validate_report(report)

    def test_oversized_stdout_and_stderr_are_stopped_while_streaming(
        self,
    ) -> None:
        size = readiness.MAX_RUNNER_OUTPUT_BYTES + 1
        for descriptor in (1, 2):
            with self.subTest(descriptor=descriptor):
                source = (
                    "import os\n"
                    f"data = b'x' * {size}\n"
                    f"view = memoryview(data)\n"
                    f"fd = {descriptor}\n"
                    "while view:\n"
                    "    view = view[os.write(fd, view):]\n"
                )
                started = time.monotonic()
                self._run_python(source)
                self.assertLess(time.monotonic() - started, 2.0)

    def test_timeout_terminates_runner_process_group(self) -> None:
        source = (
            "import subprocess, sys, time\n"
            "subprocess.Popen([sys.executable, '-c', 'import time; "
            "time.sleep(10)'])\n"
            "time.sleep(10)\n"
        )
        started = time.monotonic()
        self._run_python(source, timeout=0.05)
        self.assertLess(time.monotonic() - started, 2.0)

    def test_nonfinite_runner_timeout_rejected_before_spawn(self) -> None:
        for timeout in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(timeout=timeout):
                with self.assertRaises(readiness.ReadinessError):
                    readiness.run_runner(
                        [sys.executable, "-c", "raise SystemExit(99)"],
                        timeout_seconds=timeout,
                    )

    def test_temp_executable_stdout_and_stderr_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for stream in ("stdout", "stderr"):
                with self.subTest(stream=stream):
                    script = Path(directory) / f"oversized_{stream}.py"
                    script.write_text(
                        "import sys\n"
                        f"sys.{stream}.buffer.write(b'x' * "
                        f"{readiness.MAX_RUNNER_OUTPUT_BYTES + 1})\n",
                        encoding="utf-8",
                    )
                    os.chmod(script, 0o700)
                    with self.assertRaises(readiness.ReadinessError):
                        readiness.run_runner([sys.executable, str(script)])


if __name__ == "__main__":
    unittest.main()
