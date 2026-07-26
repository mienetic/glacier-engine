from __future__ import annotations

import copy
import hashlib
from pathlib import Path
import unittest

from bench import action_outbox_conformance as protocol
from bench import action_outbox_store_conformance as store


def mutate_scalar(value: object) -> object:
    if type(value) is bool:
        return not value
    if type(value) is int:
        return value + 1
    if type(value) is bytes:
        changed = bytearray(value)
        changed[0] ^= 1
        return bytes(changed)
    if type(value) is str:
        return value + "-changed"
    raise AssertionError(f"unsupported scalar mutation: {type(value)!r}")


class ActionOutboxStoreSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inputs = store.reference_inputs()

    def test_content_snapshot_binds_exact_recovery_and_capacity(self) -> None:
        initial = store.content_snapshot(
            self.inputs.encoded[: protocol.HEADER_BYTES],
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
        )
        self.assertEqual(store.STORE_ABI, initial["abi_version"])
        self.assertEqual(protocol.RECOVERY_CLEAN, initial["recovery_status"])
        self.assertEqual(protocol.HEADER_BYTES, initial["observed_bytes"])
        self.assertEqual(protocol.HEADER_BYTES, initial["committed_bytes"])
        self.assertEqual(0, initial["committed_records"])
        self.assertEqual(0, initial["discarded_tail_bytes"])
        self.assertEqual(
            initial["snapshot_sha256"],
            store.content_snapshot_sha256(initial),
        )
        self.assertEqual(
            protocol.HEADER_BYTES
            + self.inputs.header["maximum_records"] * protocol.RECORD_BYTES,
            self.inputs.maximum_bytes,
        )

        uncertain = store.content_snapshot(
            store._prefix(self.inputs, 3),  # noqa: SLF001
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
        )
        replay = protocol.recover(
            store._prefix(self.inputs, 3),  # noqa: SLF001
            self.inputs.header_sha256,
        )
        self.assertEqual(1, replay["ledger"]["uncertain_actions"])
        self.assertEqual(0, replay["ledger"]["ready_actions"])
        self.assertEqual(replay["state_sha256"], uncertain["state_sha256"])
        self.assertEqual(
            protocol.ledger_sha256(replay["ledger"]),
            uncertain["ledger_sha256"],
        )

    def test_lease_generation_fences_stale_append_authority(self) -> None:
        storage = store.DeterministicStorage(
            store._prefix(self.inputs, 0),  # noqa: SLF001
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        first = storage.acquire()
        stale = first.append_capability()
        first_root = first.binding["lease_sha256"]
        first.release()
        with self.assertRaises(store.ActionOutboxStoreError):
            stale.validate()

        second = storage.acquire()
        self.assertNotEqual(first_root, second.binding["lease_sha256"])
        self.assertEqual(2, second.binding["lease_generation"])
        second.release()

    def test_invalid_preflight_does_not_begin_storage_io(self) -> None:
        initial = store._prefix(self.inputs, 0)  # noqa: SLF001
        storage = store.DeterministicStorage(
            initial,
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        lease = storage.acquire()
        writer = store.Writer(lease.append_capability(), self.inputs.header)
        with self.assertRaises(protocol.ActionOutboxError):
            writer.append_record(self.inputs.record_bytes[1])
        self.assertEqual("ready", writer.state)
        self.assertEqual([], storage.trace)
        self.assertEqual(initial, storage.bytes)
        lease.release()

    def test_snapshot_lease_and_repair_plan_mutations_reject(self) -> None:
        torn = (
            store._prefix(self.inputs, 3)  # noqa: SLF001
            + self.inputs.record_bytes[3][: protocol.RECORD_BODY_BYTES + 7]
        )
        storage = store.DeterministicStorage(
            torn,
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        lease = storage.acquire()
        capability = lease.prepare_repair()
        cases = (
            (
                lease.snapshot,
                store.validate_content_snapshot,
            ),
            (
                lease.binding,
                store.validate_lease_binding,
            ),
            (
                capability.plan,
                store.validate_repair_plan,
            ),
        )
        for value, validator in cases:
            for name, field in value.items():
                changed = copy.deepcopy(value)
                changed[name] = mutate_scalar(field)
                with self.subTest(fields=tuple(value), field=name):
                    with self.assertRaises(store.ActionOutboxStoreError):
                        validator(changed)
            reordered = dict(reversed(tuple(value.items())))
            with self.assertRaises(store.ActionOutboxStoreError):
                validator(reordered)

    def test_semantically_invalid_resealed_roots_reject(self) -> None:
        clean = store.content_snapshot(
            store._prefix(self.inputs, 0),  # noqa: SLF001
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
        )
        invalid_tail = copy.deepcopy(clean)
        invalid_tail["observed_bytes"] += 1
        invalid_tail["discarded_tail_bytes"] = 1
        invalid_tail["snapshot_sha256"] = store.content_snapshot_sha256(invalid_tail)
        with self.assertRaises(store.ActionOutboxStoreError):
            store.validate_content_snapshot(invalid_tail)

        invalid_frame = copy.deepcopy(clean)
        invalid_frame["observed_bytes"] += 1
        invalid_frame["committed_bytes"] += 1
        invalid_frame["snapshot_sha256"] = store.content_snapshot_sha256(invalid_frame)
        with self.assertRaises(store.ActionOutboxStoreError):
            store.validate_content_snapshot(invalid_frame)

        zero_stream = copy.deepcopy(clean)
        zero_stream["stream_sha256"] = store.ZERO_DIGEST
        with self.assertRaises(store.ActionOutboxStoreError):
            store.validate_content_snapshot(zero_stream)

        torn = (
            store._prefix(self.inputs, 3)  # noqa: SLF001
            + self.inputs.record_bytes[3][: protocol.RECORD_BODY_BYTES]
        )
        storage = store.DeterministicStorage(
            torn,
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        lease = storage.acquire()
        invalid_plan = copy.deepcopy(lease.prepare_repair().plan)
        invalid_plan["observed_bytes"] -= protocol.RECORD_BODY_BYTES - 1
        invalid_plan["discarded_tail_bytes"] = 1
        invalid_plan["plan_sha256"] = store.repair_plan_sha256(invalid_plan)
        with self.assertRaises(store.ActionOutboxStoreError):
            store.validate_repair_plan(invalid_plan)
        lease.release()


class ActionOutboxStoreAppendFaultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inputs = store.reference_inputs()
        cls.initial = store._prefix(cls.inputs, 3)  # noqa: SLF001
        cls.record = cls.inputs.record_bytes[3]

    def _faulted_snapshot(
        self,
        call_index: int,
        *,
        write_prefix: int | None = None,
    ) -> tuple[store.Writer, store.Record]:
        storage = store.DeterministicStorage(
            self.initial,
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        lease = storage.acquire()
        writer = store.Writer(lease.append_capability(), self.inputs.header)
        storage.set_fault(store.Fault(call_index, store.TIMING_AFTER, write_prefix))
        with self.assertRaises(store.InjectedFault):
            writer.append_record(self.record)
        persisted = storage.crash_bounds()[1]
        storage.crash_persist(persisted)
        reopened = storage.acquire()
        return writer, reopened.snapshot

    def test_each_append_phase_reopens_from_bytes_not_phase_name(self) -> None:
        for call_index, phase in enumerate(store.APPEND_PHASES):
            writer, snapshot = self._faulted_snapshot(call_index)
            with self.subTest(phase=phase):
                self.assertEqual("poisoned", writer.state)
                if phase in {store.BODY_WRITE, store.BODY_SYNC}:
                    self.assertEqual(
                        protocol.RECOVERY_BODY_WITHOUT_FOOTER,
                        snapshot["recovery_status"],
                    )
                    self.assertEqual(3, snapshot["committed_records"])
                    recovery = protocol.recover(
                        self.initial,
                        self.inputs.header_sha256,
                    )
                    self.assertEqual(
                        recovery["state_sha256"],
                        snapshot["state_sha256"],
                    )
                    self.assertEqual(
                        protocol.RECORD_BODY_BYTES,
                        snapshot["discarded_tail_bytes"],
                    )
                else:
                    self.assertEqual(
                        protocol.RECOVERY_CLEAN,
                        snapshot["recovery_status"],
                    )
                    self.assertEqual(4, snapshot["committed_records"])
                    recovery = protocol.recover(
                        store._prefix(self.inputs, 4),  # noqa: SLF001
                        self.inputs.header_sha256,
                    )
                    self.assertEqual(
                        recovery["state_sha256"],
                        snapshot["state_sha256"],
                    )

    def test_partial_body_and_footer_boundaries_preserve_uncertainty(self) -> None:
        body_cases = {
            0: protocol.RECOVERY_CLEAN,
            1: protocol.RECOVERY_SHORT_BODY_TAIL,
            protocol.RECORD_BODY_BYTES - 1: protocol.RECOVERY_SHORT_BODY_TAIL,
            protocol.RECORD_BODY_BYTES: protocol.RECOVERY_BODY_WITHOUT_FOOTER,
        }
        for prefix, expected_status in body_cases.items():
            _, snapshot = self._faulted_snapshot(0, write_prefix=prefix)
            with self.subTest(section="body", prefix=prefix):
                self.assertEqual(expected_status, snapshot["recovery_status"])
                self.assertEqual(3, snapshot["committed_records"])

        footer_cases = {
            0: protocol.RECOVERY_BODY_WITHOUT_FOOTER,
            1: protocol.RECOVERY_PARTIAL_FOOTER_TAIL,
            protocol.COMMIT_FOOTER_BYTES - 1: (protocol.RECOVERY_PARTIAL_FOOTER_TAIL),
            protocol.COMMIT_FOOTER_BYTES: protocol.RECOVERY_CLEAN,
        }
        for prefix, expected_status in footer_cases.items():
            _, snapshot = self._faulted_snapshot(2, write_prefix=prefix)
            with self.subTest(section="footer", prefix=prefix):
                self.assertEqual(expected_status, snapshot["recovery_status"])
                self.assertEqual(
                    4 if prefix == protocol.COMMIT_FOOTER_BYTES else 3,
                    snapshot["committed_records"],
                )

    def test_clean_writer_rotates_snapshot_for_multiple_records(self) -> None:
        storage = store.DeterministicStorage(
            store._prefix(self.inputs, 0),  # noqa: SLF001
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        lease = storage.acquire()
        writer = store.Writer(lease.append_capability(), self.inputs.header)
        snapshots = []
        for sequence, encoded_record in enumerate(
            self.inputs.record_bytes,
            start=1,
        ):
            receipt = writer.append_record(encoded_record)
            self.assertEqual(sequence, receipt["sequence"])
            snapshots.append(lease.snapshot["snapshot_sha256"])
        self.assertEqual(len(snapshots), len(set(snapshots)))
        self.assertEqual(self.inputs.encoded, storage.bytes)
        self.assertEqual(10, lease.snapshot["committed_records"])
        lease.release()


class ActionOutboxStoreRepairTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inputs = store.reference_inputs()
        cls.initial = store._prefix(cls.inputs, 3)  # noqa: SLF001
        cls.record = cls.inputs.record_bytes[3]

    def test_each_tail_class_requires_explicit_repair_and_fresh_reopen(self) -> None:
        tails = (
            1,
            protocol.RECORD_BODY_BYTES - 1,
            protocol.RECORD_BODY_BYTES,
            protocol.RECORD_BODY_BYTES + 1,
            protocol.RECORD_BYTES - 1,
        )
        for tail in tails:
            storage = store.DeterministicStorage(
                self.initial + self.record[:tail],
                self.inputs.header_sha256,
                self.inputs.maximum_bytes,
                self.inputs.storage_epoch,
            )
            lease = storage.acquire()
            with self.subTest(tail=tail):
                with self.assertRaises(store.ActionOutboxStoreError):
                    lease.append_capability()
                capability = lease.prepare_repair()
                receipt = store.Repairer(capability).apply()
                self.assertEqual(tail, receipt["discarded_tail_bytes"])
                self.assertEqual(len(self.initial), receipt["committed_bytes"])
                with self.assertRaises(store.ActionOutboxStoreError):
                    lease.append_capability()
                lease.release()
                reopened = storage.acquire()
                self.assertEqual(
                    protocol.RECOVERY_CLEAN,
                    reopened.snapshot["recovery_status"],
                )
                writer = store.Writer(
                    reopened.append_capability(),
                    self.inputs.header,
                )
                writer.append_record(self.record)
                self.assertEqual(
                    store._prefix(self.inputs, 4),  # noqa: SLF001
                    storage.bytes,
                )
                reopened.release()

    def test_clean_and_corrupt_complete_storage_never_receive_repair(self) -> None:
        clean_storage = store.DeterministicStorage(
            self.initial,
            self.inputs.header_sha256,
            self.inputs.maximum_bytes,
            self.inputs.storage_epoch,
        )
        clean = clean_storage.acquire()
        with self.assertRaises(store.ActionOutboxStoreError):
            clean.prepare_repair()
        clean.release()

        corrupt = bytearray(self.initial + self.record)
        corrupt[-protocol.COMMIT_FOOTER_BYTES] ^= 1
        with self.assertRaises(protocol.ActionOutboxError):
            store.DeterministicStorage(
                bytes(corrupt),
                self.inputs.header_sha256,
                self.inputs.maximum_bytes,
                self.inputs.storage_epoch,
            )

    def test_repair_fault_bounds_reopen_only_clean_or_same_repairable_tail(
        self,
    ) -> None:
        torn = self.initial + self.record[: protocol.RECORD_BODY_BYTES + 7]
        for call_index, phase in enumerate(store.REPAIR_PHASES):
            for timing in store.FAULT_TIMINGS:
                for persistence in store.PERSIST_CHOICES:
                    storage = store.DeterministicStorage(
                        torn,
                        self.inputs.header_sha256,
                        self.inputs.maximum_bytes,
                        self.inputs.storage_epoch,
                    )
                    lease = storage.acquire()
                    repairer = store.Repairer(lease.prepare_repair())
                    storage.set_fault(store.Fault(call_index, timing))
                    with self.assertRaises(store.InjectedFault):
                        repairer.apply()
                    self.assertEqual("poisoned", repairer.state)
                    lower, upper = storage.crash_bounds()
                    persisted = lower if persistence == store.PERSIST_LOWER else upper
                    storage.crash_persist(persisted)
                    reopened = storage.acquire()
                    with self.subTest(
                        phase=phase,
                        timing=timing,
                        persistence=persistence,
                    ):
                        self.assertIn(
                            reopened.snapshot["recovery_status"],
                            {
                                protocol.RECOVERY_CLEAN,
                                protocol.RECOVERY_PARTIAL_FOOTER_TAIL,
                            },
                        )
                        self.assertIn(
                            reopened.snapshot["observed_bytes"],
                            {len(self.initial), len(torn)},
                        )
                    reopened.release()


class ActionOutboxStoreReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inputs = store.reference_inputs()
        cls.report = store.build_report()

    def test_report_replays_all_deterministic_case_families(self) -> None:
        self.assertEqual(40, self.report["append_phase_case_count"])
        self.assertEqual(754, self.report["partial_write_case_count"])
        self.assertEqual(751, self.report["repair_tail_case_count"])
        self.assertEqual(8, self.report["repair_fault_case_count"])
        self.assertEqual(
            hashlib.sha256(self.inputs.encoded).hexdigest(),
            self.report["journal_sha256"],
        )
        self.assertEqual(
            self.inputs.protocol_report["report_sha256"],
            self.report["protocol_report_sha256"],
        )
        self.assertEqual(
            self.report["report_sha256"],
            store.semantic_report_sha256(self.report).hex(),
        )

    def test_retained_fixture_is_canonical_and_byte_equal(self) -> None:
        fixture = (
            Path(__file__).resolve().parents[1]
            / "results"
            / "action-outbox-store-conformance-v1.json"
        )
        retained = fixture.read_bytes()
        expected = store.render_report(self.report).encode("ascii")
        self.assertEqual(expected, retained)
        decoded = store.load_json_exact(retained, "retained fixture")
        self.assertEqual(self.report, store.validate_report(decoded))

    def test_report_mutation_and_semantic_reroot_reject(self) -> None:
        for name, value in self.report.items():
            changed = copy.deepcopy(self.report)
            if isinstance(value, list):
                changed[name] = list(reversed(value))
            elif isinstance(value, dict):
                first = next(iter(value))
                changed[name][first] += 1
            else:
                changed[name] = mutate_scalar(value)
            with self.subTest(field=name):
                with self.assertRaises(store.ActionOutboxStoreError):
                    store.validate_report(changed)

        rerooted = copy.deepcopy(self.report)
        rerooted["ledger"]["safe_retry_dispatches"] += 1
        rerooted["report_sha256"] = store.semantic_report_sha256(rerooted).hex()
        with self.assertRaises(store.ActionOutboxStoreError):
            store.validate_report(rerooted)

    def test_report_excludes_host_filesystem_observations(self) -> None:
        forbidden = {
            "device",
            "directory",
            "filesystem",
            "flock",
            "fsync",
            "host",
            "inode",
            "latency",
            "operating_system",
            "path",
            "pid",
            "power_loss",
        }
        self.assertTrue(forbidden.isdisjoint(self.report))

    def test_duplicate_float_and_noncanonical_json_reject(self) -> None:
        invalid = (
            b'{"a":1,"a":1}\n',
            b'{"a":1.0}\n',
            b'{"a":NaN}\n',
            b'{"a":-0}\n',
            b'{"a":1, "b":2}\n',
            b'{"a":1}\n\n',
            b'{"a":1}',
            b'["not","an","object"]\n',
            b'{"a":"\xff"}\n',
            b"",
        )
        for encoded in invalid:
            with self.subTest(encoded=encoded):
                with self.assertRaises(store.ActionOutboxStoreError):
                    store.load_json_exact(encoded, "mutation")


if __name__ == "__main__":
    unittest.main()
