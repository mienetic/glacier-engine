"""Independent oracle for canonical typed video-segment results."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class VideoSegmentAdapterError(ValueError):
    """A video segment, source binding, or wire is invalid."""


Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
VIDEO_SEGMENT_ABI = 0x4756534547000001
VIDEO_SEGMENT_BYTES = 512
VIDEO_SEGMENT_BODY_BYTES = VIDEO_SEGMENT_BYTES - 32
VIDEO_SEGMENT_MAGIC = b"GVSEG1\x00\x00"
VIDEO_SEGMENT_DOMAIN = b"glacier-video-segment-v1\x00"
SEGMENT_SOURCE_DOMAIN = b"glacier-video-segment-source-v1\x00"
SCALAR_FIELDS = (
    "request_epoch",
    "generation",
    "segment_index",
    "first_frame",
    "last_frame",
    "frame_count",
    "frame_stride",
    "keyframe_ordinal",
    "eviction_boundary",
    "cache_generation",
    "target_numerator",
    "target_denominator",
    "target_start_tick",
    "target_end_tick",
    "event_id",
    "confidence_ppm",
)
DIGEST_FIELDS = (
    "media_object_sha256",
    "processor_state_sha256",
    "processor_bundle_sha256",
    "cache_bundle_sha256",
    "cache_payload_sha256",
    "ownership_sha256",
    "selection_sha256",
    "challenge_sha256",
    "previous_segment_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise VideoSegmentAdapterError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or not any(value):
        raise VideoSegmentAdapterError("invalid digest")
    return value


def schema_root() -> bytes:
    return hashlib.sha256(b"glacier video segment v1 512-byte wire").digest()


def segment_source_root(
    plan: Record,
    selection: Record,
    segment_index: int,
    previous_segment_sha256: bytes,
) -> bytes:
    try:
        body = b"".join(
            (
                _u64(plan["request_epoch"]),
                _u64(plan["generation"]),
                _u64(segment_index),
                _digest(plan["media_object_sha256"]),
                _digest(plan["processor_state_sha256"]),
                _digest(plan["processor_bundle_sha256"]),
                _digest(plan["cache_bundle_sha256"]),
                _digest(plan["cache_payload_sha256"]),
                _digest(plan["ownership_sha256"]),
                _digest(selection["selection_sha256"]),
                _digest(plan["challenge_sha256"]),
                _digest(previous_segment_sha256),
            )
        )
    except (KeyError, TypeError):
        raise VideoSegmentAdapterError("invalid video segment source") from None
    return hashlib.sha256(SEGMENT_SOURCE_DOMAIN + body).digest()


def _body(segment: Record) -> bytes:
    try:
        scalars = tuple(segment[field] for field in SCALAR_FIELDS)
        digests = tuple(segment[field] for field in DIGEST_FIELDS)
    except (KeyError, TypeError):
        raise VideoSegmentAdapterError("invalid video segment") from None
    output = bytearray(VIDEO_SEGMENT_BODY_BYTES)
    output[:32] = (
        VIDEO_SEGMENT_MAGIC
        + _u64(VIDEO_SEGMENT_ABI)
        + _u64(VIDEO_SEGMENT_BYTES)
        + _u64(0)
    )
    output[32:160] = b"".join(_u64(value) for value in scalars)
    output[160:448] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def segment_root(segment: Record) -> bytes:
    return hashlib.sha256(VIDEO_SEGMENT_DOMAIN + _body(segment)).digest()


def validate_segment(value: Record) -> Record:
    fields = SCALAR_FIELDS + DIGEST_FIELDS + ("segment_sha256",)
    try:
        segment = {field: value[field] for field in fields}
        for field in SCALAR_FIELDS:
            _u64(segment[field])
        for field in DIGEST_FIELDS + ("segment_sha256",):
            _digest(segment[field])
        expected_last = (
            segment["first_frame"]
            + (segment["frame_count"] - 1) * segment["frame_stride"]
        )
    except (KeyError, TypeError, OverflowError):
        raise VideoSegmentAdapterError("invalid video segment") from None
    if (
        segment["request_epoch"] == 0
        or segment["generation"] == 0
        or segment["segment_index"] == 0
        or segment["frame_count"] == 0
        or segment["frame_stride"] == 0
        or expected_last > U64_MAX
        or segment["last_frame"] != expected_last
        or segment["keyframe_ordinal"] > segment["first_frame"]
        or segment["eviction_boundary"] > segment["first_frame"]
        or segment["target_numerator"] == 0
        or segment["target_denominator"] == 0
        or segment["target_start_tick"] >= segment["target_end_tick"]
        or segment["event_id"] == 0
        or segment["confidence_ppm"] > 1_000_000
        or segment["segment_sha256"] != segment_root(segment)
    ):
        raise VideoSegmentAdapterError("invalid video segment")
    return segment


def make_segment(
    plan: Record,
    selection: Record,
    segment_index: int,
    previous_segment_sha256: bytes,
    event_id: int,
    confidence_ppm: int,
) -> Record:
    source_root = segment_source_root(
        plan,
        selection,
        segment_index,
        previous_segment_sha256,
    )
    try:
        if (
            plan["family"] != 6
            or plan["operation"] != 10
            or plan["input_kind"] != 5
            or plan["output_kind"] != 10
            or plan["numerical_policy"] != 1
            or plan["batch_items"] != 1
            or plan["output_dimensions"] != VIDEO_SEGMENT_BYTES
            or plan["input_element_bytes"] != 1
            or plan["output_element_bytes"] != 1
            or source_root != plan["input_schema_sha256"]
            or schema_root() != plan["output_schema_sha256"]
        ):
            raise VideoSegmentAdapterError("video segment schema mismatch")
        segment: Record = {
            "request_epoch": plan["request_epoch"],
            "generation": plan["generation"],
            "segment_index": segment_index,
            "first_frame": selection["first_frame"],
            "last_frame": selection["last_frame"],
            "frame_count": selection["frame_count"],
            "frame_stride": selection["frame_stride"],
            "keyframe_ordinal": selection["keyframe_ordinal"],
            "eviction_boundary": selection["eviction_boundary"],
            "cache_generation": selection["cache_generation"],
            "target_numerator": selection["target_numerator"],
            "target_denominator": selection["target_denominator"],
            "target_start_tick": selection["target_start_tick"],
            "target_end_tick": selection["target_end_tick"],
            "event_id": event_id,
            "confidence_ppm": confidence_ppm,
            "media_object_sha256": plan["media_object_sha256"],
            "processor_state_sha256": plan["processor_state_sha256"],
            "processor_bundle_sha256": plan["processor_bundle_sha256"],
            "cache_bundle_sha256": plan["cache_bundle_sha256"],
            "cache_payload_sha256": plan["cache_payload_sha256"],
            "ownership_sha256": plan["ownership_sha256"],
            "selection_sha256": selection["selection_sha256"],
            "challenge_sha256": plan["challenge_sha256"],
            "previous_segment_sha256": previous_segment_sha256,
        }
    except (KeyError, TypeError):
        raise VideoSegmentAdapterError("invalid video segment") from None
    segment["segment_sha256"] = segment_root(segment)
    return validate_segment(segment)


def encode_segment(value: Record) -> bytes:
    segment = validate_segment(value)
    return _body(segment) + segment["segment_sha256"]


def decode_segment(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != VIDEO_SEGMENT_BYTES
        or encoded[:8] != VIDEO_SEGMENT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != VIDEO_SEGMENT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != VIDEO_SEGMENT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[448:480])
    ):
        raise VideoSegmentAdapterError("invalid video segment wire")
    segment: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(SCALAR_FIELDS)
    }
    segment.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(DIGEST_FIELDS)
        }
    )
    segment["segment_sha256"] = encoded[VIDEO_SEGMENT_BODY_BYTES:]
    segment = validate_segment(segment)
    if encode_segment(segment) != encoded:
        raise VideoSegmentAdapterError("non-canonical video segment wire")
    return segment
