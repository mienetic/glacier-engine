"""Independent oracle for callback-safe device-loss dispatch retirement.

This module mirrors the fixed-width Phase B records without importing or
parsing Zig source.  The records are pointer-free composition evidence.  They
do not themselves detach a callback, release a Bank pin, retire a native
record, publish output, migrate work, reset a device, or reclaim physical
memory.

The callback fence deliberately does not require callback exit.  A backend may
detach callback ownership while the callback is still outstanding, provided
the exact native record remains retained.  ``native_completion_observed`` and
``callback_snapshot_sha256`` are diagnostic facts about whether callback exit
has subsequently been observed.
"""

from __future__ import annotations

import hashlib
import json
import struct
from dataclasses import dataclass, replace
from typing import Sequence

from bench import device_capability_contract as device
from bench import device_lifecycle_contract as lifecycle


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1

RETENTION_ABI = 0x4744_4354_0000_0001
PLAN_ABI = 0x4744_4350_0000_0001
FENCE_ABI = 0x4744_4346_0000_0001
RECEIPT_ABI = 0x4744_4352_0000_0001

RETENTION_SIZE_BYTES = 464
PLAN_SIZE_BYTES = 240
FENCE_SIZE_BYTES = 408
RECEIPT_SIZE_BYTES = 504

RETENTION_DOMAIN = (
    b"glacier-device-loss-dispatch-callback-retention-v1\x00"
)
PLAN_DOMAIN = (
    b"glacier-device-loss-dispatch-callback-retirement-plan-v1\x00"
)
FENCE_DOMAIN = b"glacier-device-loss-dispatch-callback-fence-v1\x00"
RECEIPT_DOMAIN = (
    b"glacier-device-loss-dispatch-callback-retirement-receipt-v1\x00"
)

RETAINED_PENDING = 1
RETAINED_SUBMISSION_AMBIGUOUS = 2
RETAINED_COMPLETION_UNKNOWN = 3
RETAINED_INVALID_COMPLETION = 4
VALID_RETAINED_STATES = frozenset(
    {
        RETAINED_PENDING,
        RETAINED_SUBMISSION_AMBIGUOUS,
        RETAINED_COMPLETION_UNKNOWN,
        RETAINED_INVALID_COMPLETION,
    }
)

FENCE_DETACHED_PENDING_SETTLEMENT = 1
OWNERSHIP_RETIRED_AFTER_DEVICE_LOSS = 6

NATIVE_COMMIT_STARTED = 1
NATIVE_SUBMITTED = 2
NATIVE_TERMINAL_STATUS_OBSERVED = 3

NATIVE_ERROR_NONE = 0
NATIVE_ERROR_BRIDGE = 1
NATIVE_ERROR_COMPLETION_VALIDATION = 2
NATIVE_ERROR_COMMAND_BUFFER = 3
NATIVE_ERROR_OTHER = 4

NATIVE_COMMAND_STATUS_UNOBSERVED = U64_MAX
NATIVE_COMMAND_STATUS_COMPLETED = 4
SUBMISSION_AMBIGUOUS_CODE = 1

_STRUCTURAL_SOURCES = frozenset(
    {
        lifecycle.SOURCE_REMOVED_NOTIFICATION,
        lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
        lifecycle.SOURCE_TEST_INJECTED,
    }
)
_PRODUCTION_SOURCES = frozenset(
    {
        lifecycle.SOURCE_REMOVED_NOTIFICATION,
        lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
    }
)


class ContractError(ValueError):
    """A callback-retirement record or trace is invalid."""


class InvalidCallbackRetention(ContractError):
    pass


class InvalidCallbackRetirementPlan(ContractError):
    pass


class ProductionEvidenceRequired(ContractError):
    pass


class InvalidCallbackFence(ContractError):
    pass


class InvalidCallbackRetirementReceipt(ContractError):
    pass


class InvalidCallbackRetirementTrace(ContractError):
    pass


@dataclass(frozen=True)
class LossDispatchCallbackRetentionV1:
    abi_version: int = RETENTION_ABI
    retained_state: int = RETAINED_PENDING
    dispatch_generation: int = 0
    allocation_count: int = 0
    pinned_device_bytes: int = 0
    native_disposition: int = NATIVE_SUBMITTED
    native_command_status: int = 0
    native_completion_observed: int = 0
    native_error_domain_kind: int = NATIVE_ERROR_NONE
    native_error_code_bits: int = 0
    selected_capability_sha256: Digest = ZERO_DIGEST
    allocation_lease_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    dispatch_pin_sha256: Digest = ZERO_DIGEST
    dispatch_request_sha256: Digest = ZERO_DIGEST
    async_ticket_sha256: Digest = ZERO_DIGEST
    submission_sha256: Digest = ZERO_DIGEST
    backend_quarantine_sha256: Digest = ZERO_DIGEST
    adapter_challenge_sha256: Digest = ZERO_DIGEST
    output_authority_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LossDispatchCallbackRetirementPlanV1:
    abi_version: int = PLAN_ABI
    source: int = lifecycle.SOURCE_REMOVED_NOTIFICATION
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    successor_state: int = device.INVENTORY_LOST
    source_sequence: int = 0
    retirement_generation: int = 0
    source_instance_sha256: Digest = ZERO_DIGEST
    observation_sha256: Digest = ZERO_DIGEST
    transition_receipt_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST
    plan_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LossDispatchCallbackFenceV1:
    abi_version: int = FENCE_ABI
    state: int = FENCE_DETACHED_PENDING_SETTLEMENT
    retained_state: int = RETAINED_PENDING
    retirement_generation: int = 0
    native_retirement_generation: int = 0
    native_completion_observed: int = 0
    native_callback_detached: int = 1
    native_record_retained: int = 1
    native_command_status: int = 0
    native_error_domain_kind: int = NATIVE_ERROR_NONE
    native_error_code_bits: int = 0
    plan_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST
    async_ticket_sha256: Digest = ZERO_DIGEST
    submission_sha256: Digest = ZERO_DIGEST
    backend_quarantine_sha256: Digest = ZERO_DIGEST
    native_prepare_sha256: Digest = ZERO_DIGEST
    callback_snapshot_sha256: Digest = ZERO_DIGEST
    backend_terminal_sha256: Digest = ZERO_DIGEST
    output_authority_sha256: Digest = ZERO_DIGEST
    fence_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LossDispatchCallbackRetirementReceiptV1:
    abi_version: int = RECEIPT_ABI
    source: int = lifecycle.SOURCE_REMOVED_NOTIFICATION
    evidence_class: int = lifecycle.EVIDENCE_NATIVE
    outcome: int = OWNERSHIP_RETIRED_AFTER_DEVICE_LOSS
    retained_state: int = RETAINED_PENDING
    source_sequence: int = 0
    retirement_generation: int = 0
    native_retirement_generation: int = 0
    released_dispatch_pin_count: int = 0
    retired_native_command_count: int = 0
    detached_native_callback_count: int = 0
    plan_sha256: Digest = ZERO_DIGEST
    retention_sha256: Digest = ZERO_DIGEST
    callback_fence_sha256: Digest = ZERO_DIGEST
    dispatch_terminal_sha256: Digest = ZERO_DIGEST
    dispatch_completion_sha256: Digest = ZERO_DIGEST
    bank_completion_sha256: Digest = ZERO_DIGEST
    native_retirement_sha256: Digest = ZERO_DIGEST
    adapter_settlement_sha256: Digest = ZERO_DIGEST
    output_authority_sha256: Digest = ZERO_DIGEST
    migration_authority_sha256: Digest = ZERO_DIGEST
    reset_authority_sha256: Digest = ZERO_DIGEST
    physical_reclaim_authority_sha256: Digest = ZERO_DIGEST
    receipt_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DeterministicCallbackRetirementFixtureV1:
    observation: lifecycle.ObservationV1
    transition: lifecycle.TransitionReceiptV1
    retention: LossDispatchCallbackRetentionV1
    plan: LossDispatchCallbackRetirementPlanV1
    fence: LossDispatchCallbackFenceV1
    receipt: LossDispatchCallbackRetirementReceiptV1


def loss_dispatch_callback_retention_root_v1(
    value: LossDispatchCallbackRetentionV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(RETENTION_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.retained_state,
        value.dispatch_generation,
        value.allocation_count,
        value.pinned_device_bytes,
        value.native_disposition,
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
        value.async_ticket_sha256,
        value.submission_sha256,
        value.backend_quarantine_sha256,
        value.adapter_challenge_sha256,
        value.output_authority_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_dispatch_callback_retention_v1(
    retained_state: int,
    dispatch_generation: int,
    allocation_count: int,
    pinned_device_bytes: int,
    selected_capability_sha256: Digest,
    allocation_lease_sha256: Digest,
    allocation_leaf_set_sha256: Digest,
    backend_object_set_sha256: Digest,
    dispatch_pin_sha256: Digest,
    dispatch_request_sha256: Digest,
    async_ticket_sha256: Digest,
    submission_sha256: Digest,
    backend_quarantine_sha256: Digest,
    adapter_challenge_sha256: Digest,
    *,
    native_disposition: int | None = None,
    native_command_status: int | None = None,
    native_completion_observed: int | None = None,
    native_error_domain_kind: int | None = None,
    native_error_code_bits: int | None = None,
) -> LossDispatchCallbackRetentionV1:
    defaults = _retention_native_defaults(retained_state)
    result = LossDispatchCallbackRetentionV1(
        retained_state=retained_state,
        dispatch_generation=dispatch_generation,
        allocation_count=allocation_count,
        pinned_device_bytes=pinned_device_bytes,
        native_disposition=(
            defaults[0]
            if native_disposition is None
            else native_disposition
        ),
        native_command_status=(
            defaults[1]
            if native_command_status is None
            else native_command_status
        ),
        native_completion_observed=(
            defaults[2]
            if native_completion_observed is None
            else native_completion_observed
        ),
        native_error_domain_kind=(
            defaults[3]
            if native_error_domain_kind is None
            else native_error_domain_kind
        ),
        native_error_code_bits=(
            defaults[4]
            if native_error_code_bits is None
            else native_error_code_bits
        ),
        selected_capability_sha256=_digest(
            selected_capability_sha256
        ),
        allocation_lease_sha256=_digest(allocation_lease_sha256),
        allocation_leaf_set_sha256=_digest(
            allocation_leaf_set_sha256
        ),
        backend_object_set_sha256=_digest(
            backend_object_set_sha256
        ),
        dispatch_pin_sha256=_digest(dispatch_pin_sha256),
        dispatch_request_sha256=_digest(dispatch_request_sha256),
        async_ticket_sha256=_digest(async_ticket_sha256),
        submission_sha256=_digest(submission_sha256),
        backend_quarantine_sha256=_digest(
            backend_quarantine_sha256
        ),
        adapter_challenge_sha256=_digest(adapter_challenge_sha256),
    )
    result = replace(
        result,
        retention_sha256=loss_dispatch_callback_retention_root_v1(
            result
        ),
    )
    validate_loss_dispatch_callback_retention_v1(result)
    return result


def validate_loss_dispatch_callback_retention_v1(
    value: LossDispatchCallbackRetentionV1,
) -> None:
    try:
        _validate_retention_fields(value)
        valid_root = (
            value.retention_sha256 != ZERO_DIGEST
            and value.retention_sha256
            == loss_dispatch_callback_retention_root_v1(value)
        )
    except (AttributeError, TypeError, ValueError) as error:
        raise InvalidCallbackRetention("field encoding") from error

    required_roots = (
        value.selected_capability_sha256,
        value.allocation_lease_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.dispatch_pin_sha256,
        value.dispatch_request_sha256,
        value.async_ticket_sha256,
        value.submission_sha256,
        value.adapter_challenge_sha256,
    )
    if (
        value.abi_version != RETENTION_ABI
        or value.retained_state not in VALID_RETAINED_STATES
        or value.dispatch_generation in (0, U64_MAX)
        or value.allocation_count == 0
        or value.pinned_device_bytes == 0
        or any(root == ZERO_DIGEST for root in required_roots)
        or value.output_authority_sha256 != ZERO_DIGEST
        or not _retention_shape_valid(value)
        or not valid_root
    ):
        raise InvalidCallbackRetention("shape or root")


def validate_loss_dispatch_callback_retention_replay_v1(
    candidate: LossDispatchCallbackRetentionV1,
    retained: LossDispatchCallbackRetentionV1,
) -> None:
    validate_loss_dispatch_callback_retention_v1(candidate)
    validate_loss_dispatch_callback_retention_v1(retained)
    if candidate != retained:
        raise InvalidCallbackRetention("non-identical replay")


def loss_dispatch_callback_retirement_plan_root_v1(
    value: LossDispatchCallbackRetirementPlanV1,
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
        value.retirement_generation,
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


def make_loss_dispatch_callback_retirement_plan_v1(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    retention: LossDispatchCallbackRetentionV1,
    retirement_generation: int,
) -> LossDispatchCallbackRetirementPlanV1:
    result = LossDispatchCallbackRetirementPlanV1(
        source=observation.source,
        evidence_class=observation.evidence_class,
        successor_state=transition.successor_state,
        source_sequence=observation.source_sequence,
        retirement_generation=retirement_generation,
        source_instance_sha256=observation.source_instance_sha256,
        observation_sha256=observation.observation_sha256,
        transition_receipt_sha256=transition.receipt_sha256,
        selected_capability_sha256=(
            retention.selected_capability_sha256
        ),
        retention_sha256=retention.retention_sha256,
    )
    result = replace(
        result,
        plan_sha256=loss_dispatch_callback_retirement_plan_root_v1(
            result
        ),
    )
    validate_loss_dispatch_callback_retirement_plan_v1(
        result,
        retention,
        observation,
        transition,
    )
    return result


def validate_loss_dispatch_callback_retirement_plan_v1(
    value: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> None:
    try:
        validate_loss_dispatch_callback_retention_v1(retention)
        _validate_plan_fields(value)
        evidence_valid = _loss_evidence_valid(
            observation,
            transition,
            retention.selected_capability_sha256,
        )
        valid_root = (
            value.plan_sha256 != ZERO_DIGEST
            and value.plan_sha256
            == loss_dispatch_callback_retirement_plan_root_v1(value)
        )
    except (
        AttributeError,
        InvalidCallbackRetention,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidCallbackRetirementPlan(
            "nested evidence or encoding"
        ) from error

    if (
        value.abi_version != PLAN_ABI
        or not evidence_valid
        or value.source not in _STRUCTURAL_SOURCES
        or not _source_evidence_pair_valid(
            value.source,
            value.evidence_class,
        )
        or value.source != observation.source
        or value.source != transition.source
        or value.evidence_class != observation.evidence_class
        or value.evidence_class != transition.evidence_class
        or value.successor_state != device.INVENTORY_LOST
        or value.successor_state != transition.successor_state
        or value.source_sequence == 0
        or value.source_sequence != observation.source_sequence
        or value.source_sequence != transition.source_sequence
        or value.retirement_generation in (0, U64_MAX)
        or value.source_instance_sha256
        != observation.source_instance_sha256
        or value.observation_sha256 != observation.observation_sha256
        or value.transition_receipt_sha256 != transition.receipt_sha256
        or value.selected_capability_sha256
        != retention.selected_capability_sha256
        or value.selected_capability_sha256
        != observation.capability_sha256
        or value.retention_sha256 != retention.retention_sha256
        or not valid_root
    ):
        raise InvalidCallbackRetirementPlan("shape or binding")


def loss_dispatch_callback_retirement_plan_production_eligible_v1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> bool:
    try:
        validate_loss_dispatch_callback_retirement_plan_v1(
            plan,
            retention,
            observation,
            transition,
        )
    except ContractError:
        return False
    return (
        plan.source in _PRODUCTION_SOURCES
        and plan.evidence_class == lifecycle.EVIDENCE_NATIVE
        and observation.evidence_class == lifecycle.EVIDENCE_NATIVE
        and transition.evidence_class == lifecycle.EVIDENCE_NATIVE
        and _native_loss_shape_valid(observation)
    )


def require_production_eligible_loss_dispatch_callback_retirement_plan_v1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> None:
    if not (
        loss_dispatch_callback_retirement_plan_production_eligible_v1(
            plan,
            retention,
            observation,
            transition,
        )
    ):
        raise ProductionEvidenceRequired(
            "native removed-notification or command-buffer removal "
            "evidence required"
        )


def validate_loss_dispatch_callback_retirement_plan_replay_v1(
    candidate: LossDispatchCallbackRetirementPlanV1,
    retained: LossDispatchCallbackRetirementPlanV1,
) -> None:
    if candidate != retained:
        raise InvalidCallbackRetirementPlan("non-identical replay")


def loss_dispatch_callback_fence_root_v1(
    value: LossDispatchCallbackFenceV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(FENCE_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.state,
        value.retained_state,
        value.retirement_generation,
        value.native_retirement_generation,
        value.native_completion_observed,
        value.native_callback_detached,
        value.native_record_retained,
        value.native_command_status,
        value.native_error_domain_kind,
        value.native_error_code_bits,
    )
    for root in (
        value.plan_sha256,
        value.retention_sha256,
        value.async_ticket_sha256,
        value.submission_sha256,
        value.backend_quarantine_sha256,
        value.native_prepare_sha256,
        value.callback_snapshot_sha256,
        value.backend_terminal_sha256,
        value.output_authority_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_dispatch_callback_fence_v1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    native_retirement_generation: int,
    native_prepare_sha256: Digest,
    backend_terminal_sha256: Digest,
    *,
    native_completion_observed: int,
    native_command_status: int = 0,
    native_error_domain_kind: int = NATIVE_ERROR_NONE,
    native_error_code_bits: int = 0,
    callback_snapshot_sha256: Digest = ZERO_DIGEST,
) -> LossDispatchCallbackFenceV1:
    result = LossDispatchCallbackFenceV1(
        retained_state=retention.retained_state,
        retirement_generation=plan.retirement_generation,
        native_retirement_generation=native_retirement_generation,
        native_completion_observed=native_completion_observed,
        native_callback_detached=1,
        native_record_retained=1,
        native_command_status=native_command_status,
        native_error_domain_kind=native_error_domain_kind,
        native_error_code_bits=native_error_code_bits,
        plan_sha256=plan.plan_sha256,
        retention_sha256=retention.retention_sha256,
        async_ticket_sha256=retention.async_ticket_sha256,
        submission_sha256=retention.submission_sha256,
        backend_quarantine_sha256=(
            retention.backend_quarantine_sha256
        ),
        native_prepare_sha256=_digest(native_prepare_sha256),
        callback_snapshot_sha256=_digest(
            callback_snapshot_sha256
        ),
        backend_terminal_sha256=_digest(backend_terminal_sha256),
    )
    result = replace(
        result,
        fence_sha256=loss_dispatch_callback_fence_root_v1(result),
    )
    validate_loss_dispatch_callback_fence_v1(
        result,
        plan,
        retention,
    )
    return result


def validate_loss_dispatch_callback_fence_v1(
    value: LossDispatchCallbackFenceV1,
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
) -> None:
    try:
        validate_loss_dispatch_callback_retention_v1(retention)
        _validate_plan_fields(plan)
        _validate_fence_fields(value)
        plan_root_valid = (
            plan.plan_sha256 != ZERO_DIGEST
            and plan.plan_sha256
            == loss_dispatch_callback_retirement_plan_root_v1(plan)
        )
        fence_root_valid = (
            value.fence_sha256 != ZERO_DIGEST
            and value.fence_sha256
            == loss_dispatch_callback_fence_root_v1(value)
        )
    except (
        AttributeError,
        InvalidCallbackRetention,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidCallbackFence("nested evidence or encoding") from error

    if (
        plan.abi_version != PLAN_ABI
        or plan.retention_sha256 != retention.retention_sha256
        or not plan_root_valid
        or value.abi_version != FENCE_ABI
        or value.state != FENCE_DETACHED_PENDING_SETTLEMENT
        or value.retained_state != retention.retained_state
        or value.retirement_generation != plan.retirement_generation
        or value.native_retirement_generation in (0, U64_MAX)
        or value.native_completion_observed not in (0, 1)
        or value.native_callback_detached != 1
        or value.native_record_retained != 1
        or value.plan_sha256 != plan.plan_sha256
        or value.retention_sha256 != retention.retention_sha256
        or value.async_ticket_sha256 != retention.async_ticket_sha256
        or value.submission_sha256 != retention.submission_sha256
        or value.backend_quarantine_sha256
        != retention.backend_quarantine_sha256
        or value.native_prepare_sha256 == ZERO_DIGEST
        or value.backend_terminal_sha256 == ZERO_DIGEST
        or value.output_authority_sha256 != ZERO_DIGEST
        or not _fence_snapshot_shape_valid(value)
        or not fence_root_valid
    ):
        raise InvalidCallbackFence("shape or binding")


def validate_loss_dispatch_callback_fence_replay_v1(
    candidate: LossDispatchCallbackFenceV1,
    retained: LossDispatchCallbackFenceV1,
) -> None:
    if candidate != retained:
        raise InvalidCallbackFence("non-identical replay")


def loss_dispatch_callback_retirement_receipt_root_v1(
    value: LossDispatchCallbackRetirementReceiptV1,
) -> Digest:
    digest = hashlib.sha256()
    digest.update(RECEIPT_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.outcome,
        value.retained_state,
        value.source_sequence,
        value.retirement_generation,
        value.native_retirement_generation,
        value.released_dispatch_pin_count,
        value.retired_native_command_count,
        value.detached_native_callback_count,
    )
    for root in (
        value.plan_sha256,
        value.retention_sha256,
        value.callback_fence_sha256,
        value.dispatch_terminal_sha256,
        value.dispatch_completion_sha256,
        value.bank_completion_sha256,
        value.native_retirement_sha256,
        value.adapter_settlement_sha256,
        value.output_authority_sha256,
        value.migration_authority_sha256,
        value.reset_authority_sha256,
        value.physical_reclaim_authority_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_loss_dispatch_callback_retirement_receipt_v1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    fence: LossDispatchCallbackFenceV1,
    dispatch_terminal_sha256: Digest,
    dispatch_completion_sha256: Digest,
    bank_completion_sha256: Digest,
    native_retirement_sha256: Digest,
    adapter_settlement_sha256: Digest,
) -> LossDispatchCallbackRetirementReceiptV1:
    result = LossDispatchCallbackRetirementReceiptV1(
        source=plan.source,
        evidence_class=plan.evidence_class,
        retained_state=retention.retained_state,
        source_sequence=plan.source_sequence,
        retirement_generation=plan.retirement_generation,
        native_retirement_generation=(
            fence.native_retirement_generation
        ),
        released_dispatch_pin_count=1,
        retired_native_command_count=1,
        detached_native_callback_count=1,
        plan_sha256=plan.plan_sha256,
        retention_sha256=retention.retention_sha256,
        callback_fence_sha256=fence.fence_sha256,
        dispatch_terminal_sha256=_digest(
            dispatch_terminal_sha256
        ),
        dispatch_completion_sha256=_digest(
            dispatch_completion_sha256
        ),
        bank_completion_sha256=_digest(bank_completion_sha256),
        native_retirement_sha256=_digest(
            native_retirement_sha256
        ),
        adapter_settlement_sha256=_digest(
            adapter_settlement_sha256
        ),
    )
    result = replace(
        result,
        receipt_sha256=(
            loss_dispatch_callback_retirement_receipt_root_v1(result)
        ),
    )
    validate_loss_dispatch_callback_retirement_receipt_v1(
        result,
        plan,
        retention,
        fence,
    )
    return result


def validate_loss_dispatch_callback_retirement_receipt_v1(
    value: LossDispatchCallbackRetirementReceiptV1,
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    fence: LossDispatchCallbackFenceV1,
) -> None:
    try:
        validate_loss_dispatch_callback_fence_v1(
            fence,
            plan,
            retention,
        )
        _validate_receipt_fields(value)
        valid_root = (
            value.receipt_sha256 != ZERO_DIGEST
            and value.receipt_sha256
            == loss_dispatch_callback_retirement_receipt_root_v1(value)
        )
    except (
        AttributeError,
        InvalidCallbackFence,
        TypeError,
        ValueError,
    ) as error:
        raise InvalidCallbackRetirementReceipt(
            "nested evidence or encoding"
        ) from error

    required_roots = (
        value.dispatch_terminal_sha256,
        value.dispatch_completion_sha256,
        value.bank_completion_sha256,
        value.native_retirement_sha256,
        value.adapter_settlement_sha256,
    )
    if (
        value.abi_version != RECEIPT_ABI
        or value.source != plan.source
        or value.evidence_class != plan.evidence_class
        or value.outcome != OWNERSHIP_RETIRED_AFTER_DEVICE_LOSS
        or value.retained_state != retention.retained_state
        or value.source_sequence != plan.source_sequence
        or value.retirement_generation != plan.retirement_generation
        or value.native_retirement_generation
        != fence.native_retirement_generation
        or value.released_dispatch_pin_count != 1
        or value.retired_native_command_count != 1
        or value.detached_native_callback_count != 1
        or value.plan_sha256 != plan.plan_sha256
        or value.retention_sha256 != retention.retention_sha256
        or value.callback_fence_sha256 != fence.fence_sha256
        or any(root == ZERO_DIGEST for root in required_roots)
        or value.output_authority_sha256 != ZERO_DIGEST
        or value.migration_authority_sha256 != ZERO_DIGEST
        or value.reset_authority_sha256 != ZERO_DIGEST
        or value.physical_reclaim_authority_sha256 != ZERO_DIGEST
        or not valid_root
    ):
        raise InvalidCallbackRetirementReceipt("shape or binding")


def validate_loss_dispatch_callback_retirement_receipt_replay_v1(
    candidate: LossDispatchCallbackRetirementReceiptV1,
    retained: LossDispatchCallbackRetirementReceiptV1,
) -> None:
    if candidate != retained:
        raise InvalidCallbackRetirementReceipt("non-identical replay")


def replay_loss_dispatch_callback_retirement_trace_v1(
    events: Sequence[object],
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) -> LossDispatchCallbackRetirementReceiptV1:
    """Replay exactly retention → plan → fence → receipt once.

    Exact record replay is handled by the dedicated replay validators.  This
    trace represents the first committed transition, so duplicates, foreign
    records, reordered records, and events appended after the receipt fail
    closed.
    """

    expected_types = (
        LossDispatchCallbackRetentionV1,
        LossDispatchCallbackRetirementPlanV1,
        LossDispatchCallbackFenceV1,
        LossDispatchCallbackRetirementReceiptV1,
    )
    if len(events) != len(expected_types):
        raise InvalidCallbackRetirementTrace(
            "trace must contain exactly four events"
        )
    if any(
        type(event) is not expected
        for event, expected in zip(events, expected_types)
    ):
        raise InvalidCallbackRetirementTrace(
            "duplicate, foreign, or late event"
        )
    retention, plan, fence, receipt = events
    try:
        validate_loss_dispatch_callback_retention_v1(retention)
        validate_loss_dispatch_callback_retirement_plan_v1(
            plan,
            retention,
            observation,
            transition,
        )
        validate_loss_dispatch_callback_fence_v1(
            fence,
            plan,
            retention,
        )
        validate_loss_dispatch_callback_retirement_receipt_v1(
            receipt,
            plan,
            retention,
            fence,
        )
    except ContractError as error:
        raise InvalidCallbackRetirementTrace(
            "trace binding"
        ) from error
    return receipt


def make_deterministic_fixture_v1(
    retained_state: int,
    *,
    source: int = lifecycle.SOURCE_TEST_INJECTED,
    callback_exit_observed: int = 0,
) -> DeterministicCallbackRetirementFixtureV1:
    """Build one deterministic structural transcript for tests and reports."""

    if retained_state not in VALID_RETAINED_STATES:
        raise InvalidCallbackRetention("unknown retained state")
    capability = device.make_fixture_capability(
        device.BACKEND_METAL,
        device.DEVICE_ACCELERATOR,
        f"callback retirement fixture {retained_state}",
    )
    capability = device.seal_capability(
        replace(
            capability,
            feature_bits=(
                capability.feature_bits
                | device.FEATURE_DEVICE_LOSS_SIGNAL
            ),
            capability_sha256=ZERO_DIGEST,
        )
    )
    selected_entry = device.make_fixture_entry(
        capability,
        epoch=41,
        rank=2,
    )
    inventory = (selected_entry,)
    source_sequence = 19
    native_loss_fields = (
        (
            lifecycle.COMMAND_BUFFER_STATUS_ERROR,
            lifecycle.COMMAND_BUFFER_ERROR_DOMAIN,
            lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
        )
        if source == lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
        else (0, 0, 0)
    )
    observation = lifecycle.make_observation(
        selected_entry,
        inventory,
        _label("callback retirement lifecycle source"),
        source_sequence,
        source,
        _label(f"callback retirement evidence {source}"),
        *native_loss_fields,
    )
    cursor = lifecycle.SourceCursorV1(
        observation.source_instance_sha256,
        source_sequence - 1,
    )
    successor_entry = lifecycle.make_successor_entry(
        observation,
        selected_entry,
        inventory,
        cursor,
        42,
    )
    transition = lifecycle.make_transition_receipt(
        observation,
        selected_entry,
        inventory,
        successor_entry,
        cursor,
    )

    quarantine_sha256 = (
        ZERO_DIGEST
        if retained_state == RETAINED_PENDING
        else _label(
            f"callback retirement quarantine {retained_state}"
        )
    )
    retention = make_loss_dispatch_callback_retention_v1(
        retained_state,
        31,
        4,
        1_664,
        capability.capability_sha256,
        _label("callback retirement allocation lease"),
        _label("callback retirement allocation leaf set"),
        _label("callback retirement backend object set"),
        _label("callback retirement dispatch pin"),
        _label("callback retirement dispatch request"),
        _label("callback retirement async ticket"),
        _label("callback retirement submission"),
        quarantine_sha256,
        _label("callback retirement adapter challenge"),
    )
    plan = make_loss_dispatch_callback_retirement_plan_v1(
        observation,
        transition,
        retention,
        47,
    )

    if callback_exit_observed == 0:
        callback_snapshot_sha256 = ZERO_DIGEST
        current_status = 0
        current_domain = 0
        current_code = 0
    elif callback_exit_observed == 1:
        callback_snapshot_sha256 = _label(
            f"callback retirement callback snapshot {retained_state}"
        )
        current_status = 5
        current_domain = NATIVE_ERROR_COMMAND_BUFFER
        current_code = (
            lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        )
    else:
        raise InvalidCallbackFence("callback observation must be 0 or 1")

    fence = make_loss_dispatch_callback_fence_v1(
        plan,
        retention,
        53,
        _label("callback retirement native prepare"),
        _label("callback retirement backend terminal"),
        native_completion_observed=callback_exit_observed,
        native_command_status=current_status,
        native_error_domain_kind=current_domain,
        native_error_code_bits=current_code,
        callback_snapshot_sha256=callback_snapshot_sha256,
    )
    receipt = make_loss_dispatch_callback_retirement_receipt_v1(
        plan,
        retention,
        fence,
        _label("callback retirement dispatch terminal"),
        _label("callback retirement dispatch completion"),
        _label("callback retirement bank completion"),
        _label("callback retirement native retirement"),
        _label("callback retirement adapter settlement"),
    )
    replay_loss_dispatch_callback_retirement_trace_v1(
        (retention, plan, fence, receipt),
        observation,
        transition,
    )
    return DeterministicCallbackRetirementFixtureV1(
        observation,
        transition,
        retention,
        plan,
        fence,
        receipt,
    )


def deterministic_fixture_report_v1() -> dict[str, object]:
    cases: list[dict[str, object]] = []
    for retained_state in sorted(VALID_RETAINED_STATES):
        fixture = make_deterministic_fixture_v1(
            retained_state,
            callback_exit_observed=retained_state % 2,
        )
        cases.append(
            {
                "retained_state": retained_state,
                "callback_exit_observed": (
                    fixture.fence.native_completion_observed
                ),
                "retention_sha256": (
                    fixture.retention.retention_sha256.hex()
                ),
                "plan_sha256": fixture.plan.plan_sha256.hex(),
                "fence_sha256": fixture.fence.fence_sha256.hex(),
                "receipt_sha256": fixture.receipt.receipt_sha256.hex(),
            }
        )
    native_eligibility = {}
    for source in (
        lifecycle.SOURCE_REMOVED_NOTIFICATION,
        lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
        lifecycle.SOURCE_TEST_INJECTED,
    ):
        fixture = make_deterministic_fixture_v1(
            RETAINED_PENDING,
            source=source,
        )
        native_eligibility[str(source)] = (
            loss_dispatch_callback_retirement_plan_production_eligible_v1(
                fixture.plan,
                fixture.retention,
                fixture.observation,
                fixture.transition,
            )
        )
    report: dict[str, object] = {
        "schema": (
            "glacier.device-loss-dispatch-callback-retirement/v1"
        ),
        "retention_abi": f"{RETENTION_ABI:016x}",
        "plan_abi": f"{PLAN_ABI:016x}",
        "fence_abi": f"{FENCE_ABI:016x}",
        "receipt_abi": f"{RECEIPT_ABI:016x}",
        "retention_bytes": RETENTION_SIZE_BYTES,
        "plan_bytes": PLAN_SIZE_BYTES,
        "fence_bytes": FENCE_SIZE_BYTES,
        "receipt_bytes": RECEIPT_SIZE_BYTES,
        "case_count": len(cases),
        "cases": cases,
        "production_eligible_by_source": native_eligibility,
        "output_authority_count": 0,
        "migration_authority_count": 0,
        "reset_authority_count": 0,
        "physical_reclaim_authority_count": 0,
    }
    report["report_sha256"] = hashlib.sha256(
        json.dumps(
            report,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return report


def _retention_native_defaults(
    retained_state: int,
) -> tuple[int, int, int, int, int]:
    if retained_state == RETAINED_PENDING:
        return (NATIVE_SUBMITTED, 0, 0, NATIVE_ERROR_NONE, 0)
    if retained_state == RETAINED_SUBMISSION_AMBIGUOUS:
        return (
            NATIVE_COMMIT_STARTED,
            NATIVE_COMMAND_STATUS_UNOBSERVED,
            0,
            NATIVE_ERROR_BRIDGE,
            SUBMISSION_AMBIGUOUS_CODE,
        )
    if retained_state == RETAINED_COMPLETION_UNKNOWN:
        return (
            NATIVE_SUBMITTED,
            5,
            1,
            NATIVE_ERROR_BRIDGE,
            0x201,
        )
    if retained_state == RETAINED_INVALID_COMPLETION:
        return (
            NATIVE_TERMINAL_STATUS_OBSERVED,
            NATIVE_COMMAND_STATUS_COMPLETED,
            1,
            NATIVE_ERROR_COMPLETION_VALIDATION,
            0x301,
        )
    raise InvalidCallbackRetention("unknown retained state")


def _retention_shape_valid(
    value: LossDispatchCallbackRetentionV1,
) -> bool:
    if value.retained_state == RETAINED_PENDING:
        return (
            value.native_disposition == NATIVE_SUBMITTED
            and value.native_command_status == 0
            and value.native_completion_observed == 0
            and value.native_error_domain_kind == NATIVE_ERROR_NONE
            and value.native_error_code_bits == 0
            and value.backend_quarantine_sha256 == ZERO_DIGEST
        )
    if value.retained_state == RETAINED_SUBMISSION_AMBIGUOUS:
        return (
            value.native_disposition == NATIVE_COMMIT_STARTED
            and value.native_command_status
            == NATIVE_COMMAND_STATUS_UNOBSERVED
            and value.native_completion_observed == 0
            and value.native_error_domain_kind == NATIVE_ERROR_BRIDGE
            and value.native_error_code_bits
            == SUBMISSION_AMBIGUOUS_CODE
            and value.backend_quarantine_sha256 != ZERO_DIGEST
        )
    if value.retained_state == RETAINED_COMPLETION_UNKNOWN:
        return (
            value.native_disposition == NATIVE_SUBMITTED
            and value.native_completion_observed in (0, 1)
            and value.native_error_domain_kind == NATIVE_ERROR_BRIDGE
            and value.native_error_code_bits != 0
            and value.backend_quarantine_sha256 != ZERO_DIGEST
        )
    if value.retained_state == RETAINED_INVALID_COMPLETION:
        return (
            value.native_disposition
            == NATIVE_TERMINAL_STATUS_OBSERVED
            and value.native_command_status
            == NATIVE_COMMAND_STATUS_COMPLETED
            and value.native_completion_observed == 1
            and value.native_error_domain_kind
            == NATIVE_ERROR_COMPLETION_VALIDATION
            and value.native_error_code_bits != 0
            and value.backend_quarantine_sha256 != ZERO_DIGEST
        )
    return False


def _source_evidence_pair_valid(source: int, evidence_class: int) -> bool:
    if source in _PRODUCTION_SOURCES:
        return evidence_class == lifecycle.EVIDENCE_NATIVE
    if source == lifecycle.SOURCE_TEST_INJECTED:
        return evidence_class == lifecycle.EVIDENCE_SYNTHETIC
    return False


def _loss_evidence_valid(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    selected_capability_sha256: Digest,
) -> bool:
    try:
        observation_root_valid = (
            observation.observation_sha256 != ZERO_DIGEST
            and observation.observation_sha256
            == lifecycle.observation_root(observation)
        )
        transition_root_valid = (
            transition.receipt_sha256 != ZERO_DIGEST
            and transition.receipt_sha256
            == lifecycle.transition_receipt_root(transition)
        )
    except (AttributeError, TypeError, ValueError):
        return False
    return (
        observation.source in _STRUCTURAL_SOURCES
        and _source_evidence_pair_valid(
            observation.source,
            observation.evidence_class,
        )
        and observation.observed_state == device.INVENTORY_LOST
        and observation.source_sequence != 0
        and observation.source_instance_sha256 != ZERO_DIGEST
        and observation.capability_sha256
        == selected_capability_sha256
        and transition.source == observation.source
        and transition.evidence_class == observation.evidence_class
        and transition.prior_state == device.INVENTORY_PRESENT
        and transition.successor_state == device.INVENTORY_LOST
        and transition.source_sequence == observation.source_sequence
        and transition.capability_sha256
        == selected_capability_sha256
        and transition.observation_sha256
        == observation.observation_sha256
        and observation_root_valid
        and transition_root_valid
        and (
            _native_loss_shape_valid(observation)
            if observation.source in _PRODUCTION_SOURCES
            else (
                observation.native_command_status == 0
                and observation.native_error_domain_kind == 0
                and observation.native_error_code_bits == 0
            )
        )
    )


def _native_loss_shape_valid(
    observation: lifecycle.ObservationV1,
) -> bool:
    if observation.source == lifecycle.SOURCE_REMOVED_NOTIFICATION:
        return (
            observation.native_command_status == 0
            and observation.native_error_domain_kind == 0
            and observation.native_error_code_bits == 0
        )
    if (
        observation.source
        == lifecycle.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED
    ):
        return (
            observation.native_command_status
            == lifecycle.COMMAND_BUFFER_STATUS_ERROR
            and observation.native_error_domain_kind
            == lifecycle.COMMAND_BUFFER_ERROR_DOMAIN
            and observation.native_error_code_bits
            == lifecycle.COMMAND_BUFFER_DEVICE_REMOVED_ERROR
        )
    return False


def _fence_snapshot_shape_valid(
    value: LossDispatchCallbackFenceV1,
) -> bool:
    if value.native_completion_observed == 0:
        return (
            value.native_command_status == 0
            and value.native_error_domain_kind == NATIVE_ERROR_NONE
            and value.native_error_code_bits == 0
            and value.callback_snapshot_sha256 == ZERO_DIGEST
        )
    if value.native_completion_observed != 1:
        return False
    return (
        value.callback_snapshot_sha256 != ZERO_DIGEST
        and (
            (
                value.native_error_domain_kind == NATIVE_ERROR_NONE
                and value.native_error_code_bits == 0
            )
            or (
                value.native_error_domain_kind
                in (NATIVE_ERROR_COMMAND_BUFFER, NATIVE_ERROR_OTHER)
                and value.native_error_code_bits != 0
            )
        )
    )


def _validate_retention_fields(
    value: LossDispatchCallbackRetentionV1,
) -> None:
    _u64s(
        value.abi_version,
        value.retained_state,
        value.dispatch_generation,
        value.allocation_count,
        value.pinned_device_bytes,
        value.native_disposition,
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
        value.async_ticket_sha256,
        value.submission_sha256,
        value.backend_quarantine_sha256,
        value.adapter_challenge_sha256,
        value.output_authority_sha256,
        value.retention_sha256,
    ):
        _digest(root)


def _validate_plan_fields(
    value: LossDispatchCallbackRetirementPlanV1,
) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.successor_state,
        value.source_sequence,
        value.retirement_generation,
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


def _validate_fence_fields(value: LossDispatchCallbackFenceV1) -> None:
    _u64s(
        value.abi_version,
        value.state,
        value.retained_state,
        value.retirement_generation,
        value.native_retirement_generation,
        value.native_completion_observed,
        value.native_callback_detached,
        value.native_record_retained,
        value.native_command_status,
        value.native_error_domain_kind,
        value.native_error_code_bits,
    )
    for root in (
        value.plan_sha256,
        value.retention_sha256,
        value.async_ticket_sha256,
        value.submission_sha256,
        value.backend_quarantine_sha256,
        value.native_prepare_sha256,
        value.callback_snapshot_sha256,
        value.backend_terminal_sha256,
        value.output_authority_sha256,
        value.fence_sha256,
    ):
        _digest(root)


def _validate_receipt_fields(
    value: LossDispatchCallbackRetirementReceiptV1,
) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.outcome,
        value.retained_state,
        value.source_sequence,
        value.retirement_generation,
        value.native_retirement_generation,
        value.released_dispatch_pin_count,
        value.retired_native_command_count,
        value.detached_native_callback_count,
    )
    for root in (
        value.plan_sha256,
        value.retention_sha256,
        value.callback_fence_sha256,
        value.dispatch_terminal_sha256,
        value.dispatch_completion_sha256,
        value.bank_completion_sha256,
        value.native_retirement_sha256,
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


def _label(value: str) -> Digest:
    return hashlib.sha256(value.encode("utf-8")).digest()


if __name__ == "__main__":
    print(
        json.dumps(
            deterministic_fixture_report_v1(),
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
