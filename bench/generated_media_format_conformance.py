"""Independent oracle for the generated-media format conformance sidecar.

This module mirrors the frozen V1 record and batch wires without importing or
executing Zig.  Independent producer oracles validate the complete canonical
image-plan, audio-plan, and video-manifest wires, while the external-format
oracle performs the PNG, WAVE, and APNG inspection used when record inputs are
constructed.
"""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import generated_audio_playback as audio_producer
from bench import generated_image_publication as image_producer
from bench import generated_media_external_format as external
from bench import generated_media_output_registry as registry
from bench import generated_media_producer_transition as transition
from bench import generated_video_display as video_producer


Record = dict[str, Any]

ZERO = bytes(32)
U64_MAX = (1 << 64) - 1

ABI = 1
ALLOWED_FLAGS = 0
MAX_ENTRIES = 12

FORMAT_RECORD_BYTES = 1_152
FORMAT_RECORD_BODY_BYTES = 1_120
PRODUCER_WIRE_SLOT_BYTES = 736
FORMAT_BATCH_HEADER_BYTES = 576
FORMAT_BATCH_BODY_BYTES = 544

FORMAT_RECORD_MAGIC = b"GLMFMT1\x00"
FORMAT_BATCH_MAGIC = b"GLMFBAT1"
FORMAT_RECORD_DOMAIN = b"glacier-generated-media-format-record-v1\x00"
FORMAT_RECORD_TABLE_DOMAIN = b"glacier-generated-media-format-record-table-v1\x00"
FORMAT_BATCH_DOMAIN = b"glacier-generated-media-format-batch-v1\x00"
PROFILE_SET_DOMAIN = b"glacier-generated-media-format-profile-set-v1\x00"
FORMAT_CONTRACT_DOMAIN = b"glacier-generated-media-format-contract-v1\x00"
REGISTRY_PAYLOAD_DOMAIN = b"glacier.generated-media-output-registry-payload.v1"

IMAGE_MODALITY = 1
AUDIO_MODALITY = 2
VIDEO_MODALITY = 3
MODALITIES = (IMAGE_MODALITY, AUDIO_MODALITY, VIDEO_MODALITY)

PNG_PROFILE = 1
WAVE_PCM_S16LE_PROFILE = 2
APNG_TWO_FRAME_GRAY8_PROFILE = 3
PROFILES = (
    PNG_PROFILE,
    WAVE_PCM_S16LE_PROFILE,
    APNG_TWO_FRAME_GRAY8_PROFILE,
)

PNG_ENCODING_ABI = 0x474D_504E_4700_0001
WAVE_ENCODING_ABI = 0x474D_5741_5645_0001
APNG_ENCODING_ABI = 0x474D_4150_4E47_0001

PNG_CONTRACT_IDENTITY = (
    b"w3c-png-3;png8;gray-gray-alpha-rgb-rgba;"
    b"linear-gama100000-or-srgb-intent0;filter0;"
    b"zlib-7801-stored-max65535;one-idat;no-extra-chunks"
)
WAVE_CONTRACT_IDENTITY = (
    b"microsoft-riff-wave;pcm-format1;s16le-interleaved;"
    b"channels1-or2;fixed-fmt16;fixed-header44;"
    b"single-data-chunk;no-padding-no-extra-chunks-no-rf64"
)
APNG_CONTRACT_IDENTITY = (
    b"w3c-png-3;apng-gray8-two-full-canvas-frames;"
    b"linear-gama100000;plays1;source-blend;dispose-none;"
    b"reduced-exact-u16-delays;per-frame-zlib-7801-stored-max65535;"
    b"one-idat-one-fdat;no-extra-chunks"
)

MODALITY_PROFILE = {
    IMAGE_MODALITY: PNG_PROFILE,
    AUDIO_MODALITY: WAVE_PCM_S16LE_PROFILE,
    VIDEO_MODALITY: APNG_TWO_FRAME_GRAY8_PROFILE,
}
MODALITY_BITS = {
    IMAGE_MODALITY: 1,
    AUDIO_MODALITY: 2,
    VIDEO_MODALITY: 4,
}
PRODUCER_WIRE_BYTES = {
    IMAGE_MODALITY: 736,
    AUDIO_MODALITY: 576,
    VIDEO_MODALITY: 736,
}
PROFILE_ENCODING_ABI = {
    PNG_PROFILE: PNG_ENCODING_ABI,
    WAVE_PCM_S16LE_PROFILE: WAVE_ENCODING_ABI,
    APNG_TWO_FRAME_GRAY8_PROFILE: APNG_ENCODING_ABI,
}
PROFILE_CONTRACT_IDENTITY = {
    PNG_PROFILE: PNG_CONTRACT_IDENTITY,
    WAVE_PCM_S16LE_PROFILE: WAVE_CONTRACT_IDENTITY,
    APNG_TWO_FRAME_GRAY8_PROFILE: APNG_CONTRACT_IDENTITY,
}

RECORD_INPUT_SCALARS = (
    "modality",
    "profile",
    "registry_ordinal",
    "encoding_abi",
    "raw_output_bytes",
    "encoded_payload_bytes",
)
RECORD_DIGESTS = (
    "producer_plan_or_manifest_sha256",
    "raw_output_sha256",
    "encoded_payload_sha256",
    "registry_payload_sha256",
    "encoder_implementation_sha256",
    "format_contract_sha256",
    "transition_receipt_sha256",
    "registry_entry_sha256",
    "previous_format_record_sha256",
)
RECORD_NONZERO_DIGESTS = RECORD_DIGESTS[:-1]
RECORD_INPUT_FIELDS = {
    *RECORD_INPUT_SCALARS,
    *RECORD_DIGESTS,
    "producer_wire",
}
RECORD_FIELDS = {
    *RECORD_INPUT_FIELDS,
    "producer_wire_bytes",
    "record_sha256",
}
RECORD_DIGEST_OFFSETS = {
    field: 96 + index * 32 for index, field in enumerate(RECORD_DIGESTS)
}

BATCH_METADATA_SCALARS = (
    "request_epoch",
    "registry_generation",
    "publication_sequence",
)
BATCH_METADATA_DIGESTS = (
    "generation_plan_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "transition_batch_sha256",
    "registry_manifest_sha256",
    "registry_archive_sha256",
)
BATCH_METADATA_FIELDS = {
    *BATCH_METADATA_SCALARS,
    *BATCH_METADATA_DIGESTS,
}
BATCH_SCALARS = (
    *BATCH_METADATA_SCALARS,
    "record_count",
    "record_table_bytes",
    "aggregate_raw_output_bytes",
    "aggregate_encoded_payload_bytes",
    "modality_mask",
)
BATCH_DIGESTS = (
    *BATCH_METADATA_DIGESTS,
    "record_table_sha256",
    "profile_set_sha256",
    "previous_format_batch_sha256",
    "first_record_sha256",
    "terminal_image_sha256",
    "terminal_audio_sha256",
    "terminal_video_sha256",
)
BATCH_FIELDS = {
    *BATCH_SCALARS,
    *BATCH_DIGESTS,
    "batch_sha256",
}
BATCH_DIGEST_OFFSETS = {
    "generation_plan_sha256": 96,
    "tenant_scope_sha256": 128,
    "metadata_policy_sha256": 160,
    "challenge_sha256": 192,
    "transition_batch_sha256": 224,
    "registry_manifest_sha256": 256,
    "registry_archive_sha256": 288,
    "record_table_sha256": 320,
    "profile_set_sha256": 352,
    "previous_format_batch_sha256": 384,
    "first_record_sha256": 416,
    "terminal_image_sha256": 448,
    "terminal_audio_sha256": 480,
    "terminal_video_sha256": 512,
}


class GeneratedMediaFormatConformanceError(ValueError):
    """A format-conformance value or wire is not canonical."""


def _u64(value: Any) -> int:
    if type(value) is not int or value < 0 or value > U64_MAX:
        raise GeneratedMediaFormatConformanceError("invalid u64")
    return value


def _digest(value: Any) -> bytes:
    if type(value) is not bytes or len(value) != 32:
        raise GeneratedMediaFormatConformanceError("invalid digest")
    return value


def _immutable_bytes(value: Any, where: str) -> bytes:
    if type(value) is not bytes:
        raise GeneratedMediaFormatConformanceError(f"{where} must be immutable bytes")
    return value


def _add(left: int, right: int) -> int:
    result = _u64(left) + _u64(right)
    if result > U64_MAX:
        raise GeneratedMediaFormatConformanceError("u64 overflow")
    return result


def _u64_bytes(value: int) -> bytes:
    return struct.pack("<Q", _u64(value))


def _domain_root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(
        _immutable_bytes(domain, "root domain") + _immutable_bytes(body, "root body")
    ).digest()


def encoding_abi(profile: int) -> int:
    """Return the codec-owned encoding ABI for one delivery profile."""

    checked = _u64(profile)
    try:
        return PROFILE_ENCODING_ABI[checked]
    except KeyError as error:
        raise GeneratedMediaFormatConformanceError(
            "unsupported delivery profile"
        ) from error


def format_contract_root(profile: int) -> bytes:
    """Derive the codec-owned, ABI-bound canonical contract root."""

    checked = _u64(profile)
    try:
        identity = PROFILE_CONTRACT_IDENTITY[checked]
    except KeyError as error:
        raise GeneratedMediaFormatConformanceError(
            "unsupported delivery profile"
        ) from error
    return hashlib.sha256(
        FORMAT_CONTRACT_DOMAIN + _u64_bytes(encoding_abi(checked)) + identity
    ).digest()


def profile_set_root() -> bytes:
    """Bind all retained profiles in their frozen profile-enum order."""

    return _domain_root(
        PROFILE_SET_DOMAIN,
        b"".join(format_contract_root(profile) for profile in PROFILES),
    )


def registry_payload_root(
    modality: int,
    registry_ordinal: int,
    payload_encoding_abi: int,
    raw_output_sha256: bytes,
    payload: bytes,
) -> bytes:
    """Derive the registry's domain-separated payload identity.

    This is deliberately distinct from the plain SHA-256 of the delivered
    encoded bytes, which occupies a separate field in the sidecar record.
    """

    checked_modality = _u64(modality)
    checked_payload = _immutable_bytes(payload, "registry payload")
    if (
        checked_modality not in MODALITIES
        or _u64(payload_encoding_abi) == 0
        or not checked_payload
    ):
        raise GeneratedMediaFormatConformanceError("invalid registry payload")
    return hashlib.sha256(
        REGISTRY_PAYLOAD_DOMAIN
        + _u64_bytes(checked_modality)
        + _u64_bytes(registry_ordinal)
        + _u64_bytes(payload_encoding_abi)
        + _u64_bytes(len(checked_payload))
        + _digest(raw_output_sha256)
        + checked_payload
    ).digest()


def _inspect_payload(modality: int, payload: bytes) -> Record:
    try:
        if modality == IMAGE_MODALITY:
            return external.decode_image_png(payload)
        if modality == AUDIO_MODALITY:
            return external.decode_audio_wave(payload)
        if modality == VIDEO_MODALITY:
            return external.decode_video_apng(payload)
    except external.GeneratedMediaExternalFormatError as error:
        raise GeneratedMediaFormatConformanceError(
            "encoded payload violates its delivery profile"
        ) from error
    raise GeneratedMediaFormatConformanceError("unsupported modality")


def decode_producer_wire(modality: int, producer_wire: bytes) -> Record:
    """Validate and decode one exact canonical producer plan or manifest."""

    checked_modality = _u64(modality)
    wire = _immutable_bytes(producer_wire, "producer wire")
    try:
        if checked_modality == IMAGE_MODALITY:
            return image_producer.decode_plan(wire)
        if checked_modality == AUDIO_MODALITY:
            return audio_producer.decode_plan(wire)
        if checked_modality == VIDEO_MODALITY:
            return video_producer.decode_manifest(wire)
    except (
        image_producer.GeneratedImagePublicationError,
        audio_producer.GeneratedAudioPlaybackError,
        video_producer.GeneratedVideoDisplayError,
    ) as error:
        raise GeneratedMediaFormatConformanceError(
            "invalid canonical producer wire"
        ) from error
    raise GeneratedMediaFormatConformanceError("unsupported modality")


def producer_wire_root(modality: int, producer_wire: bytes) -> bytes:
    """Return the canonical footer/root claimed by a producer wire."""

    decoded = decode_producer_wire(modality, producer_wire)
    field = {
        IMAGE_MODALITY: "plan_sha256",
        AUDIO_MODALITY: "plan_sha256",
        VIDEO_MODALITY: "manifest_sha256",
    }[_u64(modality)]
    return _digest(decoded[field])


def _validate_profile_binding(
    modality: int,
    producer: Record,
    inspection: Record,
) -> None:
    raw = _immutable_bytes(inspection["raw"], "inspected raw output")
    if modality == IMAGE_MODALITY:
        transfer = {
            image_producer.LINEAR: "linear",
            image_producer.SRGB: "srgb",
        }.get(producer["transfer_function"])
        valid = (
            producer["width"] == inspection["width"]
            and producer["height"] == inspection["height"]
            and producer["channels"] == inspection["channels"]
            and producer["color_model"] == image_producer.GRAY
            and producer["alpha_mode"] == image_producer.ALPHA_NONE
            and transfer == inspection["transfer"]
            and producer["pixel_bytes"] == len(raw)
        )
    elif modality == AUDIO_MODALITY:
        valid = (
            producer["sample_rate"] == inspection["sample_rate"]
            and producer["channels"] == inspection["channels"]
            and producer["bytes_per_sample"] == inspection["bits_per_sample"] // 8
            and producer["frame_count"] == inspection["frame_count"]
            and producer["pcm_bytes"] == len(raw)
        )
    elif modality == VIDEO_MODALITY:
        frames = inspection["frames"]
        valid = (
            producer["width"] == inspection["width"]
            and producer["height"] == inspection["height"]
            and producer["channels"] == inspection["channels"]
            and producer["bytes_per_channel"] == 1
            and producer["frame_count"] == inspection["frame_count"]
            and (
                producer["time_base_numerator"],
                producer["time_base_denominator"],
            )
            == inspection["time_base"]
            and (
                producer["first_duration_ticks"],
                producer["second_duration_ticks"],
            )
            == inspection["duration_ticks"]
            and producer["frame_bytes"] == len(frames[0])
            and producer["total_output_bytes"] == len(raw)
            and producer["first_frame_sha256"] == hashlib.sha256(frames[0]).digest()
            and producer["second_frame_sha256"] == hashlib.sha256(frames[1]).digest()
        )
    else:
        valid = False
    if not valid:
        raise GeneratedMediaFormatConformanceError(
            "producer wire and delivered profile disagree"
        )


def _producer_receipt_claims(modality: int, producer: Record) -> Record:
    """Derive receipt claims that are fixed by one decoded producer wire."""

    common: Record = {
        "request_epoch": producer["request_epoch"],
        "producer_generation": producer["generation"],
        "producer_publication_sequence": producer["publication_sequence"],
        "artifact_manifest_sha256": producer["artifact_sha256"],
        "tenant_scope_sha256": producer["tenant_scope_sha256"],
        "metadata_policy_sha256": producer["metadata_policy_sha256"],
        "challenge_sha256": producer["challenge_sha256"],
        "media_object_sha256": producer["media_object_sha256"],
        "materializer_required_capabilities": producer["required_capabilities"],
    }
    if modality == IMAGE_MODALITY:
        source_step = _u64(producer["source_step"])
        if source_step == 0:
            raise GeneratedMediaFormatConformanceError("invalid stateful producer step")
        return {
            **common,
            "producer_ordinal": producer["image_index"],
            "completion_sequence": 0,
            "producer_state_generation_before": producer["visible_images_before"],
            "producer_state_generation_after_publication": producer[
                "visible_images_after"
            ],
            "producer_state_generation_after_completion": producer[
                "visible_images_after"
            ],
            "model_kind": transition.STATEFUL_MODEL,
            "completion_kind": transition.NO_COMPLETION,
            "materializer_implementation_sha256": producer[
                "decoder_implementation_sha256"
            ],
            "materializer_payload_sha256": producer["decoder_payload_sha256"],
            "model_result_sha256": producer["terminal_result_sha256"],
            "model_output_sha256": producer["terminal_output_sha256"],
            "model_output_bytes": producer["latent_bytes"],
            "model_step_before": source_step - 1,
            "model_step_after": source_step,
            "model_plan_sha256": producer["terminal_plan_sha256"],
            "model_state_publication_after_sha256": producer[
                "terminal_state_publication_sha256"
            ],
        }
    generation = _u64(producer["generation"])
    if generation == 0 or generation == U64_MAX:
        raise GeneratedMediaFormatConformanceError(
            "invalid completed producer generation"
        )
    if modality == AUDIO_MODALITY:
        return {
            **common,
            "producer_ordinal": producer["chunk_index"],
            "completion_sequence": producer["chunk_index"],
            "producer_state_generation_before": generation - 1,
            "producer_state_generation_after_publication": generation,
            "producer_state_generation_after_completion": generation + 1,
            "model_kind": transition.STATELESS_MODEL,
            "completion_kind": transition.PLAYBACK_COMPLETION,
            "unit_start": producer["start_frame"],
            "unit_count": producer["frame_count"],
            "timeline_start": producer["start_frame"],
            "timeline_end": producer["visible_frames_after"],
            "materializer_implementation_sha256": producer[
                "renderer_implementation_sha256"
            ],
            "materializer_payload_sha256": producer["renderer_payload_sha256"],
            "model_result_sha256": producer["source_result_sha256"],
            "model_output_sha256": producer["source_output_sha256"],
            "model_output_bytes": producer["source_output_bytes"],
            "producer_state_before_sha256": producer["state_before_sha256"],
        }
    if modality == VIDEO_MODALITY:
        return {
            **common,
            "producer_ordinal": producer["segment_index"],
            "completion_sequence": producer["segment_index"],
            "producer_state_generation_before": generation - 1,
            "producer_state_generation_after_publication": generation,
            "producer_state_generation_after_completion": generation + 1,
            "model_kind": transition.STATELESS_MODEL,
            "completion_kind": transition.DISPLAY_COMPLETION,
            "unit_start": producer["first_frame_ordinal"],
            "unit_count": producer["frame_count"],
            "timeline_start": producer["start_tick"],
            "timeline_end": producer["end_tick"],
            "materializer_implementation_sha256": producer[
                "renderer_implementation_sha256"
            ],
            "materializer_payload_sha256": producer["renderer_payload_sha256"],
            "model_result_sha256": producer["source_result_sha256"],
            "model_output_sha256": producer["source_output_sha256"],
            "model_output_bytes": producer["source_output_bytes"],
            "producer_state_before_sha256": producer["state_before_sha256"],
        }
    raise GeneratedMediaFormatConformanceError("unsupported modality")


def _validate_producer_receipt_binding(
    modality: int,
    producer: Record,
    receipt: Record,
) -> None:
    expected = _producer_receipt_claims(modality, producer)
    if any(receipt.get(field) != value for field, value in expected.items()):
        raise GeneratedMediaFormatConformanceError(
            "producer wire and transition receipt disagree"
        )


def make_record_input(
    *,
    modality: int,
    registry_ordinal: int,
    producer_wire: bytes,
    producer_plan_or_manifest_sha256: bytes,
    encoded_payload: bytes,
    encoder_implementation_sha256: bytes,
    transition_receipt_sha256: bytes,
    registry_entry_sha256: bytes,
    previous_format_record_sha256: bytes = ZERO,
) -> Record:
    """Construct a record input after independent media-format inspection."""

    checked_modality = _u64(modality)
    payload = _immutable_bytes(encoded_payload, "encoded payload")
    inspection = _inspect_payload(checked_modality, payload)
    producer = decode_producer_wire(checked_modality, producer_wire)
    _validate_profile_binding(checked_modality, producer, inspection)
    profile = MODALITY_PROFILE[checked_modality]
    codec_abi = encoding_abi(profile)
    raw = _immutable_bytes(inspection["raw"], "inspected raw output")
    raw_sha256 = _digest(inspection["raw_sha256"])
    encoded_sha256 = _digest(inspection["encoded_sha256"])
    if (
        len(raw) == 0
        or len(payload) == 0
        or hashlib.sha256(raw).digest() != raw_sha256
        or hashlib.sha256(payload).digest() != encoded_sha256
    ):
        raise GeneratedMediaFormatConformanceError(
            "external-format inspection is internally inconsistent"
        )
    value: Record = {
        "modality": checked_modality,
        "profile": profile,
        "registry_ordinal": _u64(registry_ordinal),
        "encoding_abi": codec_abi,
        "raw_output_bytes": len(raw),
        "encoded_payload_bytes": len(payload),
        "producer_plan_or_manifest_sha256": _digest(producer_plan_or_manifest_sha256),
        "raw_output_sha256": raw_sha256,
        "encoded_payload_sha256": encoded_sha256,
        "registry_payload_sha256": registry_payload_root(
            checked_modality,
            registry_ordinal,
            codec_abi,
            raw_sha256,
            payload,
        ),
        "encoder_implementation_sha256": _digest(encoder_implementation_sha256),
        "format_contract_sha256": format_contract_root(profile),
        "transition_receipt_sha256": _digest(transition_receipt_sha256),
        "registry_entry_sha256": _digest(registry_entry_sha256),
        "previous_format_record_sha256": _digest(previous_format_record_sha256),
        "producer_wire": _immutable_bytes(producer_wire, "producer wire"),
    }
    return validate_record_input(value)


def validate_record_input(value: Record) -> Record:
    """Validate the semantic fields used to encode a canonical record."""

    if type(value) is not dict or set(value) != RECORD_INPUT_FIELDS:
        raise GeneratedMediaFormatConformanceError("invalid record input fields")
    checked = dict(value)
    for field in RECORD_INPUT_SCALARS:
        checked[field] = _u64(checked[field])
    for field in RECORD_DIGESTS:
        checked[field] = _digest(checked[field])
    checked["producer_wire"] = _immutable_bytes(
        checked["producer_wire"],
        "producer wire",
    )
    modality = checked["modality"]
    profile = checked["profile"]
    if (
        modality not in MODALITIES
        or profile != MODALITY_PROFILE[modality]
        or checked["encoding_abi"] != encoding_abi(profile)
        or len(checked["producer_wire"]) != PRODUCER_WIRE_BYTES[modality]
        or checked["raw_output_bytes"] == 0
        or checked["encoded_payload_bytes"] == 0
        or any(checked[field] == ZERO for field in RECORD_NONZERO_DIGESTS)
        or checked["format_contract_sha256"] != format_contract_root(profile)
        or checked["producer_plan_or_manifest_sha256"]
        != producer_wire_root(modality, checked["producer_wire"])
    ):
        raise GeneratedMediaFormatConformanceError("invalid record input")
    return checked


def _record_body(value: Record) -> bytes:
    checked = validate_record_input(value)
    body = bytearray(FORMAT_RECORD_BODY_BYTES)
    body[0:8] = FORMAT_RECORD_MAGIC
    struct.pack_into(
        "<QQQ",
        body,
        8,
        ABI,
        FORMAT_RECORD_BYTES,
        ALLOWED_FLAGS,
    )
    struct.pack_into(
        "<QQQQQQQ",
        body,
        32,
        checked["modality"],
        checked["profile"],
        checked["registry_ordinal"],
        checked["encoding_abi"],
        len(checked["producer_wire"]),
        checked["raw_output_bytes"],
        checked["encoded_payload_bytes"],
    )
    for field, offset in RECORD_DIGEST_OFFSETS.items():
        body[offset : offset + 32] = checked[field]
    producer_wire = checked["producer_wire"]
    body[384 : 384 + len(producer_wire)] = producer_wire
    return bytes(body)


def encode_format_record(value: Record) -> bytes:
    """Encode one exact 1,152-byte V1 format record."""

    body = _record_body(value)
    return body + _domain_root(FORMAT_RECORD_DOMAIN, body)


def _validate_decoded_record(value: Record) -> Record:
    if type(value) is not dict or set(value) != RECORD_FIELDS:
        raise GeneratedMediaFormatConformanceError("invalid decoded record fields")
    checked = dict(value)
    producer_wire_bytes = _u64(checked["producer_wire_bytes"])
    record_sha256 = _digest(checked["record_sha256"])
    input_value = {field: checked[field] for field in RECORD_INPUT_FIELDS}
    validated_input = validate_record_input(input_value)
    if (
        producer_wire_bytes != len(validated_input["producer_wire"])
        or record_sha256 == ZERO
    ):
        raise GeneratedMediaFormatConformanceError("invalid decoded record")
    validated_input["producer_wire_bytes"] = producer_wire_bytes
    validated_input["record_sha256"] = record_sha256
    return validated_input


def decode_format_record(raw: bytes) -> Record:
    """Decode and fully validate one exact V1 format record."""

    encoded = _immutable_bytes(raw, "format record")
    if (
        len(encoded) != FORMAT_RECORD_BYTES
        or encoded[0:8] != FORMAT_RECORD_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != FORMAT_RECORD_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != ALLOWED_FLAGS
        or struct.unpack_from("<Q", encoded, 88)[0] != 0
        or encoded[FORMAT_RECORD_BODY_BYTES:]
        != _domain_root(
            FORMAT_RECORD_DOMAIN,
            encoded[:FORMAT_RECORD_BODY_BYTES],
        )
    ):
        raise GeneratedMediaFormatConformanceError("invalid format record wire")
    (
        modality,
        profile,
        registry_ordinal,
        codec_abi,
        producer_wire_bytes,
        raw_output_bytes,
        encoded_payload_bytes,
    ) = struct.unpack_from("<QQQQQQQ", encoded, 32)
    if producer_wire_bytes > PRODUCER_WIRE_SLOT_BYTES:
        raise GeneratedMediaFormatConformanceError("invalid producer wire length")
    producer_end = 384 + producer_wire_bytes
    if any(encoded[producer_end:FORMAT_RECORD_BODY_BYTES]):
        raise GeneratedMediaFormatConformanceError("nonzero producer-slot padding")
    value: Record = {
        "modality": modality,
        "profile": profile,
        "registry_ordinal": registry_ordinal,
        "encoding_abi": codec_abi,
        "producer_wire_bytes": producer_wire_bytes,
        "raw_output_bytes": raw_output_bytes,
        "encoded_payload_bytes": encoded_payload_bytes,
        "producer_wire": encoded[384:producer_end],
        "record_sha256": encoded[FORMAT_RECORD_BODY_BYTES:],
    }
    for field, offset in RECORD_DIGEST_OFFSETS.items():
        value[field] = encoded[offset : offset + 32]
    return _validate_decoded_record(value)


def _validate_metadata(value: Record) -> Record:
    if type(value) is not dict or set(value) != BATCH_METADATA_FIELDS:
        raise GeneratedMediaFormatConformanceError("invalid batch metadata fields")
    checked = dict(value)
    for field in BATCH_METADATA_SCALARS:
        checked[field] = _u64(checked[field])
        if checked[field] == 0:
            raise GeneratedMediaFormatConformanceError("zero batch metadata scalar")
    for field in BATCH_METADATA_DIGESTS:
        checked[field] = _digest(checked[field])
        if checked[field] == ZERO:
            raise GeneratedMediaFormatConformanceError("zero batch metadata digest")
    return checked


def _evidence_from_bytes(value: bytes | None) -> Record | None:
    if value is None:
        return None
    return decode_format_evidence(_immutable_bytes(value, "previous format evidence"))


def _batch_body(batch: Record, total_bytes: int) -> bytes:
    body = bytearray(FORMAT_BATCH_BODY_BYTES)
    body[0:8] = FORMAT_BATCH_MAGIC
    struct.pack_into(
        "<QQQ",
        body,
        8,
        ABI,
        _u64(total_bytes),
        ALLOWED_FLAGS,
    )
    struct.pack_into(
        "<QQQQQQQQ",
        body,
        32,
        batch["request_epoch"],
        batch["registry_generation"],
        batch["publication_sequence"],
        batch["record_count"],
        batch["record_table_bytes"],
        batch["aggregate_raw_output_bytes"],
        batch["aggregate_encoded_payload_bytes"],
        batch["modality_mask"],
    )
    for field, offset in BATCH_DIGEST_OFFSETS.items():
        body[offset : offset + 32] = _digest(batch[field])
    return bytes(body)


def encode_format_evidence(
    metadata_value: Record,
    encoded_records: list[bytes],
    previous_evidence: bytes | None = None,
) -> bytes:
    """Encode a canonical batch around pre-encoded, lineage-bound records."""

    metadata = _validate_metadata(metadata_value)
    previous = _evidence_from_bytes(previous_evidence)
    if (metadata["registry_generation"] == 1) != (previous is None):
        raise GeneratedMediaFormatConformanceError("invalid format-batch predecessor")
    if (
        type(encoded_records) is not list
        or not 1 <= len(encoded_records) <= MAX_ENTRIES
    ):
        raise GeneratedMediaFormatConformanceError("invalid record count")
    record_wires = [
        _immutable_bytes(record, "encoded format record") for record in encoded_records
    ]
    records = [decode_format_record(record) for record in record_wires]

    expected_terminals = {
        modality: (
            ZERO
            if previous is None
            else previous["batch"][
                {
                    IMAGE_MODALITY: "terminal_image_sha256",
                    AUDIO_MODALITY: "terminal_audio_sha256",
                    VIDEO_MODALITY: "terminal_video_sha256",
                }[modality]
            ]
        )
        for modality in MODALITIES
    }
    current_terminals = {modality: ZERO for modality in MODALITIES}
    previous_modality = 0
    aggregate_raw = 0
    aggregate_encoded = 0
    modality_mask = 0
    for record in records:
        modality = record["modality"]
        if modality < previous_modality:
            raise GeneratedMediaFormatConformanceError(
                "records are not sorted by modality"
            )
        previous_modality = modality
        if record["previous_format_record_sha256"] != expected_terminals[modality]:
            raise GeneratedMediaFormatConformanceError("invalid format-record lineage")
        expected_terminals[modality] = record["record_sha256"]
        current_terminals[modality] = record["record_sha256"]
        aggregate_raw = _add(aggregate_raw, record["raw_output_bytes"])
        aggregate_encoded = _add(
            aggregate_encoded,
            record["encoded_payload_bytes"],
        )
        modality_mask |= MODALITY_BITS[modality]

    record_table = b"".join(record_wires)
    previous_batch_sha256 = (
        ZERO if previous is None else previous["batch"]["batch_sha256"]
    )
    batch: Record = {
        **metadata,
        "record_count": len(records),
        "record_table_bytes": len(record_table),
        "aggregate_raw_output_bytes": aggregate_raw,
        "aggregate_encoded_payload_bytes": aggregate_encoded,
        "modality_mask": modality_mask,
        "record_table_sha256": _domain_root(
            FORMAT_RECORD_TABLE_DOMAIN,
            record_table,
        ),
        "profile_set_sha256": profile_set_root(),
        "previous_format_batch_sha256": previous_batch_sha256,
        "first_record_sha256": records[0]["record_sha256"],
        "terminal_image_sha256": current_terminals[IMAGE_MODALITY],
        "terminal_audio_sha256": current_terminals[AUDIO_MODALITY],
        "terminal_video_sha256": current_terminals[VIDEO_MODALITY],
    }
    total_bytes = FORMAT_BATCH_HEADER_BYTES + len(record_table)
    body = _batch_body(batch, total_bytes)
    evidence = body + _domain_root(FORMAT_BATCH_DOMAIN, body) + record_table
    decode_format_evidence(evidence)
    return evidence


def _validate_batch_shape(
    batch: Record,
    record_table: bytes,
) -> tuple[Record, tuple[Record, ...]]:
    if type(batch) is not dict or set(batch) != BATCH_FIELDS:
        raise GeneratedMediaFormatConformanceError("invalid batch fields")
    checked = dict(batch)
    for field in BATCH_SCALARS:
        checked[field] = _u64(checked[field])
    for field in (*BATCH_DIGESTS, "batch_sha256"):
        checked[field] = _digest(checked[field])
    records_bytes = _immutable_bytes(record_table, "format record table")
    if (
        checked["request_epoch"] == 0
        or checked["registry_generation"] == 0
        or checked["publication_sequence"] == 0
        or not 1 <= checked["record_count"] <= MAX_ENTRIES
        or checked["record_table_bytes"] != len(records_bytes)
        or checked["record_table_bytes"]
        != checked["record_count"] * FORMAT_RECORD_BYTES
        or checked["aggregate_raw_output_bytes"] == 0
        or checked["aggregate_encoded_payload_bytes"] == 0
        or checked["modality_mask"] == 0
        or checked["modality_mask"] & ~0x7
        or any(
            checked[field] == ZERO
            for field in (
                *BATCH_METADATA_DIGESTS,
                "record_table_sha256",
                "profile_set_sha256",
                "first_record_sha256",
                "batch_sha256",
            )
        )
        or checked["profile_set_sha256"] != profile_set_root()
        or (checked["registry_generation"] == 1)
        != (checked["previous_format_batch_sha256"] == ZERO)
    ):
        raise GeneratedMediaFormatConformanceError("invalid batch shape")

    records: list[Record] = []
    aggregate_raw = 0
    aggregate_encoded = 0
    modality_mask = 0
    previous_modality = 0
    terminals = {modality: ZERO for modality in MODALITIES}
    seen: set[int] = set()
    for index in range(checked["record_count"]):
        start = index * FORMAT_RECORD_BYTES
        record = decode_format_record(
            records_bytes[start : start + FORMAT_RECORD_BYTES]
        )
        modality = record["modality"]
        if modality < previous_modality:
            raise GeneratedMediaFormatConformanceError(
                "records are not sorted by modality"
            )
        previous_modality = modality
        if modality in seen:
            expected_previous = terminals[modality]
            if record["previous_format_record_sha256"] != expected_previous:
                raise GeneratedMediaFormatConformanceError(
                    "broken intra-batch record lineage"
                )
        else:
            initial_previous = record["previous_format_record_sha256"] == ZERO
            if (checked["registry_generation"] == 1) != initial_previous:
                raise GeneratedMediaFormatConformanceError(
                    "invalid first record lineage"
                )
            seen.add(modality)
        terminals[modality] = record["record_sha256"]
        aggregate_raw = _add(aggregate_raw, record["raw_output_bytes"])
        aggregate_encoded = _add(
            aggregate_encoded,
            record["encoded_payload_bytes"],
        )
        modality_mask |= MODALITY_BITS[modality]
        records.append(record)
    if (
        aggregate_raw != checked["aggregate_raw_output_bytes"]
        or aggregate_encoded != checked["aggregate_encoded_payload_bytes"]
        or modality_mask != checked["modality_mask"]
        or records[0]["record_sha256"] != checked["first_record_sha256"]
        or terminals[IMAGE_MODALITY] != checked["terminal_image_sha256"]
        or terminals[AUDIO_MODALITY] != checked["terminal_audio_sha256"]
        or terminals[VIDEO_MODALITY] != checked["terminal_video_sha256"]
    ):
        raise GeneratedMediaFormatConformanceError(
            "batch aggregates or terminals disagree"
        )
    return checked, tuple(records)


def decode_format_evidence(raw: bytes) -> Record:
    """Decode and fully validate one V1 format evidence batch."""

    encoded = _immutable_bytes(raw, "format evidence")
    if (
        len(encoded) < FORMAT_BATCH_HEADER_BYTES
        or encoded[0:8] != FORMAT_BATCH_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != ABI
        or struct.unpack_from("<Q", encoded, 24)[0] != ALLOWED_FLAGS
    ):
        raise GeneratedMediaFormatConformanceError("invalid format evidence wire")
    declared_length = struct.unpack_from("<Q", encoded, 16)[0]
    record_count = struct.unpack_from("<Q", encoded, 56)[0]
    if not 1 <= record_count <= MAX_ENTRIES:
        raise GeneratedMediaFormatConformanceError("invalid batch record count")
    expected_table_bytes = record_count * FORMAT_RECORD_BYTES
    if (
        declared_length != len(encoded)
        or len(encoded) != FORMAT_BATCH_HEADER_BYTES + expected_table_bytes
        or struct.unpack_from("<Q", encoded, 64)[0] != expected_table_bytes
        or encoded[FORMAT_BATCH_BODY_BYTES:FORMAT_BATCH_HEADER_BYTES]
        != _domain_root(
            FORMAT_BATCH_DOMAIN,
            encoded[:FORMAT_BATCH_BODY_BYTES],
        )
    ):
        raise GeneratedMediaFormatConformanceError("invalid batch envelope")
    record_table = encoded[FORMAT_BATCH_HEADER_BYTES:]
    if encoded[320:352] != _domain_root(
        FORMAT_RECORD_TABLE_DOMAIN,
        record_table,
    ):
        raise GeneratedMediaFormatConformanceError("invalid format record table root")
    (
        request_epoch,
        registry_generation,
        publication_sequence,
        decoded_record_count,
        record_table_bytes,
        aggregate_raw_output_bytes,
        aggregate_encoded_payload_bytes,
        modality_mask,
    ) = struct.unpack_from("<QQQQQQQQ", encoded, 32)
    batch: Record = {
        "request_epoch": request_epoch,
        "registry_generation": registry_generation,
        "publication_sequence": publication_sequence,
        "record_count": decoded_record_count,
        "record_table_bytes": record_table_bytes,
        "aggregate_raw_output_bytes": aggregate_raw_output_bytes,
        "aggregate_encoded_payload_bytes": aggregate_encoded_payload_bytes,
        "modality_mask": modality_mask,
        "batch_sha256": encoded[FORMAT_BATCH_BODY_BYTES:FORMAT_BATCH_HEADER_BYTES],
    }
    for field, offset in BATCH_DIGEST_OFFSETS.items():
        batch[field] = encoded[offset : offset + 32]
    checked_batch, records = _validate_batch_shape(batch, record_table)
    return {
        "batch": checked_batch,
        "records": records,
        "record_table": record_table,
        "encoded": encoded,
    }


def validate_successor_format_evidence(
    current_raw: bytes,
    previous_raw: bytes,
) -> Record:
    """Validate the exact per-modality and batch-root predecessor links."""

    previous = decode_format_evidence(previous_raw)
    current = decode_format_evidence(current_raw)
    if (
        current["batch"]["previous_format_batch_sha256"]
        != previous["batch"]["batch_sha256"]
    ):
        raise GeneratedMediaFormatConformanceError("wrong previous format batch")
    expected = {
        IMAGE_MODALITY: previous["batch"]["terminal_image_sha256"],
        AUDIO_MODALITY: previous["batch"]["terminal_audio_sha256"],
        VIDEO_MODALITY: previous["batch"]["terminal_video_sha256"],
    }
    seen: set[int] = set()
    for record in current["records"]:
        modality = record["modality"]
        if modality not in seen:
            if record["previous_format_record_sha256"] != expected[modality]:
                raise GeneratedMediaFormatConformanceError(
                    "wrong previous modality terminal"
                )
            seen.add(modality)
        expected[modality] = record["record_sha256"]
    return current


def _validate_format_layers(
    transition_value: Record,
    format_value: Record,
) -> None:
    header = transition_value["header"]
    registry_value = transition_value["registry"]
    manifest = registry_value["manifest"]
    batch = format_value["batch"]
    expected_batch_pairs = (
        ("request_epoch", header["request_epoch"]),
        ("registry_generation", header["registry_generation"]),
        ("publication_sequence", header["publication_sequence"]),
        ("record_count", header["receipt_count"]),
        ("record_count", manifest["entry_count"]),
        ("aggregate_raw_output_bytes", header["total_raw_output_bytes"]),
        ("aggregate_raw_output_bytes", manifest["total_source_bytes"]),
        (
            "aggregate_encoded_payload_bytes",
            header["total_encoded_payload_bytes"],
        ),
        (
            "aggregate_encoded_payload_bytes",
            manifest["total_encoded_bytes"],
        ),
        ("modality_mask", header["modality_mask"]),
        ("modality_mask", manifest["modality_mask"]),
        ("generation_plan_sha256", header["generation_plan_sha256"]),
        ("generation_plan_sha256", manifest["generation_plan_sha256"]),
        ("tenant_scope_sha256", header["tenant_scope_sha256"]),
        ("tenant_scope_sha256", manifest["tenant_scope_sha256"]),
        ("metadata_policy_sha256", header["metadata_policy_sha256"]),
        ("metadata_policy_sha256", manifest["metadata_policy_sha256"]),
        ("challenge_sha256", header["challenge_sha256"]),
        ("challenge_sha256", manifest["challenge_sha256"]),
        ("transition_batch_sha256", header["batch_sha256"]),
        ("registry_manifest_sha256", manifest["manifest_sha256"]),
        ("registry_archive_sha256", registry_value["archive_sha256"]),
    )
    if any(batch[field] != expected for field, expected in expected_batch_pairs):
        raise GeneratedMediaFormatConformanceError(
            "format batch is foreign to transition pair"
        )

    records = format_value["records"]
    receipts = transition_value["receipts"]
    entries = registry_value["entries"]
    payloads = registry_value["payloads"]
    if not (len(records) == len(receipts) == len(entries) == len(payloads)):
        raise GeneratedMediaFormatConformanceError("format record count disagrees")
    for record, receipt, entry, payload in zip(
        records,
        receipts,
        entries,
        payloads,
    ):
        producer = decode_producer_wire(
            record["modality"],
            record["producer_wire"],
        )
        inspection = _inspect_payload(record["modality"], payload)
        _validate_profile_binding(record["modality"], producer, inspection)
        _validate_producer_receipt_binding(
            record["modality"],
            producer,
            receipt,
        )
        raw = _immutable_bytes(inspection["raw"], "inspected raw output")
        encoded_sha256 = hashlib.sha256(payload).digest()
        expected_record_pairs = (
            ("modality", receipt["modality"]),
            ("modality", entry["modality"]),
            ("registry_ordinal", receipt["registry_ordinal"]),
            ("registry_ordinal", entry["ordinal"]),
            ("encoding_abi", entry["encoding_abi"]),
            ("raw_output_bytes", receipt["raw_output_bytes"]),
            ("raw_output_bytes", entry["source_bytes"]),
            ("raw_output_bytes", len(raw)),
            ("encoded_payload_bytes", receipt["encoded_payload_bytes"]),
            ("encoded_payload_bytes", entry["payload_bytes"]),
            ("encoded_payload_bytes", len(payload)),
            (
                "producer_plan_or_manifest_sha256",
                receipt["producer_plan_or_manifest_sha256"],
            ),
            ("raw_output_sha256", receipt["raw_output_sha256"]),
            ("raw_output_sha256", entry["source_output_sha256"]),
            ("raw_output_sha256", hashlib.sha256(raw).digest()),
            ("encoded_payload_sha256", receipt["encoded_payload_sha256"]),
            ("encoded_payload_sha256", encoded_sha256),
            ("registry_payload_sha256", entry["payload_sha256"]),
            (
                "encoder_implementation_sha256",
                receipt["encoder_implementation_sha256"],
            ),
            (
                "encoder_implementation_sha256",
                entry["encoder_implementation_sha256"],
            ),
            ("format_contract_sha256", receipt["format_sha256"]),
            ("format_contract_sha256", entry["format_sha256"]),
            (
                "transition_receipt_sha256",
                receipt["transition_receipt_sha256"],
            ),
            ("registry_entry_sha256", entry["entry_sha256"]),
        )
        if any(record[field] != expected for field, expected in expected_record_pairs):
            raise GeneratedMediaFormatConformanceError(
                "format record is foreign to transition pair"
            )


def _canonical_transition_value(value: Record) -> Record:
    """Rebuild a retained transition chain from its canonical wire bytes."""

    chain: list[Record] = []
    seen: set[int] = set()
    cursor: Record | None = value
    while cursor is not None:
        if type(cursor) is not dict or id(cursor) in seen:
            raise GeneratedMediaFormatConformanceError("invalid decoded transition")
        seen.add(id(cursor))
        chain.append(cursor)
        try:
            cursor = cursor["previous"]
        except KeyError as error:
            raise GeneratedMediaFormatConformanceError(
                "invalid decoded transition"
            ) from error

    canonical_previous: Record | None = None
    for retained in reversed(chain):
        try:
            canonical = transition.decode_batch(
                retained["evidence_bytes"],
                retained["registry"]["archive_bytes"],
                canonical_previous,
            )
        except (
            KeyError,
            TypeError,
            registry.GeneratedMediaOutputRegistryError,
            transition.GeneratedMediaProducerTransitionError,
        ) as error:
            raise GeneratedMediaFormatConformanceError(
                "invalid decoded transition"
            ) from error
        if canonical != retained:
            raise GeneratedMediaFormatConformanceError(
                "non-canonical decoded transition"
            )
        canonical_previous = canonical

    if canonical_previous is None:
        raise GeneratedMediaFormatConformanceError("invalid decoded transition")
    return canonical_previous


def validate_transition_and_format_evidence(
    transition_value: Record,
    format_evidence: bytes,
    previous_format_evidence: bytes | None = None,
) -> Record:
    """Bind decoded transition evidence to its exact format sidecar.

    The transition value is decoded again from its retained bytes before any
    cross-layer comparison.  The returned value is the canonical decoded
    format dictionary with ``batch``, ``records``, ``record_table``, and
    ``encoded`` fields.
    """

    try:
        canonical_transition = _canonical_transition_value(transition_value)
        generation = canonical_transition["header"]["registry_generation"]
        if generation == 1:
            if previous_format_evidence is not None:
                raise GeneratedMediaFormatConformanceError(
                    "unexpected format predecessor"
                )
            format_value = decode_format_evidence(format_evidence)
        else:
            if previous_format_evidence is None:
                raise GeneratedMediaFormatConformanceError("missing format predecessor")
            previous_transition = canonical_transition["previous"]
            if previous_transition is None:
                raise GeneratedMediaFormatConformanceError(
                    "missing transition predecessor"
                )
            previous_format_value = decode_format_evidence(previous_format_evidence)
            _validate_format_layers(
                previous_transition,
                previous_format_value,
            )
            format_value = validate_successor_format_evidence(
                format_evidence,
                previous_format_evidence,
            )
        _validate_format_layers(canonical_transition, format_value)
        return format_value
    except GeneratedMediaFormatConformanceError:
        raise
    except (
        KeyError,
        TypeError,
        registry.GeneratedMediaOutputRegistryError,
        transition.GeneratedMediaProducerTransitionError,
    ) as error:
        raise GeneratedMediaFormatConformanceError(
            "invalid archive, transition, or format composition"
        ) from error


def validate_archive_transition_and_format_evidence(
    registry_archive: bytes,
    transition_evidence: bytes,
    format_evidence: bytes,
    previous: Record | None = None,
) -> Record:
    """Validate one exact registry/transition/format generation.

    ``previous`` is the composed dictionary returned by this function for the
    immediately preceding generation.  The result retains canonical decoded
    ``registry``, ``transition``, and ``format`` views for successor checking.
    """

    try:
        if previous is None:
            previous_transition = None
            previous_format_evidence = None
        else:
            if type(previous) is not dict or set(previous) != {
                "registry",
                "transition",
                "format",
            }:
                raise GeneratedMediaFormatConformanceError(
                    "invalid composed predecessor"
                )
            previous_transition = previous["transition"]
            previous_format = previous["format"]
            canonical_previous_transition = _canonical_transition_value(
                previous_transition
            )
            canonical_previous_format = decode_format_evidence(
                previous_format["encoded"]
            )
            if (
                canonical_previous_transition != previous_transition
                or previous["registry"] != previous_transition["registry"]
                or canonical_previous_format != previous_format
            ):
                raise GeneratedMediaFormatConformanceError(
                    "invalid composed predecessor"
                )
            _validate_format_layers(
                canonical_previous_transition,
                canonical_previous_format,
            )
            previous_transition = canonical_previous_transition
            previous_format_evidence = canonical_previous_format["encoded"]
        decoded_transition = transition.decode_batch(
            _immutable_bytes(
                transition_evidence,
                "transition evidence",
            ),
            _immutable_bytes(registry_archive, "registry archive"),
            previous_transition,
        )
        decoded_format = validate_transition_and_format_evidence(
            decoded_transition,
            _immutable_bytes(format_evidence, "format evidence"),
            previous_format_evidence,
        )
        return {
            "registry": decoded_transition["registry"],
            "transition": decoded_transition,
            "format": decoded_format,
        }
    except GeneratedMediaFormatConformanceError:
        raise
    except (
        KeyError,
        TypeError,
        registry.GeneratedMediaOutputRegistryError,
        transition.GeneratedMediaProducerTransitionError,
    ) as error:
        raise GeneratedMediaFormatConformanceError(
            "invalid archive, transition, or format composition"
        ) from error
