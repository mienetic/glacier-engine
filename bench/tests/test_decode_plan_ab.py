from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "decode_plan_ab.py"
SPEC = importlib.util.spec_from_file_location("decode_plan_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
decode_plan_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = decode_plan_ab
SPEC.loader.exec_module(decode_plan_ab)


def telemetry(
    *,
    mode: str,
    prompt_tokens: int = 3,
    decode_runs: int = 3,
    threshold: int = 4,
    layers: int = 4,
    graphs: int = 3,
    dispatches: int = 12,
    sets: int | None = None,
    set_bytes: int | None = None,
    builds: int | None = None,
    binds: int | None = None,
    checked_dispatches: int | None = None,
    sealed_dispatches: int | None = None,
    fallbacks: int = 0,
    rejects: int = 0,
    build_ms: str | None = None,
    abi: str = "4753485000000004",
) -> str:
    sealed = mode == "sealed-required"
    sets = (1 if sealed else 0) if sets is None else sets
    set_bytes = (4096 if sealed else 0) if set_bytes is None else set_bytes
    builds = (layers if sealed else 0) if builds is None else builds
    binds = (layers if sealed else 0) if binds is None else binds
    checked_dispatches = (
        (0 if sealed else dispatches)
        if checked_dispatches is None
        else checked_dispatches
    )
    sealed_dispatches = (
        (dispatches if sealed else 0)
        if sealed_dispatches is None
        else sealed_dispatches
    )
    build_ms = ("0.250" if sealed else "0.000") if build_ms is None else build_ms
    return (
        "load: mode=prepared artifact=glrt ms=2.0\n"
        f"schedule: attention=parallel min_context={threshold} layers={layers}\n"
        "ready: phase=request_ready ms=3.0\n"
        "phases: prefill_ms=4.0 decode_ms=10.0 sampling_ms=0.1 "
        f"decode_runs={decode_runs} attention_graphs={graphs} "
        f"attention_dispatches={dispatches} handoff_graphs={graphs} "
        f"handoff_dispatches={dispatches} fused_gqa_graphs={graphs} "
        f"fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} "
        f"paired_mlp_dispatches={dispatches}\n"
        f"decode_plan: mode={mode} sets={sets} set_bytes={set_bytes} layer_builds={builds} "
        f"layer_binds={binds} checked_dispatches={checked_dispatches} "
        f"sealed_dispatches={sealed_dispatches} fallbacks={fallbacks} "
        f"rejects={rejects} build_ms={build_ms} abi={abi}\n"
        f"time: 14.1 ms (283.7 tok/s, prefilled {prompt_tokens}, prefill=batch)\n"
    )


def write_fake_glacier(root: Path, *, divergent_output: bool = False) -> Path:
    binary = root / "fake-glacier"
    divergent = "True" if divergent_output else "False"
    binary.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib,sys\n"
        "a=sys.argv\n"
        "out=pathlib.Path(a[a.index('--out-ids-file')+1])\n"
        "prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())\n"
        "tokens=int(a[a.index('--n')+1]); runs=max(0,tokens-1); layers=4\n"
        "threshold=int(a[a.index('--parallel-attention-min-context')+1])\n"
        "mode=a[a.index('--decode-plan')+1]\n"
        "graphs=min(runs,max(0,prompt+runs-threshold+1))\n"
        "dispatches=graphs*layers; sealed=mode=='sealed-required'\n"
        f"divergent={divergent}\n"
        "start=8 if divergent and sealed else 7\n"
        "out.write_text(' '.join(str(start+i) for i in range(tokens))+'\\n')\n"
        "print('load: mode=prepared artifact=glrt ms=1.0')\n"
        "print(f'schedule: attention=parallel min_context={threshold} layers={layers}')\n"
        "print('ready: phase=request_ready ms=2.0')\n"
        "print(f'phases: prefill_ms=3.0 decode_ms=4.0 sampling_ms=0.1 decode_runs={runs} attention_graphs={graphs} attention_dispatches={dispatches} handoff_graphs={graphs} handoff_dispatches={dispatches} fused_gqa_graphs={graphs} fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} paired_mlp_dispatches={dispatches}')\n"
        "sets=1 if sealed else 0; set_bytes=4096 if sealed else 0; builds=layers if sealed else 0; binds=builds\n"
        "checked=0 if sealed else dispatches; sealed_count=dispatches if sealed else 0\n"
        "build_ms='0.250' if sealed else '0.000'\n"
        "print(f'decode_plan: mode={mode} sets={sets} set_bytes={set_bytes} layer_builds={builds} layer_binds={binds} checked_dispatches={checked} sealed_dispatches={sealed_count} fallbacks=0 rejects=0 build_ms={build_ms} abi=4753485000000004')\n"
        "print(f'time: 7.1 ms (281.7 tok/s, prefilled {prompt}, prefill=batch)')\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    return binary


class DecodePlanAbTests(unittest.TestCase):
    def test_defaults_are_p176_n64_and_balanced(self):
        args = decode_plan_ab.argument_parser().parse_args(
            ["--binary", "glacier", "--model", "model.glrt", "--output", "-"]
        )
        self.assertEqual(args.ids.name, "eval-qwen2.5.ids")
        self.assertEqual(args.new_tokens, 64)
        self.assertEqual(args.threshold, 128)
        self.assertEqual(args.samples_per_variant, 32)
        self.assertEqual(args.warmups_per_variant, 2)
        patterns = decode_plan_ab.build_patterns(args.samples_per_variant, 1234)
        self.assertEqual(len(patterns), 16)
        self.assertEqual(patterns.count("ABBA"), 8)
        self.assertEqual(patterns.count("BAAB"), 8)
        self.assertEqual(patterns, decode_plan_ab.build_patterns(32, 1234))

    def test_exact_decode_plan_and_stable_phase_telemetry(self):
        checked = decode_plan_ab.parse_telemetry(
            telemetry(mode="checked"),
            variant="checked",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        self.assertEqual(checked["decode_plan_sets"], 0)
        self.assertEqual(checked["decode_plan_checked_dispatches"], 12)
        self.assertEqual(checked["decode_plan_sealed_dispatches"], 0)
        self.assertEqual(checked["decode_plan_build_ms"], 0.0)

        sealed = decode_plan_ab.parse_telemetry(
            telemetry(mode="sealed-required"),
            variant="sealed-required",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        self.assertEqual(sealed["decode_plan_sets"], 1)
        self.assertEqual(sealed["decode_plan_layer_builds"], 4)
        self.assertEqual(sealed["decode_plan_layer_binds"], 4)
        self.assertEqual(sealed["decode_plan_sealed_dispatches"], 12)
        self.assertEqual(sealed["decode_plan_abi"], "4753485000000004")

        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "mode was"):
            decode_plan_ab.parse_telemetry(
                telemetry(mode="checked"),
                variant="sealed-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "counters"):
            decode_plan_ab.parse_telemetry(
                telemetry(mode="sealed-required", sealed_dispatches=11),
                variant="sealed-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "fallbacks/rejects"):
            decode_plan_ab.parse_telemetry(
                telemetry(mode="sealed-required", fallbacks=1),
                variant="sealed-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )

    def test_duplicate_malformed_or_drifted_telemetry_fails_closed(self):
        valid = telemetry(mode="sealed-required")
        duplicate = valid + valid.splitlines()[4] + "\n"
        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "duplicated"):
            decode_plan_ab.parse_telemetry(
                duplicate,
                variant="sealed-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        malformed = valid.replace(" abi=4753485000000004", " abi=0x4753485000000004")
        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "malformed"):
            decode_plan_ab.parse_telemetry(
                malformed,
                variant="sealed-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        drifted_phase = valid.replace(
            " paired_mlp_dispatches=12\n", " paired_mlp_dispatches=12 extra=1\n"
        )
        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "malformed"):
            decode_plan_ab.parse_telemetry(
                drifted_phase,
                variant="sealed-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )

    def test_commands_hold_binary_and_policy_constant(self):
        config = decode_plan_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        checked = decode_plan_ab.build_command(config, "checked", Path("/tmp/out.ids"))
        sealed = decode_plan_ab.build_command(
            config, "sealed-required", Path("/tmp/out.ids")
        )
        self.assertEqual(checked[0], sealed[0])
        self.assertIn("--parallel-attention-min-context", checked)
        self.assertIn("--require-batch-prefill", checked)
        self.assertIn("--require-prepared-image", checked)
        plan_index = checked.index("--decode-plan")
        self.assertEqual(checked[plan_index + 1], "checked")
        self.assertEqual(sealed[plan_index + 1], "sealed-required")
        normalized = list(sealed)
        normalized[plan_index + 1] = "checked"
        self.assertEqual(checked, normalized)

    def test_strict_harness_rejects_single_thread_configuration(self):
        config = decode_plan_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
            threads=1,
        )
        with self.assertRaisesRegex(decode_plan_ab.HarnessError, "at least 2|\[2"):
            decode_plan_ab.validate_config(config)

    def test_checked_over_sealed_bootstrap_is_deterministic(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                variant = "sealed-required" if letter == "A" else "checked"
                samples.append(
                    {
                        "block_index": block_index,
                        "variant": variant,
                        "metrics": {
                            "decode_ms": 5.0 if variant == "sealed-required" else 10.0
                        },
                    }
                )
        first = decode_plan_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = decode_plan_ab.paired_ratio(
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
        self.assertTrue(first["direction"].startswith("checked_over_sealed"))

    def test_lightweight_end_to_end_manifest_and_exact_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = write_fake_glacier(root)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = decode_plan_ab.Config(
                binary=binary,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                threshold=4,
                samples_per_variant=4,
                warmups_per_variant=1,
                new_tokens=2,
                threads=2,
                schedule_seed=7,
                bootstrap_seed=11,
                bootstrap_resamples=100,
            )
            result = decode_plan_ab.run_benchmark(config)
            self.assertEqual(result["schema"], decode_plan_ab.SCHEMA)
            self.assertEqual(result["status"], "evidence-valid")
            self.assertEqual(result["promotion_gates"]["latency"]["status"], "failed")
            self.assertEqual(result["promotion_gates"]["overall_status"], "failed")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmups"]), 2)
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["completion_equivalence"]["distinct_normalized_hashes"],
                [decode_plan_ab.sha256_bytes(b"7 8\n")],
            )
            contract = result["contract"]
            self.assertTrue(contract["same_binary_required"])
            self.assertEqual(contract["letter_mapping"]["A"], "sealed-required")
            self.assertEqual(contract["letter_mapping"]["B"], "checked")
            self.assertEqual(contract["expected_plan_dispatches_per_variant"], 4)
            self.assertEqual(
                len(set(contract["binary_sha256_by_variant"].values())), 1
            )
            self.assertEqual(
                result["checked_over_sealed"]["decode_ms"]["estimate"], 1.0
            )
            for name in result["artifacts_before"]:
                self.assertEqual(
                    result["artifacts_before"][name]["sha256"],
                    result["artifacts_after"][name]["sha256"],
                )
            json.dumps(result, allow_nan=False)

    def test_output_divergence_fails_before_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = write_fake_glacier(root, divergent_output=True)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = decode_plan_ab.Config(
                binary=binary,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                threshold=4,
                samples_per_variant=4,
                warmups_per_variant=1,
                new_tokens=2,
                threads=2,
                schedule_seed=7,
                bootstrap_resamples=100,
            )
            with self.assertRaisesRegex(decode_plan_ab.HarnessError, "exact completion"):
                decode_plan_ab.run_benchmark(config)


if __name__ == "__main__":
    unittest.main()
