import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "attention_ab.py"
SPEC = importlib.util.spec_from_file_location("attention_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
attention_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = attention_ab
SPEC.loader.exec_module(attention_ab)


def telemetry(
    *,
    policy: str,
    prompt_tokens: int = 3,
    decode_runs: int = 3,
    threshold: int = 5,
    layers: int = 4,
    graphs: int = 2,
    dispatches: int = 8,
    fused_graphs=None,
    fused_dispatches=None,
    paired_graphs=None,
    paired_dispatches=None,
) -> str:
    fused_graphs = graphs if fused_graphs is None else fused_graphs
    fused_dispatches = dispatches if fused_dispatches is None else fused_dispatches
    paired_graphs = graphs if paired_graphs is None else paired_graphs
    paired_dispatches = dispatches if paired_dispatches is None else paired_dispatches
    schedule = (
        f"schedule: attention=parallel min_context={threshold} layers={layers}"
        if policy == "parallel"
        else f"schedule: attention=serial layers={layers}"
    )
    return (
        "load: mode=prepared artifact=glrt ms=2.0\n"
        f"{schedule}\n"
        "ready: phase=request_ready ms=3.0\n"
        "phases: prefill_ms=4.0 decode_ms=10.0 sampling_ms=0.1 "
        f"decode_runs={decode_runs} attention_graphs={graphs} "
        f"attention_dispatches={dispatches} handoff_graphs={graphs} "
        f"handoff_dispatches={dispatches} fused_gqa_graphs={fused_graphs} "
        f"fused_gqa_dispatches={fused_dispatches} "
        f"paired_mlp_graphs={paired_graphs} "
        f"paired_mlp_dispatches={paired_dispatches}\n"
        f"time: 14.1 ms (283.7 tok/s, prefilled {prompt_tokens}, prefill=batch)\n"
    )


class AttentionAbTests(unittest.TestCase):
    def test_schedule_is_deterministic_and_balanced(self):
        first = attention_ab.build_patterns(20, 1234)
        self.assertEqual(first, attention_ab.build_patterns(20, 1234))
        self.assertEqual(len(first), 10)
        self.assertEqual(first.count("ABBA"), 5)
        self.assertEqual(first.count("BAAB"), 5)
        with self.assertRaises(attention_ab.HarnessError):
            attention_ab.build_patterns(6, 1234)

    def test_token_ids_are_canonical_and_bounded(self):
        self.assertEqual(attention_ab.parse_ids(b"1 2\n13\n", "ids"), [1, 2, 13])
        for invalid in (b"", b"01\n", b"-1\n", b"4294967296\n", b"1.0\n"):
            with self.subTest(invalid=invalid):
                with self.assertRaises(attention_ab.HarnessError):
                    attention_ab.parse_ids(invalid, "ids")

    def test_parser_enforces_late_threshold_graphs_and_layer_dispatches(self):
        parallel = attention_ab.parse_telemetry(
            telemetry(policy="parallel"),
            variant="parallel",
            prompt_tokens=3,
            new_tokens=4,
            threshold=5,
        )
        self.assertEqual(parallel["decode_runs"], 3)
        self.assertEqual(parallel["parallel_attention_graphs"], 2)
        self.assertEqual(parallel["parallel_attention_dispatches"], 8)
        self.assertEqual(parallel["handoff_graphs"], 2)
        self.assertEqual(parallel["handoff_dispatches"], 8)
        self.assertEqual(parallel["fused_gqa_graphs"], 2)
        self.assertEqual(parallel["fused_gqa_dispatches"], 8)
        self.assertEqual(parallel["paired_mlp_graphs"], 2)
        self.assertEqual(parallel["paired_mlp_dispatches"], 8)
        self.assertEqual(parallel["attention_layers"], 4)

        serial = attention_ab.parse_telemetry(
            telemetry(policy="serial", graphs=0, dispatches=0),
            variant="serial",
            prompt_tokens=3,
            new_tokens=4,
            threshold=5,
        )
        self.assertEqual(serial["parallel_attention_graphs"], 0)
        self.assertEqual(serial["parallel_attention_dispatches"], 0)
        self.assertEqual(serial["fused_gqa_graphs"], 0)
        self.assertEqual(serial["fused_gqa_dispatches"], 0)
        self.assertEqual(serial["paired_mlp_graphs"], 0)
        self.assertEqual(serial["paired_mlp_dispatches"], 0)

        with self.assertRaisesRegex(attention_ab.HarnessError, "expected 2"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", graphs=3, dispatches=12),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        with self.assertRaisesRegex(attention_ab.HarnessError, "expected 8"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", dispatches=7),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        with self.assertRaisesRegex(attention_ab.HarnessError, "fused GQA.*zero or 2"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", fused_graphs=1),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        with self.assertRaisesRegex(attention_ab.HarnessError, "fused GQA.*expected 8"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", fused_dispatches=7),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        with self.assertRaisesRegex(attention_ab.HarnessError, "paired MLP.*zero or 2"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", paired_graphs=1),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        with self.assertRaisesRegex(attention_ab.HarnessError, "paired MLP.*expected 8"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", paired_dispatches=7),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        unfused = attention_ab.parse_telemetry(
            telemetry(policy="parallel", fused_graphs=0, fused_dispatches=0),
            variant="parallel",
            prompt_tokens=3,
            new_tokens=4,
            threshold=5,
        )
        self.assertEqual(unfused["fused_gqa_graphs"], 0)
        with self.assertRaisesRegex(attention_ab.HarnessError, "required fused GQA"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", fused_graphs=0, fused_dispatches=0),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
                require_fused_gqa=True,
            )
        unpaired = attention_ab.parse_telemetry(
            telemetry(policy="parallel", paired_graphs=0, paired_dispatches=0),
            variant="parallel",
            prompt_tokens=3,
            new_tokens=4,
            threshold=5,
        )
        self.assertEqual(unpaired["paired_mlp_graphs"], 0)
        with self.assertRaisesRegex(attention_ab.HarnessError, "required paired MLP"):
            attention_ab.parse_telemetry(
                telemetry(policy="parallel", paired_graphs=0, paired_dispatches=0),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
                require_paired_mlp=True,
            )
        with self.assertRaisesRegex(attention_ab.HarnessError, "no eligible"):
            attention_ab.parse_telemetry(
                telemetry(
                    policy="parallel",
                    threshold=99,
                    graphs=0,
                    dispatches=0,
                    fused_graphs=0,
                    fused_dispatches=0,
                ),
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=99,
                require_fused_gqa=True,
            )

    def test_duplicate_and_nonfinite_telemetry_fail_closed(self):
        valid = telemetry(policy="parallel")
        with self.assertRaisesRegex(attention_ab.HarnessError, "duplicated"):
            attention_ab.parse_telemetry(
                valid + "schedule: attention=parallel min_context=5 layers=4\n",
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        nonfinite = valid.replace("prefill_ms=4.0", "prefill_ms=nan")
        with self.assertRaisesRegex(attention_ab.HarnessError, "malformed"):
            attention_ab.parse_telemetry(
                nonfinite,
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )
        missing_paired = valid.replace(
            " paired_mlp_graphs=2 paired_mlp_dispatches=8", ""
        )
        with self.assertRaisesRegex(attention_ab.HarnessError, "malformed"):
            attention_ab.parse_telemetry(
                missing_paired,
                variant="parallel",
                prompt_tokens=3,
                new_tokens=4,
                threshold=5,
            )

    def test_paired_bootstrap_is_deterministic(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                variant = "parallel" if letter == "A" else "serial"
                samples.append(
                    {
                        "block_index": block_index,
                        "variant": variant,
                        "metrics": {
                            "decode_ms": 5.0 if variant == "parallel" else 10.0
                        },
                    }
                )
        first = attention_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = attention_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["estimate"], 2.0)
        self.assertEqual(first["ci_low"], 2.0)
        self.assertEqual(first["ci_high"], 2.0)

    def test_lightweight_end_to_end_run_hashes_artifacts_and_exact_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "fake-glacier"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib,sys\n"
                "a=sys.argv\n"
                "out=pathlib.Path(a[a.index('--out-ids-file')+1])\n"
                "prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())\n"
                "tokens=int(a[a.index('--n')+1]); runs=max(0,tokens-1); layers=4\n"
                "parallel='--parallel-attention-min-context' in a\n"
                "threshold=int(a[a.index('--parallel-attention-min-context')+1]) if parallel else None\n"
                "graphs=min(runs,max(0,prompt+runs-threshold+1)) if parallel else 0\n"
                "dispatches=graphs*layers\n"
                "out.write_text(' '.join(str(7+i) for i in range(tokens))+'\\n')\n"
                "print('load: mode=prepared artifact=glrt ms=1.0')\n"
                'print(f"schedule: attention=parallel min_context={threshold} layers={layers}" if parallel else f"schedule: attention=serial layers={layers}")\n'
                "print('ready: phase=request_ready ms=2.0')\n"
                "print(f'phases: prefill_ms=3.0 decode_ms=4.0 sampling_ms=0.1 decode_runs={runs} attention_graphs={graphs} attention_dispatches={dispatches} handoff_graphs={graphs} handoff_dispatches={dispatches} fused_gqa_graphs={graphs} fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} paired_mlp_dispatches={dispatches}')\n"
                "print(f'time: 7.1 ms (281.7 tok/s, prefilled {prompt}, prefill=batch)')\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = attention_ab.Config(
                binary=binary,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                threshold=4,
                samples_per_variant=4,
                warmups_per_variant=1,
                new_tokens=2,
                threads=1,
                schedule_seed=7,
                bootstrap_seed=11,
                bootstrap_resamples=100,
            )
            result = attention_ab.run_benchmark(config)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmups"]), 2)
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["completion_equivalence"]["distinct_normalized_hashes"],
                [attention_ab.sha256_bytes(b"7 8\n")],
            )
            for name in result["artifacts_before"]:
                self.assertEqual(
                    result["artifacts_before"][name]["sha256"],
                    result["artifacts_after"][name]["sha256"],
                )
            self.assertEqual(
                result["serial_over_parallel"]["decode_ms"]["estimate"], 1.0
            )
            json.dumps(result, allow_nan=False)

    def test_finite_json_and_output_replacement_are_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "result.json"
            with self.assertRaises(ValueError):
                attention_ab.write_result({"bad": float("nan")}, output, False)
            self.assertFalse(output.exists())
            output.write_text("preserve", encoding="utf-8")
            with self.assertRaises(attention_ab.HarnessError):
                attention_ab.write_result({"ok": True}, output, False)
            self.assertEqual(output.read_text(encoding="utf-8"), "preserve")

            binary = root / "glacier"
            model = root / "model.glrt"
            ids = root / "prompt.ids"
            for path in (binary, model, ids):
                path.write_bytes(b"input")
            with self.assertRaisesRegex(attention_ab.HarnessError, "must not replace"):
                attention_ab.validate_config(
                    attention_ab.Config(
                        binary=binary,
                        model=model,
                        ids=ids,
                        output=model,
                        cwd=root,
                        threshold=4,
                    )
                )


if __name__ == "__main__":
    unittest.main()
