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

from bench import native_metal_disruption_report as native
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


def _synthetic_root(epoch: int, action: int, role: int) -> bytes:
    return _fixture_hash(
        b"glacier-w7-metal-controlled-disruption-record-v1\x00",
        native.EXPECTED_PROFILE_SHA256,
        fixture._u64(native.PRODUCER_ABI),
        fixture._u64(epoch),
        fixture._u64(action),
        fixture._u64(role),
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


def _unsupported_device(
    scenario: dict,
    epoch: int,
    action: int,
    reason: bytes | None = None,
) -> dict:
    return {
        "availability": native.AVAILABILITY_UNSUPPORTED,
        "start": 0,
        "end": 0,
        "duration": 0,
        "source": scenario["identities"][10],
        "clock": scenario["identities"][11],
        "reason": reason
        if reason is not None
        else _synthetic_root(
            epoch,
            action,
            native.ROLE_TIMING_UNSUPPORTED,
        ),
    }


def _unsupported_allocation(
    scenario: dict,
    epoch: int,
    action: int,
    reason: bytes | None = None,
) -> dict:
    return {
        "availability": native.AVAILABILITY_UNSUPPORTED,
        "before": 0,
        "after": 0,
        "source": scenario["identities"][10],
        "reason": reason
        if reason is not None
        else _synthetic_root(
            epoch,
            action,
            native.ROLE_ALLOCATION_UNSUPPORTED,
        ),
    }

def _admitted_commitment(
    record: dict,
    epoch: int,
    action: int,
    detail: int,
    action_evidence: bytes,
) -> bytes:
    return _fixture_hash(
        native.ADMITTED_COMMITMENT_DOMAIN,
        native.EXPECTED_PROFILE_SHA256,
        fixture._u64(native.PRODUCER_ABI),
        fixture._u64(epoch),
        fixture._u64(action),
        fixture._u64(detail),
        fixture._u64(record["outcome"]),
        fixture._u64(record["flow_id"]),
        record["roots"][0],
        record["roots"][2],
        record["roots"][7],
        record["roots"][8],
        action_evidence,
    )


def _admitted_non_submit(
    scenario: dict,
    ordinal: int,
    cohort: int,
    epoch: int,
    action: int,
    outcome: int,
    flow_id: int,
    sequences: tuple[int, int, int, int],
) -> dict:
    roots = [fixture.ZERO] * 9
    roots[0] = fixture._test_digest(20, ordinal)
    roots[2] = fixture._test_digest(22, ordinal)
    roots[7] = fixture._test_digest(27, ordinal)
    roots[8] = fixture._test_digest(28, ordinal)
    detail = (
        native.DETAIL_CANCELLED_BEFORE_SUBMIT
        if action == native.ACTION_CANCEL
        else native.DETAIL_INVALID_HOST_LENGTHS
    )
    action_evidence = (
        _synthetic_root(
            epoch,
            action,
            native.ROLE_ACTION_EVIDENCE,
        )
        if action == native.ACTION_CANCEL
        else fixture._test_digest(29, ordinal)
    )
    record = {
        "abi": fixture.RECORD_ABI,
        "ordinal": ordinal,
        "cohort": cohort,
        "outcome": outcome,
        "correctness": native.CORRECTNESS_NOT_APPLICABLE,
        "fallback": False,
        "flow_id": flow_id,
        "work_units": native.EXPECTED_WORK_UNITS,
        "queue": 0,
        "mask": native.EVENT_ADMITTED_NO_SUBMIT,
        "points": _points(
            native.EVENT_ADMITTED_NO_SUBMIT,
            sequences,
        ),
        "roots": roots,
        "maximum_error": 0,
        "device": {},
        "allocation": _unsupported_allocation(
            scenario,
            epoch,
            action,
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
        epoch,
        action,
        _admitted_commitment(
            record,
            epoch,
            action,
            detail,
            action_evidence,
        ),
    )
    return record


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


def _capacity_rejected(
    scenario: dict,
    ordinal: int,
    cohort: int,
    epoch: int,
    sequences: tuple[int, int, int],
) -> dict:
    roots = [fixture.ZERO] * 9
    roots[0] = native._capacity_root(
        epoch,
        native.ROLE_REQUEST,
    )
    roots[7] = native._capacity_root(
        epoch,
        native.ROLE_TERMINAL,
    )
    roots[8] = native._capacity_root(
        epoch,
        native.ROLE_COMPLETION,
    )
    return {
        "abi": fixture.RECORD_ABI,
        "ordinal": ordinal,
        "cohort": cohort,
        "outcome": native.OUTCOME_CAPACITY_REJECTED,
        "correctness": native.CORRECTNESS_NOT_APPLICABLE,
        "fallback": False,
        "flow_id": 0,
        "work_units": native.EXPECTED_WORK_UNITS,
        "queue": native.NO_QUEUE_SLOT,
        "mask": native.EVENT_CAPACITY_REJECTED,
        "points": _points(native.EVENT_CAPACITY_REJECTED, sequences),
        "roots": roots,
        "maximum_error": 0,
        "device": _unsupported_device(
            scenario,
            epoch,
            native.ACTION_CAPACITY_REJECTED,
        ),
        "allocation": _unsupported_allocation(
            scenario,
            epoch,
            native.ACTION_CAPACITY_REJECTED,
        ),
        "logical": [0] * 10,
        "previous": fixture.ZERO,
        "sha": fixture.ZERO,
    }


def _records(scenario: dict) -> list[dict]:
    records: list[dict] = []
    for epoch in range(native.EPOCH_COUNT):
        cohort = (
            native.COHORT_WARMUP
            if epoch < native.WARMUP_EPOCH_COUNT
            else native.COHORT_MEASURED
        )
        base = epoch * 25 + 1
        ordinal = epoch * native.RECORDS_PER_EPOCH
        records.extend(
            (
                _admitted_non_submit(
                    scenario,
                    ordinal,
                    cohort,
                    epoch,
                    native.ACTION_CANCEL,
                    native.OUTCOME_CANCELLED,
                    0,
                    (base + 0, base + 1, base + 2, base + 3),
                ),
                _admitted_non_submit(
                    scenario,
                    ordinal + 1,
                    cohort,
                    epoch,
                    native.ACTION_MALFORMED_PRE_SUBMIT,
                    native.OUTCOME_FAILED,
                    1,
                    (base + 4, base + 5, base + 6, base + 7),
                ),
                _completed(
                    scenario,
                    ordinal + 2,
                    cohort,
                    0,
                    (
                        base + 8,
                        base + 10,
                        base + 12,
                        base + 14,
                        base + 19,
                        base + 21,
                        base + 24,
                    ),
                ),
                _completed(
                    scenario,
                    ordinal + 3,
                    cohort,
                    1,
                    (
                        base + 9,
                        base + 11,
                        base + 13,
                        base + 15,
                        base + 20,
                        base + 22,
                        base + 23,
                    ),
                ),
                _capacity_rejected(
                    scenario,
                    ordinal + 4,
                    cohort,
                    epoch,
                    (base + 16, base + 17, base + 18),
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
    length = (
        fixture.HEADER_BYTES + len(body) + fixture.WIRE_DIGEST_BYTES
    )
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


def _disruption_fixture(
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


class NativeMetalDisruptionReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.encoded = _disruption_fixture()

    def assertProfileRejected(self, encoded: bytes) -> None:
        with self.assertRaises(
            native.NativeMetalDisruptionReportError
        ):
            native.verify_native_wire(
                encoded,
                TEST_RUNNER_SHA256,
                TEST_METALLIB_SHA256,
                TEST_CHALLENGE_SHA256,
            )

    def test_exact_w7_profile_verifies(self) -> None:
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
        self.assertEqual(result.record_count, 250)
        self.assertEqual(result.warmup_count, 10)
        self.assertEqual(result.measured_count, 240)
        self.assertEqual(result.completed_count, 100)
        self.assertEqual(
            result.wire_sha256,
            hashlib.sha256(self.encoded).digest(),
        )

    def test_identity_formulas_are_independently_locked(self) -> None:
        schedule_tuple = (
            native.PRODUCER_ABI,
            2,
            48,
            5,
            2,
            2,
            5_544,
            1,
            2,
            3,
            4,
            5,
        )
        schedule = _fixture_hash(
            b"glacier-w7-metal-controlled-disruption-schedule-v1\x00",
            *(fixture._u64(value) for value in schedule_tuple),
        )
        self.assertEqual(schedule, native.EXPECTED_SCHEDULE_SHA256)
        self.assertEqual(
            native.EXPECTED_PROFILE_SHA256,
            _fixture_hash(
                b"glacier-w7-metal-controlled-disruption-profile-v1\x00",
                schedule,
                *(fixture._u64(value) for value in schedule_tuple),
            ),
        )
        self.assertEqual(
            TEST_BUILD_SHA256,
            _fixture_hash(
                b"glacier-w7-metal-native-build-v1\x00",
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
                    _disruption_fixture(scenario_mutator=mutate)
                )

    def test_dynamic_identities_cannot_be_zero_or_alias(self) -> None:
        def zero_machine(scenario: dict) -> None:
            scenario["identities"][4] = fixture.ZERO

        def alias_device(scenario: dict) -> None:
            scenario["identities"][7] = scenario["identities"][6]

        for mutator in (zero_machine, alias_device):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(scenario_mutator=mutator)
                )

    def test_each_outcome_position_is_enforced(self) -> None:
        replacements = (
            native.OUTCOME_FAILED,
            native.OUTCOME_CANCELLED,
            native.OUTCOME_FAILED,
            native.OUTCOME_CANCELLED,
            native.OUTCOME_FAILED,
        )
        for position, replacement in enumerate(replacements):
            def mutate(
                records: list[dict],
                index: int = position,
                outcome: int = replacement,
            ) -> None:
                records[index]["outcome"] = outcome

            with self.subTest(position=position):
                self.assertProfileRejected(
                    _disruption_fixture(records_mutator=mutate)
                )

    def test_epoch_schedule_boundaries_are_enforced(self) -> None:
        def cancel_not_settled_before_gpu(records: list[dict]) -> None:
            left = records[1]["points"][6]
            right = records[2]["points"][0]
            records[1]["points"][6] = right
            records[2]["points"][0] = left

        def capacity_before_second_submit(records: list[dict]) -> None:
            submit = records[3]["points"][3]
            arrival = records[4]["points"][0]
            records[3]["points"][3] = arrival
            records[4]["points"][0] = submit

        def wrong_reverse_settlement(records: list[dict]) -> None:
            left = records[2]["points"][6]
            right = records[3]["points"][6]
            records[2]["points"][6] = right
            records[3]["points"][6] = left

        def early_next_epoch(records: list[dict]) -> None:
            left = records[2]["points"][6]
            right = records[5]["points"][0]
            records[2]["points"][6] = right
            records[5]["points"][0] = left

        for mutator in (
            cancel_not_settled_before_gpu,
            capacity_before_second_submit,
            wrong_reverse_settlement,
            early_next_epoch,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(records_mutator=mutator)
                )

    def test_record_masks_flows_lease_and_observations_are_enforced(
        self,
    ) -> None:
        def cancel_mask(records: list[dict]) -> None:
            records[0]["mask"] |= native.EVENT_FIRST_SERVICE
            records[0]["points"][2] = (25, 25)

        def reject_flow(records: list[dict]) -> None:
            records[1]["flow_id"] = 0

        def completed_lane(records: list[dict]) -> None:
            records[3]["flow_id"] = 0
            records[3]["queue"] = 0

        def capacity_queue(records: list[dict]) -> None:
            records[4]["queue"] = 0

        def lease_bytes(records: list[dict]) -> None:
            records[2]["logical"][2] += 1
            records[2]["logical"][3] += 1

        def fallback(records: list[dict]) -> None:
            records[2]["fallback"] = True

        def device_unavailable(records: list[dict]) -> None:
            record = records[2]
            record["device"] = _unsupported_device(
                _scenario(),
                0,
                native.ACTION_COMPLETED_LANE0,
            )

        def allocation_zero(records: list[dict]) -> None:
            records[2]["allocation"]["before"] = 0

        def incorrect(records: list[dict]) -> None:
            records[2]["correctness"] = 2

        for mutator in (
            cancel_mask,
            reject_flow,
            completed_lane,
            capacity_queue,
            lease_bytes,
            fallback,
            device_unavailable,
            allocation_zero,
            incorrect,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(records_mutator=mutator)
                )

    def test_synthetic_capacity_roots_and_unavailable_reasons_are_locked(
        self,
    ) -> None:
        def capacity_root(records: list[dict]) -> None:
            records[4]["roots"][0] = fixture._test_digest(93, 0)

        def timing_reason(records: list[dict]) -> None:
            records[0]["device"]["reason"] = fixture._test_digest(
                93,
                1,
            )

        def allocation_reason(records: list[dict]) -> None:
            records[1]["allocation"]["reason"] = fixture._test_digest(
                93,
                2,
            )

        for mutator in (
            capacity_root,
            timing_reason,
            allocation_reason,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(records_mutator=mutator)
                )

    def test_admitted_roots_are_bound_to_their_declared_action(
        self,
    ) -> None:
        def swap_cancel_and_rejection_roots(
            records: list[dict],
        ) -> None:
            for root_index in (0, 2, 7, 8):
                records[0]["roots"][root_index], records[1]["roots"][
                    root_index
                ] = (
                    records[1]["roots"][root_index],
                    records[0]["roots"][root_index],
                )

        def substitute_synthetic_capacity_roots(
            records: list[dict],
        ) -> None:
            records[0]["roots"][0] = native._capacity_root(
                0,
                native.ROLE_REQUEST,
            )
            records[0]["roots"][2] = _synthetic_root(
                0,
                native.ACTION_CAPACITY_REJECTED,
                native.ROLE_ACTION_EVIDENCE,
            )
            records[0]["roots"][7] = native._capacity_root(
                0,
                native.ROLE_TERMINAL,
            )
            records[0]["roots"][8] = native._capacity_root(
                0,
                native.ROLE_COMPLETION,
            )

        def substitute_rejection_receipt(
            records: list[dict],
        ) -> None:
            records[1]["allocation"]["reason"] = (
                fixture._test_digest(95, 1)
            )

        def cross_epoch_capacity_alias_with_new_commitment(
            records: list[dict],
        ) -> None:
            record = records[0]
            record["roots"][0] = native._capacity_root(
                1,
                native.ROLE_TERMINAL,
            )
            action_evidence = record["allocation"]["reason"]
            record["device"]["reason"] = _admitted_commitment(
                record,
                0,
                native.ACTION_CANCEL,
                native.DETAIL_CANCELLED_BEFORE_SUBMIT,
                action_evidence,
            )

        for mutator in (
            swap_cancel_and_rejection_roots,
            substitute_synthetic_capacity_roots,
            substitute_rejection_receipt,
            cross_epoch_capacity_alias_with_new_commitment,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(records_mutator=mutator)
                )

    def test_capacity_roots_bind_exact_generation_cursors(self) -> None:
        def wrong_request_cursor(records: list[dict]) -> None:
            records[4]["roots"][0] = _fixture_hash(
                native.CAPACITY_ROOT_DOMAIN,
                native.EXPECTED_PROFILE_SHA256,
                fixture._u64(native.PRODUCER_ABI),
                fixture._u64(0),
                fixture._u64(native.ACTION_CAPACITY_REJECTED),
                fixture._u64(native.ROLE_REQUEST),
                fixture._u64(6),
                fixture._u64(3),
            )

        self.assertProfileRejected(
            _disruption_fixture(
                records_mutator=wrong_request_cursor,
            )
        )

    def test_generation_roots_are_unique(self) -> None:
        for target, source, root_index in (
            (5, 0, 0),
            (5, 0, 7),
            (5, 0, 8),
            (5, 0, 2),
            (7, 2, 1),
            (7, 2, 3),
            (7, 2, 4),
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
                    _disruption_fixture(records_mutator=mutate)
                )

    def test_summary_counts_samples_and_availability_are_enforced(
        self,
    ) -> None:
        def admitted(summary: dict) -> None:
            summary["admitted"] += 1

        def completed(summary: dict) -> None:
            summary["counts"][0] += 1

        def capacity(summary: dict) -> None:
            summary["counts"][1] += 1

        def failed(summary: dict) -> None:
            summary["counts"][2] += 1

        def cancelled(summary: dict) -> None:
            summary["counts"][3] += 1

        def attempted_work(summary: dict) -> None:
            summary["attempted_work"] += 1

        def completed_work(summary: dict) -> None:
            summary["completed_work"] += 1

        def admission_samples(summary: dict) -> None:
            summary["distributions"][0][0] += 1

        def queue_samples(summary: dict) -> None:
            summary["distributions"][1][0] += 1

        def output_samples(summary: dict) -> None:
            summary["distributions"][2][0] += 1

        def service_samples(summary: dict) -> None:
            summary["distributions"][3][0] += 1

        def end_to_end_samples(summary: dict) -> None:
            summary["distributions"][4][0] += 1

        def device_samples(summary: dict) -> None:
            summary["distributions"][5][0] += 1

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
                94,
                0,
            )

        for mutator in (
            admitted,
            completed,
            capacity,
            failed,
            cancelled,
            attempted_work,
            completed_work,
            admission_samples,
            queue_samples,
            output_samples,
            service_samples,
            end_to_end_samples,
            device_samples,
            high_water,
            flow_balance,
            correctness,
            allocation_available,
            allocation_reason,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(summary_mutator=mutator)
                )

    def test_closure_counts_and_zero_orphan_are_enforced(self) -> None:
        def acquisitions(closure: dict) -> None:
            closure["acquisitions"] -= 1

        def completions(closure: dict) -> None:
            closure["completions"] -= 1

        def live_command(closure: dict) -> None:
            closure["command_count"] = 1

        def orphan(closure: dict) -> None:
            closure["zero_orphan"] = False

        for mutator in (
            acquisitions,
            completions,
            live_command,
            orphan,
        ):
            with self.subTest(mutator=mutator.__name__):
                self.assertProfileRejected(
                    _disruption_fixture(closure_mutator=mutator)
                )

    def test_generic_wire_rejection_precedes_profile_acceptance(self) -> None:
        self.assertProfileRejected(self.encoded[:-1])
        self.assertProfileRejected(self.encoded + b"\x00")
        mutated = bytearray(self.encoded)
        mutated[len(mutated) // 2] ^= 1
        self.assertProfileRejected(bytes(mutated))

    def test_runner_uses_fresh_w7_challenge_and_atomic_retention(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = root / "runner.py"
            metallib = root / "shaders.metallib"
            retained = root / "report.gw7"
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
                native.NativeMetalDisruptionReportError
            ):
                native.verify_runner(
                    runner,
                    metallib,
                    retained,
                    timeout_seconds=5.0,
                )
            self.assertEqual(retained.read_bytes(), b"previous")

    def test_runner_stdout_bound_is_w7_wire_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = root / "runner.py"
            metallib = root / "shaders.metallib"
            metallib.write_bytes(b"fixture metallib")
            runner.write_text(
                "#!%s\n"
                "import sys\n"
                "sys.stdout.buffer.write(b'x' * %d)\n"
                % (sys.executable, native.EXPECTED_WIRE_BYTES + 1),
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
            ), self.assertRaises(
                native.NativeMetalDisruptionReportError
            ):
                native.verify_runner(
                    runner,
                    metallib,
                    timeout_seconds=5.0,
                )

    def test_cli_contract(self) -> None:
        verification = native.NativeDisruptionVerificationResult(
            250,
            10,
            240,
            100,
            bytes(range(32)),
            bytes(reversed(range(32))),
            TEST_RUNNER_SHA256,
            TEST_METALLIB_SHA256,
            Path("report.gw7"),
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
                        "report.gw7",
                    ]
                ),
                0,
            )
        verify_runner.assert_called_once_with(
            "fixture-runner",
            "fixture-metallib",
            "report.gw7",
        )
        line = output.getvalue().strip()
        self.assertTrue(
            line.startswith("ok native-metal-disruption-report-v1 ")
        )
        self.assertIn("records=250", line)
        self.assertIn("completed=100", line)


if __name__ == "__main__":
    unittest.main()
