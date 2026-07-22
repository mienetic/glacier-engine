from __future__ import annotations

import copy
import unittest

from bench import provider_cost_wire as wire
from bench import provider_settlement_wire as settlement_wire


class ProviderCostWireTests(unittest.TestCase):
    def test_cross_language_golden_round_trips(self) -> None:
        encoded = wire.encode_evidence(wire.build_demo_evidence())
        self.assertEqual(len(encoded), 1_461)
        self.assertEqual(
            encoded[-32:].hex(),
            "393a668d6914cc1d23042070a280701e"
            "2f32b54e2af53b9df1f0f6cd11a1ad4b",
        )
        decoded = wire.decode_and_verify(encoded)
        self.assertEqual(
            decoded["quote"]["breakdown"]["total_nanos"],
            wire.known(700_000),
        )
        self.assertEqual(
            decoded["cost_settlement"]["breakdown"]["total_nanos"],
            wire.known(316_000),
        )
        self.assertEqual(
            decoded["cost_settlement"]["savings_nanos"],
            wire.known(384_000),
        )

    def test_all_attempt_outcomes_preserve_cost_semantics(self) -> None:
        outcomes = (
            settlement_wire.RETRYABLE_NO_CHARGE,
            settlement_wire.AMBIGUOUS,
            settlement_wire.SUCCEEDED,
            settlement_wire.FAILED,
            settlement_wire.RESOLVED_SUCCESS,
            settlement_wire.RESOLVED_FAILURE,
        )
        for outcome in outcomes:
            decoded = wire.decode_and_verify(
                wire.encode_evidence(wire.build_demo_evidence(outcome))
            )
            cost = decoded["cost_settlement"]
            if outcome == settlement_wire.AMBIGUOUS:
                self.assertEqual(
                    cost["breakdown"]["total_nanos"], wire.unknown()
                )
                self.assertEqual(cost["savings_nanos"], wire.unknown())
                self.assertEqual(cost["overrun_nanos"], wire.unknown())
            elif outcome == settlement_wire.RETRYABLE_NO_CHARGE:
                self.assertEqual(
                    cost["breakdown"]["total_nanos"], wire.known(0)
                )
                self.assertEqual(cost["savings_nanos"], wire.known(700_000))
            else:
                self.assertTrue(cost["breakdown"]["total_nanos"]["known"])

    def test_actual_usage_can_record_a_valid_quote_overrun(self) -> None:
        evidence = wire.build_demo_evidence()
        receipt = copy.deepcopy(evidence["provider_settlement"]["receipt"])
        receipt["usage"] = settlement_wire.make_usage(200, 100, 0, 0, 0, 300)
        receipt["receipt_sha256"] = settlement_wire.receipt_sha256(receipt)
        provider_envelope = settlement_wire.encode_evidence(
            evidence["provider_settlement"]["request"], receipt
        )
        provider = settlement_wire.decode_and_verify(provider_envelope)
        cost = wire.make_cost_settlement(
            evidence["price"], evidence["quote"], provider, 1_700_000_200
        )
        overrun = copy.deepcopy(evidence)
        overrun["provider_settlement_envelope"] = provider_envelope
        overrun["provider_settlement"] = provider
        overrun["cost_settlement"] = cost
        decoded = wire.decode_and_verify(wire.encode_evidence(overrun))
        self.assertEqual(
            decoded["cost_settlement"]["breakdown"]["total_nanos"],
            wire.known(1_200_000),
        )
        self.assertEqual(
            decoded["cost_settlement"]["overrun_nanos"],
            wire.known(500_000),
        )

    def test_rounding_and_unbounded_dimensions_are_explicit(self) -> None:
        evidence = wire.build_demo_evidence()
        request = evidence["provider_settlement"]["request"]
        provider = evidence["provider_settlement"]
        rates = {name: wire.known(1) for name in wire.RATE_NAMES}
        rates["retry"] = wire.known(0)
        totals: list[int] = []
        for mode in (wire.AGGREGATE_CEILING, wire.PER_COMPONENT_CEILING):
            price = wire.make_price_table(
                request["provider_adapter_abi"],
                bytes((0xA1,)) * 32,
                request["model_sha256"],
                18 + mode,
                1_700_000_000,
                1_700_001_000,
                b"USD",
                mode,
                wire.REASONING_WITHIN_OUTPUT,
                wire.RETRY_INCLUDED,
                rates,
            )
            quote = wire.make_quote(price, request, 1_700_000_100)
            cost = wire.make_cost_settlement(
                price, quote, provider, 1_700_000_200
            )
            totals.append(cost["breakdown"]["total_nanos"]["value"])
        self.assertEqual(totals, [1, 4])

        unbounded_price = copy.deepcopy(evidence["price"])
        unbounded_price["retry_mode"] = wire.RETRY_SEPARATE_UNBOUNDED
        unbounded_price["rates"]["retry"] = wire.known(1_000_000_000)
        unbounded_price["price_sha256"] = wire.price_table_sha256(
            unbounded_price
        )
        quote = wire.make_quote(unbounded_price, request, 1_700_000_100)
        self.assertEqual(quote["breakdown"]["total_nanos"], wire.unknown())
        cost = wire.make_cost_settlement(
            unbounded_price, quote, provider, 1_700_000_200
        )
        rejected = copy.deepcopy(evidence)
        rejected["price"] = unbounded_price
        rejected["quote"] = quote
        rejected["cost_settlement"] = cost
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(rejected)

    def test_every_pre_root_byte_mutation_rejects_after_outer_reseal(self) -> None:
        encoded = wire.encode_evidence(wire.build_demo_evidence())
        for offset in range(len(encoded) - 32):
            mutated = bytearray(encoded)
            mutated[offset] ^= 1
            resealed = wire.reseal_for_test(bytes(mutated))
            with self.assertRaises(wire.WireError, msg=f"offset {offset}"):
                wire.decode_and_verify(resealed)


if __name__ == "__main__":
    unittest.main()
