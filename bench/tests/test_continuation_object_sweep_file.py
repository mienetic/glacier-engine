from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

from bench import continuation_object_sweep_file as file_api
from bench import continuation_object_sweep_record as record
from bench import continuation_object_sweep_writer as writer


class ContinuationObjectSweepFileTests(unittest.TestCase):
    def setUp(self) -> None:
        first_input = record.demo_input()
        self.first = record.encode(first_input)
        first_root = record.decode(self.first)["record_sha256"]
        second_input = record.demo_input(0x7A, 0x7B)
        second_input["sequence"] = 2
        second_input["previous_record_sha256"] = first_root
        self.second = record.encode(second_input)
        self.stream = self.first + self.second
        self.anchor = record.origin_recovery_anchor()
        self.max_bytes = record.ENCODED_BYTES * 3

    def test_locked_file_appends_and_reopens_exact_stream(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with file_api.LockedSweepFile.create(
                directory,
                "sweep.records",
                41,
                self.max_bytes,
            ) as lease:
                self.assertEqual(lease.directory_sync_status, "synced")
                self.assertEqual(lease.file_sync_count, 1)
                lock_attempt = subprocess.run(
                    (
                        sys.executable,
                        "-m",
                        "bench.continuation_object_sweep_file",
                        "_child-try-lock",
                        directory,
                        "sweep.records",
                        "41",
                        str(self.max_bytes),
                    ),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    lock_attempt.returncode,
                    file_api.LOCK_HELD_EXIT,
                    lock_attempt.stderr,
                )
                capability = lease.append_capability()
                stream_writer = writer.Writer.open_clean(
                    lease.observed,
                    self.anchor,
                    capability,
                )
                stream_writer.append_record(self.first)
                stream_writer.append_record(self.second)
                self.assertEqual(lease.current_bytes, len(self.stream))
                self.assertEqual(lease.file_sync_count, 5)
                with self.assertRaises(file_api.FileAdapterError):
                    writer.Writer.open_clean(
                        self.first,
                        self.anchor,
                        capability,
                    )

            self.assertEqual(
                (Path(directory) / "sweep.records").read_bytes(),
                self.stream,
            )
            with file_api.LockedSweepFile.open(
                directory,
                "sweep.records",
                41,
                self.max_bytes,
            ) as reopened:
                self.assertEqual(reopened.observed, self.stream)
                clean_writer = writer.Writer.open_clean(
                    reopened.observed,
                    self.anchor,
                    reopened.append_capability(),
                )
                self.assertEqual(clean_writer.next_sequence, 3)

    def test_subprocess_death_after_every_append_phase_reopens_exactly(self) -> None:
        body_phases = {writer.BODY_WRITE, writer.BODY_SYNC}
        with tempfile.TemporaryDirectory() as directory:
            for index, phase in enumerate(writer.APPEND_PHASES):
                with self.subTest(phase=phase):
                    name = f"append-death-{index}.records"
                    epoch = 100 + index
                    with file_api.LockedSweepFile.create(
                        directory,
                        name,
                        epoch,
                        self.max_bytes,
                    ):
                        pass
                    child = subprocess.run(
                        (
                            sys.executable,
                            "-m",
                            "bench.continuation_object_sweep_file",
                            "_child-append",
                            directory,
                            name,
                            str(epoch),
                            str(self.max_bytes),
                            self.first.hex(),
                            phase,
                        ),
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        child.returncode,
                        -signal.SIGKILL,
                        child.stderr,
                    )
                    with file_api.LockedSweepFile.open(
                        directory,
                        name,
                        epoch,
                        self.max_bytes,
                    ) as reopened:
                        plan = writer.plan_recovery(
                            reopened.observed,
                            self.anchor,
                            reopened.snapshot,
                        )
                        if phase in body_phases:
                            self.assertEqual(
                                plan["action"],
                                "repair_incomplete_tail",
                            )
                            repairer = writer.Repairer.create(
                                reopened.observed,
                                self.anchor,
                                reopened.prepare_repair(self.anchor),
                            )
                            receipt = repairer.apply()
                            self.assertEqual(receipt["committed_bytes"], 0)
                        else:
                            self.assertEqual(plan["action"], "open_clean")
                            self.assertEqual(reopened.observed, self.first)

    def test_subprocess_death_during_repair_leaves_verified_prefix(self) -> None:
        partial = self.first + self.second[: record.BODY_BYTES + 7]
        with tempfile.TemporaryDirectory() as directory:
            for index, phase in enumerate(writer.REPAIR_PHASES):
                with self.subTest(phase=phase):
                    name = f"repair-death-{index}.records"
                    epoch = 200 + index
                    path = Path(directory) / name
                    path.write_bytes(partial)
                    path.chmod(0o600)
                    with path.open("r+b", buffering=0) as stream:
                        os.fsync(stream.fileno())
                    child = subprocess.run(
                        (
                            sys.executable,
                            "-m",
                            "bench.continuation_object_sweep_file",
                            "_child-repair",
                            directory,
                            name,
                            str(epoch),
                            str(self.max_bytes),
                            phase,
                        ),
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        child.returncode,
                        -signal.SIGKILL,
                        child.stderr,
                    )
                    with file_api.LockedSweepFile.open(
                        directory,
                        name,
                        epoch,
                        self.max_bytes,
                    ) as reopened:
                        self.assertEqual(reopened.observed, self.first)
                        plan = writer.plan_recovery(
                            reopened.observed,
                            self.anchor,
                            reopened.snapshot,
                        )
                        self.assertEqual(plan["action"], "open_clean")

    def test_symlink_hardlink_permissions_and_replacement_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for name in ("", ".", "..", "../escape", "a/b", "a\\b"):
                with self.subTest(name=name):
                    with self.assertRaises(file_api.FileAdapterError):
                        file_api.LockedSweepFile.create(
                            directory,
                            name,
                            301,
                            self.max_bytes,
                        )

            root = Path(directory)
            target = root / "target"
            target.write_bytes(b"")
            target.chmod(0o600)
            (root / "symlink").symlink_to("target")
            with self.assertRaises(OSError):
                file_api.LockedSweepFile.open(
                    directory,
                    "symlink",
                    302,
                    self.max_bytes,
                )
            os.link(target, root / "hardlink")
            with self.assertRaises(file_api.FileAdapterError):
                file_api.LockedSweepFile.open(
                    directory,
                    "target",
                    302,
                    self.max_bytes,
                )

            public = root / "public"
            public.write_bytes(b"")
            public.chmod(0o644)
            with self.assertRaises(file_api.FileAdapterError):
                file_api.LockedSweepFile.open(
                    directory,
                    "public",
                    303,
                    self.max_bytes,
                )

            replaced = False

            def replace_after_body(phase: str) -> None:
                nonlocal replaced
                if phase != writer.BODY_WRITE or replaced:
                    return
                (root / "stable.records").rename(root / "moved.records")
                replacement = root / "stable.records"
                replacement.write_bytes(b"")
                replacement.chmod(0o600)
                replaced = True

            with file_api.LockedSweepFile.create(
                directory,
                "stable.records",
                304,
                self.max_bytes,
                observer=replace_after_body,
            ) as lease:
                publication = writer.Writer.open_clean(
                    lease.observed,
                    self.anchor,
                    lease.append_capability(),
                )
                with self.assertRaises(file_api.FileAdapterError):
                    publication.append_record(self.first)
                self.assertTrue(replaced)
                self.assertEqual(lease.state, "poisoned")
                self.assertEqual(publication.state, "poisoned")
                self.assertEqual(
                    (root / "stable.records").read_bytes(),
                    b"",
                )
                self.assertEqual(
                    len((root / "moved.records").read_bytes()),
                    record.BODY_BYTES,
                )


if __name__ == "__main__":
    unittest.main()
