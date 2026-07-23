"""Independent sealed-plan and tiny image/audio/video fixture model."""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Any

from bench import media_contract as media


class MediaDecodeFixtureError(ValueError):
    """A decode plan, fixture, mapping, or receipt is invalid."""


Record = dict[str, Any]
PLAN_ABI = 0x474D445000000001
PLAN_MAGIC = b"GMDPLN1\x00"
PLAN_BYTES = 416
PLAN_BODY_BYTES = 384
PLAN_DOMAIN = b"glacier-media-decode-plan-v1\x00"
ALLOWED_CAPABILITIES = 0x7

FIXTURE_ABI = 0x474D544600000001
DECODER_ABI = 0x474D544400000001
FIXTURE_MAGIC = b"GMTINY1\x00"
FIXTURE_HEADER_BYTES = 320
FIXTURE_FOOTER_BYTES = 32
MAXIMUM_PAYLOAD_BYTES = 4096
MAXIMUM_FIXTURE_BYTES = (
    FIXTURE_HEADER_BYTES
    + MAXIMUM_PAYLOAD_BYTES
    + FIXTURE_FOOTER_BYTES
)
CONTAINER_ID = FIXTURE_ABI
ALLOWED_FLAGS = 0
FIXTURE_DOMAIN = b"glacier-tiny-media-fixture-v1\x00"
DECODER_DOMAIN = b"glacier-tiny-media-decoder-v1\x00"
TRANSFORM_DOMAIN = b"glacier-tiny-media-identity-transform-v1\x00"
RECEIPT_DOMAIN = b"glacier-tiny-media-decode-receipt-v1\x00"
MAPPING_DOMAIN = b"glacier-tiny-media-unit-mapping-v1\x00"
U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)

DETERMINISTIC = 1
QUALITY = 2
EXACT_INTEGER = 1
STRICT_FLOAT = 2
FAIL_CLOSED = 1

IMAGE_RGB8 = 1
IMAGE_GRAY8 = 2
AUDIO_PCM_S16LE = 3
VIDEO_GRAY8_INTRA = 4
IMAGE_RGB = 1
IMAGE_GRAY = 2
AUDIO_INTERLEAVED = 3
VIDEO_GRAY = 4
NOT_APPLICABLE = 0
TOP_LEFT = 1
SRGB = 1
LINEAR = 2
ALPHA_NOT_PRESENT = 1

IMAGE_PAYLOAD = bytes(
    (255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255)
)
AUDIO_PAYLOAD = bytes(
    (
        0x00,
        0x80,
        0xFF,
        0x7F,
        0x00,
        0xC0,
        0x00,
        0x40,
        0xFF,
        0xFF,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0xFF,
        0xFF,
        0x00,
        0x40,
        0x00,
        0xC0,
        0xFF,
        0x7F,
        0x00,
        0x80,
        0xD2,
        0x04,
        0x2E,
        0xFB,
    )
)
VIDEO_PAYLOAD = bytes((0, 64, 128, 255, 255, 128, 64, 0))


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaDecodeFixtureError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or value == ZERO_DIGEST
    ):
        raise MediaDecodeFixtureError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _time_base(
    value: Any, *, static: bool = False
) -> tuple[int, int]:
    if (
        not isinstance(value, tuple)
        or len(value) != 2
        or not all(isinstance(part, int) for part in value)
    ):
        raise MediaDecodeFixtureError("invalid time base")
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
        raise MediaDecodeFixtureError("non-canonical time base")
    return value


def plan_root(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) != PLAN_BODY_BYTES:
        raise MediaDecodeFixtureError("invalid plan body")
    return _hash(PLAN_DOMAIN, body)


def _plan(value: Record) -> Record:
    try:
        plan = {
            "kind": value["kind"],
            "decoder_abi": value["decoder_abi"],
            "source_container_id": value["source_container_id"],
            "source_codec_id": value["source_codec_id"],
            "destination_representation_id": value[
                "destination_representation_id"
            ],
            "execution_mode": value["execution_mode"],
            "numerical_policy": value["numerical_policy"],
            "rejection_policy": value["rejection_policy"],
            "required_capabilities": value["required_capabilities"],
            "source_bytes": value["source_bytes"],
            "output_bytes": value["output_bytes"],
            "scratch_bytes": value["scratch_bytes"],
            "logical_units": value["logical_units"],
            "source_axes": tuple(value["source_axes"]),
            "target_axes": tuple(value["target_axes"]),
            "source_time_base": tuple(value["source_time_base"]),
            "target_time_base": tuple(value["target_time_base"]),
            "media_object_sha256": _digest(
                value["media_object_sha256"]
            ),
            "decoder_implementation_sha256": _digest(
                value["decoder_implementation_sha256"]
            ),
            "transform_policy_sha256": _digest(
                value["transform_policy_sha256"]
            ),
            "resource_policy_sha256": _digest(
                value["resource_policy_sha256"]
            ),
            "challenge_sha256": _digest(value["challenge_sha256"]),
        }
    except (KeyError, TypeError):
        raise MediaDecodeFixtureError("invalid plan") from None
    integer_fields = (
        "kind",
        "decoder_abi",
        "source_container_id",
        "source_codec_id",
        "destination_representation_id",
        "execution_mode",
        "numerical_policy",
        "rejection_policy",
        "required_capabilities",
        "source_bytes",
        "output_bytes",
        "scratch_bytes",
        "logical_units",
    )
    for name in integer_fields:
        _u64(plan[name])
    if (
        plan["kind"] not in (media.IMAGE, media.AUDIO, media.VIDEO)
        or plan["decoder_abi"] == 0
        or plan["source_container_id"] == 0
        or plan["source_codec_id"] == 0
        or plan["destination_representation_id"] == 0
        or plan["execution_mode"] not in (DETERMINISTIC, QUALITY)
        or plan["numerical_policy"] not in (
            EXACT_INTEGER,
            STRICT_FLOAT,
        )
        or plan["rejection_policy"] != FAIL_CLOSED
        or plan["required_capabilities"] & ~ALLOWED_CAPABILITIES
        or plan["source_bytes"] == 0
        or plan["output_bytes"] == 0
        or plan["logical_units"] == 0
        or len(plan["source_axes"]) != 3
        or len(plan["target_axes"]) != 3
    ):
        raise MediaDecodeFixtureError("invalid plan")
    for axis in (*plan["source_axes"], *plan["target_axes"]):
        _u64(axis)
        if axis == 0:
            raise MediaDecodeFixtureError("invalid plan axes")
    if plan["kind"] == media.IMAGE:
        if (
            plan["source_time_base"] != (0, 1)
            or plan["target_time_base"] != (0, 1)
        ):
            raise MediaDecodeFixtureError("invalid image plan time")
    else:
        _time_base(plan["source_time_base"])
        _time_base(plan["target_time_base"])
    return plan


def encode_plan(value: Record) -> bytes:
    plan = _plan(value)
    output = bytearray(PLAN_BYTES)
    output[:136] = b"".join(
        (
            PLAN_MAGIC,
            _u64(PLAN_ABI),
            _u64(PLAN_BYTES),
            _u64(ALLOWED_FLAGS),
            _u64(plan["kind"]),
            _u64(plan["decoder_abi"]),
            _u64(plan["source_container_id"]),
            _u64(plan["source_codec_id"]),
            _u64(plan["destination_representation_id"]),
            _u64(plan["execution_mode"]),
            _u64(plan["numerical_policy"]),
            _u64(plan["rejection_policy"]),
            _u64(plan["required_capabilities"]),
            _u64(plan["source_bytes"]),
            _u64(plan["output_bytes"]),
            _u64(plan["scratch_bytes"]),
            _u64(plan["logical_units"]),
        )
    )
    output[136:216] = b"".join(
        _u64(part)
        for part in (
            *plan["source_axes"],
            *plan["target_axes"],
            *plan["source_time_base"],
            *plan["target_time_base"],
        )
    )
    output[216:376] = b"".join(
        (
            plan["media_object_sha256"],
            plan["decoder_implementation_sha256"],
            plan["transform_policy_sha256"],
            plan["resource_policy_sha256"],
            plan["challenge_sha256"],
        )
    )
    output[384:] = plan_root(bytes(output[:384]))
    return bytes(output)


def decode_plan(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PLAN_BYTES
        or encoded[:8] != PLAN_MAGIC
        or _read(encoded, 8) != PLAN_ABI
        or _read(encoded, 16) != PLAN_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or _read(encoded, 376) != 0
        or encoded[384:] != plan_root(encoded[:384])
    ):
        raise MediaDecodeFixtureError("invalid plan wire")
    return _plan(
        {
            "kind": _read(encoded, 32),
            "decoder_abi": _read(encoded, 40),
            "source_container_id": _read(encoded, 48),
            "source_codec_id": _read(encoded, 56),
            "destination_representation_id": _read(encoded, 64),
            "execution_mode": _read(encoded, 72),
            "numerical_policy": _read(encoded, 80),
            "rejection_policy": _read(encoded, 88),
            "required_capabilities": _read(encoded, 96),
            "source_bytes": _read(encoded, 104),
            "output_bytes": _read(encoded, 112),
            "scratch_bytes": _read(encoded, 120),
            "logical_units": _read(encoded, 128),
            "source_axes": tuple(
                _read(encoded, offset)
                for offset in (136, 144, 152)
            ),
            "target_axes": tuple(
                _read(encoded, offset)
                for offset in (160, 168, 176)
            ),
            "source_time_base": (
                _read(encoded, 184),
                _read(encoded, 192),
            ),
            "target_time_base": (
                _read(encoded, 200),
                _read(encoded, 208),
            ),
            "media_object_sha256": encoded[216:248],
            "decoder_implementation_sha256": encoded[248:280],
            "transform_policy_sha256": encoded[280:312],
            "resource_policy_sha256": encoded[312:344],
            "challenge_sha256": encoded[344:376],
        }
    )


def plan_sha256(encoded: bytes) -> bytes:
    decode_plan(encoded)
    return encoded[384:]


def validate_for_media_object(
    plan_value: Record,
    media_object: Record,
    object_sha256: bytes,
) -> None:
    plan = _plan(plan_value)
    encoded_object = media.encode_media_object(media_object)
    computed = media.media_object_sha256(encoded_object)
    if (
        computed != object_sha256
        or plan["media_object_sha256"] != object_sha256
        or plan["kind"] != media_object["kind"]
        or plan["source_bytes"] != media_object["byte_length"]
        or plan["source_container_id"] != media_object["container_id"]
        or plan["source_codec_id"] != media_object["codec_id"]
        or plan["source_axes"] != media_object["axes"]
        or plan["source_time_base"] != media_object["time_base"]
    ):
        raise MediaDecodeFixtureError("plan does not bind object")


def image_spec() -> Record:
    return {
        "kind": media.IMAGE,
        "semantic_abi": 1,
        "codec_id": 1,
        "axes": (2, 2, 3),
        "target_axes": (2, 2, 3),
        "time_base": (0, 1),
        "storage_stride": 6,
        "representation": IMAGE_RGB8,
        "layout": IMAGE_RGB,
        "orientation": TOP_LEFT,
        "transfer": SRGB,
        "alpha": ALPHA_NOT_PRESENT,
        "start_ticks": 0,
        "keyframe_bits": 0,
        "tenant_scope_sha256": bytes((0xA1,)) * 32,
        "metadata_policy_sha256": bytes((0xB1,)) * 32,
        "provenance_sha256": bytes((0xC1,)) * 32,
        "payload": IMAGE_PAYLOAD,
    }


def audio_spec() -> Record:
    return {
        "kind": media.AUDIO,
        "semantic_abi": 1,
        "codec_id": 2,
        "axes": (8, 2, 48_000),
        "target_axes": (8, 2, 48_000),
        "time_base": (1, 48_000),
        "storage_stride": 4,
        "representation": AUDIO_PCM_S16LE,
        "layout": AUDIO_INTERLEAVED,
        "orientation": NOT_APPLICABLE,
        "transfer": NOT_APPLICABLE,
        "alpha": NOT_APPLICABLE,
        "start_ticks": 0,
        "keyframe_bits": 0,
        "tenant_scope_sha256": bytes((0xA2,)) * 32,
        "metadata_policy_sha256": bytes((0xB2,)) * 32,
        "provenance_sha256": bytes((0xC2,)) * 32,
        "payload": AUDIO_PAYLOAD,
    }


def video_spec() -> Record:
    return {
        "kind": media.VIDEO,
        "semantic_abi": 1,
        "codec_id": 3,
        "axes": (2, 2, 2),
        "target_axes": (2, 2, 2),
        "time_base": (1, 30),
        "storage_stride": 4,
        "representation": VIDEO_GRAY8_INTRA,
        "layout": VIDEO_GRAY,
        "orientation": TOP_LEFT,
        "transfer": LINEAR,
        "alpha": ALPHA_NOT_PRESENT,
        "start_ticks": 0,
        "keyframe_bits": 0b11,
        "tenant_scope_sha256": bytes((0xA3,)) * 32,
        "metadata_policy_sha256": bytes((0xB3,)) * 32,
        "provenance_sha256": bytes((0xC3,)) * 32,
        "payload": VIDEO_PAYLOAD,
    }


def _spec(value: Record) -> Record:
    try:
        spec = {
            "kind": value["kind"],
            "semantic_abi": value["semantic_abi"],
            "codec_id": value["codec_id"],
            "axes": tuple(value["axes"]),
            "target_axes": tuple(value["target_axes"]),
            "time_base": tuple(value["time_base"]),
            "storage_stride": value["storage_stride"],
            "representation": value["representation"],
            "layout": value["layout"],
            "orientation": value["orientation"],
            "transfer": value["transfer"],
            "alpha": value["alpha"],
            "start_ticks": value["start_ticks"],
            "keyframe_bits": value["keyframe_bits"],
            "tenant_scope_sha256": _digest(
                value["tenant_scope_sha256"]
            ),
            "metadata_policy_sha256": _digest(
                value["metadata_policy_sha256"]
            ),
            "provenance_sha256": _digest(
                value["provenance_sha256"]
            ),
            "payload": value["payload"],
        }
    except (KeyError, TypeError):
        raise MediaDecodeFixtureError("invalid fixture spec") from None
    if (
        not isinstance(spec["payload"], bytes)
        or not 0 < len(spec["payload"]) <= MAXIMUM_PAYLOAD_BYTES
        or len(spec["axes"]) != 3
        or len(spec["target_axes"]) != 3
    ):
        raise MediaDecodeFixtureError("invalid fixture payload")
    for name in (
        "kind",
        "semantic_abi",
        "codec_id",
        "storage_stride",
        "representation",
        "layout",
        "orientation",
        "transfer",
        "alpha",
        "start_ticks",
        "keyframe_bits",
    ):
        _u64(spec[name])
    for axis in spec["axes"]:
        _u64(axis)
        if axis == 0:
            raise MediaDecodeFixtureError("invalid fixture axes")
    for axis in spec["target_axes"]:
        _u64(axis)
        if axis == 0:
            raise MediaDecodeFixtureError("invalid target axes")
    if spec["target_axes"] != spec["axes"]:
        raise MediaDecodeFixtureError("non-identity fixture geometry")
    if spec["semantic_abi"] == 0 or spec["codec_id"] == 0:
        raise MediaDecodeFixtureError("invalid fixture identity")

    axes = spec["axes"]
    if spec["kind"] == media.IMAGE:
        channels = axes[2]
        if channels == 3:
            expected_representation, expected_layout = (
                IMAGE_RGB8,
                IMAGE_RGB,
            )
        elif channels == 1:
            expected_representation, expected_layout = (
                IMAGE_GRAY8,
                IMAGE_GRAY,
            )
        else:
            raise MediaDecodeFixtureError("invalid image channels")
        row_bytes = axes[0] * channels
        expected_payload = row_bytes * axes[1]
        valid = (
            spec["representation"] == expected_representation
            and spec["layout"] == expected_layout
            and spec["orientation"] == TOP_LEFT
            and spec["transfer"] == SRGB
            and spec["alpha"] == ALPHA_NOT_PRESENT
            and spec["time_base"] == (0, 1)
            and spec["storage_stride"] == row_bytes
            and spec["start_ticks"] == 0
            and spec["keyframe_bits"] == 0
        )
    elif spec["kind"] == media.AUDIO:
        frame_bytes = axes[1] * 2
        expected_payload = axes[0] * frame_bytes
        valid = (
            axes[1] <= 64
            and axes[2] <= 768_000
            and spec["representation"] == AUDIO_PCM_S16LE
            and spec["layout"] == AUDIO_INTERLEAVED
            and spec["orientation"] == NOT_APPLICABLE
            and spec["transfer"] == NOT_APPLICABLE
            and spec["alpha"] == NOT_APPLICABLE
            and spec["time_base"] == (1, axes[2])
            and spec["storage_stride"] == frame_bytes
            and spec["keyframe_bits"] == 0
        )
    elif spec["kind"] == media.VIDEO:
        _time_base(spec["time_base"])
        frame_bytes = axes[0] * axes[1]
        expected_payload = axes[2] * frame_bytes
        if axes[2] > 64:
            raise MediaDecodeFixtureError("too many fixture frames")
        allowed_keyframes = (1 << axes[2]) - 1
        valid = (
            spec["representation"] == VIDEO_GRAY8_INTRA
            and spec["layout"] == VIDEO_GRAY
            and spec["orientation"] == TOP_LEFT
            and spec["transfer"] == LINEAR
            and spec["alpha"] == ALPHA_NOT_PRESENT
            and spec["storage_stride"] == frame_bytes
            and spec["keyframe_bits"] & 1
            and not spec["keyframe_bits"] & ~allowed_keyframes
        )
    else:
        raise MediaDecodeFixtureError("invalid media kind")
    if (
        not valid
        or expected_payload != len(spec["payload"])
        or expected_payload > U64_MAX
    ):
        raise MediaDecodeFixtureError("contradictory fixture")
    return spec


def fixture_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise MediaDecodeFixtureError("invalid fixture body")
    return _hash(FIXTURE_DOMAIN, body)


def encode_fixture(value: Record) -> bytes:
    spec = _spec(value)
    total = (
        FIXTURE_HEADER_BYTES
        + len(spec["payload"])
        + FIXTURE_FOOTER_BYTES
    )
    output = bytearray(total)
    output[:192] = b"".join(
        (
            FIXTURE_MAGIC,
            _u64(FIXTURE_ABI),
            _u64(total),
            _u64(FIXTURE_HEADER_BYTES),
            _u64(ALLOWED_FLAGS),
            _u64(spec["kind"]),
            _u64(spec["semantic_abi"]),
            _u64(CONTAINER_ID),
            _u64(spec["codec_id"]),
            *(_u64(axis) for axis in spec["axes"]),
            _u64(spec["time_base"][0]),
            _u64(spec["time_base"][1]),
            _u64(FIXTURE_HEADER_BYTES),
            _u64(len(spec["payload"])),
            _u64(spec["storage_stride"]),
            _u64(spec["representation"]),
            _u64(spec["layout"]),
            _u64(spec["orientation"]),
            _u64(spec["transfer"]),
            _u64(spec["alpha"]),
            _u64(spec["start_ticks"]),
            _u64(spec["keyframe_bits"]),
        )
    )
    output[192:288] = b"".join(
        (
            spec["tenant_scope_sha256"],
            spec["metadata_policy_sha256"],
            spec["provenance_sha256"],
        )
    )
    output[288:312] = b"".join(
        _u64(axis) for axis in spec["target_axes"]
    )
    output[320 : 320 + len(spec["payload"])] = spec["payload"]
    output[-32:] = fixture_root(bytes(output[:-32]))
    return bytes(output)


def parse_fixture(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or not FIXTURE_HEADER_BYTES + 32
        <= len(encoded)
        <= MAXIMUM_FIXTURE_BYTES
        or encoded[:8] != FIXTURE_MAGIC
        or _read(encoded, 8) != FIXTURE_ABI
        or _read(encoded, 16) != len(encoded)
        or _read(encoded, 24) != FIXTURE_HEADER_BYTES
        or _read(encoded, 32) != ALLOWED_FLAGS
        or _read(encoded, 56) != CONTAINER_ID
        or _read(encoded, 112) != FIXTURE_HEADER_BYTES
        or _read(encoded, 312) != 0
    ):
        raise MediaDecodeFixtureError("invalid fixture wire")
    payload_bytes = _read(encoded, 120)
    if (
        not 0 < payload_bytes <= MAXIMUM_PAYLOAD_BYTES
        or FIXTURE_HEADER_BYTES + payload_bytes + 32 != len(encoded)
        or encoded[-32:] != fixture_root(encoded[:-32])
    ):
        raise MediaDecodeFixtureError("invalid fixture bounds")
    spec = _spec(
        {
            "kind": _read(encoded, 40),
            "semantic_abi": _read(encoded, 48),
            "codec_id": _read(encoded, 64),
            "axes": tuple(
                _read(encoded, offset) for offset in (72, 80, 88)
            ),
            "target_axes": tuple(
                _read(encoded, offset) for offset in (288, 296, 304)
            ),
            "time_base": (_read(encoded, 96), _read(encoded, 104)),
            "storage_stride": _read(encoded, 128),
            "representation": _read(encoded, 136),
            "layout": _read(encoded, 144),
            "orientation": _read(encoded, 152),
            "transfer": _read(encoded, 160),
            "alpha": _read(encoded, 168),
            "start_ticks": _read(encoded, 176),
            "keyframe_bits": _read(encoded, 184),
            "tenant_scope_sha256": encoded[192:224],
            "metadata_policy_sha256": encoded[224:256],
            "provenance_sha256": encoded[256:288],
            "payload": encoded[320 : 320 + payload_bytes],
        }
    )
    media_object = {
        "kind": spec["kind"],
        "semantic_abi": spec["semantic_abi"],
        "byte_length": len(spec["payload"]),
        "container_id": CONTAINER_ID,
        "codec_id": spec["codec_id"],
        "axes": spec["axes"],
        "time_base": spec["time_base"],
        "tenant_scope_sha256": spec["tenant_scope_sha256"],
        "content_sha256": hashlib.sha256(spec["payload"]).digest(),
        "metadata_policy_sha256": spec["metadata_policy_sha256"],
        "provenance_sha256": spec["provenance_sha256"],
    }
    object_encoded = media.encode_media_object(media_object)
    return {
        **spec,
        "media_object": media_object,
        "media_object_sha256": media.media_object_sha256(object_encoded),
        "fixture_sha256": encoded[-32:],
    }


def decoder_implementation_sha256() -> bytes:
    return _hash(
        DECODER_DOMAIN,
        _u64(DECODER_ABI),
        _u64(MAXIMUM_PAYLOAD_BYTES),
    )


def identity_transform_sha256(kind: int, representation: int) -> bytes:
    return _hash(
        TRANSFORM_DOMAIN,
        _u64(kind),
        _u64(representation),
    )


def logical_units(fixture: Record) -> int:
    if fixture["kind"] == media.IMAGE:
        value = fixture["axes"][0] * fixture["axes"][1]
    elif fixture["kind"] == media.AUDIO:
        value = fixture["axes"][0]
    else:
        value = fixture["axes"][2]
    if value > U64_MAX:
        raise MediaDecodeFixtureError("logical units overflow")
    return value


def make_decode_plan(
    fixture: Record,
    resource_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    return _plan(
        {
            "kind": fixture["kind"],
            "decoder_abi": DECODER_ABI,
            "source_container_id": CONTAINER_ID,
            "source_codec_id": fixture["codec_id"],
            "destination_representation_id": fixture[
                "representation"
            ],
            "execution_mode": DETERMINISTIC,
            "numerical_policy": EXACT_INTEGER,
            "rejection_policy": FAIL_CLOSED,
            "required_capabilities": 0,
            "source_bytes": len(fixture["payload"]),
            "output_bytes": len(fixture["payload"]),
            "scratch_bytes": 0,
            "logical_units": logical_units(fixture),
            "source_axes": fixture["axes"],
            "target_axes": fixture["target_axes"],
            "source_time_base": fixture["time_base"],
            "target_time_base": fixture["time_base"],
            "media_object_sha256": fixture["media_object_sha256"],
            "decoder_implementation_sha256": (
                decoder_implementation_sha256()
            ),
            "transform_policy_sha256": identity_transform_sha256(
                fixture["kind"], fixture["representation"]
            ),
            "resource_policy_sha256": resource_policy_sha256,
            "challenge_sha256": challenge_sha256,
        }
    )


def complete_mapping_sha256(fixture: Record) -> bytes:
    return _hash(
        MAPPING_DOMAIN,
        fixture["fixture_sha256"],
        _u64(fixture["kind"]),
        _u64(FIXTURE_HEADER_BYTES),
        _u64(len(fixture["payload"])),
        _u64(logical_units(fixture)),
        _u64(fixture["storage_stride"]),
    )


def unit_mapping_root(mapping: Record, fixture_sha256: bytes) -> bytes:
    return _hash(
        MAPPING_DOMAIN,
        fixture_sha256,
        _u64(mapping["kind"]),
        _u64(mapping["unit_index"]),
        _u64(mapping["source_offset"]),
        _u64(mapping["source_bytes"]),
        _u64(mapping["output_offset"]),
        _u64(mapping["output_bytes"]),
        _u64(int(mapping["has_timeline"])),
        _u64(mapping["timeline_tick"]),
    )


def map_unit(encoded_fixture: bytes, unit_index: int) -> Record:
    fixture = parse_fixture(encoded_fixture)
    units = logical_units(fixture)
    _u64(unit_index)
    if unit_index >= units:
        raise MediaDecodeFixtureError("unit out of range")
    if fixture["kind"] == media.IMAGE:
        width = fixture["axes"][0]
        row, column = divmod(unit_index, width)
        unit_bytes = fixture["axes"][2]
        relative = (
            row * fixture["storage_stride"] + column * unit_bytes
        )
    else:
        unit_bytes = fixture["storage_stride"]
        relative = unit_index * unit_bytes
    has_timeline = fixture["kind"] != media.IMAGE
    timeline_tick = (
        fixture["start_ticks"] + unit_index if has_timeline else 0
    )
    if max(relative, timeline_tick) > U64_MAX:
        raise MediaDecodeFixtureError("mapping overflow")
    mapping = {
        "kind": fixture["kind"],
        "unit_index": unit_index,
        "source_offset": FIXTURE_HEADER_BYTES + relative,
        "source_bytes": unit_bytes,
        "output_offset": relative,
        "output_bytes": unit_bytes,
        "has_timeline": has_timeline,
        "timeline_tick": timeline_tick,
    }
    mapping["mapping_sha256"] = unit_mapping_root(
        mapping, fixture["fixture_sha256"]
    )
    return mapping


def verify_complete_mapping(encoded_fixture: bytes) -> int:
    fixture = parse_fixture(encoded_fixture)
    units = logical_units(fixture)
    next_source, next_output = FIXTURE_HEADER_BYTES, 0
    for index in range(units):
        mapping = map_unit(encoded_fixture, index)
        if (
            mapping["source_offset"] != next_source
            or mapping["output_offset"] != next_output
            or mapping["source_bytes"] != mapping["output_bytes"]
        ):
            raise MediaDecodeFixtureError("mapping gap or overlap")
        next_source += mapping["source_bytes"]
        next_output += mapping["output_bytes"]
    if (
        next_source != FIXTURE_HEADER_BYTES + len(fixture["payload"])
        or next_output != len(fixture["payload"])
    ):
        raise MediaDecodeFixtureError("incomplete mapping")
    return units


def receipt_root(receipt: Record) -> bytes:
    return _hash(
        RECEIPT_DOMAIN,
        _u64(receipt["kind"]),
        _u64(receipt["logical_units"]),
        _u64(receipt["source_payload_offset"]),
        _u64(receipt["source_payload_bytes"]),
        _u64(receipt["output_bytes"]),
        _digest(receipt["media_object_sha256"]),
        _digest(receipt["decode_plan_sha256"]),
        _digest(receipt["fixture_sha256"]),
        _digest(receipt["output_sha256"]),
        _digest(receipt["mapping_sha256"]),
    )


def decode_fixture(
    encoded_fixture: bytes,
    encoded_plan: bytes,
    destination: bytearray,
) -> Record:
    fixture = parse_fixture(encoded_fixture)
    plan = decode_plan(encoded_plan)
    validate_for_media_object(
        plan,
        fixture["media_object"],
        fixture["media_object_sha256"],
    )
    units = logical_units(fixture)
    if (
        plan["decoder_abi"] != DECODER_ABI
        or plan["destination_representation_id"]
        != fixture["representation"]
        or plan["execution_mode"] != DETERMINISTIC
        or plan["numerical_policy"] != EXACT_INTEGER
        or plan["rejection_policy"] != FAIL_CLOSED
        or plan["required_capabilities"] != 0
        or plan["output_bytes"] != len(fixture["payload"])
        or plan["scratch_bytes"] != 0
        or plan["logical_units"] != units
        or plan["target_axes"] != fixture["target_axes"]
        or plan["target_time_base"] != fixture["time_base"]
        or plan["decoder_implementation_sha256"]
        != decoder_implementation_sha256()
        or plan["transform_policy_sha256"]
        != identity_transform_sha256(
            fixture["kind"], fixture["representation"]
        )
    ):
        raise MediaDecodeFixtureError("unsupported decode plan")
    if not isinstance(destination, bytearray) or len(
        destination
    ) < len(fixture["payload"]):
        raise MediaDecodeFixtureError("destination too small")
    destination[: len(fixture["payload"])] = fixture["payload"]
    receipt = {
        "kind": fixture["kind"],
        "logical_units": units,
        "source_payload_offset": FIXTURE_HEADER_BYTES,
        "source_payload_bytes": len(fixture["payload"]),
        "output_bytes": len(fixture["payload"]),
        "media_object_sha256": fixture["media_object_sha256"],
        "decode_plan_sha256": plan_sha256(encoded_plan),
        "fixture_sha256": fixture["fixture_sha256"],
        "output_sha256": hashlib.sha256(
            destination[: len(fixture["payload"])]
        ).digest(),
        "mapping_sha256": complete_mapping_sha256(fixture),
    }
    receipt["receipt_sha256"] = receipt_root(receipt)
    return receipt
