import copy
import unittest

from bench import provider_gateway_event_wire as wire
from bench import provider_settlement_wire as settlement_wire


GOLDEN_ENVELOPE = "a7e56cb9e4127f9ced08455424d009a27b0b541ea14f36999ef726d7afaed827"
GOLDEN_GATEWAY_CHAIN = "802acbd0995333738ab67192f0ac417cd080e1baa637de4beccc80262819c1bd"
GOLDEN_SETTLEMENT = "39794959d4febdfebcad2ef9824163ac53c714849b9dc0e56ce57c9ecc22d21f"


class ProviderGatewayEventWireTests(unittest.TestCase):
    def setUp(self) -> None:
        self.evidence = wire.build_demo_evidence()
        self.encoded = wire.encode_evidence(**self.evidence)

    def test_cross_language_closed_stream_golden(self) -> None:
        self.assertEqual(len(self.encoded), 5984)
        self.assertEqual(self.encoded[-32:].hex(), GOLDEN_ENVELOPE)
        self.assertEqual(
            self.evidence["final_snapshot"]["event_chain_sha256"].hex(),
            GOLDEN_GATEWAY_CHAIN,
        )
        self.assertEqual(
            self.evidence["settlement_envelopes"][5][-32:].hex(),
            GOLDEN_SETTLEMENT,
        )
        decoded = wire.decode_and_verify(self.encoded)
        self.assertEqual(decoded["events"], self.evidence["events"])
        self.assertEqual(decoded["final_snapshot"], self.evidence["final_snapshot"])
        self.assertEqual(set(decoded["settlements"]), {5})

    def test_every_serialized_byte_rejects_after_outer_reseal(self) -> None:
        for index in range(len(self.encoded) - 32):
            with self.subTest(index=index):
                mutated = bytearray(self.encoded)
                mutated[index] ^= 1
                with self.assertRaises(wire.WireError):
                    wire.decode_and_verify(
                        wire.reseal_for_test(bytes(mutated))
                    )

    def test_drop_reorder_missing_attachment_and_final_drift_reject(self) -> None:
        dropped = copy.deepcopy(self.evidence)
        dropped["events"] = dropped["events"][:-1]
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(**dropped)

        reordered = copy.deepcopy(self.evidence)
        reordered["events"][1], reordered["events"][2] = (
            reordered["events"][2],
            reordered["events"][1],
        )
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(**reordered)

        missing = copy.deepcopy(self.evidence)
        missing["settlement_envelopes"] = {}
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(**missing)

        drifted = copy.deepcopy(self.evidence)
        drifted["final_snapshot"]["ledger"]["active_handles"] = 1
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(**drifted)

    def test_all_attempt_outcomes_bind_to_their_event_kind(self) -> None:
        kinds = (
            wire.RETRYABLE_NO_CHARGE,
            wire.AMBIGUOUS,
            wire.SUCCEEDED,
            wire.FAILED,
            wire.RESOLVED_SUCCESS,
            wire.RESOLVED_FAILURE,
        )
        for outcome, kind in enumerate(kinds):
            with self.subTest(outcome=outcome):
                request, receipt = settlement_wire.build_demo_evidence(outcome)
                billable = receipt["usage"]["billable_tokens"]
                event = {
                    "kind": kind,
                    "gateway_epoch": receipt["intent"]["gateway_epoch"],
                    "owner_slot_index": receipt["intent"]["owner_slot_index"],
                    "owner_generation": receipt["intent"]["owner_generation"],
                    "attempt_generation": receipt["intent"][
                        "attempt_generation"
                    ],
                    "request_sha256": request["request_sha256"],
                    "dispatch_key_sha256": receipt["intent"][
                        "dispatch_key_sha256"
                    ],
                    "intent_sha256": receipt["intent"]["intent_sha256"],
                    "usage_sha256": receipt["usage"]["usage_sha256"],
                    "result_sha256": receipt["result_sha256"],
                    "request_set_count": receipt["request_set_count"],
                    "request_set_sha256": receipt["request_set_sha256"],
                    "reservation_tokens": receipt["intent"]["reserved_tokens"],
                    "billable_tokens": billable["value"] if billable["known"] else 0,
                    "event_sha256": receipt["event_sha256"],
                }
                wire._settlement_matches_event(  # noqa: SLF001
                    event,
                    {"request": request, "receipt": receipt},
                )

    def test_truncation_extension_and_unsealed_drift_reject(self) -> None:
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
