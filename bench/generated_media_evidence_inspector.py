"""Independent expected renderer/parser for the generated-media inspector.

This module renders only validated identities and scalar bounds.  It never
copies registry payload bytes into the result.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from bench import generated_media_output_registry as registry
from bench import generated_media_producer_transition as transition

Record = dict[str, Any]

SCHEMA = "glacier-generated-media-evidence-inspector-v1"
MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_EVIDENCE_BYTES = (
    transition.BATCH_BYTES + registry.MAX_ENTRIES * transition.TRANSITION_RECEIPT_BYTES
)

TOP_FIELDS = (
    "schema",
    "verified",
    "lineage",
    "request_epoch",
    "registry_generation",
    "publication_sequence",
    "modality_mask",
    "receipt_count",
    "receipt_table_bytes",
    "registry_archive_bytes",
    "evidence_bytes",
    "generation_plan_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "receipt_table_sha256",
    "previous_batch_sha256",
    "registry_manifest_sha256",
    "registry_archive_sha256",
    "batch_sha256",
    "entries",
)

ENTRY_SCALAR_FIELDS = (
    "index",
    "modality",
    "model_kind",
    "completion_kind",
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
    "encoding_abi",
    "payload_offset",
    "producer_publication_sequence",
    "completion_sequence",
)

ENTRY_DIGEST_FIELDS = (
    "artifact_manifest_sha256",
    "adapter_descriptor_sha256",
    "support_set_sha256",
    "model_plan_sha256",
    "model_output_sha256",
    "model_transition_or_source_mapping_sha256",
    "model_result_sha256",
    "producer_plan_or_manifest_sha256",
    "media_object_sha256",
    "materializer_implementation_sha256",
    "materializer_execution_sha256",
    "raw_output_sha256",
    "provenance_sha256",
    "publication_result_sha256",
    "producer_final_state_sha256",
    "completion_result_sha256",
    "encoder_implementation_sha256",
    "format_sha256",
    "encoded_payload_sha256",
    "previous_transition_receipt_sha256",
    "producer_projection_sha256",
    "registry_previous_entry_sha256",
    "registry_entry_sha256",
    "transition_receipt_sha256",
)

ENTRY_FIELDS = ENTRY_SCALAR_FIELDS + ENTRY_DIGEST_FIELDS

TOP_DIGEST_FIELDS = (
    "generation_plan_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "challenge_sha256",
    "receipt_table_sha256",
    "previous_batch_sha256",
    "registry_manifest_sha256",
    "registry_archive_sha256",
    "batch_sha256",
)

MODALITY_NAMES = {
    registry.IMAGE_MODALITY: "image",
    registry.AUDIO_MODALITY: "audio",
    registry.VIDEO_MODALITY: "video",
}
MODEL_KIND_NAMES = {
    transition.STATELESS_MODEL: "stateless",
    transition.STATEFUL_MODEL: "stateful",
}
COMPLETION_KIND_NAMES = {
    transition.NO_COMPLETION: "none",
    transition.PLAYBACK_COMPLETION: "playback",
    transition.DISPLAY_COMPLETION: "display",
}


class GeneratedMediaEvidenceInspectorError(ValueError):
    """The rendered inspector document is not canonical."""


def _hex(value: bytes) -> str:
    if type(value) is not bytes or len(value) != 32:
        raise GeneratedMediaEvidenceInspectorError("invalid digest")
    return value.hex()


def expected_document(batch: Record) -> Record:
    """Return field-ordered expected JSON for one validated oracle batch."""

    if type(batch) is not dict:
        raise GeneratedMediaEvidenceInspectorError("invalid batch")
    try:
        previous = batch["previous"]
        validated = transition.decode_batch(
            batch["evidence_bytes"],
            batch["registry"]["archive_bytes"],
            previous,
        )
    except (
        KeyError,
        TypeError,
        transition.GeneratedMediaProducerTransitionError,
    ) as error:
        raise GeneratedMediaEvidenceInspectorError(
            "invalid transition batch"
        ) from error

    header = validated["header"]
    registry_value = validated["registry"]
    entries = [
        _expected_entry(index, receipt, registry_value["entries"][index])
        for index, receipt in enumerate(validated["receipts"])
    ]
    document: Record = {
        "schema": SCHEMA,
        "verified": True,
        "lineage": ("genesis" if header["registry_generation"] == 1 else "successor"),
        "request_epoch": header["request_epoch"],
        "registry_generation": header["registry_generation"],
        "publication_sequence": header["publication_sequence"],
        "modality_mask": header["modality_mask"],
        "receipt_count": header["receipt_count"],
        "receipt_table_bytes": header["receipt_table_bytes"],
        "registry_archive_bytes": len(registry_value["archive_bytes"]),
        "evidence_bytes": len(validated["evidence_bytes"]),
    }
    for field in TOP_DIGEST_FIELDS:
        document[field] = _hex(header[field])
    document["entries"] = entries
    if tuple(document) != TOP_FIELDS:
        raise AssertionError("expected top-level field order drift")
    return document


def _expected_entry(
    index: int,
    receipt: Record,
    registry_entry: Record,
) -> Record:
    value: Record = {
        "index": index,
        "modality": MODALITY_NAMES[receipt["modality"]],
        "model_kind": MODEL_KIND_NAMES[receipt["model_kind"]],
        "completion_kind": COMPLETION_KIND_NAMES[receipt["completion_kind"]],
        "producer_generation": receipt["producer_generation"],
        "producer_ordinal": receipt["producer_ordinal"],
        "registry_ordinal": receipt["registry_ordinal"],
        "unit_start": receipt["unit_start"],
        "unit_count": receipt["unit_count"],
        "timeline_start": receipt["timeline_start"],
        "timeline_end": receipt["timeline_end"],
        "weights_bytes": receipt["weights_bytes"],
        "model_input_bytes": receipt["model_input_bytes"],
        "model_state_before_bytes": receipt["model_state_before_bytes"],
        "model_output_bytes": receipt["model_output_bytes"],
        "model_state_after_bytes": receipt["model_state_after_bytes"],
        "materializer_payload_bytes": receipt["materializer_payload_bytes"],
        "raw_output_bytes": receipt["raw_output_bytes"],
        "encoded_payload_bytes": receipt["encoded_payload_bytes"],
        "encoding_abi": registry_entry["encoding_abi"],
        "payload_offset": registry_entry["payload_offset"],
        "producer_publication_sequence": receipt["producer_publication_sequence"],
        "completion_sequence": receipt["completion_sequence"],
    }
    for field in ENTRY_DIGEST_FIELDS:
        value[field] = _hex(receipt[field])
    if tuple(value) != ENTRY_FIELDS:
        raise AssertionError("expected entry field order drift")
    return value


def render_expected(batch: Record) -> bytes:
    """Encode the expected document as one canonical compact JSON line."""

    return (
        json.dumps(
            expected_document(batch),
            ensure_ascii=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("ascii")


@dataclass(frozen=True)
class _Pairs:
    values: tuple[tuple[str, Any], ...]


def parse_rendered(raw: bytes) -> Record:
    """Parse and strictly validate one canonical inspector JSON line."""

    if type(raw) is not bytes or not raw.endswith(b"\n"):
        raise GeneratedMediaEvidenceInspectorError("invalid rendered bytes")
    try:
        decoded = json.loads(
            raw.decode("ascii"),
            object_pairs_hook=lambda pairs: _Pairs(tuple(pairs)),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GeneratedMediaEvidenceInspectorError("invalid rendered JSON") from error
    if not isinstance(decoded, _Pairs):
        raise GeneratedMediaEvidenceInspectorError("invalid rendered root")
    document = _convert_object(decoded, TOP_FIELDS)
    entries = document["entries"]
    if type(entries) is not list or not entries:
        raise GeneratedMediaEvidenceInspectorError("invalid entries")
    document["entries"] = [_convert_object(entry, ENTRY_FIELDS) for entry in entries]
    _validate_document(document)
    canonical = (
        json.dumps(
            document,
            ensure_ascii=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("ascii")
    if canonical != raw:
        raise GeneratedMediaEvidenceInspectorError("non-canonical rendered JSON")
    return document


def _convert_object(value: Any, fields: tuple[str, ...]) -> Record:
    if not isinstance(value, _Pairs):
        raise GeneratedMediaEvidenceInspectorError("invalid object")
    keys = tuple(key for key, _ in value.values)
    if keys != fields or len(set(keys)) != len(keys):
        raise GeneratedMediaEvidenceInspectorError("invalid field order")
    return {key: item for key, item in value.values}


def _validate_document(document: Record) -> None:
    if (
        document["schema"] != SCHEMA
        or document["verified"] is not True
        or document["lineage"] not in ("genesis", "successor")
        or type(document["receipt_count"]) is not int
        or document["receipt_count"] != len(document["entries"])
        or not 1 <= document["receipt_count"] <= registry.MAX_ENTRIES
        or type(document["registry_archive_bytes"]) is not int
        or not 0 < document["registry_archive_bytes"] <= MAX_ARCHIVE_BYTES
        or type(document["evidence_bytes"]) is not int
        or not 0 < document["evidence_bytes"] <= MAX_EVIDENCE_BYTES
        or document["receipt_table_bytes"]
        != document["receipt_count"] * transition.TRANSITION_RECEIPT_BYTES
        or document["evidence_bytes"]
        != transition.BATCH_BYTES + document["receipt_table_bytes"]
        or not 0 < document["modality_mask"] <= 0x7
        or (document["lineage"] == "genesis") != (document["registry_generation"] == 1)
    ):
        raise GeneratedMediaEvidenceInspectorError("invalid document envelope")
    for field in TOP_FIELDS[3:11]:
        if type(document[field]) is not int or document[field] < 0:
            raise GeneratedMediaEvidenceInspectorError("invalid document scalar")
    for field in TOP_DIGEST_FIELDS:
        _validate_hex(document[field])
    if (document["lineage"] == "genesis") != (
        document["previous_batch_sha256"] == "0" * 64
    ):
        raise GeneratedMediaEvidenceInspectorError("invalid predecessor shape")
    payload_offset = 0
    for index, entry in enumerate(document["entries"]):
        if (
            entry["index"] != index
            or entry["modality"] not in MODALITY_NAMES.values()
            or entry["model_kind"] not in MODEL_KIND_NAMES.values()
            or entry["completion_kind"] not in COMPLETION_KIND_NAMES.values()
            or entry["payload_offset"] != payload_offset
        ):
            raise GeneratedMediaEvidenceInspectorError("invalid entry identity")
        for field in ENTRY_SCALAR_FIELDS:
            if field in (
                "modality",
                "model_kind",
                "completion_kind",
            ):
                continue
            if type(entry[field]) is not int or entry[field] < 0:
                raise GeneratedMediaEvidenceInspectorError("invalid entry scalar")
        for field in ENTRY_DIGEST_FIELDS:
            _validate_hex(entry[field])
        payload_offset += entry["encoded_payload_bytes"]


def _validate_hex(value: Any) -> None:
    if (
        type(value) is not str
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise GeneratedMediaEvidenceInspectorError("invalid hex digest")
