from __future__ import annotations

import base64
import hashlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from bench import native_metal_cancellation_storm_report as native
from bench.tests import test_native_workload_report as fixture


TEST_RUNNER_SHA256 = fixture._test_digest(90, 1)
TEST_METALLIB_SHA256 = fixture._test_digest(90, 2)
TEST_CHALLENGE_SHA256 = fixture._test_digest(90, 3)
FRESH_CHALLENGE_SHA256 = fixture._test_digest(90, 4)
TEST_BUILD_SHA256 = native._native_build_sha256(
    TEST_RUNNER_SHA256,
    TEST_METALLIB_SHA256,
)


def _fixture_hash(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _record_root(
    global_wave: int,
    action: int,
    lane: int,
    role: int,
) -> bytes:
    block = global_wave // 8
    wave = global_wave % 8
    return _fixture_hash(
        b"glacier-w7b-metal-cancellation-storm-record-v1\x00",
        native.EXPECTED_PROFILE_SHA256,
        fixture._u64(native.PRODUCER_ABI),
        fixture._u64(block),
        fixture._u64(wave),
        fixture._u64(action),
        fixture._u64(lane),
        fixture._u64(role),
    )


def _capacity_root(global_wave: int, role: int) -> bytes:
    block = global_wave // 8
    wave = global_wave % 8
    probe_flow = global_wave & 1
    next_request = block * 18 + wave * 2 + 3
    next_ticket = block * 2 + 1
    return _fixture_hash(
        b"glacier-w7b-metal-cancellation-storm-capacity-v1\x00",
        native.EXPECTED_PROFILE_SHA256,
        fixture._u64(native.PRODUCER_ABI),
        fixture._u64(block),
        fixture._u64(wave),
        fixture._u64(probe_flow),
        fixture._u64(role),
        fixture._u64(next_request),
        fixture._u64(next_ticket),
    )


def _scenario() -> dict:
    identities = [
        native.EXPECTED_WORKLOAD_SHA256,
        native.EXPECTED_PROFILE_SHA256,
        native.EXPECTED_ARTIFACT_SHA256,
        TEST_BUILD_SHA256,
        fixture._test_digest(91, 0),
        native.EXPECTED_BACKEND_SHA256,
        fixture._test_digest(91, 1),
        fixture._test_digest(91, 2),
        native.EXPECTED_HOST_SOURCE_SHA256,
        native.EXPECTED_HOST_CLOCK_SHA256,
        native.EXPECTED_DEVICE_SOURCE_SHA256,
        native.EXPECTED_DEVICE_CLOCK_SHA256,
        TEST_CHALLENGE_SHA256,
    ]
    value = {
        "abi": fixture.SCENARIO_ABI,
        "mode": native.MODE_CLOSED,
        "evidence": native.EVIDENCE_PRODUCTION_NATIVE,
        "algorithm": 0,
        "warmup": native.EXPECTED_WARMUP_COUNT,
        "measured": native.EXPECTED_MEASURED_COUNT,
        "max_in_flight": native.EXPECTED_MAX_IN_FLIGHT,
        "queue_count": native.EXPECTED_QUEUE_COUNT,
        "flow_count": native.EXPECTED_FLOW_COUNT,
        "identities": identities,
    }
    value["sha"] = fixture._scenario_sha(value)
    return value


def _points(mask: int, sequences: tuple[int, ...]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    cursor = 0
    for index in range(7):
        if mask & (1 << index):
            sequence = sequences[cursor]
            cursor += 1
            result.append((sequence * 10, sequence))
        else:
            result.append((0, 0))
    if cursor != len(sequences):
        raise AssertionError("bad fixture event schedule")
    return result


def _unsupported_device(scenario: dict, reason: bytes) -> dict:
    return {
        "availability": native.AVAILABILITY_UNSUPPORTED,
        "start": 0,
        "end": 0,
        "duration": 0,
        "source": scenario["identities"][10],
        "clock": scenario["identities"][11],
        "reason": reason,
    }


def _unsupported_allocation(scenario: dict, reason: bytes) -> dict:
    return {
        "availability": native.AVAILABILITY_UNSUPPORTED,
        "before": 0,
        "after": 0,
        "source": scenario["identities"][10],
        "reason": reason,
    }


def _admitted_commitment(
    record: dict,
    global_wave: int,
    action: int,
    lane: int,
    terminal_rank: int,
    action_evidence: bytes,
) -> bytes:
    block = global_wave // 8
    wave = global_wave % 8
    return _fixture_hash(
        b"glacier-w7b-metal-cancellation-storm-admitted-v1\x00",
        native.EXPECTED_PROFILE_SHA256,
        fixture._u64(native.PRODUCER_ABI),
        fixture._u64(block),
        fixture._u64(wave),
        fixture._u64(action),
        fixture._u64(lane),
        fixture._u64(terminal_rank),
        fixture._u64(record["outcome"]),
        record["roots"][0],
        record["roots"][2],
        record["roots"][7],
        record["roots"][8],
        action_evidence,
    )


def _cancelled(
    scenario: dict,
    ordinal: int,
    cohort: int,
    global_wave: int,
    lane: int,
    terminal_rank: int,
    sequences: tuple[int, int, int, int],
) -> dict:
    action = (
        native.ACTION_CANCEL_LANE0
        if lane == 0
        else native.ACTION_CANCEL_LANE1
    )
    roots = [fixture.ZERO] * 9
    roots[0] = fixture._test_digest(20, ordinal)
    roots[2] = fixture._test_digest(22, ordinal)
    roots[7] = fixture._test_digest(27, ordinal)
    roots[8] = fixture._test_digest(28, ordinal)
    action_evidence = _record_root(
        global_wave,
        action,
        lane,
        native.ROLE_ACTION_EVIDENCE,
    )
    record = {
        "abi": fixture.RECORD_ABI,
        "ordinal": ordinal,
        "cohort": cohort,
        "outcome": native.OUTCOME_CANCELLED,
        "correctness": native.CORRECTNESS_NOT_APPLICABLE,
        "fallback": False,
        "flow_id": lane,
        "work_units": native.EXPECTED_WORK_UNITS,
        "queue": lane,
        "mask": native.EVENT_CANCELLED,
        "points": _points(native.EVENT_CANCELLED, sequences),
        "roots": roots,
        "maximum_error": 0,
        "device": {},
        "allocation": _unsupported_allocation(
            scenario,
            action_evidence,
        ),
        "logical": [
            1,
            1,
            native.EXPECTED_LEASE_CHARGED_BYTES,
            native.EXPECTED_LEASE_CHARGED_BYTES,
            1,
            0,
            0,
            0,
            0,
            0,
        ],
        "previous": fixture.ZERO,
        "sha": fixture.ZERO,
    }
    record["device"] = _unsupported_device(
        scenario,
        _admitted_commitment(
            record,
            global_wave,
            action,
            lane,
            terminal_rank,
            action_evidence,
        ),
    )
    return record


def _capacity(
    scenario: dict,
    ordinal: int,
    cohort: int,
    global_wave: int,
    sequences: tuple[int, int, int],
) -> dict:
    roots = [fixture.ZERO] * 9
    roots[0] = _capacity_root(global_wave, native.ROLE_REQUEST)
    roots[7] = _capacity_root(global_wave, native.ROLE_TERMINAL)
    roots[8] = _capacity_root(global_wave, native.ROLE_COMPLETION)
    return {
        "abi": fixture.RECORD_ABI,
        "ordinal": ordinal,
        "cohort": cohort,
        "outcome": native.OUTCOME_CAPACITY_REJECTED,
        "correctness": native.CORRECTNESS_NOT_APPLICABLE,
        "fallback": False,
        "flow_id": global_wave & 1,
        "work_units": native.EXPECTED_WORK_UNITS,
        "queue": native.NO_QUEUE_SLOT,
        "mask": native.EVENT_CAPACITY_REJECTED,
        "points": _points(native.EVENT_CAPACITY_REJECTED, sequences),
        "roots": roots,
        "maximum_error": 0,
        "device": _unsupported_device(
            scenario,
            _capacity_root(
                global_wave,
                native.ROLE_TIMING_UNSUPPORTED,
            ),
        ),
        "allocation": _unsupported_allocation(
            scenario,
            _capacity_root(
                global_wave,
                native.ROLE_ALLOCATION_UNSUPPORTED,
            ),
        ),
        "logical": [0] * 10,
        "previous": fixture.ZERO,
        "sha": fixture.ZERO,
    }


def _completed(
    scenario: dict,
    ordinal: int,
    cohort: int,
    lane: int,
    sequences: tuple[int, ...],
) -> dict:
    record = fixture._completed(
        scenario,
        ordinal,
        cohort,
        lane,
        [sequence * 10 for sequence in sequences],
        list(sequences),
    )
    record["work_units"] = native.EXPECTED_WORK_UNITS
    record["maximum_error"] = fixture._f64_bits(1.0e-6)
    record["allocation"]["before"] = 393_216
    record["allocation"]["after"] = 393_216
    record["logical"] = [
        1,
        1,
        native.EXPECTED_LEASE_CHARGED_BYTES,
        native.EXPECTED_LEASE_CHARGED_BYTES,
        1,
        0,
        1,
        0,
        1,
        0,
    ]
    return record


def _challenge_first_lane(global_wave: int) -> int:
    return (
        TEST_CHALLENGE_SHA256[global_wave // 8]
        >> (global_wave % 8)
    ) & 1


def _records(scenario: dict) -> list[dict]:
    records: list[dict] = []
    for block in range(native.BLOCK_COUNT):
        cohort = (
            native.COHORT_WARMUP
            if block == 0
            else native.COHORT_MEASURED
        )
        for wave in range(native.WAVES_PER_BLOCK):
            global_wave = block * 8 + wave
            ordinal = block * 26 + wave * 3
            base = block * 102 + wave * 11
            terminal_first_lane = global_wave & 1
            terminal = [base + 9, base + 9]
            terminal[terminal_first_lane] = base + 8
            settlement_first_lane = _challenge_first_lane(global_wave)
            settlement = [base + 11, base + 11]
            settlement[settlement_first_lane] = base + 10
            records.extend(
                (
                    _cancelled(
                        scenario,
                        ordinal,
                        cohort,
                        global_wave,
                        0,
                        int(terminal_first_lane != 0),
                        (
                            base + 1,
                            base + 3,
                            terminal[0],
                            settlement[0],
                        ),
                    ),
                    _cancelled(
                        scenario,
                        ordinal + 1,
                        cohort,
                        global_wave,
                        1,
                        int(terminal_first_lane != 1),
                        (
                            base + 2,
                            base + 4,
                            terminal[1],
                            settlement[1],
                        ),
                    ),
                    _capacity(
                        scenario,
                        ordinal + 2,
                        cohort,
                        global_wave,
                        (base + 5, base + 6, base + 7),
                    ),
                )
            )
        control_base = block * 102 + 88
        control_ordinal = block * 26 + 24
        records.extend(
            (
                _completed(
                    scenario,
                    control_ordinal,
                    cohort,
                    0,
                    tuple(
                        control_base + value
                        for value in (1, 3, 5, 7, 9, 11, 14)
                    ),
                ),
                _completed(
                    scenario,
                    control_ordinal + 1,
                    cohort,
                    1,
                    tuple(
                        control_base + value
                        for value in (2, 4, 6, 8, 10, 12, 13)
                    ),
                ),
            )
        )
    return records


def _encode_wire(
    scenario: dict,
    records: list[dict],
    summary: dict,
    closure: dict,
) -> bytes:
    report_sha = fixture._hash(
        fixture.REPORT_DOMAIN,
        fixture._u64(fixture.REPORT_ABI),
        scenario["sha"],
        fixture._u32(len(records)),
        records[-1]["sha"],
        summary["sha"],
        closure["sha"],
    )
    body = b"".join(
        (
            fixture._encode_scenario(scenario),
            *(fixture._encode_record(record) for record in records),
            fixture._encode_summary(summary),
            fixture._encode_closure(closure),
            report_sha,
        )
    )
    length = fixture.HEADER_BYTES + len(body) + fixture.WIRE_DIGEST_BYTES
    header = b"".join(
        (
            fixture.MAGIC,
            fixture._u64(fixture.WIRE_ABI),
            fixture._u64(length),
            fixture._u32(1),
            b"\x00" * 4,
            fixture._u32(len(records)),
            b"\x00" * 4,
        )
    )
    body_digest = fixture._hash(fixture.BODY_DOMAIN, body)
    prefix = header + body + body_digest
    return prefix + fixture._hash(fixture.FOOTER_DOMAIN, prefix)


def _storm_fixture(
    scenario_mutator=None,
    records_mutator=None,
    summary_mutator=None,
    closure_mutator=None,
) -> bytes:
    scenario = _scenario()
    if scenario_mutator is not None:
        scenario_mutator(scenario)
        scenario["sha"] = fixture._scenario_sha(scenario)
    records = _records(scenario)
    if records_mutator is not None:
        records_mutator(records)
    fixture._seal_records(scenario, records)
    summary = fixture._summary(scenario, records)
    if summary_mutator is not None:
        summary_mutator(summary)
        summary["sha"] = fixture._summary_sha(summary)
    closure = fixture._closure(records)
    if closure_mutator is not None:
        closure_mutator(closure)
        closure["sha"] = fixture._closure_sha(closure)
    return _encode_wire(scenario, records, summary, closure)


class NativeMetalCancellationStormReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.encoded = _storm_fixture()

    def assertProfileRejected(self, encoded: bytes) -> None:
        with self.assertRaises(
            native.NativeMetalCancellationStormReportError
        ):
            native.verify_native_wire(
                encoded,
                TEST_RUNNER_SHA256,
                TEST_METALLIB_SHA256,
                TEST_CHALLENGE_SHA256,
            )

    def test_exact_w7b_b3_profile_verifies(self) -> None:
        self.assertEqual(len(self.encoded), 163_132)
        self.assertEqual(
            len(self.encoded),
            native.EXPECTED_WIRE_BYTES,
        )
        result = native.verify_native_wire(
            self.encoded,
            TEST_RUNNER_SHA256,
            TEST_METALLIB_SHA256,
            TEST_CHALLENGE_SHA256,
        )
        self.assertEqual(result.record_count, 208)
        self.assertEqual(result.warmup_count, 26)
        self.assertEqual(result.measured_count, 182)
        self.assertEqual(result.cancelled_count, 128)
        self.assertEqual(result.completed_count, 16)
        self.assertEqual(
            result.wire_sha256,
            hashlib.sha256(self.encoded).digest(),
        )

    def test_identity_formulas_are_independently_locked(self) -> None:
        schedule_tuple = (
            native.PRODUCER_ABI,
            8,
            8,
            1,
            3,
            2,
            2,
            2,
            5_544,
            144,
            1,
            2,
            3,
            4,
            5,
        )
        schedule = _fixture_hash(
            b"glacier-w7b-metal-cancellation-storm-schedule-v1\x00",
            *(fixture._u64(value) for value in schedule_tuple),
        )
        self.assertEqual(schedule, native.EXPECTED_SCHEDULE_SHA256)
        self.assertEqual(
            native.EXPECTED_PROFILE_SHA256,
            _fixture_hash(
                b"glacier-w7b-metal-cancellation-storm-profile-v1\x00",
                schedule,
                *(fixture._u64(value) for value in schedule_tuple),
            ),
        )
        self.assertEqual(
            native.EXPECTED_HOST_SOURCE_SHA256,
            _fixture_hash(
                b"glacier-w7b-metal-cancellation-storm-host-source-v1\x00",
                fixture._u64(native.PRODUCER_ABI),
                schedule,
            ),
        )
        self.assertEqual(
            TEST_BUILD_SHA256,
            _fixture_hash(
                b"glacier-w7b-metal-cancellation-storm-native-build-v1\x00",
                fixture._u64(native.PRODUCER_ABI),
                TEST_RUNNER_SHA256,
                TEST_METALLIB_SHA256,
            ),
        )

    def test_every_invariant_identity_is_enforced(self) -> None:
        for identity_index in (0, 1, 2, 3, 5, 8, 9, 10, 11, 12):
            def mutate(
                scenario: dict,
                index: int = identity_index,
            ) -> None:
                scenario["identities"][index] = fixture._test_digest(
                    92,
                    index,
                )

            with self.subTest(identity_index=identity_index):
                self.assertProfileRejected(
                    _storm_fixture(scenario_mutator=mutate)
                )

    def test_dynamic_identities_cannot_be_zero_or_alias(self) -> None:
        def zero_machine(scenario: dict) -> None:
            scenario["identities"][4] = fixture.ZERO

        def alias_device(scenario: dict) -> None:
            scenario["identities"][7] = scenario["identities"][6]

        for mutator in (zero_machine, alias_device):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(scenario_mutator=mutator)
                )

    def test_record_order_cohorts_outcomes_and_flows_are_locked(self) -> None:
        def wrong_warmup(records: list[dict]) -> None:
            records[26]["cohort"] = native.COHORT_WARMUP

        def wrong_cancel_outcome(records: list[dict]) -> None:
            records[0]["outcome"] = native.OUTCOME_FAILED

        def wrong_cancel_lane(records: list[dict]) -> None:
            records[1]["flow_id"] = 0
            records[1]["queue"] = 0

        def wrong_capacity_flow(records: list[dict]) -> None:
            records[5]["flow_id"] = 0

        def wrong_control_lane(records: list[dict]) -> None:
            records[25]["flow_id"] = 0
            records[25]["queue"] = 0

        for mutator in (
            wrong_warmup,
            wrong_cancel_outcome,
            wrong_cancel_lane,
            wrong_capacity_flow,
            wrong_control_lane,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_wave_partial_order_and_challenge_settlement_are_locked(
        self,
    ) -> None:
        def capacity_after_terminal(records: list[dict]) -> None:
            left = records[2]["points"][6]
            right = records[0]["points"][5]
            records[2]["points"][6] = right
            records[0]["points"][5] = left

        def wrong_challenge_settlement(records: list[dict]) -> None:
            left = records[0]["points"][6]
            right = records[1]["points"][6]
            records[0]["points"][6] = right
            records[1]["points"][6] = left

        def early_next_wave(records: list[dict]) -> None:
            left = records[1]["points"][6]
            right = records[3]["points"][0]
            records[1]["points"][6] = right
            records[3]["points"][0] = left

        for mutator in (
            capacity_after_terminal,
            wrong_challenge_settlement,
            early_next_wave,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_both_terminal_orders_are_present_and_rank_is_bound(self) -> None:
        decoded = native._decode_after_portable_verification(self.encoded)
        ranks = []
        for wave in range(64):
            block = wave // 8
            local_wave = wave % 8
            ordinal = block * 26 + local_wave * 3
            lane0, lane1 = decoded.records[ordinal : ordinal + 2]
            ranks.append(native._terminal_rank(lane0, lane1))
        self.assertEqual(set(ranks), {0, 1})

        def swap_terminals_without_rebinding(records: list[dict]) -> None:
            left = records[0]["points"][5]
            right = records[1]["points"][5]
            records[0]["points"][5] = right
            records[1]["points"][5] = left

        self.assertProfileRejected(
            _storm_fixture(
                records_mutator=swap_terminals_without_rebinding,
            )
        )

    def test_control_pair_schedule_and_reverse_settlement_are_locked(
        self,
    ) -> None:
        def wrong_start_interleave(records: list[dict]) -> None:
            left = records[24]["points"][1]
            right = records[25]["points"][0]
            records[24]["points"][1] = right
            records[25]["points"][0] = left

        def wrong_reverse_settlement(records: list[dict]) -> None:
            left = records[24]["points"][6]
            right = records[25]["points"][6]
            records[24]["points"][6] = right
            records[25]["points"][6] = left

        for mutator in (
            wrong_start_interleave,
            wrong_reverse_settlement,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_zero_submit_roots_and_logical_facts_are_enforced(self) -> None:
        def cancel_ticket(records: list[dict]) -> None:
            records[0]["roots"][1] = fixture._test_digest(30, 0)

        def cancel_output(records: list[dict]) -> None:
            records[1]["roots"][5] = fixture._test_digest(30, 1)

        def capacity_pin(records: list[dict]) -> None:
            records[2]["roots"][2] = fixture._test_digest(30, 2)

        def cancel_native_command(records: list[dict]) -> None:
            records[0]["logical"][8] = 1

        def capacity_ownership(records: list[dict]) -> None:
            records[2]["logical"][0] = 1

        for mutator in (
            cancel_ticket,
            cancel_output,
            capacity_pin,
            cancel_native_command,
            capacity_ownership,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_capacity_generation_cursors_and_reasons_are_locked(self) -> None:
        def wrong_cursor(records: list[dict]) -> None:
            records[2]["roots"][0] = _fixture_hash(
                native.CAPACITY_DOMAIN,
                native.EXPECTED_PROFILE_SHA256,
                fixture._u64(native.PRODUCER_ABI),
                fixture._u64(0),
                fixture._u64(0),
                fixture._u64(0),
                fixture._u64(native.ROLE_REQUEST),
                fixture._u64(4),
                fixture._u64(1),
            )

        def wrong_timing_reason(records: list[dict]) -> None:
            records[2]["device"]["reason"] = fixture._test_digest(31, 0)

        def wrong_allocation_reason(records: list[dict]) -> None:
            records[2]["allocation"]["reason"] = fixture._test_digest(
                31,
                1,
            )

        for mutator in (
            wrong_cursor,
            wrong_timing_reason,
            wrong_allocation_reason,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_cancellation_action_commitments_and_evidence_are_locked(
        self,
    ) -> None:
        def wrong_action_evidence(records: list[dict]) -> None:
            records[0]["allocation"]["reason"] = fixture._test_digest(
                32,
                0,
            )

        def wrong_commitment(records: list[dict]) -> None:
            records[1]["device"]["reason"] = fixture._test_digest(32, 1)

        def swap_actual_roots(records: list[dict]) -> None:
            records[0]["roots"][0], records[1]["roots"][0] = (
                records[1]["roots"][0],
                records[0]["roots"][0],
            )

        for mutator in (
            wrong_action_evidence,
            wrong_commitment,
            swap_actual_roots,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_generation_roots_are_unique_and_domains_disjoint(self) -> None:
        for target, source, root_index in (
            (3, 0, 0),
            (3, 0, 2),
            (3, 0, 7),
            (3, 0, 8),
            (50, 24, 1),
            (50, 24, 3),
            (50, 24, 4),
        ):
            def mutate(
                records: list[dict],
                target_index: int = target,
                source_index: int = source,
                index: int = root_index,
            ) -> None:
                records[target_index]["roots"][index] = (
                    records[source_index]["roots"][index]
                )

            with self.subTest(root_index=root_index):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutate)
                )

    def test_controls_require_cpu_oracle_and_supported_observations(
        self,
    ) -> None:
        def incorrect(records: list[dict]) -> None:
            records[24]["correctness"] = 2

        def missing_oracle(records: list[dict]) -> None:
            records[24]["roots"][6] = fixture.ZERO

        def unsupported_timing(records: list[dict]) -> None:
            record = records[24]
            record["device"] = _unsupported_device(
                _scenario(),
                fixture._test_digest(33, 0),
            )

        def zero_allocation(records: list[dict]) -> None:
            records[25]["allocation"]["before"] = 0

        for mutator in (
            incorrect,
            missing_oracle,
            unsupported_timing,
            zero_allocation,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(records_mutator=mutator)
                )

    def test_summary_counts_samples_flow_and_availability_are_locked(
        self,
    ) -> None:
        def admitted(summary: dict) -> None:
            summary["admitted"] += 1

        def cancelled(summary: dict) -> None:
            summary["counts"][native.OUTCOME_CANCELLED] += 1

        def capacity(summary: dict) -> None:
            summary["counts"][native.OUTCOME_CAPACITY_REJECTED] += 1

        def completed(summary: dict) -> None:
            summary["counts"][native.OUTCOME_COMPLETED] += 1

        def admission_samples(summary: dict) -> None:
            summary["distributions"][0][0] += 1

        def end_to_end_samples(summary: dict) -> None:
            summary["distributions"][4][0] += 1

        def high_water(summary: dict) -> None:
            summary["high_water"] = 1

        def flow_balance(summary: dict) -> None:
            summary["flow_max"] += 1
            summary["flow_spread"] += 1

        def correctness(summary: dict) -> None:
            summary["correct"] -= 1

        def allocation_available(summary: dict) -> None:
            summary["allocation_max_available"] = True
            summary["allocation_max"] = 393_216

        def allocation_reason(summary: dict) -> None:
            summary["metrics"][3]["reason"] = fixture._test_digest(
                34,
                0,
            )

        for mutator in (
            admitted,
            cancelled,
            capacity,
            completed,
            admission_samples,
            end_to_end_samples,
            high_water,
            flow_balance,
            correctness,
            allocation_available,
            allocation_reason,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(summary_mutator=mutator)
                )

    def test_closure_counts_and_zero_ownership_are_locked(self) -> None:
        def acquisitions(closure: dict) -> None:
            closure["acquisitions"] -= 1

        def completions(closure: dict) -> None:
            closure["completions"] -= 1

        def live_pin(closure: dict) -> None:
            closure["pin_count"] = 1

        def orphan(closure: dict) -> None:
            closure["zero_orphan"] = False

        for mutator in (
            acquisitions,
            completions,
            live_pin,
            orphan,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _storm_fixture(closure_mutator=mutator)
                )

    def test_corruption_partial_and_extra_output_are_rejected(self) -> None:
        self.assertProfileRejected(self.encoded[:-1])
        self.assertProfileRejected(self.encoded + b"\x00")
        mutated = bytearray(self.encoded)
        mutated[len(mutated) // 2] ^= 1
        self.assertProfileRejected(bytes(mutated))

    def test_runner_uses_fresh_challenge_and_atomic_retention(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = root / "runner.py"
            metallib = root / "shaders.metallib"
            retained = root / "report.gw7b"
            metallib.write_bytes(b"fixture metallib")
            runner.write_text(
                "#!%s\n"
                "import base64, os, sys\n"
                "assert os.environ[%r] == %r\n"
                "sys.stdout.buffer.write(base64.b64decode(%r))\n"
                % (
                    sys.executable,
                    native.CHALLENGE_ENVIRONMENT,
                    TEST_CHALLENGE_SHA256.hex(),
                    base64.b64encode(self.encoded),
                ),
                encoding="ascii",
            )
            os.chmod(runner, 0o700)
            with mock.patch.object(
                native.os,
                "urandom",
                return_value=TEST_CHALLENGE_SHA256,
            ), mock.patch.object(
                native.process_boundary,
                "_runner_file_sha256",
                return_value=TEST_RUNNER_SHA256,
            ), mock.patch.object(
                native.process_boundary,
                "_metallib_file_sha256",
                return_value=TEST_METALLIB_SHA256,
            ):
                result = native.verify_runner(
                    runner,
                    metallib,
                    retained,
                    timeout_seconds=5.0,
                )
            self.assertEqual(result.retained_path, retained)
            self.assertEqual(retained.read_bytes(), self.encoded)

            retained.write_bytes(b"previous")
            with mock.patch.object(
                native.os,
                "urandom",
                return_value=FRESH_CHALLENGE_SHA256,
            ), mock.patch.object(
                native.process_boundary,
                "_runner_file_sha256",
                return_value=TEST_RUNNER_SHA256,
            ), mock.patch.object(
                native.process_boundary,
                "_metallib_file_sha256",
                return_value=TEST_METALLIB_SHA256,
            ), self.assertRaises(
                native.NativeMetalCancellationStormReportError
            ):
                native.verify_runner(
                    runner,
                    metallib,
                    retained,
                    timeout_seconds=5.0,
                )
            self.assertEqual(retained.read_bytes(), b"previous")

    def test_runner_rejects_stderr_and_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metallib = root / "shaders.metallib"
            metallib.write_bytes(b"fixture metallib")
            for name, body in (
                (
                    "stderr.py",
                    (
                        "sys.stderr.write('noise')\n"
                        "sys.stdout.buffer.write(base64.b64decode(%r))\n"
                        % base64.b64encode(self.encoded)
                    ),
                ),
                (
                    "partial.py",
                    "sys.stdout.buffer.write(b'x' * %d)\n"
                    % (native.EXPECTED_WIRE_BYTES - 1),
                ),
            ):
                runner = root / name
                runner.write_text(
                    "#!%s\nimport base64, sys\n%s"
                    % (sys.executable, body),
                    encoding="ascii",
                )
                os.chmod(runner, 0o700)
                with self.subTest(name=name), mock.patch.object(
                    native.os,
                    "urandom",
                    return_value=TEST_CHALLENGE_SHA256,
                ), mock.patch.object(
                    native.process_boundary,
                    "_runner_file_sha256",
                    return_value=TEST_RUNNER_SHA256,
                ), mock.patch.object(
                    native.process_boundary,
                    "_metallib_file_sha256",
                    return_value=TEST_METALLIB_SHA256,
                ), self.assertRaises(
                    native.NativeMetalCancellationStormReportError
                ):
                    native.verify_runner(
                        runner,
                        metallib,
                        timeout_seconds=5.0,
                    )

    def test_component_change_after_runner_is_rejected(self) -> None:
        with mock.patch.object(
            native.process_boundary,
            "_runner_file_sha256",
            return_value=TEST_RUNNER_SHA256,
        ), mock.patch.object(
            native.process_boundary,
            "_metallib_file_sha256",
            return_value=TEST_METALLIB_SHA256,
        ), mock.patch.object(
            native.process_boundary,
            "_bounded_runner_output",
            return_value=(0, self.encoded, b""),
        ), mock.patch.object(
            native.process_boundary,
            "_verify_components_unchanged",
            side_effect=native.process_boundary.NativeMetalReportError(
                "component changed"
            ),
        ), mock.patch.object(
            native.os,
            "urandom",
            return_value=TEST_CHALLENGE_SHA256,
        ), self.assertRaises(
            native.NativeMetalCancellationStormReportError
        ):
            native.verify_runner("runner", "shader")

    def test_cli_contract(self) -> None:
        verification = native.NativeCancellationStormVerificationResult(
            208,
            26,
            182,
            128,
            16,
            bytes(range(32)),
            bytes(reversed(range(32))),
            TEST_RUNNER_SHA256,
            TEST_METALLIB_SHA256,
            Path("report.gw7b"),
        )
        output = io.StringIO()
        with mock.patch.object(
            native,
            "verify_runner",
            return_value=verification,
        ) as verify_runner, redirect_stdout(output):
            self.assertEqual(
                native._main(
                    [
                        "--runner",
                        "fixture-runner",
                        "--metallib",
                        "fixture-metallib",
                        "--output",
                        "report.gw7b",
                    ]
                ),
                0,
            )
        verify_runner.assert_called_once_with(
            "fixture-runner",
            "fixture-metallib",
            "report.gw7b",
        )
        line = output.getvalue().strip()
        self.assertTrue(
            line.startswith(
                "ok native-metal-cancellation-storm-report-v1 "
            )
        )
        self.assertIn("records=208", line)
        self.assertIn("cancelled=128", line)
        self.assertIn("completed=16", line)


if __name__ == "__main__":
    unittest.main()
