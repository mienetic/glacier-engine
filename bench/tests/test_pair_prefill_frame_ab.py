from __future__ import annotations

import importlib.util
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "pair_prefill_frame_ab.py"
SPEC = importlib.util.spec_from_file_location("pair_prefill_frame_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
prefill_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = prefill_ab
SPEC.loader.exec_module(prefill_ab)


TEST_DIM = 896
TEST_HIDDEN = 4864
TEST_KV_DIM = 128
TEST_LAYERS = 4
TEST_PROMPT = 128
TEST_THREADS = 4
TEST_PRODUCER_SCALE_STRIDE = 56
TEST_PAIR_SCALE_STRIDE = 304
TEST_SOURCE_COMMIT = "a" * 40
TEST_SOURCE_PATH = "README.md"
TEST_SOURCE_SHA256 = "3" * 64
TEST_SOURCE_ID = f"git-blob:{TEST_SOURCE_COMMIT}:{TEST_SOURCE_PATH}"
TEST_TOKENIZER_ID = "fixture-tokenizer"
TEST_TOKENIZER_SHA256 = "4" * 64


def write_frozen_provenance(root: Path, ids: list[int]) -> tuple[Path, str, str]:
    raw_ids = prefill_ab.canonical_ids_bytes(ids)
    ids_path = root / "prompt.ids"
    ids_path.write_bytes(raw_ids)
    ids_sha256 = hashlib.sha256(raw_ids).hexdigest()
    value = {
        "schema": prefill_ab.FROZEN_PROVENANCE_SCHEMA,
        "source": {
            "kind": "git-blob",
            "commit": TEST_SOURCE_COMMIT,
            "path": TEST_SOURCE_PATH,
            "utf8_bytes": 1234,
            "sha256": TEST_SOURCE_SHA256,
        },
        "tokenizer": {
            "model": TEST_TOKENIZER_ID,
            "artifact": "tokenizer.json",
            "artifact_sha256": TEST_TOKENIZER_SHA256,
        },
        "serialization": (
            "ASCII decimal u32 IDs separated by one space and terminated by LF"
        ),
        "prefixes": [
            {
                "tokens": 128,
                "path": "prompt.ids" if len(ids) == 128 else "p128.ids",
                "sha256": ids_sha256 if len(ids) == 128 else "5" * 64,
            },
            {
                "tokens": 512,
                "path": "prompt.ids" if len(ids) == 512 else "p512.ids",
                "sha256": ids_sha256 if len(ids) == 512 else "6" * 64,
            },
            {
                "tokens": 2048,
                "path": "prompt.ids" if len(ids) == 2048 else "p2048.ids",
                "sha256": ids_sha256 if len(ids) == 2048 else "7" * 64,
            },
        ],
    }
    raw = (json.dumps(value, sort_keys=True) + "\n").encode("utf-8")
    path = root / "provenance.json"
    path.write_bytes(raw)
    return path, hashlib.sha256(raw).hexdigest(), ids_sha256


def frame_manifest() -> dict[str, object]:
    base = (8 * TEST_DIM + 2 * TEST_KV_DIM) * 4
    materialized = base + 3 * TEST_HIDDEN * 4
    pair_scale = TEST_PAIR_SCALE_STRIDE * 4
    compact = base + TEST_HIDDEN + pair_scale
    value: dict[str, object] = {
        "schema": prefill_ab._frame.MODEL_MANIFEST_SCHEMA,
        "geometry": {
            "dim": TEST_DIM,
            "hidden_dim": TEST_HIDDEN,
            "layers": TEST_LAYERS,
            "kv_dim": TEST_KV_DIM,
        },
        "frame_ledger": {
            "base_tensor_payload_bytes": base,
            "materialized_tensor_payload_bytes": materialized,
            "compact_pair_tensor_payload_bytes": compact,
            "reclaimed_tensor_payload_bytes": materialized - compact,
            "pair_q8_bytes": TEST_HIDDEN,
            "pair_scale_bytes": pair_scale,
            "down_g8_layers": 0,
            "down_g16_layers": TEST_LAYERS,
        },
        "down_records": [
            {
                "layer": layer,
                "group_size": 16,
                "activation_scale_count": TEST_PAIR_SCALE_STRIDE,
            }
            for layer in range(TEST_LAYERS)
        ],
    }
    value["manifest_sha256"] = prefill_ab._frame._canonical_manifest_sha256(value)
    return value


def model_manifest() -> dict[str, object]:
    ledgers = {
        variant: prefill_ab._derive_prefill_ledger(
            variant=variant,
            prompt_tokens=TEST_PROMPT,
            threads=TEST_THREADS,
            dim=TEST_DIM,
            kv_dim=TEST_KV_DIM,
            hidden=TEST_HIDDEN,
            max_producer_scale_stride=TEST_PRODUCER_SCALE_STRIDE,
            pair_scale_stride=TEST_PAIR_SCALE_STRIDE,
        )
        for variant in (prefill_ab.BASELINE, *prefill_ab.CANDIDATES)
    }
    frame = frame_manifest()
    value: dict[str, object] = {
        "schema": prefill_ab.MODEL_MANIFEST_SCHEMA,
        "model_sha256": "1" * 64,
        "glrt_manifest_sha256": "2" * 64,
        "frame_manifest": frame,
        "frame_manifest_sha256": frame["manifest_sha256"],
        "geometry": {
            "dim": TEST_DIM,
            "hidden_dim": TEST_HIDDEN,
            "kv_dim": TEST_KV_DIM,
            "layers": TEST_LAYERS,
            "prompt_tokens": TEST_PROMPT,
            "threads": TEST_THREADS,
            "chunk_rows": prefill_ab.PREFILL_CHUNK_ROWS,
            "compact_tile_rows": prefill_ab.COMPACT_TILE_ROWS,
            "max_producer_scale_stride": TEST_PRODUCER_SCALE_STRIDE,
            "pair_scale_stride": TEST_PAIR_SCALE_STRIDE,
        },
        "producer_group_counts": {"g8": TEST_LAYERS, "g16": 0},
        "down_group_counts": {"g8": 0, "g16": TEST_LAYERS},
        "producer_records": [
            {
                "layer": layer,
                "group_size": 8,
                "activation_scale_count": (TEST_DIM + 31) // 32,
                "canonical_descriptor_sha256": f"{layer + 10:064x}",
                "payload_concat_sha256": f"{layer + 20:064x}",
            }
            for layer in range(TEST_LAYERS)
        ],
        "common_projection_records": [
            {
                "layer": layer,
                "kind": kind,
                "group_size": 16,
                "activation_scale_count": TEST_PRODUCER_SCALE_STRIDE,
                "canonical_descriptor_sha256": f"{100 + layer * 4 + kind:064x}",
                "payload_concat_sha256": f"{200 + layer * 4 + kind:064x}",
            }
            for layer in range(TEST_LAYERS)
            for kind in prefill_ab.GLRT_ATTN_KINDS
        ],
        "prefill_ledgers": ledgers,
        "claims": {},
    }
    return prefill_ab._with_manifest_hash(value)


def telemetry(
    variant: str,
    *,
    graph_ms: float = 4.0,
    prefill_overrides: dict[str, int] | None = None,
    duplicate_prefill: bool = False,
) -> str:
    manifest = model_manifest()
    _, groups, ledgers = prefill_ab._validated_prefill_manifest(manifest)
    ledger = dict(ledgers[variant])
    runtime = prefill_ab._runtime_prefill_counts(
        prompt_tokens=TEST_PROMPT,
        layers=TEST_LAYERS,
        capsule_rows=ledger["capsule_rows"],
    )
    selected_policy = {
        prefill_ab.BASELINE: "materialized",
        "compact-32-required": "compact-32",
        "compact-64-required": "compact-64",
    }[variant]
    prefill_fields = {
        "producer_g8_layers": TEST_LAYERS,
        "producer_g16_layers": 0,
        "down_g8_layers": 0,
        "down_g16_layers": TEST_LAYERS,
        **ledger,
        "chunk_count": runtime["chunk_count"],
        "full_chunks": runtime["full_chunks"],
        "tail_chunks": runtime["tail_chunks"],
        "peak_active_rows": runtime["peak_active_rows"],
        "materialized_layer_uses": (
            runtime["layer_uses"] if variant == prefill_ab.BASELINE else 0
        ),
        "compact_layer_uses": (
            0 if variant == prefill_ab.BASELINE else runtime["layer_uses"]
        ),
        "capsules": 0 if variant == prefill_ab.BASELINE else runtime["capsules"],
        "pair_input_rows": runtime["pair_rows"],
        "pair_output_rows": runtime["pair_rows"],
        "prepared_down_rows": (
            0 if variant == prefill_ab.BASELINE else runtime["pair_rows"]
        ),
        "prepared_down_dispatches": (
            0 if variant == prefill_ab.BASELINE else runtime["capsules"]
        ),
        "arena_sets": 1,
        "fallbacks": 0,
        "rejects": 0,
    }
    if prefill_overrides:
        prefill_fields.update(prefill_overrides)
    prefill_order = (
        "producer_g8_layers",
        "producer_g16_layers",
        "down_g8_layers",
        "down_g16_layers",
        "chunk_capacity",
        "chunk_count",
        "full_chunks",
        "tail_chunks",
        "peak_active_rows",
        "capsule_rows",
        "tile_rows",
        "task_slots",
        "materialized_layer_uses",
        "compact_layer_uses",
        "capsules",
        "pair_input_rows",
        "pair_output_rows",
        "prepared_down_rows",
        "prepared_down_dispatches",
        "common_payload_bytes",
        "gate_bytes",
        "up_bytes",
        "silu_bytes",
        "q_scratch_bytes",
        "scale_scratch_bytes",
        "pair_q8_bytes",
        "pair_scale_bytes",
        "gate_tile_bytes",
        "up_tile_bytes",
        "tensor_payload_bytes",
        "materialized_counterfactual_bytes",
        "reclaimed_tensor_payload_bytes",
        "arena_sets",
        "logical_slices",
        "fallbacks",
        "rejects",
    )
    prefill_line = (
        f"pair_prefill_frame: selected_policy={selected_policy} "
        + " ".join(f"{name}={prefill_fields[name]}" for name in prefill_order)
        + " abi=47504e5000000001\n"
    )

    coverage = prefill_ab._pair._expected_pair_coverage(
        prompt_tokens=TEST_PROMPT,
        new_tokens=1,
        layers=TEST_LAYERS,
        prefill="batch",
    )
    pair_fields = {
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
    pair_text = " ".join(f"{name}={value}" for name, value in pair_fields.items())

    frame = frame_manifest()["frame_ledger"]
    assert isinstance(frame, dict)
    frame_fields = {
        "materialized_uses": 0,
        "compact_pair_uses": 1,
        "tensor_payload_bytes": frame["compact_pair_tensor_payload_bytes"],
        "materialized_counterfactual_bytes": frame["materialized_tensor_payload_bytes"],
        "reclaimed_tensor_payload_bytes": frame["reclaimed_tensor_payload_bytes"],
        "pair_q8_bytes": frame["pair_q8_bytes"],
        "pair_scale_bytes": frame["pair_scale_bytes"],
        "down_g8_layers": 0,
        "down_g16_layers": TEST_LAYERS,
    }
    frame_text = " ".join(f"{name}={value}" for name, value in frame_fields.items())

    selected_g8 = prefill_ab._pair_tile_rows(TEST_THREADS, 8)
    scratch_fields = {
        "participants": TEST_THREADS,
        "producer_g8_layers": TEST_LAYERS,
        "producer_g16_layers": 0,
        "selected_g8_rows": selected_g8,
        "selected_g16_rows": 0,
        "capacity_rows": 256,
        "arrays_per_participant": 2,
        "branch_stride_rows": 256,
        "participant_stride_rows": 512,
        "f32_elements": 2048,
        "bytes": 8192,
        "fixed_counterfactual_bytes": 8192,
        "reclaimed_bytes": 0,
        "allocations": 1,
        "fixed_dispatches": 0,
        "model_shaped_dispatches": 0,
        "fallbacks": 0,
        "rejects": 0,
    }
    scratch_text = " ".join(f"{name}={value}" for name, value in scratch_fields.items())
    prefill_ms = graph_ms + 0.5
    internal_ms = prefill_ms + 0.1
    tps = 1000.0 / internal_ms
    result = (
        "load: mode=prepared artifact=glrt ms=2.000\n"
        f"schedule: attention=serial layers={TEST_LAYERS}\n"
        "ready: phase=request_ready ms=3.000\n"
        f"phases: prefill_ms={prefill_ms:.3f} decode_ms=0.000 "
        "sampling_ms=0.100 decode_runs=0 attention_graphs=0 "
        "attention_dispatches=0 handoff_graphs=0 handoff_dispatches=0 "
        "fused_gqa_graphs=0 fused_gqa_dispatches=0 paired_mlp_graphs=0 "
        "paired_mlp_dispatches=0\n"
        f"prefill_phase: graph_ms={graph_ms:.3f} first_head_ms=0.500 "
        "abi=4750485300000001\n"
        "pair_nibble: policy=pair-nibble-required artifact=pair-nibble "
        f"selected=pair-nibble {pair_text} storage_abi=47504e4200000001 "
        "executor_abi=47504e4500000005\n"
        "decode_frame: policy=compact-pair-required layout=pair-q8 "
        f"{frame_text} abi=47504e4600000001\n"
        "pair_scratch: policy=fixed-256-required selected=fixed-256 "
        f"layout=executor-private-f32 {scratch_text} "
        "abi=47504e5300000001\n"
        f"{prefill_line}"
        "decode_plan: mode=checked sets=0 set_bytes=0 layer_builds=0 "
        "layer_binds=0 checked_dispatches=0 sealed_dispatches=0 "
        "fallbacks=0 rejects=0 build_ms=0.000 abi=4753445000000004\n"
        "greedy_output: mode=materialized materialized_projections=1 "
        "logitless_projections=0 producer_rows=0 tile_output_bytes=0 "
        "argmax_scan_rows=0 scratch_bytes=0 materialized_logits_bytes=128 "
        "steady_state_reclaimed_bytes=0 fallbacks=0 rejects=0 "
        "abi=474c4d4800000002\n"
        f"time: {internal_ms:.2f} ms ({tps:.1f} tok/s, "
        f"prefilled {TEST_PROMPT}, prefill=batch)\n"
    )
    if duplicate_prefill:
        result += prefill_line
    return result


def parse(value: str, variant: str) -> dict[str, object]:
    return prefill_ab.parse_telemetry(
        value,
        variant=variant,
        prompt_tokens=TEST_PROMPT,
        threads=TEST_THREADS,
        expected_model_manifest=model_manifest(),
    )


def config(root: Path, **overrides) -> prefill_ab.Config:
    values = {
        "binary": root / "glacier",
        "model": root / "pair.glrt",
        "ids": root / "prompt.ids",
        "provenance": root / "provenance.json",
        "output": None,
        "cwd": root,
        "prompt_profile": "p128",
        "campaign": "primary",
        "candidate": "compact-64-required",
        "source_id": TEST_SOURCE_ID,
        "source_sha256": TEST_SOURCE_SHA256,
        "tokenizer_id": TEST_TOKENIZER_ID,
        "tokenizer_sha256": TEST_TOKENIZER_SHA256,
        "samples_per_variant": 4,
        "warmups_per_variant": 1,
        "schedule_seed": 8,
        "bootstrap_seed": 11,
        "bootstrap_resamples": 100,
        "provenance_sha256": "9" * 64,
    }
    values.update(overrides)
    return prefill_ab.Config(**values)


class PairPrefillFrameAbTests(unittest.TestCase):
    def test_cli_defaults_profiles_and_campaign_seeds(self):
        base = [
            "--binary",
            "glacier",
            "--pair-model",
            "pair.glrt",
            "--ids",
            "prompt.ids",
            "--provenance",
            "provenance.json",
            "--profile",
            "p512",
            "--campaign",
            "replication",
            "--source-id",
            TEST_SOURCE_ID,
            "--source-sha256",
            "1" * 64,
            "--tokenizer-id",
            TEST_TOKENIZER_ID,
            "--tokenizer-sha256",
            "2" * 64,
            "--provenance-sha256",
            "9" * 64,
            "--output",
            "-",
        ]
        args = prefill_ab.argument_parser().parse_args(base)
        parsed = prefill_ab.config_from_args(args)
        self.assertEqual(parsed.samples_per_variant, 32)
        self.assertEqual(parsed.warmups_per_variant, 2)
        self.assertEqual(parsed.threads, 4)
        self.assertEqual(parsed.prompt_profile, "p512")
        self.assertEqual(parsed.campaign, "replication")
        self.assertEqual(
            parsed.schedule_seed,
            prefill_ab.CAMPAIGN_SEEDS["replication"]["schedule"],
        )
        self.assertNotEqual(
            prefill_ab.CAMPAIGN_SEEDS["primary"],
            prefill_ab.CAMPAIGN_SEEDS["replication"],
        )
        patterns = prefill_ab.build_patterns(32, 1234)
        self.assertEqual(patterns.count("ABBA"), 8)
        self.assertEqual(patterns.count("BAAB"), 8)

    def test_qwen_w32_w64_and_materialized_ledgers_are_exact(self):
        expected = {
            128: {
                prefill_ab.BASELINE: (12_664_832, 0),
                "compact-32-required": (4_663_296, 8_001_536),
                "compact-64-required": (4_923_392, 7_741_440),
            },
            512: {
                prefill_ab.BASELINE: (25_329_664, 0),
                "compact-32-required": (9_066_496, 16_263_168),
                "compact-64-required": (9_326_592, 16_003_072),
            },
            2048: {
                prefill_ab.BASELINE: (25_329_664, 0),
                "compact-32-required": (9_066_496, 16_263_168),
                "compact-64-required": (9_326_592, 16_003_072),
            },
        }
        for prompt_tokens, variants in expected.items():
            for variant, (total, reclaimed) in variants.items():
                with self.subTest(prompt_tokens=prompt_tokens, variant=variant):
                    ledger = prefill_ab._derive_prefill_ledger(
                        variant=variant,
                        prompt_tokens=prompt_tokens,
                        threads=4,
                        dim=896,
                        kv_dim=128,
                        hidden=4864,
                        max_producer_scale_stride=56,
                        pair_scale_stride=304,
                    )
                    self.assertEqual(ledger["tensor_payload_bytes"], total)
                    self.assertEqual(
                        ledger["reclaimed_tensor_payload_bytes"], reclaimed
                    )
                    self.assertEqual(
                        ledger["materialized_counterfactual_bytes"],
                        variants[prefill_ab.BASELINE][0],
                    )

    def test_parse_all_arms_and_exact_capsule_coverage(self):
        materialized = parse(telemetry(prefill_ab.BASELINE), prefill_ab.BASELINE)
        compact32 = parse(telemetry("compact-32-required"), "compact-32-required")
        compact64 = parse(telemetry("compact-64-required"), "compact-64-required")
        self.assertEqual(materialized["decode_runs"], 0)
        self.assertEqual(materialized["decode_ms"], 0)
        self.assertEqual(materialized["pair_prefill_materialized_layer_uses"], 4)
        self.assertEqual(compact32["pair_prefill_capsules"], 16)
        self.assertEqual(compact64["pair_prefill_capsules"], 8)
        self.assertEqual(compact64["pair_prefill_prepared_down_rows"], 512)
        self.assertEqual(compact64["prefill_graph_ms"], 4.0)

    def test_parser_accepts_one_token_throughput_display_floor(self):
        metrics = parse(
            telemetry("compact-64-required", graph_ms=25_000.0),
            "compact-64-required",
        )
        self.assertEqual(metrics["internal_tokens_per_second"], 0.0)
        self.assertGreater(
            metrics["internal_tps_implied_from_reported_ms"],
            0.0,
        )

    def test_parser_fails_closed_on_ledger_fallback_abi_and_duplicate(self):
        cases = (
            telemetry(
                "compact-64-required",
                prefill_overrides={"tensor_payload_bytes": 1},
            ),
            telemetry("compact-64-required", prefill_overrides={"fallbacks": 1}),
            telemetry("compact-64-required").replace(
                "abi=4750485300000001", "abi=4750485300000002"
            ),
            telemetry("compact-64-required", duplicate_prefill=True),
        )
        for value in cases:
            with self.subTest(tail=value[-100:]):
                with self.assertRaises(prefill_ab.HarnessError):
                    parse(value, "compact-64-required")

    def test_commands_differ_only_by_prefill_policy_and_pin_every_other_knob(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cfg = config(root)
            baseline = prefill_ab.build_command(
                cfg, prefill_ab.BASELINE, root / "out.ids"
            )
            candidate = prefill_ab.build_command(cfg, cfg.candidate, root / "out.ids")
            differences = [
                index
                for index, (left, right) in enumerate(zip(baseline, candidate))
                if left != right
            ]
            self.assertEqual(len(differences), 1)
            self.assertEqual(baseline[differences[0] - 1], "--pair-prefill-frame")
            for required in (
                "--require-batch-prefill",
                "--serial-attention",
                "compact-pair-required",
                "fixed-256-required",
                "pair-nibble-required",
                "materialized",
            ):
                self.assertIn(required, baseline)
            self.assertEqual(baseline[baseline.index("--n") + 1], "1")
            self.assertEqual(baseline[baseline.index("--threads") + 1], "4")

    def test_prompt_and_campaign_manifests_bind_provenance_and_seeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ids = list(range(TEST_PROMPT))
            provenance_path, provenance_sha256, ids_sha256 = write_frozen_provenance(
                root, ids
            )
            cfg = config(
                root,
                provenance=provenance_path,
                provenance_sha256=provenance_sha256,
            )
            cfg.binary.write_bytes(b"binary")
            cfg.binary.chmod(0o755)
            cfg.model.write_bytes(b"model")
            cfg = config(
                root,
                provenance=provenance_path,
                provenance_sha256=provenance_sha256,
                binary_sha256=hashlib.sha256(b"binary").hexdigest(),
                model_sha256=hashlib.sha256(b"model").hexdigest(),
                ids_sha256=ids_sha256,
            )
            artifacts = prefill_ab.fingerprint_artifacts(cfg)
            self.assertEqual(
                artifacts["frozen_prompt_provenance"]["sha256"],
                provenance_sha256,
            )
            prompt = prefill_ab.derive_prompt_manifest(cfg, ids, artifacts)
            campaign = prefill_ab.build_campaign_manifest(
                cfg, artifacts, prompt, model_manifest()
            )
            prefill_ab._validate_manifest_hash(
                prompt, prefill_ab.PROMPT_MANIFEST_SCHEMA, "prompt"
            )
            prefill_ab._validate_manifest_hash(
                campaign, prefill_ab.CAMPAIGN_MANIFEST_SCHEMA, "campaign"
            )
            self.assertEqual(prompt["source"]["commit"], TEST_SOURCE_COMMIT)
            self.assertEqual(prompt["source"]["path"], TEST_SOURCE_PATH)
            self.assertEqual(prompt["source"]["blob_sha256"], TEST_SOURCE_SHA256)
            self.assertEqual(prompt["tokenizer"]["id"], TEST_TOKENIZER_ID)
            self.assertEqual(
                prompt["tokenizer"]["artifact_sha256"],
                TEST_TOKENIZER_SHA256,
            )
            self.assertEqual(prompt["frozen_provenance_sha256"], provenance_sha256)
            self.assertEqual(
                prompt["normalized_ids_sha256"],
                prompt["frozen_provenance"]["selected_prefix"]["raw_ids_sha256"],
            )
            self.assertEqual(campaign["schedule_seed"], 8)
            self.assertEqual(campaign["bootstrap_seed"], 11)
            with self.assertRaisesRegex(prefill_ab.HarnessError, "exactly 128"):
                prefill_ab.derive_prompt_manifest(cfg, ids[:-1], artifacts)

            mutated = json.loads(provenance_path.read_text())
            mutated["source"]["commit"] = "b" * 40
            provenance_path.write_text(json.dumps(mutated))
            with self.assertRaisesRegex(prefill_ab.HarnessError, "CLI source"):
                prefill_ab.derive_prompt_manifest(cfg, ids, artifacts)

    def test_paired_block_bootstrap_is_deterministic_and_favors_compact(self):
        samples = []
        for block_index in range(2):
            for variant, values in (
                (prefill_ab.BASELINE, (10.0, 12.0)),
                ("compact-64-required", (5.0, 6.0)),
            ):
                samples.extend(
                    {
                        "variant": variant,
                        "block_index": block_index,
                        "metrics": {"prefill_graph_ms": value},
                    }
                    for value in values
                )
        first = prefill_ab.paired_ratio(
            samples,
            "prefill_graph_ms",
            candidate="compact-64-required",
            resamples=100,
            seed=7,
            confidence=0.95,
        )
        second = prefill_ab.paired_ratio(
            samples,
            "prefill_graph_ms",
            candidate="compact-64-required",
            resamples=100,
            seed=7,
            confidence=0.95,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["estimate"], 2.0)
        self.assertGreater(first["ci_low"], 1.0)
        self.assertEqual(
            first["effective_bootstrap_seed"],
            first["bootstrap_seed"] ^ first["bootstrap_field_seed"],
        )

    def test_resource_gates_cover_p128_p512_p2048_without_decode_ratio(self):
        self.assertNotIn("decode_ms", prefill_ab.RESOURCE_RATIO_FIELDS)
        ratios = {
            field: {"ci_low": 1.0, "ci_high": 1.1, "estimate": 1.05}
            for field in (
                *prefill_ab.CPU_RESOURCE_PROMOTION_FIELDS,
                *prefill_ab.MEMORY_RESOURCE_PROMOTION_FIELDS,
            )
        }
        p128 = prefill_ab._resource_promotion_gate(
            profile="p128", darwin_resources=True, ratios=ratios
        )
        self.assertEqual(p128["status"], "passed")
        for profile in ("p512", "p2048"):
            with self.subTest(profile=profile):
                self.assertEqual(
                    prefill_ab._resource_promotion_gate(
                        profile=profile,
                        darwin_resources=True,
                        ratios=ratios,
                    )["status"],
                    "passed",
                )

        p128_growth_limit = dict(ratios)
        p128_growth_limit["time_peak_memory_footprint_bytes"] = {
            "ci_low": 1.0 / 1.01,
        }
        self.assertEqual(
            prefill_ab._resource_promotion_gate(
                profile="p128",
                darwin_resources=True,
                ratios=p128_growth_limit,
            )["status"],
            "passed",
        )
        p128_growth_limit["time_peak_memory_footprint_bytes"] = {"ci_low": 0.99}
        self.assertEqual(
            prefill_ab._resource_promotion_gate(
                profile="p128",
                darwin_resources=True,
                ratios=p128_growth_limit,
            )["status"],
            "failed",
        )
        self.assertEqual(
            prefill_ab._resource_promotion_gate(
                profile="p2048", darwin_resources=False, ratios={}
            )["status"],
            "failed",
        )

    def test_publication_gate_requires_registered_full_darwin_campaign(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            seeds = prefill_ab.CAMPAIGN_SEEDS["primary"]
            cfg = config(
                root,
                samples_per_variant=prefill_ab.DEFAULT_SAMPLES_PER_VARIANT,
                warmups_per_variant=prefill_ab.DEFAULT_WARMUPS_PER_VARIANT,
                schedule_seed=seeds["schedule"],
                bootstrap_seed=seeds["bootstrap"],
                bootstrap_resamples=prefill_ab.DEFAULT_BOOTSTRAP_RESAMPLES,
                confidence=prefill_ab.PUBLICATION_CONFIDENCE,
                graph_ci_min=prefill_ab.DEFAULT_GRAPH_CI_MIN,
                darwin_resources=True,
                binary_sha256="1" * 64,
                model_sha256="2" * 64,
                ids_sha256="3" * 64,
                provenance_sha256="4" * 64,
                time_sha256="5" * 64,
            )
            self.assertEqual(
                prefill_ab._publication_campaign_gate(cfg, binary_bytes=696_349)[
                    "status"
                ],
                "passed",
            )
            for override in (
                {"darwin_resources": False},
                {"confidence": 0.90},
                {"schedule_seed": seeds["schedule"] + 1},
                {"bootstrap_seed": seeds["bootstrap"] + 1},
                {"bootstrap_resamples": 100},
                {"time_sha256": None},
            ):
                with self.subTest(override=override):
                    self.assertEqual(
                        prefill_ab._publication_campaign_gate(
                            config(
                                root,
                                **{
                                    **cfg.__dict__,
                                    **override,
                                },
                            ),
                            binary_bytes=696_349,
                        )["status"],
                        "failed",
                    )
            self.assertEqual(
                prefill_ab._publication_campaign_gate(cfg, binary_bytes=696_350)[
                    "status"
                ],
                "failed",
            )
            self.assertEqual(
                prefill_ab._production_binary_size_gate({"binary": {"bytes": 696_349}})[
                    "status"
                ],
                "passed",
            )
            self.assertEqual(
                prefill_ab._production_binary_size_gate({"binary": {"bytes": 696_350}})[
                    "status"
                ],
                "failed",
            )

    def test_lightweight_campaign_is_evidence_valid_but_not_publication_promoted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ids = list(range(TEST_PROMPT))
            provenance_path, provenance_sha256, ids_sha256 = write_frozen_provenance(
                root, ids
            )
            cfg = config(
                root,
                provenance=provenance_path,
                provenance_sha256=provenance_sha256,
            )
            artifacts = {
                "binary": {
                    "identity": [1, 2],
                    "sha256": "6" * 64,
                    "bytes": 100_000,
                },
                "pair_model": {"identity": [3, 4], "sha256": "1" * 64},
                "prompt_ids": {"identity": [5, 6], "sha256": ids_sha256},
                "frozen_prompt_provenance": {
                    "identity": [7, 8],
                    "sha256": provenance_sha256,
                },
            }

            def fake_run_variant(
                _config,
                variant,
                _completion_path,
                _prompt_ids,
                _artifact_before,
                _model_manifest,
            ):
                graph = 8.0 if variant == prefill_ab.BASELINE else 4.0
                metrics = parse(telemetry(variant, graph_ms=graph), variant)
                metrics["harness_wall_ms"] = graph + 5.0
                completion_ids = [7]
                digest = prefill_ab.sha256_bytes(
                    prefill_ab.canonical_ids_bytes(completion_ids)
                )
                return {
                    "variant": variant,
                    "argv": [],
                    "metrics": metrics,
                    "completion_ids": completion_ids,
                    "completion_ids_sha256": digest,
                    "completion_file_sha256": digest,
                    "telemetry_sha256": "7" * 64,
                    "telemetry_output": "fixture",
                    "output_capture": {"raw_sha256": "7" * 64},
                    "exit_status": 0,
                }

            with (
                mock.patch.object(
                    prefill_ab, "fingerprint_artifacts", return_value=artifacts
                ),
                mock.patch.object(
                    prefill_ab, "verify_artifacts", return_value=artifacts
                ),
                mock.patch.object(prefill_ab._attention, "assert_artifact_identities"),
                mock.patch.object(
                    prefill_ab,
                    "derive_pair_prefill_model_manifest",
                    return_value=model_manifest(),
                ),
                mock.patch.object(
                    prefill_ab, "run_variant", side_effect=fake_run_variant
                ),
            ):
                result = prefill_ab.run_benchmark(cfg)

        self.assertEqual(result["status"], "evidence-valid")
        self.assertEqual(result["promotion_status"], "incomplete")
        self.assertEqual(result["strict_cell_status"], "failed")
        self.assertEqual(result["auto_cell_status"], "failed")
        self.assertEqual(result["auto_matrix_status"], "incomplete")
        self.assertEqual(
            result["promotion_gates"]["logical_payload_reduction"]["status"],
            "passed",
        )
        self.assertEqual(
            result["promotion_gates"]["prefill_graph_time"]["status"],
            "passed",
        )
        self.assertEqual(
            result["promotion_gates"]["publication_campaign_shape"]["status"],
            "failed",
        )
        self.assertEqual(
            result["promotion_gates"]["physical_resource_efficiency"]["status"],
            "failed",
        )
        self.assertEqual(len(result["samples"]), 8)
        self.assertEqual(len(result["warmups"]), 2)
        self.assertEqual(result["completion_equivalence"]["token_ids"], [7])

    def test_reserved_prefix_guard_knows_new_receipts(self):
        prefixes = prefill_ab._resource_support()._TELEMETRY_PREFIXES
        self.assertIn(b"prefill_phase:", prefixes)
        self.assertIn(b"pair_prefill_frame:", prefixes)
        with self.assertRaises(prefill_ab.HarnessError):
            prefill_ab._resource_support()._validate_raw_telemetry_envelope(
                b"pair_prefill_frame\xe2\x80\x8b: hidden\n"
            )

    def test_config_rejects_non_four_threads_and_unpinned_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(prefill_ab.HarnessError, "four threads"):
                prefill_ab.validate_config(config(root, threads=2))
            with self.assertRaisesRegex(prefill_ab.HarnessError, "provenance"):
                prefill_ab.validate_config(config(root, source_sha256=""))
            with self.assertRaisesRegex(prefill_ab.HarnessError, "must be pinned"):
                prefill_ab.validate_config(config(root, provenance_sha256=None))


if __name__ == "__main__":
    unittest.main()
