from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import generated_media_checkpoint as media

Record = dict[str, Any]

ZERO = bytes(32)
U64_MAX = (1 << 64) - 1

MANIFEST_ABI = 1
MANIFEST_BODY_BYTES = 832
MANIFEST_BYTES = MANIFEST_BODY_BYTES + 32
MANIFEST_MAGIC = b"GLGMPAY1"
MANIFEST_DOMAIN = b"glacier.generated-media-payload-manifest.v1"
PAYLOAD_DOMAIN = b"glacier.generated-media-encoded-payload.v1"
REFERENCE_IDENTITY_DOMAIN = b"glacier.generated-media-payload-reference-identity.v1"

MANIFEST_OBJECT_ORDINAL = 1
CHECKPOINT_OBJECT_ORDINAL = 2
IMAGE_MEMBER_OBJECT_ORDINAL = 3
AUDIO_MEMBER_OBJECT_ORDINAL = 4
VIDEO_MEMBER_OBJECT_ORDINAL = 5
IMAGE_PAYLOAD_OBJECT_ORDINAL = 6
AUDIO_PAYLOAD_OBJECT_ORDINAL = 7
VIDEO_PAYLOAD_OBJECT_ORDINAL = 8
ARCHIVE_OBJECT_COUNT = 8

SET_ABI = 0x4743_5345_0000_0001
SET_MAGIC = b"GCSET01\x00"
SET_HEADER_BYTES = 128
SET_ENTRY_BYTES = 72
SET_MAX_OBJECTS = 8
SET_PAYLOAD_OFFSET = SET_HEADER_BYTES + SET_ENTRY_BYTES * SET_MAX_OBJECTS
SET_FOOTER_BYTES = 32
SET_DOMAIN = b"glacier-continuation-checkpoint-set-v1\x00"
OBJECT_DOMAIN = b"glacier-continuation-checkpoint-object-v1\x00"
EXTENSION_KIND = 7

MANIFEST_SCALARS = (
    "request_epoch",
    "generation",
    "publication_sequence",
    "payload_count",
    "total_encoded_bytes",
    "image_ordinal",
    "audio_ordinal",
    "video_ordinal",
    "image_encoding_abi",
    "audio_encoding_abi",
    "video_encoding_abi",
    "image_source_bytes",
    "audio_source_bytes",
    "video_source_bytes",
    "image_encoded_bytes",
    "audio_encoded_bytes",
    "video_encoded_bytes",
)

MANIFEST_DIGESTS = (
    "checkpoint_sha256",
    "image_member_sha256",
    "audio_member_sha256",
    "video_member_sha256",
    "image_source_output_sha256",
    "audio_source_output_sha256",
    "video_source_output_sha256",
    "image_payload_sha256",
    "audio_payload_sha256",
    "video_payload_sha256",
    "image_encoder_implementation_sha256",
    "audio_encoder_implementation_sha256",
    "video_encoder_implementation_sha256",
    "image_format_sha256",
    "audio_format_sha256",
    "video_format_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "previous_manifest_sha256",
)


class GeneratedMediaPayloadArchiveError(ValueError):
    pass


def _u64(value: Any) -> int:
    if type(value) is not int or value < 0 or value > U64_MAX:
        raise GeneratedMediaPayloadArchiveError("invalid u64")
    return value


def _digest(value: Any) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise GeneratedMediaPayloadArchiveError("invalid digest")
    return value


def _add(left: int, right: int) -> int:
    value = _u64(left) + _u64(right)
    if value > U64_MAX:
        raise GeneratedMediaPayloadArchiveError("u64 overflow")
    return value


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def _hash_u64(value: int) -> bytes:
    return struct.pack("<Q", _u64(value))


def payload_root(modality: int, encoding_abi: int, payload: bytes) -> bytes:
    if (
        modality
        not in (
            media.IMAGE_MODALITY,
            media.AUDIO_MODALITY,
            media.VIDEO_MODALITY,
        )
        or _u64(encoding_abi) == 0
        or not isinstance(payload, bytes)
        or not payload
    ):
        raise GeneratedMediaPayloadArchiveError("invalid payload")
    return hashlib.sha256(
        PAYLOAD_DOMAIN
        + _hash_u64(modality)
        + _hash_u64(encoding_abi)
        + _hash_u64(len(payload))
        + payload
    ).digest()


def _manifest_body(value: Record) -> bytes:
    body = bytearray(MANIFEST_BODY_BYTES)
    body[0:8] = MANIFEST_MAGIC
    struct.pack_into("<Q", body, 8, MANIFEST_ABI)
    struct.pack_into("<Q", body, 16, MANIFEST_BYTES)
    offset = 32
    for field in MANIFEST_SCALARS:
        struct.pack_into("<Q", body, offset, _u64(value[field]))
        offset += 8
    for field in MANIFEST_DIGESTS:
        body[offset : offset + 32] = _digest(value[field])
        offset += 32
    if offset > MANIFEST_BODY_BYTES:
        raise GeneratedMediaPayloadArchiveError("manifest overflow")
    return bytes(body)


def manifest_root(value: Record) -> bytes:
    return _root(MANIFEST_DOMAIN, _manifest_body(value))


def validate_manifest(value: Record) -> Record:
    expected_fields = {
        *MANIFEST_SCALARS,
        *MANIFEST_DIGESTS,
        "manifest_sha256",
    }
    if not isinstance(value, dict) or set(value) != expected_fields:
        raise GeneratedMediaPayloadArchiveError("invalid manifest fields")
    manifest = dict(value)
    for field in MANIFEST_SCALARS:
        manifest[field] = _u64(manifest[field])
    for field in (*MANIFEST_DIGESTS, "manifest_sha256"):
        manifest[field] = _digest(manifest[field])
    try:
        total_encoded = _add(
            _add(
                manifest["image_encoded_bytes"],
                manifest["audio_encoded_bytes"],
            ),
            manifest["video_encoded_bytes"],
        )
        audio_generation = _add(manifest["audio_ordinal"], 1)
        video_generation = _add(manifest["video_ordinal"], 1)
    except GeneratedMediaPayloadArchiveError as error:
        raise GeneratedMediaPayloadArchiveError(
            "invalid manifest arithmetic"
        ) from error
    if (
        manifest["request_epoch"] == 0
        or manifest["generation"] == 0
        or manifest["publication_sequence"] == 0
        or manifest["payload_count"] != media.REQUIRED_MEMBER_COUNT
        or manifest["total_encoded_bytes"] != total_encoded
        or manifest["image_ordinal"] != manifest["generation"]
        or audio_generation != manifest["generation"]
        or video_generation != manifest["generation"]
        or manifest["image_encoding_abi"] == 0
        or manifest["audio_encoding_abi"] == 0
        or manifest["video_encoding_abi"] == 0
        or manifest["image_source_bytes"] == 0
        or manifest["audio_source_bytes"] == 0
        or manifest["video_source_bytes"] == 0
        or manifest["image_encoded_bytes"] == 0
        or manifest["audio_encoded_bytes"] == 0
        or manifest["video_encoded_bytes"] == 0
        or any(manifest[field] == ZERO for field in MANIFEST_DIGESTS[:-1])
        or (
            manifest["generation"] == 1 and manifest["previous_manifest_sha256"] != ZERO
        )
        or (manifest["generation"] > 1 and manifest["previous_manifest_sha256"] == ZERO)
        or manifest["manifest_sha256"] != manifest_root(manifest)
    ):
        raise GeneratedMediaPayloadArchiveError("invalid manifest")
    return manifest


def encode_manifest(value: Record) -> bytes:
    manifest = validate_manifest(value)
    return _manifest_body(manifest) + manifest["manifest_sha256"]


def decode_manifest(raw: bytes) -> Record:
    if (
        not isinstance(raw, bytes)
        or len(raw) != MANIFEST_BYTES
        or raw[0:8] != MANIFEST_MAGIC
        or struct.unpack_from("<Q", raw, 8)[0] != MANIFEST_ABI
        or struct.unpack_from("<Q", raw, 16)[0] != MANIFEST_BYTES
        or struct.unpack_from("<Q", raw, 24)[0] != 0
        or raw[MANIFEST_BODY_BYTES:]
        != _root(MANIFEST_DOMAIN, raw[:MANIFEST_BODY_BYTES])
    ):
        raise GeneratedMediaPayloadArchiveError("invalid manifest wire")
    value: Record = {}
    offset = 32
    for field in MANIFEST_SCALARS:
        value[field] = struct.unpack_from("<Q", raw, offset)[0]
        offset += 8
    for field in MANIFEST_DIGESTS:
        value[field] = raw[offset : offset + 32]
        offset += 32
    if any(raw[offset:MANIFEST_BODY_BYTES]):
        raise GeneratedMediaPayloadArchiveError("manifest reserved bytes")
    value["manifest_sha256"] = raw[MANIFEST_BODY_BYTES:]
    return validate_manifest(value)


def _validate_payload_input(value: Record) -> Record:
    if not isinstance(value, dict) or set(value) != {
        "encoding_abi",
        "bytes",
        "encoder_implementation_sha256",
        "format_sha256",
    }:
        raise GeneratedMediaPayloadArchiveError("invalid payload input")
    payload = dict(value)
    payload["encoding_abi"] = _u64(payload["encoding_abi"])
    payload["encoder_implementation_sha256"] = _digest(
        payload["encoder_implementation_sha256"]
    )
    payload["format_sha256"] = _digest(payload["format_sha256"])
    if (
        payload["encoding_abi"] == 0
        or not isinstance(payload["bytes"], bytes)
        or not payload["bytes"]
        or payload["encoder_implementation_sha256"] == ZERO
        or payload["format_sha256"] == ZERO
    ):
        raise GeneratedMediaPayloadArchiveError("invalid payload input")
    return payload


def _validate_typed_generation(
    previous: Record | None,
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
) -> tuple[Record, Record, Record, Record]:
    image = media.validate_member(image_value)
    audio = media.validate_member(audio_value)
    video = media.validate_member(video_value)
    previous_checkpoint = None
    if previous is not None:
        previous_archive = validate_decoded_archive(previous)
        previous_checkpoint = previous_archive["checkpoint"]
    expected = media.make_checkpoint(
        previous_checkpoint,
        image,
        audio,
        video,
    )
    checkpoint = media.validate_checkpoint(checkpoint_value)
    if checkpoint != expected:
        raise GeneratedMediaPayloadArchiveError("checkpoint/member mismatch")
    return checkpoint, image, audio, video


def _validate_current_checkpoint_bindings(
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
) -> tuple[Record, Record, Record, Record]:
    checkpoint = media.validate_checkpoint(checkpoint_value)
    image = media.validate_member(image_value)
    audio = media.validate_member(audio_value)
    video = media.validate_member(video_value)
    generation = image["ordinal"]
    if (
        image["modality"] != media.IMAGE_MODALITY
        or audio["modality"] != media.AUDIO_MODALITY
        or video["modality"] != media.VIDEO_MODALITY
        or audio["ordinal"] + 1 != generation
        or video["ordinal"] + 1 != generation
        or image["request_epoch"] != audio["request_epoch"]
        or image["request_epoch"] != video["request_epoch"]
        or image["tenant_scope_sha256"] != audio["tenant_scope_sha256"]
        or image["tenant_scope_sha256"] != video["tenant_scope_sha256"]
        or image["metadata_policy_sha256"] != audio["metadata_policy_sha256"]
        or image["metadata_policy_sha256"] != video["metadata_policy_sha256"]
        or image["challenge_sha256"] != audio["challenge_sha256"]
        or image["challenge_sha256"] != video["challenge_sha256"]
        or (
            generation == 1
            and (
                image["unit_start"] != 0
                or audio["unit_start"] != 0
                or video["unit_start"] != 0
                or video["timeline_start"] != 0
            )
        )
    ):
        raise GeneratedMediaPayloadArchiveError("invalid current generation")
    expected: Record = {
        "request_epoch": image["request_epoch"],
        "generation": generation,
        "publication_sequence": generation,
        "member_count": media.REQUIRED_MEMBER_COUNT,
        "total_bytes": _add(
            _add(image["byte_count"], audio["byte_count"]),
            video["byte_count"],
        ),
        "total_units": _add(
            _add(image["unit_count"], audio["unit_count"]),
            video["unit_count"],
        ),
        "image_ordinal": image["ordinal"],
        "audio_ordinal": audio["ordinal"],
        "video_ordinal": video["ordinal"],
        "image_unit_end": image["unit_end"],
        "audio_unit_end": audio["unit_end"],
        "video_unit_end": video["unit_end"],
        "video_timeline_end": video["timeline_end"],
        "image_bytes": image["byte_count"],
        "audio_bytes": audio["byte_count"],
        "video_bytes": video["byte_count"],
        "image_units": image["unit_count"],
        "audio_units": audio["unit_count"],
        "video_units": video["unit_count"],
        "tenant_scope_sha256": image["tenant_scope_sha256"],
        "metadata_policy_sha256": image["metadata_policy_sha256"],
        "challenge_sha256": image["challenge_sha256"],
        "image_member_sha256": image["member_sha256"],
        "audio_member_sha256": audio["member_sha256"],
        "video_member_sha256": video["member_sha256"],
        "image_result_sha256": image["result_sha256"],
        "audio_result_sha256": audio["result_sha256"],
        "video_result_sha256": video["result_sha256"],
        "image_output_sha256": image["output_sha256"],
        "audio_output_sha256": audio["output_sha256"],
        "video_output_sha256": video["output_sha256"],
        "image_state_sha256": image["state_after_sha256"],
        "audio_state_sha256": audio["state_after_sha256"],
        "video_state_sha256": video["state_after_sha256"],
        "audio_completion_sha256": audio["completion_sha256"],
        "video_completion_sha256": video["completion_sha256"],
        "previous_checkpoint_sha256": checkpoint["previous_checkpoint_sha256"],
        "checkpoint_sha256": checkpoint["checkpoint_sha256"],
    }
    if checkpoint != expected:
        raise GeneratedMediaPayloadArchiveError("checkpoint/member mismatch")
    return checkpoint, image, audio, video


def _make_current_manifest(
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
    image_payload_value: Record,
    audio_payload_value: Record,
    video_payload_value: Record,
    previous_manifest_sha256: bytes,
) -> Record:
    checkpoint, image, audio, video = _validate_current_checkpoint_bindings(
        checkpoint_value,
        image_value,
        audio_value,
        video_value,
    )
    image_payload = _validate_payload_input(image_payload_value)
    audio_payload = _validate_payload_input(audio_payload_value)
    video_payload = _validate_payload_input(video_payload_value)
    values: Record = {
        "request_epoch": checkpoint["request_epoch"],
        "generation": checkpoint["generation"],
        "publication_sequence": checkpoint["publication_sequence"],
        "payload_count": media.REQUIRED_MEMBER_COUNT,
        "total_encoded_bytes": _add(
            _add(
                len(image_payload["bytes"]),
                len(audio_payload["bytes"]),
            ),
            len(video_payload["bytes"]),
        ),
        "image_ordinal": image["ordinal"],
        "audio_ordinal": audio["ordinal"],
        "video_ordinal": video["ordinal"],
        "image_encoding_abi": image_payload["encoding_abi"],
        "audio_encoding_abi": audio_payload["encoding_abi"],
        "video_encoding_abi": video_payload["encoding_abi"],
        "image_source_bytes": image["byte_count"],
        "audio_source_bytes": audio["byte_count"],
        "video_source_bytes": video["byte_count"],
        "image_encoded_bytes": len(image_payload["bytes"]),
        "audio_encoded_bytes": len(audio_payload["bytes"]),
        "video_encoded_bytes": len(video_payload["bytes"]),
        "checkpoint_sha256": checkpoint["checkpoint_sha256"],
        "image_member_sha256": image["member_sha256"],
        "audio_member_sha256": audio["member_sha256"],
        "video_member_sha256": video["member_sha256"],
        "image_source_output_sha256": image["output_sha256"],
        "audio_source_output_sha256": audio["output_sha256"],
        "video_source_output_sha256": video["output_sha256"],
        "image_payload_sha256": payload_root(
            media.IMAGE_MODALITY,
            image_payload["encoding_abi"],
            image_payload["bytes"],
        ),
        "audio_payload_sha256": payload_root(
            media.AUDIO_MODALITY,
            audio_payload["encoding_abi"],
            audio_payload["bytes"],
        ),
        "video_payload_sha256": payload_root(
            media.VIDEO_MODALITY,
            video_payload["encoding_abi"],
            video_payload["bytes"],
        ),
        "image_encoder_implementation_sha256": image_payload[
            "encoder_implementation_sha256"
        ],
        "audio_encoder_implementation_sha256": audio_payload[
            "encoder_implementation_sha256"
        ],
        "video_encoder_implementation_sha256": video_payload[
            "encoder_implementation_sha256"
        ],
        "image_format_sha256": image_payload["format_sha256"],
        "audio_format_sha256": audio_payload["format_sha256"],
        "video_format_sha256": video_payload["format_sha256"],
        "tenant_scope_sha256": checkpoint["tenant_scope_sha256"],
        "metadata_policy_sha256": checkpoint["metadata_policy_sha256"],
        "challenge_sha256": checkpoint["challenge_sha256"],
        "previous_manifest_sha256": _digest(previous_manifest_sha256),
        "manifest_sha256": ZERO,
    }
    values["manifest_sha256"] = manifest_root(values)
    return validate_manifest(values)


def make_manifest(
    previous: Record | None,
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
    image_payload_value: Record,
    audio_payload_value: Record,
    video_payload_value: Record,
) -> Record:
    return make_manifest_unchecked_root(
        previous,
        checkpoint_value,
        image_value,
        audio_value,
        video_value,
        image_payload_value,
        audio_payload_value,
        video_payload_value,
    )


def validate_manifest_bindings(
    previous: Record | None,
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
    image_payload_value: Record,
    audio_payload_value: Record,
    video_payload_value: Record,
    manifest_value: Record,
) -> Record:
    expected = make_manifest_unchecked_root(
        previous,
        checkpoint_value,
        image_value,
        audio_value,
        video_value,
        image_payload_value,
        audio_payload_value,
        video_payload_value,
    )
    manifest = validate_manifest(manifest_value)
    if manifest != expected:
        raise GeneratedMediaPayloadArchiveError("manifest binding mismatch")
    return manifest


def make_manifest_unchecked_root(
    previous: Record | None,
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
    image_payload_value: Record,
    audio_payload_value: Record,
    video_payload_value: Record,
) -> Record:
    checkpoint, image, audio, video = _validate_typed_generation(
        previous,
        checkpoint_value,
        image_value,
        audio_value,
        video_value,
    )
    return _make_current_manifest(
        checkpoint,
        image,
        audio,
        video,
        image_payload_value,
        audio_payload_value,
        video_payload_value,
        (ZERO if previous is None else previous["manifest"]["manifest_sha256"]),
    )


def _object_root(
    ordinal: int,
    abi_version: int,
    payload: bytes,
) -> bytes:
    return hashlib.sha256(
        OBJECT_DOMAIN
        + _hash_u64(EXTENSION_KIND)
        + _hash_u64(ordinal)
        + _hash_u64(abi_version)
        + _hash_u64(len(payload))
        + payload
    ).digest()


def _encode_set(
    *,
    generation: int,
    request_epoch: int,
    publication_next_sequence: int,
    parent_archive_sha256: bytes,
    challenge_sha256: bytes,
    objects: tuple[tuple[int, int, bytes], ...],
) -> bytes:
    if (
        _u64(generation) == 0
        or _u64(request_epoch) == 0
        or _u64(publication_next_sequence) == 0
        or len(objects) != ARCHIVE_OBJECT_COUNT
        or _digest(challenge_sha256) == ZERO
        or (generation == 1) != (_digest(parent_archive_sha256) == ZERO)
    ):
        raise GeneratedMediaPayloadArchiveError("invalid set metadata")
    payload_bytes = sum(len(payload) for _, _, payload in objects)
    total_bytes = SET_PAYLOAD_OFFSET + payload_bytes + SET_FOOTER_BYTES
    output = bytearray(total_bytes)
    output[0:8] = SET_MAGIC
    struct.pack_into("<Q", output, 8, SET_ABI)
    struct.pack_into("<Q", output, 16, total_bytes)
    struct.pack_into("<Q", output, 24, generation)
    struct.pack_into("<Q", output, 32, request_epoch)
    struct.pack_into("<Q", output, 40, publication_next_sequence)
    struct.pack_into("<Q", output, 48, len(objects))
    struct.pack_into("<Q", output, 56, 0)
    output[64:96] = parent_archive_sha256
    output[96:128] = challenge_sha256
    cursor = SET_PAYLOAD_OFFSET
    previous_ordinal = 0
    for index, (ordinal, abi_version, payload) in enumerate(objects):
        if (
            _u64(ordinal) <= previous_ordinal
            or _u64(abi_version) == 0
            or not isinstance(payload, bytes)
            or not payload
        ):
            raise GeneratedMediaPayloadArchiveError("invalid set object")
        previous_ordinal = ordinal
        entry_offset = SET_HEADER_BYTES + index * SET_ENTRY_BYTES
        struct.pack_into("<Q", output, entry_offset, EXTENSION_KIND)
        struct.pack_into("<Q", output, entry_offset + 8, ordinal)
        struct.pack_into("<Q", output, entry_offset + 16, abi_version)
        struct.pack_into("<Q", output, entry_offset + 24, cursor)
        struct.pack_into("<Q", output, entry_offset + 32, len(payload))
        output[entry_offset + 40 : entry_offset + 72] = _object_root(
            ordinal,
            abi_version,
            payload,
        )
        output[cursor : cursor + len(payload)] = payload
        cursor += len(payload)
    if cursor != total_bytes - SET_FOOTER_BYTES:
        raise GeneratedMediaPayloadArchiveError("invalid set length")
    output[-SET_FOOTER_BYTES:] = _root(
        SET_DOMAIN,
        bytes(output[:-SET_FOOTER_BYTES]),
    )
    return bytes(output)


def _decode_set(raw: bytes) -> Record:
    if (
        not isinstance(raw, bytes)
        or len(raw) < SET_PAYLOAD_OFFSET + SET_FOOTER_BYTES
        or raw[0:8] != SET_MAGIC
        or struct.unpack_from("<Q", raw, 8)[0] != SET_ABI
        or struct.unpack_from("<Q", raw, 16)[0] != len(raw)
        or struct.unpack_from("<Q", raw, 48)[0] != ARCHIVE_OBJECT_COUNT
        or struct.unpack_from("<Q", raw, 56)[0] != 0
        or any(raw[128 + ARCHIVE_OBJECT_COUNT * SET_ENTRY_BYTES : SET_PAYLOAD_OFFSET])
        or raw[-SET_FOOTER_BYTES:] != _root(SET_DOMAIN, raw[:-SET_FOOTER_BYTES])
    ):
        raise GeneratedMediaPayloadArchiveError("invalid set")
    generation = struct.unpack_from("<Q", raw, 24)[0]
    request_epoch = struct.unpack_from("<Q", raw, 32)[0]
    publication_next_sequence = struct.unpack_from("<Q", raw, 40)[0]
    parent = raw[64:96]
    challenge = raw[96:128]
    if (
        generation == 0
        or request_epoch == 0
        or publication_next_sequence == 0
        or challenge == ZERO
        or (generation == 1) != (parent == ZERO)
    ):
        raise GeneratedMediaPayloadArchiveError("invalid set metadata")
    objects: dict[int, Record] = {}
    cursor = SET_PAYLOAD_OFFSET
    for index in range(ARCHIVE_OBJECT_COUNT):
        offset = SET_HEADER_BYTES + index * SET_ENTRY_BYTES
        kind, ordinal, abi_version, payload_offset, payload_bytes = struct.unpack_from(
            "<QQQQQ", raw, offset
        )
        object_sha256 = raw[offset + 40 : offset + 72]
        end = payload_offset + payload_bytes
        if (
            kind != EXTENSION_KIND
            or ordinal != index + 1
            or abi_version == 0
            or payload_offset != cursor
            or payload_bytes == 0
            or end > len(raw) - SET_FOOTER_BYTES
        ):
            raise GeneratedMediaPayloadArchiveError("invalid set object")
        payload = raw[payload_offset:end]
        if object_sha256 != _object_root(ordinal, abi_version, payload):
            raise GeneratedMediaPayloadArchiveError("invalid object root")
        objects[ordinal] = {
            "abi_version": abi_version,
            "bytes": payload,
            "object_sha256": object_sha256,
        }
        cursor = end
    if cursor != len(raw) - SET_FOOTER_BYTES:
        raise GeneratedMediaPayloadArchiveError("invalid payload tail")
    return {
        "generation": generation,
        "request_epoch": request_epoch,
        "publication_next_sequence": publication_next_sequence,
        "parent_archive_sha256": parent,
        "challenge_sha256": challenge,
        "archive_sha256": raw[-SET_FOOTER_BYTES:],
        "objects": objects,
    }


def encode_archive(
    previous: Record | None,
    checkpoint_value: Record,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
    image_payload_value: Record,
    audio_payload_value: Record,
    video_payload_value: Record,
) -> Record:
    manifest = make_manifest(
        previous,
        checkpoint_value,
        image_value,
        audio_value,
        video_value,
        image_payload_value,
        audio_payload_value,
        video_payload_value,
    )
    image_payload = _validate_payload_input(image_payload_value)
    audio_payload = _validate_payload_input(audio_payload_value)
    video_payload = _validate_payload_input(video_payload_value)
    objects = (
        (MANIFEST_OBJECT_ORDINAL, MANIFEST_ABI, encode_manifest(manifest)),
        (
            CHECKPOINT_OBJECT_ORDINAL,
            media.CHECKPOINT_ABI,
            media.encode_checkpoint(checkpoint_value),
        ),
        (
            IMAGE_MEMBER_OBJECT_ORDINAL,
            media.MEMBER_ABI,
            media.encode_member(image_value),
        ),
        (
            AUDIO_MEMBER_OBJECT_ORDINAL,
            media.MEMBER_ABI,
            media.encode_member(audio_value),
        ),
        (
            VIDEO_MEMBER_OBJECT_ORDINAL,
            media.MEMBER_ABI,
            media.encode_member(video_value),
        ),
        (
            IMAGE_PAYLOAD_OBJECT_ORDINAL,
            image_payload["encoding_abi"],
            image_payload["bytes"],
        ),
        (
            AUDIO_PAYLOAD_OBJECT_ORDINAL,
            audio_payload["encoding_abi"],
            audio_payload["bytes"],
        ),
        (
            VIDEO_PAYLOAD_OBJECT_ORDINAL,
            video_payload["encoding_abi"],
            video_payload["bytes"],
        ),
    )
    checkpoint = media.validate_checkpoint(checkpoint_value)
    archive = _encode_set(
        generation=checkpoint["generation"],
        request_epoch=checkpoint["request_epoch"],
        publication_next_sequence=_add(
            checkpoint["publication_sequence"],
            1,
        ),
        parent_archive_sha256=(
            ZERO if previous is None else previous["archive_sha256"]
        ),
        challenge_sha256=checkpoint["challenge_sha256"],
        objects=objects,
    )
    return decode_archive(archive, previous)


def decode_archive(raw: bytes, previous: Record | None) -> Record:
    set_value = _decode_set(raw)
    objects = set_value["objects"]
    if (
        objects[MANIFEST_OBJECT_ORDINAL]["abi_version"] != MANIFEST_ABI
        or objects[CHECKPOINT_OBJECT_ORDINAL]["abi_version"] != media.CHECKPOINT_ABI
        or objects[IMAGE_MEMBER_OBJECT_ORDINAL]["abi_version"] != media.MEMBER_ABI
        or objects[AUDIO_MEMBER_OBJECT_ORDINAL]["abi_version"] != media.MEMBER_ABI
        or objects[VIDEO_MEMBER_OBJECT_ORDINAL]["abi_version"] != media.MEMBER_ABI
    ):
        raise GeneratedMediaPayloadArchiveError("invalid object ABI")
    manifest = decode_manifest(objects[MANIFEST_OBJECT_ORDINAL]["bytes"])
    checkpoint = media.decode_checkpoint(objects[CHECKPOINT_OBJECT_ORDINAL]["bytes"])
    image = media.decode_member(objects[IMAGE_MEMBER_OBJECT_ORDINAL]["bytes"])
    audio = media.decode_member(objects[AUDIO_MEMBER_OBJECT_ORDINAL]["bytes"])
    video = media.decode_member(objects[VIDEO_MEMBER_OBJECT_ORDINAL]["bytes"])
    image_payload_bytes = objects[IMAGE_PAYLOAD_OBJECT_ORDINAL]["bytes"]
    audio_payload_bytes = objects[AUDIO_PAYLOAD_OBJECT_ORDINAL]["bytes"]
    video_payload_bytes = objects[VIDEO_PAYLOAD_OBJECT_ORDINAL]["bytes"]
    payloads = (
        {
            "encoding_abi": manifest["image_encoding_abi"],
            "bytes": image_payload_bytes,
            "encoder_implementation_sha256": manifest[
                "image_encoder_implementation_sha256"
            ],
            "format_sha256": manifest["image_format_sha256"],
        },
        {
            "encoding_abi": manifest["audio_encoding_abi"],
            "bytes": audio_payload_bytes,
            "encoder_implementation_sha256": manifest[
                "audio_encoder_implementation_sha256"
            ],
            "format_sha256": manifest["audio_format_sha256"],
        },
        {
            "encoding_abi": manifest["video_encoding_abi"],
            "bytes": video_payload_bytes,
            "encoder_implementation_sha256": manifest[
                "video_encoder_implementation_sha256"
            ],
            "format_sha256": manifest["video_format_sha256"],
        },
    )
    if (
        objects[IMAGE_PAYLOAD_OBJECT_ORDINAL]["abi_version"]
        != manifest["image_encoding_abi"]
        or objects[AUDIO_PAYLOAD_OBJECT_ORDINAL]["abi_version"]
        != manifest["audio_encoding_abi"]
        or objects[VIDEO_PAYLOAD_OBJECT_ORDINAL]["abi_version"]
        != manifest["video_encoding_abi"]
        or len(image_payload_bytes) != manifest["image_encoded_bytes"]
        or len(audio_payload_bytes) != manifest["audio_encoded_bytes"]
        or len(video_payload_bytes) != manifest["video_encoded_bytes"]
    ):
        raise GeneratedMediaPayloadArchiveError("payload object mismatch")
    decoded: Record = {
        "archive_sha256": set_value["archive_sha256"],
        "archive_bytes": raw,
        "manifest": manifest,
        "checkpoint": checkpoint,
        "image_member": image,
        "audio_member": audio,
        "video_member": video,
        "image_payload": image_payload_bytes,
        "audio_payload": audio_payload_bytes,
        "video_payload": video_payload_bytes,
    }
    validate_manifest_bindings(
        previous,
        checkpoint,
        image,
        audio,
        video,
        payloads[0],
        payloads[1],
        payloads[2],
        manifest,
    )
    expected_parent = ZERO if previous is None else previous["archive_sha256"]
    if (
        set_value["generation"] != manifest["generation"]
        or set_value["request_epoch"] != manifest["request_epoch"]
        or set_value["publication_next_sequence"]
        != _add(manifest["publication_sequence"], 1)
        or set_value["parent_archive_sha256"] != expected_parent
        or set_value["challenge_sha256"] != manifest["challenge_sha256"]
    ):
        raise GeneratedMediaPayloadArchiveError("archive metadata mismatch")
    return decoded


def validate_decoded_archive(value: Record) -> Record:
    expected_fields = {
        "archive_sha256",
        "archive_bytes",
        "manifest",
        "checkpoint",
        "image_member",
        "audio_member",
        "video_member",
        "image_payload",
        "audio_payload",
        "video_payload",
    }
    if not isinstance(value, dict) or set(value) != expected_fields:
        raise GeneratedMediaPayloadArchiveError("invalid decoded archive")
    raw = value["archive_bytes"]
    if not isinstance(raw, bytes):
        raise GeneratedMediaPayloadArchiveError("invalid decoded archive")
    set_value = _decode_set(raw)
    objects = set_value["objects"]
    manifest = decode_manifest(objects[MANIFEST_OBJECT_ORDINAL]["bytes"])
    checkpoint = media.decode_checkpoint(objects[CHECKPOINT_OBJECT_ORDINAL]["bytes"])
    image = media.decode_member(objects[IMAGE_MEMBER_OBJECT_ORDINAL]["bytes"])
    audio = media.decode_member(objects[AUDIO_MEMBER_OBJECT_ORDINAL]["bytes"])
    video = media.decode_member(objects[VIDEO_MEMBER_OBJECT_ORDINAL]["bytes"])
    image_payload = objects[IMAGE_PAYLOAD_OBJECT_ORDINAL]["bytes"]
    audio_payload = objects[AUDIO_PAYLOAD_OBJECT_ORDINAL]["bytes"]
    video_payload = objects[VIDEO_PAYLOAD_OBJECT_ORDINAL]["bytes"]
    if (
        _digest(value["archive_sha256"]) != set_value["archive_sha256"]
        or value["manifest"] != manifest
        or value["checkpoint"] != checkpoint
        or value["image_member"] != image
        or value["audio_member"] != audio
        or value["video_member"] != video
        or value["image_payload"] != image_payload
        or value["audio_payload"] != audio_payload
        or value["video_payload"] != video_payload
        or objects[MANIFEST_OBJECT_ORDINAL]["abi_version"] != MANIFEST_ABI
        or objects[CHECKPOINT_OBJECT_ORDINAL]["abi_version"] != media.CHECKPOINT_ABI
        or objects[IMAGE_MEMBER_OBJECT_ORDINAL]["abi_version"] != media.MEMBER_ABI
        or objects[AUDIO_MEMBER_OBJECT_ORDINAL]["abi_version"] != media.MEMBER_ABI
        or objects[VIDEO_MEMBER_OBJECT_ORDINAL]["abi_version"] != media.MEMBER_ABI
        or objects[IMAGE_PAYLOAD_OBJECT_ORDINAL]["abi_version"]
        != manifest["image_encoding_abi"]
        or objects[AUDIO_PAYLOAD_OBJECT_ORDINAL]["abi_version"]
        != manifest["audio_encoding_abi"]
        or objects[VIDEO_PAYLOAD_OBJECT_ORDINAL]["abi_version"]
        != manifest["video_encoding_abi"]
        or set_value["generation"] != manifest["generation"]
        or set_value["request_epoch"] != manifest["request_epoch"]
        or set_value["publication_next_sequence"]
        != _add(manifest["publication_sequence"], 1)
        or set_value["challenge_sha256"] != manifest["challenge_sha256"]
    ):
        raise GeneratedMediaPayloadArchiveError("invalid decoded archive")
    expected_manifest = _make_current_manifest(
        checkpoint,
        image,
        audio,
        video,
        {
            "encoding_abi": objects[IMAGE_PAYLOAD_OBJECT_ORDINAL]["abi_version"],
            "bytes": image_payload,
            "encoder_implementation_sha256": manifest[
                "image_encoder_implementation_sha256"
            ],
            "format_sha256": manifest["image_format_sha256"],
        },
        {
            "encoding_abi": objects[AUDIO_PAYLOAD_OBJECT_ORDINAL]["abi_version"],
            "bytes": audio_payload,
            "encoder_implementation_sha256": manifest[
                "audio_encoder_implementation_sha256"
            ],
            "format_sha256": manifest["audio_format_sha256"],
        },
        {
            "encoding_abi": objects[VIDEO_PAYLOAD_OBJECT_ORDINAL]["abi_version"],
            "bytes": video_payload,
            "encoder_implementation_sha256": manifest[
                "video_encoder_implementation_sha256"
            ],
            "format_sha256": manifest["video_format_sha256"],
        },
        manifest["previous_manifest_sha256"],
    )
    if manifest != expected_manifest:
        raise GeneratedMediaPayloadArchiveError("invalid decoded archive bindings")
    return value


def _reference_identity_root(label: bytes) -> bytes:
    return _root(REFERENCE_IDENTITY_DOMAIN, label)


def reference_archives() -> dict[str, Record]:
    fixture = media.reference_fixture()
    image_encoder = _reference_identity_root(b"image-encoder-v1")
    audio_encoder = _reference_identity_root(b"audio-encoder-v1")
    video_encoder = _reference_identity_root(b"video-encoder-v1")
    image_format = _reference_identity_root(b"image-format-v1")
    audio_format = _reference_identity_root(b"audio-format-v1")
    video_format = _reference_identity_root(b"video-format-v1")
    first = encode_archive(
        None,
        fixture["checkpoint1"],
        fixture["image1"],
        fixture["audio1"],
        fixture["video1"],
        {
            "encoding_abi": 1,
            "bytes": b"image-envelope-generation-one",
            "encoder_implementation_sha256": image_encoder,
            "format_sha256": image_format,
        },
        {
            "encoding_abi": 2,
            "bytes": b"audio-envelope-generation-one",
            "encoder_implementation_sha256": audio_encoder,
            "format_sha256": audio_format,
        },
        {
            "encoding_abi": 3,
            "bytes": b"video-envelope-generation-one",
            "encoder_implementation_sha256": video_encoder,
            "format_sha256": video_format,
        },
    )
    second = encode_archive(
        first,
        fixture["checkpoint2"],
        fixture["image2"],
        fixture["audio2"],
        fixture["video2"],
        {
            "encoding_abi": 1,
            "bytes": b"image-envelope-generation-two",
            "encoder_implementation_sha256": image_encoder,
            "format_sha256": image_format,
        },
        {
            "encoding_abi": 2,
            "bytes": b"audio-envelope-generation-two",
            "encoder_implementation_sha256": audio_encoder,
            "format_sha256": audio_format,
        },
        {
            "encoding_abi": 3,
            "bytes": b"video-envelope-generation-two",
            "encoder_implementation_sha256": video_encoder,
            "format_sha256": video_format,
        },
    )
    return {"first": first, "second": second}
