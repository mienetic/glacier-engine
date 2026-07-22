from __future__ import annotations

import copy
import unittest

from bench import provider_settlement_wire as settlement_wire
from bench import provider_transport_event_wire as wire


class ProviderTransportEventWireTests(unittest.TestCase):
    def test_cross_language_golden_round_trips(self) -> None:
        evidence = wire.build_demo_evidence()
        encoded = wire.encode_evidence(evidence)
        self.assertEqual(len(encoded), 2_987)
        self.assertEqual(
            encoded[-32:].hex(),
            "49529b995fdd951aa8228d1e75ecbdd3"
            "e0f4199374261e7043ba041132103798",
        )
        decoded = wire.decode_and_verify(encoded)
        self.assertEqual(len(decoded["events"]), 5)
        self.assertEqual(
            decoded["final_snapshot"]["ledger"]["emitted_chunks"], 2
        )
        self.assertEqual(
            decoded["final_cancel_snapshot"]["ledger"]
            ["known_post_cancel_billable_tokens"],
            24,
        )

    def test_normal_and_cancel_terminal_mappings(self) -> None:
        for kind in (
            wire.CANCEL_CONFIRMED,
            wire.CANCEL_TOO_LATE_SUCCEEDED,
            wire.CANCEL_AMBIGUOUS,
        ):
            evidence = self._cancel_variant(kind)
            wire.decode_and_verify(wire.encode_evidence(evidence))
        for kind in (wire.SUCCEEDED, wire.RETRYABLE_NO_CHARGE, wire.AMBIGUOUS):
            evidence = self._normal_variant(kind)
            wire.decode_and_verify(wire.encode_evidence(evidence))

    def test_drop_reorder_snapshot_and_settlement_substitution_reject(self) -> None:
        evidence = wire.build_demo_evidence()
        dropped = copy.deepcopy(evidence)
        dropped["events"].pop(1)
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(dropped)

        reordered = copy.deepcopy(evidence)
        reordered["events"][0], reordered["events"][1] = (
            reordered["events"][1],
            reordered["events"][0],
        )
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(reordered)

        drifted = copy.deepcopy(evidence)
        drifted["final_snapshot"]["ledger"]["emitted_chunks"] += 1
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(drifted)

        wrong = copy.deepcopy(evidence)
        request, receipt = settlement_wire.build_demo_evidence()
        wrong_envelope = settlement_wire.encode_evidence(request, receipt)
        wrong["settlement_envelope"] = wrong_envelope
        wrong["settlement"] = settlement_wire.decode_and_verify(wrong_envelope)
        with self.assertRaises(wire.WireError):
            wire.encode_evidence(wrong)

    def test_every_pre_root_byte_mutation_rejects_after_outer_reseal(self) -> None:
        encoded = wire.encode_evidence(wire.build_demo_evidence())
        for offset in range(len(encoded) - 32):
            mutated = bytearray(encoded)
            mutated[offset] ^= 1
            resealed = wire.reseal_for_test(bytes(mutated))
            with self.assertRaises(wire.WireError, msg=f"offset {offset}"):
                wire.decode_and_verify(resealed)

    def _replace_settlement(
        self,
        evidence: wire.Record,
        outcome: int,
        usage: wire.Record,
        result: bytes,
    ) -> None:
        request = evidence["settlement"]["request"]
        receipt = copy.deepcopy(evidence["settlement"]["receipt"])
        receipt["outcome"] = outcome
        receipt["usage"] = usage
        receipt["result_sha256"] = result
        receipt["receipt_sha256"] = settlement_wire.receipt_sha256(receipt)
        envelope = settlement_wire.encode_evidence(request, receipt)
        evidence["settlement_envelope"] = envelope
        evidence["settlement"] = settlement_wire.decode_and_verify(envelope)

    def _cancel_variant(self, kind: int) -> wire.Record:
        evidence = wire.build_demo_evidence()
        ack = evidence["events"][3]["cancel_ack"]
        outcome = evidence["events"][4]["cancel_outcome"]
        if kind == wire.CANCEL_CONFIRMED:
            usage = settlement_wire.make_usage(100, 5, 81, 0, 0, 24)
            result = bytes(32)
            outcome_kind = wire.CANCEL_OUTCOME_CONFIRMED
            settlement_kind = settlement_wire.FAILED
            ledger_name = "confirmed_cancellations"
        elif kind == wire.CANCEL_TOO_LATE_SUCCEEDED:
            usage = settlement_wire.make_usage(100, 20, 40, 8, 0, 80)
            result = bytes((0x71,)) * 32
            outcome_kind = wire.CANCEL_OUTCOME_TOO_LATE_SUCCEEDED
            settlement_kind = settlement_wire.SUCCEEDED
            ledger_name = "too_late_successes"
        else:
            usage = settlement_wire.make_usage(100, 7, 40, None, 3, None)
            result = bytes(32)
            outcome_kind = wire.CANCEL_OUTCOME_AMBIGUOUS
            settlement_kind = settlement_wire.AMBIGUOUS
            ledger_name = "ambiguous_cancellations"
        ack["kind"] = kind
        ack["usage"] = usage
        ack["result_sha256"] = result
        ack["ack_sha256"] = wire.cancel_ack_sha256(ack)
        outcome["kind"] = outcome_kind
        outcome["cancel_ack_sha256"] = ack["ack_sha256"]
        outcome["usage"] = usage
        outcome["result_sha256"] = result
        outcome["outcome_sha256"] = wire.cancel_outcome_sha256(outcome)
        cancel_ledger = wire._zero_ledger(wire.CANCEL_LEDGER_NAMES)  # noqa: SLF001
        cancel_ledger["requested_cancellations"] = 1
        cancel_ledger[ledger_name] = 1
        if usage["billable_tokens"]["known"]:
            cancel_ledger["known_post_cancel_billable_tokens"] = usage[
                "billable_tokens"
            ]["value"]
        else:
            cancel_ledger["unknown_post_cancel_usage"] = 1
        evidence["final_cancel_snapshot"]["ledger"] = cancel_ledger
        self._replace_settlement(
            evidence, settlement_kind, usage, result
        )
        return evidence

    def _normal_variant(self, kind: int) -> wire.Record:
        evidence = wire.build_demo_evidence()
        script = evidence["script"]
        if kind == wire.SUCCEEDED:
            usage = settlement_wire.make_usage(100, 20, 40, 8, 0, 80)
            result = bytes((0x71,)) * 32
            settlement_kind = settlement_wire.SUCCEEDED
            ledger_name = "successful_outcomes"
        elif kind == wire.RETRYABLE_NO_CHARGE:
            usage = settlement_wire.make_usage(None, None, None, None, None, 0)
            result = bytes(32)
            settlement_kind = settlement_wire.RETRYABLE_NO_CHARGE
            ledger_name = "retryable_outcomes"
        else:
            usage = settlement_wire.make_usage(100, 7, 40, None, 3, None)
            result = bytes(32)
            settlement_kind = settlement_wire.AMBIGUOUS
            ledger_name = "ambiguous_outcomes"
        script["terminal_mode"] = kind
        script["usage"] = usage
        script["result_sha256"] = result
        script["script_sha256"] = wire.script_sha256(script)
        events: list[wire.Record] = []
        for index in range(script["chunk_count"]):
            payload = wire.chunk_sha256(script, index)
            before = wire.response_sha256(script, index)
            chunk: wire.Record = {
                "abi_version": wire.CHUNK_ABI,
                "intent_sha256": evidence["intent"]["intent_sha256"],
                "provider_request_sha256": script["provider_request_sha256"],
                "script_sha256": script["script_sha256"],
                "chunk_index": index,
                "chunk_count": script["chunk_count"],
                "before_chain_sha256": before,
                "chunk_sha256": payload,
                "after_chain_sha256": wire.append_response_sha256(
                    before, index, payload
                ),
            }
            chunk["evidence_sha256"] = wire.chunk_evidence_sha256(chunk)
            events.append({"kind": wire.CHUNK, "chunk": chunk})
        outcome: wire.Record = {
            "abi_version": wire.OUTCOME_ABI,
            "kind": kind,
            "intent": evidence["intent"],
            "descriptor_sha256": script["descriptor_sha256"],
            "provider_request_sha256": script["provider_request_sha256"],
            "script_sha256": script["script_sha256"],
            "emitted_chunks": script["chunk_count"],
            "response_chain_sha256": wire.response_sha256(
                script, script["chunk_count"]
            ),
            "usage": usage,
            "result_sha256": result,
        }
        outcome["outcome_sha256"] = wire.outcome_sha256(outcome)
        events.append({"kind": wire.OUTCOME, "outcome": outcome})
        evidence["events"] = events
        ledger = wire._zero_ledger(wire.LEDGER_NAMES)  # noqa: SLF001
        ledger.update(
            {
                "started_attempts": 1,
                "emitted_chunks": script["chunk_count"],
                ledger_name: 1,
                "acknowledged_attempts": 1,
            }
        )
        evidence["final_snapshot"]["ledger"] = ledger
        evidence["final_cancel_snapshot"]["ledger"] = wire._zero_ledger(  # noqa: SLF001
            wire.CANCEL_LEDGER_NAMES
        )
        self._replace_settlement(
            evidence, settlement_kind, usage, result
        )
        return evidence


if __name__ == "__main__":
    unittest.main()
