import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


BENCH_DIR = Path(__file__).resolve().parents[1]
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))
MODULE_PATH = BENCH_DIR / "binary_ab.py"
SPEC = importlib.util.spec_from_file_location("binary_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
binary_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = binary_ab
SPEC.loader.exec_module(binary_ab)


class BinaryAbTests(unittest.TestCase):
    @staticmethod
    def _write_parallel_binary(
        path: Path,
        *,
        decode_ms: str,
        internal_ms: str,
        fused: bool = True,
        paired_fields: bool = True,
        paired_coverage: bool = True,
    ) -> None:
        paired_suffix = (
            " paired_mlp_graphs={paired_graphs}"
            " paired_mlp_dispatches={paired_dispatches}"
            if paired_fields
            else ""
        )
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib,sys\n"
            "a=sys.argv\n"
            "if '--parallel-attention-min-context' not in a or '--serial-attention' in a:\n"
            "    raise SystemExit(11)\n"
            "threshold=int(a[a.index('--parallel-attention-min-context')+1])\n"
            "out=pathlib.Path(a[a.index('--out-ids-file')+1])\n"
            "prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())\n"
            "tokens=int(a[a.index('--n')+1]); runs=max(0,tokens-1); layers=4\n"
            "graphs=min(runs,max(0,prompt+runs-threshold+1))\n"
            "dispatches=graphs*layers\n"
            f"fused={fused!r}\n"
            "fused_graphs=graphs if fused else 0\n"
            "fused_dispatches=fused_graphs*layers\n"
            f"paired_coverage={paired_coverage!r}\n"
            "paired_graphs=graphs if paired_coverage else 0\n"
            "paired_dispatches=paired_graphs*layers\n"
            "out.write_text(' '.join(str(7+i) for i in range(tokens))+'\\n')\n"
            "print('load: mode=prepared artifact=glrt ms=1.0')\n"
            "print(f'schedule: attention=parallel min_context={threshold} layers={layers}')\n"
            "print('ready: phase=request_ready ms=2.0')\n"
            f"print(f'phases: prefill_ms=3.0 decode_ms={decode_ms} sampling_ms=0.1 decode_runs={{runs}} attention_graphs={{graphs}} attention_dispatches={{dispatches}} handoff_graphs={{graphs}} handoff_dispatches={{dispatches}} fused_gqa_graphs={{fused_graphs}} fused_gqa_dispatches={{fused_dispatches}}{paired_suffix}')\n"
            f"print(f'time: {internal_ms} ms (100.0 tok/s, prefilled {{prompt}}, prefill=batch)')\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def test_serial_phase_schema_normalization_preserves_all_generations(self):
        prefix = (
            "phases: prefill_ms=3.0 decode_ms=5.0 sampling_ms=0.1 "
            "decode_runs=1 attention_graphs=0 attention_dispatches=0"
        )
        legacy, legacy_format = binary_ab._normalize_serial_telemetry(prefix + "\n")
        handoff, handoff_format = binary_ab._normalize_serial_telemetry(
            prefix + " handoff_graphs=0 handoff_dispatches=0\n"
        )
        fused, fused_format = binary_ab._normalize_serial_telemetry(
            prefix
            + " handoff_graphs=0 handoff_dispatches=0"
            + " fused_gqa_graphs=0 fused_gqa_dispatches=0\n"
        )
        paired, paired_format = binary_ab._normalize_serial_telemetry(
            prefix
            + " handoff_graphs=0 handoff_dispatches=0"
            + " fused_gqa_graphs=0 fused_gqa_dispatches=0"
            + " paired_mlp_graphs=0 paired_mlp_dispatches=0\n"
        )
        for normalized in (legacy, handoff, fused, paired):
            self.assertIn("paired_mlp_graphs=0 paired_mlp_dispatches=0", normalized)
        self.assertEqual(
            fused.rstrip().split()[-2:],
            ["paired_mlp_graphs=0", "paired_mlp_dispatches=0"],
        )
        self.assertEqual(legacy_format, "legacy-v1+handoff-fused-paired-zero")
        self.assertEqual(handoff_format, "handoff-v2+fused-paired-zero")
        self.assertEqual(fused_format, "fused-gqa-v3+paired-zero")
        self.assertEqual(paired_format, "paired-mlp-v4")

    def test_phase_schema_normalization_rejects_partial_paired_record(self):
        partial = (
            "phases: prefill_ms=3.0 decode_ms=5.0 sampling_ms=0.1 "
            "decode_runs=1 attention_graphs=0 attention_dispatches=0 "
            "handoff_graphs=0 handoff_dispatches=0 "
            "fused_gqa_graphs=0 fused_gqa_dispatches=0 paired_mlp_graphs=0\n"
        )
        with self.assertRaisesRegex(
            binary_ab.common.HarnessError,
            "paired-MLP phase telemetry is missing, malformed, or duplicated",
        ):
            binary_ab._normalize_serial_telemetry(partial)

    def test_legacy_baseline_and_fused_candidate_compare_exactly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def write_binary(path: Path, *, candidate: bool) -> None:
                decode_ms = "5.0" if candidate else "10.0"
                internal_ms = "10.0" if candidate else "20.0"
                current = (
                    " handoff_graphs=0 handoff_dispatches=0"
                    " fused_gqa_graphs=0 fused_gqa_dispatches=0"
                    " paired_mlp_graphs=0 paired_mlp_dispatches=0"
                    if candidate
                    else ""
                )
                path.write_text(
                    "#!/usr/bin/env python3\n"
                    "import pathlib,sys\n"
                    "a=sys.argv\n"
                    "out=pathlib.Path(a[a.index('--out-ids-file')+1])\n"
                    "prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())\n"
                    "out.write_text('7 8\\n')\n"
                    "print('load: mode=prepared artifact=glrt ms=1.0')\n"
                    "print('schedule: attention=serial layers=4')\n"
                    "print('ready: phase=request_ready ms=2.0')\n"
                    f"print('phases: prefill_ms=3.0 decode_ms={decode_ms} sampling_ms=0.1 decode_runs=1 attention_graphs=0 attention_dispatches=0{current}')\n"
                    f"print(f'time: {internal_ms} ms (100.0 tok/s, prefilled {{prompt}}, prefill=batch)')\n",
                    encoding="utf-8",
                )
                path.chmod(0o755)

            baseline = root / "baseline"
            candidate = root / "candidate"
            write_binary(baseline, candidate=False)
            write_binary(candidate, candidate=True)
            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = binary_ab.Config(
                baseline_binary=baseline,
                candidate_binary=candidate,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                samples_per_variant=4,
                warmups_per_variant=1,
                new_tokens=2,
                threads=1,
                schedule_seed=8,
                bootstrap_seed=9,
                bootstrap_resamples=100,
            )
            result = binary_ab.run_benchmark(config)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["schema"], binary_ab.SCHEMA)
            self.assertNotIn("schema", result["contract"])
            self.assertEqual(result["contract"]["attention_policy"], "serial")
            self.assertIsNone(result["contract"]["parallel_attention_min_context"])
            self.assertFalse(result["contract"]["require_fused_gqa"])
            self.assertFalse(result["contract"]["require_candidate_paired_mlp"])
            self.assertEqual(len(result["samples"]), 8)
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["baseline_over_candidate"]["decode_ms"]["estimate"], 2.0
            )
            formats = {item["telemetry_format"] for item in result["samples"]}
            self.assertEqual(
                formats,
                {"legacy-v1+handoff-fused-paired-zero", "paired-mlp-v4"},
            )
            for item in [*result["warmups"], *result["samples"]]:
                self.assertIn("--serial-attention", item["argv"])
                self.assertNotIn("--parallel-attention-min-context", item["argv"])
                self.assertEqual(item["attention_policy"], "serial")

    def test_parallel_cli_is_optional_and_records_threshold(self):
        required = [
            "--baseline-binary",
            "baseline",
            "--candidate-binary",
            "candidate",
            "--model",
            "model.glrt",
            "--ids",
            "prompt.ids",
            "--output",
            "result.json",
        ]
        serial = binary_ab.parse_args(required)
        parallel = binary_ab.parse_args(
            [*required, "--parallel-attention-min-context", "17"]
        )
        self.assertIsNone(serial.parallel_attention_min_context)
        self.assertEqual(parallel.parallel_attention_min_context, 17)

    def test_parallel_cross_binary_uses_same_policy_and_strict_fused_telemetry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline"
            candidate = root / "candidate"
            self._write_parallel_binary(
                baseline,
                decode_ms="10.0",
                internal_ms="20.0",
                paired_fields=False,
            )
            self._write_parallel_binary(candidate, decode_ms="5.0", internal_ms="10.0")
            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = binary_ab.Config(
                baseline_binary=baseline,
                candidate_binary=candidate,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                samples_per_variant=4,
                warmups_per_variant=1,
                new_tokens=2,
                threads=1,
                schedule_seed=8,
                bootstrap_seed=9,
                bootstrap_resamples=100,
                parallel_attention_min_context=3,
            )
            result = binary_ab.run_benchmark(config)
            self.assertEqual(result["schema"], binary_ab.SCHEMA)
            self.assertNotIn("schema", result["contract"])
            self.assertEqual(result["contract"]["attention_policy"], "parallel")
            self.assertEqual(result["contract"]["parallel_attention_min_context"], 3)
            self.assertTrue(result["contract"]["require_fused_gqa"])
            self.assertTrue(result["contract"]["require_candidate_paired_mlp"])
            self.assertTrue(result["contract"]["require_native_paired_mlp"])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["baseline_over_candidate"]["decode_ms"]["estimate"], 2.0
            )
            self.assertEqual(
                {item["role"] for item in result["samples"]},
                {"baseline", "candidate"},
            )
            for item in [*result["warmups"], *result["samples"]]:
                argv = item["argv"]
                self.assertNotIn("--serial-attention", argv)
                threshold_index = argv.index("--parallel-attention-min-context")
                self.assertEqual(argv[threshold_index + 1], "3")
                self.assertEqual(item["attention_policy"], "parallel")
                self.assertEqual(item["metrics"]["fused_gqa_graphs"], 1)
                self.assertEqual(item["metrics"]["fused_gqa_dispatches"], 4)
                if item["role"] == "baseline":
                    self.assertEqual(
                        item["telemetry_format"], "fused-gqa-v3+paired-zero"
                    )
                    self.assertEqual(item["metrics"]["paired_mlp_graphs"], 0)
                else:
                    self.assertEqual(item["telemetry_format"], "paired-mlp-v4")
                    self.assertEqual(item["metrics"]["paired_mlp_graphs"], 1)
                    self.assertEqual(item["metrics"]["paired_mlp_dispatches"], 4)

    def test_parallel_requires_fused_gqa_for_each_binary_role(self):
        for unfused_role in binary_ab.ROLES:
            with (
                self.subTest(role=unfused_role),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                baseline = root / "baseline"
                candidate = root / "candidate"
                self._write_parallel_binary(
                    baseline,
                    decode_ms="10.0",
                    internal_ms="20.0",
                    fused=unfused_role != "baseline",
                    paired_fields=False,
                )
                self._write_parallel_binary(
                    candidate,
                    decode_ms="5.0",
                    internal_ms="10.0",
                    fused=unfused_role != "candidate",
                )
                model = root / "model.glrt"
                model.write_bytes(b"model")
                ids = root / "prompt.ids"
                ids.write_text("1 2 3\n", encoding="ascii")
                config = binary_ab.Config(
                    baseline_binary=baseline,
                    candidate_binary=candidate,
                    model=model,
                    ids=ids,
                    output=None,
                    cwd=root,
                    samples_per_variant=4,
                    warmups_per_variant=1,
                    new_tokens=2,
                    threads=1,
                    bootstrap_resamples=100,
                    parallel_attention_min_context=3,
                )
                artifacts = binary_ab._fingerprints(config)
                with self.assertRaisesRegex(
                    binary_ab.common.HarnessError,
                    "required fused GQA covered 0 graphs, expected 1",
                ):
                    binary_ab._observe(
                        config,
                        unfused_role,
                        root / f"{unfused_role}.ids",
                        [1, 2, 3],
                        artifacts,
                    )

    def test_parallel_candidate_must_emit_native_paired_mlp_telemetry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline"
            candidate = root / "candidate"
            self._write_parallel_binary(
                baseline,
                decode_ms="10.0",
                internal_ms="20.0",
                paired_fields=False,
            )
            self._write_parallel_binary(
                candidate,
                decode_ms="5.0",
                internal_ms="10.0",
                paired_fields=False,
            )
            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = binary_ab.Config(
                baseline_binary=baseline,
                candidate_binary=candidate,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                samples_per_variant=4,
                new_tokens=2,
                threads=1,
                bootstrap_resamples=100,
                parallel_attention_min_context=3,
            )
            with self.assertRaisesRegex(
                binary_ab.common.HarnessError,
                "current binary must emit native paired-MLP phase telemetry",
            ):
                binary_ab._observe(
                    config,
                    "candidate",
                    root / "candidate.ids",
                    [1, 2, 3],
                    binary_ab._fingerprints(config),
                )

    def test_parallel_candidate_must_prove_full_paired_mlp_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline"
            candidate = root / "candidate"
            self._write_parallel_binary(
                baseline,
                decode_ms="10.0",
                internal_ms="20.0",
                paired_fields=False,
            )
            self._write_parallel_binary(
                candidate,
                decode_ms="5.0",
                internal_ms="10.0",
                paired_coverage=False,
            )
            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = binary_ab.Config(
                baseline_binary=baseline,
                candidate_binary=candidate,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                samples_per_variant=4,
                new_tokens=2,
                threads=1,
                bootstrap_resamples=100,
                parallel_attention_min_context=3,
            )
            with self.assertRaisesRegex(
                binary_ab.common.HarnessError,
                "required paired MLP covered 0 graphs, expected 1",
            ):
                binary_ab._observe(
                    config,
                    "candidate",
                    root / "candidate.ids",
                    [1, 2, 3],
                    binary_ab._fingerprints(config),
                )

    def test_parallel_native_baseline_must_prove_full_paired_mlp_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline"
            candidate = root / "candidate"
            self._write_parallel_binary(
                baseline,
                decode_ms="10.0",
                internal_ms="20.0",
                paired_coverage=False,
            )
            self._write_parallel_binary(
                candidate,
                decode_ms="5.0",
                internal_ms="10.0",
            )
            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = binary_ab.Config(
                baseline_binary=baseline,
                candidate_binary=candidate,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                samples_per_variant=4,
                new_tokens=2,
                threads=1,
                bootstrap_resamples=100,
                parallel_attention_min_context=3,
            )
            with self.assertRaisesRegex(
                binary_ab.common.HarnessError,
                "required paired MLP covered 0 graphs, expected 1",
            ):
                binary_ab._observe(
                    config,
                    "baseline",
                    root / "baseline.ids",
                    [1, 2, 3],
                    binary_ab._fingerprints(config),
                )

    def test_sample_cap_is_enforced_before_pattern_construction(self):
        config = binary_ab.Config(
            baseline_binary=Path("baseline"),
            candidate_binary=Path("candidate"),
            model=Path("model.glrt"),
            ids=Path("prompt.ids"),
            output=None,
            cwd=Path.cwd(),
            samples_per_variant=10_004,
        )
        with mock.patch.object(binary_ab.common, "build_patterns") as build_patterns:
            with self.assertRaisesRegex(
                binary_ab.common.HarnessError,
                "samples per variant must not exceed 10000",
            ):
                binary_ab._validate(config)
        build_patterns.assert_not_called()


if __name__ == "__main__":
    unittest.main()
