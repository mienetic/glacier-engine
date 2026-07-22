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


if __name__ == "__main__":
    unittest.main()
