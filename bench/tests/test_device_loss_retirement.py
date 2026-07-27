from __future__ import annotations

from dataclasses import fields, replace
import unittest

from bench import device_allocation_lease as allocation
from bench import device_allocation_lease_tree as allocation_tree
from bench import device_capability_contract as device
from bench import device_lifecycle_contract as lifecycle
from bench import device_loss_retirement as contract


def _flip(root: bytes) -> bytes:
    return bytes((root[0] ^ 1,)) + root[1:]


def _capability(
    *,
    device_label: str = "loss retirement golden gpu",
    placement_label: str = "loss retirement test placement",
) -> device.DeviceCapabilityV1:
    profiles = device.PROFILE_MATVEC_INT4_F32_BOUNDED
    return device.seal_capability(
        device.DeviceCapabilityV1(
            backend_kind=device.BACKEND_METAL,
            device_class=device.DEVICE_ACCELERATOR,
            operation_profile_bits=profiles,
            operator_bits=device.profile_operator_bits(profiles),
            element_type_bits=device.profile_element_type_bits(profiles),
            numerical_policy_bits=(
                device.profile_numerical_policy_bits(profiles)
            ),
            feature_bits=(
                device.FEATURE_ALLOCATION
                | device.FEATURE_DISPATCH
                | device.FEATURE_COMPLETION_FENCE
                | device.FEATURE_DEVICE_LOSS_SIGNAL
            ),
            max_single_allocation_bytes=4096,
            max_total_device_bytes=4096,
            max_queue_slots=1,
            backend_sha256=device.digest_v1(
                "loss retirement test backend"
            ),
            device_sha256=device.digest_v1(device_label),
            driver_sha256=device.digest_v1(
                "loss retirement test driver"
            ),
            placement_sha256=device.digest_v1(placement_label),
        )
    )


def _requirement() -> device.DeviceRequirementV1:
    profiles = device.PROFILE_MATVEC_INT4_F32_BOUNDED
    return device.seal_requirement(
        device.DeviceRequirementV1(
            plan_sha256=device.digest_v1(
                "loss retirement execution plan"
            ),
            required_device_class=device.DEVICE_ACCELERATOR,
            required_operation_profile_bits=profiles,
            required_operator_bits=device.profile_operator_bits(profiles),
            required_element_type_bits=(
                device.profile_element_type_bits(profiles)
            ),
            required_numerical_policy_bits=(
                device.profile_numerical_policy_bits(profiles)
            ),
            required_feature_bits=(
                device.FEATURE_ALLOCATION
                | device.FEATURE_DEVICE_LOSS_SIGNAL
            ),
            largest_single_allocation_bytes=4096,
            total_device_bytes=4096,
            queue_slots=1,
            fallback_policy=device.FALLBACK_FORBIDDEN,
        )
    )


def _selection_binding(
    receipt: device.DeviceSelectionReceiptV1,
    requirement: device.DeviceRequirementV1,
    selected: device.DeviceInventoryEntryV1,
) -> allocation.SelectionBindingV1:
    capability = selected.capability
    return allocation.SelectionBindingV1(
        receipt_sha256=receipt.receipt_sha256,
        requirement_sha256=requirement.requirement_sha256,
        selected_capability_sha256=capability.capability_sha256,
        selected_entry_sha256=selected.entry_sha256,
        selected_discovery_epoch=selected.discovery_epoch,
        selected_device_class=capability.device_class,
        fallback_used=receipt.fallback_used,
        required_feature_bits=requirement.required_feature_bits,
        largest_single_allocation_bytes=(
            requirement.largest_single_allocation_bytes
        ),
        total_device_bytes=requirement.total_device_bytes,
        queue_slots=requirement.queue_slots,
        selected_max_single_allocation_bytes=(
            capability.max_single_allocation_bytes
        ),
        selected_max_total_device_bytes=(
            capability.max_total_device_bytes
        ),
        selected_max_queue_slots=capability.max_queue_slots,
    )


class _Fixture:
    def __init__(
        self,
        source: int = lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
    ) -> None:
        # Keep one unrelated valid non-release terminal for negative tests.
        self.campaign = allocation_tree.make_campaign()
        self.capability = _capability()
        self.selected_entry = device.seal_inventory_entry(
            device.DeviceInventoryEntryV1(
                discovery_epoch=19,
                policy_rank=3,
                state=device.INVENTORY_PRESENT,
                capability=self.capability,
            )
        )
        self.inventory = (self.selected_entry,)
        self.requirement = _requirement()
        self.selection = device.select_device(
            self.requirement,
            self.inventory,
        ).receipt
        self.authority = allocation.seal_authority(
            allocation.AllocationAuthorityV1(
                authority_epoch=23,
                maximum_leases=1,
                maximum_live_objects=1,
                allocation_granularity_bytes=1024,
                max_single_allocation_bytes=4096,
                max_total_device_bytes=4096,
                max_queue_slots=1,
                selected_discovery_epoch=(
                    self.selected_entry.discovery_epoch
                ),
                selected_capability_sha256=(
                    self.capability.capability_sha256
                ),
                selected_entry_sha256=(
                    self.selected_entry.entry_sha256
                ),
                backend_authority_sha256=device.digest_v1(
                    "loss retirement adapter authority"
                ),
            )
        )
        binding = device.digest_v1(
            "loss retirement buffer binding"
        )
        quote = allocation.make_fake_quote(
            self.authority,
            binding,
            4000,
        )
        self.allocation_entries = (
            allocation.AllocationEntryV1(
                binding_sha256=binding,
                requested_bytes=4000,
                charged_bytes=quote.charged_bytes,
                quote_sha256=quote.quote_sha256,
            ),
        )
        self.manifest = allocation.seal_manifest(
            self.allocation_entries
        )
        self.parent = allocation.seal_resource_receipt(
            bank_epoch=41,
            slot_index=0,
            generation=1,
            owner_key=9001,
            claim=allocation.ClaimV1(
                capsule_bytes=64,
                queue_slots=1,
            ),
        )
        self.request = allocation.make_request(
            0x4C4F_5353,
            device.digest_v1("loss retirement request owner"),
            self.authority,
            _selection_binding(
                self.selection,
                self.requirement,
                self.selected_entry,
            ),
            self.parent,
            self.manifest,
            self.allocation_entries,
        )

        coordinator_epoch = 0x4C4F_5353_434F_4F52
        tree_key = 0x6C6F_7373_7472_6565
        authority_key = 0x6C6F_7373_6175_7468
        scope_key = 0x6C6F_7373_7363_6F70
        tenant_key = 0x6C6F_7373_7465_6E61
        claim = allocation.ClaimV1(device_bytes=4096)
        self.scope = allocation_tree.seal_lease_node(
            allocation_tree.LeaseNodeV1(
                parent=self.parent,
                tree_key=tree_key,
                tree_identity_generation=1,
                node_index=0,
                generation=3,
                parent_index=allocation_tree.NO_LEASE_NODE,
                parent_generation=1,
                node_key=scope_key,
                tenant_key=tenant_key,
                binding_key=0,
                kind=allocation_tree.NODE_SCOPE,
                ceiling=claim,
                claim=allocation.ClaimV1(),
            )
        )
        self.leaf = allocation_tree.seal_lease_node(
            allocation_tree.LeaseNodeV1(
                parent=self.parent,
                tree_key=tree_key,
                tree_identity_generation=1,
                node_index=1,
                generation=6,
                parent_index=self.scope.node_index,
                parent_generation=self.scope.generation,
                node_key=allocation_tree.allocation_node_key_v1(
                    coordinator_epoch,
                    1,
                    0,
                    binding,
                ),
                tenant_key=tenant_key,
                binding_key=(
                    allocation_tree.allocation_binding_key_v1(
                        coordinator_epoch,
                        1,
                        0,
                        binding,
                    )
                ),
                kind=allocation_tree.NODE_ALLOCATION,
                ceiling=claim,
                claim=claim,
            )
        )
        reserved_nodes = (
            allocation_tree._RuntimeNode(
                self.scope,
                allocation_tree.NODE_STATE_LIVE,
                0,
                claim,
            ),
            allocation_tree._RuntimeNode(
                self.leaf,
                allocation_tree.NODE_STATE_RESERVED_UNMATERIALIZED,
                5,
                claim,
            ),
        )
        pending_digest = allocation_tree._pending_node_digest(
            1,
            5,
            allocation_tree.NODE_STATE_RESERVED_UNMATERIALIZED,
            reserved_nodes,
        )
        reservation_tree = allocation_tree._make_tree_state(
            self.parent,
            tree_key,
            authority_key,
            1,
            7,
            3,
            claim,
            claim,
            allocation_tree.PENDING_ALLOCATION,
            5,
            8,
            0,
            0,
            allocation_tree.NO_LEASE_NODE,
            1,
            claim,
            pending_digest,
            reserved_nodes,
        )
        batch = allocation_tree.seal_lease_allocation_batch(
            allocation_tree.LeaseAllocationBatchV1(
                parent=self.parent,
                tree_key=tree_key,
                tree_identity_generation=1,
                tree_generation=7,
                structural_revision=3,
                request_epoch=0x4C4F_5353,
                session_id=0x5254_4952,
                sequence=0,
                generation=5,
                completion_tree_generation=8,
                node_count=1,
                claim=claim,
                node_set_digest=pending_digest,
            )
        )
        self.admission = allocation_tree.make_admission_v1(
            coordinator_epoch,
            1,
            self.authority,
            self.request,
            reservation_tree,
            self.scope,
            batch,
            (self.leaf,),
        )
        live_nodes = (
            allocation_tree._RuntimeNode(
                self.scope,
                allocation_tree.NODE_STATE_LIVE,
                0,
                claim,
            ),
            allocation_tree._RuntimeNode(
                self.leaf,
                allocation_tree.NODE_STATE_LIVE,
                0,
                claim,
            ),
        )
        materialized_tree = allocation_tree._make_tree_state(
            self.parent,
            tree_key,
            authority_key,
            1,
            8,
            4,
            claim,
            claim,
            allocation_tree.PENDING_NONE,
            0,
            0,
            0,
            0,
            allocation_tree.NO_LEASE_NODE,
            0,
            allocation.ClaimV1(),
            0,
            live_nodes,
        )
        call = allocation.make_allocation_call_for_admission_root(
            self.authority,
            self.admission.admission_sha256,
            0,
            self.allocation_entries[0],
        )
        backend_object = allocation.make_backend_object(
            call,
            allocation.fake_object_identity(
                self.authority,
                0,
                1,
                call.call_sha256,
            ),
            1,
        )
        object_set = allocation.make_object_set_for_admission_root(
            self.admission.admission_sha256,
            self.admission.authority_sha256,
            1,
            4096,
            (call,),
            (backend_object,),
        )
        self.lease = allocation_tree.make_lease_v1(
            self.admission,
            self.request,
            object_set,
            materialized_tree,
        )
        terminal_tree = allocation_tree._make_tree_state(
            self.parent,
            tree_key,
            authority_key,
            1,
            13,
            7,
            claim,
            allocation.ClaimV1(),
            allocation_tree.PENDING_NONE,
            0,
            0,
            0,
            0,
            allocation_tree.NO_LEASE_NODE,
            0,
            allocation.ClaimV1(),
            0,
            (
                allocation_tree._RuntimeNode(
                    self.scope,
                    allocation_tree.NODE_STATE_LIVE,
                    0,
                    allocation.ClaimV1(),
                ),
            ),
        )
        self.terminal = allocation_tree.make_terminal_v1(
            allocation_tree.OUTCOME_RELEASED,
            allocation_tree.REASON_NORMAL_RELEASE,
            self.admission,
            self.request,
            terminal_tree,
            self.lease,
        )

        self.source_instance = device.digest_v1(
            "loss retirement source instance"
        )
        self.source_sequence = 31
        self.cursor = lifecycle.SourceCursorV1(
            source_instance_sha256=self.source_instance,
            last_sequence=self.source_sequence - 1,
        )
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
            device.digest_v1("loss retirement lifecycle evidence"),
            *native_fields,
        )
        self.successor_entry = lifecycle.make_successor_entry(
            self.observation,
            self.selected_entry,
            self.inventory,
            self.cursor,
            self.selected_entry.discovery_epoch + 1,
        )
        self.transition = lifecycle.make_transition_receipt(
            self.observation,
            self.selected_entry,
            self.inventory,
            self.successor_entry,
            self.cursor,
        )
        self.adapter_challenge = device.digest_v1(
            "loss retirement adapter challenge"
        )
        self.plan = contract.make_loss_retirement_plan_v1(
            self.observation,
            self.transition,
            self.cursor,
            self.requirement,
            self.selection,
            self.inventory,
            self.selected_entry,
            self.successor_entry,
            self.authority,
            self.lease,
            7,
            self.adapter_challenge,
        )
        self.adapter_settlement = device.digest_v1(
            "loss retirement golden settlement"
        )
        self.receipt = contract.make_loss_retirement_receipt_v1(
            self.plan,
            self.terminal,
            self.adapter_settlement,
            self.lease.allocation_count,
        )

    def validate_plan(
        self,
        plan: contract.LossRetirementPlanV1,
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
            "authority": self.authority,
            "lease": self.lease,
        }
        arguments.update(overrides)
        contract.validate_loss_retirement_plan_v1(plan, **arguments)


class DeviceLossRetirementOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = _Fixture()

    def test_literal_abi_layout_domains_and_golden_roots(self) -> None:
        self.assertEqual(0x4744_4C50_0000_0001, contract.PLAN_ABI)
        self.assertEqual(0x4744_4C52_0000_0001, contract.RECEIPT_ABI)
        self.assertEqual(544, contract.PLAN_SIZE_BYTES)
        self.assertEqual(440, contract.RECEIPT_SIZE_BYTES)
        self.assertEqual(
            b"glacier-device-loss-retirement-plan-v1\x00",
            contract.PLAN_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-loss-retirement-receipt-v1\x00",
            contract.RECEIPT_DOMAIN,
        )
        actual = {
            "capability": self.fixture.capability.capability_sha256.hex(),
            "entry": self.fixture.selected_entry.entry_sha256.hex(),
            "requirement": (
                self.fixture.requirement.requirement_sha256.hex()
            ),
            "selection": self.fixture.selection.receipt_sha256.hex(),
            "observation": (
                self.fixture.observation.observation_sha256.hex()
            ),
            "transition": (
                self.fixture.transition.receipt_sha256.hex()
            ),
            "authority": self.fixture.authority.authority_sha256.hex(),
            "request": self.fixture.request.request_sha256.hex(),
            "lease": self.fixture.lease.lease_sha256.hex(),
            "terminal": self.fixture.terminal.terminal_sha256.hex(),
            "plan": self.fixture.plan.plan_sha256.hex(),
            "receipt": self.fixture.receipt.receipt_sha256.hex(),
        }
        expected = {
            "capability": (
                "79243a8f0bf56616f664e53d2ba78d29"
                "d8bdfc74d47a7ae6df8654072921d754"
            ),
            "entry": (
                "7b590b53849b919327386885df818a81"
                "ef74fdba1b4c929c4272c843f118c287"
            ),
            "requirement": (
                "af4899ad7bc038d6a1d677f40653594c1"
                "6137838bec0985b98ed2f4c9a3453d2"
            ),
            "selection": (
                "c977503ae4a31cab5ec6ab4440e8222c"
                "f82ff635ba0692ed6de384eb8e342b7c"
            ),
            "observation": (
                "f9086379360ad2f7100505127e5af5e4"
                "8247b14f198df45d941ec4d5093fa9ef"
            ),
            "transition": (
                "28c957c1ada15fe30ae0294efce67c48"
                "74eb4509de0e987038a97d129c2df0e2"
            ),
            "authority": (
                "146f3ddcc3787a58bc918255dee71d52"
                "bda63dda3d35f2a105eddf6ea2562dab"
            ),
            "request": (
                "5f96741e79b3ac00d0a7e887dd21182b"
                "f18355cb5f82796636c2e31aa7684980"
            ),
            "lease": (
                "b91cf2fbe36ef3291e2ff370d45d246b"
                "e2a9a8f76ac168a550230fca6792b42b"
            ),
            "terminal": (
                "bf635530cd4f1ba260699b79f7b36c94"
                "5b4252618a04b646bb4767da17b0593e"
            ),
            "plan": (
                "b335fc92c606b155ffb000aa8a91d9a5"
                "999aa1d9b82bef69b9f97604a8f83417"
            ),
            "receipt": (
                "ac46b55947af12b55884920e6ab98102"
                "090c8b19ce2091277ad46e54c86d31d0"
            ),
        }
        self.assertEqual(expected, actual)

    def test_plan_binds_every_serialized_field(self) -> None:
        plan = self.fixture.plan
        scalar_fields = {
            "abi_version",
            "source",
            "evidence_class",
            "successor_state",
            "source_sequence",
            "recovery_generation",
            "allocation_count",
            "materialized_bytes",
        }
        for field in fields(plan):
            if field.name == "plan_sha256":
                changed = replace(plan, plan_sha256=_flip(plan.plan_sha256))
            elif field.name in scalar_fields:
                changed = replace(
                    plan,
                    **{field.name: getattr(plan, field.name) + 1},
                )
            else:
                changed = replace(
                    plan,
                    **{field.name: _flip(getattr(plan, field.name))},
                )
            with self.subTest(field=field.name):
                with self.assertRaises(
                    contract.InvalidLossRetirementPlan
                ):
                    self.fixture.validate_plan(changed)

    def test_self_consistent_binding_substitutions_fail_closed(self) -> None:
        plan = self.fixture.plan
        bound_mutations = {
            "source_sequence": plan.source_sequence + 1,
            "allocation_count": plan.allocation_count + 1,
            "materialized_bytes": plan.materialized_bytes + 1,
            "source_instance_sha256": _flip(
                plan.source_instance_sha256
            ),
            "observation_sha256": _flip(plan.observation_sha256),
            "transition_receipt_sha256": _flip(
                plan.transition_receipt_sha256
            ),
            "requirement_sha256": _flip(plan.requirement_sha256),
            "prior_inventory_sha256": _flip(
                plan.prior_inventory_sha256
            ),
            "selected_entry_sha256": _flip(
                plan.selected_entry_sha256
            ),
            "selected_capability_sha256": _flip(
                plan.selected_capability_sha256
            ),
            "selection_receipt_sha256": _flip(
                plan.selection_receipt_sha256
            ),
            "allocation_authority_sha256": _flip(
                plan.allocation_authority_sha256
            ),
            "allocation_request_sha256": _flip(
                plan.allocation_request_sha256
            ),
            "allocation_lease_sha256": _flip(
                plan.allocation_lease_sha256
            ),
            "allocation_leaf_set_sha256": _flip(
                plan.allocation_leaf_set_sha256
            ),
            "backend_object_set_sha256": _flip(
                plan.backend_object_set_sha256
            ),
        }
        for field_name, changed_value in bound_mutations.items():
            draft = replace(
                plan,
                **{
                    field_name: changed_value,
                    "plan_sha256": contract.ZERO_DIGEST,
                },
            )
            changed = replace(
                draft,
                plan_sha256=contract.loss_retirement_plan_root_v1(
                    draft
                ),
            )
            with self.subTest(field=field_name):
                with self.assertRaises(
                    contract.InvalidLossRetirementPlan
                ):
                    self.fixture.validate_plan(changed)

    def test_free_plan_inputs_are_replay_fenced(self) -> None:
        fixture = self.fixture
        replacements = (
            contract.make_loss_retirement_plan_v1(
                fixture.observation,
                fixture.transition,
                fixture.cursor,
                fixture.requirement,
                fixture.selection,
                fixture.inventory,
                fixture.selected_entry,
                fixture.successor_entry,
                fixture.authority,
                fixture.lease,
                fixture.plan.recovery_generation + 1,
                fixture.adapter_challenge,
            ),
            contract.make_loss_retirement_plan_v1(
                fixture.observation,
                fixture.transition,
                fixture.cursor,
                fixture.requirement,
                fixture.selection,
                fixture.inventory,
                fixture.selected_entry,
                fixture.successor_entry,
                fixture.authority,
                fixture.lease,
                fixture.plan.recovery_generation,
                _flip(fixture.adapter_challenge),
            ),
        )
        for replacement_plan in replacements:
            fixture.validate_plan(replacement_plan)
            with self.assertRaises(
                contract.InvalidLossRetirementPlan
            ):
                contract.validate_loss_retirement_plan_replay_v1(
                    replacement_plan,
                    fixture.plan,
                )
        contract.validate_loss_retirement_plan_replay_v1(
            fixture.plan,
            fixture.plan,
        )

    def test_source_selection_device_placement_and_lease_substitution(
        self,
    ) -> None:
        fixture = self.fixture
        replacement_source = device.digest_v1(
            "replacement lifecycle source"
        )
        observation = lifecycle.make_observation(
            fixture.selected_entry,
            fixture.inventory,
            replacement_source,
            fixture.source_sequence,
            lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
            device.digest_v1("replacement lifecycle evidence"),
            lifecycle.COMMAND_BUFFER_STATUS_ERROR,
            lifecycle.COMMAND_BUFFER_ERROR_DOMAIN,
            lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
        )
        cursor = lifecycle.SourceCursorV1(
            replacement_source,
            fixture.source_sequence - 1,
        )
        successor = lifecycle.make_successor_entry(
            observation,
            fixture.selected_entry,
            fixture.inventory,
            cursor,
            21,
        )
        transition = lifecycle.make_transition_receipt(
            observation,
            fixture.selected_entry,
            fixture.inventory,
            successor,
            cursor,
        )
        with self.assertRaises(contract.InvalidLossRetirementPlan):
            fixture.validate_plan(
                fixture.plan,
                observation=observation,
                transition=transition,
                source_cursor=cursor,
                successor_entry=successor,
            )

        for changed_capability in (
            _capability(device_label="foreign retirement gpu"),
            _capability(placement_label="foreign retirement placement"),
        ):
            foreign_entry = device.seal_inventory_entry(
                replace(
                    fixture.selected_entry,
                    capability=changed_capability,
                    entry_sha256=contract.ZERO_DIGEST,
                )
            )
            with self.subTest(
                device=changed_capability.device_sha256.hex(),
                placement=changed_capability.placement_sha256.hex(),
            ):
                with self.assertRaises(
                    contract.InvalidLossRetirementPlan
                ):
                    fixture.validate_plan(
                        fixture.plan,
                        selected_entry=foreign_entry,
                    )

        changed_lease = replace(
            fixture.lease,
            generation=fixture.lease.generation + 1,
            lease_sha256=contract.ZERO_DIGEST,
        )
        changed_lease = replace(
            changed_lease,
            lease_sha256=allocation_tree.lease_root_v1(changed_lease),
        )
        allocation_tree.validate_lease_v1(changed_lease)
        with self.assertRaises(contract.InvalidLossRetirementPlan):
            fixture.validate_plan(fixture.plan, lease=changed_lease)

        foreign_requirement = replace(
            fixture.requirement,
            plan_sha256=device.digest_v1("foreign requirement plan"),
            requirement_sha256=contract.ZERO_DIGEST,
        )
        foreign_requirement = device.seal_requirement(
            foreign_requirement
        )
        foreign_selection = device.select_device(
            foreign_requirement,
            fixture.inventory,
        ).receipt
        with self.assertRaises(contract.InvalidLossRetirementPlan):
            fixture.validate_plan(
                fixture.plan,
                requirement=foreign_requirement,
                selection=foreign_selection,
            )

    def test_native_sources_are_production_eligible(self) -> None:
        for source in (
            lifecycle.SOURCE_REMOVED_NOTIFICATION,
            lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
        ):
            with self.subTest(source=source):
                fixture = _Fixture(source)
                self.assertTrue(
                    contract.loss_retirement_plan_production_eligible_v1(
                        fixture.plan,
                        fixture.observation,
                        fixture.transition,
                    )
                )
                contract.require_production_eligible_loss_retirement_plan_v1(
                    fixture.plan,
                    fixture.observation,
                    fixture.transition,
                )

    def test_synthetic_plan_is_structural_but_not_production(self) -> None:
        fixture = _Fixture(lifecycle.SOURCE_TEST_INJECTED)
        fixture.validate_plan(fixture.plan)
        self.assertFalse(
            contract.loss_retirement_plan_production_eligible_v1(
                fixture.plan,
                fixture.observation,
                fixture.transition,
            )
        )
        with self.assertRaises(contract.ProductionEvidenceRequired):
            contract.require_production_eligible_loss_retirement_plan_v1(
                fixture.plan,
                fixture.observation,
                fixture.transition,
            )

    def test_unavailable_transition_is_rejected(self) -> None:
        fixture = self.fixture
        observation = lifecycle.make_observation(
            fixture.selected_entry,
            fixture.inventory,
            fixture.source_instance,
            fixture.source_sequence,
            lifecycle.SOURCE_INVENTORY_ABSENT,
            device.digest_v1("unavailable lifecycle evidence"),
        )
        successor = lifecycle.make_successor_entry(
            observation,
            fixture.selected_entry,
            fixture.inventory,
            fixture.cursor,
            21,
        )
        transition = lifecycle.make_transition_receipt(
            observation,
            fixture.selected_entry,
            fixture.inventory,
            successor,
            fixture.cursor,
        )
        with self.assertRaises(contract.InvalidLossRetirementPlan):
            contract.make_loss_retirement_plan_v1(
                observation,
                transition,
                fixture.cursor,
                fixture.requirement,
                fixture.selection,
                fixture.inventory,
                fixture.selected_entry,
                successor,
                fixture.authority,
                fixture.lease,
                7,
                fixture.adapter_challenge,
            )

    def test_bad_abi_enums_zero_and_malformed_digests_reject(self) -> None:
        fixture = self.fixture
        malformed_plans = []
        for field_name, value in (
            ("abi_version", contract.PLAN_ABI + 1),
            ("source", 999),
            ("evidence_class", 999),
            ("successor_state", 999),
        ):
            draft = replace(
                fixture.plan,
                **{
                    field_name: value,
                    "plan_sha256": contract.ZERO_DIGEST,
                },
            )
            malformed_plans.append(
                replace(
                    draft,
                    plan_sha256=contract.loss_retirement_plan_root_v1(
                        draft
                    ),
                )
            )
        for field in fields(fixture.plan):
            if not field.name.endswith("_sha256"):
                continue
            if field.name == "plan_sha256":
                malformed_plans.append(
                    replace(fixture.plan, plan_sha256=contract.ZERO_DIGEST)
                )
                continue
            draft = replace(
                fixture.plan,
                **{
                    field.name: contract.ZERO_DIGEST,
                    "plan_sha256": contract.ZERO_DIGEST,
                },
            )
            malformed_plans.append(
                replace(
                    draft,
                    plan_sha256=contract.loss_retirement_plan_root_v1(
                        draft
                    ),
                )
            )
        malformed_plans.append(
            replace(fixture.plan, source_instance_sha256=b"short")
        )
        for ordinal, malformed in enumerate(malformed_plans):
            with self.subTest(ordinal=ordinal):
                with self.assertRaises(
                    contract.InvalidLossRetirementPlan
                ):
                    fixture.validate_plan(malformed)

    def test_receipt_binds_every_field_and_replays_exactly(self) -> None:
        fixture = self.fixture
        receipt = fixture.receipt
        scalar_fields = {
            "abi_version",
            "source",
            "evidence_class",
            "recovery_generation",
            "reference_release_count",
            "returned_logical_device_bytes",
            "physical_reclaim_observed",
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
                    contract.InvalidLossRetirementReceipt
                ):
                    contract.validate_loss_retirement_receipt_v1(
                        changed,
                        fixture.plan,
                        fixture.terminal,
                    )

        contract.validate_loss_retirement_receipt_replay_v1(
            receipt,
            receipt,
        )
        replacement = contract.make_loss_retirement_receipt_v1(
            fixture.plan,
            fixture.terminal,
            _flip(fixture.adapter_settlement),
            fixture.lease.allocation_count,
        )
        contract.validate_loss_retirement_receipt_v1(
            replacement,
            fixture.plan,
            fixture.terminal,
        )
        with self.assertRaises(
            contract.InvalidLossRetirementReceipt
        ):
            contract.validate_loss_retirement_receipt_replay_v1(
                replacement,
                receipt,
            )

    def test_receipt_forces_logical_counts_and_no_extra_authority(
        self,
    ) -> None:
        fixture = self.fixture
        receipt = fixture.receipt
        mutations = {
            "reference_release_count": receipt.reference_release_count - 1,
            "returned_logical_device_bytes": (
                receipt.returned_logical_device_bytes - 1
            ),
            "physical_reclaim_observed": 1,
            "output_authority_sha256": device.digest_v1(
                "forged output authority"
            ),
            "migration_authority_sha256": device.digest_v1(
                "forged migration authority"
            ),
            "reset_authority_sha256": device.digest_v1(
                "forged reset authority"
            ),
            "physical_reclaim_authority_sha256": device.digest_v1(
                "forged physical reclaim authority"
            ),
        }
        for field_name, changed_value in mutations.items():
            draft = replace(
                receipt,
                **{
                    field_name: changed_value,
                    "receipt_sha256": contract.ZERO_DIGEST,
                },
            )
            changed = replace(
                draft,
                receipt_sha256=contract.loss_retirement_receipt_root_v1(
                    draft
                ),
            )
            with self.subTest(field=field_name):
                with self.assertRaises(
                    contract.InvalidLossRetirementReceipt
                ):
                    contract.validate_loss_retirement_receipt_v1(
                        changed,
                        fixture.plan,
                        fixture.terminal,
                    )

    def test_only_exact_ordinary_released_terminal_is_accepted(self) -> None:
        fixture = self.fixture
        with self.assertRaises(contract.InvalidLossRetirementReceipt):
            contract.make_loss_retirement_receipt_v1(
                fixture.plan,
                fixture.campaign.terminal_cancel_1,
                fixture.adapter_settlement,
                fixture.lease.allocation_count,
            )

        terminal_mutations = {
            "authority_sha256": _flip(
                fixture.terminal.authority_sha256
            ),
            "request_sha256": _flip(fixture.terminal.request_sha256),
            "lease_sha256": _flip(fixture.terminal.lease_sha256),
            "backend_object_set_sha256": _flip(
                fixture.terminal.backend_object_set_sha256
            ),
        }
        for field_name, changed_value in terminal_mutations.items():
            draft = replace(
                fixture.terminal,
                **{
                    field_name: changed_value,
                    "terminal_sha256": contract.ZERO_DIGEST,
                },
            )
            terminal = replace(
                draft,
                terminal_sha256=allocation_tree.terminal_root_v1(
                    draft
                ),
            )
            allocation_tree.validate_terminal_v1(terminal)
            with self.subTest(field=field_name):
                with self.assertRaises(
                    contract.InvalidLossRetirementReceipt
                ):
                    contract.validate_loss_retirement_receipt_v1(
                        fixture.receipt,
                        fixture.plan,
                        terminal,
                    )

    def test_bad_receipt_abi_enums_zero_and_malformed_digests_reject(
        self,
    ) -> None:
        fixture = self.fixture
        malformed_receipts = []
        for field_name, value in (
            ("abi_version", contract.RECEIPT_ABI + 1),
            ("source", 999),
            ("evidence_class", 999),
        ):
            draft = replace(
                fixture.receipt,
                **{
                    field_name: value,
                    "receipt_sha256": contract.ZERO_DIGEST,
                },
            )
            malformed_receipts.append(
                replace(
                    draft,
                    receipt_sha256=(
                        contract.loss_retirement_receipt_root_v1(draft)
                    ),
                )
            )
        for field in fields(fixture.receipt):
            if not field.name.endswith("_sha256"):
                continue
            if field.name in {
                "output_authority_sha256",
                "migration_authority_sha256",
                "reset_authority_sha256",
                "physical_reclaim_authority_sha256",
            }:
                self.assertEqual(
                    contract.ZERO_DIGEST,
                    getattr(fixture.receipt, field.name),
                )
                continue
            if field.name == "receipt_sha256":
                malformed_receipts.append(
                    replace(
                        fixture.receipt,
                        receipt_sha256=contract.ZERO_DIGEST,
                    )
                )
                continue
            draft = replace(
                fixture.receipt,
                **{
                    field.name: contract.ZERO_DIGEST,
                    "receipt_sha256": contract.ZERO_DIGEST,
                },
            )
            malformed_receipts.append(
                replace(
                    draft,
                    receipt_sha256=(
                        contract.loss_retirement_receipt_root_v1(draft)
                    ),
                )
            )
        malformed_receipts.append(
            replace(fixture.receipt, plan_sha256=b"short")
        )
        for ordinal, malformed in enumerate(malformed_receipts):
            with self.subTest(ordinal=ordinal):
                with self.assertRaises(
                    contract.InvalidLossRetirementReceipt
                ):
                    contract.validate_loss_retirement_receipt_v1(
                        malformed,
                        fixture.plan,
                        fixture.terminal,
                    )


if __name__ == "__main__":
    unittest.main()
