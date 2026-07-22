from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "greedy_output_ab.py"
SPEC = importlib.util.spec_from_file_location("greedy_output_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
greedy_output_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = greedy_output_ab
SPEC.loader.exec_module(greedy_output_ab)


def telemetry(
    *,
    mode: str,
    prompt_tokens: int = 3,
    new_tokens: int = 4,
    decode_runs: int = 3,
    threshold: int = 4,
    layers: int = 4,
    graphs: int = 3,
    materialized: int | None = None,
    logitless: int | None = None,
    producer_rows: int | None = None,
    tile_output_bytes: int = 0,
    argmax_scan_rows: int = 0,
    scratch_bytes: int | None = None,
    materialized_logits_bytes: int = 607_744,
    reclaimed_bytes: int | None = None,
    fallbacks: int = 0,
    rejects: int = 0,
    abi: str = "474c4d4800000002",
) -> str:
    direct = mode == "logitless-required"
    materialized = (1 if direct else new_tokens) if materialized is None else materialized
    logitless = (new_tokens - 1 if direct else 0) if logitless is None else logitless
    producer_rows = (
        (new_tokens - 1) * (materialized_logits_bytes // 4) if direct else 0
    ) if producer_rows is None else producer_rows
    scratch_bytes = (32 if direct else 0) if scratch_bytes is None else scratch_bytes
    reclaimed_bytes = (
        materialized_logits_bytes if direct else 0
    ) if reclaimed_bytes is None else reclaimed_bytes
    dispatches = graphs * layers
    decode_ms = "5.000" if direct else "10.000"
    internal_ms = "9.100" if direct else "14.100"
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
        f"tile_output_bytes={tile_output_bytes} argmax_scan_rows={argmax_scan_rows} "
        f"scratch_bytes={scratch_bytes} "
        f"materialized_logits_bytes={materialized_logits_bytes} "
        f"steady_state_reclaimed_bytes={reclaimed_bytes} fallbacks={fallbacks} "
        f"rejects={rejects} abi={abi}\n"
        f"time: {internal_ms} ms (283.7 tok/s, prefilled {prompt_tokens}, prefill=batch)\n"
    )


def write_fake_glacier(
    root: Path,
    *,
    divergent_output: bool = False,
    divergent_abi: bool = False,
) -> Path:
    binary = root / "fake-glacier"
    binary.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib,sys\n"
        "a=sys.argv\n"
        "required=['--require-batch-prefill','--require-prepared-image']\n"
        "assert all(flag in a for flag in required)\n"
        "assert a[a.index('--temp')+1]=='0'\n"
        f"divergent_output={divergent_output!r}\n"
        f"divergent_abi={divergent_abi!r}\n"
        "out=pathlib.Path(a[a.index('--out-ids-file')+1])\n"
        "prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())\n"
        "tokens=int(a[a.index('--n')+1]); runs=max(0,tokens-1); layers=4\n"
        "threshold=int(a[a.index('--parallel-attention-min-context')+1])\n"
        "mode=a[a.index('--greedy-output')+1]; direct=mode=='logitless-required'\n"
        "graphs=min(runs,max(0,prompt+runs-threshold+1)); dispatches=graphs*layers\n"
        "start=8 if divergent_output and direct else 7\n"
        "out.write_text(' '.join(str(start+i) for i in range(tokens))+'\\n')\n"
        "print('load: mode=prepared artifact=glrt ms=1.0')\n"
        "print(f'schedule: attention=parallel min_context={threshold} layers={layers}')\n"
        "print('ready: phase=request_ready ms=2.0')\n"
        "decode_ms='5.000' if direct else '10.000'\n"
        "print(f'phases: prefill_ms=3.0 decode_ms={decode_ms} sampling_ms=0.1 decode_runs={runs} attention_graphs={graphs} attention_dispatches={dispatches} handoff_graphs={graphs} handoff_dispatches={dispatches} fused_gqa_graphs={graphs} fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} paired_mlp_dispatches={dispatches}')\n"
        "materialized=1 if direct else tokens; logitless=runs if direct else 0\n"
        "scratch=32 if direct else 0; logits_bytes=607744\n"
        "producer_rows=runs*(logits_bytes//4) if direct else 0\n"
        "reclaimed=logits_bytes if direct else 0\n"
        "abi='474c4d4800000003' if divergent_abi and direct else '474c4d4800000002'\n"
        "print(f'greedy_output: mode={mode} materialized_projections={materialized} logitless_projections={logitless} producer_rows={producer_rows} tile_output_bytes=0 argmax_scan_rows=0 scratch_bytes={scratch} materialized_logits_bytes={logits_bytes} steady_state_reclaimed_bytes={reclaimed} fallbacks=0 rejects=0 abi={abi}')\n"
        "internal='9.100' if direct else '14.100'\n"
        "print(f'time: {internal} ms (281.7 tok/s, prefilled {prompt}, prefill=batch)')\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    return binary


class GreedyOutputAbTests(unittest.TestCase):
    def test_defaults_are_p176_n64_and_balanced(self):
        args = greedy_output_ab.argument_parser().parse_args(
            ["--binary", "glacier", "--model", "model.glrt", "--output", "-"]
        )
        self.assertEqual(args.ids.name, "eval-qwen2.5.ids")
        self.assertEqual(args.new_tokens, 64)
        self.assertEqual(args.threshold, 128)
        self.assertEqual(args.samples_per_variant, 32)
        self.assertEqual(args.warmups_per_variant, 2)
        patterns = greedy_output_ab.build_patterns(args.samples_per_variant, 1234)
        self.assertEqual(len(patterns), 16)
        self.assertEqual(patterns.count("ABBA"), 8)
        self.assertEqual(patterns.count("BAAB"), 8)
        self.assertEqual(patterns, greedy_output_ab.build_patterns(32, 1234))

    def test_exact_greedy_output_and_phase_telemetry(self):
        materialized = greedy_output_ab.parse_telemetry(
            telemetry(mode="materialized"),
            variant="materialized",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        self.assertEqual(materialized["greedy_materialized_projections"], 4)
        self.assertEqual(materialized["greedy_logitless_projections"], 0)
        self.assertEqual(materialized["greedy_scratch_bytes"], 0)
        self.assertEqual(materialized["greedy_steady_state_reclaimed_bytes"], 0)

        logitless = greedy_output_ab.parse_telemetry(
            telemetry(mode="logitless-required"),
            variant="logitless-required",
            prompt_tokens=3,
            new_tokens=4,
            threshold=4,
        )
        self.assertEqual(logitless["greedy_materialized_projections"], 1)
        self.assertEqual(logitless["greedy_logitless_projections"], 3)
        self.assertEqual(logitless["greedy_producer_rows"], 455_808)
        self.assertEqual(logitless["greedy_tile_output_bytes"], 0)
        self.assertEqual(logitless["greedy_argmax_scan_rows"], 0)
        self.assertEqual(logitless["greedy_scratch_bytes"], 32)
        self.assertEqual(
            logitless["greedy_steady_state_reclaimed_bytes"], 607_744
        )
        self.assertEqual(logitless["greedy_output_abi"], "474c4d4800000002")

        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "mode was"):
            greedy_output_ab.parse_telemetry(
                telemetry(mode="materialized"),
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "counters"):
            greedy_output_ab.parse_telemetry(
                telemetry(mode="logitless-required", logitless=2),
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "positive scratch"):
            greedy_output_ab.parse_telemetry(
                telemetry(mode="logitless-required", scratch_bytes=0),
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "smaller"):
            greedy_output_ab.parse_telemetry(
                telemetry(
                    mode="logitless-required",
                    scratch_bytes=607_744,
                ),
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "counters"):
            greedy_output_ab.parse_telemetry(
                telemetry(mode="logitless-required", reclaimed_bytes=607_743),
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        with self.assertRaisesRegex(
            greedy_output_ab.HarnessError, "fallbacks/rejects"
        ):
            greedy_output_ab.parse_telemetry(
                telemetry(mode="logitless-required", fallbacks=1),
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )

    def test_duplicate_malformed_or_drifted_telemetry_fails_closed(self):
        valid = telemetry(mode="logitless-required")
        duplicate_greedy = valid + valid.splitlines()[4] + "\n"
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "duplicated"):
            greedy_output_ab.parse_telemetry(
                duplicate_greedy,
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        duplicate_phase = valid + valid.splitlines()[3] + "\n"
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "duplicated"):
            greedy_output_ab.parse_telemetry(
                duplicate_phase,
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        malformed = valid.replace(" abi=474c4d4800000002", " abi=0x474c4d4800000002")
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "malformed"):
            greedy_output_ab.parse_telemetry(
                malformed,
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )
        drifted = valid.replace(" rejects=0 abi=", " rejects=0 extra=1 abi=")
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "malformed"):
            greedy_output_ab.parse_telemetry(
                drifted,
                variant="logitless-required",
                prompt_tokens=3,
                new_tokens=4,
                threshold=4,
            )

    def test_commands_hold_every_option_except_greedy_policy_constant(self):
        config = greedy_output_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        output = Path("/tmp/completion.ids")
        materialized = greedy_output_ab.build_command(config, "materialized", output)
        logitless = greedy_output_ab.build_command(
            config, "logitless-required", output
        )
        self.assertEqual(materialized[0], logitless[0])
        self.assertIn("--require-batch-prefill", materialized)
        self.assertIn("--require-prepared-image", materialized)
        self.assertEqual(materialized[materialized.index("--temp") + 1], "0")
        self.assertEqual(
            materialized[materialized.index("--eos") + 1], str((1 << 32) - 1)
        )
        self.assertEqual(
            materialized[materialized.index("--decode-plan") + 1], "checked"
        )
        policy_index = materialized.index("--greedy-output")
        self.assertEqual(materialized[policy_index + 1], "materialized")
        self.assertEqual(logitless[policy_index + 1], "logitless-required")
        normalized = list(logitless)
        normalized[policy_index + 1] = "materialized"
        self.assertEqual(materialized, normalized)

    def test_strict_harness_rejects_non_logitless_configuration(self):
        base = dict(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "threads"):
            greedy_output_ab.validate_config(
                greedy_output_ab.Config(**base, threads=1)
            )
        with self.assertRaisesRegex(greedy_output_ab.HarnessError, "new tokens"):
            greedy_output_ab.validate_config(
                greedy_output_ab.Config(**base, new_tokens=1)
            )

    def test_sample_cap_is_checked_before_pattern_allocation(self):
        config = greedy_output_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
            samples_per_variant=10_001,
        )
        with mock.patch.object(
            greedy_output_ab,
            "build_patterns",
            side_effect=AssertionError("must not allocate"),
        ):
            with self.assertRaisesRegex(
                greedy_output_ab.HarnessError, "must not exceed 10000"
            ):
                greedy_output_ab.validate_config(config)

    def test_process_fingerprint_hashes_exact_raw_output_bytes(self):
        raw = b"payload:\xff\n"
        process = greedy_output_ab._run_process(
            [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'payload:\\xff\\n')"],
            Path.cwd(),
            10.0,
        )
        self.assertEqual(
            process["raw_output_sha256"], greedy_output_ab.sha256_bytes(raw)
        )
        self.assertIn("\ufffd", process["output"])

    def test_no_overwrite_publication_has_one_concurrent_winner(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result.json"
            read_fd, write_fd = os.pipe()
            children: list[int] = []
            for writer in range(4):
                process_id = os.fork()
                if process_id == 0:
                    os.close(write_fd)
                    os.read(read_fd, 1)
                    try:
                        greedy_output_ab.write_result(
                            {"writer": writer}, output, overwrite=False
                        )
                    except greedy_output_ab.HarnessError:
                        os._exit(7)
                    except BaseException:
                        os._exit(9)
                    os._exit(0)
                children.append(process_id)
            os.close(read_fd)
            os.write(write_fd, b"x" * len(children))
            os.close(write_fd)
            exit_codes = [
                os.waitstatus_to_exitcode(os.waitpid(process_id, 0)[1])
                for process_id in children
            ]
            self.assertEqual(exit_codes.count(0), 1)
            self.assertEqual(exit_codes.count(7), 3)
            self.assertIn(json.loads(output.read_text())["writer"], range(4))
            self.assertEqual(list(output.parent.glob(f".{output.name}.*")), [])

    def test_materialized_over_logitless_bootstrap_is_deterministic(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                variant = "logitless-required" if letter == "A" else "materialized"
                samples.append(
                    {
                        "block_index": block_index,
                        "variant": variant,
                        "metrics": {
                            "decode_ms": (
                                5.0 if variant == "logitless-required" else 10.0
                            )
                        },
                    }
                )
        first = greedy_output_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = greedy_output_ab.paired_ratio(
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
        self.assertTrue(first["direction"].startswith("materialized_over_logitless"))

    def test_lightweight_end_to_end_manifest_and_exact_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = write_fake_glacier(root)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = greedy_output_ab.Config(
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
            result = greedy_output_ab.run_benchmark(config)
            self.assertEqual(result["schema"], greedy_output_ab.SCHEMA)
            self.assertEqual(result["status"], "evidence-valid")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmups"]), 2)
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["completion_equivalence"]["distinct_normalized_hashes"],
                [greedy_output_ab.sha256_bytes(b"7 8\n")],
            )
            contract = result["contract"]
            self.assertTrue(contract["same_binary_required"])
            self.assertTrue(contract["only_greedy_output_policy_varies"])
            self.assertEqual(contract["letter_mapping"]["A"], "logitless-required")
            self.assertEqual(contract["letter_mapping"]["B"], "materialized")
            self.assertEqual(contract["expected_materialized_projections"], 2)
            self.assertEqual(contract["expected_logitless_projections"], 1)
            self.assertEqual(contract["expected_producer_rows"], 151_936)
            self.assertEqual(contract["required_tile_output_bytes"], 0)
            self.assertEqual(contract["required_argmax_scan_rows"], 0)
            self.assertEqual(contract["materialized_logits_bytes"], 607_744)
            self.assertEqual(contract["logitless_scratch_bytes"], 32)
            self.assertEqual(
                len(set(contract["binary_sha256_by_variant"].values())), 1
            )
            self.assertEqual(
                result["materialized_over_logitless"]["decode_ms"]["estimate"],
                2.0,
            )
            self.assertEqual(
                result["promotion_gates"]["latency"]["requirements"][
                    "decode_ms_estimate_min"
                ],
                1.02,
            )
            normalized_commands = []
            for item in [*result["warmups"], *result["samples"]]:
                command = list(item["argv"])
                command[command.index("--greedy-output") + 1] = "materialized"
                normalized_commands.append(tuple(command))
            self.assertEqual(len(set(normalized_commands)), 1)
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
            config = greedy_output_ab.Config(
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
            with self.assertRaisesRegex(greedy_output_ab.HarnessError, "exact completion"):
                greedy_output_ab.run_benchmark(config)

    def test_abi_drift_fails_before_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = write_fake_glacier(root, divergent_abi=True)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = greedy_output_ab.Config(
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
            with self.assertRaisesRegex(greedy_output_ab.HarnessError, "ABI was"):
                greedy_output_ab.run_benchmark(config)

    def test_main_reports_user_facing_error_without_traceback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "model.glrt"
            model.write_bytes(b"test glrt")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                status = greedy_output_ab.main(
                    [
                        "--binary",
                        str(root / "missing-glacier"),
                        "--model",
                        str(model),
                        "--ids",
                        str(ids),
                        "--output",
                        "-",
                        "--cwd",
                        str(root),
                        "--samples-per-variant",
                        "4",
                        "--bootstrap-resamples",
                        "100",
                    ]
                )
            self.assertEqual(status, 2)
            self.assertIn("error: binary is not executable", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
