from __future__ import annotations

import hashlib
import struct
import unittest

from bench import prepared_text_checkpoint as checkpoint


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def fixture() -> tuple[bytes, dict[str, object]]:
    blocks = (
        (
            0x00000000,
            0x80000000,
            0x3F800000,
            0xBF800000,
            0x00000001,
            0x007FFFFF,
            0x00800000,
            0x7F7FFFFF,
        ),
        (
            0x7F800000,
            0xFF800000,
            0x7FC00001,
            0xFFC01234,
            0x01020304,
            0x11223344,
            0xA1B2C3D4,
            0xFFFFFFFF,
        ),
        (
            0x40000000,
            0xC0000000,
            0x3F000000,
            0xBF000000,
            0x40490FDB,
            0xC0490FDB,
            0x3EAAAAAB,
            0xBEAAAAAB,
        ),
        (
            0x00800001,
            0x80800001,
            0x7F000001,
            0xFF000001,
            0x12345678,
            0x87654321,
            0xDEADBEEF,
            0x0BADF00D,
        ),
    )
    payload = b"".join(
        struct.pack("<I", bits)
        for block in blocks
        for bits in block
    )
    state_commitment = bytes.fromhex(
        "7f5a4e56ead8de9a227f4fdb00a806370fc4ed0ed1c126f825548ba1349d0abe"
    )
    value: dict[str, object] = {
        "local_plan_sha256": digest(0x11),
        "bound_plan_sha256": digest(0x22),
        "artifact_sha256": digest(0x33),
        "execution_plan_sha256": digest(0x44),
        "residency_binding_sha256": digest(0x55),
        "boundary_sha256": digest(0x66),
        "transcript_sha256": digest(0x77),
        "state_commitment_sha256": state_commitment,
        "request_epoch": 0x0102030405060708,
        "publication_next_sequence": 2,
        "prompt_tokens": 3,
        "max_new_tokens": 5,
        "vocab_size": 1 << 32,
        "num_layers": 2,
        "kv_dim": 2,
        "max_kv_positions": 7,
        "kv_positions": 4,
        "output_tokens": (0x01020304, 0x00010002),
        "output_count": 2,
        "sampling_calls": 2,
        "rng_state": (
            0x0102030405060708,
            0x1122334455667788,
            0x8000000000000001,
            0xFFFFFFFFFFFFFFFF,
        ),
        "canonical_kv_f32_le": payload,
        "challenge_sha256": digest(0xCC),
    }
    return checkpoint.encode(value), value


class PreparedTextCheckpointTests(unittest.TestCase):
    def test_wire_golden_and_every_byte_mutation(self) -> None:
        encoded, value = fixture()
        decoded = checkpoint.decode(encoded, value)
        self.assertEqual(len(encoded), 712)
        self.assertEqual(
            encoded[:32].hex(),
            "474c54434b503031010000004b544c47"
            "c8020000000000000000000000000000",
        )
        self.assertEqual(
            decoded["output_state_sha256"].hex(),
            "03cbe74495cfa114143c7769dfc9532f"
            "2378c8f57769c9bd9a14e28809ac6c82",
        )
        self.assertEqual(
            decoded["rng_state_sha256"].hex(),
            "b833da6866b013a35f47013a8aaf72d5"
            "3473487ad8d8f6c5d1f5fc62647db5c2",
        )
        self.assertEqual(
            decoded["logical_kv_sha256"].hex(),
            "f2888bdf0a9fd9518164ce850f3f0cdfe"
            "9772be661e2093c54a111970e9f3550",
        )
        self.assertEqual(
            decoded["checkpoint_sha256"].hex(),
            "59aaeec3bd3ef69e0aef0e42ad832758"
            "66163ae95290bc7578c810845f5affdc",
        )
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(
                    checkpoint.PreparedTextCheckpointError
                ):
                    checkpoint.decode(bytes(mutated), value)

    def test_coherent_scalar_and_context_substitution_reject(self) -> None:
        encoded, value = fixture()
        contradictory = bytearray(encoded)
        struct.pack_into("<Q", contradictory, 296, 3)
        contradictory[-checkpoint.FOOTER_BYTES :] = hashlib.sha256(
            checkpoint.CHECKPOINT_DOMAIN
            + contradictory[: -checkpoint.FOOTER_BYTES]
        ).digest()
        with self.assertRaises(checkpoint.PreparedTextCheckpointError):
            checkpoint.decode(bytes(contradictory), value)

        foreign = dict(value)
        foreign["bound_plan_sha256"] = digest(0x99)
        with self.assertRaises(checkpoint.PreparedTextCheckpointError):
            checkpoint.decode(encoded, foreign)

    def test_raw_float_bits_are_preserved_not_normalized(self) -> None:
        encoded, value = fixture()
        decoded = checkpoint.decode(encoded, value)
        payload = decoded["canonical_kv_f32_le"]
        bits = tuple(
            struct.unpack_from("<I", payload, offset)[0]
            for offset in range(0, len(payload), 4)
        )
        self.assertIn(0x00000000, bits)
        self.assertIn(0x80000000, bits)
        self.assertIn(0x7FC00001, bits)
        self.assertIn(0xFFC01234, bits)


if __name__ == "__main__":
    unittest.main()
