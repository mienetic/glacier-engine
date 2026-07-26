"""Independent oracle for the portable device-allocation lease contract.

The implementation is deliberately standard-library-only and does not parse
Zig sources or load Glacier symbols.  It reproduces the V1 little-endian
SHA-256 transcripts, structural validation, ResourceBank receipt/child
bindings, and a small synchronous reference lifecycle.

Device discovery and selection are outside this module.  ``SelectionBindingV1``
is the exact projection the allocation contract consumes from an independently
validated selection receipt.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, replace
from typing import Dict, List, Optional, Sequence, Tuple


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
U32_MAX = (1 << 32) - 1
MAXIMUM_ALLOCATIONS = 64

MANIFEST_ABI = 0x4744_414D_0000_0001
REQUEST_ABI = 0x4744_4151_0000_0001
AUTHORITY_ABI = 0x4744_4141_0000_0001
QUOTE_ABI = 0x4744_4155_0000_0001
ADMISSION_ABI = 0x4744_4144_0000_0001
ALLOCATION_CALL_ABI = 0x4744_4143_0000_0001
BACKEND_OBJECT_ABI = 0x4744_414F_0000_0001
OBJECT_SET_ABI = 0x4744_4153_0000_0001
LEASE_ABI = 0x4744_414C_0000_0001
RECOVERY_ABI = 0x4744_4152_0000_0001
TERMINAL_ABI = 0x4744_4154_0000_0001
RESOURCE_CHILD_ABI = 0x4752_434C_0000_0001

MANIFEST_DOMAIN = b"glacier-device-allocation-manifest-v1\x00"
REQUEST_DOMAIN = b"glacier-device-allocation-request-v1\x00"
AUTHORITY_DOMAIN = b"glacier-device-allocation-authority-v1\x00"
QUOTE_DOMAIN = b"glacier-device-allocation-quote-v1\x00"
ADMISSION_DOMAIN = b"glacier-device-allocation-admission-v1\x00"
ALLOCATION_CALL_DOMAIN = b"glacier-device-allocation-call-v1\x00"
BACKEND_OBJECT_DOMAIN = b"glacier-device-allocation-object-v1\x00"
OBJECT_SET_DOMAIN = b"glacier-device-allocation-object-set-v1\x00"
LEASE_DOMAIN = b"glacier-device-allocation-lease-v1\x00"
RECOVERY_DOMAIN = b"glacier-device-allocation-recovery-v1\x00"
OUTSTANDING_SET_DOMAIN = b"glacier-device-allocation-outstanding-v1\x00"
TERMINAL_DOMAIN = b"glacier-device-allocation-terminal-v1\x00"
RESOURCE_RECEIPT_DOMAIN = b"glacier-resource-receipt-binding-v1\x00"
RESOURCE_CHILD_DOMAIN = b"glacier-resource-child-binding-v1\x00"
CHILD_KEY_DOMAIN = b"glacier-device-allocation-child-key-v1\x00"
FAKE_OBJECT_IDENTITY_DOMAIN = (
    b"glacier-device-allocation-fake-object-id-v1\x00"
)

RESOURCE_RECEIPT_INTEGRITY_DOMAIN = 0x7265_6365_6970_7431
RESOURCE_CHILD_INTEGRITY_DOMAIN = 0x6368_696C_646C_7331

DEVICE_ACCELERATOR = 2
FEATURE_ALLOCATION = 1 << 0

OUTCOME_CANCELLED = 1
OUTCOME_ALLOCATION_FAILED = 2
OUTCOME_RELEASED = 3
VALID_OUTCOMES = frozenset(
    (OUTCOME_CANCELLED, OUTCOME_ALLOCATION_FAILED, OUTCOME_RELEASED)
)

REASON_EXPLICIT_CANCELLATION = 1
REASON_BACKEND_ALLOCATION_FAILURE = 2
REASON_BACKEND_PROTOCOL_VIOLATION = 3
REASON_NORMAL_RELEASE = 4
VALID_REASONS = frozenset(
    (
        REASON_EXPLICIT_CANCELLATION,
        REASON_BACKEND_ALLOCATION_FAILURE,
        REASON_BACKEND_PROTOCOL_VIOLATION,
        REASON_NORMAL_RELEASE,
    )
)


class ContractError(ValueError):
    """A portable value or lifecycle transition is invalid."""


class ArithmeticOverflow(ContractError):
    pass


class InvalidTransition(ContractError):
    pass


class StaleHandle(ContractError):
    pass


class InjectedFreeFailure(ContractError):
    pass


@dataclass(frozen=True)
class ClaimV1:
    capsule_bytes: int = 0
    kv_bytes: int = 0
    activation_bytes: int = 0
    partial_bytes: int = 0
    logits_bytes: int = 0
    output_journal_bytes: int = 0
    staging_bytes: int = 0
    device_bytes: int = 0
    io_bytes: int = 0
    queue_slots: int = 0

    def values(self) -> Tuple[int, ...]:
        return (
            self.capsule_bytes,
            self.kv_bytes,
            self.activation_bytes,
            self.partial_bytes,
            self.logits_bytes,
            self.output_journal_bytes,
            self.staging_bytes,
            self.device_bytes,
            self.io_bytes,
            self.queue_slots,
        )


@dataclass(frozen=True)
class ResourceReceiptV1:
    bank_epoch: int
    slot_index: int
    generation: int
    owner_key: int
    claim: ClaimV1
    integrity: int = 0


@dataclass(frozen=True)
class ResourceChildLeaseV1:
    abi_version: int = RESOURCE_CHILD_ABI
    parent: Optional[ResourceReceiptV1] = None
    child_key: int = 0
    generation: int = 0
    ceiling: ClaimV1 = ClaimV1()
    claim: ClaimV1 = ClaimV1()
    integrity: int = 0


@dataclass(frozen=True)
class AllocationEntryV1:
    binding_sha256: Digest = ZERO_DIGEST
    requested_bytes: int = 0
    charged_bytes: int = 0
    quote_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationManifestV1:
    abi_version: int = MANIFEST_ABI
    allocation_count: int = 0
    largest_requested_bytes: int = 0
    total_requested_bytes: int = 0
    largest_charged_bytes: int = 0
    total_charged_bytes: int = 0
    manifest_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationAuthorityV1:
    abi_version: int = AUTHORITY_ABI
    authority_epoch: int = 0
    maximum_leases: int = 0
    maximum_live_objects: int = 0
    allocation_granularity_bytes: int = 0
    max_single_allocation_bytes: int = 0
    max_total_device_bytes: int = 0
    max_queue_slots: int = 0
    selected_discovery_epoch: int = 0
    selected_capability_sha256: Digest = ZERO_DIGEST
    selected_entry_sha256: Digest = ZERO_DIGEST
    backend_authority_sha256: Digest = ZERO_DIGEST
    authority_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationQuoteV1:
    abi_version: int = QUOTE_ABI
    authority_sha256: Digest = ZERO_DIGEST
    binding_sha256: Digest = ZERO_DIGEST
    requested_bytes: int = 0
    charged_bytes: int = 0
    quote_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class SelectionBindingV1:
    receipt_sha256: Digest
    requirement_sha256: Digest
    selected_capability_sha256: Digest
    selected_entry_sha256: Digest
    selected_discovery_epoch: int
    selected_device_class: int
    fallback_used: int
    required_feature_bits: int
    largest_single_allocation_bytes: int
    total_device_bytes: int
    queue_slots: int
    selected_max_single_allocation_bytes: int
    selected_max_total_device_bytes: int
    selected_max_queue_slots: int


@dataclass(frozen=True)
class AllocationRequestV1:
    abi_version: int = REQUEST_ABI
    request_epoch: int = 0
    owner_sha256: Digest = ZERO_DIGEST
    authority_sha256: Digest = ZERO_DIGEST
    selection_receipt_sha256: Digest = ZERO_DIGEST
    requirement_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    selected_entry_sha256: Digest = ZERO_DIGEST
    allocation_manifest_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    allocation_count: int = 0
    largest_single_allocation_bytes: int = 0
    total_device_bytes: int = 0
    queue_slots: int = 0
    request_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationAdmissionV1:
    abi_version: int = ADMISSION_ABI
    coordinator_epoch: int = 0
    slot_index: int = 0
    generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    selection_receipt_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    allocation_manifest_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    child_lease_sha256: Digest = ZERO_DIGEST
    allocation_count: int = 0
    total_device_bytes: int = 0
    admission_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationCallV1:
    abi_version: int = ALLOCATION_CALL_ABI
    authority_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    ordinal: int = 0
    binding_sha256: Digest = ZERO_DIGEST
    requested_bytes: int = 0
    charged_bytes: int = 0
    quote_sha256: Digest = ZERO_DIGEST
    call_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class BackendObjectV1:
    abi_version: int = BACKEND_OBJECT_ABI
    allocation_call_sha256: Digest = ZERO_DIGEST
    binding_sha256: Digest = ZERO_DIGEST
    backend_object_sha256: Digest = ZERO_DIGEST
    backend_object_generation: int = 0
    allocated_bytes: int = 0
    object_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class BackendObjectSetV1:
    abi_version: int = OBJECT_SET_ABI
    admission_sha256: Digest = ZERO_DIGEST
    allocation_count: int = 0
    total_allocated_bytes: int = 0
    object_set_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DeviceAllocationLeaseV1:
    abi_version: int = LEASE_ABI
    coordinator_epoch: int = 0
    slot_index: int = 0
    generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    selection_receipt_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    allocation_manifest_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    child_lease_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    allocation_count: int = 0
    materialized_bytes: int = 0
    lease_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationRecoveryV1:
    abi_version: int = RECOVERY_ABI
    coordinator_epoch: int = 0
    slot_index: int = 0
    generation: int = 0
    recovery_generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    lease_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    target_outcome: int = OUTCOME_CANCELLED
    target_reason: int = REASON_EXPLICIT_CANCELLATION
    outstanding_object_count: int = 0
    outstanding_bytes: int = 0
    outstanding_set_sha256: Digest = ZERO_DIGEST
    recovery_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class AllocationTerminalReceiptV1:
    abi_version: int = TERMINAL_ABI
    outcome: int = OUTCOME_CANCELLED
    reason: int = REASON_EXPLICIT_CANCELLATION
    coordinator_epoch: int = 0
    slot_index: int = 0
    generation: int = 0
    authority_sha256: Digest = ZERO_DIGEST
    request_sha256: Digest = ZERO_DIGEST
    admission_sha256: Digest = ZERO_DIGEST
    lease_sha256: Digest = ZERO_DIGEST
    backend_object_set_sha256: Digest = ZERO_DIGEST
    parent_receipt_sha256: Digest = ZERO_DIGEST
    child_lease_sha256: Digest = ZERO_DIGEST
    returned_device_bytes: int = 0
    terminal_sha256: Digest = ZERO_DIGEST


def digest_v1(value: bytes) -> Digest:
    return hashlib.sha256(value).digest()


def _digest(value: Digest) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise ContractError("digest must contain exactly 32 bytes")
    return value


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


def _hash(domain: bytes, chunks: Sequence[bytes]) -> Digest:
    transcript = hashlib.sha256()
    transcript.update(domain)
    for chunk in chunks:
        transcript.update(chunk)
    return transcript.digest()


def _le(*values: int) -> bytes:
    for value in values:
        _u64(value)
    return struct.pack("<" + "Q" * len(values), *values)


def _add_u64(left: int, right: int) -> int:
    _u64s(left, right)
    value = left + right
    if value > U64_MAX:
        raise ArithmeticOverflow("u64 addition overflow")
    return value


def _claim_bytes(claim: ClaimV1) -> bytes:
    _u64s(*claim.values())
    return _le(*claim.values())


def _claim_within(value: ClaimV1, ceiling: ClaimV1) -> bool:
    return all(
        current <= maximum
        for current, maximum in zip(value.values(), ceiling.values())
    )


def _claim_is_zero(value: ClaimV1) -> bool:
    return all(field == 0 for field in value.values())


def _mix64(value: int) -> int:
    value &= U64_MAX
    value ^= value >> 30
    value = (value * 0xBF58_476D_1CE4_E5B9) & U64_MAX
    value ^= value >> 27
    value = (value * 0x94D0_49BB_1331_11EB) & U64_MAX
    value ^= value >> 31
    return value & U64_MAX


def _receipt_integrity(
    bank_epoch: int,
    slot_index: int,
    generation: int,
    owner_key: int,
    claim: ClaimV1,
) -> int:
    _u64s(bank_epoch, slot_index, generation, owner_key, *claim.values())
    result = _mix64(RESOURCE_RECEIPT_INTEGRITY_DOMAIN ^ bank_epoch)
    for value in (slot_index, generation, owner_key) + claim.values():
        result = _mix64(result ^ value)
    return result


def seal_resource_receipt(
    bank_epoch: int,
    slot_index: int,
    generation: int,
    owner_key: int,
    claim: ClaimV1,
) -> ResourceReceiptV1:
    result = ResourceReceiptV1(
        bank_epoch=bank_epoch,
        slot_index=slot_index,
        generation=generation,
        owner_key=owner_key,
        claim=claim,
        integrity=_receipt_integrity(
            bank_epoch, slot_index, generation, owner_key, claim
        ),
    )
    validate_resource_receipt(result)
    return result


def validate_resource_receipt(receipt: ResourceReceiptV1) -> None:
    _u32(receipt.slot_index)
    _u64s(
        receipt.bank_epoch,
        receipt.generation,
        receipt.owner_key,
        receipt.integrity,
    )
    _claim_bytes(receipt.claim)
    if receipt.integrity != _receipt_integrity(
        receipt.bank_epoch,
        receipt.slot_index,
        receipt.generation,
        receipt.owner_key,
        receipt.claim,
    ):
        raise ContractError("invalid ResourceBank receipt integrity")


def resource_receipt_root(receipt: ResourceReceiptV1) -> Digest:
    validate_resource_receipt(receipt)
    return _hash(
        RESOURCE_RECEIPT_DOMAIN,
        (
            _le(
                receipt.bank_epoch,
                receipt.slot_index,
                receipt.generation,
                receipt.owner_key,
            ),
            _claim_bytes(receipt.claim),
            _le(receipt.integrity),
        ),
    )


def _child_integrity(
    parent: ResourceReceiptV1,
    child_key: int,
    generation: int,
    ceiling: ClaimV1,
    claim: ClaimV1,
) -> int:
    validate_resource_receipt(parent)
    _u64s(child_key, generation, *ceiling.values(), *claim.values())
    result = _mix64(RESOURCE_CHILD_INTEGRITY_DOMAIN ^ parent.integrity)
    for value in (
        parent.bank_epoch,
        parent.slot_index,
        parent.generation,
        parent.owner_key,
        child_key,
        generation,
    ) + ceiling.values() + claim.values():
        result = _mix64(result ^ value)
    return result


def open_resource_child(
    parent: ResourceReceiptV1,
    child_key: int,
    generation: int,
    ceiling: ClaimV1,
    claim: ClaimV1,
) -> ResourceChildLeaseV1:
    validate_resource_receipt(parent)
    if (
        child_key == 0
        or generation == 0
        or _claim_is_zero(ceiling)
        or not _claim_within(claim, ceiling)
    ):
        raise ContractError("invalid ResourceBank child shape")
    result = ResourceChildLeaseV1(
        parent=parent,
        child_key=child_key,
        generation=generation,
        ceiling=ceiling,
        claim=claim,
        integrity=_child_integrity(
            parent, child_key, generation, ceiling, claim
        ),
    )
    validate_resource_child(result)
    return result


def validate_resource_child(child: ResourceChildLeaseV1) -> None:
    if child.parent is None:
        raise ContractError("missing ResourceBank parent")
    validate_resource_receipt(child.parent)
    _u64s(
        child.abi_version,
        child.child_key,
        child.generation,
        child.integrity,
    )
    _claim_bytes(child.ceiling)
    _claim_bytes(child.claim)
    if (
        child.abi_version != RESOURCE_CHILD_ABI
        or child.child_key == 0
        or child.generation == 0
        or _claim_is_zero(child.ceiling)
        or not _claim_within(child.claim, child.ceiling)
        or child.integrity
        != _child_integrity(
            child.parent,
            child.child_key,
            child.generation,
            child.ceiling,
            child.claim,
        )
    ):
        raise ContractError("invalid ResourceBank child")


def resource_child_root(child: ResourceChildLeaseV1) -> Digest:
    validate_resource_child(child)
    assert child.parent is not None
    return _hash(
        RESOURCE_CHILD_DOMAIN,
        (
            _le(child.abi_version),
            resource_receipt_root(child.parent),
            _le(child.child_key, child.generation),
            _claim_bytes(child.ceiling),
            _claim_bytes(child.claim),
            _le(child.integrity),
        ),
    )


def authority_root(value: AllocationAuthorityV1) -> Digest:
    return _hash(
        AUTHORITY_DOMAIN,
        (
            _le(
                value.abi_version,
                value.authority_epoch,
                value.maximum_leases,
                value.maximum_live_objects,
                value.allocation_granularity_bytes,
                value.max_single_allocation_bytes,
                value.max_total_device_bytes,
                value.max_queue_slots,
                value.selected_discovery_epoch,
            ),
            _digest(value.selected_capability_sha256),
            _digest(value.selected_entry_sha256),
            _digest(value.backend_authority_sha256),
        ),
    )


def seal_authority(
    value: AllocationAuthorityV1,
) -> AllocationAuthorityV1:
    if value.authority_sha256 != ZERO_DIGEST:
        raise ContractError("authority is already sealed")
    result = replace(value, abi_version=AUTHORITY_ABI)
    result = replace(result, authority_sha256=authority_root(result))
    validate_authority(result)
    return result


def validate_authority(value: AllocationAuthorityV1) -> None:
    _u64s(
        value.abi_version,
        value.authority_epoch,
        value.maximum_leases,
        value.maximum_live_objects,
        value.allocation_granularity_bytes,
        value.max_single_allocation_bytes,
        value.max_total_device_bytes,
        value.max_queue_slots,
        value.selected_discovery_epoch,
    )
    for root in (
        value.selected_capability_sha256,
        value.selected_entry_sha256,
        value.backend_authority_sha256,
        value.authority_sha256,
    ):
        _digest(root)
    granularity = value.allocation_granularity_bytes
    if (
        value.abi_version != AUTHORITY_ABI
        or value.authority_epoch == 0
        or value.maximum_leases != 1
        or value.maximum_live_objects == 0
        or value.maximum_live_objects > MAXIMUM_ALLOCATIONS
        or granularity == 0
        or granularity & (granularity - 1)
        or value.max_single_allocation_bytes == 0
        or granularity > value.max_single_allocation_bytes
        or value.max_total_device_bytes == 0
        or value.max_single_allocation_bytes
        > value.max_total_device_bytes
        or value.max_queue_slots == 0
        or value.selected_discovery_epoch == 0
        or value.selected_capability_sha256 == ZERO_DIGEST
        or value.selected_entry_sha256 == ZERO_DIGEST
        or value.backend_authority_sha256 == ZERO_DIGEST
        or value.authority_sha256 == ZERO_DIGEST
        or value.authority_sha256 != authority_root(value)
    ):
        raise ContractError("invalid allocation authority")


def quote_root(value: AllocationQuoteV1) -> Digest:
    return _hash(
        QUOTE_DOMAIN,
        (
            _le(value.abi_version),
            _digest(value.authority_sha256),
            _digest(value.binding_sha256),
            _le(value.requested_bytes, value.charged_bytes),
        ),
    )


def make_quote(
    authority: AllocationAuthorityV1,
    binding_sha256: Digest,
    requested_bytes: int,
    charged_bytes: int,
) -> AllocationQuoteV1:
    validate_authority(authority)
    result = AllocationQuoteV1(
        authority_sha256=authority.authority_sha256,
        binding_sha256=binding_sha256,
        requested_bytes=requested_bytes,
        charged_bytes=charged_bytes,
    )
    result = replace(result, quote_sha256=quote_root(result))
    validate_quote(result, authority)
    return result


def validate_quote(
    value: AllocationQuoteV1, authority: AllocationAuthorityV1
) -> None:
    validate_authority(authority)
    _u64s(value.abi_version, value.requested_bytes, value.charged_bytes)
    for root in (
        value.authority_sha256,
        value.binding_sha256,
        value.quote_sha256,
    ):
        _digest(root)
    if (
        value.abi_version != QUOTE_ABI
        or value.authority_sha256 != authority.authority_sha256
        or value.binding_sha256 == ZERO_DIGEST
        or value.requested_bytes == 0
        or value.charged_bytes < value.requested_bytes
        or value.charged_bytes
        % authority.allocation_granularity_bytes
        != 0
        or value.charged_bytes > authority.max_single_allocation_bytes
        or value.quote_sha256 == ZERO_DIGEST
        or value.quote_sha256 != quote_root(value)
    ):
        raise ContractError("invalid allocation quote")


def align_forward(value: int, alignment: int) -> int:
    _u64s(value, alignment)
    if value == 0 or alignment == 0 or alignment & (alignment - 1):
        raise ContractError("invalid alignment")
    with_mask = _add_u64(value, alignment - 1)
    return with_mask & ~(alignment - 1)


def make_fake_quote(
    authority: AllocationAuthorityV1,
    binding_sha256: Digest,
    requested_bytes: int,
) -> AllocationQuoteV1:
    return make_quote(
        authority,
        binding_sha256,
        requested_bytes,
        align_forward(
            requested_bytes, authority.allocation_granularity_bytes
        ),
    )


def _manifest_totals(
    entries: Sequence[AllocationEntryV1],
) -> Tuple[int, int, int, int]:
    if not entries or len(entries) > MAXIMUM_ALLOCATIONS:
        raise ContractError("invalid manifest entry count")
    total_requested = 0
    total_charged = 0
    largest_requested = 0
    largest_charged = 0
    prior = None
    for entry in entries:
        _digest(entry.binding_sha256)
        _digest(entry.quote_sha256)
        _u64s(entry.requested_bytes, entry.charged_bytes)
        if (
            entry.binding_sha256 == ZERO_DIGEST
            or entry.quote_sha256 == ZERO_DIGEST
            or entry.requested_bytes == 0
            or entry.charged_bytes < entry.requested_bytes
            or (prior is not None and prior >= entry.binding_sha256)
        ):
            raise ContractError("invalid or non-canonical manifest entry")
        prior = entry.binding_sha256
        total_requested = _add_u64(total_requested, entry.requested_bytes)
        total_charged = _add_u64(total_charged, entry.charged_bytes)
        largest_requested = max(largest_requested, entry.requested_bytes)
        largest_charged = max(largest_charged, entry.charged_bytes)
    return (
        largest_requested,
        total_requested,
        largest_charged,
        total_charged,
    )


def manifest_root(
    value: AllocationManifestV1,
    entries: Sequence[AllocationEntryV1],
) -> Digest:
    chunks = [
        _le(
            value.abi_version,
            value.allocation_count,
            value.largest_requested_bytes,
            value.total_requested_bytes,
            value.largest_charged_bytes,
            value.total_charged_bytes,
        )
    ]
    for entry in entries:
        chunks.extend(
            (
                _digest(entry.binding_sha256),
                _le(entry.requested_bytes, entry.charged_bytes),
                _digest(entry.quote_sha256),
            )
        )
    return _hash(MANIFEST_DOMAIN, chunks)


def seal_manifest(
    entries: Sequence[AllocationEntryV1],
) -> AllocationManifestV1:
    totals = _manifest_totals(entries)
    result = AllocationManifestV1(
        allocation_count=len(entries),
        largest_requested_bytes=totals[0],
        total_requested_bytes=totals[1],
        largest_charged_bytes=totals[2],
        total_charged_bytes=totals[3],
    )
    result = replace(
        result, manifest_sha256=manifest_root(result, entries)
    )
    validate_manifest(result, entries)
    return result


def validate_manifest(
    value: AllocationManifestV1,
    entries: Sequence[AllocationEntryV1],
) -> None:
    _u64s(
        value.abi_version,
        value.allocation_count,
        value.largest_requested_bytes,
        value.total_requested_bytes,
        value.largest_charged_bytes,
        value.total_charged_bytes,
    )
    _digest(value.manifest_sha256)
    totals = _manifest_totals(entries)
    if (
        value.abi_version != MANIFEST_ABI
        or value.allocation_count != len(entries)
        or (
            value.largest_requested_bytes,
            value.total_requested_bytes,
            value.largest_charged_bytes,
            value.total_charged_bytes,
        )
        != totals
        or value.manifest_sha256 == ZERO_DIGEST
        or value.manifest_sha256 != manifest_root(value, entries)
    ):
        raise ContractError("invalid allocation manifest")


def _quote_from_entry(
    authority: AllocationAuthorityV1, entry: AllocationEntryV1
) -> AllocationQuoteV1:
    return AllocationQuoteV1(
        authority_sha256=authority.authority_sha256,
        binding_sha256=entry.binding_sha256,
        requested_bytes=entry.requested_bytes,
        charged_bytes=entry.charged_bytes,
        quote_sha256=entry.quote_sha256,
    )


def request_root(value: AllocationRequestV1) -> Digest:
    return _hash(
        REQUEST_DOMAIN,
        (
            _le(value.abi_version, value.request_epoch),
            _digest(value.owner_sha256),
            _digest(value.authority_sha256),
            _digest(value.selection_receipt_sha256),
            _digest(value.requirement_sha256),
            _digest(value.selected_capability_sha256),
            _digest(value.selected_entry_sha256),
            _digest(value.allocation_manifest_sha256),
            _digest(value.parent_receipt_sha256),
            _le(
                value.allocation_count,
                value.largest_single_allocation_bytes,
                value.total_device_bytes,
                value.queue_slots,
            ),
        ),
    )


def make_request(
    request_epoch: int,
    owner_sha256: Digest,
    authority: AllocationAuthorityV1,
    selection: SelectionBindingV1,
    parent: ResourceReceiptV1,
    manifest: AllocationManifestV1,
    entries: Sequence[AllocationEntryV1],
) -> AllocationRequestV1:
    result = AllocationRequestV1(
        request_epoch=request_epoch,
        owner_sha256=owner_sha256,
        authority_sha256=authority.authority_sha256,
        selection_receipt_sha256=selection.receipt_sha256,
        requirement_sha256=selection.requirement_sha256,
        selected_capability_sha256=selection.selected_capability_sha256,
        selected_entry_sha256=selection.selected_entry_sha256,
        allocation_manifest_sha256=manifest.manifest_sha256,
        parent_receipt_sha256=resource_receipt_root(parent),
        allocation_count=manifest.allocation_count,
        largest_single_allocation_bytes=manifest.largest_charged_bytes,
        total_device_bytes=manifest.total_charged_bytes,
        queue_slots=selection.queue_slots,
    )
    result = replace(result, request_sha256=request_root(result))
    validate_request(
        result, authority, selection, parent, manifest, entries
    )
    return result


def validate_request(
    value: AllocationRequestV1,
    authority: AllocationAuthorityV1,
    selection: SelectionBindingV1,
    parent: ResourceReceiptV1,
    manifest: AllocationManifestV1,
    entries: Sequence[AllocationEntryV1],
) -> None:
    validate_authority(authority)
    validate_resource_receipt(parent)
    validate_manifest(manifest, entries)
    _u64s(
        value.abi_version,
        value.request_epoch,
        value.allocation_count,
        value.largest_single_allocation_bytes,
        value.total_device_bytes,
        value.queue_slots,
        selection.selected_discovery_epoch,
        selection.selected_device_class,
        selection.fallback_used,
        selection.required_feature_bits,
        selection.largest_single_allocation_bytes,
        selection.total_device_bytes,
        selection.queue_slots,
        selection.selected_max_single_allocation_bytes,
        selection.selected_max_total_device_bytes,
        selection.selected_max_queue_slots,
    )
    for root in (
        value.owner_sha256,
        value.authority_sha256,
        value.selection_receipt_sha256,
        value.requirement_sha256,
        value.selected_capability_sha256,
        value.selected_entry_sha256,
        value.allocation_manifest_sha256,
        value.parent_receipt_sha256,
        value.request_sha256,
        selection.receipt_sha256,
        selection.requirement_sha256,
        selection.selected_capability_sha256,
        selection.selected_entry_sha256,
    ):
        _digest(root)
    for entry in entries:
        validate_quote(_quote_from_entry(authority, entry), authority)
    expected = (
        value.abi_version == REQUEST_ABI
        and value.request_epoch != 0
        and value.owner_sha256 != ZERO_DIGEST
        and value.authority_sha256 == authority.authority_sha256
        and value.selection_receipt_sha256 == selection.receipt_sha256
        and value.requirement_sha256 == selection.requirement_sha256
        and value.selected_capability_sha256
        == selection.selected_capability_sha256
        and value.selected_entry_sha256 == selection.selected_entry_sha256
        and value.allocation_manifest_sha256 == manifest.manifest_sha256
        and value.parent_receipt_sha256 == resource_receipt_root(parent)
        and value.allocation_count == manifest.allocation_count
        and value.largest_single_allocation_bytes
        == manifest.largest_charged_bytes
        and value.total_device_bytes == manifest.total_charged_bytes
        and value.queue_slots == selection.queue_slots
        and value.largest_single_allocation_bytes
        == selection.largest_single_allocation_bytes
        and value.total_device_bytes == selection.total_device_bytes
        and parent.claim.device_bytes == 0
        and parent.claim.queue_slots == selection.queue_slots
        and selection.selected_device_class == DEVICE_ACCELERATOR
        and selection.fallback_used == 0
        and selection.required_feature_bits & FEATURE_ALLOCATION
        and selection.largest_single_allocation_bytes != 0
        and selection.selected_max_single_allocation_bytes != 0
        and selection.selected_max_total_device_bytes != 0
        and selection.selected_max_queue_slots != 0
        and authority.max_single_allocation_bytes
        <= selection.selected_max_single_allocation_bytes
        and authority.max_total_device_bytes
        <= selection.selected_max_total_device_bytes
        and authority.max_queue_slots
        <= selection.selected_max_queue_slots
        and authority.selected_capability_sha256
        == selection.selected_capability_sha256
        and authority.selected_entry_sha256 == selection.selected_entry_sha256
        and authority.selected_discovery_epoch
        == selection.selected_discovery_epoch
        and authority.max_single_allocation_bytes
        >= value.largest_single_allocation_bytes
        and authority.max_total_device_bytes >= value.total_device_bytes
        and authority.max_queue_slots >= value.queue_slots
        and authority.maximum_live_objects >= value.allocation_count
        and value.request_sha256 != ZERO_DIGEST
        and value.request_sha256 == request_root(value)
    )
    if not expected:
        raise ContractError("invalid allocation request composition")


def allocation_child_key(
    coordinator_epoch: int,
    slot_index: int,
    generation: int,
    request_sha256: Digest,
) -> int:
    _u32(slot_index)
    root = _hash(
        CHILD_KEY_DOMAIN,
        (
            _le(coordinator_epoch, slot_index, generation),
            _digest(request_sha256),
        ),
    )
    value = struct.unpack("<Q", root[:8])[0]
    return 1 if value == 0 else value


def admission_root(value: AllocationAdmissionV1) -> Digest:
    return _hash(
        ADMISSION_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.slot_index,
                value.generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.request_sha256),
            _digest(value.selection_receipt_sha256),
            _digest(value.selected_capability_sha256),
            _digest(value.allocation_manifest_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.child_lease_sha256),
            _le(value.allocation_count, value.total_device_bytes),
        ),
    )


def make_admission(
    coordinator_epoch: int,
    slot_index: int,
    generation: int,
    authority: AllocationAuthorityV1,
    request: AllocationRequestV1,
    child: ResourceChildLeaseV1,
) -> AllocationAdmissionV1:
    result = AllocationAdmissionV1(
        coordinator_epoch=coordinator_epoch,
        slot_index=slot_index,
        generation=generation,
        authority_sha256=authority.authority_sha256,
        request_sha256=request.request_sha256,
        selection_receipt_sha256=request.selection_receipt_sha256,
        selected_capability_sha256=request.selected_capability_sha256,
        allocation_manifest_sha256=request.allocation_manifest_sha256,
        parent_receipt_sha256=request.parent_receipt_sha256,
        child_lease_sha256=resource_child_root(child),
        allocation_count=request.allocation_count,
        total_device_bytes=request.total_device_bytes,
    )
    result = replace(result, admission_sha256=admission_root(result))
    validate_admission(result)
    return result


def validate_admission(value: AllocationAdmissionV1) -> None:
    _u32(value.slot_index)
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
        value.child_lease_sha256,
        value.admission_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        value.abi_version != ADMISSION_ABI
        or value.coordinator_epoch == 0
        or value.generation == 0
        or any(root == ZERO_DIGEST for root in roots)
        or value.allocation_count == 0
        or value.allocation_count > MAXIMUM_ALLOCATIONS
        or value.total_device_bytes == 0
        or value.admission_sha256 != admission_root(value)
    ):
        raise ContractError("invalid allocation admission")


def allocation_call_root(value: AllocationCallV1) -> Digest:
    return _hash(
        ALLOCATION_CALL_DOMAIN,
        (
            _le(value.abi_version),
            _digest(value.authority_sha256),
            _digest(value.admission_sha256),
            _le(value.ordinal),
            _digest(value.binding_sha256),
            _le(value.requested_bytes, value.charged_bytes),
            _digest(value.quote_sha256),
        ),
    )


def make_allocation_call(
    authority: AllocationAuthorityV1,
    admission: AllocationAdmissionV1,
    ordinal: int,
    entry: AllocationEntryV1,
) -> AllocationCallV1:
    result = AllocationCallV1(
        authority_sha256=authority.authority_sha256,
        admission_sha256=admission.admission_sha256,
        ordinal=ordinal,
        binding_sha256=entry.binding_sha256,
        requested_bytes=entry.requested_bytes,
        charged_bytes=entry.charged_bytes,
        quote_sha256=entry.quote_sha256,
    )
    result = replace(result, call_sha256=allocation_call_root(result))
    validate_allocation_call(result)
    return result


def validate_allocation_call(value: AllocationCallV1) -> None:
    _u64s(
        value.abi_version,
        value.ordinal,
        value.requested_bytes,
        value.charged_bytes,
    )
    roots = (
        value.authority_sha256,
        value.admission_sha256,
        value.binding_sha256,
        value.quote_sha256,
        value.call_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        value.abi_version != ALLOCATION_CALL_ABI
        or any(root == ZERO_DIGEST for root in roots)
        or value.ordinal >= MAXIMUM_ALLOCATIONS
        or value.requested_bytes == 0
        or value.charged_bytes < value.requested_bytes
        or value.call_sha256 != allocation_call_root(value)
    ):
        raise ContractError("invalid allocation call")


def fake_object_identity(
    authority: AllocationAuthorityV1,
    slot_index: int,
    generation: int,
    call_sha256: Digest,
) -> Digest:
    _u32(slot_index)
    return _hash(
        FAKE_OBJECT_IDENTITY_DOMAIN,
        (
            _digest(authority.authority_sha256),
            _le(slot_index, generation),
            _digest(call_sha256),
        ),
    )


def backend_object_root(value: BackendObjectV1) -> Digest:
    return _hash(
        BACKEND_OBJECT_DOMAIN,
        (
            _le(value.abi_version),
            _digest(value.allocation_call_sha256),
            _digest(value.binding_sha256),
            _digest(value.backend_object_sha256),
            _le(value.backend_object_generation, value.allocated_bytes),
        ),
    )


def make_backend_object(
    call: AllocationCallV1,
    backend_object_sha256: Digest,
    backend_object_generation: int,
) -> BackendObjectV1:
    result = BackendObjectV1(
        allocation_call_sha256=call.call_sha256,
        binding_sha256=call.binding_sha256,
        backend_object_sha256=backend_object_sha256,
        backend_object_generation=backend_object_generation,
        allocated_bytes=call.charged_bytes,
    )
    result = replace(result, object_sha256=backend_object_root(result))
    validate_backend_object(result, call)
    return result


def validate_backend_object(
    value: BackendObjectV1, call: AllocationCallV1
) -> None:
    validate_allocation_call(call)
    _u64s(
        value.abi_version,
        value.backend_object_generation,
        value.allocated_bytes,
    )
    roots = (
        value.allocation_call_sha256,
        value.binding_sha256,
        value.backend_object_sha256,
        value.object_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        value.abi_version != BACKEND_OBJECT_ABI
        or value.allocation_call_sha256 != call.call_sha256
        or value.binding_sha256 != call.binding_sha256
        or value.backend_object_sha256 == ZERO_DIGEST
        or value.backend_object_generation == 0
        or value.allocated_bytes != call.charged_bytes
        or value.object_sha256 == ZERO_DIGEST
        or value.object_sha256 != backend_object_root(value)
    ):
        raise ContractError("invalid backend object")


def object_set_root(
    value: BackendObjectSetV1,
    objects: Sequence[BackendObjectV1],
) -> Digest:
    chunks = [
        _le(value.abi_version),
        _digest(value.admission_sha256),
        _le(value.allocation_count, value.total_allocated_bytes),
    ]
    chunks.extend(_digest(item.object_sha256) for item in objects)
    return _hash(OBJECT_SET_DOMAIN, chunks)


def make_object_set(
    admission: AllocationAdmissionV1,
    calls: Sequence[AllocationCallV1],
    objects: Sequence[BackendObjectV1],
) -> BackendObjectSetV1:
    if len(calls) != len(objects):
        raise ContractError("call/object count mismatch")
    total = 0
    identities = set()
    for index, item in enumerate(objects):
        call = calls[index]
        validate_allocation_call(call)
        validate_backend_object(item, call)
        if (
            call.ordinal != index
            or call.authority_sha256 != admission.authority_sha256
            or call.admission_sha256 != admission.admission_sha256
        ):
            raise ContractError("call is foreign to object-set admission")
        identity = (
            item.backend_object_sha256,
            item.backend_object_generation,
        )
        if identity in identities:
            raise ContractError("duplicate backend object identity")
        identities.add(identity)
        total = _add_u64(total, item.allocated_bytes)
    result = BackendObjectSetV1(
        admission_sha256=admission.admission_sha256,
        allocation_count=len(objects),
        total_allocated_bytes=total,
    )
    result = replace(
        result, object_set_sha256=object_set_root(result, objects)
    )
    validate_object_set(result, admission, calls, objects)
    return result


def validate_object_set(
    value: BackendObjectSetV1,
    admission: AllocationAdmissionV1,
    calls: Sequence[AllocationCallV1],
    objects: Sequence[BackendObjectV1],
) -> None:
    validate_admission(admission)
    _u64s(
        value.abi_version,
        value.allocation_count,
        value.total_allocated_bytes,
    )
    _digest(value.admission_sha256)
    _digest(value.object_set_sha256)
    if len(calls) != len(objects):
        raise ContractError("call/object count mismatch")
    total = 0
    identities = set()
    for index, item in enumerate(objects):
        call = calls[index]
        validate_allocation_call(call)
        validate_backend_object(item, call)
        identity = (
            item.backend_object_sha256,
            item.backend_object_generation,
        )
        if (
            call.ordinal != index
            or call.authority_sha256 != admission.authority_sha256
            or call.admission_sha256 != admission.admission_sha256
            or identity in identities
        ):
            raise ContractError("invalid call/object set member")
        identities.add(identity)
        total = _add_u64(total, item.allocated_bytes)
    if (
        value.abi_version != OBJECT_SET_ABI
        or value.admission_sha256 != admission.admission_sha256
        or len(calls) != len(objects)
        or value.allocation_count != len(objects)
        or value.allocation_count != admission.allocation_count
        or value.total_allocated_bytes != admission.total_device_bytes
        or value.total_allocated_bytes != total
        or value.object_set_sha256 == ZERO_DIGEST
        or value.object_set_sha256 != object_set_root(value, objects)
    ):
        raise ContractError("invalid backend object set")


def lease_root(value: DeviceAllocationLeaseV1) -> Digest:
    return _hash(
        LEASE_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.slot_index,
                value.generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.request_sha256),
            _digest(value.admission_sha256),
            _digest(value.selection_receipt_sha256),
            _digest(value.selected_capability_sha256),
            _digest(value.allocation_manifest_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.child_lease_sha256),
            _digest(value.backend_object_set_sha256),
            _le(value.allocation_count, value.materialized_bytes),
        ),
    )


def make_lease(
    admission: AllocationAdmissionV1,
    request: AllocationRequestV1,
    object_set: BackendObjectSetV1,
) -> DeviceAllocationLeaseV1:
    if admission.request_sha256 != request.request_sha256:
        raise ContractError("admission/request substitution")
    result = DeviceAllocationLeaseV1(
        coordinator_epoch=admission.coordinator_epoch,
        slot_index=admission.slot_index,
        generation=admission.generation,
        authority_sha256=admission.authority_sha256,
        request_sha256=admission.request_sha256,
        admission_sha256=admission.admission_sha256,
        selection_receipt_sha256=admission.selection_receipt_sha256,
        selected_capability_sha256=admission.selected_capability_sha256,
        allocation_manifest_sha256=admission.allocation_manifest_sha256,
        parent_receipt_sha256=admission.parent_receipt_sha256,
        child_lease_sha256=admission.child_lease_sha256,
        backend_object_set_sha256=object_set.object_set_sha256,
        allocation_count=object_set.allocation_count,
        materialized_bytes=object_set.total_allocated_bytes,
    )
    result = replace(result, lease_sha256=lease_root(result))
    validate_lease(result)
    return result


def validate_lease(value: DeviceAllocationLeaseV1) -> None:
    _u32(value.slot_index)
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
        value.child_lease_sha256,
        value.backend_object_set_sha256,
        value.lease_sha256,
    )
    for root in roots:
        _digest(root)
    if (
        value.abi_version != LEASE_ABI
        or value.coordinator_epoch == 0
        or value.generation == 0
        or any(root == ZERO_DIGEST for root in roots)
        or value.allocation_count == 0
        or value.allocation_count > MAXIMUM_ALLOCATIONS
        or value.materialized_bytes == 0
        or value.lease_sha256 != lease_root(value)
    ):
        raise ContractError("invalid device allocation lease")


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


def outstanding_set_root(
    coordinator_epoch: int,
    slot_index: int,
    generation: int,
    outstanding: Sequence[Tuple[int, BackendObjectV1]],
) -> Digest:
    if not outstanding:
        return ZERO_DIGEST
    chunks = [_le(coordinator_epoch, slot_index, generation)]
    prior = None
    for ordinal, item in outstanding:
        _u64(ordinal)
        if prior is not None and ordinal <= prior:
            raise ContractError("outstanding objects are not ordinal ordered")
        prior = ordinal
        chunks.extend((_le(ordinal), _digest(item.object_sha256)))
    return _hash(OUTSTANDING_SET_DOMAIN, chunks)


def recovery_root(value: AllocationRecoveryV1) -> Digest:
    return _hash(
        RECOVERY_DOMAIN,
        (
            _le(
                value.abi_version,
                value.coordinator_epoch,
                value.slot_index,
                value.generation,
                value.recovery_generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.admission_sha256),
            _digest(value.lease_sha256),
            _digest(value.backend_object_set_sha256),
            _le(
                value.target_outcome,
                value.target_reason,
                value.outstanding_object_count,
                value.outstanding_bytes,
            ),
            _digest(value.outstanding_set_sha256),
        ),
    )


def make_recovery(
    coordinator_epoch: int,
    slot_index: int,
    generation: int,
    recovery_generation: int,
    authority_sha256: Digest,
    admission_sha256: Digest,
    lease_sha256: Digest,
    backend_object_set_sha256: Digest,
    target_outcome: int,
    target_reason: int,
    outstanding: Sequence[
        Tuple[int, AllocationCallV1, BackendObjectV1]
    ],
) -> AllocationRecoveryV1:
    total = 0
    for _, call, _ in outstanding:
        total = _add_u64(total, call.charged_bytes)
    outstanding_objects = tuple(
        (ordinal, item) for ordinal, _, item in outstanding
    )
    result = AllocationRecoveryV1(
        coordinator_epoch=coordinator_epoch,
        slot_index=slot_index,
        generation=generation,
        recovery_generation=recovery_generation,
        authority_sha256=authority_sha256,
        admission_sha256=admission_sha256,
        lease_sha256=lease_sha256,
        backend_object_set_sha256=backend_object_set_sha256,
        target_outcome=target_outcome,
        target_reason=target_reason,
        outstanding_object_count=len(outstanding),
        outstanding_bytes=total,
        outstanding_set_sha256=outstanding_set_root(
            coordinator_epoch,
            slot_index,
            generation,
            outstanding_objects,
        ),
    )
    result = replace(result, recovery_sha256=recovery_root(result))
    validate_recovery(result)
    return result


def validate_recovery(value: AllocationRecoveryV1) -> None:
    _u32(value.slot_index)
    _u64s(
        value.abi_version,
        value.coordinator_epoch,
        value.generation,
        value.recovery_generation,
        value.target_outcome,
        value.target_reason,
        value.outstanding_object_count,
        value.outstanding_bytes,
    )
    roots = (
        value.authority_sha256,
        value.admission_sha256,
        value.lease_sha256,
        value.backend_object_set_sha256,
        value.outstanding_set_sha256,
        value.recovery_sha256,
    )
    for root in roots:
        _digest(root)
    released = value.target_outcome == OUTCOME_RELEASED
    if (
        value.abi_version != RECOVERY_ABI
        or value.coordinator_epoch == 0
        or value.generation == 0
        or value.recovery_generation == 0
        or value.outstanding_object_count > MAXIMUM_ALLOCATIONS
        or value.authority_sha256 == ZERO_DIGEST
        or value.admission_sha256 == ZERO_DIGEST
        or value.target_outcome not in VALID_OUTCOMES
        or value.target_reason not in VALID_REASONS
        or not _terminal_pair_valid(
            value.target_outcome, value.target_reason
        )
        or released != (value.lease_sha256 != ZERO_DIGEST)
        or released != (value.backend_object_set_sha256 != ZERO_DIGEST)
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
        or value.recovery_sha256 == ZERO_DIGEST
        or value.recovery_sha256 != recovery_root(value)
    ):
        raise ContractError("invalid allocation recovery ticket")


def terminal_root(value: AllocationTerminalReceiptV1) -> Digest:
    return _hash(
        TERMINAL_DOMAIN,
        (
            _le(
                value.abi_version,
                value.outcome,
                value.reason,
                value.coordinator_epoch,
                value.slot_index,
                value.generation,
            ),
            _digest(value.authority_sha256),
            _digest(value.request_sha256),
            _digest(value.admission_sha256),
            _digest(value.lease_sha256),
            _digest(value.backend_object_set_sha256),
            _digest(value.parent_receipt_sha256),
            _digest(value.child_lease_sha256),
            _le(value.returned_device_bytes),
        ),
    )


def make_terminal(
    admission: AllocationAdmissionV1,
    request: AllocationRequestV1,
    outcome: int,
    reason: int,
    lease: Optional[DeviceAllocationLeaseV1] = None,
) -> AllocationTerminalReceiptV1:
    released = outcome == OUTCOME_RELEASED
    if released != (lease is not None):
        raise ContractError("released terminal requires an exact lease")
    result = AllocationTerminalReceiptV1(
        outcome=outcome,
        reason=reason,
        coordinator_epoch=admission.coordinator_epoch,
        slot_index=admission.slot_index,
        generation=admission.generation,
        authority_sha256=admission.authority_sha256,
        request_sha256=request.request_sha256,
        admission_sha256=admission.admission_sha256,
        lease_sha256=lease.lease_sha256 if lease else ZERO_DIGEST,
        backend_object_set_sha256=(
            lease.backend_object_set_sha256 if lease else ZERO_DIGEST
        ),
        parent_receipt_sha256=admission.parent_receipt_sha256,
        child_lease_sha256=admission.child_lease_sha256,
        returned_device_bytes=request.total_device_bytes,
    )
    result = replace(result, terminal_sha256=terminal_root(result))
    validate_terminal(result)
    return result


def validate_terminal(value: AllocationTerminalReceiptV1) -> None:
    _u32(value.slot_index)
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
        value.child_lease_sha256,
        value.terminal_sha256,
    )
    for root in roots:
        _digest(root)
    released = value.outcome == OUTCOME_RELEASED
    if (
        value.abi_version != TERMINAL_ABI
        or value.outcome not in VALID_OUTCOMES
        or value.reason not in VALID_REASONS
        or not _terminal_pair_valid(value.outcome, value.reason)
        or value.coordinator_epoch == 0
        or value.generation == 0
        or value.authority_sha256 == ZERO_DIGEST
        or value.request_sha256 == ZERO_DIGEST
        or value.admission_sha256 == ZERO_DIGEST
        or value.parent_receipt_sha256 == ZERO_DIGEST
        or value.child_lease_sha256 == ZERO_DIGEST
        or value.returned_device_bytes == 0
        or released != (value.lease_sha256 != ZERO_DIGEST)
        or released != (value.backend_object_set_sha256 != ZERO_DIGEST)
        or value.terminal_sha256 == ZERO_DIGEST
        or value.terminal_sha256 != terminal_root(value)
    ):
        raise ContractError("invalid allocation terminal receipt")


class ReferenceFakeBackend:
    """Deterministic fake object registry used only by the reference campaign."""

    def __init__(self, authority: AllocationAuthorityV1) -> None:
        validate_authority(authority)
        self.authority = authority
        self.next_generation = 1
        self.used_bytes = 0
        self._objects: Dict[
            Tuple[Digest, int],
            Tuple[int, BackendObjectV1, AllocationCallV1],
        ] = {}
        self._active_admission_sha256 = ZERO_DIGEST
        self._active_ordinals = set()  # type: set[int]
        self._fail_free_binding = None  # type: Optional[Digest]

    @property
    def live_objects(self) -> int:
        return len(self._objects)

    def fail_next_free_for(self, binding_sha256: Digest) -> None:
        self._fail_free_binding = _digest(binding_sha256)

    def allocate(self, call: AllocationCallV1) -> BackendObjectV1:
        validate_allocation_call(call)
        if call.authority_sha256 != self.authority.authority_sha256:
            raise ContractError("foreign allocator authority")
        expected = make_fake_quote(
            self.authority, call.binding_sha256, call.requested_bytes
        )
        if (
            call.charged_bytes != expected.charged_bytes
            or call.quote_sha256 != expected.quote_sha256
        ):
            raise ContractError("quote replay mismatch")
        if (
            self._active_admission_sha256 != ZERO_DIGEST
            and self._active_admission_sha256 != call.admission_sha256
        ):
            raise ContractError("another materialized lease is active")
        if call.ordinal in self._active_ordinals:
            raise ContractError("allocation ordinal is already live")
        if len(self._objects) >= self.authority.maximum_live_objects:
            raise ContractError("fake object capacity exceeded")
        next_used = _add_u64(self.used_bytes, call.charged_bytes)
        if next_used > self.authority.max_total_device_bytes:
            raise ContractError("fake byte capacity exceeded")
        slot_index = next(
            index
            for index in range(self.authority.maximum_live_objects)
            if all(current[0] != index for current in self._objects.values())
        )
        generation = self.next_generation
        if generation == 0 or generation == U64_MAX:
            raise ContractError("fake generation exhausted")
        self.next_generation += 1
        identity = fake_object_identity(
            self.authority, slot_index, generation, call.call_sha256
        )
        item = make_backend_object(call, identity, generation)
        self._objects[(identity, generation)] = (slot_index, item, call)
        self._active_admission_sha256 = call.admission_sha256
        self._active_ordinals.add(call.ordinal)
        self.used_bytes = next_used
        return item

    def free(self, item: BackendObjectV1) -> None:
        key = (
            item.backend_object_sha256,
            item.backend_object_generation,
        )
        stored = self._objects.get(key)
        if (
            stored is None
            or stored[1].allocation_call_sha256
            != item.allocation_call_sha256
        ):
            raise StaleHandle("backend object is stale")
        if self._fail_free_binding == stored[1].binding_sha256:
            self._fail_free_binding = None
            raise InjectedFreeFailure("injected free failure")
        self.used_bytes -= stored[1].allocated_bytes
        self._active_ordinals.remove(stored[2].ordinal)
        del self._objects[key]
        if not self._objects:
            self._active_admission_sha256 = ZERO_DIGEST


@dataclass
class _LiveState:
    admission: AllocationAdmissionV1
    child: ResourceChildLeaseV1
    calls: List[AllocationCallV1]
    objects: List[BackendObjectV1]
    lease: Optional[DeviceAllocationLeaseV1]
    target_outcome: int = OUTCOME_CANCELLED
    target_reason: int = REASON_EXPLICIT_CANCELLATION
    recovery_generation: int = 0
    state: str = "admitted"


class ReferenceCoordinator:
    """One-slot synchronous model for stale, cleanup, and recovery semantics."""

    def __init__(
        self,
        coordinator_epoch: int,
        authority: AllocationAuthorityV1,
        request: AllocationRequestV1,
        selection: SelectionBindingV1,
        parent: ResourceReceiptV1,
        manifest: AllocationManifestV1,
        entries: Sequence[AllocationEntryV1],
        backend: ReferenceFakeBackend,
    ) -> None:
        _u64(coordinator_epoch)
        if coordinator_epoch == 0:
            raise ContractError("zero coordinator epoch")
        validate_request(
            request, authority, selection, parent, manifest, entries
        )
        self.epoch = coordinator_epoch
        self.authority = authority
        self.request = request
        self.selection = selection
        self.parent = parent
        self.manifest = manifest
        self.entries = tuple(entries)
        self.backend = backend
        self.next_generation = 1
        self.next_child_generation = 1
        self.charged_device_bytes = 0
        self._live = None  # type: Optional[_LiveState]

    def admit(self) -> AllocationAdmissionV1:
        if self._live is not None:
            raise InvalidTransition("coordinator slot is occupied")
        for entry in self.entries:
            if make_fake_quote(
                self.authority,
                entry.binding_sha256,
                entry.requested_bytes,
            ) != _quote_from_entry(self.authority, entry):
                raise ContractError("live quote replay mismatch")
        generation = self.next_generation
        child_generation = self.next_child_generation
        if generation == U64_MAX or child_generation == U64_MAX:
            raise ContractError("generation exhausted")
        self.next_generation += 1
        self.next_child_generation += 1
        claim = ClaimV1(device_bytes=self.request.total_device_bytes)
        child = open_resource_child(
            self.parent,
            allocation_child_key(
                self.epoch, 0, generation, self.request.request_sha256
            ),
            child_generation,
            claim,
            claim,
        )
        admission = make_admission(
            self.epoch,
            0,
            generation,
            self.authority,
            self.request,
            child,
        )
        self.charged_device_bytes = self.request.total_device_bytes
        self._live = _LiveState(admission, child, [], [], None)
        return admission

    def cancel(
        self, admission: AllocationAdmissionV1
    ) -> AllocationTerminalReceiptV1:
        live = self._require_admission(admission)
        terminal = make_terminal(
            live.admission,
            self.request,
            OUTCOME_CANCELLED,
            REASON_EXPLICIT_CANCELLATION,
        )
        self._finish()
        return terminal

    def materialize(
        self, admission: AllocationAdmissionV1
    ) -> DeviceAllocationLeaseV1:
        live = self._require_admission(admission)
        for ordinal, entry in enumerate(self.entries):
            call = make_allocation_call(
                self.authority, admission, ordinal, entry
            )
            live.calls.append(call)
            live.objects.append(self.backend.allocate(call))
        object_set = make_object_set(admission, live.calls, live.objects)
        lease = make_lease(admission, self.request, object_set)
        live.lease = lease
        live.state = "live"
        return lease

    def release(
        self, lease: DeviceAllocationLeaseV1
    ) -> Tuple[Optional[AllocationTerminalReceiptV1], Optional[AllocationRecoveryV1]]:
        live = self._live
        if (
            live is None
            or live.state != "live"
            or live.lease != lease
        ):
            raise StaleHandle("allocation lease is stale")
        live.target_outcome = OUTCOME_RELEASED
        live.target_reason = REASON_NORMAL_RELEASE
        return self._cleanup(live)

    def retry_recovery(
        self, recovery: AllocationRecoveryV1
    ) -> Tuple[Optional[AllocationTerminalReceiptV1], Optional[AllocationRecoveryV1]]:
        live = self._live
        if (
            live is None
            or live.state != "recovery"
            or self._current_recovery(live) != recovery
        ):
            raise StaleHandle("allocation recovery ticket is stale")
        return self._cleanup(live)

    def current_objects(self) -> Tuple[BackendObjectV1, ...]:
        live = self._live
        return tuple(live.objects) if live else ()

    def current_calls(self) -> Tuple[AllocationCallV1, ...]:
        live = self._live
        return tuple(live.calls) if live else ()

    def _require_admission(
        self, admission: AllocationAdmissionV1
    ) -> _LiveState:
        live = self._live
        if (
            live is None
            or live.state != "admitted"
            or live.admission != admission
        ):
            raise StaleHandle("allocation admission is stale")
        return live

    def _cleanup(
        self, live: _LiveState
    ) -> Tuple[Optional[AllocationTerminalReceiptV1], Optional[AllocationRecoveryV1]]:
        failed = False
        for item in reversed(live.objects):
            key = (
                item.backend_object_sha256,
                item.backend_object_generation,
            )
            if key not in self.backend._objects:
                continue
            try:
                self.backend.free(item)
            except InjectedFreeFailure:
                failed = True
        if failed:
            live.state = "recovery"
            live.recovery_generation = min(
                U64_MAX, live.recovery_generation + 1
            )
            return None, self._current_recovery(live)
        terminal = make_terminal(
            live.admission,
            self.request,
            live.target_outcome,
            live.target_reason,
            live.lease if live.target_outcome == OUTCOME_RELEASED else None,
        )
        self._finish()
        return terminal, None

    def _current_recovery(
        self, live: _LiveState
    ) -> AllocationRecoveryV1:
        outstanding = []
        for ordinal, (call, item) in enumerate(
            zip(live.calls, live.objects)
        ):
            key = (
                item.backend_object_sha256,
                item.backend_object_generation,
            )
            if key in self.backend._objects:
                outstanding.append((ordinal, call, item))
        return make_recovery(
            self.epoch,
            live.admission.slot_index,
            live.admission.generation,
            live.recovery_generation,
            self.authority.authority_sha256,
            live.admission.admission_sha256,
            live.lease.lease_sha256 if live.lease else ZERO_DIGEST,
            (
                live.lease.backend_object_set_sha256
                if live.lease
                else ZERO_DIGEST
            ),
            live.target_outcome,
            live.target_reason,
            outstanding,
        )

    def _finish(self) -> None:
        self.charged_device_bytes = 0
        self._live = None


@dataclass(frozen=True)
class AllocationFixtureV1:
    selection: SelectionBindingV1
    authority: AllocationAuthorityV1
    entries: Tuple[AllocationEntryV1, ...]
    manifest: AllocationManifestV1
    parent: ResourceReceiptV1
    request: AllocationRequestV1


def make_fixture() -> AllocationFixtureV1:
    """Construct the fixed three-allocation cross-language fixture."""

    # Frozen projection from the independently validated device-selection
    # fixture.  Only its evidence boundary enters this allocation oracle.
    selection = SelectionBindingV1(
        receipt_sha256=bytes.fromhex(
            "561a5b05d02d933773147d26b3686b84"
            "5900ed8896a4254f27f3a3bfdeb19034"
        ),
        requirement_sha256=bytes.fromhex(
            "8915b184332b4fbfbceb328d516814e9"
            "111c31993e185e709c7827246ac82a19"
        ),
        selected_capability_sha256=bytes.fromhex(
            "049c2bd29030d4aa2ef6a4716ec4556f"
            "6c54ffe9e0cea5ce66796ab4f64f34c5"
        ),
        selected_entry_sha256=bytes.fromhex(
            "c146a8879a1004bad5ac4f9e8854b0f"
            "3afd1117c7d3c38771578845d3975041c"
        ),
        selected_discovery_epoch=20,
        selected_device_class=DEVICE_ACCELERATOR,
        fallback_used=0,
        required_feature_bits=FEATURE_ALLOCATION,
        largest_single_allocation_bytes=4096,
        total_device_bytes=8192,
        queue_slots=1,
        selected_max_single_allocation_bytes=4096,
        selected_max_total_device_bytes=8192,
        selected_max_queue_slots=1,
    )
    authority = seal_authority(
        AllocationAuthorityV1(
            authority_epoch=77,
            maximum_leases=1,
            maximum_live_objects=3,
            allocation_granularity_bytes=1024,
            max_single_allocation_bytes=4096,
            max_total_device_bytes=8192,
            max_queue_slots=1,
            selected_discovery_epoch=selection.selected_discovery_epoch,
            selected_capability_sha256=(
                selection.selected_capability_sha256
            ),
            selected_entry_sha256=selection.selected_entry_sha256,
            backend_authority_sha256=digest_v1(
                b"fake allocation authority"
            ),
        )
    )
    raw = (
        (digest_v1(b"activation allocation"), 1000),
        (digest_v1(b"kv allocation"), 3000),
        (digest_v1(b"weight allocation"), 4000),
    )
    built = []
    for binding, requested in raw:
        quote = make_fake_quote(authority, binding, requested)
        built.append(
            AllocationEntryV1(
                binding_sha256=binding,
                requested_bytes=requested,
                charged_bytes=quote.charged_bytes,
                quote_sha256=quote.quote_sha256,
            )
        )
    entries = tuple(sorted(built, key=lambda item: item.binding_sha256))
    manifest = seal_manifest(entries)
    parent = seal_resource_receipt(
        bank_epoch=41,
        slot_index=0,
        generation=1,
        owner_key=9001,
        claim=ClaimV1(capsule_bytes=64, queue_slots=1),
    )
    request = make_request(
        61,
        digest_v1(b"allocation request owner"),
        authority,
        selection,
        parent,
        manifest,
        entries,
    )
    return AllocationFixtureV1(
        selection, authority, entries, manifest, parent, request
    )
