from __future__ import annotations

import copy
import unittest

from bench import workload_pressure as pressure


SCENARIO_ROOT = "e6fc0e1b3d676c5ea89a2e54434bef0ac51e30f8b1ab85944bfc43e0cd34407b"
OUTCOME_ROOT = "9eb52f76c2c68098d59f13bc6d5b456b2efd7297b936731543c33a2d9934596f"
TRACE_ROOT = "0868ce16006aa777bbc13d2454935607f375f5446e4c18cf78a958c2bee92169"
SUMMARY_ROOT = "1c7d104f1d12627503c6d472f01bb0b07f41f200a8d1ecad23738d06dff80b0d"
RESULT_ROOT = "1f5509316a967fe410b90ac0970af3ce77e0d63c1e1ab4f81012a23accea5fb0"


class WorkloadPressureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scenario = pressure.reference_scenario()
        self.result = pressure.replay_scenario(self.scenario)

    def test_reference_scenario_wire_and_profiles_are_canonical(self) -> None:
        encoded = pressure.encode_scenario(self.scenario)
        self.assertEqual(
            len(encoded),
            pressure.required_scenario_bytes(7),
        )
        self.assertEqual(pressure.scenario_sha256(self.scenario).hex(), SCENARIO_ROOT)
        self.assertEqual(pressure.decode_scenario(encoded), self.scenario)

        expected_host = {
            pressure.MEDIA_IMAGE: 1464,
            pressure.MEDIA_AUDIO: 1220,
            pressure.MEDIA_VIDEO: 1068,
        }
        for item in self.scenario["items"]:
            with self.subTest(ordinal=item["ordinal"]):
                self.assertEqual(
                    sum(item["claim"][name] for name in pressure.HOST_CLAIM_FIELDS),
                    expected_host[item["media_kind"]],
                )
                self.assertEqual(item["claim"]["queue_slots"], 1)

    def test_independent_replay_covers_all_terminal_paths(self) -> None:
        summary = self.result["summary"]
        self.assertEqual(
            {
                "admitted": summary["admitted"],
                "rejected": summary["rejected"],
                "completed": summary["completed"],
                "cancelled": summary["cancelled"],
                "timed_out": summary["timed_out"],
            },
            {
                "admitted": 5,
                "rejected": 2,
                "completed": 3,
                "cancelled": 1,
                "timed_out": 1,
            },
        )
        self.assertEqual(summary["service_quanta"], 21)
        self.assertEqual(summary["driver_steps"], 21)
        self.assertEqual(summary["final_logical_tick"], 21)
        self.assertEqual(summary["maximum_live_receipts"], 4)
        self.assertEqual(summary["peak_host_bytes"], 4972)
        self.assertEqual(summary["successful_commits"], 5)
        self.assertEqual(summary["releases"], 5)
        self.assertEqual(summary["bank_cancellations"], 0)
        self.assertEqual(summary["bank_rejected_capacity"], 0)
        self.assertEqual(summary["bank_rejected_slots"], 0)
        self.assertTrue(summary["zero_orphan_ownership"])
        self.assertEqual(len(self.result["trace"]), 34)

        outcomes = self.result["outcomes"]
        self.assertEqual(
            outcomes[4]["rejection_reason"],
            pressure.REJECTION_NO_SLOT,
        )
        self.assertEqual(
            outcomes[5]["rejection_reason"],
            pressure.REJECTION_RESOURCE_LIMIT,
        )
        self.assertEqual(outcomes[0]["kind"], pressure.OUTCOME_CANCELLED)
        self.assertEqual(outcomes[3]["kind"], pressure.OUTCOME_TIMED_OUT)
        self.assertEqual(outcomes[3]["served_quanta"], 0)
        for index in (1, 2, 6):
            self.assertEqual(outcomes[index]["kind"], pressure.OUTCOME_COMPLETED)

    def test_weighted_fairness_delays_and_deadlines_are_exact(self) -> None:
        service_order = [
            record["item_ordinal"]
            for record in self.result["trace"]
            if record["event_kind"] == pressure.EVENT_SERVICE
        ]
        self.assertEqual(service_order[:7], [0, 1, 2, 1, 2, 2, 2])
        self.assertEqual(
            self.result["summary"]["fairness_cross_product_error"],
            0,
        )
        self.assertLessEqual(
            self.result["summary"]["maximum_wait_quanta"],
            self.result["summary"]["maximum_service_gap"],
        )
        self.assertEqual(
            (
                self.result["summary"]["queue_delay_p50_steps"],
                self.result["summary"]["queue_delay_p95_steps"],
                self.result["summary"]["queue_delay_p99_steps"],
                self.result["summary"]["queue_delay_max_steps"],
            ),
            (1, 5, 5, 5),
        )
        self.assertEqual(
            (
                self.result["summary"]["completion_delay_p50_steps"],
                self.result["summary"]["completion_delay_p95_steps"],
                self.result["summary"]["completion_delay_p99_steps"],
                self.result["summary"]["completion_delay_max_steps"],
            ),
            (16, 19, 19, 19),
        )
        for item, outcome in zip(
            self.scenario["items"],
            self.result["outcomes"],
        ):
            if item["deadline_tick"] and outcome["kind"] == pressure.OUTCOME_COMPLETED:
                terminal_services = [
                    record["logical_tick_after"]
                    for record in self.result["trace"]
                    if record["item_ordinal"] == item["ordinal"]
                    and record["event_kind"] == pressure.EVENT_SERVICE
                    and record["remaining_after"] == 0
                ]
                self.assertEqual(len(terminal_services), 1)
                self.assertLessEqual(terminal_services[0], item["deadline_tick"])

    def test_projection_operation_exhaustion_has_exact_reason(self) -> None:
        scenario = pressure.reference_scenario()
        scenario["items"] = scenario["items"][:2]
        scenario["capacity"] = 2
        scenario["max_projection_operations"] = 1
        scenario["items"][0]["terminal_action"] = pressure.ACTION_NONE
        scenario["items"][0]["terminal_action_step"] = pressure.ABSENT_STEP
        result = pressure.replay_scenario(scenario)
        self.assertEqual(result["summary"]["admitted"], 0)
        self.assertEqual(result["summary"]["rejected"], 2)
        self.assertEqual(
            [outcome["rejection_reason"] for outcome in result["outcomes"]],
            [pressure.REJECTION_PROJECTION_LIMIT] * 2,
        )

    def test_same_step_cancel_and_retire_keep_true_high_water(self) -> None:
        scenario = pressure.reference_scenario()
        scenario["items"] = scenario["items"][:2]
        scenario["capacity"] = 1
        scenario["items"][0]["terminal_action_step"] = 0
        scenario["items"][1]["arrival_step"] = 1
        scenario["items"][1]["work_quanta"] = 1
        scenario["limits"]["host_bytes"] = 1464
        scenario["limits"]["queue_slots"] = 1
        result = pressure.replay_scenario(scenario)
        self.assertEqual(result["summary"]["admitted"], 2)
        self.assertEqual(result["summary"]["completed"], 1)
        self.assertEqual(result["summary"]["cancelled"], 1)
        self.assertEqual(result["summary"]["maximum_live_receipts"], 1)
        self.assertEqual(result["summary"]["final_active"], 0)
        self.assertTrue(result["summary"]["zero_orphan_ownership"])

    def test_result_wire_round_trip_is_independently_replayed(self) -> None:
        encoded = pressure.encode_result(self.result)
        self.assertEqual(
            len(encoded),
            pressure.required_result_bytes(7, 34),
        )
        self.assertEqual(self.result["outcome_sha256"].hex(), OUTCOME_ROOT)
        self.assertEqual(self.result["trace_sha256"].hex(), TRACE_ROOT)
        self.assertEqual(self.result["summary_sha256"].hex(), SUMMARY_ROOT)
        self.assertEqual(encoded[-pressure.RESULT_FOOTER_BYTES :].hex(), RESULT_ROOT)
        decoded = pressure.decode_result(encoded)
        self.assertEqual(decoded, self.result)
        self.assertEqual(
            pressure.validate_result(self.scenario, decoded),
            decoded,
        )

    def test_every_scenario_and_result_byte_mutation_rejects(self) -> None:
        scenario_wire = pressure.encode_scenario(self.scenario)
        for index in range(len(scenario_wire)):
            with self.subTest(wire="scenario", index=index):
                mutated = bytearray(scenario_wire)
                mutated[index] ^= 1
                with self.assertRaises(pressure.WorkloadPressureError):
                    pressure.decode_scenario(bytes(mutated))

        result_wire = pressure.encode_result(self.result)
        for index in range(len(result_wire)):
            with self.subTest(wire="result", index=index):
                mutated = bytearray(result_wire)
                mutated[index] ^= 1
                with self.assertRaises(pressure.WorkloadPressureError):
                    pressure.decode_result(bytes(mutated))

    def test_truncation_substitution_and_rehashed_contradictions_reject(self) -> None:
        scenario_wire = pressure.encode_scenario(self.scenario)
        result_wire = pressure.encode_result(self.result)
        for truncated in (
            scenario_wire[:-1],
            scenario_wire[: pressure.SCENARIO_HEADER_BYTES],
        ):
            with self.assertRaises(pressure.WorkloadPressureError):
                pressure.decode_scenario(truncated)
        for truncated in (
            result_wire[:-1],
            result_wire[: pressure.RESULT_HEADER_BYTES],
        ):
            with self.assertRaises(pressure.WorkloadPressureError):
                pressure.decode_result(truncated)

        foreign = pressure.reference_scenario()
        foreign["seed"] += 1
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_result(foreign, self.result)

        contradictory = copy.deepcopy(self.result)
        contradictory["summary"]["completed"] += 1
        contradictory["summary_sha256"] = pressure.summary_sha256(
            contradictory["summary"]
        )
        decoded_contradiction = pressure.decode_result(
            pressure.encode_result(contradictory)
        )
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_result(self.scenario, decoded_contradiction)

        for summary_field in (
            "fairness_cross_product_error",
            "peak_host_bytes",
            "maximum_live_receipts",
        ):
            with self.subTest(rehashed_summary=summary_field):
                forged_summary = copy.deepcopy(self.result)
                forged_summary["summary"][summary_field] += 1
                forged_summary["summary_sha256"] = pressure.summary_sha256(
                    forged_summary["summary"]
                )
                decoded_summary = pressure.decode_result(
                    pressure.encode_result(forged_summary)
                )
                with self.assertRaises(pressure.WorkloadPressureError):
                    pressure.validate_result(self.scenario, decoded_summary)

        forged_peak = copy.deepcopy(self.result)
        forged_peak["summary"]["peak"]["capsule_bytes"] += 1
        forged_peak["summary_sha256"] = pressure.summary_sha256(forged_peak["summary"])
        decoded_peak = pressure.decode_result(pressure.encode_result(forged_peak))
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_result(self.scenario, decoded_peak)

        forged_final = copy.deepcopy(self.result)
        forged_final["summary"]["final_active"] = 1
        forged_final["summary_sha256"] = pressure.summary_sha256(
            forged_final["summary"]
        )
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.encode_result(forged_final)

        substituted_trace = copy.deepcopy(self.result)
        service_index = next(
            index
            for index, record in enumerate(substituted_trace["trace"])
            if record["event_kind"] == pressure.EVENT_SERVICE
        )
        substituted_trace["trace"][service_index]["item_ordinal"] = 2
        substituted_trace["trace"][service_index]["record_sha256"] = (
            pressure.trace_record_sha256(substituted_trace["trace"][service_index])
        )
        substituted_trace["trace_sha256"] = pressure.trace_sha256(
            substituted_trace["trace"]
        )
        decoded_substitution = pressure.decode_result(
            pressure.encode_result(substituted_trace)
        )
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_result(self.scenario, decoded_substitution)

        substituted_outcome = copy.deepcopy(self.result)
        substituted_outcome["outcomes"][0]["admission_trace_sha256"] = (
            substituted_outcome["outcomes"][1]["admission_trace_sha256"]
        )
        substituted_outcome["outcome_sha256"] = pressure.outcome_sha256(
            substituted_outcome["outcomes"]
        )
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.encode_result(substituted_outcome)

    def test_foreign_profile_and_unbounded_inputs_fail_before_replay(self) -> None:
        foreign_profile = pressure.reference_scenario()
        foreign_profile["items"][0]["profile_sha256"] = foreign_profile["items"][1][
            "profile_sha256"
        ]
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_scenario(foreign_profile)

        excessive = pressure.reference_scenario()
        excessive["max_driver_steps"] = 513
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_scenario(excessive)

        trace_excessive = pressure.reference_scenario()
        trace_excessive["items"][0]["work_quanta"] = 20
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_scenario(trace_excessive)

        late_action = pressure.reference_scenario()
        late_action["items"][0]["terminal_action_step"] = late_action[
            "max_driver_steps"
        ]
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_scenario(late_action)

        invalid_action = pressure.reference_scenario()
        invalid_action["items"][0]["terminal_action"] = 3
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_scenario(invalid_action)

        reordered = pressure.reference_scenario()
        reordered["items"][0], reordered["items"][1] = (
            reordered["items"][1],
            reordered["items"][0],
        )
        with self.assertRaises(pressure.WorkloadPressureError):
            pressure.validate_scenario(reordered)


if __name__ == "__main__":
    unittest.main()
