import importlib.util
import hashlib
import json
import os
import platform
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "paired_abba.py"
SPEC = importlib.util.spec_from_file_location("paired_abba", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)


class PairedAbbaTests(unittest.TestCase):
    def test_canonicalization_removes_exactly_one_lf(self):
        canonical, stripped = paired.canonicalize_text(b"hello\n\n", True)
        self.assertEqual(canonical, b"hello\n")
        self.assertTrue(stripped)
        canonical, stripped = paired.canonicalize_text(b"hello\n", False)
        self.assertEqual(canonical, b"hello\n")
        self.assertFalse(stripped)

    def test_token_id_parsers_consume_the_full_stream(self):
        self.assertEqual(paired.parse_token_ids("1  2\n13\n", "plain"), [1, 2, 13])
        self.assertEqual(
            paired.parse_token_ids("[1, 2, 13]\n", "json-array"), [1, 2, 13]
        )
        with self.assertRaises(paired.HarnessError):
            paired.parse_token_ids("count=3\n1 2 13", "plain")
        with self.assertRaises(paired.HarnessError):
            paired.parse_token_ids("[1, 2, 13]\nnoise", "json-array")

    def test_schedule_is_deterministic_and_fully_balanced(self):
        first = paired.build_schedule(20, 1234)
        second = paired.build_schedule(20, 1234)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 40)
        self.assertEqual(sum(item["engine"] == "glacier" for item in first), 20)
        self.assertEqual(sum(item["engine"] == "llama" for item in first), 20)
        patterns = [first[index]["pattern"] for index in range(0, len(first), 4)]
        self.assertEqual(patterns.count("ABBA"), patterns.count("BAAB"))
        for index in range(0, len(first), 4):
            letters = "".join(
                "A" if item["engine"] == "glacier" else "B"
                for item in first[index : index + 4]
            )
            self.assertEqual(letters, first[index]["pattern"])

    def test_time_and_engine_output_parsers(self):
        timing = """        1.23 real 1.00 user 0.20 sys
             1234567  maximum resident set size
              765432  peak memory footprint
"""
        parsed_timing = paired.parse_time_l(timing)
        self.assertEqual(parsed_timing["time_l_wall_seconds"], 1.23)
        self.assertEqual(parsed_timing["peak_rss_bytes"], 1234567)
        with self.assertRaisesRegex(paired.HarnessError, "exactly one real record"):
            paired.parse_time_l(timing + timing)
        with self.assertRaisesRegex(
            paired.HarnessError, "exactly one maximum resident set size record"
        ):
            paired.parse_time_l("1.23 real 1.00 user 0.20 sys\n")
        glacier = paired.parse_engine_internal(
            "glacier",
            "load: mode=prepared artifact=glrt ms=84.25\n"
            "schedule: attention=parallel min_context=128 layers=24\n"
            "ready: phase=request_ready ms=101.50\n"
            "phases: prefill_ms=200.000 decode_ms=420.000 sampling_ms=0.125 decode_runs=63 attention_graphs=63 attention_dispatches=1512 handoff_graphs=63 handoff_dispatches=1512 fused_gqa_graphs=63 fused_gqa_dispatches=1512 paired_mlp_graphs=63 paired_mlp_dispatches=1512\n"
            "  time:    640.00 ms (100.0 tok/s, prefilled 176, prefill=batch)\n",
        )
        self.assertEqual(glacier["glacier_prefilled_tokens"], 176)
        self.assertEqual(glacier["glacier_prefill_mode"], "batch")
        self.assertEqual(glacier["glacier_load_mode"], "prepared")
        self.assertEqual(glacier["glacier_load_artifact"], "glrt")
        self.assertEqual(glacier["glacier_load_ms"], 84.25)
        self.assertEqual(glacier["model_ready_ms"], 101.5)
        self.assertEqual(glacier["glacier_prefill_phase_ms"], 200.0)
        self.assertEqual(glacier["glacier_decode_phase_ms"], 420.0)
        self.assertEqual(glacier["glacier_sampling_ms"], 0.125)
        self.assertEqual(glacier["glacier_decode_graph_runs"], 63)
        self.assertEqual(glacier["glacier_parallel_attention_graphs"], 63)
        self.assertEqual(glacier["glacier_parallel_attention_dispatches"], 1512)
        self.assertEqual(glacier["glacier_handoff_graphs"], 63)
        self.assertEqual(glacier["glacier_handoff_dispatches"], 1512)
        self.assertEqual(glacier["glacier_fused_gqa_graphs"], 63)
        self.assertEqual(glacier["glacier_fused_gqa_dispatches"], 1512)
        self.assertEqual(glacier["glacier_paired_mlp_graphs"], 63)
        self.assertEqual(glacier["glacier_paired_mlp_dispatches"], 1512)
        self.assertEqual(glacier["glacier_phase_telemetry_line_count"], 1)
        self.assertEqual(glacier["glacier_phase_telemetry_valid_line_count"], 1)
        self.assertEqual(glacier["glacier_attention_schedule"], "parallel")
        self.assertEqual(glacier["glacier_attention_min_context"], 128)
        self.assertEqual(glacier["glacier_attention_layers"], 24)
        self.assertEqual(glacier["glacier_attention_schedule_line_count"], 1)
        self.assertEqual(glacier["glacier_attention_schedule_valid_line_count"], 1)
        llama = paired.parse_engine_internal(
            "llama",
            "llama_perf_context_print: prompt eval time = 10.00 ms / 176 tokens (0.06 ms per token, 17600.00 tokens per second)\n"
            "llama_perf_context_print: eval time = 630.00 ms / 63 runs (10.00 ms per token, 100.00 tokens per second)\n",
        )
        self.assertEqual(llama["llama_prompt_eval_tokens"], 176)
        self.assertEqual(llama["llama_eval_runs"], 63)
        self.assertEqual(llama["llama_eval_tokens_per_second"], 100.0)
        current = paired.parse_engine_internal(
            "llama",
            "0.00.455.984 I llama_completion: llama threadpool init, n_threads = 4\n"
            "0.02.119.284 I common_perf_print: prompt eval time = 10.00 ms / 176 tokens (0.06 ms per token, 17600.00 tokens per second)\n"
            "0.02.119.285 I common_perf_print: eval time = 630.00 ms / 63 runs (10.00 ms per token, 100.00 tokens per second)\n",
        )
        self.assertEqual(current["llama_prompt_eval_tokens"], 176)
        self.assertEqual(current["llama_eval_runs"], 63)
        self.assertEqual(current["model_ready_ms"], 455.984)

        zero_duration = paired.parse_engine_internal(
            "llama",
            "0.00.455.984 I llama_completion: llama threadpool init, n_threads = 4\n"
            "0.02.119.284 I common_perf_print: prompt eval time = 5.00 ms / 3 tokens (1.67 ms per token, 600.00 tokens per second)\n"
            "0.02.119.285 I common_perf_print: eval time = 0.00 ms / 1 runs (0.00 ms per token, inf tokens per second)\n",
        )
        self.assertEqual(zero_duration["llama_eval_ms"], 0.0)
        self.assertEqual(zero_duration["llama_eval_runs"], 1)
        self.assertIsNone(zero_duration["llama_eval_tokens_per_second"])
        self.assertEqual(
            zero_duration["llama_eval_tokens_per_second_status"],
            "unresolved_zero_duration",
        )

    def test_bootstrap_is_deterministic(self):
        samples = []
        for block in range(4):
            pattern = "ABBA" if block % 2 == 0 else "BAAB"
            for position, letter in enumerate(pattern):
                engine = "glacier" if letter == "A" else "llama"
                samples.append(
                    {
                        "block_index": block,
                        "engine": engine,
                        "metrics": {
                            "wall_seconds": 1.0 if engine == "glacier" else 2.0
                        },
                    }
                )
        first = paired.paired_bootstrap_ratio(
            samples, "wall_seconds", "lower", resamples=500, seed=9, confidence=0.95
        )
        second = paired.paired_bootstrap_ratio(
            samples, "wall_seconds", "lower", resamples=500, seed=9, confidence=0.95
        )
        self.assertEqual(first, second)
        self.assertEqual(first["estimate"], 2.0)
        self.assertEqual(first["ci_low"], 2.0)
        self.assertEqual(first["ci_high"], 2.0)

    def test_bootstrap_omits_zero_length_decode_phase(self):
        samples = []
        for block in range(2):
            for engine in ("glacier", "llama", "llama", "glacier"):
                samples.append(
                    {
                        "block_index": block,
                        "engine": engine,
                        "metrics": {
                            "decode_phase_ms": 0.0 if engine == "glacier" else 5.0
                        },
                    }
                )
        self.assertIsNone(
            paired.paired_bootstrap_ratio(
                samples,
                "decode_phase_ms",
                "lower",
                resamples=100,
                seed=9,
                confidence=0.95,
            )
        )

    def test_summary_omits_decode_ratios_for_unresolved_llama_throughput(self):
        samples = []
        for engine in ("glacier", "llama", "llama", "glacier"):
            metrics = (
                {
                    "decode_phase_ms": 10.0,
                    "decode_graph_tokens_per_second": 100.0,
                }
                if engine == "glacier"
                else {
                    "llama_eval_ms": 0.0,
                    "llama_eval_runs": 1,
                    "llama_eval_tokens_per_second": None,
                }
            )
            samples.append(
                {
                    "block_index": 0,
                    "engine": engine,
                    "metrics": metrics,
                    "completion": {"token_ids": [7]},
                }
            )
        summary = paired.summarize_samples(
            {
                "statistics": {
                    "bootstrap_resamples": 100,
                    "bootstrap_seed": 9,
                    "confidence": 0.95,
                },
                "workload": {"completion_equivalence": "stable-only"},
            },
            samples,
        )
        ratios = summary["glacier_advantage_ratios"]
        self.assertNotIn("decode_phase_ms", ratios)
        self.assertNotIn("decode_graph_tokens_per_second", ratios)

    def test_non_finite_and_unbounded_metrics_are_rejected(self):
        errors = paired.metric_evidence_errors(
            {"finite": 1.0, "infinite": float("inf"), "oversized": 1 << 80}
        )
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("non-finite" in error for error in errors))
        self.assertTrue(any("signed 64-bit" in error for error in errors))
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "non-finite.json"
            with self.assertRaises(ValueError):
                paired._write_json({"metric": float("nan")}, str(output))
            self.assertFalse(output.exists())

    def test_parallel_attention_late_threshold_crossing_is_exact(self):
        argv = ["glacier", "--parallel-attention-min-context", "5"]
        evidence = {
            "glacier_attention_schedule_line_count": 1,
            "glacier_attention_schedule_valid_line_count": 1,
            "glacier_attention_schedule": "parallel",
            "glacier_attention_min_context": 5,
            "glacier_attention_layers": 4,
            "glacier_parallel_attention_graphs": 2,
            "glacier_parallel_attention_dispatches": 8,
            "glacier_handoff_graphs": 2,
            "glacier_handoff_dispatches": 8,
            "glacier_fused_gqa_graphs": 2,
            "glacier_fused_gqa_dispatches": 8,
            "glacier_paired_mlp_graphs": 2,
            "glacier_paired_mlp_dispatches": 8,
        }
        self.assertEqual(
            paired.glacier_attention_evidence_errors(
                argv, evidence, prompt_tokens=3, decode_runs=3
            ),
            [],
        )

        wrong_graphs = {**evidence, "glacier_parallel_attention_graphs": 3}
        graph_errors = paired.glacier_attention_evidence_errors(
            argv, wrong_graphs, prompt_tokens=3, decode_runs=3
        )
        self.assertTrue(any("expected 2" in error for error in graph_errors))

        wrong_dispatches = {
            **evidence,
            "glacier_parallel_attention_dispatches": 7,
        }
        dispatch_errors = paired.glacier_attention_evidence_errors(
            argv, wrong_dispatches, prompt_tokens=3, decode_runs=3
        )
        self.assertTrue(any("expected 8" in error for error in dispatch_errors))

        wrong_fused = {**evidence, "glacier_fused_gqa_graphs": 1}
        fused_errors = paired.glacier_attention_evidence_errors(
            argv, wrong_fused, prompt_tokens=3, decode_runs=3
        )
        self.assertTrue(
            any("fused GQA" in error and "zero or 2" in error for error in fused_errors)
        )

        wrong_paired_mlp = {**evidence, "glacier_paired_mlp_graphs": 1}
        paired_mlp_errors = paired.glacier_attention_evidence_errors(
            argv, wrong_paired_mlp, prompt_tokens=3, decode_runs=3
        )
        self.assertTrue(
            any(
                "paired MLP" in error and "zero or 2" in error
                for error in paired_mlp_errors
            )
        )

        unfused_evidence = {
            **evidence,
            "glacier_fused_gqa_graphs": 0,
            "glacier_fused_gqa_dispatches": 0,
        }
        self.assertEqual(
            paired.glacier_attention_evidence_errors(
                argv, unfused_evidence, prompt_tokens=3, decode_runs=3
            ),
            [],
        )
        required_fused_errors = paired.glacier_attention_evidence_errors(
            argv,
            unfused_evidence,
            prompt_tokens=3,
            decode_runs=3,
            require_fused_gqa=True,
        )
        self.assertTrue(
            any(
                "required Glacier fused GQA" in error for error in required_fused_errors
            )
        )
        unpaired_evidence = {
            **evidence,
            "glacier_paired_mlp_graphs": 0,
            "glacier_paired_mlp_dispatches": 0,
        }
        required_paired_mlp_errors = paired.glacier_attention_evidence_errors(
            argv,
            unpaired_evidence,
            prompt_tokens=3,
            decode_runs=3,
            require_paired_mlp=True,
        )
        self.assertTrue(
            any(
                "required Glacier paired MLP" in error
                for error in required_paired_mlp_errors
            )
        )
        no_eligible_errors = paired.glacier_attention_evidence_errors(
            ["glacier", "--parallel-attention-min-context", "99"],
            {
                **unfused_evidence,
                "glacier_attention_min_context": 99,
                "glacier_parallel_attention_graphs": 0,
                "glacier_parallel_attention_dispatches": 0,
                "glacier_handoff_graphs": 0,
                "glacier_handoff_dispatches": 0,
            },
            prompt_tokens=3,
            decode_runs=3,
            require_fused_gqa=True,
        )
        self.assertTrue(any("no eligible" in error for error in no_eligible_errors))

        serial_evidence = {
            **evidence,
            "glacier_attention_schedule": "serial",
            "glacier_attention_min_context": None,
            "glacier_parallel_attention_graphs": 0,
            "glacier_parallel_attention_dispatches": 0,
            "glacier_handoff_graphs": 0,
            "glacier_handoff_dispatches": 0,
            "glacier_fused_gqa_graphs": 0,
            "glacier_fused_gqa_dispatches": 0,
            "glacier_paired_mlp_graphs": 0,
            "glacier_paired_mlp_dispatches": 0,
        }
        self.assertEqual(
            paired.glacier_attention_evidence_errors(
                ["glacier", "--serial-attention"],
                serial_evidence,
                prompt_tokens=3,
                decode_runs=3,
            ),
            [],
        )
        serial_fused_errors = paired.glacier_attention_evidence_errors(
            ["glacier", "--serial-attention"],
            {**serial_evidence, "glacier_fused_gqa_dispatches": 1},
            prompt_tokens=3,
            decode_runs=3,
        )
        self.assertTrue(
            any(
                "serial" in error and "fused GQA" in error
                for error in serial_fused_errors
            )
        )
        required_serial_errors = paired.glacier_attention_evidence_errors(
            ["glacier", "--serial-attention"],
            serial_evidence,
            prompt_tokens=3,
            decode_runs=3,
            require_fused_gqa=True,
        )
        self.assertTrue(
            any(
                "requires parallel attention" in error
                for error in required_serial_errors
            )
        )

    def test_attention_telemetry_duplicate_and_nonfinite_lines_fail_closed(self):
        parsed = paired.parse_engine_internal(
            "glacier",
            "schedule: attention=parallel min_context=5 layers=4\n"
            "schedule: attention=parallel min_context=5 layers=nan\n"
            "phases: prefill_ms=4.0 decode_ms=10.0 sampling_ms=0.1 decode_runs=3 attention_graphs=2 attention_dispatches=8 handoff_graphs=2 handoff_dispatches=8 fused_gqa_graphs=2 fused_gqa_dispatches=8 paired_mlp_graphs=2 paired_mlp_dispatches=8\n"
            "phases: prefill_ms=nan decode_ms=10.0 sampling_ms=0.1 decode_runs=3 attention_graphs=2 attention_dispatches=8 handoff_graphs=2 handoff_dispatches=8 fused_gqa_graphs=2 fused_gqa_dispatches=8 paired_mlp_graphs=2 paired_mlp_dispatches=8\n"
            "time: 14.0 ms (285.7 tok/s, prefilled 3, prefill=batch)\n",
        )
        self.assertEqual(parsed["glacier_attention_schedule_line_count"], 2)
        self.assertEqual(parsed["glacier_attention_schedule_valid_line_count"], 1)
        self.assertEqual(parsed["glacier_phase_telemetry_line_count"], 2)
        self.assertEqual(parsed["glacier_phase_telemetry_valid_line_count"], 1)
        errors = paired.glacier_attention_evidence_errors(
            ["glacier", "--parallel-attention-min-context", "5"],
            parsed,
            prompt_tokens=3,
            decode_runs=3,
        )
        self.assertTrue(any("malformed, or duplicated" in error for error in errors))

    def _write_manifest(self, root: Path, *, mismatch: bool = False) -> Path:
        (root / "text.txt").write_bytes(b"hello\n\n")
        (root / "ids.txt").write_text("1 2 13\n", encoding="utf-8")
        hf_ids = "1 2 99" if mismatch else "1 2 13"
        manifest = {
            "schema": paired.SCHEMA,
            "name": "unit",
            "repo_root": ".",
            "samples_per_engine": 4,
            "warmup_runs_per_engine": 1,
            "machine_state": {"mode": "disabled"},
            "workload": {
                "canonical_text": {
                    "path": "text.txt",
                    "strip_exactly_one_final_lf": True,
                },
                "pinned_token_ids": {"path": "ids.txt", "format": "plain"},
                "completion_tokens": 2,
                "completion_equivalence": "stable-only",
                "glacier_prefill_mode": "batch",
            },
            "artifacts": {
                "python_runtime": {
                    "path": sys.executable,
                    "kind": "executable",
                }
            },
            "tokenizer_preflight": {
                "hf": {
                    "argv": [sys.executable, "-c", f"print('{hf_ids}')"],
                    "stdin": "canonical_text",
                    "ids_format": "plain",
                },
                "llama": {
                    "argv": [sys.executable, "-c", "print('[1, 2, 13]')"],
                    "stdin": "canonical_text",
                    "ids_format": "json-array",
                },
            },
            "engines": {
                "glacier": {
                    "argv": [sys.executable, "-c", "print('1 2')"],
                    "completion": {
                        "source": "stdout",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                },
                "llama": {
                    "argv": [sys.executable, "-c", "print('1 2')"],
                    "completion": {
                        "source": "stdout",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                },
            },
            "statistics": {"bootstrap_resamples": 100},
        }
        path = root / "manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path

    @staticmethod
    def _bind_python_executables(manifest: dict[str, object]) -> None:
        for command in manifest["tokenizer_preflight"].values():
            command["argv"][0] = "{python_runtime}"
        for command in manifest["engines"].values():
            command["argv"][0] = "{python_runtime}"
            extractor = command.get("completion", {}).get("token_id_extractor")
            if extractor is not None:
                extractor["argv"][0] = "{python_runtime}"

    def test_manifest_resolution_dry_run_and_preflight(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            self.assertEqual(config["samples_per_engine"], 4)
            self.assertEqual(Path(config["repo_root"]), root.resolve())
            dry = paired.dry_run(config)
            self.assertEqual(dry["status"], "passed")
            self.assertEqual(len(dry["schedule"]), 8)
            result = paired.run_harness(config, preflight_only=True)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(
                result["tokenizer_preflight"]["commands"]["hf"]["token_ids"],
                [1, 2, 13],
            )
            self.assertTrue(result["fixture"]["terminal_lf_was_stripped"])
            self.assertEqual(result["fixture"]["canonical_text_bytes"], len(b"hello\n"))

    def test_machine_state_defaults_publishable_and_disable_is_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text(encoding="utf-8"))
            del manifest["machine_state"]
            manifest["samples_per_engine"] = 32
            self._bind_python_executables(manifest)
            path.write_text(json.dumps(manifest), encoding="utf-8")
            config = paired.load_manifest(path)
            self.assertEqual(config["machine_state"]["mode"], "publishable")
            self.assertTrue(config["machine_state"]["publication_eligible"])
            self.assertEqual(config["machine_state"]["window_seconds"], 60.0)
            schedule = paired.build_schedule(config["samples_per_engine"], 7)
            patterns = [
                entry["pattern"]
                for entry in schedule
                if entry["position_in_block"] == 0
            ]
            self.assertEqual(patterns.count("ABBA"), 8)
            self.assertEqual(patterns.count("BAAB"), 8)

            manifest["machine_state"] = {
                "mode": "disabled",
                "max_load1": 2.0,
            }
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "disabled manifest.machine_state"
            ):
                paired.load_manifest(path)
            with self.assertRaisesRegex(paired.HarnessError, "max_load1"):
                paired._validate_machine_state(
                    {"mode": "publishable", "max_load1": 1.01}
                )
            with self.assertRaisesRegex(paired.HarnessError, "window_seconds"):
                paired._validate_machine_state(
                    {"mode": "publishable", "window_seconds": 59.0}
                )
            manifest["machine_state"] = {"mode": "publishable"}
            manifest["samples_per_engine"] = 28
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "samples_per_engine >= 32"
            ):
                paired.load_manifest(path)

    def test_publishable_mode_requires_fingerprinted_command_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["machine_state"] = {"mode": "publishable"}
            manifest["samples_per_engine"] = 32
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError,
                r"manifest\.tokenizer_preflight\.hf\.argv\[0\].*artifact placeholder",
            ):
                paired.load_manifest(path)

            self._bind_python_executables(manifest)
            path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(
                paired.load_manifest(path)["machine_state"]["mode"], "publishable"
            )

            manifest["artifacts"]["python_runtime"]["kind"] = "file"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, r"artifact \{python_runtime\}.*kind 'executable'"
            ):
                paired.load_manifest(path)

    def test_publishable_mode_rejects_unbound_or_composed_file_operands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            bridge = root / "tokenize.py"
            bridge.write_text("print('1 2 13')\n", encoding="utf-8")
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["machine_state"] = {"mode": "publishable"}
            manifest["samples_per_engine"] = 32
            self._bind_python_executables(manifest)
            manifest["tokenizer_preflight"]["hf"]["argv"].append(str(bridge))
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "unbound critical file operand"
            ):
                paired.load_manifest(path)

            manifest["artifacts"]["tokenizer_bridge"] = {
                "path": str(bridge),
                "kind": "file",
            }
            manifest["tokenizer_preflight"]["hf"]["argv"][-1] = (
                "{tokenizer_bridge}"
            )
            path.write_text(json.dumps(manifest), encoding="utf-8")
            paired.load_manifest(path)

            manifest["tokenizer_preflight"]["hf"]["argv"][-1] = (
                "--bridge={tokenizer_bridge}"
            )
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "placeholder as the entire operand"
            ):
                paired.load_manifest(path)

            manifest["tokenizer_preflight"]["hf"]["argv"][-1] = (
                "{repo_root}/tokenize.py"
            )
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "unbound critical file operand"
            ):
                paired.load_manifest(path)

            manifest["machine_state"] = {"mode": "disabled"}
            manifest["samples_per_engine"] = 4
            manifest["tokenizer_preflight"]["hf"]["argv"][-1] = str(bridge)
            path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(
                paired.load_manifest(path)["machine_state"]["mode"], "disabled"
            )

    def test_publishable_mode_binds_completion_extractor_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["machine_state"] = {"mode": "publishable"}
            manifest["samples_per_engine"] = 32
            self._bind_python_executables(manifest)
            manifest["engines"]["llama"]["completion"] = {
                "source": "stdout",
                "format": "raw",
                "strip_exactly_one_final_lf": True,
                "token_id_extractor": {
                    "argv": [sys.executable, "-c", "print('1 2')"],
                    "ids_format": "plain",
                },
            }
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError,
                r"completion\.token_id_extractor\.argv\[0\].*artifact placeholder",
            ):
                paired.load_manifest(path)

            manifest["engines"]["llama"]["completion"]["token_id_extractor"][
                "argv"
            ][0] = "{python_runtime}"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            paired.load_manifest(path)

    def test_publishable_example_has_complete_artifact_bindings(self):
        config = paired.load_manifest(MODULE_PATH.parent / "paired.example.json")
        self.assertEqual(config["machine_state"]["mode"], "publishable")

    def test_machine_state_probe_parsers_do_not_infer_temperature(self):
        power = paired.parse_pmset_power(
            "Now drawing from 'AC Power'\n"
            " -InternalBattery-0 (id=1)\t100%; charged; present: true\n",
            "Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n",
        )
        self.assertTrue(power["on_ac_power"])
        self.assertTrue(power["battery_full"])
        self.assertEqual(power["low_power_mode"], 0)
        self.assertEqual(power["battery_status"], "charged")
        self.assertIn("active_settings_sha256", power)
        self.assertTrue(
            any(
                "discharging" in error
                for error in paired._power_state_errors(
                    {**power, "battery_status": "discharging"}, "test"
                )
            )
        )

        unavailable = paired.parse_pmset_thermal(
            "Note: No thermal warning level has been recorded\n", 8
        )
        self.assertEqual(unavailable["status"], "unavailable")
        self.assertFalse(unavailable["temperature_measured"])
        constrained = paired.parse_pmset_thermal(
            "CPU_Scheduler_Limit = 80\nCPU_Available_CPUs = 8\nCPU_Speed_Limit = 100\n",
            8,
        )
        self.assertEqual(constrained["status"], "constrained")
        self.assertFalse(constrained["temperature_measured"])

        vm = paired.parse_vm_stat('Pageouts: 10.\n"Swapins": 20.\n"Swapouts": 30.\n')
        self.assertEqual(vm, {"pageouts": 10, "swapins": 20, "swapouts": 30})
        load, idle = paired.parse_top_state(
            "Load Avg: 0.20, 0.30, 0.40\n"
            "CPU usage: 2.0% user, 1.0% sys, 97.0% idle\n"
            "Load Avg: 0.40, 0.30, 0.20\n"
            "CPU usage: 4.0% user, 2.0% sys, 94.0% idle\n"
        )
        self.assertEqual(load, [0.2, 0.4])
        self.assertEqual(idle, [97.0, 94.0])

    def test_external_cpu_parser_excludes_benchmark_group_and_normalizes(self):
        parsed = paired.parse_external_cpu_processes(
            " 100 1 100 390.0 /tmp/benchmark\n"
            " 101 100 100 12.0 /tmp/benchmark-helper\n"
            " 200 1 200 40.0 /tmp/background\n"
            " 300 1 300 8.0 /tmp/harness\n"
            " 400 300 300 5.0 /bin/ps\n",
            benchmark_pgid=100,
            harness_pid=300,
            sampler_pid=400,
            logical_cpu_count=8,
        )
        self.assertEqual(parsed["excluded_process_rows"], 4)
        self.assertEqual(
            parsed["external_cpu_percent_of_one_logical_cpu_sum"], 40.0
        )
        self.assertEqual(parsed["external_cpu_capacity_percent"], 5.0)
        self.assertEqual(parsed["top_external_processes"][0]["pid"], 200)
        with self.assertRaisesRegex(paired.HarnessError, "could not be parsed"):
            paired.parse_external_cpu_processes(
                "not a ps row\n",
                benchmark_pgid=100,
                harness_pid=300,
                sampler_pid=400,
                logical_cpu_count=8,
            )

    def test_external_cpu_gate_requires_samples_and_rejects_contention(self):
        policy = paired._validate_machine_state({"mode": "publishable"})
        quiet = {
            "sample_count": 3,
            "monitor_errors": [],
            "external_cpu_capacity_median_percent": 1.0,
            "external_cpu_capacity_max_percent": 2.0,
        }
        self.assertEqual(paired.external_cpu_observation_errors(quiet, policy), [])
        too_short = {**quiet, "sample_count": 2}
        self.assertTrue(
            any(
                "minimum 3" in error
                for error in paired.external_cpu_observation_errors(
                    too_short, policy
                )
            )
        )
        busy = {
            **quiet,
            "external_cpu_capacity_median_percent": 11.0,
            "external_cpu_capacity_max_percent": 21.0,
        }
        busy_errors = paired.external_cpu_observation_errors(busy, policy)
        self.assertTrue(any("median" in error for error in busy_errors))
        self.assertTrue(any("maximum" in error for error in busy_errors))
        failed = {**quiet, "monitor_errors": ["ps parser failed"]}
        self.assertTrue(
            any(
                "ps parser failed" in error
                for error in paired.external_cpu_observation_errors(failed, policy)
            )
        )
        matched = paired.matched_external_cpu_errors(
            paired.external_cpu_envelope(quiet),
            paired.external_cpu_envelope(
                {
                    **quiet,
                    "external_cpu_capacity_median_percent": 7.0,
                    "external_cpu_capacity_max_percent": 13.0,
                }
            ),
            policy,
        )
        self.assertEqual(len(matched), 2)

    def test_external_cpu_sampler_fails_closed_after_late_worker_exception(self):
        policy = paired._validate_machine_state({"mode": "publishable"})
        policy["in_run_cpu_sample_interval_seconds"] = 0.001
        sample = {"external_cpu_capacity_percent": 1.0}
        sampler = paired.ExternalCpuSampler(policy)
        with mock.patch.object(
            paired,
            "_read_external_cpu_sample",
            side_effect=[sample, sample, sample, RuntimeError("boom")],
        ):
            sampler.start(12345)
            sampler._thread.join(timeout=2.0)
            evidence = sampler.stop()
        self.assertEqual(evidence["sample_count"], 3)
        self.assertEqual(evidence["worker_exit_reason"], "unexpected-error")
        errors = paired.external_cpu_observation_errors(evidence, policy)
        self.assertTrue(any("RuntimeError: boom" in error for error in errors))

    def test_machine_state_top_interval_matches_macos_integer_contract(self):
        with self.assertRaisesRegex(paired.HarnessError, "whole number"):
            paired._validate_machine_state(
                {"mode": "publishable", "sample_interval_seconds": 1.5}
            )
        with self.assertRaisesRegex(
            paired.HarnessError, "sample_interval_seconds"
        ):
            paired._validate_machine_state(
                {"mode": "publishable", "sample_interval_seconds": 0.25}
            )

    def test_machine_state_admission_matching_and_contamination_are_strict(self):
        power = {
            "source": "AC Power",
            "on_ac_power": True,
            "battery_present": True,
            "battery_full": True,
            "battery_status": "charged",
            "low_power_mode": 0,
            "active_settings_sha256": "settings-a",
        }
        thermal = {
            "signal_available": False,
            "constrained": None,
            "status": "unavailable",
        }
        vm = {"pageouts": 10, "swapins": 20, "swapouts": 30}
        admission = {
            "window": {
                "load1_median": 0.25,
                "load1_max": 0.40,
                "cpu_idle_median_percent": 96.0,
                "cpu_idle_min_percent": 91.0,
            },
            "before": {"power": power, "thermal": thermal, "vm": vm},
            "after": {"power": power, "thermal": thermal, "vm": vm},
            "window_vm_deltas": {"pageouts": 0, "swapins": 0, "swapouts": 0},
        }
        policy = paired._validate_machine_state({"mode": "publishable"})
        self.assertEqual(paired.machine_state_admission_errors(admission, policy), [])
        envelope = paired.machine_state_envelope(admission)
        candidate = {**envelope, "load1_median": 0.6}
        self.assertTrue(
            any(
                "load1_median delta" in error
                for error in paired.matched_machine_state_errors(
                    envelope, candidate, policy
                )
            )
        )
        settings_candidate = {
            **envelope,
            "active_settings_sha256": "settings-b",
        }
        self.assertTrue(
            any(
                "active_settings_sha256" in error
                for error in paired.matched_machine_state_errors(
                    envelope, settings_candidate, policy
                )
            )
        )

        post = {
            "power": power,
            "thermal": thermal,
            "vm": {**vm, "pageouts": 11},
        }
        errors, deltas = paired.observation_contamination_errors(admission, post)
        self.assertEqual(deltas["pageouts"], 1)
        self.assertTrue(any("pageouts delta" in error for error in errors))

    def test_machine_state_gate_rechecks_and_fails_closed_before_execution(self):
        power = {
            "source": "AC Power",
            "on_ac_power": True,
            "battery_present": True,
            "battery_full": True,
            "battery_status": "charged",
            "low_power_mode": 0,
            "active_settings_sha256": "settings-a",
        }
        thermal = {
            "signal_available": False,
            "constrained": None,
            "status": "unavailable",
        }
        vm = {"pageouts": 1, "swapins": 2, "swapouts": 3}

        def admission(load: float):
            return {
                "schema": paired.MACHINE_STATE_SCHEMA,
                "window": {
                    "load1_median": load,
                    "load1_max": load,
                    "cpu_idle_median_percent": 95.0,
                    "cpu_idle_min_percent": 90.0,
                },
                "before": {"power": power, "thermal": thermal, "vm": vm},
                "after": {"power": power, "thermal": thermal, "vm": vm},
                "window_vm_deltas": {
                    "pageouts": 0,
                    "swapins": 0,
                    "swapouts": 0,
                },
            }

        config = {
            "machine_state": paired._validate_machine_state({"mode": "publishable"})
        }
        first_entry = {"sequence_index": 0, "engine": "glacier"}
        second_entry = {"sequence_index": 1, "engine": "llama"}
        post = {"power": power, "thermal": thermal, "vm": vm}
        quiet_in_run = {
            "sample_count": 3,
            "monitor_errors": [],
            "external_cpu_capacity_median_percent": 1.0,
            "external_cpu_capacity_max_percent": 2.0,
        }
        sampler = mock.Mock()
        sampler.evidence.return_value = quiet_in_run

        def timed_sample(*_args, **kwargs):
            kwargs["after_timed_child"]()
            return {"success": True, "validation_errors": []}

        with (
            mock.patch.object(
                paired,
                "collect_machine_state_admission",
                side_effect=[admission(0.2), admission(0.8), admission(0.2)],
            ) as collect,
            mock.patch.object(
                paired, "collect_machine_state_post_observation", return_value=post
            ),
            mock.patch.object(
                paired,
                "run_timed_sample",
                side_effect=timed_sample,
            ) as timed,
            mock.patch.object(
                paired, "ExternalCpuSampler", return_value=sampler
            ),
        ):
            first, anchor = paired.run_machine_gated_sample(
                config,
                b"",
                Path("canonical"),
                Path("ids"),
                [],
                {},
                {},
                Path("sample-0"),
                first_entry,
                warmup=False,
                match_anchor=None,
            )
            self.assertTrue(first["success"])
            self.assertIsNotNone(anchor)
            second, _ = paired.run_machine_gated_sample(
                config,
                b"",
                Path("canonical"),
                Path("ids"),
                [],
                {},
                {},
                Path("sample-1"),
                second_entry,
                warmup=False,
                match_anchor=anchor,
            )
            wrong_engine, _ = paired.run_machine_gated_sample(
                config,
                b"",
                Path("canonical"),
                Path("ids"),
                [],
                {},
                {},
                Path("sample-wrong-engine"),
                {**second_entry, "engine": "glacier"},
                warmup=False,
                match_anchor=anchor,
            )
        self.assertEqual(collect.call_count, 3)
        self.assertEqual(timed.call_count, 1)
        self.assertFalse(second["success"])
        self.assertTrue(second["not_executed"])
        self.assertFalse(second["machine_state"]["pair_match"]["matched"])
        self.assertFalse(wrong_engine["success"])
        self.assertTrue(
            any(
                "different engines" in error
                for error in wrong_engine["validation_errors"]
            )
        )

    def test_machine_state_candidate_rejects_mismatched_in_run_cpu(self):
        power = {
            "source": "AC Power",
            "on_ac_power": True,
            "battery_present": True,
            "battery_full": True,
            "battery_status": "charged",
            "low_power_mode": 0,
            "active_settings_sha256": "settings-a",
        }
        thermal = {
            "signal_available": False,
            "constrained": None,
            "status": "unavailable",
        }
        vm = {"pageouts": 1, "swapins": 2, "swapouts": 3}
        admission = {
            "schema": paired.MACHINE_STATE_SCHEMA,
            "window": {
                "load1_median": 0.2,
                "load1_max": 0.3,
                "cpu_idle_median_percent": 95.0,
                "cpu_idle_min_percent": 90.0,
            },
            "before": {"power": power, "thermal": thermal, "vm": vm},
            "after": {"power": power, "thermal": thermal, "vm": vm},
            "window_vm_deltas": {
                "pageouts": 0,
                "swapins": 0,
                "swapouts": 0,
            },
        }
        anchor_sampler = mock.Mock()
        anchor_sampler.evidence.return_value = {
            "sample_count": 3,
            "monitor_errors": [],
            "external_cpu_capacity_median_percent": 1.0,
            "external_cpu_capacity_max_percent": 2.0,
        }
        candidate_sampler = mock.Mock()
        candidate_sampler.evidence.return_value = {
            "sample_count": 3,
            "monitor_errors": [],
            "external_cpu_capacity_median_percent": 7.0,
            "external_cpu_capacity_max_percent": 13.0,
        }

        def timed_sample(*_args, **kwargs):
            kwargs["after_timed_child"]()
            return {"success": True, "validation_errors": []}

        config = {
            "machine_state": paired._validate_machine_state(
                {"mode": "publishable"}
            )
        }
        with (
            mock.patch.object(
                paired,
                "collect_machine_state_admission",
                side_effect=[admission, admission],
            ),
            mock.patch.object(
                paired, "collect_machine_state_post_observation", return_value={
                    "power": power,
                    "thermal": thermal,
                    "vm": vm,
                }
            ),
            mock.patch.object(
                paired, "run_timed_sample", side_effect=timed_sample
            ) as timed,
            mock.patch.object(
                paired,
                "ExternalCpuSampler",
                side_effect=[anchor_sampler, candidate_sampler],
            ),
        ):
            first, anchor = paired.run_machine_gated_sample(
                config,
                b"",
                Path("canonical"),
                Path("ids"),
                [],
                {},
                {},
                Path("sample-0"),
                {"sequence_index": 0, "engine": "glacier"},
                warmup=False,
                match_anchor=None,
            )
            second, next_anchor = paired.run_machine_gated_sample(
                config,
                b"",
                Path("canonical"),
                Path("ids"),
                [],
                {},
                {},
                Path("sample-1"),
                {"sequence_index": 1, "engine": "llama"},
                warmup=False,
                match_anchor=anchor,
            )
        self.assertTrue(first["success"])
        self.assertEqual(timed.call_count, 2)
        self.assertFalse(second["success"])
        self.assertIsNone(next_anchor)
        self.assertFalse(second["machine_state"]["publication_eligible"])
        self.assertFalse(second["machine_state"]["pair_match"]["matched"])
        self.assertFalse(
            second["machine_state"]["pair_match"][
                "in_run_external_cpu_matched"
            ]
        )

    def test_manifest_required_fused_gqa_requires_strict_parallel_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["workload"]["require_fused_gqa"] = True
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "requires --require-prepared-image"
            ):
                paired.load_manifest(path)

            manifest["engines"]["glacier"]["argv"].extend(
                ["--require-prepared-image", "--serial-attention"]
            )
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                paired.HarnessError, "requires --parallel-attention-min-context"
            ):
                paired.load_manifest(path)

    def test_preflight_mismatch_fails_before_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root, mismatch=True))
            result = paired.run_harness(config, preflight_only=False)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["samples"], [])
            diff = result["tokenizer_preflight"]["commands"]["hf"]["first_difference"]
            self.assertEqual(diff["index"], 2)
            self.assertEqual(diff["expected"], 13)
            self.assertEqual(diff["actual"], 99)

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_timeout_kills_and_waits_for_descendants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "descendant-survived.txt"
            child_code = (
                "import pathlib,sys,time; time.sleep(0.4); "
                "pathlib.Path(sys.argv[1]).write_text('survived')"
            )
            parent_code = (
                "import subprocess,sys,time; "
                "subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]]); "
                "time.sleep(30)"
            )
            result = paired._run_process(
                [sys.executable, "-c", parent_code, child_code, str(marker)],
                root,
                os.environ,
                None,
                0.15,
            )
            self.assertTrue(result["timed_out"])
            self.assertIsNotNone(result["exit_status"])
            time.sleep(0.65)
            self.assertFalse(
                marker.exists(), "timed-out descendant escaped its process group"
            )

    def test_run_process_starts_and_stops_external_cpu_observer(self):
        events: list[tuple[str, int | None]] = []

        class Observer:
            def start(self, pgid):
                events.append(("start", pgid))

            def request_stop(self):
                events.append(("request_stop", None))

            def stop(self):
                events.append(("stop", None))
                return {"sample_count": 3, "monitor_errors": []}

        with tempfile.TemporaryDirectory() as temporary:
            result = paired._run_process(
                [sys.executable, "-c", "pass"],
                Path(temporary),
                os.environ,
                None,
                5.0,
                Observer(),
                lambda: events.append(("post", None)),
            )
        self.assertEqual(result["exit_status"], 0)
        self.assertGreater(events[0][1], 0)
        self.assertEqual(
            [name for name, _value in events],
            ["start", "request_stop", "post", "stop"],
        )
        self.assertEqual(result["process_observer"]["sample_count"], 3)

    def test_artifact_fingerprint_checks_bytes_and_optional_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "tool"
            artifact.write_bytes(b"artifact bytes\n")
            artifact.chmod(0o755)
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            config = {
                "artifacts": {
                    "tool": {
                        "path": str(artifact),
                        "kind": "executable",
                        "expected_sha256": digest,
                    }
                }
            }
            result = paired.fingerprint_artifacts(config)
            self.assertEqual(result["tool"]["bytes"], len(b"artifact bytes\n"))
            self.assertEqual(result["tool"]["sha256"], digest)
            config["artifacts"]["tool"]["expected_sha256"] = "0" * 64
            with self.assertRaises(paired.HarnessError):
                paired.fingerprint_artifacts(config)

    def test_manifest_rejects_raw_completion_without_token_id_extractor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text())
            manifest["engines"]["llama"]["completion"] = {
                "source": "stdout",
                "format": "raw",
                "strip_exactly_one_final_lf": True,
            }
            path.write_text(json.dumps(manifest))
            with self.assertRaises(paired.HarnessError):
                paired.load_manifest(path)
            manifest["samples_per_engine"] = 4
            manifest["drop_caches"] = True
            path.write_text(json.dumps(manifest))
            with self.assertRaises(paired.HarnessError):
                paired.load_manifest(path)

    def test_timed_sample_isolates_time_metrics_from_child_stderr_spoof(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            config["engines"]["glacier"].update(
                {
                    "argv": ["fake-engine", "{sample_dir}/completion.ids"],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            work = root / "runtime"
            work.mkdir()
            canonical_path, pinned_path, runtime_fixture = (
                paired.materialize_runtime_fixtures(work, b"hello\n", [1, 2, 13])
            )
            artifact_fingerprints = paired.fingerprint_artifacts(config)
            sample_dir = root / "stderr-spoof"
            entry = {
                "sequence_index": 0,
                "block_index": 0,
                "position_in_block": 0,
                "pattern": "ABBA",
                "engine": "glacier",
                "engine_sample_index": 0,
            }

            def fake_process(
                argv,
                _cwd,
                _env,
                _stdin,
                _timeout,
                _observer=None,
                _after_exit=None,
            ):
                self.assertEqual(argv[:3], ["/usr/bin/time", "-l", "-o"])
                time_output_path = Path(argv[3])
                self.assertEqual(time_output_path.parent, sample_dir.resolve())
                self.assertTrue(time_output_path.is_file())
                self.assertEqual(time_output_path.stat().st_size, 0)
                Path(argv[-1]).write_text("7 8\n", encoding="utf-8")
                time_output_path.write_text(
                    "0.25 real 0.20 user 0.05 sys\n"
                    "123456 maximum resident set size\n"
                    "654321 peak memory footprint\n",
                    encoding="utf-8",
                )
                return {
                    "exit_status": 0,
                    "timed_out": False,
                    "launch_error": None,
                    "harness_wall_seconds": 0.5,
                    "stdout_bytes": (
                        b"time: 20.00 ms (100.0 tok/s, prefilled 3, "
                        b"prefill=batch)\n"
                    ),
                    "stderr_bytes": (
                        b"999.99 real 0.01 user 0.01 sys\n"
                        b"999999999 maximum resident set size\n"
                    ),
                }

            with mock.patch.object(paired, "_run_process", side_effect=fake_process):
                sample = paired.run_timed_sample(
                    config,
                    b"hello\n",
                    canonical_path,
                    pinned_path,
                    [1, 2, 13],
                    runtime_fixture,
                    artifact_fingerprints,
                    sample_dir,
                    entry,
                    warmup=False,
                )

            self.assertTrue(sample["success"], sample["validation_errors"])
            self.assertIn("999.99 real", sample["raw_stderr"])
            self.assertEqual(sample["metrics"]["time_l_wall_seconds"], 0.25)
            self.assertEqual(sample["metrics"]["peak_rss_bytes"], 123456)
            evidence = sample["time_l_evidence"]
            self.assertNotIn("999.99 real", evidence["raw_output"])
            self.assertEqual(evidence["validation_errors"], [])
            self.assertEqual(
                evidence["created_file_identity"]["inode"],
                evidence["observed_file_identity"]["inode"],
            )

    def test_time_l_reader_rejects_same_inode_metadata_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "time.txt"
            path.write_text(
                "0.25 real 0.20 user 0.05 sys\n"
                "123456 maximum resident set size\n",
                encoding="utf-8",
            )
            before = path.stat()
            after = SimpleNamespace(
                st_dev=before.st_dev,
                st_ino=before.st_ino,
                st_mode=before.st_mode,
                st_size=before.st_size,
                st_mtime_ns=before.st_mtime_ns + 1,
                st_ctime_ns=before.st_ctime_ns,
            )
            identity = {
                "device": before.st_dev,
                "inode": before.st_ino,
                "mode": before.st_mode,
            }
            with (
                mock.patch.object(paired.os, "fstat", side_effect=[before, after]),
                self.assertRaisesRegex(paired.HarnessError, "changed while being read"),
            ):
                paired._read_time_l_output(path, identity)

    def test_raw_completion_extractor_runs_only_after_timed_schedule(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            config["engines"]["llama"]["completion"] = {
                "source": "stdout",
                "format": "raw",
                "strip_exactly_one_final_lf": True,
                "token_id_extractor": {
                    "argv": [sys.executable, "-c", "print('7 8')"],
                    "cwd": str(root),
                    "env": {},
                    "timeout_seconds": 10.0,
                    "stdin": "none",
                    "ids_stream": "stdout",
                    "ids_format": "plain",
                },
            }
            work = root / "runtime"
            work.mkdir()
            canonical_path, pinned_path, runtime_fixture = (
                paired.materialize_runtime_fixtures(work, b"hello\n", [1, 2, 13])
            )
            fingerprints = paired.fingerprint_artifacts(config)
            sample_dir = root / "hook-order"
            entry = {
                "sequence_index": 0,
                "block_index": 0,
                "position_in_block": 0,
                "pattern": "ABBA",
                "engine": "llama",
                "engine_sample_index": 0,
            }
            events: list[str] = []
            deferred: list[dict[str, object]] = []

            def fake_process(
                argv,
                _cwd,
                _env,
                _stdin,
                _timeout,
                _observer=None,
                after_exit=None,
            ):
                Path(argv[3]).write_text(
                    "0.25 real 0.20 user 0.05 sys\n"
                    "123456 maximum resident set size\n",
                    encoding="utf-8",
                )
                events.append("timed-child-finished")
                if after_exit is not None:
                    after_exit()
                return {
                    "exit_status": 0,
                    "timed_out": False,
                    "launch_error": None,
                    "harness_wall_seconds": 0.5,
                    "stdout_bytes": b"generated text\n",
                    "stderr_bytes": (
                        b"prompt eval time = 5.00 ms / 3 tokens\n"
                        b"eval time = 15.00 ms / 1 runs\n"
                    ),
                }

            def fake_extractor(*_args, **_kwargs):
                events.append("completion-extractor-started")
                return [7, 8], {"error": None}

            with (
                mock.patch.object(paired, "_run_process", side_effect=fake_process),
                mock.patch.object(
                    paired, "_run_completion_extractor", side_effect=fake_extractor
                ),
            ):
                sample = paired.run_timed_sample(
                    config,
                    b"hello\n",
                    canonical_path,
                    pinned_path,
                    [1, 2, 13],
                    runtime_fixture,
                    fingerprints,
                    sample_dir,
                    entry,
                    warmup=False,
                    after_timed_child=lambda: events.append(
                        "post-state-collected"
                    ),
                    deferred_completion_queue=deferred,
                )

            self.assertEqual(
                events,
                [
                    "timed-child-finished",
                    "post-state-collected",
                ],
            )
            self.assertTrue(sample["completion_validation_pending"])
            self.assertEqual(len(deferred), 1)
            with mock.patch.object(
                paired, "_run_completion_extractor", side_effect=fake_extractor
            ):
                failures = paired.finalize_deferred_completions(deferred, 2)
            self.assertEqual(failures, [])
            self.assertEqual(
                events,
                [
                    "timed-child-finished",
                    "post-state-collected",
                    "completion-extractor-started",
                ],
            )
            self.assertFalse(sample["completion_validation_pending"])
            self.assertTrue(sample["success"], sample["validation_errors"])

    @unittest.skipUnless(
        platform.system() == "Darwin", "requires macOS /usr/bin/time -l"
    )
    def test_timed_sample_requires_telemetry_and_exact_extracted_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            extractor = {
                "argv": [sys.executable, "-c", "print('[7, 8]')"],
                "cwd": "{repo_root}",
                "env": {},
                "timeout_seconds": 10.0,
                "ids_format": "json-array",
                "ids_stream": "stdout",
            }
            config["engines"]["llama"].update(
                {
                    "argv": [sys.executable, "-c", "print('completion')"],
                    "completion": {
                        "source": "stdout",
                        "format": "raw",
                        "strip_exactly_one_final_lf": True,
                        "token_id_extractor": extractor,
                    },
                }
            )
            work = root / "runtime"
            work.mkdir()
            canonical_path, pinned_path, runtime_fixture = (
                paired.materialize_runtime_fixtures(work, b"hello\n", [1, 2, 13])
            )
            artifact_fingerprints = paired.fingerprint_artifacts(config)
            entry = {
                "sequence_index": 0,
                "block_index": 0,
                "position_in_block": 0,
                "pattern": "ABBA",
                "engine": "llama",
                "engine_sample_index": 0,
            }
            missing = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                artifact_fingerprints,
                root / "missing-telemetry",
                entry,
                warmup=False,
            )
            self.assertFalse(missing["success"])
            self.assertIn(
                "required llama.cpp prompt eval count telemetry is missing",
                missing["validation_errors"],
            )
            self.assertIn(
                "required llama.cpp eval count telemetry is missing",
                missing["validation_errors"],
            )

            config["engines"]["llama"]["argv"] = [
                sys.executable,
                "-c",
                "import sys; print('completion'); "
                "print('prompt eval time = 5.00 ms / 3 tokens', file=sys.stderr); "
                "print('eval time = 15.00 ms / 1 runs', file=sys.stderr)",
            ]
            config["engines"]["llama"]["completion"]["token_id_extractor"] = {
                **extractor,
                "argv": [sys.executable, "-c", "print('[7]')"],
            }
            wrong_count = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                artifact_fingerprints,
                root / "wrong-count",
                entry,
                warmup=False,
            )
            self.assertFalse(wrong_count["success"])
            self.assertIn(
                "completion token count was 1, expected 2",
                wrong_count["validation_errors"],
            )

            config["engines"]["glacier"].update(
                {
                    "argv": [sys.executable, "-c", "print('7 8')"],
                    "completion": {
                        "source": "stdout",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            glacier_entry = {**entry, "engine": "glacier"}
            missing_glacier = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                artifact_fingerprints,
                root / "missing-glacier-telemetry",
                glacier_entry,
                warmup=False,
            )
            self.assertFalse(missing_glacier["success"])
            self.assertIn(
                "required Glacier internal time/prefill telemetry is missing",
                missing_glacier["validation_errors"],
            )
            config["workload"]["require_fused_gqa"] = True
            fused_without_prepared = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                artifact_fingerprints,
                root / "fused-without-prepared",
                glacier_entry,
                warmup=False,
            )
            self.assertFalse(fused_without_prepared["success"])
            self.assertIn(
                "manifest.workload.require_fused_gqa requires --require-prepared-image",
                fused_without_prepared["validation_errors"],
            )
            config["workload"]["require_fused_gqa"] = False

            strict_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7 8\\n'); "
                "print('load: mode=prepared artifact=glrt ms=2.00'); "
                "print('ready: phase=request_ready ms=3.00'); "
                "print('time: 20.00 ms (100.0 tok/s, prefilled 3, prefill=batch)')"
            )
            config["engines"]["glacier"].update(
                {
                    "argv": [
                        sys.executable,
                        "-c",
                        strict_code,
                        "{sample_dir}/completion.ids",
                        "--require-prepared-image",
                        "--serial-attention",
                    ],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            missing_phases = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                artifact_fingerprints,
                root / "missing-glacier-phases",
                glacier_entry,
                warmup=False,
            )
            self.assertFalse(missing_phases["success"])
            self.assertIn(
                "required Glacier phase telemetry is missing or duplicated",
                missing_phases["validation_errors"],
            )

            mismatch_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7 8\\n'); "
                "print('load: mode=prepared artifact=glrt ms=2.00'); "
                "print('schedule: attention=parallel min_context=128 layers=24'); "
                "print('ready: phase=request_ready ms=3.00'); "
                "print('phases: prefill_ms=4.000 decode_ms=10.000 sampling_ms=0.100 decode_runs=1 attention_graphs=1 attention_dispatches=24 handoff_graphs=1 handoff_dispatches=24 fused_gqa_graphs=1 fused_gqa_dispatches=24 paired_mlp_graphs=1 paired_mlp_dispatches=24'); "
                "print('time: 20.00 ms (100.0 tok/s, prefilled 3, prefill=batch)')"
            )
            config["engines"]["glacier"]["argv"] = [
                sys.executable,
                "-c",
                mismatch_code,
                "{sample_dir}/completion.ids",
                "--require-prepared-image",
                "--serial-attention",
            ]
            schedule_mismatch = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                artifact_fingerprints,
                root / "mismatched-glacier-schedule",
                glacier_entry,
                warmup=False,
            )
            self.assertFalse(schedule_mismatch["success"])
            self.assertIn(
                "Glacier attention schedule telemetry did not confirm --serial-attention",
                schedule_mismatch["validation_errors"],
            )
            self.assertIn(
                "Glacier decode graph count was None, expected 1 for 2 completions",
                missing_phases["validation_errors"],
            )

    def test_exact_equivalence_compares_full_generated_id_lists(self):
        samples = []
        for block, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                engine = "glacier" if letter == "A" else "llama"
                ids = [7, 8] if engine == "glacier" else [7, 9]
                samples.append(
                    {
                        "block_index": block,
                        "engine": engine,
                        "metrics": {
                            "wall_seconds": 1.0,
                            "peak_rss_bytes": 100.0,
                            "effective_completion_tokens_per_second": 2.0,
                        },
                        "completion": {
                            "token_ids": ids,
                            "comparison_sha256": paired.sha256_bytes(
                                paired._canonical_ids_bytes(ids)
                            ),
                        },
                    }
                )
        config = {
            "workload": {"completion_equivalence": "exact-token-ids"},
            "statistics": {
                "bootstrap_resamples": 100,
                "bootstrap_seed": 7,
                "confidence": 0.95,
            },
        }
        summary = paired.summarize_samples(config, samples)
        equivalence = summary["completion_equivalence"]
        self.assertTrue(equivalence["cross_engine_token_ids_compared"])
        self.assertFalse(equivalence["cross_engine_token_ids_match"])
        self.assertFalse(equivalence["output_equivalence_certified"])
        self.assertFalse(equivalence["quality_certified"])
        self.assertEqual(equivalence["first_cross_engine_difference"]["index"], 1)

    @unittest.skipUnless(
        platform.system() == "Darwin", "requires macOS /usr/bin/time -l"
    )
    def test_generated_text_cannot_spoof_engine_telemetry(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as cleanup:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            work = root / "runtime"
            work.mkdir()
            canonical_path, pinned_path, runtime_fixture = (
                paired.materialize_runtime_fixtures(work, b"hello\n", [1, 2, 13])
            )
            cleanup.callback(
                paired.restore_runtime_fixture_permissions, runtime_fixture
            )
            fingerprints = paired.fingerprint_artifacts(config)
            glacier_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7 8\\n'); "
                "print('time: 1.00 ms (999.0 tok/s, prefilled 999, prefill=serial)'); "
                "print('time: 20.00 ms (100.0 tok/s, prefilled 3, prefill=batch)')"
            )
            config["engines"]["glacier"].update(
                {
                    "argv": [
                        sys.executable,
                        "-c",
                        glacier_code,
                        "{sample_dir}/completion.ids",
                    ],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            entry = {
                "sequence_index": 0,
                "block_index": 0,
                "position_in_block": 0,
                "pattern": "ABBA",
                "engine": "glacier",
                "engine_sample_index": 0,
            }
            glacier = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                fingerprints,
                root / "glacier-spoof",
                entry,
                warmup=False,
            )
            self.assertFalse(glacier["success"])
            self.assertEqual(glacier["metrics"]["glacier_prefilled_tokens"], 3)
            self.assertEqual(glacier["metrics"]["glacier_prefill_mode"], "batch")
            self.assertEqual(glacier["metrics"]["glacier_telemetry_line_count"], 2)
            self.assertIn(
                "required Glacier internal timing telemetry is duplicated",
                glacier["validation_errors"],
            )

            llama_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7 8\\n'); "
                "print('prompt eval time = 1.00 ms / 999 tokens'); "
                "print('eval time = 1.00 ms / 999 runs'); "
                "print('0.02.119.284 I common_perf_print: prompt eval time = 5.00 ms / 3 tokens', file=sys.stderr); "
                "print('0.02.119.285 I common_perf_print: eval time = 15.00 ms / 1 runs', file=sys.stderr)"
            )
            config["engines"]["llama"].update(
                {
                    "argv": [
                        sys.executable,
                        "-c",
                        llama_code,
                        "{sample_dir}/completion.ids",
                    ],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            llama = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                fingerprints,
                root / "llama-spoof",
                {**entry, "engine": "llama"},
                warmup=False,
            )
            self.assertTrue(llama["success"])
            self.assertEqual(llama["metrics"]["llama_prompt_eval_tokens"], 3)
            self.assertEqual(llama["metrics"]["llama_eval_runs"], 1)
            self.assertEqual(llama["metrics"]["llama_prompt_telemetry_line_count"], 1)

            llama_duplicate_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7 8\\n'); "
                "print('prompt eval time = 5.00 ms / 3 tokens', file=sys.stderr); "
                "print('prompt eval time = 5.00 ms / 3 tokens', file=sys.stderr); "
                "print('eval time = 15.00 ms / 1 runs', file=sys.stderr); "
                "print('eval time = 15.00 ms / 1 runs', file=sys.stderr)"
            )
            config["engines"]["llama"]["argv"] = [
                sys.executable,
                "-c",
                llama_duplicate_code,
                "{sample_dir}/completion.ids",
            ]
            duplicate_llama = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                fingerprints,
                root / "llama-duplicate-telemetry",
                {**entry, "engine": "llama"},
                warmup=False,
            )
            self.assertFalse(duplicate_llama["success"])
            self.assertIn(
                "llama.cpp prompt eval telemetry is missing or duplicated",
                duplicate_llama["validation_errors"],
            )
            self.assertIn(
                "llama.cpp eval telemetry is missing or duplicated",
                duplicate_llama["validation_errors"],
            )

            config["workload"]["completion_tokens"] = 1
            one_token_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7\\n'); "
                "print('0.02.119.284 I common_perf_print: prompt eval time = 5.00 ms / 3 tokens', file=sys.stderr); "
                "print('0.02.119.285 I common_perf_print: eval time = 5.00 ms / 1 runs', file=sys.stderr)"
            )
            config["engines"]["llama"]["argv"] = [
                sys.executable,
                "-c",
                one_token_code,
                "{sample_dir}/completion.ids",
            ]
            one_token = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                fingerprints,
                root / "llama-one-token",
                {**entry, "engine": "llama", "engine_sample_index": 1},
                warmup=False,
            )
            self.assertTrue(one_token["success"])
            self.assertEqual(one_token["metrics"]["llama_eval_runs"], 1)

            one_token_zero_duration_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('7\\n'); "
                "print('0.02.119.284 I common_perf_print: prompt eval time = 5.00 ms / 3 tokens (1.67 ms per token, 600.00 tokens per second)', file=sys.stderr); "
                "print('0.02.119.285 I common_perf_print: eval time = 0.00 ms / 1 runs (0.00 ms per token, inf tokens per second)', file=sys.stderr)"
            )
            config["engines"]["llama"]["argv"] = [
                sys.executable,
                "-c",
                one_token_zero_duration_code,
                "{sample_dir}/completion.ids",
            ]
            one_token_zero_duration = paired.run_timed_sample(
                config,
                b"hello\n",
                canonical_path,
                pinned_path,
                [1, 2, 13],
                runtime_fixture,
                fingerprints,
                root / "llama-one-token-zero-duration",
                {**entry, "engine": "llama", "engine_sample_index": 2},
                warmup=False,
            )
            self.assertTrue(one_token_zero_duration["success"])
            zero_metrics = one_token_zero_duration["metrics"]
            self.assertEqual(zero_metrics["llama_eval_ms"], 0.0)
            self.assertEqual(zero_metrics["llama_eval_runs"], 1)
            self.assertIsNone(zero_metrics["llama_eval_tokens_per_second"])
            self.assertNotIn("decode_phase_ms", zero_metrics)
            self.assertNotIn("decode_graph_tokens_per_second", zero_metrics)

    @unittest.skipUnless(
        platform.system() == "Darwin", "requires macOS /usr/bin/time -l"
    )
    def test_fixture_replace_and_artifact_toctou_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as cleanup:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            work = root / "runtime"
            work.mkdir()
            canonical_path, pinned_path, runtime_fixture = (
                paired.materialize_runtime_fixtures(work, b"hello\n", [1, 2, 13])
            )
            cleanup.callback(
                paired.restore_runtime_fixture_permissions, runtime_fixture
            )
            fingerprints = paired.fingerprint_artifacts(config)
            tamper_code = (
                "import os,pathlib,sys; p=pathlib.Path(sys.argv[1]); "
                "os.chmod(p.parent, 0o755); p.unlink(); p.write_text('9\\n'); "
                "pathlib.Path(sys.argv[2]).write_text('7 8\\n'); "
                "print('time: 20.00 ms (100.0 tok/s, prefilled 3, prefill=batch)')"
            )
            config["engines"]["glacier"].update(
                {
                    "argv": [
                        sys.executable,
                        "-c",
                        tamper_code,
                        "{pinned_token_ids_path}",
                        "{sample_dir}/completion.ids",
                    ],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            entry = {
                "sequence_index": 0,
                "block_index": 0,
                "position_in_block": 0,
                "pattern": "ABBA",
                "engine": "glacier",
                "engine_sample_index": 0,
            }
            with self.assertRaisesRegex(
                paired.HarnessError, "runtime fixture (directory )?identity changed"
            ):
                paired.run_timed_sample(
                    config,
                    b"hello\n",
                    canonical_path,
                    pinned_path,
                    [1, 2, 13],
                    runtime_fixture,
                    fingerprints,
                    root / "fixture-tamper",
                    entry,
                    warmup=False,
                )

        with tempfile.TemporaryDirectory() as temporary, ExitStack() as cleanup:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            mutable = root / "mutable.model"
            mutable.write_bytes(b"before")
            config["artifacts"]["mutable"] = {
                "path": str(mutable),
                "kind": "model",
                "expected_sha256": None,
            }
            work = root / "runtime"
            work.mkdir()
            canonical_path, pinned_path, runtime_fixture = (
                paired.materialize_runtime_fixtures(work, b"hello\n", [1, 2, 13])
            )
            cleanup.callback(
                paired.restore_runtime_fixture_permissions, runtime_fixture
            )
            fingerprints = paired.fingerprint_artifacts(config)
            tamper_code = (
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'after!'); "
                "pathlib.Path(sys.argv[2]).write_text('7 8\\n'); "
                "print('time: 20.00 ms (100.0 tok/s, prefilled 3, prefill=batch)')"
            )
            config["engines"]["glacier"].update(
                {
                    "argv": [
                        sys.executable,
                        "-c",
                        tamper_code,
                        "{mutable}",
                        "{sample_dir}/completion.ids",
                    ],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            with self.assertRaisesRegex(
                paired.HarnessError, "artifact mutable filesystem identity changed"
            ):
                paired.run_timed_sample(
                    config,
                    b"hello\n",
                    canonical_path,
                    pinned_path,
                    [1, 2, 13],
                    runtime_fixture,
                    fingerprints,
                    root / "artifact-tamper",
                    entry,
                    warmup=False,
                )

    def test_effective_environment_is_minimal_and_reproducibly_hashed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            command = dict(config["engines"]["glacier"])
            command["env"] = {"OMP_NUM_THREADS": "4"}
            with mock.patch.dict(
                os.environ, {"LLAMA_ARG_FA": "on", "UNRELATED_SECRET": "hidden"}
            ):
                _argv, _cwd, env, _context = paired.expand_command(
                    config,
                    command,
                    root / "canonical.txt",
                    root / "ids.txt",
                    root / "sample",
                    "glacier",
                    0,
                )
            self.assertNotIn("LLAMA_ARG_FA", env)
            self.assertNotIn("UNRELATED_SECRET", env)
            self.assertEqual(env["OMP_NUM_THREADS"], "4")
            snapshot = paired.environment_snapshot(env)
            self.assertEqual(snapshot["visible"]["OMP_NUM_THREADS"], "4")
            self.assertEqual(snapshot["redacted"], {})
            self.assertEqual(snapshot, paired.environment_snapshot(env))

            manifest_path = self._write_manifest(root)
            manifest = json.loads(manifest_path.read_text())
            manifest["engines"]["glacier"]["env"] = {
                "LLAMA_ARG_HF_TOKEN": "must-not-leak"
            }
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                paired.HarnessError,
                "secrets are forbidden in benchmark manifests",
            ):
                paired.load_manifest(manifest_path)

    @unittest.skipUnless(
        platform.system() == "Darwin", "requires macOS /usr/bin/time -l"
    )
    def test_lightweight_timed_path_captures_rss_hashes_and_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = paired.load_manifest(self._write_manifest(root))
            glacier_code = (
                "import os,pathlib,sys; "
                "pathlib.Path(sys.argv[1]).write_text('7 8\\n'); "
                "assert pathlib.Path(sys.argv[2]).read_text() == '1 2 13\\n'; "
                "assert (pathlib.Path(sys.argv[2]).stat().st_mode & 0o777) == 0o444; "
                "print('phases: prefill_ms=4.000 decode_ms=10.000 sampling_ms=0.100 decode_runs=1 attention_graphs=0 attention_dispatches=0 handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 fused_gqa_dispatches=0 paired_mlp_graphs=0 paired_mlp_dispatches=0'); "
                "print('time: 20.00 ms (100.0 tok/s, prefilled 3, prefill=batch)')"
            )
            llama_code = (
                "import sys; print('stable completion'); "
                "print('prompt eval time = 5.00 ms / 3 tokens (1.67 ms per token, 600.00 tokens per second)', file=sys.stderr); "
                "print('eval time = 15.00 ms / 1 runs (15.00 ms per token, 66.67 tokens per second)', file=sys.stderr)"
            )
            config["engines"]["glacier"].update(
                {
                    "argv": [
                        sys.executable,
                        "-c",
                        glacier_code,
                        "{sample_dir}/completion.ids",
                        "{pinned_token_ids_path}",
                    ],
                    "completion": {
                        "source": "file",
                        "path": "{sample_dir}/completion.ids",
                        "format": "token_ids",
                        "ids_format": "plain",
                    },
                }
            )
            config["engines"]["llama"].update(
                {
                    "argv": [sys.executable, "-c", llama_code],
                    "completion": {
                        "source": "stdout",
                        "format": "raw",
                        "strip_exactly_one_final_lf": True,
                        "token_id_extractor": {
                            "argv": [sys.executable, "-c", "print('[7, 8]')"],
                            "cwd": "{repo_root}",
                            "env": {},
                            "timeout_seconds": 10.0,
                            "ids_format": "json-array",
                            "ids_stream": "stdout",
                        },
                    },
                }
            )
            result = paired.run_harness(config, preflight_only=False)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmup_samples"]), 2)
            self.assertTrue(
                all(
                    sample["metrics"]["peak_rss_bytes"] > 0
                    for sample in result["samples"]
                )
            )
            self.assertTrue(
                all(
                    len(sample["completion"]["token_ids"]) == 2
                    for sample in result["samples"]
                )
            )
            self.assertEqual(
                result["summary"]["per_engine"]["glacier"]["sample_count"], 4
            )
            self.assertIn("wall_seconds", result["summary"]["glacier_advantage_ratios"])
            ratios = result["summary"]["glacier_advantage_ratios"]
            self.assertEqual(ratios["prefill_phase_ms"]["estimate"], 1.25)
            self.assertEqual(ratios["decode_phase_ms"]["estimate"], 1.5)
            self.assertEqual(ratios["decode_graph_tokens_per_second"]["estimate"], 1.5)
            glacier_metrics = result["summary"]["per_engine"]["glacier"]["metrics"]
            self.assertEqual(glacier_metrics["decode_graph_runs"]["median"], 1.0)
            self.assertTrue(
                result["summary"]["completion_equivalence"]["performance_only"]
            )
            self.assertFalse(
                result["summary"]["completion_equivalence"]["quality_certified"]
            )
            self.assertIn("python_runtime", result["artifact_fingerprints"])
            self.assertEqual(
                result["artifact_fingerprints"]["python_runtime"]["bytes"],
                Path(sys.executable).stat().st_size,
            )
            self.assertTrue(
                result["artifact_post_run_verification"]["full_hash_checked"]
            )
            self.assertEqual(
                result["artifact_post_run_verification"]["artifacts"]["python_runtime"][
                    "sha256"
                ],
                result["artifact_fingerprints"]["python_runtime"]["sha256"],
            )

    def test_manifest_rejects_unbalanced_count_and_unknown_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text())
            manifest["samples_per_engine"] = 6
            path.write_text(json.dumps(manifest))
            with self.assertRaises(paired.HarnessError):
                paired.load_manifest(path)

    def test_strict_prepared_manifest_requires_explicit_attention_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text())
            manifest["engines"]["glacier"]["argv"].append("--require-prepared-image")
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                paired.HarnessError, "must declare exactly one"
            ):
                paired.load_manifest(path)

            manifest["engines"]["glacier"]["argv"].extend(
                ["--parallel-attention-min-context", "128"]
            )
            path.write_text(json.dumps(manifest))
            config = paired.load_manifest(path)
            self.assertIn(
                "--parallel-attention-min-context",
                config["engines"]["glacier"]["argv"],
            )

            manifest["engines"]["glacier"]["argv"].append("--serial-attention")
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                paired.HarnessError, "must declare exactly one"
            ):
                paired.load_manifest(path)

            manifest["engines"]["glacier"]["argv"] = [
                sys.executable,
                "-c",
                "print('1 2')",
                "--require-prepared-image",
                "--serial-attention",
                "--serial-attention",
            ]
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                paired.HarnessError, "must declare exactly one"
            ):
                paired.load_manifest(path)

            manifest["engines"]["glacier"]["argv"] = [
                sys.executable,
                "-c",
                "print('1 2')",
                "--require-prepared-image",
                "--parallel-attention-min-context",
                "nan",
            ]
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                paired.HarnessError, "requires a positive integer"
            ):
                paired.load_manifest(path)

    def test_exact_id_mode_rejects_decoded_text_extractor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self._write_manifest(root)
            manifest = json.loads(path.read_text())
            manifest["engines"]["llama"]["completion"] = {
                "source": "stdout",
                "format": "raw",
                "strip_exactly_one_final_lf": True,
                "token_id_extractor": {
                    "argv": [sys.executable, "-c", "print('[1, 2]')"],
                    "ids_format": "json-array",
                    "ids_stream": "stdout",
                },
            }
            manifest["workload"]["completion_equivalence"] = "exact-token-ids"
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                paired.HarnessError, "requires native token_ids completion output"
            ):
                paired.load_manifest(path)


if __name__ == "__main__":
    unittest.main()
