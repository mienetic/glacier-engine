"""Independent Python codec/verifier for provider settlement wire v1."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class WireError(ValueError):
    """The canonical envelope or one of its semantic commitments is invalid."""


Digest = bytes
Record = dict[str, Any]

MAGIC = b"GPSWIRE1"
WIRE_ABI = 0x4750535700000001
FLAGS_NONE = 0
HEADER_BYTES = 32
REQUEST_WIRE_BYTES = 249
COUNT_WIRE_BYTES = 9
USAGE_WIRE_BYTES = 94
INTENT_WIRE_BYTES = 172
RECEIPT_WIRE_BYTES = 407
ENCODED_BYTES = 720

REQUEST_ABI = 0x4750545100000001
USAGE_ABI = 0x4750545500000001
INTENT_ABI = 0x4750544900000001
RECEIPT_ABI = 0x4750545200000001

REQUEST_HASH_DOMAIN = b"glacier-provider-request-v1\x00"
DISPATCH_KEY_HASH_DOMAIN = b"glacier-provider-dispatch-key-v1\x00"
USAGE_HASH_DOMAIN = b"glacier-provider-usage-v1\x00"
INTENT_HASH_DOMAIN = b"glacier-provider-dispatch-intent-v1\x00"
RECEIPT_HASH_DOMAIN = b"glacier-provider-attempt-receipt-v1\x00"
ENVELOPE_HASH_DOMAIN = b"glacier-provider-settlement-wire-v1\x00"

RETRYABLE_NO_CHARGE = 0
AMBIGUOUS = 1
SUCCEEDED = 2
FAILED = 3
RESOLVED_SUCCESS = 4
RESOLVED_FAILURE = 5


def _u8(value: int) -> bytes:
    if not 0 <= value <= 0xFF:
        raise WireError("u8 out of range")
    return struct.pack("<B", value)


def _u32(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFFFF:
        raise WireError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise WireError("u64 out of range")
    return struct.pack("<Q", value)


def _hash(domain: bytes, *parts: bytes) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _digest(value: bytes, *, allow_zero: bool = False) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise WireError("invalid digest")
    if not allow_zero and value == bytes(32):
        raise WireError("zero digest is not allowed")
    return value


def _count_bytes(value: Record) -> bytes:
    known = value.get("known")
    if not isinstance(known, bool):
        raise WireError("count known flag must be boolean")
    count = value.get("value")
    if not isinstance(count, int):
        raise WireError("count value must be an integer")
    if not known and count != 0:
        raise WireError("unknown count must carry canonical zero")
    return _u8(int(known)) + _u64(count)


def request_sha256(request: Record) -> Digest:
    return _hash(
        REQUEST_HASH_DOMAIN,
        _u64(request["abi_version"]),
        _u64(request["provider_adapter_abi"]),
        _u64(request["isolation_key"]),
        _u64(request["request_key"]),
        _u64(request["request_generation"]),
        request["model_sha256"],
        request["context_sha256"],
        request["tool_schema_sha256"],
        request["policy_sha256"],
        request["sampling_sha256"],
        _u64(request["input_token_estimate"]),
        _u64(request["max_output_tokens"]),
        _u8(request["reuse_policy"]),
    )


def dispatch_key_sha256(request: Record) -> Digest:
    return _hash(
        DISPATCH_KEY_HASH_DOMAIN,
        _u64(REQUEST_ABI),
        _u64(request["provider_adapter_abi"]),
        _u64(request["isolation_key"]),
        request["model_sha256"],
        request["context_sha256"],
        request["tool_schema_sha256"],
        request["policy_sha256"],
        request["sampling_sha256"],
        _u64(request["input_token_estimate"]),
        _u64(request["max_output_tokens"]),
    )


def usage_sha256(usage: Record) -> Digest:
    return _hash(
        USAGE_HASH_DOMAIN,
        _u64(usage["abi_version"]),
        *(_count_bytes(usage[name]) for name in _COUNT_NAMES),
    )


def _intent_bytes(intent: Record, *, include_digest: bool) -> bytes:
    encoded = b"".join(
        (
            _u64(intent["abi_version"]),
            _u64(intent["gateway_epoch"]),
            _u32(intent["owner_slot_index"]),
            _u64(intent["owner_generation"]),
            _u64(intent["attempt_generation"]),
            intent["request_sha256"],
            intent["dispatch_key_sha256"],
            _u64(intent["reserved_tokens"]),
            intent["previous_event_chain_sha256"],
        )
    )
    if include_digest:
        encoded += intent["intent_sha256"]
    return encoded


def intent_sha256(intent: Record) -> Digest:
    return _hash(INTENT_HASH_DOMAIN, _intent_bytes(intent, include_digest=False))


def _usage_bytes(usage: Record, *, include_digest: bool) -> bytes:
    encoded = _u64(usage["abi_version"])
    encoded += b"".join(_count_bytes(usage[name]) for name in _COUNT_NAMES)
    if include_digest:
        encoded += usage["usage_sha256"]
    return encoded


def receipt_sha256(receipt: Record) -> Digest:
    return _hash(
        RECEIPT_HASH_DOMAIN,
        _u64(receipt["abi_version"]),
        _u8(receipt["outcome"]),
        _intent_bytes(receipt["intent"], include_digest=True),
        _usage_bytes(receipt["usage"], include_digest=True),
        receipt["result_sha256"],
        _u32(receipt["request_set_count"]),
        receipt["request_set_sha256"],
        receipt["event_sha256"],
    )


_COUNT_NAMES = (
    "input_tokens",
    "output_tokens",
    "cached_input_tokens",
    "reasoning_tokens",
    "retry_tokens",
    "billable_tokens",
)


def _verify_request(request: Record) -> None:
    if request["abi_version"] != REQUEST_ABI:
        raise WireError("invalid request ABI")
    for name in (
        "provider_adapter_abi",
        "isolation_key",
        "request_key",
        "request_generation",
        "input_token_estimate",
        "max_output_tokens",
    ):
        if request[name] == 0:
            raise WireError(f"request {name} must be nonzero")
        _u64(request[name])
    for name in (
        "model_sha256",
        "context_sha256",
        "tool_schema_sha256",
        "policy_sha256",
        "sampling_sha256",
        "request_sha256",
    ):
        _digest(request[name])
    if request["reuse_policy"] not in (0, 1):
        raise WireError("invalid reuse policy")
    if request["request_sha256"] != request_sha256(request):
        raise WireError("request digest mismatch")


def _verify_usage(usage: Record) -> None:
    if usage["abi_version"] != USAGE_ABI:
        raise WireError("invalid usage ABI")
    for name in _COUNT_NAMES:
        _count_bytes(usage[name])
    cached = usage["cached_input_tokens"]
    input_count = usage["input_tokens"]
    if (
        cached["known"]
        and input_count["known"]
        and cached["value"] > input_count["value"]
    ):
        raise WireError("cached input exceeds input usage")
    _digest(usage["usage_sha256"])
    if usage["usage_sha256"] != usage_sha256(usage):
        raise WireError("usage digest mismatch")


def _verify_intent(intent: Record) -> None:
    if intent["abi_version"] != INTENT_ABI:
        raise WireError("invalid intent ABI")
    for name in (
        "gateway_epoch",
        "owner_generation",
        "attempt_generation",
        "reserved_tokens",
    ):
        if intent[name] == 0:
            raise WireError(f"intent {name} must be nonzero")
        _u64(intent[name])
    _u32(intent["owner_slot_index"])
    for name in (
        "request_sha256",
        "dispatch_key_sha256",
        "previous_event_chain_sha256",
        "intent_sha256",
    ):
        _digest(intent[name])
    if intent["intent_sha256"] != intent_sha256(intent):
        raise WireError("intent digest mismatch")


def _verify_receipt(receipt: Record) -> None:
    if receipt["abi_version"] != RECEIPT_ABI:
        raise WireError("invalid receipt ABI")
    if receipt["outcome"] not in range(6):
        raise WireError("invalid attempt outcome")
    _verify_intent(receipt["intent"])
    _verify_usage(receipt["usage"])
    result = _digest(receipt["result_sha256"], allow_zero=True)
    if receipt["request_set_count"] == 0:
        raise WireError("request set must not be empty")
    _u32(receipt["request_set_count"])
    _digest(receipt["request_set_sha256"])
    _digest(receipt["event_sha256"])
    _digest(receipt["receipt_sha256"])

    outcome = receipt["outcome"]
    billable = receipt["usage"]["billable_tokens"]
    if outcome == RETRYABLE_NO_CHARGE:
        if not billable["known"] or billable["value"] != 0 or any(result):
            raise WireError("invalid no-charge retry semantics")
    elif outcome == AMBIGUOUS:
        if any(result):
            raise WireError("ambiguous receipt cannot carry a result")
    elif outcome in (SUCCEEDED, RESOLVED_SUCCESS):
        if not billable["known"] or not any(result):
            raise WireError("invalid successful settlement semantics")
    elif outcome in (FAILED, RESOLVED_FAILURE):
        if not billable["known"] or any(result):
            raise WireError("invalid failed settlement semantics")
    if receipt["receipt_sha256"] != receipt_sha256(receipt):
        raise WireError("receipt digest mismatch")


def verify_request_settlement(request: Record, receipt: Record) -> None:
    _verify_request(request)
    _verify_receipt(receipt)
    intent = receipt["intent"]
    if intent["request_sha256"] != request["request_sha256"]:
        raise WireError("receipt is bound to a different request")
    if intent["dispatch_key_sha256"] != dispatch_key_sha256(request):
        raise WireError("dispatch key does not match request")
    reserved = request["input_token_estimate"] + request["max_output_tokens"]
    if reserved > 0xFFFFFFFFFFFFFFFF:
        raise WireError("reservation overflow")
    if intent["reserved_tokens"] != reserved:
        raise WireError("intent reservation does not match request")


def _encode_request(request: Record) -> bytes:
    return b"".join(
        (
            _u64(request["abi_version"]),
            _u64(request["provider_adapter_abi"]),
            _u64(request["isolation_key"]),
            _u64(request["request_key"]),
            _u64(request["request_generation"]),
            request["model_sha256"],
            request["context_sha256"],
            request["tool_schema_sha256"],
            request["policy_sha256"],
            request["sampling_sha256"],
            _u64(request["input_token_estimate"]),
            _u64(request["max_output_tokens"]),
            _u8(request["reuse_policy"]),
            request["request_sha256"],
        )
    )


def _encode_receipt(receipt: Record) -> bytes:
    return b"".join(
        (
            _u64(receipt["abi_version"]),
            _u8(receipt["outcome"]),
            _intent_bytes(receipt["intent"], include_digest=True),
            _usage_bytes(receipt["usage"], include_digest=True),
            receipt["result_sha256"],
            _u32(receipt["request_set_count"]),
            receipt["request_set_sha256"],
            receipt["event_sha256"],
            receipt["receipt_sha256"],
        )
    )


def encode_evidence(request: Record, receipt: Record) -> bytes:
    verify_request_settlement(request, receipt)
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(ENCODED_BYTES),
            _u32(FLAGS_NONE),
            _u32(0),
            _encode_request(request),
            _encode_receipt(receipt),
        )
    )
    if len(prefix) != ENCODED_BYTES - 32:
        raise WireError("internal wire length mismatch")
    return prefix + _hash(ENVELOPE_HASH_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if end > len(self.data):
            raise WireError("truncated wire")
        result = self.data[self.position : end]
        self.position = end
        return result

    def u8(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> Digest:
        return self.take(32)


def _read_count(reader: _Reader) -> Record:
    known_value = reader.u8()
    if known_value not in (0, 1):
        raise WireError("noncanonical boolean")
    return {"known": bool(known_value), "value": reader.u64()}


def _read_request(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "provider_adapter_abi": reader.u64(),
        "isolation_key": reader.u64(),
        "request_key": reader.u64(),
        "request_generation": reader.u64(),
        "model_sha256": reader.digest(),
        "context_sha256": reader.digest(),
        "tool_schema_sha256": reader.digest(),
        "policy_sha256": reader.digest(),
        "sampling_sha256": reader.digest(),
        "input_token_estimate": reader.u64(),
        "max_output_tokens": reader.u64(),
        "reuse_policy": reader.u8(),
        "request_sha256": reader.digest(),
    }


def _read_intent(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "gateway_epoch": reader.u64(),
        "owner_slot_index": reader.u32(),
        "owner_generation": reader.u64(),
        "attempt_generation": reader.u64(),
        "request_sha256": reader.digest(),
        "dispatch_key_sha256": reader.digest(),
        "reserved_tokens": reader.u64(),
        "previous_event_chain_sha256": reader.digest(),
        "intent_sha256": reader.digest(),
    }


def _read_usage(reader: _Reader) -> Record:
    usage: Record = {"abi_version": reader.u64()}
    for name in _COUNT_NAMES:
        usage[name] = _read_count(reader)
    usage["usage_sha256"] = reader.digest()
    return usage


def _read_receipt(reader: _Reader) -> Record:
    abi_version = reader.u64()
    outcome = reader.u8()
    if outcome not in range(6):
        raise WireError("invalid attempt outcome")
    return {
        "abi_version": abi_version,
        "outcome": outcome,
        "intent": _read_intent(reader),
        "usage": _read_usage(reader),
        "result_sha256": reader.digest(),
        "request_set_count": reader.u32(),
        "request_set_sha256": reader.digest(),
        "event_sha256": reader.digest(),
        "receipt_sha256": reader.digest(),
    }


def decode_and_verify(encoded: bytes) -> Record:
    if len(encoded) != ENCODED_BYTES:
        raise WireError("invalid envelope length")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC:
        raise WireError("invalid magic")
    if reader.u64() != WIRE_ABI:
        raise WireError("invalid wire ABI")
    if reader.u64() != ENCODED_BYTES:
        raise WireError("invalid declared length")
    if reader.u32() != FLAGS_NONE or reader.u32() != 0:
        raise WireError("unknown flags or nonzero reserved field")

    prefix = encoded[:-32]
    expected_root = _hash(ENVELOPE_HASH_DOMAIN, prefix)
    if encoded[-32:] != expected_root:
        raise WireError("envelope digest mismatch")
    request = _read_request(reader)
    receipt = _read_receipt(reader)
    envelope_sha256 = reader.digest()
    if reader.position != len(encoded) or envelope_sha256 != expected_root:
        raise WireError("trailing bytes or envelope root drift")
    verify_request_settlement(request, receipt)
    return {
        "request": request,
        "receipt": receipt,
        "envelope_sha256": envelope_sha256,
    }


def reseal_for_test(encoded: bytes) -> bytes:
    if len(encoded) != ENCODED_BYTES:
        raise WireError("invalid envelope length")
    prefix = encoded[:-32]
    return prefix + _hash(ENVELOPE_HASH_DOMAIN, prefix)


def _seed_digest(seed: int) -> Digest:
    return bytes((seed,)) * 32


def _count(value: int | None) -> Record:
    return {"known": value is not None, "value": 0 if value is None else value}


def make_usage(
    input_tokens: int | None,
    output_tokens: int | None,
    cached_input_tokens: int | None,
    reasoning_tokens: int | None,
    retry_tokens: int | None,
    billable_tokens: int | None,
) -> Record:
    usage: Record = {
        "abi_version": USAGE_ABI,
        "input_tokens": _count(input_tokens),
        "output_tokens": _count(output_tokens),
        "cached_input_tokens": _count(cached_input_tokens),
        "reasoning_tokens": _count(reasoning_tokens),
        "retry_tokens": _count(retry_tokens),
        "billable_tokens": _count(billable_tokens),
    }
    usage["usage_sha256"] = usage_sha256(usage)
    return usage


def build_demo_evidence(outcome: int = SUCCEEDED) -> tuple[Record, Record]:
    request: Record = {
        "abi_version": REQUEST_ABI,
        "provider_adapter_abi": 0x5445535441445054,
        "isolation_key": 0x5445535449534F4C,
        "request_key": 71,
        "request_generation": 3,
        "model_sha256": _seed_digest(0x11),
        "context_sha256": _seed_digest(0x22),
        "tool_schema_sha256": _seed_digest(0x33),
        "policy_sha256": _seed_digest(0x44),
        "sampling_sha256": _seed_digest(0x55),
        "input_token_estimate": 100,
        "max_output_tokens": 50,
        "reuse_policy": 1,
    }
    request["request_sha256"] = request_sha256(request)
    intent: Record = {
        "abi_version": INTENT_ABI,
        "gateway_epoch": 0x5445535447570001,
        "owner_slot_index": 2,
        "owner_generation": 9,
        "attempt_generation": 4,
        "request_sha256": request["request_sha256"],
        "dispatch_key_sha256": dispatch_key_sha256(request),
        "reserved_tokens": 150,
        "previous_event_chain_sha256": _seed_digest(0x66),
    }
    intent["intent_sha256"] = intent_sha256(intent)

    if outcome == RETRYABLE_NO_CHARGE:
        usage = make_usage(None, None, None, None, None, 0)
    elif outcome == AMBIGUOUS:
        usage = make_usage(100, 7, 40, None, 3, None)
    elif outcome in (SUCCEEDED, RESOLVED_SUCCESS):
        usage = make_usage(100, 20, 40, 8, 0, 80)
    elif outcome in (FAILED, RESOLVED_FAILURE):
        usage = make_usage(100, 0, 40, 0, 0, 60)
    else:
        raise WireError("invalid fixture outcome")
    receipt: Record = {
        "abi_version": RECEIPT_ABI,
        "outcome": outcome,
        "intent": intent,
        "usage": usage,
        "result_sha256": (
            _seed_digest(0x77)
            if outcome in (SUCCEEDED, RESOLVED_SUCCESS)
            else bytes(32)
        ),
        "request_set_count": 3,
        "request_set_sha256": _seed_digest(0x88),
        "event_sha256": _seed_digest(0x99),
    }
    receipt["receipt_sha256"] = receipt_sha256(receipt)
    return request, receipt
