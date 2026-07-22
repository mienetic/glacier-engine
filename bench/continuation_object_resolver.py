"""Independent capability and resolver model for continuation objects."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_capsule as capsule


class ResolverError(ValueError):
    """The grant, catalog, quota, or resolved composition is invalid."""


Record = dict[str, Any]
FULL_OBJECT_MASK = (1 << len(capsule.OBJECT_NAMES)) - 1
GRANT_DOMAIN = b"glacier-continuation-resolver-grant-v1\x00"


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise ResolverError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == bytes(32):
        raise ResolverError("invalid digest")
    return value


def _validate_grant(grant: Record) -> None:
    scalar_names = (
        "authority_epoch",
        "request_epoch",
        "allowed_kind_mask",
        "max_object_bytes",
        "max_total_bytes",
        "max_resolutions",
        "max_catalog_entries",
    )
    for name in scalar_names:
        _u64(grant[name])
    for name in (
        "capsule_sha256",
        "tenant_scope_sha256",
        "challenge_sha256",
    ):
        _digest(grant[name])
    mask = grant["allowed_kind_mask"]
    if (
        grant["authority_epoch"] == 0
        or grant["request_epoch"] == 0
        or mask == 0
        or mask & ~FULL_OBJECT_MASK
        or grant["max_object_bytes"] == 0
        or grant["max_total_bytes"] == 0
        or grant["max_catalog_entries"] == 0
        or grant["max_resolutions"] != bin(mask).count("1")
    ):
        raise ResolverError("invalid grant")


def grant_root(grant: Record) -> bytes:
    """Return the canonical audit identity for a locally trusted grant."""
    _validate_grant(grant)
    hasher = hashlib.sha256()
    for part in (
        GRANT_DOMAIN,
        _u64(grant["authority_epoch"]),
        _u64(grant["request_epoch"]),
        grant["capsule_sha256"],
        grant["tenant_scope_sha256"],
        _u64(grant["allowed_kind_mask"]),
        _u64(grant["max_object_bytes"]),
        _u64(grant["max_total_bytes"]),
        _u64(grant["max_resolutions"]),
        _u64(grant["max_catalog_entries"]),
        grant["challenge_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


class Resolver:
    """Allocation-model-independent conformance resolver.

    Python necessarily allocates objects; the native implementation owns the
    allocation-free runtime contract. This class independently checks identity,
    tenant, capability, quota, ambiguity, and final composition semantics.
    """

    def __init__(
        self,
        grant: Record,
        expected_authority_epoch: int,
        capsule_wire: bytes,
        catalog: list[Record],
    ) -> None:
        _validate_grant(grant)
        if grant["authority_epoch"] != expected_authority_epoch:
            raise ResolverError("stale grant")
        if len(catalog) > grant["max_catalog_entries"]:
            raise ResolverError("catalog limit exceeded")
        try:
            decoded = capsule.decode_manifest(capsule_wire)
        except capsule.CapsuleError as error:
            raise ResolverError("invalid capsule") from error
        if (
            decoded["envelope_sha256"] != grant["capsule_sha256"]
            or decoded["config"]["request_epoch"] != grant["request_epoch"]
        ):
            raise ResolverError("capsule mismatch")
        self.grant = dict(grant)
        self.grant_sha256 = grant_root(grant)
        self.capsule_wire = capsule_wire
        self.decoded = decoded
        self.catalog = list(catalog)
        self.resolved: dict[str, capsule.Object] = {}
        self.resolved_mask = 0
        self.resolved_bytes = 0
        self.resolution_count = 0
        self.finalized = False

    def resolve(self, name: str) -> bytes:
        """Resolve one exact object; failures leave accounting unchanged."""
        if self.finalized:
            raise ResolverError("finalized")
        try:
            index = capsule.OBJECT_NAMES.index(name)
        except ValueError as error:
            raise ResolverError("unknown object kind") from error
        bit = 1 << index
        if not self.grant["allowed_kind_mask"] & bit:
            raise ResolverError("denied kind")
        if name in self.resolved:
            raise ResolverError("already resolved")
        if self.resolution_count >= self.grant["max_resolutions"]:
            raise ResolverError("resolution limit")
        expected_ref = self.decoded["refs"][name]
        if expected_ref["byte_length"] > self.grant["max_object_bytes"]:
            raise ResolverError("object too large")
        next_total = self.resolved_bytes + expected_ref["byte_length"]
        if next_total > self.grant["max_total_bytes"]:
            raise ResolverError("total budget exceeded")

        matches = [
            entry
            for entry in self.catalog
            if entry["tenant_scope_sha256"]
            == self.grant["tenant_scope_sha256"]
            and entry["kind"] == name
            and entry["abi_version"] == expected_ref["abi_version"]
            and len(entry["payload"]) == expected_ref["byte_length"]
            and entry["sha256"] == expected_ref["sha256"]
        ]
        if not matches:
            raise ResolverError("object not found")
        if len(matches) != 1:
            raise ResolverError("ambiguous object")
        entry = matches[0]
        try:
            computed = capsule.object_ref(
                index,
                (entry["abi_version"], entry["payload"]),
            )
        except capsule.CapsuleError as error:
            raise ResolverError("corrupt object") from error
        if computed != expected_ref:
            raise ResolverError("corrupt object")

        # memoryview.tobytes() guarantees a distinct immutable caller result.
        output = memoryview(entry["payload"]).tobytes()
        self.resolved[name] = (entry["abi_version"], output)
        self.resolved_mask |= bit
        self.resolved_bytes = next_total
        self.resolution_count += 1
        return output

    def finish_full(self) -> dict[str, capsule.Object]:
        """Recheck all resolved bytes against the complete capsule."""
        if self.finalized:
            raise ResolverError("finalized")
        if (
            self.grant["allowed_kind_mask"] != FULL_OBJECT_MASK
            or self.resolved_mask != FULL_OBJECT_MASK
            or self.resolution_count != len(capsule.OBJECT_NAMES)
        ):
            raise ResolverError("incomplete")
        objects = dict(self.resolved)
        try:
            capsule.decode_and_verify(
                self.capsule_wire,
                self.decoded["config"],
                objects,
            )
        except capsule.CapsuleError as error:
            self.finalized = True
            raise ResolverError("resolved object changed") from error
        self.finalized = True
        return objects


def build_catalog(
    objects: dict[str, capsule.Object],
    tenant_scope_sha256: bytes,
) -> list[Record]:
    result: list[Record] = []
    for index, name in enumerate(capsule.OBJECT_NAMES):
        abi_version, payload = objects[name]
        reference = capsule.object_ref(index, objects[name])
        result.append(
            {
                "tenant_scope_sha256": tenant_scope_sha256,
                "kind": name,
                "abi_version": abi_version,
                "sha256": reference["sha256"],
                "payload": payload,
            }
        )
    return result


def demo_grant(bundle: Record) -> Record:
    return {
        "authority_epoch": 7,
        "request_epoch": bundle["config"]["request_epoch"],
        "capsule_sha256": bundle["encoded"][-32:],
        "tenant_scope_sha256": bytes((0x5C,)) * 32,
        "allowed_kind_mask": FULL_OBJECT_MASK,
        "max_object_bytes": 64,
        "max_total_bytes": sum(
            len(payload) for _, payload in bundle["objects"].values()
        ),
        "max_resolutions": len(capsule.OBJECT_NAMES),
        "max_catalog_entries": 16,
        "challenge_sha256": bytes((0xD4,)) * 32,
    }


def build_demo() -> Record:
    bundle = capsule.build_demo_bundle()
    grant = demo_grant(bundle)
    catalog = build_catalog(
        bundle["objects"],
        grant["tenant_scope_sha256"],
    )
    return {"bundle": bundle, "grant": grant, "catalog": catalog}
