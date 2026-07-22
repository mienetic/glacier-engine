from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from bench import provider_cost_journal as journal
from bench import provider_cost_journal_store as store_api


def _frame(encoded: bytes, index: int) -> bytes:
    start = journal.HEADER_BYTES + index * journal.FRAME_BYTES
    return encoded[start : start + journal.FRAME_BYTES]


class ProviderCostJournalStoreTests(unittest.TestCase):
    def test_locked_writer_creates_appends_and_reopens_exact_bytes(self) -> None:
        header, encoded, final_root = journal.build_demo_journal()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cost.journal"
            with store_api.LockedStore.create(
                directory, "cost.journal", header
            ) as store:
                self.assertIn(
                    store.directory_sync_status,
                    ("synced", "unsupported"),
                )
                lock_attempt = subprocess.run(
                    (
                        sys.executable,
                        "-m",
                        "bench.provider_cost_journal_store",
                        "_child-try-lock",
                        directory,
                        "cost.journal",
                        header["header_sha256"].hex(),
                    ),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    lock_attempt.returncode,
                    store_api.LOCK_HELD_EXIT,
                    lock_attempt.stderr,
                )
                for index in range(3):
                    receipt = store.append_frame(_frame(encoded, index))
                    self.assertEqual(receipt["sequence"], index + 1)
                    self.assertTrue(receipt["body_sync_exercised"])
                    self.assertTrue(receipt["footer_sync_exercised"])
                self.assertEqual(bytes(store.encoded), encoded)
            self.assertEqual(path.read_bytes(), encoded)

            with store_api.LockedStore.open(
                directory,
                "cost.journal",
                header["header_sha256"],
            ) as reopened:
                self.assertEqual(reopened.recovered["status"], "clean")
                self.assertFalse(reopened.repair_sync_exercised)
                self.assertEqual(reopened.recovered["final_chain_sha256"], final_root)
                self.assertEqual(reopened.recovered["ledger"]["committed_frames"], 3)

            with self.assertRaises(FileExistsError):
                store_api.LockedStore.create(directory, "cost.journal", header)
            with self.assertRaises(store_api.StoreError):
                store_api.LockedStore.create(directory, "../escape.journal", header)
            invalid_header = dict(header)
            invalid_header["journal_epoch"] = 0
            with self.assertRaises(journal.JournalError):
                store_api.LockedStore.create(
                    directory,
                    "invalid.journal",
                    invalid_header,
                )
            self.assertFalse((Path(directory) / "invalid.journal").exists())

    def test_subprocess_death_at_every_sync_phase_recovers_exact_prefix(self) -> None:
        header, encoded, _ = journal.build_demo_journal()
        body_phases = {
            store_api.AFTER_BODY_WRITE,
            store_api.AFTER_BODY_SYNC,
        }
        with tempfile.TemporaryDirectory() as directory:
            for frame_index in range(3):
                for phase in store_api.APPEND_PHASES:
                    name = f"crash-{frame_index}-{phase}.journal"
                    with store_api.LockedStore.create(
                        directory, name, header
                    ) as initial:
                        for prior_index in range(frame_index):
                            initial.append_frame(_frame(encoded, prior_index))

                    child = subprocess.run(
                        (
                            sys.executable,
                            "-m",
                            "bench.provider_cost_journal_store",
                            "_child-append",
                            directory,
                            name,
                            header["header_sha256"].hex(),
                            str(frame_index),
                            phase,
                        ),
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        child.returncode,
                        -store_api.CHILD_SIGNAL,
                        child.stderr,
                    )

                    if phase in body_phases:
                        with self.assertRaises(store_api.StoreError):
                            store_api.LockedStore.open(
                                directory,
                                name,
                                header["header_sha256"],
                                repair_torn_tail=False,
                            )
                    with store_api.LockedStore.open(
                        directory,
                        name,
                        header["header_sha256"],
                    ) as recovered:
                        committed_frames = frame_index
                        if phase not in body_phases:
                            committed_frames += 1
                        expected_end = (
                            journal.HEADER_BYTES
                            + committed_frames * journal.FRAME_BYTES
                        )
                        expected = encoded[:expected_end]
                        expected_recovery = journal.recover(
                            expected, header["header_sha256"]
                        )
                        self.assertEqual(bytes(recovered.encoded), expected)
                        self.assertEqual(
                            recovered.recovered["ledger"],
                            expected_recovery["ledger"],
                        )
                        self.assertEqual(
                            recovered.recovered["final_chain_sha256"],
                            expected_recovery["final_chain_sha256"],
                        )
                        if phase in body_phases:
                            self.assertEqual(recovered.recovered["status"], "torn_tail")
                            self.assertEqual(
                                recovered.recovered["discarded_tail_bytes"],
                                journal.FRAME_BODY_BYTES,
                            )
                            self.assertTrue(recovered.repair_sync_exercised)
                        else:
                            self.assertEqual(recovered.recovered["status"], "clean")
                            self.assertFalse(recovered.repair_sync_exercised)
                    self.assertEqual((Path(directory) / name).read_bytes(), expected)

    def test_uncertain_append_poison_and_committed_corruption_fail_closed(self) -> None:
        header, encoded, _ = journal.build_demo_journal()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "corrupt.journal"
            store = store_api.LockedStore.create(directory, "corrupt.journal", header)
            with self.assertRaises(store_api.InjectedFault):
                store.append_frame(
                    _frame(encoded, 0),
                    fault_after_phase=store_api.AFTER_BODY_SYNC,
                )
            self.assertEqual(store.state, "poisoned")
            with self.assertRaises(store_api.StoreError):
                store.append_frame(_frame(encoded, 0))
            store.close()
            with store_api.LockedStore.open(
                directory,
                "corrupt.journal",
                header["header_sha256"],
            ) as repaired:
                self.assertTrue(repaired.repair_sync_exercised)
                for index in range(3):
                    repaired.append_frame(_frame(encoded, index))

            corrupt_offset = len(encoded) - journal.COMMIT_FOOTER_BYTES
            with path.open("r+b", buffering=0) as corrupt_file:
                corrupt_file.seek(corrupt_offset)
                original = corrupt_file.read(1)
                self.assertEqual(len(original), 1)
                corrupt_file.seek(corrupt_offset)
                corrupt_file.write(bytes((original[0] ^ 1,)))
                os.fsync(corrupt_file.fileno())
            before = path.read_bytes()
            with self.assertRaises(journal.JournalError):
                store_api.LockedStore.open(
                    directory,
                    "corrupt.journal",
                    header["header_sha256"],
                )
            self.assertEqual(path.read_bytes(), before)

            with self.assertRaises(journal.JournalError):
                store_api.LockedStore.open(
                    directory,
                    "corrupt.journal",
                    bytes((0xA7,)) * 32,
                )
            self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
