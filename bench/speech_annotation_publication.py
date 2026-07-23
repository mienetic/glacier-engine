"""Independent exact word-timing and speaker-attribution oracle."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import audio_transcript_adapter as audio
from bench import model_contract as model


class SpeechAnnotationError(ValueError):
    """A speech annotation state, plan, result, or binding is invalid."""


Record = dict[str, Any]
Word = tuple[int, int, int, int, int, int]
U64_MAX = (1 << 64) - 1
STATE_ABI = 0x5350414E53540001
PLAN_ABI = 0x5350414E504C0001
RESULT_ABI = 0x5350414E52530001
STATE_BYTES = 384
PLAN_BYTES = 576
RESULT_BYTES = 896
STATE_BODY_BYTES = STATE_BYTES - 32
PLAN_BODY_BYTES = PLAN_BYTES - 32
RESULT_BODY_BYTES = RESULT_BYTES - 32
STATE_MAGIC = b"GSPANS1\x00"
PLAN_MAGIC = b"GSPANP1\x00"
RESULT_MAGIC = b"GSPANR1\x00"
STATE_DOMAIN = b"glacier-speech-annotation-state-v1\x00"
PLAN_DOMAIN = b"glacier-speech-annotation-plan-v1\x00"
RESULT_DOMAIN = b"glacier-speech-annotation-result-v1\x00"
CONTENT_DOMAIN = b"glacier-speech-annotation-content-v1\x00"
POLICY_DOMAIN = b"glacier-speech-annotation-policy-v1\x00"
MAXIMUM_WORDS = 4
MAXIMUM_SPEAKERS = 2
MAXIMUM_CONFIDENCE_PPM = 1_000_000
ZERO_DIGEST = bytes(32)
ZERO_WORD: Word = (0, 0, 0, 0, 0, 0)

STATE_SCALARS = (
    "request_epoch",
    "next_sequence",
    "visible_annotations",
    "visible_words",
    "visible_speaker_turns",
    "next_sample",
    "sample_rate",
)
STATE_DIGESTS = (
    "audio_media_sha256",
    "last_transcript_sha256",
    "previous_result_sha256",
    "last_speaker_sha256",
    "policy_sha256",
    "challenge_sha256",
)
PLAN_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "sample_rate",
    "publish_start_sample",
    "publish_end_sample",
    "text_bytes",
    "maximum_words",
    "maximum_speakers",
    "publication_sequence",
    "visible_words_before",
    "visible_speaker_turns_before",
)
PLAN_DIGESTS = (
    "transcript_sha256",
    "overlap_sha256",
    "audio_media_sha256",
    "processor_state_sha256",
    "cache_payload_sha256",
    "text_sha256",
    "state_before_sha256",
    "previous_result_sha256",
    "policy_sha256",
    "challenge_sha256",
)
RESULT_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "sample_rate",
    "publish_start_sample",
    "publish_end_sample",
    "text_bytes",
    "word_count",
    "speaker_count",
    "publication_sequence",
    "visible_annotations_before",
    "visible_annotations_after",
    "visible_words_before",
    "visible_words_after",
    "visible_speaker_turns_before",
    "visible_speaker_turns_after",
)
RESULT_DIGESTS = (
    "transcript_sha256",
    "overlap_sha256",
    "audio_media_sha256",
    "processor_state_sha256",
    "cache_payload_sha256",
    "text_sha256",
    "plan_sha256",
    "annotation_content_sha256",
    "state_before_sha256",
    "previous_result_sha256",
    "policy_sha256",
    "challenge_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise SpeechAnnotationError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or not allow_zero
        and value == ZERO_DIGEST
    ):
        raise SpeechAnnotationError("invalid digest")
    return value


def _checked_add(left: int, right: int) -> int:
    value = left + right
    if value > U64_MAX:
        raise SpeechAnnotationError("u64 addition overflow")
    return value


def _state_body(value: Record) -> bytes:
    output = bytearray(STATE_BODY_BYTES)
    output[:32] = b"".join(
        (STATE_MAGIC, _u64(STATE_ABI), _u64(STATE_BYTES), _u64(0))
    )
    output[32:88] = b"".join(
        _u64(value[field]) for field in STATE_SCALARS
    )
    output[96:288] = b"".join(
        _digest(value[field]) for field in STATE_DIGESTS
    )
    return bytes(output)


def _plan_body(value: Record) -> bytes:
    output = bytearray(PLAN_BODY_BYTES)
    output[:32] = b"".join(
        (PLAN_MAGIC, _u64(PLAN_ABI), _u64(PLAN_BYTES), _u64(0))
    )
    output[32:128] = b"".join(
        _u64(value[field]) for field in PLAN_SCALARS
    )
    output[160:480] = b"".join(
        _digest(value[field]) for field in PLAN_DIGESTS
    )
    return bytes(output)


def _word(value: Any) -> Word:
    if (
        not isinstance(value, tuple)
        or len(value) != 6
        or any(not isinstance(item, int) for item in value)
    ):
        raise SpeechAnnotationError("invalid word timing")
    for item in value:
        _u64(item)
    return value


def _result_body(value: Record) -> bytes:
    output = bytearray(RESULT_BODY_BYTES)
    output[:32] = b"".join(
        (
            RESULT_MAGIC,
            _u64(RESULT_ABI),
            _u64(RESULT_BYTES),
            _u64(0),
        )
    )
    output[32:160] = b"".join(
        _u64(value[field]) for field in RESULT_SCALARS
    )
    output[160:544] = b"".join(
        _digest(value[field]) for field in RESULT_DIGESTS
    )
    words = value["words"]
    speakers = value["speakers"]
    if (
        not isinstance(words, tuple)
        or len(words) != MAXIMUM_WORDS
        or not isinstance(speakers, tuple)
        or len(speakers) != MAXIMUM_SPEAKERS
    ):
        raise SpeechAnnotationError("invalid result arrays")
    output[544:736] = b"".join(
        b"".join(_u64(item) for item in _word(word)) for word in words
    )
    output[736:800] = b"".join(
        _digest(speaker, allow_zero=True) for speaker in speakers
    )
    return bytes(output)


def state_root(value: Record) -> bytes:
    return hashlib.sha256(STATE_DOMAIN + _state_body(value)).digest()


def plan_root(value: Record) -> bytes:
    return hashlib.sha256(PLAN_DOMAIN + _plan_body(value)).digest()


def content_root(value: Record) -> bytes:
    word_count = value["word_count"]
    speaker_count = value["speaker_count"]
    words = value["words"]
    speakers = value["speakers"]
    hasher = hashlib.sha256()
    hasher.update(CONTENT_DOMAIN)
    hasher.update(_digest(value["transcript_sha256"]))
    hasher.update(_digest(value["text_sha256"]))
    hasher.update(_u64(word_count))
    hasher.update(_u64(speaker_count))
    for word in words[:word_count]:
        for item in _word(word):
            hasher.update(_u64(item))
    for speaker in speakers[:speaker_count]:
        hasher.update(_digest(speaker))
    return hasher.digest()


def result_root(value: Record) -> bytes:
    return hashlib.sha256(RESULT_DOMAIN + _result_body(value)).digest()


def policy_root() -> bytes:
    return hashlib.sha256(
        b"".join(
            (
                POLICY_DOMAIN,
                _u64(1),
                _u64(MAXIMUM_WORDS),
                _u64(MAXIMUM_SPEAKERS),
                _u64(MAXIMUM_CONFIDENCE_PPM),
            )
        )
    ).digest()


def validate_state(value: Record) -> Record:
    fields = STATE_SCALARS + STATE_DIGESTS + ("state_sha256",)
    try:
        state = {field: value[field] for field in fields}
        for field in STATE_SCALARS:
            _u64(state[field])
        for field in STATE_DIGESTS + ("state_sha256",):
            _digest(state[field])
    except (KeyError, TypeError):
        raise SpeechAnnotationError("invalid state") from None
    if (
        state["request_epoch"] == 0
        or state["next_sequence"] != state["visible_annotations"]
        or state["visible_speaker_turns"] > state["visible_words"]
        or state["sample_rate"] == 0
        or state["policy_sha256"] != policy_root()
        or state["state_sha256"] != state_root(state)
    ):
        raise SpeechAnnotationError("invalid state")
    return state


def initialize_state(
    *,
    request_epoch: int,
    audio_media_sha256: bytes,
    sample_rate: int,
    next_sample: int,
    last_transcript_sha256: bytes,
    genesis_result_sha256: bytes,
    genesis_speaker_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    state: Record = {
        "request_epoch": request_epoch,
        "next_sequence": 0,
        "visible_annotations": 0,
        "visible_words": 0,
        "visible_speaker_turns": 0,
        "next_sample": next_sample,
        "sample_rate": sample_rate,
        "audio_media_sha256": audio_media_sha256,
        "last_transcript_sha256": last_transcript_sha256,
        "previous_result_sha256": genesis_result_sha256,
        "last_speaker_sha256": genesis_speaker_sha256,
        "policy_sha256": policy_root(),
        "challenge_sha256": challenge_sha256,
    }
    state["state_sha256"] = state_root(state)
    return validate_state(state)


def validate_transcript_inputs(
    state_value: Record,
    overlap_value: Record,
    transcript_value: Record,
) -> tuple[Record, Record, Record]:
    state = validate_state(state_value)
    overlap = audio.validate_overlap(overlap_value)
    transcript = audio.validate_transcript_for_overlap(
        transcript_value, overlap
    )
    if (
        state["request_epoch"] != overlap["request_epoch"]
        or state["request_epoch"] != transcript["request_epoch"]
        or state["sample_rate"] != transcript["sample_rate"]
        or state["next_sample"] != transcript["publish_start_sample"]
        or state["audio_media_sha256"]
        != transcript["media_object_sha256"]
        or state["last_transcript_sha256"]
        != transcript["previous_transcript_sha256"]
        or state["challenge_sha256"] != overlap["challenge_sha256"]
    ):
        raise SpeechAnnotationError("invalid transcript binding")
    return state, overlap, transcript


def validate_plan(value: Record) -> Record:
    fields = PLAN_SCALARS + PLAN_DIGESTS + ("plan_sha256",)
    try:
        plan = {field: value[field] for field in fields}
        for field in PLAN_SCALARS:
            _u64(plan[field])
        for field in PLAN_DIGESTS + ("plan_sha256",):
            _digest(plan[field])
    except (KeyError, TypeError):
        raise SpeechAnnotationError("invalid plan") from None
    if (
        min(
            plan["request_epoch"],
            plan["generation"],
            plan["segment_index"],
            plan["sample_rate"],
            plan["text_bytes"],
        )
        <= 0
        or plan["publish_start_sample"] >= plan["publish_end_sample"]
        or plan["text_bytes"] > audio.MAXIMUM_TEXT_BYTES
        or plan["maximum_words"] != MAXIMUM_WORDS
        or plan["maximum_speakers"] != MAXIMUM_SPEAKERS
        or plan["publication_sequence"] == U64_MAX
        or plan["visible_speaker_turns_before"]
        > plan["visible_words_before"]
        or plan["policy_sha256"] != policy_root()
        or plan["plan_sha256"] != plan_root(plan)
    ):
        raise SpeechAnnotationError("invalid plan")
    return plan


def make_plan(
    state_value: Record,
    overlap_value: Record,
    transcript_value: Record,
) -> Record:
    state, overlap, transcript = validate_transcript_inputs(
        state_value, overlap_value, transcript_value
    )
    text = transcript["text"][: transcript["text_bytes"]]
    plan: Record = {
        "request_epoch": state["request_epoch"],
        "generation": transcript["generation"],
        "segment_index": transcript["segment_index"],
        "sample_rate": transcript["sample_rate"],
        "publish_start_sample": transcript["publish_start_sample"],
        "publish_end_sample": transcript["publish_end_sample"],
        "text_bytes": transcript["text_bytes"],
        "maximum_words": MAXIMUM_WORDS,
        "maximum_speakers": MAXIMUM_SPEAKERS,
        "publication_sequence": state["next_sequence"],
        "visible_words_before": state["visible_words"],
        "visible_speaker_turns_before": state[
            "visible_speaker_turns"
        ],
        "transcript_sha256": transcript["transcript_sha256"],
        "overlap_sha256": overlap["overlap_sha256"],
        "audio_media_sha256": transcript["media_object_sha256"],
        "processor_state_sha256": transcript[
            "processor_state_sha256"
        ],
        "cache_payload_sha256": transcript["cache_payload_sha256"],
        "text_sha256": model.sha256(text),
        "state_before_sha256": state["state_sha256"],
        "previous_result_sha256": state["previous_result_sha256"],
        "policy_sha256": state["policy_sha256"],
        "challenge_sha256": state["challenge_sha256"],
    }
    plan["plan_sha256"] = plan_root(plan)
    validate_plan_bindings(state, plan, overlap, transcript)
    return plan


def validate_plan_bindings(
    state_value: Record,
    plan_value: Record,
    overlap_value: Record,
    transcript_value: Record,
) -> None:
    state, overlap, transcript = validate_transcript_inputs(
        state_value, overlap_value, transcript_value
    )
    plan = validate_plan(plan_value)
    text = transcript["text"][: transcript["text_bytes"]]
    expected = {
        "request_epoch": state["request_epoch"],
        "generation": transcript["generation"],
        "segment_index": transcript["segment_index"],
        "sample_rate": state["sample_rate"],
        "publish_start_sample": state["next_sample"],
        "publish_end_sample": transcript["publish_end_sample"],
        "text_bytes": transcript["text_bytes"],
        "publication_sequence": state["next_sequence"],
        "visible_words_before": state["visible_words"],
        "visible_speaker_turns_before": state[
            "visible_speaker_turns"
        ],
        "transcript_sha256": transcript["transcript_sha256"],
        "overlap_sha256": overlap["overlap_sha256"],
        "audio_media_sha256": state["audio_media_sha256"],
        "processor_state_sha256": transcript[
            "processor_state_sha256"
        ],
        "cache_payload_sha256": transcript["cache_payload_sha256"],
        "text_sha256": model.sha256(text),
        "state_before_sha256": state["state_sha256"],
        "previous_result_sha256": state["previous_result_sha256"],
        "policy_sha256": state["policy_sha256"],
        "challenge_sha256": state["challenge_sha256"],
    }
    if any(plan[field] != value for field, value in expected.items()):
        raise SpeechAnnotationError("plan does not match inputs")


def validate_candidate(
    state_value: Record,
    transcript_value: Record,
    words_value: tuple[Word, ...],
    speakers_value: tuple[bytes, ...],
) -> int:
    state = validate_state(state_value)
    transcript = audio.validate_transcript(transcript_value)
    if (
        not isinstance(words_value, tuple)
        or not 0 < len(words_value) <= MAXIMUM_WORDS
        or not isinstance(speakers_value, tuple)
        or not 0 < len(speakers_value) <= MAXIMUM_SPEAKERS
    ):
        raise SpeechAnnotationError("invalid candidate sizes")
    words = tuple(_word(word) for word in words_value)
    speakers = tuple(_digest(speaker) for speaker in speakers_value)
    if len(set(speakers)) != len(speakers):
        raise SpeechAnnotationError("duplicate speaker")
    text = transcript["text"][: transcript["text_bytes"]]
    if not text or text[:1] == b" " or text[-1:] == b" ":
        raise SpeechAnnotationError("non-canonical text spacing")
    tokens = text.split(b" ")
    if (
        len(tokens) != len(words)
        or any(not token for token in tokens)
    ):
        raise SpeechAnnotationError("word count does not match text")
    cursor = 0
    previous_end = transcript["publish_start_sample"]
    maximum_seen = 0
    previous_speaker = state["last_speaker_sha256"]
    turns = 0
    for index, (token, word) in enumerate(zip(tokens, words)):
        (
            text_offset,
            text_bytes,
            start_sample,
            end_sample,
            speaker_index,
            confidence_ppm,
        ) = word
        if (
            text_offset != cursor
            or text_bytes != len(token)
            or start_sample < transcript["publish_start_sample"]
            or end_sample > transcript["publish_end_sample"]
            or start_sample >= end_sample
            or index == 0
            and start_sample != transcript["publish_start_sample"]
            or index > 0
            and start_sample < previous_end
            or not 0 < confidence_ppm <= MAXIMUM_CONFIDENCE_PPM
            or speaker_index >= len(speakers)
        ):
            raise SpeechAnnotationError("invalid word timing")
        if index == 0:
            if speaker_index != 0:
                raise SpeechAnnotationError("non-canonical speaker order")
        elif speaker_index > maximum_seen:
            if speaker_index != maximum_seen + 1:
                raise SpeechAnnotationError("non-canonical speaker order")
            maximum_seen = speaker_index
        speaker = speakers[speaker_index]
        if speaker != previous_speaker:
            turns = _checked_add(turns, 1)
        previous_speaker = speaker
        previous_end = end_sample
        cursor += len(token) + (1 if index + 1 < len(tokens) else 0)
    if (
        cursor != len(text)
        or previous_end != transcript["publish_end_sample"]
        or maximum_seen + 1 != len(speakers)
    ):
        raise SpeechAnnotationError("incomplete annotation")
    return turns


def validate_result(value: Record) -> Record:
    fields = (
        RESULT_SCALARS
        + RESULT_DIGESTS
        + ("words", "speakers", "result_sha256")
    )
    try:
        result = {field: value[field] for field in fields}
        for field in RESULT_SCALARS:
            _u64(result[field])
        for field in RESULT_DIGESTS + ("result_sha256",):
            _digest(result[field])
        words = result["words"]
        speakers = result["speakers"]
        if (
            not isinstance(words, tuple)
            or len(words) != MAXIMUM_WORDS
            or not isinstance(speakers, tuple)
            or len(speakers) != MAXIMUM_SPEAKERS
        ):
            raise SpeechAnnotationError("invalid result arrays")
        words = tuple(_word(word) for word in words)
        speakers = tuple(
            _digest(speaker, allow_zero=True) for speaker in speakers
        )
        result["words"] = words
        result["speakers"] = speakers
    except (KeyError, TypeError):
        raise SpeechAnnotationError("invalid result") from None
    word_count = result["word_count"]
    speaker_count = result["speaker_count"]
    if (
        min(
            result["request_epoch"],
            result["generation"],
            result["segment_index"],
            result["sample_rate"],
            result["text_bytes"],
            word_count,
            speaker_count,
        )
        <= 0
        or word_count > MAXIMUM_WORDS
        or speaker_count > MAXIMUM_SPEAKERS
        or result["publish_start_sample"] >= result["publish_end_sample"]
        or result["text_bytes"] > audio.MAXIMUM_TEXT_BYTES
        or result["visible_annotations_after"]
        != _checked_add(result["visible_annotations_before"], 1)
        or result["visible_words_after"]
        != _checked_add(result["visible_words_before"], word_count)
        or result["visible_speaker_turns_before"]
        > result["visible_words_before"]
        or not result["visible_speaker_turns_before"]
        <= result["visible_speaker_turns_after"]
        <= result["visible_words_after"]
        or any(word != ZERO_WORD for word in words[word_count:])
        or any(speaker != ZERO_DIGEST for speaker in speakers[speaker_count:])
        or result["policy_sha256"] != policy_root()
        or result["annotation_content_sha256"] != content_root(result)
        or result["result_sha256"] != result_root(result)
    ):
        raise SpeechAnnotationError("invalid result")
    return result


def make_result(
    state_value: Record,
    plan_value: Record,
    overlap_value: Record,
    transcript_value: Record,
    words_value: tuple[Word, ...],
    speakers_value: tuple[bytes, ...],
) -> Record:
    validate_plan_bindings(
        state_value, plan_value, overlap_value, transcript_value
    )
    state = validate_state(state_value)
    plan = validate_plan(plan_value)
    turns = validate_candidate(
        state, transcript_value, words_value, speakers_value
    )
    words = words_value + (ZERO_WORD,) * (
        MAXIMUM_WORDS - len(words_value)
    )
    speakers = speakers_value + (ZERO_DIGEST,) * (
        MAXIMUM_SPEAKERS - len(speakers_value)
    )
    result: Record = {
        "request_epoch": plan["request_epoch"],
        "generation": plan["generation"],
        "segment_index": plan["segment_index"],
        "sample_rate": plan["sample_rate"],
        "publish_start_sample": plan["publish_start_sample"],
        "publish_end_sample": plan["publish_end_sample"],
        "text_bytes": plan["text_bytes"],
        "word_count": len(words_value),
        "speaker_count": len(speakers_value),
        "publication_sequence": plan["publication_sequence"],
        "visible_annotations_before": state["visible_annotations"],
        "visible_annotations_after": _checked_add(
            state["visible_annotations"], 1
        ),
        "visible_words_before": state["visible_words"],
        "visible_words_after": _checked_add(
            state["visible_words"], len(words_value)
        ),
        "visible_speaker_turns_before": state[
            "visible_speaker_turns"
        ],
        "visible_speaker_turns_after": _checked_add(
            state["visible_speaker_turns"], turns
        ),
        "transcript_sha256": plan["transcript_sha256"],
        "overlap_sha256": plan["overlap_sha256"],
        "audio_media_sha256": plan["audio_media_sha256"],
        "processor_state_sha256": plan["processor_state_sha256"],
        "cache_payload_sha256": plan["cache_payload_sha256"],
        "text_sha256": plan["text_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "annotation_content_sha256": ZERO_DIGEST,
        "state_before_sha256": plan["state_before_sha256"],
        "previous_result_sha256": plan["previous_result_sha256"],
        "policy_sha256": plan["policy_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
        "words": words,
        "speakers": speakers,
    }
    result["annotation_content_sha256"] = content_root(result)
    result["result_sha256"] = result_root(result)
    validate_result_bindings(
        state, plan, overlap_value, transcript_value, result
    )
    return result


def validate_result_bindings(
    state_value: Record,
    plan_value: Record,
    overlap_value: Record,
    transcript_value: Record,
    result_value: Record,
) -> None:
    validate_plan_bindings(
        state_value, plan_value, overlap_value, transcript_value
    )
    state = validate_state(state_value)
    plan = validate_plan(plan_value)
    result = validate_result(result_value)
    turns = validate_candidate(
        state,
        transcript_value,
        result["words"][: result["word_count"]],
        result["speakers"][: result["speaker_count"]],
    )
    expected = {
        "request_epoch": plan["request_epoch"],
        "generation": plan["generation"],
        "segment_index": plan["segment_index"],
        "sample_rate": plan["sample_rate"],
        "publish_start_sample": plan["publish_start_sample"],
        "publish_end_sample": plan["publish_end_sample"],
        "text_bytes": plan["text_bytes"],
        "publication_sequence": plan["publication_sequence"],
        "visible_annotations_before": state["visible_annotations"],
        "visible_annotations_after": _checked_add(
            state["visible_annotations"], 1
        ),
        "visible_words_before": state["visible_words"],
        "visible_words_after": _checked_add(
            state["visible_words"], result["word_count"]
        ),
        "visible_speaker_turns_before": state[
            "visible_speaker_turns"
        ],
        "visible_speaker_turns_after": _checked_add(
            state["visible_speaker_turns"], turns
        ),
        "transcript_sha256": plan["transcript_sha256"],
        "overlap_sha256": plan["overlap_sha256"],
        "audio_media_sha256": plan["audio_media_sha256"],
        "processor_state_sha256": plan["processor_state_sha256"],
        "cache_payload_sha256": plan["cache_payload_sha256"],
        "text_sha256": plan["text_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "state_before_sha256": plan["state_before_sha256"],
        "previous_result_sha256": plan["previous_result_sha256"],
        "policy_sha256": plan["policy_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
    }
    if any(result[field] != value for field, value in expected.items()):
        raise SpeechAnnotationError("result does not match inputs")


def apply_result(
    state_value: Record,
    plan_value: Record,
    overlap_value: Record,
    transcript_value: Record,
    result_value: Record,
) -> Record:
    validate_result_bindings(
        state_value,
        plan_value,
        overlap_value,
        transcript_value,
        result_value,
    )
    state = validate_state(state_value)
    result = validate_result(result_value)
    last_word = result["words"][result["word_count"] - 1]
    speaker = result["speakers"][last_word[4]]
    next_state = dict(state)
    next_state.update(
        {
            "next_sequence": result["visible_annotations_after"],
            "visible_annotations": result[
                "visible_annotations_after"
            ],
            "visible_words": result["visible_words_after"],
            "visible_speaker_turns": result[
                "visible_speaker_turns_after"
            ],
            "next_sample": result["publish_end_sample"],
            "last_transcript_sha256": result["transcript_sha256"],
            "previous_result_sha256": result["result_sha256"],
            "last_speaker_sha256": speaker,
        }
    )
    next_state["state_sha256"] = state_root(next_state)
    return validate_state(next_state)


def encode_state(value: Record) -> bytes:
    state = validate_state(value)
    return _state_body(state) + state["state_sha256"]


def decode_state(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != STATE_BYTES
        or encoded[:8] != STATE_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != STATE_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != STATE_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[88:96])
        or any(encoded[288:STATE_BODY_BYTES])
    ):
        raise SpeechAnnotationError("invalid state wire")
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
    state["state_sha256"] = encoded[STATE_BODY_BYTES:]
    state = validate_state(state)
    if encode_state(state) != encoded:
        raise SpeechAnnotationError("non-canonical state wire")
    return state


def encode_plan(value: Record) -> bytes:
    plan = validate_plan(value)
    return _plan_body(plan) + plan["plan_sha256"]


def decode_plan(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PLAN_BYTES
        or encoded[:8] != PLAN_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != PLAN_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != PLAN_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[128:160])
        or any(encoded[480:PLAN_BODY_BYTES])
    ):
        raise SpeechAnnotationError("invalid plan wire")
    plan: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(PLAN_SCALARS)
    }
    plan.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(PLAN_DIGESTS)
        }
    )
    plan["plan_sha256"] = encoded[PLAN_BODY_BYTES:]
    plan = validate_plan(plan)
    if encode_plan(plan) != encoded:
        raise SpeechAnnotationError("non-canonical plan wire")
    return plan


def encode_result(value: Record) -> bytes:
    result = validate_result(value)
    return _result_body(result) + result["result_sha256"]


def decode_result(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != RESULT_BYTES
        or encoded[:8] != RESULT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != RESULT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != RESULT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[832:RESULT_BODY_BYTES])
    ):
        raise SpeechAnnotationError("invalid result wire")
    result: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(RESULT_SCALARS)
    }
    result.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(RESULT_DIGESTS)
        }
    )
    result["words"] = tuple(
        struct.unpack_from("<6Q", encoded, 544 + index * 48)
        for index in range(MAXIMUM_WORDS)
    )
    result["speakers"] = tuple(
        encoded[736 + index * 32 : 768 + index * 32]
        for index in range(MAXIMUM_SPEAKERS)
    )
    result["result_sha256"] = encoded[RESULT_BODY_BYTES:]
    result = validate_result(result)
    if encode_result(result) != encoded:
        raise SpeechAnnotationError("non-canonical result wire")
    return result
