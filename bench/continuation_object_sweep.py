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
COMMIT_GRANT_DOMAIN = b"glacier-continuation-store-sweep-commit-grant-v1\x00"
COMMIT_DOMAIN = b"glacier-continuation-store-sweep-commit-v1\x00"
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


def _validate_commit_grant(grant: Record) -> None:
    for name in (
        "authority_epoch",
        "max_freed_entries",
        "max_freed_bytes",
    ):
        _u64(grant[name])
    for name in (
        "tenant_scope_sha256",
        "bundle_sha256",
        "store_grant_sha256",
        "sweep_grant_sha256",
        "prepare_sha256",
        "expected_snapshot_sha256",
        "collection_plan_sha256",
        "challenge_sha256",
    ):
        _digest(grant[name])
    if (
        grant["authority_epoch"] == 0
        or grant["max_freed_entries"] == 0
        or grant["max_freed_bytes"] == 0
    ):
        raise SweepError("invalid sweep commit grant")


def commit_grant_root(grant: Record) -> bytes:
    _validate_commit_grant(grant)
    hasher = hashlib.sha256()
    for part in (
        COMMIT_GRANT_DOMAIN,
        _u64(grant["authority_epoch"]),
        grant["tenant_scope_sha256"],
        grant["bundle_sha256"],
        grant["store_grant_sha256"],
        grant["sweep_grant_sha256"],
        grant["prepare_sha256"],
        grant["expected_snapshot_sha256"],
        grant["collection_plan_sha256"],
        _u64(grant["max_freed_entries"]),
        _u64(grant["max_freed_bytes"]),
        grant["challenge_sha256"],
    ):
        hasher.update(part)
    return hasher.digest()


def commit_root(receipt: Record) -> bytes:
    hasher = hashlib.sha256()
    for part in (
        COMMIT_DOMAIN,
        receipt["commit_grant_sha256"],
        receipt["sweep_grant_sha256"],
        receipt["prepare_sha256"],
        receipt["collection_plan_sha256"],
        receipt["targets_sha256"],
        receipt["snapshot_before_sha256"],
        receipt["snapshot_after_sha256"],
        receipt["store_commit_sha256"],
        _u64(receipt["freed_entries"]),
        _u64(receipt["freed_payload_bytes"]),
        _u64(receipt["freed_index_bytes"]),
        _u64(receipt["freed_repair_count"]),
        _u64(receipt["allocator_deallocation_calls"]),
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


def _ensure_commit_grant(
    store: object_store.Store,
    sweep_grant: Record,
    sweep_grant_sha256: bytes,
    commit_grant: Record,
    journal: Record,
) -> bytes:
    root = commit_grant_root(commit_grant)
    if store.closed:
        raise SweepError("store closed")
    if (
        commit_grant["authority_epoch"] != store.grant["authority_epoch"]
        or commit_grant["tenant_scope_sha256"]
        != store.grant["tenant_scope_sha256"]
        or commit_grant["bundle_sha256"] != store.grant["bundle_sha256"]
        or commit_grant["store_grant_sha256"] != store.grant_sha256
    ):
        raise SweepError("sweep commit scope mismatch")
    if (
        commit_grant["sweep_grant_sha256"] != sweep_grant_sha256
        or commit_grant["prepare_sha256"] != journal["prepare_sha256"]
        or commit_grant["expected_snapshot_sha256"]
        != journal["snapshot_sha256"]
        or commit_grant["collection_plan_sha256"]
        != journal["collection_plan_sha256"]
        or commit_grant["max_freed_entries"]
        > sweep_grant["max_staged_entries"]
        or commit_grant["max_freed_bytes"]
        > sweep_grant["max_staged_bytes"]
    ):
        raise SweepError("sweep commit journal mismatch")
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


def commit(
    store: object_store.Store,
    sweep_grant: Record,
    commit_grant: Record,
    collection_grant: Record,
    root_references: list[Record],
    lease_receipts: list[Record],
    current: Record,
) -> tuple[Record, Record]:
    sweep_grant_sha256 = _ensure_grant(store, sweep_grant)
    _verify_prepared_journal(sweep_grant, sweep_grant_sha256, current)
    commit_grant_sha256 = _ensure_commit_grant(
        store,
        sweep_grant,
        sweep_grant_sha256,
        commit_grant,
        current,
    )
    if (
        collection_grant["expected_snapshot_sha256"]
        != current["snapshot_sha256"]
    ):
        raise SweepError("sweep commit journal mismatch")
    plan, decisions = collection.plan_collection(
        store,
        collection_grant,
        root_references,
        lease_receipts,
    )
    if (
        plan["plan_sha256"] != current["collection_plan_sha256"]
        or plan["plan_sha256"] != commit_grant["collection_plan_sha256"]
        or plan["snapshot_sha256"] != current["snapshot_sha256"]
    ):
        raise SweepError("sweep commit journal mismatch")
    targets = collection.canonical_roots(
        [
            decision["target"]
            for decision in decisions
            if decision["class"] == "collectible"
        ]
    )
    target_bytes = sum(target["byte_length"] for target in targets)
    _u64(target_bytes)
    if (
        len(targets) != current["staged_entries"]
        or target_bytes != current["staged_bytes"]
        or len(targets) != plan["collectible_entries"]
        or target_bytes != plan["collectible_bytes"]
    ):
        raise SweepError("sweep commit journal mismatch")
    if (
        len(targets) > commit_grant["max_freed_entries"]
        or target_bytes > commit_grant["max_freed_bytes"]
    ):
        raise SweepError("sweep commit budget exceeded")
    permit = {
        "authority_epoch": commit_grant["authority_epoch"],
        "tenant_scope_sha256": commit_grant["tenant_scope_sha256"],
        "bundle_sha256": commit_grant["bundle_sha256"],
        "store_grant_sha256": commit_grant["store_grant_sha256"],
        "expected_snapshot_sha256": commit_grant[
            "expected_snapshot_sha256"
        ],
        "authorization_sha256": commit_grant_sha256,
        "max_freed_entries": commit_grant["max_freed_entries"],
        "max_freed_bytes": commit_grant["max_freed_bytes"],
    }
    store_receipt = store.commit_retired(permit, targets)
    receipt = {
        "commit_grant_sha256": commit_grant_sha256,
        "sweep_grant_sha256": sweep_grant_sha256,
        "prepare_sha256": current["prepare_sha256"],
        "collection_plan_sha256": current["collection_plan_sha256"],
        "targets_sha256": store_receipt["targets_sha256"],
        "snapshot_before_sha256": store_receipt["snapshot_before_sha256"],
        "snapshot_after_sha256": store_receipt["snapshot_after_sha256"],
        "store_commit_sha256": store_receipt["commit_sha256"],
        "freed_entries": store_receipt["freed_entries"],
        "freed_payload_bytes": store_receipt["freed_payload_bytes"],
        "freed_index_bytes": store_receipt["freed_index_bytes"],
        "freed_repair_count": store_receipt["freed_repair_count"],
        "allocator_deallocation_calls": store_receipt[
            "allocator_deallocation_calls"
        ],
    }
    receipt["commit_sha256"] = commit_root(receipt)
    return receipt, store_receipt


def verify_commit_receipt(
    commit_grant: Record,
    receipt: Record,
    store_receipt: Record,
) -> None:
    commit_grant_sha256 = commit_grant_root(commit_grant)
    try:
        object_store.verify_retired_commit_receipt(store_receipt)
    except object_store.StoreError as exc:
        raise SweepError("invalid sweep commit receipt") from exc
    if (
        receipt["commit_grant_sha256"] != commit_grant_sha256
        or receipt["sweep_grant_sha256"]
        != commit_grant["sweep_grant_sha256"]
        or receipt["prepare_sha256"] != commit_grant["prepare_sha256"]
        or receipt["collection_plan_sha256"]
        != commit_grant["collection_plan_sha256"]
        or receipt["snapshot_before_sha256"]
        != commit_grant["expected_snapshot_sha256"]
        or store_receipt["authorization_sha256"] != commit_grant_sha256
        or store_receipt["commit_sha256"]
        != object_store.retired_commit_receipt_root(store_receipt)
        or receipt["targets_sha256"] != store_receipt["targets_sha256"]
        or receipt["snapshot_before_sha256"]
        != store_receipt["snapshot_before_sha256"]
        or receipt["snapshot_after_sha256"]
        != store_receipt["snapshot_after_sha256"]
        or receipt["store_commit_sha256"] != store_receipt["commit_sha256"]
        or receipt["freed_entries"] != store_receipt["freed_entries"]
        or receipt["freed_payload_bytes"]
        != store_receipt["freed_payload_bytes"]
        or receipt["freed_index_bytes"]
        != store_receipt["freed_index_bytes"]
        or receipt["freed_repair_count"]
        != store_receipt["freed_repair_count"]
        or receipt["allocator_deallocation_calls"]
        != store_receipt["allocator_deallocation_calls"]
        or receipt["freed_entries"] > commit_grant["max_freed_entries"]
        or receipt["freed_payload_bytes"] > commit_grant["max_freed_bytes"]
        or receipt["commit_sha256"] != commit_root(receipt)
    ):
        raise SweepError("invalid sweep commit receipt")


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


def demo_commit_grant(
    store: object_store.Store,
    sweep_grant: Record,
    prepared: Record,
) -> Record:
    return {
        "authority_epoch": store.grant["authority_epoch"],
        "tenant_scope_sha256": store.grant["tenant_scope_sha256"],
        "bundle_sha256": store.grant["bundle_sha256"],
        "store_grant_sha256": store.grant_sha256,
        "sweep_grant_sha256": grant_root(sweep_grant),
        "prepare_sha256": prepared["prepare_sha256"],
        "expected_snapshot_sha256": prepared["snapshot_sha256"],
        "collection_plan_sha256": prepared["collection_plan_sha256"],
        "max_freed_entries": 2,
        "max_freed_bytes": 128,
        "challenge_sha256": bytes((0xD7,)) * 32,
    }
