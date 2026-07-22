"""Independent Python codec and replay verifier for Gateway event wire v1."""

from __future__ import annotations

import copy
import hashlib
import struct
from typing import Any

from bench import provider_settlement_wire as settlement_wire


class WireError(ValueError):
    """The event stream, lifecycle, settlement binding or envelope is invalid."""


Digest = bytes
Record = dict[str, Any]

MAGIC = b"GPEWIRE1"
WIRE_ABI = 0x4750455700000001
FLAG_REQUIRE_CLOSED = 1
MAX_EVENTS = 4096
MAX_REPLAY_SLOTS = 8192
HEADER_BYTES = 48
LIMITS_WIRE_BYTES = 28
CONFIG_WIRE_BYTES = 68
LEDGER_WIRE_BYTES = 144
EVENT_WIRE_BYTES = 609
EVENT_PREFIX_BYTES = 610
SNAPSHOT_WIRE_BYTES = 236
FIXED_WIRE_BYTES = 384

GATEWAY_ABI = 0x4750544700000002
REQUEST_ABI = 0x4750545100000001
USAGE_ABI = 0x4750545500000001
HANDLE_ABI = 0x4750544800000001
INTENT_ABI = 0x4750544900000001
PERMIT_ABI = 0x4750545000000001
EVENT_ABI = 0x4750544500000002
RECEIPT_ABI = 0x4750545200000001
SNAPSHOT_ABI = 0x4750545300000002

REQUEST_SET_DOMAIN = b"glacier-provider-request-set-v1\x00"
EVENT_HASH_DOMAIN = b"glacier-provider-token-event-v2\x00"
CHAIN_HASH_DOMAIN = b"glacier-provider-token-chain-v2\x00"
ENVELOPE_HASH_DOMAIN = b"glacier-provider-gateway-event-wire-v1\x00"

OWNER_ADMITTED = 0
FOLLOWER_COALESCED = 1
DISPATCH_STARTED = 2
RETRYABLE_NO_CHARGE = 3
AMBIGUOUS = 4
SUCCEEDED = 5
FAILED = 6
RESOLVED_SUCCESS = 7
RESOLVED_FAILURE = 8
OWNER_CANCELLED = 9
FOLLOWER_CANCELLED = 10
ACKNOWLEDGED = 11

SETTLEMENT_KINDS = {
    RETRYABLE_NO_CHARGE,
    AMBIGUOUS,
    SUCCEEDED,
    FAILED,
    RESOLVED_SUCCESS,
    RESOLVED_FAILURE,
}

LEDGER_NAMES = (
    "reserved_tokens",
    "settled_billable_tokens",
    "budget_overrun_tokens",
    "budget_overrun_dispatches",
    "active_handles",
    "ready_owners",
    "dispatched_owners",
    "ambiguous_owners",
    "physical_dispatches",
    "coalesced_requests",
    "retryable_attempts",
    "ambiguous_attempts",
    "successful_dispatches",
    "failed_dispatches",
    "acknowledged_handles",
    "cancelled_handles",
    "cancelled_followers",
    "cancelled_ready_owners",
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


def _digest(value: bytes, *, allow_zero: bool = False) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise WireError("invalid digest")
    if not allow_zero and value == bytes(32):
        raise WireError("zero digest is not allowed")
    return value


def _hash(domain: bytes, *parts: bytes) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _zero_ledger() -> Record:
    return {name: 0 for name in LEDGER_NAMES}


def _ledger_bytes(ledger: Record) -> bytes:
    return b"".join(_u64(ledger[name]) for name in LEDGER_NAMES)


def _limits_bytes(limits: Record) -> bytes:
    return b"".join(
        (
            _u64(limits["max_reserved_tokens"]),
            _u64(limits["max_reserved_tokens_per_isolation"]),
            _u64(limits["max_request_tokens"]),
            _u32(limits["max_followers_per_owner"]),
        )
    )


def _config_bytes(config: Record) -> bytes:
    return (
        _u64(config["gateway_epoch"])
        + config["challenge"]
        + _limits_bytes(config["limits"])
    )


def _event_bytes(event: Record, *, include_digest: bool) -> bytes:
    encoded = b"".join(
        (
            _u64(event["abi_version"]),
            _u64(event["gateway_epoch"]),
            _u64(event["sequence"]),
            _u8(event["kind"]),
            _u32(event["owner_slot_index"]),
            _u64(event["owner_generation"]),
            _u64(event["attempt_generation"]),
            event["request_sha256"],
            event["dispatch_key_sha256"],
            event["intent_sha256"],
            event["usage_sha256"],
            event["result_sha256"],
            _u32(event["request_set_count"]),
            event["request_set_sha256"],
            _u64(event["reservation_tokens"]),
            _u64(event["billable_tokens"]),
            _ledger_bytes(event["before"]),
            _ledger_bytes(event["after"]),
            event["previous_chain_sha256"],
        )
    )
    if include_digest:
        encoded += event["event_sha256"]
    return encoded


def event_sha256(event: Record) -> Digest:
    return _hash(EVENT_HASH_DOMAIN, _event_bytes(event, include_digest=False))


def request_set_sha256(
    before_sha256: Digest,
    count_before: int,
    request_sha256: Digest,
) -> Digest:
    return _hash(
        REQUEST_SET_DOMAIN,
        _u64(REQUEST_ABI),
        before_sha256,
        _u32(count_before),
        request_sha256,
    )


def initial_chain_sha256(
    config: Record,
    owner_capacity: int,
    follower_capacity: int,
) -> Digest:
    return _hash(
        CHAIN_HASH_DOMAIN,
        _u64(GATEWAY_ABI),
        _u64(REQUEST_ABI),
        _u64(USAGE_ABI),
        _u64(HANDLE_ABI),
        _u64(INTENT_ABI),
        _u64(PERMIT_ABI),
        _u64(EVENT_ABI),
        _u64(RECEIPT_ABI),
        _u64(SNAPSHOT_ABI),
        _u64(config["gateway_epoch"]),
        config["challenge"],
        _limits_bytes(config["limits"]),
        _u32(owner_capacity),
        _u32(follower_capacity),
    )


def _validate_config(config: Record, owner_capacity: int) -> None:
    limits = config["limits"]
    if config["gateway_epoch"] == 0 or owner_capacity == 0:
        raise WireError("invalid Gateway configuration")
    _u64(config["gateway_epoch"])
    _digest(config["challenge"])
    for name in (
        "max_reserved_tokens",
        "max_reserved_tokens_per_isolation",
        "max_request_tokens",
    ):
        if limits[name] == 0:
            raise WireError("zero token limit")
        _u64(limits[name])
    _u32(limits["max_followers_per_owner"])
    if not (
        limits["max_request_tokens"]
        <= limits["max_reserved_tokens_per_isolation"]
        <= limits["max_reserved_tokens"]
    ):
        raise WireError("inconsistent token limits")


def _checked_add(value: int, amount: int) -> int:
    result = value + amount
    if result > 0xFFFFFFFFFFFFFFFF:
        raise WireError("ledger overflow")
    return result


def _checked_sub(value: int, amount: int) -> int:
    if amount > value:
        raise WireError("ledger underflow")
    return value - amount


def _expected_after(event: Record) -> Record:
    expected = copy.deepcopy(event["before"])
    kind = event["kind"]
    reservation = event["reservation_tokens"]
    billable = event["billable_tokens"]

    def add(name: str, amount: int = 1) -> None:
        expected[name] = _checked_add(expected[name], amount)

    def sub(name: str, amount: int = 1) -> None:
        expected[name] = _checked_sub(expected[name], amount)

    if kind == OWNER_ADMITTED:
        add("reserved_tokens", reservation)
        add("active_handles")
        add("ready_owners")
    elif kind == FOLLOWER_COALESCED:
        add("active_handles")
        add("coalesced_requests")
    elif kind == OWNER_CANCELLED:
        sub("reserved_tokens", reservation)
        sub("active_handles")
        sub("ready_owners")
        add("cancelled_handles")
        add("cancelled_ready_owners")
    elif kind == FOLLOWER_CANCELLED:
        sub("active_handles")
        add("cancelled_handles")
        add("cancelled_followers")
    elif kind == DISPATCH_STARTED:
        sub("ready_owners")
        add("dispatched_owners")
        add("physical_dispatches")
    elif kind == RETRYABLE_NO_CHARGE:
        if billable != 0:
            raise WireError("retry event is not no-charge")
        sub("dispatched_owners")
        add("ready_owners")
        add("retryable_attempts")
    elif kind == AMBIGUOUS:
        sub("dispatched_owners")
        add("ambiguous_owners")
        add("ambiguous_attempts")
    elif kind in (SUCCEEDED, FAILED, RESOLVED_SUCCESS, RESOLVED_FAILURE):
        sub("reserved_tokens", reservation)
        add("settled_billable_tokens", billable)
        if billable > reservation:
            add("budget_overrun_tokens", billable - reservation)
            add("budget_overrun_dispatches")
        if kind in (SUCCEEDED, FAILED):
            sub("dispatched_owners")
        else:
            sub("ambiguous_owners")
        if kind in (SUCCEEDED, RESOLVED_SUCCESS):
            add("successful_dispatches")
        else:
            add("failed_dispatches")
    elif kind == ACKNOWLEDGED:
        sub("active_handles")
        add("acknowledged_handles")
    else:
        raise WireError("invalid event kind")
    return expected


def _verify_event(event: Record) -> None:
    if event["abi_version"] != EVENT_ABI or event["gateway_epoch"] == 0:
        raise WireError("invalid event ABI or epoch")
    if event["kind"] not in range(12):
        raise WireError("invalid event kind")
    if (
        event["owner_generation"] == 0
        or event["reservation_tokens"] == 0
        or event["request_set_count"] == 0
    ):
        raise WireError("event requires nonzero ownership fields")
    _u32(event["owner_slot_index"])
    _u32(event["request_set_count"])
    for name in (
        "request_sha256",
        "dispatch_key_sha256",
        "request_set_sha256",
        "previous_chain_sha256",
        "event_sha256",
    ):
        _digest(event[name])
    for name in ("intent_sha256", "usage_sha256", "result_sha256"):
        _digest(event[name], allow_zero=True)
    for ledger_name in LEDGER_NAMES:
        _u64(event["before"][ledger_name])
        _u64(event["after"][ledger_name])

    kind = event["kind"]
    zero = bytes(32)
    no_attempt = kind in (OWNER_ADMITTED, FOLLOWER_COALESCED, OWNER_CANCELLED)
    optional_attempt = kind == FOLLOWER_CANCELLED
    if no_attempt:
        if (
            event["attempt_generation"] != 0
            or event["intent_sha256"] != zero
            or event["usage_sha256"] != zero
            or event["result_sha256"] != zero
            or event["billable_tokens"] != 0
        ):
            raise WireError("unexpected attempt evidence")
    elif optional_attempt:
        if (
            (event["attempt_generation"] == 0)
            != (event["intent_sha256"] == zero)
            or event["usage_sha256"] != zero
            or event["result_sha256"] != zero
            or event["billable_tokens"] != 0
        ):
            raise WireError("invalid optional attempt evidence")
    elif event["attempt_generation"] == 0 or event["intent_sha256"] == zero:
        raise WireError("missing attempt evidence")

    if kind == OWNER_ADMITTED and event["request_set_count"] != 1:
        raise WireError("owner admission request set is not singular")
    if kind in (FOLLOWER_COALESCED, FOLLOWER_CANCELLED) and event[
        "request_set_count"
    ] < 2:
        raise WireError("follower event has no follower")
    if kind in (DISPATCH_STARTED, RETRYABLE_NO_CHARGE) and event[
        "billable_tokens"
    ] != 0:
        raise WireError("invalid pre-settlement billing")

    has_usage = kind in (
        RETRYABLE_NO_CHARGE,
        AMBIGUOUS,
        SUCCEEDED,
        FAILED,
        RESOLVED_SUCCESS,
        RESOLVED_FAILURE,
        ACKNOWLEDGED,
    )
    if has_usage != (event["usage_sha256"] != zero):
        raise WireError("usage presence mismatch")
    has_result = kind in (SUCCEEDED, RESOLVED_SUCCESS) or (
        kind == ACKNOWLEDGED and event["result_sha256"] != zero
    )
    if has_result != (event["result_sha256"] != zero):
        raise WireError("result presence mismatch")
    if _expected_after(event) != event["after"]:
        raise WireError("invalid ledger transition")
    if event["event_sha256"] != event_sha256(event):
        raise WireError("event digest mismatch")


def _settlement_matches_event(event: Record, decoded: Record) -> None:
    request = decoded["request"]
    receipt = decoded["receipt"]
    outcome_for_kind = {
        RETRYABLE_NO_CHARGE: settlement_wire.RETRYABLE_NO_CHARGE,
        AMBIGUOUS: settlement_wire.AMBIGUOUS,
        SUCCEEDED: settlement_wire.SUCCEEDED,
        FAILED: settlement_wire.FAILED,
        RESOLVED_SUCCESS: settlement_wire.RESOLVED_SUCCESS,
        RESOLVED_FAILURE: settlement_wire.RESOLVED_FAILURE,
    }
    if receipt["outcome"] != outcome_for_kind[event["kind"]]:
        raise WireError("settlement outcome does not match event")
    intent = receipt["intent"]
    exact_pairs = (
        (request["request_sha256"], event["request_sha256"]),
        (intent["request_sha256"], event["request_sha256"]),
        (intent["dispatch_key_sha256"], event["dispatch_key_sha256"]),
        (intent["intent_sha256"], event["intent_sha256"]),
        (receipt["usage"]["usage_sha256"], event["usage_sha256"]),
        (receipt["result_sha256"], event["result_sha256"]),
        (receipt["request_set_sha256"], event["request_set_sha256"]),
        (receipt["event_sha256"], event["event_sha256"]),
    )
    if any(left != right for left, right in exact_pairs):
        raise WireError("settlement digest binding mismatch")
    if (
        intent["gateway_epoch"] != event["gateway_epoch"]
        or intent["owner_slot_index"] != event["owner_slot_index"]
        or intent["owner_generation"] != event["owner_generation"]
        or intent["attempt_generation"] != event["attempt_generation"]
        or intent["reserved_tokens"] != event["reservation_tokens"]
        or receipt["request_set_count"] != event["request_set_count"]
    ):
        raise WireError("settlement scalar binding mismatch")
    billable = receipt["usage"]["billable_tokens"]
    observed_billable = billable["value"] if billable["known"] else 0
    if observed_billable != event["billable_tokens"]:
        raise WireError("settlement billable count mismatch")


def _find_consumer(
    consumers: list[Record | None],
    owner_slot_index: int,
    owner_generation: int,
    request_sha256: Digest,
) -> int | None:
    for index, consumer in enumerate(consumers):
        if (
            consumer is not None
            and consumer["owner_slot_index"] == owner_slot_index
            and consumer["owner_generation"] == owner_generation
            and consumer["request_sha256"] == request_sha256
        ):
            return index
    return None


def _free_consumer(consumers: list[Record | None]) -> int:
    for index, consumer in enumerate(consumers):
        if consumer is None:
            return index
    raise WireError("consumer replay capacity exceeded")


def _consumer_count(
    consumers: list[Record | None],
    owner_slot_index: int,
    owner_generation: int,
    *,
    followers_only: bool = False,
) -> int:
    return sum(
        1
        for consumer in consumers
        if consumer is not None
        and consumer["owner_slot_index"] == owner_slot_index
        and consumer["owner_generation"] == owner_generation
        and (not followers_only or consumer["kind"] == "follower")
    )


def _clear_owner(
    owners: list[Record],
    consumers: list[Record | None],
    owner_slot_index: int,
) -> None:
    owner = owners[owner_slot_index]
    generation = owner["generation"]
    for index, consumer in enumerate(consumers):
        if (
            consumer is not None
            and consumer["owner_slot_index"] == owner_slot_index
            and consumer["owner_generation"] == generation
        ):
            consumers[index] = None
    owners[owner_slot_index] = _new_owner(generation)


def _new_owner(generation: int = 0) -> Record:
    return {
        "generation": generation,
        "phase": "free",
        "owner_request_sha256": bytes(32),
        "dispatch_key_sha256": bytes(32),
        "reservation_tokens": 0,
        "request_set_count": 0,
        "request_set_sha256": bytes(32),
        "next_attempt_generation": 1,
        "active_attempt_generation": 0,
        "active_intent_sha256": bytes(32),
        "terminal_usage_sha256": bytes(32),
        "terminal_result_sha256": bytes(32),
        "terminal_billable_tokens": 0,
    }


def _require_owner_common(event: Record, owner: Record, owner_request: bool) -> None:
    if (
        owner["phase"] == "free"
        or owner["generation"] != event["owner_generation"]
        or owner["reservation_tokens"] != event["reservation_tokens"]
        or owner["request_set_count"] != event["request_set_count"]
        or owner["dispatch_key_sha256"] != event["dispatch_key_sha256"]
        or owner["request_set_sha256"] != event["request_set_sha256"]
        or (
            owner_request
            and owner["owner_request_sha256"] != event["request_sha256"]
        )
    ):
        raise WireError("owner replay state drift")


def _require_attempt(event: Record, owner: Record, phase: str) -> None:
    _require_owner_common(event, owner, True)
    if (
        owner["phase"] != phase
        or owner["active_attempt_generation"] != event["attempt_generation"]
        or owner["active_intent_sha256"] != event["intent_sha256"]
    ):
        raise WireError("attempt replay state drift")


def _apply_lifecycle(
    event: Record,
    owners: list[Record],
    consumers: list[Record | None],
) -> None:
    owner_index = event["owner_slot_index"]
    if owner_index >= len(owners):
        raise WireError("owner slot outside replay storage")
    owner = owners[owner_index]
    kind = event["kind"]
    if kind == OWNER_ADMITTED:
        expected_generation = owner["generation"] + 1
        expected_root = request_set_sha256(
            bytes(32), 0, event["request_sha256"]
        )
        if (
            owner["phase"] != "free"
            or expected_generation > 0xFFFFFFFFFFFFFFFF
            or event["owner_generation"] != expected_generation
            or event["request_set_count"] != 1
            or event["request_set_sha256"] != expected_root
        ):
            raise WireError("invalid owner admission lifecycle")
        consumer_index = _free_consumer(consumers)
        owners[owner_index] = {
            **_new_owner(event["owner_generation"]),
            "phase": "ready",
            "owner_request_sha256": event["request_sha256"],
            "dispatch_key_sha256": event["dispatch_key_sha256"],
            "reservation_tokens": event["reservation_tokens"],
            "request_set_count": 1,
            "request_set_sha256": event["request_set_sha256"],
        }
        consumers[consumer_index] = {
            "owner_slot_index": owner_index,
            "owner_generation": event["owner_generation"],
            "kind": "owner",
            "request_sha256": event["request_sha256"],
        }
        return

    owner = owners[owner_index]
    if kind == FOLLOWER_COALESCED:
        if owner["phase"] not in ("ready", "dispatched"):
            raise WireError("follower coalesced into invalid owner phase")
        if (
            owner["generation"] != event["owner_generation"]
            or owner["reservation_tokens"] != event["reservation_tokens"]
            or owner["dispatch_key_sha256"] != event["dispatch_key_sha256"]
            or _find_consumer(
                consumers,
                owner_index,
                event["owner_generation"],
                event["request_sha256"],
            )
            is not None
        ):
            raise WireError("invalid follower identity")
        expected_count = owner["request_set_count"] + 1
        expected_root = request_set_sha256(
            owner["request_set_sha256"],
            owner["request_set_count"],
            event["request_sha256"],
        )
        if (
            expected_count > 0xFFFFFFFF
            or event["request_set_count"] != expected_count
            or event["request_set_sha256"] != expected_root
        ):
            raise WireError("request-set append mismatch")
        consumers[_free_consumer(consumers)] = {
            "owner_slot_index": owner_index,
            "owner_generation": event["owner_generation"],
            "kind": "follower",
            "request_sha256": event["request_sha256"],
        }
        owner["request_set_count"] = expected_count
        owner["request_set_sha256"] = expected_root
        return

    if kind == DISPATCH_STARTED:
        _require_owner_common(event, owner, True)
        if (
            owner["phase"] != "ready"
            or event["attempt_generation"] != owner["next_attempt_generation"]
        ):
            raise WireError("invalid dispatch lifecycle")
        intent = {
            "abi_version": INTENT_ABI,
            "gateway_epoch": event["gateway_epoch"],
            "owner_slot_index": owner_index,
            "owner_generation": event["owner_generation"],
            "attempt_generation": event["attempt_generation"],
            "request_sha256": event["request_sha256"],
            "dispatch_key_sha256": event["dispatch_key_sha256"],
            "reserved_tokens": event["reservation_tokens"],
            "previous_event_chain_sha256": event["previous_chain_sha256"],
        }
        intent["intent_sha256"] = settlement_wire.intent_sha256(intent)
        if event["intent_sha256"] != intent["intent_sha256"]:
            raise WireError("dispatch intent cannot be reconstructed")
        owner["phase"] = "dispatched"
        owner["active_attempt_generation"] = event["attempt_generation"]
        owner["active_intent_sha256"] = event["intent_sha256"]
        owner["next_attempt_generation"] += 1
        if owner["next_attempt_generation"] > 0xFFFFFFFFFFFFFFFF:
            raise WireError("attempt generation overflow")
        return

    if kind == RETRYABLE_NO_CHARGE:
        _require_attempt(event, owner, "dispatched")
        owner["phase"] = "ready"
        owner["active_attempt_generation"] = 0
        owner["active_intent_sha256"] = bytes(32)
        return
    if kind == AMBIGUOUS:
        _require_attempt(event, owner, "dispatched")
        owner["phase"] = "ambiguous"
        return
    if kind in (SUCCEEDED, FAILED):
        _require_attempt(event, owner, "dispatched")
        owner["phase"] = "terminal"
        owner["terminal_usage_sha256"] = event["usage_sha256"]
        owner["terminal_result_sha256"] = event["result_sha256"]
        owner["terminal_billable_tokens"] = event["billable_tokens"]
        return
    if kind in (RESOLVED_SUCCESS, RESOLVED_FAILURE):
        _require_attempt(event, owner, "ambiguous")
        owner["phase"] = "terminal"
        owner["terminal_usage_sha256"] = event["usage_sha256"]
        owner["terminal_result_sha256"] = event["result_sha256"]
        owner["terminal_billable_tokens"] = event["billable_tokens"]
        return
    if kind == FOLLOWER_CANCELLED:
        _require_owner_common(event, owner, False)
        consumer_index = _find_consumer(
            consumers,
            owner_index,
            event["owner_generation"],
            event["request_sha256"],
        )
        if consumer_index is None or consumers[consumer_index]["kind"] != "follower":
            raise WireError("cancelled consumer is not a live follower")
        if owner["phase"] == "ready":
            if event["attempt_generation"] != 0 or event["intent_sha256"] != bytes(32):
                raise WireError("ready cancellation carries an attempt")
        elif (
            event["attempt_generation"] != owner["active_attempt_generation"]
            or event["intent_sha256"] != owner["active_intent_sha256"]
        ):
            raise WireError("cancellation attempt mismatch")
        consumers[consumer_index] = None
        if (
            owner["phase"] == "terminal"
            and _consumer_count(
                consumers, owner_index, event["owner_generation"]
            )
            == 0
        ):
            _clear_owner(owners, consumers, owner_index)
        return
    if kind == OWNER_CANCELLED:
        _require_owner_common(event, owner, True)
        consumer_index = _find_consumer(
            consumers,
            owner_index,
            event["owner_generation"],
            event["request_sha256"],
        )
        if (
            owner["phase"] != "ready"
            or _consumer_count(
                consumers,
                owner_index,
                event["owner_generation"],
                followers_only=True,
            )
            != 0
            or consumer_index is None
            or consumers[consumer_index]["kind"] != "owner"
        ):
            raise WireError("invalid owner cancellation")
        consumers[consumer_index] = None
        _clear_owner(owners, consumers, owner_index)
        return
    if kind == ACKNOWLEDGED:
        _require_owner_common(event, owner, False)
        if (
            owner["phase"] != "terminal"
            or event["attempt_generation"] != owner["active_attempt_generation"]
            or event["intent_sha256"] != owner["active_intent_sha256"]
            or event["usage_sha256"] != owner["terminal_usage_sha256"]
            or event["result_sha256"] != owner["terminal_result_sha256"]
            or event["billable_tokens"] != owner["terminal_billable_tokens"]
        ):
            raise WireError("acknowledgement terminal evidence mismatch")
        consumer_index = _find_consumer(
            consumers,
            owner_index,
            event["owner_generation"],
            event["request_sha256"],
        )
        if consumer_index is None:
            raise WireError("acknowledgement has no live consumer")
        consumers[consumer_index] = None
        if (
            _consumer_count(consumers, owner_index, event["owner_generation"])
            == 0
        ):
            _clear_owner(owners, consumers, owner_index)
        return
    raise WireError("unhandled lifecycle event")


def verify_stream(
    flags: int,
    config: Record,
    owner_capacity: int,
    follower_capacity: int,
    events: list[Record],
    settlements: dict[int, Record],
    final_snapshot: Record,
) -> None:
    if flags != FLAG_REQUIRE_CLOSED or len(events) > MAX_EVENTS:
        raise WireError("event stream must be complete and closed")
    if owner_capacity + follower_capacity > MAX_REPLAY_SLOTS:
        raise WireError("replay slot capacity exceeds the wire verifier bound")
    _validate_config(config, owner_capacity)
    _u32(owner_capacity)
    _u32(follower_capacity)
    owners = [_new_owner() for _ in range(owner_capacity)]
    consumers: list[Record | None] = [
        None for _ in range(owner_capacity + follower_capacity)
    ]
    ledger = _zero_ledger()
    chain = initial_chain_sha256(config, owner_capacity, follower_capacity)
    settlement_indexes: list[int] = []
    for index, event in enumerate(events):
        _verify_event(event)
        live_owners = (
            event["after"]["ready_owners"]
            + event["after"]["dispatched_owners"]
            + event["after"]["ambiguous_owners"]
        )
        if (
            event["gateway_epoch"] != config["gateway_epoch"]
            or event["owner_slot_index"] >= owner_capacity
            or event["reservation_tokens"]
            > config["limits"]["max_request_tokens"]
            or event["request_set_count"]
            > config["limits"]["max_followers_per_owner"] + 1
            or event["after"]["reserved_tokens"]
            > config["limits"]["max_reserved_tokens"]
            or event["after"]["active_handles"]
            > owner_capacity + follower_capacity
            or live_owners > owner_capacity
            or event["sequence"] != index
            or event["before"] != ledger
            or event["previous_chain_sha256"] != chain
        ):
            raise WireError("aggregate replay state drift")
        needs_settlement = event["kind"] in SETTLEMENT_KINDS
        if needs_settlement != (index in settlements):
            raise WireError("settlement attachment presence mismatch")
        if needs_settlement:
            _settlement_matches_event(event, settlements[index])
            settlement_indexes.append(index)
        _apply_lifecycle(event, owners, consumers)
        ledger = copy.deepcopy(event["after"])
        chain = event["event_sha256"]

    if set(settlements) != set(settlement_indexes):
        raise WireError("orphan settlement attachment")
    expected_snapshot = {
        "abi_version": SNAPSHOT_ABI,
        "gateway_epoch": config["gateway_epoch"],
        "limits": config["limits"],
        "owner_capacity": owner_capacity,
        "follower_capacity": follower_capacity,
        "next_event_sequence": len(events),
        "ledger": ledger,
        "event_chain_sha256": chain,
    }
    if final_snapshot != expected_snapshot:
        raise WireError("final snapshot does not match replay")
    if any(
        ledger[name] != 0
        for name in (
            "reserved_tokens",
            "active_handles",
            "ready_owners",
            "dispatched_owners",
            "ambiguous_owners",
        )
    ):
        raise WireError("final ledger remains open")
    if any(owner["phase"] != "free" for owner in owners) or any(
        consumer is not None for consumer in consumers
    ):
        raise WireError("final lifecycle remains open")


def encoded_len(event_count: int, settlement_count: int) -> int:
    if (
        event_count < 0
        or settlement_count < 0
        or event_count > MAX_EVENTS
        or settlement_count > event_count
    ):
        raise WireError("unsupported stream cardinality")
    return (
        FIXED_WIRE_BYTES
        + event_count * EVENT_PREFIX_BYTES
        + settlement_count * settlement_wire.ENCODED_BYTES
    )


def _snapshot_bytes(snapshot: Record) -> bytes:
    return b"".join(
        (
            _u64(snapshot["abi_version"]),
            _u64(snapshot["gateway_epoch"]),
            _limits_bytes(snapshot["limits"]),
            _u32(snapshot["owner_capacity"]),
            _u32(snapshot["follower_capacity"]),
            _u64(snapshot["next_event_sequence"]),
            _ledger_bytes(snapshot["ledger"]),
            snapshot["event_chain_sha256"],
        )
    )


def encode_evidence(
    config: Record,
    owner_capacity: int,
    follower_capacity: int,
    events: list[Record],
    settlement_envelopes: dict[int, bytes],
    final_snapshot: Record,
) -> bytes:
    decoded_settlements: dict[int, Record] = {}
    previous_index = -1
    for index, encoded in settlement_envelopes.items():
        if index <= previous_index or not 0 <= index < len(events):
            raise WireError("settlement indexes must be strictly ordered")
        try:
            decoded_settlements[index] = settlement_wire.decode_and_verify(encoded)
        except settlement_wire.WireError as exc:
            raise WireError("invalid nested settlement envelope") from exc
        previous_index = index
    verify_stream(
        FLAG_REQUIRE_CLOSED,
        config,
        owner_capacity,
        follower_capacity,
        events,
        decoded_settlements,
        final_snapshot,
    )
    total = encoded_len(len(events), len(settlement_envelopes))
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(total),
            _u32(len(events)),
            _u32(FLAG_REQUIRE_CLOSED),
            _u32(owner_capacity),
            _u32(follower_capacity),
            _u32(len(settlement_envelopes)),
            _u32(0),
            _config_bytes(config),
        )
    )
    for index, event in enumerate(events):
        prefix += _event_bytes(event, include_digest=True)
        has_settlement = index in settlement_envelopes
        prefix += _u8(int(has_settlement))
        if has_settlement:
            prefix += settlement_envelopes[index]
    prefix += _snapshot_bytes(final_snapshot)
    if len(prefix) != total - 32:
        raise WireError("internal event wire length mismatch")
    return prefix + _hash(ENVELOPE_HASH_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if end > len(self.data):
            raise WireError("truncated event wire")
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


def _read_limits(reader: _Reader) -> Record:
    return {
        "max_reserved_tokens": reader.u64(),
        "max_reserved_tokens_per_isolation": reader.u64(),
        "max_request_tokens": reader.u64(),
        "max_followers_per_owner": reader.u32(),
    }


def _read_config(reader: _Reader) -> Record:
    return {
        "gateway_epoch": reader.u64(),
        "challenge": reader.digest(),
        "limits": _read_limits(reader),
    }


def _read_ledger(reader: _Reader) -> Record:
    return {name: reader.u64() for name in LEDGER_NAMES}


def _read_event(reader: _Reader) -> Record:
    event = {
        "abi_version": reader.u64(),
        "gateway_epoch": reader.u64(),
        "sequence": reader.u64(),
        "kind": reader.u8(),
        "owner_slot_index": reader.u32(),
        "owner_generation": reader.u64(),
        "attempt_generation": reader.u64(),
        "request_sha256": reader.digest(),
        "dispatch_key_sha256": reader.digest(),
        "intent_sha256": reader.digest(),
        "usage_sha256": reader.digest(),
        "result_sha256": reader.digest(),
        "request_set_count": reader.u32(),
        "request_set_sha256": reader.digest(),
        "reservation_tokens": reader.u64(),
        "billable_tokens": reader.u64(),
        "before": _read_ledger(reader),
        "after": _read_ledger(reader),
        "previous_chain_sha256": reader.digest(),
        "event_sha256": reader.digest(),
    }
    if event["kind"] not in range(12):
        raise WireError("invalid event enum")
    return event


def _read_snapshot(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "gateway_epoch": reader.u64(),
        "limits": _read_limits(reader),
        "owner_capacity": reader.u32(),
        "follower_capacity": reader.u32(),
        "next_event_sequence": reader.u64(),
        "ledger": _read_ledger(reader),
        "event_chain_sha256": reader.digest(),
    }


def decode_and_verify(encoded: bytes) -> Record:
    if len(encoded) < FIXED_WIRE_BYTES:
        raise WireError("event envelope is too short")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC:
        raise WireError("invalid event wire magic")
    if reader.u64() != WIRE_ABI:
        raise WireError("invalid event wire ABI")
    if reader.u64() != len(encoded):
        raise WireError("invalid declared event wire length")
    event_count = reader.u32()
    flags = reader.u32()
    if flags != FLAG_REQUIRE_CLOSED:
        raise WireError("event stream is not declared complete and closed")
    owner_capacity = reader.u32()
    follower_capacity = reader.u32()
    settlement_count = reader.u32()
    if reader.u32() != 0:
        raise WireError("nonzero reserved header field")
    if encoded_len(event_count, settlement_count) != len(encoded):
        raise WireError("event stream cardinality does not match length")
    prefix = encoded[:-32]
    expected_root = _hash(ENVELOPE_HASH_DOMAIN, prefix)
    if encoded[-32:] != expected_root:
        raise WireError("event envelope digest mismatch")

    config = _read_config(reader)
    events: list[Record] = []
    settlements: dict[int, Record] = {}
    for index in range(event_count):
        events.append(_read_event(reader))
        present = reader.u8()
        if present not in (0, 1):
            raise WireError("noncanonical settlement presence boolean")
        if present:
            settlement_bytes = reader.take(settlement_wire.ENCODED_BYTES)
            try:
                settlements[index] = settlement_wire.decode_and_verify(
                    settlement_bytes
                )
            except settlement_wire.WireError as exc:
                raise WireError("invalid nested settlement envelope") from exc
    if len(settlements) != settlement_count:
        raise WireError("settlement count mismatch")
    final_snapshot = _read_snapshot(reader)
    envelope_sha256 = reader.digest()
    if reader.position != len(encoded) or envelope_sha256 != expected_root:
        raise WireError("trailing data or event root drift")
    verify_stream(
        flags,
        config,
        owner_capacity,
        follower_capacity,
        events,
        settlements,
        final_snapshot,
    )
    return {
        "flags": flags,
        "config": config,
        "owner_capacity": owner_capacity,
        "follower_capacity": follower_capacity,
        "events": events,
        "settlements": settlements,
        "final_snapshot": final_snapshot,
        "envelope_sha256": envelope_sha256,
    }


def reseal_for_test(encoded: bytes) -> bytes:
    if len(encoded) < 32:
        raise WireError("event envelope is too short")
    prefix = encoded[:-32]
    return prefix + _hash(ENVELOPE_HASH_DOMAIN, prefix)


def _seed_digest(seed: int) -> Digest:
    return bytes((seed,)) * 32


def _make_request(request_key: int) -> Record:
    request: Record = {
        "abi_version": REQUEST_ABI,
        "provider_adapter_abi": 0x44454D4F41445054,
        "isolation_key": 0x44454D4F49534F4C,
        "request_key": request_key,
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
    return request


def build_demo_evidence() -> Record:
    config: Record = {
        "gateway_epoch": 0x44454D4F47570001,
        "challenge": _seed_digest(0xA5),
        "limits": {
            "max_reserved_tokens": 1_000,
            "max_reserved_tokens_per_isolation": 800,
            "max_request_tokens": 500,
            "max_followers_per_owner": 4,
        },
    }
    owner_capacity = 2
    follower_capacity = 4
    owner_request = _make_request(1)
    follower_request = _make_request(2)
    cancelled_request = _make_request(3)
    dispatch_key = settlement_wire.dispatch_key_sha256(owner_request)
    set_one = request_set_sha256(
        bytes(32), 0, owner_request["request_sha256"]
    )
    set_two = request_set_sha256(
        set_one, 1, follower_request["request_sha256"]
    )
    set_three = request_set_sha256(
        set_two, 2, cancelled_request["request_sha256"]
    )
    ledger = _zero_ledger()
    chain = initial_chain_sha256(config, owner_capacity, follower_capacity)
    events: list[Record] = []

    def emit(
        kind: int,
        request_sha256_value: Digest,
        request_count: int,
        request_root: Digest,
        after: Record,
        *,
        attempt_generation: int = 0,
        intent_sha256_value: Digest = bytes(32),
        usage_sha256_value: Digest = bytes(32),
        result_sha256_value: Digest = bytes(32),
        billable_tokens: int = 0,
    ) -> Record:
        nonlocal ledger, chain
        event: Record = {
            "abi_version": EVENT_ABI,
            "gateway_epoch": config["gateway_epoch"],
            "sequence": len(events),
            "kind": kind,
            "owner_slot_index": 0,
            "owner_generation": 1,
            "attempt_generation": attempt_generation,
            "request_sha256": request_sha256_value,
            "dispatch_key_sha256": dispatch_key,
            "intent_sha256": intent_sha256_value,
            "usage_sha256": usage_sha256_value,
            "result_sha256": result_sha256_value,
            "request_set_count": request_count,
            "request_set_sha256": request_root,
            "reservation_tokens": 150,
            "billable_tokens": billable_tokens,
            "before": copy.deepcopy(ledger),
            "after": copy.deepcopy(after),
            "previous_chain_sha256": chain,
        }
        event["event_sha256"] = event_sha256(event)
        events.append(event)
        ledger = copy.deepcopy(after)
        chain = event["event_sha256"]
        return event

    after = copy.deepcopy(ledger)
    after["reserved_tokens"] = 150
    after["active_handles"] = 1
    after["ready_owners"] = 1
    emit(OWNER_ADMITTED, owner_request["request_sha256"], 1, set_one, after)

    after = copy.deepcopy(ledger)
    after["active_handles"] += 1
    after["coalesced_requests"] += 1
    emit(
        FOLLOWER_COALESCED,
        follower_request["request_sha256"],
        2,
        set_two,
        after,
    )
    after = copy.deepcopy(ledger)
    after["active_handles"] += 1
    after["coalesced_requests"] += 1
    emit(
        FOLLOWER_COALESCED,
        cancelled_request["request_sha256"],
        3,
        set_three,
        after,
    )
    after = copy.deepcopy(ledger)
    after["active_handles"] -= 1
    after["cancelled_handles"] += 1
    after["cancelled_followers"] += 1
    emit(
        FOLLOWER_CANCELLED,
        cancelled_request["request_sha256"],
        3,
        set_three,
        after,
    )

    intent: Record = {
        "abi_version": INTENT_ABI,
        "gateway_epoch": config["gateway_epoch"],
        "owner_slot_index": 0,
        "owner_generation": 1,
        "attempt_generation": 1,
        "request_sha256": owner_request["request_sha256"],
        "dispatch_key_sha256": dispatch_key,
        "reserved_tokens": 150,
        "previous_event_chain_sha256": chain,
    }
    intent["intent_sha256"] = settlement_wire.intent_sha256(intent)
    after = copy.deepcopy(ledger)
    after["ready_owners"] -= 1
    after["dispatched_owners"] += 1
    after["physical_dispatches"] += 1
    emit(
        DISPATCH_STARTED,
        owner_request["request_sha256"],
        3,
        set_three,
        after,
        attempt_generation=1,
        intent_sha256_value=intent["intent_sha256"],
    )

    usage = settlement_wire.make_usage(100, 20, 40, 8, 0, 80)
    result_sha256_value = _seed_digest(0x77)
    after = copy.deepcopy(ledger)
    after["reserved_tokens"] -= 150
    after["settled_billable_tokens"] += 80
    after["dispatched_owners"] -= 1
    after["successful_dispatches"] += 1
    settlement_event = emit(
        SUCCEEDED,
        owner_request["request_sha256"],
        3,
        set_three,
        after,
        attempt_generation=1,
        intent_sha256_value=intent["intent_sha256"],
        usage_sha256_value=usage["usage_sha256"],
        result_sha256_value=result_sha256_value,
        billable_tokens=80,
    )
    receipt: Record = {
        "abi_version": RECEIPT_ABI,
        "outcome": settlement_wire.SUCCEEDED,
        "intent": intent,
        "usage": usage,
        "result_sha256": result_sha256_value,
        "request_set_count": 3,
        "request_set_sha256": set_three,
        "event_sha256": settlement_event["event_sha256"],
    }
    receipt["receipt_sha256"] = settlement_wire.receipt_sha256(receipt)
    settlement_envelope = settlement_wire.encode_evidence(owner_request, receipt)

    after = copy.deepcopy(ledger)
    after["active_handles"] -= 1
    after["acknowledged_handles"] += 1
    emit(
        ACKNOWLEDGED,
        follower_request["request_sha256"],
        3,
        set_three,
        after,
        attempt_generation=1,
        intent_sha256_value=intent["intent_sha256"],
        usage_sha256_value=usage["usage_sha256"],
        result_sha256_value=result_sha256_value,
        billable_tokens=80,
    )
    after = copy.deepcopy(ledger)
    after["active_handles"] -= 1
    after["acknowledged_handles"] += 1
    emit(
        ACKNOWLEDGED,
        owner_request["request_sha256"],
        3,
        set_three,
        after,
        attempt_generation=1,
        intent_sha256_value=intent["intent_sha256"],
        usage_sha256_value=usage["usage_sha256"],
        result_sha256_value=result_sha256_value,
        billable_tokens=80,
    )

    final_snapshot: Record = {
        "abi_version": SNAPSHOT_ABI,
        "gateway_epoch": config["gateway_epoch"],
        "limits": config["limits"],
        "owner_capacity": owner_capacity,
        "follower_capacity": follower_capacity,
        "next_event_sequence": len(events),
        "ledger": ledger,
        "event_chain_sha256": chain,
    }
    return {
        "config": config,
        "owner_capacity": owner_capacity,
        "follower_capacity": follower_capacity,
        "events": events,
        "settlement_envelopes": {5: settlement_envelope},
        "final_snapshot": final_snapshot,
    }
