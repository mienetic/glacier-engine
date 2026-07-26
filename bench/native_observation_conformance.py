"""Independent W5a native-observation contract and reference oracle.

The implementation mirrors the pointer-free Zig ABI field by field using
only Python's standard library.  It recomputes descriptor, plan, observation,
bundle, workload-receipt, run-report, and reference-report roots.  It does not
probe the local machine, run a workload, infer unavailable telemetry as zero,
or grant an observer authority to start work.
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


class NativeObservationError(ValueError):
    """The native-observation value or canonical report is invalid."""


Record = dict[str, Any]
Digest = bytes

U64_MAX = (1 << 64) - 1
I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
ZERO_DIGEST = bytes(32)
MAXIMUM_RULES = 16
MAXIMUM_OBSERVATIONS = 32
MAXIMUM_JSON_BYTES = 1024 * 1024

DESCRIPTOR_ABI = 0x474E_4F44_0000_0001
RULE_ABI = 0x474E_4F4C_0000_0001
PLAN_ABI = 0x474E_4F50_0000_0001
OBSERVATION_ABI = 0x474E_4F4F_0000_0001
BUNDLE_ABI = 0x474E_4F42_0000_0001
WORKLOAD_RECEIPT_ABI = 0x474E_4F57_0000_0001
RUN_REPORT_ABI = 0x474E_4F52_0000_0001
REFERENCE_REPORT_ABI = 0x474E_4F46_0000_0001

AVAILABILITY_PRESENT = 1
AVAILABILITY_MISSING = 2
AVAILABILITY_DENIED = 3
AVAILABILITY_UNSUPPORTED = 4
AVAILABILITIES = frozenset(
    (
        AVAILABILITY_PRESENT,
        AVAILABILITY_MISSING,
        AVAILABILITY_DENIED,
        AVAILABILITY_UNSUPPORTED,
    )
)
AVAILABILITY_NAMES = ("present", "missing", "denied", "unsupported")

PHASE_PROBE = 1
PHASE_PRE_RUN = 2
PHASE_BEGIN = 3
PHASE_IN_RUN = 4
PHASE_END = 5
PHASE_POST_RUN = 6
PHASES = frozenset(range(PHASE_PROBE, PHASE_POST_RUN + 1))

PLANE_HOST = 1
PLANE_ACCELERATOR = 2

EXECUTION_HOST = 1
EXECUTION_ACCELERATOR = 2
EXECUTION_MIXED = 3
EXECUTION_PLANES = frozenset(
    (EXECUTION_HOST, EXECUTION_ACCELERATOR, EXECUTION_MIXED)
)

UNIT_COUNT = 1
UNIT_BOOLEAN = 2
UNIT_NANOSECONDS = 3
UNIT_BYTES = 4
UNIT_PPM = 5
UNIT_MILLI_CELSIUS = 6
UNIT_KILO_HERTZ = 7
UNIT_MILLI_WATTS = 8
UNIT_MICRO_JOULES = 9

METRIC_HOST_MONOTONIC_TIME = 1
METRIC_HOST_LOGICAL_CPU_COUNT = 2
METRIC_HOST_CPU_BUSY_PPM = 3
METRIC_HOST_CPU_IDLE_PPM = 4
METRIC_HOST_EXTERNAL_CPU_PPM = 5
METRIC_PROCESS_CPU_TIME = 6
METRIC_PROCESS_RESIDENT_BYTES = 7
METRIC_HOST_AVAILABLE_MEMORY_BYTES = 8
METRIC_HOST_PAGE_ACTIVITY_COUNT = 9
METRIC_HOST_SWAP_USED_BYTES = 10
METRIC_HOST_POWER_SOURCE = 11
METRIC_HOST_LOW_POWER_MODE = 12
METRIC_HOST_THERMAL_CONSTRAINT = 13
METRIC_HOST_CPU_TEMPERATURE = 14
METRIC_HOST_CPU_FREQUENCY = 15
METRIC_HOST_CPU_POWER = 16
METRIC_HOST_CPU_ENERGY = 17
METRIC_ACCELERATOR_DEVICE_PRESENT = 32
METRIC_ACCELERATOR_CPU_FALLBACK = 33
METRIC_ACCELERATOR_UTILIZATION = 34
METRIC_ACCELERATOR_ALLOCATED_BYTES = 35
METRIC_ACCELERATOR_COMMITTED_BYTES = 36
METRIC_ACCELERATOR_RESIDENT_BYTES = 37
METRIC_ACCELERATOR_QUEUE_DEPTH = 38
METRIC_ACCELERATOR_TEMPERATURE = 39
METRIC_ACCELERATOR_FREQUENCY = 40
METRIC_ACCELERATOR_POWER = 41
METRIC_ACCELERATOR_ENERGY = 42
METRIC_ACCELERATOR_DEVICE_TIME = 43

HOST_METRICS = frozenset(range(1, 18))
ACCELERATOR_METRICS = frozenset(range(32, 44))
METRICS = HOST_METRICS | ACCELERATOR_METRICS
ALLOWED_METRIC_BITS = sum(1 << metric for metric in METRICS)

METRIC_UNITS: Mapping[int, int] = {
    METRIC_HOST_MONOTONIC_TIME: UNIT_NANOSECONDS,
    METRIC_HOST_LOGICAL_CPU_COUNT: UNIT_COUNT,
    METRIC_HOST_CPU_BUSY_PPM: UNIT_PPM,
    METRIC_HOST_CPU_IDLE_PPM: UNIT_PPM,
    METRIC_HOST_EXTERNAL_CPU_PPM: UNIT_PPM,
    METRIC_PROCESS_CPU_TIME: UNIT_NANOSECONDS,
    METRIC_PROCESS_RESIDENT_BYTES: UNIT_BYTES,
    METRIC_HOST_AVAILABLE_MEMORY_BYTES: UNIT_BYTES,
    METRIC_HOST_PAGE_ACTIVITY_COUNT: UNIT_COUNT,
    METRIC_HOST_SWAP_USED_BYTES: UNIT_BYTES,
    METRIC_HOST_POWER_SOURCE: UNIT_COUNT,
    METRIC_HOST_LOW_POWER_MODE: UNIT_BOOLEAN,
    METRIC_HOST_THERMAL_CONSTRAINT: UNIT_COUNT,
    METRIC_HOST_CPU_TEMPERATURE: UNIT_MILLI_CELSIUS,
    METRIC_HOST_CPU_FREQUENCY: UNIT_KILO_HERTZ,
    METRIC_HOST_CPU_POWER: UNIT_MILLI_WATTS,
    METRIC_HOST_CPU_ENERGY: UNIT_MICRO_JOULES,
    METRIC_ACCELERATOR_DEVICE_PRESENT: UNIT_BOOLEAN,
    METRIC_ACCELERATOR_CPU_FALLBACK: UNIT_BOOLEAN,
    METRIC_ACCELERATOR_UTILIZATION: UNIT_PPM,
    METRIC_ACCELERATOR_ALLOCATED_BYTES: UNIT_BYTES,
    METRIC_ACCELERATOR_COMMITTED_BYTES: UNIT_BYTES,
    METRIC_ACCELERATOR_RESIDENT_BYTES: UNIT_BYTES,
    METRIC_ACCELERATOR_QUEUE_DEPTH: UNIT_COUNT,
    METRIC_ACCELERATOR_TEMPERATURE: UNIT_MILLI_CELSIUS,
    METRIC_ACCELERATOR_FREQUENCY: UNIT_KILO_HERTZ,
    METRIC_ACCELERATOR_POWER: UNIT_MILLI_WATTS,
    METRIC_ACCELERATOR_ENERGY: UNIT_MICRO_JOULES,
    METRIC_ACCELERATOR_DEVICE_TIME: UNIT_NANOSECONDS,
}

SCOPE_PROBE = 1
SCOPE_PRE_RUN = 2
SCOPE_POST_RUN = 3
SCOPE_PRE_POST = 4
SCOPES = frozenset(range(SCOPE_PROBE, SCOPE_PRE_POST + 1))

PREDICATE_REQUIRE_PRESENT = 1
PREDICATE_INCLUSIVE_RANGE = 2
PREDICATE_MAX_ABS_DELTA = 3
PREDICATE_REQUIRE_FALSE = 4
PREDICATE_SAME_SOURCE = 5
PREDICATE_SAME_SUBJECT = 6
PREDICATES = frozenset(
    range(PREDICATE_REQUIRE_PRESENT, PREDICATE_SAME_SUBJECT + 1)
)

WORKLOAD_SUCCEEDED = 1
WORKLOAD_FAILED = 2
GATE_PASSED = 1
GATE_FAILED = 2
FALLBACK_NOT_APPLICABLE = 1
FALLBACK_NOT_OBSERVED = 2
FALLBACK_ABSENT = 3
FALLBACK_PRESENT = 4

DECISION_PUBLISHABLE = 1
DECISION_REJECTED_PRE_RUN = 2
DECISION_WORKLOAD_FAILED = 3
DECISION_REJECTED_POST_RUN = 4
DECISION_NAMES: Mapping[int, str] = {
    DECISION_PUBLISHABLE: "publishable",
    DECISION_REJECTED_PRE_RUN: "rejected_pre_run",
    DECISION_WORKLOAD_FAILED: "workload_failed",
    DECISION_REJECTED_POST_RUN: "rejected_post_run",
}

REASON_CALLBACK_PROBE = 1 << 0

DESCRIPTOR_DOMAIN = b"glacier-native-observer-descriptor-v1\x00"
RULE_DOMAIN = b"glacier-native-observation-rule-v1\x00"
PLAN_DOMAIN = b"glacier-native-observation-plan-v1\x00"
OBSERVATION_DOMAIN = b"glacier-native-observation-record-v1\x00"
OBSERVATION_SECTION_DOMAIN = b"glacier-native-observation-section-v1\x00"
BUNDLE_DOMAIN = b"glacier-native-observation-bundle-v1\x00"
RUN_DOMAIN = b"glacier-native-observation-run-v1\x00"
WORKLOAD_RECEIPT_DOMAIN = b"glacier-native-observation-workload-receipt-v1\x00"
RUN_REPORT_DOMAIN = b"glacier-native-observation-run-report-v1\x00"
REFERENCE_REPORT_DOMAIN = b"glacier-native-observation-reference-report-v1\x00"

# The observation wrapper treats the retained W4a workload roots as opaque
# evidence inputs, then binds them into its own receipt and report hashes.
WORKLOAD_RESULT_SHA256 = bytes.fromhex(
    "fcfbacf21be1e549f2402c9bf0a1d7bf94b6252a4a46f6f5ca8f0f6f0d6fe1f2"
)
WORKLOAD_CORRECTNESS_SHA256 = bytes.fromhex(
    "a6174f75ae22ec3bec57ee184f69fb116a6bd57d8c16d487705bc64c78f23660"
)
WORKLOAD_OWNERSHIP_SHA256 = bytes.fromhex(
    "9024ea81959bc53db7b789752169e9f6ab15668519311a3cc197557eac3caa72"
)

DESCRIPTOR_FIELDS = (
    "abi_version",
    "implementation_abi",
    "observer_epoch",
    "declared_metric_bits",
    "direct_metric_bits",
    "namespace_sha256",
    "source_schema_sha256",
    "descriptor_sha256",
)
RULE_FIELDS = (
    "abi_version",
    "metric",
    "scope",
    "predicate",
    "lower",
    "upper",
    "rule_sha256",
)
PLAN_FIELDS = (
    "abi_version",
    "observer_descriptor_sha256",
    "workload_profile_sha256",
    "artifact_sha256",
    "build_sha256",
    "machine_sha256",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "execution_plane",
    "worker_count",
    "queue_count",
    "rules",
    "challenge_sha256",
    "run_sha256",
    "plan_sha256",
)
OBSERVATION_FIELDS = (
    "abi_version",
    "run_sha256",
    "descriptor_sha256",
    "phase",
    "sample_sequence",
    "metric",
    "plane",
    "availability",
    "unit",
    "value",
    "observed_at_ticks",
    "sample_clock_domain_sha256",
    "value_clock_domain_sha256",
    "source_sha256",
    "provenance_sha256",
    "subject_sha256",
    "reason_sha256",
    "observation_sha256",
)
BUNDLE_FIELDS = (
    "abi_version",
    "run_sha256",
    "descriptor_sha256",
    "phase",
    "records",
    "records_sha256",
    "bundle_sha256",
)
RECEIPT_FIELDS = (
    "abi_version",
    "run_sha256",
    "execution_plane",
    "status",
    "correctness",
    "zero_orphans",
    "fallback",
    "profile_count",
    "item_count",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "result_sha256",
    "correctness_sha256",
    "ownership_sha256",
    "receipt_sha256",
)
RUN_REPORT_FIELDS = (
    "abi_version",
    "descriptor_sha256",
    "plan_sha256",
    "probe_bundle_sha256",
    "pre_run_bundle_sha256",
    "post_run_bundle_sha256",
    "workload_receipt_sha256",
    "decision",
    "last_phase",
    "workload_invocations",
    "begin_invocations",
    "end_invocations",
    "callback_failure_bits",
    "missing_metric_bits",
    "denied_metric_bits",
    "unsupported_metric_bits",
    "threshold_metric_bits",
    "source_mismatch_bits",
    "subject_mismatch_bits",
    "reason_bits",
    "elapsed_nanoseconds",
    "report_sha256",
)
REFERENCE_FIELDS = (
    "abi_version",
    "descriptor_sha256",
    "plan_sha256",
    "probe_bundle_sha256",
    "pre_run_bundle_sha256",
    "post_run_bundle_sha256",
    "workload_receipt_sha256",
    "run_report_sha256",
    "workload_result_sha256",
    "decision",
    "profile_count",
    "item_count",
    "elapsed_nanoseconds",
    "report_sha256",
)
REPORT_FIELDS = (
    "schema",
    "descriptor_abi",
    "rule_abi",
    "plan_abi",
    "observation_abi",
    "bundle_abi",
    "workload_receipt_abi",
    "run_report_abi",
    "reference_report_abi",
    "availability",
    "decision",
    "profile_count",
    "item_count",
    "elapsed_nanoseconds",
    "descriptor_sha256",
    "plan_sha256",
    "probe_bundle_sha256",
    "pre_run_bundle_sha256",
    "post_run_bundle_sha256",
    "workload_receipt_sha256",
    "run_report_sha256",
    "workload_result_sha256",
    "report_sha256",
)
REPORT_SCHEMA = "glacier.native-observation-reference/v1"


def _exact_fields(value: Any, fields: Sequence[str], where: str) -> Record:
    if not isinstance(value, dict) or tuple(value) != tuple(fields):
        raise NativeObservationError(f"{where} fields are not canonical")
    return value


def _u64(value: Any, where: str) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise NativeObservationError(f"{where} is not u64")
    return value


def _i64(value: Any, where: str) -> int:
    if type(value) is not int or not I64_MIN <= value <= I64_MAX:
        raise NativeObservationError(f"{where} is not i64")
    return value


def _digest(value: Any, where: str, *, nonzero: bool = False) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise NativeObservationError(f"{where} is not a SHA-256 digest")
    if nonzero and hmac.compare_digest(value, ZERO_DIGEST):
        raise NativeObservationError(f"{where} is zero")
    return value


def _hash_u64(hash_value: Any, value: Any, where: str) -> None:
    hash_value.update(struct.pack("<Q", _u64(value, where)))


def _hash_i64(hash_value: Any, value: Any, where: str) -> None:
    hash_value.update(struct.pack("<q", _i64(value, where)))


def digest_v1(value: str | bytes) -> Digest:
    if isinstance(value, str):
        value = value.encode("utf-8")
    if type(value) is not bytes:
        raise NativeObservationError("digest input is not bytes")
    return hashlib.sha256(value).digest()


def metric_bit(metric: Any) -> int:
    metric = _u64(metric, "metric")
    if metric not in METRICS or metric >= 64:
        raise NativeObservationError("unknown metric")
    return 1 << metric


def metric_plane(metric: Any) -> int:
    metric = _u64(metric, "metric")
    if metric in HOST_METRICS:
        return PLANE_HOST
    if metric in ACCELERATOR_METRICS:
        return PLANE_ACCELERATOR
    raise NativeObservationError("unknown metric")


def metric_unit(metric: Any) -> int:
    try:
        return METRIC_UNITS[_u64(metric, "metric")]
    except KeyError as error:
        raise NativeObservationError("unknown metric") from error


def descriptor_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(DESCRIPTOR_DOMAIN)
    for field in (
        "abi_version",
        "implementation_abi",
        "observer_epoch",
        "declared_metric_bits",
        "direct_metric_bits",
    ):
        _hash_u64(hash_value, value[field], f"descriptor.{field}")
    for field in ("namespace_sha256", "source_schema_sha256"):
        hash_value.update(_digest(value[field], f"descriptor.{field}"))
    return hash_value.digest()


def validate_descriptor(value: Any) -> Record:
    value = _exact_fields(value, DESCRIPTOR_FIELDS, "descriptor")
    if _u64(value["abi_version"], "descriptor.abi_version") != DESCRIPTOR_ABI:
        raise NativeObservationError("descriptor ABI mismatch")
    if _u64(value["implementation_abi"], "descriptor.implementation_abi") == 0:
        raise NativeObservationError("descriptor implementation ABI is zero")
    if _u64(value["observer_epoch"], "descriptor.observer_epoch") == 0:
        raise NativeObservationError("descriptor epoch is zero")
    declared = _u64(value["declared_metric_bits"], "descriptor.declared")
    direct = _u64(value["direct_metric_bits"], "descriptor.direct")
    if declared == 0 or declared & ~ALLOWED_METRIC_BITS or direct & ~declared:
        raise NativeObservationError("descriptor metric masks are invalid")
    _digest(value["namespace_sha256"], "descriptor.namespace", nonzero=True)
    _digest(value["source_schema_sha256"], "descriptor.schema", nonzero=True)
    if not hmac.compare_digest(
        _digest(value["descriptor_sha256"], "descriptor.root"),
        descriptor_sha256(value),
    ):
        raise NativeObservationError("descriptor root mismatch")
    return deepcopy(value)


def make_descriptor(
    implementation_abi: int,
    observer_epoch: int,
    declared_metric_bits: int,
    direct_metric_bits: int,
    namespace_sha256: Digest,
    source_schema_sha256: Digest,
) -> Record:
    result = {
        "abi_version": DESCRIPTOR_ABI,
        "implementation_abi": implementation_abi,
        "observer_epoch": observer_epoch,
        "declared_metric_bits": declared_metric_bits,
        "direct_metric_bits": direct_metric_bits,
        "namespace_sha256": namespace_sha256,
        "source_schema_sha256": source_schema_sha256,
        "descriptor_sha256": ZERO_DIGEST,
    }
    result["descriptor_sha256"] = descriptor_sha256(result)
    return validate_descriptor(result)


def rule_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(RULE_DOMAIN)
    for field in ("abi_version", "metric", "scope", "predicate"):
        _hash_u64(hash_value, value[field], f"rule.{field}")
    _hash_i64(hash_value, value["lower"], "rule.lower")
    _hash_i64(hash_value, value["upper"], "rule.upper")
    return hash_value.digest()


def validate_rule(value: Any) -> Record:
    value = _exact_fields(value, RULE_FIELDS, "rule")
    if _u64(value["abi_version"], "rule.abi_version") != RULE_ABI:
        raise NativeObservationError("rule ABI mismatch")
    metric_bit(value["metric"])
    scope = _u64(value["scope"], "rule.scope")
    predicate = _u64(value["predicate"], "rule.predicate")
    if scope not in SCOPES or predicate not in PREDICATES:
        raise NativeObservationError("rule enum is invalid")
    lower = _i64(value["lower"], "rule.lower")
    upper = _i64(value["upper"], "rule.upper")
    if predicate in (
        PREDICATE_REQUIRE_PRESENT,
        PREDICATE_REQUIRE_FALSE,
        PREDICATE_SAME_SOURCE,
        PREDICATE_SAME_SUBJECT,
    ) and (lower != 0 or upper != 0):
        raise NativeObservationError("rule predicate requires zero bounds")
    if predicate == PREDICATE_INCLUSIVE_RANGE and lower > upper:
        raise NativeObservationError("rule range is inverted")
    if predicate == PREDICATE_MAX_ABS_DELTA and (
        scope != SCOPE_PRE_POST or lower != 0 or upper < 0
    ):
        raise NativeObservationError("delta rule is invalid")
    if predicate in (PREDICATE_SAME_SOURCE, PREDICATE_SAME_SUBJECT) and (
        scope != SCOPE_PRE_POST
    ):
        raise NativeObservationError("identity rule requires pre/post scope")
    if scope == SCOPE_PRE_POST and predicate not in (
        PREDICATE_MAX_ABS_DELTA,
        PREDICATE_SAME_SOURCE,
        PREDICATE_SAME_SUBJECT,
    ):
        raise NativeObservationError("pre/post rule predicate is invalid")
    if not hmac.compare_digest(
        _digest(value["rule_sha256"], "rule.root"),
        rule_sha256(value),
    ):
        raise NativeObservationError("rule root mismatch")
    return deepcopy(value)


def make_rule(
    metric: int,
    scope: int,
    predicate: int,
    lower: int = 0,
    upper: int = 0,
) -> Record:
    result = {
        "abi_version": RULE_ABI,
        "metric": metric,
        "scope": scope,
        "predicate": predicate,
        "lower": lower,
        "upper": upper,
        "rule_sha256": ZERO_DIGEST,
    }
    result["rule_sha256"] = rule_sha256(result)
    return validate_rule(result)


def run_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(RUN_DOMAIN)
    for field in (
        "observer_descriptor_sha256",
        "workload_profile_sha256",
        "artifact_sha256",
        "build_sha256",
        "machine_sha256",
        "backend_sha256",
        "device_sha256",
        "placement_sha256",
    ):
        hash_value.update(_digest(value[field], f"plan.{field}"))
    for field in ("execution_plane", "worker_count", "queue_count"):
        _hash_u64(hash_value, value[field], f"plan.{field}")
    hash_value.update(_digest(value["challenge_sha256"], "plan.challenge"))
    return hash_value.digest()


def plan_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(PLAN_DOMAIN)
    _hash_u64(hash_value, value["abi_version"], "plan.abi_version")
    for field in (
        "observer_descriptor_sha256",
        "workload_profile_sha256",
        "artifact_sha256",
        "build_sha256",
        "machine_sha256",
        "backend_sha256",
        "device_sha256",
        "placement_sha256",
    ):
        hash_value.update(_digest(value[field], f"plan.{field}"))
    for field in ("execution_plane", "worker_count", "queue_count"):
        _hash_u64(hash_value, value[field], f"plan.{field}")
    rules = value["rules"]
    if not isinstance(rules, list):
        raise NativeObservationError("plan rules are not a list")
    _hash_u64(hash_value, len(rules), "plan.rule_count")
    for rule in rules:
        hash_value.update(_digest(rule["rule_sha256"], "plan.rule.root"))
    hash_value.update(_digest(value["challenge_sha256"], "plan.challenge"))
    hash_value.update(_digest(value["run_sha256"], "plan.run"))
    return hash_value.digest()


def validate_plan(descriptor: Any, value: Any) -> Record:
    descriptor = validate_descriptor(descriptor)
    value = _exact_fields(value, PLAN_FIELDS, "plan")
    if _u64(value["abi_version"], "plan.abi_version") != PLAN_ABI:
        raise NativeObservationError("plan ABI mismatch")
    if not hmac.compare_digest(
        _digest(value["observer_descriptor_sha256"], "plan.descriptor"),
        descriptor["descriptor_sha256"],
    ):
        raise NativeObservationError("plan descriptor substitution")
    for field in (
        "workload_profile_sha256",
        "artifact_sha256",
        "build_sha256",
        "machine_sha256",
        "backend_sha256",
        "device_sha256",
        "placement_sha256",
        "challenge_sha256",
    ):
        _digest(value[field], f"plan.{field}", nonzero=True)
    execution_plane = _u64(value["execution_plane"], "plan.execution_plane")
    if execution_plane not in EXECUTION_PLANES:
        raise NativeObservationError("plan execution plane is invalid")
    if _u64(value["worker_count"], "plan.worker_count") == 0:
        raise NativeObservationError("plan worker count is zero")
    if _u64(value["queue_count"], "plan.queue_count") == 0:
        raise NativeObservationError("plan queue count is zero")
    rules = value["rules"]
    if not isinstance(rules, list) or not 0 < len(rules) <= MAXIMUM_RULES:
        raise NativeObservationError("plan rule count is invalid")
    previous_key = 0
    host_time_pre_gate = False
    host_time_post_gate = False
    host_cpu_pre_gate = False
    host_cpu_stability_gate = False
    accelerator_present_gate = False
    accelerator_pre_fallback_gate = False
    accelerator_post_fallback_gate = False
    for source in rules:
        rule = validate_rule(source)
        if descriptor["declared_metric_bits"] & metric_bit(rule["metric"]) == 0:
            raise NativeObservationError("rule metric was not declared")
        key = (rule["metric"] << 16) | (rule["scope"] << 8) | rule["predicate"]
        if key <= previous_key:
            raise NativeObservationError("rules are not canonically ordered")
        previous_key = key
        if (
            rule["metric"] == METRIC_HOST_MONOTONIC_TIME
            and rule["predicate"] == PREDICATE_REQUIRE_PRESENT
        ):
            if rule["scope"] == SCOPE_PRE_RUN:
                host_time_pre_gate = True
            if rule["scope"] == SCOPE_POST_RUN:
                host_time_post_gate = True
        if (
            rule["metric"] == METRIC_HOST_LOGICAL_CPU_COUNT
            and rule["scope"] == SCOPE_PRE_RUN
            and rule["predicate"] == PREDICATE_INCLUSIVE_RANGE
            and rule["lower"] >= 1
        ):
            host_cpu_pre_gate = True
        if (
            rule["metric"] == METRIC_HOST_LOGICAL_CPU_COUNT
            and rule["scope"] == SCOPE_PRE_POST
            and rule["predicate"] == PREDICATE_MAX_ABS_DELTA
            and rule["upper"] == 0
        ):
            host_cpu_stability_gate = True
        if (
            rule["metric"] == METRIC_ACCELERATOR_DEVICE_PRESENT
            and rule["scope"] == SCOPE_PRE_RUN
            and rule["predicate"] == PREDICATE_INCLUSIVE_RANGE
            and rule["lower"] == 1
            and rule["upper"] == 1
        ):
            accelerator_present_gate = True
        if (
            rule["metric"] == METRIC_ACCELERATOR_CPU_FALLBACK
            and rule["predicate"] == PREDICATE_REQUIRE_FALSE
        ):
            if rule["scope"] == SCOPE_PRE_RUN:
                accelerator_pre_fallback_gate = True
            if rule["scope"] == SCOPE_POST_RUN:
                accelerator_post_fallback_gate = True
    baseline_bits = metric_bit(
        METRIC_HOST_MONOTONIC_TIME
    ) | metric_bit(METRIC_HOST_LOGICAL_CPU_COUNT)
    if (
        descriptor["direct_metric_bits"] & baseline_bits != baseline_bits
        or not host_time_pre_gate
        or not host_time_post_gate
        or not host_cpu_pre_gate
        or not host_cpu_stability_gate
    ):
        raise NativeObservationError(
            "plan lacks mandatory host observation baseline"
        )
    if execution_plane in (EXECUTION_ACCELERATOR, EXECUTION_MIXED):
        accelerator_bits = metric_bit(
            METRIC_ACCELERATOR_DEVICE_PRESENT
        ) | metric_bit(METRIC_ACCELERATOR_CPU_FALLBACK)
        if (
            descriptor["direct_metric_bits"] & accelerator_bits
            != accelerator_bits
            or not accelerator_present_gate
            or not accelerator_pre_fallback_gate
            or not accelerator_post_fallback_gate
        ):
            raise NativeObservationError(
                "accelerator plan lacks fail-closed placement gates"
            )
    if not hmac.compare_digest(
        _digest(value["run_sha256"], "plan.run"),
        run_sha256(value),
    ):
        raise NativeObservationError("run root mismatch")
    if not hmac.compare_digest(
        _digest(value["plan_sha256"], "plan.root"),
        plan_sha256(value),
    ):
        raise NativeObservationError("plan root mismatch")
    return deepcopy(value)


def make_plan(
    descriptor: Record,
    workload_profile_sha256: Digest,
    artifact_sha256: Digest,
    build_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    execution_plane: int,
    worker_count: int,
    queue_count: int,
    rules: Sequence[Record],
    challenge_sha256: Digest,
) -> Record:
    result = {
        "abi_version": PLAN_ABI,
        "observer_descriptor_sha256": descriptor["descriptor_sha256"],
        "workload_profile_sha256": workload_profile_sha256,
        "artifact_sha256": artifact_sha256,
        "build_sha256": build_sha256,
        "machine_sha256": machine_sha256,
        "backend_sha256": backend_sha256,
        "device_sha256": device_sha256,
        "placement_sha256": placement_sha256,
        "execution_plane": execution_plane,
        "worker_count": worker_count,
        "queue_count": queue_count,
        "rules": [deepcopy(rule) for rule in rules],
        "challenge_sha256": challenge_sha256,
        "run_sha256": ZERO_DIGEST,
        "plan_sha256": ZERO_DIGEST,
    }
    result["run_sha256"] = run_sha256(result)
    result["plan_sha256"] = plan_sha256(result)
    return validate_plan(descriptor, result)


def observation_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(OBSERVATION_DOMAIN)
    _hash_u64(hash_value, value["abi_version"], "observation.abi_version")
    hash_value.update(_digest(value["run_sha256"], "observation.run"))
    hash_value.update(
        _digest(value["descriptor_sha256"], "observation.descriptor")
    )
    for field in (
        "phase",
        "sample_sequence",
        "metric",
        "plane",
        "availability",
        "unit",
    ):
        _hash_u64(hash_value, value[field], f"observation.{field}")
    _hash_i64(hash_value, value["value"], "observation.value")
    _hash_u64(
        hash_value,
        value["observed_at_ticks"],
        "observation.observed_at_ticks",
    )
    for field in (
        "sample_clock_domain_sha256",
        "value_clock_domain_sha256",
        "source_sha256",
        "provenance_sha256",
        "subject_sha256",
        "reason_sha256",
    ):
        hash_value.update(_digest(value[field], f"observation.{field}"))
    return hash_value.digest()


def validate_observation(
    descriptor: Any,
    plan: Any,
    value: Any,
) -> Record:
    descriptor = validate_descriptor(descriptor)
    plan = validate_plan(descriptor, plan)
    value = _exact_fields(value, OBSERVATION_FIELDS, "observation")
    if _u64(value["abi_version"], "observation.abi") != OBSERVATION_ABI:
        raise NativeObservationError("observation ABI mismatch")
    if not hmac.compare_digest(
        _digest(value["run_sha256"], "observation.run"),
        plan["run_sha256"],
    ):
        raise NativeObservationError("observation run substitution")
    if not hmac.compare_digest(
        _digest(value["descriptor_sha256"], "observation.descriptor"),
        descriptor["descriptor_sha256"],
    ):
        raise NativeObservationError("observation descriptor substitution")
    phase = _u64(value["phase"], "observation.phase")
    sequence = _u64(value["sample_sequence"], "observation.sequence")
    metric = _u64(value["metric"], "observation.metric")
    plane = _u64(value["plane"], "observation.plane")
    availability = _u64(value["availability"], "observation.availability")
    unit = _u64(value["unit"], "observation.unit")
    observed_value = _i64(value["value"], "observation.value")
    ticks = _u64(value["observed_at_ticks"], "observation.ticks")
    if phase not in PHASES or sequence == 0 or ticks == 0:
        raise NativeObservationError("observation phase, sequence, or tick invalid")
    bit = metric_bit(metric)
    if plane != metric_plane(metric) or unit != metric_unit(metric):
        raise NativeObservationError("observation metric metadata mismatch")
    if availability not in AVAILABILITIES:
        raise NativeObservationError("observation availability is invalid")
    if descriptor["declared_metric_bits"] & bit == 0:
        raise NativeObservationError("observation metric was not declared")
    if availability == AVAILABILITY_PRESENT:
        if descriptor["direct_metric_bits"] & bit == 0:
            raise NativeObservationError("present observation is not direct")
        if metric == METRIC_HOST_LOGICAL_CPU_COUNT:
            if observed_value < 1:
                raise NativeObservationError(
                    "logical CPU observation is below one"
                )
        elif metric in (
            METRIC_HOST_CPU_TEMPERATURE,
            METRIC_ACCELERATOR_TEMPERATURE,
        ):
            if observed_value < -273_150:
                raise NativeObservationError(
                    "temperature observation is below absolute zero"
                )
        elif observed_value < 0:
            raise NativeObservationError("present observation is negative")
    elif observed_value != 0:
        raise NativeObservationError("unavailable observation carries a value")
    if unit == UNIT_BOOLEAN and availability == AVAILABILITY_PRESENT:
        if observed_value not in (0, 1):
            raise NativeObservationError("boolean observation is not binary")
    if unit == UNIT_PPM and availability == AVAILABILITY_PRESENT:
        if not 0 <= observed_value <= 1_000_000:
            raise NativeObservationError("ppm observation is out of range")
    _digest(
        value["sample_clock_domain_sha256"],
        "observation.sample_clock_domain_sha256",
        nonzero=True,
    )
    value_clock = _digest(
        value["value_clock_domain_sha256"],
        "observation.value_clock_domain_sha256",
    )
    if unit == UNIT_NANOSECONDS:
        if availability == AVAILABILITY_PRESENT:
            if hmac.compare_digest(value_clock, ZERO_DIGEST):
                raise NativeObservationError(
                    "present time observation lacks a value clock"
                )
        elif not hmac.compare_digest(value_clock, ZERO_DIGEST):
            raise NativeObservationError(
                "unavailable time observation carries a value clock"
            )
    elif not hmac.compare_digest(value_clock, ZERO_DIGEST):
        raise NativeObservationError(
            "non-time observation carries a value clock"
        )
    for field in (
        "source_sha256",
        "provenance_sha256",
        "subject_sha256",
    ):
        _digest(value[field], f"observation.{field}", nonzero=True)
    reason = _digest(value["reason_sha256"], "observation.reason_sha256")
    if availability == AVAILABILITY_PRESENT:
        if not hmac.compare_digest(reason, ZERO_DIGEST):
            raise NativeObservationError(
                "present observation carries an unavailable reason"
            )
    elif hmac.compare_digest(reason, ZERO_DIGEST):
        raise NativeObservationError(
            "unavailable observation lacks a reason"
        )
    if not hmac.compare_digest(
        _digest(value["observation_sha256"], "observation.root"),
        observation_sha256(value),
    ):
        raise NativeObservationError("observation root mismatch")
    return deepcopy(value)


def make_observation(
    descriptor: Record,
    plan: Record,
    phase: int,
    sample_sequence: int,
    metric: int,
    availability: int,
    value: int,
    observed_at_ticks: int,
    sample_clock_domain_sha256: Digest,
    value_clock_domain_sha256: Digest,
    source_sha256: Digest,
    provenance_sha256: Digest,
    subject_sha256: Digest,
    reason_sha256: Digest,
) -> Record:
    result = {
        "abi_version": OBSERVATION_ABI,
        "run_sha256": plan["run_sha256"],
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "phase": phase,
        "sample_sequence": sample_sequence,
        "metric": metric,
        "plane": metric_plane(metric),
        "availability": availability,
        "unit": metric_unit(metric),
        "value": value,
        "observed_at_ticks": observed_at_ticks,
        "sample_clock_domain_sha256": sample_clock_domain_sha256,
        "value_clock_domain_sha256": value_clock_domain_sha256,
        "source_sha256": source_sha256,
        "provenance_sha256": provenance_sha256,
        "subject_sha256": subject_sha256,
        "reason_sha256": reason_sha256,
        "observation_sha256": ZERO_DIGEST,
    }
    result["observation_sha256"] = observation_sha256(result)
    return validate_observation(descriptor, plan, result)


def observation_section_sha256(records: Sequence[Mapping[str, Any]]) -> Digest:
    hash_value = hashlib.sha256(OBSERVATION_SECTION_DOMAIN)
    _hash_u64(hash_value, len(records), "bundle.record_count")
    for record in records:
        hash_value.update(
            _digest(record["observation_sha256"], "bundle.record.root")
        )
    return hash_value.digest()


def bundle_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(BUNDLE_DOMAIN)
    _hash_u64(hash_value, value["abi_version"], "bundle.abi_version")
    hash_value.update(_digest(value["run_sha256"], "bundle.run"))
    hash_value.update(_digest(value["descriptor_sha256"], "bundle.descriptor"))
    _hash_u64(hash_value, value["phase"], "bundle.phase")
    records = value["records"]
    if not isinstance(records, list):
        raise NativeObservationError("bundle records are not a list")
    _hash_u64(hash_value, len(records), "bundle.record_count")
    hash_value.update(_digest(value["records_sha256"], "bundle.records"))
    return hash_value.digest()


def validate_bundle(descriptor: Any, plan: Any, value: Any) -> Record:
    descriptor = validate_descriptor(descriptor)
    plan = validate_plan(descriptor, plan)
    value = _exact_fields(value, BUNDLE_FIELDS, "bundle")
    if _u64(value["abi_version"], "bundle.abi_version") != BUNDLE_ABI:
        raise NativeObservationError("bundle ABI mismatch")
    if not hmac.compare_digest(
        _digest(value["run_sha256"], "bundle.run"), plan["run_sha256"]
    ):
        raise NativeObservationError("bundle run substitution")
    if not hmac.compare_digest(
        _digest(value["descriptor_sha256"], "bundle.descriptor"),
        descriptor["descriptor_sha256"],
    ):
        raise NativeObservationError("bundle descriptor substitution")
    phase = _u64(value["phase"], "bundle.phase")
    records = value["records"]
    if (
        phase not in PHASES
        or not isinstance(records, list)
        or not 0 < len(records) <= MAXIMUM_OBSERVATIONS
    ):
        raise NativeObservationError("bundle phase or count is invalid")
    previous_metric = 0
    for index, source in enumerate(records, start=1):
        record = validate_observation(descriptor, plan, source)
        if (
            record["phase"] != phase
            or record["sample_sequence"] != index
            or record["metric"] <= previous_metric
        ):
            raise NativeObservationError("bundle records are not canonical")
        previous_metric = record["metric"]
    if not hmac.compare_digest(
        _digest(value["records_sha256"], "bundle.records"),
        observation_section_sha256(records),
    ):
        raise NativeObservationError("bundle record-section root mismatch")
    if not hmac.compare_digest(
        _digest(value["bundle_sha256"], "bundle.root"),
        bundle_sha256(value),
    ):
        raise NativeObservationError("bundle root mismatch")
    return deepcopy(value)


def make_bundle(
    descriptor: Record,
    plan: Record,
    phase: int,
    records: Sequence[Record],
) -> Record:
    result = {
        "abi_version": BUNDLE_ABI,
        "run_sha256": plan["run_sha256"],
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "phase": phase,
        "records": [deepcopy(record) for record in records],
        "records_sha256": ZERO_DIGEST,
        "bundle_sha256": ZERO_DIGEST,
    }
    result["records_sha256"] = observation_section_sha256(result["records"])
    result["bundle_sha256"] = bundle_sha256(result)
    return validate_bundle(descriptor, plan, result)


def workload_receipt_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(WORKLOAD_RECEIPT_DOMAIN)
    _hash_u64(hash_value, value["abi_version"], "receipt.abi_version")
    hash_value.update(_digest(value["run_sha256"], "receipt.run"))
    for field in (
        "execution_plane",
        "status",
        "correctness",
        "zero_orphans",
        "fallback",
        "profile_count",
        "item_count",
    ):
        _hash_u64(hash_value, value[field], f"receipt.{field}")
    for field in (
        "backend_sha256",
        "device_sha256",
        "placement_sha256",
        "result_sha256",
        "correctness_sha256",
        "ownership_sha256",
    ):
        hash_value.update(_digest(value[field], f"receipt.{field}"))
    return hash_value.digest()


def validate_workload_receipt(plan: Any, value: Any) -> Record:
    value = _exact_fields(value, RECEIPT_FIELDS, "receipt")
    if _u64(value["abi_version"], "receipt.abi") != WORKLOAD_RECEIPT_ABI:
        raise NativeObservationError("receipt ABI mismatch")
    if not hmac.compare_digest(
        _digest(value["run_sha256"], "receipt.run"), plan["run_sha256"]
    ):
        raise NativeObservationError("receipt run substitution")
    if value["execution_plane"] != plan["execution_plane"]:
        raise NativeObservationError("receipt execution-plane substitution")
    status = _u64(value["status"], "receipt.status")
    correctness = _u64(value["correctness"], "receipt.correctness")
    zero_orphans = _u64(value["zero_orphans"], "receipt.zero_orphans")
    fallback = _u64(value["fallback"], "receipt.fallback")
    if status not in (WORKLOAD_SUCCEEDED, WORKLOAD_FAILED):
        raise NativeObservationError("receipt status is invalid")
    if correctness not in (GATE_PASSED, GATE_FAILED):
        raise NativeObservationError("receipt correctness gate is invalid")
    if zero_orphans not in (GATE_PASSED, GATE_FAILED):
        raise NativeObservationError("receipt ownership gate is invalid")
    if fallback not in range(FALLBACK_NOT_APPLICABLE, FALLBACK_PRESENT + 1):
        raise NativeObservationError("receipt fallback state is invalid")
    if _u64(value["profile_count"], "receipt.profiles") == 0:
        raise NativeObservationError("receipt profile count is zero")
    if _u64(value["item_count"], "receipt.items") == 0:
        raise NativeObservationError("receipt item count is zero")
    for field in ("backend_sha256", "device_sha256", "placement_sha256"):
        if not hmac.compare_digest(
            _digest(value[field], f"receipt.{field}"), plan[field]
        ):
            raise NativeObservationError(f"receipt {field} substitution")
    for field in (
        "result_sha256",
        "correctness_sha256",
        "ownership_sha256",
    ):
        _digest(value[field], f"receipt.{field}", nonzero=True)
    if plan["execution_plane"] == EXECUTION_HOST:
        if fallback != FALLBACK_NOT_APPLICABLE:
            raise NativeObservationError("host receipt has fallback state")
    elif fallback == FALLBACK_NOT_APPLICABLE:
        raise NativeObservationError("accelerator receipt lacks fallback state")
    if not hmac.compare_digest(
        _digest(value["receipt_sha256"], "receipt.root"),
        workload_receipt_sha256(value),
    ):
        raise NativeObservationError("receipt root mismatch")
    return deepcopy(value)


def make_workload_receipt(
    plan: Record,
    status: int,
    correctness: int,
    zero_orphans: int,
    fallback: int,
    profile_count: int,
    item_count: int,
    result_sha256: Digest,
    correctness_sha256: Digest,
    ownership_sha256: Digest,
) -> Record:
    result = {
        "abi_version": WORKLOAD_RECEIPT_ABI,
        "run_sha256": plan["run_sha256"],
        "execution_plane": plan["execution_plane"],
        "status": status,
        "correctness": correctness,
        "zero_orphans": zero_orphans,
        "fallback": fallback,
        "profile_count": profile_count,
        "item_count": item_count,
        "backend_sha256": plan["backend_sha256"],
        "device_sha256": plan["device_sha256"],
        "placement_sha256": plan["placement_sha256"],
        "result_sha256": result_sha256,
        "correctness_sha256": correctness_sha256,
        "ownership_sha256": ownership_sha256,
        "receipt_sha256": ZERO_DIGEST,
    }
    result["receipt_sha256"] = workload_receipt_sha256(result)
    return validate_workload_receipt(plan, result)


def run_report_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(RUN_REPORT_DOMAIN)
    _hash_u64(hash_value, value["abi_version"], "run_report.abi_version")
    for field in (
        "descriptor_sha256",
        "plan_sha256",
        "probe_bundle_sha256",
        "pre_run_bundle_sha256",
        "post_run_bundle_sha256",
        "workload_receipt_sha256",
    ):
        hash_value.update(_digest(value[field], f"run_report.{field}"))
    for field in RUN_REPORT_FIELDS[7:-1]:
        _hash_u64(hash_value, value[field], f"run_report.{field}")
    return hash_value.digest()


def validate_run_report(value: Any) -> Record:
    value = _exact_fields(value, RUN_REPORT_FIELDS, "run report")
    if _u64(value["abi_version"], "run_report.abi") != RUN_REPORT_ABI:
        raise NativeObservationError("run report ABI mismatch")
    for field in ("descriptor_sha256", "plan_sha256"):
        _digest(value[field], f"run_report.{field}", nonzero=True)
    for field in (
        "probe_bundle_sha256",
        "pre_run_bundle_sha256",
        "post_run_bundle_sha256",
        "workload_receipt_sha256",
    ):
        _digest(value[field], f"run_report.{field}")
    decision = _u64(value["decision"], "run_report.decision")
    if decision not in DECISION_NAMES:
        raise NativeObservationError("run report decision is invalid")
    if hmac.compare_digest(value["probe_bundle_sha256"], ZERO_DIGEST) and not (
        decision == DECISION_REJECTED_PRE_RUN
        and value["callback_failure_bits"] & REASON_CALLBACK_PROBE
    ):
        raise NativeObservationError("run report lacks probe evidence")
    if _u64(value["last_phase"], "run_report.last_phase") not in PHASES:
        raise NativeObservationError("run report last phase is invalid")
    invocations = _u64(
        value["workload_invocations"], "run_report.workload_invocations"
    )
    begin = _u64(value["begin_invocations"], "run_report.begin_invocations")
    end = _u64(value["end_invocations"], "run_report.end_invocations")
    if invocations > 1 or begin > 1 or end > begin or invocations > begin:
        raise NativeObservationError("run report invocation counts are invalid")
    for field in RUN_REPORT_FIELDS[11:-1]:
        _u64(value[field], f"run_report.{field}")
    if decision == DECISION_PUBLISHABLE:
        required_nonzero = (
            "pre_run_bundle_sha256",
            "post_run_bundle_sha256",
            "workload_receipt_sha256",
        )
        if (
            invocations != 1
            or begin != 1
            or end != 1
            or any(
                hmac.compare_digest(value[field], ZERO_DIGEST)
                for field in required_nonzero
            )
            or any(value[field] != 0 for field in RUN_REPORT_FIELDS[12:20])
        ):
            raise NativeObservationError("publishable run report is contaminated")
    elif decision == DECISION_REJECTED_PRE_RUN:
        if invocations != 0 or not hmac.compare_digest(
            value["workload_receipt_sha256"], ZERO_DIGEST
        ):
            raise NativeObservationError("pre-run rejection started work")
    elif invocations != 1 or begin != 1 or end != 1:
        raise NativeObservationError("terminal run report counts are invalid")
    if not hmac.compare_digest(
        _digest(value["report_sha256"], "run_report.root"),
        run_report_sha256(value),
    ):
        raise NativeObservationError("run report root mismatch")
    return deepcopy(value)


def make_run_report(
    descriptor: Record,
    plan: Record,
    probe: Record,
    pre_run: Record,
    post_run: Record,
    receipt: Record,
) -> Record:
    pre_time = next(
        record
        for record in pre_run["records"]
        if record["metric"] == METRIC_HOST_MONOTONIC_TIME
    )
    post_time = next(
        record
        for record in post_run["records"]
        if record["metric"] == METRIC_HOST_MONOTONIC_TIME
    )
    if (
        pre_time["availability"] != AVAILABILITY_PRESENT
        or post_time["availability"] != AVAILABILITY_PRESENT
        or not hmac.compare_digest(
            pre_time["value_clock_domain_sha256"],
            post_time["value_clock_domain_sha256"],
        )
        or post_time["value"] < pre_time["value"]
    ):
        raise NativeObservationError("reference monotonic clock regressed")
    elapsed = post_time["value"] - pre_time["value"]
    result = {
        "abi_version": RUN_REPORT_ABI,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "probe_bundle_sha256": probe["bundle_sha256"],
        "pre_run_bundle_sha256": pre_run["bundle_sha256"],
        "post_run_bundle_sha256": post_run["bundle_sha256"],
        "workload_receipt_sha256": receipt["receipt_sha256"],
        "decision": DECISION_PUBLISHABLE,
        "last_phase": PHASE_POST_RUN,
        "workload_invocations": 1,
        "begin_invocations": 1,
        "end_invocations": 1,
        "callback_failure_bits": 0,
        "missing_metric_bits": 0,
        "denied_metric_bits": 0,
        "unsupported_metric_bits": 0,
        "threshold_metric_bits": 0,
        "source_mismatch_bits": 0,
        "subject_mismatch_bits": 0,
        "reason_bits": 0,
        "elapsed_nanoseconds": elapsed,
        "report_sha256": ZERO_DIGEST,
    }
    result["report_sha256"] = run_report_sha256(result)
    return validate_run_report(result)


def reference_report_sha256(value: Mapping[str, Any]) -> Digest:
    hash_value = hashlib.sha256(REFERENCE_REPORT_DOMAIN)
    _hash_u64(hash_value, value["abi_version"], "reference.abi_version")
    for field in REFERENCE_FIELDS[1:9]:
        hash_value.update(_digest(value[field], f"reference.{field}"))
    for field in ("decision", "profile_count", "item_count", "elapsed_nanoseconds"):
        _hash_u64(hash_value, value[field], f"reference.{field}")
    return hash_value.digest()


def validate_reference_report(value: Any) -> Record:
    value = _exact_fields(value, REFERENCE_FIELDS, "reference report")
    if _u64(value["abi_version"], "reference.abi") != REFERENCE_REPORT_ABI:
        raise NativeObservationError("reference report ABI mismatch")
    for field in REFERENCE_FIELDS[1:9]:
        _digest(value[field], f"reference.{field}", nonzero=True)
    if value["decision"] != DECISION_PUBLISHABLE:
        raise NativeObservationError("reference report is not publishable")
    if value["profile_count"] != 3 or value["item_count"] != 6:
        raise NativeObservationError("reference workload shape changed")
    if _u64(value["elapsed_nanoseconds"], "reference.elapsed") == 0:
        raise NativeObservationError("reference elapsed time is zero")
    if not hmac.compare_digest(
        _digest(value["report_sha256"], "reference.root"),
        reference_report_sha256(value),
    ):
        raise NativeObservationError("reference report root mismatch")
    return deepcopy(value)


def reference_descriptor() -> Record:
    metrics = (
        METRIC_HOST_MONOTONIC_TIME,
        METRIC_HOST_LOGICAL_CPU_COUNT,
        METRIC_HOST_EXTERNAL_CPU_PPM,
        METRIC_PROCESS_RESIDENT_BYTES,
        METRIC_HOST_AVAILABLE_MEMORY_BYTES,
        METRIC_HOST_CPU_POWER,
        METRIC_HOST_CPU_TEMPERATURE,
        METRIC_ACCELERATOR_DEVICE_PRESENT,
        METRIC_ACCELERATOR_CPU_FALLBACK,
        METRIC_ACCELERATOR_UTILIZATION,
        METRIC_ACCELERATOR_RESIDENT_BYTES,
        METRIC_ACCELERATOR_POWER,
        METRIC_ACCELERATOR_TEMPERATURE,
        METRIC_ACCELERATOR_DEVICE_TIME,
    )
    unavailable_direct = frozenset(
        (
            METRIC_HOST_CPU_POWER,
            METRIC_HOST_CPU_TEMPERATURE,
            METRIC_ACCELERATOR_UTILIZATION,
            METRIC_ACCELERATOR_RESIDENT_BYTES,
            METRIC_ACCELERATOR_POWER,
            METRIC_ACCELERATOR_TEMPERATURE,
        )
    )
    declared = 0
    direct = 0
    for metric in metrics:
        declared |= metric_bit(metric)
        if metric not in unavailable_direct:
            direct |= metric_bit(metric)
    return make_descriptor(
        0x474E_4F52_0000_0001,
        7,
        declared,
        direct,
        digest_v1("reference observer namespace"),
        digest_v1("reference observer schema"),
    )


def reference_plan(descriptor: Record | None = None) -> Record:
    descriptor = reference_descriptor() if descriptor is None else descriptor
    rules = [
        make_rule(
            METRIC_HOST_MONOTONIC_TIME,
            SCOPE_PRE_RUN,
            PREDICATE_REQUIRE_PRESENT,
        ),
        make_rule(
            METRIC_HOST_MONOTONIC_TIME,
            SCOPE_POST_RUN,
            PREDICATE_REQUIRE_PRESENT,
        ),
        make_rule(
            METRIC_HOST_LOGICAL_CPU_COUNT,
            SCOPE_PRE_RUN,
            PREDICATE_INCLUSIVE_RANGE,
            1,
            4096,
        ),
        make_rule(
            METRIC_HOST_LOGICAL_CPU_COUNT,
            SCOPE_PRE_POST,
            PREDICATE_MAX_ABS_DELTA,
            0,
            0,
        ),
        make_rule(
            METRIC_HOST_EXTERNAL_CPU_PPM,
            SCOPE_PRE_RUN,
            PREDICATE_INCLUSIVE_RANGE,
            0,
            250_000,
        ),
        make_rule(
            METRIC_HOST_EXTERNAL_CPU_PPM,
            SCOPE_POST_RUN,
            PREDICATE_INCLUSIVE_RANGE,
            0,
            250_000,
        ),
    ]
    return make_plan(
        descriptor,
        digest_v1("typed perception 3 profiles 6 items"),
        digest_v1("download-free retained fixture"),
        digest_v1("reference build"),
        digest_v1("reference machine"),
        digest_v1("reference accelerator backend"),
        digest_v1("reference accelerator device"),
        digest_v1("reference accelerator placement"),
        EXECUTION_HOST,
        4,
        3,
        rules,
        digest_v1("reference observation challenge"),
    )


def reference_bundle(
    descriptor: Record,
    plan: Record,
    phase: int,
) -> Record:
    times = {
        PHASE_PROBE: 900,
        PHASE_PRE_RUN: 1_000,
        PHASE_POST_RUN: 2_600,
    }
    try:
        ticks = times[phase]
    except KeyError as error:
        raise NativeObservationError("unsupported reference phase") from error
    clock = digest_v1("reference host clock")
    source = digest_v1("reference host observer source")
    provenance = digest_v1(
        {
            PHASE_PROBE: "reference host probe provenance",
            PHASE_PRE_RUN: "reference host pre-run provenance",
            PHASE_POST_RUN: "reference host post-run provenance",
        }[phase]
    )
    subject = digest_v1("reference host subject")
    unavailable_reasons = {
        METRIC_HOST_CPU_TEMPERATURE: digest_v1(
            "reference host temperature permission denied"
        ),
        METRIC_HOST_CPU_POWER: digest_v1(
            "reference host power unsupported"
        ),
    }
    specifications = [
        (
            METRIC_HOST_MONOTONIC_TIME,
            AVAILABILITY_PRESENT,
            ticks,
        ),
        (
            METRIC_HOST_LOGICAL_CPU_COUNT,
            AVAILABILITY_PRESENT,
            8,
        ),
    ]
    if phase != PHASE_PROBE:
        specifications.extend(
            (
                (
                    METRIC_HOST_EXTERNAL_CPU_PPM,
                    AVAILABILITY_PRESENT,
                    100_000 if phase == PHASE_PRE_RUN else 120_000,
                ),
                (
                    METRIC_PROCESS_RESIDENT_BYTES,
                    AVAILABILITY_PRESENT,
                    4_194_304 if phase == PHASE_PRE_RUN else 4_456_448,
                ),
                (
                    METRIC_HOST_AVAILABLE_MEMORY_BYTES,
                    AVAILABILITY_PRESENT,
                    17_179_869_184
                    if phase == PHASE_PRE_RUN
                    else 17_175_674_880,
                ),
                (
                    METRIC_HOST_CPU_TEMPERATURE,
                    AVAILABILITY_DENIED,
                    0,
                ),
                (
                    METRIC_HOST_CPU_POWER,
                    AVAILABILITY_UNSUPPORTED,
                    0,
                ),
            )
        )
    records = [
        make_observation(
            descriptor,
            plan,
            phase,
            sequence,
            metric,
            availability,
            value,
            ticks,
            clock,
            clock if metric_unit(metric) == UNIT_NANOSECONDS else ZERO_DIGEST,
            source,
            provenance,
            subject,
            ZERO_DIGEST
            if availability == AVAILABILITY_PRESENT
            else unavailable_reasons[metric],
        )
        for sequence, (metric, availability, value) in enumerate(
            specifications,
            start=1,
        )
    ]
    return make_bundle(descriptor, plan, phase, records)


def reference_artifacts() -> Record:
    descriptor = reference_descriptor()
    plan = reference_plan(descriptor)
    probe = reference_bundle(descriptor, plan, PHASE_PROBE)
    pre_run = reference_bundle(descriptor, plan, PHASE_PRE_RUN)
    post_run = reference_bundle(descriptor, plan, PHASE_POST_RUN)
    receipt = make_workload_receipt(
        plan,
        WORKLOAD_SUCCEEDED,
        GATE_PASSED,
        GATE_PASSED,
        FALLBACK_NOT_APPLICABLE,
        3,
        6,
        WORKLOAD_RESULT_SHA256,
        WORKLOAD_CORRECTNESS_SHA256,
        WORKLOAD_OWNERSHIP_SHA256,
    )
    run_report = make_run_report(
        descriptor,
        plan,
        probe,
        pre_run,
        post_run,
        receipt,
    )
    reference = {
        "abi_version": REFERENCE_REPORT_ABI,
        "descriptor_sha256": descriptor["descriptor_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "probe_bundle_sha256": probe["bundle_sha256"],
        "pre_run_bundle_sha256": pre_run["bundle_sha256"],
        "post_run_bundle_sha256": post_run["bundle_sha256"],
        "workload_receipt_sha256": receipt["receipt_sha256"],
        "run_report_sha256": run_report["report_sha256"],
        "workload_result_sha256": receipt["result_sha256"],
        "decision": run_report["decision"],
        "profile_count": receipt["profile_count"],
        "item_count": receipt["item_count"],
        "elapsed_nanoseconds": run_report["elapsed_nanoseconds"],
        "report_sha256": ZERO_DIGEST,
    }
    reference["report_sha256"] = reference_report_sha256(reference)
    reference = validate_reference_report(reference)
    return {
        "descriptor": descriptor,
        "plan": plan,
        "probe": probe,
        "pre_run": pre_run,
        "post_run": post_run,
        "receipt": receipt,
        "run_report": run_report,
        "reference_report": reference,
    }


def build_report() -> Record:
    """Recompute the compact reference report from independent ABI values."""

    reference = reference_artifacts()["reference_report"]
    return {
        "schema": REPORT_SCHEMA,
        "descriptor_abi": f"{DESCRIPTOR_ABI:016x}",
        "rule_abi": f"{RULE_ABI:016x}",
        "plan_abi": f"{PLAN_ABI:016x}",
        "observation_abi": f"{OBSERVATION_ABI:016x}",
        "bundle_abi": f"{BUNDLE_ABI:016x}",
        "workload_receipt_abi": f"{WORKLOAD_RECEIPT_ABI:016x}",
        "run_report_abi": f"{RUN_REPORT_ABI:016x}",
        "reference_report_abi": f"{REFERENCE_REPORT_ABI:016x}",
        "availability": list(AVAILABILITY_NAMES),
        "decision": DECISION_NAMES[reference["decision"]],
        "profile_count": reference["profile_count"],
        "item_count": reference["item_count"],
        "elapsed_nanoseconds": reference["elapsed_nanoseconds"],
        "descriptor_sha256": reference["descriptor_sha256"].hex(),
        "plan_sha256": reference["plan_sha256"].hex(),
        "probe_bundle_sha256": reference["probe_bundle_sha256"].hex(),
        "pre_run_bundle_sha256": reference["pre_run_bundle_sha256"].hex(),
        "post_run_bundle_sha256": reference["post_run_bundle_sha256"].hex(),
        "workload_receipt_sha256": reference["workload_receipt_sha256"].hex(),
        "run_report_sha256": reference["run_report_sha256"].hex(),
        "workload_result_sha256": reference["workload_result_sha256"].hex(),
        "report_sha256": reference["report_sha256"].hex(),
    }


def render_report(report: Record | None = None) -> str:
    """Render exactly one compact canonical ASCII JSON line."""

    report = build_report() if report is None else report
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
        raise NativeObservationError("report is not JSON representable") from error


def validate_report(value: Any) -> Record:
    expected = build_report()
    if (
        not isinstance(value, dict)
        or tuple(value) != REPORT_FIELDS
        or value != expected
        or render_report(value) != render_report(expected)
    ):
        raise NativeObservationError(
            "report contradicts native-observation conformance replay"
        )
    return deepcopy(expected)


def load_json_exact(encoded: bytes, where: str) -> Record:
    """Load one exact canonical compact-ASCII JSON object."""

    if (
        type(encoded) is not bytes
        or not 0 < len(encoded) <= MAXIMUM_JSON_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise NativeObservationError(f"{where} is not one canonical line")

    def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
        result: Record = {}
        for key, value in pairs:
            if key in result:
                raise NativeObservationError(f"{where} contains duplicate fields")
            result[key] = value
        return result

    def invalid_number(_: str) -> None:
        raise NativeObservationError(f"{where} contains a non-integer number")

    try:
        decoded = json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=object_pairs,
            parse_constant=invalid_number,
            parse_float=invalid_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NativeObservationError(f"{where} is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise NativeObservationError(f"{where} is not a JSON object")
    try:
        canonical = (
            json.dumps(
                decoded,
                ensure_ascii=True,
                allow_nan=False,
                separators=(",", ":"),
            ).encode("ascii")
            + b"\n"
        )
    except (TypeError, ValueError) as error:
        raise NativeObservationError(f"{where} is not representable") from error
    if canonical != encoded:
        raise NativeObservationError(f"{where} is not canonical JSON")
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
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(descriptor, "wb") as output:
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


def verify_runner(runner: Path | Sequence[str], fixture: Path) -> None:
    """Fail closed unless fixture, native runner, and oracle agree exactly."""

    if isinstance(runner, Path):
        runner_argv = [str(runner)]
    elif (
        isinstance(runner, Sequence)
        and not isinstance(runner, (str, bytes))
        and runner
        and all(isinstance(value, str) and value for value in runner)
    ):
        runner_argv = list(runner)
    else:
        raise NativeObservationError("invalid native-observation runner command")
    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise NativeObservationError("retained fixture is stale")
    completed = subprocess.run(
        runner_argv,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if completed.returncode != 0 or completed.stderr:
        raise NativeObservationError("native-observation runner failed")
    runner_value = load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise NativeObservationError(
            "native-observation runner contradicts Python oracle"
        )


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify retained W5a native-observation conformance",
    )
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verify_runner(args.runner, args.fixture)
    except (
        OSError,
        subprocess.SubprocessError,
        NativeObservationError,
    ) as error:
        print(f"native-observation-conformance: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
