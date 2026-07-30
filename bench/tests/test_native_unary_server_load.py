from __future__ import annotations

import copy
from dataclasses import replace
import hashlib
import io
import os
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from bench import native_unary_server_load as load


def _seal_structural_outer(
    profile_name: str = load.SUCCESSFUL_PROFILE_NAME,
) -> bytes:
    campaign = load._campaign_profile(profile_name)
    sidecars = []
    for ordinal in range(load.RECORD_COUNT):
        encoded_sidecar = load.SIDECAR_STRUCT.pack(
            ordinal,
            0,
            *([0] * 11),
            0,
            0,
            0,
            0,
            0,
            load.ZERO_DIGEST,
            load.ZERO_DIGEST,
            load.ZERO_DIGEST,
            load.ZERO_DIGEST,
            load.ZERO_DIGEST,
            load.ZERO_DIGEST,
        )
        if campaign.has_open_loop_schedule:
            encoded_sidecar += load.OPEN_LOOP_SCHEDULE_STRUCT.pack(
                ordinal,
                (
                    load.OPEN_LOOP_PHASE_WARMUP
                    if ordinal < load.WARMUP_COUNT
                    else load.OPEN_LOOP_PHASE_BASELINE
                ),
                (
                    0
                    if ordinal < load.WARMUP_COUNT
                    else load.OPEN_LOOP_SCHEDULE_FLAG_MEASURED
                ),
                0,
                0,
                0,
                0,
            )
        sidecars.append(encoded_sidecar)
    body = (
        b"".join(sidecars)
        + b"\x00" * campaign.closure_bytes
        + b"\x00" * load.INNER_BYTES
    )
    header = load.HEADER_STRUCT.pack(
        campaign.magic,
        campaign.outer_abi,
        campaign.outer_bytes,
        load.RECORD_COUNT,
        campaign.sidecar_bytes,
        campaign.closure_bytes,
        load.INNER_BYTES,
    )
    body_digest = load._domain_hash(campaign.body_domain, body)
    prefix = header + body + body_digest
    return prefix + load._domain_hash(campaign.footer_domain, prefix)


def _reseal_outer(encoded: bytearray, profile_name: str) -> bytes:
    campaign = load._campaign_profile(profile_name)
    body_end = len(encoded) - load.OUTER_DIGEST_BYTES
    encoded[body_end : body_end + 32] = load._domain_hash(
        campaign.body_domain,
        bytes(encoded[load.HEADER_BYTES:body_end]),
    )
    encoded[body_end + 32 :] = load._domain_hash(
        campaign.footer_domain,
        bytes(encoded[: body_end + 32]),
    )
    return bytes(encoded)


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _valid_closure(
    profile_name: str = load.SUCCESSFUL_PROFILE_NAME,
) -> tuple[int, ...]:
    campaign = load._campaign_profile(profile_name)
    if campaign.name == load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME:
        return load.QUEUED_RECEIVE_TIMEOUT_CLOSURE
    if campaign.has_open_loop_schedule:
        return _open_loop_profile_fixture()[1]
    return (
        72,
        72,
        0,
        72,
        72,
        8,
        2,
        3,
        3,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        campaign.service_completed_records,
        campaign.service_completed_records,
        0,
        0,
        0,
        1,
        1,
        1,
        0,
        222,
    )


def _profile_fixture(
    profile_name: str = load.SUCCESSFUL_PROFILE_NAME,
) -> tuple[
    tuple[load.Sidecar, ...],
    tuple[int, ...],
    load.InnerProfile,
    bytes,
    bytes,
    bytes,
]:
    campaign = load._campaign_profile(profile_name)
    if campaign.has_open_loop_schedule:
        return _open_loop_profile_fixture()
    build = _digest("build")
    machine = _digest("machine")
    challenge = _digest("challenge")
    sidecars = []
    records = []
    next_lifecycle_ordinal = 1
    next_work_sequence = 1
    for ordinal in range(load.RECORD_COUNT):
        base = (
            1_000_000 + ordinal * 6_000_000_000
            if campaign.name
            == load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            else 1_000 + ordinal * 100
        )
        request = _digest("request-%d" % ordinal)
        handle = _digest("handle-%d" % ordinal)
        output = _digest("output-%d" % ordinal)
        terminal = _digest("terminal-%d" % ordinal)
        completion = _digest("completion-%d" % ordinal)
        expected_outcome = load._expected_outcome(campaign, ordinal)
        timed_out = expected_outcome == load.OUTCOME_TIMED_OUT
        completed = expected_outcome == load.OUTCOME_COMPLETED
        enqueue_ordinal = next_lifecycle_ordinal
        if timed_out:
            dispatch_ordinal = 0
            retired_ordinal = enqueue_ordinal + 1
            next_lifecycle_ordinal += 2
        else:
            dispatch_ordinal = enqueue_ordinal + 1
            retired_ordinal = enqueue_ordinal + 2
            next_lifecycle_ordinal += 3
        sidecar = load.Sidecar(
            ordinal=ordinal,
            response_bytes=512,
            enqueue_ordinal=enqueue_ordinal,
            dispatch_ordinal=dispatch_ordinal,
            retired_ordinal=retired_ordinal,
            enqueue_ns=base + 1,
            dispatch_ns=base + 2,
            published_ns=base + 3,
            retired_ns=base + 7,
            work_sequence=next_work_sequence if completed else 0,
            process_generation=campaign.process_generation,
            connection_sequence=ordinal + 1,
            slot_generation=ordinal // campaign.connection_capacity + 1,
            slot_index=ordinal % campaign.connection_capacity,
            worker_index=ordinal % campaign.worker_count,
            content_byte=65,
            output_token=65,
            request_sha256=request,
            response_handle_sha256=handle,
            handle_sha256=handle,
            output_sha256=output,
            terminal_sha256=terminal,
            completion_sha256=completion,
        )
        if completed:
            next_work_sequence += 1
        rejected = (
            campaign.name == load.RETENTION_CAPACITY_PROFILE_NAME
            and ordinal >= campaign.service_completed_records
        )
        if rejected:
            sidecar = replace(
                sidecar,
                work_sequence=0,
                content_byte=0,
                output_token=0,
                response_handle_sha256=_digest(
                    "response-evidence-%d" % ordinal
                ),
                handle_sha256=load.ZERO_DIGEST,
                output_sha256=load.ZERO_DIGEST,
                terminal_sha256=load.ZERO_DIGEST,
                completion_sha256=load.ZERO_DIGEST,
                outcome=load.OUTCOME_CAPACITY_REJECTED,
            )
            sidecar = replace(
                sidecar,
                output_sha256=(
                    load._retention_capacity_response_semantic_root(
                        sidecar
                    )
                ),
                terminal_sha256=load._retention_capacity_terminal_root(
                    sidecar
                ),
            )
            sidecar = replace(
                sidecar,
                completion_sha256=load._retention_capacity_completion_root(
                    sidecar
                ),
            )
            roots = (
                request,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                sidecar.terminal_sha256,
                sidecar.completion_sha256,
            )
            points = (
                (base, ordinal * 7 + 1),
                (0, 0),
                (0, 0),
                (0, 0),
                (0, 0),
                (base + 5, ordinal * 7 + 6),
                (base + 7, ordinal * 7 + 7),
            )
        elif timed_out:
            timeout_ns = base + load.QUEUED_RECEIVE_TIMEOUT_NS + 10
            raw_request_evidence = (
                load._queued_receive_timeout_request_evidence(
                    ("head-%d" % ordinal).encode("ascii"),
                    ("body-%d" % ordinal).encode("ascii"),
                )
            )
            sidecar = replace(
                sidecar,
                response_bytes=0,
                dispatch_ordinal=0,
                dispatch_ns=0,
                published_ns=timeout_ns,
                retired_ns=timeout_ns,
                work_sequence=0,
                worker_index=load.NO_WORKER_INDEX,
                content_byte=0,
                output_token=0,
                response_handle_sha256=raw_request_evidence,
                handle_sha256=load.ZERO_DIGEST,
                output_sha256=load.ZERO_DIGEST,
                terminal_sha256=load.ZERO_DIGEST,
                completion_sha256=load.ZERO_DIGEST,
                outcome=load.OUTCOME_TIMED_OUT,
            )
            sidecar = replace(
                sidecar,
                output_sha256=(
                    load._queued_receive_timeout_semantic_root(
                        sidecar
                    )
                ),
            )
            sidecar = replace(
                sidecar,
                terminal_sha256=(
                    load._queued_receive_timeout_terminal_root(
                        sidecar
                    )
                ),
            )
            sidecar = replace(
                sidecar,
                completion_sha256=(
                    load._queued_receive_timeout_completion_root(
                        sidecar
                    )
                ),
            )
            roots = (
                request,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                load.ZERO_DIGEST,
                sidecar.terminal_sha256,
                sidecar.completion_sha256,
            )
            points = (
                (base, ordinal * 7 + 1),
                (0, 0),
                (0, 0),
                (0, 0),
                (0, 0),
                (timeout_ns + 1, ordinal * 7 + 6),
                (timeout_ns + 2, ordinal * 7 + 7),
            )
        else:
            pin = load._pin_root(sidecar)
            roots = (
                request,
                handle,
                pin,
                load._dispatch_root(sidecar, pin),
                load._submission_root(sidecar, pin),
                output,
                load._oracle_root(sidecar),
                terminal,
                completion,
            )
            points = (
                (base, ordinal * 7 + 1),
                (base + 1, ordinal * 7 + 2),
                (base + 2, ordinal * 7 + 3),
                (base + 3, ordinal * 7 + 4),
                (base + 4, ordinal * 7 + 5),
                (base + 5, ordinal * 7 + 6),
                (base + 7, ordinal * 7 + 7),
            )
        records.append(
            load.InnerRecord(
                ordinal=ordinal,
                cohort=0 if ordinal < load.WARMUP_COUNT else 1,
                outcome=sidecar.outcome,
                correctness=(
                    0 if rejected or timed_out else 1
                ),
                fallback=0,
                flow_id=(
                    load._expected_flow(campaign, ordinal)
                    if campaign.name
                    == load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                    else ordinal % load.FLOW_COUNT
                ),
                work_units=1,
                queue_slot=(
                    load.NO_QUEUE_SLOT
                    if rejected or timed_out
                    else sidecar.slot_index
                ),
                presence_mask=(
                    load.CAPACITY_REJECTED_PRESENCE
                    if rejected or timed_out
                    else 0x7F
                ),
                points=points,
                roots=roots,
            )
        )
        sidecars.append(sidecar)
    identities = (
        load._identity(load.WORKLOAD_ID),
        load._identity(campaign.profile_id),
        _digest("artifact"),
        build,
        machine,
        load._identity(load.BACKEND_ID),
        load._identity(load.DEVICE_ID),
        load._identity(campaign.placement_id),
        load._identity(load.HOST_SOURCE_ID),
        load._host_clock_identity("Darwin"),
        load._identity(load.DEVICE_SOURCE_ID),
        load._identity(load.DEVICE_CLOCK_ID),
        challenge,
    )
    profile = load.InnerProfile(
        mode=0,
        evidence=1,
        warmup_count=load.WARMUP_COUNT,
        measured_count=load.MEASURED_COUNT,
        max_in_flight=campaign.max_in_flight,
        queue_count=campaign.queue_count,
        flow_count=load.FLOW_COUNT,
        identities=identities,
        records=tuple(records),
        completed_work_units=campaign.measured_completed,
        interval_ns=7_000,
        throughput_numerator=campaign.measured_completed,
        throughput_denominator_ns=7_000,
        admission_sample_count=campaign.measured_completed,
        admission_p99_ns=1,
        queue_sample_count=campaign.measured_completed,
        queue_p99_ns=1,
        first_byte_sample_count=campaign.measured_completed,
        first_byte_p99_ns=4,
        terminal_p99_ns=5,
    )
    return (
        tuple(sidecars),
        _valid_closure(campaign.name),
        profile,
        build,
        machine,
        challenge,
    )


def _open_loop_profile_fixture() -> tuple[
    tuple[load.Sidecar, ...],
    tuple[int, ...],
    load.InnerProfile,
    bytes,
    bytes,
    bytes,
]:
    campaign = load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE
    build = _digest("build")
    machine = _digest("machine")
    challenge = _digest("challenge")
    anchor_ns = 10_000_000_000
    release_ns = (
        anchor_ns + load.OPEN_LOOP_FIXED_RELEASE_OFFSET_NS + 10_000_000
    )
    timing: list[dict[str, int]] = []
    previous_pressure_retired_by_slot: dict[int, int] = {}
    for planned_ordinal in range(load.RECORD_COUNT):
        phase, flags, scheduled_offset_ns = (
            load._open_loop_expected_schedule(planned_ordinal)
        )
        if phase == load.OPEN_LOOP_PHASE_WARMUP:
            arrival_ns = 8_000_000_000 + planned_ordinal * 10_000_000
            launch_lateness_ns = 0
        else:
            launch_lateness_ns = 1_000_000
            arrival_ns = (
                anchor_ns
                + scheduled_offset_ns
                + launch_lateness_ns
            )
        slot_index = planned_ordinal % campaign.connection_capacity
        if phase == load.OPEN_LOOP_PHASE_PRESSURE:
            phase_ordinal = (
                planned_ordinal - load.OPEN_LOOP_PRESSURE_START
            )
            prior_retired_ns = previous_pressure_retired_by_slot.get(
                slot_index,
                0,
            )
            enqueue_ns = max(
                arrival_ns + 100_000,
                prior_retired_ns + 100_000,
            )
            dispatch_ns = max(
                release_ns + phase_ordinal * 1_000_000,
                enqueue_ns + 100_000,
            )
            published_ns = dispatch_ns + 100_000
            first_output_ns = published_ns + 50_000
            terminal_ns = published_ns + 150_000
            retired_ns = published_ns + 200_000
            settlement_ns = retired_ns + 100_000
            previous_pressure_retired_by_slot[slot_index] = retired_ns
        else:
            enqueue_ns = arrival_ns + 100_000
            dispatch_ns = arrival_ns + 200_000
            published_ns = arrival_ns + 300_000
            first_output_ns = arrival_ns + 350_000
            terminal_ns = arrival_ns + 400_000
            retired_ns = arrival_ns + 450_000
            settlement_ns = arrival_ns + 550_000
        timing.append(
            {
                "arrival_ns": arrival_ns,
                "enqueue_ns": enqueue_ns,
                "dispatch_ns": dispatch_ns,
                "published_ns": published_ns,
                "first_output_ns": first_output_ns,
                "terminal_ns": terminal_ns,
                "retired_ns": retired_ns,
                "settlement_ns": settlement_ns,
                "transmit_complete_ns": arrival_ns + 50_000,
                "phase": phase,
                "flags": flags,
                "scheduled_offset_ns": scheduled_offset_ns,
                "launch_lateness_ns": launch_lateness_ns,
                "slot_index": slot_index,
            }
        )

    lifecycle_events: list[tuple[int, int, int]] = []
    for index, values in enumerate(timing):
        lifecycle_events.extend(
            (
                (values["enqueue_ns"], 0, index),
                (values["dispatch_ns"], 1, index),
                (values["retired_ns"], 2, index),
            )
        )
    lifecycle_ordinals: dict[tuple[int, int], int] = {}
    for ordinal, (_, kind, index) in enumerate(
        sorted(lifecycle_events),
        start=1,
    ):
        lifecycle_ordinals[(index, kind)] = ordinal

    host_events: list[tuple[int, int, int]] = []
    for index, values in enumerate(timing):
        for event_index, field in enumerate(
            (
                "arrival_ns",
                "enqueue_ns",
                "dispatch_ns",
                "published_ns",
                "first_output_ns",
                "terminal_ns",
                "settlement_ns",
            )
        ):
            host_events.append((values[field], event_index, index))
    host_sequences: dict[tuple[int, int], int] = {}
    for sequence, (_, event_index, index) in enumerate(
        sorted(host_events),
        start=1,
    ):
        host_sequences[(index, event_index)] = sequence

    sidecars: list[load.Sidecar] = []
    records: list[load.InnerRecord] = []
    for index, values in enumerate(timing):
        request = _digest("open-request-%d" % index)
        handle = _digest("open-handle-%d" % index)
        output = _digest("open-output-%d" % index)
        terminal = _digest("open-terminal-%d" % index)
        completion = _digest("open-completion-%d" % index)
        sidecar = load.Sidecar(
            ordinal=index,
            response_bytes=512,
            enqueue_ordinal=lifecycle_ordinals[(index, 0)],
            dispatch_ordinal=lifecycle_ordinals[(index, 1)],
            retired_ordinal=lifecycle_ordinals[(index, 2)],
            enqueue_ns=values["enqueue_ns"],
            dispatch_ns=values["dispatch_ns"],
            published_ns=values["published_ns"],
            retired_ns=values["retired_ns"],
            work_sequence=index + 1,
            process_generation=campaign.process_generation,
            connection_sequence=index + 1,
            slot_generation=(
                index // campaign.connection_capacity + 1
            ),
            slot_index=values["slot_index"],
            worker_index=index % campaign.worker_count,
            content_byte=65,
            output_token=65,
            request_sha256=request,
            response_handle_sha256=handle,
            handle_sha256=handle,
            output_sha256=output,
            terminal_sha256=terminal,
            completion_sha256=completion,
            schedule=load.OpenLoopSchedule(
                planned_ordinal=index,
                phase=values["phase"],
                flags=values["flags"],
                reserved=0,
                scheduled_offset_ns=values[
                    "scheduled_offset_ns"
                ],
                launch_lateness_ns=values[
                    "launch_lateness_ns"
                ],
                transmit_complete_ns=values[
                    "transmit_complete_ns"
                ],
            ),
        )
        pin = load._pin_root(sidecar)
        points = tuple(
            (
                values[field],
                host_sequences[(index, event_index)],
            )
            for event_index, field in enumerate(
                (
                    "arrival_ns",
                    "enqueue_ns",
                    "dispatch_ns",
                    "published_ns",
                    "first_output_ns",
                    "terminal_ns",
                    "settlement_ns",
                )
            )
        )
        records.append(
            load.InnerRecord(
                ordinal=index,
                cohort=0 if index < load.WARMUP_COUNT else 1,
                outcome=load.OUTCOME_COMPLETED,
                correctness=1,
                fallback=0,
                flow_id=(
                    index
                    if index < load.WARMUP_COUNT
                    else (index - load.WARMUP_COUNT)
                    % load.FLOW_COUNT
                ),
                work_units=1,
                queue_slot=(
                    index
                    if index < load.WARMUP_COUNT
                    else index - load.WARMUP_COUNT
                ),
                presence_mask=0x7F,
                points=points,
                roots=(
                    request,
                    handle,
                    pin,
                    load._dispatch_root(sidecar, pin),
                    load._submission_root(sidecar, pin),
                    output,
                    load._oracle_root(sidecar),
                    terminal,
                    completion,
                ),
            )
        )
        sidecars.append(sidecar)

    measured_records = records[load.WARMUP_COUNT :]

    def p99(values: list[int]) -> int:
        ordered = sorted(values)
        return ordered[(99 * len(ordered) + 99) // 100 - 1]

    interval_ns = (
        max(record.points[6][0] for record in measured_records)
        - min(record.points[0][0] for record in measured_records)
    )
    profile = load.InnerProfile(
        mode=1,
        evidence=1,
        warmup_count=load.WARMUP_COUNT,
        measured_count=load.MEASURED_COUNT,
        max_in_flight=campaign.max_in_flight,
        queue_count=campaign.queue_count,
        flow_count=load.FLOW_COUNT,
        identities=(
            load._identity(load.WORKLOAD_ID),
            load._identity(campaign.profile_id),
            _digest("artifact"),
            build,
            machine,
            load._identity(load.BACKEND_ID),
            load._identity(load.DEVICE_ID),
            load._identity(campaign.placement_id),
            load._identity(load.HOST_SOURCE_ID),
            load._host_clock_identity("Darwin"),
            load._identity(load.DEVICE_SOURCE_ID),
            load._identity(load.DEVICE_CLOCK_ID),
            challenge,
        ),
        records=tuple(records),
        completed_work_units=load.MEASURED_COUNT,
        interval_ns=interval_ns,
        throughput_numerator=load.MEASURED_COUNT,
        throughput_denominator_ns=interval_ns,
        admission_sample_count=load.MEASURED_COUNT,
        admission_p99_ns=p99(
            [
                record.points[1][0] - record.points[0][0]
                for record in measured_records
            ]
        ),
        queue_sample_count=load.MEASURED_COUNT,
        queue_p99_ns=p99(
            [
                record.points[2][0] - record.points[1][0]
                for record in measured_records
            ]
        ),
        first_byte_sample_count=load.MEASURED_COUNT,
        first_byte_p99_ns=p99(
            [
                record.points[4][0] - record.points[0][0]
                for record in measured_records
            ]
        ),
        terminal_p99_ns=p99(
            [
                record.points[5][0] - record.points[0][0]
                for record in measured_records
            ]
        ),
    )
    pressure = timing[
        load.OPEN_LOOP_PRESSURE_START :
        load.OPEN_LOOP_RECOVERY_START
    ]
    recovery = timing[load.OPEN_LOOP_RECOVERY_START :]
    pressure_server_settled_ns = max(
        values["retired_ns"] for values in pressure
    )
    pressure_joined_settled_ns = max(
        values["settlement_ns"] for values in pressure
    )
    recovery_first_ns = min(
        values["arrival_ns"] for values in recovery
    )
    closure = (
        72,
        72,
        0,
        72,
        72,
        8,
        2,
        1,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        72,
        72,
        0,
        0,
        0,
        1,
        1,
        1,
        0,
        218,
        anchor_ns,
        64,
        16,
        32,
        16,
        375_000_000,
        155_000_000,
        375_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        anchor_ns + 700_000_000,
        release_ns,
        pressure_server_settled_ns,
        pressure_joined_settled_ns,
        recovery_first_ns
        - max(
            pressure_server_settled_ns,
            pressure_joined_settled_ns,
        ),
    )
    return (
        tuple(sidecars),
        closure,
        profile,
        build,
        machine,
        challenge,
    )


def _reroot_completed(
    sidecar: load.Sidecar,
    record: load.InnerRecord,
    **changes: int,
) -> tuple[load.Sidecar, load.InnerRecord]:
    candidate = replace(sidecar, **changes)
    if candidate.outcome != load.OUTCOME_COMPLETED:
        raise AssertionError("completed reroot helper received another outcome")
    pin = load._pin_root(candidate)
    roots = (
        candidate.request_sha256,
        candidate.handle_sha256,
        pin,
        load._dispatch_root(candidate, pin),
        load._submission_root(candidate, pin),
        candidate.output_sha256,
        load._oracle_root(candidate),
        candidate.terminal_sha256,
        candidate.completion_sha256,
    )
    return candidate, replace(record, roots=roots)


def _observation(
    *,
    busy: int,
    external: int,
    thermal_availability: str = "missing",
    thermal_value: int | None = None,
) -> dict:
    values = {
        "host_logical_cpu_count": ("present", 8),
        "host_cpu_busy_ppm": ("present", busy),
        "host_external_cpu_ppm": ("present", external),
        "host_power_source": ("present", 1),
        "host_low_power_mode": ("present", 0),
        "host_thermal_constraint": (
            thermal_availability,
            thermal_value,
        ),
    }
    return {
        "claim_scope": "native-observation-only",
        "system": "Darwin",
        "adapter": load.native_observer.ADAPTER,
        "metrics": [
            {
                "name": name,
                "availability": availability,
                "value": value,
            }
            for name, (availability, value) in values.items()
        ],
    }


def _darwin_machine_descriptor() -> dict[str, object]:
    descriptor: dict[str, object] = {
        "system": "Darwin",
        "release": "25.0.0",
        "machine": "arm64",
        "cpu_brand": "Fixture CPU",
        "logical_cpu_count": 8,
        "boot_session_sha256": _digest("boot-session").hex(),
    }
    canonical = load.json.dumps(
        descriptor,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")
    descriptor["fingerprint_sha256"] = hashlib.sha256(
        canonical
    ).hexdigest()
    return descriptor


def _admitted_environment(
    machine: dict[str, object],
) -> dict[str, object]:
    return {
        "schema": load.lane4_evidence.ENVIRONMENT_SCHEMA,
        "captured_at_utc": "2026-01-01T00:00:00+00:00",
        "host": copy.deepcopy(machine),
        "power_source": "AC Power",
        "battery_state": "charged",
        "thermal_state": "nominal",
        "foundation_thermal_state": "nominal",
        "low_power_mode_enabled": False,
        "cpu_speed_limit_percent": 100,
        "scheduler_limit_percent": 100,
        "available_cpus": 8,
        "raw_pmset_battery_sha256": _digest(
            "pmset-battery"
        ).hex(),
        "raw_pmset_thermal_sha256": _digest(
            "pmset-thermal"
        ).hex(),
        "raw_foundation_process_info_sha256": _digest(
            "foundation-process-info"
        ).hex(),
        "foundation_probe_source_sha256": (
            load.lane4_evidence.FOUNDATION_PROBE_SOURCE_SHA256
        ),
        "foundation_probe_runner_sha256": _digest(
            "foundation-runner"
        ).hex(),
        "measurement_admitted": True,
        "reasons": [],
        "claim_scope": "environment-admission-only",
        "performance_claim": "not_evaluated",
        "promotion_decision": "not_evaluated",
        "measurements_publishable": False,
    }


def _publication_observation(
    *,
    phase: str,
    busy: int,
    external: int,
    logical_cpu_count: int = 8,
) -> dict[str, object]:
    started_ns = 100 if phase == "pre_run" else 1_000
    present_values = {
        "host_monotonic_time": started_ns,
        "host_logical_cpu_count": logical_cpu_count,
        "host_cpu_busy_ppm": busy,
        "host_external_cpu_ppm": external,
        "host_power_source": 1,
        "host_low_power_mode": 0,
    }
    metrics = []
    for name, _, _, _, _ in load.native_observer.METRIC_SPECS:
        provenance = (
            load.native_observer._common.runtime_provenance(
                load.native_observer.ADAPTER,
                "Darwin",
                "publication-fixture.%s" % name,
            )
        )
        if name in present_values:
            metric = load.native_observer._common.make_metric(
                name,
                phase,
                "present",
                present_values[name],
                provenance,
            )
        else:
            metric = load.native_observer._common.make_metric(
                name,
                phase,
                "unsupported",
                None,
                provenance,
                "fixture does not retain this metric",
            )
        metrics.append(metric)
    availability_counts = {
        availability: sum(
            metric["availability"] == availability
            for metric in metrics
        )
        for availability in load.native_observer.AVAILABILITIES
    }
    return {
        "schema": load.native_observer.SCHEMA,
        "adapter": load.native_observer.ADAPTER,
        "phase": phase,
        "system": "Darwin",
        "observed_process_id": 1234,
        "captured_at_utc": (
            "2026-01-01T00:00:00+00:00"
            if phase == "pre_run"
            else "2026-01-01T00:00:01+00:00"
        ),
        "capture_interval": {
            "sample_clock_domain": "host_monotonic",
            "started_ns": started_ns,
            "finished_ns": started_ns + 10,
        },
        "availability_counts": availability_counts,
        "metrics": metrics,
        "claim_scope": "native-observation-only",
    }


def _publication_fixture(
    *,
    publication_eligible: bool = True,
    profile_name: str = load.SUCCESSFUL_PROFILE_NAME,
) -> tuple[
    load.publication.PublicationBundle,
    load.VerifiedEnvelope,
    bytes,
    dict[str, object],
]:
    campaign = load._campaign_profile(profile_name)
    sidecars, closure, profile, _, _, _ = _profile_fixture(
        profile_name
    )
    envelope = b"native-unary-load-envelope-fixture"
    report_sha256 = _digest("inner-report")
    verified = load.VerifiedEnvelope(
        inner_result=SimpleNamespace(report_sha256=report_sha256),
        profile=profile,
        sidecars=sidecars,
        closure=closure,
        outer_sha256=hashlib.sha256(envelope).digest(),
    )
    machine = _darwin_machine_descriptor()
    machine_fingerprint = bytes.fromhex(
        str(machine["fingerprint_sha256"])
    )
    before = _publication_observation(
        phase="pre_run",
        busy=300_000,
        external=150_000,
    )
    after = _publication_observation(
        phase="post_run",
        busy=340_000,
        external=170_000 if publication_eligible else 240_000,
    )
    cpu_boundary = load._validate_native_boundaries(
        before,
        after,
        system="Darwin",
    )
    stable = [
        _admitted_environment(machine),
        _admitted_environment(machine),
    ]
    post = _admitted_environment(machine)
    environment = {
        "stable_pre_run_admission": stable,
        "pre_run_native_observation": before,
        "post_run_admission": post,
        "post_run_native_observation": after,
        "cpu_boundary": cpu_boundary,
    }
    pre_root, post_root = load._publication_environment_roots(
        environment
    )
    producer = {
        "sha256": _digest("producer").hex(),
        "size_bytes": 1234,
    }
    challenge = _digest("publication-challenge")
    eligibility = load._publication_eligibility(
        "Darwin",
        cpu_boundary,
    )
    context = {
        "schema": load.PUBLICATION_CONTEXT_SCHEMA,
        "profile": campaign.name,
        "envelope": {
            "sha256": verified.outer_sha256.hex(),
            "bytes": len(envelope),
        },
        "producer": producer,
        "system": "Darwin",
        "machine_fingerprint_sha256": machine_fingerprint.hex(),
        "challenge_hex": challenge.hex(),
        "challenge_sha256": hashlib.sha256(challenge).hexdigest(),
        "pre_environment_sha256": pre_root.hex(),
        "post_environment_sha256": post_root.hex(),
        "eligibility": eligibility,
    }
    manifest: dict[str, object] = {
        "schema": "glacier.native-unary-server-load-capture/v1",
        "status": "verified",
        "profile": campaign.name,
        "publication_eligible": publication_eligible,
        "claim_scope": load._claim_scope(campaign),
        "producer": producer,
        "machine": machine,
        "challenge_sha256": challenge.hex(),
        "publication_context": context,
        "report": load._report_manifest(
            campaign,
            envelope,
            verified,
        ),
        "environment": environment,
        "limitations": load._manifest_limitations(campaign),
    }
    bundle = load.publication.decode_bundle(
        load.publication.encode_bundle(envelope, manifest)
    )
    return bundle, verified, challenge, manifest


class NativeUnaryServerLoadTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "bounded capture is POSIX-only")
    def test_process_capture_cleans_up_when_selector_setup_fails(self) -> None:
        environment = {"LC_ALL": "C", "PATH": os.defpath}
        real_popen = load.subprocess.Popen

        class RegisterFailingSelector:
            def __init__(self, fail_on_register: int) -> None:
                self.fail_on_register = fail_on_register
                self.register_count = 0
                self.closed = False

            def register(self, *args: object, **kwargs: object) -> None:
                _ = args
                _ = kwargs
                self.register_count += 1
                if self.register_count == self.fail_on_register:
                    raise OSError("injected selector register failure")

            def close(self) -> None:
                self.closed = True

        for failure in (
            "constructor",
            "first_register",
            "second_register",
        ):
            with self.subTest(failure=failure):
                spawned: list[load.subprocess.Popen[bytes]] = []
                failing_selector: RegisterFailingSelector | None = None

                def recording_popen(
                    *args: object,
                    **kwargs: object,
                ) -> load.subprocess.Popen[bytes]:
                    process = real_popen(*args, **kwargs)
                    spawned.append(process)
                    return process

                if failure == "constructor":
                    def selector_factory() -> load.selectors.BaseSelector:
                        raise OSError(
                            "injected selector constructor failure"
                        )
                else:
                    def selector_factory() -> RegisterFailingSelector:
                        nonlocal failing_selector
                        failing_selector = RegisterFailingSelector(
                            1 if failure == "first_register" else 2
                        )
                        return failing_selector

                with mock.patch.object(
                    load.subprocess,
                    "Popen",
                    side_effect=recording_popen,
                ), mock.patch.object(
                    load.selectors,
                    "DefaultSelector",
                    side_effect=selector_factory,
                ):
                    with self.assertRaisesRegex(
                        OSError,
                        "injected selector",
                    ):
                        load._bounded_capture(
                            [
                                sys.executable,
                                "-c",
                                "import time; time.sleep(60)",
                            ],
                            stdout_limit=16,
                            stderr_limit=16,
                            timeout_seconds=5.0,
                            env=environment,
                        )

                self.assertEqual(len(spawned), 1)
                self.assertIsNotNone(spawned[0].poll())
                self.assertIsNotNone(spawned[0].stdout)
                self.assertIsNotNone(spawned[0].stderr)
                self.assertTrue(spawned[0].stdout.closed)
                self.assertTrue(spawned[0].stderr.closed)
                if failing_selector is not None:
                    self.assertEqual(
                        failing_selector.register_count,
                        failing_selector.fail_on_register,
                    )
                    self.assertTrue(failing_selector.closed)

    @unittest.skipUnless(os.name == "posix", "bounded capture is POSIX-only")
    def test_process_capture_enforces_bounds_while_child_is_live(self) -> None:
        environment = {"LC_ALL": "C", "PATH": os.defpath}
        returncode, stdout, stderr = load._bounded_capture(
            [
                sys.executable,
                "-c",
                "import os; os.write(1, b'good'); os.write(2, b'ok')",
            ],
            stdout_limit=4,
            stderr_limit=2,
            timeout_seconds=5.0,
            env=environment,
        )
        self.assertEqual(returncode, 0)
        self.assertEqual(stdout, b"good")
        self.assertEqual(stderr, b"ok")

        for label, descriptor in (("stdout", 1), ("stderr", 2)):
            with self.subTest(label=label):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "producer %s exceeded the fixed bound" % label,
                ):
                    load._bounded_capture(
                        [
                            sys.executable,
                            "-c",
                            "import os; os.write(%d, b'x' * 17)"
                            % descriptor,
                        ],
                        stdout_limit=16,
                        stderr_limit=16,
                        timeout_seconds=5.0,
                        env=environment,
                    )

        with self.assertRaisesRegex(
            load.VerificationError,
            "producer stdout exceeded the fixed bound",
        ):
            load._bounded_capture(
                [
                    sys.executable,
                    "-c",
                    (
                        "import os\n"
                        "while True:\n"
                        " os.write(1, b'x' * 4096)"
                    ),
                ],
                stdout_limit=1024,
                stderr_limit=16,
                timeout_seconds=5.0,
                env=environment,
            )

    def test_fixed_layout_is_exact_and_outer_digests_bind_regions(self) -> None:
        self.assertEqual(load.SIDECAR_STRUCT.size, load.SIDECAR_BYTES)
        self.assertEqual(load.HEADER_STRUCT.size, load.HEADER_BYTES)
        encoded = _seal_structural_outer()
        sidecars, closure, inner = load._parse_outer(encoded)
        self.assertEqual(len(encoded), load.OUTER_BYTES)
        self.assertEqual(len(sidecars), load.RECORD_COUNT)
        self.assertEqual(len(closure), load.CLOSURE_U64_COUNT)
        self.assertEqual(len(inner), load.INNER_BYTES)

        for offset in (
            0,
            8,
            load.HEADER_BYTES,
            load.HEADER_BYTES + load.SIDECAR_BYTES,
            load.HEADER_BYTES
            + load.RECORD_COUNT * load.SIDECAR_BYTES,
            len(encoded) - 65,
            len(encoded) - 1,
        ):
            mutated = bytearray(encoded)
            mutated[offset] ^= 1
            with self.subTest(offset=offset):
                with self.assertRaises(load.VerificationError):
                    load._parse_outer(bytes(mutated))

    def test_open_loop_outer_layout_and_profile_abi_are_isolated(
        self,
    ) -> None:
        campaign = load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE
        self.assertEqual(load.OPEN_LOOP_SCHEDULE_STRUCT.size, 32)
        self.assertEqual(load.OPEN_LOOP_SIDECAR_BYTES, 328)
        self.assertEqual(load.OPEN_LOOP_CLOSURE_BYTES, 352)
        self.assertEqual(load.OPEN_LOOP_OUTER_BYTES, 82_212)
        self.assertEqual(campaign.outer_bytes, load.OPEN_LOOP_OUTER_BYTES)
        encoded = _seal_structural_outer(campaign.name)
        sidecars, closure, inner = load._parse_outer(
            encoded,
            profile_name=campaign.name,
        )
        self.assertEqual(len(encoded), load.OPEN_LOOP_OUTER_BYTES)
        self.assertEqual(len(sidecars), load.RECORD_COUNT)
        self.assertEqual(len(closure), load.OPEN_LOOP_CLOSURE_U64_COUNT)
        self.assertEqual(len(inner), load.INNER_BYTES)
        self.assertEqual(sidecars[0].schedule.planned_ordinal, 0)
        self.assertEqual(
            load.HEADER_STRUCT.unpack_from(encoded, 0),
            (
                load.OPEN_LOOP_TRANSIENT_PRESSURE_MAGIC,
                load.OPEN_LOOP_TRANSIENT_PRESSURE_OUTER_ABI,
                load.OPEN_LOOP_OUTER_BYTES,
                load.RECORD_COUNT,
                load.OPEN_LOOP_SIDECAR_BYTES,
                load.OPEN_LOOP_CLOSURE_BYTES,
                load.INNER_BYTES,
            ),
        )
        for old_profile in (
            load.SUCCESSFUL_PROFILE_NAME,
            load.RETENTION_CAPACITY_PROFILE_NAME,
            load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME,
        ):
            with self.subTest(old_profile=old_profile):
                with self.assertRaises(load.VerificationError):
                    load._parse_outer(
                        encoded,
                        profile_name=old_profile,
                    )
        with self.assertRaises(load.VerificationError):
            load._parse_outer(
                _seal_structural_outer(),
                profile_name=campaign.name,
            )

        invalid_outcome = bytearray(encoded)
        invalid_outcome[load.HEADER_BYTES + 99] = (
            load.OUTCOME_CAPACITY_REJECTED
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "sidecar reserved byte is nonzero",
        ):
            load._parse_outer(
                _reseal_outer(invalid_outcome, campaign.name),
                profile_name=campaign.name,
            )

    def test_open_loop_profile_binds_schedule_gate_and_recovery(
        self,
    ) -> None:
        profile_name = load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture(profile_name)
        )

        def verify(
            candidate_sidecars: tuple[load.Sidecar, ...] = sidecars,
            candidate_closure: tuple[int, ...] = closure,
            candidate_profile: load.InnerProfile = profile,
        ) -> None:
            load._verify_profile(
                candidate_sidecars,
                candidate_closure,
                candidate_profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
                profile_name=profile_name,
            )

        verify()
        self.assertEqual(profile.mode, 1)
        self.assertEqual(
            (profile.max_in_flight, profile.queue_count),
            (64, 64),
        )
        planned = {
            sidecar.schedule.planned_ordinal: (
                sidecar,
                record,
                sidecar.schedule,
            )
            for sidecar, record in zip(sidecars, profile.records)
        }
        self.assertEqual(set(planned), set(range(load.RECORD_COUNT)))
        self.assertEqual(
            [
                planned[index][1].queue_slot
                for index in range(load.RECORD_COUNT)
            ],
            list(range(load.WARMUP_COUNT))
            + list(range(load.MEASURED_COUNT)),
        )
        self.assertEqual(
            max(sidecar.slot_index for sidecar in sidecars),
            9,
        )
        self.assertEqual(
            max(record.queue_slot for record in profile.records),
            63,
        )
        self.assertEqual(
            [
                planned[index][2].phase
                for index in range(load.WARMUP_COUNT)
            ],
            [load.OPEN_LOOP_PHASE_WARMUP] * load.WARMUP_COUNT,
        )
        self.assertEqual(
            [
                planned[index][2].scheduled_offset_ns
                for index in (
                    load.OPEN_LOOP_BASELINE_START,
                    load.OPEN_LOOP_PRESSURE_START,
                    load.OPEN_LOOP_RECOVERY_START,
                    load.RECORD_COUNT - 1,
                )
            ],
            [0, 600_000_000, 1_800_000_000, 2_175_000_000],
        )
        self.assertEqual(closure[5:9], (8, 2, 1, 1))
        self.assertEqual(closure[29:33], (64, 16, 32, 16))
        evidence = load._verify_open_loop_evidence(
            sidecars,
            profile.records,
            closure,
        )
        self.assertEqual(
            evidence["phases"]["baseline"][
                "offered_launch_rate_numerator"
            ],
            15,
        )
        self.assertEqual(
            evidence["phases"]["baseline"][
                "offered_launch_rate_denominator_ns"
            ],
            375_000_000,
        )
        self.assertEqual(
            evidence["phases"]["pressure"][
                "offered_launch_rate_denominator_ns"
            ],
            155_000_000,
        )
        self.assertEqual(
            evidence["phases"]["recovery"][
                "scheduled_offset_first_ns"
            ],
            1_800_000_000,
        )
        self.assertGreaterEqual(
            evidence["recovery"]["slack_ns"],
            load.OPEN_LOOP_RECOVERY_SLACK_NS,
        )

        verified = load.VerifiedEnvelope(
            inner_result=SimpleNamespace(
                report_sha256=_digest("open-inner-report")
            ),
            profile=profile,
            sidecars=sidecars,
            closure=closure,
            outer_sha256=_digest("open-outer"),
        )
        report = load._report_manifest(
            load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE,
            b"open-loop-envelope",
            verified,
        )
        self.assertEqual(report["open_loop"], evidence)
        self.assertEqual(
            report["throughput_numerator"],
            load.MEASURED_COUNT,
        )
        self.assertNotEqual(
            report["throughput_denominator_ns"],
            evidence["phases"]["pressure"][
                "achieved_launch_rate_denominator_ns"
            ],
        )

    def test_open_loop_profile_rejects_schedule_and_plan_mutations(
        self,
    ) -> None:
        profile_name = load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture(profile_name)
        )

        def verify(
            candidate_sidecars: tuple[load.Sidecar, ...] = sidecars,
            candidate_closure: tuple[int, ...] = closure,
            candidate_profile: load.InnerProfile = profile,
        ) -> None:
            load._verify_profile(
                candidate_sidecars,
                candidate_closure,
                candidate_profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
                profile_name=profile_name,
            )

        actor_index = load.OPEN_LOOP_PRESSURE_START
        actor_record = profile.records[actor_index]
        wrong_actor_slot = sidecars[actor_index].slot_index
        self.assertNotEqual(
            actor_record.queue_slot,
            wrong_actor_slot,
        )
        actor_records = list(profile.records)
        actor_records[actor_index] = replace(
            actor_record,
            queue_slot=wrong_actor_slot,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "logical actor slot",
        ):
            verify(
                candidate_profile=replace(
                    profile,
                    records=tuple(actor_records),
                ),
            )

        schedule_index = load.OPEN_LOOP_PRESSURE_START
        original = sidecars[schedule_index]
        assert original.schedule is not None
        schedule_mutations = {
            "duplicate": replace(
                original.schedule,
                planned_ordinal=(
                    original.schedule.planned_ordinal - 1
                ),
            ),
            "phase": replace(
                original.schedule,
                phase=load.OPEN_LOOP_PHASE_BASELINE,
            ),
            "flags": replace(original.schedule, flags=0),
            "reserved": replace(original.schedule, reserved=1),
            "offset": replace(
                original.schedule,
                scheduled_offset_ns=(
                    original.schedule.scheduled_offset_ns + 1
                ),
            ),
            "lateness": replace(
                original.schedule,
                launch_lateness_ns=(
                    original.schedule.launch_lateness_ns + 1
                ),
            ),
            "transmit": replace(
                original.schedule,
                transmit_complete_ns=closure[40] + 1,
            ),
        }
        for label, schedule in schedule_mutations.items():
            mutated = list(sidecars)
            mutated[schedule_index] = replace(
                original,
                schedule=schedule,
            )
            with self.subTest(schedule=label):
                with self.assertRaises(load.VerificationError):
                    verify(tuple(mutated))

        cohort_index = load.OPEN_LOOP_BASELINE_START
        cohort_records = list(profile.records)
        cohort_records[cohort_index] = replace(
            cohort_records[cohort_index],
            cohort=0,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "phase/cohort",
        ):
            load._verify_open_loop_evidence(
                sidecars,
                tuple(cohort_records),
                closure,
            )

        for phase_name, transmit_index in (
            ("baseline", load.OPEN_LOOP_BASELINE_START),
            ("recovery", load.OPEN_LOOP_RECOVERY_START),
        ):
            transmit_sidecar = sidecars[transmit_index]
            assert transmit_sidecar.schedule is not None
            transmit_record = profile.records[transmit_index]
            self.assertLess(
                transmit_record.points[4][0],
                transmit_record.points[6][0],
            )
            transmit_sidecars = list(sidecars)
            transmit_sidecars[transmit_index] = replace(
                transmit_sidecar,
                schedule=replace(
                    transmit_sidecar.schedule,
                    transmit_complete_ns=(
                        transmit_record.points[4][0] + 1
                    ),
                ),
            )
            with self.subTest(transmit_phase=phase_name):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "transmit boundary",
                ):
                    verify(tuple(transmit_sidecars))

        first_pressure = sidecars[load.OPEN_LOOP_PRESSURE_START]
        second_pressure = sidecars[
            load.OPEN_LOOP_PRESSURE_START + 1
        ]
        self.assertLess(
            first_pressure.enqueue_ordinal,
            second_pressure.enqueue_ordinal,
        )
        fifo_mutated = list(sidecars)
        fifo_mutated[load.OPEN_LOOP_PRESSURE_START] = replace(
            first_pressure,
            dispatch_ordinal=second_pressure.dispatch_ordinal + 1,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "FIFO enqueue order",
        ):
            load._verify_open_loop_evidence(
                tuple(fifo_mutated),
                profile.records,
                closure,
            )

        baseline_index = load.OPEN_LOOP_BASELINE_START
        baseline_sidecar = sidecars[baseline_index]
        assert baseline_sidecar.schedule is not None
        baseline_record = profile.records[baseline_index]
        early_points = list(baseline_record.points)
        early_points[0] = (
            closure[28] - 1,
            early_points[0][1],
        )
        early_records = list(profile.records)
        early_records[baseline_index] = replace(
            baseline_record,
            points=tuple(early_points),
        )
        early_sidecars = list(sidecars)
        early_sidecars[baseline_index] = replace(
            baseline_sidecar,
            schedule=replace(
                baseline_sidecar.schedule,
                launch_lateness_ns=0,
                transmit_complete_ns=closure[28],
            ),
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "launched before its schedule",
        ):
            verify(
                tuple(early_sidecars),
                candidate_profile=replace(
                    profile,
                    records=tuple(early_records),
                ),
            )

        closure_mutations = {
            "counts": (29, closure[29] - 1),
            "span": (34, closure[34] + 1),
            "lateness": (37, closure[37] + 1),
            "ready": (
                39,
                closure[28]
                + load.OPEN_LOOP_FIXED_RELEASE_OFFSET_NS
                + 1,
            ),
            "release": (
                40,
                closure[28]
                + load.OPEN_LOOP_FIXED_RELEASE_OFFSET_NS
                + load.OPEN_LOOP_LAUNCH_LATENESS_CAP_NS
                + 1,
            ),
            "server-settlement": (41, closure[41] + 1),
            "joined-settlement": (42, closure[42] + 1),
            "recovery-slack": (43, closure[43] - 1),
        }
        for label, (index, value) in closure_mutations.items():
            mutated = list(closure)
            mutated[index] = value
            with self.subTest(plan=label):
                with self.assertRaises(load.VerificationError):
                    verify(candidate_closure=tuple(mutated))

        for index, value in ((5, 7), (6, 1), (7, 0), (8, 0)):
            mutated = list(closure)
            mutated[index] = value
            if index in (7, 8):
                mutated[7] = mutated[8] = value
                mutated[27] = (
                    load.RECORD_COUNT * 3 + value * 2
                )
            with self.subTest(base_closure=index):
                with self.assertRaises(load.VerificationError):
                    verify(candidate_closure=tuple(mutated))

    def test_retention_capacity_outer_abi_rejects_profile_substitution(
        self,
    ) -> None:
        successful = _seal_structural_outer()
        capacity = _seal_structural_outer(
            load.RETENTION_CAPACITY_PROFILE_NAME
        )
        self.assertEqual(len(capacity), load.OUTER_BYTES)
        self.assertEqual(
            len(
                load._parse_outer(
                    capacity,
                    profile_name=load.RETENTION_CAPACITY_PROFILE_NAME,
                )[0]
            ),
            load.RECORD_COUNT,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "invalid outer magic",
        ):
            load._parse_outer(
                successful,
                profile_name=load.RETENTION_CAPACITY_PROFILE_NAME,
            )
        with self.assertRaisesRegex(
            load.VerificationError,
            "invalid outer magic",
        ):
            load._parse_outer(capacity)

        invalid_outcome = bytearray(capacity)
        outcome_offset = load.HEADER_BYTES + 99
        invalid_outcome[outcome_offset] = 2
        with self.assertRaisesRegex(
            load.VerificationError,
            "sidecar outcome is invalid",
        ):
            load._parse_outer(
                _reseal_outer(
                    invalid_outcome,
                    load.RETENTION_CAPACITY_PROFILE_NAME,
                ),
                profile_name=load.RETENTION_CAPACITY_PROFILE_NAME,
            )

    def test_retention_capacity_cross_language_root_vectors(self) -> None:
        sidecar = load.Sidecar(
            ordinal=0,
            response_bytes=321,
            enqueue_ordinal=0,
            dispatch_ordinal=0,
            retired_ordinal=0,
            enqueue_ns=0,
            dispatch_ns=0,
            published_ns=0,
            retired_ns=0,
            work_sequence=0,
            process_generation=0,
            connection_sequence=0,
            slot_generation=0,
            slot_index=0,
            worker_index=0,
            content_byte=0,
            output_token=0,
            request_sha256=b"\x5a" * 32,
            response_handle_sha256=b"\xa5" * 32,
            handle_sha256=load.ZERO_DIGEST,
            output_sha256=load.ZERO_DIGEST,
            terminal_sha256=load.ZERO_DIGEST,
            completion_sha256=load.ZERO_DIGEST,
            outcome=load.OUTCOME_CAPACITY_REJECTED,
        )
        semantic = load._retention_capacity_response_semantic_root(
            sidecar
        )
        terminal = load._retention_capacity_terminal_root(sidecar)
        bound = replace(
            sidecar,
            output_sha256=semantic,
            terminal_sha256=terminal,
        )
        completion = load._retention_capacity_completion_root(bound)
        self.assertEqual(
            semantic.hex(),
            "5ac9280807e3e4b9e0836a446bcec8fb"
            "d3ab1b61af50563238ca3bd10163fa95",
        )
        self.assertEqual(
            terminal.hex(),
            "fa850625ac5f41b0639cf8b1acd6eb13"
            "de8df6da4cee533ef7d1672e99941dd4",
        )
        self.assertEqual(
            completion.hex(),
            "009e45f2f79152637ffd64252f7faced"
            "2909d6a14d92d87a117510a44f66dee2",
        )

    def test_queued_timeout_outer_abi_and_outcome_are_isolated(self) -> None:
        queued = _seal_structural_outer(
            load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
        )
        self.assertEqual(len(queued), load.OUTER_BYTES)
        self.assertEqual(
            len(
                load._parse_outer(
                    queued,
                    profile_name=(
                        load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                    ),
                )[0]
            ),
            load.RECORD_COUNT,
        )
        for old_profile in (
            load.SUCCESSFUL_PROFILE_NAME,
            load.RETENTION_CAPACITY_PROFILE_NAME,
        ):
            with self.subTest(old_profile=old_profile):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "invalid outer magic",
                ):
                    load._parse_outer(
                        queued,
                        profile_name=old_profile,
                    )

        outcome_offset = load.HEADER_BYTES + 99
        timed_out = bytearray(queued)
        timed_out[outcome_offset] = load.OUTCOME_TIMED_OUT
        timed_out_wire = _reseal_outer(
            timed_out,
            load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME,
        )
        parsed = load._parse_outer(
            timed_out_wire,
            profile_name=load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME,
        )[0]
        self.assertEqual(
            parsed[0].outcome,
            load.OUTCOME_TIMED_OUT,
        )
        for old_campaign in (
            load.SUCCESSFUL_PROFILE,
            load.RETENTION_CAPACITY_PROFILE,
        ):
            with self.subTest(old_campaign=old_campaign.name):
                with self.assertRaises(load.VerificationError):
                    load._parse_sidecar_exact(
                        timed_out_wire,
                        load.HEADER_BYTES,
                        old_campaign,
                    )

        capacity_outcome = bytearray(queued)
        capacity_outcome[outcome_offset] = (
            load.OUTCOME_CAPACITY_REJECTED
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "sidecar outcome is invalid",
        ):
            load._parse_outer(
                _reseal_outer(
                    capacity_outcome,
                    load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME,
                ),
                profile_name=(
                    load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                ),
            )

    def test_queued_timeout_cross_language_root_vectors(self) -> None:
        raw_request = (
            load._queued_receive_timeout_request_evidence(
                b"POST /v1/chat/completions HTTP/1.1\r\n\r\n",
                b'{"profile":"queued-timeout"}',
            )
        )
        sidecar = load.Sidecar(
            ordinal=10,
            response_bytes=0,
            enqueue_ordinal=11,
            dispatch_ordinal=0,
            retired_ordinal=19,
            enqueue_ns=1_000,
            dispatch_ns=0,
            published_ns=2_000_001_000,
            retired_ns=2_000_001_000,
            work_sequence=0,
            process_generation=(
                load.QUEUED_RECEIVE_TIMEOUT_PROCESS_GENERATION
            ),
            connection_sequence=9,
            slot_generation=7,
            slot_index=1,
            worker_index=load.NO_WORKER_INDEX,
            content_byte=0,
            output_token=0,
            request_sha256=b"\x5a" * 32,
            response_handle_sha256=b"\xa5" * 32,
            handle_sha256=load.ZERO_DIGEST,
            output_sha256=load.ZERO_DIGEST,
            terminal_sha256=load.ZERO_DIGEST,
            completion_sha256=load.ZERO_DIGEST,
            outcome=load.OUTCOME_TIMED_OUT,
        )
        semantic = load._queued_receive_timeout_semantic_root(
            sidecar
        )
        bound = replace(sidecar, output_sha256=semantic)
        terminal = load._queued_receive_timeout_terminal_root(
            bound
        )
        bound = replace(bound, terminal_sha256=terminal)
        completion = (
            load._queued_receive_timeout_completion_root(bound)
        )
        self.assertEqual(
            raw_request.hex(),
            "141379cabcc44e0d4d6602df7de57c018"
            "7003ee2a09c45c1834802c9fce24ae5",
        )
        self.assertEqual(
            semantic.hex(),
            "8318b0766be34ec3bd6454060ef8b47f"
            "3d27c1d8b8d657f6d102702921616d7b",
        )
        self.assertEqual(
            terminal.hex(),
            "a4d614bd88a46b98607d5687cc6fbe01"
            "aca2c2f56c5cfd58223eaaae869cfcf1",
        )
        self.assertEqual(
            completion.hex(),
            "9bed6ceaf46ad62bb09dcd9c20938e62"
            "dacc9a3a4c5b5a62f039e0638f5d901a",
        )

    def test_retention_capacity_profile_binds_mixed_outcomes(self) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture(load.RETENTION_CAPACITY_PROFILE_NAME)
        )

        def verify(
            candidate_sidecars: tuple[load.Sidecar, ...] = sidecars,
            candidate_closure: tuple[int, ...] = closure,
            candidate_profile: load.InnerProfile = profile,
        ) -> None:
            load._verify_profile(
                candidate_sidecars,
                candidate_closure,
                candidate_profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
                profile_name=load.RETENTION_CAPACITY_PROFILE_NAME,
            )

        verify()
        measured = profile.records[load.WARMUP_COUNT :]
        self.assertEqual(
            sum(
                record.outcome == load.OUTCOME_COMPLETED
                for record in measured
            ),
            load.RETENTION_CAPACITY_MEASURED_COMPLETED,
        )
        self.assertEqual(
            sum(
                record.outcome == load.OUTCOME_CAPACITY_REJECTED
                for record in measured
            ),
            load.RETENTION_CAPACITY_MEASURED_REJECTED,
        )
        for flow in range(load.FLOW_COUNT):
            flow_records = [
                record for record in measured if record.flow_id == flow
            ]
            self.assertEqual(
                [
                    record.outcome
                    for record in flow_records
                ].count(load.OUTCOME_COMPLETED),
                4,
            )
            self.assertEqual(
                [
                    record.outcome
                    for record in flow_records
                ].count(load.OUTCOME_CAPACITY_REJECTED),
                4,
            )

        rejected_index = load.RETENTION_CAPACITY_COMPLETED_RECORDS
        rejected = sidecars[rejected_index]
        self.assertNotEqual(rejected.output_sha256, load.ZERO_DIGEST)
        self.assertEqual(
            profile.records[rejected_index].roots[5],
            load.ZERO_DIGEST,
        )
        mutations = {
            "outcome": replace(
                rejected,
                outcome=load.OUTCOME_COMPLETED,
            ),
            "work": replace(rejected, work_sequence=1),
            "handle": replace(
                rejected,
                handle_sha256=_digest("forged-handle"),
            ),
            "token": replace(rejected, output_token=1),
            "response": replace(
                rejected,
                response_handle_sha256=load.ZERO_DIGEST,
            ),
            "terminal": replace(
                rejected,
                terminal_sha256=_digest("forged-terminal"),
            ),
            "completion": replace(
                rejected,
                completion_sha256=_digest("forged-completion"),
            ),
            "decision": replace(
                rejected,
                published_ns=profile.records[rejected_index].points[5][0]
                + 1,
                retired_ns=profile.records[rejected_index].points[6][0],
            ),
        }
        for label, mutation in mutations.items():
            candidate = list(sidecars)
            candidate[rejected_index] = mutation
            with self.subTest(sidecar_mutation=label):
                with self.assertRaises(load.VerificationError):
                    verify(tuple(candidate))

        forged_semantics = replace(
            rejected,
            output_sha256=_digest("forged-response-semantics"),
        )
        forged_semantics = replace(
            forged_semantics,
            completion_sha256=(
                load._retention_capacity_completion_root(
                    forged_semantics
                )
            ),
        )
        forged_semantic_sidecars = list(sidecars)
        forged_semantic_sidecars[rejected_index] = forged_semantics
        forged_semantic_records = list(profile.records)
        forged_semantic_records[rejected_index] = replace(
            forged_semantic_records[rejected_index],
            roots=(
                *forged_semantic_records[rejected_index].roots[:8],
                forged_semantics.completion_sha256,
            ),
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "response semantic root mismatch",
        ):
            verify(
                tuple(forged_semantic_sidecars),
                candidate_profile=replace(
                    profile,
                    records=tuple(forged_semantic_records),
                ),
            )

        # The verifier does not retain the raw HTTP response, so this
        # domain-separated digest is intentionally opaque. Its nonzero,
        # unique value is accepted when the completion root binds it.
        opaque_response_evidence = replace(
            rejected,
            response_handle_sha256=_digest(
                "alternate-opaque-http-response"
            ),
        )
        opaque_response_evidence = replace(
            opaque_response_evidence,
            completion_sha256=(
                load._retention_capacity_completion_root(
                    opaque_response_evidence
                )
            ),
        )
        opaque_sidecars = list(sidecars)
        opaque_sidecars[rejected_index] = opaque_response_evidence
        opaque_records = list(profile.records)
        opaque_records[rejected_index] = replace(
            opaque_records[rejected_index],
            roots=(
                *opaque_records[rejected_index].roots[:8],
                opaque_response_evidence.completion_sha256,
            ),
        )
        verify(
            tuple(opaque_sidecars),
            candidate_profile=replace(
                profile,
                records=tuple(opaque_records),
            ),
        )

        duplicate_evidence = list(sidecars)
        duplicate_evidence[rejected_index + 1] = replace(
            duplicate_evidence[rejected_index + 1],
            response_handle_sha256=rejected.response_handle_sha256,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "response evidence is duplicated",
        ):
            verify(tuple(duplicate_evidence))

        record_mutations = {
            "presence": replace(
                profile.records[rejected_index],
                presence_mask=0x7F,
            ),
            "queue": replace(
                profile.records[rejected_index],
                queue_slot=0,
            ),
            "admission": replace(
                profile.records[rejected_index],
                points=(
                    profile.records[rejected_index].points[0],
                    (1, 1),
                    *profile.records[rejected_index].points[2:],
                ),
            ),
            "root": replace(
                profile.records[rejected_index],
                roots=(
                    *profile.records[rejected_index].roots[:6],
                    _digest("forged-output-root"),
                    *profile.records[rejected_index].roots[7:],
                ),
            ),
        }
        for label, mutation in record_mutations.items():
            records = list(profile.records)
            records[rejected_index] = mutation
            with self.subTest(record_mutation=label):
                with self.assertRaises(load.VerificationError):
                    verify(
                        candidate_profile=replace(
                            profile,
                            records=tuple(records),
                        )
                    )

        identities = list(profile.identities)
        identities[1] = load._identity(load.PROFILE_ID)
        with self.assertRaisesRegex(
            load.VerificationError,
            "scenario identity 1 mismatch",
        ):
            verify(
                candidate_profile=replace(
                    profile,
                    identities=tuple(identities),
                )
            )

        invalid_closure = list(closure)
        invalid_closure[18] = load.RECORD_COUNT
        with self.assertRaisesRegex(
            load.VerificationError,
            "service closure mismatch",
        ):
            verify(candidate_closure=tuple(invalid_closure))

    def test_queued_receive_timeout_profile_binds_exact_epoch_mix(
        self,
    ) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture(
                load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            )
        )

        def verify(
            candidate_sidecars: tuple[load.Sidecar, ...] = sidecars,
            candidate_closure: tuple[int, ...] = closure,
            candidate_profile: load.InnerProfile = profile,
        ) -> None:
            load._verify_profile(
                candidate_sidecars,
                candidate_closure,
                candidate_profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
                profile_name=(
                    load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                ),
            )

        verify()
        self.assertEqual(
            closure,
            load.QUEUED_RECEIVE_TIMEOUT_CLOSURE,
        )
        measured = profile.records[load.WARMUP_COUNT :]
        self.assertEqual(
            sum(
                record.outcome == load.OUTCOME_COMPLETED
                for record in measured
            ),
            load.QUEUED_RECEIVE_TIMEOUT_MEASURED_COMPLETED,
        )
        self.assertEqual(
            sum(
                record.outcome == load.OUTCOME_TIMED_OUT
                for record in measured
            ),
            load.QUEUED_RECEIVE_TIMEOUT_MEASURED_TIMED_OUT,
        )
        for epoch in range(8):
            records = measured[
                epoch * load.FLOW_COUNT :
                (epoch + 1) * load.FLOW_COUNT
            ]
            self.assertEqual(
                [record.outcome for record in records],
                [
                    load.OUTCOME_COMPLETED,
                    load.OUTCOME_COMPLETED,
                    *([load.OUTCOME_TIMED_OUT] * 6),
                ],
            )
            self.assertEqual(
                [record.flow_id for record in records],
                [
                    (epoch + lane) % load.FLOW_COUNT
                    for lane in range(load.FLOW_COUNT)
                ],
            )
        for flow in range(load.FLOW_COUNT):
            records = [
                record
                for record in measured
                if record.flow_id == flow
            ]
            self.assertEqual(
                sum(
                    record.outcome == load.OUTCOME_COMPLETED
                    for record in records
                ),
                2,
            )
            self.assertEqual(
                sum(
                    record.outcome == load.OUTCOME_TIMED_OUT
                    for record in records
                ),
                6,
            )

        timed_out_index = load.WARMUP_COUNT + 2
        timed_out = sidecars[timed_out_index]
        timed_out_record = profile.records[timed_out_index]
        self.assertEqual(
            timed_out.worker_index,
            load.NO_WORKER_INDEX,
        )
        self.assertEqual(timed_out.response_bytes, 0)
        self.assertEqual(timed_out.dispatch_ordinal, 0)
        self.assertEqual(timed_out.dispatch_ns, 0)
        self.assertEqual(
            timed_out.published_ns,
            timed_out.retired_ns,
        )
        self.assertNotEqual(
            timed_out.response_handle_sha256,
            load.ZERO_DIGEST,
        )
        self.assertNotEqual(
            timed_out.output_sha256,
            load.ZERO_DIGEST,
        )
        self.assertEqual(
            timed_out_record.roots[1:7],
            (load.ZERO_DIGEST,) * 6,
        )

        sidecar_mutations = {
            "outcome": replace(
                timed_out,
                outcome=load.OUTCOME_COMPLETED,
            ),
            "response-bytes": replace(
                timed_out,
                response_bytes=1,
            ),
            "dispatch-ordinal": replace(
                timed_out,
                dispatch_ordinal=1,
            ),
            "dispatch-time": replace(
                timed_out,
                dispatch_ns=1,
            ),
            "decision-time": replace(
                timed_out,
                published_ns=timed_out.published_ns + 1,
            ),
            "timeout-ordinal": replace(
                timed_out,
                retired_ordinal=timed_out.enqueue_ordinal,
            ),
            "worker": replace(timed_out, worker_index=0),
            "work": replace(timed_out, work_sequence=1),
            "handle": replace(
                timed_out,
                handle_sha256=_digest("forged-timeout-handle"),
            ),
            "token": replace(timed_out, output_token=1),
            "content": replace(timed_out, content_byte=1),
            "request-evidence": replace(
                timed_out,
                response_handle_sha256=load.ZERO_DIGEST,
            ),
            "transport-semantics": replace(
                timed_out,
                output_sha256=_digest(
                    "forged-timeout-semantics"
                ),
            ),
            "terminal": replace(
                timed_out,
                terminal_sha256=_digest(
                    "forged-timeout-terminal"
                ),
            ),
            "completion": replace(
                timed_out,
                completion_sha256=_digest(
                    "forged-timeout-completion"
                ),
            ),
            "connection": replace(
                timed_out,
                connection_sequence=999,
            ),
            "slot-generation": replace(
                timed_out,
                slot_generation=999,
            ),
            "enqueue-time": replace(
                timed_out,
                enqueue_ns=timed_out.enqueue_ns + 1,
            ),
        }
        for label, mutation in sidecar_mutations.items():
            candidate = list(sidecars)
            candidate[timed_out_index] = mutation
            with self.subTest(sidecar_mutation=label):
                with self.assertRaises(load.VerificationError):
                    verify(tuple(candidate))

        record_mutations = {
            "outcome": replace(
                timed_out_record,
                outcome=load.OUTCOME_COMPLETED,
            ),
            "flow": replace(
                timed_out_record,
                flow_id=(timed_out_record.flow_id + 1)
                % load.FLOW_COUNT,
            ),
            "presence": replace(
                timed_out_record,
                presence_mask=0x7F,
            ),
            "queue": replace(timed_out_record, queue_slot=0),
            "admission": replace(
                timed_out_record,
                points=(
                    timed_out_record.points[0],
                    (1, 1),
                    *timed_out_record.points[2:],
                ),
            ),
            "too-early": replace(
                timed_out_record,
                points=(
                    *timed_out_record.points[:5],
                    (
                        timed_out_record.points[0][0]
                        + load.QUEUED_RECEIVE_TIMEOUT_NS
                        - 1,
                        timed_out_record.points[5][1],
                    ),
                    timed_out_record.points[6],
                ),
            ),
            "sequence": replace(
                timed_out_record,
                points=(
                    timed_out_record.points[0],
                    *timed_out_record.points[1:5],
                    (
                        timed_out_record.points[5][0],
                        timed_out_record.points[0][1],
                    ),
                    timed_out_record.points[6],
                ),
            ),
            "output-root": replace(
                timed_out_record,
                roots=(
                    *timed_out_record.roots[:5],
                    _digest("forged-timeout-output"),
                    *timed_out_record.roots[6:],
                ),
            ),
            "completion-root": replace(
                timed_out_record,
                roots=(
                    *timed_out_record.roots[:8],
                    _digest("forged-timeout-record-completion"),
                ),
            ),
        }
        for label, mutation in record_mutations.items():
            records = list(profile.records)
            records[timed_out_index] = mutation
            with self.subTest(record_mutation=label):
                with self.assertRaises(load.VerificationError):
                    verify(
                        candidate_profile=replace(
                            profile,
                            records=tuple(records),
                        )
                    )

        alternate_evidence = replace(
            timed_out,
            response_handle_sha256=_digest(
                "alternate-opaque-timeout-request"
            ),
        )
        alternate_evidence = replace(
            alternate_evidence,
            completion_sha256=(
                load._queued_receive_timeout_completion_root(
                    alternate_evidence
                )
            ),
        )
        alternate_sidecars = list(sidecars)
        alternate_sidecars[timed_out_index] = alternate_evidence
        alternate_records = list(profile.records)
        alternate_records[timed_out_index] = replace(
            timed_out_record,
            roots=(
                *timed_out_record.roots[:8],
                alternate_evidence.completion_sha256,
            ),
        )
        verify(
            tuple(alternate_sidecars),
            candidate_profile=replace(
                profile,
                records=tuple(alternate_records),
            ),
        )

        duplicate_evidence = list(sidecars)
        duplicate_evidence[timed_out_index + 1] = replace(
            duplicate_evidence[timed_out_index + 1],
            response_handle_sha256=(
                timed_out.response_handle_sha256
            ),
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "request evidence is duplicated",
        ):
            verify(tuple(duplicate_evidence))

        duplicate_owner = list(sidecars)
        duplicate_owner[timed_out_index + 1] = replace(
            duplicate_owner[timed_out_index + 1],
            process_generation=timed_out.process_generation,
            connection_sequence=timed_out.connection_sequence,
            slot_index=timed_out.slot_index,
            slot_generation=timed_out.slot_generation,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "connection sequence is duplicated",
        ):
            verify(tuple(duplicate_owner))

        duplicate_request = list(sidecars)
        duplicate_request[timed_out_index + 1] = replace(
            duplicate_request[timed_out_index + 1],
            request_sha256=timed_out.request_sha256,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "request root is duplicated",
        ):
            verify(tuple(duplicate_request))

        identities = list(profile.identities)
        identities[7] = load._identity(load.PLACEMENT_ID)
        with self.assertRaisesRegex(
            load.VerificationError,
            "scenario identity 7 mismatch",
        ):
            verify(
                candidate_profile=replace(
                    profile,
                    identities=tuple(identities),
                )
            )
        with self.assertRaisesRegex(
            load.VerificationError,
            "inner scenario",
        ):
            verify(
                candidate_profile=replace(
                    profile,
                    queue_count=load.QUEUE_COUNT,
                )
            )
        with self.assertRaisesRegex(
            load.VerificationError,
            "throughput identity mismatch",
        ):
            verify(
                candidate_profile=replace(
                    profile,
                    throughput_numerator=(
                        profile.throughput_numerator + 1
                    ),
                )
            )

        for closure_index in (
            0,
            1,
            2,
            4,
            5,
            6,
            7,
            8,
            11,
            18,
            19,
            23,
            25,
            27,
        ):
            invalid_closure = list(closure)
            invalid_closure[closure_index] ^= 1
            with self.subTest(closure_index=closure_index):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "queued receive timeout closure mismatch",
                ):
                    verify(
                        candidate_closure=tuple(
                            invalid_closure
                        )
                    )

    def test_queued_timeout_rejects_resealed_timing_overruns(
        self,
    ) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture(
                load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
            )
        )
        timed_out_index = load.WARMUP_COUNT + 2
        original_sidecar = sidecars[timed_out_index]
        original_record = profile.records[timed_out_index]
        arrival_ns = original_record.points[0][0]

        def candidate(
            *,
            enqueue_ns: int,
            terminal_event_ns: int,
            client_terminal_ns: int,
            joined_settlement_ns: int,
        ) -> tuple[
            tuple[load.Sidecar, ...],
            load.InnerProfile,
        ]:
            rebound = replace(
                original_sidecar,
                enqueue_ns=enqueue_ns,
                published_ns=terminal_event_ns,
                retired_ns=terminal_event_ns,
                output_sha256=load.ZERO_DIGEST,
                terminal_sha256=load.ZERO_DIGEST,
                completion_sha256=load.ZERO_DIGEST,
            )
            rebound = replace(
                rebound,
                output_sha256=(
                    load._queued_receive_timeout_semantic_root(
                        rebound
                    )
                ),
            )
            rebound = replace(
                rebound,
                terminal_sha256=(
                    load._queued_receive_timeout_terminal_root(
                        rebound
                    )
                ),
            )
            rebound = replace(
                rebound,
                completion_sha256=(
                    load._queued_receive_timeout_completion_root(
                        rebound
                    )
                ),
            )

            points = list(original_record.points)
            points[5] = (
                client_terminal_ns,
                original_record.points[5][1],
            )
            points[6] = (
                joined_settlement_ns,
                original_record.points[6][1],
            )
            rebound_record = replace(
                original_record,
                points=tuple(points),
                roots=(
                    rebound.request_sha256,
                    *([load.ZERO_DIGEST] * 6),
                    rebound.terminal_sha256,
                    rebound.completion_sha256,
                ),
            )
            candidate_sidecars = list(sidecars)
            candidate_sidecars[timed_out_index] = rebound
            candidate_records = list(profile.records)
            candidate_records[timed_out_index] = rebound_record
            return (
                tuple(candidate_sidecars),
                replace(
                    profile,
                    records=tuple(candidate_records),
                ),
            )

        def verify(
            candidate_sidecars: tuple[load.Sidecar, ...],
            candidate_profile: load.InnerProfile,
        ) -> None:
            load._verify_profile(
                candidate_sidecars,
                closure,
                candidate_profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
                profile_name=(
                    load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME
                ),
            )

        terminal_event_ns = (
            arrival_ns
            + load.QUEUED_RECEIVE_TIMEOUT_MAX_TERMINAL_NS
        )
        verify(
            *candidate(
                enqueue_ns=(
                    terminal_event_ns
                    - load.QUEUED_RECEIVE_TIMEOUT_MAX_QUEUE_RESIDENCE_NS
                ),
                terminal_event_ns=terminal_event_ns,
                client_terminal_ns=terminal_event_ns,
                joined_settlement_ns=(
                    terminal_event_ns
                    + load.QUEUED_RECEIVE_TIMEOUT_MAX_SETTLEMENT_PROPAGATION_NS
                ),
            )
        )

        late_terminal_event_ns = terminal_event_ns + 1
        with self.assertRaisesRegex(
            load.VerificationError,
            "terminal observation is outside fixed bound",
        ):
            verify(
                *candidate(
                    enqueue_ns=(
                        late_terminal_event_ns
                        - load.QUEUED_RECEIVE_TIMEOUT_MAX_QUEUE_RESIDENCE_NS
                    ),
                    terminal_event_ns=late_terminal_event_ns,
                    client_terminal_ns=late_terminal_event_ns,
                    joined_settlement_ns=late_terminal_event_ns + 1,
                )
            )

        queue_overrun_terminal_event_ns = (
            arrival_ns
            + load.QUEUED_RECEIVE_TIMEOUT_MAX_QUEUE_RESIDENCE_NS
            + 2
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "queue residence exceeds fixed bound",
        ):
            verify(
                *candidate(
                    enqueue_ns=arrival_ns + 1,
                    terminal_event_ns=queue_overrun_terminal_event_ns,
                    client_terminal_ns=queue_overrun_terminal_event_ns,
                    joined_settlement_ns=(
                        queue_overrun_terminal_event_ns + 1
                    ),
                )
            )

        original_terminal_event_ns = original_sidecar.retired_ns
        with self.assertRaisesRegex(
            load.VerificationError,
            "transport settlement propagation exceeds fixed bound",
        ):
            verify(
                *candidate(
                    enqueue_ns=original_sidecar.enqueue_ns,
                    terminal_event_ns=original_terminal_event_ns,
                    client_terminal_ns=original_terminal_event_ns,
                    joined_settlement_ns=(
                        original_terminal_event_ns
                        + load.QUEUED_RECEIVE_TIMEOUT_MAX_SETTLEMENT_PROPAGATION_NS
                        + 1
                    ),
                )
            )

    def test_producer_mode_is_selected_without_another_artifact(self) -> None:
        executable = load.Path("/tmp/glacier-fake-producer")
        digest = _digest("identity")
        for profile_name, expected_mode in (
            (load.SUCCESSFUL_PROFILE_NAME, "--native-load"),
            (
                load.RETENTION_CAPACITY_PROFILE_NAME,
                "--native-load-retention-capacity",
            ),
            (
                load.QUEUED_RECEIVE_TIMEOUT_PROFILE_NAME,
                "--native-load-queued-receive-timeout",
            ),
            (
                load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME,
                "--native-load-open-loop-transient-pressure",
            ),
        ):
            captured: list[list[str]] = []
            stdout_limits: list[int] = []

            def bounded_capture(
                command: list[str],
                **kwargs: object,
            ) -> tuple[int, bytes, bytes]:
                captured.append(command)
                campaign = load._campaign_profile(profile_name)
                stdout_limits.append(int(kwargs["stdout_limit"]))
                return 0, b"\x00" * campaign.outer_bytes, b""

            with self.subTest(profile_name=profile_name), mock.patch.object(
                load,
                "_bounded_capture",
                side_effect=bounded_capture,
            ):
                load._run_producer(
                    executable,
                    digest,
                    digest,
                    digest,
                    1.0,
                    profile_name,
                )
                self.assertEqual(captured[0][1], expected_mode)
                self.assertEqual(len(captured), 1)
                self.assertEqual(
                    stdout_limits,
                    [
                        load._campaign_profile(
                            profile_name
                        ).outer_bytes
                    ],
                )

    def test_profile_composes_transport_roots_and_exact_closure(self) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture()
        )
        load._verify_profile(
            sidecars,
            closure,
            profile,
            expected_build=build,
            expected_machine=machine,
            expected_challenge=challenge,
            system="Darwin",
        )

        corrupted_sidecars = list(sidecars)
        corrupted_sidecars[9] = replace(
            corrupted_sidecars[9],
            published_ns=corrupted_sidecars[9].published_ns + 1,
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "publication timestamp mismatch",
        ):
            load._verify_profile(
                tuple(corrupted_sidecars),
                closure,
                profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
            )

        mismatched_handles = list(sidecars)
        mismatched_handles[10] = replace(
            mismatched_handles[10],
            response_handle_sha256=_digest("forged-response-handle"),
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "HTTP response handle/work handle mismatch",
        ):
            load._verify_profile(
                tuple(mismatched_handles),
                closure,
                profile,
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
            )

        for root_index in (3, 5, 7, 8):
            corrupted_records = list(profile.records)
            roots = list(corrupted_records[11].roots)
            roots[root_index] = _digest("forged-root-%d" % root_index)
            corrupted_records[11] = replace(
                corrupted_records[11],
                roots=tuple(roots),
            )
            with self.subTest(root_index=root_index):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "transport root composition mismatch",
                ):
                    load._verify_profile(
                        sidecars,
                        closure,
                        replace(profile, records=tuple(corrupted_records)),
                        expected_build=build,
                        expected_machine=machine,
                        expected_challenge=challenge,
                        system="Darwin",
                    )

    def test_profile_rejects_resealed_noncanonical_counter_streams(
        self,
    ) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture()
        )

        def verify(
            candidate_sidecars: list[load.Sidecar],
            candidate_records: list[load.InnerRecord],
        ) -> None:
            load._verify_profile(
                tuple(candidate_sidecars),
                closure,
                replace(profile, records=tuple(candidate_records)),
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
            )

        mutations = (
            (
                "connection",
                load.RECORD_COUNT - 1,
                {"connection_sequence": 999},
                "connection sequence is not canonical",
            ),
            (
                "slot-generation",
                load.SUCCESSFUL_PROFILE.connection_capacity,
                {"slot_generation": 1},
                "slot generation is not canonical",
            ),
            (
                "work",
                0,
                {"work_sequence": 999},
                "work sequence is not canonical",
            ),
        )
        for label, index, changes, message in mutations:
            candidate_sidecars = list(sidecars)
            candidate_records = list(profile.records)
            (
                candidate_sidecars[index],
                candidate_records[index],
            ) = _reroot_completed(
                candidate_sidecars[index],
                candidate_records[index],
                **changes,
            )
            with self.subTest(counter=label):
                with self.assertRaisesRegex(
                    load.VerificationError,
                    message,
                ):
                    verify(candidate_sidecars, candidate_records)

    def test_profile_rejects_resealed_lifecycle_order_and_closure_gaps(
        self,
    ) -> None:
        sidecars, closure, profile, build, machine, challenge = (
            _profile_fixture()
        )

        wrong_event_count = list(closure)
        wrong_event_count[27] += 1
        with self.assertRaisesRegex(
            load.VerificationError,
            "event stream closure mismatch",
        ):
            load._verify_closure(tuple(wrong_event_count))

        excessive_backpressure = list(closure)
        excessive_backpressure[7] = load.RECORD_COUNT + 1
        excessive_backpressure[8] = load.RECORD_COUNT + 1
        excessive_backpressure[27] = (
            load.RECORD_COUNT * 3
            + excessive_backpressure[7]
            + excessive_backpressure[8]
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "backpressure activations exceed accepted connections",
        ):
            load._verify_closure(tuple(excessive_backpressure))

        candidate_sidecars = list(sidecars)
        candidate_records = list(profile.records)
        candidate_sidecars[0], candidate_records[0] = (
            _reroot_completed(
                candidate_sidecars[0],
                candidate_records[0],
                enqueue_ordinal=217,
                dispatch_ordinal=218,
                retired_ordinal=219,
            )
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "lifecycle ordinal contradicts timestamp order",
        ):
            load._verify_profile(
                tuple(candidate_sidecars),
                closure,
                replace(profile, records=tuple(candidate_records)),
                expected_build=build,
                expected_machine=machine,
                expected_challenge=challenge,
                system="Darwin",
            )

    def test_sidecar_slots_use_managed_connection_capacity(self) -> None:
        for profile_name in load.CAMPAIGN_PROFILES:
            campaign = load._campaign_profile(profile_name)
            sidecars, closure, profile, build, machine, challenge = (
                _profile_fixture(profile_name)
            )
            with self.subTest(profile=profile_name):
                self.assertEqual(
                    campaign.connection_capacity,
                    campaign.worker_count + campaign.pending_capacity,
                )
                self.assertEqual(
                    max(sidecar.slot_index for sidecar in sidecars),
                    campaign.connection_capacity - 1,
                )
                load._verify_profile(
                    sidecars,
                    closure,
                    profile,
                    expected_build=build,
                    expected_machine=machine,
                    expected_challenge=challenge,
                    system="Darwin",
                    profile_name=profile_name,
                )
                invalid_sidecars = list(sidecars)
                invalid_sidecars[0] = replace(
                    invalid_sidecars[0],
                    slot_index=campaign.connection_capacity,
                )
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "slot index is out of range",
                ):
                    load._verify_profile(
                        tuple(invalid_sidecars),
                        closure,
                        profile,
                        expected_build=build,
                        expected_machine=machine,
                        expected_challenge=challenge,
                        system="Darwin",
                        profile_name=profile_name,
                    )

    def test_completed_timing_samples_and_manifest_fields_are_scoped(
        self,
    ) -> None:
        old_fields = {
            "admission_p99_ns",
            "queue_p99_ns",
            "http_first_byte_p99_ns",
        }
        for profile_name in load.CAMPAIGN_PROFILES:
            campaign = load._campaign_profile(profile_name)
            sidecars, closure, profile, build, machine, challenge = (
                _profile_fixture(profile_name)
            )
            with self.subTest(profile=profile_name):
                self.assertEqual(
                    (
                        profile.admission_sample_count,
                        profile.queue_sample_count,
                        profile.first_byte_sample_count,
                    ),
                    (campaign.measured_completed,) * 3,
                )
                fields = load._completed_timing_fields(profile)
                self.assertTrue(old_fields.isdisjoint(fields))
                self.assertEqual(
                    fields[
                        "completed_arrival_to_fifo_enqueue_sample_count"
                    ],
                    campaign.measured_completed,
                )
                self.assertEqual(
                    fields[
                        "completed_fifo_enqueue_to_worker_dispatch_sample_count"
                    ],
                    campaign.measured_completed,
                )
                self.assertEqual(
                    fields[
                        "completed_http_first_positive_read_sample_count"
                    ],
                    campaign.measured_completed,
                )
                with self.assertRaisesRegex(
                    load.VerificationError,
                    "completed timing sample count mismatch",
                ):
                    load._verify_profile(
                        sidecars,
                        closure,
                        replace(
                            profile,
                            admission_sample_count=(
                                campaign.measured_completed + 1
                            ),
                        ),
                        expected_build=build,
                        expected_machine=machine,
                        expected_challenge=challenge,
                        system="Darwin",
                        profile_name=profile_name,
                    )

    def test_inner_parser_retains_distribution_sample_counts(
        self,
    ) -> None:
        inner = bytearray(load.INNER_BYTES)
        summary_offset = (
            load.native_workload_report.HEADER_BYTES
            + load.native_workload_report.SCENARIO_WIRE_BYTES
            + load.RECORD_COUNT
            * load.native_workload_report.RECORD_WIRE_BYTES
        )
        expected = ((32, 101), (24, 202), (16, 303))
        for index, (sample_count, p99_ns) in enumerate(expected):
            distribution_offset = summary_offset + 100 + index * 40
            struct.pack_into(
                "<I",
                inner,
                distribution_offset,
                sample_count,
            )
            struct.pack_into(
                "<Q",
                inner,
                distribution_offset + 24,
                p99_ns,
            )
        profile = load._parse_inner_profile(bytes(inner))
        self.assertEqual(
            (
                profile.admission_sample_count,
                profile.admission_p99_ns,
                profile.queue_sample_count,
                profile.queue_p99_ns,
                profile.first_byte_sample_count,
                profile.first_byte_p99_ns,
            ),
            tuple(value for pair in expected for value in pair),
        )

    def test_cli_reports_completed_timing_scope_and_sample_count(
        self,
    ) -> None:
        profile_name = load.RETENTION_CAPACITY_PROFILE_NAME
        sidecars, closure, profile, _, _, _ = _profile_fixture(
            profile_name
        )
        verified = load.VerifiedEnvelope(
            inner_result=mock.Mock(),
            profile=profile,
            sidecars=sidecars,
            closure=closure,
            outer_sha256=_digest("outer"),
        )
        stdout = io.StringIO()
        with mock.patch.object(
            load,
            "run_campaign",
            return_value=(
                b"verified",
                {"publication_eligible": False},
                verified,
            ),
        ), mock.patch.object(sys, "stdout", stdout):
            self.assertEqual(
                load.main(["producer", "--profile", profile_name]),
                0,
            )
        output = stdout.getvalue()
        self.assertNotIn("http_first_byte_p99_ns=", output)
        self.assertIn(
            "completed_http_first_positive_read_p99_ns=4",
            output,
        )
        self.assertIn(
            "completed_http_first_positive_read_sample_count=32",
            output,
        )
        self.assertIn(
            "completed_arrival_to_fifo_enqueue_sample_count=32",
            output,
        )

    def test_publication_offline_verifier_uses_only_bound_context(
        self,
    ) -> None:
        bundle, verified, challenge, _ = _publication_fixture()
        context = bundle.manifest["publication_context"]
        producer = context["producer"]
        machine = bytes.fromhex(
            context["machine_fingerprint_sha256"]
        )
        with mock.patch.object(
            load,
            "verify_envelope",
            return_value=verified,
        ) as verify, mock.patch.object(
            load.platform,
            "system",
            side_effect=AssertionError("offline verifier read host system"),
        ), mock.patch.object(
            load,
            "_capture_native_observation",
            side_effect=AssertionError("offline verifier sampled host"),
        ), mock.patch.object(
            load.native_environment_admission,
            "wait_for_stable_admission",
            side_effect=AssertionError(
                "offline verifier ran environment admission"
            ),
        ), mock.patch.object(
            load.lane4_evidence,
            "capture_environment",
            side_effect=AssertionError(
                "offline verifier captured environment"
            ),
        ):
            self.assertIs(
                load.verify_publication_bundle(bundle),
                verified,
            )
        verify.assert_called_once_with(
            bundle.envelope,
            expected_build=bytes.fromhex(producer["sha256"]),
            expected_machine=machine,
            expected_challenge=challenge,
            system="Darwin",
            profile_name=load.SUCCESSFUL_PROFILE_NAME,
        )

    def test_open_loop_publication_round_trip_recomputes_schedule(
        self,
    ) -> None:
        profile_name = load.OPEN_LOOP_TRANSIENT_PRESSURE_PROFILE_NAME
        bundle, verified, challenge, _ = _publication_fixture(
            profile_name=profile_name
        )
        context = bundle.manifest["publication_context"]
        producer = context["producer"]
        machine = bytes.fromhex(
            context["machine_fingerprint_sha256"]
        )
        with mock.patch.object(
            load,
            "verify_envelope",
            return_value=verified,
        ) as verify, mock.patch.object(
            load.platform,
            "system",
            side_effect=AssertionError(
                "offline open-loop verification read host system"
            ),
        ), mock.patch.object(
            load,
            "_capture_native_observation",
            side_effect=AssertionError(
                "offline open-loop verification sampled host"
            ),
        ):
            self.assertIs(
                load.verify_publication_bundle(bundle),
                verified,
            )
        verify.assert_called_once_with(
            bundle.envelope,
            expected_build=bytes.fromhex(producer["sha256"]),
            expected_machine=machine,
            expected_challenge=challenge,
            system="Darwin",
            profile_name=profile_name,
        )
        open_loop = bundle.manifest["report"]["open_loop"]
        self.assertEqual(
            open_loop["arrival_policy"],
            "scheduled-open-loop",
        )
        self.assertEqual(
            open_loop["pressure_gate"]["queue_high_water"],
            8,
        )
        self.assertEqual(
            open_loop["recovery"]["minimum_slack_ns"],
            load.OPEN_LOOP_RECOVERY_SLACK_NS,
        )

        mutated_manifest = copy.deepcopy(bundle.manifest)
        mutated_manifest["report"]["open_loop"]["phases"][
            "pressure"
        ]["actual_client_launch_span_ns"] += 1
        mutated_bundle = load.publication.decode_bundle(
            load.publication.encode_bundle(
                bundle.envelope,
                mutated_manifest,
            )
        )
        with mock.patch.object(
            load,
            "verify_envelope",
            return_value=verified,
        ), self.assertRaisesRegex(
            load.VerificationError,
            "publication report summary mismatch",
        ):
            load.verify_publication_bundle(mutated_bundle)

    def test_publication_bundle_api_reconstructs_structural_identity(
        self,
    ) -> None:
        bundle, _, _, _ = _publication_fixture()
        mutations = {
            "manifest_bytes": replace(
                bundle,
                manifest_bytes=bundle.manifest_bytes + b" ",
            ),
            "envelope_sha256": replace(
                bundle,
                envelope_sha256=_digest("wrong-envelope"),
            ),
            "manifest_sha256": replace(
                bundle,
                manifest_sha256=_digest("wrong-manifest"),
            ),
            "publication_identity_sha256": replace(
                bundle,
                publication_identity_sha256=_digest(
                    "wrong-publication-identity"
                ),
            ),
            "bundle_sha256": replace(
                bundle,
                bundle_sha256=_digest("wrong-bundle"),
            ),
        }
        for field, mutated in mutations.items():
            with self.subTest(field=field), self.assertRaisesRegex(
                load.VerificationError,
                field,
            ):
                load.verify_publication_bundle(mutated)

    def test_linux_publication_environment_uses_exact_native_schema(
        self,
    ) -> None:
        adapter = load.native_observer_linux.LinuxObserver(
            reader=lambda _path, _maximum: (
                b"MemAvailable: 1048576 kB\n"
            )
        )
        with mock.patch.object(
            load.native_observer.platform,
            "system",
            return_value="Linux",
        ):
            before = load.native_observer.capture_observation(
                "pre_run",
                platform_adapter=adapter,
                logical_cpu_count=8,
                process_id=1234,
            )
            after = load.native_observer.capture_observation(
                "post_run",
                platform_adapter=adapter,
                logical_cpu_count=8,
                process_id=1234,
            )
        machine: dict[str, object] = {
            "system": "Linux",
            "release": "fixture-release",
            "machine": "x86_64",
            "processor": "Fixture CPU",
            "logical_cpu_count": 8,
            "boot_session_sha256": _digest(
                "linux-boot-session"
            ).hex(),
        }
        canonical_machine = load.json.dumps(
            machine,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
        fingerprint = hashlib.sha256(canonical_machine).digest()
        machine["fingerprint_sha256"] = fingerprint.hex()
        cpu_boundary = load._validate_native_boundaries(
            before,
            after,
            system="Linux",
        )
        environment = {
            "stable_pre_run_admission": [],
            "pre_run_native_observation": before,
            "post_run_admission": None,
            "post_run_native_observation": after,
            "cpu_boundary": cpu_boundary,
        }
        expected_pre, expected_post = (
            load._publication_environment_roots(environment)
        )
        actual_boundary, actual_pre, actual_post = (
            load._verify_publication_environment(
                environment,
                system="Linux",
                machine_fingerprint=fingerprint,
                machine_logical_cpu_count=8,
            )
        )
        self.assertEqual(actual_boundary, cpu_boundary)
        self.assertEqual(actual_pre, expected_pre)
        self.assertEqual(actual_post, expected_post)

    def test_run_campaign_builds_exact_publication_context(self) -> None:
        bundle, verified, challenge, _ = _publication_fixture()
        machine = _darwin_machine_descriptor()
        admission = _admitted_environment(machine)
        before = _observation(busy=300_000, external=150_000)
        after = _observation(busy=340_000, external=170_000)
        with tempfile.TemporaryDirectory() as temporary_directory:
            producer = load.Path(temporary_directory) / "producer"
            producer.write_bytes(b"fixed-producer")
            producer_sha256 = hashlib.sha256(
                b"fixed-producer"
            ).digest()
            with mock.patch.object(
                load.platform,
                "system",
                return_value="Darwin",
            ), mock.patch.object(
                load.native_environment_admission,
                "wait_for_stable_admission",
                return_value=SimpleNamespace(
                    captures=(admission, copy.deepcopy(admission))
                ),
            ), mock.patch.object(
                load,
                "_capture_native_observation",
                side_effect=(before, after),
            ), mock.patch.object(
                load.secrets,
                "token_bytes",
                return_value=challenge,
            ), mock.patch.object(
                load,
                "_run_producer",
                return_value=bundle.envelope,
            ), mock.patch.object(
                load.lane4_evidence,
                "capture_environment",
                return_value=copy.deepcopy(admission),
            ), mock.patch.object(
                load,
                "verify_envelope",
                return_value=verified,
            ) as verify:
                encoded, manifest, actual_verified = (
                    load.run_campaign(producer)
                )
        self.assertEqual(encoded, bundle.envelope)
        self.assertIs(actual_verified, verified)
        context = manifest["publication_context"]
        self.assertEqual(
            context["challenge_hex"],
            challenge.hex(),
        )
        self.assertEqual(
            context["challenge_sha256"],
            hashlib.sha256(challenge).hexdigest(),
        )
        self.assertEqual(
            context["producer"]["sha256"],
            producer_sha256.hex(),
        )
        self.assertEqual(
            context["machine_fingerprint_sha256"],
            machine["fingerprint_sha256"],
        )
        self.assertEqual(
            context["eligibility"],
            {
                "policy": load.PUBLICATION_ELIGIBILITY_POLICY,
                "decision": "eligible",
                "reasons": [],
                "publishable_external_cpu_ppm": (
                    load.PUBLISHABLE_EXTERNAL_CPU_PPM
                ),
            },
        )
        pre_root, post_root = load._publication_environment_roots(
            manifest["environment"]
        )
        self.assertEqual(
            context["pre_environment_sha256"],
            pre_root.hex(),
        )
        self.assertEqual(
            context["post_environment_sha256"],
            post_root.hex(),
        )
        verify.assert_called_once_with(
            bundle.envelope,
            expected_build=producer_sha256,
            expected_machine=bytes.fromhex(
                str(machine["fingerprint_sha256"])
            ),
            expected_challenge=challenge,
            system="Darwin",
            profile_name=load.SUCCESSFUL_PROFILE_NAME,
        )

    def test_publication_rejects_coherently_resealed_context_mutations(
        self,
    ) -> None:
        eligible_bundle, verified, _, _ = _publication_fixture()
        ineligible_bundle, ineligible_verified, _, _ = (
            _publication_fixture(publication_eligible=False)
        )
        mutations: list[
            tuple[
                str,
                load.publication.PublicationBundle,
                load.VerifiedEnvelope,
                str,
                object,
            ]
        ] = []

        challenge_manifest = copy.deepcopy(eligible_bundle.manifest)
        challenge_manifest["publication_context"][
            "challenge_sha256"
        ] = _digest("wrong-challenge-digest").hex()
        mutations.append(
            (
                "challenge",
                eligible_bundle,
                verified,
                "challenge digest mismatch",
                challenge_manifest,
            )
        )

        environment_manifest = copy.deepcopy(eligible_bundle.manifest)
        environment_manifest["publication_context"][
            "pre_environment_sha256"
        ] = _digest("wrong-pre-environment").hex()
        mutations.append(
            (
                "environment",
                eligible_bundle,
                verified,
                "environment root mismatch",
                environment_manifest,
            )
        )

        eligibility_manifest = copy.deepcopy(ineligible_bundle.manifest)
        eligibility_manifest["publication_context"]["eligibility"][
            "reasons"
        ] = []
        mutations.append(
            (
                "eligibility",
                ineligible_bundle,
                ineligible_verified,
                "eligibility context mismatch",
                eligibility_manifest,
            )
        )

        decision_manifest = copy.deepcopy(ineligible_bundle.manifest)
        decision_manifest["publication_eligible"] = True
        mutations.append(
            (
                "decision",
                ineligible_bundle,
                ineligible_verified,
                "eligibility decision mismatch",
                decision_manifest,
            )
        )

        cpu_type_manifest = copy.deepcopy(eligible_bundle.manifest)
        cpu_type_manifest["environment"]["cpu_boundary"][
            "logical_cpu_count"
        ] = 8.0
        mutations.append(
            (
                "cpu-boundary-type",
                eligible_bundle,
                verified,
                "retained CPU boundary is inconsistent",
                cpu_type_manifest,
            )
        )

        eligibility_type_manifest = copy.deepcopy(
            eligible_bundle.manifest
        )
        eligibility_type_manifest["publication_context"][
            "eligibility"
        ]["publishable_external_cpu_ppm"] = float(
            load.PUBLISHABLE_EXTERNAL_CPU_PPM
        )
        mutations.append(
            (
                "eligibility-type",
                eligible_bundle,
                verified,
                "eligibility context mismatch",
                eligibility_type_manifest,
            )
        )

        producer_type_manifest = copy.deepcopy(
            eligible_bundle.manifest
        )
        producer_type_manifest["producer"]["size_bytes"] = 1234.0
        mutations.append(
            (
                "producer-alias-type",
                eligible_bundle,
                verified,
                "producer alias mismatch",
                producer_type_manifest,
            )
        )

        report_type_manifest = copy.deepcopy(eligible_bundle.manifest)
        report_type_manifest["report"]["bytes"] = float(
            len(eligible_bundle.envelope)
        )
        mutations.append(
            (
                "report-type",
                eligible_bundle,
                verified,
                "report summary mismatch",
                report_type_manifest,
            )
        )

        observation_schema_manifest = copy.deepcopy(
            eligible_bundle.manifest
        )
        del observation_schema_manifest["environment"][
            "pre_run_native_observation"
        ]["schema"]
        mutations.append(
            (
                "observation-schema",
                eligible_bundle,
                verified,
                "fields are not exact",
                observation_schema_manifest,
            )
        )

        admission_schema_manifest = copy.deepcopy(
            eligible_bundle.manifest
        )
        admission_schema_manifest["environment"][
            "stable_pre_run_admission"
        ][0]["unexpected"] = True
        mutations.append(
            (
                "admission-schema",
                eligible_bundle,
                verified,
                "fields are not exact",
                admission_schema_manifest,
            )
        )

        logical_cpu_manifest = copy.deepcopy(eligible_bundle.manifest)
        logical_environment = logical_cpu_manifest["environment"]
        logical_environment["pre_run_native_observation"] = (
            _publication_observation(
                phase="pre_run",
                busy=300_000,
                external=150_000,
                logical_cpu_count=16,
            )
        )
        logical_environment["post_run_native_observation"] = (
            _publication_observation(
                phase="post_run",
                busy=340_000,
                external=170_000,
                logical_cpu_count=16,
            )
        )
        logical_environment["cpu_boundary"] = (
            load._validate_native_boundaries(
                logical_environment[
                    "pre_run_native_observation"
                ],
                logical_environment[
                    "post_run_native_observation"
                ],
                system="Darwin",
            )
        )
        logical_pre_root, logical_post_root = (
            load._publication_environment_roots(
                logical_environment
            )
        )
        logical_cpu_manifest["publication_context"][
            "pre_environment_sha256"
        ] = logical_pre_root.hex()
        logical_cpu_manifest["publication_context"][
            "post_environment_sha256"
        ] = logical_post_root.hex()
        mutations.append(
            (
                "logical-cpu-cross-binding",
                eligible_bundle,
                verified,
                "does not match the machine",
                logical_cpu_manifest,
            )
        )

        for (
            label,
            original,
            expected_verified,
            error,
            mutated_manifest,
        ) in mutations:
            resealed = load.publication.decode_bundle(
                load.publication.encode_bundle(
                    original.envelope,
                    mutated_manifest,
                )
            )
            with self.subTest(label=label), mock.patch.object(
                load,
                "verify_envelope",
                return_value=expected_verified,
            ), self.assertRaisesRegex(load.VerificationError, error):
                load.verify_publication_bundle(resealed)

    def test_publication_cli_writes_one_bundle_and_verifies_offline(
        self,
    ) -> None:
        bundle, verified, _, _ = _publication_fixture()
        with tempfile.TemporaryDirectory() as temporary_directory:
            publication_path = load.Path(
                temporary_directory
            ) / "capture.gf1pub"
            stdout = io.StringIO()
            with mock.patch.object(
                load,
                "run_campaign",
                return_value=(
                    bundle.envelope,
                    bundle.manifest,
                    verified,
                ),
            ), mock.patch.object(
                load,
                "verify_envelope",
                return_value=verified,
            ), mock.patch.object(sys, "stdout", stdout):
                self.assertEqual(
                    load.main(
                        [
                            "producer",
                            "--publication-output",
                            str(publication_path),
                        ]
                    ),
                    0,
                )
            retained = load.publication.read_bundle(publication_path)
            self.assertEqual(retained.envelope, bundle.envelope)
            self.assertEqual(retained.manifest, bundle.manifest)
            self.assertIn(
                "publication_identity_sha256=",
                stdout.getvalue(),
            )

            stdout = io.StringIO()
            with mock.patch.object(
                load,
                "verify_envelope",
                return_value=verified,
            ), mock.patch.object(
                load.platform,
                "system",
                side_effect=AssertionError(
                    "offline CLI read host system"
                ),
            ), mock.patch.object(
                load,
                "_capture_native_observation",
                side_effect=AssertionError(
                    "offline CLI sampled host"
                ),
            ), mock.patch.object(sys, "stdout", stdout):
                self.assertEqual(
                    load.main(
                        [
                            "--verify-publication",
                            str(publication_path),
                        ]
                    ),
                    0,
                )
            self.assertIn(
                retained.publication_identity_sha256.hex(),
                stdout.getvalue(),
            )

    def test_publication_cli_preserves_predecessor_on_semantic_failure(
        self,
    ) -> None:
        bundle, verified, _, _ = _publication_fixture()
        invalid_manifest = copy.deepcopy(bundle.manifest)
        invalid_manifest["publication_context"][
            "challenge_sha256"
        ] = _digest("invalid-challenge-digest").hex()
        predecessor = load.publication.encode_bundle(
            b"predecessor-envelope",
            {"generation": 1},
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            publication_path = load.Path(
                temporary_directory
            ) / "capture.glpub"
            publication_path.write_bytes(predecessor)
            with mock.patch.object(
                load,
                "run_campaign",
                return_value=(
                    bundle.envelope,
                    invalid_manifest,
                    verified,
                ),
            ), mock.patch.object(
                load,
                "verify_envelope",
                return_value=verified,
            ), mock.patch.object(sys, "stderr", io.StringIO()):
                self.assertEqual(
                    load.main(
                        [
                            "producer",
                            "--publication-output",
                            str(publication_path),
                        ]
                    ),
                    1,
                )
            self.assertEqual(
                publication_path.read_bytes(),
                predecessor,
            )

    def test_closure_rejects_each_material_class(self) -> None:
        valid = _valid_closure()
        load._verify_closure(valid)
        for index in (0, 2, 5, 6, 8, 9, 13, 18, 20, 23, 25, 26, 27):
            mutated = list(valid)
            mutated[index] = 0 if index == 27 else 99
            with self.subTest(index=index):
                with self.assertRaises(load.VerificationError):
                    load._verify_closure(tuple(mutated))

    def test_cpu_boundaries_require_stability_but_retain_eligibility(self) -> None:
        before = _observation(busy=300_000, external=150_000)
        after = _observation(busy=360_000, external=170_000)
        result = load._validate_native_boundaries(
            before,
            after,
            system="Darwin",
        )
        self.assertTrue(result["cpu_load_observation_available"])
        self.assertTrue(result["cpu_publication_eligible"])

        noisier = _observation(busy=360_000, external=240_000)
        result = load._validate_native_boundaries(
            before,
            noisier,
            system="Darwin",
        )
        self.assertFalse(result["cpu_publication_eligible"])

        unstable = _observation(busy=700_000, external=350_001)
        with self.assertRaises(load.VerificationError):
            load._validate_native_boundaries(
                before,
                unstable,
                system="Darwin",
            )

    def test_present_thermal_constraint_must_be_nominal(self) -> None:
        nominal = _observation(
            busy=300_000,
            external=100_000,
            thermal_availability="present",
            thermal_value=0,
        )
        constrained = _observation(
            busy=300_000,
            external=100_000,
            thermal_availability="present",
            thermal_value=1,
        )
        load._validate_native_boundaries(
            nominal,
            nominal,
            system="Darwin",
        )
        with self.assertRaisesRegex(
            load.VerificationError,
            "thermal state is constrained",
        ):
            load._validate_native_boundaries(
                nominal,
                constrained,
                system="Darwin",
            )


if __name__ == "__main__":
    unittest.main()
