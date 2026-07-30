#!/usr/bin/env python3
"""Canonical single-file publication container for native unary load evidence.

The container is deliberately independent of the producer and envelope
verifiers.  It binds one canonical JSON manifest to one opaque binary envelope
under a fixed header, a domain-separated publication identity, and a final
seal.  Callers must still apply the workload-specific semantic verifier to the
decoded manifest and envelope.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import stat
import struct
import tempfile
from typing import Any, Mapping


class PublicationError(ValueError):
    """The publication bytes, JSON manifest, or filesystem operation failed."""


PUBLICATION_MAGIC = b"GF1PUB01"
PUBLICATION_ABI = 0x4746_3150_0000_0001
PUBLICATION_FLAGS = 0

PUBLICATION_HEADER_STRUCT = struct.Struct("<8s6Q")
PUBLICATION_FOOTER_STRUCT = struct.Struct("<32s32s32s32s")
PUBLICATION_HEADER_BYTES = PUBLICATION_HEADER_STRUCT.size
PUBLICATION_FOOTER_BYTES = PUBLICATION_FOOTER_STRUCT.size

MAX_MANIFEST_BYTES = 1 * 1024 * 1024
MAX_ENVELOPE_BYTES = 64 * 1024 * 1024
MAX_PUBLICATION_BYTES = (
    PUBLICATION_HEADER_BYTES
    + MAX_MANIFEST_BYTES
    + MAX_ENVELOPE_BYTES
    + PUBLICATION_FOOTER_BYTES
)
READ_CHUNK_BYTES = 64 * 1024

PUBLICATION_IDENTITY_DOMAIN = (
    b"glacier-native-unary-server-load-publication-identity-v1\x00"
)
PUBLICATION_SEAL_DOMAIN = (
    b"glacier-native-unary-server-load-publication-seal-v1\x00"
)


@dataclass(frozen=True)
class PublicationBundle:
    """One verified structural publication and its retained identities."""

    envelope: bytes
    manifest: dict[str, Any]
    manifest_bytes: bytes
    envelope_sha256: bytes
    manifest_sha256: bytes
    publication_identity_sha256: bytes
    bundle_sha256: bytes


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise PublicationError(message)


def _normalize_json(value: Any, *, depth: int = 0) -> Any:
    _require(depth <= 256, "JSON nesting exceeds the fixed bound")
    if value is None or type(value) in (bool, int, str):
        return value
    if type(value) is float:
        _require(math.isfinite(value), "JSON contains a non-finite number")
        return value
    if isinstance(value, Mapping):
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            _require(type(key) is str, "JSON object keys must be strings")
            _require(key not in normalized, "JSON object key is duplicated")
            normalized[key] = _normalize_json(item, depth=depth + 1)
        return normalized
    if type(value) in (list, tuple):
        return [
            _normalize_json(item, depth=depth + 1)
            for item in value
        ]
    raise PublicationError(
        "value is not representable by the canonical JSON codec"
    )


def canonical_json_bytes(value: Any) -> bytes:
    """Encode one JSON value into the publication's canonical byte form."""

    normalized = _normalize_json(value)
    try:
        rendered = json.dumps(
            normalized,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (RecursionError, TypeError, ValueError) as error:
        raise PublicationError("canonical JSON encoding failed") from error
    try:
        encoded = (rendered + "\n").encode("ascii")
    except UnicodeEncodeError as error:
        raise PublicationError("canonical JSON is not ASCII") from error
    _require(
        0 < len(encoded) <= MAX_MANIFEST_BYTES,
        "canonical JSON exceeds the fixed byte bound",
    )
    return encoded


def canonical_json_sha256(value: Any, *, domain: bytes) -> bytes:
    """Hash canonical JSON under a caller-selected, domain-separated root."""

    _require(
        type(domain) is bytes and len(domain) > 0,
        "canonical JSON hash domain must be non-empty bytes",
    )
    digest = hashlib.sha256()
    digest.update(domain)
    digest.update(canonical_json_bytes(value))
    return digest.digest()


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise PublicationError("canonical JSON contains a duplicate key")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise PublicationError(
        "canonical JSON contains a non-finite number: %s" % value
    )


def _decode_canonical_manifest(encoded: bytes) -> dict[str, Any]:
    _require(type(encoded) is bytes, "manifest bytes must be bytes")
    _require(
        0 < len(encoded) <= MAX_MANIFEST_BYTES,
        "manifest length exceeds the fixed bound",
    )
    try:
        text = encoded.decode("ascii")
        restored = json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
        )
    except PublicationError:
        raise
    except (
        RecursionError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        ValueError,
    ) as error:
        raise PublicationError("manifest is not valid canonical JSON") from error
    _require(
        isinstance(restored, dict),
        "publication manifest must be a JSON object",
    )
    _require(
        canonical_json_bytes(restored) == encoded,
        "manifest JSON encoding is not canonical",
    )
    return restored


def _sha256(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def _publication_identity(
    header: bytes,
    manifest_sha256: bytes,
    envelope_sha256: bytes,
) -> bytes:
    digest = hashlib.sha256()
    digest.update(PUBLICATION_IDENTITY_DOMAIN)
    digest.update(header)
    digest.update(manifest_sha256)
    digest.update(envelope_sha256)
    return digest.digest()


def _publication_seal(
    header: bytes,
    manifest_bytes: bytes,
    envelope: bytes,
    footer_prefix: bytes,
) -> bytes:
    digest = hashlib.sha256()
    digest.update(PUBLICATION_SEAL_DOMAIN)
    digest.update(header)
    digest.update(manifest_bytes)
    digest.update(envelope)
    digest.update(footer_prefix)
    return digest.digest()


def encode_bundle(envelope: bytes, manifest: Mapping[str, Any]) -> bytes:
    """Encode one canonical manifest and opaque envelope as a publication."""

    _require(type(envelope) is bytes, "envelope must be bytes")
    _require(
        0 < len(envelope) <= MAX_ENVELOPE_BYTES,
        "envelope length exceeds the fixed bound",
    )
    _require(
        isinstance(manifest, Mapping),
        "publication manifest must be a mapping",
    )
    manifest_bytes = canonical_json_bytes(manifest)
    encoded_bytes = (
        PUBLICATION_HEADER_BYTES
        + len(manifest_bytes)
        + len(envelope)
        + PUBLICATION_FOOTER_BYTES
    )
    _require(
        encoded_bytes <= MAX_PUBLICATION_BYTES,
        "publication length exceeds the fixed bound",
    )
    header = PUBLICATION_HEADER_STRUCT.pack(
        PUBLICATION_MAGIC,
        PUBLICATION_ABI,
        encoded_bytes,
        PUBLICATION_FLAGS,
        len(manifest_bytes),
        len(envelope),
        PUBLICATION_FOOTER_BYTES,
    )
    envelope_sha256 = _sha256(envelope)
    manifest_sha256 = _sha256(manifest_bytes)
    identity = _publication_identity(
        header,
        manifest_sha256,
        envelope_sha256,
    )
    footer_prefix = envelope_sha256 + manifest_sha256 + identity
    seal = _publication_seal(
        header,
        manifest_bytes,
        envelope,
        footer_prefix,
    )
    return (
        header
        + manifest_bytes
        + envelope
        + PUBLICATION_FOOTER_STRUCT.pack(
            envelope_sha256,
            manifest_sha256,
            identity,
            seal,
        )
    )


def decode_bundle(encoded: bytes) -> PublicationBundle:
    """Fail closed unless every structural and cryptographic invariant holds."""

    _require(type(encoded) is bytes, "publication must be bytes")
    minimum_bytes = (
        PUBLICATION_HEADER_BYTES + 3 + 1 + PUBLICATION_FOOTER_BYTES
    )
    _require(
        minimum_bytes <= len(encoded) <= MAX_PUBLICATION_BYTES,
        "publication length is outside the fixed bounds",
    )
    try:
        (
            magic,
            abi,
            declared_bytes,
            flags,
            manifest_length,
            envelope_length,
            footer_length,
        ) = PUBLICATION_HEADER_STRUCT.unpack_from(encoded, 0)
    except struct.error as error:
        raise PublicationError("publication header is truncated") from error
    _require(magic == PUBLICATION_MAGIC, "publication magic mismatch")
    _require(abi == PUBLICATION_ABI, "publication ABI mismatch")
    _require(flags == PUBLICATION_FLAGS, "publication flags are unsupported")
    _require(
        footer_length == PUBLICATION_FOOTER_BYTES,
        "publication footer length mismatch",
    )
    _require(
        0 < manifest_length <= MAX_MANIFEST_BYTES,
        "manifest length exceeds the fixed bound",
    )
    _require(
        0 < envelope_length <= MAX_ENVELOPE_BYTES,
        "envelope length exceeds the fixed bound",
    )
    expected_bytes = (
        PUBLICATION_HEADER_BYTES
        + manifest_length
        + envelope_length
        + footer_length
    )
    _require(
        declared_bytes == expected_bytes == len(encoded),
        "publication length, truncation, or trailing bytes mismatch",
    )

    manifest_start = PUBLICATION_HEADER_BYTES
    manifest_end = manifest_start + manifest_length
    envelope_end = manifest_end + envelope_length
    manifest_bytes = encoded[manifest_start:manifest_end]
    envelope = encoded[manifest_end:envelope_end]
    try:
        (
            retained_envelope_sha256,
            retained_manifest_sha256,
            retained_identity,
            retained_seal,
        ) = PUBLICATION_FOOTER_STRUCT.unpack_from(encoded, envelope_end)
    except struct.error as error:
        raise PublicationError("publication footer is truncated") from error

    envelope_sha256 = _sha256(envelope)
    manifest_sha256 = _sha256(manifest_bytes)
    _require(
        hmac.compare_digest(
            retained_envelope_sha256,
            envelope_sha256,
        ),
        "envelope digest mismatch",
    )
    _require(
        hmac.compare_digest(
            retained_manifest_sha256,
            manifest_sha256,
        ),
        "manifest digest mismatch",
    )
    header = encoded[:PUBLICATION_HEADER_BYTES]
    identity = _publication_identity(
        header,
        manifest_sha256,
        envelope_sha256,
    )
    _require(
        hmac.compare_digest(retained_identity, identity),
        "publication identity mismatch",
    )
    footer_prefix = encoded[
        envelope_end : envelope_end + PUBLICATION_FOOTER_BYTES - 32
    ]
    seal = _publication_seal(
        header,
        manifest_bytes,
        envelope,
        footer_prefix,
    )
    _require(
        hmac.compare_digest(retained_seal, seal),
        "publication seal mismatch",
    )
    manifest = _decode_canonical_manifest(manifest_bytes)
    return PublicationBundle(
        envelope=envelope,
        manifest=manifest,
        manifest_bytes=manifest_bytes,
        envelope_sha256=envelope_sha256,
        manifest_sha256=manifest_sha256,
        publication_identity_sha256=identity,
        bundle_sha256=_sha256(encoded),
    )


def _absolute_path(path: str | os.PathLike[str]) -> Path:
    try:
        expanded = Path(path).expanduser()
    except (TypeError, ValueError) as error:
        raise PublicationError("publication path is invalid") from error
    return Path(os.path.abspath(os.fspath(expanded)))


def read_bundle(path: str | os.PathLike[str]) -> PublicationBundle:
    """Read one regular file with a hard byte bound, then verify it."""

    source = _absolute_path(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(source, flags)
    except OSError as error:
        raise PublicationError("publication file could not be opened") from error
    try:
        info_before = os.fstat(descriptor)
        _require(
            stat.S_ISREG(info_before.st_mode),
            "publication path is not a regular file",
        )
        _require(
            0 < info_before.st_size <= MAX_PUBLICATION_BYTES,
            "publication file length is outside the fixed bounds",
        )
        retained = bytearray()
        while len(retained) <= MAX_PUBLICATION_BYTES:
            remaining = MAX_PUBLICATION_BYTES + 1 - len(retained)
            chunk = os.read(
                descriptor,
                min(READ_CHUNK_BYTES, remaining),
            )
            if not chunk:
                break
            retained.extend(chunk)
        _require(
            len(retained) <= MAX_PUBLICATION_BYTES,
            "publication file exceeds the fixed byte bound",
        )
        info_after = os.fstat(descriptor)
        _require(
            info_before.st_dev == info_after.st_dev
            and info_before.st_ino == info_after.st_ino
            and info_before.st_size == info_after.st_size
            and info_before.st_mtime_ns == info_after.st_mtime_ns
            and len(retained) == info_after.st_size,
            "publication file changed while it was read",
        )
    except PublicationError:
        raise
    except OSError as error:
        raise PublicationError("publication file could not be read") from error
    finally:
        os.close(descriptor)
    return decode_bundle(bytes(retained))


def atomic_write(
    path: str | os.PathLike[str],
    data: bytes,
) -> None:
    """Verify and atomically replace one publication file in one directory."""

    decode_bundle(data)
    destination = _absolute_path(path)
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise PublicationError(
            "publication parent directory could not be created"
        ) from error

    temporary_name: str | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".%s." % destination.name,
            suffix=".tmp",
            dir=destination.parent,
        )
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, destination)
        temporary_name = None
    except OSError as error:
        raise PublicationError("publication atomic replacement failed") from error
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            except OSError:
                pass


__all__ = [
    "MAX_ENVELOPE_BYTES",
    "MAX_MANIFEST_BYTES",
    "MAX_PUBLICATION_BYTES",
    "PUBLICATION_ABI",
    "PUBLICATION_FOOTER_BYTES",
    "PUBLICATION_HEADER_BYTES",
    "PUBLICATION_MAGIC",
    "PublicationBundle",
    "PublicationError",
    "atomic_write",
    "canonical_json_bytes",
    "canonical_json_sha256",
    "decode_bundle",
    "encode_bundle",
    "read_bundle",
]
