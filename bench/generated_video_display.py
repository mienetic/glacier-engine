"""Independent generated-video publication and display-ack oracle."""

from __future__ import annotations

import hashlib
import struct
from typing import Any, Callable

from bench import media_contract as media
from bench import media_runtime_txn as resource


class GeneratedVideoDisplayError(ValueError):
    """A video manifest, publication, or display receipt is invalid."""


Record = dict[str, Any]
Validator = Callable[[Record], Record]
U64_MAX = (1 << 64) - 1
ZERO = bytes(32)

RUNTIME_ABI = 1
RAW_VIDEO_SEMANTIC_ABI = 1
RAW_CONTAINER_ID = 1
GRAY8_FRAME_CODEC_ID = 1
REFERENCE_RENDERER_ABI = 1
REFERENCE_RENDERER_PAYLOAD = b"gray8-frame-fill-v1"
REFERENCE_RENDERER_IMPLEMENTATION = hashlib.sha256(
    b"reference exact gray8 frame-fill renderer v1"
).digest()
FRAMES_PER_SEGMENT = 2
MAXIMUM_DIMENSION = 4096
MAXIMUM_CHANNELS = 1
MAXIMUM_TIME_DENOMINATOR = 1_000_000_000
MAXIMUM_DURATION_TICKS = 1_000_000_000
MAXIMUM_SEGMENT_DURATION_TICKS = (
    MAXIMUM_DURATION_TICKS * FRAMES_PER_SEGMENT
)
MAXIMUM_SOURCE_BYTES = 16 * 1024 * 1024
MAXIMUM_OUTPUT_BYTES = 256 * 1024 * 1024

STATE_ABI = 1
STATE_BODY_BYTES = 480
STATE_BYTES = 512
STATE_MAGIC = b"GLVIDST1"
STATE_DOMAIN = b"glacier.generated-video-state.v1"

MANIFEST_ABI = 1
MANIFEST_BODY_BYTES = 704
MANIFEST_BYTES = 736
MANIFEST_MAGIC = b"GLVIDMF1"
MANIFEST_DOMAIN = b"glacier.generated-video-manifest.v1"

PROVENANCE_ABI = 1
PROVENANCE_BODY_BYTES = 608
PROVENANCE_BYTES = 640
PROVENANCE_MAGIC = b"GLVIDPV1"
PROVENANCE_DOMAIN = b"glacier.generated-video-provenance.v1"

RESULT_ABI = 1
RESULT_BODY_BYTES = 640
RESULT_BYTES = 672
RESULT_MAGIC = b"GLVIDRS1"
RESULT_DOMAIN = b"glacier.generated-video-result.v1"

OBSERVATION_ABI = 1
OBSERVATION_BODY_BYTES = 288
OBSERVATION_BYTES = 320
OBSERVATION_MAGIC = b"GLVIDOB1"
OBSERVATION_DOMAIN = b"glacier.display-observation.v1"

ACK_PLAN_ABI = 1
ACK_PLAN_BODY_BYTES = 448
ACK_PLAN_BYTES = 480
ACK_PLAN_MAGIC = b"GLVIDAP1"
ACK_PLAN_DOMAIN = b"glacier.display-ack-plan.v1"

ACK_RESULT_ABI = 1
ACK_RESULT_BODY_BYTES = 480
ACK_RESULT_BYTES = 512
ACK_RESULT_MAGIC = b"GLVIDAR1"
ACK_RESULT_DOMAIN = b"glacier.display-ack-result.v1"

SOURCE_PROVENANCE_DOMAIN = b"glacier.generated-video-source-provenance.v1"
RESOURCE_DOMAIN = b"glacier.generated-video-resource.v1"
TEST_SOURCE_RESULT_DOMAIN = b"glacier.generated-video-test-source-result.v1"

STATE_SCALARS = (
    "request_epoch",
    "generation",
    "width",
    "height",
    "channels",
    "bytes_per_channel",
    "next_segment_index",
    "next_frame_ordinal",
    "next_start_tick",
    "visible_segments",
    "visible_frames",
    "visible_end_tick",
    "displayed_segments",
    "displayed_frames",
    "displayed_end_tick",
    "display_sequence",
    "pending",
    "pending_segment_index",
    "pending_first_frame",
    "pending_frame_count",
    "pending_start_tick",
    "pending_end_tick",
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

MANIFEST_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "first_frame_ordinal",
    "frame_count",
    "width",
    "height",
    "channels",
    "bytes_per_channel",
    "row_stride",
    "frame_bytes",
    "total_output_bytes",
    "time_base_numerator",
    "time_base_denominator",
    "start_tick",
    "first_duration_ticks",
    "second_duration_ticks",
    "end_tick",
    "source_output_bytes",
    "maximum_output_bytes",
    "publication_sequence",
    "visible_segments_before",
    "visible_segments_after",
    "visible_frames_before",
    "visible_frames_after",
    "visible_end_tick_before",
    "visible_end_tick_after",
    "logical_units",
    "required_capabilities",
    "renderer_abi",
)
MANIFEST_DIGESTS = (
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
    "first_frame_sha256",
    "second_frame_sha256",
)

PROVENANCE_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "first_frame_ordinal",
    "frame_count",
    "width",
    "height",
    "channels",
    "bytes_per_channel",
    "row_stride",
    "frame_bytes",
    "total_output_bytes",
    "time_base_numerator",
    "time_base_denominator",
    "start_tick",
    "first_duration_ticks",
    "second_duration_ticks",
    "end_tick",
    "source_output_bytes",
    "renderer_abi",
)
PROVENANCE_DIGESTS = (
    "manifest_sha256",
    "artifact_sha256",
    "source_result_sha256",
    "source_output_sha256",
    "renderer_payload_sha256",
    "renderer_implementation_sha256",
    "media_object_sha256",
    "first_frame_sha256",
    "second_frame_sha256",
    "output_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
)

RESULT_SCALARS = (
    "request_epoch",
    "generation",
    "segment_index",
    "first_frame_ordinal",
    "frame_count",
    "end_frame_ordinal",
    "start_tick",
    "end_tick",
    "width",
    "height",
    "channels",
    "bytes_per_channel",
    "total_output_bytes",
    "publication_sequence",
    "visible_segments_before",
    "visible_segments_after",
    "visible_frames_before",
    "visible_frames_after",
    "visible_end_tick_before",
    "visible_end_tick_after",
)
RESULT_DIGESTS = (
    "manifest_sha256",
    "provenance_sha256",
    "artifact_sha256",
    "source_result_sha256",
    "source_output_sha256",
    "media_object_sha256",
    "first_frame_sha256",
    "second_frame_sha256",
    "output_sha256",
    "resource_receipt_sha256",
    "state_before_sha256",
    "previous_publication_result_sha256",
    "renderer_implementation_sha256",
    "challenge_sha256",
)

OBSERVATION_SCALARS = (
    "request_epoch",
    "display_sequence",
    "segment_index",
    "first_frame_ordinal",
    "frame_count",
    "consumed_frames",
    "start_tick",
    "end_tick",
    "width",
    "height",
    "channels",
    "bytes_per_channel",
)
OBSERVATION_DIGESTS = (
    "publication_result_sha256",
    "output_sha256",
    "sink_implementation_sha256",
    "sink_instance_sha256",
    "challenge_sha256",
)

ACK_SCALARS = (
    "request_epoch",
    "generation",
    "display_sequence",
    "segment_index",
    "first_frame_ordinal",
    "frame_count",
    "end_frame_ordinal",
    "start_tick",
    "end_tick",
    "consumed_frames",
    "displayed_segments_before",
    "displayed_segments_after",
    "displayed_frames_before",
    "displayed_frames_after",
    "displayed_end_tick_before",
    "displayed_end_tick_after",
)
ACK_PLAN_DIGESTS = (
    "state_before_sha256",
    "publication_result_sha256",
    "output_sha256",
    "observation_sha256",
    "sink_implementation_sha256",
    "sink_instance_sha256",
    "challenge_sha256",
    "previous_publication_result_sha256",
    "previous_ack_result_sha256",
)
ACK_RESULT_DIGESTS = (
    "plan_sha256",
    "observation_sha256",
    "state_before_sha256",
    "publication_result_sha256",
    "output_sha256",
    "sink_implementation_sha256",
    "sink_instance_sha256",
    "challenge_sha256",
    "previous_publication_result_sha256",
    "previous_ack_result_sha256",
)


def sha256(value: bytes | str) -> bytes:
    if isinstance(value, str):
        value = value.encode()
    return hashlib.sha256(value).digest()


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise GeneratedVideoDisplayError("u64 out of range")
    return struct.pack("<Q", value)


def _checked_add(left: int, right: int) -> int:
    result = left + right
    _u64(result)
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    _u64(result)
    return result


def _checked_sub(left: int, right: int) -> int:
    result = left - right
    _u64(result)
    return result


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise GeneratedVideoDisplayError("invalid digest")
    if not allow_zero and value == ZERO:
        raise GeneratedVideoDisplayError("zero digest")
    return value


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def _record(
    value: Record,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
) -> Record:
    fields = set(scalars) | set(digests) | {root_field}
    if not isinstance(value, dict) or set(value) != fields:
        raise GeneratedVideoDisplayError("record fields mismatch")
    record = dict(value)
    for field in scalars:
        _u64(record[field])
    for field in digests:
        _digest(
            record[field],
            allow_zero=field.startswith("previous_")
            or field.startswith("pending_"),
        )
    _digest(record[root_field])
    return record


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
            or field.startswith("pending_"),
        )
        offset += 32
    if offset > body_bytes:
        raise GeneratedVideoDisplayError("wire body overflow")
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
    record = validator(value)
    body = _body(
        record,
        magic=magic,
        abi=abi,
        total_bytes=total_bytes,
        body_bytes=body_bytes,
        scalars=scalars,
        digests=digests,
    )
    if record[root_field] != _root(domain, body):
        raise GeneratedVideoDisplayError("invalid record root")
    return body + record[root_field]


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
    if not isinstance(encoded, bytes) or len(encoded) != total_bytes:
        raise GeneratedVideoDisplayError("invalid wire length")
    if (
        encoded[0:8] != magic
        or struct.unpack_from("<Q", encoded, 8)[0] != abi
        or struct.unpack_from("<Q", encoded, 16)[0] != total_bytes
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
    ):
        raise GeneratedVideoDisplayError("invalid wire header")
    expected = _root(domain, encoded[:body_bytes])
    if encoded[body_bytes:] != expected:
        raise GeneratedVideoDisplayError("invalid wire root")
    offset = 32
    value: Record = {}
    for field in scalars:
        value[field] = struct.unpack_from("<Q", encoded, offset)[0]
        offset += 8
    for field in digests:
        value[field] = encoded[offset : offset + 32]
        offset += 32
    if any(encoded[offset:body_bytes]):
        raise GeneratedVideoDisplayError("nonzero reserved bytes")
    value[root_field] = encoded[body_bytes:]
    return validator(value)


def _validate_root_record(
    value: Record,
    *,
    scalars: tuple[str, ...],
    digests: tuple[str, ...],
    root_field: str,
    body_fn: Callable[[Record], bytes],
    domain: bytes,
) -> Record:
    record = _record(value, scalars, digests, root_field)
    if record[root_field] != _root(domain, body_fn(record)):
        raise GeneratedVideoDisplayError("invalid record root")
    return record


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
    state = _validate_root_record(
        value,
        scalars=STATE_SCALARS,
        digests=STATE_DIGESTS,
        root_field="state_sha256",
        body_fn=_state_body,
        domain=STATE_DOMAIN,
    )
    expected_generation = _checked_add(
        state["visible_segments"],
        state["displayed_segments"],
    )
    expected_visible_frames = _checked_mul(
        state["visible_segments"],
        FRAMES_PER_SEGMENT,
    )
    expected_displayed_frames = _checked_mul(
        state["displayed_segments"],
        FRAMES_PER_SEGMENT,
    )
    if (
        state["request_epoch"] == 0
        or state["generation"] != expected_generation
        or not 0 < state["width"] <= MAXIMUM_DIMENSION
        or not 0 < state["height"] <= MAXIMUM_DIMENSION
        or not 0 < state["channels"] <= MAXIMUM_CHANNELS
        or state["bytes_per_channel"] != 1
        or state["visible_frames"] != expected_visible_frames
        or state["displayed_frames"] != expected_displayed_frames
        or state["next_segment_index"] != state["visible_segments"]
        or state["next_frame_ordinal"] != state["visible_frames"]
        or state["next_start_tick"] != state["visible_end_tick"]
        or state["display_sequence"] != state["displayed_segments"]
        or state["displayed_segments"] > state["visible_segments"]
        or state["displayed_frames"] > state["visible_frames"]
        or state["displayed_end_tick"] > state["visible_end_tick"]
        or (state["visible_segments"] == 0)
        != (state["previous_publication_result_sha256"] == ZERO)
        or (state["displayed_segments"] == 0)
        != (state["previous_ack_result_sha256"] == ZERO)
    ):
        raise GeneratedVideoDisplayError("invalid state")
    if state["pending"] == 0:
        exact = (
            state["visible_segments"] == state["displayed_segments"],
            state["visible_frames"] == state["displayed_frames"],
            state["visible_end_tick"] == state["displayed_end_tick"],
            state["pending_segment_index"] == 0,
            state["pending_first_frame"] == 0,
            state["pending_frame_count"] == 0,
            state["pending_start_tick"] == 0,
            state["pending_end_tick"] == 0,
            state["pending_publication_result_sha256"] == ZERO,
            state["pending_output_sha256"] == ZERO,
        )
    elif state["pending"] == 1:
        pending_duration = _checked_sub(
            state["pending_end_tick"],
            state["pending_start_tick"],
        )
        exact = (
            state["pending_frame_count"] == FRAMES_PER_SEGMENT,
            state["visible_segments"]
            == _checked_add(state["displayed_segments"], 1),
            state["visible_frames"]
            == _checked_add(
                state["displayed_frames"],
                state["pending_frame_count"],
            ),
            state["pending_segment_index"] == state["displayed_segments"],
            state["pending_first_frame"] == state["displayed_frames"],
            state["pending_start_tick"] == state["displayed_end_tick"],
            state["pending_end_tick"] == state["visible_end_tick"],
            state["pending_end_tick"] > state["pending_start_tick"],
            pending_duration <= MAXIMUM_SEGMENT_DURATION_TICKS,
            state["pending_publication_result_sha256"] != ZERO,
            state["pending_output_sha256"] != ZERO,
        )
    else:
        raise GeneratedVideoDisplayError("invalid pending state")
    if not all(exact):
        raise GeneratedVideoDisplayError("state position mismatch")
    return state


def initial_state(
    *,
    request_epoch: int,
    width: int,
    height: int,
    channels: int,
    artifact_sha256: bytes,
    tenant_scope_sha256: bytes,
    metadata_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    value = {
        **{field: 0 for field in STATE_SCALARS},
        **{field: ZERO for field in STATE_DIGESTS},
        "request_epoch": request_epoch,
        "width": width,
        "height": height,
        "channels": channels,
        "bytes_per_channel": 1,
        "artifact_sha256": _digest(artifact_sha256),
        "tenant_scope_sha256": _digest(tenant_scope_sha256),
        "metadata_policy_sha256": _digest(metadata_policy_sha256),
        "challenge_sha256": _digest(challenge_sha256),
        "state_sha256": ZERO,
    }
    value["state_sha256"] = _root(STATE_DOMAIN, _state_body(value))
    return validate_state(value)


def _manifest_body(value: Record) -> bytes:
    return _body(
        value,
        magic=MANIFEST_MAGIC,
        abi=MANIFEST_ABI,
        total_bytes=MANIFEST_BYTES,
        body_bytes=MANIFEST_BODY_BYTES,
        scalars=MANIFEST_SCALARS,
        digests=MANIFEST_DIGESTS,
    )


def validate_manifest(value: Record) -> Record:
    manifest = _validate_root_record(
        value,
        scalars=MANIFEST_SCALARS,
        digests=MANIFEST_DIGESTS,
        root_field="manifest_sha256",
        body_fn=_manifest_body,
        domain=MANIFEST_DOMAIN,
    )
    row_stride = _checked_mul(
        _checked_mul(manifest["width"], manifest["channels"]),
        manifest["bytes_per_channel"],
    )
    frame_bytes = _checked_mul(row_stride, manifest["height"])
    total_bytes = _checked_mul(frame_bytes, manifest["frame_count"])
    expected_generation = _checked_add(
        _checked_mul(manifest["segment_index"], 2),
        1,
    )
    expected_first_frame = _checked_mul(
        manifest["segment_index"],
        FRAMES_PER_SEGMENT,
    )
    end_tick = _checked_add(
        _checked_add(
            manifest["start_tick"],
            manifest["first_duration_ticks"],
        ),
        manifest["second_duration_ticks"],
    )
    logical_units = _checked_mul(
        _checked_mul(
            _checked_mul(manifest["width"], manifest["height"]),
            manifest["channels"],
        ),
        manifest["frame_count"],
    )
    invalid = (
        manifest["request_epoch"] == 0
        or manifest["generation"] != expected_generation
        or manifest["frame_count"] != FRAMES_PER_SEGMENT
        or manifest["first_frame_ordinal"] != expected_first_frame
        or not 0 < manifest["width"] <= MAXIMUM_DIMENSION
        or not 0 < manifest["height"] <= MAXIMUM_DIMENSION
        or not 0 < manifest["channels"] <= MAXIMUM_CHANNELS
        or manifest["bytes_per_channel"] != 1
        or manifest["row_stride"] != row_stride
        or manifest["frame_bytes"] != frame_bytes
        or manifest["total_output_bytes"] != total_bytes
        or not 0 < total_bytes <= MAXIMUM_OUTPUT_BYTES
        or manifest["time_base_numerator"] != 1
        or not 0
        < manifest["time_base_denominator"]
        <= MAXIMUM_TIME_DENOMINATOR
        or not 0
        < manifest["first_duration_ticks"]
        <= MAXIMUM_DURATION_TICKS
        or not 0
        < manifest["second_duration_ticks"]
        <= MAXIMUM_DURATION_TICKS
        or manifest["end_tick"] != end_tick
        or not 0
        < manifest["source_output_bytes"]
        <= MAXIMUM_SOURCE_BYTES
        or not total_bytes
        <= manifest["maximum_output_bytes"]
        <= MAXIMUM_OUTPUT_BYTES
        or manifest["publication_sequence"] != manifest["segment_index"]
        or manifest["visible_segments_before"] != manifest["segment_index"]
        or manifest["visible_segments_after"]
        != _checked_add(manifest["visible_segments_before"], 1)
        or manifest["visible_frames_before"]
        != manifest["first_frame_ordinal"]
        or manifest["visible_frames_after"]
        != _checked_add(
            manifest["visible_frames_before"],
            manifest["frame_count"],
        )
        or manifest["visible_end_tick_before"] != manifest["start_tick"]
        or manifest["visible_end_tick_after"] != manifest["end_tick"]
        or manifest["logical_units"] != logical_units
        or manifest["renderer_abi"] == 0
        or (manifest["segment_index"] == 0)
        != (manifest["previous_publication_result_sha256"] == ZERO)
    )
    if invalid:
        raise GeneratedVideoDisplayError("invalid manifest")
    return manifest


def make_manifest(
    state_value: Record,
    *,
    first_duration_ticks: int,
    second_duration_ticks: int,
    source_output_bytes: int,
    source_result_sha256: bytes,
    source_output_sha256: bytes,
    media_object_sha256: bytes,
    first_frame_sha256: bytes,
    second_frame_sha256: bytes,
    maximum_renderer_output_bytes: int = MAXIMUM_OUTPUT_BYTES,
    required_capabilities: int = 0,
    renderer_abi: int = REFERENCE_RENDERER_ABI,
    renderer_payload_sha256: bytes | None = None,
    renderer_implementation_sha256: bytes = (
        REFERENCE_RENDERER_IMPLEMENTATION
    ),
) -> Record:
    state = validate_state(state_value)
    if state["pending"]:
        raise GeneratedVideoDisplayError("display pending")
    row_stride = _checked_mul(
        _checked_mul(state["width"], state["channels"]),
        state["bytes_per_channel"],
    )
    frame_bytes = _checked_mul(row_stride, state["height"])
    total_bytes = _checked_mul(frame_bytes, FRAMES_PER_SEGMENT)
    end_tick = _checked_add(
        _checked_add(state["next_start_tick"], first_duration_ticks),
        second_duration_ticks,
    )
    value = {
        "request_epoch": state["request_epoch"],
        "generation": _checked_add(state["generation"], 1),
        "segment_index": state["next_segment_index"],
        "first_frame_ordinal": state["next_frame_ordinal"],
        "frame_count": FRAMES_PER_SEGMENT,
        "width": state["width"],
        "height": state["height"],
        "channels": state["channels"],
        "bytes_per_channel": state["bytes_per_channel"],
        "row_stride": row_stride,
        "frame_bytes": frame_bytes,
        "total_output_bytes": total_bytes,
        "time_base_numerator": 1,
        "time_base_denominator": 1_000,
        "start_tick": state["next_start_tick"],
        "first_duration_ticks": first_duration_ticks,
        "second_duration_ticks": second_duration_ticks,
        "end_tick": end_tick,
        "source_output_bytes": source_output_bytes,
        "maximum_output_bytes": maximum_renderer_output_bytes,
        "publication_sequence": state["next_segment_index"],
        "visible_segments_before": state["visible_segments"],
        "visible_segments_after": _checked_add(
            state["visible_segments"], 1
        ),
        "visible_frames_before": state["visible_frames"],
        "visible_frames_after": _checked_add(
            state["visible_frames"], FRAMES_PER_SEGMENT
        ),
        "visible_end_tick_before": state["visible_end_tick"],
        "visible_end_tick_after": end_tick,
        "logical_units": _checked_mul(
            _checked_mul(
                _checked_mul(
                    state["width"],
                    state["height"],
                ),
                state["channels"],
            ),
            FRAMES_PER_SEGMENT,
        ),
        "required_capabilities": required_capabilities,
        "renderer_abi": renderer_abi,
        "artifact_sha256": state["artifact_sha256"],
        "source_result_sha256": _digest(source_result_sha256),
        "source_output_sha256": _digest(source_output_sha256),
        "renderer_payload_sha256": (
            _digest(renderer_payload_sha256)
            if renderer_payload_sha256 is not None
            else sha256(REFERENCE_RENDERER_PAYLOAD)
        ),
        "renderer_implementation_sha256": _digest(
            renderer_implementation_sha256
        ),
        "tenant_scope_sha256": state["tenant_scope_sha256"],
        "metadata_policy_sha256": state["metadata_policy_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "previous_publication_result_sha256": state[
            "previous_publication_result_sha256"
        ],
        "media_object_sha256": _digest(media_object_sha256),
        "state_before_sha256": state["state_sha256"],
        "first_frame_sha256": _digest(first_frame_sha256),
        "second_frame_sha256": _digest(second_frame_sha256),
        "manifest_sha256": ZERO,
    }
    value["manifest_sha256"] = _root(
        MANIFEST_DOMAIN,
        _manifest_body(value),
    )
    return validate_manifest(value)


def source_provenance_root(manifest_value: Record) -> bytes:
    manifest = validate_manifest(manifest_value)
    scalars = (
        "request_epoch",
        "segment_index",
        "first_frame_ordinal",
        "frame_count",
        "width",
        "height",
        "channels",
        "bytes_per_channel",
        "row_stride",
        "frame_bytes",
        "total_output_bytes",
        "time_base_numerator",
        "time_base_denominator",
        "start_tick",
        "first_duration_ticks",
        "second_duration_ticks",
        "end_tick",
        "source_output_bytes",
        "renderer_abi",
    )
    digests = (
        "artifact_sha256",
        "source_result_sha256",
        "source_output_sha256",
        "renderer_payload_sha256",
        "renderer_implementation_sha256",
        "tenant_scope_sha256",
        "metadata_policy_sha256",
        "challenge_sha256",
        "first_frame_sha256",
        "second_frame_sha256",
    )
    return hashlib.sha256(
        SOURCE_PROVENANCE_DOMAIN
        + b"".join(_u64(manifest[field]) for field in scalars)
        + b"".join(manifest[field] for field in digests)
    ).digest()


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
    provenance = _validate_root_record(
        value,
        scalars=PROVENANCE_SCALARS,
        digests=PROVENANCE_DIGESTS,
        root_field="provenance_sha256",
        body_fn=_provenance_body,
        domain=PROVENANCE_DOMAIN,
    )
    row_stride = _checked_mul(
        _checked_mul(provenance["width"], provenance["channels"]),
        provenance["bytes_per_channel"],
    )
    frame_bytes = _checked_mul(row_stride, provenance["height"])
    total_bytes = _checked_mul(frame_bytes, provenance["frame_count"])
    expected_generation = _checked_add(
        _checked_mul(provenance["segment_index"], 2),
        1,
    )
    expected_first_frame = _checked_mul(
        provenance["segment_index"],
        FRAMES_PER_SEGMENT,
    )
    end_tick = _checked_add(
        _checked_add(
            provenance["start_tick"],
            provenance["first_duration_ticks"],
        ),
        provenance["second_duration_ticks"],
    )
    if (
        provenance["request_epoch"] == 0
        or provenance["generation"] != expected_generation
        or provenance["frame_count"] != FRAMES_PER_SEGMENT
        or provenance["first_frame_ordinal"] != expected_first_frame
        or not 0 < provenance["width"] <= MAXIMUM_DIMENSION
        or not 0 < provenance["height"] <= MAXIMUM_DIMENSION
        or not 0 < provenance["channels"] <= MAXIMUM_CHANNELS
        or provenance["bytes_per_channel"] != 1
        or provenance["row_stride"] != row_stride
        or provenance["frame_bytes"] != frame_bytes
        or provenance["total_output_bytes"] != total_bytes
        or not 0 < total_bytes <= MAXIMUM_OUTPUT_BYTES
        or provenance["time_base_numerator"] != 1
        or not 0
        < provenance["time_base_denominator"]
        <= MAXIMUM_TIME_DENOMINATOR
        or provenance["first_duration_ticks"] == 0
        or provenance["first_duration_ticks"] > MAXIMUM_DURATION_TICKS
        or provenance["second_duration_ticks"] == 0
        or provenance["second_duration_ticks"] > MAXIMUM_DURATION_TICKS
        or provenance["end_tick"] != end_tick
        or not 0
        < provenance["source_output_bytes"]
        <= MAXIMUM_SOURCE_BYTES
        or provenance["renderer_abi"] == 0
    ):
        raise GeneratedVideoDisplayError("invalid provenance")
    return provenance


def make_provenance(
    manifest_value: Record,
    output_sha256: bytes,
) -> Record:
    manifest = validate_manifest(manifest_value)
    value = {
        **{field: manifest[field] for field in PROVENANCE_SCALARS},
        "manifest_sha256": manifest["manifest_sha256"],
        "artifact_sha256": manifest["artifact_sha256"],
        "source_result_sha256": manifest["source_result_sha256"],
        "source_output_sha256": manifest["source_output_sha256"],
        "renderer_payload_sha256": manifest["renderer_payload_sha256"],
        "renderer_implementation_sha256": manifest[
            "renderer_implementation_sha256"
        ],
        "media_object_sha256": manifest["media_object_sha256"],
        "first_frame_sha256": manifest["first_frame_sha256"],
        "second_frame_sha256": manifest["second_frame_sha256"],
        "output_sha256": _digest(output_sha256),
        "tenant_scope_sha256": manifest["tenant_scope_sha256"],
        "metadata_policy_sha256": manifest["metadata_policy_sha256"],
        "challenge_sha256": manifest["challenge_sha256"],
        "provenance_sha256": ZERO,
    }
    value["provenance_sha256"] = _root(
        PROVENANCE_DOMAIN,
        _provenance_body(value),
    )
    return validate_provenance(value)


def validate_provenance_binding(
    manifest_value: Record,
    provenance_value: Record,
) -> None:
    manifest = validate_manifest(manifest_value)
    provenance = validate_provenance(provenance_value)
    if any(
        provenance[field] != manifest[field]
        for field in PROVENANCE_SCALARS
    ):
        raise GeneratedVideoDisplayError("provenance scalar mismatch")
    bound = (
        "manifest_sha256",
        "artifact_sha256",
        "source_result_sha256",
        "source_output_sha256",
        "renderer_payload_sha256",
        "renderer_implementation_sha256",
        "media_object_sha256",
        "first_frame_sha256",
        "second_frame_sha256",
        "tenant_scope_sha256",
        "metadata_policy_sha256",
        "challenge_sha256",
    )
    if any(provenance[field] != manifest[field] for field in bound):
        raise GeneratedVideoDisplayError("provenance digest mismatch")


def claim_for_manifest(manifest_value: Record) -> Record:
    manifest = validate_manifest(manifest_value)
    private_bytes = _checked_add(
        manifest["total_output_bytes"],
        PROVENANCE_BYTES + RESULT_BYTES,
    )
    return {
        "capsule_bytes": len(REFERENCE_RENDERER_PAYLOAD),
        "kv_bytes": 0,
        "activation_bytes": manifest["source_output_bytes"],
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
    manifest_sha256: bytes,
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
        raise GeneratedVideoDisplayError("invalid resource receipt")
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
        _digest(manifest_sha256),
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
    result = _validate_root_record(
        value,
        scalars=RESULT_SCALARS,
        digests=RESULT_DIGESTS,
        root_field="result_sha256",
        body_fn=_result_body,
        domain=RESULT_DOMAIN,
    )
    total_output_bytes = _checked_mul(
        _checked_mul(
            _checked_mul(result["width"], result["channels"]),
            result["bytes_per_channel"],
        ),
        result["height"],
    )
    total_output_bytes = _checked_mul(
        total_output_bytes,
        result["frame_count"],
    )
    expected_generation = _checked_add(
        _checked_mul(result["segment_index"], 2),
        1,
    )
    expected_first_frame = _checked_mul(
        result["segment_index"],
        FRAMES_PER_SEGMENT,
    )
    duration = _checked_sub(result["end_tick"], result["start_tick"])
    if (
        result["request_epoch"] == 0
        or result["generation"] != expected_generation
        or result["frame_count"] != FRAMES_PER_SEGMENT
        or result["first_frame_ordinal"] != expected_first_frame
        or result["end_frame_ordinal"]
        != _checked_add(
            result["first_frame_ordinal"],
            result["frame_count"],
        )
        or result["end_tick"] <= result["start_tick"]
        or duration > MAXIMUM_SEGMENT_DURATION_TICKS
        or not 0 < result["width"] <= MAXIMUM_DIMENSION
        or not 0 < result["height"] <= MAXIMUM_DIMENSION
        or not 0 < result["channels"] <= MAXIMUM_CHANNELS
        or result["bytes_per_channel"] != 1
        or result["total_output_bytes"] != total_output_bytes
        or not 0 < result["total_output_bytes"] <= MAXIMUM_OUTPUT_BYTES
        or result["publication_sequence"] != result["segment_index"]
        or result["visible_segments_before"] != result["segment_index"]
        or result["visible_segments_after"]
        != _checked_add(result["visible_segments_before"], 1)
        or result["visible_frames_before"]
        != result["first_frame_ordinal"]
        or result["visible_frames_after"]
        != _checked_add(
            result["visible_frames_before"],
            result["frame_count"],
        )
        or result["visible_end_tick_before"] != result["start_tick"]
        or result["visible_end_tick_after"] != result["end_tick"]
        or (result["segment_index"] == 0)
        != (result["previous_publication_result_sha256"] == ZERO)
    ):
        raise GeneratedVideoDisplayError("invalid result")
    return result


def make_result(
    manifest_value: Record,
    provenance_value: Record,
    receipt_value: Record,
) -> Record:
    manifest = validate_manifest(manifest_value)
    provenance = validate_provenance(provenance_value)
    validate_provenance_binding(manifest, provenance)
    value = {
        "request_epoch": manifest["request_epoch"],
        "generation": manifest["generation"],
        "segment_index": manifest["segment_index"],
        "first_frame_ordinal": manifest["first_frame_ordinal"],
        "frame_count": manifest["frame_count"],
        "end_frame_ordinal": manifest["visible_frames_after"],
        "start_tick": manifest["start_tick"],
        "end_tick": manifest["end_tick"],
        "width": manifest["width"],
        "height": manifest["height"],
        "channels": manifest["channels"],
        "bytes_per_channel": manifest["bytes_per_channel"],
        "total_output_bytes": manifest["total_output_bytes"],
        "publication_sequence": manifest["publication_sequence"],
        "visible_segments_before": manifest["visible_segments_before"],
        "visible_segments_after": manifest["visible_segments_after"],
        "visible_frames_before": manifest["visible_frames_before"],
        "visible_frames_after": manifest["visible_frames_after"],
        "visible_end_tick_before": manifest["visible_end_tick_before"],
        "visible_end_tick_after": manifest["visible_end_tick_after"],
        "manifest_sha256": manifest["manifest_sha256"],
        "provenance_sha256": provenance["provenance_sha256"],
        "artifact_sha256": manifest["artifact_sha256"],
        "source_result_sha256": manifest["source_result_sha256"],
        "source_output_sha256": manifest["source_output_sha256"],
        "media_object_sha256": manifest["media_object_sha256"],
        "first_frame_sha256": manifest["first_frame_sha256"],
        "second_frame_sha256": manifest["second_frame_sha256"],
        "output_sha256": provenance["output_sha256"],
        "resource_receipt_sha256": resource_receipt_root(
            receipt_value,
            manifest["request_epoch"],
            manifest["manifest_sha256"],
            manifest["renderer_implementation_sha256"],
        ),
        "state_before_sha256": manifest["state_before_sha256"],
        "previous_publication_result_sha256": manifest[
            "previous_publication_result_sha256"
        ],
        "renderer_implementation_sha256": manifest[
            "renderer_implementation_sha256"
        ],
        "challenge_sha256": manifest["challenge_sha256"],
        "result_sha256": ZERO,
    }
    value["result_sha256"] = _root(RESULT_DOMAIN, _result_body(value))
    return validate_result(value)


def state_after_publication(
    state_value: Record,
    manifest_value: Record,
    result_value: Record,
) -> Record:
    state = validate_state(state_value)
    manifest = validate_manifest(manifest_value)
    result = validate_result(result_value)
    if (
        state["pending"]
        or manifest["state_before_sha256"] != state["state_sha256"]
        or result["manifest_sha256"] != manifest["manifest_sha256"]
        or result["previous_publication_result_sha256"]
        != state["previous_publication_result_sha256"]
    ):
        raise GeneratedVideoDisplayError("publication binding mismatch")
    next_state = {
        **state,
        "generation": manifest["generation"],
        "next_segment_index": manifest["visible_segments_after"],
        "next_frame_ordinal": manifest["visible_frames_after"],
        "next_start_tick": manifest["end_tick"],
        "visible_segments": manifest["visible_segments_after"],
        "visible_frames": manifest["visible_frames_after"],
        "visible_end_tick": manifest["end_tick"],
        "pending": 1,
        "pending_segment_index": manifest["segment_index"],
        "pending_first_frame": manifest["first_frame_ordinal"],
        "pending_frame_count": manifest["frame_count"],
        "pending_start_tick": manifest["start_tick"],
        "pending_end_tick": manifest["end_tick"],
        "previous_publication_result_sha256": result["result_sha256"],
        "pending_publication_result_sha256": result["result_sha256"],
        "pending_output_sha256": result["output_sha256"],
        "state_sha256": ZERO,
    }
    next_state["state_sha256"] = _root(
        STATE_DOMAIN,
        _state_body(next_state),
    )
    return validate_state(next_state)


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
    observation = _validate_root_record(
        value,
        scalars=OBSERVATION_SCALARS,
        digests=OBSERVATION_DIGESTS,
        root_field="observation_sha256",
        body_fn=_observation_body,
        domain=OBSERVATION_DOMAIN,
    )
    _checked_add(
        observation["first_frame_ordinal"],
        observation["frame_count"],
    )
    expected_first_frame = _checked_mul(
        observation["segment_index"],
        FRAMES_PER_SEGMENT,
    )
    duration = _checked_sub(
        observation["end_tick"],
        observation["start_tick"],
    )
    if (
        observation["request_epoch"] == 0
        or observation["display_sequence"] != observation["segment_index"]
        or observation["frame_count"] != FRAMES_PER_SEGMENT
        or observation["first_frame_ordinal"] != expected_first_frame
        or not 0
        < observation["consumed_frames"]
        <= observation["frame_count"]
        or observation["end_tick"] <= observation["start_tick"]
        or duration > MAXIMUM_SEGMENT_DURATION_TICKS
        or not 0 < observation["width"] <= MAXIMUM_DIMENSION
        or not 0 < observation["height"] <= MAXIMUM_DIMENSION
        or not 0 < observation["channels"] <= MAXIMUM_CHANNELS
        or observation["bytes_per_channel"] != 1
    ):
        raise GeneratedVideoDisplayError("invalid observation")
    return observation


def make_observation(
    state_value: Record,
    *,
    sink_implementation_sha256: bytes,
    sink_instance_sha256: bytes,
) -> Record:
    state = validate_state(state_value)
    if state["pending"] != 1:
        raise GeneratedVideoDisplayError("no display pending")
    value = {
        "request_epoch": state["request_epoch"],
        "display_sequence": state["display_sequence"],
        "segment_index": state["pending_segment_index"],
        "first_frame_ordinal": state["pending_first_frame"],
        "frame_count": state["pending_frame_count"],
        "consumed_frames": state["pending_frame_count"],
        "start_tick": state["pending_start_tick"],
        "end_tick": state["pending_end_tick"],
        "width": state["width"],
        "height": state["height"],
        "channels": state["channels"],
        "bytes_per_channel": state["bytes_per_channel"],
        "publication_result_sha256": state[
            "pending_publication_result_sha256"
        ],
        "output_sha256": state["pending_output_sha256"],
        "sink_implementation_sha256": _digest(
            sink_implementation_sha256
        ),
        "sink_instance_sha256": _digest(sink_instance_sha256),
        "challenge_sha256": state["challenge_sha256"],
        "observation_sha256": ZERO,
    }
    value["observation_sha256"] = _root(
        OBSERVATION_DOMAIN,
        _observation_body(value),
    )
    return validate_observation(value)


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


def _validate_ack_shape(value: Record, kind: str) -> None:
    expected_generation = _checked_mul(
        _checked_add(value["segment_index"], 1),
        2,
    )
    expected_first_frame = _checked_mul(
        value["segment_index"],
        FRAMES_PER_SEGMENT,
    )
    duration = _checked_sub(value["end_tick"], value["start_tick"])
    if (
        value["request_epoch"] == 0
        or value["generation"] != expected_generation
        or value["frame_count"] != FRAMES_PER_SEGMENT
        or value["first_frame_ordinal"] != expected_first_frame
        or value["consumed_frames"] != value["frame_count"]
        or value["end_frame_ordinal"]
        != _checked_add(
            value["first_frame_ordinal"],
            value["frame_count"],
        )
        or value["end_tick"] <= value["start_tick"]
        or duration > MAXIMUM_SEGMENT_DURATION_TICKS
        or value["display_sequence"]
        != value["displayed_segments_before"]
        or value["segment_index"] != value["displayed_segments_before"]
        or value["first_frame_ordinal"]
        != value["displayed_frames_before"]
        or value["displayed_segments_after"]
        != _checked_add(value["displayed_segments_before"], 1)
        or value["displayed_frames_after"]
        != _checked_add(
            value["displayed_frames_before"],
            value["frame_count"],
        )
        or value["displayed_end_tick_before"] != value["start_tick"]
        or value["displayed_end_tick_after"] != value["end_tick"]
        or (value["displayed_segments_before"] == 0)
        != (value["previous_ack_result_sha256"] == ZERO)
    ):
        raise GeneratedVideoDisplayError(f"invalid {kind}")


def validate_ack_plan(value: Record) -> Record:
    plan = _validate_root_record(
        value,
        scalars=ACK_SCALARS,
        digests=ACK_PLAN_DIGESTS,
        root_field="plan_sha256",
        body_fn=_ack_plan_body,
        domain=ACK_PLAN_DOMAIN,
    )
    _validate_ack_shape(plan, "ack plan")
    return plan


def make_ack_plan(
    state_value: Record,
    publication_result_value: Record,
    observation_value: Record,
) -> Record:
    state = validate_state(state_value)
    result = validate_result(publication_result_value)
    observation = validate_observation(observation_value)
    if state["pending"] != 1:
        raise GeneratedVideoDisplayError("no display pending")
    exact = (
        observation["consumed_frames"] == state["pending_frame_count"],
        observation["request_epoch"] == state["request_epoch"],
        observation["display_sequence"] == state["display_sequence"],
        observation["segment_index"] == state["pending_segment_index"],
        observation["first_frame_ordinal"]
        == state["pending_first_frame"],
        observation["frame_count"] == state["pending_frame_count"],
        observation["start_tick"] == state["pending_start_tick"],
        observation["end_tick"] == state["pending_end_tick"],
        observation["width"] == state["width"],
        observation["height"] == state["height"],
        observation["channels"] == state["channels"],
        observation["bytes_per_channel"] == state["bytes_per_channel"],
        observation["publication_result_sha256"]
        == state["pending_publication_result_sha256"],
        observation["output_sha256"] == state["pending_output_sha256"],
        observation["challenge_sha256"] == state["challenge_sha256"],
        result["result_sha256"]
        == state["pending_publication_result_sha256"],
        result["output_sha256"] == state["pending_output_sha256"],
    )
    if not all(exact):
        raise GeneratedVideoDisplayError("ack observation mismatch")
    displayed_segments_after = _checked_add(
        state["displayed_segments"], 1
    )
    displayed_frames_after = _checked_add(
        state["displayed_frames"],
        state["pending_frame_count"],
    )
    value = {
        "request_epoch": state["request_epoch"],
        "generation": _checked_add(state["generation"], 1),
        "display_sequence": state["display_sequence"],
        "segment_index": state["pending_segment_index"],
        "first_frame_ordinal": state["pending_first_frame"],
        "frame_count": state["pending_frame_count"],
        "end_frame_ordinal": displayed_frames_after,
        "start_tick": state["pending_start_tick"],
        "end_tick": state["pending_end_tick"],
        "consumed_frames": observation["consumed_frames"],
        "displayed_segments_before": state["displayed_segments"],
        "displayed_segments_after": displayed_segments_after,
        "displayed_frames_before": state["displayed_frames"],
        "displayed_frames_after": displayed_frames_after,
        "displayed_end_tick_before": state["displayed_end_tick"],
        "displayed_end_tick_after": state["pending_end_tick"],
        "state_before_sha256": state["state_sha256"],
        "publication_result_sha256": result["result_sha256"],
        "output_sha256": result["output_sha256"],
        "observation_sha256": observation["observation_sha256"],
        "sink_implementation_sha256": observation[
            "sink_implementation_sha256"
        ],
        "sink_instance_sha256": observation["sink_instance_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "previous_publication_result_sha256": state[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": state["previous_ack_result_sha256"],
        "plan_sha256": ZERO,
    }
    value["plan_sha256"] = _root(ACK_PLAN_DOMAIN, _ack_plan_body(value))
    return validate_ack_plan(value)


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
    result = _validate_root_record(
        value,
        scalars=ACK_SCALARS,
        digests=ACK_RESULT_DIGESTS,
        root_field="result_sha256",
        body_fn=_ack_result_body,
        domain=ACK_RESULT_DOMAIN,
    )
    _validate_ack_shape(result, "ack result")
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
    plan = validate_ack_plan(plan_value)
    expected = make_ack_plan(state, publication_result, observation)
    if plan != expected:
        raise GeneratedVideoDisplayError("ack plan mismatch")
    value = {
        **{field: plan[field] for field in ACK_SCALARS},
        "plan_sha256": plan["plan_sha256"],
        "observation_sha256": observation["observation_sha256"],
        "state_before_sha256": state["state_sha256"],
        "publication_result_sha256": publication_result["result_sha256"],
        "output_sha256": publication_result["output_sha256"],
        "sink_implementation_sha256": observation[
            "sink_implementation_sha256"
        ],
        "sink_instance_sha256": observation["sink_instance_sha256"],
        "challenge_sha256": state["challenge_sha256"],
        "previous_publication_result_sha256": state[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": state["previous_ack_result_sha256"],
        "result_sha256": ZERO,
    }
    value["result_sha256"] = _root(
        ACK_RESULT_DOMAIN,
        _ack_result_body(value),
    )
    return validate_ack_result(value)


def acknowledge(
    state_value: Record,
    publication_result_value: Record,
    observation_value: Record,
    plan_value: Record,
) -> tuple[Record, Record]:
    state = validate_state(state_value)
    result = make_ack_result(
        state,
        publication_result_value,
        observation_value,
        plan_value,
    )
    plan = validate_ack_plan(plan_value)
    next_state = {
        **state,
        "generation": plan["generation"],
        "displayed_segments": plan["displayed_segments_after"],
        "displayed_frames": plan["displayed_frames_after"],
        "displayed_end_tick": plan["displayed_end_tick_after"],
        "display_sequence": _checked_add(plan["display_sequence"], 1),
        "pending": 0,
        "pending_segment_index": 0,
        "pending_first_frame": 0,
        "pending_frame_count": 0,
        "pending_start_tick": 0,
        "pending_end_tick": 0,
        "pending_publication_result_sha256": ZERO,
        "pending_output_sha256": ZERO,
        "previous_ack_result_sha256": result["result_sha256"],
        "state_sha256": ZERO,
    }
    next_state["state_sha256"] = _root(
        STATE_DOMAIN,
        _state_body(next_state),
    )
    return validate_state(next_state), result


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


def encode_manifest(value: Record) -> bytes:
    return _encode(
        value,
        magic=MANIFEST_MAGIC,
        abi=MANIFEST_ABI,
        total_bytes=MANIFEST_BYTES,
        body_bytes=MANIFEST_BODY_BYTES,
        domain=MANIFEST_DOMAIN,
        scalars=MANIFEST_SCALARS,
        digests=MANIFEST_DIGESTS,
        root_field="manifest_sha256",
        validator=validate_manifest,
    )


def decode_manifest(encoded: bytes) -> Record:
    return _decode(
        encoded,
        magic=MANIFEST_MAGIC,
        abi=MANIFEST_ABI,
        total_bytes=MANIFEST_BYTES,
        body_bytes=MANIFEST_BODY_BYTES,
        domain=MANIFEST_DOMAIN,
        scalars=MANIFEST_SCALARS,
        digests=MANIFEST_DIGESTS,
        root_field="manifest_sha256",
        validator=validate_manifest,
    )


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


def render_reference_frames(source_output: bytes) -> bytes:
    if not isinstance(source_output, bytes) or len(source_output) != 2:
        raise GeneratedVideoDisplayError("invalid source output")
    return bytes((source_output[0],)) * 4 + bytes((source_output[1],)) * 4


def make_reference_chunk(
    state_value: Record,
    source_output: bytes,
    first_duration_ticks: int,
    second_duration_ticks: int,
    source_result_sha256: bytes,
    receipt_value: Record,
) -> tuple[Record, Record, Record, Record, Record, bytes]:
    state = validate_state(state_value)
    output = render_reference_frames(source_output)
    first_root = sha256(output[:4])
    second_root = sha256(output[4:])
    provisional = make_manifest(
        state,
        first_duration_ticks=first_duration_ticks,
        second_duration_ticks=second_duration_ticks,
        source_output_bytes=len(source_output),
        source_result_sha256=source_result_sha256,
        source_output_sha256=sha256(source_output),
        media_object_sha256=sha256("generated video placeholder media"),
        first_frame_sha256=first_root,
        second_frame_sha256=second_root,
        maximum_renderer_output_bytes=len(output),
    )
    media_object = {
        "kind": media.VIDEO,
        "semantic_abi": RAW_VIDEO_SEMANTIC_ABI,
        "byte_length": len(output),
        "container_id": RAW_CONTAINER_ID,
        "codec_id": GRAY8_FRAME_CODEC_ID,
        "axes": (2, 2, 2),
        "time_base": (1, 1_000),
        "tenant_scope_sha256": state["tenant_scope_sha256"],
        "content_sha256": sha256(output),
        "metadata_policy_sha256": state["metadata_policy_sha256"],
        "provenance_sha256": source_provenance_root(provisional),
    }
    media_wire = media.encode_media_object(media_object)
    manifest = make_manifest(
        state,
        first_duration_ticks=first_duration_ticks,
        second_duration_ticks=second_duration_ticks,
        source_output_bytes=len(source_output),
        source_result_sha256=source_result_sha256,
        source_output_sha256=sha256(source_output),
        media_object_sha256=media.media_object_sha256(media_wire),
        first_frame_sha256=first_root,
        second_frame_sha256=second_root,
        maximum_renderer_output_bytes=len(output),
    )
    if media_object["provenance_sha256"] != source_provenance_root(manifest):
        raise GeneratedVideoDisplayError("source provenance drift")
    if receipt_value["claim"] != claim_for_manifest(manifest):
        raise GeneratedVideoDisplayError("resource claim mismatch")
    provenance = make_provenance(manifest, sha256(output))
    result = make_result(manifest, provenance, receipt_value)
    after = state_after_publication(state, manifest, result)
    return after, manifest, provenance, result, media_object, output


def reference_fixture() -> Record:
    state0 = initial_state(
        request_epoch=81_001,
        width=2,
        height=2,
        channels=1,
        artifact_sha256=sha256("generated video test artifact"),
        tenant_scope_sha256=sha256("generated video test tenant"),
        metadata_policy_sha256=sha256(
            "generated video test metadata policy"
        ),
        challenge_sha256=sha256("generated video test challenge"),
    )
    empty_claim = {field: 0 for field in resource.CLAIM_FIELDS}
    claim = {
        **empty_claim,
        "capsule_bytes": len(REFERENCE_RENDERER_PAYLOAD),
        "activation_bytes": 2,
        "partial_bytes": 1320,
        "output_journal_bytes": 1320,
        "queue_slots": 1,
    }
    receipt1 = resource.resource_receipt(
        94_001,
        0,
        1,
        95_001,
        claim,
    )
    (
        state1,
        manifest1,
        provenance1,
        result1,
        media1,
        output1,
    ) = make_reference_chunk(
        state0,
        bytes((3, 7)),
        2,
        3,
        sha256("generated video source result zero"),
        receipt1,
    )
    sink_implementation = sha256("test display sink implementation")
    sink_instance = sha256("test display sink instance")
    observation1 = make_observation(
        state1,
        sink_implementation_sha256=sink_implementation,
        sink_instance_sha256=sink_instance,
    )
    ack_plan1 = make_ack_plan(state1, result1, observation1)
    state2, ack1 = acknowledge(state1, result1, observation1, ack_plan1)

    receipt2 = resource.resource_receipt(
        94_001,
        0,
        2,
        95_002,
        claim,
    )
    (
        state3,
        manifest2,
        provenance2,
        result2,
        media2,
        output2,
    ) = make_reference_chunk(
        state2,
        bytes((11, 13)),
        4,
        1,
        result1["result_sha256"],
        receipt2,
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
        "manifest1": manifest1,
        "manifest2": manifest2,
        "provenance1": provenance1,
        "provenance2": provenance2,
        "result1": result1,
        "result2": result2,
        "media1": media1,
        "media2": media2,
        "output1": output1,
        "output2": output2,
        "observation1": observation1,
        "observation2": observation2,
        "ack_plan1": ack_plan1,
        "ack_plan2": ack_plan2,
        "ack1": ack1,
        "ack2": ack2,
    }
