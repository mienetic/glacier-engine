"""Independent verifier for multimodal processor and synchronized cache state."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media


class MediaProcessorStateError(ValueError):
    """A processor, sync, or bundle record is invalid."""


Record = dict[str, Any]
PROCESSOR_STATE_ABI = 0x474D505300000001
PROCESSOR_STATE_MAGIC = b"GMPRST1\x00"
PROCESSOR_STATE_BODY_BYTES = 480
PROCESSOR_STATE_BYTES = 512
SYNC_STATE_ABI = 0x474D535900000001
SYNC_STATE_MAGIC = b"GMSYNC1\x00"
SYNC_STATE_BODY_BYTES = 480
SYNC_STATE_BYTES = 512
PROCESSOR_BUNDLE_ABI = 0x474D504200000001
PROCESSOR_BUNDLE_MAGIC = b"GMPBND1\x00"
PROCESSOR_COUNT = 3
PROCESSOR_BUNDLE_HEADER_BYTES = 192
PROCESSOR_BUNDLE_BODY_BYTES = 2240
PROCESSOR_BUNDLE_BYTES = 2272
ALLOWED_FLAGS = 0
PROCESSOR_STATE_DOMAIN = b"glacier-media-processor-state-v1\x00"
SYNC_STATE_DOMAIN = b"glacier-media-processor-sync-state-v1\x00"
PROCESSOR_BUNDLE_DOMAIN = (
    b"glacier-media-processor-state-bundle-v1\x00"
)
OWNERSHIP_SET_DOMAIN = (
    b"glacier-media-processor-ownership-set-v1\x00"
)
OUTPUT_SET_DOMAIN = b"glacier-media-processor-output-set-v1\x00"
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
DIGEST_FIELDS = (
    "media_object_sha256",
    "processor_plan_sha256",
    "previous_state_sha256",
    "challenge_sha256",
    "cache_content_sha256",
    "output_chain_sha256",
    "ownership_receipt_sha256",
    "decoder_state_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaProcessorStateError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise MediaProcessorStateError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _checked_add(left: int, right: int) -> int:
    result = left + right
    _u64(result)
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    _u64(result)
    return result


def _state_from_plan(plan: Record) -> Record:
    try:
        result = {
            "kind": plan["kind"],
            "request_epoch": plan["request_epoch"],
            "generation": plan["generation"],
            "stream_key": plan["stream_key"],
            "timeline_numerator": plan["timeline_numerator"],
            "timeline_denominator": plan["timeline_denominator"],
            "cursor_units": 0,
            "produced_units": 0,
            "cache_entries": 0,
            "cache_bytes": 0,
            "parameters": [0] * 8,
            **{field: plan[field] for field in DIGEST_FIELDS},
            "state_sha256": ZERO_DIGEST,
        }
    except (KeyError, TypeError):
        raise MediaProcessorStateError("invalid state plan") from None
    return result


def make_image_state(
    plan: Record,
    processed_tiles: int,
    total_tiles: int,
    tile_width: int,
    tile_height: int,
    patch_width: int,
    patch_height: int,
    channels: int,
) -> Record:
    elements = _checked_mul(
        _checked_mul(patch_width, patch_height),
        channels,
    )
    normalized = _checked_mul(processed_tiles, elements)
    state = _state_from_plan(plan)
    state.update(
        cursor_units=processed_tiles,
        produced_units=normalized,
        cache_entries=processed_tiles,
        cache_bytes=_checked_mul(normalized, 2),
        parameters=[
            processed_tiles,
            total_tiles,
            tile_width,
            tile_height,
            patch_width,
            patch_height,
            channels,
            normalized,
        ],
    )
    state["state_sha256"] = state_root(state)
    return _state(state)


def make_audio_state(
    plan: Record,
    feature_frames: int,
    sample_rate: int,
    channels: int,
    window_samples: int,
    hop_samples: int,
    feature_bins: int,
    feature_bytes: int,
) -> Record:
    if feature_frames <= 0 or window_samples < hop_samples:
        raise MediaProcessorStateError("invalid audio window")
    context_samples = window_samples - hop_samples
    cursor = _checked_add(
        window_samples,
        _checked_mul(feature_frames - 1, hop_samples),
    )
    cache_bytes = _checked_add(
        _checked_mul(
            _checked_mul(feature_frames, feature_bins),
            feature_bytes,
        ),
        _checked_mul(
            _checked_mul(context_samples, channels),
            2,
        ),
    )
    state = _state_from_plan(plan)
    state.update(
        cursor_units=cursor,
        produced_units=feature_frames,
        cache_entries=feature_frames,
        cache_bytes=cache_bytes,
        parameters=[
            sample_rate,
            channels,
            window_samples,
            hop_samples,
            feature_bins,
            context_samples,
            feature_bytes,
            0,
        ],
    )
    state["state_sha256"] = state_root(state)
    return _state(state)


def make_video_state(
    plan: Record,
    window_capacity: int,
    bytes_per_entry: int,
    window_start_frame: int,
    window_end_frame: int,
    last_keyframe: int,
) -> Record:
    cache_entries = window_end_frame - window_start_frame
    if cache_entries < 0:
        raise MediaProcessorStateError("invalid video window")
    state = _state_from_plan(plan)
    state.update(
        cursor_units=window_end_frame,
        produced_units=window_end_frame,
        cache_entries=cache_entries,
        cache_bytes=_checked_mul(cache_entries, bytes_per_entry),
        parameters=[
            window_capacity,
            bytes_per_entry,
            window_start_frame,
            window_end_frame,
            last_keyframe,
            plan["generation"],
            window_start_frame,
            0,
        ],
    )
    state["state_sha256"] = state_root(state)
    return _state(state)


def _state(value: Record) -> Record:
    scalar_fields = (
        "kind",
        "request_epoch",
        "generation",
        "stream_key",
        "timeline_numerator",
        "timeline_denominator",
        "cursor_units",
        "produced_units",
        "cache_entries",
        "cache_bytes",
    )
    try:
        result = {field: value[field] for field in scalar_fields}
        result["parameters"] = list(value["parameters"])
        for field in DIGEST_FIELDS:
            result[field] = _digest(
                value[field],
                allow_zero=field == "previous_state_sha256",
            )
        result["state_sha256"] = _digest(value["state_sha256"])
    except (KeyError, TypeError):
        raise MediaProcessorStateError("invalid processor state") from None
    for field in scalar_fields:
        _u64(result[field])
    if len(result["parameters"]) != 8:
        raise MediaProcessorStateError("invalid parameters")
    for parameter in result["parameters"]:
        _u64(parameter)
    if (
        result["kind"] not in (media.IMAGE, media.AUDIO, media.VIDEO)
        or result["request_epoch"] == 0
        or result["generation"] == 0
        or result["stream_key"] == 0
        or result["timeline_denominator"] == 0
        or result["cursor_units"] == 0
        or result["produced_units"] == 0
        or result["cache_entries"] == 0
        or result["cache_bytes"] == 0
        or (
            result["generation"] == 1
            and result["previous_state_sha256"] != ZERO_DIGEST
        )
        or (
            result["generation"] != 1
            and result["previous_state_sha256"] == ZERO_DIGEST
        )
    ):
        raise MediaProcessorStateError("contradictory state")
    if result["kind"] == media.IMAGE:
        _validate_image(result)
    elif result["kind"] == media.AUDIO:
        _validate_audio(result)
    else:
        _validate_video(result)
    if state_root(result) != result["state_sha256"]:
        raise MediaProcessorStateError("state root mismatch")
    return result


def _validate_image(state: Record) -> None:
    p = state["parameters"]
    expected_units = _checked_mul(
        _checked_mul(_checked_mul(p[0], p[4]), p[5]),
        p[6],
    )
    if (
        state["timeline_numerator"] != 0
        or state["timeline_denominator"] != 1
        or p[0] != state["cursor_units"]
        or not 0 < p[0] <= p[1]
        or min(p[2:7]) <= 0
        or p[4] > p[2]
        or p[5] > p[3]
        or p[7] != state["produced_units"]
        or state["produced_units"] != expected_units
        or state["cache_entries"] != p[0]
        or state["cache_bytes"] != _checked_mul(expected_units, 2)
    ):
        raise MediaProcessorStateError("invalid image state")


def _validate_audio(state: Record) -> None:
    p = state["parameters"]
    expected_cursor = _checked_add(
        p[2],
        _checked_mul(state["produced_units"] - 1, p[3]),
    )
    expected_bytes = _checked_add(
        _checked_mul(
            _checked_mul(state["produced_units"], p[4]),
            p[6],
        ),
        _checked_mul(_checked_mul(p[5], p[1]), 2),
    )
    if (
        state["timeline_numerator"] != 1
        or state["timeline_denominator"] != p[0]
        or min(p[:5]) <= 0
        or p[3] > p[2]
        or p[5] != p[2] - p[3]
        or p[6] == 0
        or p[7] != 0
        or state["cursor_units"] != expected_cursor
        or state["cache_entries"] != state["produced_units"]
        or state["cache_bytes"] != expected_bytes
    ):
        raise MediaProcessorStateError("invalid audio state")


def _validate_video(state: Record) -> None:
    p = state["parameters"]
    if (
        state["timeline_numerator"] == 0
        or p[0] == 0
        or p[1] == 0
        or p[2] >= p[3]
        or p[3] != state["cursor_units"]
        or state["produced_units"] != state["cursor_units"]
        or p[3] - p[2] > p[0]
        or not p[2] <= p[4] < p[3]
        or p[5] != state["generation"]
        or p[6] != p[2]
        or p[7] != 0
        or state["cache_entries"] != p[3] - p[2]
        or state["cache_bytes"]
        != _checked_mul(state["cache_entries"], p[1])
    ):
        raise MediaProcessorStateError("invalid video state")


def _state_body(value: Record) -> bytes:
    state = dict(value)
    output = bytearray(PROCESSOR_STATE_BODY_BYTES)
    output[:112] = b"".join(
        (
            PROCESSOR_STATE_MAGIC,
            _u64(PROCESSOR_STATE_ABI),
            _u64(PROCESSOR_STATE_BYTES),
            _u64(ALLOWED_FLAGS),
            *(
                _u64(state[field])
                for field in (
                    "kind",
                    "request_epoch",
                    "generation",
                    "stream_key",
                    "timeline_numerator",
                    "timeline_denominator",
                    "cursor_units",
                    "produced_units",
                    "cache_entries",
                    "cache_bytes",
                )
            ),
        )
    )
    output[112:176] = b"".join(
        _u64(value) for value in state["parameters"]
    )
    for index, field in enumerate(DIGEST_FIELDS):
        output[192 + index * 32 : 224 + index * 32] = state[field]
    return bytes(output)


def state_root(value: Record) -> bytes:
    return _hash(PROCESSOR_STATE_DOMAIN, _state_body(value))


def encode_state(value: Record) -> bytes:
    state = _state(value)
    return _state_body(state) + state["state_sha256"]


def decode_state(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PROCESSOR_STATE_BYTES
        or encoded[:8] != PROCESSOR_STATE_MAGIC
        or _read(encoded, 8) != PROCESSOR_STATE_ABI
        or _read(encoded, 16) != PROCESSOR_STATE_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or any(encoded[176:192])
        or any(encoded[448:PROCESSOR_STATE_BODY_BYTES])
    ):
        raise MediaProcessorStateError("invalid state wire")
    return _state(
        {
            "kind": _read(encoded, 32),
            "request_epoch": _read(encoded, 40),
            "generation": _read(encoded, 48),
            "stream_key": _read(encoded, 56),
            "timeline_numerator": _read(encoded, 64),
            "timeline_denominator": _read(encoded, 72),
            "cursor_units": _read(encoded, 80),
            "produced_units": _read(encoded, 88),
            "cache_entries": _read(encoded, 96),
            "cache_bytes": _read(encoded, 104),
            "parameters": [
                _read(encoded, 112 + index * 8) for index in range(8)
            ],
            **{
                field: encoded[
                    192 + index * 32 : 224 + index * 32
                ]
                for index, field in enumerate(DIGEST_FIELDS)
            },
            "state_sha256": encoded[PROCESSOR_STATE_BODY_BYTES:],
        }
    )


def _digest_set_root(domain: bytes, digests: list[bytes]) -> bytes:
    if len(digests) != PROCESSOR_COUNT:
        raise MediaProcessorStateError("invalid digest set")
    return _hash(domain, *(_digest(value) for value in digests))


def _units_to_ticks(
    units: int,
    numerator: int,
    denominator: int,
    master_ticks_per_second: int,
) -> int:
    if numerator == 0 or denominator == 0 or master_ticks_per_second == 0:
        raise MediaProcessorStateError("invalid time base")
    scaled = _checked_mul(
        _checked_mul(units, numerator),
        master_ticks_per_second,
    )
    if scaled % denominator:
        raise MediaProcessorStateError("non-integral sync mapping")
    return scaled // denominator


def make_sync_state(states: list[Record], plan: Record) -> Record:
    checked = _state_set(states)
    try:
        master = plan["master_ticks_per_second"]
        audio_tick = _units_to_ticks(
            checked[1]["cursor_units"],
            checked[1]["timeline_numerator"],
            checked[1]["timeline_denominator"],
            master,
        )
        video_tick = _units_to_ticks(
            checked[2]["cursor_units"],
            checked[2]["timeline_numerator"],
            checked[2]["timeline_denominator"],
            master,
        )
        sync = {
            "generation": plan["generation"],
            "request_epoch": plan["request_epoch"],
            "master_ticks_per_second": master,
            "maximum_skew_ticks": plan["maximum_skew_ticks"],
            "watermark_tick": min(audio_tick, video_tick),
            "audio_end_tick": audio_tick,
            "video_end_tick": video_tick,
            "image_barrier_units": checked[0]["cursor_units"],
            "image_total_units": checked[0]["parameters"][1],
            "processor_state_sha256": [
                state["state_sha256"] for state in checked
            ],
            "previous_sync_sha256": plan.get(
                "previous_sync_sha256",
                ZERO_DIGEST,
            ),
            "challenge_sha256": plan["challenge_sha256"],
            "sync_policy_sha256": plan["sync_policy_sha256"],
            "ownership_set_sha256": _digest_set_root(
                OWNERSHIP_SET_DOMAIN,
                [
                    state["ownership_receipt_sha256"]
                    for state in checked
                ],
            ),
            "output_set_sha256": _digest_set_root(
                OUTPUT_SET_DOMAIN,
                [state["output_chain_sha256"] for state in checked],
            ),
            "sync_sha256": ZERO_DIGEST,
        }
    except (KeyError, TypeError):
        raise MediaProcessorStateError("invalid sync plan") from None
    sync["sync_sha256"] = sync_root(sync)
    return _sync_against_states(checked, sync)


def _sync(value: Record) -> Record:
    scalar_fields = (
        "generation",
        "request_epoch",
        "master_ticks_per_second",
        "maximum_skew_ticks",
        "watermark_tick",
        "audio_end_tick",
        "video_end_tick",
        "image_barrier_units",
        "image_total_units",
    )
    digest_fields = (
        "previous_sync_sha256",
        "challenge_sha256",
        "sync_policy_sha256",
        "ownership_set_sha256",
        "output_set_sha256",
        "sync_sha256",
    )
    try:
        result = {field: value[field] for field in scalar_fields}
        result["processor_state_sha256"] = [
            _digest(item) for item in value["processor_state_sha256"]
        ]
        for field in digest_fields:
            result[field] = _digest(
                value[field],
                allow_zero=field == "previous_sync_sha256",
            )
    except (KeyError, TypeError):
        raise MediaProcessorStateError("invalid sync state") from None
    for field in scalar_fields:
        _u64(result[field])
    if len(result["processor_state_sha256"]) != PROCESSOR_COUNT:
        raise MediaProcessorStateError("invalid state root count")
    if (
        result["generation"] == 0
        or result["request_epoch"] == 0
        or result["master_ticks_per_second"] == 0
        or result["maximum_skew_ticks"] == 0
        or result["watermark_tick"] == 0
        or result["audio_end_tick"] == 0
        or result["video_end_tick"] == 0
        or not 0
        < result["image_barrier_units"]
        <= result["image_total_units"]
        or result["watermark_tick"]
        != min(result["audio_end_tick"], result["video_end_tick"])
        or abs(result["audio_end_tick"] - result["video_end_tick"])
        > result["maximum_skew_ticks"]
        or (
            result["generation"] == 1
            and result["previous_sync_sha256"] != ZERO_DIGEST
        )
        or (
            result["generation"] != 1
            and result["previous_sync_sha256"] == ZERO_DIGEST
        )
        or sync_root(result) != result["sync_sha256"]
    ):
        raise MediaProcessorStateError("contradictory sync state")
    return result


def _sync_body(value: Record) -> bytes:
    sync = dict(value)
    output = bytearray(SYNC_STATE_BODY_BYTES)
    output[:112] = b"".join(
        (
            SYNC_STATE_MAGIC,
            _u64(SYNC_STATE_ABI),
            _u64(SYNC_STATE_BYTES),
            _u64(ALLOWED_FLAGS),
            *(
                _u64(sync[field])
                for field in (
                    "generation",
                    "request_epoch",
                    "master_ticks_per_second",
                    "maximum_skew_ticks",
                    "watermark_tick",
                    "audio_end_tick",
                    "video_end_tick",
                    "image_barrier_units",
                    "image_total_units",
                )
            ),
            _u64(PROCESSOR_COUNT),
        )
    )
    digests = [
        *sync["processor_state_sha256"],
        sync["previous_sync_sha256"],
        sync["challenge_sha256"],
        sync["sync_policy_sha256"],
        sync["ownership_set_sha256"],
        sync["output_set_sha256"],
    ]
    for index, digest in enumerate(digests):
        output[128 + index * 32 : 160 + index * 32] = digest
    return bytes(output)


def sync_root(value: Record) -> bytes:
    return _hash(SYNC_STATE_DOMAIN, _sync_body(value))


def encode_sync(value: Record) -> bytes:
    sync = _sync(value)
    return _sync_body(sync) + sync["sync_sha256"]


def decode_sync(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != SYNC_STATE_BYTES
        or encoded[:8] != SYNC_STATE_MAGIC
        or _read(encoded, 8) != SYNC_STATE_ABI
        or _read(encoded, 16) != SYNC_STATE_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or _read(encoded, 104) != PROCESSOR_COUNT
        or any(encoded[112:128])
        or any(encoded[384:SYNC_STATE_BODY_BYTES])
    ):
        raise MediaProcessorStateError("invalid sync wire")
    roots = [
        encoded[128 + index * 32 : 160 + index * 32]
        for index in range(8)
    ]
    return _sync(
        {
            "generation": _read(encoded, 32),
            "request_epoch": _read(encoded, 40),
            "master_ticks_per_second": _read(encoded, 48),
            "maximum_skew_ticks": _read(encoded, 56),
            "watermark_tick": _read(encoded, 64),
            "audio_end_tick": _read(encoded, 72),
            "video_end_tick": _read(encoded, 80),
            "image_barrier_units": _read(encoded, 88),
            "image_total_units": _read(encoded, 96),
            "processor_state_sha256": roots[:3],
            "previous_sync_sha256": roots[3],
            "challenge_sha256": roots[4],
            "sync_policy_sha256": roots[5],
            "ownership_set_sha256": roots[6],
            "output_set_sha256": roots[7],
            "sync_sha256": encoded[SYNC_STATE_BODY_BYTES:],
        }
    )


def _state_set(states: list[Record]) -> list[Record]:
    if len(states) != PROCESSOR_COUNT:
        raise MediaProcessorStateError("invalid state count")
    checked = [_state(state) for state in states]
    if [state["kind"] for state in checked] != [
        media.IMAGE,
        media.AUDIO,
        media.VIDEO,
    ]:
        raise MediaProcessorStateError("noncanonical state order")
    first = checked[0]
    if any(
        state["generation"] != first["generation"]
        or state["request_epoch"] != first["request_epoch"]
        or state["challenge_sha256"] != first["challenge_sha256"]
        for state in checked[1:]
    ) or len({state["stream_key"] for state in checked}) != PROCESSOR_COUNT:
        raise MediaProcessorStateError("state metadata mismatch")
    return checked


def _sync_against_states(states: list[Record], value: Record) -> Record:
    checked = _state_set(states)
    sync = _sync(value)
    audio_tick = _units_to_ticks(
        checked[1]["cursor_units"],
        checked[1]["timeline_numerator"],
        checked[1]["timeline_denominator"],
        sync["master_ticks_per_second"],
    )
    video_tick = _units_to_ticks(
        checked[2]["cursor_units"],
        checked[2]["timeline_numerator"],
        checked[2]["timeline_denominator"],
        sync["master_ticks_per_second"],
    )
    if (
        sync["generation"] != checked[0]["generation"]
        or sync["request_epoch"] != checked[0]["request_epoch"]
        or sync["audio_end_tick"] != audio_tick
        or sync["video_end_tick"] != video_tick
        or sync["image_barrier_units"] != checked[0]["cursor_units"]
        or sync["image_total_units"] != checked[0]["parameters"][1]
        or sync["challenge_sha256"] != checked[0]["challenge_sha256"]
        or sync["processor_state_sha256"]
        != [state["state_sha256"] for state in checked]
        or sync["ownership_set_sha256"]
        != _digest_set_root(
            OWNERSHIP_SET_DOMAIN,
            [
                state["ownership_receipt_sha256"]
                for state in checked
            ],
        )
        or sync["output_set_sha256"]
        != _digest_set_root(
            OUTPUT_SET_DOMAIN,
            [state["output_chain_sha256"] for state in checked],
        )
    ):
        raise MediaProcessorStateError("sync/state mismatch")
    return sync


def encode_bundle(states: list[Record], sync_value: Record) -> bytes:
    checked = _state_set(states)
    sync = _sync_against_states(checked, sync_value)
    output = bytearray(PROCESSOR_BUNDLE_BYTES)
    output[:64] = b"".join(
        (
            PROCESSOR_BUNDLE_MAGIC,
            _u64(PROCESSOR_BUNDLE_ABI),
            _u64(PROCESSOR_BUNDLE_BYTES),
            _u64(ALLOWED_FLAGS),
            _u64(sync["generation"]),
            _u64(sync["request_epoch"]),
            _u64(PROCESSOR_COUNT),
            _u64(0),
        )
    )
    for index, state in enumerate(checked):
        output[64 + index * 32 : 96 + index * 32] = state[
            "state_sha256"
        ]
        start = PROCESSOR_BUNDLE_HEADER_BYTES + index * PROCESSOR_STATE_BYTES
        output[start : start + PROCESSOR_STATE_BYTES] = encode_state(state)
    output[160:192] = sync["sync_sha256"]
    sync_start = (
        PROCESSOR_BUNDLE_HEADER_BYTES
        + PROCESSOR_COUNT * PROCESSOR_STATE_BYTES
    )
    output[sync_start : sync_start + SYNC_STATE_BYTES] = encode_sync(sync)
    output[PROCESSOR_BUNDLE_BODY_BYTES:] = _hash(
        PROCESSOR_BUNDLE_DOMAIN,
        output[:PROCESSOR_BUNDLE_BODY_BYTES],
    )
    decode_bundle(bytes(output))
    return bytes(output)


def decode_bundle(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PROCESSOR_BUNDLE_BYTES
        or encoded[:8] != PROCESSOR_BUNDLE_MAGIC
        or _read(encoded, 8) != PROCESSOR_BUNDLE_ABI
        or _read(encoded, 16) != PROCESSOR_BUNDLE_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or _read(encoded, 48) != PROCESSOR_COUNT
        or _read(encoded, 56) != 0
        or encoded[PROCESSOR_BUNDLE_BODY_BYTES:]
        != _hash(
            PROCESSOR_BUNDLE_DOMAIN,
            encoded[:PROCESSOR_BUNDLE_BODY_BYTES],
        )
    ):
        raise MediaProcessorStateError("invalid processor bundle")
    states = []
    for index in range(PROCESSOR_COUNT):
        start = PROCESSOR_BUNDLE_HEADER_BYTES + index * PROCESSOR_STATE_BYTES
        state = decode_state(
            encoded[start : start + PROCESSOR_STATE_BYTES]
        )
        if (
            state["state_sha256"]
            != encoded[64 + index * 32 : 96 + index * 32]
        ):
            raise MediaProcessorStateError("state header root mismatch")
        states.append(state)
    sync_start = (
        PROCESSOR_BUNDLE_HEADER_BYTES
        + PROCESSOR_COUNT * PROCESSOR_STATE_BYTES
    )
    sync = decode_sync(encoded[sync_start : sync_start + SYNC_STATE_BYTES])
    if (
        _read(encoded, 32) != sync["generation"]
        or _read(encoded, 40) != sync["request_epoch"]
        or encoded[160:192] != sync["sync_sha256"]
    ):
        raise MediaProcessorStateError("sync header mismatch")
    _sync_against_states(states, sync)
    return {
        "states": states,
        "sync": sync,
        "bundle_sha256": encoded[PROCESSOR_BUNDLE_BODY_BYTES:],
    }


def validate_successor(previous: Record, successor: Record) -> None:
    prior = decode_bundle(
        encode_bundle(previous["states"], previous["sync"])
    )
    next_bundle = decode_bundle(
        encode_bundle(successor["states"], successor["sync"])
    )
    for old, new in zip(prior["states"], next_bundle["states"]):
        _validate_state_successor(old, new)
    old_sync = prior["sync"]
    new_sync = next_bundle["sync"]
    if (
        new_sync["generation"] != old_sync["generation"] + 1
        or new_sync["request_epoch"] != old_sync["request_epoch"]
        or new_sync["master_ticks_per_second"]
        != old_sync["master_ticks_per_second"]
        or new_sync["maximum_skew_ticks"]
        != old_sync["maximum_skew_ticks"]
        or new_sync["watermark_tick"] < old_sync["watermark_tick"]
        or new_sync["audio_end_tick"] <= old_sync["audio_end_tick"]
        or new_sync["video_end_tick"] <= old_sync["video_end_tick"]
        or new_sync["image_barrier_units"]
        != old_sync["image_barrier_units"] + 1
        or new_sync["image_total_units"] != old_sync["image_total_units"]
        or new_sync["previous_sync_sha256"] != old_sync["sync_sha256"]
        or new_sync["challenge_sha256"] != old_sync["challenge_sha256"]
        or new_sync["sync_policy_sha256"]
        != old_sync["sync_policy_sha256"]
    ):
        raise MediaProcessorStateError("invalid sync successor")


def _validate_state_successor(old: Record, new: Record) -> None:
    if (
        new["generation"] != old["generation"] + 1
        or new["kind"] != old["kind"]
        or new["request_epoch"] != old["request_epoch"]
        or new["stream_key"] != old["stream_key"]
        or new["timeline_numerator"] != old["timeline_numerator"]
        or new["timeline_denominator"] != old["timeline_denominator"]
        or new["media_object_sha256"] != old["media_object_sha256"]
        or new["processor_plan_sha256"] != old["processor_plan_sha256"]
        or new["previous_state_sha256"] != old["state_sha256"]
        or new["challenge_sha256"] != old["challenge_sha256"]
        or new["decoder_state_sha256"] != old["decoder_state_sha256"]
        or new["cache_content_sha256"] == old["cache_content_sha256"]
        or new["output_chain_sha256"] == old["output_chain_sha256"]
        or new["ownership_receipt_sha256"]
        == old["ownership_receipt_sha256"]
    ):
        raise MediaProcessorStateError("invalid state successor")
    if new["kind"] == media.IMAGE:
        valid = (
            new["cursor_units"] == old["cursor_units"] + 1
            and new["parameters"][1:7] == old["parameters"][1:7]
        )
    elif new["kind"] == media.AUDIO:
        valid = (
            new["produced_units"] == old["produced_units"] + 1
            and new["cursor_units"]
            == old["cursor_units"] + old["parameters"][3]
            and new["parameters"] == old["parameters"]
        )
    else:
        expected_end = old["parameters"][3] + 1
        expected_start = max(0, expected_end - old["parameters"][0])
        valid = (
            new["parameters"][0] == old["parameters"][0]
            and new["parameters"][1] == old["parameters"][1]
            and new["parameters"][2] == expected_start
            and new["parameters"][3] == expected_end
            and new["parameters"][5] == old["parameters"][5] + 1
            and new["parameters"][6] == expected_start
            and new["parameters"][7] == 0
        )
    if not valid:
        raise MediaProcessorStateError("invalid modality successor")
