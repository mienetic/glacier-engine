"""Independent verifier for prepared-text successor evidence v1."""

from __future__ import annotations

import copy
import hashlib
import struct
from typing import Any

from bench import model_contract as contract
from bench import prepared_text_checkpoint as checkpoint


class PreparedTextSuccessorError(ValueError):
    """The successor evidence or retained source context is invalid."""


Record = dict[str, Any]
MAGIC = b"GLTSEG01"
SUCCESSOR_SEGMENT_ABI = 0x474C545400000001
OWNERSHIP_INTENT_ABI = 0x474C544F00000001
RESOURCE_BANK_ABI = 0x4752424B00000001
LEASE_TREE_ABI = 0x47524C5400000001
LANE_WEAVE_ABI = 0x474C575100000001
TRANSCRIPT_SNAPSHOT_ABI = 0x474C505600000001
STATE_COMMITMENT_ABI = 0x474C505300000001
CONTIGUOUS_EXECUTION_ABI = checkpoint.CONTIGUOUS_ABI
CONTIGUOUS_RNG_STATE_ABI = checkpoint.RNG_STATE_ABI
IMPLEMENTATION_DEFINED = 4
NO_CAPABILITIES = 0
SUCCESSOR_SEGMENT_BYTES = 512
SUCCESSOR_SEGMENT_BODY_BYTES = SUCCESSOR_SEGMENT_BYTES - 32
ALLOWED_FLAGS = 0
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
U32_MAX = (1 << 32) - 1

SUCCESSOR_SEGMENT_DOMAIN = (
    b"glacier-prepared-text-successor-transcript-segment-v1\x00"
)
OWNERSHIP_INTENT_DOMAIN = (
    b"glacier-prepared-text-successor-ownership-intent-v1\x00"
)
RESOURCE_RECEIPT_DOMAIN = (
    b"glacier-lane-weave-qos-resource-receipt-v1\x00"
)
PUBLICATION_STATE_DOMAIN = b"glacier-lane-publication-state-v1\x00"

TARGET_FIELDS = (
    "scheduler_epoch",
    "coordinator_id",
    "bank_epoch",
    "request_generation",
    "resource_owner_key",
    "tree_key",
    "authority_key",
    "tenant_key",
    "scope_key",
    "cache_node_key",
    "cache_binding_key",
    "intent_generation",
)
SEGMENT_SCALAR_FIELDS = (
    "request_epoch",
    "sequence_base",
    "terminal_sequence",
    "remaining_quanta",
    "source_last_resource_permit_generation",
    "source_kv_position",
    "source_sampling_calls",
    "source_output_length",
    "source_execution_generation",
    "successor_execution_generation",
    "segment_generation",
    "execution_abi",
    "rng_state_abi",
)
SEGMENT_DIGEST_FIELDS = (
    "source_checkpoint_sha256",
    "source_bound_plan_sha256",
    "source_execution_plan_sha256",
    "source_boundary_sha256",
    "predecessor_transcript_sha256",
    "source_state_commitment_sha256",
    "source_logical_kv_sha256",
    "successor_execution_plan_sha256",
    "successor_residency_binding_sha256",
    "ownership_intent_sha256",
    "challenge_sha256",
)


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U32_MAX:
        raise PreparedTextSuccessorError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise PreparedTextSuccessorError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise PreparedTextSuccessorError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _claim(value: Record) -> Record:
    if not isinstance(value, dict) or set(value) != set(
        contract.CLAIM_FIELDS
    ):
        raise PreparedTextSuccessorError("invalid resource claim")
    result: Record = {}
    for name in contract.CLAIM_FIELDS:
        _u64(value[name])
        result[name] = value[name]
    try:
        contract.claim_host_bytes(result)
    except contract.ModelContractError as exc:
        raise PreparedTextSuccessorError("invalid resource claim") from exc
    return result


def _claim_bytes(value: Record) -> bytes:
    checked = _claim(value)
    return b"".join(
        _u64(checked[name]) for name in contract.CLAIM_FIELDS
    )


def _claims_equal(left: Record, right: Record) -> bool:
    try:
        return _claim_bytes(left) == _claim_bytes(right)
    except PreparedTextSuccessorError:
        return False


def resource_receipt_root(receipt: Record) -> bytes:
    """Hash a ResourceBank Receipt without native-struct padding."""

    try:
        bank_epoch = receipt["bank_epoch"]
        slot_index = receipt["slot_index"]
        generation = receipt["generation"]
        owner_key = receipt["owner_key"]
        claim = receipt["claim"]
        integrity = receipt["integrity"]
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError("invalid resource receipt") from exc
    return _hash(
        RESOURCE_RECEIPT_DOMAIN,
        _u64(bank_epoch),
        _u32(slot_index),
        _u64(generation),
        _u64(owner_key),
        _claim_bytes(claim),
        _u64(integrity),
    )


def publication_state_root(state: Record) -> bytes:
    """Recompute LanePublication StateCommitmentV1's canonical root."""

    try:
        return _hash(
            PUBLICATION_STATE_DOMAIN,
            _u64(state["abi_version"]),
            _u64(state["execution_abi"]),
            _u64(state["kv_position"]),
            _digest(state["kv_state_sha256"]),
            _u64(state["rng_state_abi"]),
            _digest(state["rng_state_sha256"]),
            _u64(state["sampling_calls"]),
            _u64(state["output_length"]),
            _digest(state["output_state_sha256"]),
        )
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError(
            "invalid publication state"
        ) from exc


def ownership_intent_root(
    source: Record,
    source_checkpoint_sha256: bytes,
    source_boundary_sha256: bytes,
    sequence_base: int,
    successor_generation: int,
    challenge_sha256: bytes,
    target: Record,
) -> bytes:
    """Hash the exact source-to-target ownership intent preimage."""

    checked_target = _target(target)
    try:
        execution = source["execution"]
        receipt = source["receipt"]
        parts = (
            _u64(OWNERSHIP_INTENT_ABI),
            _u64(RESOURCE_BANK_ABI),
            _u64(LEASE_TREE_ABI),
            _u64(LANE_WEAVE_ABI),
            _u64(contract.EXECUTION_PLAN_ABI),
            resource_receipt_root(receipt),
            _digest(execution["ownership_sha256"]),
            _digest(execution["plan_sha256"]),
            _digest(source_checkpoint_sha256),
            _digest(source_boundary_sha256),
            _u64(execution["request_epoch"]),
            _u64(sequence_base),
            _u64(execution["generation"]),
            _u64(successor_generation),
            *(_u64(checked_target[name]) for name in TARGET_FIELDS),
            _claim_bytes(checked_target["request_claim"]),
            _digest(challenge_sha256),
        )
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError(
            "invalid ownership intent source"
        ) from exc
    return _hash(OWNERSHIP_INTENT_DOMAIN, *parts)


def successor_segment_root(segment: Record) -> bytes:
    """Return the domain-separated root of the canonical 480-byte body."""

    return _hash(SUCCESSOR_SEGMENT_DOMAIN, _segment_body(segment))


def encode_segment(segment: Record) -> bytes:
    """Encode one canonical fixed-width successor transcript segment."""

    checked = _segment(segment)
    body = _segment_body(checked)
    if len(body) != SUCCESSOR_SEGMENT_BODY_BYTES:
        raise PreparedTextSuccessorError("internal segment length mismatch")
    return body + checked["segment_sha256"]


def decode_segment(encoded: bytes) -> Record:
    """Decode and semantically validate one successor segment."""

    if (
        not isinstance(encoded, bytes)
        or len(encoded) != SUCCESSOR_SEGMENT_BYTES
        or encoded[:8] != MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0]
        != SUCCESSOR_SEGMENT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != ALLOWED_FLAGS
    ):
        raise PreparedTextSuccessorError("invalid segment wire")
    cursor = 24

    def read_u64() -> int:
        nonlocal cursor
        result = struct.unpack_from("<Q", encoded, cursor)[0]
        cursor += 8
        return result

    def read_digest() -> bytes:
        nonlocal cursor
        result = encoded[cursor : cursor + 32]
        cursor += 32
        return result

    value: Record = {
        "abi_version": SUCCESSOR_SEGMENT_ABI,
        **{name: read_u64() for name in SEGMENT_SCALAR_FIELDS},
        **{name: read_digest() for name in SEGMENT_DIGEST_FIELDS},
    }
    if cursor != SUCCESSOR_SEGMENT_BODY_BYTES:
        raise PreparedTextSuccessorError("segment body mismatch")
    value["segment_sha256"] = read_digest()
    if cursor != SUCCESSOR_SEGMENT_BYTES:
        raise PreparedTextSuccessorError("segment footer mismatch")
    checked = _segment(value)
    if encode_segment(checked) != encoded:
        raise PreparedTextSuccessorError("non-canonical segment")
    return checked


def make_for_checkpoint(
    encoded_checkpoint: bytes,
    expected_checkpoint: Record,
    source: Record,
    target: Record,
) -> Record:
    """Derive the successor plan, residency binding, and bridge segment."""

    try:
        decoded = checkpoint.decode(
            encoded_checkpoint,
            expected_checkpoint,
        )
    except checkpoint.PreparedTextCheckpointError as exc:
        raise PreparedTextSuccessorError("invalid source checkpoint") from exc
    return _make_from_decoded(decoded, source, target)


def encode_artifacts(artifacts: Record) -> tuple[bytes, bytes, bytes]:
    """Encode the three canonical records after full composition checks."""

    checked = _artifacts(artifacts)
    try:
        encoded_plan = contract.encode_plan(checked["successor_plan"])
        encoded_residency = contract.encode_residency_binding(
            checked["successor_residency"]
        )
    except contract.ModelContractError as exc:
        raise PreparedTextSuccessorError(
            "invalid Common Model Contract artifact"
        ) from exc
    return encoded_plan, encoded_residency, encode_segment(
        checked["segment"]
    )


def decode_artifacts(
    encoded_plan: bytes,
    encoded_residency: bytes,
    encoded_segment: bytes,
) -> Record:
    """Decode and cross-check three self-contained successor records."""

    try:
        plan = contract.decode_plan(encoded_plan)
    except contract.ModelContractError as exc:
        raise PreparedTextSuccessorError("invalid successor plan") from exc
    try:
        residency = contract.decode_residency_binding(encoded_residency)
    except contract.ModelContractError as exc:
        raise PreparedTextSuccessorError(
            "invalid successor residency"
        ) from exc
    return _artifacts(
        {
            "successor_plan": plan,
            "successor_residency": residency,
            "segment": decode_segment(encoded_segment),
        }
    )


def decode_and_verify_for_checkpoint(
    encoded_plan: bytes,
    encoded_residency: bytes,
    encoded_segment: bytes,
    encoded_checkpoint: bytes,
    expected_checkpoint: Record,
    source: Record,
    target: Record,
) -> Record:
    """Reject a canonical foreign artifact against caller-retained context."""

    expected = make_for_checkpoint(
        encoded_checkpoint,
        expected_checkpoint,
        source,
        target,
    )
    decoded = decode_artifacts(
        encoded_plan,
        encoded_residency,
        encoded_segment,
    )
    if (
        decoded["segment"]["challenge_sha256"]
        != expected["segment"]["challenge_sha256"]
    ):
        raise PreparedTextSuccessorError("challenge mismatch")
    if decoded != expected:
        raise PreparedTextSuccessorError("successor binding mismatch")
    return decoded


def _segment_body(segment: Record) -> bytes:
    try:
        abi_version = segment.get(
            "abi_version",
            SUCCESSOR_SEGMENT_ABI,
        )
        scalars = tuple(segment[name] for name in SEGMENT_SCALAR_FIELDS)
        digests = tuple(
            _digest(segment[name], allow_zero=True)
            for name in SEGMENT_DIGEST_FIELDS
        )
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError("invalid segment") from exc
    return b"".join(
        (
            MAGIC,
            _u64(abi_version),
            _u64(ALLOWED_FLAGS),
            *(_u64(value) for value in scalars),
            *digests,
        )
    )


def _segment(value: Record) -> Record:
    try:
        result: Record = {
            "abi_version": value.get(
                "abi_version",
                SUCCESSOR_SEGMENT_ABI,
            ),
            **{name: value[name] for name in SEGMENT_SCALAR_FIELDS},
            **{
                name: _digest(value[name])
                for name in SEGMENT_DIGEST_FIELDS
            },
            "segment_sha256": _digest(value["segment_sha256"]),
        }
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError("invalid segment") from exc
    for name in ("abi_version", *SEGMENT_SCALAR_FIELDS):
        _u64(result[name])
    source_generation = result["source_execution_generation"]
    if source_generation == U64_MAX:
        raise PreparedTextSuccessorError("successor generation overflow")
    if (
        result["abi_version"] != SUCCESSOR_SEGMENT_ABI
        or result["request_epoch"] == 0
        or result["sequence_base"] == 0
        or result["sequence_base"] >= result["terminal_sequence"]
        or result["remaining_quanta"] == 0
        or result["remaining_quanta"]
        != result["terminal_sequence"] - result["sequence_base"]
        or result["source_last_resource_permit_generation"] == 0
        or result["source_kv_position"] == 0
        or result["source_sampling_calls"] != result["sequence_base"]
        or result["source_output_length"] != result["sequence_base"]
        or source_generation == 0
        or result["successor_execution_generation"]
        != source_generation + 1
        or result["segment_generation"]
        != result["successor_execution_generation"]
        or result["execution_abi"] != CONTIGUOUS_EXECUTION_ABI
        or result["rng_state_abi"] != CONTIGUOUS_RNG_STATE_ABI
        or result["source_execution_plan_sha256"]
        == result["successor_execution_plan_sha256"]
    ):
        raise PreparedTextSuccessorError("invalid segment semantics")
    expected_root = successor_segment_root(result)
    if result["segment_sha256"] != expected_root:
        raise PreparedTextSuccessorError("segment root mismatch")
    return result


def _target(value: Record) -> Record:
    try:
        result = {name: value[name] for name in TARGET_FIELDS}
        result["request_claim"] = _claim(value["request_claim"])
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError(
            "invalid target ownership"
        ) from exc
    for name in TARGET_FIELDS:
        _u64(result[name])
    return result


def _canonical_plan(value: Record, *, sealed: bool) -> Record:
    try:
        encoded = contract.encode_plan(value)
        result = contract.decode_plan(encoded)
    except contract.ModelContractError as exc:
        raise PreparedTextSuccessorError("invalid execution plan") from exc
    if sealed and value.get("plan_sha256", ZERO_DIGEST) == ZERO_DIGEST:
        raise PreparedTextSuccessorError("unsealed execution plan")
    return result


def _validate_source(decoded: Record, source: Record) -> Record:
    try:
        execution = _canonical_plan(source["execution"], sealed=True)
        residency = source["residency"]
        contract.validate_residency_binding(residency, execution)
        canonical_residency = contract.decode_residency_binding(
            contract.encode_residency_binding(residency)
        )
        receipt = source["receipt"]
        publication = source["publication"]
        state = publication["state"]
        bound_plan = _digest(source["bound_plan_sha256"])
        boundary = _digest(source["boundary_sha256"])
    except (KeyError, TypeError, contract.ModelContractError) as exc:
        raise PreparedTextSuccessorError(
            "invalid source context"
        ) from exc
    if not contract.receipt_integrity_valid(receipt):
        raise PreparedTextSuccessorError("invalid source receipt")
    try:
        contract.claim_host_bytes(receipt["claim"])
    except (KeyError, TypeError, contract.ModelContractError) as exc:
        raise PreparedTextSuccessorError("invalid source receipt") from exc
    maximum_output = execution["maximum_absolute_output"]
    if maximum_output == U64_MAX:
        raise PreparedTextSuccessorError("output vocabulary overflow")
    try:
        state_root = publication_state_root(state)
        state_commitment = _digest(state["commitment_sha256"])
        transcript = _digest(publication["transcript_sha256"])
    except (KeyError, TypeError) as exc:
        raise PreparedTextSuccessorError(
            "invalid source publication"
        ) from exc
    if (
        execution["family"] != contract.AUTOREGRESSIVE
        or execution["operation"] != contract.GENERATE_SEQUENCE
        or execution["input_kind"] != contract.TOKEN_ID_INPUT
        or execution["output_kind"] != contract.TOKEN_IDS
        or execution["numerical_policy"] != IMPLEMENTATION_DEFINED
        or execution["batch_items"] != 1
        or execution["required_capabilities"] != NO_CAPABILITIES
        or execution["input_element_bytes"] != 4
        or execution["output_element_bytes"] != 4
        or canonical_residency["residency"]
        != contract.SHARED_READ_ONLY
        or execution["scratch_bytes"]
        != canonical_residency["request_claim"]["partial_bytes"]
        or execution["request_epoch"] != decoded["request_epoch"]
        or execution["input_features"] != decoded["prompt_tokens"]
        or execution["output_dimensions"] != decoded["max_new_tokens"]
        or maximum_output + 1 != decoded["vocab_size"]
        or execution["publication_next_sequence"]
        >= decoded["publication_next_sequence"]
        or execution["artifact_sha256"] != decoded["artifact_sha256"]
        or execution["plan_sha256"]
        != decoded["execution_plan_sha256"]
        or canonical_residency["binding_sha256"]
        != decoded["residency_binding_sha256"]
        or bound_plan != decoded["bound_plan_sha256"]
        or boundary != decoded["boundary_sha256"]
        or publication.get("abi_version") != TRANSCRIPT_SNAPSHOT_ABI
        or publication.get("request_epoch") != decoded["request_epoch"]
        or publication.get("execution_abi")
        != CONTIGUOUS_EXECUTION_ABI
        or publication.get("execution_abi")
        != state.get("execution_abi")
        or state.get("rng_state_abi")
        != CONTIGUOUS_RNG_STATE_ABI
        or publication.get("next_sequence")
        != decoded["publication_next_sequence"]
        or publication.get("last_resource_permit_generation", 0) == 0
        or publication.get("terminal") is not False
        or state.get("abi_version") != STATE_COMMITMENT_ABI
        or state.get("execution_abi", 0) == 0
        or state.get("rng_state_abi", 0) == 0
        or state_root != state_commitment
        or state.get("kv_position") != decoded["kv_positions"]
        or state.get("sampling_calls") != decoded["sampling_calls"]
        or state.get("output_length") != decoded["output_count"]
        or state_commitment != decoded["state_commitment_sha256"]
        or transcript != decoded["transcript_sha256"]
        or not _claims_equal(
            receipt.get("claim", {}),
            canonical_residency["request_claim"],
        )
    ):
        raise PreparedTextSuccessorError("source binding mismatch")
    return {
        "bound_plan_sha256": bound_plan,
        "execution": execution,
        "residency": canonical_residency,
        "boundary_sha256": boundary,
        "publication": copy.deepcopy(publication),
        "receipt": copy.deepcopy(receipt),
    }


def _validate_target(
    source: Record,
    target: Record,
    successor_generation: int,
) -> Record:
    checked = _target(target)
    receipt = source["receipt"]
    if (
        any(checked[name] == 0 for name in TARGET_FIELDS)
        or checked["bank_epoch"] == receipt["bank_epoch"]
        or checked["resource_owner_key"] == receipt["owner_key"]
        or checked["request_generation"] != successor_generation
        or checked["intent_generation"] != successor_generation
        or not _claims_equal(
            checked["request_claim"],
            source["residency"]["request_claim"],
        )
    ):
        raise PreparedTextSuccessorError("invalid ownership intent")
    return checked


def _make_from_decoded(
    decoded: Record,
    source: Record,
    target: Record,
) -> Record:
    checked_source = _validate_source(decoded, source)
    source_generation = checked_source["execution"]["generation"]
    if source_generation == U64_MAX:
        raise PreparedTextSuccessorError("successor generation overflow")
    successor_generation = source_generation + 1
    checked_target = _validate_target(
        checked_source,
        target,
        successor_generation,
    )
    intent = ownership_intent_root(
        checked_source,
        decoded["checkpoint_sha256"],
        decoded["boundary_sha256"],
        decoded["publication_next_sequence"],
        successor_generation,
        decoded["challenge_sha256"],
        checked_target,
    )
    successor_plan = copy.deepcopy(checked_source["execution"])
    successor_plan.update(
        {
            "generation": successor_generation,
            "publication_next_sequence": decoded[
                "publication_next_sequence"
            ],
            "cache_payload_sha256": decoded["logical_kv_sha256"],
            "ownership_sha256": intent,
            "challenge_sha256": decoded["challenge_sha256"],
            "previous_plan_sha256": checked_source["execution"][
                "plan_sha256"
            ],
            "plan_sha256": ZERO_DIGEST,
        }
    )
    successor_plan = _canonical_plan(successor_plan, sealed=False)
    try:
        successor_residency = contract.make_residency_binding(
            successor_plan,
            residency=checked_source["residency"]["residency"],
            resident_weight_bytes=checked_source["residency"][
                "resident_weight_bytes"
            ],
            request_claim=checked_source["residency"]["request_claim"],
        )
    except contract.ModelContractError as exc:
        raise PreparedTextSuccessorError(
            "invalid successor residency"
        ) from exc
    publication = checked_source["publication"]
    state = publication["state"]
    segment: Record = {
        "abi_version": SUCCESSOR_SEGMENT_ABI,
        "request_epoch": decoded["request_epoch"],
        "sequence_base": decoded["publication_next_sequence"],
        "terminal_sequence": decoded["max_new_tokens"],
        "remaining_quanta": (
            decoded["max_new_tokens"]
            - decoded["publication_next_sequence"]
        ),
        "source_last_resource_permit_generation": publication[
            "last_resource_permit_generation"
        ],
        "source_kv_position": decoded["kv_positions"],
        "source_sampling_calls": decoded["sampling_calls"],
        "source_output_length": decoded["output_count"],
        "source_execution_generation": source_generation,
        "successor_execution_generation": successor_generation,
        "segment_generation": successor_generation,
        "execution_abi": state["execution_abi"],
        "rng_state_abi": state["rng_state_abi"],
        "source_checkpoint_sha256": decoded["checkpoint_sha256"],
        "source_bound_plan_sha256": decoded["bound_plan_sha256"],
        "source_execution_plan_sha256": checked_source["execution"][
            "plan_sha256"
        ],
        "source_boundary_sha256": decoded["boundary_sha256"],
        "predecessor_transcript_sha256": decoded[
            "transcript_sha256"
        ],
        "source_state_commitment_sha256": decoded[
            "state_commitment_sha256"
        ],
        "source_logical_kv_sha256": decoded["logical_kv_sha256"],
        "successor_execution_plan_sha256": successor_plan[
            "plan_sha256"
        ],
        "successor_residency_binding_sha256": successor_residency[
            "binding_sha256"
        ],
        "ownership_intent_sha256": intent,
        "challenge_sha256": decoded["challenge_sha256"],
        "segment_sha256": ZERO_DIGEST,
    }
    segment["segment_sha256"] = successor_segment_root(segment)
    return _artifacts(
        {
            "successor_plan": successor_plan,
            "successor_residency": successor_residency,
            "segment": segment,
        }
    )


def _artifacts(value: Record) -> Record:
    try:
        plan = _canonical_plan(value["successor_plan"], sealed=True)
        residency = contract.decode_residency_binding(
            contract.encode_residency_binding(
                value["successor_residency"]
            )
        )
        contract.validate_residency_binding(residency, plan)
        segment = _segment(value["segment"])
    except (KeyError, TypeError, contract.ModelContractError) as exc:
        raise PreparedTextSuccessorError(
            "invalid successor artifact composition"
        ) from exc
    kv_sequence_offset = segment["sequence_base"] - 1
    if plan["input_features"] > U64_MAX - kv_sequence_offset:
        raise PreparedTextSuccessorError("source KV position overflow")
    expected_source_kv_position = (
        plan["input_features"] + kv_sequence_offset
    )
    if (
        plan["family"] != contract.AUTOREGRESSIVE
        or plan["operation"] != contract.GENERATE_SEQUENCE
        or plan["input_kind"] != contract.TOKEN_ID_INPUT
        or plan["output_kind"] != contract.TOKEN_IDS
        or plan["numerical_policy"] != IMPLEMENTATION_DEFINED
        or plan["batch_items"] != 1
        or plan["required_capabilities"] != NO_CAPABILITIES
        or plan["input_element_bytes"] != 4
        or plan["output_element_bytes"] != 4
        or residency["residency"] != contract.SHARED_READ_ONLY
        or plan["scratch_bytes"]
        != residency["request_claim"]["partial_bytes"]
    ):
        raise PreparedTextSuccessorError("invalid successor plan profile")
    if (
        plan["request_epoch"] != segment["request_epoch"]
        or plan["generation"]
        != segment["successor_execution_generation"]
        or plan["publication_next_sequence"]
        != segment["sequence_base"]
        or plan["output_dimensions"] != segment["terminal_sequence"]
        or segment["source_kv_position"]
        != expected_source_kv_position
        or plan["previous_plan_sha256"]
        != segment["source_execution_plan_sha256"]
        or plan["cache_payload_sha256"]
        != segment["source_logical_kv_sha256"]
        or plan["ownership_sha256"]
        != segment["ownership_intent_sha256"]
        or plan["challenge_sha256"] != segment["challenge_sha256"]
        or plan["plan_sha256"]
        != segment["successor_execution_plan_sha256"]
        or residency["binding_sha256"]
        != segment["successor_residency_binding_sha256"]
    ):
        raise PreparedTextSuccessorError(
            "successor artifact binding mismatch"
        )
    return {
        "successor_plan": plan,
        "successor_residency": residency,
        "segment": segment,
    }


if SUCCESSOR_SEGMENT_BODY_BYTES != 480:
    raise RuntimeError("prepared successor segment body drift")
