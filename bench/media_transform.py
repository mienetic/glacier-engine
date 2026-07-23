"""Independent deterministic image, audio, and video transform oracle."""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Any

from bench import media_contract as media
from bench import media_decode_fixture as fixture_api


class MediaTransformError(ValueError):
    """A transform plan, source binding, mapping, or receipt is invalid."""


Record = dict[str, Any]
PLAN_ABI = 0x474D545000000001
IMPLEMENTATION_ABI = 0x474D545800000001
PLAN_MAGIC = b"GMTRFM1\x00"
PLAN_BYTES = 512
PLAN_BODY_BYTES = 480
PLAN_DOMAIN = b"glacier-media-transform-plan-v1\x00"
IMPLEMENTATION_DOMAIN = b"glacier-media-transform-implementation-v1\x00"
MAPPING_DOMAIN = b"glacier-media-transform-mapping-v1\x00"
MAPPING_CHAIN_DOMAIN = b"glacier-media-transform-mapping-chain-v1\x00"
RECEIPT_DOMAIN = b"glacier-media-transform-receipt-v1\x00"
PARAMETER_COUNT = 8
MAXIMUM_VIDEO_SELECTIONS = PARAMETER_COUNT - 1
ALLOWED_FLAGS = 0
ALLOWED_CAPABILITIES = 0
U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)

IMAGE_CROP_NEAREST_TILE = 1
AUDIO_MIX_DECIMATE = 2
VIDEO_KEYFRAME_SELECT = 3


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaTransformError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or value == ZERO_DIGEST
    ):
        raise MediaTransformError("invalid digest")
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
        raise MediaTransformError("u64 addition overflow")
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    if result > U64_MAX:
        raise MediaTransformError("u64 multiplication overflow")
    return result


def _time_base(value: Any, *, static: bool = False) -> tuple[int, int]:
    if (
        not isinstance(value, tuple)
        or len(value) != 2
        or not all(isinstance(part, int) for part in value)
    ):
        raise MediaTransformError("invalid time base")
    numerator, denominator = value
    _u64(numerator)
    _u64(denominator)
    if static and value == (0, 1):
        return value
    if (
        numerator == 0
        or denominator == 0
        or math.gcd(numerator, denominator) != 1
    ):
        raise MediaTransformError("non-canonical time base")
    return value


def implementation_sha256() -> bytes:
    return _hash(
        IMPLEMENTATION_DOMAIN,
        _u64(IMPLEMENTATION_ABI),
        _u64(PARAMETER_COUNT),
        _u64(MAXIMUM_VIDEO_SELECTIONS),
    )


def plan_root(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) != PLAN_BODY_BYTES:
        raise MediaTransformError("invalid plan body")
    return _hash(PLAN_DOMAIN, body)


def _plan(value: Record) -> Record:
    try:
        plan = {
            "operation": value["operation"],
            "kind": value["kind"],
            "input_representation_id": value[
                "input_representation_id"
            ],
            "output_representation_id": value[
                "output_representation_id"
            ],
            "source_bytes": value["source_bytes"],
            "output_bytes": value["output_bytes"],
            "scratch_bytes": value["scratch_bytes"],
            "logical_units": value["logical_units"],
            "source_axes": tuple(value["source_axes"]),
            "target_axes": tuple(value["target_axes"]),
            "source_time_base": tuple(value["source_time_base"]),
            "target_time_base": tuple(value["target_time_base"]),
            "parameters": tuple(value["parameters"]),
            "media_object_sha256": _digest(
                value["media_object_sha256"]
            ),
            "decode_plan_sha256": _digest(
                value["decode_plan_sha256"]
            ),
            "decode_receipt_sha256": _digest(
                value["decode_receipt_sha256"]
            ),
            "source_output_sha256": _digest(
                value["source_output_sha256"]
            ),
            "transform_implementation_sha256": _digest(
                value["transform_implementation_sha256"]
            ),
            "resource_policy_sha256": _digest(
                value["resource_policy_sha256"]
            ),
            "challenge_sha256": _digest(value["challenge_sha256"]),
            "required_capabilities": value["required_capabilities"],
        }
    except (KeyError, TypeError):
        raise MediaTransformError("invalid transform plan") from None
    integers = (
        "operation",
        "kind",
        "input_representation_id",
        "output_representation_id",
        "source_bytes",
        "output_bytes",
        "scratch_bytes",
        "logical_units",
        "required_capabilities",
    )
    for name in integers:
        _u64(plan[name])
    if (
        plan["operation"]
        not in (
            IMAGE_CROP_NEAREST_TILE,
            AUDIO_MIX_DECIMATE,
            VIDEO_KEYFRAME_SELECT,
        )
        or plan["input_representation_id"] == 0
        or plan["output_representation_id"] == 0
        or plan["source_bytes"] == 0
        or plan["output_bytes"] == 0
        or plan["logical_units"] == 0
        or plan["required_capabilities"] != ALLOWED_CAPABILITIES
        or len(plan["source_axes"]) != 3
        or len(plan["target_axes"]) != 3
        or len(plan["parameters"]) != PARAMETER_COUNT
    ):
        raise MediaTransformError("invalid transform plan")
    for value in (
        *plan["source_axes"],
        *plan["target_axes"],
        *plan["parameters"],
    ):
        _u64(value)
    if 0 in plan["source_axes"] or 0 in plan["target_axes"]:
        raise MediaTransformError("invalid transform axes")
    if plan["operation"] == IMAGE_CROP_NEAREST_TILE:
        _validate_image(plan)
    elif plan["operation"] == AUDIO_MIX_DECIMATE:
        _validate_audio(plan)
    else:
        _validate_video(plan)
    return plan


def _validate_image(plan: Record) -> None:
    (
        crop_x,
        crop_y,
        crop_width,
        crop_height,
        target_width,
        target_height,
        tile_width,
        tile_height,
    ) = plan["parameters"]
    channels = plan["source_axes"][2]
    valid = (
        plan["kind"] == media.IMAGE
        and plan["input_representation_id"]
        == plan["output_representation_id"]
        and plan["input_representation_id"]
        in (fixture_api.IMAGE_RGB8, fixture_api.IMAGE_GRAY8)
        and plan["source_time_base"] == (0, 1)
        and plan["target_time_base"] == (0, 1)
        and plan["scratch_bytes"] == 0
        and channels == plan["target_axes"][2]
        and crop_width > 0
        and crop_height > 0
        and target_width > 0
        and target_height > 0
        and tile_width > 0
        and tile_height > 0
        and target_width == plan["target_axes"][0]
        and target_height == plan["target_axes"][1]
        and target_width % tile_width == 0
        and target_height % tile_height == 0
    )
    if not valid:
        raise MediaTransformError("invalid image transform")
    if (
        _checked_add(crop_x, crop_width) > plan["source_axes"][0]
        or _checked_add(crop_y, crop_height)
        > plan["source_axes"][1]
    ):
        raise MediaTransformError("image crop out of bounds")
    source_pixels = _checked_mul(
        plan["source_axes"][0], plan["source_axes"][1]
    )
    target_pixels = _checked_mul(target_width, target_height)
    if (
        plan["source_bytes"] != _checked_mul(source_pixels, channels)
        or plan["output_bytes"]
        != _checked_mul(target_pixels, plan["target_axes"][2])
        or plan["logical_units"] != target_pixels
    ):
        raise MediaTransformError("contradictory image transform")


def _validate_audio(plan: Record) -> None:
    start, source_count, left, right, denominator, factor, p6, p7 = (
        plan["parameters"]
    )
    _time_base(plan["source_time_base"])
    _time_base(plan["target_time_base"])
    valid = (
        plan["kind"] == media.AUDIO
        and plan["input_representation_id"]
        == fixture_api.AUDIO_PCM_S16LE
        and plan["output_representation_id"]
        == fixture_api.AUDIO_PCM_S16LE
        and plan["source_axes"][1] == 2
        and plan["target_axes"][1] == 1
        and plan["source_axes"][2]
        == plan["source_time_base"][1]
        and plan["source_time_base"][0] == 1
        and plan["target_axes"][2]
        == plan["target_time_base"][1]
        and plan["target_time_base"][0] == 1
        and plan["scratch_bytes"] == 0
        and p6 == 0
        and p7 == 0
        and source_count > 0
        and denominator > 0
        and factor > 0
        and left <= 65_535
        and right <= 65_535
        and _checked_add(left, right) == denominator
        and _checked_mul(denominator, factor)
        <= ((1 << 63) - 1) // 32_768
        and plan["source_axes"][2] % plan["target_axes"][2] == 0
        and plan["source_axes"][2] // plan["target_axes"][2]
        == factor
        and source_count % factor == 0
    )
    if not valid:
        raise MediaTransformError("invalid audio transform")
    if _checked_add(start, source_count) > plan["source_axes"][0]:
        raise MediaTransformError("audio range out of bounds")
    target_frames = source_count // factor
    if (
        plan["target_axes"][0] != target_frames
        or plan["source_bytes"]
        != _checked_mul(_checked_mul(plan["source_axes"][0], 2), 2)
        or plan["output_bytes"] != _checked_mul(target_frames, 2)
        or plan["logical_units"] != target_frames
    ):
        raise MediaTransformError("contradictory audio transform")


def _validate_video(plan: Record) -> None:
    _time_base(plan["source_time_base"])
    count = plan["parameters"][0]
    selected = plan["parameters"][1 : count + 1]
    valid = (
        plan["kind"] == media.VIDEO
        and plan["input_representation_id"]
        == fixture_api.VIDEO_GRAY8_INTRA
        and plan["output_representation_id"]
        == fixture_api.VIDEO_GRAY8_INTRA
        and plan["source_axes"][:2] == plan["target_axes"][:2]
        and plan["source_time_base"] == plan["target_time_base"]
        and plan["scratch_bytes"] == 0
        and 0 < count <= MAXIMUM_VIDEO_SELECTIONS
        and count == plan["target_axes"][2]
        and count == plan["logical_units"]
        and all(
            frame < plan["source_axes"][2] for frame in selected
        )
        and len(set(selected)) == len(selected)
        and all(value == 0 for value in plan["parameters"][count + 1 :])
    )
    if not valid:
        raise MediaTransformError("invalid video transform")
    frame_bytes = _checked_mul(
        plan["source_axes"][0], plan["source_axes"][1]
    )
    if (
        plan["source_bytes"]
        != _checked_mul(frame_bytes, plan["source_axes"][2])
        or plan["output_bytes"] != _checked_mul(frame_bytes, count)
    ):
        raise MediaTransformError("contradictory video transform")


def encode_plan(value: Record) -> bytes:
    plan = _plan(value)
    output = bytearray(PLAN_BYTES)
    output[:240] = b"".join(
        (
            PLAN_MAGIC,
            _u64(PLAN_ABI),
            _u64(PLAN_BYTES),
            _u64(ALLOWED_FLAGS),
            _u64(plan["operation"]),
            _u64(plan["kind"]),
            _u64(plan["input_representation_id"]),
            _u64(plan["output_representation_id"]),
            _u64(plan["source_bytes"]),
            _u64(plan["output_bytes"]),
            _u64(plan["scratch_bytes"]),
            _u64(plan["logical_units"]),
            *(_u64(axis) for axis in plan["source_axes"]),
            *(_u64(axis) for axis in plan["target_axes"]),
            *(_u64(part) for part in plan["source_time_base"]),
            *(_u64(part) for part in plan["target_time_base"]),
            *(_u64(parameter) for parameter in plan["parameters"]),
        )
    )
    output[240:464] = b"".join(
        (
            plan["media_object_sha256"],
            plan["decode_plan_sha256"],
            plan["decode_receipt_sha256"],
            plan["source_output_sha256"],
            plan["transform_implementation_sha256"],
            plan["resource_policy_sha256"],
            plan["challenge_sha256"],
        )
    )
    output[464:472] = _u64(plan["required_capabilities"])
    output[480:] = plan_root(bytes(output[:480]))
    return bytes(output)


def decode_plan(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PLAN_BYTES
        or encoded[:8] != PLAN_MAGIC
        or _read(encoded, 8) != PLAN_ABI
        or _read(encoded, 16) != PLAN_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or _read(encoded, 472) != 0
        or encoded[480:] != plan_root(encoded[:480])
    ):
        raise MediaTransformError("invalid transform plan wire")
    return _plan(
        {
            "operation": _read(encoded, 32),
            "kind": _read(encoded, 40),
            "input_representation_id": _read(encoded, 48),
            "output_representation_id": _read(encoded, 56),
            "source_bytes": _read(encoded, 64),
            "output_bytes": _read(encoded, 72),
            "scratch_bytes": _read(encoded, 80),
            "logical_units": _read(encoded, 88),
            "source_axes": tuple(
                _read(encoded, offset) for offset in (96, 104, 112)
            ),
            "target_axes": tuple(
                _read(encoded, offset) for offset in (120, 128, 136)
            ),
            "source_time_base": (
                _read(encoded, 144),
                _read(encoded, 152),
            ),
            "target_time_base": (
                _read(encoded, 160),
                _read(encoded, 168),
            ),
            "parameters": tuple(
                _read(encoded, 176 + index * 8)
                for index in range(PARAMETER_COUNT)
            ),
            "media_object_sha256": encoded[240:272],
            "decode_plan_sha256": encoded[272:304],
            "decode_receipt_sha256": encoded[304:336],
            "source_output_sha256": encoded[336:368],
            "transform_implementation_sha256": encoded[368:400],
            "resource_policy_sha256": encoded[400:432],
            "challenge_sha256": encoded[432:464],
            "required_capabilities": _read(encoded, 464),
        }
    )


def plan_sha256(encoded: bytes) -> bytes:
    decode_plan(encoded)
    return encoded[480:]


def _base_plan(
    parsed_fixture: Record,
    decode_receipt: Record,
    operation: int,
    output_representation: int,
    output_bytes: int,
    logical_units: int,
    target_axes: tuple[int, int, int],
    target_time_base: tuple[int, int],
    parameters: tuple[int, ...],
    resource_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    return _plan(
        {
            "operation": operation,
            "kind": parsed_fixture["kind"],
            "input_representation_id": parsed_fixture[
                "representation"
            ],
            "output_representation_id": output_representation,
            "source_bytes": decode_receipt["output_bytes"],
            "output_bytes": output_bytes,
            "scratch_bytes": 0,
            "logical_units": logical_units,
            "source_axes": parsed_fixture["target_axes"],
            "target_axes": target_axes,
            "source_time_base": parsed_fixture["time_base"],
            "target_time_base": target_time_base,
            "parameters": parameters,
            "media_object_sha256": parsed_fixture[
                "media_object_sha256"
            ],
            "decode_plan_sha256": decode_receipt[
                "decode_plan_sha256"
            ],
            "decode_receipt_sha256": decode_receipt[
                "receipt_sha256"
            ],
            "source_output_sha256": decode_receipt["output_sha256"],
            "transform_implementation_sha256": implementation_sha256(),
            "resource_policy_sha256": resource_policy_sha256,
            "challenge_sha256": challenge_sha256,
            "required_capabilities": 0,
        }
    )


def make_image_plan(
    parsed_fixture: Record,
    decode_receipt: Record,
    crop_x: int,
    crop_y: int,
    crop_width: int,
    crop_height: int,
    target_width: int,
    target_height: int,
    tile_width: int,
    tile_height: int,
    resource_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    channels = parsed_fixture["target_axes"][2]
    pixels = _checked_mul(target_width, target_height)
    return _base_plan(
        parsed_fixture,
        decode_receipt,
        IMAGE_CROP_NEAREST_TILE,
        parsed_fixture["representation"],
        _checked_mul(pixels, channels),
        pixels,
        (target_width, target_height, channels),
        parsed_fixture["time_base"],
        (
            crop_x,
            crop_y,
            crop_width,
            crop_height,
            target_width,
            target_height,
            tile_width,
            tile_height,
        ),
        resource_policy_sha256,
        challenge_sha256,
    )


def make_audio_plan(
    parsed_fixture: Record,
    decode_receipt: Record,
    source_start_frame: int,
    source_frame_count: int,
    target_sample_rate: int,
    left_weight: int,
    right_weight: int,
    mix_denominator: int,
    resource_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    source_rate = parsed_fixture["target_axes"][2]
    if (
        target_sample_rate == 0
        or source_rate % target_sample_rate != 0
    ):
        raise MediaTransformError("inexact sample-rate ratio")
    factor = source_rate // target_sample_rate
    if factor == 0 or source_frame_count % factor != 0:
        raise MediaTransformError("inexact frame range")
    frames = source_frame_count // factor
    return _base_plan(
        parsed_fixture,
        decode_receipt,
        AUDIO_MIX_DECIMATE,
        fixture_api.AUDIO_PCM_S16LE,
        _checked_mul(frames, 2),
        frames,
        (frames, 1, target_sample_rate),
        (1, target_sample_rate),
        (
            source_start_frame,
            source_frame_count,
            left_weight,
            right_weight,
            mix_denominator,
            factor,
            0,
            0,
        ),
        resource_policy_sha256,
        challenge_sha256,
    )


def make_video_plan(
    parsed_fixture: Record,
    decode_receipt: Record,
    selected_frames: tuple[int, ...],
    resource_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    if not 0 < len(selected_frames) <= MAXIMUM_VIDEO_SELECTIONS:
        raise MediaTransformError("invalid frame selection count")
    parameters = (
        len(selected_frames),
        *selected_frames,
        *(0 for _ in range(MAXIMUM_VIDEO_SELECTIONS - len(selected_frames))),
    )
    frame_bytes = _checked_mul(
        parsed_fixture["target_axes"][0],
        parsed_fixture["target_axes"][1],
    )
    return _base_plan(
        parsed_fixture,
        decode_receipt,
        VIDEO_KEYFRAME_SELECT,
        parsed_fixture["representation"],
        _checked_mul(frame_bytes, len(selected_frames)),
        len(selected_frames),
        (
            parsed_fixture["target_axes"][0],
            parsed_fixture["target_axes"][1],
            len(selected_frames),
        ),
        parsed_fixture["time_base"],
        parameters,
        resource_policy_sha256,
        challenge_sha256,
    )


def _mapping_root(mapping: Record, decode_receipt_sha256: bytes) -> bytes:
    return _hash(
        MAPPING_DOMAIN,
        decode_receipt_sha256,
        *(
            _u64(mapping[name])
            for name in (
                "operation",
                "output_unit",
                "source_first_unit",
                "source_unit_count",
                "source_byte_offset",
                "source_bytes",
                "output_byte_offset",
                "output_bytes",
                "source_start_tick",
                "source_end_tick",
                "target_start_tick",
                "target_end_tick",
            )
        ),
    )


def _mapping(
    plan: Record,
    output_unit: int,
    source_first_unit: int,
    source_unit_count: int,
    source_byte_offset: int,
    source_bytes: int,
    output_byte_offset: int,
    output_bytes: int,
    source_start_tick: int,
    source_end_tick: int,
    target_start_tick: int,
    target_end_tick: int,
) -> Record:
    mapping = {
        "operation": plan["operation"],
        "output_unit": output_unit,
        "source_first_unit": source_first_unit,
        "source_unit_count": source_unit_count,
        "source_byte_offset": source_byte_offset,
        "source_bytes": source_bytes,
        "output_byte_offset": output_byte_offset,
        "output_bytes": output_bytes,
        "source_start_tick": source_start_tick,
        "source_end_tick": source_end_tick,
        "target_start_tick": target_start_tick,
        "target_end_tick": target_end_tick,
    }
    mapping["mapping_sha256"] = _mapping_root(
        mapping, plan["decode_receipt_sha256"]
    )
    return mapping


def _trunc_div(numerator: int, denominator: int) -> int:
    magnitude = abs(numerator) // abs(denominator)
    return -magnitude if (numerator < 0) != (denominator < 0) else magnitude


def _execute_image(
    plan: Record, source: bytes
) -> tuple[bytes, list[Record]]:
    crop_x, crop_y, crop_width, crop_height = plan["parameters"][:4]
    target_width, target_height, channels = plan["target_axes"]
    output = bytearray(plan["output_bytes"])
    mappings = []
    for output_unit in range(plan["logical_units"]):
        output_y, output_x = divmod(output_unit, target_width)
        source_x = crop_x + output_x * crop_width // target_width
        source_y = crop_y + output_y * crop_height // target_height
        source_unit = source_y * plan["source_axes"][0] + source_x
        source_offset = source_unit * channels
        output_offset = output_unit * channels
        output[output_offset : output_offset + channels] = source[
            source_offset : source_offset + channels
        ]
        mappings.append(
            _mapping(
                plan,
                output_unit,
                source_unit,
                1,
                source_offset,
                channels,
                output_offset,
                channels,
                0,
                0,
                0,
                0,
            )
        )
    return bytes(output), mappings


def _execute_audio(
    plan: Record, parsed_fixture: Record, source: bytes
) -> tuple[bytes, list[Record]]:
    start, _, left_weight, right_weight, denominator, factor, _, _ = (
        plan["parameters"]
    )
    divisor = denominator * factor
    output = bytearray(plan["output_bytes"])
    mappings = []
    for output_unit in range(plan["logical_units"]):
        source_first = start + output_unit * factor
        total = 0
        for frame in range(source_first, source_first + factor):
            left, right = struct.unpack_from("<hh", source, frame * 4)
            total += left * left_weight + right * right_weight
        sample = _trunc_div(total, divisor)
        struct.pack_into("<h", output, output_unit * 2, sample)
        mappings.append(
            _mapping(
                plan,
                output_unit,
                source_first,
                factor,
                source_first * 4,
                factor * 4,
                output_unit * 2,
                2,
                parsed_fixture["start_ticks"] + source_first,
                parsed_fixture["start_ticks"] + source_first + factor,
                output_unit,
                output_unit + 1,
            )
        )
    return bytes(output), mappings


def _execute_video(
    plan: Record, parsed_fixture: Record, source: bytes
) -> tuple[bytes, list[Record]]:
    frame_bytes = plan["source_axes"][0] * plan["source_axes"][1]
    output = bytearray(plan["output_bytes"])
    mappings = []
    for output_unit, source_frame in enumerate(
        plan["parameters"][1 : plan["logical_units"] + 1]
    ):
        source_offset = source_frame * frame_bytes
        output_offset = output_unit * frame_bytes
        output[output_offset : output_offset + frame_bytes] = source[
            source_offset : source_offset + frame_bytes
        ]
        mappings.append(
            _mapping(
                plan,
                output_unit,
                source_frame,
                1,
                source_offset,
                frame_bytes,
                output_offset,
                frame_bytes,
                parsed_fixture["start_ticks"] + source_frame,
                parsed_fixture["start_ticks"] + source_frame + 1,
                output_unit,
                output_unit + 1,
            )
        )
    return bytes(output), mappings


def _mapping_chain_root(
    transform_plan_sha256: bytes, mappings: list[Record]
) -> bytes:
    return _hash(
        MAPPING_CHAIN_DOMAIN,
        transform_plan_sha256,
        _u64(len(mappings)),
        *(mapping["mapping_sha256"] for mapping in mappings),
    )


def receipt_root(receipt: Record) -> bytes:
    return _hash(
        RECEIPT_DOMAIN,
        *(
            _u64(receipt[name])
            for name in (
                "operation",
                "kind",
                "logical_units",
                "output_bytes",
                "mapping_count",
            )
        ),
        *(
            _digest(receipt[name])
            for name in (
                "transform_plan_sha256",
                "decode_receipt_sha256",
                "source_output_sha256",
                "output_sha256",
                "mapping_chain_sha256",
            )
        ),
    )


def verify_receipt(
    encoded_fixture: bytes,
    encoded_transform_plan: bytes,
    receipt: Record,
    output: bytes,
    mappings: list[Record],
) -> None:
    parsed_fixture = fixture_api.parse_fixture(encoded_fixture)
    plan = decode_plan(encoded_transform_plan)
    if not isinstance(output, bytes) or not isinstance(mappings, list):
        raise MediaTransformError("invalid receipt evidence")
    source = parsed_fixture["payload"]
    if plan["operation"] == VIDEO_KEYFRAME_SELECT:
        selected = plan["parameters"][1 : plan["logical_units"] + 1]
        if any(
            not parsed_fixture["keyframe_bits"] & (1 << frame) for frame in selected
        ):
            raise MediaTransformError("selected frame is not a keyframe")
        expected_output, expected_mappings = _execute_video(
            plan, parsed_fixture, source
        )
    elif plan["operation"] == IMAGE_CROP_NEAREST_TILE:
        expected_output, expected_mappings = _execute_image(plan, source)
    else:
        expected_output, expected_mappings = _execute_audio(
            plan, parsed_fixture, source
        )
    expected_plan_root = plan_sha256(encoded_transform_plan)
    expected_chain = _mapping_chain_root(expected_plan_root, expected_mappings)
    try:
        valid = (
            plan["kind"] == parsed_fixture["kind"]
            and plan["input_representation_id"] == parsed_fixture["representation"]
            and plan["source_bytes"] == len(source)
            and plan["source_axes"] == parsed_fixture["target_axes"]
            and plan["source_time_base"] == parsed_fixture["time_base"]
            and plan["media_object_sha256"] == parsed_fixture["media_object_sha256"]
            and plan["transform_implementation_sha256"] == implementation_sha256()
            and output == expected_output
            and mappings == expected_mappings
            and receipt["operation"] == plan["operation"]
            and receipt["kind"] == plan["kind"]
            and receipt["logical_units"] == plan["logical_units"]
            and receipt["output_bytes"] == plan["output_bytes"]
            and receipt["mapping_count"] == plan["logical_units"]
            and receipt["transform_plan_sha256"] == expected_plan_root
            and receipt["decode_receipt_sha256"] == plan["decode_receipt_sha256"]
            and receipt["source_output_sha256"] == plan["source_output_sha256"]
            and receipt["output_sha256"] == hashlib.sha256(output).digest()
            and receipt["mapping_chain_sha256"] == expected_chain
            and receipt["receipt_sha256"] == receipt_root(receipt)
        )
    except (KeyError, TypeError, MediaTransformError):
        valid = False
    if not valid:
        raise MediaTransformError("invalid transform receipt")


def execute(
    encoded_fixture: bytes,
    encoded_decode_plan: bytes,
    encoded_transform_plan: bytes,
    destination: bytearray,
) -> tuple[Record, list[Record]]:
    parsed_fixture = fixture_api.parse_fixture(encoded_fixture)
    plan = decode_plan(encoded_transform_plan)
    if (
        plan["decode_plan_sha256"]
        != fixture_api.plan_sha256(encoded_decode_plan)
        or not isinstance(destination, bytearray)
        or len(destination) < plan["output_bytes"]
    ):
        raise MediaTransformError("invalid input binding or capacity")
    decoded = bytearray(plan["source_bytes"])
    try:
        decode_receipt = fixture_api.decode_fixture(
            encoded_fixture, encoded_decode_plan, decoded
        )
    except fixture_api.MediaDecodeFixtureError as error:
        raise MediaTransformError("invalid fixture decode") from error
    source = bytes(decoded)
    if (
        plan["kind"] != parsed_fixture["kind"]
        or plan["input_representation_id"]
        != parsed_fixture["representation"]
        or plan["source_bytes"] != len(source)
        or plan["source_axes"] != parsed_fixture["target_axes"]
        or plan["source_time_base"] != parsed_fixture["time_base"]
        or plan["media_object_sha256"]
        != parsed_fixture["media_object_sha256"]
        or plan["decode_plan_sha256"]
        != decode_receipt["decode_plan_sha256"]
        or plan["decode_receipt_sha256"]
        != decode_receipt["receipt_sha256"]
        or plan["source_output_sha256"] != hashlib.sha256(source).digest()
        or plan["transform_implementation_sha256"]
        != implementation_sha256()
    ):
        raise MediaTransformError("stale transform binding")
    if plan["operation"] == VIDEO_KEYFRAME_SELECT:
        selected = plan["parameters"][1 : plan["logical_units"] + 1]
        if any(
            not parsed_fixture["keyframe_bits"] & (1 << frame)
            for frame in selected
        ):
            raise MediaTransformError("selected frame is not a keyframe")
        output, mappings = _execute_video(
            plan, parsed_fixture, source
        )
    elif plan["operation"] == IMAGE_CROP_NEAREST_TILE:
        output, mappings = _execute_image(plan, source)
    else:
        output, mappings = _execute_audio(
            plan, parsed_fixture, source
        )
    destination[: len(output)] = output
    receipt = {
        "operation": plan["operation"],
        "kind": plan["kind"],
        "logical_units": plan["logical_units"],
        "output_bytes": plan["output_bytes"],
        "mapping_count": plan["logical_units"],
        "transform_plan_sha256": plan_sha256(
            encoded_transform_plan
        ),
        "decode_receipt_sha256": decode_receipt["receipt_sha256"],
        "source_output_sha256": decode_receipt["output_sha256"],
        "output_sha256": hashlib.sha256(output).digest(),
        "mapping_chain_sha256": _mapping_chain_root(
            plan_sha256(encoded_transform_plan), mappings
        ),
    }
    receipt["receipt_sha256"] = receipt_root(receipt)
    return receipt, mappings
