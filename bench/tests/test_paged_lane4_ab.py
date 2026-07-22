import importlib.util
import math
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "paged_lane4_ab.py"
SPEC = importlib.util.spec_from_file_location("paged_lane4_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
paged = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paged)


class PagedLane4AbTests(unittest.TestCase):
    def test_order_adjustment_uses_geometric_mean_of_order_medians(self):
        ratios = {
            "contiguous-paged": [3.0, 4.0, 5.0],
            "paged-contiguous": [8.0, 9.0, 10.0],
        }
        self.assertEqual(paged.adjusted_ratio(ratios), 6.0)

    def test_bootstrap_is_deterministic_and_order_stratified(self):
        ratios = {
            "contiguous-paged": [4.0] * 8,
            "paged-contiguous": [9.0] * 8,
        }
        first = paged.bootstrap_ci(ratios, 1_000, 17)
        second = paged.bootstrap_ci(ratios, 1_000, 17)
        self.assertEqual(first, second)
        self.assertEqual(first, (6.0, 6.0))

    def test_stable_identity_includes_lane_state_and_every_runtime_abi(self):
        keys = (
            "runner_sha256",
            "model_sha256",
            "ids_sha256",
            "model_source_sha256",
            "decode_lane4_abi",
            "paged_decode_abi",
            "paged_kv_abi",
            "paged_token_txn_abi",
            "terminal_kv_positions",
            "capacity_kv_positions",
            "prompt_tokens_per_lane",
            "new_tokens_per_lane",
            "head_mode",
            "attention_mode",
            "pair_down_mode",
            "lane_states",
        )
        payload = {key: f"value-{index}" for index, key in enumerate(keys)}
        identity = paged.stable_identity(payload)
        self.assertEqual(set(identity), set(keys))
        changed = dict(payload)
        changed["lane_states"] = "different"
        self.assertNotEqual(identity, paged.stable_identity(changed))

    def test_median_rejects_empty_samples(self):
        with self.assertRaisesRegex(RuntimeError, "empty sample"):
            paged.median([])
        self.assertTrue(math.isclose(paged.median([1.0, 3.0]), 2.0))


if __name__ == "__main__":
    unittest.main()
