"""Independent oracle for LeaseTree-backed device-allocation V1 evidence.

This module is standard-library-only apart from importing the existing
portable allocation-contract oracle.  It does not parse Zig sources or load
Glacier symbols.  ResourceBank's accidental-misuse checksums and the public
SHA-256 evidence transcripts are reproduced as separate algorithms.

``make_campaign`` follows one fixed additive LeaseTree through cancellation,
materialization, free-authorized recovery, settlement recovery, and release.
Its session identifier is a stable integer rather than a process address, so
all roots are reproducible across processes and languages.

``make_dispatch_campaign`` takes an independent branch from that campaign's
materialized lease through ordered allocation pinning, backend terminal
evidence, pin release, and pointer-free completion evidence.  Its outcome
parameter covers every core terminal shape while
``make_rejected_before_submit_dispatch_campaign`` names the zero-native-root
rejection branch explicitly.

``make_metal_matvec_pre_submit_rejection_campaign`` independently mirrors the
Metal INT4 attempt, replay-fenced request, and adapter-authorized rejection
transcripts.  The oracle uses fixed literals and does not parse the Zig
implementation, so shared self-hashing cannot hide field-order or width drift.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, replace
from typing import Optional, Sequence, Tuple

from bench import device_allocation_lease as allocation


Digest = bytes
ClaimV1 = allocation.ClaimV1
ResourceReceiptV1 = allocation.ResourceReceiptV1
AllocationRequestV1 = allocation.AllocationRequestV1
BackendObjectV1 = allocation.BackendObjectV1
BackendObjectSetV1 = allocation.BackendObjectSetV1
AllocationCallV1 = allocation.AllocationCallV1
ZERO_DIGEST = allocation.ZERO_DIGEST
U64_MAX = allocation.U64_MAX
U32_MAX = allocation.U32_MAX
MAXIMUM_ALLOCATIONS = allocation.MAXIMUM_ALLOCATIONS
ContractError = allocation.ContractError

LEASE_TREE_ABI = 0x4752_4C54_0000_0001
LEASE_NODE_ABI = 0x4752_4C4E_0000_0001
LEASE_ALLOCATION_BATCH_ABI = 0x4752_4C41_0000_0001
LEASE_FREE_PERMIT_ABI = 0x4752_4C46_0000_0001
LEASE_PIN_PERMIT_ABI = 0x4752_4C50_0000_0001
LEASE_PIN_COMPLETION_ABI = 0x4752_5043_0000_0001
MAXIMUM_LEASE_PIN_NODES = 64

ADMISSION_ABI = 0x4744_5441_0000_0001
LEASE_ABI = 0x4744_544C_0000_0001
RECOVERY_ABI = 0x4744_5452_0000_0001
TERMINAL_ABI = 0x4744_5454_0000_0001
DISPATCH_PIN_ABI = 0x4744_5450_0000_0001
DISPATCH_PIN_INTENT_ABI = 0x4744_5449_0000_0001
DISPATCH_TERMINAL_ABI = 0x4744_5444_0000_0001
DISPATCH_COMPLETION_ABI = 0x4744_5443_0000_0001
METAL_PRE_SUBMIT_ATTEMPT_ABI = 0x474D_5041_0000_0001
METAL_MATVEC_DISPATCH_REQUEST_ABI = 0x474D_4452_0000_0001
METAL_PRE_SUBMIT_REJECTION_ABI = 0x474D_5052_0000_0001

TREE_DOMAIN = b"glacier-resource-lease-tree-v1\x00"
NODE_DOMAIN = b"glacier-resource-lease-node-v1\x00"
BATCH_DOMAIN = b"glacier-resource-lease-allocation-batch-v1\x00"
PERMIT_DOMAIN = b"glacier-resource-lease-free-permit-v1\x00"
BANK_PIN_DOMAIN = b"glacier-resource-lease-pin-permit-v1\x00"
BANK_PIN_COMPLETION_DOMAIN = (
    b"glacier-resource-lease-pin-completion-v1\x00"
)
LEAF_SET_DOMAIN = b"glacier-device-tree-allocation-leaf-set-v1\x00"
PUBLICATION_BINDING_DOMAIN = (
    b"glacier-device-tree-publication-binding-v1\x00"
)
ADMISSION_DOMAIN = b"glacier-device-tree-allocation-admission-v1\x00"
LEASE_DOMAIN = b"glacier-device-tree-allocation-lease-v1\x00"
RECOVERY_DOMAIN = b"glacier-device-tree-allocation-recovery-v1\x00"
TERMINAL_DOMAIN = b"glacier-device-tree-allocation-terminal-v1\x00"
OUTSTANDING_SET_DOMAIN = (
    b"glacier-device-tree-allocation-outstanding-v1\x00"
)
NODE_KEY_DOMAIN = b"glacier-device-tree-allocation-node-key-v1\x00"
BINDING_KEY_DOMAIN = (
    b"glacier-device-tree-allocation-binding-key-v1\x00"
)
DISPATCH_PIN_DOMAIN = b"glacier-device-tree-dispatch-pin-v1\x00"
DISPATCH_PIN_INTENT_DOMAIN = (
    b"glacier-device-tree-dispatch-pin-intent-v1\x00"
)
DISPATCH_TERMINAL_DOMAIN = (
    b"glacier-device-tree-dispatch-terminal-v1\x00"
)
DISPATCH_COMPLETION_DOMAIN = (
    b"glacier-device-tree-dispatch-completion-v1\x00"
)
DISPATCH_OWNER_DOMAIN = b"glacier-device-tree-dispatch-owner-v1\x00"
DISPATCH_PUBLICATION_DOMAIN = (
    b"glacier-device-tree-dispatch-publication-v1\x00"
)
METAL_PRE_SUBMIT_ATTEMPT_DOMAIN = (
    b"glacier-metal-matvec-pre-submit-attempt-v1\x00"
)
METAL_MATVEC_DISPATCH_REQUEST_DOMAIN = (
    b"glacier-metal-matvec-dispatch-request-v1\x00"
)
METAL_PRE_SUBMIT_REJECTION_DOMAIN = (
    b"glacier-metal-matvec-pre-submit-rejection-v1\x00"
)

LEASE_TREE_INTEGRITY_DOMAIN = 0x6C65_6173_6574_7231
LEASE_TREE_STATE_DOMAIN = 0x6C65_6173_6573_7431
LEASE_NODE_INTEGRITY_DOMAIN = 0x6C65_6173_656E_6431
LEASE_PENDING_DOMAIN = 0x6C65_6173_6570_6431
LEASE_BATCH_INTEGRITY_DOMAIN = 0x6C65_6173_6562_6131
LEASE_FREE_INTEGRITY_DOMAIN = 0x6C65_6173_6566_7231
LEASE_PIN_STATE_DOMAIN = 0x6C65_6173_6570_7331
LEASE_PIN_MEMBER_DOMAIN = 0x6C65_6173_6570_6D31
LEASE_PIN_SLOT_DOMAIN = 0x6C65_6173_6570_6C31
LEASE_PIN_PERMIT_INTEGRITY_DOMAIN = 0x6C65_6173_6570_7031
LEASE_PIN_COMPLETION_INTEGRITY_DOMAIN = 0x6C65_6173_6570_6331

NODE_SCOPE = 0
NODE_ALLOCATION = 1

NODE_STATE_FREE = 0
NODE_STATE_LIVE = 1
NODE_STATE_RESERVED_UNMATERIALIZED = 2
NODE_STATE_QUIESCING = 3
NODE_STATE_FREE_AUTHORIZED = 4

PENDING_NONE = 0
PENDING_ALLOCATION = 1
PENDING_RETIRE = 2
PENDING_FREE = 3

PHASE_ROLLBACK_RESERVED = 1
PHASE_FREE_AUTHORIZED = 2
PHASE_SETTLEMENT_REQUIRED = 3

DISPATCH_SUCCEEDED = 1
DISPATCH_TERMINAL_FAILURE = 2
DISPATCH_CANCELLED_BEFORE_SUBMIT = 3
DISPATCH_CANCELLED_AFTER_SUBMIT = 4
DISPATCH_REJECTED_BEFORE_SUBMIT = 5
VALID_DISPATCH_OUTCOMES = frozenset(
    (
        DISPATCH_SUCCEEDED,
        DISPATCH_TERMINAL_FAILURE,
        DISPATCH_CANCELLED_BEFORE_SUBMIT,
        DISPATCH_CANCELLED_AFTER_SUBMIT,
        DISPATCH_REJECTED_BEFORE_SUBMIT,
    )
)

METAL_INVALID_GEOMETRY = 1
METAL_INVALID_HOST_LENGTHS = 2
METAL_INVALID_ROLE_BINDINGS = 3
METAL_INVALID_ROLE_MAPPING = 4
VALID_METAL_PRE_SUBMIT_REASONS = frozenset(
    (
        METAL_INVALID_GEOMETRY,
        METAL_INVALID_HOST_LENGTHS,
        METAL_INVALID_ROLE_BINDINGS,
        METAL_INVALID_ROLE_MAPPING,
    )
)

OUTCOME_CANCELLED = allocation.OUTCOME_CANCELLED
OUTCOME_ALLOCATION_FAILED = allocation.OUTCOME_ALLOCATION_FAILED
OUTCOME_RELEASED = allocation.OUTCOME_RELEASED
REASON_EXPLICIT_CANCELLATION = (
    allocation.REASON_EXPLICIT_CANCELLATION
)
REASON_BACKEND_ALLOCATION_FAILURE = (
    allocation.REASON_BACKEND_ALLOCATION_FAILURE
)
REASON_BACKEND_PROTOCOL_VIOLATION = (
    allocation.REASON_BACKEND_PROTOCOL_VIOLATION
)
REASON_NORMAL_RELEASE = allocation.REASON_NORMAL_RELEASE

# Fits both 32-bit and 64-bit usize while remaining nonzero and recognizable.
FIXED_SESSION_ID = 0x4754_5345
FIXED_PUBLICATION_SEQUENCE = 0
NO_LEASE_NODE = U32_MAX


@dataclass(frozen=True)
class LeaseTreeV1:
    abi_version: int = LEASE_TREE_ABI
    parent: Optional[ResourceReceiptV1] = None
    tree_key: int = 0
    authority_key: int = 0
    identity_generation: int = 0
    generation: int = 0
    structural_revision: int = 0
    ceiling: ClaimV1 = ClaimV1()
    current: ClaimV1 = ClaimV1()
    active_nodes: int = 0
    state_digest: int = 0
    integrity: int = 0


@dataclass(frozen=True)
class LeaseNodeV1:
    abi_version: int = LEASE_NODE_ABI
    parent: Optional[ResourceReceiptV1] = None
    tree_key: int = 0
    tree_identity_generation: int = 0
    node_index: int = 0
    generation: int = 0
    parent_index: int = NO_LEASE_NODE
    parent_generation: int = 0
    node_key: int = 0
    tenant_key: int = 0
    binding_key: int = 0
    kind: int = NODE_SCOPE
    ceiling: ClaimV1 = ClaimV1()
    claim: ClaimV1 = ClaimV1()
    integrity: int = 0


@dataclass(frozen=True)
class LeaseAllocationBatchV1:
    abi_version: int = LEASE_ALLOCATION_BATCH_ABI
    parent: Optional[ResourceReceiptV1] = None
    tree_key: int = 0
    tree_identity_generation: int = 0
    tree_generation: int = 0
    structural_revision: int = 0
    request_epoch: int = 0
    session_id: int = 0
    sequence: int = 0
    generation: int = 0
    completion_tree_generation: int = 0
    node_count: int = 0
    claim: ClaimV1 = ClaimV1()
    node_set_digest: int = 0
    integrity: int = 0


@dataclass(frozen=True)
class LeaseFreePermitV1:
    abi_version: int = LEASE_FREE_PERMIT_ABI
    parent: Optional[ResourceReceiptV1] = None
    tree_key: int = 0
    tree_identity_generation: int = 0
    tree_generation: int = 0
    structural_revision: int = 0
    request_epoch: int = 0
    session_id: int = 0
    sequence: int = 0
    generation: int = 0
    completion_tree_generation: int = 0
    scope_index: int = 0
    scope_generation: int = 0
    node_count: int = 0
    claim: ClaimV1 = ClaimV1()
    node_set_digest: int = 0
    integrity: int = 0


@dataclass(frozen=True)
class LeasePinMemberV1:
    node_index: int = NO_LEASE_NODE
    reserved: int = 0
    node_generation: int = 0
    node_integrity: int = 0


@dataclass(frozen=True)
class LeasePinSlotV1:
    active: bool = False
    receipt_slot_index: int = 0
    tree_key: int = 0
    tree_identity_generation: int = 0
    tree_generation: int = 0
    structural_revision: int = 0
    generation: int = 0
    completion_generation: int = 0
    request_epoch: int = 0
    session_id: int = 0
    sequence: int = 0
    owner_key: int = 0
    scope_index: int = NO_LEASE_NODE
    scope_generation: int = 0
    node_count: int = 0
    claim: ClaimV1 = ClaimV1()
    node_set_digest: int = 0
    integrity: int = 0
    members: Tuple[LeasePinMemberV1, ...] = ()


@dataclass(frozen=True)
class LeasePinPermitV1:
    abi_version: int = LEASE_PIN_PERMIT_ABI
    parent: Optional[ResourceReceiptV1] = None
    tree_key: int = 0
    tree_identity_generation: int = 0
    tree_generation: int = 0
    structural_revision: int = 0
    pin_slot_index: int = 0
    reserved: int = 0
    generation: int = 0
    completion_generation: int = 0
    request_epoch: int = 0
    session_id: int = 0
    sequence: int = 0
    owner_key: int = 0
    scope_index: int = 0
    scope_generation: int = 0
    node_count: int = 0
    claim: ClaimV1 = ClaimV1()
    node_set_digest: int = 0
    integrity: int = 0


@dataclass(frozen=True)
class LeasePinCompletionV1:
    abi_version: int = LEASE_PIN_COMPLETION_ABI
    parent: Optional[ResourceReceiptV1] = None
    tree_key: int = 0
    tree_identity_generation: int = 0
    pin_slot_index: int = 0
    reserved: int = 0
    permit_generation: int = 0
    completion_generation: int = 0
    request_epoch: int = 0
    session_id: int = 0
    sequence: int = 0
    owner_key: int = 0
    scope_index: int = 0
    scope_generation: int = 0
    node_count: int = 0
    claim: ClaimV1 = ClaimV1()
    node_set_digest: int = 0
    permit_integrity: int = 0
    completion_tree_generation: int = 0
    completion_structural_revision: int = 0
    completion_state_digest: int = 0
    completion_tree_integrity: int = 0
    integrity: int = 0


@dataclass(frozen=True)
class LeaseTreeAllocationAdmissionV1:
    abi_version: int = ADMISSION_ABI
    coordinator_epoch: int = 0
    generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    selection_receipt_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    allocation_manifest_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    reservation_tree: LeaseTreeV1 = LeaseTreeV1()
    scope: LeaseNodeV1 = LeaseNodeV1()
    allocation_batch_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    publication_binding_sha256: Digest = ZERO_DIGEST
    allocation_count: int = 0
    total_device_bytes: int = 0
    admission_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LeaseTreeDeviceAllocationLeaseV1:
    abi_version: int = LEASE_ABI
    coordinator_epoch: int = 0
    generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    selection_receipt_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    allocation_manifest_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    materialized_tree: LeaseTreeV1 = LeaseTreeV1()
    scope: LeaseNodeV1 = LeaseNodeV1()
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    allocation_count: int = 0
    materialized_bytes: int = 0
    lease_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LeaseTreeAllocationRecoveryV1:
    abi_version: int = RECOVERY_ABI
    phase: int = PHASE_ROLLBACK_RESERVED
    target_outcome: int = OUTCOME_CANCELLED
    target_reason: int = REASON_EXPLICIT_CANCELLATION
    coordinator_epoch: int = 0
    generation: int = 0
    recovery_generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    lease_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    bank_authority_sha256: Digest = ZERO_DIGEST
    total_device_bytes: int = 0
    outstanding_object_count: int = 0
    outstanding_bytes: int = 0
    outstanding_set_sha256: Digest = ZERO_DIGEST
    pending_tree: LeaseTreeV1 = LeaseTreeV1()
    scope: LeaseNodeV1 = LeaseNodeV1()
    recovery_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LeaseTreeAllocationTerminalReceiptV1:
    abi_version: int = TERMINAL_ABI
    outcome: int = OUTCOME_CANCELLED
    reason: int = REASON_EXPLICIT_CANCELLATION
    coordinator_epoch: int = 0
    generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    lease_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    allocation_batch_sha256: Digest = ZERO_DIGEST
    returned_device_bytes: int = 0
    terminal_tree: LeaseTreeV1 = LeaseTreeV1()
    scope: LeaseNodeV1 = LeaseNodeV1()
    terminal_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LeaseTreeDispatchPinV1:
    abi_version: int = DISPATCH_PIN_ABI
    coordinator_epoch: int = 0
    allocation_generation: int = 0
    dispatch_generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    dispatch_authority_sha256: Digest = ZERO_DIGEST
    queue_authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    lease_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    dispatch_request_sha256: Digest = ZERO_DIGEST
    publication_binding_sha256: Digest = ZERO_DIGEST
    bank_pin_sha256: Digest = ZERO_DIGEST
    pinned_tree: LeaseTreeV1 = LeaseTreeV1()
    scope: LeaseNodeV1 = LeaseNodeV1()
    allocation_count: int = 0
    pinned_device_bytes: int = 0
    pin_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DispatchPinIntentV1:
    abi_version: int = DISPATCH_PIN_INTENT_ABI
    coordinator_epoch: int = 0
    allocation_generation: int = 0
    dispatch_generation: int = 0
    allocation_count: int = 0
    pinned_device_bytes: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    dispatch_authority_sha256: Digest = ZERO_DIGEST
    queue_authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    lease_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    allocation_leaf_set_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    scope_sha256: Digest = ZERO_DIGEST
    dispatch_request_sha256: Digest = ZERO_DIGEST
    publication_binding_sha256: Digest = ZERO_DIGEST
    intent_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DispatchTerminalEvidenceV1:
    abi_version: int = DISPATCH_TERMINAL_ABI
    outcome: int = DISPATCH_REJECTED_BEFORE_SUBMIT
    dispatch_generation: int = 0
    dispatch_authority_sha256: Digest = ZERO_DIGEST
    queue_authority_sha256: Digest = ZERO_DIGEST
    pin_sha256: Digest = ZERO_DIGEST
    dispatch_request_sha256: Digest = ZERO_DIGEST
    submission_sha256: Digest = ZERO_DIGEST
    backend_completion_sha256: Digest = ZERO_DIGEST
    output_sha256: Digest = ZERO_DIGEST
    terminal_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class MetalMatvecAllocationBindingsV1:
    packed_weights_sha256: Digest = ZERO_DIGEST
    scales_sha256: Digest = ZERO_DIGEST
    input_sha256: Digest = ZERO_DIGEST
    output_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class MetalMatvecPreSubmitAttemptV1:
    abi_version: int = METAL_PRE_SUBMIT_ATTEMPT_ABI
    group_size: int = 0
    in_features: int = 0
    out_features: int = 0
    reserved: int = 0
    packed_weights_bytes: int = 0
    scales_count: int = 0
    input_count: int = 0
    output_count: int = 0
    bindings: MetalMatvecAllocationBindingsV1 = (
        MetalMatvecAllocationBindingsV1()
    )
    attempt_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class MetalMatvecDispatchRequestV1:
    abi_version: int = METAL_MATVEC_DISPATCH_REQUEST_ABI
    request_generation: int = 0
    dispatch_authority_sha256: Digest = ZERO_DIGEST
    queue_authority_sha256: Digest = ZERO_DIGEST
    attempt: MetalMatvecPreSubmitAttemptV1 = (
        MetalMatvecPreSubmitAttemptV1()
    )
    request_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class MetalMatvecPreSubmitRejectionV1:
    abi_version: int = METAL_PRE_SUBMIT_REJECTION_ABI
    reason: int = METAL_INVALID_GEOMETRY
    dispatch_generation: int = 0
    allocation_count: int = 0
    materialized_bytes: int = 0
    pin_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    request: MetalMatvecDispatchRequestV1 = (
        MetalMatvecDispatchRequestV1()
    )
    terminal_sha256: Digest = ZERO_DIGEST
    rejection_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class LeaseTreeDispatchCompletionV1:
    abi_version: int = DISPATCH_COMPLETION_ABI
    outcome: int = DISPATCH_REJECTED_BEFORE_SUBMIT
    coordinator_epoch: int = 0
    allocation_generation: int = 0
    dispatch_generation: int = 0
    pin_sha256: Digest = ZERO_DIGEST
    dispatch_terminal_sha256: Digest = ZERO_DIGEST
    submission_sha256: Digest = ZERO_DIGEST
    backend_completion_sha256: Digest = ZERO_DIGEST
    output_sha256: Digest = ZERO_DIGEST
    bank_completion_sha256: Digest = ZERO_DIGEST
    completion_publication_binding_sha256: Digest = ZERO_DIGEST
    completed_tree: LeaseTreeV1 = LeaseTreeV1()
    scope: LeaseNodeV1 = LeaseNodeV1()
    completion_sha256: Digest = ZERO_DIGEST


def _u64(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError("integer field is not an int")
    if value < 0 or value > U64_MAX:
        raise ContractError("integer field is outside u64")
    return value


def _u64s(*values: int) -> None:
    for value in values:
        _u64(value)


def _u32(value: int) -> int:
    _u64(value)
    if value > U32_MAX:
        raise ContractError("integer field is outside u32")
    return value


def _digest(value: Digest) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise ContractError("digest must contain exactly 32 bytes")
    return value


def _le(*values: int) -> bytes:
    _u64s(*values)
    return struct.pack("<" + "Q" * len(values), *values)


def _le32(*values: int) -> bytes:
    for value in values:
        _u32(value)
    return struct.pack("<" + "I" * len(values), *values)


def _hash(domain: bytes, chunks: Sequence[bytes]) -> Digest:
    transcript = hashlib.sha256()
    transcript.update(domain)
    for chunk in chunks:
        transcript.update(chunk)
    return transcript.digest()


def _claim_bytes(claim: ClaimV1) -> bytes:
    return _le(*claim.values())


def _claim_is_zero(claim: ClaimV1) -> bool:
    return all(value == 0 for value in claim.values())


def _claim_within(claim: ClaimV1, ceiling: ClaimV1) -> bool:
    return all(
        value <= bound
        for value, bound in zip(claim.values(), ceiling.values())
    )


def _claim_is_device_only(claim: ClaimV1) -> bool:
    return (
        claim.device_bytes != 0
        and all(
            value == 0
            for index, value in enumerate(claim.values())
            if index != 7
        )
    )


def _add_claims(left: ClaimV1, right: ClaimV1) -> ClaimV1:
    values = []
    for left_value, right_value in zip(left.values(), right.values()):
        result = left_value + right_value
        if result > U64_MAX:
            raise allocation.ArithmeticOverflow("claim addition overflow")
        values.append(result)
    return ClaimV1(*values)


def _mix64(value: int) -> int:
    value &= U64_MAX
    value ^= value >> 30
    value = (value * 0xBF58_476D_1CE4_E5B9) & U64_MAX
    value ^= value >> 27
    value = (value * 0x94D0_49BB_1331_11EB) & U64_MAX
    value ^= value >> 31
    return value & U64_MAX


def _lease_tree_integrity(value: LeaseTreeV1) -> int:
    if value.parent is None:
        raise ContractError("LeaseTree parent is missing")
    allocation.validate_resource_receipt(value.parent)
    result = _mix64(
        LEASE_TREE_INTEGRITY_DOMAIN ^ value.parent.integrity
    )
    for scalar in (
        value.tree_key,
        value.authority_key,
        value.identity_generation,
        value.generation,
        value.structural_revision,
    ) + value.ceiling.values() + value.current.values() + (
        value.active_nodes,
        value.state_digest,
    ):
        result = _mix64(result ^ _u64(scalar))
    return result


def seal_lease_tree(value: LeaseTreeV1) -> LeaseTreeV1:
    if value.integrity != 0:
        raise ContractError("LeaseTree is already sealed")
    result = replace(value, abi_version=LEASE_TREE_ABI)
    result = replace(result, integrity=_lease_tree_integrity(result))
    validate_lease_tree(result)
    return result


def validate_lease_tree(value: LeaseTreeV1) -> None:
    if value.parent is None:
        raise ContractError("LeaseTree parent is missing")
    allocation.validate_resource_receipt(value.parent)
    _u32(value.active_nodes)
    _u64s(
        value.abi_version,
        value.tree_key,
        value.authority_key,
        value.identity_generation,
        value.generation,
        value.structural_revision,
        value.state_digest,
        value.integrity,
        *value.ceiling.values(),
        *value.current.values(),
    )
    if (
        value.abi_version != LEASE_TREE_ABI
        or value.integrity != _lease_tree_integrity(value)
    ):
        raise ContractError("invalid LeaseTree")


def _lease_node_integrity(value: LeaseNodeV1) -> int:
    if value.parent is None:
        raise ContractError("LeaseNode parent is missing")
    allocation.validate_resource_receipt(value.parent)
    result = _mix64(
        LEASE_NODE_INTEGRITY_DOMAIN ^ value.parent.integrity
    )
    for scalar in (
        value.tree_key,
        value.tree_identity_generation,
        value.node_index,
        value.generation,
        value.parent_index,
        value.parent_generation,
        value.node_key,
        value.tenant_key,
        value.binding_key,
        value.kind,
    ) + value.ceiling.values() + value.claim.values():
        result = _mix64(result ^ _u64(scalar))
    return result


def seal_lease_node(value: LeaseNodeV1) -> LeaseNodeV1:
    if value.integrity != 0:
        raise ContractError("LeaseNode is already sealed")
    result = replace(value, abi_version=LEASE_NODE_ABI)
    result = replace(result, integrity=_lease_node_integrity(result))
    validate_lease_node(result)
    return result


def validate_lease_node(value: LeaseNodeV1) -> None:
    if value.parent is None:
        raise ContractError("LeaseNode parent is missing")
    allocation.validate_resource_receipt(value.parent)
    _u32(value.node_index)
    _u32(value.parent_index)
    _u64s(
        value.abi_version,
        value.tree_key,
        value.tree_identity_generation,
        value.generation,
        value.parent_generation,
        value.node_key,
        value.tenant_key,
        value.binding_key,
        value.kind,
        value.integrity,
        *value.ceiling.values(),
        *value.claim.values(),
    )
    if (
        value.abi_version != LEASE_NODE_ABI
        or value.kind not in (NODE_SCOPE, NODE_ALLOCATION)
        or value.integrity != _lease_node_integrity(value)
    ):
        raise ContractError("invalid LeaseNode")


def _lease_batch_integrity(value: LeaseAllocationBatchV1) -> int:
    if value.parent is None:
        raise ContractError("allocation batch parent is missing")
    allocation.validate_resource_receipt(value.parent)
    result = _mix64(
        LEASE_BATCH_INTEGRITY_DOMAIN ^ value.parent.integrity
    )
    for scalar in (
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.generation,
        value.completion_tree_generation,
        value.node_count,
    ) + value.claim.values() + (value.node_set_digest,):
        result = _mix64(result ^ _u64(scalar))
    return result


def seal_lease_allocation_batch(
    value: LeaseAllocationBatchV1,
) -> LeaseAllocationBatchV1:
    if value.integrity != 0:
        raise ContractError("allocation batch is already sealed")
    result = replace(value, abi_version=LEASE_ALLOCATION_BATCH_ABI)
    result = replace(result, integrity=_lease_batch_integrity(result))
    validate_lease_allocation_batch(result)
    return result


def validate_lease_allocation_batch(
    value: LeaseAllocationBatchV1,
) -> None:
    if value.parent is None:
        raise ContractError("allocation batch parent is missing")
    allocation.validate_resource_receipt(value.parent)
    _u32(value.node_count)
    _u64s(
        value.abi_version,
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.generation,
        value.completion_tree_generation,
        value.node_set_digest,
        value.integrity,
        *value.claim.values(),
    )
    if (
        value.abi_version != LEASE_ALLOCATION_BATCH_ABI
        or value.tree_key == 0
        or value.tree_identity_generation == 0
        or value.tree_generation == 0
        or value.structural_revision == 0
        or value.request_epoch == 0
        or value.session_id == 0
        or value.generation == 0
        or value.completion_tree_generation == 0
        or value.node_count == 0
        or _claim_is_zero(value.claim)
        or value.integrity != _lease_batch_integrity(value)
    ):
        raise ContractError("invalid LeaseTree allocation batch")


def _lease_free_permit_integrity(value: LeaseFreePermitV1) -> int:
    if value.parent is None:
        raise ContractError("free permit parent is missing")
    allocation.validate_resource_receipt(value.parent)
    result = _mix64(
        LEASE_FREE_INTEGRITY_DOMAIN ^ value.parent.integrity
    )
    for scalar in (
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.generation,
        value.completion_tree_generation,
        value.scope_index,
        value.scope_generation,
        value.node_count,
    ) + value.claim.values() + (value.node_set_digest,):
        result = _mix64(result ^ _u64(scalar))
    return result


def seal_lease_free_permit(
    value: LeaseFreePermitV1,
) -> LeaseFreePermitV1:
    if value.integrity != 0:
        raise ContractError("free permit is already sealed")
    result = replace(value, abi_version=LEASE_FREE_PERMIT_ABI)
    result = replace(
        result, integrity=_lease_free_permit_integrity(result)
    )
    validate_lease_free_permit(result)
    return result


def validate_lease_free_permit(value: LeaseFreePermitV1) -> None:
    if value.parent is None:
        raise ContractError("free permit parent is missing")
    allocation.validate_resource_receipt(value.parent)
    _u32(value.scope_index)
    _u32(value.node_count)
    _u64s(
        value.abi_version,
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.generation,
        value.completion_tree_generation,
        value.scope_generation,
        value.node_set_digest,
        value.integrity,
        *value.claim.values(),
    )
    if (
        value.abi_version != LEASE_FREE_PERMIT_ABI
        or value.tree_key == 0
        or value.tree_identity_generation == 0
        or value.tree_generation == 0
        or value.structural_revision == 0
        or value.request_epoch == 0
        or value.session_id == 0
        or value.generation == 0
        or value.completion_tree_generation == 0
        or value.scope_generation == 0
        or value.node_count == 0
        or _claim_is_zero(value.claim)
        or value.integrity != _lease_free_permit_integrity(value)
    ):
        raise ContractError("invalid LeaseTree free permit")


def lease_pin_node_set_digest_v1(
    tree_key: int,
    tree_identity_generation: int,
    scope_index: int,
    scope_generation: int,
    members: Sequence[LeasePinMemberV1],
) -> int:
    _u32(scope_index)
    _u64s(
        tree_key,
        tree_identity_generation,
        scope_generation,
    )
    if (
        tree_key == 0
        or tree_identity_generation == 0
        or scope_index == NO_LEASE_NODE
        or scope_generation == 0
        or len(members) == 0
        or len(members) > MAXIMUM_LEASE_PIN_NODES
    ):
        raise ContractError("invalid LeaseTree pin member set")
    result = _mix64(LEASE_PIN_MEMBER_DOMAIN ^ tree_key)
    for scalar in (
        tree_identity_generation,
        scope_index,
        scope_generation,
        len(members),
    ):
        result = _mix64(result ^ scalar)
    seen = set()
    for ordinal, member in enumerate(members):
        _u32(member.node_index)
        _u32(member.reserved)
        _u64s(member.node_generation, member.node_integrity)
        identity = (member.node_index, member.node_generation)
        if (
            member.node_index == NO_LEASE_NODE
            or member.reserved != 0
            or member.node_generation == 0
            or member.node_integrity == 0
            or identity in seen
        ):
            raise ContractError("invalid LeaseTree pin member")
        seen.add(identity)
        for scalar in (
            ordinal,
            member.node_index,
            member.reserved,
            member.node_generation,
            member.node_integrity,
        ):
            result = _mix64(result ^ scalar)
    return result


def _lease_pin_slot_integrity(
    parent: ResourceReceiptV1,
    pin_slot_index: int,
    value: LeasePinSlotV1,
) -> int:
    allocation.validate_resource_receipt(parent)
    _u32(pin_slot_index)
    _u32(value.receipt_slot_index)
    _u32(value.scope_index)
    _u32(value.node_count)
    _u64s(
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_generation,
        value.node_set_digest,
        *value.claim.values(),
    )
    if value.node_count != len(value.members):
        raise ContractError("pin slot member count mismatch")
    result = _mix64(
        LEASE_PIN_SLOT_DOMAIN ^ parent.integrity
    )
    for scalar in (
        int(value.active),
        pin_slot_index,
        value.receipt_slot_index,
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_index,
        value.scope_generation,
        value.node_count,
    ) + value.claim.values() + (value.node_set_digest,):
        result = _mix64(result ^ scalar)
    for ordinal, member in enumerate(value.members):
        for scalar in (
            ordinal,
            member.node_index,
            member.reserved,
            member.node_generation,
            member.node_integrity,
        ):
            result = _mix64(result ^ scalar)
    return result


def seal_lease_pin_slot(
    parent: ResourceReceiptV1,
    pin_slot_index: int,
    value: LeasePinSlotV1,
) -> LeasePinSlotV1:
    if value.integrity != 0:
        raise ContractError("LeaseTree pin slot is already sealed")
    result = replace(
        value,
        integrity=_lease_pin_slot_integrity(
            parent,
            pin_slot_index,
            value,
        ),
    )
    validate_lease_pin_slot(parent, pin_slot_index, result)
    return result


def validate_lease_pin_slot(
    parent: ResourceReceiptV1,
    pin_slot_index: int,
    value: LeasePinSlotV1,
) -> None:
    allocation.validate_resource_receipt(parent)
    _u32(pin_slot_index)
    _u32(value.receipt_slot_index)
    _u32(value.scope_index)
    _u32(value.node_count)
    _u64s(
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_generation,
        value.node_set_digest,
        value.integrity,
        *value.claim.values(),
    )
    if (
        not value.active
        or pin_slot_index == NO_LEASE_NODE
        or value.receipt_slot_index != parent.slot_index
        or value.tree_key == 0
        or value.tree_identity_generation == 0
        or value.tree_generation == 0
        or value.structural_revision == 0
        or value.generation == 0
        or value.generation > U64_MAX - 2
        or value.tree_generation != value.generation + 1
        or value.completion_generation != value.generation + 2
        or value.request_epoch == 0
        or value.session_id == 0
        or value.owner_key == 0
        or value.scope_index == NO_LEASE_NODE
        or value.scope_generation == 0
        or value.node_count == 0
        or value.node_count > MAXIMUM_LEASE_PIN_NODES
        or value.node_count != len(value.members)
        or len({member.node_index for member in value.members})
        != value.node_count
        or _claim_is_zero(value.claim)
        or value.node_set_digest == 0
        or value.node_set_digest
        != lease_pin_node_set_digest_v1(
            value.tree_key,
            value.tree_identity_generation,
            value.scope_index,
            value.scope_generation,
            value.members,
        )
        or value.integrity
        != _lease_pin_slot_integrity(
            parent,
            pin_slot_index,
            value,
        )
    ):
        raise ContractError("invalid LeaseTree pin slot")


def _lease_pin_permit_integrity(
    value: LeasePinPermitV1,
) -> int:
    if value.parent is None:
        raise ContractError("pin permit parent is missing")
    allocation.validate_resource_receipt(value.parent)
    result = _mix64(
        LEASE_PIN_PERMIT_INTEGRITY_DOMAIN
        ^ value.parent.integrity
    )
    for scalar in (
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.pin_slot_index,
        value.reserved,
        value.generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_index,
        value.scope_generation,
        value.node_count,
    ) + value.claim.values() + (value.node_set_digest,):
        result = _mix64(result ^ _u64(scalar))
    return result


def seal_lease_pin_permit(
    value: LeasePinPermitV1,
) -> LeasePinPermitV1:
    if value.integrity != 0:
        raise ContractError("pin permit is already sealed")
    result = replace(value, abi_version=LEASE_PIN_PERMIT_ABI)
    result = replace(
        result,
        integrity=_lease_pin_permit_integrity(result),
    )
    validate_lease_pin_permit(result)
    return result


def validate_lease_pin_permit(
    value: LeasePinPermitV1,
) -> None:
    if value.parent is None:
        raise ContractError("pin permit parent is missing")
    allocation.validate_resource_receipt(value.parent)
    _u32(value.pin_slot_index)
    _u32(value.reserved)
    _u32(value.scope_index)
    _u32(value.node_count)
    _u64s(
        value.abi_version,
        value.tree_key,
        value.tree_identity_generation,
        value.tree_generation,
        value.structural_revision,
        value.generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_generation,
        value.node_set_digest,
        value.integrity,
        *value.claim.values(),
    )
    if (
        value.abi_version != LEASE_PIN_PERMIT_ABI
        or value.tree_key == 0
        or value.tree_identity_generation == 0
        or value.tree_generation == 0
        or value.structural_revision == 0
        or value.pin_slot_index == NO_LEASE_NODE
        or value.reserved != 0
        or value.generation == 0
        or value.generation > U64_MAX - 2
        or value.tree_generation != value.generation + 1
        or value.completion_generation != value.generation + 2
        or value.request_epoch == 0
        or value.session_id == 0
        or value.owner_key == 0
        or value.scope_index == NO_LEASE_NODE
        or value.scope_generation == 0
        or value.node_count == 0
        or value.node_count > MAXIMUM_LEASE_PIN_NODES
        or _claim_is_zero(value.claim)
        or value.node_set_digest == 0
        or value.integrity != _lease_pin_permit_integrity(value)
    ):
        raise ContractError("invalid LeaseTree pin permit")


def _lease_pin_completion_integrity(
    value: LeasePinCompletionV1,
) -> int:
    if value.parent is None:
        raise ContractError("pin completion parent is missing")
    allocation.validate_resource_receipt(value.parent)
    result = _mix64(
        LEASE_PIN_COMPLETION_INTEGRITY_DOMAIN
        ^ value.parent.integrity
    )
    for scalar in (
        value.tree_key,
        value.tree_identity_generation,
        value.pin_slot_index,
        value.reserved,
        value.permit_generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_index,
        value.scope_generation,
        value.node_count,
    ) + value.claim.values() + (
        value.node_set_digest,
        value.permit_integrity,
        value.completion_tree_generation,
        value.completion_structural_revision,
        value.completion_state_digest,
        value.completion_tree_integrity,
    ):
        result = _mix64(result ^ _u64(scalar))
    return result


def seal_lease_pin_completion(
    value: LeasePinCompletionV1,
) -> LeasePinCompletionV1:
    if value.integrity != 0:
        raise ContractError("pin completion is already sealed")
    result = replace(value, abi_version=LEASE_PIN_COMPLETION_ABI)
    result = replace(
        result,
        integrity=_lease_pin_completion_integrity(result),
    )
    validate_lease_pin_completion(result)
    return result


def validate_lease_pin_completion(
    value: LeasePinCompletionV1,
) -> None:
    if value.parent is None:
        raise ContractError("pin completion parent is missing")
    allocation.validate_resource_receipt(value.parent)
    _u32(value.pin_slot_index)
    _u32(value.reserved)
    _u32(value.scope_index)
    _u32(value.node_count)
    _u64s(
        value.abi_version,
        value.tree_key,
        value.tree_identity_generation,
        value.permit_generation,
        value.completion_generation,
        value.request_epoch,
        value.session_id,
        value.sequence,
        value.owner_key,
        value.scope_generation,
        value.node_set_digest,
        value.permit_integrity,
        value.completion_tree_generation,
        value.completion_structural_revision,
        value.completion_state_digest,
        value.completion_tree_integrity,
        value.integrity,
        *value.claim.values(),
    )
    if (
        value.abi_version != LEASE_PIN_COMPLETION_ABI
        or value.tree_key == 0
        or value.tree_identity_generation == 0
        or value.pin_slot_index == NO_LEASE_NODE
        or value.reserved != 0
        or value.permit_generation == 0
        or value.permit_generation > U64_MAX - 2
        or value.completion_generation
        != value.permit_generation + 2
        or value.request_epoch == 0
        or value.session_id == 0
        or value.owner_key == 0
        or value.scope_index == NO_LEASE_NODE
        or value.scope_generation == 0
        or value.node_count == 0
        or value.node_count > MAXIMUM_LEASE_PIN_NODES
        or _claim_is_zero(value.claim)
        or value.node_set_digest == 0
        or value.permit_integrity == 0
        or value.completion_tree_generation == 0
        or value.completion_tree_generation
        <= value.completion_generation
        or value.completion_structural_revision == 0
        or value.completion_state_digest == 0
        or value.completion_tree_integrity == 0
        or value.integrity
        != _lease_pin_completion_integrity(value)
    ):
        raise ContractError("invalid LeaseTree pin completion")


def lease_tree_sha256_v1(value: LeaseTreeV1) -> Digest:
    if value.parent is None:
        raise ContractError("LeaseTree parent is missing")
    return _hash(
        TREE_DOMAIN,
        (
            _le(value.abi_version),
            allocation.resource_receipt_root(value.parent),
            _le(
                value.tree_key,
                value.authority_key,
                value.identity_generation,
                value.generation,
                value.structural_revision,
            ),
            _claim_bytes(value.ceiling),
            _claim_bytes(value.current),
            _le(value.active_nodes, value.state_digest, value.integrity),
        ),
    )


def lease_node_sha256_v1(value: LeaseNodeV1) -> Digest:
    if value.parent is None:
        raise ContractError("LeaseNode parent is missing")
    return _hash(
        NODE_DOMAIN,
        (
            _le(value.abi_version),
            allocation.resource_receipt_root(value.parent),
            _le(
                value.tree_key,
                value.tree_identity_generation,
                value.node_index,
                value.generation,
                value.parent_index,
                value.parent_generation,
                value.node_key,
                value.tenant_key,
                value.binding_key,
                value.kind,
            ),
            _claim_bytes(value.ceiling),
            _claim_bytes(value.claim),
            _le(value.integrity),
        ),
    )


def lease_allocation_batch_sha256_v1(
    value: LeaseAllocationBatchV1,
) -> Digest:
    if value.parent is None:
        raise ContractError("allocation batch parent is missing")
    return _hash(
        BATCH_DOMAIN,
        (
            _le(value.abi_version),
            allocation.resource_receipt_root(value.parent),
            _le(
                value.tree_key,
                value.tree_identity_generation,
                value.tree_generation,
                value.structural_revision,
                value.request_epoch,
                value.session_id,
                value.sequence,
                value.generation,
                value.completion_tree_generation,
                value.node_count,
            ),
            _claim_bytes(value.claim),
            _le(value.node_set_digest, value.integrity),
        ),
    )


def lease_free_permit_sha256_v1(
    value: LeaseFreePermitV1,
) -> Digest:
    if value.parent is None:
        raise ContractError("free permit parent is missing")
    return _hash(
        PERMIT_DOMAIN,
        (
            _le(value.abi_version),
            allocation.resource_receipt_root(value.parent),
            _le(
                value.tree_key,
                value.tree_identity_generation,
                value.tree_generation,
                value.structural_revision,
                value.request_epoch,
                value.session_id,
                value.sequence,
                value.generation,
                value.completion_tree_generation,
                value.scope_index,
                value.scope_generation,
                value.node_count,
            ),
            _claim_bytes(value.claim),
            _le(value.node_set_digest, value.integrity),
        ),
    )


def lease_pin_permit_sha256_v1(
    value: LeasePinPermitV1,
) -> Digest:
    if value.parent is None:
        raise ContractError("pin permit parent is missing")
    return _hash(
        BANK_PIN_DOMAIN,
        (
            _le(value.abi_version),
            allocation.resource_receipt_root(value.parent),
            _le(
                value.tree_key,
                value.tree_identity_generation,
                value.tree_generation,
                value.structural_revision,
                value.pin_slot_index,
                value.reserved,
                value.generation,
                value.completion_generation,
                value.request_epoch,
                value.session_id,
                value.sequence,
                value.owner_key,
                value.scope_index,
                value.scope_generation,
                value.node_count,
            ),
            _claim_bytes(value.claim),
            _le(value.node_set_digest, value.integrity),
        ),
    )


def lease_pin_completion_sha256_v1(
    value: LeasePinCompletionV1,
) -> Digest:
    if value.parent is None:
        raise ContractError("pin completion parent is missing")
    return _hash(
        BANK_PIN_COMPLETION_DOMAIN,
        (
            _le(value.abi_version),
            allocation.resource_receipt_root(value.parent),
            _le(
                value.tree_key,
                value.tree_identity_generation,
                value.pin_slot_index,
                value.reserved,
                value.permit_generation,
                value.completion_generation,
                value.request_epoch,
                value.session_id,
                value.sequence,
                value.owner_key,
                value.scope_index,
                value.scope_generation,
                value.node_count,
            ),
            _claim_bytes(value.claim),
            _le(
                value.node_set_digest,
                value.permit_integrity,
                value.completion_tree_generation,
                value.completion_structural_revision,
                value.completion_state_digest,
                value.completion_tree_integrity,
                value.integrity,
            ),
        ),
    )


def allocation_leaf_set_sha256_v1(
    leaves: Sequence[LeaseNodeV1],
) -> Digest:
    chunks = [_le(len(leaves))]
    chunks.extend(lease_node_sha256_v1(leaf) for leaf in leaves)
    return _hash(LEAF_SET_DOMAIN, chunks)


def publication_binding_sha256_v1(
    batch: LeaseAllocationBatchV1,
) -> Digest:
    if batch.parent is None:
        raise ContractError("allocation batch parent is missing")
    return _hash(
        PUBLICATION_BINDING_DOMAIN,
        (
            allocation.resource_receipt_root(batch.parent),
            _le(batch.request_epoch, batch.session_id, batch.sequence),
        ),
    )


def allocation_key_v1(
    domain: bytes,
    coordinator_epoch: int,
    generation: int,
    ordinal: int,
    binding_sha256: Digest,
) -> int:
    root = _hash(
        domain,
        (
            _le(coordinator_epoch, generation, ordinal),
            _digest(binding_sha256),
        ),
    )
    value = struct.unpack("<Q", root[:8])[0]
    return 1 if value == 0 else value


def allocation_node_key_v1(
    coordinator_epoch: int,
    generation: int,
    ordinal: int,
    binding_sha256: Digest,
) -> int:
    return allocation_key_v1(
        NODE_KEY_DOMAIN,
        coordinator_epoch,
        generation,
        ordinal,
        binding_sha256,
    )


def allocation_binding_key_v1(
    coordinator_epoch: int,
    generation: int,
    ordinal: int,
    binding_sha256: Digest,
) -> int:
    return allocation_key_v1(
        BINDING_KEY_DOMAIN,
        coordinator_epoch,
        generation,
        ordinal,
        binding_sha256,
    )


def _tree_scope_binding_valid(
    tree: LeaseTreeV1,
    scope: LeaseNodeV1,
    parent_receipt_sha256: Digest,
) -> bool:
    try:
        validate_lease_tree(tree)
        validate_lease_node(scope)
    except ContractError:
        return False
    return (
        tree.tree_key != 0
        and tree.authority_key != 0
        and tree.identity_generation != 0
        and tree.generation > tree.identity_generation
        and tree.structural_revision != 0
        and tree.active_nodes != 0
        and not _claim_is_zero(tree.ceiling)
        and _claim_within(tree.current, tree.ceiling)
        and scope.parent == tree.parent
        and scope.tree_key == tree.tree_key
        and scope.tree_identity_generation == tree.identity_generation
        and scope.node_index != U32_MAX
        and scope.generation != 0
        and scope.parent_index == U32_MAX
        and scope.parent_generation == tree.identity_generation
        and scope.node_key != 0
        and scope.tenant_key != 0
        and scope.kind == NODE_SCOPE
        and scope.binding_key == 0
        and _claim_is_zero(scope.claim)
        and _claim_is_device_only(scope.ceiling)
        and _claim_within(scope.ceiling, tree.ceiling)
        and tree.parent is not None
        and parent_receipt_sha256
        == allocation.resource_receipt_root(tree.parent)
    )


def admission_root_v1(
    value: LeaseTreeAllocationAdmissionV1,
) -> Digest:
    return _hash(
        ADMISSION_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.request_sha256),
            _digest(value.selection_receipt_sha256),
            _digest(value.selected_capability_sha256),
            _digest(value.allocation_manifest_sha256),
            _digest(value.parent_receipt_sha256),
            lease_tree_sha256_v1(value.reservation_tree),
            lease_node_sha256_v1(value.scope),
            _digest(value.allocation_batch_sha256),
            _digest(value.allocation_leaf_set_sha256),
            _digest(value.publication_binding_sha256),
            _le(value.allocation_count, value.total_device_bytes),
        ),
    )


def make_admission_v1(
    coordinator_epoch: int,
    generation: int,
    authority: allocation.AllocationAuthorityV1,
    request: AllocationRequestV1,
    reservation_tree: LeaseTreeV1,
    scope: LeaseNodeV1,
    batch: LeaseAllocationBatchV1,
    leaves: Sequence[LeaseNodeV1],
) -> LeaseTreeAllocationAdmissionV1:
    allocation.validate_authority(authority)
    validate_lease_tree(reservation_tree)
    validate_lease_node(scope)
    validate_lease_allocation_batch(batch)
    if (
        request.authority_sha256 != authority.authority_sha256
        or request.parent_receipt_sha256
        != (
            allocation.resource_receipt_root(reservation_tree.parent)
            if reservation_tree.parent is not None
            else ZERO_DIGEST
        )
        or batch.parent != reservation_tree.parent
        or batch.tree_key != reservation_tree.tree_key
        or batch.tree_identity_generation
        != reservation_tree.identity_generation
        or batch.tree_generation != reservation_tree.generation
        or batch.structural_revision
        != reservation_tree.structural_revision
        or batch.request_epoch != request.request_epoch
        or batch.node_count != len(leaves)
        or batch.claim.device_bytes != request.total_device_bytes
        or len(leaves) != request.allocation_count
    ):
        raise ContractError("invalid admission composition")
    aggregate = ClaimV1()
    for leaf in leaves:
        validate_lease_node(leaf)
        if (
            leaf.parent != reservation_tree.parent
            or leaf.tree_key != reservation_tree.tree_key
            or leaf.tree_identity_generation
            != reservation_tree.identity_generation
            or leaf.parent_index != scope.node_index
            or leaf.parent_generation != scope.generation
            or leaf.tenant_key != scope.tenant_key
            or leaf.kind != NODE_ALLOCATION
            or leaf.binding_key == 0
            or leaf.claim != leaf.ceiling
        ):
            raise ContractError("invalid allocation leaf composition")
        aggregate = _add_claims(aggregate, leaf.claim)
    if aggregate != batch.claim:
        raise ContractError("allocation leaf claim mismatch")
    result = LeaseTreeAllocationAdmissionV1(
        coordinator_epoch=coordinator_epoch,
        generation=generation,
        authority_sha256=authority.authority_sha256,
        request_sha256=request.request_sha256,
        selection_receipt_sha256=request.selection_receipt_sha256,
        selected_capability_sha256=request.selected_capability_sha256,
        allocation_manifest_sha256=request.allocation_manifest_sha256,
        parent_receipt_sha256=request.parent_receipt_sha256,
        reservation_tree=reservation_tree,
        scope=scope,
        allocation_batch_sha256=lease_allocation_batch_sha256_v1(
            batch
        ),
        allocation_leaf_set_sha256=allocation_leaf_set_sha256_v1(
            leaves
        ),
        publication_binding_sha256=publication_binding_sha256_v1(
            batch
        ),
        allocation_count=request.allocation_count,
        total_device_bytes=request.total_device_bytes,
    )
    result = replace(result, admission_sha256=admission_root_v1(result))
    validate_admission_v1(result)
    return result


def validate_admission_v1(
    value: LeaseTreeAllocationAdmissionV1,
) -> None:
    _u64s(
        value.abi_version,
        value.coordinator_epoch,
        value.generation,
        value.allocation_count,
        value.total_device_bytes,
    )
    roots = (
        value.authority_sha256,
        value.request_sha256,
        value.selection_receipt_sha256,
        value.selected_capability_sha256,
        value.allocation_manifest_sha256,
        value.parent_receipt_sha256,
        value.allocation_batch_sha256,
        value.allocation_leaf_set_sha256,
        value.publication_binding_sha256,
        value.admission_sha256,
    )
    for root in roots:
        _digest(root)
    validate_lease_tree(value.reservation_tree)
    if (
        value.abi_version != ADMISSION_ABI
        or value.coordinator_epoch == 0
        or value.generation == 0
        or any(root == ZERO_DIGEST for root in roots)
        or not _tree_scope_binding_valid(
            value.reservation_tree,
            value.scope,
            value.parent_receipt_sha256,
        )
        or value.allocation_count == 0
        or value.allocation_count > MAXIMUM_ALLOCATIONS
        or value.total_device_bytes == 0
        or value.total_device_bytes < value.allocation_count
        or value.total_device_bytes != value.scope.ceiling.device_bytes
        or value.reservation_tree.active_nodes
        < value.allocation_count + 1
        or value.reservation_tree.current.device_bytes
        < value.total_device_bytes
        or value.admission_sha256 != admission_root_v1(value)
    ):
        raise ContractError("invalid LeaseTree allocation admission")


def lease_root_v1(value: LeaseTreeDeviceAllocationLeaseV1) -> Digest:
    return _hash(
        LEASE_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.request_sha256),
            _digest(value.admission_sha256),
            _digest(value.selection_receipt_sha256),
            _digest(value.selected_capability_sha256),
            _digest(value.allocation_manifest_sha256),
            _digest(value.parent_receipt_sha256),
            lease_tree_sha256_v1(value.materialized_tree),
            lease_node_sha256_v1(value.scope),
            _digest(value.allocation_leaf_set_sha256),
            _digest(value.backend_object_set_sha256),
            _le(value.allocation_count, value.materialized_bytes),
        ),
    )


def make_lease_v1(
    admission: LeaseTreeAllocationAdmissionV1,
    request: AllocationRequestV1,
    object_set: BackendObjectSetV1,
    materialized_tree: LeaseTreeV1,
) -> LeaseTreeDeviceAllocationLeaseV1:
    validate_admission_v1(admission)
    validate_lease_tree(materialized_tree)
    if (
        admission.request_sha256 != request.request_sha256
        or object_set.admission_sha256 != admission.admission_sha256
        or object_set.allocation_count != admission.allocation_count
        or object_set.total_allocated_bytes
        != admission.total_device_bytes
    ):
        raise ContractError("invalid LeaseTree lease composition")
    result = LeaseTreeDeviceAllocationLeaseV1(
        coordinator_epoch=admission.coordinator_epoch,
        generation=admission.generation,
        authority_sha256=admission.authority_sha256,
        request_sha256=request.request_sha256,
        admission_sha256=admission.admission_sha256,
        selection_receipt_sha256=admission.selection_receipt_sha256,
        selected_capability_sha256=(
            admission.selected_capability_sha256
        ),
        allocation_manifest_sha256=(
            admission.allocation_manifest_sha256
        ),
        parent_receipt_sha256=admission.parent_receipt_sha256,
        materialized_tree=materialized_tree,
        scope=admission.scope,
        allocation_leaf_set_sha256=(
            admission.allocation_leaf_set_sha256
        ),
        backend_object_set_sha256=object_set.object_set_sha256,
        allocation_count=object_set.allocation_count,
        materialized_bytes=object_set.total_allocated_bytes,
    )
    result = replace(result, lease_sha256=lease_root_v1(result))
    validate_lease_v1(result)
    return result


def validate_lease_v1(value: LeaseTreeDeviceAllocationLeaseV1) -> None:
    _u64s(
        value.abi_version,
        value.coordinator_epoch,
        value.generation,
        value.allocation_count,
        value.materialized_bytes,
    )
    roots = (
        value.authority_sha256,
        value.request_sha256,
        value.admission_sha256,
        value.selection_receipt_sha256,
        value.selected_capability_sha256,
        value.allocation_manifest_sha256,
        value.parent_receipt_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.lease_sha256,
    )
    for root in roots:
        _digest(root)
    validate_lease_tree(value.materialized_tree)
    if (
        value.abi_version != LEASE_ABI
        or value.coordinator_epoch == 0
        or value.generation == 0
        or any(root == ZERO_DIGEST for root in roots)
        or not _tree_scope_binding_valid(
            value.materialized_tree,
            value.scope,
            value.parent_receipt_sha256,
        )
        or value.allocation_count == 0
        or value.allocation_count > MAXIMUM_ALLOCATIONS
        or value.materialized_bytes == 0
        or value.materialized_bytes < value.allocation_count
        or value.materialized_bytes != value.scope.ceiling.device_bytes
        or value.materialized_tree.active_nodes
        < value.allocation_count + 1
        or value.materialized_tree.current.device_bytes
        < value.materialized_bytes
        or value.lease_sha256 != lease_root_v1(value)
    ):
        raise ContractError("invalid LeaseTree device allocation lease")


def outstanding_set_sha256_v1(
    coordinator_epoch: int,
    generation: int,
    outstanding: Sequence[Tuple[int, BackendObjectV1]],
) -> Digest:
    if not outstanding:
        return ZERO_DIGEST
    chunks = [_le(coordinator_epoch, generation)]
    prior = None
    for ordinal, item in outstanding:
        _u64(ordinal)
        _digest(item.object_sha256)
        if prior is not None and ordinal <= prior:
            raise ContractError("outstanding objects are not ordinal ordered")
        prior = ordinal
        chunks.extend(
            (
                _le(ordinal),
                allocation.backend_object_root(item),
                item.object_sha256,
            )
        )
    return _hash(OUTSTANDING_SET_DOMAIN, chunks)


def _terminal_pair_valid(outcome: int, reason: int) -> bool:
    return (
        outcome == OUTCOME_CANCELLED
        and reason == REASON_EXPLICIT_CANCELLATION
    ) or (
        outcome == OUTCOME_ALLOCATION_FAILED
        and reason
        in (
            REASON_BACKEND_ALLOCATION_FAILURE,
            REASON_BACKEND_PROTOCOL_VIOLATION,
        )
    ) or (
        outcome == OUTCOME_RELEASED and reason == REASON_NORMAL_RELEASE
    )


def _recovery_phase_pair_valid(
    phase: int,
    outcome: int,
    outstanding_object_count: int,
) -> bool:
    return (
        phase == PHASE_ROLLBACK_RESERVED
        and outcome != OUTCOME_RELEASED
    ) or (
        phase == PHASE_FREE_AUTHORIZED
        and outcome == OUTCOME_RELEASED
        and outstanding_object_count != 0
    ) or (
        phase == PHASE_SETTLEMENT_REQUIRED
        and outcome == OUTCOME_RELEASED
        and outstanding_object_count == 0
    )


def recovery_root_v1(
    value: LeaseTreeAllocationRecoveryV1,
) -> Digest:
    return _hash(
        RECOVERY_DOMAIN,
        (
            _le(
                value.abi_version,
                value.phase,
                value.target_outcome,
                value.target_reason,
                value.coordinator_epoch,
                value.generation,
                value.recovery_generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.admission_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.lease_sha256),
            _digest(value.backend_object_set_sha256),
            _digest(value.bank_authority_sha256),
            _le(
                value.total_device_bytes,
                value.outstanding_object_count,
                value.outstanding_bytes,
            ),
            _digest(value.outstanding_set_sha256),
            lease_tree_sha256_v1(value.pending_tree),
            lease_node_sha256_v1(value.scope),
        ),
    )


def make_recovery_v1(
    phase: int,
    recovery_generation: int,
    admission: LeaseTreeAllocationAdmissionV1,
    pending_tree: LeaseTreeV1,
    bank_authority_sha256: Digest,
    target_outcome: int,
    target_reason: int,
    outstanding: Sequence[Tuple[int, BackendObjectV1]],
    lease: Optional[LeaseTreeDeviceAllocationLeaseV1] = None,
) -> LeaseTreeAllocationRecoveryV1:
    validate_admission_v1(admission)
    validate_lease_tree(pending_tree)
    _digest(bank_authority_sha256)
    if target_outcome == OUTCOME_RELEASED:
        if lease is None:
            raise ContractError("released recovery requires a lease")
        validate_lease_v1(lease)
        lease_sha256 = lease.lease_sha256
        object_set_sha256 = lease.backend_object_set_sha256
    else:
        if lease is not None:
            raise ContractError("rollback recovery cannot bind a lease")
        lease_sha256 = ZERO_DIGEST
        object_set_sha256 = ZERO_DIGEST
    outstanding_bytes = 0
    for _, item in outstanding:
        outstanding_bytes += item.allocated_bytes
        if outstanding_bytes > U64_MAX:
            raise allocation.ArithmeticOverflow(
                "outstanding byte sum overflow"
            )
    result = LeaseTreeAllocationRecoveryV1(
        phase=phase,
        target_outcome=target_outcome,
        target_reason=target_reason,
        coordinator_epoch=admission.coordinator_epoch,
        generation=admission.generation,
        recovery_generation=recovery_generation,
        authority_sha256=admission.authority_sha256,
        admission_sha256=admission.admission_sha256,
        parent_receipt_sha256=admission.parent_receipt_sha256,
        lease_sha256=lease_sha256,
        backend_object_set_sha256=object_set_sha256,
        bank_authority_sha256=bank_authority_sha256,
        total_device_bytes=admission.total_device_bytes,
        outstanding_object_count=len(outstanding),
        outstanding_bytes=outstanding_bytes,
        outstanding_set_sha256=outstanding_set_sha256_v1(
            admission.coordinator_epoch,
            admission.generation,
            outstanding,
        ),
        pending_tree=pending_tree,
        scope=admission.scope,
    )
    result = replace(result, recovery_sha256=recovery_root_v1(result))
    validate_recovery_v1(result)
    return result


def validate_recovery_v1(
    value: LeaseTreeAllocationRecoveryV1,
) -> None:
    _u64s(
        value.abi_version,
        value.phase,
        value.target_outcome,
        value.target_reason,
        value.coordinator_epoch,
        value.generation,
        value.recovery_generation,
        value.total_device_bytes,
        value.outstanding_object_count,
        value.outstanding_bytes,
    )
    roots = (
        value.authority_sha256,
        value.admission_sha256,
        value.parent_receipt_sha256,
        value.lease_sha256,
        value.backend_object_set_sha256,
        value.bank_authority_sha256,
        value.outstanding_set_sha256,
        value.recovery_sha256,
    )
    for root in roots:
        _digest(root)
    validate_lease_tree(value.pending_tree)
    released = value.target_outcome == OUTCOME_RELEASED
    if (
        value.abi_version != RECOVERY_ABI
        or value.phase
        not in (
            PHASE_ROLLBACK_RESERVED,
            PHASE_FREE_AUTHORIZED,
            PHASE_SETTLEMENT_REQUIRED,
        )
        or not _recovery_phase_pair_valid(
            value.phase,
            value.target_outcome,
            value.outstanding_object_count,
        )
        or not _terminal_pair_valid(
            value.target_outcome, value.target_reason
        )
        or value.coordinator_epoch == 0
        or value.generation == 0
        or value.recovery_generation == 0
        or value.authority_sha256 == ZERO_DIGEST
        or value.admission_sha256 == ZERO_DIGEST
        or value.parent_receipt_sha256 == ZERO_DIGEST
        or value.bank_authority_sha256 == ZERO_DIGEST
        or value.total_device_bytes == 0
        or value.outstanding_object_count > MAXIMUM_ALLOCATIONS
        or released != (value.lease_sha256 != ZERO_DIGEST)
        or released
        != (value.backend_object_set_sha256 != ZERO_DIGEST)
        or (value.outstanding_object_count == 0)
        != (value.outstanding_set_sha256 == ZERO_DIGEST)
        or (
            value.outstanding_object_count == 0
            and value.outstanding_bytes != 0
        )
        or (
            value.outstanding_object_count != 0
            and value.outstanding_bytes == 0
        )
        or value.outstanding_bytes < value.outstanding_object_count
        or not _tree_scope_binding_valid(
            value.pending_tree,
            value.scope,
            value.parent_receipt_sha256,
        )
        or value.total_device_bytes != value.scope.ceiling.device_bytes
        or value.pending_tree.active_nodes
        < max(value.outstanding_object_count + 1, 2)
        or value.pending_tree.current.device_bytes
        < value.total_device_bytes
        or value.outstanding_bytes > value.total_device_bytes
        or value.recovery_sha256 == ZERO_DIGEST
        or value.recovery_sha256 != recovery_root_v1(value)
    ):
        raise ContractError("invalid LeaseTree allocation recovery")


def terminal_root_v1(
    value: LeaseTreeAllocationTerminalReceiptV1,
) -> Digest:
    return _hash(
        TERMINAL_DOMAIN,
        (
            _le(
                value.abi_version,
                value.outcome,
                value.reason,
                value.coordinator_epoch,
                value.generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.request_sha256),
            _digest(value.admission_sha256),
            _digest(value.lease_sha256),
            _digest(value.backend_object_set_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.allocation_batch_sha256),
            _le(value.returned_device_bytes),
            lease_tree_sha256_v1(value.terminal_tree),
            lease_node_sha256_v1(value.scope),
        ),
    )


def make_terminal_v1(
    outcome: int,
    reason: int,
    admission: LeaseTreeAllocationAdmissionV1,
    request: AllocationRequestV1,
    terminal_tree: LeaseTreeV1,
    lease: Optional[LeaseTreeDeviceAllocationLeaseV1] = None,
) -> LeaseTreeAllocationTerminalReceiptV1:
    validate_admission_v1(admission)
    validate_lease_tree(terminal_tree)
    if outcome == OUTCOME_RELEASED:
        if lease is None:
            raise ContractError("released terminal requires a lease")
        validate_lease_v1(lease)
        lease_sha256 = lease.lease_sha256
        object_set_sha256 = lease.backend_object_set_sha256
    else:
        if lease is not None:
            raise ContractError("rollback terminal cannot bind a lease")
        lease_sha256 = ZERO_DIGEST
        object_set_sha256 = ZERO_DIGEST
    result = LeaseTreeAllocationTerminalReceiptV1(
        outcome=outcome,
        reason=reason,
        coordinator_epoch=admission.coordinator_epoch,
        generation=admission.generation,
        authority_sha256=admission.authority_sha256,
        request_sha256=request.request_sha256,
        admission_sha256=admission.admission_sha256,
        lease_sha256=lease_sha256,
        backend_object_set_sha256=object_set_sha256,
        parent_receipt_sha256=admission.parent_receipt_sha256,
        allocation_batch_sha256=admission.allocation_batch_sha256,
        returned_device_bytes=admission.total_device_bytes,
        terminal_tree=terminal_tree,
        scope=admission.scope,
    )
    result = replace(result, terminal_sha256=terminal_root_v1(result))
    validate_terminal_v1(result)
    return result


def validate_terminal_v1(
    value: LeaseTreeAllocationTerminalReceiptV1,
) -> None:
    _u64s(
        value.abi_version,
        value.outcome,
        value.reason,
        value.coordinator_epoch,
        value.generation,
        value.returned_device_bytes,
    )
    roots = (
        value.authority_sha256,
        value.request_sha256,
        value.admission_sha256,
        value.lease_sha256,
        value.backend_object_set_sha256,
        value.parent_receipt_sha256,
        value.allocation_batch_sha256,
        value.terminal_sha256,
    )
    for root in roots:
        _digest(root)
    validate_lease_tree(value.terminal_tree)
    released = value.outcome == OUTCOME_RELEASED
    if (
        value.abi_version != TERMINAL_ABI
        or not _terminal_pair_valid(value.outcome, value.reason)
        or value.coordinator_epoch == 0
        or value.generation == 0
        or value.authority_sha256 == ZERO_DIGEST
        or value.request_sha256 == ZERO_DIGEST
        or value.admission_sha256 == ZERO_DIGEST
        or value.parent_receipt_sha256 == ZERO_DIGEST
        or value.allocation_batch_sha256 == ZERO_DIGEST
        or value.returned_device_bytes == 0
        or released != (value.lease_sha256 != ZERO_DIGEST)
        or released
        != (value.backend_object_set_sha256 != ZERO_DIGEST)
        or not _tree_scope_binding_valid(
            value.terminal_tree,
            value.scope,
            value.parent_receipt_sha256,
        )
        or value.returned_device_bytes
        != value.scope.ceiling.device_bytes
        or value.terminal_tree.current.device_bytes
        + value.returned_device_bytes
        > value.terminal_tree.ceiling.device_bytes
        or (
            not _claim_is_zero(value.terminal_tree.current)
            and value.terminal_tree.active_nodes < 3
        )
        or value.terminal_sha256 == ZERO_DIGEST
        or value.terminal_sha256 != terminal_root_v1(value)
    ):
        raise ContractError("invalid LeaseTree allocation terminal")


def dispatch_owner_key_v1(
    coordinator_epoch: int,
    allocation_generation: int,
    dispatch_generation: int,
    dispatch_request_sha256: Digest,
) -> int:
    root = _hash(
        DISPATCH_OWNER_DOMAIN,
        (
            _le(
                coordinator_epoch,
                allocation_generation,
                dispatch_generation,
            ),
            _digest(dispatch_request_sha256),
        ),
    )
    value = struct.unpack("<Q", root[:8])[0]
    return 1 if value == 0 else value


def dispatch_publication_binding_sha256_v1(
    parent: ResourceReceiptV1,
    request_epoch: int,
    session_id: int,
    sequence: int,
) -> Digest:
    allocation.validate_resource_receipt(parent)
    return _hash(
        DISPATCH_PUBLICATION_DOMAIN,
        (
            allocation.resource_receipt_root(parent),
            _le(request_epoch, session_id, sequence),
        ),
    )


def dispatch_pin_root_v1(
    value: LeaseTreeDispatchPinV1,
) -> Digest:
    return _hash(
        DISPATCH_PIN_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.allocation_generation,
                value.dispatch_generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.dispatch_authority_sha256),
            _digest(value.queue_authority_sha256),
            _digest(value.request_sha256),
            _digest(value.admission_sha256),
            _digest(value.lease_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.allocation_leaf_set_sha256),
            _digest(value.backend_object_set_sha256),
            _digest(value.dispatch_request_sha256),
            _digest(value.publication_binding_sha256),
            _digest(value.bank_pin_sha256),
            lease_tree_sha256_v1(value.pinned_tree),
            lease_node_sha256_v1(value.scope),
            _le(value.allocation_count, value.pinned_device_bytes),
        ),
    )


def dispatch_pin_intent_root_v1(
    value: DispatchPinIntentV1,
) -> Digest:
    return _hash(
        DISPATCH_PIN_INTENT_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.allocation_generation,
                value.dispatch_generation,
                value.allocation_count,
                value.pinned_device_bytes,
            ),
            _digest(value.authority_sha256),
            _digest(value.dispatch_authority_sha256),
            _digest(value.queue_authority_sha256),
            _digest(value.request_sha256),
            _digest(value.admission_sha256),
            _digest(value.lease_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.allocation_leaf_set_sha256),
            _digest(value.backend_object_set_sha256),
            _digest(value.scope_sha256),
            _digest(value.dispatch_request_sha256),
            _digest(value.publication_binding_sha256),
        ),
    )


def make_dispatch_pin_intent_v1(
    *,
    coordinator_epoch: int,
    allocation_generation: int,
    dispatch_generation: int,
    allocation_count: int,
    pinned_device_bytes: int,
    authority_sha256: Digest,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    request_sha256: Digest,
    admission_sha256: Digest,
    lease_sha256: Digest,
    parent_receipt_sha256: Digest,
    allocation_leaf_set_sha256: Digest,
    backend_object_set_sha256: Digest,
    scope_sha256: Digest,
    dispatch_request_sha256: Digest,
    publication_binding_sha256: Digest,
) -> DispatchPinIntentV1:
    """Seal the pre-Bank reservation transcript from prepared inputs."""

    result = DispatchPinIntentV1(
        coordinator_epoch=coordinator_epoch,
        allocation_generation=allocation_generation,
        dispatch_generation=dispatch_generation,
        allocation_count=allocation_count,
        pinned_device_bytes=pinned_device_bytes,
        authority_sha256=_digest(authority_sha256),
        dispatch_authority_sha256=_digest(
            dispatch_authority_sha256
        ),
        queue_authority_sha256=_digest(queue_authority_sha256),
        request_sha256=_digest(request_sha256),
        admission_sha256=_digest(admission_sha256),
        lease_sha256=_digest(lease_sha256),
        parent_receipt_sha256=_digest(parent_receipt_sha256),
        allocation_leaf_set_sha256=_digest(
            allocation_leaf_set_sha256
        ),
        backend_object_set_sha256=_digest(
            backend_object_set_sha256
        ),
        scope_sha256=_digest(scope_sha256),
        dispatch_request_sha256=_digest(
            dispatch_request_sha256
        ),
        publication_binding_sha256=_digest(
            publication_binding_sha256
        ),
    )
    result = replace(
        result,
        intent_sha256=dispatch_pin_intent_root_v1(result),
    )
    validate_dispatch_pin_intent_v1(result)
    return result


def validate_dispatch_pin_intent_v1(
    value: DispatchPinIntentV1,
) -> None:
    _u64s(
        value.abi_version,
        value.coordinator_epoch,
        value.allocation_generation,
        value.dispatch_generation,
        value.allocation_count,
        value.pinned_device_bytes,
    )
    roots = (
        value.authority_sha256,
        value.dispatch_authority_sha256,
        value.queue_authority_sha256,
        value.request_sha256,
        value.admission_sha256,
        value.lease_sha256,
        value.parent_receipt_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.scope_sha256,
        value.dispatch_request_sha256,
        value.publication_binding_sha256,
        value.intent_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        value.abi_version != DISPATCH_PIN_INTENT_ABI
        or value.coordinator_epoch == 0
        or value.allocation_generation == 0
        or value.dispatch_generation == 0
        or value.allocation_count == 0
        or value.allocation_count > MAXIMUM_ALLOCATIONS
        or value.pinned_device_bytes < value.allocation_count
        or any(root == ZERO_DIGEST for root in roots)
        or value.dispatch_authority_sha256
        == value.queue_authority_sha256
        or value.intent_sha256
        != dispatch_pin_intent_root_v1(value)
    ):
        raise ContractError("invalid dispatch pin intent")


def validate_dispatch_pin_for_intent_v1(
    pin: LeaseTreeDispatchPinV1,
    intent: DispatchPinIntentV1,
) -> None:
    validate_dispatch_pin_v1(pin)
    validate_dispatch_pin_intent_v1(intent)
    if (
        pin.coordinator_epoch != intent.coordinator_epoch
        or pin.allocation_generation
        != intent.allocation_generation
        or pin.dispatch_generation != intent.dispatch_generation
        or pin.allocation_count != intent.allocation_count
        or pin.pinned_device_bytes != intent.pinned_device_bytes
        or pin.authority_sha256 != intent.authority_sha256
        or pin.dispatch_authority_sha256
        != intent.dispatch_authority_sha256
        or pin.queue_authority_sha256
        != intent.queue_authority_sha256
        or pin.request_sha256 != intent.request_sha256
        or pin.admission_sha256 != intent.admission_sha256
        or pin.lease_sha256 != intent.lease_sha256
        or pin.parent_receipt_sha256
        != intent.parent_receipt_sha256
        or pin.allocation_leaf_set_sha256
        != intent.allocation_leaf_set_sha256
        or pin.backend_object_set_sha256
        != intent.backend_object_set_sha256
        or lease_node_sha256_v1(pin.scope) != intent.scope_sha256
        or pin.dispatch_request_sha256
        != intent.dispatch_request_sha256
        or pin.publication_binding_sha256
        != intent.publication_binding_sha256
    ):
        raise ContractError("dispatch pin does not bind intent")


def validate_dispatch_pin_v1(
    value: LeaseTreeDispatchPinV1,
) -> None:
    _u64s(
        value.abi_version,
        value.coordinator_epoch,
        value.allocation_generation,
        value.dispatch_generation,
        value.allocation_count,
        value.pinned_device_bytes,
    )
    roots = (
        value.authority_sha256,
        value.dispatch_authority_sha256,
        value.queue_authority_sha256,
        value.request_sha256,
        value.admission_sha256,
        value.lease_sha256,
        value.parent_receipt_sha256,
        value.allocation_leaf_set_sha256,
        value.backend_object_set_sha256,
        value.dispatch_request_sha256,
        value.publication_binding_sha256,
        value.bank_pin_sha256,
        value.pin_sha256,
    )
    for root in roots:
        _digest(root)
    validate_lease_tree(value.pinned_tree)
    if (
        value.abi_version != DISPATCH_PIN_ABI
        or value.coordinator_epoch == 0
        or value.allocation_generation == 0
        or value.dispatch_generation == 0
        or any(root == ZERO_DIGEST for root in roots)
        or value.dispatch_authority_sha256
        == value.queue_authority_sha256
        or not _tree_scope_binding_valid(
            value.pinned_tree,
            value.scope,
            value.parent_receipt_sha256,
        )
        or value.allocation_count == 0
        or value.allocation_count > MAXIMUM_ALLOCATIONS
        or value.pinned_device_bytes == 0
        or value.pinned_device_bytes < value.allocation_count
        or value.pinned_device_bytes
        != value.scope.ceiling.device_bytes
        or value.pinned_tree.active_nodes
        < value.allocation_count + 1
        or value.pinned_tree.current.device_bytes
        < value.pinned_device_bytes
        or value.pin_sha256 != dispatch_pin_root_v1(value)
    ):
        raise ContractError("invalid LeaseTree dispatch pin")


def _dispatch_terminal_root_pair_valid(
    outcome: int,
    submission_sha256: Digest,
    backend_completion_sha256: Digest,
    output_sha256: Digest,
) -> bool:
    if outcome == DISPATCH_SUCCEEDED:
        return (
            submission_sha256 != ZERO_DIGEST
            and backend_completion_sha256 != ZERO_DIGEST
            and output_sha256 != ZERO_DIGEST
        )
    if outcome in (
        DISPATCH_TERMINAL_FAILURE,
        DISPATCH_CANCELLED_AFTER_SUBMIT,
    ):
        return (
            submission_sha256 != ZERO_DIGEST
            and backend_completion_sha256 != ZERO_DIGEST
            and output_sha256 == ZERO_DIGEST
        )
    if outcome in (
        DISPATCH_CANCELLED_BEFORE_SUBMIT,
        DISPATCH_REJECTED_BEFORE_SUBMIT,
    ):
        return (
            submission_sha256 == ZERO_DIGEST
            and backend_completion_sha256 == ZERO_DIGEST
            and output_sha256 == ZERO_DIGEST
        )
    return False


def dispatch_terminal_root_v1(
    value: DispatchTerminalEvidenceV1,
) -> Digest:
    return _hash(
        DISPATCH_TERMINAL_DOMAIN,
        (
            _le(
                value.abi_version,
                value.outcome,
                value.dispatch_generation,
            ),
            _digest(value.dispatch_authority_sha256),
            _digest(value.queue_authority_sha256),
            _digest(value.pin_sha256),
            _digest(value.dispatch_request_sha256),
            _digest(value.submission_sha256),
            _digest(value.backend_completion_sha256),
            _digest(value.output_sha256),
        ),
    )


def make_dispatch_terminal_v1(
    pin: LeaseTreeDispatchPinV1,
    outcome: int,
    submission_sha256: Digest,
    backend_completion_sha256: Digest,
    output_sha256: Digest,
) -> DispatchTerminalEvidenceV1:
    validate_dispatch_pin_v1(pin)
    result = DispatchTerminalEvidenceV1(
        outcome=outcome,
        dispatch_generation=pin.dispatch_generation,
        dispatch_authority_sha256=pin.dispatch_authority_sha256,
        queue_authority_sha256=pin.queue_authority_sha256,
        pin_sha256=pin.pin_sha256,
        dispatch_request_sha256=pin.dispatch_request_sha256,
        submission_sha256=_digest(submission_sha256),
        backend_completion_sha256=_digest(
            backend_completion_sha256
        ),
        output_sha256=_digest(output_sha256),
    )
    result = replace(
        result,
        terminal_sha256=dispatch_terminal_root_v1(result),
    )
    validate_dispatch_terminal_v1(result)
    return result


def make_rejected_before_submit_terminal_v1(
    pin: LeaseTreeDispatchPinV1,
) -> DispatchTerminalEvidenceV1:
    """Make the exact zero-native-root pre-submit rejection for ``pin``."""

    return make_dispatch_terminal_v1(
        pin,
        DISPATCH_REJECTED_BEFORE_SUBMIT,
        ZERO_DIGEST,
        ZERO_DIGEST,
        ZERO_DIGEST,
    )


def validate_dispatch_terminal_v1(
    value: DispatchTerminalEvidenceV1,
) -> None:
    _u64s(
        value.abi_version,
        value.outcome,
        value.dispatch_generation,
    )
    roots = (
        value.dispatch_authority_sha256,
        value.queue_authority_sha256,
        value.pin_sha256,
        value.dispatch_request_sha256,
        value.submission_sha256,
        value.backend_completion_sha256,
        value.output_sha256,
        value.terminal_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        value.abi_version != DISPATCH_TERMINAL_ABI
        or value.outcome not in VALID_DISPATCH_OUTCOMES
        or value.dispatch_generation == 0
        or value.dispatch_authority_sha256 == ZERO_DIGEST
        or value.queue_authority_sha256 == ZERO_DIGEST
        or value.dispatch_authority_sha256
        == value.queue_authority_sha256
        or value.pin_sha256 == ZERO_DIGEST
        or value.dispatch_request_sha256 == ZERO_DIGEST
        or not _dispatch_terminal_root_pair_valid(
            value.outcome,
            value.submission_sha256,
            value.backend_completion_sha256,
            value.output_sha256,
        )
        or value.terminal_sha256 == ZERO_DIGEST
        or value.terminal_sha256
        != dispatch_terminal_root_v1(value)
    ):
        raise ContractError("invalid dispatch terminal evidence")


def validate_dispatch_terminal_for_pin_v1(
    terminal: DispatchTerminalEvidenceV1,
    pin: LeaseTreeDispatchPinV1,
) -> None:
    validate_dispatch_terminal_v1(terminal)
    validate_dispatch_pin_v1(pin)
    if (
        terminal.dispatch_generation != pin.dispatch_generation
        or terminal.dispatch_authority_sha256
        != pin.dispatch_authority_sha256
        or terminal.queue_authority_sha256
        != pin.queue_authority_sha256
        or terminal.pin_sha256 != pin.pin_sha256
        or terminal.dispatch_request_sha256
        != pin.dispatch_request_sha256
    ):
        raise ContractError("dispatch terminal does not bind pin")


def validate_rejected_before_submit_terminal_for_pin_v1(
    terminal: DispatchTerminalEvidenceV1,
    pin: LeaseTreeDispatchPinV1,
) -> None:
    """Require the exact rejection semantic in addition to core pin binding."""

    validate_dispatch_terminal_for_pin_v1(terminal, pin)
    if terminal.outcome != DISPATCH_REJECTED_BEFORE_SUBMIT:
        raise ContractError(
            "dispatch terminal is not a pre-submit rejection"
        )


def metal_matvec_pre_submit_attempt_root_v1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) -> Digest:
    """Mirror the Zig attempt transcript, including mixed u64/u32 widths."""

    return _hash(
        METAL_PRE_SUBMIT_ATTEMPT_DOMAIN,
        (
            _le(attempt.abi_version),
            _le32(
                attempt.group_size,
                attempt.in_features,
                attempt.out_features,
                attempt.reserved,
            ),
            _le(
                attempt.packed_weights_bytes,
                attempt.scales_count,
                attempt.input_count,
                attempt.output_count,
            ),
            _digest(attempt.bindings.packed_weights_sha256),
            _digest(attempt.bindings.scales_sha256),
            _digest(attempt.bindings.input_sha256),
            _digest(attempt.bindings.output_sha256),
        ),
    )


def make_metal_matvec_pre_submit_attempt_v1(
    bindings: MetalMatvecAllocationBindingsV1,
    packed_weights_bytes: int,
    scales_count: int,
    input_count: int,
    output_count: int,
    group_size: int,
    in_features: int,
    out_features: int,
) -> MetalMatvecPreSubmitAttemptV1:
    result = MetalMatvecPreSubmitAttemptV1(
        group_size=group_size,
        in_features=in_features,
        out_features=out_features,
        packed_weights_bytes=packed_weights_bytes,
        scales_count=scales_count,
        input_count=input_count,
        output_count=output_count,
        bindings=bindings,
    )
    result = replace(
        result,
        attempt_sha256=metal_matvec_pre_submit_attempt_root_v1(
            result
        ),
    )
    validate_metal_matvec_pre_submit_attempt_v1(result)
    return result


def validate_metal_matvec_pre_submit_attempt_v1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) -> None:
    _u64s(
        attempt.abi_version,
        attempt.packed_weights_bytes,
        attempt.scales_count,
        attempt.input_count,
        attempt.output_count,
    )
    _u32(attempt.group_size)
    _u32(attempt.in_features)
    _u32(attempt.out_features)
    _u32(attempt.reserved)
    roots = (
        attempt.bindings.packed_weights_sha256,
        attempt.bindings.scales_sha256,
        attempt.bindings.input_sha256,
        attempt.bindings.output_sha256,
        attempt.attempt_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        attempt.abi_version != METAL_PRE_SUBMIT_ATTEMPT_ABI
        or attempt.reserved != 0
        or attempt.attempt_sha256 == ZERO_DIGEST
        or attempt.attempt_sha256
        != metal_matvec_pre_submit_attempt_root_v1(attempt)
    ):
        raise ContractError("invalid Metal matvec pre-submit attempt")


def validate_metal_matvec_allocation_bindings_v1(
    bindings: MetalMatvecAllocationBindingsV1,
) -> None:
    values = (
        bindings.packed_weights_sha256,
        bindings.scales_sha256,
        bindings.input_sha256,
        bindings.output_sha256,
    )
    for index, value in enumerate(values):
        _digest(value)
        if value == ZERO_DIGEST or value in values[:index]:
            raise ContractError("invalid Metal matvec role bindings")


def _metal_matvec_expected_counts_v1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) -> Tuple[int, int, int, int]:
    group_size = _u32(attempt.group_size)
    in_features = _u32(attempt.in_features)
    out_features = _u32(attempt.out_features)
    if (
        group_size == 0
        or group_size & (group_size - 1) != 0
        or in_features == 0
        or out_features == 0
    ):
        raise ContractError("invalid Metal matvec geometry")
    elements = in_features * out_features
    if elements > U32_MAX:
        raise ContractError("Metal matvec geometry exceeds u32 elements")
    return (
        (elements + 1) // 2,
        (elements + group_size - 1) // group_size,
        in_features,
        out_features,
    )


def classify_metal_matvec_pre_submit_rejection_v1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) -> Optional[int]:
    validate_metal_matvec_pre_submit_attempt_v1(attempt)
    try:
        expected = _metal_matvec_expected_counts_v1(attempt)
    except ContractError:
        return METAL_INVALID_GEOMETRY
    actual = (
        attempt.packed_weights_bytes,
        attempt.scales_count,
        attempt.input_count,
        attempt.output_count,
    )
    if actual != expected:
        return METAL_INVALID_HOST_LENGTHS
    try:
        validate_metal_matvec_allocation_bindings_v1(
            attempt.bindings
        )
    except ContractError:
        return METAL_INVALID_ROLE_BINDINGS
    return None


def metal_matvec_dispatch_request_root_v1(
    request: MetalMatvecDispatchRequestV1,
) -> Digest:
    return _hash(
        METAL_MATVEC_DISPATCH_REQUEST_DOMAIN,
        (
            _le(
                request.abi_version,
                request.request_generation,
            ),
            _digest(request.dispatch_authority_sha256),
            _digest(request.queue_authority_sha256),
            _digest(request.attempt.attempt_sha256),
        ),
    )


def make_metal_matvec_dispatch_request_v1(
    request_generation: int,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    attempt: MetalMatvecPreSubmitAttemptV1,
) -> MetalMatvecDispatchRequestV1:
    validate_metal_matvec_pre_submit_attempt_v1(attempt)
    result = MetalMatvecDispatchRequestV1(
        request_generation=request_generation,
        dispatch_authority_sha256=_digest(
            dispatch_authority_sha256
        ),
        queue_authority_sha256=_digest(queue_authority_sha256),
        attempt=attempt,
    )
    result = replace(
        result,
        request_sha256=metal_matvec_dispatch_request_root_v1(
            result
        ),
    )
    validate_metal_matvec_dispatch_request_v1(result)
    return result


def validate_metal_matvec_dispatch_request_v1(
    request: MetalMatvecDispatchRequestV1,
) -> None:
    validate_metal_matvec_pre_submit_attempt_v1(request.attempt)
    _u64s(request.abi_version, request.request_generation)
    roots = (
        request.dispatch_authority_sha256,
        request.queue_authority_sha256,
        request.request_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        request.abi_version != METAL_MATVEC_DISPATCH_REQUEST_ABI
        or request.request_generation == 0
        or request.dispatch_authority_sha256 == ZERO_DIGEST
        or request.queue_authority_sha256 == ZERO_DIGEST
        or request.dispatch_authority_sha256
        == request.queue_authority_sha256
        or request.request_sha256 == ZERO_DIGEST
        or request.request_sha256
        != metal_matvec_dispatch_request_root_v1(request)
    ):
        raise ContractError("invalid Metal matvec dispatch request")


def metal_matvec_pre_submit_rejection_root_v1(
    rejection: MetalMatvecPreSubmitRejectionV1,
) -> Digest:
    return _hash(
        METAL_PRE_SUBMIT_REJECTION_DOMAIN,
        (
            _le(
                rejection.abi_version,
                rejection.reason,
                rejection.dispatch_generation,
                rejection.allocation_count,
                rejection.materialized_bytes,
            ),
            _digest(rejection.pin_sha256),
            _digest(rejection.backend_object_set_sha256),
            _digest(rejection.request.request_sha256),
            _digest(rejection.terminal_sha256),
        ),
    )


def validate_metal_matvec_pre_submit_rejection_v1(
    rejection: MetalMatvecPreSubmitRejectionV1,
) -> None:
    validate_metal_matvec_dispatch_request_v1(rejection.request)
    _u64s(
        rejection.abi_version,
        rejection.reason,
        rejection.dispatch_generation,
        rejection.allocation_count,
        rejection.materialized_bytes,
    )
    roots = (
        rejection.pin_sha256,
        rejection.backend_object_set_sha256,
        rejection.terminal_sha256,
        rejection.rejection_sha256,
    )
    for root in roots:
        _digest(root)
    static_reason = classify_metal_matvec_pre_submit_rejection_v1(
        rejection.request.attempt
    )
    role_mapping = rejection.reason == METAL_INVALID_ROLE_MAPPING
    if (
        rejection.abi_version != METAL_PRE_SUBMIT_REJECTION_ABI
        or rejection.reason not in VALID_METAL_PRE_SUBMIT_REASONS
        or (role_mapping and static_reason is not None)
        or (
            not role_mapping
            and (
                static_reason is None
                or static_reason != rejection.reason
            )
        )
        or rejection.dispatch_generation == 0
        or rejection.allocation_count != 4
        or rejection.materialized_bytes
        < rejection.allocation_count
        or rejection.pin_sha256 == ZERO_DIGEST
        or rejection.backend_object_set_sha256 == ZERO_DIGEST
        or rejection.terminal_sha256 == ZERO_DIGEST
        or rejection.rejection_sha256 == ZERO_DIGEST
        or rejection.rejection_sha256
        != metal_matvec_pre_submit_rejection_root_v1(rejection)
    ):
        raise ContractError("invalid Metal matvec pre-submit rejection")


def validate_metal_matvec_pre_submit_rejection_for_pin_v1(
    rejection: MetalMatvecPreSubmitRejectionV1,
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
) -> None:
    validate_metal_matvec_pre_submit_rejection_v1(rejection)
    validate_dispatch_terminal_for_pin_v1(terminal, pin)
    if (
        terminal.outcome != DISPATCH_REJECTED_BEFORE_SUBMIT
        or terminal.submission_sha256 != ZERO_DIGEST
        or terminal.backend_completion_sha256 != ZERO_DIGEST
        or terminal.output_sha256 != ZERO_DIGEST
        or rejection.dispatch_generation != pin.dispatch_generation
        or rejection.allocation_count != pin.allocation_count
        or rejection.materialized_bytes != pin.pinned_device_bytes
        or rejection.pin_sha256 != pin.pin_sha256
        or rejection.request.request_sha256
        != pin.dispatch_request_sha256
        or rejection.request.dispatch_authority_sha256
        != pin.dispatch_authority_sha256
        or rejection.request.queue_authority_sha256
        != pin.queue_authority_sha256
        or rejection.backend_object_set_sha256
        != pin.backend_object_set_sha256
        or rejection.terminal_sha256 != terminal.terminal_sha256
    ):
        raise ContractError(
            "Metal pre-submit rejection does not bind pin and terminal"
        )


def make_metal_matvec_pre_submit_rejection_v1(
    pin: LeaseTreeDispatchPinV1,
    request: MetalMatvecDispatchRequestV1,
    reason: int,
    terminal: DispatchTerminalEvidenceV1,
) -> MetalMatvecPreSubmitRejectionV1:
    validate_dispatch_pin_v1(pin)
    validate_dispatch_terminal_for_pin_v1(terminal, pin)
    validate_metal_matvec_dispatch_request_v1(request)
    result = MetalMatvecPreSubmitRejectionV1(
        reason=reason,
        dispatch_generation=pin.dispatch_generation,
        allocation_count=pin.allocation_count,
        materialized_bytes=pin.pinned_device_bytes,
        pin_sha256=pin.pin_sha256,
        backend_object_set_sha256=(
            pin.backend_object_set_sha256
        ),
        request=request,
        terminal_sha256=terminal.terminal_sha256,
    )
    result = replace(
        result,
        rejection_sha256=metal_matvec_pre_submit_rejection_root_v1(
            result
        ),
    )
    validate_metal_matvec_pre_submit_rejection_for_pin_v1(
        result,
        pin,
        terminal,
    )
    return result


def dispatch_completion_root_v1(
    value: LeaseTreeDispatchCompletionV1,
) -> Digest:
    return _hash(
        DISPATCH_COMPLETION_DOMAIN,
        (
            _le(
                value.abi_version,
                value.outcome,
                value.coordinator_epoch,
                value.allocation_generation,
                value.dispatch_generation,
            ),
            _digest(value.pin_sha256),
            _digest(value.dispatch_terminal_sha256),
            _digest(value.submission_sha256),
            _digest(value.backend_completion_sha256),
            _digest(value.output_sha256),
            _digest(value.bank_completion_sha256),
            _digest(
                value.completion_publication_binding_sha256
            ),
            lease_tree_sha256_v1(value.completed_tree),
            lease_node_sha256_v1(value.scope),
        ),
    )


def validate_dispatch_completion_v1(
    value: LeaseTreeDispatchCompletionV1,
) -> None:
    _u64s(
        value.abi_version,
        value.outcome,
        value.coordinator_epoch,
        value.allocation_generation,
        value.dispatch_generation,
    )
    roots = (
        value.pin_sha256,
        value.dispatch_terminal_sha256,
        value.submission_sha256,
        value.backend_completion_sha256,
        value.output_sha256,
        value.bank_completion_sha256,
        value.completion_publication_binding_sha256,
        value.completion_sha256,
    )
    for root in roots:
        _digest(root)
    validate_lease_tree(value.completed_tree)
    parent_sha256 = (
        allocation.resource_receipt_root(value.completed_tree.parent)
        if value.completed_tree.parent is not None
        else ZERO_DIGEST
    )
    if (
        value.abi_version != DISPATCH_COMPLETION_ABI
        or value.outcome not in VALID_DISPATCH_OUTCOMES
        or value.coordinator_epoch == 0
        or value.allocation_generation == 0
        or value.dispatch_generation == 0
        or value.pin_sha256 == ZERO_DIGEST
        or value.dispatch_terminal_sha256 == ZERO_DIGEST
        or not _dispatch_terminal_root_pair_valid(
            value.outcome,
            value.submission_sha256,
            value.backend_completion_sha256,
            value.output_sha256,
        )
        or value.bank_completion_sha256 == ZERO_DIGEST
        or value.completion_publication_binding_sha256
        == ZERO_DIGEST
        or not _tree_scope_binding_valid(
            value.completed_tree,
            value.scope,
            parent_sha256,
        )
        or value.completed_tree.current.device_bytes
        < value.scope.ceiling.device_bytes
        or value.completion_sha256 == ZERO_DIGEST
        or value.completion_sha256
        != dispatch_completion_root_v1(value)
    ):
        raise ContractError("invalid LeaseTree dispatch completion")


def validate_dispatch_completion_for_pin_v1(
    completion: LeaseTreeDispatchCompletionV1,
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
) -> None:
    validate_dispatch_completion_v1(completion)
    validate_dispatch_terminal_for_pin_v1(terminal, pin)
    if (
        completion.outcome != terminal.outcome
        or completion.coordinator_epoch != pin.coordinator_epoch
        or completion.allocation_generation
        != pin.allocation_generation
        or completion.dispatch_generation != pin.dispatch_generation
        or completion.pin_sha256 != pin.pin_sha256
        or completion.dispatch_terminal_sha256
        != terminal.terminal_sha256
        or completion.submission_sha256
        != terminal.submission_sha256
        or completion.backend_completion_sha256
        != terminal.backend_completion_sha256
        or completion.output_sha256 != terminal.output_sha256
        or completion.completion_publication_binding_sha256
        != pin.publication_binding_sha256
        or completion.scope != pin.scope
        or completion.completed_tree.parent
        != pin.pinned_tree.parent
        or completion.completed_tree.tree_key
        != pin.pinned_tree.tree_key
        or completion.completed_tree.identity_generation
        != pin.pinned_tree.identity_generation
        or completion.completed_tree.authority_key
        != pin.pinned_tree.authority_key
        or completion.completed_tree.ceiling
        != pin.pinned_tree.ceiling
        or completion.completed_tree.generation
        <= pin.pinned_tree.generation
        or completion.completed_tree.structural_revision
        <= pin.pinned_tree.structural_revision
        or completion.completed_tree.active_nodes
        < pin.allocation_count + 1
    ):
        raise ContractError("dispatch completion does not bind pin")


def validate_lease_pin_slot_for_permit_v1(
    slot: LeasePinSlotV1,
    permit: LeasePinPermitV1,
) -> None:
    if permit.parent is None:
        raise ContractError("pin permit parent is missing")
    validate_lease_pin_permit(permit)
    validate_lease_pin_slot(
        permit.parent,
        permit.pin_slot_index,
        slot,
    )
    if (
        slot.receipt_slot_index != permit.parent.slot_index
        or slot.tree_key != permit.tree_key
        or slot.tree_identity_generation
        != permit.tree_identity_generation
        or slot.tree_generation != permit.tree_generation
        or slot.structural_revision != permit.structural_revision
        or slot.generation != permit.generation
        or slot.completion_generation
        != permit.completion_generation
        or slot.request_epoch != permit.request_epoch
        or slot.session_id != permit.session_id
        or slot.sequence != permit.sequence
        or slot.owner_key != permit.owner_key
        or slot.scope_index != permit.scope_index
        or slot.scope_generation != permit.scope_generation
        or slot.node_count != permit.node_count
        or slot.claim != permit.claim
        or slot.node_set_digest != permit.node_set_digest
    ):
        raise ContractError("pin registry slot does not bind permit")


def validate_bank_pin_binding_v1(
    pinned_tree: LeaseTreeV1,
    permit: LeasePinPermitV1,
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
) -> None:
    validate_lease_pin_permit(permit)
    validate_lease_tree(pinned_tree)
    validate_admission_v1(admission)
    validate_lease_v1(lease)
    source = lease.materialized_tree
    exact_claim = ClaimV1(device_bytes=lease.materialized_bytes)
    if (
        permit.parent != pinned_tree.parent
        or pinned_tree.parent != source.parent
        or pinned_tree.tree_key != permit.tree_key
        or pinned_tree.tree_key != source.tree_key
        or pinned_tree.authority_key != source.authority_key
        or pinned_tree.identity_generation
        != permit.tree_identity_generation
        or pinned_tree.identity_generation
        != source.identity_generation
        or pinned_tree.generation != permit.tree_generation
        or pinned_tree.generation <= source.generation
        or pinned_tree.structural_revision
        != permit.structural_revision
        or pinned_tree.structural_revision
        <= source.structural_revision
        or pinned_tree.ceiling != source.ceiling
        or admission.parent_receipt_sha256
        != allocation.resource_receipt_root(permit.parent)
        or permit.scope_index != admission.scope.node_index
        or permit.scope_generation != admission.scope.generation
        or permit.node_count != lease.allocation_count
        or permit.claim != exact_claim
    ):
        raise ContractError("Bank pin does not bind allocation lease")


def validate_dispatch_pin_for_lease_v1(
    pin: LeaseTreeDispatchPinV1,
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    permit: LeasePinPermitV1,
) -> None:
    validate_dispatch_pin_v1(pin)
    validate_bank_pin_binding_v1(
        pin.pinned_tree,
        permit,
        admission,
        lease,
    )
    if (
        lease.coordinator_epoch != admission.coordinator_epoch
        or lease.generation != admission.generation
        or lease.authority_sha256 != admission.authority_sha256
        or lease.request_sha256 != admission.request_sha256
        or lease.admission_sha256 != admission.admission_sha256
        or lease.parent_receipt_sha256
        != admission.parent_receipt_sha256
        or lease.allocation_leaf_set_sha256
        != admission.allocation_leaf_set_sha256
        or pin.coordinator_epoch != admission.coordinator_epoch
        or pin.allocation_generation != admission.generation
        or pin.authority_sha256 != admission.authority_sha256
        or pin.request_sha256 != admission.request_sha256
        or pin.admission_sha256 != admission.admission_sha256
        or pin.lease_sha256 != lease.lease_sha256
        or pin.parent_receipt_sha256
        != admission.parent_receipt_sha256
        or pin.allocation_leaf_set_sha256
        != admission.allocation_leaf_set_sha256
        or pin.backend_object_set_sha256
        != lease.backend_object_set_sha256
        or pin.scope != admission.scope
        or pin.allocation_count != lease.allocation_count
        or pin.pinned_device_bytes != lease.materialized_bytes
        or permit.owner_key
        != dispatch_owner_key_v1(
            pin.coordinator_epoch,
            pin.allocation_generation,
            pin.dispatch_generation,
            pin.dispatch_request_sha256,
        )
        or pin.publication_binding_sha256
        != dispatch_publication_binding_sha256_v1(
            permit.parent,
            permit.request_epoch,
            permit.session_id,
            permit.sequence,
        )
        or pin.bank_pin_sha256
        != lease_pin_permit_sha256_v1(permit)
    ):
        raise ContractError("dispatch pin does not bind allocation lease")


def validate_bank_completion_binding_v1(
    completed_tree: LeaseTreeV1,
    bank_completion: LeasePinCompletionV1,
    pin: LeaseTreeDispatchPinV1,
    permit: LeasePinPermitV1,
) -> None:
    validate_lease_pin_completion(bank_completion)
    validate_lease_pin_permit(permit)
    validate_dispatch_pin_v1(pin)
    validate_lease_tree(completed_tree)
    source = pin.pinned_tree
    exact_claim = ClaimV1(device_bytes=pin.pinned_device_bytes)
    if (
        bank_completion.parent != completed_tree.parent
        or bank_completion.parent != permit.parent
        or completed_tree.parent != source.parent
        or permit.parent != source.parent
        or completed_tree.tree_key != bank_completion.tree_key
        or bank_completion.tree_key != permit.tree_key
        or completed_tree.tree_key != source.tree_key
        or permit.tree_key != source.tree_key
        or completed_tree.authority_key != source.authority_key
        or completed_tree.identity_generation
        != bank_completion.tree_identity_generation
        or bank_completion.tree_identity_generation
        != permit.tree_identity_generation
        or completed_tree.identity_generation
        != source.identity_generation
        or permit.tree_identity_generation
        != source.identity_generation
        or permit.tree_generation != source.generation
        or permit.structural_revision
        != source.structural_revision
        or completed_tree.generation
        != bank_completion.completion_tree_generation
        or completed_tree.generation <= source.generation
        or completed_tree.structural_revision
        <= source.structural_revision
        or completed_tree.structural_revision
        != bank_completion.completion_structural_revision
        or completed_tree.ceiling != source.ceiling
        or completed_tree.state_digest
        != bank_completion.completion_state_digest
        or completed_tree.integrity
        != bank_completion.completion_tree_integrity
        or pin.parent_receipt_sha256
        != allocation.resource_receipt_root(bank_completion.parent)
        or pin.bank_pin_sha256
        != lease_pin_permit_sha256_v1(permit)
        or pin.publication_binding_sha256
        != dispatch_publication_binding_sha256_v1(
            permit.parent,
            permit.request_epoch,
            permit.session_id,
            permit.sequence,
        )
        or permit.owner_key
        != dispatch_owner_key_v1(
            pin.coordinator_epoch,
            pin.allocation_generation,
            pin.dispatch_generation,
            pin.dispatch_request_sha256,
        )
        or bank_completion.pin_slot_index
        != permit.pin_slot_index
        or bank_completion.reserved != permit.reserved
        or bank_completion.permit_generation != permit.generation
        or bank_completion.completion_generation
        != permit.completion_generation
        or bank_completion.request_epoch != permit.request_epoch
        or bank_completion.session_id != permit.session_id
        or bank_completion.sequence != permit.sequence
        or bank_completion.owner_key != permit.owner_key
        or bank_completion.scope_index != permit.scope_index
        or bank_completion.scope_generation
        != permit.scope_generation
        or bank_completion.node_count != permit.node_count
        or bank_completion.claim != permit.claim
        or bank_completion.node_set_digest
        != permit.node_set_digest
        or bank_completion.permit_integrity != permit.integrity
        or bank_completion.scope_index != pin.scope.node_index
        or bank_completion.scope_generation != pin.scope.generation
        or bank_completion.node_count != pin.allocation_count
        or bank_completion.claim != exact_claim
    ):
        raise ContractError("Bank completion does not bind dispatch pin")


def validate_dispatch_completion_for_bank_v1(
    completion: LeaseTreeDispatchCompletionV1,
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
    permit: LeasePinPermitV1,
    bank_completion: LeasePinCompletionV1,
) -> None:
    validate_dispatch_completion_for_pin_v1(
        completion,
        pin,
        terminal,
    )
    validate_bank_completion_binding_v1(
        completion.completed_tree,
        bank_completion,
        pin,
        permit,
    )
    if (
        completion.bank_completion_sha256
        != lease_pin_completion_sha256_v1(bank_completion)
        or completion.completion_publication_binding_sha256
        != dispatch_publication_binding_sha256_v1(
            bank_completion.parent,
            bank_completion.request_epoch,
            bank_completion.session_id,
            bank_completion.sequence,
        )
    ):
        raise ContractError("dispatch completion does not bind Bank")


def make_dispatch_pin_v1(
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    pinned_tree: LeaseTreeV1,
    permit: LeasePinPermitV1,
    dispatch_generation: int,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    dispatch_request_sha256: Digest,
) -> LeaseTreeDispatchPinV1:
    result = LeaseTreeDispatchPinV1(
        coordinator_epoch=admission.coordinator_epoch,
        allocation_generation=admission.generation,
        dispatch_generation=dispatch_generation,
        authority_sha256=admission.authority_sha256,
        dispatch_authority_sha256=_digest(
            dispatch_authority_sha256
        ),
        queue_authority_sha256=_digest(queue_authority_sha256),
        request_sha256=admission.request_sha256,
        admission_sha256=admission.admission_sha256,
        lease_sha256=lease.lease_sha256,
        parent_receipt_sha256=admission.parent_receipt_sha256,
        allocation_leaf_set_sha256=(
            admission.allocation_leaf_set_sha256
        ),
        backend_object_set_sha256=lease.backend_object_set_sha256,
        dispatch_request_sha256=_digest(
            dispatch_request_sha256
        ),
        publication_binding_sha256=(
            dispatch_publication_binding_sha256_v1(
                permit.parent,
                permit.request_epoch,
                permit.session_id,
                permit.sequence,
            )
            if permit.parent is not None
            else ZERO_DIGEST
        ),
        bank_pin_sha256=lease_pin_permit_sha256_v1(permit),
        pinned_tree=pinned_tree,
        scope=admission.scope,
        allocation_count=lease.allocation_count,
        pinned_device_bytes=lease.materialized_bytes,
    )
    result = replace(result, pin_sha256=dispatch_pin_root_v1(result))
    validate_dispatch_pin_for_lease_v1(
        result,
        admission,
        lease,
        permit,
    )
    return result


def make_dispatch_completion_v1(
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
    completed_tree: LeaseTreeV1,
    permit: LeasePinPermitV1,
    bank_completion: LeasePinCompletionV1,
) -> LeaseTreeDispatchCompletionV1:
    result = LeaseTreeDispatchCompletionV1(
        outcome=terminal.outcome,
        coordinator_epoch=pin.coordinator_epoch,
        allocation_generation=pin.allocation_generation,
        dispatch_generation=pin.dispatch_generation,
        pin_sha256=pin.pin_sha256,
        dispatch_terminal_sha256=terminal.terminal_sha256,
        submission_sha256=terminal.submission_sha256,
        backend_completion_sha256=(
            terminal.backend_completion_sha256
        ),
        output_sha256=terminal.output_sha256,
        bank_completion_sha256=(
            lease_pin_completion_sha256_v1(bank_completion)
        ),
        completion_publication_binding_sha256=(
            dispatch_publication_binding_sha256_v1(
                bank_completion.parent,
                bank_completion.request_epoch,
                bank_completion.session_id,
                bank_completion.sequence,
            )
            if bank_completion.parent is not None
            else ZERO_DIGEST
        ),
        completed_tree=completed_tree,
        scope=pin.scope,
    )
    result = replace(
        result,
        completion_sha256=dispatch_completion_root_v1(result),
    )
    validate_dispatch_completion_for_bank_v1(
        result,
        pin,
        terminal,
        permit,
        bank_completion,
    )
    return result


@dataclass(frozen=True)
class _RuntimeNode:
    node: LeaseNodeV1
    state: int
    pending_generation: int
    subtree_claim: ClaimV1
    pin_count: int = 0
    published_references: int = 0


def _pending_node_digest(
    tree_identity_generation: int,
    pending_generation: int,
    state: int,
    nodes: Sequence[_RuntimeNode],
) -> int:
    result = _mix64(
        LEASE_PENDING_DOMAIN ^ tree_identity_generation
    )
    result = _mix64(result ^ pending_generation)
    result = _mix64(result ^ state)
    for runtime in sorted(nodes, key=lambda item: item.node.node_index):
        if (
            runtime.pending_generation != pending_generation
            or runtime.state != state
        ):
            continue
        result = _mix64(result ^ runtime.node.node_index)
        result = _mix64(result ^ runtime.node.integrity)
        for scalar in runtime.node.claim.values():
            result = _mix64(result ^ scalar)
    return result


def _tree_state_digest(
    tree_key: int,
    identity_generation: int,
    structural_revision: int,
    active_nodes: int,
    current: ClaimV1,
    pending_kind: int,
    pending_generation: int,
    pending_completion_generation: int,
    pending_free_permit_generation: int,
    pending_free_completion_generation: int,
    pending_scope_index: int,
    pending_count: int,
    pending_claim: ClaimV1,
    pending_digest: int,
    nodes: Sequence[_RuntimeNode],
    pin_slots: Sequence[Tuple[int, LeasePinSlotV1]] = (),
) -> int:
    result = _mix64(LEASE_TREE_STATE_DOMAIN ^ tree_key)
    for scalar in (
        identity_generation,
        structural_revision,
        active_nodes,
        pending_kind,
        pending_generation,
        pending_completion_generation,
        pending_free_permit_generation,
        pending_free_completion_generation,
        pending_scope_index,
        pending_count,
    ):
        result = _mix64(result ^ scalar)
    for current_value, pending_value in zip(
        current.values(), pending_claim.values()
    ):
        result = _mix64(result ^ current_value)
        result = _mix64(result ^ pending_value)
    result = _mix64(result ^ pending_digest)
    for runtime in sorted(nodes, key=lambda item: item.node.node_index):
        result = _mix64(result ^ runtime.node.node_index)
        result = _mix64(result ^ runtime.node.integrity)
        result = _mix64(result ^ runtime.state)
        result = _mix64(result ^ runtime.pending_generation)
        result = _mix64(result ^ runtime.pin_count)
        result = _mix64(result ^ runtime.published_references)
        for scalar in runtime.subtree_claim.values():
            result = _mix64(result ^ scalar)
    prior_pin_index = None
    has_active_pins = False
    for pin_index, pin_slot in pin_slots:
        _u32(pin_index)
        if prior_pin_index is not None and pin_index <= prior_pin_index:
            raise ContractError("pin slots are not physically ordered")
        prior_pin_index = pin_index
        if (
            not pin_slot.active
            or pin_slot.tree_identity_generation
            != identity_generation
        ):
            continue
        if not has_active_pins:
            result = _mix64(result ^ LEASE_PIN_STATE_DOMAIN)
            has_active_pins = True
        for scalar in (
            pin_index,
            pin_slot.generation,
            pin_slot.node_set_digest,
            pin_slot.integrity,
        ):
            result = _mix64(result ^ scalar)
    return result


def _make_tree_state(
    parent: ResourceReceiptV1,
    tree_key: int,
    authority_key: int,
    identity_generation: int,
    generation: int,
    structural_revision: int,
    ceiling: ClaimV1,
    current: ClaimV1,
    pending_kind: int,
    pending_generation: int,
    pending_completion_generation: int,
    pending_free_permit_generation: int,
    pending_free_completion_generation: int,
    pending_scope_index: int,
    pending_count: int,
    pending_claim: ClaimV1,
    pending_digest: int,
    nodes: Sequence[_RuntimeNode],
    pin_slots: Sequence[Tuple[int, LeasePinSlotV1]] = (),
) -> LeaseTreeV1:
    matching_pin_slots = tuple(
        (pin_index, pin_slot)
        for pin_index, pin_slot in pin_slots
        if pin_slot.receipt_slot_index == parent.slot_index
    )
    state_digest = _tree_state_digest(
        tree_key,
        identity_generation,
        structural_revision,
        len(nodes),
        current,
        pending_kind,
        pending_generation,
        pending_completion_generation,
        pending_free_permit_generation,
        pending_free_completion_generation,
        pending_scope_index,
        pending_count,
        pending_claim,
        pending_digest,
        nodes,
        matching_pin_slots,
    )
    return seal_lease_tree(
        LeaseTreeV1(
            parent=parent,
            tree_key=tree_key,
            authority_key=authority_key,
            identity_generation=identity_generation,
            generation=generation,
            structural_revision=structural_revision,
            ceiling=ceiling,
            current=current,
            active_nodes=len(nodes),
            state_digest=state_digest,
        )
    )


@dataclass(frozen=True)
class LeaseTreeCampaignV1:
    allocation_fixture: allocation.AllocationFixtureV1
    coordinator_epoch: int
    session_id: int
    publication_sequence: int
    scope: LeaseNodeV1
    leaves_1: Tuple[LeaseNodeV1, ...]
    reservation_tree_1: LeaseTreeV1
    batch_1: LeaseAllocationBatchV1
    admission_1: LeaseTreeAllocationAdmissionV1
    terminal_cancel_1: LeaseTreeAllocationTerminalReceiptV1
    leaves_2: Tuple[LeaseNodeV1, ...]
    reservation_tree_2: LeaseTreeV1
    batch_2: LeaseAllocationBatchV1
    admission_2: LeaseTreeAllocationAdmissionV1
    materialized_tree_2: LeaseTreeV1
    calls_2: Tuple[AllocationCallV1, ...]
    objects_2: Tuple[BackendObjectV1, ...]
    object_set_2: BackendObjectSetV1
    lease_2: LeaseTreeDeviceAllocationLeaseV1
    authorized_tree_2: LeaseTreeV1
    permit_2: LeaseFreePermitV1
    recovery_free_2: LeaseTreeAllocationRecoveryV1
    recovery_settlement_2: LeaseTreeAllocationRecoveryV1
    terminal_release_2: LeaseTreeAllocationTerminalReceiptV1


def make_campaign() -> LeaseTreeCampaignV1:
    """Build the deterministic cross-language LeaseTree evidence campaign."""

    fixture = allocation.make_fixture()
    parent = fixture.parent
    coordinator_epoch = 0x434F_4F52_4449_4E41
    tree_key = 0x6465_7669_6365
    authority_key = 0x6175_7468_6F72
    scope_key = 0x616C_6C6F_6361
    tenant_key = 0x7465_6E61_6E74
    identity_generation = 1
    total_claim = ClaimV1(
        device_bytes=fixture.request.total_device_bytes
    )

    # openLeaseTree consumes generations 1..2; openLeaseScope consumes 3..4.
    scope = seal_lease_node(
        LeaseNodeV1(
            parent=parent,
            tree_key=tree_key,
            tree_identity_generation=identity_generation,
            node_index=0,
            generation=3,
            parent_index=NO_LEASE_NODE,
            parent_generation=identity_generation,
            node_key=scope_key,
            tenant_key=tenant_key,
            binding_key=0,
            kind=NODE_SCOPE,
            ceiling=total_claim,
            claim=ClaimV1(),
        )
    )

    def make_leaves(
        coordinator_generation: int,
        first_resource_generation: int,
    ) -> Tuple[LeaseNodeV1, ...]:
        result = []
        for ordinal, entry in enumerate(fixture.entries):
            claim = ClaimV1(device_bytes=entry.charged_bytes)
            result.append(
                seal_lease_node(
                    LeaseNodeV1(
                        parent=parent,
                        tree_key=tree_key,
                        tree_identity_generation=identity_generation,
                        node_index=ordinal + 1,
                        generation=first_resource_generation + ordinal,
                        parent_index=scope.node_index,
                        parent_generation=scope.generation,
                        node_key=allocation_node_key_v1(
                            coordinator_epoch,
                            coordinator_generation,
                            ordinal,
                            entry.binding_sha256,
                        ),
                        tenant_key=scope.tenant_key,
                        binding_key=allocation_binding_key_v1(
                            coordinator_epoch,
                            coordinator_generation,
                            ordinal,
                            entry.binding_sha256,
                        ),
                        kind=NODE_ALLOCATION,
                        ceiling=claim,
                        claim=claim,
                    )
                )
            )
        return tuple(result)

    def runtime_nodes(
        leaves: Sequence[LeaseNodeV1],
        leaf_state: int,
        leaf_pending_generation: int,
    ) -> Tuple[_RuntimeNode, ...]:
        return (
            _RuntimeNode(
                node=scope,
                state=NODE_STATE_LIVE,
                pending_generation=0,
                subtree_claim=total_claim,
            ),
        ) + tuple(
            _RuntimeNode(
                node=leaf,
                state=leaf_state,
                pending_generation=leaf_pending_generation,
                subtree_claim=leaf.claim,
            )
            for leaf in leaves
        )

    def empty_scope_runtime() -> Tuple[_RuntimeNode, ...]:
        return (
            _RuntimeNode(
                node=scope,
                state=NODE_STATE_LIVE,
                pending_generation=0,
                subtree_claim=ClaimV1(),
            ),
        )

    # Coordinator generation one: reserve and cancel before materialization.
    leaves_1 = make_leaves(1, 6)
    reserved_nodes_1 = runtime_nodes(
        leaves_1, NODE_STATE_RESERVED_UNMATERIALIZED, 5
    )
    pending_digest_1 = _pending_node_digest(
        identity_generation,
        5,
        NODE_STATE_RESERVED_UNMATERIALIZED,
        reserved_nodes_1,
    )
    reservation_tree_1 = _make_tree_state(
        parent,
        tree_key,
        authority_key,
        identity_generation,
        9,
        3,
        total_claim,
        total_claim,
        PENDING_ALLOCATION,
        5,
        10,
        0,
        0,
        NO_LEASE_NODE,
        len(leaves_1),
        total_claim,
        pending_digest_1,
        reserved_nodes_1,
    )
    batch_1 = seal_lease_allocation_batch(
        LeaseAllocationBatchV1(
            parent=parent,
            tree_key=tree_key,
            tree_identity_generation=identity_generation,
            tree_generation=reservation_tree_1.generation,
            structural_revision=reservation_tree_1.structural_revision,
            request_epoch=fixture.request.request_epoch,
            session_id=FIXED_SESSION_ID,
            sequence=FIXED_PUBLICATION_SEQUENCE,
            generation=5,
            completion_tree_generation=10,
            node_count=len(leaves_1),
            claim=total_claim,
            node_set_digest=pending_digest_1,
        )
    )
    admission_1 = make_admission_v1(
        coordinator_epoch,
        1,
        fixture.authority,
        fixture.request,
        reservation_tree_1,
        scope,
        batch_1,
        leaves_1,
    )
    cancelled_tree_1 = _make_tree_state(
        parent,
        tree_key,
        authority_key,
        identity_generation,
        10,
        4,
        total_claim,
        ClaimV1(),
        PENDING_NONE,
        0,
        0,
        0,
        0,
        NO_LEASE_NODE,
        0,
        ClaimV1(),
        0,
        empty_scope_runtime(),
    )
    terminal_cancel_1 = make_terminal_v1(
        OUTCOME_CANCELLED,
        REASON_EXPLICIT_CANCELLATION,
        admission_1,
        fixture.request,
        cancelled_tree_1,
    )

    # Coordinator generation two: materialize, recover two cleanup phases,
    # and settle. ResourceBank generations continue at 11 after cancellation.
    leaves_2 = make_leaves(2, 12)
    reserved_nodes_2 = runtime_nodes(
        leaves_2, NODE_STATE_RESERVED_UNMATERIALIZED, 11
    )
    pending_digest_2 = _pending_node_digest(
        identity_generation,
        11,
        NODE_STATE_RESERVED_UNMATERIALIZED,
        reserved_nodes_2,
    )
    reservation_tree_2 = _make_tree_state(
        parent,
        tree_key,
        authority_key,
        identity_generation,
        15,
        5,
        total_claim,
        total_claim,
        PENDING_ALLOCATION,
        11,
        16,
        0,
        0,
        NO_LEASE_NODE,
        len(leaves_2),
        total_claim,
        pending_digest_2,
        reserved_nodes_2,
    )
    batch_2 = seal_lease_allocation_batch(
        LeaseAllocationBatchV1(
            parent=parent,
            tree_key=tree_key,
            tree_identity_generation=identity_generation,
            tree_generation=reservation_tree_2.generation,
            structural_revision=reservation_tree_2.structural_revision,
            request_epoch=fixture.request.request_epoch,
            session_id=FIXED_SESSION_ID,
            sequence=FIXED_PUBLICATION_SEQUENCE,
            generation=11,
            completion_tree_generation=16,
            node_count=len(leaves_2),
            claim=total_claim,
            node_set_digest=pending_digest_2,
        )
    )
    admission_2 = make_admission_v1(
        coordinator_epoch,
        2,
        fixture.authority,
        fixture.request,
        reservation_tree_2,
        scope,
        batch_2,
        leaves_2,
    )
    live_nodes_2 = runtime_nodes(leaves_2, NODE_STATE_LIVE, 0)
    materialized_tree_2 = _make_tree_state(
        parent,
        tree_key,
        authority_key,
        identity_generation,
        16,
        6,
        total_claim,
        total_claim,
        PENDING_NONE,
        0,
        0,
        0,
        0,
        NO_LEASE_NODE,
        0,
        ClaimV1(),
        0,
        live_nodes_2,
    )
    calls_2 = tuple(
        allocation.make_allocation_call_for_admission_root(
            fixture.authority,
            admission_2.admission_sha256,
            ordinal,
            entry,
        )
        for ordinal, entry in enumerate(fixture.entries)
    )
    objects_2 = tuple(
        allocation.make_backend_object(
            call,
            allocation.fake_object_identity(
                fixture.authority,
                ordinal,
                ordinal + 1,
                call.call_sha256,
            ),
            ordinal + 1,
        )
        for ordinal, call in enumerate(calls_2)
    )
    object_set_2 = allocation.make_object_set_for_admission_root(
        admission_2.admission_sha256,
        admission_2.authority_sha256,
        admission_2.allocation_count,
        admission_2.total_device_bytes,
        calls_2,
        objects_2,
    )
    lease_2 = make_lease_v1(
        admission_2,
        fixture.request,
        object_set_2,
        materialized_tree_2,
    )

    free_nodes_2 = runtime_nodes(
        leaves_2, NODE_STATE_FREE_AUTHORIZED, 20
    )
    free_pending_digest_2 = _pending_node_digest(
        identity_generation,
        20,
        NODE_STATE_FREE_AUTHORIZED,
        free_nodes_2,
    )
    authorized_tree_2 = _make_tree_state(
        parent,
        tree_key,
        authority_key,
        identity_generation,
        19,
        8,
        total_claim,
        total_claim,
        PENDING_FREE,
        20,
        21,
        0,
        0,
        scope.node_index,
        len(leaves_2),
        total_claim,
        free_pending_digest_2,
        free_nodes_2,
    )
    permit_2 = seal_lease_free_permit(
        LeaseFreePermitV1(
            parent=parent,
            tree_key=tree_key,
            tree_identity_generation=identity_generation,
            tree_generation=authorized_tree_2.generation,
            structural_revision=authorized_tree_2.structural_revision,
            request_epoch=fixture.request.request_epoch,
            session_id=FIXED_SESSION_ID,
            sequence=FIXED_PUBLICATION_SEQUENCE,
            generation=20,
            completion_tree_generation=21,
            scope_index=scope.node_index,
            scope_generation=scope.generation,
            node_count=len(leaves_2),
            claim=total_claim,
            node_set_digest=free_pending_digest_2,
        )
    )
    permit_root = lease_free_permit_sha256_v1(permit_2)
    recovery_free_2 = make_recovery_v1(
        PHASE_FREE_AUTHORIZED,
        1,
        admission_2,
        authorized_tree_2,
        permit_root,
        OUTCOME_RELEASED,
        REASON_NORMAL_RELEASE,
        ((1, objects_2[1]),),
        lease_2,
    )
    recovery_settlement_2 = make_recovery_v1(
        PHASE_SETTLEMENT_REQUIRED,
        2,
        admission_2,
        authorized_tree_2,
        permit_root,
        OUTCOME_RELEASED,
        REASON_NORMAL_RELEASE,
        (),
        lease_2,
    )
    terminal_tree_2 = _make_tree_state(
        parent,
        tree_key,
        authority_key,
        identity_generation,
        21,
        9,
        total_claim,
        ClaimV1(),
        PENDING_NONE,
        0,
        0,
        0,
        0,
        NO_LEASE_NODE,
        0,
        ClaimV1(),
        0,
        empty_scope_runtime(),
    )
    terminal_release_2 = make_terminal_v1(
        OUTCOME_RELEASED,
        REASON_NORMAL_RELEASE,
        admission_2,
        fixture.request,
        terminal_tree_2,
        lease_2,
    )

    return LeaseTreeCampaignV1(
        allocation_fixture=fixture,
        coordinator_epoch=coordinator_epoch,
        session_id=FIXED_SESSION_ID,
        publication_sequence=FIXED_PUBLICATION_SEQUENCE,
        scope=scope,
        leaves_1=leaves_1,
        reservation_tree_1=reservation_tree_1,
        batch_1=batch_1,
        admission_1=admission_1,
        terminal_cancel_1=terminal_cancel_1,
        leaves_2=leaves_2,
        reservation_tree_2=reservation_tree_2,
        batch_2=batch_2,
        admission_2=admission_2,
        materialized_tree_2=materialized_tree_2,
        calls_2=calls_2,
        objects_2=objects_2,
        object_set_2=object_set_2,
        lease_2=lease_2,
        authorized_tree_2=authorized_tree_2,
        permit_2=permit_2,
        recovery_free_2=recovery_free_2,
        recovery_settlement_2=recovery_settlement_2,
        terminal_release_2=terminal_release_2,
    )


@dataclass(frozen=True)
class LeaseTreeDispatchCampaignV1:
    allocation_campaign: LeaseTreeCampaignV1
    dispatch_generation: int
    dispatch_authority_sha256: Digest
    queue_authority_sha256: Digest
    dispatch_request_sha256: Digest
    submission_sha256: Digest
    backend_completion_sha256: Digest
    output_sha256: Digest
    owner_key: int
    members: Tuple[LeasePinMemberV1, ...]
    pin_slot: LeasePinSlotV1
    permit: LeasePinPermitV1
    pinned_tree: LeaseTreeV1
    pin: LeaseTreeDispatchPinV1
    terminal: DispatchTerminalEvidenceV1
    completed_tree: LeaseTreeV1
    bank_completion: LeasePinCompletionV1
    completion: LeaseTreeDispatchCompletionV1


def make_dispatch_campaign(
    outcome: int = DISPATCH_SUCCEEDED,
    *,
    dispatch_authority_sha256: Optional[Digest] = None,
    queue_authority_sha256: Optional[Digest] = None,
    dispatch_request_sha256: Optional[Digest] = None,
) -> LeaseTreeDispatchCampaignV1:
    """Branch from a materialized lease through one terminal dispatch."""

    campaign = make_campaign()
    fixture = campaign.allocation_fixture
    parent = fixture.parent
    lease = campaign.lease_2
    source_tree = campaign.materialized_tree_2
    scope = campaign.scope
    leaves = campaign.leaves_2
    claim = ClaimV1(device_bytes=lease.materialized_bytes)
    dispatch_generation = 1
    if dispatch_authority_sha256 is None:
        dispatch_authority_sha256 = allocation.digest_v1(
            b"LeaseTree dispatch authority"
        )
    else:
        dispatch_authority_sha256 = _digest(
            dispatch_authority_sha256
        )
    if queue_authority_sha256 is None:
        queue_authority_sha256 = allocation.digest_v1(
            b"LeaseTree queue authority"
        )
    else:
        queue_authority_sha256 = _digest(
            queue_authority_sha256
        )
    if dispatch_request_sha256 is None:
        dispatch_request_sha256 = allocation.digest_v1(
            b"LeaseTree dispatch request"
        )
    else:
        dispatch_request_sha256 = _digest(
            dispatch_request_sha256
        )
    _u64(outcome)
    if outcome not in VALID_DISPATCH_OUTCOMES:
        raise ContractError("invalid dispatch campaign outcome")
    submitted = outcome in (
        DISPATCH_SUCCEEDED,
        DISPATCH_TERMINAL_FAILURE,
        DISPATCH_CANCELLED_AFTER_SUBMIT,
    )
    submission_sha256 = (
        allocation.digest_v1(b"LeaseTree dispatch submission")
        if submitted
        else ZERO_DIGEST
    )
    backend_completion_sha256 = (
        allocation.digest_v1(
            b"LeaseTree dispatch backend completion"
        )
        if submitted
        else ZERO_DIGEST
    )
    output_sha256 = (
        allocation.digest_v1(b"LeaseTree dispatch output")
        if outcome == DISPATCH_SUCCEEDED
        else ZERO_DIGEST
    )
    owner_key = dispatch_owner_key_v1(
        campaign.coordinator_epoch,
        lease.generation,
        dispatch_generation,
        dispatch_request_sha256,
    )
    members = tuple(
        LeasePinMemberV1(
            node_index=leaf.node_index,
            node_generation=leaf.generation,
            node_integrity=leaf.integrity,
        )
        for leaf in leaves
    )
    node_set_digest = lease_pin_node_set_digest_v1(
        source_tree.tree_key,
        source_tree.identity_generation,
        scope.node_index,
        scope.generation,
        members,
    )

    permit_generation = 17
    acquired_tree_generation = 18
    completion_generation = 19
    pin_slot_index = 0
    acquired_structural_revision = (
        source_tree.structural_revision + 1
    )
    pin_slot = seal_lease_pin_slot(
        parent,
        pin_slot_index,
        LeasePinSlotV1(
            active=True,
            receipt_slot_index=parent.slot_index,
            tree_key=source_tree.tree_key,
            tree_identity_generation=(
                source_tree.identity_generation
            ),
            tree_generation=acquired_tree_generation,
            structural_revision=acquired_structural_revision,
            generation=permit_generation,
            completion_generation=completion_generation,
            request_epoch=fixture.request.request_epoch,
            session_id=campaign.session_id,
            sequence=campaign.publication_sequence,
            owner_key=owner_key,
            scope_index=scope.node_index,
            scope_generation=scope.generation,
            node_count=len(members),
            claim=claim,
            node_set_digest=node_set_digest,
            members=members,
        ),
    )
    pinned_nodes = (
        _RuntimeNode(
            node=scope,
            state=NODE_STATE_LIVE,
            pending_generation=0,
            subtree_claim=claim,
        ),
    ) + tuple(
        _RuntimeNode(
            node=leaf,
            state=NODE_STATE_LIVE,
            pending_generation=0,
            subtree_claim=leaf.claim,
            pin_count=1,
        )
        for leaf in leaves
    )
    pinned_tree = _make_tree_state(
        parent,
        source_tree.tree_key,
        source_tree.authority_key,
        source_tree.identity_generation,
        acquired_tree_generation,
        acquired_structural_revision,
        source_tree.ceiling,
        source_tree.current,
        PENDING_NONE,
        0,
        0,
        0,
        0,
        NO_LEASE_NODE,
        0,
        ClaimV1(),
        0,
        pinned_nodes,
        ((pin_slot_index, pin_slot),),
    )
    permit = seal_lease_pin_permit(
        LeasePinPermitV1(
            parent=parent,
            tree_key=pinned_tree.tree_key,
            tree_identity_generation=(
                pinned_tree.identity_generation
            ),
            tree_generation=pinned_tree.generation,
            structural_revision=pinned_tree.structural_revision,
            pin_slot_index=pin_slot_index,
            generation=permit_generation,
            completion_generation=completion_generation,
            request_epoch=fixture.request.request_epoch,
            session_id=campaign.session_id,
            sequence=campaign.publication_sequence,
            owner_key=owner_key,
            scope_index=scope.node_index,
            scope_generation=scope.generation,
            node_count=len(members),
            claim=claim,
            node_set_digest=node_set_digest,
        )
    )
    validate_lease_pin_slot_for_permit_v1(pin_slot, permit)
    pin = make_dispatch_pin_v1(
        campaign.admission_2,
        lease,
        pinned_tree,
        permit,
        dispatch_generation,
        dispatch_authority_sha256,
        queue_authority_sha256,
        dispatch_request_sha256,
    )
    terminal = make_dispatch_terminal_v1(
        pin,
        outcome,
        submission_sha256,
        backend_completion_sha256,
        output_sha256,
    )

    completed_structural_revision = (
        pinned_tree.structural_revision + 1
    )
    completed_tree_generation = 20
    completed_nodes = (
        _RuntimeNode(
            node=scope,
            state=NODE_STATE_LIVE,
            pending_generation=0,
            subtree_claim=claim,
        ),
    ) + tuple(
        _RuntimeNode(
            node=leaf,
            state=NODE_STATE_LIVE,
            pending_generation=0,
            subtree_claim=leaf.claim,
        )
        for leaf in leaves
    )
    completed_tree = _make_tree_state(
        parent,
        pinned_tree.tree_key,
        pinned_tree.authority_key,
        pinned_tree.identity_generation,
        completed_tree_generation,
        completed_structural_revision,
        pinned_tree.ceiling,
        pinned_tree.current,
        PENDING_NONE,
        0,
        0,
        0,
        0,
        NO_LEASE_NODE,
        0,
        ClaimV1(),
        0,
        completed_nodes,
    )
    bank_completion = seal_lease_pin_completion(
        LeasePinCompletionV1(
            parent=parent,
            tree_key=permit.tree_key,
            tree_identity_generation=(
                permit.tree_identity_generation
            ),
            pin_slot_index=permit.pin_slot_index,
            permit_generation=permit.generation,
            completion_generation=permit.completion_generation,
            request_epoch=permit.request_epoch,
            session_id=permit.session_id,
            sequence=permit.sequence,
            owner_key=permit.owner_key,
            scope_index=permit.scope_index,
            scope_generation=permit.scope_generation,
            node_count=permit.node_count,
            claim=permit.claim,
            node_set_digest=permit.node_set_digest,
            permit_integrity=permit.integrity,
            completion_tree_generation=completed_tree.generation,
            completion_structural_revision=(
                completed_tree.structural_revision
            ),
            completion_state_digest=completed_tree.state_digest,
            completion_tree_integrity=completed_tree.integrity,
        )
    )
    completion = make_dispatch_completion_v1(
        pin,
        terminal,
        completed_tree,
        permit,
        bank_completion,
    )
    return LeaseTreeDispatchCampaignV1(
        allocation_campaign=campaign,
        dispatch_generation=dispatch_generation,
        dispatch_authority_sha256=dispatch_authority_sha256,
        queue_authority_sha256=queue_authority_sha256,
        dispatch_request_sha256=dispatch_request_sha256,
        submission_sha256=submission_sha256,
        backend_completion_sha256=backend_completion_sha256,
        output_sha256=output_sha256,
        owner_key=owner_key,
        members=members,
        pin_slot=pin_slot,
        permit=permit,
        pinned_tree=pinned_tree,
        pin=pin,
        terminal=terminal,
        completed_tree=completed_tree,
        bank_completion=bank_completion,
        completion=completion,
    )


def make_rejected_before_submit_dispatch_campaign(
) -> LeaseTreeDispatchCampaignV1:
    """Build the exact core pre-submit rejection transcript branch."""

    return make_dispatch_campaign(DISPATCH_REJECTED_BEFORE_SUBMIT)


@dataclass(frozen=True)
class MetalMatvecPreSubmitRejectionCampaignV1:
    bindings: MetalMatvecAllocationBindingsV1
    attempt: MetalMatvecPreSubmitAttemptV1
    request: MetalMatvecDispatchRequestV1
    intent: DispatchPinIntentV1
    pin: LeaseTreeDispatchPinV1
    terminal: DispatchTerminalEvidenceV1
    rejection: MetalMatvecPreSubmitRejectionV1


def make_metal_matvec_pre_submit_rejection_campaign(
) -> MetalMatvecPreSubmitRejectionCampaignV1:
    """Build a fixed Metal rejection transcript without loading Zig code."""

    bindings = MetalMatvecAllocationBindingsV1(
        packed_weights_sha256=allocation.digest_v1(
            b"request packed binding"
        ),
        scales_sha256=allocation.digest_v1(
            b"request scales binding"
        ),
        input_sha256=allocation.digest_v1(
            b"request input binding"
        ),
        output_sha256=allocation.digest_v1(
            b"request output binding"
        ),
    )
    attempt = make_metal_matvec_pre_submit_attempt_v1(
        bindings,
        1_184,
        296,
        64,
        37,
        8,
        64,
        37,
    )
    dispatch_authority_sha256 = allocation.digest_v1(
        b"request dispatch authority"
    )
    queue_authority_sha256 = allocation.digest_v1(
        b"request queue authority"
    )
    request = make_metal_matvec_dispatch_request_v1(
        1,
        dispatch_authority_sha256,
        queue_authority_sha256,
        attempt,
    )
    dispatch = make_dispatch_campaign(
        DISPATCH_REJECTED_BEFORE_SUBMIT,
        dispatch_authority_sha256=dispatch_authority_sha256,
        queue_authority_sha256=queue_authority_sha256,
        dispatch_request_sha256=request.request_sha256,
    )
    pinned_tree = seal_lease_tree(
        replace(
            dispatch.pinned_tree,
            active_nodes=5,
            integrity=0,
        )
    )
    pin_draft = replace(
        dispatch.pin,
        pinned_tree=pinned_tree,
        allocation_count=4,
        pin_sha256=ZERO_DIGEST,
    )
    pin = replace(
        pin_draft,
        pin_sha256=dispatch_pin_root_v1(pin_draft),
    )
    validate_dispatch_pin_v1(pin)
    intent = make_dispatch_pin_intent_v1(
        coordinator_epoch=pin.coordinator_epoch,
        allocation_generation=pin.allocation_generation,
        dispatch_generation=pin.dispatch_generation,
        allocation_count=pin.allocation_count,
        pinned_device_bytes=pin.pinned_device_bytes,
        authority_sha256=pin.authority_sha256,
        dispatch_authority_sha256=pin.dispatch_authority_sha256,
        queue_authority_sha256=pin.queue_authority_sha256,
        request_sha256=pin.request_sha256,
        admission_sha256=pin.admission_sha256,
        lease_sha256=pin.lease_sha256,
        parent_receipt_sha256=pin.parent_receipt_sha256,
        allocation_leaf_set_sha256=(
            pin.allocation_leaf_set_sha256
        ),
        backend_object_set_sha256=pin.backend_object_set_sha256,
        scope_sha256=lease_node_sha256_v1(pin.scope),
        dispatch_request_sha256=pin.dispatch_request_sha256,
        publication_binding_sha256=(
            pin.publication_binding_sha256
        ),
    )
    validate_dispatch_pin_for_intent_v1(pin, intent)
    terminal = make_rejected_before_submit_terminal_v1(pin)
    rejection = make_metal_matvec_pre_submit_rejection_v1(
        pin,
        request,
        METAL_INVALID_ROLE_MAPPING,
        terminal,
    )
    return MetalMatvecPreSubmitRejectionCampaignV1(
        bindings=bindings,
        attempt=attempt,
        request=request,
        intent=intent,
        pin=pin,
        terminal=terminal,
        rejection=rejection,
    )
