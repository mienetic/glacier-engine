from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path

from bench import scheduled_media_pressure as scheduled
from bench import workload_closed_loop as closed
from bench import workload_pressure as workload
from bench import workload_scenario_corpus as corpus


class WorkloadClosedLoopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = closed.reference_plan()
        cls.result = closed.replay_plan(cls.plan)

    @staticmethod
    def _reseal_result(result: dict[str, object]) -> None:
        result["outcome_sha256"] = closed.outcomes_sha256(
            result["outcomes"]  # type: ignore[arg-type]
        )
        result["trace_sha256"] = closed.trace_sha256(
            result["trace"]  # type: ignore[arg-type]
        )
        result["summary_sha256"] = closed.summary_sha256(
            result["summary"]  # type: ignore[arg-type]
        )
        result["result_sha256"] = closed._sha(
            closed.RESULT_DOMAIN,
            closed._u64(closed.RESULT_ABI),
            result["plan_sha256"],  # type: ignore[arg-type]
            result["outcome_sha256"],  # type: ignore[arg-type]
            result["trace_sha256"],  # type: ignore[arg-type]
            result["summary_sha256"],  # type: ignore[arg-type]
        )

    @staticmethod
    def _reseal_plan_wire(encoded: bytearray) -> bytes:
        encoded[-closed.PLAN_FOOTER_BYTES :] = closed._sha(
            closed.PLAN_WIRE_DOMAIN,
            bytes(encoded[: -closed.PLAN_FOOTER_BYTES]),
        )
        return bytes(encoded)

    @staticmethod
    def _reseal_result_wire(encoded: bytearray) -> bytes:
        encoded[-closed.RESULT_FOOTER_BYTES :] = closed._sha(
            closed.RESULT_WIRE_DOMAIN,
            bytes(encoded[: -closed.RESULT_FOOTER_BYTES]),
        )
        return bytes(encoded)

    def test_reference_direct_replay_and_semantic_roots_are_frozen(self) -> None:
        self.assertEqual(closed.PLAN_ABI, 0x4757434C50000001)
        self.assertEqual(closed.RESULT_ABI, 0x4757434C52000001)
        self.assertEqual(closed.TRACE_ABI, 0x4757434C54000001)
        self.assertEqual(closed.SUMMARY_ABI, 0x4757434C53000001)
        self.assertEqual(
            closed.plan_sha256(self.plan).hex(),
            "3641114db6e5a286888b6c17c5fe5dfda80e5b2218eeb98624c5762c9e58dfe0",
        )
        self.assertEqual(
            self.result["result_sha256"].hex(),
            "1086ce5e2ac75090acb0e40efd92792bb51238192923ecb1a9a71f3b4f250f41",
        )
        self.assertEqual(
            {
                name: self.result[name].hex()
                for name in (
                    "outcome_sha256",
                    "trace_sha256",
                    "summary_sha256",
                )
            },
            {
                "outcome_sha256": (
                    "4a2380bd7350afcd167a92cbf746487d"
                    "26c884cd72cfd1b64e0587e8d49ba6f1"
                ),
                "trace_sha256": (
                    "ad0ea0a930993f6c219c622db2129cb0"
                    "cb2932e14ecc2cc7d0ff032ba6bb3bda"
                ),
                "summary_sha256": (
                    "d670d8ae7ca6a6e6673cfdd39f6f883"
                    "d7b95f64885f8fce9438e4d498c531d3c"
                ),
            },
        )
        self.assertEqual(closed.validate_plan(self.plan), self.plan)
        self.assertEqual(
            closed.validate_result(self.plan, self.result),
            self.result,
        )

    def test_reference_summary_covers_turnover_rejections_and_drain(self) -> None:
        summary = self.result["summary"]
        expected = {
            "candidate_budget": 10,
            "in_flight_target": 3,
            "capacity": 4,
            "attempted": 10,
            "admitted": 7,
            "rejected": 3,
            "completed": 4,
            "cancelled": 2,
            "timed_out": 1,
            "service_quanta": 6,
            "driver_steps": 7,
            "final_logical_tick": 6,
            "maximum_active": 3,
            "maximum_due_credits": 3,
            "maximum_live_receipts": 3,
            "replacement_attempts": 7,
            "replacements_after_completed": 2,
            "replacements_after_rejected": 2,
            "replacements_after_cancelled": 2,
            "replacements_after_timed_out": 1,
            "credits_sealed": 10,
            "credits_exhausted": 3,
            "lineage_count": 3,
            "maximum_lineage_generation": 4,
            "peak_host_bytes": 3752,
            "maximum_wait_quanta": 2,
            "maximum_service_gap": 13,
            "fairness_cross_product_error": 8,
            "successful_commits": 7,
            "releases": 7,
            "final_active": 0,
            "final_due_credits": 0,
            "zero_orphan_ownership": True,
        }
        self.assertEqual(
            {name: summary[name] for name in expected},
            expected,
        )
        rejections = {
            outcome["ordinal"]: outcome["rejection_reason"]
            for outcome in self.result["outcomes"]
            if outcome["kind"] == closed.OUTCOME_REJECTED
        }
        self.assertEqual(
            rejections,
            {
                3: closed.REJECTION_DEADLINE_INFEASIBLE,
                8: closed.REJECTION_RESOURCE_LIMIT,
                9: closed.REJECTION_PROJECTION_LIMIT,
            },
        )

    def test_four_phases_fifo_lineage_and_no_same_step_refill(self) -> None:
        step_one = [
            record
            for record in self.result["trace"]
            if record["driver_step"] == 1
        ]
        terminal = [
            (
                record["phase"],
                record["event_kind"],
                record["candidate_ordinal"],
                record["terminal_action"],
            )
            for record in step_one
            if record["event_kind"]
            in (closed.EVENT_CANCEL, closed.EVENT_RETIRE)
        ]
        self.assertEqual(
            terminal,
            [
                (
                    closed.PHASE_APPLY_ACTIONS,
                    closed.EVENT_CANCEL,
                    0,
                    closed.ACTION_CANCEL,
                ),
                (
                    closed.PHASE_APPLY_ACTIONS,
                    closed.EVENT_CANCEL,
                    1,
                    closed.ACTION_TIMEOUT,
                ),
                (
                    closed.PHASE_SERVICE_RETIRE,
                    closed.EVENT_RETIRE,
                    2,
                    closed.ACTION_NONE,
                ),
            ],
        )
        self.assertEqual(
            [
                record["candidate_ordinal"]
                for record in step_one
                if record["event_kind"] == closed.EVENT_CREDIT_SEALED
            ],
            [0, 1, 2],
        )
        self.assertEqual(
            [
                (
                    outcome["ordinal"],
                    outcome["predecessor_ordinal"],
                    outcome["submission_step"],
                    outcome["lineage_index"],
                    outcome["lineage_generation"],
                )
                for outcome in self.result["outcomes"][3:]
            ],
            [
                (3, 0, 2, 0, 2),
                (4, 1, 2, 1, 2),
                (5, 2, 2, 2, 2),
                (6, 3, 3, 0, 3),
                (7, 4, 3, 1, 3),
                (8, 5, 3, 2, 3),
                (9, 8, 4, 2, 4),
            ],
        )
        self.assertNotIn(
            closed.EVENT_ADMISSION_ACCEPTED,
            [
                record["event_kind"]
                for record in step_one
                if record["candidate_ordinal"] >= 3
            ],
        )
        for record in self.result["trace"]:
            self.assertLessEqual(
                record["active_after"],
                self.plan["in_flight_target"],
            )
        traces_by_root = {
            record["record_sha256"]: record
            for record in self.result["trace"]
        }
        for outcome in self.result["outcomes"]:
            self.assertIn(outcome["admission_trace_sha256"], traces_by_root)
            self.assertIn(outcome["terminal_trace_sha256"], traces_by_root)
            predecessor = outcome["predecessor_ordinal"]
            if predecessor == closed.ABSENT:
                self.assertEqual(
                    outcome["trigger_trace_sha256"],
                    closed.ZERO_DIGEST,
                )
                self.assertEqual(
                    outcome["trigger_credit_sha256"],
                    closed.ZERO_DIGEST,
                )
                continue
            prior = self.result["outcomes"][predecessor]
            self.assertEqual(
                outcome["trigger_trace_sha256"],
                prior["terminal_trace_sha256"],
            )
            credit = traces_by_root[outcome["trigger_credit_sha256"]]
            self.assertEqual(
                (
                    credit["event_kind"],
                    credit["phase"],
                    credit["candidate_ordinal"],
                ),
                (
                    closed.EVENT_CREDIT_SEALED,
                    closed.PHASE_SEAL_STEP,
                    predecessor,
                ),
            )

    def test_target_one_reuses_one_lineage_and_drains_exhausted_credit(
        self,
    ) -> None:
        plan = closed.reference_plan()
        plan["seed"] += 1
        plan["capacity"] = 1
        plan["in_flight_target"] = 1
        plan["limits"]["queue_slots"] = 1
        plan["limits"]["host_bytes"] = 2000
        plan["max_service_quanta"] = 8
        plan["candidates"] = [
            closed._candidate(0, closed.MEDIA_VIDEO),
            closed._candidate(1, closed.MEDIA_AUDIO),
            closed._candidate(2, closed.MEDIA_IMAGE),
        ]
        result = closed.replay_plan(plan)
        self.assertEqual(
            [
                (
                    outcome["lineage_index"],
                    outcome["lineage_generation"],
                    outcome["predecessor_ordinal"],
                    outcome["submission_step"],
                )
                for outcome in result["outcomes"]
            ],
            [
                (0, 1, closed.ABSENT, 0),
                (0, 2, 0, 1),
                (0, 3, 1, 2),
            ],
        )
        self.assertEqual(result["summary"]["maximum_active"], 1)
        self.assertEqual(result["summary"]["maximum_lineage_generation"], 3)
        self.assertEqual(result["summary"]["credits_exhausted"], 1)
        self.assertEqual(result["summary"]["driver_steps"], 4)
        self.assertTrue(result["summary"]["zero_orphan_ownership"])

    def test_plan_rejects_bounds_identity_profile_and_action_mutations(
        self,
    ) -> None:
        mutations: list[dict[str, object]] = []
        for field, value in (
            ("in_flight_target", 0),
            ("capacity", 0),
            ("max_driver_steps", 0),
            ("max_service_quanta", 0),
            ("challenge", bytes(32)),
        ):
            changed = copy.deepcopy(self.plan)
            changed[field] = value
            mutations.append(changed)

        changed = copy.deepcopy(self.plan)
        changed["in_flight_target"] = changed["capacity"] + 1
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["limits"]["queue_slots"] = 3
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["candidates"][1]["tenant_key"] = changed["candidates"][0][
            "tenant_key"
        ]
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["candidates"][1]["ordinal"] = 0
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["candidates"][0]["terminal_action"] = closed.ACTION_NONE
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["candidates"][0]["claim"]["queue_slots"] = 2
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["candidates"][0]["profile_sha256"] = bytes((1,)) * 32
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["max_service_quanta"] = 1
        mutations.append(changed)
        changed = copy.deepcopy(self.plan)
        changed["candidates"][9]["deadline_budget_quanta"] = 9
        mutations.append(changed)

        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(closed.WorkloadClosedLoopError):
                    closed.validate_plan(mutation)

    def test_replay_rejects_step_exhaustion_without_partial_result(self) -> None:
        changed = copy.deepcopy(self.plan)
        changed["max_driver_steps"] = 4
        with self.assertRaisesRegex(
            closed.WorkloadClosedLoopError,
            "driver step limit exceeded",
        ):
            closed.replay_plan(changed)

    def test_resealed_semantic_result_mutations_fail_exact_replay(self) -> None:
        mutations: list[dict[str, object]] = []

        changed = copy.deepcopy(self.result)
        outcome = changed["outcomes"][3]
        outcome["predecessor_ordinal"] = 1
        outcome["record_sha256"] = closed.outcome_record_sha256(
            {
                name: value
                for name, value in outcome.items()
                if name != "record_sha256"
            }
        )
        self._reseal_result(changed)
        mutations.append(changed)

        changed = copy.deepcopy(self.result)
        outcome = changed["outcomes"][3]
        outcome["trigger_credit_sha256"] = bytes((0xA5,)) * 32
        outcome["record_sha256"] = closed.outcome_record_sha256(
            {
                name: value
                for name, value in outcome.items()
                if name != "record_sha256"
            }
        )
        self._reseal_result(changed)
        mutations.append(changed)

        changed = copy.deepcopy(self.result)
        record = next(
            item
            for item in changed["trace"]
            if item["event_kind"] == closed.EVENT_CREDIT_SEALED
        )
        record["phase"] = closed.PHASE_ADMIT_DUE
        record["record_sha256"] = closed.trace_record_sha256(
            {
                name: value
                for name, value in record.items()
                if name != "record_sha256"
            }
        )
        self._reseal_result(changed)
        mutations.append(changed)

        changed = copy.deepcopy(self.result)
        changed["summary"]["maximum_active"] -= 1
        self._reseal_result(changed)
        mutations.append(changed)

        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(closed.WorkloadClosedLoopError):
                    closed.validate_result(self.plan, mutation)

    def test_plan_wire_round_trip_and_mutations_fail_closed(self) -> None:
        encoded = closed.encode_plan(self.plan)
        self.assertEqual(len(encoded), closed.required_plan_bytes(10))
        self.assertEqual(closed.decode_plan(encoded), self.plan)
        mutations = [
            encoded[:-1],
            encoded + b"\x00",
            bytes((encoded[0] ^ 1,)) + encoded[1:],
            encoded[:-1] + bytes((encoded[-1] ^ 1,)),
        ]
        for offset in (8, 16, 24, 32, 40, 48, 56, 312):
            changed = bytearray(encoded)
            changed[offset] ^= 1
            mutations.append(self._reseal_plan_wire(changed))
        for offset in (
            280,
            closed.PLAN_HEADER_BYTES + 104,
            closed.PLAN_HEADER_BYTES + 224,
        ):
            changed = bytearray(encoded)
            changed[offset] ^= 1
            mutations.append(self._reseal_plan_wire(changed))
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(closed.WorkloadClosedLoopError):
                    closed.decode_plan(mutation)
        for count in (0, closed.MAXIMUM_CANDIDATES + 1, True):
            with self.assertRaises(closed.WorkloadClosedLoopError):
                closed.required_plan_bytes(count)

    def test_result_wire_round_trip_and_mutations_fail_closed(self) -> None:
        encoded = closed.encode_result(self.plan, self.result)
        self.assertEqual(
            len(encoded),
            closed.required_result_bytes(10, 37),
        )
        self.assertEqual(
            closed.decode_result(self.plan, encoded),
            self.result,
        )
        foreign_plan = copy.deepcopy(self.plan)
        foreign_plan["seed"] += 1
        with self.assertRaises(closed.WorkloadClosedLoopError):
            closed.decode_result(foreign_plan, encoded)
        with self.assertRaises(closed.WorkloadClosedLoopError):
            closed.encode_result(foreign_plan, self.result)
        mutations = [
            encoded[:-1],
            encoded + b"\x00",
            bytes((encoded[0] ^ 1,)) + encoded[1:],
            encoded[:-1] + bytes((encoded[-1] ^ 1,)),
        ]
        for offset in (8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88):
            changed = bytearray(encoded)
            changed[offset] ^= 1
            mutations.append(self._reseal_result_wire(changed))
        trace_offset = (
            closed.RESULT_HEADER_BYTES
            + len(self.result["outcomes"]) * closed.OUTCOME_RECORD_BYTES
        )
        summary_offset = (
            trace_offset
            + len(self.result["trace"]) * closed.TRACE_RECORD_BYTES
        )
        for offset in (
            96,
            128,
            160,
            192,
            224,
            closed.RESULT_HEADER_BYTES + 296,
            trace_offset + 168,
            summary_offset + 392,
        ):
            changed = bytearray(encoded)
            changed[offset] ^= 1
            mutations.append(self._reseal_result_wire(changed))
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(closed.WorkloadClosedLoopError):
                    closed.decode_result(self.plan, mutation)
        for counts in (
            (0, 1),
            (1, 0),
            (closed.MAXIMUM_CANDIDATES + 1, 1),
            (1, closed.MAXIMUM_TRACE_RECORDS + 1),
            (True, 1),
        ):
            with self.assertRaises(closed.WorkloadClosedLoopError):
                closed.required_result_bytes(*counts)

    def test_report_is_canonical_and_semantic_mutations_are_rejected(
        self,
    ) -> None:
        report = closed.build_report()
        self.assertEqual(report["candidate_abi"], "4757434c43000001")
        self.assertEqual(report["outcome_abi"], "4757434c4f000001")
        initial = report["outcomes"][0]
        self.assertIsNone(initial["predecessor_ordinal"])
        self.assertIsNone(initial["trigger_terminal_step"])
        self.assertEqual(initial["trigger_trace_sha256"], "0" * 64)
        self.assertEqual(initial["trigger_credit_sha256"], "0" * 64)
        rejected = report["outcomes"][3]
        self.assertIsNone(rejected["scheduler_slot_index"])
        self.assertIsNone(rejected["admitted_step"])
        self.assertIsNone(rejected["first_service_step"])
        for name in (
            "trigger_trace_sha256",
            "trigger_credit_sha256",
            "admission_trace_sha256",
            "terminal_trace_sha256",
            "record_sha256",
        ):
            self.assertEqual(len(rejected[name]), 64)
        self.assertEqual(
            {
                name: report[name]
                for name in (
                    "plan_wire_bytes",
                    "result_wire_bytes",
                    "plan_wire_sha256",
                    "result_wire_sha256",
                )
            },
            {
                "plan_wire_bytes": 2912,
                "result_wire_bytes": 11392,
                "plan_wire_sha256": (
                    "cf966b2744ec5fd15054d1041681aa90"
                    "f9bf618cdfb3c7f396e7aaa4888044f6"
                ),
                "result_wire_sha256": (
                    "98cc9122b649b98402965853ac185071"
                    "d12b1e27112e167a878d9a17f9e523fc"
                ),
            },
        )
        encoded = closed.render_report(report).encode("ascii")
        self.assertTrue(encoded.endswith(b"\n"))
        self.assertFalse(encoded.endswith(b"\n\n"))
        self.assertEqual(closed._load_json_exact(encoded, "report"), report)
        self.assertEqual(closed.validate_report(report), report)
        malformed = (
            encoded[:-1],
            encoded + b"\n",
            encoded.replace(b"{", b"{ ", 1),
            b'{"schema":"a","schema":"b"}\n',
            b'{"value":NaN}\n',
            b"[]\n",
            b"\xff\n",
        )
        for index, value in enumerate(malformed):
            with self.subTest(index=index):
                with self.assertRaises(closed.WorkloadClosedLoopError):
                    closed._load_json_exact(value, "report")
        for mutation in (
            ("result_sha256", "0" * 64),
            ("candidate_count", 9),
        ):
            changed = copy.deepcopy(report)
            changed[mutation[0]] = mutation[1]
            with self.assertRaises(closed.WorkloadClosedLoopError):
                closed.validate_report(changed)
        changed = copy.deepcopy(report)
        changed["summary"]["fairness_cross_product_error"] = 7
        with self.assertRaises(closed.WorkloadClosedLoopError):
            closed.validate_report(changed)
        changed = copy.deepcopy(report)
        changed["outcomes"][3]["predecessor_ordinal"] = 1
        with self.assertRaises(closed.WorkloadClosedLoopError):
            closed.validate_report(changed)

    def test_runner_comparison_requires_exact_fixture_and_output(self) -> None:
        expected = closed.render_report().encode("ascii")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "fixture.json"
            runner = root / "runner.py"
            fixture.write_bytes(expected)
            runner.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                f"sys.stdout.buffer.write({expected!r})\n",
                encoding="ascii",
            )
            runner_command = [sys.executable, str(runner)]
            closed.verify_runner(runner_command, fixture)

            fixture.write_bytes(b"{}\n")
            with self.assertRaisesRegex(
                closed.WorkloadClosedLoopError,
                "fixture is stale",
            ):
                closed.verify_runner(runner_command, fixture)
            fixture.unlink()
            self.assertEqual(
                closed.main(
                    [
                        "--runner",
                        str(runner),
                        "--fixture",
                        str(fixture),
                    ]
                ),
                2,
            )

    def test_w0_w1_and_w2_reference_goldens_remain_unchanged(self) -> None:
        scenario = workload.reference_scenario()
        result = workload.replay_scenario(scenario)
        evidence = scheduled.build_reference_evidence()
        report = corpus.build_report()
        self.assertEqual(
            workload.scenario_sha256(scenario).hex(),
            "e6fc0e1b3d676c5ea89a2e54434bef0ac51e30f8b1ab85944bfc43e0cd34407b",
        )
        self.assertEqual(
            workload.encode_result(result)[-32:].hex(),
            "1f5509316a967fe410b90ac0970af3ce77e0d63c1e1ab4f81012a23accea5fb0",
        )
        self.assertEqual(
            evidence["evidence_sha256"].hex(),
            "f6d17a0d6471379c61bd38a5ac255c88f14dfb7585e150cda85b8d04631b880b",
        )
        self.assertEqual(
            report["corpus_sha256"],
            "68215427b0c8feef54611eb144446b1819a587e41d4696d2b9483e22d8ca5bbc",
        )


if __name__ == "__main__":
    unittest.main()
