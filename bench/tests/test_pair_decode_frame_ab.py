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


MODULE_PATH = Path(__file__).resolve().parents[1] / "pair_decode_frame_ab.py"
SPEC = importlib.util.spec_from_file_location("pair_decode_frame_ab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
frame_ab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = frame_ab
SPEC.loader.exec_module(frame_ab)


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

TEST_DIM = 16
TEST_HIDDEN = 64
TEST_HEAD_DIM = 16
TEST_KV_HEADS = 1
TEST_LAYERS = 4
TEST_BASE_BYTES = (8 * TEST_DIM + 2 * TEST_KV_HEADS * TEST_HEAD_DIM) * 4
TEST_MATERIALIZED_BYTES = TEST_BASE_BYTES + 3 * TEST_HIDDEN * 4
TEST_PAIR_Q8_BYTES = TEST_HIDDEN
TEST_PAIR_SCALE_BYTES = ((TEST_HIDDEN + 31) // 32) * 4
TEST_COMPACT_BYTES = TEST_BASE_BYTES + TEST_PAIR_Q8_BYTES + TEST_PAIR_SCALE_BYTES
TEST_RECLAIMED_BYTES = TEST_MATERIALIZED_BYTES - TEST_COMPACT_BYTES


def _expected_model_manifest(
    *,
    layers: int = TEST_LAYERS,
    down_g8_layers: int | None = None,
    down_g16_layers: int = 0,
) -> dict[str, object]:
    if down_g8_layers is None:
        down_g8_layers = layers - down_g16_layers
    pair_scale_bytes = (
        (TEST_HIDDEN + (15 if down_g16_layers else 31))
        // (16 if down_g16_layers else 32)
    ) * 4
    compact_bytes = TEST_BASE_BYTES + TEST_HIDDEN + pair_scale_bytes
    manifest: dict[str, object] = {
        "schema": frame_ab.MODEL_MANIFEST_SCHEMA,
        "geometry": {
            "dim": TEST_DIM,
            "hidden_dim": TEST_HIDDEN,
            "layers": layers,
            "kv_dim": TEST_KV_HEADS * TEST_HEAD_DIM,
        },
        "frame_ledger": {
            "base_tensor_payload_bytes": TEST_BASE_BYTES,
            "materialized_tensor_payload_bytes": TEST_MATERIALIZED_BYTES,
            "compact_pair_tensor_payload_bytes": compact_bytes,
            "reclaimed_tensor_payload_bytes": TEST_MATERIALIZED_BYTES - compact_bytes,
            "pair_q8_bytes": TEST_HIDDEN,
            "pair_scale_bytes": pair_scale_bytes,
            "down_g8_layers": down_g8_layers,
            "down_g16_layers": down_g16_layers,
        },
    }
    manifest["manifest_sha256"] = frame_ab._canonical_manifest_sha256(manifest)
    return manifest


def _align64(value: int) -> int:
    return (value + 63) & ~63


def _pair_record(layer: int) -> dict[str, object]:
    elements = TEST_HIDDEN * TEST_DIM
    packed = bytes((layer * 17 + index) & 0xFF for index in range(elements))
    scales = bytes((layer * 19 + index) & 0xFF for index in range(elements // 8 * 4))
    return {
        "layer": layer,
        "kind": 255,
        "encoding": 2,
        "packed_layout": 0xFFFF,
        "pair_layout": 0,
        "role": 1,
        "group_size": 8,
        "out_f": TEST_HIDDEN,
        "in_f": TEST_DIM,
        "streams": (packed, b"", b"", scales, b""),
    }


def _int4_record(
    layer: int,
    kind: int,
    *,
    out_f: int,
    in_f: int,
    group_size: int,
    rows4: bool = True,
) -> dict[str, object]:
    elements = out_f * in_f
    packed = bytes((layer * 23 + kind + index) & 0xFF for index in range(elements // 2))
    scales = bytes(
        (layer * 29 + kind + index) & 0xFF
        for index in range(elements // group_size * 2)
    )
    streams = (
        (packed, b"", b"", scales, b"") if rows4 else (packed, b"", scales, b"", b"")
    )
    return {
        "layer": layer,
        "kind": kind,
        "encoding": 1,
        "packed_layout": 1 if rows4 else 0,
        "pair_layout": 0xFFFF,
        "role": 0,
        "group_size": group_size,
        "out_f": out_f,
        "in_f": in_f,
        "streams": streams,
    }


def write_pair_glrt(
    path: Path,
    *,
    down_groups: tuple[int, ...] = (8, 8, 8, 8),
    missing_down_layer: int | None = None,
    row_major_down_layer: int | None = None,
    include_gate: bool = False,
) -> None:
    records: list[dict[str, object]] = []
    for layer, group_size in enumerate(down_groups):
        records.append(_pair_record(layer))
        if layer != missing_down_layer:
            records.append(
                _int4_record(
                    layer,
                    6,
                    out_f=TEST_DIM,
                    in_f=TEST_HIDDEN,
                    group_size=group_size,
                    rows4=layer != row_major_down_layer,
                )
            )
        if include_gate and layer == 0:
            records.append(
                _int4_record(
                    layer,
                    7,
                    out_f=TEST_HIDDEN,
                    in_f=TEST_DIM,
                    group_size=8,
                )
            )

    record_count = len(records)
    data_offset = _align64(512 + record_count * 160)
    cursor = data_offset
    planned: list[tuple[bytearray, tuple[bytes, ...], list[tuple[int, int]]]] = []
    for item in records:
        streams = tuple(item["streams"])
        ranges: list[tuple[int, int]] = []
        for payload in streams:
            if payload:
                cursor = _align64(cursor)
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

    file_size = _align64(cursor)
    image = bytearray(file_size)
    for index, (descriptor, streams, ranges) in enumerate(planned):
        start = 512 + index * 160
        image[start : start + 160] = descriptor
        for payload, (offset, length) in zip(streams, ranges):
            if length:
                image[offset : offset + length] = payload
    index_bytes = bytes(image[512 : 512 + record_count * 160])
    header = bytearray(512)
    header[0:4] = b"GLRT"
    struct.pack_into("<HHHHI", header, 4, 2, 512, 160, 64, 0)
    struct.pack_into("<QQQQ", header, 16, record_count, 512, data_offset, file_size)
    header[48:80] = hashlib.sha256(b"frame fixture source").digest()
    header[80:112] = hashlib.sha256(b"frame fixture ABI").digest()
    struct.pack_into(
        "<7I",
        header,
        112,
        TEST_DIM,
        TEST_HIDDEN,
        len(down_groups),
        32,
        1,
        TEST_HEAD_DIM,
        TEST_KV_HEADS,
    )
    header[140] = 1
    struct.pack_into("<ff", header, 144, 1e-5, 10_000.0)
    struct.pack_into("<I", header, 152, zlib.crc32(index_bytes) & 0xFFFFFFFF)
    struct.pack_into("<I", header, 156, zlib.crc32(header) & 0xFFFFFFFF)
    image[:512] = header
    path.write_bytes(image)


def telemetry(
    *,
    variant: str,
    prompt_tokens: int = 9,
    new_tokens: int = 4,
    layers: int = TEST_LAYERS,
    prefill: str = "batch",
    frame_overrides: dict[str, int] | None = None,
    pair_overrides: dict[str, int] | None = None,
    frame_extra: str = "",
    pair_extra: str = "",
) -> str:
    pair_counters = {
        "admissions": 1,
        "artifact_layers": layers,
        "selected_layers": layers,
        "pair_weight_bytes": 256,
        "pair_scale_bytes": 128,
        "separate_gate_bytes": 0,
        "separate_up_bytes": 0,
        **frame_ab._expected_pair_coverage(
            prompt_tokens=prompt_tokens,
            new_tokens=new_tokens,
            layers=layers,
            prefill=prefill,
        ),
        "fallbacks": 0,
        "rejects": 0,
    }
    if pair_overrides:
        pair_counters.update(pair_overrides)

    if variant == "materialized-required":
        layout = "materialized-f32"
        frame_counters = {
            "materialized_uses": 1,
            "compact_pair_uses": 0,
            "tensor_payload_bytes": TEST_MATERIALIZED_BYTES,
            "materialized_counterfactual_bytes": TEST_MATERIALIZED_BYTES,
            "reclaimed_tensor_payload_bytes": 0,
            "pair_q8_bytes": 0,
            "pair_scale_bytes": 0,
            "down_g8_layers": layers,
            "down_g16_layers": 0,
        }
    else:
        layout = "pair-q8"
        frame_counters = {
            "materialized_uses": 0,
            "compact_pair_uses": 1,
            "tensor_payload_bytes": TEST_COMPACT_BYTES,
            "materialized_counterfactual_bytes": TEST_MATERIALIZED_BYTES,
            "reclaimed_tensor_payload_bytes": TEST_RECLAIMED_BYTES,
            "pair_q8_bytes": TEST_PAIR_Q8_BYTES,
            "pair_scale_bytes": TEST_PAIR_SCALE_BYTES,
            "down_g8_layers": layers,
            "down_g16_layers": 0,
        }
    if frame_overrides:
        frame_counters.update(frame_overrides)

    pair_fields = " ".join(f"{name}={value}" for name, value in pair_counters.items())
    frame_fields = " ".join(f"{name}={value}" for name, value in frame_counters.items())
    decode_runs = new_tokens - 1
    return (
        "load: mode=prepared artifact=glrt ms=2.0\n"
        f"schedule: attention=serial layers={layers}\n"
        "ready: phase=request_ready ms=3.0\n"
        "phases: prefill_ms=4.000 decode_ms=5.000 sampling_ms=0.100 "
        f"decode_runs={decode_runs} attention_graphs=0 attention_dispatches=0 "
        "handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 "
        "fused_gqa_dispatches=0 paired_mlp_graphs=0 paired_mlp_dispatches=0\n"
        "pair_nibble: policy=pair-nibble-required artifact=pair-nibble "
        f"selected=pair-nibble {pair_fields} storage_abi=47504e4200000001 "
        f"executor_abi=47504e4500000005{pair_extra}\n"
        f"decode_frame: policy={variant} layout={layout} {frame_fields} "
        f"abi=47504e4600000001{frame_extra}\n"
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
    mutate_model: bool = False,
) -> Path:
    binary = root / "fake-glacier"
    source = f"""
        #!/usr/bin/env python3
        import pathlib,sys
        divergent={divergent_output!r}
        mutate={mutate_model!r}
        a=sys.argv
        model=pathlib.Path(a[2])
        out=pathlib.Path(a[a.index('--out-ids-file')+1])
        prompt=len(pathlib.Path(a[a.index('--ids-file')+1]).read_text().split())
        tokens=int(a[a.index('--n')+1]); runs=tokens-1; layers={TEST_LAYERS}
        variant=a[a.index('--decode-frame')+1]
        compact=variant=='compact-pair-required'
        prefill='serial' if '--serial-prefill' in a else 'batch'
        start=8 if divergent and compact else 7
        out.write_text(' '.join(str(start+i) for i in range(tokens))+'\\n')
        if prefill=='serial':
            pm1=prompt*layers; m4=0; tails=0; tail_rows=0
            prefill_checked=pm1
        else:
            remaining=prompt; groups=0; tail_count=0; tail_sum=0; checked=0
            while remaining:
                rows=min(256,remaining); groups+=rows//4
                tail_count+=int(rows%4!=0); tail_sum+=rows%4
                checked+=(rows+3)//4; remaining-=rows
            pm1=0; m4=groups*layers; tails=tail_count*layers
            tail_rows=tail_sum*layers; prefill_checked=checked*layers
        decode=runs*layers; active=(prompt+runs)*layers
        print('load: mode=prepared artifact=glrt ms=1.0')
        print(f'schedule: attention=serial layers={{layers}}')
        print('ready: phase=request_ready ms=2.0')
        prefill_ms=4.0 if compact else 8.0
        decode_ms=5.0 if compact else 10.0
        internal_ms=10.0 if compact else 20.0
        print(f'phases: prefill_ms={{prefill_ms:.3f}} decode_ms={{decode_ms:.3f}} sampling_ms=0.100 decode_runs={{runs}} attention_graphs=0 attention_dispatches=0 handoff_graphs=0 handoff_dispatches=0 fused_gqa_graphs=0 fused_gqa_dispatches=0 paired_mlp_graphs=0 paired_mlp_dispatches=0')
        print(f'pair_nibble: policy=pair-nibble-required artifact=pair-nibble selected=pair-nibble admissions=1 artifact_layers={{layers}} selected_layers={{layers}} pair_weight_bytes=256 pair_scale_bytes=128 separate_gate_bytes=0 separate_up_bytes=0 prefill_m1={{pm1}} prefill_m4_groups={{m4}} prefill_tail_dispatches={{tails}} prefill_tail_rows={{tail_rows}} decode_m1={{decode}} outputless_m1={{pm1 + decode}} activation_rows_quantized={{active}} selected_layer_rows={{active}} checked_dispatches={{prefill_checked + decode}} sealed_dispatches=0 fallbacks=0 rejects=0 storage_abi=47504e4200000001 executor_abi=47504e4500000005')
        if compact:
            print(f'decode_frame: policy={{variant}} layout=pair-q8 materialized_uses=0 compact_pair_uses=1 tensor_payload_bytes={TEST_COMPACT_BYTES} materialized_counterfactual_bytes={TEST_MATERIALIZED_BYTES} reclaimed_tensor_payload_bytes={TEST_RECLAIMED_BYTES} pair_q8_bytes={TEST_PAIR_Q8_BYTES} pair_scale_bytes={TEST_PAIR_SCALE_BYTES} down_g8_layers={{layers}} down_g16_layers=0 abi=47504e4600000001')
        else:
            print(f'decode_frame: policy={{variant}} layout=materialized-f32 materialized_uses=1 compact_pair_uses=0 tensor_payload_bytes={TEST_MATERIALIZED_BYTES} materialized_counterfactual_bytes={TEST_MATERIALIZED_BYTES} reclaimed_tensor_payload_bytes=0 pair_q8_bytes=0 pair_scale_bytes=0 down_g8_layers={{layers}} down_g16_layers=0 abi=47504e4600000001')
        print('decode_plan: mode=checked sets=0 set_bytes=0 layer_builds=0 layer_binds=0 checked_dispatches=0 sealed_dispatches=0 fallbacks=0 rejects=0 build_ms=0.000 abi=4753445000000004')
        print(f'greedy_output: mode=materialized materialized_projections={{tokens}} logitless_projections=0 producer_rows=0 tile_output_bytes=0 argmax_scan_rows=0 scratch_bytes=0 materialized_logits_bytes=128 steady_state_reclaimed_bytes=0 fallbacks=0 rejects=0 abi=474c4d4800000002')
        print(f'time: {{internal_ms:.2f}} ms ({{tokens * 1000.0 / internal_ms:.1f}} tok/s, prefilled {{prompt}}, prefill={{prefill}})')
        if mutate and compact:
            model.write_bytes(model.read_bytes()+b'x')
    """
    binary.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    binary.chmod(0o755)
    return binary


def make_config(root: Path, binary: Path, *, prefill: str = "batch") -> frame_ab.Config:
    model = root / "pair.glrt"
    write_pair_glrt(model)
    ids = root / "prompt.ids"
    ids.write_text("1 2 3 4 5 6 7 8 9\n", encoding="ascii")
    return frame_ab.Config(
        binary=binary,
        model=model,
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


class PairDecodeFrameAbTests(unittest.TestCase):
    def test_defaults_alias_and_balanced_schedule(self):
        args = frame_ab.argument_parser().parse_args(
            [
                "--binary",
                "glacier",
                "--pair-model",
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
        patterns = frame_ab.build_patterns(32, 1234)
        self.assertEqual(patterns.count("ABBA"), 8)
        self.assertEqual(patterns.count("BAAB"), 8)
        self.assertEqual(patterns, frame_ab.build_patterns(32, 1234))

    def test_model_manifest_derives_mixed_down_groups_and_exact_frame_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "mixed.glrt"
            write_pair_glrt(model, down_groups=(8, 16, 8, 16))
            model_sha256 = hashlib.sha256(model.read_bytes()).hexdigest()
            manifest = frame_ab.derive_pair_model_manifest(
                model,
                model_sha256=model_sha256,
            )
            self.assertEqual(manifest["schema"], frame_ab.MODEL_MANIFEST_SCHEMA)
            self.assertEqual(manifest["model_sha256"], model_sha256)
            self.assertEqual(len(manifest["down_records"]), TEST_LAYERS)
            ledger = manifest["frame_ledger"]
            self.assertEqual(ledger["base_tensor_payload_bytes"], TEST_BASE_BYTES)
            self.assertEqual(
                ledger["materialized_tensor_payload_bytes"],
                TEST_MATERIALIZED_BYTES,
            )
            expected_g16_scales = ((TEST_HIDDEN + 15) // 16) * 4
            self.assertEqual(ledger["pair_scale_bytes"], expected_g16_scales)
            self.assertEqual(
                ledger["compact_pair_tensor_payload_bytes"],
                TEST_BASE_BYTES + TEST_HIDDEN + expected_g16_scales,
            )
            self.assertEqual(ledger["down_g8_layers"], 2)
            self.assertEqual(ledger["down_g16_layers"], 2)
            self.assertEqual(
                manifest["manifest_sha256"],
                frame_ab._canonical_manifest_sha256(
                    {
                        key: value
                        for key, value in manifest.items()
                        if key != "manifest_sha256"
                    }
                ),
            )

    def test_model_manifest_rejects_missing_noncanonical_or_separate_mlp_records(self):
        cases = (
            ({"missing_down_layer": 3}, "exactly one MLP-down"),
            ({"row_major_down_layer": 2}, "rows4/K16"),
            ({"include_gate": True}, "forbidden separate"),
        )
        for options, message in cases:
            with self.subTest(options=options):
                with tempfile.TemporaryDirectory() as temporary:
                    model = Path(temporary) / "broken.glrt"
                    write_pair_glrt(model, **options)
                    digest = hashlib.sha256(model.read_bytes()).hexdigest()
                    with self.assertRaisesRegex(frame_ab.HarnessError, message):
                        frame_ab.derive_pair_model_manifest(
                            model,
                            model_sha256=digest,
                        )

    def test_model_manifest_rejects_corrupted_glrt_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "corrupted.glrt"
            write_pair_glrt(model)
            with self.assertRaisesRegex(frame_ab.HarnessError, "SHA-256 mismatch"):
                frame_ab.derive_pair_model_manifest(
                    model,
                    model_sha256="0" * 64,
                )
            damaged = bytearray(model.read_bytes())
            damaged[-1] ^= 1
            model.write_bytes(damaged)
            digest = hashlib.sha256(damaged).hexdigest()
            with self.assertRaisesRegex(frame_ab.HarnessError, "CRC|digest"):
                frame_ab.derive_pair_model_manifest(
                    model,
                    model_sha256=digest,
                )

    def test_strict_parser_accepts_both_exact_frame_ledgers_and_executor_abi_v5(self):
        materialized = frame_ab.parse_telemetry(
            telemetry(variant="materialized-required"),
            variant="materialized-required",
            prompt_tokens=9,
            new_tokens=4,
            prefill="batch",
            expected_model_manifest=_expected_model_manifest(),
        )
        compact = frame_ab.parse_telemetry(
            telemetry(variant="compact-pair-required"),
            variant="compact-pair-required",
            prompt_tokens=9,
            new_tokens=4,
            prefill="batch",
            expected_model_manifest=_expected_model_manifest(),
        )
        self.assertEqual(
            materialized["decode_frame_tensor_payload_bytes"],
            TEST_MATERIALIZED_BYTES,
        )
        self.assertEqual(
            compact["decode_frame_tensor_payload_bytes"], TEST_COMPACT_BYTES
        )
        self.assertEqual(
            compact["decode_frame_reclaimed_tensor_payload_bytes"],
            TEST_RECLAIMED_BYTES,
        )
        self.assertEqual(compact["pair_nibble_executor_abi"], "47504e4500000005")
        self.assertEqual(compact["decode_frame_abi"], "47504e4600000001")
        self.assertEqual(compact["pair_nibble_prefill_m4_groups"], 8)
        self.assertEqual(compact["pair_nibble_decode_m1"], 12)

    def test_strict_parser_accepts_serial_pair_coverage(self):
        parsed = frame_ab.parse_telemetry(
            telemetry(variant="compact-pair-required", prefill="serial"),
            variant="compact-pair-required",
            prompt_tokens=9,
            new_tokens=4,
            prefill="serial",
            expected_model_manifest=_expected_model_manifest(),
        )
        self.assertEqual(parsed["pair_nibble_prefill_m1"], 36)
        self.assertEqual(parsed["pair_nibble_outputless_m1"], 48)
        self.assertEqual(parsed["pair_nibble_checked_dispatches"], 48)

    def test_runtime_telemetry_must_match_pinned_model_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "g16.glrt"
            write_pair_glrt(model, down_groups=(16, 16, 16, 16))
            manifest = frame_ab.derive_pair_model_manifest(
                model,
                model_sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
            )
            with self.assertRaisesRegex(frame_ab.HarnessError, "pinned Pair GLRT"):
                frame_ab.parse_telemetry(
                    telemetry(variant="compact-pair-required"),
                    variant="compact-pair-required",
                    prompt_tokens=9,
                    new_tokens=4,
                    prefill="batch",
                    expected_model_manifest=manifest,
                )

        malformed = _expected_model_manifest()
        malformed["manifest_sha256"] = "0" * 64
        with self.assertRaisesRegex(frame_ab.HarnessError, "manifest hash mismatch"):
            frame_ab.parse_telemetry(
                telemetry(variant="compact-pair-required"),
                variant="compact-pair-required",
                prompt_tokens=9,
                new_tokens=4,
                prefill="batch",
                expected_model_manifest=malformed,
            )

    def test_decode_frame_line_is_exactly_once_and_fail_closed(self):
        valid = telemetry(variant="compact-pair-required")
        frame_line = next(
            line for line in valid.splitlines() if line.startswith("decode_frame:")
        )
        broken_values = (
            valid + frame_line + "\n",
            valid.replace(" abi=47504e4600000001\n", " abi=1\n"),
            telemetry(variant="compact-pair-required", frame_extra=" extra=1"),
        )
        for broken in broken_values:
            with self.subTest(tail=broken[-100:]):
                with self.assertRaises(frame_ab.HarnessError):
                    frame_ab.parse_telemetry(
                        broken,
                        variant="compact-pair-required",
                        prompt_tokens=9,
                        new_tokens=4,
                        prefill="batch",
                        expected_model_manifest=_expected_model_manifest(),
                    )

    def test_wrong_executor_abi_pair_coverage_and_frame_geometry_fail(self):
        cases = (
            (
                telemetry(variant="compact-pair-required").replace(
                    "executor_abi=47504e4500000005",
                    "executor_abi=47504e4500000003",
                ),
                "executor ABI",
            ),
            (
                telemetry(
                    variant="compact-pair-required",
                    pair_overrides={"outputless_m1": 11},
                ),
                "coverage",
            ),
            (
                telemetry(
                    variant="compact-pair-required",
                    frame_overrides={"pair_scale_bytes": 4},
                ),
                "byte/use",
            ),
            (
                telemetry(
                    variant="materialized-required",
                    frame_overrides={"reclaimed_tensor_payload_bytes": 1},
                ),
                "materialized",
            ),
        )
        for output, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(frame_ab.HarnessError, message):
                    variant = (
                        "materialized-required"
                        if "policy=materialized-required" in output
                        else "compact-pair-required"
                    )
                    frame_ab.parse_telemetry(
                        output,
                        variant=variant,
                        prompt_tokens=9,
                        new_tokens=4,
                        prefill="batch",
                        expected_model_manifest=_expected_model_manifest(),
                    )

    def test_commands_are_same_binary_model_and_differ_only_by_frame_policy(self):
        config = frame_ab.Config(
            binary=Path("/tmp/glacier"),
            model=Path("/tmp/pair.glrt"),
            ids=Path("/tmp/prompt.ids"),
            output=None,
            cwd=Path("/tmp"),
        )
        completion = Path("/tmp/out.ids")
        baseline = frame_ab.build_command(config, "materialized-required", completion)
        candidate = frame_ab.build_command(config, "compact-pair-required", completion)
        self.assertEqual(baseline[0:3], candidate[0:3])
        self.assertEqual(
            baseline[baseline.index("--mlp-layout") + 1], "pair-nibble-required"
        )
        self.assertIn("--require-prepared-image", baseline)
        self.assertIn("--serial-attention", baseline)
        normalized = list(candidate)
        normalized[normalized.index("--decode-frame") + 1] = "materialized-required"
        self.assertEqual(baseline, normalized)

    def test_paired_bootstrap_is_deterministic_and_favors_compact(self):
        samples = []
        for block_index, pattern in enumerate(("ABBA", "BAAB")):
            for letter in pattern:
                variant = (
                    "compact-pair-required"
                    if letter == "A"
                    else "materialized-required"
                )
                samples.append(
                    {
                        "block_index": block_index,
                        "variant": variant,
                        "metrics": {
                            "decode_ms": (
                                5.0 if variant == "compact-pair-required" else 10.0
                            )
                        },
                    }
                )
        first = frame_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        second = frame_ab.paired_ratio(
            samples,
            "decode_ms",
            resamples=100,
            seed=99,
            confidence=0.95,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["estimate"], 2.0)
        self.assertEqual(first["ci_low"], 2.0)
        self.assertTrue(first["direction"].startswith("materialized_over_compact"))

    def test_lightweight_end_to_end_same_artifact_manifest_and_exact_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            result = frame_ab.run_benchmark(config)
            self.assertEqual(result["schema"], frame_ab.SCHEMA)
            self.assertEqual(result["status"], "evidence-valid")
            self.assertEqual(len(result["samples"]), 8)
            self.assertEqual(len(result["warmups"]), 2)
            self.assertEqual(result["completion_equivalence"]["token_ids"], [7, 8])
            self.assertTrue(result["completion_equivalence"]["exact_ids_match"])
            self.assertEqual(
                result["materialized_over_compact_pair"]["decode_ms"]["estimate"],
                2.0,
            )
            contract = result["contract"]
            self.assertEqual(contract["letter_mapping"]["A"], "compact-pair-required")
            self.assertEqual(contract["letter_mapping"]["B"], "materialized-required")
            self.assertEqual(len(set(contract["binary_sha256_by_variant"].values())), 1)
            self.assertEqual(len(set(contract["model_sha256_by_variant"].values())), 1)
            derived = contract["derived_pair_model_manifest"]
            self.assertEqual(
                contract["derived_pair_model_manifest_sha256"],
                derived["manifest_sha256"],
            )
            self.assertEqual(
                derived["model_sha256"],
                result["artifacts_before"]["pair_model"]["sha256"],
            )
            self.assertEqual(len(derived["down_records"]), TEST_LAYERS)
            self.assertTrue(
                contract["runtime_frame_telemetry_must_match_derived_manifest"]
            )
            ledger = result["logical_decode_frame_byte_ledger"]
            self.assertEqual(
                ledger["materialized_tensor_payload_bytes"],
                TEST_MATERIALIZED_BYTES,
            )
            self.assertEqual(
                ledger["compact_pair_tensor_payload_bytes"], TEST_COMPACT_BYTES
            )
            self.assertEqual(
                ledger["reclaimed_tensor_payload_bytes"], TEST_RECLAIMED_BYTES
            )
            self.assertTrue(ledger["exact_compact_geometry_verified"])
            self.assertEqual(
                result["process_output_capture_contract"]["raw_reserved_prefix_guard"][
                    "additional_prefixes"
                ],
                ["pair_nibble:", "decode_frame:", "pair_scratch:"],
            )
            for name in result["artifacts_before"]:
                self.assertEqual(
                    result["artifacts_before"][name]["sha256"],
                    result["artifacts_after"][name]["sha256"],
                )
            json.dumps(result, allow_nan=False)

    def test_exact_completion_divergence_and_model_mutation_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root, divergent_output=True))
            with self.assertRaisesRegex(frame_ab.HarnessError, "exact completion"):
                frame_ab.run_benchmark(config)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root, mutate_model=True))
            with self.assertRaisesRegex(frame_ab.HarnessError, "identity changed"):
                frame_ab.run_benchmark(config)

    def test_raw_prefix_taint_is_rejected_and_binary_output_is_hashed(self):
        accepted = frame_ab._run_process(
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
        for payload in (
            b"pair_nibble: policy=x\xff\n",
            b"decode_frame: policy=x\xff\n",
            b"decode_\xffframe: policy=x\n",
            b"decode_frame: policy=x\r\n",
        ):
            with self.subTest(payload=payload):
                with self.assertRaises(frame_ab.HarnessError):
                    frame_ab._run_process(
                        [
                            sys.executable,
                            "-c",
                            f"import os; os.write(1, {payload!r})",
                        ],
                        Path.cwd(),
                        10.0,
                    )

    def test_resource_parser_and_darwin_gate_are_reused(self):
        parsed = frame_ab.parse_resource_output(TIME_RECORD)
        self.assertEqual(parsed["time_cpu_seconds"], 3.75)
        self.assertEqual(parsed["time_maximum_resident_set_size_bytes"], 426_328_064)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            enabled = frame_ab.Config(**{**config.__dict__, "darwin_resources": True})
            with mock.patch.object(frame_ab.platform, "system", return_value="Linux"):
                with self.assertRaisesRegex(frame_ab.HarnessError, "Darwin"):
                    frame_ab.validate_config(enabled)

    def test_config_rejects_batch_one_thread_and_aliased_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = make_config(root, write_fake_glacier(root))
            one = frame_ab.Config(**{**config.__dict__, "threads": 1})
            with self.assertRaisesRegex(frame_ab.HarnessError, "at least two"):
                frame_ab.validate_config(one)
            aliased = frame_ab.Config(
                **{
                    **config.__dict__,
                    "ids": config.model,
                    "prefill": "serial",
                }
            )
            with self.assertRaisesRegex(frame_ab.HarnessError, "distinct"):
                frame_ab.validate_config(aliased)


if __name__ == "__main__":
    unittest.main()
