"""Independent oracle for exact audio/transcript-to-video result links."""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Any

from bench import audio_transcript_adapter as audio
from bench import media_contract as media
from bench import video_segment_timeline as video_timeline


class AudioVideoResultLinkError(ValueError):
    """A cross-modal link state, input, or result is invalid."""


Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
LINK_STATE_ABI = 0x4741564C53000001
RESULT_LINK_ABI = 0x4741564C4B000001
LINK_STATE_BYTES = 320
RESULT_LINK_BYTES = 576
LINK_STATE_BODY_BYTES = LINK_STATE_BYTES - 32
RESULT_LINK_BODY_BYTES = RESULT_LINK_BYTES - 32
LINK_STATE_MAGIC = b"GAVLS1\x00\x00"
RESULT_LINK_MAGIC = b"GAVLK1\x00\x00"
LINK_STATE_DOMAIN = b"glacier-audio-video-link-state-v1\x00"
RESULT_LINK_DOMAIN = b"glacier-audio-video-result-link-v1\x00"
LINK_POLICY_DOMAIN = b"glacier-audio-video-link-policy-v1\x00"

EXACT = 1
AUDIO_WITHIN_VIDEO = 2
VIDEO_WITHIN_AUDIO = 3
PARTIAL_OVERLAP = 4
RELATIONS = (EXACT, AUDIO_WITHIN_VIDEO, VIDEO_WITHIN_AUDIO, PARTIAL_OVERLAP)

STATE_SCALARS = (
    "request_epoch",
    "next_sequence",
    "visible_links",
    "last_link_index",
)
STATE_DIGESTS = (
    "audio_media_sha256",
    "video_media_sha256",
    "challenge_sha256",
    "previous_link_sha256",
    "policy_sha256",
)
LINK_SCALARS = (
    "request_epoch",
    "link_sequence",
    "link_index",
    "relation",
    "target_numerator",
    "target_denominator",
    "audio_source_start_sample",
    "audio_source_end_sample",
    "audio_start_tick",
    "audio_end_tick",
    "video_start_tick",
    "video_end_tick",
    "overlap_start_tick",
    "overlap_end_tick",
    "transcript_segment_index",
    "timeline_decision_count",
    "timeline_visible_segments",
)
LINK_DIGESTS = (
    "audio_media_sha256",
    "audio_processor_state_sha256",
    "audio_cache_payload_sha256",
    "audio_overlap_sha256",
    "transcript_sha256",
    "video_media_sha256",
    "video_timeline_sha256",
    "video_tail_segment_sha256",
    "previous_link_sha256",
    "challenge_sha256",
    "policy_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise AudioVideoResultLinkError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or not any(value):
        raise AudioVideoResultLinkError("invalid digest")
    return value


def policy_root() -> bytes:
    return hashlib.sha256(
        LINK_POLICY_DOMAIN
        + _u64(1)
        + b"".join(_u64(relation) for relation in RELATIONS)
    ).digest()


def _state_body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in STATE_SCALARS)
        digests = tuple(value[field] for field in STATE_DIGESTS)
    except (KeyError, TypeError):
        raise AudioVideoResultLinkError("invalid link state") from None
    output = bytearray(LINK_STATE_BODY_BYTES)
    output[:32] = (
        LINK_STATE_MAGIC
        + _u64(LINK_STATE_ABI)
        + _u64(LINK_STATE_BYTES)
        + _u64(0)
    )
    output[32:64] = b"".join(_u64(value) for value in scalars)
    output[96:256] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def state_root(value: Record) -> bytes:
    return hashlib.sha256(LINK_STATE_DOMAIN + _state_body(value)).digest()


def validate_state(value: Record) -> Record:
    fields = STATE_SCALARS + STATE_DIGESTS + ("state_sha256",)
    try:
        state = {field: value[field] for field in fields}
        for field in STATE_SCALARS:
            _u64(state[field])
        for field in STATE_DIGESTS + ("state_sha256",):
            _digest(state[field])
    except (KeyError, TypeError):
        raise AudioVideoResultLinkError("invalid link state") from None
    if (
        state["request_epoch"] == 0
        or state["next_sequence"] != state["visible_links"]
        or state["visible_links"] != state["last_link_index"]
        or state["policy_sha256"] != policy_root()
        or state["state_sha256"] != state_root(state)
    ):
        raise AudioVideoResultLinkError("invalid link state")
    return state


def initialize_state(
    request_epoch: int,
    audio_media_sha256: bytes,
    video_media_sha256: bytes,
    challenge_sha256: bytes,
    genesis_link_sha256: bytes,
) -> Record:
    state: Record = {
        "request_epoch": request_epoch,
        "next_sequence": 0,
        "visible_links": 0,
        "last_link_index": 0,
        "audio_media_sha256": audio_media_sha256,
        "video_media_sha256": video_media_sha256,
        "challenge_sha256": challenge_sha256,
        "previous_link_sha256": genesis_link_sha256,
        "policy_sha256": policy_root(),
    }
    state["state_sha256"] = state_root(state)
    return validate_state(state)


def _link_body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in LINK_SCALARS)
        digests = tuple(value[field] for field in LINK_DIGESTS)
    except (KeyError, TypeError):
        raise AudioVideoResultLinkError("invalid result link") from None
    output = bytearray(RESULT_LINK_BODY_BYTES)
    output[:32] = (
        RESULT_LINK_MAGIC
        + _u64(RESULT_LINK_ABI)
        + _u64(RESULT_LINK_BYTES)
        + _u64(0)
    )
    output[32:168] = b"".join(_u64(value) for value in scalars)
    output[192:544] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def link_root(value: Record) -> bytes:
    return hashlib.sha256(RESULT_LINK_DOMAIN + _link_body(value)).digest()


def temporal_relation(
    audio_start: int,
    audio_end: int,
    video_start: int,
    video_end: int,
) -> int:
    if audio_start == video_start and audio_end == video_end:
        return EXACT
    if audio_start >= video_start and audio_end <= video_end:
        return AUDIO_WITHIN_VIDEO
    if video_start >= audio_start and video_end <= audio_end:
        return VIDEO_WITHIN_AUDIO
    return PARTIAL_OVERLAP


def validate_link(value: Record) -> Record:
    fields = LINK_SCALARS + LINK_DIGESTS + ("link_sha256",)
    try:
        link = {field: value[field] for field in fields}
        for field in LINK_SCALARS:
            _u64(link[field])
        for field in LINK_DIGESTS + ("link_sha256",):
            _digest(link[field])
        expected_index = link["link_sequence"] + 1
        _u64(expected_index)
    except (KeyError, TypeError):
        raise AudioVideoResultLinkError("invalid result link") from None
    if (
        link["request_epoch"] == 0
        or link["link_index"] != expected_index
        or link["relation"] not in RELATIONS
        or link["target_numerator"] == 0
        or link["target_denominator"] == 0
        or math.gcd(
            link["target_numerator"],
            link["target_denominator"],
        )
        != 1
        or link["audio_source_start_sample"]
        >= link["audio_source_end_sample"]
        or link["audio_start_tick"] >= link["audio_end_tick"]
        or link["video_start_tick"] >= link["video_end_tick"]
        or link["overlap_start_tick"] >= link["overlap_end_tick"]
        or link["overlap_start_tick"]
        != max(link["audio_start_tick"], link["video_start_tick"])
        or link["overlap_end_tick"]
        != min(link["audio_end_tick"], link["video_end_tick"])
        or link["relation"]
        != temporal_relation(
            link["audio_start_tick"],
            link["audio_end_tick"],
            link["video_start_tick"],
            link["video_end_tick"],
        )
        or link["transcript_segment_index"] == 0
        or link["timeline_decision_count"] == U64_MAX
        or link["timeline_visible_segments"] == 0
        or link["timeline_visible_segments"]
        > link["timeline_decision_count"] + 1
        or link["policy_sha256"] != policy_root()
        or link["link_sha256"] != link_root(link)
    ):
        raise AudioVideoResultLinkError("invalid result link")
    return link


def _mapped_publish_range(
    transcript: Record,
    timeline: Record,
) -> tuple[int, int]:
    try:
        mapped = media.map_span_exact(
            (
                (
                    transcript["publish_start_sample"],
                    (1, transcript["sample_rate"]),
                ),
                (
                    transcript["publish_end_sample"],
                    (1, transcript["sample_rate"]),
                ),
            ),
            (
                timeline["target_numerator"],
                timeline["target_denominator"],
            ),
        )
    except media.MediaContractError as error:
        raise AudioVideoResultLinkError(
            "publish range cannot map exactly"
        ) from error
    return mapped[0][0], mapped[1][0]


def validate_inputs(
    state_value: Record,
    overlap_value: Record,
    transcript_value: Record,
    timeline_value: Record,
) -> tuple[Record, Record, Record, Record]:
    state = validate_state(state_value)
    try:
        overlap = audio.validate_overlap(overlap_value)
        transcript = audio.validate_transcript_for_overlap(
            transcript_value,
            overlap,
        )
        timeline = video_timeline.validate_timeline(timeline_value)
    except (
        audio.AudioTranscriptAdapterError,
        video_timeline.VideoSegmentTimelineError,
    ) as error:
        raise AudioVideoResultLinkError("invalid link input") from error
    if (
        state["request_epoch"] != overlap["request_epoch"]
        or state["request_epoch"] != transcript["request_epoch"]
        or state["request_epoch"] != timeline["request_epoch"]
        or state["audio_media_sha256"]
        != overlap["media_object_sha256"]
        or state["video_media_sha256"]
        != timeline["media_object_sha256"]
        or state["challenge_sha256"] != overlap["challenge_sha256"]
        or state["challenge_sha256"] != timeline["challenge_sha256"]
    ):
        raise AudioVideoResultLinkError("invalid link input")
    _mapped_publish_range(transcript, timeline)
    return state, overlap, transcript, timeline


def make_link(
    state_value: Record,
    overlap_value: Record,
    transcript_value: Record,
    timeline_value: Record,
) -> Record:
    state, _overlap, transcript, timeline = validate_inputs(
        state_value,
        overlap_value,
        transcript_value,
        timeline_value,
    )
    audio_start, audio_end = _mapped_publish_range(transcript, timeline)
    video_start = timeline["tail_start_tick"]
    video_end = timeline["tail_end_tick"]
    overlap_start = max(audio_start, video_start)
    overlap_end = min(audio_end, video_end)
    if overlap_start >= overlap_end:
        raise AudioVideoResultLinkError("no temporal overlap")
    link_index = state["last_link_index"] + 1
    _u64(link_index)
    link: Record = {
        "request_epoch": state["request_epoch"],
        "link_sequence": state["next_sequence"],
        "link_index": link_index,
        "relation": temporal_relation(
            audio_start,
            audio_end,
            video_start,
            video_end,
        ),
        "target_numerator": timeline["target_numerator"],
        "target_denominator": timeline["target_denominator"],
        "audio_source_start_sample": transcript["publish_start_sample"],
        "audio_source_end_sample": transcript["publish_end_sample"],
        "audio_start_tick": audio_start,
        "audio_end_tick": audio_end,
        "video_start_tick": video_start,
        "video_end_tick": video_end,
        "overlap_start_tick": overlap_start,
        "overlap_end_tick": overlap_end,
        "transcript_segment_index": transcript["segment_index"],
        "timeline_decision_count": timeline["decision_count"],
        "timeline_visible_segments": timeline["visible_segments"],
        "audio_media_sha256": transcript["media_object_sha256"],
        "audio_processor_state_sha256": transcript[
            "processor_state_sha256"
        ],
        "audio_cache_payload_sha256": transcript[
            "cache_payload_sha256"
        ],
        "audio_overlap_sha256": transcript["overlap_sha256"],
        "transcript_sha256": transcript["transcript_sha256"],
        "video_media_sha256": timeline["media_object_sha256"],
        "video_timeline_sha256": timeline["timeline_sha256"],
        "video_tail_segment_sha256": timeline[
            "tail_segment_sha256"
        ],
        "previous_link_sha256": state["previous_link_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "policy_sha256": state["policy_sha256"],
    }
    link["link_sha256"] = link_root(link)
    return validate_link(link)


def apply_link(
    state_value: Record,
    overlap_value: Record,
    transcript_value: Record,
    timeline_value: Record,
    link_value: Record,
) -> Record:
    state = validate_state(state_value)
    link = validate_link(link_value)
    expected = make_link(
        state,
        overlap_value,
        transcript_value,
        timeline_value,
    )
    if link != expected:
        raise AudioVideoResultLinkError("link does not match input")
    next_state: Record = {
        **state,
        "next_sequence": state["next_sequence"] + 1,
        "visible_links": state["visible_links"] + 1,
        "last_link_index": link["link_index"],
        "previous_link_sha256": link["link_sha256"],
    }
    _u64(next_state["next_sequence"])
    _u64(next_state["visible_links"])
    next_state["state_sha256"] = state_root(next_state)
    return validate_state(next_state)


def encode_state(value: Record) -> bytes:
    state = validate_state(value)
    return _state_body(state) + state["state_sha256"]


def decode_state(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != LINK_STATE_BYTES
        or encoded[:8] != LINK_STATE_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != LINK_STATE_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != LINK_STATE_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[64:96])
        or any(encoded[256:LINK_STATE_BODY_BYTES])
    ):
        raise AudioVideoResultLinkError("invalid link state wire")
    state: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(STATE_SCALARS)
    }
    state.update(
        {
            field: encoded[96 + index * 32 : 128 + index * 32]
            for index, field in enumerate(STATE_DIGESTS)
        }
    )
    state["state_sha256"] = encoded[LINK_STATE_BODY_BYTES:]
    state = validate_state(state)
    if encode_state(state) != encoded:
        raise AudioVideoResultLinkError("non-canonical link state wire")
    return state


def encode_link(value: Record) -> bytes:
    link = validate_link(value)
    return _link_body(link) + link["link_sha256"]


def decode_link(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != RESULT_LINK_BYTES
        or encoded[:8] != RESULT_LINK_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != RESULT_LINK_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != RESULT_LINK_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[168:192])
    ):
        raise AudioVideoResultLinkError("invalid result link wire")
    link: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(LINK_SCALARS)
    }
    link.update(
        {
            field: encoded[192 + index * 32 : 224 + index * 32]
            for index, field in enumerate(LINK_DIGESTS)
        }
    )
    link["link_sha256"] = encoded[RESULT_LINK_BODY_BYTES:]
    link = validate_link(link)
    if encode_link(link) != encoded:
        raise AudioVideoResultLinkError("non-canonical result link wire")
    return link
