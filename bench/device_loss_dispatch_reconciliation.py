"""Independent oracle for device-loss dispatch reconciliation.

This module mirrors the fixed-width V1 contract using only Python's standard
library and the independent lifecycle and LeaseTree allocation oracles.  It
does not parse Zig source, load Glacier symbols, or infer native state.

The three records deliberately separate:

* retention of one exact command-buffer device-removed failure;
* a lifecycle-loss plan that joins that retained dispatch to one observation;
* settlement after the dispatch pin and native command are each finalized.

Synthetic evidence may exercise the complete structural protocol, but only an
exact native ``5 / 1 / 11`` lifecycle observation is production eligible.
None of the records grants output, migration, reset, or physical-reclaim
authority.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, replace
from typing import Sequence

from bench import device_allocation_lease_tree as allocation_tree
from bench import device_capability_contract as device
from bench import device_lifecycle_contract as lifecycle


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1

RETENTION_ABI = 0x4744_4454_0000_0001
PLAN_ABI = 0x4744_4450_0000_0001
RECEIPT_ABI = 0x4744_4452_0000_0001

RETENTION_SIZE_BYTES = 440
PLAN_SIZE_BYTES = 240
RECEIPT_SIZE_BYTES = 448

RETENTION_DOMAIN = b"glacier-device-loss-dispatch-retention-v1\x00"
PLAN_DOMAIN = (
    b"glacier-device-loss-dispatch-reconciliation-plan-v1\x00"
)
RECEIPT_DOMAIN = (
    b"glacier-device-loss-dispatch-reconciliation-receipt-v1\x00"
)

LOSS_DISPATCH_RETENTION_EXACT_COMMAND_DEVICE_REMOVED = 1


class ContractError(ValueError):
    """A device-loss dispatch reconciliation value is invalid."""


class InvalidLossDispatchRetention(ContractError):
    pass


class InvalidLossDispatchReconciliationPlan(ContractError):
    pass


class ProductionEvidenceRequired(ContractError):
    pass


class InvalidLossDispatchReconciliationReceipt(ContractError):
    pass


@dataclass(frozen=True)
class LossDispatchRetentionV1:
    abi_version: int = RETENTION_ABI
    kind: int = LOSS_DISPATCH_RETENTION_EXACT_COMMAND_DEVICE_REMOVED
    source: int = lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    dispatch_generation: int = 0
    allocation_count: int = 0
    pinned_device_bytes: int = 0
    native_command_status: int = 0
    native_completion_observed: int = 0
    native_error_domain_kind: int = 0
    native_error_code_bits: int = 0
    selected_capability_sha256: Digest = ZERO_DIGEST
    allocation_lease_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    dispatch_pin_sha256: Digest = ZERO_DIGEST
    dispatch_request_sha256: Digest = ZERO_DIGEST
    submission_sha256: Digest = ZERO_DIGEST
    backend_quarantine_sha256: Digest = ZERO_DIGEST
    adapter_challenge_sha256: Digest = ZERO_DIGEST
    output_authority_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LossDispatchReconciliationPlanV1:
    abi_version: int = PLAN_ABI
    source: int = lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    successor_state: int = device.INVENTORY_LOST
    source_sequence: int = 0
    reconciliation_generation: int = 0
    source_instance_sha256: Digest = ZERO_DIGEST
    observation_sha256: Digest = ZERO_DIGEST
    transition_receipt_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST
    plan_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LossDispatchReconciliationReceiptV1:
    abi_version: int = RECEIPT_ABI
    source: int = lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    outcome: int = allocation_tree.DISPATCH_TERMINAL_FAILURE
    source_sequence: int = 0
    reconciliation_generation: int = 0
    released_dispatch_pin_count: int = 0
    finalized_native_command_count: int = 0
    plan_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST
    backend_terminal_sha256: Digest = ZERO_DIGEST
    dispatch_terminal_sha256: Digest = ZERO_DIGEST
    dispatch_completion_sha256: Digest = ZERO_DIGEST
    bank_completion_sha256: Digest = ZERO_DIGEST
    adapter_settlement_sha256: Digest = ZERO_DIGEST
    output_authority_sha256: Digest = ZERO_DIGEST
    migration_authority_sha256: Digest = ZERO_DIGEST
    reset_authority_sha256: Digest = ZERO_DIGEST
    physical_reclaim_authority_sha256: Digest = ZERO_DIGEST
    receipt_sha256: Digest = ZERO_DIGEST


def loss_dispatch_retention_root_v1(
    value: LossDispatchRetentionV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(RETENTION_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.kind,
        value.source,
        value.evidence_class,
        value.dispatch_generation,
        value.allocation_count,
        value.pinned_device_bytes,
        value.native_command_status,
        value.native_completion_observed,
        value.native_error_domain_kind,
        value.native_error_code_bits,
    )
    for root in (
        value.selected_capability_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.dispatch_pin_sha256,
        value.dispatch_request_sha256,
        value.submission_sha256,
        value.backend_quarantine_sha256,
        value.adapter_challenge_sha256,
        value.output_authority_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_dispatch_retention_v1(
    source: int,
    evidence_class: int,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    submission_sha256: Digest,
    backend_quarantine_sha256: Digest,
    adapter_challenge_sha256: Digest,
) -> LossDispatchRetentionV1:
    result = LossDispatchRetentionV1(
        source=source,
        evidence_class=evidence_class,
        dispatch_generation=pin.dispatch_generation,
        allocation_count=pin.allocation_count,
        pinned_device_bytes=pin.pinned_device_bytes,
        native_command_status=lifecycle.COMMAND_BUFFER_STATUS_ERROR,
        native_completion_observed=1,
        native_error_domain_kind=lifecycle.COMMAND_BUFFER_ERROR_DOMAIN,
        native_error_code_bits=(
            lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        ),
        selected_capability_sha256=(
            selected_entry.capability.capability_sha256
        ),
        allocation_lease_sha256=lease.lease_sha256,
        allocation_leaf_set_sha256=lease.allocation_leaf_set_sha256,
        backend_object_set_sha256=lease.backend_object_set_sha256,
        dispatch_pin_sha256=pin.pin_sha256,
        dispatch_request_sha256=pin.dispatch_request_sha256,
        submission_sha256=_digest(submission_sha256),
        backend_quarantine_sha256=_digest(
            backend_quarantine_sha256
        ),
        adapter_challenge_sha256=_digest(adapter_challenge_sha256),
    )
    result = replace(
        result,
        retention_sha256=loss_dispatch_retention_root_v1(result),
    )
    validate_loss_dispatch_retention_v1(
        result,
        selected_entry,
        lease,
        pin,
    )
    return result


def validate_loss_dispatch_retention_v1(
    value: LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
) -> None:
    try:
        device.validate_inventory_entry(selected_entry)
        allocation_tree.validate_lease_v1(lease)
        allocation_tree.validate_dispatch_pin_v1(pin)
        _validate_retention_fields(value)
        root_valid = (
            value.retention_sha256 != ZERO_DIGEST
            and value.retention_sha256
            == loss_dispatch_retention_root_v1(value)
        )
    except (
        allocation_tree.ContractError,
        device.ContractError,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidLossDispatchRetention("nested evidence") from error

    expected_evidence = _retention_evidence_class(value.source)
    capability_sha256 = selected_entry.capability.capability_sha256
    if (
        value.abi_version != RETENTION_ABI
        or value.kind
        != LOSS_DISPATCH_RETENTION_EXACT_COMMAND_DEVICE_REMOVED
        or expected_evidence is None
        or value.evidence_class != expected_evidence
        or selected_entry.state != device.INVENTORY_PRESENT
        or lease.selected_capability_sha256 != capability_sha256
        or pin.coordinator_epoch != lease.coordinator_epoch
        or pin.allocation_generation != lease.generation
        or pin.authority_sha256 != lease.authority_sha256
        or pin.request_sha256 != lease.request_sha256
        or pin.admission_sha256 != lease.admission_sha256
        or pin.lease_sha256 != lease.lease_sha256
        or pin.parent_receipt_sha256 != lease.parent_receipt_sha256
        or pin.allocation_leaf_set_sha256
        != lease.allocation_leaf_set_sha256
        or pin.backend_object_set_sha256
        != lease.backend_object_set_sha256
        or pin.scope != lease.scope
        or pin.allocation_count != lease.allocation_count
        or pin.pinned_device_bytes != lease.materialized_bytes
        or value.dispatch_generation != pin.dispatch_generation
        or value.allocation_count != pin.allocation_count
        or value.pinned_device_bytes != pin.pinned_device_bytes
        or value.native_command_status
        != lifecycle.COMMAND_BUFFER_STATUS_ERROR
        or value.native_completion_observed != 1
        or value.native_error_domain_kind
        != lifecycle.COMMAND_BUFFER_ERROR_DOMAIN
        or value.native_error_code_bits
        != lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        or value.selected_capability_sha256
        != capability_sha256
        or value.allocation_lease_sha256 != lease.lease_sha256
        or value.allocation_leaf_set_sha256
        != lease.allocation_leaf_set_sha256
        or value.backend_object_set_sha256
        != lease.backend_object_set_sha256
        or value.dispatch_pin_sha256 != pin.pin_sha256
        or value.dispatch_request_sha256
        != pin.dispatch_request_sha256
        or value.submission_sha256 == ZERO_DIGEST
        or value.backend_quarantine_sha256 == ZERO_DIGEST
        or value.adapter_challenge_sha256 == ZERO_DIGEST
        or value.output_authority_sha256 != ZERO_DIGEST
        or not root_valid
    ):
        raise InvalidLossDispatchRetention("shape or binding")


def validate_loss_dispatch_retention_replay_v1(
    candidate: LossDispatchRetentionV1,
    retained: LossDispatchRetentionV1,
) -> None:
    if candidate != retained:
        raise InvalidLossDispatchRetention("non-identical replay")


def loss_dispatch_reconciliation_plan_root_v1(
    value: LossDispatchReconciliationPlanV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(PLAN_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.successor_state,
        value.source_sequence,
        value.reconciliation_generation,
    )
    for root in (
        value.source_instance_sha256,
        value.observation_sha256,
        value.transition_receipt_sha256,
        value.selected_capability_sha256,
        value.retention_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_dispatch_reconciliation_plan_v1(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    retention: LossDispatchRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    reconciliation_generation: int,
) -> LossDispatchReconciliationPlanV1:
    result = LossDispatchReconciliationPlanV1(
        source=observation.source,
        evidence_class=observation.evidence_class,
        successor_state=transition.successor_state,
        source_sequence=observation.source_sequence,
        reconciliation_generation=reconciliation_generation,
        source_instance_sha256=observation.source_instance_sha256,
        observation_sha256=observation.observation_sha256,
        transition_receipt_sha256=transition.receipt_sha256,
        selected_capability_sha256=(
            selected_entry.capability.capability_sha256
        ),
        retention_sha256=retention.retention_sha256,
    )
    result = replace(
        result,
        plan_sha256=loss_dispatch_reconciliation_plan_root_v1(result),
    )
    validate_loss_dispatch_reconciliation_plan_v1(
        result,
        observation,
        transition,
        source_cursor,
        requirement,
        selection,
        prior_inventory,
        selected_entry,
        successor_entry,
        retention,
        lease,
        pin,
    )
    return result


def validate_loss_dispatch_reconciliation_plan_v1(
    value: LossDispatchReconciliationPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    retention: LossDispatchRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
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
        validate_loss_dispatch_retention_v1(
            retention,
            selected_entry,
            lease,
            pin,
        )
        _validate_plan_fields(value)
        plan_root_valid = (
            value.plan_sha256 != ZERO_DIGEST
            and value.plan_sha256
            == loss_dispatch_reconciliation_plan_root_v1(value)
        )
    except (
        InvalidLossDispatchRetention,
        device.ContractError,
        lifecycle.ContractError,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidLossDispatchReconciliationPlan(
            "nested evidence"
        ) from error

    capability_sha256 = selected_entry.capability.capability_sha256
    if (
        observation.observed_state != device.INVENTORY_LOST
        or transition.prior_state != device.INVENTORY_PRESENT
        or transition.successor_state != device.INVENTORY_LOST
        or selected_entry.state != device.INVENTORY_PRESENT
        or successor_entry.state != device.INVENTORY_LOST
        or observation.capability_sha256 != capability_sha256
        or transition.capability_sha256 != capability_sha256
        or retention.selected_capability_sha256 != capability_sha256
        or selection.selected_entry_sha256
        != selected_entry.entry_sha256
        or selection.selected_capability_sha256 != capability_sha256
        or lease.selection_receipt_sha256 != selection.receipt_sha256
        or value.abi_version != PLAN_ABI
        or value.source != retention.source
        or value.source != observation.source
        or value.source != transition.source
        or value.evidence_class != retention.evidence_class
        or value.evidence_class != observation.evidence_class
        or value.evidence_class != transition.evidence_class
        or value.successor_state != device.INVENTORY_LOST
        or value.successor_state != transition.successor_state
        or value.source_sequence == 0
        or value.source_sequence != observation.source_sequence
        or value.source_sequence != transition.source_sequence
        or value.reconciliation_generation == 0
        or value.source_instance_sha256
        != observation.source_instance_sha256
        or value.observation_sha256 != observation.observation_sha256
        or value.transition_receipt_sha256 != transition.receipt_sha256
        or value.selected_capability_sha256 != capability_sha256
        or value.retention_sha256 != retention.retention_sha256
        or not plan_root_valid
    ):
        raise InvalidLossDispatchReconciliationPlan(
            "shape or binding"
        )


def loss_dispatch_reconciliation_plan_production_eligible_v1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> bool:
    try:
        roots_valid = (
            plan.plan_sha256 != ZERO_DIGEST
            and plan.plan_sha256
            == loss_dispatch_reconciliation_plan_root_v1(plan)
            and retention.retention_sha256 != ZERO_DIGEST
            and retention.retention_sha256
            == loss_dispatch_retention_root_v1(retention)
        )
    except (TypeError, ValueError):
        return False
    return (
        roots_valid
        and plan.abi_version == PLAN_ABI
        and retention.abi_version == RETENTION_ABI
        and retention.kind
        == LOSS_DISPATCH_RETENTION_EXACT_COMMAND_DEVICE_REMOVED
        and plan.source
        == lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
        and retention.source == plan.source
        and observation.source == plan.source
        and transition.source == plan.source
        and plan.evidence_class == lifecycle.EVIDENCE_NATIVE
        and retention.evidence_class == lifecycle.EVIDENCE_NATIVE
        and observation.evidence_class == lifecycle.EVIDENCE_NATIVE
        and transition.evidence_class == lifecycle.EVIDENCE_NATIVE
        and plan.observation_sha256 == observation.observation_sha256
        and plan.transition_receipt_sha256
        == transition.receipt_sha256
        and plan.retention_sha256 == retention.retention_sha256
        and plan.successor_state == device.INVENTORY_LOST
        and observation.observed_state == device.INVENTORY_LOST
        and transition.prior_state == device.INVENTORY_PRESENT
        and transition.successor_state == device.INVENTORY_LOST
        and observation.native_command_status
        == lifecycle.COMMAND_BUFFER_STATUS_ERROR
        and observation.native_error_domain_kind
        == lifecycle.COMMAND_BUFFER_ERROR_DOMAIN
        and observation.native_error_code_bits
        == lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        and retention.native_command_status
        == lifecycle.COMMAND_BUFFER_STATUS_ERROR
        and retention.native_completion_observed == 1
        and retention.native_error_domain_kind
        == lifecycle.COMMAND_BUFFER_ERROR_DOMAIN
        and retention.native_error_code_bits
        == lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        and observation.observation_sha256 != ZERO_DIGEST
        and observation.observation_sha256
        == lifecycle.observation_root(observation)
        and transition.receipt_sha256 != ZERO_DIGEST
        and transition.receipt_sha256
        == lifecycle.transition_receipt_root(transition)
    )


def require_production_eligible_loss_dispatch_reconciliation_plan_v1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> None:
    if not loss_dispatch_reconciliation_plan_production_eligible_v1(
        plan,
        retention,
        observation,
        transition,
    ):
        raise ProductionEvidenceRequired(
            "exact native command-buffer device-loss evidence required"
        )


def validate_loss_dispatch_reconciliation_plan_replay_v1(
    candidate: LossDispatchReconciliationPlanV1,
    retained: LossDispatchReconciliationPlanV1,
) -> None:
    if candidate != retained:
        raise InvalidLossDispatchReconciliationPlan(
            "non-identical replay"
        )


def loss_dispatch_reconciliation_receipt_root_v1(
    value: LossDispatchReconciliationReceiptV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(RECEIPT_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.outcome,
        value.source_sequence,
        value.reconciliation_generation,
        value.released_dispatch_pin_count,
        value.finalized_native_command_count,
    )
    for root in (
        value.plan_sha256,
        value.retention_sha256,
        value.backend_terminal_sha256,
        value.dispatch_terminal_sha256,
        value.dispatch_completion_sha256,
        value.bank_completion_sha256,
        value.adapter_settlement_sha256,
        value.output_authority_sha256,
        value.migration_authority_sha256,
        value.reset_authority_sha256,
        value.physical_reclaim_authority_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_dispatch_reconciliation_receipt_v1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    terminal: allocation_tree.DispatchTerminalEvidenceV1,
    completion: allocation_tree.LeaseTreeDispatchCompletionV1,
    adapter_settlement_sha256: Digest,
) -> LossDispatchReconciliationReceiptV1:
    result = LossDispatchReconciliationReceiptV1(
        source=plan.source,
        evidence_class=plan.evidence_class,
        outcome=terminal.outcome,
        source_sequence=plan.source_sequence,
        reconciliation_generation=plan.reconciliation_generation,
        released_dispatch_pin_count=1,
        finalized_native_command_count=1,
        plan_sha256=plan.plan_sha256,
        retention_sha256=retention.retention_sha256,
        backend_terminal_sha256=terminal.backend_completion_sha256,
        dispatch_terminal_sha256=terminal.terminal_sha256,
        dispatch_completion_sha256=completion.completion_sha256,
        bank_completion_sha256=completion.bank_completion_sha256,
        adapter_settlement_sha256=_digest(
            adapter_settlement_sha256
        ),
    )
    result = replace(
        result,
        receipt_sha256=(
            loss_dispatch_reconciliation_receipt_root_v1(result)
        ),
    )
    validate_loss_dispatch_reconciliation_receipt_v1(
        result,
        plan,
        retention,
        selected_entry,
        lease,
        pin,
        terminal,
        completion,
    )
    return result


def validate_loss_dispatch_reconciliation_receipt_v1(
    value: LossDispatchReconciliationReceiptV1,
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    terminal: allocation_tree.DispatchTerminalEvidenceV1,
    completion: allocation_tree.LeaseTreeDispatchCompletionV1,
) -> None:
    try:
        validate_loss_dispatch_retention_v1(
            retention,
            selected_entry,
            lease,
            pin,
        )
        allocation_tree.validate_dispatch_terminal_for_pin_v1(
            terminal,
            pin,
        )
        allocation_tree.validate_dispatch_completion_for_pin_v1(
            completion,
            pin,
            terminal,
        )
        _validate_plan_fields(plan)
        _validate_receipt_fields(value)
        plan_root_valid = (
            plan.plan_sha256 != ZERO_DIGEST
            and plan.plan_sha256
            == loss_dispatch_reconciliation_plan_root_v1(plan)
        )
        receipt_root_valid = (
            value.receipt_sha256 != ZERO_DIGEST
            and value.receipt_sha256
            == loss_dispatch_reconciliation_receipt_root_v1(value)
        )
    except (
        InvalidLossDispatchRetention,
        allocation_tree.ContractError,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidLossDispatchReconciliationReceipt(
            "nested evidence"
        ) from error

    if (
        retention.abi_version != RETENTION_ABI
        or retention.output_authority_sha256 != ZERO_DIGEST
        or retention.dispatch_pin_sha256 != pin.pin_sha256
        or retention.dispatch_generation != pin.dispatch_generation
        or retention.dispatch_request_sha256
        != pin.dispatch_request_sha256
        or plan.abi_version != PLAN_ABI
        or plan.retention_sha256 != retention.retention_sha256
        or not plan_root_valid
        or terminal.outcome != allocation_tree.DISPATCH_TERMINAL_FAILURE
        or terminal.dispatch_generation != retention.dispatch_generation
        or terminal.pin_sha256 != retention.dispatch_pin_sha256
        or terminal.dispatch_request_sha256
        != retention.dispatch_request_sha256
        or terminal.submission_sha256 != retention.submission_sha256
        or terminal.backend_completion_sha256 == ZERO_DIGEST
        or terminal.output_sha256 != ZERO_DIGEST
        or completion.outcome
        != allocation_tree.DISPATCH_TERMINAL_FAILURE
        or completion.output_sha256 != ZERO_DIGEST
        or value.abi_version != RECEIPT_ABI
        or value.source != plan.source
        or value.source != retention.source
        or value.evidence_class != plan.evidence_class
        or value.evidence_class != retention.evidence_class
        or value.outcome != allocation_tree.DISPATCH_TERMINAL_FAILURE
        or value.source_sequence != plan.source_sequence
        or value.reconciliation_generation
        != plan.reconciliation_generation
        or value.released_dispatch_pin_count != 1
        or value.finalized_native_command_count != 1
        or value.plan_sha256 != plan.plan_sha256
        or value.retention_sha256 != retention.retention_sha256
        or value.backend_terminal_sha256
        != terminal.backend_completion_sha256
        or value.dispatch_terminal_sha256 != terminal.terminal_sha256
        or value.dispatch_completion_sha256
        != completion.completion_sha256
        or value.bank_completion_sha256
        != completion.bank_completion_sha256
        or value.adapter_settlement_sha256 == ZERO_DIGEST
        or value.output_authority_sha256 != ZERO_DIGEST
        or value.migration_authority_sha256 != ZERO_DIGEST
        or value.reset_authority_sha256 != ZERO_DIGEST
        or value.physical_reclaim_authority_sha256 != ZERO_DIGEST
        or not receipt_root_valid
    ):
        raise InvalidLossDispatchReconciliationReceipt(
            "shape or binding"
        )


def validate_loss_dispatch_reconciliation_receipt_replay_v1(
    candidate: LossDispatchReconciliationReceiptV1,
    retained: LossDispatchReconciliationReceiptV1,
) -> None:
    if candidate != retained:
        raise InvalidLossDispatchReconciliationReceipt(
            "non-identical replay"
        )


def _retention_evidence_class(source: int) -> int | None:
    if source == lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED:
        return lifecycle.EVIDENCE_NATIVE
    if source == lifecycle.SOURCE_TEST_INJECTED:
        return lifecycle.EVIDENCE_SYNTHETIC
    return None


def _validate_retention_fields(value: LossDispatchRetentionV1) -> None:
    _u64s(
        value.abi_version,
        value.kind,
        value.source,
        value.evidence_class,
        value.dispatch_generation,
        value.allocation_count,
        value.pinned_device_bytes,
        value.native_command_status,
        value.native_completion_observed,
        value.native_error_domain_kind,
        value.native_error_code_bits,
    )
    for root in (
        value.selected_capability_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.dispatch_pin_sha256,
        value.dispatch_request_sha256,
        value.submission_sha256,
        value.backend_quarantine_sha256,
        value.adapter_challenge_sha256,
        value.output_authority_sha256,
        value.retention_sha256,
    ):
        _digest(root)


def _validate_plan_fields(
    value: LossDispatchReconciliationPlanV1,
) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.successor_state,
        value.source_sequence,
        value.reconciliation_generation,
    )
    for root in (
        value.source_instance_sha256,
        value.observation_sha256,
        value.transition_receipt_sha256,
        value.selected_capability_sha256,
        value.retention_sha256,
        value.plan_sha256,
    ):
        _digest(root)


def _validate_receipt_fields(
    value: LossDispatchReconciliationReceiptV1,
) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.outcome,
        value.source_sequence,
        value.reconciliation_generation,
        value.released_dispatch_pin_count,
        value.finalized_native_command_count,
    )
    for root in (
        value.plan_sha256,
        value.retention_sha256,
        value.backend_terminal_sha256,
        value.dispatch_terminal_sha256,
        value.dispatch_completion_sha256,
        value.bank_completion_sha256,
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
        raise TypeError("digest must contain exactly 32 bytes")
    return value
