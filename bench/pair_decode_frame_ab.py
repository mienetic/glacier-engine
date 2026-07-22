#!/usr/bin/env python3
"""Strict same-artifact PairNibble decode-frame A/B evidence harness.

Both arms execute the same binary, the same prepared PairNibble GLRT, and the
same tokenizer-pinned prompt.  The only policy difference is the request-local
decode frame: the baseline requires the legacy materialized f32 frame and the
candidate requires the compact Pair Q8 frame.  Every observation is a fresh
process in balanced ABBA/BAAB blocks and must produce byte-exact completion
IDs and fail-closed telemetry.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import platform
import random
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


def _load_pair_support():
    """Load the sibling PairNibble harness without trusting ``sys.path``."""
    module_name = "_glacier_pair_decode_frame_pair_support"
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    path = Path(__file__).resolve().with_name("pair_nibble_runtime_ab.py")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load benchmark support module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


_pair = _load_pair_support()
_attention = _pair._attention

SCHEMA = "glacier.pair-decode-frame-ab/result-v1"
MODEL_MANIFEST_SCHEMA = "glacier.pair-decode-frame/model-manifest-v1"
VARIANTS = ("materialized-required", "compact-pair-required")
DEFAULT_SAMPLES_PER_VARIANT = 32
DEFAULT_WARMUPS_PER_VARIANT = 2
DEFAULT_SCHEDULE_SEED = 20_260_721
DEFAULT_BOOTSTRAP_SEED = 0x504149524652414D
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
SYSTEM_TIME_BINARY = Path("/usr/bin/time").resolve()
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1
MAX_I64 = (1 << 63) - 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")
PAIR_NIBBLE_STORAGE_ABI = 0x47504E4200000001
PAIR_NIBBLE_EXECUTOR_ABI = 0x47504E4500000005
PAIR_DECODE_FRAME_ABI = 0x47504E4600000001
GLRT_MLP_UP_KIND = 5
GLRT_MLP_DOWN_KIND = 6
GLRT_MLP_GATE_KIND = 7

RESOURCE_RATIO_FIELDS = _pair.RESOURCE_RATIO_FIELDS
RESOURCE_REQUIRED_POSITIVE_FIELDS = _pair.RESOURCE_REQUIRED_POSITIVE_FIELDS
RESOURCE_MEDIAN_FIELDS = _pair.RESOURCE_MEDIAN_FIELDS
RESOURCE_UNITS = _pair.RESOURCE_UNITS
GREEDY_ARGMAX_ABI = _pair.GREEDY_ARGMAX_ABI

_PAIR_NIBBLE_RE = _pair._PAIR_NIBBLE_RE
_DECODE_PLAN_RE = _pair._DECODE_PLAN_RE
_GREEDY_OUTPUT_RE = _pair._GREEDY_OUTPUT_RE
_TOTAL_RE = _pair._TOTAL_RE
_DECODE_FRAME_RE = re.compile(
    r"^[^\S\r\n]*decode_frame:[^\S\r\n]+policy="
    r"(auto|materialized-required|compact-pair-required)"
    r"[^\S\r\n]+layout=(none|materialized-f32|pair-q8)"
    r"[^\S\r\n]+materialized_uses=([0-9]+)"
    r"[^\S\r\n]+compact_pair_uses=([0-9]+)"
    r"[^\S\r\n]+tensor_payload_bytes=([0-9]+)"
    r"[^\S\r\n]+materialized_counterfactual_bytes=([0-9]+)"
    r"[^\S\r\n]+reclaimed_tensor_payload_bytes=([0-9]+)"
    r"[^\S\r\n]+pair_q8_bytes=([0-9]+)"
    r"[^\S\r\n]+pair_scale_bytes=([0-9]+)"
    r"[^\S\r\n]+down_g8_layers=([0-9]+)"
    r"[^\S\r\n]+down_g16_layers=([0-9]+)"
    r"[^\S\r\n]+abi=([0-9a-f]{1,16})[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)

HarnessError = _attention.HarnessError
canonical_ids_bytes = _attention.canonical_ids_bytes
parse_ids = _attention.parse_ids
sha256_bytes = _attention.sha256_bytes


@dataclass(frozen=True)
class Config:
    binary: Path
    model: Path
    ids: Path
    output: Path | None
    cwd: Path
    prefill: str = "batch"
    samples_per_variant: int = DEFAULT_SAMPLES_PER_VARIANT
    warmups_per_variant: int = DEFAULT_WARMUPS_PER_VARIANT
    new_tokens: int = 64
    threads: int = 4
    schedule_seed: int = DEFAULT_SCHEDULE_SEED
    bootstrap_seed: int = DEFAULT_BOOTSTRAP_SEED
    bootstrap_resamples: int = DEFAULT_BOOTSTRAP_RESAMPLES
    confidence: float = 0.95
    timeout_seconds: float = 3600.0
    overwrite: bool = False
    binary_sha256: str | None = None
    model_sha256: str | None = None
    ids_sha256: str | None = None
    darwin_resources: bool = False
    time_binary: Path = Path("/usr/bin/time")
    time_sha256: str | None = None


def _resource_support():
    return _pair._load_resource_support()


def fingerprint_artifacts(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.model.suffix.lower() != ".glrt":
        raise HarnessError("strict decode-frame A/B requires a .glrt model path")
    resource = _resource_support()
    declarations = {
        "driver": (Path(__file__).resolve(), None),
        "pair_nibble_runtime_support": (Path(_pair.__file__).resolve(), None),
        "attention_ab_support": (Path(_attention.__file__).resolve(), None),
        "resource_ab_support": (Path(resource.__file__).resolve(), None),
        "binary": (config.binary, config.binary_sha256),
        "pair_model": (config.model, config.model_sha256),
        "prompt_ids": (config.ids, config.ids_sha256),
    }
    if config.darwin_resources:
        declarations["time_binary"] = (config.time_binary, config.time_sha256)
    return {
        name: _attention.fingerprint(path, name, expected)
        for name, (path, expected) in declarations.items()
    }


def verify_artifacts(
    config: Config, before: Mapping[str, Mapping[str, Any]]
) -> dict[str, dict[str, Any]]:
    after = fingerprint_artifacts(config)
    for name in before:
        if before[name]["identity"] != after[name]["identity"]:
            raise HarnessError(
                f"artifact {name} filesystem identity changed during A/B"
            )
        if before[name]["sha256"] != after[name]["sha256"]:
            raise HarnessError(f"artifact {name} bytes changed during A/B")
    return after


def _canonical_manifest_sha256(value: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
    ).hexdigest()


def derive_pair_model_manifest(
    model: Path,
    *,
    model_sha256: str,
) -> dict[str, Any]:
    """Derive the only admissible frame ledger from one pinned Pair GLRT."""
    if SHA256_RE.fullmatch(model_sha256) is None:
        raise HarnessError("derived Pair model SHA-256 must be 64 lowercase hex digits")
    artifact_before = _attention.fingerprint(
        model,
        "decode-frame PairNibble GLRT",
        model_sha256,
    )
    image = _pair.parse_glrt_image(model, "decode-frame PairNibble GLRT")
    artifact_after = _attention.fingerprint(
        model,
        "decode-frame PairNibble GLRT",
        model_sha256,
    )
    if (
        artifact_before["identity"] != artifact_after["identity"]
        or artifact_before["sha256"] != artifact_after["sha256"]
    ):
        raise HarnessError("Pair GLRT changed while deriving its frame manifest")
    config = image.header.config
    dim = int(config["dim"])
    hidden = int(config["hidden_dim"])
    layers = int(config["layers"])
    heads = int(config["heads"])
    head_dim = int(config["head_dim"])
    kv_heads = int(config["kv_heads"])
    if dim != heads * head_dim or kv_heads > heads:
        raise HarnessError("Pair GLRT has inconsistent attention geometry")
    kv_dim = kv_heads * head_dim
    if dim % 4 != 0 or hidden % 16 != 0:
        raise HarnessError("Pair GLRT is outside canonical rows4/K16 geometry")

    by_identity = {record.identity(): record for record in image.records}
    down_records = [
        record
        for record in image.records
        if record.role == _pair.GLRT_ROLE_TENSOR and record.kind == GLRT_MLP_DOWN_KIND
    ]
    if len(down_records) != layers:
        raise HarnessError(
            "Pair GLRT must contain exactly one MLP-down record per layer"
        )
    pair_records = [
        record for record in image.records if record.role == _pair.GLRT_ROLE_PAIR
    ]
    if len(pair_records) != layers:
        raise HarnessError(
            "Pair GLRT must contain exactly one PairNibble producer record per layer"
        )
    if any(
        record.role == _pair.GLRT_ROLE_TENSOR
        and record.kind in (GLRT_MLP_UP_KIND, GLRT_MLP_GATE_KIND)
        for record in image.records
    ):
        raise HarnessError("Pair GLRT retains forbidden separate gate/up records")

    down_manifest: list[dict[str, Any]] = []
    activation_scale_counts: list[int] = []
    down_g8_layers = 0
    down_g16_layers = 0
    expected_elements = dim * hidden
    for layer in range(layers):
        pair_record = by_identity.get(("role", layer, _pair.GLRT_ROLE_PAIR))
        if pair_record is None:
            raise HarnessError(f"Pair GLRT is missing PairNibble layer {layer}")
        _pair._require_pair_record(pair_record, layer=layer, config=config)

        down = by_identity.get(("tensor", layer, GLRT_MLP_DOWN_KIND))
        if down is None:
            raise HarnessError(f"Pair GLRT is missing MLP-down layer {layer}")
        if down.group_size not in (8, 16):
            raise HarnessError(f"Pair GLRT MLP-down layer {layer} has a bad group")
        expected_scale_stream_bytes = expected_elements // down.group_size * 2
        lengths = tuple(length for _, length in down.ranges)
        if (
            down.encoding != _pair.GLRT_ENCODING_INT4
            or down.packed_layout != _pair.GLRT_PACKED_ROWS4_K16
            or down.pair_nibble_layout != _pair.GLRT_PAIR_NONE
            or down.flags != 0
            or down.out_f != dim
            or down.in_f != hidden
            or down.num_elements != expected_elements
            or expected_elements % down.group_size != 0
            or lengths
            != (
                expected_elements // 2,
                0,
                0,
                expected_scale_stream_bytes,
                0,
            )
        ):
            raise HarnessError(
                f"Pair GLRT MLP-down layer {layer} is not canonical INT4 rows4/K16"
            )
        if down.group_size == 8:
            down_g8_layers += 1
            activation_group = 32
        else:
            down_g16_layers += 1
            activation_group = 16
        activation_scale_count = (hidden + activation_group - 1) // activation_group
        activation_scale_counts.append(activation_scale_count)
        down_manifest.append(
            {
                "layer": layer,
                "group_size": down.group_size,
                "activation_group_size": activation_group,
                "activation_scale_count": activation_scale_count,
                "packed_weight_bytes": lengths[0],
                "rows4_scale_bytes": lengths[3],
                "canonical_descriptor_sha256": (down.canonical_descriptor_sha256),
                "payload_concat_sha256": down.payload_concat_sha256,
            }
        )

    base_tensor_payload_bytes = (8 * dim + 2 * kv_dim) * 4
    pair_q8_bytes = hidden
    pair_scale_bytes = max(activation_scale_counts) * 4
    materialized_bytes = base_tensor_payload_bytes + 3 * hidden * 4
    compact_bytes = base_tensor_payload_bytes + pair_q8_bytes + pair_scale_bytes
    frame_ledger = {
        "base_tensor_payload_bytes": base_tensor_payload_bytes,
        "materialized_tensor_payload_bytes": materialized_bytes,
        "compact_pair_tensor_payload_bytes": compact_bytes,
        "reclaimed_tensor_payload_bytes": materialized_bytes - compact_bytes,
        "pair_q8_bytes": pair_q8_bytes,
        "pair_scale_bytes": pair_scale_bytes,
        "down_g8_layers": down_g8_layers,
        "down_g16_layers": down_g16_layers,
    }
    manifest: dict[str, Any] = {
        "schema": MODEL_MANIFEST_SCHEMA,
        "model_sha256": model_sha256,
        "glrt_manifest_sha256": image.manifest_sha256,
        "header": image.header.manifest(),
        "geometry": {
            "dim": dim,
            "hidden_dim": hidden,
            "layers": layers,
            "heads": heads,
            "head_dim": head_dim,
            "kv_heads": kv_heads,
            "kv_dim": kv_dim,
        },
        "down_records": down_manifest,
        "frame_ledger": frame_ledger,
        "claims": {
            "strict_glrt_v2_verified": True,
            "exactly_one_pair_producer_per_layer": True,
            "separate_gate_up_records_absent": True,
            "exactly_one_down_record_per_layer": True,
            "all_down_records_int4_rows4_k16": True,
            "frame_ledger_derived_from_pinned_model": True,
        },
    }
    manifest["manifest_sha256"] = _canonical_manifest_sha256(manifest)
    return manifest


def _validated_frame_ledger(
    manifest: Mapping[str, Any],
) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
    if manifest.get("schema") != MODEL_MANIFEST_SCHEMA:
        raise HarnessError("decode-frame model manifest schema mismatch")
    declared_hash = manifest.get("manifest_sha256")
    if not isinstance(declared_hash, str) or SHA256_RE.fullmatch(declared_hash) is None:
        raise HarnessError("decode-frame model manifest hash is malformed")
    hash_input = dict(manifest)
    hash_input.pop("manifest_sha256", None)
    if _canonical_manifest_sha256(hash_input) != declared_hash:
        raise HarnessError("decode-frame model manifest hash mismatch")
    geometry = manifest.get("geometry")
    ledger = manifest.get("frame_ledger")
    if not isinstance(geometry, Mapping) or not isinstance(ledger, Mapping):
        raise HarnessError("decode-frame model manifest is missing its ledger")
    required_geometry = ("dim", "hidden_dim", "layers", "kv_dim")
    required_ledger = (
        "base_tensor_payload_bytes",
        "materialized_tensor_payload_bytes",
        "compact_pair_tensor_payload_bytes",
        "reclaimed_tensor_payload_bytes",
        "pair_q8_bytes",
        "pair_scale_bytes",
        "down_g8_layers",
        "down_g16_layers",
    )
    for name in (*required_geometry, *required_ledger):
        source = geometry if name in required_geometry else ledger
        value = source.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise HarnessError(f"decode-frame model manifest field {name} is invalid")
    if int(geometry["layers"]) <= 0:
        raise HarnessError("decode-frame model manifest has no layers")
    dim = int(geometry["dim"])
    hidden = int(geometry["hidden_dim"])
    kv_dim = int(geometry["kv_dim"])
    layers = int(geometry["layers"])
    base = (8 * dim + 2 * kv_dim) * 4
    materialized = base + 3 * hidden * 4
    compact = base + hidden + int(ledger["pair_scale_bytes"])
    if (
        int(ledger["base_tensor_payload_bytes"]) != base
        or int(ledger["pair_q8_bytes"]) != hidden
        or int(ledger["materialized_tensor_payload_bytes"]) != materialized
        or int(ledger["compact_pair_tensor_payload_bytes"]) != compact
        or int(ledger["reclaimed_tensor_payload_bytes"]) != materialized - compact
        or int(ledger["down_g8_layers"]) + int(ledger["down_g16_layers"]) != layers
    ):
        raise HarnessError("decode-frame model manifest ledger is internally invalid")
    return geometry, ledger


def build_patterns(samples_per_variant: int, seed: int) -> list[str]:
    return _attention.build_patterns(samples_per_variant, seed)


def percentile(values: Sequence[float], probability: float) -> float:
    return _attention.percentile(values, probability)


def paired_ratio(
    samples: Sequence[Mapping[str, Any]],
    field: str,
    *,
    resamples: int,
    seed: int,
    confidence: float,
) -> dict[str, Any]:
    blocks: dict[int, dict[str, list[float]]] = {}
    for sample in samples:
        value = sample["metrics"].get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HarnessError(f"metric {field} is missing or not numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or numeric <= 0:
            raise HarnessError(f"metric {field} must be finite and positive")
        variant = str(sample.get("variant"))
        if variant not in VARIANTS:
            raise HarnessError(f"unknown variant in paired sample: {variant}")
        block = blocks.setdefault(
            int(sample["block_index"]), {mode: [] for mode in VARIANTS}
        )
        block[variant].append(numeric)
    ordered = [blocks[index] for index in sorted(blocks)]
    if not ordered or any(
        len(block[variant]) != 2 for block in ordered for variant in VARIANTS
    ):
        raise HarnessError(
            "paired bootstrap requires two observations per variant per block"
        )

    def ratio(selected: Sequence[Mapping[str, Sequence[float]]]) -> float:
        materialized = [
            value for block in selected for value in block["materialized-required"]
        ]
        compact = [
            value for block in selected for value in block["compact-pair-required"]
        ]
        return statistics.median(materialized) / statistics.median(compact)

    field_seed = int.from_bytes(
        hashlib.sha256(field.encode("ascii")).digest()[:8], "big"
    )
    rng = random.Random(seed ^ field_seed)
    bootstrap: list[float] = []
    for _ in range(resamples):
        selected = [ordered[rng.randrange(len(ordered))] for _ in ordered]
        bootstrap.append(ratio(selected))
    tail = (1.0 - confidence) / 2.0
    return {
        "direction": (
            "materialized_over_compact_pair; greater than 1 favors "
            "compact-pair-required"
        ),
        "estimate": ratio(ordered),
        "confidence": confidence,
        "ci_low": percentile(bootstrap, tail),
        "ci_high": percentile(bootstrap, 1.0 - tail),
        "bootstrap_resamples": resamples,
        "bootstrap_seed": seed,
    }


def _exactly_one_valid(
    output: str, prefix: str, expression: re.Pattern[str], where: str
) -> re.Match[str]:
    prefix_count = len(
        re.findall(rf"^[^\S\r\n]*{re.escape(prefix)}", output, re.I | re.M)
    )
    matches = list(expression.finditer(output))
    if prefix_count != 1 or len(matches) != 1:
        raise HarnessError(f"{where} telemetry is missing, malformed, or duplicated")
    return matches[0]


def _counter(value: str, where: str) -> int:
    result = int(value)
    if result > MAX_I64:
        raise HarnessError(f"{where} exceeds the signed 64-bit evidence bound")
    return result


def _finite_nonnegative(value: str, where: str) -> float:
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise HarnessError(f"{where} must be finite and non-negative")
    return result


def _expected_pair_coverage(
    *, prompt_tokens: int, new_tokens: int, layers: int, prefill: str
) -> dict[str, int]:
    return _pair._expected_pair_coverage(
        prompt_tokens=prompt_tokens,
        new_tokens=new_tokens,
        layers=layers,
        prefill=prefill,
    )


def parse_telemetry(
    output: str,
    *,
    variant: str,
    prompt_tokens: int,
    new_tokens: int,
    prefill: str,
    expected_model_manifest: Mapping[str, Any],
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")
    expected_geometry, expected_frame = _validated_frame_ledger(expected_model_manifest)
    load = _exactly_one_valid(output, "load:", _attention._LOAD_RE, "load")
    ready = _exactly_one_valid(output, "ready:", _attention._READY_RE, "request-ready")
    schedule = _exactly_one_valid(
        output, "schedule:", _attention._SCHEDULE_RE, "schedule"
    )
    phases = _exactly_one_valid(output, "phases:", _attention._PHASES_RE, "phase")
    pair = _exactly_one_valid(output, "pair_nibble:", _PAIR_NIBBLE_RE, "PairNibble")
    frame = _exactly_one_valid(
        output, "decode_frame:", _DECODE_FRAME_RE, "decode-frame"
    )
    plan = _exactly_one_valid(output, "decode_plan:", _DECODE_PLAN_RE, "DecodePlan")
    greedy = _exactly_one_valid(
        output, "greedy_output:", _GREEDY_OUTPUT_RE, "greedy-output"
    )
    total = _exactly_one_valid(output, "time:", _TOTAL_RE, "total-time")

    if load.group(1).lower() != "prepared" or load.group(2).lower() != "glrt":
        raise HarnessError("run did not report a prepared GLRT load")
    if schedule.group(1).lower() != "serial" or schedule.group(2) is not None:
        raise HarnessError("decode-frame A/B requires explicit serial attention")
    layers = _counter(schedule.group(3), "layer count")
    if layers != int(expected_geometry["layers"]):
        raise HarnessError("runtime layer count differs from the pinned Pair GLRT")
    if int(total.group(3)) != prompt_tokens or total.group(4).lower() != prefill:
        raise HarnessError(
            "run did not report the exact prompt count and required prefill mode"
        )

    decode_runs = _counter(phases.group(4), "decode graph count")
    if decode_runs != new_tokens - 1:
        raise HarnessError(
            f"decode graph count was {decode_runs}, expected {new_tokens - 1}"
        )
    phase_counters = tuple(
        _counter(phases.group(index), "phase counter") for index in range(5, 13)
    )
    if any(phase_counters):
        raise HarnessError(
            "serial-attention decode-frame A/B requires zero attention/handoff/legacy-paired counters"
        )

    plan_mode = plan.group(1).lower()
    plan_counters = tuple(
        _counter(plan.group(index), "DecodePlan counter") for index in range(2, 10)
    )
    plan_build_ms = _finite_nonnegative(plan.group(10), "DecodePlan build_ms")
    plan_abi_value = int(plan.group(11), 16)
    if (
        plan_mode != "checked"
        or any(plan_counters)
        or plan_build_ms != 0
        or plan_abi_value == 0
        or plan_abi_value > MAX_U64
    ):
        raise HarnessError(
            "decode-frame A/B requires an idle checked DecodePlan with no fallback/reject work"
        )

    greedy_names = (
        "materialized_projections",
        "logitless_projections",
        "producer_rows",
        "tile_output_bytes",
        "argmax_scan_rows",
        "scratch_bytes",
        "materialized_logits_bytes",
        "steady_state_reclaimed_bytes",
        "fallbacks",
        "rejects",
    )
    greedy_counters = {
        name: _counter(greedy.group(index), f"greedy-output {name}")
        for index, name in enumerate(greedy_names, start=2)
    }
    greedy_abi_value = int(greedy.group(12), 16)
    greedy_abi = f"{greedy_abi_value:016x}"
    if greedy.group(1).lower() != "materialized" or greedy_abi != GREEDY_ARGMAX_ABI:
        raise HarnessError(
            "decode-frame A/B requires the materialized greedy-output policy and ABI"
        )
    expected_greedy = {
        "materialized_projections": new_tokens,
        "logitless_projections": 0,
        "producer_rows": 0,
        "tile_output_bytes": 0,
        "argmax_scan_rows": 0,
        "scratch_bytes": 0,
        "steady_state_reclaimed_bytes": 0,
        "fallbacks": 0,
        "rejects": 0,
    }
    observed_greedy = {name: greedy_counters[name] for name in expected_greedy}
    if (
        observed_greedy != expected_greedy
        or greedy_counters["materialized_logits_bytes"] <= 0
        or greedy_counters["materialized_logits_bytes"] % 4 != 0
    ):
        raise HarnessError(
            f"materialized greedy-output counters were {observed_greedy}, expected {expected_greedy}"
        )

    pair_names = (
        "admissions",
        "artifact_layers",
        "selected_layers",
        "pair_weight_bytes",
        "pair_scale_bytes",
        "separate_gate_bytes",
        "separate_up_bytes",
        "prefill_m1",
        "prefill_m4_groups",
        "prefill_tail_dispatches",
        "prefill_tail_rows",
        "decode_m1",
        "outputless_m1",
        "activation_rows_quantized",
        "selected_layer_rows",
        "checked_dispatches",
        "sealed_dispatches",
        "fallbacks",
        "rejects",
    )
    pair_counters = {
        name: _counter(pair.group(index), f"PairNibble {name}")
        for index, name in enumerate(pair_names, start=4)
    }
    storage_abi_value = int(pair.group(23), 16)
    executor_abi_value = int(pair.group(24), 16)
    if storage_abi_value != PAIR_NIBBLE_STORAGE_ABI:
        raise HarnessError(
            "PairNibble storage ABI mismatch: "
            f"expected {PAIR_NIBBLE_STORAGE_ABI:016x}, got {storage_abi_value:016x}"
        )
    if executor_abi_value != PAIR_NIBBLE_EXECUTOR_ABI:
        raise HarnessError(
            "PairNibble executor ABI mismatch: "
            f"expected {PAIR_NIBBLE_EXECUTOR_ABI:016x}, got {executor_abi_value:016x}"
        )
    if tuple(pair.group(index).lower() for index in (1, 2, 3)) != (
        "pair-nibble-required",
        "pair-nibble",
        "pair-nibble",
    ):
        raise HarnessError(
            "both decode-frame arms must report required PairNibble policy/artifact/selection"
        )
    if pair_counters["admissions"] != 1:
        raise HarnessError("each arm must report exactly one PairNibble admission")
    if (
        pair_counters["artifact_layers"] != layers
        or pair_counters["selected_layers"] != layers
    ):
        raise HarnessError("PairNibble layer coverage is incomplete")
    if (
        pair_counters["pair_weight_bytes"] <= 0
        or pair_counters["pair_scale_bytes"] <= 0
    ):
        raise HarnessError("PairNibble artifact bytes must be resident")
    if (
        pair_counters["separate_gate_bytes"] != 0
        or pair_counters["separate_up_bytes"] != 0
    ):
        raise HarnessError("PairNibble arm retained forbidden separate gate/up bytes")
    expected_coverage = _expected_pair_coverage(
        prompt_tokens=prompt_tokens,
        new_tokens=new_tokens,
        layers=layers,
        prefill=prefill,
    )
    observed_coverage = {name: pair_counters[name] for name in expected_coverage}
    if observed_coverage != expected_coverage:
        raise HarnessError(
            f"PairNibble coverage was {observed_coverage}, expected {expected_coverage}"
        )
    if pair_counters["fallbacks"] != 0 or pair_counters["rejects"] != 0:
        raise HarnessError("PairNibble execution reported fallback/reject work")

    frame_names = (
        "materialized_uses",
        "compact_pair_uses",
        "tensor_payload_bytes",
        "materialized_counterfactual_bytes",
        "reclaimed_tensor_payload_bytes",
        "pair_q8_bytes",
        "pair_scale_bytes",
        "down_g8_layers",
        "down_g16_layers",
    )
    frame_counters = {
        name: _counter(frame.group(index), f"decode-frame {name}")
        for index, name in enumerate(frame_names, start=3)
    }
    frame_abi_value = int(frame.group(12), 16)
    if frame_abi_value != PAIR_DECODE_FRAME_ABI:
        raise HarnessError(
            "decode-frame ABI mismatch: "
            f"expected {PAIR_DECODE_FRAME_ABI:016x}, got {frame_abi_value:016x}"
        )
    if frame.group(1).lower() != variant:
        raise HarnessError("decode-frame telemetry policy does not match the A/B arm")
    if frame_counters["down_g8_layers"] + frame_counters["down_g16_layers"] != layers:
        raise HarnessError("decode-frame down-group layer ledger is incomplete")

    payload = frame_counters["tensor_payload_bytes"]
    counterfactual = frame_counters["materialized_counterfactual_bytes"]
    reclaimed = frame_counters["reclaimed_tensor_payload_bytes"]
    q8_bytes = frame_counters["pair_q8_bytes"]
    scale_bytes = frame_counters["pair_scale_bytes"]
    expected_materialized_bytes = int(
        expected_frame["materialized_tensor_payload_bytes"]
    )
    expected_compact_bytes = int(expected_frame["compact_pair_tensor_payload_bytes"])
    expected_reclaimed_bytes = int(expected_frame["reclaimed_tensor_payload_bytes"])
    expected_pair_q8_bytes = int(expected_frame["pair_q8_bytes"])
    expected_pair_scale_bytes = int(expected_frame["pair_scale_bytes"])
    expected_down_g8_layers = int(expected_frame["down_g8_layers"])
    expected_down_g16_layers = int(expected_frame["down_g16_layers"])
    if (
        counterfactual != expected_materialized_bytes
        or frame_counters["down_g8_layers"] != expected_down_g8_layers
        or frame_counters["down_g16_layers"] != expected_down_g16_layers
    ):
        raise HarnessError(
            "decode-frame telemetry differs from the pinned Pair GLRT ledger"
        )
    if payload <= 0 or counterfactual <= 0:
        raise HarnessError("decode-frame payload byte ledgers must be positive")
    if variant == "materialized-required":
        if frame.group(2).lower() != "materialized-f32":
            raise HarnessError("materialized arm did not select materialized-f32")
        if (
            frame_counters["materialized_uses"] != 1
            or frame_counters["compact_pair_uses"] != 0
            or payload != expected_materialized_bytes
            or reclaimed != 0
            or q8_bytes != 0
            or scale_bytes != 0
        ):
            raise HarnessError("materialized decode-frame byte/use ledger is invalid")
    else:
        if frame.group(2).lower() != "pair-q8":
            raise HarnessError("compact arm did not select pair-q8")
        if (
            frame_counters["materialized_uses"] != 0
            or frame_counters["compact_pair_uses"] != 1
            or q8_bytes != expected_pair_q8_bytes
            or scale_bytes != expected_pair_scale_bytes
            or payload != expected_compact_bytes
            or reclaimed != expected_reclaimed_bytes
        ):
            raise HarnessError("compact Pair decode-frame byte/use ledger is invalid")
        activation_group = 16 if frame_counters["down_g16_layers"] > 0 else 32
        expected_scale_bytes = (
            (q8_bytes + activation_group - 1) // activation_group
        ) * 4
        base_payload = payload - q8_bytes - scale_bytes
        if (
            scale_bytes != expected_scale_bytes
            or base_payload < 0
            or counterfactual != base_payload + 12 * q8_bytes
        ):
            raise HarnessError("compact Pair decode-frame geometry ledger is invalid")

    metrics: dict[str, Any] = {
        "load_ms": _finite_nonnegative(load.group(3), "load_ms"),
        "request_ready_ms": _finite_nonnegative(ready.group(1), "request_ready_ms"),
        "prefill_ms": _finite_nonnegative(phases.group(1), "prefill_ms"),
        "decode_ms": _finite_nonnegative(phases.group(2), "decode_ms"),
        "sampling_ms": _finite_nonnegative(phases.group(3), "sampling_ms"),
        "decode_runs": decode_runs,
        "layers": layers,
        "internal_ms": _finite_nonnegative(total.group(1), "internal_ms"),
        "internal_tokens_per_second": _finite_nonnegative(
            total.group(2), "internal_tokens_per_second"
        ),
        "prefill_mode": total.group(4).lower(),
        "pair_nibble_policy": pair.group(1).lower(),
        "pair_nibble_artifact": pair.group(2).lower(),
        "pair_nibble_selected": pair.group(3).lower(),
        "pair_nibble_storage_abi": f"{storage_abi_value:016x}",
        "pair_nibble_executor_abi": f"{executor_abi_value:016x}",
        "decode_frame_policy": frame.group(1).lower(),
        "decode_frame_layout": frame.group(2).lower(),
        "decode_frame_abi": f"{frame_abi_value:016x}",
        "decode_plan_abi": f"{plan_abi_value:016x}",
        "greedy_output_mode": "materialized",
        "greedy_output_abi": greedy_abi,
        "pair_nibble_line_sha256": sha256_bytes(pair.group(0).strip().encode("ascii")),
        "decode_frame_line_sha256": sha256_bytes(
            frame.group(0).strip().encode("ascii")
        ),
        "greedy_output_line_sha256": sha256_bytes(
            greedy.group(0).strip().encode("ascii")
        ),
    }
    metrics.update(
        {f"pair_nibble_{name}": value for name, value in pair_counters.items()}
    )
    metrics.update(
        {f"decode_frame_{name}": value for name, value in frame_counters.items()}
    )
    metrics.update({f"greedy_{name}": value for name, value in greedy_counters.items()})
    if (
        metrics["prefill_ms"] <= 0
        or metrics["decode_ms"] <= 0
        or metrics["internal_ms"] <= 0
        or metrics["internal_tokens_per_second"] <= 0
    ):
        raise HarnessError(
            "prefill, decode, internal timing, and throughput must be positive"
        )
    resource = _resource_support()
    resource._validate_telemetry_precision(output)
    metrics.update(
        resource._validate_internal_metric_relations(
            metrics,
            completion_tokens=new_tokens,
        )
    )
    return metrics


def build_command(config: Config, variant: str, completion_path: Path) -> list[str]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown variant: {variant}")
    prefill_policy = (
        ["--require-batch-prefill"]
        if config.prefill == "batch"
        else ["--serial-prefill"]
    )
    return [
        str(config.binary),
        "generate",
        str(config.model),
        "--ids-file",
        str(config.ids),
        "--n",
        str(config.new_tokens),
        "--threads",
        str(config.threads),
        "--temp",
        "0",
        "--top-k",
        "0",
        "--top-p",
        "1",
        "--seed",
        "0",
        "--eos",
        str(MAX_U32),
        "--require-prepared-image",
        "--serial-attention",
        "--decode-plan",
        "checked",
        "--greedy-output",
        "materialized",
        "--mlp-layout",
        "pair-nibble-required",
        "--decode-frame",
        variant,
        "--out-ids-file",
        str(completion_path),
        *prefill_policy,
    ]


def _run_process(
    argv: Sequence[str],
    cwd: Path,
    timeout_seconds: float,
    *,
    environment: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter_ns()
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
            env=None if environment is None else dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError as error:
        raise HarnessError(f"cannot launch Glacier: {error}") from error
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise HarnessError(
            f"Glacier timed out after {timeout_seconds} seconds"
        ) from error
    wall_ms = (time.perf_counter_ns() - started) / 1e6
    capture = _resource_support()._capture_process_output(
        output,
        extra_reserved_prefixes=(
            b"pair_nibble:",
            b"decode_frame:",
            b"pair_scratch:",
        ),
    )
    if process.returncode != 0:
        raise HarnessError(
            f"Glacier exited with {process.returncode}:\n{capture['retained_text']}"
        )
    if not math.isfinite(wall_ms) or wall_ms <= 0:
        raise HarnessError("harness wall timing is not finite and positive")
    return {**capture, "wall_ms": wall_ms, "exit_status": process.returncode}


def parse_resource_output(value: str) -> dict[str, int | float]:
    return _resource_support().parse_time_output(value)


def run_variant(
    config: Config,
    variant: str,
    completion_path: Path,
    prompt_ids: Sequence[int],
    artifact_before: Mapping[str, Mapping[str, Any]],
    expected_model_manifest: Mapping[str, Any],
) -> dict[str, Any]:
    _attention.assert_artifact_identities(artifact_before)
    time_path = completion_path.with_name("resource.time")
    if completion_path.exists() or (config.darwin_resources and time_path.exists()):
        raise HarnessError("observation output path unexpectedly exists")
    command = build_command(config, variant, completion_path)
    executed_command = command
    environment = None
    if config.darwin_resources:
        executed_command = [
            str(config.time_binary),
            "-lp",
            "-o",
            str(time_path),
            *command,
        ]
        environment = {"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"}
    process = _run_process(
        executed_command,
        config.cwd,
        config.timeout_seconds,
        environment=environment,
    )
    _attention.assert_artifact_identities(artifact_before)
    if not completion_path.is_file():
        raise HarnessError("Glacier did not create the required completion-ID file")
    try:
        completion_raw = completion_path.read_bytes()
    except OSError as error:
        raise HarnessError(f"cannot read completion IDs: {error}") from error
    completion_ids = parse_ids(completion_raw, "completion output")
    if len(completion_ids) != config.new_tokens:
        raise HarnessError(
            f"completion output had {len(completion_ids)} IDs, expected {config.new_tokens}"
        )
    metrics = parse_telemetry(
        process["telemetry_text"],
        variant=variant,
        prompt_tokens=len(prompt_ids),
        new_tokens=config.new_tokens,
        prefill=config.prefill,
        expected_model_manifest=expected_model_manifest,
    )
    metrics["harness_wall_ms"] = process["wall_ms"]
    result: dict[str, Any] = {
        "variant": variant,
        "argv": command,
        "metrics": metrics,
        "completion_ids": completion_ids,
        "completion_ids_sha256": sha256_bytes(canonical_ids_bytes(completion_ids)),
        "completion_file_sha256": sha256_bytes(completion_raw),
        "telemetry_sha256": process["output_capture"]["raw_sha256"],
        "telemetry_output": process["retained_text"],
        "output_capture": process["output_capture"],
        "exit_status": process["exit_status"],
    }
    if config.darwin_resources:
        if not time_path.is_file():
            raise HarnessError("time did not create the required resource record")
        try:
            time_raw = time_path.read_bytes()
            time_text = time_raw.decode("ascii", errors="strict")
        except (OSError, UnicodeDecodeError) as error:
            raise HarnessError(f"cannot read resource record: {error}") from error
        resource = _resource_support()
        resource._validate_telemetry_precision(process["telemetry_text"])
        resources = parse_resource_output(time_text)
        for field in RESOURCE_REQUIRED_POSITIVE_FIELDS:
            if float(resources[field]) <= 0:
                raise HarnessError(f"resource metric must be positive: {field}")
        harness_wall_seconds = process["wall_ms"] / 1000.0
        relations = resource._validate_metric_relations(
            metrics,
            resources,
            completion_tokens=len(completion_ids),
            harness_wall_seconds=harness_wall_seconds,
        )
        metrics.update(resources)
        metrics.update(relations)
        metrics["harness_wall_seconds"] = harness_wall_seconds
        result.update(
            {
                "timed_argv": executed_command,
                "time_output": time_text,
                "time_output_sha256": sha256_bytes(time_raw),
            }
        )
    return result


def validate_config(config: Config) -> None:
    build_patterns(config.samples_per_variant, config.schedule_seed)
    if config.samples_per_variant > 10_000:
        raise HarnessError("samples per variant must not exceed 10000")
    if not 1 <= config.warmups_per_variant <= 100:
        raise HarnessError("warmups per variant must be in [1, 100]")
    if not 2 <= config.new_tokens <= 1_000_000:
        raise HarnessError("decode-frame A/B new tokens must be in [2, 1000000]")
    if not 1 <= config.threads <= 8:
        raise HarnessError(
            "PairNibble evidence threads must be in the certified range [1, 8]"
        )
    if config.prefill not in ("batch", "serial"):
        raise HarnessError("prefill must be batch or serial")
    if config.prefill == "batch" and config.threads < 2:
        raise HarnessError("batch prefill requires at least two threads")
    if not 100 <= config.bootstrap_resamples <= 1_000_000:
        raise HarnessError("bootstrap resamples must be in [100, 1000000]")
    if not 0 <= config.schedule_seed <= MAX_I64:
        raise HarnessError("schedule seed must be in the signed int64 range")
    if not 0 <= config.bootstrap_seed <= MAX_I64:
        raise HarnessError("bootstrap seed must be in the signed int64 range")
    if not 0.5 <= config.confidence <= 0.999:
        raise HarnessError("confidence must be in [0.5, 0.999]")
    if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
        raise HarnessError("timeout must be finite and positive")
    if not config.cwd.is_dir():
        raise HarnessError(f"cwd is not a directory: {config.cwd}")

    resource_path = Path(_resource_support().__file__).resolve()
    input_paths = {
        config.binary,
        config.model,
        config.ids,
        Path(__file__).resolve(),
        Path(_pair.__file__).resolve(),
        Path(_attention.__file__).resolve(),
        resource_path,
    }
    expected_input_paths = 7
    if config.darwin_resources:
        configured_paths = {
            "binary": config.binary,
            "PairNibble model": config.model,
            "IDs": config.ids,
            "cwd": config.cwd,
            "time binary": config.time_binary,
        }
        if config.output is not None:
            configured_paths["output"] = config.output
        for name, path in configured_paths.items():
            if not path.is_absolute():
                raise HarnessError(
                    f"Darwin resource benchmark path must be absolute ({name}): {path}"
                )
        if (
            platform.system() != "Darwin"
            or config.time_binary.resolve() != SYSTEM_TIME_BINARY
        ):
            raise HarnessError(
                "publishable resource measurements require Darwin /usr/bin/time"
            )
        if not os.access(config.time_binary, os.X_OK):
            raise HarnessError(f"time binary is not executable: {config.time_binary}")
        input_paths.add(config.time_binary)
        expected_input_paths += 1
    if len(input_paths) != expected_input_paths:
        raise HarnessError(
            "binary, PairNibble model, IDs, drivers, support modules, and time must be distinct files"
        )
    if config.output is not None and config.output in input_paths:
        raise HarnessError("result output must not replace a benchmark input artifact")
    for name, digest in (
        ("binary", config.binary_sha256),
        ("PairNibble model", config.model_sha256),
        ("IDs", config.ids_sha256),
        ("time", config.time_sha256),
    ):
        if digest is not None and SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"{name} SHA-256 pin must be 64 lowercase hex digits")


def _pair_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    names = (
        "layers",
        "decode_runs",
        "prefill_mode",
        "pair_nibble_policy",
        "pair_nibble_artifact",
        "pair_nibble_selected",
        "pair_nibble_admissions",
        "pair_nibble_artifact_layers",
        "pair_nibble_selected_layers",
        "pair_nibble_pair_weight_bytes",
        "pair_nibble_pair_scale_bytes",
        "pair_nibble_separate_gate_bytes",
        "pair_nibble_separate_up_bytes",
        "pair_nibble_prefill_m1",
        "pair_nibble_prefill_m4_groups",
        "pair_nibble_prefill_tail_dispatches",
        "pair_nibble_prefill_tail_rows",
        "pair_nibble_decode_m1",
        "pair_nibble_outputless_m1",
        "pair_nibble_activation_rows_quantized",
        "pair_nibble_selected_layer_rows",
        "pair_nibble_checked_dispatches",
        "pair_nibble_sealed_dispatches",
        "pair_nibble_fallbacks",
        "pair_nibble_rejects",
        "pair_nibble_storage_abi",
        "pair_nibble_executor_abi",
        "decode_plan_abi",
    )
    return tuple(metrics[name] for name in names)


def _frame_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    names = (
        "decode_frame_policy",
        "decode_frame_layout",
        "decode_frame_materialized_uses",
        "decode_frame_compact_pair_uses",
        "decode_frame_tensor_payload_bytes",
        "decode_frame_materialized_counterfactual_bytes",
        "decode_frame_reclaimed_tensor_payload_bytes",
        "decode_frame_pair_q8_bytes",
        "decode_frame_pair_scale_bytes",
        "decode_frame_down_g8_layers",
        "decode_frame_down_g16_layers",
        "decode_frame_abi",
    )
    return tuple(metrics[name] for name in names)


def run_benchmark(config: Config) -> dict[str, Any]:
    validate_config(config)
    artifact_before = fingerprint_artifacts(config)
    _attention.assert_artifact_identities(artifact_before)
    model_manifest = derive_pair_model_manifest(
        config.model,
        model_sha256=str(artifact_before["pair_model"]["sha256"]),
    )
    expected_geometry, expected_frame_ledger = _validated_frame_ledger(model_manifest)
    _attention.assert_artifact_identities(artifact_before)
    try:
        prompt_ids = parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise HarnessError(f"cannot read prompt IDs: {error}") from error
    if config.prefill == "batch" and len(prompt_ids) < 8:
        raise HarnessError("batch prefill requires at least eight prompt IDs")

    patterns = build_patterns(config.samples_per_variant, config.schedule_seed)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    layers: int | None = None
    pair_signature: tuple[Any, ...] | None = None
    frame_signatures: dict[str, tuple[Any, ...]] = {}
    with tempfile.TemporaryDirectory(
        prefix="glacier-pair-decode-frame-ab."
    ) as temporary:
        run_root = Path(temporary)

        def observe(
            variant: str,
            *,
            warmup: bool,
            sequence_index: int,
            block_index: int,
            position_in_block: int,
            pattern: str,
        ) -> dict[str, Any]:
            nonlocal reference_ids, layers, pair_signature
            sample_root = run_root / (
                f"{'warmup' if warmup else 'sample'}-{sequence_index:03d}-{variant}"
            )
            sample_root.mkdir()
            item = run_variant(
                config,
                variant,
                sample_root / "completion.ids",
                prompt_ids,
                artifact_before,
                model_manifest,
            )
            item.update(
                {
                    "warmup": warmup,
                    "sequence_index": sequence_index,
                    "block_index": block_index,
                    "position_in_block": position_in_block,
                    "pattern": pattern,
                    "fresh_process": True,
                }
            )
            if reference_ids is None:
                reference_ids = list(item["completion_ids"])
            elif item["completion_ids"] != reference_ids:
                raise HarnessError(
                    "exact completion IDs changed at "
                    f"{'warmup' if warmup else 'sample'} {sequence_index} ({variant})"
                )
            observed_layers = int(item["metrics"]["layers"])
            if layers is None:
                layers = observed_layers
            elif observed_layers != layers:
                raise HarnessError("layer count changed during decode-frame A/B")
            observed_pair = _pair_signature(item["metrics"])
            if pair_signature is None:
                pair_signature = observed_pair
            elif observed_pair != pair_signature:
                raise HarnessError(
                    "PairNibble artifact/coverage changed between decode-frame arms"
                )
            observed_frame = _frame_signature(item["metrics"])
            if variant not in frame_signatures:
                frame_signatures[variant] = observed_frame
            elif frame_signatures[variant] != observed_frame:
                raise HarnessError(f"{variant} decode-frame ledger changed during A/B")
            return item

        warmup_order = list(VARIANTS)
        if config.schedule_seed & 1:
            warmup_order.reverse()
        for _ in range(config.warmups_per_variant):
            for position, variant in enumerate(warmup_order):
                warmups.append(
                    observe(
                        variant,
                        warmup=True,
                        sequence_index=len(warmups),
                        block_index=-1,
                        position_in_block=position,
                        pattern="warmup",
                    )
                )
        for block_index, pattern in enumerate(patterns):
            for position, letter in enumerate(pattern):
                variant = (
                    "compact-pair-required"
                    if letter == "A"
                    else "materialized-required"
                )
                samples.append(
                    observe(
                        variant,
                        warmup=False,
                        sequence_index=len(samples),
                        block_index=block_index,
                        position_in_block=position,
                        pattern=pattern,
                    )
                )

    artifact_after = verify_artifacts(config, artifact_before)
    assert reference_ids is not None
    assert layers is not None
    assert pair_signature is not None
    if layers != int(expected_geometry["layers"]):
        raise HarnessError("campaign layer count differs from the pinned Pair GLRT")

    baseline = next(
        item["metrics"]
        for item in samples
        if item["variant"] == "materialized-required"
    )
    candidate = next(
        item["metrics"]
        for item in samples
        if item["variant"] == "compact-pair-required"
    )
    baseline_bytes = int(baseline["decode_frame_tensor_payload_bytes"])
    candidate_bytes = int(candidate["decode_frame_tensor_payload_bytes"])
    counterfactual = int(candidate["decode_frame_materialized_counterfactual_bytes"])
    reclaimed = int(candidate["decode_frame_reclaimed_tensor_payload_bytes"])
    if (
        int(baseline["decode_frame_materialized_counterfactual_bytes"])
        != counterfactual
        or baseline_bytes
        != int(expected_frame_ledger["materialized_tensor_payload_bytes"])
        or candidate_bytes
        != int(expected_frame_ledger["compact_pair_tensor_payload_bytes"])
        or reclaimed != int(expected_frame_ledger["reclaimed_tensor_payload_bytes"])
        or int(baseline["decode_frame_down_g8_layers"])
        != int(candidate["decode_frame_down_g8_layers"])
        or int(baseline["decode_frame_down_g16_layers"])
        != int(candidate["decode_frame_down_g16_layers"])
    ):
        raise HarnessError("cross-arm decode-frame byte/group ledger is inconsistent")

    ratio_fields = (
        "prefill_ms",
        "decode_ms",
        "internal_ms",
        *(RESOURCE_RATIO_FIELDS if config.darwin_resources else ()),
    )
    ratios = {
        field: paired_ratio(
            samples,
            field,
            resamples=config.bootstrap_resamples,
            seed=config.bootstrap_seed,
            confidence=config.confidence,
        )
        for field in ratio_fields
    }
    median_fields = (
        "load_ms",
        "request_ready_ms",
        "prefill_ms",
        "decode_ms",
        "sampling_ms",
        "internal_ms",
        "internal_tokens_per_second",
        "harness_wall_ms",
        *(RESOURCE_MEDIAN_FIELDS if config.darwin_resources else ()),
    )
    medians = {
        variant: {
            field: statistics.median(
                float(sample["metrics"][field])
                for sample in samples
                if sample["variant"] == variant
            )
            for field in median_fields
        }
        for variant in VARIANTS
    }

    binary_sha256 = str(artifact_before["binary"]["sha256"])
    model_sha256 = str(artifact_before["pair_model"]["sha256"])
    output_capture_contract = _resource_support()._process_output_capture_contract()
    output_capture_contract["raw_reserved_prefix_guard"]["additional_prefixes"] = [
        "pair_nibble:",
        "decode_frame:",
        "pair_scratch:",
    ]
    logical_byte_ledger = {
        **dict(expected_frame_ledger),
        "materialized_over_compact_payload_ratio": baseline_bytes / candidate_bytes,
        "payload_reduction_fraction": reclaimed / baseline_bytes,
        "exact_counterfactual_relation_verified": True,
        "exact_compact_geometry_verified": True,
        "runtime_matches_pinned_model_manifest": True,
    }
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "evidence-valid",
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "python": sys.version,
        },
        "process_output_capture_contract": output_capture_contract,
        "contract": {
            "samples_per_variant": config.samples_per_variant,
            "warmups_per_variant": config.warmups_per_variant,
            "prompt_tokens": len(prompt_ids),
            "new_tokens": config.new_tokens,
            "threads": config.threads,
            "prefill": config.prefill,
            "layers": layers,
            "variants": list(VARIANTS),
            "pair_nibble_storage_abi": f"{PAIR_NIBBLE_STORAGE_ABI:016x}",
            "pair_nibble_executor_abi": f"{PAIR_NIBBLE_EXECUTOR_ABI:016x}",
            "pair_decode_frame_abi": f"{PAIR_DECODE_FRAME_ABI:016x}",
            "strict_prepared_glrt": True,
            "strict_pair_nibble_required_both_arms": True,
            "strict_decode_frame_policy_required": True,
            "strict_materialized_greedy_output_required": True,
            "zero_fallbacks_rejects_and_sealed_dispatches_required": True,
            "exact_pair_coverage_required": True,
            "exact_decode_frame_byte_ledger_required": True,
            "derived_pair_model_manifest": model_manifest,
            "derived_pair_model_manifest_sha256": model_manifest["manifest_sha256"],
            "runtime_frame_telemetry_must_match_derived_manifest": True,
            "same_binary_required": True,
            "same_pair_model_required": True,
            "binary_sha256_by_variant": {
                variant: binary_sha256 for variant in VARIANTS
            },
            "model_sha256_by_variant": {variant: model_sha256 for variant in VARIANTS},
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {
                "A": "compact-pair-required",
                "B": "materialized-required",
            },
            "bootstrap_resamples": config.bootstrap_resamples,
            "exact_completion_ids_required_across_all_invocations": True,
            "darwin_resource_mode": config.darwin_resources,
            "publishable_resource_measurements": config.darwin_resources,
            "resource_wrapper": (
                "/usr/bin/time -lp -o <per-observation-record>"
                if config.darwin_resources
                else None
            ),
            "resource_ratio_fields": (
                list(RESOURCE_RATIO_FIELDS) if config.darwin_resources else []
            ),
        },
        "artifacts_before": artifact_before,
        "artifacts_after": artifact_after,
        "prompt_ids": {
            "count": len(prompt_ids),
            "normalized_sha256": sha256_bytes(canonical_ids_bytes(prompt_ids)),
        },
        "completion_equivalence": {
            "exact_ids_match": True,
            "token_count": len(reference_ids),
            "token_ids": reference_ids,
            "normalized_sha256": sha256_bytes(canonical_ids_bytes(reference_ids)),
            "distinct_normalized_hashes": sorted(
                {item["completion_ids_sha256"] for item in [*warmups, *samples]}
            ),
        },
        "logical_decode_frame_byte_ledger": logical_byte_ledger,
        "warmups": warmups,
        "samples": samples,
        "medians": medians,
        "materialized_over_compact_pair": ratios,
        "resource_evidence": {
            "enabled": config.darwin_resources,
            "measurements_publishable": config.darwin_resources,
            "required_platform_and_timer": "Darwin /usr/bin/time",
            "units": RESOURCE_UNITS if config.darwin_resources else {},
            "paired_ratio_fields": (
                list(RESOURCE_RATIO_FIELDS) if config.darwin_resources else []
            ),
        },
    }
    json.dumps(result, allow_nan=False)
    return result


def write_result(
    result: Mapping[str, Any], output: Path | None, overwrite: bool
) -> None:
    _resource_support().write_resource_result(result, output, overwrite)


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


def argument_parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Run a tokenizer-pinned same-binary/same-Pair-GLRT paired A/B "
            "between materialized and compact Pair decode frames."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument(
        "--model",
        "--pair-model",
        dest="model",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--ids", type=Path, default=repo_root / "bench" / "eval-qwen2.5.ids"
    )
    parser.add_argument("-o", "--output", required=True, help="result JSON path or '-'")
    parser.add_argument("--cwd", type=Path, default=repo_root)
    parser.add_argument("--prefill", choices=("batch", "serial"), default="batch")
    parser.add_argument(
        "--samples-per-variant",
        "--samples",
        dest="samples_per_variant",
        type=_positive_int,
        default=DEFAULT_SAMPLES_PER_VARIANT,
    )
    parser.add_argument(
        "--warmups-per-variant",
        "--warmups",
        dest="warmups_per_variant",
        type=_positive_int,
        default=DEFAULT_WARMUPS_PER_VARIANT,
    )
    parser.add_argument("-n", "--new-tokens", type=_positive_int, default=64)
    parser.add_argument("-t", "--threads", type=_positive_int, default=4)
    parser.add_argument(
        "--schedule-seed", type=_nonnegative_int, default=DEFAULT_SCHEDULE_SEED
    )
    parser.add_argument(
        "--bootstrap-seed", type=_nonnegative_int, default=DEFAULT_BOOTSTRAP_SEED
    )
    parser.add_argument(
        "--bootstrap-resamples",
        type=_positive_int,
        default=DEFAULT_BOOTSTRAP_RESAMPLES,
    )
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument(
        "--darwin-resources",
        action="store_true",
        help=(
            "wrap every invocation in Darwin /usr/bin/time -lp and include "
            "paired RSS/footprint/CPU/instruction/cycle evidence"
        ),
    )
    parser.add_argument("--time-binary", type=Path, default=Path("/usr/bin/time"))
    parser.add_argument("--binary-sha256")
    parser.add_argument("--model-sha256", "--pair-model-sha256", dest="model_sha256")
    parser.add_argument("--ids-sha256")
    parser.add_argument("--time-sha256")
    parser.add_argument("--overwrite", action="store_true")
    return parser


def config_from_args(args: argparse.Namespace) -> Config:
    output = None if args.output == "-" else Path(args.output).expanduser().resolve()
    return Config(
        binary=args.binary.expanduser().resolve(),
        model=args.model.expanduser().resolve(),
        ids=args.ids.expanduser().resolve(),
        output=output,
        cwd=args.cwd.expanduser().resolve(),
        prefill=args.prefill,
        samples_per_variant=args.samples_per_variant,
        warmups_per_variant=args.warmups_per_variant,
        new_tokens=args.new_tokens,
        threads=args.threads,
        schedule_seed=args.schedule_seed,
        bootstrap_seed=args.bootstrap_seed,
        bootstrap_resamples=args.bootstrap_resamples,
        confidence=args.confidence,
        timeout_seconds=args.timeout_seconds,
        overwrite=args.overwrite,
        binary_sha256=args.binary_sha256,
        model_sha256=args.model_sha256,
        ids_sha256=args.ids_sha256,
        darwin_resources=args.darwin_resources,
        time_binary=args.time_binary.expanduser().resolve(),
        time_sha256=args.time_sha256,
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = argument_parser().parse_args(argv)
    try:
        config = config_from_args(args)
        if (
            config.output is not None
            and config.output.exists()
            and not config.overwrite
        ):
            raise HarnessError(
                f"output already exists; pass --overwrite to replace it: {config.output}"
            )
        result = run_benchmark(config)
        write_result(result, config.output, config.overwrite)
        return 0
    except (HarnessError, OSError, ValueError) as error:
        sys.stderr.write(f"error: {error}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
