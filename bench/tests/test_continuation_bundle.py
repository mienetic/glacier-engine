from __future__ import annotations

import struct
import unittest

from bench import continuation_bundle as bundle
from bench import continuation_capsule as capsule


class ContinuationBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        demo = bundle.build_demo()
        self.objects = demo["objects"]
        self.capsule_wire = demo["capsule_wire"]
        self.config = demo["bundle_config"]
        self.encoded = demo["encoded"]

    def test_cross_language_golden_and_canonical_dedup(self) -> None:
        self.assertEqual(len(self.encoded), 1136)
        self.assertEqual(
            self.encoded[-32:].hex(),
            "390c29d58b4cf979f44606f611f10b81"
            "1351d85cdbe1dedaeebe7b31b8564cc5",
        )
        decoded = bundle.decode_and_verify(
            self.encoded,
            self.config,
            self.capsule_wire,
            self.objects,
        )
        self.assertEqual(decoded["unique_blob_count"], 8)
        self.assertEqual(
            decoded["deduplicated_payload_bytes"],
            len(self.objects["model"][1]),
        )
        model_entry, tokenizer_entry = decoded["entries"][:2]
        self.assertEqual(
            model_entry["blob_ordinal"],
            tokenizer_entry["blob_ordinal"],
        )
        self.assertNotEqual(
            model_entry["typed_sha256"],
            tokenizer_entry["typed_sha256"],
        )

    def test_every_serialized_byte_mutation_rejects(self) -> None:
        for offset in range(len(self.encoded)):
            with self.subTest(offset=offset):
                mutated = bytearray(self.encoded)
                mutated[offset] ^= 1
                candidate = bytes(mutated)
                if offset < len(self.encoded) - 32:
                    candidate = bundle.reseal_for_test(candidate)
                with self.assertRaises(bundle.BundleError):
                    bundle.decode_and_verify(
                        candidate,
                        self.config,
                        self.capsule_wire,
                        self.objects,
                    )

    def test_tenant_scope_separates_identical_blob_identity(self) -> None:
        first = bundle.blob_ref(
            self.config["tenant_scope_sha256"],
            self.objects["model"][1],
        )
        second_config = dict(self.config)
        second_config["tenant_scope_sha256"] = bytes((0x7E,)) * 32
        second = bundle.blob_ref(
            second_config["tenant_scope_sha256"],
            self.objects["model"][1],
        )
        self.assertNotEqual(first["sha256"], second["sha256"])
        with self.assertRaises(bundle.BundleError):
            bundle.decode_and_verify(
                self.encoded,
                second_config,
                self.capsule_wire,
                self.objects,
            )

    def test_noncanonical_ordinal_and_totals_reject(self) -> None:
        for candidate in (self.encoded[:-1], self.encoded + b"\x00"):
            with self.assertRaises(bundle.BundleError):
                bundle.decode_manifest(candidate)

        ordinal_offset = bundle.HEADER_BYTES + bundle.ENTRY_BYTES + 24
        mutated = bytearray(self.encoded)
        mutated[ordinal_offset : ordinal_offset + 8] = struct.pack("<Q", 1)
        with self.assertRaises(bundle.BundleError):
            bundle.decode_manifest(bundle.reseal_for_test(bytes(mutated)))

        mutated = bytearray(self.encoded)
        logical_bytes_offset = 48
        value = struct.unpack(
            "<Q",
            mutated[logical_bytes_offset : logical_bytes_offset + 8],
        )[0]
        mutated[logical_bytes_offset : logical_bytes_offset + 8] = struct.pack(
            "<Q", value + 1
        )
        with self.assertRaises(bundle.BundleError):
            bundle.decode_manifest(bundle.reseal_for_test(bytes(mutated)))

    def test_foreign_object_capsule_and_parent_reject(self) -> None:
        foreign = dict(self.objects)
        foreign["kv_state"] = (
            self.objects["kv_state"][0],
            b"kv-v1:positions=37:root=foreign",
        )
        with self.assertRaises(bundle.BundleError):
            bundle.decode_and_verify(
                self.encoded,
                self.config,
                self.capsule_wire,
                foreign,
            )

        foreign_capsule_config = bundle.demo_capsule_config()
        foreign_capsule_config["publication_sequence"] += 1
        foreign_capsule = capsule.encode(
            foreign_capsule_config,
            self.objects,
        )
        with self.assertRaises(bundle.BundleError):
            bundle.decode_and_verify(
                self.encoded,
                self.config,
                foreign_capsule,
                self.objects,
            )

        next_config = dict(self.config)
        next_config.update(
            bundle_generation=1,
            parent_bundle_sha256=self.encoded[-32:],
        )
        next_encoded = bundle.encode(
            next_config,
            self.capsule_wire,
            self.objects,
        )
        decoded = bundle.decode_and_verify(
            next_encoded,
            next_config,
            self.capsule_wire,
            self.objects,
        )
        self.assertEqual(decoded["config"]["bundle_generation"], 1)
        invalid = dict(next_config)
        invalid["parent_bundle_sha256"] = capsule.ZERO_DIGEST
        with self.assertRaises(bundle.BundleError):
            bundle.encode(invalid, self.capsule_wire, self.objects)


if __name__ == "__main__":
    unittest.main()
