"""Independent oracle for the portable device-loss retirement contract.

The oracle uses only Python's standard library and the independent Python
oracles for the four contracts composed by Retirement V1.  It never parses
Zig source or loads Glacier symbols.

A retirement plan binds one exact ``lost`` lifecycle transition to one exact
selected device and one exact LeaseTree allocation.  A receipt records logical
ownership settlement only: it cannot publish output, authorize migration or
reset, or claim that physical device memory was reclaimed.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, replace
from typing import Sequence

from bench import device_allocation_lease as allocation
from bench import device_allocation_lease_tree as allocation_tree
from bench import device_capability_contract as device
from bench import device_lifecycle_contract as lifecycle


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1

PLAN_ABI = 0x4744_4C50_0000_0001
RECEIPT_ABI = 0x4744_4C52_0000_0001
PLAN_SIZE_BYTES = 544
RECEIPT_SIZE_BYTES = 440

PLAN_DOMAIN = b"glacier-device-loss-retirement-plan-v1\x00"
RECEIPT_DOMAIN = b"glacier-device-loss-retirement-receipt-v1\x00"


class ContractError(ValueError):
    """A device-loss retirement value is invalid."""


class InvalidLossRetirementPlan(ContractError):
    pass


class ProductionEvidenceRequired(ContractError):
    pass


class InvalidLossRetirementReceipt(ContractError):
    pass


@dataclass(frozen=True)
class LossRetirementPlanV1:
    abi_version: int = PLAN_ABI
    source: int = lifecycle.SOURCE_REMOVED_NOTIFICATION
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    successor_state: int = device.INVENTORY_LOST
    source_sequence: int = 0
    recovery_generation: int = 0
    allocation_count: int = 0
    materialized_bytes: int = 0
    source_instance_sha256: Digest = ZERO_DIGEST
    observation_sha256: Digest = ZERO_DIGEST
    transition_receipt_sha256: Digest = ZERO_DIGEST
    requirement_sha256: Digest = ZERO_DIGEST
    prior_inventory_sha256: Digest = ZERO_DIGEST
    selected_entry_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    selection_receipt_sha256: Digest = ZERO_DIGEST
    allocation_authority_sha256: Digest = ZERO_DIGEST
    allocation_request_sha256: Digest = ZERO_DIGEST
    allocation_lease_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    adapter_challenge_sha256: Digest = ZERO_DIGEST
    plan_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LossRetirementReceiptV1:
    abi_version: int = RECEIPT_ABI
    source: int = lifecycle.SOURCE_REMOVED_NOTIFICATION
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    recovery_generation: int = 0
    reference_release_count: int = 0
    returned_logical_device_bytes: int = 0
    physical_reclaim_observed: int = 0
    plan_sha256: Digest = ZERO_DIGEST
    transition_receipt_sha256: Digest = ZERO_DIGEST
    allocation_lease_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    allocation_terminal_sha256: Digest = ZERO_DIGEST
    adapter_settlement_sha256: Digest = ZERO_DIGEST
    output_authority_sha256: Digest = ZERO_DIGEST
    migration_authority_sha256: Digest = ZERO_DIGEST
    reset_authority_sha256: Digest = ZERO_DIGEST
    physical_reclaim_authority_sha256: Digest = ZERO_DIGEST
    receipt_sha256: Digest = ZERO_DIGEST


def loss_retirement_plan_root_v1(value: LossRetirementPlanV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(PLAN_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.successor_state,
        value.source_sequence,
        value.recovery_generation,
        value.allocation_count,
        value.materialized_bytes,
    )
    for root in (
        value.source_instance_sha256,
        value.observation_sha256,
        value.transition_receipt_sha256,
        value.requirement_sha256,
        value.prior_inventory_sha256,
        value.selected_entry_sha256,
        value.selected_capability_sha256,
        value.selection_receipt_sha256,
        value.allocation_authority_sha256,
        value.allocation_request_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.adapter_challenge_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_retirement_plan_v1(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    authority: allocation.AllocationAuthorityV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    recovery_generation: int,
    adapter_challenge_sha256: Digest,
) -> LossRetirementPlanV1:
    result = LossRetirementPlanV1(
        source=observation.source,
        evidence_class=observation.evidence_class,
        successor_state=transition.successor_state,
        source_sequence=observation.source_sequence,
        recovery_generation=recovery_generation,
        allocation_count=lease.allocation_count,
        materialized_bytes=lease.materialized_bytes,
        source_instance_sha256=observation.source_instance_sha256,
        observation_sha256=observation.observation_sha256,
        transition_receipt_sha256=transition.receipt_sha256,
        requirement_sha256=requirement.requirement_sha256,
        prior_inventory_sha256=transition.prior_inventory_sha256,
        selected_entry_sha256=selected_entry.entry_sha256,
        selected_capability_sha256=(
            selected_entry.capability.capability_sha256
        ),
        selection_receipt_sha256=selection.receipt_sha256,
        allocation_authority_sha256=authority.authority_sha256,
        allocation_request_sha256=lease.request_sha256,
        allocation_lease_sha256=lease.lease_sha256,
        allocation_leaf_set_sha256=lease.allocation_leaf_set_sha256,
        backend_object_set_sha256=lease.backend_object_set_sha256,
        adapter_challenge_sha256=adapter_challenge_sha256,
    )
    result = replace(
        result,
        plan_sha256=loss_retirement_plan_root_v1(result),
    )
    validate_loss_retirement_plan_v1(
        result,
        observation,
        transition,
        source_cursor,
        requirement,
        selection,
        prior_inventory,
        selected_entry,
        successor_entry,
        authority,
        lease,
    )
    return result


def validate_loss_retirement_plan_v1(
    value: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    authority: allocation.AllocationAuthorityV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
) -> None:
    try:
        lifecycle.validate_transition_receipt(
            transition,
            observation,
            selected_entry,
            prior_inventory,
            successor_entry,
            source_cursor,
        )
        device.validate_requirement(requirement)
        device.validate_selection_receipt(
            selection,
            requirement,
            prior_inventory,
        )
        device.validate_inventory_entry(selected_entry)
        device.validate_inventory_entry(successor_entry)
        allocation.validate_authority(authority)
        allocation_tree.validate_lease_v1(lease)
        _validate_plan_fields(value)
        valid_root = (
            value.plan_sha256 != ZERO_DIGEST
            and value.plan_sha256
            == loss_retirement_plan_root_v1(value)
        )
    except (
        allocation.ContractError,
        allocation_tree.ContractError,
        device.ContractError,
        lifecycle.ContractError,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidLossRetirementPlan("nested evidence") from error

    capability_root = selected_entry.capability.capability_sha256
    if (
        observation.observed_state != device.INVENTORY_LOST
        or transition.prior_state != device.INVENTORY_PRESENT
        or transition.successor_state != device.INVENTORY_LOST
        or successor_entry.state != device.INVENTORY_LOST
        or selected_entry.state != device.INVENTORY_PRESENT
        or selection.selected_entry_sha256
        != selected_entry.entry_sha256
        or selection.selected_capability_sha256 != capability_root
        or transition.prior_entry_sha256
        != selected_entry.entry_sha256
        or transition.capability_sha256 != capability_root
        or authority.selected_discovery_epoch
        != selected_entry.discovery_epoch
        or authority.selected_entry_sha256
        != selected_entry.entry_sha256
        or authority.selected_capability_sha256 != capability_root
        or lease.authority_sha256 != authority.authority_sha256
        or lease.selection_receipt_sha256 != selection.receipt_sha256
        or lease.selected_capability_sha256 != capability_root
        or value.abi_version != PLAN_ABI
        or value.source != observation.source
        or value.evidence_class != observation.evidence_class
        or value.successor_state != device.INVENTORY_LOST
        or value.successor_state != transition.successor_state
        or value.source_sequence != observation.source_sequence
        or value.source_sequence != transition.source_sequence
        or value.recovery_generation == 0
        or value.allocation_count == 0
        or value.allocation_count != lease.allocation_count
        or value.materialized_bytes == 0
        or value.materialized_bytes != lease.materialized_bytes
        or value.source_instance_sha256
        != observation.source_instance_sha256
        or value.observation_sha256 != observation.observation_sha256
        or value.transition_receipt_sha256 != transition.receipt_sha256
        or value.requirement_sha256 != requirement.requirement_sha256
        or value.prior_inventory_sha256
        != transition.prior_inventory_sha256
        or value.selected_entry_sha256 != selected_entry.entry_sha256
        or value.selected_capability_sha256 != capability_root
        or value.selection_receipt_sha256 != selection.receipt_sha256
        or value.allocation_authority_sha256
        != authority.authority_sha256
        or value.allocation_request_sha256 != lease.request_sha256
        or value.allocation_lease_sha256 != lease.lease_sha256
        or value.allocation_leaf_set_sha256
        != lease.allocation_leaf_set_sha256
        or value.backend_object_set_sha256
        != lease.backend_object_set_sha256
        or value.adapter_challenge_sha256 == ZERO_DIGEST
        or not valid_root
    ):
        raise InvalidLossRetirementPlan("shape or binding")


def loss_retirement_plan_production_eligible_v1(
    plan: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> bool:
    try:
        root_valid = (
            plan.plan_sha256 != ZERO_DIGEST
            and plan.plan_sha256 == loss_retirement_plan_root_v1(plan)
        )
    except (TypeError, ValueError):
        return False
    if (
        plan.abi_version != PLAN_ABI
        or plan.successor_state != device.INVENTORY_LOST
        or plan.evidence_class != lifecycle.EVIDENCE_NATIVE
        or observation.evidence_class != lifecycle.EVIDENCE_NATIVE
        or transition.evidence_class != lifecycle.EVIDENCE_NATIVE
        or observation.observed_state != device.INVENTORY_LOST
        or transition.successor_state != device.INVENTORY_LOST
        or plan.source != observation.source
        or plan.source != transition.source
        or plan.observation_sha256 != observation.observation_sha256
        or plan.transition_receipt_sha256 != transition.receipt_sha256
        or not root_valid
    ):
        return False
    if plan.source == lifecycle.SOURCE_REMOVED_NOTIFICATION:
        return (
            observation.native_command_status == 0
            and observation.native_error_domain_kind == 0
            and observation.native_error_code_bits == 0
        )
    if plan.source == lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED:
        return (
            observation.native_command_status
            == lifecycle.COMMAND_BUFFER_STATUS_ERROR
            and observation.native_error_domain_kind
            == lifecycle.COMMAND_BUFFER_ERROR_DOMAIN
            and observation.native_error_code_bits
            == lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        )
    return False


def require_production_eligible_loss_retirement_plan_v1(
    plan: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> None:
    if not loss_retirement_plan_production_eligible_v1(
        plan,
        observation,
        transition,
    ):
        raise ProductionEvidenceRequired("native loss evidence required")


def validate_loss_retirement_plan_replay_v1(
    candidate: LossRetirementPlanV1,
    retained: LossRetirementPlanV1,
) -> None:
    if candidate != retained:
        raise InvalidLossRetirementPlan("non-identical replay")


def loss_retirement_receipt_root_v1(
    value: LossRetirementReceiptV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(RECEIPT_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.recovery_generation,
        value.reference_release_count,
        value.returned_logical_device_bytes,
        value.physical_reclaim_observed,
    )
    for root in (
        value.plan_sha256,
        value.transition_receipt_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.allocation_terminal_sha256,
        value.adapter_settlement_sha256,
        value.output_authority_sha256,
        value.migration_authority_sha256,
        value.reset_authority_sha256,
        value.physical_reclaim_authority_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_retirement_receipt_v1(
    plan: LossRetirementPlanV1,
    terminal: allocation_tree.LeaseTreeAllocationTerminalReceiptV1,
    adapter_settlement_sha256: Digest,
    reference_release_count: int,
) -> LossRetirementReceiptV1:
    result = LossRetirementReceiptV1(
        source=plan.source,
        evidence_class=plan.evidence_class,
        recovery_generation=plan.recovery_generation,
        reference_release_count=reference_release_count,
        returned_logical_device_bytes=terminal.returned_device_bytes,
        physical_reclaim_observed=0,
        plan_sha256=plan.plan_sha256,
        transition_receipt_sha256=plan.transition_receipt_sha256,
        allocation_lease_sha256=plan.allocation_lease_sha256,
        allocation_leaf_set_sha256=plan.allocation_leaf_set_sha256,
        backend_object_set_sha256=plan.backend_object_set_sha256,
        allocation_terminal_sha256=terminal.terminal_sha256,
        adapter_settlement_sha256=adapter_settlement_sha256,
    )
    result = replace(
        result,
        receipt_sha256=loss_retirement_receipt_root_v1(result),
    )
    validate_loss_retirement_receipt_v1(result, plan, terminal)
    return result


def validate_loss_retirement_receipt_v1(
    value: LossRetirementReceiptV1,
    plan: LossRetirementPlanV1,
    terminal: allocation_tree.LeaseTreeAllocationTerminalReceiptV1,
) -> None:
    try:
        allocation_tree.validate_terminal_v1(terminal)
        _validate_plan_fields(plan)
        _validate_receipt_fields(value)
        plan_root_valid = (
            plan.plan_sha256 != ZERO_DIGEST
            and plan.plan_sha256 == loss_retirement_plan_root_v1(plan)
        )
        receipt_root_valid = (
            value.receipt_sha256 != ZERO_DIGEST
            and value.receipt_sha256
            == loss_retirement_receipt_root_v1(value)
        )
    except (
        allocation_tree.ContractError,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidLossRetirementReceipt("nested evidence") from error
    if (
        plan.abi_version != PLAN_ABI
        or not plan_root_valid
        or terminal.outcome != allocation_tree.OUTCOME_RELEASED
        or terminal.reason != allocation_tree.REASON_NORMAL_RELEASE
        or terminal.authority_sha256
        != plan.allocation_authority_sha256
        or terminal.request_sha256 != plan.allocation_request_sha256
        or terminal.lease_sha256 != plan.allocation_lease_sha256
        or terminal.backend_object_set_sha256
        != plan.backend_object_set_sha256
        or terminal.returned_device_bytes != plan.materialized_bytes
        or value.abi_version != RECEIPT_ABI
        or value.source != plan.source
        or value.evidence_class != plan.evidence_class
        or value.recovery_generation != plan.recovery_generation
        or value.reference_release_count != plan.allocation_count
        or value.returned_logical_device_bytes != plan.materialized_bytes
        or value.physical_reclaim_observed != 0
        or value.plan_sha256 != plan.plan_sha256
        or value.transition_receipt_sha256
        != plan.transition_receipt_sha256
        or value.allocation_lease_sha256
        != plan.allocation_lease_sha256
        or value.allocation_leaf_set_sha256
        != plan.allocation_leaf_set_sha256
        or value.backend_object_set_sha256
        != plan.backend_object_set_sha256
        or value.allocation_terminal_sha256 != terminal.terminal_sha256
        or value.adapter_settlement_sha256 == ZERO_DIGEST
        or value.output_authority_sha256 != ZERO_DIGEST
        or value.migration_authority_sha256 != ZERO_DIGEST
        or value.reset_authority_sha256 != ZERO_DIGEST
        or value.physical_reclaim_authority_sha256 != ZERO_DIGEST
        or not receipt_root_valid
    ):
        raise InvalidLossRetirementReceipt("shape or binding")


def validate_loss_retirement_receipt_replay_v1(
    candidate: LossRetirementReceiptV1,
    retained: LossRetirementReceiptV1,
) -> None:
    if candidate != retained:
        raise InvalidLossRetirementReceipt("non-identical replay")


def _validate_plan_fields(value: LossRetirementPlanV1) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.successor_state,
        value.source_sequence,
        value.recovery_generation,
        value.allocation_count,
        value.materialized_bytes,
    )
    for root in (
        value.source_instance_sha256,
        value.observation_sha256,
        value.transition_receipt_sha256,
        value.requirement_sha256,
        value.prior_inventory_sha256,
        value.selected_entry_sha256,
        value.selected_capability_sha256,
        value.selection_receipt_sha256,
        value.allocation_authority_sha256,
        value.allocation_request_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.adapter_challenge_sha256,
        value.plan_sha256,
    ):
        _digest(root)


def _validate_receipt_fields(value: LossRetirementReceiptV1) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.recovery_generation,
        value.reference_release_count,
        value.returned_logical_device_bytes,
        value.physical_reclaim_observed,
    )
    for root in (
        value.plan_sha256,
        value.transition_receipt_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.allocation_terminal_sha256,
        value.adapter_settlement_sha256,
        value.output_authority_sha256,
        value.migration_authority_sha256,
        value.reset_authority_sha256,
        value.physical_reclaim_authority_sha256,
        value.receipt_sha256,
    ):
        _digest(root)


def _u64(value: int) -> bytes:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError("u64 must be an integer")
    if value < 0 or value > U64_MAX:
        raise ValueError("u64 out of range")
    return struct.pack("<Q", value)


def _u64s(*values: int) -> None:
    for value in values:
        _u64(value)


def _update_u64(
    digest: "hashlib._Hash",  # type: ignore[name-defined]
    *values: int,
) -> None:
    for value in values:
        digest.update(_u64(value))


def _digest(value: Digest) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise ValueError("digest must be exactly 32 bytes")
    return value
