"""Independent execution oracle for generated-media producer transitions.

The oracle intentionally owns no runtime callbacks.  It replays the portable
reference model and materializer implementations, validates all supplied
canonical wires, then binds the resulting transition receipts to the existing
generated-media output registry archive.
"""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import generated_audio_playback as audio
from bench import generated_image_publication as image
from bench import generated_media_output_registry as registry
from bench import generated_video_display as video
from bench import media_contract as media
from bench import media_runtime_txn as resource
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as continuation

Record = dict[str, Any]

ZERO = bytes(32)
U64_MAX = (1 << 64) - 1

STATELESS_MODEL = 1
STATEFUL_MODEL = 2
NO_COMPLETION = 0
PLAYBACK_COMPLETION = 1
DISPLAY_COMPLETION = 2

MODEL_PUBLICATION_ABI = 1
MODEL_PUBLICATION_BYTES = 160
MODEL_PUBLICATION_MAGIC = b"GLMPUB1\x00"

ADAPTER_DESCRIPTOR_ABI = 1
ADAPTER_DESCRIPTOR_BYTES = 256
ADAPTER_DESCRIPTOR_MAGIC = b"GLMADP1\x00"
ADAPTER_DESCRIPTOR_DOMAIN = (
    b"glacier-generated-media-producer-transition-adapter-descriptor-v1\x00"
)

MEDIA_PUBLICATION_ABI = 1
MEDIA_PUBLICATION_BYTES = 224
MEDIA_PUBLICATION_MAGIC = b"GLMMPB1\x00"

RESOURCE_RECEIPT_ABI = 1
RESOURCE_RECEIPT_BYTES = 192
RESOURCE_RECEIPT_MAGIC = b"GLMRCP1\x00"
RESOURCE_RECEIPT_DOMAIN = (
    b"glacier-generated-media-producer-transition-resource-receipt-v1\x00"
)

SUPPORT_SET_DOMAIN = b"glacier-generated-media-producer-transition-support-set-v1\x00"
STATELESS_SOURCE_MAPPING_DOMAIN = (
    b"glacier-generated-media-producer-transition-stateless-source-mapping-v1\x00"
)
MATERIALIZER_EXECUTION_DOMAIN = (
    b"glacier-generated-media-producer-transition-materializer-execution-v1\x00"
)
PRODUCER_PROJECTION_DOMAIN = (
    b"glacier-generated-media-producer-transition-producer-projection-v1\x00"
)

TRANSITION_RECEIPT_ABI = 1
TRANSITION_RECEIPT_BYTES = 1728
TRANSITION_RECEIPT_BODY_BYTES = 1696
TRANSITION_RECEIPT_MAGIC = b"GLMXTRN1"
TRANSITION_RECEIPT_DOMAIN = (
    b"glacier-generated-media-producer-transition-receipt-v1\x00"
)
RECEIPT_TABLE_DOMAIN = (
    b"glacier-generated-media-producer-transition-receipt-table-v1\x00"
)

BATCH_ABI = 1
BATCH_BYTES = 640
BATCH_BODY_BYTES = 608
BATCH_MAGIC = b"GLMXBAT1"
BATCH_DOMAIN = b"glacier-generated-media-producer-transition-batch-v1\x00"

SUPPORT_FIELDS = (
    "family",
    "operation",
    "input_kind",
    "output_kind",
    "numerical_policy",
    "max_batch_items",
    "max_input_features",
    "max_output_dimensions",
    "allowed_capabilities",
)
ADAPTER_FIELDS = (
    "adapter_abi",
    "family",
    "operation",
    "input_kind",
    "output_kind",
    "numerical_policy",
    "max_batch_items",
    "max_input_features",
    "max_output_dimensions",
    "allowed_capabilities",
)
TRANSITION_SCALARS = (
    "modality",
    "model_kind",
    "completion_kind",
    "request_epoch",
    "producer_generation",
    "producer_ordinal",
    "registry_ordinal",
    "unit_start",
    "unit_count",
    "timeline_start",
    "timeline_end",
    "weights_bytes",
    "model_input_bytes",
    "model_state_before_bytes",
    "model_output_bytes",
    "model_state_after_bytes",
    "materializer_payload_bytes",
    "raw_output_bytes",
    "encoded_payload_bytes",
    "producer_publication_sequence",
    "completion_sequence",
    "model_required_capabilities",
    "materializer_required_capabilities",
    "model_step_before",
    "model_step_after",
    "producer_state_generation_before",
    "producer_state_generation_after_publication",
    "producer_state_generation_after_completion",
)
TRANSITION_DIGESTS = (
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "generation_plan_sha256",
    "artifact_manifest_sha256",
    "adapter_descriptor_sha256",
    "support_set_sha256",
    "model_plan_sha256",
    "model_publication_before_sha256",
    "model_state_publication_before_sha256",
    "weights_sha256",
    "model_input_sha256",
    "model_state_before_sha256",
    "model_output_sha256",
    "model_state_after_sha256",
    "model_transition_or_source_mapping_sha256",
    "model_result_sha256",
    "model_publication_after_sha256",
    "model_state_publication_after_sha256",
    "producer_plan_or_manifest_sha256",
    "producer_state_before_sha256",
    "media_object_sha256",
    "materializer_payload_sha256",
    "materializer_implementation_sha256",
    "materializer_execution_sha256",
    "raw_output_sha256",
    "provenance_sha256",
    "producer_receipt_wire_sha256",
    "producer_resource_sha256",
    "publication_result_sha256",
    "producer_state_after_publication_sha256",
    "completion_observation_sha256",
    "completion_plan_sha256",
    "completion_result_sha256",
    "producer_final_state_sha256",
    "encoder_implementation_sha256",
    "format_sha256",
    "encoded_payload_sha256",
    "previous_transition_receipt_sha256",
    "producer_projection_sha256",
    "registry_previous_entry_sha256",
    "registry_entry_sha256",
    "registry_manifest_sha256",
    "registry_archive_sha256",
)
BATCH_SCALARS = (
    "request_epoch",
    "registry_generation",
    "publication_sequence",
    "receipt_count",
    "receipt_table_bytes",
    "total_model_input_bytes",
    "total_model_output_bytes",
    "total_model_state_transition_bytes",
    "total_materializer_payload_bytes",
    "total_raw_output_bytes",
    "total_encoded_payload_bytes",
    "modality_mask",
)
BATCH_DIGESTS = (
    "generation_plan_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "receipt_table_sha256",
    "previous_batch_sha256",
    "registry_manifest_sha256",
    "registry_archive_sha256",
    "first_receipt_sha256",
    "terminal_image_receipt_sha256",
    "terminal_audio_receipt_sha256",
    "terminal_video_receipt_sha256",
)


class GeneratedMediaProducerTransitionError(ValueError):
    """Execution evidence or its registry binding is invalid."""


def _u64(value: Any, label: str = "u64") -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise GeneratedMediaProducerTransitionError(f"invalid {label}")
    return value


def _u64_bytes(value: Any, label: str = "u64") -> bytes:
    return struct.pack("<Q", _u64(value, label))


def _read(raw: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", raw, offset)[0]


def _digest(
    value: Any,
    label: str = "digest",
    *,
    allow_zero: bool = False,
) -> bytes:
    if (
        type(value) is not bytes
        or len(value) != 32
        or (not allow_zero and value == ZERO)
    ):
        raise GeneratedMediaProducerTransitionError(f"invalid {label}")
    return value


def _bytes(value: Any, label: str, *, nonempty: bool = True) -> bytes:
    if type(value) is not bytes or (nonempty and not value):
        raise GeneratedMediaProducerTransitionError(f"invalid {label}")
    return value


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def _checked_add(left: int, right: int, label: str) -> int:
    result = _u64(left, label) + _u64(right, label)
    return _u64(result, label)


def _wire_header(
    magic: bytes,
    abi: int,
    total_bytes: int,
) -> bytes:
    return magic + _u64_bytes(abi) + _u64_bytes(total_bytes) + _u64_bytes(0)


def encode_model_publication(value: Record) -> bytes:
    """Encode a model PublicationStateV1 without serializing runtime policy."""

    try:
        state = {
            "request_epoch": _u64(value["request_epoch"], "request epoch"),
            "next_sequence": _u64(value["next_sequence"], "next sequence"),
            "visible_results": _u64(value["visible_results"], "visible results"),
            "artifact_sha256": _digest(value["artifact_sha256"], "artifact root"),
            "previous_result_sha256": _digest(
                value["previous_result_sha256"],
                "previous result root",
                allow_zero=True,
            ),
        }
        state_root = model.publication_state_root(state)
    except (KeyError, TypeError, model.ModelContractError) as error:
        raise GeneratedMediaProducerTransitionError(
            "invalid model publication"
        ) from error
    raw = bytearray(MODEL_PUBLICATION_BYTES)
    raw[:32] = _wire_header(
        MODEL_PUBLICATION_MAGIC,
        MODEL_PUBLICATION_ABI,
        MODEL_PUBLICATION_BYTES,
    )
    raw[32:56] = b"".join(
        _u64_bytes(state[field])
        for field in ("request_epoch", "next_sequence", "visible_results")
    )
    raw[64:128] = state["artifact_sha256"] + state["previous_result_sha256"]
    raw[128:] = state_root
    return bytes(raw)


def decode_model_publication(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != MODEL_PUBLICATION_BYTES
        or raw[:8] != MODEL_PUBLICATION_MAGIC
        or _read(raw, 8) != MODEL_PUBLICATION_ABI
        or _read(raw, 16) != MODEL_PUBLICATION_BYTES
        or _read(raw, 24) != 0
        or any(raw[56:64])
    ):
        raise GeneratedMediaProducerTransitionError("invalid model publication wire")
    value: Record = {
        "request_epoch": _read(raw, 32),
        "next_sequence": _read(raw, 40),
        "visible_results": _read(raw, 48),
        "artifact_sha256": raw[64:96],
        "previous_result_sha256": raw[96:128],
        "publication_state_sha256": raw[128:160],
    }
    if (
        encode_model_publication(value) != raw
        or model.publication_state_root(value) != value["publication_state_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("model publication root mismatch")
    return value


def adapter_descriptor_root(value: Record) -> bytes:
    try:
        body = _wire_header(
            ADAPTER_DESCRIPTOR_MAGIC,
            ADAPTER_DESCRIPTOR_ABI,
            ADAPTER_DESCRIPTOR_BYTES,
        )
        body += b"".join(_u64_bytes(value[field], field) for field in ADAPTER_FIELDS)
        body += _digest(value["implementation_sha256"], "adapter implementation")
        body += _digest(value["adapter_sha256"], "adapter root")
        body += bytes(48)
    except (KeyError, TypeError):
        raise GeneratedMediaProducerTransitionError(
            "invalid adapter descriptor"
        ) from None
    if len(body) != 224:
        raise AssertionError("adapter descriptor body size")
    return _root(ADAPTER_DESCRIPTOR_DOMAIN, body)


def encode_adapter_descriptor(value: Record) -> bytes:
    try:
        supplied_adapter = _digest(value["adapter_sha256"], "adapter root")
        expected_adapter = stateful.adapter_descriptor_root(
            **{
                field: value[field]
                for field in (
                    *ADAPTER_FIELDS,
                    "implementation_sha256",
                )
            }
        )
    except (
        KeyError,
        TypeError,
        stateful.StatefulModelAdapterError,
    ) as error:
        raise GeneratedMediaProducerTransitionError(
            "invalid adapter descriptor"
        ) from error
    if supplied_adapter != expected_adapter:
        raise GeneratedMediaProducerTransitionError("adapter descriptor root mismatch")
    body = bytearray(224)
    body[:32] = _wire_header(
        ADAPTER_DESCRIPTOR_MAGIC,
        ADAPTER_DESCRIPTOR_ABI,
        ADAPTER_DESCRIPTOR_BYTES,
    )
    body[32:112] = b"".join(_u64_bytes(value[field], field) for field in ADAPTER_FIELDS)
    body[112:144] = value["implementation_sha256"]
    body[144:176] = supplied_adapter
    return bytes(body) + adapter_descriptor_root(value)


def decode_adapter_descriptor(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != ADAPTER_DESCRIPTOR_BYTES
        or raw[:8] != ADAPTER_DESCRIPTOR_MAGIC
        or _read(raw, 8) != ADAPTER_DESCRIPTOR_ABI
        or _read(raw, 16) != ADAPTER_DESCRIPTOR_BYTES
        or _read(raw, 24) != 0
        or any(raw[176:224])
    ):
        raise GeneratedMediaProducerTransitionError("invalid adapter descriptor wire")
    value: Record = {
        field: _read(raw, 32 + index * 8) for index, field in enumerate(ADAPTER_FIELDS)
    }
    value["implementation_sha256"] = raw[112:144]
    value["adapter_sha256"] = raw[144:176]
    value["descriptor_sha256"] = raw[224:256]
    if (
        encode_adapter_descriptor(value) != raw
        or adapter_descriptor_root(value) != value["descriptor_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("adapter descriptor root mismatch")
    return value


def encode_media_publication(value: Record) -> bytes:
    try:
        state = {
            "request_epoch": _u64(value["request_epoch"], "request epoch"),
            "next_sequence": _u64(value["next_sequence"], "next sequence"),
            "visible_chunks": _u64(value["visible_chunks"], "visible chunks"),
            "visible_units": _u64(value["visible_units"], "visible units"),
            "timeline_base": (
                _u64(value["timeline_base"][0], "time numerator"),
                _u64(value["timeline_base"][1], "time denominator"),
            ),
            "media_object_sha256": _digest(
                value["media_object_sha256"], "media object root"
            ),
            "timeline_sha256": _digest(
                value["timeline_sha256"],
                "timeline root",
                allow_zero=True,
            ),
            "previous_commit_sha256": _digest(
                value["previous_commit_sha256"],
                "previous commit root",
            ),
        }
        state_root = media.publication_state_root(state)
    except (
        KeyError,
        TypeError,
        IndexError,
        media.MediaContractError,
    ) as error:
        raise GeneratedMediaProducerTransitionError(
            "invalid media publication"
        ) from error
    raw = bytearray(MEDIA_PUBLICATION_BYTES)
    raw[:32] = _wire_header(
        MEDIA_PUBLICATION_MAGIC,
        MEDIA_PUBLICATION_ABI,
        MEDIA_PUBLICATION_BYTES,
    )
    raw[32:80] = b"".join(
        _u64_bytes(item)
        for item in (
            state["request_epoch"],
            state["next_sequence"],
            state["visible_chunks"],
            state["visible_units"],
            *state["timeline_base"],
        )
    )
    raw[80:176] = b"".join(
        state[field]
        for field in (
            "media_object_sha256",
            "timeline_sha256",
            "previous_commit_sha256",
        )
    )
    raw[192:] = state_root
    return bytes(raw)


def decode_media_publication(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != MEDIA_PUBLICATION_BYTES
        or raw[:8] != MEDIA_PUBLICATION_MAGIC
        or _read(raw, 8) != MEDIA_PUBLICATION_ABI
        or _read(raw, 16) != MEDIA_PUBLICATION_BYTES
        or _read(raw, 24) != 0
        or any(raw[176:192])
    ):
        raise GeneratedMediaProducerTransitionError("invalid media publication wire")
    value: Record = {
        "request_epoch": _read(raw, 32),
        "next_sequence": _read(raw, 40),
        "visible_chunks": _read(raw, 48),
        "visible_units": _read(raw, 56),
        "timeline_base": (_read(raw, 64), _read(raw, 72)),
        "media_object_sha256": raw[80:112],
        "timeline_sha256": raw[112:144],
        "previous_commit_sha256": raw[144:176],
        "publication_state_sha256": raw[192:224],
    }
    if (
        encode_media_publication(value) != raw
        or media.publication_state_root(value) != value["publication_state_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("media publication root mismatch")
    return value


def resource_receipt_root(value: Record) -> bytes:
    raw = _resource_receipt_body(value)
    return _root(RESOURCE_RECEIPT_DOMAIN, raw)


def _resource_receipt_body(value: Record) -> bytes:
    try:
        receipt = resource.resource_receipt(
            value["bank_epoch"],
            value["slot_index"],
            value["generation"],
            value["owner_key"],
            value["claim"],
        )
        if receipt["integrity"] != value["integrity"]:
            raise GeneratedMediaProducerTransitionError(
                "resource receipt integrity mismatch"
            )
    except (
        KeyError,
        TypeError,
        resource.MediaRuntimeTxnError,
    ) as error:
        raise GeneratedMediaProducerTransitionError(
            "invalid resource receipt"
        ) from error
    raw = bytearray(160)
    raw[:32] = _wire_header(
        RESOURCE_RECEIPT_MAGIC,
        RESOURCE_RECEIPT_ABI,
        RESOURCE_RECEIPT_BYTES,
    )
    raw[32:144] = b"".join(
        _u64_bytes(item)
        for item in (
            receipt["bank_epoch"],
            receipt["slot_index"],
            receipt["generation"],
            receipt["owner_key"],
            *(receipt["claim"][field] for field in resource.CLAIM_FIELDS),
        )
    )
    raw[144:152] = _u64_bytes(receipt["integrity"])
    return bytes(raw)


def encode_resource_receipt(value: Record) -> bytes:
    body = _resource_receipt_body(value)
    return body + resource_receipt_root(value)


def decode_resource_receipt(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != RESOURCE_RECEIPT_BYTES
        or raw[:8] != RESOURCE_RECEIPT_MAGIC
        or _read(raw, 8) != RESOURCE_RECEIPT_ABI
        or _read(raw, 16) != RESOURCE_RECEIPT_BYTES
        or _read(raw, 24) != 0
        or any(raw[152:160])
    ):
        raise GeneratedMediaProducerTransitionError("invalid resource receipt wire")
    value: Record = {
        "bank_epoch": _read(raw, 32),
        "slot_index": _read(raw, 40),
        "generation": _read(raw, 48),
        "owner_key": _read(raw, 56),
        "claim": {
            field: _read(raw, 64 + index * 8)
            for index, field in enumerate(resource.CLAIM_FIELDS)
        },
        "integrity": _read(raw, 144),
        "receipt_sha256": raw[160:192],
    }
    if (
        encode_resource_receipt(value) != raw
        or resource_receipt_root(value) != value["receipt_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("resource receipt root mismatch")
    return value


def _runtime_resource_receipt(value: Record) -> Record:
    return {
        field: value[field]
        for field in (
            "bank_epoch",
            "slot_index",
            "generation",
            "owner_key",
            "claim",
            "integrity",
        )
    }


def support_set_root(records: list[Record]) -> bytes:
    if type(records) is not list or not 1 <= len(records) <= 32:
        raise GeneratedMediaProducerTransitionError("invalid support set")
    rows: list[tuple[int, ...]] = []
    for record in records:
        try:
            row = tuple(_u64(record[field], field) for field in SUPPORT_FIELDS)
        except (KeyError, TypeError):
            raise GeneratedMediaProducerTransitionError(
                "invalid support record"
            ) from None
        rows.append(row)
    if rows != sorted(rows) or len(set(rows)) != len(rows):
        raise GeneratedMediaProducerTransitionError("non-canonical support set")
    body = _u64_bytes(len(rows)) + b"".join(
        b"".join(_u64_bytes(item) for item in row) for row in rows
    )
    return _root(SUPPORT_SET_DOMAIN, body)


def stateless_source_mapping_root(
    plan: Record,
    weights: bytes,
    model_input: bytes,
    model_output: bytes,
    adapter_sha256: bytes,
) -> bytes:
    return _root(
        STATELESS_SOURCE_MAPPING_DOMAIN,
        b"".join(
            (
                _digest(plan["plan_sha256"], "model plan root"),
                hashlib.sha256(weights).digest(),
                hashlib.sha256(model_input).digest(),
                hashlib.sha256(model_output).digest(),
                _digest(adapter_sha256, "adapter root"),
                _digest(plan["challenge_sha256"], "challenge root"),
                _u64_bytes(len(weights)),
                _u64_bytes(len(model_input)),
                _u64_bytes(len(model_output)),
            )
        ),
    )


def materializer_execution_root(
    *,
    modality: int,
    producer_plan_sha256: bytes,
    model_output: bytes,
    payload: bytes,
    implementation_sha256: bytes,
    raw_output: bytes,
    required_capabilities: int,
) -> bytes:
    return materializer_execution_root_from_fields(
        modality=modality,
        producer_plan_sha256=producer_plan_sha256,
        model_output_sha256=hashlib.sha256(model_output).digest(),
        payload_sha256=hashlib.sha256(payload).digest(),
        implementation_sha256=implementation_sha256,
        raw_output_sha256=hashlib.sha256(raw_output).digest(),
        required_capabilities=required_capabilities,
        model_output_bytes=len(model_output),
        payload_bytes=len(payload),
        raw_output_bytes=len(raw_output),
    )


def materializer_execution_root_from_fields(
    *,
    modality: int,
    producer_plan_sha256: bytes,
    model_output_sha256: bytes,
    payload_sha256: bytes,
    implementation_sha256: bytes,
    raw_output_sha256: bytes,
    required_capabilities: int,
    model_output_bytes: int,
    payload_bytes: int,
    raw_output_bytes: int,
) -> bytes:
    return _root(
        MATERIALIZER_EXECUTION_DOMAIN,
        b"".join(
            (
                _u64_bytes(modality),
                _digest(producer_plan_sha256),
                _digest(model_output_sha256),
                _digest(payload_sha256),
                _digest(implementation_sha256),
                _digest(raw_output_sha256),
                _u64_bytes(required_capabilities),
                _u64_bytes(model_output_bytes),
                _u64_bytes(payload_bytes),
                _u64_bytes(raw_output_bytes),
            )
        ),
    )


def producer_projection_root(value: Record) -> bytes:
    scalar_fields = (
        "modality",
        "producer_generation",
        "producer_ordinal",
        "registry_ordinal",
        "unit_start",
        "unit_count",
        "timeline_start",
        "timeline_end",
        "raw_output_bytes",
        "completion_kind",
    )
    digest_fields = (
        "artifact_sha256",
        "producer_plan_sha256",
        "provenance_sha256",
        "publication_result_sha256",
        "raw_output_sha256",
        "state_before_sha256",
        "state_after_publication_sha256",
        "observation_sha256",
        "ack_plan_sha256",
        "completion_sha256",
        "final_state_sha256",
        "tenant_scope_sha256",
        "metadata_policy_sha256",
        "challenge_sha256",
    )
    try:
        body = b"".join(
            _u64_bytes(value[field], field) for field in scalar_fields
        ) + b"".join(
            _digest(
                value[field],
                field,
                allow_zero=field
                in (
                    "observation_sha256",
                    "ack_plan_sha256",
                    "completion_sha256",
                ),
            )
            for field in digest_fields
        )
    except (KeyError, TypeError):
        raise GeneratedMediaProducerTransitionError(
            "invalid producer projection"
        ) from None
    return _root(PRODUCER_PROJECTION_DOMAIN, body)


def _producer_projection_root_from_receipt(value: Record) -> bytes:
    return producer_projection_root(
        {
            "modality": value["modality"],
            "producer_generation": value["producer_generation"],
            "producer_ordinal": value["producer_ordinal"],
            "registry_ordinal": value["registry_ordinal"],
            "unit_start": value["unit_start"],
            "unit_count": value["unit_count"],
            "timeline_start": value["timeline_start"],
            "timeline_end": value["timeline_end"],
            "raw_output_bytes": value["raw_output_bytes"],
            "completion_kind": value["completion_kind"],
            "artifact_sha256": value["artifact_manifest_sha256"],
            "producer_plan_sha256": value["producer_plan_or_manifest_sha256"],
            "provenance_sha256": value["provenance_sha256"],
            "publication_result_sha256": value["publication_result_sha256"],
            "raw_output_sha256": value["raw_output_sha256"],
            "state_before_sha256": value["producer_state_before_sha256"],
            "state_after_publication_sha256": value[
                "producer_state_after_publication_sha256"
            ],
            "observation_sha256": value["completion_observation_sha256"],
            "ack_plan_sha256": value["completion_plan_sha256"],
            "completion_sha256": value["completion_result_sha256"],
            "final_state_sha256": value["producer_final_state_sha256"],
            "tenant_scope_sha256": value["tenant_scope_sha256"],
            "metadata_policy_sha256": value["metadata_policy_sha256"],
            "challenge_sha256": value["challenge_sha256"],
        }
    )


def transition_receipt_root(value: Record) -> bytes:
    return _root(TRANSITION_RECEIPT_DOMAIN, _transition_body(value))


def _transition_body(value: Record) -> bytes:
    try:
        body = bytearray(TRANSITION_RECEIPT_BODY_BYTES)
        body[:32] = _wire_header(
            TRANSITION_RECEIPT_MAGIC,
            TRANSITION_RECEIPT_ABI,
            TRANSITION_RECEIPT_BYTES,
        )
        body[32:256] = b"".join(
            _u64_bytes(value[field], field) for field in TRANSITION_SCALARS
        )
        body[256:1664] = b"".join(
            _digest(
                value[field],
                field,
                allow_zero=field
                in (
                    "model_state_publication_before_sha256",
                    "model_state_before_sha256",
                    "model_state_after_sha256",
                    "model_state_publication_after_sha256",
                    "completion_observation_sha256",
                    "completion_plan_sha256",
                    "completion_result_sha256",
                    "previous_transition_receipt_sha256",
                    "registry_previous_entry_sha256",
                ),
            )
            for field in TRANSITION_DIGESTS
        )
    except (KeyError, TypeError):
        raise GeneratedMediaProducerTransitionError(
            "invalid transition receipt"
        ) from None
    _validate_transition_shape(value)
    return bytes(body)


def _validate_transition_shape(value: Record) -> None:
    modality = value["modality"]
    kind = value["model_kind"]
    completion = value["completion_kind"]
    state_roots = (
        value["model_state_publication_before_sha256"],
        value["model_state_before_sha256"],
        value["model_state_after_sha256"],
        value["model_state_publication_after_sha256"],
    )
    completion_roots = (
        value["completion_observation_sha256"],
        value["completion_plan_sha256"],
        value["completion_result_sha256"],
    )
    if (
        modality not in registry.MODALITIES
        or kind not in (STATELESS_MODEL, STATEFUL_MODEL)
        or completion not in (NO_COMPLETION, PLAYBACK_COMPLETION, DISPLAY_COMPLETION)
        or value["request_epoch"] == 0
        or value["producer_generation"] == 0
        or value["unit_count"] == 0
        or value["timeline_end"] <= value["timeline_start"]
        or min(
            value["weights_bytes"],
            value["model_input_bytes"],
            value["model_output_bytes"],
            value["materializer_payload_bytes"],
            value["raw_output_bytes"],
            value["encoded_payload_bytes"],
        )
        <= 0
        or value["model_step_after"]
        != _checked_add(value["model_step_before"], 1, "model step")
        or (
            kind == STATELESS_MODEL
            and (
                value["model_state_before_bytes"] != 0
                or value["model_state_after_bytes"] != 0
                or any(root != ZERO for root in state_roots)
            )
        )
        or (
            kind == STATEFUL_MODEL
            and (
                value["model_state_before_bytes"] == 0
                or value["model_state_after_bytes"] == 0
                or value["model_state_before_bytes"] != value["model_state_after_bytes"]
                or any(root == ZERO for root in state_roots)
            )
        )
        or (
            modality == registry.IMAGE_MODALITY
            and (
                completion != NO_COMPLETION
                or value["producer_ordinal"] != 1
                or value["unit_start"] != value["registry_ordinal"]
                or value["unit_count"] != 1
                or value["timeline_start"] != value["registry_ordinal"]
                or value["timeline_end"] != value["registry_ordinal"] + 1
                or any(root != ZERO for root in completion_roots)
                or value["completion_sequence"] != 0
                or value["producer_state_generation_after_publication"]
                != value["producer_state_generation_after_completion"]
            )
        )
        or (
            modality == registry.AUDIO_MODALITY
            and (
                completion != PLAYBACK_COMPLETION
                or value["producer_ordinal"] != value["registry_ordinal"]
                or any(root == ZERO for root in completion_roots)
            )
        )
        or (
            modality == registry.VIDEO_MODALITY
            and (
                completion != DISPLAY_COMPLETION
                or value["producer_ordinal"] != value["registry_ordinal"]
                or any(root == ZERO for root in completion_roots)
            )
        )
        or (
            (value["registry_ordinal"] == 0)
            != (value["registry_previous_entry_sha256"] == ZERO)
        )
        or (
            (value["registry_ordinal"] == 0)
            != (value["previous_transition_receipt_sha256"] == ZERO)
        )
    ):
        raise GeneratedMediaProducerTransitionError("invalid transition receipt shape")
    materializer_root = materializer_execution_root_from_fields(
        modality=modality,
        producer_plan_sha256=value["producer_plan_or_manifest_sha256"],
        model_output_sha256=value["model_output_sha256"],
        payload_sha256=value["materializer_payload_sha256"],
        implementation_sha256=value["materializer_implementation_sha256"],
        raw_output_sha256=value["raw_output_sha256"],
        required_capabilities=value["materializer_required_capabilities"],
        model_output_bytes=value["model_output_bytes"],
        payload_bytes=value["materializer_payload_bytes"],
        raw_output_bytes=value["raw_output_bytes"],
    )
    projection_root = _producer_projection_root_from_receipt(value)
    if (
        value["materializer_execution_sha256"] != materializer_root
        or value["producer_projection_sha256"] != projection_root
    ):
        raise GeneratedMediaProducerTransitionError(
            "transition receipt execution binding mismatch"
        )


def encode_transition_receipt(value: Record) -> bytes:
    body = _transition_body(value)
    supplied = value.get("transition_receipt_sha256", ZERO)
    root = _root(TRANSITION_RECEIPT_DOMAIN, body)
    if supplied not in (ZERO, root):
        raise GeneratedMediaProducerTransitionError("transition receipt root mismatch")
    return body + root


def decode_transition_receipt(raw: bytes) -> Record:
    if (
        type(raw) is not bytes
        or len(raw) != TRANSITION_RECEIPT_BYTES
        or raw[:8] != TRANSITION_RECEIPT_MAGIC
        or _read(raw, 8) != TRANSITION_RECEIPT_ABI
        or _read(raw, 16) != TRANSITION_RECEIPT_BYTES
        or _read(raw, 24) != 0
        or any(raw[1664:1696])
    ):
        raise GeneratedMediaProducerTransitionError("invalid transition receipt wire")
    value: Record = {
        field: _read(raw, 32 + index * 8)
        for index, field in enumerate(TRANSITION_SCALARS)
    }
    value.update(
        {
            field: raw[256 + index * 32 : 288 + index * 32]
            for index, field in enumerate(TRANSITION_DIGESTS)
        }
    )
    value["transition_receipt_sha256"] = raw[1696:1728]
    if (
        encode_transition_receipt(value) != raw
        or transition_receipt_root(value) != value["transition_receipt_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("transition receipt root mismatch")
    return value


def receipt_table_root(receipt_table: bytes) -> bytes:
    return _root(
        RECEIPT_TABLE_DOMAIN,
        _bytes(receipt_table, "receipt table"),
    )


def batch_root(value: Record) -> bytes:
    return _root(BATCH_DOMAIN, _batch_body(value))


def _batch_body(value: Record) -> bytes:
    try:
        receipt_count = _u64(value["receipt_count"], "receipt count")
        total_bytes = _checked_add(
            BATCH_BYTES,
            receipt_count * TRANSITION_RECEIPT_BYTES,
            "batch evidence bytes",
        )
        body = bytearray(BATCH_BODY_BYTES)
        body[:32] = _wire_header(BATCH_MAGIC, BATCH_ABI, total_bytes)
        body[32:128] = b"".join(
            _u64_bytes(value[field], field) for field in BATCH_SCALARS
        )
        body[128:512] = b"".join(
            _digest(
                value[field],
                field,
                allow_zero=field
                in (
                    "previous_batch_sha256",
                    "terminal_image_receipt_sha256",
                    "terminal_audio_receipt_sha256",
                    "terminal_video_receipt_sha256",
                ),
            )
            for field in BATCH_DIGESTS
        )
    except (KeyError, TypeError):
        raise GeneratedMediaProducerTransitionError(
            "invalid transition batch"
        ) from None
    if (
        value["request_epoch"] == 0
        or value["registry_generation"] == 0
        or value["publication_sequence"] == 0
        or not 1 <= value["receipt_count"] <= registry.MAX_ENTRIES
        or value["receipt_table_bytes"]
        != value["receipt_count"] * TRANSITION_RECEIPT_BYTES
        or value["modality_mask"] == 0
        or value["modality_mask"] & ~0x7
    ):
        raise GeneratedMediaProducerTransitionError("invalid transition batch shape")
    return bytes(body)


def encode_batch_header(value: Record) -> bytes:
    body = _batch_body(value)
    supplied = value.get("batch_sha256", ZERO)
    root = _root(BATCH_DOMAIN, body)
    if supplied not in (ZERO, root):
        raise GeneratedMediaProducerTransitionError("transition batch root mismatch")
    return body + root


def decode_batch_header(raw: bytes) -> Record:
    receipt_count = (
        _read(raw, 56) if type(raw) is bytes and len(raw) == BATCH_BYTES else 0
    )
    expected_total = BATCH_BYTES + (receipt_count * TRANSITION_RECEIPT_BYTES)
    if (
        type(raw) is not bytes
        or len(raw) != BATCH_BYTES
        or raw[:8] != BATCH_MAGIC
        or _read(raw, 8) != BATCH_ABI
        or _read(raw, 16) != expected_total
        or _read(raw, 24) != 0
        or any(raw[512:608])
    ):
        raise GeneratedMediaProducerTransitionError("invalid transition batch wire")
    value: Record = {
        field: _read(raw, 32 + index * 8) for index, field in enumerate(BATCH_SCALARS)
    }
    value.update(
        {
            field: raw[128 + index * 32 : 160 + index * 32]
            for index, field in enumerate(BATCH_DIGESTS)
        }
    )
    value["batch_sha256"] = raw[608:640]
    if encode_batch_header(value) != raw or batch_root(value) != value["batch_sha256"]:
        raise GeneratedMediaProducerTransitionError("transition batch root mismatch")
    return value


def _reference_stateless_execution(
    plan: Record,
    weights: bytes,
    model_input: bytes,
) -> bytes:
    """Portable exact-u8 matrix projection used by the V1 oracle fixture."""

    if (
        plan["input_element_bytes"] != 1
        or plan["output_element_bytes"] != 1
        or len(weights) != plan["input_features"] * plan["output_dimensions"]
        or len(model_input) != plan["input_bytes"]
    ):
        raise GeneratedMediaProducerTransitionError(
            "stateless execution shape mismatch"
        )
    output = bytearray()
    features = plan["input_features"]
    dimensions = plan["output_dimensions"]
    for batch in range(plan["batch_items"]):
        input_start = batch * features
        for dimension in range(dimensions):
            weight_start = dimension * features
            accumulator = sum(
                model_input[input_start + feature] * weights[weight_start + feature]
                for feature in range(features)
            )
            if accumulator > plan["maximum_absolute_output"] or accumulator > 255:
                raise GeneratedMediaProducerTransitionError(
                    "stateless execution overflow"
                )
            output.append(accumulator)
    return bytes(output)


def _model_publication_after(
    before: Record,
    result_sha256: bytes,
) -> Record:
    return {
        "request_epoch": before["request_epoch"],
        "next_sequence": _checked_add(before["next_sequence"], 1, "model sequence"),
        "visible_results": _checked_add(
            before["visible_results"], 1, "visible model results"
        ),
        "artifact_sha256": before["artifact_sha256"],
        "previous_result_sha256": result_sha256,
    }


def _state_publication_after(
    before: Record,
    result_sha256: bytes,
    next_state: bytes,
) -> Record:
    value = {
        **before,
        "current_step": _checked_add(before["current_step"], 1, "stateful model step"),
        "current_state_sha256": hashlib.sha256(next_state).digest(),
        "previous_result_sha256": result_sha256,
        "publication_sha256": ZERO,
    }
    value["publication_sha256"] = stateful.publication_root(value)
    return stateful.validate_publication(value)


def _receipt_from_model_result(result: Record) -> Record:
    candidate = resource.resource_receipt(
        result["resource_bank_epoch"],
        result["resource_slot_index"],
        result["resource_generation"],
        result["resource_owner_key"],
        result["claim"],
    )
    if candidate["integrity"] != result["resource_integrity"]:
        raise GeneratedMediaProducerTransitionError("model resource receipt mismatch")
    return candidate


def _verify_model(witness: Record) -> Record:
    try:
        kind = _u64(witness["kind"], "model kind")
        artifact_wire = _bytes(
            witness["artifact_manifest_wire"], "artifact manifest wire"
        )
        plan_wire = _bytes(witness["plan_wire"], "model plan wire")
        result_wire = _bytes(witness["result_wire"], "model result wire")
        publication_before_wire = _bytes(
            witness["publication_before_wire"],
            "model publication before wire",
        )
        publication_after_wire = _bytes(
            witness["publication_after_wire"],
            "model publication after wire",
        )
        descriptor_wire = _bytes(
            witness["adapter_descriptor_wire"],
            "adapter descriptor wire",
        )
        weights = _bytes(witness["weights"], "model weights")
        model_input = _bytes(witness["input"], "model input")
        supplied_output = _bytes(witness["output"], "model output")
        support_records = witness["support_records"]

        artifact = model.decode_artifact(artifact_wire)
        plan = model.decode_plan(plan_wire)
        result = model.decode_result(result_wire)
        publication_before = decode_model_publication(publication_before_wire)
        publication_after = decode_model_publication(publication_after_wire)
        descriptor = decode_adapter_descriptor(descriptor_wire)
        support_root = support_set_root(support_records)
        model.require_support(support_records, plan)
    except GeneratedMediaProducerTransitionError:
        raise
    except (
        KeyError,
        TypeError,
        model.ModelContractError,
    ) as error:
        raise GeneratedMediaProducerTransitionError("invalid model witness") from error

    descriptor_pairs = (
        "family",
        "operation",
        "input_kind",
        "output_kind",
        "numerical_policy",
    )
    if (
        kind not in (STATELESS_MODEL, STATEFUL_MODEL)
        or artifact["artifact_sha256"] != plan["artifact_sha256"]
        or artifact["weights_sha256"] != hashlib.sha256(weights).digest()
        or len(weights) != plan["weight_bytes"]
        or len(model_input) != plan["input_bytes"]
        or len(supplied_output) != plan["output_bytes"]
        or publication_before["request_epoch"] != plan["request_epoch"]
        or publication_before["next_sequence"] != plan["publication_next_sequence"]
        or publication_before["artifact_sha256"] != plan["artifact_sha256"]
        or any(descriptor[field] != plan[field] for field in descriptor_pairs)
        or descriptor["max_batch_items"] < plan["batch_items"]
        or descriptor["max_input_features"] < plan["input_features"]
        or descriptor["max_output_dimensions"] < plan["output_dimensions"]
        or plan["required_capabilities"] & ~descriptor["allowed_capabilities"]
    ):
        raise GeneratedMediaProducerTransitionError("model witness binding mismatch")

    if kind == STATELESS_MODEL:
        if any(
            witness.get(field, b"")
            for field in (
                "state_publication_before_wire",
                "state_publication_after_wire",
                "checkpoint_wire",
                "checkpoint_previous_result_wire",
                "state_before",
                "state_after",
            )
        ):
            raise GeneratedMediaProducerTransitionError(
                "stateless witness carries state"
            )
        output = _reference_stateless_execution(plan, weights, model_input)
        state_before = b""
        state_after = b""
        state_publication_before = None
        state_publication_after = None
        checkpoint = None
        mapping_root = stateless_source_mapping_root(
            plan,
            weights,
            model_input,
            output,
            descriptor["adapter_sha256"],
        )
        model_step_before = plan["generation"] - 1
        model_step_after = plan["generation"]
    else:
        try:
            state_before = _bytes(witness["state_before"], "model state before")
            state_after = _bytes(witness["state_after"], "model state after")
            state_publication_before_wire = _bytes(
                witness["state_publication_before_wire"],
                "state publication before wire",
            )
            state_publication_after_wire = _bytes(
                witness["state_publication_after_wire"],
                "state publication after wire",
            )
            state_publication_before = stateful.decode_publication(
                state_publication_before_wire
            )
            state_publication_after = stateful.decode_publication(
                state_publication_after_wire
            )
            checkpoint_wire = _bytes(
                witness["checkpoint_wire"], "stateful checkpoint wire"
            )
            checkpoint_result_wire = _bytes(
                witness["checkpoint_previous_result_wire"],
                "checkpoint previous result wire",
            )
            checkpoint = continuation.decode_checkpoint(checkpoint_wire)
            checkpoint_result = model.decode_result(checkpoint_result_wire)
            output = stateful.reference_latent_step(
                state_before,
                model_input,
                weights,
            )
        except (
            KeyError,
            TypeError,
            stateful.StatefulModelAdapterError,
            continuation.StatefulModelContinuationError,
            model.ModelContractError,
        ) as error:
            raise GeneratedMediaProducerTransitionError(
                "invalid stateful model witness"
            ) from error
        if (
            len(state_before) != state_publication_before["state_bytes"]
            or len(state_after) != state_publication_before["state_bytes"]
            or state_publication_before["current_state_sha256"]
            != hashlib.sha256(state_before).digest()
            or state_publication_before["publication_sha256"]
            != plan["processor_state_sha256"]
            or state_publication_before["current_state_sha256"]
            != plan["cache_payload_sha256"]
        ):
            raise GeneratedMediaProducerTransitionError("stateful model input mismatch")
        try:
            reconstructed_publication = continuation.reconstruct_model_publication(
                checkpoint,
                state_publication_before,
            )
            reconstructed_checkpoint = continuation.make_checkpoint(
                source_bank_epoch=checkpoint["source_bank_epoch"],
                restore_plan={
                    field: checkpoint[field]
                    for field in (
                        "restore_bank_epoch",
                        "restore_owner_key",
                        "restore_tree_key",
                        "restore_authority_key",
                        "tenant_key",
                        "scope_key",
                        "allocation_key",
                        "binding_key",
                    )
                },
                model_publication=publication_before,
                state_publication=state_publication_before,
                last_result=checkpoint_result,
            )
        except continuation.StatefulModelContinuationError as error:
            raise GeneratedMediaProducerTransitionError(
                "checkpoint reconstruction failed"
            ) from error
        if (
            encode_model_publication(reconstructed_publication)
            != publication_before_wire
            or continuation.encode_checkpoint(reconstructed_checkpoint)
            != checkpoint_wire
        ):
            raise GeneratedMediaProducerTransitionError("checkpoint binding mismatch")
        mapping_root = stateful.transition_root(
            state_publication_before,
            plan,
            hashlib.sha256(output).digest(),
            hashlib.sha256(output).digest(),
            descriptor["adapter_sha256"],
        )
        model_step_before = state_publication_before["current_step"]
        model_step_after = model_step_before + 1

    if output != supplied_output or (kind == STATEFUL_MODEL and output != state_after):
        raise GeneratedMediaProducerTransitionError("model execution mismatch")

    receipt = _receipt_from_model_result(result)
    try:
        expected_result = model.make_result(
            publication_before,
            plan,
            receipt,
            output_sha256=hashlib.sha256(output).digest(),
            source_mapping_sha256=mapping_root,
            adapter_sha256=descriptor["adapter_sha256"],
        )
    except model.ModelContractError as error:
        raise GeneratedMediaProducerTransitionError(
            "model result reconstruction failed"
        ) from error
    if model.encode_result(expected_result) != result_wire:
        raise GeneratedMediaProducerTransitionError("model result mismatch")
    expected_publication_after = _model_publication_after(
        publication_before,
        result["result_sha256"],
    )
    if encode_model_publication(expected_publication_after) != publication_after_wire:
        raise GeneratedMediaProducerTransitionError(
            "model publication transition mismatch"
        )
    if kind == STATEFUL_MODEL:
        expected_state_publication_after = _state_publication_after(
            state_publication_before,
            result["result_sha256"],
            state_after,
        )
        if (
            stateful.encode_publication(expected_state_publication_after)
            != state_publication_after_wire
        ):
            raise GeneratedMediaProducerTransitionError(
                "state publication transition mismatch"
            )

    return {
        "kind": kind,
        "artifact": artifact,
        "artifact_wire": artifact_wire,
        "plan": plan,
        "plan_wire": plan_wire,
        "result": result,
        "result_wire": result_wire,
        "publication_before": publication_before,
        "publication_before_wire": publication_before_wire,
        "publication_after": publication_after,
        "publication_after_wire": publication_after_wire,
        "descriptor": descriptor,
        "descriptor_wire": descriptor_wire,
        "support_set_sha256": support_root,
        "weights": weights,
        "input": model_input,
        "output": output,
        "state_before": state_before,
        "state_after": state_after,
        "state_publication_before": state_publication_before,
        "state_publication_after": state_publication_after,
        "checkpoint": checkpoint,
        "mapping_sha256": mapping_root,
        "model_step_before": model_step_before,
        "model_step_after": model_step_after,
    }


def _delivery(witness: Record) -> Record:
    try:
        encoding_abi = _u64(witness["encoding_abi"], "encoding ABI")
        payload = _bytes(witness["encoded_payload"], "encoded payload")
        implementation = _digest(
            witness["encoder_implementation_sha256"],
            "encoder implementation",
        )
        format_root = _digest(witness["format_sha256"], "format root")
    except (KeyError, TypeError):
        raise GeneratedMediaProducerTransitionError(
            "invalid delivery witness"
        ) from None
    if encoding_abi == 0:
        raise GeneratedMediaProducerTransitionError("invalid delivery encoding ABI")
    return {
        "encoding_abi": encoding_abi,
        "payload": payload,
        "encoder_implementation_sha256": implementation,
        "format_sha256": format_root,
    }


def _registry_entry_input(
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
    delivery: Record,
) -> Record:
    return {
        "modality": modality,
        "ordinal": ordinal,
        "unit_start": unit_start,
        "unit_count": unit_count,
        "timeline_start": timeline_start,
        "timeline_end": timeline_end,
        "source_bytes": source_bytes,
        "encoding_abi": delivery["encoding_abi"],
        "completion_required": modality != registry.IMAGE_MODALITY,
        "completed": True,
        "artifact_sha256": artifact_sha256,
        "provenance_sha256": provenance_sha256,
        "result_sha256": result_sha256,
        "source_output_sha256": source_output_sha256,
        "media_object_sha256": media_object_sha256,
        "state_after_sha256": state_after_sha256,
        "completion_sha256": completion_sha256,
        "encoder_implementation_sha256": delivery["encoder_implementation_sha256"],
        "format_sha256": delivery["format_sha256"],
        "payload": delivery["payload"],
    }


def _verify_image(
    witness: Record,
    model_execution: Record,
    delivery: Record,
) -> Record:
    try:
        publication_before_wire = _bytes(
            witness["publication_before_wire"],
            "image publication before wire",
        )
        publication_after_wire = _bytes(
            witness["publication_after_wire"],
            "image publication after wire",
        )
        publication_before = decode_media_publication(publication_before_wire)
        publication_after = decode_media_publication(publication_after_wire)
        plan_wire = _bytes(witness["plan_wire"], "image plan wire")
        provenance_wire = _bytes(witness["provenance_wire"], "image provenance wire")
        result_wire = _bytes(witness["result_wire"], "image result wire")
        media_object_wire = _bytes(
            witness["media_object_wire"], "image media object wire"
        )
        receipt_wire = _bytes(
            witness["resource_receipt_wire"],
            "image resource receipt wire",
        )
        payload = _bytes(witness["materializer_payload"], "image decoder payload")
        raw_output = _bytes(witness["raw_output"], "image pixels")
        plan = image.decode_plan(plan_wire)
        provenance = image.decode_provenance(provenance_wire)
        result = image.decode_result(result_wire)
        media_object = media.decode_media_object(media_object_wire)
        receipt = decode_resource_receipt(receipt_wire)
    except GeneratedMediaProducerTransitionError:
        raise
    except (
        KeyError,
        TypeError,
        continuation.StatefulModelContinuationError,
        image.GeneratedImagePublicationError,
        media.MediaContractError,
    ) as error:
        raise GeneratedMediaProducerTransitionError("invalid image witness") from error
    if model_execution["kind"] != STATEFUL_MODEL:
        raise GeneratedMediaProducerTransitionError("image model must be stateful")
    try:
        reconstructed = continuation.reconstruct_model_publication(
            model_execution["checkpoint"],
            model_execution["state_publication_before"],
        )
        image.validate_bindings(
            plan,
            model_execution["artifact"],
            model_execution["checkpoint"],
            model_execution["plan"],
            model_execution["result"],
            model_execution["state_publication_after"],
            media_object,
            payload,
            publication_before,
        )
        decoded = image.reference_decode(model_execution["output"], payload)
        expected_provenance = image.make_provenance(
            plan, hashlib.sha256(decoded).digest()
        )
        expected_result, expected_after = image.make_result(
            plan_value=plan,
            provenance_value=expected_provenance,
            media_object=media_object,
            receipt=_runtime_resource_receipt(receipt),
            publication_state_before=publication_before,
        )
    except (
        continuation.StatefulModelContinuationError,
        image.GeneratedImagePublicationError,
        media.MediaContractError,
    ) as error:
        raise GeneratedMediaProducerTransitionError(
            "image execution verification failed"
        ) from error
    if (
        encode_model_publication(reconstructed)
        != model_execution["publication_before_wire"]
        or decoded != raw_output
        or image.encode_provenance(expected_provenance) != provenance_wire
        or image.encode_result(expected_result) != result_wire
        or encode_media_publication(expected_after) != publication_after_wire
        or media.encode_media_object(media_object) != media_object_wire
        or plan["image_index"] != 1
        or plan["visible_images_before"] != 0
        or plan["visible_images_after"] != 1
    ):
        raise GeneratedMediaProducerTransitionError("image execution binding mismatch")
    implementation = image.decoder_implementation_root()
    materializer_root = materializer_execution_root(
        modality=registry.IMAGE_MODALITY,
        producer_plan_sha256=plan["plan_sha256"],
        model_output=model_execution["output"],
        payload=payload,
        implementation_sha256=implementation,
        raw_output=raw_output,
        required_capabilities=plan["required_capabilities"],
    )
    return {
        "modality": registry.IMAGE_MODALITY,
        "completion_kind": NO_COMPLETION,
        "producer_generation": plan["generation"],
        "producer_ordinal": plan["image_index"],
        "producer_publication_sequence": plan["publication_sequence"],
        "completion_sequence": 0,
        "producer_state_generation_before": publication_before["visible_chunks"],
        "producer_state_generation_after_publication": publication_after[
            "visible_chunks"
        ],
        "producer_state_generation_after_completion": publication_after[
            "visible_chunks"
        ],
        "local_unit_start": 0,
        "unit_count": plan["logical_units"],
        "local_timeline_start": 0,
        "timeline_length": plan["logical_units"],
        "artifact_sha256": plan["artifact_sha256"],
        "producer_plan_sha256": plan["plan_sha256"],
        "producer_state_before_sha256": publication_before["publication_state_sha256"],
        "media_object_sha256": plan["media_object_sha256"],
        "payload": payload,
        "materializer_implementation_sha256": implementation,
        "materializer_execution_sha256": materializer_root,
        "raw_output": raw_output,
        "provenance_sha256": provenance["provenance_sha256"],
        "producer_receipt_wire_sha256": receipt["receipt_sha256"],
        "producer_resource_sha256": result["resource_receipt_sha256"],
        "publication_result_sha256": result["result_sha256"],
        "producer_state_after_publication_sha256": publication_after[
            "publication_state_sha256"
        ],
        "completion_observation_sha256": ZERO,
        "completion_plan_sha256": ZERO,
        "completion_result_sha256": ZERO,
        "producer_final_state_sha256": publication_after["publication_state_sha256"],
        "tenant_scope_sha256": plan["tenant_scope_sha256"],
        "metadata_policy_sha256": plan["metadata_policy_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
        "materializer_required_capabilities": plan["required_capabilities"],
        "previous_plan_sha256": plan["previous_plan_sha256"],
        "previous_result_sha256": plan["previous_result_sha256"],
        "previous_completion_sha256": ZERO,
        "delivery": delivery,
    }


def _verify_audio(
    witness: Record,
    model_execution: Record,
    delivery: Record,
) -> Record:
    try:
        pre = audio.decode_state(
            _bytes(witness["state_before_wire"], "audio pre-state wire")
        )
        pending = audio.decode_state(
            _bytes(witness["state_pending_wire"], "audio pending wire")
        )
        final = audio.decode_state(
            _bytes(witness["state_after_wire"], "audio final-state wire")
        )
        plan = audio.decode_plan(_bytes(witness["plan_wire"], "audio plan wire"))
        provenance = audio.decode_provenance(
            _bytes(witness["provenance_wire"], "audio provenance wire")
        )
        result = audio.decode_result(
            _bytes(witness["result_wire"], "audio result wire")
        )
        observation = audio.decode_observation(
            _bytes(witness["observation_wire"], "audio observation wire")
        )
        ack_plan = audio.decode_ack_plan(
            _bytes(witness["ack_plan_wire"], "audio ack plan wire")
        )
        ack_result = audio.decode_ack_result(
            _bytes(witness["ack_result_wire"], "audio ack result wire")
        )
        media_object_wire = _bytes(
            witness["media_object_wire"], "audio media object wire"
        )
        media.decode_media_object(media_object_wire)
        receipt = decode_resource_receipt(
            _bytes(
                witness["resource_receipt_wire"],
                "audio resource receipt wire",
            )
        )
        payload = _bytes(witness["materializer_payload"], "audio renderer payload")
        raw_output = _bytes(witness["raw_output"], "audio PCM")
    except GeneratedMediaProducerTransitionError:
        raise
    except (
        KeyError,
        TypeError,
        audio.GeneratedAudioPlaybackError,
        media.MediaContractError,
    ) as error:
        raise GeneratedMediaProducerTransitionError("invalid audio witness") from error

    rendered = audio.render_reference_pcm(model_execution["output"])
    expected_media_object = audio.audio_media_object(
        pre,
        frame_count=len(model_execution["output"]) // pre["channels"],
        output_sha256=hashlib.sha256(rendered).digest(),
        source_result_sha256=model_execution["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(model_execution["output"]).digest(),
    )
    expected_plan = audio.make_plan(
        pre,
        frame_count=len(model_execution["output"]) // pre["channels"],
        source_output_bytes=len(model_execution["output"]),
        source_result_sha256=model_execution["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(model_execution["output"]).digest(),
        media_object_sha256=media.media_object_sha256(
            media.encode_media_object(expected_media_object)
        ),
        maximum_output_bytes=plan["maximum_output_bytes"],
        required_capabilities=plan["required_capabilities"],
        renderer_abi=plan["renderer_abi"],
        renderer_payload_sha256=hashlib.sha256(payload).digest(),
        renderer_implementation_sha256=audio.REFERENCE_RENDERER_IMPLEMENTATION,
    )
    try:
        expected_provenance = audio.make_provenance(
            expected_plan, hashlib.sha256(rendered).digest()
        )
        expected_result = audio.make_result(
            expected_plan,
            expected_provenance,
            _runtime_resource_receipt(receipt),
        )
        expected_pending = audio.state_after_publication(
            pre, expected_plan, expected_result
        )
        expected_observation = audio.make_observation(
            expected_pending,
            sink_implementation_sha256=observation["sink_implementation_sha256"],
            sink_instance_sha256=observation["sink_instance_sha256"],
        )
        expected_ack_plan = audio.make_ack_plan(
            expected_pending,
            expected_result,
            expected_observation,
        )
        expected_final, expected_ack_result = audio.acknowledge(
            expected_pending,
            expected_result,
            expected_observation,
            expected_ack_plan,
        )
    except audio.GeneratedAudioPlaybackError as error:
        raise GeneratedMediaProducerTransitionError(
            "audio execution verification failed"
        ) from error
    exact = (
        rendered == raw_output,
        media.encode_media_object(expected_media_object) == media_object_wire,
        audio.encode_plan(expected_plan) == audio.encode_plan(plan),
        audio.encode_provenance(expected_provenance)
        == audio.encode_provenance(provenance),
        audio.encode_result(expected_result) == audio.encode_result(result),
        audio.encode_state(expected_pending) == audio.encode_state(pending),
        audio.encode_observation(expected_observation)
        == audio.encode_observation(observation),
        audio.encode_ack_plan(expected_ack_plan) == audio.encode_ack_plan(ack_plan),
        audio.encode_ack_result(expected_ack_result)
        == audio.encode_ack_result(ack_result),
        audio.encode_state(expected_final) == audio.encode_state(final),
    )
    if not all(exact):
        raise GeneratedMediaProducerTransitionError("audio execution binding mismatch")
    implementation = audio.REFERENCE_RENDERER_IMPLEMENTATION
    materializer_root = materializer_execution_root(
        modality=registry.AUDIO_MODALITY,
        producer_plan_sha256=plan["plan_sha256"],
        model_output=model_execution["output"],
        payload=payload,
        implementation_sha256=implementation,
        raw_output=raw_output,
        required_capabilities=plan["required_capabilities"],
    )
    return {
        "modality": registry.AUDIO_MODALITY,
        "completion_kind": PLAYBACK_COMPLETION,
        "producer_generation": plan["generation"],
        "producer_ordinal": plan["chunk_index"],
        "producer_publication_sequence": plan["publication_sequence"],
        "completion_sequence": ack_result["playback_sequence"],
        "producer_state_generation_before": pre["generation"],
        "producer_state_generation_after_publication": pending["generation"],
        "producer_state_generation_after_completion": final["generation"],
        "local_unit_start": plan["start_frame"],
        "unit_count": plan["frame_count"],
        "local_timeline_start": plan["start_frame"],
        "timeline_length": plan["frame_count"],
        "artifact_sha256": plan["artifact_sha256"],
        "producer_plan_sha256": plan["plan_sha256"],
        "producer_state_before_sha256": pre["state_sha256"],
        "media_object_sha256": plan["media_object_sha256"],
        "payload": payload,
        "materializer_implementation_sha256": implementation,
        "materializer_execution_sha256": materializer_root,
        "raw_output": raw_output,
        "provenance_sha256": provenance["provenance_sha256"],
        "producer_receipt_wire_sha256": receipt["receipt_sha256"],
        "producer_resource_sha256": result["resource_receipt_sha256"],
        "publication_result_sha256": result["result_sha256"],
        "producer_state_after_publication_sha256": pending["state_sha256"],
        "completion_observation_sha256": observation["observation_sha256"],
        "completion_plan_sha256": ack_plan["plan_sha256"],
        "completion_result_sha256": ack_result["result_sha256"],
        "producer_final_state_sha256": final["state_sha256"],
        "tenant_scope_sha256": plan["tenant_scope_sha256"],
        "metadata_policy_sha256": plan["metadata_policy_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
        "materializer_required_capabilities": plan["required_capabilities"],
        "previous_plan_sha256": ZERO,
        "previous_result_sha256": plan["previous_publication_result_sha256"],
        "previous_completion_sha256": ack_result["previous_ack_result_sha256"],
        "delivery": delivery,
    }


def _verify_video(
    witness: Record,
    model_execution: Record,
    delivery: Record,
) -> Record:
    try:
        pre = video.decode_state(
            _bytes(witness["state_before_wire"], "video pre-state wire")
        )
        pending = video.decode_state(
            _bytes(witness["state_pending_wire"], "video pending wire")
        )
        final = video.decode_state(
            _bytes(witness["state_after_wire"], "video final-state wire")
        )
        manifest = video.decode_manifest(
            _bytes(witness["manifest_wire"], "video manifest wire")
        )
        provenance = video.decode_provenance(
            _bytes(witness["provenance_wire"], "video provenance wire")
        )
        result = video.decode_result(
            _bytes(witness["result_wire"], "video result wire")
        )
        observation = video.decode_observation(
            _bytes(witness["observation_wire"], "video observation wire")
        )
        ack_plan = video.decode_ack_plan(
            _bytes(witness["ack_plan_wire"], "video ack plan wire")
        )
        ack_result = video.decode_ack_result(
            _bytes(witness["ack_result_wire"], "video ack result wire")
        )
        media_object_wire = _bytes(
            witness["media_object_wire"], "video media object wire"
        )
        media.decode_media_object(media_object_wire)
        receipt = decode_resource_receipt(
            _bytes(
                witness["resource_receipt_wire"],
                "video resource receipt wire",
            )
        )
        payload = _bytes(witness["materializer_payload"], "video renderer payload")
        raw_output = _bytes(witness["raw_output"], "video frames")
    except GeneratedMediaProducerTransitionError:
        raise
    except (
        KeyError,
        TypeError,
        video.GeneratedVideoDisplayError,
        media.MediaContractError,
    ) as error:
        raise GeneratedMediaProducerTransitionError("invalid video witness") from error

    rendered = video.render_reference_frames(model_execution["output"])
    first_root = hashlib.sha256(rendered[:4]).digest()
    second_root = hashlib.sha256(rendered[4:]).digest()
    provisional = video.make_manifest(
        pre,
        first_duration_ticks=manifest["first_duration_ticks"],
        second_duration_ticks=manifest["second_duration_ticks"],
        source_output_bytes=len(model_execution["output"]),
        source_result_sha256=model_execution["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(model_execution["output"]).digest(),
        media_object_sha256=hashlib.sha256(
            b"generated video placeholder media"
        ).digest(),
        first_frame_sha256=first_root,
        second_frame_sha256=second_root,
        maximum_renderer_output_bytes=manifest["maximum_output_bytes"],
        required_capabilities=manifest["required_capabilities"],
        renderer_abi=manifest["renderer_abi"],
        renderer_payload_sha256=hashlib.sha256(payload).digest(),
        renderer_implementation_sha256=video.REFERENCE_RENDERER_IMPLEMENTATION,
    )
    expected_media_object = {
        "kind": media.VIDEO,
        "semantic_abi": video.RAW_VIDEO_SEMANTIC_ABI,
        "byte_length": len(rendered),
        "container_id": video.RAW_CONTAINER_ID,
        "codec_id": video.GRAY8_FRAME_CODEC_ID,
        "axes": (2, 2, 2),
        "time_base": (1, 1_000),
        "tenant_scope_sha256": pre["tenant_scope_sha256"],
        "content_sha256": hashlib.sha256(rendered).digest(),
        "metadata_policy_sha256": pre["metadata_policy_sha256"],
        "provenance_sha256": video.source_provenance_root(provisional),
    }
    expected_media_object = media.decode_media_object(
        media.encode_media_object(expected_media_object)
    )
    expected_manifest = video.make_manifest(
        pre,
        first_duration_ticks=manifest["first_duration_ticks"],
        second_duration_ticks=manifest["second_duration_ticks"],
        source_output_bytes=len(model_execution["output"]),
        source_result_sha256=model_execution["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(model_execution["output"]).digest(),
        media_object_sha256=media.media_object_sha256(
            media.encode_media_object(expected_media_object)
        ),
        first_frame_sha256=first_root,
        second_frame_sha256=second_root,
        maximum_renderer_output_bytes=manifest["maximum_output_bytes"],
        required_capabilities=manifest["required_capabilities"],
        renderer_abi=manifest["renderer_abi"],
        renderer_payload_sha256=hashlib.sha256(payload).digest(),
        renderer_implementation_sha256=video.REFERENCE_RENDERER_IMPLEMENTATION,
    )
    try:
        expected_provenance = video.make_provenance(
            expected_manifest, hashlib.sha256(rendered).digest()
        )
        expected_result = video.make_result(
            expected_manifest,
            expected_provenance,
            _runtime_resource_receipt(receipt),
        )
        expected_pending = video.state_after_publication(
            pre, expected_manifest, expected_result
        )
        expected_observation = video.make_observation(
            expected_pending,
            sink_implementation_sha256=observation["sink_implementation_sha256"],
            sink_instance_sha256=observation["sink_instance_sha256"],
        )
        expected_ack_plan = video.make_ack_plan(
            expected_pending,
            expected_result,
            expected_observation,
        )
        expected_final, expected_ack_result = video.acknowledge(
            expected_pending,
            expected_result,
            expected_observation,
            expected_ack_plan,
        )
    except video.GeneratedVideoDisplayError as error:
        raise GeneratedMediaProducerTransitionError(
            "video execution verification failed"
        ) from error
    exact = (
        rendered == raw_output,
        media.encode_media_object(expected_media_object) == media_object_wire,
        video.encode_manifest(expected_manifest) == video.encode_manifest(manifest),
        video.encode_provenance(expected_provenance)
        == video.encode_provenance(provenance),
        video.encode_result(expected_result) == video.encode_result(result),
        video.encode_state(expected_pending) == video.encode_state(pending),
        video.encode_observation(expected_observation)
        == video.encode_observation(observation),
        video.encode_ack_plan(expected_ack_plan) == video.encode_ack_plan(ack_plan),
        video.encode_ack_result(expected_ack_result)
        == video.encode_ack_result(ack_result),
        video.encode_state(expected_final) == video.encode_state(final),
    )
    if not all(exact):
        raise GeneratedMediaProducerTransitionError("video execution binding mismatch")
    implementation = video.REFERENCE_RENDERER_IMPLEMENTATION
    materializer_root = materializer_execution_root(
        modality=registry.VIDEO_MODALITY,
        producer_plan_sha256=manifest["manifest_sha256"],
        model_output=model_execution["output"],
        payload=payload,
        implementation_sha256=implementation,
        raw_output=raw_output,
        required_capabilities=manifest["required_capabilities"],
    )
    return {
        "modality": registry.VIDEO_MODALITY,
        "completion_kind": DISPLAY_COMPLETION,
        "producer_generation": manifest["generation"],
        "producer_ordinal": manifest["segment_index"],
        "producer_publication_sequence": manifest["publication_sequence"],
        "completion_sequence": ack_result["display_sequence"],
        "producer_state_generation_before": pre["generation"],
        "producer_state_generation_after_publication": pending["generation"],
        "producer_state_generation_after_completion": final["generation"],
        "local_unit_start": manifest["first_frame_ordinal"],
        "unit_count": manifest["frame_count"],
        "local_timeline_start": manifest["start_tick"],
        "timeline_length": manifest["end_tick"] - manifest["start_tick"],
        "artifact_sha256": manifest["artifact_sha256"],
        "producer_plan_sha256": manifest["manifest_sha256"],
        "producer_state_before_sha256": pre["state_sha256"],
        "media_object_sha256": manifest["media_object_sha256"],
        "payload": payload,
        "materializer_implementation_sha256": implementation,
        "materializer_execution_sha256": materializer_root,
        "raw_output": raw_output,
        "provenance_sha256": provenance["provenance_sha256"],
        "producer_receipt_wire_sha256": receipt["receipt_sha256"],
        "producer_resource_sha256": result["resource_receipt_sha256"],
        "publication_result_sha256": result["result_sha256"],
        "producer_state_after_publication_sha256": pending["state_sha256"],
        "completion_observation_sha256": observation["observation_sha256"],
        "completion_plan_sha256": ack_plan["plan_sha256"],
        "completion_result_sha256": ack_result["result_sha256"],
        "producer_final_state_sha256": final["state_sha256"],
        "tenant_scope_sha256": manifest["tenant_scope_sha256"],
        "metadata_policy_sha256": manifest["metadata_policy_sha256"],
        "challenge_sha256": manifest["challenge_sha256"],
        "materializer_required_capabilities": manifest["required_capabilities"],
        "previous_plan_sha256": ZERO,
        "previous_result_sha256": manifest["previous_publication_result_sha256"],
        "previous_completion_sha256": ack_result["previous_ack_result_sha256"],
        "delivery": delivery,
    }


def _verify_output(witness: Record) -> Record:
    try:
        modality = _u64(witness["modality"], "modality")
        model_execution = _verify_model(witness["model"])
        delivery = _delivery(witness["delivery"])
        producer = witness["producer"]
    except (KeyError, TypeError):
        raise GeneratedMediaProducerTransitionError("invalid output witness") from None
    if modality == registry.IMAGE_MODALITY:
        producer_execution = _verify_image(producer, model_execution, delivery)
    elif modality == registry.AUDIO_MODALITY:
        producer_execution = _verify_audio(producer, model_execution, delivery)
    elif modality == registry.VIDEO_MODALITY:
        producer_execution = _verify_video(producer, model_execution, delivery)
    else:
        raise GeneratedMediaProducerTransitionError("invalid modality")
    if (
        producer_execution["modality"] != modality
        or producer_execution["artifact_sha256"]
        != model_execution["artifact"]["artifact_sha256"]
        or producer_execution["challenge_sha256"]
        != model_execution["result"]["challenge_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("model/producer binding mismatch")
    return {
        "model": model_execution,
        "producer": producer_execution,
    }


def _terminal_by_modality(
    entries: list[Record],
) -> dict[int, Record | None]:
    terminals: dict[int, Record | None] = {
        modality: None for modality in registry.MODALITIES
    }
    for entry in entries:
        terminals[entry["modality"]] = entry
    return terminals


def _receipt_terminals(
    receipts: list[Record],
) -> dict[int, Record | None]:
    terminals: dict[int, Record | None] = {
        modality: None for modality in registry.MODALITIES
    }
    for receipt in receipts:
        terminals[receipt["modality"]] = receipt
    return terminals


def _registry_coordinates(
    prior: Record | None,
    producer: Record,
) -> tuple[int, int, int, int, int]:
    if prior is None:
        ordinal = 0
        unit_start = 0
        timeline_start = 0
    else:
        ordinal = _checked_add(prior["ordinal"], 1, "registry ordinal")
        unit_start = prior["unit_end"]
        timeline_start = prior["timeline_end"]
    unit_count = producer["unit_count"]
    timeline_end = _checked_add(
        timeline_start,
        producer["timeline_length"],
        "registry timeline end",
    )
    if producer["modality"] != registry.IMAGE_MODALITY and (
        producer["producer_ordinal"] != ordinal
        or producer["local_unit_start"] != unit_start
        or producer["local_timeline_start"] != timeline_start
    ):
        raise GeneratedMediaProducerTransitionError(
            "producer/registry coordinate mismatch"
        )
    return (
        ordinal,
        unit_start,
        unit_count,
        timeline_start,
        timeline_end,
    )


def _validate_producer_predecessor(
    producer: Record,
    registry_ordinal: int,
    previous: Record | None,
) -> None:
    if (
        producer["modality"] != registry.IMAGE_MODALITY
        and producer["producer_ordinal"] != registry_ordinal
    ):
        raise GeneratedMediaProducerTransitionError("producer ordinal mismatch")
    if previous is None:
        if registry_ordinal != 0:
            raise GeneratedMediaProducerTransitionError("missing producer predecessor")
        if producer["modality"] != registry.IMAGE_MODALITY and (
            producer["previous_result_sha256"] != ZERO
            or producer["previous_completion_sha256"] != ZERO
        ):
            raise GeneratedMediaProducerTransitionError("invalid producer genesis")
        return
    if producer["previous_result_sha256"] != previous["publication_result_sha256"]:
        raise GeneratedMediaProducerTransitionError(
            "producer result predecessor mismatch"
        )
    if producer["modality"] == registry.IMAGE_MODALITY:
        if (
            producer["previous_plan_sha256"]
            != previous["producer_plan_or_manifest_sha256"]
        ):
            raise GeneratedMediaProducerTransitionError(
                "image plan predecessor mismatch"
            )
    elif (
        producer["previous_completion_sha256"] != previous["completion_result_sha256"]
        or producer["producer_state_before_sha256"]
        != previous["producer_final_state_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError(
            "producer state predecessor mismatch"
        )


def _lineage_from_producer(producer: Record) -> Record:
    return {
        "producer_plan_or_manifest_sha256": producer["producer_plan_sha256"],
        "publication_result_sha256": producer["publication_result_sha256"],
        "completion_result_sha256": producer["completion_result_sha256"],
        "producer_final_state_sha256": producer["producer_final_state_sha256"],
    }


def _projection(
    producer: Record,
    *,
    registry_ordinal: int,
    unit_start: int,
    timeline_start: int,
    timeline_end: int,
) -> Record:
    return {
        "modality": producer["modality"],
        "producer_generation": producer["producer_generation"],
        "producer_ordinal": producer["producer_ordinal"],
        "registry_ordinal": registry_ordinal,
        "unit_start": unit_start,
        "unit_count": producer["unit_count"],
        "timeline_start": timeline_start,
        "timeline_end": timeline_end,
        "raw_output_bytes": len(producer["raw_output"]),
        "completion_kind": producer["completion_kind"],
        "artifact_sha256": producer["artifact_sha256"],
        "producer_plan_sha256": producer["producer_plan_sha256"],
        "provenance_sha256": producer["provenance_sha256"],
        "publication_result_sha256": producer["publication_result_sha256"],
        "raw_output_sha256": hashlib.sha256(producer["raw_output"]).digest(),
        "state_before_sha256": producer["producer_state_before_sha256"],
        "state_after_publication_sha256": producer[
            "producer_state_after_publication_sha256"
        ],
        "observation_sha256": producer["completion_observation_sha256"],
        "ack_plan_sha256": producer["completion_plan_sha256"],
        "completion_sha256": producer["completion_result_sha256"],
        "final_state_sha256": producer["producer_final_state_sha256"],
        "tenant_scope_sha256": producer["tenant_scope_sha256"],
        "metadata_policy_sha256": producer["metadata_policy_sha256"],
        "challenge_sha256": producer["challenge_sha256"],
    }


def _transition_value(
    *,
    execution: Record,
    generation_plan_sha256: bytes,
    registry_entry: Record,
    previous_transition_sha256: bytes,
    registry_manifest_sha256: bytes,
    registry_archive_sha256: bytes,
) -> Record:
    model_execution = execution["model"]
    producer = execution["producer"]
    projection = _projection(
        producer,
        registry_ordinal=registry_entry["ordinal"],
        unit_start=registry_entry["unit_start"],
        timeline_start=registry_entry["timeline_start"],
        timeline_end=registry_entry["timeline_end"],
    )
    delivery = producer["delivery"]
    state_before_bytes = len(model_execution["state_before"])
    state_after_bytes = len(model_execution["state_after"])
    value: Record = {
        "modality": producer["modality"],
        "model_kind": model_execution["kind"],
        "completion_kind": producer["completion_kind"],
        "request_epoch": model_execution["plan"]["request_epoch"],
        "producer_generation": producer["producer_generation"],
        "producer_ordinal": producer["producer_ordinal"],
        "registry_ordinal": registry_entry["ordinal"],
        "unit_start": registry_entry["unit_start"],
        "unit_count": registry_entry["unit_count"],
        "timeline_start": registry_entry["timeline_start"],
        "timeline_end": registry_entry["timeline_end"],
        "weights_bytes": len(model_execution["weights"]),
        "model_input_bytes": len(model_execution["input"]),
        "model_state_before_bytes": state_before_bytes,
        "model_output_bytes": len(model_execution["output"]),
        "model_state_after_bytes": state_after_bytes,
        "materializer_payload_bytes": len(producer["payload"]),
        "raw_output_bytes": len(producer["raw_output"]),
        "encoded_payload_bytes": len(delivery["payload"]),
        "producer_publication_sequence": producer["producer_publication_sequence"],
        "completion_sequence": producer["completion_sequence"],
        "model_required_capabilities": model_execution["plan"]["required_capabilities"],
        "materializer_required_capabilities": producer[
            "materializer_required_capabilities"
        ],
        "model_step_before": model_execution["model_step_before"],
        "model_step_after": model_execution["model_step_after"],
        "producer_state_generation_before": producer[
            "producer_state_generation_before"
        ],
        "producer_state_generation_after_publication": producer[
            "producer_state_generation_after_publication"
        ],
        "producer_state_generation_after_completion": producer[
            "producer_state_generation_after_completion"
        ],
        "tenant_scope_sha256": producer["tenant_scope_sha256"],
        "metadata_policy_sha256": producer["metadata_policy_sha256"],
        "challenge_sha256": producer["challenge_sha256"],
        "generation_plan_sha256": generation_plan_sha256,
        "artifact_manifest_sha256": model_execution["artifact"]["artifact_sha256"],
        "adapter_descriptor_sha256": model_execution["descriptor"]["descriptor_sha256"],
        "support_set_sha256": model_execution["support_set_sha256"],
        "model_plan_sha256": model_execution["plan"]["plan_sha256"],
        "model_publication_before_sha256": model_execution["publication_before"][
            "publication_state_sha256"
        ],
        "model_state_publication_before_sha256": (
            ZERO
            if model_execution["kind"] == STATELESS_MODEL
            else model_execution["state_publication_before"]["publication_sha256"]
        ),
        "weights_sha256": hashlib.sha256(model_execution["weights"]).digest(),
        "model_input_sha256": hashlib.sha256(model_execution["input"]).digest(),
        "model_state_before_sha256": (
            ZERO
            if model_execution["kind"] == STATELESS_MODEL
            else hashlib.sha256(model_execution["state_before"]).digest()
        ),
        "model_output_sha256": hashlib.sha256(model_execution["output"]).digest(),
        "model_state_after_sha256": (
            ZERO
            if model_execution["kind"] == STATELESS_MODEL
            else hashlib.sha256(model_execution["state_after"]).digest()
        ),
        "model_transition_or_source_mapping_sha256": model_execution["mapping_sha256"],
        "model_result_sha256": model_execution["result"]["result_sha256"],
        "model_publication_after_sha256": model_execution["publication_after"][
            "publication_state_sha256"
        ],
        "model_state_publication_after_sha256": (
            ZERO
            if model_execution["kind"] == STATELESS_MODEL
            else model_execution["state_publication_after"]["publication_sha256"]
        ),
        "producer_plan_or_manifest_sha256": producer["producer_plan_sha256"],
        "producer_state_before_sha256": producer["producer_state_before_sha256"],
        "media_object_sha256": producer["media_object_sha256"],
        "materializer_payload_sha256": hashlib.sha256(producer["payload"]).digest(),
        "materializer_implementation_sha256": producer[
            "materializer_implementation_sha256"
        ],
        "materializer_execution_sha256": producer["materializer_execution_sha256"],
        "raw_output_sha256": hashlib.sha256(producer["raw_output"]).digest(),
        "provenance_sha256": producer["provenance_sha256"],
        "producer_receipt_wire_sha256": producer["producer_receipt_wire_sha256"],
        "producer_resource_sha256": producer["producer_resource_sha256"],
        "publication_result_sha256": producer["publication_result_sha256"],
        "producer_state_after_publication_sha256": producer[
            "producer_state_after_publication_sha256"
        ],
        "completion_observation_sha256": producer["completion_observation_sha256"],
        "completion_plan_sha256": producer["completion_plan_sha256"],
        "completion_result_sha256": producer["completion_result_sha256"],
        "producer_final_state_sha256": producer["producer_final_state_sha256"],
        "encoder_implementation_sha256": delivery["encoder_implementation_sha256"],
        "format_sha256": delivery["format_sha256"],
        "encoded_payload_sha256": hashlib.sha256(delivery["payload"]).digest(),
        "previous_transition_receipt_sha256": previous_transition_sha256,
        "producer_projection_sha256": producer_projection_root(projection),
        "registry_previous_entry_sha256": registry_entry["previous_entry_sha256"],
        "registry_entry_sha256": registry_entry["entry_sha256"],
        "registry_manifest_sha256": registry_manifest_sha256,
        "registry_archive_sha256": registry_archive_sha256,
    }
    value["transition_receipt_sha256"] = transition_receipt_root(value)
    return value


def _registry_entry_for_execution(
    execution: Record,
    coordinates: tuple[int, int, int, int, int],
) -> Record:
    producer = execution["producer"]
    ordinal, unit_start, unit_count, timeline_start, timeline_end = coordinates
    return _registry_entry_input(
        modality=producer["modality"],
        ordinal=ordinal,
        unit_start=unit_start,
        unit_count=unit_count,
        timeline_start=timeline_start,
        timeline_end=timeline_end,
        source_bytes=len(producer["raw_output"]),
        artifact_sha256=producer["artifact_sha256"],
        provenance_sha256=producer["provenance_sha256"],
        result_sha256=producer["publication_result_sha256"],
        source_output_sha256=hashlib.sha256(producer["raw_output"]).digest(),
        media_object_sha256=producer["media_object_sha256"],
        state_after_sha256=producer["producer_final_state_sha256"],
        completion_sha256=producer["completion_result_sha256"],
        delivery=producer["delivery"],
    )


def verify_and_encode_batch(
    previous: Record | None,
    generation_plan_sha256: bytes,
    witnesses: list[Record],
) -> Record:
    """Replay one generation and emit evidence plus an unchanged registry."""

    generation_plan_sha256 = _digest(generation_plan_sha256, "generation plan root")
    if type(witnesses) is not list or not 1 <= len(witnesses) <= 12:
        raise GeneratedMediaProducerTransitionError("invalid output witness count")
    previous_checked = None
    if previous is not None:
        previous_checked = decode_batch(
            previous["evidence_bytes"],
            previous["registry"]["archive_bytes"],
            previous.get("previous"),
        )
    executions = [_verify_output(witness) for witness in witnesses]
    modalities = [execution["producer"]["modality"] for execution in executions]
    if modalities != sorted(modalities):
        raise GeneratedMediaProducerTransitionError("non-canonical output order")
    common = executions[0]["producer"]
    for execution in executions:
        producer = execution["producer"]
        if any(
            producer[field] != common[field]
            for field in (
                "tenant_scope_sha256",
                "metadata_policy_sha256",
                "challenge_sha256",
            )
        ):
            raise GeneratedMediaProducerTransitionError("output envelope mismatch")
    request_epoch = executions[0]["model"]["plan"]["request_epoch"]
    if any(
        execution["model"]["plan"]["request_epoch"] != request_epoch
        for execution in executions
    ):
        raise GeneratedMediaProducerTransitionError("output request mismatch")

    previous_registry = (
        None if previous_checked is None else previous_checked["registry"]
    )
    prior_entries = (
        {modality: None for modality in registry.MODALITIES}
        if previous_registry is None
        else _terminal_by_modality(previous_registry["entries"])
    )
    prior_lineage = (
        {modality: None for modality in registry.MODALITIES}
        if previous_checked is None
        else _receipt_terminals(previous_checked["receipts"])
    )
    entry_inputs: list[Record] = []
    for execution in executions:
        producer = execution["producer"]
        modality = producer["modality"]
        coordinates = _registry_coordinates(prior_entries[modality], producer)
        _validate_producer_predecessor(
            producer,
            coordinates[0],
            prior_lineage[modality],
        )
        entry_input = _registry_entry_for_execution(execution, coordinates)
        entry_inputs.append(entry_input)
        prior_entries[modality] = {
            **entry_input,
            "unit_end": coordinates[1] + coordinates[2],
            "timeline_end": coordinates[4],
            "entry_sha256": ZERO,
        }
        prior_lineage[modality] = _lineage_from_producer(producer)

    generation = (
        1
        if previous_registry is None
        else previous_registry["manifest"]["generation"] + 1
    )
    publication_sequence = (
        1
        if previous_registry is None
        else previous_registry["manifest"]["publication_sequence"] + 1
    )
    metadata = {
        "request_epoch": request_epoch,
        "generation": generation,
        "publication_sequence": publication_sequence,
        "generation_plan_sha256": generation_plan_sha256,
        "tenant_scope_sha256": common["tenant_scope_sha256"],
        "metadata_policy_sha256": common["metadata_policy_sha256"],
        "challenge_sha256": common["challenge_sha256"],
    }
    try:
        registry_value = registry.encode_archive(
            previous_registry,
            metadata,
            entry_inputs,
        )
    except registry.GeneratedMediaOutputRegistryError as error:
        raise GeneratedMediaProducerTransitionError(
            "registry construction failed"
        ) from error

    previous_receipt_terminals = (
        {modality: None for modality in registry.MODALITIES}
        if previous_checked is None
        else _receipt_terminals(previous_checked["receipts"])
    )
    receipts: list[Record] = []
    for execution, entry in zip(executions, registry_value["entries"]):
        modality = execution["producer"]["modality"]
        prior_receipt = previous_receipt_terminals[modality]
        receipt = _transition_value(
            execution=execution,
            generation_plan_sha256=generation_plan_sha256,
            registry_entry=entry,
            previous_transition_sha256=(
                ZERO
                if prior_receipt is None
                else prior_receipt["transition_receipt_sha256"]
            ),
            registry_manifest_sha256=registry_value["manifest"]["manifest_sha256"],
            registry_archive_sha256=registry_value["archive_sha256"],
        )
        receipts.append(receipt)
        previous_receipt_terminals[modality] = receipt

    receipt_wires = [encode_transition_receipt(receipt) for receipt in receipts]
    receipt_table = b"".join(receipt_wires)
    terminals = _receipt_terminals(receipts)
    header: Record = {
        "request_epoch": request_epoch,
        "registry_generation": generation,
        "publication_sequence": publication_sequence,
        "receipt_count": len(receipts),
        "receipt_table_bytes": len(receipt_table),
        "total_model_input_bytes": sum(
            receipt["model_input_bytes"] for receipt in receipts
        ),
        "total_model_output_bytes": sum(
            receipt["model_output_bytes"] for receipt in receipts
        ),
        "total_model_state_transition_bytes": sum(
            receipt["model_state_before_bytes"] + receipt["model_state_after_bytes"]
            for receipt in receipts
        ),
        "total_materializer_payload_bytes": sum(
            receipt["materializer_payload_bytes"] for receipt in receipts
        ),
        "total_raw_output_bytes": sum(
            receipt["raw_output_bytes"] for receipt in receipts
        ),
        "total_encoded_payload_bytes": sum(
            receipt["encoded_payload_bytes"] for receipt in receipts
        ),
        "modality_mask": registry_value["manifest"]["modality_mask"],
        "generation_plan_sha256": generation_plan_sha256,
        "tenant_scope_sha256": common["tenant_scope_sha256"],
        "metadata_policy_sha256": common["metadata_policy_sha256"],
        "challenge_sha256": common["challenge_sha256"],
        "receipt_table_sha256": receipt_table_root(receipt_table),
        "previous_batch_sha256": (
            ZERO
            if previous_checked is None
            else previous_checked["header"]["batch_sha256"]
        ),
        "registry_manifest_sha256": registry_value["manifest"]["manifest_sha256"],
        "registry_archive_sha256": registry_value["archive_sha256"],
        "first_receipt_sha256": receipts[0]["transition_receipt_sha256"],
        "terminal_image_receipt_sha256": (
            ZERO
            if terminals[registry.IMAGE_MODALITY] is None
            else terminals[registry.IMAGE_MODALITY]["transition_receipt_sha256"]
        ),
        "terminal_audio_receipt_sha256": (
            ZERO
            if terminals[registry.AUDIO_MODALITY] is None
            else terminals[registry.AUDIO_MODALITY]["transition_receipt_sha256"]
        ),
        "terminal_video_receipt_sha256": (
            ZERO
            if terminals[registry.VIDEO_MODALITY] is None
            else terminals[registry.VIDEO_MODALITY]["transition_receipt_sha256"]
        ),
    }
    header["batch_sha256"] = batch_root(header)
    evidence = encode_batch_header(header) + receipt_table
    result = decode_batch(
        evidence,
        registry_value["archive_bytes"],
        previous_checked,
    )
    result["previous"] = previous_checked
    return result


def _compare_receipt_to_entry(
    receipt: Record,
    entry: Record,
) -> None:
    pairs = (
        ("modality", "modality"),
        ("registry_ordinal", "ordinal"),
        ("unit_start", "unit_start"),
        ("unit_count", "unit_count"),
        ("timeline_start", "timeline_start"),
        ("timeline_end", "timeline_end"),
        ("raw_output_bytes", "source_bytes"),
        ("artifact_manifest_sha256", "artifact_sha256"),
        ("provenance_sha256", "provenance_sha256"),
        ("publication_result_sha256", "result_sha256"),
        ("raw_output_sha256", "source_output_sha256"),
        ("media_object_sha256", "media_object_sha256"),
        ("producer_final_state_sha256", "state_after_sha256"),
        ("completion_result_sha256", "completion_sha256"),
        ("encoder_implementation_sha256", "encoder_implementation_sha256"),
        ("format_sha256", "format_sha256"),
        ("registry_previous_entry_sha256", "previous_entry_sha256"),
        ("registry_entry_sha256", "entry_sha256"),
    )
    if any(receipt[left] != entry[right] for left, right in pairs):
        raise GeneratedMediaProducerTransitionError(
            "transition/registry entry mismatch"
        )


def decode_batch(
    evidence: bytes,
    registry_archive: bytes,
    previous: Record | None,
) -> Record:
    """Decode structural evidence and bind it to the exact registry archive."""

    if type(evidence) is not bytes or len(evidence) < BATCH_BYTES:
        raise GeneratedMediaProducerTransitionError("invalid transition evidence")
    header = decode_batch_header(evidence[:BATCH_BYTES])
    expected_bytes = BATCH_BYTES + header["receipt_count"] * TRANSITION_RECEIPT_BYTES
    if len(evidence) != expected_bytes:
        raise GeneratedMediaProducerTransitionError("transition evidence size mismatch")
    receipt_table = evidence[BATCH_BYTES:]
    if (
        len(receipt_table) != header["receipt_table_bytes"]
        or receipt_table_root(receipt_table) != header["receipt_table_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("receipt table mismatch")
    receipts = [
        decode_transition_receipt(
            receipt_table[
                index * TRANSITION_RECEIPT_BYTES : (index + 1)
                * TRANSITION_RECEIPT_BYTES
            ]
        )
        for index in range(header["receipt_count"])
    ]
    previous_registry = None if previous is None else previous["registry"]
    try:
        registry_value = registry.decode_archive(registry_archive, previous_registry)
    except registry.GeneratedMediaOutputRegistryError as error:
        raise GeneratedMediaProducerTransitionError(
            "invalid registry archive"
        ) from error
    if (
        header["registry_generation"] != registry_value["manifest"]["generation"]
        or header["publication_sequence"]
        != registry_value["manifest"]["publication_sequence"]
        or header["request_epoch"] != registry_value["manifest"]["request_epoch"]
        or header["modality_mask"] != registry_value["manifest"]["modality_mask"]
        or header["generation_plan_sha256"]
        != registry_value["manifest"]["generation_plan_sha256"]
        or header["tenant_scope_sha256"]
        != registry_value["manifest"]["tenant_scope_sha256"]
        or header["metadata_policy_sha256"]
        != registry_value["manifest"]["metadata_policy_sha256"]
        or header["challenge_sha256"] != registry_value["manifest"]["challenge_sha256"]
        or header["registry_manifest_sha256"]
        != registry_value["manifest"]["manifest_sha256"]
        or header["registry_archive_sha256"] != registry_value["archive_sha256"]
        or len(receipts) != len(registry_value["entries"])
    ):
        raise GeneratedMediaProducerTransitionError("batch/registry mismatch")
    expected_previous_batch = (
        ZERO if previous is None else previous["header"]["batch_sha256"]
    )
    if header["previous_batch_sha256"] != expected_previous_batch:
        raise GeneratedMediaProducerTransitionError("previous batch mismatch")
    pairs = [(receipt["modality"], receipt["registry_ordinal"]) for receipt in receipts]
    if pairs != sorted(pairs) or len(set(pairs)) != len(pairs):
        raise GeneratedMediaProducerTransitionError("non-canonical receipt order")
    prior_receipts = (
        {modality: None for modality in registry.MODALITIES}
        if previous is None
        else _receipt_terminals(previous["receipts"])
    )
    for receipt, entry, payload in zip(
        receipts,
        registry_value["entries"],
        registry_value["payloads"],
    ):
        _compare_receipt_to_entry(receipt, entry)
        prior = prior_receipts[receipt["modality"]]
        expected_prior = ZERO if prior is None else prior["transition_receipt_sha256"]
        if (
            receipt["previous_transition_receipt_sha256"] != expected_prior
            or receipt["generation_plan_sha256"] != header["generation_plan_sha256"]
            or receipt["tenant_scope_sha256"] != header["tenant_scope_sha256"]
            or receipt["metadata_policy_sha256"] != header["metadata_policy_sha256"]
            or receipt["challenge_sha256"] != header["challenge_sha256"]
            or receipt["registry_manifest_sha256"] != header["registry_manifest_sha256"]
            or receipt["registry_archive_sha256"] != header["registry_archive_sha256"]
            or receipt["encoded_payload_bytes"] != len(payload)
            or receipt["encoded_payload_sha256"] != hashlib.sha256(payload).digest()
        ):
            raise GeneratedMediaProducerTransitionError(
                "receipt batch binding mismatch"
            )
        prior_receipts[receipt["modality"]] = receipt
    terminals = _receipt_terminals(receipts)
    terminal_roots = (
        (
            "terminal_image_receipt_sha256",
            registry.IMAGE_MODALITY,
        ),
        (
            "terminal_audio_receipt_sha256",
            registry.AUDIO_MODALITY,
        ),
        (
            "terminal_video_receipt_sha256",
            registry.VIDEO_MODALITY,
        ),
    )
    if (
        any(
            header[field]
            != (
                ZERO
                if terminals[modality] is None
                else terminals[modality]["transition_receipt_sha256"]
            )
            for field, modality in terminal_roots
        )
        or header["first_receipt_sha256"] != receipts[0]["transition_receipt_sha256"]
    ):
        raise GeneratedMediaProducerTransitionError("batch terminal receipt mismatch")
    totals = {
        "total_model_input_bytes": sum(
            receipt["model_input_bytes"] for receipt in receipts
        ),
        "total_model_output_bytes": sum(
            receipt["model_output_bytes"] for receipt in receipts
        ),
        "total_model_state_transition_bytes": sum(
            receipt["model_state_before_bytes"] + receipt["model_state_after_bytes"]
            for receipt in receipts
        ),
        "total_materializer_payload_bytes": sum(
            receipt["materializer_payload_bytes"] for receipt in receipts
        ),
        "total_raw_output_bytes": sum(
            receipt["raw_output_bytes"] for receipt in receipts
        ),
        "total_encoded_payload_bytes": sum(
            receipt["encoded_payload_bytes"] for receipt in receipts
        ),
    }
    if any(header[field] != total for field, total in totals.items()):
        raise GeneratedMediaProducerTransitionError("batch aggregate mismatch")
    return {
        "evidence_bytes": evidence,
        "header": header,
        "receipts": receipts,
        "receipt_table": receipt_table,
        "registry": registry_value,
        "previous": previous,
    }


def _identity(label: bytes) -> bytes:
    return hashlib.sha256(
        b"glacier-generated-media-producer-transition-reference-v1\x00" + label
    ).digest()


def _delivery_fixture(label: bytes, raw_output: bytes) -> Record:
    return {
        "encoding_abi": 0x454E430000000001,
        "encoded_payload": b"transition-fixture:" + label + b":" + raw_output,
        "encoder_implementation_sha256": _identity(b"encoder:" + label),
        "format_sha256": _identity(b"format:" + label),
    }


def _model_claim(
    *,
    weight_bytes: int,
    input_bytes: int,
    output_bytes: int,
) -> Record:
    return {
        "capsule_bytes": weight_bytes,
        "kv_bytes": 0,
        "activation_bytes": input_bytes,
        "partial_bytes": output_bytes,
        "logits_bytes": 0,
        "output_journal_bytes": output_bytes,
        "staging_bytes": output_bytes,
        "device_bytes": 0,
        "io_bytes": 0,
        "queue_slots": 1,
    }


def _model_plan_digests(
    label: bytes,
    *,
    challenge_sha256: bytes,
    previous_plan_sha256: bytes,
    processor_state_sha256: bytes,
    cache_payload_sha256: bytes,
) -> Record:
    return {
        "media_object_sha256": _identity(b"model-media:" + label),
        "processor_state_sha256": processor_state_sha256,
        "processor_bundle_sha256": _identity(b"processor-bundle:" + label),
        "cache_bundle_sha256": _identity(b"cache-bundle:" + label),
        "cache_payload_sha256": cache_payload_sha256,
        "ownership_sha256": _identity(b"ownership:" + label),
        "challenge_sha256": challenge_sha256,
        "previous_plan_sha256": previous_plan_sha256,
        "input_schema_sha256": _identity(b"input-schema:" + label),
        "output_schema_sha256": _identity(b"output-schema:" + label),
    }


def _adapter_fixture(
    *,
    artifact: Record,
    operation: int,
    implementation_sha256: bytes,
) -> tuple[Record, bytes, list[Record]]:
    descriptor: Record = {
        "adapter_abi": 0x474D54524E000001,
        "family": artifact["family"],
        "operation": operation,
        "input_kind": artifact["input_kind"],
        "output_kind": artifact["output_kind"],
        "numerical_policy": artifact["numerical_policy"],
        "max_batch_items": artifact["max_batch_items"],
        "max_input_features": artifact["input_features"],
        "max_output_dimensions": artifact["output_dimensions"],
        "allowed_capabilities": 0,
        "implementation_sha256": implementation_sha256,
    }
    descriptor["adapter_sha256"] = stateful.adapter_descriptor_root(**descriptor)
    descriptor_wire = encode_adapter_descriptor(descriptor)
    support = [{field: descriptor[field] for field in SUPPORT_FIELDS}]
    return descriptor, descriptor_wire, support


def _stateless_model_fixture(
    *,
    label: bytes,
    family: int,
    request_epoch: int,
    challenge_sha256: bytes,
    model_input: bytes,
    previous: Record | None = None,
) -> Record:
    dimensions = len(model_input)
    weights = bytes(
        1 if row == column else 0
        for row in range(dimensions)
        for column in range(dimensions)
    )
    artifact = (
        model.make_artifact(
            family=family,
            artifact_abi=0x5354415445000001,
            input_kind=6,
            output_kind=6,
            numerical_policy=model.EXACT_INTEGER,
            max_batch_items=1,
            input_features=dimensions,
            output_dimensions=dimensions,
            input_element_bytes=1,
            output_element_bytes=1,
            weight_element_bytes=1,
            weights=weights,
            metadata_sha256=_identity(b"metadata:" + label),
            license_sha256=_identity(b"license:" + label),
        )
        if previous is None
        else previous["artifact"]
    )
    publication_before = (
        {
            "request_epoch": request_epoch,
            "next_sequence": 0,
            "visible_results": 0,
            "artifact_sha256": artifact["artifact_sha256"],
            "previous_result_sha256": ZERO,
        }
        if previous is None
        else previous["publication_after"]
    )
    generation = 1 if previous is None else previous["plan"]["generation"] + 1
    previous_plan = (
        _identity(b"model-plan-genesis:" + label)
        if previous is None
        else previous["plan"]["plan_sha256"]
    )
    plan = model.make_plan(
        artifact,
        operation=7,
        request_epoch=request_epoch,
        generation=generation,
        batch_items=1,
        publication_next_sequence=publication_before["next_sequence"],
        maximum_absolute_output=255,
        required_capabilities=0,
        scratch_bytes=dimensions,
        claim=_model_claim(
            weight_bytes=len(weights),
            input_bytes=len(model_input),
            output_bytes=dimensions,
        ),
        digests=_model_plan_digests(
            label,
            challenge_sha256=challenge_sha256,
            previous_plan_sha256=previous_plan,
            processor_state_sha256=_identity(b"stateless-processor:" + label),
            cache_payload_sha256=_identity(b"stateless-cache:" + label),
        ),
    )
    implementation = _identity(b"stateless-u8-projection:" + label)
    descriptor, descriptor_wire, support = _adapter_fixture(
        artifact=artifact,
        operation=7,
        implementation_sha256=implementation,
    )
    output = _reference_stateless_execution(plan, weights, model_input)
    mapping = stateless_source_mapping_root(
        plan,
        weights,
        model_input,
        output,
        descriptor["adapter_sha256"],
    )
    receipt = resource.resource_receipt(
        710_000 + family,
        generation - 1,
        generation,
        720_000 + family * 10 + generation,
        plan["claim"],
    )
    result = model.make_result(
        publication_before,
        plan,
        receipt,
        output_sha256=hashlib.sha256(output).digest(),
        source_mapping_sha256=mapping,
        adapter_sha256=descriptor["adapter_sha256"],
    )
    publication_after = _model_publication_after(
        publication_before, result["result_sha256"]
    )
    witness: Record = {
        "kind": STATELESS_MODEL,
        "artifact_manifest_wire": model.encode_artifact(artifact),
        "plan_wire": model.encode_plan(plan),
        "result_wire": model.encode_result(result),
        "publication_before_wire": encode_model_publication(publication_before),
        "publication_after_wire": encode_model_publication(publication_after),
        "adapter_descriptor_wire": descriptor_wire,
        "support_records": support,
        "weights": weights,
        "input": model_input,
        "output": output,
    }
    return {
        "witness": witness,
        "artifact": artifact,
        "plan": plan,
        "result": result,
        "publication_after": publication_after,
        "output": output,
    }


def _latent_plan(
    *,
    artifact: Record,
    state_publication: Record,
    request_epoch: int,
    publication_next_sequence: int,
    previous_plan_sha256: bytes,
    challenge_sha256: bytes,
    label: bytes,
) -> Record:
    return model.make_plan(
        artifact,
        operation=8,
        request_epoch=request_epoch,
        generation=state_publication["current_step"] + 1,
        batch_items=1,
        publication_next_sequence=publication_next_sequence,
        maximum_absolute_output=255,
        required_capabilities=0,
        scratch_bytes=4,
        claim=_model_claim(
            weight_bytes=1,
            input_bytes=4,
            output_bytes=4,
        ),
        digests=_model_plan_digests(
            label,
            challenge_sha256=challenge_sha256,
            previous_plan_sha256=previous_plan_sha256,
            processor_state_sha256=state_publication["publication_sha256"],
            cache_payload_sha256=state_publication["current_state_sha256"],
        ),
    )


def _image_output_fixture(
    *,
    label: bytes,
    request_epoch: int,
    tenant_scope_sha256: bytes,
    metadata_policy_sha256: bytes,
    challenge_sha256: bytes,
    seed_offset: int,
    previous_producer_plan_sha256: bytes | None = None,
    previous_producer_result_sha256: bytes | None = None,
) -> Record:
    weights = bytes((1,))
    conditioning = bytes((1, 2, 3, 4))
    initial_state = bytes(
        (10 + seed_offset, 20 + seed_offset, 30 + seed_offset, 40 + seed_offset)
    )
    artifact = model.make_artifact(
        family=7,
        artifact_abi=0x4C4154454E540001,
        input_kind=6,
        output_kind=6,
        numerical_policy=model.EXACT_INTEGER,
        max_batch_items=1,
        input_features=4,
        output_dimensions=4,
        input_element_bytes=1,
        output_element_bytes=1,
        weight_element_bytes=1,
        weights=weights,
        metadata_sha256=_identity(b"image-model-metadata:" + label),
        license_sha256=_identity(b"image-model-license:" + label),
    )
    state0 = stateful.initialize_publication(
        request_epoch=request_epoch,
        total_steps=2,
        state_bytes=4,
        artifact_sha256=artifact["artifact_sha256"],
        current_state_sha256=hashlib.sha256(initial_state).digest(),
        challenge_sha256=challenge_sha256,
    )
    implementation = _identity(b"stateful-latent-step")
    descriptor, descriptor_wire, support = _adapter_fixture(
        artifact=artifact,
        operation=8,
        implementation_sha256=implementation,
    )
    model_pub0 = {
        "request_epoch": request_epoch,
        "next_sequence": 0,
        "visible_results": 0,
        "artifact_sha256": artifact["artifact_sha256"],
        "previous_result_sha256": ZERO,
    }
    first_plan = _latent_plan(
        artifact=artifact,
        state_publication=state0,
        request_epoch=request_epoch,
        publication_next_sequence=0,
        previous_plan_sha256=_identity(b"latent-genesis:" + label),
        challenge_sha256=challenge_sha256,
        label=label + b":first",
    )
    first_state = stateful.reference_latent_step(initial_state, conditioning, weights)
    first_mapping = stateful.transition_root(
        state0,
        first_plan,
        hashlib.sha256(first_state).digest(),
        hashlib.sha256(first_state).digest(),
        descriptor["adapter_sha256"],
    )
    first_receipt = resource.resource_receipt(
        730_001 + seed_offset * 10,
        0,
        1,
        731_001 + seed_offset * 10,
        first_plan["claim"],
    )
    first_result = model.make_result(
        model_pub0,
        first_plan,
        first_receipt,
        output_sha256=hashlib.sha256(first_state).digest(),
        source_mapping_sha256=first_mapping,
        adapter_sha256=descriptor["adapter_sha256"],
    )
    state1 = _state_publication_after(
        state0, first_result["result_sha256"], first_state
    )
    model_pub1 = _model_publication_after(model_pub0, first_result["result_sha256"])
    restore_bank = 740_001 + seed_offset * 10
    checkpoint = continuation.make_checkpoint(
        source_bank_epoch=first_receipt["bank_epoch"],
        restore_plan={
            "restore_bank_epoch": restore_bank,
            "restore_owner_key": 741_001 + seed_offset * 10,
            "restore_tree_key": 742_001 + seed_offset * 10,
            "restore_authority_key": 743_001 + seed_offset * 10,
            "tenant_key": 744_001 + seed_offset * 10,
            "scope_key": 745_001 + seed_offset * 10,
            "allocation_key": 746_001 + seed_offset * 10,
            "binding_key": 747_001 + seed_offset * 10,
        },
        model_publication=model_pub1,
        state_publication=state1,
        last_result=first_result,
    )
    terminal_plan = _latent_plan(
        artifact=artifact,
        state_publication=state1,
        request_epoch=request_epoch,
        publication_next_sequence=model_pub1["next_sequence"],
        previous_plan_sha256=checkpoint["last_plan_sha256"],
        challenge_sha256=challenge_sha256,
        label=label + b":terminal",
    )
    terminal_state = stateful.reference_latent_step(first_state, conditioning, weights)
    terminal_mapping = stateful.transition_root(
        state1,
        terminal_plan,
        hashlib.sha256(terminal_state).digest(),
        hashlib.sha256(terminal_state).digest(),
        descriptor["adapter_sha256"],
    )
    terminal_receipt = resource.resource_receipt(
        restore_bank,
        1,
        2,
        748_001 + seed_offset * 10,
        terminal_plan["claim"],
    )
    terminal_result = model.make_result(
        model_pub1,
        terminal_plan,
        terminal_receipt,
        output_sha256=hashlib.sha256(terminal_state).digest(),
        source_mapping_sha256=terminal_mapping,
        adapter_sha256=descriptor["adapter_sha256"],
    )
    state2 = _state_publication_after(
        state1, terminal_result["result_sha256"], terminal_state
    )
    model_pub2 = _model_publication_after(model_pub1, terminal_result["result_sha256"])
    pixels = image.reference_decode(terminal_state, image.REFERENCE_DECODER_PAYLOAD)
    source_provenance = image.source_provenance_root(
        artifact,
        checkpoint,
        terminal_plan,
        terminal_result,
        state2,
        hashlib.sha256(image.REFERENCE_DECODER_PAYLOAD).digest(),
        image.decoder_implementation_root(),
        tenant_scope_sha256,
        metadata_policy_sha256,
        challenge_sha256,
    )
    media_object = media.decode_media_object(
        media.encode_media_object(
            {
                "kind": media.IMAGE,
                "semantic_abi": image.RAW_IMAGE_SEMANTIC_ABI,
                "byte_length": len(pixels),
                "container_id": image.RAW_CONTAINER_ID,
                "codec_id": image.INTERLEAVED_U8_CODEC_ID,
                "axes": (2, 2, 1),
                "time_base": (0, 1),
                "tenant_scope_sha256": tenant_scope_sha256,
                "content_sha256": hashlib.sha256(pixels).digest(),
                "metadata_policy_sha256": metadata_policy_sha256,
                "provenance_sha256": source_provenance,
            }
        )
    )
    media_root = media.media_object_sha256(media.encode_media_object(media_object))
    publication_before = media.initialize_publication_state(
        request_epoch,
        1,
        (1, 1),
        media_root,
        _identity(b"image-publication-genesis:" + label),
    )
    producer_plan = image.make_plan(
        manifest=artifact,
        checkpoint=checkpoint,
        terminal_plan=terminal_plan,
        terminal_result=terminal_result,
        terminal_state_publication=state2,
        media_object=media_object,
        decoder_payload=image.REFERENCE_DECODER_PAYLOAD,
        publication_state=publication_before,
        previous_plan_sha256=(
            _identity(b"image-producer-plan-genesis:" + label)
            if previous_producer_plan_sha256 is None
            else previous_producer_plan_sha256
        ),
        previous_result_sha256=(
            _identity(b"image-producer-result-genesis:" + label)
            if previous_producer_result_sha256 is None
            else previous_producer_result_sha256
        ),
    )
    provenance = image.make_provenance(producer_plan, hashlib.sha256(pixels).digest())
    producer_receipt = resource.resource_receipt(
        750_001 + seed_offset * 10,
        0,
        3,
        751_001 + seed_offset * 10,
        image.claim_for_plan(producer_plan, len(image.REFERENCE_DECODER_PAYLOAD)),
    )
    producer_result, publication_after = image.make_result(
        plan_value=producer_plan,
        provenance_value=provenance,
        media_object=media_object,
        receipt=producer_receipt,
        publication_state_before=publication_before,
    )
    model_witness: Record = {
        "kind": STATEFUL_MODEL,
        "artifact_manifest_wire": model.encode_artifact(artifact),
        "plan_wire": model.encode_plan(terminal_plan),
        "result_wire": model.encode_result(terminal_result),
        "publication_before_wire": encode_model_publication(model_pub1),
        "publication_after_wire": encode_model_publication(model_pub2),
        "adapter_descriptor_wire": descriptor_wire,
        "support_records": support,
        "weights": weights,
        "input": conditioning,
        "output": terminal_state,
        "state_publication_before_wire": stateful.encode_publication(state1),
        "state_publication_after_wire": stateful.encode_publication(state2),
        "checkpoint_wire": continuation.encode_checkpoint(checkpoint),
        "checkpoint_previous_result_wire": model.encode_result(first_result),
        "state_before": first_state,
        "state_after": terminal_state,
    }
    producer_witness: Record = {
        "publication_before_wire": encode_media_publication(publication_before),
        "publication_after_wire": encode_media_publication(publication_after),
        "plan_wire": image.encode_plan(producer_plan),
        "provenance_wire": image.encode_provenance(provenance),
        "result_wire": image.encode_result(producer_result),
        "media_object_wire": media.encode_media_object(media_object),
        "resource_receipt_wire": encode_resource_receipt(producer_receipt),
        "materializer_payload": image.REFERENCE_DECODER_PAYLOAD,
        "raw_output": pixels,
    }
    return {
        "modality": registry.IMAGE_MODALITY,
        "model": model_witness,
        "producer": producer_witness,
        "delivery": _delivery_fixture(label, pixels),
    }


def _audio_output_fixture(
    *,
    label: bytes,
    request_epoch: int,
    tenant_scope_sha256: bytes,
    metadata_policy_sha256: bytes,
    challenge_sha256: bytes,
    model_input: bytes,
    previous_model: Record | None,
    state_before: Record | None,
) -> tuple[Record, Record, Record]:
    model_fixture = _stateless_model_fixture(
        label=b"audio-model",
        family=9,
        request_epoch=request_epoch,
        challenge_sha256=challenge_sha256,
        model_input=model_input,
        previous=previous_model,
    )
    pre = (
        audio.initial_state(
            request_epoch=request_epoch,
            sample_rate=16_000,
            channels=1,
            artifact_sha256=model_fixture["artifact"]["artifact_sha256"],
            tenant_scope_sha256=tenant_scope_sha256,
            metadata_policy_sha256=metadata_policy_sha256,
            challenge_sha256=challenge_sha256,
        )
        if state_before is None
        else state_before
    )
    source = model_fixture["output"]
    pcm = audio.render_reference_pcm(source)
    media_object = audio.audio_media_object(
        pre,
        frame_count=len(source),
        output_sha256=hashlib.sha256(pcm).digest(),
        source_result_sha256=model_fixture["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(source).digest(),
    )
    media_wire = media.encode_media_object(media_object)
    plan = audio.make_plan(
        pre,
        frame_count=len(source),
        source_output_bytes=len(source),
        source_result_sha256=model_fixture["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(source).digest(),
        media_object_sha256=media.media_object_sha256(media_wire),
    )
    producer_receipt = resource.resource_receipt(
        760_001,
        plan["chunk_index"],
        plan["generation"],
        761_001 + plan["chunk_index"],
        audio.claim_for_plan(plan),
    )
    provenance = audio.make_provenance(plan, hashlib.sha256(pcm).digest())
    result = audio.make_result(plan, provenance, producer_receipt)
    pending = audio.state_after_publication(pre, plan, result)
    observation = audio.make_observation(
        pending,
        sink_implementation_sha256=_identity(b"audio-sink"),
        sink_instance_sha256=_identity(b"audio-sink-instance"),
    )
    ack_plan = audio.make_ack_plan(pending, result, observation)
    final, ack_result = audio.acknowledge(pending, result, observation, ack_plan)
    witness: Record = {
        "modality": registry.AUDIO_MODALITY,
        "model": model_fixture["witness"],
        "producer": {
            "state_before_wire": audio.encode_state(pre),
            "state_pending_wire": audio.encode_state(pending),
            "state_after_wire": audio.encode_state(final),
            "plan_wire": audio.encode_plan(plan),
            "provenance_wire": audio.encode_provenance(provenance),
            "result_wire": audio.encode_result(result),
            "observation_wire": audio.encode_observation(observation),
            "ack_plan_wire": audio.encode_ack_plan(ack_plan),
            "ack_result_wire": audio.encode_ack_result(ack_result),
            "media_object_wire": media_wire,
            "resource_receipt_wire": encode_resource_receipt(producer_receipt),
            "materializer_payload": audio.REFERENCE_RENDERER_PAYLOAD,
            "raw_output": pcm,
        },
        "delivery": _delivery_fixture(label, pcm),
    }
    return witness, model_fixture, final


def _video_output_fixture(
    *,
    label: bytes,
    request_epoch: int,
    tenant_scope_sha256: bytes,
    metadata_policy_sha256: bytes,
    challenge_sha256: bytes,
    model_input: bytes,
    previous_model: Record | None,
    state_before: Record | None,
) -> tuple[Record, Record, Record]:
    model_fixture = _stateless_model_fixture(
        label=b"video-model",
        family=8,
        request_epoch=request_epoch,
        challenge_sha256=challenge_sha256,
        model_input=model_input,
        previous=previous_model,
    )
    pre = (
        video.initial_state(
            request_epoch=request_epoch,
            width=2,
            height=2,
            channels=1,
            artifact_sha256=model_fixture["artifact"]["artifact_sha256"],
            tenant_scope_sha256=tenant_scope_sha256,
            metadata_policy_sha256=metadata_policy_sha256,
            challenge_sha256=challenge_sha256,
        )
        if state_before is None
        else state_before
    )
    source = model_fixture["output"]
    rendered = video.render_reference_frames(source)
    first_duration = 2 + pre["next_segment_index"]
    second_duration = 3 + pre["next_segment_index"]
    first_root = hashlib.sha256(rendered[:4]).digest()
    second_root = hashlib.sha256(rendered[4:]).digest()
    provisional = video.make_manifest(
        pre,
        first_duration_ticks=first_duration,
        second_duration_ticks=second_duration,
        source_output_bytes=len(source),
        source_result_sha256=model_fixture["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(source).digest(),
        media_object_sha256=_identity(b"video-media-placeholder"),
        first_frame_sha256=first_root,
        second_frame_sha256=second_root,
        maximum_renderer_output_bytes=len(rendered),
    )
    media_object = media.decode_media_object(
        media.encode_media_object(
            {
                "kind": media.VIDEO,
                "semantic_abi": video.RAW_VIDEO_SEMANTIC_ABI,
                "byte_length": len(rendered),
                "container_id": video.RAW_CONTAINER_ID,
                "codec_id": video.GRAY8_FRAME_CODEC_ID,
                "axes": (2, 2, 2),
                "time_base": (1, 1_000),
                "tenant_scope_sha256": tenant_scope_sha256,
                "content_sha256": hashlib.sha256(rendered).digest(),
                "metadata_policy_sha256": metadata_policy_sha256,
                "provenance_sha256": video.source_provenance_root(provisional),
            }
        )
    )
    media_wire = media.encode_media_object(media_object)
    manifest = video.make_manifest(
        pre,
        first_duration_ticks=first_duration,
        second_duration_ticks=second_duration,
        source_output_bytes=len(source),
        source_result_sha256=model_fixture["result"]["result_sha256"],
        source_output_sha256=hashlib.sha256(source).digest(),
        media_object_sha256=media.media_object_sha256(media_wire),
        first_frame_sha256=first_root,
        second_frame_sha256=second_root,
        maximum_renderer_output_bytes=len(rendered),
    )
    producer_receipt = resource.resource_receipt(
        770_001,
        manifest["segment_index"],
        manifest["generation"],
        771_001 + manifest["segment_index"],
        video.claim_for_manifest(manifest),
    )
    provenance = video.make_provenance(manifest, hashlib.sha256(rendered).digest())
    result = video.make_result(manifest, provenance, producer_receipt)
    pending = video.state_after_publication(pre, manifest, result)
    observation = video.make_observation(
        pending,
        sink_implementation_sha256=_identity(b"video-sink"),
        sink_instance_sha256=_identity(b"video-sink-instance"),
    )
    ack_plan = video.make_ack_plan(pending, result, observation)
    final, ack_result = video.acknowledge(pending, result, observation, ack_plan)
    witness: Record = {
        "modality": registry.VIDEO_MODALITY,
        "model": model_fixture["witness"],
        "producer": {
            "state_before_wire": video.encode_state(pre),
            "state_pending_wire": video.encode_state(pending),
            "state_after_wire": video.encode_state(final),
            "manifest_wire": video.encode_manifest(manifest),
            "provenance_wire": video.encode_provenance(provenance),
            "result_wire": video.encode_result(result),
            "observation_wire": video.encode_observation(observation),
            "ack_plan_wire": video.encode_ack_plan(ack_plan),
            "ack_result_wire": video.encode_ack_result(ack_result),
            "media_object_wire": media_wire,
            "resource_receipt_wire": encode_resource_receipt(producer_receipt),
            "materializer_payload": video.REFERENCE_RENDERER_PAYLOAD,
            "raw_output": rendered,
        },
        "delivery": _delivery_fixture(label, rendered),
    }
    return witness, model_fixture, final


def reference_inputs() -> Record:
    """Build deterministic first/successor witness generations."""

    request_epoch = 701_001
    tenant = _identity(b"tenant")
    policy = _identity(b"metadata-policy")
    challenge = _identity(b"challenge")
    image1 = _image_output_fixture(
        label=b"image-one",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        seed_offset=0,
    )
    image1_plan = image.decode_plan(image1["producer"]["plan_wire"])
    image1_result = image.decode_result(image1["producer"]["result_wire"])
    image2 = _image_output_fixture(
        label=b"image-two",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        seed_offset=1,
        previous_producer_plan_sha256=image1_plan["plan_sha256"],
        previous_producer_result_sha256=image1_result["result_sha256"],
    )
    audio1, audio_model1, audio_state1 = _audio_output_fixture(
        label=b"audio-one",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        model_input=bytes((129, 127)),
        previous_model=None,
        state_before=None,
    )
    video1, video_model1, video_state1 = _video_output_fixture(
        label=b"video-one",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        model_input=bytes((3, 7)),
        previous_model=None,
        state_before=None,
    )
    image3 = _image_output_fixture(
        label=b"image-three",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        seed_offset=2,
        previous_producer_plan_sha256=image.decode_plan(
            image2["producer"]["plan_wire"]
        )["plan_sha256"],
        previous_producer_result_sha256=image.decode_result(
            image2["producer"]["result_wire"]
        )["result_sha256"],
    )
    audio2, _, _ = _audio_output_fixture(
        label=b"audio-two",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        model_input=bytes((130, 126)),
        previous_model=audio_model1,
        state_before=audio_state1,
    )
    video2, _, _ = _video_output_fixture(
        label=b"video-two",
        request_epoch=request_epoch,
        tenant_scope_sha256=tenant,
        metadata_policy_sha256=policy,
        challenge_sha256=challenge,
        model_input=bytes((11, 13)),
        previous_model=video_model1,
        state_before=video_state1,
    )
    return {
        "generation_plan1_sha256": _identity(b"generation-plan-one"),
        "generation_plan2_sha256": _identity(b"generation-plan-two"),
        "batch1": [image1, image2, audio1, video1],
        "batch2": [image3, audio2, video2],
    }


def reference_batches() -> Record:
    """Return the deterministic two-generation execution evidence chain."""

    fixture = reference_inputs()
    first = verify_and_encode_batch(
        None,
        fixture["generation_plan1_sha256"],
        fixture["batch1"],
    )
    second = verify_and_encode_batch(
        first,
        fixture["generation_plan2_sha256"],
        fixture["batch2"],
    )
    return {"first": first, "second": second}
