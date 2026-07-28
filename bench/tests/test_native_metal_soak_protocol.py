from __future__ import annotations

import contextlib
import os
from pathlib import Path
import sys
import tempfile
import textwrap
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


if __name__ == "__main__":
    unittest.main()
