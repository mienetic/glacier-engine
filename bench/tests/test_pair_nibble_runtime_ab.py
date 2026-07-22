from __future__ import annotations

import hashlib
import importlib.util
import json
import struct
import sys
import tempfile
import textwrap
import unittest
import zlib
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "pair_nibble_runtime_ab.py"
SPEC = importlib.util.spec_from_file_location("pair_nibble_runtime_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
pair_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pair_ab
SPEC.loader.exec_module(pair_ab)


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


def align64(value: int) -> int:
    return (value + 63) & ~63


def raw_record(layer: int, payload: bytes) -> dict[str, object]:
    return {
        "layer": layer,
        "kind": 8,
        "encoding": 0,
        "packed_layout": 0xFFFF,
        "pair_layout": 0xFFFF,
        "role": 0,
        "group_size": 0,
        "out_f": 1,
        "in_f": len(payload) // 4,
        "streams": (b"", b"", b"", b"", payload),
    }


def int4_record(
    layer: int,
    kind: int,
    packed: bytes,
    scales: bytes,
) -> dict[str, object]:
    return {
        "layer": layer,
        "kind": kind,
        "encoding": 1,
        "packed_layout": 1,
        "pair_layout": 0xFFFF,
        "role": 0,
        "group_size": 8,
        "out_f": 4,
        "in_f": 16,
        "streams": (packed, b"", b"", scales, b""),
    }


def pair_record(
    layer: int,
    packed: bytes,
    scales: bytes,
) -> dict[str, object]:
    return {
        "layer": layer,
        "kind": 255,
        "encoding": 2,
        "packed_layout": 0xFFFF,
        "pair_layout": 0,
        "role": 1,
        "group_size": 8,
        "out_f": 4,
        "in_f": 16,
        "streams": (packed, b"", b"", scales, b""),
    }


def write_glrt(
    path: Path,
    records: list[dict[str, object]],
    *,
    source_fingerprint: bytes,
    layers: int = 4,
    dim: int = 16,
    hidden_dim: int = 4,
) -> None:
    record_count = len(records)
    data_offset = align64(512 + record_count * 160)
    cursor = data_offset
    planned: list[tuple[bytearray, tuple[bytes, ...], list[tuple[int, int]]]] = []
    for item in records:
        streams = tuple(item["streams"])
        ranges: list[tuple[int, int]] = []
        for payload in streams:
            if payload:
                cursor = align64(cursor)
                ranges.append((cursor, len(payload)))
                cursor += len(payload)
            else:
                ranges.append((0, 0))
        descriptor = bytearray(160)
        struct.pack_into("<II", descriptor, 0, int(item["layer"]), int(item["kind"]))
        struct.pack_into(
            "<HH",
            descriptor,
            8,
            int(item["encoding"]),
            int(item["packed_layout"]),
        )
        out_f = int(item["out_f"])
        in_f = int(item["in_f"])
        payload_crc = 0
        for payload in streams:
            payload_crc = zlib.crc32(payload, payload_crc)
        struct.pack_into(
            "<IIIIIQ",
            descriptor,
            12,
            int(item["group_size"]),
            out_f,
            in_f,
            0,
            payload_crc & 0xFFFFFFFF,
            out_f * in_f,
        )
        for offset, pair in zip((40, 56, 72, 88, 104), ranges):
            struct.pack_into("<QQ", descriptor, offset, *pair)
        struct.pack_into(
            "<HH", descriptor, 120, int(item["role"]), int(item["pair_layout"])
        )
        digest = hashlib.sha256(descriptor[:128])
        for payload in streams:
            digest.update(payload)
        descriptor[128:160] = digest.digest()
        planned.append((descriptor, streams, ranges))

    file_size = align64(cursor)
    image = bytearray(file_size)
    for index, (descriptor, streams, ranges) in enumerate(planned):
        start = 512 + index * 160
        image[start : start + 160] = descriptor
        for payload, (offset, length) in zip(streams, ranges):
            if length:
                image[offset : offset + length] = payload
    index = bytes(image[512 : 512 + record_count * 160])
    header = bytearray(512)
    header[0:4] = b"GLRT"
    struct.pack_into("<HHHHI", header, 4, 2, 512, 160, 64, 0)
    struct.pack_into("<QQQQ", header, 16, record_count, 512, data_offset, file_size)
    header[48:80] = source_fingerprint
    header[80:112] = bytes.fromhex(
        "d0d7df06350af6b2d48e282f65ff873a3cf95bd6397b1d2d26cc6e679304e06f"
    )
    struct.pack_into("<7I", header, 112, dim, hidden_dim, layers, 32, 1, 16, 1)
    header[140] = 1
    struct.pack_into("<ff", header, 144, 1e-5, 10_000.0)
    struct.pack_into("<I", header, 152, zlib.crc32(index) & 0xFFFFFFFF)
    struct.pack_into("<I", header, 156, zlib.crc32(header) & 0xFFFFFFFF)
    image[:512] = header
    path.write_bytes(image)


def build_glrt_pair(
    root: Path,
    *,
    pair_source_fingerprint: bytes | None = None,
    pair_layers: int = 4,
    pair_common_delta: int = 0,
    corrupt_pair_rewrite: bool = False,
) -> tuple[Path, Path]:
    source_fingerprint = hashlib.sha256(b"same source fixture").digest()
    separate_records: list[dict[str, object]] = []
    pair_records: list[dict[str, object]] = []
    for layer in range(4):
        common = bytearray(64)
        for index in range(64):
            common[index] = (layer * 17 + index) & 0xFF
        separate_records.append(raw_record(layer, bytes(common)))
        candidate_common = bytearray(common)
        if layer == 0 and pair_common_delta:
            candidate_common[0] ^= pair_common_delta
        pair_records.append(raw_record(layer, bytes(candidate_common)))

        gate = bytes((layer * 29 + index * 3) & 0xFF for index in range(32))
        up = bytes((layer * 31 + index * 5 + 7) & 0xFF for index in range(32))
        gate_scales = bytes((layer * 11 + index) & 0xFF for index in range(16))
        up_scales = bytes((layer * 13 + index + 80) & 0xFF for index in range(16))
        separate_records.extend(
            (
                int4_record(layer, 7, gate, gate_scales),
                int4_record(layer, 5, up, up_scales),
            )
        )
        paired = bytearray()
        for gate_byte, up_byte in zip(gate, up):
            paired.append((gate_byte & 0x0F) | ((up_byte & 0x0F) << 4))
            paired.append((gate_byte >> 4) | (up_byte & 0xF0))
        if layer == 0 and corrupt_pair_rewrite:
            paired[0] ^= 1
        paired_scales = b"".join(
            gate_scales[offset : offset + 8] + up_scales[offset : offset + 8]
            for offset in range(0, len(gate_scales), 8)
        )
        pair_records.append(pair_record(layer, bytes(paired), paired_scales))

    separate = root / "separate.glrt"
    pair = root / "pair.glrt"
    write_glrt(
        separate,
        separate_records,
        source_fingerprint=source_fingerprint,
        layers=4,
    )
    write_glrt(
        pair,
        pair_records,
        source_fingerprint=pair_source_fingerprint or source_fingerprint,
        layers=pair_layers,
    )
    return separate, pair


def telemetry(
    *,
    variant: str,
    prompt_tokens: int = 9,
    new_tokens: int = 4,
    layers: int = 4,
    prefill: str = "batch",
    overrides: dict[str, int] | None = None,
    pair_extra: str = "",
) -> str:
    counters = {
        "admissions": 0,
        "artifact_layers": 0,
        "selected_layers": 0,
        "pair_weight_bytes": 0,
        "pair_scale_bytes": 0,
        "separate_gate_bytes": 192,
        "separate_up_bytes": 192,
        "prefill_m1": 0,
        "prefill_m4_groups": 0,
        "prefill_tail_dispatches": 0,
        "prefill_tail_rows": 0,
        "decode_m1": 0,
        "outputless_m1": 0,
        "activation_rows_quantized": 0,
        "selected_layer_rows": 0,
        "checked_dispatches": 0,
        "sealed_dispatches": 0,
        "fallbacks": 0,
        "rejects": 0,
    }
    if variant == "pair-nibble-required":
        counters.update(
            {
                "admissions": 1,
                "artifact_layers": layers,
                "selected_layers": layers,
                "pair_weight_bytes": 256,
                "pair_scale_bytes": 128,
                "separate_gate_bytes": 0,
                "separate_up_bytes": 0,
                **pair_ab._expected_pair_coverage(
                    prompt_tokens=prompt_tokens,
                    new_tokens=new_tokens,
                    layers=layers,
                    prefill=prefill,
                ),
            }
        )
    if overrides:
        counters.update(overrides)
    policy = variant
    artifact = "pair-nibble" if variant == "pair-nibble-required" else "separate"
    selected = "pair-nibble" if variant == "pair-nibble-required" else "separate"
    pair_fields = " ".join(f"{name}={value}" for name, value in counters.items())
    decode_runs = new_tokens - 1
    return (
        "load: mode=prepared artifact=glrt ms=2.0\n"
        f"schedule: attention=serial layers={layers}\n"
        "ready: phase=request_ready ms=3.0\n"
        "phases: prefill_ms=4.000 decode_ms=5.000 sampling_ms=0.100 "
        f"decode_runs={decode_runs} attention_graphs=0 attention_dispatches=0 "
        "handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 "
        "fused_gqa_dispatches=0 paired_mlp_graphs=0 paired_mlp_dispatches=0\n"
        f"pair_nibble: policy={policy} artifact={artifact} selected={selected} "
        f"{pair_fields} storage_abi=47504e4200000001 "
        f"executor_abi=47504e4500000005{pair_extra}\n"
        "decode_plan: mode=checked sets=0 set_bytes=0 layer_builds=0 "
        "layer_binds=0 checked_dispatches=0 sealed_dispatches=0 "
        "fallbacks=0 rejects=0 build_ms=0.000 abi=4753445000000004\n"
        f"greedy_output: mode=materialized materialized_projections={new_tokens} "
        "logitless_projections=0 producer_rows=0 tile_output_bytes=0 "
        "argmax_scan_rows=0 scratch_bytes=0 materialized_logits_bytes=128 "
        "steady_state_reclaimed_bytes=0 fallbacks=0 rejects=0 "
        "abi=474c4d4800000002\n"
        f"time: 9.10 ms ({new_tokens * 1000.0 / 9.1:.1f} tok/s, "
        f"prefilled {prompt_tokens}, prefill={prefill})\n"
    )


def write_fake_glacier(
    root: Path,
    *,
    divergent_output: bool = False,
    mutate_pair_model: bool = False,
) -> Path:
    binary = root / "fake-glacier"
    source = f"""
        #!/usr/bin/env python3
        import pathlib,sys
        divergent={divergent_output!r}
        mutate_pair={mutate_pair_model!r}
        a=sys.argv
        model=pathlib.Path(a[2])
        out=pathlib.Path(a[a.index('--out-ids-file')+1])
        prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())
        tokens=int(a[a.index('--n')+1]); runs=tokens-1; layers=4
        variant=a[a.index('--mlp-layout')+1]
        pair=variant=='pair-nibble-required'
        prefill='serial' if '--serial-prefill' in a else 'batch'
        start=8 if divergent and pair else 7
        out.write_text(' '.join(str(start+i) for i in range(tokens))+'\\n')
        if prefill=='serial':
            pm1=prompt*layers; m4=0; tails=0; tail_rows=0; prefill_checked=pm1
        else:
            remaining=prompt; groups=0; tail_count=0; tail_sum=0; checked=0
            while remaining:
                rows=min(256,remaining); groups+=rows//4
                tail_count+=int(rows%4!=0); tail_sum+=rows%4
                checked+=(rows+3)//4; remaining-=rows
            pm1=0; m4=groups*layers; tails=tail_count*layers
            tail_rows=tail_sum*layers; prefill_checked=checked*layers
        decode=runs*layers; active=(prompt+runs)*layers
        if pair:
            admissions=1; artifact='pair-nibble'; selected='pair-nibble'
            artifact_layers=layers; selected_layers=layers
            pair_weights=256; pair_scales=128; gate=0; up=0
            activation=active; selected_rows=active
            checked=prefill_checked+decode
        else:
            admissions=0; artifact='separate'; selected='separate'
            artifact_layers=0; selected_layers=0
            pair_weights=0; pair_scales=0; gate=192; up=192
            pm1=0; m4=0; tails=0; tail_rows=0; decode=0
            activation=0; selected_rows=0; checked=0
        print('load: mode=prepared artifact=glrt ms=1.0')
        print(f'schedule: attention=serial layers={{layers}}')
        print('ready: phase=request_ready ms=2.0')
        prefill_ms=4.0 if pair else 8.0
        decode_ms=5.0 if pair else 10.0
        internal_ms=10.0 if pair else 20.0
        print(f'phases: prefill_ms={{prefill_ms:.3f}} decode_ms={{decode_ms:.3f}} sampling_ms=0.100 decode_runs={{runs}} attention_graphs=0 attention_dispatches=0 handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 fused_gqa_dispatches=0 paired_mlp_graphs=0 paired_mlp_dispatches=0')
        print(f'pair_nibble: policy={{variant}} artifact={{artifact}} selected={{selected}} admissions={{admissions}} artifact_layers={{artifact_layers}} selected_layers={{selected_layers}} pair_weight_bytes={{pair_weights}} pair_scale_bytes={{pair_scales}} separate_gate_bytes={{gate}} separate_up_bytes={{up}} prefill_m1={{pm1}} prefill_m4_groups={{m4}} prefill_tail_dispatches={{tails}} prefill_tail_rows={{tail_rows}} decode_m1={{decode}} outputless_m1={{pm1 + decode}} activation_rows_quantized={{activation}} selected_layer_rows={{selected_rows}} checked_dispatches={{checked}} sealed_dispatches=0 fallbacks=0 rejects=0 storage_abi=47504e4200000001 executor_abi=47504e4500000005')
        print('decode_plan: mode=checked sets=0 set_bytes=0 layer_builds=0 layer_binds=0 checked_dispatches=0 sealed_dispatches=0 fallbacks=0 rejects=0 build_ms=0.000 abi=4753445000000004')
        print(f'greedy_output: mode=materialized materialized_projections={{tokens}} logitless_projections=0 producer_rows=0 tile_output_bytes=0 argmax_scan_rows=0 scratch_bytes=0 materialized_logits_bytes=128 steady_state_reclaimed_bytes=0 fallbacks=0 rejects=0 abi=474c4d4800000002')
        print(f'time: {{internal_ms:.2f}} ms ({{tokens * 1000.0 / internal_ms:.1f}} tok/s, prefilled {{prompt}}, prefill={{prefill}})')
        if mutate_pair and pair:
            model.write_bytes(model.read_bytes()+b'x')
    """
    binary.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    binary.chmod(0o755)
    return binary


def make_config(
    root: Path,
    binary: Path,
    *,
    prefill: str = "batch",
) -> pair_ab.Config:
    separate, pair = build_glrt_pair(root)
    ids = root / "prompt.ids"
    ids.write_text("1 2 3 4 5 6 7 8 9\n", encoding="ascii")
    return pair_ab.Config(
        binary=binary,
        separate_model=separate,
        pair_model=pair,
        ids=ids,
        output=None,
        cwd=root,
        prefill=prefill,
        samples_per_variant=4,
        warmups_per_variant=1,
        new_tokens=2,
        threads=2,
        schedule_seed=8,
        bootstrap_seed=11,
        bootstrap_resamples=100,
    )


class PairNibbleRuntimeAbTests(unittest.TestCase):
    def test_defaults_cli_aliases_and_balanced_schedule(self):
        args = pair_ab.argument_parser().parse_args(
            [
                "--binary",
                "glacier",
                "--baseline-model",
                "separate.glrt",
                "--candidate-model",
                "pair.glrt",
                "--output",
                "-",
            ]
        )
        self.assertEqual(args.samples_per_variant, 32)
        self.assertEqual(args.warmups_per_variant, 2)
        self.assertEqual(args.new_tokens, 64)
        self.assertEqual(args.threads, 4)
        self.assertEqual(args.prefill, "batch")
        self.assertEqual(args.bootstrap_resamples, 100_000)
        self.assertFalse(args.darwin_resources)
        self.assertEqual(args.time_binary, Path("/usr/bin/time"))
        patterns = pair_ab.build_patterns(32, 1234)
        self.assertEqual(patterns.count("ABBA"), 8)
        self.assertEqual(patterns.count("BAAB"), 8)
        self.assertEqual(patterns, pair_ab.build_patterns(32, 1234))

    def test_strict_parser_accepts_exact_batch_and_serial_coverage(self):
        baseline = pair_ab.parse_telemetry(
            telemetry(variant="separate"),
            variant="separate",
            prompt_tokens=9,
            new_tokens=4,
            prefill="batch",
        )
        self.assertEqual(baseline["pair_nibble_admissions"], 0)
        self.assertEqual(baseline["pair_nibble_pair_weight_bytes"], 0)
        self.assertEqual(baseline["pair_nibble_separate_gate_bytes"], 192)

        batch = pair_ab.parse_telemetry(
            telemetry(variant="pair-nibble-required"),
            variant="pair-nibble-required",
            prompt_tokens=9,
            new_tokens=4,
            prefill="batch",
        )
        self.assertEqual(batch["pair_nibble_prefill_m4_groups"], 8)
        self.assertEqual(batch["pair_nibble_prefill_tail_dispatches"], 4)
        self.assertEqual(batch["pair_nibble_prefill_tail_rows"], 4)
        self.assertEqual(batch["pair_nibble_decode_m1"], 12)
        self.assertEqual(batch["pair_nibble_outputless_m1"], 12)
        self.assertEqual(batch["pair_nibble_checked_dispatches"], 24)

        serial = pair_ab.parse_telemetry(
            telemetry(variant="pair-nibble-required", prefill="serial"),
            variant="pair-nibble-required",
            prompt_tokens=9,
            new_tokens=4,
            prefill="serial",
        )
        self.assertEqual(serial["pair_nibble_prefill_m1"], 36)
        self.assertEqual(serial["pair_nibble_prefill_m4_groups"], 0)
        self.assertEqual(serial["pair_nibble_decode_m1"], 12)
        self.assertEqual(serial["pair_nibble_outputless_m1"], 48)
        self.assertEqual(serial["pair_nibble_checked_dispatches"], 48)

    def test_chunked_batch_coverage_is_exact_at_257_rows(self):
        expected = pair_ab._expected_pair_coverage(
            prompt_tokens=257,
            new_tokens=2,
            layers=3,
            prefill="batch",
        )
        self.assertEqual(expected["prefill_m4_groups"], 64 * 3)
        self.assertEqual(expected["prefill_tail_dispatches"], 3)
        self.assertEqual(expected["prefill_tail_rows"], 3)
        self.assertEqual(expected["outputless_m1"], 3)
        self.assertEqual(expected["checked_dispatches"], (65 + 1) * 3)

    def test_duplicate_malformed_or_drifted_pair_line_fails_closed(self):
        valid = telemetry(variant="pair-nibble-required")
        pair_line = next(
            line for line in valid.splitlines() if line.startswith("pair_nibble:")
        )
        for broken in (
            valid + pair_line + "\n",
            valid.replace(" executor_abi=47504e4500000005", " executor_abi=0x1"),
            telemetry(variant="pair-nibble-required", pair_extra=" extra=1"),
        ):
            with self.subTest(broken=broken[-80:]):
                with self.assertRaisesRegex(
                    pair_ab.HarnessError, "malformed|duplicated"
                ):
                    pair_ab.parse_telemetry(
                        broken,
                        variant="pair-nibble-required",
                        prompt_tokens=9,
                        new_tokens=4,
                        prefill="batch",
                    )

    def test_wrong_baseline_or_candidate_counters_fail_closed(self):
        cases = (
            ("separate", {"admissions": 1}, "baseline"),
            ("pair-nibble-required", {"artifact_layers": 3}, "coverage"),
            ("pair-nibble-required", {"separate_gate_bytes": 1}, "forbidden"),
            ("pair-nibble-required", {"prefill_m4_groups": 7}, "coverage"),
            ("pair-nibble-required", {"outputless_m1": 11}, "coverage"),
            ("pair-nibble-required", {"sealed_dispatches": 1}, "coverage"),
            ("pair-nibble-required", {"fallbacks": 1}, "fallback"),
            ("pair-nibble-required", {"rejects": 1}, "fallback"),
        )
        for variant, overrides, message in cases:
            with self.subTest(variant=variant, overrides=overrides):
                with self.assertRaisesRegex(pair_ab.HarnessError, message):
                    pair_ab.parse_telemetry(
                        telemetry(variant=variant, overrides=overrides),
                        variant=variant,
                        prompt_tokens=9,
                        new_tokens=4,
                        prefill="batch",
                    )

    def test_phase_and_throughput_relations_fail_closed_in_base_mode(self):
        valid = telemetry(variant="separate")
        invalid = {
            "phase sum": valid.replace("time: 9.10 ms", "time: 8.00 ms"),
            "tok/s": valid.replace("439.6 tok/s", "1.0 tok/s"),
            "precision": valid.replace("prefill_ms=4.000", "prefill_ms=4.00"),
        }
        for name, output in invalid.items():
            with self.subTest(name=name):
                with self.assertRaises(pair_ab.HarnessError):
                    pair_ab.parse_telemetry(
                        output,
                        variant="separate",
                        prompt_tokens=9,
                        new_tokens=4,
                        prefill="batch",
                    )

    def test_materialized_greedy_output_is_verified(self):
        valid = telemetry(variant="pair-nibble-required")
        invalid = (
            valid.replace("mode=materialized", "mode=logitless-required"),
            valid.replace("materialized_projections=4", "materialized_projections=3"),
            valid.replace(
                "fallbacks=0 rejects=0 abi=474c4d4800000002",
                "fallbacks=1 rejects=0 abi=474c4d4800000002",
            ),
        )
        for output in invalid:
            with self.subTest(output=output[-180:]):
                with self.assertRaises(pair_ab.HarnessError):
                    pair_ab.parse_telemetry(
                        output,
                        variant="pair-nibble-required",
                        prompt_tokens=9,
                        new_tokens=4,
                        prefill="batch",
                    )

    def test_glrt_pair_equivalence_proves_exact_rewrite_and_manifests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            separate, pair = build_glrt_pair(root)
            proof = pair_ab.prove_glrt_pair_equivalence(
                separate,
                pair,
                separate_file_sha256=hashlib.sha256(separate.read_bytes()).hexdigest(),
                pair_file_sha256=hashlib.sha256(pair.read_bytes()).hexdigest(),
            )
            self.assertEqual(proof["schema"], pair_ab.GLRT_PROOF_SCHEMA)
            self.assertEqual(proof["status"], "exact-lossless-rewrite-verified")
            self.assertEqual(len(proof["layers"]), 4)
            self.assertTrue(proof["claims"]["all_non_rewrite_records_identical"])
            self.assertTrue(proof["claims"]["exact_gate_up_nibble_rewrite"])
            self.assertEqual(
                proof["byte_ledger"]["separate_gate_bytes"],
                proof["byte_ledger"]["separate_up_bytes"],
            )
            self.assertRegex(proof["proof_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(proof["separate_manifest_sha256"], r"^[0-9a-f]{64}$")

    def test_glrt_pair_equivalence_rejects_valid_but_different_artifacts(self):
        cases = (
            (
                {"pair_source_fingerprint": hashlib.sha256(b"other").digest()},
                "source fingerprints",
            ),
            ({"pair_layers": 5}, "config snapshots"),
            ({"pair_common_delta": 1}, "non-rewrite record differs"),
            ({"corrupt_pair_rewrite": True}, "not an exact lossless rewrite"),
        )
        for options, message in cases:
            with self.subTest(options=options):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    separate, pair = build_glrt_pair(root, **options)
                    with self.assertRaisesRegex(pair_ab.HarnessError, message):
                        pair_ab.prove_glrt_pair_equivalence(
                            separate,
                            pair,
                            separate_file_sha256=hashlib.sha256(
                                separate.read_bytes()
                            ).hexdigest(),
                            pair_file_sha256=hashlib.sha256(
                                pair.read_bytes()
                            ).hexdigest(),
                        )

    def test_glrt_parser_rejects_fake_or_corrupted_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / "fake.glrt"
            fake.write_bytes(b"separate glrt")
            with self.assertRaisesRegex(pair_ab.HarnessError, "truncated"):
                pair_ab.parse_glrt_image(fake, "fake GLRT")

            separate, _ = build_glrt_pair(root)
            damaged = bytearray(separate.read_bytes())
            damaged[-64] ^= 1
            separate.write_bytes(damaged)
            with self.assertRaisesRegex(pair_ab.HarnessError, "CRC|digest"):
                pair_ab.parse_glrt_image(separate, "damaged GLRT")

    def test_raw_stdout_hash_and_pair_prefix_taint_are_fail_closed(self):
        accepted = pair_ab._run_process(
            [
                sys.executable,
                "-c",
                "import os; os.write(1, b'model payload \\xff\\n')",
            ],
            Path.cwd(),
            10.0,
        )
        self.assertEqual(
            accepted["output_capture"]["raw_sha256"],
            hashlib.sha256(b"model payload \xff\n").hexdigest(),
        )
        self.assertEqual(accepted["output_capture"]["non_ascii_byte_count"], 1)
        tainted = (
            b"pair_nibble: policy=separate\xff\n",
            b"pair_\xffnibble: policy=separate\n",
            b"pair_nibble: policy=separate\r\n",
        )
        for payload in tainted:
            source = f"import os; os.write(1, {payload!r})"
            with self.subTest(payload=payload):
                with self.assertRaises(pair_ab.HarnessError):
                    pair_ab._run_process(
                        [sys.executable, "-c", source],
                        Path.cwd(),
                        10.0,
                    )

    def test_commands_differ_only_by_model_and_strict_mlp_policy(self):
        config = pair_ab.Config(
            binary=Path("/tmp/glacier"),
            separate_model=Path("/tmp/separate.glrt"),
            pair_model=Path("/tmp/pair.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        completion = Path("/tmp/out.ids")
        baseline = pair_ab.build_command(config, "separate", completion)
        candidate = pair_ab.build_command(config, "pair-nibble-required", completion)
        self.assertEqual(baseline[0], candidate[0])
        self.assertIn("--require-batch-prefill", baseline)
        self.assertIn("--serial-attention", baseline)
        self.assertEqual(baseline[baseline.index("--decode-plan") + 1], "checked")
        self.assertEqual(
            baseline[baseline.index("--greedy-output") + 1], "materialized"
        )
        normalized = list(candidate)
        normalized[2] = str(config.separate_model)
        normalized[normalized.index("--mlp-layout") + 1] = "separate"
        self.assertEqual(baseline, normalized)

        serial_config = pair_ab.Config(**{**config.__dict__, "prefill": "serial"})
        serial = pair_ab.build_command(serial_config, "separate", completion)
        self.assertIn("--serial-prefill", serial)
        self.assertNotIn("--require-batch-prefill", serial)

    def test_paired_bootstrap_is_deterministic_and_favors_pair(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                variant = "pair-nibble-required" if letter == "A" else "separate"
                samples.append(
                    {
                        "block_index": block_index,
                        "variant": variant,
                        "metrics": {
                            "decode_ms": (
                                5.0 if variant == "pair-nibble-required" else 10.0
                            )
                        },
                    }
                )
        first = pair_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = pair_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["estimate"], 2.0)
        self.assertEqual(first["ci_low"], 2.0)
        self.assertTrue(first["direction"].startswith("separate_over_pair"))

    def test_lightweight_end_to_end_manifest_and_exact_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            result = pair_ab.run_benchmark(config)
            self.assertEqual(result["schema"], pair_ab.SCHEMA)
            self.assertEqual(result["status"], "evidence-valid")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmups"]), 2)
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["separate_over_pair_nibble"]["prefill_ms"]["estimate"],
                2.0,
            )
            self.assertEqual(
                result["separate_over_pair_nibble"]["decode_ms"]["estimate"],
                2.0,
            )
            contract = result["contract"]
            self.assertEqual(contract["letter_mapping"]["A"], "pair-nibble-required")
            self.assertEqual(contract["letter_mapping"]["B"], "separate")
            self.assertEqual(contract["bootstrap_resamples"], 100)
            self.assertEqual(
                contract["mlp_producer_bytes_per_variant"]["separate"],
                contract["mlp_producer_bytes_per_variant"]["pair-nibble-required"],
            )
            self.assertEqual(len(set(contract["binary_sha256_by_variant"].values())), 1)
            self.assertEqual(len(set(contract["model_sha256_by_variant"].values())), 2)
            proof = result["glrt_pair_equivalence"]
            self.assertEqual(proof["status"], "exact-lossless-rewrite-verified")
            self.assertEqual(proof["byte_ledger"]["pair_weight_bytes"], 256)
            self.assertEqual(proof["byte_ledger"]["pair_scale_bytes"], 128)
            self.assertEqual(
                result["process_output_capture_contract"]["raw_reserved_prefix_guard"][
                    "additional_prefixes"
                ],
                ["pair_nibble:", "pair_scratch:"],
            )
            for name in result["artifacts_before"]:
                self.assertEqual(
                    result["artifacts_before"][name]["sha256"],
                    result["artifacts_after"][name]["sha256"],
                )
            json.dumps(result, allow_nan=False)

    def test_exact_completion_divergence_fails_before_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root, divergent_output=True))
            with self.assertRaisesRegex(pair_ab.HarnessError, "exact completion"):
                pair_ab.run_benchmark(config)

    def test_artifact_mutation_during_run_fails_before_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root, mutate_pair_model=True))
            with self.assertRaisesRegex(pair_ab.HarnessError, "identity changed"):
                pair_ab.run_benchmark(config)

    def test_config_rejects_batch_with_one_thread_and_aliasing(self):
        config = pair_ab.Config(
            binary=Path("/tmp/glacier"),
            separate_model=Path("/tmp/same.glrt"),
            pair_model=Path("/tmp/same.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
            threads=1,
        )
        with self.assertRaisesRegex(pair_ab.HarnessError, "at least two"):
            pair_ab.validate_config(config)
        serial = pair_ab.Config(**{**config.__dict__, "prefill": "serial"})
        with self.assertRaisesRegex(pair_ab.HarnessError, "distinct"):
            pair_ab.validate_config(serial)

    def test_config_rejects_uncertified_pair_participant_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            unsupported = pair_ab.Config(**{**config.__dict__, "threads": 9})
            with self.assertRaisesRegex(pair_ab.HarnessError, r"\[1, 8\]"):
                pair_ab.validate_config(unsupported)

    def test_resource_parser_is_strict_and_reused(self):
        parsed = pair_ab.parse_resource_output(TIME_RECORD)
        self.assertEqual(parsed["time_cpu_seconds"], 3.75)
        self.assertEqual(parsed["time_maximum_resident_set_size_bytes"], 426_328_064)
        self.assertEqual(parsed["time_peak_memory_footprint_bytes"], 25_675_488)
        for broken in (
            TIME_RECORD.replace("9876543210  instructions retired\n", ""),
            "real 9.00\n" + TIME_RECORD,
            TIME_RECORD.replace("cycles elapsed", "mystery cycles"),
            TIME_RECORD.replace("real 1.25", "real 1.250"),
        ):
            with self.subTest(broken=broken[-80:]):
                with self.assertRaises(pair_ab.HarnessError):
                    pair_ab.parse_resource_output(broken)

    def test_resource_config_requires_darwin_system_time(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            enabled = pair_ab.Config(**{**config.__dict__, "darwin_resources": True})
            with mock.patch.object(pair_ab.platform, "system", return_value="Linux"):
                with self.assertRaisesRegex(pair_ab.HarnessError, "Darwin"):
                    pair_ab.validate_config(enabled)

            custom_time = root / "custom-time"
            custom_time.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            custom_time.chmod(0o755)
            custom = pair_ab.Config(
                **{
                    **enabled.__dict__,
                    "time_binary": custom_time,
                }
            )
            with mock.patch.object(pair_ab.platform, "system", return_value="Darwin"):
                with self.assertRaisesRegex(pair_ab.HarnessError, "/usr/bin/time"):
                    pair_ab.validate_config(custom)

    def test_resource_observation_wraps_every_process_and_records_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            enabled = pair_ab.Config(**{**config.__dict__, "darwin_resources": True})
            output = telemetry(variant="separate", prompt_tokens=9, new_tokens=2)
            record = (
                TIME_RECORD.replace("real 1.25", "real 0.01")
                .replace("user 3.50", "user 0.01")
                .replace("sys 0.25", "sys 0.01")
            )

            def fake_run(argv, cwd, timeout_seconds, *, environment=None):
                self.assertEqual(argv[:3], ["/usr/bin/time", "-lp", "-o"])
                self.assertEqual(environment["LC_ALL"], "C")
                Path(argv[3]).write_text(record, encoding="ascii")
                glacier_argv = list(argv[4:])
                completion = Path(
                    glacier_argv[glacier_argv.index("--out-ids-file") + 1]
                )
                completion.write_text("7 8\n", encoding="ascii")
                capture = pair_ab._load_resource_support()._capture_process_output(
                    output.encode("ascii"),
                    extra_reserved_prefixes=(b"pair_nibble:",),
                )
                return {**capture, "wall_ms": 20.0, "exit_status": 0}

            artifacts = pair_ab.fingerprint_artifacts(enabled)
            completion_path = root / "completion.ids"
            with mock.patch.object(pair_ab, "_run_process", side_effect=fake_run):
                item = pair_ab.run_variant(
                    enabled,
                    "separate",
                    completion_path,
                    list(range(9)),
                    artifacts,
                )
            self.assertEqual(item["timed_argv"][:3], ["/usr/bin/time", "-lp", "-o"])
            self.assertEqual(
                item["metrics"]["time_maximum_resident_set_size_bytes"],
                426_328_064,
            )
            self.assertEqual(item["metrics"]["time_cpu_seconds"], 0.02)
            self.assertEqual(
                item["time_output_sha256"],
                pair_ab.sha256_bytes(record.encode("ascii")),
            )

    def test_resource_ratio_contract_includes_wall_and_real_time(self):
        self.assertIn("harness_wall_seconds", pair_ab.RESOURCE_RATIO_FIELDS)
        self.assertIn("time_real_seconds", pair_ab.RESOURCE_RATIO_FIELDS)

    def test_resource_campaign_reports_paired_wall_and_real_time_intervals(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            enabled = pair_ab.Config(**{**config.__dict__, "darwin_resources": True})

            def fake_variant(
                active_config,
                variant,
                completion_path,
                prompt_ids,
                artifact_before,
            ):
                metrics = pair_ab.parse_telemetry(
                    telemetry(
                        variant=variant,
                        prompt_tokens=len(prompt_ids),
                        new_tokens=active_config.new_tokens,
                        prefill=active_config.prefill,
                    ),
                    variant=variant,
                    prompt_tokens=len(prompt_ids),
                    new_tokens=active_config.new_tokens,
                    prefill=active_config.prefill,
                )
                candidate = variant == "pair-nibble-required"
                scale = 1.0 if candidate else 2.0
                metrics.update(
                    {
                        "harness_wall_ms": 100.0 * scale,
                        "harness_wall_seconds": 0.1 * scale,
                        "time_real_seconds": 0.09 * scale,
                        "time_user_seconds": 0.08 * scale,
                        "time_sys_seconds": 0.01 * scale,
                        "time_cpu_seconds": 0.09 * scale,
                        "time_maximum_resident_set_size_bytes": 1000 * scale,
                        "time_peak_memory_footprint_bytes": 800 * scale,
                        "time_instructions_retired": 10_000 * scale,
                        "time_cycles_elapsed": 20_000 * scale,
                    }
                )
                ids = [7, 8]
                return {
                    "variant": variant,
                    "argv": [],
                    "metrics": metrics,
                    "completion_ids": ids,
                    "completion_ids_sha256": pair_ab.sha256_bytes(
                        pair_ab.canonical_ids_bytes(ids)
                    ),
                    "completion_file_sha256": "11" * 32,
                    "telemetry_sha256": "22" * 32,
                    "exit_status": 0,
                }

            with (
                mock.patch.object(pair_ab.platform, "system", return_value="Darwin"),
                mock.patch.object(pair_ab, "run_variant", side_effect=fake_variant),
            ):
                result = pair_ab.run_benchmark(enabled)
            for field in ("harness_wall_seconds", "time_real_seconds"):
                interval = result["separate_over_pair_nibble"][field]
                self.assertEqual(interval["estimate"], 2.0)
                self.assertEqual(interval["ci_low"], 2.0)
                self.assertEqual(interval["ci_high"], 2.0)
                self.assertEqual(interval["bootstrap_resamples"], 100)

    def test_atomic_no_overwrite_preserves_existing_and_dangling_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            existing = root / "existing.json"
            existing.write_text("original\n", encoding="utf-8")
            with self.assertRaisesRegex(pair_ab.HarnessError, "already exists"):
                pair_ab.write_result({"new": True}, existing, False)
            self.assertEqual(existing.read_text(encoding="utf-8"), "original\n")

            dangling = root / "dangling.json"
            dangling.symlink_to(root / "missing.json")
            with self.assertRaisesRegex(pair_ab.HarnessError, "already exists"):
                pair_ab.write_result({"new": True}, dangling, False)
            self.assertTrue(dangling.is_symlink())


if __name__ == "__main__":
    unittest.main()
