"""Independent oracle for Glacier's typed model-family contract wires."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class ModelContractError(ValueError):
    """A model artifact, execution plan, result, or support query is invalid."""


Record = dict[str, Any]
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
ARTIFACT_MANIFEST_ABI = 0x474D414600000001
EXECUTION_PLAN_ABI = 0x474D504C00000001
RESULT_ENVELOPE_ABI = 0x474D525300000001
ARTIFACT_MANIFEST_BYTES = 320
EXECUTION_PLAN_BYTES = 768
RESULT_ENVELOPE_BYTES = 768
ARTIFACT_BODY_BYTES = ARTIFACT_MANIFEST_BYTES - 32
PLAN_BODY_BYTES = EXECUTION_PLAN_BYTES - 32
RESULT_BODY_BYTES = RESULT_ENVELOPE_BYTES - 32
ARTIFACT_MAGIC = b"GMART1\x00\x00"
PLAN_MAGIC = b"GMPLAN1\x00"
RESULT_MAGIC = b"GMRES1\x00\x00"
ARTIFACT_DOMAIN = b"glacier-model-artifact-manifest-v1\x00"
PLAN_DOMAIN = b"glacier-model-execution-plan-v1\x00"
RESULT_DOMAIN = b"glacier-model-result-envelope-v1\x00"
PUBLICATION_STATE_DOMAIN = b"glacier-model-publication-state-v1\x00"
PUBLICATION_COMMIT_DOMAIN = b"glacier-model-publication-commit-v1\x00"
CLAIM_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "logits_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "device_bytes",
    "io_bytes",
    "queue_slots",
)
PLAN_DIGEST_FIELDS = (
    "artifact_sha256",
    "weights_sha256",
    "media_object_sha256",
    "processor_state_sha256",
    "processor_bundle_sha256",
    "cache_bundle_sha256",
    "cache_payload_sha256",
    "ownership_sha256",
    "challenge_sha256",
    "previous_plan_sha256",
    "input_schema_sha256",
    "output_schema_sha256",
)
RESULT_DIGEST_FIELDS = (
    "artifact_sha256",
    "plan_sha256",
    "media_object_sha256",
    "processor_state_sha256",
    "cache_bundle_sha256",
    "cache_payload_sha256",
    "ownership_sha256",
    "output_sha256",
    "source_mapping_sha256",
    "challenge_sha256",
    "previous_result_sha256",
    "publication_state_before_sha256",
    "publication_commit_sha256",
    "adapter_sha256",
)

# IDs are vocabulary, not claims of executable support.
VISION_UNDERSTANDING = 3
ENCODE = 3
IMAGE_FEATURE_U8 = 3
EMBEDDING_I32 = 2
EXACT_INTEGER = 1
FAMILY_IDS = frozenset(range(1, 18))
OPERATION_IDS = frozenset(range(1, 13))
INPUT_KIND_IDS = frozenset(range(1, 8))
OUTPUT_KIND_IDS = frozenset(range(1, 10))
NUMERICAL_POLICY_IDS = frozenset(range(1, 5))


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise ModelContractError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise ModelContractError("invalid digest")
    return value


def sha256(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def make_artifact(
    *,
    family: int,
    artifact_abi: int,
    input_kind: int,
    output_kind: int,
    numerical_policy: int,
    max_batch_items: int,
    input_features: int,
    output_dimensions: int,
    input_element_bytes: int,
    output_element_bytes: int,
    weight_element_bytes: int,
    weights: bytes,
    metadata_sha256: bytes,
    license_sha256: bytes,
) -> Record:
    if weight_element_bytes <= 0 or len(weights) % weight_element_bytes:
        raise ModelContractError("invalid weight representation")
    weight_elements = len(weights) // weight_element_bytes
    weight_bytes = len(weights)
    if (
        min(
            artifact_abi,
            max_batch_items,
            input_features,
            output_dimensions,
            input_element_bytes,
            output_element_bytes,
            weight_element_bytes,
        )
        <= 0
        or weight_bytes > U64_MAX
        or len(weights) != weight_bytes
    ):
        raise ModelContractError("invalid artifact dimensions")
    value: Record = {
        "family": family,
        "artifact_abi": artifact_abi,
        "input_kind": input_kind,
        "output_kind": output_kind,
        "numerical_policy": numerical_policy,
        "max_batch_items": max_batch_items,
        "input_features": input_features,
        "output_dimensions": output_dimensions,
        "weight_elements": weight_elements,
        "input_element_bytes": input_element_bytes,
        "output_element_bytes": output_element_bytes,
        "weight_element_bytes": weight_element_bytes,
        "weight_bytes": weight_bytes,
        "weights_sha256": sha256(weights),
        "metadata_sha256": _digest(metadata_sha256),
        "license_sha256": _digest(license_sha256),
    }
    return decode_artifact(encode_artifact(value))


def encode_artifact(value: Record) -> bytes:
    try:
        scalars = (
            value["family"],
            value["artifact_abi"],
            value["input_kind"],
            value["output_kind"],
            value["numerical_policy"],
            value["max_batch_items"],
            value["input_features"],
            value["output_dimensions"],
            value["weight_elements"],
            value["weight_bytes"],
        )
        weight_element_bytes = value["weight_element_bytes"]
        input_element_bytes = value["input_element_bytes"]
        output_element_bytes = value["output_element_bytes"]
        digests = (
            _digest(value["weights_sha256"]),
            _digest(value["metadata_sha256"]),
            _digest(value["license_sha256"]),
        )
    except (KeyError, TypeError):
        raise ModelContractError("invalid artifact") from None
    for scalar in (
        *scalars,
        weight_element_bytes,
        input_element_bytes,
        output_element_bytes,
    ):
        _u64(scalar)
    if (
        min(scalars[1], *scalars[5:]) <= 0
        or input_element_bytes <= 0
        or output_element_bytes <= 0
        or weight_element_bytes <= 0
        or scalars[9] != scalars[8] * weight_element_bytes
        or scalars[0] not in FAMILY_IDS
        or scalars[2] not in INPUT_KIND_IDS
        or scalars[3] not in OUTPUT_KIND_IDS
        or scalars[4] not in NUMERICAL_POLICY_IDS
    ):
        raise ModelContractError("invalid artifact")
    output = bytearray(ARTIFACT_MANIFEST_BYTES)
    output[:32] = ARTIFACT_MAGIC + _u64(ARTIFACT_MANIFEST_ABI) + _u64(
        ARTIFACT_MANIFEST_BYTES
    ) + _u64(0)
    output[32:112] = b"".join(_u64(value) for value in scalars)
    output[112:208] = b"".join(digests)
    output[208:216] = _u64(weight_element_bytes)
    output[216:224] = _u64(input_element_bytes)
    output[224:232] = _u64(output_element_bytes)
    root = _root(ARTIFACT_DOMAIN, bytes(output[:ARTIFACT_BODY_BYTES]))
    supplied = value.get("artifact_sha256", ZERO_DIGEST)
    if supplied not in (ZERO_DIGEST, root):
        raise ModelContractError("artifact root mismatch")
    output[ARTIFACT_BODY_BYTES:] = root
    return bytes(output)


def decode_artifact(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != ARTIFACT_MANIFEST_BYTES
        or encoded[:8] != ARTIFACT_MAGIC
        or _read(encoded, 8) != ARTIFACT_MANIFEST_ABI
        or _read(encoded, 16) != ARTIFACT_MANIFEST_BYTES
        or _read(encoded, 24) != 0
        or any(encoded[232:ARTIFACT_BODY_BYTES])
    ):
        raise ModelContractError("invalid artifact wire")
    root = _root(ARTIFACT_DOMAIN, encoded[:ARTIFACT_BODY_BYTES])
    if encoded[ARTIFACT_BODY_BYTES:] != root:
        raise ModelContractError("artifact root mismatch")
    values = [_read(encoded, 32 + index * 8) for index in range(10)]
    result: Record = dict(
        zip(
            (
                "family",
                "artifact_abi",
                "input_kind",
                "output_kind",
                "numerical_policy",
                "max_batch_items",
                "input_features",
                "output_dimensions",
                "weight_elements",
                "weight_bytes",
            ),
            values,
        )
    )
    result.update(
        {
            "weights_sha256": encoded[112:144],
            "metadata_sha256": encoded[144:176],
            "license_sha256": encoded[176:208],
            "weight_element_bytes": _read(encoded, 208),
            "input_element_bytes": _read(encoded, 216),
            "output_element_bytes": _read(encoded, 224),
            "artifact_sha256": root,
        }
    )
    if encode_artifact(result) != encoded:
        raise ModelContractError("non-canonical artifact")
    return result


def make_plan(
    artifact: Record,
    *,
    operation: int,
    request_epoch: int,
    generation: int,
    batch_items: int,
    publication_next_sequence: int,
    maximum_absolute_output: int,
    required_capabilities: int,
    scratch_bytes: int,
    claim: Record,
    digests: Record,
) -> Record:
    artifact = decode_artifact(encode_artifact(artifact))
    if batch_items <= 0 or batch_items > artifact["max_batch_items"]:
        raise ModelContractError("invalid plan batch")
    input_bytes = (
        batch_items
        * artifact["input_features"]
        * artifact["input_element_bytes"]
    )
    output_bytes = (
        batch_items
        * artifact["output_dimensions"]
        * artifact["output_element_bytes"]
    )
    value: Record = {
        "family": artifact["family"],
        "operation": operation,
        "input_kind": artifact["input_kind"],
        "output_kind": artifact["output_kind"],
        "numerical_policy": artifact["numerical_policy"],
        "request_epoch": request_epoch,
        "generation": generation,
        "batch_items": batch_items,
        "input_features": artifact["input_features"],
        "output_dimensions": artifact["output_dimensions"],
        "input_bytes": input_bytes,
        "output_bytes": output_bytes,
        "scratch_bytes": scratch_bytes,
        "required_capabilities": required_capabilities,
        "publication_next_sequence": publication_next_sequence,
        "maximum_absolute_output": maximum_absolute_output,
        "weight_bytes": artifact["weight_bytes"],
        "input_element_bytes": artifact["input_element_bytes"],
        "output_element_bytes": artifact["output_element_bytes"],
        "claim": dict(claim),
        "artifact_sha256": artifact["artifact_sha256"],
        "weights_sha256": artifact["weights_sha256"],
        **digests,
    }
    return decode_plan(encode_plan(value))


def encode_plan(value: Record) -> bytes:
    scalar_fields = (
        "family",
        "operation",
        "input_kind",
        "output_kind",
        "numerical_policy",
        "request_epoch",
        "generation",
        "batch_items",
        "input_features",
        "output_dimensions",
        "input_bytes",
        "output_bytes",
        "scratch_bytes",
        "required_capabilities",
        "publication_next_sequence",
        "maximum_absolute_output",
        "weight_bytes",
    )
    try:
        scalars = tuple(value[field] for field in scalar_fields)
        claim = tuple(value["claim"][field] for field in CLAIM_FIELDS)
        digests = tuple(
            _digest(
                value[field],
                allow_zero=field == "previous_plan_sha256",
            )
            for field in PLAN_DIGEST_FIELDS
        )
    except (KeyError, TypeError):
        raise ModelContractError("invalid execution plan") from None
    for scalar in (*scalars, *claim):
        _u64(scalar)
    input_element_bytes = value["input_element_bytes"]
    output_element_bytes = value["output_element_bytes"]
    _u64(input_element_bytes)
    _u64(output_element_bytes)
    expected_input = scalars[7] * scalars[8] * input_element_bytes
    expected_output = scalars[7] * scalars[9] * output_element_bytes
    if (
        min(scalars[5], scalars[6], scalars[7], scalars[8], scalars[9])
        <= 0
        or scalars[10] != expected_input
        or scalars[11] != expected_output
        or input_element_bytes <= 0
        or output_element_bytes <= 0
        or scalars[15] <= 0
        or scalars[16] <= 0
        or claim[0] < scalars[16]
        or claim[2] < expected_input
        or claim[3] < scalars[12]
        or claim[5] < expected_output
        or claim[9] == 0
        or scalars[0] not in FAMILY_IDS
        or scalars[1] not in OPERATION_IDS
        or scalars[2] not in INPUT_KIND_IDS
        or scalars[3] not in OUTPUT_KIND_IDS
        or scalars[4] not in NUMERICAL_POLICY_IDS
    ):
        raise ModelContractError("invalid execution plan")
    output = bytearray(EXECUTION_PLAN_BYTES)
    output[:32] = PLAN_MAGIC + _u64(EXECUTION_PLAN_ABI) + _u64(
        EXECUTION_PLAN_BYTES
    ) + _u64(0)
    output[32:168] = b"".join(_u64(scalar) for scalar in scalars)
    output[176:256] = b"".join(_u64(scalar) for scalar in claim)
    output[256:640] = b"".join(digests)
    output[640:648] = _u64(input_element_bytes)
    output[648:656] = _u64(output_element_bytes)
    root = _root(PLAN_DOMAIN, bytes(output[:PLAN_BODY_BYTES]))
    supplied = value.get("plan_sha256", ZERO_DIGEST)
    if supplied not in (ZERO_DIGEST, root):
        raise ModelContractError("plan root mismatch")
    output[PLAN_BODY_BYTES:] = root
    return bytes(output)


def decode_plan(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != EXECUTION_PLAN_BYTES
        or encoded[:8] != PLAN_MAGIC
        or _read(encoded, 8) != EXECUTION_PLAN_ABI
        or _read(encoded, 16) != EXECUTION_PLAN_BYTES
        or _read(encoded, 24) != 0
        or _read(encoded, 168) != 0
        or any(encoded[656:PLAN_BODY_BYTES])
    ):
        raise ModelContractError("invalid execution plan wire")
    root = _root(PLAN_DOMAIN, encoded[:PLAN_BODY_BYTES])
    if encoded[PLAN_BODY_BYTES:] != root:
        raise ModelContractError("plan root mismatch")
    scalar_fields = (
        "family",
        "operation",
        "input_kind",
        "output_kind",
        "numerical_policy",
        "request_epoch",
        "generation",
        "batch_items",
        "input_features",
        "output_dimensions",
        "input_bytes",
        "output_bytes",
        "scratch_bytes",
        "required_capabilities",
        "publication_next_sequence",
        "maximum_absolute_output",
        "weight_bytes",
    )
    result: Record = {
        field: _read(encoded, 32 + index * 8)
        for index, field in enumerate(scalar_fields)
    }
    result["claim"] = {
        field: _read(encoded, 176 + index * 8)
        for index, field in enumerate(CLAIM_FIELDS)
    }
    result.update(
        {
            field: encoded[256 + index * 32 : 288 + index * 32]
            for index, field in enumerate(PLAN_DIGEST_FIELDS)
        }
    )
    result["input_element_bytes"] = _read(encoded, 640)
    result["output_element_bytes"] = _read(encoded, 648)
    result["plan_sha256"] = root
    if encode_plan(result) != encoded:
        raise ModelContractError("non-canonical execution plan")
    return result


def require_support(records: list[Record], plan: Record) -> None:
    stages = (
        ("family", "unsupported family"),
        ("operation", "unsupported operation"),
        ("input_kind", "unsupported input kind"),
        ("output_kind", "unsupported output kind"),
        ("numerical_policy", "unsupported numerical policy"),
    )
    candidates = records
    for field, message in stages:
        candidates = [
            record
            for record in candidates
            if record[field] == plan[field]
        ]
        if not candidates:
            raise ModelContractError(message)
    for record in candidates:
        if (
            plan["batch_items"] <= record["max_batch_items"]
            and plan["input_features"]
            <= record["max_input_features"]
            and plan["output_dimensions"]
            <= record["max_output_dimensions"]
        ):
            if (
                plan["required_capabilities"]
                & ~record["allowed_capabilities"]
            ):
                raise ModelContractError("unsupported capabilities")
            return
    raise ModelContractError("unsupported dimensions")


def publication_state_root(state: Record) -> bytes:
    if (
        state["request_epoch"] <= 0
        or state["next_sequence"] != state["visible_results"]
    ):
        raise ModelContractError("invalid publication state")
    return hashlib.sha256(
        PUBLICATION_STATE_DOMAIN
        + _u64(state["request_epoch"])
        + _u64(state["next_sequence"])
        + _u64(state["visible_results"])
        + _digest(state["artifact_sha256"])
        + _digest(
            state["previous_result_sha256"],
            allow_zero=True,
        )
    ).digest()


def publication_commit_root(result: Record) -> bytes:
    return hashlib.sha256(
        PUBLICATION_COMMIT_DOMAIN
        + result["publication_state_before_sha256"]
        + result["plan_sha256"]
        + result["output_sha256"]
        + result["source_mapping_sha256"]
        + result["previous_result_sha256"]
        + result["adapter_sha256"]
        + _u64(result["publication_sequence"])
    ).digest()


def make_result(
    state: Record,
    plan: Record,
    receipt: Record,
    *,
    output_sha256: bytes,
    source_mapping_sha256: bytes,
    adapter_sha256: bytes,
) -> Record:
    if (
        state["request_epoch"] != plan["request_epoch"]
        or state["next_sequence"] != plan["publication_next_sequence"]
        or state["artifact_sha256"] != plan["artifact_sha256"]
        or receipt["claim"] != plan["claim"]
    ):
        raise ModelContractError("invalid publication binding")
    result: Record = {
        "family": plan["family"],
        "operation": plan["operation"],
        "output_kind": plan["output_kind"],
        "numerical_policy": plan["numerical_policy"],
        "request_epoch": plan["request_epoch"],
        "generation": plan["generation"],
        "publication_sequence": state["next_sequence"],
        "batch_items": plan["batch_items"],
        "output_dimensions": plan["output_dimensions"],
        "output_element_bytes": plan["output_element_bytes"],
        "output_bytes": plan["output_bytes"],
        "resource_bank_epoch": receipt["bank_epoch"],
        "resource_slot_index": receipt["slot_index"],
        "resource_generation": receipt["generation"],
        "resource_owner_key": receipt["owner_key"],
        "claim": dict(receipt["claim"]),
        "resource_integrity": receipt["integrity"],
        "artifact_sha256": plan["artifact_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "media_object_sha256": plan["media_object_sha256"],
        "processor_state_sha256": plan["processor_state_sha256"],
        "cache_bundle_sha256": plan["cache_bundle_sha256"],
        "cache_payload_sha256": plan["cache_payload_sha256"],
        "ownership_sha256": plan["ownership_sha256"],
        "output_sha256": _digest(output_sha256),
        "source_mapping_sha256": _digest(source_mapping_sha256),
        "challenge_sha256": plan["challenge_sha256"],
        "previous_result_sha256": state["previous_result_sha256"],
        "publication_state_before_sha256": publication_state_root(state),
        "adapter_sha256": _digest(adapter_sha256),
    }
    result["publication_commit_sha256"] = publication_commit_root(result)
    return decode_result(encode_result(result))


def encode_result(value: Record) -> bytes:
    scalar_fields = (
        "family",
        "operation",
        "output_kind",
        "numerical_policy",
        "request_epoch",
        "generation",
        "publication_sequence",
        "batch_items",
        "output_dimensions",
        "output_bytes",
        "resource_bank_epoch",
        "resource_slot_index",
        "resource_generation",
        "resource_owner_key",
    )
    try:
        scalars = tuple(value[field] for field in scalar_fields)
        claim = tuple(value["claim"][field] for field in CLAIM_FIELDS)
        resource_integrity = value["resource_integrity"]
        digests = tuple(
            _digest(
                value[field],
                allow_zero=field == "previous_result_sha256",
            )
            for field in RESULT_DIGEST_FIELDS
        )
    except (KeyError, TypeError):
        raise ModelContractError("invalid result") from None
    output_element_bytes = value["output_element_bytes"]
    for scalar in (
        *scalars,
        *claim,
        resource_integrity,
        output_element_bytes,
    ):
        _u64(scalar)
    if (
        min(scalars[4], scalars[5], scalars[7], scalars[8]) <= 0
        or output_element_bytes <= 0
        or scalars[9]
        != scalars[7]
        * scalars[8]
        * output_element_bytes
        or min(scalars[10], scalars[12], scalars[13]) <= 0
        or resource_integrity <= 0
        or claim[5] < scalars[9]
        or claim[9] == 0
        or scalars[0] not in FAMILY_IDS
        or scalars[1] not in OPERATION_IDS
        or scalars[2] not in OUTPUT_KIND_IDS
        or scalars[3] not in NUMERICAL_POLICY_IDS
    ):
        raise ModelContractError("invalid result")
    candidate: Record = {**value}
    if publication_commit_root(candidate) != candidate[
        "publication_commit_sha256"
    ]:
        raise ModelContractError("publication commit mismatch")
    output = bytearray(RESULT_ENVELOPE_BYTES)
    output[:32] = RESULT_MAGIC + _u64(RESULT_ENVELOPE_ABI) + _u64(
        RESULT_ENVELOPE_BYTES
    ) + _u64(0)
    output[32:144] = b"".join(_u64(scalar) for scalar in scalars)
    output[144:224] = b"".join(_u64(scalar) for scalar in claim)
    output[224:232] = _u64(resource_integrity)
    output[232:240] = _u64(output_element_bytes)
    output[240:688] = b"".join(digests)
    root = _root(RESULT_DOMAIN, bytes(output[:RESULT_BODY_BYTES]))
    supplied = value.get("result_sha256", ZERO_DIGEST)
    if supplied not in (ZERO_DIGEST, root):
        raise ModelContractError("result root mismatch")
    output[RESULT_BODY_BYTES:] = root
    return bytes(output)


def decode_result(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != RESULT_ENVELOPE_BYTES
        or encoded[:8] != RESULT_MAGIC
        or _read(encoded, 8) != RESULT_ENVELOPE_ABI
        or _read(encoded, 16) != RESULT_ENVELOPE_BYTES
        or _read(encoded, 24) != 0
        or any(encoded[688:RESULT_BODY_BYTES])
    ):
        raise ModelContractError("invalid result wire")
    root = _root(RESULT_DOMAIN, encoded[:RESULT_BODY_BYTES])
    if encoded[RESULT_BODY_BYTES:] != root:
        raise ModelContractError("result root mismatch")
    scalar_fields = (
        "family",
        "operation",
        "output_kind",
        "numerical_policy",
        "request_epoch",
        "generation",
        "publication_sequence",
        "batch_items",
        "output_dimensions",
        "output_bytes",
        "resource_bank_epoch",
        "resource_slot_index",
        "resource_generation",
        "resource_owner_key",
    )
    result: Record = {
        field: _read(encoded, 32 + index * 8)
        for index, field in enumerate(scalar_fields)
    }
    result["claim"] = {
        field: _read(encoded, 144 + index * 8)
        for index, field in enumerate(CLAIM_FIELDS)
    }
    result["resource_integrity"] = _read(encoded, 224)
    result["output_element_bytes"] = _read(encoded, 232)
    result.update(
        {
            field: encoded[240 + index * 32 : 272 + index * 32]
            for index, field in enumerate(RESULT_DIGEST_FIELDS)
        }
    )
    result["result_sha256"] = root
    if encode_result(result) != encoded:
        raise ModelContractError("non-canonical result")
    return result


def reference_integer_projection(
    plan: Record,
    weights: bytes,
    image_features: bytes,
) -> bytes:
    if (
        len(weights) != plan["weight_bytes"]
        or len(image_features) != plan["input_bytes"]
    ):
        raise ModelContractError("projection input mismatch")
    output = bytearray()
    features = plan["input_features"]
    dimensions = plan["output_dimensions"]
    for batch in range(plan["batch_items"]):
        for dimension in range(dimensions):
            accumulator = sum(
                image_features[batch * features + feature]
                * struct.unpack(
                    "b",
                    weights[
                        dimension * features + feature :
                        dimension * features + feature + 1
                    ],
                )[0]
                for feature in range(features)
            )
            if (
                abs(accumulator) > plan["maximum_absolute_output"]
                or not -(1 << 31) <= accumulator < (1 << 31)
            ):
                raise ModelContractError("invalid projection candidate")
            output.extend(struct.pack("<i", accumulator))
    return bytes(output)
