"""Independent codec and verifier for Glacier continuation capsule v1."""

from __future__ import annotations

import hashlib
import struct
from typing import Any


class CapsuleError(ValueError):
    """The continuation manifest or one of its bound objects is invalid."""


Digest = bytes
Record = dict[str, Any]
Object = tuple[int, bytes]

MAGIC = b"GCCAPV01"
WIRE_ABI = 0x4743434100000001
FLAG_REQUIRE_ALL_OBJECTS = 1
HEADER_BYTES = 144
OBJECT_REF_BYTES = 48
OBJECT_NAMES = (
    "model",
    "tokenizer",
    "execution_plan",
    "resource_state",
    "lane_state",
    "kv_state",
    "sampler_state",
    "output_state",
    "publication_receipt",
)
ENCODED_BYTES = HEADER_BYTES + len(OBJECT_NAMES) * OBJECT_REF_BYTES + 32
OBJECT_DOMAIN = b"glacier-continuation-object-v1\x00"
ENVELOPE_DOMAIN = b"glacier-continuation-capsule-wire-v1\x00"
ZERO_DIGEST = bytes(32)


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise CapsuleError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise CapsuleError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise CapsuleError("invalid digest")
    if not allow_zero and value == ZERO_DIGEST:
        raise CapsuleError("zero digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _validate_config(config: Record) -> None:
    scalar_names = (
        "execution_abi",
        "request_epoch",
        "publication_sequence",
        "checkpoint_generation",
        "kv_tokens",
        "output_tokens",
    )
    for name in scalar_names:
        _u64(config[name])
    if (
        config["execution_abi"] == 0
        or config["request_epoch"] == 0
        or config["publication_sequence"] == 0
        or config["kv_tokens"] == 0
        or config["output_tokens"] == 0
        or config["output_tokens"] > config["kv_tokens"]
    ):
        raise CapsuleError("invalid scalar identity")
    _digest(config["challenge_sha256"])
    parent = _digest(config["parent_capsule_sha256"], allow_zero=True)
    has_parent = parent != ZERO_DIGEST
    if (config["checkpoint_generation"] == 0 and has_parent) or (
        config["checkpoint_generation"] != 0 and not has_parent
    ):
        raise CapsuleError("invalid parent chain")


def object_ref(kind_index: int, value: Object) -> Record:
    if not 0 <= kind_index < len(OBJECT_NAMES):
        raise CapsuleError("invalid object kind")
    abi_version, payload = value
    _u64(abi_version)
    if abi_version == 0 or not isinstance(payload, bytes) or not payload:
        raise CapsuleError("invalid object")
    byte_length = len(payload)
    _u64(byte_length)
    return {
        "abi_version": abi_version,
        "byte_length": byte_length,
        "sha256": _hash(
            OBJECT_DOMAIN,
            _u64(kind_index),
            _u64(abi_version),
            _u64(byte_length),
            payload,
        ),
    }


def encode(config: Record, objects: dict[str, Object]) -> bytes:
    """Encode a canonical fixed-size continuation manifest."""
    _validate_config(config)
    if set(objects) != set(OBJECT_NAMES):
        raise CapsuleError("object set mismatch")
    refs = [object_ref(index, objects[name]) for index, name in enumerate(OBJECT_NAMES)]
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(ENCODED_BYTES),
            _u32(FLAG_REQUIRE_ALL_OBJECTS),
            _u32(0),
            _u64(config["execution_abi"]),
            _u64(config["request_epoch"]),
            _u64(config["publication_sequence"]),
            _u64(config["checkpoint_generation"]),
            _u64(config["kv_tokens"]),
            _u64(config["output_tokens"]),
            config["challenge_sha256"],
            config["parent_capsule_sha256"],
            *(
                part
                for ref in refs
                for part in (
                    _u64(ref["abi_version"]),
                    _u64(ref["byte_length"]),
                    ref["sha256"],
                )
            ),
        )
    )
    if len(prefix) != ENCODED_BYTES - 32:
        raise CapsuleError("internal encoded length mismatch")
    return prefix + _hash(ENVELOPE_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if length < 0 or end > len(self.data):
            raise CapsuleError("truncated capsule")
        value = self.data[self.position : end]
        self.position = end
        return value

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> Digest:
        return self.take(32)


def decode_manifest(encoded: bytes) -> Record:
    """Validate the self-contained envelope without external object authority."""
    if not isinstance(encoded, bytes) or len(encoded) != ENCODED_BYTES:
        raise CapsuleError("invalid capsule length")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC:
        raise CapsuleError("invalid magic")
    if reader.u64() != WIRE_ABI:
        raise CapsuleError("invalid ABI")
    if reader.u64() != ENCODED_BYTES:
        raise CapsuleError("invalid declared length")
    if reader.u32() != FLAG_REQUIRE_ALL_OBJECTS or reader.u32() != 0:
        raise CapsuleError("invalid flags")
    config = {
        "execution_abi": reader.u64(),
        "request_epoch": reader.u64(),
        "publication_sequence": reader.u64(),
        "checkpoint_generation": reader.u64(),
        "kv_tokens": reader.u64(),
        "output_tokens": reader.u64(),
        "challenge_sha256": reader.digest(),
        "parent_capsule_sha256": reader.digest(),
    }
    _validate_config(config)
    refs: dict[str, Record] = {}
    for name in OBJECT_NAMES:
        ref = {
            "abi_version": reader.u64(),
            "byte_length": reader.u64(),
            "sha256": reader.digest(),
        }
        if ref["abi_version"] == 0 or ref["byte_length"] == 0:
            raise CapsuleError("invalid object reference")
        _digest(ref["sha256"])
        refs[name] = ref
    envelope_sha256 = reader.digest()
    if reader.position != len(encoded):
        raise CapsuleError("trailing capsule bytes")
    expected_envelope = _hash(ENVELOPE_DOMAIN, encoded[:-32])
    if envelope_sha256 != expected_envelope:
        raise CapsuleError("envelope mismatch")
    return {
        "config": config,
        "refs": refs,
        "envelope_sha256": envelope_sha256,
    }


def decode_and_verify(
    encoded: bytes,
    expected_config: Record,
    objects: dict[str, Object],
) -> Record:
    """Verify the expected scalar identity and every exact external object."""
    decoded = decode_manifest(encoded)
    _validate_config(expected_config)
    if decoded["config"] != expected_config:
        raise CapsuleError("scalar identity substitution")
    if encode(expected_config, objects) != encoded:
        raise CapsuleError("object or manifest substitution")
    return decoded


def reseal_for_test(encoded: bytes) -> bytes:
    """Recompute only the outer envelope for mutation-completeness tests."""
    if len(encoded) != ENCODED_BYTES:
        raise CapsuleError("invalid capsule length")
    return encoded[:-32] + _hash(ENVELOPE_DOMAIN, encoded[:-32])


def demo_config() -> Record:
    return {
        "execution_abi": 0x4341455800000001,
        "request_epoch": 0x4341525100000001,
        "publication_sequence": 3,
        "checkpoint_generation": 0,
        "kv_tokens": 35,
        "output_tokens": 3,
        "challenge_sha256": bytes((0xA7,)) * 32,
        "parent_capsule_sha256": ZERO_DIGEST,
    }


def demo_objects() -> dict[str, Object]:
    return {
        "model": (0x43414D4F00000001, b"model-v1:sha256:demo-glrt"),
        "tokenizer": (0x4341544B00000001, b"tokenizer-v1:demo-qwen"),
        "execution_plan": (0x4341504C00000001, b"plan-v1:cpu:threads=4:strict"),
        "resource_state": (
            0x4341525300000001,
            b"resource-v1:bank=17:kv=4096:output=64",
        ),
        "lane_state": (0x43414C4E00000001, b"lane-v1:request=41:service=9"),
        "kv_state": (0x43414B5600000001, b"kv-v1:positions=35:root=demo"),
        "sampler_state": (
            0x4341534D00000001,
            b"sampler-v1:rng=01020304:calls=3",
        ),
        "output_state": (
            0x43414F5500000001,
            b"output-v1:tokens=901,902,903",
        ),
        "publication_receipt": (
            0x4341505200000001,
            b"publication-v1:sequence=3:commit=demo",
        ),
    }


def build_demo_bundle() -> Record:
    config = demo_config()
    objects = demo_objects()
    encoded = encode(config, objects)
    return {"config": config, "objects": objects, "encoded": encoded}
