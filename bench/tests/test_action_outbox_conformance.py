from __future__ import annotations

import copy
import unittest
from pathlib import Path

from bench import action_outbox_conformance as oracle


def mutate_scalar(value: object) -> object:
    if type(value) is bool:
        return not value
    if type(value) is int:
        return value + 1
    if type(value) is bytes:
        changed = bytearray(value)
        changed[0] ^= 1
        return bytes(changed)
    if type(value) is str:
        return value + "-changed"
    raise AssertionError(f"unsupported scalar mutation: {type(value)!r}")


class ActionOutboxWireAndGoldenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.campaign = oracle.reference_campaign()
        cls.report = oracle.build_report()

    def test_header_record_and_semantic_golden_roots(self) -> None:
        self.assertEqual(320, oracle.HEADER_BYTES)
        self.assertEqual(704, oracle.RECORD_BODY_BYTES)
        self.assertEqual(48, oracle.COMMIT_FOOTER_BYTES)
        self.assertEqual(752, oracle.RECORD_BYTES)
        self.assertEqual(7_840, len(self.campaign["encoded"]))
        self.assertEqual(
            oracle.REFERENCE_ROOTS,
            {name: self.report[name] for name in oracle.REFERENCE_ROOTS},
        )
        self.assertEqual(
            oracle.REFERENCE_RECORD_ROOTS,
            tuple(record["record_sha256"].hex() for record in self.campaign["records"]),
        )
        self.assertFalse(hasattr(oracle, "REFERENCE_REPORT_BYTES"))

    def test_header_and_every_record_round_trip_exactly(self) -> None:
        header = self.campaign["header"]
        encoded_header = oracle.encode_header(header)
        self.assertEqual(oracle.HEADER_BYTES, len(encoded_header))
        self.assertEqual(
            header,
            oracle.decode_header(encoded_header, header["header_sha256"]),
        )
        previous = header["header_sha256"]
        for index, expected in enumerate(self.campaign["records"], start=1):
            start = oracle.HEADER_BYTES + (index - 1) * oracle.RECORD_BYTES
            encoded = self.campaign["encoded"][start : start + oracle.RECORD_BYTES]
            with self.subTest(sequence=index):
                self.assertEqual(
                    expected, oracle.decode_record(header, index, previous, encoded)
                )
                self.assertEqual(encoded, oracle.encode_record(header, expected))
                body, footer = oracle.append_plan(
                    header,
                    index,
                    previous,
                    encoded,
                )
                self.assertEqual(oracle.RECORD_BODY_BYTES, len(body))
                self.assertEqual(oracle.COMMIT_FOOTER_BYTES, len(footer))
            previous = expected["record_sha256"]

    def test_retained_fixture_is_canonical_and_byte_equal_without_size_golden(
        self,
    ) -> None:
        fixture = (
            Path(__file__).resolve().parents[1]
            / "results"
            / "action-outbox-conformance-v1.json"
        )
        retained = fixture.read_bytes()
        expected = oracle.render_report(self.report).encode("ascii")
        self.assertEqual(expected, retained)
        decoded = oracle.load_json_exact(retained, "retained fixture")
        self.assertEqual(self.report, oracle.validate_report(decoded))
        self.assertEqual(
            self.report["report_sha256"],
            oracle.semantic_report_sha256(self.report).hex(),
        )


class ActionOutboxReplayAndRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.campaign = oracle.reference_campaign()
        cls.report = oracle.build_report()

    def test_full_primary_retry_and_compensation_replay_closes(self) -> None:
        recovered = self.campaign["recovered"]
        self.assertEqual(oracle.RECOVERY_CLEAN, recovered["status"])
        self.assertEqual(0, recovered["discarded_tail_bytes"])
        self.assertEqual(
            [
                "enqueued",
                "dispatch_intent",
                "ambiguity_observed",
                "reconciled_not_applied",
                "dispatch_intent",
                "acknowledged_success",
                "enqueued",
                "dispatch_intent",
                "ambiguity_observed",
                "reconciled_success",
            ],
            self.report["event_kinds"],
        )
        self.assertEqual(
            [0, 1, 1, 1, 2, 2, 0, 1, 1, 1],
            self.report["attempt_generations"],
        )
        self.assertEqual(
            {
                "committed_records": 10,
                "actions_enqueued": 2,
                "primary_actions": 1,
                "compensation_actions": 1,
                "dispatch_intents": 3,
                "safe_retry_dispatches": 1,
                "ambiguity_observations": 2,
                "acknowledged_successes": 1,
                "acknowledged_failures": 0,
                "reconciled_not_applied": 1,
                "reconciled_successes": 1,
                "reconciled_failures": 0,
                "ready_actions": 0,
                "uncertain_actions": 0,
                "succeeded_actions": 2,
                "failed_actions": 0,
            },
            recovered["ledger"],
        )
        self.assertEqual(2, len(recovered["states"]))
        primary, compensation = recovered["states"]
        self.assertEqual(oracle.PURPOSE_PRIMARY, primary["identity"]["purpose"])
        self.assertEqual(
            oracle.PURPOSE_COMPENSATION, compensation["identity"]["purpose"]
        )
        self.assertEqual(oracle.PHASE_SUCCEEDED, primary["phase"])
        self.assertEqual(oracle.PHASE_SUCCEEDED, compensation["phase"])
        self.assertEqual(
            primary["identity"]["action_sha256"],
            compensation["identity"]["parent_action_sha256"],
        )
        records = recovered["records"]
        self.assertEqual(
            records[1]["identity"]["stable_remote_request_sha256"],
            records[4]["identity"]["stable_remote_request_sha256"],
        )
        self.assertNotEqual(
            records[1]["dispatch_request_sha256"],
            records[4]["dispatch_request_sha256"],
        )
        oracle.verify_closed(recovered, self.campaign["anchor"])

    def test_declared_capacities_bound_logical_state(self) -> None:
        header = oracle.make_header(
            7,
            10,
            41,
            1,
            2,
            4096,
            oracle._label("bounded adapter"),  # noqa: SLF001
            oracle._label("bounded payload store"),  # noqa: SLF001
            oracle._label("bounded challenge"),  # noqa: SLF001
        )

        def identity(ordinal: int, key: str) -> oracle.Record:
            parts = oracle._reference_tool_action(  # noqa: SLF001
                ordinal,
                key,
                ordinal,
                0,
            )
            return oracle.make_action_identity(
                header,
                oracle.PURPOSE_PRIMARY,
                oracle.ZERO_DIGEST,
                parts["descriptor"],
                parts["arguments"],
                parts["proposal"],
                parts["policy"],
                parts["authorization"],
                oracle._label(f"bounded event {ordinal}"),  # noqa: SLF001
                oracle._label(f"bounded locator {ordinal}"),  # noqa: SLF001
                16,
                oracle._label(f"bounded payload {ordinal}"),  # noqa: SLF001
            )

        first = identity(1, "first bounded key")
        first_record = oracle.make_enqueued_record(
            header,
            1,
            header["header_sha256"],
            first,
        )
        states, ledger = oracle.apply_record(
            header,
            first_record,
            [],
            oracle.empty_ledger(),
        )
        second = identity(2, "second bounded key")
        second_record = oracle.make_enqueued_record(
            header,
            2,
            first_record["record_sha256"],
            second,
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.apply_record(
                header,
                second_record,
                states,
                ledger,
            )

        dispatch = oracle.make_transition_record(
            header,
            2,
            first_record["record_sha256"],
            states[0],
            oracle.EVENT_DISPATCH_INTENT,
            1,
            oracle.ZERO_DIGEST,
            oracle.ZERO_DIGEST,
        )
        states, ledger = oracle.apply_record(
            header,
            dispatch,
            states,
            ledger,
        )
        overflow = oracle.make_transition_record(
            header,
            3,
            dispatch["record_sha256"],
            states[0],
            oracle.EVENT_AMBIGUITY_OBSERVED,
            1,
            oracle._label("record limit observation"),  # noqa: SLF001
            oracle.ZERO_DIGEST,
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.apply_record(
                header,
                overflow,
                states,
                ledger,
            )

    def test_failure_records_close_and_terminal_actions_do_not_reopen(self) -> None:
        header = self.campaign["header"]
        states = copy.deepcopy(self.campaign["recovered"]["states"])
        ledger = copy.deepcopy(self.campaign["recovered"]["ledger"])
        previous = self.campaign["recovered"]["final_chain_sha256"]
        sequence = 11
        encoded_records: list[bytes] = []

        def identity(ordinal: int, key: str) -> oracle.Record:
            parts = oracle._reference_tool_action(  # noqa: SLF001
                ordinal,
                key,
                ordinal,
                0,
            )
            return oracle.make_action_identity(
                header,
                oracle.PURPOSE_PRIMARY,
                oracle.ZERO_DIGEST,
                parts["descriptor"],
                parts["arguments"],
                parts["proposal"],
                parts["policy"],
                parts["authorization"],
                oracle._label(f"failure event {ordinal}"),  # noqa: SLF001
                oracle._label(f"failure locator {ordinal}"),  # noqa: SLF001
                16,
                oracle._label(f"failure payload {ordinal}"),  # noqa: SLF001
            )

        def append(record: oracle.Record) -> None:
            nonlocal states, ledger, previous, sequence
            states, ledger = oracle.apply_record(
                header,
                record,
                states,
                ledger,
            )
            encoded_records.append(oracle.encode_record(header, record))
            previous = record["record_sha256"]
            sequence += 1

        acknowledged = identity(3, "acknowledged failure key")
        append(
            oracle.make_enqueued_record(
                header,
                sequence,
                previous,
                acknowledged,
            )
        )
        acknowledged_index = oracle._find_state(  # noqa: SLF001
            states,
            acknowledged["action_sha256"],
        )
        self.assertIsNotNone(acknowledged_index)
        append(
            oracle.make_transition_record(
                header,
                sequence,
                previous,
                states[acknowledged_index],
                oracle.EVENT_DISPATCH_INTENT,
                1,
                oracle.ZERO_DIGEST,
                oracle.ZERO_DIGEST,
            )
        )
        append(
            oracle.make_transition_record(
                header,
                sequence,
                previous,
                states[acknowledged_index],
                oracle.EVENT_ACKNOWLEDGED_FAILURE,
                1,
                oracle._label("failure acknowledgement"),  # noqa: SLF001
                oracle._label("failure result"),  # noqa: SLF001
            )
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.make_transition_record(
                header,
                sequence,
                previous,
                states[acknowledged_index],
                oracle.EVENT_DISPATCH_INTENT,
                2,
                oracle.ZERO_DIGEST,
                oracle.ZERO_DIGEST,
            )

        reconciled = identity(4, "reconciled failure key")
        append(
            oracle.make_enqueued_record(
                header,
                sequence,
                previous,
                reconciled,
            )
        )
        reconciled_index = oracle._find_state(  # noqa: SLF001
            states,
            reconciled["action_sha256"],
        )
        self.assertIsNotNone(reconciled_index)
        append(
            oracle.make_transition_record(
                header,
                sequence,
                previous,
                states[reconciled_index],
                oracle.EVENT_DISPATCH_INTENT,
                1,
                oracle.ZERO_DIGEST,
                oracle.ZERO_DIGEST,
            )
        )
        append(
            oracle.make_transition_record(
                header,
                sequence,
                previous,
                states[reconciled_index],
                oracle.EVENT_RECONCILED_FAILURE,
                1,
                oracle._label("reconciled failure observation"),  # noqa: SLF001
                oracle._label("reconciled failure result"),  # noqa: SLF001
            )
        )
        recovered = oracle.recover(
            self.campaign["encoded"] + b"".join(encoded_records),
            header["header_sha256"],
        )
        self.assertEqual(1, recovered["ledger"]["acknowledged_failures"])
        self.assertEqual(1, recovered["ledger"]["reconciled_failures"])
        self.assertEqual(2, recovered["ledger"]["failed_actions"])

    def test_every_cut_recovers_exactly_one_committed_prefix(self) -> None:
        encoded = self.campaign["encoded"]
        header = self.campaign["header"]
        boundary_recoveries = [
            oracle.recover(
                encoded[: oracle.HEADER_BYTES + count * oracle.RECORD_BYTES],
                header["header_sha256"],
            )
            for count in range(len(self.campaign["records"]) + 1)
        ]
        case_roots: list[bytes] = []
        for cut in range(oracle.HEADER_BYTES, len(encoded) + 1):
            recovered = oracle.recover(encoded[:cut], header["header_sha256"])
            payload = cut - oracle.HEADER_BYTES
            committed_records, tail = divmod(payload, oracle.RECORD_BYTES)
            expected = boundary_recoveries[committed_records]
            if tail == 0:
                expected_status = oracle.RECOVERY_CLEAN
            elif tail < oracle.RECORD_BODY_BYTES:
                expected_status = oracle.RECOVERY_SHORT_BODY_TAIL
            elif tail == oracle.RECORD_BODY_BYTES:
                expected_status = oracle.RECOVERY_BODY_WITHOUT_FOOTER
            else:
                expected_status = oracle.RECOVERY_PARTIAL_FOOTER_TAIL
            with self.subTest(cut=cut):
                self.assertEqual(expected_status, recovered["status"])
                self.assertEqual(
                    oracle.HEADER_BYTES + committed_records * oracle.RECORD_BYTES,
                    recovered["committed_bytes"],
                )
                self.assertEqual(tail, recovered["discarded_tail_bytes"])
                self.assertEqual(
                    expected["final_chain_sha256"], recovered["final_chain_sha256"]
                )
                self.assertEqual(expected["state_sha256"], recovered["state_sha256"])
                self.assertEqual(expected["ledger"], recovered["ledger"])
            case_roots.append(oracle.recovery_case_sha256(cut, recovered))
        matrix = oracle._sha(  # noqa: SLF001
            oracle.RECOVERY_MATRIX_DOMAIN,
            oracle._le_u64(oracle.HEADER_BYTES),  # noqa: SLF001
            oracle._le_u64(len(encoded)),  # noqa: SLF001
            *case_roots,
        )
        self.assertEqual(self.report["recovery_matrix_sha256"], matrix.hex())

    def test_body_without_footer_preserves_uncertain_hold_then_repairs(self) -> None:
        torn = oracle.retained_torn_case(self.campaign)
        recovered = torn["recovered"]
        self.assertEqual(oracle.RECOVERY_BODY_WITHOUT_FOOTER, recovered["status"])
        self.assertEqual(3, recovered["ledger"]["committed_records"])
        self.assertEqual(oracle.RECORD_BODY_BYTES, recovered["discarded_tail_bytes"])
        self.assertEqual(1, recovered["ledger"]["uncertain_actions"])
        self.assertEqual(0, recovered["ledger"]["ready_actions"])
        self.assertEqual(oracle.PHASE_UNCERTAIN, recovered["states"][0]["phase"])
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.make_transition_record(
                recovered["header"],
                4,
                recovered["final_chain_sha256"],
                recovered["states"][0],
                oracle.EVENT_DISPATCH_INTENT,
                2,
                oracle.ZERO_DIGEST,
                oracle.ZERO_DIGEST,
            )
        prefix = recovered["committed_bytes"]
        repaired = torn["encoded"][:prefix] + self.campaign["encoded"][prefix:]
        self.assertEqual(self.campaign["encoded"], repaired)
        final = oracle.recover(repaired, self.campaign["header"]["header_sha256"])
        self.assertEqual(
            self.campaign["recovered"]["state_sha256"], final["state_sha256"]
        )
        self.assertEqual(
            self.campaign["recovered"]["final_chain_sha256"],
            final["final_chain_sha256"],
        )

    def test_incomplete_header_and_corrupt_committed_footer_reject(self) -> None:
        header_root = self.campaign["header"]["header_sha256"]
        for cut in (0, 1, oracle.HEADER_BYTES - 1):
            with self.subTest(cut=cut):
                with self.assertRaises(oracle.ActionOutboxError):
                    oracle.recover(self.campaign["encoded"][:cut], header_root)
        corrupt = bytearray(self.campaign["encoded"])
        corrupt[-oracle.COMMIT_FOOTER_BYTES] ^= 1
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.recover(bytes(corrupt), header_root)


class ActionOutboxSemanticMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.campaign = oracle.reference_campaign()
        self.header = self.campaign["header"]

    def _reseal_record(self, value: oracle.Record) -> oracle.Record:
        changed = copy.deepcopy(value)
        changed["record_sha256"] = oracle.record_sha256(self.header, changed)
        oracle.validate_record(self.header, changed)
        return changed

    def test_resealed_dispatch_while_uncertain_is_semantically_rejected(self) -> None:
        prefix = oracle.HEADER_BYTES + 2 * oracle.RECORD_BYTES
        recovery = oracle.recover(
            self.campaign["encoded"][:prefix],
            self.header["header_sha256"],
        )
        state = recovery["states"][0]
        illegal: oracle.Record = {
            "abi_version": oracle.RECORD_ABI,
            "sequence": 3,
            "kind": oracle.EVENT_DISPATCH_INTENT,
            "attempt_generation": 2,
            "identity": copy.deepcopy(state["identity"]),
            "previous_action_event_sha256": state["last_event_sha256"],
            "previous_journal_sha256": recovery["final_chain_sha256"],
            "dispatch_request_sha256": oracle.dispatch_request_sha256(
                self.header, state["identity"], 2
            ),
            "observation_sha256": oracle.ZERO_DIGEST,
            "result_sha256": oracle.ZERO_DIGEST,
            "record_sha256": oracle.ZERO_DIGEST,
        }
        illegal = self._reseal_record(illegal)
        encoded = self.campaign["encoded"][:prefix] + oracle.encode_record(
            self.header, illegal
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.recover(encoded, self.header["header_sha256"])

    def test_resealed_compensation_before_parent_success_is_rejected(self) -> None:
        prefix = oracle.HEADER_BYTES + 2 * oracle.RECORD_BYTES
        early = oracle.make_enqueued_record(
            self.header,
            3,
            self.campaign["records"][1]["record_sha256"],
            self.campaign["compensation"],
        )
        encoded = self.campaign["encoded"][:prefix] + oracle.encode_record(
            self.header, early
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.recover(encoded, self.header["header_sha256"])

    def test_second_compensation_for_one_parent_is_rejected(self) -> None:
        second_input = oracle._reference_tool_action(  # noqa: SLF001
            3,
            "second compensation key",
            -2,
            3,
        )
        second = oracle.make_action_identity(
            self.header,
            oracle.PURPOSE_COMPENSATION,
            self.campaign["primary"]["action_sha256"],
            second_input["descriptor"],
            second_input["arguments"],
            second_input["proposal"],
            second_input["policy"],
            second_input["authorization"],
            oracle._label("second compensation event"),  # noqa: SLF001
            oracle._label("second compensation payload"),  # noqa: SLF001
            24,
            oracle._label("second compensation bytes"),  # noqa: SLF001
        )
        record = oracle.make_enqueued_record(
            self.header,
            11,
            self.campaign["recovered"]["final_chain_sha256"],
            second,
        )
        encoded = self.campaign["encoded"] + oracle.encode_record(
            self.header,
            record,
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.recover(encoded, self.header["header_sha256"])

    def test_resealed_wrong_attempt_resolution_is_rejected(self) -> None:
        prefix = oracle.HEADER_BYTES + 3 * oracle.RECORD_BYTES
        recovery = oracle.recover(
            self.campaign["encoded"][:prefix],
            self.header["header_sha256"],
        )
        valid = self.campaign["records"][3]
        changed = copy.deepcopy(valid)
        changed["previous_journal_sha256"] = recovery["final_chain_sha256"]
        changed["previous_action_event_sha256"] = recovery["states"][0][
            "last_event_sha256"
        ]
        changed["dispatch_request_sha256"] = oracle.dispatch_request_sha256(
            self.header, changed["identity"], 2
        )
        changed = self._reseal_record(changed)
        encoded = self.campaign["encoded"][:prefix] + oracle.encode_record(
            self.header, changed
        )
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.recover(encoded, self.header["header_sha256"])

    def test_field_order_extra_fields_and_unsealed_mutations_reject(self) -> None:
        cases = (
            (self.header, lambda value: oracle.validate_header(value)),
            (
                self.campaign["primary"],
                lambda value: oracle.validate_action_identity(self.header, value),
            ),
            (
                self.campaign["records"][2],
                lambda value: oracle.validate_record(self.header, value),
            ),
            (
                self.campaign["anchor"],
                lambda value: oracle.validate_closed_anchor(value),
            ),
        )
        for value, validator in cases:
            with self.subTest(fields=tuple(value), mutation="order"):
                with self.assertRaises(oracle.ActionOutboxError):
                    validator(dict(reversed(tuple(value.items()))))
            with self.subTest(fields=tuple(value), mutation="extra"):
                changed = copy.deepcopy(value)
                changed["extra"] = 0
                with self.assertRaises(oracle.ActionOutboxError):
                    validator(changed)
            for name, field in value.items():
                if isinstance(field, dict):
                    continue
                changed = copy.deepcopy(value)
                changed[name] = mutate_scalar(field)
                with self.subTest(fields=tuple(value), field=name):
                    with self.assertRaises(oracle.ActionOutboxError):
                        validator(changed)

    def test_serialized_reserved_chain_and_footer_mutations_reject(self) -> None:
        encoded_header = bytearray(oracle.encode_header(self.header))
        encoded_header[88] = 1
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.decode_header(bytes(encoded_header), self.header["header_sha256"])

        first = bytearray(
            oracle.encode_record(self.header, self.campaign["records"][0])
        )
        for offset in (72, 496, 656, oracle.RECORD_BODY_BYTES):
            changed = bytearray(first)
            changed[offset] ^= 1
            with self.subTest(offset=offset):
                with self.assertRaises(oracle.ActionOutboxError):
                    oracle.decode_record(
                        self.header,
                        1,
                        self.header["header_sha256"],
                        bytes(changed),
                    )
        changed = bytearray(first)
        changed[72] = 1
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.append_plan(
                self.header,
                1,
                self.header["header_sha256"],
                bytes(changed),
            )


class ActionOutboxReportEnvelopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = oracle.build_report()

    def test_report_and_rerooted_semantic_mutations_reject(self) -> None:
        for name, value in self.report.items():
            changed = copy.deepcopy(self.report)
            if isinstance(value, list):
                changed[name] = list(reversed(value))
            elif isinstance(value, dict):
                first = next(iter(value))
                changed[name][first] += 1
            else:
                changed[name] = mutate_scalar(value)
            with self.subTest(field=name):
                with self.assertRaises(oracle.ActionOutboxError):
                    oracle.validate_report(changed)

        rerooted = copy.deepcopy(self.report)
        rerooted["ledger"]["safe_retry_dispatches"] += 1
        rerooted["report_sha256"] = oracle.semantic_report_sha256(rerooted).hex()
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.validate_report(rerooted)

    def test_report_field_order_is_exact(self) -> None:
        self.assertEqual(oracle.REPORT_FIELDS, tuple(self.report))
        self.assertEqual(oracle.LEDGER_FIELDS, tuple(self.report["ledger"]))
        reordered = dict(reversed(tuple(self.report.items())))
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.validate_report(reordered)

    def test_duplicate_noninteger_and_noncanonical_json_reject(self) -> None:
        invalid = (
            b'{"a":1,"a":1}\n',
            b'{"nested":{"a":1,"a":1}}\n',
            b'{"a":1.0}\n',
            b'{"a":NaN}\n',
            b'{"a":-0}\n',
            b'{"a":1, "b":2}\n',
            b'{"a":1}\n\n',
            b'{"a":1}',
            b'["not","an","object"]\n',
            b'{"a":"\xff"}\n',
            b"",
        )
        for encoded in invalid:
            with self.subTest(encoded=encoded):
                with self.assertRaises(oracle.ActionOutboxError):
                    oracle.load_json_exact(encoded, "mutation")

    def test_report_renderer_rejects_non_json_values(self) -> None:
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.render_report({"value": float("nan")})
        with self.assertRaises(oracle.ActionOutboxError):
            oracle.render_report({"value": b"bytes"})


if __name__ == "__main__":
    unittest.main()
