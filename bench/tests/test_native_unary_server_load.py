from __future__ import annotations

from dataclasses import replace
import hashlib
import os
import struct
import sys
import unittest
from unittest import mock

from bench import native_unary_server_load as load


def _seal_structural_outer() -> bytes:
    sidecars = []
    for ordinal in range(load.RECORD_COUNT):
        sidecars.append(
            load.SIDECAR_STRUCT.pack(
                ordinal,
                0,
                *([0] * 11),
                0,
                0,
                0,
                0,
                0,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
            )
        )
    body = (
        b"".join(sidecars)
        + b"\x00" * load.CLOSURE_BYTES
        + b"\x00" * load.INNER_BYTES
    )
    header = load.HEADER_STRUCT.pack(
        load.MAGIC,
        load.OUTER_ABI,
        load.OUTER_BYTES,
        load.RECORD_COUNT,
        load.SIDECAR_BYTES,
        load.CLOSURE_BYTES,
        load.INNER_BYTES,
    )
    body_digest = load._domain_hash(load.BODY_DOMAIN, body)
    prefix = header + body + body_digest
    return prefix + load._domain_hash(load.FOOTER_DOMAIN, prefix)


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _valid_closure() -> tuple[int, ...]:
    return (
        72,
        72,
        0,
        72,
        72,
        8,
        2,
        3,
        3,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        72,
        72,
        0,
        0,
        0,
        1,
        1,
        1,
        0,
        216,
    )


def _profile_fixture() -> tuple[
    tuple[load.Sidecar, ...],
    tuple[int, ...],
    load.InnerProfile,
    bytes,
    bytes,
    bytes,
]:
    build = _digest("build")
    machine = _digest("machine")
    challenge = _digest("challenge")
    sidecars = []
    records = []
    for ordinal in range(load.RECORD_COUNT):
        base = 1_000 + ordinal * 100
        request = _digest("request-%d" % ordinal)
        handle = _digest("handle-%d" % ordinal)
        output = _digest("output-%d" % ordinal)
        terminal = _digest("terminal-%d" % ordinal)
        completion = _digest("completion-%d" % ordinal)
        sidecar = load.Sidecar(
            ordinal=ordinal,
            response_bytes=512,
            enqueue_ordinal=ordinal * 3 + 1,
            dispatch_ordinal=ordinal * 3 + 2,
            retired_ordinal=ordinal * 3 + 3,
            enqueue_ns=base + 1,
            dispatch_ns=base + 2,
            published_ns=base + 3,
            retired_ns=base + 7,
            work_sequence=ordinal + 1,
            process_generation=load.PROCESS_GENERATION,
            connection_sequence=ordinal + 1,
            slot_generation=ordinal // load.QUEUE_COUNT + 1,
            slot_index=ordinal % load.QUEUE_COUNT,
            worker_index=ordinal % load.WORKER_COUNT,
            content_byte=65,
            output_token=65,
            request_sha256=request,
            response_handle_sha256=handle,
            handle_sha256=handle,
            output_sha256=output,
            terminal_sha256=terminal,
            completion_sha256=completion,
        )
        pin = load._pin_root(sidecar)
        roots = (
            request,
            handle,
            pin,
            load._dispatch_root(sidecar, pin),
            load._submission_root(sidecar, pin),
            output,
            load._oracle_root(sidecar),
            terminal,
            completion,
        )
        points = (
            (base, ordinal * 7 + 1),
            (base + 1, ordinal * 7 + 2),
            (base + 2, ordinal * 7 + 3),
            (base + 3, ordinal * 7 + 4),
            (base + 4, ordinal * 7 + 5),
            (base + 5, ordinal * 7 + 6),
            (base + 7, ordinal * 7 + 7),
        )
        records.append(
            load.InnerRecord(
                ordinal=ordinal,
                cohort=0 if ordinal < load.WARMUP_COUNT else 1,
                outcome=0,
                correctness=1,
                fallback=0,
                flow_id=ordinal % load.FLOW_COUNT,
                work_units=1,
                queue_slot=sidecar.slot_index,
                presence_mask=0x7F,
                points=points,
                roots=roots,
            )
        )
        sidecars.append(sidecar)
    identities = (
        load._identity(load.WORKLOAD_ID),
        load._identity(load.PROFILE_ID),
        _digest("artifact"),
        build,
        machine,
        load._identity(load.BACKEND_ID),
        load._identity(load.DEVICE_ID),
        load._identity(load.PLACEMENT_ID),
        load._identity(load.HOST_SOURCE_ID),
        load._host_clock_identity("Darwin"),
        load._identity(load.DEVICE_SOURCE_ID),
        load._identity(load.DEVICE_CLOCK_ID),
        challenge,
    )
    profile = load.InnerProfile(
        mode=0,
        evidence=1,
        warmup_count=load.WARMUP_COUNT,
        measured_count=load.MEASURED_COUNT,
        max_in_flight=load.FLOW_COUNT,
        queue_count=load.QUEUE_COUNT,
        flow_count=load.FLOW_COUNT,
        identities=identities,
        records=tuple(records),
        completed_work_units=load.MEASURED_COUNT,
        interval_ns=7_000,
        throughput_numerator=load.MEASURED_COUNT,
        throughput_denominator_ns=7_000,
        admission_p99_ns=1,
        queue_p99_ns=1,
        first_byte_p99_ns=4,
        terminal_p99_ns=5,
    )
    return (
        tuple(sidecars),
        _valid_closure(),
        profile,
        build,
        machine,
        challenge,
    )


def _observation(
    *,
    busy: int,
    external: int,
    thermal_availability: str = "missing",
    thermal_value: int | None = None,
) -> dict:
    values = {
        "host_logical_cpu_count": ("present", 8),
        "host_cpu_busy_ppm": ("present", busy),
        "host_external_cpu_ppm": ("present", external),
        "host_power_source": ("present", 1),
        "host_low_power_mode": ("present", 0),
        "host_thermal_constraint": (
            thermal_availability,
            thermal_value,
        ),
    }
    return {
        "claim_scope": "native-observation-only",
        "system": "Darwin",
        "adapter": load.native_observer.ADAPTER,
        "metrics": [
            {
                "name": name,
                "availability": availability,
                "value": value,
            }
            for name, (availability, value) in values.items()
        ],
    }


class NativeUnaryServerLoadTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "bounded capture is POSIX-only")
    def test_process_capture_cleans_up_when_selector_setup_fails(self) -> None:
        environment = {"LC_ALL": "C", "PATH": os.defpath}
        real_popen = load.subprocess.Popen

        class RegisterFailingSelector:
            def __init__(self, fail_on_register: int) -> None:
                self.fail_on_register = fail_on_register
                self.register_count = 0
                self.closed = False

            def register(self, *args: object, **kwargs: object) -> None:
                _ = args
                _ = kwargs
                self.register_count += 1
                if self.register_count == self.fail_on_register:
                    raise OSError("injected selector register failure")

            def close(self) -> None:
                self.closed = True

        for failure in (
            "constructor",
            "first_register",
            "second_register",
        ):
            with self.subTest(failure=failure):
                spawned: list[load.subprocess.Popen[bytes]] = []
                failing_selector: RegisterFailingSelector | None = None

                def recording_popen(
                    *args: object,
                    **kwargs: object,
                ) -> load.subprocess.Popen[bytes]:
                    process = real_popen(*args, **kwargs)
                    spawned.append(process)
                    return process

                if failure == "constructor":
                    def selector_factory() -> load.selectors.BaseSelector:
                        raise OSError(
                            "injected selector constructor failure"
                        )
                else:
                    def selector_factory() -> RegisterFailingSelector:
                        nonlocal failing_selector
                        failing_selector = RegisterFailingSelector(
                            1 if failure == "first_register" else 2
                        )
                        return failing_selector

                with mock.patch.object(
                    load.subprocess,
                    "Popen",
                    side_effect=recording_popen,
                ), mock.patch.object(
                    load.selectors,
                    "DefaultSelector",
                    side_effect=selector_factory,
                ):
                    with self.assertRaisesRegex(
                        OSError,
                        "injected selector",
                    ):
                        load._bounded_capture(
                            [
                                sys.executable,
                                "-c",
                                "import time; time.sleep(60)",
                            ],
                            stdout_limit=16,
                            stderr_limit=16,
                            timeout_seconds=5.0,
                            env=environment,
                        )

                self.assertEqual(len(spawned), 1)
                self.assertIsNotNone(spawned[0].poll())
                self.assertIsNotNone(spawned[0].stdout)
                self.assertIsNotNone(spawned[0].stderr)
                self.assertTrue(spawned[0].stdout.closed)
                self.assertTrue(spawned[0].stderr.closed)
                if failing_selector is not None:
                    self.assertEqual(
                        failing_selector.register_count,
                        failing_selector.fail_on_register,
                    )
                    self.assertTrue(failing_selector.closed)

    @unittest.skipUnless(os.name == "posix", "bounded capture is POSIX-only")
    def test_process_capture_enforces_bounds_while_child_is_live(self) -> None:
        environment = {"LC_ALL": "C", "PATH": os.defpath}
        returncode, stdout, stderr = load._bounded_capture(
            [
                sys.executable,
                "-c",
                "import os; os.write(1, b'good'); os.write(2, b'ok')",
            ],
            stdout_limit=4,
            stderr_limit=2,
            timeout_seconds=5.0,
            env=environment,
        )
        self.assertEqual(returncode, 0)
        self.assertEqual(stdout, b"good")
        self.assertEqual(stderr, b"ok")

        for label, descriptor in (("stdout", 1), ("stderr", 2)):
            with self.subTest(label=label):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "producer %s exceeded the fixed bound" % label,
                ):
                    load._bounded_capture(
                        [
                            sys.executable,
                            "-c",
                            "import os; os.write(%d, b'x' * 17)"
                            % descriptor,
                        ],
                        stdout_limit=16,
                        stderr_limit=16,
                        timeout_seconds=5.0,
                        env=environment,
                    )

        with self.assertRaisesRegex(
            load.VerificationError,
            "producer stdout exceeded the fixed bound",
        ):
            load._bounded_capture(
                [
                    sys.executable,
                    "-c",
                    (
                        "import os\n"
                        "while True:\n"
                        " os.write(1, b'x' * 4096)"
                    ),
                ],
                stdout_limit=1024,
                stderr_limit=16,
                timeout_seconds=5.0,
                env=environment,
            )

    def test_fixed_layout_is_exact_and_outer_digests_bind_regions(self) -> None:
        self.assertEqual(load.SIDECAR_STRUCT.size, load.SIDECAR_BYTES)
        self.assertEqual(load.HEADER_STRUCT.size, load.HEADER_BYTES)
        encoded = _seal_structural_outer()
        sidecars, closure, inner = load._parse_outer(encoded)
        self.assertEqual(len(encoded), load.OUTER_BYTES)
        self.assertEqual(len(sidecars), load.RECORD_COUNT)
        self.assertEqual(len(closure), load.CLOSURE_U64_COUNT)
        self.assertEqual(len(inner), load.INNER_BYTES)

        for offset in (
            0,
            8,
            load.HEADER_BYTES,
            load.HEADER_BYTES + load.SIDECAR_BYTES,
            load.HEADER_BYTES
            + load.RECORD_COUNT * load.SIDECAR_BYTES,
            len(encoded) - 65,
            len(encoded) - 1,
        ):
            mutated = bytearray(encoded)
            mutated[offset] ^= 1
            with self.subTest(offset=offset):
                with self.assertRaises(load.VerificationError):
                    load._parse_outer(bytes(mutated))

    def test_profile_composes_transport_roots_and_exact_closure(self) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture()
        )
        load._verify_profile(
            sidecars,
            closure,
            profile,
            expected_build=build,
            expected_machine=machine,
            expected_challenge=challenge,
            system="Darwin",
        )

        corrupted_sidecars = list(sidecars)
        corrupted_sidecars[9] = replace(
            corrupted_sidecars[9],
            published_ns=corrupted_sidecars[9].published_ns + 1,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "publication timestamp mismatch",
        ):
            load._verify_profile(
                tuple(corrupted_sidecars),
                closure,
                profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
            )

        mismatched_handles = list(sidecars)
        mismatched_handles[10] = replace(
            mismatched_handles[10],
            response_handle_sha256=_digest("forged-response-handle"),
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "HTTP response handle/work handle mismatch",
        ):
            load._verify_profile(
                tuple(mismatched_handles),
                closure,
                profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
            )

        for root_index in (3, 5, 7, 8):
            corrupted_records = list(profile.records)
            roots = list(corrupted_records[11].roots)
            roots[root_index] = _digest("forged-root-%d" % root_index)
            corrupted_records[11] = replace(
                corrupted_records[11],
                roots=tuple(roots),
            )
            with self.subTest(root_index=root_index):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "transport root composition mismatch",
                ):
                    load._verify_profile(
                        sidecars,
                        closure,
                        replace(profile, records=tuple(corrupted_records)),
                        expected_build=build,
                        expected_machine=machine,
                        expected_challenge=challenge,
                        system="Darwin",
                    )

    def test_closure_rejects_each_material_class(self) -> None:
        valid = _valid_closure()
        load._verify_closure(valid)
        for index in (0, 2, 5, 6, 8, 9, 13, 18, 20, 23, 25, 26, 27):
            mutated = list(valid)
            mutated[index] = 0 if index == 27 else 99
            with self.subTest(index=index):
                with self.assertRaises(load.VerificationError):
                    load._verify_closure(tuple(mutated))

    def test_cpu_boundaries_require_stability_but_retain_eligibility(self) -> None:
        before = _observation(busy=300_000, external=150_000)
        after = _observation(busy=360_000, external=170_000)
        result = load._validate_native_boundaries(
            before,
            after,
            system="Darwin",
        )
        self.assertTrue(result["cpu_load_observation_available"])
        self.assertTrue(result["cpu_publication_eligible"])

        noisier = _observation(busy=360_000, external=240_000)
        result = load._validate_native_boundaries(
            before,
            noisier,
            system="Darwin",
        )
        self.assertFalse(result["cpu_publication_eligible"])

        unstable = _observation(busy=700_000, external=350_001)
        with self.assertRaises(load.VerificationError):
            load._validate_native_boundaries(
                before,
                unstable,
                system="Darwin",
            )

    def test_present_thermal_constraint_must_be_nominal(self) -> None:
        nominal = _observation(
            busy=300_000,
            external=100_000,
            thermal_availability="present",
            thermal_value=0,
        )
        constrained = _observation(
            busy=300_000,
            external=100_000,
            thermal_availability="present",
            thermal_value=1,
        )
        load._validate_native_boundaries(
            nominal,
            nominal,
            system="Darwin",
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "thermal state is constrained",
        ):
            load._validate_native_boundaries(
                nominal,
                constrained,
                system="Darwin",
            )


if __name__ == "__main__":
    unittest.main()
