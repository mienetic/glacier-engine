"""Independent oracle for the portable device-lifecycle contract.

This module intentionally does not parse Zig sources or load Glacier symbols.
It reproduces the fixed V1 vocabulary, little-endian SHA-256 transcripts, and
validation rules with Python's standard library plus the independent portable
device-capability oracle.

Lifecycle evidence is descriptive only: it grants no allocation, dispatch,
resource-release, reset, or migration authority.  In particular,
``SOURCE_TEST_INJECTED`` is always ``EVIDENCE_SYNTHETIC`` and can never carry
native command-buffer status fields.  Replay state remains external in a
``SourceCursorV1``: a matching nonzero source instance is mandatory, sequence
gaps are allowed, and only positions newer than the last consumed sequence
validate.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, replace
from typing import Sequence

from bench import device_capability_contract as device


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1

OBSERVATION_ABI = 0x4744_4C4F_0000_0001
TRANSITION_RECEIPT_ABI = 0x4744_4C54_0000_0001
SOURCE_CURSOR_SIZE_BYTES = 40
OBSERVATION_SIZE_BYTES = 280
TRANSITION_RECEIPT_SIZE_BYTES = 272

COMMAND_BUFFER_STATUS_ERROR = 5
COMMAND_BUFFER_ERROR_DOMAIN = 1
COMMAND_BUFFER_DEVICE_REMOVED_ERROR = 11

OBSERVATION_DOMAIN = b"glacier-device-lifecycle-observation-v1\x00"
TRANSITION_RECEIPT_DOMAIN = (
    b"glacier-device-lifecycle-transition-receipt-v1\x00"
)

SOURCE_INITIAL_MEMBERSHIP = 1
SOURCE_ADDED_NOTIFICATION = 2
SOURCE_INVENTORY_ABSENT = 3
SOURCE_REMOVAL_REQUESTED_NOTIFICATION = 4
SOURCE_REMOVED_NOTIFICATION = 5
SOURCE_COMMAND_BUFFER_DEVICE_REMOVED = 6
SOURCE_TEST_INJECTED = 7

EVIDENCE_NATIVE = 1
EVIDENCE_SYNTHETIC = 2

# (evidence class, observed inventory state, exact command error required)
_SOURCE_SEMANTICS = {
    SOURCE_INITIAL_MEMBERSHIP: (
        EVIDENCE_NATIVE,
        device.INVENTORY_PRESENT,
        False,
    ),
    SOURCE_ADDED_NOTIFICATION: (
        EVIDENCE_NATIVE,
        device.INVENTORY_PRESENT,
        False,
    ),
    SOURCE_INVENTORY_ABSENT: (
        EVIDENCE_NATIVE,
        device.INVENTORY_UNAVAILABLE,
        False,
    ),
    SOURCE_REMOVAL_REQUESTED_NOTIFICATION: (
        EVIDENCE_NATIVE,
        device.INVENTORY_UNAVAILABLE,
        False,
    ),
    SOURCE_REMOVED_NOTIFICATION: (
        EVIDENCE_NATIVE,
        device.INVENTORY_LOST,
        False,
    ),
    SOURCE_COMMAND_BUFFER_DEVICE_REMOVED: (
        EVIDENCE_NATIVE,
        device.INVENTORY_LOST,
        True,
    ),
    SOURCE_TEST_INJECTED: (
        EVIDENCE_SYNTHETIC,
        device.INVENTORY_LOST,
        False,
    ),
}


class ContractError(ValueError):
    """A lifecycle observation or transition receipt is invalid."""


class InvalidObservation(ContractError):
    pass


class StaleObservation(ContractError):
    pass


class SourceInstanceChanged(ContractError):
    pass


class InvalidTransitionReceipt(ContractError):
    pass


@dataclass(frozen=True)
class SourceCursorV1:
    source_instance_sha256: Digest = ZERO_DIGEST
    last_sequence: int = 0


@dataclass(frozen=True)
class ObservationV1:
    abi_version: int = OBSERVATION_ABI
    source: int = SOURCE_INITIAL_MEMBERSHIP
    evidence_class: int = EVIDENCE_NATIVE
    observed_state: int = device.INVENTORY_PRESENT
    source_sequence: int = 0
    native_command_status: int = 0
    native_error_domain_kind: int = 0
    native_error_code_bits: int = 0
    prior_discovery_epoch: int = 0
    prior_policy_rank: int = 0
    prior_inventory_count: int = 0
    source_instance_sha256: Digest = ZERO_DIGEST
    prior_inventory_sha256: Digest = ZERO_DIGEST
    prior_entry_sha256: Digest = ZERO_DIGEST
    capability_sha256: Digest = ZERO_DIGEST
    evidence_sha256: Digest = ZERO_DIGEST
    observation_sha256: Digest = ZERO_DIGEST


@dataclass(frozen=True)
class TransitionReceiptV1:
    abi_version: int = TRANSITION_RECEIPT_ABI
    source: int = SOURCE_INVENTORY_ABSENT
    evidence_class: int = EVIDENCE_NATIVE
    prior_state: int = device.INVENTORY_PRESENT
    successor_state: int = device.INVENTORY_UNAVAILABLE
    source_sequence: int = 0
    prior_inventory_count: int = 0
    prior_discovery_epoch: int = 0
    successor_discovery_epoch: int = 0
    policy_rank: int = 0
    prior_inventory_sha256: Digest = ZERO_DIGEST
    prior_entry_sha256: Digest = ZERO_DIGEST
    capability_sha256: Digest = ZERO_DIGEST
    observation_sha256: Digest = ZERO_DIGEST
    successor_entry_sha256: Digest = ZERO_DIGEST
    receipt_sha256: Digest = ZERO_DIGEST


def observation_root(value: ObservationV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(OBSERVATION_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.observed_state,
        value.source_sequence,
        value.native_command_status,
        value.native_error_domain_kind,
        value.native_error_code_bits,
        value.prior_discovery_epoch,
        value.prior_policy_rank,
        value.prior_inventory_count,
    )
    for root in (
        value.source_instance_sha256,
        value.prior_inventory_sha256,
        value.prior_entry_sha256,
        value.capability_sha256,
        value.evidence_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def make_observation(
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    source_instance_sha256: Digest,
    source_sequence: int,
    source: int,
    evidence_sha256: Digest,
    native_command_status: int = 0,
    native_error_domain_kind: int = 0,
    native_error_code_bits: int = 0,
) -> ObservationV1:
    semantics = _SOURCE_SEMANTICS.get(source)
    if semantics is None:
        raise InvalidObservation("unknown source")
    evidence_class, observed_state, _ = semantics
    try:
        inventory_sha256 = device.inventory_root(prior_inventory)
    except device.ContractError as error:
        raise InvalidObservation("prior inventory") from error
    result = ObservationV1(
        source=source,
        evidence_class=evidence_class,
        observed_state=observed_state,
        source_sequence=source_sequence,
        native_command_status=native_command_status,
        native_error_domain_kind=native_error_domain_kind,
        native_error_code_bits=native_error_code_bits,
        prior_discovery_epoch=prior_entry.discovery_epoch,
        prior_policy_rank=prior_entry.policy_rank,
        prior_inventory_count=len(prior_inventory),
        source_instance_sha256=source_instance_sha256,
        prior_inventory_sha256=inventory_sha256,
        prior_entry_sha256=prior_entry.entry_sha256,
        capability_sha256=prior_entry.capability.capability_sha256,
        evidence_sha256=evidence_sha256,
    )
    _validate_observation_shape(result, prior_entry, prior_inventory)
    result = replace(result, observation_sha256=observation_root(result))
    initial_cursor = SourceCursorV1(
        source_instance_sha256=source_instance_sha256,
        last_sequence=source_sequence - 1,
    )
    validate_observation(
        result,
        prior_entry,
        prior_inventory,
        initial_cursor,
    )
    return result


def validate_observation(
    value: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    source_cursor: SourceCursorV1,
) -> None:
    try:
        source_instance_sha256 = _digest(
            source_cursor.source_instance_sha256
        )
        value_source_instance_sha256 = _digest(
            value.source_instance_sha256
        )
    except (TypeError, ValueError) as error:
        raise SourceInstanceChanged("source instance") from error
    if (
        source_instance_sha256 == ZERO_DIGEST
        or value_source_instance_sha256 != source_instance_sha256
    ):
        raise SourceInstanceChanged("source instance")
    try:
        _u64(source_cursor.last_sequence)
        _u64(value.source_sequence)
    except (TypeError, ValueError) as error:
        raise StaleObservation("source sequence") from error
    if value.source_sequence <= source_cursor.last_sequence:
        raise StaleObservation("source sequence")
    _validate_observation_shape(value, prior_entry, prior_inventory)
    try:
        valid_root = (
            value.observation_sha256 != ZERO_DIGEST
            and value.observation_sha256 == observation_root(value)
        )
    except (TypeError, ValueError) as error:
        raise InvalidObservation("observation root") from error
    if not valid_root:
        raise InvalidObservation("observation root")


def validate_and_advance_observation(
    value: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    source_cursor: SourceCursorV1,
) -> SourceCursorV1:
    validate_observation(
        value,
        prior_entry,
        prior_inventory,
        source_cursor,
    )
    return SourceCursorV1(
        source_instance_sha256=value.source_instance_sha256,
        last_sequence=value.source_sequence,
    )


def _validate_observation_shape(
    value: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
) -> None:
    try:
        device.validate_inventory_entry(prior_entry)
        _validate_observation_fields(value)
        inventory_sha256 = device.inventory_root(prior_inventory)
    except (device.ContractError, TypeError, ValueError) as error:
        raise InvalidObservation("field or prior inventory") from error

    semantics = _SOURCE_SEMANTICS.get(value.source)
    if semantics is None:
        raise InvalidObservation("unknown source")
    evidence_class, observed_state, requires_command_error = semantics

    if (
        prior_entry.state != device.INVENTORY_PRESENT
        or not (
            prior_entry.capability.feature_bits
            & device.FEATURE_DEVICE_LOSS_SIGNAL
        )
        or value.abi_version != OBSERVATION_ABI
        or value.source_sequence == 0
        or value.source_instance_sha256 == ZERO_DIGEST
        or value.evidence_sha256 == ZERO_DIGEST
        or value.evidence_class != evidence_class
        or value.observed_state != observed_state
        or not _native_command_fields_valid(
            value,
            requires_command_error,
        )
        or not _inventory_contains_exact_entry(
            prior_inventory,
            prior_entry,
        )
        or value.prior_discovery_epoch != prior_entry.discovery_epoch
        or value.prior_policy_rank != prior_entry.policy_rank
        or value.prior_inventory_count != len(prior_inventory)
        or value.prior_inventory_sha256 != inventory_sha256
        or value.prior_entry_sha256 != prior_entry.entry_sha256
        or value.capability_sha256
        != prior_entry.capability.capability_sha256
    ):
        raise InvalidObservation("shape or binding")


def _validate_observation_fields(value: ObservationV1) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.observed_state,
        value.source_sequence,
        value.native_command_status,
        value.native_error_domain_kind,
        value.native_error_code_bits,
        value.prior_discovery_epoch,
        value.prior_policy_rank,
        value.prior_inventory_count,
    )
    for root in (
        value.source_instance_sha256,
        value.prior_inventory_sha256,
        value.prior_entry_sha256,
        value.capability_sha256,
        value.evidence_sha256,
        value.observation_sha256,
    ):
        _digest(root)


def _native_command_fields_valid(
    value: ObservationV1,
    requires_command_error: bool,
) -> bool:
    fields = (
        value.native_command_status,
        value.native_error_domain_kind,
        value.native_error_code_bits,
    )
    if requires_command_error:
        return fields == (
            COMMAND_BUFFER_STATUS_ERROR,
            COMMAND_BUFFER_ERROR_DOMAIN,
            COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
        )
    return fields == (0, 0, 0)


def make_successor_entry(
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    source_cursor: SourceCursorV1,
    successor_discovery_epoch: int,
) -> device.DeviceInventoryEntryV1:
    validate_observation(
        observation,
        prior_entry,
        prior_inventory,
        source_cursor,
    )
    try:
        _u64(successor_discovery_epoch)
    except (TypeError, ValueError) as error:
        raise InvalidTransitionReceipt("successor epoch") from error
    if (
        observation.observed_state
        not in (device.INVENTORY_UNAVAILABLE, device.INVENTORY_LOST)
        or successor_discovery_epoch <= prior_entry.discovery_epoch
    ):
        raise InvalidTransitionReceipt("successor state or epoch")
    try:
        return device.seal_inventory_entry(
            device.DeviceInventoryEntryV1(
                discovery_epoch=successor_discovery_epoch,
                policy_rank=prior_entry.policy_rank,
                state=observation.observed_state,
                capability=prior_entry.capability,
            )
        )
    except device.ContractError as error:
        raise InvalidTransitionReceipt("successor entry") from error


def make_transition_receipt(
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    successor_entry: device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) -> TransitionReceiptV1:
    _validate_transition_inputs(
        observation,
        prior_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    )
    result = TransitionReceiptV1(
        source=observation.source,
        evidence_class=observation.evidence_class,
        prior_state=prior_entry.state,
        successor_state=successor_entry.state,
        source_sequence=observation.source_sequence,
        prior_inventory_count=observation.prior_inventory_count,
        prior_discovery_epoch=prior_entry.discovery_epoch,
        successor_discovery_epoch=successor_entry.discovery_epoch,
        policy_rank=prior_entry.policy_rank,
        prior_inventory_sha256=observation.prior_inventory_sha256,
        prior_entry_sha256=prior_entry.entry_sha256,
        capability_sha256=prior_entry.capability.capability_sha256,
        observation_sha256=observation.observation_sha256,
        successor_entry_sha256=successor_entry.entry_sha256,
    )
    result = replace(
        result,
        receipt_sha256=transition_receipt_root(result),
    )
    validate_transition_receipt(
        result,
        observation,
        prior_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    )
    return result


def validate_transition_receipt(
    value: TransitionReceiptV1,
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    successor_entry: device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) -> None:
    _validate_transition_inputs(
        observation,
        prior_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    )
    try:
        _validate_transition_receipt_fields(value)
        valid_root = (
            value.receipt_sha256 != ZERO_DIGEST
            and value.receipt_sha256 == transition_receipt_root(value)
        )
    except (TypeError, ValueError) as error:
        raise InvalidTransitionReceipt("receipt fields") from error
    if (
        value.abi_version != TRANSITION_RECEIPT_ABI
        or value.source != observation.source
        or value.evidence_class != observation.evidence_class
        or value.prior_state != device.INVENTORY_PRESENT
        or value.successor_state != successor_entry.state
        or value.source_sequence != observation.source_sequence
        or value.prior_inventory_count
        != observation.prior_inventory_count
        or value.prior_discovery_epoch != prior_entry.discovery_epoch
        or value.successor_discovery_epoch
        != successor_entry.discovery_epoch
        or value.policy_rank != prior_entry.policy_rank
        or value.prior_inventory_sha256
        != observation.prior_inventory_sha256
        or value.prior_entry_sha256 != prior_entry.entry_sha256
        or value.capability_sha256
        != prior_entry.capability.capability_sha256
        or value.observation_sha256
        != observation.observation_sha256
        or value.successor_entry_sha256
        != successor_entry.entry_sha256
        or not valid_root
    ):
        raise InvalidTransitionReceipt("receipt binding or root")


def _validate_transition_inputs(
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: Sequence[device.DeviceInventoryEntryV1],
    successor_entry: device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) -> None:
    validate_observation(
        observation,
        prior_entry,
        prior_inventory,
        source_cursor,
    )
    try:
        device.validate_inventory_entry(successor_entry)
    except device.ContractError as error:
        raise InvalidTransitionReceipt("successor entry") from error
    if (
        prior_entry.state != device.INVENTORY_PRESENT
        or successor_entry.state
        not in (device.INVENTORY_UNAVAILABLE, device.INVENTORY_LOST)
        or successor_entry.state != observation.observed_state
        or successor_entry.discovery_epoch <= prior_entry.discovery_epoch
        or successor_entry.policy_rank != prior_entry.policy_rank
        or successor_entry.capability != prior_entry.capability
    ):
        raise InvalidTransitionReceipt("transition inputs")


def transition_receipt_root(value: TransitionReceiptV1) -> Digest:
    digest = hashlib.sha256()
    digest.update(TRANSITION_RECEIPT_DOMAIN)
    _update_u64(
        digest,
        value.abi_version,
        value.source,
        value.evidence_class,
        value.prior_state,
        value.successor_state,
        value.source_sequence,
        value.prior_inventory_count,
        value.prior_discovery_epoch,
        value.successor_discovery_epoch,
        value.policy_rank,
    )
    for root in (
        value.prior_inventory_sha256,
        value.prior_entry_sha256,
        value.capability_sha256,
        value.observation_sha256,
        value.successor_entry_sha256,
    ):
        digest.update(_digest(root))
    return digest.digest()


def _validate_transition_receipt_fields(
    value: TransitionReceiptV1,
) -> None:
    _u64s(
        value.abi_version,
        value.source,
        value.evidence_class,
        value.prior_state,
        value.successor_state,
        value.source_sequence,
        value.prior_inventory_count,
        value.prior_discovery_epoch,
        value.successor_discovery_epoch,
        value.policy_rank,
    )
    for root in (
        value.prior_inventory_sha256,
        value.prior_entry_sha256,
        value.capability_sha256,
        value.observation_sha256,
        value.successor_entry_sha256,
        value.receipt_sha256,
    ):
        _digest(root)


def _inventory_contains_exact_entry(
    inventory: Sequence[device.DeviceInventoryEntryV1],
    expected: device.DeviceInventoryEntryV1,
) -> bool:
    return any(
        entry.entry_sha256 == expected.entry_sha256
        and entry == expected
        for entry in inventory
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
