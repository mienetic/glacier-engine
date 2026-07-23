from __future__ import annotations

import hashlib
import struct
import unittest

from bench import continuation_paged_kv_restore as restore


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def fixture() -> tuple[bytes, dict[str, object]]:
    source_ref = {
        "abi_version": restore.PAGE_REF_ABI,
        "cache_instance": 501,
        "logical_page": 0,
        "ownership_generation": 9,
    }
    source_ownership = restore.append_ownership(
        restore.empty_ownership(501, 2, 2, 32),
        source_ref,
    )
    source_root = {
        "abi_version": restore.PAGE_MAP_ROOT_ABI,
        "cache_instance": 501,
        "generation": 8,
        "committed_len": 16,
        "committed_pages": 1,
        "ownership_sha256": source_ownership,
    }
    payload = b"".join(
        struct.pack("<f", float(index)) for index in range(128)
    )
    value: dict[str, object] = {
        "source_root": source_root,
        "num_layers": 2,
        "dim": 2,
        "max_seq": 32,
        "source_ref": source_ref,
        "committed_rows": 16,
        "canonical_f32_le": payload,
        "challenge_sha256": digest(0x61),
    }
    return restore.encode(value), value


class ContinuationPagedKVRestoreTests(unittest.TestCase):
    def test_page_image_golden_and_every_byte_mutation(self) -> None:
        encoded, _ = fixture()
        decoded = restore.decode(encoded, digest(0x61))
        self.assertEqual(len(encoded), 752)
        self.assertEqual(
            decoded["image_sha256"].hex(),
            "e052306f36ef24b9b92f7f0ef505045e"
            "a25fddf7bdf8f4c9e81b96733437d1e4",
        )
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(restore.PagedKVRestoreError):
                    restore.decode(bytes(mutated), digest(0x61))

        contradiction = bytearray(encoded)
        struct.pack_into("<I", contradiction, 28, 1)
        contradiction[-restore.FOOTER_BYTES :] = hashlib.sha256(
            restore.PAGE_IMAGE_DOMAIN
            + contradiction[: -restore.FOOTER_BYTES]
        ).digest()
        with self.assertRaises(restore.PagedKVRestoreError):
            restore.decode(bytes(contradiction), digest(0x61))

    def test_source_chain_remaps_to_fresh_target_generations(self) -> None:
        encoded, _ = fixture()
        remapped = restore.verify_and_remap(
            [encoded],
            digest(0x61),
            777,
        )
        self.assertEqual(
            remapped["source_root"]["cache_instance"],
            501,
        )
        self.assertEqual(
            remapped["target_root"]["cache_instance"],
            777,
        )
        self.assertEqual(
            remapped["target_refs"][0]["ownership_generation"],
            1,
        )
        self.assertNotEqual(
            remapped["source_root"]["ownership_sha256"],
            remapped["target_root"]["ownership_sha256"],
        )

    def test_stale_source_generation_breaks_complete_chain(self) -> None:
        _, value = fixture()
        stale_value = dict(value)
        stale_value["source_ref"] = {
            **value["source_ref"],
            "ownership_generation": 10,
        }
        stale_wire = restore.encode(stale_value)
        with self.assertRaises(restore.PagedKVRestoreError):
            restore.verify_and_remap(
                [stale_wire],
                digest(0x61),
                777,
            )


if __name__ == "__main__":
    unittest.main()
