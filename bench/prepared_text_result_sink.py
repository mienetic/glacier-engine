"""Independent R1i prepared-text result acknowledgement and local sink.

The acknowledgement codec mirrors the allocation-free Zig wire but shares no
implementation with it.  ``ResultSinkV1`` is a bounded POSIX reference
adapter: every successful application publishes a new immutable ledger image
before atomically replacing a fixed selector.  It is intentionally a local
conformance sink, not a network delivery adapter.
"""

from __future__ import annotations

from dataclasses import dataclass
import errno
import fcntl
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import stat
import struct
from typing import Callable, Optional, Sequence, Union


Digest = bytes
PathLike = Union[str, os.PathLike[str]]
ZERO_DIGEST = bytes(32)
U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1

# Canonical acknowledgement wire owned by src/prepared_text_result_sink.zig.
ACKNOWLEDGEMENT_MAGIC = b"GPRSACK1"
ACKNOWLEDGEMENT_ABI = 0x4750_5253_0000_0001
ACKNOWLEDGEMENT_BYTES = 424
ACKNOWLEDGEMENT_BODY_BYTES = 392
ACKNOWLEDGEMENT_FLAGS = 0

DELIVERY_KEY_DOMAIN = b"glacier-prepared-text-result-delivery-key-v1\x00"
COMMIT_RECEIPT_DOMAIN = b"glacier-prepared-text-result-commit-receipt-v1\x00"
SINK_PREFIX_DOMAIN = b"glacier-prepared-text-result-sink-prefix-v1\x00"
ACKNOWLEDGEMENT_DOMAIN = b"glacier-prepared-text-result-acknowledgement-v1\x00"

# Canonical immutable ledger and selector wire.  They wrap exact canonical ACK
# images; neither is another acknowledgement ABI.
LEDGER_ABI = 0x4750_524C_0000_0001
SELECTOR_ABI = 0x4750_524C_0000_0002
LEDGER_MAGIC = b"GPRSLED1"
SELECTOR_MAGIC = b"GPRSSEL1"
LEDGER_HEADER_BYTES = 256
LEDGER_FOOTER_BYTES = 32
SELECTOR_BODY_BYTES = 240
SELECTOR_BYTES = SELECTOR_BODY_BYTES + 32
STORE_FLAGS = 0

LEDGER_DOMAIN = b"glacier-prepared-text-result-sink-ledger-v1\x00"
SELECTOR_DOMAIN = b"glacier-prepared-text-result-sink-selector-v1\x00"

LOCK_NAME = ".glacier-prepared-text-result-sink-lock-v1"
ACTIVE_SELECTOR_NAME = ".glacier-prepared-text-result-sink-active-v1"
LEDGER_NAME_PREFIX = "prepared-text-result-ledger-"
LEDGER_NAME_SUFFIX = ".bin"
TEMP_NAME_PREFIX = ".glacier-prepared-text-result-sink-tmp-"

LEDGER_BODY_WRITE = "ledger_body_write"
LEDGER_BODY_SYNC = "ledger_body_sync"
LEDGER_FOOTER_WRITE = "ledger_footer_write"
LEDGER_FILE_SYNC = "ledger_file_sync"
LEDGER_IMMUTABLE_RENAME = "ledger_immutable_rename"
LEDGER_DIRECTORY_SYNC = "ledger_directory_sync"
SELECTOR_TEMP_WRITE = "selector_temp_write"
SELECTOR_TEMP_SYNC = "selector_temp_sync"
SELECTOR_REPLACE = "selector_replace"
SELECTOR_DIRECTORY_SYNC = "selector_directory_sync"
IO_PHASES = (
    LEDGER_BODY_WRITE,
    LEDGER_BODY_SYNC,
    LEDGER_FOOTER_WRITE,
    LEDGER_FILE_SYNC,
    LEDGER_IMMUTABLE_RENAME,
    LEDGER_DIRECTORY_SYNC,
    SELECTOR_TEMP_WRITE,
    SELECTOR_TEMP_SYNC,
    SELECTOR_REPLACE,
    SELECTOR_DIRECTORY_SYNC,
)

APPLIED = "applied"
ALREADY_APPLIED = "already_applied"


class PreparedTextResultSinkError(ValueError):
    """The acknowledgement, ledger, selector, or operation is invalid."""


class AcknowledgementError(PreparedTextResultSinkError):
    """The canonical acknowledgement wire is invalid."""


class SinkIdentityMismatch(PreparedTextResultSinkError):
    """The wire or store belongs to another sink identity."""


class SinkConflict(PreparedTextResultSinkError):
    """An already-named result differs from the retained result."""


class SinkSequenceGap(PreparedTextResultSinkError):
    """The application sequence is not the exact next sequence."""


class SinkCapacityExceeded(PreparedTextResultSinkError):
    """The configured bounded local ledger has no remaining slot."""


class SinkStorageError(PreparedTextResultSinkError):
    """The durable local representation is missing, unsafe, or corrupt."""


class SinkBusy(PreparedTextResultSinkError):
    """Another process owns the local sink lease."""


class InjectedCrash(PreparedTextResultSinkError):
    """A deterministic crash was injected after one durable I/O phase."""

    def __init__(self, phase: str):
        super().__init__(f"injected crash after {phase}")
        self.phase = phase


@dataclass(frozen=True)
class ResultAcknowledgementV1:
    request_epoch: int
    transaction_sequence: int
    token_id: int
    application_ordinal: int
    application_count: int
    request_sha256: Digest
    proposal_sha256: Digest
    transition_sha256: Digest
    commit_receipt_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    delivery_key_sha256: Digest
    predecessor_acknowledgement_sha256: Digest
    predecessor_sink_prefix_sha256: Digest
    result_sink_prefix_sha256: Digest
    acknowledgement_sha256: Digest
    encoded: bytes

    @property
    def global_sequence(self) -> int:
        return self.transaction_sequence


@dataclass(frozen=True)
class SinkSnapshotV1:
    request_sha256: Digest
    request_epoch: int
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    base_global_sequence: int
    next_global_sequence: int
    applied_count: int
    maximum_results: int
    generation: int
    head_acknowledgement_sha256: Digest
    result_sink_prefix_sha256: Digest
    ledger_sha256: Digest
    selector_sha256: Digest
    ledger_bytes: int


@dataclass(frozen=True)
class ApplyReceiptV1:
    disposition: str
    transaction_sequence: int
    application_ordinal: int
    applied_count: int
    acknowledgement_sha256: Digest
    result_sink_prefix_sha256: Digest
    ledger_sha256: Digest
    selector_sha256: Digest


@dataclass(frozen=True)
class _LedgerV1:
    request_epoch: int
    base_global_sequence: int
    next_global_sequence: int
    request_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    acknowledgements: tuple[ResultAcknowledgementV1, ...]
    ledger_sha256: Digest
    encoded: bytes


@dataclass(frozen=True)
class _SelectorV1:
    generation: int
    request_epoch: int
    base_global_sequence: int
    next_global_sequence: int
    ledger_bytes: int
    request_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    previous_selector_sha256: Digest
    ledger_sha256: Digest
    selector_sha256: Digest
    encoded: bytes


def _u64(value: int, where: str) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise PreparedTextResultSinkError(f"{where} is outside u64")
    return struct.pack("<Q", value)


def _digest(
    value: object,
    where: str,
    *,
    allow_zero: bool = False,
) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise PreparedTextResultSinkError(f"{where} is not a digest")
    if not allow_zero and hmac.compare_digest(value, ZERO_DIGEST):
        raise PreparedTextResultSinkError(f"{where} is zero")
    return value


def _sha256(domain: bytes, *parts: bytes) -> Digest:
    if type(domain) is not bytes or not domain.endswith(b"\x00"):
        raise PreparedTextResultSinkError("invalid hash domain")
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        if type(part) is not bytes:
            raise PreparedTextResultSinkError("hash input is not bytes")
        hasher.update(part)
    return hasher.digest()


def delivery_key_sha256_v1(
    request_sha256: Digest,
    request_epoch: int,
    transaction_sequence: int,
) -> Digest:
    return _sha256(
        DELIVERY_KEY_DOMAIN,
        _u64(ACKNOWLEDGEMENT_ABI, "acknowledgement ABI"),
        _digest(request_sha256, "request"),
        _u64(request_epoch, "request epoch"),
        _u64(transaction_sequence, "transaction sequence"),
    )


def result_sink_prefix_sha256_v1(
    *,
    request_epoch: int,
    transaction_sequence: int,
    token_id: int,
    application_ordinal: int,
    application_count: int,
    request_sha256: Digest,
    proposal_sha256: Digest,
    transition_sha256: Digest,
    commit_receipt_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    delivery_key_sha256: Digest,
    predecessor_acknowledgement_sha256: Digest,
    predecessor_sink_prefix_sha256: Digest,
) -> Digest:
    return _sha256(
        SINK_PREFIX_DOMAIN,
        _u64(ACKNOWLEDGEMENT_ABI, "acknowledgement ABI"),
        _u64(request_epoch, "request epoch"),
        _u64(transaction_sequence, "transaction sequence"),
        _u64(token_id, "token id"),
        _u64(application_ordinal, "application ordinal"),
        _u64(application_count, "application count"),
        _digest(request_sha256, "request"),
        _digest(proposal_sha256, "proposal"),
        _digest(transition_sha256, "transition"),
        _digest(commit_receipt_sha256, "commit receipt"),
        _digest(sink_implementation_sha256, "sink implementation"),
        _digest(sink_instance_sha256, "sink instance"),
        _digest(delivery_key_sha256, "delivery key"),
        _digest(
            predecessor_acknowledgement_sha256,
            "predecessor acknowledgement",
            allow_zero=True,
        ),
        _digest(
            predecessor_sink_prefix_sha256,
            "predecessor sink prefix",
            allow_zero=True,
        ),
    )


def acknowledgement_sha256_v1(body: bytes) -> Digest:
    if type(body) is not bytes or len(body) != ACKNOWLEDGEMENT_BODY_BYTES:
        raise AcknowledgementError("invalid acknowledgement body")
    return _sha256(ACKNOWLEDGEMENT_DOMAIN, body)


def encode_acknowledgement_v1(
    *,
    request_sha256: Digest,
    request_epoch: int,
    transaction_sequence: int,
    token_id: int,
    proposal_sha256: Digest,
    transition_sha256: Digest,
    commit_receipt_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    application_ordinal: int,
    predecessor_acknowledgement_sha256: Digest = ZERO_DIGEST,
    predecessor_sink_prefix_sha256: Digest = ZERO_DIGEST,
) -> bytes:
    if type(token_id) is not int or not 0 <= token_id <= U32_MAX:
        raise AcknowledgementError("token id is outside u32")
    if type(application_ordinal) is not int or application_ordinal <= 0:
        raise AcknowledgementError("application ordinal is invalid")
    predecessor_ack = _digest(
        predecessor_acknowledgement_sha256,
        "predecessor acknowledgement",
        allow_zero=True,
    )
    predecessor_prefix = _digest(
        predecessor_sink_prefix_sha256,
        "predecessor sink prefix",
        allow_zero=True,
    )
    if (application_ordinal == 1) != (
        predecessor_ack == ZERO_DIGEST and predecessor_prefix == ZERO_DIGEST
    ):
        raise AcknowledgementError("predecessor shape does not match ordinal")
    if application_ordinal > 1 and (
        predecessor_ack == ZERO_DIGEST or predecessor_prefix == ZERO_DIGEST
    ):
        raise AcknowledgementError("later acknowledgement lacks predecessor")

    request = _digest(request_sha256, "request")
    proposal = _digest(proposal_sha256, "proposal")
    transition = _digest(transition_sha256, "transition")
    commit_receipt = _digest(commit_receipt_sha256, "commit receipt")
    sink_implementation = _digest(
        sink_implementation_sha256,
        "sink implementation",
    )
    sink_instance = _digest(sink_instance_sha256, "sink instance")
    delivery_key = delivery_key_sha256_v1(
        request,
        request_epoch,
        transaction_sequence,
    )
    prefix = result_sink_prefix_sha256_v1(
        request_epoch=request_epoch,
        transaction_sequence=transaction_sequence,
        token_id=token_id,
        application_ordinal=application_ordinal,
        application_count=1,
        request_sha256=request,
        proposal_sha256=proposal,
        transition_sha256=transition,
        commit_receipt_sha256=commit_receipt,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
        delivery_key_sha256=delivery_key,
        predecessor_acknowledgement_sha256=predecessor_ack,
        predecessor_sink_prefix_sha256=predecessor_prefix,
    )
    body = b"".join(
        (
            ACKNOWLEDGEMENT_MAGIC,
            _u64(ACKNOWLEDGEMENT_ABI, "acknowledgement ABI"),
            _u64(ACKNOWLEDGEMENT_BYTES, "acknowledgement bytes"),
            _u64(ACKNOWLEDGEMENT_FLAGS, "acknowledgement flags"),
            _u64(request_epoch, "request epoch"),
            _u64(transaction_sequence, "transaction sequence"),
            _u64(token_id, "token id"),
            _u64(application_ordinal, "application ordinal"),
            _u64(1, "application count"),
            request,
            proposal,
            transition,
            commit_receipt,
            sink_implementation,
            sink_instance,
            delivery_key,
            predecessor_ack,
            predecessor_prefix,
            prefix,
        )
    )
    if len(body) != ACKNOWLEDGEMENT_BODY_BYTES:
        raise AcknowledgementError("acknowledgement body geometry changed")
    encoded = body + acknowledgement_sha256_v1(body)
    decode_acknowledgement_v1(encoded)
    return encoded


def decode_acknowledgement_v1(
    encoded_value: bytes,
    *,
    expected_request_sha256: Optional[Digest] = None,
    expected_request_epoch: Optional[int] = None,
    expected_sink_implementation_sha256: Optional[Digest] = None,
    expected_sink_instance_sha256: Optional[Digest] = None,
) -> ResultAcknowledgementV1:
    if type(encoded_value) is not bytes:
        raise AcknowledgementError("acknowledgement must be bytes")
    encoded = encoded_value
    if (
        len(encoded) != ACKNOWLEDGEMENT_BYTES
        or encoded[:8] != ACKNOWLEDGEMENT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != ACKNOWLEDGEMENT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != ACKNOWLEDGEMENT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != ACKNOWLEDGEMENT_FLAGS
    ):
        raise AcknowledgementError("invalid acknowledgement header")

    (
        request_epoch,
        transaction_sequence,
        token_id,
        application_ordinal,
        application_count,
    ) = struct.unpack_from("<QQQQQ", encoded, 32)
    digest_values = tuple(
        encoded[offset : offset + 32]
        for offset in range(72, ACKNOWLEDGEMENT_BODY_BYTES, 32)
    )
    if len(digest_values) != 10:
        raise AcknowledgementError("acknowledgement digest geometry changed")
    (
        request,
        proposal,
        transition,
        commit_receipt,
        sink_implementation,
        sink_instance,
        delivery_key,
        predecessor_ack,
        predecessor_prefix,
        result_prefix,
    ) = digest_values
    acknowledgement = encoded[ACKNOWLEDGEMENT_BODY_BYTES:]

    if (
        request_epoch == 0
        or token_id > U32_MAX
        or application_ordinal == 0
        or application_count != 1
    ):
        raise AcknowledgementError("invalid acknowledgement scalars")
    for value, label in (
        (request, "request"),
        (proposal, "proposal"),
        (transition, "transition"),
        (commit_receipt, "commit receipt"),
        (sink_implementation, "sink implementation"),
        (sink_instance, "sink instance"),
        (delivery_key, "delivery key"),
        (result_prefix, "result sink prefix"),
        (acknowledgement, "acknowledgement"),
    ):
        try:
            _digest(value, label)
        except PreparedTextResultSinkError as error:
            raise AcknowledgementError(str(error)) from error
    try:
        _digest(
            predecessor_ack,
            "predecessor acknowledgement",
            allow_zero=True,
        )
        _digest(
            predecessor_prefix,
            "predecessor sink prefix",
            allow_zero=True,
        )
    except PreparedTextResultSinkError as error:
        raise AcknowledgementError(str(error)) from error
    if application_ordinal == 1:
        if predecessor_ack != ZERO_DIGEST or predecessor_prefix != ZERO_DIGEST:
            raise AcknowledgementError("first acknowledgement has predecessor")
    elif predecessor_ack == ZERO_DIGEST or predecessor_prefix == ZERO_DIGEST:
        raise AcknowledgementError("later acknowledgement lacks predecessor")

    expected_delivery = delivery_key_sha256_v1(
        request,
        request_epoch,
        transaction_sequence,
    )
    expected_prefix = result_sink_prefix_sha256_v1(
        request_epoch=request_epoch,
        transaction_sequence=transaction_sequence,
        token_id=token_id,
        application_ordinal=application_ordinal,
        application_count=application_count,
        request_sha256=request,
        proposal_sha256=proposal,
        transition_sha256=transition,
        commit_receipt_sha256=commit_receipt,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
        delivery_key_sha256=delivery_key,
        predecessor_acknowledgement_sha256=predecessor_ack,
        predecessor_sink_prefix_sha256=predecessor_prefix,
    )
    expected_acknowledgement = acknowledgement_sha256_v1(
        encoded[:ACKNOWLEDGEMENT_BODY_BYTES]
    )
    if not hmac.compare_digest(delivery_key, expected_delivery):
        raise AcknowledgementError("delivery key mismatch")
    if not hmac.compare_digest(result_prefix, expected_prefix):
        raise AcknowledgementError("result sink prefix mismatch")
    if not hmac.compare_digest(
        acknowledgement,
        expected_acknowledgement,
    ):
        raise AcknowledgementError("acknowledgement root mismatch")

    for actual, expected, label in (
        (request, expected_request_sha256, "request"),
        (request_epoch, expected_request_epoch, "request epoch"),
        (
            sink_implementation,
            expected_sink_implementation_sha256,
            "sink implementation",
        ),
        (sink_instance, expected_sink_instance_sha256, "sink instance"),
    ):
        if expected is None:
            continue
        if isinstance(actual, bytes):
            try:
                expected_value = _digest(expected, f"expected {label}")
            except PreparedTextResultSinkError as error:
                raise SinkIdentityMismatch(str(error)) from error
            matches = hmac.compare_digest(actual, expected_value)
        else:
            matches = type(expected) is int and actual == expected
        if not matches:
            raise SinkIdentityMismatch(f"acknowledgement {label} does not match sink")

    return ResultAcknowledgementV1(
        request_epoch=request_epoch,
        transaction_sequence=transaction_sequence,
        token_id=token_id,
        application_ordinal=application_ordinal,
        application_count=application_count,
        request_sha256=request,
        proposal_sha256=proposal,
        transition_sha256=transition,
        commit_receipt_sha256=commit_receipt,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
        delivery_key_sha256=delivery_key,
        predecessor_acknowledgement_sha256=predecessor_ack,
        predecessor_sink_prefix_sha256=predecessor_prefix,
        result_sink_prefix_sha256=result_prefix,
        acknowledgement_sha256=acknowledgement,
        encoded=encoded,
    )


# Short aliases make the independent command-line/test vocabulary convenient
# without obscuring the canonical public type name above.
decode_ack_v1 = decode_acknowledgement_v1
encode_ack_v1 = encode_acknowledgement_v1


def _ledger_root(body: bytes) -> Digest:
    return _sha256(LEDGER_DOMAIN, body)


def _selector_root(body: bytes) -> Digest:
    return _sha256(SELECTOR_DOMAIN, body)


def _checked_add(left: int, right: int, where: str) -> int:
    if (
        type(left) is not int
        or type(right) is not int
        or left < 0
        or right < 0
        or left > U64_MAX - right
    ):
        raise PreparedTextResultSinkError(f"{where} overflows u64")
    return left + right


def _ledger_body(
    *,
    request_sha256: Digest,
    request_epoch: int,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    base_global_sequence: int,
    acknowledgement_wires: Sequence[bytes],
) -> bytes:
    count = len(acknowledgement_wires)
    next_sequence = _checked_add(
        base_global_sequence,
        count,
        "next global sequence",
    )
    total = LEDGER_HEADER_BYTES + count * ACKNOWLEDGEMENT_BYTES + LEDGER_FOOTER_BYTES
    header = b"".join(
        (
            LEDGER_MAGIC,
            _u64(LEDGER_ABI, "ledger ABI"),
            _u64(LEDGER_HEADER_BYTES, "ledger header bytes"),
            _u64(ACKNOWLEDGEMENT_BYTES, "acknowledgement bytes"),
            _u64(total, "ledger bytes"),
            _u64(count, "result count"),
            _u64(base_global_sequence, "base global sequence"),
            _u64(next_sequence, "next global sequence"),
            _u64(request_epoch, "request epoch"),
            _u64(STORE_FLAGS, "store flags"),
            _digest(request_sha256, "request"),
            _digest(sink_implementation_sha256, "sink implementation"),
            _digest(sink_instance_sha256, "sink instance"),
            (
                decode_acknowledgement_v1(
                    acknowledgement_wires[-1]
                ).acknowledgement_sha256
                if count
                else ZERO_DIGEST
            ),
            (
                decode_acknowledgement_v1(
                    acknowledgement_wires[-1]
                ).result_sink_prefix_sha256
                if count
                else ZERO_DIGEST
            ),
            bytes(16),
        )
    )
    if len(header) != LEDGER_HEADER_BYTES:
        raise SinkStorageError("ledger header geometry changed")
    for wire in acknowledgement_wires:
        if type(wire) is not bytes or len(wire) != ACKNOWLEDGEMENT_BYTES:
            raise SinkStorageError("ledger acknowledgement geometry changed")
    return header + b"".join(acknowledgement_wires)


def _encode_ledger(**kwargs: object) -> bytes:
    body = _ledger_body(**kwargs)  # type: ignore[arg-type]
    return body + _ledger_root(body)


def _decode_ledger(
    encoded: bytes,
    *,
    expected_request_sha256: Digest,
    expected_request_epoch: int,
    expected_sink_implementation_sha256: Digest,
    expected_sink_instance_sha256: Digest,
    expected_base_global_sequence: int,
    expected_maximum_results: int,
) -> _LedgerV1:
    if (
        type(encoded) is not bytes
        or len(encoded) < LEDGER_HEADER_BYTES + LEDGER_FOOTER_BYTES
        or encoded[:8] != LEDGER_MAGIC
    ):
        raise SinkStorageError("invalid ledger envelope")
    scalars = struct.unpack_from("<9Q", encoded, 8)
    (
        abi,
        header_bytes,
        acknowledgement_bytes,
        encoded_bytes,
        count,
        base_sequence,
        next_sequence,
        request_epoch,
        flags,
    ) = scalars
    if (
        abi != LEDGER_ABI
        or encoded_bytes != len(encoded)
        or header_bytes != LEDGER_HEADER_BYTES
        or acknowledgement_bytes != ACKNOWLEDGEMENT_BYTES
        or request_epoch == 0
        or count > expected_maximum_results
        or flags != STORE_FLAGS
        or len(encoded)
        != LEDGER_HEADER_BYTES + count * ACKNOWLEDGEMENT_BYTES + LEDGER_FOOTER_BYTES
        or next_sequence != _checked_add(base_sequence, count, "ledger sequence")
    ):
        raise SinkStorageError("invalid ledger header")
    # Canonical fixed offsets place identities immediately after the scalar
    # header, not at the aligned offsets used by unrelated store formats.
    request = encoded[80:112]
    sink_implementation = encoded[112:144]
    sink_instance = encoded[144:176]
    last_ack = encoded[176:208]
    result_prefix = encoded[208:240]
    reserved = encoded[240:256]
    footer = encoded[-LEDGER_FOOTER_BYTES:]
    for value, label, allow_zero in (
        (request, "ledger request", False),
        (sink_implementation, "ledger sink implementation", False),
        (sink_instance, "ledger sink instance", False),
        (last_ack, "ledger last acknowledgement", count == 0),
        (result_prefix, "ledger result prefix", count == 0),
        (footer, "ledger root", False),
    ):
        try:
            _digest(value, label, allow_zero=allow_zero)
        except PreparedTextResultSinkError as error:
            raise SinkStorageError(str(error)) from error
    if not hmac.compare_digest(
        footer,
        _ledger_root(encoded[:-LEDGER_FOOTER_BYTES]),
    ):
        raise SinkStorageError("ledger root mismatch")
    if any(reserved) or (count == 0) != (
        last_ack == ZERO_DIGEST and result_prefix == ZERO_DIGEST
    ):
        raise SinkStorageError("invalid ledger head")
    expected_values = (
        (request, _digest(expected_request_sha256, "expected request")),
        (
            request_epoch,
            expected_request_epoch,
        ),
        (
            sink_implementation,
            _digest(
                expected_sink_implementation_sha256,
                "expected sink implementation",
            ),
        ),
        (
            sink_instance,
            _digest(
                expected_sink_instance_sha256,
                "expected sink instance",
            ),
        ),
        (base_sequence, expected_base_global_sequence),
    )
    if any(actual != expected for actual, expected in expected_values):
        raise SinkIdentityMismatch("ledger identity does not match sink")

    acknowledgements: list[ResultAcknowledgementV1] = []
    previous_ack = ZERO_DIGEST
    previous_prefix = ZERO_DIGEST
    seen_delivery_keys: set[Digest] = set()
    for index in range(count):
        offset = LEDGER_HEADER_BYTES + index * ACKNOWLEDGEMENT_BYTES
        wire = encoded[offset : offset + ACKNOWLEDGEMENT_BYTES]
        try:
            ack = decode_acknowledgement_v1(
                wire,
                expected_request_sha256=request,
                expected_request_epoch=request_epoch,
                expected_sink_implementation_sha256=sink_implementation,
                expected_sink_instance_sha256=sink_instance,
            )
        except PreparedTextResultSinkError as error:
            raise SinkStorageError("ledger contains invalid acknowledgement") from error
        expected_sequence = _checked_add(
            base_sequence,
            index,
            "acknowledgement sequence",
        )
        if (
            ack.transaction_sequence != expected_sequence
            or ack.application_ordinal != index + 1
            or ack.predecessor_acknowledgement_sha256 != previous_ack
            or ack.predecessor_sink_prefix_sha256 != previous_prefix
            or ack.delivery_key_sha256 in seen_delivery_keys
        ):
            raise SinkStorageError("ledger acknowledgement chain mismatch")
        seen_delivery_keys.add(ack.delivery_key_sha256)
        acknowledgements.append(ack)
        previous_ack = ack.acknowledgement_sha256
        previous_prefix = ack.result_sink_prefix_sha256
    if previous_ack != last_ack or previous_prefix != result_prefix:
        raise SinkStorageError("ledger header does not bind replayed head")

    return _LedgerV1(
        request_epoch=request_epoch,
        base_global_sequence=base_sequence,
        next_global_sequence=next_sequence,
        request_sha256=request,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
        acknowledgements=tuple(acknowledgements),
        ledger_sha256=footer,
        encoded=encoded,
    )


def _encode_selector(
    *,
    ledger: _LedgerV1,
    previous_selector_sha256: Digest,
) -> bytes:
    count = len(ledger.acknowledgements)
    body = b"".join(
        (
            SELECTOR_MAGIC,
            _u64(SELECTOR_ABI, "selector ABI"),
            _u64(SELECTOR_BYTES, "selector bytes"),
            _u64(STORE_FLAGS, "store flags"),
            _u64(count + 1, "selector generation"),
            _u64(count, "result count"),
            _u64(ledger.base_global_sequence, "base global sequence"),
            _u64(ledger.next_global_sequence, "next global sequence"),
            _u64(ledger.request_epoch, "request epoch"),
            _u64(len(ledger.encoded), "ledger bytes"),
            ledger.request_sha256,
            ledger.sink_implementation_sha256,
            ledger.sink_instance_sha256,
            _digest(
                previous_selector_sha256,
                "previous selector",
                allow_zero=True,
            ),
            ledger.ledger_sha256,
        )
    )
    if len(body) != SELECTOR_BODY_BYTES:
        raise SinkStorageError("selector body geometry changed")
    return body + _selector_root(body)


def _decode_selector(
    encoded: bytes,
    *,
    expected_request_sha256: Digest,
    expected_request_epoch: int,
    expected_sink_implementation_sha256: Digest,
    expected_sink_instance_sha256: Digest,
    expected_base_global_sequence: int,
    expected_maximum_results: int,
) -> _SelectorV1:
    if (
        type(encoded) is not bytes
        or len(encoded) != SELECTOR_BYTES
        or encoded[:8] != SELECTOR_MAGIC
    ):
        raise SinkStorageError("invalid selector envelope")
    scalars = struct.unpack_from("<9Q", encoded, 8)
    (
        abi,
        encoded_bytes,
        flags,
        generation,
        count,
        base_sequence,
        next_sequence,
        request_epoch,
        ledger_bytes,
    ) = scalars
    if (
        abi != SELECTOR_ABI
        or encoded_bytes != SELECTOR_BYTES
        or generation == 0
        or request_epoch == 0
        or count > expected_maximum_results
        or ledger_bytes
        != LEDGER_HEADER_BYTES + count * ACKNOWLEDGEMENT_BYTES + LEDGER_FOOTER_BYTES
        or next_sequence != _checked_add(base_sequence, count, "selector sequence")
        or flags != STORE_FLAGS
    ):
        raise SinkStorageError("invalid selector header")
    request = encoded[80:112]
    sink_implementation = encoded[112:144]
    sink_instance = encoded[144:176]
    previous_selector = encoded[176:208]
    ledger_root = encoded[208:240]
    selector_root = encoded[240:272]
    for value, label, allow_zero in (
        (request, "selector request", False),
        (sink_implementation, "selector sink implementation", False),
        (sink_instance, "selector sink instance", False),
        (previous_selector, "selector predecessor", generation == 1),
        (ledger_root, "selector ledger", False),
        (selector_root, "selector root", False),
    ):
        try:
            _digest(value, label, allow_zero=allow_zero)
        except PreparedTextResultSinkError as error:
            raise SinkStorageError(str(error)) from error
    if (
        not hmac.compare_digest(
            selector_root,
            _selector_root(encoded[:SELECTOR_BODY_BYTES]),
        )
        or generation != count + 1
        or (generation == 1) != (previous_selector == ZERO_DIGEST)
    ):
        raise SinkStorageError("selector root or lineage mismatch")
    expected_values = (
        (request, _digest(expected_request_sha256, "expected request")),
        (request_epoch, expected_request_epoch),
        (
            sink_implementation,
            _digest(
                expected_sink_implementation_sha256,
                "expected sink implementation",
            ),
        ),
        (
            sink_instance,
            _digest(
                expected_sink_instance_sha256,
                "expected sink instance",
            ),
        ),
        (base_sequence, expected_base_global_sequence),
    )
    if any(actual != expected for actual, expected in expected_values):
        raise SinkIdentityMismatch("selector identity does not match sink")
    return _SelectorV1(
        generation=generation,
        request_epoch=request_epoch,
        base_global_sequence=base_sequence,
        next_global_sequence=next_sequence,
        ledger_bytes=ledger_bytes,
        request_sha256=request,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
        previous_selector_sha256=previous_selector,
        ledger_sha256=ledger_root,
        selector_sha256=selector_root,
        encoded=encoded,
    )


def _ledger_name(root: Digest) -> str:
    return LEDGER_NAME_PREFIX + _digest(root, "ledger root").hex() + LEDGER_NAME_SUFFIX


def _temporary_name(kind: str) -> str:
    if kind not in ("ledger", "selector"):
        raise SinkStorageError("invalid temporary file kind")
    return (
        TEMP_NAME_PREFIX + kind + "-" + str(os.getpid()) + "-" + secrets.token_hex(12)
    )


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    position = 0
    while position < len(view):
        try:
            written = os.write(fd, view[position:])
        except OSError as error:
            raise SinkStorageError("storage write failed") from error
        if written <= 0:
            raise SinkStorageError("storage write made no progress")
        position += written


def _safe_file_flags(flags: int) -> int:
    return flags | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)


def _file_view(info: os.stat_result, name: str) -> tuple[int, ...]:
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or info.st_mode & 0o077
        or info.st_size < 0
    ):
        raise SinkStorageError(f"{name} is not a private regular file")
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _open_regular_at(
    directory_fd: int,
    name: str,
    flags: int,
    mode: int = 0o600,
) -> int:
    try:
        fd = os.open(
            name,
            _safe_file_flags(flags),
            mode,
            dir_fd=directory_fd,
        )
    except OSError as error:
        raise SinkStorageError(f"cannot open {name}") from error
    try:
        _file_view(os.fstat(fd), name)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _read_file_at(
    directory_fd: int,
    name: str,
    maximum_bytes: int,
) -> bytes:
    fd = _open_regular_at(directory_fd, name, os.O_RDONLY)
    try:
        before = os.fstat(fd)
        before_view = _file_view(before, name)
        try:
            entry_before = os.stat(
                name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise SinkStorageError(f"cannot inspect directory entry {name}") from error
        if before_view != _file_view(entry_before, name):
            raise SinkStorageError(f"{name} changed identity while opening")
        if before.st_size > maximum_bytes:
            raise SinkStorageError(f"{name} has unsafe length")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            try:
                chunk = os.read(fd, min(remaining, 64 * 1024))
            except OSError as error:
                raise SinkStorageError(f"cannot read {name}") from error
            if not chunk:
                raise SinkStorageError(f"{name} was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(fd, 1):
            raise SinkStorageError(f"{name} grew while reading")
        after = os.fstat(fd)
        try:
            entry_after = os.stat(
                name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise SinkStorageError(
                f"cannot re-inspect directory entry {name}"
            ) from error
        after_view = _file_view(after, name)
        if before_view != after_view or after_view != _file_view(entry_after, name):
            raise SinkStorageError(f"{name} changed while reading")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _sync_directory(directory_fd: int) -> None:
    try:
        os.fsync(directory_fd)
    except OSError as error:
        raise SinkStorageError("directory sync failed") from error


class ResultSinkV1:
    """Exclusive, crash-recoverable reference sink for one request lineage."""

    def __init__(
        self,
        *,
        path: Path,
        directory_fd: int,
        lock_fd: int,
        request_sha256: Digest,
        request_epoch: int,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        base_global_sequence: int,
        maximum_results: int,
        ledger: _LedgerV1,
        selector: _SelectorV1,
    ):
        self.path = path
        self._directory_fd = directory_fd
        self._lock_fd = lock_fd
        self.request_sha256 = request_sha256
        self.request_epoch = request_epoch
        self.sink_implementation_sha256 = sink_implementation_sha256
        self.sink_instance_sha256 = sink_instance_sha256
        self.base_global_sequence = base_global_sequence
        self.maximum_results = maximum_results
        self._ledger = ledger
        self._selector = selector
        self._closed = False
        self._poisoned = False

    @classmethod
    def create(
        cls,
        directory: PathLike,
        *,
        request_sha256: Digest,
        request_epoch: int,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        base_global_sequence: int,
        maximum_results: int,
    ) -> "ResultSinkV1":
        path = Path(directory)
        path.mkdir(mode=0o700, parents=False, exist_ok=True)
        values = cls._validate_identity(
            request_sha256=request_sha256,
            request_epoch=request_epoch,
            sink_implementation_sha256=sink_implementation_sha256,
            sink_instance_sha256=sink_instance_sha256,
            base_global_sequence=base_global_sequence,
            maximum_results=maximum_results,
        )
        directory_fd, lock_fd = cls._open_directory_and_lock(path)
        try:
            try:
                os.stat(
                    ACTIVE_SELECTOR_NAME,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            else:
                raise SinkStorageError("result sink already exists")

            encoded_ledger = _encode_ledger(
                request_sha256=values[0],
                request_epoch=values[1],
                sink_implementation_sha256=values[2],
                sink_instance_sha256=values[3],
                base_global_sequence=values[4],
                acknowledgement_wires=(),
            )
            ledger = _decode_ledger(
                encoded_ledger,
                expected_request_sha256=values[0],
                expected_request_epoch=values[1],
                expected_sink_implementation_sha256=values[2],
                expected_sink_instance_sha256=values[3],
                expected_base_global_sequence=values[4],
                expected_maximum_results=values[5],
            )
            selector_encoded = _encode_selector(
                ledger=ledger,
                previous_selector_sha256=ZERO_DIGEST,
            )
            selector = _decode_selector(
                selector_encoded,
                expected_request_sha256=values[0],
                expected_request_epoch=values[1],
                expected_sink_implementation_sha256=values[2],
                expected_sink_instance_sha256=values[3],
                expected_base_global_sequence=values[4],
                expected_maximum_results=values[5],
            )
            cls._publish_initial(
                directory_fd,
                encoded_ledger,
                selector_encoded,
            )
            return cls(
                path=path,
                directory_fd=directory_fd,
                lock_fd=lock_fd,
                request_sha256=values[0],
                request_epoch=values[1],
                sink_implementation_sha256=values[2],
                sink_instance_sha256=values[3],
                base_global_sequence=values[4],
                maximum_results=values[5],
                ledger=ledger,
                selector=selector,
            )
        except BaseException:
            os.close(lock_fd)
            os.close(directory_fd)
            raise

    @classmethod
    def open(
        cls,
        directory: PathLike,
        *,
        request_sha256: Digest,
        request_epoch: int,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        base_global_sequence: int,
        maximum_results: int,
    ) -> "ResultSinkV1":
        path = Path(directory)
        values = cls._validate_identity(
            request_sha256=request_sha256,
            request_epoch=request_epoch,
            sink_implementation_sha256=sink_implementation_sha256,
            sink_instance_sha256=sink_instance_sha256,
            base_global_sequence=base_global_sequence,
            maximum_results=maximum_results,
        )
        directory_fd, lock_fd = cls._open_directory_and_lock(path)
        try:
            selector_encoded = _read_file_at(
                directory_fd,
                ACTIVE_SELECTOR_NAME,
                SELECTOR_BYTES,
            )
            selector = _decode_selector(
                selector_encoded,
                expected_request_sha256=values[0],
                expected_request_epoch=values[1],
                expected_sink_implementation_sha256=values[2],
                expected_sink_instance_sha256=values[3],
                expected_base_global_sequence=values[4],
                expected_maximum_results=values[5],
            )
            maximum_ledger_bytes = (
                LEDGER_HEADER_BYTES
                + values[5] * ACKNOWLEDGEMENT_BYTES
                + LEDGER_FOOTER_BYTES
            )
            ledger_encoded = _read_file_at(
                directory_fd,
                _ledger_name(selector.ledger_sha256),
                maximum_ledger_bytes,
            )
            ledger = _decode_ledger(
                ledger_encoded,
                expected_request_sha256=values[0],
                expected_request_epoch=values[1],
                expected_sink_implementation_sha256=values[2],
                expected_sink_instance_sha256=values[3],
                expected_base_global_sequence=values[4],
                expected_maximum_results=values[5],
            )
            cls._validate_pair(ledger, selector)
            return cls(
                path=path,
                directory_fd=directory_fd,
                lock_fd=lock_fd,
                request_sha256=values[0],
                request_epoch=values[1],
                sink_implementation_sha256=values[2],
                sink_instance_sha256=values[3],
                base_global_sequence=values[4],
                maximum_results=values[5],
                ledger=ledger,
                selector=selector,
            )
        except BaseException:
            os.close(lock_fd)
            os.close(directory_fd)
            raise

    @staticmethod
    def _validate_identity(
        *,
        request_sha256: Digest,
        request_epoch: int,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        base_global_sequence: int,
        maximum_results: int,
    ) -> tuple[Digest, int, Digest, Digest, int, int]:
        request = _digest(request_sha256, "request")
        implementation = _digest(
            sink_implementation_sha256,
            "sink implementation",
        )
        instance = _digest(sink_instance_sha256, "sink instance")
        _u64(request_epoch, "request epoch")
        _u64(base_global_sequence, "base global sequence")
        _u64(maximum_results, "maximum results")
        if request_epoch == 0 or maximum_results == 0:
            raise SinkIdentityMismatch("sink epoch or capacity is zero")
        _checked_add(
            base_global_sequence,
            maximum_results,
            "maximum global sequence",
        )
        return (
            request,
            request_epoch,
            implementation,
            instance,
            base_global_sequence,
            maximum_results,
        )

    @staticmethod
    def _open_directory_and_lock(path: Path) -> tuple[int, int]:
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            directory_fd = os.open(path, flags)
        except OSError as error:
            raise SinkStorageError("cannot open result sink directory") from error
        try:
            lock_fd = _open_regular_at(
                directory_fd,
                LOCK_NAME,
                os.O_RDWR | os.O_CREAT,
            )
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                os.close(lock_fd)
                if error.errno in (errno.EACCES, errno.EAGAIN):
                    raise SinkBusy("result sink is already leased") from error
                raise SinkStorageError("cannot lock result sink") from error
            return directory_fd, lock_fd
        except BaseException:
            os.close(directory_fd)
            raise

    @staticmethod
    def _publish_initial(
        directory_fd: int,
        encoded_ledger: bytes,
        encoded_selector: bytes,
    ) -> None:
        ledger_root = encoded_ledger[-LEDGER_FOOTER_BYTES:]
        ledger_name = _ledger_name(ledger_root)
        ledger_fd = _open_regular_at(
            directory_fd,
            ledger_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        )
        try:
            _write_all(ledger_fd, encoded_ledger)
            os.fsync(ledger_fd)
        except OSError as error:
            raise SinkStorageError("cannot sync initial ledger") from error
        finally:
            os.close(ledger_fd)
        _sync_directory(directory_fd)
        selector_fd = _open_regular_at(
            directory_fd,
            ACTIVE_SELECTOR_NAME,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        )
        try:
            _write_all(selector_fd, encoded_selector)
            os.fsync(selector_fd)
        except OSError as error:
            raise SinkStorageError("cannot sync initial selector") from error
        finally:
            os.close(selector_fd)
        _sync_directory(directory_fd)

    @staticmethod
    def _validate_pair(ledger: _LedgerV1, selector: _SelectorV1) -> None:
        count = len(ledger.acknowledgements)
        if (
            selector.generation != count + 1
            or selector.request_epoch != ledger.request_epoch
            or selector.base_global_sequence != ledger.base_global_sequence
            or selector.next_global_sequence != ledger.next_global_sequence
            or selector.ledger_bytes != len(ledger.encoded)
            or selector.request_sha256 != ledger.request_sha256
            or selector.sink_implementation_sha256 != ledger.sink_implementation_sha256
            or selector.sink_instance_sha256 != ledger.sink_instance_sha256
            or selector.ledger_sha256 != ledger.ledger_sha256
        ):
            raise SinkStorageError("selector does not bind exact ledger")

    def _require_ready(self) -> None:
        if self._closed:
            raise SinkStorageError("result sink is closed")
        if self._poisoned:
            raise SinkStorageError("result sink requires reopen after failure")

    def snapshot(self) -> SinkSnapshotV1:
        self._require_ready()
        count = len(self._ledger.acknowledgements)
        return SinkSnapshotV1(
            request_sha256=self.request_sha256,
            request_epoch=self.request_epoch,
            sink_implementation_sha256=self.sink_implementation_sha256,
            sink_instance_sha256=self.sink_instance_sha256,
            base_global_sequence=self.base_global_sequence,
            next_global_sequence=self._ledger.next_global_sequence,
            applied_count=count,
            maximum_results=self.maximum_results,
            generation=self._selector.generation,
            head_acknowledgement_sha256=(
                self._ledger.acknowledgements[-1].acknowledgement_sha256
                if count
                else ZERO_DIGEST
            ),
            result_sink_prefix_sha256=(
                self._ledger.acknowledgements[-1].result_sink_prefix_sha256
                if count
                else ZERO_DIGEST
            ),
            ledger_sha256=self._ledger.ledger_sha256,
            selector_sha256=self._selector.selector_sha256,
            ledger_bytes=len(self._ledger.encoded),
        )

    def apply(
        self,
        encoded_acknowledgement: bytes,
        *,
        crash_after: Optional[str] = None,
        phase_observer: Optional[Callable[[str], None]] = None,
    ) -> ApplyReceiptV1:
        self._require_ready()
        if crash_after is not None and crash_after not in IO_PHASES:
            raise PreparedTextResultSinkError("unknown injected crash phase")
        ack = decode_acknowledgement_v1(
            encoded_acknowledgement,
            expected_request_sha256=self.request_sha256,
            expected_request_epoch=self.request_epoch,
            expected_sink_implementation_sha256=(self.sink_implementation_sha256),
            expected_sink_instance_sha256=self.sink_instance_sha256,
        )
        count = len(self._ledger.acknowledgements)
        if ack.transaction_sequence < self.base_global_sequence:
            raise SinkSequenceGap("acknowledgement precedes sink base")
        index = ack.transaction_sequence - self.base_global_sequence
        if index < count:
            retained = self._ledger.acknowledgements[index]
            if hmac.compare_digest(retained.encoded, ack.encoded):
                return self._receipt(ALREADY_APPLIED, retained)
            raise SinkConflict("sequence already names a different result")
        if index > count:
            raise SinkSequenceGap("acknowledgement skips next sequence")
        if count >= self.maximum_results:
            raise SinkCapacityExceeded("result sink is full")
        previous_ack = (
            self._ledger.acknowledgements[-1].acknowledgement_sha256
            if count
            else ZERO_DIGEST
        )
        previous_prefix = (
            self._ledger.acknowledgements[-1].result_sink_prefix_sha256
            if count
            else ZERO_DIGEST
        )
        if (
            ack.application_ordinal != count + 1
            or ack.predecessor_acknowledgement_sha256 != previous_ack
            or ack.predecessor_sink_prefix_sha256 != previous_prefix
            or any(
                retained.delivery_key_sha256 == ack.delivery_key_sha256
                for retained in self._ledger.acknowledgements
            )
        ):
            raise SinkConflict("acknowledgement does not extend exact sink head")

        new_wires = tuple(value.encoded for value in self._ledger.acknowledgements) + (
            ack.encoded,
        )
        encoded_ledger = _encode_ledger(
            request_sha256=self.request_sha256,
            request_epoch=self.request_epoch,
            sink_implementation_sha256=self.sink_implementation_sha256,
            sink_instance_sha256=self.sink_instance_sha256,
            base_global_sequence=self.base_global_sequence,
            acknowledgement_wires=new_wires,
        )
        new_ledger = _decode_ledger(
            encoded_ledger,
            expected_request_sha256=self.request_sha256,
            expected_request_epoch=self.request_epoch,
            expected_sink_implementation_sha256=(self.sink_implementation_sha256),
            expected_sink_instance_sha256=self.sink_instance_sha256,
            expected_base_global_sequence=self.base_global_sequence,
            expected_maximum_results=self.maximum_results,
        )
        encoded_selector = _encode_selector(
            ledger=new_ledger,
            previous_selector_sha256=self._selector.selector_sha256,
        )
        new_selector = _decode_selector(
            encoded_selector,
            expected_request_sha256=self.request_sha256,
            expected_request_epoch=self.request_epoch,
            expected_sink_implementation_sha256=(self.sink_implementation_sha256),
            expected_sink_instance_sha256=self.sink_instance_sha256,
            expected_base_global_sequence=self.base_global_sequence,
            expected_maximum_results=self.maximum_results,
        )
        self._validate_pair(new_ledger, new_selector)

        def after(phase: str) -> None:
            if phase_observer is not None:
                phase_observer(phase)
            if phase == crash_after:
                self._poisoned = True
                raise InjectedCrash(phase)

        try:
            self._publish_successor(
                encoded_ledger,
                encoded_selector,
                after,
            )
        except BaseException:
            self._poisoned = True
            raise
        self._ledger = new_ledger
        self._selector = new_selector
        return self._receipt(APPLIED, ack)

    def _publish_successor(
        self,
        encoded_ledger: bytes,
        encoded_selector: bytes,
        after: Callable[[str], None],
    ) -> None:
        ledger_temp = _temporary_name("ledger")
        ledger_fd = _open_regular_at(
            self._directory_fd,
            ledger_temp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        )
        try:
            body = encoded_ledger[:-LEDGER_FOOTER_BYTES]
            footer = encoded_ledger[-LEDGER_FOOTER_BYTES:]
            _write_all(ledger_fd, body)
            after(LEDGER_BODY_WRITE)
            try:
                os.fsync(ledger_fd)
            except OSError as error:
                raise SinkStorageError("ledger body sync failed") from error
            after(LEDGER_BODY_SYNC)
            _write_all(ledger_fd, footer)
            after(LEDGER_FOOTER_WRITE)
            try:
                os.fsync(ledger_fd)
            except OSError as error:
                raise SinkStorageError("ledger file sync failed") from error
            after(LEDGER_FILE_SYNC)
        finally:
            os.close(ledger_fd)

        ledger_name = _ledger_name(footer)
        try:
            os.stat(
                ledger_name,
                dir_fd=self._directory_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            try:
                os.rename(
                    ledger_temp,
                    ledger_name,
                    src_dir_fd=self._directory_fd,
                    dst_dir_fd=self._directory_fd,
                )
            except OSError as error:
                raise SinkStorageError("ledger immutable rename failed") from error
        else:
            retained = _read_file_at(
                self._directory_fd,
                ledger_name,
                len(encoded_ledger),
            )
            if not hmac.compare_digest(retained, encoded_ledger):
                raise SinkStorageError("ledger root names conflicting bytes")
            try:
                os.unlink(ledger_temp, dir_fd=self._directory_fd)
            except OSError as error:
                raise SinkStorageError("cannot discard duplicate ledger") from error
        after(LEDGER_IMMUTABLE_RENAME)
        _sync_directory(self._directory_fd)
        after(LEDGER_DIRECTORY_SYNC)

        selector_temp = _temporary_name("selector")
        selector_fd = _open_regular_at(
            self._directory_fd,
            selector_temp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        )
        try:
            _write_all(selector_fd, encoded_selector)
            after(SELECTOR_TEMP_WRITE)
            try:
                os.fsync(selector_fd)
            except OSError as error:
                raise SinkStorageError("selector sync failed") from error
            after(SELECTOR_TEMP_SYNC)
        finally:
            os.close(selector_fd)
        try:
            os.replace(
                selector_temp,
                ACTIVE_SELECTOR_NAME,
                src_dir_fd=self._directory_fd,
                dst_dir_fd=self._directory_fd,
            )
        except OSError as error:
            raise SinkStorageError("selector replacement failed") from error
        after(SELECTOR_REPLACE)
        _sync_directory(self._directory_fd)
        after(SELECTOR_DIRECTORY_SYNC)

    def _receipt(
        self,
        disposition: str,
        acknowledgement: ResultAcknowledgementV1,
    ) -> ApplyReceiptV1:
        return ApplyReceiptV1(
            disposition=disposition,
            transaction_sequence=acknowledgement.transaction_sequence,
            application_ordinal=acknowledgement.application_ordinal,
            applied_count=len(self._ledger.acknowledgements),
            acknowledgement_sha256=(acknowledgement.acknowledgement_sha256),
            result_sink_prefix_sha256=(acknowledgement.result_sink_prefix_sha256),
            ledger_sha256=self._ledger.ledger_sha256,
            selector_sha256=self._selector.selector_sha256,
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(self._lock_fd)
            os.close(self._directory_fd)

    def __enter__(self) -> "ResultSinkV1":
        self._require_ready()
        return self

    def __exit__(
        self,
        exc_type: object,
        exc: object,
        traceback: object,
    ) -> None:
        self.close()


__all__ = (
    "ACKNOWLEDGEMENT_ABI",
    "ACKNOWLEDGEMENT_BODY_BYTES",
    "ACKNOWLEDGEMENT_BYTES",
    "ACKNOWLEDGEMENT_MAGIC",
    "ALREADY_APPLIED",
    "APPLIED",
    "AcknowledgementError",
    "ApplyReceiptV1",
    "IO_PHASES",
    "InjectedCrash",
    "PreparedTextResultSinkError",
    "ResultAcknowledgementV1",
    "ResultSinkV1",
    "SinkBusy",
    "SinkCapacityExceeded",
    "SinkConflict",
    "SinkIdentityMismatch",
    "SinkSequenceGap",
    "SinkSnapshotV1",
    "SinkStorageError",
    "acknowledgement_sha256_v1",
    "decode_ack_v1",
    "decode_acknowledgement_v1",
    "delivery_key_sha256_v1",
    "encode_ack_v1",
    "encode_acknowledgement_v1",
    "result_sink_prefix_sha256_v1",
)
