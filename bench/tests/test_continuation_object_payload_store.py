from __future__ import annotations

import copy
import unittest

from bench import continuation_bundle as bundle
from bench import continuation_object_payload_store as payload_store
from bench import continuation_object_store as object_store


class ContinuationObjectPayloadStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tenant = bytes((0x6D,)) * 32
        payloads = (
            b"payload-alpha",
            b"payload-beta-beta",
            b"payload-gamma-gamma-gamma",
        )
        self.entries = payload_store.sort_entries(
            [
                {
                    "reference": bundle.blob_ref(self.tenant, payload),
                    "payload": payload,
                }
                for payload in payloads
            ]
        )
        self.encoded = payload_store.encode_snapshot(
            self.tenant,
            self.entries,
        )

    def test_round_trip_and_exact_reclaim_preview(self) -> None:
        before = payload_store.decode_snapshot(
            self.encoded,
            self.tenant,
        )
        targets = [self.entries[1]["reference"]]
        targets.sort(key=lambda item: (item["sha256"], item["byte_length"]))
        preview = payload_store.preview_reclaim(
            self.encoded,
            self.tenant,
            targets,
        )
        payload_store.verify_reclaim_preview(preview)
        self.assertEqual(
            (before["entry_count"], before["payload_bytes"]),
            (3, 55),
        )
        self.assertEqual(preview["after"]["entry_count"], 2)
        self.assertEqual(
            preview["freed_payload_bytes"],
            targets[0]["byte_length"],
        )
        self.assertEqual(
            payload_store.decode_snapshot(
                preview["candidate"],
                self.tenant,
            )["snapshot_sha256"],
            preview["after"]["snapshot_sha256"],
        )
        self.assertEqual(
            self.encoded,
            payload_store.encode_snapshot(self.tenant, self.entries),
        )
        actual = {
            "encoded": before["encoded_sha256"].hex(),
            "before": preview["before"]["snapshot_sha256"].hex(),
            "targets": preview["targets_sha256"].hex(),
            "after": preview["after"]["snapshot_sha256"].hex(),
            "preview": preview["preview_sha256"].hex(),
        }
        expected = {
            "encoded": (
                "9399cdbed8b404f99452d389e42cf911"
                "69f5754fd434039144267bad493040e8"
            ),
            "before": (
                "273c8764ec1a383b4c6b613c4ba5cac"
                "bc4f84537fcd83a9ef258c268e1085f97"
            ),
            "targets": (
                "3401de400d1a47621ed276440d83fb915"
                "391363635e31c8ee1d80a66846e4432"
            ),
            "after": (
                "20175ca9739aa818bc006a6aec42cb9b"
                "37c25356f75d478c782dbcc34ae2c189"
            ),
            "preview": (
                "175dd88fd650ebcb22b437d58f976443"
                "fe97bc8a5931bbba850b19cd0b23f533"
            ),
        }
        self.assertEqual(actual, expected)

    def test_mutations_foreign_scope_and_targets_fail_closed(self) -> None:
        with self.assertRaises(payload_store.PayloadStoreError):
            payload_store.decode_snapshot(
                self.encoded,
                bytes((0x7D,)) * 32,
            )
        for index in range(len(self.encoded)):
            with self.subTest(index=index):
                mutated = bytearray(self.encoded)
                mutated[index] ^= 1
                with self.assertRaises(payload_store.PayloadStoreError):
                    payload_store.decode_snapshot(
                        bytes(mutated),
                        self.tenant,
                    )
        foreign = bundle.blob_ref(self.tenant, b"foreign")
        with self.assertRaises(payload_store.PayloadStoreError):
            payload_store.preview_reclaim(
                self.encoded,
                self.tenant,
                [foreign],
            )
        duplicated = [
            self.entries[0]["reference"],
            self.entries[0]["reference"],
        ]
        with self.assertRaises(payload_store.PayloadStoreError):
            payload_store.preview_reclaim(
                self.encoded,
                self.tenant,
                duplicated,
            )

    def test_preview_mutations_reject(self) -> None:
        target = [self.entries[1]["reference"]]
        target.sort(key=lambda item: (item["sha256"], item["byte_length"]))
        preview = payload_store.preview_reclaim(
            self.encoded,
            self.tenant,
            target,
        )
        for path in (
            ("freed_entries",),
            ("freed_payload_bytes",),
            ("before", "snapshot_sha256"),
            ("after", "snapshot_sha256"),
            ("targets_sha256",),
            ("preview_sha256",),
        ):
            with self.subTest(path=path):
                mutated = copy.deepcopy(preview)
                if len(path) == 1:
                    value = mutated[path[0]]
                    mutated[path[0]] = (
                        value + 1 if isinstance(value, int) else bytes(32)
                    )
                else:
                    mutated[path[0]][path[1]] = bytes(32)
                with self.assertRaises(payload_store.PayloadStoreError):
                    payload_store.verify_reclaim_preview(mutated)

        noncanonical = list(reversed(self.entries))
        with self.assertRaises(payload_store.PayloadStoreError):
            payload_store.encode_snapshot(self.tenant, noncanonical)
        with self.assertRaises(object_store.StoreError):
            object_store.retired_targets_root([])


if __name__ == "__main__":
    unittest.main()
