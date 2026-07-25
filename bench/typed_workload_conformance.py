"""Independent W4a typed-workload plan and logical replay oracle.

This module reimplements the portable plan ABI, LaneWeave logical scheduling,
ResourceBank receipt projection, and driver semantic roots. It never imports
or executes Zig and does not measure wall-clock performance, memory residency,
device utilization, or model quality.
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
from collections.abc import Callable, Mapping, Sequence
from copy import deepcopy
from pathlib import Path
from typing import Any


class TypedWorkloadError(ValueError):
    """The plan, wire, JSON document, or logical evidence is invalid."""


Record = dict[str, Any]
FixtureFactory = Callable[[], Record]
ResultObserver = Callable[[Record, Record], None]
EvidenceVerifier = Callable[[Record, Record, Any], None]

U64_MAX = (1 << 64) - 1
U32_MAX = (1 << 32) - 1
U16_MAX = (1 << 16) - 1
ABSENT = U64_MAX
ZERO_DIGEST = bytes(32)

PLAN_ABI = 0x4757545750000001
PROFILE_ABI = 0x4757545746000001
ITEM_ABI = 0x4757545749000001
SUPPORT_RECORD_ABI = 0x4757545753000001

RESULT_ABI = 0x4754574452000001
OUTCOME_ABI = 0x475457444F000001
TRACE_ABI = 0x4754574454000001
SUMMARY_ABI = 0x4754574453000001

LANE_WEAVE_ABI = 0x474C575100000001
LANE_WEAVE_EVENT_ABI = 0x474C574500000001
RESOURCE_BANK_ABI = 0x4752424B00000001

EVIDENCE_ABI = 0x4754505745000001
ITEM_EVIDENCE_ABI = 0x4754505749000001
EVIDENCE_SUMMARY_ABI = 0x4754505753000001

PLAN_MAGIC = b"GWTWP1\x00\x00"
PLAN_HEADER_BYTES = 384
PROFILE_RECORD_BYTES = 368
ITEM_RECORD_BYTES = 280
PLAN_FOOTER_BYTES = 32
ALLOWED_FLAGS = 0

MAXIMUM_PROFILES = 16
MAXIMUM_ITEMS = 16
MAXIMUM_DRIVER_STEPS = 512
MAXIMUM_SERVICE_QUANTA = 256
MAXIMUM_TRACE_RECORDS = 512
MAXIMUM_PLAN_BYTES = (
    PLAN_HEADER_BYTES
    + MAXIMUM_PROFILES * PROFILE_RECORD_BYTES
    + MAXIMUM_ITEMS * ITEM_RECORD_BYTES
    + PLAN_FOOTER_BYTES
)
MAXIMUM_JSON_BYTES = 4 * 1024 * 1024

PLAN_SCHEMA = "glacier.typed-workload-plan/v1"
RESULT_SCHEMA = "glacier.typed-workload-result/v1"
CONFORMANCE_SCHEMA = "glacier.typed-workload-conformance/v1"

REFERENCE_ITEM_SECTION_SHA256 = (
    "020b3af8abd9ef97e7d5871d17fb2e51f51d0ec1ce0e49d7e9256b2cf137703a"
)
REFERENCE_EVIDENCE_SUMMARY_SHA256 = (
    "a6174f75ae22ec3bec57ee184f69fb116a6bd57d8c16d487705bc64c78f23660"
)
REFERENCE_EVIDENCE_SHA256 = (
    "fcfbacf21be1e549f2402c9bf0a1d7bf94b6252a4a46f6f5ca8f0f6f0d6fe1f2"
)

SUPPORT_RECORD_DOMAIN = b"glacier-typed-workload-support-record-v1\x00"
PROFILE_DOMAIN = b"glacier-typed-workload-profile-v1\x00"
ITEM_DOMAIN = b"glacier-typed-workload-item-v1\x00"
PROFILE_SECTION_DOMAIN = b"glacier-typed-workload-profile-section-v1\x00"
ITEM_SECTION_DOMAIN = b"glacier-typed-workload-item-section-v1\x00"
PLAN_DOMAIN = b"glacier-typed-workload-plan-v1\x00"
PLAN_WIRE_DOMAIN = b"glacier-typed-workload-plan-wire-v1\x00"

OUTCOME_DOMAIN = b"glacier-typed-workload-driver-outcome-v1\x00"
OUTCOME_SECTION_DOMAIN = b"glacier-typed-workload-driver-outcome-section-v1\x00"
TRACE_RECORD_DOMAIN = b"glacier-typed-workload-driver-trace-record-v1\x00"
TRACE_DOMAIN = b"glacier-typed-workload-driver-trace-v1\x00"
SUMMARY_DOMAIN = b"glacier-typed-workload-driver-summary-v1\x00"
RESULT_DOMAIN = b"glacier-typed-workload-driver-result-v1\x00"

LANE_INITIAL_ROOT_DOMAIN = b"glacier-lane-weave-qos-root-v1\x00"
LANE_STATE_DOMAIN = b"glacier-lane-weave-qos-state-v1\x00"
LANE_EVENT_DOMAIN = b"glacier-lane-weave-qos-event-v1\x00"
LANE_RECEIPT_DOMAIN = b"glacier-lane-weave-qos-resource-receipt-v1\x00"
RESOURCE_RECEIPT_INTEGRITY_DOMAIN = 0x7265636569707431

ACTION_NONE = 0
ACTION_CANCEL = 1
ACTION_TIMEOUT = 2

OUTCOME_COMPLETED = 1
OUTCOME_REJECTED = 2
OUTCOME_CANCELLED = 3
OUTCOME_TIMED_OUT = 4

REJECTION_NONE = 0
REJECTION_NO_SLOT = 1
REJECTION_DUPLICATE_TENANT = 2
REJECTION_RESOURCE_LIMIT = 3
REJECTION_PROJECTION_LIMIT = 4
REJECTION_DEADLINE_INFEASIBLE = 5

EVENT_ADMISSION_ACCEPTED = 0
EVENT_ADMISSION_REJECTED = 1
EVENT_SERVICE = 2
EVENT_CANCEL = 3
EVENT_RETIRE = 4
EVENT_CLOSE = 5

SLOT_FREE = 0
SLOT_ACTIVE = 1
SLOT_FINISHED = 2

LIFECYCLE_STATELESS = 1
LIFECYCLE_STATEFUL = 2

EXECUTION_OPERATION = 1
EXECUTION_TOKEN = 2
EXECUTION_FRAME = 3
EXECUTION_SAMPLE = 4
EXECUTION_DIFFUSION_STEP = 5
EXECUTION_PROVIDER_CALL = 6
EXECUTION_TOOL_CALL = 7

CANCELLATION_BEFORE_START = 1
CANCELLATION_BETWEEN_UNITS = 2
CANCELLATION_COOPERATIVE = 3
CANCELLATION_TERMINAL_ONLY = 4

PUBLICATION_FINAL_ONLY = 1
PUBLICATION_INCREMENTAL = 2
PUBLICATION_TRANSACTIONAL = 3

CORRECTNESS_EXACT = 1
CORRECTNESS_BOUNDED_NUMERIC = 2
CORRECTNESS_STRUCTURAL = 3
CORRECTNESS_EXTERNAL_VERIFIER = 4

MODEL_FAMILIES = frozenset(range(1, 18))
MODEL_OPERATIONS = frozenset(range(1, 14))
MODEL_INPUT_KINDS = frozenset(range(1, 8))
MODEL_OUTPUT_KINDS = frozenset(range(1, 12))
NUMERICAL_POLICIES = frozenset(range(1, 5))
LIFECYCLES = frozenset((LIFECYCLE_STATELESS, LIFECYCLE_STATEFUL))
EXECUTION_UNITS = frozenset(range(EXECUTION_OPERATION, EXECUTION_TOOL_CALL + 1))
CANCELLATION_BOUNDARIES = frozenset(
    range(CANCELLATION_BEFORE_START, CANCELLATION_TERMINAL_ONLY + 1)
)
PUBLICATION_POLICIES = frozenset(
    range(PUBLICATION_FINAL_ONLY, PUBLICATION_TRANSACTIONAL + 1)
)
CORRECTNESS_GATES = frozenset(
    range(CORRECTNESS_EXACT, CORRECTNESS_EXTERNAL_VERIFIER + 1)
)
TERMINAL_ACTIONS = frozenset((ACTION_NONE, ACTION_CANCEL, ACTION_TIMEOUT))

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
HOST_CLAIM_FIELDS = CLAIM_FIELDS[:7]
LIMIT_FIELDS = ("host_bytes", *CLAIM_FIELDS)

SUPPORT_RECORD_FIELDS = (
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

PROFILE_SCALAR_FIELDS = (
    "index",
    "family",
    "operation",
    "input_kind",
    "output_kind",
    "numerical_policy",
    "adapter_abi",
    "lifecycle",
    "execution_unit",
    "cancellation_boundary",
    "publication_policy",
    "correctness_gate",
)
PROFILE_DIGEST_FIELDS = (
    "support_sha256",
    "artifact_sha256",
    "execution_plan_sha256",
    "adapter_implementation_sha256",
    "correctness_sha256",
    "profile_sha256",
)
PROFILE_FIELDS = (*PROFILE_SCALAR_FIELDS, "claim", *PROFILE_DIGEST_FIELDS)

ITEM_SCALAR_FIELDS = (
    "ordinal",
    "profile_index",
    "arrival_step",
    "weight",
    "work_quanta",
    "deadline_tick",
    "terminal_action_step",
    "terminal_action",
    "fairness_member",
    "tenant_key",
    "request_key",
    "request_generation",
    "resource_owner_key",
)
ITEM_DIGEST_FIELDS = (
    "profile_sha256",
    "input_binding_sha256",
    "item_sha256",
)
ITEM_FIELDS = (
    "ordinal",
    "profile_index",
    "profile_sha256",
    *ITEM_SCALAR_FIELDS[2:],
    "claim",
    "input_binding_sha256",
    "item_sha256",
)

PLAN_SCALAR_FIELDS = (
    "seed",
    "capacity",
    "max_driver_steps",
    "max_service_quanta",
    "fairness_start_tick",
    "fairness_end_tick",
    "bank_epoch",
    "scheduler_epoch",
    "max_weight",
    "max_projection_quanta",
    "max_projection_operations",
)
PLAN_FIELDS = (*PLAN_SCALAR_FIELDS, "limits", "challenge", "profiles", "items")

OUTCOME_SCALAR_FIELDS = (
    "ordinal",
    "profile_index",
    "kind",
    "rejection_reason",
    "terminal_action",
    "scheduler_slot_index",
    "scheduler_slot_generation",
    "admitted_step",
    "first_service_step",
    "terminal_step",
    "served_quanta",
    "maximum_wait_quanta",
)
OUTCOME_FIELDS = (
    "ordinal",
    "item_sha256",
    "profile_index",
    "profile_sha256",
    *OUTCOME_SCALAR_FIELDS[2:],
    "admission_trace_sha256",
    "terminal_trace_sha256",
    "record_sha256",
)

TRACE_SCALAR_FIELDS = (
    "sequence",
    "driver_step",
    "item_ordinal",
    "profile_index",
    "event_kind",
    "scheduler_event_sequence",
    "rejection_reason",
    "terminal_action",
    "logical_tick_before",
    "logical_tick_after",
    "remaining_before",
    "remaining_after",
    "wait_quanta",
    "active_after",
    "finished_after",
)
TRACE_FIELDS = (
    *TRACE_SCALAR_FIELDS,
    "scheduler_event_sha256",
    "record_sha256",
)

SUMMARY_SCALAR_FIELDS = (
    "profile_count",
    "item_count",
    "attempted",
    "admitted",
    "rejected",
    "completed",
    "cancelled",
    "timed_out",
    "service_quanta",
    "driver_steps",
    "final_logical_tick",
    "maximum_live_receipts",
    "peak_host_bytes",
    "maximum_wait_quanta",
    "maximum_service_gap",
    "fairness_cross_product_error",
    "bind_callbacks",
    "cancel_callbacks",
    "service_callbacks",
    "final_service_callbacks",
    "retire_callbacks",
    "final_active",
    "final_finished",
    "final_active_reservations",
    "final_committed_receipts",
    "successful_commits",
    "releases",
    "bank_cancellations",
    "bank_rejected_capacity",
    "bank_rejected_slots",
    "zero_orphan_ownership",
)
SUMMARY_FIELDS = (*SUMMARY_SCALAR_FIELDS, "peak")
RESULT_FIELDS = (
    "plan_sha256",
    "outcome_sha256",
    "trace_sha256",
    "summary_sha256",
    "result_sha256",
    "outcomes",
    "trace",
    "summary",
)

DRIVER_REPORT_SUMMARY_FIELDS = (
    "profile_count",
    "item_count",
    "attempted",
    "admitted",
    "rejected",
    "completed",
    "cancelled",
    "timed_out",
    "service_quanta",
    "driver_steps",
    "final_logical_tick",
    "maximum_live_receipts",
    "peak_host_bytes",
    "peak",
    "maximum_wait_quanta",
    "maximum_service_gap",
    "fairness_cross_product_error",
    "bind_callbacks",
    "cancel_callbacks",
    "service_callbacks",
    "final_service_callbacks",
    "retire_callbacks",
    "final_active",
    "final_finished",
    "final_active_reservations",
    "final_committed_receipts",
    "successful_commits",
    "releases",
    "bank_cancellations",
    "bank_rejected_capacity",
    "bank_rejected_slots",
    "zero_orphan_ownership",
)
EVIDENCE_REPORT_SUMMARY_FIELDS = (
    "profile_count",
    "item_count",
    "admitted",
    "rejected",
    "completed",
    "cancelled",
    "timed_out",
    "vision_completed",
    "audio_window_completed",
    "temporal_video_completed",
    "publications",
    "nonpublished_terminal_items",
    "cache_restores",
    "cache_closures",
    "cache_successful_commits",
    "cache_releases",
    "cache_live_allocations",
    "model_successful_commits",
    "model_releases",
    "model_final_active_reservations",
    "model_final_committed_receipts",
    "zero_model_ownership",
    "zero_cache_ownership",
    "zero_orphan_ownership",
)
OUTCOME_NAMES = {
    OUTCOME_COMPLETED: "completed",
    OUTCOME_REJECTED: "rejected",
    OUTCOME_CANCELLED: "cancelled",
    OUTCOME_TIMED_OUT: "timed_out",
}


def _u8(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= 0xFF:
        raise TypedWorkloadError("u8 out of range")
    return struct.pack("<B", value)


def _u16(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U16_MAX:
        raise TypedWorkloadError("u16 out of range")
    return struct.pack("<H", value)


def _u32(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U32_MAX:
        raise TypedWorkloadError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise TypedWorkloadError("u64 out of range")
    return struct.pack("<Q", value)


def _read_u64(value: bytes, offset: int) -> int:
    try:
        return struct.unpack_from("<Q", value, offset)[0]
    except struct.error as error:
        raise TypedWorkloadError("truncated u64") from error


def _write_u64(output: bytearray, offset: int, value: int) -> None:
    try:
        struct.pack_into("<Q", output, offset, value)
    except (struct.error, TypeError) as error:
        raise TypedWorkloadError("invalid u64 write") from error


def _sha(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _digest(value: Any, *, allow_zero: bool = False) -> bytes:
    if type(value) is not bytes or len(value) != 32:
        raise TypedWorkloadError("digest must be exactly 32 bytes")
    if not allow_zero and value == ZERO_DIGEST:
        raise TypedWorkloadError("zero digest is not a valid binding")
    return value


def _strict_record(value: Any, fields: Sequence[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != set(fields):
        raise TypedWorkloadError(f"invalid {label} fields")
    return value


def _integer(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
    maximum: int = U64_MAX,
) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise TypedWorkloadError(f"invalid {label}")
    return value


def _boolean(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise TypedWorkloadError(f"invalid {label}")
    return value


def _enum(value: Any, allowed: frozenset[int], label: str) -> int:
    result = _integer(value, label)
    if result not in allowed:
        raise TypedWorkloadError(f"unsupported {label}")
    return result


def _empty_claim() -> Record:
    return {name: 0 for name in CLAIM_FIELDS}


def claim(**values: int) -> Record:
    unknown = set(values) - set(CLAIM_FIELDS)
    if unknown:
        raise TypedWorkloadError("unknown claim field")
    result = _empty_claim()
    result.update(values)
    return _validate_claim(result)


def limits(**values: int) -> Record:
    unknown = set(values) - set(LIMIT_FIELDS)
    if unknown:
        raise TypedWorkloadError("unknown limit field")
    result = {name: U64_MAX for name in LIMIT_FIELDS}
    result.update(values)
    return _validate_limits(result)


def _validate_claim(value: Any, *, require_request: bool = False) -> Record:
    source = _strict_record(value, CLAIM_FIELDS, "claim")
    result = {name: _integer(source[name], f"claim.{name}") for name in CLAIM_FIELDS}
    _host_bytes(result)
    if require_request and (not any(result.values()) or result["queue_slots"] != 1):
        raise TypedWorkloadError("invalid request claim")
    return result


def _validate_limits(value: Any) -> Record:
    source = _strict_record(value, LIMIT_FIELDS, "limits")
    return {name: _integer(source[name], f"limits.{name}") for name in LIMIT_FIELDS}


def _host_bytes(value: Mapping[str, int]) -> int:
    total = sum(value[name] for name in HOST_CLAIM_FIELDS)
    _u64(total)
    return total


def _claim_add(left: Mapping[str, int], right: Mapping[str, int]) -> Record:
    result = {name: left[name] + right[name] for name in CLAIM_FIELDS}
    for value in result.values():
        _u64(value)
    return result


def _claim_subtract(left: Mapping[str, int], right: Mapping[str, int]) -> Record:
    if any(right[name] > left[name] for name in CLAIM_FIELDS):
        raise TypedWorkloadError("resource accounting underflow")
    return {name: left[name] - right[name] for name in CLAIM_FIELDS}


def _fits(limit: Mapping[str, int], value: Mapping[str, int]) -> bool:
    return _host_bytes(value) <= limit["host_bytes"] and all(
        value[name] <= limit[name] for name in CLAIM_FIELDS
    )


def _hash_claim(value: Mapping[str, int]) -> tuple[bytes, ...]:
    return tuple(_u64(value[name]) for name in CLAIM_FIELDS)


def _hash_limits(value: Mapping[str, int]) -> tuple[bytes, ...]:
    return tuple(_u64(value[name]) for name in LIMIT_FIELDS)


def validate_support_record(value: Any) -> Record:
    source = _strict_record(value, SUPPORT_RECORD_FIELDS, "support record")
    return {
        "family": _enum(source["family"], MODEL_FAMILIES, "family"),
        "operation": _enum(source["operation"], MODEL_OPERATIONS, "operation"),
        "input_kind": _enum(source["input_kind"], MODEL_INPUT_KINDS, "input kind"),
        "output_kind": _enum(source["output_kind"], MODEL_OUTPUT_KINDS, "output kind"),
        "numerical_policy": _enum(
            source["numerical_policy"],
            NUMERICAL_POLICIES,
            "numerical policy",
        ),
        "max_batch_items": _integer(source["max_batch_items"], "max batch items"),
        "max_input_features": _integer(
            source["max_input_features"], "max input features"
        ),
        "max_output_dimensions": _integer(
            source["max_output_dimensions"], "max output dimensions"
        ),
        "allowed_capabilities": _integer(
            source["allowed_capabilities"], "allowed capabilities"
        ),
    }


def support_record_sha256(value: Any) -> bytes:
    record = validate_support_record(value)
    return _sha(
        SUPPORT_RECORD_DOMAIN,
        _u64(SUPPORT_RECORD_ABI),
        *(_u64(record[name]) for name in SUPPORT_RECORD_FIELDS),
    )


def _canonical_profile(value: Any, *, verify_root: bool) -> Record:
    source = _strict_record(value, PROFILE_FIELDS, "profile")
    result: Record = {
        "index": _integer(source["index"], "profile index"),
        "family": _enum(source["family"], MODEL_FAMILIES, "family"),
        "operation": _enum(source["operation"], MODEL_OPERATIONS, "operation"),
        "input_kind": _enum(source["input_kind"], MODEL_INPUT_KINDS, "input kind"),
        "output_kind": _enum(source["output_kind"], MODEL_OUTPUT_KINDS, "output kind"),
        "numerical_policy": _enum(
            source["numerical_policy"],
            NUMERICAL_POLICIES,
            "numerical policy",
        ),
        "adapter_abi": _integer(source["adapter_abi"], "adapter ABI", minimum=1),
        "lifecycle": _enum(source["lifecycle"], LIFECYCLES, "lifecycle"),
        "execution_unit": _enum(
            source["execution_unit"], EXECUTION_UNITS, "execution unit"
        ),
        "cancellation_boundary": _enum(
            source["cancellation_boundary"],
            CANCELLATION_BOUNDARIES,
            "cancellation boundary",
        ),
        "publication_policy": _enum(
            source["publication_policy"],
            PUBLICATION_POLICIES,
            "publication policy",
        ),
        "correctness_gate": _enum(
            source["correctness_gate"],
            CORRECTNESS_GATES,
            "correctness gate",
        ),
        "claim": _validate_claim(source["claim"], require_request=True),
    }
    for name in PROFILE_DIGEST_FIELDS:
        result[name] = _digest(
            source[name], allow_zero=name == "profile_sha256" and not verify_root
        )
    if verify_root and not hmac.compare_digest(
        result["profile_sha256"], profile_sha256(result)
    ):
        raise TypedWorkloadError("profile root mismatch")
    return result


def profile_sha256(value: Any) -> bytes:
    profile = _canonical_profile(value, verify_root=False)
    return _sha(
        PROFILE_DOMAIN,
        _u64(PROFILE_ABI),
        *(_u64(profile[name]) for name in PROFILE_SCALAR_FIELDS),
        *_hash_claim(profile["claim"]),
        *(_digest(profile[name]) for name in PROFILE_DIGEST_FIELDS[:-1]),
    )


def seal_profile(value: Any) -> Record:
    source = deepcopy(value)
    if not isinstance(source, dict):
        raise TypedWorkloadError("profile must be an object")
    source["profile_sha256"] = ZERO_DIGEST
    profile = _canonical_profile(source, verify_root=False)
    profile["profile_sha256"] = profile_sha256(profile)
    return _canonical_profile(profile, verify_root=True)


def _canonical_item(value: Any, *, verify_root: bool) -> Record:
    source = _strict_record(value, ITEM_FIELDS, "item")
    result: Record = {
        "ordinal": _integer(source["ordinal"], "item ordinal"),
        "profile_index": _integer(source["profile_index"], "item profile index"),
        "profile_sha256": _digest(source["profile_sha256"]),
        "arrival_step": _integer(source["arrival_step"], "arrival step"),
        "weight": _integer(source["weight"], "weight", minimum=1, maximum=U16_MAX),
        "work_quanta": _integer(source["work_quanta"], "work quanta", minimum=1),
        "deadline_tick": _integer(source["deadline_tick"], "deadline tick"),
        "terminal_action_step": _integer(
            source["terminal_action_step"], "terminal action step"
        ),
        "terminal_action": _enum(
            source["terminal_action"], TERMINAL_ACTIONS, "terminal action"
        ),
        "fairness_member": _boolean(source["fairness_member"], "fairness member"),
        "tenant_key": _integer(source["tenant_key"], "tenant key", minimum=1),
        "request_key": _integer(source["request_key"], "request key", minimum=1),
        "request_generation": _integer(
            source["request_generation"], "request generation", minimum=1
        ),
        "resource_owner_key": _integer(
            source["resource_owner_key"], "resource owner key", minimum=1
        ),
        "claim": _validate_claim(source["claim"], require_request=True),
        "input_binding_sha256": _digest(source["input_binding_sha256"]),
        "item_sha256": _digest(source["item_sha256"], allow_zero=not verify_root),
    }
    if verify_root and not hmac.compare_digest(
        result["item_sha256"], item_sha256(result)
    ):
        raise TypedWorkloadError("item root mismatch")
    return result


def item_sha256(value: Any) -> bytes:
    item = _canonical_item(value, verify_root=False)
    return _sha(
        ITEM_DOMAIN,
        _u64(ITEM_ABI),
        _u64(item["ordinal"]),
        _u64(item["profile_index"]),
        _digest(item["profile_sha256"]),
        *(_u64(int(item[name])) for name in ITEM_SCALAR_FIELDS[2:]),
        *_hash_claim(item["claim"]),
        _digest(item["input_binding_sha256"]),
    )


def seal_item(value: Any) -> Record:
    source = deepcopy(value)
    if not isinstance(source, dict):
        raise TypedWorkloadError("item must be an object")
    source["item_sha256"] = ZERO_DIGEST
    item = _canonical_item(source, verify_root=False)
    item["item_sha256"] = item_sha256(item)
    return _canonical_item(item, verify_root=True)


def profile_section_sha256(profiles: Sequence[Record]) -> bytes:
    if not 0 < len(profiles) <= MAXIMUM_PROFILES:
        raise TypedWorkloadError("invalid profile count")
    return _sha(
        PROFILE_SECTION_DOMAIN,
        _u64(len(profiles)),
        *(_digest(profile["profile_sha256"]) for profile in profiles),
    )


def item_section_sha256(items: Sequence[Record]) -> bytes:
    if not 0 < len(items) <= MAXIMUM_ITEMS:
        raise TypedWorkloadError("invalid item count")
    return _sha(
        ITEM_SECTION_DOMAIN,
        _u64(len(items)),
        *(_digest(item["item_sha256"]) for item in items),
    )


def validate_plan(value: Any) -> Record:
    source = _strict_record(value, PLAN_FIELDS, "plan")
    result: Record = {
        "seed": _integer(source["seed"], "seed", minimum=1),
        "capacity": _integer(
            source["capacity"], "capacity", minimum=1, maximum=U32_MAX
        ),
        "max_driver_steps": _integer(
            source["max_driver_steps"],
            "max driver steps",
            minimum=1,
            maximum=MAXIMUM_DRIVER_STEPS,
        ),
        "max_service_quanta": _integer(
            source["max_service_quanta"],
            "max service quanta",
            minimum=1,
            maximum=MAXIMUM_SERVICE_QUANTA,
        ),
        "fairness_start_tick": _integer(
            source["fairness_start_tick"], "fairness start tick"
        ),
        "fairness_end_tick": _integer(source["fairness_end_tick"], "fairness end tick"),
        "bank_epoch": _integer(source["bank_epoch"], "bank epoch", minimum=1),
        "scheduler_epoch": _integer(
            source["scheduler_epoch"], "scheduler epoch", minimum=1
        ),
        "max_weight": _integer(
            source["max_weight"],
            "max weight",
            minimum=1,
            maximum=U16_MAX,
        ),
        "max_projection_quanta": _integer(
            source["max_projection_quanta"],
            "max projection quanta",
            minimum=1,
        ),
        "max_projection_operations": _integer(
            source["max_projection_operations"],
            "max projection operations",
            minimum=1,
        ),
        "limits": _validate_limits(source["limits"]),
        "challenge": _digest(source["challenge"]),
    }
    profiles_value = source["profiles"]
    items_value = source["items"]
    if (
        not isinstance(profiles_value, list)
        or not 0 < len(profiles_value) <= MAXIMUM_PROFILES
        or not isinstance(items_value, list)
        or not 2 <= len(items_value) <= MAXIMUM_ITEMS
    ):
        raise TypedWorkloadError("invalid ordered plan sections")
    result["profiles"] = [
        _canonical_profile(profile, verify_root=True) for profile in profiles_value
    ]
    result["items"] = [_canonical_item(item, verify_root=True) for item in items_value]
    if (
        result["capacity"] > len(result["items"])
        or len(result["profiles"]) > len(result["items"])
        or result["fairness_end_tick"] <= result["fairness_start_tick"]
        or result["fairness_end_tick"] > result["max_service_quanta"]
        or result["limits"]["queue_slots"] < result["capacity"]
    ):
        raise TypedWorkloadError("invalid plan bounds")

    profile_roots: set[bytes] = set()
    for index, profile in enumerate(result["profiles"]):
        if profile["index"] != index:
            raise TypedWorkloadError("profiles are not canonically ordered")
        root = profile["profile_sha256"]
        if root in profile_roots:
            raise TypedWorkloadError("duplicate profile root")
        profile_roots.add(root)

    total_work = 0
    fairness_members = 0
    previous_arrival = 0
    identities: dict[str, set[int]] = {
        "tenant_key": set(),
        "request_key": set(),
        "resource_owner_key": set(),
    }
    referenced_profiles: set[int] = set()
    for index, item in enumerate(result["items"]):
        if (
            item["ordinal"] != index
            or item["profile_index"] >= len(result["profiles"])
            or item["arrival_step"] >= result["max_driver_steps"]
            or (index and item["arrival_step"] < previous_arrival)
            or item["weight"] > result["max_weight"]
            or item["deadline_tick"] > result["max_projection_quanta"]
            or (item["deadline_tick"] and item["deadline_tick"] <= item["arrival_step"])
            or (
                (item["terminal_action"] == ACTION_NONE)
                != (item["terminal_action_step"] == ABSENT)
            )
            or (
                item["terminal_action"] != ACTION_NONE
                and (
                    item["terminal_action_step"] < item["arrival_step"]
                    or item["terminal_action_step"] >= result["max_driver_steps"]
                )
            )
        ):
            raise TypedWorkloadError("invalid ordered item schedule")
        profile = result["profiles"][item["profile_index"]]
        if (
            profile["index"] != item["profile_index"]
            or not hmac.compare_digest(
                profile["profile_sha256"], item["profile_sha256"]
            )
            or profile["claim"] != item["claim"]
        ):
            raise TypedWorkloadError("item/profile binding mismatch")
        for name, seen in identities.items():
            if item[name] in seen:
                raise TypedWorkloadError(f"duplicate {name}")
            seen.add(item[name])
        referenced_profiles.add(item["profile_index"])
        previous_arrival = item["arrival_step"]
        total_work += item["work_quanta"]
        _u64(total_work)
        fairness_members += int(item["fairness_member"])
    if (
        total_work > result["max_service_quanta"]
        or fairness_members < 2
        or referenced_profiles != set(range(len(result["profiles"])))
    ):
        raise TypedWorkloadError("invalid work or fairness envelope")
    return result


def _plan_sha256_canonical(plan: Mapping[str, Any]) -> bytes:
    profile_root = profile_section_sha256(plan["profiles"])
    item_root = item_section_sha256(plan["items"])
    return _sha(
        PLAN_DOMAIN,
        _u64(PLAN_ABI),
        *(_u64(plan[name]) for name in PLAN_SCALAR_FIELDS),
        *_hash_limits(plan["limits"]),
        _digest(plan["challenge"]),
        _u64(len(plan["profiles"])),
        profile_root,
        _u64(len(plan["items"])),
        item_root,
    )


def plan_sha256(value: Any) -> bytes:
    return _plan_sha256_canonical(validate_plan(value))


def required_plan_bytes(profile_count: int, item_count: int) -> int:
    if (
        type(profile_count) is not int
        or not 0 < profile_count <= MAXIMUM_PROFILES
        or type(item_count) is not int
        or not 0 < item_count <= MAXIMUM_ITEMS
    ):
        raise TypedWorkloadError("invalid plan section count")
    return (
        PLAN_HEADER_BYTES
        + profile_count * PROFILE_RECORD_BYTES
        + item_count * ITEM_RECORD_BYTES
        + PLAN_FOOTER_BYTES
    )


def _write_claim(output: bytearray, offset: int, value: Mapping[str, int]) -> None:
    for index, name in enumerate(CLAIM_FIELDS):
        _write_u64(output, offset + index * 8, value[name])


def _read_claim(value: bytes, offset: int) -> Record:
    return {
        name: _read_u64(value, offset + index * 8)
        for index, name in enumerate(CLAIM_FIELDS)
    }


def _write_limits(output: bytearray, offset: int, value: Mapping[str, int]) -> None:
    for index, name in enumerate(LIMIT_FIELDS):
        _write_u64(output, offset + index * 8, value[name])


def _read_limits(value: bytes, offset: int) -> Record:
    return {
        name: _read_u64(value, offset + index * 8)
        for index, name in enumerate(LIMIT_FIELDS)
    }


def _encode_profile_record(profile: Record) -> bytes:
    output = bytearray(PROFILE_RECORD_BYTES)
    for index, name in enumerate(PROFILE_SCALAR_FIELDS):
        _write_u64(output, index * 8, profile[name])
    _write_claim(output, 96, profile["claim"])
    for index, name in enumerate(PROFILE_DIGEST_FIELDS):
        start = 176 + index * 32
        output[start : start + 32] = profile[name]
    return bytes(output)


def _decode_profile_record(value: bytes) -> Record:
    if len(value) != PROFILE_RECORD_BYTES:
        raise TypedWorkloadError("invalid profile record length")
    profile: Record = {
        name: _read_u64(value, index * 8)
        for index, name in enumerate(PROFILE_SCALAR_FIELDS)
    }
    profile["claim"] = _read_claim(value, 96)
    for index, name in enumerate(PROFILE_DIGEST_FIELDS):
        start = 176 + index * 32
        profile[name] = value[start : start + 32]
    return profile


def _encode_item_record(item: Record) -> bytes:
    output = bytearray(ITEM_RECORD_BYTES)
    _write_u64(output, 0, item["ordinal"])
    _write_u64(output, 8, item["profile_index"])
    output[16:48] = item["profile_sha256"]
    scalar_offsets = {
        "arrival_step": 48,
        "weight": 56,
        "work_quanta": 64,
        "deadline_tick": 72,
        "terminal_action_step": 80,
        "terminal_action": 88,
        "fairness_member": 96,
        "tenant_key": 104,
        "request_key": 112,
        "request_generation": 120,
        "resource_owner_key": 128,
    }
    for name, offset in scalar_offsets.items():
        _write_u64(output, offset, int(item[name]))
    _write_claim(output, 136, item["claim"])
    output[216:248] = item["input_binding_sha256"]
    output[248:280] = item["item_sha256"]
    return bytes(output)


def _decode_item_record(value: bytes) -> Record:
    if len(value) != ITEM_RECORD_BYTES:
        raise TypedWorkloadError("invalid item record length")
    fairness = _read_u64(value, 96)
    if fairness not in (0, 1):
        raise TypedWorkloadError("noncanonical fairness flag")
    weight = _read_u64(value, 56)
    if weight > U16_MAX:
        raise TypedWorkloadError("noncanonical weight")
    return {
        "ordinal": _read_u64(value, 0),
        "profile_index": _read_u64(value, 8),
        "profile_sha256": value[16:48],
        "arrival_step": _read_u64(value, 48),
        "weight": weight,
        "work_quanta": _read_u64(value, 64),
        "deadline_tick": _read_u64(value, 72),
        "terminal_action_step": _read_u64(value, 80),
        "terminal_action": _read_u64(value, 88),
        "fairness_member": bool(fairness),
        "tenant_key": _read_u64(value, 104),
        "request_key": _read_u64(value, 112),
        "request_generation": _read_u64(value, 120),
        "resource_owner_key": _read_u64(value, 128),
        "claim": _read_claim(value, 136),
        "input_binding_sha256": value[216:248],
        "item_sha256": value[248:280],
    }


def encode_plan(value: Any) -> bytes:
    plan = validate_plan(value)
    needed = required_plan_bytes(len(plan["profiles"]), len(plan["items"]))
    output = bytearray(needed)
    output[:8] = PLAN_MAGIC
    header_values = {
        8: PLAN_ABI,
        16: needed,
        24: PLAN_HEADER_BYTES,
        32: PROFILE_RECORD_BYTES,
        40: ITEM_RECORD_BYTES,
        48: PLAN_FOOTER_BYTES,
        56: ALLOWED_FLAGS,
        64: len(plan["profiles"]),
        72: len(plan["items"]),
        80: plan["seed"],
        88: plan["capacity"],
        96: plan["max_driver_steps"],
        104: plan["max_service_quanta"],
        112: plan["fairness_start_tick"],
        120: plan["fairness_end_tick"],
        128: plan["bank_epoch"],
        136: plan["scheduler_epoch"],
        144: plan["max_weight"],
        152: plan["max_projection_quanta"],
        160: plan["max_projection_operations"],
    }
    for offset, number in header_values.items():
        _write_u64(output, offset, number)
    _write_limits(output, 168, plan["limits"])
    output[256:288] = plan["challenge"]
    output[288:320] = profile_section_sha256(plan["profiles"])
    output[320:352] = item_section_sha256(plan["items"])
    output[352:384] = plan_sha256(plan)
    offset = PLAN_HEADER_BYTES
    for profile in plan["profiles"]:
        output[offset : offset + PROFILE_RECORD_BYTES] = _encode_profile_record(profile)
        offset += PROFILE_RECORD_BYTES
    for item in plan["items"]:
        output[offset : offset + ITEM_RECORD_BYTES] = _encode_item_record(item)
        offset += ITEM_RECORD_BYTES
    output[offset : offset + PLAN_FOOTER_BYTES] = _sha(
        PLAN_WIRE_DOMAIN, bytes(output[:offset])
    )
    return bytes(output)


def decode_plan(value: Any) -> Record:
    if type(value) is not bytes:
        raise TypedWorkloadError("plan wire must be immutable bytes")
    minimum = PLAN_HEADER_BYTES + PLAN_FOOTER_BYTES
    if (
        len(value) < minimum
        or len(value) > MAXIMUM_PLAN_BYTES
        or value[:8] != PLAN_MAGIC
        or _read_u64(value, 8) != PLAN_ABI
        or _read_u64(value, 16) != len(value)
        or _read_u64(value, 24) != PLAN_HEADER_BYTES
        or _read_u64(value, 32) != PROFILE_RECORD_BYTES
        or _read_u64(value, 40) != ITEM_RECORD_BYTES
        or _read_u64(value, 48) != PLAN_FOOTER_BYTES
        or _read_u64(value, 56) != ALLOWED_FLAGS
    ):
        raise TypedWorkloadError("invalid plan header")
    profile_count = _read_u64(value, 64)
    item_count = _read_u64(value, 72)
    if len(value) != required_plan_bytes(profile_count, item_count):
        raise TypedWorkloadError("noncanonical plan length")
    if not hmac.compare_digest(
        value[-PLAN_FOOTER_BYTES:],
        _sha(PLAN_WIRE_DOMAIN, value[:-PLAN_FOOTER_BYTES]),
    ):
        raise TypedWorkloadError("plan wire footer mismatch")

    offset = PLAN_HEADER_BYTES
    profiles: list[Record] = []
    for _ in range(profile_count):
        profiles.append(
            _decode_profile_record(value[offset : offset + PROFILE_RECORD_BYTES])
        )
        offset += PROFILE_RECORD_BYTES
    items: list[Record] = []
    for _ in range(item_count):
        items.append(_decode_item_record(value[offset : offset + ITEM_RECORD_BYTES]))
        offset += ITEM_RECORD_BYTES
    plan: Record = {
        "seed": _read_u64(value, 80),
        "capacity": _read_u64(value, 88),
        "max_driver_steps": _read_u64(value, 96),
        "max_service_quanta": _read_u64(value, 104),
        "fairness_start_tick": _read_u64(value, 112),
        "fairness_end_tick": _read_u64(value, 120),
        "bank_epoch": _read_u64(value, 128),
        "scheduler_epoch": _read_u64(value, 136),
        "max_weight": _read_u64(value, 144),
        "max_projection_quanta": _read_u64(value, 152),
        "max_projection_operations": _read_u64(value, 160),
        "limits": _read_limits(value, 168),
        "challenge": value[256:288],
        "profiles": profiles,
        "items": items,
    }
    canonical = validate_plan(plan)
    if (
        not hmac.compare_digest(
            value[288:320], profile_section_sha256(canonical["profiles"])
        )
        or not hmac.compare_digest(
            value[320:352], item_section_sha256(canonical["items"])
        )
        or not hmac.compare_digest(value[352:384], plan_sha256(canonical))
    ):
        raise TypedWorkloadError("plan semantic root mismatch")
    return canonical


def _mix64(value: int) -> int:
    value &= U64_MAX
    value ^= value >> 30
    value = (value * 0xBF58476D1CE4E5B9) & U64_MAX
    value ^= value >> 27
    value = (value * 0x94D049BB133111EB) & U64_MAX
    value ^= value >> 31
    return value & U64_MAX


def _receipt_integrity(
    bank_epoch: int,
    slot_index: int,
    generation: int,
    owner_key: int,
    value: Mapping[str, int],
) -> int:
    result = _mix64(RESOURCE_RECEIPT_INTEGRITY_DOMAIN ^ bank_epoch)
    result = _mix64(result ^ slot_index)
    result = _mix64(result ^ generation)
    result = _mix64(result ^ owner_key)
    for name in CLAIM_FIELDS:
        result = _mix64(result ^ value[name])
    return result


def _zero_spec() -> Record:
    return {
        "tenant_key": 0,
        "request_key": 0,
        "request_generation": 0,
        "resource_owner_key": 0,
        "weight": 0,
        "work_quanta": 0,
        "deadline_tick": 0,
        "claim": _empty_claim(),
    }


def _zero_receipt() -> Record:
    return {
        "bank_epoch": 0,
        "slot_index": 0,
        "generation": 0,
        "owner_key": 0,
        "claim": _empty_claim(),
        "integrity": 0,
    }


def _zero_handle() -> Record:
    return {
        "scheduler_epoch": 0,
        "slot_index": 0,
        "slot_generation": 0,
        "tenant_key": 0,
        "request_key": 0,
        "request_generation": 0,
    }


def _free_slot() -> Record:
    return {
        "state": SLOT_FREE,
        "generation": 0,
        "spec": _zero_spec(),
        "remaining_quanta": 0,
        "admitted_tick": 0,
        "last_service_tick": 0,
        "service_count": 0,
        "receipt": _zero_receipt(),
        "receipt_sha256": ZERO_DIGEST,
    }


def _request_spec(item: Mapping[str, Any]) -> Record:
    return {
        "tenant_key": item["tenant_key"],
        "request_key": item["request_key"],
        "request_generation": item["request_generation"],
        "resource_owner_key": item["resource_owner_key"],
        "weight": item["weight"],
        "work_quanta": item["work_quanta"],
        "deadline_tick": item["deadline_tick"],
        "claim": deepcopy(item["claim"]),
    }


def _hash_spec(spec: Mapping[str, Any]) -> bytes:
    return b"".join(
        (
            _u64(spec["tenant_key"]),
            _u64(spec["request_key"]),
            _u64(spec["request_generation"]),
            _u64(spec["resource_owner_key"]),
            _u16(spec["weight"]),
            _u64(spec["work_quanta"]),
            _u64(spec["deadline_tick"]),
            *_hash_claim(spec["claim"]),
        )
    )


def _hash_handle(handle: Mapping[str, int]) -> bytes:
    return b"".join(
        (
            _u64(handle["scheduler_epoch"]),
            _u32(handle["slot_index"]),
            _u64(handle["slot_generation"]),
            _u64(handle["tenant_key"]),
            _u64(handle["request_key"]),
            _u64(handle["request_generation"]),
        )
    )


def _hash_receipt(receipt: Mapping[str, Any]) -> bytes:
    return b"".join(
        (
            _u64(receipt["bank_epoch"]),
            _u32(receipt["slot_index"]),
            _u64(receipt["generation"]),
            _u64(receipt["owner_key"]),
            *_hash_claim(receipt["claim"]),
            _u64(receipt["integrity"]),
        )
    )


def resource_receipt_sha256(receipt: Mapping[str, Any]) -> bytes:
    return _sha(LANE_RECEIPT_DOMAIN, _hash_receipt(receipt))


def _hash_slot(slot: Mapping[str, Any]) -> bytes:
    return b"".join(
        (
            _u8(slot["state"]),
            _u64(slot["generation"]),
            _hash_spec(slot["spec"]),
            _u64(slot["remaining_quanta"]),
            _u64(slot["admitted_tick"]),
            _u64(slot["last_service_tick"]),
            _u64(slot["service_count"]),
            _hash_receipt(slot["receipt"]),
            _digest(slot["receipt_sha256"], allow_zero=True),
        )
    )


def _maximum_service_gap(capacity: int, max_weight: int) -> int:
    result = (capacity - 1) * max_weight + 1
    _u64(result)
    return result


def _initial_chain_root(plan: Mapping[str, Any]) -> bytes:
    gap = _maximum_service_gap(plan["capacity"], plan["max_weight"])
    return _sha(
        LANE_INITIAL_ROOT_DOMAIN,
        _u64(LANE_WEAVE_ABI),
        _u64(LANE_WEAVE_EVENT_ABI),
        _u64(RESOURCE_BANK_ABI),
        _u64(plan["scheduler_epoch"]),
        _digest(plan["challenge"]),
        _u16(plan["max_weight"]),
        _u64(plan["max_projection_quanta"]),
        _u64(plan["max_projection_operations"]),
        _u32(plan["capacity"]),
        _u64(plan["bank_epoch"]),
        *_hash_limits(plan["limits"]),
        _u64(gap),
    )


def _scheduler_state_sha256(state: Mapping[str, Any]) -> bytes:
    return _sha(
        LANE_STATE_DOMAIN,
        _u64(state["scheduler_epoch"]),
        _u64(state["logical_tick"]),
        _u64(state["next_event_sequence"]),
        _u64(state["next_slot_generation"]),
        _u32(state["cursor"]),
        _u16(state["level"]),
        _u8(int(state["poisoned"])),
        _u8(int(state["closed"])),
        *_hash_claim(state["used"]),
        _u32(len(state["slots"])),
        *(_hash_slot(slot) for slot in state["slots"]),
    )


def scheduler_event_sha256(event: Mapping[str, Any]) -> bytes:
    return _sha(
        LANE_EVENT_DOMAIN,
        _u64(LANE_WEAVE_EVENT_ABI),
        _u64(event["scheduler_epoch"]),
        _u64(event["event_sequence"]),
        _u8(event["kind"]),
        _u8(event["rejection_reason"]),
        _digest(event["previous_sha256"], allow_zero=True),
        _digest(event["state_before_sha256"]),
        _digest(event["state_after_sha256"]),
        _u64(event["logical_tick_before"]),
        _u64(event["logical_tick_after"]),
        _u32(event["cursor_before"]),
        _u32(event["cursor_after"]),
        _u16(event["level_before"]),
        _u16(event["level_after"]),
        _hash_handle(event["handle"]),
        _hash_spec(event["spec"]),
        _hash_receipt(event["resource_receipt"]),
        _digest(event["resource_receipt_sha256"], allow_zero=True),
        _u64(event["remaining_before"]),
        _u64(event["remaining_after"]),
        _u64(event["wait_quanta"]),
        _u64(event["maximum_service_gap"]),
        _u32(event["active_before"]),
        _u32(event["active_after"]),
        _u32(event["finished_before"]),
        _u32(event["finished_after"]),
        *_hash_claim(event["bank_used_before"]),
        *_hash_claim(event["bank_used_after"]),
    )


def _slot_counts(state: Mapping[str, Any]) -> tuple[int, int]:
    active = sum(slot["state"] == SLOT_ACTIVE for slot in state["slots"])
    finished = sum(slot["state"] == SLOT_FINISHED for slot in state["slots"])
    return active, finished


def _handle_for(state: Mapping[str, Any], index: int) -> Record:
    slot = state["slots"][index]
    return {
        "scheduler_epoch": state["scheduler_epoch"],
        "slot_index": index,
        "slot_generation": slot["generation"],
        "tenant_key": slot["spec"]["tenant_key"],
        "request_key": slot["spec"]["request_key"],
        "request_generation": slot["spec"]["request_generation"],
    }


def _emit_event(state: Record, seed: Mapping[str, Any]) -> Record:
    sequence = state["next_event_sequence"]
    if sequence == U64_MAX:
        raise TypedWorkloadError("scheduler sequence overflow")
    state["next_event_sequence"] += 1
    active_after, finished_after = _slot_counts(state)
    event: Record = {
        "scheduler_epoch": state["scheduler_epoch"],
        "event_sequence": sequence,
        "kind": seed["kind"],
        "rejection_reason": seed.get("rejection_reason", REJECTION_NONE),
        "previous_sha256": state["chain_head_sha256"],
        "state_before_sha256": seed["state_before_sha256"],
        "state_after_sha256": _scheduler_state_sha256(state),
        "logical_tick_before": seed["logical_tick_before"],
        "logical_tick_after": state["logical_tick"],
        "cursor_before": seed["cursor_before"],
        "cursor_after": state["cursor"],
        "level_before": seed["level_before"],
        "level_after": state["level"],
        "handle": deepcopy(seed.get("handle", _zero_handle())),
        "spec": deepcopy(seed.get("spec", _zero_spec())),
        "resource_receipt": deepcopy(seed.get("resource_receipt", _zero_receipt())),
        "resource_receipt_sha256": seed.get("resource_receipt_sha256", ZERO_DIGEST),
        "remaining_before": seed.get("remaining_before", 0),
        "remaining_after": seed.get("remaining_after", 0),
        "wait_quanta": seed.get("wait_quanta", 0),
        "maximum_service_gap": state["maximum_service_gap"],
        "active_before": seed["active_before"],
        "active_after": active_after,
        "finished_before": seed["finished_before"],
        "finished_after": finished_after,
        "bank_used_before": deepcopy(seed["bank_used_before"]),
        "bank_used_after": deepcopy(state["used"]),
    }
    event["event_sha256"] = scheduler_event_sha256(event)
    state["chain_head_sha256"] = event["event_sha256"]
    return event


def _new_scheduler(plan: Mapping[str, Any]) -> Record:
    state: Record = {
        "scheduler_epoch": plan["scheduler_epoch"],
        "bank_epoch": plan["bank_epoch"],
        "limits": deepcopy(plan["limits"]),
        "max_weight": plan["max_weight"],
        "max_projection_quanta": plan["max_projection_quanta"],
        "max_projection_operations": plan["max_projection_operations"],
        "slots": [_free_slot() for _ in range(plan["capacity"])],
        "used": _empty_claim(),
        "peak": _empty_claim(),
        "peak_host_bytes": 0,
        "logical_tick": 0,
        "next_event_sequence": 0,
        "next_slot_generation": 1,
        "next_bank_generation": 1,
        "cursor": 0,
        "level": 1,
        "maximum_service_gap": _maximum_service_gap(
            plan["capacity"], plan["max_weight"]
        ),
        "chain_head_sha256": ZERO_DIGEST,
        "poisoned": False,
        "closed": False,
        "successful_reservations": 0,
        "successful_commits": 0,
        "releases": 0,
        "bank_cancellations": 0,
        "bank_rejected_capacity": 0,
        "bank_rejected_slots": 0,
    }
    state["chain_head_sha256"] = _initial_chain_root(plan)
    return state


def _select_iwrr(
    slots: Sequence[Mapping[str, Any]],
    initial_cursor: int,
    initial_level: int,
    configured_max_weight: int,
) -> tuple[int, int, int]:
    active_weights = [
        slot["spec"]["weight"] for slot in slots if slot["state"] == SLOT_ACTIVE
    ]
    if not active_weights:
        raise TypedWorkloadError("no runnable request")
    maximum_active_weight = max(active_weights)
    cursor = min(initial_cursor, len(slots))
    level = initial_level or 1
    if level > maximum_active_weight or level > configured_max_weight:
        level = 1
        cursor = 0
    for _ in range(len(slots) * configured_max_weight):
        if cursor >= len(slots):
            cursor = 0
            level = 1 if level >= maximum_active_weight else level + 1
        index = cursor
        cursor += 1
        slot = slots[index]
        if slot["state"] == SLOT_ACTIVE and slot["spec"]["weight"] >= level:
            return index, cursor, level
    raise TypedWorkloadError("IWRR scan exhausted")


def _projection_rejection(
    slots: Sequence[Mapping[str, Any]],
    candidate_index: int,
    spec: Mapping[str, Any],
    logical_tick: int,
    cursor: int,
    level: int,
    max_weight: int,
    max_quanta: int,
    max_operations: int,
) -> int:
    remaining_operations = max_operations
    budget_exhausted = False

    def spend(amount: int) -> bool:
        nonlocal remaining_operations, budget_exhausted
        if amount > remaining_operations:
            budget_exhausted = True
            return False
        remaining_operations -= amount
        return True

    if spec["deadline_tick"] and spec["work_quanta"] > max_quanta:
        return REJECTION_PROJECTION_LIMIT
    if not spec["deadline_tick"]:
        if not spend(len(slots)):
            return REJECTION_PROJECTION_LIMIT
        if not any(
            slot["state"] == SLOT_ACTIVE and slot["spec"]["deadline_tick"]
            for slot in slots
        ):
            return REJECTION_NONE
    if not spend(len(slots)):
        return REJECTION_PROJECTION_LIMIT

    projected: list[Record | None] = []
    for slot in slots:
        if slot["state"] != SLOT_ACTIVE:
            projected.append(None)
        else:
            projected.append(
                {
                    "active": True,
                    "weight": slot["spec"]["weight"],
                    "remaining": slot["remaining_quanta"],
                    "deadline_tick": slot["spec"]["deadline_tick"],
                }
            )
    projected[candidate_index] = {
        "active": True,
        "weight": spec["weight"],
        "remaining": spec["work_quanta"],
        "deadline_tick": spec["deadline_tick"],
    }
    deadline_count = sum(
        bool(slot and slot["active"] and slot["deadline_tick"]) for slot in projected
    )
    minimum_deadline_quanta = sum(
        slot["remaining"]
        for slot in projected
        if slot and slot["active"] and slot["deadline_tick"]
    )
    if minimum_deadline_quanta > max_quanta:
        return REJECTION_PROJECTION_LIMIT
    projected_quanta = 0
    tick = logical_tick
    while deadline_count:
        if projected_quanta >= max_quanta:
            return REJECTION_PROJECTION_LIMIT
        if not spend(len(projected)):
            return REJECTION_PROJECTION_LIMIT
        for slot in projected:
            if (
                slot
                and slot["active"]
                and slot["deadline_tick"]
                and tick >= slot["deadline_tick"]
            ):
                return REJECTION_DEADLINE_INFEASIBLE
        if not spend(len(projected)):
            return REJECTION_PROJECTION_LIMIT
        active_weights = [
            slot["weight"] for slot in projected if slot and slot["active"]
        ]
        if not active_weights:
            return (
                REJECTION_PROJECTION_LIMIT
                if budget_exhausted
                else REJECTION_DEADLINE_INFEASIBLE
            )
        maximum_active_weight = max(active_weights)
        cursor = min(cursor, len(projected))
        level = level or 1
        if level > maximum_active_weight or level > max_weight:
            level = 1
            cursor = 0
        selected: int | None = None
        for _ in range(len(projected) * max_weight):
            if not spend(1):
                return REJECTION_PROJECTION_LIMIT
            if cursor >= len(projected):
                cursor = 0
                level = 1 if level >= maximum_active_weight else level + 1
            index = cursor
            cursor += 1
            slot = projected[index]
            if slot and slot["active"] and slot["weight"] >= level:
                selected = index
                break
        if selected is None:
            return (
                REJECTION_PROJECTION_LIMIT
                if budget_exhausted
                else REJECTION_DEADLINE_INFEASIBLE
            )
        slot = projected[selected]
        assert slot is not None
        slot["remaining"] -= 1
        tick += 1
        projected_quanta += 1
        if slot["remaining"] == 0:
            if slot["deadline_tick"] and tick > slot["deadline_tick"]:
                return REJECTION_DEADLINE_INFEASIBLE
            deadline_count -= int(bool(slot["deadline_tick"]))
            slot["active"] = False
    return REJECTION_NONE


def _before_event(state: Mapping[str, Any]) -> Record:
    active, finished = _slot_counts(state)
    return {
        "state_before_sha256": _scheduler_state_sha256(state),
        "logical_tick_before": state["logical_tick"],
        "cursor_before": state["cursor"],
        "level_before": state["level"],
        "active_before": active,
        "finished_before": finished,
        "bank_used_before": deepcopy(state["used"]),
    }


def _validate_live_spec(state: Mapping[str, Any], spec: Mapping[str, Any]) -> None:
    if (
        not spec["tenant_key"]
        or not spec["request_key"]
        or not spec["request_generation"]
        or not spec["resource_owner_key"]
        or not 0 < spec["weight"] <= state["max_weight"]
        or not spec["work_quanta"]
        or not any(spec["claim"].values())
        or spec["claim"]["queue_slots"] != 1
        or (spec["deadline_tick"] and spec["deadline_tick"] <= state["logical_tick"])
    ):
        raise TypedWorkloadError("invalid live scheduler request")
    _host_bytes(spec["claim"])


def _admit(state: Record, item: Mapping[str, Any]) -> tuple[bool, Record, Record]:
    if state["closed"]:
        raise TypedWorkloadError("scheduler is closed")
    spec = _request_spec(item)
    _validate_live_spec(state, spec)
    before = _before_event(state)
    free_index: int | None = None
    rejection = REJECTION_NONE
    for index, slot in enumerate(state["slots"]):
        if (
            slot["state"] != SLOT_FREE
            and slot["spec"]["tenant_key"] == spec["tenant_key"]
        ):
            rejection = REJECTION_DUPLICATE_TENANT
            break
        if slot["state"] == SLOT_FREE and free_index is None:
            free_index = index
    if rejection == REJECTION_NONE and free_index is None:
        rejection = REJECTION_NO_SLOT
    next_used: Record | None = None
    if rejection == REJECTION_NONE:
        try:
            next_used = _claim_add(state["used"], spec["claim"])
        except TypedWorkloadError:
            rejection = REJECTION_RESOURCE_LIMIT
        if next_used is not None and not _fits(state["limits"], next_used):
            rejection = REJECTION_RESOURCE_LIMIT
    if rejection == REJECTION_NONE:
        assert free_index is not None
        rejection = _projection_rejection(
            state["slots"],
            free_index,
            spec,
            state["logical_tick"],
            state["cursor"],
            state["level"],
            state["max_weight"],
            state["max_projection_quanta"],
            state["max_projection_operations"],
        )
    if rejection != REJECTION_NONE:
        event = _emit_event(
            state,
            {
                **before,
                "kind": EVENT_ADMISSION_REJECTED,
                "rejection_reason": rejection,
                "spec": spec,
            },
        )
        return False, _zero_handle(), event

    assert free_index is not None and next_used is not None
    generation = state["next_slot_generation"]
    if generation in (0, U64_MAX) or generation != state["next_bank_generation"]:
        raise TypedWorkloadError("slot generation drift")
    receipt: Record = {
        "bank_epoch": state["bank_epoch"],
        "slot_index": free_index,
        "generation": generation,
        "owner_key": spec["resource_owner_key"],
        "claim": deepcopy(spec["claim"]),
        "integrity": _receipt_integrity(
            state["bank_epoch"],
            free_index,
            generation,
            spec["resource_owner_key"],
            spec["claim"],
        ),
    }
    receipt_root = resource_receipt_sha256(receipt)
    state["next_slot_generation"] += 1
    state["next_bank_generation"] += 1
    state["used"] = next_used
    state["peak"] = {
        name: max(state["peak"][name], next_used[name]) for name in CLAIM_FIELDS
    }
    state["peak_host_bytes"] = max(state["peak_host_bytes"], _host_bytes(next_used))
    state["successful_reservations"] += 1
    state["successful_commits"] += 1
    state["slots"][free_index] = {
        "state": SLOT_ACTIVE,
        "generation": generation,
        "spec": spec,
        "remaining_quanta": spec["work_quanta"],
        "admitted_tick": state["logical_tick"],
        "last_service_tick": state["logical_tick"],
        "service_count": 0,
        "receipt": receipt,
        "receipt_sha256": receipt_root,
    }
    handle = _handle_for(state, free_index)
    event = _emit_event(
        state,
        {
            **before,
            "kind": EVENT_ADMISSION_ACCEPTED,
            "handle": handle,
            "spec": spec,
            "resource_receipt": receipt,
            "resource_receipt_sha256": receipt_root,
            "remaining_after": spec["work_quanta"],
        },
    )
    return True, handle, event


def _selection_preserves_deadlines(
    slots: Sequence[Mapping[str, Any]], selected_index: int, after_tick: int
) -> bool:
    for index, slot in enumerate(slots):
        if slot["state"] != SLOT_ACTIVE or not slot["spec"]["deadline_tick"]:
            continue
        completes = index == selected_index and slot["remaining_quanta"] == 1
        if completes:
            if after_tick > slot["spec"]["deadline_tick"]:
                return False
        elif after_tick >= slot["spec"]["deadline_tick"]:
            return False
    return True


def _service(state: Record) -> tuple[int, Record]:
    selected, cursor_after, level_after = _select_iwrr(
        state["slots"],
        state["cursor"],
        state["level"],
        state["max_weight"],
    )
    slot = state["slots"][selected]
    if slot["state"] != SLOT_ACTIVE or not slot["remaining_quanta"]:
        raise TypedWorkloadError("selected slot is not runnable")
    before = _before_event(state)
    after_tick = state["logical_tick"] + 1
    _u64(after_tick)
    if not _selection_preserves_deadlines(state["slots"], selected, after_tick):
        raise TypedWorkloadError("service violates a logical deadline")
    wait_quanta = after_tick - slot["last_service_tick"]
    if wait_quanta > state["maximum_service_gap"]:
        raise TypedWorkloadError("service gap invariant failed")
    handle = _handle_for(state, selected)
    spec = deepcopy(slot["spec"])
    receipt = deepcopy(slot["receipt"])
    receipt_root = slot["receipt_sha256"]
    remaining_before = slot["remaining_quanta"]
    slot["remaining_quanta"] -= 1
    slot["last_service_tick"] = after_tick
    slot["service_count"] += 1
    if slot["remaining_quanta"] == 0:
        slot["state"] = SLOT_FINISHED
    state["logical_tick"] = after_tick
    state["cursor"] = cursor_after
    state["level"] = level_after
    event = _emit_event(
        state,
        {
            **before,
            "kind": EVENT_SERVICE,
            "handle": handle,
            "spec": spec,
            "resource_receipt": receipt,
            "resource_receipt_sha256": receipt_root,
            "remaining_before": remaining_before,
            "remaining_after": slot["remaining_quanta"],
            "wait_quanta": wait_quanta,
        },
    )
    return selected, event


def _finish_slot(
    state: Record, handle: Mapping[str, int], event_kind: int, required_state: int
) -> Record:
    index = handle["slot_index"]
    if not 0 <= index < len(state["slots"]):
        raise TypedWorkloadError("stale scheduler handle")
    slot = state["slots"][index]
    if (
        slot["state"] != required_state
        or slot["generation"] != handle["slot_generation"]
        or slot["spec"]["tenant_key"] != handle["tenant_key"]
        or slot["spec"]["request_key"] != handle["request_key"]
        or slot["spec"]["request_generation"] != handle["request_generation"]
        or handle["scheduler_epoch"] != state["scheduler_epoch"]
    ):
        raise TypedWorkloadError("stale scheduler handle")
    before = _before_event(state)
    spec = deepcopy(slot["spec"])
    receipt = deepcopy(slot["receipt"])
    receipt_root = slot["receipt_sha256"]
    remaining = slot["remaining_quanta"]
    state["used"] = _claim_subtract(state["used"], spec["claim"])
    state["slots"][index] = _free_slot()
    state["releases"] += 1
    return _emit_event(
        state,
        {
            **before,
            "kind": event_kind,
            "handle": deepcopy(handle),
            "spec": spec,
            "resource_receipt": receipt,
            "resource_receipt_sha256": receipt_root,
            "remaining_before": remaining,
        },
    )


def _close_scheduler(state: Record) -> Record:
    if any(_slot_counts(state)) or any(state["used"].values()):
        raise TypedWorkloadError("scheduler did not drain")
    before = _before_event(state)
    state["closed"] = True
    return _emit_event(state, {**before, "kind": EVENT_CLOSE})


def trace_record_sha256(value: Any) -> bytes:
    source = _strict_record(value, TRACE_FIELDS, "trace record")
    return _sha(
        TRACE_RECORD_DOMAIN,
        _u64(TRACE_ABI),
        *(_u64(int(source[name])) for name in TRACE_SCALAR_FIELDS),
        _digest(source["scheduler_event_sha256"]),
    )


def _append_trace(
    trace: list[Record],
    *,
    driver_step: int,
    item_ordinal: int,
    profile_index: int,
    terminal_action: int,
    event: Mapping[str, Any],
) -> bytes:
    if len(trace) >= MAXIMUM_TRACE_RECORDS:
        raise TypedWorkloadError("trace storage exhausted")
    record: Record = {
        "sequence": len(trace),
        "driver_step": driver_step,
        "item_ordinal": item_ordinal,
        "profile_index": profile_index,
        "event_kind": event["kind"],
        "scheduler_event_sequence": event["event_sequence"],
        "rejection_reason": event["rejection_reason"],
        "terminal_action": terminal_action,
        "logical_tick_before": event["logical_tick_before"],
        "logical_tick_after": event["logical_tick_after"],
        "remaining_before": event["remaining_before"],
        "remaining_after": event["remaining_after"],
        "wait_quanta": event["wait_quanta"],
        "active_after": event["active_after"],
        "finished_after": event["finished_after"],
        "scheduler_event_sha256": event["event_sha256"],
        "record_sha256": ZERO_DIGEST,
    }
    record["record_sha256"] = trace_record_sha256(record)
    trace.append(record)
    return record["record_sha256"]


def trace_sha256(value: Any) -> bytes:
    if not isinstance(value, list) or not 0 < len(value) <= MAXIMUM_TRACE_RECORDS:
        raise TypedWorkloadError("invalid trace count")
    roots: list[bytes] = []
    for index, record in enumerate(value):
        source = _strict_record(record, TRACE_FIELDS, "trace record")
        if (
            source["sequence"] != index
            or source["scheduler_event_sequence"] != index
            or not hmac.compare_digest(
                _digest(source["record_sha256"]),
                trace_record_sha256(source),
            )
        ):
            raise TypedWorkloadError("trace record mismatch")
        roots.append(source["record_sha256"])
    return _sha(TRACE_DOMAIN, _u64(TRACE_ABI), _u64(len(value)), *roots)


def outcome_record_sha256(value: Any) -> bytes:
    source = _strict_record(value, OUTCOME_FIELDS, "outcome")
    return _sha(
        OUTCOME_DOMAIN,
        _u64(OUTCOME_ABI),
        _u64(source["ordinal"]),
        _digest(source["item_sha256"]),
        _u64(source["profile_index"]),
        _digest(source["profile_sha256"]),
        *(_u64(source[name]) for name in OUTCOME_SCALAR_FIELDS[2:]),
        _digest(source["admission_trace_sha256"]),
        _digest(source["terminal_trace_sha256"]),
    )


def outcome_sha256(value: Any) -> bytes:
    if not isinstance(value, list) or not 0 < len(value) <= MAXIMUM_ITEMS:
        raise TypedWorkloadError("invalid outcome count")
    roots: list[bytes] = []
    for index, outcome in enumerate(value):
        source = _strict_record(outcome, OUTCOME_FIELDS, "outcome")
        if source["ordinal"] != index or not hmac.compare_digest(
            _digest(source["record_sha256"]),
            outcome_record_sha256(source),
        ):
            raise TypedWorkloadError("outcome record mismatch")
        roots.append(source["record_sha256"])
    return _sha(
        OUTCOME_SECTION_DOMAIN,
        _u64(OUTCOME_ABI),
        _u64(len(value)),
        *roots,
    )


def summary_sha256(value: Any) -> bytes:
    source = _strict_record(value, SUMMARY_FIELDS, "summary")
    peak = _validate_claim(source["peak"])
    return _sha(
        SUMMARY_DOMAIN,
        _u64(SUMMARY_ABI),
        *(_u64(int(source[name])) for name in SUMMARY_SCALAR_FIELDS),
        *_hash_claim(peak),
    )


def result_sha256(
    plan_root: bytes,
    outcome_root: bytes,
    trace_root: bytes,
    summary_root: bytes,
) -> bytes:
    return _sha(
        RESULT_DOMAIN,
        _u64(RESULT_ABI),
        _digest(plan_root),
        _digest(outcome_root),
        _digest(trace_root),
        _digest(summary_root),
    )


def _new_runtime_item() -> Record:
    return {
        "state": "pending",
        "handle": _zero_handle(),
        "admitted_step": ABSENT,
        "first_service_step": ABSENT,
        "terminal_step": ABSENT,
        "served_quanta": 0,
        "fairness_quanta": 0,
        "maximum_wait_quanta": 0,
        "admission_trace_sha256": ZERO_DIGEST,
        "terminal_trace_sha256": ZERO_DIGEST,
        "outcome": None,
        "rejection_reason": REJECTION_NONE,
        "terminal_action": ACTION_NONE,
    }


def replay_plan(value: Any) -> Record:
    """Replay the direct W4a arrival/action/service/retire state machine."""

    plan = validate_plan(value)
    scheduler = _new_scheduler(plan)
    runtime = [_new_runtime_item() for _ in plan["items"]]
    trace: list[Record] = []
    maximum_live_receipts = 0
    driver_steps = 0
    service_quanta = 0
    binds = 0
    cancels = 0
    services = 0
    final_services = 0
    retires = 0
    completed = False

    for step in range(plan["max_driver_steps"]):
        for index, item in enumerate(plan["items"]):
            if item["arrival_step"] != step:
                continue
            state = runtime[index]
            if state["state"] != "pending":
                raise TypedWorkloadError("item arrived more than once")
            admitted, handle, event = _admit(scheduler, item)
            if admitted:
                state.update(
                    {
                        "state": "active",
                        "handle": handle,
                        "admitted_step": step,
                    }
                )
                binds += 1
                maximum_live_receipts = max(
                    maximum_live_receipts, sum(_slot_counts(scheduler))
                )
                state["admission_trace_sha256"] = _append_trace(
                    trace,
                    driver_step=step,
                    item_ordinal=item["ordinal"],
                    profile_index=item["profile_index"],
                    terminal_action=ACTION_NONE,
                    event=event,
                )
            else:
                state.update(
                    {
                        "state": "terminal",
                        "outcome": OUTCOME_REJECTED,
                        "rejection_reason": event["rejection_reason"],
                        "terminal_step": step,
                    }
                )
                root = _append_trace(
                    trace,
                    driver_step=step,
                    item_ordinal=item["ordinal"],
                    profile_index=item["profile_index"],
                    terminal_action=ACTION_NONE,
                    event=event,
                )
                state["admission_trace_sha256"] = root
                state["terminal_trace_sha256"] = root

        for index, item in enumerate(plan["items"]):
            if item["terminal_action_step"] != step:
                continue
            state = runtime[index]
            if state["state"] == "terminal":
                continue
            if state["state"] != "active" or item["terminal_action"] == ACTION_NONE:
                raise TypedWorkloadError("terminal action lacks active request")
            event = _finish_slot(
                scheduler,
                state["handle"],
                EVENT_CANCEL,
                SLOT_ACTIVE,
            )
            cancels += 1
            state.update(
                {
                    "state": "terminal",
                    "terminal_step": step,
                    "terminal_action": item["terminal_action"],
                    "outcome": (
                        OUTCOME_CANCELLED
                        if item["terminal_action"] == ACTION_CANCEL
                        else OUTCOME_TIMED_OUT
                    ),
                }
            )
            state["terminal_trace_sha256"] = _append_trace(
                trace,
                driver_step=step,
                item_ordinal=item["ordinal"],
                profile_index=item["profile_index"],
                terminal_action=item["terminal_action"],
                event=event,
            )

        active, _ = _slot_counts(scheduler)
        if active:
            if service_quanta >= plan["max_service_quanta"]:
                raise TypedWorkloadError("service quantum limit exceeded")
            selected, event = _service(scheduler)
            item_index = next(
                (
                    index
                    for index, state in enumerate(runtime)
                    if state["state"] == "active"
                    and state["handle"]["slot_index"] == selected
                    and state["handle"]["slot_generation"]
                    == event["handle"]["slot_generation"]
                ),
                None,
            )
            if item_index is None:
                raise TypedWorkloadError("service handle lost its item")
            item = plan["items"][item_index]
            state = runtime[item_index]
            service_quanta += 1
            services += 1
            final_quantum = event["remaining_after"] == 0
            final_services += int(final_quantum)
            if state["first_service_step"] == ABSENT:
                state["first_service_step"] = step
            state["served_quanta"] += 1
            state["maximum_wait_quanta"] = max(
                state["maximum_wait_quanta"], event["wait_quanta"]
            )
            if (
                item["fairness_member"]
                and plan["fairness_start_tick"]
                < event["logical_tick_after"]
                <= plan["fairness_end_tick"]
            ):
                state["fairness_quanta"] += 1
            _append_trace(
                trace,
                driver_step=step,
                item_ordinal=item["ordinal"],
                profile_index=item["profile_index"],
                terminal_action=ACTION_NONE,
                event=event,
            )
            if final_quantum:
                retire_event = _finish_slot(
                    scheduler,
                    state["handle"],
                    EVENT_RETIRE,
                    SLOT_FINISHED,
                )
                retires += 1
                state.update(
                    {
                        "state": "terminal",
                        "outcome": OUTCOME_COMPLETED,
                        "terminal_step": step,
                    }
                )
                state["terminal_trace_sha256"] = _append_trace(
                    trace,
                    driver_step=step,
                    item_ordinal=item["ordinal"],
                    profile_index=item["profile_index"],
                    terminal_action=ACTION_NONE,
                    event=retire_event,
                )

        maximum_live_receipts = max(maximum_live_receipts, sum(_slot_counts(scheduler)))
        if all(state["state"] == "terminal" for state in runtime):
            driver_steps = step + 1
            completed = True
            break
    if not completed:
        raise TypedWorkloadError("driver step limit exceeded")

    close_event = _close_scheduler(scheduler)
    _append_trace(
        trace,
        driver_step=driver_steps,
        item_ordinal=ABSENT,
        profile_index=ABSENT,
        terminal_action=ACTION_NONE,
        event=close_event,
    )

    outcomes: list[Record] = []
    for item, state in zip(plan["items"], runtime):
        kind = state["outcome"]
        if kind is None:
            raise TypedWorkloadError("incomplete item outcome")
        outcome: Record = {
            "ordinal": item["ordinal"],
            "item_sha256": item["item_sha256"],
            "profile_index": item["profile_index"],
            "profile_sha256": item["profile_sha256"],
            "kind": kind,
            "rejection_reason": state["rejection_reason"],
            "terminal_action": state["terminal_action"],
            "scheduler_slot_index": (
                ABSENT if kind == OUTCOME_REJECTED else state["handle"]["slot_index"]
            ),
            "scheduler_slot_generation": (
                0 if kind == OUTCOME_REJECTED else state["handle"]["slot_generation"]
            ),
            "admitted_step": state["admitted_step"],
            "first_service_step": state["first_service_step"],
            "terminal_step": state["terminal_step"],
            "served_quanta": state["served_quanta"],
            "maximum_wait_quanta": state["maximum_wait_quanta"],
            "admission_trace_sha256": state["admission_trace_sha256"],
            "terminal_trace_sha256": state["terminal_trace_sha256"],
            "record_sha256": ZERO_DIGEST,
        }
        outcome["record_sha256"] = outcome_record_sha256(outcome)
        outcomes.append(outcome)

    counts = {
        OUTCOME_COMPLETED: sum(
            outcome["kind"] == OUTCOME_COMPLETED for outcome in outcomes
        ),
        OUTCOME_REJECTED: sum(
            outcome["kind"] == OUTCOME_REJECTED for outcome in outcomes
        ),
        OUTCOME_CANCELLED: sum(
            outcome["kind"] == OUTCOME_CANCELLED for outcome in outcomes
        ),
        OUTCOME_TIMED_OUT: sum(
            outcome["kind"] == OUTCOME_TIMED_OUT for outcome in outcomes
        ),
    }
    admitted = (
        counts[OUTCOME_COMPLETED]
        + counts[OUTCOME_CANCELLED]
        + counts[OUTCOME_TIMED_OUT]
    )
    maximum_wait = max(
        (outcome["maximum_wait_quanta"] for outcome in outcomes), default=0
    )
    fairness_error = 0
    for left_index, (left_item, left_state) in enumerate(zip(plan["items"], runtime)):
        if not left_item["fairness_member"]:
            continue
        for right_item, right_state in zip(
            plan["items"][left_index + 1 :],
            runtime[left_index + 1 :],
        ):
            if not right_item["fairness_member"]:
                continue
            fairness_error = max(
                fairness_error,
                abs(
                    left_state["fairness_quanta"] * right_item["weight"]
                    - right_state["fairness_quanta"] * left_item["weight"]
                ),
            )
    final_active, final_finished = _slot_counts(scheduler)
    summary: Record = {
        "profile_count": len(plan["profiles"]),
        "item_count": len(plan["items"]),
        "attempted": len(plan["items"]),
        "admitted": admitted,
        "rejected": counts[OUTCOME_REJECTED],
        "completed": counts[OUTCOME_COMPLETED],
        "cancelled": counts[OUTCOME_CANCELLED],
        "timed_out": counts[OUTCOME_TIMED_OUT],
        "service_quanta": service_quanta,
        "driver_steps": driver_steps,
        "final_logical_tick": scheduler["logical_tick"],
        "maximum_live_receipts": maximum_live_receipts,
        "peak_host_bytes": scheduler["peak_host_bytes"],
        "maximum_wait_quanta": maximum_wait,
        "maximum_service_gap": scheduler["maximum_service_gap"],
        "fairness_cross_product_error": fairness_error,
        "bind_callbacks": binds,
        "cancel_callbacks": cancels,
        "service_callbacks": services,
        "final_service_callbacks": final_services,
        "retire_callbacks": retires,
        "final_active": final_active,
        "final_finished": final_finished,
        "final_active_reservations": 0,
        "final_committed_receipts": sum(_slot_counts(scheduler)),
        "successful_commits": scheduler["successful_commits"],
        "releases": scheduler["releases"],
        "bank_cancellations": scheduler["bank_cancellations"],
        "bank_rejected_capacity": scheduler["bank_rejected_capacity"],
        "bank_rejected_slots": scheduler["bank_rejected_slots"],
        "zero_orphan_ownership": (
            final_active == 0
            and final_finished == 0
            and not any(scheduler["used"].values())
            and scheduler["successful_commits"] == scheduler["releases"]
            and scheduler["closed"]
        ),
        "peak": deepcopy(scheduler["peak"]),
    }
    plan_root = plan_sha256(plan)
    outcome_root = outcome_sha256(outcomes)
    trace_root = trace_sha256(trace)
    summary_root = summary_sha256(summary)
    result: Record = {
        "plan_sha256": plan_root,
        "outcome_sha256": outcome_root,
        "trace_sha256": trace_root,
        "summary_sha256": summary_root,
        "result_sha256": result_sha256(
            plan_root, outcome_root, trace_root, summary_root
        ),
        "outcomes": outcomes,
        "trace": trace,
        "summary": summary,
    }
    validate_result_structure(plan, result)
    return result


def _canonical_outcome(value: Any) -> Record:
    source = _strict_record(value, OUTCOME_FIELDS, "outcome")
    result: Record = {}
    for name in OUTCOME_SCALAR_FIELDS:
        result[name] = _integer(source[name], f"outcome.{name}")
    for name in (
        "item_sha256",
        "profile_sha256",
        "admission_trace_sha256",
        "terminal_trace_sha256",
        "record_sha256",
    ):
        result[name] = _digest(source[name])
    return {name: result[name] for name in OUTCOME_FIELDS}


def _canonical_trace_record(value: Any) -> Record:
    source = _strict_record(value, TRACE_FIELDS, "trace record")
    result: Record = {}
    for name in TRACE_SCALAR_FIELDS:
        result[name] = _integer(source[name], f"trace.{name}")
    result["scheduler_event_sha256"] = _digest(source["scheduler_event_sha256"])
    result["record_sha256"] = _digest(source["record_sha256"])
    return result


def _canonical_summary(value: Any) -> Record:
    source = _strict_record(value, SUMMARY_FIELDS, "summary")
    result: Record = {}
    for name in SUMMARY_SCALAR_FIELDS:
        if name == "zero_orphan_ownership":
            result[name] = _boolean(source[name], name)
        else:
            result[name] = _integer(source[name], name)
    result["peak"] = _validate_claim(source["peak"])
    return result


def validate_result_structure(plan_value: Any, value: Any) -> Record:
    plan = validate_plan(plan_value)
    source = _strict_record(value, RESULT_FIELDS, "result")
    outcomes_value = source["outcomes"]
    trace_value = source["trace"]
    if (
        not isinstance(outcomes_value, list)
        or len(outcomes_value) != len(plan["items"])
        or not isinstance(trace_value, list)
        or not 0 < len(trace_value) <= MAXIMUM_TRACE_RECORDS
    ):
        raise TypedWorkloadError("invalid result sections")
    outcomes = [_canonical_outcome(outcome) for outcome in outcomes_value]
    trace = [_canonical_trace_record(record) for record in trace_value]
    summary = _canonical_summary(source["summary"])
    result: Record = {
        "plan_sha256": _digest(source["plan_sha256"]),
        "outcome_sha256": _digest(source["outcome_sha256"]),
        "trace_sha256": _digest(source["trace_sha256"]),
        "summary_sha256": _digest(source["summary_sha256"]),
        "result_sha256": _digest(source["result_sha256"]),
        "outcomes": outcomes,
        "trace": trace,
        "summary": summary,
    }
    expected_plan = plan_sha256(plan)
    expected_outcomes = outcome_sha256(outcomes)
    expected_trace = trace_sha256(trace)
    expected_summary = summary_sha256(summary)
    expected_result = result_sha256(
        expected_plan, expected_outcomes, expected_trace, expected_summary
    )
    retained = (
        result["plan_sha256"],
        result["outcome_sha256"],
        result["trace_sha256"],
        result["summary_sha256"],
        result["result_sha256"],
    )
    expected = (
        expected_plan,
        expected_outcomes,
        expected_trace,
        expected_summary,
        expected_result,
    )
    if any(
        not hmac.compare_digest(actual, canonical)
        for actual, canonical in zip(retained, expected)
    ):
        raise TypedWorkloadError("result semantic root mismatch")
    if (
        summary["profile_count"] != len(plan["profiles"])
        or summary["item_count"] != len(plan["items"])
        or summary["attempted"] != len(plan["items"])
        or summary["admitted"] + summary["rejected"] != summary["attempted"]
        or summary["completed"] + summary["cancelled"] + summary["timed_out"]
        != summary["admitted"]
        or summary["bind_callbacks"] != summary["admitted"]
        or summary["cancel_callbacks"] != summary["cancelled"] + summary["timed_out"]
        or summary["service_callbacks"] != summary["service_quanta"]
        or summary["final_service_callbacks"] != summary["completed"]
        or summary["retire_callbacks"] != summary["completed"]
        or summary["final_logical_tick"] != summary["service_quanta"]
        or summary["successful_commits"] != summary["admitted"]
        or summary["releases"] != summary["admitted"]
        or summary["bank_cancellations"] != 0
        or summary["bank_rejected_capacity"] != 0
        or summary["bank_rejected_slots"] != 0
        or not summary["zero_orphan_ownership"]
        or any(
            summary[name]
            for name in (
                "final_active",
                "final_finished",
                "final_active_reservations",
                "final_committed_receipts",
            )
        )
    ):
        raise TypedWorkloadError("result summary contradiction")
    for item, outcome in zip(plan["items"], outcomes):
        if (
            outcome["ordinal"] != item["ordinal"]
            or outcome["profile_index"] != item["profile_index"]
            or not hmac.compare_digest(outcome["item_sha256"], item["item_sha256"])
            or not hmac.compare_digest(
                outcome["profile_sha256"], item["profile_sha256"]
            )
        ):
            raise TypedWorkloadError("outcome/item substitution")
    terminal = trace[-1]
    if (
        terminal["event_kind"] != EVENT_CLOSE
        or terminal["item_ordinal"] != ABSENT
        or terminal["profile_index"] != ABSENT
        or terminal["driver_step"] != summary["driver_steps"]
    ):
        raise TypedWorkloadError("trace is not canonically closed")
    return result


def validate_result_by_replay(plan_value: Any, value: Any) -> Record:
    plan = validate_plan(plan_value)
    actual = validate_result_structure(plan, value)
    expected = replay_plan(plan)
    if actual != expected:
        raise TypedWorkloadError("result differs from canonical logical replay")
    return actual


def _json_ready(value: Any) -> Any:
    if type(value) is bytes:
        return value.hex()
    if isinstance(value, dict):
        return {name: _json_ready(item) for name, item in value.items()}
    if isinstance(value, list):
        return [_json_ready(item) for item in value]
    if type(value) in (int, bool, str) or value is None:
        return value
    raise TypedWorkloadError("value is not JSON representable")


def _restore_digests(value: Any) -> Any:
    if isinstance(value, dict):
        return {name: _restore_digests(item) for name, item in value.items()}
    if isinstance(value, list):
        return [_restore_digests(item) for item in value]
    if (
        type(value) is str
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    ):
        return bytes.fromhex(value)
    return value


def canonical_json_dumps(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            _json_ready(value),
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as error:
        raise TypedWorkloadError("JSON encoding failed") from error
    return (encoded + "\n").encode("ascii")


def _reject_constant(value: str) -> None:
    raise TypedWorkloadError(f"non-finite JSON constant: {value}")


def _unique_object(pairs: list[tuple[str, Any]]) -> Record:
    result: Record = {}
    for name, value in pairs:
        if name in result:
            raise TypedWorkloadError("duplicate JSON key")
        result[name] = value
    return result


def canonical_json_loads(value: Any) -> Record:
    if type(value) is not bytes or not 0 < len(value) <= MAXIMUM_JSON_BYTES:
        raise TypedWorkloadError("invalid JSON byte envelope")
    try:
        text = value.decode("ascii")
        parsed = json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TypedWorkloadError("invalid canonical JSON") from error
    restored = _restore_digests(parsed)
    if not isinstance(restored, dict) or canonical_json_dumps(restored) != value:
        raise TypedWorkloadError("JSON is not canonical")
    return restored


def plan_document(plan_value: Any) -> Record:
    plan = validate_plan(plan_value)
    wire = encode_plan(plan)
    return {
        "schema": PLAN_SCHEMA,
        "kind": "plan",
        "plan": plan,
        "plan_sha256": plan_sha256(plan),
        "plan_wire_bytes": len(wire),
        "plan_wire_sha256": hashlib.sha256(wire).digest(),
    }


def result_document(plan_value: Any, result_value: Any) -> Record:
    plan = validate_plan(plan_value)
    result = validate_result_by_replay(plan, result_value)
    wire = encode_plan(plan)
    return {
        "schema": RESULT_SCHEMA,
        "kind": "result",
        "plan": plan,
        "plan_wire_bytes": len(wire),
        "plan_wire_sha256": hashlib.sha256(wire).digest(),
        "result": result,
    }


def verify_document(value: Any) -> Record:
    if not isinstance(value, dict):
        raise TypedWorkloadError("document must be an object")
    kind = value.get("kind")
    if kind == "plan":
        source = _strict_record(
            value,
            (
                "schema",
                "kind",
                "plan",
                "plan_sha256",
                "plan_wire_bytes",
                "plan_wire_sha256",
            ),
            "plan document",
        )
        if source["schema"] != PLAN_SCHEMA:
            raise TypedWorkloadError("unsupported plan JSON schema")
        expected = plan_document(source["plan"])
    elif kind == "result":
        source = _strict_record(
            value,
            (
                "schema",
                "kind",
                "plan",
                "plan_wire_bytes",
                "plan_wire_sha256",
                "result",
            ),
            "result document",
        )
        if source["schema"] != RESULT_SCHEMA:
            raise TypedWorkloadError("unsupported result JSON schema")
        expected = result_document(source["plan"], source["result"])
    else:
        raise TypedWorkloadError("unsupported document kind")
    if value != expected:
        raise TypedWorkloadError("canonical document mismatch")
    return deepcopy(expected)


def encode_document(value: Any) -> bytes:
    return canonical_json_dumps(verify_document(value))


def decode_document(value: Any) -> Record:
    return verify_document(canonical_json_loads(value))


def write_document(path_value: str | os.PathLike[str], value: Any) -> None:
    path = Path(path_value)
    payload = encode_document(value)
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


def read_document(path_value: str | os.PathLike[str]) -> Record:
    path = Path(path_value)
    try:
        size = path.stat().st_size
        if not 0 < size <= MAXIMUM_JSON_BYTES:
            raise TypedWorkloadError("JSON file exceeds its bound")
        return decode_document(path.read_bytes())
    except OSError as error:
        raise TypedWorkloadError("JSON file read failed") from error


def reference_support_record(index: int) -> Record:
    """Return one retained perception support record without native state."""

    records = (
        {
            "family": 3,
            "operation": 3,
            "input_kind": 3,
            "output_kind": 2,
            "numerical_policy": 1,
            "max_batch_items": 64,
            "max_input_features": 65_536,
            "max_output_dimensions": 16_384,
            "allowed_capabilities": 0,
        },
        {
            "family": 4,
            "operation": 3,
            "input_kind": 4,
            "output_kind": 2,
            "numerical_policy": 1,
            "max_batch_items": 4_096,
            "max_input_features": 16_384,
            "max_output_dimensions": 16_384,
            "allowed_capabilities": 0,
        },
        {
            "family": 6,
            "operation": 3,
            "input_kind": 5,
            "output_kind": 2,
            "numerical_policy": 1,
            "max_batch_items": 4_096,
            "max_input_features": 1_048_576,
            "max_output_dimensions": 16_384,
            "allowed_capabilities": 0,
        },
    )
    if type(index) is not int or not 0 <= index < len(records):
        raise TypedWorkloadError("unknown reference profile")
    return validate_support_record(records[index])


def _reference_profiles() -> list[Record]:
    adapter_abis = (
        0x4756454E00000001,
        0x4741574500000001,
        0x4754564500000001,
    )
    artifact_roots = (
        "834970076a3a58c3049e4daae7ff27ae9c133a430d9ec8fd915828d17c5ca36f",
        "646c6e43b173de2b115d773f4f83936344625c947383b70a6f407d3561cae7d4",
        "d7effeac9770e889f7e6d1f68e94ff0ce41b09a867eebc28ed4117a75675f3c8",
    )
    execution_plan_roots = (
        "9002aaae47c69f3b5963ad7571ddfeaeb100df4e344cac33e30e67adf65bf38d",
        "1e7987c3f9b86926c548ce810d3749a9da2c3520e2ba78fb49b6de6d4bbd30cf",
        "0005da45e66510150f3f00288c2b769e0ff73f03ade97fa8ca5e9a65da7e0553",
    )
    implementation_labels = (
        b"glacier reference vision implementation v1",
        b"glacier reference audio-window implementation v1",
        b"glacier reference temporal-video implementation v1",
    )
    outputs = (
        (30, 6, 70, 6),
        (500, 500, 500, 1500),
        (5, 5, 17, 13),
    )
    claims = (
        claim(
            capsule_bytes=8,
            activation_bytes=8,
            partial_bytes=16,
            output_journal_bytes=16,
            queue_slots=1,
        ),
        claim(
            capsule_bytes=8,
            activation_bytes=8,
            partial_bytes=16,
            output_journal_bytes=16,
            queue_slots=1,
        ),
        claim(
            capsule_bytes=4,
            activation_bytes=4,
            partial_bytes=16,
            output_journal_bytes=16,
            staging_bytes=4,
            queue_slots=1,
        ),
    )
    profiles: list[Record] = []
    for index in range(3):
        support = reference_support_record(index)
        encoded_output = b"".join(
            value.to_bytes(4, "little", signed=True) for value in outputs[index]
        )
        profiles.append(
            seal_profile(
                {
                    "index": index,
                    "family": support["family"],
                    "operation": support["operation"],
                    "input_kind": support["input_kind"],
                    "output_kind": support["output_kind"],
                    "numerical_policy": support["numerical_policy"],
                    "adapter_abi": adapter_abis[index],
                    "lifecycle": LIFECYCLE_STATELESS,
                    "execution_unit": EXECUTION_OPERATION,
                    "cancellation_boundary": CANCELLATION_BETWEEN_UNITS,
                    "publication_policy": PUBLICATION_FINAL_ONLY,
                    "correctness_gate": CORRECTNESS_EXACT,
                    "claim": claims[index],
                    "support_sha256": support_record_sha256(support),
                    "artifact_sha256": bytes.fromhex(artifact_roots[index]),
                    "execution_plan_sha256": bytes.fromhex(execution_plan_roots[index]),
                    "adapter_implementation_sha256": hashlib.sha256(
                        implementation_labels[index]
                    ).digest(),
                    "correctness_sha256": hashlib.sha256(encoded_output).digest(),
                    "profile_sha256": ZERO_DIGEST,
                }
            )
        )
    return profiles


def reference_plan() -> Record:
    """Return the canonical six-item typed perception plan."""

    profiles = _reference_profiles()
    input_roots = (
        "e7365d346e47dc802f909b3a84484767bbada232de7a6383fc193fc1eb566dee",
        "b65fce1e3bd5486b480cd700b7e8b586ebd6f0d14a65ab172af4d7a4c9e6cedd",
        "cbdf30f05789216a9a4c3e57d91eed914f8a970a90edc3ecf3fde6db17eeb1ed",
    )
    item_specs = (
        (0, 0, 0, 8, 1, ACTION_CANCEL),
        (1, 1, 0, 8, 2, ACTION_TIMEOUT),
        (2, 2, 0, 1, ABSENT, ACTION_NONE),
        (3, 2, 1, 1, ABSENT, ACTION_NONE),
        (4, 0, 2, 1, ABSENT, ACTION_NONE),
        (5, 1, 3, 1, ABSENT, ACTION_NONE),
    )
    items: list[Record] = []
    for ordinal, profile_index, arrival, work, action_step, action in item_specs:
        profile = profiles[profile_index]
        identity = ordinal + 1
        items.append(
            seal_item(
                {
                    "ordinal": ordinal,
                    "profile_index": profile_index,
                    "profile_sha256": profile["profile_sha256"],
                    "arrival_step": arrival,
                    "weight": 1,
                    "work_quanta": work,
                    "deadline_tick": 0,
                    "terminal_action_step": action_step,
                    "terminal_action": action,
                    "fairness_member": True,
                    "tenant_key": 0x7100 + identity,
                    "request_key": 0x7200 + identity,
                    "request_generation": 1,
                    "resource_owner_key": 0x7300 + identity,
                    "claim": deepcopy(profile["claim"]),
                    "input_binding_sha256": bytes.fromhex(input_roots[profile_index]),
                    "item_sha256": ZERO_DIGEST,
                }
            )
        )
    return validate_plan(
        {
            "seed": 0x4757504300000001,
            "capacity": 3,
            "max_driver_steps": 32,
            "max_service_quanta": 32,
            "fairness_start_tick": 0,
            "fairness_end_tick": 16,
            "bank_epoch": 0x47575043424B0001,
            "scheduler_epoch": 0x4757504353430001,
            "max_weight": 1,
            "max_projection_quanta": 64,
            "max_projection_operations": 256,
            "limits": limits(
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
            "challenge": hashlib.sha256(
                b"typed perception reference campaign v1"
            ).digest(),
            "profiles": profiles,
            "items": items,
        }
    )


def run_fixture(
    fixture_factory: FixtureFactory,
    *,
    result_observer: ResultObserver | None = None,
) -> Record:
    """Run a caller-supplied fixture without granting mutation authority."""

    plan = validate_plan(fixture_factory())
    result = replay_plan(plan)
    if result_observer is not None:
        result_observer(deepcopy(plan), deepcopy(result))
    return result_document(plan, result)


def verify_fixture(
    document_value: Any,
    *,
    concrete_evidence: Any = None,
    evidence_verifier: EvidenceVerifier | None = None,
) -> Record:
    """Verify core semantics, then optionally invoke a concrete evidence hook."""

    document = verify_document(document_value)
    if document["kind"] != "result":
        raise TypedWorkloadError("fixture document does not contain a result")
    if evidence_verifier is not None:
        evidence_verifier(
            deepcopy(document["plan"]),
            deepcopy(document["result"]),
            concrete_evidence,
        )
    elif concrete_evidence is not None:
        raise TypedWorkloadError("concrete evidence lacks a verifier")
    return document


def _reference_evidence_summary(
    plan: Record,
    result: Record,
) -> Record:
    summary = result["summary"]
    completed_by_profile = [0] * len(plan["profiles"])
    for item, outcome in zip(
        plan["items"],
        result["outcomes"],
        strict=True,
    ):
        if outcome["kind"] == OUTCOME_COMPLETED:
            completed_by_profile[item["profile_index"]] += 1
    if completed_by_profile != [1, 1, 1]:
        raise TypedWorkloadError("reference family completion counts changed")
    cache_operations = summary["admitted"] * 3
    evidence_summary = {
        "profile_count": summary["profile_count"],
        "item_count": summary["item_count"],
        "admitted": summary["admitted"],
        "rejected": summary["rejected"],
        "completed": summary["completed"],
        "cancelled": summary["cancelled"],
        "timed_out": summary["timed_out"],
        "vision_completed": completed_by_profile[0],
        "audio_window_completed": completed_by_profile[1],
        "temporal_video_completed": completed_by_profile[2],
        "publications": summary["completed"],
        "nonpublished_terminal_items": (
            summary["rejected"] + summary["cancelled"] + summary["timed_out"]
        ),
        "cache_restores": summary["admitted"],
        "cache_closures": summary["admitted"],
        "cache_successful_commits": cache_operations,
        "cache_releases": cache_operations,
        "cache_live_allocations": 0,
        "model_successful_commits": summary["successful_commits"],
        "model_releases": summary["releases"],
        "model_final_active_reservations": (summary["final_active_reservations"]),
        "model_final_committed_receipts": (summary["final_committed_receipts"]),
        "zero_model_ownership": summary["zero_orphan_ownership"],
        "zero_cache_ownership": summary["zero_orphan_ownership"],
        "zero_orphan_ownership": summary["zero_orphan_ownership"],
    }
    if tuple(evidence_summary) != EVIDENCE_REPORT_SUMMARY_FIELDS:
        raise TypedWorkloadError("evidence summary field order changed")
    return evidence_summary


def build_report() -> Record:
    """Recompute the retained W4 conformance report from first principles."""

    plan = reference_plan()
    result = replay_plan(plan)
    plan_wire = encode_plan(plan)
    driver_summary = {
        name: deepcopy(result["summary"][name]) for name in DRIVER_REPORT_SUMMARY_FIELDS
    }
    evidence_summary = _reference_evidence_summary(plan, result)
    try:
        outcomes = [OUTCOME_NAMES[outcome["kind"]] for outcome in result["outcomes"]]
    except KeyError as error:
        raise TypedWorkloadError("unknown reference outcome") from error
    return {
        "schema": CONFORMANCE_SCHEMA,
        "plan_abi": f"{PLAN_ABI:016x}",
        "profile_abi": f"{PROFILE_ABI:016x}",
        "item_abi": f"{ITEM_ABI:016x}",
        "driver_result_abi": f"{RESULT_ABI:016x}",
        "driver_outcome_abi": f"{OUTCOME_ABI:016x}",
        "driver_trace_abi": f"{TRACE_ABI:016x}",
        "driver_summary_abi": f"{SUMMARY_ABI:016x}",
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
        "item_section_sha256": REFERENCE_ITEM_SECTION_SHA256,
        "evidence_summary_sha256": REFERENCE_EVIDENCE_SUMMARY_SHA256,
        "evidence_sha256": REFERENCE_EVIDENCE_SHA256,
        "outcomes": outcomes,
        "driver_summary": driver_summary,
        "evidence_summary": evidence_summary,
    }


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
        raise TypedWorkloadError("report is not JSON representable") from error


def validate_report(value: Any) -> Record:
    """Require exact equality with independent replay and retained evidence."""

    expected = build_report()
    if (
        not isinstance(value, dict)
        or value != expected
        or render_report(value) != render_report(expected)
    ):
        raise TypedWorkloadError("report contradicts typed-workload conformance replay")
    return deepcopy(expected)


def _load_json_exact(encoded: bytes, where: str) -> Record:
    if (
        type(encoded) is not bytes
        or not 0 < len(encoded) <= MAXIMUM_JSON_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise TypedWorkloadError(f"{where} is not one canonical line")

    def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
        value: Record = {}
        for key, item in pairs:
            if key in value:
                raise TypedWorkloadError(f"{where} contains duplicate fields")
            value[key] = item
        return value

    def invalid_number(_: str) -> None:
        raise TypedWorkloadError(f"{where} contains a non-integer number")

    try:
        decoded = json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=object_pairs,
            parse_constant=invalid_number,
            parse_float=invalid_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TypedWorkloadError(f"{where} is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise TypedWorkloadError(f"{where} is not a JSON object")
    if render_report(decoded).encode("ascii") != encoded:
        raise TypedWorkloadError(f"{where} is not canonical JSON")
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
        raise TypedWorkloadError("invalid typed-workload runner command")
    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = _load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise TypedWorkloadError("retained fixture is stale")
    completed = subprocess.run(
        runner_argv,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if completed.returncode != 0 or completed.stderr:
        raise TypedWorkloadError("typed-workload runner failed")
    runner_value = _load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise TypedWorkloadError("typed-workload runner contradicts Python oracle")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify retained W4 typed-workload conformance",
    )
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verify_runner(args.runner, args.fixture)
    except (OSError, subprocess.SubprocessError, TypedWorkloadError) as error:
        print(f"typed-workload-conformance: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
