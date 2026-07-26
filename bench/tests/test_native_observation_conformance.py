from __future__ import annotations

import copy
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from bench import native_observation_conformance as oracle


class NativeObservationHashTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.artifacts = oracle.reference_artifacts()
        cls.report = oracle.build_report()

    def test_reference_contract_is_reconstructed_field_by_field(self) -> None:
        self.assertEqual(tuple(self.artifacts["descriptor"]), oracle.DESCRIPTOR_FIELDS)
        self.assertEqual(tuple(self.artifacts["plan"]), oracle.PLAN_FIELDS)
        self.assertEqual(tuple(self.artifacts["probe"]), oracle.BUNDLE_FIELDS)
        self.assertEqual(tuple(self.artifacts["receipt"]), oracle.RECEIPT_FIELDS)
        self.assertEqual(
            tuple(self.artifacts["run_report"]),
            oracle.RUN_REPORT_FIELDS,
        )
        self.assertEqual(
            tuple(self.artifacts["reference_report"]),
            oracle.REFERENCE_FIELDS,
        )
        self.assertEqual(tuple(self.report), oracle.REPORT_FIELDS)
        self.assertEqual("publishable", self.report["decision"])
        self.assertEqual(3, self.report["profile_count"])
        self.assertEqual(6, self.report["item_count"])
        self.assertEqual(1_600, self.report["elapsed_nanoseconds"])
        self.assertEqual(
            list(oracle.AVAILABILITY_NAMES),
            self.report["availability"],
        )

    def test_every_hash_recomputes_from_its_canonical_fields(self) -> None:
        descriptor = self.artifacts["descriptor"]
        plan = self.artifacts["plan"]
        self.assertEqual(
            descriptor["descriptor_sha256"],
            oracle.descriptor_sha256(descriptor),
        )
        for rule in plan["rules"]:
            self.assertEqual(rule["rule_sha256"], oracle.rule_sha256(rule))
        self.assertEqual(plan["run_sha256"], oracle.run_sha256(plan))
        self.assertEqual(plan["plan_sha256"], oracle.plan_sha256(plan))
        for bundle_name in ("probe", "pre_run", "post_run"):
            bundle = self.artifacts[bundle_name]
            for record in bundle["records"]:
                self.assertEqual(
                    record["observation_sha256"],
                    oracle.observation_sha256(record),
                )
            self.assertEqual(
                bundle["records_sha256"],
                oracle.observation_section_sha256(bundle["records"]),
            )
            self.assertEqual(
                bundle["bundle_sha256"],
                oracle.bundle_sha256(bundle),
            )
        receipt = self.artifacts["receipt"]
        self.assertEqual(
            receipt["receipt_sha256"],
            oracle.workload_receipt_sha256(receipt),
        )
        run_report = self.artifacts["run_report"]
        self.assertEqual(
            run_report["report_sha256"],
            oracle.run_report_sha256(run_report),
        )
        reference = self.artifacts["reference_report"]
        self.assertEqual(
            reference["report_sha256"],
            oracle.reference_report_sha256(reference),
        )

    def test_all_four_availability_states_are_explicit(self) -> None:
        descriptor = self.artifacts["descriptor"]
        plan = self.artifacts["plan"]
        roots: set[bytes] = set()
        for availability in (
            oracle.AVAILABILITY_PRESENT,
            oracle.AVAILABILITY_MISSING,
            oracle.AVAILABILITY_DENIED,
            oracle.AVAILABILITY_UNSUPPORTED,
        ):
            with self.subTest(availability=availability):
                record = oracle.make_observation(
                    descriptor,
                    plan,
                    oracle.PHASE_PRE_RUN,
                    1,
                    oracle.METRIC_HOST_LOGICAL_CPU_COUNT,
                    availability,
                    8 if availability == oracle.AVAILABILITY_PRESENT else 0,
                    100,
                    oracle.digest_v1("availability clock"),
                    oracle.ZERO_DIGEST,
                    oracle.digest_v1("availability source"),
                    oracle.digest_v1("availability provenance"),
                    oracle.digest_v1("availability subject"),
                    oracle.ZERO_DIGEST
                    if availability == oracle.AVAILABILITY_PRESENT
                    else oracle.digest_v1(
                        f"availability reason {availability}"
                    ),
                )
                self.assertEqual(availability, record["availability"])
                roots.add(record["observation_sha256"])
        self.assertEqual(4, len(roots))
        with self.assertRaises(oracle.NativeObservationError):
            oracle.make_observation(
                descriptor,
                plan,
                oracle.PHASE_PRE_RUN,
                1,
                oracle.METRIC_HOST_LOGICAL_CPU_COUNT,
                oracle.AVAILABILITY_MISSING,
                8,
                100,
                oracle.digest_v1("availability clock"),
                oracle.ZERO_DIGEST,
                oracle.digest_v1("availability source"),
                oracle.digest_v1("availability provenance"),
                oracle.digest_v1("availability subject"),
                oracle.digest_v1("availability missing reason"),
            )

    def test_sample_and_value_clock_domains_are_distinct(self) -> None:
        descriptor = self.artifacts["descriptor"]
        plan = self.artifacts["plan"]
        pre_run = self.artifacts["pre_run"]
        time_record = pre_run["records"][0]
        cpu_record = pre_run["records"][1]
        host_clock = oracle.digest_v1("reference host clock")
        self.assertEqual(
            host_clock,
            time_record["sample_clock_domain_sha256"],
        )
        self.assertEqual(
            host_clock,
            time_record["value_clock_domain_sha256"],
        )
        for record in pre_run["records"][1:]:
            self.assertEqual(
                host_clock,
                record["sample_clock_domain_sha256"],
            )
            self.assertEqual(
                oracle.ZERO_DIGEST,
                record["value_clock_domain_sha256"],
            )

        invalid_time = copy.deepcopy(time_record)
        invalid_time["value_clock_domain_sha256"] = oracle.ZERO_DIGEST
        invalid_time["observation_sha256"] = oracle.observation_sha256(
            invalid_time
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_observation(descriptor, plan, invalid_time)

        invalid_non_time = copy.deepcopy(cpu_record)
        invalid_non_time["value_clock_domain_sha256"] = host_clock
        invalid_non_time["observation_sha256"] = oracle.observation_sha256(
            invalid_non_time
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_observation(descriptor, plan, invalid_non_time)

        unavailable_time = copy.deepcopy(time_record)
        unavailable_time["availability"] = oracle.AVAILABILITY_MISSING
        unavailable_time["value"] = 0
        unavailable_time["observation_sha256"] = oracle.observation_sha256(
            unavailable_time
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_observation(descriptor, plan, unavailable_time)

        missing_sample_clock = copy.deepcopy(cpu_record)
        missing_sample_clock["sample_clock_domain_sha256"] = oracle.ZERO_DIGEST
        missing_sample_clock["observation_sha256"] = (
            oracle.observation_sha256(missing_sample_clock)
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_observation(
                descriptor,
                plan,
                missing_sample_clock,
            )

    def test_source_provenance_and_unavailable_reason_are_bound(self) -> None:
        descriptor = self.artifacts["descriptor"]
        plan = self.artifacts["plan"]
        expected_source = oracle.digest_v1(
            "reference host observer source"
        )
        expected_provenance = {
            "probe": oracle.digest_v1(
                "reference host probe provenance"
            ),
            "pre_run": oracle.digest_v1(
                "reference host pre-run provenance"
            ),
            "post_run": oracle.digest_v1(
                "reference host post-run provenance"
            ),
        }
        observed_provenance: set[bytes] = set()
        for bundle_name in ("probe", "pre_run", "post_run"):
            bundle = self.artifacts[bundle_name]
            for record in bundle["records"]:
                self.assertEqual(expected_source, record["source_sha256"])
                self.assertEqual(
                    expected_provenance[bundle_name],
                    record["provenance_sha256"],
                )
                observed_provenance.add(record["provenance_sha256"])
                if record["availability"] == oracle.AVAILABILITY_PRESENT:
                    self.assertEqual(
                        oracle.ZERO_DIGEST,
                        record["reason_sha256"],
                    )
        self.assertEqual(3, len(observed_provenance))

        temperature = next(
            record
            for record in self.artifacts["pre_run"]["records"]
            if record["metric"] == oracle.METRIC_HOST_CPU_TEMPERATURE
        )
        power = next(
            record
            for record in self.artifacts["pre_run"]["records"]
            if record["metric"] == oracle.METRIC_HOST_CPU_POWER
        )
        self.assertEqual(
            oracle.digest_v1(
                "reference host temperature permission denied"
            ),
            temperature["reason_sha256"],
        )
        self.assertEqual(
            oracle.digest_v1("reference host power unsupported"),
            power["reason_sha256"],
        )

        present_with_reason = copy.deepcopy(
            self.artifacts["pre_run"]["records"][0]
        )
        present_with_reason["reason_sha256"] = oracle.digest_v1(
            "invalid present reason"
        )
        present_with_reason["observation_sha256"] = (
            oracle.observation_sha256(present_with_reason)
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_observation(
                descriptor,
                plan,
                present_with_reason,
            )

        unavailable_without_reason = copy.deepcopy(temperature)
        unavailable_without_reason["reason_sha256"] = oracle.ZERO_DIGEST
        unavailable_without_reason["observation_sha256"] = (
            oracle.observation_sha256(unavailable_without_reason)
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_observation(
                descriptor,
                plan,
                unavailable_without_reason,
            )

    def test_metric_specific_numeric_domains_are_enforced(self) -> None:
        descriptor = copy.deepcopy(self.artifacts["descriptor"])
        descriptor["direct_metric_bits"] |= oracle.metric_bit(
            oracle.METRIC_HOST_CPU_TEMPERATURE
        )
        descriptor["direct_metric_bits"] |= oracle.metric_bit(
            oracle.METRIC_ACCELERATOR_TEMPERATURE
        )
        descriptor["descriptor_sha256"] = oracle.descriptor_sha256(
            descriptor
        )
        plan = copy.deepcopy(self.artifacts["plan"])
        plan["observer_descriptor_sha256"] = descriptor[
            "descriptor_sha256"
        ]
        plan["run_sha256"] = oracle.run_sha256(plan)
        plan["plan_sha256"] = oracle.plan_sha256(plan)
        oracle.validate_plan(descriptor, plan)

        for metric in (
            oracle.METRIC_HOST_CPU_TEMPERATURE,
            oracle.METRIC_ACCELERATOR_TEMPERATURE,
        ):
            with self.subTest(metric=metric, boundary="valid"):
                record = oracle.make_observation(
                    descriptor,
                    plan,
                    oracle.PHASE_PRE_RUN,
                    1,
                    metric,
                    oracle.AVAILABILITY_PRESENT,
                    -273_150,
                    100,
                    oracle.digest_v1("numeric sample clock"),
                    oracle.ZERO_DIGEST,
                    oracle.digest_v1("numeric source"),
                    oracle.digest_v1("numeric provenance"),
                    oracle.digest_v1("numeric subject"),
                    oracle.ZERO_DIGEST,
                )
                self.assertEqual(-273_150, record["value"])
            with self.subTest(metric=metric, boundary="invalid"):
                with self.assertRaises(oracle.NativeObservationError):
                    oracle.make_observation(
                        descriptor,
                        plan,
                        oracle.PHASE_PRE_RUN,
                        1,
                        metric,
                        oracle.AVAILABILITY_PRESENT,
                        -273_151,
                        100,
                        oracle.digest_v1("numeric sample clock"),
                        oracle.ZERO_DIGEST,
                        oracle.digest_v1("numeric source"),
                        oracle.digest_v1("numeric provenance"),
                        oracle.digest_v1("numeric subject"),
                        oracle.ZERO_DIGEST,
                    )

        with self.assertRaises(oracle.NativeObservationError):
            oracle.make_observation(
                descriptor,
                plan,
                oracle.PHASE_PRE_RUN,
                1,
                oracle.METRIC_HOST_LOGICAL_CPU_COUNT,
                oracle.AVAILABILITY_PRESENT,
                0,
                100,
                oracle.digest_v1("numeric sample clock"),
                oracle.ZERO_DIGEST,
                oracle.digest_v1("numeric source"),
                oracle.digest_v1("numeric provenance"),
                oracle.digest_v1("numeric subject"),
                oracle.ZERO_DIGEST,
            )

    def test_malformed_overflow_and_substitution_fail_closed(self) -> None:
        malformed = copy.deepcopy(self.artifacts["descriptor"])
        del malformed["observer_epoch"]
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_descriptor(malformed)

        unknown_metric = copy.deepcopy(self.artifacts["descriptor"])
        unknown_metric["declared_metric_bits"] |= 1 << 63
        unknown_metric["descriptor_sha256"] = oracle.descriptor_sha256(
            unknown_metric
        )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_descriptor(unknown_metric)

        with self.assertRaises(oracle.NativeObservationError):
            oracle.make_rule(
                oracle.METRIC_HOST_LOGICAL_CPU_COUNT,
                oracle.SCOPE_PRE_RUN,
                oracle.PREDICATE_INCLUSIVE_RANGE,
                oracle.I64_MIN,
                oracle.I64_MAX + 1,
            )

        with self.assertRaises(oracle.NativeObservationError):
            oracle.make_observation(
                self.artifacts["descriptor"],
                self.artifacts["plan"],
                oracle.PHASE_PRE_RUN,
                oracle.U64_MAX + 1,
                oracle.METRIC_HOST_LOGICAL_CPU_COUNT,
                oracle.AVAILABILITY_PRESENT,
                8,
                100,
                oracle.digest_v1("overflow clock"),
                oracle.ZERO_DIGEST,
                oracle.digest_v1("overflow source"),
                oracle.digest_v1("overflow provenance"),
                oracle.digest_v1("overflow subject"),
                oracle.ZERO_DIGEST,
            )
        with self.assertRaises(oracle.NativeObservationError):
            oracle.make_observation(
                self.artifacts["descriptor"],
                self.artifacts["plan"],
                oracle.PHASE_PRE_RUN,
                1,
                oracle.METRIC_HOST_MONOTONIC_TIME,
                oracle.AVAILABILITY_PRESENT,
                -1,
                100,
                oracle.digest_v1("negative clock"),
                oracle.digest_v1("negative clock"),
                oracle.digest_v1("negative source"),
                oracle.digest_v1("negative provenance"),
                oracle.digest_v1("negative subject"),
                oracle.ZERO_DIGEST,
            )

        substituted = copy.deepcopy(self.artifacts["pre_run"])
        substituted["records"][0]["subject_sha256"] = oracle.digest_v1(
            "foreign host"
        )
        substituted["records_sha256"] = oracle.observation_section_sha256(
            substituted["records"]
        )
        substituted["bundle_sha256"] = oracle.bundle_sha256(substituted)
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_bundle(
                self.artifacts["descriptor"],
                self.artifacts["plan"],
                substituted,
            )

        reordered = copy.deepcopy(self.artifacts["plan"])
        reordered["rules"][0], reordered["rules"][1] = (
            reordered["rules"][1],
            reordered["rules"][0],
        )
        reordered["plan_sha256"] = oracle.plan_sha256(reordered)
        with self.assertRaises(oracle.NativeObservationError):
            oracle.validate_plan(self.artifacts["descriptor"], reordered)

    def test_plan_requires_the_host_observation_baseline(self) -> None:
        descriptor = self.artifacts["descriptor"]
        plan = self.artifacts["plan"]
        baseline_rule_indexes = (0, 1, 2, 3)
        for removed_index in baseline_rule_indexes:
            with self.subTest(removed_index=removed_index):
                missing_gate = copy.deepcopy(plan)
                del missing_gate["rules"][removed_index]
                missing_gate["plan_sha256"] = oracle.plan_sha256(
                    missing_gate
                )
                with self.assertRaisesRegex(
                    oracle.NativeObservationError,
                    "mandatory host observation baseline",
                ):
                    oracle.validate_plan(descriptor, missing_gate)

        narrowed = copy.deepcopy(descriptor)
        narrowed["direct_metric_bits"] &= ~oracle.metric_bit(
            oracle.METRIC_HOST_LOGICAL_CPU_COUNT
        )
        narrowed["descriptor_sha256"] = oracle.descriptor_sha256(narrowed)
        narrowed_plan = copy.deepcopy(plan)
        narrowed_plan["observer_descriptor_sha256"] = narrowed[
            "descriptor_sha256"
        ]
        narrowed_plan["run_sha256"] = oracle.run_sha256(narrowed_plan)
        narrowed_plan["plan_sha256"] = oracle.plan_sha256(narrowed_plan)
        with self.assertRaisesRegex(
            oracle.NativeObservationError,
            "mandatory host observation baseline",
        ):
            oracle.validate_plan(narrowed, narrowed_plan)

        require_present_only = copy.deepcopy(plan)
        require_present_only["rules"][2] = oracle.make_rule(
            oracle.METRIC_HOST_LOGICAL_CPU_COUNT,
            oracle.SCOPE_PRE_RUN,
            oracle.PREDICATE_REQUIRE_PRESENT,
        )
        require_present_only["plan_sha256"] = oracle.plan_sha256(
            require_present_only
        )
        with self.assertRaisesRegex(
            oracle.NativeObservationError,
            "mandatory host observation baseline",
        ):
            oracle.validate_plan(descriptor, require_present_only)

    def test_accelerator_plan_requires_direct_placement_gates(self) -> None:
        descriptor = self.artifacts["descriptor"]
        plan = self.artifacts["plan"]
        ungated = oracle.make_plan
        with self.assertRaisesRegex(
            oracle.NativeObservationError,
            "placement gates",
        ):
            ungated(
                descriptor,
                plan["workload_profile_sha256"],
                plan["artifact_sha256"],
                plan["build_sha256"],
                plan["machine_sha256"],
                plan["backend_sha256"],
                plan["device_sha256"],
                plan["placement_sha256"],
                oracle.EXECUTION_ACCELERATOR,
                plan["worker_count"],
                plan["queue_count"],
                plan["rules"],
                plan["challenge_sha256"],
            )


class NativeObservationCanonicalJsonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = oracle.build_report()
        cls.encoded = oracle.render_report(cls.report).encode("ascii")

    def test_exact_compact_ascii_line_round_trips(self) -> None:
        self.assertEqual(
            self.report,
            oracle.load_json_exact(self.encoded, "reference"),
        )
        self.assertEqual(self.report, oracle.validate_report(self.report))

    def test_noncanonical_json_is_rejected(self) -> None:
        duplicate = self.encoded.replace(
            b'{"schema":',
            b'{"schema":"substituted","schema":',
            1,
        )
        pretty = (json.dumps(self.report, indent=2) + "\n").encode("ascii")
        invalid = (
            self.encoded[:-1],
            self.encoded + b"\n",
            b"\n" + self.encoded,
            pretty,
            duplicate,
            self.encoded.replace(b'"profile_count":3', b'"profile_count":3.0'),
            self.encoded.replace(b'"profile_count":3', b'"profile_count":03'),
            self.encoded.replace(b'"publishable"', b'"\\u0070ublishable"'),
            b'["not","an","object"]\n',
            b"",
        )
        for encoded in invalid:
            with self.subTest(encoded=encoded[:80]):
                with self.assertRaises(oracle.NativeObservationError):
                    oracle.load_json_exact(encoded, "invalid")

    def test_semantic_root_substitution_is_rejected(self) -> None:
        for field in (
            "descriptor_sha256",
            "plan_sha256",
            "probe_bundle_sha256",
            "pre_run_bundle_sha256",
            "post_run_bundle_sha256",
            "workload_receipt_sha256",
            "run_report_sha256",
            "workload_result_sha256",
            "report_sha256",
        ):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.report)
                changed[field] = "0" * 64
                with self.assertRaises(oracle.NativeObservationError):
                    oracle.validate_report(changed)

    def test_retained_fixture_is_exact_if_present(self) -> None:
        fixture = (
            Path(__file__).resolve().parents[1]
            / "results"
            / "native-observation-conformance-v1.json"
        )
        if not fixture.exists():
            self.skipTest("retained fixture has not been generated yet")
        self.assertEqual(self.encoded, fixture.read_bytes())
        self.assertEqual(
            self.report,
            oracle.validate_report(
                oracle.load_json_exact(fixture.read_bytes(), "fixture")
            ),
        )


class NativeObservationRunnerTests(unittest.TestCase):
    def test_runner_fixture_and_cli_require_exact_output(self) -> None:
        expected = oracle.render_report().encode("ascii")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "fixture.json"
            runner = root / "runner.py"
            oracle.write_report(fixture)

            def install_runner(
                stdout: bytes,
                *,
                stderr: bytes = b"",
                returncode: int = 0,
            ) -> None:
                runner.write_text(
                    "#!/usr/bin/env python3\n"
                    "import sys\n"
                    f"sys.stdout.buffer.write({stdout!r})\n"
                    f"sys.stderr.buffer.write({stderr!r})\n"
                    f"raise SystemExit({returncode})\n",
                    encoding="ascii",
                )
                runner.chmod(0o755)

            install_runner(expected)
            oracle.verify_runner([sys.executable, str(runner)], fixture)
            self.assertEqual(
                0,
                oracle.main(
                    [
                        "--runner",
                        str(runner),
                        "--fixture",
                        str(fixture),
                    ]
                ),
            )

            substituted = oracle.build_report()
            substituted["report_sha256"] = "0" * 64
            install_runner(oracle.render_report(substituted).encode("ascii"))
            with self.assertRaisesRegex(
                oracle.NativeObservationError,
                "contradicts Python oracle",
            ):
                oracle.verify_runner([sys.executable, str(runner)], fixture)

            install_runner(expected, stderr=b"unexpected")
            with self.assertRaisesRegex(
                oracle.NativeObservationError,
                "runner failed",
            ):
                oracle.verify_runner([sys.executable, str(runner)], fixture)

            fixture.write_bytes(b"{}\n")
            with self.assertRaisesRegex(
                oracle.NativeObservationError,
                "fixture is stale",
            ):
                oracle.verify_runner([sys.executable, str(runner)], fixture)
            with redirect_stderr(io.StringIO()):
                self.assertEqual(
                    2,
                    oracle.main(
                        [
                            "--runner",
                            str(runner),
                            "--fixture",
                            str(fixture),
                        ]
                    ),
                )
            with self.assertRaises(oracle.NativeObservationError):
                oracle.verify_runner([], fixture)

    def test_actual_zig_runner_if_supplied(self) -> None:
        runner_value = os.environ.get("GLACIER_NATIVE_OBSERVATION_RUNNER")
        if not runner_value:
            self.skipTest("GLACIER_NATIVE_OBSERVATION_RUNNER is not set")
        fixture = (
            Path(__file__).resolve().parents[1]
            / "results"
            / "native-observation-conformance-v1.json"
        )
        oracle.verify_runner(Path(runner_value), fixture)


if __name__ == "__main__":
    unittest.main()
