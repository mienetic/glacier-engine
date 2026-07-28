from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

from bench import native_metal_inflight_process_kill_report as report
from bench import native_metal_workload_report as w6
from bench.tests import test_native_metal_workload_report as w6_fixture
from bench.tests import test_native_workload_report as portable_fixture


READY_ABI = 0x4757_494B_0000_0001
KILL_ABI = 0x4757_494B_0000_0002
REPORT_ABI = 0x4757_4952_0000_0001
READY_BYTES = 512
KILL_BYTES = 256
HEADER_BYTES = 640
W6_BYTES = 17_996
REPORT_BYTES = 19_468
PID = 42_424

READY_DOMAIN = b"glacier-w7b-b4-metal-inflight-ready-frame-v1\x00"
KILL_DOMAIN = b"glacier-w7b-b4-metal-inflight-kill-receipt-v1\x00"
HEADER_DOMAIN = b"glacier-w7b-b4-metal-inflight-report-header-v1\x00"
BODY_DOMAIN = b"glacier-w7b-b4-metal-inflight-report-body-v1\x00"
ROOT_DOMAIN = b"glacier-w7b-b4-metal-inflight-report-root-v1\x00"
SCHEDULE_DOMAIN = b"glacier-w7b-b4-metal-inflight-schedule-v1\x00"
COMPONENT_DOMAIN = b"glacier-w7b-b4-metal-inflight-component-set-v1\x00"
VICTIM_CHALLENGE_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-victim-challenge-v1\x00"
)
RECOVERY_CHALLENGE_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-recovery-challenge-v1\x00"
)
VICTIM_BUILD_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-victim-build-v1\x00"
)
VICTIM_BACKEND_DOMAIN = (
    b"glacier-w7b-b4-metal-inflight-backend-v1\x00"
)

VICTIM_SHA256 = hashlib.sha256(b"w7b-b4 fixture victim/v1").digest()
VICTIM_METALLIB_SHA256 = hashlib.sha256(
    b"w7b-b4 fixture victim metallib/v1"
).digest()
RECOVERY_RUNNER_SHA256 = w6_fixture.TEST_RUNNER_SHA256
RECOVERY_METALLIB_SHA256 = w6_fixture.TEST_METALLIB_SHA256
CAMPAIGN_SHA256 = hashlib.sha256(b"w7b-b4 fixture campaign/v1").digest()
MACHINE_SHA256 = portable_fixture._test_digest(41, 0)
DEVICE_SHA256 = portable_fixture._test_digest(42, 0)
PLACEMENT_SHA256 = portable_fixture._test_digest(43, 0)
TICKET_SHA256 = hashlib.sha256(b"w7b-b4 ticket/v1").digest()
PIN_SHA256 = hashlib.sha256(b"w7b-b4 pin/v1").digest()
SUBMISSION_SHA256 = hashlib.sha256(b"w7b-b4 submission/v1").digest()


def _u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def _sha(*parts: bytes) -> bytes:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
    return digest.digest()


SCHEDULE_TUPLE = (
    REPORT_ABI,
    READY_ABI,
    KILL_ABI,
    HEADER_BYTES,
    READY_BYTES,
    KILL_BYTES,
    W6_BYTES,
    1,
    1,
    1,
    20,
    20,
    47_360,
    2,
    2,
    1,
    1,
    2,
    4,
    1,
    4,
)
SCHEDULE_SHA256 = _sha(
    SCHEDULE_DOMAIN,
    *(_u64(value) for value in SCHEDULE_TUPLE),
)


def _component_set(
    victim_sha256: bytes = VICTIM_SHA256,
    victim_metallib_sha256: bytes = VICTIM_METALLIB_SHA256,
    recovery_runner_sha256: bytes = RECOVERY_RUNNER_SHA256,
    recovery_metallib_sha256: bytes = RECOVERY_METALLIB_SHA256,
) -> bytes:
    return _sha(
        COMPONENT_DOMAIN,
        victim_sha256,
        victim_metallib_sha256,
        recovery_runner_sha256,
        recovery_metallib_sha256,
    )


def _victim_challenge(
    campaign_sha256: bytes,
    component_set_sha256: bytes,
) -> bytes:
    return _sha(
        VICTIM_CHALLENGE_DOMAIN,
        campaign_sha256,
        SCHEDULE_SHA256,
        component_set_sha256,
    )


def _recovery_challenge(
    campaign_sha256: bytes,
    component_set_sha256: bytes,
    ready_sha256: bytes,
    kill_sha256: bytes,
) -> bytes:
    return _sha(
        RECOVERY_CHALLENGE_DOMAIN,
        campaign_sha256,
        SCHEDULE_SHA256,
        component_set_sha256,
        ready_sha256,
        kill_sha256,
    )


def _victim_build(
    victim_sha256: bytes,
    metallib_sha256: bytes,
) -> bytes:
    return _sha(
        VICTIM_BUILD_DOMAIN,
        _u64(READY_ABI),
        _u64(0x474D_4942_0000_0001),
        _u64(0x474D_4946_0000_0001),
        victim_sha256,
        metallib_sha256,
    )


def _victim_backend() -> bytes:
    return _sha(
        VICTIM_BACKEND_DOMAIN,
        _u64(READY_ABI),
        _u64(0x474D_4449_0000_0001),
        _u64(0x474D_4153_0000_0001),
        _u64(0x474D_4141_0000_0001),
        _u64(0x474D_4942_0000_0001),
        _u64(0x474D_4946_0000_0001),
    )


def _w6_build(runner_sha256: bytes, metallib_sha256: bytes) -> bytes:
    return _sha(
        b"glacier-w6-metal-native-build-v1\x00",
        _u64(0x4757_364D_0000_0001),
        runner_sha256,
        metallib_sha256,
    )


def _ready_frame(
    *,
    pid: int = PID,
    challenge_sha256: bytes | None = None,
    victim_sha256: bytes = VICTIM_SHA256,
    metallib_sha256: bytes = VICTIM_METALLIB_SHA256,
    machine_sha256: bytes = MACHINE_SHA256,
    device_sha256: bytes = DEVICE_SHA256,
    placement_sha256: bytes = PLACEMENT_SHA256,
    scalar_overrides: dict[int, int] | None = None,
    digest_overrides: dict[int, bytes] | None = None,
) -> bytes:
    challenge = challenge_sha256 or _victim_challenge(
        CAMPAIGN_SHA256,
        _component_set(
            victim_sha256,
            metallib_sha256,
        ),
    )
    scalars = [
        READY_ABI,
        READY_BYTES,
        0,
        pid,
        7,
        11,
        1,
        3,
        1,
        0,
        1,
        1,
        2,
        4,
        1,
        4,
    ]
    if scalar_overrides:
        for index, value in scalar_overrides.items():
            scalars[index] = value
    digests = [
        challenge,
        victim_sha256,
        metallib_sha256,
        _victim_build(victim_sha256, metallib_sha256),
        machine_sha256,
        _victim_backend(),
        device_sha256,
        placement_sha256,
        TICKET_SHA256,
        PIN_SHA256,
        SUBMISSION_SHA256,
    ]
    if digest_overrides:
        for index, value in digest_overrides.items():
            digests[index] = value
    prefix = b"".join(
        (*(_u64(value) for value in scalars), *digests)
    )
    assert len(prefix) == READY_BYTES - 32
    return prefix + _sha(READY_DOMAIN, prefix)


def _kill_receipt(
    ready_frame: bytes,
    *,
    pid: int | None = None,
    campaign_sha256: bytes = CAMPAIGN_SHA256,
    scalar_overrides: dict[int, int] | None = None,
    digest_overrides: dict[int, bytes] | None = None,
) -> bytes:
    ready_scalars = struct.unpack("<16Q", ready_frame[:128])
    ready_digests = [
        ready_frame[128 + index * 32 : 160 + index * 32]
        for index in range(12)
    ]
    scalars = [
        KILL_ABI,
        KILL_BYTES,
        0,
        ready_scalars[3] if pid is None else pid,
        signal.SIGKILL,
        (-signal.SIGKILL) & ((1 << 64) - 1),
        READY_BYTES,
        0,
    ]
    if scalar_overrides:
        for index, value in scalar_overrides.items():
            scalars[index] = value
    digests = [
        campaign_sha256,
        ready_digests[0],
        ready_digests[11],
        ready_digests[1],
        ready_digests[2],
    ]
    if digest_overrides:
        for index, value in digest_overrides.items():
            digests[index] = value
    prefix = b"".join(
        (*(_u64(value) for value in scalars), *digests)
    )
    assert len(prefix) == KILL_BYTES - 32
    return prefix + _sha(KILL_DOMAIN, prefix)


def _outer_fixture(
    *,
    ready_frame: bytes | None = None,
    kill_receipt: bytes | None = None,
    campaign_sha256: bytes = CAMPAIGN_SHA256,
    recovery_runner_sha256: bytes = RECOVERY_RUNNER_SHA256,
    recovery_metallib_sha256: bytes = RECOVERY_METALLIB_SHA256,
) -> bytes:
    ready = ready_frame or _ready_frame()
    kill = kill_receipt or _kill_receipt(
        ready,
        campaign_sha256=campaign_sha256,
    )
    ready_digests = [
        ready[128 + index * 32 : 160 + index * 32]
        for index in range(12)
    ]
    kill_digests = [
        kill[64 + index * 32 : 96 + index * 32]
        for index in range(6)
    ]
    component_set = _component_set(
        ready_digests[1],
        ready_digests[2],
        recovery_runner_sha256,
        recovery_metallib_sha256,
    )
    recovery_challenge = _recovery_challenge(
        campaign_sha256,
        component_set,
        ready_digests[11],
        kill_digests[5],
    )
    recovery_wire = w6_fixture._native_fixture(
        runner_sha256=recovery_runner_sha256,
        metallib_sha256=recovery_metallib_sha256,
        challenge_sha256=recovery_challenge,
    )
    recovery_result = w6.verify_native_wire(
        recovery_wire,
        recovery_runner_sha256,
        recovery_metallib_sha256,
        recovery_challenge,
    )
    scalars = (
        REPORT_ABI,
        REPORT_BYTES,
        0,
        HEADER_BYTES,
        READY_BYTES,
        KILL_BYTES,
        W6_BYTES,
        1,
        1,
        1,
        20,
        20,
        47_360,
        2,
        2,
        0,
    )
    digests = (
        campaign_sha256,
        SCHEDULE_SHA256,
        ready_digests[0],
        recovery_challenge,
        ready_digests[1],
        ready_digests[2],
        ready_digests[3],
        recovery_runner_sha256,
        recovery_metallib_sha256,
        _w6_build(recovery_runner_sha256, recovery_metallib_sha256),
        ready_digests[11],
        kill_digests[5],
        hashlib.sha256(recovery_wire).digest(),
        recovery_result.report_sha256,
        component_set,
    )
    header_prefix = b"".join(
        (*(_u64(value) for value in scalars), *digests)
    )
    assert len(header_prefix) == HEADER_BYTES - 32
    header = header_prefix + _sha(HEADER_DOMAIN, header_prefix)
    body = header + ready + kill + recovery_wire
    body_sha256 = _sha(BODY_DOMAIN, body)
    report_sha256 = _sha(
        ROOT_DOMAIN,
        header[-32:],
        ready_digests[11],
        kill_digests[5],
        hashlib.sha256(recovery_wire).digest(),
        recovery_result.report_sha256,
        body_sha256,
    )
    encoded = body + body_sha256 + report_sha256
    assert len(encoded) == REPORT_BYTES
    return encoded


def _reseal_ready(encoded: bytes, offset: int, value: bytes) -> bytes:
    changed = bytearray(encoded)
    changed[offset : offset + len(value)] = value
    changed[-32:] = _sha(READY_DOMAIN, bytes(changed[:-32]))
    return bytes(changed)


def _reseal_kill(encoded: bytes, offset: int, value: bytes) -> bytes:
    changed = bytearray(encoded)
    changed[offset : offset + len(value)] = value
    changed[-32:] = _sha(KILL_DOMAIN, bytes(changed[:-32]))
    return bytes(changed)


def _reseal_outer(encoded: bytes, offset: int, value: bytes) -> bytes:
    changed = bytearray(encoded)
    changed[offset : offset + len(value)] = value
    changed[608:640] = _sha(HEADER_DOMAIN, bytes(changed[:608]))
    body_end = REPORT_BYTES - 64
    changed[body_end : body_end + 32] = _sha(
        BODY_DOMAIN,
        bytes(changed[:body_end]),
    )
    digest_offset = 128
    changed[body_end + 32 :] = _sha(
        ROOT_DOMAIN,
        bytes(changed[608:640]),
        bytes(changed[digest_offset + 10 * 32 : digest_offset + 11 * 32]),
        bytes(changed[digest_offset + 11 * 32 : digest_offset + 12 * 32]),
        bytes(changed[digest_offset + 12 * 32 : digest_offset + 13 * 32]),
        bytes(changed[digest_offset + 13 * 32 : digest_offset + 14 * 32]),
        bytes(changed[body_end : body_end + 32]),
    )
    return bytes(changed)


class _FakeProcess:
    def __init__(
        self,
        stdout: bytes,
        *,
        stderr: bytes = b"",
        pid: int = PID,
        close_stdout_before_kill: bool = False,
        returncode_after_kill: int = -signal.SIGKILL,
    ) -> None:
        stdout_read, self._stdout_write = os.pipe()
        stderr_read, self._stderr_write = os.pipe()
        self.stdout = os.fdopen(stdout_read, "rb", buffering=0)
        self.stderr = os.fdopen(stderr_read, "rb", buffering=0)
        self.pid = pid
        self.returncode: int | None = None
        self.returncode_after_kill = returncode_after_kill
        self.cleanup_kill_count = 0
        os.write(self._stdout_write, stdout)
        if stderr:
            os.write(self._stderr_write, stderr)
        if close_stdout_before_kill:
            os.close(self._stdout_write)
            self._stdout_write = -1

    def _close_writers(self) -> None:
        for name in ("_stdout_write", "_stderr_write"):
            descriptor = getattr(self, name)
            if descriptor >= 0:
                os.close(descriptor)
                setattr(self, name, -1)

    def mark_pid_killed(self) -> None:
        self.returncode = self.returncode_after_kill
        self._close_writers()

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        if self.returncode is None:
            raise subprocess.TimeoutExpired("fake", 0)
        return self.returncode

    def kill(self) -> None:
        self.cleanup_kill_count += 1
        self.returncode = -signal.SIGKILL
        self._close_writers()


class NativeMetalInflightProcessKillReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ready = _ready_frame()
        cls.kill = _kill_receipt(cls.ready)
        cls.encoded = _outer_fixture(
            ready_frame=cls.ready,
            kill_receipt=cls.kill,
        )

    def assertRejected(self, encoded: bytes) -> None:
        with self.assertRaises(
            report.NativeMetalInflightProcessKillReportError
        ):
            report.verify_outer_wire(encoded)

    def test_exact_independent_fixture_verifies(self) -> None:
        self.assertEqual(len(self.ready), READY_BYTES)
        self.assertEqual(len(self.kill), KILL_BYTES)
        self.assertEqual(len(self.encoded), REPORT_BYTES)
        decoded = report.verify_outer_wire(self.encoded)
        self.assertEqual(decoded.ready_frame.scalars["pid"], PID)
        self.assertEqual(
            decoded.header_scalars["recovery_record_count"],
            20,
        )
        self.assertEqual(
            decoded.header_scalars["recovery_completed_count"],
            20,
        )
        self.assertEqual(
            decoded.header_scalars["recovery_work_units"],
            47_360,
        )

    def test_independent_identity_formulas_are_locked(self) -> None:
        component_set = _component_set()
        victim_challenge = _victim_challenge(
            CAMPAIGN_SHA256,
            component_set,
        )
        self.assertEqual(report.EXPECTED_SCHEDULE_SHA256, SCHEDULE_SHA256)
        self.assertEqual(
            report._component_set_sha256(
                VICTIM_SHA256,
                VICTIM_METALLIB_SHA256,
                RECOVERY_RUNNER_SHA256,
                RECOVERY_METALLIB_SHA256,
            ),
            component_set,
        )
        self.assertEqual(
            report.derive_victim_challenge(
                CAMPAIGN_SHA256,
                component_set,
            ),
            victim_challenge,
        )
        self.assertEqual(
            report.victim_build_sha256(
                VICTIM_SHA256,
                VICTIM_METALLIB_SHA256,
            ),
            _victim_build(VICTIM_SHA256, VICTIM_METALLIB_SHA256),
        )
        self.assertEqual(
            report.expected_victim_backend_sha256(),
            _victim_backend(),
        )
        self.assertNotEqual(
            victim_challenge,
            _recovery_challenge(
                CAMPAIGN_SHA256,
                component_set,
                self.ready[-32:],
                self.kill[-32:],
            ),
        )

    def test_ready_frame_exact_fields_verify(self) -> None:
        decoded = report.decode_ready_frame(
            self.ready,
            expected_pid=PID,
            expected_challenge_sha256=self.ready[128:160],
            expected_victim_sha256=VICTIM_SHA256,
            expected_metallib_sha256=VICTIM_METALLIB_SHA256,
            expected_build_sha256=_victim_build(
                VICTIM_SHA256,
                VICTIM_METALLIB_SHA256,
            ),
        )
        self.assertEqual(decoded.scalars["command_buffer_status"], 3)
        self.assertEqual(decoded.scalars["completion_observed"], 0)
        self.assertEqual(decoded.scalars["live_native_buffer_count"], 4)

    def test_ready_frame_rejects_pid_status_barrier_and_ownership(self) -> None:
        cases = (
            (3, 0),
            (3, (1 << 64) - 1),
            (4, 0),
            (4, (1 << 64) - 1),
            (5, 0),
            (5, (1 << 64) - 1),
            (7, 4),
            (9, 1),
            (10, 2),
            (13, 5),
            (14, 2),
            (15, 5),
        )
        for scalar_index, value in cases:
            with self.subTest(index=scalar_index, value=value):
                changed = _reseal_ready(
                    self.ready,
                    scalar_index * 8,
                    _u64(value),
                )
                with self.assertRaises(
                    report.NativeMetalInflightProcessKillReportError
                ):
                    report.decode_ready_frame(changed)
        with self.assertRaises(
            report.NativeMetalInflightProcessKillReportError
        ):
            report.decode_ready_frame(self.ready, expected_pid=PID + 1)

    def test_ready_frame_rejects_root_build_backend_and_aliases(self) -> None:
        invalid_build = _reseal_ready(
            self.ready,
            128 + 3 * 32,
            hashlib.sha256(b"wrong build").digest(),
        )
        invalid_backend = _reseal_ready(
            self.ready,
            128 + 5 * 32,
            hashlib.sha256(b"wrong backend").digest(),
        )
        aliased_ticket = _reseal_ready(
            self.ready,
            128 + 8 * 32,
            PIN_SHA256,
        )
        corrupt_root = bytearray(self.ready)
        corrupt_root[-1] ^= 1
        for changed in (
            invalid_build,
            invalid_backend,
            aliased_ticket,
            bytes(corrupt_root),
        ):
            with self.subTest(changed=hashlib.sha256(changed).hexdigest()):
                with self.assertRaises(
                    report.NativeMetalInflightProcessKillReportError
                ):
                    report.decode_ready_frame(changed)

    def test_kill_receipt_exact_fields_verify(self) -> None:
        decoded = report.decode_kill_receipt(
            self.kill,
            expected_campaign_challenge_sha256=CAMPAIGN_SHA256,
            expected_victim_challenge_sha256=self.ready[128:160],
            expected_ready_frame_sha256=self.ready[-32:],
            expected_victim_sha256=VICTIM_SHA256,
            expected_metallib_sha256=VICTIM_METALLIB_SHA256,
        )
        self.assertEqual(decoded.scalars["pid"], PID)
        self.assertEqual(decoded.scalars["termination_signal"], signal.SIGKILL)
        self.assertEqual(decoded.scalars["stderr_bytes"], 0)

    def test_kill_receipt_rejects_status_pipe_facts_and_roots(self) -> None:
        scalar_cases = (
            (3, 0),
            (3, (1 << 64) - 1),
            (4, signal.SIGTERM),
            (5, 0),
            (6, READY_BYTES - 1),
            (7, 1),
        )
        for scalar_index, value in scalar_cases:
            with self.subTest(index=scalar_index, value=value):
                changed = _reseal_kill(
                    self.kill,
                    scalar_index * 8,
                    _u64(value),
                )
                with self.assertRaises(
                    report.NativeMetalInflightProcessKillReportError
                ):
                    report.decode_kill_receipt(changed)
        corrupt_root = bytearray(self.kill)
        corrupt_root[-1] ^= 1
        with self.assertRaises(
            report.NativeMetalInflightProcessKillReportError
        ):
            report.decode_kill_receipt(bytes(corrupt_root))

    def test_outer_rejects_ready_and_receipt_pid_disagreement(self) -> None:
        mismatched = _kill_receipt(self.ready, pid=PID + 1)
        self.assertRejected(
            _outer_fixture(
                ready_frame=self.ready,
                kill_receipt=mismatched,
            )
        )

    def test_outer_rejects_machine_device_or_placement_disagreement(self) -> None:
        for keyword in (
            "machine_sha256",
            "device_sha256",
            "placement_sha256",
        ):
            with self.subTest(identity=keyword):
                changed_ready = _ready_frame(
                    **{
                        keyword: hashlib.sha256(
                            ("wrong " + keyword).encode("ascii")
                        ).digest()
                    }
                )
                self.assertRejected(
                    _outer_fixture(
                        ready_frame=changed_ready,
                        kill_receipt=_kill_receipt(changed_ready),
                    )
                )

    def test_outer_rejects_profile_component_and_challenge_changes(self) -> None:
        changed_scalar = _reseal_outer(
            self.encoded,
            8 * 8,
            _u64(2),
        )
        changed_component_set = _reseal_outer(
            self.encoded,
            128 + 14 * 32,
            hashlib.sha256(b"wrong component set").digest(),
        )
        changed_victim_challenge = _reseal_outer(
            self.encoded,
            128 + 2 * 32,
            hashlib.sha256(b"wrong victim challenge").digest(),
        )
        changed_schedule = _reseal_outer(
            self.encoded,
            128 + 1 * 32,
            hashlib.sha256(b"wrong schedule").digest(),
        )
        for changed in (
            changed_scalar,
            changed_component_set,
            changed_victim_challenge,
            changed_schedule,
        ):
            self.assertRejected(changed)

    def test_outer_rejects_inner_wire_body_and_report_mutation(self) -> None:
        recovery_start = HEADER_BYTES + READY_BYTES + KILL_BYTES
        inner = bytearray(self.encoded)
        inner[recovery_start + W6_BYTES // 2] ^= 1
        body = bytearray(self.encoded)
        body[-64] ^= 1
        root = bytearray(self.encoded)
        root[-1] ^= 1
        for changed in (bytes(inner), bytes(body), bytes(root)):
            self.assertRejected(changed)

    def test_outer_rejects_truncation_extra_byte_and_midpoint_corruption(
        self,
    ) -> None:
        midpoint = bytearray(self.encoded)
        midpoint[len(midpoint) // 2] ^= 1
        for changed in (
            self.encoded[:-1],
            self.encoded + b"\x00",
            bytes(midpoint),
        ):
            self.assertRejected(changed)

    def test_expected_component_join_is_exact(self) -> None:
        expected = {
            "victim_sha256": VICTIM_SHA256,
            "victim_metallib_sha256": VICTIM_METALLIB_SHA256,
            "recovery_runner_sha256": RECOVERY_RUNNER_SHA256,
            "recovery_metallib_sha256": RECOVERY_METALLIB_SHA256,
        }
        report.verify_outer_wire(self.encoded, expected_components=expected)
        wrong = dict(expected)
        wrong["victim_sha256"] = hashlib.sha256(b"replacement").digest()
        with self.assertRaises(
            report.NativeMetalInflightProcessKillReportError
        ):
            report.verify_outer_wire(self.encoded, expected_components=wrong)
        del wrong["victim_sha256"]
        with self.assertRaises(
            report.NativeMetalInflightProcessKillReportError
        ):
            report.verify_outer_wire(self.encoded, expected_components=wrong)

    def test_component_snapshot_detects_source_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [
                root / "victim",
                root / "victim.metallib",
                root / "recovery",
                root / "recovery.metallib",
            ]
            for index, path in enumerate(paths):
                path.write_bytes(("component-%d" % index).encode("ascii"))
            snapshot = report._snapshot_components(*paths)
            mapping = dict(zip(snapshot, paths))
            report._verify_components_unchanged(mapping, snapshot)
            paths[2].write_bytes(b"changed recovery runner")
            with self.assertRaisesRegex(
                report.NativeMetalInflightProcessKillReportError,
                "changed during execution",
            ):
                report._verify_components_unchanged(mapping, snapshot)

    def _run_fake_boundary(
        self,
        fake: _FakeProcess,
        *,
        frame: bytes | None = None,
    ):
        observed: list[tuple[int, int]] = []

        def popen_factory(*args, **kwargs):
            self.assertEqual(args[0], ["/fixture/victim"])
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stdout"], subprocess.PIPE)
            self.assertEqual(kwargs["stderr"], subprocess.PIPE)
            self.assertEqual(
                kwargs["env"][
                    report.VICTIM_CHALLENGE_ENVIRONMENT
                ],
                self.ready[128:160].hex(),
            )
            return fake

        def kill_function(pid: int, termination_signal: int) -> None:
            observed.append((pid, termination_signal))
            fake.mark_pid_killed()

        result = report._run_victim_boundary(
            "/fixture/victim",
            self.ready[128:160],
            VICTIM_SHA256,
            VICTIM_METALLIB_SHA256,
            expected_build_sha256=_victim_build(
                VICTIM_SHA256,
                VICTIM_METALLIB_SHA256,
            ),
            ready_timeout_seconds=0.5,
            kill_timeout_seconds=0.5,
            popen_factory=popen_factory,
            kill_function=kill_function,
        )
        self.assertEqual(observed, [(PID, signal.SIGKILL)])
        self.assertEqual(result[2], frame or self.ready)
        self.assertEqual(result[3], b"")
        return result

    def test_boundary_sends_pid_only_sigkill_and_requires_exact_eof(self) -> None:
        fake = _FakeProcess(self.ready)
        ready, returncode, stdout, stderr = self._run_fake_boundary(fake)
        self.assertEqual(ready.scalars["pid"], PID)
        self.assertEqual(returncode, -signal.SIGKILL)
        self.assertEqual(stdout, self.ready)
        self.assertEqual(stderr, b"")
        self.assertEqual(fake.cleanup_kill_count, 0)

    def test_boundary_rejects_extra_stderr_pid_status_and_root(self) -> None:
        wrong_pid = _ready_frame(pid=PID + 1)
        wrong_status = _ready_frame(scalar_overrides={7: 4})
        wrong_root = bytearray(self.ready)
        wrong_root[-1] ^= 1
        cases = (
            _FakeProcess(self.ready + b"x"),
            _FakeProcess(self.ready, stderr=b"noise"),
            _FakeProcess(wrong_pid),
            _FakeProcess(wrong_status),
            _FakeProcess(bytes(wrong_root)),
            _FakeProcess(self.ready, returncode_after_kill=-signal.SIGTERM),
        )
        for fake in cases:
            with self.subTest(fake=fake):
                with self.assertRaises(
                    report.NativeMetalInflightProcessKillReportError
                ):
                    self._run_fake_boundary(fake)

    def test_boundary_rejects_stdout_eof_before_kill(self) -> None:
        fake = _FakeProcess(
            self.ready,
            close_stdout_before_kill=True,
        )
        with self.assertRaisesRegex(
            report.NativeMetalInflightProcessKillReportError,
            "stdout closed before PID-only kill",
        ):
            self._run_fake_boundary(fake)

    def test_controller_runs_distinct_recovery_and_retains_outer_wire(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            victim = root / "victim"
            victim_metallib = root / "victim.metallib"
            recovery = root / "recovery"
            recovery_metallib = root / "recovery.metallib"
            components = (
                (victim, b"controller victim"),
                (victim_metallib, b"controller victim metallib"),
                (recovery, b"controller recovery"),
                (recovery_metallib, b"controller recovery metallib"),
            )
            for path, data in components:
                path.write_bytes(data)
            output = root / "retained.bin"
            observed: dict[str, bytes] = {}

            def fake_boundary(
                victim_path,
                challenge_sha256,
                victim_sha256,
                metallib_sha256,
                **kwargs,
            ):
                self.assertEqual(Path(victim_path), victim)
                self.assertEqual(kwargs["ready_timeout_seconds"], 2.0)
                self.assertEqual(kwargs["kill_timeout_seconds"], 2.0)
                observed["victim_challenge"] = challenge_sha256
                encoded = _ready_frame(
                    pid=PID,
                    challenge_sha256=challenge_sha256,
                    victim_sha256=victim_sha256,
                    metallib_sha256=metallib_sha256,
                )
                decoded = report.decode_ready_frame(
                    encoded,
                    expected_pid=PID,
                    expected_challenge_sha256=challenge_sha256,
                    expected_victim_sha256=victim_sha256,
                    expected_metallib_sha256=metallib_sha256,
                )
                return decoded, -signal.SIGKILL, encoded, b""

            def fake_recovery(
                runner_path,
                challenge_sha256,
                runner_sha256,
                metallib_sha256,
                timeout_seconds,
            ):
                self.assertEqual(Path(runner_path), recovery)
                self.assertEqual(timeout_seconds, 2.0)
                observed["recovery_challenge"] = challenge_sha256
                return w6_fixture._native_fixture(
                    runner_sha256=runner_sha256,
                    metallib_sha256=metallib_sha256,
                    challenge_sha256=challenge_sha256,
                )

            with mock.patch.object(
                report,
                "_run_victim_boundary",
                side_effect=fake_boundary,
            ), mock.patch.object(
                report,
                "_run_recovery_worker",
                side_effect=fake_recovery,
            ):
                result = report.run_campaign(
                    victim,
                    victim_metallib,
                    recovery,
                    recovery_metallib,
                    output,
                    timeout_seconds=2.0,
                    campaign_challenge_sha256=CAMPAIGN_SHA256,
                )
            self.assertEqual(result.victim_pid, PID)
            self.assertEqual(result.termination_signal, signal.SIGKILL)
            self.assertEqual(result.recovery_record_count, 20)
            self.assertNotEqual(
                observed["victim_challenge"],
                observed["recovery_challenge"],
            )
            self.assertEqual(output.stat().st_size, REPORT_BYTES)
            verified = report.verify_report_file(output)
            self.assertEqual(verified.report_sha256, result.report_sha256)

    def test_offline_cli_verifies_retained_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.bin"
            path.write_bytes(self.encoded)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                returncode = report._main(["--verify", os.fspath(path)])
            self.assertEqual(returncode, 0)
            self.assertEqual(stderr.getvalue(), "")
            self.assertIn(
                "ok native-metal-inflight-process-kill-report-v1",
                stdout.getvalue(),
            )
            self.assertIn("signal=%d" % signal.SIGKILL, stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
