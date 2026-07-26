"""Independent typed-tool transaction and workload conformance oracle.

The generic plan and LaneWeave replay come from
``bench.typed_workload_conformance``.  Every tool descriptor, proposal, policy,
authorization, effect, delivery, idempotency, and campaign-evidence rule in
this module is reimplemented independently from the Zig implementation.

The retained workload is credential-free and has no filesystem, network,
process, clock, random-number, or external side-effect authority.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import struct
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Any, Mapping, Sequence

from bench import typed_workload_conformance as workload


class TypedToolError(ValueError):
    """The tool contract, campaign evidence, or canonical report is invalid."""


Record = dict[str, Any]
Digest = bytes

U64_MAX = (1 << 64) - 1
I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
ZERO_DIGEST = bytes(32)

DESCRIPTOR_ABI = 0x4754414400000001
BOUNDED_ADD_ARGUMENTS_ABI = 0x4754414100000001
PROPOSAL_ABI = 0x4754415000000001
POLICY_ABI = 0x4754415900000001
AUTHORIZATION_ABI = 0x4754415500000001
EFFECT_ABI = 0x4754414500000001
DELIVERY_ABI = 0x4754414C00000001

CAPABILITY_BOUNDED_ADD = 1 << 0
ALLOWED_CAPABILITIES = CAPABILITY_BOUNDED_ADD

OPERATION_BOUNDED_ADD = 1

AUTHORIZATION_ALLOWED = 1
AUTHORIZATION_DENIED = 2

DENIAL_NONE = 0
DENIAL_TENANT_MISMATCH = 1
DENIAL_DESCRIPTOR_MISMATCH = 2
DENIAL_TOOL_DISABLED = 3
DENIAL_DELTA_OUT_OF_RANGE = 4
DENIAL_RESULT_OUT_OF_RANGE = 5
DENIAL_IDEMPOTENCY_CONFLICT = 6

DELIVERY_EXECUTED = 1
DELIVERY_REUSED = 2
DELIVERY_DENIED = 3
DELIVERY_CONFLICT = 4

DESCRIPTOR_DOMAIN = b"glacier-tool-action-descriptor-v1\x00"
ARGUMENTS_DOMAIN = b"glacier-tool-bounded-add-arguments-v1\x00"
PROPOSAL_DOMAIN = b"glacier-tool-action-proposal-v1\x00"
POLICY_DOMAIN = b"glacier-tool-action-policy-v1\x00"
AUTHORIZATION_DOMAIN = b"glacier-tool-authorization-v1\x00"
EFFECT_OUTPUT_DOMAIN = b"glacier-tool-bounded-add-output-v1\x00"
EFFECT_DOMAIN = b"glacier-tool-effect-v1\x00"
TERMINAL_OUTPUT_DOMAIN = b"glacier-tool-terminal-output-v1\x00"
DELIVERY_DOMAIN = b"glacier-tool-delivery-v1\x00"

DESCRIPTOR_FIELDS = (
    "abi_version",
    "tool_adapter_abi",
    "operation",
    "capability_bits",
    "tool_namespace_sha256",
    "argument_schema_sha256",
    "result_schema_sha256",
    "implementation_sha256",
    "descriptor_sha256",
)
ARGUMENT_FIELDS = (
    "abi_version",
    "target_key",
    "delta",
    "arguments_sha256",
)
PROPOSAL_FIELDS = (
    "abi_version",
    "tenant_key",
    "action_ordinal",
    "agent_request_sha256",
    "descriptor_sha256",
    "arguments_sha256",
    "idempotency_key_sha256",
    "proposal_sha256",
)
POLICY_FIELDS = (
    "abi_version",
    "policy_epoch",
    "tenant_key",
    "allow_bounded_add",
    "maximum_absolute_delta",
    "minimum_value",
    "maximum_value",
    "descriptor_sha256",
    "challenge_sha256",
    "policy_sha256",
)
AUTHORIZATION_FIELDS = (
    "abi_version",
    "kind",
    "reason",
    "proposal_sha256",
    "policy_sha256",
    "observed_before",
    "projected_after",
    "authorization_sha256",
)
EFFECT_FIELDS = (
    "abi_version",
    "execution_sequence",
    "target_key",
    "before_value",
    "after_value",
    "idempotency_key_sha256",
    "proposal_sha256",
    "authorization_sha256",
    "output_sha256",
    "effect_sha256",
)
DELIVERY_FIELDS = (
    "abi_version",
    "disposition",
    "proposal_sha256",
    "authorization_sha256",
    "idempotency_key_sha256",
    "effect_sha256",
    "service_event_sha256",
    "output_sha256",
    "delivery_sha256",
)

EVIDENCE_ABI = 0x4754545745000001
ITEM_EVIDENCE_ABI = 0x4754545749000001
EVIDENCE_SUMMARY_ABI = 0x4754545753000001

ITEM_EVIDENCE_DOMAIN = b"glacier-typed-tool-workload-item-evidence-v1\x00"
ITEM_EVIDENCE_SECTION_DOMAIN = b"glacier-typed-tool-workload-item-section-v1\x00"
EVIDENCE_SUMMARY_DOMAIN = b"glacier-typed-tool-workload-summary-v1\x00"
EVIDENCE_DOMAIN = b"glacier-typed-tool-workload-evidence-v1\x00"

ITEM_EVIDENCE_FIELDS = (
    "ordinal",
    "profile_index",
    "outcome",
    "terminal_action",
    "profile_sha256",
    "item_sha256",
    "arguments",
    "proposal",
    "descriptor_sha256",
    "policy_sha256",
    "resource_receipt_sha256",
    "resource_bank_epoch",
    "resource_slot_index",
    "resource_generation",
    "resource_owner_key",
    "resource_claim",
    "resource_integrity",
    "authorization",
    "effect",
    "delivery",
    "final_service_event_sha256",
    "counter_before",
    "counter_after",
    "admission_trace_sha256",
    "terminal_trace_sha256",
    "driver_outcome_sha256",
    "record_sha256",
)
EVIDENCE_SUMMARY_FIELDS = (
    "profile_count",
    "item_count",
    "admitted",
    "rejected",
    "completed",
    "cancelled",
    "timed_out",
    "tool_calls",
    "deliveries",
    "executed",
    "reused",
    "denied",
    "conflicts",
    "effects",
    "initial_counter",
    "final_counter",
    "model_successful_commits",
    "model_releases",
    "model_final_active_reservations",
    "model_final_committed_receipts",
    "harness_open",
    "pending_prepared",
    "pending_armed",
    "zero_model_ownership",
    "zero_harness_authority",
    "zero_orphan_ownership",
    "summary_sha256",
)
EVIDENCE_FIELDS = (
    "plan_sha256",
    "driver_result_sha256",
    "driver_outcome_sha256",
    "driver_trace_sha256",
    "driver_summary_sha256",
    "descriptor",
    "policy",
    "item_section_sha256",
    "evidence_summary_sha256",
    "items",
    "summary",
    "evidence_sha256",
)

REPORT_SCHEMA = "glacier.typed-tool-conformance/v1"
MAXIMUM_JSON_BYTES = 4 * 1024 * 1024

REPORT_PEAK_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "queue_slots",
)
EVIDENCE_REPORT_SUMMARY_FIELDS = EVIDENCE_SUMMARY_FIELDS[:-1]
REPORT_FIELDS = (
    "schema",
    "plan_abi",
    "profile_abi",
    "item_abi",
    "driver_result_abi",
    "driver_outcome_abi",
    "driver_trace_abi",
    "driver_summary_abi",
    "tool_descriptor_abi",
    "tool_arguments_abi",
    "tool_proposal_abi",
    "tool_policy_abi",
    "tool_authorization_abi",
    "tool_effect_abi",
    "tool_delivery_abi",
    "evidence_abi",
    "item_evidence_abi",
    "evidence_summary_abi",
    "profile_count",
    "item_count",
    "trace_count",
    "plan_wire_bytes",
    "plan_wire_sha256",
    "plan_sha256",
    "outcome_sha256",
    "trace_sha256",
    "summary_sha256",
    "result_sha256",
    "descriptor_sha256",
    "policy_sha256",
    "item_section_sha256",
    "evidence_summary_sha256",
    "evidence_sha256",
    "outcomes",
    "dispositions",
    "driver_summary",
    "evidence_summary",
)

REFERENCE_REPORT_BYTES = 3223
REFERENCE_REPORT_SHA256 = (
    "12290bf9c833a02e95666294d39f9e83320b9f031e40ede9278da190883c41e2"
)
REFERENCE_REPORT_ROOTS = {
    "plan_wire_sha256": (
        "8f5923d3ea833085958fcdcc337eaea5125d3e334c2cab6fce8d22a7dd6c9bb6"
    ),
    "plan_sha256": ("70f9a93231f0f8250dda77ca04664bec620fd1422445298ea7bf3aeca1dfadae"),
    "outcome_sha256": (
        "12b71a866ecaf09b1b6982ae15625be6d6af5424b435beb641da1d0ab5b17741"
    ),
    "trace_sha256": (
        "26486838c786ef79e4439ade1ffce3c4853a610c7186a830ea15d5cf0b3a0d87"
    ),
    "summary_sha256": (
        "fc0ef6eaad6dfd6e93df34f1505e3d7725fc70b66997916f4cfdee4defb249d9"
    ),
    "result_sha256": (
        "1ce13ab97d950b3fbc36aa4f3a060bcdee3a966537fcf382091216fe1860cab8"
    ),
    "item_section_sha256": (
        "9f0fe42a069594d54f5bae4609cc435e38eb351767dda5998fe8900d7b3aa5d7"
    ),
    "evidence_summary_sha256": (
        "1e63ba2ffb0e8123772996fe1110968377c5594482e90ab49727ed9bdd5286ba"
    ),
    "evidence_sha256": (
        "5926b5fec3a69fdc9f000e44004f206db459a236a1900c85a0bd9f51080ec3a7"
    ),
}

TOOL_WORKLOAD_ADAPTER_ABI = 0x4754544100000001
REFERENCE_SEED = 0x4754545700000001
REFERENCE_BANK_EPOCH = 0x47545457424B0001
REFERENCE_SCHEDULER_EPOCH = 0x4754545753430001

MODEL_FAMILY_TOOL_EXECUTOR = 18
MODEL_OPERATION_EXECUTE_ACTION = 14
MODEL_INPUT_TYPED_RECORD = 7
MODEL_OUTPUT_TOOL_RESULT = 12
NUMERICAL_EXACT_INTEGER = 1


def _strict_record(value: Any, fields: Sequence[str], where: str) -> Record:
    if not isinstance(value, dict) or tuple(value) != tuple(fields):
        raise TypedToolError(f"{where} has noncanonical fields")
    return value


def _u64(value: Any, where: str) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise TypedToolError(f"{where} is not u64")
    return value


def _i64(value: Any, where: str) -> int:
    if type(value) is not int or not I64_MIN <= value <= I64_MAX:
        raise TypedToolError(f"{where} is not i64")
    return value


def _bool(value: Any, where: str) -> bool:
    if type(value) is not bool:
        raise TypedToolError(f"{where} is not bool")
    return value


def _digest(
    value: Any,
    where: str,
    *,
    allow_zero: bool = False,
) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise TypedToolError(f"{where} is not a digest")
    if not allow_zero and hmac.compare_digest(value, ZERO_DIGEST):
        raise TypedToolError(f"{where} is zero")
    return value


def _enum(value: Any, allowed: Sequence[int] | set[int], where: str) -> int:
    result = _u64(value, where)
    if result not in allowed:
        raise TypedToolError(f"{where} is not a known enum value")
    return result


def _le_u8(value: int) -> bytes:
    return struct.pack("<B", value)


def _le_u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def _le_i64(value: int) -> bytes:
    return struct.pack("<q", value)


def _sha(domain: bytes, *parts: bytes) -> Digest:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def descriptor_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        DESCRIPTOR_DOMAIN,
        _le_u64(_u64(value["abi_version"], "descriptor ABI")),
        _le_u64(_u64(value["tool_adapter_abi"], "tool adapter ABI")),
        _le_u8(_enum(value["operation"], {OPERATION_BOUNDED_ADD}, "operation")),
        _le_u64(_u64(value["capability_bits"], "capability bits")),
        _digest(value["tool_namespace_sha256"], "tool namespace"),
        _digest(value["argument_schema_sha256"], "argument schema"),
        _digest(value["result_schema_sha256"], "result schema"),
        _digest(value["implementation_sha256"], "implementation"),
    )


def validate_descriptor(value: Any) -> Record:
    result = _strict_record(value, DESCRIPTOR_FIELDS, "descriptor")
    if (
        _u64(result["abi_version"], "descriptor ABI") != DESCRIPTOR_ABI
        or _u64(result["tool_adapter_abi"], "tool adapter ABI") == 0
        or _enum(result["operation"], {OPERATION_BOUNDED_ADD}, "operation")
        != OPERATION_BOUNDED_ADD
        or _u64(result["capability_bits"], "capability bits") != CAPABILITY_BOUNDED_ADD
    ):
        raise TypedToolError("invalid descriptor")
    expected = descriptor_sha256(result)
    if not hmac.compare_digest(
        _digest(result["descriptor_sha256"], "descriptor root"),
        expected,
    ):
        raise TypedToolError("descriptor root mismatch")
    return deepcopy(result)


def make_descriptor(
    tool_adapter_abi: int,
    tool_namespace_sha256: Digest,
    argument_schema_sha256: Digest,
    result_schema_sha256: Digest,
    implementation_sha256: Digest,
) -> Record:
    value: Record = {
        "abi_version": DESCRIPTOR_ABI,
        "tool_adapter_abi": tool_adapter_abi,
        "operation": OPERATION_BOUNDED_ADD,
        "capability_bits": CAPABILITY_BOUNDED_ADD,
        "tool_namespace_sha256": tool_namespace_sha256,
        "argument_schema_sha256": argument_schema_sha256,
        "result_schema_sha256": result_schema_sha256,
        "implementation_sha256": implementation_sha256,
        "descriptor_sha256": ZERO_DIGEST,
    }
    value["descriptor_sha256"] = descriptor_sha256(value)
    return validate_descriptor(value)


def bounded_add_arguments_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        ARGUMENTS_DOMAIN,
        _le_u64(_u64(value["abi_version"], "arguments ABI")),
        _le_u64(_u64(value["target_key"], "target key")),
        _le_i64(_i64(value["delta"], "delta")),
    )


def validate_arguments(value: Any) -> Record:
    result = _strict_record(value, ARGUMENT_FIELDS, "arguments")
    delta = _i64(result["delta"], "delta")
    if (
        _u64(result["abi_version"], "arguments ABI") != BOUNDED_ADD_ARGUMENTS_ABI
        or _u64(result["target_key"], "target key") == 0
        or delta in (0, I64_MIN)
    ):
        raise TypedToolError("invalid bounded-add arguments")
    if not hmac.compare_digest(
        _digest(result["arguments_sha256"], "arguments root"),
        bounded_add_arguments_sha256(result),
    ):
        raise TypedToolError("arguments root mismatch")
    return deepcopy(result)


def make_arguments(target_key: int, delta: int) -> Record:
    value: Record = {
        "abi_version": BOUNDED_ADD_ARGUMENTS_ABI,
        "target_key": target_key,
        "delta": delta,
        "arguments_sha256": ZERO_DIGEST,
    }
    value["arguments_sha256"] = bounded_add_arguments_sha256(value)
    return validate_arguments(value)


def proposal_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        PROPOSAL_DOMAIN,
        _le_u64(_u64(value["abi_version"], "proposal ABI")),
        _le_u64(_u64(value["tenant_key"], "proposal tenant")),
        _le_u64(_u64(value["action_ordinal"], "action ordinal")),
        _digest(value["agent_request_sha256"], "agent request"),
        _digest(value["descriptor_sha256"], "proposal descriptor"),
        _digest(value["arguments_sha256"], "proposal arguments"),
        _digest(value["idempotency_key_sha256"], "idempotency key"),
    )


def validate_proposal(value: Any) -> Record:
    result = _strict_record(value, PROPOSAL_FIELDS, "proposal")
    if (
        _u64(result["abi_version"], "proposal ABI") != PROPOSAL_ABI
        or _u64(result["tenant_key"], "proposal tenant") == 0
    ):
        raise TypedToolError("invalid action proposal")
    _u64(result["action_ordinal"], "action ordinal")
    for name in (
        "agent_request_sha256",
        "descriptor_sha256",
        "arguments_sha256",
        "idempotency_key_sha256",
    ):
        _digest(result[name], name)
    if not hmac.compare_digest(
        _digest(result["proposal_sha256"], "proposal root"),
        proposal_sha256(result),
    ):
        raise TypedToolError("proposal root mismatch")
    return deepcopy(result)


def make_proposal(
    tenant_key: int,
    action_ordinal: int,
    agent_request_sha256: Digest,
    descriptor: Any,
    arguments: Any,
    idempotency_key_sha256: Digest,
) -> Record:
    descriptor_value = validate_descriptor(descriptor)
    argument_value = validate_arguments(arguments)
    value: Record = {
        "abi_version": PROPOSAL_ABI,
        "tenant_key": tenant_key,
        "action_ordinal": action_ordinal,
        "agent_request_sha256": agent_request_sha256,
        "descriptor_sha256": descriptor_value["descriptor_sha256"],
        "arguments_sha256": argument_value["arguments_sha256"],
        "idempotency_key_sha256": idempotency_key_sha256,
        "proposal_sha256": ZERO_DIGEST,
    }
    value["proposal_sha256"] = proposal_sha256(value)
    return validate_proposal(value)


def validate_proposal_composition(
    proposal: Any,
    descriptor: Any,
    arguments: Any,
) -> tuple[Record, Record, Record]:
    proposal_value = validate_proposal(proposal)
    descriptor_value = validate_descriptor(descriptor)
    argument_value = validate_arguments(arguments)
    if not hmac.compare_digest(
        proposal_value["descriptor_sha256"],
        descriptor_value["descriptor_sha256"],
    ) or not hmac.compare_digest(
        proposal_value["arguments_sha256"],
        argument_value["arguments_sha256"],
    ):
        raise TypedToolError("proposal composition mismatch")
    return proposal_value, descriptor_value, argument_value


def policy_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        POLICY_DOMAIN,
        _le_u64(_u64(value["abi_version"], "policy ABI")),
        _le_u64(_u64(value["policy_epoch"], "policy epoch")),
        _le_u64(_u64(value["tenant_key"], "policy tenant")),
        _le_u8(int(_bool(value["allow_bounded_add"], "allow bounded add"))),
        _le_u64(_u64(value["maximum_absolute_delta"], "maximum delta")),
        _le_i64(_i64(value["minimum_value"], "minimum value")),
        _le_i64(_i64(value["maximum_value"], "maximum value")),
        _digest(value["descriptor_sha256"], "policy descriptor"),
        _digest(value["challenge_sha256"], "policy challenge"),
    )


def validate_policy(value: Any) -> Record:
    result = _strict_record(value, POLICY_FIELDS, "policy")
    maximum_delta = _u64(result["maximum_absolute_delta"], "maximum delta")
    minimum = _i64(result["minimum_value"], "minimum value")
    maximum = _i64(result["maximum_value"], "maximum value")
    if (
        _u64(result["abi_version"], "policy ABI") != POLICY_ABI
        or _u64(result["policy_epoch"], "policy epoch") == 0
        or _u64(result["tenant_key"], "policy tenant") == 0
        or maximum_delta == 0
        or maximum_delta > I64_MAX
        or minimum > maximum
    ):
        raise TypedToolError("invalid tool policy")
    _bool(result["allow_bounded_add"], "allow bounded add")
    _digest(result["descriptor_sha256"], "policy descriptor")
    _digest(result["challenge_sha256"], "policy challenge")
    if not hmac.compare_digest(
        _digest(result["policy_sha256"], "policy root"),
        policy_sha256(result),
    ):
        raise TypedToolError("policy root mismatch")
    return deepcopy(result)


def make_policy(
    policy_epoch: int,
    tenant_key: int,
    allow_bounded_add: bool,
    maximum_absolute_delta: int,
    minimum_value: int,
    maximum_value: int,
    descriptor: Any,
    challenge_sha256: Digest,
) -> Record:
    descriptor_value = validate_descriptor(descriptor)
    value: Record = {
        "abi_version": POLICY_ABI,
        "policy_epoch": policy_epoch,
        "tenant_key": tenant_key,
        "allow_bounded_add": allow_bounded_add,
        "maximum_absolute_delta": maximum_absolute_delta,
        "minimum_value": minimum_value,
        "maximum_value": maximum_value,
        "descriptor_sha256": descriptor_value["descriptor_sha256"],
        "challenge_sha256": challenge_sha256,
        "policy_sha256": ZERO_DIGEST,
    }
    value["policy_sha256"] = policy_sha256(value)
    return validate_policy(value)


def authorization_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        AUTHORIZATION_DOMAIN,
        _le_u64(_u64(value["abi_version"], "authorization ABI")),
        _le_u8(
            _enum(
                value["kind"],
                {AUTHORIZATION_ALLOWED, AUTHORIZATION_DENIED},
                "authorization kind",
            )
        ),
        _le_u8(
            _enum(
                value["reason"],
                set(range(DENIAL_NONE, DENIAL_IDEMPOTENCY_CONFLICT + 1)),
                "denial reason",
            )
        ),
        _digest(value["proposal_sha256"], "authorization proposal"),
        _digest(value["policy_sha256"], "authorization policy"),
        _le_i64(_i64(value["observed_before"], "observed before")),
        _le_i64(_i64(value["projected_after"], "projected after")),
    )


def validate_authorization(value: Any) -> Record:
    result = _strict_record(value, AUTHORIZATION_FIELDS, "authorization")
    kind = _enum(
        result["kind"],
        {AUTHORIZATION_ALLOWED, AUTHORIZATION_DENIED},
        "authorization kind",
    )
    reason = _enum(
        result["reason"],
        set(range(DENIAL_NONE, DENIAL_IDEMPOTENCY_CONFLICT + 1)),
        "denial reason",
    )
    observed = _i64(result["observed_before"], "observed before")
    projected = _i64(result["projected_after"], "projected after")
    shape_valid = (
        kind == AUTHORIZATION_ALLOWED
        and reason == DENIAL_NONE
        or kind == AUTHORIZATION_DENIED
        and reason != DENIAL_NONE
        and projected == observed
    )
    if (
        _u64(result["abi_version"], "authorization ABI") != AUTHORIZATION_ABI
        or not shape_valid
    ):
        raise TypedToolError("invalid authorization receipt")
    _digest(result["proposal_sha256"], "authorization proposal")
    _digest(result["policy_sha256"], "authorization policy")
    if not hmac.compare_digest(
        _digest(result["authorization_sha256"], "authorization root"),
        authorization_sha256(result),
    ):
        raise TypedToolError("authorization root mismatch")
    return deepcopy(result)


def _make_authorization(
    proposal: Any,
    policy: Any,
    kind: int,
    reason: int,
    observed_before: int,
    projected_after: int,
) -> Record:
    proposal_value = validate_proposal(proposal)
    policy_value = validate_policy(policy)
    value: Record = {
        "abi_version": AUTHORIZATION_ABI,
        "kind": kind,
        "reason": reason,
        "proposal_sha256": proposal_value["proposal_sha256"],
        "policy_sha256": policy_value["policy_sha256"],
        "observed_before": observed_before,
        "projected_after": projected_after,
        "authorization_sha256": ZERO_DIGEST,
    }
    value["authorization_sha256"] = authorization_sha256(value)
    return validate_authorization(value)


def authorize_bounded_add(
    proposal: Any,
    descriptor: Any,
    arguments: Any,
    policy: Any,
    observed_before: int,
) -> Record:
    proposal_value, descriptor_value, argument_value = validate_proposal_composition(
        proposal, descriptor, arguments
    )
    policy_value = validate_policy(policy)
    observed = _i64(observed_before, "observed before")
    reason = DENIAL_NONE
    projected = observed
    if proposal_value["tenant_key"] != policy_value["tenant_key"]:
        reason = DENIAL_TENANT_MISMATCH
    elif not hmac.compare_digest(
        proposal_value["descriptor_sha256"],
        policy_value["descriptor_sha256"],
    ):
        reason = DENIAL_DESCRIPTOR_MISMATCH
    elif not policy_value["allow_bounded_add"]:
        reason = DENIAL_TOOL_DISABLED
    elif abs(argument_value["delta"]) > policy_value["maximum_absolute_delta"]:
        reason = DENIAL_DELTA_OUT_OF_RANGE
    else:
        projected = observed + argument_value["delta"]
        if (
            not I64_MIN <= projected <= I64_MAX
            or projected < policy_value["minimum_value"]
            or projected > policy_value["maximum_value"]
        ):
            reason = DENIAL_RESULT_OUT_OF_RANGE
    return _make_authorization(
        proposal_value,
        policy_value,
        AUTHORIZATION_ALLOWED if reason == DENIAL_NONE else AUTHORIZATION_DENIED,
        reason,
        observed,
        projected if reason == DENIAL_NONE else observed,
    )


def deny_idempotency_conflict(
    proposal: Any,
    policy: Any,
    observed_before: int,
) -> Record:
    proposal_value = validate_proposal(proposal)
    policy_value = validate_policy(policy)
    if (
        proposal_value["tenant_key"] != policy_value["tenant_key"]
        or not hmac.compare_digest(
            proposal_value["descriptor_sha256"],
            policy_value["descriptor_sha256"],
        )
        or not policy_value["allow_bounded_add"]
    ):
        raise TypedToolError("conflict denial lacks matching enabled policy")
    return _make_authorization(
        proposal_value,
        policy_value,
        AUTHORIZATION_DENIED,
        DENIAL_IDEMPOTENCY_CONFLICT,
        _i64(observed_before, "observed before"),
        _i64(observed_before, "observed before"),
    )


def validate_authorization_composition(
    authorization: Any,
    proposal: Any,
    policy: Any,
) -> tuple[Record, Record, Record]:
    authorization_value = validate_authorization(authorization)
    proposal_value = validate_proposal(proposal)
    policy_value = validate_policy(policy)
    if not hmac.compare_digest(
        authorization_value["proposal_sha256"],
        proposal_value["proposal_sha256"],
    ) or not hmac.compare_digest(
        authorization_value["policy_sha256"],
        policy_value["policy_sha256"],
    ):
        raise TypedToolError("authorization composition mismatch")
    return authorization_value, proposal_value, policy_value


def bounded_add_output_sha256(
    target_key: int,
    before_value: int,
    after_value: int,
) -> Digest:
    return _sha(
        EFFECT_OUTPUT_DOMAIN,
        _le_u64(_u64(target_key, "effect target")),
        _le_i64(_i64(before_value, "effect before")),
        _le_i64(_i64(after_value, "effect after")),
    )


def effect_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        EFFECT_DOMAIN,
        _le_u64(_u64(value["abi_version"], "effect ABI")),
        _le_u64(_u64(value["execution_sequence"], "execution sequence")),
        _le_u64(_u64(value["target_key"], "effect target")),
        _le_i64(_i64(value["before_value"], "effect before")),
        _le_i64(_i64(value["after_value"], "effect after")),
        _digest(value["idempotency_key_sha256"], "effect idempotency key"),
        _digest(value["proposal_sha256"], "effect proposal"),
        _digest(value["authorization_sha256"], "effect authorization"),
        _digest(value["output_sha256"], "effect output"),
    )


def validate_effect(value: Any) -> Record:
    result = _strict_record(value, EFFECT_FIELDS, "effect")
    if (
        _u64(result["abi_version"], "effect ABI") != EFFECT_ABI
        or _u64(result["execution_sequence"], "execution sequence") == 0
        or _u64(result["target_key"], "effect target") == 0
    ):
        raise TypedToolError("invalid effect receipt")
    before = _i64(result["before_value"], "effect before")
    after = _i64(result["after_value"], "effect after")
    for name in (
        "idempotency_key_sha256",
        "proposal_sha256",
        "authorization_sha256",
    ):
        _digest(result[name], name)
    if not hmac.compare_digest(
        _digest(result["output_sha256"], "effect output"),
        bounded_add_output_sha256(result["target_key"], before, after),
    ) or not hmac.compare_digest(
        _digest(result["effect_sha256"], "effect root"),
        effect_sha256(result),
    ):
        raise TypedToolError("effect root mismatch")
    return deepcopy(result)


def make_effect(
    execution_sequence: int,
    proposal: Any,
    arguments: Any,
    authorization: Any,
) -> Record:
    proposal_value = validate_proposal(proposal)
    argument_value = validate_arguments(arguments)
    authorization_value = validate_authorization(authorization)
    projected = authorization_value["observed_before"] + argument_value["delta"]
    if (
        authorization_value["kind"] != AUTHORIZATION_ALLOWED
        or not hmac.compare_digest(
            proposal_value["arguments_sha256"],
            argument_value["arguments_sha256"],
        )
        or not hmac.compare_digest(
            authorization_value["proposal_sha256"],
            proposal_value["proposal_sha256"],
        )
        or not I64_MIN <= projected <= I64_MAX
        or authorization_value["projected_after"] != projected
    ):
        raise TypedToolError("effect lacks exact authorization")
    value: Record = {
        "abi_version": EFFECT_ABI,
        "execution_sequence": execution_sequence,
        "target_key": argument_value["target_key"],
        "before_value": authorization_value["observed_before"],
        "after_value": authorization_value["projected_after"],
        "idempotency_key_sha256": proposal_value["idempotency_key_sha256"],
        "proposal_sha256": proposal_value["proposal_sha256"],
        "authorization_sha256": authorization_value["authorization_sha256"],
        "output_sha256": ZERO_DIGEST,
        "effect_sha256": ZERO_DIGEST,
    }
    value["output_sha256"] = bounded_add_output_sha256(
        value["target_key"],
        value["before_value"],
        value["after_value"],
    )
    value["effect_sha256"] = effect_sha256(value)
    return validate_effect(value)


def validate_effect_composition(
    effect: Any,
    proposal: Any,
    arguments: Any,
    authorization: Any,
) -> Record:
    effect_value = validate_effect(effect)
    expected = make_effect(
        effect_value["execution_sequence"],
        proposal,
        arguments,
        authorization,
    )
    if effect_value != expected:
        raise TypedToolError("effect composition mismatch")
    return effect_value


def terminal_output_sha256(
    disposition: int,
    proposal: Mapping[str, Any],
    authorization: Mapping[str, Any],
    effect_root: Digest,
) -> Digest:
    return _sha(
        TERMINAL_OUTPUT_DOMAIN,
        _le_u8(
            _enum(
                disposition,
                {
                    DELIVERY_EXECUTED,
                    DELIVERY_REUSED,
                    DELIVERY_DENIED,
                    DELIVERY_CONFLICT,
                },
                "delivery disposition",
            )
        ),
        _digest(proposal["proposal_sha256"], "terminal proposal"),
        _digest(authorization["authorization_sha256"], "terminal authorization"),
        _digest(effect_root, "terminal effect", allow_zero=True),
    )


def delivery_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        DELIVERY_DOMAIN,
        _le_u64(_u64(value["abi_version"], "delivery ABI")),
        _le_u8(
            _enum(
                value["disposition"],
                {
                    DELIVERY_EXECUTED,
                    DELIVERY_REUSED,
                    DELIVERY_DENIED,
                    DELIVERY_CONFLICT,
                },
                "delivery disposition",
            )
        ),
        _digest(value["proposal_sha256"], "delivery proposal"),
        _digest(value["authorization_sha256"], "delivery authorization"),
        _digest(value["idempotency_key_sha256"], "delivery idempotency key"),
        _digest(value["effect_sha256"], "delivery effect", allow_zero=True),
        _digest(value["service_event_sha256"], "service event"),
        _digest(value["output_sha256"], "delivery output"),
    )


def validate_delivery(value: Any) -> Record:
    result = _strict_record(value, DELIVERY_FIELDS, "delivery")
    disposition = _enum(
        result["disposition"],
        {
            DELIVERY_EXECUTED,
            DELIVERY_REUSED,
            DELIVERY_DENIED,
            DELIVERY_CONFLICT,
        },
        "delivery disposition",
    )
    effect = _digest(
        result["effect_sha256"],
        "delivery effect",
        allow_zero=True,
    )
    if _u64(result["abi_version"], "delivery ABI") != DELIVERY_ABI or (
        disposition == DELIVERY_DENIED
    ) != hmac.compare_digest(
        effect,
        ZERO_DIGEST,
    ):
        raise TypedToolError("invalid delivery receipt shape")
    for name in (
        "proposal_sha256",
        "authorization_sha256",
        "idempotency_key_sha256",
        "service_event_sha256",
        "output_sha256",
    ):
        _digest(result[name], name)
    if not hmac.compare_digest(
        _digest(result["delivery_sha256"], "delivery root"),
        delivery_sha256(result),
    ):
        raise TypedToolError("delivery root mismatch")
    return deepcopy(result)


def make_delivery(
    disposition: int,
    proposal: Any,
    authorization: Any,
    effect: Any | None,
    service_event_sha256: Digest,
) -> Record:
    proposal_value = validate_proposal(proposal)
    authorization_value = validate_authorization(authorization)
    if not hmac.compare_digest(
        proposal_value["proposal_sha256"],
        authorization_value["proposal_sha256"],
    ):
        raise TypedToolError("delivery authorization is for another proposal")
    service_root = _digest(service_event_sha256, "service event")
    effect_value = validate_effect(effect) if effect is not None else None
    effect_root = (
        effect_value["effect_sha256"] if effect_value is not None else ZERO_DIGEST
    )
    if effect_value is not None and not hmac.compare_digest(
        effect_value["idempotency_key_sha256"],
        proposal_value["idempotency_key_sha256"],
    ):
        raise TypedToolError("delivery idempotency key mismatch")

    if disposition in (DELIVERY_EXECUTED, DELIVERY_REUSED):
        if (
            effect_value is None
            or authorization_value["kind"] != AUTHORIZATION_ALLOWED
            or not hmac.compare_digest(
                effect_value["proposal_sha256"],
                proposal_value["proposal_sha256"],
            )
            or not hmac.compare_digest(
                effect_value["authorization_sha256"],
                authorization_value["authorization_sha256"],
            )
        ):
            raise TypedToolError("executed/reused delivery lacks exact effect")
        output_root = effect_value["output_sha256"]
    elif disposition == DELIVERY_DENIED:
        if (
            effect_value is not None
            or authorization_value["kind"] != AUTHORIZATION_DENIED
            or authorization_value["reason"] == DENIAL_IDEMPOTENCY_CONFLICT
        ):
            raise TypedToolError("denied delivery shape mismatch")
        output_root = terminal_output_sha256(
            disposition,
            proposal_value,
            authorization_value,
            ZERO_DIGEST,
        )
    elif disposition == DELIVERY_CONFLICT:
        if (
            effect_value is None
            or authorization_value["kind"] != AUTHORIZATION_DENIED
            or authorization_value["reason"] != DENIAL_IDEMPOTENCY_CONFLICT
            or hmac.compare_digest(
                effect_value["proposal_sha256"],
                proposal_value["proposal_sha256"],
            )
        ):
            raise TypedToolError("conflict delivery shape mismatch")
        output_root = terminal_output_sha256(
            disposition,
            proposal_value,
            authorization_value,
            effect_value["effect_sha256"],
        )
    else:
        raise TypedToolError("unknown delivery disposition")

    value: Record = {
        "abi_version": DELIVERY_ABI,
        "disposition": disposition,
        "proposal_sha256": proposal_value["proposal_sha256"],
        "authorization_sha256": authorization_value["authorization_sha256"],
        "idempotency_key_sha256": proposal_value["idempotency_key_sha256"],
        "effect_sha256": effect_root,
        "service_event_sha256": service_root,
        "output_sha256": output_root,
        "delivery_sha256": ZERO_DIGEST,
    }
    value["delivery_sha256"] = delivery_sha256(value)
    return validate_delivery(value)


def validate_delivery_composition(
    delivery: Any,
    proposal: Any,
    authorization: Any,
    effect: Any | None,
    service_event_sha256: Digest,
) -> Record:
    delivery_value = validate_delivery(delivery)
    expected = make_delivery(
        delivery_value["disposition"],
        proposal,
        authorization,
        effect,
        service_event_sha256,
    )
    if delivery_value != expected:
        raise TypedToolError("delivery composition mismatch")
    return delivery_value


# The workload/campaign-specific oracle is defined below the contract layer.
# It is intentionally kept in this module so one canonical report can bind the
# generic W4 plan replay and the independently reconstructed tool transaction.


def _label(value: str) -> Digest:
    return hashlib.sha256(value.encode("ascii")).digest()


def reference_descriptor() -> Record:
    return make_descriptor(
        TOOL_WORKLOAD_ADAPTER_ABI,
        _label("glacier typed tool bounded-add namespace v1"),
        _label("glacier typed tool bounded-add argument schema v1"),
        _label("glacier typed tool bounded-add result schema v1"),
        _label("glacier typed tool bounded-add implementation v1"),
    )


def reference_policy(descriptor: Any | None = None) -> Record:
    descriptor_value = (
        reference_descriptor()
        if descriptor is None
        else validate_descriptor(descriptor)
    )
    return make_policy(
        1,
        0x544F_4F4C,
        True,
        8,
        -32,
        32,
        descriptor_value,
        _label("glacier typed tool bounded-add policy challenge v1"),
    )


def reference_arguments() -> list[Record]:
    return [make_arguments(1, delta) for delta in (1, 2, 3, 4, 5, 5, 9, 4)]


def reference_proposals(
    descriptor: Any | None = None,
    arguments: Sequence[Any] | None = None,
) -> list[Record]:
    descriptor_value = (
        reference_descriptor()
        if descriptor is None
        else validate_descriptor(descriptor)
    )
    argument_values = (
        reference_arguments()
        if arguments is None
        else [validate_arguments(value) for value in arguments]
    )
    if len(argument_values) != 8:
        raise TypedToolError("reference proposal argument count changed")
    proposals: list[Record] = []
    for ordinal, argument in enumerate(argument_values):
        if ordinal == 5:
            proposals.append(deepcopy(proposals[4]))
            continue
        idempotency_ordinal = 4 if ordinal == 7 else ordinal
        proposals.append(
            make_proposal(
                0x544F_4F4C,
                ordinal,
                _label(f"glacier typed tool agent request {ordinal} v1"),
                descriptor_value,
                argument,
                _label(f"glacier typed tool idempotency {idempotency_ordinal} v1"),
            )
        )
    if proposals[5] != proposals[4]:
        raise TypedToolError("reference duplicate proposal changed")
    if not hmac.compare_digest(
        proposals[7]["idempotency_key_sha256"],
        proposals[4]["idempotency_key_sha256"],
    ) or hmac.compare_digest(
        proposals[7]["proposal_sha256"],
        proposals[4]["proposal_sha256"],
    ):
        raise TypedToolError("reference conflict proposal changed")
    return proposals


def reference_support_record() -> Record:
    return workload.validate_support_record(
        {
            "family": MODEL_FAMILY_TOOL_EXECUTOR,
            "operation": MODEL_OPERATION_EXECUTE_ACTION,
            "input_kind": MODEL_INPUT_TYPED_RECORD,
            "output_kind": MODEL_OUTPUT_TOOL_RESULT,
            "numerical_policy": NUMERICAL_EXACT_INTEGER,
            "max_batch_items": 1,
            "max_input_features": 1,
            "max_output_dimensions": 1,
            "allowed_capabilities": CAPABILITY_BOUNDED_ADD,
        }
    )


def reference_claim() -> Record:
    return workload.claim(
        capsule_bytes=32,
        activation_bytes=8,
        partial_bytes=32,
        output_journal_bytes=32,
        staging_bytes=32,
        queue_slots=1,
    )


def reference_profile() -> Record:
    support = reference_support_record()
    descriptor = reference_descriptor()
    policy = reference_policy(descriptor)
    return workload.seal_profile(
        {
            "index": 0,
            "family": MODEL_FAMILY_TOOL_EXECUTOR,
            "operation": MODEL_OPERATION_EXECUTE_ACTION,
            "input_kind": MODEL_INPUT_TYPED_RECORD,
            "output_kind": MODEL_OUTPUT_TOOL_RESULT,
            "numerical_policy": NUMERICAL_EXACT_INTEGER,
            "adapter_abi": TOOL_WORKLOAD_ADAPTER_ABI,
            "lifecycle": workload.LIFECYCLE_STATELESS,
            "execution_unit": workload.EXECUTION_TOOL_CALL,
            "cancellation_boundary": workload.CANCELLATION_BEFORE_START,
            "publication_policy": workload.PUBLICATION_FINAL_ONLY,
            "correctness_gate": workload.CORRECTNESS_EXACT,
            "claim": reference_claim(),
            "support_sha256": workload.support_record_sha256(support),
            "artifact_sha256": _label("glacier typed tool bounded-add artifact v1"),
            "execution_plan_sha256": _label(
                "glacier typed tool bounded-add execution plan v1"
            ),
            "adapter_implementation_sha256": descriptor["implementation_sha256"],
            "correctness_sha256": _sha(
                b"glacier-typed-tool-correctness-v1\x00",
                descriptor["descriptor_sha256"],
                policy["policy_sha256"],
            ),
            "profile_sha256": ZERO_DIGEST,
        }
    )


def reference_plan() -> Record:
    profile = reference_profile()
    proposals = reference_proposals()
    item_specs = (
        (0, 0, 8, 1, workload.ACTION_CANCEL),
        (1, 0, 8, 2, workload.ACTION_TIMEOUT),
        (2, 0, 1, workload.ABSENT, workload.ACTION_NONE),
        (3, 1, 1, workload.ABSENT, workload.ACTION_NONE),
        (4, 2, 1, workload.ABSENT, workload.ACTION_NONE),
        (5, 3, 1, workload.ABSENT, workload.ACTION_NONE),
        (6, 4, 1, workload.ABSENT, workload.ACTION_NONE),
        (7, 5, 1, workload.ABSENT, workload.ACTION_NONE),
    )
    items: list[Record] = []
    for ordinal, arrival, work, action_step, action in item_specs:
        identity = ordinal + 1
        items.append(
            workload.seal_item(
                {
                    "ordinal": ordinal,
                    "profile_index": profile["index"],
                    "profile_sha256": profile["profile_sha256"],
                    "arrival_step": arrival,
                    "weight": 1,
                    "work_quanta": work,
                    "deadline_tick": 0,
                    "terminal_action_step": action_step,
                    "terminal_action": action,
                    "fairness_member": True,
                    "tenant_key": 0x8100 + identity,
                    "request_key": 0x8200 + identity,
                    "request_generation": 1,
                    "resource_owner_key": 0x8300 + identity,
                    "claim": deepcopy(profile["claim"]),
                    "input_binding_sha256": proposals[ordinal]["proposal_sha256"],
                    "item_sha256": ZERO_DIGEST,
                }
            )
        )
    return workload.validate_plan(
        {
            "seed": REFERENCE_SEED,
            "capacity": 3,
            "max_driver_steps": 32,
            "max_service_quanta": 32,
            "fairness_start_tick": 0,
            "fairness_end_tick": 16,
            "bank_epoch": REFERENCE_BANK_EPOCH,
            "scheduler_epoch": REFERENCE_SCHEDULER_EPOCH,
            "max_weight": 1,
            "max_projection_quanta": 64,
            "max_projection_operations": 256,
            "limits": workload.limits(
                host_bytes=1024 * 1024,
                capsule_bytes=1024 * 1024,
                kv_bytes=1024 * 1024,
                activation_bytes=1024 * 1024,
                partial_bytes=1024 * 1024,
                logits_bytes=1024 * 1024,
                output_journal_bytes=1024 * 1024,
                staging_bytes=1024 * 1024,
                device_bytes=1024 * 1024,
                io_bytes=1024 * 1024,
                queue_slots=3,
            ),
            "challenge": _label("glacier typed tool reference campaign v1"),
            "profiles": [profile],
            "items": items,
        }
    )


def _completed_service_roots(result: Mapping[str, Any]) -> dict[int, Digest]:
    roots: dict[int, Digest] = {}
    for record in result["trace"]:
        if (
            record["event_kind"] == workload.EVENT_SERVICE
            and record["remaining_after"] == 0
        ):
            ordinal = record["item_ordinal"]
            if ordinal in roots:
                raise TypedToolError("duplicate final service event")
            roots[ordinal] = _digest(
                record["scheduler_event_sha256"],
                "final service event",
            )
    return roots


def _resolve_completed_transaction(
    proposal: Any,
    descriptor: Any,
    arguments: Any,
    policy: Any,
    observed_before: int,
    execution_sequence: int,
    existing: tuple[Record, Record, Record, Record] | None,
    service_event_sha256: Digest,
) -> Record:
    """Reuse an exact commit first; policy-gate new or conflicting work."""

    proposal_value, descriptor_value, argument_value = validate_proposal_composition(
        proposal, descriptor, arguments
    )
    policy_value = validate_policy(policy)
    before = _i64(observed_before, "transaction counter")
    sequence = _u64(execution_sequence, "execution sequence")
    service_root = _digest(service_event_sha256, "service event")
    authorization: Record
    effect: Record | None = None
    ledger_entry: tuple[Record, Record, Record, Record] | None = None
    counter_after = before

    if existing is not None:
        (
            stored_proposal,
            stored_arguments,
            stored_authorization,
            stored_effect,
        ) = existing
        stored_proposal_value = validate_proposal(stored_proposal)
        if not hmac.compare_digest(
            stored_proposal_value["idempotency_key_sha256"],
            proposal_value["idempotency_key_sha256"],
        ):
            raise TypedToolError("idempotency ledger key mismatch")

        def validate_stored_commit() -> tuple[Record, Record, Record, Record]:
            composed_proposal, _, composed_arguments = validate_proposal_composition(
                stored_proposal_value,
                descriptor_value,
                stored_arguments,
            )
            composed_authorization, _, _ = validate_authorization_composition(
                stored_authorization,
                composed_proposal,
                policy_value,
            )
            composed_effect = validate_effect_composition(
                stored_effect,
                composed_proposal,
                composed_arguments,
                composed_authorization,
            )
            return (
                composed_proposal,
                composed_arguments,
                composed_authorization,
                composed_effect,
            )

        if hmac.compare_digest(
            stored_proposal_value["proposal_sha256"],
            proposal_value["proposal_sha256"],
        ):
            (
                _,
                stored_argument_value,
                stored_authorization_value,
                stored_effect_value,
            ) = validate_stored_commit()
            if stored_argument_value != argument_value:
                raise TypedToolError("reused proposal arguments drifted")
            authorization = stored_authorization_value
            effect = stored_effect_value
            disposition = DELIVERY_REUSED
            disposition_name = "reused"
        else:
            gate_authorization = authorize_bounded_add(
                proposal_value,
                descriptor_value,
                argument_value,
                policy_value,
                before,
            )
            if gate_authorization["kind"] == AUTHORIZATION_DENIED:
                authorization = gate_authorization
                disposition = DELIVERY_DENIED
                disposition_name = "denied"
            else:
                _, _, _, stored_effect_value = validate_stored_commit()
                authorization = deny_idempotency_conflict(
                    proposal_value,
                    policy_value,
                    before,
                )
                effect = stored_effect_value
                disposition = DELIVERY_CONFLICT
                disposition_name = "conflict"
    else:
        gate_authorization = authorize_bounded_add(
            proposal_value,
            descriptor_value,
            argument_value,
            policy_value,
            before,
        )
        authorization = gate_authorization
        if gate_authorization["kind"] == AUTHORIZATION_DENIED:
            disposition = DELIVERY_DENIED
            disposition_name = "denied"
        else:
            sequence = _u64(sequence + 1, "next execution sequence")
            effect = make_effect(
                sequence,
                proposal_value,
                argument_value,
                authorization,
            )
            counter_after = effect["after_value"]
            ledger_entry = (
                deepcopy(proposal_value),
                deepcopy(argument_value),
                deepcopy(authorization),
                deepcopy(effect),
            )
            disposition = DELIVERY_EXECUTED
            disposition_name = "executed"

    delivery = make_delivery(
        disposition,
        proposal_value,
        authorization,
        effect,
        service_root,
    )
    return {
        "authorization": deepcopy(authorization),
        "effect": deepcopy(effect),
        "delivery": delivery,
        "disposition": disposition,
        "disposition_name": disposition_name,
        "counter_after": counter_after,
        "execution_sequence": sequence,
        "ledger_entry": ledger_entry,
    }


def replay_tool_transactions(
    plan_value: Any | None = None,
    result_value: Any | None = None,
) -> Record:
    retained_plan = reference_plan()
    plan = workload.validate_plan(retained_plan if plan_value is None else plan_value)
    if plan != retained_plan:
        raise TypedToolError("tool campaign is not the retained reference plan")
    result = (
        workload.replay_plan(plan)
        if result_value is None
        else workload.validate_result_by_replay(plan, result_value)
    )
    descriptor = reference_descriptor()
    policy = reference_policy(descriptor)
    arguments = reference_arguments()
    proposals = reference_proposals(descriptor, arguments)
    if not (
        len(plan["items"])
        == len(result["outcomes"])
        == len(arguments)
        == len(proposals)
    ):
        raise TypedToolError("tool proposal count does not match plan")
    for item, proposal in zip(plan["items"], proposals):
        if not hmac.compare_digest(
            item["input_binding_sha256"],
            proposal["proposal_sha256"],
        ):
            raise TypedToolError("plan item does not bind its tool proposal")

    service_roots = _completed_service_roots(result)
    counter = 0
    execution_sequence = 0
    effects: dict[Digest, tuple[Record, Record, Record, Record]] = {}
    item_evidence: list[Record] = []
    dispositions: list[str] = []
    outcome_names = {
        workload.OUTCOME_COMPLETED: "completed",
        workload.OUTCOME_REJECTED: "rejected",
        workload.OUTCOME_CANCELLED: "cancelled",
        workload.OUTCOME_TIMED_OUT: "timed_out",
    }
    for item, outcome, argument, proposal in zip(
        plan["items"],
        result["outcomes"],
        arguments,
        proposals,
    ):
        ordinal = item["ordinal"]
        before = 0
        after = 0
        authorization: Record | None = None
        effect: Record | None = None
        delivery: Record | None = None
        disposition_name = "none"
        if outcome["kind"] == workload.OUTCOME_COMPLETED:
            before = counter
            service_root = service_roots.get(ordinal)
            if service_root is None:
                raise TypedToolError("completed tool item lacks final service")
            idempotency_key = proposal["idempotency_key_sha256"]
            transaction = _resolve_completed_transaction(
                proposal,
                descriptor,
                argument,
                policy,
                counter,
                execution_sequence,
                effects.get(idempotency_key),
                service_root,
            )
            authorization = transaction["authorization"]
            effect = transaction["effect"]
            delivery = transaction["delivery"]
            disposition_name = transaction["disposition_name"]
            counter = transaction["counter_after"]
            execution_sequence = transaction["execution_sequence"]
            if transaction["ledger_entry"] is not None:
                effects[idempotency_key] = transaction["ledger_entry"]
            after = counter
        elif ordinal in service_roots:
            raise TypedToolError("noncompleted tool item has final service")

        dispositions.append(disposition_name)
        item_evidence.append(
            {
                "ordinal": ordinal,
                "outcome": outcome_names[outcome["kind"]],
                "arguments": deepcopy(argument),
                "proposal": deepcopy(proposal),
                "authorization": deepcopy(authorization),
                "effect": deepcopy(effect),
                "delivery": deepcopy(delivery),
                "counter_before": before,
                "counter_after": after,
            }
        )

    if counter != 8 or execution_sequence != 2 or len(effects) != 2:
        raise TypedToolError("reference tool terminal state changed")
    if dispositions != [
        "none",
        "none",
        "executed",
        "none",
        "executed",
        "reused",
        "denied",
        "conflict",
    ]:
        raise TypedToolError("reference tool dispositions changed")
    return {
        "descriptor": descriptor,
        "policy": policy,
        "items": item_evidence,
        "dispositions": dispositions,
        "final_counter": counter,
        "effects": execution_sequence,
    }


def _validate_resource_claim(value: Any, where: str) -> Record:
    source = _strict_record(value, workload.CLAIM_FIELDS, where)
    return {
        name: _u64(source[name], f"{where}.{name}") for name in workload.CLAIM_FIELDS
    }


def _optional_receipt_root(
    value: Any,
    validator: Any,
    root_name: str,
    where: str,
) -> tuple[int, Digest]:
    if value is None:
        return 0, ZERO_DIGEST
    receipt = validator(value)
    return 1, _digest(receipt[root_name], where)


def item_evidence_sha256(value: Mapping[str, Any]) -> Digest:
    item = _strict_record(value, ITEM_EVIDENCE_FIELDS, "item evidence")
    claim = _validate_resource_claim(
        item["resource_claim"],
        "item evidence resource claim",
    )
    authorization_present, authorization_root = _optional_receipt_root(
        item["authorization"],
        validate_authorization,
        "authorization_sha256",
        "item evidence authorization",
    )
    effect_present, effect_root = _optional_receipt_root(
        item["effect"],
        validate_effect,
        "effect_sha256",
        "item evidence effect",
    )
    delivery_present, delivery_root = _optional_receipt_root(
        item["delivery"],
        validate_delivery,
        "delivery_sha256",
        "item evidence delivery",
    )
    return _sha(
        ITEM_EVIDENCE_DOMAIN,
        _le_u64(ITEM_EVIDENCE_ABI),
        _le_u64(_u64(item["ordinal"], "item evidence ordinal")),
        _le_u64(_u64(item["profile_index"], "item evidence profile index")),
        _le_u64(
            _enum(
                item["outcome"],
                {
                    workload.OUTCOME_COMPLETED,
                    workload.OUTCOME_REJECTED,
                    workload.OUTCOME_CANCELLED,
                    workload.OUTCOME_TIMED_OUT,
                },
                "item evidence outcome",
            )
        ),
        _le_u64(
            _enum(
                item["terminal_action"],
                {
                    workload.ACTION_NONE,
                    workload.ACTION_CANCEL,
                    workload.ACTION_TIMEOUT,
                },
                "item evidence terminal action",
            )
        ),
        _digest(item["profile_sha256"], "item evidence profile"),
        _digest(item["item_sha256"], "item evidence item"),
        validate_arguments(item["arguments"])["arguments_sha256"],
        validate_proposal(item["proposal"])["proposal_sha256"],
        _digest(item["descriptor_sha256"], "item evidence descriptor"),
        _digest(item["policy_sha256"], "item evidence policy"),
        _digest(
            item["resource_receipt_sha256"],
            "item evidence resource receipt",
            allow_zero=True,
        ),
        _le_u64(_u64(item["resource_bank_epoch"], "resource bank epoch")),
        _le_u64(_u64(item["resource_slot_index"], "resource slot index")),
        _le_u64(_u64(item["resource_generation"], "resource generation")),
        _le_u64(_u64(item["resource_owner_key"], "resource owner key")),
        *(_le_u64(claim[name]) for name in workload.CLAIM_FIELDS),
        _le_u64(_u64(item["resource_integrity"], "resource integrity")),
        _le_u64(authorization_present),
        authorization_root,
        _le_u64(effect_present),
        effect_root,
        _le_u64(delivery_present),
        delivery_root,
        _digest(
            item["final_service_event_sha256"],
            "final service event",
            allow_zero=True,
        ),
        _le_i64(_i64(item["counter_before"], "counter before")),
        _le_i64(_i64(item["counter_after"], "counter after")),
        _digest(item["admission_trace_sha256"], "admission trace"),
        _digest(item["terminal_trace_sha256"], "terminal trace"),
        _digest(item["driver_outcome_sha256"], "driver outcome"),
    )


def validate_item_evidence(value: Any) -> Record:
    item = _strict_record(value, ITEM_EVIDENCE_FIELDS, "item evidence")
    arguments = validate_arguments(item["arguments"])
    proposal = validate_proposal(item["proposal"])
    descriptor_root = _digest(
        item["descriptor_sha256"],
        "item evidence descriptor",
    )
    policy_root = _digest(item["policy_sha256"], "item evidence policy")
    if not hmac.compare_digest(
        proposal["arguments_sha256"],
        arguments["arguments_sha256"],
    ) or not hmac.compare_digest(
        proposal["descriptor_sha256"],
        descriptor_root,
    ):
        raise TypedToolError("item evidence proposal composition mismatch")

    _u64(item["ordinal"], "item evidence ordinal")
    _u64(item["profile_index"], "item evidence profile index")
    _enum(
        item["outcome"],
        {
            workload.OUTCOME_COMPLETED,
            workload.OUTCOME_REJECTED,
            workload.OUTCOME_CANCELLED,
            workload.OUTCOME_TIMED_OUT,
        },
        "item evidence outcome",
    )
    _enum(
        item["terminal_action"],
        {
            workload.ACTION_NONE,
            workload.ACTION_CANCEL,
            workload.ACTION_TIMEOUT,
        },
        "item evidence terminal action",
    )
    for name in (
        "profile_sha256",
        "item_sha256",
        "admission_trace_sha256",
        "terminal_trace_sha256",
        "driver_outcome_sha256",
    ):
        _digest(item[name], f"item evidence {name}")
    _digest(
        item["resource_receipt_sha256"],
        "item evidence resource receipt",
        allow_zero=True,
    )
    for name in (
        "resource_bank_epoch",
        "resource_slot_index",
        "resource_generation",
        "resource_owner_key",
        "resource_integrity",
    ):
        _u64(item[name], f"item evidence {name}")
    _validate_resource_claim(
        item["resource_claim"],
        "item evidence resource claim",
    )
    _i64(item["counter_before"], "counter before")
    _i64(item["counter_after"], "counter after")

    authorization = (
        None
        if item["authorization"] is None
        else validate_authorization(item["authorization"])
    )
    effect = None if item["effect"] is None else validate_effect(item["effect"])
    delivery = None if item["delivery"] is None else validate_delivery(item["delivery"])
    final_root = _digest(
        item["final_service_event_sha256"],
        "final service event",
        allow_zero=True,
    )
    if delivery is None:
        if authorization is not None or effect is not None:
            raise TypedToolError("undelivered item retains tool receipts")
    else:
        if authorization is None:
            raise TypedToolError("delivery lacks authorization")
        if not hmac.compare_digest(
            authorization["proposal_sha256"],
            proposal["proposal_sha256"],
        ) or not hmac.compare_digest(
            authorization["policy_sha256"],
            policy_root,
        ):
            raise TypedToolError("item authorization composition mismatch")
        validate_delivery_composition(
            delivery,
            proposal,
            authorization,
            effect,
            final_root,
        )
        if delivery["disposition"] in (
            DELIVERY_EXECUTED,
            DELIVERY_REUSED,
        ):
            assert effect is not None
            validate_effect_composition(
                effect,
                proposal,
                arguments,
                authorization,
            )
    expected = item_evidence_sha256(item)
    if not hmac.compare_digest(
        _digest(item["record_sha256"], "item evidence root"),
        expected,
    ):
        raise TypedToolError("item evidence root mismatch")
    return deepcopy(item)


def item_evidence_section_sha256(items: Any) -> Digest:
    if not isinstance(items, list):
        raise TypedToolError("item evidence section is not a list")
    roots = [validate_item_evidence(item)["record_sha256"] for item in items]
    return _sha(
        ITEM_EVIDENCE_SECTION_DOMAIN,
        _le_u64(_u64(len(items), "item evidence count")),
        *roots,
    )


def evidence_summary_sha256(value: Mapping[str, Any]) -> Digest:
    summary = _strict_record(
        value,
        EVIDENCE_SUMMARY_FIELDS,
        "evidence summary",
    )
    unsigned_names = (
        "profile_count",
        "item_count",
        "admitted",
        "rejected",
        "completed",
        "cancelled",
        "timed_out",
        "tool_calls",
        "deliveries",
        "executed",
        "reused",
        "denied",
        "conflicts",
        "effects",
        "model_successful_commits",
        "model_releases",
        "model_final_active_reservations",
        "model_final_committed_receipts",
    )
    return _sha(
        EVIDENCE_SUMMARY_DOMAIN,
        _le_u64(EVIDENCE_SUMMARY_ABI),
        *(
            _le_u64(_u64(summary[name], f"evidence summary {name}"))
            for name in unsigned_names[:14]
        ),
        _le_i64(_i64(summary["initial_counter"], "initial counter")),
        _le_i64(_i64(summary["final_counter"], "final counter")),
        *(
            _le_u64(_u64(summary[name], f"evidence summary {name}"))
            for name in unsigned_names[14:]
        ),
        _le_u64(int(_bool(summary["harness_open"], "harness open"))),
        _le_u64(_u64(summary["pending_prepared"], "pending prepared")),
        _le_u64(_u64(summary["pending_armed"], "pending armed")),
        _le_u64(
            int(
                _bool(
                    summary["zero_model_ownership"],
                    "zero model ownership",
                )
            )
        ),
        _le_u64(
            int(
                _bool(
                    summary["zero_harness_authority"],
                    "zero harness authority",
                )
            )
        ),
        _le_u64(
            int(
                _bool(
                    summary["zero_orphan_ownership"],
                    "zero orphan ownership",
                )
            )
        ),
    )


def validate_evidence_summary(value: Any) -> Record:
    summary = _strict_record(
        value,
        EVIDENCE_SUMMARY_FIELDS,
        "evidence summary",
    )
    expected = evidence_summary_sha256(summary)
    if not hmac.compare_digest(
        _digest(summary["summary_sha256"], "evidence summary root"),
        expected,
    ):
        raise TypedToolError("evidence summary root mismatch")
    return deepcopy(summary)


def evidence_sha256(value: Mapping[str, Any]) -> Digest:
    evidence = _strict_record(value, EVIDENCE_FIELDS, "evidence")
    descriptor = validate_descriptor(evidence["descriptor"])
    policy = validate_policy(evidence["policy"])
    items = evidence["items"]
    if not isinstance(items, list):
        raise TypedToolError("evidence items are not a list")
    item_roots = [validate_item_evidence(item)["record_sha256"] for item in items]
    validate_evidence_summary(evidence["summary"])
    return _sha(
        EVIDENCE_DOMAIN,
        _le_u64(EVIDENCE_ABI),
        _digest(evidence["plan_sha256"], "evidence plan"),
        _digest(evidence["driver_result_sha256"], "evidence driver result"),
        _digest(evidence["driver_outcome_sha256"], "evidence driver outcome"),
        _digest(evidence["driver_trace_sha256"], "evidence driver trace"),
        _digest(evidence["driver_summary_sha256"], "evidence driver summary"),
        descriptor["descriptor_sha256"],
        policy["policy_sha256"],
        _digest(evidence["item_section_sha256"], "item evidence section"),
        _digest(evidence["evidence_summary_sha256"], "evidence summary"),
        _le_u64(_u64(len(items), "evidence item count")),
        *item_roots,
    )


def validate_evidence_structure(value: Any) -> Record:
    evidence = _strict_record(value, EVIDENCE_FIELDS, "evidence")
    descriptor = validate_descriptor(evidence["descriptor"])
    policy = validate_policy(evidence["policy"])
    if not hmac.compare_digest(
        descriptor["descriptor_sha256"],
        policy["descriptor_sha256"],
    ):
        raise TypedToolError("evidence descriptor/policy mismatch")
    items = evidence["items"]
    if not isinstance(items, list):
        raise TypedToolError("evidence items are not a list")
    validated_items = [validate_item_evidence(item) for item in items]
    summary = validate_evidence_summary(evidence["summary"])
    if not hmac.compare_digest(
        _digest(evidence["item_section_sha256"], "item evidence section"),
        item_evidence_section_sha256(validated_items),
    ):
        raise TypedToolError("item evidence section root mismatch")
    if not hmac.compare_digest(
        _digest(evidence["evidence_summary_sha256"], "evidence summary"),
        summary["summary_sha256"],
    ):
        raise TypedToolError("evidence summary binding mismatch")
    if not hmac.compare_digest(
        _digest(evidence["evidence_sha256"], "evidence root"),
        evidence_sha256(evidence),
    ):
        raise TypedToolError("evidence root mismatch")
    for name in (
        "plan_sha256",
        "driver_result_sha256",
        "driver_outcome_sha256",
        "driver_trace_sha256",
        "driver_summary_sha256",
    ):
        _digest(evidence[name], f"evidence {name}")
    return deepcopy(evidence)


def _reference_resource_evidence(
    plan: Mapping[str, Any],
    item: Mapping[str, Any],
    outcome: Mapping[str, Any],
) -> Record:
    if outcome["kind"] == workload.OUTCOME_REJECTED:
        return {
            "resource_receipt_sha256": ZERO_DIGEST,
            "resource_bank_epoch": 0,
            "resource_slot_index": 0,
            "resource_generation": 0,
            "resource_owner_key": 0,
            "resource_claim": workload.claim(),
            "resource_integrity": 0,
        }
    claim = deepcopy(item["claim"])
    bank_epoch = plan["bank_epoch"]
    slot_index = outcome["scheduler_slot_index"]
    generation = outcome["scheduler_slot_generation"]
    owner_key = item["resource_owner_key"]
    integrity = workload._receipt_integrity(
        bank_epoch,
        slot_index,
        generation,
        owner_key,
        claim,
    )
    receipt = {
        "bank_epoch": bank_epoch,
        "slot_index": slot_index,
        "generation": generation,
        "owner_key": owner_key,
        "claim": claim,
        "integrity": integrity,
    }
    return {
        "resource_receipt_sha256": workload.resource_receipt_sha256(receipt),
        "resource_bank_epoch": bank_epoch,
        "resource_slot_index": slot_index,
        "resource_generation": generation,
        "resource_owner_key": owner_key,
        "resource_claim": claim,
        "resource_integrity": integrity,
    }


def _build_evidence_from_validated(
    plan: Record,
    result: Record,
) -> Record:
    tool_result = replay_tool_transactions(plan, result)
    descriptor = tool_result["descriptor"]
    policy = tool_result["policy"]
    service_roots = _completed_service_roots(result)
    evidence_items: list[Record] = []
    if not (
        len(plan["items"])
        == len(result["outcomes"])
        == len(tool_result["items"])
    ):
        raise TypedToolError("tool evidence item count mismatch")
    for item, outcome, tool_item in zip(
        plan["items"],
        result["outcomes"],
        tool_result["items"],
    ):
        completed = outcome["kind"] == workload.OUTCOME_COMPLETED
        resource = _reference_resource_evidence(plan, item, outcome)
        evidence_item: Record = {
            "ordinal": item["ordinal"],
            "profile_index": item["profile_index"],
            "outcome": outcome["kind"],
            "terminal_action": outcome["terminal_action"],
            "profile_sha256": item["profile_sha256"],
            "item_sha256": item["item_sha256"],
            "arguments": deepcopy(tool_item["arguments"]),
            "proposal": deepcopy(tool_item["proposal"]),
            "descriptor_sha256": descriptor["descriptor_sha256"],
            "policy_sha256": policy["policy_sha256"],
            **resource,
            "authorization": deepcopy(tool_item["authorization"]),
            "effect": deepcopy(tool_item["effect"]),
            "delivery": deepcopy(tool_item["delivery"]),
            "final_service_event_sha256": (
                service_roots[item["ordinal"]] if completed else ZERO_DIGEST
            ),
            "counter_before": tool_item["counter_before"],
            "counter_after": tool_item["counter_after"],
            "admission_trace_sha256": outcome["admission_trace_sha256"],
            "terminal_trace_sha256": outcome["terminal_trace_sha256"],
            "driver_outcome_sha256": outcome["record_sha256"],
            "record_sha256": ZERO_DIGEST,
        }
        evidence_item["record_sha256"] = item_evidence_sha256(evidence_item)
        evidence_items.append(validate_item_evidence(evidence_item))

    driver_summary = result["summary"]
    model_zero = (
        driver_summary["zero_orphan_ownership"]
        and driver_summary["final_active_reservations"] == 0
        and driver_summary["final_committed_receipts"] == 0
    )
    counts = {
        name: tool_result["dispositions"].count(name)
        for name in ("executed", "reused", "denied", "conflict")
    }
    summary: Record = {
        "profile_count": len(plan["profiles"]),
        "item_count": len(plan["items"]),
        "admitted": driver_summary["admitted"],
        "rejected": driver_summary["rejected"],
        "completed": driver_summary["completed"],
        "cancelled": driver_summary["cancelled"],
        "timed_out": driver_summary["timed_out"],
        "tool_calls": driver_summary["final_service_callbacks"],
        "deliveries": sum(value != "none" for value in tool_result["dispositions"]),
        "executed": counts["executed"],
        "reused": counts["reused"],
        "denied": counts["denied"],
        "conflicts": counts["conflict"],
        "effects": tool_result["effects"],
        "initial_counter": 0,
        "final_counter": tool_result["final_counter"],
        "model_successful_commits": driver_summary["successful_commits"],
        "model_releases": driver_summary["releases"],
        "model_final_active_reservations": driver_summary["final_active_reservations"],
        "model_final_committed_receipts": driver_summary["final_committed_receipts"],
        "harness_open": False,
        "pending_prepared": 0,
        "pending_armed": 0,
        "zero_model_ownership": model_zero,
        "zero_harness_authority": True,
        "zero_orphan_ownership": model_zero,
        "summary_sha256": ZERO_DIGEST,
    }
    summary["summary_sha256"] = evidence_summary_sha256(summary)
    summary = validate_evidence_summary(summary)
    evidence: Record = {
        "plan_sha256": result["plan_sha256"],
        "driver_result_sha256": result["result_sha256"],
        "driver_outcome_sha256": result["outcome_sha256"],
        "driver_trace_sha256": result["trace_sha256"],
        "driver_summary_sha256": result["summary_sha256"],
        "descriptor": deepcopy(descriptor),
        "policy": deepcopy(policy),
        "item_section_sha256": item_evidence_section_sha256(evidence_items),
        "evidence_summary_sha256": summary["summary_sha256"],
        "items": evidence_items,
        "summary": summary,
        "evidence_sha256": ZERO_DIGEST,
    }
    evidence["evidence_sha256"] = evidence_sha256(evidence)
    return validate_evidence_structure(evidence)


def build_evidence(
    plan_value: Any | None = None,
    result_value: Any | None = None,
) -> Record:
    plan = workload.validate_plan(
        reference_plan() if plan_value is None else plan_value
    )
    if plan != reference_plan():
        raise TypedToolError("evidence plan is not the retained reference")
    result = (
        workload.replay_plan(plan)
        if result_value is None
        else workload.validate_result_by_replay(plan, result_value)
    )
    return _build_evidence_from_validated(plan, result)


def validate_evidence_by_replay(
    plan_value: Any,
    result_value: Any,
    evidence_value: Any,
) -> Record:
    plan = workload.validate_plan(plan_value)
    if plan != reference_plan():
        raise TypedToolError("evidence plan is not the retained reference")
    result = workload.validate_result_by_replay(plan, result_value)
    evidence = validate_evidence_structure(evidence_value)
    expected = _build_evidence_from_validated(plan, result)
    if evidence != expected:
        raise TypedToolError("evidence differs from semantic replay")
    return deepcopy(evidence)


def build_report() -> Record:
    """Recompute the canonical typed-tool report from first principles."""

    plan = reference_plan()
    result = workload.replay_plan(plan)
    evidence = _build_evidence_from_validated(plan, result)
    plan_wire = workload.encode_plan(plan)
    driver_summary: Record = {}
    for name in workload.DRIVER_REPORT_SUMMARY_FIELDS:
        if name == "peak":
            driver_summary[name] = {
                field: result["summary"]["peak"][field] for field in REPORT_PEAK_FIELDS
            }
        else:
            driver_summary[name] = deepcopy(result["summary"][name])
    evidence_summary = {
        name: deepcopy(evidence["summary"][name])
        for name in EVIDENCE_REPORT_SUMMARY_FIELDS
    }
    try:
        outcomes = [
            workload.OUTCOME_NAMES[outcome["kind"]] for outcome in result["outcomes"]
        ]
    except KeyError as error:
        raise TypedToolError("unknown reference outcome") from error
    report: Record = {
        "schema": REPORT_SCHEMA,
        "plan_abi": f"{workload.PLAN_ABI:016x}",
        "profile_abi": f"{workload.PROFILE_ABI:016x}",
        "item_abi": f"{workload.ITEM_ABI:016x}",
        "driver_result_abi": f"{workload.RESULT_ABI:016x}",
        "driver_outcome_abi": f"{workload.OUTCOME_ABI:016x}",
        "driver_trace_abi": f"{workload.TRACE_ABI:016x}",
        "driver_summary_abi": f"{workload.SUMMARY_ABI:016x}",
        "tool_descriptor_abi": f"{DESCRIPTOR_ABI:016x}",
        "tool_arguments_abi": f"{BOUNDED_ADD_ARGUMENTS_ABI:016x}",
        "tool_proposal_abi": f"{PROPOSAL_ABI:016x}",
        "tool_policy_abi": f"{POLICY_ABI:016x}",
        "tool_authorization_abi": f"{AUTHORIZATION_ABI:016x}",
        "tool_effect_abi": f"{EFFECT_ABI:016x}",
        "tool_delivery_abi": f"{DELIVERY_ABI:016x}",
        "evidence_abi": f"{EVIDENCE_ABI:016x}",
        "item_evidence_abi": f"{ITEM_EVIDENCE_ABI:016x}",
        "evidence_summary_abi": f"{EVIDENCE_SUMMARY_ABI:016x}",
        "profile_count": len(plan["profiles"]),
        "item_count": len(plan["items"]),
        "trace_count": len(result["trace"]),
        "plan_wire_bytes": len(plan_wire),
        "plan_wire_sha256": hashlib.sha256(plan_wire).hexdigest(),
        "plan_sha256": result["plan_sha256"].hex(),
        "outcome_sha256": result["outcome_sha256"].hex(),
        "trace_sha256": result["trace_sha256"].hex(),
        "summary_sha256": result["summary_sha256"].hex(),
        "result_sha256": result["result_sha256"].hex(),
        "descriptor_sha256": evidence["descriptor"]["descriptor_sha256"].hex(),
        "policy_sha256": evidence["policy"]["policy_sha256"].hex(),
        "item_section_sha256": evidence["item_section_sha256"].hex(),
        "evidence_summary_sha256": evidence["evidence_summary_sha256"].hex(),
        "evidence_sha256": evidence["evidence_sha256"].hex(),
        "outcomes": outcomes,
        "dispositions": replay_tool_transactions(
            plan,
            result,
        )["dispositions"],
        "driver_summary": driver_summary,
        "evidence_summary": evidence_summary,
    }
    if tuple(report) != REPORT_FIELDS:
        raise TypedToolError("report field order changed")
    for name, expected in REFERENCE_REPORT_ROOTS.items():
        if report[name] != expected:
            raise TypedToolError(f"retained {name} changed")
    payload = render_report(report).encode("ascii")
    if (
        len(payload) != REFERENCE_REPORT_BYTES
        or hashlib.sha256(payload).hexdigest() != REFERENCE_REPORT_SHA256
    ):
        raise TypedToolError("retained canonical report bytes changed")
    return report


def render_report(report: Record | None = None) -> str:
    """Render exactly one compact canonical ASCII JSON line."""

    if report is None:
        report = build_report()
    try:
        return (
            json.dumps(
                report,
                ensure_ascii=True,
                allow_nan=False,
                separators=(",", ":"),
            )
            + "\n"
        )
    except (TypeError, ValueError) as error:
        raise TypedToolError("report is not JSON representable") from error


def validate_report(value: Any) -> Record:
    """Require exact equality with independent replay and retained evidence."""

    expected = build_report()
    if (
        not isinstance(value, dict)
        or value != expected
        or render_report(value) != render_report(expected)
    ):
        raise TypedToolError("report contradicts typed-tool conformance replay")
    return deepcopy(expected)


def _load_json_exact(encoded: bytes, where: str) -> Record:
    if (
        type(encoded) is not bytes
        or not 0 < len(encoded) <= MAXIMUM_JSON_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise TypedToolError(f"{where} is not one canonical line")

    def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
        value: Record = {}
        for key, item in pairs:
            if key in value:
                raise TypedToolError(f"{where} contains duplicate fields")
            value[key] = item
        return value

    def invalid_number(_: str) -> None:
        raise TypedToolError(f"{where} contains a non-integer number")

    try:
        decoded = json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=object_pairs,
            parse_constant=invalid_number,
            parse_float=invalid_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TypedToolError(f"{where} is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise TypedToolError(f"{where} is not a JSON object")
    if render_report(decoded).encode("ascii") != encoded:
        raise TypedToolError(f"{where} is not canonical JSON")
    return decoded


def write_report(
    path_value: str | os.PathLike[str],
    report_value: Record | None = None,
) -> None:
    """Atomically replace a retained report after exact validation."""

    report = build_report() if report_value is None else validate_report(report_value)
    payload = render_report(report).encode("ascii")
    path = Path(path_value)
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(file_descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def verify_runner(runner: Path | list[str], fixture: Path) -> None:
    """Fail closed unless fixture, native runner, and oracle agree exactly."""

    if isinstance(runner, Path):
        runner_argv = [str(runner)]
    elif runner and all(isinstance(value, str) and value for value in runner):
        runner_argv = list(runner)
    else:
        raise TypedToolError("invalid typed-tool runner command")
    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = _load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise TypedToolError("retained fixture is stale")
    completed = subprocess.run(
        runner_argv,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if completed.returncode != 0 or completed.stderr:
        raise TypedToolError("typed-tool runner failed")
    runner_value = _load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise TypedToolError("typed-tool runner contradicts Python oracle")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify retained W4b typed-tool conformance",
    )
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verify_runner(args.runner, args.fixture)
    except (OSError, subprocess.SubprocessError, TypedToolError) as error:
        print(f"typed-tool-conformance: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
