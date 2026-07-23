"""Independent image/audio/video identity, timeline, and publication model."""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Any


class MediaContractError(ValueError):
    """A media descriptor, timeline event, or publication is invalid."""


Record = dict[str, Any]
DESCRIPTOR_ABI = 0x474D4F4200000001
TIMELINE_EVENT_ABI = 0x474D544C00000001
PUBLICATION_ABI = 0x474D505500000001
DESCRIPTOR_MAGIC = b"GMOBJ01\x00"
DESCRIPTOR_BYTES = 272
DESCRIPTOR_BODY_BYTES = 240
ALLOWED_FLAGS = 0
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
U128_MAX = (1 << 128) - 1
DESCRIPTOR_DOMAIN = b"glacier-media-object-v1\x00"
TIMELINE_EVENT_DOMAIN = b"glacier-media-timeline-event-v1\x00"
PUBLICATION_STATE_DOMAIN = b"glacier-media-publication-state-v1\x00"
PUBLICATION_DOMAIN = b"glacier-media-publication-v1\x00"

IMAGE = 1
AUDIO = 2
VIDEO = 3
IDENTITY = 1
TRIM = 2
PAD = 3
RESAMPLE = 4
FRAME_SELECT = 5
REORDER = 6


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaContractError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, zero_allowed: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or not zero_allowed
        and value == ZERO_DIGEST
    ):
        raise MediaContractError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _time_base(value: Any, *, static_allowed: bool = False) -> tuple[int, int]:
    if (
        not isinstance(value, tuple)
        or len(value) != 2
        or not all(isinstance(part, int) for part in value)
    ):
        raise MediaContractError("invalid time base")
    numerator, denominator = value
    _u64(numerator)
    _u64(denominator)
    if static_allowed and numerator == 0 and denominator == 1:
        return value
    if numerator == 0 or denominator == 0 or math.gcd(
        numerator, denominator
    ) != 1:
        raise MediaContractError("non-canonical time base")
    return value


def _media_object(value: Record) -> Record:
    try:
        kind = value["kind"]
        semantic_abi = value["semantic_abi"]
        byte_length = value["byte_length"]
        container_id = value["container_id"]
        codec_id = value["codec_id"]
        axes = tuple(value["axes"])
        time_base = _time_base(value["time_base"], static_allowed=True)
        tenant_scope_sha256 = _digest(value["tenant_scope_sha256"])
        content_sha256 = _digest(value["content_sha256"])
        metadata_policy_sha256 = _digest(value["metadata_policy_sha256"])
        provenance_sha256 = _digest(value["provenance_sha256"])
    except (KeyError, TypeError):
        raise MediaContractError("invalid media object") from None
    for field in (kind, semantic_abi, byte_length, container_id, codec_id):
        _u64(field)
    if (
        kind not in (IMAGE, AUDIO, VIDEO)
        or semantic_abi == 0
        or byte_length == 0
        or container_id == 0
        or codec_id == 0
        or len(axes) != 3
    ):
        raise MediaContractError("invalid media object")
    for axis in axes:
        _u64(axis)
    if kind == IMAGE and (
        0 in axes or axes[2] > 4 or time_base != (0, 1)
    ):
        raise MediaContractError("invalid image geometry")
    if kind == AUDIO and (
        axes[0] == 0
        or axes[1] == 0
        or axes[1] > 64
        or axes[2] == 0
        or axes[2] > 768_000
        or time_base != (1, axes[2])
    ):
        raise MediaContractError("invalid audio geometry")
    if kind == VIDEO:
        if 0 in axes:
            raise MediaContractError("invalid video geometry")
        _time_base(time_base)
    return {
        "kind": kind,
        "semantic_abi": semantic_abi,
        "byte_length": byte_length,
        "container_id": container_id,
        "codec_id": codec_id,
        "axes": axes,
        "time_base": time_base,
        "tenant_scope_sha256": tenant_scope_sha256,
        "content_sha256": content_sha256,
        "metadata_policy_sha256": metadata_policy_sha256,
        "provenance_sha256": provenance_sha256,
    }


def media_object_root(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) != DESCRIPTOR_BODY_BYTES:
        raise MediaContractError("invalid descriptor body")
    return _hash(DESCRIPTOR_DOMAIN, body)


def encode_media_object(value: Record) -> bytes:
    media = _media_object(value)
    output = bytearray(DESCRIPTOR_BYTES)
    output[:112] = b"".join(
        (
            DESCRIPTOR_MAGIC,
            _u64(DESCRIPTOR_ABI),
            _u64(DESCRIPTOR_BYTES),
            _u64(ALLOWED_FLAGS),
            _u64(media["kind"]),
            _u64(media["semantic_abi"]),
            _u64(media["byte_length"]),
            _u64(media["container_id"]),
            _u64(media["codec_id"]),
            *(_u64(axis) for axis in media["axes"]),
            _u64(media["time_base"][0]),
            _u64(media["time_base"][1]),
        )
    )
    output[112:240] = b"".join(
        (
            media["tenant_scope_sha256"],
            media["content_sha256"],
            media["metadata_policy_sha256"],
            media["provenance_sha256"],
        )
    )
    output[240:] = media_object_root(bytes(output[:240]))
    return bytes(output)


def decode_media_object(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != DESCRIPTOR_BYTES
        or encoded[:8] != DESCRIPTOR_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != DESCRIPTOR_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != DESCRIPTOR_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != ALLOWED_FLAGS
        or encoded[240:] != media_object_root(encoded[:240])
    ):
        raise MediaContractError("invalid descriptor")
    fields = struct.unpack_from("<QQQQQQQQQ", encoded, 32)
    return _media_object(
        {
            "kind": fields[0],
            "semantic_abi": fields[1],
            "byte_length": fields[2],
            "container_id": fields[3],
            "codec_id": fields[4],
            "axes": fields[5:8],
            "time_base": (
                fields[8],
                struct.unpack_from("<Q", encoded, 104)[0],
            ),
            "tenant_scope_sha256": encoded[112:144],
            "content_sha256": encoded[144:176],
            "metadata_policy_sha256": encoded[176:208],
            "provenance_sha256": encoded[208:240],
        }
    )


def media_object_sha256(encoded: bytes) -> bytes:
    decode_media_object(encoded)
    return encoded[240:]


def _position(value: Any) -> tuple[int, tuple[int, int]]:
    if (
        not isinstance(value, tuple)
        or len(value) != 2
        or not isinstance(value[0], int)
    ):
        raise MediaContractError("invalid position")
    _u64(value[0])
    return value[0], _time_base(value[1])


def _span(value: Any) -> tuple[Any, Any]:
    if not isinstance(value, tuple) or len(value) != 2:
        raise MediaContractError("invalid span")
    start, end = _position(value[0]), _position(value[1])
    if start[1] != end[1] or start[0] >= end[0]:
        raise MediaContractError("invalid span")
    return start, end


def convert_exact(
    position: tuple[int, tuple[int, int]],
    target_base: tuple[int, int],
) -> tuple[int, tuple[int, int]]:
    ticks, source_base = _position(position)
    target = _time_base(target_base)
    numerator = ticks * source_base[0]
    if numerator > U128_MAX:
        raise MediaContractError("converted position overflows")
    numerator *= target[1]
    denominator = source_base[1] * target[0]
    if numerator > U128_MAX or denominator > U128_MAX:
        raise MediaContractError("converted position overflows")
    ticks, remainder = divmod(numerator, denominator)
    if remainder or ticks > U64_MAX:
        raise MediaContractError("non-integral mapping")
    return ticks, target


def map_span_exact(
    span: tuple[Any, Any],
    target_base: tuple[int, int],
) -> tuple[Any, Any]:
    source = _span(span)
    return _span(
        (
            convert_exact(source[0], target_base),
            convert_exact(source[1], target_base),
        )
    )


def _span_bytes(span: Any) -> bytes:
    checked = _span(span)
    return b"".join(
        _u64(value)
        for position in checked
        for value in (position[0], *position[1])
    )


def _event(value: Record) -> Record:
    try:
        kind = value["kind"]
        sequence = value["sequence"]
        media_object_sha256 = _digest(value["media_object_sha256"])
        source = _span(value["source"])
        target = _span(value["target"])
        plan_sha256 = _digest(value["plan_sha256"])
        previous_event_sha256 = _digest(
            value["previous_event_sha256"], zero_allowed=True
        )
    except (KeyError, TypeError):
        raise MediaContractError("invalid timeline event") from None
    _u64(kind)
    _u64(sequence)
    if kind not in (
        IDENTITY,
        TRIM,
        PAD,
        RESAMPLE,
        FRAME_SELECT,
        REORDER,
    ) or sequence == 0:
        raise MediaContractError("invalid timeline event")
    if kind == IDENTITY and source != target:
        raise MediaContractError("identity changes timeline")
    if kind in (TRIM, FRAME_SELECT) and (
        target[1][0] - target[0][0] > source[1][0] - source[0][0]
    ):
        raise MediaContractError("selection expands timeline")
    return {
        "kind": kind,
        "sequence": sequence,
        "media_object_sha256": media_object_sha256,
        "source": source,
        "target": target,
        "plan_sha256": plan_sha256,
        "previous_event_sha256": previous_event_sha256,
    }


def timeline_event_root(value: Record) -> bytes:
    event = _event(value)
    return _hash(
        TIMELINE_EVENT_DOMAIN,
        _u64(TIMELINE_EVENT_ABI),
        _u64(event["kind"]),
        _u64(event["sequence"]),
        event["media_object_sha256"],
        _span_bytes(event["source"]),
        _span_bytes(event["target"]),
        event["plan_sha256"],
        event["previous_event_sha256"],
    )


def initialize_publication_state(
    request_epoch: int,
    first_sequence: int,
    timeline_base: tuple[int, int],
    media_object_sha256_value: bytes,
    previous_commit_sha256: bytes,
) -> Record:
    _u64(request_epoch)
    _u64(first_sequence)
    if request_epoch == 0 or first_sequence == 0:
        raise MediaContractError("invalid publication sequence")
    return {
        "request_epoch": request_epoch,
        "next_sequence": first_sequence,
        "visible_chunks": 0,
        "visible_units": 0,
        "timeline_base": _time_base(timeline_base),
        "media_object_sha256": _digest(media_object_sha256_value),
        "timeline_sha256": ZERO_DIGEST,
        "previous_commit_sha256": _digest(previous_commit_sha256),
    }


def _publication_state(value: Record) -> Record:
    try:
        state = {
            "request_epoch": value["request_epoch"],
            "next_sequence": value["next_sequence"],
            "visible_chunks": value["visible_chunks"],
            "visible_units": value["visible_units"],
            "timeline_base": _time_base(value["timeline_base"]),
            "media_object_sha256": _digest(value["media_object_sha256"]),
            "timeline_sha256": _digest(
                value["timeline_sha256"], zero_allowed=True
            ),
            "previous_commit_sha256": _digest(
                value["previous_commit_sha256"]
            ),
        }
    except (KeyError, TypeError):
        raise MediaContractError("invalid publication state") from None
    for name in (
        "request_epoch",
        "next_sequence",
        "visible_chunks",
        "visible_units",
    ):
        _u64(state[name])
    if state["request_epoch"] == 0 or state["next_sequence"] == 0:
        raise MediaContractError("invalid publication state")
    empty = state["visible_chunks"] == 0
    if (
        empty
        and (
            state["visible_units"] != 0
            or state["timeline_sha256"] != ZERO_DIGEST
        )
        or not empty
        and (
            state["visible_units"] == 0
            or state["timeline_sha256"] == ZERO_DIGEST
        )
    ):
        raise MediaContractError("contradictory publication state")
    return state


def publication_state_root(value: Record) -> bytes:
    state = _publication_state(value)
    return _hash(
        PUBLICATION_STATE_DOMAIN,
        _u64(state["request_epoch"]),
        _u64(state["next_sequence"]),
        _u64(state["visible_chunks"]),
        _u64(state["visible_units"]),
        _u64(state["timeline_base"][0]),
        _u64(state["timeline_base"][1]),
        state["media_object_sha256"],
        state["timeline_sha256"],
        state["previous_commit_sha256"],
    )


def publication_root(prepared: Record) -> bytes:
    try:
        return _hash(
            PUBLICATION_DOMAIN,
            _u64(PUBLICATION_ABI),
            _digest(prepared["state_before_sha256"]),
            _u64(prepared["request_epoch"]),
            _u64(prepared["sequence"]),
            _u64(prepared["chunk_ordinal"]),
            _u64(prepared["units_before"]),
            _u64(prepared["units_after"]),
            _digest(prepared["media_object_sha256"]),
            _digest(prepared["timeline_event_sha256"]),
            _digest(prepared["output_sha256"]),
            _digest(prepared["resource_claim_sha256"]),
            _digest(prepared["previous_commit_sha256"]),
        )
    except (KeyError, TypeError):
        raise MediaContractError("invalid prepared publication") from None


def prepare_publication(
    state_value: Record,
    event_value: Record,
    output_sha256: bytes,
    resource_claim_sha256: bytes,
) -> Record:
    state = _publication_state(state_value)
    event = _event(event_value)
    event_root = timeline_event_root(event)
    if (
        event["sequence"] != state["next_sequence"]
        or event["media_object_sha256"] != state["media_object_sha256"]
        or event["previous_event_sha256"] != state["timeline_sha256"]
        or event["target"][0][1] != state["timeline_base"]
        or event["target"][1][1] != state["timeline_base"]
        or event["target"][0][0] != state["visible_units"]
        or state["next_sequence"] == U64_MAX
        or state["visible_chunks"] == U64_MAX
    ):
        raise MediaContractError("publication does not extend state")
    prepared = {
        "abi_version": PUBLICATION_ABI,
        "state_before_sha256": publication_state_root(state),
        "request_epoch": state["request_epoch"],
        "sequence": state["next_sequence"],
        "chunk_ordinal": state["visible_chunks"],
        "units_before": state["visible_units"],
        "units_after": event["target"][1][0],
        "media_object_sha256": state["media_object_sha256"],
        "timeline_event_sha256": event_root,
        "output_sha256": _digest(output_sha256),
        "resource_claim_sha256": _digest(resource_claim_sha256),
        "previous_commit_sha256": state["previous_commit_sha256"],
    }
    prepared["commit_sha256"] = publication_root(prepared)
    return prepared


def commit_publication(state_value: Record, prepared: Record) -> Record:
    state = _publication_state(state_value)
    try:
        valid = (
            prepared["abi_version"] == PUBLICATION_ABI
            and prepared["request_epoch"] == state["request_epoch"]
            and prepared["sequence"] == state["next_sequence"]
            and prepared["chunk_ordinal"] == state["visible_chunks"]
            and prepared["units_before"] == state["visible_units"]
            and prepared["units_after"] > prepared["units_before"]
            and state["next_sequence"] != U64_MAX
            and state["visible_chunks"] != U64_MAX
            and prepared["state_before_sha256"]
            == publication_state_root(state)
            and prepared["media_object_sha256"]
            == state["media_object_sha256"]
            and prepared["previous_commit_sha256"]
            == state["previous_commit_sha256"]
            and prepared["commit_sha256"] == publication_root(prepared)
        )
    except (KeyError, TypeError, MediaContractError):
        valid = False
    if not valid:
        raise MediaContractError("stale publication")
    return {
        **state,
        "next_sequence": state["next_sequence"] + 1,
        "visible_chunks": state["visible_chunks"] + 1,
        "visible_units": prepared["units_after"],
        "timeline_sha256": prepared["timeline_event_sha256"],
        "previous_commit_sha256": prepared["commit_sha256"],
    }
