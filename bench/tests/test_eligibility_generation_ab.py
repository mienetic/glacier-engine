from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "eligibility_generation_ab.py"
SPEC = importlib.util.spec_from_file_location("eligibility_generation_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
eligibility_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = eligibility_ab
SPEC.loader.exec_module(eligibility_ab)


def telemetry(
    *,
    mode: str,
    domain: str = "rotating64-v1",
    prompt_tokens: int = 3,
    new_tokens: int = 4,
    vocab: int = 128,
    threshold: int = 4,
    layers: int = 4,
    producer_rows_per_head: int = 64,
    fallbacks: int = 0,
    rejects: int = 0,
    greedy_abi: str = "474c4d4800000002",
    provider_abi: str = "474c564300000001",
    executor_abi: str = "474c564900000001",
    policy_sha256: str = "1" * 64,
    last_mask_sha256: str = "2" * 64,
    trace_sha256: str = "3" * 64,
) -> str:
    prehead = mode == "domain-prehead-required"
    assert prehead or mode == "domain-posthead-required"
    decode_runs = new_tokens - 1
    graphs = decode_runs
    dispatches = graphs * layers
    eligible_rows = new_tokens * 64
    producer_rows = new_tokens * producer_rows_per_head if prehead else 0
    skipped_rows = new_tokens * vocab - producer_rows if prehead else 0
    overcomputed_rows = producer_rows - eligible_rows if prehead else 0
    producer_runs = new_tokens if prehead else 0
    materialized = 0 if prehead else new_tokens
    logitless = new_tokens if prehead else 0
    scratch = 32 if prehead else 0
    logits_bytes = 0 if prehead else vocab * 4
    posthead = 0 if prehead else new_tokens
    prehead_count = new_tokens if prehead else 0
    materialized_dot = 0 if prehead else new_tokens * vocab
    full_rows = 0 if prehead else new_tokens * vocab
    full_peak = 0 if prehead else vocab * 4
    candidate_bytes = 32 if prehead else 0
    tile_scratch = 1024 if prehead else 0
    eligible_mode = "prehead-required" if prehead else "posthead-required"
    decode_ms = "5.000" if prehead else "10.000"
    internal_ms = "9.100" if prehead else "14.100"
    return (
        "load: mode=prepared artifact=glrt ms=2.0\n"
        f"schedule: attention=parallel min_context={threshold} layers={layers}\n"
        "ready: phase=request_ready ms=3.0\n"
        f"phases: prefill_ms=4.0 decode_ms={decode_ms} sampling_ms=0.1 "
        f"decode_runs={decode_runs} attention_graphs={graphs} "
        f"attention_dispatches={dispatches} handoff_graphs={graphs} "
        f"handoff_dispatches={dispatches} fused_gqa_graphs={graphs} "
        f"fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} "
        f"paired_mlp_dispatches={dispatches}\n"
        f"greedy_output: mode={mode} materialized_projections={materialized} "
        f"logitless_projections={logitless} producer_rows={producer_rows} "
        "tile_output_bytes=0 argmax_scan_rows=0 "
        f"scratch_bytes={scratch} materialized_logits_bytes={logits_bytes} "
        "steady_state_reclaimed_bytes=0 "
        f"fallbacks={fallbacks} rejects={rejects} abi={greedy_abi}\n"
        f"eligible_vocab: mode={eligible_mode} domain={domain} "
        f"provider_calls={new_tokens} certificates={new_tokens} "
        f"posthead_projections={posthead} prehead_projections={prehead_count} "
        f"eligible_rows={eligible_rows} materialized_dot_rows={materialized_dot} "
        f"producer_rows={producer_rows} skipped_rows={skipped_rows} "
        f"overcomputed_rows={overcomputed_rows} producer_runs={producer_runs} "
        f"full_logits_rows_written={full_rows} full_logits_peak_bytes={full_peak} "
        f"staging_mask_bytes={((vocab + 63) // 64) * 8} "
        f"sealed_mask_bytes={((vocab + 63) // 64) * 8} "
        f"executor_candidate_bytes={candidate_bytes} "
        f"executor_tile_scratch_bytes={tile_scratch} "
        f"provider_ms=0.004 verification_ms=0.003 published_tokens={new_tokens} "
        f"fallbacks={fallbacks} rejects={rejects} "
        f"policy_sha256={policy_sha256} last_mask_sha256={last_mask_sha256} "
        f"trace_sha256={trace_sha256} provider_abi={provider_abi} "
        f"executor_abi={executor_abi}\n"
        f"time: {internal_ms} ms (283.7 tok/s, prefilled {prompt_tokens}, "
        "prefill=batch)\n"
    )


def write_fake_glacier(
    root: Path,
    *,
    divergent_output: bool = False,
    divergent_trace: bool = False,
) -> Path:
    binary = root / "fake-glacier"
    binary.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib,sys\n"
        "a=sys.argv\n"
        "required=['--require-batch-prefill','--require-prepared-image']\n"
        "assert all(flag in a for flag in required)\n"
        "assert a[a.index('--temp')+1]=='0'\n"
        "assert a[a.index('--decode-plan')+1]=='checked'\n"
        "assert a[a.index('--eligible-domain')+1] in "
        "('rotating64-v1','static64-v1')\n"
        f"divergent_output={divergent_output!r}\n"
        f"divergent_trace={divergent_trace!r}\n"
        "out=pathlib.Path(a[a.index('--out-ids-file')+1])\n"
        "prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())\n"
        "tokens=int(a[a.index('--n')+1]); runs=tokens-1; layers=4; vocab=128\n"
        "threshold=int(a[a.index('--parallel-attention-min-context')+1])\n"
        "mode=a[a.index('--greedy-output')+1]; pre=mode=='domain-prehead-required'\n"
        "domain=a[a.index('--eligible-domain')+1]\n"
        "graphs=min(runs,max(0,prompt+runs-threshold+1)); dispatches=graphs*layers\n"
        "start=8 if divergent_output and pre else 7\n"
        "out.write_text(' '.join(str(start+i) for i in range(tokens))+'\\n')\n"
        "print('load: mode=prepared artifact=glrt ms=1.0')\n"
        "print(f'schedule: attention=parallel min_context={threshold} layers={layers}')\n"
        "print('ready: phase=request_ready ms=2.0')\n"
        "decode_ms='5.000' if pre else '10.000'\n"
        "print(f'phases: prefill_ms=3.0 decode_ms={decode_ms} sampling_ms=0.1 "
        "decode_runs={runs} attention_graphs={graphs} attention_dispatches={dispatches} "
        "handoff_graphs={graphs} handoff_dispatches={dispatches} "
        "fused_gqa_graphs={graphs} fused_gqa_dispatches={dispatches} "
        "paired_mlp_graphs={graphs} paired_mlp_dispatches={dispatches}')\n"
        "producer=tokens*64 if pre else 0; skipped=tokens*vocab-producer if pre else 0\n"
        "materialized=0 if pre else tokens; logitless=tokens if pre else 0\n"
        "scratch=32 if pre else 0; logits=0 if pre else vocab*4\n"
        "print(f'greedy_output: mode={mode} materialized_projections={materialized} "
        "logitless_projections={logitless} producer_rows={producer} "
        "tile_output_bytes=0 argmax_scan_rows=0 scratch_bytes={scratch} "
        "materialized_logits_bytes={logits} steady_state_reclaimed_bytes=0 "
        "fallbacks=0 rejects=0 abi=474c4d4800000002')\n"
        "eligible_mode='prehead-required' if pre else 'posthead-required'\n"
        "post=0 if pre else tokens; pre_count=tokens if pre else 0\n"
        "matdot=0 if pre else tokens*vocab; over=0; pruns=tokens if pre else 0\n"
        "fullrows=0 if pre else tokens*vocab; fullpeak=0 if pre else vocab*4\n"
        "candidate=32 if pre else 0; tile=1024 if pre else 0\n"
        "trace=('4' if divergent_trace and pre else '3')*64\n"
        "policy='1'*64; mask_hash='2'*64\n"
        "print(f'eligible_vocab: mode={eligible_mode} domain={domain} "
        "provider_calls={tokens} certificates={tokens} posthead_projections={post} "
        "prehead_projections={pre_count} eligible_rows={tokens*64} "
        "materialized_dot_rows={matdot} producer_rows={producer} "
        "skipped_rows={skipped} overcomputed_rows={over} producer_runs={pruns} "
        "full_logits_rows_written={fullrows} full_logits_peak_bytes={fullpeak} "
        "staging_mask_bytes=16 sealed_mask_bytes=16 "
        "executor_candidate_bytes={candidate} executor_tile_scratch_bytes={tile} "
        "provider_ms=0.004 verification_ms=0.003 published_tokens={tokens} "
        "fallbacks=0 rejects=0 policy_sha256={policy} last_mask_sha256={mask_hash} "
        "trace_sha256={trace} provider_abi=474c564300000001 "
        "executor_abi=474c564900000001')\n"
        "internal='9.100' if pre else '14.100'\n"
        "print(f'time: {internal} ms (281.7 tok/s, prefilled {prompt}, prefill=batch)')\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    return binary


class EligibilityGenerationAbTests(unittest.TestCase):
    def test_defaults_and_balanced_full_blocks(self):
        args = eligibility_ab.argument_parser().parse_args(
            ["--binary", "glacier", "--model", "model.glrt", "--output", "-"]
        )
        self.assertEqual(args.eligible_domain, "rotating64-v1")
        self.assertEqual(args.new_tokens, 64)
        self.assertEqual(args.samples_per_variant, 32)
        patterns = eligibility_ab.build_patterns(32, 1234)
        self.assertEqual(len(patterns), 16)
        self.assertEqual(patterns.count("ABBA"), 8)
        self.assertEqual(patterns.count("BAAB"), 8)
        self.assertEqual(patterns, eligibility_ab.build_patterns(32, 1234))

    def test_exact_posthead_and_prehead_arithmetic(self):
        post = eligibility_ab.parse_telemetry(
            telemetry(mode="domain-posthead-required"),
            variant="domain-posthead-required",
            domain="rotating64-v1",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        self.assertEqual(post["eligible_vocabulary_rows"], 128)
        self.assertEqual(post["eligible_materialized_dot_rows"], 512)
        self.assertEqual(post["eligible_full_logits_rows_written"], 512)
        self.assertEqual(post["greedy_materialized_logits_bytes"], 512)

        pre = eligibility_ab.parse_telemetry(
            telemetry(mode="domain-prehead-required"),
            variant="domain-prehead-required",
            domain="rotating64-v1",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        self.assertEqual(pre["eligible_vocabulary_rows"], 128)
        self.assertEqual(pre["eligible_producer_rows"], 256)
        self.assertEqual(pre["eligible_skipped_rows"], 256)
        self.assertEqual(pre["eligible_full_logits_rows_written"], 0)
        self.assertEqual(pre["eligible_full_logits_peak_bytes"], 0)
        self.assertEqual(pre["greedy_materialized_projections"], 0)
        self.assertEqual(pre["greedy_materialized_logits_bytes"], 0)
        self.assertEqual(pre["eligible_executor_candidate_bytes"], 32)
        self.assertEqual(pre["eligible_executor_tile_scratch_bytes"], 1024)

    def test_malformed_duplicate_and_bad_arithmetic_fail_closed(self):
        valid = telemetry(mode="domain-prehead-required")
        eligible_line = next(
            line for line in valid.splitlines() if line.startswith("eligible_vocab:")
        )
        with self.assertRaisesRegex(eligibility_ab.HarnessError, "duplicated"):
            eligibility_ab.parse_telemetry(
                valid + eligible_line + "\n",
                variant="domain-prehead-required",
                domain="rotating64-v1",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(
            eligibility_ab.HarnessError, "divide into N heads|N times vocabulary"
        ):
            eligibility_ab.parse_telemetry(
                valid.replace("skipped_rows=256", "skipped_rows=255"),
                variant="domain-prehead-required",
                domain="rotating64-v1",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(eligibility_ab.HarnessError, "counters"):
            eligibility_ab.parse_telemetry(
                valid.replace(
                    "materialized_logits_bytes=0", "materialized_logits_bytes=4"
                ),
                variant="domain-prehead-required",
                domain="rotating64-v1",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )

    def test_reject_fallback_domain_or_abi_drift(self):
        kwargs = dict(
            variant="domain-posthead-required",
            domain="rotating64-v1",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        with self.assertRaisesRegex(eligibility_ab.HarnessError, "fallbacks/rejects"):
            eligibility_ab.parse_telemetry(
                telemetry(mode="domain-posthead-required", fallbacks=1), **kwargs
            )
        with self.assertRaisesRegex(eligibility_ab.HarnessError, "eligible domain was"):
            eligibility_ab.parse_telemetry(
                telemetry(mode="domain-posthead-required", domain="static64-v1"),
                **kwargs,
            )
        with self.assertRaisesRegex(eligibility_ab.HarnessError, "provider.*ABI was"):
            eligibility_ab.parse_telemetry(
                telemetry(
                    mode="domain-posthead-required",
                    provider_abi="474c564300000002",
                ),
                **kwargs,
            )

    def test_commands_hold_every_option_except_output_policy_constant(self):
        config = eligibility_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
            domain="static64-v1",
        )
        output = Path("/tmp/completion.ids")
        post = eligibility_ab.build_command(config, eligibility_ab.VARIANTS[0], output)
        pre = eligibility_ab.build_command(config, eligibility_ab.VARIANTS[1], output)
        self.assertIn("--require-batch-prefill", post)
        self.assertIn("--require-prepared-image", post)
        self.assertEqual(post[post.index("--eligible-domain") + 1], "static64-v1")
        policy_index = post.index("--greedy-output")
        normalized = list(pre)
        normalized[policy_index + 1] = eligibility_ab.VARIANTS[0]
        self.assertEqual(post, normalized)

    def test_full_block_bootstrap_is_deterministic(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                variant = (
                    "domain-prehead-required"
                    if letter == "A"
                    else "domain-posthead-required"
                )
                samples.append(
                    {
                        "block_index": block_index,
                        "variant": variant,
                        "metrics": {"decode_ms": 5.0 if letter == "A" else 10.0},
                    }
                )
        first = eligibility_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = eligibility_ab.paired_ratio(
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
        self.assertEqual(
            first["bootstrap_unit"], "complete_balanced_abba_or_baab_block"
        )

    def test_lightweight_end_to_end_manifest_equivalence_and_geometry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = write_fake_glacier(root)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = eligibility_ab.Config(
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
            result = eligibility_ab.run_benchmark(config)
            self.assertEqual(result["schema"], eligibility_ab.SCHEMA)
            self.assertEqual(result["status"], "evidence-valid")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmups"]), 2)
            self.assertTrue(
                all(not item["included_in_statistics"] for item in result["warmups"])
            )
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            contract = result["contract"]
            self.assertEqual(contract["vocabulary_rows"], 128)
            self.assertTrue(contract["vocabulary_source"].startswith("posthead"))
            self.assertTrue(contract["zero_prehead_full_logits_required"])
            self.assertEqual(
                contract["letter_mapping"]["A"], eligibility_ab.VARIANTS[1]
            )
            self.assertEqual(
                contract["letter_mapping"]["B"], eligibility_ab.VARIANTS[0]
            )
            self.assertEqual(
                result["posthead_over_prehead"]["decode_ms"]["estimate"], 2.0
            )
            self.assertEqual(
                len(result["source_manifest_before"]), len(eligibility_ab.SOURCE_PATHS)
            )
            for before_name, before in result["artifacts_before"].items():
                self.assertEqual(
                    before["sha256"], result["artifacts_after"][before_name]["sha256"]
                )
            for source_name, before in result["source_manifest_before"].items():
                self.assertEqual(
                    before["sha256"],
                    result["source_manifest_after"][source_name]["sha256"],
                )
            normalized_commands = []
            for item in [*result["warmups"], *result["samples"]]:
                command = list(item["argv"])
                command[command.index("--greedy-output") + 1] = eligibility_ab.VARIANTS[
                    0
                ]
                normalized_commands.append(tuple(command))
            self.assertEqual(len(set(normalized_commands)), 1)
            json.dumps(result, allow_nan=False)

    def test_output_or_trace_divergence_fails_before_result(self):
        for option, expected in (
            ({"divergent_output": True}, "exact completion IDs"),
            ({"divergent_trace": True}, "policy/mask trace/ABI"),
        ):
            with (
                self.subTest(option=option),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                binary = write_fake_glacier(root, **option)
                model = root / "model.glrt"
                model.write_bytes(b"test glrt")
                ids = root / "prompt.ids"
                ids.write_text("1 2 3\n", encoding="ascii")
                config = eligibility_ab.Config(
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
                    bootstrap_resamples=100,
                )
                with self.assertRaisesRegex(eligibility_ab.HarnessError, expected):
                    eligibility_ab.run_benchmark(config)

    def test_atomic_publication_refuses_overwrite_without_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result.json"
            eligibility_ab.write_result({"generation": 1}, output, overwrite=False)
            with self.assertRaisesRegex(eligibility_ab.HarnessError, "refusing"):
                eligibility_ab.write_result({"generation": 2}, output, overwrite=False)
            self.assertEqual(json.loads(output.read_text())["generation"], 1)
            self.assertEqual(list(output.parent.glob(f".{output.name}.*")), [])
            eligibility_ab.write_result({"generation": 3}, output, overwrite=True)
            self.assertEqual(json.loads(output.read_text())["generation"], 3)


if __name__ == "__main__":
    unittest.main()
