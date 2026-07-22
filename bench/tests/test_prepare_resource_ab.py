from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


BENCH_DIR = Path(__file__).resolve().parents[1]
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))
MODULE_PATH = BENCH_DIR / "prepare_resource_ab.py"
SPEC = importlib.util.spec_from_file_location("prepare_resource_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
prepare_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = prepare_ab
SPEC.loader.exec_module(prepare_ab)


class PrepareResourceAbTests(unittest.TestCase):
    def test_parse_prepare_telemetry_requires_exact_pair_identity(self):
        source = Path("/tmp/model.glacier")
        output = Path("/tmp/model.glrt")
        source_sha = "a" * 64
        provenance = "b" * 64
        raw = (
            f"prepare: source={source} output={output} mlp_layout=pair-nibble\n"
            "  hash_ms=10.00 materialize_ms=20.00 "
            "materialize_cache_state=post-hash-os-warm "
            "write_ms=30.00 total_ms=60.00\n"
            f"  source_sha256={source_sha} provenance_sha256={provenance}\n"
            "  prepare_workspace: generated_records=24 "
            "generated_workspace_bytes_total=130744320 "
            "generated_workspace_bytes_peak=5447680\n"
        ).encode("ascii")
        parsed = prepare_ab.parse_prepare_telemetry(
            raw,
            expected_source=source,
            expected_output=output,
            expected_source_sha256=source_sha,
        )
        self.assertEqual(parsed["write_ms"], 30.0)
        self.assertEqual(parsed["provenance_sha256"], provenance)
        self.assertEqual(parsed["workspace"]["generated_records"], 24)
        self.assertEqual(
            parsed["workspace"]["generated_workspace_bytes_peak"], 5_447_680
        )

        invalid = {
            "duplicate": raw + raw,
            "wrong layout": raw.replace(b"pair-nibble", b"separate"),
            "wrong source": raw.replace(source_sha.encode(), ("c" * 64).encode()),
            "wrong output": raw.replace(str(output).encode(), b"/tmp/other.glrt"),
            "impossible phases": raw.replace(b"total_ms=60.00", b"total_ms=59.97"),
            "precision": raw.replace(b"hash_ms=10.00", b"hash_ms=10.0"),
            "non-ascii": raw + b"\xff",
            "duplicate workspace": raw + (
                b"prepare_workspace: generated_records=1 "
                b"generated_workspace_bytes_total=1 "
                b"generated_workspace_bytes_peak=1\n"
            ),
            "bad workspace": raw.replace(
                b"generated_workspace_bytes_total=130744320",
                b"generated_workspace_bytes_total=1",
            ),
        }
        for name, candidate in invalid.items():
            with self.subTest(name=name):
                with self.assertRaises(prepare_ab.common.HarnessError):
                    prepare_ab.parse_prepare_telemetry(
                        candidate,
                        expected_source=source,
                        expected_output=output,
                        expected_source_sha256=source_sha,
                    )

    def test_patterns_are_balanced_and_deterministic(self):
        first = prepare_ab.build_patterns(16, 123)
        self.assertEqual(first, prepare_ab.build_patterns(16, 123))
        self.assertEqual(first.count("ABBA"), 4)
        self.assertEqual(first.count("BAAB"), 4)
        self.assertEqual(sum(pattern.count("A") for pattern in first), 16)
        self.assertEqual(sum(pattern.count("B") for pattern in first), 16)
        for invalid in (0, 2, 6, 10):
            with self.subTest(invalid=invalid):
                with self.assertRaises(prepare_ab.common.HarnessError):
                    prepare_ab.build_patterns(invalid, 123)

    def test_paired_ratio_uses_two_arms_per_block(self):
        samples = []
        for block_index in range(2):
            for role, values in (
                ("baseline", (120.0, 120.0)),
                ("candidate", (100.0, 100.0)),
            ):
                for value in values:
                    samples.append(
                        {
                            "block_index": block_index,
                            "role": role,
                            "metrics": {"rss": value},
                        }
                    )
        ratio = prepare_ab.paired_ratio(
            samples,
            "rss",
            resamples=100,
            seed=7,
            confidence=0.95,
        )
        self.assertEqual(ratio["estimate"], 1.2)
        self.assertEqual(ratio["ci_low"], 1.2)
        self.assertEqual(ratio["ci_high"], 1.2)

        with self.assertRaises(prepare_ab.common.HarnessError):
            prepare_ab.paired_ratio(
                samples[:-1],
                "rss",
                resamples=10,
                seed=7,
                confidence=0.95,
            )

    def test_candidate_workspace_requires_real_bounded_generation(self):
        self.assertTrue(
            prepare_ab._candidate_workspace_semantics_valid(
                (24, 130_744_320, 5_447_680)
            )
        )
        for invalid in (
            (0, 0, 0),
            (1, 0, 0),
            (1, 5, 0),
            (1, 4, 5),
        ):
            with self.subTest(invalid=invalid):
                self.assertFalse(
                    prepare_ab._candidate_workspace_semantics_valid(invalid)
                )

    def test_absent_sidecar_contract_fails_if_it_appears(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "model.glacier"
            config = mock.Mock(source=source)
            prepare_ab._assert_absent_sidecar(config, True)
            sidecar = Path(str(source) + ".json")
            sidecar.write_text("{}", encoding="utf-8")
            with self.assertRaises(prepare_ab.common.HarnessError):
                prepare_ab._assert_absent_sidecar(config, True)

            # When a sidecar was hash-pinned into the artifact set, the common
            # identity guard owns mutation checks and this absence guard is off.
            prepare_ab._assert_absent_sidecar(config, False)

    def test_main_reports_harness_failure_without_traceback(self):
        parser = mock.Mock()
        parser.parse_args.return_value = object()
        config = mock.Mock(output=None)
        stderr = io.StringIO()
        with (
            mock.patch.object(prepare_ab, "argument_parser", return_value=parser),
            mock.patch.object(prepare_ab, "config_from_args", return_value=config),
            mock.patch.object(
                prepare_ab,
                "run_benchmark",
                side_effect=prepare_ab.common.HarnessError("hash mismatch"),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            self.assertEqual(prepare_ab.main([]), 2)
        self.assertEqual(
            stderr.getvalue(),
            "prepare resource benchmark failed: hash mismatch\n",
        )


if __name__ == "__main__":
    unittest.main()
