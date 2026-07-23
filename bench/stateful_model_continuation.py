"""Independent oracle for portable stateful-model checkpoints."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import model_contract as model
from bench import stateful_model_adapter as stateful

Record = dict[str, Any]
CHECKPOINT_ABI = 0x4753434B00000001
CHECKPOINT_BYTES = 512
CHECKPOINT_BODY_BYTES = CHECKPOINT_BYTES - 32
CHECKPOINT_MAGIC = b"GSCHKP1\x00"
CHECKPOINT_DOMAIN = b"glacier-stateful-model-checkpoint-v1\x00"
ZERO_DIGEST = bytes(32)

SCALAR_FIELDS = (
    "request_epoch",
    "current_step",
    "total_steps",
    "state_bytes",
    "source_bank_epoch",
    "restore_bank_epoch",
    "restore_owner_key",
    "restore_tree_key",
    "restore_authority_key",
    "tenant_key",
    "scope_key",
    "allocation_key",
    "binding_key",
    "publication_next_sequence",
    "visible_results",
)
DIGEST_FIELDS = (
    "artifact_sha256",
    "model_publication_sha256",
    "state_publication_sha256",
    "previous_result_sha256",
    "last_plan_sha256",
    "last_output_sha256",
    "current_state_sha256",
    "challenge_sha256",
)


class StatefulModelContinuationError(ValueError):
    """A checkpoint or retained-state binding is invalid."""


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= model.U64_MAX:
        raise StatefulModelContinuationError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or value == ZERO_DIGEST
    ):
        raise StatefulModelContinuationError("invalid digest")
    return value


def _body(value: Record) -> bytes:
    try:
        scalars = tuple(value[field] for field in SCALAR_FIELDS)
        digests = tuple(value[field] for field in DIGEST_FIELDS)
    except (KeyError, TypeError):
        raise StatefulModelContinuationError(
            "invalid checkpoint"
        ) from None
    output = bytearray(CHECKPOINT_BODY_BYTES)
    output[:32] = b"".join(
        (
            CHECKPOINT_MAGIC,
            _u64(CHECKPOINT_ABI),
            _u64(CHECKPOINT_BYTES),
            _u64(0),
        )
    )
    output[32:152] = b"".join(_u64(item) for item in scalars)
    output[160:416] = b"".join(_digest(item) for item in digests)
    return bytes(output)


def checkpoint_root(value: Record) -> bytes:
    return hashlib.sha256(CHECKPOINT_DOMAIN + _body(value)).digest()


def validate_checkpoint(value: Record) -> Record:
    fields = SCALAR_FIELDS + DIGEST_FIELDS + ("checkpoint_sha256",)
    try:
        checkpoint = {field: value[field] for field in fields}
        for field in SCALAR_FIELDS:
            _u64(checkpoint[field])
        for field in DIGEST_FIELDS + ("checkpoint_sha256",):
            _digest(checkpoint[field])
    except (KeyError, TypeError):
        raise StatefulModelContinuationError(
            "invalid checkpoint"
        ) from None
    nonzero_scalars = (
        "request_epoch",
        "current_step",
        "total_steps",
        "state_bytes",
        "source_bank_epoch",
        "restore_bank_epoch",
        "restore_owner_key",
        "restore_tree_key",
        "restore_authority_key",
        "tenant_key",
        "scope_key",
        "allocation_key",
        "binding_key",
    )
    if (
        any(checkpoint[field] == 0 for field in nonzero_scalars)
        or checkpoint["current_step"] >= checkpoint["total_steps"]
        or checkpoint["source_bank_epoch"]
        == checkpoint["restore_bank_epoch"]
        or checkpoint["publication_next_sequence"]
        != checkpoint["current_step"]
        or checkpoint["visible_results"] != checkpoint["current_step"]
        or checkpoint["checkpoint_sha256"]
        != checkpoint_root(checkpoint)
    ):
        raise StatefulModelContinuationError("invalid checkpoint")
    return checkpoint


def make_checkpoint(
    *,
    source_bank_epoch: int,
    restore_plan: Record,
    model_publication: Record,
    state_publication: Record,
    last_result: Record,
) -> Record:
    state = stateful.validate_publication(state_publication)
    result = model.decode_result(model.encode_result(last_result))
    try:
        restored = {
            field: restore_plan[field]
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
        }
        model_root = model.publication_state_root(model_publication)
    except (KeyError, TypeError, model.ModelContractError):
        raise StatefulModelContinuationError(
            "invalid checkpoint input"
        ) from None
    expected_sequence = state["current_step"] - 1
    if (
        state["current_step"] == 0
        or state["current_step"] >= state["total_steps"]
        or source_bank_epoch == 0
        or source_bank_epoch != result["resource_bank_epoch"]
        or restored["restore_bank_epoch"] == 0
        or restored["restore_bank_epoch"] == source_bank_epoch
        or any(value == 0 for value in restored.values())
        or model_publication["request_epoch"] != state["request_epoch"]
        or model_publication["next_sequence"] != state["current_step"]
        or model_publication["visible_results"] != state["current_step"]
        or result["request_epoch"] != state["request_epoch"]
        or result["generation"] != state["current_step"]
        or result["publication_sequence"] != expected_sequence
        or model_publication["artifact_sha256"]
        != state["artifact_sha256"]
        or result["artifact_sha256"] != state["artifact_sha256"]
        or model_publication["previous_result_sha256"]
        != result["result_sha256"]
        or state["previous_result_sha256"] != result["result_sha256"]
        or result["challenge_sha256"] != state["challenge_sha256"]
    ):
        raise StatefulModelContinuationError(
            "invalid checkpoint binding"
        )
    checkpoint: Record = {
        "request_epoch": state["request_epoch"],
        "current_step": state["current_step"],
        "total_steps": state["total_steps"],
        "state_bytes": state["state_bytes"],
        "source_bank_epoch": source_bank_epoch,
        **restored,
        "publication_next_sequence": model_publication["next_sequence"],
        "visible_results": model_publication["visible_results"],
        "artifact_sha256": state["artifact_sha256"],
        "model_publication_sha256": model_root,
        "state_publication_sha256": state["publication_sha256"],
        "previous_result_sha256": result["result_sha256"],
        "last_plan_sha256": result["plan_sha256"],
        "last_output_sha256": result["output_sha256"],
        "current_state_sha256": state["current_state_sha256"],
        "challenge_sha256": state["challenge_sha256"],
    }
    checkpoint["checkpoint_sha256"] = checkpoint_root(checkpoint)
    return validate_checkpoint(checkpoint)


def encode_checkpoint(value: Record) -> bytes:
    checkpoint = validate_checkpoint(value)
    return _body(checkpoint) + checkpoint["checkpoint_sha256"]


def decode_checkpoint(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != CHECKPOINT_BYTES
        or encoded[:8] != CHECKPOINT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != CHECKPOINT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != CHECKPOINT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[152:160])
        or any(encoded[416:CHECKPOINT_BODY_BYTES])
    ):
        raise StatefulModelContinuationError("invalid checkpoint wire")
    checkpoint: Record = {
        field: struct.unpack_from("<Q", encoded, 32 + index * 8)[0]
        for index, field in enumerate(SCALAR_FIELDS)
    }
    checkpoint.update(
        {
            field: encoded[160 + index * 32 : 192 + index * 32]
            for index, field in enumerate(DIGEST_FIELDS)
        }
    )
    checkpoint["checkpoint_sha256"] = encoded[CHECKPOINT_BODY_BYTES:]
    checkpoint = validate_checkpoint(checkpoint)
    if encode_checkpoint(checkpoint) != encoded:
        raise StatefulModelContinuationError(
            "non-canonical checkpoint wire"
        )
    return checkpoint


def reconstruct_model_publication(
    checkpoint_value: Record,
    state_publication_value: Record,
) -> Record:
    checkpoint = validate_checkpoint(checkpoint_value)
    state = stateful.validate_publication(state_publication_value)
    if (
        state["request_epoch"] != checkpoint["request_epoch"]
        or state["current_step"] != checkpoint["current_step"]
        or state["total_steps"] != checkpoint["total_steps"]
        or state["state_bytes"] != checkpoint["state_bytes"]
        or state["artifact_sha256"] != checkpoint["artifact_sha256"]
        or state["publication_sha256"]
        != checkpoint["state_publication_sha256"]
        or state["previous_result_sha256"]
        != checkpoint["previous_result_sha256"]
        or state["current_state_sha256"]
        != checkpoint["current_state_sha256"]
        or state["challenge_sha256"] != checkpoint["challenge_sha256"]
    ):
        raise StatefulModelContinuationError(
            "state does not match checkpoint"
        )
    publication: Record = {
        "request_epoch": checkpoint["request_epoch"],
        "next_sequence": checkpoint["publication_next_sequence"],
        "visible_results": checkpoint["visible_results"],
        "artifact_sha256": checkpoint["artifact_sha256"],
        "previous_result_sha256": checkpoint["previous_result_sha256"],
    }
    if (
        model.publication_state_root(publication)
        != checkpoint["model_publication_sha256"]
    ):
        raise StatefulModelContinuationError(
            "model publication root mismatch"
        )
    return publication
