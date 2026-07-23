"""Independent oracle for overlapping audio and transcript segment wires."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)
OVERLAP_PLAN_ABI = 0x414F565200000001
TRANSCRIPT_SEGMENT_ABI = 0x4154534700000001
OVERLAP_PLAN_BYTES = 512
TRANSCRIPT_SEGMENT_BYTES = 384
OVERLAP_BODY_BYTES = OVERLAP_PLAN_BYTES - 32
TRANSCRIPT_BODY_BYTES = TRANSCRIPT_SEGMENT_BYTES - 32
MAXIMUM_TEXT_BYTES = 64
OVERLAP_MAGIC = b"GAOVRP1\x00"
TRANSCRIPT_MAGIC = b"GATRNS1\x00"
OVERLAP_DOMAIN = b"glacier-audio-overlap-plan-v1\x00"
TRANSCRIPT_DOMAIN = b"glacier-audio-transcript-segment-v1\x00"

OVERLAP_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "source_start_sample",
    "source_end_sample",
    "context_start_sample",
    "context_end_sample",
    "publish_start_sample",
    "publish_end_sample",
    "sample_rate",
    "window_samples",
    "hop_samples",
    "feature_frames",
    "feature_bins",
    "feature_bytes",
)
OVERLAP_DIGESTS = (
    "media_object_sha256",
    "processor_state_sha256",
    "processor_bundle_sha256",
    "cache_bundle_sha256",
    "cache_payload_sha256",
    "ownership_sha256",
    "challenge_sha256",
    "previous_transcript_sha256",
)
TRANSCRIPT_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "context_start_sample",
    "context_end_sample",
    "publish_start_sample",
    "publish_end_sample",
    "sample_rate",
    "text_bytes",
)
TRANSCRIPT_DIGESTS = (
    "media_object_sha256",
    "processor_state_sha256",
    "cache_payload_sha256",
    "overlap_sha256",
    "previous_transcript_sha256",
)


class AudioTranscriptAdapterError(ValueError):
    """An overlap or transcript segment is invalid."""


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise AudioTranscriptAdapterError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or value == ZERO_DIGEST
    ):
        raise AudioTranscriptAdapterError("invalid digest")
    return value


def _overlap_body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in OVERLAP_SCALARS)
        digests = tuple(value[field] for field in OVERLAP_DIGESTS)
    except (KeyError, TypeError):
        raise AudioTranscriptAdapterError("invalid overlap plan") from None
    output = bytearray(OVERLAP_BODY_BYTES)
    output[:32] = b"".join(
        (
            OVERLAP_MAGIC,
            _u64(OVERLAP_PLAN_ABI),
            _u64(OVERLAP_PLAN_BYTES),
            _u64(0),
        )
    )
    output[32:152] = b"".join(_u64(value) for value in scalars)
    output[160:416] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def overlap_root(value: Record) -> bytes:
    return hashlib.sha256(OVERLAP_DOMAIN + _overlap_body(value)).digest()


def validate_overlap(value: Record) -> Record:
    fields = OVERLAP_SCALARS + OVERLAP_DIGESTS + ("overlap_sha256",)
    try:
        plan = {field: value[field] for field in fields}
        for field in OVERLAP_SCALARS:
            _u64(plan[field])
        for field in OVERLAP_DIGESTS + ("overlap_sha256",):
            _digest(plan[field])
    except (KeyError, TypeError):
        raise AudioTranscriptAdapterError("invalid overlap plan") from None
    source_units = (
        plan["source_end_sample"] - plan["source_start_sample"]
    )
    context_units = (
        plan["context_end_sample"] - plan["context_start_sample"]
    )
    publish_units = (
        plan["publish_end_sample"] - plan["publish_start_sample"]
    )
    expected_source_units = plan["window_samples"] + (
        plan["feature_frames"] - 1
    ) * plan["hop_samples"]
    if (
        min(
            plan["request_epoch"],
            plan["generation"],
            plan["segment_index"],
            plan["sample_rate"],
            plan["window_samples"],
            plan["hop_samples"],
            plan["feature_frames"],
            plan["feature_bins"],
            plan["feature_bytes"],
        )
        <= 0
        or plan["hop_samples"] >= plan["window_samples"]
        or source_units <= 0
        or context_units <= 0
        or publish_units <= 0
        or plan["context_start_sample"] != plan["source_start_sample"]
        or plan["context_end_sample"] != plan["publish_start_sample"]
        or plan["publish_end_sample"] != plan["source_end_sample"]
        or context_units
        != plan["window_samples"] - plan["hop_samples"]
        or source_units != expected_source_units
        or publish_units != source_units - context_units
        or plan["overlap_sha256"] != overlap_root(plan)
    ):
        raise AudioTranscriptAdapterError("invalid overlap plan")
    return plan


def make_overlap(
    *,
    audio_state: Record,
    processor_bundle_sha256: bytes,
    cache_bundle_sha256: bytes,
    segment_index: int,
    source_start_sample: int,
    previous_transcript_sha256: bytes,
) -> Record:
    try:
        context_samples = audio_state["parameters"][5]
        cursor_units = audio_state["cursor_units"]
        plan: Record = {
            "request_epoch": audio_state["request_epoch"],
            "generation": audio_state["generation"],
            "segment_index": segment_index,
            "source_start_sample": source_start_sample,
            "source_end_sample": source_start_sample + cursor_units,
            "context_start_sample": source_start_sample,
            "context_end_sample": source_start_sample + context_samples,
            "publish_start_sample": source_start_sample + context_samples,
            "publish_end_sample": source_start_sample + cursor_units,
            "sample_rate": audio_state["parameters"][0],
            "window_samples": audio_state["parameters"][2],
            "hop_samples": audio_state["parameters"][3],
            "feature_frames": audio_state["produced_units"],
            "feature_bins": audio_state["parameters"][4],
            "feature_bytes": audio_state["parameters"][6],
            "media_object_sha256": audio_state["media_object_sha256"],
            "processor_state_sha256": audio_state["state_sha256"],
            "processor_bundle_sha256": processor_bundle_sha256,
            "cache_bundle_sha256": cache_bundle_sha256,
            "cache_payload_sha256": audio_state["cache_content_sha256"],
            "ownership_sha256": audio_state[
                "ownership_receipt_sha256"
            ],
            "challenge_sha256": audio_state["challenge_sha256"],
            "previous_transcript_sha256": previous_transcript_sha256,
        }
    except (KeyError, IndexError, TypeError):
        raise AudioTranscriptAdapterError("invalid audio state") from None
    plan["overlap_sha256"] = overlap_root(plan)
    return validate_overlap(plan)


def encode_overlap(value: Record) -> bytes:
    plan = validate_overlap(value)
    return _overlap_body(plan) + plan["overlap_sha256"]


def decode_overlap(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != OVERLAP_PLAN_BYTES
        or encoded[:8] != OVERLAP_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != OVERLAP_PLAN_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != OVERLAP_PLAN_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[152:160])
        or any(encoded[416:OVERLAP_BODY_BYTES])
    ):
        raise AudioTranscriptAdapterError("invalid overlap wire")
    plan: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(OVERLAP_SCALARS)
    }
    plan.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(OVERLAP_DIGESTS)
        }
    )
    plan["overlap_sha256"] = encoded[OVERLAP_BODY_BYTES:]
    plan = validate_overlap(plan)
    if encode_overlap(plan) != encoded:
        raise AudioTranscriptAdapterError("non-canonical overlap wire")
    return plan


def _transcript_body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in TRANSCRIPT_SCALARS)
        digests = tuple(value[field] for field in TRANSCRIPT_DIGESTS)
        text = value["text"]
    except (KeyError, TypeError):
        raise AudioTranscriptAdapterError("invalid transcript") from None
    if not isinstance(text, bytes) or len(text) != MAXIMUM_TEXT_BYTES:
        raise AudioTranscriptAdapterError("invalid transcript text")
    output = bytearray(TRANSCRIPT_BODY_BYTES)
    output[:32] = b"".join(
        (
            TRANSCRIPT_MAGIC,
            _u64(TRANSCRIPT_SEGMENT_ABI),
            _u64(TRANSCRIPT_SEGMENT_BYTES),
            _u64(0),
        )
    )
    output[32:104] = b"".join(_u64(value) for value in scalars)
    output[128:288] = b"".join(_digest(value) for value in digests)
    output[288:352] = text
    return bytes(output)


def transcript_root(value: Record) -> bytes:
    return hashlib.sha256(
        TRANSCRIPT_DOMAIN + _transcript_body(value)
    ).digest()


def validate_transcript(value: Record) -> Record:
    fields = (
        TRANSCRIPT_SCALARS
        + TRANSCRIPT_DIGESTS
        + ("text", "transcript_sha256")
    )
    try:
        segment = {field: value[field] for field in fields}
        for field in TRANSCRIPT_SCALARS:
            _u64(segment[field])
        for field in TRANSCRIPT_DIGESTS + ("transcript_sha256",):
            _digest(segment[field])
        text = segment["text"]
    except (KeyError, TypeError):
        raise AudioTranscriptAdapterError("invalid transcript") from None
    text_bytes = segment["text_bytes"]
    if (
        not isinstance(text, bytes)
        or len(text) != MAXIMUM_TEXT_BYTES
        or min(
            segment["request_epoch"],
            segment["generation"],
            segment["segment_index"],
            segment["sample_rate"],
            text_bytes,
        )
        <= 0
        or text_bytes > MAXIMUM_TEXT_BYTES
        or segment["context_start_sample"]
        >= segment["context_end_sample"]
        or segment["context_end_sample"]
        != segment["publish_start_sample"]
        or segment["publish_start_sample"]
        >= segment["publish_end_sample"]
        or any(text[text_bytes:])
        or any(byte < 0x20 or byte > 0x7E for byte in text[:text_bytes])
        or segment["transcript_sha256"] != transcript_root(segment)
    ):
        raise AudioTranscriptAdapterError("invalid transcript")
    return segment


def make_transcript(overlap_value: Record, text_value: bytes) -> Record:
    plan = validate_overlap(overlap_value)
    if (
        not isinstance(text_value, bytes)
        or not 0 < len(text_value) <= MAXIMUM_TEXT_BYTES
    ):
        raise AudioTranscriptAdapterError("invalid transcript text")
    text = text_value + bytes(MAXIMUM_TEXT_BYTES - len(text_value))
    segment: Record = {
        "request_epoch": plan["request_epoch"],
        "generation": plan["generation"],
        "segment_index": plan["segment_index"],
        "context_start_sample": plan["context_start_sample"],
        "context_end_sample": plan["context_end_sample"],
        "publish_start_sample": plan["publish_start_sample"],
        "publish_end_sample": plan["publish_end_sample"],
        "sample_rate": plan["sample_rate"],
        "text_bytes": len(text_value),
        "media_object_sha256": plan["media_object_sha256"],
        "processor_state_sha256": plan["processor_state_sha256"],
        "cache_payload_sha256": plan["cache_payload_sha256"],
        "overlap_sha256": plan["overlap_sha256"],
        "previous_transcript_sha256": plan[
            "previous_transcript_sha256"
        ],
        "text": text,
    }
    segment["transcript_sha256"] = transcript_root(segment)
    return validate_transcript(segment)


def validate_transcript_for_overlap(
    transcript_value: Record,
    overlap_value: Record,
) -> Record:
    segment = validate_transcript(transcript_value)
    plan = validate_overlap(overlap_value)
    bindings = (
        ("request_epoch", "request_epoch"),
        ("generation", "generation"),
        ("segment_index", "segment_index"),
        ("context_start_sample", "context_start_sample"),
        ("context_end_sample", "context_end_sample"),
        ("publish_start_sample", "publish_start_sample"),
        ("publish_end_sample", "publish_end_sample"),
        ("sample_rate", "sample_rate"),
        ("media_object_sha256", "media_object_sha256"),
        ("processor_state_sha256", "processor_state_sha256"),
        ("cache_payload_sha256", "cache_payload_sha256"),
        ("overlap_sha256", "overlap_sha256"),
        (
            "previous_transcript_sha256",
            "previous_transcript_sha256",
        ),
    )
    if any(segment[left] != plan[right] for left, right in bindings):
        raise AudioTranscriptAdapterError(
            "transcript does not match overlap"
        )
    return segment


def validate_predecessor(
    overlap_value: Record,
    previous_value: Record,
) -> Record:
    plan = validate_overlap(overlap_value)
    previous = validate_transcript(previous_value)
    if (
        previous["segment_index"] + 1 != plan["segment_index"]
        or previous["request_epoch"] != plan["request_epoch"]
        or previous["sample_rate"] != plan["sample_rate"]
        or previous["publish_end_sample"] != plan["publish_start_sample"]
        or previous["media_object_sha256"]
        != plan["media_object_sha256"]
        or previous["transcript_sha256"]
        != plan["previous_transcript_sha256"]
    ):
        raise AudioTranscriptAdapterError(
            "invalid transcript predecessor"
        )
    return previous


def encode_transcript(value: Record) -> bytes:
    segment = validate_transcript(value)
    return _transcript_body(segment) + segment["transcript_sha256"]


def decode_transcript(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != TRANSCRIPT_SEGMENT_BYTES
        or encoded[:8] != TRANSCRIPT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0]
        != TRANSCRIPT_SEGMENT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0]
        != TRANSCRIPT_SEGMENT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[104:128])
    ):
        raise AudioTranscriptAdapterError("invalid transcript wire")
    segment: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(TRANSCRIPT_SCALARS)
    }
    segment.update(
        {
            field: encoded[128 + index * 32 : 160 + index * 32]
            for index, field in enumerate(TRANSCRIPT_DIGESTS)
        }
    )
    segment["text"] = encoded[288:352]
    segment["transcript_sha256"] = encoded[TRANSCRIPT_BODY_BYTES:]
    segment = validate_transcript(segment)
    if encode_transcript(segment) != encoded:
        raise AudioTranscriptAdapterError(
            "non-canonical transcript wire"
        )
    return segment
