from __future__ import annotations

import copy
import hashlib
import io
import struct
import subprocess
import unittest
from contextlib import redirect_stdout
from unittest import mock

from bench import native_workload_report as verifier


# This fixture encoder is intentionally independent of the verifier.  The
# constants, semantic hashes, summary derivation, and fixed-layout writer are
# repeated here so that the test does not bless a wire by calling production
# encoding or hashing helpers.
MAGIC = b"GW6RPT01"
SCENARIO_ABI = 0x4757365300000001
RECORD_ABI = 0x4757365200000001
SUMMARY_ABI = 0x4757365500000001
CLOSURE_ABI = 0x4757364300000001
REPORT_ABI = 0x4757365000000001
WIRE_ABI = 0x4757365700000001
HEADER_BYTES = 40
SCENARIO_BYTES = 484
RECORD_BYTES = 772
SUMMARY_BYTES = 1856
CLOSURE_BYTES = 80
WIRE_DIGEST_BYTES = 64
NO_QUEUE_SLOT = 0xFFFFFFFF
ZERO = b"\x00" * 32

SCENARIO_DOMAIN = b"glacier-native-workload-scenario-v1\x00"
RECORD_DOMAIN = b"glacier-native-workload-record-v1\x00"
SUMMARY_DOMAIN = b"glacier-native-workload-summary-v1\x00"
CLOSURE_DOMAIN = b"glacier-native-workload-closure-v1\x00"
REPORT_DOMAIN = b"glacier-native-workload-report-v1\x00"
BODY_DOMAIN = b"glacier-native-workload-body-wire-v1\x00"
FOOTER_DOMAIN = b"glacier-native-workload-footer-wire-v1\x00"
METRIC_REASON_DOMAIN = b"glacier-native-workload-metric-unsupported-v1\x00"
AGGREGATE_REASON_DOMAIN = (
    b"glacier-native-workload-metric-aggregate-reason-v1\x00"
)

EVENT_ADMISSION = 1 << 1
EVENT_FIRST_SERVICE = 1 << 2
EVENT_SUBMIT_RETURN = 1 << 3
EVENT_FIRST_OUTPUT = 1 << 4
EVENT_ALL = 0x7F
EVENT_REJECTED = 0x61
MEASURED = 1
COMPLETED = 0
CAPACITY_REJECTED = 1
FAILED = 2
TIMED_OUT = 4
PRESENT = 3
MISSING = 0
UNSUPPORTED = 2


def _u8(value: int) -> bytes:
    return struct.pack("<B", value)


def _u32(value: int) -> bytes:
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def _f64_bits(value: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def _hash(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _test_digest(tag: int, ordinal: int) -> bytes:
    return hashlib.sha256(_u8(tag) + _u32(ordinal)).digest()


def _scenario() -> dict:
    value = {
        "abi": SCENARIO_ABI,
        "mode": 0,
        "evidence": 0,
        "algorithm": 0,
        "warmup": 2,
        "measured": 4,
        "max_in_flight": 2,
        "queue_count": 2,
        "flow_count": 2,
        "identities": [_test_digest(tag, 0) for tag in range(1, 14)],
    }
    value["sha"] = _scenario_sha(value)
    return value


def _scenario_sha(value: dict) -> bytes:
    return _hash(
        SCENARIO_DOMAIN,
        _u64(value["abi"]),
        _u8(value["mode"]),
        _u8(value["evidence"]),
        _u8(value["algorithm"]),
        _u32(value["warmup"]),
        _u32(value["measured"]),
        _u32(value["max_in_flight"]),
        _u32(value["queue_count"]),
        _u32(value["flow_count"]),
        *value["identities"],
    )


def _encode_scenario(value: dict) -> bytes:
    encoded = b"".join(
        (
            _u64(value["abi"]),
            _u8(value["mode"]),
            _u8(value["evidence"]),
            _u8(value["algorithm"]),
            b"\x00",
            _u32(value["warmup"]),
            _u32(value["measured"]),
            _u32(value["max_in_flight"]),
            _u32(value["queue_count"]),
            _u32(value["flow_count"]),
            b"\x00" * 4,
            *value["identities"],
            value["sha"],
        )
    )
    if len(encoded) != SCENARIO_BYTES:
        raise AssertionError("bad independent scenario layout")
    return encoded


def _completed(
    scenario: dict,
    ordinal: int,
    cohort: int,
    flow_id: int,
    timestamps: list[int],
    sequences: list[int],
) -> dict:
    start = 10.0 + ordinal
    end = start + 0.000001
    start_bits = _f64_bits(start)
    end_bits = _f64_bits(end)
    duration = int((end - start) * 1_000_000_000.0)
    return {
        "abi": RECORD_ABI,
        "ordinal": ordinal,
        "cohort": cohort,
        "outcome": COMPLETED,
        "correctness": 1,
        "fallback": False,
        "flow_id": flow_id,
        "work_units": 10,
        "queue": flow_id,
        "mask": EVENT_ALL,
        "points": list(zip(timestamps, sequences)),
        "roots": [
            _test_digest(tag, ordinal) for tag in range(20, 29)
        ],
        "maximum_error": _f64_bits(0.001),
        "device": {
            "availability": PRESENT,
            "start": start_bits,
            "end": end_bits,
            "duration": duration,
            "source": scenario["identities"][10],
            "clock": scenario["identities"][11],
            "reason": ZERO,
        },
        "allocation": {
            "availability": PRESENT,
            "before": 4096 + ordinal,
            "after": 4112 + ordinal,
            "source": scenario["identities"][10],
            "reason": ZERO,
        },
        "logical": [1, 1, 100, 100, 1, 0, 1, 0, 1, 0],
        "previous": ZERO,
        "sha": ZERO,
    }


def _unavailable_device(scenario: dict, ordinal: int) -> dict:
    return {
        "availability": UNSUPPORTED,
        "start": 0,
        "end": 0,
        "duration": 0,
        "source": scenario["identities"][10],
        "clock": scenario["identities"][11],
        "reason": _test_digest(30, ordinal),
    }


def _unavailable_allocation(scenario: dict, ordinal: int) -> dict:
    return {
        "availability": UNSUPPORTED,
        "before": 0,
        "after": 0,
        "source": scenario["identities"][10],
        "reason": _test_digest(31, ordinal),
    }


def _rejected(scenario: dict, ordinal: int) -> dict:
    roots = [ZERO] * 9
    roots[0] = _test_digest(20, ordinal)
    roots[7] = _test_digest(27, ordinal)
    roots[8] = _test_digest(28, ordinal)
    return {
        "abi": RECORD_ABI,
        "ordinal": ordinal,
        "cohort": MEASURED,
        "outcome": CAPACITY_REJECTED,
        "correctness": 0,
        "fallback": False,
        "flow_id": 0,
        "work_units": 10,
        "queue": NO_QUEUE_SLOT,
        "mask": EVENT_REJECTED,
        "points": [
            (1030, 38),
            (0, 0),
            (0, 0),
            (0, 0),
            (0, 0),
            (1031, 39),
            (1031, 40),
        ],
        "roots": roots,
        "maximum_error": 0,
        "device": _unavailable_device(scenario, ordinal),
        "allocation": _unavailable_allocation(scenario, ordinal),
        "logical": [0] * 10,
        "previous": ZERO,
        "sha": ZERO,
    }


def _timed_out(scenario: dict, ordinal: int) -> dict:
    roots = [ZERO] * 9
    for index, tag in (
        (0, 20),
        (1, 21),
        (2, 22),
        (3, 23),
        (4, 24),
        (7, 27),
        (8, 28),
    ):
        roots[index] = _test_digest(tag, ordinal)
    return {
        "abi": RECORD_ABI,
        "ordinal": ordinal,
        "cohort": MEASURED,
        "outcome": TIMED_OUT,
        "correctness": 0,
        "fallback": False,
        "flow_id": 0,
        "work_units": 10,
        "queue": 0,
        "mask": EVENT_ALL & ~EVENT_FIRST_OUTPUT,
        "points": [
            (1040, 41),
            (1041, 42),
            (1042, 43),
            (1043, 44),
            (0, 0),
            (1045, 45),
            (1046, 46),
        ],
        "roots": roots,
        "maximum_error": 0,
        "device": _unavailable_device(scenario, ordinal),
        "allocation": _unavailable_allocation(scenario, ordinal),
        "logical": [1, 1, 100, 100, 1, 0, 1, 0, 1, 0],
        "previous": ZERO,
        "sha": ZERO,
    }


def _records(scenario: dict) -> list[dict]:
    return [
        _completed(
            scenario,
            0,
            0,
            0,
            [100] * 7,
            [1, 2, 3, 4, 5, 6, 7],
        ),
        _completed(
            scenario,
            1,
            0,
            1,
            [200, 201, 202, 203, 204, 205, 206],
            [8, 9, 10, 11, 12, 13, 14],
        ),
        _completed(
            scenario,
            2,
            1,
            0,
            [1000, 1001, 1002, 1003, 1010, 1012, 1016],
            [20, 21, 22, 23, 30, 32, 36],
        ),
        _completed(
            scenario,
            3,
            1,
            1,
            [1004, 1005, 1006, 1007, 1011, 1013, 1017],
            [24, 25, 26, 27, 31, 33, 37],
        ),
        _rejected(scenario, 4),
        _timed_out(scenario, 5),
    ]


def _make_failed_without_admission(records: list[dict]) -> None:
    records[4]["outcome"] = FAILED


def _make_admitted_without_submit(records: list[dict]) -> None:
    record = records[5]
    record["mask"] = 0x63
    record["points"][2] = (0, 0)
    record["points"][3] = (0, 0)
    roots = [ZERO] * 9
    roots[0] = _test_digest(20, 5)
    roots[2] = _test_digest(22, 5)
    roots[7] = _test_digest(27, 5)
    roots[8] = _test_digest(28, 5)
    record["roots"] = roots
    record["logical"][6] = 0
    record["logical"][8] = 0


def _record_sha(scenario_sha: bytes, value: dict) -> bytes:
    logical = value["logical"]
    parts = [
        scenario_sha,
        _u64(value["abi"]),
        _u32(value["ordinal"]),
        _u8(value["cohort"]),
        _u8(value["outcome"]),
        _u8(value["correctness"]),
        _u8(int(value["fallback"])),
        _u32(value["flow_id"]),
        _u64(value["work_units"]),
        _u32(value["queue"]),
        _u8(value["mask"]),
    ]
    for ns, sequence in value["points"]:
        parts.extend((_u64(ns), _u64(sequence)))
    parts.extend(value["roots"])
    device = value["device"]
    allocation = value["allocation"]
    parts.extend(
        (
            _u64(value["maximum_error"]),
            _u8(device["availability"]),
            _u64(device["start"]),
            _u64(device["end"]),
            _u64(device["duration"]),
            device["source"],
            device["clock"],
            device["reason"],
            _u8(allocation["availability"]),
            _u64(allocation["before"]),
            _u64(allocation["after"]),
            allocation["source"],
            allocation["reason"],
            _u32(logical[0]),
            _u32(logical[1]),
            _u64(logical[2]),
            _u64(logical[3]),
            _u32(logical[4]),
            _u32(logical[5]),
            _u32(logical[6]),
            _u32(logical[7]),
            _u32(logical[8]),
            _u32(logical[9]),
            value["previous"],
        )
    )
    return _hash(RECORD_DOMAIN, *parts)


def _seal_records(scenario: dict, records: list[dict]) -> None:
    previous = scenario["sha"]
    for record in records:
        record["previous"] = previous
        record["sha"] = _record_sha(scenario["sha"], record)
        previous = record["sha"]


def _encode_record(value: dict) -> bytes:
    device = value["device"]
    allocation = value["allocation"]
    logical = value["logical"]
    parts = [
        _u64(value["abi"]),
        _u32(value["ordinal"]),
        _u8(value["cohort"]),
        _u8(value["outcome"]),
        _u8(value["correctness"]),
        _u8(int(value["fallback"])),
        _u32(value["flow_id"]),
        _u64(value["work_units"]),
        _u32(value["queue"]),
        _u8(value["mask"]),
        b"\x00" * 3,
    ]
    for ns, sequence in value["points"]:
        parts.extend((_u64(ns), _u64(sequence)))
    parts.extend(value["roots"])
    parts.extend(
        (
            _u64(value["maximum_error"]),
            _u8(device["availability"]),
            b"\x00" * 7,
            _u64(device["start"]),
            _u64(device["end"]),
            _u64(device["duration"]),
            device["source"],
            device["clock"],
            device["reason"],
            _u8(allocation["availability"]),
            b"\x00" * 7,
            _u64(allocation["before"]),
            _u64(allocation["after"]),
            allocation["source"],
            allocation["reason"],
            _u32(logical[0]),
            _u32(logical[1]),
            _u64(logical[2]),
            _u64(logical[3]),
            _u32(logical[4]),
            _u32(logical[5]),
            _u32(logical[6]),
            _u32(logical[7]),
            _u32(logical[8]),
            _u32(logical[9]),
            value["previous"],
            value["sha"],
        )
    )
    encoded = b"".join(parts)
    if len(encoded) != RECORD_BYTES:
        raise AssertionError("bad independent record layout")
    return encoded


def _nearest(values: list[int], percentile: int) -> int:
    ordered = sorted(values)
    rank = (percentile * len(ordered) + 99) // 100
    return ordered[rank - 1]


def _distribution(values: list[int]) -> list[int]:
    if not values:
        return [0, 0, 0, 0, 0]
    return [
        len(values),
        _nearest(values, 50),
        _nearest(values, 95),
        _nearest(values, 99),
        _nearest(values, 100),
    ]


def _aggregate_reason(kind: int, reason: int) -> bytes:
    return _hash(AGGREGATE_REASON_DOMAIN, _u8(kind), _u8(reason))


def _aggregate(records: list[dict], plane: str) -> tuple[int, bytes]:
    eligible = []
    for record in records:
        if record["cohort"] != MEASURED:
            continue
        eligibility_bit = (
            EVENT_SUBMIT_RETURN if plane == "device" else EVENT_ADMISSION
        )
        if not record["mask"] & eligibility_bit:
            continue
        eligible.append(record[plane])
    kind = 2 if plane == "device" else 3
    if not eligible:
        return (MISSING, _aggregate_reason(kind, 1))
    present_count = sum(
        value["availability"] == PRESENT for value in eligible
    )
    if present_count == len(eligible):
        return (PRESENT, ZERO)
    unavailable = [
        value
        for value in eligible
        if value["availability"] != PRESENT
    ]
    homogeneous = all(
        value["availability"] == unavailable[0]["availability"]
        and value["reason"] == unavailable[0]["reason"]
        for value in unavailable
    )
    if present_count == 0 and homogeneous:
        return (
            unavailable[0]["availability"],
            unavailable[0]["reason"],
        )
    return (MISSING, _aggregate_reason(kind, 2))


def _metric_domains(scenario: dict, kind: int) -> tuple[bytes, bytes]:
    if kind in (0, 1):
        return (scenario["identities"][8], scenario["identities"][9])
    if kind == 3:
        return (scenario["identities"][10], scenario["identities"][9])
    return (scenario["identities"][10], scenario["identities"][11])


def _unsupported_metric(scenario: dict, kind: int) -> dict:
    source, clock = _metric_domains(scenario, kind)
    return {
        "kind": kind,
        "availability": UNSUPPORTED,
        "numerator": 0,
        "denominator": 0,
        "source": source,
        "clock": clock,
        "reason": _hash(METRIC_REASON_DOMAIN, _u8(kind)),
    }


def _summary(scenario: dict, records: list[dict]) -> dict:
    measured = [
        record for record in records if record["cohort"] == MEASURED
    ]
    counts = [0] * 5
    for record in measured:
        counts[record["outcome"]] += 1
    interval_start = min(record["points"][0][0] for record in measured)
    interval_end = max(record["points"][6][0] for record in measured)
    interval = interval_end - interval_start
    admitted = sum(bool(record["mask"] & EVENT_ADMISSION) for record in measured)

    latency = {
        "admission": [
            record["points"][1][0] - record["points"][0][0]
            for record in measured
            if record["mask"] & EVENT_ADMISSION
        ],
        "queue": [
            record["points"][2][0] - record["points"][1][0]
            for record in measured
            if record["mask"] & EVENT_FIRST_SERVICE
        ],
        "first_output": [
            record["points"][4][0] - record["points"][0][0]
            for record in measured
            if record["mask"] & EVENT_FIRST_OUTPUT
        ],
        "service": [
            record["points"][5][0] - record["points"][2][0]
            for record in measured
            if record["mask"] & EVENT_FIRST_SERVICE
        ],
        "end_to_end": [
            record["points"][6][0] - record["points"][0][0]
            for record in measured
        ],
        "device": [
            record["device"]["duration"]
            for record in measured
            if record["device"]["availability"] == PRESENT
        ],
    }
    high_water = 0
    for candidate in measured:
        if not candidate["mask"] & EVENT_ADMISSION:
            continue
        sequence = candidate["points"][1][1]
        active = sum(
            record["points"][1][1]
            <= sequence
            < record["points"][6][1]
            for record in measured
            if record["mask"] & EVENT_ADMISSION
        )
        high_water = max(high_water, active)
    flow_counts = [
        sum(
            record["flow_id"] == flow
            and record["outcome"] == COMPLETED
            for record in measured
        )
        for flow in range(scenario["flow_count"])
    ]
    device_availability, device_reason = _aggregate(records, "device")
    allocation_availability, allocation_reason = _aggregate(
        records, "allocation"
    )
    allocation_max = max(
        (
            max(
                record["allocation"]["before"],
                record["allocation"]["after"],
            )
            for record in measured
            if record["mask"] & EVENT_ADMISSION
            and record["allocation"]["availability"] == PRESENT
        ),
        default=0,
    )
    allocation_max_available = allocation_availability == PRESENT
    if not allocation_max_available:
        allocation_max = 0
    device_total = sum(
        record["device"]["duration"]
        for record in measured
        if record["mask"] & EVENT_SUBMIT_RETURN
        and record["device"]["availability"] == PRESENT
    )
    metrics = [
        _unsupported_metric(scenario, kind) for kind in range(12)
    ]
    source, clock = _metric_domains(scenario, 2)
    metrics[2] = {
        "kind": 2,
        "availability": device_availability,
        "numerator": device_total if device_availability == PRESENT else 0,
        "denominator": 1 if device_availability == PRESENT else 0,
        "source": source,
        "clock": clock,
        "reason": ZERO if device_availability == PRESENT else device_reason,
    }
    source, clock = _metric_domains(scenario, 3)
    metrics[3] = {
        "kind": 3,
        "availability": allocation_availability,
        "numerator": allocation_max if allocation_availability == PRESENT else 0,
        "denominator": 1 if allocation_availability == PRESENT else 0,
        "source": source,
        "clock": clock,
        "reason": (
            ZERO
            if allocation_availability == PRESENT
            else allocation_reason
        ),
    }
    completed_work = sum(
        record["work_units"]
        for record in measured
        if record["outcome"] == COMPLETED
    )
    value = {
        "abi": SUMMARY_ABI,
        "measured": len(measured),
        "admitted": admitted,
        "counts": counts,
        "attempted_work": sum(record["work_units"] for record in measured),
        "completed_work": completed_work,
        "interval_start": interval_start,
        "interval_end": interval_end,
        "interval_numerator": interval,
        "interval_denominator": 1,
        "throughput_numerator": completed_work,
        "throughput_denominator": interval,
        "distributions": [
            _distribution(latency["admission"]),
            _distribution(latency["queue"]),
            _distribution(latency["first_output"]),
            _distribution(latency["service"]),
            _distribution(latency["end_to_end"]),
            _distribution(latency["device"]),
        ],
        "high_water": high_water,
        "flow_min": min(flow_counts),
        "flow_max": max(flow_counts),
        "flow_spread": max(flow_counts) - min(flow_counts),
        "fallback": sum(record["fallback"] for record in measured),
        "correct": sum(record["correctness"] == 1 for record in measured),
        "incorrect": sum(record["correctness"] == 2 for record in measured),
        "allocation_max_available": allocation_max_available,
        "allocation_max": allocation_max,
        "metrics": metrics,
        "sha": ZERO,
    }
    value["sha"] = _summary_sha(value)
    return value


def _distribution_hash_parts(value: list[int]) -> tuple[bytes, ...]:
    return (
        _u32(value[0]),
        _u64(value[1]),
        _u64(value[2]),
        _u64(value[3]),
        _u64(value[4]),
    )


def _metric_hash_parts(value: dict) -> tuple[bytes, ...]:
    return (
        _u8(value["kind"]),
        _u8(value["availability"]),
        _u64(value["numerator"]),
        _u64(value["denominator"]),
        value["source"],
        value["clock"],
        value["reason"],
    )


def _summary_sha(value: dict) -> bytes:
    parts = [
        _u64(value["abi"]),
        _u32(value["measured"]),
        _u32(value["admitted"]),
        *(_u32(count) for count in value["counts"]),
        _u64(value["attempted_work"]),
        _u64(value["completed_work"]),
        _u64(value["interval_start"]),
        _u64(value["interval_end"]),
        _u64(value["interval_numerator"]),
        _u64(value["interval_denominator"]),
        _u64(value["throughput_numerator"]),
        _u64(value["throughput_denominator"]),
    ]
    for distribution in value["distributions"]:
        parts.extend(_distribution_hash_parts(distribution))
    parts.extend(
        (
            _u32(value["high_water"]),
            _u32(value["flow_min"]),
            _u32(value["flow_max"]),
            _u32(value["flow_spread"]),
            _u32(value["fallback"]),
            _u32(value["correct"]),
            _u32(value["incorrect"]),
            _u8(int(value["allocation_max_available"])),
            _u64(value["allocation_max"]),
        )
    )
    for metric in value["metrics"]:
        parts.extend(_metric_hash_parts(metric))
    return _hash(SUMMARY_DOMAIN, *parts)


def _encode_distribution(value: list[int]) -> bytes:
    return b"".join(
        (
            _u32(value[0]),
            b"\x00" * 4,
            _u64(value[1]),
            _u64(value[2]),
            _u64(value[3]),
            _u64(value[4]),
        )
    )


def _encode_metric(value: dict) -> bytes:
    return b"".join(
        (
            _u8(value["kind"]),
            _u8(value["availability"]),
            b"\x00" * 6,
            _u64(value["numerator"]),
            _u64(value["denominator"]),
            value["source"],
            value["clock"],
            value["reason"],
        )
    )


def _encode_summary(value: dict) -> bytes:
    parts = [
        _u64(value["abi"]),
        _u32(value["measured"]),
        _u32(value["admitted"]),
        *(_u32(count) for count in value["counts"]),
        _u64(value["attempted_work"]),
        _u64(value["completed_work"]),
        _u64(value["interval_start"]),
        _u64(value["interval_end"]),
        _u64(value["interval_numerator"]),
        _u64(value["interval_denominator"]),
        _u64(value["throughput_numerator"]),
        _u64(value["throughput_denominator"]),
    ]
    parts.extend(
        _encode_distribution(value)
        for value in value["distributions"]
    )
    parts.extend(
        (
            _u32(value["high_water"]),
            _u32(value["flow_min"]),
            _u32(value["flow_max"]),
            _u32(value["flow_spread"]),
            _u32(value["fallback"]),
            _u32(value["correct"]),
            _u32(value["incorrect"]),
            _u8(int(value["allocation_max_available"])),
            b"\x00" * 7,
            _u64(value["allocation_max"]),
        )
    )
    parts.extend(_encode_metric(metric) for metric in value["metrics"])
    parts.append(value["sha"])
    encoded = b"".join(parts)
    if len(encoded) != SUMMARY_BYTES:
        raise AssertionError("bad independent summary layout")
    return encoded


def _closure(records: list[dict]) -> dict:
    value = {
        "abi": CLOSURE_ABI,
        "bank_count": 0,
        "pin_count": 0,
        "dispatch_count": 0,
        "command_count": 0,
        "buffer_count": 0,
        "acquisitions": sum(record["logical"][0] for record in records),
        "completions": sum(record["logical"][1] for record in records),
        "zero_orphan": True,
        "sha": ZERO,
    }
    value["sha"] = _closure_sha(value)
    return value


def _closure_sha(value: dict) -> bytes:
    return _hash(
        CLOSURE_DOMAIN,
        _u64(value["abi"]),
        _u32(value["bank_count"]),
        _u32(value["pin_count"]),
        _u32(value["dispatch_count"]),
        _u32(value["command_count"]),
        _u32(value["buffer_count"]),
        _u64(value["acquisitions"]),
        _u64(value["completions"]),
        _u8(int(value["zero_orphan"])),
    )


def _encode_closure(value: dict) -> bytes:
    encoded = b"".join(
        (
            _u64(value["abi"]),
            _u32(value["bank_count"]),
            _u32(value["pin_count"]),
            _u32(value["dispatch_count"]),
            _u32(value["command_count"]),
            _u32(value["buffer_count"]),
            _u64(value["acquisitions"]),
            _u64(value["completions"]),
            _u8(int(value["zero_orphan"])),
            b"\x00" * 3,
            value["sha"],
        )
    )
    if len(encoded) != CLOSURE_BYTES:
        raise AssertionError("bad independent closure layout")
    return encoded


def _fixture(
    record_mutator=None,
    summary_mutator=None,
) -> bytes:
    scenario = _scenario()
    records = _records(scenario)
    if record_mutator is not None:
        record_mutator(records)
    _seal_records(scenario, records)
    summary = _summary(scenario, records)
    if summary_mutator is not None:
        summary_mutator(summary)
        summary["sha"] = _summary_sha(summary)
    closure = _closure(records)
    report_sha = _hash(
        REPORT_DOMAIN,
        _u64(REPORT_ABI),
        scenario["sha"],
        _u32(len(records)),
        records[-1]["sha"],
        summary["sha"],
        closure["sha"],
    )
    body = b"".join(
        (
            _encode_scenario(scenario),
            *(_encode_record(record) for record in records),
            _encode_summary(summary),
            _encode_closure(closure),
            report_sha,
        )
    )
    length = HEADER_BYTES + len(body) + WIRE_DIGEST_BYTES
    header = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(length),
            _u32(1),
            b"\x00" * 4,
            _u32(len(records)),
            b"\x00" * 4,
        )
    )
    body_digest = _hash(BODY_DOMAIN, body)
    prefix = header + body + body_digest
    return prefix + _hash(FOOTER_DOMAIN, prefix)


def _reseal_outer(encoded: bytes) -> bytes:
    value = bytearray(encoded)
    body_end = len(value) - WIRE_DIGEST_BYTES
    value[body_end : body_end + 32] = _hash(
        BODY_DOMAIN, bytes(value[HEADER_BYTES:body_end])
    )
    value[body_end + 32 :] = _hash(
        FOOTER_DOMAIN, bytes(value[: body_end + 32])
    )
    return bytes(value)


class NativeWorkloadReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.encoded = _fixture()

    def assertRejected(self, encoded: bytes) -> None:
        with self.assertRaises(verifier.VerificationError):
            verifier.verify_wire(encoded)

    def test_independent_canonical_fixture_verifies(self) -> None:
        self.assertEqual(len(self.encoded), 7188)
        self.assertEqual(
            hashlib.sha256(self.encoded).hexdigest(),
            "7b61707818f7a4acc0f3f66ee2c8d729"
            "9a3e1fffc4336ae3fc9d34e11c56d954",
        )
        result = verifier.verify_wire(self.encoded)
        self.assertEqual(result.record_count, 6)
        self.assertEqual(result.warmup_count, 2)
        self.assertEqual(result.measured_count, 4)

    def test_truncation_extension_and_every_byte_mutation_reject(self) -> None:
        self.assertRejected(self.encoded[:-1])
        self.assertRejected(self.encoded + b"\x00")
        for offset in range(len(self.encoded)):
            mutated = bytearray(self.encoded)
            mutated[offset] ^= 1
            with self.subTest(offset=offset):
                self.assertRejected(bytes(mutated))

    def test_reordered_and_duplicated_records_reject_after_outer_reseal(
        self,
    ) -> None:
        first = HEADER_BYTES + SCENARIO_BYTES
        reordered = bytearray(self.encoded)
        first_record = bytes(reordered[first : first + RECORD_BYTES])
        second = first + RECORD_BYTES
        reordered[first : first + RECORD_BYTES] = reordered[
            second : second + RECORD_BYTES
        ]
        reordered[second : second + RECORD_BYTES] = first_record
        self.assertRejected(_reseal_outer(bytes(reordered)))

        duplicated = bytearray(self.encoded)
        record_two = first + 2 * RECORD_BYTES
        record_three = first + 3 * RECORD_BYTES
        duplicated[record_three : record_three + RECORD_BYTES] = duplicated[
            record_two : record_two + RECORD_BYTES
        ]
        self.assertRejected(_reseal_outer(bytes(duplicated)))

    def test_forged_summary_and_physical_metric_reject(self) -> None:
        def corrupt_count(summary: dict) -> None:
            summary["counts"][COMPLETED] += 1

        self.assertRejected(_fixture(summary_mutator=corrupt_count))

        def claim_physical_parallelism(summary: dict) -> None:
            metric = summary["metrics"][11]
            metric["availability"] = PRESENT
            metric["numerator"] = 2
            metric["denominator"] = 1
            metric["reason"] = ZERO

        self.assertRejected(
            _fixture(summary_mutator=claim_physical_parallelism)
        )

    def test_duration_availability_root_and_terminal_facts_reject(self) -> None:
        def corrupt_duration(records: list[dict]) -> None:
            records[2]["device"]["duration"] += 1

        self.assertRejected(_fixture(record_mutator=corrupt_duration))

        def corrupt_availability(records: list[dict]) -> None:
            records[2]["device"]["availability"] = UNSUPPORTED

        self.assertRejected(_fixture(record_mutator=corrupt_availability))

        def remove_completed_root(records: list[dict]) -> None:
            records[2]["roots"][5] = ZERO

        self.assertRejected(_fixture(record_mutator=remove_completed_root))

        def leave_pin_live(records: list[dict]) -> None:
            records[2]["logical"][5] = 1

        self.assertRejected(_fixture(record_mutator=leave_pin_live))

        def change_bank_usage(records: list[dict]) -> None:
            records[2]["logical"][3] += 1

        self.assertRejected(_fixture(record_mutator=change_bank_usage))

        def leave_dispatch_live(records: list[dict]) -> None:
            records[2]["logical"][7] = 1

        self.assertRejected(_fixture(record_mutator=leave_dispatch_live))

        def leave_command_live(records: list[dict]) -> None:
            records[2]["logical"][9] = 1

        self.assertRejected(_fixture(record_mutator=leave_command_live))

        def cross_record_cancellation(records: list[dict]) -> None:
            records[2]["logical"][1] = 0
            records[3]["logical"][1] = 2

        self.assertRejected(
            _fixture(record_mutator=cross_record_cancellation)
        )

    def test_campaign_and_eligibility_mutations_reject(self) -> None:
        def contradict_global_time(records: list[dict]) -> None:
            _, sequence = records[3]["points"][0]
            records[3]["points"][0] = (999, sequence)

        self.assertRejected(_fixture(record_mutator=contradict_global_time))

        def reverse_adjacent_arrivals(records: list[dict]) -> None:
            records[3]["points"][0] = (1000, 19)

        self.assertRejected(_fixture(record_mutator=reverse_adjacent_arrivals))

        def overlap_warmup_and_measurement(records: list[dict]) -> None:
            records[1]["points"][6] = (1008, 28)

        self.assertRejected(
            _fixture(record_mutator=overlap_warmup_and_measurement)
        )

        def overlap_queue_slot(records: list[dict]) -> None:
            records[3]["queue"] = records[2]["queue"]

        self.assertRejected(_fixture(record_mutator=overlap_queue_slot))

        def rejected_fallback(records: list[dict]) -> None:
            records[4]["fallback"] = True

        self.assertRejected(_fixture(record_mutator=rejected_fallback))

        def present_timing_without_submit(records: list[dict]) -> None:
            records[4]["device"] = copy.deepcopy(records[2]["device"])

        self.assertRejected(
            _fixture(record_mutator=present_timing_without_submit)
        )

        def present_allocation_without_admission(
            records: list[dict],
        ) -> None:
            records[4]["allocation"] = copy.deepcopy(
                records[2]["allocation"]
            )

        self.assertRejected(
            _fixture(record_mutator=present_allocation_without_admission)
        )

        def admitted_without_acquisition(records: list[dict]) -> None:
            records[5]["logical"][0] = 0
            records[5]["logical"][1] = 0

        self.assertRejected(
            _fixture(record_mutator=admitted_without_acquisition)
        )

    def test_device_aggregation_eligibility_is_submit(self) -> None:
        def valid_admitted_without_submit(records: list[dict]) -> None:
            _make_admitted_without_submit(records)

        result = verifier.verify_wire(
            _fixture(record_mutator=valid_admitted_without_submit)
        )
        self.assertEqual(result.record_count, 6)

    def test_logical_before_counts_require_event_eligibility(self) -> None:
        self.assertEqual(
            verifier.verify_wire(
                _fixture(record_mutator=_make_failed_without_admission)
            ).record_count,
            6,
        )

        def pin_without_admission(records: list[dict]) -> None:
            _make_failed_without_admission(records)
            records[4]["logical"][4] = 1

        self.assertRejected(_fixture(record_mutator=pin_without_admission))

        def dispatch_without_submit(records: list[dict]) -> None:
            _make_admitted_without_submit(records)
            records[5]["logical"][6] = 1

        self.assertRejected(
            _fixture(record_mutator=dispatch_without_submit)
        )

        def command_without_submit(records: list[dict]) -> None:
            _make_admitted_without_submit(records)
            records[5]["logical"][8] = 1

        self.assertRejected(_fixture(record_mutator=command_without_submit))

    def test_partial_device_telemetry_does_not_sum_unused_total(self) -> None:
        def overflowing_present_subset(records: list[dict]) -> None:
            end = 10_000_000_000.0
            duration = int(end * 1_000_000_000.0)
            self.assertLess(duration, 1 << 64)
            self.assertGreater(duration * 2, (1 << 64) - 1)
            for record in records[2:4]:
                record["device"]["start"] = _f64_bits(0.0)
                record["device"]["end"] = _f64_bits(end)
                record["device"]["duration"] = duration

        result = verifier.verify_wire(
            _fixture(record_mutator=overflowing_present_subset)
        )
        self.assertEqual(result.record_count, 6)

    def test_runner_contract_uses_only_raw_stdout(self) -> None:
        completed = subprocess.CompletedProcess(
            ["fixture-runner"], 0, self.encoded, b""
        )
        with mock.patch.object(
            verifier.subprocess, "run", return_value=completed
        ) as run:
            result = verifier.verify_runner(
                "fixture-runner",
                hashlib.sha256(self.encoded).digest(),
            )
        self.assertEqual(result.record_count, 6)
        run.assert_called_once_with(
            ["fixture-runner"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=verifier.RUNNER_TIMEOUT_SECONDS,
        )

        with mock.patch.object(
            verifier.subprocess, "run", return_value=completed
        ):
            with self.assertRaises(verifier.VerificationError):
                verifier.verify_runner(
                    "fixture-runner",
                    b"\xff" * 32,
                )

        for returncode, stderr in ((1, b""), (0, b"diagnostic\n")):
            with self.subTest(returncode=returncode, stderr=stderr):
                failed = subprocess.CompletedProcess(
                    ["fixture-runner"],
                    returncode,
                    self.encoded,
                    stderr,
                )
                with mock.patch.object(
                    verifier.subprocess, "run", return_value=failed
                ):
                    with self.assertRaises(verifier.VerificationError):
                        verifier.verify_runner("fixture-runner")

        with mock.patch.object(
            verifier.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(
                ["fixture-runner"],
                verifier.RUNNER_TIMEOUT_SECONDS,
            ),
        ):
            with self.assertRaises(verifier.VerificationError):
                verifier.verify_runner("fixture-runner")

    def test_cli_success_is_one_concise_line(self) -> None:
        result = verifier.VerificationResult(6, 2, 4, bytes(range(32)))
        output = io.StringIO()
        with mock.patch.object(
            verifier,
            "verify_runner",
            return_value=result,
        ) as verify_runner, redirect_stdout(output):
            self.assertEqual(
                verifier._main(["--runner", "fixture-runner"]), 0
            )
        verify_runner.assert_called_once_with("fixture-runner", None)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("ok native-workload-report-v1 "))


if __name__ == "__main__":
    unittest.main()
