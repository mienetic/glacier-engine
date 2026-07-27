from __future__ import annotations

from dataclasses import fields, replace
import hashlib
import json
import unittest

from bench import device_lifecycle_contract as lifecycle
from bench import device_loss_dispatch_callback_retirement as contract


def _flip(root: bytes) -> bytes:
    return bytes((root[0] ^ 1,)) + root[1:]


def _reseal_retention(
    value: contract.LossDispatchCallbackRetentionV1,
    **changes: object,
) -> contract.LossDispatchCallbackRetentionV1:
    draft = replace(
        value,
        **changes,
        retention_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        retention_sha256=(
            contract.loss_dispatch_callback_retention_root_v1(draft)
        ),
    )


def _reseal_plan(
    value: contract.LossDispatchCallbackRetirementPlanV1,
    **changes: object,
) -> contract.LossDispatchCallbackRetirementPlanV1:
    draft = replace(
        value,
        **changes,
        plan_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        plan_sha256=(
            contract.loss_dispatch_callback_retirement_plan_root_v1(
                draft
            )
        ),
    )


def _reseal_fence(
    value: contract.LossDispatchCallbackFenceV1,
    **changes: object,
) -> contract.LossDispatchCallbackFenceV1:
    draft = replace(
        value,
        **changes,
        fence_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        fence_sha256=contract.loss_dispatch_callback_fence_root_v1(
            draft
        ),
    )


def _reseal_receipt(
    value: contract.LossDispatchCallbackRetirementReceiptV1,
    **changes: object,
) -> contract.LossDispatchCallbackRetirementReceiptV1:
    draft = replace(
        value,
        **changes,
        receipt_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        receipt_sha256=(
            contract.loss_dispatch_callback_retirement_receipt_root_v1(
                draft
            )
        ),
    )


class DeviceLossDispatchCallbackRetirementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures = {
            state: contract.make_deterministic_fixture_v1(
                state,
                callback_exit_observed=state % 2,
            )
            for state in sorted(contract.VALID_RETAINED_STATES)
        }

    def test_fixed_width_layout_and_domains_are_frozen(self) -> None:
        self.assertEqual(
            contract.RETENTION_SIZE_BYTES,
            10 * 8 + 12 * 32,
        )
        self.assertEqual(
            contract.PLAN_SIZE_BYTES,
            6 * 8 + 6 * 32,
        )
        self.assertEqual(
            contract.FENCE_SIZE_BYTES,
            11 * 8 + 10 * 32,
        )
        self.assertEqual(
            contract.RECEIPT_SIZE_BYTES,
            11 * 8 + 13 * 32,
        )
        self.assertEqual(
            22,
            len(fields(contract.LossDispatchCallbackRetentionV1)),
        )
        self.assertEqual(
            12,
            len(
                fields(
                    contract.LossDispatchCallbackRetirementPlanV1
                )
            ),
        )
        self.assertEqual(
            21,
            len(fields(contract.LossDispatchCallbackFenceV1)),
        )
        self.assertEqual(
            24,
            len(
                fields(
                    contract.LossDispatchCallbackRetirementReceiptV1
                )
            ),
        )
        self.assertEqual(
            b"glacier-device-loss-dispatch-callback-retention-v1\x00",
            contract.RETENTION_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-loss-dispatch-callback-retirement-plan-v1"
            b"\x00",
            contract.PLAN_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-loss-dispatch-callback-fence-v1\x00",
            contract.FENCE_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-loss-dispatch-callback-retirement-receipt-v1"
            b"\x00",
            contract.RECEIPT_DOMAIN,
        )

    def test_four_retained_states_have_exact_canonical_shapes(
        self,
    ) -> None:
        expected = {
            contract.RETAINED_PENDING: (
                contract.NATIVE_SUBMITTED,
                0,
                0,
                contract.NATIVE_ERROR_NONE,
                0,
                True,
            ),
            contract.RETAINED_SUBMISSION_AMBIGUOUS: (
                contract.NATIVE_COMMIT_STARTED,
                contract.NATIVE_COMMAND_STATUS_UNOBSERVED,
                0,
                contract.NATIVE_ERROR_BRIDGE,
                contract.SUBMISSION_AMBIGUOUS_CODE,
                False,
            ),
            contract.RETAINED_COMPLETION_UNKNOWN: (
                contract.NATIVE_SUBMITTED,
                5,
                1,
                contract.NATIVE_ERROR_BRIDGE,
                0x201,
                False,
            ),
            contract.RETAINED_INVALID_COMPLETION: (
                contract.NATIVE_TERMINAL_STATUS_OBSERVED,
                contract.NATIVE_COMMAND_STATUS_COMPLETED,
                1,
                contract.NATIVE_ERROR_COMPLETION_VALIDATION,
                0x301,
                False,
            ),
        }
        for state, fixture in self.fixtures.items():
            retention = fixture.retention
            with self.subTest(state=state):
                contract.validate_loss_dispatch_callback_retention_v1(
                    retention
                )
                self.assertEqual(
                    expected[state],
                    (
                        retention.native_disposition,
                        retention.native_command_status,
                        retention.native_completion_observed,
                        retention.native_error_domain_kind,
                        retention.native_error_code_bits,
                        retention.backend_quarantine_sha256
                        == contract.ZERO_DIGEST,
                    ),
                )
                contract.validate_loss_dispatch_callback_retirement_plan_v1(
                    fixture.plan,
                    retention,
                    fixture.observation,
                    fixture.transition,
                )
                contract.validate_loss_dispatch_callback_fence_v1(
                    fixture.fence,
                    fixture.plan,
                    retention,
                )
                contract.validate_loss_dispatch_callback_retirement_receipt_v1(
                    fixture.receipt,
                    fixture.plan,
                    retention,
                    fixture.fence,
                )

    def test_completion_unknown_preserves_raw_status_and_observed_bit(
        self,
    ) -> None:
        fixture = self.fixtures[contract.RETAINED_COMPLETION_UNKNOWN]
        for status in (0, 4, 5, 77, contract.U64_MAX):
            for observed in (0, 1):
                candidate = _reseal_retention(
                    fixture.retention,
                    native_command_status=status,
                    native_completion_observed=observed,
                )
                with self.subTest(status=status, observed=observed):
                    contract.validate_loss_dispatch_callback_retention_v1(
                        candidate
                    )

    def test_native_removed_sources_are_eligible_and_synthetic_is_not(
        self,
    ) -> None:
        for source in (
            lifecycle.SOURCE_REMOVED_NOTIFICATION,
            lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
        ):
            fixture = contract.make_deterministic_fixture_v1(
                contract.RETAINED_PENDING,
                source=source,
            )
            with self.subTest(source=source):
                self.assertTrue(
                    contract.loss_dispatch_callback_retirement_plan_production_eligible_v1(
                        fixture.plan,
                        fixture.retention,
                        fixture.observation,
                        fixture.transition,
                    )
                )
                contract.require_production_eligible_loss_dispatch_callback_retirement_plan_v1(
                    fixture.plan,
                    fixture.retention,
                    fixture.observation,
                    fixture.transition,
                )

        synthetic = contract.make_deterministic_fixture_v1(
            contract.RETAINED_PENDING,
            source=lifecycle.SOURCE_TEST_INJECTED,
        )
        self.assertFalse(
            contract.loss_dispatch_callback_retirement_plan_production_eligible_v1(
                synthetic.plan,
                synthetic.retention,
                synthetic.observation,
                synthetic.transition,
            )
        )
        with self.assertRaises(contract.ProductionEvidenceRequired):
            contract.require_production_eligible_loss_dispatch_callback_retirement_plan_v1(
                synthetic.plan,
                synthetic.retention,
                synthetic.observation,
                synthetic.transition,
            )

    def test_callback_exit_is_diagnostic_not_a_detachment_prerequisite(
        self,
    ) -> None:
        not_exited = contract.make_deterministic_fixture_v1(
            contract.RETAINED_PENDING,
            callback_exit_observed=0,
        )
        exited = contract.make_deterministic_fixture_v1(
            contract.RETAINED_PENDING,
            callback_exit_observed=1,
        )
        for fixture in (not_exited, exited):
            contract.validate_loss_dispatch_callback_fence_v1(
                fixture.fence,
                fixture.plan,
                fixture.retention,
            )
            self.assertEqual(1, fixture.fence.native_callback_detached)
            self.assertEqual(1, fixture.fence.native_record_retained)
        self.assertEqual(
            contract.ZERO_DIGEST,
            not_exited.fence.callback_snapshot_sha256,
        )
        self.assertNotEqual(
            contract.ZERO_DIGEST,
            exited.fence.callback_snapshot_sha256,
        )
        self.assertNotEqual(
            exited.retention.native_command_status,
            exited.fence.native_command_status,
        )
        native_other = _reseal_fence(
            exited.fence,
            native_command_status=77,
            native_error_domain_kind=contract.NATIVE_ERROR_OTHER,
            native_error_code_bits=0x404,
        )
        contract.validate_loss_dispatch_callback_fence_v1(
            native_other,
            exited.plan,
            exited.retention,
        )
        invalid_bridge_snapshot = _reseal_fence(
            exited.fence,
            native_error_domain_kind=contract.NATIVE_ERROR_BRIDGE,
        )
        with self.assertRaises(contract.InvalidCallbackFence):
            contract.validate_loss_dispatch_callback_fence_v1(
                invalid_bridge_snapshot,
                exited.plan,
                exited.retention,
            )

    def test_receipt_retires_exactly_three_ownership_units_without_authority(
        self,
    ) -> None:
        for state, fixture in self.fixtures.items():
            receipt = fixture.receipt
            with self.subTest(state=state):
                self.assertEqual(
                    contract.OWNERSHIP_RETIRED_AFTER_DEVICE_LOSS,
                    receipt.outcome,
                )
                self.assertEqual(
                    (1, 1, 1),
                    (
                        receipt.released_dispatch_pin_count,
                        receipt.retired_native_command_count,
                        receipt.detached_native_callback_count,
                    ),
                )
                self.assertEqual(
                    {
                        receipt.output_authority_sha256,
                        receipt.migration_authority_sha256,
                        receipt.reset_authority_sha256,
                        receipt.physical_reclaim_authority_sha256,
                    },
                    {contract.ZERO_DIGEST},
                )

    def test_unsealed_mutation_of_every_retention_field_fails(
        self,
    ) -> None:
        value = self.fixtures[contract.RETAINED_INVALID_COMPLETION].retention
        scalar_names = {
            "abi_version",
            "retained_state",
            "dispatch_generation",
            "allocation_count",
            "pinned_device_bytes",
            "native_disposition",
            "native_command_status",
            "native_completion_observed",
            "native_error_domain_kind",
            "native_error_code_bits",
        }
        for field in fields(value):
            current = getattr(value, field.name)
            if field.name in scalar_names:
                changed_value = (
                    current - 1
                    if current == contract.U64_MAX
                    else current + 1
                )
            else:
                changed_value = _flip(current)
            changed = replace(value, **{field.name: changed_value})
            with self.subTest(field=field.name):
                with self.assertRaises(contract.InvalidCallbackRetention):
                    contract.validate_loss_dispatch_callback_retention_v1(
                        changed
                    )

    def test_unsealed_mutation_of_every_plan_field_fails(self) -> None:
        fixture = contract.make_deterministic_fixture_v1(
            contract.RETAINED_PENDING,
            callback_exit_observed=0,
        )
        value = fixture.plan
        scalar_names = {
            "abi_version",
            "source",
            "evidence_class",
            "successor_state",
            "source_sequence",
            "retirement_generation",
        }
        for field in fields(value):
            current = getattr(value, field.name)
            changed_value = (
                current + 1
                if field.name in scalar_names
                else _flip(current)
            )
            changed = replace(value, **{field.name: changed_value})
            with self.subTest(field=field.name):
                with self.assertRaises(
                    contract.InvalidCallbackRetirementPlan
                ):
                    contract.validate_loss_dispatch_callback_retirement_plan_v1(
                        changed,
                        fixture.retention,
                        fixture.observation,
                        fixture.transition,
                    )

    def test_unsealed_mutation_of_every_fence_field_fails(self) -> None:
        fixture = self.fixtures[contract.RETAINED_PENDING]
        value = fixture.fence
        scalar_names = {
            "abi_version",
            "state",
            "retained_state",
            "retirement_generation",
            "native_retirement_generation",
            "native_completion_observed",
            "native_callback_detached",
            "native_record_retained",
            "native_command_status",
            "native_error_domain_kind",
            "native_error_code_bits",
        }
        for field in fields(value):
            current = getattr(value, field.name)
            changed_value = (
                current + 1
                if field.name in scalar_names
                else _flip(current)
            )
            changed = replace(value, **{field.name: changed_value})
            with self.subTest(field=field.name):
                with self.assertRaises(contract.InvalidCallbackFence):
                    contract.validate_loss_dispatch_callback_fence_v1(
                        changed,
                        fixture.plan,
                        fixture.retention,
                    )

    def test_unsealed_mutation_of_every_receipt_field_fails(
        self,
    ) -> None:
        fixture = self.fixtures[contract.RETAINED_PENDING]
        value = fixture.receipt
        scalar_names = {
            "abi_version",
            "source",
            "evidence_class",
            "outcome",
            "retained_state",
            "source_sequence",
            "retirement_generation",
            "native_retirement_generation",
            "released_dispatch_pin_count",
            "retired_native_command_count",
            "detached_native_callback_count",
        }
        for field in fields(value):
            current = getattr(value, field.name)
            changed_value = (
                current + 1
                if field.name in scalar_names
                else _flip(current)
            )
            changed = replace(value, **{field.name: changed_value})
            with self.subTest(field=field.name):
                with self.assertRaises(
                    contract.InvalidCallbackRetirementReceipt
                ):
                    contract.validate_loss_dispatch_callback_retirement_receipt_v1(
                        changed,
                        fixture.plan,
                        fixture.retention,
                        fixture.fence,
                    )

    def test_coherently_resealed_canonical_shape_mutations_fail(
        self,
    ) -> None:
        shape_mutations = (
            (
                contract.RETAINED_PENDING,
                {"backend_quarantine_sha256": _flip(contract.ZERO_DIGEST)},
            ),
            (
                contract.RETAINED_SUBMISSION_AMBIGUOUS,
                {"native_completion_observed": 1},
            ),
            (
                contract.RETAINED_COMPLETION_UNKNOWN,
                {"native_error_code_bits": 0},
            ),
            (
                contract.RETAINED_INVALID_COMPLETION,
                {"native_command_status": 5},
            ),
        )
        for state, changes in shape_mutations:
            changed = _reseal_retention(
                self.fixtures[state].retention,
                **changes,
            )
            with self.subTest(state=state):
                with self.assertRaises(contract.InvalidCallbackRetention):
                    contract.validate_loss_dispatch_callback_retention_v1(
                        changed
                    )

        fixture = contract.make_deterministic_fixture_v1(
            contract.RETAINED_PENDING,
            callback_exit_observed=0,
        )
        fence_mutations = (
            {"native_callback_detached": 0},
            {"native_record_retained": 0},
            {"callback_snapshot_sha256": _flip(contract.ZERO_DIGEST)},
            {"native_error_domain_kind": 1},
        )
        for changes in fence_mutations:
            changed = _reseal_fence(fixture.fence, **changes)
            with self.subTest(fence_changes=changes):
                with self.assertRaises(contract.InvalidCallbackFence):
                    contract.validate_loss_dispatch_callback_fence_v1(
                        changed,
                        fixture.plan,
                        fixture.retention,
                    )

        receipt_mutations = (
            {"outcome": 5},
            {"released_dispatch_pin_count": 2},
            {"retired_native_command_count": 0},
            {"detached_native_callback_count": 2},
            {
                "output_authority_sha256": _flip(
                    contract.ZERO_DIGEST
                )
            },
            {
                "migration_authority_sha256": _flip(
                    contract.ZERO_DIGEST
                )
            },
            {"reset_authority_sha256": _flip(contract.ZERO_DIGEST)},
            {
                "physical_reclaim_authority_sha256": _flip(
                    contract.ZERO_DIGEST
                )
            },
        )
        for changes in receipt_mutations:
            changed = _reseal_receipt(fixture.receipt, **changes)
            with self.subTest(receipt_changes=changes):
                with self.assertRaises(
                    contract.InvalidCallbackRetirementReceipt
                ):
                    contract.validate_loss_dispatch_callback_retirement_receipt_v1(
                        changed,
                        fixture.plan,
                        fixture.retention,
                        fixture.fence,
                    )

    def test_substituted_records_fail_exact_binding(self) -> None:
        original = self.fixtures[contract.RETAINED_PENDING]
        foreign_retention = _reseal_retention(
            original.retention,
            adapter_challenge_sha256=_flip(
                original.retention.adapter_challenge_sha256
            ),
        )
        contract.validate_loss_dispatch_callback_retention_v1(
            foreign_retention
        )
        foreign_plan = (
            contract.make_loss_dispatch_callback_retirement_plan_v1(
                original.observation,
                original.transition,
                foreign_retention,
                original.plan.retirement_generation,
            )
        )
        with self.assertRaises(contract.InvalidCallbackRetirementPlan):
            contract.validate_loss_dispatch_callback_retirement_plan_v1(
                foreign_plan,
                original.retention,
                original.observation,
                original.transition,
            )

        foreign_fence = contract.make_loss_dispatch_callback_fence_v1(
            foreign_plan,
            foreign_retention,
            original.fence.native_retirement_generation,
            original.fence.native_prepare_sha256,
            original.fence.backend_terminal_sha256,
            native_completion_observed=0,
        )
        with self.assertRaises(contract.InvalidCallbackFence):
            contract.validate_loss_dispatch_callback_fence_v1(
                foreign_fence,
                original.plan,
                original.retention,
            )

        foreign_receipt = (
            contract.make_loss_dispatch_callback_retirement_receipt_v1(
                foreign_plan,
                foreign_retention,
                foreign_fence,
                original.receipt.dispatch_terminal_sha256,
                original.receipt.dispatch_completion_sha256,
                original.receipt.bank_completion_sha256,
                original.receipt.native_retirement_sha256,
                original.receipt.adapter_settlement_sha256,
            )
        )
        with self.assertRaises(
            contract.InvalidCallbackRetirementReceipt
        ):
            contract.validate_loss_dispatch_callback_retirement_receipt_v1(
                foreign_receipt,
                original.plan,
                original.retention,
                original.fence,
            )

    def test_free_input_replays_must_be_byte_exact(self) -> None:
        fixture = self.fixtures[contract.RETAINED_PENDING]
        changed_retention = _reseal_retention(
            fixture.retention,
            adapter_challenge_sha256=_flip(
                fixture.retention.adapter_challenge_sha256
            ),
        )
        changed_plan = _reseal_plan(
            fixture.plan,
            retirement_generation=fixture.plan.retirement_generation
            + 1,
        )
        changed_fence = _reseal_fence(
            fixture.fence,
            native_retirement_generation=(
                fixture.fence.native_retirement_generation + 1
            ),
        )
        changed_receipt = _reseal_receipt(
            fixture.receipt,
            adapter_settlement_sha256=_flip(
                fixture.receipt.adapter_settlement_sha256
            ),
        )
        replay_cases = (
            (
                contract.validate_loss_dispatch_callback_retention_replay_v1,
                changed_retention,
                fixture.retention,
                contract.InvalidCallbackRetention,
            ),
            (
                contract.validate_loss_dispatch_callback_retirement_plan_replay_v1,
                changed_plan,
                fixture.plan,
                contract.InvalidCallbackRetirementPlan,
            ),
            (
                contract.validate_loss_dispatch_callback_fence_replay_v1,
                changed_fence,
                fixture.fence,
                contract.InvalidCallbackFence,
            ),
            (
                contract.validate_loss_dispatch_callback_retirement_receipt_replay_v1,
                changed_receipt,
                fixture.receipt,
                contract.InvalidCallbackRetirementReceipt,
            ),
        )
        for validator, candidate, retained, expected_error in replay_cases:
            with self.subTest(validator=validator.__name__):
                validator(retained, retained)
                with self.assertRaises(expected_error):
                    validator(candidate, retained)

    def test_trace_rejects_duplicate_foreign_and_late_events(
        self,
    ) -> None:
        fixture = self.fixtures[contract.RETAINED_PENDING]
        valid = (
            fixture.retention,
            fixture.plan,
            fixture.fence,
            fixture.receipt,
        )
        self.assertEqual(
            fixture.receipt,
            contract.replay_loss_dispatch_callback_retirement_trace_v1(
                valid,
                fixture.observation,
                fixture.transition,
            ),
        )

        foreign = self.fixtures[
            contract.RETAINED_SUBMISSION_AMBIGUOUS
        ]
        traces = {
            "duplicate": (
                fixture.retention,
                fixture.plan,
                fixture.fence,
                fixture.fence,
                fixture.receipt,
            ),
            "foreign": (
                fixture.retention,
                foreign.plan,
                foreign.fence,
                foreign.receipt,
            ),
            "late": (
                fixture.retention,
                fixture.plan,
                fixture.receipt,
                fixture.fence,
            ),
        }
        for label, events in traces.items():
            with self.subTest(trace=label):
                with self.assertRaises(
                    contract.InvalidCallbackRetirementTrace
                ):
                    contract.replay_loss_dispatch_callback_retirement_trace_v1(
                        events,
                        fixture.observation,
                        fixture.transition,
                    )

    def test_deterministic_fixture_report_is_canonical(self) -> None:
        first = contract.deterministic_fixture_report_v1()
        second = contract.deterministic_fixture_report_v1()
        self.assertEqual(first, second)
        self.assertEqual(4, first["case_count"])
        self.assertEqual(
            {
                "5": True,
                "6": True,
                "7": False,
            },
            first["production_eligible_by_source"],
        )
        canonical = json.dumps(
            {
                key: value
                for key, value in first.items()
                if key != "report_sha256"
            },
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        self.assertEqual(
            hashlib.sha256(canonical).hexdigest(),
            first["report_sha256"],
        )
        self.assertEqual(
            "6c1efcba5d15b568316ed37111c25bc2"
            "f19da18eeda78c3b6c667d5fc0341e29",
            first["report_sha256"],
        )

    def test_bool_negative_and_overflow_scalars_fail_closed(self) -> None:
        fixture = self.fixtures[contract.RETAINED_PENDING]
        for value in (True, -1, contract.U64_MAX + 1):
            changed = replace(
                fixture.retention,
                dispatch_generation=value,
            )
            with self.subTest(value=value):
                with self.assertRaises(contract.InvalidCallbackRetention):
                    contract.validate_loss_dispatch_callback_retention_v1(
                        changed
                    )


if __name__ == "__main__":
    unittest.main()
