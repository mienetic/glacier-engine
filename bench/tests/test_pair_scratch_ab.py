from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "pair_scratch_ab.py"
SPEC = importlib.util.spec_from_file_location("pair_scratch_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
scratch_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = scratch_ab
SPEC.loader.exec_module(scratch_ab)


TEST_DIM = 16
TEST_HIDDEN = 64
TEST_KV_DIM = 16
TEST_LAYERS = 4
TEST_PROMPT = 9
TEST_NEW_TOKENS = 4
TEST_THREADS = 4
TEST_BASE_BYTES = (8 * TEST_DIM + 2 * TEST_KV_DIM) * 4
TEST_MATERIALIZED_BYTES = TEST_BASE_BYTES + 3 * TEST_HIDDEN * 4
TEST_PAIR_SCALE_BYTES = ((TEST_HIDDEN + 15) // 16) * 4
TEST_COMPACT_BYTES = TEST_BASE_BYTES + TEST_HIDDEN + TEST_PAIR_SCALE_BYTES


def frame_manifest() -> dict[str, object]:
    value: dict[str, object] = {
        "schema": scratch_ab._frame.MODEL_MANIFEST_SCHEMA,
        "geometry": {
            "dim": TEST_DIM,
            "hidden_dim": TEST_HIDDEN,
            "layers": TEST_LAYERS,
            "kv_dim": TEST_KV_DIM,
        },
        "frame_ledger": {
            "base_tensor_payload_bytes": TEST_BASE_BYTES,
            "materialized_tensor_payload_bytes": TEST_MATERIALIZED_BYTES,
            "compact_pair_tensor_payload_bytes": TEST_COMPACT_BYTES,
            "reclaimed_tensor_payload_bytes": (
                TEST_MATERIALIZED_BYTES - TEST_COMPACT_BYTES
            ),
            "pair_q8_bytes": TEST_HIDDEN,
            "pair_scale_bytes": TEST_PAIR_SCALE_BYTES,
            "down_g8_layers": 0,
            "down_g16_layers": TEST_LAYERS,
        },
    }
    value["manifest_sha256"] = scratch_ab._frame._canonical_manifest_sha256(value)
    return value


def scratch_manifest(
    *,
    participants: int = TEST_THREADS,
    producer_groups: tuple[int, ...] = (8, 8, 8, 8),
) -> dict[str, object]:
    g8 = producer_groups.count(8)
    g16 = producer_groups.count(16)
    value: dict[str, object] = {
        "schema": scratch_ab.SCRATCH_MANIFEST_SCHEMA,
        "model_sha256": "1" * 64,
        "glrt_manifest_sha256": "2" * 64,
        "participants": participants,
        "layers": len(producer_groups),
        "producer_group_counts": {"g8": g8, "g16": g16},
        "producer_records": [
            {
                "layer": layer,
                "group_size": group_size,
                "canonical_descriptor_sha256": f"{layer + 3:064x}",
                "payload_concat_sha256": f"{layer + 11:064x}",
            }
            for layer, group_size in enumerate(producer_groups)
        ],
        "scratch_ledgers": {
            variant: scratch_ab._derive_ledger(
                participants=participants,
                producer_g8_layers=g8,
                producer_g16_layers=g16,
                variant=variant,
            )
            for variant in scratch_ab.VARIANTS
        },
        "claims": {
            "scratch_geometry_derived_from_pair_producer_groups": True,
            "down_groups_not_used_for_scratch_geometry": True,
        },
    }
    value["manifest_sha256"] = scratch_ab._frame._canonical_manifest_sha256(value)
    return value


def telemetry(
    *,
    variant: str,
    scratch_overrides: dict[str, int] | None = None,
    scratch_extra: str = "",
    prefill: str = "batch",
) -> str:
    expected_scratch = scratch_manifest()
    _, ledgers = scratch_ab._validated_scratch_ledgers(expected_scratch)
    ledger = dict(ledgers[variant])
    coverage = scratch_ab._frame._expected_pair_coverage(
        prompt_tokens=TEST_PROMPT,
        new_tokens=TEST_NEW_TOKENS,
        layers=TEST_LAYERS,
        prefill=prefill,
    )
    dispatches = coverage["outputless_m1"]
    scratch_counters = {
        "participants": TEST_THREADS,
        "producer_g8_layers": TEST_LAYERS,
        "producer_g16_layers": 0,
        "selected_g8_rows": ledger["selected_g8_rows"],
        "selected_g16_rows": ledger["selected_g16_rows"],
        "capacity_rows": ledger["capacity_rows"],
        "arrays_per_participant": 2,
        "branch_stride_rows": ledger["branch_stride_rows"],
        "participant_stride_rows": ledger["participant_stride_rows"],
        "f32_elements": ledger["f32_elements"],
        "bytes": ledger["bytes"],
        "fixed_counterfactual_bytes": ledger["fixed_counterfactual_bytes"],
        "reclaimed_bytes": ledger["reclaimed_bytes"],
        "allocations": 1,
        "fixed_dispatches": (dispatches if variant == scratch_ab.BASELINE else 0),
        "model_shaped_dispatches": (
            dispatches if variant == scratch_ab.CANDIDATE else 0
        ),
        "fallbacks": 0,
        "rejects": 0,
    }
    if scratch_overrides:
        scratch_counters.update(scratch_overrides)
    scratch_fields = " ".join(
        f"{name}={value}" for name, value in scratch_counters.items()
    )
    selected = "fixed-256" if variant == scratch_ab.BASELINE else "model-shaped"
    pair_counters = {
        "admissions": 1,
        "artifact_layers": TEST_LAYERS,
        "selected_layers": TEST_LAYERS,
        "pair_weight_bytes": 256,
        "pair_scale_bytes": 128,
        "separate_gate_bytes": 0,
        "separate_up_bytes": 0,
        **coverage,
        "fallbacks": 0,
        "rejects": 0,
    }
    pair_fields = " ".join(f"{name}={value}" for name, value in pair_counters.items())
    frame_fields = {
        "materialized_uses": 0,
        "compact_pair_uses": 1,
        "tensor_payload_bytes": TEST_COMPACT_BYTES,
        "materialized_counterfactual_bytes": TEST_MATERIALIZED_BYTES,
        "reclaimed_tensor_payload_bytes": (
            TEST_MATERIALIZED_BYTES - TEST_COMPACT_BYTES
        ),
        "pair_q8_bytes": TEST_HIDDEN,
        "pair_scale_bytes": TEST_PAIR_SCALE_BYTES,
        "down_g8_layers": 0,
        "down_g16_layers": TEST_LAYERS,
    }
    frame_fields_text = " ".join(
        f"{name}={value}" for name, value in frame_fields.items()
    )
    decode_runs = TEST_NEW_TOKENS - 1
    return (
        "load: mode=prepared artifact=glrt ms=2.0\n"
        f"schedule: attention=serial layers={TEST_LAYERS}\n"
        "ready: phase=request_ready ms=3.0\n"
        "phases: prefill_ms=4.000 decode_ms=5.000 sampling_ms=0.100 "
        f"decode_runs={decode_runs} attention_graphs=0 attention_dispatches=0 "
        "handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 "
        "fused_gqa_dispatches=0 paired_mlp_graphs=0 paired_mlp_dispatches=0\n"
        "pair_nibble: policy=pair-nibble-required artifact=pair-nibble "
        f"selected=pair-nibble {pair_fields} storage_abi=47504e4200000001 "
        "executor_abi=47504e4500000005\n"
        "decode_frame: policy=compact-pair-required layout=pair-q8 "
        f"{frame_fields_text} abi=47504e4600000001\n"
        f"pair_scratch: policy={variant} selected={selected} "
        f"layout=executor-private-f32 {scratch_fields} "
        f"abi=47504e5300000001{scratch_extra}\n"
        "decode_plan: mode=checked sets=0 set_bytes=0 layer_builds=0 "
        "layer_binds=0 checked_dispatches=0 sealed_dispatches=0 "
        "fallbacks=0 rejects=0 build_ms=0.000 abi=4753445000000004\n"
        f"greedy_output: mode=materialized materialized_projections={TEST_NEW_TOKENS} "
        "logitless_projections=0 producer_rows=0 tile_output_bytes=0 "
        "argmax_scan_rows=0 scratch_bytes=0 materialized_logits_bytes=128 "
        "steady_state_reclaimed_bytes=0 fallbacks=0 rejects=0 "
        "abi=474c4d4800000002\n"
        f"time: 9.10 ms ({TEST_NEW_TOKENS * 1000.0 / 9.1:.1f} tok/s, "
        f"prefilled {TEST_PROMPT}, prefill={prefill})\n"
    )


def parse(value: str, variant: str, *, prefill: str = "batch") -> dict[str, object]:
    return scratch_ab.parse_telemetry(
        value,
        variant=variant,
        prompt_tokens=TEST_PROMPT,
        new_tokens=TEST_NEW_TOKENS,
        prefill=prefill,
        expected_frame_manifest=frame_manifest(),
        expected_scratch_manifest=scratch_manifest(),
    )


class FakePairRecord:
    def __init__(self, layer: int, group_size: int):
        self.layer_idx = layer
        self.group_size = group_size
        self.role = scratch_ab._pair.GLRT_ROLE_PAIR
        self.kind = scratch_ab._pair.GLRT_OTHER_KIND
        self.canonical_descriptor_sha256 = f"{layer + 5:064x}"
        self.payload_concat_sha256 = f"{layer + 17:064x}"

    def identity(self) -> tuple[str, int, int]:
        return ("role", self.layer_idx, self.role)


class PairScratchAbTests(unittest.TestCase):
    def test_tile_row_table_and_exact_ledgers(self):
        expected = {
            1: (256, 256),
            2: (32, 64),
            3: (32, 64),
            4: (64, 128),
            5: (64, 128),
            6: (64, 128),
            7: (256, 256),
            8: (256, 256),
        }
        for participants, rows in expected.items():
            self.assertEqual(scratch_ab.pair_tile_rows(participants, 8), rows[0])
            self.assertEqual(scratch_ab.pair_tile_rows(participants, 16), rows[1])
        fixed = scratch_ab._derive_ledger(
            participants=4,
            producer_g8_layers=4,
            producer_g16_layers=0,
            variant=scratch_ab.BASELINE,
        )
        shaped = scratch_ab._derive_ledger(
            participants=4,
            producer_g8_layers=4,
            producer_g16_layers=0,
            variant=scratch_ab.CANDIDATE,
        )
        self.assertEqual(fixed["bytes"], 8192)
        self.assertEqual(shaped["bytes"], 2048)
        self.assertEqual(shaped["reclaimed_bytes"], 6144)

    def test_manifest_derives_geometry_from_pair_producer_not_down(self):
        records = [
            FakePairRecord(0, 8),
            FakePairRecord(1, 16),
            FakePairRecord(2, 8),
            FakePairRecord(3, 16),
        ]
        image = SimpleNamespace(
            header=SimpleNamespace(config={"layers": 4}),
            records=records,
            manifest_sha256="a" * 64,
        )
        fingerprint = {"identity": [1, 2], "sha256": "1" * 64}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pair.glrt"
            path.write_bytes(b"fixture")
            with (
                mock.patch.object(
                    scratch_ab._attention,
                    "fingerprint",
                    return_value=fingerprint,
                ),
                mock.patch.object(
                    scratch_ab._pair, "parse_glrt_image", return_value=image
                ),
                mock.patch.object(scratch_ab._pair, "_require_pair_record"),
            ):
                manifest = scratch_ab.derive_pair_scratch_manifest(
                    path, model_sha256="1" * 64, participants=4
                )
        self.assertEqual(manifest["producer_group_counts"], {"g8": 2, "g16": 2})
        shaped = manifest["scratch_ledgers"][scratch_ab.CANDIDATE]
        self.assertEqual(shaped["selected_g8_rows"], 64)
        self.assertEqual(shaped["selected_g16_rows"], 128)
        self.assertEqual(shaped["bytes"], 4096)

    def test_manifest_validation_rejects_group_or_ledger_tampering(self):
        bad_groups = scratch_manifest()
        bad_groups["producer_group_counts"] = {"g8": 3, "g16": 1}
        bad_groups["manifest_sha256"] = scratch_ab._frame._canonical_manifest_sha256(
            {
                key: value
                for key, value in bad_groups.items()
                if key != "manifest_sha256"
            }
        )
        bad_ledger = scratch_manifest()
        bad_ledger["scratch_ledgers"][scratch_ab.CANDIDATE]["bytes"] += 4
        bad_ledger["manifest_sha256"] = scratch_ab._frame._canonical_manifest_sha256(
            {
                key: value
                for key, value in bad_ledger.items()
                if key != "manifest_sha256"
            }
        )
        boolean_ledger = scratch_manifest(participants=1)
        boolean_ledger["scratch_ledgers"][scratch_ab.CANDIDATE]["reclaimed_bytes"] = (
            False
        )
        boolean_ledger["manifest_sha256"] = (
            scratch_ab._frame._canonical_manifest_sha256(
                {
                    key: value
                    for key, value in boolean_ledger.items()
                    if key != "manifest_sha256"
                }
            )
        )
        for value in (bad_groups, bad_ledger, boolean_ledger):
            with self.subTest(value=value["producer_group_counts"]):
                with self.assertRaises(scratch_ab.HarnessError):
                    scratch_ab._validated_scratch_ledgers(value)

    def test_parser_accepts_exact_fixed_and_model_shaped_receipts(self):
        fixed = parse(telemetry(variant=scratch_ab.BASELINE), scratch_ab.BASELINE)
        shaped = parse(telemetry(variant=scratch_ab.CANDIDATE), scratch_ab.CANDIDATE)
        self.assertEqual(fixed["pair_scratch_bytes"], 8192)
        self.assertEqual(shaped["pair_scratch_bytes"], 2048)
        self.assertEqual(shaped["pair_scratch_reclaimed_bytes"], 6144)
        self.assertEqual(fixed["pair_scratch_fixed_dispatches"], 12)
        self.assertEqual(shaped["pair_scratch_model_shaped_dispatches"], 12)
        self.assertEqual(
            shaped["decode_frame_tensor_payload_bytes"], TEST_COMPACT_BYTES
        )
        self.assertEqual(shaped["pair_nibble_executor_abi"], "47504e4500000005")

    def test_parser_accepts_serial_dispatch_coverage(self):
        parsed = parse(
            telemetry(variant=scratch_ab.CANDIDATE, prefill="serial"),
            scratch_ab.CANDIDATE,
            prefill="serial",
        )
        self.assertEqual(parsed["pair_scratch_model_shaped_dispatches"], 48)
        self.assertEqual(parsed["pair_nibble_outputless_m1"], 48)

    def test_scratch_line_must_be_exactly_once_and_canonical(self):
        valid = telemetry(variant=scratch_ab.CANDIDATE)
        line = next(
            line for line in valid.splitlines() if line.startswith("pair_scratch:")
        )
        cases = (
            valid + line + "\n",
            valid.replace(line + "\n", ""),
            telemetry(variant=scratch_ab.CANDIDATE, scratch_extra=" extra=1"),
        )
        for value in cases:
            with self.subTest(tail=value[-100:]):
                with self.assertRaises(scratch_ab.HarnessError):
                    parse(value, scratch_ab.CANDIDATE)

    def test_wrong_producer_group_capacity_and_bytes_fail_closed(self):
        cases = (
            {"producer_g8_layers": 0, "producer_g16_layers": 4},
            {"selected_g8_rows": 128},
            {"capacity_rows": 128},
            {"branch_stride_rows": 32},
            {"participant_stride_rows": 64},
            {"f32_elements": 1},
            {"bytes": 1},
            {"fixed_counterfactual_bytes": 4096},
            {"reclaimed_bytes": 1},
            {"allocations": 0},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                with self.assertRaises(scratch_ab.HarnessError):
                    parse(
                        telemetry(
                            variant=scratch_ab.CANDIDATE,
                            scratch_overrides=overrides,
                        ),
                        scratch_ab.CANDIDATE,
                    )

    def test_dispatch_fallback_reject_and_abi_fail_closed(self):
        cases = (
            telemetry(
                variant=scratch_ab.CANDIDATE,
                scratch_overrides={"model_shaped_dispatches": 11},
            ),
            telemetry(
                variant=scratch_ab.CANDIDATE,
                scratch_overrides={"fixed_dispatches": 1},
            ),
            telemetry(
                variant=scratch_ab.CANDIDATE,
                scratch_overrides={"fallbacks": 1},
            ),
            telemetry(
                variant=scratch_ab.CANDIDATE,
                scratch_overrides={"rejects": 1},
            ),
            telemetry(variant=scratch_ab.CANDIDATE).replace(
                "abi=47504e5300000001", "abi=47504e5300000002"
            ),
        )
        for value in cases:
            with self.subTest(tail=value[-120:]):
                with self.assertRaises(scratch_ab.HarnessError):
                    parse(value, scratch_ab.CANDIDATE)

    def test_policy_or_selected_arm_mismatch_fails_closed(self):
        fixed = telemetry(variant=scratch_ab.BASELINE)
        cases = (
            fixed.replace("policy=fixed-256-required", "policy=model-shaped-required"),
            fixed.replace("selected=fixed-256", "selected=model-shaped"),
            fixed.replace("layout=executor-private-f32", "layout=none"),
        )
        for value in cases:
            with self.assertRaises(scratch_ab.HarnessError):
                parse(value, scratch_ab.BASELINE)

    def test_commands_keep_compact_frame_and_differ_only_by_scratch_policy(self):
        config = scratch_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/pair.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        fixed = scratch_ab.build_command(
            config, scratch_ab.BASELINE, Path("/tmp/o.ids")
        )
        shaped = scratch_ab.build_command(
            config, scratch_ab.CANDIDATE, Path("/tmp/o.ids")
        )
        differences = [
            index
            for index, values in enumerate(zip(fixed, shaped))
            if values[0] != values[1]
        ]
        self.assertEqual(len(differences), 1)
        self.assertEqual(fixed[differences[0] - 1], "--pair-scratch")
        self.assertIn("compact-pair-required", fixed)
        self.assertIn("pair-nibble-required", fixed)

    def test_lightweight_campaign_builds_exact_cross_arm_ledger(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ids = root / "prompt.ids"
            ids.write_text(" ".join(str(value) for value in range(TEST_PROMPT)))
            config = scratch_ab.Config(
                binary=root / "glacier",
                model=root / "pair.glrt",
                ids=ids,
                output=None,
                cwd=root,
                samples_per_variant=4,
                warmups_per_variant=1,
                new_tokens=TEST_NEW_TOKENS,
                threads=TEST_THREADS,
                schedule_seed=8,
                bootstrap_seed=11,
                bootstrap_resamples=100,
            )
            artifacts = {
                "binary": {"identity": [1, 2], "sha256": "3" * 64},
                "pair_model": {"identity": [3, 4], "sha256": "1" * 64},
            }

            def fake_run_variant(
                _config,
                variant,
                _completion_path,
                _prompt_ids,
                _artifact_before,
                _frame_manifest,
                _scratch_manifest,
            ):
                metrics = parse(telemetry(variant=variant), variant)
                if variant == scratch_ab.CANDIDATE:
                    metrics["decode_ms"] = 2.5
                    metrics["internal_ms"] = 7.5
                metrics["harness_wall_ms"] = (
                    10.0 if variant == scratch_ab.BASELINE else 8.0
                )
                completion_ids = [7, 8, 9, 10]
                digest = scratch_ab.sha256_bytes(
                    scratch_ab.canonical_ids_bytes(completion_ids)
                )
                return {
                    "variant": variant,
                    "argv": [],
                    "metrics": metrics,
                    "completion_ids": completion_ids,
                    "completion_ids_sha256": digest,
                    "completion_file_sha256": digest,
                    "telemetry_sha256": "4" * 64,
                    "telemetry_output": "fixture",
                    "output_capture": {"raw_sha256": "4" * 64},
                    "exit_status": 0,
                }

            with (
                mock.patch.object(
                    scratch_ab, "fingerprint_artifacts", return_value=artifacts
                ),
                mock.patch.object(
                    scratch_ab, "verify_artifacts", return_value=artifacts
                ),
                mock.patch.object(scratch_ab._attention, "assert_artifact_identities"),
                mock.patch.object(
                    scratch_ab._frame,
                    "derive_pair_model_manifest",
                    return_value=frame_manifest(),
                ),
                mock.patch.object(
                    scratch_ab,
                    "derive_pair_scratch_manifest",
                    return_value=scratch_manifest(),
                ),
                mock.patch.object(
                    scratch_ab, "run_variant", side_effect=fake_run_variant
                ),
            ):
                result = scratch_ab.run_benchmark(config)

        self.assertEqual(result["schema"], scratch_ab.SCHEMA)
        self.assertEqual(result["status"], "evidence-valid")
        self.assertEqual(len(result["samples"]), 8)
        self.assertEqual(len(result["warmups"]), 2)
        self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8, 9, 10])
        ledger = result["logical_pair_scratch_byte_ledger"]
        self.assertEqual(ledger["fixed_256_scratch_bytes"], 8192)
        self.assertEqual(ledger["model_shaped_scratch_bytes"], 2048)
        self.assertEqual(ledger["reclaimed_scratch_bytes"], 6144)
        self.assertEqual(ledger["fixed_over_model_shaped_scratch_ratio"], 4.0)
        self.assertFalse(ledger["physical_memory_claim"])
        self.assertEqual(
            result["fixed_256_over_model_shaped"]["decode_ms"]["estimate"],
            2.0,
        )
        self.assertEqual(
            result["contract"]["letter_mapping"],
            {"A": scratch_ab.CANDIDATE, "B": scratch_ab.BASELINE},
        )
        self.assertEqual(
            result["process_output_capture_contract"]["raw_reserved_prefix_guard"][
                "additional_prefixes"
            ],
            ["pair_nibble:", "decode_frame:", "pair_scratch:"],
        )

    def test_paired_bootstrap_direction_and_reserved_prefix(self):
        samples = []
        for block in range(2):
            for variant, values in (
                (scratch_ab.BASELINE, (10.0, 12.0)),
                (scratch_ab.CANDIDATE, (5.0, 6.0)),
            ):
                samples.extend(
                    {
                        "variant": variant,
                        "block_index": block,
                        "metrics": {"decode_ms": value},
                    }
                    for value in values
                )
        ratio = scratch_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=7,
            confidence=0.95,
        )
        self.assertEqual(ratio["estimate"], 2.0)
        self.assertIn("fixed_256_over_model_shaped", ratio["direction"])
        self.assertIn(
            b"pair_scratch:",
            scratch_ab._resource_support()._TELEMETRY_PREFIXES,
        )

    def test_parser_rejects_tampered_manifest_hash(self):
        manifest = scratch_manifest()
        manifest["manifest_sha256"] = "0" * 64
        with self.assertRaisesRegex(scratch_ab.HarnessError, "manifest hash"):
            scratch_ab.parse_telemetry(
                telemetry(variant=scratch_ab.CANDIDATE),
                variant=scratch_ab.CANDIDATE,
                prompt_tokens=TEST_PROMPT,
                new_tokens=TEST_NEW_TOKENS,
                prefill="batch",
                expected_frame_manifest=frame_manifest(),
                expected_scratch_manifest=manifest,
            )


if __name__ == "__main__":
    unittest.main()
