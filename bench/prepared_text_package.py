"""Independent verifier for stable packages and durable raw-input archives."""

from __future__ import annotations

import hashlib
import math
import struct
from typing import Mapping

from bench import prepared_text_raw_input as raw_input


class PreparedTextPackageError(ValueError):
    """A package, representation, or raw-input archive is not canonical."""


DIGEST_BYTES = 32
ZERO_DIGEST = bytes(DIGEST_BYTES)
U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1

MANIFEST_ABI = 0x474C_504B_0000_0002
CONFIG_ABI = 0x474C_5043_0000_0001
PREPARED_REPRESENTATION_ABI = 0x474C_5052_0000_0001
MANIFEST_BYTES = 640
MANIFEST_BODY_BYTES = MANIFEST_BYTES - DIGEST_BYTES
PREPARED_REPRESENTATION_BYTES = 256
PREPARED_REPRESENTATION_BODY_BYTES = PREPARED_REPRESENTATION_BYTES - DIGEST_BYTES
ADMISSION_BUNDLE_BYTES = MANIFEST_BYTES + PREPARED_REPRESENTATION_BYTES
MANIFEST_MAGIC = b"GLPKG02\x00"
PREPARED_REPRESENTATION_MAGIC = b"GLPREP1\x00"
MANIFEST_FLAG_MODEL_PROFILE = 1 << 0
MANIFEST_ALLOWED_FLAGS = MANIFEST_FLAG_MODEL_PROFILE
ALLOWED_FLAGS = 0
MODEL_PROFILE_ABI = 0x474C_4D50_0000_0001
ORDINARY_PACKAGE_PROFILE_ID = 1

ARCHIVE_ABI = 0x4750_5449_0000_0001
ARCHIVE_MAGIC = b"GPTINP1\x00"
ARCHIVE_HEADER_BYTES = 128
ARCHIVE_FOOTER_BYTES = DIGEST_BYTES
PACKAGE_OFFSET = ARCHIVE_HEADER_BYTES
REPRESENTATION_OFFSET = PACKAGE_OFFSET + MANIFEST_BYTES
TOKENIZER_MANIFEST_OFFSET = REPRESENTATION_OFFSET + PREPARED_REPRESENTATION_BYTES
TOKENIZER_PROMPT_OFFSET = TOKENIZER_MANIFEST_OFFSET + raw_input.MANIFEST_BYTES
RAW_BINDING_OFFSET = TOKENIZER_PROMPT_OFFSET + raw_input.PROMPT_BYTES
RAW_TEXT_OFFSET = RAW_BINDING_OFFSET + raw_input.BINDING_BYTES
ARCHIVE_FIXED_PAYLOAD_BYTES = RAW_TEXT_OFFSET - ARCHIVE_HEADER_BYTES
ARCHIVE_MINIMUM_BYTES = RAW_TEXT_OFFSET + ARCHIVE_FOOTER_BYTES

MANIFEST_DOMAIN = b"glacier-model-package-manifest-v2\x00"
CONFIG_DOMAIN = b"glacier-model-package-config-v1\x00"
PREPARED_REPRESENTATION_DOMAIN = b"glacier-model-prepared-representation-v1\x00"
MODEL_CONTENT_DOMAIN = b"glacier-prepared-provenance-v1\x00"
PROFILED_MODEL_CONTENT_DOMAIN = (
    b"glacier-model-package-profiled-content-v1\x00"
)
MODEL_PROFILE_DOMAIN = b"glacier-model-package-profile-v1\x00"
ARCHIVE_DOMAIN = b"glacier-prepared-text-input-archive-v1\x00"
RAW_TEXT_DOMAIN = b"glacier-utf8-byte-tokenizer-raw-text-v1\x00"
TOKEN_STREAM_DOMAIN = b"glacier-utf8-byte-tokenizer-token-stream-v1\x00"
PREPARED_PROMPT_DOMAIN = b"glacier-prepared-text-prompt-v1\x00"

FAMILY_IDS = frozenset(range(1, 19))
SOURCE_FORMAT_IDS = frozenset((1, 2, 3, 255))
CONFIG_U32_FIELDS = (
    "dim",
    "hidden_dim",
    "layers",
    "vocab",
    "heads",
    "head_dim",
    "kv_heads",
)
MANIFEST_PREFIX_U64_FIELDS = (
    "portable_format_abi",
    "conversion_profile_abi",
    "conversion_plan_abi",
    "tokenizer_manifest_abi",
    "tokenizer_manifest_bytes",
    "source_bytes",
    "portable_bytes",
    "portable_page_count",
    "license_bytes",
)
MANIFEST_U64_FIELDS = MANIFEST_PREFIX_U64_FIELDS + (
    "model_profile_id",
    "tensor_profile_abi",
    "tensor_count",
)
MANIFEST_DIGEST_FIELDS = (
    "source_sha256",
    "portable_artifact_sha256",
    "conversion_profile_sha256",
    "conversion_plan_sha256",
    "model_content_sha256",
    "tokenizer_config_sha256",
    "tokenizer_domain_sha256",
    "tokenizer_behavior_sha256",
    "license_sha256",
    "tensor_inventory_sha256",
)
REPRESENTATION_DIGEST_FIELDS = (
    "package_sha256",
    "resolved_config_sha256",
    "source_fingerprint",
    "abi_fingerprint",
    "container_sha256",
)


def _sha(*parts: bytes) -> bytes:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
    return digest.digest()


def _u32(value: object) -> bytes:
    if type(value) is not int or not 0 <= value <= U32_MAX:
        raise PreparedTextPackageError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: object) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise PreparedTextPackageError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: object, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != DIGEST_BYTES
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise PreparedTextPackageError("invalid digest")
    return value


def _f32_bits(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PreparedTextPackageError("invalid f32")
    try:
        encoded = struct.pack("<f", value)
    except (OverflowError, struct.error) as error:
        raise PreparedTextPackageError("invalid f32") from error
    decoded = struct.unpack("<f", encoded)[0]
    if not math.isfinite(decoded) or decoded <= 0:
        raise PreparedTextPackageError("invalid f32")
    return struct.unpack("<I", encoded)[0]


def _checked_config(config: object) -> dict[str, object]:
    if not isinstance(config, Mapping):
        raise PreparedTextPackageError("invalid config")
    value: dict[str, object] = {}
    try:
        for name in CONFIG_U32_FIELDS:
            scalar = config[name]
            _u32(scalar)
            if scalar == 0:
                raise PreparedTextPackageError("zero config dimension")
            value[name] = scalar
        tie_embeddings = config["tie_embeddings"]
        if type(tie_embeddings) is not bool:
            raise PreparedTextPackageError("invalid tie_embeddings")
        value["tie_embeddings"] = tie_embeddings
        for name in ("rms_eps", "rope_theta"):
            bits = _f32_bits(config[name])
            value[name] = struct.unpack("<f", struct.pack("<I", bits))[0]
            value[f"{name}_bits"] = bits
    except KeyError as error:
        raise PreparedTextPackageError("missing config field") from error
    heads = value["heads"]
    kv_heads = value["kv_heads"]
    if (
        not isinstance(heads, int)
        or not isinstance(kv_heads, int)
        or kv_heads > heads
        or heads % kv_heads != 0
        or value["dim"] != heads * value["head_dim"]
    ):
        raise PreparedTextPackageError("invalid config geometry")
    return value


def resolved_config_sha256(config: Mapping[str, object]) -> bytes:
    """Recompute the architecture-independent resolved-config identity."""

    value = _checked_config(config)
    return _sha(
        CONFIG_DOMAIN,
        _u64(CONFIG_ABI),
        *(_u32(value[name]) for name in CONFIG_U32_FIELDS),
        _u32(int(value["tie_embeddings"])),
        _u32(value["rms_eps_bits"]),
        _u32(value["rope_theta_bits"]),
    )


def model_content_sha256(
    portable_artifact_sha256: bytes,
    config: Mapping[str, object],
) -> bytes:
    """Recompute the portable/config provenance stored by GLRT images."""

    value = _checked_config(config)
    return _sha(
        MODEL_CONTENT_DOMAIN,
        _digest(portable_artifact_sha256),
        *(_u64(value[name]) for name in CONFIG_U32_FIELDS),
        _u32(value["rms_eps_bits"]),
        _u32(value["rope_theta_bits"]),
        bytes((int(value["tie_embeddings"]),)),
    )


def model_profile_sha256(profile_id: object) -> bytes:
    """Derive one canonical package-model profile identity."""

    _u64(profile_id)
    if profile_id == 0:
        raise PreparedTextPackageError("zero model profile")
    return _sha(
        MODEL_PROFILE_DOMAIN,
        _u64(MODEL_PROFILE_ABI),
        _u64(profile_id),
    )


def profiled_model_content_sha256(
    value: Mapping[str, object],
) -> bytes:
    """Bind a prepared fingerprint to exact package/conversion semantics."""

    try:
        family = value["family"]
        source_format = value["source_format"]
        portable_format_abi = value["portable_format_abi"]
        conversion_profile_abi = value["conversion_profile_abi"]
        conversion_plan_abi = value["conversion_plan_abi"]
        model_profile_id = value["model_profile_id"]
        tensor_profile_abi = value["tensor_profile_abi"]
        tensor_count = value["tensor_count"]
        config = value["config"]
        portable_artifact = _digest(value["portable_artifact_sha256"])
        conversion_profile = _digest(value["conversion_profile_sha256"])
        conversion_plan = _digest(value["conversion_plan_sha256"])
        tensor_inventory = _digest(value["tensor_inventory_sha256"])
    except (KeyError, TypeError) as error:
        raise PreparedTextPackageError(
            "invalid profiled model content input"
        ) from error
    for scalar in (
        family,
        source_format,
        portable_format_abi,
        conversion_profile_abi,
        conversion_plan_abi,
        model_profile_id,
        tensor_profile_abi,
        tensor_count,
    ):
        _u64(scalar)
        if scalar == 0:
            raise PreparedTextPackageError(
                "zero profiled model content scalar"
            )
    return _sha(
        PROFILED_MODEL_CONTENT_DOMAIN,
        _u64(family),
        _u64(source_format),
        _u64(portable_format_abi),
        portable_artifact,
        _u64(conversion_profile_abi),
        conversion_profile,
        _u64(conversion_plan_abi),
        conversion_plan,
        _u64(MODEL_PROFILE_ABI),
        _u64(model_profile_id),
        model_profile_sha256(model_profile_id),
        _u64(tensor_profile_abi),
        _u64(tensor_count),
        tensor_inventory,
        resolved_config_sha256(config),
    )


def package_sha256(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) != MANIFEST_BODY_BYTES:
        raise PreparedTextPackageError("invalid package body")
    return _sha(MANIFEST_DOMAIN, body)


def prepared_representation_sha256(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) != PREPARED_REPRESENTATION_BODY_BYTES:
        raise PreparedTextPackageError("invalid representation body")
    return _sha(PREPARED_REPRESENTATION_DOMAIN, body)


def archive_sha256(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) < RAW_TEXT_OFFSET + 1:
        raise PreparedTextPackageError("invalid archive body")
    return _sha(ARCHIVE_DOMAIN, body)


def encode_manifest(value: Mapping[str, object]) -> bytes:
    """Encode a canonical package manifest while deriving both roots."""

    try:
        family = value["family"]
        source_format = value["source_format"]
        config = _checked_config(value["config"])
    except (KeyError, TypeError) as error:
        raise PreparedTextPackageError("invalid package input") from error
    _u64(family)
    _u64(source_format)
    if family not in FAMILY_IDS or source_format not in SOURCE_FORMAT_IDS:
        raise PreparedTextPackageError("unknown package enum")
    scalars: dict[str, int] = {}
    for name in MANIFEST_U64_FIELDS:
        try:
            scalar = value[name]
        except KeyError as error:
            raise PreparedTextPackageError(f"missing {name}") from error
        _u64(scalar)
        if scalar == 0:
            raise PreparedTextPackageError(f"zero {name}")
        scalars[name] = scalar
    digests: dict[str, bytes] = {}
    for name in MANIFEST_DIGEST_FIELDS:
        try:
            digests[name] = _digest(value[name])
        except KeyError as error:
            raise PreparedTextPackageError(f"missing {name}") from error

    body = bytearray(MANIFEST_BODY_BYTES)
    body[0:8] = MANIFEST_MAGIC
    struct.pack_into(
        "<QQQQQQQQQQQQQQQ",
        body,
        8,
        MANIFEST_ABI,
        MANIFEST_BYTES,
        MANIFEST_ALLOWED_FLAGS,
        family,
        source_format,
        *(scalars[name] for name in MANIFEST_PREFIX_U64_FIELDS),
        CONFIG_ABI,
    )
    for index, name in enumerate(CONFIG_U32_FIELDS):
        struct.pack_into("<I", body, 128 + index * 4, config[name])
    struct.pack_into(
        "<III",
        body,
        156,
        int(config["tie_embeddings"]),
        config["rms_eps_bits"],
        config["rope_theta_bits"],
    )
    resolved = resolved_config_sha256(config)
    digest_values = (
        digests["source_sha256"],
        digests["portable_artifact_sha256"],
        digests["conversion_profile_sha256"],
        digests["conversion_plan_sha256"],
        resolved,
        digests["model_content_sha256"],
        digests["tokenizer_config_sha256"],
        digests["tokenizer_domain_sha256"],
        digests["tokenizer_behavior_sha256"],
        digests["license_sha256"],
    )
    for index, digest in enumerate(digest_values):
        offset = 176 + index * DIGEST_BYTES
        body[offset : offset + DIGEST_BYTES] = digest
    struct.pack_into(
        "<QQ",
        body,
        496,
        MODEL_PROFILE_ABI,
        scalars["model_profile_id"],
    )
    body[512:544] = model_profile_sha256(
        scalars["model_profile_id"]
    )
    struct.pack_into(
        "<QQ",
        body,
        544,
        scalars["tensor_profile_abi"],
        scalars["tensor_count"],
    )
    body[560:592] = digests["tensor_inventory_sha256"]
    encoded = bytes(body) + package_sha256(bytes(body))
    decode_manifest(encoded)
    return encoded


def decode_manifest(encoded: bytes) -> dict[str, object]:
    """Decode and independently authenticate a package manifest."""

    if not isinstance(encoded, bytes) or len(encoded) != MANIFEST_BYTES:
        raise PreparedTextPackageError("invalid package length")
    if (
        encoded[0:8] != MANIFEST_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != MANIFEST_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != MANIFEST_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != MANIFEST_ALLOWED_FLAGS
        or struct.unpack_from("<Q", encoded, 120)[0] != CONFIG_ABI
        or any(encoded[168:176])
        or any(encoded[592:MANIFEST_BODY_BYTES])
        or encoded[MANIFEST_BODY_BYTES:]
        != package_sha256(encoded[:MANIFEST_BODY_BYTES])
    ):
        raise PreparedTextPackageError("invalid package wire")
    family = struct.unpack_from("<Q", encoded, 32)[0]
    source_format = struct.unpack_from("<Q", encoded, 40)[0]
    if family not in FAMILY_IDS or source_format not in SOURCE_FORMAT_IDS:
        raise PreparedTextPackageError("unknown package enum")
    scalar_values = struct.unpack_from("<9Q", encoded, 48)
    scalars = dict(
        zip(
            MANIFEST_PREFIX_U64_FIELDS,
            scalar_values,
            strict=True,
        )
    )
    model_profile_abi, model_profile_id = struct.unpack_from(
        "<QQ",
        encoded,
        496,
    )
    tensor_profile_abi, tensor_count = struct.unpack_from(
        "<QQ",
        encoded,
        544,
    )
    scalars.update(
        {
            "model_profile_id": model_profile_id,
            "tensor_profile_abi": tensor_profile_abi,
            "tensor_count": tensor_count,
        }
    )
    if any(value == 0 for value in scalars.values()):
        raise PreparedTextPackageError("zero package scalar")
    config: dict[str, object] = {
        name: struct.unpack_from("<I", encoded, 128 + index * 4)[0]
        for index, name in enumerate(CONFIG_U32_FIELDS)
    }
    tie_embeddings = struct.unpack_from("<I", encoded, 156)[0]
    if tie_embeddings not in (0, 1):
        raise PreparedTextPackageError("invalid tie_embeddings")
    config["tie_embeddings"] = bool(tie_embeddings)
    for name, offset in (("rms_eps", 160), ("rope_theta", 164)):
        bits = struct.unpack_from("<I", encoded, offset)[0]
        config[name] = struct.unpack("<f", struct.pack("<I", bits))[0]
    config = _checked_config(config)

    digest_names = (
        "source_sha256",
        "portable_artifact_sha256",
        "conversion_profile_sha256",
        "conversion_plan_sha256",
        "resolved_config_sha256",
        "model_content_sha256",
        "tokenizer_config_sha256",
        "tokenizer_domain_sha256",
        "tokenizer_behavior_sha256",
        "license_sha256",
    )
    digests = {
        name: encoded[176 + index * DIGEST_BYTES : 208 + index * DIGEST_BYTES]
        for index, name in enumerate(digest_names)
    }
    model_profile_root = encoded[512:544]
    digests["tensor_inventory_sha256"] = encoded[560:592]
    if (
        model_profile_abi != MODEL_PROFILE_ABI
        or model_profile_root != model_profile_sha256(model_profile_id)
        or any(digest == ZERO_DIGEST for digest in digests.values())
        or digests["resolved_config_sha256"]
        != resolved_config_sha256(config)
    ):
        raise PreparedTextPackageError("invalid package identity")
    return {
        "abi_version": MANIFEST_ABI,
        "family": family,
        "source_format": source_format,
        **scalars,
        "model_profile_abi": model_profile_abi,
        "model_profile_sha256": model_profile_root,
        "config": config,
        **digests,
        "package_sha256": encoded[MANIFEST_BODY_BYTES:],
    }


def encode_prepared_representation(
    value: Mapping[str, object],
) -> bytes:
    """Encode one native prepared representation of a stable package."""

    scalars: dict[str, int] = {}
    for name in ("format_abi", "format_version", "container_bytes"):
        try:
            scalar = value[name]
        except KeyError as error:
            raise PreparedTextPackageError(f"missing {name}") from error
        _u64(scalar)
        if scalar == 0:
            raise PreparedTextPackageError(f"zero {name}")
        scalars[name] = scalar
    digests: dict[str, bytes] = {}
    for name in REPRESENTATION_DIGEST_FIELDS:
        try:
            digests[name] = _digest(value[name])
        except KeyError as error:
            raise PreparedTextPackageError(f"missing {name}") from error
    body = bytearray(PREPARED_REPRESENTATION_BODY_BYTES)
    body[0:8] = PREPARED_REPRESENTATION_MAGIC
    struct.pack_into(
        "<QQQQQQ",
        body,
        8,
        PREPARED_REPRESENTATION_ABI,
        PREPARED_REPRESENTATION_BYTES,
        ALLOWED_FLAGS,
        scalars["format_abi"],
        scalars["format_version"],
        scalars["container_bytes"],
    )
    for index, name in enumerate(REPRESENTATION_DIGEST_FIELDS):
        offset = 64 + index * DIGEST_BYTES
        body[offset : offset + DIGEST_BYTES] = digests[name]
    encoded = bytes(body) + prepared_representation_sha256(bytes(body))
    decode_prepared_representation(encoded)
    return encoded


def decode_prepared_representation(
    encoded: bytes,
) -> dict[str, object]:
    """Decode and independently authenticate a prepared representation."""

    if (
        not isinstance(encoded, bytes)
        or len(encoded) != PREPARED_REPRESENTATION_BYTES
        or encoded[0:8] != PREPARED_REPRESENTATION_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != PREPARED_REPRESENTATION_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != PREPARED_REPRESENTATION_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != ALLOWED_FLAGS
        or any(encoded[56:64])
        or encoded[PREPARED_REPRESENTATION_BODY_BYTES:]
        != prepared_representation_sha256(encoded[:PREPARED_REPRESENTATION_BODY_BYTES])
    ):
        raise PreparedTextPackageError("invalid representation wire")
    format_abi, format_version, container_bytes = struct.unpack_from(
        "<QQQ", encoded, 32
    )
    if format_abi == 0 or format_version == 0 or container_bytes == 0:
        raise PreparedTextPackageError("zero representation scalar")
    digests = {
        name: encoded[64 + index * DIGEST_BYTES : 96 + index * DIGEST_BYTES]
        for index, name in enumerate(REPRESENTATION_DIGEST_FIELDS)
    }
    if any(digest == ZERO_DIGEST for digest in digests.values()):
        raise PreparedTextPackageError("zero representation identity")
    return {
        "abi_version": PREPARED_REPRESENTATION_ABI,
        "format_abi": format_abi,
        "format_version": format_version,
        "container_bytes": container_bytes,
        **digests,
        "representation_sha256": encoded[PREPARED_REPRESENTATION_BODY_BYTES:],
    }


def validate_prepared_representation(
    package: Mapping[str, object],
    representation: Mapping[str, object],
) -> None:
    """Require one representation to name the exact stable package."""

    if (
        representation.get("package_sha256") != package.get("package_sha256")
        or representation.get("resolved_config_sha256")
        != package.get("resolved_config_sha256")
        or representation.get("source_fingerprint")
        != package.get("model_content_sha256")
    ):
        raise PreparedTextPackageError("foreign representation")


def encode_admission_bundle(
    manifest: bytes,
    representation: bytes,
) -> bytes:
    """Join and authenticate one manifest with its admitted representation."""

    package_facts = decode_manifest(manifest)
    representation_facts = decode_prepared_representation(representation)
    validate_prepared_representation(
        package_facts,
        representation_facts,
    )
    return manifest + representation


def decode_admission_bundle(encoded: bytes) -> dict[str, object]:
    """Decode both authenticated records in one fixed admission bundle."""

    if not isinstance(encoded, bytes) or len(encoded) != ADMISSION_BUNDLE_BYTES:
        raise PreparedTextPackageError("invalid admission bundle length")
    package_facts = decode_manifest(encoded[:MANIFEST_BYTES])
    representation_facts = decode_prepared_representation(encoded[MANIFEST_BYTES:])
    validate_prepared_representation(
        package_facts,
        representation_facts,
    )
    return {
        "encoded": encoded,
        "package": package_facts,
        "representation": representation_facts,
    }


def raw_text_sha256(raw_text: bytes) -> bytes:
    if not isinstance(raw_text, bytes) or not raw_text:
        raise PreparedTextPackageError("invalid raw text")
    return _sha(RAW_TEXT_DOMAIN, _u64(len(raw_text)), raw_text)


def token_ids_sha256(raw_text: bytes) -> bytes:
    if not isinstance(raw_text, bytes) or not raw_text:
        raise PreparedTextPackageError("invalid token stream")
    return _sha(
        TOKEN_STREAM_DOMAIN,
        _u64(len(raw_text)),
        *(_u32(token) for token in raw_text),
    )


def prepared_prompt_sha256(raw_text: bytes) -> bytes:
    if not isinstance(raw_text, bytes) or not raw_text:
        raise PreparedTextPackageError("invalid prepared prompt")
    return _sha(
        PREPARED_PROMPT_DOMAIN,
        _u64(len(raw_text)),
        *(_u32(token) for token in raw_text),
    )


def archive_wire(
    *,
    package: bytes,
    representation: bytes,
    tokenizer_manifest: bytes,
    tokenizer_prompt: bytes,
    binding: bytes,
    raw_text: bytes,
) -> bytes:
    """Frame already encoded components and derive the archive footer."""

    expected_lengths = (
        (package, MANIFEST_BYTES),
        (representation, PREPARED_REPRESENTATION_BYTES),
        (tokenizer_manifest, raw_input.MANIFEST_BYTES),
        (tokenizer_prompt, raw_input.PROMPT_BYTES),
        (binding, raw_input.BINDING_BYTES),
    )
    if any(
        not isinstance(value, bytes) or len(value) != expected
        for value, expected in expected_lengths
    ):
        raise PreparedTextPackageError("invalid archive component")
    if (
        not isinstance(raw_text, bytes)
        or not raw_text
        or len(raw_text) > raw_input.MAX_INPUT_BYTES
    ):
        raise PreparedTextPackageError("invalid archive raw text")
    encoded_bytes = ARCHIVE_MINIMUM_BYTES + len(raw_text)
    body = bytearray(encoded_bytes - ARCHIVE_FOOTER_BYTES)
    body[0:8] = ARCHIVE_MAGIC
    struct.pack_into(
        "<QQQQQQQQQQQ",
        body,
        8,
        ARCHIVE_ABI,
        encoded_bytes,
        ALLOWED_FLAGS,
        ARCHIVE_HEADER_BYTES,
        ARCHIVE_FIXED_PAYLOAD_BYTES,
        len(raw_text),
        MANIFEST_BYTES,
        PREPARED_REPRESENTATION_BYTES,
        raw_input.MANIFEST_BYTES,
        raw_input.PROMPT_BYTES,
        raw_input.BINDING_BYTES,
    )
    body[PACKAGE_OFFSET:REPRESENTATION_OFFSET] = package
    body[REPRESENTATION_OFFSET:TOKENIZER_MANIFEST_OFFSET] = representation
    body[TOKENIZER_MANIFEST_OFFSET:TOKENIZER_PROMPT_OFFSET] = tokenizer_manifest
    body[TOKENIZER_PROMPT_OFFSET:RAW_BINDING_OFFSET] = tokenizer_prompt
    body[RAW_BINDING_OFFSET:RAW_TEXT_OFFSET] = binding
    body[RAW_TEXT_OFFSET:] = raw_text
    return bytes(body) + archive_sha256(bytes(body))


def decode_archive(encoded: bytes) -> dict[str, object]:
    """Authenticate an archive and reconstruct its byte-tokenized prompt."""

    if not isinstance(encoded, bytes) or len(encoded) < ARCHIVE_MINIMUM_BYTES + 1:
        raise PreparedTextPackageError("invalid archive length")
    body = encoded[:-ARCHIVE_FOOTER_BYTES]
    if (
        encoded[-ARCHIVE_FOOTER_BYTES:] != archive_sha256(body)
        or encoded[0:8] != ARCHIVE_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != ARCHIVE_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != len(encoded)
        or struct.unpack_from("<Q", encoded, 24)[0] != ALLOWED_FLAGS
        or struct.unpack_from("<Q", encoded, 32)[0] != ARCHIVE_HEADER_BYTES
        or struct.unpack_from("<Q", encoded, 40)[0] != ARCHIVE_FIXED_PAYLOAD_BYTES
        or struct.unpack_from("<Q", encoded, 56)[0] != MANIFEST_BYTES
        or struct.unpack_from("<Q", encoded, 64)[0] != PREPARED_REPRESENTATION_BYTES
        or struct.unpack_from("<Q", encoded, 72)[0] != raw_input.MANIFEST_BYTES
        or struct.unpack_from("<Q", encoded, 80)[0] != raw_input.PROMPT_BYTES
        or struct.unpack_from("<Q", encoded, 88)[0] != raw_input.BINDING_BYTES
        or any(encoded[96:ARCHIVE_HEADER_BYTES])
    ):
        raise PreparedTextPackageError("invalid archive wire")
    raw_text_bytes = struct.unpack_from("<Q", encoded, 48)[0]
    if (
        raw_text_bytes == 0
        or raw_text_bytes > raw_input.MAX_INPUT_BYTES
        or len(encoded) != ARCHIVE_MINIMUM_BYTES + raw_text_bytes
    ):
        raise PreparedTextPackageError("invalid archive bounds")

    package = decode_manifest(encoded[PACKAGE_OFFSET:REPRESENTATION_OFFSET])
    representation = decode_prepared_representation(
        encoded[REPRESENTATION_OFFSET:TOKENIZER_MANIFEST_OFFSET]
    )
    validate_prepared_representation(package, representation)
    try:
        tokenizer_manifest = raw_input.decode_manifest(
            encoded[TOKENIZER_MANIFEST_OFFSET:TOKENIZER_PROMPT_OFFSET]
        )
        tokenizer_prompt = raw_input.decode_prompt(
            encoded[TOKENIZER_PROMPT_OFFSET:RAW_BINDING_OFFSET]
        )
        binding = raw_input.decode_binding(encoded[RAW_BINDING_OFFSET:RAW_TEXT_OFFSET])
    except raw_input.RawInputError as error:
        raise PreparedTextPackageError("invalid raw-input component") from error
    raw_text = encoded[RAW_TEXT_OFFSET : RAW_TEXT_OFFSET + raw_text_bytes]
    try:
        raw_text.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise PreparedTextPackageError("invalid retained UTF-8") from error
    raw_root = raw_text_sha256(raw_text)
    token_root = token_ids_sha256(raw_text)
    prompt_root = prepared_prompt_sha256(raw_text)

    if (
        raw_text_bytes > tokenizer_manifest["max_input_bytes"]
        or tokenizer_prompt["raw_text_bytes"] != raw_text_bytes
        or tokenizer_prompt["token_count"] != raw_text_bytes
        or binding["prompt_bytes"] != raw_text_bytes
        or binding["prompt_tokens"] != raw_text_bytes
        or package["config"]["vocab"] != tokenizer_manifest["vocab_size"]
        or package["tokenizer_manifest_abi"] != raw_input.MANIFEST_ABI
        or package["tokenizer_manifest_bytes"] != raw_input.MANIFEST_BYTES
        or tokenizer_prompt["raw_text_sha256"] != raw_root
        or tokenizer_prompt["token_ids_sha256"] != token_root
        or tokenizer_prompt["tokenizer_domain_sha256"]
        != tokenizer_manifest["domain_sha256"]
        or tokenizer_prompt["tokenizer_config_sha256"]
        != tokenizer_manifest["config_sha256"]
        or binding["tokenizer_domain_sha256"] != tokenizer_manifest["domain_sha256"]
        or binding["tokenizer_config_sha256"] != tokenizer_manifest["config_sha256"]
        or binding["prompt_receipt_sha256"] != tokenizer_prompt["receipt_sha256"]
        or binding["raw_text_sha256"] != raw_root
        or binding["token_ids_sha256"] != token_root
        or binding["prepared_prompt_sha256"] != prompt_root
        or package["tokenizer_config_sha256"] != tokenizer_manifest["config_sha256"]
        or package["tokenizer_domain_sha256"] != tokenizer_manifest["domain_sha256"]
        or package["tokenizer_behavior_sha256"] != tokenizer_manifest["behavior_sha256"]
        or package["license_sha256"] != binding["artifact_license_sha256"]
    ):
        raise PreparedTextPackageError("archive context substitution")
    return {
        "encoded": encoded,
        "package": package,
        "representation": representation,
        "tokenizer_manifest": tokenizer_manifest,
        "tokenizer_prompt": tokenizer_prompt,
        "binding": binding,
        "raw_text": raw_text,
        "tokens": tuple(raw_text),
        "archive_sha256": encoded[-ARCHIVE_FOOTER_BYTES:],
    }
