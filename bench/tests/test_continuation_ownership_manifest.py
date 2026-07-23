from __future__ import annotations

import hashlib
import struct
import unittest

from bench import continuation_capsule as capsule
from bench import continuation_object_payload_store as payload_store
from bench import continuation_ownership_manifest as ownership


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def claim(**values: int) -> dict[str, int]:
    result = ownership.zero_claim()
    result.update(values)
    return result


def fixture() -> tuple[bytes, bytes, bytes, dict[str, object]]:
    tenant = digest(0x44)
    challenge = digest(0x55)
    payload_wire = payload_store.encode_snapshot(tenant, [])
    payload_snapshot = payload_store.decode_snapshot(payload_wire, tenant)
    value: dict[str, object] = {
        "source_bank_epoch": 41,
        "source_receipt_generation": 1,
        "restore_bank_epoch": 42,
        "request_epoch": 91,
        "publication_next_sequence": 7,
        "checkpoint_generation": 5,
        "owner_key": 7001,
        "tree_key": 7002,
        "authority_key": 7003,
        "parent_claim": claim(capsule_bytes=128, queue_slots=1),
        "tree_ceiling": claim(
            kv_bytes=8,
            output_journal_bytes=6,
        ),
        "tenant_scope_sha256": tenant,
        "payload_snapshot_sha256": payload_snapshot["snapshot_sha256"],
        "challenge_sha256": challenge,
        "scopes": [
            {
                "scope_key": 10,
                "tenant_key": 100,
                "ceiling": claim(kv_bytes=8),
            },
            {
                "scope_key": 20,
                "tenant_key": 200,
                "ceiling": claim(output_journal_bytes=6),
            },
        ],
        "allocations": [
            {
                "scope_ordinal": 0,
                "node_key": 1000,
                "binding_key": 10_000,
                "kind": "kv_page",
                "claim": claim(kv_bytes=8),
                "object_bytes": b"kv-page",
            },
            {
                "scope_ordinal": 1,
                "node_key": 2000,
                "binding_key": 20_000,
                "kind": "output_journal",
                "claim": claim(output_journal_bytes=6),
                "object_bytes": b"output",
            },
        ],
    }
    manifest_wire = ownership.encode(value)
    objects: dict[str, tuple[int, bytes]] = {
        "model": (1, b"model"),
        "tokenizer": (2, b"tokenizer"),
        "execution_plan": (3, b"plan"),
        "resource_state": (ownership.ABI_VERSION, manifest_wire),
        "lane_state": (5, b"lanes"),
        "kv_state": (6, b"kv"),
        "sampler_state": (7, b"sampler"),
        "output_state": (8, b"output-state"),
        "publication_receipt": (9, b"publication"),
    }
    capsule_wire = capsule.encode(
        {
            "execution_abi": 1,
            "request_epoch": 91,
            "publication_sequence": 7,
            "checkpoint_generation": 5,
            "kv_tokens": 8,
            "output_tokens": 4,
            "challenge_sha256": challenge,
            "parent_capsule_sha256": digest(0x66),
        },
        objects,
    )
    return manifest_wire, capsule_wire, payload_wire, value


class ContinuationOwnershipManifestTests(unittest.TestCase):
    def test_round_trip_golden_and_every_byte_mutation(self) -> None:
        manifest_wire, _, _, _ = fixture()
        decoded = ownership.decode(manifest_wire)
        self.assertEqual(len(manifest_wire), ownership.ENCODED_BYTES)
        self.assertEqual(
            decoded["manifest_sha256"].hex(),
            "59c777c9a576fdc87ecf8bb1d18ffbf1"
            "e98b30eef88e1ec8a5b312bfe68f394f",
        )
        for index in range(ownership.ENCODED_BYTES):
            with self.subTest(index=index):
                mutated = bytearray(manifest_wire)
                mutated[index] ^= 1
                with self.assertRaises(ownership.OwnershipManifestError):
                    ownership.decode(bytes(mutated))

        contradiction = bytearray(manifest_wire)
        struct.pack_into("<Q", contradiction, 376, 1)
        contradiction[-ownership.FOOTER_BYTES :] = hashlib.sha256(
            ownership.MANIFEST_DOMAIN
            + contradiction[: -ownership.FOOTER_BYTES]
        ).digest()
        with self.assertRaises(ownership.OwnershipManifestError):
            ownership.decode(bytes(contradiction))

    def test_capsule_payload_and_materialized_objects_are_exact(self) -> None:
        manifest_wire, capsule_wire, payload_wire, _ = fixture()
        verified = ownership.verify_bindings(
            capsule_wire,
            manifest_wire,
            payload_wire,
        )
        ownership.verify_materialized(
            verified["manifest"],
            [
                ("kv_page", b"kv-page"),
                ("output_journal", b"output"),
            ],
        )
        with self.assertRaises(ownership.OwnershipManifestError):
            ownership.verify_materialized(
                verified["manifest"],
                [
                    ("kv_page", b"wrong!!"),
                    ("output_journal", b"output"),
                ],
            )

        foreign_payload = payload_store.encode_snapshot(digest(0x45), [])
        with self.assertRaises(ownership.OwnershipManifestError):
            ownership.verify_bindings(
                capsule_wire,
                manifest_wire,
                foreign_payload,
            )

    def test_duplicate_scope_node_and_binding_are_rejected(self) -> None:
        _, _, _, value = fixture()
        duplicate_scope = dict(value)
        duplicate_scope["scopes"] = [
            *value["scopes"],
            {
                "scope_key": 20,
                "tenant_key": 201,
                "ceiling": claim(output_journal_bytes=6),
            },
        ]
        with self.assertRaises(ownership.OwnershipManifestError):
            ownership.encode(duplicate_scope)

        duplicate_node = dict(value)
        duplicate_node["allocations"] = [
            value["allocations"][0],
            {
                **value["allocations"][0],
                "binding_key": 10_001,
            },
        ]
        with self.assertRaises(ownership.OwnershipManifestError):
            ownership.encode(duplicate_node)

        duplicate_binding = dict(value)
        duplicate_binding["allocations"] = [
            value["allocations"][0],
            {
                **value["allocations"][1],
                "binding_key": 10_000,
            },
        ]
        with self.assertRaises(ownership.OwnershipManifestError):
            ownership.encode(duplicate_binding)


if __name__ == "__main__":
    unittest.main()
