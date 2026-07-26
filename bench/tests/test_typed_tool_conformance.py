from __future__ import annotations

import copy
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bench import typed_tool_conformance as oracle


PLAN_ROOT = "70f9a93231f0f8250dda77ca04664bec620fd1422445298ea7bf3aeca1dfadae"
PLAN_WIRE_ROOT = "8f5923d3ea833085958fcdcc337eaea5125d3e334c2cab6fce8d22a7dd6c9bb6"
PROFILE_ROOT = "f845c402673987817d2345942dc4927273b717bb2d90c62fc57d01a7e5c149ff"
OUTCOME_ROOT = "12b71a866ecaf09b1b6982ae15625be6d6af5424b435beb641da1d0ab5b17741"
TRACE_ROOT = "26486838c786ef79e4439ade1ffce3c4853a610c7186a830ea15d5cf0b3a0d87"
SUMMARY_ROOT = "fc0ef6eaad6dfd6e93df34f1505e3d7725fc70b66997916f4cfdee4defb249d9"
RESULT_ROOT = "1ce13ab97d950b3fbc36aa4f3a060bcdee3a966537fcf382091216fe1860cab8"
DESCRIPTOR_ROOT = "b3a98a6b6ae1e15f61f576b003df9d60e8d43fcc74e16d9dddd6e2cbd04b221b"
POLICY_ROOT = "f0c364387aa04f87ca7181f01c9358a29438d4b446bd3906fb34515b77b903e4"

ARGUMENT_ROOTS = (
    "1f3c198434de351bd28ec13e63126ced61f8bb7e53511e3c8b540db2ccf703fa",
    "64f226f791c1700323c65a7e0eeb4d43ec67a99d6792ad6750f9b335ac0797ca",
    "ea47182961885deda20636d5fbf564b15799bafa28b910de652bb30adf793cca",
    "692e433853131505e6eacfe154207c5f05c5cda70b8f70fbfe49781cecf75740",
    "539590212dab44e20662704d8b1b6fa74f03621e0a67e4264ed533ab895f7cdd",
    "539590212dab44e20662704d8b1b6fa74f03621e0a67e4264ed533ab895f7cdd",
    "b1fd5f6907151c6efe05afd4ee9b678cd015dd8507837e3f6d760c12e7cc855d",
    "692e433853131505e6eacfe154207c5f05c5cda70b8f70fbfe49781cecf75740",
)
PROPOSAL_ROOTS = (
    "e0d9bf49701b957c15ef5a636fa4114bcd0bcee36f4ba26d334ceb279f3bccf0",
    "983a94767c57398ab1dc04261b9ad21b4c40d9f847ff3ee242b285a3396ede3b",
    "136722f50721185e1f127d27475cccbe69ee78770c8f20631ff0ff3843e1fd28",
    "308fe34d838600194567e8592ec22b3677ff94c31641d7b037f32cd976631d7f",
    "273f520c3470fb71cc7ffd761ce1844a77a79fda0221f9737bbfd52d5dbd9977",
    "273f520c3470fb71cc7ffd761ce1844a77a79fda0221f9737bbfd52d5dbd9977",
    "17598c1a2d4320900c9f0d42d77967619cf99897b53caeb05e71f4afb54da1d8",
    "f0e55d830ba04fe8ec49c263fac5f566d4545d48e14183f8144c6d0e0aac51b8",
)
AUTHORIZATION_ROOTS = (
    None,
    None,
    "ea0f5684e73db3d86866ad80668091ecac6a3e7b67393108d369193fa9b82f3c",
    None,
    "3ad658aa6384b9ee0b79101f2c50f2c04ebd94f8eb950f9cc43aafb82f6a6cd1",
    "3ad658aa6384b9ee0b79101f2c50f2c04ebd94f8eb950f9cc43aafb82f6a6cd1",
    "210e7356316f52abb8c2a4047216dc55c6744f52d63250e421b085d114842f46",
    "f0e9c630dc35df3fb71b8b23db04fe0af4d121547599545d78ea7a14a4ecc76a",
)
EFFECT_ROOTS = (
    None,
    None,
    "84ea9cc8495a532ccf8065d5f332626e7ae7ba9cd5bd5fdca0e9e2d2be2bbe34",
    None,
    "04d013e4982a1147828a19aebddeb96932ce669837d4e498bb0312086754718e",
    "04d013e4982a1147828a19aebddeb96932ce669837d4e498bb0312086754718e",
    None,
    "04d013e4982a1147828a19aebddeb96932ce669837d4e498bb0312086754718e",
)
DELIVERY_ROOTS = (
    None,
    None,
    "67620172e31d7eea06f70a17338817bc5dfc0c3e56f36f46400533c1f64051fc",
    None,
    "09f626be3e7501fcb67e6998be60f85b698e7dcede9c57b71d5220ca2adb7579",
    "aaec22d5f1c127a7fa48c96c71ffae35f043ae1635a3182b946104908de67919",
    "0e4fd8bdc319c9d9aeb9bd3b3abf67a6186c42a582c351ed717a15e1978a4f47",
    "b551da93546283d4e01412d542ab7c0fbaac420f788378f34b5863c8c48a0626",
)


def digest(value: str) -> bytes:
    return hashlib.sha256(value.encode("ascii")).digest()


def mutate_value(value: object) -> object:
    if type(value) is bool:
        return not value
    if type(value) is int:
        return value + 1
    if type(value) is bytes:
        encoded = bytearray(value)
        encoded[0] ^= 1
        return bytes(encoded)
    raise AssertionError(f"unsupported mutation type: {type(value)!r}")


class TypedToolContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.descriptor = oracle.reference_descriptor()
        self.policy = oracle.reference_policy(self.descriptor)
        self.arguments = oracle.reference_arguments()
        self.proposals = oracle.reference_proposals(
            self.descriptor,
            self.arguments,
        )
        self.plan = oracle.reference_plan()
        self.driver = oracle.workload.replay_plan(self.plan)
        self.tool = oracle.replay_tool_transactions(self.plan, self.driver)

    def test_cross_language_golden_roots(self) -> None:
        wire = oracle.workload.encode_plan(self.plan)
        self.assertEqual(3024, len(wire))
        self.assertEqual(PLAN_WIRE_ROOT, hashlib.sha256(wire).hexdigest())
        self.assertEqual(PLAN_ROOT, self.driver["plan_sha256"].hex())
        self.assertEqual(PROFILE_ROOT, self.plan["profiles"][0]["profile_sha256"].hex())
        self.assertEqual(OUTCOME_ROOT, self.driver["outcome_sha256"].hex())
        self.assertEqual(TRACE_ROOT, self.driver["trace_sha256"].hex())
        self.assertEqual(SUMMARY_ROOT, self.driver["summary_sha256"].hex())
        self.assertEqual(RESULT_ROOT, self.driver["result_sha256"].hex())
        self.assertEqual(DESCRIPTOR_ROOT, self.descriptor["descriptor_sha256"].hex())
        self.assertEqual(POLICY_ROOT, self.policy["policy_sha256"].hex())
        self.assertEqual(
            ARGUMENT_ROOTS,
            tuple(value["arguments_sha256"].hex() for value in self.arguments),
        )
        self.assertEqual(
            PROPOSAL_ROOTS,
            tuple(value["proposal_sha256"].hex() for value in self.proposals),
        )

        def optional_root(item: oracle.Record, name: str) -> str | None:
            value = item[name]
            return None if value is None else value[f"{name}_sha256"].hex()

        self.assertEqual(
            AUTHORIZATION_ROOTS,
            tuple(optional_root(item, "authorization") for item in self.tool["items"]),
        )
        self.assertEqual(
            EFFECT_ROOTS,
            tuple(optional_root(item, "effect") for item in self.tool["items"]),
        )
        self.assertEqual(
            DELIVERY_ROOTS,
            tuple(optional_root(item, "delivery") for item in self.tool["items"]),
        )

    def test_records_are_field_order_and_root_protected(self) -> None:
        rows = self.tool["items"]
        cases = (
            (self.descriptor, oracle.validate_descriptor),
            (self.arguments[2], oracle.validate_arguments),
            (self.proposals[2], oracle.validate_proposal),
            (self.policy, oracle.validate_policy),
            (rows[2]["authorization"], oracle.validate_authorization),
            (rows[2]["effect"], oracle.validate_effect),
            (rows[2]["delivery"], oracle.validate_delivery),
        )
        for record, validator in cases:
            assert record is not None
            with self.subTest(record=tuple(record), mutation="field-order"):
                with self.assertRaises(oracle.TypedToolError):
                    validator(dict(reversed(tuple(record.items()))))
            with self.subTest(record=tuple(record), mutation="extra-field"):
                changed = copy.deepcopy(record)
                changed["extra"] = 0
                with self.assertRaises(oracle.TypedToolError):
                    validator(changed)
            for field in record:
                changed = copy.deepcopy(record)
                changed[field] = mutate_value(changed[field])
                with self.subTest(record=tuple(record), field=field):
                    with self.assertRaises(oracle.TypedToolError):
                        validator(changed)

    def test_constructor_envelopes_fail_closed(self) -> None:
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_arguments(0, 1)
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_arguments(1, 0)
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_arguments(1, oracle.I64_MIN)
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_arguments(1, oracle.I64_MAX + 1)
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_descriptor(
                0,
                digest("namespace"),
                digest("arguments"),
                digest("result"),
                digest("implementation"),
            )
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_policy(
                1,
                1,
                1,
                8,
                -32,
                32,
                self.descriptor,
                digest("challenge"),
            )
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_policy(
                1,
                1,
                True,
                oracle.I64_MAX + 1,
                -32,
                32,
                self.descriptor,
                digest("challenge"),
            )

    def test_policy_decision_order_and_arithmetic(self) -> None:
        one = oracle.make_arguments(1, 1)
        allowed_proposal = oracle.make_proposal(
            self.policy["tenant_key"],
            100,
            digest("allowed request"),
            self.descriptor,
            one,
            digest("allowed idempotency"),
        )
        allowed = oracle.authorize_bounded_add(
            allowed_proposal,
            self.descriptor,
            one,
            self.policy,
            7,
        )
        self.assertEqual(oracle.AUTHORIZATION_ALLOWED, allowed["kind"])
        self.assertEqual(oracle.DENIAL_NONE, allowed["reason"])
        self.assertEqual(
            (7, 8), (allowed["observed_before"], allowed["projected_after"])
        )

        tenant_proposal = oracle.make_proposal(
            self.policy["tenant_key"] + 1,
            101,
            digest("tenant request"),
            self.descriptor,
            one,
            digest("tenant idempotency"),
        )
        tenant = oracle.authorize_bounded_add(
            tenant_proposal,
            self.descriptor,
            one,
            self.policy,
            0,
        )
        self.assertEqual(oracle.DENIAL_TENANT_MISMATCH, tenant["reason"])

        other_descriptor = oracle.make_descriptor(
            oracle.TOOL_WORKLOAD_ADAPTER_ABI,
            digest("other namespace"),
            digest("other arguments"),
            digest("other result"),
            digest("other implementation"),
        )
        descriptor_proposal = oracle.make_proposal(
            self.policy["tenant_key"],
            102,
            digest("descriptor request"),
            other_descriptor,
            one,
            digest("descriptor idempotency"),
        )
        descriptor = oracle.authorize_bounded_add(
            descriptor_proposal,
            other_descriptor,
            one,
            self.policy,
            0,
        )
        self.assertEqual(oracle.DENIAL_DESCRIPTOR_MISMATCH, descriptor["reason"])

        disabled_policy = oracle.make_policy(
            2,
            self.policy["tenant_key"],
            False,
            8,
            -32,
            32,
            self.descriptor,
            digest("disabled challenge"),
        )
        disabled = oracle.authorize_bounded_add(
            allowed_proposal,
            self.descriptor,
            one,
            disabled_policy,
            0,
        )
        self.assertEqual(oracle.DENIAL_TOOL_DISABLED, disabled["reason"])

        delta = oracle.authorize_bounded_add(
            self.proposals[6],
            self.descriptor,
            self.arguments[6],
            self.policy,
            8,
        )
        self.assertEqual(oracle.DENIAL_DELTA_OUT_OF_RANGE, delta["reason"])
        result = oracle.authorize_bounded_add(
            self.proposals[4],
            self.descriptor,
            self.arguments[4],
            self.policy,
            30,
        )
        self.assertEqual(oracle.DENIAL_RESULT_OUT_OF_RANGE, result["reason"])
        self.assertEqual(
            (30, 30), (result["observed_before"], result["projected_after"])
        )

        wide_policy = oracle.make_policy(
            3,
            self.policy["tenant_key"],
            True,
            8,
            oracle.I64_MIN,
            oracle.I64_MAX,
            self.descriptor,
            digest("wide challenge"),
        )
        overflow = oracle.authorize_bounded_add(
            allowed_proposal,
            self.descriptor,
            one,
            wide_policy,
            oracle.I64_MAX,
        )
        self.assertEqual(oracle.DENIAL_RESULT_OUT_OF_RANGE, overflow["reason"])
        self.assertEqual(oracle.I64_MAX, overflow["projected_after"])

    def test_resealed_substitutions_fail_composition(self) -> None:
        row = self.tool["items"][2]
        authorization = row["authorization"]
        effect = row["effect"]
        delivery = row["delivery"]
        assert authorization is not None
        assert effect is not None
        assert delivery is not None

        other_descriptor = oracle.make_descriptor(
            oracle.TOOL_WORKLOAD_ADAPTER_ABI,
            digest("substitute namespace"),
            digest("substitute arguments"),
            digest("substitute result"),
            digest("substitute implementation"),
        )
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_proposal_composition(
                self.proposals[2],
                other_descriptor,
                self.arguments[2],
            )
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_proposal_composition(
                self.proposals[2],
                self.descriptor,
                self.arguments[3],
            )
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_authorization_composition(
                authorization,
                self.proposals[4],
                self.policy,
            )
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_effect_composition(
                effect,
                self.proposals[2],
                self.arguments[3],
                authorization,
            )
        service_roots = oracle._completed_service_roots(self.driver)
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_delivery_composition(
                delivery,
                self.proposals[2],
                authorization,
                effect,
                service_roots[4],
            )

    def test_effect_requires_the_proposals_exact_arguments(self) -> None:
        authorization = self.tool["items"][2]["authorization"]
        assert authorization is not None
        same_delta_other_target = oracle.make_arguments(2, 3)
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_effect(
                1,
                self.proposals[2],
                same_delta_other_target,
                authorization,
            )

    def test_policy_denial_precedes_idempotency_conflict(self) -> None:
        stored = self.tool["items"][4]
        stored_authorization = stored["authorization"]
        stored_effect = stored["effect"]
        assert stored_authorization is not None
        assert stored_effect is not None
        denied_arguments = oracle.make_arguments(1, 9)
        denied_proposal = oracle.make_proposal(
            self.policy["tenant_key"],
            99,
            digest("policy-first conflict request"),
            self.descriptor,
            denied_arguments,
            stored["proposal"]["idempotency_key_sha256"],
        )
        transaction = oracle._resolve_completed_transaction(
            denied_proposal,
            self.descriptor,
            denied_arguments,
            self.policy,
            8,
            2,
            (
                stored["proposal"],
                stored["arguments"],
                stored_authorization,
                stored_effect,
            ),
            digest("policy-first service event"),
        )
        self.assertEqual("denied", transaction["disposition_name"])
        self.assertEqual(
            oracle.DENIAL_DELTA_OUT_OF_RANGE,
            transaction["authorization"]["reason"],
        )
        self.assertIsNone(transaction["effect"])
        self.assertEqual(8, transaction["counter_after"])
        self.assertEqual(2, transaction["execution_sequence"])

    def test_exact_replay_survives_a_fresh_policy_projection_boundary(self) -> None:
        boundary_policy = oracle.make_policy(
            10,
            self.policy["tenant_key"],
            True,
            8,
            0,
            8,
            self.descriptor,
            digest("idempotent replay boundary policy"),
        )
        arguments_a = oracle.make_arguments(1, 3)
        proposal_a = oracle.make_proposal(
            boundary_policy["tenant_key"],
            1,
            digest("boundary request A"),
            self.descriptor,
            arguments_a,
            digest("boundary idempotency A"),
        )
        arguments_b = oracle.make_arguments(1, 5)
        proposal_b = oracle.make_proposal(
            boundary_policy["tenant_key"],
            2,
            digest("boundary request B"),
            self.descriptor,
            arguments_b,
            digest("boundary idempotency B"),
        )
        executed_a = oracle._resolve_completed_transaction(
            proposal_a,
            self.descriptor,
            arguments_a,
            boundary_policy,
            0,
            0,
            None,
            digest("boundary service A"),
        )
        self.assertEqual("executed", executed_a["disposition_name"])
        self.assertEqual(3, executed_a["counter_after"])
        self.assertIsNotNone(executed_a["ledger_entry"])

        executed_b = oracle._resolve_completed_transaction(
            proposal_b,
            self.descriptor,
            arguments_b,
            boundary_policy,
            3,
            1,
            None,
            digest("boundary service B"),
        )
        self.assertEqual("executed", executed_b["disposition_name"])
        self.assertEqual(8, executed_b["counter_after"])

        fresh_projection = oracle.authorize_bounded_add(
            proposal_a,
            self.descriptor,
            arguments_a,
            boundary_policy,
            8,
        )
        self.assertEqual(
            oracle.DENIAL_RESULT_OUT_OF_RANGE,
            fresh_projection["reason"],
        )
        replayed_a = oracle._resolve_completed_transaction(
            proposal_a,
            self.descriptor,
            arguments_a,
            boundary_policy,
            8,
            2,
            executed_a["ledger_entry"],
            digest("boundary replay service A"),
        )
        self.assertEqual("reused", replayed_a["disposition_name"])
        self.assertEqual(8, replayed_a["counter_after"])
        self.assertEqual(2, replayed_a["execution_sequence"])
        self.assertEqual(
            executed_a["authorization"],
            replayed_a["authorization"],
        )
        self.assertEqual(executed_a["effect"], replayed_a["effect"])

    def test_direct_conflict_denial_requires_matching_enabled_policy(self) -> None:
        valid = oracle.deny_idempotency_conflict(
            self.proposals[7],
            self.policy,
            8,
        )
        self.assertEqual(oracle.DENIAL_IDEMPOTENCY_CONFLICT, valid["reason"])

        tenant_mismatch = oracle.make_proposal(
            self.policy["tenant_key"] + 1,
            200,
            digest("conflict tenant mismatch"),
            self.descriptor,
            self.arguments[7],
            digest("conflict tenant mismatch idempotency"),
        )
        with self.assertRaises(oracle.TypedToolError):
            oracle.deny_idempotency_conflict(
                tenant_mismatch,
                self.policy,
                8,
            )

        other_descriptor = oracle.make_descriptor(
            oracle.TOOL_WORKLOAD_ADAPTER_ABI,
            digest("conflict other namespace"),
            digest("conflict other arguments"),
            digest("conflict other result"),
            digest("conflict other implementation"),
        )
        descriptor_mismatch = oracle.make_proposal(
            self.policy["tenant_key"],
            201,
            digest("conflict descriptor mismatch"),
            other_descriptor,
            self.arguments[7],
            digest("conflict descriptor mismatch idempotency"),
        )
        with self.assertRaises(oracle.TypedToolError):
            oracle.deny_idempotency_conflict(
                descriptor_mismatch,
                self.policy,
                8,
            )

        disabled_policy = oracle.make_policy(
            11,
            self.policy["tenant_key"],
            False,
            8,
            -32,
            32,
            self.descriptor,
            digest("conflict disabled policy"),
        )
        with self.assertRaises(oracle.TypedToolError):
            oracle.deny_idempotency_conflict(
                self.proposals[7],
                disabled_policy,
                8,
            )

    def test_all_delivery_dispositions_recompose_exactly(self) -> None:
        service_roots = oracle._completed_service_roots(self.driver)
        for ordinal in (2, 4, 5, 6, 7):
            row = self.tool["items"][ordinal]
            authorization = row["authorization"]
            delivery = row["delivery"]
            assert authorization is not None
            assert delivery is not None
            with self.subTest(ordinal=ordinal):
                self.assertEqual(
                    delivery,
                    oracle.validate_delivery_composition(
                        delivery,
                        row["proposal"],
                        authorization,
                        row["effect"],
                        service_roots[ordinal],
                    ),
                )
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_delivery(
                oracle.DELIVERY_DENIED,
                self.proposals[6],
                self.tool["items"][6]["authorization"],
                self.tool["items"][4]["effect"],
                service_roots[6],
            )
        with self.assertRaises(oracle.TypedToolError):
            oracle.make_delivery(
                oracle.DELIVERY_CONFLICT,
                self.proposals[7],
                self.tool["items"][7]["authorization"],
                self.tool["items"][2]["effect"],
                service_roots[7],
            )


class TypedToolCampaignTests(unittest.TestCase):
    def setUp(self) -> None:
        self.plan = oracle.reference_plan()
        self.driver = oracle.workload.replay_plan(self.plan)
        self.tool = oracle.replay_tool_transactions(self.plan, self.driver)

    def test_reference_campaign_outcomes_and_exact_effects(self) -> None:
        self.assertEqual(
            [
                oracle.workload.OUTCOME_CANCELLED,
                oracle.workload.OUTCOME_TIMED_OUT,
                oracle.workload.OUTCOME_COMPLETED,
                oracle.workload.OUTCOME_REJECTED,
                oracle.workload.OUTCOME_COMPLETED,
                oracle.workload.OUTCOME_COMPLETED,
                oracle.workload.OUTCOME_COMPLETED,
                oracle.workload.OUTCOME_COMPLETED,
            ],
            [value["kind"] for value in self.driver["outcomes"]],
        )
        self.assertEqual(
            [
                "none",
                "none",
                "executed",
                "none",
                "executed",
                "reused",
                "denied",
                "conflict",
            ],
            self.tool["dispositions"],
        )
        self.assertEqual(
            [(0, 0), (0, 0), (0, 3), (0, 0), (3, 8), (8, 8), (8, 8), (8, 8)],
            [
                (value["counter_before"], value["counter_after"])
                for value in self.tool["items"]
            ],
        )
        self.assertEqual(8, self.tool["final_counter"])
        self.assertEqual(2, self.tool["effects"])
        self.assertEqual(
            oracle.DENIAL_DELTA_OUT_OF_RANGE,
            self.tool["items"][6]["authorization"]["reason"],
        )
        self.assertEqual(
            oracle.DENIAL_IDEMPOTENCY_CONFLICT,
            self.tool["items"][7]["authorization"]["reason"],
        )
        self.assertEqual(
            self.tool["items"][4]["effect"],
            self.tool["items"][5]["effect"],
        )
        self.assertEqual(
            self.tool["items"][4]["effect"],
            self.tool["items"][7]["effect"],
        )
        for ordinal in (0, 1, 3):
            row = self.tool["items"][ordinal]
            self.assertIsNone(row["authorization"])
            self.assertIsNone(row["effect"])
            self.assertIsNone(row["delivery"])

    def test_driver_summary_closes_all_ownership(self) -> None:
        summary = self.driver["summary"]
        self.assertEqual(
            {
                "attempted": 8,
                "admitted": 7,
                "rejected": 1,
                "completed": 5,
                "cancelled": 1,
                "timed_out": 1,
                "successful_commits": 7,
                "releases": 7,
                "final_active_reservations": 0,
                "final_committed_receipts": 0,
                "zero_orphan_ownership": True,
            },
            {
                name: summary[name]
                for name in (
                    "attempted",
                    "admitted",
                    "rejected",
                    "completed",
                    "cancelled",
                    "timed_out",
                    "successful_commits",
                    "releases",
                    "final_active_reservations",
                    "final_committed_receipts",
                    "zero_orphan_ownership",
                )
            },
        )

    def test_resealed_plan_binding_substitution_is_rejected(self) -> None:
        changed = copy.deepcopy(self.plan)
        item = copy.deepcopy(changed["items"][0])
        item["input_binding_sha256"] = self.tool["items"][1]["proposal"][
            "proposal_sha256"
        ]
        item["item_sha256"] = oracle.ZERO_DIGEST
        changed["items"][0] = oracle.workload.seal_item(item)
        changed = oracle.workload.validate_plan(changed)
        with self.assertRaises(oracle.TypedToolError):
            oracle.replay_tool_transactions(changed)

    def test_resealed_driver_result_substitution_is_rejected(self) -> None:
        changed = copy.deepcopy(self.driver)
        outcome = changed["outcomes"][2]
        outcome["served_quanta"] += 1
        outcome["record_sha256"] = oracle.workload.outcome_record_sha256(outcome)
        changed["outcome_sha256"] = oracle.workload.outcome_sha256(changed["outcomes"])
        changed["result_sha256"] = oracle.workload.result_sha256(
            changed["plan_sha256"],
            changed["outcome_sha256"],
            changed["trace_sha256"],
            changed["summary_sha256"],
        )
        with self.assertRaises(oracle.workload.TypedWorkloadError):
            oracle.replay_tool_transactions(self.plan, changed)


class TypedToolEvidenceAndReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.plan = oracle.reference_plan()
        self.driver = oracle.workload.replay_plan(self.plan)
        self.evidence = oracle.build_evidence(self.plan, self.driver)
        self.report = oracle.build_report()

    def test_evidence_hashes_and_semantic_replay_close_exactly(self) -> None:
        self.assertEqual(
            self.evidence,
            oracle.validate_evidence_by_replay(
                self.plan,
                self.driver,
                self.evidence,
            ),
        )
        self.assertEqual(
            self.evidence["item_section_sha256"],
            oracle.item_evidence_section_sha256(self.evidence["items"]),
        )
        self.assertEqual(
            self.evidence["summary"]["summary_sha256"],
            oracle.evidence_summary_sha256(self.evidence["summary"]),
        )
        self.assertEqual(
            self.evidence["evidence_sha256"],
            oracle.evidence_sha256(self.evidence),
        )
        self.assertEqual(
            [0, 0, 1, 0, 1, 2, 3, 4],
            [
                (0 if item["delivery"] is None else item["delivery"]["disposition"])
                for item in self.evidence["items"]
            ],
        )
        self.assertEqual(
            {
                "tool_calls": 5,
                "deliveries": 5,
                "executed": 2,
                "reused": 1,
                "denied": 1,
                "conflicts": 1,
                "effects": 2,
                "initial_counter": 0,
                "final_counter": 8,
                "zero_model_ownership": True,
                "zero_harness_authority": True,
                "zero_orphan_ownership": True,
            },
            {
                name: self.evidence["summary"][name]
                for name in (
                    "tool_calls",
                    "deliveries",
                    "executed",
                    "reused",
                    "denied",
                    "conflicts",
                    "effects",
                    "initial_counter",
                    "final_counter",
                    "zero_model_ownership",
                    "zero_harness_authority",
                    "zero_orphan_ownership",
                )
            },
        )

    def test_item_evidence_is_canonical_and_root_protected(self) -> None:
        item = self.evidence["items"][2]
        reordered = dict(reversed(tuple(item.items())))
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_item_evidence(reordered)
        changed = copy.deepcopy(item)
        changed["counter_after"] += 1
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_item_evidence(changed)
        changed = copy.deepcopy(item)
        changed["record_sha256"] = mutate_value(changed["record_sha256"])
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_item_evidence(changed)

    def test_resealed_item_evidence_mutation_fails_semantic_replay(self) -> None:
        changed = copy.deepcopy(self.evidence)
        item = changed["items"][2]
        item["counter_after"] += 1
        item["record_sha256"] = oracle.item_evidence_sha256(item)
        changed["item_section_sha256"] = oracle.item_evidence_section_sha256(
            changed["items"]
        )
        changed["evidence_sha256"] = oracle.evidence_sha256(changed)
        oracle.validate_evidence_structure(changed)
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_evidence_by_replay(
                self.plan,
                self.driver,
                changed,
            )

    def test_resealed_summary_mutation_fails_semantic_replay(self) -> None:
        changed = copy.deepcopy(self.evidence)
        changed["summary"]["final_counter"] += 1
        changed["summary"]["summary_sha256"] = oracle.evidence_summary_sha256(
            changed["summary"]
        )
        changed["evidence_summary_sha256"] = changed["summary"]["summary_sha256"]
        changed["evidence_sha256"] = oracle.evidence_sha256(changed)
        oracle.validate_evidence_structure(changed)
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_evidence_by_replay(
                self.plan,
                self.driver,
                changed,
            )

    def test_actual_report_matches_frozen_field_order(self) -> None:
        self.assertEqual(oracle.REPORT_FIELDS, tuple(self.report))
        self.assertEqual(
            oracle.workload.DRIVER_REPORT_SUMMARY_FIELDS,
            tuple(self.report["driver_summary"]),
        )
        self.assertEqual(
            oracle.REPORT_PEAK_FIELDS,
            tuple(self.report["driver_summary"]["peak"]),
        )
        self.assertEqual(
            oracle.EVIDENCE_REPORT_SUMMARY_FIELDS,
            tuple(self.report["evidence_summary"]),
        )
        self.assertEqual(
            [
                "cancelled",
                "timed_out",
                "completed",
                "rejected",
                "completed",
                "completed",
                "completed",
                "completed",
            ],
            self.report["outcomes"],
        )
        self.assertEqual(
            [
                "none",
                "none",
                "executed",
                "none",
                "executed",
                "reused",
                "denied",
                "conflict",
            ],
            self.report["dispositions"],
        )
        encoded = oracle.render_report(self.report).encode("ascii")
        self.assertEqual(1, encoded.count(b"\n"))
        self.assertTrue(encoded.endswith(b"\n"))
        decoded = oracle._load_json_exact(encoded, "actual report")
        self.assertEqual(self.report, oracle.validate_report(decoded))
        self.assertEqual(encoded, oracle.render_report().encode("ascii"))

    def test_retained_fixture_matches_every_golden_byte(self) -> None:
        fixture = (
            Path(__file__).resolve().parents[1]
            / "results"
            / "typed-tool-conformance-v1.json"
        )
        retained = fixture.read_bytes()
        expected = oracle.render_report(self.report).encode("ascii")
        self.assertEqual(oracle.REFERENCE_REPORT_BYTES, len(retained))
        self.assertEqual(
            oracle.REFERENCE_REPORT_SHA256,
            hashlib.sha256(retained).hexdigest(),
        )
        self.assertEqual(expected, retained)
        restored = oracle._load_json_exact(retained, "retained fixture")
        self.assertEqual(self.report, oracle.validate_report(restored))
        self.assertEqual(
            oracle.REFERENCE_REPORT_ROOTS,
            {name: restored[name] for name in oracle.REFERENCE_REPORT_ROOTS},
        )

    def test_canonical_stale_fixture_mutation_is_rejected(self) -> None:
        stale = copy.deepcopy(self.report)
        root = stale["evidence_sha256"]
        stale["evidence_sha256"] = ("0" if root[0] != "0" else "1") + root[1:]
        stale_bytes = oracle.render_report(stale).encode("ascii")
        self.assertEqual(
            stale,
            oracle._load_json_exact(stale_bytes, "stale fixture"),
        )
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_report(stale)

        expected = oracle.render_report(self.report).encode("ascii")
        runner = [
            sys.executable,
            "-c",
            (f"import sys;sys.stdout.buffer.write({expected!r})"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "stale.json"
            fixture.write_bytes(stale_bytes)
            with self.assertRaises(oracle.TypedToolError):
                oracle.verify_runner(runner, fixture)

    def test_actual_report_mutations_are_rejected(self) -> None:
        changed_root = copy.deepcopy(self.report)
        root = changed_root["evidence_sha256"]
        changed_root["evidence_sha256"] = ("0" if root[0] != "0" else "1") + root[1:]
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_report(changed_root)

        changed_summary = copy.deepcopy(self.report)
        changed_summary["evidence_summary"]["final_counter"] += 1
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_report(changed_summary)

        changed_disposition = copy.deepcopy(self.report)
        changed_disposition["dispositions"][7] = "denied"
        with self.assertRaises(oracle.TypedToolError):
            oracle.validate_report(changed_disposition)

    def test_actual_atomic_report_and_runner_match_byte_for_byte(self) -> None:
        expected = oracle.render_report(self.report).encode("ascii")
        runner = [
            sys.executable,
            "-c",
            (f"import sys;sys.stdout.buffer.write({expected!r})"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "nested" / "report.json"
            oracle.write_report(fixture)
            self.assertEqual(expected, fixture.read_bytes())
            oracle.verify_runner(runner, fixture)


class CanonicalEnvelopeTests(unittest.TestCase):
    def test_exact_compact_ascii_line_round_trips(self) -> None:
        value = {
            "schema": "test/v1",
            "count": 2,
            "nested": {"closed": True},
            "items": ["executed", "denied"],
        }
        encoded = oracle.render_report(value).encode("ascii")
        self.assertEqual(value, oracle._load_json_exact(encoded, "test"))

    def test_duplicate_fields_are_rejected_at_every_depth(self) -> None:
        for encoded in (
            b'{"a":1,"a":1}\n',
            b'{"nested":{"a":1,"a":1}}\n',
        ):
            with self.subTest(encoded=encoded):
                with self.assertRaises(oracle.TypedToolError):
                    oracle._load_json_exact(encoded, "test")

    def test_truncation_multiple_lines_and_noncanonical_json_fail(self) -> None:
        valid = b'{"a":1,"b":true}\n'
        invalid = (
            valid[:-1],
            valid + b"\n",
            b"\n" + valid,
            b'{"a":1, "b":true}\n',
            b'{"a":1,"b":true} \n',
            b'{"a":1.0,"b":true}\n',
            b'{"a":NaN,"b":true}\n',
            b'{"a":-0,"b":true}\n',
            b'{"a":"\\u0062"}\n',
            b'["not","an","object"]\n',
            b'{"a":"\xff"}\n',
            b"",
        )
        for encoded in invalid:
            with self.subTest(encoded=encoded):
                with self.assertRaises(oracle.TypedToolError):
                    oracle._load_json_exact(encoded, "test")

    def test_json_envelope_and_renderer_fail_closed(self) -> None:
        oversized = b" " * (oracle.MAXIMUM_JSON_BYTES + 1)
        with self.assertRaises(oracle.TypedToolError):
            oracle._load_json_exact(oversized, "test")
        with self.assertRaises(oracle.TypedToolError):
            oracle._load_json_exact("not bytes", "test")
        with self.assertRaises(oracle.TypedToolError):
            oracle.render_report({"not_finite": float("nan")})
        with self.assertRaises(oracle.TypedToolError):
            oracle.render_report({"not_json": b"bytes"})

    def test_report_validation_is_order_and_type_exact(self) -> None:
        expected = {
            "schema": "test/v1",
            "count": 1,
            "closed": True,
        }
        with mock.patch.object(
            oracle,
            "build_report",
            return_value=expected,
            create=True,
        ):
            self.assertEqual(expected, oracle.validate_report(copy.deepcopy(expected)))
            reordered = {
                "closed": True,
                "count": 1,
                "schema": "test/v1",
            }
            with self.assertRaises(oracle.TypedToolError):
                oracle.validate_report(reordered)
            wrong_boolean = copy.deepcopy(expected)
            wrong_boolean["count"] = True
            with self.assertRaises(oracle.TypedToolError):
                oracle.validate_report(wrong_boolean)

    def test_atomic_fixture_and_runner_must_match_exactly(self) -> None:
        expected = {
            "schema": "test/v1",
            "count": 2,
            "closed": True,
        }
        expected_bytes = oracle.render_report(expected).encode("ascii")
        runner = [
            sys.executable,
            "-c",
            (f"import sys;sys.stdout.buffer.write({expected_bytes!r})"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "nested" / "fixture.json"
            with mock.patch.object(
                oracle,
                "build_report",
                return_value=expected,
                create=True,
            ):
                oracle.write_report(fixture)
                self.assertEqual(expected_bytes, fixture.read_bytes())
                self.assertEqual([], list(fixture.parent.glob("*.tmp")))
                oracle.verify_runner(runner, fixture)

                fixture.write_bytes(b'{"schema":"test/v1","count":3,"closed":true}\n')
                with self.assertRaises(oracle.TypedToolError):
                    oracle.verify_runner(runner, fixture)

    def test_runner_output_stderr_exit_and_command_fail_closed(self) -> None:
        expected = {"schema": "test/v1", "count": 2}
        expected_bytes = oracle.render_report(expected).encode("ascii")
        cases = (
            [
                sys.executable,
                "-c",
                'print(\'{"schema":"test/v1", "count":2}\')',
            ],
            [
                sys.executable,
                "-c",
                (
                    "import sys;"
                    f"sys.stdout.buffer.write({expected_bytes!r});"
                    "sys.stderr.write('unexpected')"
                ),
            ],
            [
                sys.executable,
                "-c",
                (f"import sys;sys.stdout.buffer.write({expected_bytes!r});sys.exit(7)"),
            ],
        )
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            fixture.write_bytes(expected_bytes)
            with mock.patch.object(
                oracle,
                "build_report",
                return_value=expected,
                create=True,
            ):
                for runner in cases:
                    with self.subTest(runner=runner):
                        with self.assertRaises(oracle.TypedToolError):
                            oracle.verify_runner(runner, fixture)
                with self.assertRaises(oracle.TypedToolError):
                    oracle.verify_runner([], fixture)


if __name__ == "__main__":
    unittest.main()
