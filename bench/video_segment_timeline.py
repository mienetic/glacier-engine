"""Independent oracle for canonical video-segment timeline merging."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import video_segment_adapter as segment_adapter


class VideoSegmentTimelineError(ValueError):
    """A segment timeline, merge input, or receipt is invalid."""


Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
TIMELINE_ABI = 0x4756544C4E000001
MERGE_RECEIPT_ABI = 0x47564D5247000001
TIMELINE_BYTES = 384
MERGE_RECEIPT_BYTES = 384
TIMELINE_BODY_BYTES = TIMELINE_BYTES - 32
MERGE_RECEIPT_BODY_BYTES = MERGE_RECEIPT_BYTES - 32
TIMELINE_MAGIC = b"GVTLN1\x00\x00"
MERGE_RECEIPT_MAGIC = b"GVMRG1\x00\x00"
TIMELINE_DOMAIN = b"glacier-video-segment-timeline-v1\x00"
MERGE_RECEIPT_DOMAIN = b"glacier-video-segment-merge-receipt-v1\x00"
POLICY_DOMAIN = b"glacier-video-segment-merge-policy-v1\x00"
COALESCE = 1
RETAIN_DISTINCT = 2
TIMELINE_SCALARS = (
    "request_epoch",
    "next_sequence",
    "decision_count",
    "visible_segments",
    "tail_segment_index",
    "tail_first_frame",
    "tail_last_frame",
    "target_numerator",
    "target_denominator",
    "tail_start_tick",
    "tail_end_tick",
    "tail_event_id",
    "tail_confidence_ppm",
)
TIMELINE_DIGESTS = (
    "media_object_sha256",
    "challenge_sha256",
    "tail_segment_sha256",
    "previous_decision_sha256",
    "policy_sha256",
)
RECEIPT_SCALARS = (
    "request_epoch",
    "decision_sequence",
    "previous_segment_index",
    "incoming_segment_index",
    "action",
    "output_first_frame",
    "output_last_frame",
    "target_numerator",
    "target_denominator",
    "output_start_tick",
    "output_end_tick",
    "output_event_id",
    "output_confidence_ppm",
    "input_overlap_ticks",
    "replaced_tail_count",
    "visible_segment_delta",
)
RECEIPT_DIGESTS = (
    "media_object_sha256",
    "challenge_sha256",
    "previous_segment_sha256",
    "incoming_segment_sha256",
    "previous_decision_sha256",
    "policy_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise VideoSegmentTimelineError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or not any(value):
        raise VideoSegmentTimelineError("invalid digest")
    return value


def policy_root() -> bytes:
    return hashlib.sha256(
        POLICY_DOMAIN + _u64(1) + _u64(COALESCE) + _u64(RETAIN_DISTINCT)
    ).digest()


def _timeline_body(timeline: Record) -> bytes:
    try:
        scalars = tuple(timeline[field] for field in TIMELINE_SCALARS)
        digests = tuple(timeline[field] for field in TIMELINE_DIGESTS)
    except (KeyError, TypeError):
        raise VideoSegmentTimelineError("invalid timeline") from None
    output = bytearray(TIMELINE_BODY_BYTES)
    output[:32] = TIMELINE_MAGIC + _u64(TIMELINE_ABI) + _u64(TIMELINE_BYTES) + _u64(0)
    output[32:136] = b"".join(_u64(value) for value in scalars)
    output[160:320] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def timeline_root(timeline: Record) -> bytes:
    return hashlib.sha256(TIMELINE_DOMAIN + _timeline_body(timeline)).digest()


def validate_timeline(value: Record) -> Record:
    fields = TIMELINE_SCALARS + TIMELINE_DIGESTS + ("timeline_sha256",)
    try:
        timeline = {field: value[field] for field in fields}
        for field in TIMELINE_SCALARS:
            _u64(timeline[field])
        for field in TIMELINE_DIGESTS + ("timeline_sha256",):
            _digest(timeline[field])
        maximum_visible = timeline["decision_count"] + 1
        _u64(maximum_visible)
    except (KeyError, TypeError, OverflowError):
        raise VideoSegmentTimelineError("invalid timeline") from None
    if (
        timeline["request_epoch"] == 0
        or timeline["visible_segments"] == 0
        or timeline["tail_segment_index"] == 0
        or timeline["tail_first_frame"] > timeline["tail_last_frame"]
        or timeline["target_numerator"] == 0
        or timeline["target_denominator"] == 0
        or timeline["tail_start_tick"] >= timeline["tail_end_tick"]
        or timeline["tail_event_id"] == 0
        or timeline["tail_confidence_ppm"] > 1_000_000
        or timeline["next_sequence"] != timeline["decision_count"]
        or timeline["visible_segments"] > maximum_visible
        or timeline["policy_sha256"] != policy_root()
        or timeline["timeline_sha256"] != timeline_root(timeline)
    ):
        raise VideoSegmentTimelineError("invalid timeline")
    return timeline


def initialize_timeline(
    initial_value: Record,
    genesis_decision_sha256: bytes,
) -> Record:
    initial = segment_adapter.validate_segment(initial_value)
    _digest(genesis_decision_sha256)
    timeline: Record = {
        "request_epoch": initial["request_epoch"],
        "next_sequence": 0,
        "decision_count": 0,
        "visible_segments": 1,
        "tail_segment_index": initial["segment_index"],
        "tail_first_frame": initial["first_frame"],
        "tail_last_frame": initial["last_frame"],
        "target_numerator": initial["target_numerator"],
        "target_denominator": initial["target_denominator"],
        "tail_start_tick": initial["target_start_tick"],
        "tail_end_tick": initial["target_end_tick"],
        "tail_event_id": initial["event_id"],
        "tail_confidence_ppm": initial["confidence_ppm"],
        "media_object_sha256": initial["media_object_sha256"],
        "challenge_sha256": initial["challenge_sha256"],
        "tail_segment_sha256": initial["segment_sha256"],
        "previous_decision_sha256": genesis_decision_sha256,
        "policy_sha256": policy_root(),
    }
    timeline["timeline_sha256"] = timeline_root(timeline)
    return validate_timeline(timeline)


def validate_merge_inputs(
    timeline_value: Record,
    previous_value: Record,
    incoming_value: Record,
) -> tuple[Record, Record, Record]:
    timeline = validate_timeline(timeline_value)
    previous = segment_adapter.validate_segment(previous_value)
    incoming = segment_adapter.validate_segment(incoming_value)
    expected_index = previous["segment_index"] + 1
    try:
        _u64(expected_index)
    except VideoSegmentTimelineError:
        raise VideoSegmentTimelineError("invalid merge input") from None
    if (
        timeline["request_epoch"] != previous["request_epoch"]
        or timeline["request_epoch"] != incoming["request_epoch"]
        or timeline["tail_segment_index"] != previous["segment_index"]
        or incoming["segment_index"] != expected_index
        or incoming["generation"] < previous["generation"]
        or timeline["target_numerator"] != previous["target_numerator"]
        or timeline["target_denominator"] != previous["target_denominator"]
        or timeline["target_numerator"] != incoming["target_numerator"]
        or timeline["target_denominator"] != incoming["target_denominator"]
        or incoming["first_frame"] < timeline["tail_first_frame"]
        or incoming["target_start_tick"] < timeline["tail_start_tick"]
        or timeline["tail_first_frame"] > previous["first_frame"]
        or timeline["tail_last_frame"] < previous["last_frame"]
        or timeline["tail_start_tick"] > previous["target_start_tick"]
        or timeline["tail_end_tick"] < previous["target_end_tick"]
        or timeline["tail_event_id"] != previous["event_id"]
        or timeline["tail_confidence_ppm"] < previous["confidence_ppm"]
        or timeline["media_object_sha256"] != previous["media_object_sha256"]
        or timeline["media_object_sha256"] != incoming["media_object_sha256"]
        or timeline["challenge_sha256"] != previous["challenge_sha256"]
        or timeline["challenge_sha256"] != incoming["challenge_sha256"]
        or timeline["tail_segment_sha256"] != previous["segment_sha256"]
        or incoming["previous_segment_sha256"] != previous["segment_sha256"]
    ):
        raise VideoSegmentTimelineError("invalid merge input")
    return timeline, previous, incoming


def _receipt_body(receipt: Record) -> bytes:
    try:
        scalars = tuple(receipt[field] for field in RECEIPT_SCALARS)
        digests = tuple(receipt[field] for field in RECEIPT_DIGESTS)
    except (KeyError, TypeError):
        raise VideoSegmentTimelineError("invalid merge receipt") from None
    output = bytearray(MERGE_RECEIPT_BODY_BYTES)
    output[:32] = (
        MERGE_RECEIPT_MAGIC
        + _u64(MERGE_RECEIPT_ABI)
        + _u64(MERGE_RECEIPT_BYTES)
        + _u64(0)
    )
    output[32:160] = b"".join(_u64(value) for value in scalars)
    output[160:352] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def receipt_root(receipt: Record) -> bytes:
    return hashlib.sha256(MERGE_RECEIPT_DOMAIN + _receipt_body(receipt)).digest()


def validate_receipt(value: Record) -> Record:
    fields = RECEIPT_SCALARS + RECEIPT_DIGESTS + ("receipt_sha256",)
    try:
        receipt = {field: value[field] for field in fields}
        for field in RECEIPT_SCALARS:
            _u64(receipt[field])
        for field in RECEIPT_DIGESTS + ("receipt_sha256",):
            _digest(receipt[field])
        expected_incoming = receipt["previous_segment_index"] + 1
        _u64(expected_incoming)
    except (KeyError, TypeError, OverflowError):
        raise VideoSegmentTimelineError("invalid merge receipt") from None
    action = receipt["action"]
    if (
        receipt["request_epoch"] == 0
        or receipt["previous_segment_index"] == 0
        or receipt["incoming_segment_index"] != expected_incoming
        or action not in (COALESCE, RETAIN_DISTINCT)
        or receipt["output_first_frame"] > receipt["output_last_frame"]
        or receipt["target_numerator"] == 0
        or receipt["target_denominator"] == 0
        or receipt["output_start_tick"] >= receipt["output_end_tick"]
        or receipt["output_event_id"] == 0
        or receipt["output_confidence_ppm"] > 1_000_000
        or (
            action == COALESCE
            and (
                receipt["replaced_tail_count"] != 1
                or receipt["visible_segment_delta"] != 0
            )
        )
        or (
            action == RETAIN_DISTINCT
            and (
                receipt["replaced_tail_count"] != 0
                or receipt["visible_segment_delta"] != 1
            )
        )
        or receipt["policy_sha256"] != policy_root()
        or receipt["receipt_sha256"] != receipt_root(receipt)
    ):
        raise VideoSegmentTimelineError("invalid merge receipt")
    return receipt


def make_receipt(
    timeline_value: Record,
    previous_value: Record,
    incoming_value: Record,
) -> Record:
    timeline, previous, incoming = validate_merge_inputs(
        timeline_value,
        previous_value,
        incoming_value,
    )
    coalesced = (
        incoming["target_start_tick"] <= timeline["tail_end_tick"]
        and incoming["event_id"] == timeline["tail_event_id"]
    )
    if coalesced:
        action = COALESCE
        output_first_frame = timeline["tail_first_frame"]
        output_last_frame = max(
            timeline["tail_last_frame"],
            incoming["last_frame"],
        )
        output_start_tick = timeline["tail_start_tick"]
        output_end_tick = max(
            timeline["tail_end_tick"],
            incoming["target_end_tick"],
        )
        output_event_id = timeline["tail_event_id"]
        output_confidence_ppm = max(
            timeline["tail_confidence_ppm"],
            incoming["confidence_ppm"],
        )
    else:
        action = RETAIN_DISTINCT
        output_first_frame = incoming["first_frame"]
        output_last_frame = incoming["last_frame"]
        output_start_tick = incoming["target_start_tick"]
        output_end_tick = incoming["target_end_tick"]
        output_event_id = incoming["event_id"]
        output_confidence_ppm = incoming["confidence_ppm"]
    overlap = max(
        0,
        timeline["tail_end_tick"] - incoming["target_start_tick"],
    )
    receipt: Record = {
        "request_epoch": timeline["request_epoch"],
        "decision_sequence": timeline["next_sequence"],
        "previous_segment_index": previous["segment_index"],
        "incoming_segment_index": incoming["segment_index"],
        "action": action,
        "output_first_frame": output_first_frame,
        "output_last_frame": output_last_frame,
        "target_numerator": timeline["target_numerator"],
        "target_denominator": timeline["target_denominator"],
        "output_start_tick": output_start_tick,
        "output_end_tick": output_end_tick,
        "output_event_id": output_event_id,
        "output_confidence_ppm": output_confidence_ppm,
        "input_overlap_ticks": overlap,
        "replaced_tail_count": 1 if coalesced else 0,
        "visible_segment_delta": 0 if coalesced else 1,
        "media_object_sha256": timeline["media_object_sha256"],
        "challenge_sha256": timeline["challenge_sha256"],
        "previous_segment_sha256": previous["segment_sha256"],
        "incoming_segment_sha256": incoming["segment_sha256"],
        "previous_decision_sha256": timeline["previous_decision_sha256"],
        "policy_sha256": timeline["policy_sha256"],
    }
    receipt["receipt_sha256"] = receipt_root(receipt)
    return validate_receipt(receipt)


def apply_receipt(
    timeline_value: Record,
    previous_value: Record,
    incoming_value: Record,
    receipt_value: Record,
) -> Record:
    timeline = validate_timeline(timeline_value)
    receipt = validate_receipt(receipt_value)
    expected = make_receipt(
        timeline,
        previous_value,
        incoming_value,
    )
    if receipt != expected:
        raise VideoSegmentTimelineError("receipt does not match input")
    incoming = segment_adapter.validate_segment(incoming_value)
    next_sequence = timeline["next_sequence"] + 1
    decision_count = timeline["decision_count"] + 1
    visible_segments = timeline["visible_segments"] + receipt["visible_segment_delta"]
    for value in (next_sequence, decision_count, visible_segments):
        _u64(value)
    next_timeline: Record = {
        **timeline,
        "next_sequence": next_sequence,
        "decision_count": decision_count,
        "visible_segments": visible_segments,
        "tail_segment_index": incoming["segment_index"],
        "tail_first_frame": receipt["output_first_frame"],
        "tail_last_frame": receipt["output_last_frame"],
        "tail_start_tick": receipt["output_start_tick"],
        "tail_end_tick": receipt["output_end_tick"],
        "tail_event_id": receipt["output_event_id"],
        "tail_confidence_ppm": receipt["output_confidence_ppm"],
        "tail_segment_sha256": incoming["segment_sha256"],
        "previous_decision_sha256": receipt["receipt_sha256"],
    }
    next_timeline["timeline_sha256"] = timeline_root(next_timeline)
    return validate_timeline(next_timeline)


def encode_timeline(value: Record) -> bytes:
    timeline = validate_timeline(value)
    return _timeline_body(timeline) + timeline["timeline_sha256"]


def decode_timeline(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != TIMELINE_BYTES
        or encoded[:8] != TIMELINE_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != TIMELINE_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != TIMELINE_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[136:160])
        or any(encoded[320:352])
    ):
        raise VideoSegmentTimelineError("invalid timeline wire")
    timeline: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(TIMELINE_SCALARS)
    }
    timeline.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(TIMELINE_DIGESTS)
        }
    )
    timeline["timeline_sha256"] = encoded[TIMELINE_BODY_BYTES:]
    timeline = validate_timeline(timeline)
    if encode_timeline(timeline) != encoded:
        raise VideoSegmentTimelineError("non-canonical timeline")
    return timeline


def encode_receipt(value: Record) -> bytes:
    receipt = validate_receipt(value)
    return _receipt_body(receipt) + receipt["receipt_sha256"]


def decode_receipt(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != MERGE_RECEIPT_BYTES
        or encoded[:8] != MERGE_RECEIPT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != MERGE_RECEIPT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != MERGE_RECEIPT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
    ):
        raise VideoSegmentTimelineError("invalid merge receipt wire")
    receipt: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(RECEIPT_SCALARS)
    }
    receipt.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(RECEIPT_DIGESTS)
        }
    )
    receipt["receipt_sha256"] = encoded[MERGE_RECEIPT_BODY_BYTES:]
    receipt = validate_receipt(receipt)
    if encode_receipt(receipt) != encoded:
        raise VideoSegmentTimelineError("non-canonical merge receipt")
    return receipt
