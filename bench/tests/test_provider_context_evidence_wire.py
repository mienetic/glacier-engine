import unittest

from bench import provider_context_evidence_wire as wire


GOLDEN_DESCRIPTOR = "d85a42b9ad16255d122ac883ca63d5136eca00d82f2c3689f809a10ee975cafa"
GOLDEN_EXECUTION = "3114bae74248905c516aa677ffeea560a9dae09dc0d32b893cf0dac17734cbaf"
GOLDEN_ENVELOPE = "24836b276a8918ebcff9d3c9ff6b38d66e301602d96ddffda4de963fbf87e545"


class ProviderContextEvidenceWireTests(unittest.TestCase):
    def setUp(self) -> None:
        self.evidence = wire.build_demo_evidence()
        self.encoded = wire.encode_evidence(self.evidence)

    def test_cross_language_golden_round_trip(self) -> None:
        self.assertEqual(len(self.encoded), 2654)
        self.assertEqual(self.encoded[-32:].hex(), GOLDEN_ENVELOPE)
        self.assertEqual(
            self.evidence["descriptor"]["descriptor_sha256"].hex(),
            GOLDEN_DESCRIPTOR,
        )
        self.assertEqual(
            self.evidence["execution"]["execution_sha256"].hex(),
            GOLDEN_EXECUTION,
        )
        decoded = wire.decode_and_verify(self.encoded)
        self.assertEqual(decoded["packed_wire"], b"[AABBBC]")
        self.assertEqual(decoded["spans"], self.evidence["spans"])
        self.assertEqual(decoded["decisions"], self.evidence["decisions"])
        self.assertEqual(decoded["execution"], self.evidence["execution"])

    def test_every_serialized_byte_rejects_after_outer_reseal(self) -> None:
        for index in range(len(self.encoded) - 32):
            with self.subTest(index=index):
                mutated = bytearray(self.encoded)
                mutated[index] ^= 1
                resealed = wire.reseal_for_test(bytes(mutated))
                with self.assertRaises(wire.WireError):
                    wire.decode_and_verify(resealed)

    def test_truncation_extension_and_outer_drift_reject(self) -> None:
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(self.encoded[:-1])
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(self.encoded + b"\x00")
        mutated = bytearray(self.encoded)
        mutated[wire.HEADER_BYTES] ^= 1
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(bytes(mutated))


if __name__ == "__main__":
    unittest.main()
