from __future__ import annotations

import unittest

from bench import provider_cost_journal as cost_journal
from bench import provider_evidence_join_wire as wire


class ProviderEvidenceJoinWireTests(unittest.TestCase):
    def test_cross_language_golden_replays_all_external_evidence(self) -> None:
        bundle = wire.build_demo_bundle()
        encoded = bundle["join"]
        self.assertEqual(len(encoded), 712)
        self.assertEqual(len(bundle["gateway"]), 5_984)
        self.assertEqual(len(bundle["transport"]), 2_758)
        self.assertEqual(
            bundle["transport"][-32:].hex(),
            "6f58a4ac93d819771985856fc6579ea0"
            "566e1e6d220a01e7b72af7e82a0be3bd",
        )
        self.assertEqual(
            encoded[-32:].hex(),
            "2fada5a5836deb0d5a8d2acdad08bd09"
            "f4eb3b759dcf5b8ee69a4e38d6ee5274",
        )
        decoded = self._verify(encoded, bundle)
        self.assertEqual(decoded["journal_sequence"], 1)
        self.assertEqual(decoded["gateway_event_index"], 5)
        self.assertEqual(decoded["transport_event_count"], 4)
        self.assertEqual(decoded["journal_frame_bytes"], 1_645)
        self.assertEqual(decoded["gateway_wire_bytes"], 5_984)
        self.assertEqual(decoded["transport_wire_bytes"], 2_758)
        self.assertEqual(
            decoded["journal_entry_sha256"].hex(),
            "2bbd2e767663fdb30810adc3c246ec04"
            "94e6857fb87c7ef003f0f3b63a653187",
        )

    def test_every_join_byte_mutation_rejects(self) -> None:
        bundle = wire.build_demo_bundle()
        encoded = bundle["join"]
        for offset in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[offset] ^= 1
            candidate = bytes(mutated)
            if offset < len(encoded) - 32:
                candidate = wire.reseal_for_test(candidate)
            with self.assertRaises(wire.WireError, msg=f"offset {offset}"):
                self._verify(candidate, bundle)

    def test_valid_transport_substitution_rejects(self) -> None:
        bundle = wire.build_demo_bundle()
        alternate = wire.build_demo_transport(
            bundle["settlement"],
            bundle["settlement_envelope"],
            chunk_seed=0x62,
        )
        self.assertNotEqual(alternate, bundle["transport"])
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(
                bundle["join"],
                bundle["header"],
                bundle["frame"],
                bundle["gateway"],
                alternate,
            )

    def test_unsettled_event_and_wrong_journal_chain_reject(self) -> None:
        bundle = wire.build_demo_bundle()
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(
                bundle["header"],
                1,
                bundle["header"]["header_sha256"],
                bundle["frame"],
                4,
                bundle["gateway"],
                bundle["transport"],
            )
        wrong_previous = bytes((0xD1,)) * 32
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(
                bundle["header"],
                1,
                wrong_previous,
                bundle["frame"],
                5,
                bundle["gateway"],
                bundle["transport"],
            )
        alternate_frame = cost_journal.encode_frame(
            bundle["header"],
            1,
            wrong_previous,
            bundle["frame"][104 : cost_journal.FRAME_PREFIX_BYTES],
        )
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(
                bundle["header"],
                1,
                wrong_previous,
                alternate_frame,
                5,
                bundle["gateway"],
                bundle["transport"],
            )

    def test_truncation_and_extension_reject(self) -> None:
        bundle = wire.build_demo_bundle()
        for candidate in (bundle["join"][:-1], bundle["join"] + b"\x00"):
            with self.assertRaises(wire.WireError):
                self._verify(candidate, bundle)

    @staticmethod
    def _verify(encoded: bytes, bundle: wire.Record) -> wire.Record:
        return wire.decode_and_verify(
            encoded,
            bundle["header"],
            bundle["frame"],
            bundle["gateway"],
            bundle["transport"],
        )


if __name__ == "__main__":
    unittest.main()
