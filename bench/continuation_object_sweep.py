"""Independent model for capability-scoped object sweep journals."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_object_collection as collection
from bench import continuation_object_store as object_store


class SweepError(ValueError):
    """The sweep grant, evidence, or journal transition is invalid."""


Record = dict[str, Any]
ZERO_DIGEST = bytes(32)
GRANT_DOMAIN = b"glacier-continuation-store-sweep-grant-v1\x00"
PREPARE_DOMAIN = b"glacier-continuation-store-sweep-prepare-v1\x00"
ABORT_DOMAIN = b"glacier-continuation-store-sweep-abort-v1\x00"
JOURNAL_FIELDS = {
    "state",
    "sweep_grant_sha256",
    "collection_plan_sha256",
    "snapshot_sha256",
    "staged_entries",
    "staged_bytes",
    "prepare_sha256",
    "abort_sha256",
}


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise SweepError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise SweepError("invalid digest")
    return value


def empty_journal() -> Record:
    return {
        "state": "empty",
        "sweep_grant_sha256": ZERO_DIGEST,
        "collection_plan_sha256": ZERO_DIGEST,
        "snapshot_sha256": ZERO_DIGEST,
        "staged_entries": 0,
        "staged_bytes": 0,
        "prepare_sha256": ZERO_DIGEST,
        "abort_sha256": ZERO_DIGEST,
    }


def _validate_grant(grant: Record) -> None:
    _u64(grant["authority_epoch"])
    _u64(grant["max_staged_entries"])
    _u64(grant["max_staged_bytes"])
    for name in (
        "tenant_scope_sha256",
        "bundle_sha256",
        "store_grant_sha256",
        "expected_snapshot_sha256",
        "collection_plan_sha256",
        "challenge_sha256",
    ):
        _digest(grant[name])
    if (
        grant["authority_epoch"] == 0
        or grant["max_staged_entries"] == 0
        or grant["max_staged_bytes"] == 0
    ):
        raise SweepError("invalid sweep grant")


def grant_root(grant: Record) -> bytes:
    _validate_grant(grant)
    hasher = hashlib.sha256()
    for part in (
        GRANT_DOMAIN,
        _u64(grant["authority_epoch"]),
        grant["tenant_scope_sha256"],
        grant["bundle_sha256"],
        grant["store_grant_sha256"],
        grant["expected_snapshot_sha256"],
        grant["collection_plan_sha256"],
        _u64(grant["max_staged_entries"]),
        _u64(grant["max_staged_bytes"]),
        grant["challenge_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


def prepare_root(receipt: Record) -> bytes:
    hasher = hashlib.sha256()
    for part in (
        PREPARE_DOMAIN,
        receipt["sweep_grant_sha256"],
        receipt["collection_plan_sha256"],
        receipt["snapshot_sha256"],
        _u64(receipt["staged_entries"]),
        _u64(receipt["staged_bytes"]),
    ):
        hasher.update(part)
    return hasher.digest()


def abort_root(receipt: Record) -> bytes:
    hasher = hashlib.sha256()
    for part in (
        ABORT_DOMAIN,
        receipt["sweep_grant_sha256"],
        receipt["collection_plan_sha256"],
        receipt["snapshot_sha256"],
        _u64(receipt["staged_entries"]),
        _u64(receipt["staged_bytes"]),
        receipt["prepare_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


def _ensure_grant(store: object_store.Store, grant: Record) -> bytes:
    root = grant_root(grant)
    if store.closed:
        raise SweepError("store closed")
    if (
        grant["authority_epoch"] != store.grant["authority_epoch"]
        or grant["tenant_scope_sha256"]
        != store.grant["tenant_scope_sha256"]
        or grant["bundle_sha256"] != store.grant["bundle_sha256"]
        or grant["store_grant_sha256"] != store.grant_sha256
    ):
        raise SweepError("sweep scope mismatch")
    return root


def _ensure_empty_journal(journal: Record) -> None:
    if set(journal) != JOURNAL_FIELDS:
        raise SweepError("invalid sweep journal fields")
    if journal != empty_journal():
        if journal.get("state") != "empty":
            raise SweepError("sweep already prepared")
        raise SweepError("invalid empty sweep journal")


def _verify_prepared_journal(
    grant: Record,
    sweep_grant_sha256: bytes,
    journal: Record,
) -> None:
    if set(journal) != JOURNAL_FIELDS:
        raise SweepError("invalid sweep journal fields")
    if journal["state"] != "prepared":
        raise SweepError("sweep not prepared")
    if (
        journal["abort_sha256"] != ZERO_DIGEST
        or journal["staged_entries"] == 0
        or journal["staged_bytes"] == 0
        or journal["staged_entries"] > grant["max_staged_entries"]
        or journal["staged_bytes"] > grant["max_staged_bytes"]
        or journal["sweep_grant_sha256"] != sweep_grant_sha256
        or journal["collection_plan_sha256"]
        != grant["collection_plan_sha256"]
        or journal["snapshot_sha256"] != grant["expected_snapshot_sha256"]
    ):
        raise SweepError("invalid prepared sweep journal")
    if prepare_root(journal) != journal["prepare_sha256"]:
        raise SweepError("prepare root mismatch")


def verify_journal(grant: Record, journal: Record) -> None:
    sweep_grant_sha256 = grant_root(grant)
    if set(journal) != JOURNAL_FIELDS:
        raise SweepError("invalid sweep journal fields")
    if journal["state"] == "empty":
        _ensure_empty_journal(journal)
        return
    if journal["state"] == "prepared":
        _verify_prepared_journal(grant, sweep_grant_sha256, journal)
        return
    if journal["state"] != "aborted":
        raise SweepError("invalid sweep journal state")
    prepared = dict(journal)
    prepared["state"] = "prepared"
    prepared["abort_sha256"] = ZERO_DIGEST
    _verify_prepared_journal(grant, sweep_grant_sha256, prepared)
    if journal["abort_sha256"] == ZERO_DIGEST:
        raise SweepError("missing abort root")
    if abort_root(journal) != journal["abort_sha256"]:
        raise SweepError("abort root mismatch")


def prepare(
    store: object_store.Store,
    sweep_grant: Record,
    collection_grant: Record,
    root_references: list[Record],
    lease_receipts: list[Record],
    current: Record,
) -> tuple[Record, Record, Record]:
    _ensure_empty_journal(current)
    sweep_grant_sha256 = _ensure_grant(store, sweep_grant)
    if (
        collection_grant["expected_snapshot_sha256"]
        != sweep_grant["expected_snapshot_sha256"]
    ):
        raise SweepError("sweep snapshot mismatch")
    collection_receipt, _ = collection.plan_collection(
        store,
        collection_grant,
        root_references,
        lease_receipts,
    )
    if (
        collection_receipt["snapshot_sha256"]
        != sweep_grant["expected_snapshot_sha256"]
    ):
        raise SweepError("sweep snapshot mismatch")
    if (
        collection_receipt["plan_sha256"]
        != sweep_grant["collection_plan_sha256"]
    ):
        raise SweepError("sweep plan mismatch")
    if (
        collection_receipt["collectible_entries"] == 0
        or collection_receipt["collectible_bytes"] == 0
    ):
        raise SweepError("nothing to sweep")
    if (
        collection_receipt["collectible_entries"]
        > sweep_grant["max_staged_entries"]
        or collection_receipt["collectible_bytes"]
        > sweep_grant["max_staged_bytes"]
    ):
        raise SweepError("sweep budget exceeded")
    snapshot_after = store.audit_snapshot_root_v2()
    if snapshot_after != sweep_grant["expected_snapshot_sha256"]:
        raise SweepError("sweep snapshot mismatch")
    receipt = {
        "sweep_grant_sha256": sweep_grant_sha256,
        "collection_plan_sha256": collection_receipt["plan_sha256"],
        "snapshot_sha256": snapshot_after,
        "staged_entries": collection_receipt["collectible_entries"],
        "staged_bytes": collection_receipt["collectible_bytes"],
    }
    receipt["prepare_sha256"] = prepare_root(receipt)
    journal = {
        "state": "prepared",
        **receipt,
        "abort_sha256": ZERO_DIGEST,
    }
    return journal, receipt, collection_receipt


def abort(
    store: object_store.Store,
    sweep_grant: Record,
    current: Record,
) -> tuple[Record, Record]:
    sweep_grant_sha256 = _ensure_grant(store, sweep_grant)
    _verify_prepared_journal(sweep_grant, sweep_grant_sha256, current)
    snapshot = store.audit_snapshot_root_v2()
    if snapshot != sweep_grant["expected_snapshot_sha256"]:
        raise SweepError("sweep snapshot mismatch")
    receipt = {
        "sweep_grant_sha256": current["sweep_grant_sha256"],
        "collection_plan_sha256": current["collection_plan_sha256"],
        "snapshot_sha256": snapshot,
        "staged_entries": current["staged_entries"],
        "staged_bytes": current["staged_bytes"],
        "prepare_sha256": current["prepare_sha256"],
    }
    receipt["abort_sha256"] = abort_root(receipt)
    journal = dict(current)
    journal["state"] = "aborted"
    journal["abort_sha256"] = receipt["abort_sha256"]
    return journal, receipt


def demo_grant(
    store: object_store.Store,
    collection_plan_sha256: bytes,
) -> Record:
    return {
        "authority_epoch": store.grant["authority_epoch"],
        "tenant_scope_sha256": store.grant["tenant_scope_sha256"],
        "bundle_sha256": store.grant["bundle_sha256"],
        "store_grant_sha256": store.grant_sha256,
        "expected_snapshot_sha256": store.audit_snapshot_root_v2(),
        "collection_plan_sha256": collection_plan_sha256,
        "max_staged_entries": 2,
        "max_staged_bytes": 128,
        "challenge_sha256": bytes((0xD4,)) * 32,
    }
