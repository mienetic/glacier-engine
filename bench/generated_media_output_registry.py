"""Independent oracle for the generated-media output registry archive."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

Record = dict[str, Any]

ZERO = bytes(32)
U64_MAX = (1 << 64) - 1

IMAGE_MODALITY = 1
AUDIO_MODALITY = 2
VIDEO_MODALITY = 3
MODALITIES = (IMAGE_MODALITY, AUDIO_MODALITY, VIDEO_MODALITY)
MODALITY_BITS = {
    IMAGE_MODALITY: 1,
    AUDIO_MODALITY: 2,
    VIDEO_MODALITY: 4,
}
MAX_ENTRIES_PER_MODALITY = 4
MAX_ENTRIES = 12

ENTRY_ABI = 1
ENTRY_BODY_BYTES = 512
ENTRY_BYTES = ENTRY_BODY_BYTES + 32
ENTRY_MAGIC = b"GLGMOUT1"
ENTRY_DOMAIN = b"glacier.generated-media-output-registry-entry.v1"

MANIFEST_ABI = 1
MANIFEST_BODY_BYTES = 512
MANIFEST_BYTES = MANIFEST_BODY_BYTES + 32
MANIFEST_MAGIC = b"GLGMREG1"
MANIFEST_DOMAIN = b"glacier.generated-media-output-registry-manifest.v1"

ENTRY_TABLE_ABI = 1
PAYLOAD_PACK_ABI = 1
ENTRY_TABLE_DOMAIN = b"glacier.generated-media-output-registry-entry-table.v1"
PAYLOAD_PACK_DOMAIN = b"glacier.generated-media-output-registry-payload-pack.v1"
PAYLOAD_DOMAIN = b"glacier.generated-media-output-registry-payload.v1"
REFERENCE_IDENTITY_DOMAIN = (
    b"glacier.generated-media-output-registry-reference-identity.v1"
)

MANIFEST_OBJECT_ORDINAL = 1
ENTRY_TABLE_OBJECT_ORDINAL = 2
PAYLOAD_PACK_OBJECT_ORDINAL = 3
ARCHIVE_OBJECT_COUNT = 3

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

ENTRY_SCALARS = (
    "modality",
    "ordinal",
    "unit_start",
    "unit_count",
    "unit_end",
    "timeline_start",
    "timeline_end",
    "source_bytes",
    "encoding_abi",
    "payload_offset",
    "payload_bytes",
    "completion_required",
    "completed",
)

ENTRY_DIGESTS = (
    "artifact_sha256",
    "provenance_sha256",
    "result_sha256",
    "source_output_sha256",
    "media_object_sha256",
    "state_after_sha256",
    "completion_sha256",
    "encoder_implementation_sha256",
    "format_sha256",
    "previous_entry_sha256",
    "payload_sha256",
)

ENTRY_NONZERO_DIGESTS = (
    "artifact_sha256",
    "provenance_sha256",
    "result_sha256",
    "source_output_sha256",
    "media_object_sha256",
    "state_after_sha256",
    "encoder_implementation_sha256",
    "format_sha256",
    "payload_sha256",
)

ENTRY_FIELDS = {
    *ENTRY_SCALARS,
    *ENTRY_DIGESTS,
    "entry_sha256",
}

ENTRY_INPUT_FIELDS = {
    "modality",
    "ordinal",
    "unit_start",
    "unit_count",
    "timeline_start",
    "timeline_end",
    "source_bytes",
    "encoding_abi",
    "completion_required",
    "completed",
    "artifact_sha256",
    "provenance_sha256",
    "result_sha256",
    "source_output_sha256",
    "media_object_sha256",
    "state_after_sha256",
    "completion_sha256",
    "encoder_implementation_sha256",
    "format_sha256",
    "payload",
}

MANIFEST_SCALARS = (
    "request_epoch",
    "generation",
    "publication_sequence",
    "entry_count",
    "entry_table_bytes",
    "payload_pack_bytes",
    "total_source_bytes",
    "total_encoded_bytes",
    "total_units",
    "image_count",
    "audio_count",
    "video_count",
    "image_units",
    "audio_units",
    "video_units",
    "image_encoded_bytes",
    "audio_encoded_bytes",
    "video_encoded_bytes",
    "image_unit_end",
    "audio_unit_end",
    "video_unit_end",
    "image_timeline_end",
    "audio_timeline_end",
    "video_timeline_end",
    "modality_mask",
)

MANIFEST_DIGESTS = (
    "entry_table_sha256",
    "payload_pack_sha256",
    "generation_plan_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "previous_manifest_sha256",
    "previous_archive_sha256",
)

MANIFEST_FIELDS = {
    *MANIFEST_SCALARS,
    *MANIFEST_DIGESTS,
    "manifest_sha256",
}

METADATA_FIELDS = {
    "request_epoch",
    "generation",
    "publication_sequence",
    "generation_plan_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
}

ARCHIVE_FIELDS = {
    "archive_sha256",
    "archive_bytes",
    "manifest",
    "entries",
    "payloads",
    "entry_table",
    "payload_pack",
}


class GeneratedMediaOutputRegistryError(ValueError):
    """The registry value or archive is not canonical."""


def _u64(value: Any) -> int:
    if type(value) is not int or value < 0 or value > U64_MAX:
        raise GeneratedMediaOutputRegistryError("invalid u64")
    return value


def _digest(value: Any) -> bytes:
    if type(value) is not bytes or len(value) != 32:
        raise GeneratedMediaOutputRegistryError("invalid digest")
    return value


def _add(left: int, right: int) -> int:
    value = _u64(left) + _u64(right)
    if value > U64_MAX:
        raise GeneratedMediaOutputRegistryError("u64 overflow")
    return value


def _sum(values: list[int] | tuple[int, ...]) -> int:
    total = 0
    for value in values:
        total = _add(total, value)
    return total


def _u64_bytes(value: int) -> bytes:
    return struct.pack("<Q", _u64(value))


def _length_root(domain: bytes, body: bytes) -> bytes:
    if type(body) is not bytes:
        raise GeneratedMediaOutputRegistryError("invalid root body")
    return hashlib.sha256(domain + _u64_bytes(len(body)) + body).digest()


def reference_identity_root(label: bytes) -> bytes:
    if type(label) is not bytes or not label:
        raise GeneratedMediaOutputRegistryError("invalid identity label")
    return _length_root(REFERENCE_IDENTITY_DOMAIN, label)


def payload_root(
    modality: int,
    ordinal: int,
    encoding_abi: int,
    source_output_sha256: bytes,
    payload: bytes,
) -> bytes:
    if (
        _u64(modality) not in MODALITIES
        or _u64(encoding_abi) == 0
        or type(payload) is not bytes
        or not payload
    ):
        raise GeneratedMediaOutputRegistryError("invalid payload")
    return hashlib.sha256(
        PAYLOAD_DOMAIN
        + _u64_bytes(modality)
        + _u64_bytes(ordinal)
        + _u64_bytes(encoding_abi)
        + _u64_bytes(len(payload))
        + _digest(source_output_sha256)
        + payload
    ).digest()


def entry_table_root(entry_count: int, entry_table: bytes) -> bytes:
    if (
        _u64(entry_count) == 0
        or type(entry_table) is not bytes
        or len(entry_table) != entry_count * ENTRY_BYTES
    ):
        raise GeneratedMediaOutputRegistryError("invalid entry table")
    return hashlib.sha256(
        ENTRY_TABLE_DOMAIN
        + _u64_bytes(entry_count)
        + _u64_bytes(len(entry_table))
        + entry_table
    ).digest()


def payload_pack_root(payload_pack: bytes) -> bytes:
    if type(payload_pack) is not bytes or not payload_pack:
        raise GeneratedMediaOutputRegistryError("invalid payload pack")
    return _length_root(PAYLOAD_PACK_DOMAIN, payload_pack)


def _entry_body(value: Record) -> bytes:
    if type(value) is not dict or set(value) != ENTRY_FIELDS:
        raise GeneratedMediaOutputRegistryError("invalid entry fields")
    body = bytearray(ENTRY_BODY_BYTES)
    body[0:8] = ENTRY_MAGIC
    struct.pack_into("<Q", body, 8, ENTRY_ABI)
    struct.pack_into("<Q", body, 16, ENTRY_BYTES)
    offset = 24
    for field in ENTRY_SCALARS:
        scalar = value[field]
        if field in ("completion_required", "completed"):
            if type(scalar) is not bool:
                raise GeneratedMediaOutputRegistryError("invalid entry flag")
            scalar = int(scalar)
        struct.pack_into("<Q", body, offset, _u64(scalar))
        offset += 8
    for field in ENTRY_DIGESTS:
        body[offset : offset + 32] = _digest(value[field])
        offset += 32
    if offset != 480:
        raise GeneratedMediaOutputRegistryError("entry layout mismatch")
    return bytes(body)


def entry_root(value: Record) -> bytes:
    return _length_root(ENTRY_DOMAIN, _entry_body(value))


def validate_entry(value: Record) -> Record:
    if type(value) is not dict or set(value) != ENTRY_FIELDS:
        raise GeneratedMediaOutputRegistryError("invalid entry fields")
    entry = dict(value)
    for field in ENTRY_SCALARS:
        if field in ("completion_required", "completed"):
            if type(entry[field]) is not bool:
                raise GeneratedMediaOutputRegistryError("invalid entry flag")
        else:
            entry[field] = _u64(entry[field])
    for field in (*ENTRY_DIGESTS, "entry_sha256"):
        entry[field] = _digest(entry[field])
    try:
        expected_unit_end = _add(entry["unit_start"], entry["unit_count"])
    except GeneratedMediaOutputRegistryError as error:
        raise GeneratedMediaOutputRegistryError("invalid entry arithmetic") from error
    completion_valid = (
        not entry["completion_required"]
        and entry["completed"]
        and entry["completion_sha256"] == ZERO
        if entry["modality"] == IMAGE_MODALITY
        else entry["completion_required"]
        and entry["completed"]
        and entry["completion_sha256"] != ZERO
    )
    if (
        entry["modality"] not in MODALITIES
        or entry["unit_count"] == 0
        or entry["unit_end"] != expected_unit_end
        or entry["timeline_end"] <= entry["timeline_start"]
        or entry["source_bytes"] == 0
        or entry["encoding_abi"] == 0
        or entry["payload_bytes"] == 0
        or any(entry[field] == ZERO for field in ENTRY_NONZERO_DIGESTS)
        or not completion_valid
        or entry["entry_sha256"] != entry_root(entry)
    ):
        raise GeneratedMediaOutputRegistryError("invalid entry")
    return entry


def encode_entry(value: Record) -> bytes:
    entry = validate_entry(value)
    return _entry_body(entry) + entry["entry_sha256"]


def decode_entry(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != ENTRY_BYTES
        or raw[0:8] != ENTRY_MAGIC
        or struct.unpack_from("<Q", raw, 8)[0] != ENTRY_ABI
        or struct.unpack_from("<Q", raw, 16)[0] != ENTRY_BYTES
        or any(raw[480:ENTRY_BODY_BYTES])
        or raw[ENTRY_BODY_BYTES:] != _length_root(ENTRY_DOMAIN, raw[:ENTRY_BODY_BYTES])
    ):
        raise GeneratedMediaOutputRegistryError("invalid entry wire")
    value: Record = {}
    offset = 24
    for field in ENTRY_SCALARS:
        scalar = struct.unpack_from("<Q", raw, offset)[0]
        if field in ("completion_required", "completed"):
            if scalar not in (0, 1):
                raise GeneratedMediaOutputRegistryError("invalid entry flag")
            value[field] = bool(scalar)
        else:
            value[field] = scalar
        offset += 8
    for field in ENTRY_DIGESTS:
        value[field] = raw[offset : offset + 32]
        offset += 32
    value["entry_sha256"] = raw[ENTRY_BODY_BYTES:]
    return validate_entry(value)


def _manifest_body(value: Record) -> bytes:
    if type(value) is not dict or set(value) != MANIFEST_FIELDS:
        raise GeneratedMediaOutputRegistryError("invalid manifest fields")
    body = bytearray(MANIFEST_BODY_BYTES)
    body[0:8] = MANIFEST_MAGIC
    struct.pack_into("<Q", body, 8, MANIFEST_ABI)
    struct.pack_into("<Q", body, 16, MANIFEST_BYTES)
    offset = 24
    for field in MANIFEST_SCALARS:
        struct.pack_into("<Q", body, offset, _u64(value[field]))
        offset += 8
    for field in MANIFEST_DIGESTS:
        body[offset : offset + 32] = _digest(value[field])
        offset += 32
    if offset != 480:
        raise GeneratedMediaOutputRegistryError("manifest layout mismatch")
    return bytes(body)


def manifest_root(value: Record) -> bytes:
    return _length_root(MANIFEST_DOMAIN, _manifest_body(value))


def _manifest_modality_values(
    manifest: Record,
    name: str,
) -> tuple[int, int, int]:
    return (
        manifest[f"image_{name}"],
        manifest[f"audio_{name}"],
        manifest[f"video_{name}"],
    )


def validate_manifest(value: Record) -> Record:
    if type(value) is not dict or set(value) != MANIFEST_FIELDS:
        raise GeneratedMediaOutputRegistryError("invalid manifest fields")
    manifest = dict(value)
    for field in MANIFEST_SCALARS:
        manifest[field] = _u64(manifest[field])
    for field in (*MANIFEST_DIGESTS, "manifest_sha256"):
        manifest[field] = _digest(manifest[field])
    counts = _manifest_modality_values(manifest, "count")
    units = _manifest_modality_values(manifest, "units")
    encoded = _manifest_modality_values(manifest, "encoded_bytes")
    unit_ends = _manifest_modality_values(manifest, "unit_end")
    timeline_ends = _manifest_modality_values(manifest, "timeline_end")
    expected_mask = 0
    for index, count in enumerate(counts):
        modality = MODALITIES[index]
        if count:
            expected_mask |= MODALITY_BITS[modality]
    try:
        aggregate_valid = (
            manifest["entry_count"] == _sum(counts)
            and manifest["total_units"] == _sum(units)
            and manifest["total_encoded_bytes"] == _sum(encoded)
        )
    except GeneratedMediaOutputRegistryError as error:
        raise GeneratedMediaOutputRegistryError(
            "invalid manifest arithmetic"
        ) from error
    modality_values_valid = all(
        (
            count == 0
            and unit_count == 0
            and encoded_bytes == 0
            and unit_end == 0
            and timeline_end == 0
        )
        or (
            1 <= count <= MAX_ENTRIES_PER_MODALITY
            and unit_count > 0
            and encoded_bytes > 0
            and unit_end > 0
            and timeline_end > 0
        )
        for count, unit_count, encoded_bytes, unit_end, timeline_end in zip(
            counts,
            units,
            encoded,
            unit_ends,
            timeline_ends,
        )
    )
    initial = manifest["generation"] == 1
    if (
        manifest["request_epoch"] == 0
        or manifest["generation"] == 0
        or manifest["publication_sequence"] == 0
        or not 1 <= manifest["entry_count"] <= MAX_ENTRIES
        or manifest["entry_table_bytes"] != manifest["entry_count"] * ENTRY_BYTES
        or manifest["payload_pack_bytes"] == 0
        or manifest["payload_pack_bytes"] != manifest["total_encoded_bytes"]
        or manifest["total_source_bytes"] == 0
        or not aggregate_valid
        or not modality_values_valid
        or manifest["modality_mask"] != expected_mask
        or any(manifest[field] == ZERO for field in MANIFEST_DIGESTS[:-2])
        or (
            initial
            and (
                manifest["previous_manifest_sha256"] != ZERO
                or manifest["previous_archive_sha256"] != ZERO
            )
        )
        or (
            not initial
            and (
                manifest["previous_manifest_sha256"] == ZERO
                or manifest["previous_archive_sha256"] == ZERO
            )
        )
        or manifest["manifest_sha256"] != manifest_root(manifest)
    ):
        raise GeneratedMediaOutputRegistryError("invalid manifest")
    return manifest


def encode_manifest(value: Record) -> bytes:
    manifest = validate_manifest(value)
    return _manifest_body(manifest) + manifest["manifest_sha256"]


def decode_manifest(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != MANIFEST_BYTES
        or raw[0:8] != MANIFEST_MAGIC
        or struct.unpack_from("<Q", raw, 8)[0] != MANIFEST_ABI
        or struct.unpack_from("<Q", raw, 16)[0] != MANIFEST_BYTES
        or any(raw[480:MANIFEST_BODY_BYTES])
        or raw[MANIFEST_BODY_BYTES:]
        != _length_root(MANIFEST_DOMAIN, raw[:MANIFEST_BODY_BYTES])
    ):
        raise GeneratedMediaOutputRegistryError("invalid manifest wire")
    value: Record = {}
    offset = 24
    for field in MANIFEST_SCALARS:
        value[field] = struct.unpack_from("<Q", raw, offset)[0]
        offset += 8
    for field in MANIFEST_DIGESTS:
        value[field] = raw[offset : offset + 32]
        offset += 32
    value["manifest_sha256"] = raw[MANIFEST_BODY_BYTES:]
    return validate_manifest(value)


def _object_root(
    ordinal: int,
    abi_version: int,
    payload: bytes,
) -> bytes:
    if (
        _u64(ordinal) == 0
        or _u64(abi_version) == 0
        or type(payload) is not bytes
        or not payload
    ):
        raise GeneratedMediaOutputRegistryError("invalid set object")
    return hashlib.sha256(
        OBJECT_DOMAIN
        + _u64_bytes(EXTENSION_KIND)
        + _u64_bytes(ordinal)
        + _u64_bytes(abi_version)
        + _u64_bytes(len(payload))
        + payload
    ).digest()


def _set_root(body: bytes) -> bytes:
    if type(body) is not bytes:
        raise GeneratedMediaOutputRegistryError("invalid set body")
    return hashlib.sha256(SET_DOMAIN + body).digest()


def _encode_set(
    *,
    generation: int,
    request_epoch: int,
    publication_next_sequence: int,
    parent_archive_sha256: bytes,
    challenge_sha256: bytes,
    objects: tuple[tuple[int, int, bytes], ...],
) -> bytes:
    generation = _u64(generation)
    request_epoch = _u64(request_epoch)
    publication_next_sequence = _u64(publication_next_sequence)
    parent = _digest(parent_archive_sha256)
    challenge = _digest(challenge_sha256)
    if (
        generation == 0
        or request_epoch == 0
        or publication_next_sequence == 0
        or challenge == ZERO
        or len(objects) != ARCHIVE_OBJECT_COUNT
        or (generation == 1) != (parent == ZERO)
    ):
        raise GeneratedMediaOutputRegistryError("invalid set metadata")
    payload_bytes = _sum(tuple(len(item[2]) for item in objects))
    total_bytes = _add(
        _add(SET_PAYLOAD_OFFSET, payload_bytes),
        SET_FOOTER_BYTES,
    )
    output = bytearray(total_bytes)
    output[0:8] = SET_MAGIC
    struct.pack_into("<Q", output, 8, SET_ABI)
    struct.pack_into("<Q", output, 16, total_bytes)
    struct.pack_into("<Q", output, 24, generation)
    struct.pack_into("<Q", output, 32, request_epoch)
    struct.pack_into("<Q", output, 40, publication_next_sequence)
    struct.pack_into("<Q", output, 48, ARCHIVE_OBJECT_COUNT)
    struct.pack_into("<Q", output, 56, 0)
    output[64:96] = parent
    output[96:128] = challenge
    cursor = SET_PAYLOAD_OFFSET
    for index, (ordinal, abi_version, payload) in enumerate(objects):
        if ordinal != index + 1:
            raise GeneratedMediaOutputRegistryError("non-canonical set object")
        object_sha256 = _object_root(ordinal, abi_version, payload)
        entry_offset = SET_HEADER_BYTES + index * SET_ENTRY_BYTES
        struct.pack_into("<Q", output, entry_offset, EXTENSION_KIND)
        struct.pack_into("<Q", output, entry_offset + 8, ordinal)
        struct.pack_into("<Q", output, entry_offset + 16, abi_version)
        struct.pack_into("<Q", output, entry_offset + 24, cursor)
        struct.pack_into("<Q", output, entry_offset + 32, len(payload))
        output[entry_offset + 40 : entry_offset + 72] = object_sha256
        end = cursor + len(payload)
        output[cursor:end] = payload
        cursor = end
    if cursor != total_bytes - SET_FOOTER_BYTES:
        raise GeneratedMediaOutputRegistryError("invalid set length")
    output[-SET_FOOTER_BYTES:] = _set_root(bytes(output[:-SET_FOOTER_BYTES]))
    return bytes(output)


def _decode_set(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) < SET_PAYLOAD_OFFSET + SET_FOOTER_BYTES
        or raw[0:8] != SET_MAGIC
        or struct.unpack_from("<Q", raw, 8)[0] != SET_ABI
        or struct.unpack_from("<Q", raw, 16)[0] != len(raw)
        or struct.unpack_from("<Q", raw, 48)[0] != ARCHIVE_OBJECT_COUNT
        or struct.unpack_from("<Q", raw, 56)[0] != 0
        or any(
            raw[
                SET_HEADER_BYTES
                + ARCHIVE_OBJECT_COUNT * SET_ENTRY_BYTES : SET_PAYLOAD_OFFSET
            ]
        )
        or raw[-SET_FOOTER_BYTES:] != _set_root(raw[:-SET_FOOTER_BYTES])
    ):
        raise GeneratedMediaOutputRegistryError("invalid checkpoint set")
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
        raise GeneratedMediaOutputRegistryError("invalid set metadata")
    objects: dict[int, Record] = {}
    cursor = SET_PAYLOAD_OFFSET
    for index in range(ARCHIVE_OBJECT_COUNT):
        offset = SET_HEADER_BYTES + index * SET_ENTRY_BYTES
        kind, ordinal, abi_version, payload_offset, payload_bytes = struct.unpack_from(
            "<QQQQQ", raw, offset
        )
        end = payload_offset + payload_bytes
        if (
            kind != EXTENSION_KIND
            or ordinal != index + 1
            or abi_version == 0
            or payload_offset != cursor
            or payload_bytes == 0
            or end > len(raw) - SET_FOOTER_BYTES
        ):
            raise GeneratedMediaOutputRegistryError("invalid set object")
        payload = raw[payload_offset:end]
        object_sha256 = raw[offset + 40 : offset + 72]
        if object_sha256 != _object_root(ordinal, abi_version, payload):
            raise GeneratedMediaOutputRegistryError("invalid set object root")
        objects[ordinal] = {
            "abi_version": abi_version,
            "bytes": payload,
            "object_sha256": object_sha256,
        }
        cursor = end
    if cursor != len(raw) - SET_FOOTER_BYTES:
        raise GeneratedMediaOutputRegistryError("invalid set payload tail")
    return {
        "generation": generation,
        "request_epoch": request_epoch,
        "publication_next_sequence": publication_next_sequence,
        "parent_archive_sha256": parent,
        "challenge_sha256": challenge,
        "archive_sha256": raw[-SET_FOOTER_BYTES:],
        "objects": objects,
    }


def _validate_metadata(value: Record) -> Record:
    if type(value) is not dict or set(value) != METADATA_FIELDS:
        raise GeneratedMediaOutputRegistryError("invalid metadata fields")
    metadata = dict(value)
    for field in (
        "request_epoch",
        "generation",
        "publication_sequence",
    ):
        metadata[field] = _u64(metadata[field])
        if metadata[field] == 0:
            raise GeneratedMediaOutputRegistryError("invalid metadata")
    for field in (
        "generation_plan_sha256",
        "tenant_scope_sha256",
        "metadata_policy_sha256",
        "challenge_sha256",
    ):
        metadata[field] = _digest(metadata[field])
        if metadata[field] == ZERO:
            raise GeneratedMediaOutputRegistryError("invalid metadata")
    return metadata


def _validate_entry_input(value: Record) -> Record:
    if type(value) is not dict or set(value) != ENTRY_INPUT_FIELDS:
        raise GeneratedMediaOutputRegistryError("invalid entry input fields")
    checked = dict(value)
    for field in (
        "modality",
        "ordinal",
        "unit_start",
        "unit_count",
        "timeline_start",
        "timeline_end",
        "source_bytes",
        "encoding_abi",
    ):
        checked[field] = _u64(checked[field])
    for field in ("completion_required", "completed"):
        if type(checked[field]) is not bool:
            raise GeneratedMediaOutputRegistryError("invalid entry flag")
    for field in ENTRY_DIGESTS[:-2]:
        checked[field] = _digest(checked[field])
    if type(checked["payload"]) is not bytes or not checked["payload"]:
        raise GeneratedMediaOutputRegistryError("invalid entry payload")
    if (
        checked["modality"] not in MODALITIES
        or checked["unit_count"] == 0
        or checked["timeline_end"] <= checked["timeline_start"]
        or checked["source_bytes"] == 0
        or checked["encoding_abi"] == 0
        or any(
            checked[field] == ZERO
            for field in (
                "artifact_sha256",
                "provenance_sha256",
                "result_sha256",
                "source_output_sha256",
                "media_object_sha256",
                "state_after_sha256",
                "encoder_implementation_sha256",
                "format_sha256",
            )
        )
        or (
            checked["modality"] == IMAGE_MODALITY
            and (
                checked["completion_required"]
                or not checked["completed"]
                or checked["completion_sha256"] != ZERO
            )
        )
        or (
            checked["modality"] != IMAGE_MODALITY
            and (
                not checked["completion_required"]
                or not checked["completed"]
                or checked["completion_sha256"] == ZERO
            )
        )
    ):
        raise GeneratedMediaOutputRegistryError("invalid entry input")
    return checked


def _entries_by_modality(entries: list[Record]) -> dict[int, list[Record]]:
    return {
        modality: [entry for entry in entries if entry["modality"] == modality]
        for modality in MODALITIES
    }


def _validate_entry_sequence(
    entries: list[Record],
    generation: int,
    previous_entries: list[Record] | None,
) -> None:
    if type(entries) is not list or not 1 <= len(entries) <= MAX_ENTRIES:
        raise GeneratedMediaOutputRegistryError("invalid entry count")
    pairs = [(entry["modality"], entry["ordinal"]) for entry in entries]
    if pairs != sorted(pairs) or len(set(pairs)) != len(pairs):
        raise GeneratedMediaOutputRegistryError("non-canonical entry order")
    grouped = _entries_by_modality(entries)
    previous_grouped = (
        None if previous_entries is None else _entries_by_modality(previous_entries)
    )
    for modality in MODALITIES:
        current = grouped[modality]
        if len(current) > MAX_ENTRIES_PER_MODALITY:
            raise GeneratedMediaOutputRegistryError("modality entry cap")
        if not current:
            continue
        if generation == 1:
            expected_ordinal = 0
            expected_unit_start = 0
            expected_timeline_start = 0
            expected_previous = ZERO
        elif previous_grouped is None:
            first = current[0]
            if (
                first["ordinal"] == 0
                or first["unit_start"] == 0
                or first["timeline_start"] == 0
                or first["previous_entry_sha256"] == ZERO
            ):
                raise GeneratedMediaOutputRegistryError("missing predecessor state")
            expected_ordinal = first["ordinal"]
            expected_unit_start = first["unit_start"]
            expected_timeline_start = first["timeline_start"]
            expected_previous = first["previous_entry_sha256"]
        else:
            previous_modality = previous_grouped[modality]
            if not previous_modality:
                raise GeneratedMediaOutputRegistryError("missing previous modality")
            terminal = previous_modality[-1]
            expected_ordinal = _add(terminal["ordinal"], 1)
            expected_unit_start = terminal["unit_end"]
            expected_timeline_start = terminal["timeline_end"]
            expected_previous = terminal["entry_sha256"]
        for entry in current:
            if (
                entry["ordinal"] != expected_ordinal
                or entry["unit_start"] != expected_unit_start
                or entry["timeline_start"] != expected_timeline_start
                or entry["previous_entry_sha256"] != expected_previous
            ):
                raise GeneratedMediaOutputRegistryError("invalid entry predecessor")
            expected_ordinal = _add(entry["ordinal"], 1)
            expected_unit_start = entry["unit_end"]
            expected_timeline_start = entry["timeline_end"]
            expected_previous = entry["entry_sha256"]


def _make_manifest(
    metadata: Record,
    entries: list[Record],
    entry_table: bytes,
    payload_pack: bytes,
    previous_manifest_sha256: bytes,
    previous_archive_sha256: bytes,
) -> Record:
    grouped = _entries_by_modality(entries)
    counts = {modality: len(grouped[modality]) for modality in MODALITIES}
    units = {
        modality: _sum(tuple(entry["unit_count"] for entry in grouped[modality]))
        for modality in MODALITIES
    }
    encoded = {
        modality: _sum(tuple(entry["payload_bytes"] for entry in grouped[modality]))
        for modality in MODALITIES
    }
    unit_ends = {
        modality: (grouped[modality][-1]["unit_end"] if grouped[modality] else 0)
        for modality in MODALITIES
    }
    timeline_ends = {
        modality: (grouped[modality][-1]["timeline_end"] if grouped[modality] else 0)
        for modality in MODALITIES
    }
    modality_mask = 0
    for modality in MODALITIES:
        if counts[modality]:
            modality_mask |= MODALITY_BITS[modality]
    manifest: Record = {
        "request_epoch": metadata["request_epoch"],
        "generation": metadata["generation"],
        "publication_sequence": metadata["publication_sequence"],
        "entry_count": len(entries),
        "entry_table_bytes": len(entry_table),
        "payload_pack_bytes": len(payload_pack),
        "total_source_bytes": _sum(tuple(entry["source_bytes"] for entry in entries)),
        "total_encoded_bytes": len(payload_pack),
        "total_units": _sum(tuple(entry["unit_count"] for entry in entries)),
        "image_count": counts[IMAGE_MODALITY],
        "audio_count": counts[AUDIO_MODALITY],
        "video_count": counts[VIDEO_MODALITY],
        "image_units": units[IMAGE_MODALITY],
        "audio_units": units[AUDIO_MODALITY],
        "video_units": units[VIDEO_MODALITY],
        "image_encoded_bytes": encoded[IMAGE_MODALITY],
        "audio_encoded_bytes": encoded[AUDIO_MODALITY],
        "video_encoded_bytes": encoded[VIDEO_MODALITY],
        "image_unit_end": unit_ends[IMAGE_MODALITY],
        "audio_unit_end": unit_ends[AUDIO_MODALITY],
        "video_unit_end": unit_ends[VIDEO_MODALITY],
        "image_timeline_end": timeline_ends[IMAGE_MODALITY],
        "audio_timeline_end": timeline_ends[AUDIO_MODALITY],
        "video_timeline_end": timeline_ends[VIDEO_MODALITY],
        "modality_mask": modality_mask,
        "entry_table_sha256": entry_table_root(
            len(entries),
            entry_table,
        ),
        "payload_pack_sha256": payload_pack_root(payload_pack),
        "generation_plan_sha256": metadata["generation_plan_sha256"],
        "tenant_scope_sha256": metadata["tenant_scope_sha256"],
        "metadata_policy_sha256": metadata["metadata_policy_sha256"],
        "challenge_sha256": metadata["challenge_sha256"],
        "previous_manifest_sha256": _digest(previous_manifest_sha256),
        "previous_archive_sha256": _digest(previous_archive_sha256),
        "manifest_sha256": ZERO,
    }
    manifest["manifest_sha256"] = manifest_root(manifest)
    return validate_manifest(manifest)


def _build_entries(
    inputs: list[Record],
    generation: int,
    previous_entries: list[Record] | None,
) -> tuple[list[Record], list[bytes], bytes]:
    if type(inputs) is not list or not 1 <= len(inputs) <= MAX_ENTRIES:
        raise GeneratedMediaOutputRegistryError("invalid entry inputs")
    checked = [_validate_entry_input(value) for value in inputs]
    pairs = [(value["modality"], value["ordinal"]) for value in checked]
    if pairs != sorted(pairs) or len(set(pairs)) != len(pairs):
        raise GeneratedMediaOutputRegistryError("non-canonical entry order")
    counts = {
        modality: sum(value["modality"] == modality for value in checked)
        for modality in MODALITIES
    }
    if any(count > MAX_ENTRIES_PER_MODALITY for count in counts.values()):
        raise GeneratedMediaOutputRegistryError("modality entry cap")
    previous_grouped = (
        None if previous_entries is None else _entries_by_modality(previous_entries)
    )
    prior_by_modality: dict[int, Record | None] = {}
    for modality in MODALITIES:
        previous_modality = (
            [] if previous_grouped is None else previous_grouped[modality]
        )
        prior_by_modality[modality] = (
            previous_modality[-1] if previous_modality else None
        )
    entries: list[Record] = []
    payloads: list[bytes] = []
    payload_cursor = 0
    for value in checked:
        prior = prior_by_modality[value["modality"]]
        if prior is None:
            expected_ordinal = 0
            expected_unit_start = 0
            expected_timeline_start = 0
            previous_entry_sha256 = ZERO
        else:
            expected_ordinal = _add(prior["ordinal"], 1)
            expected_unit_start = prior["unit_end"]
            expected_timeline_start = prior["timeline_end"]
            previous_entry_sha256 = prior["entry_sha256"]
        if (
            value["ordinal"] != expected_ordinal
            or value["unit_start"] != expected_unit_start
            or value["timeline_start"] != expected_timeline_start
        ):
            raise GeneratedMediaOutputRegistryError("invalid entry predecessor")
        payload = value["payload"]
        entry: Record = {
            field: value[field]
            for field in ENTRY_SCALARS
            if field
            not in (
                "unit_end",
                "payload_offset",
                "payload_bytes",
            )
        }
        entry["unit_end"] = _add(
            value["unit_start"],
            value["unit_count"],
        )
        entry["payload_offset"] = payload_cursor
        entry["payload_bytes"] = len(payload)
        for field in ENTRY_DIGESTS[:-2]:
            entry[field] = value[field]
        entry["previous_entry_sha256"] = previous_entry_sha256
        entry["payload_sha256"] = payload_root(
            value["modality"],
            value["ordinal"],
            value["encoding_abi"],
            value["source_output_sha256"],
            payload,
        )
        entry["entry_sha256"] = ZERO
        entry["entry_sha256"] = entry_root(entry)
        entry = validate_entry(entry)
        entries.append(entry)
        payloads.append(payload)
        payload_cursor = _add(payload_cursor, len(payload))
        prior_by_modality[value["modality"]] = entry
    _validate_entry_sequence(entries, generation, previous_entries)
    return entries, payloads, b"".join(payloads)


def _metadata_from_manifest(manifest: Record) -> Record:
    return {field: manifest[field] for field in METADATA_FIELDS}


def _validate_successor(
    current: Record,
    previous: Record,
) -> None:
    manifest = current["manifest"]
    previous_manifest = previous["manifest"]
    try:
        generation_valid = manifest["generation"] == _add(
            previous_manifest["generation"],
            1,
        )
        sequence_valid = manifest["publication_sequence"] == _add(
            previous_manifest["publication_sequence"],
            1,
        )
    except GeneratedMediaOutputRegistryError as error:
        raise GeneratedMediaOutputRegistryError(
            "invalid successor arithmetic"
        ) from error
    if (
        not generation_valid
        or not sequence_valid
        or manifest["request_epoch"] != previous_manifest["request_epoch"]
        or manifest["tenant_scope_sha256"] != previous_manifest["tenant_scope_sha256"]
        or manifest["metadata_policy_sha256"]
        != previous_manifest["metadata_policy_sha256"]
        or manifest["challenge_sha256"] != previous_manifest["challenge_sha256"]
        or manifest["modality_mask"] != previous_manifest["modality_mask"]
        or manifest["previous_manifest_sha256"] != previous_manifest["manifest_sha256"]
        or manifest["previous_archive_sha256"] != previous["archive_sha256"]
    ):
        raise GeneratedMediaOutputRegistryError("invalid archive lineage")
    _validate_entry_sequence(
        current["entries"],
        manifest["generation"],
        previous["entries"],
    )


def encode_archive(
    previous: Record | None,
    metadata_value: Record,
    entry_values: list[Record],
) -> Record:
    previous_checked = None if previous is None else validate_decoded_archive(previous)
    metadata = _validate_metadata(metadata_value)
    if (metadata["generation"] == 1) != (previous_checked is None):
        raise GeneratedMediaOutputRegistryError("invalid predecessor")
    previous_entries = None if previous_checked is None else previous_checked["entries"]
    entries, payloads, payload_pack = _build_entries(
        entry_values,
        metadata["generation"],
        previous_entries,
    )
    entry_table = b"".join(encode_entry(entry) for entry in entries)
    previous_manifest_sha256 = (
        ZERO
        if previous_checked is None
        else previous_checked["manifest"]["manifest_sha256"]
    )
    previous_archive_sha256 = (
        ZERO if previous_checked is None else previous_checked["archive_sha256"]
    )
    manifest = _make_manifest(
        metadata,
        entries,
        entry_table,
        payload_pack,
        previous_manifest_sha256,
        previous_archive_sha256,
    )
    archive = _encode_set(
        generation=manifest["generation"],
        request_epoch=manifest["request_epoch"],
        publication_next_sequence=_add(
            manifest["publication_sequence"],
            1,
        ),
        parent_archive_sha256=previous_archive_sha256,
        challenge_sha256=manifest["challenge_sha256"],
        objects=(
            (
                MANIFEST_OBJECT_ORDINAL,
                MANIFEST_ABI,
                encode_manifest(manifest),
            ),
            (
                ENTRY_TABLE_OBJECT_ORDINAL,
                ENTRY_TABLE_ABI,
                entry_table,
            ),
            (
                PAYLOAD_PACK_OBJECT_ORDINAL,
                PAYLOAD_PACK_ABI,
                payload_pack,
            ),
        ),
    )
    return decode_archive(archive, previous_checked)


def _decode_archive_core(raw: bytes) -> Record:
    set_value = _decode_set(raw)
    objects = set_value["objects"]
    if (
        objects[MANIFEST_OBJECT_ORDINAL]["abi_version"] != MANIFEST_ABI
        or objects[ENTRY_TABLE_OBJECT_ORDINAL]["abi_version"] != ENTRY_TABLE_ABI
        or objects[PAYLOAD_PACK_OBJECT_ORDINAL]["abi_version"] != PAYLOAD_PACK_ABI
    ):
        raise GeneratedMediaOutputRegistryError("invalid object ABI")
    manifest = decode_manifest(objects[MANIFEST_OBJECT_ORDINAL]["bytes"])
    entry_table = objects[ENTRY_TABLE_OBJECT_ORDINAL]["bytes"]
    payload_pack = objects[PAYLOAD_PACK_OBJECT_ORDINAL]["bytes"]
    if (
        len(entry_table) != manifest["entry_table_bytes"]
        or len(payload_pack) != manifest["payload_pack_bytes"]
        or entry_table_root(manifest["entry_count"], entry_table)
        != manifest["entry_table_sha256"]
        or payload_pack_root(payload_pack) != manifest["payload_pack_sha256"]
    ):
        raise GeneratedMediaOutputRegistryError("manifest object mismatch")
    entries = [
        decode_entry(entry_table[index : index + ENTRY_BYTES])
        for index in range(0, len(entry_table), ENTRY_BYTES)
    ]
    if len(entries) != manifest["entry_count"]:
        raise GeneratedMediaOutputRegistryError("entry count mismatch")
    payloads: list[bytes] = []
    cursor = 0
    for entry in entries:
        end = _add(entry["payload_offset"], entry["payload_bytes"])
        if entry["payload_offset"] != cursor or end > len(payload_pack):
            raise GeneratedMediaOutputRegistryError("non-canonical payload offset")
        payload = payload_pack[cursor:end]
        if entry["payload_sha256"] != payload_root(
            entry["modality"],
            entry["ordinal"],
            entry["encoding_abi"],
            entry["source_output_sha256"],
            payload,
        ):
            raise GeneratedMediaOutputRegistryError("payload digest mismatch")
        payloads.append(payload)
        cursor = end
    if cursor != len(payload_pack):
        raise GeneratedMediaOutputRegistryError("payload pack tail")
    _validate_entry_sequence(
        entries,
        manifest["generation"],
        None,
    )
    expected_manifest = _make_manifest(
        _metadata_from_manifest(manifest),
        entries,
        entry_table,
        payload_pack,
        manifest["previous_manifest_sha256"],
        manifest["previous_archive_sha256"],
    )
    if manifest != expected_manifest:
        raise GeneratedMediaOutputRegistryError("invalid manifest bindings")
    if (
        set_value["generation"] != manifest["generation"]
        or set_value["request_epoch"] != manifest["request_epoch"]
        or set_value["publication_next_sequence"]
        != _add(manifest["publication_sequence"], 1)
        or set_value["parent_archive_sha256"] != manifest["previous_archive_sha256"]
        or set_value["challenge_sha256"] != manifest["challenge_sha256"]
    ):
        raise GeneratedMediaOutputRegistryError("archive metadata mismatch")
    return {
        "archive_sha256": set_value["archive_sha256"],
        "archive_bytes": raw,
        "manifest": manifest,
        "entries": entries,
        "payloads": payloads,
        "entry_table": entry_table,
        "payload_pack": payload_pack,
    }


def _validated_snapshot(value: Record) -> Record:
    if (
        type(value) is not dict
        or any(type(key) is not str for key in value)
        or set(value) != ARCHIVE_FIELDS
    ):
        raise GeneratedMediaOutputRegistryError("invalid decoded archive fields")
    if type(value["archive_bytes"]) is not bytes:
        raise GeneratedMediaOutputRegistryError("invalid archive bytes")
    decoded = _decode_archive_core(value["archive_bytes"])
    if not _strict_equal(decoded, value):
        raise GeneratedMediaOutputRegistryError("invalid decoded archive")
    return decoded


def _strict_equal(left: Any, right: Any) -> bool:
    if type(left) is not type(right):
        return False
    if type(left) is dict:
        if any(type(key) is not str for key in left) or any(
            type(key) is not str for key in right
        ):
            return False
        if set(left) != set(right):
            return False
        return all(_strict_equal(left[key], right[key]) for key in left)
    if type(left) is list:
        return len(left) == len(right) and all(
            _strict_equal(left[index], right[index]) for index in range(len(left))
        )
    if type(left) in (bytes, str, int, bool, type(None)):
        return left == right
    return False


def decode_archive(raw: bytes, previous: Record | None) -> Record:
    current = _decode_archive_core(raw)
    if current["manifest"]["generation"] == 1:
        if previous is not None:
            raise GeneratedMediaOutputRegistryError("unexpected predecessor")
        return current
    if previous is None:
        raise GeneratedMediaOutputRegistryError("missing predecessor")
    previous_checked = _validated_snapshot(previous)
    _validate_successor(current, previous_checked)
    return current


def validate_decoded_archive(value: Record) -> Record:
    return _validated_snapshot(value)


def _reference_entry(
    *,
    modality: int,
    ordinal: int,
    unit_start: int,
    unit_count: int,
    timeline_start: int,
    timeline_end: int,
    source_bytes: int,
    generation_word: bytes,
) -> Record:
    names = {
        IMAGE_MODALITY: b"image",
        AUDIO_MODALITY: b"audio",
        VIDEO_MODALITY: b"video",
    }
    name = names[modality]
    suffix = name + b"-" + str(ordinal).encode("ascii")

    def identity(prefix: bytes) -> bytes:
        return reference_identity_root(prefix + b"-" + suffix)

    completion = ZERO if modality == IMAGE_MODALITY else identity(b"completion")
    return {
        "modality": modality,
        "ordinal": ordinal,
        "unit_start": unit_start,
        "unit_count": unit_count,
        "timeline_start": timeline_start,
        "timeline_end": timeline_end,
        "source_bytes": source_bytes,
        "encoding_abi": modality,
        "completion_required": modality != IMAGE_MODALITY,
        "completed": True,
        "artifact_sha256": identity(b"artifact"),
        "provenance_sha256": identity(b"provenance"),
        "result_sha256": identity(b"result"),
        "source_output_sha256": identity(b"source-output"),
        "media_object_sha256": identity(b"media-object"),
        "state_after_sha256": identity(b"state-after"),
        "completion_sha256": completion,
        "encoder_implementation_sha256": reference_identity_root(b"encoder-" + name),
        "format_sha256": reference_identity_root(b"format-" + name),
        "payload": (
            name
            + b"-"
            + str(ordinal).encode("ascii")
            + b"-generation-"
            + generation_word
        ),
    }


def reference_inputs() -> dict[str, Any]:
    common = {
        "request_epoch": 23,
        "tenant_scope_sha256": reference_identity_root(b"tenant-scope"),
        "metadata_policy_sha256": reference_identity_root(b"metadata-policy"),
        "challenge_sha256": reference_identity_root(b"challenge"),
    }
    metadata1 = {
        **common,
        "generation": 1,
        "publication_sequence": 1,
        "generation_plan_sha256": reference_identity_root(b"generation-plan-one"),
    }
    entries1 = [
        _reference_entry(
            modality=IMAGE_MODALITY,
            ordinal=0,
            unit_start=0,
            unit_count=1,
            timeline_start=0,
            timeline_end=100,
            source_bytes=101,
            generation_word=b"one",
        ),
        _reference_entry(
            modality=IMAGE_MODALITY,
            ordinal=1,
            unit_start=1,
            unit_count=2,
            timeline_start=100,
            timeline_end=260,
            source_bytes=102,
            generation_word=b"one",
        ),
        _reference_entry(
            modality=AUDIO_MODALITY,
            ordinal=0,
            unit_start=0,
            unit_count=160,
            timeline_start=0,
            timeline_end=160,
            source_bytes=201,
            generation_word=b"one",
        ),
        _reference_entry(
            modality=AUDIO_MODALITY,
            ordinal=1,
            unit_start=160,
            unit_count=240,
            timeline_start=160,
            timeline_end=400,
            source_bytes=202,
            generation_word=b"one",
        ),
        _reference_entry(
            modality=AUDIO_MODALITY,
            ordinal=2,
            unit_start=400,
            unit_count=80,
            timeline_start=400,
            timeline_end=480,
            source_bytes=203,
            generation_word=b"one",
        ),
        _reference_entry(
            modality=VIDEO_MODALITY,
            ordinal=0,
            unit_start=0,
            unit_count=1,
            timeline_start=0,
            timeline_end=33,
            source_bytes=301,
            generation_word=b"one",
        ),
        _reference_entry(
            modality=VIDEO_MODALITY,
            ordinal=1,
            unit_start=1,
            unit_count=2,
            timeline_start=33,
            timeline_end=99,
            source_bytes=302,
            generation_word=b"one",
        ),
    ]
    metadata2 = {
        **common,
        "generation": 2,
        "publication_sequence": 2,
        "generation_plan_sha256": reference_identity_root(b"generation-plan-two"),
    }
    entries2 = [
        _reference_entry(
            modality=IMAGE_MODALITY,
            ordinal=2,
            unit_start=3,
            unit_count=2,
            timeline_start=260,
            timeline_end=450,
            source_bytes=103,
            generation_word=b"two",
        ),
        _reference_entry(
            modality=IMAGE_MODALITY,
            ordinal=3,
            unit_start=5,
            unit_count=1,
            timeline_start=450,
            timeline_end=600,
            source_bytes=104,
            generation_word=b"two",
        ),
        _reference_entry(
            modality=AUDIO_MODALITY,
            ordinal=3,
            unit_start=480,
            unit_count=120,
            timeline_start=480,
            timeline_end=600,
            source_bytes=204,
            generation_word=b"two",
        ),
        _reference_entry(
            modality=AUDIO_MODALITY,
            ordinal=4,
            unit_start=600,
            unit_count=200,
            timeline_start=600,
            timeline_end=800,
            source_bytes=205,
            generation_word=b"two",
        ),
        _reference_entry(
            modality=VIDEO_MODALITY,
            ordinal=2,
            unit_start=3,
            unit_count=1,
            timeline_start=99,
            timeline_end=132,
            source_bytes=303,
            generation_word=b"two",
        ),
        _reference_entry(
            modality=VIDEO_MODALITY,
            ordinal=3,
            unit_start=4,
            unit_count=1,
            timeline_start=132,
            timeline_end=165,
            source_bytes=304,
            generation_word=b"two",
        ),
        _reference_entry(
            modality=VIDEO_MODALITY,
            ordinal=4,
            unit_start=5,
            unit_count=2,
            timeline_start=165,
            timeline_end=231,
            source_bytes=305,
            generation_word=b"two",
        ),
    ]
    return {
        "metadata1": metadata1,
        "entries1": entries1,
        "metadata2": metadata2,
        "entries2": entries2,
    }


def reference_archives() -> dict[str, Record]:
    fixture = reference_inputs()
    first = encode_archive(
        None,
        fixture["metadata1"],
        fixture["entries1"],
    )
    second = encode_archive(
        first,
        fixture["metadata2"],
        fixture["entries2"],
    )
    return {"first": first, "second": second}
