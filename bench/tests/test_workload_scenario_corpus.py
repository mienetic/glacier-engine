from __future__ import annotations

import copy
import unittest
from pathlib import Path

from bench import scheduled_media_pressure as scheduled
from bench import workload_pressure as workload
from bench import workload_scenario_corpus as corpus


FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "results"
    / "workload-scenario-corpus-v1.json"
)

DECISION_KATS = {
    corpus.DecisionTag.SCENARIO_SEED: (
        "4c0b3855daa90459f6025c1c00d2822da64d24e4742b117896020c0887b1a006"
    ),
    corpus.DecisionTag.BANK_EPOCH: (
        "cbc709239e8dd4ee3f496671cf4abc5d69cded5e26d1cebf730762e771aeb522"
    ),
    corpus.DecisionTag.SCHEDULER_EPOCH: (
        "47d3ca0a4e836d6351cd8f20a39790ee1a49c71b57b61d698325d0fcefd90431"
    ),
    corpus.DecisionTag.CHALLENGE: (
        "72c2beb7487d9e24725a33593e5d6f84b23394eb993545de6a79bcffb7a17c1e"
    ),
    corpus.DecisionTag.MODALITY_ROTATION: (
        "a5495d4122eb9a23e106773fcca08fc6a7c3c133124a3513433a4dc72f30633e"
    ),
}

CASE_ROOTS = (
    "7503b944a4092d3e0a3c7c40602f7df38d46adbf4569d038353004668b993c0b",
    "b9e0a55253faf1b10166d2c6eef6e92f59657fc6fc56d90d16af71a594b9d2a3",
    "db24324fecd8738ea3247cb88b66d62cbe993f67fd8bda80fdf895a20dbfe32a",
    "5541934f84f4a8336b9d120748a49701958e0b0de65b09544f172b0f505cb743",
    "0e409f7ddd9d4717c6d8554ce1edfda0e399f0af66e126615fc6a5bb6bd5bc49",
    "bb0f4cca96911c99d11ed6c0008f2f3b6c53024fa82119a2ba3544f5edfce17f",
    "1b66b98e7898277ef63dbbff32bd724cb6c24d53fda44e5171254411290ca4da",
    "e63afcad7020390d493d64f7adc8953a7114a017468ad8d2a6bd85a08fb30f2c",
    "4d514a92661a25b2a458fd9fcdde765cf57c8d164a6cc689cd3fc3676841a9d6",
    "e68b8ef908178c7b97c33d092b068d406416d7e098d09229176f8d1832203039",
    "7305d831100015d733e5b7239207409c6647259b187a39fdcdbdd0b57b2f68b1",
    "1ec4930828dec0de95bd8765d58281077976011a80424f2b04329f22389235de",
    "f77777dd80e3de97f8e6f4387168d9a663615f403d45711f89ac9d4e767a8a14",
    "4ec2b5a4bdc54c3790fc2e4bf8a2e2db299c62c39f410cf68bcfa0e79723898c",
    "abf0a365f21fc7deb10b8290bb9cf3649b4d1a3cf78caa88097b630929e9ad93",
    "3a999f994c5f31f96a14af291de18fd01b2d2fddbd12d26dc837e743bd11d9b6",
    "64e53f9f0c42f9c802c91d6de2aa5d5e666023688c86d104e9b002ff4fa0b762",
    "090b433fff9c51d5a57d0b5931b74e42a341ba481f11eb127a08579c70db611b",
    "6a6f2f922069a24615d78d9563dff084f1a9bf6e5cf925f107dc7713b51f2ace",
    "e9f1cff8c2c2ff99eb243840416e3b6aab3568edba26f37acf0b0c0e87abf19d",
    "dc7c20a1486b4ab139cc62590cfca73a884ddc29a09b5b25a5d85a5095b19dc1",
    "cfa6d70b0c6201db0e97a85ac6740b765fba8054a431db6b1fbbc27ec1a154d5",
    "f3e31686117e0d803d3d10f00c44454d35a15e00905e917be178a265997aac90",
    "75b8556f846c8b3a61c0b68f805830dae060916734e65721553e733271566477",
    "d5025d5b07d1fd5bf89c7e1f96475aea45c204aca3d6fd0e6dff77cd52ce40c6",
    "dad7dad286dec6eba5eb74a7b4bde82229ebd17eec427da3904378be3e51ca4a",
    "39aa8fdbbda895040797534647b5f40350006335559a805535dd05337050db77",
    "9bad97058e3d83f2f56d72e5fb0df11616d1f197e1605eb1553fdad3c3c6b6dd",
    "98652366f643059e2993044b92700f6b18019ca5d7afce14044948c73b59f432",
    "e5c88c37e4d3b096aac45979d621a91f316a7f24817e402648945fe89cd086fb",
    "6e5e59c15aaface00497d84350b2d98a005153542e06d68e891bd8f5e5b71793",
    "3926667442459e19b398b796688689db774fdb2fb157e39b4f9e14ba3371aaf6",
)


class WorkloadScenarioCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = corpus.build_report()

    def test_abi_seed_class_and_decision_contract_is_frozen(self) -> None:
        self.assertEqual(corpus.GENERATOR_ABI, 0x4757434700000001)
        self.assertEqual(corpus.SHRINKER_ABI, 0x4757435300000001)
        self.assertEqual(corpus.CORPUS_ABI, 0x4757434300000001)
        self.assertEqual(corpus.COVERAGE_ABI, 0x4757435600000001)
        self.assertEqual(corpus.FAILURE_ABI, 0x4757434600000001)
        self.assertEqual(
            corpus.RETAINED_SEEDS,
            tuple(range(0x4757433220260001, 0x4757433220260005)),
        )
        self.assertEqual(
            tuple(int(value) for value in corpus.ScenarioClass),
            tuple(range(1, 9)),
        )
        for tag, expected in DECISION_KATS.items():
            with self.subTest(tag=tag):
                self.assertEqual(
                    corpus.decision(
                        corpus.RETAINED_SEEDS[0],
                        0,
                        corpus.ScenarioClass.FAIRNESS,
                        tag,
                    ).hex(),
                    expected,
                )

    def test_all_32_cases_round_trip_w0_and_generic_w1(self) -> None:
        aggregate_coverage = 0
        for seed_index in range(4):
            for class_index in range(8):
                with self.subTest(
                    seed_index=seed_index,
                    class_index=class_index,
                ):
                    scenario = corpus.generate_scenario(seed_index, class_index)
                    scenario_wire = workload.encode_scenario(scenario)
                    self.assertEqual(
                        workload.decode_scenario(scenario_wire),
                        scenario,
                    )
                    result = workload.replay_scenario(scenario)
                    result_wire = workload.encode_result(result)
                    decoded_result = workload.decode_result(result_wire)
                    self.assertEqual(
                        workload.validate_result(scenario, decoded_result),
                        result,
                    )
                    evidence = scheduled.build_evidence(scenario)
                    evidence_wire = scheduled.encode_evidence(evidence)
                    decoded_evidence = scheduled.decode_evidence(evidence_wire)
                    self.assertEqual(
                        scheduled.validate_evidence(scenario, decoded_evidence),
                        evidence,
                    )
                    self.assertTrue(result["summary"]["zero_orphan_ownership"])
                    aggregate_coverage |= corpus.coverage_bits(scenario, result)
        self.assertEqual(aggregate_coverage, corpus.MANDATORY_COVERAGE)

    def test_retained_case_and_corpus_roots_are_frozen(self) -> None:
        self.assertEqual(
            tuple(case["case_sha256"] for case in self.report["cases"]),
            CASE_ROOTS,
        )
        self.assertEqual(
            {
                field: self.report[field]
                for field in (
                    "case_count",
                    "coverage_bits",
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
                    "zero_orphan_ownership",
                    "corpus_sha256",
                )
            },
            {
                "case_count": 32,
                "coverage_bits": "0000000000007fff",
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
                "corpus_sha256": (
                    "68215427b0c8feef54611eb144446b181"
                    "9a587e41d4696d2b9483e22d8ca5bbc"
                ),
            },
        )

    def test_corpus_root_recomputes_child_roots_from_case_metadata(self) -> None:
        totals = {
            field: self.report[field]
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
                "zero_orphan_ownership",
            )
        }
        coverage = int(self.report["coverage_bits"], 16)
        expected = bytes.fromhex(self.report["corpus_sha256"])
        self.assertEqual(
            corpus._corpus_root(self.report["cases"], totals, coverage),
            expected,
        )

        stale_metadata = copy.deepcopy(self.report["cases"])
        stale_metadata[0]["service_quanta"] += 1
        self.assertNotEqual(
            corpus._corpus_root(stale_metadata, totals, coverage),
            expected,
        )

        stale_cached_root = copy.deepcopy(self.report["cases"])
        stale_cached_root[0]["case_sha256"] = "00" * 32
        self.assertEqual(
            corpus._corpus_root(stale_cached_root, totals, coverage),
            expected,
        )

    def test_reference_w0_and_w1_goldens_are_unchanged(self) -> None:
        scenario = workload.reference_scenario()
        result = workload.replay_scenario(scenario)
        evidence = scheduled.build_reference_evidence()
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

    def test_shrinker_preserves_exact_signature_and_reaches_fixed_point(
        self,
    ) -> None:
        original = corpus.generate_scenario(
            0,
            corpus.ScenarioClass.CANCEL_TURNOVER - 1,
        )
        shrink = corpus.run_synthetic_shrink()
        self.assertEqual(
            shrink["original_scenario_sha256"].hex(),
            "552f40e339d7dc4b90757179ef244de25015caeea2890a08eb978f50a9cba314",
        )
        self.assertEqual(
            shrink["minimized_scenario_sha256"].hex(),
            "6cf1ea51f6b1deb5f765500eb389c408c9eb451e8b9ba5ca971f9295fefc4cf4",
        )
        self.assertEqual(
            shrink["failure_signature_sha256"].hex(),
            "d0b9ca7624476aa868bf28115635e35119224f642031d6a810ed93c08151cff3",
        )
        self.assertEqual(shrink["evaluations"], 58)
        self.assertEqual(shrink["reductions"], 8)
        self.assertFalse(shrink["budget_exhausted"])
        self.assertTrue(shrink["locally_minimal"])
        self.assertLess(
            corpus.complexity(shrink["scenario"]),
            corpus.complexity(original),
        )
        result = workload.replay_scenario(shrink["scenario"])
        self.assertEqual(
            corpus.synthetic_failure_probe(shrink["scenario"], result),
            corpus.synthetic_failure_signature(),
        )
        second = corpus.shrink_failure(
            shrink["scenario"],
            corpus.synthetic_failure_signature(),
            corpus.synthetic_failure_probe,
            corpus.MAXIMUM_SHRINK_EVALUATIONS,
        )
        self.assertEqual(
            second["minimized_scenario_sha256"],
            shrink["minimized_scenario_sha256"],
        )
        self.assertEqual(second["reductions"], 0)
        self.assertEqual(second["evaluations"], 8)
        self.assertTrue(second["locally_minimal"])

    def test_shrinker_rejects_budget_signature_and_probe_failures(self) -> None:
        original = corpus.generate_scenario(
            0,
            corpus.ScenarioClass.CANCEL_TURNOVER - 1,
        )
        with self.assertRaises(corpus.WorkloadScenarioCorpusError):
            corpus.run_synthetic_shrink(2)
        for budget in (0, 1, 3, corpus.MAXIMUM_SHRINK_EVALUATIONS + 2):
            with self.subTest(budget=budget):
                with self.assertRaises(corpus.WorkloadScenarioCorpusError):
                    corpus.run_synthetic_shrink(budget)

        changed_signature = copy.deepcopy(corpus.synthetic_failure_signature())
        changed_signature["code"] += 1
        with self.assertRaises(corpus.WorkloadScenarioCorpusError):
            corpus.shrink_failure(
                original,
                changed_signature,
                corpus.synthetic_failure_probe,
                corpus.MAXIMUM_SHRINK_EVALUATIONS,
            )
        with self.assertRaises(corpus.WorkloadScenarioCorpusError):
            corpus.shrink_failure(
                original,
                corpus.synthetic_failure_signature(),
                lambda _scenario, _result: None,
                corpus.MAXIMUM_SHRINK_EVALUATIONS,
            )

        calls = 0

        def unstable(_scenario: dict[str, object], _result: dict[str, object]):
            nonlocal calls
            calls += 1
            return corpus.synthetic_failure_signature() if calls % 2 else None

        with self.assertRaises(corpus.WorkloadScenarioCorpusError):
            corpus.shrink_failure(
                original,
                corpus.synthetic_failure_signature(),
                unstable,
                corpus.MAXIMUM_SHRINK_EVALUATIONS,
            )

    def test_fixture_is_canonical_and_matches_independent_replay(self) -> None:
        encoded = FIXTURE.read_bytes()
        decoded = corpus._load_json_exact(encoded, "fixture")
        self.assertEqual(corpus.validate_report(decoded), self.report)
        self.assertEqual(encoded.decode("ascii"), corpus.render_report(self.report))

    def test_report_semantic_mutations_and_noncanonical_json_reject(self) -> None:
        mutations = []
        changed = copy.deepcopy(self.report)
        changed["generator_abi"] = "4757434700000002"
        mutations.append(changed)
        changed = copy.deepcopy(self.report)
        changed["cases"][0]["scenario_sha256"] = "00" * 32
        mutations.append(changed)
        changed = copy.deepcopy(self.report)
        changed["cases"].reverse()
        mutations.append(changed)
        changed = copy.deepcopy(self.report)
        changed["synthetic_shrinker"]["locally_minimal"] = False
        mutations.append(changed)
        for index, changed in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(corpus.WorkloadScenarioCorpusError):
                    corpus.validate_report(changed)

        canonical = corpus.render_report(self.report).encode("ascii")
        for malformed in (
            canonical[:-1],
            canonical + b"\n",
            b" " + canonical,
            b'{"schema":"a","schema":"b"}\n',
        ):
            with self.assertRaises(corpus.WorkloadScenarioCorpusError):
                corpus._load_json_exact(malformed, "fixture")


if __name__ == "__main__":
    unittest.main()
