#!/usr/bin/env python3
"""Strict same-binary/same-Pair-GLRT private scratch A/B evidence harness.

Both arms require the compact Pair decode frame and execute the same prepared
PairNibble artifact.  The only execution-policy difference is the capacity of
the executor-private two-branch f32 tile arena: the control reserves 256 rows
per branch and participant, while the candidate reserves the largest row tile
required by the admitted Pair producer group.  Every observation is a fresh
process in a balanced ABBA/BAAB block and must preserve exact completion IDs,
Pair coverage, frame bytes, and a GLRT-derived scratch receipt.

The byte ledger is logical executor allocation evidence.  It is deliberately
kept separate from whole-process RSS and footprint measurements.
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
    """Load the sibling frame harness without trusting ``sys.path``."""
    module_name = "_glacier_pair_scratch_frame_support"
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

SCHEMA = "glacier.pair-scratch-ab/result-v1"
SCRATCH_MANIFEST_SCHEMA = "glacier.pair-scratch/model-manifest-v1"
VARIANTS = ("fixed-256-required", "model-shaped-required")
BASELINE = "fixed-256-required"
CANDIDATE = "model-shaped-required"
DEFAULT_SAMPLES_PER_VARIANT = 32
DEFAULT_WARMUPS_PER_VARIANT = 2
DEFAULT_SCHEDULE_SEED = 20_260_721
DEFAULT_BOOTSTRAP_SEED = 0x5041495253435241
DEFAULT_BOOTSTRAP_RESAMPLES = 100_000
FIXED_CAPACITY_ROWS = 256
ARRAYS_PER_PARTICIPANT = 2
F32_BYTES = 4
SYSTEM_TIME_BINARY = Path("/usr/bin/time").resolve()
MAX_U32 = (1 << 32) - 1
MAX_I64 = (1 << 63) - 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")
PAIR_NIBBLE_STORAGE_ABI = 0x47504E4200000001
PAIR_NIBBLE_EXECUTOR_ABI = 0x47504E4500000005
PAIR_DECODE_FRAME_ABI = 0x47504E4600000001
PAIR_SCRATCH_ABI = 0x47504E5300000001

RESOURCE_RATIO_FIELDS = _frame.RESOURCE_RATIO_FIELDS
RESOURCE_REQUIRED_POSITIVE_FIELDS = _frame.RESOURCE_REQUIRED_POSITIVE_FIELDS
RESOURCE_MEDIAN_FIELDS = _frame.RESOURCE_MEDIAN_FIELDS
RESOURCE_UNITS = _frame.RESOURCE_UNITS

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
    return _frame._resource_support()


def fingerprint_artifacts(config: Config) -> dict[str, dict[str, Any]]:
    if not os.access(config.binary, os.X_OK):
        raise HarnessError(f"binary is not executable: {config.binary}")
    if config.model.suffix.lower() != ".glrt":
        raise HarnessError("strict Pair scratch A/B requires a .glrt model path")
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


def pair_tile_rows(participants: int, producer_group_size: int) -> int:
    """Mirror the versioned executor row-ownership table, fail closed."""
    if (
        isinstance(participants, bool)
        or not isinstance(participants, int)
        or isinstance(producer_group_size, bool)
        or not isinstance(producer_group_size, int)
        or producer_group_size not in (8, 16)
        or not 1 <= participants <= 8
    ):
        raise HarnessError("Pair scratch geometry is outside the certified domain")
    if participants == 1 or participants in (7, 8):
        return 256
    if participants in (2, 3):
        return 32 if producer_group_size == 8 else 64
    return 64 if producer_group_size == 8 else 128


def _derive_ledger(
    *,
    participants: int,
    producer_g8_layers: int,
    producer_g16_layers: int,
    variant: str,
) -> dict[str, int]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown Pair scratch variant: {variant}")
    if (
        isinstance(participants, bool)
        or not isinstance(participants, int)
        or participants < 1
        or participants > 8
    ):
        raise HarnessError("Pair scratch participants must be in [1, 8]")
    if (
        isinstance(producer_g8_layers, bool)
        or not isinstance(producer_g8_layers, int)
        or isinstance(producer_g16_layers, bool)
        or not isinstance(producer_g16_layers, int)
        or producer_g8_layers < 0
        or producer_g16_layers < 0
    ):
        raise HarnessError("Pair producer group counts must be non-negative")
    if producer_g8_layers + producer_g16_layers <= 0:
        raise HarnessError("Pair scratch manifest has no producer layers")
    selected_g8_rows = pair_tile_rows(participants, 8) if producer_g8_layers else 0
    selected_g16_rows = pair_tile_rows(participants, 16) if producer_g16_layers else 0
    selected_rows = max(selected_g8_rows, selected_g16_rows)
    capacity_rows = FIXED_CAPACITY_ROWS if variant == BASELINE else selected_rows
    if selected_rows <= 0 or capacity_rows < selected_rows:
        raise HarnessError("Pair scratch capacity is smaller than admitted geometry")
    branch_stride_rows = capacity_rows
    participant_stride_rows = ARRAYS_PER_PARTICIPANT * capacity_rows
    f32_elements = participants * participant_stride_rows
    byte_count = f32_elements * F32_BYTES
    fixed_counterfactual_bytes = (
        participants * ARRAYS_PER_PARTICIPANT * FIXED_CAPACITY_ROWS * F32_BYTES
    )
    if byte_count > fixed_counterfactual_bytes:
        raise HarnessError("Pair scratch ledger exceeds its fixed counterfactual")
    return {
        "participants": participants,
        "selected_g8_rows": selected_g8_rows,
        "selected_g16_rows": selected_g16_rows,
        "capacity_rows": capacity_rows,
        "branch_stride_rows": branch_stride_rows,
        "participant_stride_rows": participant_stride_rows,
        "f32_elements": f32_elements,
        "bytes": byte_count,
        "fixed_counterfactual_bytes": fixed_counterfactual_bytes,
        "reclaimed_bytes": fixed_counterfactual_bytes - byte_count,
    }


def derive_pair_scratch_manifest(
    model: Path, *, model_sha256: str, participants: int
) -> dict[str, Any]:
    """Derive producer groups and both scratch ledgers from one pinned GLRT."""
    if SHA256_RE.fullmatch(model_sha256) is None:
        raise HarnessError("derived Pair model SHA-256 is malformed")
    artifact_before = _attention.fingerprint(model, "Pair scratch GLRT", model_sha256)
    image = _pair.parse_glrt_image(model, "Pair scratch GLRT")
    artifact_after = _attention.fingerprint(model, "Pair scratch GLRT", model_sha256)
    if (
        artifact_before["identity"] != artifact_after["identity"]
        or artifact_before["sha256"] != artifact_after["sha256"]
    ):
        raise HarnessError("Pair GLRT changed while deriving scratch geometry")

    config = image.header.config
    layers = int(config["layers"])
    if layers <= 0:
        raise HarnessError("Pair scratch GLRT has no layers")
    pair_records = [
        record for record in image.records if record.role == _pair.GLRT_ROLE_PAIR
    ]
    if len(pair_records) != layers:
        raise HarnessError(
            "Pair scratch GLRT must contain exactly one Pair producer per layer"
        )
    if any(
        record.role == _pair.GLRT_ROLE_TENSOR
        and record.kind in (_frame.GLRT_MLP_UP_KIND, _frame.GLRT_MLP_GATE_KIND)
        for record in image.records
    ):
        raise HarnessError("Pair scratch GLRT retains forbidden gate/up records")

    by_identity = {record.identity(): record for record in image.records}
    producer_g8_layers = 0
    producer_g16_layers = 0
    producer_records: list[dict[str, Any]] = []
    for layer in range(layers):
        record = by_identity.get(("role", layer, _pair.GLRT_ROLE_PAIR))
        if record is None:
            raise HarnessError(f"Pair scratch GLRT is missing producer layer {layer}")
        _pair._require_pair_record(record, layer=layer, config=config)
        if record.group_size == 8:
            producer_g8_layers += 1
        elif record.group_size == 16:
            producer_g16_layers += 1
        else:
            raise HarnessError(f"Pair producer layer {layer} has a bad group")
        producer_records.append(
            {
                "layer": layer,
                "group_size": record.group_size,
                "canonical_descriptor_sha256": record.canonical_descriptor_sha256,
                "payload_concat_sha256": record.payload_concat_sha256,
            }
        )

    ledgers = {
        variant: _derive_ledger(
            participants=participants,
            producer_g8_layers=producer_g8_layers,
            producer_g16_layers=producer_g16_layers,
            variant=variant,
        )
        for variant in VARIANTS
    }
    manifest: dict[str, Any] = {
        "schema": SCRATCH_MANIFEST_SCHEMA,
        "model_sha256": model_sha256,
        "glrt_manifest_sha256": image.manifest_sha256,
        "participants": participants,
        "layers": layers,
        "producer_group_counts": {
            "g8": producer_g8_layers,
            "g16": producer_g16_layers,
        },
        "producer_records": producer_records,
        "scratch_ledgers": ledgers,
        "claims": {
            "strict_glrt_v2_verified": True,
            "exactly_one_pair_producer_per_layer": True,
            "separate_gate_up_records_absent": True,
            "scratch_geometry_derived_from_pair_producer_groups": True,
            "down_groups_not_used_for_scratch_geometry": True,
            "logical_allocation_bytes_not_os_residency": True,
        },
    }
    manifest["manifest_sha256"] = _frame._canonical_manifest_sha256(manifest)
    return manifest


def _validated_scratch_ledgers(
    manifest: Mapping[str, Any],
) -> tuple[dict[str, int], dict[str, Mapping[str, int]]]:
    if manifest.get("schema") != SCRATCH_MANIFEST_SCHEMA:
        raise HarnessError("Pair scratch model manifest schema mismatch")
    declared_hash = manifest.get("manifest_sha256")
    if not isinstance(declared_hash, str) or SHA256_RE.fullmatch(declared_hash) is None:
        raise HarnessError("Pair scratch model manifest hash is malformed")
    hash_input = dict(manifest)
    hash_input.pop("manifest_sha256", None)
    if _frame._canonical_manifest_sha256(hash_input) != declared_hash:
        raise HarnessError("Pair scratch model manifest hash mismatch")
    model_sha256 = manifest.get("model_sha256")
    if not isinstance(model_sha256, str) or SHA256_RE.fullmatch(model_sha256) is None:
        raise HarnessError("Pair scratch model digest is malformed")
    glrt_manifest_sha256 = manifest.get("glrt_manifest_sha256")
    if (
        not isinstance(glrt_manifest_sha256, str)
        or SHA256_RE.fullmatch(glrt_manifest_sha256) is None
    ):
        raise HarnessError("Pair scratch GLRT manifest digest is malformed")

    scalar_names = ("participants", "layers")
    scalars: dict[str, int] = {}
    for name in scalar_names:
        value = manifest.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise HarnessError(f"Pair scratch manifest field {name} is invalid")
        scalars[name] = value
    if scalars["participants"] > 8:
        raise HarnessError("Pair scratch manifest participants exceed eight")

    groups = manifest.get("producer_group_counts")
    records = manifest.get("producer_records")
    ledgers = manifest.get("scratch_ledgers")
    if (
        not isinstance(groups, Mapping)
        or not isinstance(records, list)
        or not isinstance(ledgers, Mapping)
    ):
        raise HarnessError("Pair scratch manifest is missing producer geometry")
    group_counts: dict[str, int] = {}
    for name in ("g8", "g16"):
        value = groups.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise HarnessError(f"Pair scratch producer count {name} is invalid")
        group_counts[name] = value
    if group_counts["g8"] + group_counts["g16"] != scalars["layers"]:
        raise HarnessError("Pair scratch producer group coverage is incomplete")
    if len(records) != scalars["layers"]:
        raise HarnessError("Pair scratch producer-record coverage is incomplete")
    seen_layers: set[int] = set()
    observed_groups = {"g8": 0, "g16": 0}
    for record_index, item in enumerate(records):
        if not isinstance(item, Mapping):
            raise HarnessError("Pair scratch producer record is malformed")
        layer = item.get("layer")
        group_size = item.get("group_size")
        if (
            isinstance(layer, bool)
            or not isinstance(layer, int)
            or layer < 0
            or layer >= scalars["layers"]
            or layer != record_index
            or layer in seen_layers
            or group_size not in (8, 16)
        ):
            raise HarnessError("Pair scratch producer record geometry is invalid")
        for digest_name in (
            "canonical_descriptor_sha256",
            "payload_concat_sha256",
        ):
            digest = item.get(digest_name)
            if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
                raise HarnessError("Pair scratch producer record digest is malformed")
        seen_layers.add(layer)
        observed_groups["g8" if group_size == 8 else "g16"] += 1
    if observed_groups != group_counts:
        raise HarnessError("Pair scratch group ledger disagrees with producer records")

    expected_ledgers = {
        variant: _derive_ledger(
            participants=scalars["participants"],
            producer_g8_layers=group_counts["g8"],
            producer_g16_layers=group_counts["g16"],
            variant=variant,
        )
        for variant in VARIANTS
    }
    for variant, expected in expected_ledgers.items():
        declared = ledgers.get(variant)
        if not isinstance(declared, Mapping) or any(
            isinstance(value, bool) or not isinstance(value, int) or value < 0
            for value in declared.values()
        ):
            raise HarnessError(f"{variant} Pair scratch ledger is malformed")
        if dict(declared) != expected:
            raise HarnessError(f"{variant} Pair scratch ledger is invalid")
    return (
        {
            **scalars,
            "producer_g8_layers": group_counts["g8"],
            "producer_g16_layers": group_counts["g16"],
        },
        expected_ledgers,
    )


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
        fixed = [value for block in selected for value in block[BASELINE]]
        shaped = [value for block in selected for value in block[CANDIDATE]]
        return statistics.median(fixed) / statistics.median(shaped)

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
            "fixed_256_over_model_shaped; greater than 1 favors model-shaped-required"
        ),
        "estimate": ratio(ordered),
        "confidence": confidence,
        "ci_low": percentile(bootstrap, tail),
        "ci_high": percentile(bootstrap, 1.0 - tail),
        "bootstrap_resamples": resamples,
        "bootstrap_seed": seed,
    }


def _parse_scratch_telemetry(
    output: str,
    *,
    variant: str,
    expected_manifest: Mapping[str, Any],
    expected_dispatches: int,
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown Pair scratch variant: {variant}")
    geometry, ledgers = _validated_scratch_ledgers(expected_manifest)
    match = _frame._exactly_one_valid(
        output,
        "pair_scratch:",
        _PAIR_SCRATCH_RE,
        "Pair scratch",
    )
    names = (
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
    counters = {
        name: _frame._counter(match.group(index), f"Pair scratch {name}")
        for index, name in enumerate(names, start=4)
    }
    abi_value = int(match.group(22), 16)
    selected = "fixed-256" if variant == BASELINE else "model-shaped"
    if (
        match.group(1).lower() != variant
        or match.group(2).lower() != selected
        or match.group(3).lower() != "executor-private-f32"
    ):
        raise HarnessError("Pair scratch policy receipt does not match its arm")
    if abi_value != PAIR_SCRATCH_ABI:
        raise HarnessError(
            "Pair scratch ABI mismatch: "
            f"expected {PAIR_SCRATCH_ABI:016x}, got {abi_value:016x}"
        )
    expected_ledger = dict(ledgers[variant])
    expected_values = {
        **expected_ledger,
        "producer_g8_layers": geometry["producer_g8_layers"],
        "producer_g16_layers": geometry["producer_g16_layers"],
        "arrays_per_participant": ARRAYS_PER_PARTICIPANT,
        "allocations": 1,
        "fixed_dispatches": expected_dispatches if variant == BASELINE else 0,
        "model_shaped_dispatches": (expected_dispatches if variant == CANDIDATE else 0),
        "fallbacks": 0,
        "rejects": 0,
    }
    observed = {name: counters[name] for name in expected_values}
    if observed != expected_values:
        raise HarnessError(
            f"Pair scratch telemetry was {observed}, expected {expected_values}"
        )
    if counters["fixed_dispatches"] + counters["model_shaped_dispatches"] != (
        expected_dispatches
    ):
        raise HarnessError("Pair scratch dispatch coverage is incomplete")
    if (
        counters["branch_stride_rows"] != counters["capacity_rows"]
        or counters["participant_stride_rows"]
        != ARRAYS_PER_PARTICIPANT * counters["capacity_rows"]
        or counters["f32_elements"]
        != counters["participants"] * counters["participant_stride_rows"]
        or counters["bytes"] != F32_BYTES * counters["f32_elements"]
        or counters["fixed_counterfactual_bytes"]
        != counters["participants"]
        * ARRAYS_PER_PARTICIPANT
        * FIXED_CAPACITY_ROWS
        * F32_BYTES
        or counters["reclaimed_bytes"]
        != counters["fixed_counterfactual_bytes"] - counters["bytes"]
    ):
        raise HarnessError("Pair scratch runtime byte arithmetic is inconsistent")
    metrics: dict[str, Any] = {
        "pair_scratch_policy": match.group(1).lower(),
        "pair_scratch_selected": match.group(2).lower(),
        "pair_scratch_layout": match.group(3).lower(),
        "pair_scratch_abi": f"{abi_value:016x}",
        "pair_scratch_line_sha256": sha256_bytes(
            match.group(0).strip().encode("ascii")
        ),
    }
    metrics.update({f"pair_scratch_{name}": value for name, value in counters.items()})
    return metrics


def parse_telemetry(
    output: str,
    *,
    variant: str,
    prompt_tokens: int,
    new_tokens: int,
    prefill: str,
    expected_frame_manifest: Mapping[str, Any],
    expected_scratch_manifest: Mapping[str, Any],
) -> dict[str, Any]:
    metrics = _frame.parse_telemetry(
        output,
        variant="compact-pair-required",
        prompt_tokens=prompt_tokens,
        new_tokens=new_tokens,
        prefill=prefill,
        expected_model_manifest=expected_frame_manifest,
    )
    coverage = _frame._expected_pair_coverage(
        prompt_tokens=prompt_tokens,
        new_tokens=new_tokens,
        layers=int(metrics["layers"]),
        prefill=prefill,
    )
    expected_dispatches = int(coverage["outputless_m1"])
    scratch = _parse_scratch_telemetry(
        output,
        variant=variant,
        expected_manifest=expected_scratch_manifest,
        expected_dispatches=expected_dispatches,
    )
    if int(metrics["pair_nibble_outputless_m1"]) != expected_dispatches:
        raise HarnessError("Pair and scratch dispatch receipts disagree")
    metrics.update(scratch)
    return metrics


def build_command(config: Config, variant: str, completion_path: Path) -> list[str]:
    if variant not in VARIANTS:
        raise HarnessError(f"unknown Pair scratch variant: {variant}")
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
        "compact-pair-required",
        "--pair-scratch",
        variant,
        "--out-ids-file",
        str(completion_path),
        *prefill_policy,
    ]


def _assert_command_isolation(config: Config) -> None:
    marker = config.cwd / "pair-scratch-command-isolation.ids"
    fixed = build_command(config, BASELINE, marker)
    shaped = build_command(config, CANDIDATE, marker)
    differences = [
        index for index, (left, right) in enumerate(zip(fixed, shaped)) if left != right
    ]
    if len(fixed) != len(shaped) or len(differences) != 1:
        raise HarnessError("Pair scratch A/B commands differ outside one policy value")
    index = differences[0]
    if index == 0 or fixed[index - 1] != "--pair-scratch":
        raise HarnessError("Pair scratch command isolation is malformed")


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


def run_variant(
    config: Config,
    variant: str,
    completion_path: Path,
    prompt_ids: Sequence[int],
    artifact_before: Mapping[str, Mapping[str, Any]],
    expected_frame_manifest: Mapping[str, Any],
    expected_scratch_manifest: Mapping[str, Any],
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
            f"completion output had {len(completion_ids)} IDs, "
            f"expected {config.new_tokens}"
        )
    metrics = parse_telemetry(
        process["telemetry_text"],
        variant=variant,
        prompt_tokens=len(prompt_ids),
        new_tokens=config.new_tokens,
        prefill=config.prefill,
        expected_frame_manifest=expected_frame_manifest,
        expected_scratch_manifest=expected_scratch_manifest,
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
        resources = _frame.parse_resource_output(time_text)
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
    _frame.build_patterns(config.samples_per_variant, config.schedule_seed)
    if config.samples_per_variant > 10_000:
        raise HarnessError("samples per variant must not exceed 10000")
    if not 1 <= config.warmups_per_variant <= 100:
        raise HarnessError("warmups per variant must be in [1, 100]")
    if not 2 <= config.new_tokens <= 1_000_000:
        raise HarnessError("Pair scratch A/B new tokens must be in [2, 1000000]")
    if not 1 <= config.threads <= 8:
        raise HarnessError("Pair scratch evidence threads must be in [1, 8]")
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
        Path(_frame.__file__).resolve(),
        Path(_pair.__file__).resolve(),
        Path(_attention.__file__).resolve(),
        resource_path,
    }
    expected_input_paths = 8
    if config.darwin_resources:
        configured_paths = {
            "binary": config.binary,
            "Pair model": config.model,
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
            "binary, Pair model, IDs, drivers, support modules, and time must be distinct files"
        )
    if config.output is not None and config.output in input_paths:
        raise HarnessError("result output must not replace a benchmark input artifact")
    for name, digest in (
        ("binary", config.binary_sha256),
        ("Pair model", config.model_sha256),
        ("IDs", config.ids_sha256),
        ("time", config.time_sha256),
    ):
        if digest is not None and SHA256_RE.fullmatch(digest) is None:
            raise HarnessError(f"{name} SHA-256 pin must be 64 lowercase hex digits")
    _assert_command_isolation(config)


def _common_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    return (
        _frame._pair_signature(metrics),
        _frame._frame_signature(metrics),
        metrics["pair_scratch_participants"],
        metrics["pair_scratch_producer_g8_layers"],
        metrics["pair_scratch_producer_g16_layers"],
        metrics["pair_scratch_selected_g8_rows"],
        metrics["pair_scratch_selected_g16_rows"],
        metrics["pair_scratch_fixed_counterfactual_bytes"],
        metrics["pair_scratch_fixed_dispatches"]
        + metrics["pair_scratch_model_shaped_dispatches"],
        metrics["pair_scratch_abi"],
    )


def _scratch_signature(metrics: Mapping[str, Any]) -> tuple[Any, ...]:
    names = (
        "pair_scratch_policy",
        "pair_scratch_selected",
        "pair_scratch_layout",
        "pair_scratch_participants",
        "pair_scratch_producer_g8_layers",
        "pair_scratch_producer_g16_layers",
        "pair_scratch_selected_g8_rows",
        "pair_scratch_selected_g16_rows",
        "pair_scratch_capacity_rows",
        "pair_scratch_arrays_per_participant",
        "pair_scratch_branch_stride_rows",
        "pair_scratch_participant_stride_rows",
        "pair_scratch_f32_elements",
        "pair_scratch_bytes",
        "pair_scratch_fixed_counterfactual_bytes",
        "pair_scratch_reclaimed_bytes",
        "pair_scratch_allocations",
        "pair_scratch_fixed_dispatches",
        "pair_scratch_model_shaped_dispatches",
        "pair_scratch_fallbacks",
        "pair_scratch_rejects",
        "pair_scratch_abi",
    )
    return tuple(metrics[name] for name in names)


def run_benchmark(config: Config) -> dict[str, Any]:
    validate_config(config)
    artifact_before = fingerprint_artifacts(config)
    _attention.assert_artifact_identities(artifact_before)
    model_sha256 = str(artifact_before["pair_model"]["sha256"])
    frame_manifest = _frame.derive_pair_model_manifest(
        config.model, model_sha256=model_sha256
    )
    scratch_manifest = derive_pair_scratch_manifest(
        config.model,
        model_sha256=model_sha256,
        participants=config.threads,
    )
    expected_geometry, expected_ledgers = _validated_scratch_ledgers(scratch_manifest)
    _, frame_ledger = _frame._validated_frame_ledger(frame_manifest)
    _attention.assert_artifact_identities(artifact_before)
    try:
        prompt_ids = parse_ids(config.ids.read_bytes(), "prompt IDs")
    except OSError as error:
        raise HarnessError(f"cannot read prompt IDs: {error}") from error
    if config.prefill == "batch" and len(prompt_ids) < 8:
        raise HarnessError("batch prefill requires at least eight prompt IDs")

    patterns = _frame.build_patterns(config.samples_per_variant, config.schedule_seed)
    warmups: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    reference_ids: list[int] | None = None
    common_signature: tuple[Any, ...] | None = None
    scratch_signatures: dict[str, tuple[Any, ...]] = {}
    with tempfile.TemporaryDirectory(prefix="glacier-pair-scratch-ab.") as temporary:
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
                frame_manifest,
                scratch_manifest,
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
            observed_common = _common_signature(item["metrics"])
            if common_signature is None:
                common_signature = observed_common
            elif observed_common != common_signature:
                raise HarnessError(
                    "Pair artifact/frame/common scratch geometry changed between arms"
                )
            observed_scratch = _scratch_signature(item["metrics"])
            if variant not in scratch_signatures:
                scratch_signatures[variant] = observed_scratch
            elif scratch_signatures[variant] != observed_scratch:
                raise HarnessError(f"{variant} scratch receipt changed during A/B")
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
                variant = CANDIDATE if letter == "A" else BASELINE
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

    baseline = next(item["metrics"] for item in samples if item["variant"] == BASELINE)
    candidate = next(
        item["metrics"] for item in samples if item["variant"] == CANDIDATE
    )
    baseline_bytes = int(baseline["pair_scratch_bytes"])
    candidate_bytes = int(candidate["pair_scratch_bytes"])
    fixed_counterfactual = int(candidate["pair_scratch_fixed_counterfactual_bytes"])
    reclaimed = int(candidate["pair_scratch_reclaimed_bytes"])
    if (
        baseline_bytes != int(expected_ledgers[BASELINE]["bytes"])
        or candidate_bytes != int(expected_ledgers[CANDIDATE]["bytes"])
        or fixed_counterfactual != baseline_bytes
        or reclaimed != baseline_bytes - candidate_bytes
        or int(baseline["pair_scratch_reclaimed_bytes"]) != 0
    ):
        raise HarnessError("cross-arm Pair scratch byte ledger is inconsistent")

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
    for variant in VARIANTS:
        medians[variant]["decode_phase_tokens_per_second"] = (
            (config.new_tokens - 1) * 1000.0 / medians[variant]["decode_ms"]
        )

    binary_sha256 = str(artifact_before["binary"]["sha256"])
    output_capture_contract = _resource_support()._process_output_capture_contract()
    output_capture_contract["raw_reserved_prefix_guard"]["additional_prefixes"] = [
        "pair_nibble:",
        "decode_frame:",
        "pair_scratch:",
    ]
    compact_frame_bytes = int(frame_ledger["compact_pair_tensor_payload_bytes"])
    logical_ledger = {
        "scope": "maximum concurrent typed compact decode frame plus executor-private Pair tile allocation",
        "physical_memory_claim": False,
        "os_rss_or_footprint_bytes": False,
        "compact_decode_frame_bytes": compact_frame_bytes,
        "fixed_256_scratch_bytes": baseline_bytes,
        "model_shaped_scratch_bytes": candidate_bytes,
        "fixed_counterfactual_bytes": fixed_counterfactual,
        "reclaimed_scratch_bytes": reclaimed,
        "fixed_over_model_shaped_scratch_ratio": (baseline_bytes / candidate_bytes),
        "scratch_reduction_fraction": reclaimed / baseline_bytes,
        "fixed_frame_plus_scratch_bytes": compact_frame_bytes + baseline_bytes,
        "model_shaped_frame_plus_scratch_bytes": compact_frame_bytes + candidate_bytes,
        "runtime_matches_glrt_derived_scratch_manifest": True,
        "producer_group_geometry_not_down_group_geometry": True,
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
            "layers": expected_geometry["layers"],
            "variants": list(VARIANTS),
            "pair_nibble_storage_abi": f"{PAIR_NIBBLE_STORAGE_ABI:016x}",
            "pair_nibble_executor_abi": f"{PAIR_NIBBLE_EXECUTOR_ABI:016x}",
            "pair_decode_frame_abi": f"{PAIR_DECODE_FRAME_ABI:016x}",
            "pair_scratch_abi": f"{PAIR_SCRATCH_ABI:016x}",
            "strict_prepared_pair_glrt_both_arms": True,
            "strict_compact_pair_frame_both_arms": True,
            "strict_pair_scratch_policy_required": True,
            "strict_materialized_greedy_output_required": True,
            "zero_fallbacks_rejects_and_sealed_dispatches_required": True,
            "exact_pair_and_scratch_dispatch_coverage_required": True,
            "exact_completion_ids_required_across_all_invocations": True,
            "same_binary_required": True,
            "same_pair_model_required": True,
            "binary_sha256_by_variant": {
                variant: binary_sha256 for variant in VARIANTS
            },
            "model_sha256_by_variant": {variant: model_sha256 for variant in VARIANTS},
            "derived_frame_manifest": frame_manifest,
            "derived_frame_manifest_sha256": frame_manifest["manifest_sha256"],
            "derived_scratch_manifest": scratch_manifest,
            "derived_scratch_manifest_sha256": scratch_manifest["manifest_sha256"],
            "fresh_process_per_observation": True,
            "cache_regime": "process-cold/os-warm-after-excluded-warmups",
            "schedule_seed": config.schedule_seed,
            "patterns": patterns,
            "letter_mapping": {"A": CANDIDATE, "B": BASELINE},
            "bootstrap_resamples": config.bootstrap_resamples,
            "bootstrap_seed": config.bootstrap_seed,
            "confidence": config.confidence,
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
        "logical_pair_scratch_byte_ledger": logical_ledger,
        "warmups": warmups,
        "samples": samples,
        "medians": medians,
        "fixed_256_over_model_shaped": ratios,
        "resource_evidence": {
            "enabled": config.darwin_resources,
            "measurements_publishable": config.darwin_resources,
            "required_platform_and_timer": "Darwin /usr/bin/time",
            "units": RESOURCE_UNITS if config.darwin_resources else {},
            "paired_ratio_fields": (
                list(RESOURCE_RATIO_FIELDS) if config.darwin_resources else []
            ),
            "logical_scratch_ledger_is_not_physical_memory_evidence": True,
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
            "between fixed-256 and model-shaped private Pair scratch."
        )
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument(
        "--model", "--pair-model", dest="model", type=Path, required=True
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
