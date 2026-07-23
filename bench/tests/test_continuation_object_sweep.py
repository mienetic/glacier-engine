from __future__ import annotations

import unittest

from bench import continuation_bundle as bundle
from bench import continuation_capsule as capsule
from bench import continuation_object_collection as collection
from bench import continuation_object_store as object_store
from bench import continuation_object_sweep as sweep


class ContinuationObjectSweepTests(unittest.TestCase):
    def setUp(self) -> None:
        demo = object_store.build_demo()
        self.bundle = demo["bundle"]
        self.store_grant = demo["grant"]
        self.store = object_store.Store(
            self.store_grant,
            self.store_grant["authority_epoch"],
        )
        self.store.import_bundle(
            self.bundle["encoded"],
            self.bundle["bundle_config"],
            self.bundle["capsule_wire"],
            self.bundle["objects"],
        )
        manifest = bundle.decode_manifest(self.bundle["encoded"])
        self.entries = manifest["entries"]
        self.model = self.key(0)
        self.lane = self.key(4)
        self.kv = self.key(5)
        lifecycle = object_store.demo_lifecycle_grant(self.store_grant)
        self.lease = self.store.acquire_lease(
            self.model,
            lifecycle,
            bytes((0x71,)) * 32,
            100,
            120,
        )
        self.store.retire(self.kv)
        self.store.quarantine(self.lane, bytes((0x9A,)) * 32)
        self.roots = collection.canonical_roots(
            [
                self.key(index)
                for index in range(len(capsule.OBJECT_NAMES))
                if index != 5
            ]
        )
        self.leases = collection.canonical_lease_receipts([self.lease])
        self.collection_grant = collection.demo_grant(self.store)
        self.collection_receipt, _ = collection.plan_collection(
            self.store,
            self.collection_grant,
            self.roots,
            self.leases,
        )
        self.sweep_grant = sweep.demo_grant(
            self.store,
            self.collection_receipt["plan_sha256"],
        )

    def key(self, entry_index: int) -> dict[str, object]:
        entry = self.entries[entry_index]
        return {
            "byte_length": entry["byte_length"],
            "sha256": entry["blob_sha256"],
        }

    def prepare(self) -> tuple[dict[str, object], ...]:
        return sweep.prepare(
            self.store,
            self.sweep_grant,
            self.collection_grant,
            self.roots,
            self.leases,
            sweep.empty_journal(),
        )

    def test_prepare_and_abort_are_functional_and_store_preserving(self) -> None:
        snapshot_before = self.store.audit_snapshot_root_v2()
        payload_before = self.store.payload_bytes
        current = sweep.empty_journal()
        journal, receipt, regenerated = sweep.prepare(
            self.store,
            self.sweep_grant,
            self.collection_grant,
            self.roots,
            self.leases,
            current,
        )
        self.assertEqual(current, sweep.empty_journal())
        self.assertEqual(journal["state"], "prepared")
        self.assertEqual(
            (receipt["staged_entries"], receipt["staged_bytes"]),
            (1, 30),
        )
        self.assertEqual(
            regenerated["plan_sha256"],
            self.collection_receipt["plan_sha256"],
        )
        sweep.verify_journal(self.sweep_grant, journal)
        aborted, abort_receipt = sweep.abort(
            self.store,
            self.sweep_grant,
            journal,
        )
        self.assertEqual(journal["state"], "prepared")
        self.assertEqual(aborted["state"], "aborted")
        self.assertEqual(
            aborted["abort_sha256"],
            abort_receipt["abort_sha256"],
        )
        sweep.verify_journal(self.sweep_grant, aborted)
        with self.assertRaises(sweep.SweepError):
            sweep.abort(self.store, self.sweep_grant, aborted)
        self.assertEqual(snapshot_before, self.store.audit_snapshot_root_v2())
        self.assertEqual(payload_before, self.store.payload_bytes)

    def test_cross_language_grant_prepare_and_abort_roots(self) -> None:
        journal, receipt, _ = self.prepare()
        aborted, abort_receipt = sweep.abort(
            self.store,
            self.sweep_grant,
            journal,
        )
        actual = {
            "grant": sweep.grant_root(self.sweep_grant).hex(),
            "prepare": receipt["prepare_sha256"].hex(),
            "abort": abort_receipt["abort_sha256"].hex(),
            "journal_bytes": 184,
            "staged_bytes": aborted["staged_bytes"],
        }
        expected = {
            "grant": (
                "062021af17762a0d259073ce5bb2bcf3"
                "860d146f621b86d2149efcd7a615612c"
            ),
            "prepare": (
                "4e660266135b3a4aa7f5116fffb8191e"
                "f4c931e479320fbfd6366abbe5999474"
            ),
            "abort": (
                "603535a93206cfafcee6a1a58c58cb97"
                "de21c94e0e433f184bd9a9ee09513c1e"
            ),
            "journal_bytes": 184,
            "staged_bytes": 30,
        }
        self.assertEqual(actual, expected)

    def test_scope_plan_snapshot_and_budget_fail_closed(self) -> None:
        mutations = (
            ("bundle_sha256", bytes((0x44,)) * 32),
            ("collection_plan_sha256", bytes((0x45,)) * 32),
            ("expected_snapshot_sha256", bytes((0x46,)) * 32),
            ("max_staged_entries", 0),
            ("max_staged_bytes", 29),
        )
        for name, value in mutations:
            with self.subTest(grant_field=name):
                grant = dict(self.sweep_grant)
                grant[name] = value
                with self.assertRaises(
                    (
                        sweep.SweepError,
                        collection.CollectionError,
                    )
                ):
                    sweep.prepare(
                        self.store,
                        grant,
                        self.collection_grant,
                        self.roots,
                        self.leases,
                        sweep.empty_journal(),
                    )

    def test_prepare_regenerates_root_and_lease_evidence(self) -> None:
        with self.assertRaises(collection.CollectionError):
            sweep.prepare(
                self.store,
                self.sweep_grant,
                self.collection_grant,
                self.roots[:-1],
                self.leases,
                sweep.empty_journal(),
            )
        with self.assertRaises(collection.CollectionError):
            sweep.prepare(
                self.store,
                self.sweep_grant,
                self.collection_grant,
                self.roots,
                [],
                sweep.empty_journal(),
            )

    def test_journal_tamper_replay_and_stale_abort_fail_closed(self) -> None:
        journal, _, _ = self.prepare()
        with self.assertRaises(sweep.SweepError):
            sweep.prepare(
                self.store,
                self.sweep_grant,
                self.collection_grant,
                self.roots,
                self.leases,
                journal,
            )
        with self.assertRaises(sweep.SweepError):
            sweep.abort(
                self.store,
                self.sweep_grant,
                sweep.empty_journal(),
            )
        tampered = dict(journal)
        tampered["staged_bytes"] += 1
        with self.assertRaises(sweep.SweepError):
            sweep.abort(self.store, self.sweep_grant, tampered)
        self.store.release(self.roots[0])
        with self.assertRaises(sweep.SweepError):
            sweep.abort(self.store, self.sweep_grant, journal)

    def test_valid_plan_without_collectible_entries_rejects(self) -> None:
        demo = object_store.build_demo()
        store = object_store.Store(
            demo["grant"],
            demo["grant"]["authority_epoch"],
        )
        store.import_bundle(
            demo["bundle"]["encoded"],
            demo["bundle"]["bundle_config"],
            demo["bundle"]["capsule_wire"],
            demo["bundle"]["objects"],
        )
        manifest = bundle.decode_manifest(demo["bundle"]["encoded"])
        roots = collection.canonical_roots(
            [
                {
                    "byte_length": entry["byte_length"],
                    "sha256": entry["blob_sha256"],
                }
                for entry in manifest["entries"]
            ]
        )
        collection_grant = collection.demo_grant(store)
        receipt, _ = collection.plan_collection(
            store,
            collection_grant,
            roots,
            [],
        )
        sweep_grant = sweep.demo_grant(store, receipt["plan_sha256"])
        with self.assertRaises(sweep.SweepError):
            sweep.prepare(
                store,
                sweep_grant,
                collection_grant,
                roots,
                [],
                sweep.empty_journal(),
            )


if __name__ == "__main__":
    unittest.main()
