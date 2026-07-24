"""Independent expected renderer/parser for the generated-media inspector.

This module renders only validated identities and scalar bounds.  It never
copies registry payload bytes into the result.
"""

from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass
from typing import Any

from bench import generated_media_external_format as external
from bench import generated_media_format_conformance as conformance
from bench import generated_media_output_registry as registry
from bench import generated_media_producer_transition as transition
from bench import generated_video_display as video_producer

Record = dict[str, Any]

SCHEMA = "glacier-generated-media-evidence-inspector-v1"
FORMAT_SCHEMA = "glacier-generated-media-evidence-inspector-format-v1"
MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_EVIDENCE_BYTES = (
    transition.BATCH_BYTES + registry.MAX_ENTRIES * transition.TRANSITION_RECEIPT_BYTES
)
MAX_FORMAT_EVIDENCE_BYTES = (
    conformance.FORMAT_BATCH_HEADER_BYTES
    + registry.MAX_ENTRIES * conformance.FORMAT_RECORD_BYTES
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

FORMAT_TOP_FIELDS = (
    *TOP_FIELDS[:-1],
    "format_evidence_bytes",
    "format_batch_sha256",
    "previous_format_batch_sha256",
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

FORMAT_ENTRY_FIELDS = (
    *ENTRY_FIELDS,
    "delivery_profile",
    "format_record_sha256",
    "format_contract_sha256",
    "plain_encoded_payload_sha256",
)

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
PROFILE_NAMES = {
    conformance.PNG_PROFILE: "png",
    conformance.WAVE_PCM_S16LE_PROFILE: "wave-pcm-s16le",
    conformance.APNG_TWO_FRAME_GRAY8_PROFILE: "apng-two-frame-gray8",
}


class GeneratedMediaEvidenceInspectorError(ValueError):
    """The rendered inspector document is not canonical."""


def _hex(value: bytes) -> str:
    if type(value) is not bytes or len(value) != 32:
        raise GeneratedMediaEvidenceInspectorError("invalid digest")
    return value.hex()


def expected_document(
    batch: Record,
    format_evidence: bytes | None = None,
    previous_format_evidence: bytes | None = None,
) -> Record:
    """Return field-ordered expected JSON for one validated oracle batch."""

    if type(batch) is not dict:
        raise GeneratedMediaEvidenceInspectorError("invalid batch")
    if format_evidence is None and previous_format_evidence is not None:
        raise GeneratedMediaEvidenceInspectorError(
            "format predecessor without current format evidence"
        )
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
    if format_evidence is None:
        return document

    validated_format = _validate_format_binding(
        validated,
        format_evidence,
        previous_format_evidence,
    )
    document["schema"] = FORMAT_SCHEMA
    format_entries = validated_format["records"]
    document_entries = document.pop("entries")
    document["format_evidence_bytes"] = len(validated_format["encoded"])
    document["format_batch_sha256"] = _hex(validated_format["batch"]["batch_sha256"])
    document["previous_format_batch_sha256"] = _hex(
        validated_format["batch"]["previous_format_batch_sha256"]
    )
    document["entries"] = [
        {
            **entry,
            "delivery_profile": PROFILE_NAMES[record["profile"]],
            "format_record_sha256": _hex(record["record_sha256"]),
            "format_contract_sha256": _hex(record["format_contract_sha256"]),
            "plain_encoded_payload_sha256": _hex(record["encoded_payload_sha256"]),
        }
        for entry, record in zip(
            document_entries,
            format_entries,
        )
    ]
    if tuple(document) != FORMAT_TOP_FIELDS or any(
        tuple(entry) != FORMAT_ENTRY_FIELDS for entry in document["entries"]
    ):
        raise AssertionError("expected format field order drift")
    return document


def _validate_format_binding(
    validated: Record,
    raw: bytes,
    previous_raw: bytes | None,
) -> Record:
    try:
        return conformance.validate_transition_and_format_evidence(
            validated,
            raw,
            previous_raw,
        )
    except conformance.GeneratedMediaFormatConformanceError as error:
        raise GeneratedMediaEvidenceInspectorError("invalid format evidence") from error


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


def render_expected(
    batch: Record,
    format_evidence: bytes | None = None,
    previous_format_evidence: bytes | None = None,
) -> bytes:
    """Encode the expected document as one canonical compact JSON line."""

    return (
        json.dumps(
            expected_document(
                batch,
                format_evidence,
                previous_format_evidence,
            ),
            ensure_ascii=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("ascii")


def reference_format_batches() -> Record:
    """Build a deterministic two-generation three-profile inspector chain."""

    fixture = _canonical_profile_reference_inputs()
    witnesses_one = copy.deepcopy(fixture["batch1"])
    witnesses_two = copy.deepcopy(fixture["batch2"])
    for generation, witnesses in enumerate(
        (witnesses_one, witnesses_two),
        start=1,
    ):
        for index, witness in enumerate(witnesses):
            _install_canonical_delivery(
                witness,
                f"generation-{generation}-entry-{index}".encode("ascii"),
            )
    first = transition.verify_and_encode_batch(
        None,
        fixture["generation_plan1_sha256"],
        witnesses_one,
    )
    second = transition.verify_and_encode_batch(
        first,
        fixture["generation_plan2_sha256"],
        witnesses_two,
    )
    first_format = _encode_format_evidence(
        first,
        witnesses_one,
        None,
    )
    second_format = _encode_format_evidence(
        second,
        witnesses_two,
        first_format,
    )
    return {
        "first": {
            **first,
            "format_evidence_bytes": first_format,
        },
        "second": {
            **second,
            "format_evidence_bytes": second_format,
        },
    }


def _canonical_profile_reference_inputs() -> Record:
    """Retain exact APNG V1 delays across the producer successor fixture."""

    original = video_producer.make_manifest

    def fixed_timing_manifest(*args: Any, **kwargs: Any) -> Record:
        canonical = dict(kwargs)
        canonical["first_duration_ticks"] = external.VIDEO_DURATION_TICKS[0]
        canonical["second_duration_ticks"] = external.VIDEO_DURATION_TICKS[1]
        return original(*args, **canonical)

    video_producer.make_manifest = fixed_timing_manifest
    try:
        return transition.reference_inputs()
    finally:
        video_producer.make_manifest = original


def _install_canonical_delivery(
    witness: Record,
    label: bytes,
) -> None:
    modality = witness["modality"]
    raw = bytes(witness["producer"]["raw_output"])
    if modality == registry.IMAGE_MODALITY:
        payload = external.encode_image_png(raw)
    elif modality == registry.AUDIO_MODALITY:
        payload = external.encode_audio_wave(raw)
    elif modality == registry.VIDEO_MODALITY:
        payload = external.encode_video_apng(raw[:4], raw[4:])
    else:
        raise AssertionError("unsupported fixture modality")
    profile = conformance.MODALITY_PROFILE[modality]
    witness["delivery"] = {
        "encoding_abi": conformance.encoding_abi(profile),
        "encoded_payload": payload,
        "encoder_implementation_sha256": hashlib.sha256(
            b"glacier-generated-media-inspector-format-encoder-v1\x00" + label
        ).digest(),
        "format_sha256": conformance.format_contract_root(profile),
    }


def _encode_format_evidence(
    batch: Record,
    witnesses: list[Record],
    previous_format: bytes | None,
) -> bytes:
    previous = (
        None
        if previous_format is None
        else conformance.decode_format_evidence(previous_format)
    )
    terminals = {
        registry.IMAGE_MODALITY: (
            conformance.ZERO
            if previous is None
            else previous["batch"]["terminal_image_sha256"]
        ),
        registry.AUDIO_MODALITY: (
            conformance.ZERO
            if previous is None
            else previous["batch"]["terminal_audio_sha256"]
        ),
        registry.VIDEO_MODALITY: (
            conformance.ZERO
            if previous is None
            else previous["batch"]["terminal_video_sha256"]
        ),
    }
    records: list[bytes] = []
    for witness, receipt, entry, payload in zip(
        witnesses,
        batch["receipts"],
        batch["registry"]["entries"],
        batch["registry"]["payloads"],
    ):
        modality = witness["modality"]
        producer_field = (
            "manifest_wire" if modality == registry.VIDEO_MODALITY else "plan_wire"
        )
        producer_wire = bytes(witness["producer"][producer_field])
        record = conformance.make_record_input(
            modality=modality,
            registry_ordinal=receipt["registry_ordinal"],
            producer_wire=producer_wire,
            producer_plan_or_manifest_sha256=receipt[
                "producer_plan_or_manifest_sha256"
            ],
            encoded_payload=payload,
            encoder_implementation_sha256=receipt["encoder_implementation_sha256"],
            transition_receipt_sha256=receipt["transition_receipt_sha256"],
            registry_entry_sha256=entry["entry_sha256"],
            previous_format_record_sha256=terminals[modality],
        )
        wire = conformance.encode_format_record(record)
        terminals[modality] = conformance.decode_format_record(wire)["record_sha256"]
        records.append(wire)
    header = batch["header"]
    registry_value = batch["registry"]
    manifest = registry_value["manifest"]
    metadata = {
        "request_epoch": header["request_epoch"],
        "registry_generation": header["registry_generation"],
        "publication_sequence": header["publication_sequence"],
        "generation_plan_sha256": header["generation_plan_sha256"],
        "tenant_scope_sha256": header["tenant_scope_sha256"],
        "metadata_policy_sha256": header["metadata_policy_sha256"],
        "challenge_sha256": header["challenge_sha256"],
        "transition_batch_sha256": header["batch_sha256"],
        "registry_manifest_sha256": manifest["manifest_sha256"],
        "registry_archive_sha256": registry_value["archive_sha256"],
    }
    return conformance.encode_format_evidence(
        metadata,
        records,
        previous_format,
    )


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
    if not decoded.values or decoded.values[0][0] != "schema":
        raise GeneratedMediaEvidenceInspectorError("missing schema")
    schema_value = decoded.values[0][1]
    if schema_value == SCHEMA:
        top_fields = TOP_FIELDS
        entry_fields = ENTRY_FIELDS
    elif schema_value == FORMAT_SCHEMA:
        top_fields = FORMAT_TOP_FIELDS
        entry_fields = FORMAT_ENTRY_FIELDS
    else:
        raise GeneratedMediaEvidenceInspectorError("unsupported schema")
    document = _convert_object(decoded, top_fields)
    entries = document["entries"]
    if type(entries) is not list or not entries:
        raise GeneratedMediaEvidenceInspectorError("invalid entries")
    document["entries"] = [_convert_object(entry, entry_fields) for entry in entries]
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
    is_format = document["schema"] == FORMAT_SCHEMA
    if (
        document["schema"] not in (SCHEMA, FORMAT_SCHEMA)
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
    if is_format:
        if (
            type(document["format_evidence_bytes"]) is not int
            or not 0 < document["format_evidence_bytes"] <= MAX_FORMAT_EVIDENCE_BYTES
            or document["format_evidence_bytes"]
            != conformance.FORMAT_BATCH_HEADER_BYTES
            + document["receipt_count"] * conformance.FORMAT_RECORD_BYTES
        ):
            raise GeneratedMediaEvidenceInspectorError("invalid format evidence size")
        _validate_hex(document["format_batch_sha256"])
        _validate_hex(document["previous_format_batch_sha256"])
        if document["format_batch_sha256"] == "0" * 64:
            raise GeneratedMediaEvidenceInspectorError("zero format batch identity")
    if (document["lineage"] == "genesis") != (
        document["previous_batch_sha256"] == "0" * 64
    ):
        raise GeneratedMediaEvidenceInspectorError("invalid predecessor shape")
    if is_format and (document["lineage"] == "genesis") != (
        document["previous_format_batch_sha256"] == "0" * 64
    ):
        raise GeneratedMediaEvidenceInspectorError("invalid format predecessor shape")
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
        if is_format:
            profile = {
                "image": conformance.PNG_PROFILE,
                "audio": conformance.WAVE_PCM_S16LE_PROFILE,
                "video": conformance.APNG_TWO_FRAME_GRAY8_PROFILE,
            }[entry["modality"]]
            expected_profile = PROFILE_NAMES[profile]
            if (
                entry["delivery_profile"] != expected_profile
                or entry["plain_encoded_payload_sha256"]
                != entry["encoded_payload_sha256"]
                or entry["format_contract_sha256"]
                != conformance.format_contract_root(profile).hex()
                or entry["format_record_sha256"] == "0" * 64
            ):
                raise GeneratedMediaEvidenceInspectorError(
                    "invalid format entry identity"
                )
            for field in (
                "format_record_sha256",
                "format_contract_sha256",
                "plain_encoded_payload_sha256",
            ):
                _validate_hex(entry[field])
        payload_offset += entry["encoded_payload_bytes"]


def _validate_hex(value: Any) -> None:
    if (
        type(value) is not str
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise GeneratedMediaEvidenceInspectorError("invalid hex digest")
