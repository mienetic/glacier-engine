"""Independent codec and verifier for continuation sweep evidence records."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_object_store as object_store
from bench import continuation_object_sweep as sweep


class SweepRecordError(ValueError):
    """The record framing, chain, expectation, or embedded evidence is invalid."""


Record = dict[str, Any]
ZERO_DIGEST = bytes(32)
ABI_VERSION = 0x4743_5352_0000_0001
BODY_MAGIC = b"GCSWRB01"
COMMIT_MAGIC = b"GCSWRF01"
ALLOWED_FLAGS = 0
RECORD_DOMAIN = b"glacier-continuation-sweep-record-body-v1\x00"
ACCOUNTING_FIELDS = (
    "entry_count",
    "live_entries",
    "quarantined_entries",
    "retired_entries",
    "payload_bytes",
    "logical_index_bytes",
    "reference_count",
    "active_leases",
    "repair_count",
)
FREED_FIELDS = (
    "freed_entries",
    "freed_payload_bytes",
    "freed_index_bytes",
    "freed_repair_count",
    "allocator_deallocation_calls",
)
ACCOUNTING_BEFORE_OFFSET = 456
SEQUENCE_OFFSET = 40
BODY_PREFIX_BYTES = 704
BODY_BYTES = 736
COMMIT_FOOTER_BYTES = 48
ENCODED_BYTES = 784


def _u32(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise SweepRecordError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise SweepRecordError("u64 out of range")
    return struct.pack("<Q", value)


def _nonzero_digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise SweepRecordError("invalid digest")
    return value


def _chain_digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise SweepRecordError("invalid chain digest")
    return value


def _accounting_bytes(accounting: Record) -> bytes:
    try:
        return b"".join(_u64(accounting[name]) for name in ACCOUNTING_FIELDS)
    except KeyError as exc:
        raise SweepRecordError("missing accounting field") from exc


def record_root(prefix: bytes) -> bytes:
    if not isinstance(prefix, bytes) or len(prefix) != BODY_PREFIX_BYTES:
        raise SweepRecordError("invalid record prefix")
    return hashlib.sha256(RECORD_DOMAIN + prefix).digest()


def _validate_input(record: Record) -> None:
    try:
        record_epoch = record["record_epoch"]
        sequence = record["sequence"]
        previous = _chain_digest(record["previous_record_sha256"])
        _nonzero_digest(record["record_challenge_sha256"])
        commit_grant = record["commit_grant"]
        commit_receipt = record["commit_receipt"]
        store_receipt = record["store_receipt"]
        _u64(record_epoch)
        _u64(sequence)
    except KeyError as exc:
        raise SweepRecordError("missing sweep record field") from exc
    if record_epoch == 0 or sequence == 0:
        raise SweepRecordError("invalid record chain position")
    if (sequence == 1) != (previous == ZERO_DIGEST):
        raise SweepRecordError("invalid previous record root")
    try:
        sweep.verify_commit_receipt(
            commit_grant,
            commit_receipt,
            store_receipt,
        )
    except (KeyError, TypeError, sweep.SweepError) as exc:
        raise SweepRecordError("invalid embedded sweep evidence") from exc


def encode(record: Record) -> bytes:
    _validate_input(record)
    grant = record["commit_grant"]
    receipt = record["commit_receipt"]
    store_receipt = record["store_receipt"]
    try:
        parts = [
            BODY_MAGIC,
            _u64(ABI_VERSION),
            _u64(ENCODED_BYTES),
            _u32(ALLOWED_FLAGS),
            _u32(0),
            _u64(record["record_epoch"]),
            _u64(record["sequence"]),
            _chain_digest(record["previous_record_sha256"]),
            _nonzero_digest(record["record_challenge_sha256"]),
            _u64(grant["authority_epoch"]),
            _nonzero_digest(grant["tenant_scope_sha256"]),
            _nonzero_digest(grant["bundle_sha256"]),
            _nonzero_digest(grant["store_grant_sha256"]),
            _nonzero_digest(grant["sweep_grant_sha256"]),
            _nonzero_digest(grant["prepare_sha256"]),
            _nonzero_digest(grant["expected_snapshot_sha256"]),
            _nonzero_digest(grant["collection_plan_sha256"]),
            _u64(grant["max_freed_entries"]),
            _u64(grant["max_freed_bytes"]),
            _nonzero_digest(grant["challenge_sha256"]),
            _nonzero_digest(receipt["targets_sha256"]),
            _nonzero_digest(receipt["snapshot_after_sha256"]),
            _accounting_bytes(store_receipt["accounting_before"]),
            _accounting_bytes(store_receipt["accounting_after"]),
            *(_u64(receipt[name]) for name in FREED_FIELDS),
            _nonzero_digest(store_receipt["commit_sha256"]),
            _nonzero_digest(receipt["commit_sha256"]),
        ]
    except KeyError as exc:
        raise SweepRecordError("missing embedded evidence field") from exc
    prefix = b"".join(parts)
    if len(prefix) != BODY_PREFIX_BYTES:
        raise SweepRecordError("record layout drift")
    root = record_root(prefix)
    encoded = b"".join(
        (
            prefix,
            root,
            COMMIT_MAGIC,
            _u64(record["sequence"]),
            root,
        )
    )
    if len(encoded) != ENCODED_BYTES:
        raise SweepRecordError("record length drift")
    return encoded


class _Reader:
    def __init__(self, encoded: bytes) -> None:
        self.encoded = encoded
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if length < 0 or end > len(self.encoded):
            raise SweepRecordError("truncated record")
        value = self.encoded[self.position : end]
        self.position = end
        return value

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> bytes:
        return self.take(32)

    def accounting(self) -> Record:
        return {name: self.u64() for name in ACCOUNTING_FIELDS}


def _decode(encoded: bytes) -> Record:
    if not isinstance(encoded, bytes) or len(encoded) != ENCODED_BYTES:
        raise SweepRecordError("invalid encoded length")
    reader = _Reader(encoded)
    if reader.take(len(BODY_MAGIC)) != BODY_MAGIC:
        raise SweepRecordError("invalid body magic")
    if reader.u64() != ABI_VERSION:
        raise SweepRecordError("invalid ABI")
    if reader.u64() != ENCODED_BYTES:
        raise SweepRecordError("invalid declared length")
    if reader.u32() != ALLOWED_FLAGS or reader.u32() != 0:
        raise SweepRecordError("invalid flags")

    record_epoch = reader.u64()
    sequence = reader.u64()
    previous_record_sha256 = reader.digest()
    record_challenge_sha256 = reader.digest()
    grant = {
        "authority_epoch": reader.u64(),
        "tenant_scope_sha256": reader.digest(),
        "bundle_sha256": reader.digest(),
        "store_grant_sha256": reader.digest(),
        "sweep_grant_sha256": reader.digest(),
        "prepare_sha256": reader.digest(),
        "expected_snapshot_sha256": reader.digest(),
        "collection_plan_sha256": reader.digest(),
        "max_freed_entries": reader.u64(),
        "max_freed_bytes": reader.u64(),
        "challenge_sha256": reader.digest(),
    }
    targets_sha256 = reader.digest()
    snapshot_after_sha256 = reader.digest()
    accounting_before = reader.accounting()
    accounting_after = reader.accounting()
    freed = {name: reader.u64() for name in FREED_FIELDS}
    store_commit_sha256 = reader.digest()
    sweep_commit_sha256 = reader.digest()
    if reader.position != BODY_PREFIX_BYTES:
        raise SweepRecordError("invalid body prefix length")

    stored_record_sha256 = reader.digest()
    computed_record_sha256 = record_root(encoded[:BODY_PREFIX_BYTES])
    if stored_record_sha256 != computed_record_sha256:
        raise SweepRecordError("body root mismatch")
    if reader.position != BODY_BYTES:
        raise SweepRecordError("invalid body length")
    if reader.take(len(COMMIT_MAGIC)) != COMMIT_MAGIC:
        raise SweepRecordError("invalid commit footer")
    if reader.u64() != sequence:
        raise SweepRecordError("commit sequence mismatch")
    if reader.digest() != stored_record_sha256 or reader.position != len(encoded):
        raise SweepRecordError("commit root mismatch")

    try:
        commit_grant_sha256 = sweep.commit_grant_root(grant)
    except (KeyError, TypeError, sweep.SweepError) as exc:
        raise SweepRecordError("invalid commit grant") from exc
    store_receipt = {
        "authorization_sha256": commit_grant_sha256,
        "targets_sha256": targets_sha256,
        "snapshot_before_sha256": grant["expected_snapshot_sha256"],
        "snapshot_after_sha256": snapshot_after_sha256,
        "accounting_before": accounting_before,
        "accounting_after": accounting_after,
        **freed,
        "commit_sha256": store_commit_sha256,
    }
    commit_receipt = {
        "commit_grant_sha256": commit_grant_sha256,
        "sweep_grant_sha256": grant["sweep_grant_sha256"],
        "prepare_sha256": grant["prepare_sha256"],
        "collection_plan_sha256": grant["collection_plan_sha256"],
        "targets_sha256": targets_sha256,
        "snapshot_before_sha256": grant["expected_snapshot_sha256"],
        "snapshot_after_sha256": snapshot_after_sha256,
        "store_commit_sha256": store_commit_sha256,
        **freed,
        "commit_sha256": sweep_commit_sha256,
    }
    record = {
        "record_epoch": record_epoch,
        "sequence": sequence,
        "previous_record_sha256": previous_record_sha256,
        "record_challenge_sha256": record_challenge_sha256,
        "commit_grant": grant,
        "commit_receipt": commit_receipt,
        "store_receipt": store_receipt,
    }
    _validate_input(record)
    return {"input": record, "record_sha256": stored_record_sha256}


def decode(encoded: bytes) -> Record:
    try:
        return _decode(encoded)
    except SweepRecordError:
        raise
    except (KeyError, TypeError, ValueError, struct.error) as exc:
        raise SweepRecordError("invalid sweep record") from exc


def expectation(record: Record, record_sha256: bytes) -> Record:
    _validate_input(record)
    expected = {
        "record_epoch": record["record_epoch"],
        "sequence": record["sequence"],
        "previous_record_sha256": record["previous_record_sha256"],
        "sweep_commit_sha256": record["commit_receipt"]["commit_sha256"],
        "record_sha256": _nonzero_digest(record_sha256),
    }
    _validate_expectation(expected)
    return expected


def _validate_expectation(expected: Record) -> None:
    try:
        record_epoch = expected["record_epoch"]
        sequence = expected["sequence"]
        previous = _chain_digest(expected["previous_record_sha256"])
        _nonzero_digest(expected["sweep_commit_sha256"])
        _nonzero_digest(expected["record_sha256"])
        _u64(record_epoch)
        _u64(sequence)
    except KeyError as exc:
        raise SweepRecordError("missing expectation field") from exc
    if record_epoch == 0 or sequence == 0:
        raise SweepRecordError("invalid expected chain position")
    if (sequence == 1) != (previous == ZERO_DIGEST):
        raise SweepRecordError("invalid expected previous root")


def decode_and_verify(encoded: bytes, expected: Record) -> Record:
    _validate_expectation(expected)
    decoded = decode(encoded)
    record = decoded["input"]
    if (
        record["record_epoch"] != expected["record_epoch"]
        or record["sequence"] != expected["sequence"]
        or record["previous_record_sha256"]
        != expected["previous_record_sha256"]
        or record["commit_receipt"]["commit_sha256"]
        != expected["sweep_commit_sha256"]
        or decoded["record_sha256"] != expected["record_sha256"]
    ):
        raise SweepRecordError("record expectation mismatch")
    return decoded


def append_plan(encoded: bytes) -> Record:
    decoded = decode(encoded)
    return {
        "body": encoded[:BODY_BYTES],
        "commit_footer": encoded[BODY_BYTES:],
        "record_sha256": decoded["record_sha256"],
    }


def origin_recovery_anchor(record_epoch: int = 0x5357_4545_5000_0001) -> Record:
    anchor = {
        "record_epoch": record_epoch,
        "next_sequence": 1,
        "previous_record_sha256": ZERO_DIGEST,
    }
    _validate_recovery_anchor(anchor)
    return anchor


def _validate_recovery_anchor(anchor: Record) -> None:
    try:
        record_epoch = anchor["record_epoch"]
        next_sequence = anchor["next_sequence"]
        previous = _chain_digest(anchor["previous_record_sha256"])
        _u64(record_epoch)
        _u64(next_sequence)
    except KeyError as exc:
        raise SweepRecordError("missing recovery anchor field") from exc
    if record_epoch == 0 or next_sequence == 0:
        raise SweepRecordError("invalid recovery anchor position")
    if (next_sequence == 1) != (previous == ZERO_DIGEST):
        raise SweepRecordError("invalid recovery anchor chain")


def _expected_footer(body: bytes) -> bytes:
    if not isinstance(body, bytes) or len(body) != BODY_BYTES:
        raise SweepRecordError("invalid recovery body")
    return b"".join(
        (
            COMMIT_MAGIC,
            body[SEQUENCE_OFFSET : SEQUENCE_OFFSET + 8],
            body[BODY_PREFIX_BYTES:BODY_BYTES],
        )
    )


def _decode_body_for_recovery(body: bytes) -> Record:
    return decode(body + _expected_footer(body))


def _recovery_classification(
    status: str,
    anchor: Record,
    last_sequence: int,
    committed_records: int,
    committed_bytes: int,
    tail_bytes: int,
    final_record_sha256: bytes,
) -> Record:
    return {
        "status": status,
        "record_epoch": anchor["record_epoch"],
        "first_sequence": anchor["next_sequence"],
        "last_sequence": last_sequence,
        "committed_records": committed_records,
        "committed_bytes": committed_bytes,
        "tail_bytes": tail_bytes,
        "final_record_sha256": final_record_sha256,
    }


def _recovery_record_matches(
    decoded: Record,
    record_epoch: int,
    sequence: int,
    previous_record_sha256: bytes,
) -> bool:
    value = decoded["input"]
    return (
        value["record_epoch"] == record_epoch
        and value["sequence"] == sequence
        and value["previous_record_sha256"] == previous_record_sha256
    )


def classify_recovery(stream: bytes, anchor: Record) -> Record:
    """Classify a record stream without modifying it or granting repair authority."""

    if not isinstance(stream, bytes):
        raise SweepRecordError("invalid recovery stream")
    _validate_recovery_anchor(anchor)
    offset = 0
    committed_records = 0
    expected_sequence = anchor["next_sequence"]
    expected_previous = anchor["previous_record_sha256"]
    last_sequence = expected_sequence - 1
    final_record_sha256 = expected_previous

    while len(stream) - offset >= ENCODED_BYTES:
        try:
            decoded = decode(stream[offset : offset + ENCODED_BYTES])
        except SweepRecordError:
            return _recovery_classification(
                "corrupt_record",
                anchor,
                last_sequence,
                committed_records,
                offset,
                len(stream) - offset,
                final_record_sha256,
            )
        if not _recovery_record_matches(
            decoded,
            anchor["record_epoch"],
            expected_sequence,
            expected_previous,
        ):
            return _recovery_classification(
                "corrupt_record",
                anchor,
                last_sequence,
                committed_records,
                offset,
                len(stream) - offset,
                final_record_sha256,
            )
        offset += ENCODED_BYTES
        committed_records += 1
        last_sequence = decoded["input"]["sequence"]
        final_record_sha256 = decoded["record_sha256"]
        expected_previous = final_record_sha256
        if offset < len(stream):
            if last_sequence == 0xFFFFFFFFFFFFFFFF:
                return _recovery_classification(
                    "corrupt_record",
                    anchor,
                    last_sequence,
                    committed_records,
                    offset,
                    len(stream) - offset,
                    final_record_sha256,
                )
            expected_sequence = last_sequence + 1

    tail_bytes = len(stream) - offset
    if tail_bytes == 0:
        return _recovery_classification(
            "clean",
            anchor,
            last_sequence,
            committed_records,
            offset,
            0,
            final_record_sha256,
        )
    if tail_bytes < BODY_BYTES:
        return _recovery_classification(
            "short_body_tail",
            anchor,
            last_sequence,
            committed_records,
            offset,
            tail_bytes,
            final_record_sha256,
        )

    body = stream[offset : offset + BODY_BYTES]
    try:
        decoded_body = _decode_body_for_recovery(body)
    except SweepRecordError:
        return _recovery_classification(
            "corrupt_record",
            anchor,
            last_sequence,
            committed_records,
            offset,
            tail_bytes,
            final_record_sha256,
        )
    if not _recovery_record_matches(
        decoded_body,
        anchor["record_epoch"],
        expected_sequence,
        expected_previous,
    ):
        return _recovery_classification(
            "corrupt_record",
            anchor,
            last_sequence,
            committed_records,
            offset,
            tail_bytes,
            final_record_sha256,
        )
    if tail_bytes == BODY_BYTES:
        return _recovery_classification(
            "body_without_footer",
            anchor,
            last_sequence,
            committed_records,
            offset,
            tail_bytes,
            final_record_sha256,
        )

    partial_footer = stream[offset + BODY_BYTES :]
    if partial_footer != _expected_footer(body)[: len(partial_footer)]:
        return _recovery_classification(
            "corrupt_record",
            anchor,
            last_sequence,
            committed_records,
            offset,
            tail_bytes,
            final_record_sha256,
        )
    return _recovery_classification(
        "partial_footer_tail",
        anchor,
        last_sequence,
        committed_records,
        offset,
        tail_bytes,
        final_record_sha256,
    )


def demo_input(commit_challenge: int = 0x6A, record_challenge: int = 0x6B) -> Record:
    def digest(byte: int) -> bytes:
        return bytes((byte,)) * 32

    grant = {
        "authority_epoch": 11,
        "tenant_scope_sha256": digest(0x61),
        "bundle_sha256": digest(0x62),
        "store_grant_sha256": digest(0x63),
        "sweep_grant_sha256": digest(0x64),
        "prepare_sha256": digest(0x65),
        "expected_snapshot_sha256": digest(0x66),
        "collection_plan_sha256": digest(0x67),
        "max_freed_entries": 2,
        "max_freed_bytes": 128,
        "challenge_sha256": digest(commit_challenge),
    }
    grant_sha256 = sweep.commit_grant_root(grant)
    store_receipt = {
        "authorization_sha256": grant_sha256,
        "targets_sha256": digest(0x68),
        "snapshot_before_sha256": grant["expected_snapshot_sha256"],
        "snapshot_after_sha256": digest(0x69),
        "accounting_before": {
            "entry_count": 8,
            "live_entries": 6,
            "quarantined_entries": 1,
            "retired_entries": 1,
            "payload_bytes": 255,
            "logical_index_bytes": 1024,
            "reference_count": 8,
            "active_leases": 1,
            "repair_count": 0,
        },
        "accounting_after": {
            "entry_count": 7,
            "live_entries": 6,
            "quarantined_entries": 1,
            "retired_entries": 0,
            "payload_bytes": 216,
            "logical_index_bytes": 896,
            "reference_count": 8,
            "active_leases": 1,
            "repair_count": 0,
        },
        "freed_entries": 1,
        "freed_payload_bytes": 39,
        "freed_index_bytes": 128,
        "freed_repair_count": 0,
        "allocator_deallocation_calls": 1,
    }
    store_receipt["commit_sha256"] = object_store.retired_commit_receipt_root(
        store_receipt
    )
    receipt = {
        "commit_grant_sha256": grant_sha256,
        "sweep_grant_sha256": grant["sweep_grant_sha256"],
        "prepare_sha256": grant["prepare_sha256"],
        "collection_plan_sha256": grant["collection_plan_sha256"],
        "targets_sha256": store_receipt["targets_sha256"],
        "snapshot_before_sha256": store_receipt["snapshot_before_sha256"],
        "snapshot_after_sha256": store_receipt["snapshot_after_sha256"],
        "store_commit_sha256": store_receipt["commit_sha256"],
        "freed_entries": 1,
        "freed_payload_bytes": 39,
        "freed_index_bytes": 128,
        "freed_repair_count": 0,
        "allocator_deallocation_calls": 1,
    }
    receipt["commit_sha256"] = sweep.commit_root(receipt)
    return {
        "record_epoch": 0x5357_4545_5000_0001,
        "sequence": 1,
        "previous_record_sha256": ZERO_DIGEST,
        "record_challenge_sha256": digest(record_challenge),
        "commit_grant": grant,
        "commit_receipt": receipt,
        "store_receipt": store_receipt,
    }
