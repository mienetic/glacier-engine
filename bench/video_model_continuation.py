"""Independent oracle for stateful VFR video continuation composition."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import audio_transcript_adapter as audio
from bench import audio_video_result_link as result_link
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as model_continuation
from bench import stateful_video_adapter as video_model
from bench import video_segment_adapter as video_segment
from bench import video_segment_timeline as video_timeline


class VideoModelContinuationError(ValueError):
    """A VFR video continuation checkpoint or binding is invalid."""


Record = dict[str, Any]
CHECKPOINT_ABI = 0x47564D4350000001
CHECKPOINT_BYTES = 768
CHECKPOINT_BODY_BYTES = CHECKPOINT_BYTES - 32
CHECKPOINT_MAGIC = b"GVMCP1\x00\x00"
CHECKPOINT_DOMAIN = b"glacier-video-model-continuation-v1\x00"
SCALAR_FIELDS = (
    "request_epoch",
    "completed_generation",
    "next_generation",
    "next_segment_index",
    "next_first_frame_ordinal",
    "next_frame_count",
    "next_previous_end_tick",
    "next_start_tick",
    "next_end_tick",
    "next_discontinuity_ticks",
    "target_numerator",
    "target_denominator",
    "state_bytes",
    "source_bank_epoch",
    "restore_bank_epoch",
    "model_publication_next_sequence",
    "timeline_next_sequence",
    "timeline_visible_segments",
    "link_next_sequence",
    "visible_links",
)
DIGEST_FIELDS = (
    "stateful_checkpoint_sha256",
    "state_publication_sha256",
    "restored_state_sha256",
    "previous_window_sha256",
    "previous_segment_sha256",
    "next_window_sha256",
    "video_timeline_sha256",
    "previous_overlap_sha256",
    "previous_transcript_sha256",
    "next_overlap_sha256",
    "next_transcript_sha256",
    "link_state_sha256",
    "previous_link_sha256",
    "audio_media_sha256",
    "video_media_sha256",
    "challenge_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= model.U64_MAX:
        raise VideoModelContinuationError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or not any(value):
        raise VideoModelContinuationError("invalid digest")
    return value


def _body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in SCALAR_FIELDS)
        digests = tuple(value[field] for field in DIGEST_FIELDS)
    except (KeyError, TypeError):
        raise VideoModelContinuationError("invalid checkpoint") from None
    output = bytearray(CHECKPOINT_BODY_BYTES)
    output[:32] = (
        CHECKPOINT_MAGIC
        + _u64(CHECKPOINT_ABI)
        + _u64(CHECKPOINT_BYTES)
        + _u64(0)
    )
    output[32:192] = b"".join(_u64(value) for value in scalars)
    output[224:736] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def checkpoint_root(value: Record) -> bytes:
    return hashlib.sha256(CHECKPOINT_DOMAIN + _body(value)).digest()


def validate_checkpoint(value: Record) -> Record:
    fields = SCALAR_FIELDS + DIGEST_FIELDS + ("checkpoint_sha256",)
    try:
        checkpoint = {field: value[field] for field in fields}
        for field in SCALAR_FIELDS:
            _u64(checkpoint[field])
        for field in DIGEST_FIELDS + ("checkpoint_sha256",):
            _digest(checkpoint[field])
        expected_next = checkpoint["completed_generation"] + 1
        _u64(expected_next)
    except (KeyError, TypeError):
        raise VideoModelContinuationError("invalid checkpoint") from None
    if (
        checkpoint["request_epoch"] == 0
        or checkpoint["completed_generation"] == 0
        or checkpoint["next_generation"] != expected_next
        or checkpoint["next_segment_index"] == 0
        or not 0
        < checkpoint["next_frame_count"]
        <= video_model.FRAME_CAPACITY
        or checkpoint["next_start_tick"]
        < checkpoint["next_previous_end_tick"]
        or checkpoint["next_start_tick"] >= checkpoint["next_end_tick"]
        or checkpoint["next_discontinuity_ticks"]
        != checkpoint["next_start_tick"]
        - checkpoint["next_previous_end_tick"]
        or checkpoint["target_numerator"] == 0
        or checkpoint["target_denominator"] == 0
        or checkpoint["state_bytes"] == 0
        or checkpoint["source_bank_epoch"] == 0
        or checkpoint["restore_bank_epoch"] == 0
        or checkpoint["source_bank_epoch"]
        == checkpoint["restore_bank_epoch"]
        or checkpoint["model_publication_next_sequence"]
        != checkpoint["completed_generation"]
        or checkpoint["timeline_visible_segments"] == 0
        or checkpoint["link_next_sequence"] != checkpoint["visible_links"]
        or checkpoint["visible_links"] == 0
        or checkpoint["checkpoint_sha256"] != checkpoint_root(checkpoint)
    ):
        raise VideoModelContinuationError("invalid checkpoint")
    return checkpoint


def _segment_matches_window(segment: Record, window: Record) -> bool:
    return (
        segment["request_epoch"] == window["request_epoch"]
        and segment["generation"] == window["generation"]
        and segment["segment_index"] == window["segment_index"]
        and segment["first_frame"] == window["first_frame_ordinal"]
        and segment["last_frame"]
        == window["frame_ordinals"][window["frame_count"] - 1]
        and segment["frame_count"] == window["frame_count"]
        and segment["frame_stride"] == 1
        and segment["keyframe_ordinal"]
        == window["frame_ordinals"][window["keyframe_flags"].index(1)]
        and segment["eviction_boundary"] == window["first_frame_ordinal"]
        and segment["cache_generation"] == window["generation"]
        and segment["target_numerator"] == window["target_numerator"]
        and segment["target_denominator"] == window["target_denominator"]
        and segment["target_start_tick"] == window["start_tick"]
        and segment["target_end_tick"] == window["end_tick"]
        and segment["media_object_sha256"] == window["media_object_sha256"]
        and segment["processor_bundle_sha256"]
        == window["processor_bundle_sha256"]
        and segment["cache_bundle_sha256"]
        == window["cache_bundle_sha256"]
        and segment["ownership_sha256"] == window["ownership_sha256"]
        and segment["selection_sha256"] == window["window_sha256"]
        and segment["challenge_sha256"] == window["challenge_sha256"]
    )


def validate_bindings(
    checkpoint_value: Record,
    stateful_checkpoint_value: Record,
    state_publication_value: Record,
    previous_window_value: Record,
    previous_segment_value: Record,
    next_window_value: Record,
    timeline_value: Record,
    previous_overlap_value: Record,
    previous_transcript_value: Record,
    next_overlap_value: Record,
    next_transcript_value: Record,
    previous_link_value: Record,
    link_state_value: Record,
) -> tuple[Record, ...]:
    checkpoint = validate_checkpoint(checkpoint_value)
    try:
        stateful_checkpoint = model_continuation.validate_checkpoint(
            stateful_checkpoint_value
        )
        state_publication = stateful.validate_publication(
            state_publication_value
        )
        previous_window = video_model.validate_window(previous_window_value)
        previous_segment = video_segment.validate_segment(
            previous_segment_value
        )
        next_window = video_model.validate_window(next_window_value)
        video_model.validate_predecessor(previous_window, next_window)
        timeline = video_timeline.validate_timeline(timeline_value)
        previous_overlap = audio.validate_overlap(previous_overlap_value)
        previous_transcript = audio.validate_transcript_for_overlap(
            previous_transcript_value,
            previous_overlap,
        )
        next_overlap = audio.validate_overlap(next_overlap_value)
        next_transcript = audio.validate_transcript_for_overlap(
            next_transcript_value,
            next_overlap,
        )
        audio.validate_predecessor(next_overlap, previous_transcript)
        previous_link = result_link.validate_link(previous_link_value)
        link_state = result_link.validate_state(link_state_value)
        previous_link_state = {
            **link_state,
            "next_sequence": previous_link["link_sequence"],
            "visible_links": previous_link["link_sequence"],
            "last_link_index": previous_link["link_sequence"],
            "previous_link_sha256": previous_link[
                "previous_link_sha256"
            ],
        }
        previous_link_state["state_sha256"] = result_link.state_root(
            previous_link_state
        )
        expected_previous_link = result_link.make_link(
            previous_link_state,
            previous_overlap,
            previous_transcript,
            timeline,
        )
    except (
        audio.AudioTranscriptAdapterError,
        result_link.AudioVideoResultLinkError,
        stateful.StatefulModelAdapterError,
        model_continuation.StatefulModelContinuationError,
        video_model.StatefulVideoAdapterError,
        video_segment.VideoSegmentAdapterError,
        video_timeline.VideoSegmentTimelineError,
    ) as error:
        raise VideoModelContinuationError(
            "invalid checkpoint binding"
        ) from error
    expected_next_segment = previous_segment["segment_index"] + 1
    expected_next_link = previous_link["link_sequence"] + 1
    previous_segment_wire = video_segment.encode_segment(previous_segment)
    if (
        not _segment_matches_window(previous_segment, previous_window)
        or previous_link != expected_previous_link
        or checkpoint["request_epoch"]
        != stateful_checkpoint["request_epoch"]
        or checkpoint["request_epoch"] != state_publication["request_epoch"]
        or checkpoint["request_epoch"] != previous_window["request_epoch"]
        or checkpoint["request_epoch"] != previous_segment["request_epoch"]
        or checkpoint["request_epoch"] != next_window["request_epoch"]
        or checkpoint["request_epoch"] != timeline["request_epoch"]
        or checkpoint["request_epoch"] != previous_overlap["request_epoch"]
        or checkpoint["request_epoch"] != next_overlap["request_epoch"]
        or checkpoint["request_epoch"] != link_state["request_epoch"]
        or checkpoint["completed_generation"]
        != stateful_checkpoint["current_step"]
        or checkpoint["completed_generation"] != previous_window["generation"]
        or checkpoint["completed_generation"]
        != previous_segment["generation"]
        or checkpoint["next_generation"] != next_window["generation"]
        or checkpoint["next_segment_index"] != expected_next_segment
        or checkpoint["next_segment_index"] != next_window["segment_index"]
        or checkpoint["next_first_frame_ordinal"]
        != next_window["first_frame_ordinal"]
        or checkpoint["next_frame_count"] != next_window["frame_count"]
        or checkpoint["next_previous_end_tick"]
        != next_window["previous_end_tick"]
        or checkpoint["next_start_tick"] != next_window["start_tick"]
        or checkpoint["next_end_tick"] != next_window["end_tick"]
        or checkpoint["next_discontinuity_ticks"]
        != next_window["discontinuity_before_ticks"]
        or checkpoint["target_numerator"] != next_window["target_numerator"]
        or checkpoint["target_denominator"]
        != next_window["target_denominator"]
        or checkpoint["state_bytes"] != stateful_checkpoint["state_bytes"]
        or checkpoint["state_bytes"] != state_publication["state_bytes"]
        or checkpoint["source_bank_epoch"]
        != stateful_checkpoint["source_bank_epoch"]
        or checkpoint["restore_bank_epoch"]
        != stateful_checkpoint["restore_bank_epoch"]
        or checkpoint["model_publication_next_sequence"]
        != stateful_checkpoint["publication_next_sequence"]
        or checkpoint["timeline_next_sequence"] != timeline["next_sequence"]
        or checkpoint["timeline_visible_segments"]
        != timeline["visible_segments"]
        or checkpoint["link_next_sequence"] != link_state["next_sequence"]
        or checkpoint["link_next_sequence"] != expected_next_link
        or checkpoint["visible_links"] != link_state["visible_links"]
        or checkpoint["visible_links"] != previous_link["link_index"]
        or timeline["tail_segment_index"] != previous_segment["segment_index"]
        or timeline["tail_first_frame"] != previous_segment["first_frame"]
        or timeline["tail_last_frame"] != previous_segment["last_frame"]
        or timeline["target_numerator"]
        != previous_segment["target_numerator"]
        or timeline["target_denominator"]
        != previous_segment["target_denominator"]
        or timeline["tail_start_tick"]
        != previous_segment["target_start_tick"]
        or timeline["tail_end_tick"] != previous_segment["target_end_tick"]
        or timeline["tail_segment_sha256"]
        != previous_segment["segment_sha256"]
        or checkpoint["stateful_checkpoint_sha256"]
        != stateful_checkpoint["checkpoint_sha256"]
        or checkpoint["state_publication_sha256"]
        != state_publication["publication_sha256"]
        or stateful_checkpoint["state_publication_sha256"]
        != state_publication["publication_sha256"]
        or checkpoint["restored_state_sha256"]
        != state_publication["current_state_sha256"]
        or stateful_checkpoint["current_state_sha256"]
        != state_publication["current_state_sha256"]
        or stateful_checkpoint["last_output_sha256"]
        != model.sha256(previous_segment_wire)
        or checkpoint["previous_window_sha256"]
        != previous_window["window_sha256"]
        or checkpoint["previous_segment_sha256"]
        != previous_segment["segment_sha256"]
        or checkpoint["next_window_sha256"] != next_window["window_sha256"]
        or checkpoint["video_timeline_sha256"] != timeline["timeline_sha256"]
        or checkpoint["previous_overlap_sha256"]
        != previous_overlap["overlap_sha256"]
        or checkpoint["previous_transcript_sha256"]
        != previous_transcript["transcript_sha256"]
        or checkpoint["next_overlap_sha256"] != next_overlap["overlap_sha256"]
        or checkpoint["next_transcript_sha256"]
        != next_transcript["transcript_sha256"]
        or checkpoint["link_state_sha256"] != link_state["state_sha256"]
        or checkpoint["previous_link_sha256"] != previous_link["link_sha256"]
        or checkpoint["previous_link_sha256"]
        != link_state["previous_link_sha256"]
        or checkpoint["audio_media_sha256"]
        != previous_overlap["media_object_sha256"]
        or checkpoint["audio_media_sha256"]
        != next_overlap["media_object_sha256"]
        or checkpoint["audio_media_sha256"]
        != link_state["audio_media_sha256"]
        or checkpoint["video_media_sha256"]
        != previous_window["media_object_sha256"]
        or checkpoint["video_media_sha256"]
        != next_window["media_object_sha256"]
        or checkpoint["video_media_sha256"]
        != timeline["media_object_sha256"]
        or checkpoint["video_media_sha256"]
        != link_state["video_media_sha256"]
    ):
        raise VideoModelContinuationError("invalid checkpoint binding")
    challenge = checkpoint["challenge_sha256"]
    if any(
        challenge != value
        for value in (
            stateful_checkpoint["challenge_sha256"],
            state_publication["challenge_sha256"],
            previous_window["challenge_sha256"],
            next_window["challenge_sha256"],
            timeline["challenge_sha256"],
            previous_overlap["challenge_sha256"],
            next_overlap["challenge_sha256"],
            link_state["challenge_sha256"],
        )
    ):
        raise VideoModelContinuationError("invalid challenge binding")
    return (
        checkpoint,
        stateful_checkpoint,
        state_publication,
        previous_window,
        previous_segment,
        next_window,
        timeline,
        previous_overlap,
        previous_transcript,
        next_overlap,
        next_transcript,
        previous_link,
        link_state,
    )


def make_checkpoint(
    stateful_checkpoint_value: Record,
    state_publication_value: Record,
    previous_window_value: Record,
    previous_segment_value: Record,
    next_window_value: Record,
    timeline_value: Record,
    previous_overlap_value: Record,
    previous_transcript_value: Record,
    next_overlap_value: Record,
    next_transcript_value: Record,
    previous_link_value: Record,
    link_state_value: Record,
) -> Record:
    stateful_checkpoint = model_continuation.validate_checkpoint(
        stateful_checkpoint_value
    )
    state_publication = stateful.validate_publication(
        state_publication_value
    )
    previous_window = video_model.validate_window(previous_window_value)
    previous_segment = video_segment.validate_segment(previous_segment_value)
    next_window = video_model.validate_window(next_window_value)
    timeline = video_timeline.validate_timeline(timeline_value)
    previous_overlap = audio.validate_overlap(previous_overlap_value)
    previous_transcript = audio.validate_transcript_for_overlap(
        previous_transcript_value,
        previous_overlap,
    )
    next_overlap = audio.validate_overlap(next_overlap_value)
    next_transcript = audio.validate_transcript_for_overlap(
        next_transcript_value,
        next_overlap,
    )
    previous_link = result_link.validate_link(previous_link_value)
    link_state = result_link.validate_state(link_state_value)
    checkpoint: Record = {
        "request_epoch": stateful_checkpoint["request_epoch"],
        "completed_generation": stateful_checkpoint["current_step"],
        "next_generation": stateful_checkpoint["current_step"] + 1,
        "next_segment_index": next_window["segment_index"],
        "next_first_frame_ordinal": next_window["first_frame_ordinal"],
        "next_frame_count": next_window["frame_count"],
        "next_previous_end_tick": next_window["previous_end_tick"],
        "next_start_tick": next_window["start_tick"],
        "next_end_tick": next_window["end_tick"],
        "next_discontinuity_ticks": next_window[
            "discontinuity_before_ticks"
        ],
        "target_numerator": next_window["target_numerator"],
        "target_denominator": next_window["target_denominator"],
        "state_bytes": stateful_checkpoint["state_bytes"],
        "source_bank_epoch": stateful_checkpoint["source_bank_epoch"],
        "restore_bank_epoch": stateful_checkpoint["restore_bank_epoch"],
        "model_publication_next_sequence": stateful_checkpoint[
            "publication_next_sequence"
        ],
        "timeline_next_sequence": timeline["next_sequence"],
        "timeline_visible_segments": timeline["visible_segments"],
        "link_next_sequence": link_state["next_sequence"],
        "visible_links": link_state["visible_links"],
        "stateful_checkpoint_sha256": stateful_checkpoint[
            "checkpoint_sha256"
        ],
        "state_publication_sha256": state_publication[
            "publication_sha256"
        ],
        "restored_state_sha256": state_publication[
            "current_state_sha256"
        ],
        "previous_window_sha256": previous_window["window_sha256"],
        "previous_segment_sha256": previous_segment["segment_sha256"],
        "next_window_sha256": next_window["window_sha256"],
        "video_timeline_sha256": timeline["timeline_sha256"],
        "previous_overlap_sha256": previous_overlap["overlap_sha256"],
        "previous_transcript_sha256": previous_transcript[
            "transcript_sha256"
        ],
        "next_overlap_sha256": next_overlap["overlap_sha256"],
        "next_transcript_sha256": next_transcript["transcript_sha256"],
        "link_state_sha256": link_state["state_sha256"],
        "previous_link_sha256": previous_link["link_sha256"],
        "audio_media_sha256": previous_overlap["media_object_sha256"],
        "video_media_sha256": previous_window["media_object_sha256"],
        "challenge_sha256": stateful_checkpoint["challenge_sha256"],
    }
    checkpoint["checkpoint_sha256"] = checkpoint_root(checkpoint)
    validate_bindings(
        checkpoint,
        stateful_checkpoint,
        state_publication,
        previous_window,
        previous_segment,
        next_window,
        timeline,
        previous_overlap,
        previous_transcript,
        next_overlap,
        next_transcript,
        previous_link,
        link_state,
    )
    return checkpoint


def encode_checkpoint(value: Record) -> bytes:
    checkpoint = validate_checkpoint(value)
    return _body(checkpoint) + checkpoint["checkpoint_sha256"]


def decode_checkpoint(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != CHECKPOINT_BYTES
        or encoded[:8] != CHECKPOINT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != CHECKPOINT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != CHECKPOINT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[192:224])
    ):
        raise VideoModelContinuationError("invalid checkpoint wire")
    checkpoint: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(SCALAR_FIELDS)
    }
    checkpoint.update(
        {
            field: encoded[224 + index * 32 : 256 + index * 32]
            for index, field in enumerate(DIGEST_FIELDS)
        }
    )
    checkpoint["checkpoint_sha256"] = encoded[CHECKPOINT_BODY_BYTES:]
    checkpoint = validate_checkpoint(checkpoint)
    if encode_checkpoint(checkpoint) != encoded:
        raise VideoModelContinuationError("non-canonical checkpoint wire")
    return checkpoint
