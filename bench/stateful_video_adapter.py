"""Independent exact-integer stateful VFR video fixture."""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Any

from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import video_segment_adapter as video


class StatefulVideoAdapterError(ValueError):
    """A VFR window, retained state, plan, or transition is invalid."""


Record = dict[str, Any]
FRAME_CAPACITY = 4
FRAME_WINDOW_ABI = 0x475646524D000001
FRAME_WINDOW_BYTES = 576
FRAME_WINDOW_BODY_BYTES = FRAME_WINDOW_BYTES - 32
FRAME_WINDOW_MAGIC = b"GVFRM1\x00\x00"
FRAME_WINDOW_DOMAIN = b"glacier-video-vfr-frame-window-v1\x00"
TIMESTAMP_PAYLOAD_DOMAIN = b"glacier-video-vfr-timestamp-payload-v1\x00"
REFERENCE_ADAPTER_ABI = 0x5354565646520001
REFERENCE_ARTIFACT_ABI = 0x5354565347000001
REFERENCE_STATE_BYTES = 48
REFERENCE_INPUT_FEATURES = FRAME_CAPACITY
REFERENCE_OUTPUT_BYTES = video.VIDEO_SEGMENT_BYTES
REFERENCE_WEIGHTS = bytes((1, 2, 3, 4))
REFERENCE_FIRST_FEATURES = bytes((3, 1, 0, 0))
REFERENCE_SECOND_FEATURES = bytes((3, 2, 0, 0))
WINDOW_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "first_frame_ordinal",
    "frame_count",
    "target_numerator",
    "target_denominator",
    "previous_end_tick",
    "start_tick",
    "end_tick",
    "discontinuity_before_ticks",
    "duration_transition_count",
    "keyframe_count",
)
WINDOW_ARRAYS = (
    "frame_ordinals",
    "presentation_ticks",
    "duration_ticks",
    "keyframe_flags",
)
WINDOW_DIGESTS = (
    "media_object_sha256",
    "processor_bundle_sha256",
    "cache_bundle_sha256",
    "ownership_sha256",
    "frame_payload_sha256",
    "timestamp_payload_sha256",
    "previous_window_sha256",
    "challenge_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= model.U64_MAX:
        raise StatefulVideoAdapterError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or not any(value):
        raise StatefulVideoAdapterError("invalid digest")
    return value


def _window_body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in WINDOW_SCALARS)
        arrays = tuple(value[field] for field in WINDOW_ARRAYS)
        digests = tuple(value[field] for field in WINDOW_DIGESTS)
    except (KeyError, TypeError):
        raise StatefulVideoAdapterError("invalid frame window") from None
    output = bytearray(FRAME_WINDOW_BODY_BYTES)
    output[:32] = (
        FRAME_WINDOW_MAGIC
        + _u64(FRAME_WINDOW_ABI)
        + _u64(FRAME_WINDOW_BYTES)
        + _u64(0)
    )
    output[32:136] = b"".join(_u64(value) for value in scalars)
    for array_index, values in enumerate(arrays):
        if not isinstance(values, tuple) or len(values) != FRAME_CAPACITY:
            raise StatefulVideoAdapterError("invalid frame array")
        start = 160 + array_index * 32
        output[start : start + 32] = b"".join(
            _u64(value) for value in values
        )
    output[288:544] = b"".join(_digest(value) for value in digests)
    return bytes(output)


def window_root(value: Record) -> bytes:
    return hashlib.sha256(FRAME_WINDOW_DOMAIN + _window_body(value)).digest()


def timestamp_payload_root(value: Record) -> bytes:
    try:
        count = value["frame_count"]
        body = b"".join(
            (
                _u64(value["request_epoch"]),
                _u64(value["generation"]),
                _u64(count),
                _u64(value["target_numerator"]),
                _u64(value["target_denominator"]),
            )
        )
        for index in range(count):
            body += b"".join(
                _u64(value[field][index])
                for field in WINDOW_ARRAYS
            )
    except (KeyError, TypeError):
        raise StatefulVideoAdapterError(
            "invalid timestamp payload"
        ) from None
    return hashlib.sha256(TIMESTAMP_PAYLOAD_DOMAIN + body).digest()


def validate_window(value: Record) -> Record:
    fields = WINDOW_SCALARS + WINDOW_ARRAYS + WINDOW_DIGESTS + (
        "window_sha256",
    )
    try:
        window = {field: value[field] for field in fields}
        for field in WINDOW_SCALARS:
            _u64(window[field])
        for field in WINDOW_DIGESTS + ("window_sha256",):
            _digest(window[field])
        for field in WINDOW_ARRAYS:
            if (
                not isinstance(window[field], tuple)
                or len(window[field]) != FRAME_CAPACITY
            ):
                raise StatefulVideoAdapterError("invalid frame array")
            for item in window[field]:
                _u64(item)
    except (KeyError, TypeError):
        raise StatefulVideoAdapterError("invalid frame window") from None
    count = window["frame_count"]
    if (
        window["request_epoch"] == 0
        or window["generation"] == 0
        or window["segment_index"] == 0
        or not 0 < count <= FRAME_CAPACITY
        or window["target_numerator"] == 0
        or window["target_denominator"] == 0
        or math.gcd(
            window["target_numerator"],
            window["target_denominator"],
        )
        != 1
        or window["first_frame_ordinal"] != window["frame_ordinals"][0]
        or window["start_tick"] != window["presentation_ticks"][0]
        or window["start_tick"] < window["previous_end_tick"]
        or window["discontinuity_before_ticks"]
        != window["start_tick"] - window["previous_end_tick"]
        or window["start_tick"] >= window["end_tick"]
    ):
        raise StatefulVideoAdapterError("invalid frame window")
    transitions = 0
    keyframes = 0
    for index in range(count):
        duration = window["duration_ticks"][index]
        keyframe = window["keyframe_flags"][index]
        if duration == 0 or keyframe not in (0, 1):
            raise StatefulVideoAdapterError("invalid frame window")
        keyframes += keyframe
        if index:
            if (
                window["frame_ordinals"][index]
                != window["frame_ordinals"][index - 1] + 1
                or window["presentation_ticks"][index]
                != window["presentation_ticks"][index - 1]
                + window["duration_ticks"][index - 1]
            ):
                raise StatefulVideoAdapterError("invalid frame window")
            transitions += (
                window["duration_ticks"][index]
                != window["duration_ticks"][index - 1]
            )
    expected_end = (
        window["presentation_ticks"][count - 1]
        + window["duration_ticks"][count - 1]
    )
    if (
        expected_end > model.U64_MAX
        or window["end_tick"] != expected_end
        or window["duration_transition_count"] != transitions
        or window["keyframe_count"] != keyframes
        or keyframes == 0
        or window["timestamp_payload_sha256"]
        != timestamp_payload_root(window)
    ):
        raise StatefulVideoAdapterError("invalid frame window")
    for field in WINDOW_ARRAYS:
        if any(window[field][count:]):
            raise StatefulVideoAdapterError("non-canonical frame padding")
    if window["window_sha256"] != window_root(window):
        raise StatefulVideoAdapterError("invalid frame window root")
    return window


def make_window(
    *,
    request_epoch: int,
    generation: int,
    segment_index: int,
    target_base: tuple[int, int],
    previous_end_tick: int,
    frame_ordinals: tuple[int, ...],
    presentation_ticks: tuple[int, ...],
    duration_ticks: tuple[int, ...],
    keyframe_flags: tuple[int, ...],
    digests: Record,
) -> Record:
    count = len(frame_ordinals)
    if (
        not 0 < count <= FRAME_CAPACITY
        or len(presentation_ticks) != count
        or len(duration_ticks) != count
        or len(keyframe_flags) != count
    ):
        raise StatefulVideoAdapterError("invalid frame arrays")
    def padded(values: tuple[int, ...]) -> tuple[int, ...]:
        return tuple(values) + (0,) * (FRAME_CAPACITY - count)
    end_tick = presentation_ticks[-1] + duration_ticks[-1]
    if end_tick > model.U64_MAX or presentation_ticks[0] < previous_end_tick:
        raise StatefulVideoAdapterError("invalid frame span")
    transitions = sum(
        duration_ticks[index] != duration_ticks[index - 1]
        for index in range(1, count)
    )
    window: Record = {
        "request_epoch": request_epoch,
        "generation": generation,
        "segment_index": segment_index,
        "first_frame_ordinal": frame_ordinals[0],
        "frame_count": count,
        "target_numerator": target_base[0],
        "target_denominator": target_base[1],
        "previous_end_tick": previous_end_tick,
        "start_tick": presentation_ticks[0],
        "end_tick": end_tick,
        "discontinuity_before_ticks": (
            presentation_ticks[0] - previous_end_tick
        ),
        "duration_transition_count": transitions,
        "keyframe_count": sum(keyframe_flags),
        "frame_ordinals": padded(frame_ordinals),
        "presentation_ticks": padded(presentation_ticks),
        "duration_ticks": padded(duration_ticks),
        "keyframe_flags": padded(keyframe_flags),
        **{
            field: digests[field]
            for field in WINDOW_DIGESTS
            if field != "timestamp_payload_sha256"
        },
    }
    window["timestamp_payload_sha256"] = timestamp_payload_root(window)
    window["window_sha256"] = window_root(window)
    return validate_window(window)


def validate_predecessor(previous_value: Record, next_value: Record) -> None:
    previous = validate_window(previous_value)
    next_window = validate_window(next_value)
    if (
        next_window["request_epoch"] != previous["request_epoch"]
        or next_window["generation"] != previous["generation"] + 1
        or next_window["segment_index"] != previous["segment_index"] + 1
        or next_window["first_frame_ordinal"]
        != previous["first_frame_ordinal"] + previous["frame_count"]
        or next_window["previous_end_tick"] != previous["end_tick"]
        or next_window["target_numerator"] != previous["target_numerator"]
        or next_window["target_denominator"] != previous["target_denominator"]
        or next_window["media_object_sha256"]
        != previous["media_object_sha256"]
        or next_window["processor_bundle_sha256"]
        != previous["processor_bundle_sha256"]
        or next_window["cache_bundle_sha256"]
        != previous["cache_bundle_sha256"]
        or next_window["ownership_sha256"]
        != previous["ownership_sha256"]
        or next_window["previous_window_sha256"]
        != previous["window_sha256"]
        or next_window["challenge_sha256"]
        != previous["challenge_sha256"]
    ):
        raise StatefulVideoAdapterError("invalid frame predecessor")


def encode_window(value: Record) -> bytes:
    window = validate_window(value)
    return _window_body(window) + window["window_sha256"]


def decode_window(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != FRAME_WINDOW_BYTES
        or encoded[:8] != FRAME_WINDOW_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != FRAME_WINDOW_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != FRAME_WINDOW_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[136:160])
    ):
        raise StatefulVideoAdapterError("invalid frame window wire")
    window: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(WINDOW_SCALARS)
    }
    for array_index, field in enumerate(WINDOW_ARRAYS):
        start = 160 + array_index * 32
        window[field] = tuple(
            struct.unpack_from("<Q", encoded, start + index * 8)[0]
            for index in range(FRAME_CAPACITY)
        )
    window.update(
        {
            field: encoded[288 + index * 32 : 320 + index * 32]
            for index, field in enumerate(WINDOW_DIGESTS)
        }
    )
    window["window_sha256"] = encoded[FRAME_WINDOW_BODY_BYTES:]
    window = validate_window(window)
    if encode_window(window) != encoded:
        raise StatefulVideoAdapterError("non-canonical frame window")
    return window


def validate_state(value: Record) -> Record:
    fields = (
        "segment_index",
        "next_frame_ordinal",
        "last_end_tick",
        "target_numerator",
        "target_denominator",
        "emitted_segments",
    )
    try:
        state = {field: value[field] for field in fields}
        for field in fields:
            _u64(state[field])
    except (KeyError, TypeError):
        raise StatefulVideoAdapterError("invalid video state") from None
    if (
        state["target_numerator"] == 0
        or state["target_denominator"] == 0
        or math.gcd(
            state["target_numerator"],
            state["target_denominator"],
        )
        != 1
        or state["segment_index"] != state["emitted_segments"]
    ):
        raise StatefulVideoAdapterError("invalid video state")
    return state


def encode_state(value: Record) -> bytes:
    state = validate_state(value)
    return b"".join(_u64(state[field]) for field in state)


def decode_state(encoded: bytes) -> Record:
    if not isinstance(encoded, bytes) or len(encoded) != REFERENCE_STATE_BYTES:
        raise StatefulVideoAdapterError("invalid video state wire")
    fields = (
        "segment_index",
        "next_frame_ordinal",
        "last_end_tick",
        "target_numerator",
        "target_denominator",
        "emitted_segments",
    )
    state = {
        field: struct.unpack_from("<Q", encoded, index * 8)[0]
        for index, field in enumerate(fields)
    }
    state = validate_state(state)
    if encode_state(state) != encoded:
        raise StatefulVideoAdapterError("non-canonical video state")
    return state


def initialize_state(first_window_value: Record) -> Record:
    window = validate_window(first_window_value)
    if window["generation"] != 1 or window["segment_index"] != 1:
        raise StatefulVideoAdapterError("invalid first window")
    return validate_state(
        {
            "segment_index": 0,
            "next_frame_ordinal": window["first_frame_ordinal"],
            "last_end_tick": window["previous_end_tick"],
            "target_numerator": window["target_numerator"],
            "target_denominator": window["target_denominator"],
            "emitted_segments": 0,
        }
    )


def make_manifest(weights: bytes = REFERENCE_WEIGHTS) -> Record:
    if not isinstance(weights, bytes) or len(weights) != len(REFERENCE_WEIGHTS):
        raise StatefulVideoAdapterError("invalid weights")
    return model.make_artifact(
        family=6,
        artifact_abi=REFERENCE_ARTIFACT_ABI,
        input_kind=5,
        output_kind=10,
        numerical_policy=model.EXACT_INTEGER,
        max_batch_items=1,
        input_features=REFERENCE_INPUT_FEATURES,
        output_dimensions=REFERENCE_OUTPUT_BYTES,
        input_element_bytes=1,
        output_element_bytes=1,
        weight_element_bytes=1,
        weights=weights,
        metadata_sha256=model.sha256(
            b"stateful VFR video fixture metadata"
        ),
        license_sha256=model.sha256(b"fixture-only license"),
    )


def make_plan(
    *,
    manifest: Record,
    model_publication: Record,
    state_publication: Record,
    window_value: Record,
    previous_plan_sha256: bytes,
) -> Record:
    publication = stateful.validate_publication(state_publication)
    window = validate_window(window_value)
    generation = publication["current_step"] + 1
    if (
        generation > model.U64_MAX
        or generation != window["generation"]
        or publication["state_bytes"] != REFERENCE_STATE_BYTES
        or model_publication["request_epoch"] != publication["request_epoch"]
        or model_publication["next_sequence"] != publication["current_step"]
        or model_publication["visible_results"] != publication["current_step"]
        or model_publication["artifact_sha256"]
        != manifest["artifact_sha256"]
        or model_publication["previous_result_sha256"]
        != publication["previous_result_sha256"]
        or publication["challenge_sha256"] != window["challenge_sha256"]
    ):
        raise StatefulVideoAdapterError("invalid plan binding")
    return model.make_plan(
        manifest,
        operation=10,
        request_epoch=publication["request_epoch"],
        generation=generation,
        batch_items=1,
        publication_next_sequence=model_publication["next_sequence"],
        maximum_absolute_output=255,
        required_capabilities=0,
        scratch_bytes=REFERENCE_OUTPUT_BYTES,
        claim={
            "capsule_bytes": len(REFERENCE_WEIGHTS),
            "kv_bytes": 0,
            "activation_bytes": REFERENCE_INPUT_FEATURES,
            "partial_bytes": REFERENCE_OUTPUT_BYTES,
            "logits_bytes": 0,
            "output_journal_bytes": (
                REFERENCE_OUTPUT_BYTES + REFERENCE_STATE_BYTES
            ),
            "staging_bytes": REFERENCE_STATE_BYTES,
            "device_bytes": 0,
            "io_bytes": 0,
            "queue_slots": 1,
        },
        digests={
            "media_object_sha256": window["media_object_sha256"],
            "processor_state_sha256": publication["publication_sha256"],
            "processor_bundle_sha256": window[
                "processor_bundle_sha256"
            ],
            "cache_bundle_sha256": window["cache_bundle_sha256"],
            "cache_payload_sha256": publication["current_state_sha256"],
            "ownership_sha256": window["ownership_sha256"],
            "challenge_sha256": window["challenge_sha256"],
            "previous_plan_sha256": previous_plan_sha256,
            "input_schema_sha256": window["window_sha256"],
            "output_schema_sha256": video.schema_root(),
        },
    )


def adapter_root(manifest: Record) -> bytes:
    return stateful.adapter_descriptor_root(
        adapter_abi=REFERENCE_ADAPTER_ABI,
        family=manifest["family"],
        operation=10,
        input_kind=manifest["input_kind"],
        output_kind=manifest["output_kind"],
        numerical_policy=manifest["numerical_policy"],
        max_batch_items=1,
        max_input_features=REFERENCE_INPUT_FEATURES,
        max_output_dimensions=REFERENCE_OUTPUT_BYTES,
        allowed_capabilities=0,
        implementation_sha256=model.sha256(
            b"reference exact stateful VFR video v1"
        ),
    )


def reference_step(
    *,
    plan: Record,
    window_value: Record,
    previous_segment_sha256: bytes,
    current_state_wire: bytes,
    features: bytes,
    weights: bytes = REFERENCE_WEIGHTS,
) -> tuple[bytes, bytes]:
    window = validate_window(window_value)
    state = decode_state(current_state_wire)
    if (
        not isinstance(features, bytes)
        or len(features) != REFERENCE_INPUT_FEATURES
        or not isinstance(weights, bytes)
        or len(weights) != len(REFERENCE_WEIGHTS)
        or not isinstance(previous_segment_sha256, bytes)
        or len(previous_segment_sha256) != 32
        or not any(previous_segment_sha256)
        or state["segment_index"] + 1 != window["segment_index"]
        or state["next_frame_ordinal"] != window["first_frame_ordinal"]
        or state["last_end_tick"] != window["previous_end_tick"]
        or state["target_numerator"] != window["target_numerator"]
        or state["target_denominator"] != window["target_denominator"]
        or model.sha256(features) != window["frame_payload_sha256"]
    ):
        raise StatefulVideoAdapterError("invalid step binding")
    keyframe_index = window["keyframe_flags"].index(1)
    segment: Record = {
        "request_epoch": plan["request_epoch"],
        "generation": plan["generation"],
        "segment_index": window["segment_index"],
        "first_frame": window["first_frame_ordinal"],
        "last_frame": window["frame_ordinals"][window["frame_count"] - 1],
        "frame_count": window["frame_count"],
        "frame_stride": 1,
        "keyframe_ordinal": window["frame_ordinals"][keyframe_index],
        "eviction_boundary": window["first_frame_ordinal"],
        "cache_generation": window["generation"],
        "target_numerator": window["target_numerator"],
        "target_denominator": window["target_denominator"],
        "target_start_tick": window["start_tick"],
        "target_end_tick": window["end_tick"],
        "event_id": features[0] + weights[0],
        "confidence_ppm": 800_000 + features[1] * 10_000,
        "media_object_sha256": plan["media_object_sha256"],
        "processor_state_sha256": plan["processor_state_sha256"],
        "processor_bundle_sha256": plan["processor_bundle_sha256"],
        "cache_bundle_sha256": plan["cache_bundle_sha256"],
        "cache_payload_sha256": plan["cache_payload_sha256"],
        "ownership_sha256": plan["ownership_sha256"],
        "selection_sha256": window["window_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
        "previous_segment_sha256": previous_segment_sha256,
    }
    segment["segment_sha256"] = video.segment_root(segment)
    segment = video.validate_segment(segment)
    output = video.encode_segment(segment)
    next_state = {
        "segment_index": window["segment_index"],
        "next_frame_ordinal": (
            window["first_frame_ordinal"] + window["frame_count"]
        ),
        "last_end_tick": window["end_tick"],
        "target_numerator": window["target_numerator"],
        "target_denominator": window["target_denominator"],
        "emitted_segments": state["emitted_segments"] + 1,
    }
    return output, encode_state(next_state)
