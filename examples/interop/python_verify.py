#!/usr/bin/env python3
"""Verify canonical ModelContract V1 fixtures through the experimental C ABI.

This quick start uses only the Python standard library:

    python3 examples/interop/python_verify.py \
        --library zig-out/lib/libglacier_contract.dylib

Use ``libglacier_contract.so`` on Linux or ``glacier_contract.dll`` on
Windows. The ABI is experimental and may change before a stable release.
"""

from __future__ import annotations

import argparse
import ctypes
import platform
from pathlib import Path
from typing import Final


OK: Final = 0
ABI_V1: Final = 1
NULL: Final = 1
SIZE: Final = 2
INVALID_ARTIFACT: Final = 3
INVALID_PLAN: Final = 4
INVALID_RESULT: Final = 5
BINDING_MISMATCH: Final = 6
OUT_OF_RANGE: Final = 7
INVALID_QUERY: Final = 8

SUPPORT_REGISTRY_ABI_V1: Final = 0x4752535200000001
SUPPORT_PROFILE_COUNT_V1: Final = 8
SUPPORT_PROFILE_VISION_ENCODER: Final = 0x4756454E00000001
SUPPORT_LIFECYCLE_STATELESS: Final = 1
SUPPORT_EVIDENCE_RETAINED_REFERENCE_FIXTURE: Final = 1
MODEL_FAMILY_VISION_UNDERSTANDING: Final = 3
MODEL_FAMILY_AUDIO_UNDERSTANDING: Final = 4
MODEL_OPERATION_ENCODE: Final = 3
MODEL_OPERATION_TRANSCRIBE: Final = 6
MODEL_INPUT_IMAGE_FEATURE_U8: Final = 3
MODEL_INPUT_AUDIO_FEATURE_I16: Final = 4
MODEL_OUTPUT_EMBEDDING_I32: Final = 2
MODEL_OUTPUT_TRANSCRIPT: Final = 5
NUMERICAL_EXACT_INTEGER: Final = 1
SUPPORT_UNSUPPORTED_NONE: Final = 0
SUPPORT_UNSUPPORTED_CAPABILITIES: Final = 7
SUPPORT_MASK_AUDIO_TRANSCRIPT: Final = 1 << 2
SUPPORT_MASK_STATEFUL_TRANSCRIPT: Final = 1 << 3
SUPPORT_MASK_TRANSCRIPT: Final = (
    SUPPORT_MASK_AUDIO_TRANSCRIPT | SUPPORT_MASK_STATEFUL_TRANSCRIPT
)

STATUS_NAMES: Final = {
    OK: "OK",
    NULL: "NULL",
    SIZE: "SIZE",
    INVALID_ARTIFACT: "INVALID_ARTIFACT",
    INVALID_PLAN: "INVALID_PLAN",
    INVALID_RESULT: "INVALID_RESULT",
    BINDING_MISMATCH: "BINDING_MISMATCH",
    OUT_OF_RANGE: "OUT_OF_RANGE",
    INVALID_QUERY: "INVALID_QUERY",
}

FIXTURE_SIZES: Final = {
    "artifact_manifest_v1.hex": 320,
    "execution_plan_v1.hex": 768,
    "result_envelope_v1.hex": 768,
}


class ModelSupportProfileV1(ctypes.Structure):
    _fields_ = [
        ("profile_abi", ctypes.c_uint64),
        ("lifecycle", ctypes.c_uint64),
        ("evidence", ctypes.c_uint64),
        ("family", ctypes.c_uint64),
        ("operation", ctypes.c_uint64),
        ("input_kind", ctypes.c_uint64),
        ("output_kind", ctypes.c_uint64),
        ("numerical_policy", ctypes.c_uint64),
        ("max_batch_items", ctypes.c_uint64),
        ("max_input_features", ctypes.c_uint64),
        ("max_output_dimensions", ctypes.c_uint64),
        ("allowed_capabilities", ctypes.c_uint64),
    ]


class ModelSupportQueryV1(ctypes.Structure):
    _fields_ = [
        ("family", ctypes.c_uint64),
        ("operation", ctypes.c_uint64),
        ("input_kind", ctypes.c_uint64),
        ("output_kind", ctypes.c_uint64),
        ("numerical_policy", ctypes.c_uint64),
        ("batch_items", ctypes.c_uint64),
        ("input_features", ctypes.c_uint64),
        ("output_dimensions", ctypes.c_uint64),
        ("required_capabilities", ctypes.c_uint64),
    ]


class ModelSupportResultV1(ctypes.Structure):
    _fields_ = [
        ("compatible", ctypes.c_uint64),
        ("unsupported_reason", ctypes.c_uint64),
        ("matching_profile_mask", ctypes.c_uint64),
    ]


if ctypes.sizeof(ModelSupportProfileV1) != 96:
    raise RuntimeError("ModelSupportProfileV1 layout changed")
if ctypes.sizeof(ModelSupportQueryV1) != 72:
    raise RuntimeError("ModelSupportQueryV1 layout changed")
if ctypes.sizeof(ModelSupportResultV1) != 24:
    raise RuntimeError("ModelSupportResultV1 layout changed")


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_fixture_dir() -> Path:
    return Path(__file__).resolve().parent / "fixtures"


def default_library() -> Path:
    root = repository_root()
    system = platform.system()
    platform_candidates = {
        "Darwin": [root / "zig-out/lib/libglacier_contract.dylib"],
        "Linux": [root / "zig-out/lib/libglacier_contract.so"],
        "Windows": [
            root / "zig-out/bin/glacier_contract.dll",
            root / "zig-out/lib/glacier_contract.dll",
        ],
    }
    candidates = platform_candidates.get(system, []) + [
        root / "zig-out/lib/libglacier_contract.dylib",
        root / "zig-out/lib/libglacier_contract.so",
        root / "zig-out/bin/glacier_contract.dll",
        root / "zig-out/lib/glacier_contract.dll",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    expected = platform_candidates.get(system, candidates)
    locations = ", ".join(str(path) for path in expected)
    raise FileNotFoundError(
        "contract library not found; build it first or pass --library. "
        f"Checked: {locations}"
    )


def read_hex_fixture(directory: Path, name: str) -> bytes:
    path = directory / name
    try:
        wire = bytes.fromhex(path.read_text(encoding="ascii"))
    except (OSError, UnicodeError, ValueError) as error:
        raise RuntimeError(f"cannot read canonical fixture {path}: {error}") from error
    expected = FIXTURE_SIZES[name]
    if len(wire) != expected:
        raise RuntimeError(
            f"{path} has {len(wire)} bytes; expected exactly {expected}"
        )
    return wire


def as_c_bytes(value: bytes) -> ctypes.Array[ctypes.c_uint8]:
    return (ctypes.c_uint8 * len(value)).from_buffer_copy(value)


def verify(library_path: Path, fixture_dir: Path) -> tuple[int, bytes, int, int]:
    library = ctypes.CDLL(str(library_path.resolve()))
    library.glacier_contract_abi_v1.argtypes = []
    library.glacier_contract_abi_v1.restype = ctypes.c_uint64
    library.glacier_model_contract_verify_v1.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
    ]
    library.glacier_model_contract_verify_v1.restype = ctypes.c_uint32
    library.glacier_model_support_registry_abi_v1.argtypes = []
    library.glacier_model_support_registry_abi_v1.restype = ctypes.c_uint64
    library.glacier_model_support_profile_count_v1.argtypes = []
    library.glacier_model_support_profile_count_v1.restype = ctypes.c_uint64
    library.glacier_model_support_profile_get_v1.argtypes = [
        ctypes.c_uint64,
        ctypes.POINTER(ModelSupportProfileV1),
        ctypes.c_size_t,
    ]
    library.glacier_model_support_profile_get_v1.restype = ctypes.c_uint32
    library.glacier_model_support_query_v1.argtypes = [
        ctypes.POINTER(ModelSupportQueryV1),
        ctypes.c_size_t,
        ctypes.POINTER(ModelSupportResultV1),
        ctypes.c_size_t,
    ]
    library.glacier_model_support_query_v1.restype = ctypes.c_uint32

    artifact = read_hex_fixture(fixture_dir, "artifact_manifest_v1.hex")
    plan = read_hex_fixture(fixture_dir, "execution_plan_v1.hex")
    result = read_hex_fixture(fixture_dir, "result_envelope_v1.hex")
    artifact_c = as_c_bytes(artifact)
    plan_c = as_c_bytes(plan)
    result_c = as_c_bytes(result)
    result_root_c = (ctypes.c_uint8 * 32)()

    abi = int(library.glacier_contract_abi_v1())
    if abi != ABI_V1:
        raise RuntimeError(
            f"unsupported contract ABI: expected {ABI_V1}, received {abi}"
        )
    status = int(
        library.glacier_model_contract_verify_v1(
            artifact_c,
            len(artifact),
            plan_c,
            len(plan),
            result_c,
            len(result),
            result_root_c,
        )
    )
    if status != OK:
        name = STATUS_NAMES.get(status, "UNKNOWN")
        raise RuntimeError(f"contract verification failed: {name} ({status})")

    result_root = bytes(result_root_c)
    canonical_root = result[-32:]
    if result_root != canonical_root:
        raise RuntimeError("binding returned a root different from the canonical wire")

    registry_abi = int(library.glacier_model_support_registry_abi_v1())
    if registry_abi != SUPPORT_REGISTRY_ABI_V1:
        raise RuntimeError(
            "unsupported model-support registry ABI: "
            f"expected 0x{SUPPORT_REGISTRY_ABI_V1:016x}, "
            f"received 0x{registry_abi:016x}"
        )
    profile_count = int(library.glacier_model_support_profile_count_v1())
    if profile_count != SUPPORT_PROFILE_COUNT_V1:
        raise RuntimeError(
            "unexpected model-support profile count: "
            f"expected {SUPPORT_PROFILE_COUNT_V1}, received {profile_count}"
        )

    profiles: list[ModelSupportProfileV1] = []
    for index in range(profile_count):
        profile = ModelSupportProfileV1()
        status = int(
            library.glacier_model_support_profile_get_v1(
                index,
                ctypes.byref(profile),
                ctypes.sizeof(profile),
            )
        )
        if status != OK:
            name = STATUS_NAMES.get(status, "UNKNOWN")
            raise RuntimeError(
                f"support profile {index} failed: {name} ({status})"
            )
        profiles.append(profile)

    profile_abis = {int(profile.profile_abi) for profile in profiles}
    if len(profile_abis) != profile_count:
        raise RuntimeError("model-support profile ABI values are not unique")

    first = profiles[0]
    first_values = (
        int(first.profile_abi),
        int(first.lifecycle),
        int(first.evidence),
        int(first.family),
        int(first.operation),
        int(first.input_kind),
        int(first.output_kind),
        int(first.numerical_policy),
        int(first.max_batch_items),
        int(first.max_input_features),
        int(first.max_output_dimensions),
        int(first.allowed_capabilities),
    )
    expected_first = (
        SUPPORT_PROFILE_VISION_ENCODER,
        SUPPORT_LIFECYCLE_STATELESS,
        SUPPORT_EVIDENCE_RETAINED_REFERENCE_FIXTURE,
        MODEL_FAMILY_VISION_UNDERSTANDING,
        MODEL_OPERATION_ENCODE,
        MODEL_INPUT_IMAGE_FEATURE_U8,
        MODEL_OUTPUT_EMBEDDING_I32,
        NUMERICAL_EXACT_INTEGER,
        64,
        65_536,
        16_384,
        0,
    )
    if first_values != expected_first:
        raise RuntimeError("first model-support profile does not match V1")

    transcript_query = ModelSupportQueryV1(
        family=MODEL_FAMILY_AUDIO_UNDERSTANDING,
        operation=MODEL_OPERATION_TRANSCRIBE,
        input_kind=MODEL_INPUT_AUDIO_FEATURE_I16,
        output_kind=MODEL_OUTPUT_TRANSCRIPT,
        numerical_policy=NUMERICAL_EXACT_INTEGER,
        batch_items=1,
        input_features=1,
        output_dimensions=1,
        required_capabilities=0,
    )
    transcript_result = ModelSupportResultV1()
    status = int(
        library.glacier_model_support_query_v1(
            ctypes.byref(transcript_query),
            ctypes.sizeof(transcript_query),
            ctypes.byref(transcript_result),
            ctypes.sizeof(transcript_result),
        )
    )
    if status != OK:
        name = STATUS_NAMES.get(status, "UNKNOWN")
        raise RuntimeError(f"transcript support query failed: {name} ({status})")
    if (
        int(transcript_result.compatible) != 1
        or int(transcript_result.unsupported_reason) != SUPPORT_UNSUPPORTED_NONE
        or int(transcript_result.matching_profile_mask) != SUPPORT_MASK_TRANSCRIPT
    ):
        raise RuntimeError("transcript support query did not match both V1 profiles")

    transcript_query.required_capabilities = 1
    unsupported_result = ModelSupportResultV1()
    status = int(
        library.glacier_model_support_query_v1(
            ctypes.byref(transcript_query),
            ctypes.sizeof(transcript_query),
            ctypes.byref(unsupported_result),
            ctypes.sizeof(unsupported_result),
        )
    )
    if status != OK:
        name = STATUS_NAMES.get(status, "UNKNOWN")
        raise RuntimeError(
            f"unsupported capability query failed: {name} ({status})"
        )
    if (
        int(unsupported_result.compatible) != 0
        or int(unsupported_result.unsupported_reason)
        != SUPPORT_UNSUPPORTED_CAPABILITIES
        or int(unsupported_result.matching_profile_mask) != 0
    ):
        raise RuntimeError(
            "unsupported capability query did not return the explicit V1 reason"
        )

    return (
        abi,
        result_root,
        profile_count,
        int(transcript_result.matching_profile_mask),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--library",
        type=Path,
        help="path to libglacier_contract (.dylib, .so, or .dll)",
    )
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=default_fixture_dir(),
        help="directory containing the three canonical .hex fixtures",
    )
    args = parser.parse_args()

    try:
        library_path = args.library if args.library is not None else default_library()
        abi, result_root, profile_count, transcript_mask = verify(
            library_path, args.fixtures
        )
    except (FileNotFoundError, OSError, RuntimeError) as error:
        parser.exit(1, f"error: {error}\n")

    print("Glacier contract C ABI (experimental)")
    print(f"abi=0x{abi:016x}")
    print(f"result_root={result_root.hex()}")
    print(
        f"profile_count={profile_count} "
        f"transcript_mask=0x{transcript_mask:016x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
