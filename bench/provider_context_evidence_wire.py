"""Independent Python codec/verifier for provider-context evidence wire v1."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class WireError(ValueError):
    """The canonical envelope or one of its semantic commitments is invalid."""


Digest = bytes
Record = dict[str, Any]

MAGIC = b"GPCWIRE1"
WIRE_ABI = 0x4750435A00000001
FLAGS_NONE = 0
MAX_SPANS = 4096
MAX_WIRE_BYTES = 16 * 1024 * 1024
HEADER_BYTES = 40
FIXED_WIRE_BYTES = 1526

DOMAIN_ABI = 0x4750434400000001
POLICY_ABI = 0x4750435000000001
SPAN_ABI = 0x4750435300000001
DECISION_ABI = 0x4750434500000001
RECEIPT_ABI = 0x4750435200000001
TOKEN_OBSERVATION_ABI = 0x4750435400000001
RECONCILIATION_ABI = 0x4750435800000001
DESCRIPTOR_ABI = 0x4750434100000001
EXECUTION_ABI = 0x4750435700000001

REQUIRED_CAPABILITIES = 0x0F

DOMAIN_HASH_DOMAIN = b"glacier-provider-context-domain-v1\x00"
POLICY_HASH_DOMAIN = b"glacier-provider-context-policy-v1\x00"
SPAN_HASH_DOMAIN = b"glacier-provider-context-span-v1\x00"
DECISION_HASH_DOMAIN = b"glacier-provider-context-decision-v1\x00"
MAPPING_INITIAL_DOMAIN = b"glacier-provider-context-mapping-v1\x00"
MAPPING_APPEND_DOMAIN = b"glacier-provider-context-mapping-append-v1\x00"
EMITTED_INITIAL_DOMAIN = b"glacier-provider-context-emitted-v1\x00"
EMITTED_APPEND_DOMAIN = b"glacier-provider-context-emitted-append-v1\x00"
RECEIPT_HASH_DOMAIN = b"glacier-provider-context-receipt-v1\x00"
OBSERVATION_HASH_DOMAIN = b"glacier-provider-context-token-observation-v1\x00"
RECONCILIATION_HASH_DOMAIN = (
    b"glacier-provider-context-token-reconciliation-v1\x00"
)
DESCRIPTOR_HASH_DOMAIN = b"glacier-provider-context-adapter-v1\x00"
EXECUTION_HASH_DOMAIN = b"glacier-provider-context-wire-execution-v1\x00"
ENVELOPE_HASH_DOMAIN = b"glacier-provider-context-evidence-wire-v1\x00"


def _sha256(value: bytes) -> Digest:
    return hashlib.sha256(value).digest()


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


def _digest(value: bytes) -> Digest:
    if len(value) != 32 or value == bytes(32):
        raise WireError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _domain_hash(value: Record) -> Digest:
    return _hash(
        DOMAIN_HASH_DOMAIN,
        _u64(value["abi_version"]),
        _u64(value["isolation_key"]),
        _u64(value["adapter_abi"]),
        value["provider_namespace_sha256"],
        value["model_sha256"],
        value["tokenizer_sha256"],
        value["render_policy_sha256"],
    )


def _policy_hash(value: Record) -> Digest:
    return _hash(
        POLICY_HASH_DOMAIN,
        _u64(value["abi_version"]),
        _u32(value["max_spans"]),
        _u64(value["max_input_tokens"]),
        _u64(value["fixed_overhead_tokens"]),
    )


def _span_hash(value: Record) -> Digest:
    return _hash(
        SPAN_HASH_DOMAIN,
        _u64(value["abi_version"]),
        _u32(value["sequence"]),
        _u8(value["kind"]),
        _u8(value["reuse_mode"]),
        _u8(value["retention"]),
        value["content_sha256"],
        value["rendered_sha256"],
        value["provenance_sha256"],
        _u64(value["token_count"]),
    )


def _decision_hash(value: Record) -> Digest:
    return _hash(
        DECISION_HASH_DOMAIN,
        _u64(value["abi_version"]),
        _u32(value["sequence"]),
        _u8(value["action"]),
        value["span_sha256"],
        _u32(value["representative_sequence"]),
        value["representative_span_sha256"],
        _u64(value["logical_tokens"]),
        _u64(value["emitted_tokens"]),
    )


def _receipt_hash(value: Record) -> Digest:
    return _hash(
        RECEIPT_HASH_DOMAIN,
        _u64(value["abi_version"]),
        value["domain_sha256"],
        value["policy_sha256"],
        _u32(value["input_spans"]),
        _u32(value["emitted_spans"]),
        _u32(value["aliased_spans"]),
        _u32(value["required_spans"]),
        _u64(value["logical_tokens"]),
        _u64(value["emitted_tokens"]),
        _u64(value["deduplicated_tokens"]),
        value["mapping_chain_sha256"],
        value["emitted_chain_sha256"],
    )


def _observation_hash(value: Record) -> Digest:
    return _hash(
        OBSERVATION_HASH_DOMAIN,
        _u64(value["abi_version"]),
        _u8(value["arm"]),
        value["domain_sha256"],
        value["context_chain_sha256"],
        value["wire_sha256"],
        value["tokenizer_execution_sha256"],
        _u64(value["wire_tokens"]),
    )


def _reconciliation_hash(value: Record) -> Digest:
    return _hash(
        RECONCILIATION_HASH_DOMAIN,
        _u64(value["abi_version"]),
        value["domain_sha256"],
        value["policy_sha256"],
        value["receipt_sha256"],
        value["raw_observation_sha256"],
        value["packed_observation_sha256"],
        value["tokenizer_execution_sha256"],
        _u64(value["raw_wire_tokens"]),
        _u64(value["packed_wire_tokens"]),
        _u64(value["wire_deduplicated_tokens"]),
        _u64(value["max_input_tokens"]),
        _u64(value["packed_budget_headroom"]),
    )


def _descriptor_hash(value: Record) -> Digest:
    return _hash(
        DESCRIPTOR_HASH_DOMAIN,
        _u64(value["abi_version"]),
        _u64(value["adapter_abi"]),
        value["provider_namespace_sha256"],
        value["tokenizer_sha256"],
        value["render_policy_sha256"],
        _u64(value["capability_bits"]),
        _u64(value["max_wire_bytes"]),
    )


def _execution_hash(value: Record) -> Digest:
    return _hash(
        EXECUTION_HASH_DOMAIN,
        _u64(value["abi_version"]),
        value["descriptor_sha256"],
        value["domain_sha256"],
        value["policy_sha256"],
        value["pack_receipt_sha256"],
        value["render_execution_sha256"],
        _u64(value["raw_wire_bytes"]),
        _u64(value["packed_wire_bytes"]),
        value["raw_observation"]["observation_sha256"],
        value["packed_observation"]["observation_sha256"],
        value["reconciliation"]["reconciliation_sha256"],
    )


def make_domain(
    isolation_key: int,
    adapter_abi: int,
    provider: Digest,
    model: Digest,
    tokenizer: Digest,
    render_policy: Digest,
) -> Record:
    value = {
        "abi_version": DOMAIN_ABI,
        "isolation_key": isolation_key,
        "adapter_abi": adapter_abi,
        "provider_namespace_sha256": _digest(provider),
        "model_sha256": _digest(model),
        "tokenizer_sha256": _digest(tokenizer),
        "render_policy_sha256": _digest(render_policy),
    }
    value["domain_sha256"] = _domain_hash(value)
    return value


def make_policy(max_spans: int, max_input_tokens: int, overhead: int) -> Record:
    if not 0 < max_spans <= MAX_SPANS or not 0 <= overhead <= max_input_tokens:
        raise WireError("invalid policy")
    value = {
        "abi_version": POLICY_ABI,
        "max_spans": max_spans,
        "max_input_tokens": max_input_tokens,
        "fixed_overhead_tokens": overhead,
    }
    value["policy_sha256"] = _policy_hash(value)
    return value


def make_span(
    sequence: int,
    kind: int,
    reuse_mode: int,
    retention: int,
    content: Digest,
    rendered: Digest,
    provenance: Digest,
    tokens: int,
) -> Record:
    if kind not in range(5) or reuse_mode not in range(2) or retention not in range(2):
        raise WireError("invalid span enum")
    value = {
        "abi_version": SPAN_ABI,
        "sequence": sequence,
        "kind": kind,
        "reuse_mode": reuse_mode,
        "retention": retention,
        "content_sha256": _digest(content),
        "rendered_sha256": _digest(rendered),
        "provenance_sha256": _digest(provenance),
        "token_count": tokens,
    }
    value["span_sha256"] = _span_hash(value)
    return value


def _representative(spans: list[Record], index: int) -> int:
    span = spans[index]
    if span["reuse_mode"] == 0:
        return index
    for candidate_index, candidate in enumerate(spans[:index]):
        if (
            candidate["reuse_mode"] == 1
            and candidate["kind"] == span["kind"]
            and candidate["content_sha256"] == span["content_sha256"]
            and candidate["rendered_sha256"] == span["rendered_sha256"]
        ):
            if candidate["token_count"] != span["token_count"]:
                raise WireError("tokenization conflict")
            return candidate_index
    return index


def make_pack(
    domain: Record,
    policy: Record,
    spans: list[Record],
) -> tuple[list[Record], Record]:
    if len(spans) > policy["max_spans"]:
        raise WireError("span capacity exceeded")
    logical_tokens = policy["fixed_overhead_tokens"]
    emitted_tokens = policy["fixed_overhead_tokens"]
    emitted_spans = 0
    required_spans = 0
    mapping = _hash(
        MAPPING_INITIAL_DOMAIN,
        domain["domain_sha256"],
        policy["policy_sha256"],
        _u32(len(spans)),
    )
    emitted = _hash(
        EMITTED_INITIAL_DOMAIN,
        domain["domain_sha256"],
        policy["policy_sha256"],
    )
    decisions: list[Record] = []
    for index, span in enumerate(spans):
        for name in (
            "content_sha256",
            "rendered_sha256",
            "provenance_sha256",
        ):
            _digest(span[name])
        if (
            span["abi_version"] != SPAN_ABI
            or span["sequence"] != index
            or span["kind"] not in range(5)
            or span["reuse_mode"] not in range(2)
            or span["retention"] not in range(2)
            or span["span_sha256"] != _span_hash(span)
        ):
            raise WireError("invalid span")
        representative = _representative(spans, index)
        action = 0 if representative == index else 1
        decision = {
            "abi_version": DECISION_ABI,
            "sequence": index,
            "action": action,
            "span_sha256": span["span_sha256"],
            "representative_sequence": representative,
            "representative_span_sha256": spans[representative]["span_sha256"],
            "logical_tokens": span["token_count"],
            "emitted_tokens": span["token_count"] if action == 0 else 0,
        }
        decision["decision_sha256"] = _decision_hash(decision)
        decisions.append(decision)
        logical_tokens += span["token_count"]
        mapping = _hash(
            MAPPING_APPEND_DOMAIN,
            mapping,
            decision["decision_sha256"],
        )
        if action == 0:
            emitted_spans += 1
            emitted_tokens += span["token_count"]
            emitted = _hash(
                EMITTED_APPEND_DOMAIN,
                emitted,
                decision["representative_span_sha256"],
                _u64(decision["emitted_tokens"]),
            )
        if span["retention"] == 0:
            required_spans += 1
    if emitted_tokens > policy["max_input_tokens"]:
        raise WireError("packed context exceeds policy")
    receipt = {
        "abi_version": RECEIPT_ABI,
        "domain_sha256": domain["domain_sha256"],
        "policy_sha256": policy["policy_sha256"],
        "input_spans": len(spans),
        "emitted_spans": emitted_spans,
        "aliased_spans": len(spans) - emitted_spans,
        "required_spans": required_spans,
        "logical_tokens": logical_tokens,
        "emitted_tokens": emitted_tokens,
        "deduplicated_tokens": logical_tokens - emitted_tokens,
        "mapping_chain_sha256": mapping,
        "emitted_chain_sha256": emitted,
    }
    receipt["receipt_sha256"] = _receipt_hash(receipt)
    return decisions, receipt


def make_descriptor(
    adapter_abi: int,
    provider: Digest,
    tokenizer: Digest,
    render_policy: Digest,
    capability_bits: int,
    max_wire_bytes: int,
) -> Record:
    value = {
        "abi_version": DESCRIPTOR_ABI,
        "adapter_abi": adapter_abi,
        "provider_namespace_sha256": _digest(provider),
        "tokenizer_sha256": _digest(tokenizer),
        "render_policy_sha256": _digest(render_policy),
        "capability_bits": capability_bits,
        "max_wire_bytes": max_wire_bytes,
    }
    value["descriptor_sha256"] = _descriptor_hash(value)
    return value


def make_observation(
    domain: Record,
    receipt: Record,
    arm: int,
    wire_sha256: Digest,
    tokenizer_execution_sha256: Digest,
    wire_tokens: int,
) -> Record:
    if arm not in (0, 1):
        raise WireError("invalid observation arm")
    value = {
        "abi_version": TOKEN_OBSERVATION_ABI,
        "arm": arm,
        "domain_sha256": domain["domain_sha256"],
        "context_chain_sha256": (
            receipt["mapping_chain_sha256"]
            if arm == 0
            else receipt["emitted_chain_sha256"]
        ),
        "wire_sha256": _digest(wire_sha256),
        "tokenizer_execution_sha256": _digest(tokenizer_execution_sha256),
        "wire_tokens": wire_tokens,
    }
    value["observation_sha256"] = _observation_hash(value)
    return value


def make_reconciliation(
    domain: Record,
    policy: Record,
    receipt: Record,
    raw: Record,
    packed: Record,
) -> Record:
    if (
        raw["arm"] != 0
        or packed["arm"] != 1
        or raw["tokenizer_execution_sha256"]
        != packed["tokenizer_execution_sha256"]
        or raw["wire_tokens"] != receipt["logical_tokens"]
        or packed["wire_tokens"] != receipt["emitted_tokens"]
    ):
        raise WireError("invalid observation pair")
    deduplicated = raw["wire_tokens"] - packed["wire_tokens"]
    headroom = policy["max_input_tokens"] - packed["wire_tokens"]
    if deduplicated != receipt["deduplicated_tokens"] or headroom < 0:
        raise WireError("invalid reconciliation totals")
    value = {
        "abi_version": RECONCILIATION_ABI,
        "domain_sha256": domain["domain_sha256"],
        "policy_sha256": policy["policy_sha256"],
        "receipt_sha256": receipt["receipt_sha256"],
        "raw_observation_sha256": raw["observation_sha256"],
        "packed_observation_sha256": packed["observation_sha256"],
        "tokenizer_execution_sha256": raw["tokenizer_execution_sha256"],
        "raw_wire_tokens": raw["wire_tokens"],
        "packed_wire_tokens": packed["wire_tokens"],
        "wire_deduplicated_tokens": deduplicated,
        "max_input_tokens": policy["max_input_tokens"],
        "packed_budget_headroom": headroom,
    }
    value["reconciliation_sha256"] = _reconciliation_hash(value)
    return value


def make_execution(
    descriptor: Record,
    domain: Record,
    policy: Record,
    receipt: Record,
    render_execution_sha256: Digest,
    raw_wire_bytes: int,
    packed_wire_bytes: int,
    raw_observation: Record,
    packed_observation: Record,
    reconciliation: Record,
) -> Record:
    value = {
        "abi_version": EXECUTION_ABI,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "domain_sha256": domain["domain_sha256"],
        "policy_sha256": policy["policy_sha256"],
        "pack_receipt_sha256": receipt["receipt_sha256"],
        "render_execution_sha256": _digest(render_execution_sha256),
        "raw_wire_bytes": raw_wire_bytes,
        "packed_wire_bytes": packed_wire_bytes,
        "raw_observation": raw_observation,
        "packed_observation": packed_observation,
        "reconciliation": reconciliation,
    }
    value["execution_sha256"] = _execution_hash(value)
    return value


def verify_evidence(value: Record) -> None:
    descriptor = value["descriptor"]
    domain = value["domain"]
    policy = value["policy"]
    spans = value["spans"]
    decisions = value["decisions"]
    receipt = value["receipt"]
    execution = value["execution"]
    packed_wire = value["packed_wire"]

    for name in (
        "provider_namespace_sha256",
        "tokenizer_sha256",
        "render_policy_sha256",
    ):
        _digest(descriptor[name])
    if (
        descriptor["abi_version"] != DESCRIPTOR_ABI
        or descriptor["descriptor_sha256"] != _descriptor_hash(descriptor)
        or descriptor["adapter_abi"] == 0
        or descriptor["capability_bits"] & REQUIRED_CAPABILITIES
        != REQUIRED_CAPABILITIES
        or not 0 < descriptor["max_wire_bytes"] <= MAX_WIRE_BYTES
    ):
        raise WireError("invalid descriptor")
    for name in (
        "provider_namespace_sha256",
        "model_sha256",
        "tokenizer_sha256",
        "render_policy_sha256",
    ):
        _digest(domain[name])
    if (
        domain["abi_version"] != DOMAIN_ABI
        or domain["domain_sha256"] != _domain_hash(domain)
        or domain["isolation_key"] == 0
        or domain["adapter_abi"] == 0
    ):
        raise WireError("invalid domain")
    if (
        policy["abi_version"] != POLICY_ABI
        or policy["policy_sha256"] != _policy_hash(policy)
        or not 0 < policy["max_spans"] <= MAX_SPANS
        or policy["max_input_tokens"] == 0
        or not 0 <= policy["fixed_overhead_tokens"]
        <= policy["max_input_tokens"]
    ):
        raise WireError("invalid policy")
    if (
        descriptor["adapter_abi"] != domain["adapter_abi"]
        or descriptor["provider_namespace_sha256"]
        != domain["provider_namespace_sha256"]
        or descriptor["tokenizer_sha256"] != domain["tokenizer_sha256"]
        or descriptor["render_policy_sha256"]
        != domain["render_policy_sha256"]
    ):
        raise WireError("descriptor/domain mismatch")
    expected_decisions, expected_receipt = make_pack(domain, policy, spans)
    if decisions != expected_decisions or receipt != expected_receipt:
        raise WireError("invalid pack evidence")

    raw = execution["raw_observation"]
    packed = execution["packed_observation"]
    expected_raw = make_observation(
        domain,
        receipt,
        0,
        raw["wire_sha256"],
        raw["tokenizer_execution_sha256"],
        raw["wire_tokens"],
    )
    if _sha256(packed_wire) != packed["wire_sha256"]:
        raise WireError("packed wire digest mismatch")
    expected_packed = make_observation(
        domain,
        receipt,
        1,
        packed["wire_sha256"],
        packed["tokenizer_execution_sha256"],
        packed["wire_tokens"],
    )
    if raw != expected_raw or packed != expected_packed:
        raise WireError("invalid observations")
    expected_reconciliation = make_reconciliation(
        domain,
        policy,
        receipt,
        raw,
        packed,
    )
    if execution["reconciliation"] != expected_reconciliation:
        raise WireError("invalid reconciliation")
    if (
        execution["raw_wire_bytes"] == 0
        or execution["packed_wire_bytes"] != len(packed_wire)
        or execution["packed_wire_bytes"] > execution["raw_wire_bytes"]
        or execution["raw_wire_bytes"] > descriptor["max_wire_bytes"]
        or execution["packed_wire_bytes"] > descriptor["max_wire_bytes"]
    ):
        raise WireError("invalid execution wire lengths")
    expected_execution = make_execution(
        descriptor,
        domain,
        policy,
        receipt,
        execution["render_execution_sha256"],
        execution["raw_wire_bytes"],
        execution["packed_wire_bytes"],
        raw,
        packed,
        expected_reconciliation,
    )
    if execution != expected_execution:
        raise WireError("invalid execution")


def _encode_descriptor(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u64(value["adapter_abi"]),
            value["provider_namespace_sha256"],
            value["tokenizer_sha256"],
            value["render_policy_sha256"],
            _u64(value["capability_bits"]),
            _u64(value["max_wire_bytes"]),
            value["descriptor_sha256"],
        )
    )


def _encode_domain(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u64(value["isolation_key"]),
            _u64(value["adapter_abi"]),
            value["provider_namespace_sha256"],
            value["model_sha256"],
            value["tokenizer_sha256"],
            value["render_policy_sha256"],
            value["domain_sha256"],
        )
    )


def _encode_policy(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u32(value["max_spans"]),
            _u64(value["max_input_tokens"]),
            _u64(value["fixed_overhead_tokens"]),
            value["policy_sha256"],
        )
    )


def _encode_span(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u32(value["sequence"]),
            _u8(value["kind"]),
            _u8(value["reuse_mode"]),
            _u8(value["retention"]),
            value["content_sha256"],
            value["rendered_sha256"],
            value["provenance_sha256"],
            _u64(value["token_count"]),
            value["span_sha256"],
        )
    )


def _encode_decision(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u32(value["sequence"]),
            _u8(value["action"]),
            value["span_sha256"],
            _u32(value["representative_sequence"]),
            value["representative_span_sha256"],
            _u64(value["logical_tokens"]),
            _u64(value["emitted_tokens"]),
            value["decision_sha256"],
        )
    )


def _encode_receipt(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            value["domain_sha256"],
            value["policy_sha256"],
            _u32(value["input_spans"]),
            _u32(value["emitted_spans"]),
            _u32(value["aliased_spans"]),
            _u32(value["required_spans"]),
            _u64(value["logical_tokens"]),
            _u64(value["emitted_tokens"]),
            _u64(value["deduplicated_tokens"]),
            value["mapping_chain_sha256"],
            value["emitted_chain_sha256"],
            value["receipt_sha256"],
        )
    )


def _encode_observation(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u8(value["arm"]),
            value["domain_sha256"],
            value["context_chain_sha256"],
            value["wire_sha256"],
            value["tokenizer_execution_sha256"],
            _u64(value["wire_tokens"]),
            value["observation_sha256"],
        )
    )


def _encode_reconciliation(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            value["domain_sha256"],
            value["policy_sha256"],
            value["receipt_sha256"],
            value["raw_observation_sha256"],
            value["packed_observation_sha256"],
            value["tokenizer_execution_sha256"],
            _u64(value["raw_wire_tokens"]),
            _u64(value["packed_wire_tokens"]),
            _u64(value["wire_deduplicated_tokens"]),
            _u64(value["max_input_tokens"]),
            _u64(value["packed_budget_headroom"]),
            value["reconciliation_sha256"],
        )
    )


def _encode_execution(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            value["descriptor_sha256"],
            value["domain_sha256"],
            value["policy_sha256"],
            value["pack_receipt_sha256"],
            value["render_execution_sha256"],
            _u64(value["raw_wire_bytes"]),
            _u64(value["packed_wire_bytes"]),
            _encode_observation(value["raw_observation"]),
            _encode_observation(value["packed_observation"]),
            _encode_reconciliation(value["reconciliation"]),
            value["execution_sha256"],
        )
    )


def encoded_len(span_count: int, packed_wire_bytes: int) -> int:
    if not 0 <= span_count <= MAX_SPANS or not 0 <= packed_wire_bytes <= MAX_WIRE_BYTES:
        raise WireError("wire capacity exceeded")
    return FIXED_WIRE_BYTES + span_count * (151 + 129) + packed_wire_bytes


def encode_evidence(value: Record) -> bytes:
    verify_evidence(value)
    spans = value["spans"]
    decisions = value["decisions"]
    packed_wire = value["packed_wire"]
    if len(spans) != len(decisions):
        raise WireError("span/decision count mismatch")
    total = encoded_len(len(spans), len(packed_wire))
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(total),
            _u32(len(spans)),
            _u32(FLAGS_NONE),
            _u64(len(packed_wire)),
            _encode_descriptor(value["descriptor"]),
            _encode_domain(value["domain"]),
            _encode_policy(value["policy"]),
            b"".join(_encode_span(item) for item in spans),
            b"".join(_encode_decision(item) for item in decisions),
            _encode_receipt(value["receipt"]),
            _encode_execution(value["execution"]),
            packed_wire,
        )
    )
    if len(prefix) + 32 != total:
        raise WireError("internal wire length mismatch")
    return prefix + _hash(ENVELOPE_HASH_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.position = 0

    def take(self, size: int) -> bytes:
        end = self.position + size
        if size < 0 or end > len(self.data):
            raise WireError("truncated wire")
        result = self.data[self.position : end]
        self.position = end
        return result

    def u8(self) -> int:
        return struct.unpack("<B", self.take(1))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> Digest:
        return self.take(32)


def _read_descriptor(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "adapter_abi": reader.u64(),
        "provider_namespace_sha256": reader.digest(),
        "tokenizer_sha256": reader.digest(),
        "render_policy_sha256": reader.digest(),
        "capability_bits": reader.u64(),
        "max_wire_bytes": reader.u64(),
        "descriptor_sha256": reader.digest(),
    }


def _read_domain(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "isolation_key": reader.u64(),
        "adapter_abi": reader.u64(),
        "provider_namespace_sha256": reader.digest(),
        "model_sha256": reader.digest(),
        "tokenizer_sha256": reader.digest(),
        "render_policy_sha256": reader.digest(),
        "domain_sha256": reader.digest(),
    }


def _read_policy(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "max_spans": reader.u32(),
        "max_input_tokens": reader.u64(),
        "fixed_overhead_tokens": reader.u64(),
        "policy_sha256": reader.digest(),
    }


def _read_span(reader: _Reader) -> Record:
    value = {
        "abi_version": reader.u64(),
        "sequence": reader.u32(),
        "kind": reader.u8(),
        "reuse_mode": reader.u8(),
        "retention": reader.u8(),
        "content_sha256": reader.digest(),
        "rendered_sha256": reader.digest(),
        "provenance_sha256": reader.digest(),
        "token_count": reader.u64(),
        "span_sha256": reader.digest(),
    }
    if value["kind"] not in range(5) or value["reuse_mode"] not in range(2) or value[
        "retention"
    ] not in range(2):
        raise WireError("unknown span enum")
    return value


def _read_decision(reader: _Reader) -> Record:
    value = {
        "abi_version": reader.u64(),
        "sequence": reader.u32(),
        "action": reader.u8(),
        "span_sha256": reader.digest(),
        "representative_sequence": reader.u32(),
        "representative_span_sha256": reader.digest(),
        "logical_tokens": reader.u64(),
        "emitted_tokens": reader.u64(),
        "decision_sha256": reader.digest(),
    }
    if value["action"] not in (0, 1):
        raise WireError("unknown decision enum")
    return value


def _read_receipt(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "domain_sha256": reader.digest(),
        "policy_sha256": reader.digest(),
        "input_spans": reader.u32(),
        "emitted_spans": reader.u32(),
        "aliased_spans": reader.u32(),
        "required_spans": reader.u32(),
        "logical_tokens": reader.u64(),
        "emitted_tokens": reader.u64(),
        "deduplicated_tokens": reader.u64(),
        "mapping_chain_sha256": reader.digest(),
        "emitted_chain_sha256": reader.digest(),
        "receipt_sha256": reader.digest(),
    }


def _read_observation(reader: _Reader) -> Record:
    value = {
        "abi_version": reader.u64(),
        "arm": reader.u8(),
        "domain_sha256": reader.digest(),
        "context_chain_sha256": reader.digest(),
        "wire_sha256": reader.digest(),
        "tokenizer_execution_sha256": reader.digest(),
        "wire_tokens": reader.u64(),
        "observation_sha256": reader.digest(),
    }
    if value["arm"] not in (0, 1):
        raise WireError("unknown observation arm")
    return value


def _read_reconciliation(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "domain_sha256": reader.digest(),
        "policy_sha256": reader.digest(),
        "receipt_sha256": reader.digest(),
        "raw_observation_sha256": reader.digest(),
        "packed_observation_sha256": reader.digest(),
        "tokenizer_execution_sha256": reader.digest(),
        "raw_wire_tokens": reader.u64(),
        "packed_wire_tokens": reader.u64(),
        "wire_deduplicated_tokens": reader.u64(),
        "max_input_tokens": reader.u64(),
        "packed_budget_headroom": reader.u64(),
        "reconciliation_sha256": reader.digest(),
    }


def _read_execution(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "descriptor_sha256": reader.digest(),
        "domain_sha256": reader.digest(),
        "policy_sha256": reader.digest(),
        "pack_receipt_sha256": reader.digest(),
        "render_execution_sha256": reader.digest(),
        "raw_wire_bytes": reader.u64(),
        "packed_wire_bytes": reader.u64(),
        "raw_observation": _read_observation(reader),
        "packed_observation": _read_observation(reader),
        "reconciliation": _read_reconciliation(reader),
        "execution_sha256": reader.digest(),
    }


def decode_and_verify(data: bytes) -> Record:
    if len(data) < FIXED_WIRE_BYTES:
        raise WireError("wire too short")
    reader = _Reader(data)
    if reader.take(8) != MAGIC:
        raise WireError("invalid magic")
    if reader.u64() != WIRE_ABI:
        raise WireError("invalid wire ABI")
    if reader.u64() != len(data):
        raise WireError("declared length mismatch")
    span_count = reader.u32()
    if reader.u32() != FLAGS_NONE:
        raise WireError("unknown flags")
    packed_wire_bytes = reader.u64()
    if encoded_len(span_count, packed_wire_bytes) != len(data):
        raise WireError("derived length mismatch")
    root = _hash(ENVELOPE_HASH_DOMAIN, data[:-32])
    if data[-32:] != root:
        raise WireError("invalid envelope digest")
    value = {
        "descriptor": _read_descriptor(reader),
        "domain": _read_domain(reader),
        "policy": _read_policy(reader),
        "spans": [_read_span(reader) for _ in range(span_count)],
        "decisions": [_read_decision(reader) for _ in range(span_count)],
        "receipt": _read_receipt(reader),
        "execution": _read_execution(reader),
        "packed_wire": reader.take(packed_wire_bytes),
        "envelope_sha256": reader.digest(),
    }
    if reader.position != len(data) or value["envelope_sha256"] != root:
        raise WireError("trailing bytes or envelope mismatch")
    verify_evidence(value)
    return value


def reseal_for_test(data: bytes) -> bytes:
    if len(data) < 32:
        raise WireError("wire too short")
    prefix = data[:-32]
    return prefix + _hash(ENVELOPE_HASH_DOMAIN, prefix)


def build_demo_evidence() -> Record:
    adapter_abi = 0x44454D4F41445001
    provider = _sha256(b"demo-adapter-provider-v1")
    tokenizer = _sha256(b"demo-byte-tokenizer-v1")
    render_policy = _sha256(b"demo-framed-render-policy-v1")
    domain = make_domain(
        0x44454D4F43545849,
        adapter_abi,
        provider,
        _sha256(b"demo-adapter-model-v1"),
        tokenizer,
        render_policy,
    )
    policy = make_policy(4, 10, 2)
    fragments = (b"AA", b"BBB", b"BBB", b"C")
    provenance = (b"policy", b"tool-a", b"tool-b", b"turn-1")
    spans = [
        make_span(
            index,
            (0, 1, 1, 2)[index],
            (0, 1, 1, 0)[index],
            (0, 0, 0, 1)[index],
            _sha256(fragment),
            _sha256(fragment),
            _sha256(provenance[index]),
            len(fragment),
        )
        for index, fragment in enumerate(fragments)
    ]
    decisions, receipt = make_pack(domain, policy, spans)
    descriptor = make_descriptor(
        adapter_abi,
        provider,
        tokenizer,
        render_policy,
        REQUIRED_CAPABILITIES,
        64,
    )
    raw_wire = b"[AABBBBBBC]"
    packed_wire = b"[AABBBC]"
    tokenizer_execution = _sha256(b"demo-byte-tokenizer-execution-v1")
    raw = make_observation(
        domain,
        receipt,
        0,
        _sha256(raw_wire),
        tokenizer_execution,
        len(raw_wire),
    )
    packed = make_observation(
        domain,
        receipt,
        1,
        _sha256(packed_wire),
        tokenizer_execution,
        len(packed_wire),
    )
    reconciliation = make_reconciliation(
        domain,
        policy,
        receipt,
        raw,
        packed,
    )
    execution = make_execution(
        descriptor,
        domain,
        policy,
        receipt,
        _sha256(b"demo-byte-render-execution-v1"),
        len(raw_wire),
        len(packed_wire),
        raw,
        packed,
        reconciliation,
    )
    return {
        "descriptor": descriptor,
        "domain": domain,
        "policy": policy,
        "spans": spans,
        "decisions": decisions,
        "receipt": receipt,
        "execution": execution,
        "packed_wire": packed_wire,
    }
