from __future__ import annotations

import copy
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

    def commit_fixture(self) -> dict[str, object]:
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

        def key(index: int) -> dict[str, object]:
            entry = manifest["entries"][index]
            return {
                "byte_length": entry["byte_length"],
                "sha256": entry["blob_sha256"],
            }

        lifecycle = object_store.demo_lifecycle_grant(demo["grant"])
        lease = store.acquire_lease(
            key(0),
            lifecycle,
            bytes((0x71,)) * 32,
            100,
            120,
        )
        retired = key(8)
        store.retire(retired)
        store.quarantine(key(4), bytes((0x9A,)) * 32)
        roots = collection.canonical_roots(
            [key(index) for index in range(len(capsule.OBJECT_NAMES) - 1)]
        )
        leases = collection.canonical_lease_receipts([lease])
        collection_grant = collection.demo_grant(store)
        plan, _ = collection.plan_collection(
            store,
            collection_grant,
            roots,
            leases,
        )
        sweep_grant = sweep.demo_grant(store, plan["plan_sha256"])
        prepared, _, _ = sweep.prepare(
            store,
            sweep_grant,
            collection_grant,
            roots,
            leases,
            sweep.empty_journal(),
        )
        commit_grant = sweep.demo_commit_grant(
            store,
            sweep_grant,
            prepared,
        )
        return {
            "store": store,
            "roots": roots,
            "leases": leases,
            "retired": retired,
            "collection_grant": collection_grant,
            "sweep_grant": sweep_grant,
            "prepared": prepared,
            "commit_grant": commit_grant,
        }

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

    def test_commit_frees_exact_retired_target_and_roots_match(self) -> None:
        fixture = self.commit_fixture()
        store = fixture["store"]
        self.assertIsInstance(store, object_store.Store)
        receipt, store_receipt = sweep.commit(
            store,
            fixture["sweep_grant"],
            fixture["commit_grant"],
            fixture["collection_grant"],
            fixture["roots"],
            fixture["leases"],
            fixture["prepared"],
        )
        sweep.verify_commit_receipt(
            fixture["commit_grant"],
            receipt,
            store_receipt,
        )
        store.verify_all()
        self.assertEqual(
            (
                receipt["freed_entries"],
                receipt["freed_payload_bytes"],
                receipt["freed_index_bytes"],
                receipt["freed_repair_count"],
                receipt["allocator_deallocation_calls"],
            ),
            (1, 39, 128, 0, 1),
        )
        self.assertEqual(
            (store.entry_count, store.retired_entries, store.payload_bytes),
            (7, 0, 216),
        )
        with self.assertRaises(object_store.StoreError):
            store.get(fixture["retired"])
        actual = {
            "commit_grant": sweep.commit_grant_root(
                fixture["commit_grant"]
            ).hex(),
            "targets": store_receipt["targets_sha256"].hex(),
            "store_commit": store_receipt["commit_sha256"].hex(),
            "commit": receipt["commit_sha256"].hex(),
            "snapshot_after": receipt["snapshot_after_sha256"].hex(),
        }
        expected = {
            "commit_grant": (
                "4bb165e6809e00403cc17997d3bdbcc1"
                "3787c051d895b4ff7eadde9d24991d3e"
            ),
            "targets": (
                "d5e185b91d3aae5e6d96f249c69cc59"
                "b213e9cdd43717669fee2192d2752988e"
            ),
            "store_commit": (
                "4dc638ad333478ba67e7273f6bdd3e5c"
                "3bb7b82c2b3df0fef0d7ad3aa22a2c88"
            ),
            "commit": (
                "e40010e0a26dbfe6cd94ecfdb3b1fbf"
                "49b9b3f4421b1cf40247fa6304ad309b5"
            ),
            "snapshot_after": (
                "2e537f05538bcb1ef378a600f55fd1bc"
                "f35c85c9c1f4185cb908a128ec147ab2"
            ),
        }
        self.assertEqual(actual, expected)
        contradictory_store_receipt = copy.deepcopy(store_receipt)
        contradictory_store_receipt["accounting_after"][
            "payload_bytes"
        ] += 1
        contradictory_store_receipt["commit_sha256"] = (
            object_store.retired_commit_receipt_root(
                contradictory_store_receipt
            )
        )
        contradictory_receipt = dict(receipt)
        contradictory_receipt["store_commit_sha256"] = (
            contradictory_store_receipt["commit_sha256"]
        )
        contradictory_receipt["commit_sha256"] = sweep.commit_root(
            contradictory_receipt
        )
        with self.assertRaises(sweep.SweepError):
            sweep.verify_commit_receipt(
                fixture["commit_grant"],
                contradictory_receipt,
                contradictory_store_receipt,
            )
        with self.assertRaises(collection.CollectionError):
            sweep.commit(
                store,
                fixture["sweep_grant"],
                fixture["commit_grant"],
                fixture["collection_grant"],
                fixture["roots"],
                fixture["leases"],
                fixture["prepared"],
            )

    def test_commit_scope_evidence_targets_and_budgets_fail_closed(self) -> None:
        fixture = self.commit_fixture()
        store = fixture["store"]
        self.assertIsInstance(store, object_store.Store)
        snapshot_before = store.audit_snapshot_root_v2()
        mutations = (
            ("bundle_sha256", bytes((0x44,)) * 32),
            ("prepare_sha256", bytes((0x45,)) * 32),
            ("collection_plan_sha256", bytes((0x46,)) * 32),
            ("max_freed_entries", 0),
            ("max_freed_bytes", 38),
        )
        for name, value in mutations:
            with self.subTest(commit_grant_field=name):
                grant = dict(fixture["commit_grant"])
                grant[name] = value
                with self.assertRaises(
                    (sweep.SweepError, collection.CollectionError)
                ):
                    sweep.commit(
                        store,
                        fixture["sweep_grant"],
                        grant,
                        fixture["collection_grant"],
                        fixture["roots"],
                        fixture["leases"],
                        fixture["prepared"],
                    )
        with self.assertRaises(collection.CollectionError):
            sweep.commit(
                store,
                fixture["sweep_grant"],
                fixture["commit_grant"],
                fixture["collection_grant"],
                fixture["roots"][:-1],
                fixture["leases"],
                fixture["prepared"],
            )
        with self.assertRaises(collection.CollectionError):
            sweep.commit(
                store,
                fixture["sweep_grant"],
                fixture["commit_grant"],
                fixture["collection_grant"],
                fixture["roots"],
                [],
                fixture["prepared"],
            )
        tampered = dict(fixture["prepared"])
        tampered["staged_bytes"] += 1
        with self.assertRaises(sweep.SweepError):
            sweep.commit(
                store,
                fixture["sweep_grant"],
                fixture["commit_grant"],
                fixture["collection_grant"],
                fixture["roots"],
                fixture["leases"],
                tampered,
            )
        permit = {
            "authority_epoch": fixture["commit_grant"]["authority_epoch"],
            "tenant_scope_sha256": fixture["commit_grant"][
                "tenant_scope_sha256"
            ],
            "bundle_sha256": fixture["commit_grant"]["bundle_sha256"],
            "store_grant_sha256": fixture["commit_grant"][
                "store_grant_sha256"
            ],
            "expected_snapshot_sha256": fixture["commit_grant"][
                "expected_snapshot_sha256"
            ],
            "authorization_sha256": sweep.commit_grant_root(
                fixture["commit_grant"]
            ),
            "max_freed_entries": 2,
            "max_freed_bytes": 128,
        }
        with self.assertRaises(object_store.StoreError):
            store.commit_retired(
                permit,
                [fixture["retired"], fixture["retired"]],
            )
        with self.assertRaises(object_store.StoreError):
            store.commit_retired(permit, [fixture["roots"][0]])
        with self.assertRaises(object_store.StoreError):
            store.commit_retired(
                permit,
                collection.canonical_roots(
                    [fixture["retired"], fixture["roots"][0]]
                ),
            )
        self.assertEqual(snapshot_before, store.audit_snapshot_root_v2())

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
