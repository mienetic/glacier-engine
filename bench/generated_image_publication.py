"""Independent bounded generated-image publication oracle."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media
from bench import media_runtime_txn as resource
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as continuation


class GeneratedImagePublicationError(ValueError):
    """A generated-image plan, provenance, result, or binding is invalid."""


Record = dict[str, Any]
PLAN_ABI = 0x4749504C414E0001
PLAN_BYTES = 736
PLAN_BODY_BYTES = PLAN_BYTES - 32
PLAN_MAGIC = b"GIPLAN1\x00"
PLAN_DOMAIN = b"glacier-generated-image-plan-v1\x00"
PROVENANCE_ABI = 0x474950524F560001
PROVENANCE_BYTES = 640
PROVENANCE_BODY_BYTES = PROVENANCE_BYTES - 32
PROVENANCE_MAGIC = b"GIPROV1\x00"
PROVENANCE_DOMAIN = b"glacier-generated-image-provenance-v1\x00"
RESULT_ABI = 0x474952534C540001
RESULT_BYTES = 704
RESULT_BODY_BYTES = RESULT_BYTES - 32
RESULT_MAGIC = b"GIRSLT1\x00"
RESULT_DOMAIN = b"glacier-generated-image-result-v1\x00"
SOURCE_PROVENANCE_DOMAIN = (
    b"glacier-generated-image-source-provenance-v1\x00"
)
RESOURCE_DOMAIN = b"glacier-generated-image-resource-v1\x00"
RUNTIME_ABI = 0x4749525400000001
RAW_IMAGE_SEMANTIC_ABI = 0x4749524157000001
RAW_CONTAINER_ID = 0x4749524157000001
INTERLEAVED_U8_CODEC_ID = 0x4749553800000001
REFERENCE_DECODER_ABI = 0x47494445434F0001
REFERENCE_DECODER_PAYLOAD = bytes((4, 3, 2, 1))
REFERENCE_TERMINAL_LATENT = bytes((6, 12, 18, 24))
REFERENCE_PIXELS = bytes((24, 36, 36, 24))
MAXIMUM_DIMENSION = 8_192
MAXIMUM_PIXEL_BYTES = 16 * 1024 * 1024
MAXIMUM_LATENT_BYTES = 16 * 1024 * 1024
GRAY = 1
RGB = 2
LINEAR = 1
SRGB = 2
ALPHA_NONE = 1
ALPHA_STRAIGHT = 2
ZERO_DIGEST = bytes(32)

PLAN_SCALARS = (
    "request_epoch",
    "generation",
    "image_index",
    "source_step",
    "width",
    "height",
    "channels",
    "row_stride",
    "latent_bytes",
    "pixel_bytes",
    "maximum_output_bytes",
    "decoder_abi",
    "color_model",
    "transfer_function",
    "alpha_mode",
    "publication_sequence",
    "visible_images_before",
    "visible_images_after",
    "logical_units",
    "required_capabilities",
)
PLAN_DIGESTS = (
    "artifact_sha256",
    "terminal_result_sha256",
    "terminal_plan_sha256",
    "terminal_output_sha256",
    "terminal_state_publication_sha256",
    "stateful_checkpoint_sha256",
    "decoder_payload_sha256",
    "decoder_implementation_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "source_provenance_sha256",
    "challenge_sha256",
    "previous_plan_sha256",
    "previous_result_sha256",
    "media_object_sha256",
)
PROVENANCE_SCALARS = (
    "request_epoch",
    "generation",
    "image_index",
    "source_step",
    "width",
    "height",
    "channels",
    "pixel_bytes",
    "decoder_abi",
    "color_model",
    "transfer_function",
    "alpha_mode",
)
PROVENANCE_DIGESTS = (
    "plan_sha256",
    "artifact_sha256",
    "terminal_result_sha256",
    "terminal_plan_sha256",
    "terminal_output_sha256",
    "terminal_state_publication_sha256",
    "stateful_checkpoint_sha256",
    "decoder_payload_sha256",
    "decoder_implementation_sha256",
    "media_object_sha256",
    "output_sha256",
    "tenant_scope_sha256",
    "metadata_policy_sha256",
    "source_provenance_sha256",
    "challenge_sha256",
)
RESULT_SCALARS = (
    "request_epoch",
    "generation",
    "image_index",
    "source_step",
    "width",
    "height",
    "channels",
    "row_stride",
    "pixel_bytes",
    "publication_sequence",
    "visible_images_before",
    "visible_images_after",
    "logical_units",
    "decoder_abi",
)
RESULT_DIGESTS = (
    "plan_sha256",
    "provenance_sha256",
    "artifact_sha256",
    "terminal_result_sha256",
    "terminal_output_sha256",
    "terminal_state_publication_sha256",
    "media_object_sha256",
    "output_sha256",
    "resource_receipt_sha256",
    "publication_state_before_sha256",
    "timeline_event_sha256",
    "media_commit_sha256",
    "publication_state_after_sha256",
    "previous_result_sha256",
    "decoder_implementation_sha256",
    "challenge_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= model.U64_MAX:
        raise GeneratedImagePublicationError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or value == ZERO_DIGEST
    ):
        raise GeneratedImagePublicationError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _checked_add(left: int, right: int) -> int:
    result = left + right
    if result > model.U64_MAX:
        raise GeneratedImagePublicationError("u64 addition overflow")
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    if result > model.U64_MAX:
        raise GeneratedImagePublicationError("u64 multiplication overflow")
    return result


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
        raise GeneratedImagePublicationError("invalid record") from None
    for field in scalars:
        _u64(result[field])
    for field in digests + (root_field,):
        _digest(result[field])
    return result


def _valid_color_shape(
    channels: int,
    color_model: int,
    alpha_mode: int,
) -> bool:
    return (
        channels == 1
        and color_model == GRAY
        and alpha_mode == ALPHA_NONE
        or channels == 3
        and color_model == RGB
        and alpha_mode == ALPHA_NONE
        or channels == 4
        and color_model == RGB
        and alpha_mode == ALPHA_STRAIGHT
    )


def _plan_body(value: Record) -> bytes:
    plan = {
        **{field: value[field] for field in PLAN_SCALARS},
        **{field: value[field] for field in PLAN_DIGESTS},
    }
    output = bytearray(PLAN_BODY_BYTES)
    output[:32] = b"".join(
        (
            PLAN_MAGIC,
            _u64(PLAN_ABI),
            _u64(PLAN_BYTES),
            _u64(0),
        )
    )
    output[32:192] = b"".join(
        _u64(plan[field]) for field in PLAN_SCALARS
    )
    output[224:704] = b"".join(
        _digest(plan[field]) for field in PLAN_DIGESTS
    )
    return bytes(output)


def plan_root(value: Record) -> bytes:
    return _hash(PLAN_DOMAIN, _plan_body(value))


def validate_plan(value: Record) -> Record:
    plan = _record(value, PLAN_SCALARS, PLAN_DIGESTS, "plan_sha256")
    stride = _checked_mul(plan["width"], plan["channels"])
    pixel_bytes = _checked_mul(stride, plan["height"])
    expected_after = _checked_add(plan["visible_images_before"], 1)
    if (
        plan["request_epoch"] == 0
        or plan["generation"] == 0
        or plan["image_index"] != expected_after
        or plan["source_step"] == 0
        or not 0 < plan["width"] <= MAXIMUM_DIMENSION
        or not 0 < plan["height"] <= MAXIMUM_DIMENSION
        or not 0 < plan["channels"] <= 4
        or plan["row_stride"] != stride
        or not 0 < plan["latent_bytes"] <= MAXIMUM_LATENT_BYTES
        or plan["pixel_bytes"] != pixel_bytes
        or not 0 < plan["pixel_bytes"] <= MAXIMUM_PIXEL_BYTES
        or plan["maximum_output_bytes"] != plan["pixel_bytes"]
        or plan["decoder_abi"] == 0
        or plan["publication_sequence"] == 0
        or plan["visible_images_after"] != expected_after
        or plan["logical_units"] != 1
        or plan["required_capabilities"] != 0
        or not _valid_color_shape(
            plan["channels"],
            plan["color_model"],
            plan["alpha_mode"],
        )
        or plan["transfer_function"] not in (LINEAR, SRGB)
        or plan["plan_sha256"] != plan_root(plan)
    ):
        raise GeneratedImagePublicationError("invalid generated image plan")
    return plan


def encode_plan(value: Record) -> bytes:
    plan = validate_plan(value)
    return _plan_body(plan) + plan["plan_sha256"]


def decode_plan(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PLAN_BYTES
        or encoded[:8] != PLAN_MAGIC
        or _read(encoded, 8) != PLAN_ABI
        or _read(encoded, 16) != PLAN_BYTES
        or _read(encoded, 24) != 0
        or any(encoded[192:224])
    ):
        raise GeneratedImagePublicationError("invalid plan wire")
    plan: Record = {
        field: _read(encoded, 32 + index * 8)
        for index, field in enumerate(PLAN_SCALARS)
    }
    plan.update(
        {
            field: encoded[224 + index * 32 : 256 + index * 32]
            for index, field in enumerate(PLAN_DIGESTS)
        }
    )
    plan["plan_sha256"] = encoded[704:736]
    plan = validate_plan(plan)
    if encode_plan(plan) != encoded:
        raise GeneratedImagePublicationError("non-canonical plan")
    return plan


def _provenance_body(value: Record) -> bytes:
    output = bytearray(PROVENANCE_BODY_BYTES)
    output[:32] = b"".join(
        (
            PROVENANCE_MAGIC,
            _u64(PROVENANCE_ABI),
            _u64(PROVENANCE_BYTES),
            _u64(0),
        )
    )
    output[32:128] = b"".join(
        _u64(value[field]) for field in PROVENANCE_SCALARS
    )
    output[128:608] = b"".join(
        _digest(value[field]) for field in PROVENANCE_DIGESTS
    )
    return bytes(output)


def provenance_root(value: Record) -> bytes:
    return _hash(PROVENANCE_DOMAIN, _provenance_body(value))


def validate_provenance(value: Record) -> Record:
    provenance = _record(
        value,
        PROVENANCE_SCALARS,
        PROVENANCE_DIGESTS,
        "provenance_sha256",
    )
    if (
        provenance["request_epoch"] == 0
        or provenance["generation"] == 0
        or provenance["image_index"] == 0
        or provenance["source_step"] == 0
        or not 0 < provenance["width"] <= MAXIMUM_DIMENSION
        or not 0 < provenance["height"] <= MAXIMUM_DIMENSION
        or not 0 < provenance["channels"] <= 4
        or not 0 < provenance["pixel_bytes"] <= MAXIMUM_PIXEL_BYTES
        or provenance["decoder_abi"] == 0
        or not _valid_color_shape(
            provenance["channels"],
            provenance["color_model"],
            provenance["alpha_mode"],
        )
        or provenance["transfer_function"] not in (LINEAR, SRGB)
        or provenance["provenance_sha256"] != provenance_root(provenance)
    ):
        raise GeneratedImagePublicationError("invalid provenance")
    return provenance


def make_provenance(plan_value: Record, output_sha256: bytes) -> Record:
    plan = validate_plan(plan_value)
    _digest(output_sha256)
    provenance: Record = {
        **{field: plan[field] for field in PROVENANCE_SCALARS},
        "plan_sha256": plan["plan_sha256"],
        "artifact_sha256": plan["artifact_sha256"],
        "terminal_result_sha256": plan["terminal_result_sha256"],
        "terminal_plan_sha256": plan["terminal_plan_sha256"],
        "terminal_output_sha256": plan["terminal_output_sha256"],
        "terminal_state_publication_sha256": plan[
            "terminal_state_publication_sha256"
        ],
        "stateful_checkpoint_sha256": plan[
            "stateful_checkpoint_sha256"
        ],
        "decoder_payload_sha256": plan["decoder_payload_sha256"],
        "decoder_implementation_sha256": plan[
            "decoder_implementation_sha256"
        ],
        "media_object_sha256": plan["media_object_sha256"],
        "output_sha256": output_sha256,
        "tenant_scope_sha256": plan["tenant_scope_sha256"],
        "metadata_policy_sha256": plan["metadata_policy_sha256"],
        "source_provenance_sha256": plan["source_provenance_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
    }
    provenance["provenance_sha256"] = provenance_root(provenance)
    return validate_provenance(provenance)


def validate_provenance_bindings(
    plan_value: Record,
    provenance_value: Record,
    media_object: Record,
) -> None:
    plan = validate_plan(plan_value)
    provenance = validate_provenance(provenance_value)
    media_wire = media.encode_media_object(media_object)
    media_value = media.decode_media_object(media_wire)
    media_root = media.media_object_sha256(media_wire)
    for field in PROVENANCE_SCALARS:
        if provenance[field] != plan[field]:
            raise GeneratedImagePublicationError(
                "provenance scalar does not match plan"
            )
    plan_digest_fields = (
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
    if (
        provenance["plan_sha256"] != plan["plan_sha256"]
        or any(
            provenance[field] != plan[field]
            for field in plan_digest_fields
        )
        or media_root != plan["media_object_sha256"]
        or media_value["content_sha256"] != provenance["output_sha256"]
    ):
        raise GeneratedImagePublicationError(
            "provenance does not match plan or media"
        )


def encode_provenance(value: Record) -> bytes:
    provenance = validate_provenance(value)
    return _provenance_body(provenance) + provenance["provenance_sha256"]


def decode_provenance(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PROVENANCE_BYTES
        or encoded[:8] != PROVENANCE_MAGIC
        or _read(encoded, 8) != PROVENANCE_ABI
        or _read(encoded, 16) != PROVENANCE_BYTES
        or _read(encoded, 24) != 0
    ):
        raise GeneratedImagePublicationError("invalid provenance wire")
    value: Record = {
        field: _read(encoded, 32 + index * 8)
        for index, field in enumerate(PROVENANCE_SCALARS)
    }
    value.update(
        {
            field: encoded[128 + index * 32 : 160 + index * 32]
            for index, field in enumerate(PROVENANCE_DIGESTS)
        }
    )
    value["provenance_sha256"] = encoded[608:640]
    value = validate_provenance(value)
    if encode_provenance(value) != encoded:
        raise GeneratedImagePublicationError("non-canonical provenance")
    return value


def _result_body(value: Record) -> bytes:
    output = bytearray(RESULT_BODY_BYTES)
    output[:32] = b"".join(
        (
            RESULT_MAGIC,
            _u64(RESULT_ABI),
            _u64(RESULT_BYTES),
            _u64(0),
        )
    )
    output[32:144] = b"".join(
        _u64(value[field]) for field in RESULT_SCALARS
    )
    output[160:672] = b"".join(
        _digest(value[field]) for field in RESULT_DIGESTS
    )
    return bytes(output)


def result_root(value: Record) -> bytes:
    return _hash(RESULT_DOMAIN, _result_body(value))


def validate_result(value: Record) -> Record:
    result = _record(value, RESULT_SCALARS, RESULT_DIGESTS, "result_sha256")
    expected_after = _checked_add(result["visible_images_before"], 1)
    stride = _checked_mul(result["width"], result["channels"])
    pixel_bytes = _checked_mul(stride, result["height"])
    if (
        result["request_epoch"] == 0
        or result["generation"] == 0
        or result["image_index"] != expected_after
        or result["source_step"] == 0
        or not 0 < result["width"] <= MAXIMUM_DIMENSION
        or not 0 < result["height"] <= MAXIMUM_DIMENSION
        or not 0 < result["channels"] <= 4
        or result["row_stride"] != stride
        or result["pixel_bytes"] != pixel_bytes
        or not 0 < result["pixel_bytes"] <= MAXIMUM_PIXEL_BYTES
        or result["publication_sequence"] == 0
        or result["visible_images_after"] != expected_after
        or result["logical_units"] != 1
        or result["decoder_abi"] == 0
        or result["result_sha256"] != result_root(result)
    ):
        raise GeneratedImagePublicationError("invalid result")
    return result


def encode_result(value: Record) -> bytes:
    result = validate_result(value)
    return _result_body(result) + result["result_sha256"]


def decode_result(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != RESULT_BYTES
        or encoded[:8] != RESULT_MAGIC
        or _read(encoded, 8) != RESULT_ABI
        or _read(encoded, 16) != RESULT_BYTES
        or _read(encoded, 24) != 0
        or any(encoded[144:160])
    ):
        raise GeneratedImagePublicationError("invalid result wire")
    value: Record = {
        field: _read(encoded, 32 + index * 8)
        for index, field in enumerate(RESULT_SCALARS)
    }
    value.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(RESULT_DIGESTS)
        }
    )
    value["result_sha256"] = encoded[672:704]
    value = validate_result(value)
    if encode_result(value) != encoded:
        raise GeneratedImagePublicationError("non-canonical result")
    return value


def source_provenance_root(
    manifest: Record,
    checkpoint: Record,
    terminal_plan: Record,
    terminal_result: Record,
    terminal_state_publication: Record,
    decoder_payload_sha256: bytes,
    decoder_implementation_sha256: bytes,
    tenant_scope_sha256: bytes,
    metadata_policy_sha256: bytes,
    challenge_sha256: bytes,
) -> bytes:
    return _hash(
        SOURCE_PROVENANCE_DOMAIN,
        _u64(PLAN_ABI),
        _u64(terminal_result["request_epoch"]),
        _u64(terminal_result["generation"]),
        _digest(manifest["artifact_sha256"]),
        _digest(checkpoint["checkpoint_sha256"]),
        _digest(terminal_plan["plan_sha256"]),
        _digest(terminal_result["result_sha256"]),
        _digest(terminal_result["output_sha256"]),
        _digest(terminal_state_publication["publication_sha256"]),
        _digest(decoder_payload_sha256),
        _digest(decoder_implementation_sha256),
        _digest(tenant_scope_sha256),
        _digest(metadata_policy_sha256),
        _digest(challenge_sha256),
    )


def decoder_implementation_root() -> bytes:
    return model.sha256(b"reference exact latent-to-gray8 decoder v1")


def reference_decode(
    terminal_latent: bytes,
    decoder_payload: bytes = REFERENCE_DECODER_PAYLOAD,
) -> bytes:
    if (
        not isinstance(terminal_latent, bytes)
        or not isinstance(decoder_payload, bytes)
        or len(terminal_latent) != len(decoder_payload)
    ):
        raise GeneratedImagePublicationError("invalid decoder input")
    output = bytearray()
    for latent_value, weight in zip(terminal_latent, decoder_payload):
        pixel = latent_value * weight
        if pixel > 255:
            raise GeneratedImagePublicationError("decoder output overflow")
        output.append(pixel)
    return bytes(output)


def claim_for_plan(plan_value: Record, decoder_payload_bytes: int) -> Record:
    plan = validate_plan(plan_value)
    _u64(decoder_payload_bytes)
    if decoder_payload_bytes == 0:
        raise GeneratedImagePublicationError("empty decoder payload")
    private_bytes = _checked_add(
        plan["pixel_bytes"],
        PROVENANCE_BYTES + RESULT_BYTES,
    )
    return {
        "capsule_bytes": decoder_payload_bytes,
        "kv_bytes": 0,
        "activation_bytes": plan["latent_bytes"],
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
    decoder_implementation_sha256: bytes,
) -> bytes:
    receipt = resource.resource_receipt(
        receipt_value["bank_epoch"],
        receipt_value["slot_index"],
        receipt_value["generation"],
        receipt_value["owner_key"],
        receipt_value["claim"],
    )
    if receipt != receipt_value:
        raise GeneratedImagePublicationError("invalid resource receipt")
    return _hash(
        RESOURCE_DOMAIN,
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
        _digest(decoder_implementation_sha256),
    )


def timeline_event_for_plan(
    plan_value: Record,
    publication_state: Record,
) -> Record:
    plan = validate_plan(plan_value)
    return {
        "kind": media.IDENTITY,
        "sequence": plan["publication_sequence"],
        "media_object_sha256": plan["media_object_sha256"],
        "source": ((0, (1, 1)), (plan["logical_units"], (1, 1))),
        "target": (
            (publication_state["visible_units"], (1, 1)),
            (
                _checked_add(
                    publication_state["visible_units"],
                    plan["logical_units"],
                ),
                (1, 1),
            ),
        ),
        "plan_sha256": plan["plan_sha256"],
        "previous_event_sha256": publication_state["timeline_sha256"],
    }


def make_plan(
    *,
    manifest: Record,
    checkpoint: Record,
    terminal_plan: Record,
    terminal_result: Record,
    terminal_state_publication: Record,
    media_object: Record,
    decoder_payload: bytes,
    publication_state: Record,
    previous_plan_sha256: bytes,
    previous_result_sha256: bytes,
) -> Record:
    checkpoint = continuation.validate_checkpoint(checkpoint)
    terminal_state_publication = stateful.validate_publication(
        terminal_state_publication
    )
    terminal_plan = model.decode_plan(model.encode_plan(terminal_plan))
    terminal_result = model.decode_result(model.encode_result(terminal_result))
    media_root = media.media_object_sha256(
        media.encode_media_object(media_object)
    )
    implementation_sha256 = decoder_implementation_root()
    payload_sha256 = model.sha256(decoder_payload)
    source_provenance_sha256 = source_provenance_root(
        manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        terminal_state_publication,
        payload_sha256,
        implementation_sha256,
        media_object["tenant_scope_sha256"],
        media_object["metadata_policy_sha256"],
        terminal_result["challenge_sha256"],
    )
    after = _checked_add(publication_state["visible_chunks"], 1)
    channels = media_object["axes"][2]
    color_model = GRAY if channels == 1 else RGB
    alpha_mode = ALPHA_STRAIGHT if channels == 4 else ALPHA_NONE
    plan: Record = {
        "request_epoch": terminal_result["request_epoch"],
        "generation": terminal_result["generation"],
        "image_index": after,
        "source_step": terminal_state_publication["current_step"],
        "width": media_object["axes"][0],
        "height": media_object["axes"][1],
        "channels": channels,
        "row_stride": media_object["axes"][0] * channels,
        "latent_bytes": terminal_result["output_bytes"],
        "pixel_bytes": media_object["byte_length"],
        "maximum_output_bytes": media_object["byte_length"],
        "decoder_abi": REFERENCE_DECODER_ABI,
        "color_model": color_model,
        "transfer_function": LINEAR,
        "alpha_mode": alpha_mode,
        "publication_sequence": publication_state["next_sequence"],
        "visible_images_before": publication_state["visible_chunks"],
        "visible_images_after": after,
        "logical_units": 1,
        "required_capabilities": 0,
        "artifact_sha256": manifest["artifact_sha256"],
        "terminal_result_sha256": terminal_result["result_sha256"],
        "terminal_plan_sha256": terminal_plan["plan_sha256"],
        "terminal_output_sha256": terminal_result["output_sha256"],
        "terminal_state_publication_sha256": terminal_state_publication[
            "publication_sha256"
        ],
        "stateful_checkpoint_sha256": checkpoint["checkpoint_sha256"],
        "decoder_payload_sha256": payload_sha256,
        "decoder_implementation_sha256": implementation_sha256,
        "tenant_scope_sha256": media_object["tenant_scope_sha256"],
        "metadata_policy_sha256": media_object["metadata_policy_sha256"],
        "source_provenance_sha256": source_provenance_sha256,
        "challenge_sha256": terminal_result["challenge_sha256"],
        "previous_plan_sha256": previous_plan_sha256,
        "previous_result_sha256": previous_result_sha256,
        "media_object_sha256": media_root,
    }
    plan["plan_sha256"] = plan_root(plan)
    plan = validate_plan(plan)
    validate_bindings(
        plan,
        manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        terminal_state_publication,
        media_object,
        decoder_payload,
        publication_state,
    )
    return plan


def validate_bindings(
    plan_value: Record,
    manifest: Record,
    checkpoint_value: Record,
    terminal_plan: Record,
    terminal_result: Record,
    terminal_state_publication: Record,
    media_object: Record,
    decoder_payload: bytes,
    publication_state: Record,
) -> None:
    plan = validate_plan(plan_value)
    checkpoint = continuation.validate_checkpoint(checkpoint_value)
    state = stateful.validate_publication(terminal_state_publication)
    terminal_plan = model.decode_plan(model.encode_plan(terminal_plan))
    terminal_result = model.decode_result(model.encode_result(terminal_result))
    media_wire = media.encode_media_object(media_object)
    media_root = media.media_object_sha256(media_wire)
    media_object = media.decode_media_object(media_wire)
    implementation_sha256 = decoder_implementation_root()
    payload_sha256 = model.sha256(decoder_payload)
    expected_source = source_provenance_root(
        manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        state,
        payload_sha256,
        implementation_sha256,
        media_object["tenant_scope_sha256"],
        media_object["metadata_policy_sha256"],
        terminal_result["challenge_sha256"],
    )
    if (
        manifest["family"] != 7
        or manifest["input_kind"] != 6
        or manifest["output_kind"] != 6
        or manifest["numerical_policy"] != model.EXACT_INTEGER
        or terminal_plan["family"] != 7
        or terminal_plan["operation"] != 8
        or terminal_result["family"] != 7
        or terminal_result["operation"] != 8
        or plan["request_epoch"] != terminal_plan["request_epoch"]
        or plan["request_epoch"] != terminal_result["request_epoch"]
        or plan["request_epoch"] != state["request_epoch"]
        or plan["request_epoch"] != checkpoint["request_epoch"]
        or plan["generation"] != terminal_plan["generation"]
        or plan["generation"] != terminal_result["generation"]
        or plan["source_step"] != state["current_step"]
        or plan["source_step"] != state["total_steps"]
        or plan["source_step"] != checkpoint["total_steps"]
        or plan["source_step"] != checkpoint["current_step"] + 1
        or plan["latent_bytes"] != terminal_result["output_bytes"]
        or terminal_plan["output_bytes"] != terminal_result["output_bytes"]
        or terminal_plan["output_bytes"] != state["state_bytes"]
        or state["previous_result_sha256"] != terminal_result["result_sha256"]
        or checkpoint["artifact_sha256"] != manifest["artifact_sha256"]
        or terminal_plan["artifact_sha256"] != manifest["artifact_sha256"]
        or terminal_result["artifact_sha256"] != manifest["artifact_sha256"]
        or terminal_result["plan_sha256"] != terminal_plan["plan_sha256"]
        or terminal_result["resource_bank_epoch"]
        != checkpoint["restore_bank_epoch"]
        or terminal_result["previous_result_sha256"]
        != checkpoint["previous_result_sha256"]
        or terminal_plan["previous_plan_sha256"]
        != checkpoint["last_plan_sha256"]
        or terminal_plan["processor_state_sha256"]
        != checkpoint["state_publication_sha256"]
        or terminal_plan["cache_payload_sha256"]
        != checkpoint["current_state_sha256"]
        or terminal_plan["challenge_sha256"] != checkpoint["challenge_sha256"]
        or checkpoint["publication_next_sequence"]
        != terminal_result["publication_sequence"]
        or media_object["kind"] != media.IMAGE
        or media_object["semantic_abi"] != RAW_IMAGE_SEMANTIC_ABI
        or media_object["container_id"] != RAW_CONTAINER_ID
        or media_object["codec_id"] != INTERLEAVED_U8_CODEC_ID
        or tuple(media_object["axes"])
        != (plan["width"], plan["height"], plan["channels"])
        or media_object["time_base"] != (0, 1)
        or publication_state["request_epoch"] != plan["request_epoch"]
        or publication_state["next_sequence"] != plan["publication_sequence"]
        or publication_state["visible_chunks"]
        != plan["visible_images_before"]
        or publication_state["visible_units"] != 0
        or publication_state["timeline_base"] != (1, 1)
        or publication_state["timeline_sha256"] != ZERO_DIGEST
        or publication_state["media_object_sha256"]
        != plan["media_object_sha256"]
        or payload_sha256 != plan["decoder_payload_sha256"]
        or implementation_sha256 != plan["decoder_implementation_sha256"]
        or manifest["artifact_sha256"] != plan["artifact_sha256"]
        or terminal_result["result_sha256"] != plan["terminal_result_sha256"]
        or terminal_plan["plan_sha256"] != plan["terminal_plan_sha256"]
        or terminal_result["output_sha256"] != plan["terminal_output_sha256"]
        or state["publication_sha256"]
        != plan["terminal_state_publication_sha256"]
        or checkpoint["checkpoint_sha256"]
        != plan["stateful_checkpoint_sha256"]
        or media_root != plan["media_object_sha256"]
        or media_object["tenant_scope_sha256"] != plan["tenant_scope_sha256"]
        or media_object["metadata_policy_sha256"]
        != plan["metadata_policy_sha256"]
        or media_object["provenance_sha256"]
        != plan["source_provenance_sha256"]
        or expected_source != plan["source_provenance_sha256"]
        or terminal_result["challenge_sha256"] != plan["challenge_sha256"]
        or checkpoint["challenge_sha256"] != plan["challenge_sha256"]
    ):
        raise GeneratedImagePublicationError("invalid generated image binding")


def make_result(
    *,
    plan_value: Record,
    provenance_value: Record,
    media_object: Record,
    receipt: Record,
    publication_state_before: Record,
) -> tuple[Record, Record]:
    plan = validate_plan(plan_value)
    provenance = validate_provenance(provenance_value)
    validate_provenance_bindings(
        plan,
        provenance,
        media_object,
    )
    event = timeline_event_for_plan(plan, publication_state_before)
    resource_root = resource_receipt_root(
        receipt,
        plan["request_epoch"],
        plan["plan_sha256"],
        plan["decoder_implementation_sha256"],
    )
    prepared = media.prepare_publication(
        publication_state_before,
        event,
        provenance["output_sha256"],
        resource_root,
    )
    state_after = media.commit_publication(publication_state_before, prepared)
    result: Record = {
        **{field: plan[field] for field in RESULT_SCALARS},
        "plan_sha256": plan["plan_sha256"],
        "provenance_sha256": provenance["provenance_sha256"],
        "artifact_sha256": plan["artifact_sha256"],
        "terminal_result_sha256": plan["terminal_result_sha256"],
        "terminal_output_sha256": plan["terminal_output_sha256"],
        "terminal_state_publication_sha256": plan[
            "terminal_state_publication_sha256"
        ],
        "media_object_sha256": plan["media_object_sha256"],
        "output_sha256": provenance["output_sha256"],
        "resource_receipt_sha256": resource_root,
        "publication_state_before_sha256": media.publication_state_root(
            publication_state_before
        ),
        "timeline_event_sha256": media.timeline_event_root(event),
        "media_commit_sha256": prepared["commit_sha256"],
        "publication_state_after_sha256": media.publication_state_root(
            state_after
        ),
        "previous_result_sha256": plan["previous_result_sha256"],
        "decoder_implementation_sha256": plan[
            "decoder_implementation_sha256"
        ],
        "challenge_sha256": plan["challenge_sha256"],
    }
    result["result_sha256"] = result_root(result)
    return validate_result(result), state_after
