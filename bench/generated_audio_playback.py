"""Independent generated-audio publication and playback-ack oracle."""

from __future__ import annotations

import hashlib
import struct
from typing import Any, Callable

from bench import media_contract as media
from bench import media_runtime_txn as resource


class GeneratedAudioPlaybackError(ValueError):
    """An audio output, playback observation, or binding is invalid."""


Record = dict[str, Any]
Validator = Callable[[Record], Record]
U64_MAX = (1 << 64) - 1
ZERO = bytes(32)

STATE_ABI = 1
STATE_BODY_BYTES = 416
STATE_BYTES = 448
STATE_MAGIC = b"GLAUDST1"
STATE_DOMAIN = b"glacier.generated-audio-state.v1"

PLAN_ABI = 1
PLAN_BODY_BYTES = 544
PLAN_BYTES = 576
PLAN_MAGIC = b"GLAUDPL1"
PLAN_DOMAIN = b"glacier.generated-audio-plan.v1"

PROVENANCE_ABI = 1
PROVENANCE_BODY_BYTES = 480
PROVENANCE_BYTES = 512
PROVENANCE_MAGIC = b"GLAUDPV1"
PROVENANCE_DOMAIN = b"glacier.generated-audio-provenance.v1"

RESULT_ABI = 1
RESULT_BODY_BYTES = 544
RESULT_BYTES = 576
RESULT_MAGIC = b"GLAUDRS1"
RESULT_DOMAIN = b"glacier.generated-audio-result.v1"

OBSERVATION_ABI = 1
OBSERVATION_BODY_BYTES = 256
OBSERVATION_BYTES = 288
OBSERVATION_MAGIC = b"GLAUDOB1"
OBSERVATION_DOMAIN = b"glacier.playback-observation.v1"

ACK_PLAN_ABI = 1
ACK_PLAN_BODY_BYTES = 416
ACK_PLAN_BYTES = 448
ACK_PLAN_MAGIC = b"GLAUDAP1"
ACK_PLAN_DOMAIN = b"glacier.playback-ack-plan.v1"

ACK_RESULT_ABI = 1
ACK_RESULT_BODY_BYTES = 480
ACK_RESULT_BYTES = 512
ACK_RESULT_MAGIC = b"GLAUDAR1"
ACK_RESULT_DOMAIN = b"glacier.playback-ack-result.v1"

RESOURCE_DOMAIN = b"glacier.generated-audio-resource.v1"
MEDIA_PROVENANCE_DOMAIN = b"glacier.generated-audio-media-provenance.v1"
TEST_SOURCE_RESULT_DOMAIN = b"glacier.generated-audio-test-source-result.v1"

RUNTIME_ABI = 1
PCM_S16LE_SEMANTIC_ABI = 1
RAW_AUDIO_CONTAINER_ID = 1
PCM_S16LE_CODEC_ID = 1
REFERENCE_RENDERER_ABI = 1
REFERENCE_RENDERER_PAYLOAD = b"pcm-s16le-v1"
REFERENCE_RENDERER_IMPLEMENTATION = hashlib.sha256(
    b"reference exact audio-token-to-pcm-s16le renderer v1"
).digest()
MAXIMUM_FRAMES_PER_CHUNK = 4096
MAXIMUM_CHANNELS = 64
MAXIMUM_SAMPLE_RATE = 768_000
MAXIMUM_SOURCE_BYTES = (
    MAXIMUM_FRAMES_PER_CHUNK * MAXIMUM_CHANNELS * 8
)
MAXIMUM_PCM_BYTES = (
    MAXIMUM_FRAMES_PER_CHUNK * MAXIMUM_CHANNELS * 2
)

STATE_SCALARS = (
    "request_epoch",
    "generation",
    "sample_rate",
    "channels",
    "bytes_per_sample",
    "next_chunk_index",
    "next_start_frame",
    "visible_chunks",
    "visible_frames",
    "acknowledged_chunks",
    "acknowledged_frames",
    "playback_sequence",
    "pending",
    "pending_chunk_index",
    "pending_start_frame",
    "pending_frame_count",
)
STATE_DIGESTS = (
    "artifact_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "previous_publication_result_sha256",
    "previous_ack_result_sha256",
    "pending_publication_result_sha256",
    "pending_output_sha256",
    "challenge_sha256",
)

PLAN_SCALARS = (
    "request_epoch",
    "generation",
    "chunk_index",
    "start_frame",
    "frame_count",
    "sample_rate",
    "channels",
    "bytes_per_sample",
    "source_output_bytes",
    "pcm_bytes",
    "maximum_output_bytes",
    "publication_sequence",
    "visible_chunks_before",
    "visible_chunks_after",
    "visible_frames_before",
    "visible_frames_after",
    "logical_units",
    "required_capabilities",
    "renderer_abi",
)
PLAN_DIGESTS = (
    "artifact_sha256",
    "source_result_sha256",
    "source_output_sha256",
    "renderer_payload_sha256",
    "renderer_implementation_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "previous_publication_result_sha256",
    "media_object_sha256",
    "state_before_sha256",
)

PROVENANCE_SCALARS = (
    "request_epoch",
    "generation",
    "chunk_index",
    "start_frame",
    "frame_count",
    "sample_rate",
    "channels",
    "bytes_per_sample",
    "source_output_bytes",
    "pcm_bytes",
    "renderer_abi",
)
PROVENANCE_DIGESTS = (
    "plan_sha256",
    "artifact_sha256",
    "source_result_sha256",
    "source_output_sha256",
    "renderer_payload_sha256",
    "renderer_implementation_sha256",
    "media_object_sha256",
    "output_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
)

RESULT_SCALARS = (
    "request_epoch",
    "generation",
    "chunk_index",
    "start_frame",
    "frame_count",
    "end_frame",
    "sample_rate",
    "channels",
    "bytes_per_sample",
    "source_output_bytes",
    "pcm_bytes",
    "publication_sequence",
    "visible_chunks_before",
    "visible_chunks_after",
    "visible_frames_before",
    "visible_frames_after",
)
RESULT_DIGESTS = (
    "plan_sha256",
    "provenance_sha256",
    "artifact_sha256",
    "source_result_sha256",
    "source_output_sha256",
    "media_object_sha256",
    "output_sha256",
    "resource_receipt_sha256",
    "state_before_sha256",
    "previous_publication_result_sha256",
    "renderer_implementation_sha256",
    "challenge_sha256",
)

OBSERVATION_SCALARS = (
    "request_epoch",
    "playback_sequence",
    "chunk_index",
    "start_frame",
    "frame_count",
    "consumed_frames",
    "sample_rate",
    "channels",
    "bytes_per_sample",
)
OBSERVATION_DIGESTS = (
    "output_sha256",
    "sink_implementation_sha256",
    "sink_instance_sha256",
    "challenge_sha256",
)

ACK_SCALARS = (
    "request_epoch",
    "generation",
    "playback_sequence",
    "chunk_index",
    "start_frame",
    "frame_count",
    "end_frame",
    "consumed_frames",
    "sample_rate",
    "channels",
    "bytes_per_sample",
    "acknowledged_chunks_before",
    "acknowledged_chunks_after",
    "acknowledged_frames_before",
    "acknowledged_frames_after",
)
ACK_PLAN_DIGESTS = (
    "state_before_sha256",
    "publication_result_sha256",
    "output_sha256",
    "sink_implementation_sha256",
    "sink_instance_sha256",
    "observation_sha256",
    "previous_ack_result_sha256",
    "challenge_sha256",
)
ACK_RESULT_DIGESTS = (
    "plan_sha256",
    "state_before_sha256",
    "publication_result_sha256",
    "output_sha256",
    "sink_implementation_sha256",
    "sink_instance_sha256",
    "observation_sha256",
    "previous_publication_result_sha256",
    "previous_ack_result_sha256",
    "challenge_sha256",
)


def sha256(value: bytes | str) -> bytes:
    if isinstance(value, str):
        value = value.encode()
    if not isinstance(value, bytes):
        raise GeneratedAudioPlaybackError("invalid hash input")
    return hashlib.sha256(value).digest()


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise GeneratedAudioPlaybackError("u64 out of range")
    return struct.pack("<Q", value)


def _checked_add(left: int, right: int) -> int:
    result = left + right
    _u64(result)
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    _u64(result)
    return result


def _digest(value: bytes, *, zero_allowed: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or not zero_allowed
        and value == ZERO
    ):
        raise GeneratedAudioPlaybackError("invalid digest")
    return value


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


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
    output[:32] = magic + _u64(abi) + _u64(total_bytes) + _u64(0)
    offset = 32
    for field in scalars:
        output[offset : offset + 8] = _u64(value[field])
        offset += 8
    for field in digests:
        output[offset : offset + 32] = _digest(
            value[field],
            zero_allowed=True,
        )
        offset += 32
    return bytes(output)


def _encode(
    value: Record,
    *,
    magic: bytes,
    abi: int,
    total_bytes: int,
    body_bytes: int,
    domain: bytes,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
    validator: Validator,
) -> bytes:
    checked = validator(value)
    body = _body(
        checked,
        magic=magic,
        abi=abi,
        total_bytes=total_bytes,
        body_bytes=body_bytes,
        scalars=scalars,
        digests=digests,
    )
    root = _root(domain, body)
    if checked[root_field] != root:
        raise GeneratedAudioPlaybackError("invalid record root")
    return body + root


def _decode(
    encoded: bytes,
    *,
    magic: bytes,
    abi: int,
    total_bytes: int,
    body_bytes: int,
    domain: bytes,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
    validator: Validator,
) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != total_bytes
        or encoded[:8] != magic
        or struct.unpack_from("<Q", encoded, 8)[0] != abi
        or struct.unpack_from("<Q", encoded, 16)[0] != total_bytes
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or encoded[body_bytes:] != _root(domain, encoded[:body_bytes])
    ):
        raise GeneratedAudioPlaybackError("invalid wire")
    offset = 32
    value: Record = {}
    for field in scalars:
        value[field] = struct.unpack_from("<Q", encoded, offset)[0]
        offset += 8
    for field in digests:
        value[field] = encoded[offset : offset + 32]
        offset += 32
    if any(encoded[offset:body_bytes]):
        raise GeneratedAudioPlaybackError("non-canonical padding")
    value[root_field] = encoded[body_bytes:]
    checked = validator(value)
    if (
        _encode(
            checked,
            magic=magic,
            abi=abi,
            total_bytes=total_bytes,
            body_bytes=body_bytes,
            domain=domain,
            scalars=scalars,
            digests=digests,
            root_field=root_field,
            validator=validator,
        )
        != encoded
    ):
        raise GeneratedAudioPlaybackError("non-canonical wire")
    return checked


def _record(
    value: Record,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
) -> Record:
    try:
        result = {
            field: value[field]
            for field in scalars + digests + (root_field,)
        }
    except (KeyError, TypeError):
        raise GeneratedAudioPlaybackError("invalid record") from None
    for field in scalars:
        _u64(result[field])
    for field in digests:
        _digest(result[field], zero_allowed=True)
    _digest(result[root_field])
    return result


def _state_body(value: Record) -> bytes:
    return _body(
        value,
        magic=STATE_MAGIC,
        abi=STATE_ABI,
        total_bytes=STATE_BYTES,
        body_bytes=STATE_BODY_BYTES,
        scalars=STATE_SCALARS,
        digests=STATE_DIGESTS,
    )


def validate_state(value: Record) -> Record:
    state = _record(value, STATE_SCALARS, STATE_DIGESTS, "state_sha256")
    if (
        state["request_epoch"] == 0
        or not 0 < state["sample_rate"] <= MAXIMUM_SAMPLE_RATE
        or not 0 < state["channels"] <= MAXIMUM_CHANNELS
        or state["bytes_per_sample"] != 2
        or state["next_chunk_index"] != state["visible_chunks"]
        or state["next_start_frame"] != state["visible_frames"]
        or state["acknowledged_chunks"] > state["visible_chunks"]
        or state["acknowledged_frames"] > state["visible_frames"]
        or state["playback_sequence"] != state["acknowledged_chunks"]
        or state["pending"] not in (0, 1)
    ):
        raise GeneratedAudioPlaybackError("invalid state")
    for field in (
        "artifact_sha256",
        "tenant_scope_sha256",
        "metadata_policy_sha256",
        "challenge_sha256",
    ):
        _digest(state[field])
    pending_fields = (
        state["pending_chunk_index"],
        state["pending_start_frame"],
        state["pending_frame_count"],
    )
    pending_roots = (
        state["pending_publication_result_sha256"],
        state["pending_output_sha256"],
    )
    if state["pending"] == 0:
        if (
            state["acknowledged_chunks"] != state["visible_chunks"]
            or state["acknowledged_frames"] != state["visible_frames"]
            or any(pending_fields)
            or pending_roots != (ZERO, ZERO)
        ):
            raise GeneratedAudioPlaybackError("invalid idle state")
    elif (
        state["pending_frame_count"] == 0
        or state["visible_chunks"]
        != _checked_add(state["acknowledged_chunks"], 1)
        or state["visible_frames"]
        != _checked_add(
            state["acknowledged_frames"],
            state["pending_frame_count"],
        )
        or state["pending_chunk_index"] != state["acknowledged_chunks"]
        or state["pending_start_frame"] != state["acknowledged_frames"]
        or ZERO in pending_roots
    ):
        raise GeneratedAudioPlaybackError("invalid pending state")
    if state["state_sha256"] != _root(STATE_DOMAIN, _state_body(state)):
        raise GeneratedAudioPlaybackError("invalid state root")
    return state


def initial_state(
    *,
    request_epoch: int,
    sample_rate: int,
    channels: int,
    artifact_sha256: bytes,
    tenant_scope_sha256: bytes,
    metadata_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    value = {
        "request_epoch": request_epoch,
        "generation": 0,
        "sample_rate": sample_rate,
        "channels": channels,
        "bytes_per_sample": 2,
        "next_chunk_index": 0,
        "next_start_frame": 0,
        "visible_chunks": 0,
        "visible_frames": 0,
        "acknowledged_chunks": 0,
        "acknowledged_frames": 0,
        "playback_sequence": 0,
        "pending": 0,
        "pending_chunk_index": 0,
        "pending_start_frame": 0,
        "pending_frame_count": 0,
        "artifact_sha256": artifact_sha256,
        "tenant_scope_sha256": tenant_scope_sha256,
        "metadata_policy_sha256": metadata_policy_sha256,
        "previous_publication_result_sha256": ZERO,
        "previous_ack_result_sha256": ZERO,
        "pending_publication_result_sha256": ZERO,
        "pending_output_sha256": ZERO,
        "challenge_sha256": challenge_sha256,
        "state_sha256": ZERO,
    }
    value["state_sha256"] = _root(STATE_DOMAIN, _state_body(value))
    return validate_state(value)


def encode_state(value: Record) -> bytes:
    return _encode(
        value,
        magic=STATE_MAGIC,
        abi=STATE_ABI,
        total_bytes=STATE_BYTES,
        body_bytes=STATE_BODY_BYTES,
        domain=STATE_DOMAIN,
        scalars=STATE_SCALARS,
        digests=STATE_DIGESTS,
        root_field="state_sha256",
        validator=validate_state,
    )


def decode_state(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=STATE_MAGIC,
        abi=STATE_ABI,
        total_bytes=STATE_BYTES,
        body_bytes=STATE_BODY_BYTES,
        domain=STATE_DOMAIN,
        scalars=STATE_SCALARS,
        digests=STATE_DIGESTS,
        root_field="state_sha256",
        validator=validate_state,
    )


def _plan_body(value: Record) -> bytes:
    return _body(
        value,
        magic=PLAN_MAGIC,
        abi=PLAN_ABI,
        total_bytes=PLAN_BYTES,
        body_bytes=PLAN_BODY_BYTES,
        scalars=PLAN_SCALARS,
        digests=PLAN_DIGESTS,
    )


def validate_plan(value: Record) -> Record:
    plan = _record(value, PLAN_SCALARS, PLAN_DIGESTS, "plan_sha256")
    samples = _checked_mul(plan["frame_count"], plan["channels"])
    pcm_bytes = _checked_mul(samples, plan["bytes_per_sample"])
    if (
        plan["request_epoch"] == 0
        or plan["generation"] == 0
        or not 0 < plan["frame_count"] <= MAXIMUM_FRAMES_PER_CHUNK
        or not 0 < plan["sample_rate"] <= MAXIMUM_SAMPLE_RATE
        or not 0 < plan["channels"] <= MAXIMUM_CHANNELS
        or plan["bytes_per_sample"] != 2
        or not 0 < plan["source_output_bytes"] <= MAXIMUM_SOURCE_BYTES
        or plan["pcm_bytes"] != pcm_bytes
        or not plan["pcm_bytes"]
        <= plan["maximum_output_bytes"]
        <= MAXIMUM_PCM_BYTES
        or plan["publication_sequence"] != plan["chunk_index"]
        or plan["visible_chunks_before"] != plan["chunk_index"]
        or plan["visible_chunks_after"]
        != _checked_add(plan["visible_chunks_before"], 1)
        or plan["visible_frames_before"] != plan["start_frame"]
        or plan["visible_frames_after"]
        != _checked_add(plan["visible_frames_before"], plan["frame_count"])
        or plan["logical_units"] != samples
        or plan["renderer_abi"] == 0
    ):
        raise GeneratedAudioPlaybackError("invalid plan")
    for field in PLAN_DIGESTS:
        if field != "previous_publication_result_sha256":
            _digest(plan[field])
    if plan["plan_sha256"] != _root(PLAN_DOMAIN, _plan_body(plan)):
        raise GeneratedAudioPlaybackError("invalid plan root")
    return plan


def make_plan(
    state_value: Record,
    *,
    frame_count: int,
    source_output_bytes: int,
    source_result_sha256: bytes,
    source_output_sha256: bytes,
    media_object_sha256: bytes,
    maximum_output_bytes: int = MAXIMUM_PCM_BYTES,
    required_capabilities: int = 0,
    renderer_abi: int = REFERENCE_RENDERER_ABI,
    renderer_payload_sha256: bytes | None = None,
    renderer_implementation_sha256: bytes = (
        REFERENCE_RENDERER_IMPLEMENTATION
    ),
) -> Record:
    state = validate_state(state_value)
    if state["pending"]:
        raise GeneratedAudioPlaybackError("playback pending")
    samples = _checked_mul(frame_count, state["channels"])
    pcm_bytes = _checked_mul(samples, state["bytes_per_sample"])
    value = {
        "request_epoch": state["request_epoch"],
        "generation": _checked_add(state["generation"], 1),
        "chunk_index": state["next_chunk_index"],
        "start_frame": state["next_start_frame"],
        "frame_count": frame_count,
        "sample_rate": state["sample_rate"],
        "channels": state["channels"],
        "bytes_per_sample": state["bytes_per_sample"],
        "source_output_bytes": source_output_bytes,
        "pcm_bytes": pcm_bytes,
        "maximum_output_bytes": maximum_output_bytes,
        "publication_sequence": state["next_chunk_index"],
        "visible_chunks_before": state["visible_chunks"],
        "visible_chunks_after": _checked_add(state["visible_chunks"], 1),
        "visible_frames_before": state["visible_frames"],
        "visible_frames_after": _checked_add(
            state["visible_frames"],
            frame_count,
        ),
        "logical_units": samples,
        "required_capabilities": required_capabilities,
        "renderer_abi": renderer_abi,
        "artifact_sha256": state["artifact_sha256"],
        "source_result_sha256": source_result_sha256,
        "source_output_sha256": source_output_sha256,
        "renderer_payload_sha256": (
            renderer_payload_sha256
            if renderer_payload_sha256 is not None
            else sha256(REFERENCE_RENDERER_PAYLOAD)
        ),
        "renderer_implementation_sha256": (
            renderer_implementation_sha256
        ),
        "tenant_scope_sha256": state["tenant_scope_sha256"],
        "metadata_policy_sha256": state["metadata_policy_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "previous_publication_result_sha256": state[
            "previous_publication_result_sha256"
        ],
        "media_object_sha256": media_object_sha256,
        "state_before_sha256": state["state_sha256"],
        "plan_sha256": ZERO,
    }
    value["plan_sha256"] = _root(PLAN_DOMAIN, _plan_body(value))
    return validate_plan(value)


def encode_plan(value: Record) -> bytes:
    return _encode(
        value,
        magic=PLAN_MAGIC,
        abi=PLAN_ABI,
        total_bytes=PLAN_BYTES,
        body_bytes=PLAN_BODY_BYTES,
        domain=PLAN_DOMAIN,
        scalars=PLAN_SCALARS,
        digests=PLAN_DIGESTS,
        root_field="plan_sha256",
        validator=validate_plan,
    )


def decode_plan(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=PLAN_MAGIC,
        abi=PLAN_ABI,
        total_bytes=PLAN_BYTES,
        body_bytes=PLAN_BODY_BYTES,
        domain=PLAN_DOMAIN,
        scalars=PLAN_SCALARS,
        digests=PLAN_DIGESTS,
        root_field="plan_sha256",
        validator=validate_plan,
    )


def _simple_record_validator(
    value: Record,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
    body_fn: Callable[[Record], bytes],
    domain: bytes,
) -> Record:
    record = _record(value, scalars, digests, root_field)
    for field in digests:
        if not field.startswith("previous_"):
            _digest(record[field])
    if record[root_field] != _root(domain, body_fn(record)):
        raise GeneratedAudioPlaybackError("invalid record root")
    return record


def _provenance_body(value: Record) -> bytes:
    return _body(
        value,
        magic=PROVENANCE_MAGIC,
        abi=PROVENANCE_ABI,
        total_bytes=PROVENANCE_BYTES,
        body_bytes=PROVENANCE_BODY_BYTES,
        scalars=PROVENANCE_SCALARS,
        digests=PROVENANCE_DIGESTS,
    )


def validate_provenance(value: Record) -> Record:
    record = _simple_record_validator(
        value,
        PROVENANCE_SCALARS,
        PROVENANCE_DIGESTS,
        "provenance_sha256",
        _provenance_body,
        PROVENANCE_DOMAIN,
    )
    if (
        record["request_epoch"] == 0
        or record["generation"] == 0
        or record["frame_count"] == 0
        or record["frame_count"] > MAXIMUM_FRAMES_PER_CHUNK
        or not 0 < record["sample_rate"] <= MAXIMUM_SAMPLE_RATE
        or not 0 < record["channels"] <= MAXIMUM_CHANNELS
        or record["bytes_per_sample"] != 2
        or not 0
        < record["source_output_bytes"]
        <= MAXIMUM_SOURCE_BYTES
        or record["pcm_bytes"]
        != _checked_mul(
            _checked_mul(record["frame_count"], record["channels"]),
            record["bytes_per_sample"],
        )
        or record["pcm_bytes"] > MAXIMUM_PCM_BYTES
        or record["renderer_abi"] == 0
    ):
        raise GeneratedAudioPlaybackError("invalid provenance")
    return record


def make_provenance(plan_value: Record, output_sha256: bytes) -> Record:
    plan = validate_plan(plan_value)
    _digest(output_sha256)
    value = {
        **{field: plan[field] for field in PROVENANCE_SCALARS},
        "plan_sha256": plan["plan_sha256"],
        "artifact_sha256": plan["artifact_sha256"],
        "source_result_sha256": plan["source_result_sha256"],
        "source_output_sha256": plan["source_output_sha256"],
        "renderer_payload_sha256": plan["renderer_payload_sha256"],
        "renderer_implementation_sha256": plan[
            "renderer_implementation_sha256"
        ],
        "media_object_sha256": plan["media_object_sha256"],
        "output_sha256": output_sha256,
        "tenant_scope_sha256": plan["tenant_scope_sha256"],
        "metadata_policy_sha256": plan["metadata_policy_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
        "provenance_sha256": ZERO,
    }
    value["provenance_sha256"] = _root(
        PROVENANCE_DOMAIN,
        _provenance_body(value),
    )
    return validate_provenance(value)


def validate_provenance_binding(
    plan_value: Record,
    provenance_value: Record,
) -> None:
    plan = validate_plan(plan_value)
    provenance = validate_provenance(provenance_value)
    if any(
        provenance[field] != plan[field]
        for field in PROVENANCE_SCALARS
    ):
        raise GeneratedAudioPlaybackError("provenance mismatch")
    plan_bound_digests = (
        "plan_sha256",
        "artifact_sha256",
        "source_result_sha256",
        "source_output_sha256",
        "renderer_payload_sha256",
        "renderer_implementation_sha256",
        "media_object_sha256",
        "tenant_scope_sha256",
        "metadata_policy_sha256",
        "challenge_sha256",
    )
    if any(
        provenance[field] != plan[field]
        for field in plan_bound_digests
    ):
        raise GeneratedAudioPlaybackError("provenance mismatch")


def encode_provenance(value: Record) -> bytes:
    return _encode(
        value,
        magic=PROVENANCE_MAGIC,
        abi=PROVENANCE_ABI,
        total_bytes=PROVENANCE_BYTES,
        body_bytes=PROVENANCE_BODY_BYTES,
        domain=PROVENANCE_DOMAIN,
        scalars=PROVENANCE_SCALARS,
        digests=PROVENANCE_DIGESTS,
        root_field="provenance_sha256",
        validator=validate_provenance,
    )


def decode_provenance(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=PROVENANCE_MAGIC,
        abi=PROVENANCE_ABI,
        total_bytes=PROVENANCE_BYTES,
        body_bytes=PROVENANCE_BODY_BYTES,
        domain=PROVENANCE_DOMAIN,
        scalars=PROVENANCE_SCALARS,
        digests=PROVENANCE_DIGESTS,
        root_field="provenance_sha256",
        validator=validate_provenance,
    )


def claim_for_plan(plan_value: Record) -> Record:
    plan = validate_plan(plan_value)
    private_bytes = _checked_add(
        plan["pcm_bytes"],
        PROVENANCE_BYTES + RESULT_BYTES,
    )
    return {
        "capsule_bytes": len(REFERENCE_RENDERER_PAYLOAD),
        "kv_bytes": 0,
        "activation_bytes": plan["source_output_bytes"],
        "partial_bytes": private_bytes,
        "logits_bytes": 0,
        "output_journal_bytes": private_bytes,
        "staging_bytes": 0,
        "device_bytes": 0,
        "io_bytes": 0,
        "queue_slots": 1,
    }


def resource_receipt_root(
    receipt_value: Record,
    request_epoch: int,
    plan_sha256: bytes,
    renderer_implementation_sha256: bytes,
) -> bytes:
    receipt = resource.resource_receipt(
        receipt_value["bank_epoch"],
        receipt_value["slot_index"],
        receipt_value["generation"],
        receipt_value["owner_key"],
        receipt_value["claim"],
    )
    if receipt != receipt_value:
        raise GeneratedAudioPlaybackError("invalid resource receipt")
    parts = (
        _u64(RUNTIME_ABI),
        _u64(request_epoch),
        _u64(receipt["bank_epoch"]),
        _u64(receipt["slot_index"]),
        _u64(receipt["generation"]),
        _u64(receipt["owner_key"]),
        *(
            _u64(receipt["claim"][field])
            for field in resource.CLAIM_FIELDS
        ),
        _u64(receipt["integrity"]),
        _digest(plan_sha256),
        _digest(renderer_implementation_sha256),
    )
    return hashlib.sha256(RESOURCE_DOMAIN + b"".join(parts)).digest()


def _result_body(value: Record) -> bytes:
    return _body(
        value,
        magic=RESULT_MAGIC,
        abi=RESULT_ABI,
        total_bytes=RESULT_BYTES,
        body_bytes=RESULT_BODY_BYTES,
        scalars=RESULT_SCALARS,
        digests=RESULT_DIGESTS,
    )


def validate_result(value: Record) -> Record:
    result = _simple_record_validator(
        value,
        RESULT_SCALARS,
        RESULT_DIGESTS,
        "result_sha256",
        _result_body,
        RESULT_DOMAIN,
    )
    if (
        result["request_epoch"] == 0
        or result["generation"] == 0
        or result["frame_count"] == 0
        or result["frame_count"] > MAXIMUM_FRAMES_PER_CHUNK
        or result["end_frame"]
        != _checked_add(result["start_frame"], result["frame_count"])
        or not 0 < result["sample_rate"] <= MAXIMUM_SAMPLE_RATE
        or not 0 < result["channels"] <= MAXIMUM_CHANNELS
        or result["bytes_per_sample"] != 2
        or not 0
        < result["source_output_bytes"]
        <= MAXIMUM_SOURCE_BYTES
        or result["pcm_bytes"]
        != _checked_mul(
            _checked_mul(result["frame_count"], result["channels"]),
            result["bytes_per_sample"],
        )
        or result["pcm_bytes"] > MAXIMUM_PCM_BYTES
        or result["publication_sequence"] != result["chunk_index"]
        or result["visible_chunks_before"] != result["chunk_index"]
        or result["visible_chunks_after"]
        != _checked_add(result["visible_chunks_before"], 1)
        or result["visible_frames_before"] != result["start_frame"]
        or result["visible_frames_after"] != result["end_frame"]
    ):
        raise GeneratedAudioPlaybackError("invalid result")
    return result


def make_result(
    plan_value: Record,
    provenance_value: Record,
    receipt_value: Record,
) -> Record:
    plan = validate_plan(plan_value)
    provenance = validate_provenance(provenance_value)
    validate_provenance_binding(plan, provenance)
    value = {
        "request_epoch": plan["request_epoch"],
        "generation": plan["generation"],
        "chunk_index": plan["chunk_index"],
        "start_frame": plan["start_frame"],
        "frame_count": plan["frame_count"],
        "end_frame": plan["visible_frames_after"],
        "sample_rate": plan["sample_rate"],
        "channels": plan["channels"],
        "bytes_per_sample": plan["bytes_per_sample"],
        "source_output_bytes": plan["source_output_bytes"],
        "pcm_bytes": plan["pcm_bytes"],
        "publication_sequence": plan["publication_sequence"],
        "visible_chunks_before": plan["visible_chunks_before"],
        "visible_chunks_after": plan["visible_chunks_after"],
        "visible_frames_before": plan["visible_frames_before"],
        "visible_frames_after": plan["visible_frames_after"],
        "plan_sha256": plan["plan_sha256"],
        "provenance_sha256": provenance["provenance_sha256"],
        "artifact_sha256": plan["artifact_sha256"],
        "source_result_sha256": plan["source_result_sha256"],
        "source_output_sha256": plan["source_output_sha256"],
        "media_object_sha256": plan["media_object_sha256"],
        "output_sha256": provenance["output_sha256"],
        "resource_receipt_sha256": resource_receipt_root(
            receipt_value,
            plan["request_epoch"],
            plan["plan_sha256"],
            plan["renderer_implementation_sha256"],
        ),
        "state_before_sha256": plan["state_before_sha256"],
        "previous_publication_result_sha256": plan[
            "previous_publication_result_sha256"
        ],
        "renderer_implementation_sha256": plan[
            "renderer_implementation_sha256"
        ],
        "challenge_sha256": plan["challenge_sha256"],
        "result_sha256": ZERO,
    }
    value["result_sha256"] = _root(RESULT_DOMAIN, _result_body(value))
    return validate_result(value)


def encode_result(value: Record) -> bytes:
    return _encode(
        value,
        magic=RESULT_MAGIC,
        abi=RESULT_ABI,
        total_bytes=RESULT_BYTES,
        body_bytes=RESULT_BODY_BYTES,
        domain=RESULT_DOMAIN,
        scalars=RESULT_SCALARS,
        digests=RESULT_DIGESTS,
        root_field="result_sha256",
        validator=validate_result,
    )


def decode_result(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=RESULT_MAGIC,
        abi=RESULT_ABI,
        total_bytes=RESULT_BYTES,
        body_bytes=RESULT_BODY_BYTES,
        domain=RESULT_DOMAIN,
        scalars=RESULT_SCALARS,
        digests=RESULT_DIGESTS,
        root_field="result_sha256",
        validator=validate_result,
    )


def state_after_publication(
    state_value: Record,
    plan_value: Record,
    result_value: Record,
) -> Record:
    state = validate_state(state_value)
    plan = validate_plan(plan_value)
    result = validate_result(result_value)
    if (
        state["pending"]
        or plan["state_before_sha256"] != state["state_sha256"]
        or result["plan_sha256"] != plan["plan_sha256"]
    ):
        raise GeneratedAudioPlaybackError("publication state mismatch")
    value = {
        **state,
        "generation": plan["generation"],
        "next_chunk_index": plan["visible_chunks_after"],
        "next_start_frame": plan["visible_frames_after"],
        "visible_chunks": plan["visible_chunks_after"],
        "visible_frames": plan["visible_frames_after"],
        "pending": 1,
        "pending_chunk_index": plan["chunk_index"],
        "pending_start_frame": plan["start_frame"],
        "pending_frame_count": plan["frame_count"],
        "pending_publication_result_sha256": result["result_sha256"],
        "pending_output_sha256": result["output_sha256"],
        "state_sha256": ZERO,
    }
    value["state_sha256"] = _root(STATE_DOMAIN, _state_body(value))
    return validate_state(value)


def render_reference_pcm(source_output: bytes) -> bytes:
    if not isinstance(source_output, bytes) or not source_output:
        raise GeneratedAudioPlaybackError("invalid source output")
    return b"".join(
        struct.pack("<h", (token - 128) * 256)
        for token in source_output
    )


def audio_media_object(
    state_value: Record,
    *,
    frame_count: int,
    output_sha256: bytes,
    source_result_sha256: bytes,
    source_output_sha256: bytes,
) -> Record:
    state = validate_state(state_value)
    provenance = hashlib.sha256(
        b"".join(
            (
                MEDIA_PROVENANCE_DOMAIN,
                _u64(RUNTIME_ABI),
                _u64(state["request_epoch"]),
                _u64(state["next_chunk_index"]),
                _u64(state["next_start_frame"]),
                _u64(frame_count),
                state["artifact_sha256"],
                source_result_sha256,
                source_output_sha256,
                REFERENCE_RENDERER_IMPLEMENTATION,
                state["challenge_sha256"],
            )
        )
    ).digest()
    pcm_bytes = _checked_mul(
        _checked_mul(frame_count, state["channels"]),
        state["bytes_per_sample"],
    )
    value = {
        "kind": media.AUDIO,
        "semantic_abi": PCM_S16LE_SEMANTIC_ABI,
        "byte_length": pcm_bytes,
        "container_id": RAW_AUDIO_CONTAINER_ID,
        "codec_id": PCM_S16LE_CODEC_ID,
        "axes": (frame_count, state["channels"], state["sample_rate"]),
        "time_base": (1, state["sample_rate"]),
        "tenant_scope_sha256": state["tenant_scope_sha256"],
        "content_sha256": output_sha256,
        "metadata_policy_sha256": state["metadata_policy_sha256"],
        "provenance_sha256": provenance,
    }
    return media.decode_media_object(media.encode_media_object(value))


def source_result_root(state_value: Record) -> bytes:
    state = validate_state(state_value)
    return hashlib.sha256(
        b"".join(
            (
                TEST_SOURCE_RESULT_DOMAIN,
                _u64(state["next_chunk_index"]),
                _u64(state["next_start_frame"]),
                state["previous_publication_result_sha256"],
            )
        )
    ).digest()


def make_reference_chunk(
    state_value: Record,
    source_output: bytes,
    receipt_value: Record,
) -> tuple[Record, Record, Record, Record, Record, bytes]:
    state = validate_state(state_value)
    pcm = render_reference_pcm(source_output)
    source_result = source_result_root(state)
    source_output_root = sha256(source_output)
    media_object = audio_media_object(
        state,
        frame_count=len(source_output) // state["channels"],
        output_sha256=sha256(pcm),
        source_result_sha256=source_result,
        source_output_sha256=source_output_root,
    )
    media_wire = media.encode_media_object(media_object)
    plan = make_plan(
        state,
        frame_count=len(source_output) // state["channels"],
        source_output_bytes=len(source_output),
        source_result_sha256=source_result,
        source_output_sha256=source_output_root,
        media_object_sha256=media.media_object_sha256(media_wire),
    )
    if receipt_value["claim"] != claim_for_plan(plan):
        raise GeneratedAudioPlaybackError("claim mismatch")
    provenance = make_provenance(plan, sha256(pcm))
    result = make_result(plan, provenance, receipt_value)
    after = state_after_publication(state, plan, result)
    return after, plan, provenance, result, media_object, pcm


def _observation_body(value: Record) -> bytes:
    return _body(
        value,
        magic=OBSERVATION_MAGIC,
        abi=OBSERVATION_ABI,
        total_bytes=OBSERVATION_BYTES,
        body_bytes=OBSERVATION_BODY_BYTES,
        scalars=OBSERVATION_SCALARS,
        digests=OBSERVATION_DIGESTS,
    )


def validate_observation(value: Record) -> Record:
    observation = _simple_record_validator(
        value,
        OBSERVATION_SCALARS,
        OBSERVATION_DIGESTS,
        "observation_sha256",
        _observation_body,
        OBSERVATION_DOMAIN,
    )
    if (
        observation["request_epoch"] == 0
        or observation["frame_count"] == 0
        or observation["consumed_frames"] != observation["frame_count"]
        or not 0 < observation["sample_rate"] <= MAXIMUM_SAMPLE_RATE
        or not 0 < observation["channels"] <= MAXIMUM_CHANNELS
        or observation["bytes_per_sample"] != 2
    ):
        raise GeneratedAudioPlaybackError("invalid observation")
    return observation


def make_observation(
    state_value: Record,
    *,
    sink_implementation_sha256: bytes,
    sink_instance_sha256: bytes,
) -> Record:
    state = validate_state(state_value)
    if not state["pending"]:
        raise GeneratedAudioPlaybackError("no playback pending")
    value = {
        "request_epoch": state["request_epoch"],
        "playback_sequence": state["playback_sequence"],
        "chunk_index": state["pending_chunk_index"],
        "start_frame": state["pending_start_frame"],
        "frame_count": state["pending_frame_count"],
        "consumed_frames": state["pending_frame_count"],
        "sample_rate": state["sample_rate"],
        "channels": state["channels"],
        "bytes_per_sample": state["bytes_per_sample"],
        "output_sha256": state["pending_output_sha256"],
        "sink_implementation_sha256": sink_implementation_sha256,
        "sink_instance_sha256": sink_instance_sha256,
        "challenge_sha256": state["challenge_sha256"],
        "observation_sha256": ZERO,
    }
    value["observation_sha256"] = _root(
        OBSERVATION_DOMAIN,
        _observation_body(value),
    )
    return validate_observation(value)


def encode_observation(value: Record) -> bytes:
    return _encode(
        value,
        magic=OBSERVATION_MAGIC,
        abi=OBSERVATION_ABI,
        total_bytes=OBSERVATION_BYTES,
        body_bytes=OBSERVATION_BODY_BYTES,
        domain=OBSERVATION_DOMAIN,
        scalars=OBSERVATION_SCALARS,
        digests=OBSERVATION_DIGESTS,
        root_field="observation_sha256",
        validator=validate_observation,
    )


def decode_observation(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=OBSERVATION_MAGIC,
        abi=OBSERVATION_ABI,
        total_bytes=OBSERVATION_BYTES,
        body_bytes=OBSERVATION_BODY_BYTES,
        domain=OBSERVATION_DOMAIN,
        scalars=OBSERVATION_SCALARS,
        digests=OBSERVATION_DIGESTS,
        root_field="observation_sha256",
        validator=validate_observation,
    )


def _ack_plan_body(value: Record) -> bytes:
    return _body(
        value,
        magic=ACK_PLAN_MAGIC,
        abi=ACK_PLAN_ABI,
        total_bytes=ACK_PLAN_BYTES,
        body_bytes=ACK_PLAN_BODY_BYTES,
        scalars=ACK_SCALARS,
        digests=ACK_PLAN_DIGESTS,
    )


def validate_ack_plan(value: Record) -> Record:
    plan = _simple_record_validator(
        value,
        ACK_SCALARS,
        ACK_PLAN_DIGESTS,
        "plan_sha256",
        _ack_plan_body,
        ACK_PLAN_DOMAIN,
    )
    if (
        plan["request_epoch"] == 0
        or plan["generation"] == 0
        or plan["frame_count"] == 0
        or plan["end_frame"]
        != _checked_add(plan["start_frame"], plan["frame_count"])
        or plan["consumed_frames"] != plan["frame_count"]
        or not 0 < plan["sample_rate"] <= MAXIMUM_SAMPLE_RATE
        or not 0 < plan["channels"] <= MAXIMUM_CHANNELS
        or plan["bytes_per_sample"] != 2
        or plan["acknowledged_chunks_after"]
        != _checked_add(plan["acknowledged_chunks_before"], 1)
        or plan["acknowledged_frames_before"] != plan["start_frame"]
        or plan["acknowledged_frames_after"] != plan["end_frame"]
    ):
        raise GeneratedAudioPlaybackError("invalid ack plan")
    return plan


def make_ack_plan(
    state_value: Record,
    publication_result_value: Record,
    observation_value: Record,
) -> Record:
    state = validate_state(state_value)
    publication_result = validate_result(publication_result_value)
    observation = validate_observation(observation_value)
    if not state["pending"]:
        raise GeneratedAudioPlaybackError("no playback pending")
    value = {
        "request_epoch": state["request_epoch"],
        "generation": _checked_add(state["generation"], 1),
        "playback_sequence": state["playback_sequence"],
        "chunk_index": state["pending_chunk_index"],
        "start_frame": state["pending_start_frame"],
        "frame_count": state["pending_frame_count"],
        "end_frame": _checked_add(
            state["acknowledged_frames"],
            state["pending_frame_count"],
        ),
        "consumed_frames": observation["consumed_frames"],
        "sample_rate": state["sample_rate"],
        "channels": state["channels"],
        "bytes_per_sample": state["bytes_per_sample"],
        "acknowledged_chunks_before": state["acknowledged_chunks"],
        "acknowledged_chunks_after": _checked_add(
            state["acknowledged_chunks"],
            1,
        ),
        "acknowledged_frames_before": state["acknowledged_frames"],
        "acknowledged_frames_after": _checked_add(
            state["acknowledged_frames"],
            state["pending_frame_count"],
        ),
        "state_before_sha256": state["state_sha256"],
        "publication_result_sha256": publication_result["result_sha256"],
        "output_sha256": state["pending_output_sha256"],
        "sink_implementation_sha256": observation[
            "sink_implementation_sha256"
        ],
        "sink_instance_sha256": observation["sink_instance_sha256"],
        "observation_sha256": observation["observation_sha256"],
        "previous_ack_result_sha256": state["previous_ack_result_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "plan_sha256": ZERO,
    }
    value["plan_sha256"] = _root(ACK_PLAN_DOMAIN, _ack_plan_body(value))
    return validate_ack_bindings(
        state,
        publication_result,
        observation,
        value,
    )


def validate_ack_bindings(
    state_value: Record,
    publication_result_value: Record,
    observation_value: Record,
    plan_value: Record,
) -> Record:
    state = validate_state(state_value)
    publication_result = validate_result(publication_result_value)
    observation = validate_observation(observation_value)
    plan = validate_ack_plan(plan_value)
    if not state["pending"]:
        raise GeneratedAudioPlaybackError("no playback pending")
    exact = (
        plan["request_epoch"] == state["request_epoch"],
        plan["generation"] == _checked_add(state["generation"], 1),
        plan["playback_sequence"] == state["playback_sequence"],
        plan["chunk_index"] == state["pending_chunk_index"],
        plan["start_frame"] == state["pending_start_frame"],
        plan["frame_count"] == state["pending_frame_count"],
        plan["sample_rate"] == state["sample_rate"],
        plan["channels"] == state["channels"],
        plan["bytes_per_sample"] == state["bytes_per_sample"],
        plan["state_before_sha256"] == state["state_sha256"],
        plan["publication_result_sha256"]
        == state["pending_publication_result_sha256"]
        == publication_result["result_sha256"],
        plan["output_sha256"]
        == state["pending_output_sha256"]
        == publication_result["output_sha256"],
        plan["previous_ack_result_sha256"]
        == state["previous_ack_result_sha256"],
        plan["challenge_sha256"] == state["challenge_sha256"],
        observation["request_epoch"] == plan["request_epoch"],
        observation["playback_sequence"] == plan["playback_sequence"],
        observation["chunk_index"] == plan["chunk_index"],
        observation["start_frame"] == plan["start_frame"],
        observation["frame_count"] == plan["frame_count"],
        observation["consumed_frames"] == plan["consumed_frames"],
        observation["sample_rate"] == plan["sample_rate"],
        observation["channels"] == plan["channels"],
        observation["bytes_per_sample"] == plan["bytes_per_sample"],
        observation["output_sha256"] == plan["output_sha256"],
        observation["sink_implementation_sha256"]
        == plan["sink_implementation_sha256"],
        observation["sink_instance_sha256"]
        == plan["sink_instance_sha256"],
        observation["observation_sha256"] == plan["observation_sha256"],
        observation["challenge_sha256"] == plan["challenge_sha256"],
        publication_result["chunk_index"] == plan["chunk_index"],
        publication_result["start_frame"] == plan["start_frame"],
        publication_result["frame_count"] == plan["frame_count"],
        publication_result["previous_publication_result_sha256"]
        == state["previous_publication_result_sha256"],
    )
    if not all(exact):
        raise GeneratedAudioPlaybackError("ack binding mismatch")
    return plan


def encode_ack_plan(value: Record) -> bytes:
    return _encode(
        value,
        magic=ACK_PLAN_MAGIC,
        abi=ACK_PLAN_ABI,
        total_bytes=ACK_PLAN_BYTES,
        body_bytes=ACK_PLAN_BODY_BYTES,
        domain=ACK_PLAN_DOMAIN,
        scalars=ACK_SCALARS,
        digests=ACK_PLAN_DIGESTS,
        root_field="plan_sha256",
        validator=validate_ack_plan,
    )


def decode_ack_plan(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=ACK_PLAN_MAGIC,
        abi=ACK_PLAN_ABI,
        total_bytes=ACK_PLAN_BYTES,
        body_bytes=ACK_PLAN_BODY_BYTES,
        domain=ACK_PLAN_DOMAIN,
        scalars=ACK_SCALARS,
        digests=ACK_PLAN_DIGESTS,
        root_field="plan_sha256",
        validator=validate_ack_plan,
    )


def _ack_result_body(value: Record) -> bytes:
    return _body(
        value,
        magic=ACK_RESULT_MAGIC,
        abi=ACK_RESULT_ABI,
        total_bytes=ACK_RESULT_BYTES,
        body_bytes=ACK_RESULT_BODY_BYTES,
        scalars=ACK_SCALARS,
        digests=ACK_RESULT_DIGESTS,
    )


def validate_ack_result(value: Record) -> Record:
    result = _simple_record_validator(
        value,
        ACK_SCALARS,
        ACK_RESULT_DIGESTS,
        "result_sha256",
        _ack_result_body,
        ACK_RESULT_DOMAIN,
    )
    if (
        result["request_epoch"] == 0
        or result["generation"] == 0
        or result["frame_count"] == 0
        or result["end_frame"]
        != _checked_add(result["start_frame"], result["frame_count"])
        or result["consumed_frames"] != result["frame_count"]
        or result["bytes_per_sample"] != 2
        or result["acknowledged_chunks_after"]
        != _checked_add(result["acknowledged_chunks_before"], 1)
        or result["acknowledged_frames_before"] != result["start_frame"]
        or result["acknowledged_frames_after"] != result["end_frame"]
    ):
        raise GeneratedAudioPlaybackError("invalid ack result")
    return result


def make_ack_result(
    state_value: Record,
    publication_result_value: Record,
    observation_value: Record,
    plan_value: Record,
) -> Record:
    state = validate_state(state_value)
    publication_result = validate_result(publication_result_value)
    observation = validate_observation(observation_value)
    plan = validate_ack_bindings(
        state,
        publication_result,
        observation,
        plan_value,
    )
    value = {
        **{field: plan[field] for field in ACK_SCALARS},
        "plan_sha256": plan["plan_sha256"],
        "state_before_sha256": state["state_sha256"],
        "publication_result_sha256": publication_result["result_sha256"],
        "output_sha256": publication_result["output_sha256"],
        "sink_implementation_sha256": observation[
            "sink_implementation_sha256"
        ],
        "sink_instance_sha256": observation["sink_instance_sha256"],
        "observation_sha256": observation["observation_sha256"],
        "previous_publication_result_sha256": state[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": state["previous_ack_result_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "result_sha256": ZERO,
    }
    value["result_sha256"] = _root(
        ACK_RESULT_DOMAIN,
        _ack_result_body(value),
    )
    return validate_ack_result(value)


def encode_ack_result(value: Record) -> bytes:
    return _encode(
        value,
        magic=ACK_RESULT_MAGIC,
        abi=ACK_RESULT_ABI,
        total_bytes=ACK_RESULT_BYTES,
        body_bytes=ACK_RESULT_BODY_BYTES,
        domain=ACK_RESULT_DOMAIN,
        scalars=ACK_SCALARS,
        digests=ACK_RESULT_DIGESTS,
        root_field="result_sha256",
        validator=validate_ack_result,
    )


def decode_ack_result(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=ACK_RESULT_MAGIC,
        abi=ACK_RESULT_ABI,
        total_bytes=ACK_RESULT_BYTES,
        body_bytes=ACK_RESULT_BODY_BYTES,
        domain=ACK_RESULT_DOMAIN,
        scalars=ACK_SCALARS,
        digests=ACK_RESULT_DIGESTS,
        root_field="result_sha256",
        validator=validate_ack_result,
    )


def state_after_ack(
    state_value: Record,
    publication_result_value: Record,
    ack_result_value: Record,
) -> Record:
    state = validate_state(state_value)
    publication_result = validate_result(publication_result_value)
    ack_result = validate_ack_result(ack_result_value)
    if (
        not state["pending"]
        or state["pending_publication_result_sha256"]
        != publication_result["result_sha256"]
        or ack_result["publication_result_sha256"]
        != publication_result["result_sha256"]
        or ack_result["state_before_sha256"] != state["state_sha256"]
    ):
        raise GeneratedAudioPlaybackError("ack state mismatch")
    value = {
        **state,
        "generation": ack_result["generation"],
        "acknowledged_chunks": ack_result["acknowledged_chunks_after"],
        "acknowledged_frames": ack_result["acknowledged_frames_after"],
        "playback_sequence": _checked_add(state["playback_sequence"], 1),
        "pending": 0,
        "pending_chunk_index": 0,
        "pending_start_frame": 0,
        "pending_frame_count": 0,
        "previous_publication_result_sha256": publication_result[
            "result_sha256"
        ],
        "previous_ack_result_sha256": ack_result["result_sha256"],
        "pending_publication_result_sha256": ZERO,
        "pending_output_sha256": ZERO,
        "state_sha256": ZERO,
    }
    value["state_sha256"] = _root(STATE_DOMAIN, _state_body(value))
    return validate_state(value)


def acknowledge(
    state_value: Record,
    publication_result_value: Record,
    observation_value: Record,
    plan_value: Record,
) -> tuple[Record, Record]:
    result = make_ack_result(
        state_value,
        publication_result_value,
        observation_value,
        plan_value,
    )
    return (
        state_after_ack(state_value, publication_result_value, result),
        result,
    )


def reference_fixture() -> Record:
    state0 = initial_state(
        request_epoch=91_001,
        sample_rate=16_000,
        channels=1,
        artifact_sha256=sha256("generated audio test artifact"),
        tenant_scope_sha256=sha256("generated audio test tenant"),
        metadata_policy_sha256=sha256("generated audio test policy"),
        challenge_sha256=sha256("generated audio test challenge"),
    )
    first_claim_placeholder = {
        field: 0 for field in resource.CLAIM_FIELDS
    }
    first_receipt = resource.resource_receipt(
        94_001,
        0,
        1,
        95_001,
        {
            **first_claim_placeholder,
            "capsule_bytes": len(REFERENCE_RENDERER_PAYLOAD),
            "activation_bytes": 2,
            "partial_bytes": 1092,
            "output_journal_bytes": 1092,
            "queue_slots": 1,
        },
    )
    state1, plan1, provenance1, result1, media1, pcm1 = (
        make_reference_chunk(state0, bytes((129, 127)), first_receipt)
    )
    sink_implementation = sha256("test playback sink implementation")
    sink_instance = sha256("test playback sink instance")
    observation1 = make_observation(
        state1,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
    )
    ack_plan1 = make_ack_plan(state1, result1, observation1)
    state2, ack1 = acknowledge(state1, result1, observation1, ack_plan1)

    second_receipt = resource.resource_receipt(
        94_001,
        0,
        2,
        95_002,
        {
            **first_claim_placeholder,
            "capsule_bytes": len(REFERENCE_RENDERER_PAYLOAD),
            "activation_bytes": 2,
            "partial_bytes": 1092,
            "output_journal_bytes": 1092,
            "queue_slots": 1,
        },
    )
    state3, plan2, provenance2, result2, media2, pcm2 = (
        make_reference_chunk(state2, bytes((130, 126)), second_receipt)
    )
    observation2 = make_observation(
        state3,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
    )
    ack_plan2 = make_ack_plan(state3, result2, observation2)
    state4, ack2 = acknowledge(state3, result2, observation2, ack_plan2)
    return {
        "state0": state0,
        "state1": state1,
        "state2": state2,
        "state3": state3,
        "state4": state4,
        "plan1": plan1,
        "provenance1": provenance1,
        "result1": result1,
        "observation1": observation1,
        "ack_plan1": ack_plan1,
        "ack1": ack1,
        "pcm1": pcm1,
        "media1": media1,
        "plan2": plan2,
        "provenance2": provenance2,
        "result2": result2,
        "observation2": observation2,
        "ack_plan2": ack_plan2,
        "ack2": ack2,
        "pcm2": pcm2,
        "media2": media2,
    }
