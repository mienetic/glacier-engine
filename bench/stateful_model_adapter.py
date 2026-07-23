"""Independent oracle for stateful model publication and transition roots."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import model_contract as model

Record = dict[str, Any]
STATE_PUBLICATION_ABI = 0x4753545000000001
STATE_PUBLICATION_BYTES = 320
STATE_BODY_BYTES = STATE_PUBLICATION_BYTES - 32
STATE_MAGIC = b"GSTATE1\x00"
STATE_DOMAIN = b"glacier-stateful-model-publication-v1\x00"
TRANSITION_DOMAIN = b"glacier-stateful-model-transition-v1\x00"
ADAPTER_DOMAIN = b"glacier-stateless-model-adapter-v1\x00"
ZERO_DIGEST = bytes(32)


class StatefulModelAdapterError(ValueError):
    """State publication or transition evidence is invalid."""


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= model.U64_MAX:
        raise StatefulModelAdapterError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise StatefulModelAdapterError("invalid digest")
    return value


def _state_body(value: Record) -> bytes:
    try:
        scalars = tuple(
            value[field]
            for field in (
                "request_epoch",
                "current_step",
                "total_steps",
                "state_bytes",
            )
        )
        artifact = _digest(value["artifact_sha256"])
        current = _digest(value["current_state_sha256"])
        previous = _digest(
            value["previous_result_sha256"],
            allow_zero=True,
        )
        challenge = _digest(value["challenge_sha256"])
    except (KeyError, TypeError):
        raise StatefulModelAdapterError(
            "invalid state publication"
        ) from None
    output = bytearray(STATE_BODY_BYTES)
    output[:64] = b"".join(
        (
            STATE_MAGIC,
            _u64(STATE_PUBLICATION_ABI),
            _u64(STATE_PUBLICATION_BYTES),
            _u64(0),
            *(_u64(item) for item in scalars),
        )
    )
    output[64:192] = artifact + current + previous + challenge
    return bytes(output)


def publication_root(value: Record) -> bytes:
    return hashlib.sha256(STATE_DOMAIN + _state_body(value)).digest()


def validate_publication(value: Record) -> Record:
    fields = (
        "request_epoch",
        "current_step",
        "total_steps",
        "state_bytes",
        "artifact_sha256",
        "current_state_sha256",
        "previous_result_sha256",
        "challenge_sha256",
        "publication_sha256",
    )
    try:
        state = {field: value[field] for field in fields}
        for field in fields[:4]:
            _u64(state[field])
        for field in fields[4:]:
            _digest(
                state[field],
                allow_zero=field == "previous_result_sha256",
            )
    except (KeyError, TypeError):
        raise StatefulModelAdapterError(
            "invalid state publication"
        ) from None
    if (
        state["request_epoch"] == 0
        or state["total_steps"] == 0
        or state["current_step"] > state["total_steps"]
        or state["state_bytes"] == 0
        or (
            state["current_step"] == 0
            and state["previous_result_sha256"] != ZERO_DIGEST
        )
        or (
            state["current_step"] != 0
            and state["previous_result_sha256"] == ZERO_DIGEST
        )
        or state["publication_sha256"] != publication_root(state)
    ):
        raise StatefulModelAdapterError("invalid state publication")
    return state


def initialize_publication(
    *,
    request_epoch: int,
    total_steps: int,
    state_bytes: int,
    artifact_sha256: bytes,
    current_state_sha256: bytes,
    challenge_sha256: bytes,
) -> Record:
    state: Record = {
        "request_epoch": request_epoch,
        "current_step": 0,
        "total_steps": total_steps,
        "state_bytes": state_bytes,
        "artifact_sha256": artifact_sha256,
        "current_state_sha256": current_state_sha256,
        "previous_result_sha256": ZERO_DIGEST,
        "challenge_sha256": challenge_sha256,
    }
    state["publication_sha256"] = publication_root(state)
    return validate_publication(state)


def encode_publication(value: Record) -> bytes:
    state = validate_publication(value)
    return _state_body(state) + state["publication_sha256"]


def decode_publication(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != STATE_PUBLICATION_BYTES
        or encoded[:8] != STATE_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0]
        != STATE_PUBLICATION_ABI
        or struct.unpack_from("<Q", encoded, 16)[0]
        != STATE_PUBLICATION_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[192:STATE_BODY_BYTES])
    ):
        raise StatefulModelAdapterError("invalid state wire")
    state: Record = {
        "request_epoch": struct.unpack_from("<Q", encoded, 32)[0],
        "current_step": struct.unpack_from("<Q", encoded, 40)[0],
        "total_steps": struct.unpack_from("<Q", encoded, 48)[0],
        "state_bytes": struct.unpack_from("<Q", encoded, 56)[0],
        "artifact_sha256": encoded[64:96],
        "current_state_sha256": encoded[96:128],
        "previous_result_sha256": encoded[128:160],
        "challenge_sha256": encoded[160:192],
        "publication_sha256": encoded[STATE_BODY_BYTES:],
    }
    state = validate_publication(state)
    if encode_publication(state) != encoded:
        raise StatefulModelAdapterError("non-canonical state wire")
    return state


def adapter_descriptor_root(
    *,
    adapter_abi: int,
    family: int,
    operation: int,
    input_kind: int,
    output_kind: int,
    numerical_policy: int,
    max_batch_items: int,
    max_input_features: int,
    max_output_dimensions: int,
    allowed_capabilities: int,
    implementation_sha256: bytes,
) -> bytes:
    values = (
        adapter_abi,
        family,
        operation,
        input_kind,
        output_kind,
        numerical_policy,
        max_batch_items,
        max_input_features,
        max_output_dimensions,
        allowed_capabilities,
    )
    return hashlib.sha256(
        ADAPTER_DOMAIN
        + b"".join(_u64(value) for value in values)
        + _digest(implementation_sha256)
    ).digest()


def transition_root(
    state_before: Record,
    plan: Record,
    output_sha256: bytes,
    next_state_sha256: bytes,
    adapter_sha256: bytes,
) -> bytes:
    state = validate_publication(state_before)
    try:
        model.decode_plan(model.encode_plan(plan))
        next_step = state["current_step"] + 1
        _u64(next_step)
        if (
            next_step != plan["generation"]
            or plan["request_epoch"] != state["request_epoch"]
            or plan["artifact_sha256"] != state["artifact_sha256"]
            or plan["challenge_sha256"] != state["challenge_sha256"]
        ):
            raise StatefulModelAdapterError("invalid state transition")
        body = b"".join(
            (
                state["publication_sha256"],
                _digest(plan["plan_sha256"]),
                _digest(output_sha256),
                _digest(next_state_sha256),
                _digest(adapter_sha256),
                state["challenge_sha256"],
                _u64(next_step),
            )
        )
    except (KeyError, TypeError, model.ModelContractError):
        raise StatefulModelAdapterError(
            "invalid state transition"
        ) from None
    return hashlib.sha256(TRANSITION_DOMAIN + body).digest()


def reference_latent_step(
    current_state: bytes,
    conditioning: bytes,
    scalar_weight: bytes,
) -> bytes:
    if (
        not isinstance(current_state, bytes)
        or not isinstance(conditioning, bytes)
        or len(current_state) != len(conditioning)
        or not isinstance(scalar_weight, bytes)
        or len(scalar_weight) != 1
    ):
        raise StatefulModelAdapterError("invalid latent step")
    candidate = bytearray()
    for current, condition in zip(current_state, conditioning):
        delta = condition * scalar_weight[0]
        if delta > current:
            raise StatefulModelAdapterError("invalid latent step")
        candidate.append(current - delta)
    return bytes(candidate)
