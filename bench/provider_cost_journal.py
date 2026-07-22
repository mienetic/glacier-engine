"""Independent verifier for the crash-recoverable provider cost journal v1."""

from __future__ import annotations

import copy
import hashlib
import struct
from typing import Any

from bench import provider_cost_wire as cost_wire
from bench import provider_settlement_wire as settlement_wire


class JournalError(ValueError):
    """The journal header, committed frame, lifecycle, or ledger is invalid."""


Digest = bytes
Record = dict[str, Any]

HEADER_ABI = 0x47504A4800000001
FRAME_ABI = 0x47504A4600000001
HEADER_MAGIC = b"GPCJNLH1"
FRAME_MAGIC = b"GPCJNLF1"
COMMIT_MAGIC = b"GPCJCMT1"
FLAG_RECOVER_TORN_TAIL = 1
MAX_SUPPORTED_FRAMES = 4_096

HEADER_DOMAIN = b"glacier-provider-cost-journal-header-v1\x00"
FRAME_DOMAIN = b"glacier-provider-cost-journal-frame-v1\x00"

HEADER_BYTES = 144
FRAME_PREFIX_BYTES = 1_565
FRAME_BODY_BYTES = 1_597
COMMIT_FOOTER_BYTES = 48
FRAME_BYTES = 1_645
U64_MAX = (1 << 64) - 1

FREE = 0
RETRYABLE = 1
AMBIGUOUS = 2
TERMINAL = 3


def _u32(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFFFF:
        raise JournalError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not 0 <= value <= U64_MAX:
        raise JournalError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise JournalError("invalid digest")
    if not allow_zero and value == bytes(32):
        raise JournalError("zero digest is not allowed")
    return value


def _hash(domain: bytes, *parts: bytes) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _currency(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 3:
        raise JournalError("currency must be exactly three bytes")
    if any(byte < ord("A") or byte > ord("Z") for byte in value):
        raise JournalError("currency must be uppercase ASCII")
    return value


def header_sha256(value: Record) -> Digest:
    return _hash(
        HEADER_DOMAIN,
        _u64(value["abi_version"]),
        _u32(value["flags"]),
        _u64(value["journal_epoch"]),
        value["tenant_sha256"],
        value["currency_code"],
        value["challenge_sha256"],
    )


def make_header(
    journal_epoch: int,
    tenant_sha256: Digest,
    currency_code: bytes,
    challenge_sha256: Digest,
) -> Record:
    value = {
        "abi_version": HEADER_ABI,
        "flags": FLAG_RECOVER_TORN_TAIL,
        "journal_epoch": journal_epoch,
        "tenant_sha256": tenant_sha256,
        "currency_code": currency_code,
        "challenge_sha256": challenge_sha256,
    }
    value["header_sha256"] = header_sha256(value)
    _verify_header(value)
    return value


def _verify_header(value: Record) -> None:
    if value["abi_version"] != HEADER_ABI:
        raise JournalError("invalid header ABI")
    if value["flags"] != FLAG_RECOVER_TORN_TAIL:
        raise JournalError("invalid header flags")
    if value["journal_epoch"] == 0:
        raise JournalError("zero journal epoch")
    _u64(value["journal_epoch"])
    _digest(value["tenant_sha256"])
    _currency(value["currency_code"])
    _digest(value["challenge_sha256"])
    if value["header_sha256"] != header_sha256(value):
        raise JournalError("header digest mismatch")


def encode_header(value: Record) -> bytes:
    _verify_header(value)
    encoded = b"".join(
        (
            HEADER_MAGIC,
            _u64(value["abi_version"]),
            _u64(HEADER_BYTES),
            _u32(value["flags"]),
            _u32(0),
            _u64(value["journal_epoch"]),
            value["tenant_sha256"],
            value["currency_code"],
            bytes(5),
            value["challenge_sha256"],
            value["header_sha256"],
        )
    )
    if len(encoded) != HEADER_BYTES:
        raise JournalError("invalid encoded header length")
    return encoded


def decode_header(encoded: bytes, expected_header_sha256: Digest) -> Record:
    if len(encoded) != HEADER_BYTES:
        raise JournalError("invalid header length")
    if encoded[:8] != HEADER_MAGIC:
        raise JournalError("invalid header magic")
    abi, length, flags, reserved, epoch = struct.unpack_from("<QQIIQ", encoded, 8)
    if abi != HEADER_ABI or length != HEADER_BYTES:
        raise JournalError("invalid header ABI or length")
    if flags != FLAG_RECOVER_TORN_TAIL or reserved != 0:
        raise JournalError("invalid header flags or reserved bytes")
    if encoded[75:80] != bytes(5):
        raise JournalError("invalid header padding")
    value = {
        "abi_version": abi,
        "flags": flags,
        "journal_epoch": epoch,
        "tenant_sha256": encoded[40:72],
        "currency_code": encoded[72:75],
        "challenge_sha256": encoded[80:112],
        "header_sha256": encoded[112:144],
    }
    if value["header_sha256"] != expected_header_sha256:
        raise JournalError("unpinned journal header")
    _verify_header(value)
    return value


def _frame_sha256(header_root: Digest, prefix: bytes) -> Digest:
    return _hash(FRAME_DOMAIN, header_root, prefix)


def encode_frame(
    header: Record,
    sequence: int,
    previous_chain_sha256: Digest,
    encoded_cost: bytes,
) -> bytes:
    _verify_header(header)
    if sequence == 0:
        raise JournalError("zero frame sequence")
    _u64(sequence)
    _digest(previous_chain_sha256)
    if len(encoded_cost) != cost_wire.ENCODED_BYTES:
        raise JournalError("invalid nested cost wire length")
    try:
        cost = cost_wire.decode_and_verify(encoded_cost)
    except cost_wire.WireError as exc:
        raise JournalError("invalid nested cost evidence") from exc
    if cost["price"]["currency_code"] != header["currency_code"]:
        raise JournalError("journal currency mismatch")
    prefix = b"".join(
        (
            FRAME_MAGIC,
            _u64(FRAME_ABI),
            _u64(FRAME_BYTES),
            _u64(header["journal_epoch"]),
            _u64(sequence),
            header["tenant_sha256"],
            previous_chain_sha256,
            encoded_cost,
        )
    )
    if len(prefix) != FRAME_PREFIX_BYTES:
        raise JournalError("invalid frame prefix length")
    root = _frame_sha256(header["header_sha256"], prefix)
    encoded = b"".join(
        (prefix, root, COMMIT_MAGIC, _u64(sequence), root)
    )
    if len(encoded) != FRAME_BYTES:
        raise JournalError("invalid frame length")
    return encoded


def append_plan(encoded_frame: bytes) -> tuple[bytes, bytes]:
    """Return the body and commit-footer writes in required durability order."""
    if len(encoded_frame) != FRAME_BYTES:
        raise JournalError("invalid frame length")
    if (
        encoded_frame[:8] != FRAME_MAGIC
        or encoded_frame[FRAME_BODY_BYTES : FRAME_BODY_BYTES + 8] != COMMIT_MAGIC
    ):
        raise JournalError("invalid encoded frame markers")
    return encoded_frame[:FRAME_BODY_BYTES], encoded_frame[FRAME_BODY_BYTES:]


def _decode_frame(
    header: Record,
    expected_sequence: int,
    expected_previous: Digest,
    encoded: bytes,
) -> Record:
    if len(encoded) != FRAME_BYTES:
        raise JournalError("invalid frame length")
    if encoded[:8] != FRAME_MAGIC:
        raise JournalError("invalid frame magic")
    abi, length, epoch, sequence = struct.unpack_from("<QQQQ", encoded, 8)
    if abi != FRAME_ABI or length != FRAME_BYTES:
        raise JournalError("invalid frame ABI or length")
    if epoch != header["journal_epoch"] or sequence != expected_sequence:
        raise JournalError("frame epoch or sequence drift")
    if encoded[40:72] != header["tenant_sha256"]:
        raise JournalError("frame tenant drift")
    if encoded[72:104] != expected_previous:
        raise JournalError("frame chain drift")
    expected_root = _frame_sha256(
        header["header_sha256"], encoded[:FRAME_PREFIX_BYTES]
    )
    entry_root = encoded[FRAME_PREFIX_BYTES:FRAME_BODY_BYTES]
    if entry_root != expected_root:
        raise JournalError("frame digest mismatch")
    if encoded[FRAME_BODY_BYTES : FRAME_BODY_BYTES + 8] != COMMIT_MAGIC:
        raise JournalError("missing commit footer")
    committed_sequence = struct.unpack_from("<Q", encoded, FRAME_BODY_BYTES + 8)[0]
    committed_root = encoded[FRAME_BODY_BYTES + 16 :]
    if committed_sequence != sequence or committed_root != entry_root:
        raise JournalError("commit footer mismatch")
    encoded_cost = encoded[104:FRAME_PREFIX_BYTES]
    try:
        cost = cost_wire.decode_and_verify(encoded_cost)
    except cost_wire.WireError as exc:
        raise JournalError("invalid nested cost evidence") from exc
    if cost["price"]["currency_code"] != header["currency_code"]:
        raise JournalError("journal currency mismatch")
    return {"sequence": sequence, "cost": cost, "entry_sha256": entry_root}


def _known_zero() -> Record:
    return {"known": True, "value": 0}


def _add_u64(left: int, right: int) -> int:
    result = left + right
    _u64(result)
    return result


def _add_known(left: Record, right: Record) -> Record:
    if not left["known"] or not right["known"]:
        return cost_wire.unknown()
    return cost_wire.known(_add_u64(left["value"], right["value"]))


def _new_ledger() -> Record:
    return {
        "committed_frames": 0,
        "physical_attempts": 0,
        "settled_attempts": 0,
        "retryable_no_charge_records": 0,
        "ambiguous_records": 0,
        "resolved_records": 0,
        "retryable_requests": 0,
        "open_ambiguous_requests": 0,
        "terminal_requests": 0,
        "unpriced_settled_attempts": 0,
        "quoted_nanos": _known_zero(),
        "settled_nanos": _known_zero(),
        "savings_nanos": _known_zero(),
        "overrun_nanos": _known_zero(),
    }


def _accumulate_settlement(cost: Record, ledger: Record) -> None:
    settlement = cost["cost_settlement"]
    ledger["settled_attempts"] = _add_u64(ledger["settled_attempts"], 1)
    total = settlement["breakdown"]["total_nanos"]
    if not total["known"]:
        ledger["unpriced_settled_attempts"] = _add_u64(
            ledger["unpriced_settled_attempts"], 1
        )
    ledger["settled_nanos"] = _add_known(ledger["settled_nanos"], total)
    ledger["savings_nanos"] = _add_known(
        ledger["savings_nanos"], settlement["savings_nanos"]
    )
    ledger["overrun_nanos"] = _add_known(
        ledger["overrun_nanos"], settlement["overrun_nanos"]
    )


def _apply_frame(frame: Record, states: dict[Digest, Record], ledger: Record) -> None:
    cost = frame["cost"]
    provider = cost["provider_settlement"]
    request_root = provider["request"]["request_sha256"]
    receipt = provider["receipt"]
    intent = receipt["intent"]
    attempt_generation = intent["attempt_generation"]
    outcome = receipt["outcome"]
    state = states.get(request_root)
    new_attempt = False
    if state is None:
        if outcome in (
            settlement_wire.RESOLVED_SUCCESS,
            settlement_wire.RESOLVED_FAILURE,
        ):
            raise JournalError("resolution has no ambiguous predecessor")
        state = {
            "phase": FREE,
            "attempt_generation": 0,
            "intent_sha256": bytes(32),
            "price_sha256": bytes(32),
            "quote_sha256": bytes(32),
        }
        states[request_root] = state
        new_attempt = True
    elif state["phase"] == TERMINAL:
        raise JournalError("attempt follows terminal request")
    elif state["phase"] == RETRYABLE:
        if attempt_generation != state["attempt_generation"] + 1 or outcome in (
            settlement_wire.RESOLVED_SUCCESS,
            settlement_wire.RESOLVED_FAILURE,
        ):
            raise JournalError("retry attempt generation drift")
        new_attempt = True
    elif state["phase"] == AMBIGUOUS:
        if outcome not in (
            settlement_wire.RESOLVED_SUCCESS,
            settlement_wire.RESOLVED_FAILURE,
        ):
            raise JournalError("ambiguous attempt was not resolved")
        if (
            attempt_generation != state["attempt_generation"]
            or intent["intent_sha256"] != state["intent_sha256"]
            or cost["price"]["price_sha256"] != state["price_sha256"]
            or cost["quote"]["quote_sha256"] != state["quote_sha256"]
        ):
            raise JournalError("ambiguous resolution identity drift")
    else:
        raise JournalError("invalid request phase")

    if new_attempt:
        state.update(
            {
                "attempt_generation": attempt_generation,
                "intent_sha256": intent["intent_sha256"],
                "price_sha256": cost["price"]["price_sha256"],
                "quote_sha256": cost["quote"]["quote_sha256"],
            }
        )
        ledger["physical_attempts"] = _add_u64(ledger["physical_attempts"], 1)
        ledger["quoted_nanos"] = _add_known(
            ledger["quoted_nanos"], cost["quote"]["breakdown"]["total_nanos"]
        )

    if outcome == settlement_wire.RETRYABLE_NO_CHARGE:
        state["phase"] = RETRYABLE
        ledger["retryable_no_charge_records"] = _add_u64(
            ledger["retryable_no_charge_records"], 1
        )
        _accumulate_settlement(cost, ledger)
    elif outcome == settlement_wire.AMBIGUOUS:
        state["phase"] = AMBIGUOUS
        ledger["ambiguous_records"] = _add_u64(ledger["ambiguous_records"], 1)
    elif outcome in (settlement_wire.SUCCEEDED, settlement_wire.FAILED):
        state["phase"] = TERMINAL
        _accumulate_settlement(cost, ledger)
    else:
        state["phase"] = TERMINAL
        ledger["resolved_records"] = _add_u64(ledger["resolved_records"], 1)
        _accumulate_settlement(cost, ledger)
    ledger["committed_frames"] = _add_u64(ledger["committed_frames"], 1)


def _finalize_counts(states: dict[Digest, Record], ledger: Record) -> None:
    for state in states.values():
        if state["phase"] == RETRYABLE:
            ledger["retryable_requests"] = _add_u64(
                ledger["retryable_requests"], 1
            )
        elif state["phase"] == AMBIGUOUS:
            ledger["open_ambiguous_requests"] = _add_u64(
                ledger["open_ambiguous_requests"], 1
            )
        elif state["phase"] == TERMINAL:
            ledger["terminal_requests"] = _add_u64(
                ledger["terminal_requests"], 1
            )
        else:
            raise JournalError("invalid final request phase")


def recover(encoded: bytes, expected_header_sha256: Digest) -> Record:
    if len(encoded) < HEADER_BYTES:
        raise JournalError("journal header is incomplete")
    header = decode_header(encoded[:HEADER_BYTES], expected_header_sha256)
    complete_frames, tail_bytes = divmod(len(encoded) - HEADER_BYTES, FRAME_BYTES)
    if complete_frames > MAX_SUPPORTED_FRAMES:
        raise JournalError("journal frame limit exceeded")
    entries: list[Record] = []
    states: dict[Digest, Record] = {}
    ledger = _new_ledger()
    previous = header["header_sha256"]
    for index in range(complete_frames):
        start = HEADER_BYTES + index * FRAME_BYTES
        frame = _decode_frame(
            header,
            index + 1,
            previous,
            encoded[start : start + FRAME_BYTES],
        )
        _apply_frame(frame, states, ledger)
        entries.append(frame)
        previous = frame["entry_sha256"]
    _finalize_counts(states, ledger)
    committed_bytes = HEADER_BYTES + complete_frames * FRAME_BYTES
    return {
        "header": header,
        "entries": entries,
        "status": "clean" if tail_bytes == 0 else "torn_tail",
        "committed_bytes": committed_bytes,
        "discarded_tail_bytes": tail_bytes,
        "final_chain_sha256": previous,
        "ledger": ledger,
    }


def verify_closed(
    encoded: bytes,
    expected_header_sha256: Digest,
    expected_final_chain_sha256: Digest,
) -> Record:
    result = recover(encoded, expected_header_sha256)
    _digest(expected_final_chain_sha256)
    if result["status"] != "clean":
        raise JournalError("closed journal has a torn tail")
    if result["final_chain_sha256"] != expected_final_chain_sha256:
        raise JournalError("closed journal final root mismatch")
    return result


def _seed_digest(seed: int) -> Digest:
    return bytes((seed,)) * 32


def _cost_envelope(outcome: int, attempt_generation: int) -> bytes:
    evidence = cost_wire.build_demo_evidence(outcome)
    provider = evidence["provider_settlement"]
    receipt = copy.deepcopy(provider["receipt"])
    receipt["intent"]["attempt_generation"] = attempt_generation
    receipt["intent"]["intent_sha256"] = settlement_wire.intent_sha256(
        receipt["intent"]
    )
    receipt["receipt_sha256"] = settlement_wire.receipt_sha256(receipt)
    provider_envelope = settlement_wire.encode_evidence(provider["request"], receipt)
    updated_provider = settlement_wire.decode_and_verify(provider_envelope)
    settlement = cost_wire.make_cost_settlement(
        evidence["price"],
        evidence["quote"],
        updated_provider,
        1_700_000_200,
    )
    updated = copy.deepcopy(evidence)
    updated["provider_settlement_envelope"] = provider_envelope
    updated["provider_settlement"] = updated_provider
    updated["cost_settlement"] = settlement
    return cost_wire.encode_evidence(updated)


def build_demo_journal() -> tuple[Record, bytes, Digest]:
    header = make_header(
        0x4A4F55524E414C01,
        _seed_digest(0xB1),
        b"USD",
        _seed_digest(0xC1),
    )
    costs = (
        _cost_envelope(settlement_wire.RETRYABLE_NO_CHARGE, 4),
        _cost_envelope(settlement_wire.AMBIGUOUS, 5),
        _cost_envelope(settlement_wire.RESOLVED_SUCCESS, 5),
    )
    frames: list[bytes] = []
    previous = header["header_sha256"]
    for index, cost in enumerate(costs, start=1):
        frame = encode_frame(header, index, previous, cost)
        frames.append(frame)
        previous = frame[FRAME_PREFIX_BYTES:FRAME_BODY_BYTES]
    return header, encode_header(header) + b"".join(frames), previous


def reseal_header_for_test(encoded: bytes) -> bytes:
    if len(encoded) < HEADER_BYTES:
        raise JournalError("short header")
    mutable = bytearray(encoded)
    root = _hash(
        HEADER_DOMAIN,
        bytes(mutable[8:16]),
        bytes(mutable[24:28]),
        bytes(mutable[32:40]),
        bytes(mutable[40:72]),
        bytes(mutable[72:75]),
        bytes(mutable[80:112]),
    )
    mutable[112:144] = root
    return bytes(mutable)


def reseal_frame_for_test(encoded: bytes, header_root: Digest) -> bytes:
    if len(encoded) != FRAME_BYTES:
        raise JournalError("invalid frame length")
    mutable = bytearray(encoded)
    root = _frame_sha256(header_root, bytes(mutable[:FRAME_PREFIX_BYTES]))
    mutable[FRAME_PREFIX_BYTES:FRAME_BODY_BYTES] = root
    mutable[FRAME_BODY_BYTES + 16 :] = root
    return bytes(mutable)
