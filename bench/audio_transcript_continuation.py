"""Independent oracle for transcript-model continuation composition."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import audio_transcript_adapter as audio
from bench import audio_video_result_link as result_link
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as model_continuation
from bench import video_segment_timeline as video_timeline


class AudioTranscriptContinuationError(ValueError):
    """A transcript continuation checkpoint or binding is invalid."""


Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
CHECKPOINT_ABI = 0x4154435054000001
CHECKPOINT_BYTES = 576
CHECKPOINT_BODY_BYTES = CHECKPOINT_BYTES - 32
CHECKPOINT_MAGIC = b"GATCP1\x00\x00"
CHECKPOINT_DOMAIN = b"glacier-audio-transcript-continuation-v1\x00"
SCALAR_FIELDS = (
    "request_epoch",
    "completed_generation",
    "next_generation",
    "next_segment_index",
    "next_source_start_sample",
    "next_publish_start_sample",
    "next_publish_end_sample",
    "sample_rate",
    "state_bytes",
    "source_bank_epoch",
    "restore_bank_epoch",
    "model_publication_next_sequence",
    "link_next_sequence",
    "visible_links",
)
DIGEST_FIELDS = (
    "stateful_checkpoint_sha256",
    "state_publication_sha256",
    "restored_state_sha256",
    "previous_overlap_sha256",
    "previous_transcript_sha256",
    "next_overlap_sha256",
    "audio_media_sha256",
    "video_media_sha256",
    "video_timeline_sha256",
    "link_state_sha256",
    "previous_link_sha256",
    "challenge_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise AudioTranscriptContinuationError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or not any(value):
        raise AudioTranscriptContinuationError("invalid digest")
    return value


def _body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in SCALAR_FIELDS)
        digests = tuple(value[field] for field in DIGEST_FIELDS)
    except (KeyError, TypeError):
        raise AudioTranscriptContinuationError(
            "invalid checkpoint"
        ) from None
    output = bytearray(CHECKPOINT_BODY_BYTES)
    output[:32] = (
        CHECKPOINT_MAGIC
        + _u64(CHECKPOINT_ABI)
        + _u64(CHECKPOINT_BYTES)
        + _u64(0)
    )
    output[32:144] = b"".join(_u64(value) for value in scalars)
    output[160:544] = b"".join(_digest(value) for value in digests)
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
        raise AudioTranscriptContinuationError(
            "invalid checkpoint"
        ) from None
    if (
        checkpoint["request_epoch"] == 0
        or checkpoint["completed_generation"] == 0
        or checkpoint["next_generation"] != expected_next
        or checkpoint["next_segment_index"] == 0
        or checkpoint["next_source_start_sample"]
        >= checkpoint["next_publish_start_sample"]
        or checkpoint["next_publish_start_sample"]
        >= checkpoint["next_publish_end_sample"]
        or checkpoint["sample_rate"] == 0
        or checkpoint["state_bytes"] == 0
        or checkpoint["source_bank_epoch"] == 0
        or checkpoint["restore_bank_epoch"] == 0
        or checkpoint["source_bank_epoch"]
        == checkpoint["restore_bank_epoch"]
        or checkpoint["model_publication_next_sequence"]
        != checkpoint["completed_generation"]
        or checkpoint["link_next_sequence"]
        != checkpoint["visible_links"]
        or checkpoint["visible_links"] == 0
        or checkpoint["checkpoint_sha256"] != checkpoint_root(checkpoint)
    ):
        raise AudioTranscriptContinuationError("invalid checkpoint")
    return checkpoint


def _transcript_matches_overlap(
    transcript: Record,
    overlap: Record,
) -> bool:
    fields = (
        "request_epoch",
        "generation",
        "segment_index",
        "context_start_sample",
        "context_end_sample",
        "publish_start_sample",
        "publish_end_sample",
        "sample_rate",
        "media_object_sha256",
        "processor_state_sha256",
        "cache_payload_sha256",
        "overlap_sha256",
        "previous_transcript_sha256",
    )
    return all(transcript[field] == overlap[field] for field in fields)


def validate_bindings(
    checkpoint_value: Record,
    stateful_checkpoint_value: Record,
    state_publication_value: Record,
    previous_overlap_value: Record,
    previous_transcript_value: Record,
    previous_link_value: Record,
    next_overlap_value: Record,
    timeline_value: Record,
    link_state_value: Record,
) -> tuple[
    Record,
    Record,
    Record,
    Record,
    Record,
    Record,
    Record,
    Record,
    Record,
]:
    checkpoint = validate_checkpoint(checkpoint_value)
    try:
        stateful_checkpoint = model_continuation.validate_checkpoint(
            stateful_checkpoint_value
        )
        state_publication = stateful.validate_publication(
            state_publication_value
        )
        previous_overlap = audio.validate_overlap(previous_overlap_value)
        previous_transcript = audio.validate_transcript_for_overlap(
            previous_transcript_value,
            previous_overlap,
        )
        previous_link = result_link.validate_link(previous_link_value)
        next_overlap = audio.validate_overlap(next_overlap_value)
        audio.validate_predecessor(next_overlap, previous_transcript)
        timeline = video_timeline.validate_timeline(timeline_value)
        link_state = result_link.validate_state(link_state_value)
        expected_next_segment = previous_overlap["segment_index"] + 1
        _u64(expected_next_segment)
        expected_next_link = previous_link["link_sequence"] + 1
        _u64(expected_next_link)
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
        video_timeline.VideoSegmentTimelineError,
    ) as error:
        raise AudioTranscriptContinuationError(
            "invalid checkpoint binding"
        ) from error
    if (
        not _transcript_matches_overlap(
            previous_transcript,
            previous_overlap,
        )
        or previous_link != expected_previous_link
        or checkpoint["request_epoch"]
        != stateful_checkpoint["request_epoch"]
        or checkpoint["request_epoch"] != state_publication["request_epoch"]
        or checkpoint["request_epoch"] != previous_overlap["request_epoch"]
        or checkpoint["request_epoch"] != previous_link["request_epoch"]
        or checkpoint["request_epoch"] != next_overlap["request_epoch"]
        or checkpoint["request_epoch"] != timeline["request_epoch"]
        or checkpoint["request_epoch"] != link_state["request_epoch"]
        or checkpoint["completed_generation"]
        != stateful_checkpoint["current_step"]
        or checkpoint["completed_generation"]
        != previous_overlap["generation"]
        or checkpoint["next_generation"] != next_overlap["generation"]
        or checkpoint["next_segment_index"] != expected_next_segment
        or checkpoint["next_segment_index"] != next_overlap["segment_index"]
        or previous_overlap["publish_end_sample"]
        != next_overlap["publish_start_sample"]
        or checkpoint["next_source_start_sample"]
        != next_overlap["source_start_sample"]
        or checkpoint["next_publish_start_sample"]
        != next_overlap["publish_start_sample"]
        or checkpoint["next_publish_end_sample"]
        != next_overlap["publish_end_sample"]
        or checkpoint["sample_rate"] != previous_overlap["sample_rate"]
        or checkpoint["sample_rate"] != next_overlap["sample_rate"]
        or checkpoint["state_bytes"] != stateful_checkpoint["state_bytes"]
        or checkpoint["state_bytes"] != state_publication["state_bytes"]
        or checkpoint["source_bank_epoch"]
        != stateful_checkpoint["source_bank_epoch"]
        or checkpoint["restore_bank_epoch"]
        != stateful_checkpoint["restore_bank_epoch"]
        or checkpoint["model_publication_next_sequence"]
        != stateful_checkpoint["publication_next_sequence"]
        or checkpoint["link_next_sequence"] != link_state["next_sequence"]
        or checkpoint["link_next_sequence"] != expected_next_link
        or checkpoint["visible_links"] != link_state["visible_links"]
        or checkpoint["visible_links"] != previous_link["link_index"]
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
        or checkpoint["previous_overlap_sha256"]
        != previous_overlap["overlap_sha256"]
        or checkpoint["previous_transcript_sha256"]
        != previous_transcript["transcript_sha256"]
        or stateful_checkpoint["last_output_sha256"]
        != model.sha256(previous_transcript["text"])
        or checkpoint["next_overlap_sha256"]
        != next_overlap["overlap_sha256"]
        or next_overlap["previous_transcript_sha256"]
        != previous_transcript["transcript_sha256"]
        or checkpoint["audio_media_sha256"]
        != previous_overlap["media_object_sha256"]
        or checkpoint["audio_media_sha256"]
        != next_overlap["media_object_sha256"]
        or checkpoint["audio_media_sha256"]
        != link_state["audio_media_sha256"]
        or checkpoint["video_media_sha256"]
        != timeline["media_object_sha256"]
        or checkpoint["video_media_sha256"]
        != link_state["video_media_sha256"]
        or checkpoint["video_timeline_sha256"]
        != timeline["timeline_sha256"]
        or checkpoint["link_state_sha256"] != link_state["state_sha256"]
        or checkpoint["previous_link_sha256"]
        != link_state["previous_link_sha256"]
        or checkpoint["previous_link_sha256"]
        != previous_link["link_sha256"]
        or previous_link["audio_overlap_sha256"]
        != previous_overlap["overlap_sha256"]
        or previous_link["transcript_sha256"]
        != previous_transcript["transcript_sha256"]
        or previous_link["video_timeline_sha256"]
        != timeline["timeline_sha256"]
        or previous_link["audio_media_sha256"]
        != checkpoint["audio_media_sha256"]
        or previous_link["video_media_sha256"]
        != checkpoint["video_media_sha256"]
        or checkpoint["challenge_sha256"]
        != stateful_checkpoint["challenge_sha256"]
        or checkpoint["challenge_sha256"]
        != state_publication["challenge_sha256"]
        or checkpoint["challenge_sha256"]
        != previous_overlap["challenge_sha256"]
        or checkpoint["challenge_sha256"]
        != next_overlap["challenge_sha256"]
        or checkpoint["challenge_sha256"] != timeline["challenge_sha256"]
        or checkpoint["challenge_sha256"] != link_state["challenge_sha256"]
    ):
        raise AudioTranscriptContinuationError(
            "invalid checkpoint binding"
        )
    return (
        checkpoint,
        stateful_checkpoint,
        state_publication,
        previous_overlap,
        previous_transcript,
        previous_link,
        next_overlap,
        timeline,
        link_state,
    )


def make_checkpoint(
    stateful_checkpoint_value: Record,
    state_publication_value: Record,
    previous_overlap_value: Record,
    previous_transcript_value: Record,
    previous_link_value: Record,
    next_overlap_value: Record,
    timeline_value: Record,
    link_state_value: Record,
) -> Record:
    stateful_checkpoint = model_continuation.validate_checkpoint(
        stateful_checkpoint_value
    )
    state_publication = stateful.validate_publication(
        state_publication_value
    )
    previous_overlap = audio.validate_overlap(previous_overlap_value)
    previous_transcript = audio.validate_transcript_for_overlap(
        previous_transcript_value,
        previous_overlap,
    )
    previous_link = result_link.validate_link(previous_link_value)
    next_overlap = audio.validate_overlap(next_overlap_value)
    timeline = video_timeline.validate_timeline(timeline_value)
    link_state = result_link.validate_state(link_state_value)
    checkpoint: Record = {
        "request_epoch": stateful_checkpoint["request_epoch"],
        "completed_generation": stateful_checkpoint["current_step"],
        "next_generation": stateful_checkpoint["current_step"] + 1,
        "next_segment_index": next_overlap["segment_index"],
        "next_source_start_sample": next_overlap["source_start_sample"],
        "next_publish_start_sample": next_overlap["publish_start_sample"],
        "next_publish_end_sample": next_overlap["publish_end_sample"],
        "sample_rate": next_overlap["sample_rate"],
        "state_bytes": stateful_checkpoint["state_bytes"],
        "source_bank_epoch": stateful_checkpoint["source_bank_epoch"],
        "restore_bank_epoch": stateful_checkpoint["restore_bank_epoch"],
        "model_publication_next_sequence": stateful_checkpoint[
            "publication_next_sequence"
        ],
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
        "previous_overlap_sha256": previous_overlap["overlap_sha256"],
        "previous_transcript_sha256": previous_transcript[
            "transcript_sha256"
        ],
        "next_overlap_sha256": next_overlap["overlap_sha256"],
        "audio_media_sha256": next_overlap["media_object_sha256"],
        "video_media_sha256": timeline["media_object_sha256"],
        "video_timeline_sha256": timeline["timeline_sha256"],
        "link_state_sha256": link_state["state_sha256"],
        "previous_link_sha256": link_state["previous_link_sha256"],
        "challenge_sha256": stateful_checkpoint["challenge_sha256"],
    }
    checkpoint["checkpoint_sha256"] = checkpoint_root(checkpoint)
    validate_bindings(
        checkpoint,
        stateful_checkpoint,
        state_publication,
        previous_overlap,
        previous_transcript,
        previous_link,
        next_overlap,
        timeline,
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
        or any(encoded[144:160])
    ):
        raise AudioTranscriptContinuationError(
            "invalid checkpoint wire"
        )
    checkpoint: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(SCALAR_FIELDS)
    }
    checkpoint.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(DIGEST_FIELDS)
        }
    )
    checkpoint["checkpoint_sha256"] = encoded[CHECKPOINT_BODY_BYTES:]
    checkpoint = validate_checkpoint(checkpoint)
    if encode_checkpoint(checkpoint) != encoded:
        raise AudioTranscriptContinuationError(
            "non-canonical checkpoint wire"
        )
    return checkpoint
