"""Independent oracle for fixed media stream continuation checkpoints."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media
from bench import media_runtime_lease as lease
from bench import media_stream_runtime as stream


class MediaStreamContinuationError(ValueError):
    """A media stream checkpoint or retained output is invalid."""


Record = dict[str, Any]
CHECKPOINT_ABI = 0x474D534B00000001
CHECKPOINT_MAGIC = b"GMSKPT1\x00"
MAXIMUM_RETAINED_OUTPUTS = stream.MAXIMUM_STREAM_CHUNKS
CHECKPOINT_HEADER_BYTES = 480
CHECKPOINT_ENTRY_BYTES = 384
CHECKPOINT_BODY_BYTES = 2016
CHECKPOINT_BYTES = 2048
ALLOWED_FLAGS = 0
CHECKPOINT_DOMAIN = b"glacier-media-stream-checkpoint-v1\x00"
RETAINED_MANIFEST_DOMAIN = (
    b"glacier-media-stream-retained-manifest-v1\x00"
)
RESTORED_OWNERSHIP_DOMAIN = (
    b"glacier-media-stream-restored-ownership-v1\x00"
)
RESTORED_SCOPE_KEY_BASE = 0x6D73637300000000
RESTORED_ALLOCATION_KEY_BASE = 0x6D73636100000000
RESTORED_BINDING_KEY_BASE = 0x6D73636200000000
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
ROOT_FIELDS = (
    "media_object_sha256",
    "timeline_sha256",
    "previous_commit_sha256",
    "last_chunk_sha256",
    "challenge_sha256",
    "retained_manifest_sha256",
    "previous_checkpoint_sha256",
)
ENTRY_ROOT_FIELDS = (
    "output_sha256",
    "chunk_receipt_sha256",
    "lease_receipt_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaStreamContinuationError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise MediaStreamContinuationError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _claim(value: Record, *, allow_zero: bool = False) -> Record:
    try:
        result = {field: value[field] for field in lease.CLAIM_FIELDS}
    except (KeyError, TypeError):
        raise MediaStreamContinuationError("invalid claim") from None
    for field in lease.CLAIM_FIELDS:
        _u64(result[field])
    if not allow_zero and not any(result.values()):
        raise MediaStreamContinuationError("empty claim")
    return result


def _claim_bytes(value: Record) -> bytes:
    claim = _claim(value, allow_zero=True)
    return b"".join(_u64(claim[field]) for field in lease.CLAIM_FIELDS)


def _zero_claim() -> Record:
    return {field: 0 for field in lease.CLAIM_FIELDS}


def _entry_body(value: Record) -> bytes:
    entry = _entry(value)
    output = bytearray(CHECKPOINT_ENTRY_BYTES)
    scalars = (
        "chunk_index",
        "publication_sequence",
        "output_bytes",
        "source_bank_epoch",
        "source_receipt_slot_index",
        "source_receipt_generation",
        "source_owner_key",
        "restore_owner_key",
        "restore_tree_key",
        "restore_authority_key",
        "tenant_key",
        "scope_key",
        "allocation_key",
        "binding_key",
        "publication_next_sequence",
    )
    output[:120] = b"".join(_u64(entry[field]) for field in scalars)
    output[128:208] = _claim_bytes(entry["parent_claim"])
    output[208:288] = _claim_bytes(entry["output_claim"])
    for index, field in enumerate(ENTRY_ROOT_FIELDS):
        output[288 + index * 32 : 320 + index * 32] = entry[field]
    return bytes(output)


def _entry(value: Record) -> Record:
    scalar_fields = (
        "chunk_index",
        "publication_sequence",
        "output_bytes",
        "source_bank_epoch",
        "source_receipt_slot_index",
        "source_receipt_generation",
        "source_owner_key",
        "restore_owner_key",
        "restore_tree_key",
        "restore_authority_key",
        "tenant_key",
        "scope_key",
        "allocation_key",
        "binding_key",
        "publication_next_sequence",
    )
    try:
        result = {field: value[field] for field in scalar_fields}
        result["parent_claim"] = _claim(value["parent_claim"])
        result["output_claim"] = _claim(value["output_claim"])
        for field in ENTRY_ROOT_FIELDS:
            result[field] = _digest(value[field])
    except (KeyError, TypeError):
        raise MediaStreamContinuationError("invalid entry") from None
    for field in scalar_fields:
        _u64(result[field])
    expected_output_claim = _zero_claim()
    expected_output_claim["output_journal_bytes"] = result["output_bytes"]
    if (
        result["publication_sequence"] == 0
        or result["output_bytes"] == 0
        or result["source_bank_epoch"] == 0
        or result["source_receipt_generation"] == 0
        or result["source_owner_key"] == 0
        or result["restore_owner_key"] == 0
        or result["restore_tree_key"] == 0
        or result["restore_authority_key"] == 0
        or result["tenant_key"] == 0
        or result["scope_key"] == 0
        or result["allocation_key"] == 0
        or result["binding_key"] == 0
        or result["publication_next_sequence"] == 0
        or result["output_claim"] != expected_output_claim
    ):
        raise MediaStreamContinuationError("contradictory entry")
    return result


def retained_manifest_root(entries: list[Record]) -> bytes:
    if not 0 < len(entries) <= MAXIMUM_RETAINED_OUTPUTS:
        raise MediaStreamContinuationError("invalid retained count")
    return _hash(
        RETAINED_MANIFEST_DOMAIN,
        _u64(len(entries)),
        *(_entry_body(entry) for entry in entries),
    )


def restored_ownership_receipt_root(
    previous_checkpoint_sha256: bytes,
    prior: Record,
    successor: Record,
) -> bytes:
    previous_root = _digest(previous_checkpoint_sha256)
    prior_entry = _entry(prior)
    next_entry = _entry(successor)
    scalars = (
        "chunk_index",
        "publication_sequence",
        "output_bytes",
        "source_bank_epoch",
        "source_receipt_slot_index",
        "source_receipt_generation",
        "source_owner_key",
        "publication_next_sequence",
    )
    return _hash(
        RESTORED_OWNERSHIP_DOMAIN,
        *(_u64(next_entry[field]) for field in scalars),
        _claim_bytes(next_entry["parent_claim"]),
        _claim_bytes(next_entry["output_claim"]),
        previous_root,
        prior_entry["lease_receipt_sha256"],
        prior_entry["output_sha256"],
        prior_entry["chunk_receipt_sha256"],
        next_entry["output_sha256"],
        next_entry["chunk_receipt_sha256"],
    )


def _checkpoint(value: Record) -> Record:
    scalar_fields = (
        "kind",
        "request_epoch",
        "checkpoint_generation",
        "stream_key",
        "committed_chunks",
        "chunk_limit",
        "next_sequence",
        "visible_chunks",
        "visible_units",
        "timeline_numerator",
        "timeline_denominator",
        "restore_bank_epoch",
        "next_owner_key_base",
        "next_tree_key_base",
        "next_authority_key_base",
        "tenant_key",
    )
    try:
        result = {field: value[field] for field in scalar_fields}
        result["entries"] = [_entry(entry) for entry in value["entries"]]
        for field in ROOT_FIELDS:
            result[field] = _digest(
                value[field],
                allow_zero=field == "previous_checkpoint_sha256",
            )
        result["checkpoint_sha256"] = _digest(
            value["checkpoint_sha256"]
        )
    except (KeyError, TypeError):
        raise MediaStreamContinuationError("invalid checkpoint") from None
    for field in scalar_fields:
        _u64(result[field])
    entries = result["entries"]
    count = len(entries)
    if (
        result["kind"] not in (media.IMAGE, media.AUDIO, media.VIDEO)
        or result["request_epoch"] == 0
        or result["checkpoint_generation"] == 0
        or result["stream_key"] == 0
        or result["committed_chunks"] != count
        or not 0 < count < result["chunk_limit"]
        or result["chunk_limit"] > MAXIMUM_RETAINED_OUTPUTS
        or result["next_sequence"] == 0
        or result["visible_chunks"] != count
        or result["visible_units"] == 0
        or result["timeline_numerator"] == 0
        or result["timeline_denominator"] == 0
        or result["restore_bank_epoch"] == 0
        or result["next_owner_key_base"] == 0
        or result["next_tree_key_base"] == 0
        or result["next_authority_key_base"] == 0
        or result["tenant_key"] == 0
        or (
            result["checkpoint_generation"] == 1
            and result["previous_checkpoint_sha256"] != ZERO_DIGEST
        )
        or (
            result["checkpoint_generation"] != 1
            and result["previous_checkpoint_sha256"] == ZERO_DIGEST
        )
    ):
        raise MediaStreamContinuationError("contradictory checkpoint")
    source_bank_epoch = entries[0]["source_bank_epoch"]
    for index, entry in enumerate(entries):
        if (
            entry["chunk_index"] != index
            or entry["source_bank_epoch"] != source_bank_epoch
            or entry["source_bank_epoch"] == result["restore_bank_epoch"]
            or entry["tenant_key"] != result["tenant_key"]
            or (
                index
                and entry["publication_sequence"]
                != entries[index - 1]["publication_sequence"] + 1
            )
        ):
            raise MediaStreamContinuationError("entry sequence mismatch")
        for prior in entries[:index]:
            if (
                (
                    entry["source_receipt_slot_index"]
                    == prior["source_receipt_slot_index"]
                    and entry["source_receipt_generation"]
                    == prior["source_receipt_generation"]
                )
                or entry["restore_owner_key"] == prior["restore_owner_key"]
                or entry["restore_tree_key"] == prior["restore_tree_key"]
                or entry["restore_authority_key"]
                == prior["restore_authority_key"]
                or entry["scope_key"] == prior["scope_key"]
                or entry["allocation_key"] == prior["allocation_key"]
                or entry["binding_key"] == prior["binding_key"]
            ):
                raise MediaStreamContinuationError("duplicate identity")
    final = entries[-1]
    remaining = result["chunk_limit"] - result["committed_chunks"]
    for field in (
        "next_owner_key_base",
        "next_tree_key_base",
        "next_authority_key_base",
    ):
        _u64(result[field] + remaining - 1)
    if (
        final["publication_sequence"] + 1 != result["next_sequence"]
        or final["chunk_receipt_sha256"]
        != result["last_chunk_sha256"]
        or retained_manifest_root(entries)
        != result["retained_manifest_sha256"]
        or checkpoint_root(result) != result["checkpoint_sha256"]
    ):
        raise MediaStreamContinuationError("checkpoint root mismatch")
    return result


def _body(value: Record) -> bytes:
    checkpoint = dict(value)
    entries = [_entry(entry) for entry in checkpoint["entries"]]
    output = bytearray(CHECKPOINT_BODY_BYTES)
    output[:168] = b"".join(
        (
            CHECKPOINT_MAGIC,
            _u64(CHECKPOINT_ABI),
            _u64(CHECKPOINT_BYTES),
            _u64(ALLOWED_FLAGS),
            *(
                _u64(checkpoint[field])
                for field in (
                    "kind",
                    "request_epoch",
                    "checkpoint_generation",
                    "stream_key",
                    "committed_chunks",
                    "chunk_limit",
                    "next_sequence",
                    "visible_chunks",
                    "visible_units",
                    "timeline_numerator",
                    "timeline_denominator",
                )
            ),
            _u64(len(entries)),
            *(
                _u64(checkpoint[field])
                for field in (
                    "restore_bank_epoch",
                    "next_owner_key_base",
                    "next_tree_key_base",
                    "next_authority_key_base",
                    "tenant_key",
                )
            ),
        )
    )
    for index, field in enumerate(ROOT_FIELDS):
        output[192 + index * 32 : 224 + index * 32] = checkpoint[field]
    for index, entry in enumerate(entries):
        start = CHECKPOINT_HEADER_BYTES + index * CHECKPOINT_ENTRY_BYTES
        output[start : start + CHECKPOINT_ENTRY_BYTES] = _entry_body(entry)
    return bytes(output)


def checkpoint_root(value: Record) -> bytes:
    return _hash(CHECKPOINT_DOMAIN, _body(value))


def encode_checkpoint(value: Record) -> bytes:
    checkpoint = _checkpoint(value)
    return _body(checkpoint) + checkpoint["checkpoint_sha256"]


def decode_checkpoint(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != CHECKPOINT_BYTES
        or encoded[:8] != CHECKPOINT_MAGIC
        or _read(encoded, 8) != CHECKPOINT_ABI
        or _read(encoded, 16) != CHECKPOINT_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or any(encoded[168:192])
        or any(encoded[416:CHECKPOINT_HEADER_BYTES])
        or encoded[-32:] != _hash(CHECKPOINT_DOMAIN, encoded[:-32])
    ):
        raise MediaStreamContinuationError("invalid checkpoint wire")
    count = _read(encoded, 120)
    if count > MAXIMUM_RETAINED_OUTPUTS:
        raise MediaStreamContinuationError("invalid retained count")
    entries = []
    for index in range(MAXIMUM_RETAINED_OUTPUTS):
        start = CHECKPOINT_HEADER_BYTES + index * CHECKPOINT_ENTRY_BYTES
        record = encoded[start : start + CHECKPOINT_ENTRY_BYTES]
        if index >= count:
            if any(record):
                raise MediaStreamContinuationError("nonzero inactive entry")
            continue
        if any(record[120:128]):
            raise MediaStreamContinuationError("nonzero entry reserved bytes")
        entries.append(
            _entry(
                {
                    "chunk_index": _read(record, 0),
                    "publication_sequence": _read(record, 8),
                    "output_bytes": _read(record, 16),
                    "source_bank_epoch": _read(record, 24),
                    "source_receipt_slot_index": _read(record, 32),
                    "source_receipt_generation": _read(record, 40),
                    "source_owner_key": _read(record, 48),
                    "restore_owner_key": _read(record, 56),
                    "restore_tree_key": _read(record, 64),
                    "restore_authority_key": _read(record, 72),
                    "tenant_key": _read(record, 80),
                    "scope_key": _read(record, 88),
                    "allocation_key": _read(record, 96),
                    "binding_key": _read(record, 104),
                    "publication_next_sequence": _read(record, 112),
                    "parent_claim": {
                        field: _read(record, 128 + field_index * 8)
                        for field_index, field in enumerate(
                            lease.CLAIM_FIELDS
                        )
                    },
                    "output_claim": {
                        field: _read(record, 208 + field_index * 8)
                        for field_index, field in enumerate(
                            lease.CLAIM_FIELDS
                        )
                    },
                    **{
                        field: record[
                            288 + field_index * 32 :
                            320 + field_index * 32
                        ]
                        for field_index, field in enumerate(
                            ENTRY_ROOT_FIELDS
                        )
                    },
                }
            )
        )
    return _checkpoint(
        {
            "kind": _read(encoded, 32),
            "request_epoch": _read(encoded, 40),
            "checkpoint_generation": _read(encoded, 48),
            "stream_key": _read(encoded, 56),
            "committed_chunks": _read(encoded, 64),
            "chunk_limit": _read(encoded, 72),
            "next_sequence": _read(encoded, 80),
            "visible_chunks": _read(encoded, 88),
            "visible_units": _read(encoded, 96),
            "timeline_numerator": _read(encoded, 104),
            "timeline_denominator": _read(encoded, 112),
            "restore_bank_epoch": _read(encoded, 128),
            "next_owner_key_base": _read(encoded, 136),
            "next_tree_key_base": _read(encoded, 144),
            "next_authority_key_base": _read(encoded, 152),
            "tenant_key": _read(encoded, 160),
            **{
                field: encoded[
                    192 + field_index * 32 : 224 + field_index * 32
                ]
                for field_index, field in enumerate(ROOT_FIELDS)
            },
            "entries": entries,
            "checkpoint_sha256": encoded[-32:],
        }
    )


def make_checkpoint(
    state_after: Record,
    kind: int,
    stream_key: int,
    plan: Record,
    executions: list[Record],
    chunks: list[Record],
    outputs: list[bytes],
) -> Record:
    if (
        not executions
        or len(executions) != len(chunks)
        or len(executions) != len(outputs)
        or state_after["visible_chunks"] != len(executions)
    ):
        raise MediaStreamContinuationError("invalid checkpoint inputs")
    entries = []
    for index, (execution, chunk, output) in enumerate(
        zip(executions, chunks, outputs)
    ):
        execution = lease.decode_receipt(lease.encode_receipt(execution))
        chunk = stream.decode_receipt(stream.encode_receipt(chunk))
        parent = execution["tree"]["parent"]
        if (
            execution["kind"] != kind
            or chunk["kind"] != kind
            or len(output) != execution["output_bytes"]
            or hashlib.sha256(output).digest() != execution["output_sha256"]
            or parent["bank_epoch"] == plan["restore_bank_epoch"]
        ):
            raise MediaStreamContinuationError("invalid retained output")
        output_claim = _zero_claim()
        output_claim["output_journal_bytes"] = len(output)
        entries.append(
            {
                "chunk_index": chunk["stream_chunk_index"],
                "publication_sequence": chunk["publication_sequence"],
                "output_bytes": len(output),
                "source_bank_epoch": parent["bank_epoch"],
                "source_receipt_slot_index": parent["slot_index"],
                "source_receipt_generation": parent["generation"],
                "source_owner_key": parent["owner_key"],
                "restore_owner_key": plan["restore_owner_key_base"]
                + index,
                "restore_tree_key": plan["restore_tree_key_base"] + index,
                "restore_authority_key": (
                    plan["restore_authority_key_base"] + index
                ),
                "tenant_key": plan["tenant_key"],
                "scope_key": RESTORED_SCOPE_KEY_BASE + index,
                "allocation_key": RESTORED_ALLOCATION_KEY_BASE + index,
                "binding_key": RESTORED_BINDING_KEY_BASE + index,
                "publication_next_sequence": (
                    execution["resource_sequence"] + 1
                ),
                "parent_claim": parent["claim"],
                "output_claim": output_claim,
                "output_sha256": execution["output_sha256"],
                "chunk_receipt_sha256": chunk["receipt_sha256"],
                "lease_receipt_sha256": execution["receipt_sha256"],
            }
        )
    checkpoint = {
        "kind": kind,
        "request_epoch": state_after["request_epoch"],
        "checkpoint_generation": plan["checkpoint_generation"],
        "stream_key": stream_key,
        "committed_chunks": len(entries),
        "chunk_limit": plan["chunk_limit"],
        "next_sequence": state_after["next_sequence"],
        "visible_chunks": state_after["visible_chunks"],
        "visible_units": state_after["visible_units"],
        "timeline_numerator": state_after["timeline_base"][0],
        "timeline_denominator": state_after["timeline_base"][1],
        "restore_bank_epoch": plan["restore_bank_epoch"],
        "next_owner_key_base": plan["next_owner_key_base"],
        "next_tree_key_base": plan["next_tree_key_base"],
        "next_authority_key_base": plan["next_authority_key_base"],
        "tenant_key": plan["tenant_key"],
        "media_object_sha256": state_after["media_object_sha256"],
        "timeline_sha256": state_after["timeline_sha256"],
        "previous_commit_sha256": state_after["previous_commit_sha256"],
        "last_chunk_sha256": chunks[-1]["receipt_sha256"],
        "challenge_sha256": _digest(plan["challenge_sha256"]),
        "retained_manifest_sha256": retained_manifest_root(entries),
        "previous_checkpoint_sha256": _digest(
            plan.get("previous_checkpoint_sha256", ZERO_DIGEST),
            allow_zero=True,
        ),
        "entries": entries,
        "checkpoint_sha256": ZERO_DIGEST,
    }
    checkpoint["checkpoint_sha256"] = checkpoint_root(checkpoint)
    return _checkpoint(checkpoint)


def verify_materialized_outputs(
    checkpoint_value: Record,
    outputs: list[bytes],
) -> None:
    checkpoint = _checkpoint(checkpoint_value)
    if len(outputs) != len(checkpoint["entries"]):
        raise MediaStreamContinuationError("output count mismatch")
    for output, entry in zip(outputs, checkpoint["entries"]):
        if (
            len(output) != entry["output_bytes"]
            or hashlib.sha256(output).digest() != entry["output_sha256"]
        ):
            raise MediaStreamContinuationError("output mismatch")
