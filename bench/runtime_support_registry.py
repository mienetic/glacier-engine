#!/usr/bin/env python3
"""Independent oracle for the retained runtime-support registry.

This module intentionally does not parse Zig sources or load Glacier symbols.
Its fixed profile specification is a cross-implementation drift detector for
the runtime support inspector.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


SCHEMA = "glacier.runtime-support-registry/v1"
REGISTRY_ABI = 0x4752_5352_0000_0001
CLAIM_SCOPE = "retained_reference_fixture_contracts"
MAX_PROFILES = 64
UNEXPECTED_INSPECTOR_ARGUMENT = "--oracle-unexpected-argument"


class OracleError(RuntimeError):
    """The inspector disagrees with the independently specified registry."""


@dataclass(frozen=True)
class SupportSpec:
    family: str
    family_id: int
    operation: str
    operation_id: int
    input_kind: str
    input_kind_id: int
    output_kind: str
    output_kind_id: int
    numerical_policy: str
    numerical_policy_id: int
    max_batch_items: int
    max_input_features: int
    max_output_dimensions: int
    allowed_capabilities: int = 0

    def document(self) -> dict[str, object]:
        return {
            "family": self.family,
            "family_id": self.family_id,
            "operation": self.operation,
            "operation_id": self.operation_id,
            "input_kind": self.input_kind,
            "input_kind_id": self.input_kind_id,
            "output_kind": self.output_kind,
            "output_kind_id": self.output_kind_id,
            "numerical_policy": self.numerical_policy,
            "numerical_policy_id": self.numerical_policy_id,
            "max_batch_items": self.max_batch_items,
            "max_input_features": self.max_input_features,
            "max_output_dimensions": self.max_output_dimensions,
            "allowed_capabilities": f"{self.allowed_capabilities:016x}",
        }


@dataclass(frozen=True)
class ProfileSpec:
    index: int
    slug: str
    profile_abi: int
    lifecycle: str
    support: SupportSpec
    evidence: str = "retained_reference_fixture"

    def document(self) -> dict[str, object]:
        return {
            "index": self.index,
            "slug": self.slug,
            "profile_abi": f"{self.profile_abi:016x}",
            "lifecycle": self.lifecycle,
            "evidence": self.evidence,
            "support": self.support.document(),
        }


PROFILES = (
    ProfileSpec(
        index=0,
        slug="vision-encoder-reference",
        profile_abi=0x4756_454E_0000_0001,
        lifecycle="stateless",
        support=SupportSpec(
            family="vision_understanding",
            family_id=3,
            operation="encode",
            operation_id=3,
            input_kind="image_feature_u8",
            input_kind_id=3,
            output_kind="embedding_i32",
            output_kind_id=2,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=64,
            max_input_features=65_536,
            max_output_dimensions=16_384,
        ),
    ),
    ProfileSpec(
        index=1,
        slug="audio-window-reference",
        profile_abi=0x4741_5745_0000_0001,
        lifecycle="stateless",
        support=SupportSpec(
            family="audio_understanding",
            family_id=4,
            operation="encode",
            operation_id=3,
            input_kind="audio_feature_i16",
            input_kind_id=4,
            output_kind="embedding_i32",
            output_kind_id=2,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=4_096,
            max_input_features=16_384,
            max_output_dimensions=16_384,
        ),
    ),
    ProfileSpec(
        index=2,
        slug="audio-transcript-reference",
        profile_abi=0x4154_524E_0000_0001,
        lifecycle="stateless",
        support=SupportSpec(
            family="audio_understanding",
            family_id=4,
            operation="transcribe",
            operation_id=6,
            input_kind="audio_feature_i16",
            input_kind_id=4,
            output_kind="transcript",
            output_kind_id=5,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=1,
            max_input_features=4_096,
            max_output_dimensions=384,
        ),
    ),
    ProfileSpec(
        index=3,
        slug="stateful-transcript-reference",
        profile_abi=0x5354_5254_524E_0001,
        lifecycle="stateful",
        support=SupportSpec(
            family="audio_understanding",
            family_id=4,
            operation="transcribe",
            operation_id=6,
            input_kind="audio_feature_i16",
            input_kind_id=4,
            output_kind="transcript",
            output_kind_id=5,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=1,
            max_input_features=4,
            max_output_dimensions=64,
        ),
    ),
    ProfileSpec(
        index=4,
        slug="temporal-video-reference",
        profile_abi=0x4754_5645_0000_0001,
        lifecycle="stateless",
        support=SupportSpec(
            family="video_understanding",
            family_id=6,
            operation="encode",
            operation_id=3,
            input_kind="video_feature_u8",
            input_kind_id=5,
            output_kind="embedding_i32",
            output_kind_id=2,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=4_096,
            max_input_features=1_048_576,
            max_output_dimensions=16_384,
        ),
    ),
    ProfileSpec(
        index=5,
        slug="video-segment-reference",
        profile_abi=0x4756_5341_0000_0001,
        lifecycle="stateless",
        support=SupportSpec(
            family="video_understanding",
            family_id=6,
            operation="segment",
            operation_id=10,
            input_kind="video_feature_u8",
            input_kind_id=5,
            output_kind="video_segment",
            output_kind_id=10,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=1,
            max_input_features=1_048_576,
            max_output_dimensions=512,
        ),
    ),
    ProfileSpec(
        index=6,
        slug="stateful-video-reference",
        profile_abi=0x5354_5656_4652_0001,
        lifecycle="stateful",
        support=SupportSpec(
            family="video_understanding",
            family_id=6,
            operation="segment",
            operation_id=10,
            input_kind="video_feature_u8",
            input_kind_id=5,
            output_kind="video_segment",
            output_kind_id=10,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=1,
            max_input_features=4,
            max_output_dimensions=512,
        ),
    ),
    ProfileSpec(
        index=7,
        slug="latent-step-reference",
        profile_abi=0x474C_4154_0000_0001,
        lifecycle="stateful",
        support=SupportSpec(
            family="image_generation",
            family_id=7,
            operation="diffuse_step",
            operation_id=8,
            input_kind="latent_tensor",
            input_kind_id=6,
            output_kind="media_chunk",
            output_kind_id=6,
            numerical_policy="exact_integer",
            numerical_policy_id=1,
            max_batch_items=1,
            max_input_features=1_048_576,
            max_output_dimensions=1_048_576,
        ),
    ),
)


def registry_document() -> dict[str, object]:
    """Return the ordered v1 registry document."""
    return {
        "schema": SCHEMA,
        "registry_abi": f"{REGISTRY_ABI:016x}",
        "production_model_support": False,
        "host_backend_probed": False,
        "claim_scope": CLAIM_SCOPE,
        "profile_count": len(PROFILES),
        "max_profiles": MAX_PROFILES,
        "profiles": [profile.document() for profile in PROFILES],
    }


def render_registry() -> str:
    """Render canonical compact JSON with one terminating newline."""
    return json.dumps(
        registry_document(),
        ensure_ascii=True,
        separators=(",", ":"),
    ) + "\n"


def render_registry_bytes() -> bytes:
    return render_registry().encode("ascii")


def _first_difference(expected: bytes, actual: bytes) -> int:
    for offset, (expected_byte, actual_byte) in enumerate(
        zip(expected, actual)
    ):
        if expected_byte != actual_byte:
            return offset
    return min(len(expected), len(actual))


def verify_inspector(inspector: Path) -> None:
    """Require exact output and fail-closed argument handling from inspector."""
    inspector_path = inspector.resolve()
    expected = render_registry_bytes()

    try:
        actual = subprocess.run(
            [str(inspector_path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise OracleError(
            f"could not execute inspector {inspector_path}: {error}"
        ) from error

    if actual.returncode != 0:
        raise OracleError(
            "inspector exited with status "
            f"{actual.returncode}; stderr={actual.stderr!r}"
        )
    if actual.stderr:
        raise OracleError(
            f"inspector wrote unexpected stderr: {actual.stderr!r}"
        )
    if actual.stdout != expected:
        offset = _first_difference(expected, actual.stdout)
        raise OracleError(
            "inspector output differs from oracle at byte "
            f"{offset} (expected {len(expected)} bytes, "
            f"received {len(actual.stdout)} bytes)"
        )

    unexpected = subprocess.run(
        [str(inspector_path), UNEXPECTED_INSPECTOR_ARGUMENT],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if unexpected.returncode == 0:
        raise OracleError("inspector accepted an unexpected CLI argument")
    if unexpected.stdout:
        raise OracleError(
            "inspector wrote stdout for an unexpected CLI argument: "
            f"{unexpected.stdout!r}"
        )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify the Glacier runtime-support inspector"
    )
    parser.add_argument(
        "--inspector",
        required=True,
        type=Path,
        help="path to glacier-runtime-support-inspector",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _argument_parser().parse_args(argv)
    try:
        verify_inspector(arguments.inspector)
    except OracleError as error:
        print(f"runtime-support-registry oracle: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
