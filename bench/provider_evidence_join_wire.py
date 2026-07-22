"""Independent codec and verifier for provider evidence join wire v1."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import provider_cost_journal as cost_journal
from bench import provider_cost_wire as cost_wire
from bench import provider_gateway_event_wire as gateway_wire
from bench import provider_settlement_wire as settlement_wire
from bench import provider_transport_event_wire as transport_wire


class WireError(ValueError):
    """The joined provider histories are invalid or do not compose."""


Digest = bytes
Record = dict[str, Any]

MAGIC = b"GPJOINR1"
WIRE_ABI = 0x47504A4F00000001
FLAG_REQUIRE_CLOSED = 1
HEADER_BYTES = 72
DIGEST_FIELD_COUNT = 20
ENCODED_BYTES = HEADER_BYTES + DIGEST_FIELD_COUNT * 32
ENVELOPE_DOMAIN = b"glacier-provider-evidence-join-wire-v1\x00"

DIGEST_NAMES = (
    "journal_header_sha256",
    "journal_previous_chain_sha256",
    "journal_entry_sha256",
    "cost_envelope_sha256",
    "settlement_envelope_sha256",
    "request_sha256",
    "dispatch_key_sha256",
    "intent_sha256",
    "receipt_sha256",
    "price_sha256",
    "quote_sha256",
    "cost_settlement_sha256",
    "gateway_envelope_sha256",
    "gateway_event_sha256",
    "gateway_final_chain_sha256",
    "transport_envelope_sha256",
    "provider_request_sha256",
    "response_chain_sha256",
    "transport_outcome_sha256",
)


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


def _digest(value: bytes) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32 or value == bytes(32):
        raise WireError("invalid digest")
    return value


def _terminal_roots(events: list[Record]) -> tuple[Digest, Digest, Digest]:
    terminal: Record | None = None
    for event in events:
        if event["kind"] == transport_wire.OUTCOME:
            candidate = event["outcome"]
        elif event["kind"] == transport_wire.CANCEL_OUTCOME:
            candidate = event["cancel_outcome"]
        else:
            continue
        if terminal is not None:
            raise WireError("multiple transport terminal outcomes")
        terminal = candidate
    if terminal is None:
        raise WireError("missing transport terminal outcome")
    return (
        terminal["provider_request_sha256"],
        terminal["response_chain_sha256"],
        terminal["outcome_sha256"],
    )


def _compose(
    header: Record,
    journal_sequence: int,
    journal_previous_chain_sha256: Digest,
    encoded_frame: bytes,
    gateway_event_index: int,
    encoded_gateway: bytes,
    encoded_transport: bytes,
) -> Record:
    if journal_sequence == 0:
        raise WireError("zero journal sequence")
    _u64(journal_sequence)
    _digest(journal_previous_chain_sha256)
    if (
        journal_sequence == 1
        and journal_previous_chain_sha256 != header.get("header_sha256")
    ):
        raise WireError("first journal frame does not follow the header")
    try:
        cost_journal._verify_header(header)  # noqa: SLF001
        frame = cost_journal._decode_frame(  # noqa: SLF001
            header,
            journal_sequence,
            journal_previous_chain_sha256,
            encoded_frame,
        )
        gateway = gateway_wire.decode_and_verify(encoded_gateway)
        transport = transport_wire.decode_and_verify(encoded_transport)
    except (
        cost_journal.JournalError,
        gateway_wire.WireError,
        transport_wire.WireError,
    ) as exc:
        raise WireError("invalid nested evidence") from exc

    if not 0 <= gateway_event_index < len(gateway["events"]):
        raise WireError("Gateway event index is outside the closed stream")
    selected = gateway["settlements"].get(gateway_event_index)
    if selected is None:
        raise WireError("selected Gateway event has no settlement")
    cost = frame["cost"]
    settlement = cost["provider_settlement"]
    if settlement != selected or settlement != transport["settlement"]:
        raise WireError("settlement substitution across histories")
    provider_root, response_root, outcome_root = _terminal_roots(
        transport["events"]
    )
    receipt = settlement["receipt"]
    value = {
        "flags": FLAG_REQUIRE_CLOSED,
        "journal_sequence": journal_sequence,
        "gateway_event_index": gateway_event_index,
        "transport_event_count": len(transport["events"]),
        "journal_frame_bytes": len(encoded_frame),
        "gateway_wire_bytes": len(encoded_gateway),
        "transport_wire_bytes": len(encoded_transport),
        "journal_header_sha256": header["header_sha256"],
        "journal_previous_chain_sha256": journal_previous_chain_sha256,
        "journal_entry_sha256": frame["entry_sha256"],
        "cost_envelope_sha256": cost["envelope_sha256"],
        "settlement_envelope_sha256": settlement["envelope_sha256"],
        "request_sha256": settlement["request"]["request_sha256"],
        "dispatch_key_sha256": receipt["intent"]["dispatch_key_sha256"],
        "intent_sha256": receipt["intent"]["intent_sha256"],
        "receipt_sha256": receipt["receipt_sha256"],
        "price_sha256": cost["price"]["price_sha256"],
        "quote_sha256": cost["quote"]["quote_sha256"],
        "cost_settlement_sha256": cost["cost_settlement"][
            "settlement_sha256"
        ],
        "gateway_envelope_sha256": gateway["envelope_sha256"],
        "gateway_event_sha256": gateway["events"][gateway_event_index][
            "event_sha256"
        ],
        "gateway_final_chain_sha256": gateway["final_snapshot"][
            "event_chain_sha256"
        ],
        "transport_envelope_sha256": transport["envelope_sha256"],
        "provider_request_sha256": provider_root,
        "response_chain_sha256": response_root,
        "transport_outcome_sha256": outcome_root,
    }
    for name in DIGEST_NAMES:
        _digest(value[name])
    return value


def _encode_value(value: Record) -> bytes:
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(ENCODED_BYTES),
            _u32(value["flags"]),
            _u32(0),
            _u64(value["journal_sequence"]),
            _u32(value["gateway_event_index"]),
            _u32(value["transport_event_count"]),
            _u64(value["journal_frame_bytes"]),
            _u64(value["gateway_wire_bytes"]),
            _u64(value["transport_wire_bytes"]),
            *(value[name] for name in DIGEST_NAMES),
        )
    )
    if len(prefix) != ENCODED_BYTES - 32:
        raise WireError("internal join length mismatch")
    return prefix + _hash(ENVELOPE_DOMAIN, prefix)


def encode_evidence(
    header: Record,
    journal_sequence: int,
    journal_previous_chain_sha256: Digest,
    encoded_frame: bytes,
    gateway_event_index: int,
    encoded_gateway: bytes,
    encoded_transport: bytes,
) -> bytes:
    """Replay all nested evidence and encode its canonical root manifest."""
    value = _compose(
        header,
        journal_sequence,
        journal_previous_chain_sha256,
        encoded_frame,
        gateway_event_index,
        encoded_gateway,
        encoded_transport,
    )
    return _encode_value(value)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if end > len(self.data):
            raise WireError("truncated join wire")
        value = self.data[self.position : end]
        self.position = end
        return value

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> Digest:
        return self.take(32)


def decode_and_verify(
    encoded: bytes,
    header: Record,
    encoded_frame: bytes,
    encoded_gateway: bytes,
    encoded_transport: bytes,
) -> Record:
    """Verify the envelope, replay every external blob, then compare bytes."""
    if len(encoded) != ENCODED_BYTES:
        raise WireError("invalid join wire length")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC or reader.u64() != WIRE_ABI:
        raise WireError("invalid join magic or ABI")
    if reader.u64() != ENCODED_BYTES:
        raise WireError("invalid declared join length")
    value: Record = {"flags": reader.u32()}
    if value["flags"] != FLAG_REQUIRE_CLOSED or reader.u32() != 0:
        raise WireError("invalid join flags")
    value.update(
        {
            "journal_sequence": reader.u64(),
            "gateway_event_index": reader.u32(),
            "transport_event_count": reader.u32(),
            "journal_frame_bytes": reader.u64(),
            "gateway_wire_bytes": reader.u64(),
            "transport_wire_bytes": reader.u64(),
        }
    )
    for name in DIGEST_NAMES:
        value[name] = reader.digest()
    value["envelope_sha256"] = reader.digest()
    expected_root = _hash(ENVELOPE_DOMAIN, encoded[:-32])
    if reader.position != len(encoded) or value["envelope_sha256"] != expected_root:
        raise WireError("join envelope digest mismatch")
    expected = encode_evidence(
        header,
        value["journal_sequence"],
        value["journal_previous_chain_sha256"],
        encoded_frame,
        value["gateway_event_index"],
        encoded_gateway,
        encoded_transport,
    )
    if encoded != expected:
        raise WireError("joined histories do not match the manifest")
    return value


def reseal_for_test(encoded: bytes) -> bytes:
    if len(encoded) != ENCODED_BYTES:
        raise WireError("invalid join wire length")
    return encoded[:-32] + _hash(ENVELOPE_DOMAIN, encoded[:-32])


def _seed_digest(seed: int) -> Digest:
    return bytes((seed,)) * 32


def build_demo_transport(
    settlement: Record,
    settlement_envelope: bytes,
    *,
    chunk_seed: int = 0x61,
) -> bytes:
    """Build the normal terminal transport used by the cross-language join."""
    intent = settlement["receipt"]["intent"]
    descriptor: Record = {
        "abi_version": transport_wire.DESCRIPTOR_ABI,
        "transport_adapter_abi": settlement["request"]["provider_adapter_abi"],
        "provider_namespace_sha256": _seed_digest(0x91),
        "capability_bits": transport_wire.REQUIRED_CAPABILITIES,
    }
    descriptor["descriptor_sha256"] = transport_wire.descriptor_sha256(
        descriptor
    )
    config: Record = {
        "harness_epoch": 0x4A4F494E54520001,
        "challenge": _seed_digest(0xA6),
        "max_chunks_per_attempt": 8,
        "descriptor": descriptor,
    }
    script: Record = {
        "abi_version": transport_wire.SCRIPT_ABI,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "provider_request_sha256": transport_wire.provider_request_sha256(
            descriptor, intent
        ),
        "chunk_seed_sha256": _seed_digest(chunk_seed),
        "chunk_count": 3,
        "terminal_mode": transport_wire.SUCCEEDED,
        "usage": settlement["receipt"]["usage"],
        "result_sha256": settlement["receipt"]["result_sha256"],
    }
    script["script_sha256"] = transport_wire.script_sha256(script)
    events: list[Record] = []
    for index in range(script["chunk_count"]):
        payload = transport_wire.chunk_sha256(script, index)
        before = transport_wire.response_sha256(script, index)
        chunk: Record = {
            "abi_version": transport_wire.CHUNK_ABI,
            "intent_sha256": intent["intent_sha256"],
            "provider_request_sha256": script["provider_request_sha256"],
            "script_sha256": script["script_sha256"],
            "chunk_index": index,
            "chunk_count": script["chunk_count"],
            "before_chain_sha256": before,
            "chunk_sha256": payload,
            "after_chain_sha256": transport_wire.append_response_sha256(
                before, index, payload
            ),
        }
        chunk["evidence_sha256"] = transport_wire.chunk_evidence_sha256(chunk)
        events.append({"kind": transport_wire.CHUNK, "chunk": chunk})
    outcome: Record = {
        "abi_version": transport_wire.OUTCOME_ABI,
        "kind": transport_wire.SUCCEEDED,
        "intent": intent,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "provider_request_sha256": script["provider_request_sha256"],
        "script_sha256": script["script_sha256"],
        "emitted_chunks": script["chunk_count"],
        "response_chain_sha256": transport_wire.response_sha256(
            script, script["chunk_count"]
        ),
        "usage": script["usage"],
        "result_sha256": script["result_sha256"],
    }
    outcome["outcome_sha256"] = transport_wire.outcome_sha256(outcome)
    events.append({"kind": transport_wire.OUTCOME, "outcome": outcome})
    ledger = transport_wire._zero_ledger(  # noqa: SLF001
        transport_wire.LEDGER_NAMES
    )
    ledger.update(
        {
            "started_attempts": 1,
            "emitted_chunks": 3,
            "successful_outcomes": 1,
            "acknowledged_attempts": 1,
        }
    )
    evidence: Record = {
        "flags": transport_wire.FLAG_REQUIRE_CLOSED,
        "config": config,
        "slot_capacity": 1,
        "intent": intent,
        "script": script,
        "events": events,
        "settlement": settlement,
        "settlement_envelope": settlement_envelope,
        "final_snapshot": {
            "abi_version": transport_wire.SNAPSHOT_ABI,
            "harness_epoch": config["harness_epoch"],
            "slot_capacity": 1,
            "max_chunks_per_attempt": config["max_chunks_per_attempt"],
            "ledger": ledger,
        },
        "final_cancel_snapshot": {
            "abi_version": transport_wire.CANCEL_SNAPSHOT_ABI,
            "harness_epoch": config["harness_epoch"],
            "ledger": transport_wire._zero_ledger(  # noqa: SLF001
                transport_wire.CANCEL_LEDGER_NAMES
            ),
        },
    }
    return transport_wire.encode_evidence(evidence)


def build_demo_bundle() -> Record:
    """Construct every independently encoded blob used by the Zig demo."""
    gateway_fixture = gateway_wire.build_demo_evidence()
    encoded_gateway = gateway_wire.encode_evidence(
        gateway_fixture["config"],
        gateway_fixture["owner_capacity"],
        gateway_fixture["follower_capacity"],
        gateway_fixture["events"],
        gateway_fixture["settlement_envelopes"],
        gateway_fixture["final_snapshot"],
    )
    settlement_envelope = gateway_fixture["settlement_envelopes"][5]
    settlement = settlement_wire.decode_and_verify(settlement_envelope)
    encoded_transport = build_demo_transport(settlement, settlement_envelope)
    request = settlement["request"]
    price = cost_wire.make_price_table(
        request["provider_adapter_abi"],
        _seed_digest(0xA1),
        request["model_sha256"],
        17,
        1_700_000_000,
        1_700_001_000,
        b"USD",
        cost_wire.PER_COMPONENT_CEILING,
        cost_wire.REASONING_WITHIN_OUTPUT,
        cost_wire.RETRY_INCLUDED,
        {
            "uncached_input": cost_wire.known(2_000_000_000),
            "cached_input": cost_wire.known(500_000_000),
            "visible_output": cost_wire.known(8_000_000_000),
            "reasoning": cost_wire.known(10_000_000_000),
            "retry": cost_wire.known(0),
        },
    )
    quote = cost_wire.make_quote(price, request, 1_700_000_100)
    cost_settlement = cost_wire.make_cost_settlement(
        price, quote, settlement, 1_700_000_200
    )
    cost_evidence: Record = {
        "flags": cost_wire.FLAG_REQUIRE_KNOWN_QUOTE,
        "price": price,
        "quote": quote,
        "provider_settlement": settlement,
        "provider_settlement_envelope": settlement_envelope,
        "cost_settlement": cost_settlement,
    }
    encoded_cost = cost_wire.encode_evidence(cost_evidence)
    header = cost_journal.make_header(
        0x4A4F55524E414C01,
        _seed_digest(0xB1),
        b"USD",
        _seed_digest(0xC1),
    )
    encoded_frame = cost_journal.encode_frame(
        header, 1, header["header_sha256"], encoded_cost
    )
    encoded_join = encode_evidence(
        header,
        1,
        header["header_sha256"],
        encoded_frame,
        5,
        encoded_gateway,
        encoded_transport,
    )
    return {
        "header": header,
        "frame": encoded_frame,
        "gateway": encoded_gateway,
        "transport": encoded_transport,
        "join": encoded_join,
        "settlement": settlement,
        "settlement_envelope": settlement_envelope,
    }
