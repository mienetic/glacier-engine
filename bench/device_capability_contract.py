"""Independent oracle for the portable device-capability contract.

This module intentionally does not parse Zig sources or load Glacier symbols.
It reproduces the fixed V1 vocabulary, canonical SHA-256 roots, validation, and
selection rules with Python's standard library only.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, replace
from typing import Sequence


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
MAXIMUM_INVENTORY_ENTRIES = 32

CAPABILITY_ABI = 0x4744_4341_0000_0001
INVENTORY_ENTRY_ABI = 0x4744_4945_0000_0001
REQUIREMENT_ABI = 0x4744_5251_0000_0001
SELECTION_RECEIPT_ABI = 0x4744_5352_0000_0001

CAPABILITY_DOMAIN = b"glacier-device-capability-v1\x00"
INVENTORY_ENTRY_DOMAIN = b"glacier-device-inventory-entry-v1\x00"
INVENTORY_DOMAIN = b"glacier-device-inventory-v1\x00"
REQUIREMENT_DOMAIN = b"glacier-device-requirement-v1\x00"
SELECTION_DOMAIN = b"glacier-device-selection-v1\x00"

BACKEND_CPU = 1
BACKEND_METAL = 2
BACKEND_PORTABLE_COMPUTE = 3
BACKEND_PROVIDER = 4
BACKEND_KINDS = frozenset(
    (
        BACKEND_CPU,
        BACKEND_METAL,
        BACKEND_PORTABLE_COMPUTE,
        BACKEND_PROVIDER,
    )
)

DEVICE_CPU = 1
DEVICE_ACCELERATOR = 2
DEVICE_CLASSES = frozenset((DEVICE_CPU, DEVICE_ACCELERATOR))

INVENTORY_PRESENT = 1
INVENTORY_UNAVAILABLE = 2
INVENTORY_LOST = 3
INVENTORY_STATES = frozenset(
    (INVENTORY_PRESENT, INVENTORY_UNAVAILABLE, INVENTORY_LOST)
)

FALLBACK_FORBIDDEN = 1
FALLBACK_EXPLICIT_CPU = 2
FALLBACK_POLICIES = frozenset(
    (FALLBACK_FORBIDDEN, FALLBACK_EXPLICIT_CPU)
)

PROFILE_DEQUANTIZE_INT4_F16 = 1 << 0
PROFILE_MATMUL_F16_BOUNDED = 1 << 1
PROFILE_MATVEC_INT4_F32_BOUNDED = 1 << 2
ALL_OPERATION_PROFILE_BITS = (
    PROFILE_DEQUANTIZE_INT4_F16
    | PROFILE_MATMUL_F16_BOUNDED
    | PROFILE_MATVEC_INT4_F32_BOUNDED
)

OPERATOR_DEQUANTIZE_INT4 = 1 << 0
OPERATOR_MATMUL_F16 = 1 << 1
OPERATOR_MATVEC_INT4_F32 = 1 << 2
ALL_OPERATOR_BITS = (
    OPERATOR_DEQUANTIZE_INT4
    | OPERATOR_MATMUL_F16
    | OPERATOR_MATVEC_INT4_F32
)

ELEMENT_PACKED_INT4 = 1 << 0
ELEMENT_FLOAT16 = 1 << 1
ELEMENT_FLOAT32 = 1 << 2
ALL_ELEMENT_TYPE_BITS = (
    ELEMENT_PACKED_INT4 | ELEMENT_FLOAT16 | ELEMENT_FLOAT32
)

NUMERICAL_EXACT_INTEGER = 1 << 0
NUMERICAL_BOUNDED_FLOAT32 = 1 << 1
NUMERICAL_BOUNDED_FLOAT16 = 1 << 2
ALL_NUMERICAL_POLICY_BITS = (
    NUMERICAL_EXACT_INTEGER
    | NUMERICAL_BOUNDED_FLOAT32
    | NUMERICAL_BOUNDED_FLOAT16
)

FEATURE_ALLOCATION = 1 << 0
FEATURE_DISPATCH = 1 << 1
FEATURE_COMPLETION_FENCE = 1 << 2
FEATURE_PERSISTENT_WEIGHTS = 1 << 3
FEATURE_COMMAND_BUFFER_TIME = 1 << 4
FEATURE_ALLOCATED_BYTES_OBSERVATION = 1 << 5
FEATURE_CANCELLATION = 1 << 6
FEATURE_DEVICE_LOSS_SIGNAL = 1 << 7
ALL_FEATURE_BITS = (
    FEATURE_ALLOCATION
    | FEATURE_DISPATCH
    | FEATURE_COMPLETION_FENCE
    | FEATURE_PERSISTENT_WEIGHTS
    | FEATURE_COMMAND_BUFFER_TIME
    | FEATURE_ALLOCATED_BYTES_OBSERVATION
    | FEATURE_CANCELLATION
    | FEATURE_DEVICE_LOSS_SIGNAL
)


class ContractError(ValueError):
    """A capability, inventory, requirement, or selection is invalid."""


class AlreadySealed(ContractError):
    pass


class InvalidCapability(ContractError):
    pass


class InvalidInventoryEntry(ContractError):
    pass


class InvalidRequirement(ContractError):
    pass


class InvalidSelectionReceipt(ContractError):
    pass


class TooManyInventoryEntries(ContractError):
    pass


class DuplicateInventoryEntry(ContractError):
    pass


class DuplicateCapability(ContractError):
    pass


class DuplicateDevice(ContractError):
    pass


class NoCompatibleDevice(ContractError):
    pass


@dataclass(frozen=True)
class DeviceCapabilityV1:
    abi_version: int = CAPABILITY_ABI
    backend_kind: int = BACKEND_METAL
    device_class: int = DEVICE_ACCELERATOR
    operation_profile_bits: int = 0
    operator_bits: int = 0
    element_type_bits: int = 0
    numerical_policy_bits: int = 0
    feature_bits: int = 0
    max_single_allocation_bytes: int = 0
    max_total_device_bytes: int = 0
    max_queue_slots: int = 0
    backend_sha256: Digest = ZERO_DIGEST
    device_sha256: Digest = ZERO_DIGEST
    driver_sha256: Digest = ZERO_DIGEST
    placement_sha256: Digest = ZERO_DIGEST
    capability_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DeviceInventoryEntryV1:
    abi_version: int = INVENTORY_ENTRY_ABI
    discovery_epoch: int = 0
    policy_rank: int = 0
    state: int = INVENTORY_PRESENT
    capability: DeviceCapabilityV1 = DeviceCapabilityV1()
    entry_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DeviceRequirementV1:
    abi_version: int = REQUIREMENT_ABI
    plan_sha256: Digest = ZERO_DIGEST
    required_device_class: int = DEVICE_ACCELERATOR
    required_operation_profile_bits: int = 0
    required_operator_bits: int = 0
    required_element_type_bits: int = 0
    required_numerical_policy_bits: int = 0
    required_feature_bits: int = 0
    largest_single_allocation_bytes: int = 0
    total_device_bytes: int = 0
    queue_slots: int = 0
    fallback_policy: int = FALLBACK_FORBIDDEN
    pinned_capability_sha256: Digest = ZERO_DIGEST
    requirement_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class DeviceSelectionReceiptV1:
    abi_version: int = SELECTION_RECEIPT_ABI
    inventory_count: int = 0
    compatible_count: int = 0
    selected_discovery_epoch: int = 0
    selected_policy_rank: int = 0
    selected_backend_kind: int = BACKEND_METAL
    selected_device_class: int = DEVICE_ACCELERATOR
    fallback_used: int = 0
    requirement_sha256: Digest = ZERO_DIGEST
    inventory_sha256: Digest = ZERO_DIGEST
    selected_capability_sha256: Digest = ZERO_DIGEST
    selected_entry_sha256: Digest = ZERO_DIGEST
    receipt_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class SelectionV1:
    selected_index: int
    receipt: DeviceSelectionReceiptV1


def digest_v1(value: bytes | str) -> Digest:
    if isinstance(value, str):
        value = value.encode("utf-8")
    return hashlib.sha256(value).digest()


def profile_operator_bits(profiles: int) -> int:
    result = 0
    if profiles & PROFILE_DEQUANTIZE_INT4_F16:
        result |= OPERATOR_DEQUANTIZE_INT4
    if profiles & PROFILE_MATMUL_F16_BOUNDED:
        result |= OPERATOR_MATMUL_F16
    if profiles & PROFILE_MATVEC_INT4_F32_BOUNDED:
        result |= OPERATOR_MATVEC_INT4_F32
    return result


def profile_element_type_bits(profiles: int) -> int:
    result = 0
    if profiles & PROFILE_DEQUANTIZE_INT4_F16:
        result |= ELEMENT_PACKED_INT4 | ELEMENT_FLOAT16
    if profiles & PROFILE_MATMUL_F16_BOUNDED:
        result |= ELEMENT_FLOAT16
    if profiles & PROFILE_MATVEC_INT4_F32_BOUNDED:
        result |= ELEMENT_PACKED_INT4 | ELEMENT_FLOAT32
    return result


def profile_numerical_policy_bits(profiles: int) -> int:
    result = 0
    if profiles & PROFILE_DEQUANTIZE_INT4_F16:
        result |= NUMERICAL_BOUNDED_FLOAT16
    if profiles & PROFILE_MATMUL_F16_BOUNDED:
        result |= NUMERICAL_BOUNDED_FLOAT16
    if profiles & PROFILE_MATVEC_INT4_F32_BOUNDED:
        result |= NUMERICAL_BOUNDED_FLOAT32
    return result


def capability_root(value: DeviceCapabilityV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(CAPABILITY_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.backend_kind,
        value.device_class,
        value.operation_profile_bits,
        value.operator_bits,
        value.element_type_bits,
        value.numerical_policy_bits,
        value.feature_bits,
        value.max_single_allocation_bytes,
        value.max_total_device_bytes,
        value.max_queue_slots,
    )
    for identity in (
        value.backend_sha256,
        value.device_sha256,
        value.driver_sha256,
        value.placement_sha256,
    ):
        digest.update(_digest(identity))
    return digest.digest()


def seal_capability(value: DeviceCapabilityV1) -> DeviceCapabilityV1:
    if value.capability_sha256 != ZERO_DIGEST:
        raise AlreadySealed("capability")
    result = replace(value, abi_version=CAPABILITY_ABI)
    _validate_capability_shape(result)
    result = replace(result, capability_sha256=capability_root(result))
    validate_capability(result)
    return result


def validate_capability(value: DeviceCapabilityV1) -> None:
    _validate_capability_shape(value)
    if (
        value.capability_sha256 == ZERO_DIGEST
        or _digest(value.capability_sha256) != capability_root(value)
    ):
        raise InvalidCapability("capability root")


def _validate_capability_shape(value: DeviceCapabilityV1) -> None:
    try:
        _u64s(
            value.abi_version,
            value.backend_kind,
            value.device_class,
            value.operation_profile_bits,
            value.operator_bits,
            value.element_type_bits,
            value.numerical_policy_bits,
            value.feature_bits,
            value.max_single_allocation_bytes,
            value.max_total_device_bytes,
            value.max_queue_slots,
        )
        for identity in (
            value.backend_sha256,
            value.device_sha256,
            value.driver_sha256,
            value.placement_sha256,
            value.capability_sha256,
        ):
            _digest(identity)
    except (TypeError, ValueError) as error:
        raise InvalidCapability("field width") from error

    if (
        value.abi_version != CAPABILITY_ABI
        or value.backend_kind not in BACKEND_KINDS
        or value.device_class not in DEVICE_CLASSES
        or value.operation_profile_bits == 0
        or value.operation_profile_bits & ~ALL_OPERATION_PROFILE_BITS
        or value.operator_bits == 0
        or value.operator_bits & ~ALL_OPERATOR_BITS
        or value.element_type_bits == 0
        or value.element_type_bits & ~ALL_ELEMENT_TYPE_BITS
        or value.numerical_policy_bits == 0
        or value.numerical_policy_bits & ~ALL_NUMERICAL_POLICY_BITS
        or value.feature_bits == 0
        or value.feature_bits & ~ALL_FEATURE_BITS
        or value.backend_sha256 == ZERO_DIGEST
        or value.device_sha256 == ZERO_DIGEST
        or value.placement_sha256 == ZERO_DIGEST
        or (value.backend_kind == BACKEND_CPU)
        != (value.device_class == DEVICE_CPU)
    ):
        raise InvalidCapability("shape")

    if (
        value.operator_bits
        != profile_operator_bits(value.operation_profile_bits)
        or value.element_type_bits
        != profile_element_type_bits(value.operation_profile_bits)
        or value.numerical_policy_bits
        != profile_numerical_policy_bits(value.operation_profile_bits)
    ):
        raise InvalidCapability("operation profile aggregates")

    if (
        value.max_single_allocation_bytes
        and value.max_total_device_bytes
        and value.max_single_allocation_bytes
        > value.max_total_device_bytes
    ):
        raise InvalidCapability("allocation ceilings")

    dependencies = (
        (FEATURE_DISPATCH, FEATURE_ALLOCATION),
        (FEATURE_COMPLETION_FENCE, FEATURE_DISPATCH),
        (FEATURE_PERSISTENT_WEIGHTS, FEATURE_ALLOCATION),
        (FEATURE_COMMAND_BUFFER_TIME, FEATURE_COMPLETION_FENCE),
        (FEATURE_ALLOCATED_BYTES_OBSERVATION, FEATURE_ALLOCATION),
        (FEATURE_CANCELLATION, FEATURE_DISPATCH),
        (FEATURE_DEVICE_LOSS_SIGNAL, FEATURE_DISPATCH),
    )
    for feature, prerequisite in dependencies:
        if value.feature_bits & feature and not value.feature_bits & prerequisite:
            raise InvalidCapability("feature dependency")


def inventory_entry_root(value: DeviceInventoryEntryV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(INVENTORY_ENTRY_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.discovery_epoch,
        value.policy_rank,
        value.state,
    )
    digest.update(_digest(value.capability.capability_sha256))
    return digest.digest()


def seal_inventory_entry(
    value: DeviceInventoryEntryV1,
) -> DeviceInventoryEntryV1:
    if value.entry_sha256 != ZERO_DIGEST:
        raise AlreadySealed("inventory entry")
    result = replace(value, abi_version=INVENTORY_ENTRY_ABI)
    _validate_inventory_entry_shape(result)
    result = replace(result, entry_sha256=inventory_entry_root(result))
    validate_inventory_entry(result)
    return result


def validate_inventory_entry(value: DeviceInventoryEntryV1) -> None:
    _validate_inventory_entry_shape(value)
    if (
        value.entry_sha256 == ZERO_DIGEST
        or _digest(value.entry_sha256) != inventory_entry_root(value)
    ):
        raise InvalidInventoryEntry("entry root")


def _validate_inventory_entry_shape(value: DeviceInventoryEntryV1) -> None:
    try:
        _u64s(
            value.abi_version,
            value.discovery_epoch,
            value.policy_rank,
            value.state,
        )
        _digest(value.entry_sha256)
    except (TypeError, ValueError) as error:
        raise InvalidInventoryEntry("field width") from error
    if (
        value.abi_version != INVENTORY_ENTRY_ABI
        or value.discovery_epoch == 0
        or value.state not in INVENTORY_STATES
    ):
        raise InvalidInventoryEntry("shape")
    try:
        validate_capability(value.capability)
    except InvalidCapability as error:
        raise InvalidInventoryEntry("capability") from error


def requirement_root(value: DeviceRequirementV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(REQUIREMENT_DOMAIN)
    _update_u64(digest, value.abi_version)
    digest.update(_digest(value.plan_sha256))
    _update_u64(
        digest,
        value.required_device_class,
        value.required_operation_profile_bits,
        value.required_operator_bits,
        value.required_element_type_bits,
        value.required_numerical_policy_bits,
        value.required_feature_bits,
        value.largest_single_allocation_bytes,
        value.total_device_bytes,
        value.queue_slots,
        value.fallback_policy,
    )
    digest.update(_digest(value.pinned_capability_sha256))
    return digest.digest()


def seal_requirement(value: DeviceRequirementV1) -> DeviceRequirementV1:
    if value.requirement_sha256 != ZERO_DIGEST:
        raise AlreadySealed("requirement")
    result = replace(value, abi_version=REQUIREMENT_ABI)
    _validate_requirement_shape(result)
    result = replace(result, requirement_sha256=requirement_root(result))
    validate_requirement(result)
    return result


def validate_requirement(value: DeviceRequirementV1) -> None:
    _validate_requirement_shape(value)
    if (
        value.requirement_sha256 == ZERO_DIGEST
        or _digest(value.requirement_sha256) != requirement_root(value)
    ):
        raise InvalidRequirement("requirement root")


def _validate_requirement_shape(value: DeviceRequirementV1) -> None:
    try:
        _u64s(
            value.abi_version,
            value.required_device_class,
            value.required_operation_profile_bits,
            value.required_operator_bits,
            value.required_element_type_bits,
            value.required_numerical_policy_bits,
            value.required_feature_bits,
            value.largest_single_allocation_bytes,
            value.total_device_bytes,
            value.queue_slots,
            value.fallback_policy,
        )
        _digest(value.plan_sha256)
        _digest(value.pinned_capability_sha256)
        _digest(value.requirement_sha256)
    except (TypeError, ValueError) as error:
        raise InvalidRequirement("field width") from error

    if (
        value.abi_version != REQUIREMENT_ABI
        or value.plan_sha256 == ZERO_DIGEST
        or value.required_device_class not in DEVICE_CLASSES
        or value.required_operation_profile_bits == 0
        or value.required_operation_profile_bits
        & ~ALL_OPERATION_PROFILE_BITS
        or value.required_operator_bits == 0
        or value.required_operator_bits & ~ALL_OPERATOR_BITS
        or value.required_element_type_bits == 0
        or value.required_element_type_bits & ~ALL_ELEMENT_TYPE_BITS
        or value.required_numerical_policy_bits == 0
        or value.required_numerical_policy_bits
        & ~ALL_NUMERICAL_POLICY_BITS
        or value.required_feature_bits & ~ALL_FEATURE_BITS
        or value.total_device_bytes == 0
        or value.largest_single_allocation_bytes
        > value.total_device_bytes
        or value.queue_slots == 0
        or value.fallback_policy not in FALLBACK_POLICIES
    ):
        raise InvalidRequirement("shape")
    if (
        value.required_operator_bits
        != profile_operator_bits(value.required_operation_profile_bits)
        or value.required_element_type_bits
        != profile_element_type_bits(
            value.required_operation_profile_bits
        )
        or value.required_numerical_policy_bits
        != profile_numerical_policy_bits(
            value.required_operation_profile_bits
        )
    ):
        raise InvalidRequirement("operation profile aggregates")
    if (
        value.fallback_policy == FALLBACK_EXPLICIT_CPU
        and value.required_device_class != DEVICE_ACCELERATOR
    ):
        raise InvalidRequirement("fallback class")
    if (
        value.pinned_capability_sha256 != ZERO_DIGEST
        and value.fallback_policy != FALLBACK_FORBIDDEN
    ):
        raise InvalidRequirement("pinned fallback")


def validate_inventory(entries: Sequence[DeviceInventoryEntryV1]) -> None:
    if not entries:
        raise NoCompatibleDevice("empty inventory")
    if len(entries) > MAXIMUM_INVENTORY_ENTRIES:
        raise TooManyInventoryEntries(len(entries))
    for index, entry in enumerate(entries):
        validate_inventory_entry(entry)
        for previous in entries[:index]:
            if entry.entry_sha256 == previous.entry_sha256:
                raise DuplicateInventoryEntry(entry.entry_sha256.hex())
            if (
                entry.capability.capability_sha256
                == previous.capability.capability_sha256
            ):
                raise DuplicateCapability(
                    entry.capability.capability_sha256.hex()
                )
            if (
                entry.capability.backend_sha256
                == previous.capability.backend_sha256
                and entry.capability.device_sha256
                == previous.capability.device_sha256
            ):
                raise DuplicateDevice(entry.capability.device_sha256.hex())


def inventory_root(entries: Sequence[DeviceInventoryEntryV1]) -> Digest:
    validate_inventory(entries)
    digest = hashlib.sha256()
    digest.update(INVENTORY_DOMAIN)
    _update_u64(digest, len(entries))
    for root in sorted(entry.entry_sha256 for entry in entries):
        digest.update(root)
    return digest.digest()


def capability_satisfies(
    capability: DeviceCapabilityV1,
    requirement: DeviceRequirementV1,
) -> bool:
    if (
        requirement.required_operation_profile_bits
        & ~capability.operation_profile_bits
        or requirement.required_operator_bits & ~capability.operator_bits
        or requirement.required_element_type_bits
        & ~capability.element_type_bits
        or requirement.required_numerical_policy_bits
        & ~capability.numerical_policy_bits
        or requirement.required_feature_bits & ~capability.feature_bits
    ):
        return False
    if requirement.largest_single_allocation_bytes and (
        capability.max_single_allocation_bytes == 0
        or capability.max_single_allocation_bytes
        < requirement.largest_single_allocation_bytes
    ):
        return False
    if (
        capability.max_total_device_bytes == 0
        or capability.max_total_device_bytes
        < requirement.total_device_bytes
        or capability.max_queue_slots == 0
        or capability.max_queue_slots < requirement.queue_slots
    ):
        return False
    return True


def select_device(
    requirement: DeviceRequirementV1,
    entries: Sequence[DeviceInventoryEntryV1],
) -> SelectionV1:
    validate_requirement(requirement)
    inventory_sha256 = inventory_root(entries)

    if requirement.pinned_capability_sha256 != ZERO_DIGEST:
        for index, entry in enumerate(entries):
            if (
                entry.capability.capability_sha256
                != requirement.pinned_capability_sha256
            ):
                continue
            if (
                entry.state != INVENTORY_PRESENT
                or entry.capability.device_class
                != requirement.required_device_class
                or not capability_satisfies(entry.capability, requirement)
            ):
                raise NoCompatibleDevice("pinned capability is incompatible")
            return _make_selection(
                requirement,
                entries,
                inventory_sha256,
                index,
                compatible_count=1,
                fallback_used=False,
            )
        raise NoCompatibleDevice("pinned capability is absent")

    exact = _compatible_indices(
        requirement, entries, requirement.required_device_class
    )
    if exact:
        selected_index = min(exact, key=lambda index: _entry_key(entries[index]))
        return _make_selection(
            requirement,
            entries,
            inventory_sha256,
            selected_index,
            compatible_count=len(exact),
            fallback_used=False,
        )

    if (
        requirement.fallback_policy != FALLBACK_EXPLICIT_CPU
        or requirement.required_device_class != DEVICE_ACCELERATOR
    ):
        raise NoCompatibleDevice("fallback is forbidden")
    fallback = _compatible_indices(requirement, entries, DEVICE_CPU)
    if not fallback:
        raise NoCompatibleDevice("no compatible CPU fallback")
    selected_index = min(
        fallback, key=lambda index: _entry_key(entries[index])
    )
    return _make_selection(
        requirement,
        entries,
        inventory_sha256,
        selected_index,
        compatible_count=len(fallback),
        fallback_used=True,
    )


def selection_receipt_root(value: DeviceSelectionReceiptV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(SELECTION_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.inventory_count,
        value.compatible_count,
        value.selected_discovery_epoch,
        value.selected_policy_rank,
        value.selected_backend_kind,
        value.selected_device_class,
        value.fallback_used,
    )
    for root in (
        value.requirement_sha256,
        value.inventory_sha256,
        value.selected_capability_sha256,
        value.selected_entry_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def validate_selection_receipt(
    value: DeviceSelectionReceiptV1,
    requirement: DeviceRequirementV1,
    entries: Sequence[DeviceInventoryEntryV1],
) -> None:
    _validate_selection_receipt_shape(value)
    try:
        expected = select_device(requirement, entries).receipt
    except ContractError as error:
        raise InvalidSelectionReceipt("selection cannot replay") from error
    if value != expected:
        raise InvalidSelectionReceipt("receipt substitution")


def _compatible_indices(
    requirement: DeviceRequirementV1,
    entries: Sequence[DeviceInventoryEntryV1],
    device_class: int,
) -> list[int]:
    return [
        index
        for index, entry in enumerate(entries)
        if entry.state == INVENTORY_PRESENT
        and entry.capability.device_class == device_class
        and capability_satisfies(entry.capability, requirement)
    ]


def _entry_key(entry: DeviceInventoryEntryV1) -> tuple[int, bytes]:
    return entry.policy_rank, entry.capability.capability_sha256


def _make_selection(
    requirement: DeviceRequirementV1,
    entries: Sequence[DeviceInventoryEntryV1],
    inventory_sha256: Digest,
    selected_index: int,
    compatible_count: int,
    fallback_used: bool,
) -> SelectionV1:
    selected = entries[selected_index]
    receipt = DeviceSelectionReceiptV1(
        inventory_count=len(entries),
        compatible_count=compatible_count,
        selected_discovery_epoch=selected.discovery_epoch,
        selected_policy_rank=selected.policy_rank,
        selected_backend_kind=selected.capability.backend_kind,
        selected_device_class=selected.capability.device_class,
        fallback_used=int(fallback_used),
        requirement_sha256=requirement.requirement_sha256,
        inventory_sha256=inventory_sha256,
        selected_capability_sha256=(
            selected.capability.capability_sha256
        ),
        selected_entry_sha256=selected.entry_sha256,
    )
    receipt = replace(receipt, receipt_sha256=selection_receipt_root(receipt))
    _validate_selection_receipt_shape(receipt)
    return SelectionV1(selected_index=selected_index, receipt=receipt)


def _validate_selection_receipt_shape(
    value: DeviceSelectionReceiptV1,
) -> None:
    try:
        _u64s(
            value.abi_version,
            value.inventory_count,
            value.compatible_count,
            value.selected_discovery_epoch,
            value.selected_policy_rank,
            value.selected_backend_kind,
            value.selected_device_class,
            value.fallback_used,
        )
        for root in (
            value.requirement_sha256,
            value.inventory_sha256,
            value.selected_capability_sha256,
            value.selected_entry_sha256,
            value.receipt_sha256,
        ):
            _digest(root)
    except (TypeError, ValueError) as error:
        raise InvalidSelectionReceipt("field width") from error

    if (
        value.abi_version != SELECTION_RECEIPT_ABI
        or value.inventory_count == 0
        or value.inventory_count > MAXIMUM_INVENTORY_ENTRIES
        or value.compatible_count == 0
        or value.compatible_count > value.inventory_count
        or value.selected_discovery_epoch == 0
        or value.selected_backend_kind not in BACKEND_KINDS
        or value.selected_device_class not in DEVICE_CLASSES
        or value.fallback_used not in (0, 1)
        or value.requirement_sha256 == ZERO_DIGEST
        or value.inventory_sha256 == ZERO_DIGEST
        or value.selected_capability_sha256 == ZERO_DIGEST
        or value.selected_entry_sha256 == ZERO_DIGEST
        or value.receipt_sha256 == ZERO_DIGEST
        or value.receipt_sha256 != selection_receipt_root(value)
        or (value.selected_backend_kind == BACKEND_CPU)
        != (value.selected_device_class == DEVICE_CPU)
        or (
            value.fallback_used == 1
            and value.selected_device_class != DEVICE_CPU
        )
    ):
        raise InvalidSelectionReceipt("shape")


def make_fixture_capability(
    backend_kind: int,
    device_class: int,
    name: str,
    operation_profile_bits: int = ALL_OPERATION_PROFILE_BITS,
) -> DeviceCapabilityV1:
    """Build the fixed cross-language-style test capability."""

    features = (
        FEATURE_ALLOCATION | FEATURE_DISPATCH | FEATURE_COMPLETION_FENCE
    )
    return seal_capability(
        DeviceCapabilityV1(
            backend_kind=backend_kind,
            device_class=device_class,
            operation_profile_bits=operation_profile_bits,
            operator_bits=profile_operator_bits(operation_profile_bits),
            element_type_bits=profile_element_type_bits(
                operation_profile_bits
            ),
            numerical_policy_bits=profile_numerical_policy_bits(
                operation_profile_bits
            ),
            feature_bits=features,
            max_single_allocation_bytes=1 << 20,
            max_total_device_bytes=8 << 20,
            max_queue_slots=4,
            backend_sha256=digest_v1(
                "test cpu backend"
                if backend_kind == BACKEND_CPU
                else "test accelerator backend"
            ),
            device_sha256=digest_v1(name),
            driver_sha256=digest_v1("test driver"),
            placement_sha256=digest_v1(
                "test cpu placement"
                if device_class == DEVICE_CPU
                else "test accelerator placement"
            ),
        )
    )


def make_fixture_entry(
    capability: DeviceCapabilityV1,
    epoch: int,
    rank: int,
    state: int = INVENTORY_PRESENT,
) -> DeviceInventoryEntryV1:
    return seal_inventory_entry(
        DeviceInventoryEntryV1(
            discovery_epoch=epoch,
            policy_rank=rank,
            state=state,
            capability=capability,
        )
    )


def make_fixture_requirement(
    fallback_policy: int,
) -> DeviceRequirementV1:
    return seal_requirement(
        DeviceRequirementV1(
            plan_sha256=digest_v1("test execution plan"),
            required_device_class=DEVICE_ACCELERATOR,
            required_operation_profile_bits=(
                PROFILE_MATVEC_INT4_F32_BOUNDED
            ),
            required_operator_bits=OPERATOR_MATVEC_INT4_F32,
            required_element_type_bits=(
                ELEMENT_PACKED_INT4 | ELEMENT_FLOAT32
            ),
            required_numerical_policy_bits=(
                NUMERICAL_BOUNDED_FLOAT32
            ),
            required_feature_bits=(
                FEATURE_ALLOCATION
                | FEATURE_DISPATCH
                | FEATURE_COMPLETION_FENCE
            ),
            largest_single_allocation_bytes=4096,
            total_device_bytes=8192,
            queue_slots=1,
            fallback_policy=fallback_policy,
        )
    )


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
    digest: "hashlib._Hash", *values: int  # type: ignore[name-defined]
) -> None:
    for value in values:
        digest.update(_u64(value))


def _digest(value: Digest) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise ValueError("digest must be exactly 32 bytes")
    return value
