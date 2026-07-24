"""Independent structural admission for typed generated-media producer wires.

This module verifies canonical producer records, their cross-record bindings,
exact raw-output bytes, and the modality-specific post-publication shape before
building the existing generated-media output registry.  It does not attest
that a model, renderer, playback sink, display sink, or encoder actually ran.
"""

from __future__ import annotations

import hashlib
from typing import Any

from bench import generated_audio_playback as audio
from bench import generated_image_publication as image
from bench import generated_media_output_registry as registry
from bench import generated_video_display as video
from bench import media_runtime_txn as resource
from bench import model_contract as model

Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
ZERO = bytes(32)


class GeneratedMediaProducerAdmissionError(ValueError):
    """A typed producer record set or registry admission is invalid."""


ENCODING_FIELDS = {
    "encoding_abi",
    "encoded_payload",
    "encoder_implementation_sha256",
    "format_sha256",
}
IMAGE_INPUT_FIELDS = {
    "modality",
    "plan_wire",
    "provenance_wire",
    "result_wire",
    "raw_output",
    *ENCODING_FIELDS,
}
AUDIO_INPUT_FIELDS = {
    "modality",
    "state_wire",
    "plan_wire",
    "provenance_wire",
    "result_wire",
    "ack_result_wire",
    "raw_output",
    *ENCODING_FIELDS,
}
VIDEO_INPUT_FIELDS = {
    "modality",
    "state_wire",
    "manifest_wire",
    "provenance_wire",
    "result_wire",
    "ack_result_wire",
    "raw_output",
    *ENCODING_FIELDS,
}
METADATA_FIELDS = {"generation_plan_sha256"}
ENVELOPE_FIELDS = (
    "request_epoch",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
)

UPSTREAM_ERRORS = (
    audio.GeneratedAudioPlaybackError,
    image.GeneratedImagePublicationError,
    registry.GeneratedMediaOutputRegistryError,
    video.GeneratedVideoDisplayError,
)


def _exact_dict(value: Any, fields: set[str], label: str) -> Record:
    if type(value) is not dict or set(value) != fields:
        raise GeneratedMediaProducerAdmissionError(f"invalid {label} fields")
    return dict(value)


def _u64(value: Any, label: str, *, nonzero: bool = False) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise GeneratedMediaProducerAdmissionError(f"invalid {label}")
    if nonzero and value == 0:
        raise GeneratedMediaProducerAdmissionError(f"invalid {label}")
    return value


def _add(left: int, right: int, label: str) -> int:
    result = left + right
    if result > U64_MAX:
        raise GeneratedMediaProducerAdmissionError(f"{label} overflow")
    return result


def _digest(
    value: Any,
    label: str,
    *,
    zero_allowed: bool = False,
) -> bytes:
    if (
        type(value) is not bytes
        or len(value) != 32
        or (not zero_allowed and value == ZERO)
    ):
        raise GeneratedMediaProducerAdmissionError(f"invalid {label}")
    return value


def _bytes(value: Any, label: str, *, nonempty: bool = True) -> bytes:
    if type(value) is not bytes or (nonempty and not value):
        raise GeneratedMediaProducerAdmissionError(f"invalid {label}")
    return value


def _same(
    left: Record,
    right: Record,
    pairs: tuple[tuple[str, str], ...],
    label: str,
) -> None:
    if any(left[left_field] != right[right_field] for left_field, right_field in pairs):
        raise GeneratedMediaProducerAdmissionError(label)


def _encoding(value: Record) -> Record:
    return {
        "encoding_abi": _u64(
            value["encoding_abi"],
            "encoding ABI",
            nonzero=True,
        ),
        "payload": _bytes(value["encoded_payload"], "encoded payload"),
        "encoder_implementation_sha256": _digest(
            value["encoder_implementation_sha256"],
            "encoder implementation root",
        ),
        "format_sha256": _digest(
            value["format_sha256"],
            "format root",
        ),
    }


def _metadata(value: Any) -> Record:
    metadata = _exact_dict(value, METADATA_FIELDS, "registry metadata")
    metadata["generation_plan_sha256"] = _digest(
        metadata["generation_plan_sha256"],
        "generation plan root",
    )
    return metadata


def _entry(
    *,
    modality: int,
    ordinal: int,
    unit_start: int,
    unit_count: int,
    timeline_start: int,
    timeline_end: int,
    source_bytes: int,
    artifact_sha256: bytes,
    provenance_sha256: bytes,
    result_sha256: bytes,
    source_output_sha256: bytes,
    media_object_sha256: bytes,
    state_after_sha256: bytes,
    completion_sha256: bytes,
    encoding: Record,
) -> Record:
    return {
        "modality": modality,
        "ordinal": ordinal,
        "unit_start": unit_start,
        "unit_count": unit_count,
        "timeline_start": timeline_start,
        "timeline_end": timeline_end,
        "source_bytes": source_bytes,
        "encoding_abi": encoding["encoding_abi"],
        "completion_required": modality != registry.IMAGE_MODALITY,
        "completed": True,
        "artifact_sha256": artifact_sha256,
        "provenance_sha256": provenance_sha256,
        "result_sha256": result_sha256,
        "source_output_sha256": source_output_sha256,
        "media_object_sha256": media_object_sha256,
        "state_after_sha256": state_after_sha256,
        "completion_sha256": completion_sha256,
        "encoder_implementation_sha256": encoding["encoder_implementation_sha256"],
        "format_sha256": encoding["format_sha256"],
        "payload": encoding["payload"],
    }


def _image_admission(value: Any) -> tuple[Record, Record, Record]:
    producer = _exact_dict(value, IMAGE_INPUT_FIELDS, "image producer")
    if _u64(producer["modality"], "image modality") != registry.IMAGE_MODALITY:
        raise GeneratedMediaProducerAdmissionError("invalid image modality")
    plan = image.decode_plan(_bytes(producer["plan_wire"], "image plan wire"))
    provenance = image.decode_provenance(
        _bytes(producer["provenance_wire"], "image provenance wire")
    )
    result = image.decode_result(_bytes(producer["result_wire"], "image result wire"))
    raw_output = _bytes(producer["raw_output"], "image raw output")
    encoding = _encoding(producer)

    _same(
        provenance,
        plan,
        tuple((field, field) for field in image.PROVENANCE_SCALARS),
        "image provenance scalar mismatch",
    )
    _same(
        provenance,
        plan,
        tuple(
            (field, field)
            for field in (
                "artifact_sha256",
                "terminal_result_sha256",
                "terminal_plan_sha256",
                "terminal_output_sha256",
                "terminal_state_publication_sha256",
                "stateful_checkpoint_sha256",
                "decoder_payload_sha256",
                "decoder_implementation_sha256",
                "media_object_sha256",
                "tenant_scope_sha256",
                "metadata_policy_sha256",
                "source_provenance_sha256",
                "challenge_sha256",
            )
        )
        + (("plan_sha256", "plan_sha256"),),
        "image provenance digest mismatch",
    )
    _same(
        result,
        plan,
        (
            ("request_epoch", "request_epoch"),
            ("generation", "generation"),
            ("image_index", "image_index"),
            ("source_step", "source_step"),
            ("width", "width"),
            ("height", "height"),
            ("channels", "channels"),
            ("row_stride", "row_stride"),
            ("pixel_bytes", "pixel_bytes"),
            ("publication_sequence", "publication_sequence"),
            ("visible_images_before", "visible_images_before"),
            ("visible_images_after", "visible_images_after"),
            ("logical_units", "logical_units"),
            ("decoder_abi", "decoder_abi"),
            ("plan_sha256", "plan_sha256"),
            ("artifact_sha256", "artifact_sha256"),
            ("terminal_result_sha256", "terminal_result_sha256"),
            ("terminal_output_sha256", "terminal_output_sha256"),
            (
                "terminal_state_publication_sha256",
                "terminal_state_publication_sha256",
            ),
            ("media_object_sha256", "media_object_sha256"),
            ("previous_result_sha256", "previous_result_sha256"),
            (
                "decoder_implementation_sha256",
                "decoder_implementation_sha256",
            ),
            ("challenge_sha256", "challenge_sha256"),
        ),
        "image result mismatch",
    )
    if (
        result["provenance_sha256"] != provenance["provenance_sha256"]
        or result["output_sha256"] != provenance["output_sha256"]
        or len(raw_output) != result["pixel_bytes"]
        or model.sha256(raw_output) != result["output_sha256"]
    ):
        raise GeneratedMediaProducerAdmissionError("image output binding mismatch")
    ordinal = result["image_index"] - 1
    if ordinal != result["visible_images_before"] or result[
        "visible_images_after"
    ] != _add(ordinal, 1, "image ordinal"):
        raise GeneratedMediaProducerAdmissionError("image registry position mismatch")
    entry = _entry(
        modality=registry.IMAGE_MODALITY,
        ordinal=ordinal,
        unit_start=result["visible_images_before"],
        unit_count=result["logical_units"],
        timeline_start=result["visible_images_before"],
        timeline_end=result["visible_images_after"],
        source_bytes=result["pixel_bytes"],
        artifact_sha256=result["artifact_sha256"],
        provenance_sha256=result["provenance_sha256"],
        result_sha256=result["result_sha256"],
        source_output_sha256=result["output_sha256"],
        media_object_sha256=result["media_object_sha256"],
        state_after_sha256=result["publication_state_after_sha256"],
        completion_sha256=ZERO,
        encoding=encoding,
    )
    envelope = {
        "request_epoch": result["request_epoch"],
        "tenant_scope_sha256": plan["tenant_scope_sha256"],
        "metadata_policy_sha256": plan["metadata_policy_sha256"],
        "challenge_sha256": result["challenge_sha256"],
    }
    lineage = {
        "state_before_sha256": result["publication_state_before_sha256"],
        "previous_result_sha256": result["previous_result_sha256"],
        "previous_completion_sha256": ZERO,
    }
    return entry, envelope, lineage


def _audio_completion_is_exact(
    state: Record,
    result: Record,
    acknowledgement: Record,
) -> bool:
    before = {
        **state,
        "generation": result["generation"] - 1,
        "next_chunk_index": result["chunk_index"],
        "next_start_frame": result["start_frame"],
        "visible_chunks": result["visible_chunks_before"],
        "visible_frames": result["visible_frames_before"],
        "acknowledged_chunks": result["visible_chunks_before"],
        "acknowledged_frames": result["visible_frames_before"],
        "playback_sequence": result["chunk_index"],
        "pending": 0,
        "pending_chunk_index": 0,
        "pending_start_frame": 0,
        "pending_frame_count": 0,
        "previous_publication_result_sha256": result[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": acknowledgement["previous_ack_result_sha256"],
        "pending_publication_result_sha256": ZERO,
        "pending_output_sha256": ZERO,
        "state_sha256": ZERO,
    }
    before["state_sha256"] = audio._root(
        audio.STATE_DOMAIN,
        audio._state_body(before),
    )
    before = audio.validate_state(before)
    if before["state_sha256"] != result["state_before_sha256"]:
        return False

    pending = {
        **state,
        "generation": result["generation"],
        "acknowledged_chunks": acknowledgement["acknowledged_chunks_before"],
        "acknowledged_frames": acknowledgement["acknowledged_frames_before"],
        "playback_sequence": acknowledgement["playback_sequence"],
        "pending": 1,
        "pending_chunk_index": result["chunk_index"],
        "pending_start_frame": result["start_frame"],
        "pending_frame_count": result["frame_count"],
        "previous_publication_result_sha256": result[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": acknowledgement["previous_ack_result_sha256"],
        "pending_publication_result_sha256": result["result_sha256"],
        "pending_output_sha256": result["output_sha256"],
        "state_sha256": ZERO,
    }
    pending["state_sha256"] = audio._root(
        audio.STATE_DOMAIN,
        audio._state_body(pending),
    )
    pending = audio.validate_state(pending)
    observation = audio.make_observation(
        pending,
        sink_implementation_sha256=acknowledgement["sink_implementation_sha256"],
        sink_instance_sha256=acknowledgement["sink_instance_sha256"],
    )
    plan = audio.make_ack_plan(pending, result, observation)
    expected_state, expected_acknowledgement = audio.acknowledge(
        pending,
        result,
        observation,
        plan,
    )
    return expected_state == state and expected_acknowledgement == acknowledgement


def _video_completion_is_exact(
    state: Record,
    result: Record,
    acknowledgement: Record,
) -> bool:
    before = {
        **state,
        "generation": result["generation"] - 1,
        "next_segment_index": result["segment_index"],
        "next_frame_ordinal": result["first_frame_ordinal"],
        "next_start_tick": result["start_tick"],
        "visible_segments": result["visible_segments_before"],
        "visible_frames": result["visible_frames_before"],
        "visible_end_tick": result["visible_end_tick_before"],
        "displayed_segments": result["visible_segments_before"],
        "displayed_frames": result["visible_frames_before"],
        "displayed_end_tick": result["visible_end_tick_before"],
        "display_sequence": result["segment_index"],
        "pending": 0,
        "pending_segment_index": 0,
        "pending_first_frame": 0,
        "pending_frame_count": 0,
        "pending_start_tick": 0,
        "pending_end_tick": 0,
        "previous_publication_result_sha256": result[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": acknowledgement["previous_ack_result_sha256"],
        "pending_publication_result_sha256": ZERO,
        "pending_output_sha256": ZERO,
        "state_sha256": ZERO,
    }
    before["state_sha256"] = video._root(
        video.STATE_DOMAIN,
        video._state_body(before),
    )
    before = video.validate_state(before)
    if before["state_sha256"] != result["state_before_sha256"]:
        return False

    pending = {
        **state,
        "generation": result["generation"],
        "displayed_segments": acknowledgement["displayed_segments_before"],
        "displayed_frames": acknowledgement["displayed_frames_before"],
        "displayed_end_tick": acknowledgement["displayed_end_tick_before"],
        "display_sequence": acknowledgement["display_sequence"],
        "pending": 1,
        "pending_segment_index": result["segment_index"],
        "pending_first_frame": result["first_frame_ordinal"],
        "pending_frame_count": result["frame_count"],
        "pending_start_tick": result["start_tick"],
        "pending_end_tick": result["end_tick"],
        "previous_publication_result_sha256": result["result_sha256"],
        "previous_ack_result_sha256": acknowledgement["previous_ack_result_sha256"],
        "pending_publication_result_sha256": result["result_sha256"],
        "pending_output_sha256": result["output_sha256"],
        "state_sha256": ZERO,
    }
    pending["state_sha256"] = video._root(
        video.STATE_DOMAIN,
        video._state_body(pending),
    )
    pending = video.validate_state(pending)
    observation = video.make_observation(
        pending,
        sink_implementation_sha256=acknowledgement["sink_implementation_sha256"],
        sink_instance_sha256=acknowledgement["sink_instance_sha256"],
    )
    plan = video.make_ack_plan(pending, result, observation)
    expected_state, expected_acknowledgement = video.acknowledge(
        pending,
        result,
        observation,
        plan,
    )
    return expected_state == state and expected_acknowledgement == acknowledgement


def _audio_admission(value: Any) -> tuple[Record, Record, Record]:
    producer = _exact_dict(value, AUDIO_INPUT_FIELDS, "audio producer")
    if _u64(producer["modality"], "audio modality") != registry.AUDIO_MODALITY:
        raise GeneratedMediaProducerAdmissionError("invalid audio modality")
    state = audio.decode_state(_bytes(producer["state_wire"], "audio state wire"))
    plan = audio.decode_plan(_bytes(producer["plan_wire"], "audio plan wire"))
    provenance = audio.decode_provenance(
        _bytes(producer["provenance_wire"], "audio provenance wire")
    )
    result = audio.decode_result(_bytes(producer["result_wire"], "audio result wire"))
    acknowledgement = audio.decode_ack_result(
        _bytes(producer["ack_result_wire"], "audio acknowledgement wire")
    )
    raw_output = _bytes(producer["raw_output"], "audio raw output")
    encoding = _encoding(producer)
    audio.validate_provenance_binding(plan, provenance)

    _same(
        result,
        plan,
        (
            ("request_epoch", "request_epoch"),
            ("generation", "generation"),
            ("chunk_index", "chunk_index"),
            ("start_frame", "start_frame"),
            ("frame_count", "frame_count"),
            ("end_frame", "visible_frames_after"),
            ("sample_rate", "sample_rate"),
            ("channels", "channels"),
            ("bytes_per_sample", "bytes_per_sample"),
            ("source_output_bytes", "source_output_bytes"),
            ("pcm_bytes", "pcm_bytes"),
            ("publication_sequence", "publication_sequence"),
            ("visible_chunks_before", "visible_chunks_before"),
            ("visible_chunks_after", "visible_chunks_after"),
            ("visible_frames_before", "visible_frames_before"),
            ("visible_frames_after", "visible_frames_after"),
            ("plan_sha256", "plan_sha256"),
            ("artifact_sha256", "artifact_sha256"),
            ("source_result_sha256", "source_result_sha256"),
            ("source_output_sha256", "source_output_sha256"),
            ("media_object_sha256", "media_object_sha256"),
            ("state_before_sha256", "state_before_sha256"),
            (
                "previous_publication_result_sha256",
                "previous_publication_result_sha256",
            ),
            (
                "renderer_implementation_sha256",
                "renderer_implementation_sha256",
            ),
            ("challenge_sha256", "challenge_sha256"),
        ),
        "audio result mismatch",
    )
    acknowledged_generation = _add(
        result["generation"],
        1,
        "audio acknowledgement generation",
    )
    _same(
        acknowledgement,
        result,
        (
            ("request_epoch", "request_epoch"),
            ("playback_sequence", "chunk_index"),
            ("chunk_index", "chunk_index"),
            ("start_frame", "start_frame"),
            ("frame_count", "frame_count"),
            ("end_frame", "end_frame"),
            ("sample_rate", "sample_rate"),
            ("channels", "channels"),
            ("bytes_per_sample", "bytes_per_sample"),
            ("acknowledged_chunks_before", "visible_chunks_before"),
            ("acknowledged_chunks_after", "visible_chunks_after"),
            ("acknowledged_frames_before", "visible_frames_before"),
            ("acknowledged_frames_after", "visible_frames_after"),
            ("publication_result_sha256", "result_sha256"),
            ("output_sha256", "output_sha256"),
            ("challenge_sha256", "challenge_sha256"),
            (
                "previous_publication_result_sha256",
                "previous_publication_result_sha256",
            ),
        ),
        "audio acknowledgement mismatch",
    )
    if (
        result["provenance_sha256"] != provenance["provenance_sha256"]
        or result["output_sha256"] != provenance["output_sha256"]
        or acknowledgement["generation"] != acknowledged_generation
        or state["pending"] != 0
        or state["request_epoch"] != result["request_epoch"]
        or state["generation"] != acknowledgement["generation"]
        or state["sample_rate"] != result["sample_rate"]
        or state["channels"] != result["channels"]
        or state["bytes_per_sample"] != result["bytes_per_sample"]
        or state["next_chunk_index"] != result["visible_chunks_after"]
        or state["next_start_frame"] != result["visible_frames_after"]
        or state["visible_chunks"] != result["visible_chunks_after"]
        or state["visible_frames"] != result["visible_frames_after"]
        or state["acknowledged_chunks"] != result["visible_chunks_after"]
        or state["acknowledged_frames"] != result["visible_frames_after"]
        or state["playback_sequence"] != acknowledgement["acknowledged_chunks_after"]
        or state["artifact_sha256"] != result["artifact_sha256"]
        or state["tenant_scope_sha256"] != plan["tenant_scope_sha256"]
        or state["metadata_policy_sha256"] != plan["metadata_policy_sha256"]
        or state["challenge_sha256"] != result["challenge_sha256"]
        or state["previous_publication_result_sha256"] != result["result_sha256"]
        or state["previous_ack_result_sha256"] != acknowledgement["result_sha256"]
        or (result["chunk_index"] == 0)
        != (acknowledgement["previous_ack_result_sha256"] == ZERO)
        or len(raw_output) != result["pcm_bytes"]
        or audio.sha256(raw_output) != result["output_sha256"]
        or not _audio_completion_is_exact(state, result, acknowledgement)
    ):
        raise GeneratedMediaProducerAdmissionError(
            "audio post-acknowledgement binding mismatch"
        )
    entry = _entry(
        modality=registry.AUDIO_MODALITY,
        ordinal=result["chunk_index"],
        unit_start=result["start_frame"],
        unit_count=result["frame_count"],
        timeline_start=result["start_frame"],
        timeline_end=result["end_frame"],
        source_bytes=result["pcm_bytes"],
        artifact_sha256=result["artifact_sha256"],
        provenance_sha256=result["provenance_sha256"],
        result_sha256=result["result_sha256"],
        source_output_sha256=result["output_sha256"],
        media_object_sha256=result["media_object_sha256"],
        state_after_sha256=state["state_sha256"],
        completion_sha256=acknowledgement["result_sha256"],
        encoding=encoding,
    )
    envelope = {
        "request_epoch": result["request_epoch"],
        "tenant_scope_sha256": state["tenant_scope_sha256"],
        "metadata_policy_sha256": state["metadata_policy_sha256"],
        "challenge_sha256": state["challenge_sha256"],
    }
    lineage = {
        "state_before_sha256": result["state_before_sha256"],
        "previous_result_sha256": result["previous_publication_result_sha256"],
        "previous_completion_sha256": acknowledgement["previous_ack_result_sha256"],
    }
    return entry, envelope, lineage


def _video_admission(value: Any) -> tuple[Record, Record, Record]:
    producer = _exact_dict(value, VIDEO_INPUT_FIELDS, "video producer")
    if _u64(producer["modality"], "video modality") != registry.VIDEO_MODALITY:
        raise GeneratedMediaProducerAdmissionError("invalid video modality")
    state = video.decode_state(_bytes(producer["state_wire"], "video state wire"))
    manifest = video.decode_manifest(
        _bytes(producer["manifest_wire"], "video manifest wire")
    )
    provenance = video.decode_provenance(
        _bytes(producer["provenance_wire"], "video provenance wire")
    )
    result = video.decode_result(_bytes(producer["result_wire"], "video result wire"))
    acknowledgement = video.decode_ack_result(
        _bytes(producer["ack_result_wire"], "video acknowledgement wire")
    )
    raw_output = _bytes(producer["raw_output"], "video raw output")
    encoding = _encoding(producer)
    video.validate_provenance_binding(manifest, provenance)

    _same(
        result,
        manifest,
        (
            ("request_epoch", "request_epoch"),
            ("generation", "generation"),
            ("segment_index", "segment_index"),
            ("first_frame_ordinal", "first_frame_ordinal"),
            ("frame_count", "frame_count"),
            ("end_frame_ordinal", "visible_frames_after"),
            ("start_tick", "start_tick"),
            ("end_tick", "end_tick"),
            ("width", "width"),
            ("height", "height"),
            ("channels", "channels"),
            ("bytes_per_channel", "bytes_per_channel"),
            ("total_output_bytes", "total_output_bytes"),
            ("publication_sequence", "publication_sequence"),
            ("visible_segments_before", "visible_segments_before"),
            ("visible_segments_after", "visible_segments_after"),
            ("visible_frames_before", "visible_frames_before"),
            ("visible_frames_after", "visible_frames_after"),
            ("visible_end_tick_before", "visible_end_tick_before"),
            ("visible_end_tick_after", "visible_end_tick_after"),
            ("manifest_sha256", "manifest_sha256"),
            ("artifact_sha256", "artifact_sha256"),
            ("source_result_sha256", "source_result_sha256"),
            ("source_output_sha256", "source_output_sha256"),
            ("media_object_sha256", "media_object_sha256"),
            ("first_frame_sha256", "first_frame_sha256"),
            ("second_frame_sha256", "second_frame_sha256"),
            ("state_before_sha256", "state_before_sha256"),
            (
                "previous_publication_result_sha256",
                "previous_publication_result_sha256",
            ),
            (
                "renderer_implementation_sha256",
                "renderer_implementation_sha256",
            ),
            ("challenge_sha256", "challenge_sha256"),
        ),
        "video result mismatch",
    )
    acknowledged_generation = _add(
        result["generation"],
        1,
        "video acknowledgement generation",
    )
    _same(
        acknowledgement,
        result,
        (
            ("request_epoch", "request_epoch"),
            ("display_sequence", "segment_index"),
            ("segment_index", "segment_index"),
            ("first_frame_ordinal", "first_frame_ordinal"),
            ("frame_count", "frame_count"),
            ("end_frame_ordinal", "end_frame_ordinal"),
            ("start_tick", "start_tick"),
            ("end_tick", "end_tick"),
            ("displayed_segments_before", "visible_segments_before"),
            ("displayed_segments_after", "visible_segments_after"),
            ("displayed_frames_before", "visible_frames_before"),
            ("displayed_frames_after", "visible_frames_after"),
            ("displayed_end_tick_before", "visible_end_tick_before"),
            ("displayed_end_tick_after", "visible_end_tick_after"),
            ("publication_result_sha256", "result_sha256"),
            ("output_sha256", "output_sha256"),
            ("challenge_sha256", "challenge_sha256"),
        ),
        "video acknowledgement mismatch",
    )
    if (
        result["provenance_sha256"] != provenance["provenance_sha256"]
        or result["output_sha256"] != provenance["output_sha256"]
        or acknowledgement["generation"] != acknowledged_generation
        or acknowledgement["previous_publication_result_sha256"]
        != result["result_sha256"]
        or state["pending"] != 0
        or state["request_epoch"] != result["request_epoch"]
        or state["generation"] != acknowledgement["generation"]
        or state["width"] != result["width"]
        or state["height"] != result["height"]
        or state["channels"] != result["channels"]
        or state["bytes_per_channel"] != result["bytes_per_channel"]
        or state["next_segment_index"] != result["visible_segments_after"]
        or state["next_frame_ordinal"] != result["visible_frames_after"]
        or state["next_start_tick"] != result["visible_end_tick_after"]
        or state["visible_segments"] != result["visible_segments_after"]
        or state["visible_frames"] != result["visible_frames_after"]
        or state["visible_end_tick"] != result["visible_end_tick_after"]
        or state["displayed_segments"] != result["visible_segments_after"]
        or state["displayed_frames"] != result["visible_frames_after"]
        or state["displayed_end_tick"] != result["visible_end_tick_after"]
        or state["display_sequence"] != acknowledgement["displayed_segments_after"]
        or state["artifact_sha256"] != result["artifact_sha256"]
        or state["tenant_scope_sha256"] != manifest["tenant_scope_sha256"]
        or state["metadata_policy_sha256"] != manifest["metadata_policy_sha256"]
        or state["challenge_sha256"] != result["challenge_sha256"]
        or state["previous_publication_result_sha256"] != result["result_sha256"]
        or state["previous_ack_result_sha256"] != acknowledgement["result_sha256"]
        or (result["segment_index"] == 0)
        != (acknowledgement["previous_ack_result_sha256"] == ZERO)
        or len(raw_output) != result["total_output_bytes"]
        or video.sha256(raw_output) != result["output_sha256"]
        or not _video_completion_is_exact(state, result, acknowledgement)
    ):
        raise GeneratedMediaProducerAdmissionError(
            "video post-acknowledgement binding mismatch"
        )
    entry = _entry(
        modality=registry.VIDEO_MODALITY,
        ordinal=result["segment_index"],
        unit_start=result["first_frame_ordinal"],
        unit_count=result["frame_count"],
        timeline_start=result["start_tick"],
        timeline_end=result["end_tick"],
        source_bytes=result["total_output_bytes"],
        artifact_sha256=result["artifact_sha256"],
        provenance_sha256=result["provenance_sha256"],
        result_sha256=result["result_sha256"],
        source_output_sha256=result["output_sha256"],
        media_object_sha256=result["media_object_sha256"],
        state_after_sha256=state["state_sha256"],
        completion_sha256=acknowledgement["result_sha256"],
        encoding=encoding,
    )
    envelope = {
        "request_epoch": result["request_epoch"],
        "tenant_scope_sha256": state["tenant_scope_sha256"],
        "metadata_policy_sha256": state["metadata_policy_sha256"],
        "challenge_sha256": state["challenge_sha256"],
    }
    lineage = {
        "state_before_sha256": result["state_before_sha256"],
        "previous_result_sha256": result["previous_publication_result_sha256"],
        "previous_completion_sha256": acknowledgement["previous_ack_result_sha256"],
    }
    return entry, envelope, lineage


def admit_image(value: Any) -> Record:
    """Validate one structural image producer record set."""

    try:
        return _image_admission(value)[0]
    except GeneratedMediaProducerAdmissionError:
        raise
    except UPSTREAM_ERRORS as error:
        raise GeneratedMediaProducerAdmissionError(
            "invalid image producer records"
        ) from error


def admit_audio(value: Any) -> Record:
    """Validate one quiescent acknowledged audio producer record set."""

    try:
        return _audio_admission(value)[0]
    except GeneratedMediaProducerAdmissionError:
        raise
    except UPSTREAM_ERRORS as error:
        raise GeneratedMediaProducerAdmissionError(
            "invalid audio producer records"
        ) from error


def admit_video(value: Any) -> Record:
    """Validate one quiescent acknowledged video producer record set."""

    try:
        return _video_admission(value)[0]
    except GeneratedMediaProducerAdmissionError:
        raise
    except UPSTREAM_ERRORS as error:
        raise GeneratedMediaProducerAdmissionError(
            "invalid video producer records"
        ) from error


def encode_archive(
    previous: Record | None,
    metadata_value: Any,
    producer_values: Any,
) -> Record:
    """Admit typed producers and build the existing registry archive."""

    try:
        metadata_input = _metadata(metadata_value)
        previous_checked = (
            None if previous is None else registry.validate_decoded_archive(previous)
        )
        if (
            type(producer_values) is not list
            or not 1 <= len(producer_values) <= registry.MAX_ENTRIES
        ):
            raise GeneratedMediaProducerAdmissionError("invalid producer list")
        entries: list[Record] = []
        envelopes: list[Record] = []
        lineages: list[Record] = []
        for producer in producer_values:
            if type(producer) is not dict or type(producer.get("modality")) is not int:
                raise GeneratedMediaProducerAdmissionError(
                    "invalid producer discriminator"
                )
            modality = producer["modality"]
            if modality == registry.IMAGE_MODALITY:
                entry, envelope, lineage = _image_admission(producer)
            elif modality == registry.AUDIO_MODALITY:
                entry, envelope, lineage = _audio_admission(producer)
            elif modality == registry.VIDEO_MODALITY:
                entry, envelope, lineage = _video_admission(producer)
            else:
                raise GeneratedMediaProducerAdmissionError("invalid producer modality")
            entries.append(entry)
            envelopes.append(envelope)
            lineages.append(lineage)
        expected_envelope = envelopes[0]
        for envelope in envelopes[1:]:
            if any(
                envelope[field] != expected_envelope[field] for field in ENVELOPE_FIELDS
            ):
                raise GeneratedMediaProducerAdmissionError("producer envelope mismatch")
        terminals: dict[int, Record | None] = {
            modality: None for modality in registry.MODALITIES
        }
        if previous_checked is not None:
            for previous_entry in previous_checked["entries"]:
                terminals[previous_entry["modality"]] = previous_entry
        for entry, lineage in zip(entries, lineages):
            prior = terminals[entry["modality"]]
            if prior is None:
                if entry["ordinal"] != 0:
                    raise GeneratedMediaProducerAdmissionError(
                        "missing producer predecessor"
                    )
                if entry["modality"] != registry.IMAGE_MODALITY and (
                    lineage["previous_result_sha256"] != ZERO
                    or lineage["previous_completion_sha256"] != ZERO
                ):
                    raise GeneratedMediaProducerAdmissionError(
                        "invalid producer genesis"
                    )
            elif (
                entry["ordinal"] != _add(prior["ordinal"], 1, "producer ordinal")
                or lineage["previous_result_sha256"] != prior["result_sha256"]
                or lineage["state_before_sha256"] != prior["state_after_sha256"]
                or (
                    entry["modality"] != registry.IMAGE_MODALITY
                    and lineage["previous_completion_sha256"]
                    != prior["completion_sha256"]
                )
            ):
                raise GeneratedMediaProducerAdmissionError(
                    "invalid producer predecessor"
                )
            terminals[entry["modality"]] = entry
        if previous_checked is None:
            generation = 1
            publication_sequence = 1
        else:
            generation = _add(
                previous_checked["manifest"]["generation"],
                1,
                "registry generation",
            )
            publication_sequence = _add(
                previous_checked["manifest"]["publication_sequence"],
                1,
                "registry publication sequence",
            )
        metadata = {
            **expected_envelope,
            "generation": generation,
            "publication_sequence": publication_sequence,
            "generation_plan_sha256": metadata_input["generation_plan_sha256"],
        }
        return registry.encode_archive(previous_checked, metadata, entries)
    except GeneratedMediaProducerAdmissionError:
        raise
    except UPSTREAM_ERRORS as error:
        raise GeneratedMediaProducerAdmissionError(
            "registry admission failed"
        ) from error


def _identity(label: bytes) -> bytes:
    return hashlib.sha256(
        b"glacier.generated-media-producer-admission.reference.v1\x00" + label
    ).digest()


def _encoding_input(modality: bytes, ordinal: int, raw: bytes) -> Record:
    return {
        "encoding_abi": {
            b"image": 101,
            b"audio": 102,
            b"video": 103,
        }[modality],
        "encoded_payload": (
            b"producer-admission-"
            + modality
            + b"-"
            + str(ordinal).encode("ascii")
            + b"\x00"
            + raw
        ),
        "encoder_implementation_sha256": _identity(b"encoder-" + modality),
        "format_sha256": _identity(b"format-" + modality),
    }


def _reference_image(
    index: int,
    common: Record,
    previous_plan_sha256: bytes,
    previous_result_sha256: bytes,
    publication_state_before_sha256: bytes,
) -> tuple[Record, Record, Record]:
    ordinal = index - 1
    raw = bytes((20 + index, 30 + index, 40 + index, 50 + index))
    plan: Record = {
        "request_epoch": common["request_epoch"],
        "generation": index,
        "image_index": index,
        "source_step": index,
        "width": 2,
        "height": 2,
        "channels": 1,
        "row_stride": 2,
        "latent_bytes": 4,
        "pixel_bytes": 4,
        "maximum_output_bytes": 4,
        "decoder_abi": image.REFERENCE_DECODER_ABI,
        "color_model": image.GRAY,
        "transfer_function": image.LINEAR,
        "alpha_mode": image.ALPHA_NONE,
        "publication_sequence": index,
        "visible_images_before": ordinal,
        "visible_images_after": index,
        "logical_units": 1,
        "required_capabilities": 0,
        "artifact_sha256": _identity(b"image-artifact"),
        "terminal_result_sha256": _identity(
            b"image-terminal-result-" + str(index).encode("ascii")
        ),
        "terminal_plan_sha256": _identity(
            b"image-terminal-plan-" + str(index).encode("ascii")
        ),
        "terminal_output_sha256": _identity(
            b"image-terminal-output-" + str(index).encode("ascii")
        ),
        "terminal_state_publication_sha256": _identity(
            b"image-terminal-state-" + str(index).encode("ascii")
        ),
        "stateful_checkpoint_sha256": _identity(
            b"image-checkpoint-" + str(index).encode("ascii")
        ),
        "decoder_payload_sha256": _identity(b"image-decoder-payload"),
        "decoder_implementation_sha256": _identity(b"image-decoder-implementation"),
        "tenant_scope_sha256": common["tenant_scope_sha256"],
        "metadata_policy_sha256": common["metadata_policy_sha256"],
        "source_provenance_sha256": _identity(
            b"image-source-provenance-" + str(index).encode("ascii")
        ),
        "challenge_sha256": common["challenge_sha256"],
        "previous_plan_sha256": previous_plan_sha256,
        "previous_result_sha256": previous_result_sha256,
        "media_object_sha256": _identity(b"image-media-" + str(index).encode("ascii")),
    }
    plan["plan_sha256"] = image.plan_root(plan)
    plan = image.validate_plan(plan)
    provenance = image.make_provenance(plan, model.sha256(raw))
    result: Record = {
        **{field: plan[field] for field in image.RESULT_SCALARS},
        "plan_sha256": plan["plan_sha256"],
        "provenance_sha256": provenance["provenance_sha256"],
        "artifact_sha256": plan["artifact_sha256"],
        "terminal_result_sha256": plan["terminal_result_sha256"],
        "terminal_output_sha256": plan["terminal_output_sha256"],
        "terminal_state_publication_sha256": plan["terminal_state_publication_sha256"],
        "media_object_sha256": plan["media_object_sha256"],
        "output_sha256": provenance["output_sha256"],
        "resource_receipt_sha256": _identity(
            b"image-resource-" + str(index).encode("ascii")
        ),
        "publication_state_before_sha256": publication_state_before_sha256,
        "timeline_event_sha256": _identity(
            b"image-event-" + str(index).encode("ascii")
        ),
        "media_commit_sha256": _identity(b"image-commit-" + str(index).encode("ascii")),
        "publication_state_after_sha256": _identity(
            b"image-state-after-" + str(index).encode("ascii")
        ),
        "previous_result_sha256": plan["previous_result_sha256"],
        "decoder_implementation_sha256": plan["decoder_implementation_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
    }
    result["result_sha256"] = image.result_root(result)
    result = image.validate_result(result)
    producer = {
        "modality": registry.IMAGE_MODALITY,
        "plan_wire": image.encode_plan(plan),
        "provenance_wire": image.encode_provenance(provenance),
        "result_wire": image.encode_result(result),
        "raw_output": raw,
        **_encoding_input(b"image", ordinal, raw),
    }
    return producer, plan, result


def _reference_audio(
    common: Record,
    sources: tuple[bytes, bytes] = (
        bytes((129, 127)),
        bytes((130, 126)),
    ),
) -> tuple[Record, Record]:
    state0 = audio.initial_state(
        request_epoch=common["request_epoch"],
        sample_rate=16_000,
        channels=1,
        artifact_sha256=_identity(b"audio-artifact"),
        tenant_scope_sha256=common["tenant_scope_sha256"],
        metadata_policy_sha256=common["metadata_policy_sha256"],
        challenge_sha256=common["challenge_sha256"],
    )
    empty_claim = {field: 0 for field in resource.CLAIM_FIELDS}
    claim = {
        **empty_claim,
        "capsule_bytes": len(audio.REFERENCE_RENDERER_PAYLOAD),
        "activation_bytes": 2,
        "partial_bytes": 1092,
        "output_journal_bytes": 1092,
        "queue_slots": 1,
    }
    producers: list[Record] = []
    state = state0
    for ordinal, source in enumerate(sources):
        receipt = resource.resource_receipt(
            151_001,
            0,
            ordinal + 1,
            152_001 + ordinal,
            claim,
        )
        pending, plan, provenance, result, _, pcm = audio.make_reference_chunk(
            state,
            source,
            receipt,
        )
        observation = audio.make_observation(
            pending,
            sink_implementation_sha256=_identity(b"audio-sink"),
            sink_instance_sha256=_identity(b"audio-sink-instance"),
        )
        ack_plan = audio.make_ack_plan(
            pending,
            result,
            observation,
        )
        state, acknowledgement = audio.acknowledge(
            pending,
            result,
            observation,
            ack_plan,
        )
        producers.append(
            {
                "modality": registry.AUDIO_MODALITY,
                "state_wire": audio.encode_state(state),
                "plan_wire": audio.encode_plan(plan),
                "provenance_wire": audio.encode_provenance(provenance),
                "result_wire": audio.encode_result(result),
                "ack_result_wire": audio.encode_ack_result(acknowledgement),
                "raw_output": pcm,
                **_encoding_input(b"audio", ordinal, pcm),
            }
        )
    return producers[0], producers[1]


def _reference_video(
    common: Record,
    cases: tuple[
        tuple[bytes, int, int],
        tuple[bytes, int, int],
    ] = (
        (bytes((3, 7)), 2, 3),
        (bytes((11, 13)), 4, 1),
    ),
) -> tuple[Record, Record]:
    state0 = video.initial_state(
        request_epoch=common["request_epoch"],
        width=2,
        height=2,
        channels=1,
        artifact_sha256=_identity(b"video-artifact"),
        tenant_scope_sha256=common["tenant_scope_sha256"],
        metadata_policy_sha256=common["metadata_policy_sha256"],
        challenge_sha256=common["challenge_sha256"],
    )
    empty_claim = {field: 0 for field in resource.CLAIM_FIELDS}
    claim = {
        **empty_claim,
        "capsule_bytes": len(video.REFERENCE_RENDERER_PAYLOAD),
        "activation_bytes": 2,
        "partial_bytes": 1320,
        "output_journal_bytes": 1320,
        "queue_slots": 1,
    }
    producers: list[Record] = []
    state = state0
    previous_source_result = _identity(b"video-source-result-genesis")
    for ordinal, (source, first_duration, second_duration) in enumerate(cases):
        receipt = resource.resource_receipt(
            161_001,
            0,
            ordinal + 1,
            162_001 + ordinal,
            claim,
        )
        (
            pending,
            manifest,
            provenance,
            result,
            _,
            output,
        ) = video.make_reference_chunk(
            state,
            source,
            first_duration,
            second_duration,
            previous_source_result,
            receipt,
        )
        observation = video.make_observation(
            pending,
            sink_implementation_sha256=_identity(b"video-sink"),
            sink_instance_sha256=_identity(b"video-sink-instance"),
        )
        ack_plan = video.make_ack_plan(
            pending,
            result,
            observation,
        )
        state, acknowledgement = video.acknowledge(
            pending,
            result,
            observation,
            ack_plan,
        )
        producers.append(
            {
                "modality": registry.VIDEO_MODALITY,
                "state_wire": video.encode_state(state),
                "manifest_wire": video.encode_manifest(manifest),
                "provenance_wire": video.encode_provenance(provenance),
                "result_wire": video.encode_result(result),
                "ack_result_wire": video.encode_ack_result(acknowledgement),
                "raw_output": output,
                **_encoding_input(b"video", ordinal, output),
            }
        )
        previous_source_result = result["result_sha256"]
    return producers[0], producers[1]


def reference_inputs() -> Record:
    """Return two deterministic, lineage-compatible typed producer batches."""

    common = {
        "request_epoch": 131_001,
        "tenant_scope_sha256": _identity(b"tenant-scope"),
        "metadata_policy_sha256": _identity(b"metadata-policy"),
        "challenge_sha256": _identity(b"challenge"),
    }
    image1, image_plan1, image_result1 = _reference_image(
        1,
        common,
        _identity(b"image-plan-genesis"),
        _identity(b"image-result-genesis"),
        _identity(b"image-state-genesis"),
    )
    image2, _, _ = _reference_image(
        2,
        common,
        image_plan1["plan_sha256"],
        image_result1["result_sha256"],
        image_result1["publication_state_after_sha256"],
    )
    audio1, audio2 = _reference_audio(common)
    video1, video2 = _reference_video(common)
    metadata1 = {
        "generation_plan_sha256": _identity(b"generation-plan-one"),
    }
    metadata2 = {
        "generation_plan_sha256": _identity(b"generation-plan-two"),
    }
    return {
        "metadata1": metadata1,
        "metadata2": metadata2,
        "batch1": [image1, audio1, video1],
        "batch2": [image2, audio2, video2],
    }


def reference_archives() -> Record:
    """Build the deterministic two-generation structural admission chain."""

    fixture = reference_inputs()
    first = encode_archive(None, fixture["metadata1"], fixture["batch1"])
    second = encode_archive(first, fixture["metadata2"], fixture["batch2"])
    return {"first": first, "second": second}
