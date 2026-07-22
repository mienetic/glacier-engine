import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[1]
REPORT_PATH = REPOSITORY / "bench" / "pair_nibble_executor_tile_report.py"
SPEC = importlib.util.spec_from_file_location("pair_tile_report", REPORT_PATH)
assert SPEC is not None and SPEC.loader is not None
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)


class PairNibbleExecutorTileReportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.constants = mock.patch.multiple(
            report,
            PARTICIPANTS=(1,),
            GROUP_SIZES=(8,),
            TILE_ROWS=(16, 64),
            RUNS=1,
            ROUNDS=1,
            SAMPLES=2,
            WARMUPS=1,
            OUT_FEATURES=64,
            IN_FEATURES=16,
        )
        self.constants.start()
        self.addCleanup(self.constants.stop)

    @staticmethod
    def valid_rows() -> list[dict[str, str]]:
        rows: list[dict[str, str]] = []
        for tile_rows, position in ((16, 0), (64, 1)):
            for sample in range(2):
                rows.append(
                    {
                        "run_id": "42",
                        "run_index": "0",
                        "participants": "1",
                        "group_size": "8",
                        "tile_rows": str(tile_rows),
                        "claims": str((64 + tile_rows - 1) // tile_rows),
                        "round": "0",
                        "sample": str(sample),
                        "position": str(position),
                        "elapsed_ns": str(1000 + tile_rows + sample),
                    }
                )
        return rows

    def write_raw(self, rows: list[dict[str, str]]) -> Path:
        path = self.root / "raw.csv"
        with path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(
                stream,
                fieldnames=[
                    "run_id",
                    "run_index",
                    "participants",
                    "group_size",
                    "tile_rows",
                    "claims",
                    "round",
                    "sample",
                    "position",
                    "elapsed_ns",
                ],
            )
            writer.writeheader()
            writer.writerows(rows)
        return path

    def write_log(self) -> Path:
        path = self.root / "verify.log"
        path.write_text(
            "\n".join(
                [
                    "CAMPAIGN,run_id=42,out=64,in=16,participants=1,"
                    "runs=1,rounds=1,samples=2,warmups=1",
                    "MAIN_QOS,status=0",
                    "VERIFY_PASS,run_id=42,run=0,t1,g8,tile16_64,bit_exact",
                    "WORKER_QOS,g8,participants=1,failures=0",
                    "SINK,value=123",
                    "CAMPAIGN_PASS",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        return path

    def test_valid_raw_requires_the_full_coordinate_set(self) -> None:
        run_id, grouped = report.parse_raw(self.write_raw(self.valid_rows()))
        self.assertEqual(42, run_id)
        self.assertEqual(4, sum(len(values) for values in grouped.values()))

    def test_duplicate_raw_coordinate_is_rejected(self) -> None:
        rows = self.valid_rows()
        rows[-1] = dict(rows[-2])
        with self.assertRaisesRegex(ValueError, "duplicate campaign coordinate"):
            report.parse_raw(self.write_raw(rows))

    def test_missing_raw_coordinate_is_rejected(self) -> None:
        rows = self.valid_rows()
        rows.pop()
        with self.assertRaisesRegex(ValueError, "expected 4 rows"):
            report.parse_raw(self.write_raw(rows))

    def test_verification_log_requires_exact_order_and_fields(self) -> None:
        path = self.write_log()
        report.validate_verification(path, 42)
        lines = path.read_text(encoding="utf-8").splitlines()
        lines[2], lines[3] = lines[3], lines[2]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "verification line 2 mismatch"):
            report.validate_verification(path, 42)

    def test_recommendation_uses_paired_ratios_not_independent_medians(self) -> None:
        with mock.patch.multiple(
            report,
            PARTICIPANTS=(4,),
            GROUP_SIZES=(8,),
            TILE_ROWS=(64, 256),
            RUNS=3,
        ):
            run_medians = {
                (4, 8, 64): [94_854.0, 90_333.0, 70_187.0],
                (4, 8, 256): [96_208.0, 89_021.0, 71_729.0],
            }
            # Independent medians misleadingly favor 256, while two of three
            # paired runs and the paired median show that it is slower.
            self.assertLess(
                report.median(run_medians[(4, 8, 256)]),
                report.median(run_medians[(4, 8, 64)]),
            )
            by_group, cross_group = report.recommend_tiles(run_medians)
            self.assertEqual({"t4_g8": 64}, by_group)
            self.assertEqual({"4": 64}, cross_group)

    def test_runtime_projection_uses_nearest_measured_with_lower_ties(self) -> None:
        measured = {
            "t1_g8": 256,
            "t2_g8": 32,
            "t4_g8": 64,
            "t8_g8": 256,
        }
        with mock.patch.multiple(
            report,
            PARTICIPANTS=(1, 2, 4, 8),
            GROUP_SIZES=(8,),
        ):
            projected, sources = report.project_measured_tiles(measured)
        self.assertEqual(
            {"1": 1, "2": 2, "3": 2, "4": 4, "5": 4, "6": 4, "7": 8, "8": 8},
            sources,
        )
        self.assertEqual(
            {
                "t1_g8": 256,
                "t2_g8": 32,
                "t3_g8": 32,
                "t4_g8": 64,
                "t5_g8": 64,
                "t6_g8": 64,
                "t7_g8": 256,
                "t8_g8": 256,
            },
            projected,
        )


if __name__ == "__main__":
    unittest.main()
