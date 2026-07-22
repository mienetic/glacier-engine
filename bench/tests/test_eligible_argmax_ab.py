from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "eligible_argmax_ab.py"
SPEC = importlib.util.spec_from_file_location("eligible_argmax_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
eligible_argmax_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = eligible_argmax_ab
SPEC.loader.exec_module(eligible_argmax_ab)


def raw_output(
    *,
    materialized_oracle: int = 17,
    full_winner: int | None = None,
    eligible_materialized_oracle: int | None = None,
    eligible_winner: int | None = None,
    samples: int = 2,
    schema: str = "glacier.eligible-argmax-kernel/raw-v2",
) -> bytes:
    full_winner = materialized_oracle if full_winner is None else full_winner
    eligible_materialized_oracle = (
        materialized_oracle
        if eligible_materialized_oracle is None
        else eligible_materialized_oracle
    )
    eligible_winner = (
        eligible_materialized_oracle
        if eligible_winner is None
        else eligible_winner
    )
    eligible_ids = eligible_argmax_ab.expected_eligible_ids(
        128, materialized_oracle, 2
    )
    mask_hash = eligible_argmax_ab.mask_sha256(128, eligible_ids)
    timings = ",".join(str(100 + index) for index in range(samples))
    sparse = ",".join(str(10 + index) for index in range(samples))
    checksum = (full_winner + eligible_winner) * samples
    return (
        "eligible_argmax: "
        f"schema={schema} "
        f"vocab=128 dim=32 group_size=8 threads=4 samples={samples} warmups=1 "
        f"materialized_oracle={materialized_oracle} full_winner={full_winner} "
        f"eligible_materialized_oracle={eligible_materialized_oracle} "
        f"eligible_winner={eligible_winner} eligible_rows=2 "
        "producer_rows=8 skipped_rows=120 overcomputed_rows=6 producer_runs=2 "
        "tile_scratch_bytes=1024 executor_scratch_bytes=64 "
        "greedy_abi=474c4d4800000002 eligibility_abi=474c564900000001 "
        f"optimize=ReleaseFast metal_enabled=0 zig=0.15.2 checksum={checksum}\n"
        f"mask_sha256: {mask_hash}\n"
        f"eligible_ids: {','.join(str(token) for token in eligible_ids)}\n"
        f"full_ns: {timings}\n"
        f"eligible_ns: {sparse}\n"
        "schedule: F,E,E,F repeated-by-round\n"
        "scope: real_glrt_weights deterministic_synthetic_f32_input "
        "isolated_lm_head excludes_load_and_decode\n"
    ).encode()


class EligibleArgmaxAbTests(unittest.TestCase):
    def test_strict_raw_contract_parses_exact_samples(self):
        parsed = eligible_argmax_ab.parse_stdout(raw_output(samples=4), 4)
        self.assertEqual(parsed["materialized_oracle"], 17)
        self.assertEqual(parsed["full_winner"], 17)
        self.assertEqual(parsed["eligible_materialized_oracle"], 17)
        self.assertEqual(parsed["eligible_winner"], 17)
        self.assertEqual(parsed["eligible_ids"], [17, 42])
        self.assertEqual(parsed["zig_version"], "0.15.2")
        self.assertEqual(parsed["producer_rows"], 8)
        self.assertEqual(parsed["full_ns"], [100, 101, 102, 103])
        self.assertEqual(parsed["eligible_ns"], [10, 11, 12, 13])

    def test_contract_rejects_schema_and_sample_drift(self):
        with self.assertRaisesRegex(eligible_argmax_ab.HarnessError, "raw schema"):
            eligible_argmax_ab.parse_stdout(
                raw_output(schema="glacier.eligible-argmax-kernel/raw-v1"), 2
            )
        with self.assertRaisesRegex(eligible_argmax_ab.HarnessError, "sample count"):
            eligible_argmax_ab.parse_stdout(raw_output(samples=2), 3)

    def test_contract_exposes_independent_oracle_mismatches(self):
        parsed = eligible_argmax_ab.parse_stdout(
            raw_output(full_winner=19, eligible_winner=23), 2
        )
        self.assertNotEqual(parsed["materialized_oracle"], parsed["full_winner"])
        self.assertNotEqual(
            parsed["eligible_materialized_oracle"], parsed["eligible_winner"]
        )

    def test_mask_reconstruction_is_deterministic_and_lsb_first(self):
        ids = eligible_argmax_ab.expected_eligible_ids(128, 17, 2)
        self.assertEqual(ids, [17, 42])
        self.assertEqual(
            eligible_argmax_ab.mask_sha256(128, ids),
            eligible_argmax_ab.mask_sha256(128, list(reversed(ids))),
        )
        self.assertNotEqual(
            eligible_argmax_ab.mask_sha256(128, ids),
            eligible_argmax_ab.mask_sha256(128, [17, 43]),
        )

    def test_paired_bootstrap_is_deterministic_and_positive(self):
        first = eligible_argmax_ab.bootstrap_ratio(
            [100, 110, 90, 105], [10, 11, 9, 10], 2_000, 123
        )
        second = eligible_argmax_ab.bootstrap_ratio(
            [100, 110, 90, 105], [10, 11, 9, 10], 2_000, 123
        )
        self.assertEqual(first, second)
        self.assertGreater(first["low_95"], 1.0)
        self.assertGreaterEqual(first["high_95"], first["low_95"])

    def test_block_bootstrap_requires_even_round_count(self):
        with self.assertRaisesRegex(
            eligible_argmax_ab.HarnessError, "even number"
        ):
            eligible_argmax_ab.bootstrap_ratio(
                [100, 110, 90], [10, 11, 9], 2_000, 123
            )

    def test_atomic_publication_refuses_to_clobber(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result.json"
            eligible_argmax_ab.publish_no_clobber(output, b"first\n")
            self.assertEqual(output.read_bytes(), b"first\n")
            with self.assertRaisesRegex(eligible_argmax_ab.HarnessError, "replace"):
                eligible_argmax_ab.publish_no_clobber(output, b"second\n")
            self.assertEqual(output.read_bytes(), b"first\n")


if __name__ == "__main__":
    unittest.main()
