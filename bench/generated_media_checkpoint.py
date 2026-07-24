from __future__ import annotations

import hashlib
import struct
from collections.abc import Callable
from typing import Any

Record = dict[str, Any]
Validator = Callable[[Record], Record]

U64_MAX = (1 << 64) - 1
ZERO = bytes(32)

MEMBER_ABI = 1
MEMBER_BODY_BYTES = 448
MEMBER_BYTES = MEMBER_BODY_BYTES + 32
MEMBER_MAGIC = b"GLGMMBR1"
MEMBER_DOMAIN = b"glacier.generated-media-member.v1"

CHECKPOINT_ABI = 1
CHECKPOINT_BODY_BYTES = 768
CHECKPOINT_BYTES = CHECKPOINT_BODY_BYTES + 32
CHECKPOINT_MAGIC = b"GLGMCHK1"
CHECKPOINT_DOMAIN = b"glacier.generated-media-checkpoint.v1"

SELECTOR_ABI = 1
SELECTOR_BODY_BYTES = 320
SELECTOR_BYTES = SELECTOR_BODY_BYTES + 32
SELECTOR_MAGIC = b"GLGMSEL1"
SELECTOR_DOMAIN = b"glacier.generated-media-selector.v1"

REFERENCE_DOMAIN = b"glacier.generated-media-reference.v1"

IMAGE_MODALITY = 1
AUDIO_MODALITY = 2
VIDEO_MODALITY = 3
REQUIRED_MEMBER_COUNT = 3

MEMBER_SCALARS = (
    "request_epoch",
    "source_generation",
    "modality",
    "ordinal",
    "unit_start",
    "unit_count",
    "unit_end",
    "timeline_start",
    "timeline_end",
    "byte_count",
    "completion_required",
    "completed",
)
MEMBER_DIGESTS = (
    "artifact_sha256",
    "provenance_sha256",
    "result_sha256",
    "output_sha256",
    "media_object_sha256",
    "state_after_sha256",
    "completion_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
)

CHECKPOINT_SCALARS = (
    "request_epoch",
    "generation",
    "publication_sequence",
    "member_count",
    "total_bytes",
    "total_units",
    "image_ordinal",
    "audio_ordinal",
    "video_ordinal",
    "image_unit_end",
    "audio_unit_end",
    "video_unit_end",
    "video_timeline_end",
    "image_bytes",
    "audio_bytes",
    "video_bytes",
    "image_units",
    "audio_units",
    "video_units",
)
CHECKPOINT_DIGESTS = (
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "image_member_sha256",
    "audio_member_sha256",
    "video_member_sha256",
    "image_result_sha256",
    "audio_result_sha256",
    "video_result_sha256",
    "image_output_sha256",
    "audio_output_sha256",
    "video_output_sha256",
    "image_state_sha256",
    "audio_state_sha256",
    "video_state_sha256",
    "audio_completion_sha256",
    "video_completion_sha256",
    "previous_checkpoint_sha256",
)

SELECTOR_SCALARS = (
    "request_epoch",
    "generation",
    "publication_sequence",
    "checkpoint_wire_bytes",
    "member_wire_bytes",
    "member_count",
)
SELECTOR_DIGESTS = (
    "checkpoint_sha256",
    "image_member_sha256",
    "audio_member_sha256",
    "video_member_sha256",
    "previous_checkpoint_sha256",
    "previous_selector_sha256",
    "challenge_sha256",
)


class GeneratedMediaCheckpointError(ValueError):
    pass


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise GeneratedMediaCheckpointError("u64 out of range")
    return struct.pack("<Q", value)


def _add(left: int, right: int) -> int:
    value = left + right
    _u64(value)
    return value


def _mul(left: int, right: int) -> int:
    value = left * right
    _u64(value)
    return value


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise GeneratedMediaCheckpointError("invalid digest")
    if not allow_zero and value == ZERO:
        raise GeneratedMediaCheckpointError("zero digest")
    return value


def _body(
    value: Record,
    *,
    magic: bytes,
    abi: int,
    total_bytes: int,
    body_bytes: int,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
) -> bytes:
    output = bytearray(body_bytes)
    output[0:8] = magic
    output[8:16] = _u64(abi)
    output[16:24] = _u64(total_bytes)
    output[24:32] = _u64(0)
    offset = 32
    for field in scalars:
        output[offset : offset + 8] = _u64(value[field])
        offset += 8
    for field in digests:
        output[offset : offset + 32] = _digest(
            value[field],
            allow_zero=field.startswith("previous_")
            or field == "completion_sha256",
        )
        offset += 32
    if offset > body_bytes:
        raise GeneratedMediaCheckpointError("wire body overflow")
    return bytes(output)


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def _record(
    value: Record,
    *,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
) -> Record:
    expected = set(scalars) | set(digests) | {root_field}
    if not isinstance(value, dict) or set(value) != expected:
        raise GeneratedMediaCheckpointError("record fields mismatch")
    record = dict(value)
    for field in scalars:
        _u64(record[field])
    for field in digests:
        _digest(
            record[field],
            allow_zero=field.startswith("previous_")
            or field == "completion_sha256",
        )
    _digest(record[root_field])
    return record


def _validate_record(
    value: Record,
    *,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
    body: Callable[[Record], bytes],
    domain: bytes,
) -> Record:
    record = _record(
        value,
        scalars=scalars,
        digests=digests,
        root_field=root_field,
    )
    if record[root_field] != _root(domain, body(record)):
        raise GeneratedMediaCheckpointError("invalid record root")
    return record


def _encode(
    value: Record,
    *,
    validator: Validator,
    body: Callable[[Record], bytes],
    root_field: str,
) -> bytes:
    record = validator(value)
    raw = body(record)
    return raw + record[root_field]


def _decode(
    raw: bytes,
    *,
    magic: bytes,
    abi: int,
    total_bytes: int,
    body_bytes: int,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
    domain: bytes,
    validator: Validator,
) -> Record:
    if (
        not isinstance(raw, bytes)
        or len(raw) != total_bytes
        or raw[0:8] != magic
        or struct.unpack_from("<Q", raw, 8)[0] != abi
        or struct.unpack_from("<Q", raw, 16)[0] != total_bytes
        or struct.unpack_from("<Q", raw, 24)[0] != 0
    ):
        raise GeneratedMediaCheckpointError("invalid wire")
    if raw[body_bytes:] != _root(domain, raw[:body_bytes]):
        raise GeneratedMediaCheckpointError("invalid wire root")
    value: Record = {}
    offset = 32
    for field in scalars:
        value[field] = struct.unpack_from("<Q", raw, offset)[0]
        offset += 8
    for field in digests:
        value[field] = raw[offset : offset + 32]
        offset += 32
    if any(raw[offset:body_bytes]):
        raise GeneratedMediaCheckpointError("nonzero reserved bytes")
    value[root_field] = raw[body_bytes:]
    return validator(value)


def _member_body(value: Record) -> bytes:
    return _body(
        value,
        magic=MEMBER_MAGIC,
        abi=MEMBER_ABI,
        total_bytes=MEMBER_BYTES,
        body_bytes=MEMBER_BODY_BYTES,
        scalars=MEMBER_SCALARS,
        digests=MEMBER_DIGESTS,
    )


def validate_member(value: Record) -> Record:
    member = _validate_record(
        value,
        scalars=MEMBER_SCALARS,
        digests=MEMBER_DIGESTS,
        root_field="member_sha256",
        body=_member_body,
        domain=MEMBER_DOMAIN,
    )
    if (
        member["request_epoch"] == 0
        or member["source_generation"] == 0
        or member["unit_count"] == 0
        or member["unit_end"]
        != _add(member["unit_start"], member["unit_count"])
        or member["timeline_end"] <= member["timeline_start"]
        or member["byte_count"] == 0
        or member["completed"] != 1
    ):
        raise GeneratedMediaCheckpointError("invalid member")
    if member["modality"] == IMAGE_MODALITY:
        if (
            member["ordinal"] == 0
            or member["source_generation"] != member["ordinal"]
            or member["unit_start"] != member["ordinal"] - 1
            or member["unit_count"] != 1
            or member["unit_end"] != member["ordinal"]
            or member["timeline_start"] != member["unit_start"]
            or member["timeline_end"] != member["unit_end"]
            or member["completion_required"] != 0
            or member["completion_sha256"] != ZERO
        ):
            raise GeneratedMediaCheckpointError("invalid image member")
    elif member["modality"] in (AUDIO_MODALITY, VIDEO_MODALITY):
        if (
            member["source_generation"]
            != _add(_mul(member["ordinal"], 2), 1)
            or member["completion_required"] != 1
            or member["completion_sha256"] == ZERO
        ):
            raise GeneratedMediaCheckpointError("invalid stream member")
        if member["modality"] == AUDIO_MODALITY and (
            member["timeline_start"] != member["unit_start"]
            or member["timeline_end"] != member["unit_end"]
        ):
            raise GeneratedMediaCheckpointError("invalid audio timeline")
    else:
        raise GeneratedMediaCheckpointError("invalid modality")
    return member


def encode_member(value: Record) -> bytes:
    return _encode(
        value,
        validator=validate_member,
        body=_member_body,
        root_field="member_sha256",
    )


def decode_member(raw: bytes) -> Record:
    return _decode(
        raw,
        magic=MEMBER_MAGIC,
        abi=MEMBER_ABI,
        total_bytes=MEMBER_BYTES,
        body_bytes=MEMBER_BODY_BYTES,
        scalars=MEMBER_SCALARS,
        digests=MEMBER_DIGESTS,
        root_field="member_sha256",
        domain=MEMBER_DOMAIN,
        validator=validate_member,
    )


def _checkpoint_body(value: Record) -> bytes:
    return _body(
        value,
        magic=CHECKPOINT_MAGIC,
        abi=CHECKPOINT_ABI,
        total_bytes=CHECKPOINT_BYTES,
        body_bytes=CHECKPOINT_BODY_BYTES,
        scalars=CHECKPOINT_SCALARS,
        digests=CHECKPOINT_DIGESTS,
    )


def validate_checkpoint(value: Record) -> Record:
    checkpoint = _validate_record(
        value,
        scalars=CHECKPOINT_SCALARS,
        digests=CHECKPOINT_DIGESTS,
        root_field="checkpoint_sha256",
        body=_checkpoint_body,
        domain=CHECKPOINT_DOMAIN,
    )
    generation = checkpoint["generation"]
    if generation == 0:
        raise GeneratedMediaCheckpointError("invalid generation")
    total_bytes = _add(
        _add(checkpoint["image_bytes"], checkpoint["audio_bytes"]),
        checkpoint["video_bytes"],
    )
    total_units = _add(
        _add(checkpoint["image_units"], checkpoint["audio_units"]),
        checkpoint["video_units"],
    )
    if (
        checkpoint["request_epoch"] == 0
        or checkpoint["publication_sequence"] != generation
        or checkpoint["member_count"] != REQUIRED_MEMBER_COUNT
        or checkpoint["total_bytes"] == 0
        or checkpoint["total_bytes"] != total_bytes
        or checkpoint["total_units"] == 0
        or checkpoint["total_units"] != total_units
        or checkpoint["image_ordinal"] != generation
        or checkpoint["audio_ordinal"] != generation - 1
        or checkpoint["video_ordinal"] != generation - 1
        or checkpoint["image_unit_end"] != generation
        or checkpoint["image_bytes"] == 0
        or checkpoint["audio_bytes"] == 0
        or checkpoint["video_bytes"] == 0
        or checkpoint["image_units"] != 1
        or checkpoint["audio_units"] == 0
        or checkpoint["video_units"] == 0
        or checkpoint["audio_unit_end"] == 0
        or checkpoint["video_unit_end"] == 0
        or checkpoint["video_timeline_end"] == 0
        or (generation == 1)
        != (checkpoint["previous_checkpoint_sha256"] == ZERO)
    ):
        raise GeneratedMediaCheckpointError("invalid checkpoint")
    return checkpoint


def make_checkpoint(
    previous_value: Record | None,
    image_value: Record,
    audio_value: Record,
    video_value: Record,
) -> Record:
    image_member = validate_member(image_value)
    audio_member = validate_member(audio_value)
    video_member = validate_member(video_value)
    exact = (
        image_member["modality"] == IMAGE_MODALITY,
        audio_member["modality"] == AUDIO_MODALITY,
        video_member["modality"] == VIDEO_MODALITY,
        image_member["request_epoch"] == audio_member["request_epoch"],
        image_member["request_epoch"] == video_member["request_epoch"],
        image_member["tenant_scope_sha256"]
        == audio_member["tenant_scope_sha256"],
        image_member["tenant_scope_sha256"]
        == video_member["tenant_scope_sha256"],
        image_member["metadata_policy_sha256"]
        == audio_member["metadata_policy_sha256"],
        image_member["metadata_policy_sha256"]
        == video_member["metadata_policy_sha256"],
        image_member["challenge_sha256"]
        == audio_member["challenge_sha256"],
        image_member["challenge_sha256"]
        == video_member["challenge_sha256"],
    )
    if not all(exact):
        raise GeneratedMediaCheckpointError("member scope mismatch")
    generation = image_member["ordinal"]
    if (
        audio_member["ordinal"] + 1 != generation
        or video_member["ordinal"] + 1 != generation
    ):
        raise GeneratedMediaCheckpointError("mixed generation")
    previous_root = ZERO
    if previous_value is None:
        if (
            generation != 1
            or image_member["unit_start"] != 0
            or audio_member["unit_start"] != 0
            or video_member["unit_start"] != 0
            or video_member["timeline_start"] != 0
        ):
            raise GeneratedMediaCheckpointError("invalid origin")
    else:
        previous = validate_checkpoint(previous_value)
        if (
            generation != previous["generation"] + 1
            or image_member["unit_start"] != previous["image_unit_end"]
            or audio_member["unit_start"] != previous["audio_unit_end"]
            or video_member["unit_start"] != previous["video_unit_end"]
            or video_member["timeline_start"]
            != previous["video_timeline_end"]
            or image_member["request_epoch"] != previous["request_epoch"]
            or image_member["tenant_scope_sha256"]
            != previous["tenant_scope_sha256"]
            or image_member["metadata_policy_sha256"]
            != previous["metadata_policy_sha256"]
            or image_member["challenge_sha256"]
            != previous["challenge_sha256"]
        ):
            raise GeneratedMediaCheckpointError("invalid successor")
        current_roots = (
            image_member["member_sha256"],
            audio_member["member_sha256"],
            video_member["member_sha256"],
            image_member["result_sha256"],
            audio_member["result_sha256"],
            video_member["result_sha256"],
        )
        previous_roots = (
            previous["image_member_sha256"],
            previous["audio_member_sha256"],
            previous["video_member_sha256"],
            previous["image_result_sha256"],
            previous["audio_result_sha256"],
            previous["video_result_sha256"],
        )
        if any(
            current == prior
            for current, prior in zip(
                current_roots,
                previous_roots,
            )
        ):
            raise GeneratedMediaCheckpointError("member replay")
        previous_root = previous["checkpoint_sha256"]
    total_bytes = _add(
        _add(image_member["byte_count"], audio_member["byte_count"]),
        video_member["byte_count"],
    )
    total_units = _add(
        _add(image_member["unit_count"], audio_member["unit_count"]),
        video_member["unit_count"],
    )
    checkpoint: Record = {
        "request_epoch": image_member["request_epoch"],
        "generation": generation,
        "publication_sequence": generation,
        "member_count": REQUIRED_MEMBER_COUNT,
        "total_bytes": total_bytes,
        "total_units": total_units,
        "image_ordinal": image_member["ordinal"],
        "audio_ordinal": audio_member["ordinal"],
        "video_ordinal": video_member["ordinal"],
        "image_unit_end": image_member["unit_end"],
        "audio_unit_end": audio_member["unit_end"],
        "video_unit_end": video_member["unit_end"],
        "video_timeline_end": video_member["timeline_end"],
        "image_bytes": image_member["byte_count"],
        "audio_bytes": audio_member["byte_count"],
        "video_bytes": video_member["byte_count"],
        "image_units": image_member["unit_count"],
        "audio_units": audio_member["unit_count"],
        "video_units": video_member["unit_count"],
        "tenant_scope_sha256": image_member["tenant_scope_sha256"],
        "metadata_policy_sha256": image_member[
            "metadata_policy_sha256"
        ],
        "challenge_sha256": image_member["challenge_sha256"],
        "image_member_sha256": image_member["member_sha256"],
        "audio_member_sha256": audio_member["member_sha256"],
        "video_member_sha256": video_member["member_sha256"],
        "image_result_sha256": image_member["result_sha256"],
        "audio_result_sha256": audio_member["result_sha256"],
        "video_result_sha256": video_member["result_sha256"],
        "image_output_sha256": image_member["output_sha256"],
        "audio_output_sha256": audio_member["output_sha256"],
        "video_output_sha256": video_member["output_sha256"],
        "image_state_sha256": image_member["state_after_sha256"],
        "audio_state_sha256": audio_member["state_after_sha256"],
        "video_state_sha256": video_member["state_after_sha256"],
        "audio_completion_sha256": audio_member["completion_sha256"],
        "video_completion_sha256": video_member["completion_sha256"],
        "previous_checkpoint_sha256": previous_root,
        "checkpoint_sha256": ZERO,
    }
    checkpoint["checkpoint_sha256"] = _root(
        CHECKPOINT_DOMAIN,
        _checkpoint_body(checkpoint),
    )
    return validate_checkpoint(checkpoint)


def encode_checkpoint(value: Record) -> bytes:
    return _encode(
        value,
        validator=validate_checkpoint,
        body=_checkpoint_body,
        root_field="checkpoint_sha256",
    )


def decode_checkpoint(raw: bytes) -> Record:
    return _decode(
        raw,
        magic=CHECKPOINT_MAGIC,
        abi=CHECKPOINT_ABI,
        total_bytes=CHECKPOINT_BYTES,
        body_bytes=CHECKPOINT_BODY_BYTES,
        scalars=CHECKPOINT_SCALARS,
        digests=CHECKPOINT_DIGESTS,
        root_field="checkpoint_sha256",
        domain=CHECKPOINT_DOMAIN,
        validator=validate_checkpoint,
    )


def _selector_body(value: Record) -> bytes:
    return _body(
        value,
        magic=SELECTOR_MAGIC,
        abi=SELECTOR_ABI,
        total_bytes=SELECTOR_BYTES,
        body_bytes=SELECTOR_BODY_BYTES,
        scalars=SELECTOR_SCALARS,
        digests=SELECTOR_DIGESTS,
    )


def validate_selector(value: Record) -> Record:
    selector = _validate_record(
        value,
        scalars=SELECTOR_SCALARS,
        digests=SELECTOR_DIGESTS,
        root_field="selector_sha256",
        body=_selector_body,
        domain=SELECTOR_DOMAIN,
    )
    if (
        selector["request_epoch"] == 0
        or selector["generation"] == 0
        or selector["publication_sequence"] != selector["generation"]
        or selector["checkpoint_wire_bytes"] != CHECKPOINT_BYTES
        or selector["member_wire_bytes"] != MEMBER_BYTES
        or selector["member_count"] != REQUIRED_MEMBER_COUNT
        or (selector["generation"] == 1)
        != (selector["previous_checkpoint_sha256"] == ZERO)
        or (selector["generation"] == 1)
        != (selector["previous_selector_sha256"] == ZERO)
    ):
        raise GeneratedMediaCheckpointError("invalid selector")
    return selector


def make_selector(
    previous_value: Record | None,
    checkpoint_value: Record,
) -> Record:
    checkpoint = validate_checkpoint(checkpoint_value)
    previous_selector = ZERO
    if previous_value is None:
        if checkpoint["generation"] != 1:
            raise GeneratedMediaCheckpointError("invalid initial selector")
    else:
        previous = validate_selector(previous_value)
        if (
            checkpoint["generation"] != previous["generation"] + 1
            or checkpoint["request_epoch"] != previous["request_epoch"]
            or checkpoint["previous_checkpoint_sha256"]
            != previous["checkpoint_sha256"]
            or checkpoint["challenge_sha256"]
            != previous["challenge_sha256"]
        ):
            raise GeneratedMediaCheckpointError("invalid selector chain")
        previous_selector = previous["selector_sha256"]
    selector: Record = {
        "request_epoch": checkpoint["request_epoch"],
        "generation": checkpoint["generation"],
        "publication_sequence": checkpoint["publication_sequence"],
        "checkpoint_wire_bytes": CHECKPOINT_BYTES,
        "member_wire_bytes": MEMBER_BYTES,
        "member_count": REQUIRED_MEMBER_COUNT,
        "checkpoint_sha256": checkpoint["checkpoint_sha256"],
        "image_member_sha256": checkpoint["image_member_sha256"],
        "audio_member_sha256": checkpoint["audio_member_sha256"],
        "video_member_sha256": checkpoint["video_member_sha256"],
        "previous_checkpoint_sha256": checkpoint[
            "previous_checkpoint_sha256"
        ],
        "previous_selector_sha256": previous_selector,
        "challenge_sha256": checkpoint["challenge_sha256"],
        "selector_sha256": ZERO,
    }
    selector["selector_sha256"] = _root(
        SELECTOR_DOMAIN,
        _selector_body(selector),
    )
    return validate_selector(selector)


def encode_selector(value: Record) -> bytes:
    return _encode(
        value,
        validator=validate_selector,
        body=_selector_body,
        root_field="selector_sha256",
    )


def decode_selector(raw: bytes) -> Record:
    return _decode(
        raw,
        magic=SELECTOR_MAGIC,
        abi=SELECTOR_ABI,
        total_bytes=SELECTOR_BYTES,
        body_bytes=SELECTOR_BODY_BYTES,
        scalars=SELECTOR_SCALARS,
        digests=SELECTOR_DIGESTS,
        root_field="selector_sha256",
        domain=SELECTOR_DOMAIN,
        validator=validate_selector,
    )


def _reference_digest(kind: int, modality: int, generation: int) -> bytes:
    return hashlib.sha256(
        REFERENCE_DOMAIN
        + _u64(kind)
        + _u64(modality)
        + _u64(generation)
    ).digest()


def _reference_member(modality: int, generation: int) -> Record:
    ordinal = generation if modality == IMAGE_MODALITY else generation - 1
    unit_start = ordinal if modality != IMAGE_MODALITY else ordinal - 1
    if modality != IMAGE_MODALITY:
        unit_start *= 2
    unit_count = 1 if modality == IMAGE_MODALITY else 2
    unit_end = unit_start + unit_count
    timeline_start = ordinal * 5 if modality == VIDEO_MODALITY else unit_start
    timeline_end = (
        timeline_start + 5
        if modality == VIDEO_MODALITY
        else unit_end
    )
    byte_count = 8 if modality == VIDEO_MODALITY else 4
    source_generation = (
        generation
        if modality == IMAGE_MODALITY
        else ordinal * 2 + 1
    )
    member: Record = {
        "request_epoch": 70_001,
        "source_generation": source_generation,
        "modality": modality,
        "ordinal": ordinal,
        "unit_start": unit_start,
        "unit_count": unit_count,
        "unit_end": unit_end,
        "timeline_start": timeline_start,
        "timeline_end": timeline_end,
        "byte_count": byte_count,
        "completion_required": 0 if modality == IMAGE_MODALITY else 1,
        "completed": 1,
        "artifact_sha256": _reference_digest(1, modality, generation),
        "provenance_sha256": _reference_digest(2, modality, generation),
        "result_sha256": _reference_digest(3, modality, generation),
        "output_sha256": _reference_digest(4, modality, generation),
        "media_object_sha256": _reference_digest(5, modality, generation),
        "state_after_sha256": _reference_digest(6, modality, generation),
        "completion_sha256": (
            ZERO
            if modality == IMAGE_MODALITY
            else _reference_digest(7, modality, generation)
        ),
        "tenant_scope_sha256": _reference_digest(8, 0, 0),
        "metadata_policy_sha256": _reference_digest(9, 0, 0),
        "challenge_sha256": _reference_digest(10, 0, 0),
        "member_sha256": ZERO,
    }
    member["member_sha256"] = _root(
        MEMBER_DOMAIN,
        _member_body(member),
    )
    return validate_member(member)


def reference_fixture() -> Record:
    image1 = _reference_member(IMAGE_MODALITY, 1)
    audio1 = _reference_member(AUDIO_MODALITY, 1)
    video1 = _reference_member(VIDEO_MODALITY, 1)
    checkpoint1 = make_checkpoint(None, image1, audio1, video1)
    selector1 = make_selector(None, checkpoint1)
    image2 = _reference_member(IMAGE_MODALITY, 2)
    audio2 = _reference_member(AUDIO_MODALITY, 2)
    video2 = _reference_member(VIDEO_MODALITY, 2)
    checkpoint2 = make_checkpoint(
        checkpoint1,
        image2,
        audio2,
        video2,
    )
    selector2 = make_selector(selector1, checkpoint2)
    return {
        "image1": image1,
        "audio1": audio1,
        "video1": video1,
        "checkpoint1": checkpoint1,
        "selector1": selector1,
        "image2": image2,
        "audio2": audio2,
        "video2": video2,
        "checkpoint2": checkpoint2,
        "selector2": selector2,
    }
