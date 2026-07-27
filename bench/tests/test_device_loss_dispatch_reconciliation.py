from __future__ import annotations

from dataclasses import fields, replace
import unittest

from bench import device_allocation_lease as allocation
from bench import device_allocation_lease_tree as allocation_tree
from bench import device_capability_contract as device
from bench import device_lifecycle_contract as lifecycle
from bench import device_loss_dispatch_reconciliation as contract


def _flip(root: bytes) -> bytes:
    return bytes((root[0] ^ 1,)) + root[1:]


def _reseal_retention(
    value: contract.LossDispatchRetentionV1,
    **changes: object,
) -> contract.LossDispatchRetentionV1:
    draft = replace(
        value,
        **changes,
        retention_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        retention_sha256=contract.loss_dispatch_retention_root_v1(
            draft
        ),
    )


def _reseal_plan(
    value: contract.LossDispatchReconciliationPlanV1,
    **changes: object,
) -> contract.LossDispatchReconciliationPlanV1:
    draft = replace(
        value,
        **changes,
        plan_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        plan_sha256=(
            contract.loss_dispatch_reconciliation_plan_root_v1(draft)
        ),
    )


def _reseal_receipt(
    value: contract.LossDispatchReconciliationReceiptV1,
    **changes: object,
) -> contract.LossDispatchReconciliationReceiptV1:
    draft = replace(
        value,
        **changes,
        receipt_sha256=contract.ZERO_DIGEST,
    )
    return replace(
        draft,
        receipt_sha256=(
            contract.loss_dispatch_reconciliation_receipt_root_v1(
                draft
            )
        ),
    )


class _Fixture:
    def __init__(
        self,
        source: int = lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
    ) -> None:
        capability = device.make_fixture_capability(
            device.BACKEND_METAL,
            device.DEVICE_ACCELERATOR,
            "loss dispatch reconciliation gpu",
        )
        self.capability = device.seal_capability(
            replace(
                capability,
                feature_bits=(
                    capability.feature_bits
                    | device.FEATURE_DEVICE_LOSS_SIGNAL
                ),
                capability_sha256=contract.ZERO_DIGEST,
            )
        )
        self.selected_entry = device.make_fixture_entry(
            self.capability,
            epoch=29,
            rank=2,
        )
        self.inventory = (self.selected_entry,)
        self.requirement = device.make_fixture_requirement(
            device.FALLBACK_FORBIDDEN
        )
        self.selection = device.select_device(
            self.requirement,
            self.inventory,
        ).receipt

        self.bindings = allocation_tree.MetalMatvecAllocationBindingsV1(
            packed_weights_sha256=allocation.digest_v1(
                b"loss dispatch packed binding"
            ),
            scales_sha256=allocation.digest_v1(
                b"loss dispatch scales binding"
            ),
            input_sha256=allocation.digest_v1(
                b"loss dispatch input binding"
            ),
            output_sha256=allocation.digest_v1(
                b"loss dispatch output binding"
            ),
        )
        self.attempt = (
            allocation_tree.make_metal_matvec_pre_submit_attempt_v1(
                self.bindings,
                1_184,
                296,
                64,
                37,
                8,
                64,
                37,
            )
        )
        self.dispatch_authority = allocation.digest_v1(
            b"loss dispatch authority"
        )
        self.queue_authority = allocation.digest_v1(
            b"loss dispatch queue authority"
        )
        self.request = (
            allocation_tree.make_metal_matvec_dispatch_request_v1(
                1,
                self.dispatch_authority,
                self.queue_authority,
                self.attempt,
            )
        )
        base = allocation_tree.make_dispatch_campaign(
            allocation_tree.DISPATCH_TERMINAL_FAILURE,
            dispatch_authority_sha256=self.dispatch_authority,
            queue_authority_sha256=self.queue_authority,
            dispatch_request_sha256=self.request.request_sha256,
        )
        lease_draft = replace(
            base.allocation_campaign.lease_2,
            selection_receipt_sha256=self.selection.receipt_sha256,
            selected_capability_sha256=(
                self.capability.capability_sha256
            ),
            lease_sha256=contract.ZERO_DIGEST,
        )
        self.lease = replace(
            lease_draft,
            lease_sha256=allocation_tree.lease_root_v1(lease_draft),
        )
        allocation_tree.validate_lease_v1(self.lease)

        pin_draft = replace(
            base.pin,
            lease_sha256=self.lease.lease_sha256,
            pin_sha256=contract.ZERO_DIGEST,
        )
        self.pin = replace(
            pin_draft,
            pin_sha256=allocation_tree.dispatch_pin_root_v1(
                pin_draft
            ),
        )
        allocation_tree.validate_dispatch_pin_v1(self.pin)

        self.terminal = allocation_tree.make_dispatch_terminal_v1(
            self.pin,
            allocation_tree.DISPATCH_TERMINAL_FAILURE,
            base.submission_sha256,
            base.backend_completion_sha256,
            contract.ZERO_DIGEST,
        )
        completion_draft = replace(
            base.completion,
            pin_sha256=self.pin.pin_sha256,
            dispatch_terminal_sha256=self.terminal.terminal_sha256,
            completion_sha256=contract.ZERO_DIGEST,
        )
        self.completion = replace(
            completion_draft,
            completion_sha256=(
                allocation_tree.dispatch_completion_root_v1(
                    completion_draft
                )
            ),
        )
        allocation_tree.validate_dispatch_completion_for_pin_v1(
            self.completion,
            self.pin,
            self.terminal,
        )

        self.ticket = (
            allocation_tree.make_metal_async_dispatch_ticket_v1(
                21,
                self.request,
                self.pin,
                self.terminal.submission_sha256,
            )
        )
        self.device_sha256 = allocation.digest_v1(
            b"loss dispatch Metal device"
        )
        self.placement_sha256 = allocation.digest_v1(
            b"loss dispatch Metal placement"
        )
        self.quarantine = (
            allocation_tree.make_metal_async_dispatch_quarantine_v1(
                self.ticket,
                self.device_sha256,
                self.placement_sha256,
                allocation_tree.METAL_ASYNC_TERMINAL_COMMAND_ERROR,
                allocation_tree.METAL_ASYNC_TERMINAL_STATUS_OBSERVED,
                allocation_tree.METAL_ASYNC_COMMAND_STATUS_ERROR,
                1,
                allocation_tree.METAL_ASYNC_ERROR_COMMAND_BUFFER,
                lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
            )
        )
        self.adapter_challenge = allocation.digest_v1(
            b"loss dispatch adapter challenge"
        )
        evidence_class = (
            lifecycle.EVIDENCE_SYNTHETIC
            if source == lifecycle.SOURCE_TEST_INJECTED
            else lifecycle.EVIDENCE_NATIVE
        )
        self.retention = contract.make_loss_dispatch_retention_v1(
            source,
            evidence_class,
            self.selected_entry,
            self.lease,
            self.pin,
            self.terminal.submission_sha256,
            self.quarantine.quarantine_sha256,
            self.adapter_challenge,
        )

        self.source_instance = device.digest_v1(
            "loss dispatch lifecycle source"
        )
        self.source_sequence = 13
        native_fields = (
            (
                lifecycle.COMMAND_BUFFER_STATUS_ERROR,
                lifecycle.COMMAND_BUFFER_ERROR_DOMAIN,
                lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
            )
            if source
            == lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
            else (0, 0, 0)
        )
        self.observation = lifecycle.make_observation(
            self.selected_entry,
            self.inventory,
            self.source_instance,
            self.source_sequence,
            source,
            device.digest_v1("loss dispatch lifecycle evidence"),
            *native_fields,
        )
        self.cursor = lifecycle.SourceCursorV1(
            self.source_instance,
            self.source_sequence - 1,
        )
        self.successor_entry = lifecycle.make_successor_entry(
            self.observation,
            self.selected_entry,
            self.inventory,
            self.cursor,
            30,
        )
        self.transition = lifecycle.make_transition_receipt(
            self.observation,
            self.selected_entry,
            self.inventory,
            self.successor_entry,
            self.cursor,
        )
        self.plan = (
            contract.make_loss_dispatch_reconciliation_plan_v1(
                self.observation,
                self.transition,
                self.cursor,
                self.requirement,
                self.selection,
                self.inventory,
                self.selected_entry,
                self.successor_entry,
                self.retention,
                self.lease,
                self.pin,
                17,
            )
        )
        self.adapter_settlement = allocation.digest_v1(
            b"loss dispatch adapter settlement"
        )
        self.receipt = (
            contract.make_loss_dispatch_reconciliation_receipt_v1(
                self.plan,
                self.retention,
                self.selected_entry,
                self.lease,
                self.pin,
                self.terminal,
                self.completion,
                self.adapter_settlement,
            )
        )

    def validate_retention(
        self,
        value: contract.LossDispatchRetentionV1,
        **overrides: object,
    ) -> None:
        arguments = {
            "selected_entry": self.selected_entry,
            "lease": self.lease,
            "pin": self.pin,
        }
        arguments.update(overrides)
        contract.validate_loss_dispatch_retention_v1(
            value,
            **arguments,
        )

    def validate_plan(
        self,
        value: contract.LossDispatchReconciliationPlanV1,
        **overrides: object,
    ) -> None:
        arguments = {
            "observation": self.observation,
            "transition": self.transition,
            "source_cursor": self.cursor,
            "requirement": self.requirement,
            "selection": self.selection,
            "prior_inventory": self.inventory,
            "selected_entry": self.selected_entry,
            "successor_entry": self.successor_entry,
            "retention": self.retention,
            "lease": self.lease,
            "pin": self.pin,
        }
        arguments.update(overrides)
        contract.validate_loss_dispatch_reconciliation_plan_v1(
            value,
            **arguments,
        )

    def validate_receipt(
        self,
        value: contract.LossDispatchReconciliationReceiptV1,
        **overrides: object,
    ) -> None:
        arguments = {
            "plan": self.plan,
            "retention": self.retention,
            "selected_entry": self.selected_entry,
            "lease": self.lease,
            "pin": self.pin,
            "terminal": self.terminal,
            "completion": self.completion,
        }
        arguments.update(overrides)
        contract.validate_loss_dispatch_reconciliation_receipt_v1(
            value,
            **arguments,
        )


class DeviceLossDispatchReconciliationOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = _Fixture()

    def test_literal_abi_layout_domains_and_golden_roots(self) -> None:
        self.assertEqual(0x4744_4454_0000_0001, contract.RETENTION_ABI)
        self.assertEqual(0x4744_4450_0000_0001, contract.PLAN_ABI)
        self.assertEqual(0x4744_4452_0000_0001, contract.RECEIPT_ABI)
        self.assertEqual(440, contract.RETENTION_SIZE_BYTES)
        self.assertEqual(240, contract.PLAN_SIZE_BYTES)
        self.assertEqual(448, contract.RECEIPT_SIZE_BYTES)
        self.assertEqual(
            b"glacier-device-loss-dispatch-retention-v1\x00",
            contract.RETENTION_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-loss-dispatch-reconciliation-plan-v1\x00",
            contract.PLAN_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-loss-dispatch-reconciliation-receipt-v1\x00",
            contract.RECEIPT_DOMAIN,
        )
        self.assertEqual(
            (
                "abi_version",
                "kind",
                "source",
                "evidence_class",
                "dispatch_generation",
                "allocation_count",
                "pinned_device_bytes",
                "native_command_status",
                "native_completion_observed",
                "native_error_domain_kind",
                "native_error_code_bits",
                "selected_capability_sha256",
                "allocation_lease_sha256",
                "allocation_leaf_set_sha256",
                "backend_object_set_sha256",
                "dispatch_pin_sha256",
                "dispatch_request_sha256",
                "submission_sha256",
                "backend_quarantine_sha256",
                "adapter_challenge_sha256",
                "output_authority_sha256",
                "retention_sha256",
            ),
            tuple(field.name for field in fields(self.fixture.retention)),
        )
        self.assertEqual(
            (
                "abi_version",
                "source",
                "evidence_class",
                "successor_state",
                "source_sequence",
                "reconciliation_generation",
                "source_instance_sha256",
                "observation_sha256",
                "transition_receipt_sha256",
                "selected_capability_sha256",
                "retention_sha256",
                "plan_sha256",
            ),
            tuple(field.name for field in fields(self.fixture.plan)),
        )
        self.assertEqual(
            (
                "abi_version",
                "source",
                "evidence_class",
                "outcome",
                "source_sequence",
                "reconciliation_generation",
                "released_dispatch_pin_count",
                "finalized_native_command_count",
                "plan_sha256",
                "retention_sha256",
                "backend_terminal_sha256",
                "dispatch_terminal_sha256",
                "dispatch_completion_sha256",
                "bank_completion_sha256",
                "adapter_settlement_sha256",
                "output_authority_sha256",
                "migration_authority_sha256",
                "reset_authority_sha256",
                "physical_reclaim_authority_sha256",
                "receipt_sha256",
            ),
            tuple(field.name for field in fields(self.fixture.receipt)),
        )
        fixture = self.fixture
        actual = {
            "capability": fixture.capability.capability_sha256.hex(),
            "selection": fixture.selection.receipt_sha256.hex(),
            "lease": fixture.lease.lease_sha256.hex(),
            "pin": fixture.pin.pin_sha256.hex(),
            "quarantine": fixture.quarantine.quarantine_sha256.hex(),
            "observation": fixture.observation.observation_sha256.hex(),
            "transition": fixture.transition.receipt_sha256.hex(),
            "backend_terminal": (
                fixture.terminal.backend_completion_sha256.hex()
            ),
            "dispatch_terminal": fixture.terminal.terminal_sha256.hex(),
            "dispatch_completion": (
                fixture.completion.completion_sha256.hex()
            ),
            "bank_completion": (
                fixture.completion.bank_completion_sha256.hex()
            ),
            "retention": fixture.retention.retention_sha256.hex(),
            "plan": fixture.plan.plan_sha256.hex(),
            "receipt": fixture.receipt.receipt_sha256.hex(),
        }
        expected = {
            "capability": (
                "d517713178ddb47b083a8146ff2814938"
                "ede7ff303503f9fd9b03a3a2bae34f1"
            ),
            "selection": (
                "2e7513fd4e465d2fc134f0f2dad48de8"
                "c44ce25c89519ad04da0fafdfd166a3d"
            ),
            "lease": (
                "b177b592c28e7ff61ac80e5f92f43694"
                "521cce23a4a9c7d6c489fdcf868c7e52"
            ),
            "pin": (
                "1ba862aae092d41fe7d06ecea80c56b1"
                "74187fa51eca1c9812e5376c6d8f8706"
            ),
            "quarantine": (
                "98cdc1044234658dfe3f37b3495cb7ad"
                "b65f50def52734800ea4ebc0a37a74f4"
            ),
            "observation": (
                "a613cf07bd6d23d702f8c41f5b857129"
                "046ac78b8d1f7432c300cb360aa8a915"
            ),
            "transition": (
                "662a3566523e0272fe57dd6b086b011c"
                "c2d3395513f4801baa73e01ce81eef70"
            ),
            "backend_terminal": (
                "79e5cd1dfd26da50a47e5e95fd9713c"
                "276d3d6648007064f12186fdcb6055752"
            ),
            "dispatch_terminal": (
                "78c77671ae02c2e0c98fbf513e893308"
                "1c40a6607d3b6f271be0bfa0a4987cda"
            ),
            "dispatch_completion": (
                "031cc1976d01d3120ca67c8938d961ce"
                "252fbae825464f5bfd61f43c50104774"
            ),
            "bank_completion": (
                "5b36b09cda490e0c9012ccd66feec19a"
                "56fa15b0553934d5fb066969811b3f1d"
            ),
            "retention": (
                "0f3d18730e2e59fcf70c24e1f5206615"
                "7dc98244b3f5854065d30c96066eeecc"
            ),
            "plan": (
                "fea6ba513a642cc56ea302621c10c5df"
                "a009abb2b151f56efe6efbaa253da54a"
            ),
            "receipt": (
                "eb581acbaf570c52c8e19fd349e1529b"
                "ec5f410f3486a715e4f8cd25fb6831ff"
            ),
        }
        self.assertEqual(expected, actual)

    def test_exact_native_5_1_11_is_production_eligible(self) -> None:
        fixture = self.fixture
        self.assertEqual(
            (5, 1, 1, 11),
            (
                fixture.retention.native_command_status,
                fixture.retention.native_completion_observed,
                fixture.retention.native_error_domain_kind,
                fixture.retention.native_error_code_bits,
            ),
        )
        self.assertEqual(
            (5, 1, 11),
            (
                fixture.observation.native_command_status,
                fixture.observation.native_error_domain_kind,
                fixture.observation.native_error_code_bits,
            ),
        )
        self.assertEqual(
            (5, 1, 11),
            (
                fixture.quarantine.native_command_status,
                fixture.quarantine.native_completion_observed,
                fixture.quarantine.error_code_bits,
            ),
        )
        self.assertTrue(
            contract.loss_dispatch_reconciliation_plan_production_eligible_v1(
                fixture.plan,
                fixture.retention,
                fixture.observation,
                fixture.transition,
            )
        )
        contract.require_production_eligible_loss_dispatch_reconciliation_plan_v1(
            fixture.plan,
            fixture.retention,
            fixture.observation,
            fixture.transition,
        )

    def test_synthetic_transcript_is_structural_not_production(self) -> None:
        fixture = _Fixture(lifecycle.SOURCE_TEST_INJECTED)
        fixture.validate_retention(fixture.retention)
        fixture.validate_plan(fixture.plan)
        fixture.validate_receipt(fixture.receipt)
        self.assertFalse(
            contract.loss_dispatch_reconciliation_plan_production_eligible_v1(
                fixture.plan,
                fixture.retention,
                fixture.observation,
                fixture.transition,
            )
        )
        with self.assertRaises(contract.ProductionEvidenceRequired):
            contract.require_production_eligible_loss_dispatch_reconciliation_plan_v1(
                fixture.plan,
                fixture.retention,
                fixture.observation,
                fixture.transition,
            )

    def test_retention_binds_every_serialized_field(self) -> None:
        retention = self.fixture.retention
        scalar_fields = {
            "abi_version",
            "kind",
            "source",
            "evidence_class",
            "dispatch_generation",
            "allocation_count",
            "pinned_device_bytes",
            "native_command_status",
            "native_completion_observed",
            "native_error_domain_kind",
            "native_error_code_bits",
        }
        for field in fields(retention):
            if field.name == "retention_sha256":
                changed = replace(
                    retention,
                    retention_sha256=_flip(
                        retention.retention_sha256
                    ),
                )
            elif field.name in scalar_fields:
                changed = replace(
                    retention,
                    **{field.name: getattr(retention, field.name) + 1},
                )
            else:
                changed = replace(
                    retention,
                    **{
                        field.name: _flip(
                            getattr(retention, field.name)
                        )
                    },
                )
            with self.subTest(field=field.name):
                with self.assertRaises(
                    contract.InvalidLossDispatchRetention
                ):
                    self.fixture.validate_retention(changed)

    def test_plan_binds_every_serialized_field(self) -> None:
        plan = self.fixture.plan
        scalar_fields = {
            "abi_version",
            "source",
            "evidence_class",
            "successor_state",
            "source_sequence",
            "reconciliation_generation",
        }
        for field in fields(plan):
            if field.name == "plan_sha256":
                changed = replace(
                    plan,
                    plan_sha256=_flip(plan.plan_sha256),
                )
            elif field.name in scalar_fields:
                changed = replace(
                    plan,
                    **{field.name: getattr(plan, field.name) + 1},
                )
            else:
                changed = replace(
                    plan,
                    **{
                        field.name: _flip(getattr(plan, field.name))
                    },
                )
            with self.subTest(field=field.name):
                with self.assertRaises(
                    contract.InvalidLossDispatchReconciliationPlan
                ):
                    self.fixture.validate_plan(changed)

    def test_receipt_binds_every_serialized_field(self) -> None:
        receipt = self.fixture.receipt
        scalar_fields = {
            "abi_version",
            "source",
            "evidence_class",
            "outcome",
            "source_sequence",
            "reconciliation_generation",
            "released_dispatch_pin_count",
            "finalized_native_command_count",
        }
        for field in fields(receipt):
            if field.name == "receipt_sha256":
                changed = replace(
                    receipt,
                    receipt_sha256=_flip(receipt.receipt_sha256),
                )
            elif field.name in scalar_fields:
                changed = replace(
                    receipt,
                    **{field.name: getattr(receipt, field.name) + 1},
                )
            else:
                changed = replace(
                    receipt,
                    **{
                        field.name: _flip(
                            getattr(receipt, field.name)
                        )
                    },
                )
            with self.subTest(field=field.name):
                with self.assertRaises(
                    contract.InvalidLossDispatchReconciliationReceipt
                ):
                    self.fixture.validate_receipt(changed)

    def test_coherently_resealed_binding_substitutions_fail(self) -> None:
        retention = self.fixture.retention
        retention_mutations = {
            "dispatch_generation": retention.dispatch_generation + 1,
            "allocation_count": retention.allocation_count + 1,
            "pinned_device_bytes": retention.pinned_device_bytes + 1,
            "native_command_status": retention.native_command_status + 1,
            "native_completion_observed": 0,
            "native_error_domain_kind": (
                retention.native_error_domain_kind + 1
            ),
            "native_error_code_bits": (
                retention.native_error_code_bits + 1
            ),
            "selected_capability_sha256": _flip(
                retention.selected_capability_sha256
            ),
            "allocation_lease_sha256": _flip(
                retention.allocation_lease_sha256
            ),
            "allocation_leaf_set_sha256": _flip(
                retention.allocation_leaf_set_sha256
            ),
            "backend_object_set_sha256": _flip(
                retention.backend_object_set_sha256
            ),
            "dispatch_pin_sha256": _flip(
                retention.dispatch_pin_sha256
            ),
            "dispatch_request_sha256": _flip(
                retention.dispatch_request_sha256
            ),
        }
        for field_name, value in retention_mutations.items():
            with self.subTest(record="retention", field=field_name):
                with self.assertRaises(
                    contract.InvalidLossDispatchRetention
                ):
                    self.fixture.validate_retention(
                        _reseal_retention(
                            retention,
                            **{field_name: value},
                        )
                    )

        plan = self.fixture.plan
        plan_mutations = {
            "source_sequence": plan.source_sequence + 1,
            "source_instance_sha256": _flip(
                plan.source_instance_sha256
            ),
            "observation_sha256": _flip(plan.observation_sha256),
            "transition_receipt_sha256": _flip(
                plan.transition_receipt_sha256
            ),
            "selected_capability_sha256": _flip(
                plan.selected_capability_sha256
            ),
            "retention_sha256": _flip(plan.retention_sha256),
        }
        for field_name, value in plan_mutations.items():
            with self.subTest(record="plan", field=field_name):
                with self.assertRaises(
                    contract.InvalidLossDispatchReconciliationPlan
                ):
                    self.fixture.validate_plan(
                        _reseal_plan(plan, **{field_name: value})
                    )

        receipt = self.fixture.receipt
        receipt_mutations = {
            "source_sequence": receipt.source_sequence + 1,
            "released_dispatch_pin_count": 2,
            "finalized_native_command_count": 2,
            "plan_sha256": _flip(receipt.plan_sha256),
            "retention_sha256": _flip(receipt.retention_sha256),
            "backend_terminal_sha256": _flip(
                receipt.backend_terminal_sha256
            ),
            "dispatch_terminal_sha256": _flip(
                receipt.dispatch_terminal_sha256
            ),
            "dispatch_completion_sha256": _flip(
                receipt.dispatch_completion_sha256
            ),
            "bank_completion_sha256": _flip(
                receipt.bank_completion_sha256
            ),
        }
        for field_name, value in receipt_mutations.items():
            with self.subTest(record="receipt", field=field_name):
                with self.assertRaises(
                    contract.InvalidLossDispatchReconciliationReceipt
                ):
                    self.fixture.validate_receipt(
                        _reseal_receipt(
                            receipt,
                            **{field_name: value},
                        )
                    )

    def test_exact_replays_fence_valid_free_input_substitutions(self) -> None:
        fixture = self.fixture
        contract.validate_loss_dispatch_retention_replay_v1(
            fixture.retention,
            fixture.retention,
        )
        alternate_retention = (
            contract.make_loss_dispatch_retention_v1(
                fixture.retention.source,
                fixture.retention.evidence_class,
                fixture.selected_entry,
                fixture.lease,
                fixture.pin,
                fixture.terminal.submission_sha256,
                fixture.quarantine.quarantine_sha256,
                _flip(fixture.adapter_challenge),
            )
        )
        with self.assertRaises(contract.InvalidLossDispatchRetention):
            contract.validate_loss_dispatch_retention_replay_v1(
                alternate_retention,
                fixture.retention,
            )

        contract.validate_loss_dispatch_reconciliation_plan_replay_v1(
            fixture.plan,
            fixture.plan,
        )
        alternate_plan = (
            contract.make_loss_dispatch_reconciliation_plan_v1(
                fixture.observation,
                fixture.transition,
                fixture.cursor,
                fixture.requirement,
                fixture.selection,
                fixture.inventory,
                fixture.selected_entry,
                fixture.successor_entry,
                fixture.retention,
                fixture.lease,
                fixture.pin,
                fixture.plan.reconciliation_generation + 1,
            )
        )
        with self.assertRaises(
            contract.InvalidLossDispatchReconciliationPlan
        ):
            contract.validate_loss_dispatch_reconciliation_plan_replay_v1(
                alternate_plan,
                fixture.plan,
            )

        contract.validate_loss_dispatch_reconciliation_receipt_replay_v1(
            fixture.receipt,
            fixture.receipt,
        )
        alternate_receipt = (
            contract.make_loss_dispatch_reconciliation_receipt_v1(
                fixture.plan,
                fixture.retention,
                fixture.selected_entry,
                fixture.lease,
                fixture.pin,
                fixture.terminal,
                fixture.completion,
                _flip(fixture.adapter_settlement),
            )
        )
        with self.assertRaises(
            contract.InvalidLossDispatchReconciliationReceipt
        ):
            contract.validate_loss_dispatch_reconciliation_receipt_replay_v1(
                alternate_receipt,
                fixture.receipt,
            )

    def test_device_placement_selection_lease_and_pin_substitution(self) -> None:
        fixture = self.fixture
        for label in (
            "foreign loss dispatch device",
            "foreign loss dispatch placement",
        ):
            changed_capability = replace(
                fixture.capability,
                device_sha256=(
                    device.digest_v1(label)
                    if "device" in label
                    else fixture.capability.device_sha256
                ),
                placement_sha256=(
                    device.digest_v1(label)
                    if "placement" in label
                    else fixture.capability.placement_sha256
                ),
                capability_sha256=contract.ZERO_DIGEST,
            )
            changed_capability = device.seal_capability(
                changed_capability
            )
            changed_entry = device.make_fixture_entry(
                changed_capability,
                fixture.selected_entry.discovery_epoch,
                fixture.selected_entry.policy_rank,
            )
            with self.subTest(label=label):
                with self.assertRaises(
                    contract.InvalidLossDispatchRetention
                ):
                    fixture.validate_retention(
                        fixture.retention,
                        selected_entry=changed_entry,
                    )

        changed_lease = replace(
            fixture.lease,
            generation=fixture.lease.generation + 1,
            lease_sha256=contract.ZERO_DIGEST,
        )
        changed_lease = replace(
            changed_lease,
            lease_sha256=allocation_tree.lease_root_v1(
                changed_lease
            ),
        )
        allocation_tree.validate_lease_v1(changed_lease)
        with self.assertRaises(contract.InvalidLossDispatchRetention):
            fixture.validate_retention(
                fixture.retention,
                lease=changed_lease,
            )

        changed_pin = replace(
            fixture.pin,
            dispatch_generation=fixture.pin.dispatch_generation + 1,
            pin_sha256=contract.ZERO_DIGEST,
        )
        changed_pin = replace(
            changed_pin,
            pin_sha256=allocation_tree.dispatch_pin_root_v1(
                changed_pin
            ),
        )
        allocation_tree.validate_dispatch_pin_v1(changed_pin)
        with self.assertRaises(contract.InvalidLossDispatchRetention):
            fixture.validate_retention(
                fixture.retention,
                pin=changed_pin,
            )

        foreign_requirement = device.seal_requirement(
            replace(
                fixture.requirement,
                plan_sha256=device.digest_v1(
                    "foreign loss dispatch requirement"
                ),
                requirement_sha256=contract.ZERO_DIGEST,
            )
        )
        foreign_selection = device.select_device(
            foreign_requirement,
            fixture.inventory,
        ).receipt
        with self.assertRaises(
            contract.InvalidLossDispatchReconciliationPlan
        ):
            fixture.validate_plan(
                fixture.plan,
                requirement=foreign_requirement,
                selection=foreign_selection,
            )

    def test_backend_quarantine_substitution_is_replay_fenced(self) -> None:
        fixture = self.fixture
        changed_quarantine = (
            allocation_tree.make_metal_async_dispatch_quarantine_v1(
                fixture.ticket,
                _flip(fixture.device_sha256),
                fixture.placement_sha256,
                allocation_tree.METAL_ASYNC_TERMINAL_COMMAND_ERROR,
                allocation_tree.METAL_ASYNC_TERMINAL_STATUS_OBSERVED,
                allocation_tree.METAL_ASYNC_COMMAND_STATUS_ERROR,
                1,
                allocation_tree.METAL_ASYNC_ERROR_COMMAND_BUFFER,
                lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
            )
        )
        replacement = contract.make_loss_dispatch_retention_v1(
            fixture.retention.source,
            fixture.retention.evidence_class,
            fixture.selected_entry,
            fixture.lease,
            fixture.pin,
            fixture.terminal.submission_sha256,
            changed_quarantine.quarantine_sha256,
            fixture.adapter_challenge,
        )
        fixture.validate_retention(replacement)
        with self.assertRaises(contract.InvalidLossDispatchRetention):
            contract.validate_loss_dispatch_retention_replay_v1(
                replacement,
                fixture.retention,
            )

    def test_no_output_migration_reset_or_physical_reclaim_authority(
        self,
    ) -> None:
        retention = self.fixture.retention
        with self.assertRaises(contract.InvalidLossDispatchRetention):
            self.fixture.validate_retention(
                _reseal_retention(
                    retention,
                    output_authority_sha256=device.digest_v1(
                        "forged retained output authority"
                    ),
                )
            )

        receipt = self.fixture.receipt
        for field_name in (
            "output_authority_sha256",
            "migration_authority_sha256",
            "reset_authority_sha256",
            "physical_reclaim_authority_sha256",
        ):
            with self.subTest(field=field_name):
                with self.assertRaises(
                    contract.InvalidLossDispatchReconciliationReceipt
                ):
                    self.fixture.validate_receipt(
                        _reseal_receipt(
                            receipt,
                            **{
                                field_name: device.digest_v1(
                                    f"forged {field_name}"
                                )
                            },
                        )
                    )

    def test_malformed_abi_enums_zero_and_digest_width_reject(self) -> None:
        fixture = self.fixture
        for changed in (
            _reseal_retention(
                fixture.retention,
                abi_version=contract.RETENTION_ABI + 1,
            ),
            _reseal_retention(fixture.retention, kind=999),
            _reseal_retention(fixture.retention, source=999),
            _reseal_retention(
                fixture.retention,
                submission_sha256=contract.ZERO_DIGEST,
            ),
            replace(
                fixture.retention,
                adapter_challenge_sha256=b"short",
            ),
        ):
            with self.assertRaises(
                contract.InvalidLossDispatchRetention
            ):
                fixture.validate_retention(changed)

        with self.assertRaises(
            contract.InvalidLossDispatchReconciliationPlan
        ):
            fixture.validate_plan(
                _reseal_plan(
                    fixture.plan,
                    successor_state=device.INVENTORY_UNAVAILABLE,
                )
            )
        with self.assertRaises(
            contract.InvalidLossDispatchReconciliationReceipt
        ):
            fixture.validate_receipt(
                _reseal_receipt(
                    fixture.receipt,
                    released_dispatch_pin_count=0,
                )
            )

    def test_existing_four_buffer_async_fixture_cannot_cross_bind(self) -> None:
        async_campaign = (
            allocation_tree.make_metal_async_dispatch_terminal_failure_campaign()
        )
        lease = allocation_tree.make_campaign().lease_2
        self.assertEqual(4, async_campaign.evidence.pin.allocation_count)
        self.assertEqual(3, lease.allocation_count)
        with self.assertRaises(contract.InvalidLossDispatchRetention):
            contract.make_loss_dispatch_retention_v1(
                lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
                lifecycle.EVIDENCE_NATIVE,
                self.fixture.selected_entry,
                lease,
                async_campaign.evidence.pin,
                async_campaign.evidence.submission_sha256,
                async_campaign.quarantine.quarantine_sha256,
                self.fixture.adapter_challenge,
            )


if __name__ == "__main__":
    unittest.main()
