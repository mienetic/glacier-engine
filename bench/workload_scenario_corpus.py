"""Independent W2 generated-workload corpus and shrink oracle.

Generator V1 emits unchanged WorkloadPressure V1 scenarios. Decisions are
coordinate-addressed SHA-256 values rather than draws from mutable random
state, so adding one future decision cannot perturb an unrelated field.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from copy import deepcopy
from enum import IntEnum
from pathlib import Path
from typing import Any, Callable

from bench import scheduled_media_pressure as scheduled
from bench import workload_pressure as workload

Record = dict[str, Any]


class WorkloadScenarioCorpusError(ValueError):
    """The generator, corpus, shrink request, or retained report is invalid."""


GENERATOR_ABI = 0x4757434700000001
SHRINKER_ABI = 0x4757435300000001
CORPUS_ABI = 0x4757434300000001
COVERAGE_ABI = 0x4757435600000001
FAILURE_ABI = 0x4757434600000001

SCHEMA = "glacier.workload-scenario-corpus/v1"
SYNTHETIC_LABEL = "synthetic_shrinker_conformance"

RETAINED_SEEDS = (
    0x4757433220260001,
    0x4757433220260002,
    0x4757433220260003,
    0x4757433220260004,
)
CLASSES_PER_SEED = 8
RETAINED_CASE_COUNT = len(RETAINED_SEEDS) * CLASSES_PER_SEED

DECISION_DOMAIN = b"glacier-workload-scenario-corpus-decision-v1\x00"
CASE_DOMAIN = b"glacier-workload-scenario-case-v1\x00"
CORPUS_DOMAIN = b"glacier-workload-scenario-corpus-v1\x00"
FAILURE_DOMAIN = b"glacier-workload-failure-signature-v1\x00"
SYNTHETIC_FAILURE_DOMAIN = b"glacier-workload-synthetic-turnover-v1\x00"

U64_MAX = (1 << 64) - 1
SCENARIO_ORDINAL = U64_MAX
ZERO_DIGEST = bytes(32)
MAXIMUM_SHRINK_EVALUATIONS = 4096


class ScenarioClass(IntEnum):
    FAIRNESS = 1
    NO_SLOT = 2
    RESOURCE_LIMIT = 3
    CANCEL_TURNOVER = 4
    TIMEOUT_TURNOVER = 5
    DEADLINE_FEASIBLE = 6
    DEADLINE_INFEASIBLE = 7
    PROJECTION_LIMIT = 8


class DecisionTag(IntEnum):
    SCENARIO_SEED = 1
    BANK_EPOCH = 2
    SCHEDULER_EPOCH = 3
    CHALLENGE = 4
    MODALITY_ROTATION = 5


class CoverageBit(IntEnum):
    COMPLETED = 0
    CANCELLED = 1
    TIMED_OUT = 2
    NO_SLOT = 3
    RESOURCE_LIMIT = 4
    PROJECTION_LIMIT = 5
    DEADLINE_INFEASIBLE = 6
    IMAGE = 7
    AUDIO = 8
    VIDEO = 9
    DEADLINE_COMPLETED = 10
    WEIGHTED_FAIRNESS = 11
    STAGGERED = 12
    TERMINAL_AFTER_SERVICE = 13
    ZERO_ORPHAN = 14


class FailureStage(IntEnum):
    SYNTHETIC_SHRINKER_CONFORMANCE = 1
    SCENARIO_GENERATION = 2
    SCENARIO_WIRE = 3
    WORKLOAD_REPLAY = 4
    RESULT_MISMATCH = 5
    SCHEDULED_MEDIA_MISMATCH = 6
    INVARIANT_VIOLATION = 7


MANDATORY_COVERAGE = (1 << len(CoverageBit)) - 1

CASE_CLASS_NAMES = {
    ScenarioClass.FAIRNESS: "fairness",
    ScenarioClass.NO_SLOT: "no_slot",
    ScenarioClass.RESOURCE_LIMIT: "resource_limit",
    ScenarioClass.CANCEL_TURNOVER: "cancel_turnover",
    ScenarioClass.TIMEOUT_TURNOVER: "timeout_turnover",
    ScenarioClass.DEADLINE_FEASIBLE: "deadline_feasible",
    ScenarioClass.DEADLINE_INFEASIBLE: "deadline_infeasible",
    ScenarioClass.PROJECTION_LIMIT: "projection_limit",
}
_CASE_CLASS_BY_NAME = {
    name: scenario_class
    for scenario_class, name in CASE_CLASS_NAMES.items()
}


def _u64(value: int) -> bytes:
    if isinstance(value, bool) or not isinstance(value, int):
        raise WorkloadScenarioCorpusError("expected u64")
    if not 0 <= value <= U64_MAX:
        raise WorkloadScenarioCorpusError("u64 out of range")
    return value.to_bytes(8, "little")


def _sha(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _nonzero(value: int) -> int:
    return value if value != 0 else 1


def decision(
    seed: int,
    case_index: int,
    scenario_class: ScenarioClass | int,
    tag: DecisionTag | int,
    ordinal: int = SCENARIO_ORDINAL,
) -> bytes:
    """Return one Generator-v1 decision digest for an exact address."""

    try:
        class_value = ScenarioClass(scenario_class)
        tag_value = DecisionTag(tag)
    except ValueError as error:
        raise WorkloadScenarioCorpusError("unsupported decision address") from error
    return _sha(
        DECISION_DOMAIN,
        _u64(GENERATOR_ABI),
        _u64(seed),
        _u64(case_index),
        _u64(class_value),
        _u64(tag_value),
        _u64(ordinal),
    )


def decision_u64(
    seed: int,
    case_index: int,
    scenario_class: ScenarioClass | int,
    tag: DecisionTag | int,
    ordinal: int = SCENARIO_ORDINAL,
) -> int:
    return int.from_bytes(
        decision(seed, case_index, scenario_class, tag, ordinal)[:8],
        "little",
    )


def _profile(kind: int) -> Record:
    if kind == workload.MEDIA_IMAGE:
        family, claim = workload.FAMILY_VISION_UNDERSTANDING, workload.image_claim()
    elif kind == workload.MEDIA_AUDIO:
        family, claim = workload.FAMILY_AUDIO_UNDERSTANDING, workload.audio_claim()
    elif kind == workload.MEDIA_VIDEO:
        family, claim = workload.FAMILY_VIDEO_UNDERSTANDING, workload.video_claim()
    else:
        raise WorkloadScenarioCorpusError("unsupported generated media kind")
    profile_root = _sha(
        workload.PROFILE_DOMAIN,
        _u64(workload.PROFILE_ABI),
        _u64(kind),
        _u64(family),
        _u64(workload.OPERATION_ENCODE),
        *(_u64(claim[name]) for name in workload.CLAIM_FIELDS),
    )
    return {
        "family": family,
        "operation": workload.OPERATION_ENCODE,
        "media_kind": kind,
        "claim": claim,
        "profile_sha256": profile_root,
    }


def _host_bytes(claim: Record) -> int:
    return sum(claim[name] for name in workload.HOST_CLAIM_FIELDS)


def _item(
    *,
    case_index: int,
    ordinal: int,
    kind: int,
    arrival_step: int,
    weight: int,
    work_quanta: int,
    deadline_tick: int = 0,
    terminal_action_step: int = workload.ABSENT_STEP,
    terminal_action: int = workload.ACTION_NONE,
) -> Record:
    identity = 1 + case_index * workload.MAXIMUM_ITEMS + ordinal
    if identity >= 1 << 60:
        raise WorkloadScenarioCorpusError("generated identity out of range")
    return {
        "ordinal": ordinal,
        **_profile(kind),
        "arrival_step": arrival_step,
        "weight": weight,
        "work_quanta": work_quanta,
        "deadline_tick": deadline_tick,
        "terminal_action_step": terminal_action_step,
        "terminal_action": terminal_action,
        "fairness_member": True,
        "tenant_key": 0x1000000000000000 | identity,
        "request_key": 0x2000000000000000 | identity,
        "request_generation": 1,
        "resource_owner_key": 0x3000000000000000 | identity,
    }


def _template(
    scenario_class: ScenarioClass,
) -> tuple[
    list[int],
    list[int],
    list[int],
    int,
    list[int],
    list[int],
    list[int],
    int,
    int,
]:
    absent = workload.ABSENT_STEP
    none = workload.ACTION_NONE
    if scenario_class == ScenarioClass.FAIRNESS:
        return (
            [0, 0, 0],
            [1, 2, 4],
            [4, 4, 4],
            3,
            [0, 0, 0],
            [absent] * 3,
            [none] * 3,
            7,
            4096,
        )
    if scenario_class == ScenarioClass.NO_SLOT:
        return (
            [0, 0, 0, 0],
            [1, 2, 1, 2],
            [2, 2, 2, 2],
            2,
            [0] * 4,
            [absent] * 4,
            [none] * 4,
            8,
            4096,
        )
    if scenario_class == ScenarioClass.RESOURCE_LIMIT:
        return (
            [0, 0, 0],
            [1, 1, 1],
            [2, 2, 2],
            2,
            [0, 0, 0],
            [absent] * 3,
            [none] * 3,
            8,
            4096,
        )
    if scenario_class == ScenarioClass.CANCEL_TURNOVER:
        return (
            [0, 2],
            [1, 1],
            [4, 2],
            1,
            [0, 0],
            [1, absent],
            [workload.ACTION_CANCEL, none],
            8,
            4096,
        )
    if scenario_class == ScenarioClass.TIMEOUT_TURNOVER:
        return (
            [0, 3],
            [1, 1],
            [4, 2],
            1,
            [0, 0],
            [2, absent],
            [workload.ACTION_TIMEOUT, none],
            8,
            4096,
        )
    if scenario_class == ScenarioClass.DEADLINE_FEASIBLE:
        return (
            [0, 3],
            [1, 1],
            [3, 2],
            1,
            [3, 5],
            [absent, absent],
            [none, none],
            8,
            4096,
        )
    if scenario_class == ScenarioClass.DEADLINE_INFEASIBLE:
        return (
            [0, 1],
            [1, 1],
            [3, 1],
            1,
            [2, 0],
            [absent, absent],
            [none, none],
            8,
            4096,
        )
    if scenario_class == ScenarioClass.PROJECTION_LIMIT:
        return (
            [0, 0],
            [1, 1],
            [2, 2],
            2,
            [8, 8],
            [absent, absent],
            [none, none],
            8,
            1,
        )
    raise WorkloadScenarioCorpusError("unsupported scenario class")


def generate_case(
    seed: int,
    case_index: int,
    scenario_class: ScenarioClass | int,
) -> Record:
    """Generate one canonical unchanged WorkloadPressure V1 scenario."""

    try:
        scenario_class = ScenarioClass(scenario_class)
    except ValueError as error:
        raise WorkloadScenarioCorpusError("unsupported scenario class") from error
    if seed == 0 or not 0 <= case_index < 64:
        raise WorkloadScenarioCorpusError("case identity out of range")
    (
        arrivals,
        weights,
        work,
        capacity,
        deadlines,
        action_steps,
        actions,
        fairness_end,
        projection_operations,
    ) = _template(scenario_class)
    rotation = (
        decision_u64(
            seed,
            case_index,
            scenario_class,
            DecisionTag.MODALITY_ROTATION,
        )
        % 3
    )
    items = [
        _item(
            case_index=case_index,
            ordinal=ordinal,
            kind=1 + (rotation + ordinal) % 3,
            arrival_step=arrivals[ordinal],
            weight=weights[ordinal],
            work_quanta=work[ordinal],
            deadline_tick=deadlines[ordinal],
            terminal_action_step=action_steps[ordinal],
            terminal_action=actions[ordinal],
        )
        for ordinal in range(len(arrivals))
    ]
    limits = {name: U64_MAX for name in workload.LIMIT_FIELDS}
    limits["queue_slots"] = capacity
    if scenario_class == ScenarioClass.RESOURCE_LIMIT:
        limits["host_bytes"] = _host_bytes(items[0]["claim"])
    elif scenario_class == ScenarioClass.NO_SLOT:
        limits["host_bytes"] = sum(
            _host_bytes(item["claim"]) for item in items[:capacity]
        )
    elif capacity == 1:
        limits["host_bytes"] = max(_host_bytes(item["claim"]) for item in items)
    else:
        limits["host_bytes"] = sum(_host_bytes(item["claim"]) for item in items)
    challenge = decision(
        seed,
        case_index,
        scenario_class,
        DecisionTag.CHALLENGE,
    )
    if challenge == ZERO_DIGEST:
        challenge = b"\x01" + challenge[1:]
    scenario = {
        "mode": workload.MODE_OPEN_LOOP,
        "seed": _nonzero(
            decision_u64(
                seed,
                case_index,
                scenario_class,
                DecisionTag.SCENARIO_SEED,
            )
        ),
        "max_driver_steps": 64,
        "fairness_start_tick": 0,
        "fairness_end_tick": fairness_end,
        "bank_epoch": _nonzero(
            decision_u64(
                seed,
                case_index,
                scenario_class,
                DecisionTag.BANK_EPOCH,
            )
        ),
        "scheduler_epoch": _nonzero(
            decision_u64(
                seed,
                case_index,
                scenario_class,
                DecisionTag.SCHEDULER_EPOCH,
            )
        ),
        "max_weight": 4,
        "max_projection_quanta": 256,
        "max_projection_operations": projection_operations,
        "capacity": capacity,
        "limits": limits,
        "challenge": challenge,
        "items": items,
    }
    return workload.validate_scenario(scenario)


def generate_scenario(seed_index: int, class_index: int) -> Record:
    """Generate one case from the retained four-by-eight corpus."""

    if not 0 <= seed_index < len(RETAINED_SEEDS):
        raise WorkloadScenarioCorpusError("seed index out of range")
    if not 0 <= class_index < CLASSES_PER_SEED:
        raise WorkloadScenarioCorpusError("class index out of range")
    case_index = seed_index * CLASSES_PER_SEED + class_index
    return generate_case(
        RETAINED_SEEDS[seed_index],
        case_index,
        ScenarioClass(class_index + 1),
    )


def coverage_bits(scenario: Record, result: Record) -> int:
    """Derive the exact Coverage-v1 bitset for one replayed case."""

    scenario = workload.validate_scenario(scenario)
    result = workload.validate_result(scenario, result)
    bits = 0

    def cover(bit: CoverageBit) -> None:
        nonlocal bits
        bits |= 1 << bit

    for item in scenario["items"]:
        if item["media_kind"] == workload.MEDIA_IMAGE:
            cover(CoverageBit.IMAGE)
        elif item["media_kind"] == workload.MEDIA_AUDIO:
            cover(CoverageBit.AUDIO)
        elif item["media_kind"] == workload.MEDIA_VIDEO:
            cover(CoverageBit.VIDEO)
    for item, outcome in zip(scenario["items"], result["outcomes"]):
        if outcome["kind"] == workload.OUTCOME_COMPLETED:
            cover(CoverageBit.COMPLETED)
            if item["deadline_tick"] != 0:
                cover(CoverageBit.DEADLINE_COMPLETED)
        elif outcome["kind"] == workload.OUTCOME_CANCELLED:
            cover(CoverageBit.CANCELLED)
        elif outcome["kind"] == workload.OUTCOME_TIMED_OUT:
            cover(CoverageBit.TIMED_OUT)
        if outcome["rejection_reason"] == workload.REJECTION_NO_SLOT:
            cover(CoverageBit.NO_SLOT)
        elif outcome["rejection_reason"] == workload.REJECTION_RESOURCE_LIMIT:
            cover(CoverageBit.RESOURCE_LIMIT)
        elif outcome["rejection_reason"] == workload.REJECTION_PROJECTION_LIMIT:
            cover(CoverageBit.PROJECTION_LIMIT)
        elif outcome["rejection_reason"] == workload.REJECTION_DEADLINE_INFEASIBLE:
            cover(CoverageBit.DEADLINE_INFEASIBLE)
        if (
            outcome["kind"]
            in (workload.OUTCOME_CANCELLED, workload.OUTCOME_TIMED_OUT)
            and outcome["served_quanta"] != 0
        ):
            cover(CoverageBit.TERMINAL_AFTER_SERVICE)
    fairness_weights = {
        item["weight"] for item in scenario["items"] if item["fairness_member"]
    }
    if (
        len(fairness_weights) >= 2
        and result["summary"]["fairness_cross_product_error"] == 0
    ):
        cover(CoverageBit.WEIGHTED_FAIRNESS)
    if len({item["arrival_step"] for item in scenario["items"]}) >= 2:
        cover(CoverageBit.STAGGERED)
    if result["summary"]["zero_orphan_ownership"]:
        cover(CoverageBit.ZERO_ORPHAN)
    return bits


def _case_root(
    *,
    seed: int,
    case_index: int,
    scenario_class: ScenarioClass,
    coverage: int,
    summary: Record,
    scenario_sha256: bytes,
    outcome_sha256: bytes,
    trace_sha256: bytes,
    summary_sha256: bytes,
    scheduled_evidence_sha256: bytes,
) -> bytes:
    return _sha(
        CASE_DOMAIN,
        *(
            _u64(value)
            for value in (
                CORPUS_ABI,
                GENERATOR_ABI,
                COVERAGE_ABI,
                seed,
                case_index,
                scenario_class,
                coverage,
                summary["item_count"],
                summary["admitted"],
                summary["rejected"],
                summary["completed"],
                summary["cancelled"],
                summary["timed_out"],
                summary["service_quanta"],
                summary["driver_steps"],
                summary["publications"],
                summary["closed_terminal_sessions"],
                int(summary["zero_orphan_ownership"]),
            )
        ),
        scenario_sha256,
        outcome_sha256,
        trace_sha256,
        summary_sha256,
        scheduled_evidence_sha256,
    )


def build_case(seed_index: int, class_index: int) -> Record:
    """Generate and independently verify one retained W0/W1 case."""

    scenario = generate_scenario(seed_index, class_index)
    result = workload.replay_scenario(scenario)
    workload.validate_result(scenario, result)
    evidence = scheduled.build_evidence(scenario)
    scheduled.validate_evidence(scenario, evidence)
    scenario_class = ScenarioClass(class_index + 1)
    seed = RETAINED_SEEDS[seed_index]
    case_index = seed_index * CLASSES_PER_SEED + class_index
    coverage = coverage_bits(scenario, result)
    summary = {
        "item_count": len(scenario["items"]),
        "admitted": result["summary"]["admitted"],
        "rejected": result["summary"]["rejected"],
        "completed": result["summary"]["completed"],
        "cancelled": result["summary"]["cancelled"],
        "timed_out": result["summary"]["timed_out"],
        "service_quanta": result["summary"]["service_quanta"],
        "driver_steps": result["summary"]["driver_steps"],
        "publications": evidence["summary"]["publications"],
        "closed_terminal_sessions": evidence["summary"][
            "closed_terminal_sessions"
        ],
        "zero_orphan_ownership": bool(
            result["summary"]["zero_orphan_ownership"]
            and evidence["summary"]["zero_orphan_ownership"]
        ),
    }
    roots = {
        "scenario_sha256": workload.scenario_sha256(scenario),
        "outcome_sha256": result["outcome_sha256"],
        "trace_sha256": result["trace_sha256"],
        "summary_sha256": result["summary_sha256"],
        "scheduled_evidence_sha256": evidence["evidence_sha256"],
    }
    case_sha256 = _case_root(
        seed=seed,
        case_index=case_index,
        scenario_class=scenario_class,
        coverage=coverage,
        summary=summary,
        **roots,
    )
    return {
        "case_index": case_index,
        "seed_index": seed_index,
        "generator_seed": f"{seed:016x}",
        "class": CASE_CLASS_NAMES[scenario_class],
        "item_count": summary["item_count"],
        "coverage_bits": f"{coverage:016x}",
        "admitted": summary["admitted"],
        "rejected": summary["rejected"],
        "completed": summary["completed"],
        "cancelled": summary["cancelled"],
        "timed_out": summary["timed_out"],
        "service_quanta": summary["service_quanta"],
        "driver_steps": summary["driver_steps"],
        "publications": summary["publications"],
        "closed_terminal_sessions": summary["closed_terminal_sessions"],
        "zero_orphan_ownership": summary["zero_orphan_ownership"],
        **{name: root.hex() for name, root in roots.items()},
        "case_sha256": case_sha256.hex(),
    }


def _hex_u64(value: Any) -> int:
    if not isinstance(value, str) or len(value) != 16:
        raise WorkloadScenarioCorpusError("invalid report u64")
    try:
        decoded = int(value, 16)
    except ValueError as error:
        raise WorkloadScenarioCorpusError("invalid report u64") from error
    if f"{decoded:016x}" != value:
        raise WorkloadScenarioCorpusError("invalid report u64")
    return decoded


def _hex_digest(value: Any) -> bytes:
    if not isinstance(value, str) or len(value) != 64:
        raise WorkloadScenarioCorpusError("invalid report digest")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise WorkloadScenarioCorpusError("invalid report digest") from error
    if decoded.hex() != value:
        raise WorkloadScenarioCorpusError("invalid report digest")
    return decoded


def _case_root_from_record(case: Record) -> bytes:
    """Recompute a child root from bound metadata, never its cached root."""

    try:
        scenario_class = _CASE_CLASS_BY_NAME[case["class"]]
        zero_orphan_ownership = case["zero_orphan_ownership"]
        if not isinstance(zero_orphan_ownership, bool):
            raise WorkloadScenarioCorpusError(
                "invalid zero-orphan ownership flag",
            )
        summary = {
            field: case[field]
            for field in (
                "item_count",
                "admitted",
                "rejected",
                "completed",
                "cancelled",
                "timed_out",
                "service_quanta",
                "driver_steps",
                "publications",
                "closed_terminal_sessions",
            )
        }
        summary["zero_orphan_ownership"] = zero_orphan_ownership
        return _case_root(
            seed=_hex_u64(case["generator_seed"]),
            case_index=case["case_index"],
            scenario_class=scenario_class,
            coverage=_hex_u64(case["coverage_bits"]),
            summary=summary,
            scenario_sha256=_hex_digest(case["scenario_sha256"]),
            outcome_sha256=_hex_digest(case["outcome_sha256"]),
            trace_sha256=_hex_digest(case["trace_sha256"]),
            summary_sha256=_hex_digest(case["summary_sha256"]),
            scheduled_evidence_sha256=_hex_digest(
                case["scheduled_evidence_sha256"],
            ),
        )
    except (KeyError, TypeError) as error:
        raise WorkloadScenarioCorpusError(
            "invalid retained case metadata",
        ) from error


def _corpus_root(cases: list[Record], totals: Record, coverage: int) -> bytes:
    return _sha(
        CORPUS_DOMAIN,
        *(
            _u64(value)
            for value in (
                CORPUS_ABI,
                GENERATOR_ABI,
                COVERAGE_ABI,
                len(RETAINED_SEEDS),
                CLASSES_PER_SEED,
                len(cases),
                coverage,
                totals["item_count"],
                totals["admitted"],
                totals["rejected"],
                totals["completed"],
                totals["cancelled"],
                totals["timed_out"],
                totals["service_quanta"],
                totals["driver_steps"],
                totals["publications"],
                totals["closed_terminal_sessions"],
                int(totals["zero_orphan_ownership"]),
            )
        ),
        *(_case_root_from_record(case) for case in cases),
    )


def failure_signature_sha256(signature: Record) -> bytes:
    if not isinstance(signature, dict) or set(signature) != {
        "stage",
        "code",
        "fingerprint",
    }:
        raise WorkloadScenarioCorpusError("invalid failure signature")
    try:
        stage = FailureStage(signature["stage"])
    except ValueError as error:
        raise WorkloadScenarioCorpusError("invalid failure stage") from error
    fingerprint = signature["fingerprint"]
    if not isinstance(fingerprint, bytes) or len(fingerprint) != 32:
        raise WorkloadScenarioCorpusError("invalid failure fingerprint")
    return _sha(
        FAILURE_DOMAIN,
        _u64(FAILURE_ABI),
        _u64(stage),
        _u64(signature["code"]),
        fingerprint,
    )


def complexity(scenario: Record) -> tuple[int, ...]:
    scenario = workload.validate_scenario(scenario)
    terminal_actions = 0
    total_action_distance = 0
    deadline_count = 0
    total_deadline_ticks = 0
    for item in scenario["items"]:
        if item["terminal_action"] != workload.ACTION_NONE:
            terminal_actions += 1
            total_action_distance += (
                item["terminal_action_step"] - item["arrival_step"] + 1
            )
        if item["deadline_tick"] != 0:
            deadline_count += 1
            total_deadline_ticks += item["deadline_tick"]
    return (
        len(scenario["items"]),
        terminal_actions,
        sum(item["work_quanta"] for item in scenario["items"]),
        sum(item["arrival_step"] for item in scenario["items"]),
        total_action_distance,
        deadline_count,
        total_deadline_ticks,
        sum(item["weight"] for item in scenario["items"]),
        sum(item["media_kind"] for item in scenario["items"]),
        scenario["capacity"],
        scenario["limits"]["host_bytes"],
        scenario["max_driver_steps"],
        scenario["max_projection_operations"],
        scenario["fairness_end_tick"],
    )


FailureProbe = Callable[[Record, Record], Record | None]


class _ShrinkContext:
    def __init__(
        self,
        expected: Record,
        probe: FailureProbe,
        evaluation_budget: int,
    ) -> None:
        self.expected = expected
        self.probe = probe
        self.evaluation_budget = evaluation_budget
        self.evaluations = 0

    def observe(self, candidate: Record) -> tuple[str, Record | None]:
        try:
            scenario = workload.validate_scenario(candidate)
            result = workload.replay_scenario(scenario)
            workload.validate_result(scenario, result)
        except ValueError:
            return "invalid", None
        if self.evaluations + 2 > self.evaluation_budget:
            return "budget", None
        first = self.probe(scenario, result)
        self.evaluations += 1
        second = self.probe(scenario, result)
        self.evaluations += 1
        if first != second:
            raise WorkloadScenarioCorpusError("unstable failure probe")
        if first is None:
            return "absent", None
        failure_signature_sha256(first)
        return "present", first

    def consider(self, current: Record, candidate: Record) -> tuple[str, Record]:
        try:
            if not complexity(candidate) < complexity(current):
                return "rejected", current
        except ValueError:
            return "rejected", current
        observation, signature = self.observe(candidate)
        if observation == "budget":
            return "budget", current
        if observation != "present" or signature != self.expected:
            return "rejected", current
        return "accepted", workload.validate_scenario(candidate)


def _with_kind(item: Record, kind: int) -> Record:
    changed = deepcopy(item)
    profile = _profile(kind)
    changed.update(profile)
    return changed


def _minimum_driver_steps(items: list[Record]) -> int:
    total_work = sum(item["work_quanta"] for item in items)
    latest_arrival = max(item["arrival_step"] for item in items)
    latest_action = max(
        (
            item["terminal_action_step"]
            for item in items
            if item["terminal_action"] != workload.ACTION_NONE
        ),
        default=0,
    )
    return max(latest_arrival + total_work + 1, latest_action + 1)


def _reduce_one_pass(
    current: Record,
    context: _ShrinkContext,
) -> tuple[str, Record]:
    count = len(current["items"])

    if count > 2:
        for remove_index in range(count - 1, -1, -1):
            candidate = deepcopy(current)
            candidate["items"].pop(remove_index)
            for ordinal, item in enumerate(candidate["items"]):
                item["ordinal"] = ordinal
            decision_value, next_value = context.consider(current, candidate)
            if decision_value != "rejected":
                return decision_value, next_value

    for index in range(count):
        if current["items"][index]["terminal_action"] == workload.ACTION_NONE:
            continue
        candidate = deepcopy(current)
        candidate["items"][index]["terminal_action"] = workload.ACTION_NONE
        candidate["items"][index]["terminal_action_step"] = workload.ABSENT_STEP
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    for index in range(count):
        current_work = current["items"][index]["work_quanta"]
        if current_work <= 1:
            continue
        targets = dict.fromkeys(
            (1, max(1, current_work // 2), current_work - 1)
        )
        for target in targets:
            if target >= current_work:
                continue
            candidate = deepcopy(current)
            candidate["items"][index]["work_quanta"] = target
            decision_value, next_value = context.consider(current, candidate)
            if decision_value != "rejected":
                return decision_value, next_value

    for index in range(count):
        current_arrival = current["items"][index]["arrival_step"]
        if current_arrival == 0:
            continue
        previous_arrival = (
            0 if index == 0 else current["items"][index - 1]["arrival_step"]
        )
        for target in dict.fromkeys((previous_arrival, current_arrival - 1)):
            if target >= current_arrival:
                continue
            candidate = deepcopy(current)
            candidate["items"][index]["arrival_step"] = target
            decision_value, next_value = context.consider(current, candidate)
            if decision_value != "rejected":
                return decision_value, next_value

    for index in range(count):
        item = current["items"][index]
        if (
            item["terminal_action"] == workload.ACTION_NONE
            or item["terminal_action_step"] == item["arrival_step"]
        ):
            continue
        candidate = deepcopy(current)
        candidate["items"][index]["terminal_action_step"] = item["arrival_step"]
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    for index in range(count):
        if current["items"][index]["deadline_tick"] == 0:
            continue
        candidate = deepcopy(current)
        candidate["items"][index]["deadline_tick"] = 0
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    for index in range(count):
        if current["items"][index]["weight"] == 1:
            continue
        candidate = deepcopy(current)
        candidate["items"][index]["weight"] = 1
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    for index in range(count):
        if current["items"][index]["media_kind"] == workload.MEDIA_IMAGE:
            continue
        candidate = deepcopy(current)
        candidate["items"][index] = _with_kind(
            candidate["items"][index],
            workload.MEDIA_IMAGE,
        )
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    if current["capacity"] > 1:
        candidate = deepcopy(current)
        candidate["capacity"] = 1
        candidate["limits"]["queue_slots"] = 1
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    minimum_host = max(_host_bytes(item["claim"]) for item in current["items"])
    if minimum_host < current["limits"]["host_bytes"]:
        candidate = deepcopy(current)
        candidate["limits"]["host_bytes"] = minimum_host
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    minimum_steps = _minimum_driver_steps(current["items"])
    if minimum_steps < current["max_driver_steps"]:
        candidate = deepcopy(current)
        candidate["max_driver_steps"] = minimum_steps
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    if current["max_projection_operations"] > 1:
        candidate = deepcopy(current)
        candidate["max_projection_operations"] = 1
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value

    if current["fairness_end_tick"] > 1:
        candidate = deepcopy(current)
        candidate["fairness_end_tick"] = 1
        decision_value, next_value = context.consider(current, candidate)
        if decision_value != "rejected":
            return decision_value, next_value
    return "no_change", current


def shrink_failure(
    initial: Record,
    expected: Record,
    probe: FailureProbe,
    evaluation_budget: int,
) -> Record:
    """Shrink while preserving one exact, stable Failure-v1 signature."""

    if (
        isinstance(evaluation_budget, bool)
        or not 2 <= evaluation_budget <= MAXIMUM_SHRINK_EVALUATIONS
        or evaluation_budget % 2
    ):
        raise WorkloadScenarioCorpusError("invalid evaluation budget")
    current = deepcopy(workload.validate_scenario(initial))
    original_root = workload.scenario_sha256(current)
    failure_signature_sha256(expected)
    context = _ShrinkContext(expected, probe, evaluation_budget)
    observation, signature = context.observe(current)
    if observation in ("invalid", "absent"):
        raise WorkloadScenarioCorpusError("failure is not interesting")
    if observation == "budget":
        raise WorkloadScenarioCorpusError("invalid evaluation budget")
    if signature != expected:
        raise WorkloadScenarioCorpusError("failure signature mismatch")

    reductions = 0
    locally_minimal = False
    while True:
        pass_result, next_value = _reduce_one_pass(current, context)
        if pass_result == "accepted":
            current = next_value
            reductions += 1
        elif pass_result == "budget":
            raise WorkloadScenarioCorpusError("evaluation budget exhausted")
        else:
            locally_minimal = True
            break
    return {
        "scenario": current,
        "original_scenario_sha256": original_root,
        "minimized_scenario_sha256": workload.scenario_sha256(current),
        "failure_signature_sha256": failure_signature_sha256(expected),
        "evaluations": context.evaluations,
        "reductions": reductions,
        "budget_exhausted": False,
        "locally_minimal": locally_minimal,
    }


def synthetic_failure_signature() -> Record:
    return {
        "stage": FailureStage.SYNTHETIC_SHRINKER_CONFORMANCE,
        "code": 1,
        "fingerprint": _sha(SYNTHETIC_FAILURE_DOMAIN),
    }


def synthetic_failure_probe(scenario: Record, result: Record) -> Record | None:
    if (
        len(scenario["items"]) != 2
        or result["summary"]["cancelled"] != 1
        or result["summary"]["completed"] != 1
        or result["summary"]["maximum_live_receipts"] != 1
        or not result["summary"]["zero_orphan_ownership"]
    ):
        return None
    cancel_steps = [
        item["terminal_action_step"]
        for item in scenario["items"]
        if item["terminal_action"] == workload.ACTION_CANCEL
    ]
    if len(cancel_steps) != 1:
        return None
    for item, outcome in zip(scenario["items"], result["outcomes"]):
        if (
            outcome["kind"] == workload.OUTCOME_COMPLETED
            and item["arrival_step"] > cancel_steps[0]
        ):
            return synthetic_failure_signature()
    return None


def run_synthetic_shrink(
    evaluation_budget: int = MAXIMUM_SHRINK_EVALUATIONS,
) -> Record:
    return shrink_failure(
        generate_scenario(0, ScenarioClass.CANCEL_TURNOVER - 1),
        synthetic_failure_signature(),
        synthetic_failure_probe,
        evaluation_budget,
    )


def build_report() -> Record:
    """Recompute the complete retained W2 report from first principles."""

    cases = [
        build_case(seed_index, class_index)
        for seed_index in range(len(RETAINED_SEEDS))
        for class_index in range(CLASSES_PER_SEED)
    ]
    totals = {
        field: sum(case[field] for case in cases)
        for field in (
            "item_count",
            "admitted",
            "rejected",
            "completed",
            "cancelled",
            "timed_out",
            "service_quanta",
            "driver_steps",
            "publications",
            "closed_terminal_sessions",
        )
    }
    totals["zero_orphan_ownership"] = all(
        case["zero_orphan_ownership"] for case in cases
    )
    coverage = 0
    for case in cases:
        coverage |= int(case["coverage_bits"], 16)
    if (
        coverage != MANDATORY_COVERAGE
        or totals
        != {
            "item_count": 80,
            "admitted": 52,
            "rejected": 28,
            "completed": 44,
            "cancelled": 4,
            "timed_out": 4,
            "service_quanta": 124,
            "driver_steps": 140,
            "publications": 44,
            "closed_terminal_sessions": 52,
            "zero_orphan_ownership": True,
        }
    ):
        raise WorkloadScenarioCorpusError("retained corpus coverage drift")
    corpus_sha256 = _corpus_root(cases, totals, coverage)

    original = generate_scenario(0, ScenarioClass.CANCEL_TURNOVER - 1)
    original_complexity = complexity(original)
    shrink = run_synthetic_shrink()
    minimized_complexity = complexity(shrink["scenario"])
    second = shrink_failure(
        shrink["scenario"],
        synthetic_failure_signature(),
        synthetic_failure_probe,
        MAXIMUM_SHRINK_EVALUATIONS,
    )
    idempotent = (
        second["minimized_scenario_sha256"]
        == shrink["minimized_scenario_sha256"]
        and second["reductions"] == 0
        and second["locally_minimal"]
        and not second["budget_exhausted"]
    )
    synthetic = {
        "label": SYNTHETIC_LABEL,
        "shrinker_abi": f"{SHRINKER_ABI:016x}",
        "failure_signature_sha256": shrink["failure_signature_sha256"].hex(),
        "original_scenario_sha256": shrink["original_scenario_sha256"].hex(),
        "minimized_scenario_sha256": shrink["minimized_scenario_sha256"].hex(),
        "original_complexity": list(original_complexity),
        "minimized_complexity": list(minimized_complexity),
        "evaluations": shrink["evaluations"],
        "reductions": shrink["reductions"],
        "budget_exhausted": shrink["budget_exhausted"],
        "locally_minimal": shrink["locally_minimal"],
        "idempotent_scenario_sha256": second[
            "minimized_scenario_sha256"
        ].hex(),
        "idempotent": idempotent,
    }
    if (
        shrink["budget_exhausted"]
        or not shrink["locally_minimal"]
        or not minimized_complexity < original_complexity
        or not idempotent
    ):
        raise WorkloadScenarioCorpusError("synthetic shrink fixture drift")
    return {
        "schema": SCHEMA,
        "generator_abi": f"{GENERATOR_ABI:016x}",
        "shrinker_abi": f"{SHRINKER_ABI:016x}",
        "corpus_abi": f"{CORPUS_ABI:016x}",
        "coverage_abi": f"{COVERAGE_ABI:016x}",
        "failure_abi": f"{FAILURE_ABI:016x}",
        "retained_seed_count": len(RETAINED_SEEDS),
        "class_count": CLASSES_PER_SEED,
        "case_count": len(cases),
        "coverage_bits": f"{coverage:016x}",
        **totals,
        "corpus_sha256": corpus_sha256.hex(),
        "cases": cases,
        "synthetic_shrinker": synthetic,
    }


def render_report(report: Record | None = None) -> str:
    """Render the canonical compact JSON report with one final newline."""

    if report is None:
        report = build_report()
    return json.dumps(report, ensure_ascii=True, separators=(",", ":")) + "\n"


def validate_report(value: Record) -> Record:
    """Require exact equality with an independent retained-corpus replay."""

    if not isinstance(value, dict) or value != build_report():
        raise WorkloadScenarioCorpusError(
            "report contradicts independent retained-corpus replay"
        )
    return value


def _load_json_exact(encoded: bytes, where: str) -> Record:
    if not encoded or not encoded.endswith(b"\n") or encoded.endswith(b"\n\n"):
        raise WorkloadScenarioCorpusError(f"{where} is not one canonical line")
    try:
        text = encoded.decode("ascii")

        def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
            value: Record = {}
            for key, item in pairs:
                if key in value:
                    raise WorkloadScenarioCorpusError(
                        f"{where} contains duplicate fields"
                    )
                value[key] = item
            return value

        decoded = json.loads(text, object_pairs_hook=object_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WorkloadScenarioCorpusError(f"{where} is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise WorkloadScenarioCorpusError(f"{where} is not a JSON object")
    if render_report(decoded).encode("ascii") != encoded:
        raise WorkloadScenarioCorpusError(f"{where} is not canonical JSON")
    return decoded


def verify_runner(runner: Path, fixture: Path) -> None:
    """Verify native runner output and the retained fixture independently."""

    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = _load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise WorkloadScenarioCorpusError("retained fixture is stale")
    completed = subprocess.run(
        [str(runner)],
        check=False,
        capture_output=True,
        timeout=30,
    )
    if completed.returncode != 0 or completed.stderr:
        raise WorkloadScenarioCorpusError("native runner failed")
    runner_value = _load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise WorkloadScenarioCorpusError("native runner contradicts Python oracle")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the retained W2 workload corpus",
    )
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verify_runner(args.runner, args.fixture)
    except (OSError, subprocess.SubprocessError, WorkloadScenarioCorpusError) as error:
        print(f"workload-scenario-corpus: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
