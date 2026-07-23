"""Independent exact-integer stateful transcript fixture."""

from __future__ import annotations

import struct
from typing import Any

from bench import audio_transcript_adapter as audio
from bench import model_contract as model
from bench import stateful_model_adapter as stateful


class StatefulTranscriptAdapterError(ValueError):
    """A transcript state, plan, or transition is invalid."""


Record = dict[str, Any]
REFERENCE_ADAPTER_ABI = 0x53545254524E0001
REFERENCE_ARTIFACT_ABI = 0x5354415352000001
REFERENCE_STATE_BYTES = 32
REFERENCE_INPUT_FEATURES = 4
REFERENCE_OUTPUT_BYTES = audio.MAXIMUM_TEXT_BYTES
REFERENCE_WEIGHTS = bytes((1, 2, 3, 4))
REFERENCE_FIRST_FEATURES = bytes((7, 0, 0, 0, 1, 0, 0, 0))
REFERENCE_SECOND_FEATURES = bytes((23, 0, 25, 0, 11, 0, 25, 0))


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= model.U64_MAX:
        raise StatefulTranscriptAdapterError("u64 out of range")
    return struct.pack("<Q", value)


def validate_state(value: Record) -> Record:
    fields = (
        "segment_index",
        "next_sample",
        "sample_rate",
        "emitted_text_bytes",
    )
    try:
        state = {field: value[field] for field in fields}
        for field in fields:
            _u64(state[field])
    except (KeyError, TypeError):
        raise StatefulTranscriptAdapterError(
            "invalid transcript state"
        ) from None
    if state["next_sample"] == 0 or state["sample_rate"] == 0:
        raise StatefulTranscriptAdapterError("invalid transcript state")
    return state


def encode_state(value: Record) -> bytes:
    state = validate_state(value)
    return b"".join(
        _u64(state[field])
        for field in (
            "segment_index",
            "next_sample",
            "sample_rate",
            "emitted_text_bytes",
        )
    )


def decode_state(encoded: bytes) -> Record:
    if not isinstance(encoded, bytes) or len(encoded) != REFERENCE_STATE_BYTES:
        raise StatefulTranscriptAdapterError("invalid transcript state wire")
    state = {
        "segment_index": struct.unpack_from("<Q", encoded, 0)[0],
        "next_sample": struct.unpack_from("<Q", encoded, 8)[0],
        "sample_rate": struct.unpack_from("<Q", encoded, 16)[0],
        "emitted_text_bytes": struct.unpack_from("<Q", encoded, 24)[0],
    }
    state = validate_state(state)
    if encode_state(state) != encoded:
        raise StatefulTranscriptAdapterError(
            "non-canonical transcript state"
        )
    return state


def initialize_state(first_overlap_value: Record) -> Record:
    first_overlap = audio.validate_overlap(first_overlap_value)
    if (
        first_overlap["segment_index"] != 1
        or first_overlap["generation"] != 1
    ):
        raise StatefulTranscriptAdapterError("invalid first overlap")
    return validate_state(
        {
            "segment_index": 0,
            "next_sample": first_overlap["publish_start_sample"],
            "sample_rate": first_overlap["sample_rate"],
            "emitted_text_bytes": 0,
        }
    )


def transcript_schema_root() -> bytes:
    return model.sha256(
        b"glacier audio transcript segment v1 384-byte wire"
    )


def make_manifest(weights: bytes = REFERENCE_WEIGHTS) -> Record:
    if not isinstance(weights, bytes) or len(weights) != len(REFERENCE_WEIGHTS):
        raise StatefulTranscriptAdapterError("invalid weights")
    return model.make_artifact(
        family=4,
        artifact_abi=REFERENCE_ARTIFACT_ABI,
        input_kind=4,
        output_kind=5,
        numerical_policy=model.EXACT_INTEGER,
        max_batch_items=1,
        input_features=REFERENCE_INPUT_FEATURES,
        output_dimensions=REFERENCE_OUTPUT_BYTES,
        input_element_bytes=2,
        output_element_bytes=1,
        weight_element_bytes=1,
        weights=weights,
        metadata_sha256=model.sha256(
            b"stateful transcript fixture metadata"
        ),
        license_sha256=model.sha256(b"fixture-only license"),
    )


def make_plan(
    *,
    manifest: Record,
    model_publication: Record,
    state_publication: Record,
    overlap_value: Record,
    previous_plan_sha256: bytes,
) -> Record:
    state = stateful.validate_publication(state_publication)
    overlap = audio.validate_overlap(overlap_value)
    generation = state["current_step"] + 1
    if (
        generation > model.U64_MAX
        or generation != overlap["generation"]
        or state["state_bytes"] != REFERENCE_STATE_BYTES
        or model_publication["request_epoch"] != state["request_epoch"]
        or model_publication["next_sequence"] != state["current_step"]
        or model_publication["visible_results"] != state["current_step"]
        or model_publication["artifact_sha256"]
        != manifest["artifact_sha256"]
        or model_publication["previous_result_sha256"]
        != state["previous_result_sha256"]
        or state["challenge_sha256"] != overlap["challenge_sha256"]
    ):
        raise StatefulTranscriptAdapterError("invalid plan binding")
    return model.make_plan(
        manifest,
        operation=6,
        request_epoch=state["request_epoch"],
        generation=generation,
        batch_items=1,
        publication_next_sequence=model_publication["next_sequence"],
        maximum_absolute_output=ord("z"),
        required_capabilities=0,
        scratch_bytes=REFERENCE_OUTPUT_BYTES,
        claim={
            "capsule_bytes": len(REFERENCE_WEIGHTS),
            "kv_bytes": 0,
            "activation_bytes": len(REFERENCE_FIRST_FEATURES),
            "partial_bytes": REFERENCE_OUTPUT_BYTES,
            "logits_bytes": 0,
            "output_journal_bytes": (
                REFERENCE_OUTPUT_BYTES + REFERENCE_STATE_BYTES
            ),
            "staging_bytes": REFERENCE_STATE_BYTES,
            "device_bytes": 0,
            "io_bytes": 0,
            "queue_slots": 1,
        },
        digests={
            "media_object_sha256": overlap["media_object_sha256"],
            "processor_state_sha256": state["publication_sha256"],
            "processor_bundle_sha256": overlap[
                "processor_bundle_sha256"
            ],
            "cache_bundle_sha256": overlap["cache_bundle_sha256"],
            "cache_payload_sha256": state["current_state_sha256"],
            "ownership_sha256": overlap["ownership_sha256"],
            "challenge_sha256": overlap["challenge_sha256"],
            "previous_plan_sha256": previous_plan_sha256,
            "input_schema_sha256": overlap["overlap_sha256"],
            "output_schema_sha256": transcript_schema_root(),
        },
    )


def adapter_root(manifest: Record) -> bytes:
    return stateful.adapter_descriptor_root(
        adapter_abi=REFERENCE_ADAPTER_ABI,
        family=manifest["family"],
        operation=6,
        input_kind=manifest["input_kind"],
        output_kind=manifest["output_kind"],
        numerical_policy=manifest["numerical_policy"],
        max_batch_items=1,
        max_input_features=REFERENCE_INPUT_FEATURES,
        max_output_dimensions=REFERENCE_OUTPUT_BYTES,
        allowed_capabilities=0,
        implementation_sha256=model.sha256(
            b"reference exact stateful transcript v1"
        ),
    )


def reference_step(
    *,
    overlap_value: Record,
    current_state_wire: bytes,
    features: bytes,
    text_bytes: int,
    weights: bytes = REFERENCE_WEIGHTS,
) -> tuple[bytes, bytes]:
    overlap = audio.validate_overlap(overlap_value)
    state = decode_state(current_state_wire)
    if (
        not isinstance(features, bytes)
        or len(features) != len(REFERENCE_FIRST_FEATURES)
        or not isinstance(weights, bytes)
        or len(weights) != len(REFERENCE_WEIGHTS)
        or not isinstance(text_bytes, int)
        or not 0 < text_bytes <= REFERENCE_INPUT_FEATURES
        or state["segment_index"] + 1 != overlap["segment_index"]
        or state["next_sample"] != overlap["publish_start_sample"]
        or state["sample_rate"] != overlap["sample_rate"]
    ):
        raise StatefulTranscriptAdapterError("invalid step binding")
    output = bytearray(REFERENCE_OUTPUT_BYTES)
    for index in range(text_bytes):
        feature_index = index % REFERENCE_INPUT_FEATURES
        feature = struct.unpack_from("<H", features, feature_index * 2)[0]
        value = (
            feature
            + weights[index % len(weights)]
            + state["emitted_text_bytes"]
        ) % 26
        output[index] = ord("a") + value
    next_state = {
        "segment_index": overlap["segment_index"],
        "next_sample": overlap["publish_end_sample"],
        "sample_rate": overlap["sample_rate"],
        "emitted_text_bytes": (
            state["emitted_text_bytes"] + text_bytes
        ),
    }
    return bytes(output), encode_state(next_state)
