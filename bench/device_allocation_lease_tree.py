"""Independent oracle for LeaseTree-backed device-allocation V1 evidence.

This module is standard-library-only apart from importing the existing
portable allocation-contract oracle.  It does not parse Zig sources or load
Glacier symbols.  ResourceBank's accidental-misuse checksums and the public
SHA-256 evidence transcripts are reproduced as separate algorithms.

``make_campaign`` follows one fixed additive LeaseTree through cancellation,
materialization, free-authorized recovery, settlement recovery, and release.
Its session identifier is a stable integer rather than a process address, so
all roots are reproducible across processes and languages.
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

ADMISSION_ABI = 0x4744_5441_0000_0001
LEASE_ABI = 0x4744_544C_0000_0001
RECOVERY_ABI = 0x4744_5452_0000_0001
TERMINAL_ABI = 0x4744_5454_0000_0001

TREE_DOMAIN = b"glacier-resource-lease-tree-v1\x00"
NODE_DOMAIN = b"glacier-resource-lease-node-v1\x00"
BATCH_DOMAIN = b"glacier-resource-lease-allocation-batch-v1\x00"
PERMIT_DOMAIN = b"glacier-resource-lease-free-permit-v1\x00"
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

LEASE_TREE_INTEGRITY_DOMAIN = 0x6C65_6173_6574_7231
LEASE_TREE_STATE_DOMAIN = 0x6C65_6173_6573_7431
LEASE_NODE_INTEGRITY_DOMAIN = 0x6C65_6173_656E_6431
LEASE_PENDING_DOMAIN = 0x6C65_6173_6570_6431
LEASE_BATCH_INTEGRITY_DOMAIN = 0x6C65_6173_6562_6131
LEASE_FREE_INTEGRITY_DOMAIN = 0x6C65_6173_6566_7231

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
) -> LeaseTreeV1:
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
