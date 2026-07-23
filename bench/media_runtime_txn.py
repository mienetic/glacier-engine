"""Independent resource-admitted media runtime transaction oracle."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media
from bench import media_decode_fixture as fixture_api
from bench import media_transform as transform


class MediaRuntimeTxnError(ValueError):
    """A media runtime claim, publication, or receipt is invalid."""


Record = dict[str, Any]
RUNTIME_ABI = 0x474D525400000001
RECEIPT_ABI = 0x474D525200000001
RECEIPT_MAGIC = b"GMRTXN1\x00"
RECEIPT_BYTES = 640
RECEIPT_BODY_BYTES = 608
MAPPING_ACCOUNTING_BYTES = 128
ALLOWED_FLAGS = 0
RESOURCE_DOMAIN = b"glacier-media-runtime-resource-v1\x00"
RECEIPT_DOMAIN = b"glacier-media-runtime-receipt-v1\x00"
RESOURCE_RECEIPT_DOMAIN = 0x7265636569707431
U64_MAX = (1 << 64) - 1
U32_MAX = (1 << 32) - 1
ZERO_DIGEST = bytes(32)
CLAIM_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "logits_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "device_bytes",
    "io_bytes",
    "queue_slots",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaRuntimeTxnError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise MediaRuntimeTxnError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _checked_add(left: int, right: int) -> int:
    result = left + right
    if result > U64_MAX:
        raise MediaRuntimeTxnError("u64 addition overflow")
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    if result > U64_MAX:
        raise MediaRuntimeTxnError("u64 multiplication overflow")
    return result


def _claim(value: Record) -> Record:
    try:
        claim = {name: value[name] for name in CLAIM_FIELDS}
    except (KeyError, TypeError):
        raise MediaRuntimeTxnError("invalid resource claim") from None
    for field in CLAIM_FIELDS:
        _u64(claim[field])
    if not any(claim.values()):
        raise MediaRuntimeTxnError("empty resource claim")
    return claim


def claim_for_execution(
    encoded_fixture_bytes: int,
    plan_value: Record,
) -> Record:
    plan = transform.decode_plan(transform.encode_plan(plan_value))
    _u64(encoded_fixture_bytes)
    mapping_bytes = _checked_mul(plan["logical_units"], MAPPING_ACCOUNTING_BYTES)
    return _claim(
        {
            "capsule_bytes": (fixture_api.PLAN_BYTES + transform.PLAN_BYTES),
            "kv_bytes": 0,
            "activation_bytes": plan["source_bytes"],
            "partial_bytes": 0,
            "logits_bytes": 0,
            "output_journal_bytes": plan["output_bytes"],
            "staging_bytes": _checked_add(mapping_bytes, plan["scratch_bytes"]),
            "device_bytes": 0,
            "io_bytes": encoded_fixture_bytes,
            "queue_slots": 1,
        }
    )


def _mix64(value: int) -> int:
    value &= U64_MAX
    value ^= value >> 30
    value = (value * 0xBF58476D1CE4E5B9) & U64_MAX
    value ^= value >> 27
    value = (value * 0x94D049BB133111EB) & U64_MAX
    value ^= value >> 31
    return value


def resource_receipt(
    bank_epoch: int,
    slot_index: int,
    generation: int,
    owner_key: int,
    claim_value: Record,
) -> Record:
    claim = _claim(claim_value)
    for value in (bank_epoch, slot_index, generation, owner_key):
        _u64(value)
    if bank_epoch == 0 or slot_index > U32_MAX or generation == 0 or owner_key == 0:
        raise MediaRuntimeTxnError("invalid resource identity")
    integrity = _mix64(RESOURCE_RECEIPT_DOMAIN ^ bank_epoch)
    integrity = _mix64(integrity ^ slot_index)
    integrity = _mix64(integrity ^ generation)
    integrity = _mix64(integrity ^ owner_key)
    for field in CLAIM_FIELDS:
        integrity = _mix64(integrity ^ claim[field])
    return {
        "bank_epoch": bank_epoch,
        "slot_index": slot_index,
        "generation": generation,
        "owner_key": owner_key,
        "claim": claim,
        "integrity": integrity,
    }


def _resource_receipt(value: Record) -> Record:
    try:
        expected = resource_receipt(
            value["bank_epoch"],
            value["slot_index"],
            value["generation"],
            value["owner_key"],
            value["claim"],
        )
        integrity = value["integrity"]
    except (KeyError, TypeError):
        raise MediaRuntimeTxnError("invalid resource receipt") from None
    _u64(integrity)
    if expected["integrity"] != integrity:
        raise MediaRuntimeTxnError("invalid resource integrity")
    return {**expected, "integrity": integrity}


def resource_commitment(
    receipt_value: Record,
    request_epoch: int,
    fixture_sha256: bytes,
    transform_plan_sha256: bytes,
) -> bytes:
    receipt = _resource_receipt(receipt_value)
    return _hash(
        RESOURCE_DOMAIN,
        _u64(RUNTIME_ABI),
        _u64(request_epoch),
        _u64(receipt["bank_epoch"]),
        _u64(receipt["slot_index"]),
        _u64(receipt["generation"]),
        _u64(receipt["owner_key"]),
        *(_u64(receipt["claim"][name]) for name in CLAIM_FIELDS),
        _u64(receipt["integrity"]),
        _digest(fixture_sha256),
        _digest(transform_plan_sha256),
    )


def output_timeline_base(plan: Record) -> tuple[int, int]:
    return (1, 1) if plan["kind"] == media.IMAGE else plan["target_time_base"]


def _source_span(
    plan: Record,
) -> tuple[tuple[int, tuple[int, int]], tuple[int, tuple[int, int]]]:
    if plan["operation"] == transform.IMAGE_CROP_NEAREST_TILE:
        crop_x, crop_y, crop_width, crop_height = plan["parameters"][:4]
        first = crop_y * plan["source_axes"][0] + crop_x
        end = (crop_y + crop_height - 1) * plan["source_axes"][0] + crop_x + crop_width
        base = (1, 1)
    elif plan["operation"] == transform.AUDIO_MIX_DECIMATE:
        first = plan["parameters"][0]
        end = first + plan["parameters"][1]
        base = plan["source_time_base"]
    else:
        selected = plan["parameters"][1 : plan["logical_units"] + 1]
        first = min(selected)
        end = max(selected) + 1
        base = plan["source_time_base"]
    _u64(first)
    _u64(end)
    return ((first, base), (end, base))


def timeline_event_for_plan(
    plan_value: Record,
    parsed_fixture: Record,
    state: Record,
    transform_plan_sha256: bytes,
) -> Record:
    plan = transform.decode_plan(transform.encode_plan(plan_value))
    if (
        plan["kind"] != parsed_fixture["kind"]
        or plan["media_object_sha256"] != parsed_fixture["media_object_sha256"]
        or state["timeline_base"] != output_timeline_base(plan)
    ):
        raise MediaRuntimeTxnError("invalid timeline composition")
    target_end = _checked_add(state["visible_units"], plan["logical_units"])
    return {
        "kind": (
            media.FRAME_SELECT
            if plan["operation"] == transform.VIDEO_KEYFRAME_SELECT
            else media.RESAMPLE
        ),
        "sequence": state["next_sequence"],
        "media_object_sha256": plan["media_object_sha256"],
        "source": _source_span(plan),
        "target": (
            (state["visible_units"], state["timeline_base"]),
            (target_end, state["timeline_base"]),
        ),
        "plan_sha256": _digest(transform_plan_sha256),
        "previous_event_sha256": state["timeline_sha256"],
    }


def _receipt_body(receipt: Record) -> bytes:
    output = bytearray(RECEIPT_BODY_BYTES)
    output[:96] = b"".join(
        (
            RECEIPT_MAGIC,
            _u64(RECEIPT_ABI),
            _u64(RECEIPT_BYTES),
            _u64(ALLOWED_FLAGS),
            _u64(receipt["operation"]),
            _u64(receipt["kind"]),
            _u64(receipt["request_epoch"]),
            _u64(receipt["resource_sequence"]),
            _u64(receipt["media_sequence"]),
            _u64(receipt["logical_units"]),
            _u64(receipt["output_bytes"]),
            _u64(receipt["mapping_count"]),
        )
    )
    output[96:176] = b"".join(_u64(receipt["claim"][field]) for field in CLAIM_FIELDS)
    output[176:216] = b"".join(
        _u64(receipt[field])
        for field in (
            "resource_bank_epoch",
            "resource_slot_index",
            "resource_generation",
            "resource_owner_key",
            "resource_integrity",
        )
    )
    output[216:472] = b"".join(
        _digest(receipt[field])
        for field in (
            "fixture_sha256",
            "transform_plan_sha256",
            "transform_receipt_sha256",
            "resource_claim_sha256",
            "timeline_event_sha256",
            "publication_commit_sha256",
            "output_sha256",
            "mapping_chain_sha256",
        )
    )
    return bytes(output)


def receipt_root(receipt: Record) -> bytes:
    return _hash(RECEIPT_DOMAIN, _receipt_body(receipt))


def _receipt(value: Record) -> Record:
    try:
        receipt = {
            "operation": value["operation"],
            "kind": value["kind"],
            "request_epoch": value["request_epoch"],
            "resource_sequence": value["resource_sequence"],
            "media_sequence": value["media_sequence"],
            "logical_units": value["logical_units"],
            "output_bytes": value["output_bytes"],
            "mapping_count": value["mapping_count"],
            "claim": _claim(value["claim"]),
            "resource_bank_epoch": value["resource_bank_epoch"],
            "resource_slot_index": value["resource_slot_index"],
            "resource_generation": value["resource_generation"],
            "resource_owner_key": value["resource_owner_key"],
            "resource_integrity": value["resource_integrity"],
            "fixture_sha256": _digest(value["fixture_sha256"]),
            "transform_plan_sha256": _digest(value["transform_plan_sha256"]),
            "transform_receipt_sha256": _digest(value["transform_receipt_sha256"]),
            "resource_claim_sha256": _digest(value["resource_claim_sha256"]),
            "timeline_event_sha256": _digest(value["timeline_event_sha256"]),
            "publication_commit_sha256": _digest(value["publication_commit_sha256"]),
            "output_sha256": _digest(value["output_sha256"]),
            "mapping_chain_sha256": _digest(value["mapping_chain_sha256"]),
            "receipt_sha256": _digest(value["receipt_sha256"]),
        }
    except (KeyError, TypeError):
        raise MediaRuntimeTxnError("invalid runtime receipt") from None
    for field in (
        "operation",
        "kind",
        "request_epoch",
        "resource_sequence",
        "media_sequence",
        "logical_units",
        "output_bytes",
        "mapping_count",
        "resource_bank_epoch",
        "resource_slot_index",
        "resource_generation",
        "resource_owner_key",
        "resource_integrity",
    ):
        _u64(receipt[field])
    minimum_staging = _checked_mul(receipt["mapping_count"], MAPPING_ACCOUNTING_BYTES)
    if (
        receipt["operation"]
        not in (
            transform.IMAGE_CROP_NEAREST_TILE,
            transform.AUDIO_MIX_DECIMATE,
            transform.VIDEO_KEYFRAME_SELECT,
        )
        or receipt["kind"] not in (media.IMAGE, media.AUDIO, media.VIDEO)
        or receipt["request_epoch"] == 0
        or receipt["resource_sequence"] != 0
        or receipt["media_sequence"] == 0
        or receipt["logical_units"] == 0
        or receipt["output_bytes"] == 0
        or receipt["mapping_count"] != receipt["logical_units"]
        or receipt["claim"]["queue_slots"] != 1
        or receipt["claim"]["kv_bytes"] != 0
        or receipt["claim"]["partial_bytes"] != 0
        or receipt["claim"]["logits_bytes"] != 0
        or receipt["claim"]["device_bytes"] != 0
        or receipt["claim"]["output_journal_bytes"] != receipt["output_bytes"]
        or receipt["claim"]["staging_bytes"] < minimum_staging
        or receipt["resource_bank_epoch"] == 0
        or receipt["resource_slot_index"] > U32_MAX
        or receipt["resource_generation"] == 0
        or receipt["resource_owner_key"] == 0
        or receipt["resource_integrity"] == 0
        or receipt["receipt_sha256"] != receipt_root(receipt)
    ):
        raise MediaRuntimeTxnError("contradictory runtime receipt")
    return receipt


def encode_receipt(value: Record) -> bytes:
    receipt = _receipt(value)
    return _receipt_body(receipt) + receipt["receipt_sha256"]


def decode_receipt(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != RECEIPT_BYTES
        or encoded[:8] != RECEIPT_MAGIC
        or _read(encoded, 8) != RECEIPT_ABI
        or _read(encoded, 16) != RECEIPT_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or any(encoded[472:608])
        or encoded[608:] != _hash(RECEIPT_DOMAIN, encoded[:608])
    ):
        raise MediaRuntimeTxnError("invalid runtime receipt wire")
    fields = {
        "operation": _read(encoded, 32),
        "kind": _read(encoded, 40),
        "request_epoch": _read(encoded, 48),
        "resource_sequence": _read(encoded, 56),
        "media_sequence": _read(encoded, 64),
        "logical_units": _read(encoded, 72),
        "output_bytes": _read(encoded, 80),
        "mapping_count": _read(encoded, 88),
        "claim": {
            field: _read(encoded, 96 + index * 8)
            for index, field in enumerate(CLAIM_FIELDS)
        },
        "resource_bank_epoch": _read(encoded, 176),
        "resource_slot_index": _read(encoded, 184),
        "resource_generation": _read(encoded, 192),
        "resource_owner_key": _read(encoded, 200),
        "resource_integrity": _read(encoded, 208),
        "fixture_sha256": encoded[216:248],
        "transform_plan_sha256": encoded[248:280],
        "transform_receipt_sha256": encoded[280:312],
        "resource_claim_sha256": encoded[312:344],
        "timeline_event_sha256": encoded[344:376],
        "publication_commit_sha256": encoded[376:408],
        "output_sha256": encoded[408:440],
        "mapping_chain_sha256": encoded[440:472],
        "receipt_sha256": encoded[608:640],
    }
    return _receipt(fields)


def build_execution_receipt(
    state_before: Record,
    encoded_fixture: bytes,
    encoded_transform_plan: bytes,
    transform_receipt: Record,
    output: bytes,
    mappings: list[Record],
    resource_receipt_value: Record,
    resource_sequence: int = 0,
) -> tuple[Record, Record]:
    transform.verify_receipt(
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        output,
        mappings,
    )
    parsed_fixture = fixture_api.parse_fixture(encoded_fixture)
    plan = transform.decode_plan(encoded_transform_plan)
    plan_sha256 = transform.plan_sha256(encoded_transform_plan)
    claim = claim_for_execution(len(encoded_fixture), plan)
    resource = _resource_receipt(resource_receipt_value)
    if resource["claim"] != claim:
        raise MediaRuntimeTxnError("resource claim mismatch")
    commitment = resource_commitment(
        resource,
        state_before["request_epoch"],
        parsed_fixture["fixture_sha256"],
        plan_sha256,
    )
    event = timeline_event_for_plan(plan, parsed_fixture, state_before, plan_sha256)
    publication = media.prepare_publication(
        state_before,
        event,
        transform_receipt["output_sha256"],
        commitment,
    )
    receipt = {
        "operation": plan["operation"],
        "kind": plan["kind"],
        "request_epoch": state_before["request_epoch"],
        "resource_sequence": resource_sequence,
        "media_sequence": publication["sequence"],
        "logical_units": plan["logical_units"],
        "output_bytes": plan["output_bytes"],
        "mapping_count": plan["logical_units"],
        "claim": claim,
        "resource_bank_epoch": resource["bank_epoch"],
        "resource_slot_index": resource["slot_index"],
        "resource_generation": resource["generation"],
        "resource_owner_key": resource["owner_key"],
        "resource_integrity": resource["integrity"],
        "fixture_sha256": parsed_fixture["fixture_sha256"],
        "transform_plan_sha256": plan_sha256,
        "transform_receipt_sha256": transform_receipt["receipt_sha256"],
        "resource_claim_sha256": commitment,
        "timeline_event_sha256": media.timeline_event_root(event),
        "publication_commit_sha256": publication["commit_sha256"],
        "output_sha256": transform_receipt["output_sha256"],
        "mapping_chain_sha256": transform_receipt["mapping_chain_sha256"],
        "receipt_sha256": ZERO_DIGEST,
    }
    receipt["receipt_sha256"] = receipt_root(receipt)
    receipt = _receipt(receipt)
    return receipt, media.commit_publication(state_before, publication)


def verify_execution_receipt(
    state_before: Record,
    encoded_fixture: bytes,
    encoded_transform_plan: bytes,
    transform_receipt: Record,
    output: bytes,
    mappings: list[Record],
    receipt_value: Record,
) -> None:
    receipt = _receipt(receipt_value)
    resource = _resource_receipt(
        {
            "bank_epoch": receipt["resource_bank_epoch"],
            "slot_index": receipt["resource_slot_index"],
            "generation": receipt["resource_generation"],
            "owner_key": receipt["resource_owner_key"],
            "claim": receipt["claim"],
            "integrity": receipt["resource_integrity"],
        }
    )
    expected, _ = build_execution_receipt(
        state_before,
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        output,
        mappings,
        resource,
        receipt["resource_sequence"],
    )
    if receipt != expected:
        raise MediaRuntimeTxnError("runtime receipt mismatch")
