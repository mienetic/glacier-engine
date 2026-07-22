#!/usr/bin/env python3
"""Canonical offline replay for the runner-v6 strict-B4 TokenTxn journal.

This is a new wire contract.  It does not extend, reinterpret, or accept the
legacy lane-at-a-time ``raw-event-evidence-v3`` profile.  A valid document is
exactly 65 canonical ASCII JSONL records: one sealed journal receipt followed
by the 64 committed TokenTxn waves in transaction order.

The compact runner journal does not retain the full TokenTxn proposal, so its
proposal digest remains an opaque commitment.  The prepare acknowledgement,
commit digest, ResourceBank receipt digest, runner wave chain, and an
out-of-band trusted chain head still bind that commitment without pretending
that the compact replay can reconstruct proposal-only KV/RNG fields.

TokenTxn's commit callback has no fallible clock boundary.  Consequently this
contract admits no timestamp field and requires the sole availability marker
to be ``false``.  Timing must come from a separately labelled observation.

All integer values on the wire are fixed-width lowercase hexadecimal strings.
Object key order is normative and follows the tuples below.  JSON numbers,
``null``, duplicate keys, non-ASCII text, alternate key order, missing final
newlines, and unknown fields fail closed.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any, Mapping, Sequence


RAW_EVENT_SCHEMA = "glacier.decode-lane4/token-txn-raw-event-evidence-v4"

OBSERVATION_ABI = 0x474C_344F_0000_0002
DECODE_LANE4_ABI = 0x4744_4C34_0000_0004
B4_TOKEN_TXN_JOURNAL_ABI = 0x4742_3454_0000_0001
TOKEN_TXN_ABI = 0x4754_584E_0000_0001
TOKEN_TXN_SINK_ABI = 0x4754_5853_0000_0001
TOKEN_TXN_PREPARE_ACK_ABI = 0x4754_5841_0000_0001
TOKEN_TXN_COMMIT_RECEIPT_ABI = 0x4754_5843_0000_0001
RESOURCE_BANK_ABI = 0x4752_424B_0000_0001

LANE_COUNT = 4
TRANSACTION_COUNT = 64
LANE_TRANSITION_COUNT = LANE_COUNT * TRANSACTION_COUNT
KV_TRANSITION_COUNT = LANE_COUNT * (TRANSACTION_COUNT - 1)
RECORD_COUNT = 1 + TRANSACTION_COUNT
SINK_EPOCH_XOR = 0x4234_5349_4E4B_0001

# The 64 wave records already carry every token in the 4 x 64 output matrix.
# The trusted matrix remains out of band so replay can detect substitution;
# adding a 66th, candidate-supplied output record would only duplicate evidence.

INITIAL_HASH_DOMAIN = b"glacier-lane4-runner-b4-token-txn-root-v1\x00"
WAVE_HASH_DOMAIN = b"glacier-lane4-runner-b4-token-txn-wave-v1\x00"
RESOURCE_RECEIPT_HASH_DOMAIN = b"glacier-lane4-runner-resource-receipt-v1\x00"
COMMIT_HASH_DOMAIN = b"glacier-token-txn-commit-v1\x00"
CANONICAL_JSONL_HASH_DOMAIN = b"glacier-lane4-token-txn-canonical-jsonl-v4\x00"

# Match the fixed Zig codec buffer.  Valid v4 records are much smaller because
# every string/array width is exact, but rejecting before splitting or parsing
# keeps the offline surface explicitly bounded.
MAX_RECORD_LINE_BYTES = 16 * 1024
MAX_EVIDENCE_BYTES = RECORD_COUNT * MAX_RECORD_LINE_BYTES
U8_MAX = (1 << 8) - 1
U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1

_U8_HEX_RE = re.compile(r"[0-9a-f]{2}")
_U32_HEX_RE = re.compile(r"[0-9a-f]{8}")
_U64_HEX_RE = re.compile(r"[0-9a-f]{16}")
_SHA256_RE = re.compile(r"[0-9a-f]{64}")

TOP_RECORD_FIELDS = (
    "schema",
    "kind",
    "observation_abi",
    "decode_lane4_abi",
    "journal_receipt",
)
JOURNAL_RECEIPT_FIELDS = (
    "abi_version",
    "token_txn_abi",
    "token_txn_sink_abi",
    "token_txn_prepare_ack_abi",
    "token_txn_commit_receipt_abi",
    "resource_bank_abi",
    "request_epoch",
    "expected_transaction_count",
    "prepare_count",
    "commit_count",
    "abort_count",
    "lane_transition_count",
    "kv_transition_count",
    "first_sequence",
    "last_sequence",
    "root_binding_sha256",
    "resource_receipt",
    "initial_sha256",
    "head_sha256",
    "commit_timestamps_available",
)
RESOURCE_RECEIPT_FIELDS = (
    "bank_epoch",
    "slot_index",
    "generation",
    "owner_key",
    "claim",
    "integrity",
)
RESOURCE_BYTE_CLAIM_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "logits_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "device_bytes",
    "io_bytes",
)
RESOURCE_CLAIM_FIELDS = (
    *RESOURCE_BYTE_CLAIM_FIELDS,
    "queue_slots",
)
WAVE_RECORD_FIELDS = (
    "schema",
    "kind",
    "record_sequence",
    "wave",
)
WAVE_FIELDS = (
    "abi_version",
    "token_txn_abi",
    "token_txn_sink_abi",
    "previous_sha256",
    "receipt",
    "wave_sha256",
)
WAVE_RECEIPT_FIELDS = (
    "abi_version",
    "proposal_abi",
    "sink_abi",
    "request_epoch",
    "transaction_sequence",
    "resource_permit_generation",
    "live_mask",
    "live_lane_count",
    "kv_transition_mask",
    "terminal_mask",
    "lane_step_indices",
    "token_ids",
    "resource_receipt_sha256",
    "proposal_sha256",
    "prepare_ack",
    "commit_sha256",
)
PREPARE_ACK_FIELDS = (
    "abi_version",
    "proposal_sha256",
    "sink_epoch",
    "reservation_id",
)


class TokenTxnEvidenceError(RuntimeError):
    """The v4 journal is malformed, noncanonical, or fails replay."""


@dataclass(frozen=True)
class ResourceClaimV1:
    capsule_bytes: int
    kv_bytes: int
    activation_bytes: int
    partial_bytes: int
    logits_bytes: int
    output_journal_bytes: int
    staging_bytes: int
    device_bytes: int
    io_bytes: int
    queue_slots: int


@dataclass(frozen=True)
class ResourceReceiptV1:
    bank_epoch: int
    slot_index: int
    generation: int
    owner_key: int
    claim: ResourceClaimV1
    integrity: int


@dataclass(frozen=True)
class PrepareAckV1:
    abi_version: int
    proposal_sha256: str
    sink_epoch: int
    reservation_id: int


@dataclass(frozen=True)
class WaveReceiptV1:
    abi_version: int
    proposal_abi: int
    sink_abi: int
    request_epoch: int
    transaction_sequence: int
    resource_permit_generation: int
    live_mask: int
    live_lane_count: int
    kv_transition_mask: int
    terminal_mask: int
    lane_step_indices: tuple[int, int, int, int]
    token_ids: tuple[int, int, int, int]
    resource_receipt_sha256: str
    proposal_sha256: str
    prepare_ack: PrepareAckV1
    commit_sha256: str


@dataclass(frozen=True)
class WaveV1:
    abi_version: int
    token_txn_abi: int
    token_txn_sink_abi: int
    previous_sha256: str
    receipt: WaveReceiptV1
    wave_sha256: str


@dataclass(frozen=True)
class JournalReceiptV1:
    abi_version: int
    token_txn_abi: int
    token_txn_sink_abi: int
    token_txn_prepare_ack_abi: int
    token_txn_commit_receipt_abi: int
    resource_bank_abi: int
    request_epoch: int
    expected_transaction_count: int
    prepare_count: int
    commit_count: int
    abort_count: int
    lane_transition_count: int
    kv_transition_count: int
    first_sequence: int
    last_sequence: int
    root_binding_sha256: str
    resource_receipt: ResourceReceiptV1
    initial_sha256: str
    head_sha256: str
    commit_timestamps_available: bool


@dataclass(frozen=True)
class ReplayExpectation:
    """Trusted identity and outputs required to admit an offline replay."""

    root_binding_sha256: str
    request_epoch: int
    resource_receipt_sha256: str
    head_sha256: str
    lane_outputs: tuple[tuple[int, ...], ...]


@dataclass(frozen=True)
class ValidatedTokenTxnEvidence:
    journal_receipt: JournalReceiptV1
    waves: tuple[WaveV1, ...]
    lane_outputs: tuple[tuple[int, ...], ...]


def u8_hex(value: int) -> str:
    """Encode a u8 as exactly two lowercase hexadecimal digits."""

    _require_int_range(value, U8_MAX, "u8 value")
    return f"{value:02x}"


def u32_hex(value: int) -> str:
    """Encode a u32 as exactly eight lowercase hexadecimal digits."""

    _require_int_range(value, U32_MAX, "u32 value")
    return f"{value:08x}"


def u64_hex(value: int) -> str:
    """Encode a u64 as exactly sixteen lowercase hexadecimal digits."""

    _require_int_range(value, U64_MAX, "u64 value")
    return f"{value:016x}"


def _require_int_range(value: Any, maximum: int, where: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise TokenTxnEvidenceError(f"{where} is outside its unsigned range")
    return value


def _printable_ascii(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise TokenTxnEvidenceError(f"{where} must be a non-empty string")
    if any(ord(character) < 0x20 or ord(character) > 0x7E for character in value):
        raise TokenTxnEvidenceError(f"{where} must contain printable ASCII only")
    return value


def _require_fixed_hex(value: Any, pattern: re.Pattern[str], where: str) -> int:
    text = _printable_ascii(value, where)
    if pattern.fullmatch(text) is None:
        raise TokenTxnEvidenceError(f"{where} has a noncanonical hexadecimal width")
    return int(text, 16)


def require_u8_hex(value: Any, where: str) -> int:
    return _require_fixed_hex(value, _U8_HEX_RE, where)


def require_u32_hex(value: Any, where: str) -> int:
    return _require_fixed_hex(value, _U32_HEX_RE, where)


def require_u64_hex(value: Any, where: str) -> int:
    return _require_fixed_hex(value, _U64_HEX_RE, where)


def require_sha256(value: Any, where: str) -> str:
    text = _printable_ascii(value, where)
    if _SHA256_RE.fullmatch(text) is None:
        raise TokenTxnEvidenceError(
            f"{where} must be exactly 64 lowercase hexadecimal digits"
        )
    return text


def _mapping(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise TokenTxnEvidenceError(f"{where} must be an object with string keys")
    return value


def _exact_keys(value: Mapping[str, Any], expected: tuple[str, ...], where: str) -> None:
    actual = tuple(value.keys())
    if actual != expected:
        raise TokenTxnEvidenceError(
            f"{where} keys/order mismatch: expected {expected!r}, got {actual!r}"
        )


def _array(value: Any, length: int, where: str) -> list[Any]:
    if not isinstance(value, list) or len(value) != length:
        raise TokenTxnEvidenceError(f"{where} must be an array of length {length}")
    return value


def _validate_canonical_value_inner(value: Any, where: str) -> None:
    if isinstance(value, bool):
        return
    if isinstance(value, str):
        _printable_ascii(value, where)
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_canonical_value_inner(item, f"{where}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            _printable_ascii(key, f"{where} key")
            _validate_canonical_value_inner(item, f"{where}.{key}")
        return
    raise TokenTxnEvidenceError(
        f"{where} must use only ordered objects, arrays, printable ASCII "
        "strings, or booleans; JSON numbers and null are forbidden"
    )


def _validate_canonical_value(value: Any, where: str) -> None:
    try:
        _validate_canonical_value_inner(value, where)
    except RecursionError as exc:
        raise TokenTxnEvidenceError(f"{where} nesting is too deep") from exc


def canonical_ascii_json(value: Any) -> bytes:
    """Encode one value while preserving the contract's normative key order."""

    _validate_canonical_value(value, "value")
    try:
        return json.dumps(
            value,
            sort_keys=False,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
    except RecursionError as exc:
        raise TokenTxnEvidenceError("value nesting is too deep to encode") from exc
    except (TypeError, ValueError, UnicodeError) as exc:
        raise TokenTxnEvidenceError(f"value cannot be encoded canonically: {exc}") from exc


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise TokenTxnEvidenceError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_json_number(value: str) -> None:
    raise TokenTxnEvidenceError(f"JSON number {value!r} is forbidden")


def _load_record_line(line: bytes, line_index: int) -> dict[str, Any]:
    if not line or len(line) > MAX_RECORD_LINE_BYTES:
        raise TokenTxnEvidenceError(f"record {line_index} is empty or too large")
    if not line.endswith(b"\n") or line.count(b"\n") != 1:
        raise TokenTxnEvidenceError(f"record {line_index} is not one complete JSONL line")
    try:
        text = line[:-1].decode("ascii")
    except UnicodeDecodeError as exc:
        raise TokenTxnEvidenceError(f"record {line_index} must be ASCII") from exc
    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_int=_reject_json_number,
            parse_float=_reject_json_number,
            parse_constant=_reject_json_number,
        )
    except TokenTxnEvidenceError:
        raise
    except RecursionError as exc:
        raise TokenTxnEvidenceError(
            f"record {line_index} JSON nesting is too deep"
        ) from exc
    except json.JSONDecodeError as exc:
        raise TokenTxnEvidenceError(f"record {line_index} is invalid JSON: {exc}") from exc
    record = _mapping(value, f"record {line_index}")
    _validate_canonical_value(record, f"record {line_index}")
    if line != canonical_ascii_json(record) + b"\n":
        raise TokenTxnEvidenceError(f"record {line_index} is not canonical ASCII JSONL")
    return record


def _parse_resource_claim(value: Any, where: str) -> ResourceClaimV1:
    claim = _mapping(value, where)
    _exact_keys(claim, RESOURCE_CLAIM_FIELDS, where)
    parsed = [require_u64_hex(claim[field], f"{where}.{field}") for field in RESOURCE_CLAIM_FIELDS]
    return ResourceClaimV1(*parsed)


def _parse_resource_receipt(value: Any, where: str) -> ResourceReceiptV1:
    receipt = _mapping(value, where)
    _exact_keys(receipt, RESOURCE_RECEIPT_FIELDS, where)
    return ResourceReceiptV1(
        bank_epoch=require_u64_hex(receipt["bank_epoch"], f"{where}.bank_epoch"),
        slot_index=require_u32_hex(receipt["slot_index"], f"{where}.slot_index"),
        generation=require_u64_hex(receipt["generation"], f"{where}.generation"),
        owner_key=require_u64_hex(receipt["owner_key"], f"{where}.owner_key"),
        claim=_parse_resource_claim(receipt["claim"], f"{where}.claim"),
        integrity=require_u64_hex(receipt["integrity"], f"{where}.integrity"),
    )


def _parse_prepare_ack(value: Any, where: str) -> PrepareAckV1:
    ack = _mapping(value, where)
    _exact_keys(ack, PREPARE_ACK_FIELDS, where)
    return PrepareAckV1(
        abi_version=require_u64_hex(ack["abi_version"], f"{where}.abi_version"),
        proposal_sha256=require_sha256(
            ack["proposal_sha256"], f"{where}.proposal_sha256"
        ),
        sink_epoch=require_u64_hex(ack["sink_epoch"], f"{where}.sink_epoch"),
        reservation_id=require_u64_hex(
            ack["reservation_id"], f"{where}.reservation_id"
        ),
    )


def _parse_wave_receipt(value: Any, where: str) -> WaveReceiptV1:
    receipt = _mapping(value, where)
    _exact_keys(receipt, WAVE_RECEIPT_FIELDS, where)
    steps = _array(receipt["lane_step_indices"], LANE_COUNT, f"{where}.lane_step_indices")
    tokens = _array(receipt["token_ids"], LANE_COUNT, f"{where}.token_ids")
    return WaveReceiptV1(
        abi_version=require_u64_hex(receipt["abi_version"], f"{where}.abi_version"),
        proposal_abi=require_u64_hex(receipt["proposal_abi"], f"{where}.proposal_abi"),
        sink_abi=require_u64_hex(receipt["sink_abi"], f"{where}.sink_abi"),
        request_epoch=require_u64_hex(receipt["request_epoch"], f"{where}.request_epoch"),
        transaction_sequence=require_u64_hex(
            receipt["transaction_sequence"], f"{where}.transaction_sequence"
        ),
        resource_permit_generation=require_u64_hex(
            receipt["resource_permit_generation"],
            f"{where}.resource_permit_generation",
        ),
        live_mask=require_u8_hex(receipt["live_mask"], f"{where}.live_mask"),
        live_lane_count=require_u8_hex(
            receipt["live_lane_count"], f"{where}.live_lane_count"
        ),
        kv_transition_mask=require_u8_hex(
            receipt["kv_transition_mask"], f"{where}.kv_transition_mask"
        ),
        terminal_mask=require_u8_hex(
            receipt["terminal_mask"], f"{where}.terminal_mask"
        ),
        lane_step_indices=tuple(
            require_u64_hex(step, f"{where}.lane_step_indices[{index}]")
            for index, step in enumerate(steps)
        ),
        token_ids=tuple(
            require_u32_hex(token, f"{where}.token_ids[{index}]")
            for index, token in enumerate(tokens)
        ),
        resource_receipt_sha256=require_sha256(
            receipt["resource_receipt_sha256"],
            f"{where}.resource_receipt_sha256",
        ),
        proposal_sha256=require_sha256(
            receipt["proposal_sha256"], f"{where}.proposal_sha256"
        ),
        prepare_ack=_parse_prepare_ack(receipt["prepare_ack"], f"{where}.prepare_ack"),
        commit_sha256=require_sha256(
            receipt["commit_sha256"], f"{where}.commit_sha256"
        ),
    )


def _parse_wave(value: Any, where: str) -> WaveV1:
    wave = _mapping(value, where)
    _exact_keys(wave, WAVE_FIELDS, where)
    return WaveV1(
        abi_version=require_u64_hex(wave["abi_version"], f"{where}.abi_version"),
        token_txn_abi=require_u64_hex(wave["token_txn_abi"], f"{where}.token_txn_abi"),
        token_txn_sink_abi=require_u64_hex(
            wave["token_txn_sink_abi"], f"{where}.token_txn_sink_abi"
        ),
        previous_sha256=require_sha256(
            wave["previous_sha256"], f"{where}.previous_sha256"
        ),
        receipt=_parse_wave_receipt(wave["receipt"], f"{where}.receipt"),
        wave_sha256=require_sha256(wave["wave_sha256"], f"{where}.wave_sha256"),
    )


def _parse_journal_receipt(value: Any, where: str) -> JournalReceiptV1:
    receipt = _mapping(value, where)
    _exact_keys(receipt, JOURNAL_RECEIPT_FIELDS, where)
    timestamps = receipt["commit_timestamps_available"]
    if not isinstance(timestamps, bool):
        raise TokenTxnEvidenceError(f"{where}.commit_timestamps_available must be boolean")
    return JournalReceiptV1(
        abi_version=require_u64_hex(receipt["abi_version"], f"{where}.abi_version"),
        token_txn_abi=require_u64_hex(receipt["token_txn_abi"], f"{where}.token_txn_abi"),
        token_txn_sink_abi=require_u64_hex(
            receipt["token_txn_sink_abi"], f"{where}.token_txn_sink_abi"
        ),
        token_txn_prepare_ack_abi=require_u64_hex(
            receipt["token_txn_prepare_ack_abi"],
            f"{where}.token_txn_prepare_ack_abi",
        ),
        token_txn_commit_receipt_abi=require_u64_hex(
            receipt["token_txn_commit_receipt_abi"],
            f"{where}.token_txn_commit_receipt_abi",
        ),
        resource_bank_abi=require_u64_hex(
            receipt["resource_bank_abi"], f"{where}.resource_bank_abi"
        ),
        request_epoch=require_u64_hex(receipt["request_epoch"], f"{where}.request_epoch"),
        expected_transaction_count=require_u32_hex(
            receipt["expected_transaction_count"],
            f"{where}.expected_transaction_count",
        ),
        prepare_count=require_u32_hex(receipt["prepare_count"], f"{where}.prepare_count"),
        commit_count=require_u32_hex(receipt["commit_count"], f"{where}.commit_count"),
        abort_count=require_u32_hex(receipt["abort_count"], f"{where}.abort_count"),
        lane_transition_count=require_u32_hex(
            receipt["lane_transition_count"], f"{where}.lane_transition_count"
        ),
        kv_transition_count=require_u32_hex(
            receipt["kv_transition_count"], f"{where}.kv_transition_count"
        ),
        first_sequence=require_u64_hex(
            receipt["first_sequence"], f"{where}.first_sequence"
        ),
        last_sequence=require_u64_hex(receipt["last_sequence"], f"{where}.last_sequence"),
        root_binding_sha256=require_sha256(
            receipt["root_binding_sha256"], f"{where}.root_binding_sha256"
        ),
        resource_receipt=_parse_resource_receipt(
            receipt["resource_receipt"], f"{where}.resource_receipt"
        ),
        initial_sha256=require_sha256(
            receipt["initial_sha256"], f"{where}.initial_sha256"
        ),
        head_sha256=require_sha256(receipt["head_sha256"], f"{where}.head_sha256"),
        commit_timestamps_available=timestamps,
    )


def _hash_u8(digest: Any, value: int) -> None:
    digest.update(value.to_bytes(1, "little"))


def _hash_u32(digest: Any, value: int) -> None:
    digest.update(value.to_bytes(4, "little"))


def _hash_u64(digest: Any, value: int) -> None:
    digest.update(value.to_bytes(8, "little"))


def _resource_receipt_digest(receipt: ResourceReceiptV1) -> str:
    digest = hashlib.sha256()
    digest.update(RESOURCE_RECEIPT_HASH_DOMAIN)
    _hash_u64(digest, RESOURCE_BANK_ABI)
    _hash_u64(digest, receipt.bank_epoch)
    _hash_u32(digest, receipt.slot_index)
    _hash_u64(digest, receipt.generation)
    _hash_u64(digest, receipt.owner_key)
    for field in RESOURCE_CLAIM_FIELDS:
        _hash_u64(digest, getattr(receipt.claim, field))
    _hash_u64(digest, receipt.integrity)
    return digest.hexdigest()


def derive_resource_receipt_sha256(receipt: Mapping[str, Any]) -> str:
    """Match runner ``resourceReceiptSha256`` for the full Bank receipt."""

    return _resource_receipt_digest(_parse_resource_receipt(receipt, "resource_receipt"))


def derive_initial_sha256(root_binding_sha256: str, request_epoch: int) -> str:
    """Match runner ``initialB4TokenTxnSha256`` byte for byte."""

    root = bytes.fromhex(require_sha256(root_binding_sha256, "root_binding_sha256"))
    _require_int_range(request_epoch, U64_MAX, "request_epoch")
    digest = hashlib.sha256()
    digest.update(INITIAL_HASH_DOMAIN)
    for abi in (
        B4_TOKEN_TXN_JOURNAL_ABI,
        TOKEN_TXN_ABI,
        TOKEN_TXN_SINK_ABI,
        TOKEN_TXN_PREPARE_ACK_ABI,
        TOKEN_TXN_COMMIT_RECEIPT_ABI,
        RESOURCE_BANK_ABI,
    ):
        _hash_u64(digest, abi)
    _hash_u32(digest, LANE_COUNT)
    _hash_u32(digest, TRANSACTION_COUNT)
    _hash_u64(digest, request_epoch)
    digest.update(root)
    return digest.hexdigest()


def _commit_digest(proposal_sha256: str, ack: PrepareAckV1) -> str:
    proposal = bytes.fromhex(require_sha256(proposal_sha256, "proposal_sha256"))
    digest = hashlib.sha256()
    digest.update(COMMIT_HASH_DOMAIN)
    _hash_u64(digest, TOKEN_TXN_COMMIT_RECEIPT_ABI)
    digest.update(proposal)
    _hash_u64(digest, ack.abi_version)
    digest.update(bytes.fromhex(ack.proposal_sha256))
    _hash_u64(digest, ack.sink_epoch)
    _hash_u64(digest, ack.reservation_id)
    return digest.hexdigest()


def derive_commit_sha256(
    proposal_sha256: str,
    prepare_ack: Mapping[str, Any],
) -> str:
    """Match ``token_txn.commitSha256`` for one compact prepare ack."""

    return _commit_digest(
        proposal_sha256,
        _parse_prepare_ack(prepare_ack, "prepare_ack"),
    )


def _wave_digest(previous_sha256: str, receipt: WaveReceiptV1) -> str:
    previous = bytes.fromhex(require_sha256(previous_sha256, "previous_sha256"))
    digest = hashlib.sha256()
    digest.update(WAVE_HASH_DOMAIN)
    _hash_u64(digest, B4_TOKEN_TXN_JOURNAL_ABI)
    _hash_u64(digest, TOKEN_TXN_ABI)
    _hash_u64(digest, TOKEN_TXN_SINK_ABI)
    digest.update(previous)
    digest.update(bytes.fromhex(receipt.resource_receipt_sha256))
    digest.update(bytes.fromhex(receipt.proposal_sha256))
    digest.update(bytes.fromhex(receipt.commit_sha256))
    _hash_u64(digest, receipt.request_epoch)
    _hash_u64(digest, receipt.transaction_sequence)
    _hash_u64(digest, receipt.resource_permit_generation)
    _hash_u8(digest, receipt.live_mask)
    _hash_u8(digest, receipt.live_lane_count)
    _hash_u8(digest, receipt.kv_transition_mask)
    _hash_u8(digest, receipt.terminal_mask)
    for step, token_id in zip(receipt.lane_step_indices, receipt.token_ids):
        _hash_u64(digest, step)
        _hash_u32(digest, token_id)
    return digest.hexdigest()


def derive_wave_sha256(
    previous_sha256: str,
    receipt: Mapping[str, Any],
) -> str:
    """Match runner ``b4TokenTxnWaveSha256`` for one compact receipt."""

    return _wave_digest(
        previous_sha256,
        _parse_wave_receipt(receipt, "wave receipt"),
    )


def _validate_expectation(expectation: ReplayExpectation) -> tuple[tuple[int, ...], ...]:
    if not isinstance(expectation, ReplayExpectation):
        raise TokenTxnEvidenceError("expectation must be ReplayExpectation")
    root = require_sha256(expectation.root_binding_sha256, "expectation.root_binding_sha256")
    if root == "0" * 64:
        raise TokenTxnEvidenceError("expectation.root_binding_sha256 must be nonzero")
    _require_int_range(expectation.request_epoch, U64_MAX, "expectation.request_epoch")
    if expectation.request_epoch == 0 or expectation.request_epoch ^ SINK_EPOCH_XOR == 0:
        raise TokenTxnEvidenceError("expectation.request_epoch is invalid for the v1 sink")
    require_sha256(
        expectation.resource_receipt_sha256,
        "expectation.resource_receipt_sha256",
    )
    require_sha256(expectation.head_sha256, "expectation.head_sha256")
    if expectation.resource_receipt_sha256 == "0" * 64:
        raise TokenTxnEvidenceError("expectation.resource_receipt_sha256 must be nonzero")
    if expectation.head_sha256 == "0" * 64:
        raise TokenTxnEvidenceError("expectation.head_sha256 must be nonzero")
    if not isinstance(expectation.lane_outputs, tuple) or len(expectation.lane_outputs) != LANE_COUNT:
        raise TokenTxnEvidenceError("expectation.lane_outputs must contain exactly four tuples")
    outputs: list[tuple[int, ...]] = []
    for lane_index, lane in enumerate(expectation.lane_outputs):
        if not isinstance(lane, tuple) or len(lane) != TRANSACTION_COUNT:
            raise TokenTxnEvidenceError(
                f"expectation.lane_outputs[{lane_index}] must contain 64 tokens"
            )
        outputs.append(
            tuple(
                _require_int_range(token, U32_MAX, f"expectation.lane_outputs[{lane_index}][{step}]")
                for step, token in enumerate(lane)
            )
        )
    return tuple(outputs)


def _validate_journal_receipt(receipt: JournalReceiptV1) -> str:
    expected_values = (
        (receipt.abi_version, B4_TOKEN_TXN_JOURNAL_ABI, "abi_version"),
        (receipt.token_txn_abi, TOKEN_TXN_ABI, "token_txn_abi"),
        (receipt.token_txn_sink_abi, TOKEN_TXN_SINK_ABI, "token_txn_sink_abi"),
        (
            receipt.token_txn_prepare_ack_abi,
            TOKEN_TXN_PREPARE_ACK_ABI,
            "token_txn_prepare_ack_abi",
        ),
        (
            receipt.token_txn_commit_receipt_abi,
            TOKEN_TXN_COMMIT_RECEIPT_ABI,
            "token_txn_commit_receipt_abi",
        ),
        (receipt.resource_bank_abi, RESOURCE_BANK_ABI, "resource_bank_abi"),
        (
            receipt.expected_transaction_count,
            TRANSACTION_COUNT,
            "expected_transaction_count",
        ),
        (receipt.prepare_count, TRANSACTION_COUNT, "prepare_count"),
        (receipt.commit_count, TRANSACTION_COUNT, "commit_count"),
        (receipt.abort_count, 0, "abort_count"),
        (receipt.lane_transition_count, LANE_TRANSITION_COUNT, "lane_transition_count"),
        (receipt.kv_transition_count, KV_TRANSITION_COUNT, "kv_transition_count"),
        (receipt.first_sequence, 0, "first_sequence"),
        (receipt.last_sequence, TRANSACTION_COUNT - 1, "last_sequence"),
    )
    for actual, expected, field in expected_values:
        if actual != expected:
            raise TokenTxnEvidenceError(f"journal_receipt.{field} is not the fixed v4 value")
    if receipt.request_epoch == 0 or receipt.request_epoch ^ SINK_EPOCH_XOR == 0:
        raise TokenTxnEvidenceError("journal_receipt.request_epoch is invalid")
    if receipt.root_binding_sha256 == "0" * 64:
        raise TokenTxnEvidenceError("journal_receipt.root_binding_sha256 must be nonzero")
    bank_receipt = receipt.resource_receipt
    if (
        bank_receipt.bank_epoch == 0
        or bank_receipt.slot_index != 0
        or bank_receipt.generation == 0
        or bank_receipt.owner_key == 0
        or bank_receipt.integrity == 0
        or bank_receipt.claim.queue_slots != LANE_COUNT
    ):
        raise TokenTxnEvidenceError("resource_receipt is not a runner-v6 Bank receipt")
    if not any(
        getattr(bank_receipt.claim, field) != 0
        for field in RESOURCE_BYTE_CLAIM_FIELDS
    ):
        raise TokenTxnEvidenceError(
            "resource_receipt.claim must reserve nonzero bytes"
        )
    if receipt.commit_timestamps_available is not False:
        raise TokenTxnEvidenceError("commit timestamps must be explicitly unavailable")
    initial = derive_initial_sha256(receipt.root_binding_sha256, receipt.request_epoch)
    if receipt.initial_sha256 != initial:
        raise TokenTxnEvidenceError("journal_receipt.initial_sha256 is inconsistent")
    return _resource_receipt_digest(receipt.resource_receipt)


def _validate_wave(
    wave: WaveV1,
    sequence: int,
    request_epoch: int,
    resource_receipt_sha256: str,
    previous_sha256: str,
    expected_outputs: tuple[tuple[int, ...], ...] | None,
) -> str:
    receipt = wave.receipt
    if wave.abi_version != B4_TOKEN_TXN_JOURNAL_ABI:
        raise TokenTxnEvidenceError(f"wave {sequence} journal ABI mismatch")
    if wave.token_txn_abi != TOKEN_TXN_ABI or wave.token_txn_sink_abi != TOKEN_TXN_SINK_ABI:
        raise TokenTxnEvidenceError(f"wave {sequence} TokenTxn ABI mismatch")
    if wave.previous_sha256 != previous_sha256:
        raise TokenTxnEvidenceError(f"wave {sequence} previous hash mismatch")
    if receipt.abi_version != TOKEN_TXN_COMMIT_RECEIPT_ABI:
        raise TokenTxnEvidenceError(f"wave {sequence} commit receipt ABI mismatch")
    if receipt.proposal_abi != TOKEN_TXN_ABI or receipt.sink_abi != TOKEN_TXN_SINK_ABI:
        raise TokenTxnEvidenceError(f"wave {sequence} compact receipt ABI mismatch")
    if receipt.request_epoch != request_epoch or receipt.transaction_sequence != sequence:
        raise TokenTxnEvidenceError(f"wave {sequence} request/sequence mismatch")
    if receipt.resource_permit_generation != sequence + 1:
        raise TokenTxnEvidenceError(f"wave {sequence} permit generation mismatch")
    expected_kv_mask = 0 if sequence == 0 else 0x0F
    expected_terminal_mask = 0x0F if sequence == TRANSACTION_COUNT - 1 else 0
    if (
        receipt.live_mask != 0x0F
        or receipt.live_lane_count != LANE_COUNT
        or receipt.kv_transition_mask != expected_kv_mask
        or receipt.terminal_mask != expected_terminal_mask
    ):
        raise TokenTxnEvidenceError(f"wave {sequence} lane masks/count mismatch")
    if any(step != sequence for step in receipt.lane_step_indices):
        raise TokenTxnEvidenceError(f"wave {sequence} lane step mismatch")
    if receipt.resource_receipt_sha256 != resource_receipt_sha256:
        raise TokenTxnEvidenceError(f"wave {sequence} ResourceBank binding mismatch")
    if receipt.proposal_sha256 == "0" * 64:
        raise TokenTxnEvidenceError(f"wave {sequence} proposal digest must be nonzero")
    ack = receipt.prepare_ack
    if ack.abi_version != TOKEN_TXN_PREPARE_ACK_ABI:
        raise TokenTxnEvidenceError(f"wave {sequence} prepare ack ABI mismatch")
    if ack.proposal_sha256 != receipt.proposal_sha256:
        raise TokenTxnEvidenceError(f"wave {sequence} prepare ack proposal mismatch")
    if ack.sink_epoch != request_epoch ^ SINK_EPOCH_XOR:
        raise TokenTxnEvidenceError(f"wave {sequence} sink epoch mismatch")
    if ack.reservation_id != sequence + 1:
        raise TokenTxnEvidenceError(f"wave {sequence} reservation id mismatch")
    expected_commit = _commit_digest(receipt.proposal_sha256, ack)
    if receipt.commit_sha256 != expected_commit:
        raise TokenTxnEvidenceError(f"wave {sequence} commit digest mismatch")
    expected_wave = _wave_digest(previous_sha256, receipt)
    if wave.wave_sha256 != expected_wave:
        raise TokenTxnEvidenceError(f"wave {sequence} wave digest mismatch")
    if expected_outputs is not None:
        for lane_index, token_id in enumerate(receipt.token_ids):
            if token_id != expected_outputs[lane_index][sequence]:
                raise TokenTxnEvidenceError(
                    f"wave {sequence} lane {lane_index} output/token mismatch"
                )
    return expected_wave


def _decode_and_validate(
    data: bytes,
    expectation: ReplayExpectation | None,
) -> ValidatedTokenTxnEvidence:
    if not isinstance(data, bytes) or not data:
        raise TokenTxnEvidenceError("evidence must be non-empty bytes")
    if len(data) > MAX_EVIDENCE_BYTES:
        raise TokenTxnEvidenceError(
            f"evidence exceeds the {MAX_EVIDENCE_BYTES}-byte maximum"
        )
    if not data.endswith(b"\n"):
        raise TokenTxnEvidenceError("evidence is truncated or lacks its final newline")
    lines = data.splitlines(keepends=True)
    if len(lines) != RECORD_COUNT:
        raise TokenTxnEvidenceError(f"evidence must contain exactly {RECORD_COUNT} records")
    records = [_load_record_line(line, index) for index, line in enumerate(lines)]

    top = records[0]
    _exact_keys(top, TOP_RECORD_FIELDS, "top record")
    if top["schema"] != RAW_EVENT_SCHEMA or top["kind"] != "journal_receipt":
        raise TokenTxnEvidenceError("top record schema/kind mismatch")
    if require_u64_hex(top["observation_abi"], "top record.observation_abi") != OBSERVATION_ABI:
        raise TokenTxnEvidenceError("top record observation ABI mismatch")
    if require_u64_hex(top["decode_lane4_abi"], "top record.decode_lane4_abi") != DECODE_LANE4_ABI:
        raise TokenTxnEvidenceError("top record DecodeLane4 ABI mismatch")
    journal = _parse_journal_receipt(top["journal_receipt"], "journal_receipt")
    resource_digest = _validate_journal_receipt(journal)

    expected_outputs = _validate_expectation(expectation) if expectation is not None else None
    if expectation is not None:
        if journal.root_binding_sha256 != expectation.root_binding_sha256:
            raise TokenTxnEvidenceError("journal root binding does not match expectation")
        if journal.request_epoch != expectation.request_epoch:
            raise TokenTxnEvidenceError("journal request epoch does not match expectation")
        if resource_digest != expectation.resource_receipt_sha256:
            raise TokenTxnEvidenceError("ResourceBank receipt does not match expectation")
        if journal.head_sha256 != expectation.head_sha256:
            raise TokenTxnEvidenceError("journal head does not match expectation")

    previous = journal.initial_sha256
    waves: list[WaveV1] = []
    derived_outputs = [[] for _ in range(LANE_COUNT)]
    for sequence, record in enumerate(records[1:]):
        where = f"wave record {sequence}"
        _exact_keys(record, WAVE_RECORD_FIELDS, where)
        if record["schema"] != RAW_EVENT_SCHEMA or record["kind"] != "token_txn_wave":
            raise TokenTxnEvidenceError(f"{where} schema/kind mismatch")
        if require_u64_hex(record["record_sequence"], f"{where}.record_sequence") != sequence:
            raise TokenTxnEvidenceError(f"{where} sequence mismatch")
        wave = _parse_wave(record["wave"], f"{where}.wave")
        previous = _validate_wave(
            wave,
            sequence,
            journal.request_epoch,
            resource_digest,
            previous,
            expected_outputs,
        )
        waves.append(wave)
        for lane_index, token_id in enumerate(wave.receipt.token_ids):
            derived_outputs[lane_index].append(token_id)
    if previous != journal.head_sha256:
        raise TokenTxnEvidenceError("journal head does not match the final wave")

    return ValidatedTokenTxnEvidence(
        journal_receipt=journal,
        waves=tuple(waves),
        lane_outputs=tuple(tuple(lane) for lane in derived_outputs),
    )


def encode_token_txn_evidence(
    journal_receipt: Mapping[str, Any],
    waves: Sequence[Mapping[str, Any]],
) -> bytes:
    """Encode and internally replay one exact 64-wave journal."""

    if not isinstance(waves, Sequence) or isinstance(waves, (str, bytes, bytearray)):
        raise TokenTxnEvidenceError("waves must be a sequence")
    if len(waves) != TRANSACTION_COUNT:
        raise TokenTxnEvidenceError("waves must contain exactly 64 entries")
    records: list[dict[str, Any]] = [
        {
            "schema": RAW_EVENT_SCHEMA,
            "kind": "journal_receipt",
            "observation_abi": u64_hex(OBSERVATION_ABI),
            "decode_lane4_abi": u64_hex(DECODE_LANE4_ABI),
            "journal_receipt": dict(journal_receipt),
        }
    ]
    for sequence, wave in enumerate(waves):
        records.append(
            {
                "schema": RAW_EVENT_SCHEMA,
                "kind": "token_txn_wave",
                "record_sequence": u64_hex(sequence),
                "wave": dict(wave),
            }
        )
    encoded = b"".join(canonical_ascii_json(record) + b"\n" for record in records)
    _decode_and_validate(encoded, None)
    return encoded


def decode_token_txn_evidence(
    data: bytes,
    expectation: ReplayExpectation,
) -> ValidatedTokenTxnEvidence:
    """Decode canonical JSONL and replay it against trusted external identity."""

    # The no-expectation replay path exists only for this module's encoder and
    # canonical-golden helper.  A public admission check must never let runtime
    # ``None`` (or a lookalike object) turn trusted head/output checks off.
    if not isinstance(expectation, ReplayExpectation):
        raise TokenTxnEvidenceError(
            "decode requires a trusted ReplayExpectation"
        )
    return _decode_and_validate(data, expectation)


def derive_canonical_jsonl_sha256(data: bytes) -> str:
    """Commit the exact canonical record bytes for cross-language vectors.

    The preimage is the domain, ``record_count:u32-le``, then one
    ``line_length:u64-le || line`` pair per record.  Each line length includes
    its required trailing newline.
    """

    _decode_and_validate(data, None)
    lines = data.splitlines(keepends=True)
    digest = hashlib.sha256()
    digest.update(CANONICAL_JSONL_HASH_DOMAIN)
    _hash_u32(digest, len(lines))
    for line in lines:
        _hash_u64(digest, len(line))
        digest.update(line)
    return digest.hexdigest()
