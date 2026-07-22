#!/usr/bin/env python3
"""Strict same-artifact PairNibble batch-prefill-frame A/B harness.

The baseline and candidate execute one pinned binary, one prepared PairNibble
GLRT, and one provenance-bound prompt.  The only command-line difference is
``--pair-prefill-frame``: the baseline requires the materialized prompt MLP
frame while the candidate requires a bounded 32- or 64-row Pair capsule.

Every measured observation is a fresh process in a balanced ABBA/BAAB block.
``--n 1`` executes the complete prompt graph and first LM head without a
decode graph, making ``prefill_phase.graph_ms`` the paired promotion metric.
Evidence validity is deliberately separate from the promotion decision: an
exact but slower compact implementation remains publishable evidence.
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


def _load_frame_support():
    """Load sibling evidence code without trusting the caller's sys.path."""
    module_name = "_glacier_pair_prefill_frame_support"
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    path = Path(__file__).resolve().with_name("pair_decode_frame_ab.py")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load benchmark support module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


_frame = _load_frame_support()
_pair = _frame._pair
_attention = _frame._attention

SCHEMA = "glacier.pair-prefill-frame-ab/result-v1"
MODEL_MANIFEST_SCHEMA = "glacier.pair-prefill-frame/model-manifest-v1"
PROMPT_MANIFEST_SCHEMA = "glacier.pair-prefill-frame/prompt-manifest-v1"
CAMPAIGN_MANIFEST_SCHEMA = "glacier.pair-prefill-frame/campaign-manifest-v1"
FROZEN_PROVENANCE_SCHEMA = "glacier.pair-prefill-natural-ids.v1"
BASELINE = "materialized-required"
CANDIDATES = ("compact-32-required", "compact-64-required")
PROMPT_PROFILES = {"p128": 128, "p512": 512, "p2048": 2048}
CAMPAIGNS = ("primary", "replication")
DEFAULT_CANDIDATE = "compact-64-required"
DEFAULT_SAMPLES_PER_VARIANT = 32
DEFAULT_WARMUPS_PER_VARIANT = 2
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
CAMPAIGN_SEEDS = {
    "primary": {
        "schedule": 20_260_721,
        "bootstrap": 0x5041495250465031,
    },
    "replication": {
        "schedule": 20_260_722,
        "bootstrap": 0x5041495250465032,
    },
}
DEFAULT_GRAPH_CI_MIN = 1.0
AUTO_GRAPH_CI_MIN = 1.05
PUBLICATION_CONFIDENCE = 0.95
PRODUCTION_BINARY_SIZE_MAX_BYTES = 696_349
PREFILL_CHUNK_ROWS = 256
COMPACT_TILE_ROWS = 64
SYSTEM_TIME_BINARY = Path("/usr/bin/time").resolve()
MAX_U32 = (1 << 32) - 1
MAX_U64 = (1 << 64) - 1
MAX_I64 = (1 << 63) - 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")

PAIR_NIBBLE_STORAGE_ABI = 0x47504E4200000001
PAIR_NIBBLE_EXECUTOR_ABI = 0x47504E4500000005
PAIR_DECODE_FRAME_ABI = 0x47504E4600000001
PAIR_SCRATCH_ABI = 0x47504E5300000001
PAIR_PREFILL_FRAME_ABI = 0x47504E5000000001
PREFILL_PHASE_ABI = 0x4750485300000001
GREEDY_ARGMAX_ABI = _pair.GREEDY_ARGMAX_ABI

GLRT_ATTN_KINDS = (1, 2, 3, 4)
GLRT_MLP_DOWN_KIND = 6
F32_BYTES = 4
FIXED_SCRATCH_CAPACITY_ROWS = 256
SCRATCH_ARRAYS_PER_PARTICIPANT = 2

# This is intentionally a prefill-only allowlist.  In particular, ``decode_ms``
# is exactly zero under the required ``--n 1`` contract and therefore cannot be
# used by the strictly-positive paired-ratio bootstrap.
RESOURCE_RATIO_FIELDS = (
    "harness_wall_seconds",
    "time_real_seconds",
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
    "time_cpu_seconds",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
if not set(RESOURCE_RATIO_FIELDS).issubset(_frame.RESOURCE_RATIO_FIELDS):
    raise RuntimeError("Pair prefill resource support is missing a required field")
RESOURCE_REQUIRED_POSITIVE_FIELDS = _frame.RESOURCE_REQUIRED_POSITIVE_FIELDS
RESOURCE_MEDIAN_FIELDS = _frame.RESOURCE_MEDIAN_FIELDS
RESOURCE_UNITS = _frame.RESOURCE_UNITS
CPU_RESOURCE_PROMOTION_FIELDS = (
    "time_cpu_seconds",
    "time_instructions_retired",
    "time_cycles_elapsed",
)
MEMORY_RESOURCE_PROMOTION_FIELDS = (
    "time_maximum_resident_set_size_bytes",
    "time_peak_memory_footprint_bytes",
)

_PAIR_NIBBLE_RE = _pair._PAIR_NIBBLE_RE
_DECODE_PLAN_RE = _pair._DECODE_PLAN_RE
_GREEDY_OUTPUT_RE = _pair._GREEDY_OUTPUT_RE
_TOTAL_RE = _pair._TOTAL_RE
_DECODE_FRAME_RE = _frame._DECODE_FRAME_RE

_PREFILL_PHASE_RE = re.compile(
    r"^[^\S\r\n]*prefill_phase:[^\S\r\n]+graph_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+first_head_ms="
    r"([0-9]+(?:\.[0-9]+)?)[^\S\r\n]+abi="
    r"([0-9a-f]{1,16})[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)

_PAIR_PREFILL_FRAME_RE = re.compile(
    r"^[^\S\r\n]*pair_prefill_frame:[^\S\r\n]+selected_policy="
    r"(disabled|materialized|compact-32|compact-64)"
    r"[^\S\r\n]+producer_g8_layers=([0-9]+)"
    r"[^\S\r\n]+producer_g16_layers=([0-9]+)"
    r"[^\S\r\n]+down_g8_layers=([0-9]+)"
    r"[^\S\r\n]+down_g16_layers=([0-9]+)"
    r"[^\S\r\n]+chunk_capacity=([0-9]+)"
    r"[^\S\r\n]+chunk_count=([0-9]+)"
    r"[^\S\r\n]+full_chunks=([0-9]+)"
    r"[^\S\r\n]+tail_chunks=([0-9]+)"
    r"[^\S\r\n]+peak_active_rows=([0-9]+)"
    r"[^\S\r\n]+capsule_rows=([0-9]+)"
    r"[^\S\r\n]+tile_rows=([0-9]+)"
    r"[^\S\r\n]+task_slots=([0-9]+)"
    r"[^\S\r\n]+materialized_layer_uses=([0-9]+)"
    r"[^\S\r\n]+compact_layer_uses=([0-9]+)"
    r"[^\S\r\n]+capsules=([0-9]+)"
    r"[^\S\r\n]+pair_input_rows=([0-9]+)"
    r"[^\S\r\n]+pair_output_rows=([0-9]+)"
    r"[^\S\r\n]+prepared_down_rows=([0-9]+)"
    r"[^\S\r\n]+prepared_down_dispatches=([0-9]+)"
    r"[^\S\r\n]+common_payload_bytes=([0-9]+)"
    r"[^\S\r\n]+gate_bytes=([0-9]+)"
    r"[^\S\r\n]+up_bytes=([0-9]+)"
    r"[^\S\r\n]+silu_bytes=([0-9]+)"
    r"[^\S\r\n]+q_scratch_bytes=([0-9]+)"
    r"[^\S\r\n]+scale_scratch_bytes=([0-9]+)"
    r"[^\S\r\n]+pair_q8_bytes=([0-9]+)"
    r"[^\S\r\n]+pair_scale_bytes=([0-9]+)"
    r"[^\S\r\n]+gate_tile_bytes=([0-9]+)"
    r"[^\S\r\n]+up_tile_bytes=([0-9]+)"
    r"[^\S\r\n]+tensor_payload_bytes=([0-9]+)"
    r"[^\S\r\n]+materialized_counterfactual_bytes=([0-9]+)"
    r"[^\S\r\n]+reclaimed_tensor_payload_bytes=([0-9]+)"
    r"[^\S\r\n]+arena_sets=([0-9]+)"
    r"[^\S\r\n]+logical_slices=([0-9]+)"
    r"[^\S\r\n]+fallbacks=([0-9]+)"
    r"[^\S\r\n]+rejects=([0-9]+)"
    r"[^\S\r\n]+abi=([0-9a-f]{1,16})[^\S\r\n]*$",
    re.IGNORECASE | re.MULTILINE,
)

_PAIR_SCRATCH_RE = re.compile(
    r"^[^\S\r\n]*pair_scratch:[^\S\r\n]+policy="
    r"(auto|fixed-256-required|model-shaped-required)"
    r"[^\S\r\n]+selected=(disabled|fixed-256|model-shaped)"
    r"[^\S\r\n]+layout=(none|executor-private-f32)"
    r"[^\S\r\n]+participants=([0-9]+)"
    r"[^\S\r\n]+producer_g8_layers=([0-9]+)"
    r"[^\S\r\n]+producer_g16_layers=([0-9]+)"
    r"[^\S\r\n]+selected_g8_rows=([0-9]+)"
    r"[^\S\r\n]+selected_g16_rows=([0-9]+)"
    r"[^\S\r\n]+capacity_rows=([0-9]+)"
    r"[^\S\r\n]+arrays_per_participant=([0-9]+)"
    r"[^\S\r\n]+branch_stride_rows=([0-9]+)"
    r"[^\S\r\n]+participant_stride_rows=([0-9]+)"
    r"[^\S\r\n]+f32_elements=([0-9]+)"
    r"[^\S\r\n]+bytes=([0-9]+)"
    r"[^\S\r\n]+fixed_counterfactual_bytes=([0-9]+)"
    r"[^\S\r\n]+reclaimed_bytes=([0-9]+)"
    r"[^\S\r\n]+allocations=([0-9]+)"
    r"[^\S\r\n]+fixed_dispatches=([0-9]+)"
    r"[^\S\r\n]+model_shaped_dispatches=([0-9]+)"
    r"[^\S\r\n]+fallbacks=([0-9]+)"
    r"[^\S\r\n]+rejects=([0-9]+)"
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
    provenance: Path
    output: Path | None
    cwd: Path
    prompt_profile: str = "p128"
    campaign: str = "primary"
    candidate: str = DEFAULT_CANDIDATE
    source_id: str = ""
    source_sha256: str = ""
    tokenizer_id: str = ""
    tokenizer_sha256: str = ""
    samples_per_variant: int = DEFAULT_SAMPLES_PER_VARIANT
    warmups_per_variant: int = DEFAULT_WARMUPS_PER_VARIANT
    threads: int = 4
    schedule_seed: int = CAMPAIGN_SEEDS["primary"]["schedule"]
    bootstrap_seed: int = CAMPAIGN_SEEDS["primary"]["bootstrap"]
    bootstrap_resamples: int = DEFAULT_BOOTSTRAP_RESAMPLES
    confidence: float = 0.95
    graph_ci_min: float = DEFAULT_GRAPH_CI_MIN
    timeout_seconds: float = 3600.0
    overwrite: bool = False
    binary_sha256: str | None = None
    model_sha256: str | None = None
    ids_sha256: str | None = None
    provenance_sha256: str | None = None
    darwin_resources: bool = False
    time_binary: Path = Path("/usr/bin/time")
    time_sha256: str | None = None


def variants(config: Config) -> tuple[str, str]:
    if config.candidate not in CANDIDATES:
        raise HarnessError(
            f"unknown compact Pair prefill candidate: {config.candidate}"
        )
    return (BASELINE, config.candidate)


def _resource_support():
    return _frame._resource_support()


def _canonical_sha256(value: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
    ).hexdigest()


def _with_manifest_hash(value: Mapping[str, Any]) -> dict[str, Any]:
    result = dict(value)
    result["manifest_sha256"] = _canonical_sha256(result)
    return result


def _validate_manifest_hash(value: Mapping[str, Any], schema: str, where: str) -> None:
    if value.get("schema") != schema:
        raise HarnessError(f"{where} schema mismatch")
    digest = value.get("manifest_sha256")
    if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
        raise HarnessError(f"{where} hash is malformed")
    canonical = dict(value)
    canonical.pop("manifest_sha256", None)
    if _canonical_sha256(canonical) != digest:
        raise HarnessError(f"{where} hash mismatch")


def fingerprint_artifacts(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.model.suffix.lower() != ".glrt":
        raise HarnessError("strict Pair prefill A/B requires a .glrt model")
    resource = _resource_support()
    declarations = {
        "driver": (Path(__file__).resolve(), None),
        "frame_ab_support": (Path(_frame.__file__).resolve(), None),
        "pair_nibble_runtime_support": (Path(_pair.__file__).resolve(), None),
        "attention_ab_support": (Path(_attention.__file__).resolve(), None),
        "resource_ab_support": (Path(resource.__file__).resolve(), None),
        "binary": (config.binary, config.binary_sha256),
        "pair_model": (config.model, config.model_sha256),
        "prompt_ids": (config.ids, config.ids_sha256),
        "frozen_prompt_provenance": (
            config.provenance,
            config.provenance_sha256,
        ),
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
    for name, first in before.items():
        if first["identity"] != after[name]["identity"]:
            raise HarnessError(f"artifact {name} identity changed during A/B")
        if first["sha256"] != after[name]["sha256"]:
            raise HarnessError(f"artifact {name} bytes changed during A/B")
    return after


def _activation_scale_count(in_f: int, group_size: int) -> int:
    if group_size == 8:
        activation_group = 32
    elif group_size == 16:
        activation_group = 16
    else:
        raise HarnessError("INT4 group is outside the certified Pair domain")
    return (in_f + activation_group - 1) // activation_group


def _checked_evidence_int(value: int, where: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise HarnessError(f"{where} is not an integer")
    if value < (1 if positive else 0) or value > MAX_I64:
        raise HarnessError(f"{where} is outside the signed 64-bit evidence bound")
    return value


def _derive_prefill_ledger(
    *,
    variant: str,
    prompt_tokens: int,
    threads: int,
    dim: int,
    kv_dim: int,
    hidden: int,
    max_producer_scale_stride: int,
    pair_scale_stride: int,
) -> dict[str, int]:
    if variant not in (BASELINE, *CANDIDATES):
        raise HarnessError(f"unknown Pair prefill-frame variant: {variant}")
    for name, value in (
        ("prompt tokens", prompt_tokens),
        ("threads", threads),
        ("dim", dim),
        ("kv_dim", kv_dim),
        ("hidden", hidden),
        ("producer scale stride", max_producer_scale_stride),
        ("Pair scale stride", pair_scale_stride),
    ):
        _checked_evidence_int(value, name, positive=True)
    chunk_capacity = min(prompt_tokens, PREFILL_CHUNK_ROWS)
    common_payload = chunk_capacity * (9 * dim + 2 * kv_dim) * F32_BYTES
    materialized_q = chunk_capacity * max(dim, hidden)
    materialized_scale = chunk_capacity * ((max(dim, hidden) + 7) // 8) * F32_BYTES
    hidden_branch = chunk_capacity * hidden * F32_BYTES
    materialized_total = (
        common_payload + materialized_q + materialized_scale + 3 * hidden_branch
    )
    if variant == BASELINE:
        ledger = {
            "chunk_capacity": chunk_capacity,
            "capsule_rows": 0,
            "tile_rows": 0,
            "task_slots": 0,
            "common_payload_bytes": common_payload,
            "gate_bytes": hidden_branch,
            "up_bytes": hidden_branch,
            "silu_bytes": hidden_branch,
            "q_scratch_bytes": materialized_q,
            "scale_scratch_bytes": materialized_scale,
            "pair_q8_bytes": 0,
            "pair_scale_bytes": 0,
            "gate_tile_bytes": 0,
            "up_tile_bytes": 0,
            "tensor_payload_bytes": materialized_total,
            "materialized_counterfactual_bytes": materialized_total,
            "reclaimed_tensor_payload_bytes": 0,
            "logical_slices": 16,
        }
    else:
        requested = 32 if variant == "compact-32-required" else 64
        bounded = min(requested, chunk_capacity)
        capsule_rows = bounded if bounded <= 3 else (bounded // 4) * 4
        if capsule_rows <= 0 or hidden < COMPACT_TILE_ROWS:
            raise HarnessError("compact Pair prefill geometry is inadmissible")
        q_scratch = chunk_capacity * dim
        scale_scratch = chunk_capacity * max_producer_scale_stride * F32_BYTES
        pair_q8 = capsule_rows * hidden
        pair_scale = capsule_rows * pair_scale_stride * F32_BYTES
        tile_bytes = threads * capsule_rows * COMPACT_TILE_ROWS * F32_BYTES
        compact_total = (
            common_payload
            + q_scratch
            + scale_scratch
            + pair_q8
            + pair_scale
            + 2 * tile_bytes
        )
        if compact_total > materialized_total:
            raise HarnessError("compact Pair prefill ledger exceeds materialized")
        ledger = {
            "chunk_capacity": chunk_capacity,
            "capsule_rows": capsule_rows,
            "tile_rows": COMPACT_TILE_ROWS,
            "task_slots": threads,
            "common_payload_bytes": common_payload,
            "gate_bytes": 0,
            "up_bytes": 0,
            "silu_bytes": 0,
            "q_scratch_bytes": q_scratch,
            "scale_scratch_bytes": scale_scratch,
            "pair_q8_bytes": pair_q8,
            "pair_scale_bytes": pair_scale,
            "gate_tile_bytes": tile_bytes,
            "up_tile_bytes": tile_bytes,
            "tensor_payload_bytes": compact_total,
            "materialized_counterfactual_bytes": materialized_total,
            "reclaimed_tensor_payload_bytes": materialized_total - compact_total,
            "logical_slices": 17,
        }
    for name, value in ledger.items():
        _checked_evidence_int(value, f"Pair prefill ledger {name}")
    return ledger


def _validate_canonical_int4_record(
    record: Any, *, layer: int, kind: int, out_f: int, in_f: int
) -> None:
    elements = out_f * in_f
    lengths = tuple(length for _, length in record.ranges)
    expected_scale_bytes = elements // record.group_size * 2
    if (
        record.role != _pair.GLRT_ROLE_TENSOR
        or record.layer_idx != layer
        or record.kind != kind
        or record.encoding != _pair.GLRT_ENCODING_INT4
        or record.packed_layout != _pair.GLRT_PACKED_ROWS4_K16
        or record.pair_nibble_layout != _pair.GLRT_PAIR_NONE
        or record.flags != 0
        or record.group_size not in (8, 16)
        or record.out_f != out_f
        or record.in_f != in_f
        or record.num_elements != elements
        or elements % record.group_size != 0
        or lengths != (elements // 2, 0, 0, expected_scale_bytes, 0)
    ):
        raise HarnessError(
            f"Pair prefill GLRT layer {layer} kind {kind} is not canonical INT4 rows4/K16"
        )


def derive_pair_prefill_model_manifest(
    model: Path,
    *,
    model_sha256: str,
    prompt_tokens: int,
    threads: int,
) -> dict[str, Any]:
    """Derive all three frame ledgers from one immutable Pair GLRT."""
    if SHA256_RE.fullmatch(model_sha256) is None:
        raise HarnessError("Pair prefill model SHA-256 is malformed")
    before = _attention.fingerprint(model, "Pair prefill GLRT", model_sha256)
    frame_manifest = _frame.derive_pair_model_manifest(model, model_sha256=model_sha256)
    image = _pair.parse_glrt_image(model, "Pair prefill GLRT")
    after = _attention.fingerprint(model, "Pair prefill GLRT", model_sha256)
    if before["identity"] != after["identity"] or before["sha256"] != after["sha256"]:
        raise HarnessError("Pair GLRT changed while deriving prefill geometry")

    frame_geometry, frame_ledger = _frame._validated_frame_ledger(frame_manifest)
    dim = int(frame_geometry["dim"])
    hidden = int(frame_geometry["hidden_dim"])
    kv_dim = int(frame_geometry["kv_dim"])
    layers = int(frame_geometry["layers"])
    by_identity = {record.identity(): record for record in image.records}

    producer_g8 = 0
    producer_g16 = 0
    max_producer_scale_stride = 0
    producer_records: list[dict[str, Any]] = []
    common_records: list[dict[str, Any]] = []
    for layer in range(layers):
        pair = by_identity.get(("role", layer, _pair.GLRT_ROLE_PAIR))
        if pair is None:
            raise HarnessError(f"Pair prefill GLRT is missing producer layer {layer}")
        _pair._require_pair_record(pair, layer=layer, config=image.header.config)
        max_producer_scale_stride = max(
            max_producer_scale_stride,
            _activation_scale_count(dim, pair.group_size),
        )
        if pair.group_size == 8:
            producer_g8 += 1
        elif pair.group_size == 16:
            producer_g16 += 1
        producer_records.append(
            {
                "layer": layer,
                "group_size": pair.group_size,
                "activation_scale_count": _activation_scale_count(dim, pair.group_size),
                "canonical_descriptor_sha256": pair.canonical_descriptor_sha256,
                "payload_concat_sha256": pair.payload_concat_sha256,
            }
        )

        expected_out = {1: dim, 2: kv_dim, 3: kv_dim, 4: dim}
        for kind in GLRT_ATTN_KINDS:
            record = by_identity.get(("tensor", layer, kind))
            if record is None:
                raise HarnessError(
                    f"Pair prefill GLRT is missing layer {layer} tensor kind {kind}"
                )
            _validate_canonical_int4_record(
                record,
                layer=layer,
                kind=kind,
                out_f=expected_out[kind],
                in_f=dim,
            )
            scale_count = _activation_scale_count(dim, record.group_size)
            max_producer_scale_stride = max(max_producer_scale_stride, scale_count)
            common_records.append(
                {
                    "layer": layer,
                    "kind": kind,
                    "group_size": record.group_size,
                    "activation_scale_count": scale_count,
                    "canonical_descriptor_sha256": record.canonical_descriptor_sha256,
                    "payload_concat_sha256": record.payload_concat_sha256,
                }
            )

    if producer_g8 + producer_g16 != layers:
        raise HarnessError("Pair producer group coverage is incomplete")
    down_records = frame_manifest["down_records"]
    pair_scale_stride = max(
        int(record["activation_scale_count"]) for record in down_records
    )
    ledgers = {
        variant: _derive_prefill_ledger(
            variant=variant,
            prompt_tokens=prompt_tokens,
            threads=threads,
            dim=dim,
            kv_dim=kv_dim,
            hidden=hidden,
            max_producer_scale_stride=max_producer_scale_stride,
            pair_scale_stride=pair_scale_stride,
        )
        for variant in (BASELINE, *CANDIDATES)
    }
    manifest = {
        "schema": MODEL_MANIFEST_SCHEMA,
        "model_sha256": model_sha256,
        "glrt_manifest_sha256": image.manifest_sha256,
        "frame_manifest": frame_manifest,
        "frame_manifest_sha256": frame_manifest["manifest_sha256"],
        "geometry": {
            "dim": dim,
            "hidden_dim": hidden,
            "kv_dim": kv_dim,
            "layers": layers,
            "prompt_tokens": prompt_tokens,
            "threads": threads,
            "chunk_rows": PREFILL_CHUNK_ROWS,
            "compact_tile_rows": COMPACT_TILE_ROWS,
            "max_producer_scale_stride": max_producer_scale_stride,
            "pair_scale_stride": pair_scale_stride,
        },
        "producer_group_counts": {"g8": producer_g8, "g16": producer_g16},
        "down_group_counts": {
            "g8": int(frame_ledger["down_g8_layers"]),
            "g16": int(frame_ledger["down_g16_layers"]),
        },
        "producer_records": producer_records,
        "common_projection_records": common_records,
        "prefill_ledgers": ledgers,
        "claims": {
            "strict_glrt_v2_verified": True,
            "exactly_one_pair_producer_per_layer": True,
            "separate_gate_up_records_absent": True,
            "all_batch_projection_records_int4_rows4_k16": True,
            "logical_payload_excludes_allocator_metadata_and_os_residency": True,
            "depth_independent_request_arena": True,
        },
    }
    return _with_manifest_hash(manifest)


def _validated_prefill_manifest(
    manifest: Mapping[str, Any],
) -> tuple[dict[str, int], dict[str, int], dict[str, Mapping[str, int]]]:
    _validate_manifest_hash(
        manifest, MODEL_MANIFEST_SCHEMA, "Pair prefill model manifest"
    )
    geometry_value = manifest.get("geometry")
    producers_value = manifest.get("producer_group_counts")
    down_value = manifest.get("down_group_counts")
    ledgers_value = manifest.get("prefill_ledgers")
    frame_manifest = manifest.get("frame_manifest")
    producer_records = manifest.get("producer_records")
    common_records = manifest.get("common_projection_records")
    if (
        not isinstance(geometry_value, Mapping)
        or not isinstance(producers_value, Mapping)
        or not isinstance(down_value, Mapping)
        or not isinstance(ledgers_value, Mapping)
        or not isinstance(frame_manifest, Mapping)
        or not isinstance(producer_records, list)
        or not isinstance(common_records, list)
    ):
        raise HarnessError("Pair prefill model manifest is incomplete")
    frame_geometry, frame_ledger = _frame._validated_frame_ledger(frame_manifest)
    if manifest.get("frame_manifest_sha256") != frame_manifest.get("manifest_sha256"):
        raise HarnessError("Pair prefill frame-manifest binding mismatch")
    for name in ("model_sha256", "glrt_manifest_sha256"):
        digest = manifest.get(name)
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"Pair prefill manifest {name} is malformed")
    if frame_manifest.get("model_sha256") not in (None, manifest["model_sha256"]):
        raise HarnessError("Pair prefill model/frame digest binding mismatch")

    geometry_names = (
        "dim",
        "hidden_dim",
        "kv_dim",
        "layers",
        "prompt_tokens",
        "threads",
        "chunk_rows",
        "compact_tile_rows",
        "max_producer_scale_stride",
        "pair_scale_stride",
    )
    geometry = {
        name: _checked_evidence_int(
            geometry_value.get(name), f"Pair prefill geometry {name}", positive=True
        )
        for name in geometry_names
    }
    if (
        geometry["chunk_rows"] != PREFILL_CHUNK_ROWS
        or geometry["compact_tile_rows"] != COMPACT_TILE_ROWS
    ):
        raise HarnessError("Pair prefill manifest topology constants changed")
    for outer, inner in (
        ("dim", "dim"),
        ("hidden_dim", "hidden_dim"),
        ("kv_dim", "kv_dim"),
        ("layers", "layers"),
    ):
        if geometry[outer] != int(frame_geometry[inner]):
            raise HarnessError("Pair prefill/frame geometry binding mismatch")
    groups: dict[str, int] = {}
    for prefix, source in (("producer", producers_value), ("down", down_value)):
        for group in ("g8", "g16"):
            groups[f"{prefix}_{group}"] = _checked_evidence_int(
                source.get(group), f"{prefix} {group} layers"
            )
    if (
        groups["producer_g8"] + groups["producer_g16"] != geometry["layers"]
        or groups["down_g8"] + groups["down_g16"] != geometry["layers"]
    ):
        raise HarnessError("Pair prefill manifest group coverage is incomplete")
    if groups["down_g8"] != int(frame_ledger["down_g8_layers"]) or groups[
        "down_g16"
    ] != int(frame_ledger["down_g16_layers"]):
        raise HarnessError("Pair prefill/frame down-group binding mismatch")

    if len(producer_records) != geometry["layers"]:
        raise HarnessError("Pair prefill producer-record coverage is incomplete")
    seen_producer_layers: set[int] = set()
    observed_producer_groups = {8: 0, 16: 0}
    observed_max_stride = 0
    for item in producer_records:
        if not isinstance(item, Mapping):
            raise HarnessError("Pair prefill producer record is malformed")
        layer = item.get("layer")
        group_size = item.get("group_size")
        scale_count = item.get("activation_scale_count")
        if (
            isinstance(layer, bool)
            or not isinstance(layer, int)
            or not 0 <= layer < geometry["layers"]
            or layer in seen_producer_layers
            or group_size not in (8, 16)
            or scale_count != _activation_scale_count(geometry["dim"], group_size)
        ):
            raise HarnessError("Pair prefill producer record geometry is invalid")
        for digest_name in (
            "canonical_descriptor_sha256",
            "payload_concat_sha256",
        ):
            digest = item.get(digest_name)
            if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
                raise HarnessError("Pair prefill producer record digest is malformed")
        seen_producer_layers.add(layer)
        observed_producer_groups[group_size] += 1
        observed_max_stride = max(observed_max_stride, int(scale_count))
    if (
        observed_producer_groups[8] != groups["producer_g8"]
        or observed_producer_groups[16] != groups["producer_g16"]
    ):
        raise HarnessError("Pair prefill producer record groups disagree")

    if len(common_records) != geometry["layers"] * len(GLRT_ATTN_KINDS):
        raise HarnessError("Pair prefill common-projection coverage is incomplete")
    seen_common: set[tuple[int, int]] = set()
    for item in common_records:
        if not isinstance(item, Mapping):
            raise HarnessError("Pair prefill common projection record is malformed")
        layer = item.get("layer")
        kind = item.get("kind")
        group_size = item.get("group_size")
        scale_count = item.get("activation_scale_count")
        identity = (layer, kind)
        if (
            isinstance(layer, bool)
            or not isinstance(layer, int)
            or not 0 <= layer < geometry["layers"]
            or kind not in GLRT_ATTN_KINDS
            or identity in seen_common
            or group_size not in (8, 16)
            or scale_count != _activation_scale_count(geometry["dim"], group_size)
        ):
            raise HarnessError("Pair prefill common projection geometry is invalid")
        for digest_name in (
            "canonical_descriptor_sha256",
            "payload_concat_sha256",
        ):
            digest = item.get(digest_name)
            if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
                raise HarnessError("Pair prefill common projection digest is malformed")
        seen_common.add(identity)
        observed_max_stride = max(observed_max_stride, int(scale_count))
    if observed_max_stride != geometry["max_producer_scale_stride"]:
        raise HarnessError("Pair prefill producer scale-stride ledger disagrees")

    frame_down_records = frame_manifest.get("down_records")
    if (
        not isinstance(frame_down_records, list)
        or len(frame_down_records) != geometry["layers"]
    ):
        raise HarnessError("Pair prefill frame down-record coverage is incomplete")
    observed_pair_scale_stride = max(
        _checked_evidence_int(
            item.get("activation_scale_count") if isinstance(item, Mapping) else None,
            "Pair prefill down activation scale count",
            positive=True,
        )
        for item in frame_down_records
    )
    if observed_pair_scale_stride != geometry["pair_scale_stride"]:
        raise HarnessError("Pair prefill down scale-stride ledger disagrees")

    expected_ledgers = {
        variant: _derive_prefill_ledger(
            variant=variant,
            prompt_tokens=geometry["prompt_tokens"],
            threads=geometry["threads"],
            dim=geometry["dim"],
            kv_dim=geometry["kv_dim"],
            hidden=geometry["hidden_dim"],
            max_producer_scale_stride=geometry["max_producer_scale_stride"],
            pair_scale_stride=geometry["pair_scale_stride"],
        )
        for variant in (BASELINE, *CANDIDATES)
    }
    normalized: dict[str, Mapping[str, int]] = {}
    for variant, expected in expected_ledgers.items():
        declared = ledgers_value.get(variant)
        if not isinstance(declared, Mapping) or dict(declared) != expected:
            raise HarnessError(f"Pair prefill {variant} manifest ledger is invalid")
        normalized[variant] = expected
    return geometry, groups, normalized


def _provenance_string(value: Any, where: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or any(ord(char) < 0x20 for char in value)
    ):
        raise HarnessError(f"frozen provenance {where} must be a printable string")
    return value


def _provenance_sha256(value: Any, where: str) -> str:
    digest = _provenance_string(value, where)
    if SHA256_RE.fullmatch(digest) is None or digest == "0" * 64:
        raise HarnessError(f"frozen provenance {where} must be a nonzero SHA-256")
    return digest


def _load_frozen_prompt_provenance(
    config: Config,
    prompt_ids: Sequence[int],
    artifacts: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    """Validate the selected prompt against the immutable provenance artifact."""
    try:
        raw = config.provenance.read_bytes()
        value = json.loads(raw.decode("utf-8", errors="strict"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HarnessError(f"cannot read frozen prompt provenance: {error}") from error
    if not isinstance(value, Mapping):
        raise HarnessError("frozen prompt provenance root must be an object")
    if value.get("schema") != FROZEN_PROVENANCE_SCHEMA:
        raise HarnessError("frozen prompt provenance schema mismatch")
    if value.get("serialization") != (
        "ASCII decimal u32 IDs separated by one space and terminated by LF"
    ):
        raise HarnessError("frozen prompt provenance serialization mismatch")

    source = value.get("source")
    tokenizer = value.get("tokenizer")
    prefixes = value.get("prefixes")
    if not isinstance(source, Mapping) or not isinstance(tokenizer, Mapping):
        raise HarnessError("frozen prompt provenance source/tokenizer is malformed")
    if not isinstance(prefixes, list) or len(prefixes) != len(PROMPT_PROFILES):
        raise HarnessError("frozen prompt provenance must declare all prompt profiles")

    if source.get("kind") != "git-blob":
        raise HarnessError("frozen prompt provenance source must be a git blob")
    source_commit = _provenance_string(source.get("commit"), "source commit")
    if re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
        raise HarnessError(
            "frozen provenance source commit must be 40 lowercase hex digits"
        )
    source_path = _provenance_string(source.get("path"), "source path")
    if Path(source_path).is_absolute() or ".." in Path(source_path).parts:
        raise HarnessError("frozen provenance source path must be repository-relative")
    source_bytes = source.get("utf8_bytes")
    if (
        isinstance(source_bytes, bool)
        or not isinstance(source_bytes, int)
        or source_bytes <= 0
    ):
        raise HarnessError("frozen provenance source byte count must be positive")
    source_digest = _provenance_sha256(source.get("sha256"), "source blob SHA-256")
    canonical_source_id = f"git-blob:{source_commit}:{source_path}"
    if config.source_id != canonical_source_id or config.source_sha256 != source_digest:
        raise HarnessError("CLI source provenance disagrees with frozen manifest")

    tokenizer_id = _provenance_string(tokenizer.get("model"), "tokenizer model")
    tokenizer_artifact = _provenance_string(
        tokenizer.get("artifact"), "tokenizer artifact"
    )
    tokenizer_digest = _provenance_sha256(
        tokenizer.get("artifact_sha256"), "tokenizer artifact SHA-256"
    )
    if (
        config.tokenizer_id != tokenizer_id
        or config.tokenizer_sha256 != tokenizer_digest
    ):
        raise HarnessError("CLI tokenizer provenance disagrees with frozen manifest")

    indexed: dict[int, Mapping[str, Any]] = {}
    for index, entry in enumerate(prefixes):
        if not isinstance(entry, Mapping):
            raise HarnessError(f"frozen prompt prefix {index} is malformed")
        tokens = entry.get("tokens")
        if isinstance(tokens, bool) or not isinstance(tokens, int) or tokens <= 0:
            raise HarnessError(f"frozen prompt prefix {index} token count is invalid")
        if tokens in indexed:
            raise HarnessError("frozen prompt provenance has duplicate token counts")
        indexed[tokens] = entry
    if set(indexed) != set(PROMPT_PROFILES.values()):
        raise HarnessError("frozen prompt provenance profile set mismatch")

    expected_tokens = PROMPT_PROFILES[config.prompt_profile]
    selected = indexed[expected_tokens]
    prefix_path_text = _provenance_string(selected.get("path"), "prefix path")
    prefix_path = Path(prefix_path_text)
    if prefix_path.is_absolute() or ".." in prefix_path.parts:
        raise HarnessError("frozen provenance prefix path must be repository-relative")
    if (config.cwd / prefix_path).resolve() != config.ids.resolve():
        raise HarnessError("selected IDs path disagrees with frozen provenance")
    prefix_digest = _provenance_sha256(selected.get("sha256"), "prefix SHA-256")
    if prefix_digest != artifacts["prompt_ids"]["sha256"]:
        raise HarnessError("selected IDs bytes disagree with frozen provenance")

    normalized = canonical_ids_bytes(prompt_ids)
    if sha256_bytes(normalized) != prefix_digest:
        raise HarnessError("selected IDs are not the frozen canonical serialization")
    provenance_digest = artifacts["frozen_prompt_provenance"]["sha256"]
    if sha256_bytes(raw) != provenance_digest:
        raise HarnessError("frozen provenance bytes disagree with artifact fingerprint")

    return {
        "schema": FROZEN_PROVENANCE_SCHEMA,
        "artifact_sha256": provenance_digest,
        "selected_prefix": {
            "profile": config.prompt_profile,
            "tokens": expected_tokens,
            "path": prefix_path_text,
            "raw_ids_sha256": prefix_digest,
            "normalized_ids_sha256": sha256_bytes(normalized),
        },
        "source": {
            "kind": "git-blob",
            "id": canonical_source_id,
            "commit": source_commit,
            "path": source_path,
            "utf8_bytes": source_bytes,
            "blob_sha256": source_digest,
        },
        "tokenizer": {
            "id": tokenizer_id,
            "artifact": tokenizer_artifact,
            "artifact_sha256": tokenizer_digest,
        },
    }


def derive_prompt_manifest(
    config: Config,
    prompt_ids: Sequence[int],
    artifacts: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    expected_count = PROMPT_PROFILES.get(config.prompt_profile)
    if expected_count is None or len(prompt_ids) != expected_count:
        raise HarnessError(
            f"{config.prompt_profile} requires exactly {expected_count} prompt IDs"
        )
    normalized = canonical_ids_bytes(prompt_ids)
    frozen = _load_frozen_prompt_provenance(config, prompt_ids, artifacts)
    manifest = {
        "schema": PROMPT_MANIFEST_SCHEMA,
        "profile": config.prompt_profile,
        "token_count": len(prompt_ids),
        "ids_file_sha256": artifacts["prompt_ids"]["sha256"],
        "normalized_ids_sha256": sha256_bytes(normalized),
        "frozen_provenance": frozen,
        "frozen_provenance_sha256": frozen["artifact_sha256"],
        "source": frozen["source"],
        "tokenizer": frozen["tokenizer"],
        "claims": {
            "frozen_provenance_artifact_validated": True,
            "natural_prompt_provenance_validated": True,
            "tokenizer_provenance_validated": True,
            "profile_path_raw_sha_and_count_validated": True,
            "token_order_and_multiplicity_hashed": True,
        },
    }
    return _with_manifest_hash(manifest)


def build_campaign_manifest(
    config: Config,
    artifacts: Mapping[str, Mapping[str, Any]],
    prompt_manifest: Mapping[str, Any],
    model_manifest: Mapping[str, Any],
) -> dict[str, Any]:
    manifest = {
        "schema": CAMPAIGN_MANIFEST_SCHEMA,
        "campaign": config.campaign,
        "profile": config.prompt_profile,
        "candidate": config.candidate,
        "binary_sha256": artifacts["binary"]["sha256"],
        "model_sha256": artifacts["pair_model"]["sha256"],
        "prompt_manifest_sha256": prompt_manifest["manifest_sha256"],
        "model_manifest_sha256": model_manifest["manifest_sha256"],
        "schedule_seed": config.schedule_seed,
        "bootstrap_seed": config.bootstrap_seed,
        "bootstrap_resamples": config.bootstrap_resamples,
        "confidence": config.confidence,
        "samples_per_variant": config.samples_per_variant,
        "warmups_per_variant": config.warmups_per_variant,
        "threads": config.threads,
        "new_tokens": 1,
        "graph_ci_min": config.graph_ci_min,
    }
    return _with_manifest_hash(manifest)


def build_patterns(samples_per_variant: int, seed: int) -> list[str]:
    return _attention.build_patterns(samples_per_variant, seed)


def percentile(values: Sequence[float], probability: float) -> float:
    return _attention.percentile(values, probability)


def paired_ratio(
    samples: Sequence[Mapping[str, Any]],
    field: str,
    *,
    candidate: str,
    resamples: int,
    seed: int,
    confidence: float,
) -> dict[str, Any]:
    if candidate not in CANDIDATES:
        raise HarnessError(f"unknown compact candidate: {candidate}")
    arms = (BASELINE, candidate)
    blocks: dict[int, dict[str, list[float]]] = {}
    for sample in samples:
        value = sample["metrics"].get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HarnessError(f"metric {field} is missing or not numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or numeric <= 0:
            raise HarnessError(f"metric {field} must be finite and positive")
        variant = str(sample.get("variant"))
        if variant not in arms:
            raise HarnessError(f"unknown variant in paired sample: {variant}")
        block = blocks.setdefault(int(sample["block_index"]), {arm: [] for arm in arms})
        block[variant].append(numeric)
    ordered = [blocks[index] for index in sorted(blocks)]
    if not ordered or any(len(block[arm]) != 2 for block in ordered for arm in arms):
        raise HarnessError(
            "paired bootstrap requires two observations per arm per block"
        )

    def ratio(selected: Sequence[Mapping[str, Sequence[float]]]) -> float:
        baseline = [value for block in selected for value in block[BASELINE]]
        compact = [value for block in selected for value in block[candidate]]
        return statistics.median(baseline) / statistics.median(compact)

    field_seed = int.from_bytes(
        hashlib.sha256(field.encode("ascii")).digest()[:8], "big"
    )
    effective_seed = seed ^ field_seed
    rng = random.Random(effective_seed)
    bootstrap = [
        ratio([ordered[rng.randrange(len(ordered))] for _ in ordered])
        for _ in range(resamples)
    ]
    tail = (1.0 - confidence) / 2.0
    return {
        "direction": (
            f"{BASELINE}_over_{candidate}; greater than 1 favors {candidate}"
        ),
        "estimate": ratio(ordered),
        "confidence": confidence,
        "ci_low": percentile(bootstrap, tail),
        "ci_high": percentile(bootstrap, 1.0 - tail),
        "bootstrap_unit": "complete_balanced_abba_or_baab_block",
        "bootstrap_resamples": resamples,
        "bootstrap_seed": seed,
        "bootstrap_field_seed": field_seed,
        "effective_bootstrap_seed": effective_seed,
    }


def _exactly_one_valid(
    output: str, prefix: str, expression: re.Pattern[str], where: str
) -> re.Match[str]:
    return _frame._exactly_one_valid(output, prefix, expression, where)


def _counter(value: str, where: str) -> int:
    return _frame._counter(value, where)


def _finite_nonnegative(value: str, where: str) -> float:
    return _frame._finite_nonnegative(value, where)


def _pair_tile_rows(participants: int, group_size: int) -> int:
    if group_size not in (8, 16) or not 1 <= participants <= 8:
        raise HarnessError("Pair scratch geometry is outside the certified domain")
    if participants == 1 or participants in (7, 8):
        return 256
    if participants in (2, 3):
        return 32 if group_size == 8 else 64
    return 64 if group_size == 8 else 128


def _runtime_prefill_counts(
    *, prompt_tokens: int, layers: int, capsule_rows: int
) -> dict[str, int]:
    remaining = prompt_tokens
    chunk_capacity = min(prompt_tokens, PREFILL_CHUNK_ROWS)
    chunk_count = 0
    full_chunks = 0
    tail_chunks = 0
    capsules_per_layer = 0
    while remaining:
        rows = min(chunk_capacity, remaining)
        chunk_count += 1
        if rows == chunk_capacity:
            full_chunks += 1
        else:
            tail_chunks += 1
        if capsule_rows:
            capsules_per_layer += (rows + capsule_rows - 1) // capsule_rows
        remaining -= rows
    layer_uses = chunk_count * layers
    pair_rows = prompt_tokens * layers
    return {
        "chunk_count": chunk_count,
        "full_chunks": full_chunks,
        "tail_chunks": tail_chunks,
        "peak_active_rows": chunk_capacity,
        "layer_uses": layer_uses,
        "capsules": capsules_per_layer * layers,
        "pair_rows": pair_rows,
    }


def parse_telemetry(
    output: str,
    *,
    variant: str,
    prompt_tokens: int,
    threads: int,
    expected_model_manifest: Mapping[str, Any],
) -> dict[str, Any]:
    if variant not in (BASELINE, *CANDIDATES):
        raise HarnessError(f"unknown Pair prefill variant: {variant}")
    geometry, groups, ledgers = _validated_prefill_manifest(expected_model_manifest)
    if prompt_tokens != geometry["prompt_tokens"] or threads != geometry["threads"]:
        raise HarnessError(
            "runtime invocation differs from the pinned prefill manifest"
        )
    frame_manifest = expected_model_manifest["frame_manifest"]
    frame_geometry, frame_ledger = _frame._validated_frame_ledger(frame_manifest)

    load = _exactly_one_valid(output, "load:", _attention._LOAD_RE, "load")
    ready = _exactly_one_valid(output, "ready:", _attention._READY_RE, "request-ready")
    schedule = _exactly_one_valid(
        output, "schedule:", _attention._SCHEDULE_RE, "schedule"
    )
    phases = _exactly_one_valid(output, "phases:", _attention._PHASES_RE, "phase")
    prefill_phase = _exactly_one_valid(
        output, "prefill_phase:", _PREFILL_PHASE_RE, "prefill-phase"
    )
    pair = _exactly_one_valid(output, "pair_nibble:", _PAIR_NIBBLE_RE, "PairNibble")
    decode_frame = _exactly_one_valid(
        output, "decode_frame:", _DECODE_FRAME_RE, "decode-frame"
    )
    scratch = _exactly_one_valid(
        output, "pair_scratch:", _PAIR_SCRATCH_RE, "Pair scratch"
    )
    prefill_frame = _exactly_one_valid(
        output,
        "pair_prefill_frame:",
        _PAIR_PREFILL_FRAME_RE,
        "Pair prefill frame",
    )
    plan = _exactly_one_valid(output, "decode_plan:", _DECODE_PLAN_RE, "DecodePlan")
    greedy = _exactly_one_valid(
        output, "greedy_output:", _GREEDY_OUTPUT_RE, "greedy-output"
    )
    total = _exactly_one_valid(output, "time:", _TOTAL_RE, "total-time")

    if load.group(1).lower() != "prepared" or load.group(2).lower() != "glrt":
        raise HarnessError("run did not report a prepared GLRT load")
    if schedule.group(1).lower() != "serial" or schedule.group(2) is not None:
        raise HarnessError("Pair prefill A/B requires explicit serial attention")
    layers = _counter(schedule.group(3), "layer count")
    if layers != geometry["layers"] or layers != int(frame_geometry["layers"]):
        raise HarnessError("runtime layer count differs from the pinned Pair GLRT")
    if int(total.group(3)) != prompt_tokens or total.group(4).lower() != "batch":
        raise HarnessError("run did not report the exact batch-prefill prompt")

    prefill_ms = _finite_nonnegative(phases.group(1), "prefill_ms")
    decode_ms = _finite_nonnegative(phases.group(2), "decode_ms")
    sampling_ms = _finite_nonnegative(phases.group(3), "sampling_ms")
    decode_runs = _counter(phases.group(4), "decode graph count")
    phase_counters = tuple(
        _counter(phases.group(index), "phase counter") for index in range(5, 13)
    )
    if decode_runs != 0 or decode_ms != 0 or any(phase_counters):
        raise HarnessError(
            "prefill-only evidence requires zero decode/attention/handoff counters"
        )
    graph_ms = _finite_nonnegative(prefill_phase.group(1), "prefill graph_ms")
    first_head_ms = _finite_nonnegative(prefill_phase.group(2), "prefill first_head_ms")
    prefill_phase_abi = int(prefill_phase.group(3), 16)
    if (
        graph_ms <= 0
        or first_head_ms <= 0
        or prefill_phase_abi != PREFILL_PHASE_ABI
        or abs(prefill_ms - graph_ms - first_head_ms) > 0.0016
    ):
        raise HarnessError("prefill phase split or ABI is invalid")

    plan_counters = tuple(
        _counter(plan.group(index), "DecodePlan counter") for index in range(2, 10)
    )
    plan_build_ms = _finite_nonnegative(plan.group(10), "DecodePlan build_ms")
    plan_abi = int(plan.group(11), 16)
    if (
        plan.group(1).lower() != "checked"
        or any(plan_counters)
        or plan_build_ms != 0
        or plan_abi == 0
        or plan_abi > MAX_U64
    ):
        raise HarnessError("prefill A/B requires an idle checked DecodePlan")

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
    if (
        greedy.group(1).lower() != "materialized"
        or greedy.group(12).lower() != GREEDY_ARGMAX_ABI
        or greedy_counters["materialized_projections"] != 1
        or greedy_counters["materialized_logits_bytes"] <= 0
        or any(
            greedy_counters[name]
            for name in greedy_names
            if name not in ("materialized_projections", "materialized_logits_bytes")
        )
    ):
        raise HarnessError("prefill A/B requires one materialized first head")

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
    storage_abi = int(pair.group(23), 16)
    executor_abi = int(pair.group(24), 16)
    if (
        tuple(pair.group(index).lower() for index in (1, 2, 3))
        != ("pair-nibble-required", "pair-nibble", "pair-nibble")
        or storage_abi != PAIR_NIBBLE_STORAGE_ABI
        or executor_abi != PAIR_NIBBLE_EXECUTOR_ABI
        or pair_counters["admissions"] != 1
        or pair_counters["artifact_layers"] != layers
        or pair_counters["selected_layers"] != layers
        or pair_counters["pair_weight_bytes"] <= 0
        or pair_counters["pair_scale_bytes"] <= 0
        or pair_counters["separate_gate_bytes"] != 0
        or pair_counters["separate_up_bytes"] != 0
    ):
        raise HarnessError("PairNibble admission/artifact receipt is invalid")
    expected_pair = _pair._expected_pair_coverage(
        prompt_tokens=prompt_tokens,
        new_tokens=1,
        layers=layers,
        prefill="batch",
    )
    if {name: pair_counters[name] for name in expected_pair} != expected_pair:
        raise HarnessError("PairNibble prefill coverage is incomplete")
    if pair_counters["fallbacks"] or pair_counters["rejects"]:
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
        name: _counter(decode_frame.group(index), f"decode-frame {name}")
        for index, name in enumerate(frame_names, start=3)
    }
    expected_decode_frame = {
        "materialized_uses": 0,
        "compact_pair_uses": 1,
        "tensor_payload_bytes": int(frame_ledger["compact_pair_tensor_payload_bytes"]),
        "materialized_counterfactual_bytes": int(
            frame_ledger["materialized_tensor_payload_bytes"]
        ),
        "reclaimed_tensor_payload_bytes": int(
            frame_ledger["reclaimed_tensor_payload_bytes"]
        ),
        "pair_q8_bytes": int(frame_ledger["pair_q8_bytes"]),
        "pair_scale_bytes": int(frame_ledger["pair_scale_bytes"]),
        "down_g8_layers": groups["down_g8"],
        "down_g16_layers": groups["down_g16"],
    }
    if (
        decode_frame.group(1).lower() != "compact-pair-required"
        or decode_frame.group(2).lower() != "pair-q8"
        or int(decode_frame.group(12), 16) != PAIR_DECODE_FRAME_ABI
        or frame_counters != expected_decode_frame
    ):
        raise HarnessError("compact decode-frame receipt changed between prefill arms")

    scratch_names = (
        "participants",
        "producer_g8_layers",
        "producer_g16_layers",
        "selected_g8_rows",
        "selected_g16_rows",
        "capacity_rows",
        "arrays_per_participant",
        "branch_stride_rows",
        "participant_stride_rows",
        "f32_elements",
        "bytes",
        "fixed_counterfactual_bytes",
        "reclaimed_bytes",
        "allocations",
        "fixed_dispatches",
        "model_shaped_dispatches",
        "fallbacks",
        "rejects",
    )
    scratch_counters = {
        name: _counter(scratch.group(index), f"Pair scratch {name}")
        for index, name in enumerate(scratch_names, start=4)
    }
    selected_g8_rows = _pair_tile_rows(threads, 8) if groups["producer_g8"] else 0
    selected_g16_rows = _pair_tile_rows(threads, 16) if groups["producer_g16"] else 0
    participant_stride = SCRATCH_ARRAYS_PER_PARTICIPANT * FIXED_SCRATCH_CAPACITY_ROWS
    scratch_elements = threads * participant_stride
    expected_scratch = {
        "participants": threads,
        "producer_g8_layers": groups["producer_g8"],
        "producer_g16_layers": groups["producer_g16"],
        "selected_g8_rows": selected_g8_rows,
        "selected_g16_rows": selected_g16_rows,
        "capacity_rows": FIXED_SCRATCH_CAPACITY_ROWS,
        "arrays_per_participant": SCRATCH_ARRAYS_PER_PARTICIPANT,
        "branch_stride_rows": FIXED_SCRATCH_CAPACITY_ROWS,
        "participant_stride_rows": participant_stride,
        "f32_elements": scratch_elements,
        "bytes": scratch_elements * F32_BYTES,
        "fixed_counterfactual_bytes": scratch_elements * F32_BYTES,
        "reclaimed_bytes": 0,
        "allocations": 1,
        "fixed_dispatches": 0,
        "model_shaped_dispatches": 0,
        "fallbacks": 0,
        "rejects": 0,
    }
    if (
        scratch.group(1).lower() != "fixed-256-required"
        or scratch.group(2).lower() != "fixed-256"
        or scratch.group(3).lower() != "executor-private-f32"
        or int(scratch.group(22), 16) != PAIR_SCRATCH_ABI
        or scratch_counters != expected_scratch
    ):
        raise HarnessError("fixed Pair scratch receipt changed between prefill arms")

    prefill_names = (
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
    prefill_counters = {
        name: _counter(prefill_frame.group(index), f"Pair prefill {name}")
        for index, name in enumerate(prefill_names, start=2)
    }
    ledger = dict(ledgers[variant])
    runtime = _runtime_prefill_counts(
        prompt_tokens=prompt_tokens,
        layers=layers,
        capsule_rows=ledger["capsule_rows"],
    )
    selected_policy = {
        BASELINE: "materialized",
        "compact-32-required": "compact-32",
        "compact-64-required": "compact-64",
    }[variant]
    expected_prefill = {
        "producer_g8_layers": groups["producer_g8"],
        "producer_g16_layers": groups["producer_g16"],
        "down_g8_layers": groups["down_g8"],
        "down_g16_layers": groups["down_g16"],
        **ledger,
        "chunk_count": runtime["chunk_count"],
        "full_chunks": runtime["full_chunks"],
        "tail_chunks": runtime["tail_chunks"],
        "peak_active_rows": runtime["peak_active_rows"],
        "materialized_layer_uses": (
            runtime["layer_uses"] if variant == BASELINE else 0
        ),
        "compact_layer_uses": (0 if variant == BASELINE else runtime["layer_uses"]),
        "capsules": 0 if variant == BASELINE else runtime["capsules"],
        "pair_input_rows": runtime["pair_rows"],
        "pair_output_rows": runtime["pair_rows"],
        "prepared_down_rows": (0 if variant == BASELINE else runtime["pair_rows"]),
        "prepared_down_dispatches": (0 if variant == BASELINE else runtime["capsules"]),
        "arena_sets": 1,
        "fallbacks": 0,
        "rejects": 0,
    }
    if set(expected_prefill) != set(prefill_counters):
        raise HarnessError("internal Pair prefill parser field set drifted")
    if (
        prefill_frame.group(1).lower() != selected_policy
        or int(prefill_frame.group(38), 16) != PAIR_PREFILL_FRAME_ABI
        or prefill_counters != expected_prefill
    ):
        raise HarnessError(
            f"{variant} Pair prefill runtime receipt differs from its pinned ledger"
        )

    metrics: dict[str, Any] = {
        "load_ms": _finite_nonnegative(load.group(3), "load_ms"),
        "request_ready_ms": _finite_nonnegative(ready.group(1), "request_ready_ms"),
        "prefill_ms": prefill_ms,
        "prefill_graph_ms": graph_ms,
        "first_head_ms": first_head_ms,
        "decode_ms": decode_ms,
        "sampling_ms": sampling_ms,
        "decode_runs": decode_runs,
        "layers": layers,
        "internal_ms": _finite_nonnegative(total.group(1), "internal_ms"),
        "internal_tokens_per_second": _finite_nonnegative(
            total.group(2), "internal_tokens_per_second"
        ),
        "prefill_mode": "batch",
        "pair_nibble_policy": pair.group(1).lower(),
        "pair_nibble_artifact": pair.group(2).lower(),
        "pair_nibble_selected": pair.group(3).lower(),
        "pair_nibble_storage_abi": f"{storage_abi:016x}",
        "pair_nibble_executor_abi": f"{executor_abi:016x}",
        "decode_frame_policy": decode_frame.group(1).lower(),
        "decode_frame_layout": decode_frame.group(2).lower(),
        "decode_frame_abi": f"{PAIR_DECODE_FRAME_ABI:016x}",
        "pair_scratch_policy": scratch.group(1).lower(),
        "pair_scratch_selected": scratch.group(2).lower(),
        "pair_scratch_abi": f"{PAIR_SCRATCH_ABI:016x}",
        "pair_prefill_selected_policy": prefill_frame.group(1).lower(),
        "pair_prefill_frame_abi": f"{PAIR_PREFILL_FRAME_ABI:016x}",
        "prefill_phase_abi": f"{PREFILL_PHASE_ABI:016x}",
        "decode_plan_abi": f"{plan_abi:016x}",
        "greedy_output_mode": "materialized",
        "greedy_output_abi": GREEDY_ARGMAX_ABI,
        "pair_nibble_line_sha256": sha256_bytes(pair.group(0).strip().encode("ascii")),
        "decode_frame_line_sha256": sha256_bytes(
            decode_frame.group(0).strip().encode("ascii")
        ),
        "pair_scratch_line_sha256": sha256_bytes(
            scratch.group(0).strip().encode("ascii")
        ),
        "pair_prefill_frame_line_sha256": sha256_bytes(
            prefill_frame.group(0).strip().encode("ascii")
        ),
        "prefill_phase_line_sha256": sha256_bytes(
            prefill_phase.group(0).strip().encode("ascii")
        ),
    }
    metrics.update(
        {f"pair_nibble_{name}": value for name, value in pair_counters.items()}
    )
    metrics.update(
        {f"decode_frame_{name}": value for name, value in frame_counters.items()}
    )
    metrics.update(
        {f"pair_scratch_{name}": value for name, value in scratch_counters.items()}
    )
    metrics.update(
        {f"pair_prefill_{name}": value for name, value in prefill_counters.items()}
    )
    metrics.update({f"greedy_{name}": value for name, value in greedy_counters.items()})
    if (
        metrics["prefill_ms"] <= 0
        or metrics["prefill_graph_ms"] <= 0
        or metrics["first_head_ms"] <= 0
        or metrics["internal_ms"] <= 0
    ):
        raise HarnessError("prefill-only timings must be positive")
    # The CLI prints tok/s with one decimal place.  A valid one-token PP2048
    # process taking at least 20 seconds is therefore reported as 0.0 tok/s.
    # Keep that display-floor value as a descriptive median only; the shared
    # relation validator below still proves that its rounding interval overlaps
    # the positive throughput implied by the completion count and internal_ms.
    resource = _resource_support()
    resource._validate_telemetry_precision(output)
    metrics.update(
        resource._validate_internal_metric_relations(metrics, completion_tokens=1)
    )
    return metrics


def build_command(config: Config, variant: str, completion_path: Path) -> list[str]:
    if variant not in variants(config):
        raise HarnessError(f"unknown Pair prefill arm: {variant}")
    return [
        str(config.binary),
        "generate",
        str(config.model),
        "--ids-file",
        str(config.ids),
        "--n",
        "1",
        "--threads",
        "4",
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
        "--require-batch-prefill",
        "--serial-attention",
        "--decode-plan",
        "checked",
        "--greedy-output",
        "materialized",
        "--mlp-layout",
        "pair-nibble-required",
        "--decode-frame",
        "compact-pair-required",
        "--pair-scratch",
        "fixed-256-required",
        "--pair-prefill-frame",
        variant,
        "--out-ids-file",
        str(completion_path),
    ]


def _assert_command_isolation(config: Config) -> None:
    marker = config.cwd / "pair-prefill-command-isolation.ids"
    baseline = build_command(config, BASELINE, marker)
    candidate = build_command(config, config.candidate, marker)
    differences = [
        index
        for index, (left, right) in enumerate(zip(baseline, candidate))
        if left != right
    ]
    if len(baseline) != len(candidate) or len(differences) != 1:
        raise HarnessError("Pair prefill A/B commands differ outside one policy")
    index = differences[0]
    if index == 0 or baseline[index - 1] != "--pair-prefill-frame":
        raise HarnessError("Pair prefill command isolation is malformed")


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
            b"pair_prefill_frame:",
            b"prefill_phase:",
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
        raise HarnessError("Glacier did not create the completion-ID file")
    try:
        completion_raw = completion_path.read_bytes()
    except OSError as error:
        raise HarnessError(f"cannot read completion IDs: {error}") from error
    completion_ids = parse_ids(completion_raw, "completion output")
    if len(completion_ids) != 1:
        raise HarnessError(
            f"completion output had {len(completion_ids)} IDs, expected exactly one"
        )
    metrics = parse_telemetry(
        process["telemetry_text"],
        variant=variant,
        prompt_tokens=len(prompt_ids),
        threads=config.threads,
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
            raise HarnessError("time did not create the resource record")
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
        metrics.update(resources)
        metrics.update(
            resource._validate_metric_relations(
                metrics,
                resources,
                completion_tokens=1,
                harness_wall_seconds=harness_wall_seconds,
            )
        )
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
    if config.threads != 4:
        raise HarnessError("Pair prefill evidence requires exactly four threads")
    if config.prompt_profile not in PROMPT_PROFILES:
        raise HarnessError("prompt profile must be p128, p512, or p2048")
    if config.campaign not in CAMPAIGNS:
        raise HarnessError("campaign must be primary or replication")
    variants(config)
    if not 100 <= config.bootstrap_resamples <= 1_000_000:
        raise HarnessError("bootstrap resamples must be in [100, 1000000]")
    if not 0 <= config.schedule_seed <= MAX_I64:
        raise HarnessError("schedule seed must be in the signed int64 range")
    if not 0 <= config.bootstrap_seed <= MAX_I64:
        raise HarnessError("bootstrap seed must be in the signed int64 range")
    if not 0.5 <= config.confidence <= 0.999:
        raise HarnessError("confidence must be in [0.5, 0.999]")
    if not math.isfinite(config.graph_ci_min) or config.graph_ci_min < 1.0:
        raise HarnessError("graph CI promotion threshold must be finite and >= 1")
    if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
        raise HarnessError("timeout must be finite and positive")
    if not config.cwd.is_dir():
        raise HarnessError(f"cwd is not a directory: {config.cwd}")
    for name, value in (
        ("source ID", config.source_id),
        ("tokenizer ID", config.tokenizer_id),
    ):
        if not value or any(ord(char) < 0x20 for char in value):
            raise HarnessError(f"{name} must be a non-empty printable string")
    for name, digest in (
        ("source provenance", config.source_sha256),
        ("tokenizer provenance", config.tokenizer_sha256),
        ("binary", config.binary_sha256),
        ("Pair model", config.model_sha256),
        ("IDs", config.ids_sha256),
        ("frozen provenance", config.provenance_sha256),
        ("time", config.time_sha256),
    ):
        if digest is not None and SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"{name} SHA-256 must be 64 lowercase hex digits")
    if config.source_sha256 == "0" * 64 or config.tokenizer_sha256 == "0" * 64:
        raise HarnessError("provenance SHA-256 values must not be all zero")
    if config.provenance_sha256 is None:
        raise HarnessError("frozen provenance SHA-256 must be pinned")

    resource_path = Path(_resource_support().__file__).resolve()
    input_paths = {
        config.binary,
        config.model,
        config.ids,
        config.provenance,
        Path(__file__).resolve(),
        Path(_frame.__file__).resolve(),
        Path(_pair.__file__).resolve(),
        Path(_attention.__file__).resolve(),
        resource_path,
    }
    expected_paths = 9
    if config.darwin_resources:
        configured_paths = {
            "binary": config.binary,
            "Pair model": config.model,
            "IDs": config.ids,
            "frozen provenance": config.provenance,
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
            raise HarnessError("resource evidence requires Darwin /usr/bin/time")
        if not os.access(config.time_binary, os.X_OK):
            raise HarnessError(f"time binary is not executable: {config.time_binary}")
        input_paths.add(config.time_binary)
        expected_paths += 1
    if len(input_paths) != expected_paths:
        raise HarnessError(
            "binary, model, IDs, provenance, drivers, supports, and time must be distinct files"
        )
    if config.output is not None and config.output in input_paths:
        raise HarnessError("result output must not replace an input artifact")
    _assert_command_isolation(config)


def _common_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    prefixes = (
        "pair_nibble_",
        "decode_frame_",
        "pair_scratch_",
        "greedy_",
    )
    excluded = {
        "pair_nibble_line_sha256",
        "decode_frame_line_sha256",
        "pair_scratch_line_sha256",
    }
    names = sorted(
        name
        for name in metrics
        if name not in excluded and any(name.startswith(prefix) for prefix in prefixes)
    )
    return tuple((name, metrics[name]) for name in names)


def _prefill_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    names = sorted(
        name
        for name in metrics
        if name.startswith("pair_prefill_") and name != "pair_prefill_frame_line_sha256"
    )
    return tuple((name, metrics[name]) for name in names)


def _resource_promotion_gate(
    *,
    profile: str,
    darwin_resources: bool,
    ratios: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    memory_minimum = 1.0 if profile in ("p512", "p2048") else 1.0 / 1.01
    requirements = {
        **{field: 1.0 for field in CPU_RESOURCE_PROMOTION_FIELDS},
        **{field: memory_minimum for field in MEMORY_RESOURCE_PROMOTION_FIELDS},
    }
    observed: dict[str, Any] = {}
    passed = darwin_resources
    for field, minimum in requirements.items():
        interval = ratios.get(field)
        if not darwin_resources or not isinstance(interval, Mapping):
            observed[field] = {
                "status": "not-measured",
                "required_materialized_over_compact_ci_low": minimum,
            }
            passed = False
            continue
        ci_low = interval.get("ci_low")
        field_passed = (
            not isinstance(ci_low, bool)
            and isinstance(ci_low, (int, float))
            and math.isfinite(float(ci_low))
            and float(ci_low) >= minimum
        )
        observed[field] = {
            "status": "passed" if field_passed else "failed",
            "required_materialized_over_compact_ci_low": minimum,
            "observed": interval,
        }
        passed = passed and field_passed
    return {
        "status": "passed" if passed else "failed",
        "required_darwin_resources": True,
        "ratio_direction": ("materialized_over_compact; greater than 1 favors compact"),
        "profile_memory_policy": (
            "p512/p2048 require no upper-confidence memory regression; "
            "p128 permits at most 1% candidate upper-confidence growth"
        ),
        "fields": observed,
    }


def _publication_campaign_gate(config: Config, *, binary_bytes: int) -> dict[str, Any]:
    registered_seeds = CAMPAIGN_SEEDS[config.campaign]
    hashes_pinned = all(
        digest is not None
        for digest in (
            config.binary_sha256,
            config.model_sha256,
            config.ids_sha256,
            config.provenance_sha256,
            config.time_sha256,
        )
    )
    checks = {
        "samples_per_variant": (
            config.samples_per_variant == DEFAULT_SAMPLES_PER_VARIANT
        ),
        "warmups_per_variant": (
            config.warmups_per_variant == DEFAULT_WARMUPS_PER_VARIANT
        ),
        "bootstrap_resamples": (
            config.bootstrap_resamples == DEFAULT_BOOTSTRAP_RESAMPLES
        ),
        "registered_schedule_seed": (
            config.schedule_seed == registered_seeds["schedule"]
        ),
        "registered_bootstrap_seed": (
            config.bootstrap_seed == registered_seeds["bootstrap"]
        ),
        "confidence": config.confidence == PUBLICATION_CONFIDENCE,
        "graph_ci_min": config.graph_ci_min == DEFAULT_GRAPH_CI_MIN,
        "darwin_resources": config.darwin_resources,
        "all_artifact_hashes_pinned": hashes_pinned,
        "production_binary_size": (
            not isinstance(binary_bytes, bool)
            and isinstance(binary_bytes, int)
            and binary_bytes <= PRODUCTION_BINARY_SIZE_MAX_BYTES
        ),
    }
    return {
        "status": "passed" if all(checks.values()) else "failed",
        "required_samples_per_variant": DEFAULT_SAMPLES_PER_VARIANT,
        "required_warmups_per_variant": DEFAULT_WARMUPS_PER_VARIANT,
        "required_bootstrap_resamples": DEFAULT_BOOTSTRAP_RESAMPLES,
        "required_schedule_seed": registered_seeds["schedule"],
        "required_bootstrap_seed": registered_seeds["bootstrap"],
        "required_confidence": PUBLICATION_CONFIDENCE,
        "required_graph_ci_min": DEFAULT_GRAPH_CI_MIN,
        "required_darwin_resources": True,
        "required_binary_size_max_bytes": PRODUCTION_BINARY_SIZE_MAX_BYTES,
        "observed_binary_size_bytes": binary_bytes,
        "required_pinned_hashes": [
            "binary",
            "model",
            "IDs",
            "frozen provenance",
            "Darwin time binary",
        ],
        "checks": checks,
    }


def _production_binary_size_gate(
    artifacts: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    binary_bytes = artifacts["binary"].get("bytes")
    if isinstance(binary_bytes, bool) or not isinstance(binary_bytes, int):
        raise HarnessError("binary artifact fingerprint is missing its byte count")
    return {
        "status": (
            "passed" if binary_bytes <= PRODUCTION_BINARY_SIZE_MAX_BYTES else "failed"
        ),
        "required_maximum_bytes": PRODUCTION_BINARY_SIZE_MAX_BYTES,
        "observed_bytes": binary_bytes,
    }


def run_benchmark(config: Config) -> dict[str, Any]:
    validate_config(config)
    artifact_before = fingerprint_artifacts(config)
    _attention.assert_artifact_identities(artifact_before)
    try:
        prompt_ids = parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise HarnessError(f"cannot read prompt IDs: {error}") from error
    prompt_manifest = derive_prompt_manifest(config, prompt_ids, artifact_before)
    model_manifest = derive_pair_prefill_model_manifest(
        config.model,
        model_sha256=str(artifact_before["pair_model"]["sha256"]),
        prompt_tokens=len(prompt_ids),
        threads=config.threads,
    )
    geometry, groups, ledgers = _validated_prefill_manifest(model_manifest)
    campaign_manifest = build_campaign_manifest(
        config, artifact_before, prompt_manifest, model_manifest
    )
    _validate_manifest_hash(
        campaign_manifest, CAMPAIGN_MANIFEST_SCHEMA, "Pair prefill campaign manifest"
    )
    _attention.assert_artifact_identities(artifact_before)

    patterns = build_patterns(config.samples_per_variant, config.schedule_seed)
    arms = variants(config)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    common_signature: tuple[Any, ...] | None = None
    prefill_signatures: dict[str, tuple[Any, ...]] = {}
    with tempfile.TemporaryDirectory(
        prefix="glacier-pair-prefill-frame-ab."
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
            nonlocal reference_ids, common_signature
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
                    "exact completion ID changed at "
                    f"{'warmup' if warmup else 'sample'} {sequence_index}"
                )
            observed_common = _common_signature(item["metrics"])
            if common_signature is None:
                common_signature = observed_common
            elif observed_common != common_signature:
                raise HarnessError(
                    "Pair/decode-frame/scratch/greedy receipt changed between arms"
                )
            observed_prefill = _prefill_signature(item["metrics"])
            if variant not in prefill_signatures:
                prefill_signatures[variant] = observed_prefill
            elif prefill_signatures[variant] != observed_prefill:
                raise HarnessError(f"{variant} prefill receipt changed during A/B")
            return item

        warmup_order = list(arms)
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
                variant = config.candidate if letter == "A" else BASELINE
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
    assert common_signature is not None
    baseline_ledger = dict(ledgers[BASELINE])
    candidate_ledger = dict(ledgers[config.candidate])
    baseline_bytes = baseline_ledger["tensor_payload_bytes"]
    candidate_bytes = candidate_ledger["tensor_payload_bytes"]
    reclaimed = candidate_ledger["reclaimed_tensor_payload_bytes"]
    if (
        baseline_ledger["materialized_counterfactual_bytes"] != baseline_bytes
        or candidate_ledger["materialized_counterfactual_bytes"] != baseline_bytes
        or reclaimed != baseline_bytes - candidate_bytes
    ):
        raise HarnessError("cross-arm Pair prefill logical-byte ledger is invalid")

    ratio_fields = (
        "prefill_graph_ms",
        "prefill_ms",
        "first_head_ms",
        "internal_ms",
        "harness_wall_ms",
        *(RESOURCE_RATIO_FIELDS if config.darwin_resources else ()),
    )
    ratios = {
        field: paired_ratio(
            samples,
            field,
            candidate=config.candidate,
            resamples=config.bootstrap_resamples,
            seed=config.bootstrap_seed,
            confidence=config.confidence,
        )
        for field in ratio_fields
    }
    median_fields = (
        "load_ms",
        "request_ready_ms",
        "prefill_graph_ms",
        "first_head_ms",
        "prefill_ms",
        "sampling_ms",
        "internal_ms",
        "internal_tokens_per_second",
        "harness_wall_ms",
        *(RESOURCE_MEDIAN_FIELDS if config.darwin_resources else ()),
    )
    medians = {
        arm: {
            field: statistics.median(
                float(sample["metrics"][field])
                for sample in samples
                if sample["variant"] == arm
            )
            for field in median_fields
        }
        for arm in arms
    }

    payload_reduction = reclaimed / baseline_bytes
    graph_interval = ratios["prefill_graph_ms"]
    binary_size_gate = _production_binary_size_gate(artifact_before)
    publication_gate = _publication_campaign_gate(
        config, binary_bytes=int(binary_size_gate["observed_bytes"])
    )
    resource_gate = _resource_promotion_gate(
        profile=config.prompt_profile,
        darwin_resources=config.darwin_resources,
        ratios=ratios,
    )
    gates = {
        "evidence_exactness": {
            "status": "passed",
            "requirement": (
                "same artifacts/prompt; exact completion; exact ABI, coverage, "
                "ledger, and zero fallback/reject receipts"
            ),
        },
        "logical_payload_reduction": {
            "status": "passed" if payload_reduction >= 0.50 else "failed",
            "required_minimum_fraction": 0.50,
            "observed_fraction": payload_reduction,
            "baseline_bytes": baseline_bytes,
            "candidate_bytes": candidate_bytes,
        },
        "prefill_graph_time": {
            "status": (
                "passed"
                if float(graph_interval["ci_low"]) >= config.graph_ci_min
                else "failed"
            ),
            "required_materialized_over_compact_ci_low": config.graph_ci_min,
            "observed": graph_interval,
        },
        "auto_prefill_graph_time": {
            "status": (
                "passed"
                if float(graph_interval["ci_low"]) >= AUTO_GRAPH_CI_MIN
                else "failed"
            ),
            "required_materialized_over_compact_ci_low": AUTO_GRAPH_CI_MIN,
            "observed": graph_interval,
        },
        "production_binary_size": binary_size_gate,
        "physical_resource_efficiency": resource_gate,
        "publication_campaign_shape": publication_gate,
    }
    shared_gate_names = (
        "evidence_exactness",
        "logical_payload_reduction",
        "production_binary_size",
        "physical_resource_efficiency",
        "publication_campaign_shape",
    )
    strict_cell_passed = all(
        gates[name]["status"] == "passed"
        for name in (*shared_gate_names, "prefill_graph_time")
    )
    auto_cell_passed = (
        config.candidate == DEFAULT_CANDIDATE
        and all(gates[name]["status"] == "passed" for name in shared_gate_names)
        and gates["auto_prefill_graph_time"]["status"] == "passed"
    )
    gates["strict_cell_status"] = "passed" if strict_cell_passed else "failed"
    gates["auto_cell_status"] = "passed" if auto_cell_passed else "failed"
    gates["auto_matrix_status"] = "incomplete"
    gates["scope"] = "one prompt-profile/campaign matrix cell"
    gates["matrix_complete"] = False
    gates["matrix_note"] = (
        "global auto-promotion requires independent passing primary and "
        "replication results for p128, p512, and p2048"
    )

    capture_contract = _resource_support()._process_output_capture_contract()
    capture_contract["raw_reserved_prefix_guard"]["additional_prefixes"] = [
        "pair_nibble:",
        "decode_frame:",
        "pair_scratch:",
        "pair_prefill_frame:",
        "prefill_phase:",
    ]
    logical_ledger = {
        "baseline": baseline_ledger,
        "candidate": candidate_ledger,
        "materialized_over_compact_payload_ratio": baseline_bytes / candidate_bytes,
        "payload_reduction_fraction": payload_reduction,
        "exact_counterfactual_relation_verified": True,
        "runtime_matches_glrt_derived_manifest": True,
        "logical_payload_not_physical_residency": True,
    }
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "evidence-valid",
        # A single result is one of six required cells and can never promote
        # auto-selection by itself.
        "promotion_status": "incomplete",
        "strict_cell_status": "passed" if strict_cell_passed else "failed",
        "auto_cell_status": "passed" if auto_cell_passed else "failed",
        "auto_matrix_status": "incomplete",
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "logical_cpu_count": os.cpu_count(),
            "python": sys.version,
        },
        "process_output_capture_contract": capture_contract,
        "contract": {
            "profile": config.prompt_profile,
            "campaign": config.campaign,
            "matrix_profiles": list(PROMPT_PROFILES),
            "matrix_campaigns": list(CAMPAIGNS),
            "samples_per_variant": config.samples_per_variant,
            "warmups_per_variant": config.warmups_per_variant,
            "prompt_tokens": len(prompt_ids),
            "new_tokens": 1,
            "threads": config.threads,
            "prefill": "batch-required",
            "attention": "serial-required",
            "variants": list(arms),
            "strict_pair_nibble_required": True,
            "strict_compact_decode_frame_required": True,
            "strict_fixed_256_pair_scratch_required": True,
            "strict_checked_decode_plan_required": True,
            "strict_materialized_greedy_output_required": True,
            "zero_decode_graphs_required": True,
            "zero_fallbacks_rejects_and_sealed_dispatches_required": True,
            "same_binary_model_prompt_required": True,
            "commands_differ_only_by_pair_prefill_policy": True,
            "exact_completion_id_required_across_all_invocations": True,
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule": "balanced ABBA/BAAB blocks",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": config.candidate, "B": BASELINE},
            "bootstrap_seed": config.bootstrap_seed,
            "bootstrap_resamples": config.bootstrap_resamples,
            "confidence": config.confidence,
            "pair_nibble_storage_abi": f"{PAIR_NIBBLE_STORAGE_ABI:016x}",
            "pair_nibble_executor_abi": f"{PAIR_NIBBLE_EXECUTOR_ABI:016x}",
            "pair_decode_frame_abi": f"{PAIR_DECODE_FRAME_ABI:016x}",
            "pair_scratch_abi": f"{PAIR_SCRATCH_ABI:016x}",
            "pair_prefill_frame_abi": f"{PAIR_PREFILL_FRAME_ABI:016x}",
            "prefill_phase_abi": f"{PREFILL_PHASE_ABI:016x}",
            "darwin_resource_mode": config.darwin_resources,
            "publishable_resource_measurements": config.darwin_resources,
        },
        "prompt_manifest": prompt_manifest,
        "prompt_manifest_sha256": prompt_manifest["manifest_sha256"],
        "model_manifest": model_manifest,
        "model_manifest_sha256": model_manifest["manifest_sha256"],
        "campaign_manifest": campaign_manifest,
        "campaign_manifest_sha256": campaign_manifest["manifest_sha256"],
        "artifacts_before": artifact_before,
        "artifacts_after": artifact_after,
        "completion_equivalence": {
            "exact_ids_match": True,
            "token_count": 1,
            "token_ids": reference_ids,
            "normalized_sha256": sha256_bytes(canonical_ids_bytes(reference_ids)),
            "distinct_normalized_hashes": sorted(
                {item["completion_ids_sha256"] for item in [*warmups, *samples]}
            ),
        },
        "logical_pair_prefill_frame_byte_ledger": logical_ledger,
        "warmups": warmups,
        "samples": samples,
        "medians": medians,
        "materialized_over_compact": ratios,
        "promotion_gates": gates,
        "resource_evidence": {
            "enabled": config.darwin_resources,
            "measurements_publishable": config.darwin_resources,
            "required_platform_and_timer": "Darwin /usr/bin/time",
            "units": RESOURCE_UNITS if config.darwin_resources else {},
            "paired_ratio_fields": (
                list(RESOURCE_RATIO_FIELDS) if config.darwin_resources else []
            ),
        },
        "geometry_summary": {**geometry, **groups},
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
            "Run one provenance-pinned p128/p512/p2048 primary or replication "
            "Pair batch-prefill frame A/B matrix cell."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument(
        "--model", "--pair-model", dest="model", type=Path, required=True
    )
    parser.add_argument("--ids", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument(
        "--profile",
        dest="prompt_profile",
        choices=tuple(PROMPT_PROFILES),
        required=True,
    )
    parser.add_argument("--campaign", choices=CAMPAIGNS, required=True)
    parser.add_argument("--candidate", choices=CANDIDATES, default=DEFAULT_CANDIDATE)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--tokenizer-id", required=True)
    parser.add_argument("--tokenizer-sha256", required=True)
    parser.add_argument("-o", "--output", required=True, help="result JSON path or '-'")
    parser.add_argument("--cwd", type=Path, default=repo_root)
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
    parser.add_argument("--schedule-seed", type=_nonnegative_int)
    parser.add_argument("--bootstrap-seed", type=_nonnegative_int)
    parser.add_argument(
        "--bootstrap-resamples",
        type=_positive_int,
        default=DEFAULT_BOOTSTRAP_RESAMPLES,
    )
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument("--graph-ci-min", type=float, default=DEFAULT_GRAPH_CI_MIN)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument("--darwin-resources", action="store_true")
    parser.add_argument("--time-binary", type=Path, default=Path("/usr/bin/time"))
    parser.add_argument("--binary-sha256")
    parser.add_argument("--model-sha256", "--pair-model-sha256", dest="model_sha256")
    parser.add_argument("--ids-sha256")
    parser.add_argument("--provenance-sha256", required=True)
    parser.add_argument("--time-sha256")
    parser.add_argument("--overwrite", action="store_true")
    return parser


def config_from_args(args: argparse.Namespace) -> Config:
    seeds = CAMPAIGN_SEEDS[args.campaign]
    output = None if args.output == "-" else Path(args.output).expanduser().resolve()
    return Config(
        binary=args.binary.expanduser().resolve(),
        model=args.model.expanduser().resolve(),
        ids=args.ids.expanduser().resolve(),
        provenance=args.provenance.expanduser().resolve(),
        output=output,
        cwd=args.cwd.expanduser().resolve(),
        prompt_profile=args.prompt_profile,
        campaign=args.campaign,
        candidate=args.candidate,
        source_id=args.source_id,
        source_sha256=args.source_sha256,
        tokenizer_id=args.tokenizer_id,
        tokenizer_sha256=args.tokenizer_sha256,
        samples_per_variant=args.samples_per_variant,
        warmups_per_variant=args.warmups_per_variant,
        threads=4,
        schedule_seed=(
            seeds["schedule"] if args.schedule_seed is None else args.schedule_seed
        ),
        bootstrap_seed=(
            seeds["bootstrap"] if args.bootstrap_seed is None else args.bootstrap_seed
        ),
        bootstrap_resamples=args.bootstrap_resamples,
        confidence=args.confidence,
        graph_ci_min=args.graph_ci_min,
        timeout_seconds=args.timeout_seconds,
        overwrite=args.overwrite,
        binary_sha256=args.binary_sha256,
        model_sha256=args.model_sha256,
        ids_sha256=args.ids_sha256,
        provenance_sha256=args.provenance_sha256,
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
