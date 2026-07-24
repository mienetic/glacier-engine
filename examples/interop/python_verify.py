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

STATUS_NAMES: Final = {
    OK: "OK",
    NULL: "NULL",
    SIZE: "SIZE",
    INVALID_ARTIFACT: "INVALID_ARTIFACT",
    INVALID_PLAN: "INVALID_PLAN",
    INVALID_RESULT: "INVALID_RESULT",
    BINDING_MISMATCH: "BINDING_MISMATCH",
}

FIXTURE_SIZES: Final = {
    "artifact_manifest_v1.hex": 320,
    "execution_plan_v1.hex": 768,
    "result_envelope_v1.hex": 768,
}


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


def verify(library_path: Path, fixture_dir: Path) -> tuple[int, bytes]:
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
    return abi, result_root


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
        abi, result_root = verify(library_path, args.fixtures)
    except (FileNotFoundError, OSError, RuntimeError) as error:
        parser.exit(1, f"error: {error}\n")

    print("Glacier contract C ABI (experimental)")
    print(f"abi=0x{abi:016x}")
    print(f"result_root={result_root.hex()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
