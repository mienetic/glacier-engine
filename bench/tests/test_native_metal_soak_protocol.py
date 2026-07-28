from __future__ import annotations

import contextlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

from bench import native_metal_soak_report as soak


def _fake_worker(directory: Path, body: str) -> Path:
    path = directory / "fake-native-metal-soak-worker"
    path.write_text(
        "#!%s\n%s"
        % (
            sys.executable,
            textwrap.dedent(body).lstrip(),
        ),
        encoding="utf-8",
    )
    path.chmod(0o700)
    return path


@contextlib.contextmanager
def _persistent_worker(body: str):
    with tempfile.TemporaryDirectory(
        prefix="glacier-soak-protocol-test."
    ) as directory:
        root = Path(directory)
        worker_path = _fake_worker(root, body)
        metallib_path = root / "fake.metallib"
        metallib_path.write_bytes(b"fake-metal-library")
        worker_sha256 = soak._file_sha256(worker_path)
        metallib_sha256 = soak._file_sha256(metallib_path)
        worker = soak._PersistentWorker(
            os.fspath(worker_path),
            os.fspath(metallib_path),
            worker_sha256,
            metallib_sha256,
        )
        # These tests exercise framing and lifecycle behavior, not the native
        # /bin/ps adapter. Two deterministic endpoint samples are sufficient.
        worker._sample_rss = lambda: 16 * 1024 * 1024  # type: ignore[method-assign]
        try:
            with mock.patch.object(soak, "MINIMUM_RSS_SAMPLES", 2):
                yield worker
        finally:
            worker.abort()
            for stream in (
                worker.process.stdin,
                worker.process.stdout,
                worker.process.stderr,
            ):
                if stream is not None:
                    with contextlib.suppress(OSError, ValueError):
                        stream.close()


class NativeMetalSoakWorkerProtocolTests(unittest.TestCase):
    def test_selector_construction_failure_reaps_worker_and_closes_pipes(
        self,
    ) -> None:
        real_popen = subprocess.Popen
        started: list[subprocess.Popen[bytes]] = []

        def start_worker(
            *args: object,
            **kwargs: object,
        ) -> subprocess.Popen[bytes]:
            process = real_popen(*args, **kwargs)  # type: ignore[arg-type]
            started.append(process)
            return process

        with tempfile.TemporaryDirectory(
            prefix="glacier-selector-failure-test."
        ) as directory:
            root = Path(directory)
            worker_path = _fake_worker(
                root,
                """
                    import time
                    time.sleep(60)
                """,
            )
            metallib_path = root / "fake.metallib"
            metallib_path.write_bytes(b"fake-metal-library")
            with (
                mock.patch.object(
                    soak.subprocess,
                    "Popen",
                    side_effect=start_worker,
                ),
                mock.patch.object(
                    soak.selectors,
                    "DefaultSelector",
                    side_effect=OSError("injected selector failure"),
                ),
            ):
                with self.assertRaisesRegex(
                    soak.NativeMetalSoakError,
                    "could not register",
                ):
                    soak._PersistentWorker(
                        os.fspath(worker_path),
                        os.fspath(metallib_path),
                        soak._file_sha256(worker_path),
                        soak._file_sha256(metallib_path),
                    )

        self.assertEqual(1, len(started))
        process = started[0]
        self.assertIsNotNone(process.poll())
        for stream in (
            process.stdin,
            process.stdout,
            process.stderr,
        ):
            self.assertIsNotNone(stream)
            self.assertTrue(stream.closed)  # type: ignore[union-attr]

    def test_rejects_wrong_declared_wire_lengths(self) -> None:
        for declared in (
            soak.inner.EXPECTED_WIRE_BYTES - 1,
            soak.inner.EXPECTED_WIRE_BYTES + 1,
            (1 << 64) - 1,
        ):
            with self.subTest(declared=declared):
                body = """
                    import struct
                    import sys
                    import time

                    if not sys.stdin.buffer.readline():
                        raise SystemExit(2)
                    sys.stdout.buffer.write(struct.pack("<Q", %d))
                    sys.stdout.buffer.flush()
                    time.sleep(10)
                """ % declared
                with _persistent_worker(body) as worker:
                    with self.assertRaisesRegex(
                        soak.NativeMetalSoakError,
                        "declared an unexpected wire length",
                    ):
                        worker.request(bytes([1]) * 32, 1.0)

    def test_rejects_stderr_from_live_worker(self) -> None:
        body = """
            import sys
            import time

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            sys.stderr.buffer.write(b"fake worker diagnostic\\n")
            sys.stderr.buffer.flush()
            time.sleep(10)
        """
        with _persistent_worker(body) as worker:
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "wrote to stderr",
            ):
                worker.request(bytes([2]) * 32, 1.0)

    def test_rejects_early_exit_with_truncated_frame(self) -> None:
        body = """
            import struct
            import sys

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            sys.stdout.buffer.write(struct.pack("<Q", %d))
            sys.stdout.buffer.write(b"truncated")
            sys.stdout.buffer.flush()
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "exited before emitting a frame",
            ):
                worker.request(bytes([3]) * 32, 1.0)

    def test_timeout_followed_by_abort_reaps_live_truncated_worker(self) -> None:
        body = """
            import struct
            import sys
            import time

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            sys.stdout.buffer.write(struct.pack("<Q", %d))
            sys.stdout.buffer.write(b"truncated")
            sys.stdout.buffer.flush()
            time.sleep(10)
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "segment exceeded 0.2s timeout",
            ):
                worker.request(bytes([4]) * 32, 0.2)
            self.assertIsNone(worker.process.poll())
            worker.abort()
            self.assertIsNotNone(worker.process.poll())
            self.assertEqual(
                worker.process.returncode,
                worker.process.wait(timeout=0),
            )

    def test_rejects_bytes_beyond_one_frame(self) -> None:
        frame_bytes = 8 + soak.inner.EXPECTED_WIRE_BYTES
        body = """
            import struct
            import sys
            import time

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            wire_bytes = %d
            sys.stdout.buffer.write(struct.pack("<Q", wire_bytes))
            sys.stdout.buffer.write(bytes(wire_bytes))
            sys.stdout.buffer.write(b"x")
            sys.stdout.buffer.flush()
            sys.stdin.buffer.read()
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            try:
                worker.request(bytes([5]) * 32, 1.0)
            except soak.NativeMetalSoakError as error:
                self.assertRegex(
                    str(error),
                    "stdout exceeded %d bytes" % frame_bytes,
                )
            else:
                # Pipe chunking can leave the extra byte unread until the
                # exact frame has been returned. It must still fail closure.
                with self.assertRaisesRegex(
                    soak.NativeMetalSoakError,
                    "emitted trailing output",
                ):
                    worker.close_cleanly()

    def test_exact_frame_then_clean_eof_succeeds(self) -> None:
        body = """
            import struct
            import sys

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            wire_bytes = %d
            sys.stdout.buffer.write(struct.pack("<Q", wire_bytes))
            sys.stdout.buffer.write(bytes(wire_bytes))
            sys.stdout.buffer.flush()
            sys.stdin.buffer.read()
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            wire, duration_ns, rss = worker.request(
                bytes([6]) * 32,
                1.0,
            )
            self.assertEqual(soak.inner.EXPECTED_WIRE_BYTES, len(wire))
            self.assertEqual(bytes(len(wire)), wire)
            self.assertGreater(duration_ns, 0)
            self.assertEqual((16 * 1024 * 1024,) * 3, rss[:3])
            self.assertGreaterEqual(rss[3], 2)
            worker.close_cleanly()
            self.assertTrue(worker.closed)
            self.assertEqual(0, worker.process.returncode)

    def test_exact_frame_then_scheduled_sigkill_is_reaped(self) -> None:
        body = """
            import struct
            import sys

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            wire_bytes = %d
            sys.stdout.buffer.write(struct.pack("<Q", wire_bytes))
            sys.stdout.buffer.write(bytes(wire_bytes))
            sys.stdout.buffer.flush()
            sys.stdin.buffer.read()
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            wire, _duration_ns, _rss = worker.request(
                bytes([8]) * 32,
                1.0,
            )
            self.assertEqual(soak.inner.EXPECTED_WIRE_BYTES, len(wire))
            worker.kill_for_campaign()
            self.assertTrue(worker.closed)
            self.assertEqual(
                -soak.campaign.TERMINATION_SIGNAL_KILL,
                worker.process.returncode,
            )

    def test_scheduled_sigkill_rejects_natural_worker_exit(self) -> None:
        body = """
            import struct
            import sys

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            wire_bytes = %d
            sys.stdout.buffer.write(struct.pack("<Q", wire_bytes))
            sys.stdout.buffer.write(bytes(wire_bytes))
            sys.stdout.buffer.flush()
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            wire, _duration_ns, _rss = worker.request(
                bytes([9]) * 32,
                1.0,
            )
            self.assertEqual(soak.inner.EXPECTED_WIRE_BYTES, len(wire))
            worker.process.wait(timeout=1.0)
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "exited before its scheduled process kill",
            ):
                worker.kill_for_campaign()

    def test_rejects_trailing_stdout_emitted_after_eof(self) -> None:
        body = """
            import struct
            import sys

            if not sys.stdin.buffer.readline():
                raise SystemExit(2)
            wire_bytes = %d
            sys.stdout.buffer.write(struct.pack("<Q", wire_bytes))
            sys.stdout.buffer.write(bytes(wire_bytes))
            sys.stdout.buffer.flush()
            sys.stdin.buffer.read()
            sys.stdout.buffer.write(b"trailing")
            sys.stdout.buffer.flush()
        """ % soak.inner.EXPECTED_WIRE_BYTES
        with _persistent_worker(body) as worker:
            wire, _duration_ns, _rss = worker.request(
                bytes([7]) * 32,
                1.0,
            )
            self.assertEqual(soak.inner.EXPECTED_WIRE_BYTES, len(wire))
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "emitted trailing output",
            ):
                worker.close_cleanly()

    def test_abort_reaps_live_worker(self) -> None:
        body = """
            import sys
            import time

            sys.stdin.buffer.readline()
            time.sleep(10)
        """
        with _persistent_worker(body) as worker:
            self.assertIsNone(worker.process.poll())
            worker.abort()
            self.assertIsNotNone(worker.process.poll())
            self.assertEqual(
                worker.process.returncode,
                worker.process.wait(timeout=0),
            )

    def test_watchdog_kills_descendant_after_group_leader_exits(self) -> None:
        leader_source = """
            import os
            import subprocess
            import sys
            import time

            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import pathlib,signal,sys,time;"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN);"
                    "pathlib.Path(sys.argv[1]).write_text('ready');"
                    "time.sleep(60)",
                    sys.argv[2],
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            deadline = time.monotonic() + 2
            while not os.path.exists(sys.argv[2]):
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise SystemExit(3)
                time.sleep(0.01)
            with open(sys.argv[1], "w", encoding="ascii") as stream:
                stream.write(str(child.pid))
            while True:
                time.sleep(1)
        """
        with tempfile.TemporaryDirectory(
            prefix="glacier-watchdog-group-test."
        ) as directory:
            child_pid_path = Path(directory) / "child.pid"
            child_ready_path = Path(directory) / "child.ready"
            leader = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    textwrap.dedent(leader_source),
                    os.fspath(child_pid_path),
                    os.fspath(child_ready_path),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
            )
            child_pid = 0
            try:
                deadline = time.monotonic() + 2.0
                while (
                    not child_pid_path.exists()
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue(child_pid_path.exists())
                child_pid = int(child_pid_path.read_text("ascii"))
                os.killpg(leader.pid, signal.SIGTERM)
                leader.wait(timeout=1.0)
                os.kill(child_pid, 0)

                soak._force_kill_process_group(leader)
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    status = subprocess.run(
                        ["/bin/ps", "-o", "stat=", "-p", str(child_pid)],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        check=False,
                        timeout=0.5,
                    )
                    if status.returncode != 0 or status.stdout.lstrip().startswith(
                        b"Z"
                    ):
                        break
                    time.sleep(0.01)
                else:
                    self.fail("watchdog descendant survived SIGKILL")
            finally:
                with contextlib.suppress(OSError):
                    os.killpg(leader.pid, signal.SIGKILL)
                if child_pid:
                    with contextlib.suppress(OSError):
                        os.kill(child_pid, signal.SIGKILL)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    leader.wait(timeout=1.0)

    def test_watchdog_timeout_cleans_group_store_and_skips_offline(
        self,
    ) -> None:
        leader_source = """
            import os
            import pathlib
            import subprocess
            import sys
            import time

            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import pathlib,signal,sys,time;"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN);"
                    "pathlib.Path(sys.argv[1]).write_text('ready');"
                    "time.sleep(60)",
                    sys.argv[2],
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            deadline = time.monotonic() + 1
            while not pathlib.Path(sys.argv[2]).exists():
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise SystemExit(3)
                time.sleep(0.01)
            pathlib.Path(sys.argv[1]).write_text(
                f"{os.getpid()} {child.pid}"
            )
            while True:
                time.sleep(1)
        """
        real_temporary_directory = tempfile.TemporaryDirectory
        with real_temporary_directory(
            prefix="glacier-watchdog-e2e-parent."
        ) as parent:
            parent_path = Path(parent)
            pid_path = parent_path / "processes"
            ready_path = parent_path / "child.ready"
            created_stores: list[Path] = []

            def temporary_store(
                *,
                prefix: str,
            ) -> tempfile.TemporaryDirectory[str]:
                value = real_temporary_directory(
                    prefix=prefix,
                    dir=parent,
                )
                created_stores.append(Path(value.name))
                return value

            command = [
                sys.executable,
                "-c",
                textwrap.dedent(leader_source),
                os.fspath(pid_path),
                os.fspath(ready_path),
            ]
            with (
                mock.patch.object(
                    soak,
                    "CAMPAIGN_WALL_TIMEOUT_SECONDS",
                    2.0,
                ),
                mock.patch.object(
                    soak.tempfile,
                    "TemporaryDirectory",
                    side_effect=temporary_store,
                ),
                mock.patch.object(
                    soak,
                    "_run_offline_verifier",
                ) as offline,
                mock.patch.object(soak.sys, "stderr"),
            ):
                result = soak._run_with_watchdog(
                    "unused-worker",
                    "unused-metallib",
                    None,
                    _supervised_command=command,
                )

            self.assertEqual(1, result)
            offline.assert_not_called()
            self.assertEqual(1, len(created_stores))
            self.assertFalse(created_stores[0].exists())
            self.assertTrue(pid_path.exists())
            group_pid, child_pid = (
                int(value)
                for value in pid_path.read_text("ascii").split()
            )
            try:
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    status = subprocess.run(
                        ["/bin/ps", "-o", "stat=", "-p", str(child_pid)],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        check=False,
                        timeout=0.5,
                    )
                    if (
                        status.returncode != 0
                        or status.stdout.lstrip().startswith(b"Z")
                    ):
                        break
                    time.sleep(0.01)
                else:
                    self.fail("watchdog timeout left a live descendant")
            finally:
                with contextlib.suppress(OSError):
                    os.killpg(group_pid, signal.SIGKILL)
                with contextlib.suppress(OSError):
                    os.kill(child_pid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
