"""Independent Python codec and replay verifier for transport event wire v1."""

from __future__ import annotations

import copy
import hashlib
import struct
from typing import Any

from bench import provider_gateway_event_wire as gateway_wire
from bench import provider_settlement_wire as settlement_wire


class WireError(ValueError):
    """The closed transport attempt or one of its commitments is invalid."""


Digest = bytes
Record = dict[str, Any]

MAGIC = b"GPTWIRE1"
WIRE_ABI = 0x4750545700000001
FLAG_REQUIRE_CLOSED = 1
MAX_EVENTS = 8192

TRANSPORT_ABI = 0x4750544600000001
DESCRIPTOR_ABI = 0x4750544400000001
SCRIPT_ABI = 0x4750545300000001
CHUNK_ABI = 0x4750544300000001
OUTCOME_ABI = 0x4750544F00000001
SNAPSHOT_ABI = 0x4750545000000001
CANCEL_REQUEST_ABI = 0x4750435200000001
CANCEL_ACK_ABI = 0x4750434100000001
CANCEL_OUTCOME_ABI = 0x4750434F00000001
CANCEL_SNAPSHOT_ABI = 0x4750435000000001

CAPABILITY_STREAMING = 1 << 0
CAPABILITY_AUTHORITATIVE_USAGE = 1 << 1
CAPABILITY_RETRY_CLASSIFICATION = 1 << 2
CAPABILITY_IDEMPOTENCY = 1 << 3
CAPABILITY_AMBIGUOUS_DETECTION = 1 << 4
CAPABILITY_ACTIVE_CANCELLATION = 1 << 5
REQUIRED_CAPABILITIES = (
    CAPABILITY_STREAMING
    | CAPABILITY_AUTHORITATIVE_USAGE
    | CAPABILITY_RETRY_CLASSIFICATION
    | CAPABILITY_IDEMPOTENCY
    | CAPABILITY_AMBIGUOUS_DETECTION
)

CHUNK = 0
CANCEL_REQUEST = 1
CANCEL_ACK = 2
OUTCOME = 3
CANCEL_OUTCOME = 4

SUCCEEDED = 0
RETRYABLE_NO_CHARGE = 1
AMBIGUOUS = 2

CANCEL_NOT_ACCEPTED = 0
CANCEL_CONFIRMED = 1
CANCEL_TOO_LATE_SUCCEEDED = 2
CANCEL_AMBIGUOUS = 3

CANCEL_OUTCOME_CONFIRMED = 0
CANCEL_OUTCOME_TOO_LATE_SUCCEEDED = 1
CANCEL_OUTCOME_AMBIGUOUS = 2

HEADER_BYTES = 40
DESCRIPTOR_WIRE_BYTES = 88
CONFIG_WIRE_BYTES = 132
COUNT_WIRE_BYTES = 9
USAGE_WIRE_BYTES = 94
INTENT_WIRE_BYTES = 172
SCRIPT_WIRE_BYTES = 267
CHUNK_WIRE_BYTES = 240
CANCEL_REQUEST_WIRE_BYTES = 205
CANCEL_ACK_WIRE_BYTES = 199
OUTCOME_WIRE_BYTES = 471
CANCEL_OUTCOME_WIRE_BYTES = 535
SNAPSHOT_WIRE_BYTES = 88
CANCEL_SNAPSHOT_WIRE_BYTES = 80
FIXED_WIRE_BYTES = 1563

DESCRIPTOR_DOMAIN = b"glacier-provider-transport-descriptor-v1\x00"
PROVIDER_REQUEST_DOMAIN = b"glacier-provider-request-id-v1\x00"
SCRIPT_DOMAIN = b"glacier-provider-transport-script-v1\x00"
INITIAL_RESPONSE_DOMAIN = b"glacier-provider-response-chain-v1\x00"
CHUNK_PAYLOAD_DOMAIN = b"glacier-provider-chunk-payload-v1\x00"
CHUNK_CHAIN_DOMAIN = b"glacier-provider-chunk-chain-v1\x00"
CHUNK_EVIDENCE_DOMAIN = b"glacier-provider-chunk-evidence-v1\x00"
OUTCOME_DOMAIN = b"glacier-provider-transport-outcome-v1\x00"
CANCEL_REQUEST_DOMAIN = b"glacier-provider-cancel-request-v1\x00"
CANCEL_ACK_DOMAIN = b"glacier-provider-cancel-ack-v1\x00"
CANCEL_OUTCOME_DOMAIN = b"glacier-provider-cancel-outcome-v1\x00"
CONFIGURATION_DOMAIN = b"glacier-provider-transport-wire-configuration-v1\x00"
ENVELOPE_DOMAIN = b"glacier-provider-transport-event-wire-v1\x00"

COUNT_NAMES = (
    "input_tokens",
    "output_tokens",
    "cached_input_tokens",
    "reasoning_tokens",
    "retry_tokens",
    "billable_tokens",
)
LEDGER_NAMES = (
    "active_attempts",
    "completed_unacknowledged",
    "started_attempts",
    "emitted_chunks",
    "successful_outcomes",
    "retryable_outcomes",
    "ambiguous_outcomes",
    "acknowledged_attempts",
)
CANCEL_LEDGER_NAMES = (
    "pending_cancellations",
    "requested_cancellations",
    "rejected_cancellations",
    "confirmed_cancellations",
    "too_late_successes",
    "ambiguous_cancellations",
    "known_post_cancel_billable_tokens",
    "unknown_post_cancel_usage",
)


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
    count = value.get("value")
    if not isinstance(known, bool) or not isinstance(count, int):
        raise WireError("invalid count")
    if not known and count != 0:
        raise WireError("unknown count must carry canonical zero")
    return _u8(int(known)) + _u64(count)


def _usage_bytes(usage: Record) -> bytes:
    return (
        _u64(usage["abi_version"])
        + b"".join(_count_bytes(usage[name]) for name in COUNT_NAMES)
        + usage["usage_sha256"]
    )


def _verify_usage(usage: Record) -> None:
    if usage["abi_version"] != settlement_wire.USAGE_ABI:
        raise WireError("invalid usage ABI")
    for name in COUNT_NAMES:
        _count_bytes(usage[name])
    if (
        usage["input_tokens"]["known"]
        and usage["cached_input_tokens"]["known"]
        and usage["cached_input_tokens"]["value"]
        > usage["input_tokens"]["value"]
    ):
        raise WireError("cached input exceeds input")
    if usage["usage_sha256"] != settlement_wire.usage_sha256(usage):
        raise WireError("usage digest mismatch")


def _intent_bytes(intent: Record) -> bytes:
    return b"".join(
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
            intent["intent_sha256"],
        )
    )


def _verify_intent(intent: Record) -> None:
    if intent["abi_version"] != settlement_wire.INTENT_ABI:
        raise WireError("invalid intent ABI")
    for name in (
        "gateway_epoch",
        "owner_generation",
        "attempt_generation",
        "reserved_tokens",
    ):
        if intent[name] == 0:
            raise WireError(f"intent {name} must be nonzero")
    for name in (
        "request_sha256",
        "dispatch_key_sha256",
        "previous_event_chain_sha256",
        "intent_sha256",
    ):
        _digest(intent[name])
    if intent["intent_sha256"] != settlement_wire.intent_sha256(intent):
        raise WireError("intent digest mismatch")


def _descriptor_bytes(descriptor: Record) -> bytes:
    return b"".join(
        (
            _u64(descriptor["abi_version"]),
            _u64(descriptor["transport_adapter_abi"]),
            descriptor["provider_namespace_sha256"],
            _u64(descriptor["capability_bits"]),
            descriptor["descriptor_sha256"],
        )
    )


def descriptor_sha256(descriptor: Record) -> Digest:
    return _hash(
        DESCRIPTOR_DOMAIN,
        _u64(descriptor["abi_version"]),
        _u64(descriptor["transport_adapter_abi"]),
        descriptor["provider_namespace_sha256"],
        _u64(descriptor["capability_bits"]),
    )


def _verify_descriptor(descriptor: Record) -> None:
    if descriptor["abi_version"] != DESCRIPTOR_ABI:
        raise WireError("invalid descriptor ABI")
    if descriptor["transport_adapter_abi"] == 0:
        raise WireError("zero transport adapter ABI")
    _digest(descriptor["provider_namespace_sha256"])
    if descriptor["capability_bits"] & REQUIRED_CAPABILITIES != REQUIRED_CAPABILITIES:
        raise WireError("required transport capability missing")
    if descriptor["descriptor_sha256"] != descriptor_sha256(descriptor):
        raise WireError("descriptor digest mismatch")


def _config_bytes(config: Record) -> bytes:
    return b"".join(
        (
            _u64(config["harness_epoch"]),
            config["challenge"],
            _u32(config["max_chunks_per_attempt"]),
            _descriptor_bytes(config["descriptor"]),
        )
    )


def configuration_sha256(config: Record, slot_capacity: int) -> Digest:
    return _hash(
        CONFIGURATION_DOMAIN,
        _u64(TRANSPORT_ABI),
        _u64(DESCRIPTOR_ABI),
        _u64(SCRIPT_ABI),
        _u64(CHUNK_ABI),
        _u64(OUTCOME_ABI),
        _u64(CANCEL_REQUEST_ABI),
        _u64(CANCEL_ACK_ABI),
        _u64(CANCEL_OUTCOME_ABI),
        _u64(config["harness_epoch"]),
        config["challenge"],
        _u32(config["max_chunks_per_attempt"]),
        config["descriptor"]["descriptor_sha256"],
        _u32(slot_capacity),
    )


def _verify_config(config: Record, slot_capacity: int) -> None:
    if config["harness_epoch"] == 0 or slot_capacity == 0:
        raise WireError("invalid transport capacity or epoch")
    _digest(config["challenge"])
    if not 0 < config["max_chunks_per_attempt"] <= 4096:
        raise WireError("invalid chunk bound")
    _verify_descriptor(config["descriptor"])


def provider_request_sha256(descriptor: Record, intent: Record) -> Digest:
    return _hash(
        PROVIDER_REQUEST_DOMAIN,
        _u64(descriptor["transport_adapter_abi"]),
        descriptor["provider_namespace_sha256"],
        _u64(intent["gateway_epoch"]),
        _u32(intent["owner_slot_index"]),
        _u64(intent["owner_generation"]),
        intent["request_sha256"],
        intent["dispatch_key_sha256"],
    )


def _script_bytes(script: Record) -> bytes:
    return b"".join(
        (
            _u64(script["abi_version"]),
            script["descriptor_sha256"],
            script["provider_request_sha256"],
            script["chunk_seed_sha256"],
            _u32(script["chunk_count"]),
            _u8(script["terminal_mode"]),
            _usage_bytes(script["usage"]),
            script["result_sha256"],
            script["script_sha256"],
        )
    )


def script_sha256(script: Record) -> Digest:
    return _hash(
        SCRIPT_DOMAIN,
        _u64(script["abi_version"]),
        script["descriptor_sha256"],
        script["provider_request_sha256"],
        script["chunk_seed_sha256"],
        _u32(script["chunk_count"]),
        _u8(script["terminal_mode"]),
        _usage_bytes(script["usage"]),
        script["result_sha256"],
    )


def _verify_script(script: Record, config: Record, intent: Record) -> None:
    if script["abi_version"] != SCRIPT_ABI:
        raise WireError("invalid script ABI")
    for name in (
        "descriptor_sha256",
        "provider_request_sha256",
        "chunk_seed_sha256",
        "script_sha256",
    ):
        _digest(script[name])
    _verify_usage(script["usage"])
    if script["terminal_mode"] not in (SUCCEEDED, RETRYABLE_NO_CHARGE, AMBIGUOUS):
        raise WireError("invalid terminal mode")
    billable = script["usage"]["billable_tokens"]
    if script["terminal_mode"] == SUCCEEDED:
        _digest(script["result_sha256"])
        if not billable["known"]:
            raise WireError("success requires known billable usage")
    elif script["terminal_mode"] == RETRYABLE_NO_CHARGE:
        if not billable["known"] or billable["value"] != 0:
            raise WireError("retry must prove zero billable usage")
        if script["result_sha256"] != bytes(32):
            raise WireError("retry cannot carry a result")
    elif script["result_sha256"] != bytes(32):
        raise WireError("ambiguous script cannot carry a result")
    if script["script_sha256"] != script_sha256(script):
        raise WireError("script digest mismatch")
    if script["descriptor_sha256"] != config["descriptor"]["descriptor_sha256"]:
        raise WireError("script descriptor mismatch")
    if script["provider_request_sha256"] != provider_request_sha256(
        config["descriptor"], intent
    ):
        raise WireError("provider request identity mismatch")
    if script["chunk_count"] > config["max_chunks_per_attempt"]:
        raise WireError("script exceeds chunk bound")


def initial_response_sha256(script: Record) -> Digest:
    return _hash(
        INITIAL_RESPONSE_DOMAIN,
        script["descriptor_sha256"],
        script["provider_request_sha256"],
        script["script_sha256"],
    )


def chunk_sha256(script: Record, index: int) -> Digest:
    return _hash(
        CHUNK_PAYLOAD_DOMAIN,
        script["chunk_seed_sha256"],
        script["provider_request_sha256"],
        _u32(index),
        _u32(script["chunk_count"]),
    )


def append_response_sha256(before: Digest, index: int, chunk: Digest) -> Digest:
    return _hash(CHUNK_CHAIN_DOMAIN, before, _u32(index), chunk)


def response_sha256(script: Record, count: int) -> Digest:
    chain = initial_response_sha256(script)
    for index in range(count):
        payload = chunk_sha256(script, index)
        chain = append_response_sha256(chain, index, payload)
    return chain


def _chunk_bytes(chunk: Record) -> bytes:
    return b"".join(
        (
            _u64(chunk["abi_version"]),
            chunk["intent_sha256"],
            chunk["provider_request_sha256"],
            chunk["script_sha256"],
            _u32(chunk["chunk_index"]),
            _u32(chunk["chunk_count"]),
            chunk["before_chain_sha256"],
            chunk["chunk_sha256"],
            chunk["after_chain_sha256"],
            chunk["evidence_sha256"],
        )
    )


def chunk_evidence_sha256(chunk: Record) -> Digest:
    return _hash(
        CHUNK_EVIDENCE_DOMAIN,
        _u64(chunk["abi_version"]),
        chunk["intent_sha256"],
        chunk["provider_request_sha256"],
        chunk["script_sha256"],
        _u32(chunk["chunk_index"]),
        _u32(chunk["chunk_count"]),
        chunk["before_chain_sha256"],
        chunk["chunk_sha256"],
        chunk["after_chain_sha256"],
    )


def _verify_chunk(chunk: Record, intent: Record, script: Record, index: int) -> None:
    if chunk["abi_version"] != CHUNK_ABI or chunk["chunk_index"] != index:
        raise WireError("chunk sequence mismatch")
    if chunk["chunk_count"] != script["chunk_count"] or index >= chunk["chunk_count"]:
        raise WireError("chunk cardinality mismatch")
    if chunk["intent_sha256"] != intent["intent_sha256"]:
        raise WireError("chunk intent mismatch")
    if chunk["provider_request_sha256"] != script["provider_request_sha256"]:
        raise WireError("chunk provider request mismatch")
    if chunk["script_sha256"] != script["script_sha256"]:
        raise WireError("chunk script mismatch")
    expected_payload = chunk_sha256(script, index)
    expected_before = response_sha256(script, index)
    if chunk["chunk_sha256"] != expected_payload:
        raise WireError("chunk payload digest mismatch")
    if chunk["before_chain_sha256"] != expected_before:
        raise WireError("chunk before-chain mismatch")
    if chunk["after_chain_sha256"] != append_response_sha256(
        expected_before, index, expected_payload
    ):
        raise WireError("chunk after-chain mismatch")
    if chunk["evidence_sha256"] != chunk_evidence_sha256(chunk):
        raise WireError("chunk evidence digest mismatch")


def _cancel_request_bytes(request: Record) -> bytes:
    return b"".join(
        (
            _u64(request["abi_version"]),
            request["intent_sha256"],
            request["descriptor_sha256"],
            request["provider_request_sha256"],
            request["script_sha256"],
            _u32(request["emitted_chunks"]),
            request["response_chain_sha256"],
            _u8(request["reason"]),
            request["request_sha256"],
        )
    )


def cancel_request_sha256(request: Record) -> Digest:
    return _hash(
        CANCEL_REQUEST_DOMAIN,
        _u64(request["abi_version"]),
        request["intent_sha256"],
        request["descriptor_sha256"],
        request["provider_request_sha256"],
        request["script_sha256"],
        _u32(request["emitted_chunks"]),
        request["response_chain_sha256"],
        _u8(request["reason"]),
    )


def _verify_cancel_request(
    request: Record,
    config: Record,
    intent: Record,
    script: Record,
    emitted: int,
) -> None:
    if request["abi_version"] != CANCEL_REQUEST_ABI or request["reason"] not in range(4):
        raise WireError("invalid cancellation request")
    if config["descriptor"]["capability_bits"] & CAPABILITY_ACTIVE_CANCELLATION == 0:
        raise WireError("active cancellation was not declared")
    if request["intent_sha256"] != intent["intent_sha256"]:
        raise WireError("cancellation intent mismatch")
    if request["descriptor_sha256"] != config["descriptor"]["descriptor_sha256"]:
        raise WireError("cancellation descriptor mismatch")
    if request["provider_request_sha256"] != script["provider_request_sha256"]:
        raise WireError("cancellation provider request mismatch")
    if request["script_sha256"] != script["script_sha256"]:
        raise WireError("cancellation script mismatch")
    if request["emitted_chunks"] != emitted:
        raise WireError("cancellation response position mismatch")
    if request["response_chain_sha256"] != response_sha256(script, emitted):
        raise WireError("cancellation response chain mismatch")
    if request["request_sha256"] != cancel_request_sha256(request):
        raise WireError("cancellation request digest mismatch")


def _cancel_ack_bytes(ack: Record) -> bytes:
    return b"".join(
        (
            _u64(ack["abi_version"]),
            ack["cancel_request_sha256"],
            _u8(ack["kind"]),
            _usage_bytes(ack["usage"]),
            ack["result_sha256"],
            ack["ack_sha256"],
        )
    )


def cancel_ack_sha256(ack: Record) -> Digest:
    return _hash(
        CANCEL_ACK_DOMAIN,
        _u64(ack["abi_version"]),
        ack["cancel_request_sha256"],
        _u8(ack["kind"]),
        _usage_bytes(ack["usage"]),
        ack["result_sha256"],
    )


def _known_nonzero_usage(usage: Record) -> bool:
    return any(usage[name]["known"] and usage[name]["value"] for name in COUNT_NAMES)


def _verify_cancel_ack(ack: Record, request: Record) -> None:
    if ack["abi_version"] != CANCEL_ACK_ABI or ack["kind"] not in range(4):
        raise WireError("invalid cancellation acknowledgement")
    _verify_usage(ack["usage"])
    if ack["cancel_request_sha256"] != request["request_sha256"]:
        raise WireError("cancellation acknowledgement request mismatch")
    billable = ack["usage"]["billable_tokens"]
    if ack["kind"] == CANCEL_NOT_ACCEPTED:
        if not billable["known"] or billable["value"] or _known_nonzero_usage(ack["usage"]):
            raise WireError("rejected cancellation must carry zero usage")
        if ack["result_sha256"] != bytes(32):
            raise WireError("rejected cancellation cannot carry a result")
    elif ack["kind"] == CANCEL_CONFIRMED:
        if not billable["known"] or ack["result_sha256"] != bytes(32):
            raise WireError("confirmed cancellation evidence mismatch")
    elif ack["kind"] == CANCEL_TOO_LATE_SUCCEEDED:
        if not billable["known"]:
            raise WireError("late success requires known billable usage")
        _digest(ack["result_sha256"])
    elif ack["result_sha256"] != bytes(32):
        raise WireError("ambiguous cancellation cannot carry a result")
    if ack["ack_sha256"] != cancel_ack_sha256(ack):
        raise WireError("cancellation acknowledgement digest mismatch")


def _outcome_bytes(outcome: Record) -> bytes:
    return b"".join(
        (
            _u64(outcome["abi_version"]),
            _u8(outcome["kind"]),
            _intent_bytes(outcome["intent"]),
            outcome["descriptor_sha256"],
            outcome["provider_request_sha256"],
            outcome["script_sha256"],
            _u32(outcome["emitted_chunks"]),
            outcome["response_chain_sha256"],
            _usage_bytes(outcome["usage"]),
            outcome["result_sha256"],
            outcome["outcome_sha256"],
        )
    )


def outcome_sha256(outcome: Record) -> Digest:
    return _hash(
        OUTCOME_DOMAIN,
        _u64(outcome["abi_version"]),
        _u8(outcome["kind"]),
        _intent_bytes(outcome["intent"]),
        outcome["descriptor_sha256"],
        outcome["provider_request_sha256"],
        outcome["script_sha256"],
        _u32(outcome["emitted_chunks"]),
        outcome["response_chain_sha256"],
        _usage_bytes(outcome["usage"]),
        outcome["result_sha256"],
    )


def _verify_outcome(outcome: Record, config: Record, intent: Record, script: Record) -> None:
    if outcome["abi_version"] != OUTCOME_ABI or outcome["kind"] not in range(3):
        raise WireError("invalid normal transport outcome")
    _verify_intent(outcome["intent"])
    _verify_usage(outcome["usage"])
    if outcome["intent"] != intent:
        raise WireError("transport outcome intent mismatch")
    if outcome["kind"] != script["terminal_mode"]:
        raise WireError("transport terminal classification mismatch")
    if outcome["descriptor_sha256"] != config["descriptor"]["descriptor_sha256"]:
        raise WireError("outcome descriptor mismatch")
    if outcome["provider_request_sha256"] != script["provider_request_sha256"]:
        raise WireError("outcome provider request mismatch")
    if outcome["script_sha256"] != script["script_sha256"]:
        raise WireError("outcome script mismatch")
    if outcome["emitted_chunks"] != script["chunk_count"]:
        raise WireError("normal outcome before complete stream")
    if outcome["response_chain_sha256"] != response_sha256(
        script, script["chunk_count"]
    ):
        raise WireError("normal outcome response chain mismatch")
    if outcome["usage"] != script["usage"] or outcome["result_sha256"] != script["result_sha256"]:
        raise WireError("normal outcome script evidence mismatch")
    if outcome["outcome_sha256"] != outcome_sha256(outcome):
        raise WireError("normal outcome digest mismatch")


def _cancel_outcome_bytes(outcome: Record) -> bytes:
    return b"".join(
        (
            _u64(outcome["abi_version"]),
            _u8(outcome["kind"]),
            _intent_bytes(outcome["intent"]),
            outcome["descriptor_sha256"],
            outcome["provider_request_sha256"],
            outcome["script_sha256"],
            outcome["cancel_request_sha256"],
            outcome["cancel_ack_sha256"],
            _u32(outcome["emitted_chunks"]),
            outcome["response_chain_sha256"],
            _usage_bytes(outcome["usage"]),
            outcome["result_sha256"],
            outcome["outcome_sha256"],
        )
    )


def cancel_outcome_sha256(outcome: Record) -> Digest:
    return _hash(
        CANCEL_OUTCOME_DOMAIN,
        _u64(outcome["abi_version"]),
        _u8(outcome["kind"]),
        _intent_bytes(outcome["intent"]),
        outcome["descriptor_sha256"],
        outcome["provider_request_sha256"],
        outcome["script_sha256"],
        outcome["cancel_request_sha256"],
        outcome["cancel_ack_sha256"],
        _u32(outcome["emitted_chunks"]),
        outcome["response_chain_sha256"],
        _usage_bytes(outcome["usage"]),
        outcome["result_sha256"],
    )


def _verify_cancel_outcome(
    outcome: Record,
    config: Record,
    intent: Record,
    script: Record,
    request: Record,
    ack: Record,
) -> None:
    if outcome["abi_version"] != CANCEL_OUTCOME_ABI or outcome["kind"] not in range(3):
        raise WireError("invalid terminal cancellation outcome")
    expected_kind = {
        CANCEL_CONFIRMED: CANCEL_OUTCOME_CONFIRMED,
        CANCEL_TOO_LATE_SUCCEEDED: CANCEL_OUTCOME_TOO_LATE_SUCCEEDED,
        CANCEL_AMBIGUOUS: CANCEL_OUTCOME_AMBIGUOUS,
    }.get(ack["kind"])
    if expected_kind is None or outcome["kind"] != expected_kind:
        raise WireError("cancellation outcome classification mismatch")
    if outcome["intent"] != intent:
        raise WireError("cancellation outcome intent mismatch")
    if outcome["descriptor_sha256"] != config["descriptor"]["descriptor_sha256"]:
        raise WireError("cancellation outcome descriptor mismatch")
    if outcome["provider_request_sha256"] != script["provider_request_sha256"]:
        raise WireError("cancellation outcome provider request mismatch")
    if outcome["script_sha256"] != script["script_sha256"]:
        raise WireError("cancellation outcome script mismatch")
    if outcome["cancel_request_sha256"] != request["request_sha256"]:
        raise WireError("cancellation outcome request mismatch")
    if outcome["cancel_ack_sha256"] != ack["ack_sha256"]:
        raise WireError("cancellation outcome acknowledgement mismatch")
    if outcome["emitted_chunks"] != request["emitted_chunks"]:
        raise WireError("cancellation outcome position mismatch")
    if outcome["response_chain_sha256"] != request["response_chain_sha256"]:
        raise WireError("cancellation outcome chain mismatch")
    if outcome["usage"] != ack["usage"] or outcome["result_sha256"] != ack["result_sha256"]:
        raise WireError("cancellation outcome acknowledgement evidence mismatch")
    if outcome["outcome_sha256"] != cancel_outcome_sha256(outcome):
        raise WireError("cancellation outcome digest mismatch")


def _event_bytes(event: Record) -> bytes:
    kind = event["kind"]
    if kind == CHUNK:
        return _u8(kind) + _chunk_bytes(event["chunk"])
    if kind == CANCEL_REQUEST:
        return _u8(kind) + _cancel_request_bytes(event["cancel_request"])
    if kind == CANCEL_ACK:
        return _u8(kind) + _cancel_ack_bytes(event["cancel_ack"])
    if kind == OUTCOME:
        return _u8(kind) + _outcome_bytes(event["outcome"])
    if kind == CANCEL_OUTCOME:
        return _u8(kind) + _cancel_outcome_bytes(event["cancel_outcome"])
    raise WireError("invalid transport event kind")


def _ledger_bytes(ledger: Record, names: tuple[str, ...]) -> bytes:
    return b"".join(_u64(ledger[name]) for name in names)


def _snapshot_bytes(snapshot: Record) -> bytes:
    return b"".join(
        (
            _u64(snapshot["abi_version"]),
            _u64(snapshot["harness_epoch"]),
            _u32(snapshot["slot_capacity"]),
            _u32(snapshot["max_chunks_per_attempt"]),
            _ledger_bytes(snapshot["ledger"], LEDGER_NAMES),
        )
    )


def _cancel_snapshot_bytes(snapshot: Record) -> bytes:
    return b"".join(
        (
            _u64(snapshot["abi_version"]),
            _u64(snapshot["harness_epoch"]),
            _ledger_bytes(snapshot["ledger"], CANCEL_LEDGER_NAMES),
        )
    )


def encoded_len(events: list[Record]) -> int:
    if not events or len(events) > MAX_EVENTS:
        raise WireError("event count outside wire bound")
    return FIXED_WIRE_BYTES + sum(len(_event_bytes(event)) for event in events)


def _zero_ledger(names: tuple[str, ...]) -> Record:
    return {name: 0 for name in names}


def verify_stream(evidence: Record) -> None:
    if evidence["flags"] != FLAG_REQUIRE_CLOSED:
        raise WireError("transport attempt is not closed")
    config = evidence["config"]
    slot_capacity = evidence["slot_capacity"]
    intent = evidence["intent"]
    script = evidence["script"]
    events = evidence["events"]
    settlement = evidence["settlement"]
    _verify_config(config, slot_capacity)
    _verify_intent(intent)
    _verify_script(script, config, intent)
    if not events or len(events) > MAX_EVENTS:
        raise WireError("event count outside wire bound")

    phase = "streaming"
    emitted = 0
    current_request: Record | None = None
    current_ack: Record | None = None
    normal_outcome: Record | None = None
    cancel_outcome: Record | None = None
    ledger = _zero_ledger(LEDGER_NAMES)
    ledger["active_attempts"] = 1
    ledger["started_attempts"] = 1
    cancel_ledger = _zero_ledger(CANCEL_LEDGER_NAMES)

    for event in events:
        kind = event["kind"]
        if kind == CHUNK:
            if phase != "streaming":
                raise WireError("chunk outside streaming phase")
            _verify_chunk(event["chunk"], intent, script, emitted)
            emitted += 1
            ledger["emitted_chunks"] += 1
        elif kind == CANCEL_REQUEST:
            if phase != "streaming":
                raise WireError("overlapping cancellation request")
            request = event["cancel_request"]
            _verify_cancel_request(request, config, intent, script, emitted)
            current_request = request
            phase = "cancel_pending"
            cancel_ledger["pending_cancellations"] = 1
            cancel_ledger["requested_cancellations"] += 1
        elif kind == CANCEL_ACK:
            if phase != "cancel_pending" or current_request is None:
                raise WireError("cancellation acknowledgement without request")
            ack = event["cancel_ack"]
            _verify_cancel_ack(ack, current_request)
            cancel_ledger["pending_cancellations"] = 0
            if ack["kind"] == CANCEL_NOT_ACCEPTED:
                cancel_ledger["rejected_cancellations"] += 1
                current_request = None
                phase = "streaming"
            else:
                current_ack = ack
                phase = "cancel_acked"
        elif kind == OUTCOME:
            if phase != "streaming" or emitted != script["chunk_count"]:
                raise WireError("normal outcome at invalid lifecycle position")
            outcome = event["outcome"]
            _verify_outcome(outcome, config, intent, script)
            ledger["active_attempts"] = 0
            ledger["completed_unacknowledged"] = 1
            ledger[
                {
                    SUCCEEDED: "successful_outcomes",
                    RETRYABLE_NO_CHARGE: "retryable_outcomes",
                    AMBIGUOUS: "ambiguous_outcomes",
                }[outcome["kind"]]
            ] = 1
            normal_outcome = outcome
            phase = "complete"
        elif kind == CANCEL_OUTCOME:
            if phase != "cancel_acked" or current_request is None or current_ack is None:
                raise WireError("cancellation outcome without accepted acknowledgement")
            outcome = event["cancel_outcome"]
            _verify_cancel_outcome(
                outcome, config, intent, script, current_request, current_ack
            )
            if outcome["emitted_chunks"] != emitted:
                raise WireError("cancellation outcome emitted count mismatch")
            ledger["active_attempts"] = 0
            ledger["completed_unacknowledged"] = 1
            cancel_ledger[
                {
                    CANCEL_OUTCOME_CONFIRMED: "confirmed_cancellations",
                    CANCEL_OUTCOME_TOO_LATE_SUCCEEDED: "too_late_successes",
                    CANCEL_OUTCOME_AMBIGUOUS: "ambiguous_cancellations",
                }[outcome["kind"]]
            ] = 1
            billable = outcome["usage"]["billable_tokens"]
            if billable["known"]:
                cancel_ledger["known_post_cancel_billable_tokens"] = billable["value"]
            else:
                cancel_ledger["unknown_post_cancel_usage"] = 1
            cancel_outcome = outcome
            phase = "complete"
        else:
            raise WireError("invalid transport event kind")

    if phase != "complete" or (normal_outcome is None) == (cancel_outcome is None):
        raise WireError("transport attempt is not uniquely terminal")
    ledger["completed_unacknowledged"] = 0
    ledger["acknowledged_attempts"] = 1

    receipt = settlement["receipt"]
    if receipt["intent"] != intent:
        raise WireError("settlement intent mismatch")
    if normal_outcome is not None:
        expected = {
            SUCCEEDED: settlement_wire.SUCCEEDED,
            RETRYABLE_NO_CHARGE: settlement_wire.RETRYABLE_NO_CHARGE,
            AMBIGUOUS: settlement_wire.AMBIGUOUS,
        }[normal_outcome["kind"]]
        terminal = normal_outcome
    else:
        expected = {
            CANCEL_OUTCOME_CONFIRMED: settlement_wire.FAILED,
            CANCEL_OUTCOME_TOO_LATE_SUCCEEDED: settlement_wire.SUCCEEDED,
            CANCEL_OUTCOME_AMBIGUOUS: settlement_wire.AMBIGUOUS,
        }[cancel_outcome["kind"]]
        terminal = cancel_outcome
    if (
        receipt["outcome"] != expected
        or receipt["usage"] != terminal["usage"]
        or receipt["result_sha256"] != terminal["result_sha256"]
    ):
        raise WireError("transport terminal outcome does not match settlement")

    final_snapshot = evidence["final_snapshot"]
    if (
        final_snapshot["abi_version"] != SNAPSHOT_ABI
        or final_snapshot["harness_epoch"] != config["harness_epoch"]
        or final_snapshot["slot_capacity"] != slot_capacity
        or final_snapshot["max_chunks_per_attempt"]
        != config["max_chunks_per_attempt"]
        or final_snapshot["ledger"] != ledger
    ):
        raise WireError("final transport snapshot mismatch")
    final_cancel = evidence["final_cancel_snapshot"]
    if (
        final_cancel["abi_version"] != CANCEL_SNAPSHOT_ABI
        or final_cancel["harness_epoch"] != config["harness_epoch"]
        or final_cancel["ledger"] != cancel_ledger
    ):
        raise WireError("final cancellation snapshot mismatch")


def encode_evidence(evidence: Record) -> bytes:
    verify_stream(evidence)
    events = evidence["events"]
    total = encoded_len(events)
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(total),
            _u32(evidence["flags"]),
            _u32(len(events)),
            _u32(evidence["slot_capacity"]),
            _u32(0),
            _config_bytes(evidence["config"]),
            configuration_sha256(evidence["config"], evidence["slot_capacity"]),
            _intent_bytes(evidence["intent"]),
            _script_bytes(evidence["script"]),
            b"".join(_event_bytes(event) for event in events),
            evidence["settlement_envelope"],
            _snapshot_bytes(evidence["final_snapshot"]),
            _cancel_snapshot_bytes(evidence["final_cancel_snapshot"]),
        )
    )
    if len(prefix) != total - 32:
        raise WireError("internal transport wire length mismatch")
    return prefix + _hash(ENVELOPE_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if end > len(self.data):
            raise WireError("truncated transport wire")
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
    known = reader.u8()
    if known not in (0, 1):
        raise WireError("noncanonical count boolean")
    return {"known": bool(known), "value": reader.u64()}


def _read_usage(reader: _Reader) -> Record:
    usage = {"abi_version": reader.u64()}
    usage.update({name: _read_count(reader) for name in COUNT_NAMES})
    usage["usage_sha256"] = reader.digest()
    return usage


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


def _read_descriptor(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "transport_adapter_abi": reader.u64(),
        "provider_namespace_sha256": reader.digest(),
        "capability_bits": reader.u64(),
        "descriptor_sha256": reader.digest(),
    }


def _read_config(reader: _Reader) -> Record:
    return {
        "harness_epoch": reader.u64(),
        "challenge": reader.digest(),
        "max_chunks_per_attempt": reader.u32(),
        "descriptor": _read_descriptor(reader),
    }


def _read_script(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "descriptor_sha256": reader.digest(),
        "provider_request_sha256": reader.digest(),
        "chunk_seed_sha256": reader.digest(),
        "chunk_count": reader.u32(),
        "terminal_mode": reader.u8(),
        "usage": _read_usage(reader),
        "result_sha256": reader.digest(),
        "script_sha256": reader.digest(),
    }


def _read_chunk(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "intent_sha256": reader.digest(),
        "provider_request_sha256": reader.digest(),
        "script_sha256": reader.digest(),
        "chunk_index": reader.u32(),
        "chunk_count": reader.u32(),
        "before_chain_sha256": reader.digest(),
        "chunk_sha256": reader.digest(),
        "after_chain_sha256": reader.digest(),
        "evidence_sha256": reader.digest(),
    }


def _read_cancel_request(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "intent_sha256": reader.digest(),
        "descriptor_sha256": reader.digest(),
        "provider_request_sha256": reader.digest(),
        "script_sha256": reader.digest(),
        "emitted_chunks": reader.u32(),
        "response_chain_sha256": reader.digest(),
        "reason": reader.u8(),
        "request_sha256": reader.digest(),
    }


def _read_cancel_ack(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "cancel_request_sha256": reader.digest(),
        "kind": reader.u8(),
        "usage": _read_usage(reader),
        "result_sha256": reader.digest(),
        "ack_sha256": reader.digest(),
    }


def _read_outcome(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "kind": reader.u8(),
        "intent": _read_intent(reader),
        "descriptor_sha256": reader.digest(),
        "provider_request_sha256": reader.digest(),
        "script_sha256": reader.digest(),
        "emitted_chunks": reader.u32(),
        "response_chain_sha256": reader.digest(),
        "usage": _read_usage(reader),
        "result_sha256": reader.digest(),
        "outcome_sha256": reader.digest(),
    }


def _read_cancel_outcome(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "kind": reader.u8(),
        "intent": _read_intent(reader),
        "descriptor_sha256": reader.digest(),
        "provider_request_sha256": reader.digest(),
        "script_sha256": reader.digest(),
        "cancel_request_sha256": reader.digest(),
        "cancel_ack_sha256": reader.digest(),
        "emitted_chunks": reader.u32(),
        "response_chain_sha256": reader.digest(),
        "usage": _read_usage(reader),
        "result_sha256": reader.digest(),
        "outcome_sha256": reader.digest(),
    }


def _read_event(reader: _Reader) -> Record:
    kind = reader.u8()
    if kind == CHUNK:
        return {"kind": kind, "chunk": _read_chunk(reader)}
    if kind == CANCEL_REQUEST:
        return {"kind": kind, "cancel_request": _read_cancel_request(reader)}
    if kind == CANCEL_ACK:
        return {"kind": kind, "cancel_ack": _read_cancel_ack(reader)}
    if kind == OUTCOME:
        return {"kind": kind, "outcome": _read_outcome(reader)}
    if kind == CANCEL_OUTCOME:
        return {"kind": kind, "cancel_outcome": _read_cancel_outcome(reader)}
    raise WireError("invalid transport event kind")


def _read_ledger(reader: _Reader, names: tuple[str, ...]) -> Record:
    return {name: reader.u64() for name in names}


def _read_snapshot(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "harness_epoch": reader.u64(),
        "slot_capacity": reader.u32(),
        "max_chunks_per_attempt": reader.u32(),
        "ledger": _read_ledger(reader, LEDGER_NAMES),
    }


def _read_cancel_snapshot(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "harness_epoch": reader.u64(),
        "ledger": _read_ledger(reader, CANCEL_LEDGER_NAMES),
    }


def decode_and_verify(encoded: bytes) -> Record:
    if len(encoded) < FIXED_WIRE_BYTES + 1:
        raise WireError("transport envelope is too short")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC or reader.u64() != WIRE_ABI:
        raise WireError("invalid transport wire magic or ABI")
    if reader.u64() != len(encoded):
        raise WireError("invalid declared transport wire length")
    flags = reader.u32()
    event_count = reader.u32()
    slot_capacity = reader.u32()
    if reader.u32() != 0:
        raise WireError("nonzero reserved header field")
    if flags != FLAG_REQUIRE_CLOSED or not 0 < event_count <= MAX_EVENTS:
        raise WireError("invalid flags or event count")
    expected_root = _hash(ENVELOPE_DOMAIN, encoded[:-32])
    if encoded[-32:] != expected_root:
        raise WireError("transport envelope digest mismatch")
    config = _read_config(reader)
    if reader.digest() != configuration_sha256(config, slot_capacity):
        raise WireError("transport configuration commitment mismatch")
    intent = _read_intent(reader)
    script = _read_script(reader)
    events = [_read_event(reader) for _ in range(event_count)]
    try:
        settlement_envelope = reader.take(settlement_wire.ENCODED_BYTES)
        settlement = settlement_wire.decode_and_verify(settlement_envelope)
    except settlement_wire.WireError as exc:
        raise WireError("invalid nested settlement envelope") from exc
    final_snapshot = _read_snapshot(reader)
    final_cancel_snapshot = _read_cancel_snapshot(reader)
    envelope_sha256 = reader.digest()
    if reader.position != len(encoded) or envelope_sha256 != expected_root:
        raise WireError("trailing transport data or root drift")
    evidence = {
        "flags": flags,
        "config": config,
        "slot_capacity": slot_capacity,
        "intent": intent,
        "script": script,
        "events": events,
        "settlement": settlement,
        "settlement_envelope": settlement_envelope,
        "final_snapshot": final_snapshot,
        "final_cancel_snapshot": final_cancel_snapshot,
        "envelope_sha256": envelope_sha256,
    }
    if encoded_len(events) != len(encoded):
        raise WireError("transport event shapes do not match declared length")
    verify_stream(evidence)
    return evidence


def reseal_for_test(encoded: bytes) -> bytes:
    if len(encoded) < 32:
        raise WireError("transport envelope is too short")
    return encoded[:-32] + _hash(ENVELOPE_DOMAIN, encoded[:-32])


def _seed_digest(seed: int) -> Digest:
    return bytes((seed,)) * 32


def _make_gateway_fixture() -> tuple[Record, Record, Record]:
    request: Record = {
        "abi_version": settlement_wire.REQUEST_ABI,
        "provider_adapter_abi": 0x5452414E53504F52,
        "isolation_key": 0x5452414E5349534F,
        "request_key": 7,
        "request_generation": 1,
        "model_sha256": _seed_digest(0x11),
        "context_sha256": _seed_digest(0x22),
        "tool_schema_sha256": _seed_digest(0x33),
        "policy_sha256": _seed_digest(0x44),
        "sampling_sha256": _seed_digest(0x55),
        "input_token_estimate": 100,
        "max_output_tokens": 50,
        "reuse_policy": 1,
    }
    request["request_sha256"] = settlement_wire.request_sha256(request)
    gateway_config = {
        "gateway_epoch": 0x5452414E53475701,
        "challenge": _seed_digest(0xA1),
        "limits": {
            "max_reserved_tokens": 1000,
            "max_reserved_tokens_per_isolation": 1000,
            "max_request_tokens": 500,
            "max_followers_per_owner": 1,
        },
    }
    dispatch_key = settlement_wire.dispatch_key_sha256(request)
    request_set = gateway_wire.request_set_sha256(
        bytes(32), 0, request["request_sha256"]
    )
    ledger = gateway_wire._zero_ledger()  # noqa: SLF001
    chain = gateway_wire.initial_chain_sha256(gateway_config, 1, 1)
    after_admit = copy.deepcopy(ledger)
    after_admit["reserved_tokens"] = 150
    after_admit["active_handles"] = 1
    after_admit["ready_owners"] = 1
    admitted = {
        "abi_version": gateway_wire.EVENT_ABI,
        "gateway_epoch": gateway_config["gateway_epoch"],
        "sequence": 0,
        "kind": gateway_wire.OWNER_ADMITTED,
        "owner_slot_index": 0,
        "owner_generation": 1,
        "attempt_generation": 0,
        "request_sha256": request["request_sha256"],
        "dispatch_key_sha256": dispatch_key,
        "intent_sha256": bytes(32),
        "usage_sha256": bytes(32),
        "result_sha256": bytes(32),
        "request_set_count": 1,
        "request_set_sha256": request_set,
        "reservation_tokens": 150,
        "billable_tokens": 0,
        "before": ledger,
        "after": after_admit,
        "previous_chain_sha256": chain,
    }
    admitted["event_sha256"] = gateway_wire.event_sha256(admitted)
    intent: Record = {
        "abi_version": settlement_wire.INTENT_ABI,
        "gateway_epoch": gateway_config["gateway_epoch"],
        "owner_slot_index": 0,
        "owner_generation": 1,
        "attempt_generation": 1,
        "request_sha256": request["request_sha256"],
        "dispatch_key_sha256": dispatch_key,
        "reserved_tokens": 150,
        "previous_event_chain_sha256": admitted["event_sha256"],
    }
    intent["intent_sha256"] = settlement_wire.intent_sha256(intent)
    after_dispatch = copy.deepcopy(after_admit)
    after_dispatch["ready_owners"] = 0
    after_dispatch["dispatched_owners"] = 1
    after_dispatch["physical_dispatches"] = 1
    dispatched = {
        "abi_version": gateway_wire.EVENT_ABI,
        "gateway_epoch": gateway_config["gateway_epoch"],
        "sequence": 1,
        "kind": gateway_wire.DISPATCH_STARTED,
        "owner_slot_index": 0,
        "owner_generation": 1,
        "attempt_generation": 1,
        "request_sha256": request["request_sha256"],
        "dispatch_key_sha256": dispatch_key,
        "intent_sha256": intent["intent_sha256"],
        "usage_sha256": bytes(32),
        "result_sha256": bytes(32),
        "request_set_count": 1,
        "request_set_sha256": request_set,
        "reservation_tokens": 150,
        "billable_tokens": 0,
        "before": after_admit,
        "after": after_dispatch,
        "previous_chain_sha256": admitted["event_sha256"],
    }
    dispatched["event_sha256"] = gateway_wire.event_sha256(dispatched)
    return request, intent, {
        "config": gateway_config,
        "request_set_sha256": request_set,
        "before_terminal": after_dispatch,
        "previous_chain_sha256": dispatched["event_sha256"],
    }


def build_demo_evidence() -> Record:
    request, intent, gateway_state = _make_gateway_fixture()
    descriptor: Record = {
        "abi_version": DESCRIPTOR_ABI,
        "transport_adapter_abi": 0x5452414E53414450,
        "provider_namespace_sha256": _seed_digest(0x91),
        "capability_bits": REQUIRED_CAPABILITIES | CAPABILITY_ACTIVE_CANCELLATION,
    }
    descriptor["descriptor_sha256"] = descriptor_sha256(descriptor)
    config = {
        "harness_epoch": 0x5452414E53485201,
        "challenge": _seed_digest(0xA2),
        "max_chunks_per_attempt": 8,
        "descriptor": descriptor,
    }
    script: Record = {
        "abi_version": SCRIPT_ABI,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "provider_request_sha256": provider_request_sha256(descriptor, intent),
        "chunk_seed_sha256": _seed_digest(0x61),
        "chunk_count": 3,
        "terminal_mode": SUCCEEDED,
        "usage": settlement_wire.make_usage(100, 20, 40, 8, 0, 80),
        "result_sha256": _seed_digest(0x71),
    }
    script["script_sha256"] = script_sha256(script)
    events: list[Record] = []
    for index in range(2):
        payload = chunk_sha256(script, index)
        before = response_sha256(script, index)
        chunk: Record = {
            "abi_version": CHUNK_ABI,
            "intent_sha256": intent["intent_sha256"],
            "provider_request_sha256": script["provider_request_sha256"],
            "script_sha256": script["script_sha256"],
            "chunk_index": index,
            "chunk_count": script["chunk_count"],
            "before_chain_sha256": before,
            "chunk_sha256": payload,
            "after_chain_sha256": append_response_sha256(before, index, payload),
        }
        chunk["evidence_sha256"] = chunk_evidence_sha256(chunk)
        events.append({"kind": CHUNK, "chunk": chunk})
    cancel_request: Record = {
        "abi_version": CANCEL_REQUEST_ABI,
        "intent_sha256": intent["intent_sha256"],
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "provider_request_sha256": script["provider_request_sha256"],
        "script_sha256": script["script_sha256"],
        "emitted_chunks": 2,
        "response_chain_sha256": response_sha256(script, 2),
        "reason": 1,
    }
    cancel_request["request_sha256"] = cancel_request_sha256(cancel_request)
    events.append({"kind": CANCEL_REQUEST, "cancel_request": cancel_request})
    cancel_usage = settlement_wire.make_usage(100, 5, 81, 0, 0, 24)
    cancel_ack: Record = {
        "abi_version": CANCEL_ACK_ABI,
        "cancel_request_sha256": cancel_request["request_sha256"],
        "kind": CANCEL_CONFIRMED,
        "usage": cancel_usage,
        "result_sha256": bytes(32),
    }
    cancel_ack["ack_sha256"] = cancel_ack_sha256(cancel_ack)
    events.append({"kind": CANCEL_ACK, "cancel_ack": cancel_ack})
    cancel_outcome: Record = {
        "abi_version": CANCEL_OUTCOME_ABI,
        "kind": CANCEL_OUTCOME_CONFIRMED,
        "intent": intent,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "provider_request_sha256": script["provider_request_sha256"],
        "script_sha256": script["script_sha256"],
        "cancel_request_sha256": cancel_request["request_sha256"],
        "cancel_ack_sha256": cancel_ack["ack_sha256"],
        "emitted_chunks": 2,
        "response_chain_sha256": response_sha256(script, 2),
        "usage": cancel_usage,
        "result_sha256": bytes(32),
    }
    cancel_outcome["outcome_sha256"] = cancel_outcome_sha256(cancel_outcome)
    events.append({"kind": CANCEL_OUTCOME, "cancel_outcome": cancel_outcome})

    after_terminal = copy.deepcopy(gateway_state["before_terminal"])
    after_terminal["reserved_tokens"] = 0
    after_terminal["settled_billable_tokens"] = 24
    after_terminal["dispatched_owners"] = 0
    after_terminal["failed_dispatches"] = 1
    terminal_event = {
        "abi_version": gateway_wire.EVENT_ABI,
        "gateway_epoch": gateway_state["config"]["gateway_epoch"],
        "sequence": 2,
        "kind": gateway_wire.FAILED,
        "owner_slot_index": 0,
        "owner_generation": 1,
        "attempt_generation": 1,
        "request_sha256": request["request_sha256"],
        "dispatch_key_sha256": intent["dispatch_key_sha256"],
        "intent_sha256": intent["intent_sha256"],
        "usage_sha256": cancel_usage["usage_sha256"],
        "result_sha256": bytes(32),
        "request_set_count": 1,
        "request_set_sha256": gateway_state["request_set_sha256"],
        "reservation_tokens": 150,
        "billable_tokens": 24,
        "before": gateway_state["before_terminal"],
        "after": after_terminal,
        "previous_chain_sha256": gateway_state["previous_chain_sha256"],
    }
    terminal_event["event_sha256"] = gateway_wire.event_sha256(terminal_event)
    receipt: Record = {
        "abi_version": settlement_wire.RECEIPT_ABI,
        "outcome": settlement_wire.FAILED,
        "intent": intent,
        "usage": cancel_usage,
        "result_sha256": bytes(32),
        "request_set_count": 1,
        "request_set_sha256": gateway_state["request_set_sha256"],
        "event_sha256": terminal_event["event_sha256"],
    }
    receipt["receipt_sha256"] = settlement_wire.receipt_sha256(receipt)
    settlement_envelope = settlement_wire.encode_evidence(request, receipt)
    ledger = _zero_ledger(LEDGER_NAMES)
    ledger.update(
        {
            "started_attempts": 1,
            "emitted_chunks": 2,
            "acknowledged_attempts": 1,
        }
    )
    cancel_ledger = _zero_ledger(CANCEL_LEDGER_NAMES)
    cancel_ledger.update(
        {
            "requested_cancellations": 1,
            "confirmed_cancellations": 1,
            "known_post_cancel_billable_tokens": 24,
        }
    )
    evidence = {
        "flags": FLAG_REQUIRE_CLOSED,
        "config": config,
        "slot_capacity": 1,
        "intent": intent,
        "script": script,
        "events": events,
        "settlement": settlement_wire.decode_and_verify(settlement_envelope),
        "settlement_envelope": settlement_envelope,
        "final_snapshot": {
            "abi_version": SNAPSHOT_ABI,
            "harness_epoch": config["harness_epoch"],
            "slot_capacity": 1,
            "max_chunks_per_attempt": config["max_chunks_per_attempt"],
            "ledger": ledger,
        },
        "final_cancel_snapshot": {
            "abi_version": CANCEL_SNAPSHOT_ABI,
            "harness_epoch": config["harness_epoch"],
            "ledger": cancel_ledger,
        },
    }
    verify_stream(evidence)
    return evidence
