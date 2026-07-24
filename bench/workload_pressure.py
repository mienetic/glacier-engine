"""Independent logical-step oracle for mixed-media workload pressure.

This is a deterministic state-machine replay, not a wall-clock load runner. It
does not derive throughput, latency in seconds, RSS, device use, or model/media
quality. The native Zig implementation and this oracle share only the public
wire rules and retained scenario values.
"""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Any


class WorkloadPressureError(ValueError):
    """The scenario, evidence, or logical replay is invalid."""


Record = dict[str, Any]

SCENARIO_ABI = 0x4757505300000001
RESULT_ABI = 0x4757505200000001
SUMMARY_ABI = 0x4757505900000001
TRACE_ABI = 0x4757505400000001
PROFILE_ABI = 0x4757505000000001

SCENARIO_MAGIC = b"GWPSC1\x00\x00"
RESULT_MAGIC = b"GWPRS1\x00\x00"
SCENARIO_HEADER_BYTES = 256
SCENARIO_ITEM_BYTES = 272
SCENARIO_FOOTER_BYTES = 32
RESULT_HEADER_BYTES = 544
OUTCOME_RECORD_BYTES = 160
TRACE_RECORD_BYTES = 112
RESULT_FOOTER_BYTES = 32
MAXIMUM_ITEMS = 16
MAXIMUM_TRACE_RECORDS = 64
MAXIMUM_DRIVER_STEPS = 512
MAXIMUM_SERVICE_QUANTA = 256
MAXIMUM_WEIGHT = (1 << 16) - 1
ABSENT_STEP = (1 << 64) - 1
ABSENT_ITEM = ABSENT_STEP
U64_MAX = ABSENT_STEP
ZERO_DIGEST = bytes(32)

SCENARIO_DOMAIN = b"glacier-workload-pressure-scenario-v1\x00"
SCENARIO_ITEM_DOMAIN = b"glacier-workload-pressure-item-v1\x00"
PROFILE_DOMAIN = b"glacier-workload-pressure-profile-v1\x00"
RESULT_DOMAIN = b"glacier-workload-pressure-result-v1\x00"
TRACE_DOMAIN = b"glacier-workload-pressure-trace-v1\x00"
TRACE_RECORD_DOMAIN = b"glacier-workload-pressure-trace-record-v1\x00"
OUTCOME_DOMAIN = b"glacier-workload-pressure-outcomes-v1\x00"
SUMMARY_DOMAIN = b"glacier-workload-pressure-summary-v1\x00"

MODE_OPEN_LOOP = 1
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

MEDIA_IMAGE = 1
MEDIA_AUDIO = 2
MEDIA_VIDEO = 3
FAMILY_VISION_UNDERSTANDING = 3
FAMILY_AUDIO_UNDERSTANDING = 4
FAMILY_VIDEO_UNDERSTANDING = 6
OPERATION_ENCODE = 3

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

SUMMARY_FIELDS = (
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
    "queue_delay_p50_steps",
    "queue_delay_p95_steps",
    "queue_delay_p99_steps",
    "queue_delay_max_steps",
    "completion_delay_p50_steps",
    "completion_delay_p95_steps",
    "completion_delay_p99_steps",
    "completion_delay_max_steps",
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

OUTCOME_FIELDS = (
    "ordinal",
    "kind",
    "rejection_reason",
    "terminal_action",
    "admitted_step",
    "first_service_step",
    "terminal_step",
    "served_quanta",
    "maximum_wait_quanta",
    "queue_delay_steps",
    "completion_delay_steps",
)

TRACE_FIELDS = (
    "driver_step",
    "item_ordinal",
    "event_kind",
    "rejection_reason",
    "terminal_action",
    "logical_tick_before",
    "logical_tick_after",
    "remaining_before",
    "remaining_after",
    "wait_quanta",
)


def _u64(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise WorkloadPressureError("u64 out of range")
    return struct.pack("<Q", value)


def _read_u64(value: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", value, offset)[0]


def _write_u64(output: bytearray, offset: int, value: int) -> None:
    output[offset : offset + 8] = _u64(value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise WorkloadPressureError("invalid digest")
    return value


def _sha(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _empty_claim() -> Record:
    return {name: 0 for name in CLAIM_FIELDS}


def _claim(**values: int) -> Record:
    claim = _empty_claim()
    claim.update(values)
    if set(claim) != set(CLAIM_FIELDS):
        raise WorkloadPressureError("unknown claim field")
    for value in claim.values():
        _u64(value)
    return claim


def image_claim() -> Record:
    return _claim(
        capsule_bytes=928,
        activation_bytes=12,
        output_journal_bytes=12,
        staging_bytes=512,
        io_bytes=364,
        queue_slots=1,
    )


def audio_claim() -> Record:
    return _claim(
        capsule_bytes=928,
        activation_bytes=32,
        output_journal_bytes=4,
        staging_bytes=256,
        io_bytes=384,
        queue_slots=1,
    )


def video_claim() -> Record:
    return _claim(
        capsule_bytes=928,
        activation_bytes=8,
        output_journal_bytes=4,
        staging_bytes=128,
        io_bytes=360,
        queue_slots=1,
    )


def _profile(kind: int) -> Record:
    if kind == MEDIA_IMAGE:
        family, claim = FAMILY_VISION_UNDERSTANDING, image_claim()
    elif kind == MEDIA_AUDIO:
        family, claim = FAMILY_AUDIO_UNDERSTANDING, audio_claim()
    elif kind == MEDIA_VIDEO:
        family, claim = FAMILY_VIDEO_UNDERSTANDING, video_claim()
    else:
        raise WorkloadPressureError("unsupported media profile")
    root = _sha(
        PROFILE_DOMAIN,
        _u64(PROFILE_ABI),
        _u64(kind),
        _u64(family),
        _u64(OPERATION_ENCODE),
        *(_u64(claim[name]) for name in CLAIM_FIELDS),
    )
    return {
        "family": family,
        "operation": OPERATION_ENCODE,
        "media_kind": kind,
        "claim": claim,
        "profile_sha256": root,
    }


def _item(
    ordinal: int,
    kind: int,
    arrival_step: int,
    weight: int,
    work_quanta: int,
    deadline_tick: int,
    terminal_action_step: int,
    terminal_action: int,
    fairness_member: bool,
) -> Record:
    profile = _profile(kind)
    identity = ordinal + 1
    return {
        "ordinal": ordinal,
        **profile,
        "arrival_step": arrival_step,
        "weight": weight,
        "work_quanta": work_quanta,
        "deadline_tick": deadline_tick,
        "terminal_action_step": terminal_action_step,
        "terminal_action": terminal_action,
        "fairness_member": fairness_member,
        "tenant_key": 0x1000 + identity,
        "request_key": 0x2000 + identity,
        "request_generation": 1,
        "resource_owner_key": 0x3000 + identity,
    }


def reference_scenario() -> Record:
    limits = {name: U64_MAX for name in LIMIT_FIELDS}
    limits["host_bytes"] = 4972
    limits["queue_slots"] = 4
    return {
        "mode": MODE_OPEN_LOOP,
        "seed": 0x4757505320260001,
        "max_driver_steps": 64,
        "fairness_start_tick": 0,
        "fairness_end_tick": 7,
        "bank_epoch": 0x4757504200000001,
        "scheduler_epoch": 0x4757505100000001,
        "max_weight": 4,
        "max_projection_quanta": 256,
        "max_projection_operations": 4096,
        "capacity": 4,
        "limits": limits,
        "challenge": bytes((0x57,)) * 32,
        "items": [
            _item(0, MEDIA_IMAGE, 0, 1, 8, 64, 7, ACTION_CANCEL, True),
            _item(1, MEDIA_AUDIO, 0, 2, 6, 64, ABSENT_STEP, ACTION_NONE, True),
            _item(2, MEDIA_VIDEO, 0, 4, 12, 64, ABSENT_STEP, ACTION_NONE, True),
            _item(3, MEDIA_AUDIO, 0, 1, 8, 0, 3, ACTION_TIMEOUT, False),
            _item(4, MEDIA_VIDEO, 0, 2, 2, 0, ABSENT_STEP, ACTION_NONE, False),
            _item(5, MEDIA_IMAGE, 4, 1, 2, 0, ABSENT_STEP, ACTION_NONE, False),
            _item(6, MEDIA_IMAGE, 8, 1, 2, 64, ABSENT_STEP, ACTION_NONE, False),
        ],
    }


def _validate_claim(value: Record) -> Record:
    if not isinstance(value, dict) or set(value) != set(CLAIM_FIELDS):
        raise WorkloadPressureError("invalid resource claim")
    claim = {name: value[name] for name in CLAIM_FIELDS}
    for amount in claim.values():
        _u64(amount)
    if not any(claim.values()) or claim["queue_slots"] != 1:
        raise WorkloadPressureError("invalid request claim")
    return claim


def _validate_item(item: Record, max_weight: int) -> Record:
    required = {
        "ordinal",
        "family",
        "operation",
        "media_kind",
        "profile_sha256",
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
        "claim",
    }
    if not isinstance(item, dict) or set(item) != required:
        raise WorkloadPressureError("invalid work item fields")
    for name in required - {"claim", "profile_sha256", "fairness_member"}:
        _u64(item[name])
    if not isinstance(item["fairness_member"], bool):
        raise WorkloadPressureError("invalid fairness marker")
    if not 1 <= item["weight"] <= max_weight or item["work_quanta"] == 0:
        raise WorkloadPressureError("invalid service envelope")
    if (
        item["tenant_key"] == 0
        or item["request_key"] == 0
        or item["request_generation"] == 0
        or item["resource_owner_key"] == 0
    ):
        raise WorkloadPressureError("invalid request identity")
    if (item["terminal_action"] == ACTION_NONE) != (
        item["terminal_action_step"] == ABSENT_STEP
    ):
        raise WorkloadPressureError("inconsistent terminal action")
    if item["terminal_action"] not in (
        ACTION_NONE,
        ACTION_CANCEL,
        ACTION_TIMEOUT,
    ):
        raise WorkloadPressureError("invalid terminal action")
    if (
        item["terminal_action"] != ACTION_NONE
        and item["terminal_action_step"] < item["arrival_step"]
    ):
        raise WorkloadPressureError("terminal action precedes arrival")
    profile = _profile(item["media_kind"])
    claim = _validate_claim(item["claim"])
    if (
        item["family"] != profile["family"]
        or item["operation"] != profile["operation"]
        or claim != profile["claim"]
        or item["profile_sha256"] != profile["profile_sha256"]
    ):
        raise WorkloadPressureError("foreign media pressure profile")
    return {**item, "claim": claim}


def validate_scenario(scenario: Record) -> Record:
    required = {
        "mode",
        "seed",
        "max_driver_steps",
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
        "items",
    }
    if not isinstance(scenario, dict) or set(scenario) != required:
        raise WorkloadPressureError("invalid scenario fields")
    for name in required - {"limits", "challenge", "items"}:
        _u64(scenario[name])
    if (
        scenario["mode"] != MODE_OPEN_LOOP
        or scenario["seed"] == 0
        or not 0 < scenario["max_driver_steps"] <= MAXIMUM_DRIVER_STEPS
        or scenario["fairness_end_tick"] <= scenario["fairness_start_tick"]
        or scenario["bank_epoch"] == 0
        or scenario["scheduler_epoch"] == 0
        or not 0 < scenario["max_weight"] <= MAXIMUM_WEIGHT
        or scenario["max_projection_quanta"] == 0
        or scenario["max_projection_operations"] == 0
        or not 0 < scenario["capacity"] <= MAXIMUM_ITEMS
    ):
        raise WorkloadPressureError("invalid scenario envelope")
    challenge = _digest(scenario["challenge"])
    limits_value = scenario["limits"]
    if not isinstance(limits_value, dict) or set(limits_value) != set(LIMIT_FIELDS):
        raise WorkloadPressureError("invalid resource limits")
    limits = {name: limits_value[name] for name in LIMIT_FIELDS}
    for amount in limits.values():
        _u64(amount)
    if limits["queue_slots"] < scenario["capacity"]:
        raise WorkloadPressureError("queue limit below slot capacity")
    items_value = scenario["items"]
    if not isinstance(items_value, list) or not 0 < len(items_value) <= MAXIMUM_ITEMS:
        raise WorkloadPressureError("invalid item count")
    items: list[Record] = []
    seen_tenants: set[int] = set()
    seen_requests: set[int] = set()
    seen_owners: set[int] = set()
    previous_arrival = 0
    fairness_members = 0
    total_quanta = 0
    for index, candidate in enumerate(items_value):
        item = _validate_item(candidate, scenario["max_weight"])
        if (
            item["ordinal"] != index
            or item["arrival_step"] >= scenario["max_driver_steps"]
            or (
                item["terminal_action"] != ACTION_NONE
                and item["terminal_action_step"] >= scenario["max_driver_steps"]
            )
            or (index and item["arrival_step"] < previous_arrival)
        ):
            raise WorkloadPressureError("noncanonical item order")
        previous_arrival = item["arrival_step"]
        if (
            item["tenant_key"] in seen_tenants
            or item["request_key"] in seen_requests
            or item["resource_owner_key"] in seen_owners
        ):
            raise WorkloadPressureError("duplicate request identity")
        seen_tenants.add(item["tenant_key"])
        seen_requests.add(item["request_key"])
        seen_owners.add(item["resource_owner_key"])
        total_quanta += item["work_quanta"]
        if total_quanta > MAXIMUM_SERVICE_QUANTA:
            raise WorkloadPressureError("service bound exceeded")
        fairness_members += int(item["fairness_member"])
        items.append(item)
    if fairness_members < 2:
        raise WorkloadPressureError("insufficient fairness cohort")
    if total_quanta + 2 * len(items) + 1 > MAXIMUM_TRACE_RECORDS:
        raise WorkloadPressureError("trace envelope exceeded")
    return {
        **scenario,
        "challenge": challenge,
        "limits": limits,
        "items": items,
    }


def item_sha256(item_value: Record) -> bytes:
    item = _validate_item(item_value, U64_MAX)
    return _sha(
        SCENARIO_ITEM_DOMAIN,
        *(
            _u64(item[name])
            for name in (
                "ordinal",
                "family",
                "operation",
                "media_kind",
                "arrival_step",
                "weight",
                "work_quanta",
                "deadline_tick",
                "terminal_action_step",
                "terminal_action",
            )
        ),
        _u64(int(item["fairness_member"])),
        *(
            _u64(item[name])
            for name in (
                "tenant_key",
                "request_key",
                "request_generation",
                "resource_owner_key",
            )
        ),
        *(_u64(item["claim"][name]) for name in CLAIM_FIELDS),
        item["profile_sha256"],
    )


def scenario_sha256(scenario_value: Record) -> bytes:
    scenario = validate_scenario(scenario_value)
    return _sha(
        SCENARIO_DOMAIN,
        _u64(SCENARIO_ABI),
        *(
            _u64(scenario[name])
            for name in (
                "mode",
                "seed",
                "max_driver_steps",
                "fairness_start_tick",
                "fairness_end_tick",
                "bank_epoch",
                "scheduler_epoch",
                "max_weight",
                "max_projection_quanta",
                "max_projection_operations",
                "capacity",
            )
        ),
        *(_u64(scenario["limits"][name]) for name in LIMIT_FIELDS),
        scenario["challenge"],
        _u64(len(scenario["items"])),
        *(item_sha256(item) for item in scenario["items"]),
    )


def required_scenario_bytes(item_count: int) -> int:
    if not 0 < item_count <= MAXIMUM_ITEMS:
        raise WorkloadPressureError("invalid item count")
    return SCENARIO_HEADER_BYTES + item_count * SCENARIO_ITEM_BYTES + 32


def encode_scenario(scenario_value: Record) -> bytes:
    scenario = validate_scenario(scenario_value)
    output = bytearray(required_scenario_bytes(len(scenario["items"])))
    output[:8] = SCENARIO_MAGIC
    header_values = (
        SCENARIO_ABI,
        len(output),
        0,
        scenario["mode"],
        scenario["seed"],
        scenario["max_driver_steps"],
        scenario["fairness_start_tick"],
        scenario["fairness_end_tick"],
        scenario["bank_epoch"],
        scenario["scheduler_epoch"],
        scenario["max_weight"],
        scenario["max_projection_quanta"],
        scenario["max_projection_operations"],
        scenario["capacity"],
        len(scenario["items"]),
    )
    for index, value in enumerate(header_values, start=1):
        _write_u64(output, index * 8, value)
    for index, name in enumerate(LIMIT_FIELDS):
        _write_u64(output, 128 + index * 8, scenario["limits"][name])
    output[216:248] = scenario["challenge"]
    for index, item in enumerate(scenario["items"]):
        offset = SCENARIO_HEADER_BYTES + index * SCENARIO_ITEM_BYTES
        values = (
            item["ordinal"],
            item["family"],
            item["operation"],
            item["media_kind"],
            item["arrival_step"],
            item["weight"],
            item["work_quanta"],
            item["deadline_tick"],
            item["terminal_action_step"],
            item["terminal_action"],
            int(item["fairness_member"]),
            item["tenant_key"],
            item["request_key"],
            item["request_generation"],
            item["resource_owner_key"],
        )
        for value_index, value in enumerate(values):
            _write_u64(output, offset + value_index * 8, value)
        for claim_index, name in enumerate(CLAIM_FIELDS):
            _write_u64(output, offset + 120 + claim_index * 8, item["claim"][name])
        output[offset + 200 : offset + 232] = item["profile_sha256"]
        output[offset + 232 : offset + 264] = item_sha256(item)
    output[-32:] = scenario_sha256(scenario)
    return bytes(output)


def decode_scenario(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < SCENARIO_HEADER_BYTES + 32
        or encoded[:8] != SCENARIO_MAGIC
        or _read_u64(encoded, 8) != SCENARIO_ABI
        or _read_u64(encoded, 16) != len(encoded)
        or _read_u64(encoded, 24) != 0
        or encoded[248:256] != bytes(8)
    ):
        raise WorkloadPressureError("invalid scenario wire")
    item_count = _read_u64(encoded, 120)
    if len(encoded) != required_scenario_bytes(item_count):
        raise WorkloadPressureError("invalid scenario length")
    items: list[Record] = []
    for index in range(item_count):
        offset = SCENARIO_HEADER_BYTES + index * SCENARIO_ITEM_BYTES
        if encoded[offset + 264 : offset + 272] != bytes(8):
            raise WorkloadPressureError("nonzero item reserved bytes")
        kind = _read_u64(encoded, offset + 24)
        item = {
            "ordinal": _read_u64(encoded, offset),
            "family": _read_u64(encoded, offset + 8),
            "operation": _read_u64(encoded, offset + 16),
            "media_kind": kind,
            "arrival_step": _read_u64(encoded, offset + 32),
            "weight": _read_u64(encoded, offset + 40),
            "work_quanta": _read_u64(encoded, offset + 48),
            "deadline_tick": _read_u64(encoded, offset + 56),
            "terminal_action_step": _read_u64(encoded, offset + 64),
            "terminal_action": _read_u64(encoded, offset + 72),
            "fairness_member": bool(_read_u64(encoded, offset + 80)),
            "tenant_key": _read_u64(encoded, offset + 88),
            "request_key": _read_u64(encoded, offset + 96),
            "request_generation": _read_u64(encoded, offset + 104),
            "resource_owner_key": _read_u64(encoded, offset + 112),
            "claim": {
                name: _read_u64(encoded, offset + 120 + claim_index * 8)
                for claim_index, name in enumerate(CLAIM_FIELDS)
            },
            "profile_sha256": encoded[offset + 200 : offset + 232],
        }
        if _read_u64(encoded, offset + 80) not in (0, 1):
            raise WorkloadPressureError("invalid fairness marker")
        if encoded[offset + 232 : offset + 264] != item_sha256(item):
            raise WorkloadPressureError("invalid item root")
        items.append(item)
    scenario = {
        "mode": _read_u64(encoded, 32),
        "seed": _read_u64(encoded, 40),
        "max_driver_steps": _read_u64(encoded, 48),
        "fairness_start_tick": _read_u64(encoded, 56),
        "fairness_end_tick": _read_u64(encoded, 64),
        "bank_epoch": _read_u64(encoded, 72),
        "scheduler_epoch": _read_u64(encoded, 80),
        "max_weight": _read_u64(encoded, 88),
        "max_projection_quanta": _read_u64(encoded, 96),
        "max_projection_operations": _read_u64(encoded, 104),
        "capacity": _read_u64(encoded, 112),
        "limits": {
            name: _read_u64(encoded, 128 + index * 8)
            for index, name in enumerate(LIMIT_FIELDS)
        },
        "challenge": encoded[216:248],
        "items": items,
    }
    canonical = validate_scenario(scenario)
    if encoded[-32:] != scenario_sha256(canonical):
        raise WorkloadPressureError("invalid scenario footer")
    return canonical


def _claim_add(left: Record, right: Record) -> Record:
    result: Record = {}
    for name in CLAIM_FIELDS:
        value = left[name] + right[name]
        _u64(value)
        result[name] = value
    return result


def _claim_subtract(left: Record, right: Record) -> Record:
    result: Record = {}
    for name in CLAIM_FIELDS:
        if right[name] > left[name]:
            raise WorkloadPressureError("resource accounting underflow")
        result[name] = left[name] - right[name]
    return result


def _host_bytes(claim: Record) -> int:
    value = sum(claim[name] for name in HOST_CLAIM_FIELDS)
    _u64(value)
    return value


def _fits(limits: Record, claim: Record) -> bool:
    return _host_bytes(claim) <= limits["host_bytes"] and all(
        claim[name] <= limits[name] for name in CLAIM_FIELDS
    )


def _select_iwrr(
    slots: list[Record | None],
    initial_cursor: int,
    initial_level: int,
    configured_max_weight: int,
) -> tuple[int, int, int]:
    del configured_max_weight
    active_weights = [
        slot["weight"] for slot in slots if slot is not None and slot["active"]
    ]
    if not active_weights:
        raise WorkloadPressureError("no runnable request")
    max_weight = max(active_weights)
    cursor = min(initial_cursor, len(slots))
    level = initial_level or 1
    if level > max_weight:
        level, cursor = 1, 0
    for _ in range(len(slots) * max_weight):
        if cursor >= len(slots):
            cursor = 0
            level = 1 if level >= max_weight else level + 1
        index = cursor
        cursor += 1
        slot = slots[index]
        if slot is not None and slot["active"] and slot["weight"] >= level:
            return index, cursor, level
    raise WorkloadPressureError("IWRR scan exhausted")


def _projection_rejection(
    slots: list[Record | None],
    candidate_index: int,
    item: Record,
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

    if item["deadline_tick"] and item["work_quanta"] > max_quanta:
        return REJECTION_PROJECTION_LIMIT
    if not item["deadline_tick"]:
        if not spend(len(slots)):
            return REJECTION_PROJECTION_LIMIT
        if not any(
            slot is not None and slot["active"] and slot["deadline_tick"]
            for slot in slots
        ):
            return REJECTION_NONE
    if not spend(len(slots)):
        return REJECTION_PROJECTION_LIMIT

    projected: list[Record | None] = []
    for slot in slots:
        if slot is None or not slot["active"]:
            projected.append(None)
        else:
            projected.append(
                {
                    "active": True,
                    "weight": slot["weight"],
                    "remaining": slot["remaining"],
                    "deadline_tick": slot["deadline_tick"],
                }
            )
    projected[candidate_index] = {
        "active": True,
        "weight": item["weight"],
        "remaining": item["work_quanta"],
        "deadline_tick": item["deadline_tick"],
    }
    deadline_count = sum(
        bool(slot and slot["active"] and slot["deadline_tick"]) for slot in projected
    )
    minimum_deadline_quanta = sum(
        slot["remaining"]
        for slot in projected
        if slot is not None and slot["active"] and slot["deadline_tick"]
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
                slot is not None
                and slot["active"]
                and slot["deadline_tick"]
                and tick >= slot["deadline_tick"]
            ):
                return REJECTION_DEADLINE_INFEASIBLE

        if not spend(len(projected)):
            return REJECTION_PROJECTION_LIMIT
        active_weights = [
            slot["weight"] for slot in projected if slot is not None and slot["active"]
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
            level, cursor = 1, 0
        selected: int | None = None
        for _ in range(len(projected) * max_weight):
            if not spend(1):
                return REJECTION_PROJECTION_LIMIT
            if cursor >= len(projected):
                cursor = 0
                level = 1 if level >= maximum_active_weight else level + 1
            candidate_slot = cursor
            cursor += 1
            slot = projected[candidate_slot]
            if slot is not None and slot["active"] and slot["weight"] >= level:
                selected = candidate_slot
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


def trace_record_sha256(record: Record) -> bytes:
    return _sha(
        TRACE_RECORD_DOMAIN,
        _u64(TRACE_ABI),
        *(_u64(record[name]) for name in TRACE_FIELDS),
    )


def _append_trace(
    trace: list[Record],
    *,
    driver_step: int,
    item_ordinal: int,
    event_kind: int,
    rejection_reason: int = REJECTION_NONE,
    terminal_action: int = ACTION_NONE,
    logical_tick_before: int,
    logical_tick_after: int,
    remaining_before: int = 0,
    remaining_after: int = 0,
    wait_quanta: int = 0,
) -> bytes:
    record = {
        "driver_step": driver_step,
        "item_ordinal": item_ordinal,
        "event_kind": event_kind,
        "rejection_reason": rejection_reason,
        "terminal_action": terminal_action,
        "logical_tick_before": logical_tick_before,
        "logical_tick_after": logical_tick_after,
        "remaining_before": remaining_before,
        "remaining_after": remaining_after,
        "wait_quanta": wait_quanta,
    }
    root = trace_record_sha256(record)
    trace.append({**record, "record_sha256": root})
    return root


def _nearest_rank(values: list[int], percentile: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    rank = max(math.ceil(percentile * len(ordered) / 100), 1)
    return ordered[rank - 1]


def replay_scenario(scenario_value: Record) -> Record:
    """Independently replay one bounded explicit-arrival scenario."""

    scenario = validate_scenario(scenario_value)
    items = scenario["items"]
    capacity = scenario["capacity"]
    slots: list[Record | None] = [None] * capacity
    runtime = [
        {
            "state": "pending",
            "admitted_step": ABSENT_STEP,
            "first_service_step": ABSENT_STEP,
            "terminal_step": ABSENT_STEP,
            "served_quanta": 0,
            "fairness_quanta": 0,
            "maximum_wait_quanta": 0,
            "admission_trace_sha256": ZERO_DIGEST,
            "terminal_trace_sha256": ZERO_DIGEST,
            "outcome": None,
            "rejection_reason": REJECTION_NONE,
            "terminal_action": ACTION_NONE,
        }
        for _ in items
    ]
    used = _empty_claim()
    peak = _empty_claim()
    peak_host_bytes = 0
    maximum_live = 0
    successful_commits = 0
    releases = 0
    cursor = 0
    level = 1
    logical_tick = 0
    trace: list[Record] = []
    driver_steps = 0

    def update_peak() -> None:
        nonlocal peak, peak_host_bytes, maximum_live
        peak = {name: max(peak[name], used[name]) for name in CLAIM_FIELDS}
        peak_host_bytes = max(peak_host_bytes, _host_bytes(used))
        maximum_live = max(
            maximum_live,
            sum(slot is not None for slot in slots),
        )

    for step in range(scenario["max_driver_steps"]):
        for index, item in enumerate(items):
            if item["arrival_step"] != step:
                continue
            if runtime[index]["state"] != "pending":
                raise WorkloadPressureError("duplicate arrival")
            if item["deadline_tick"] and item["deadline_tick"] <= logical_tick:
                raise WorkloadPressureError("deadline is not in the future")
            free = next(
                (slot_index for slot_index, slot in enumerate(slots) if slot is None),
                None,
            )
            rejection = REJECTION_NONE
            if any(
                slot is not None and slot["tenant_key"] == item["tenant_key"]
                for slot in slots
            ):
                rejection = REJECTION_DUPLICATE_TENANT
            elif free is None:
                rejection = REJECTION_NO_SLOT
            else:
                next_used = _claim_add(used, item["claim"])
                if not _fits(scenario["limits"], next_used):
                    rejection = REJECTION_RESOURCE_LIMIT
                else:
                    rejection = _projection_rejection(
                        slots,
                        free,
                        item,
                        logical_tick,
                        cursor,
                        level,
                        scenario["max_weight"],
                        scenario["max_projection_quanta"],
                        scenario["max_projection_operations"],
                    )
            if rejection != REJECTION_NONE:
                runtime[index].update(
                    {
                        "state": "terminal",
                        "terminal_step": step,
                        "outcome": OUTCOME_REJECTED,
                        "rejection_reason": rejection,
                    }
                )
                trace_root = _append_trace(
                    trace,
                    driver_step=step,
                    item_ordinal=item["ordinal"],
                    event_kind=EVENT_ADMISSION_REJECTED,
                    rejection_reason=rejection,
                    logical_tick_before=logical_tick,
                    logical_tick_after=logical_tick,
                )
                runtime[index]["admission_trace_sha256"] = trace_root
                runtime[index]["terminal_trace_sha256"] = trace_root
                continue
            assert free is not None
            slots[free] = {
                "item_index": index,
                "tenant_key": item["tenant_key"],
                "weight": item["weight"],
                "remaining": item["work_quanta"],
                "deadline_tick": item["deadline_tick"],
                "admitted_tick": logical_tick,
                "last_service_tick": logical_tick,
                "active": True,
                "claim": item["claim"],
            }
            used = next_used
            successful_commits += 1
            update_peak()
            runtime[index].update(
                {
                    "state": "active",
                    "slot_index": free,
                    "admitted_step": step,
                }
            )
            runtime[index]["admission_trace_sha256"] = _append_trace(
                trace,
                driver_step=step,
                item_ordinal=item["ordinal"],
                event_kind=EVENT_ADMISSION_ACCEPTED,
                logical_tick_before=logical_tick,
                logical_tick_after=logical_tick,
                remaining_after=item["work_quanta"],
            )

        for index, item in enumerate(items):
            if item["terminal_action_step"] != step:
                continue
            state = runtime[index]
            if state["state"] != "active" or item["terminal_action"] == ACTION_NONE:
                raise WorkloadPressureError("terminal action lacks active request")
            slot_index = state["slot_index"]
            slot = slots[slot_index]
            assert slot is not None
            used = _claim_subtract(used, slot["claim"])
            slots[slot_index] = None
            releases += 1
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
                event_kind=EVENT_CANCEL,
                terminal_action=item["terminal_action"],
                logical_tick_before=logical_tick,
                logical_tick_after=logical_tick,
                remaining_before=slot["remaining"],
            )

        if any(slot is not None and slot["active"] for slot in slots):
            selected, cursor, level = _select_iwrr(
                slots, cursor, level, scenario["max_weight"]
            )
            slot = slots[selected]
            assert slot is not None
            index = slot["item_index"]
            item = items[index]
            state = runtime[index]
            before = slot["remaining"]
            after_tick = logical_tick + 1
            wait = after_tick - slot["last_service_tick"]
            slot["remaining"] -= 1
            slot["last_service_tick"] = after_tick
            logical_tick = after_tick
            if state["first_service_step"] == ABSENT_STEP:
                state["first_service_step"] = step
            state["served_quanta"] += 1
            state["maximum_wait_quanta"] = max(state["maximum_wait_quanta"], wait)
            if (
                item["fairness_member"]
                and scenario["fairness_start_tick"]
                < logical_tick
                <= scenario["fairness_end_tick"]
            ):
                state["fairness_quanta"] += 1
            _append_trace(
                trace,
                driver_step=step,
                item_ordinal=item["ordinal"],
                event_kind=EVENT_SERVICE,
                logical_tick_before=logical_tick - 1,
                logical_tick_after=logical_tick,
                remaining_before=before,
                remaining_after=slot["remaining"],
                wait_quanta=wait,
            )
            if slot["remaining"] == 0:
                slot["active"] = False
                used = _claim_subtract(used, slot["claim"])
                slots[selected] = None
                releases += 1
                state.update(
                    {
                        "state": "terminal",
                        "terminal_step": step,
                        "outcome": OUTCOME_COMPLETED,
                    }
                )
                state["terminal_trace_sha256"] = _append_trace(
                    trace,
                    driver_step=step,
                    item_ordinal=item["ordinal"],
                    event_kind=EVENT_RETIRE,
                    logical_tick_before=logical_tick,
                    logical_tick_after=logical_tick,
                )

        if all(state["state"] == "terminal" for state in runtime):
            driver_steps = step + 1
            break
    else:
        raise WorkloadPressureError("driver step limit exceeded")

    _append_trace(
        trace,
        driver_step=driver_steps,
        item_ordinal=ABSENT_ITEM,
        event_kind=EVENT_CLOSE,
        logical_tick_before=logical_tick,
        logical_tick_after=logical_tick,
    )

    outcomes: list[Record] = []
    for item, state in zip(items, runtime):
        outcome = state["outcome"]
        if outcome is None:
            raise WorkloadPressureError("incomplete outcome")
        first = state["first_service_step"]
        outcomes.append(
            {
                "ordinal": item["ordinal"],
                "kind": outcome,
                "rejection_reason": state["rejection_reason"],
                "terminal_action": state["terminal_action"],
                "admitted_step": state["admitted_step"],
                "first_service_step": first,
                "terminal_step": state["terminal_step"],
                "served_quanta": state["served_quanta"],
                "maximum_wait_quanta": state["maximum_wait_quanta"],
                "queue_delay_steps": (
                    first - item["arrival_step"]
                    if first != ABSENT_STEP
                    else ABSENT_STEP
                ),
                "completion_delay_steps": (
                    state["terminal_step"] - item["arrival_step"]
                    if outcome == OUTCOME_COMPLETED
                    else ABSENT_STEP
                ),
                "admission_trace_sha256": state["admission_trace_sha256"],
                "terminal_trace_sha256": state["terminal_trace_sha256"],
            }
        )

    queue_delays = [
        outcome["queue_delay_steps"]
        for outcome in outcomes
        if outcome["queue_delay_steps"] != ABSENT_STEP
    ]
    completion_delays = [
        outcome["completion_delay_steps"]
        for outcome in outcomes
        if outcome["completion_delay_steps"] != ABSENT_STEP
    ]
    fairness_error = 0
    for left_index, (left, left_state) in enumerate(zip(items, runtime)):
        if not left["fairness_member"]:
            continue
        for right, right_state in zip(
            items[left_index + 1 :], runtime[left_index + 1 :]
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
    summary = {
        "admitted": sum(outcome["kind"] != OUTCOME_REJECTED for outcome in outcomes),
        "rejected": sum(outcome["kind"] == OUTCOME_REJECTED for outcome in outcomes),
        "completed": sum(outcome["kind"] == OUTCOME_COMPLETED for outcome in outcomes),
        "cancelled": sum(outcome["kind"] == OUTCOME_CANCELLED for outcome in outcomes),
        "timed_out": sum(outcome["kind"] == OUTCOME_TIMED_OUT for outcome in outcomes),
        "service_quanta": sum(outcome["served_quanta"] for outcome in outcomes),
        "driver_steps": driver_steps,
        "final_logical_tick": logical_tick,
        "maximum_live_receipts": maximum_live,
        "peak_host_bytes": peak_host_bytes,
        "maximum_wait_quanta": max(
            outcome["maximum_wait_quanta"] for outcome in outcomes
        ),
        "maximum_service_gap": (capacity - 1) * scenario["max_weight"] + 1,
        "fairness_cross_product_error": fairness_error,
        "queue_delay_p50_steps": _nearest_rank(queue_delays, 50),
        "queue_delay_p95_steps": _nearest_rank(queue_delays, 95),
        "queue_delay_p99_steps": _nearest_rank(queue_delays, 99),
        "queue_delay_max_steps": max(queue_delays, default=0),
        "completion_delay_p50_steps": _nearest_rank(completion_delays, 50),
        "completion_delay_p95_steps": _nearest_rank(completion_delays, 95),
        "completion_delay_p99_steps": _nearest_rank(completion_delays, 99),
        "completion_delay_max_steps": max(completion_delays, default=0),
        "final_active": 0,
        "final_finished": 0,
        "final_active_reservations": 0,
        "final_committed_receipts": 0,
        "successful_commits": successful_commits,
        "releases": releases,
        "bank_cancellations": 0,
        "bank_rejected_capacity": 0,
        "bank_rejected_slots": 0,
        "zero_orphan_ownership": (
            not any(used.values())
            and not any(slot is not None for slot in slots)
            and successful_commits == releases
        ),
        "peak": peak,
    }
    result = {
        "mode": scenario["mode"],
        "scenario_sha256": scenario_sha256(scenario),
        "summary": summary,
        "outcomes": outcomes,
        "trace": trace,
    }
    result["outcome_sha256"] = outcome_sha256(outcomes)
    result["trace_sha256"] = trace_sha256(trace)
    result["summary_sha256"] = summary_sha256(summary)
    _validate_result_structure(result)
    return result


def trace_sha256(trace: list[Record]) -> bytes:
    if not 0 < len(trace) <= MAXIMUM_TRACE_RECORDS:
        raise WorkloadPressureError("invalid trace count")
    parts = [_u64(TRACE_ABI), _u64(len(trace))]
    for record in trace:
        parts.extend(_u64(record[name]) for name in TRACE_FIELDS)
        parts.append(_digest(record["record_sha256"]))
    return _sha(TRACE_DOMAIN, *parts)


def outcome_sha256(outcomes: list[Record]) -> bytes:
    if not 0 < len(outcomes) <= MAXIMUM_ITEMS:
        raise WorkloadPressureError("invalid outcome count")
    parts = [_u64(RESULT_ABI), _u64(len(outcomes))]
    for outcome in outcomes:
        parts.extend(_u64(outcome[name]) for name in OUTCOME_FIELDS)
        parts.append(_digest(outcome["admission_trace_sha256"]))
        parts.append(_digest(outcome["terminal_trace_sha256"]))
    return _sha(OUTCOME_DOMAIN, *parts)


def summary_sha256(summary: Record) -> bytes:
    if set(summary) != {*SUMMARY_FIELDS, "peak"}:
        raise WorkloadPressureError("invalid summary fields")
    peak_value = summary["peak"]
    if not isinstance(peak_value, dict) or set(peak_value) != set(CLAIM_FIELDS):
        raise WorkloadPressureError("invalid peak claim")
    peak = {name: peak_value[name] for name in CLAIM_FIELDS}
    for amount in peak.values():
        _u64(amount)
    values = []
    for name in SUMMARY_FIELDS:
        value = int(summary[name]) if name == "zero_orphan_ownership" else summary[name]
        values.append(_u64(value))
    return _sha(
        SUMMARY_DOMAIN,
        _u64(SUMMARY_ABI),
        *values,
        *(_u64(peak[name]) for name in CLAIM_FIELDS),
    )


def required_result_bytes(item_count: int, trace_count: int) -> int:
    if not 0 < item_count <= MAXIMUM_ITEMS:
        raise WorkloadPressureError("invalid outcome count")
    if not 0 < trace_count <= MAXIMUM_TRACE_RECORDS:
        raise WorkloadPressureError("invalid trace count")
    return (
        RESULT_HEADER_BYTES
        + item_count * OUTCOME_RECORD_BYTES
        + trace_count * TRACE_RECORD_BYTES
        + RESULT_FOOTER_BYTES
    )


def encode_result(result: Record) -> bytes:
    _validate_result_structure(result)
    outcomes = result["outcomes"]
    trace = result["trace"]
    output = bytearray(required_result_bytes(len(outcomes), len(trace)))
    output[:8] = RESULT_MAGIC
    for index, value in enumerate(
        (
            RESULT_ABI,
            len(output),
            0,
            result["mode"],
            len(outcomes),
            len(trace),
        ),
        start=1,
    ):
        _write_u64(output, index * 8, value)
    for index, name in enumerate(SUMMARY_FIELDS):
        value = (
            int(result["summary"][name])
            if name == "zero_orphan_ownership"
            else result["summary"][name]
        )
        _write_u64(output, 56 + index * 8, value)
    output[312:344] = result["scenario_sha256"]
    output[344:376] = result["outcome_sha256"]
    output[376:408] = result["trace_sha256"]
    output[408:440] = result["summary_sha256"]
    for index, name in enumerate(CLAIM_FIELDS):
        _write_u64(output, 440 + index * 8, result["summary"]["peak"][name])
    offset = RESULT_HEADER_BYTES
    for outcome in outcomes:
        for index, name in enumerate(OUTCOME_FIELDS):
            _write_u64(output, offset + index * 8, outcome[name])
        output[offset + 88 : offset + 120] = outcome["admission_trace_sha256"]
        output[offset + 120 : offset + 152] = outcome["terminal_trace_sha256"]
        offset += OUTCOME_RECORD_BYTES
    for record in trace:
        for index, name in enumerate(TRACE_FIELDS):
            _write_u64(output, offset + index * 8, record[name])
        output[offset + 80 : offset + 112] = record["record_sha256"]
        offset += TRACE_RECORD_BYTES
    output[-32:] = _sha(RESULT_DOMAIN, bytes(output[:-32]))
    return bytes(output)


def decode_result(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < RESULT_HEADER_BYTES + 32
        or encoded[:8] != RESULT_MAGIC
        or _read_u64(encoded, 8) != RESULT_ABI
        or _read_u64(encoded, 16) != len(encoded)
        or _read_u64(encoded, 24) != 0
        or encoded[304:312] != bytes(8)
        or encoded[520:544] != bytes(24)
        or encoded[-32:] != _sha(RESULT_DOMAIN, encoded[:-32])
    ):
        raise WorkloadPressureError("invalid result wire")
    outcome_count = _read_u64(encoded, 40)
    trace_count = _read_u64(encoded, 48)
    if len(encoded) != required_result_bytes(outcome_count, trace_count):
        raise WorkloadPressureError("invalid result length")
    summary = {
        name: _read_u64(encoded, 56 + index * 8)
        for index, name in enumerate(SUMMARY_FIELDS)
    }
    if summary["zero_orphan_ownership"] not in (0, 1):
        raise WorkloadPressureError("invalid zero-orphan marker")
    summary["zero_orphan_ownership"] = bool(summary["zero_orphan_ownership"])
    summary["peak"] = {
        name: _read_u64(encoded, 440 + index * 8)
        for index, name in enumerate(CLAIM_FIELDS)
    }
    offset = RESULT_HEADER_BYTES
    outcomes: list[Record] = []
    for _ in range(outcome_count):
        if encoded[offset + 152 : offset + 160] != bytes(8):
            raise WorkloadPressureError("nonzero outcome reserved bytes")
        outcome = {
            name: _read_u64(encoded, offset + index * 8)
            for index, name in enumerate(OUTCOME_FIELDS)
        }
        outcome["admission_trace_sha256"] = encoded[offset + 88 : offset + 120]
        outcome["terminal_trace_sha256"] = encoded[offset + 120 : offset + 152]
        outcomes.append(outcome)
        offset += OUTCOME_RECORD_BYTES
    trace: list[Record] = []
    for _ in range(trace_count):
        record = {
            name: _read_u64(encoded, offset + index * 8)
            for index, name in enumerate(TRACE_FIELDS)
        }
        record["record_sha256"] = encoded[offset + 80 : offset + 112]
        trace.append(record)
        offset += TRACE_RECORD_BYTES
    result = {
        "mode": _read_u64(encoded, 32),
        "scenario_sha256": encoded[312:344],
        "outcome_sha256": encoded[344:376],
        "trace_sha256": encoded[376:408],
        "summary_sha256": encoded[408:440],
        "summary": summary,
        "outcomes": outcomes,
        "trace": trace,
    }
    _validate_result_structure(result)
    return result


def _validate_result_structure(result: Record) -> None:
    required = {
        "mode",
        "scenario_sha256",
        "outcome_sha256",
        "trace_sha256",
        "summary_sha256",
        "summary",
        "outcomes",
        "trace",
    }
    if not isinstance(result, dict) or set(result) != required:
        raise WorkloadPressureError("invalid result fields")
    if result["mode"] != MODE_OPEN_LOOP:
        raise WorkloadPressureError("invalid result mode")
    for name in (
        "scenario_sha256",
        "outcome_sha256",
        "trace_sha256",
        "summary_sha256",
    ):
        _digest(result[name])
    if (
        not isinstance(result["outcomes"], list)
        or not 0 < len(result["outcomes"]) <= MAXIMUM_ITEMS
    ):
        raise WorkloadPressureError("invalid outcome count")
    if (
        not isinstance(result["trace"], list)
        or not 0 < len(result["trace"]) <= MAXIMUM_TRACE_RECORDS
    ):
        raise WorkloadPressureError("invalid trace count")
    if result["outcome_sha256"] != outcome_sha256(result["outcomes"]):
        raise WorkloadPressureError("invalid outcome root")
    if result["trace_sha256"] != trace_sha256(result["trace"]):
        raise WorkloadPressureError("invalid trace root")
    if result["summary_sha256"] != summary_sha256(result["summary"]):
        raise WorkloadPressureError("invalid summary root")
    if (
        not result["summary"]["zero_orphan_ownership"]
        or result["summary"]["final_active"]
        or result["summary"]["final_finished"]
        or result["summary"]["final_active_reservations"]
        or result["summary"]["final_committed_receipts"]
        or result["summary"]["maximum_wait_quanta"]
        > result["summary"]["maximum_service_gap"]
    ):
        raise WorkloadPressureError("invalid final accounting")
    for index, outcome in enumerate(result["outcomes"]):
        if not isinstance(outcome, dict) or set(outcome) != {
            *OUTCOME_FIELDS,
            "admission_trace_sha256",
            "terminal_trace_sha256",
        }:
            raise WorkloadPressureError("invalid outcome fields")
        for name in OUTCOME_FIELDS:
            _u64(outcome[name])
        if outcome["ordinal"] != index:
            raise WorkloadPressureError("noncanonical outcome order")
        if (
            outcome["kind"]
            not in (
                OUTCOME_COMPLETED,
                OUTCOME_REJECTED,
                OUTCOME_CANCELLED,
                OUTCOME_TIMED_OUT,
            )
            or outcome["rejection_reason"]
            not in (
                REJECTION_NONE,
                REJECTION_NO_SLOT,
                REJECTION_DUPLICATE_TENANT,
                REJECTION_RESOURCE_LIMIT,
                REJECTION_PROJECTION_LIMIT,
                REJECTION_DEADLINE_INFEASIBLE,
            )
            or outcome["terminal_action"]
            not in (ACTION_NONE, ACTION_CANCEL, ACTION_TIMEOUT)
        ):
            raise WorkloadPressureError("invalid outcome enum")
        _digest(outcome["admission_trace_sha256"])
        _digest(outcome["terminal_trace_sha256"])
    previous_step = 0
    for index, record in enumerate(result["trace"]):
        if not isinstance(record, dict) or set(record) != {
            *TRACE_FIELDS,
            "record_sha256",
        }:
            raise WorkloadPressureError("invalid trace fields")
        for name in TRACE_FIELDS:
            _u64(record[name])
        if (
            record["event_kind"]
            not in (
                EVENT_ADMISSION_ACCEPTED,
                EVENT_ADMISSION_REJECTED,
                EVENT_SERVICE,
                EVENT_CANCEL,
                EVENT_RETIRE,
                EVENT_CLOSE,
            )
            or record["rejection_reason"]
            not in (
                REJECTION_NONE,
                REJECTION_NO_SLOT,
                REJECTION_DUPLICATE_TENANT,
                REJECTION_RESOURCE_LIMIT,
                REJECTION_PROJECTION_LIMIT,
                REJECTION_DEADLINE_INFEASIBLE,
            )
            or record["terminal_action"]
            not in (ACTION_NONE, ACTION_CANCEL, ACTION_TIMEOUT)
        ):
            raise WorkloadPressureError("invalid trace enum")
        if (
            record["event_kind"] == EVENT_CLOSE
            and (
                index != len(result["trace"]) - 1
                or record["item_ordinal"] != ABSENT_ITEM
            )
        ) or (
            record["event_kind"] != EVENT_CLOSE
            and record["item_ordinal"] >= len(result["outcomes"])
        ):
            raise WorkloadPressureError("invalid trace item")
        if index and record["driver_step"] < previous_step:
            raise WorkloadPressureError("trace steps are reordered")
        previous_step = record["driver_step"]
        if record["record_sha256"] != trace_record_sha256(record):
            raise WorkloadPressureError("invalid trace record root")
    terminal = result["trace"][-1]
    if terminal["event_kind"] != EVENT_CLOSE or terminal["item_ordinal"] != ABSENT_ITEM:
        raise WorkloadPressureError("missing terminal close event")
    for outcome in result["outcomes"]:
        admission_root: bytes | None = None
        terminal_root: bytes | None = None
        for record in result["trace"]:
            if record["item_ordinal"] != outcome["ordinal"]:
                continue
            if record["event_kind"] == EVENT_ADMISSION_ACCEPTED:
                if admission_root is not None:
                    raise WorkloadPressureError("duplicate admission trace")
                admission_root = record["record_sha256"]
            elif record["event_kind"] == EVENT_ADMISSION_REJECTED:
                if admission_root is not None or terminal_root is not None:
                    raise WorkloadPressureError("duplicate rejection trace")
                admission_root = record["record_sha256"]
                terminal_root = record["record_sha256"]
            elif record["event_kind"] in (EVENT_CANCEL, EVENT_RETIRE):
                if terminal_root is not None:
                    raise WorkloadPressureError("duplicate terminal trace")
                terminal_root = record["record_sha256"]
            elif record["event_kind"] == EVENT_CLOSE:
                raise WorkloadPressureError("item-scoped close trace")
        if (
            admission_root is None
            or terminal_root is None
            or outcome["admission_trace_sha256"] != admission_root
            or outcome["terminal_trace_sha256"] != terminal_root
        ):
            raise WorkloadPressureError("outcome trace reference mismatch")


def validate_result(scenario_value: Record, result: Record) -> Record:
    """Recompute all logical outcomes and summaries from the scenario."""

    scenario = validate_scenario(scenario_value)
    _validate_result_structure(result)
    if result["scenario_sha256"] != scenario_sha256(scenario):
        raise WorkloadPressureError("foreign scenario result")
    expected = replay_scenario(scenario)
    if result != expected:
        raise WorkloadPressureError("result contradicts independent replay")
    return result
