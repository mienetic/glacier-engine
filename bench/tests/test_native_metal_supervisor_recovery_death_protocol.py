from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

from bench import native_metal_supervisor_recovery_death_campaign as runner
from bench import native_metal_supervisor_recovery_death_report as report
from bench import native_metal_soak_report as soak
from bench.tests import (
    test_native_metal_supervisor_recovery_death_report as report_fixture,
)


class NativeMetalSupervisorRecoveryDeathProtocolTests(
    unittest.TestCase
):
    def test_host_protocol_is_real_ephemeral_and_never_evidence(
        self,
    ) -> None:
        receipt = runner.run_host_protocol_fixture()
        self.assertEqual(runner.HOST_RECEIPT_SCHEMA, receipt["schema"])
        self.assertEqual(2, receipt["sigkills"])
        self.assertEqual(2, receipt["worker_processes"])
        self.assertEqual(7, receipt["distinct_role_pids"])
        self.assertTrue(receipt["real_processes"])
        self.assertTrue(receipt["real_flock"])
        self.assertTrue(receipt["real_filesystem_operations"])
        self.assertFalse(receipt["gpu_execution"])
        self.assertFalse(receipt["report_retained"])
        self.assertFalse(receipt["hard_protocol_verified"])
        self.assertFalse(receipt["evidence"])
        self.assertTrue(receipt["verified"])

    def test_host_frame_mutation_fails_closed(self) -> None:
        encoded = runner._host_frame(
            phase=1,
            pid=101,
            worker_pid=102,
            lock_device=103,
            lock_inode=104,
            encoded_bytes=512,
        )
        decoded = runner._decode_host_frame(
            encoded,
            expected_phase=1,
            expected_bytes=512,
        )
        self.assertEqual(101, decoded["pid"])
        mutated = bytearray(encoded)
        mutated[-1] ^= 1
        with self.assertRaisesRegex(
            runner.SupervisorRecoveryDeathCampaignError,
            "content changed",
        ):
            runner._decode_host_frame(
                bytes(mutated),
                expected_phase=1,
                expected_bytes=512,
            )

    def test_wrong_ack_reaps_child_and_retains_no_lock(
        self,
    ) -> None:
        observed: list[subprocess.Popen[bytes]] = []
        original = runner._ChildRegistry.cleanup

        def recording_cleanup(
            registry: runner._ChildRegistry,
        ) -> None:
            original(registry)
            observed.extend(registry.processes)

        def mutate_ack(value: dict[str, object]) -> dict[str, object]:
            value["lock_inode"] = int(value["lock_inode"]) + 1
            return value

        with mock.patch.object(
            runner._ChildRegistry,
            "cleanup",
            recording_cleanup,
        ):
            with self.assertRaisesRegex(
                runner.SupervisorRecoveryDeathCampaignError,
                "ended early",
            ):
                runner.run_host_protocol_fixture(
                    ready_timeout=1.0,
                    _ack_mutator=mutate_ack,
                )
        self.assertTrue(observed)
        self.assertTrue(all(process.poll() is not None for process in observed))

    def test_no_public_ready_before_ack_and_missing_ack_cleanup(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            root = parent / "campaign"
            protocol = parent / "protocol"
            root.mkdir(mode=0o700)
            protocol.mkdir(mode=0o700)
            lock_fd = os.open(
                root / soak.LOCK_NAME,
                os.O_RDWR | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            os.fchmod(lock_fd, 0o600)
            os.close(lock_fd)
            challenge = hashlib.sha256(b"missing-ack").digest()
            config = protocol / "supervisor.config.json"
            handoff = protocol / "supervisor.handoff.json"
            ack = protocol / "supervisor.ack.json"
            runner._write_private_json(
                config,
                {
                    "schema": "glacier.w7b-b5/host-victim-config-v1",
                    "controller_pid": os.getpid(),
                    "ack_timeout_millis": 5_000,
                    "supervisor_challenge_sha256": challenge,
                },
            )
            with runner._ChildRegistry() as registry:
                process = runner._spawn_role(
                    "host-victim",
                    worker=runner._SCRIPT_PATH,
                    metallib=runner._SCRIPT_PATH,
                    campaign_dir=root,
                    config=config,
                    handoff=handoff,
                    ack=ack,
                    extra=("--_host-phase", "supervisor"),
                    registry=registry,
                )
                pre_ready = runner._wait_private_json(
                    handoff,
                    process,
                    timeout=2.0,
                    remove=True,
                )
                runner._prove_lock_contended(
                    root / soak.LOCK_NAME,
                    int(pre_ready["lock_device"]),
                    int(pre_ready["lock_inode"]),
                )
                self.assertIsNotNone(process.stdout)
                selector = selectors.DefaultSelector()
                selector.register(process.stdout, selectors.EVENT_READ)
                try:
                    self.assertEqual([], selector.select(0.05))
                finally:
                    selector.close()
                with self.assertRaisesRegex(
                    runner.SupervisorRecoveryDeathCampaignError,
                    "timed out",
                ):
                    runner._read_exact_frame(
                        process,
                        512,
                        timeout=0.05,
                        require_blocked=True,
                    )
            self.assertEqual(-signal.SIGKILL, process.returncode)
            probe = os.open(root / soak.LOCK_NAME, os.O_RDWR)
            try:
                fcntl.flock(
                    probe,
                    fcntl.LOCK_EX | fcntl.LOCK_NB,
                )
                fcntl.flock(probe, fcntl.LOCK_UN)
            finally:
                os.close(probe)

    def test_valid_ack_is_exact_and_challenge_bound(self) -> None:
        challenge = hashlib.sha256(b"contention-challenge").digest()
        value = runner._contention_ack(
            controller_pid=101,
            supervisor_pid=102,
            worker_pid=103,
            lock_device=104,
            lock_inode=105,
            supervisor_challenge_sha256=challenge,
        )
        runner._validate_contention_ack(
            value,
            controller_pid=101,
            supervisor_pid=102,
            worker_pid=103,
            lock_device=104,
            lock_inode=105,
            supervisor_challenge_sha256=challenge,
        )
        wrong = dict(value)
        wrong["supervisor_challenge_sha256"] = "11" * 32
        with self.assertRaisesRegex(
            runner.SupervisorRecoveryDeathCampaignError,
            "ACK changed",
        ):
            runner._validate_contention_ack(
                wrong,
                controller_pid=101,
                supervisor_pid=102,
                worker_pid=103,
                lock_device=104,
                lock_inode=105,
                supervisor_challenge_sha256=challenge,
            )

    def test_component_hash_rejects_symlink_and_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            worker = root / "worker"
            metallib = root / "default.metallib"
            verifier = root / "verifier"
            worker.write_bytes(b"worker-v1")
            metallib.write_bytes(b"metallib-v1")
            verifier.write_bytes(b"verifier-v1")
            snapshot = runner._component_snapshot(
                worker,
                metallib,
                verifier,
            )
            runner._verify_component_snapshot(
                snapshot,
                worker,
                metallib,
                verifier,
            )
            worker.write_bytes(b"worker-v2")
            with self.assertRaisesRegex(
                runner.SupervisorRecoveryDeathCampaignError,
                "provenance changed",
            ):
                runner._verify_component_snapshot(
                    snapshot,
                    worker,
                    metallib,
                    verifier,
                )
            link = root / "worker-link"
            link.symlink_to(worker)
            with self.assertRaises(OSError):
                runner._file_sha256(link)

    def test_fresh_report_verifier_runs_each_implementation_once(
        self,
    ) -> None:
        encoded = report_fixture._fixture()[7]
        decoded = report.verify_report(encoded)
        python_receipt = {
            "schema": runner.PYTHON_VERIFY_SCHEMA,
            "encoded_bytes": len(encoded),
            "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
            "report_sha256": decoded.report_sha256.hex(),
            "verified": True,
        }
        python_result = subprocess.CompletedProcess(
            args=("python",),
            returncode=0,
            stdout=(
                json.dumps(
                    python_receipt,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("ascii")
                + b"\n"
            ),
            stderr=b"",
        )
        zig_result = subprocess.CompletedProcess(
            args=("zig-verifier",),
            returncode=0,
            stdout=(
                "wire_verified=true claims_only=true generation=6->12 "
                "recovery_lock_ack=1 claimed_sigkills=2 "
                "claimed_commands=1200 claimed_cpu_oracles=1200 "
                "report_sha256="
                + decoded.report_sha256.hex()
                + "\n"
            ).encode("ascii"),
            stderr=b"",
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.bin"
            path.write_bytes(encoded)
            with mock.patch.object(
                runner.subprocess,
                "run",
                side_effect=(python_result, zig_result),
            ) as run:
                receipt = runner._verify_report_fresh(
                    path,
                    encoded,
                    Path("/fixture/zig-verifier"),
                )
        self.assertTrue(receipt["verified"])
        self.assertEqual(2, run.call_count)

    def test_controller_header_composition_matches_wire_codec(self) -> None:
        (
            header,
            supervisor_ready,
            supervisor_kill,
            audit_six,
            recovery_ready,
            recovery_kill,
            audit_final,
            encoded,
        ) = report_fixture._fixture()
        components = {
            name: header[name]
            for name in (
                "controller_sha256",
                "supervisor_sha256",
                "recovery_sha256",
                "worker_sha256",
                "metallib_sha256",
                "verifier_sha256",
            )
        }
        plan = {
            name: header[name]
            for name in (
                "campaign_challenge_sha256",
                "schedule_sha256",
                "machine_sha256",
                "backend_sha256",
                "device_sha256",
                "placement_sha256",
            )
        }
        rebuilt_header = runner._header_record(
            plan_identities=plan,
            controller_authority_sha256=header[
                "controller_authority_sha256"
            ],
            components=components,
            component_set_sha256=header["component_set_sha256"],
            resume_grant_sha256=header["resume_grant_sha256"],
            finalizer_grant_sha256=header["finalizer_grant_sha256"],
            supervisor_ready=supervisor_ready,
            supervisor_kill=supervisor_kill,
            generation_six_audit=audit_six,
            recovery_ready=recovery_ready,
            recovery_kill=recovery_kill,
            final_audit=audit_final,
        )
        self.assertEqual(header, rebuilt_header)
        self.assertEqual(
            encoded,
            report.make_report(
                rebuilt_header,
                supervisor_ready,
                supervisor_kill,
                audit_six,
                recovery_ready,
                recovery_kill,
                audit_final,
            ),
        )

    def test_existing_output_is_never_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            target = root / "target"
            source.mkdir()
            target.mkdir()
            (source / "report.bin").write_bytes(b"new")
            (target / "owned").write_bytes(b"old")
            with self.assertRaisesRegex(
                runner.SupervisorRecoveryDeathCampaignError,
                "already exists",
            ):
                runner._rename_noreplace(source, target)
            self.assertEqual(b"old", (target / "owned").read_bytes())
            self.assertEqual(b"new", (source / "report.bin").read_bytes())

    def test_atomic_noreplace_publishes_one_new_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            target = root / "target"
            source.mkdir()
            (source / "report.bin").write_bytes(b"report")
            runner._rename_noreplace(source, target)
            self.assertFalse(source.exists())
            self.assertEqual(b"report", (target / "report.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
