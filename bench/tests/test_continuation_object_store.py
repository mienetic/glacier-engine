from __future__ import annotations

import unittest

from bench import continuation_bundle as bundle
from bench import continuation_object_store as object_store


class ContinuationObjectStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        demo = object_store.build_demo()
        self.bundle = demo["bundle"]
        self.grant = demo["grant"]

    def store(self, **kwargs: object) -> object_store.Store:
        return object_store.Store(
            self.grant,
            self.grant["authority_epoch"],
            **kwargs,
        )

    def import_bundle(self, store: object_store.Store) -> dict[str, object]:
        return store.import_bundle(
            self.bundle["encoded"],
            self.bundle["bundle_config"],
            self.bundle["capsule_wire"],
            self.bundle["objects"],
        )

    def key(self, entry_index: int) -> dict[str, object]:
        entry = bundle.decode_manifest(self.bundle["encoded"])["entries"][
            entry_index
        ]
        return {
            "byte_length": entry["byte_length"],
            "sha256": entry["blob_sha256"],
        }

    def test_cross_language_grant_snapshot_and_exact_accounting(self) -> None:
        self.assertEqual(
            object_store.grant_root(self.grant).hex(),
            "1d7b766cd09f48421c8638916716299c"
            "bbe0d7046aa7c24c54b5971c68d91771",
        )
        store = self.store()
        receipt = self.import_bundle(store)
        self.assertEqual(receipt["semantic_references"], 9)
        self.assertEqual(receipt["unique_entries_added"], 8)
        self.assertEqual(receipt["references_reused"], 1)
        self.assertEqual(receipt["payload_bytes_added"], 255)
        self.assertEqual(store.entry_count, 8)
        self.assertEqual(store.reference_count, 9)
        self.assertEqual(store.payload_bytes, 255)
        self.assertEqual(store.logical_index_bytes, 1024)
        self.assertEqual(
            receipt["snapshot_sha256"].hex(),
            "5ef533c5bbf2db216806736f6a12c595"
            "03f668b02e3c12dba8dc8b503121860f",
        )

    def test_duplicate_release_frees_only_final_reference(self) -> None:
        store = self.store()
        self.import_bundle(store)
        decoded = bundle.decode_manifest(self.bundle["encoded"])
        model = decoded["entries"][0]
        key = {
            "byte_length": model["byte_length"],
            "sha256": model["blob_sha256"],
        }
        self.assertEqual(store.get(key), self.bundle["objects"]["model"][1])
        store.release(key)
        self.assertEqual((store.entry_count, store.reference_count), (8, 8))
        store.release(key)
        self.assertEqual((store.entry_count, store.reference_count), (7, 7))
        self.assertEqual(store.payload_bytes, 230)
        with self.assertRaises(object_store.StoreError):
            store.release(key)

    def test_stale_denied_and_budget_failure_roll_back(self) -> None:
        with self.assertRaises(object_store.StoreError):
            object_store.Store(
                self.grant,
                self.grant["authority_epoch"] + 1,
            )
        denied_grant = dict(self.grant)
        denied_grant["allowed_operation_mask"] = object_store.OPERATION_GET
        denied = object_store.Store(
            denied_grant,
            denied_grant["authority_epoch"],
        )
        with self.assertRaises(object_store.StoreError):
            self.import_bundle(denied)

        provenance_store = self.store()
        decoded = bundle.decode_manifest(self.bundle["encoded"])
        model = decoded["entries"][0]
        with self.assertRaises(object_store.StoreError):
            provenance_store.put(
                {
                    "byte_length": model["byte_length"],
                    "sha256": model["blob_sha256"],
                },
                self.bundle["objects"]["model"][1],
                bytes((0x33,)) * 32,
            )
        self.assertEqual(provenance_store.entry_count, 0)

        limited_grant = dict(self.grant)
        limited_grant["max_entries"] = 7
        limited = object_store.Store(
            limited_grant,
            limited_grant["authority_epoch"],
        )
        with self.assertRaises(object_store.StoreError):
            self.import_bundle(limited)
        self.assertEqual(
            (
                limited.entry_count,
                limited.payload_bytes,
                limited.logical_index_bytes,
                limited.reference_count,
            ),
            (0, 0, 0, 0),
        )

        quota_changes = (
            ("max_object_bytes", 32),
            ("max_payload_bytes", 200),
            ("max_index_bytes", 7 * object_store.LOGICAL_INDEX_ENTRY_BYTES),
            ("max_references", 8),
        )
        for name, value in quota_changes:
            with self.subTest(quota=name):
                quota_grant = dict(self.grant)
                quota_grant[name] = value
                quota_store = object_store.Store(
                    quota_grant,
                    quota_grant["authority_epoch"],
                )
                with self.assertRaises(object_store.StoreError):
                    self.import_bundle(quota_store)
                self.assertEqual(
                    (
                        quota_store.entry_count,
                        quota_store.payload_bytes,
                        quota_store.logical_index_bytes,
                        quota_store.reference_count,
                    ),
                    (0, 0, 0, 0),
                )

    def test_injected_allocator_failure_rolls_back_exactly(self) -> None:
        store = self.store(fail_after_new_entries=3)
        with self.assertRaises(object_store.StoreError):
            self.import_bundle(store)
        self.assertEqual(
            (
                store.entry_count,
                store.live_entries,
                store.payload_bytes,
                store.logical_index_bytes,
                store.reference_count,
                store.allocator_insertions,
            ),
            (0, 0, 0, 0, 0, 0),
        )
        store.verify_all()

    def test_corruption_quarantine_and_bundle_scope_reject(self) -> None:
        store = self.store()
        self.import_bundle(store)
        decoded = bundle.decode_manifest(self.bundle["encoded"])
        kv = decoded["entries"][5]
        key = {"byte_length": kv["byte_length"], "sha256": kv["blob_sha256"]}
        index = store._find(key)
        assert index is not None and store.slots[index] is not None
        store.slots[index]["payload"] = b"x" + store.slots[index]["payload"][1:]
        with self.assertRaises(object_store.StoreError):
            store.verify_all()
        with self.assertRaises(object_store.StoreError):
            store.get(key)
        store.quarantine(key, bytes((0x9A,)) * 32)
        with self.assertRaises(object_store.StoreError):
            store.get(key)
        self.assertEqual(store.quarantined_entries, 1)

        foreign_grant = dict(self.grant)
        foreign_grant["bundle_sha256"] = bytes((0x44,)) * 32
        foreign = object_store.Store(
            foreign_grant,
            foreign_grant["authority_epoch"],
        )
        with self.assertRaises(object_store.StoreError):
            self.import_bundle(foreign)
        self.assertEqual(foreign.entry_count, 0)

        tenant_grant = dict(self.grant)
        tenant_grant["tenant_scope_sha256"] = bytes((0x7E,)) * 32
        foreign_tenant = object_store.Store(
            tenant_grant,
            tenant_grant["authority_epoch"],
        )
        with self.assertRaises(object_store.StoreError):
            self.import_bundle(foreign_tenant)
        self.assertEqual(foreign_tenant.entry_count, 0)

    def test_generation_fenced_lease_renew_expire_and_collection(self) -> None:
        store = self.store()
        self.import_bundle(store)
        lifecycle = object_store.demo_lifecycle_grant(self.grant)
        model = self.key(0)
        owner = bytes((0x71,)) * 32
        first = store.acquire_lease(model, lifecycle, owner, 100, 120)
        self.assertEqual((first["generation"], store.active_leases), (1, 1))
        store.release(model)
        with self.assertRaises(object_store.StoreError):
            store.release(model)
        renewed = store.renew_lease(model, first, lifecycle, 110, 150)
        self.assertEqual((renewed["generation"], store.active_leases), (2, 1))
        with self.assertRaises(object_store.StoreError):
            store.release_lease(model, first, lifecycle)
        with self.assertRaises(object_store.StoreError):
            store.expire_lease(model, renewed, lifecycle, 149)
        store.expire_lease(model, renewed, lifecycle, 150)
        self.assertEqual(store.active_leases, 0)
        store.release(model)
        self.assertIsNone(store._find(model))
        store.verify_all()

    def test_lease_scope_budget_window_and_tamper_fail_closed(self) -> None:
        store = self.store()
        self.import_bundle(store)
        lifecycle = object_store.demo_lifecycle_grant(self.grant)
        lifecycle["max_active_leases"] = 1
        model = self.key(0)
        kv = self.key(5)
        receipt = store.acquire_lease(
            model, lifecycle, bytes((0x71,)) * 32, 10, 20
        )
        with self.assertRaises(object_store.StoreError):
            store.acquire_lease(kv, lifecycle, bytes((0x72,)) * 32, 10, 20)
        with self.assertRaises(object_store.StoreError):
            store.renew_lease(model, receipt, lifecycle, 11, 80)
        tampered = dict(receipt)
        tampered["generation"] += 1
        with self.assertRaises(object_store.StoreError):
            store.release_lease(model, tampered, lifecycle)
        foreign = dict(lifecycle)
        foreign["bundle_sha256"] = bytes((0x44,)) * 32
        with self.assertRaises(object_store.StoreError):
            store.release_lease(model, receipt, foreign)
        denied = dict(lifecycle)
        denied["allowed_operation_mask"] = object_store.LEASE_OPERATION_ACQUIRE
        with self.assertRaises(object_store.StoreError):
            store.release_lease(model, receipt, denied)
        store.release_lease(model, receipt, lifecycle)
        store.verify_all()

    def test_quarantine_fences_lease_and_repair_requires_exact_provenance(
        self,
    ) -> None:
        store = self.store()
        self.import_bundle(store)
        lifecycle = object_store.demo_lifecycle_grant(self.grant)
        kv = self.key(5)
        lease = store.acquire_lease(
            kv, lifecycle, bytes((0x72,)) * 32, 200, 240
        )
        index = store._find(kv)
        assert index is not None and store.slots[index] is not None
        store.slots[index]["payload"] = b"x" + store.slots[index]["payload"][1:]
        reason = bytes((0x9A,)) * 32
        source = bytes((0xB6,)) * 32
        store.quarantine(kv, reason)
        self.assertEqual(store.active_leases, 0)
        with self.assertRaises(object_store.StoreError):
            store.release_lease(kv, lease, lifecycle)
        repair_grant = object_store.demo_repair_grant(
            self.grant, kv, source, reason
        )
        with self.assertRaises(object_store.StoreError):
            store.repair(
                kv,
                self.bundle["objects"]["kv_state"][1],
                bytes((0xB7,)) * 32,
                repair_grant,
            )
        wrong_reason = dict(repair_grant)
        wrong_reason["expected_quarantine_reason_sha256"] = bytes((0x91,)) * 32
        with self.assertRaises(object_store.StoreError):
            store.repair(kv, self.bundle["objects"]["kv_state"][1], source, wrong_reason)
        with self.assertRaises(object_store.StoreError):
            store.repair(kv, b"wrong repair payload", source, repair_grant)
        receipt = store.repair(
            kv,
            self.bundle["objects"]["kv_state"][1],
            source,
            repair_grant,
        )
        self.assertEqual((receipt["repair_generation"], store.repair_count), (1, 1))
        self.assertEqual(store.get(kv), self.bundle["objects"]["kv_state"][1])
        self.assertEqual(receipt["repair_sha256"], object_store.repair_receipt_root(receipt))
        store.verify_all()
        store.release(kv)
        self.assertEqual(store.repair_count, 0)
        store.verify_all()

    def test_cross_language_lifecycle_and_repair_roots(self) -> None:
        self.maxDiff = None
        store = self.store()
        self.import_bundle(store)
        lifecycle = object_store.demo_lifecycle_grant(self.grant)
        model = self.key(0)
        first = store.acquire_lease(
            model, lifecycle, bytes((0x71,)) * 32, 100, 120
        )
        renewed = store.renew_lease(model, first, lifecycle, 110, 150)
        store.release_lease(model, renewed, lifecycle)
        kv = self.key(5)
        kv_lease = store.acquire_lease(
            kv, lifecycle, bytes((0x72,)) * 32, 200, 240
        )
        reason = bytes((0x9A,)) * 32
        source = bytes((0xB6,)) * 32
        store.quarantine(kv, reason)
        repair_grant = object_store.demo_repair_grant(
            self.grant, kv, source, reason
        )
        repair = store.repair(
            kv,
            self.bundle["objects"]["kv_state"][1],
            source,
            repair_grant,
        )
        self.assertEqual(kv_lease["generation"], 1)
        expected = {
            "lifecycle_grant": (
                "cfd5df486b00f6fcf2fb61792a49bd4c"
                "4ad358be183b9ec2b4df517a4b79b85b"
            ),
            "first_lease": (
                "a95418f46e56d7105b73c40dc5138e56"
                "b64ff881ebf84e2cc958cf26615b348a"
            ),
            "renewed_lease": (
                "3ff1c7b5f4d83e40dccce97e424e4362"
                "ccd7b04920b2141f71658f2922d5069d"
            ),
            "repair_grant": (
                "5d4fa957f3e163b5fc3cf7cb2fed8fcc"
                "8df28eaa74cff1b574c56ee69e787e7a"
            ),
            "repair_receipt": (
                "59d39a2e4ab40382012505a326e3bec3"
                "f8f1f27453d1a47928c3a4f27e282875"
            ),
            "snapshot_v2": (
                "239ea7e7555388fab740d3d1fdb8040a"
                "7f3706b102e9572c05f7dc612822e1bd"
            ),
        }
        actual = {
            "lifecycle_grant": object_store.lifecycle_grant_root(lifecycle).hex(),
            "first_lease": first["lease_sha256"].hex(),
            "renewed_lease": renewed["lease_sha256"].hex(),
            "repair_grant": object_store.repair_grant_root(repair_grant).hex(),
            "repair_receipt": repair["repair_sha256"].hex(),
            "snapshot_v2": store.snapshot_root_v2().hex(),
        }
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
