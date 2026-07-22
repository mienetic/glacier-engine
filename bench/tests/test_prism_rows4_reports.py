from __future__ import annotations

import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


BENCH_DIR = Path(__file__).resolve().parents[1]


def load_reporter(name: str):
    path = BENCH_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


rows4 = load_reporter("prism_rows4_report")
rows4_2x2 = load_reporter("prism_rows4_2x2_report")


class PrismRows4ReporterTests(unittest.TestCase):
    def test_rows4_rejects_extra_csv_field(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "rows4.csv"
            self._write_rows4(path)
            run_id, grouped = rows4.parse_raw(path, 2)
            self.assertEqual(run_id, 7)
            self.assertEqual(set(grouped), set(rows4.CONFIGS))

            lines = path.read_text(encoding="utf-8").splitlines()
            lines[1] += ",hidden"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(rows4.ReportError, "extra raw column"):
                rows4.parse_raw(path, 2)

    def test_rows4_2x2_rejects_extra_csv_field(self):
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "rows4-2x2.csv"
            self._write_rows4_2x2(path)
            run_id, grouped = rows4_2x2.parse_raw(path, 2)
            self.assertEqual(run_id, 11)
            self.assertEqual(set(grouped), set(rows4_2x2.CONFIGS))

            lines = path.read_text(encoding="utf-8").splitlines()
            lines[-1] += ",hidden"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(
                rows4_2x2.ReportError, "extra raw column"
            ):
                rows4_2x2.parse_raw(path, 2)

    @staticmethod
    def _write_rows4(path: Path) -> None:
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(rows4.FIELDS)
            for tier, group_size in rows4.CONFIGS:
                for block in range(2):
                    pattern = "ABBA" if block == 0 else "BAAB"
                    for position, method in enumerate(pattern):
                        writer.writerow(
                            [
                                7,
                                tier,
                                group_size,
                                block,
                                pattern,
                                position,
                                method,
                                100 + position,
                            ]
                        )

    @staticmethod
    def _write_rows4_2x2(path: Path) -> None:
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(rows4_2x2.FIELDS)
            for variant, group_size in rows4_2x2.CONFIGS:
                for sample in range(2):
                    pattern = "AB" if sample == 0 else "BA"
                    prepare = 10 if variant == "p2_lut" else ""
                    for position, method in enumerate(pattern):
                        writer.writerow(
                            [
                                11,
                                variant,
                                group_size,
                                sample,
                                pattern,
                                position,
                                method,
                                100 + position,
                                prepare,
                            ]
                        )


if __name__ == "__main__":
    unittest.main()
