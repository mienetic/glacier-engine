"""Independent ActionOutbox adapter-contract and fake-authority model.

This module mirrors the portable V1 values in
``src/core/tool_action_outbox_adapter_contract.zig`` using only Python's
standard library.  The existing ActionOutbox oracle is used only to construct
and validate prior-layer headers, records, identities, and states.

Portable builders in this module never accept credentials.  ``RuntimeAdapter``
owns a separate process-local ``RuntimeCredential`` and is deliberately not a
portable value.  ``FakeAuthority`` is a bounded, deterministic, same-process
model.  It provides no network, filesystem, sandbox, cryptographic-origin, or
external exactly-once claim.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import dataclass
from functools import wraps
import hashlib
import hmac
import json
from pathlib import Path
import struct
import subprocess
import sys
from threading import RLock
from typing import Any, Mapping, Sequence

from bench import action_outbox_conformance as outbox
from bench import typed_tool_conformance as tool


class ActionOutboxAdapterError(ValueError):
    """A portable adapter value, binding, or transition is invalid."""


class AdapterCallbackError(ActionOutboxAdapterError):
    """A process-local fake-authority callback failed."""


class AuthorityUnavailable(AdapterCallbackError):
    """The fake authority cannot currently classify the request."""


class CapacityExceeded(AdapterCallbackError):
    """The bounded fake authority has no free stable-request slot."""


class CredentialRejected(AdapterCallbackError):
    """The runtime-only credential was rejected without portable evidence."""


class RequestRejected(AdapterCallbackError):
    """The fake authority rejected an invalid or conflicting request."""


Digest = bytes
Record = dict[str, Any]

U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)

DESCRIPTOR_ABI = 0x4754_4144_0000_0001
DISPATCH_REQUEST_ABI = 0x4754_4451_0000_0001
DISPATCH_EVIDENCE_ABI = 0x4754_4445_0000_0001
STATUS_REQUEST_ABI = 0x4754_5351_0000_0001
STATUS_EVIDENCE_ABI = 0x4754_5345_0000_0001
REFERENCE_REPORT_ABI = 0x4754_4152_0000_0001

CAPABILITY_STABLE_IDEMPOTENCY = 1 << 0
CAPABILITY_AUTHORITATIVE_STATUS = 1 << 1
CAPABILITY_GENERATION_FENCE = 1 << 2
CAPABILITY_EXACT_TERMINAL_REPLAY = 1 << 3
REQUIRED_CAPABILITIES = (
    CAPABILITY_STABLE_IDEMPOTENCY
    | CAPABILITY_AUTHORITATIVE_STATUS
    | CAPABILITY_GENERATION_FENCE
    | CAPABILITY_EXACT_TERMINAL_REPLAY
)
ALLOWED_CAPABILITIES = REQUIRED_CAPABILITIES

DESCRIPTOR_DOMAIN = b"glacier-action-outbox-adapter-descriptor-v1\x00"
DISPATCH_REQUEST_DOMAIN = b"glacier-action-outbox-adapter-dispatch-request-v1\x00"
DISPATCH_EVIDENCE_DOMAIN = b"glacier-action-outbox-adapter-dispatch-evidence-v1\x00"
STATUS_REQUEST_DOMAIN = b"glacier-action-outbox-adapter-status-request-v1\x00"
STATUS_EVIDENCE_DOMAIN = b"glacier-action-outbox-adapter-status-evidence-v1\x00"
REFERENCE_REPORT_DOMAIN = b"glacier-action-outbox-adapter-reference-report-v1\x00"
REFERENCE_SCHEMA = "glacier.action-outbox-adapter-reference/v1"
MAXIMUM_RUNNER_STDOUT_BYTES = 4096

DISPATCH_SUCCEEDED = 1
DISPATCH_TERMINAL_FAILURE = 2
DISPATCH_INDETERMINATE = 3
DISPATCH_REJECTED_STALE_GENERATION = 4
DISPATCH_DISPOSITIONS = frozenset(
    {
        DISPATCH_SUCCEEDED,
        DISPATCH_TERMINAL_FAILURE,
        DISPATCH_INDETERMINATE,
        DISPATCH_REJECTED_STALE_GENERATION,
    }
)
DISPATCH_DISPOSITION_NAMES = {
    DISPATCH_SUCCEEDED: "succeeded",
    DISPATCH_TERMINAL_FAILURE: "terminal_failure",
    DISPATCH_INDETERMINATE: "indeterminate",
    DISPATCH_REJECTED_STALE_GENERATION: "rejected_stale_generation",
}

STATUS_PENDING = 1
STATUS_UNKNOWN = 2
STATUS_NOT_APPLIED_FENCED = 3
STATUS_SUCCEEDED = 4
STATUS_FAILED = 5
STATUS_DISPOSITIONS = frozenset(
    {
        STATUS_PENDING,
        STATUS_UNKNOWN,
        STATUS_NOT_APPLIED_FENCED,
        STATUS_SUCCEEDED,
        STATUS_FAILED,
    }
)
STATUS_DISPOSITION_NAMES = {
    STATUS_PENDING: "pending",
    STATUS_UNKNOWN: "unknown",
    STATUS_NOT_APPLIED_FENCED: "not_applied_fenced",
    STATUS_SUCCEEDED: "succeeded",
    STATUS_FAILED: "failed",
}

DESCRIPTOR_FIELDS = (
    "abi_version",
    "adapter_abi",
    "authority_epoch",
    "capability_bits",
    "authority_namespace_sha256",
    "request_schema_sha256",
    "result_schema_sha256",
    "descriptor_sha256",
)
DISPATCH_REQUEST_FIELDS = (
    "abi_version",
    "header_sha256",
    "adapter_descriptor_sha256",
    "action_sha256",
    "stable_remote_request_sha256",
    "idempotency_key_sha256",
    "dispatch_request_sha256",
    "attempt_generation",
    "intent_record_sha256",
    "payload_locator_sha256",
    "payload_bytes",
    "payload_sha256",
    "request_sha256",
)
DISPATCH_EVIDENCE_FIELDS = (
    "abi_version",
    "request_sha256",
    "adapter_descriptor_sha256",
    "authority_epoch",
    "authority_revision",
    "disposition",
    "service_event_sha256",
    "result_sha256",
    "evidence_sha256",
)
STATUS_REQUEST_FIELDS = (
    "abi_version",
    "header_sha256",
    "adapter_descriptor_sha256",
    "action_sha256",
    "stable_remote_request_sha256",
    "idempotency_key_sha256",
    "dispatch_request_sha256",
    "attempt_generation",
    "current_action_event_sha256",
    "query_ordinal",
    "request_sha256",
)
STATUS_EVIDENCE_FIELDS = (
    "abi_version",
    "request_sha256",
    "adapter_descriptor_sha256",
    "authority_epoch",
    "authority_revision",
    "disposition",
    "fence_through_generation",
    "service_event_sha256",
    "result_sha256",
    "evidence_sha256",
)
TRANSITION_FIELDS = (
    "kind",
    "attempt_generation",
    "observation_sha256",
    "result_sha256",
)
REFERENCE_REPORT_FIELDS = (
    "abi_version",
    "descriptor_sha256",
    "header_sha256",
    "action_sha256",
    "stable_remote_request_sha256",
    "intent_record_sha256",
    "outbox_dispatch_request_sha256",
    "adapter_dispatch_request_sha256",
    "status_request_sha256",
    "dispatch_evidence_sha256",
    "status_evidence_sha256",
    "report_sha256",
)
REFERENCE_JSON_FIELDS = (
    "schema",
    "reference_report_abi",
    "descriptor_abi",
    "dispatch_request_abi",
    "dispatch_evidence_abi",
    "status_request_abi",
    "status_evidence_abi",
    "descriptor_sha256",
    "header_sha256",
    "action_sha256",
    "stable_remote_request_sha256",
    "intent_record_sha256",
    "outbox_dispatch_request_sha256",
    "adapter_dispatch_request_sha256",
    "status_request_sha256",
    "dispatch_evidence_sha256",
    "status_evidence_sha256",
    "report_sha256",
)

_FAKE_EVENT_DOMAIN = b"glacier-action-outbox-fake-authority-event-v1\x00"
_FAKE_RESULT_DOMAIN = b"glacier-action-outbox-fake-authority-result-v1\x00"


def _strict_record(
    value: Any,
    fields: Sequence[str],
    where: str,
) -> Record:
    if not isinstance(value, dict) or tuple(value) != tuple(fields):
        raise ActionOutboxAdapterError(f"{where} has noncanonical fields")
    return value


def _u8(value: Any, where: str) -> int:
    if type(value) is not int or not 0 <= value <= 0xFF:
        raise ActionOutboxAdapterError(f"{where} is not a u8")
    return value


def _u64(value: Any, where: str) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise ActionOutboxAdapterError(f"{where} is not a u64")
    return value


def _le_u8(value: int) -> bytes:
    return bytes((_u8(value, "u8"),))


def _le_u64(value: int) -> bytes:
    return struct.pack("<Q", _u64(value, "u64"))


def _digest(
    value: Any,
    where: str,
    *,
    allow_zero: bool = False,
) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise ActionOutboxAdapterError(f"{where} is not a digest")
    if not allow_zero and hmac.compare_digest(value, ZERO_DIGEST):
        raise ActionOutboxAdapterError(f"{where} is zero")
    return value


def _enum(value: Any, allowed: frozenset[int], where: str) -> int:
    result = _u8(value, where)
    if result not in allowed:
        raise ActionOutboxAdapterError(f"{where} is invalid")
    return result


def _sha(domain: bytes, *parts: bytes) -> Digest:
    if type(domain) is not bytes or not domain.endswith(b"\x00"):
        raise ActionOutboxAdapterError("invalid hash domain")
    result = hashlib.sha256()
    result.update(domain)
    for part in parts:
        if type(part) is not bytes:
            raise ActionOutboxAdapterError("hash input is not bytes")
        result.update(part)
    return result.digest()


def _label(value: str) -> Digest:
    return hashlib.sha256(value.encode("utf-8")).digest()


def descriptor_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        DESCRIPTOR_DOMAIN,
        _le_u64(value["abi_version"]),
        _le_u64(value["adapter_abi"]),
        _le_u64(value["authority_epoch"]),
        _le_u64(value["capability_bits"]),
        _digest(value["authority_namespace_sha256"], "authority namespace"),
        _digest(value["request_schema_sha256"], "request schema"),
        _digest(value["result_schema_sha256"], "result schema"),
    )


def make_descriptor(
    adapter_abi: int,
    authority_epoch: int,
    authority_namespace_sha256: Digest,
    request_schema_sha256: Digest,
    result_schema_sha256: Digest,
) -> Record:
    result: Record = {
        "abi_version": DESCRIPTOR_ABI,
        "adapter_abi": adapter_abi,
        "authority_epoch": authority_epoch,
        "capability_bits": REQUIRED_CAPABILITIES,
        "authority_namespace_sha256": authority_namespace_sha256,
        "request_schema_sha256": request_schema_sha256,
        "result_schema_sha256": result_schema_sha256,
        "descriptor_sha256": ZERO_DIGEST,
    }
    result["descriptor_sha256"] = descriptor_sha256(result)
    return validate_descriptor(result)


def validate_descriptor(value: Any) -> Record:
    result = _strict_record(value, DESCRIPTOR_FIELDS, "adapter descriptor")
    for name in (
        "abi_version",
        "adapter_abi",
        "authority_epoch",
        "capability_bits",
    ):
        _u64(result[name], f"descriptor {name}")
    for name in DESCRIPTOR_FIELDS[4:]:
        _digest(result[name], f"descriptor {name}")
    if (
        result["abi_version"] != DESCRIPTOR_ABI
        or result["adapter_abi"] == 0
        or result["authority_epoch"] == 0
        or result["capability_bits"] != REQUIRED_CAPABILITIES
        or not hmac.compare_digest(
            result["descriptor_sha256"],
            descriptor_sha256(result),
        )
    ):
        raise ActionOutboxAdapterError("invalid adapter descriptor")
    return deepcopy(result)


def validate_descriptor_header_binding(
    descriptor_value: Any,
    header_value: Any,
) -> tuple[Record, Record]:
    descriptor = validate_descriptor(descriptor_value)
    header = outbox.validate_header(header_value)
    if not hmac.compare_digest(
        descriptor["descriptor_sha256"],
        header["adapter_descriptor_sha256"],
    ):
        raise ActionOutboxAdapterError("adapter descriptor is not header-pinned")
    return descriptor, header


def dispatch_request_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        DISPATCH_REQUEST_DOMAIN,
        _le_u64(value["abi_version"]),
        _digest(value["header_sha256"], "dispatch header"),
        _digest(value["adapter_descriptor_sha256"], "dispatch adapter"),
        _digest(value["action_sha256"], "dispatch action"),
        _digest(value["stable_remote_request_sha256"], "stable request"),
        _digest(value["idempotency_key_sha256"], "idempotency key"),
        _digest(value["dispatch_request_sha256"], "dispatch request"),
        _le_u64(value["attempt_generation"]),
        _digest(value["intent_record_sha256"], "intent record"),
        _digest(value["payload_locator_sha256"], "payload locator"),
        _le_u64(value["payload_bytes"]),
        _digest(value["payload_sha256"], "payload"),
    )


def make_dispatch_request(
    descriptor_value: Any,
    header_value: Any,
    intent_value: Any,
) -> Record:
    descriptor, header = validate_descriptor_header_binding(
        descriptor_value,
        header_value,
    )
    intent = outbox.validate_record(header, intent_value)
    if intent["kind"] != outbox.EVENT_DISPATCH_INTENT:
        raise ActionOutboxAdapterError("dispatch request requires an intent")
    identity = intent["identity"]
    result: Record = {
        "abi_version": DISPATCH_REQUEST_ABI,
        "header_sha256": header["header_sha256"],
        "adapter_descriptor_sha256": descriptor["descriptor_sha256"],
        "action_sha256": identity["action_sha256"],
        "stable_remote_request_sha256": identity["stable_remote_request_sha256"],
        "idempotency_key_sha256": identity["idempotency_key_sha256"],
        "dispatch_request_sha256": intent["dispatch_request_sha256"],
        "attempt_generation": intent["attempt_generation"],
        "intent_record_sha256": intent["record_sha256"],
        "payload_locator_sha256": identity["payload_locator_sha256"],
        "payload_bytes": identity["payload_bytes"],
        "payload_sha256": identity["payload_sha256"],
        "request_sha256": ZERO_DIGEST,
    }
    result["request_sha256"] = dispatch_request_sha256(result)
    validate_dispatch_request_composition(descriptor, header, intent, result)
    return deepcopy(result)


def validate_dispatch_request(value: Any) -> Record:
    result = _strict_record(
        value,
        DISPATCH_REQUEST_FIELDS,
        "dispatch request",
    )
    _u64(result["abi_version"], "dispatch request ABI")
    _u64(result["attempt_generation"], "dispatch attempt generation")
    _u64(result["payload_bytes"], "dispatch payload bytes")
    for name in DISPATCH_REQUEST_FIELDS[1:7]:
        _digest(result[name], f"dispatch request {name}")
    for name in DISPATCH_REQUEST_FIELDS[8:10]:
        _digest(result[name], f"dispatch request {name}")
    _digest(result["payload_sha256"], "dispatch request payload")
    _digest(result["request_sha256"], "dispatch request root")
    if (
        result["abi_version"] != DISPATCH_REQUEST_ABI
        or result["attempt_generation"] == 0
        or result["payload_bytes"] == 0
        or not hmac.compare_digest(
            result["request_sha256"],
            dispatch_request_sha256(result),
        )
    ):
        raise ActionOutboxAdapterError("invalid dispatch request")
    return deepcopy(result)


def validate_dispatch_request_composition(
    descriptor_value: Any,
    header_value: Any,
    intent_value: Any,
    value: Any,
) -> Record:
    descriptor, header = validate_descriptor_header_binding(
        descriptor_value,
        header_value,
    )
    intent = outbox.validate_record(header, intent_value)
    request = validate_dispatch_request(value)
    identity = intent["identity"]
    expected = (
        (request["header_sha256"], header["header_sha256"]),
        (
            request["adapter_descriptor_sha256"],
            descriptor["descriptor_sha256"],
        ),
        (request["action_sha256"], identity["action_sha256"]),
        (
            request["stable_remote_request_sha256"],
            identity["stable_remote_request_sha256"],
        ),
        (
            request["idempotency_key_sha256"],
            identity["idempotency_key_sha256"],
        ),
        (
            request["dispatch_request_sha256"],
            intent["dispatch_request_sha256"],
        ),
        (request["intent_record_sha256"], intent["record_sha256"]),
        (
            request["payload_locator_sha256"],
            identity["payload_locator_sha256"],
        ),
        (request["payload_sha256"], identity["payload_sha256"]),
    )
    if (
        intent["kind"] != outbox.EVENT_DISPATCH_INTENT
        or request["attempt_generation"] != intent["attempt_generation"]
        or request["payload_bytes"] != identity["payload_bytes"]
        or any(not hmac.compare_digest(left, right) for left, right in expected)
    ):
        raise ActionOutboxAdapterError("dispatch request composition mismatch")
    return request


def dispatch_evidence_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        DISPATCH_EVIDENCE_DOMAIN,
        _le_u64(value["abi_version"]),
        _digest(value["request_sha256"], "dispatch evidence request"),
        _digest(value["adapter_descriptor_sha256"], "dispatch evidence adapter"),
        _le_u64(value["authority_epoch"]),
        _le_u64(value["authority_revision"]),
        _le_u8(value["disposition"]),
        _digest(value["service_event_sha256"], "dispatch service event"),
        _digest(
            value["result_sha256"],
            "dispatch result",
            allow_zero=True,
        ),
    )


def make_dispatch_evidence(
    descriptor_value: Any,
    request_value: Any,
    authority_revision: int,
    disposition: int,
    service_event_sha256: Digest,
    result_sha256: Digest,
) -> Record:
    descriptor = validate_descriptor(descriptor_value)
    request = validate_dispatch_request(request_value)
    if not hmac.compare_digest(
        descriptor["descriptor_sha256"],
        request["adapter_descriptor_sha256"],
    ):
        raise ActionOutboxAdapterError("dispatch evidence adapter mismatch")
    result: Record = {
        "abi_version": DISPATCH_EVIDENCE_ABI,
        "request_sha256": request["request_sha256"],
        "adapter_descriptor_sha256": descriptor["descriptor_sha256"],
        "authority_epoch": descriptor["authority_epoch"],
        "authority_revision": authority_revision,
        "disposition": disposition,
        "service_event_sha256": service_event_sha256,
        "result_sha256": result_sha256,
        "evidence_sha256": ZERO_DIGEST,
    }
    result["evidence_sha256"] = dispatch_evidence_sha256(result)
    return validate_dispatch_evidence(descriptor, request, result)


def validate_dispatch_evidence(
    descriptor_value: Any,
    request_value: Any,
    value: Any,
) -> Record:
    descriptor = validate_descriptor(descriptor_value)
    request = validate_dispatch_request(request_value)
    result = _strict_record(
        value,
        DISPATCH_EVIDENCE_FIELDS,
        "dispatch evidence",
    )
    _u64(result["abi_version"], "dispatch evidence ABI")
    _u64(result["authority_epoch"], "dispatch authority epoch")
    _u64(result["authority_revision"], "dispatch authority revision")
    disposition = _enum(
        result["disposition"],
        DISPATCH_DISPOSITIONS,
        "dispatch disposition",
    )
    for name in (
        "request_sha256",
        "adapter_descriptor_sha256",
        "service_event_sha256",
        "evidence_sha256",
    ):
        _digest(result[name], f"dispatch evidence {name}")
    output = _digest(
        result["result_sha256"],
        "dispatch evidence result",
        allow_zero=True,
    )
    terminal = disposition in {
        DISPATCH_SUCCEEDED,
        DISPATCH_TERMINAL_FAILURE,
    }
    if (
        result["abi_version"] != DISPATCH_EVIDENCE_ABI
        or result["authority_epoch"] != descriptor["authority_epoch"]
        or result["authority_revision"] == 0
        or terminal == hmac.compare_digest(output, ZERO_DIGEST)
        or not hmac.compare_digest(
            result["request_sha256"],
            request["request_sha256"],
        )
        or not hmac.compare_digest(
            request["adapter_descriptor_sha256"],
            descriptor["descriptor_sha256"],
        )
        or not hmac.compare_digest(
            result["adapter_descriptor_sha256"],
            descriptor["descriptor_sha256"],
        )
        or not hmac.compare_digest(
            result["evidence_sha256"],
            dispatch_evidence_sha256(result),
        )
    ):
        raise ActionOutboxAdapterError("invalid dispatch evidence")
    return deepcopy(result)


def status_request_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        STATUS_REQUEST_DOMAIN,
        _le_u64(value["abi_version"]),
        _digest(value["header_sha256"], "status header"),
        _digest(value["adapter_descriptor_sha256"], "status adapter"),
        _digest(value["action_sha256"], "status action"),
        _digest(value["stable_remote_request_sha256"], "stable request"),
        _digest(value["idempotency_key_sha256"], "idempotency key"),
        _digest(value["dispatch_request_sha256"], "dispatch request"),
        _le_u64(value["attempt_generation"]),
        _digest(value["current_action_event_sha256"], "current action event"),
        _le_u64(value["query_ordinal"]),
    )


def _require_uncertain_state(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ActionOutboxAdapterError("status state is not a mapping")
    required = {
        "occupied",
        "phase",
        "attempt_generation",
        "identity",
        "dispatch_request_sha256",
        "last_event_sha256",
    }
    if not required.issubset(value):
        raise ActionOutboxAdapterError("status state is incomplete")
    if (
        value["occupied"] is not True
        or value["phase"] != outbox.PHASE_UNCERTAIN
        or _u64(value["attempt_generation"], "state attempt generation") == 0
    ):
        raise ActionOutboxAdapterError("status requires uncertain state")
    return value


def make_status_request(
    descriptor_value: Any,
    header_value: Any,
    state_value: Any,
    query_ordinal: int,
) -> Record:
    descriptor, header = validate_descriptor_header_binding(
        descriptor_value,
        header_value,
    )
    state = _require_uncertain_state(state_value)
    if _u64(query_ordinal, "query ordinal") == 0:
        raise ActionOutboxAdapterError("status query ordinal is zero")
    identity = state["identity"]
    result: Record = {
        "abi_version": STATUS_REQUEST_ABI,
        "header_sha256": header["header_sha256"],
        "adapter_descriptor_sha256": descriptor["descriptor_sha256"],
        "action_sha256": identity["action_sha256"],
        "stable_remote_request_sha256": identity["stable_remote_request_sha256"],
        "idempotency_key_sha256": identity["idempotency_key_sha256"],
        "dispatch_request_sha256": state["dispatch_request_sha256"],
        "attempt_generation": state["attempt_generation"],
        "current_action_event_sha256": state["last_event_sha256"],
        "query_ordinal": query_ordinal,
        "request_sha256": ZERO_DIGEST,
    }
    result["request_sha256"] = status_request_sha256(result)
    validate_status_request_composition(descriptor, header, state, result)
    return deepcopy(result)


def validate_status_request(value: Any) -> Record:
    result = _strict_record(value, STATUS_REQUEST_FIELDS, "status request")
    _u64(result["abi_version"], "status request ABI")
    _u64(result["attempt_generation"], "status attempt generation")
    _u64(result["query_ordinal"], "status query ordinal")
    for name in STATUS_REQUEST_FIELDS[1:7]:
        _digest(result[name], f"status request {name}")
    _digest(
        result["current_action_event_sha256"],
        "status current action event",
    )
    _digest(result["request_sha256"], "status request root")
    if (
        result["abi_version"] != STATUS_REQUEST_ABI
        or result["attempt_generation"] == 0
        or result["query_ordinal"] == 0
        or not hmac.compare_digest(
            result["request_sha256"],
            status_request_sha256(result),
        )
    ):
        raise ActionOutboxAdapterError("invalid status request")
    return deepcopy(result)


def validate_status_request_composition(
    descriptor_value: Any,
    header_value: Any,
    state_value: Any,
    value: Any,
) -> Record:
    descriptor, header = validate_descriptor_header_binding(
        descriptor_value,
        header_value,
    )
    state = _require_uncertain_state(state_value)
    request = validate_status_request(value)
    identity = state["identity"]
    expected = (
        (request["header_sha256"], header["header_sha256"]),
        (
            request["adapter_descriptor_sha256"],
            descriptor["descriptor_sha256"],
        ),
        (request["action_sha256"], identity["action_sha256"]),
        (
            request["stable_remote_request_sha256"],
            identity["stable_remote_request_sha256"],
        ),
        (
            request["idempotency_key_sha256"],
            identity["idempotency_key_sha256"],
        ),
        (
            request["dispatch_request_sha256"],
            state["dispatch_request_sha256"],
        ),
        (
            request["current_action_event_sha256"],
            state["last_event_sha256"],
        ),
    )
    if request["attempt_generation"] != state["attempt_generation"] or any(
        not hmac.compare_digest(left, right) for left, right in expected
    ):
        raise ActionOutboxAdapterError("status request composition mismatch")
    return request


def status_evidence_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        STATUS_EVIDENCE_DOMAIN,
        _le_u64(value["abi_version"]),
        _digest(value["request_sha256"], "status evidence request"),
        _digest(value["adapter_descriptor_sha256"], "status evidence adapter"),
        _le_u64(value["authority_epoch"]),
        _le_u64(value["authority_revision"]),
        _le_u8(value["disposition"]),
        _le_u64(value["fence_through_generation"]),
        _digest(value["service_event_sha256"], "status service event"),
        _digest(
            value["result_sha256"],
            "status result",
            allow_zero=True,
        ),
    )


def make_status_evidence(
    descriptor_value: Any,
    request_value: Any,
    authority_revision: int,
    disposition: int,
    fence_through_generation: int,
    service_event_sha256: Digest,
    result_sha256: Digest,
) -> Record:
    descriptor = validate_descriptor(descriptor_value)
    request = validate_status_request(request_value)
    if not hmac.compare_digest(
        descriptor["descriptor_sha256"],
        request["adapter_descriptor_sha256"],
    ):
        raise ActionOutboxAdapterError("status evidence adapter mismatch")
    result: Record = {
        "abi_version": STATUS_EVIDENCE_ABI,
        "request_sha256": request["request_sha256"],
        "adapter_descriptor_sha256": descriptor["descriptor_sha256"],
        "authority_epoch": descriptor["authority_epoch"],
        "authority_revision": authority_revision,
        "disposition": disposition,
        "fence_through_generation": fence_through_generation,
        "service_event_sha256": service_event_sha256,
        "result_sha256": result_sha256,
        "evidence_sha256": ZERO_DIGEST,
    }
    result["evidence_sha256"] = status_evidence_sha256(result)
    return validate_status_evidence(descriptor, request, result)


def validate_status_evidence(
    descriptor_value: Any,
    request_value: Any,
    value: Any,
) -> Record:
    descriptor = validate_descriptor(descriptor_value)
    request = validate_status_request(request_value)
    result = _strict_record(
        value,
        STATUS_EVIDENCE_FIELDS,
        "status evidence",
    )
    _u64(result["abi_version"], "status evidence ABI")
    _u64(result["authority_epoch"], "status authority epoch")
    _u64(result["authority_revision"], "status authority revision")
    disposition = _enum(
        result["disposition"],
        STATUS_DISPOSITIONS,
        "status disposition",
    )
    fence = _u64(
        result["fence_through_generation"],
        "status fence generation",
    )
    for name in (
        "request_sha256",
        "adapter_descriptor_sha256",
        "service_event_sha256",
        "evidence_sha256",
    ):
        _digest(result[name], f"status evidence {name}")
    output = _digest(
        result["result_sha256"],
        "status evidence result",
        allow_zero=True,
    )
    terminal = disposition in {STATUS_SUCCEEDED, STATUS_FAILED}
    fenced = disposition == STATUS_NOT_APPLIED_FENCED
    if (
        result["abi_version"] != STATUS_EVIDENCE_ABI
        or result["authority_epoch"] != descriptor["authority_epoch"]
        or result["authority_revision"] == 0
        or terminal == hmac.compare_digest(output, ZERO_DIGEST)
        or (fenced and fence != request["attempt_generation"])
        or (not fenced and fence != 0)
        or not hmac.compare_digest(
            result["request_sha256"],
            request["request_sha256"],
        )
        or not hmac.compare_digest(
            request["adapter_descriptor_sha256"],
            descriptor["descriptor_sha256"],
        )
        or not hmac.compare_digest(
            result["adapter_descriptor_sha256"],
            descriptor["descriptor_sha256"],
        )
        or not hmac.compare_digest(
            result["evidence_sha256"],
            status_evidence_sha256(result),
        )
    ):
        raise ActionOutboxAdapterError("invalid status evidence")
    return deepcopy(result)


def transition_from_dispatch(
    descriptor_value: Any,
    request_value: Any,
    evidence_value: Any,
) -> Record:
    request = validate_dispatch_request(request_value)
    evidence = validate_dispatch_evidence(
        descriptor_value,
        request,
        evidence_value,
    )
    if evidence["disposition"] == DISPATCH_SUCCEEDED:
        kind = outbox.EVENT_ACKNOWLEDGED_SUCCESS
    elif evidence["disposition"] == DISPATCH_TERMINAL_FAILURE:
        kind = outbox.EVENT_ACKNOWLEDGED_FAILURE
    else:
        kind = outbox.EVENT_AMBIGUITY_OBSERVED
    return {
        "kind": kind,
        "attempt_generation": request["attempt_generation"],
        "observation_sha256": evidence["evidence_sha256"],
        "result_sha256": evidence["result_sha256"],
    }


def transition_from_status(
    descriptor_value: Any,
    request_value: Any,
    evidence_value: Any,
) -> Record | None:
    request = validate_status_request(request_value)
    evidence = validate_status_evidence(
        descriptor_value,
        request,
        evidence_value,
    )
    disposition = evidence["disposition"]
    if disposition in {STATUS_PENDING, STATUS_UNKNOWN}:
        return None
    if disposition == STATUS_NOT_APPLIED_FENCED:
        kind = outbox.EVENT_RECONCILED_NOT_APPLIED
        result_sha256 = ZERO_DIGEST
    elif disposition == STATUS_SUCCEEDED:
        kind = outbox.EVENT_RECONCILED_SUCCESS
        result_sha256 = evidence["result_sha256"]
    else:
        kind = outbox.EVENT_RECONCILED_FAILURE
        result_sha256 = evidence["result_sha256"]
    return {
        "kind": kind,
        "attempt_generation": request["attempt_generation"],
        "observation_sha256": evidence["evidence_sha256"],
        "result_sha256": result_sha256,
    }


class RuntimeCredential:
    """Runtime-only bearer material; never a portable builder argument."""

    __slots__ = ("_material",)

    def __init__(self, material: bytes) -> None:
        if type(material) is not bytes or not material:
            raise CredentialRejected("credential material is invalid")
        self._material = material

    def matches(self, expected: bytes) -> bool:
        return hmac.compare_digest(self._material, expected)


@dataclass
class _AuthorityEntry:
    header_sha256: Digest
    action_sha256: Digest
    idempotency_key_sha256: Digest
    payload_bound: bool = False
    payload_locator_sha256: Digest = ZERO_DIGEST
    payload_bytes: int = 0
    payload_sha256: Digest = ZERO_DIGEST
    fence_through_generation: int = 0
    fence_revision: int = 0
    fence_event_sha256: Digest = ZERO_DIGEST
    inflight_generation: int = 0
    inflight_revision: int = 0
    inflight_request_sha256: Digest = ZERO_DIGEST
    inflight_event_sha256: Digest = ZERO_DIGEST
    terminal_dispatch_disposition: int = 0
    terminal_generation: int = 0
    terminal_request_sha256: Digest = ZERO_DIGEST
    terminal_revision: int = 0
    terminal_service_event_sha256: Digest = ZERO_DIGEST
    terminal_result_sha256: Digest = ZERO_DIGEST


def _serialized(method: Any) -> Any:
    @wraps(method)
    def locked(self: Any, *args: Any, **kwargs: Any) -> Any:
        with self._lock:
            return method(self, *args, **kwargs)

    return locked


class FakeAuthority:
    """Bounded same-process fake service with an atomic generation fence."""

    def __init__(
        self,
        descriptor_value: Any,
        accepted_credential: bytes,
        *,
        maximum_entries: int = 8,
    ) -> None:
        self.descriptor = validate_descriptor(descriptor_value)
        if type(accepted_credential) is not bytes or not accepted_credential:
            raise CredentialRejected("accepted credential is invalid")
        if type(maximum_entries) is not int or not 0 < maximum_entries <= 64:
            raise CapacityExceeded("invalid fake-authority capacity")
        self._accepted_credential = accepted_credential
        self._maximum_entries = maximum_entries
        self._entries: dict[Digest, _AuthorityEntry] = {}
        self._dispatch_plans: dict[Digest, int] = {}
        self._status_overrides: dict[Digest, int] = {}
        self._revision = 1
        self._lock = RLock()

    @property
    def authority_revision(self) -> int:
        with self._lock:
            return self._revision

    @_serialized
    def fence_for(self, stable_remote_request_sha256: Digest) -> int:
        stable = _digest(stable_remote_request_sha256, "stable request")
        entry = self._entries.get(stable)
        return 0 if entry is None else entry.fence_through_generation

    @_serialized
    def plan_dispatch(
        self,
        stable_remote_request_sha256: Digest,
        disposition: int,
    ) -> None:
        stable = _digest(stable_remote_request_sha256, "stable request")
        selected = _enum(
            disposition,
            DISPATCH_DISPOSITIONS,
            "planned dispatch disposition",
        )
        if selected == DISPATCH_REJECTED_STALE_GENERATION:
            raise RequestRejected("stale rejection is derived from a fence")
        if (
            stable not in self._dispatch_plans
            and len(self._dispatch_plans) >= self._maximum_entries
        ):
            raise CapacityExceeded("dispatch-plan capacity exceeded")
        self._dispatch_plans[stable] = selected

    @_serialized
    def override_status(
        self,
        stable_remote_request_sha256: Digest,
        disposition: int | None,
    ) -> None:
        stable = _digest(stable_remote_request_sha256, "stable request")
        if disposition is None:
            self._status_overrides.pop(stable, None)
            return
        selected = _enum(
            disposition,
            STATUS_DISPOSITIONS,
            "status override",
        )
        if selected not in {STATUS_PENDING, STATUS_UNKNOWN}:
            raise RequestRejected("only pending/unknown may be overridden")
        if (
            stable not in self._status_overrides
            and len(self._status_overrides) >= self._maximum_entries
        ):
            raise CapacityExceeded("status-override capacity exceeded")
        self._status_overrides[stable] = selected

    def _authenticate(self, credential: RuntimeCredential) -> None:
        if not isinstance(credential, RuntimeCredential) or not credential.matches(
            self._accepted_credential
        ):
            raise CredentialRejected("credential rejected")

    def _validate_descriptor_binding(self, request: Mapping[str, Any]) -> None:
        if not hmac.compare_digest(
            request["adapter_descriptor_sha256"],
            self.descriptor["descriptor_sha256"],
        ):
            raise RequestRejected("request targets another authority epoch")

    def _entry(
        self,
        request: Mapping[str, Any],
        *,
        create: bool,
    ) -> _AuthorityEntry | None:
        stable = request["stable_remote_request_sha256"]
        entry = self._entries.get(stable)
        if entry is None:
            for occupied in self._entries.values():
                if hmac.compare_digest(
                    occupied.action_sha256,
                    request["action_sha256"],
                ) or hmac.compare_digest(
                    occupied.idempotency_key_sha256,
                    request["idempotency_key_sha256"],
                ):
                    raise RequestRejected("authority identity conflict")
            if create:
                if len(self._entries) >= self._maximum_entries:
                    raise CapacityExceeded("fake-authority capacity exceeded")
                entry = _AuthorityEntry(
                    header_sha256=request["header_sha256"],
                    action_sha256=request["action_sha256"],
                    idempotency_key_sha256=request["idempotency_key_sha256"],
                )
                if "payload_sha256" in request:
                    entry.payload_bound = True
                    entry.payload_locator_sha256 = request[
                        "payload_locator_sha256"
                    ]
                    entry.payload_bytes = request["payload_bytes"]
                    entry.payload_sha256 = request["payload_sha256"]
                self._entries[stable] = entry
        if entry is not None and (
            not hmac.compare_digest(entry.header_sha256, request["header_sha256"])
            or not hmac.compare_digest(
                entry.action_sha256,
                request["action_sha256"],
            )
            or not hmac.compare_digest(
                entry.idempotency_key_sha256,
                request["idempotency_key_sha256"],
            )
        ):
            raise RequestRejected("stable-request identity conflict")
        if entry is not None and "payload_sha256" in request:
            if entry.payload_bound and (
                not hmac.compare_digest(
                    entry.payload_locator_sha256,
                    request["payload_locator_sha256"],
                )
                or entry.payload_bytes != request["payload_bytes"]
                or not hmac.compare_digest(
                    entry.payload_sha256,
                    request["payload_sha256"],
                )
            ):
                raise RequestRejected("stable-request payload conflict")
        return entry

    @staticmethod
    def _bind_payload(entry: _AuthorityEntry, request: Mapping[str, Any]) -> None:
        if entry.payload_bound:
            return
        entry.payload_bound = True
        entry.payload_locator_sha256 = request["payload_locator_sha256"]
        entry.payload_bytes = request["payload_bytes"]
        entry.payload_sha256 = request["payload_sha256"]

    def _advance(self) -> int:
        if self._revision == U64_MAX:
            raise CapacityExceeded("authority revision overflow")
        self._revision += 1
        return self._revision

    def _event(
        self,
        stable_remote_request_sha256: Digest,
        disposition: int,
        attempt_generation: int,
        revision: int,
    ) -> Digest:
        return _sha(
            _FAKE_EVENT_DOMAIN,
            self.descriptor["descriptor_sha256"],
            stable_remote_request_sha256,
            _le_u8(disposition),
            _le_u64(attempt_generation),
            _le_u64(revision),
        )

    def _result(
        self,
        stable_remote_request_sha256: Digest,
        disposition: int,
    ) -> Digest:
        return _sha(
            _FAKE_RESULT_DOMAIN,
            self.descriptor["descriptor_sha256"],
            stable_remote_request_sha256,
            _le_u8(disposition),
        )

    def _terminal_dispatch_evidence(
        self,
        request: Record,
        entry: _AuthorityEntry,
    ) -> Record:
        return make_dispatch_evidence(
            self.descriptor,
            request,
            entry.terminal_revision,
            entry.terminal_dispatch_disposition,
            entry.terminal_service_event_sha256,
            entry.terminal_result_sha256,
        )

    @_serialized
    def dispatch(
        self,
        request_value: Any,
        credential: RuntimeCredential,
    ) -> Record:
        request = validate_dispatch_request(request_value)
        self._authenticate(credential)
        self._validate_descriptor_binding(request)
        entry = self._entry(request, create=False)
        if (
            entry is not None
            and request["attempt_generation"] <= entry.fence_through_generation
        ):
            revision = entry.fence_revision or self._revision
            event = self._event(
                request["stable_remote_request_sha256"],
                DISPATCH_REJECTED_STALE_GENERATION,
                request["attempt_generation"],
                revision,
            )
            return make_dispatch_evidence(
                self.descriptor,
                request,
                revision,
                DISPATCH_REJECTED_STALE_GENERATION,
                event,
                ZERO_DIGEST,
            )
        if entry is None and request["attempt_generation"] != 1:
            raise RequestRejected("first dispatch generation is not one")
        if (
            entry is not None
            and entry.fence_through_generation != 0
            and entry.terminal_dispatch_disposition == 0
            and entry.inflight_generation == 0
            and request["attempt_generation"] != entry.fence_through_generation + 1
        ):
            raise RequestRejected("dispatch skipped the fenced next generation")
        if entry is not None and entry.terminal_dispatch_disposition != 0:
            if request[
                "attempt_generation"
            ] == entry.terminal_generation and not hmac.compare_digest(
                request["request_sha256"],
                entry.terminal_request_sha256,
            ):
                raise RequestRejected("terminal attempt request was resealed")
            return self._terminal_dispatch_evidence(request, entry)
        if entry is not None and entry.inflight_generation != 0:
            if request[
                "attempt_generation"
            ] != entry.inflight_generation or not hmac.compare_digest(
                request["request_sha256"],
                entry.inflight_request_sha256,
            ):
                raise RequestRejected("dispatch conflicts with inflight attempt")
            return make_dispatch_evidence(
                self.descriptor,
                request,
                entry.inflight_revision,
                DISPATCH_INDETERMINATE,
                entry.inflight_event_sha256,
                ZERO_DIGEST,
            )
        if entry is not None:
            self._bind_payload(entry, request)
        planned = self._dispatch_plans.pop(
            request["stable_remote_request_sha256"],
            DISPATCH_SUCCEEDED,
        )
        if planned == DISPATCH_INDETERMINATE:
            entry = self._entry(request, create=True)
            if entry is None:
                raise AuthorityUnavailable("fake authority entry disappeared")
            self._bind_payload(entry, request)
            revision = self._advance()
            event = self._event(
                request["stable_remote_request_sha256"],
                planned,
                request["attempt_generation"],
                revision,
            )
            entry.inflight_generation = request["attempt_generation"]
            entry.inflight_revision = revision
            entry.inflight_request_sha256 = request["request_sha256"]
            entry.inflight_event_sha256 = event
            return make_dispatch_evidence(
                self.descriptor,
                request,
                revision,
                planned,
                event,
                ZERO_DIGEST,
            )
        entry = self._entry(request, create=True)
        if entry is None:
            raise AuthorityUnavailable("fake authority entry disappeared")
        revision = self._advance()
        entry.terminal_dispatch_disposition = planned
        entry.terminal_generation = request["attempt_generation"]
        entry.terminal_request_sha256 = request["request_sha256"]
        entry.terminal_revision = revision
        entry.terminal_service_event_sha256 = self._event(
            request["stable_remote_request_sha256"],
            planned,
            request["attempt_generation"],
            revision,
        )
        entry.terminal_result_sha256 = self._result(
            request["stable_remote_request_sha256"],
            planned,
        )
        return self._terminal_dispatch_evidence(request, entry)

    @_serialized
    def begin_inflight(
        self,
        request_value: Any,
        credential: RuntimeCredential,
    ) -> None:
        request = validate_dispatch_request(request_value)
        self._authenticate(credential)
        self._validate_descriptor_binding(request)
        entry = self._entry(request, create=False)
        if entry is None:
            if request["attempt_generation"] != 1:
                raise RequestRejected("first inflight generation is not one")
            entry = self._entry(request, create=True)
        elif (
            entry.fence_through_generation == 0 and request["attempt_generation"] != 1
        ) or (
            entry.fence_through_generation != 0
            and request["attempt_generation"] != entry.fence_through_generation + 1
        ):
            raise RequestRejected("inflight dispatch skipped a generation")
        if entry is None:
            raise AuthorityUnavailable("fake authority entry disappeared")
        if (
            request["attempt_generation"] <= entry.fence_through_generation
            or entry.terminal_dispatch_disposition != 0
            or entry.inflight_generation != 0
        ):
            raise RequestRejected("dispatch cannot enter inflight state")
        self._bind_payload(entry, request)
        entry.inflight_generation = request["attempt_generation"]
        entry.inflight_revision = self._advance()
        entry.inflight_request_sha256 = request["request_sha256"]
        entry.inflight_event_sha256 = self._event(
            request["stable_remote_request_sha256"],
            DISPATCH_INDETERMINATE,
            request["attempt_generation"],
            entry.inflight_revision,
        )

    @_serialized
    def finish_inflight(
        self,
        request_value: Any,
        credential: RuntimeCredential,
        disposition: int,
    ) -> Record:
        request = validate_dispatch_request(request_value)
        self._authenticate(credential)
        self._validate_descriptor_binding(request)
        selected = _enum(
            disposition,
            DISPATCH_DISPOSITIONS,
            "inflight disposition",
        )
        if selected not in {
            DISPATCH_SUCCEEDED,
            DISPATCH_TERMINAL_FAILURE,
            DISPATCH_INDETERMINATE,
        }:
            raise RequestRejected("invalid inflight completion")
        entry = self._entry(request, create=False)
        if (
            entry is None
            or entry.inflight_generation != request["attempt_generation"]
            or not hmac.compare_digest(
                entry.inflight_request_sha256,
                request["request_sha256"],
            )
        ):
            raise RequestRejected("dispatch is not the current inflight attempt")
        if selected == DISPATCH_INDETERMINATE:
            revision = self._advance()
            event = self._event(
                request["stable_remote_request_sha256"],
                selected,
                request["attempt_generation"],
                revision,
            )
            entry.inflight_revision = revision
            entry.inflight_event_sha256 = event
            return make_dispatch_evidence(
                self.descriptor,
                request,
                revision,
                selected,
                event,
                ZERO_DIGEST,
            )
        entry.inflight_generation = 0
        entry.inflight_revision = 0
        entry.inflight_request_sha256 = ZERO_DIGEST
        entry.inflight_event_sha256 = ZERO_DIGEST
        revision = self._advance()
        entry.terminal_dispatch_disposition = selected
        entry.terminal_generation = request["attempt_generation"]
        entry.terminal_request_sha256 = request["request_sha256"]
        entry.terminal_revision = revision
        entry.terminal_service_event_sha256 = self._event(
            request["stable_remote_request_sha256"],
            selected,
            request["attempt_generation"],
            revision,
        )
        entry.terminal_result_sha256 = self._result(
            request["stable_remote_request_sha256"],
            selected,
        )
        return self._terminal_dispatch_evidence(request, entry)

    @_serialized
    def status(
        self,
        request_value: Any,
        credential: RuntimeCredential,
    ) -> Record:
        request = validate_status_request(request_value)
        self._authenticate(credential)
        self._validate_descriptor_binding(request)
        stable = request["stable_remote_request_sha256"]
        entry = self._entry(request, create=False)
        override = self._status_overrides.get(stable)
        if override is not None:
            event = self._event(
                stable,
                override,
                request["attempt_generation"],
                self._revision,
            )
            return make_status_evidence(
                self.descriptor,
                request,
                self._revision,
                override,
                0,
                event,
                ZERO_DIGEST,
            )
        if entry is not None and entry.terminal_dispatch_disposition != 0:
            disposition = (
                STATUS_SUCCEEDED
                if entry.terminal_dispatch_disposition == DISPATCH_SUCCEEDED
                else STATUS_FAILED
            )
            return make_status_evidence(
                self.descriptor,
                request,
                entry.terminal_revision,
                disposition,
                0,
                entry.terminal_service_event_sha256,
                entry.terminal_result_sha256,
            )
        if entry is not None and entry.inflight_generation != 0:
            generation = request["attempt_generation"]
            if generation <= entry.fence_through_generation:
                revision = entry.fence_revision or self._revision
                return make_status_evidence(
                    self.descriptor,
                    request,
                    revision,
                    STATUS_NOT_APPLIED_FENCED,
                    generation,
                    self._event(
                        stable,
                        STATUS_NOT_APPLIED_FENCED,
                        generation,
                        revision,
                    ),
                    ZERO_DIGEST,
                )
            if generation != entry.inflight_generation:
                raise RequestRejected(
                    "status query conflicts with inflight generation"
                )
            return make_status_evidence(
                self.descriptor,
                request,
                entry.inflight_revision,
                STATUS_PENDING,
                0,
                entry.inflight_event_sha256,
                ZERO_DIGEST,
            )
        entry = self._entry(request, create=True)
        if entry is None:
            raise AuthorityUnavailable("fake authority entry disappeared")
        generation = request["attempt_generation"]
        if entry.fence_through_generation < generation:
            if (
                entry.fence_through_generation != 0
                and generation != entry.fence_through_generation + 1
            ):
                raise RequestRejected("status query skipped a generation")
            revision = self._advance()
            entry.fence_through_generation = generation
            entry.fence_revision = revision
            entry.fence_event_sha256 = self._event(
                stable,
                STATUS_NOT_APPLIED_FENCED,
                generation,
                revision,
            )
        revision = entry.fence_revision
        return make_status_evidence(
            self.descriptor,
            request,
            revision,
            STATUS_NOT_APPLIED_FENCED,
            generation,
            self._event(
                stable,
                STATUS_NOT_APPLIED_FENCED,
                generation,
                revision,
            ),
            ZERO_DIGEST,
        )


@dataclass
class RuntimeAdapter:
    """Nonportable adapter boundary containing runtime-only authority."""

    descriptor: Record
    authority: FakeAuthority
    credential: RuntimeCredential

    def __post_init__(self) -> None:
        self.descriptor = validate_descriptor(self.descriptor)
        if not isinstance(self.authority, FakeAuthority):
            raise ActionOutboxAdapterError("adapter authority is invalid")
        if not isinstance(self.credential, RuntimeCredential):
            raise ActionOutboxAdapterError("adapter credential is invalid")
        if not hmac.compare_digest(
            self.descriptor["descriptor_sha256"],
            self.authority.descriptor["descriptor_sha256"],
        ):
            raise ActionOutboxAdapterError("adapter authority descriptor mismatch")


def dispatch(
    adapter: RuntimeAdapter,
    request_value: Any,
) -> Record:
    if not isinstance(adapter, RuntimeAdapter):
        raise ActionOutboxAdapterError("invalid runtime adapter")
    request = validate_dispatch_request(request_value)
    if not hmac.compare_digest(
        request["adapter_descriptor_sha256"],
        adapter.descriptor["descriptor_sha256"],
    ):
        raise ActionOutboxAdapterError("dispatch adapter binding mismatch")
    evidence = adapter.authority.dispatch(request, adapter.credential)
    return validate_dispatch_evidence(
        adapter.descriptor,
        request,
        evidence,
    )


def status(
    adapter: RuntimeAdapter,
    request_value: Any,
) -> Record:
    if not isinstance(adapter, RuntimeAdapter):
        raise ActionOutboxAdapterError("invalid runtime adapter")
    request = validate_status_request(request_value)
    if not hmac.compare_digest(
        request["adapter_descriptor_sha256"],
        adapter.descriptor["descriptor_sha256"],
    ):
        raise ActionOutboxAdapterError("status adapter binding mismatch")
    evidence = adapter.authority.status(request, adapter.credential)
    return validate_status_evidence(
        adapter.descriptor,
        request,
        evidence,
    )


def reference_fixture() -> Record:
    """Construct the exact prior-layer shape used by the Zig contract tests."""

    descriptor = make_descriptor(
        17,
        3,
        _label("fake authority namespace"),
        _label("fake request schema"),
        _label("fake result schema"),
    )
    header = outbox.make_header(
        7,
        9,
        41,
        2,
        8,
        4096,
        descriptor["descriptor_sha256"],
        _label("payload store"),
        _label("header challenge"),
    )
    tool_descriptor = tool.make_descriptor(
        4,
        _label("tool namespace"),
        _label("argument schema"),
        _label("result schema"),
        _label("implementation"),
    )
    arguments = tool.make_arguments(88, 2)
    proposal = tool.make_proposal(
        41,
        1,
        _label("agent request"),
        tool_descriptor,
        arguments,
        _label("idempotency"),
    )
    policy = tool.make_policy(
        2,
        41,
        True,
        8,
        -10,
        10,
        tool_descriptor,
        _label("policy"),
    )
    authorization = tool.authorize_bounded_add(
        proposal,
        tool_descriptor,
        arguments,
        policy,
        1,
    )
    identity = outbox.make_action_identity(
        header,
        outbox.PURPOSE_PRIMARY,
        ZERO_DIGEST,
        tool_descriptor,
        arguments,
        proposal,
        policy,
        authorization,
        _label("service event"),
        _label("payload locator"),
        32,
        _label("payload"),
    )
    enqueued = outbox.make_enqueued_record(
        header,
        1,
        header["header_sha256"],
        identity,
    )
    states, ledger = outbox.apply_record(
        header,
        enqueued,
        [],
        outbox.empty_ledger(),
    )
    intent = outbox.make_transition_record(
        header,
        2,
        enqueued["record_sha256"],
        states[0],
        outbox.EVENT_DISPATCH_INTENT,
        1,
        ZERO_DIGEST,
        ZERO_DIGEST,
    )
    states, ledger = outbox.apply_record(header, intent, states, ledger)
    return {
        "descriptor": descriptor,
        "header": header,
        "identity": identity,
        "enqueued": enqueued,
        "intent": intent,
        "state": states[0],
        "states": states,
        "ledger": ledger,
    }


def reference_report_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        REFERENCE_REPORT_DOMAIN,
        _le_u64(value["abi_version"]),
        *(
            _digest(value[name], f"reference report {name}")
            for name in REFERENCE_REPORT_FIELDS[1:-1]
        ),
    )


def validate_reference_report(value: Any) -> Record:
    result = _strict_record(
        value,
        REFERENCE_REPORT_FIELDS,
        "reference report",
    )
    _u64(result["abi_version"], "reference report ABI")
    for name in REFERENCE_REPORT_FIELDS[1:]:
        _digest(result[name], f"reference report {name}")
    if result["abi_version"] != REFERENCE_REPORT_ABI or not hmac.compare_digest(
        result["report_sha256"],
        reference_report_sha256(result),
    ):
        raise ActionOutboxAdapterError("invalid reference report")
    return deepcopy(result)


def build_reference_report() -> Record:
    fixture = reference_fixture()
    descriptor = fixture["descriptor"]
    dispatch_request = make_dispatch_request(
        descriptor,
        fixture["header"],
        fixture["intent"],
    )
    dispatch_evidence = make_dispatch_evidence(
        descriptor,
        dispatch_request,
        1,
        DISPATCH_SUCCEEDED,
        _label("remote event"),
        _label("result"),
    )
    status_request = make_status_request(
        descriptor,
        fixture["header"],
        fixture["state"],
        1,
    )
    status_evidence = make_status_evidence(
        descriptor,
        status_request,
        2,
        STATUS_NOT_APPLIED_FENCED,
        status_request["attempt_generation"],
        _label("fence receipt"),
        ZERO_DIGEST,
    )
    result: Record = {
        "abi_version": REFERENCE_REPORT_ABI,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "header_sha256": fixture["header"]["header_sha256"],
        "action_sha256": fixture["identity"]["action_sha256"],
        "stable_remote_request_sha256": fixture["identity"][
            "stable_remote_request_sha256"
        ],
        "intent_record_sha256": fixture["intent"]["record_sha256"],
        "outbox_dispatch_request_sha256": fixture["intent"]["dispatch_request_sha256"],
        "adapter_dispatch_request_sha256": dispatch_request["request_sha256"],
        "status_request_sha256": status_request["request_sha256"],
        "dispatch_evidence_sha256": dispatch_evidence["evidence_sha256"],
        "status_evidence_sha256": status_evidence["evidence_sha256"],
        "report_sha256": ZERO_DIGEST,
    }
    result["report_sha256"] = reference_report_sha256(result)
    return validate_reference_report(result)


def build_reference_json() -> Record:
    report = build_reference_report()
    return {
        "schema": REFERENCE_SCHEMA,
        "reference_report_abi": f"{REFERENCE_REPORT_ABI:016x}",
        "descriptor_abi": f"{DESCRIPTOR_ABI:016x}",
        "dispatch_request_abi": f"{DISPATCH_REQUEST_ABI:016x}",
        "dispatch_evidence_abi": f"{DISPATCH_EVIDENCE_ABI:016x}",
        "status_request_abi": f"{STATUS_REQUEST_ABI:016x}",
        "status_evidence_abi": f"{STATUS_EVIDENCE_ABI:016x}",
        **{name: report[name].hex() for name in REFERENCE_REPORT_FIELDS[1:]},
    }


def validate_reference_json(value: Any) -> Record:
    result = _strict_record(
        value,
        REFERENCE_JSON_FIELDS,
        "reference JSON report",
    )
    if any(type(item) is not str for item in result.values()):
        raise ActionOutboxAdapterError(
            "reference JSON report contains a non-string value"
        )
    if result != build_reference_json():
        raise ActionOutboxAdapterError(
            "reference JSON report contradicts the Python oracle"
        )
    return deepcopy(result)


def render_reference_json(value: Any | None = None) -> str:
    report = build_reference_json() if value is None else validate_reference_json(value)
    return (
        json.dumps(
            report,
            ensure_ascii=True,
            separators=(",", ":"),
        )
        + "\n"
    )


def load_reference_json_exact(encoded: bytes, where: str) -> Record:
    if (
        type(encoded) is not bytes
        or not 0 < len(encoded) <= MAXIMUM_RUNNER_STDOUT_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise ActionOutboxAdapterError(
            f"{where} is not one bounded canonical JSON line"
        )

    def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
        result: Record = {}
        for key, item in pairs:
            if key in result:
                raise ActionOutboxAdapterError(f"{where} contains duplicate fields")
            result[key] = item
        return result

    def reject_number(_: str) -> None:
        raise ActionOutboxAdapterError(f"{where} contains a non-string number")

    try:
        decoded = json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=object_pairs,
            parse_constant=reject_number,
            parse_float=reject_number,
            parse_int=reject_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActionOutboxAdapterError(f"{where} is invalid JSON") from error
    report = validate_reference_json(decoded)
    if render_reference_json(report).encode("ascii") != encoded:
        raise ActionOutboxAdapterError(f"{where} is not canonical JSON")
    return report


def verify_runner(runner: Path | Sequence[str]) -> None:
    command = [str(runner)] if isinstance(runner, Path) else list(runner)
    if not command or not all(
        isinstance(argument, str) and argument for argument in command
    ):
        raise ActionOutboxAdapterError("invalid adapter runner command")
    completed = subprocess.run(
        command,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if len(completed.stdout) > MAXIMUM_RUNNER_STDOUT_BYTES:
        raise ActionOutboxAdapterError("adapter runner stdout is too large")
    if completed.returncode != 0 or completed.stderr:
        raise ActionOutboxAdapterError("adapter runner failed")
    expected = build_reference_json()
    actual = load_reference_json_exact(completed.stdout, "adapter runner output")
    if actual != expected or completed.stdout != render_reference_json(expected).encode(
        "ascii"
    ):
        raise ActionOutboxAdapterError("adapter runner contradicts the Python oracle")


def request_for_generation(
    request_value: Any,
    generation: int,
    *,
    intent_record_sha256: Digest | None = None,
) -> Record:
    """Create a structurally valid alternate-attempt envelope for fake-service tests.

    Composition against an outbox record remains the caller's responsibility.
    This helper intentionally does not manufacture prior-layer authority.
    """

    request = validate_dispatch_request(request_value)
    selected = _u64(generation, "alternate attempt generation")
    if selected == 0:
        raise ActionOutboxAdapterError("alternate generation is zero")
    result = deepcopy(request)
    result["attempt_generation"] = selected
    result["dispatch_request_sha256"] = _sha(
        outbox.DISPATCH_REQUEST_DOMAIN,
        result["header_sha256"],
        result["stable_remote_request_sha256"],
        _le_u64(selected),
    )
    result["intent_record_sha256"] = (
        _label(f"alternate intent {selected}")
        if intent_record_sha256 is None
        else _digest(intent_record_sha256, "alternate intent")
    )
    result["request_sha256"] = dispatch_request_sha256(result)
    return validate_dispatch_request(result)


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render or verify the ActionOutbox adapter reference",
    )
    parser.add_argument("--runner", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if arguments.runner is None:
            sys.stdout.write(render_reference_json())
        else:
            verify_runner(arguments.runner)
    except (
        ActionOutboxAdapterError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"action-outbox-adapter-conformance: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
