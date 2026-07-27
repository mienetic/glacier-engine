from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock

from bench import native_metal_workload_report as native
from bench.tests import test_native_workload_report as fixture


TEST_RUNNER_SHA256 = hashlib.sha256(
    b"native Metal workload report test runner/v1"
).digest()
TEST_METALLIB_SHA256 = hashlib.sha256(
    b"native Metal workload report test metallib/v1"
).digest()
TEST_BUILD_SHA256 = native._native_build_sha256(
    TEST_RUNNER_SHA256,
    TEST_METALLIB_SHA256,
)
TEST_CHALLENGE_SHA256 = hashlib.sha256(
    b"native Metal workload report test challenge/v1"
).digest()
FRESH_CHALLENGE_SHA256 = hashlib.sha256(
    b"native Metal workload report fresh challenge/v1"
).digest()


def _native_scenario(
    runner_sha256: bytes = TEST_RUNNER_SHA256,
    metallib_sha256: bytes = TEST_METALLIB_SHA256,
    challenge_sha256: bytes = TEST_CHALLENGE_SHA256,
) -> dict:
    build_sha256 = native._native_build_sha256(
        runner_sha256,
        metallib_sha256,
    )
    identities = [
        native.EXPECTED_WORKLOAD_SHA256,
        native.EXPECTED_PROFILE_SHA256,
        native.EXPECTED_ARTIFACT_SHA256,
        build_sha256,
        fixture._test_digest(41, 0),
        native.EXPECTED_BACKEND_SHA256,
        fixture._test_digest(42, 0),
        fixture._test_digest(43, 0),
        native.EXPECTED_HOST_SOURCE_SHA256,
        native.EXPECTED_HOST_CLOCK_SHA256,
        native.EXPECTED_DEVICE_SOURCE_SHA256,
        native.EXPECTED_DEVICE_CLOCK_SHA256,
        challenge_sha256,
    ]
    value = {
        "abi": fixture.SCENARIO_ABI,
        "mode": native.MODE_CLOSED,
        "evidence": native.EVIDENCE_PRODUCTION_NATIVE,
        "algorithm": 0,
        "warmup": native.EXPECTED_WARMUP_COUNT,
        "measured": native.EXPECTED_MEASURED_COUNT,
        "max_in_flight": native.EXPECTED_MAX_IN_FLIGHT,
        "queue_count": native.EXPECTED_QUEUE_COUNT,
        "flow_count": native.EXPECTED_FLOW_COUNT,
        "identities": identities,
    }
    value["sha"] = fixture._scenario_sha(value)
    return value


def _event_points(
    pair_index: int,
    second_lane: bool,
) -> tuple[list[int], list[int]]:
    base = 1 + pair_index * 16
    if second_lane:
        sequences = [
            base + 1,
            base + 3,
            base + 5,
            base + 7,
            base + 8,
            base + 10,
            base + 14,
        ]
    else:
        sequences = [
            base,
            base + 2,
            base + 4,
            base + 6,
            base + 9,
            base + 12,
            base + 15,
        ]
    return ([1_000_000 + value for value in sequences], sequences)


def _native_records(scenario: dict) -> list[dict]:
    records = []
    for ordinal in range(native.EXPECTED_RECORD_COUNT):
        lane = ordinal % native.EXPECTED_FLOW_COUNT
        pair = ordinal // native.EXPECTED_FLOW_COUNT
        timestamps, sequences = _event_points(pair, lane == 1)
        record = fixture._completed(
            scenario,
            ordinal,
            (
                native.COHORT_WARMUP
                if ordinal < native.EXPECTED_WARMUP_COUNT
                else native.COHORT_MEASURED
            ),
            lane,
            timestamps,
            sequences,
        )
        record["work_units"] = native.EXPECTED_WORK_UNITS
        record["maximum_error"] = fixture._f64_bits(1.0e-6)
        record["allocation"]["before"] = 8_192 + ordinal
        record["allocation"]["after"] = 8_192 + ordinal
        record["logical"] = [
            1,
            1,
            native.EXPECTED_LEASE_CHARGED_BYTES,
            native.EXPECTED_LEASE_CHARGED_BYTES,
            1,
            0,
            1,
            0,
            1,
            0,
        ]
        records.append(record)
    return records


def _native_fixture(
    scenario_mutator=None,
    records_mutator=None,
    runner_sha256: bytes = TEST_RUNNER_SHA256,
    metallib_sha256: bytes = TEST_METALLIB_SHA256,
    challenge_sha256: bytes = TEST_CHALLENGE_SHA256,
) -> bytes:
    scenario = _native_scenario(
        runner_sha256,
        metallib_sha256,
        challenge_sha256,
    )
    if scenario_mutator is not None:
        scenario_mutator(scenario)
        scenario["sha"] = fixture._scenario_sha(scenario)
    records = _native_records(scenario)
    if records_mutator is not None:
        records_mutator(records)
    fixture._seal_records(scenario, records)
    summary = fixture._summary(scenario, records)
    closure = fixture._closure(records)
    report_sha = fixture._hash(
        fixture.REPORT_DOMAIN,
        fixture._u64(fixture.REPORT_ABI),
        scenario["sha"],
        fixture._u32(len(records)),
        records[-1]["sha"],
        summary["sha"],
        closure["sha"],
    )
    body = b"".join(
        (
            fixture._encode_scenario(scenario),
            *(fixture._encode_record(record) for record in records),
            fixture._encode_summary(summary),
            fixture._encode_closure(closure),
            report_sha,
        )
    )
    length = (
        fixture.HEADER_BYTES + len(body) + fixture.WIRE_DIGEST_BYTES
    )
    header = b"".join(
        (
            fixture.MAGIC,
            fixture._u64(fixture.WIRE_ABI),
            fixture._u64(length),
            fixture._u32(1),
            b"\x00" * 4,
            fixture._u32(len(records)),
            b"\x00" * 4,
        )
    )
    body_digest = fixture._hash(fixture.BODY_DOMAIN, body)
    prefix = header + body + body_digest
    return prefix + fixture._hash(fixture.FOOTER_DOMAIN, prefix)


class NativeMetalWorkloadReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.encoded = _native_fixture()

    def assertProfileRejected(self, encoded: bytes) -> None:
        with self.assertRaises(native.NativeMetalReportError):
            native.verify_native_wire(
                encoded,
                TEST_RUNNER_SHA256,
                TEST_METALLIB_SHA256,
                TEST_CHALLENGE_SHA256,
            )

    def test_exact_production_profile_verifies(self) -> None:
        self.assertEqual(
            len(self.encoded),
            native.EXPECTED_WIRE_BYTES,
        )
        result = native.verify_native_wire(
            self.encoded,
            TEST_RUNNER_SHA256,
            TEST_METALLIB_SHA256,
            TEST_CHALLENGE_SHA256,
        )
        self.assertEqual(result.record_count, 20)
        self.assertEqual(result.warmup_count, 4)
        self.assertEqual(result.measured_count, 16)
        self.assertEqual(
            result.wire_sha256,
            hashlib.sha256(self.encoded).digest(),
        )
        self.assertEqual(result.runner_sha256, TEST_RUNNER_SHA256)
        self.assertEqual(result.metallib_sha256, TEST_METALLIB_SHA256)

    def test_profile_rejects_synthetic_or_foreign_build_identity(self) -> None:
        def synthetic(scenario: dict) -> None:
            scenario["evidence"] = 0

        def foreign_build(scenario: dict) -> None:
            scenario["identities"][3] = fixture._test_digest(99, 1)

        for mutator in (synthetic, foreign_build):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _native_fixture(scenario_mutator=mutator)
                )

    def test_profile_rejects_invariant_identity_drift(self) -> None:
        for identity_index in (0, 1, 2, 5, 8, 9, 10, 11):
            def mutate(
                scenario: dict,
                index: int = identity_index,
            ) -> None:
                scenario["identities"][index] = fixture._test_digest(
                    90,
                    index,
                )

            with self.subTest(identity_index=identity_index):
                self.assertProfileRejected(
                    _native_fixture(scenario_mutator=mutate)
                )

    def test_profile_rejects_dynamic_identity_alias_or_zero(self) -> None:
        def zero_machine(scenario: dict) -> None:
            scenario["identities"][4] = bytes(32)

        def alias_device_and_placement(scenario: dict) -> None:
            scenario["identities"][7] = scenario["identities"][6]

        for mutator in (zero_machine, alias_device_and_placement):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _native_fixture(scenario_mutator=mutator)
                )

    def test_build_identity_binds_abi_runner_and_metallib(self) -> None:
        expected = hashlib.sha256(
            b"".join(
                (
                    b"glacier-w6-metal-native-build-v1\x00",
                    fixture._u64(native.PRODUCER_ABI),
                    TEST_RUNNER_SHA256,
                    TEST_METALLIB_SHA256,
                )
            )
        ).digest()
        self.assertEqual(TEST_BUILD_SHA256, expected)
        self.assertNotEqual(
            native._native_build_sha256(
                fixture._test_digest(97, 0),
                TEST_METALLIB_SHA256,
            ),
            expected,
        )
        self.assertNotEqual(
            native._native_build_sha256(
                TEST_RUNNER_SHA256,
                fixture._test_digest(97, 1),
            ),
            expected,
        )

    def test_profile_rejects_stale_component_or_challenge(self) -> None:
        for expected_runner, expected_metallib, expected_challenge in (
            (
                fixture._test_digest(98, 0),
                TEST_METALLIB_SHA256,
                TEST_CHALLENGE_SHA256,
            ),
            (
                TEST_RUNNER_SHA256,
                fixture._test_digest(98, 1),
                TEST_CHALLENGE_SHA256,
            ),
            (
                TEST_RUNNER_SHA256,
                TEST_METALLIB_SHA256,
                FRESH_CHALLENGE_SHA256,
            ),
        ):
            with self.subTest(
                expected_runner=expected_runner,
                expected_metallib=expected_metallib,
                expected_challenge=expected_challenge,
            ):
                with self.assertRaises(native.NativeMetalReportError):
                    native.verify_native_wire(
                        self.encoded,
                        expected_runner,
                        expected_metallib,
                        expected_challenge,
                    )

    def test_profile_rejects_geometry_lease_fallback_and_error_drift(
        self,
    ) -> None:
        def work_units(records: list[dict]) -> None:
            records[7]["work_units"] += 1

        def lease_bytes(records: list[dict]) -> None:
            records[7]["logical"][2] += 1
            records[7]["logical"][3] += 1

        def fallback(records: list[dict]) -> None:
            records[7]["fallback"] = True

        def numerical_error(records: list[dict]) -> None:
            records[7]["maximum_error"] = fixture._f64_bits(3.0e-5)

        for mutator in (
            work_units,
            lease_bytes,
            fallback,
            numerical_error,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _native_fixture(records_mutator=mutator)
                )

    def test_profile_rejects_lane_order_pairing_and_generation_drift(
        self,
    ) -> None:
        def wrong_lane(records: list[dict]) -> None:
            records[8]["flow_id"] = 1
            records[8]["queue"] = 1

        def wrong_settlement_order(records: list[dict]) -> None:
            first = records[8]
            second = records[9]
            first_ns, first_sequence = first["points"][6]
            second_ns, second_sequence = second["points"][6]
            first["points"][6] = (second_ns, second_sequence)
            second["points"][6] = (first_ns, first_sequence)

        def reused_ticket_root(records: list[dict]) -> None:
            records[8]["roots"][1] = records[0]["roots"][1]

        for mutator in (
            wrong_lane,
            wrong_settlement_order,
            reused_ticket_root,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _native_fixture(records_mutator=mutator)
                )

    def test_generic_wire_rejection_happens_before_profile_acceptance(
        self,
    ) -> None:
        for encoded in (self.encoded[:-1], self.encoded + b"\x00"):
            with self.subTest(length=len(encoded)):
                self.assertProfileRejected(encoded)
        mutated = bytearray(self.encoded)
        mutated[len(mutated) // 2] ^= 1
        self.assertProfileRejected(bytes(mutated))

    def test_oversized_stdout_and_stderr_are_stopped_while_streaming(
        self,
    ) -> None:
        for descriptor, maximum in (
            (1, native.MAX_STDOUT_BYTES),
            (2, native.MAX_STDERR_BYTES),
        ):
            with self.subTest(descriptor=descriptor):
                source = (
                    "import os\n"
                    "data = b'x' * %d\n"
                    "view = memoryview(data)\n"
                    "while view:\n"
                    "    view = view[os.write(%d, view):]\n"
                    % (maximum + 1, descriptor)
                )
                started = time.monotonic()
                with self.assertRaises(native.NativeMetalReportError):
                    native._bounded_runner_output(
                        [sys.executable, "-c", source],
                        timeout_seconds=2.0,
                    )
                self.assertLess(time.monotonic() - started, 2.0)

    def test_timeout_terminates_runner_process_group(self) -> None:
        source = (
            "import subprocess, sys, time\n"
            "subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(10)'])\n"
            "time.sleep(10)\n"
        )
        started = time.monotonic()
        with self.assertRaises(native.NativeMetalReportError):
            native._bounded_runner_output(
                [sys.executable, "-c", source],
                timeout_seconds=0.05,
            )
        self.assertLess(time.monotonic() - started, 2.0)

    def test_nonfinite_timeout_rejected_before_spawn(self) -> None:
        for timeout in (float("nan"), float("inf"), float("-inf"), 0):
            with self.subTest(timeout=timeout):
                with mock.patch.object(native.subprocess, "Popen") as popen:
                    with self.assertRaises(native.NativeMetalReportError):
                        native._bounded_runner_output(
                            ["unused"],
                            timeout_seconds=timeout,
                        )
                popen.assert_not_called()

    def test_runner_receives_only_lowercase_exact_challenge(self) -> None:
        source = (
            "import os, sys\n"
            "sys.stdout.write(os.environ[%r])\n"
            % native.CHALLENGE_ENVIRONMENT
        )
        returncode, stdout, stderr = native._bounded_runner_output(
            [sys.executable, "-c", source],
            timeout_seconds=2.0,
            challenge_sha256=TEST_CHALLENGE_SHA256,
        )
        self.assertEqual(returncode, 0)
        self.assertEqual(stdout, TEST_CHALLENGE_SHA256.hex().encode("ascii"))
        self.assertEqual(stderr, b"")

    def test_verified_artifact_is_written_atomically(self) -> None:
        result = native.verify_native_wire(
            self.encoded,
            TEST_RUNNER_SHA256,
            TEST_METALLIB_SHA256,
            TEST_CHALLENGE_SHA256,
        )
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "report.gw6"
            retained = native._write_retained_artifact(
                target,
                self.encoded,
            )
            self.assertEqual(retained, target)
            self.assertEqual(target.read_bytes(), self.encoded)
            self.assertEqual(
                hashlib.sha256(target.read_bytes()).digest(),
                result.wire_sha256,
            )
            self.assertEqual(
                list(Path(directory).glob(".report.gw6.*.tmp")),
                [],
            )

    def test_runner_is_zero_argument_and_retains_only_after_validation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = root / "runner.py"
            metallib = root / "shaders.metallib"
            target = root / "report.gw6"
            metallib.write_bytes(b"fixture metallib")
            runner.write_text(
                "#!%s\n"
                "import base64, sys\n"
                "sys.stdout.buffer.write(base64.b64decode(%r))\n"
                % (
                    sys.executable,
                    __import__("base64").b64encode(self.encoded),
                ),
                encoding="ascii",
            )
            os.chmod(runner, 0o700)
            with mock.patch.object(
                native.os,
                "urandom",
                return_value=TEST_CHALLENGE_SHA256,
            ), mock.patch.object(
                native,
                "_runner_file_sha256",
                return_value=TEST_RUNNER_SHA256,
            ), mock.patch.object(
                native,
                "_metallib_file_sha256",
                return_value=TEST_METALLIB_SHA256,
            ):
                result = native.verify_runner(runner, metallib, target)
            self.assertEqual(result.retained_path, target)
            self.assertEqual(target.read_bytes(), self.encoded)
            self.assertEqual(result.runner_sha256, TEST_RUNNER_SHA256)
            self.assertEqual(result.metallib_sha256, TEST_METALLIB_SHA256)

            bad_runner = root / "bad.py"
            bad_runner.write_text(
                "#!%s\nimport sys\nsys.stdout.buffer.write(b'bad')\n"
                % sys.executable,
                encoding="ascii",
            )
            os.chmod(bad_runner, 0o700)
            untouched = b"previous"
            target.write_bytes(untouched)
            with mock.patch.object(
                native.os,
                "urandom",
                return_value=TEST_CHALLENGE_SHA256,
            ), mock.patch.object(
                native,
                "_runner_file_sha256",
                return_value=TEST_RUNNER_SHA256,
            ), mock.patch.object(
                native,
                "_metallib_file_sha256",
                return_value=TEST_METALLIB_SHA256,
            ), self.assertRaises(native.NativeMetalReportError):
                native.verify_runner(bad_runner, metallib, target)
            self.assertEqual(target.read_bytes(), untouched)

    def test_runner_rejects_stale_replay_or_component_replacement(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = root / "runner.py"
            metallib = root / "shaders.metallib"
            metallib.write_bytes(b"fixture metallib")
            runner.write_text(
                "#!%s\n"
                "import base64, sys\n"
                "sys.stdout.buffer.write(base64.b64decode(%r))\n"
                % (
                    sys.executable,
                    __import__("base64").b64encode(self.encoded),
                ),
                encoding="ascii",
            )
            os.chmod(runner, 0o700)

            with mock.patch.object(
                native.os,
                "urandom",
                return_value=FRESH_CHALLENGE_SHA256,
            ), mock.patch.object(
                native,
                "_runner_file_sha256",
                return_value=TEST_RUNNER_SHA256,
            ), mock.patch.object(
                native,
                "_metallib_file_sha256",
                return_value=TEST_METALLIB_SHA256,
            ), self.assertRaises(native.NativeMetalReportError):
                native.verify_runner(runner, metallib)

            replaced_runner = fixture._test_digest(99, 2)
            with mock.patch.object(
                native.os,
                "urandom",
                return_value=TEST_CHALLENGE_SHA256,
            ), mock.patch.object(
                native,
                "_runner_file_sha256",
                side_effect=(TEST_RUNNER_SHA256, replaced_runner),
            ), mock.patch.object(
                native,
                "_metallib_file_sha256",
                return_value=TEST_METALLIB_SHA256,
            ), self.assertRaises(native.NativeMetalReportError):
                native.verify_runner(runner, metallib)

            replaced_metallib = fixture._test_digest(99, 3)
            with mock.patch.object(
                native.os,
                "urandom",
                return_value=TEST_CHALLENGE_SHA256,
            ), mock.patch.object(
                native,
                "_runner_file_sha256",
                return_value=TEST_RUNNER_SHA256,
            ), mock.patch.object(
                native,
                "_metallib_file_sha256",
                side_effect=(
                    TEST_METALLIB_SHA256,
                    replaced_metallib,
                ),
            ), self.assertRaises(native.NativeMetalReportError):
                native.verify_runner(runner, metallib)

    def test_cli_contract_uses_runner_and_optional_output(self) -> None:
        verification = native.NativeVerificationResult(
            20,
            4,
            16,
            bytes(range(32)),
            bytes(reversed(range(32))),
            TEST_RUNNER_SHA256,
            TEST_METALLIB_SHA256,
            Path("report.gw6"),
        )
        output = io.StringIO()
        with mock.patch.object(
            native,
            "verify_runner",
            return_value=verification,
        ) as verify_runner, redirect_stdout(output):
            self.assertEqual(
                native._main(
                    [
                        "--runner",
                        "fixture-runner",
                        "--metallib",
                        "fixture-metallib",
                        "--output",
                        "report.gw6",
                    ]
                ),
                0,
            )
        verify_runner.assert_called_once_with(
            "fixture-runner",
            "fixture-metallib",
            "report.gw6",
        )
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(
            lines[0].startswith("ok native-metal-workload-report-v1 ")
        )
        self.assertIn(
            "runner_sha256=%s" % TEST_RUNNER_SHA256.hex(),
            lines[0],
        )
        self.assertIn(
            "metallib_sha256=%s" % TEST_METALLIB_SHA256.hex(),
            lines[0],
        )

    def test_retained_native_capture_matches_manifest(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        results = repository / "bench" / "results"
        artifact_path = (
            results
            / "native-metal-workload-report-macos-arm64-2026-07-28.bin"
        )
        manifest_path = (
            results
            / "native-metal-workload-report-macos-arm64-2026-07-28.manifest.json"
        )
        wire = artifact_path.read_bytes()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(
            manifest["schema"],
            "glacier.native-metal-workload-capture/v1",
        )
        self.assertFalse(manifest["performance_claim"])
        self.assertTrue(manifest["source"]["tree_clean_before_capture"])

        decoded = native._decode_after_portable_verification(wire)
        challenge_sha256 = decoded.scenario.identities[12]
        runner_sha256 = bytes.fromhex(
            manifest["build"]["runner"]["sha256"]
        )
        metallib_sha256 = bytes.fromhex(
            manifest["build"]["metallib"]["sha256"]
        )
        verified = native.verify_native_wire(
            wire,
            runner_sha256,
            metallib_sha256,
            challenge_sha256,
        )
        artifact = manifest["artifact"]
        self.assertEqual(len(wire), artifact["bytes"])
        self.assertEqual(
            verified.wire_sha256.hex(),
            artifact["wire_sha256"],
        )
        self.assertEqual(
            verified.report_sha256.hex(),
            artifact["report_sha256"],
        )
        self.assertEqual(
            decoded.scenario.scenario_sha256.hex(),
            artifact["scenario_sha256"],
        )
        self.assertEqual(wire[-64:-32].hex(), artifact["body_wire_sha256"])
        self.assertEqual(wire[-32:].hex(), artifact["footer_wire_sha256"])

        identity_names = (
            "workload",
            "profile",
            "artifact",
            "build",
            "machine",
            "backend",
            "device",
            "placement",
            "host_source",
            "host_clock",
            "device_source",
            "device_clock",
            "challenge",
        )
        self.assertEqual(
            {
                name: value.hex()
                for name, value in zip(
                    identity_names,
                    decoded.scenario.identities,
                )
            },
            manifest["scenario_identities"],
        )
        for path_key, digest_key in (
            ("portable_path", "portable_source_sha256"),
            ("native_profile_path", "native_profile_source_sha256"),
            ("producer_path", "producer_source_sha256"),
            ("runner_source_path", "runner_source_sha256"),
        ):
            source_path = Path(manifest["verifier"][path_key])
            self.assertFalse(source_path.is_absolute())
            self.assertNotIn("..", source_path.parts)
            source_sha256 = bytes.fromhex(
                manifest["verifier"][digest_key]
            )
            self.assertEqual(len(source_sha256), 32)
            self.assertNotEqual(source_sha256, bytes(32))


if __name__ == "__main__":
    unittest.main()
