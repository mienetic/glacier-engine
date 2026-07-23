from __future__ import annotations

import copy
import unittest

from bench import continuation_object_sweep_record as record
from bench import continuation_object_sweep_writer as writer_api


def _stream() -> bytes:
    first = record.encode(record.demo_input(0x6A, 0x6B))
    first_root = record.decode(first)["record_sha256"]
    second_input = record.demo_input(0x6B, 0x6C)
    second_input["sequence"] = 2
    second_input["previous_record_sha256"] = first_root
    return first + record.encode(second_input)


class ContinuationObjectSweepWriterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.stream = _stream()
        self.first = self.stream[: record.ENCODED_BYTES]
        self.second = self.stream[record.ENCODED_BYTES :]
        self.anchor = record.origin_recovery_anchor()

    def test_snapshot_root_and_every_recovery_plan_match_golden(self) -> None:
        snapshot = writer_api.make_snapshot(
            41,
            1,
            self.first,
            record.ENCODED_BYTES * 3,
        )
        self.assertEqual(
            snapshot["stream_sha256"].hex(),
            "3b3fb1adf8ed0b13b8e8719a3ade7db"
            "b2a7133c0ea6d307598ee3b2941d7c6d3",
        )
        self.assertEqual(
            snapshot["snapshot_sha256"].hex(),
            "b02d101a0c8152e112562ed4d70ea5b"
            "957192ba5886e35188ea8ef9a9aee3897",
        )
        for tail_length in range(record.ENCODED_BYTES + 1):
            value = self.stream[: record.ENCODED_BYTES + tail_length]
            snapshot = writer_api.make_snapshot(
                42,
                tail_length + 1,
                value,
                len(self.stream),
            )
            plan = writer_api.plan_recovery(value, self.anchor, snapshot)
            if tail_length in (0, record.ENCODED_BYTES):
                expected_action = "open_clean"
            else:
                expected_action = "repair_incomplete_tail"
            with self.subTest(tail_length=tail_length):
                self.assertEqual(plan["action"], expected_action)
                self.assertEqual(
                    plan["truncate_to_bytes"],
                    record.ENCODED_BYTES
                    if tail_length < record.ENCODED_BYTES
                    else len(self.stream),
                )

    def test_exclusive_snapshot_bound_writer_and_stale_capability(self) -> None:
        storage = writer_api.DeterministicStorage(
            self.first,
            record.ENCODED_BYTES * 3,
            43,
        )
        lease = storage.acquire()
        with self.assertRaises(writer_api.SweepWriterError):
            storage.acquire()
        capability = lease.append_capability()
        writer = writer_api.Writer.open_clean(
            storage.bytes,
            self.anchor,
            capability,
        )
        receipt = writer.append_record(self.second)
        self.assertEqual(receipt["sequence"], 2)
        self.assertEqual(receipt["committed_bytes"], len(self.stream))
        self.assertEqual(storage.bytes, self.stream)
        self.assertEqual(list(storage.trace), list(writer_api.APPEND_PHASES))
        self.assertEqual(storage.length, storage.synced_length)
        with self.assertRaises(writer_api.SweepWriterError):
            writer_api.Writer.open_clean(
                self.first,
                self.anchor,
                capability,
            )
        lease.release()
        with self.assertRaises(writer_api.SweepWriterError):
            writer_api.Writer.open_clean(storage.bytes, self.anchor, capability)

        next_lease = storage.acquire()
        changed = bytearray(storage.bytes)
        changed[0] ^= 1
        with self.assertRaises(writer_api.SweepWriterError):
            writer_api.Writer.open_clean(
                bytes(changed),
                self.anchor,
                next_lease.append_capability(),
            )
        next_lease.release()

        limited = writer_api.DeterministicStorage(
            self.first,
            record.ENCODED_BYTES + record.BODY_BYTES,
            44,
        )
        limited_lease = limited.acquire()
        limited_writer = writer_api.Writer.open_clean(
            limited.bytes,
            self.anchor,
            limited_lease.append_capability(),
        )
        with self.assertRaises(writer_api.SweepWriterError):
            limited_writer.append_record(self.second)
        self.assertEqual(limited_writer.state, "ready")
        self.assertEqual(limited.trace, [])
        limited_lease.release()

    def test_every_io_uncertainty_poisons_and_reopens_from_evidence(self) -> None:
        expected_status = (
            ("clean", "body_without_footer"),
            ("body_without_footer", "body_without_footer"),
            ("body_without_footer", "clean"),
            ("clean", "clean"),
        )
        for call_index in range(4):
            for timing_index, timing in enumerate(("before", "after")):
                storage = writer_api.DeterministicStorage(
                    self.first,
                    len(self.stream),
                    50 + call_index * 2 + timing_index,
                )
                lease = storage.acquire()
                writer = writer_api.Writer.open_clean(
                    storage.bytes,
                    self.anchor,
                    lease.append_capability(),
                )
                storage.set_fault(writer_api.Fault(call_index, timing))
                with self.assertRaises(writer_api.InjectedFault):
                    writer.append_record(self.second)
                self.assertEqual(writer.state, "poisoned")
                with self.assertRaises(writer_api.SweepWriterError):
                    writer.append_record(self.second)
                storage.crash_persist(storage.crash_bounds()[1])
                reopened = storage.acquire()
                plan = writer_api.plan_recovery(
                    storage.bytes,
                    self.anchor,
                    reopened.snapshot,
                )
                with self.subTest(call_index=call_index, timing=timing):
                    self.assertEqual(
                        plan["classification"]["status"],
                        expected_status[call_index][timing_index],
                    )
                reopened.release()

    def test_every_partial_body_and_footer_write_classifies_exactly(self) -> None:
        for prefix in range(record.BODY_BYTES + 1):
            storage = writer_api.DeterministicStorage(
                self.first,
                len(self.stream),
                1000 + prefix,
            )
            lease = storage.acquire()
            writer = writer_api.Writer.open_clean(
                storage.bytes,
                self.anchor,
                lease.append_capability(),
            )
            storage.set_fault(writer_api.Fault(0, "after", prefix))
            with self.assertRaises(writer_api.InjectedFault):
                writer.append_record(self.second)
            storage.crash_persist(storage.crash_bounds()[1])
            reopened = storage.acquire()
            plan = writer_api.plan_recovery(
                storage.bytes,
                self.anchor,
                reopened.snapshot,
            )
            if prefix == 0:
                expected = "clean"
            elif prefix < record.BODY_BYTES:
                expected = "short_body_tail"
            else:
                expected = "body_without_footer"
            with self.subTest(kind="body", prefix=prefix):
                self.assertEqual(plan["classification"]["status"], expected)
            reopened.release()

        for prefix in range(record.COMMIT_FOOTER_BYTES + 1):
            storage = writer_api.DeterministicStorage(
                self.first,
                len(self.stream),
                2000 + prefix,
            )
            lease = storage.acquire()
            writer = writer_api.Writer.open_clean(
                storage.bytes,
                self.anchor,
                lease.append_capability(),
            )
            storage.set_fault(writer_api.Fault(2, "after", prefix))
            with self.assertRaises(writer_api.InjectedFault):
                writer.append_record(self.second)
            storage.crash_persist(storage.crash_bounds()[1])
            reopened = storage.acquire()
            plan = writer_api.plan_recovery(
                storage.bytes,
                self.anchor,
                reopened.snapshot,
            )
            if prefix == 0:
                expected = "body_without_footer"
            elif prefix < record.COMMIT_FOOTER_BYTES:
                expected = "partial_footer_tail"
            else:
                expected = "clean"
            with self.subTest(kind="footer", prefix=prefix):
                self.assertEqual(plan["classification"]["status"], expected)
            reopened.release()

    def test_every_incomplete_tail_repairs_exact_prefix_then_reacquires(self) -> None:
        for tail_length in range(1, record.ENCODED_BYTES):
            storage = writer_api.DeterministicStorage(
                self.stream[: record.ENCODED_BYTES + tail_length],
                len(self.stream),
                3000 + tail_length,
            )
            lease = storage.acquire()
            stale_append = lease.append_capability()
            with self.assertRaises(writer_api.SweepWriterError):
                writer_api.Writer.open_clean(
                    storage.bytes,
                    self.anchor,
                    stale_append,
                )
            repair_capability = lease.prepare_repair(
                storage.bytes,
                self.anchor,
            )
            if tail_length == 1:
                forged = copy.copy(repair_capability)
                forged.target_bytes += 1
                with self.assertRaises(writer_api.SweepWriterError):
                    writer_api.Repairer.create(
                        storage.bytes,
                        self.anchor,
                        forged,
                    )
                self.assertEqual(storage.trace, [])
            repairer = writer_api.Repairer.create(
                storage.bytes,
                self.anchor,
                repair_capability,
            )
            receipt = repairer.apply()
            self.assertEqual(receipt["committed_bytes"], record.ENCODED_BYTES)
            self.assertEqual(receipt["discarded_tail_bytes"], tail_length)
            self.assertEqual(repairer.state, "complete")
            with self.assertRaises(writer_api.SweepWriterError):
                repairer.apply()
            with self.assertRaises(writer_api.SweepWriterError):
                writer_api.Writer.open_clean(
                    storage.bytes,
                    self.anchor,
                    stale_append,
                )
            lease.release()
            reopened = storage.acquire()
            writer = writer_api.Writer.open_clean(
                storage.bytes,
                self.anchor,
                reopened.append_capability(),
            )
            writer.append_record(self.second)
            self.assertEqual(storage.bytes, self.stream)
            reopened.release()

    def test_corruption_and_uncertain_repair_fail_closed(self) -> None:
        corrupted = bytearray(self.stream)
        corrupted[
            record.ENCODED_BYTES + record.ACCOUNTING_BEFORE_OFFSET
        ] ^= 1
        storage = writer_api.DeterministicStorage(
            bytes(corrupted), len(corrupted), 4001
        )
        lease = storage.acquire()
        plan = writer_api.plan_recovery(
            storage.bytes,
            self.anchor,
            lease.snapshot,
        )
        self.assertEqual(plan["action"], "reject_corrupt")
        before = storage.bytes
        with self.assertRaises(writer_api.SweepWriterError):
            lease.prepare_repair(storage.bytes, self.anchor)
        self.assertEqual(storage.bytes, before)
        lease.release()

        for call_index in range(2):
            for timing in ("before", "after"):
                for persist_upper in (False, True):
                    storage = writer_api.DeterministicStorage(
                        self.stream[: record.ENCODED_BYTES + 100],
                        len(self.stream),
                        4100
                        + call_index * 4
                        + (timing == "after") * 2
                        + persist_upper,
                    )
                    lease = storage.acquire()
                    repair_capability = lease.prepare_repair(
                        storage.bytes,
                        self.anchor,
                    )
                    repairer = writer_api.Repairer.create(
                        storage.bytes,
                        self.anchor,
                        repair_capability,
                    )
                    storage.set_fault(writer_api.Fault(call_index, timing))
                    with self.assertRaises(writer_api.InjectedFault):
                        repairer.apply()
                    self.assertEqual(repairer.state, "poisoned")
                    with self.assertRaises(writer_api.SweepWriterError):
                        repairer.apply()
                    lower, upper = storage.crash_bounds()
                    self.assertIn(
                        lower,
                        (record.ENCODED_BYTES, record.ENCODED_BYTES + 100),
                    )
                    self.assertIn(
                        upper,
                        (record.ENCODED_BYTES, record.ENCODED_BYTES + 100),
                    )
                    persisted = upper if persist_upper else lower
                    storage.crash_persist(persisted)
                    reopened = storage.acquire()
                    reopened_plan = writer_api.plan_recovery(
                        storage.bytes,
                        self.anchor,
                        reopened.snapshot,
                    )
                    self.assertEqual(
                        reopened_plan["action"],
                        "open_clean"
                        if persisted == record.ENCODED_BYTES
                        else "repair_incomplete_tail",
                    )
                    reopened.release()


if __name__ == "__main__":
    unittest.main()
