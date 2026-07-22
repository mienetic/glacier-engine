import importlib.util
import math
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


BENCH_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = BENCH_DIR / "pair_nibble_report.py"
SPEC = importlib.util.spec_from_file_location("pair_nibble_report", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
report = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = report
SPEC.loader.exec_module(report)


class PairNibbleReportTests(unittest.TestCase):
    def test_parse_rows_rejects_non_finite_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "raw.csv"
            path.write_text(
                "run_id,group_size,batch,block,pattern,position,method,"
                "ns_per_producer\n"
                "7,8,1,0,ABBA,0,A,nan\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(report.ReportError, "invalid position/timing"):
                report.parse_rows(path, 1)

    def test_validate_schedule_rejects_duplicate_positions(self):
        rows = []
        for block, pattern, positions in (
            (0, "ABBA", (0, 1, 1, 3)),
            (1, "BAAB", (0, 1, 2, 3)),
        ):
            rows.extend(
                {
                    "block": block,
                    "pattern": pattern,
                    "position": position,
                    "method": method,
                    "ns": 1.0,
                }
                for position, method in zip(positions, pattern)
            )
        with self.assertRaisesRegex(report.ReportError, "positions are not exactly"):
            report.validate_schedule(rows, 2)

    def test_verification_log_is_complete_ordered_and_run_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "verify.log"
            passes = [
                f"VERIFY_PASS,{when},g{group},b{batch},bit_exact,run_id=7"
                for group, batch in report.CONFIGS
                for when in ("before", "after")
            ]
            path.write_text(
                "\n".join(
                    passes
                    + [
                        "BENCH_DONE,blocks=2,inner_m1=3,inner_m4=4,"
                        "qos=user_interactive,sink=9,run_id=7"
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            result = report.validate_verification_log(
                path, blocks=2, inner_m1=3, inner_m4=4, run_id=7
            )
            self.assertEqual(result["ordered_bit_exact_passes"], 8)

            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "VERIFY_PASS,after,g16,b4,bit_exact",
                    "VERIFY_FAIL,after,g16,b4,up,index=0,00000000,00000001",
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(report.ReportError, "ordered PASS"):
                report.validate_verification_log(
                    path, blocks=2, inner_m1=3, inner_m4=4, run_id=7
                )

    def test_encode_report_rejects_non_finite_output(self):
        for value in (math.nan, math.inf, -math.inf):
            with self.subTest(value=value):
                with self.assertRaisesRegex(report.ReportError, "non-finite"):
                    report.encode_report({"value": value})

    def test_batch_specific_direct_gate_thresholds(self):
        rows = []
        for block, pattern in ((0, "ABBA"), (1, "BAAB")):
            for position, method in enumerate(pattern):
                rows.append(
                    {
                        "block": block,
                        "pattern": pattern,
                        "position": position,
                        "method": method,
                        "ns": 110.0 if method == "A" else 100.0,
                    }
                )

        with mock.patch.object(
            report,
            "bootstrap_ratios",
            return_value=report.np.asarray([1.10, 1.10]),
        ):
            m1 = report.summarize_config(
                rows,
                8,
                1,
                blocks=2,
                resamples=2,
                seed=1,
                direct_threshold=1.15,
                coefficients=64,
            )
            m4 = report.summarize_config(
                rows,
                8,
                4,
                blocks=2,
                resamples=2,
                seed=1,
                direct_threshold=1.05,
                coefficients=64,
            )

        self.assertFalse(m1["direct_gate"]["entire_95pct_ci_clears"])
        self.assertEqual(m1["direct_gate"]["threshold"], 1.15)
        self.assertTrue(m4["direct_gate"]["entire_95pct_ci_clears"])
        self.assertEqual(m4["direct_gate"]["threshold"], 1.05)


if __name__ == "__main__":
    unittest.main()
