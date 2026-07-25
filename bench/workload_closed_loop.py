"""Independent deterministic closed-loop workload oracle.

This module executes the W3 four-phase logical state machine directly. It does
not translate closed-loop work into a precompiled open-loop schedule, and it
does not measure wall-clock time, native concurrency, throughput, RSS, or
device behavior.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

from bench import workload_pressure as workload


Record = dict[str, Any]
U64_MAX = (1 << 64) - 1
ABSENT = U64_MAX
ZERO_DIGEST = bytes(32)

PLAN_ABI = 0x4757434C50000001
RESULT_ABI = 0x4757434C52000001
TRACE_ABI = 0x4757434C54000001
SUMMARY_ABI = 0x4757434C53000001
CANDIDATE_ABI = 0x4757434C43000001
OUTCOME_ABI = 0x4757434C4F000001

SCHEMA = "glacier.workload-closed-loop/v1"

MAXIMUM_CANDIDATES = workload.MAXIMUM_ITEMS
MAXIMUM_DRIVER_STEPS = workload.MAXIMUM_DRIVER_STEPS
MAXIMUM_SERVICE_QUANTA = workload.MAXIMUM_SERVICE_QUANTA
MAXIMUM_TRACE_RECORDS = 384
MAXIMUM_IN_FLIGHT = workload.MAXIMUM_ITEMS

PLAN_MAGIC = b"GWCLP1\x00\x00"
RESULT_MAGIC = b"GWCLR1\x00\x00"
PLAN_HEADER_BYTES = 320
CANDIDATE_RECORD_BYTES = 256
PLAN_FOOTER_BYTES = 32
RESULT_HEADER_BYTES = 256
OUTCOME_RECORD_BYTES = 328
TRACE_RECORD_BYTES = 200
SUMMARY_RECORD_BYTES = 424
RESULT_FOOTER_BYTES = 32
ALLOWED_FLAGS = 0

PHASE_ADMIT_DUE = 1
PHASE_APPLY_ACTIONS = 2
PHASE_SERVICE_RETIRE = 3
PHASE_SEAL_STEP = 4
PHASE_CLOSE = 5

EVENT_ADMISSION_ACCEPTED = 0
EVENT_ADMISSION_REJECTED = 1
EVENT_SERVICE = 2
EVENT_CANCEL = 3
EVENT_RETIRE = 4
EVENT_CLOSE = 5
EVENT_CREDIT_SEALED = 6
EVENT_CREDIT_EXHAUSTED = 7

TRIGGER_INITIAL = 0
TRIGGER_COMPLETED = 1
TRIGGER_REJECTED = 2
TRIGGER_CANCELLED = 3
TRIGGER_TIMED_OUT = 4

PLAN_DOMAIN = b"glacier-workload-closed-loop-plan-v1\x00"
PLAN_WIRE_DOMAIN = b"glacier-workload-closed-loop-plan-wire-v1\x00"
CANDIDATE_DOMAIN = b"glacier-workload-closed-loop-candidate-v1\x00"
RESULT_DOMAIN = b"glacier-workload-closed-loop-result-v1\x00"
RESULT_WIRE_DOMAIN = b"glacier-workload-closed-loop-result-wire-v1\x00"
OUTCOMES_DOMAIN = b"glacier-workload-closed-loop-outcome-section-v1\x00"
OUTCOME_DOMAIN = b"glacier-workload-closed-loop-outcome-v1\x00"
TRACE_DOMAIN = b"glacier-workload-closed-loop-trace-v1\x00"
TRACE_RECORD_DOMAIN = b"glacier-workload-closed-loop-trace-record-v1\x00"
SUMMARY_DOMAIN = b"glacier-workload-closed-loop-summary-v1\x00"

ACTION_NONE = workload.ACTION_NONE
ACTION_CANCEL = workload.ACTION_CANCEL
ACTION_TIMEOUT = workload.ACTION_TIMEOUT

OUTCOME_COMPLETED = workload.OUTCOME_COMPLETED
OUTCOME_REJECTED = workload.OUTCOME_REJECTED
OUTCOME_CANCELLED = workload.OUTCOME_CANCELLED
OUTCOME_TIMED_OUT = workload.OUTCOME_TIMED_OUT

REJECTION_NONE = workload.REJECTION_NONE
REJECTION_NO_SLOT = workload.REJECTION_NO_SLOT
REJECTION_DUPLICATE_TENANT = workload.REJECTION_DUPLICATE_TENANT
REJECTION_RESOURCE_LIMIT = workload.REJECTION_RESOURCE_LIMIT
REJECTION_PROJECTION_LIMIT = workload.REJECTION_PROJECTION_LIMIT
REJECTION_DEADLINE_INFEASIBLE = workload.REJECTION_DEADLINE_INFEASIBLE

MEDIA_IMAGE = workload.MEDIA_IMAGE
MEDIA_AUDIO = workload.MEDIA_AUDIO
MEDIA_VIDEO = workload.MEDIA_VIDEO

CANDIDATE_FIELDS = (
    "ordinal",
    "family",
    "operation",
    "media_kind",
    "weight",
    "work_quanta",
    "deadline_budget_quanta",
    "terminal_action_after_steps",
    "terminal_action",
    "fairness_member",
    "tenant_key",
    "request_key",
    "request_generation",
    "resource_owner_key",
)

TRACE_FIELDS = (
    "sequence",
    "driver_step",
    "phase",
    "event_kind",
    "candidate_ordinal",
    "predecessor_ordinal",
    "lineage_index",
    "lineage_generation",
    "scheduler_event_sequence",
    "rejection_reason",
    "terminal_action",
    "logical_tick_before",
    "logical_tick_after",
    "remaining_before",
    "remaining_after",
    "wait_quanta",
    "active_before",
    "active_after",
    "due_before",
    "due_after",
    "candidate_cursor_after",
)

OUTCOME_FIELDS = (
    "ordinal",
    "lineage_index",
    "lineage_generation",
    "predecessor_ordinal",
    "trigger_kind",
    "trigger_terminal_step",
    "submission_step",
    "scheduler_slot_index",
    "scheduler_slot_generation",
    "kind",
    "rejection_reason",
    "terminal_action",
    "admitted_step",
    "first_service_step",
    "terminal_step",
    "served_quanta",
    "maximum_wait_quanta",
)

SUMMARY_FIELDS = (
    "in_flight_target",
    "capacity",
    "candidate_budget",
    "attempted",
    "admitted",
    "rejected",
    "completed",
    "cancelled",
    "timed_out",
    "service_quanta",
    "driver_steps",
    "final_logical_tick",
    "maximum_active",
    "maximum_due_credits",
    "maximum_live_receipts",
    "replacement_attempts",
    "replacements_after_completed",
    "replacements_after_rejected",
    "replacements_after_cancelled",
    "replacements_after_timed_out",
    "credits_sealed",
    "credits_exhausted",
    "lineage_count",
    "maximum_lineage_generation",
    "peak_host_bytes",
    "maximum_wait_quanta",
    "maximum_service_gap",
    "fairness_cross_product_error",
    "final_active",
    "final_due_credits",
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


class WorkloadClosedLoopError(ValueError):
    """The W3 plan, result, report, or deterministic replay is invalid."""


def _u64(value: int) -> bytes:
    if isinstance(value, bool) or not isinstance(value, int):
        raise WorkloadClosedLoopError("expected u64")
    if not 0 <= value <= U64_MAX:
        raise WorkloadClosedLoopError("u64 out of range")
    return struct.pack("<Q", value)


def _read_u64(value: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", value, offset)[0]


def _write_u64(output: bytearray, offset: int, value: int) -> None:
    output[offset : offset + 8] = _u64(value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise WorkloadClosedLoopError("invalid digest")
    return value


def _sha(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _hex_u64(value: Any) -> int:
    if (
        not isinstance(value, str)
        or len(value) != 16
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise WorkloadClosedLoopError("invalid hexadecimal u64")
    return int(value, 16)


def _hex_digest(value: Any) -> bytes:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise WorkloadClosedLoopError("invalid hexadecimal digest")
    return bytes.fromhex(value)


def _candidate(
    ordinal: int,
    media_kind: int,
    *,
    weight: int = 1,
    work_quanta: int = 1,
    deadline_budget_quanta: int = 0,
    terminal_action_after_steps: int = ABSENT,
    terminal_action: int = ACTION_NONE,
    fairness_member: bool = True,
) -> Record:
    try:
        profile = workload._profile(media_kind)
    except workload.WorkloadPressureError as error:
        raise WorkloadClosedLoopError("unsupported candidate profile") from error
    identity = ordinal + 1
    return {
        "ordinal": ordinal,
        "family": profile["family"],
        "operation": profile["operation"],
        "media_kind": media_kind,
        "profile_sha256": profile["profile_sha256"],
        "weight": weight,
        "work_quanta": work_quanta,
        "deadline_budget_quanta": deadline_budget_quanta,
        "terminal_action_after_steps": terminal_action_after_steps,
        "terminal_action": terminal_action,
        "fairness_member": fairness_member,
        "tenant_key": 0x4100000000000000 | identity,
        "request_key": 0x4200000000000000 | identity,
        "request_generation": 1,
        "resource_owner_key": 0x4300000000000000 | identity,
        "claim": deepcopy(profile["claim"]),
    }


def reference_plan() -> Record:
    """Return the bounded retained target-three W3 plan."""

    limits = {name: U64_MAX for name in workload.LIMIT_FIELDS}
    limits["host_bytes"] = 4148
    limits["queue_slots"] = 4
    return {
        "seed": 0x4757434C20260001,
        "max_driver_steps": 64,
        "max_service_quanta": 64,
        "in_flight_target": 3,
        "fairness_start_tick": 0,
        "fairness_end_tick": 16,
        "bank_epoch": 0x4757434C42410001,
        "scheduler_epoch": 0x4757434C51530001,
        "max_weight": 4,
        "max_projection_quanta": 8,
        "max_projection_operations": 4096,
        "capacity": 4,
        "limits": limits,
        "challenge": bytes(
            (
                0x57,
                0x33,
                0x2D,
                0x63,
                0x6C,
                0x6F,
                0x73,
                0x65,
                0x64,
                0x2D,
                0x6C,
                0x6F,
                0x6F,
                0x70,
                0x2D,
                0x72,
                0x65,
                0x66,
                0x65,
                0x72,
                0x65,
                0x6E,
                0x63,
                0x65,
                0x2D,
                0x76,
                0x31,
                0x00,
                0x00,
                0x00,
                0x00,
                0x01,
            )
        ),
        "candidates": [
            _candidate(
                0,
                MEDIA_IMAGE,
                weight=1,
                work_quanta=4,
                terminal_action_after_steps=1,
                terminal_action=ACTION_CANCEL,
                fairness_member=True,
            ),
            _candidate(
                1,
                MEDIA_AUDIO,
                weight=2,
                work_quanta=4,
                terminal_action_after_steps=1,
                terminal_action=ACTION_TIMEOUT,
                fairness_member=True,
            ),
            _candidate(
                2,
                MEDIA_VIDEO,
                weight=4,
                work_quanta=1,
                fairness_member=True,
            ),
            _candidate(
                3,
                MEDIA_AUDIO,
                weight=1,
                work_quanta=3,
                deadline_budget_quanta=1,
            ),
            _candidate(
                4,
                MEDIA_IMAGE,
                weight=2,
                work_quanta=3,
                terminal_action_after_steps=0,
                terminal_action=ACTION_CANCEL,
            ),
            _candidate(5, MEDIA_VIDEO, weight=4, work_quanta=1),
            _candidate(6, MEDIA_IMAGE, weight=1, work_quanta=1),
            _candidate(7, MEDIA_IMAGE, weight=2, work_quanta=2),
            _candidate(8, MEDIA_IMAGE, weight=4, work_quanta=2),
            _candidate(
                9,
                MEDIA_AUDIO,
                weight=1,
                work_quanta=9,
                deadline_budget_quanta=8,
            ),
        ],
    }


def _validate_candidate(candidate: Record, max_weight: int) -> Record:
    required = {*CANDIDATE_FIELDS, "profile_sha256", "claim"}
    if not isinstance(candidate, dict) or set(candidate) != required:
        raise WorkloadClosedLoopError("invalid candidate fields")
    for name in CANDIDATE_FIELDS:
        if name == "fairness_member":
            continue
        _u64(candidate[name])
    if not isinstance(candidate["fairness_member"], bool):
        raise WorkloadClosedLoopError("invalid fairness marker")
    if (
        not 1 <= candidate["weight"] <= max_weight
        or candidate["work_quanta"] == 0
        or candidate["tenant_key"] == 0
        or candidate["request_key"] == 0
        or candidate["request_generation"] == 0
        or candidate["resource_owner_key"] == 0
    ):
        raise WorkloadClosedLoopError("invalid candidate envelope")
    if (candidate["terminal_action"] == ACTION_NONE) != (
        candidate["terminal_action_after_steps"] == ABSENT
    ):
        raise WorkloadClosedLoopError("inconsistent relative terminal action")
    if candidate["terminal_action"] not in (
        ACTION_NONE,
        ACTION_CANCEL,
        ACTION_TIMEOUT,
    ):
        raise WorkloadClosedLoopError("invalid terminal action")
    try:
        profile = workload._profile(candidate["media_kind"])
        claim = workload._validate_claim(candidate["claim"])
    except workload.WorkloadPressureError as error:
        raise WorkloadClosedLoopError("invalid candidate profile") from error
    if (
        candidate["family"] != profile["family"]
        or candidate["operation"] != profile["operation"]
        or candidate["profile_sha256"] != profile["profile_sha256"]
        or claim != profile["claim"]
    ):
        raise WorkloadClosedLoopError("foreign candidate profile")
    return {**candidate, "claim": claim}


def validate_plan(plan: Record) -> Record:
    required = {
        "seed",
        "max_driver_steps",
        "max_service_quanta",
        "in_flight_target",
        "fairness_start_tick",
        "fairness_end_tick",
        "bank_epoch",
        "scheduler_epoch",
        "max_weight",
        "max_projection_quanta",
        "max_projection_operations",
        "capacity",
        "limits",
        "challenge",
        "candidates",
    }
    if not isinstance(plan, dict) or set(plan) != required:
        raise WorkloadClosedLoopError("invalid plan fields")
    for name in required - {"limits", "challenge", "candidates"}:
        _u64(plan[name])
    if (
        plan["seed"] == 0
        or not 0 < plan["max_driver_steps"] <= MAXIMUM_DRIVER_STEPS
        or not 0 < plan["max_service_quanta"] <= MAXIMUM_SERVICE_QUANTA
        or plan["bank_epoch"] == 0
        or plan["scheduler_epoch"] == 0
        or plan["fairness_end_tick"] <= plan["fairness_start_tick"]
        or not 0 < plan["max_weight"] <= workload.MAXIMUM_WEIGHT
        or plan["max_projection_quanta"] == 0
        or plan["max_projection_operations"] == 0
        or not 0 < plan["capacity"] <= MAXIMUM_IN_FLIGHT
        or not 0 < plan["in_flight_target"] <= plan["capacity"]
    ):
        raise WorkloadClosedLoopError("invalid plan envelope")
    challenge = _digest(plan["challenge"])
    limits_value = plan["limits"]
    if not isinstance(limits_value, dict) or set(limits_value) != set(
        workload.LIMIT_FIELDS
    ):
        raise WorkloadClosedLoopError("invalid resource limits")
    limits = {name: limits_value[name] for name in workload.LIMIT_FIELDS}
    for amount in limits.values():
        _u64(amount)
    if limits["queue_slots"] < plan["capacity"]:
        raise WorkloadClosedLoopError("queue limit below physical capacity")
    candidates_value = plan["candidates"]
    if (
        not isinstance(candidates_value, list)
        or not plan["in_flight_target"]
        <= len(candidates_value)
        <= MAXIMUM_CANDIDATES
    ):
        raise WorkloadClosedLoopError("invalid candidate budget")
    candidates: list[Record] = []
    seen_tenants: set[int] = set()
    seen_requests: set[int] = set()
    seen_owners: set[int] = set()
    total_quanta = 0
    fairness_members = 0
    for index, value in enumerate(candidates_value):
        candidate = _validate_candidate(value, plan["max_weight"])
        if (
            candidate["ordinal"] != index
            or candidate["tenant_key"] in seen_tenants
            or candidate["request_key"] in seen_requests
            or candidate["resource_owner_key"] in seen_owners
            or (
                candidate["terminal_action"] != ACTION_NONE
                and candidate["terminal_action_after_steps"]
                >= plan["max_driver_steps"]
            )
        ):
            raise WorkloadClosedLoopError("noncanonical candidate order")
        seen_tenants.add(candidate["tenant_key"])
        seen_requests.add(candidate["request_key"])
        seen_owners.add(candidate["resource_owner_key"])
        total_quanta += candidate["work_quanta"]
        if total_quanta > plan["max_service_quanta"]:
            raise WorkloadClosedLoopError("declared service bound exceeded")
        if candidate["deadline_budget_quanta"] > plan["max_projection_quanta"]:
            raise WorkloadClosedLoopError("deadline budget exceeds projection")
        fairness_members += int(candidate["fairness_member"])
        candidates.append(candidate)
    worst_trace = (
        len(candidates)
        + plan["max_service_quanta"]
        + len(candidates)
        + len(candidates)
        + len(candidates)
        + 1
    )
    if fairness_members < 2 or worst_trace > MAXIMUM_TRACE_RECORDS:
        raise WorkloadClosedLoopError("trace envelope exceeded")
    return {
        **plan,
        "limits": limits,
        "challenge": challenge,
        "candidates": candidates,
    }


def candidate_sha256(candidate_value: Record, max_weight: int) -> bytes:
    candidate = _validate_candidate(candidate_value, max_weight)
    return _sha(
        CANDIDATE_DOMAIN,
        _u64(CANDIDATE_ABI),
        _u64(candidate["ordinal"]),
        _u64(candidate["family"]),
        _u64(candidate["operation"]),
        _u64(candidate["media_kind"]),
        _digest(candidate["profile_sha256"]),
        _u64(candidate["weight"]),
        _u64(candidate["work_quanta"]),
        _u64(candidate["deadline_budget_quanta"]),
        _u64(candidate["terminal_action_after_steps"]),
        _u64(candidate["terminal_action"]),
        _u64(int(candidate["fairness_member"])),
        _u64(candidate["tenant_key"]),
        _u64(candidate["request_key"]),
        _u64(candidate["request_generation"]),
        _u64(candidate["resource_owner_key"]),
        *(
            _u64(candidate["claim"][name])
            for name in workload.CLAIM_FIELDS
        ),
    )


def plan_sha256(plan_value: Record) -> bytes:
    plan = validate_plan(plan_value)
    parts = [
        _u64(PLAN_ABI),
        _u64(plan["seed"]),
        _u64(plan["in_flight_target"]),
        _u64(plan["capacity"]),
        _u64(plan["max_driver_steps"]),
        _u64(plan["max_service_quanta"]),
        _u64(plan["fairness_start_tick"]),
        _u64(plan["fairness_end_tick"]),
        _u64(plan["bank_epoch"]),
        _u64(plan["scheduler_epoch"]),
        _u64(plan["max_weight"]),
        _u64(plan["max_projection_quanta"]),
        _u64(plan["max_projection_operations"]),
        *(_u64(plan["limits"][name]) for name in workload.LIMIT_FIELDS),
        _digest(plan["challenge"]),
        _u64(len(plan["candidates"])),
    ]
    for candidate in plan["candidates"]:
        parts.append(candidate_sha256(candidate, plan["max_weight"]))
    return _sha(PLAN_DOMAIN, *parts)


def trace_record_sha256(record: Record) -> bytes:
    if not isinstance(record, dict) or set(record) != set(TRACE_FIELDS):
        raise WorkloadClosedLoopError("invalid trace record fields")
    return _sha(
        TRACE_RECORD_DOMAIN,
        _u64(TRACE_ABI),
        *(_u64(record[name]) for name in TRACE_FIELDS),
    )


def _append_trace(
    trace: list[Record],
    *,
    driver_step: int,
    phase: int,
    kind: int,
    candidate_ordinal: int = ABSENT,
    lineage_index: int = ABSENT,
    lineage_generation: int = 0,
    predecessor_ordinal: int = ABSENT,
    scheduler_event_sequence: int = ABSENT,
    rejection_reason: int = REJECTION_NONE,
    terminal_action: int = ACTION_NONE,
    logical_tick_before: int,
    logical_tick_after: int,
    active_before: int,
    active_after: int,
    due_before: int,
    due_after: int,
    candidate_cursor_after: int,
    remaining_before: int = 0,
    remaining_after: int = 0,
    wait_quanta: int = 0,
) -> bytes:
    if len(trace) >= MAXIMUM_TRACE_RECORDS:
        raise WorkloadClosedLoopError("trace storage exhausted")
    record = {
        "sequence": len(trace),
        "driver_step": driver_step,
        "phase": phase,
        "event_kind": kind,
        "candidate_ordinal": candidate_ordinal,
        "predecessor_ordinal": predecessor_ordinal,
        "lineage_index": lineage_index,
        "lineage_generation": lineage_generation,
        "scheduler_event_sequence": scheduler_event_sequence,
        "rejection_reason": rejection_reason,
        "terminal_action": terminal_action,
        "logical_tick_before": logical_tick_before,
        "logical_tick_after": logical_tick_after,
        "active_before": active_before,
        "active_after": active_after,
        "due_before": due_before,
        "due_after": due_after,
        "candidate_cursor_after": candidate_cursor_after,
        "remaining_before": remaining_before,
        "remaining_after": remaining_after,
        "wait_quanta": wait_quanta,
    }
    root = trace_record_sha256(record)
    trace.append({**record, "record_sha256": root})
    return root


def trace_sha256(trace: list[Record]) -> bytes:
    if not isinstance(trace, list) or not 0 < len(trace) <= MAXIMUM_TRACE_RECORDS:
        raise WorkloadClosedLoopError("invalid trace count")
    parts = [_u64(TRACE_ABI), _u64(len(trace))]
    for sequence, value in enumerate(trace):
        if not isinstance(value, dict) or set(value) != {
            *TRACE_FIELDS,
            "record_sha256",
        }:
            raise WorkloadClosedLoopError("invalid trace record")
        record = {name: value[name] for name in TRACE_FIELDS}
        if (
            value["sequence"] != sequence
            or trace_record_sha256(record) != value["record_sha256"]
        ):
            raise WorkloadClosedLoopError("trace record root mismatch")
        parts.append(_digest(value["record_sha256"]))
    return _sha(TRACE_DOMAIN, *parts)


def outcome_record_sha256(outcome: Record) -> bytes:
    if not isinstance(outcome, dict) or set(outcome) != {
        *OUTCOME_FIELDS,
        "candidate_sha256",
        "trigger_trace_sha256",
        "trigger_credit_sha256",
        "admission_trace_sha256",
        "terminal_trace_sha256",
    }:
        raise WorkloadClosedLoopError("invalid outcome fields")
    return _sha(
        OUTCOME_DOMAIN,
        _u64(OUTCOME_ABI),
        _u64(outcome["ordinal"]),
        _digest(outcome["candidate_sha256"]),
        _u64(outcome["lineage_index"]),
        _u64(outcome["lineage_generation"]),
        _u64(outcome["predecessor_ordinal"]),
        _u64(outcome["trigger_kind"]),
        _u64(outcome["trigger_terminal_step"]),
        _digest(outcome["trigger_trace_sha256"], allow_zero=True),
        _digest(outcome["trigger_credit_sha256"], allow_zero=True),
        *(
            _u64(outcome[name])
            for name in OUTCOME_FIELDS[6:]
        ),
        _digest(outcome["admission_trace_sha256"]),
        _digest(outcome["terminal_trace_sha256"]),
    )


def outcomes_sha256(outcomes: list[Record]) -> bytes:
    if (
        not isinstance(outcomes, list)
        or not 0 < len(outcomes) <= MAXIMUM_CANDIDATES
    ):
        raise WorkloadClosedLoopError("invalid outcome count")
    parts = [_u64(OUTCOME_ABI), _u64(len(outcomes))]
    for ordinal, value in enumerate(outcomes):
        if not isinstance(value, dict) or set(value) != {
            *OUTCOME_FIELDS,
            "candidate_sha256",
            "trigger_trace_sha256",
            "trigger_credit_sha256",
            "admission_trace_sha256",
            "terminal_trace_sha256",
            "record_sha256",
        }:
            raise WorkloadClosedLoopError("invalid outcome record")
        outcome = {name: value[name] for name in OUTCOME_FIELDS}
        for name in (
            "candidate_sha256",
            "trigger_trace_sha256",
            "trigger_credit_sha256",
            "admission_trace_sha256",
            "terminal_trace_sha256",
        ):
            outcome[name] = value[name]
        if (
            value["ordinal"] != ordinal
            or outcome_record_sha256(outcome) != value["record_sha256"]
        ):
            raise WorkloadClosedLoopError("outcome record root mismatch")
        parts.append(_digest(value["record_sha256"]))
    return _sha(OUTCOMES_DOMAIN, *parts)


def summary_sha256(summary: Record) -> bytes:
    if not isinstance(summary, dict) or set(summary) != {
        *SUMMARY_FIELDS,
        "peak",
    }:
        raise WorkloadClosedLoopError("invalid summary fields")
    peak = summary["peak"]
    if not isinstance(peak, dict) or set(peak) != set(workload.CLAIM_FIELDS):
        raise WorkloadClosedLoopError("invalid summary peak")
    peak_index = SUMMARY_FIELDS.index("peak_host_bytes") + 1
    return _sha(
        SUMMARY_DOMAIN,
        _u64(SUMMARY_ABI),
        *(
            _u64(int(summary[name]))
            for name in SUMMARY_FIELDS[:peak_index]
        ),
        *(_u64(peak[name]) for name in workload.CLAIM_FIELDS),
        *(
            _u64(int(summary[name]))
            for name in SUMMARY_FIELDS[peak_index:]
        ),
    )


def replay_plan(plan_value: Record) -> Record:
    """Execute the direct four-phase W3 logical state machine."""

    plan = validate_plan(plan_value)
    candidates = plan["candidates"]
    slots: list[Record | None] = [None] * plan["capacity"]
    runtime: list[Record] = [
        {
            "state": "pending",
            "lineage_index": ABSENT,
            "lineage_generation": 0,
            "predecessor_ordinal": ABSENT,
            "trigger_kind": TRIGGER_INITIAL,
            "trigger_terminal_step": ABSENT,
            "trigger_trace_sha256": ZERO_DIGEST,
            "trigger_credit_sha256": ZERO_DIGEST,
            "submitted_step": ABSENT,
            "scheduler_slot_index": ABSENT,
            "scheduler_slot_generation": 0,
            "admitted_step": ABSENT,
            "first_service_step": ABSENT,
            "terminal_step": ABSENT,
            "served_quanta": 0,
            "fairness_quanta": 0,
            "maximum_wait_quanta": 0,
            "outcome": 0,
            "rejection_reason": REJECTION_NONE,
            "terminal_action": ACTION_NONE,
            "admission_trace_sha256": ZERO_DIGEST,
            "terminal_trace_sha256": ZERO_DIGEST,
        }
        for _ in candidates
    ]
    used = workload._empty_claim()
    peak = workload._empty_claim()
    peak_host_bytes = 0
    maximum_active = 0
    maximum_due = 0
    successful_commits = 0
    releases = 0
    cursor = 0
    level = 1
    logical_tick = 0
    next_event_sequence = 0
    next_slot_generation = 1
    service_quanta = 0
    trace: list[Record] = []
    next_candidate = 0
    due: list[Record] = []
    credits_exhausted = 0
    driver_steps = 0
    closed = False

    def active_count() -> int:
        return sum(slot is not None and slot["active"] for slot in slots)

    def update_peak() -> None:
        nonlocal peak, peak_host_bytes, maximum_active
        peak = {
            name: max(peak[name], used[name])
            for name in workload.CLAIM_FIELDS
        }
        peak_host_bytes = max(
            peak_host_bytes,
            workload._host_bytes(used),
        )
        maximum_active = max(maximum_active, active_count())
        if active_count() > plan["in_flight_target"]:
            raise WorkloadClosedLoopError("logical target exceeded")

    for step in range(plan["max_driver_steps"]):
        terminal_events: list[Record] = []

        if step == 0:
            due_now = [
                {
                    "initial": True,
                    "lineage_index": index,
                    "lineage_generation": 1,
                    "predecessor_ordinal": ABSENT,
                    "trigger_kind": TRIGGER_INITIAL,
                    "trigger_terminal_step": ABSENT,
                    "trigger_trace_sha256": ZERO_DIGEST,
                    "trigger_credit_sha256": ZERO_DIGEST,
                }
                for index in range(plan["in_flight_target"])
            ]
        else:
            due_now = due
            due = []

        due_total = len(due_now)
        for due_index, credit in enumerate(due_now):
            is_initial = credit["initial"]
            due_before = 0 if is_initial else due_total - due_index
            due_after = 0 if is_initial else due_before - 1
            if next_candidate >= len(candidates):
                if is_initial:
                    raise WorkloadClosedLoopError(
                        "initial prefix exceeds candidate budget"
                    )
                credits_exhausted += 1
                _append_trace(
                    trace,
                    driver_step=step,
                    phase=PHASE_ADMIT_DUE,
                    kind=EVENT_CREDIT_EXHAUSTED,
                    candidate_ordinal=credit["predecessor_ordinal"],
                    lineage_index=credit["lineage_index"],
                    lineage_generation=credit["lineage_generation"],
                    predecessor_ordinal=credit["predecessor_ordinal"],
                    scheduler_event_sequence=ABSENT,
                    logical_tick_before=logical_tick,
                    logical_tick_after=logical_tick,
                    active_before=active_count(),
                    active_after=active_count(),
                    due_before=due_before,
                    due_after=due_after,
                    candidate_cursor_after=next_candidate,
                )
                continue

            index = next_candidate
            next_candidate += 1
            candidate = candidates[index]
            state = runtime[index]
            if state["state"] != "pending":
                raise WorkloadClosedLoopError("candidate attempted twice")
            state.update(
                {
                    "state": "submitted",
                    "lineage_index": credit["lineage_index"],
                    "lineage_generation": (
                        credit["lineage_generation"]
                        if is_initial
                        else credit["lineage_generation"] + 1
                    ),
                    "predecessor_ordinal": credit["predecessor_ordinal"],
                    "trigger_kind": credit["trigger_kind"],
                    "trigger_terminal_step": credit[
                        "trigger_terminal_step"
                    ],
                    "trigger_trace_sha256": credit[
                        "trigger_trace_sha256"
                    ],
                    "trigger_credit_sha256": credit[
                        "trigger_credit_sha256"
                    ],
                    "submitted_step": step,
                }
            )

            active_before = active_count()
            free = next(
                (
                    slot_index
                    for slot_index, slot in enumerate(slots)
                    if slot is None
                ),
                None,
            )
            if free is None:
                raise WorkloadClosedLoopError("no-slot invariant violated")
            if any(
                slot is not None
                and slot["tenant_key"] == candidate["tenant_key"]
                for slot in slots
            ):
                raise WorkloadClosedLoopError(
                    "duplicate-tenant invariant violated"
                )
            deadline_tick = 0
            if candidate["deadline_budget_quanta"]:
                deadline_tick = (
                    logical_tick + candidate["deadline_budget_quanta"]
                )
                if deadline_tick > U64_MAX:
                    raise WorkloadClosedLoopError("relative deadline overflow")

            try:
                next_used = workload._claim_add(used, candidate["claim"])
            except workload.WorkloadPressureError as error:
                raise WorkloadClosedLoopError(
                    "resource accounting overflow"
                ) from error
            rejection = REJECTION_NONE
            if not workload._fits(plan["limits"], next_used):
                rejection = REJECTION_RESOURCE_LIMIT
            else:
                projected = {
                    **candidate,
                    "deadline_tick": deadline_tick,
                }
                try:
                    rejection = workload._projection_rejection(
                        slots,
                        free,
                        projected,
                        logical_tick,
                        cursor,
                        level,
                        plan["max_weight"],
                        plan["max_projection_quanta"],
                        plan["max_projection_operations"],
                    )
                except workload.WorkloadPressureError as error:
                    raise WorkloadClosedLoopError(
                        "projection replay failed"
                    ) from error

            if rejection != REJECTION_NONE:
                if rejection in (REJECTION_NO_SLOT, REJECTION_DUPLICATE_TENANT):
                    raise WorkloadClosedLoopError(
                        "closed-loop admission invariant violated"
                    )
                state.update(
                    {
                        "state": "terminal",
                        "terminal_step": step,
                        "outcome": OUTCOME_REJECTED,
                        "rejection_reason": rejection,
                    }
                )
                scheduler_event_sequence = next_event_sequence
                next_event_sequence += 1
                root = _append_trace(
                    trace,
                    driver_step=step,
                    phase=PHASE_ADMIT_DUE,
                    kind=EVENT_ADMISSION_REJECTED,
                    candidate_ordinal=index,
                    lineage_index=state["lineage_index"],
                    lineage_generation=state["lineage_generation"],
                    predecessor_ordinal=state["predecessor_ordinal"],
                    scheduler_event_sequence=scheduler_event_sequence,
                    rejection_reason=rejection,
                    logical_tick_before=logical_tick,
                    logical_tick_after=logical_tick,
                    active_before=active_before,
                    active_after=active_before,
                    due_before=due_before,
                    due_after=due_after,
                    candidate_cursor_after=next_candidate,
                )
                state["admission_trace_sha256"] = root
                state["terminal_trace_sha256"] = root
                terminal_events.append(
                    {
                        "candidate_index": index,
                        "terminal_trace_sha256": root,
                    }
                )
                continue

            assert free is not None
            slots[free] = {
                "candidate_index": index,
                "tenant_key": candidate["tenant_key"],
                "weight": candidate["weight"],
                "remaining": candidate["work_quanta"],
                "deadline_tick": deadline_tick,
                "last_service_tick": logical_tick,
                "active": True,
                "claim": candidate["claim"],
                "slot_generation": next_slot_generation,
            }
            used = next_used
            successful_commits += 1
            state.update(
                {
                    "state": "active",
                    "slot_index": free,
                    "scheduler_slot_index": free,
                    "scheduler_slot_generation": next_slot_generation,
                    "admitted_step": step,
                }
            )
            next_slot_generation += 1
            scheduler_event_sequence = next_event_sequence
            next_event_sequence += 1
            update_peak()
            state["admission_trace_sha256"] = _append_trace(
                trace,
                driver_step=step,
                phase=PHASE_ADMIT_DUE,
                kind=EVENT_ADMISSION_ACCEPTED,
                candidate_ordinal=index,
                lineage_index=state["lineage_index"],
                lineage_generation=state["lineage_generation"],
                predecessor_ordinal=state["predecessor_ordinal"],
                scheduler_event_sequence=scheduler_event_sequence,
                logical_tick_before=logical_tick,
                logical_tick_after=logical_tick,
                active_before=active_before,
                active_after=active_count(),
                due_before=due_before,
                due_after=due_after,
                candidate_cursor_after=next_candidate,
                remaining_after=candidate["work_quanta"],
            )

        for index, (candidate, state) in enumerate(
            zip(candidates, runtime)
        ):
            if (
                state["state"] != "active"
                or candidate["terminal_action"] == ACTION_NONE
                or state["submitted_step"]
                + candidate["terminal_action_after_steps"]
                != step
            ):
                continue
            slot_index = state["slot_index"]
            slot = slots[slot_index]
            if slot is None:
                raise WorkloadClosedLoopError("terminal action lost slot")
            active_before = active_count()
            try:
                used = workload._claim_subtract(used, slot["claim"])
            except workload.WorkloadPressureError as error:
                raise WorkloadClosedLoopError(
                    "resource accounting underflow"
                ) from error
            slots[slot_index] = None
            releases += 1
            outcome = (
                OUTCOME_CANCELLED
                if candidate["terminal_action"] == ACTION_CANCEL
                else OUTCOME_TIMED_OUT
            )
            event_kind = EVENT_CANCEL
            state.update(
                {
                    "state": "terminal",
                    "terminal_step": step,
                    "outcome": outcome,
                    "terminal_action": candidate["terminal_action"],
                }
            )
            scheduler_event_sequence = next_event_sequence
            next_event_sequence += 1
            root = _append_trace(
                trace,
                driver_step=step,
                phase=PHASE_APPLY_ACTIONS,
                kind=event_kind,
                candidate_ordinal=index,
                lineage_index=state["lineage_index"],
                lineage_generation=state["lineage_generation"],
                predecessor_ordinal=state["predecessor_ordinal"],
                scheduler_event_sequence=scheduler_event_sequence,
                terminal_action=candidate["terminal_action"],
                logical_tick_before=logical_tick,
                logical_tick_after=logical_tick,
                active_before=active_before,
                active_after=active_count(),
                due_before=0,
                due_after=0,
                candidate_cursor_after=next_candidate,
                remaining_before=slot["remaining"],
            )
            state["terminal_trace_sha256"] = root
            terminal_events.append(
                {
                    "candidate_index": index,
                    "terminal_trace_sha256": root,
                }
            )
            update_peak()

        if active_count():
            try:
                selected, cursor, level = workload._select_iwrr(
                    slots,
                    cursor,
                    level,
                    plan["max_weight"],
                )
            except workload.WorkloadPressureError as error:
                raise WorkloadClosedLoopError(
                    "weighted scheduler replay failed"
                ) from error
            slot = slots[selected]
            assert slot is not None
            index = slot["candidate_index"]
            candidate = candidates[index]
            state = runtime[index]
            before = slot["remaining"]
            after_tick = logical_tick + 1
            wait = after_tick - slot["last_service_tick"]
            if service_quanta >= plan["max_service_quanta"]:
                raise WorkloadClosedLoopError("service quantum limit exceeded")
            slot["remaining"] -= 1
            slot["last_service_tick"] = after_tick
            logical_tick = after_tick
            service_quanta += 1
            if state["first_service_step"] == ABSENT:
                state["first_service_step"] = step
            state["served_quanta"] += 1
            state["maximum_wait_quanta"] = max(
                state["maximum_wait_quanta"],
                wait,
            )
            if (
                candidate["fairness_member"]
                and plan["fairness_start_tick"]
                < logical_tick
                <= plan["fairness_end_tick"]
            ):
                state["fairness_quanta"] += 1
            scheduler_event_sequence = next_event_sequence
            next_event_sequence += 1
            _append_trace(
                trace,
                driver_step=step,
                phase=PHASE_SERVICE_RETIRE,
                kind=EVENT_SERVICE,
                candidate_ordinal=index,
                lineage_index=state["lineage_index"],
                lineage_generation=state["lineage_generation"],
                predecessor_ordinal=state["predecessor_ordinal"],
                scheduler_event_sequence=scheduler_event_sequence,
                logical_tick_before=logical_tick - 1,
                logical_tick_after=logical_tick,
                active_before=active_count(),
                active_after=active_count(),
                due_before=0,
                due_after=0,
                candidate_cursor_after=next_candidate,
                remaining_before=before,
                remaining_after=slot["remaining"],
                wait_quanta=wait,
            )
            if slot["remaining"] == 0:
                active_before = active_count()
                try:
                    used = workload._claim_subtract(
                        used,
                        slot["claim"],
                    )
                except workload.WorkloadPressureError as error:
                    raise WorkloadClosedLoopError(
                        "resource accounting underflow"
                    ) from error
                slots[selected] = None
                releases += 1
                state.update(
                    {
                        "state": "terminal",
                        "terminal_step": step,
                        "outcome": OUTCOME_COMPLETED,
                    }
                )
                scheduler_event_sequence = next_event_sequence
                next_event_sequence += 1
                root = _append_trace(
                    trace,
                    driver_step=step,
                    phase=PHASE_SERVICE_RETIRE,
                    kind=EVENT_RETIRE,
                    candidate_ordinal=index,
                    lineage_index=state["lineage_index"],
                    lineage_generation=state["lineage_generation"],
                    predecessor_ordinal=state["predecessor_ordinal"],
                    scheduler_event_sequence=scheduler_event_sequence,
                    logical_tick_before=logical_tick,
                    logical_tick_after=logical_tick,
                    active_before=active_before,
                    active_after=active_count(),
                    due_before=0,
                    due_after=0,
                    candidate_cursor_after=next_candidate,
                )
                state["terminal_trace_sha256"] = root
                terminal_events.append(
                    {
                        "candidate_index": index,
                        "terminal_trace_sha256": root,
                    }
                )
                update_peak()

        next_due: list[Record] = []
        for terminal in terminal_events:
            index = terminal["candidate_index"]
            state = runtime[index]
            outcome = state["outcome"]
            trigger_kind = {
                OUTCOME_COMPLETED: TRIGGER_COMPLETED,
                OUTCOME_REJECTED: TRIGGER_REJECTED,
                OUTCOME_CANCELLED: TRIGGER_CANCELLED,
                OUTCOME_TIMED_OUT: TRIGGER_TIMED_OUT,
            }[outcome]
            credit = {
                "initial": False,
                "lineage_index": state["lineage_index"],
                "lineage_generation": state["lineage_generation"],
                "predecessor_ordinal": index,
                "trigger_kind": trigger_kind,
                "trigger_terminal_step": step,
                "trigger_trace_sha256": terminal[
                    "terminal_trace_sha256"
                ],
                "trigger_credit_sha256": ZERO_DIGEST,
            }
            if credit["lineage_generation"] == U64_MAX:
                raise WorkloadClosedLoopError("lineage generation overflow")
            due_before = len(next_due)
            credit_root = _append_trace(
                trace,
                driver_step=step,
                phase=PHASE_SEAL_STEP,
                kind=EVENT_CREDIT_SEALED,
                candidate_ordinal=index,
                lineage_index=state["lineage_index"],
                lineage_generation=state["lineage_generation"],
                predecessor_ordinal=index,
                scheduler_event_sequence=ABSENT,
                logical_tick_before=logical_tick,
                logical_tick_after=logical_tick,
                active_before=active_count(),
                active_after=active_count(),
                due_before=due_before,
                due_after=due_before + 1,
                candidate_cursor_after=next_candidate,
            )
            credit["trigger_credit_sha256"] = credit_root
            next_due.append(credit)
        maximum_due = max(maximum_due, len(next_due))
        due = next_due
        update_peak()

        if (
            next_candidate == len(candidates)
            and active_count() == 0
            and not due
        ):
            driver_steps = step + 1
            closed = True
            break
        if active_count() == 0 and not due and next_candidate < len(candidates):
            raise WorkloadClosedLoopError("closed-loop source stalled")

    if not closed:
        raise WorkloadClosedLoopError("driver step limit exceeded")

    scheduler_event_sequence = next_event_sequence
    next_event_sequence += 1
    _append_trace(
        trace,
        driver_step=driver_steps,
        phase=PHASE_CLOSE,
        kind=EVENT_CLOSE,
        scheduler_event_sequence=scheduler_event_sequence,
        logical_tick_before=logical_tick,
        logical_tick_after=logical_tick,
        active_before=0,
        active_after=0,
        due_before=0,
        due_after=0,
        candidate_cursor_after=next_candidate,
    )

    outcomes: list[Record] = []
    for candidate, state in zip(candidates, runtime):
        if (
            state["state"] != "terminal"
            or state["outcome"] == 0
            or state["admission_trace_sha256"] == ZERO_DIGEST
            or state["terminal_trace_sha256"] == ZERO_DIGEST
        ):
            raise WorkloadClosedLoopError("incomplete candidate outcome")
        outcome = {
            "ordinal": candidate["ordinal"],
            "candidate_sha256": candidate_sha256(
                candidate,
                plan["max_weight"],
            ),
            "lineage_index": state["lineage_index"],
            "lineage_generation": state["lineage_generation"],
            "predecessor_ordinal": state["predecessor_ordinal"],
            "trigger_kind": state["trigger_kind"],
            "trigger_terminal_step": state["trigger_terminal_step"],
            "trigger_trace_sha256": state["trigger_trace_sha256"],
            "trigger_credit_sha256": state["trigger_credit_sha256"],
            "submission_step": state["submitted_step"],
            "scheduler_slot_index": state["scheduler_slot_index"],
            "scheduler_slot_generation": state[
                "scheduler_slot_generation"
            ],
            "kind": state["outcome"],
            "rejection_reason": state["rejection_reason"],
            "terminal_action": state["terminal_action"],
            "admitted_step": state["admitted_step"],
            "first_service_step": state["first_service_step"],
            "terminal_step": state["terminal_step"],
            "served_quanta": state["served_quanta"],
            "maximum_wait_quanta": state["maximum_wait_quanta"],
            "admission_trace_sha256": state[
                "admission_trace_sha256"
            ],
            "terminal_trace_sha256": state["terminal_trace_sha256"],
        }
        outcome["record_sha256"] = outcome_record_sha256(outcome)
        outcomes.append(outcome)

    fairness_error = 0
    for left_index, (left, left_state) in enumerate(
        zip(candidates, runtime)
    ):
        if not left["fairness_member"]:
            continue
        for right, right_state in zip(
            candidates[left_index + 1 :],
            runtime[left_index + 1 :],
        ):
            if not right["fairness_member"]:
                continue
            fairness_error = max(
                fairness_error,
                abs(
                    left_state["fairness_quanta"] * right["weight"]
                    - right_state["fairness_quanta"] * left["weight"]
                ),
            )

    initial_count = plan["in_flight_target"]
    replacement_states = runtime[initial_count:]
    summary = {
        "in_flight_target": plan["in_flight_target"],
        "capacity": plan["capacity"],
        "candidate_budget": len(candidates),
        "attempted": len(candidates),
        "admitted": sum(
            state["outcome"] != OUTCOME_REJECTED for state in runtime
        ),
        "rejected": sum(
            state["outcome"] == OUTCOME_REJECTED for state in runtime
        ),
        "completed": sum(
            state["outcome"] == OUTCOME_COMPLETED for state in runtime
        ),
        "cancelled": sum(
            state["outcome"] == OUTCOME_CANCELLED for state in runtime
        ),
        "timed_out": sum(
            state["outcome"] == OUTCOME_TIMED_OUT for state in runtime
        ),
        "service_quanta": service_quanta,
        "driver_steps": driver_steps,
        "final_logical_tick": logical_tick,
        "maximum_active": maximum_active,
        "maximum_due_credits": maximum_due,
        "maximum_live_receipts": maximum_active,
        "replacement_attempts": len(replacement_states),
        "replacements_after_completed": sum(
            state["trigger_kind"] == TRIGGER_COMPLETED
            for state in replacement_states
        ),
        "replacements_after_rejected": sum(
            state["trigger_kind"] == TRIGGER_REJECTED
            for state in replacement_states
        ),
        "replacements_after_cancelled": sum(
            state["trigger_kind"] == TRIGGER_CANCELLED
            for state in replacement_states
        ),
        "replacements_after_timed_out": sum(
            state["trigger_kind"] == TRIGGER_TIMED_OUT
            for state in replacement_states
        ),
        "credits_sealed": len(candidates),
        "credits_exhausted": credits_exhausted,
        "lineage_count": plan["in_flight_target"],
        "maximum_lineage_generation": max(
            state["lineage_generation"] for state in runtime
        ),
        "peak_host_bytes": peak_host_bytes,
        "maximum_wait_quanta": max(
            state["maximum_wait_quanta"] for state in runtime
        ),
        "maximum_service_gap": (
            (plan["capacity"] - 1) * plan["max_weight"] + 1
        ),
        "fairness_cross_product_error": fairness_error,
        "final_active": active_count(),
        "final_due_credits": len(due),
        "final_finished": 0,
        "final_active_reservations": 0,
        "final_committed_receipts": 0,
        "successful_commits": successful_commits,
        "releases": releases,
        "bank_cancellations": 0,
        "bank_rejected_capacity": 0,
        "bank_rejected_slots": 0,
        "zero_orphan_ownership": (
            active_count() == 0
            and not due
            and not any(used.values())
            and successful_commits == releases
        ),
        "peak": peak,
    }
    if (
        summary["attempted"] != summary["admitted"] + summary["rejected"]
        or summary["admitted"]
        != summary["completed"] + summary["cancelled"] + summary["timed_out"]
        or summary["credits_sealed"]
        != summary["replacement_attempts"] + summary["credits_exhausted"]
        or not summary["zero_orphan_ownership"]
    ):
        raise WorkloadClosedLoopError("closed-loop summary invariant failed")

    result = {
        "plan_sha256": plan_sha256(plan),
        "outcomes": outcomes,
        "trace": trace,
        "summary": summary,
    }
    result["outcome_sha256"] = outcomes_sha256(outcomes)
    result["trace_sha256"] = trace_sha256(trace)
    result["summary_sha256"] = summary_sha256(summary)
    result["result_sha256"] = _sha(
        RESULT_DOMAIN,
        _u64(RESULT_ABI),
        result["plan_sha256"],
        result["outcome_sha256"],
        result["trace_sha256"],
        result["summary_sha256"],
    )
    return result


def _validate_result_structure(plan: Record, result: Record) -> None:
    if not isinstance(result, dict) or set(result) != {
        "plan_sha256",
        "outcome_sha256",
        "trace_sha256",
        "summary_sha256",
        "result_sha256",
        "outcomes",
        "trace",
        "summary",
    }:
        raise WorkloadClosedLoopError("invalid result fields")
    if result["plan_sha256"] != plan_sha256(plan):
        raise WorkloadClosedLoopError("result binds a foreign plan")
    if len(result["outcomes"]) != len(plan["candidates"]):
        raise WorkloadClosedLoopError("outcome count contradicts plan")
    if outcomes_sha256(result["outcomes"]) != result["outcome_sha256"]:
        raise WorkloadClosedLoopError("outcome section root mismatch")
    if trace_sha256(result["trace"]) != result["trace_sha256"]:
        raise WorkloadClosedLoopError("trace section root mismatch")
    if summary_sha256(result["summary"]) != result["summary_sha256"]:
        raise WorkloadClosedLoopError("summary root mismatch")
    expected = _sha(
        RESULT_DOMAIN,
        _u64(RESULT_ABI),
        _digest(result["plan_sha256"]),
        _digest(result["outcome_sha256"]),
        _digest(result["trace_sha256"]),
        _digest(result["summary_sha256"]),
    )
    if expected != result["result_sha256"]:
        raise WorkloadClosedLoopError("result root mismatch")


def validate_result(plan_value: Record, result: Record) -> Record:
    """Validate roots and require equality with an independent direct replay."""

    plan = validate_plan(plan_value)
    _validate_result_structure(plan, result)
    expected = replay_plan(plan)
    if result != expected:
        raise WorkloadClosedLoopError(
            "result contradicts deterministic closed-loop replay"
        )
    return result


def required_plan_bytes(candidate_count: int) -> int:
    """Return the exact canonical plan wire length."""

    if (
        isinstance(candidate_count, bool)
        or not isinstance(candidate_count, int)
        or not 0 < candidate_count <= MAXIMUM_CANDIDATES
    ):
        raise WorkloadClosedLoopError("invalid candidate count")
    return (
        PLAN_HEADER_BYTES
        + candidate_count * CANDIDATE_RECORD_BYTES
        + PLAN_FOOTER_BYTES
    )


def encode_plan(plan_value: Record) -> bytes:
    """Encode a validated plan as the canonical little-endian wire."""

    plan = validate_plan(plan_value)
    output = bytearray(required_plan_bytes(len(plan["candidates"])))
    output[:8] = PLAN_MAGIC
    header_values = (
        PLAN_ABI,
        len(output),
        PLAN_HEADER_BYTES,
        CANDIDATE_RECORD_BYTES,
        PLAN_FOOTER_BYTES,
        ALLOWED_FLAGS,
        len(plan["candidates"]),
        plan["seed"],
        plan["in_flight_target"],
        plan["capacity"],
        plan["max_driver_steps"],
        plan["max_service_quanta"],
        plan["fairness_start_tick"],
        plan["fairness_end_tick"],
        plan["bank_epoch"],
        plan["scheduler_epoch"],
        plan["max_weight"],
        plan["max_projection_quanta"],
        plan["max_projection_operations"],
    )
    for index, value in enumerate(header_values, start=1):
        _write_u64(output, index * 8, value)
    for index, name in enumerate(workload.LIMIT_FIELDS):
        _write_u64(output, 160 + index * 8, plan["limits"][name])
    output[248:280] = plan["challenge"]
    output[280:312] = plan_sha256(plan)

    offset = PLAN_HEADER_BYTES
    for candidate in plan["candidates"]:
        for index, name in enumerate(
            ("ordinal", "family", "operation", "media_kind")
        ):
            _write_u64(output, offset + index * 8, candidate[name])
        output[offset + 32 : offset + 64] = candidate["profile_sha256"]
        for index, name in enumerate(
            (
                "weight",
                "work_quanta",
                "deadline_budget_quanta",
                "terminal_action_after_steps",
                "terminal_action",
            )
        ):
            _write_u64(output, offset + 64 + index * 8, candidate[name])
        _write_u64(output, offset + 104, int(candidate["fairness_member"]))
        for index, name in enumerate(
            (
                "tenant_key",
                "request_key",
                "request_generation",
                "resource_owner_key",
            )
        ):
            _write_u64(output, offset + 112 + index * 8, candidate[name])
        for index, name in enumerate(workload.CLAIM_FIELDS):
            _write_u64(
                output,
                offset + 144 + index * 8,
                candidate["claim"][name],
            )
        output[offset + 224 : offset + 256] = candidate_sha256(
            candidate,
            plan["max_weight"],
        )
        offset += CANDIDATE_RECORD_BYTES
    output[-PLAN_FOOTER_BYTES:] = _sha(
        PLAN_WIRE_DOMAIN,
        bytes(output[:-PLAN_FOOTER_BYTES]),
    )
    return bytes(output)


def decode_plan(encoded: bytes) -> Record:
    """Decode and fully validate a canonical plan wire."""

    if (
        not isinstance(encoded, bytes)
        or len(encoded) < PLAN_HEADER_BYTES + PLAN_FOOTER_BYTES
        or encoded[:8] != PLAN_MAGIC
        or _read_u64(encoded, 8) != PLAN_ABI
        or _read_u64(encoded, 16) != len(encoded)
        or _read_u64(encoded, 24) != PLAN_HEADER_BYTES
        or _read_u64(encoded, 32) != CANDIDATE_RECORD_BYTES
        or _read_u64(encoded, 40) != PLAN_FOOTER_BYTES
        or _read_u64(encoded, 48) != ALLOWED_FLAGS
        or encoded[312:320] != bytes(8)
        or encoded[-PLAN_FOOTER_BYTES:]
        != _sha(PLAN_WIRE_DOMAIN, encoded[:-PLAN_FOOTER_BYTES])
    ):
        raise WorkloadClosedLoopError("invalid plan wire")
    candidate_count = _read_u64(encoded, 56)
    if len(encoded) != required_plan_bytes(candidate_count):
        raise WorkloadClosedLoopError("invalid plan length")

    candidates: list[Record] = []
    offset = PLAN_HEADER_BYTES
    max_weight = _read_u64(encoded, 136)
    for ordinal in range(candidate_count):
        fairness_marker = _read_u64(encoded, offset + 104)
        if fairness_marker not in (0, 1):
            raise WorkloadClosedLoopError("invalid fairness marker")
        candidate = {
            name: _read_u64(encoded, offset + index * 8)
            for index, name in enumerate(
                ("ordinal", "family", "operation", "media_kind")
            )
        }
        candidate["profile_sha256"] = encoded[offset + 32 : offset + 64]
        candidate.update(
            {
                name: _read_u64(encoded, offset + 64 + index * 8)
                for index, name in enumerate(
                    (
                        "weight",
                        "work_quanta",
                        "deadline_budget_quanta",
                        "terminal_action_after_steps",
                        "terminal_action",
                    )
                )
            }
        )
        candidate["fairness_member"] = bool(fairness_marker)
        candidate.update(
            {
                name: _read_u64(encoded, offset + 112 + index * 8)
                for index, name in enumerate(
                    (
                        "tenant_key",
                        "request_key",
                        "request_generation",
                        "resource_owner_key",
                    )
                )
            }
        )
        candidate["claim"] = {
            name: _read_u64(encoded, offset + 144 + index * 8)
            for index, name in enumerate(workload.CLAIM_FIELDS)
        }
        if (
            candidate["ordinal"] != ordinal
            or candidate_sha256(candidate, max_weight)
            != encoded[offset + 224 : offset + 256]
        ):
            raise WorkloadClosedLoopError("candidate wire root mismatch")
        candidates.append(candidate)
        offset += CANDIDATE_RECORD_BYTES

    plan = {
        "seed": _read_u64(encoded, 64),
        "in_flight_target": _read_u64(encoded, 72),
        "capacity": _read_u64(encoded, 80),
        "max_driver_steps": _read_u64(encoded, 88),
        "max_service_quanta": _read_u64(encoded, 96),
        "fairness_start_tick": _read_u64(encoded, 104),
        "fairness_end_tick": _read_u64(encoded, 112),
        "bank_epoch": _read_u64(encoded, 120),
        "scheduler_epoch": _read_u64(encoded, 128),
        "max_weight": max_weight,
        "max_projection_quanta": _read_u64(encoded, 144),
        "max_projection_operations": _read_u64(encoded, 152),
        "limits": {
            name: _read_u64(encoded, 160 + index * 8)
            for index, name in enumerate(workload.LIMIT_FIELDS)
        },
        "challenge": encoded[248:280],
        "candidates": candidates,
    }
    plan = validate_plan(plan)
    if plan_sha256(plan) != encoded[280:312]:
        raise WorkloadClosedLoopError("plan wire root mismatch")
    return plan


def required_result_bytes(outcome_count: int, trace_count: int) -> int:
    """Return the exact canonical result wire length."""

    if (
        isinstance(outcome_count, bool)
        or not isinstance(outcome_count, int)
        or not 0 < outcome_count <= MAXIMUM_CANDIDATES
    ):
        raise WorkloadClosedLoopError("invalid outcome count")
    if (
        isinstance(trace_count, bool)
        or not isinstance(trace_count, int)
        or not 0 < trace_count <= MAXIMUM_TRACE_RECORDS
    ):
        raise WorkloadClosedLoopError("invalid trace count")
    return (
        RESULT_HEADER_BYTES
        + outcome_count * OUTCOME_RECORD_BYTES
        + trace_count * TRACE_RECORD_BYTES
        + SUMMARY_RECORD_BYTES
        + RESULT_FOOTER_BYTES
    )


def _write_outcome_record(
    output: bytearray,
    offset: int,
    outcome: Record,
) -> None:
    _write_u64(output, offset, outcome["ordinal"])
    output[offset + 8 : offset + 40] = outcome["candidate_sha256"]
    for index, name in enumerate(
        (
            "lineage_index",
            "lineage_generation",
            "predecessor_ordinal",
            "trigger_kind",
            "trigger_terminal_step",
        )
    ):
        _write_u64(output, offset + 40 + index * 8, outcome[name])
    output[offset + 80 : offset + 112] = outcome["trigger_trace_sha256"]
    output[offset + 112 : offset + 144] = outcome["trigger_credit_sha256"]
    for index, name in enumerate(OUTCOME_FIELDS[6:]):
        _write_u64(output, offset + 144 + index * 8, outcome[name])
    output[offset + 232 : offset + 264] = outcome[
        "admission_trace_sha256"
    ]
    output[offset + 264 : offset + 296] = outcome[
        "terminal_trace_sha256"
    ]
    output[offset + 296 : offset + 328] = outcome["record_sha256"]


def _write_trace_record(
    output: bytearray,
    offset: int,
    record: Record,
) -> None:
    for index, name in enumerate(TRACE_FIELDS):
        _write_u64(output, offset + index * 8, record[name])
    output[offset + 168 : offset + 200] = record["record_sha256"]


def _write_summary_record(
    output: bytearray,
    offset: int,
    summary: Record,
    root: bytes,
) -> None:
    peak_index = SUMMARY_FIELDS.index("peak_host_bytes") + 1
    for index, name in enumerate(SUMMARY_FIELDS[:peak_index]):
        _write_u64(output, offset + index * 8, int(summary[name]))
    for index, name in enumerate(workload.CLAIM_FIELDS):
        _write_u64(output, offset + 200 + index * 8, summary["peak"][name])
    for index, name in enumerate(SUMMARY_FIELDS[peak_index:]):
        _write_u64(output, offset + 280 + index * 8, int(summary[name]))
    output[offset + 392 : offset + 424] = root


def encode_result(plan_value: Record, result_value: Record) -> bytes:
    """Encode a result after exact validation by independent replay."""

    plan = validate_plan(plan_value)
    result = validate_result(plan, result_value)
    outcomes = result["outcomes"]
    trace = result["trace"]
    output = bytearray(required_result_bytes(len(outcomes), len(trace)))
    output[:8] = RESULT_MAGIC
    header_values = (
        RESULT_ABI,
        len(output),
        RESULT_HEADER_BYTES,
        OUTCOME_RECORD_BYTES,
        TRACE_RECORD_BYTES,
        SUMMARY_RECORD_BYTES,
        RESULT_FOOTER_BYTES,
        ALLOWED_FLAGS,
        len(outcomes),
        len(trace),
        0,
    )
    for index, value in enumerate(header_values, start=1):
        _write_u64(output, index * 8, value)
    for offset, name in (
        (96, "plan_sha256"),
        (128, "outcome_sha256"),
        (160, "trace_sha256"),
        (192, "summary_sha256"),
        (224, "result_sha256"),
    ):
        output[offset : offset + 32] = result[name]

    offset = RESULT_HEADER_BYTES
    for outcome in outcomes:
        _write_outcome_record(output, offset, outcome)
        offset += OUTCOME_RECORD_BYTES
    for record in trace:
        _write_trace_record(output, offset, record)
        offset += TRACE_RECORD_BYTES
    _write_summary_record(
        output,
        offset,
        result["summary"],
        result["summary_sha256"],
    )
    output[-RESULT_FOOTER_BYTES:] = _sha(
        RESULT_WIRE_DOMAIN,
        bytes(output[:-RESULT_FOOTER_BYTES]),
    )
    return bytes(output)


def _decode_outcome_record(encoded: bytes, offset: int) -> Record:
    outcome = {
        "ordinal": _read_u64(encoded, offset),
        "candidate_sha256": encoded[offset + 8 : offset + 40],
    }
    outcome.update(
        {
            name: _read_u64(encoded, offset + 40 + index * 8)
            for index, name in enumerate(
                (
                    "lineage_index",
                    "lineage_generation",
                    "predecessor_ordinal",
                    "trigger_kind",
                    "trigger_terminal_step",
                )
            )
        }
    )
    outcome["trigger_trace_sha256"] = encoded[offset + 80 : offset + 112]
    outcome["trigger_credit_sha256"] = encoded[offset + 112 : offset + 144]
    outcome.update(
        {
            name: _read_u64(encoded, offset + 144 + index * 8)
            for index, name in enumerate(OUTCOME_FIELDS[6:])
        }
    )
    outcome["admission_trace_sha256"] = encoded[offset + 232 : offset + 264]
    outcome["terminal_trace_sha256"] = encoded[offset + 264 : offset + 296]
    outcome["record_sha256"] = encoded[offset + 296 : offset + 328]
    return outcome


def _decode_trace_record(encoded: bytes, offset: int) -> Record:
    record = {
        name: _read_u64(encoded, offset + index * 8)
        for index, name in enumerate(TRACE_FIELDS)
    }
    record["record_sha256"] = encoded[offset + 168 : offset + 200]
    return record


def _decode_summary_record(encoded: bytes, offset: int) -> tuple[Record, bytes]:
    peak_index = SUMMARY_FIELDS.index("peak_host_bytes") + 1
    summary = {
        name: _read_u64(encoded, offset + index * 8)
        for index, name in enumerate(SUMMARY_FIELDS[:peak_index])
    }
    summary["peak"] = {
        name: _read_u64(encoded, offset + 200 + index * 8)
        for index, name in enumerate(workload.CLAIM_FIELDS)
    }
    summary.update(
        {
            name: _read_u64(encoded, offset + 280 + index * 8)
            for index, name in enumerate(SUMMARY_FIELDS[peak_index:])
        }
    )
    marker = summary["zero_orphan_ownership"]
    if marker not in (0, 1):
        raise WorkloadClosedLoopError("invalid zero-orphan marker")
    summary["zero_orphan_ownership"] = bool(marker)
    return summary, encoded[offset + 392 : offset + 424]


def decode_result(plan_value: Record, encoded: bytes) -> Record:
    """Decode a canonical result wire and validate it by exact replay."""

    plan = validate_plan(plan_value)
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < (
            RESULT_HEADER_BYTES + SUMMARY_RECORD_BYTES + RESULT_FOOTER_BYTES
        )
        or encoded[:8] != RESULT_MAGIC
        or _read_u64(encoded, 8) != RESULT_ABI
        or _read_u64(encoded, 16) != len(encoded)
        or _read_u64(encoded, 24) != RESULT_HEADER_BYTES
        or _read_u64(encoded, 32) != OUTCOME_RECORD_BYTES
        or _read_u64(encoded, 40) != TRACE_RECORD_BYTES
        or _read_u64(encoded, 48) != SUMMARY_RECORD_BYTES
        or _read_u64(encoded, 56) != RESULT_FOOTER_BYTES
        or _read_u64(encoded, 64) != ALLOWED_FLAGS
        or _read_u64(encoded, 88) != 0
        or encoded[-RESULT_FOOTER_BYTES:]
        != _sha(RESULT_WIRE_DOMAIN, encoded[:-RESULT_FOOTER_BYTES])
    ):
        raise WorkloadClosedLoopError("invalid result wire")
    outcome_count = _read_u64(encoded, 72)
    trace_count = _read_u64(encoded, 80)
    if len(encoded) != required_result_bytes(outcome_count, trace_count):
        raise WorkloadClosedLoopError("invalid result length")

    offset = RESULT_HEADER_BYTES
    outcomes = []
    for _ in range(outcome_count):
        outcomes.append(_decode_outcome_record(encoded, offset))
        offset += OUTCOME_RECORD_BYTES
    trace = []
    for _ in range(trace_count):
        trace.append(_decode_trace_record(encoded, offset))
        offset += TRACE_RECORD_BYTES
    summary, summary_record_root = _decode_summary_record(encoded, offset)
    result = {
        "plan_sha256": encoded[96:128],
        "outcome_sha256": encoded[128:160],
        "trace_sha256": encoded[160:192],
        "summary_sha256": encoded[192:224],
        "result_sha256": encoded[224:256],
        "outcomes": outcomes,
        "trace": trace,
        "summary": summary,
    }
    if summary_record_root != result["summary_sha256"]:
        raise WorkloadClosedLoopError("summary record root mismatch")
    return validate_result(plan, result)


TRIGGER_NAMES = {
    TRIGGER_INITIAL: "initial",
    TRIGGER_COMPLETED: "completed",
    TRIGGER_REJECTED: "rejected",
    TRIGGER_CANCELLED: "cancelled",
    TRIGGER_TIMED_OUT: "timed_out",
}
OUTCOME_NAMES = {
    OUTCOME_COMPLETED: "completed",
    OUTCOME_REJECTED: "rejected",
    OUTCOME_CANCELLED: "cancelled",
    OUTCOME_TIMED_OUT: "timed_out",
}
REJECTION_NAMES = {
    REJECTION_NONE: "none",
    REJECTION_NO_SLOT: "no_slot",
    REJECTION_DUPLICATE_TENANT: "duplicate_tenant",
    REJECTION_RESOURCE_LIMIT: "resource_limit",
    REJECTION_PROJECTION_LIMIT: "projection_limit",
    REJECTION_DEADLINE_INFEASIBLE: "deadline_infeasible",
}
ACTION_NAMES = {
    ACTION_NONE: "none",
    ACTION_CANCEL: "cancel",
    ACTION_TIMEOUT: "timeout",
}


def _name(names: dict[int, str], value: int, what: str) -> str:
    try:
        return names[value]
    except KeyError as error:
        raise WorkloadClosedLoopError(f"invalid {what}") from error


def _optional_u64(value: int) -> int | None:
    return None if value == ABSENT else value


def build_report() -> Record:
    """Recompute the retained canonical report from first principles."""

    plan = reference_plan()
    result = replay_plan(plan)
    plan_wire = encode_plan(plan)
    result_wire = encode_result(plan, result)
    summary: Record = {}
    peak_index = SUMMARY_FIELDS.index("peak_host_bytes") + 1
    for name in SUMMARY_FIELDS[:peak_index]:
        summary[name] = result["summary"][name]
    summary["peak"] = {
        name: result["summary"]["peak"][name]
        for name in workload.CLAIM_FIELDS
    }
    for name in SUMMARY_FIELDS[peak_index:]:
        summary[name] = result["summary"][name]
    outcomes = []
    for outcome in result["outcomes"]:
        outcomes.append(
            {
                "ordinal": outcome["ordinal"],
                "candidate_sha256": outcome["candidate_sha256"].hex(),
                "lineage_index": outcome["lineage_index"],
                "lineage_generation": outcome["lineage_generation"],
                "predecessor_ordinal": _optional_u64(
                    outcome["predecessor_ordinal"]
                ),
                "trigger_kind": _name(
                    TRIGGER_NAMES,
                    outcome["trigger_kind"],
                    "trigger kind",
                ),
                "trigger_terminal_step": _optional_u64(
                    outcome["trigger_terminal_step"]
                ),
                "trigger_trace_sha256": outcome[
                    "trigger_trace_sha256"
                ].hex(),
                "trigger_credit_sha256": outcome[
                    "trigger_credit_sha256"
                ].hex(),
                "submission_step": outcome["submission_step"],
                "scheduler_slot_index": _optional_u64(
                    outcome["scheduler_slot_index"]
                ),
                "scheduler_slot_generation": outcome[
                    "scheduler_slot_generation"
                ],
                "kind": _name(
                    OUTCOME_NAMES,
                    outcome["kind"],
                    "outcome kind",
                ),
                "rejection_reason": _name(
                    REJECTION_NAMES,
                    outcome["rejection_reason"],
                    "rejection reason",
                ),
                "terminal_action": _name(
                    ACTION_NAMES,
                    outcome["terminal_action"],
                    "terminal action",
                ),
                "admitted_step": _optional_u64(outcome["admitted_step"]),
                "first_service_step": _optional_u64(
                    outcome["first_service_step"]
                ),
                "terminal_step": outcome["terminal_step"],
                "served_quanta": outcome["served_quanta"],
                "maximum_wait_quanta": outcome["maximum_wait_quanta"],
                "admission_trace_sha256": outcome[
                    "admission_trace_sha256"
                ].hex(),
                "terminal_trace_sha256": outcome[
                    "terminal_trace_sha256"
                ].hex(),
                "record_sha256": outcome["record_sha256"].hex(),
            }
        )
    return {
        "schema": SCHEMA,
        "plan_abi": f"{PLAN_ABI:016x}",
        "result_abi": f"{RESULT_ABI:016x}",
        "trace_abi": f"{TRACE_ABI:016x}",
        "summary_abi": f"{SUMMARY_ABI:016x}",
        "candidate_abi": f"{CANDIDATE_ABI:016x}",
        "outcome_abi": f"{OUTCOME_ABI:016x}",
        "candidate_count": len(result["outcomes"]),
        "trace_count": len(result["trace"]),
        "plan_wire_bytes": len(plan_wire),
        "result_wire_bytes": len(result_wire),
        "plan_wire_sha256": hashlib.sha256(plan_wire).hexdigest(),
        "result_wire_sha256": hashlib.sha256(result_wire).hexdigest(),
        "plan_sha256": result["plan_sha256"].hex(),
        "outcome_sha256": result["outcome_sha256"].hex(),
        "trace_sha256": result["trace_sha256"].hex(),
        "summary_sha256": result["summary_sha256"].hex(),
        "result_sha256": result["result_sha256"].hex(),
        "summary": summary,
        "outcomes": outcomes,
    }


def render_report(report: Record | None = None) -> str:
    """Render exactly one canonical compact ASCII JSON line."""

    if report is None:
        report = build_report()
    return json.dumps(report, ensure_ascii=True, separators=(",", ":")) + "\n"


def validate_report(value: Record) -> Record:
    """Require exact equality with the independently replayed report."""

    if not isinstance(value, dict) or value != build_report():
        raise WorkloadClosedLoopError(
            "report contradicts independent closed-loop replay"
        )
    return value


def _load_json_exact(encoded: bytes, where: str) -> Record:
    if not encoded or not encoded.endswith(b"\n") or encoded.endswith(b"\n\n"):
        raise WorkloadClosedLoopError(f"{where} is not one canonical line")
    try:
        text = encoded.decode("ascii")

        def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
            value: Record = {}
            for key, item in pairs:
                if key in value:
                    raise WorkloadClosedLoopError(
                        f"{where} contains duplicate fields"
                    )
                value[key] = item
            return value

        def invalid_constant(_: str) -> None:
            raise WorkloadClosedLoopError(
                f"{where} contains a non-JSON number"
            )

        decoded = json.loads(
            text,
            object_pairs_hook=object_pairs,
            parse_constant=invalid_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WorkloadClosedLoopError(f"{where} is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise WorkloadClosedLoopError(f"{where} is not a JSON object")
    if render_report(decoded).encode("ascii") != encoded:
        raise WorkloadClosedLoopError(f"{where} is not canonical JSON")
    return decoded


def verify_runner(runner: Path | list[str], fixture: Path) -> None:
    """Fail closed unless fixture, native runner, and oracle agree exactly."""

    if isinstance(runner, Path):
        runner_argv = [str(runner)]
    elif runner and all(isinstance(value, str) and value for value in runner):
        runner_argv = runner
    else:
        raise WorkloadClosedLoopError("invalid native runner command")
    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = _load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise WorkloadClosedLoopError("retained fixture is stale")
    completed = subprocess.run(
        runner_argv,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if completed.returncode != 0 or completed.stderr:
        raise WorkloadClosedLoopError("native runner failed")
    runner_value = _load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise WorkloadClosedLoopError(
            "native runner contradicts Python oracle"
        )


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the retained deterministic closed-loop workload",
    )
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verify_runner(args.runner, args.fixture)
    except (OSError, subprocess.SubprocessError, WorkloadClosedLoopError) as error:
        print(f"workload-closed-loop: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
