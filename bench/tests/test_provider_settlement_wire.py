import copy
import unittest

from bench import provider_settlement_wire as wire


GOLDEN_ENVELOPE = "9d2aec698e62176966ef11193fce5d447b67fe77ea2ba6938ae6aa9bd9a7c3ba"


class ProviderSettlementWireTests(unittest.TestCase):
    def setUp(self) -> None:
        self.request, self.receipt = wire.build_demo_evidence()
        self.encoded = wire.encode_evidence(self.request, self.receipt)

    def test_cross_language_golden_round_trip(self) -> None:
        self.assertEqual(len(self.encoded), 720)
        self.assertEqual(self.encoded[-32:].hex(), GOLDEN_ENVELOPE)
        decoded = wire.decode_and_verify(self.encoded)
        self.assertEqual(decoded["request"], self.request)
        self.assertEqual(decoded["receipt"], self.receipt)

    def test_known_zero_unknown_and_every_outcome_survive_round_trip(self) -> None:
        for outcome in range(6):
            with self.subTest(outcome=outcome):
                request, receipt = wire.build_demo_evidence(outcome)
                decoded = wire.decode_and_verify(
                    wire.encode_evidence(request, receipt)
                )
                billable = decoded["receipt"]["usage"]["billable_tokens"]
                if outcome == wire.RETRYABLE_NO_CHARGE:
                    self.assertTrue(billable["known"])
                    self.assertEqual(billable["value"], 0)
                    self.assertFalse(
                        decoded["receipt"]["usage"]["input_tokens"]["known"]
                    )
                elif outcome == wire.AMBIGUOUS:
                    self.assertFalse(billable["known"])
                    self.assertEqual(billable["value"], 0)
                else:
                    self.assertTrue(billable["known"])

    def test_every_serialized_byte_rejects_after_outer_reseal(self) -> None:
        for index in range(len(self.encoded) - 32):
            with self.subTest(index=index):
                mutated = bytearray(self.encoded)
                mutated[index] ^= 1
                resealed = wire.reseal_for_test(bytes(mutated))
                with self.assertRaises(wire.WireError):
                    wire.decode_and_verify(resealed)

    def test_truncation_extension_outer_drift_and_substitution_reject(self) -> None:
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(self.encoded[:-1])
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(self.encoded + b"\x00")
        mutated = bytearray(self.encoded)
        mutated[wire.HEADER_BYTES] ^= 1
        with self.assertRaises(wire.WireError):
            wire.decode_and_verify(bytes(mutated))

        foreign = copy.deepcopy(self.request)
        foreign["request_key"] += 1
        foreign["request_sha256"] = wire.request_sha256(foreign)
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(foreign, self.receipt)

    def test_coordinated_nested_resealing_cannot_bless_semantic_drift(self) -> None:
        unknown_with_value = copy.deepcopy(self.receipt)
        unknown_with_value["usage"]["input_tokens"] = {
            "known": False,
            "value": 1,
        }
        with self.assertRaises(wire.WireError):
            wire.usage_sha256(unknown_with_value["usage"])

        reservation_drift = copy.deepcopy(self.receipt)
        reservation_drift["intent"]["reserved_tokens"] += 1
        reservation_drift["intent"]["intent_sha256"] = wire.intent_sha256(
            reservation_drift["intent"]
        )
        reservation_drift["receipt_sha256"] = wire.receipt_sha256(
            reservation_drift
        )
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(self.request, reservation_drift)

        false_failure = copy.deepcopy(self.receipt)
        false_failure["outcome"] = wire.FAILED
        false_failure["receipt_sha256"] = wire.receipt_sha256(false_failure)
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(self.request, false_failure)

        overflow_request = copy.deepcopy(self.request)
        overflow_request["input_token_estimate"] = 0xFFFFFFFFFFFFFFFF
        overflow_request["max_output_tokens"] = 1
        overflow_request["request_sha256"] = wire.request_sha256(
            overflow_request
        )
        overflow_receipt = copy.deepcopy(self.receipt)
        overflow_receipt["intent"]["request_sha256"] = overflow_request[
            "request_sha256"
        ]
        overflow_receipt["intent"]["dispatch_key_sha256"] = (
            wire.dispatch_key_sha256(overflow_request)
        )
        overflow_receipt["intent"]["intent_sha256"] = wire.intent_sha256(
            overflow_receipt["intent"]
        )
        overflow_receipt["receipt_sha256"] = wire.receipt_sha256(
            overflow_receipt
        )
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(overflow_request, overflow_receipt)


if __name__ == "__main__":
    unittest.main()
