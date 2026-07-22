import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


BENCH_DIR = Path(__file__).resolve().parents[1]
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))
MODULE_PATH = BENCH_DIR / "resource_ab.py"
SPEC = importlib.util.spec_from_file_location("resource_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
resource_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = resource_ab
SPEC.loader.exec_module(resource_ab)


TIME_RECORD = """\
real 1.25
user 3.50
sys 0.25
             426328064  maximum resident set size
                     0  average shared memory size
                     0  average unshared data size
                     0  average unshared stack size
                  1234  page reclaims
                     7  page faults
                     0  swaps
                     1  block input operations
                     2  block output operations
                     0  messages sent
                     0  messages received
                     0  signals received
                    44  voluntary context switches
                    55  involuntary context switches
            9876543210  instructions retired
            8765432109  cycles elapsed
              25675488  peak memory footprint
"""


class ResourceAbTests(unittest.TestCase):
    def test_decode_plan_harness_error_is_reported_without_traceback(self):
        parser = mock.Mock()
        parser.parse_args.return_value = object()
        config = mock.Mock(output=None)
        stderr = io.StringIO()
        with (
            mock.patch.object(resource_ab, "argument_parser", return_value=parser),
            mock.patch.object(resource_ab, "config_from_args", return_value=config),
            mock.patch.object(
                resource_ab,
                "run_benchmark",
                side_effect=resource_ab.decode_plan.HarnessError(
                    "malformed DecodePlan telemetry"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            self.assertEqual(resource_ab.main([]), 2)
        self.assertEqual(
            stderr.getvalue(),
            "resource benchmark failed: malformed DecodePlan telemetry\n",
        )

    def test_greedy_harness_error_is_reported_without_traceback(self):
        parser = mock.Mock()
        parser.parse_args.return_value = object()
        config = mock.Mock(output=None)
        stderr = io.StringIO()
        with (
            mock.patch.object(resource_ab, "argument_parser", return_value=parser),
            mock.patch.object(resource_ab, "config_from_args", return_value=config),
            mock.patch.object(
                resource_ab,
                "run_benchmark",
                side_effect=resource_ab.greedy_output.HarnessError(
                    "malformed greedy-output telemetry"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            self.assertEqual(resource_ab.main([]), 2)
        self.assertEqual(
            stderr.getvalue(),
            "resource benchmark failed: malformed greedy-output telemetry\n",
        )

    def test_time_lp_parser_is_strict_and_derives_cpu_time(self):
        parsed = resource_ab.parse_time_output(TIME_RECORD)
        self.assertEqual(parsed["time_real_seconds"], 1.25)
        self.assertEqual(parsed["time_user_seconds"], 3.5)
        self.assertEqual(parsed["time_sys_seconds"], 0.25)
        self.assertEqual(parsed["time_cpu_seconds"], 3.75)
        self.assertEqual(parsed["time_maximum_resident_set_size_bytes"], 426_328_064)
        self.assertEqual(parsed["time_instructions_retired"], 9_876_543_210)
        self.assertEqual(parsed["time_cycles_elapsed"], 8_765_432_109)

        invalid = {
            "missing": TIME_RECORD.replace(
                "            9876543210  instructions retired\n", ""
            ),
            "duplicate": "real 9.00\n" + TIME_RECORD,
            "unknown": TIME_RECORD.replace("cycles elapsed", "mystery cycles"),
            "negative": TIME_RECORD.replace(
                "            8765432109  cycles elapsed",
                "                    -1  cycles elapsed",
            ),
            "one_decimal_clock": TIME_RECORD.replace("real 1.25", "real 1.2"),
            "three_decimal_clock": TIME_RECORD.replace("real 1.25", "real 1.250"),
            "integer_clock": TIME_RECORD.replace("real 1.25", "real 1"),
        }
        for name, record in invalid.items():
            with self.subTest(name=name):
                with self.assertRaises(resource_ab.common.HarnessError):
                    resource_ab.parse_time_output(record)

    def test_cross_field_metric_relations_fail_closed(self):
        telemetry = {
            "prefill_ms": 4.0,
            "decode_ms": 10.0,
            "sampling_ms": 0.1,
            "internal_ms": 14.10,
            "internal_tokens_per_second": 283.7,
        }
        resources = {"time_real_seconds": 0.20}
        derived = resource_ab._validate_metric_relations(
            telemetry,
            resources,
            completion_tokens=4,
            harness_wall_seconds=0.22,
        )
        self.assertAlmostEqual(derived["phase_sum_ms"], 14.1)

        rounding_boundary = {
            **telemetry,
            "decode_ms": 9.996,
            "internal_ms": 14.09,
            "internal_tokens_per_second": 283.9,
        }
        resource_ab._validate_metric_relations(
            rounding_boundary,
            resources,
            completion_tokens=4,
            harness_wall_seconds=0.22,
        )
        resource_ab._validate_metric_relations(
            {**telemetry, "internal_ms": 210.00, "internal_tokens_per_second": 19.0},
            resources,
            completion_tokens=4,
            harness_wall_seconds=0.22,
        )
        # Real PP2048 evidence exposed a bounded cross-clock lead: Darwin time
        # printed 16.35 s while the enclosing monotonic read was 16.32642675 s.
        # It is inside the explicit 50 ms lead envelope and must not discard an
        # otherwise exact long-prompt observation.
        resource_ab._validate_metric_relations(
            telemetry,
            {"time_real_seconds": 16.35},
            completion_tokens=4,
            harness_wall_seconds=16.32642675,
        )
        resource_ab._validate_metric_relations(
            {**telemetry, "internal_ms": 209.99, "internal_tokens_per_second": 19.0},
            resources,
            completion_tokens=4,
            harness_wall_seconds=0.16,
        )

        invalid = {
            "phase_sum": (
                {**rounding_boundary, "decode_ms": 9.997},
                resources,
                0.22,
            ),
            "throughput": (
                {**telemetry, "internal_tokens_per_second": 999.0},
                resources,
                0.22,
            ),
            "uses_n_minus_one_for_throughput": (
                {**telemetry, "internal_tokens_per_second": 212.8},
                resources,
                0.22,
            ),
            "real_exceeds_outer_wall": (telemetry, resources, 0.14),
            "wrapper_overhead": (telemetry, resources, 0.47),
            "internal_exceeds_outer_wall_lead": (
                {
                    **telemetry,
                    "internal_ms": 210.00,
                    "internal_tokens_per_second": 19.0,
                },
                resources,
                0.15998,
            ),
            "internal_exceeds_time_real": (
                {
                    **telemetry,
                    "internal_ms": 210.01,
                    "internal_tokens_per_second": 19.0,
                },
                resources,
                0.22,
            ),
        }
        for name, (candidate, candidate_resources, wall) in invalid.items():
            with self.subTest(name=name):
                with self.assertRaises(resource_ab.common.HarnessError):
                    resource_ab._validate_metric_relations(
                        candidate,
                        candidate_resources,
                        completion_tokens=4,
                        harness_wall_seconds=wall,
                    )

    def test_relational_telemetry_requires_emitter_precision(self):
        output = (
            "phases: prefill_ms=4.000 decode_ms=10.000 sampling_ms=0.100 "
            "decode_runs=3 attention_graphs=0 attention_dispatches=0 "
            "handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 "
            "fused_gqa_dispatches=0 paired_mlp_graphs=0 "
            "paired_mlp_dispatches=0\n"
            "  time:    14.10 ms (283.7 tok/s, prefilled 3, prefill=batch)\n"
        )
        resource_ab._validate_telemetry_precision(output)
        for invalid in (
            output.replace("prefill_ms=4.000", "prefill_ms=4.00"),
            output.replace("14.10 ms", "14.1 ms"),
            output.replace("283.7 tok/s", "283.70 tok/s"),
        ):
            with self.assertRaises(resource_ab.common.HarnessError):
                resource_ab._validate_telemetry_precision(invalid)

    def test_invalid_utf8_model_text_preserves_raw_hash_and_metrics(self):
        payload = (
            b"load: mode=prepared artifact=glrt ms=2.0\n"
            b"ready: phase=request_ready ms=3.0\n"
            b"  output: [7, 8, 9, 10]\n"
            b'  text (byte-decoded): "\xbd\xca"\n'
            b"schedule: attention=serial layers=4\n"
            b"phases: prefill_ms=4.000 decode_ms=10.000 sampling_ms=0.100 "
            b"decode_runs=3 attention_graphs=0 attention_dispatches=0 "
            b"handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 "
            b"fused_gqa_dispatches=0 paired_mlp_graphs=0 "
            b"paired_mlp_dispatches=0\n"
            b"  time:    14.10 ms (283.7 tok/s, prefilled 3, prefill=batch)\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            emitter = root / "invalid-utf8-emitter"
            emitter.write_text(
                f"#!{sys.executable}\n"
                "import sys\n"
                f"sys.stdout.buffer.write(bytes.fromhex('{payload.hex()}'))\n",
                encoding="ascii",
            )
            os.chmod(emitter, 0o755)
            process = resource_ab._run_timed_process([str(emitter)], root, 5.0)

        expected_raw_sha256 = resource_ab.common.sha256_bytes(payload)
        self.assertEqual(process["output_raw"], payload)
        self.assertEqual(process["output_capture"]["raw_sha256"], expected_raw_sha256)
        self.assertEqual(process["output_capture"]["non_ascii_byte_count"], 2)
        self.assertEqual(
            process["output_capture"]["telemetry_projection_rejection_markers"],
            2,
        )
        self.assertIn("\ufffd", process["retained_text"])
        resource_ab._validate_telemetry_precision(process["telemetry_text"])
        metrics = resource_ab.common.parse_telemetry(
            process["telemetry_text"],
            variant="serial",
            prompt_tokens=3,
            new_tokens=4,
            threshold=5,
        )
        self.assertEqual(metrics["internal_ms"], 14.1)
        self.assertEqual(metrics["decode_runs"], 3)

        with self.assertRaises(resource_ab.common.HarnessError):
            resource_ab._capture_process_output(
                payload.replace(b"prefill_ms=4.000", b"prefill_ms=4.\xbd00")
            )

    def test_tainted_reserved_telemetry_prefixes_fail_closed(self):
        for prefix in resource_ab._TELEMETRY_PREFIXES:
            insertion = len(prefix) // 2
            corrupted = prefix[:insertion] + b"\x80" + prefix[insertion:]
            with self.subTest(prefix=prefix.decode("ascii")):
                with self.assertRaisesRegex(
                    resource_ab.common.HarnessError,
                    "tainted leading output label",
                ):
                    resource_ab._capture_process_output(corrupted + b" payload\n")

        lookalikes = {
            "substitution": b"phas\x80s: payload\n",
            "mixed_case_insertion": b"Pha\x80Ses: payload\n",
            "mixed_case_substitution": b"PHAS\x80S: payload\n",
            "tab_in_prefix": b"pha\tses: payload\n",
            "collapsed_multi_character_substitution": b"ph\x80es: payload\n",
            "overlong_lf": b"\xc0\x8aphases: payload\n",
            "overlong_lf_then_indent": b"\xc0\x8a phases: payload\n",
            "unicode_line_separator": b"\xe2\x80\xa8phases: payload\n",
            "unicode_line_separator_then_tab": b"\xe2\x80\xa8\tphases: payload\n",
            "bare_cr": b"\rphases: payload\n",
            "bare_cr_then_space": b"\r phases: payload\n",
        }
        for name, payload in lookalikes.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(
                    resource_ab.common.HarnessError,
                    "tainted leading output label",
                ):
                    resource_ab._capture_process_output(payload)

    def test_non_ascii_or_control_bytes_in_exact_telemetry_line_fail_closed(self):
        invalid_lines = {
            "invalid_field_byte": b"phases: prefill_ms=4.\xbd00\n",
            "nbsp_separator": b"phases:\xc2\xa0prefill_ms=4.000\n",
            "unicode_digit": "phases: prefill_ms=٤.000\n".encode(),
            "fullwidth_digit": "phases: prefill_ms=４.000\n".encode(),
            "crlf": b"phases: prefill_ms=4.000\r\n",
            "nul_suffix": b"phases: prefill_ms=4.000\x00\n",
            "vertical_tab": b"\vphases: prefill_ms=4.000\n",
            "form_feed": b"\fphases: prefill_ms=4.000\n",
        }
        for name, payload in invalid_lines.items():
            with self.subTest(name=name):
                with self.assertRaises(resource_ab.common.HarnessError):
                    resource_ab._capture_process_output(payload)

    def test_measurement_order_is_deterministic_and_position_balanced(self):
        patterns, order = resource_ab.build_measurement_order(20, 1234)
        self.assertEqual(
            (patterns, order), resource_ab.build_measurement_order(20, 1234)
        )
        self.assertEqual(patterns.count("ABBA"), 5)
        self.assertEqual(patterns.count("BAAB"), 5)
        self.assertEqual(len(order), 40)
        self.assertEqual(
            sum(item["role"] == "baseline" for item in order),
            20,
        )
        self.assertEqual(
            sum(item["role"] == "candidate" for item in order),
            20,
        )
        for position in range(4):
            positioned = [
                item for item in order if item["position_in_block"] == position
            ]
            self.assertEqual(sum(item["role"] == "baseline" for item in positioned), 5)
            self.assertEqual(sum(item["role"] == "candidate" for item in positioned), 5)
        with self.assertRaises(resource_ab.common.HarnessError):
            resource_ab.build_measurement_order(6, 1234)

    def test_paired_bootstrap_is_deterministic_and_role_aware(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                role = "candidate" if letter == "A" else "baseline"
                samples.append(
                    {
                        "block_index": block_index,
                        "role": role,
                        "metrics": {
                            "time_cpu_seconds": 1.0 if role == "candidate" else 2.0
                        },
                    }
                )
        first = resource_ab.paired_ratio(
            samples,
            "time_cpu_seconds",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = resource_ab.paired_ratio(
            samples,
            "time_cpu_seconds",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["estimate"], 2.0)
        self.assertEqual(first["ci_low"], 2.0)
        self.assertEqual(first["ci_high"], 2.0)
        self.assertEqual(first["candidate_relative_change_percent"], -50.0)

    def test_serial_vs_fused_option_changes_only_candidate_policy(self):
        base = dict(
            baseline_binary=Path("/tmp/baseline"),
            candidate_binary=Path("/tmp/candidate"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        serial = resource_ab.Config(**base)
        candidate_serial = resource_ab.build_glacier_command(
            serial, "candidate", Path("/tmp/out.ids")
        )
        self.assertIn("--serial-attention", candidate_serial)
        self.assertNotIn("--parallel-attention-min-context", candidate_serial)

        fused = resource_ab.Config(**base, serial_vs_fused=True, threshold=256)
        baseline = resource_ab.build_glacier_command(
            fused, "baseline", Path("/tmp/baseline.ids")
        )
        candidate = resource_ab.build_glacier_command(
            fused, "candidate", Path("/tmp/candidate.ids")
        )
        self.assertIn("--serial-attention", baseline)
        self.assertNotIn("--serial-attention", candidate)
        threshold_index = candidate.index("--parallel-attention-min-context")
        self.assertEqual(candidate[threshold_index + 1], "256")
        self.assertIn("--require-prepared-image", candidate)
        self.assertIn("--require-batch-prefill", candidate)

        decode = resource_ab.Config(**base, decode_plan_ab=True, threshold=128)
        checked = resource_ab.build_glacier_command(
            decode, "baseline", Path("/tmp/checked.ids")
        )
        sealed = resource_ab.build_glacier_command(
            decode, "candidate", Path("/tmp/sealed.ids")
        )
        for command, mode in ((checked, "checked"), (sealed, "sealed-required")):
            self.assertNotIn("--serial-attention", command)
            self.assertEqual(
                command[command.index("--parallel-attention-min-context") + 1],
                "128",
            )
            self.assertEqual(command[command.index("--decode-plan") + 1], mode)
        normalized = list(sealed)
        normalized[0] = checked[0]
        normalized[normalized.index("--decode-plan") + 1] = "checked"
        normalized[normalized.index("--out-ids-file") + 1] = "/tmp/checked.ids"
        self.assertEqual(checked, normalized)

        greedy_base = {
            **base,
            "baseline_binary": Path("/tmp/glacier"),
            "candidate_binary": Path("/tmp/glacier"),
        }
        greedy = resource_ab.Config(
            **greedy_base,
            greedy_output_ab=True,
            threshold=128,
        )
        completion = Path("/tmp/greedy.ids")
        materialized = resource_ab.build_glacier_command(
            greedy, "baseline", completion
        )
        logitless = resource_ab.build_glacier_command(
            greedy, "candidate", completion
        )
        for command, mode in (
            (materialized, "materialized"),
            (logitless, "logitless-required"),
        ):
            self.assertEqual(command[0], "/tmp/glacier")
            self.assertIn("--require-prepared-image", command)
            self.assertIn("--require-batch-prefill", command)
            self.assertEqual(command[command.index("--temp") + 1], "0")
            self.assertEqual(
                command[command.index("--eos") + 1], str((1 << 32) - 1)
            )
            self.assertEqual(
                command[command.index("--parallel-attention-min-context") + 1],
                "128",
            )
            self.assertEqual(command[command.index("--decode-plan") + 1], "checked")
            self.assertEqual(command[command.index("--greedy-output") + 1], mode)
        normalized = list(logitless)
        normalized[normalized.index("--greedy-output") + 1] = "materialized"
        self.assertEqual(materialized, normalized)

    def test_policy_modes_are_mutually_exclusive_and_greedy_is_same_path(self):
        base = dict(
            baseline_binary=Path("/tmp/glacier"),
            candidate_binary=Path("/tmp/glacier"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        for flags in (
            {"serial_vs_fused": True, "decode_plan_ab": True},
            {"serial_vs_fused": True, "greedy_output_ab": True},
            {"decode_plan_ab": True, "greedy_output_ab": True},
        ):
            with self.subTest(flags=flags):
                with self.assertRaisesRegex(
                    resource_ab.common.HarnessError, "mutually exclusive"
                ):
                    resource_ab._validate(resource_ab.Config(**base, **flags))

        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            with self.assertRaises(SystemExit) as exit_status:
                resource_ab.argument_parser().parse_args(
                    [
                        "--baseline-binary",
                        "/tmp/glacier",
                        "--candidate-binary",
                        "/tmp/glacier",
                        "--model",
                        "/tmp/model.glrt",
                        "--ids",
                        "/tmp/ids",
                        "--output",
                        "-",
                        "--decode-plan-ab",
                        "--greedy-output-ab",
                    ]
                )
        self.assertEqual(exit_status.exception.code, 2)
        self.assertIn("not allowed with argument", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

        with self.assertRaisesRegex(
            resource_ab.common.HarnessError, "same binary path"
        ):
            resource_ab._validate(
                resource_ab.Config(
                    **{
                        **base,
                        "candidate_binary": Path("/tmp/other-glacier"),
                    },
                    greedy_output_ab=True,
                )
            )
        for field, value in (("threads", 1), ("new_tokens", 1)):
            with self.subTest(field=field):
                with self.assertRaisesRegex(
                    resource_ab.common.HarnessError,
                    "at least 2 threads and 2 new tokens",
                ):
                    resource_ab._validate(
                        resource_ab.Config(
                            **base,
                            greedy_output_ab=True,
                            **{field: value},
                        )
                    )

    def test_validation_rejects_relative_programmatic_paths(self):
        config = resource_ab.Config(
            baseline_binary=Path("relative-glacier"),
            candidate_binary=Path("/tmp/candidate"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        with self.assertRaisesRegex(
            resource_ab.common.HarnessError, "path must be absolute"
        ):
            resource_ab._validate(config)

    def test_sample_cap_precedes_pattern_allocation(self):
        base = dict(
            baseline_binary=Path("/tmp/baseline"),
            candidate_binary=Path("/tmp/candidate"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        with mock.patch.object(
            resource_ab.common,
            "build_patterns",
            side_effect=AssertionError("must not allocate patterns"),
        ) as build_patterns:
            for samples in (10_004, 10**30):
                with self.subTest(samples=samples):
                    with self.assertRaisesRegex(
                        resource_ab.common.HarnessError,
                        "must not exceed 10000",
                    ):
                        resource_ab._validate(
                            resource_ab.Config(
                                **base,
                                samples_per_role=samples,
                            )
                        )
        build_patterns.assert_not_called()

    def test_custom_time_provider_requires_test_only_escape_hatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline"
            candidate = root / "candidate"
            timer = root / "fake-time"
            for executable in (baseline, candidate, timer):
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
                os.chmod(executable, 0o755)
            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            base = dict(
                baseline_binary=baseline,
                candidate_binary=candidate,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                time_binary=timer,
            )
            with self.assertRaisesRegex(
                resource_ab.common.HarnessError, "custom timers are test-only"
            ):
                resource_ab._validate(resource_ab.Config(**base))
            resource_ab._validate(
                resource_ab.Config(
                    **base,
                    test_only_allow_non_system_time=True,
                )
            )

    def test_serial_vs_fused_rejects_different_binary_hashes(self):
        config = resource_ab.Config(
            baseline_binary=Path("/tmp/baseline"),
            candidate_binary=Path("/tmp/candidate"),
            model=Path("/tmp/model.glrt"),
            ids=Path("/tmp/ids"),
            output=None,
            cwd=Path("/tmp"),
            serial_vs_fused=True,
        )
        artifacts = {
            "baseline_binary": {"sha256": "0" * 64},
            "candidate_binary": {"sha256": "1" * 64},
        }
        with self.assertRaisesRegex(resource_ab.common.HarnessError, "byte-identical"):
            resource_ab._validate_comparison_artifacts(config, artifacts)

    def test_no_overwrite_publication_has_one_concurrent_winner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "result.json"
            read_fd, write_fd = os.pipe()
            children: list[int] = []
            writer_count = 4
            for writer in range(writer_count):
                process_id = os.fork()
                if process_id == 0:
                    os.close(write_fd)
                    os.read(read_fd, 1)
                    try:
                        resource_ab.write_resource_result(
                            {"writer": writer},
                            output,
                            overwrite=False,
                        )
                    except resource_ab.common.HarnessError:
                        os._exit(7)
                    except BaseException:
                        os._exit(9)
                    os._exit(0)
                children.append(process_id)
            os.close(read_fd)
            os.write(write_fd, b"x" * writer_count)
            os.close(write_fd)
            statuses = [os.waitpid(process_id, 0)[1] for process_id in children]
            exit_codes = [os.waitstatus_to_exitcode(status) for status in statuses]
            self.assertEqual(exit_codes.count(0), 1)
            self.assertEqual(exit_codes.count(7), writer_count - 1)
            self.assertIn(json.loads(output.read_text())["writer"], range(4))
            self.assertEqual(list(root.glob(".glacier-resource-ab.*.tmp")), [])

    def test_no_overwrite_preserves_regular_file_and_dangling_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            regular = root / "regular.json"
            regular.write_bytes(b"sentinel\n")
            before = regular.stat()
            with self.assertRaises(resource_ab.common.HarnessError):
                resource_ab.write_resource_result(
                    {"replacement": True}, regular, overwrite=False
                )
            after = regular.stat()
            self.assertEqual(regular.read_bytes(), b"sentinel\n")
            self.assertEqual(
                (before.st_dev, before.st_ino), (after.st_dev, after.st_ino)
            )

            dangling = root / "dangling.json"
            dangling.symlink_to(root / "missing-target")
            link_before = dangling.lstat()
            with self.assertRaises(resource_ab.common.HarnessError):
                resource_ab.write_resource_result(
                    {"replacement": True}, dangling, overwrite=False
                )
            link_after = dangling.lstat()
            self.assertEqual(
                (link_before.st_dev, link_before.st_ino),
                (link_after.st_dev, link_after.st_ino),
            )
            self.assertEqual(os.readlink(dangling), str(root / "missing-target"))
            self.assertEqual(list(root.glob(".glacier-resource-ab.*.tmp")), [])

    def test_publication_fsyncs_file_before_link_and_directory_after(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "ordered.json"
            events: list[str] = []
            real_fsync = os.fsync
            real_link = os.link

            def observed_fsync(descriptor, /):
                events.append("fsync")
                return real_fsync(descriptor)

            def observed_link(source, destination, **kwargs):
                events.append("link")
                return real_link(source, destination, **kwargs)

            with (
                mock.patch.object(resource_ab.os, "fsync", observed_fsync),
                mock.patch.object(resource_ab.os, "link", observed_link),
            ):
                resource_ab.write_resource_result(
                    {"complete": True}, output, overwrite=False
                )
            self.assertEqual(events, ["fsync", "link", "fsync"])
            self.assertEqual(json.loads(output.read_text()), {"complete": True})

    def test_publication_failure_before_link_leaves_no_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "failed.json"
            with mock.patch.object(
                resource_ab.os,
                "fsync",
                side_effect=OSError("injected file fsync failure"),
            ):
                with self.assertRaisesRegex(
                    resource_ab.common.HarnessError,
                    "cannot write and fsync",
                ):
                    resource_ab.write_resource_result(
                        {"complete": False}, output, overwrite=False
                    )
            self.assertFalse(os.path.lexists(output))
            self.assertEqual(list(root.glob(".glacier-resource-ab.*.tmp")), [])

    def test_lightweight_strict_greedy_output_resource_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            glacier = root / "fake-glacier"
            glacier.write_text(
                f"#!{sys.executable}\n"
                "import pathlib,sys\n"
                "args=sys.argv[1:]\n"
                "def value(flag): return args[args.index(flag)+1]\n"
                "assert '--require-batch-prefill' in args\n"
                "assert '--require-prepared-image' in args\n"
                "assert value('--temp')=='0'\n"
                "assert value('--eos')==str((1<<32)-1)\n"
                "assert value('--decode-plan')=='checked'\n"
                "tokens=int(value('--n')); runs=tokens-1; layers=4\n"
                "threshold=int(value('--parallel-attention-min-context'))\n"
                "mode=value('--greedy-output'); direct=mode=='logitless-required'\n"
                "out=pathlib.Path(value('--out-ids-file'))\n"
                "out.write_text(' '.join(str(7+i) for i in range(tokens))+'\\n')\n"
                "graphs=runs; dispatches=graphs*layers\n"
                "print('load: mode=prepared artifact=glrt ms=2.0')\n"
                "print('ready: phase=request_ready ms=3.0')\n"
                "print(f'schedule: attention=parallel min_context={threshold} layers={layers}')\n"
                "decode_ms='5.000' if direct else '10.000'\n"
                "sampling_ms='0.000' if direct else '0.100'\n"
                "print(f'phases: prefill_ms=4.000 decode_ms={decode_ms} sampling_ms={sampling_ms} decode_runs={runs} attention_graphs={graphs} attention_dispatches={dispatches} handoff_graphs={graphs} handoff_dispatches={dispatches} fused_gqa_graphs={graphs} fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} paired_mlp_dispatches={dispatches}')\n"
                "materialized=1 if direct else tokens; logitless=runs if direct else 0\n"
                "scratch=32 if direct else 0; logits_bytes=607744\n"
                "producer_rows=runs*(logits_bytes//4) if direct else 0\n"
                "reclaimed=logits_bytes if direct else 0\n"
                "print(f'greedy_output: mode={mode} materialized_projections={materialized} logitless_projections={logitless} producer_rows={producer_rows} tile_output_bytes=0 argmax_scan_rows=0 scratch_bytes={scratch} materialized_logits_bytes={logits_bytes} steady_state_reclaimed_bytes={reclaimed} fallbacks=0 rejects=0 abi=474c4d4800000002')\n"
                "internal='9.00' if direct else '14.10'\n"
                "tps='444.4' if direct else '283.7'\n"
                "print(f'time: {internal} ms ({tps} tok/s, prefilled 3, prefill=batch)')\n",
                encoding="utf-8",
            )
            os.chmod(glacier, 0o755)

            fake_time = root / "fake-time"
            fake_time.write_text(
                f"#!{sys.executable}\n"
                "import pathlib,subprocess,sys,time\n"
                "args=sys.argv[1:]\n"
                "assert args[:2]==['-lp','-o']\n"
                "target=pathlib.Path(args[2]); command=args[3:]\n"
                "started=time.perf_counter()\n"
                "run=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)\n"
                "elapsed=max(0.01,int((time.perf_counter()-started)*100)/100)\n"
                "mode=command[command.index('--greedy-output')+1]\n"
                "scale=1 if mode=='logitless-required' else 2\n"
                "lines=[f'real {elapsed:.2f}',f'user {scale}.00','sys 0.10',f'{200*scale}  maximum resident set size','0  average shared memory size','0  average unshared data size','0  average unshared stack size','10  page reclaims','1  page faults','0  swaps','0  block input operations','0  block output operations','0  messages sent','0  messages received','0  signals received','3  voluntary context switches','4  involuntary context switches',f'{1000*scale}  instructions retired',f'{2000*scale}  cycles elapsed',f'{100*scale}  peak memory footprint']\n"
                "target.write_text('\\n'.join(lines)+'\\n')\n"
                "sys.stdout.buffer.write(run.stdout)\n"
                "raise SystemExit(run.returncode)\n",
                encoding="utf-8",
            )
            os.chmod(fake_time, 0o755)

            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = resource_ab.Config(
                baseline_binary=glacier,
                candidate_binary=glacier,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                time_binary=fake_time,
                test_only_allow_non_system_time=True,
                greedy_output_ab=True,
                threshold=4,
                samples_per_role=4,
                warmups_per_role=1,
                new_tokens=4,
                threads=2,
                schedule_seed=1234,
                bootstrap_seed=99,
                bootstrap_resamples=100,
            )
            real_greedy_parser = resource_ab.greedy_output.parse_telemetry
            with (
                mock.patch.object(
                    resource_ab,
                    "_TIME_WRAPPER_OVERHEAD_TOLERANCE_SECONDS",
                    2.0,
                ),
                mock.patch.object(
                    resource_ab.greedy_output,
                    "parse_telemetry",
                    side_effect=real_greedy_parser,
                ) as greedy_parser,
            ):
                result = resource_ab.run_benchmark(config)

            self.assertTrue(greedy_parser.call_args_list)
            self.assertTrue(
                all(
                    call.kwargs["require_fused_gqa"]
                    for call in greedy_parser.call_args_list
                )
            )

            self.assertEqual(result["schema"], resource_ab.SCHEMA)
            self.assertEqual(result["status"], "passed")
            contract = result["contract"]
            self.assertEqual(
                contract["comparison"],
                "same-binary-materialized-vs-logitless-required",
            )
            self.assertTrue(contract["same_binary_required"])
            self.assertTrue(contract["same_binary_path_required"])
            self.assertTrue(contract["only_greedy_output_policy_varies"])
            self.assertTrue(contract["strict_greedy_output"])
            self.assertTrue(contract["strict_logitless_required"])
            self.assertTrue(contract["require_fused_gqa"])
            self.assertTrue(contract["require_paired_mlp"])
            self.assertTrue(contract["stable_phase_signature_required"])
            self.assertEqual(
                contract["phase_signature"], [3, 3, 12, 3, 12, 3, 12, 3, 12]
            )
            self.assertEqual(contract["decode_plan_mode"], "checked")
            self.assertEqual(contract["policies"]["baseline"], "materialized")
            self.assertEqual(
                contract["policies"]["candidate"], "logitless-required"
            )
            self.assertEqual(contract["greedy_output_abi"], "474c4d4800000002")
            self.assertEqual(contract["materialized_logits_bytes"], 607_744)
            self.assertEqual(contract["logitless_scratch_bytes"], 32)
            self.assertEqual(contract["expected_materialized_projections"], 4)
            self.assertEqual(contract["expected_logitless_projections"], 3)
            self.assertEqual(contract["expected_producer_rows"], 455_808)
            self.assertEqual(contract["required_tile_output_bytes"], 0)
            self.assertEqual(contract["required_argmax_scan_rows"], 0)
            self.assertIn("greedy_output_driver", result["artifacts_before"])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8, 9, 10])
            self.assertEqual(len(result["samples"]), 8)

            normalized_commands = []
            normalized_timed_commands = []
            for sample in [*result["warmups"], *result["samples"]]:
                command = list(sample["glacier_argv"])
                command[command.index("--greedy-output") + 1] = "materialized"
                normalized_commands.append(tuple(command))
                timed = list(sample["timed_argv"])
                timed[timed.index("--greedy-output") + 1] = "materialized"
                normalized_timed_commands.append(tuple(timed))
            self.assertEqual(len(set(normalized_commands)), 1)
            self.assertEqual(len(set(normalized_timed_commands)), 1)

            baselines = [
                sample for sample in result["samples"] if sample["role"] == "baseline"
            ]
            candidates = [
                sample for sample in result["samples"] if sample["role"] == "candidate"
            ]
            self.assertTrue(
                all(
                    sample["metrics"]["greedy_materialized_projections"] == 4
                    and sample["metrics"]["greedy_logitless_projections"] == 0
                    for sample in baselines
                )
            )
            self.assertTrue(
                all(
                    sample["metrics"]["greedy_materialized_projections"] == 1
                    and sample["metrics"]["greedy_logitless_projections"] == 3
                    and sample["metrics"]["greedy_fallbacks"] == 0
                    and sample["metrics"]["greedy_rejects"] == 0
                    for sample in candidates
                )
            )
            for role in resource_ab.ROLES:
                medians = result["medians"][role]
                for field in (
                    "time_user_seconds",
                    "time_sys_seconds",
                    "time_maximum_resident_set_size_bytes",
                    "time_instructions_retired",
                    "time_peak_memory_footprint_bytes",
                ):
                    self.assertIn(field, medians)
            for field in (
                "time_maximum_resident_set_size_bytes",
                "time_instructions_retired",
                "time_peak_memory_footprint_bytes",
            ):
                self.assertEqual(
                    result["baseline_over_candidate"][field]["estimate"], 2.0
                )
            for name in result["artifacts_before"]:
                self.assertEqual(
                    result["artifacts_before"][name]["sha256"],
                    result["artifacts_after"][name]["sha256"],
                )
            json.dumps(result, allow_nan=False)

    def test_lightweight_strict_serial_vs_fused_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            glacier = root / "fake-glacier"
            glacier.write_text(
                f"#!{sys.executable}\n"
                "import pathlib,sys\n"
                "args=sys.argv[1:]\n"
                "def value(flag): return args[args.index(flag)+1]\n"
                "tokens=int(value('--n'))\n"
                "out=pathlib.Path(value('--out-ids-file'))\n"
                "out.write_text(' '.join(str(7+i) for i in range(tokens))+'\\n')\n"
                "parallel='--parallel-attention-min-context' in args\n"
                "graphs=2 if parallel else 0\n"
                "dispatches=graphs*4\n"
                "print('load: mode=prepared artifact=glrt ms=2.0')\n"
                "print('ready: phase=request_ready ms=3.0')\n"
                "sys.stdout.flush()\n"
                "sys.stdout.buffer.write(b'  text (byte-decoded): \\\"\\xbd\\xca\\\"\\n')\n"
                "sys.stdout.buffer.flush()\n"
                "print('schedule: attention=parallel min_context=5 layers=4' if parallel else 'schedule: attention=serial layers=4')\n"
                "print(f'phases: prefill_ms=4.000 decode_ms=10.000 sampling_ms=0.100 decode_runs=3 attention_graphs={graphs} attention_dispatches={dispatches} handoff_graphs={graphs} handoff_dispatches={dispatches} fused_gqa_graphs={graphs} fused_gqa_dispatches={dispatches} paired_mlp_graphs={graphs} paired_mlp_dispatches={dispatches}')\n"
                "print('time: 14.10 ms (283.7 tok/s, prefilled 3, prefill=batch)')\n",
                encoding="utf-8",
            )
            os.chmod(glacier, 0o755)

            fake_time = root / "fake-time"
            fake_time.write_text(
                f"#!{sys.executable}\n"
                "import pathlib,subprocess,sys,time\n"
                "args=sys.argv[1:]\n"
                "assert args[:2]==['-lp','-o']\n"
                "target=pathlib.Path(args[2]); command=args[3:]\n"
                "started=time.perf_counter()\n"
                "run=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)\n"
                "elapsed=max(0.01,int((time.perf_counter()-started)*100)/100)\n"
                "parallel='--parallel-attention-min-context' in command\n"
                "scale=1 if parallel else 2\n"
                "lines=[f'real {elapsed:.2f}',f'user {scale}.00','sys 0.10',f'{200*scale}  maximum resident set size','0  average shared memory size','0  average unshared data size','0  average unshared stack size','10  page reclaims','1  page faults','0  swaps','0  block input operations','0  block output operations','0  messages sent','0  messages received','0  signals received','3  voluntary context switches','4  involuntary context switches',f'{1000*scale}  instructions retired',f'{2000*scale}  cycles elapsed',f'{100*scale}  peak memory footprint']\n"
                "target.write_text('\\n'.join(lines)+'\\n')\n"
                "sys.stdout.buffer.write(run.stdout)\n"
                "raise SystemExit(run.returncode)\n",
                encoding="utf-8",
            )
            os.chmod(fake_time, 0o755)

            model = root / "model.glrt"
            model.write_bytes(b"model")
            ids = root / "prompt.ids"
            ids.write_text("1 2 3\n", encoding="ascii")
            config = resource_ab.Config(
                baseline_binary=glacier,
                candidate_binary=glacier,
                model=model,
                ids=ids,
                output=None,
                cwd=root,
                time_binary=fake_time,
                test_only_allow_non_system_time=True,
                serial_vs_fused=True,
                threshold=5,
                samples_per_role=4,
                warmups_per_role=1,
                new_tokens=4,
                threads=2,
                schedule_seed=1234,
                bootstrap_seed=99,
                bootstrap_resamples=100,
            )
            # The injected timer is a Python process, so its interpreter startup
            # is intentionally outside the child duration and may be cold/slow.
            # Production evidence always uses native Darwin /usr/bin/time and
            # retains the strict 250 ms wrapper allowance.
            with mock.patch.object(
                resource_ab,
                "_TIME_WRAPPER_OVERHEAD_TOLERANCE_SECONDS",
                2.0,
            ):
                result = resource_ab.run_benchmark(config)
            self.assertEqual(result["schema"], resource_ab.SCHEMA)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(
                result["contract"]["comparison"],
                "same-binary-serial-vs-fused",
            )
            self.assertTrue(result["contract"]["require_fused_gqa"])
            self.assertTrue(result["contract"]["require_paired_mlp"])
            self.assertNotIn("evidence_publishable", result)
            self.assertNotIn("evidence_publishable", result["contract"])
            scope = result["resource_evidence_scope"]
            self.assertEqual(scope["claim_scope"], "resource_evidence_only")
            self.assertFalse(scope["measurements_publishable"])
            self.assertFalse(scope["quality_certified"])
            self.assertFalse(scope["energy_measured"])
            self.assertFalse(scope["thermal_state_controlled"])
            self.assertFalse(scope["thermal_state_measured"])
            self.assertTrue(scope["single_fixture"])
            self.assertEqual(scope["decision_role"], "evidence_only")
            self.assertEqual(scope["promotion_decision"], "not_evaluated")
            self.assertFalse(result["contract"]["strict_macos_time_lp"])
            self.assertEqual(result["contract"]["time_provider"], "test-only-injected")
            self.assertEqual(
                result["contract"]["cache_regime"],
                "process-cold/cache-uncontrolled-after-excluded-warmups",
            )
            capture_contract = result["contract"]["process_output_capture"]
            self.assertEqual(capture_contract["stream"], "combined_stdout_stderr")
            self.assertEqual(
                capture_contract["retained_human_text"],
                {
                    "encoding": "utf-8",
                    "errors": "replace",
                    "purpose": "human-readable evidence only; never parsed as telemetry",
                },
            )
            self.assertEqual(
                capture_contract["telemetry_projection"]["encoding"], "ascii"
            )
            self.assertIn(
                "outside the telemetry grammar",
                capture_contract["telemetry_projection"]["purpose"],
            )
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(
                result["artifacts_before"]["baseline_binary"]["sha256"],
                result["artifacts_before"]["candidate_binary"]["sha256"],
            )
            candidates = [
                sample for sample in result["samples"] if sample["role"] == "candidate"
            ]
            baselines = [
                sample for sample in result["samples"] if sample["role"] == "baseline"
            ]
            self.assertTrue(
                all(sample["metrics"]["fused_gqa_graphs"] == 2 for sample in candidates)
            )
            self.assertTrue(
                all(sample["metrics"]["fused_gqa_graphs"] == 0 for sample in baselines)
            )
            self.assertTrue(
                all(sample["metrics"]["paired_mlp_graphs"] == 2 for sample in candidates)
            )
            self.assertTrue(
                all(sample["metrics"]["paired_mlp_graphs"] == 0 for sample in baselines)
            )
            self.assertTrue(
                all(sample["telemetry_output"] for sample in result["samples"])
            )
            for sample in result["samples"]:
                capture = sample["output_capture"]
                self.assertEqual(capture["raw_sha256"], sample["telemetry_sha256"])
                self.assertEqual(capture["non_ascii_byte_count"], 2)
                self.assertEqual(capture["telemetry_projection_rejection_markers"], 2)
                self.assertIn("\ufffd", sample["telemetry_output"])
            self.assertTrue(all(sample["time_output"] for sample in result["samples"]))
            self.assertEqual(
                result["baseline_over_candidate"]["time_instructions_retired"][
                    "estimate"
                ],
                2.0,
            )


if __name__ == "__main__":
    unittest.main()
