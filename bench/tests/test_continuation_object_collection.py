from __future__ import annotations

import unittest

from bench import continuation_bundle as bundle
from bench import continuation_capsule as capsule
from bench import continuation_object_collection as collection
from bench import continuation_object_store as object_store


class ContinuationObjectCollectionTests(unittest.TestCase):
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
        self.grant = collection.demo_grant(self.store)

    def key(self, entry_index: int) -> dict[str, object]:
        entry = self.entries[entry_index]
        return {
            "byte_length": entry["byte_length"],
            "sha256": entry["blob_sha256"],
        }

    def plan(self) -> tuple[dict[str, object], list[dict[str, object]]]:
        return collection.plan_collection(
            self.store,
            self.grant,
            self.roots,
            self.leases,
        )

    def test_exact_classification_and_dry_run_does_not_mutate(self) -> None:
        before = self.store.audit_snapshot_root_v2()
        receipt, decisions = self.plan()
        after = self.store.audit_snapshot_root_v2()
        self.assertEqual(before, after)
        self.assertEqual(
            (
                receipt["reachable_entries"],
                receipt["reachable_references"],
                receipt["leased_entries"],
                receipt["leased_references"],
                receipt["quarantined_entries"],
                receipt["quarantined_references"],
                receipt["collectible_entries"],
                receipt["collectible_bytes"],
            ),
            (5, 5, 1, 2, 1, 1, 1, self.kv["byte_length"]),
        )
        self.assertEqual(
            [decision["class"] for decision in decisions].count("reachable"),
            5,
        )
        self.assertEqual(
            [decision["class"] for decision in decisions].count("leased"),
            1,
        )
        self.assertEqual(
            [decision["class"] for decision in decisions].count("quarantined"),
            1,
        )
        self.assertEqual(
            [decision["class"] for decision in decisions].count("collectible"),
            1,
        )

    def test_cross_language_grant_input_and_plan_roots(self) -> None:
        self.maxDiff = None
        receipt, decisions = self.plan()
        actual = {
            "grant": collection.collection_grant_root(self.grant).hex(),
            "roots": collection.root_references_root(self.roots).hex(),
            "leases": collection.lease_receipts_root(self.leases).hex(),
            "snapshot": receipt["snapshot_sha256"].hex(),
            "plan": receipt["plan_sha256"].hex(),
            "collectible_bytes": receipt["collectible_bytes"],
        }
        expected = {
            "grant": (
                "e50faf088020f0e274d9759687833479"
                "5ce62535a6145c64b226fad8c03e14ee"
            ),
            "roots": (
                "b7ea28e55d1452b5221a12abcb6f648"
                "d63355a3eecb1aee2c60fcb5be42edf72"
            ),
            "leases": (
                "000b5c1c68b5c120a203d5593a305389"
                "001556cc2b2d1f3fcc624b0c13f8d824"
            ),
            "snapshot": (
                "b8b82e6eb574f7cef0f4e1c855054f4d"
                "9f1cd53e347bbb97f2250b3a72e871bf"
            ),
            "plan": (
                "b283dc923a974897ba9427c6ef9db4ac"
                "de41f5bb3a11d907e717645984894bc4"
            ),
            "collectible_bytes": 30,
        }
        self.assertEqual(actual, expected)
        self.assertEqual(
            receipt["plan_sha256"],
            collection.collection_plan_root(receipt, decisions),
        )

    def test_retired_entry_rejects_live_operations(self) -> None:
        lifecycle = object_store.demo_lifecycle_grant(self.store_grant)
        operations = (
            lambda: self.store.get(self.kv),
            lambda: self.store.release(self.kv),
            lambda: self.store.retire(self.kv),
            lambda: self.store.quarantine(self.kv, bytes((0x9A,)) * 32),
            lambda: self.store.acquire_lease(
                self.kv,
                lifecycle,
                bytes((0x72,)) * 32,
                100,
                120,
            ),
            lambda: self.store.put(
                self.kv,
                self.bundle["objects"]["kv_state"][1],
                self.store_grant["bundle_sha256"],
            ),
        )
        for operation in operations:
            with self.subTest(operation=operation):
                with self.assertRaises(object_store.StoreError):
                    operation()

    def test_root_multiplicity_order_and_unknown_inputs_fail_closed(self) -> None:
        with self.assertRaises(collection.CollectionError):
            collection.plan_collection(
                self.store,
                self.grant,
                self.roots[:-1],
                self.leases,
            )
        duplicate = collection.canonical_roots(self.roots + [self.roots[0]])
        with self.assertRaises(collection.CollectionError):
            collection.plan_collection(
                self.store,
                self.grant,
                duplicate,
                self.leases,
            )
        with self.assertRaises(collection.CollectionError):
            collection.plan_collection(
                self.store,
                self.grant,
                list(reversed(self.roots)),
                self.leases,
            )
        unknown = {
            "byte_length": 7,
            "sha256": bytes((0x44,)) * 32,
        }
        unknown_roots = collection.canonical_roots(self.roots + [unknown])
        with self.assertRaises(collection.CollectionError):
            collection.plan_collection(
                self.store,
                self.grant,
                unknown_roots,
                self.leases,
            )

    def test_lease_snapshot_scope_and_all_budgets_fail_closed(self) -> None:
        with self.assertRaises(collection.CollectionError):
            collection.plan_collection(
                self.store,
                self.grant,
                self.roots,
                [],
            )
        tampered_lease = dict(self.lease)
        tampered_lease["generation"] += 1
        with self.assertRaises(collection.CollectionError):
            collection.plan_collection(
                self.store,
                self.grant,
                self.roots,
                [tampered_lease],
            )
        mutations = (
            ("bundle_sha256", bytes((0x44,)) * 32),
            ("expected_snapshot_sha256", bytes((0x45,)) * 32),
            ("max_root_references", len(self.roots) - 1),
            ("max_lease_receipts", 0),
            ("max_slot_scans", self.store.capacity - 1),
            ("max_collectible_entries", 0),
            ("max_collectible_bytes", 0),
        )
        for name, value in mutations:
            with self.subTest(grant_field=name):
                grant = dict(self.grant)
                grant[name] = value
                with self.assertRaises(collection.CollectionError):
                    collection.plan_collection(
                        self.store,
                        grant,
                        self.roots,
                        self.leases,
                    )

    def test_corrupt_quarantine_is_classified_but_not_verified_as_live(self) -> None:
        index = self.store._find(self.lane)
        assert index is not None and self.store.slots[index] is not None
        payload = self.store.slots[index]["payload"]
        self.store.slots[index]["payload"] = b"x" + payload[1:]
        with self.assertRaises(object_store.StoreError):
            self.store.verify_all()
        self.grant = collection.demo_grant(self.store)
        receipt, decisions = self.plan()
        self.assertEqual(receipt["quarantined_entries"], 1)
        lane_decision = next(
            decision for decision in decisions if decision["target"] == self.lane
        )
        self.assertEqual(lane_decision["class"], "quarantined")


if __name__ == "__main__":
    unittest.main()
