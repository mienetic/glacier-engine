"""Independent scheduled-media pressure evidence oracle.

This module composes the retained deterministic workload replay with the
bounded image, audio, and video fixture/transform/publication rules.  It does
not call a native worker.  The resulting Evidence-v1 wire is therefore an
independent Python oracle for a native implementation.
"""

from __future__ import annotations

import hashlib
from copy import deepcopy
from typing import Any

from bench import media_contract as media
from bench import media_decode_fixture as fixture
from bench import media_runtime_txn as runtime
from bench import media_transform as transform
from bench import workload_pressure as workload

Record = dict[str, Any]


class ScheduledMediaPressureError(ValueError):
    """Raised when scheduled-media pressure evidence is not canonical."""


EVIDENCE_ABI = 0x4757504D00000001
EVIDENCE_MAGIC = b"GWPME1\x00\x00"
HEADER_BYTES = 288
ITEM_RECORD_BYTES = 288
EXECUTION_RECORD_BYTES = 992
SUMMARY_BYTES = 160
FOOTER_BYTES = 32

MAXIMUM_ITEMS = workload.MAXIMUM_ITEMS
MAXIMUM_EXECUTIONS = workload.MAXIMUM_ITEMS
ABSENT = workload.ABSENT_STEP
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
U32_MAX = (1 << 32) - 1

EVIDENCE_DOMAIN = b"glacier-scheduled-media-pressure-evidence-v1\x00"
ITEM_DOMAIN = b"glacier-scheduled-media-pressure-item-v1\x00"
EXECUTION_DOMAIN = b"glacier-scheduled-media-pressure-execution-v1\x00"
SUMMARY_DOMAIN = b"glacier-scheduled-media-pressure-summary-v1\x00"
RESOURCE_RECEIPT_DOMAIN = b"glacier-lane-weave-qos-resource-receipt-v1\x00"
RECORD_TAG = b"record\x00"
SECTION_TAG = b"section\x00"

CLAIM_FIELDS = runtime.CLAIM_FIELDS

ITEM_SCALAR_FIELDS = (
    "ordinal",
    "kind",
    "outcome",
    "action",
    "admitted_step",
    "terminal_step",
    "execution_index",
    "resource_bank_epoch",
    "resource_slot_index",
    "resource_generation",
    "resource_owner_key",
    "resource_integrity",
)
ITEM_DIGEST_FIELDS = (
    "item_sha256",
    "admission_trace_sha256",
    "terminal_trace_sha256",
    "resource_receipt_sha256",
)
EXECUTION_SCALAR_FIELDS = (
    "ordinal",
    "kind",
    "final_trace_index",
    "driver_step",
    "service_sequence",
    "logical_tick_before",
    "logical_tick_after",
    "remaining_before",
    "remaining_after",
    "wait_quanta",
    "request_epoch",
    "output_length",
    "mapping_count",
)
EXECUTION_DIGEST_FIELDS = (
    "item_sha256",
    "final_trace_sha256",
    "media_state_before_sha256",
    "media_state_after_sha256",
    "output_sha256",
)
SUMMARY_FIELDS = (
    "item_count",
    "execution_count",
    "admitted",
    "rejected",
    "completed",
    "cancelled",
    "timed_out",
    "image_executions",
    "audio_executions",
    "video_executions",
    "logical_units",
    "output_bytes",
    "publications",
    "closed_terminal_sessions",
    "maximum_live_receipts",
    "zero_orphan_ownership",
)

COMPLETED_ORDINALS = (1, 2, 6)


def _u64(value: int) -> bytes:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ScheduledMediaPressureError("expected unsigned integer")
    if not 0 <= value <= U64_MAX:
        raise ScheduledMediaPressureError("unsigned integer out of range")
    return value.to_bytes(8, "little")


def _u32(value: int) -> bytes:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ScheduledMediaPressureError("expected unsigned integer")
    if not 0 <= value <= U32_MAX:
        raise ScheduledMediaPressureError("unsigned integer out of range")
    return value.to_bytes(4, "little")


def _digest(value: bytes, *, zero_allowed: bool = True) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise ScheduledMediaPressureError("expected SHA-256 digest")
    if not zero_allowed and value == ZERO_DIGEST:
        raise ScheduledMediaPressureError("zero digest is not allowed")
    return value


def _sha(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _write_u64(output: bytearray, offset: int, value: int) -> None:
    output[offset : offset + 8] = _u64(value)


def _read_u64(encoded: bytes, offset: int) -> int:
    return int.from_bytes(encoded[offset : offset + 8], "little")


def _required_fields(
    value: Record,
    required: set[str],
    optional: set[str] | None = None,
) -> None:
    if not isinstance(value, dict):
        raise ScheduledMediaPressureError("expected record")
    allowed = required | (optional or set())
    if not required <= set(value) or not set(value) <= allowed:
        raise ScheduledMediaPressureError("invalid record fields")


def resource_receipt_sha256(receipt_value: Record) -> bytes:
    """Recompute LaneWeave's canonical ResourceBank receipt identity."""

    try:
        expected = runtime.resource_receipt(
            receipt_value["bank_epoch"],
            receipt_value["slot_index"],
            receipt_value["generation"],
            receipt_value["owner_key"],
            receipt_value["claim"],
        )
        if expected["integrity"] != receipt_value["integrity"]:
            raise ScheduledMediaPressureError("invalid resource integrity")
        claim = expected["claim"]
        return _sha(
            RESOURCE_RECEIPT_DOMAIN,
            _u64(expected["bank_epoch"]),
            _u32(expected["slot_index"]),
            _u64(expected["generation"]),
            _u64(expected["owner_key"]),
            *(_u64(claim[name]) for name in CLAIM_FIELDS),
            _u64(expected["integrity"]),
        )
    except (KeyError, TypeError, ValueError) as error:
        if isinstance(error, ScheduledMediaPressureError):
            raise
        raise ScheduledMediaPressureError("invalid resource receipt") from error


def _record_root(domain: bytes, body: bytes) -> bytes:
    return _sha(domain, RECORD_TAG, body)


def _section_root(domain: bytes, roots: list[bytes]) -> bytes:
    return _sha(
        domain,
        SECTION_TAG,
        _u64(len(roots)),
        *(_digest(root, zero_allowed=False) for root in roots),
    )


def _encode_item_record(value: Record) -> bytes:
    required = set(ITEM_SCALAR_FIELDS) | set(ITEM_DIGEST_FIELDS)
    _required_fields(value, required, {"record_sha256"})
    output = bytearray(ITEM_RECORD_BYTES)
    for index, field in enumerate(ITEM_SCALAR_FIELDS):
        _write_u64(output, index * 8, value[field])
    for index, field in enumerate(ITEM_DIGEST_FIELDS):
        start = 96 + index * 32
        output[start : start + 32] = _digest(value[field])
    root = _record_root(ITEM_DOMAIN, bytes(output[:256]))
    if "record_sha256" in value and value["record_sha256"] != root:
        raise ScheduledMediaPressureError("stale item record root")
    output[256:288] = root
    return bytes(output)


def _decode_item_record(encoded: bytes) -> Record:
    if len(encoded) != ITEM_RECORD_BYTES:
        raise ScheduledMediaPressureError("invalid item record length")
    if any(encoded[224:256]):
        raise ScheduledMediaPressureError("non-zero item reserved bytes")
    root = _record_root(ITEM_DOMAIN, encoded[:256])
    if encoded[256:288] != root:
        raise ScheduledMediaPressureError("invalid item record root")
    value: Record = {
        field: _read_u64(encoded, index * 8)
        for index, field in enumerate(ITEM_SCALAR_FIELDS)
    }
    value.update(
        {
            field: encoded[96 + index * 32 : 128 + index * 32]
            for index, field in enumerate(ITEM_DIGEST_FIELDS)
        }
    )
    value["record_sha256"] = root
    return value


def _encode_execution_record(value: Record) -> bytes:
    required = (
        set(EXECUTION_SCALAR_FIELDS)
        | set(EXECUTION_DIGEST_FIELDS)
        | {"execution_receipt"}
    )
    _required_fields(value, required, {"record_sha256"})
    output = bytearray(EXECUTION_RECORD_BYTES)
    for index, field in enumerate(EXECUTION_SCALAR_FIELDS):
        _write_u64(output, index * 8, value[field])
    for index, field in enumerate(EXECUTION_DIGEST_FIELDS):
        start = 104 + index * 32
        output[start : start + 32] = _digest(value[field])
    receipt = runtime.encode_receipt(value["execution_receipt"])
    if len(receipt) != runtime.RECEIPT_BYTES:
        raise ScheduledMediaPressureError("invalid execution receipt length")
    output[264:904] = receipt
    root = _record_root(EXECUTION_DOMAIN, bytes(output[:960]))
    if "record_sha256" in value and value["record_sha256"] != root:
        raise ScheduledMediaPressureError("stale execution record root")
    output[960:992] = root
    return bytes(output)


def _decode_execution_record(encoded: bytes) -> Record:
    if len(encoded) != EXECUTION_RECORD_BYTES:
        raise ScheduledMediaPressureError("invalid execution record length")
    if any(encoded[904:960]):
        raise ScheduledMediaPressureError("non-zero execution reserved bytes")
    root = _record_root(EXECUTION_DOMAIN, encoded[:960])
    if encoded[960:992] != root:
        raise ScheduledMediaPressureError("invalid execution record root")
    try:
        receipt = runtime.decode_receipt(encoded[264:904])
    except ValueError as error:
        raise ScheduledMediaPressureError("invalid execution receipt") from error
    value: Record = {
        field: _read_u64(encoded, index * 8)
        for index, field in enumerate(EXECUTION_SCALAR_FIELDS)
    }
    value.update(
        {
            field: encoded[104 + index * 32 : 136 + index * 32]
            for index, field in enumerate(EXECUTION_DIGEST_FIELDS)
        }
    )
    value["execution_receipt"] = receipt
    value["record_sha256"] = root
    return value


def _encode_summary(value: Record) -> bytes:
    _required_fields(value, set(SUMMARY_FIELDS), {"summary_sha256"})
    output = bytearray(SUMMARY_BYTES)
    for index, field in enumerate(SUMMARY_FIELDS):
        _write_u64(output, index * 8, value[field])
    root = _record_root(SUMMARY_DOMAIN, bytes(output[:128]))
    if "summary_sha256" in value and value["summary_sha256"] != root:
        raise ScheduledMediaPressureError("stale evidence summary root")
    output[128:160] = root
    return bytes(output)


def _decode_summary(encoded: bytes) -> Record:
    if len(encoded) != SUMMARY_BYTES:
        raise ScheduledMediaPressureError("invalid evidence summary length")
    root = _record_root(SUMMARY_DOMAIN, encoded[:128])
    if encoded[128:160] != root:
        raise ScheduledMediaPressureError("invalid evidence summary root")
    value: Record = {
        field: _read_u64(encoded, index * 8)
        for index, field in enumerate(SUMMARY_FIELDS)
    }
    value["summary_sha256"] = root
    return value


def _request_epoch(ordinal: int) -> int:
    identity = ordinal + 1
    if not 0 < identity <= U32_MAX:
        raise ScheduledMediaPressureError("invalid media request ordinal")
    return 0x4757504D00000000 | identity


def _validate_evidence_shape(value: Record) -> None:
    items = value["items"]
    executions = value["executions"]
    summary = value["summary"]
    admitted = rejected = completed = cancelled = timed_out = 0
    for index, item in enumerate(items):
        if (
            item["ordinal"] != index
            or item["kind"]
            not in (
                workload.MEDIA_IMAGE,
                workload.MEDIA_AUDIO,
                workload.MEDIA_VIDEO,
            )
            or item["outcome"]
            not in (
                workload.OUTCOME_COMPLETED,
                workload.OUTCOME_REJECTED,
                workload.OUTCOME_CANCELLED,
                workload.OUTCOME_TIMED_OUT,
            )
            or item["action"]
            not in (
                workload.ACTION_NONE,
                workload.ACTION_CANCEL,
                workload.ACTION_TIMEOUT,
            )
            or any(
                item[field] == ZERO_DIGEST
                for field in (
                    "item_sha256",
                    "admission_trace_sha256",
                    "terminal_trace_sha256",
                )
            )
        ):
            raise ScheduledMediaPressureError("invalid item evidence shape")
        has_receipt = (
            item["resource_bank_epoch"] != 0
            and item["resource_generation"] != 0
            and item["resource_owner_key"] != 0
            and item["resource_integrity"] != 0
            and item["resource_receipt_sha256"] != ZERO_DIGEST
        )
        if item["outcome"] == workload.OUTCOME_REJECTED:
            rejected += 1
            if (
                item["admitted_step"] != ABSENT
                or item["execution_index"] != ABSENT
                or item["action"] != workload.ACTION_NONE
                or has_receipt
                or any(item[field] for field in ITEM_SCALAR_FIELDS[7:])
                or item["resource_receipt_sha256"] != ZERO_DIGEST
            ):
                raise ScheduledMediaPressureError(
                    "rejected item has admitted ownership"
                )
        elif item["outcome"] == workload.OUTCOME_COMPLETED:
            admitted += 1
            completed += 1
            if (
                not has_receipt
                or item["action"] != workload.ACTION_NONE
                or item["execution_index"] >= len(executions)
            ):
                raise ScheduledMediaPressureError("completed item lacks execution")
        elif item["outcome"] == workload.OUTCOME_CANCELLED:
            admitted += 1
            cancelled += 1
            if (
                not has_receipt
                or item["action"] != workload.ACTION_CANCEL
                or item["execution_index"] != ABSENT
            ):
                raise ScheduledMediaPressureError("invalid cancelled item evidence")
        else:
            admitted += 1
            timed_out += 1
            if (
                not has_receipt
                or item["action"] != workload.ACTION_TIMEOUT
                or item["execution_index"] != ABSENT
            ):
                raise ScheduledMediaPressureError("invalid timed-out item evidence")

    kind_counts = {
        workload.MEDIA_IMAGE: 0,
        workload.MEDIA_AUDIO: 0,
        workload.MEDIA_VIDEO: 0,
    }
    logical_units = 0
    output_bytes = 0
    for index, execution in enumerate(executions):
        ordinal = execution["ordinal"]
        if (
            execution["kind"] not in kind_counts
            or execution["remaining_before"] != 1
            or execution["remaining_after"] != 0
            or execution["logical_tick_after"] != execution["logical_tick_before"] + 1
            or execution["service_sequence"] != execution["final_trace_index"]
            or execution["request_epoch"] != _request_epoch(ordinal)
            or execution["output_length"] == 0
            or execution["mapping_count"] == 0
            or any(execution[field] == ZERO_DIGEST for field in EXECUTION_DIGEST_FIELDS)
            or ordinal >= len(items)
        ):
            raise ScheduledMediaPressureError("invalid execution evidence shape")
        item = items[ordinal]
        receipt = execution["execution_receipt"]
        if (
            item["execution_index"] != index
            or item["kind"] != execution["kind"]
            or item["outcome"] != workload.OUTCOME_COMPLETED
            or item["item_sha256"] != execution["item_sha256"]
            or receipt["request_epoch"] != execution["request_epoch"]
            or receipt["output_bytes"] != execution["output_length"]
            or receipt["mapping_count"] != execution["mapping_count"]
            or receipt["output_sha256"] != execution["output_sha256"]
        ):
            raise ScheduledMediaPressureError(
                "execution record is not bound to its item"
            )
        kind_counts[execution["kind"]] += 1
        logical_units += receipt["logical_units"]
        output_bytes += execution["output_length"]
        if logical_units > U64_MAX or output_bytes > U64_MAX:
            raise ScheduledMediaPressureError("evidence summary overflow")

    expected_summary = {
        "item_count": len(items),
        "execution_count": len(executions),
        "admitted": admitted,
        "rejected": rejected,
        "completed": completed,
        "cancelled": cancelled,
        "timed_out": timed_out,
        "image_executions": kind_counts[workload.MEDIA_IMAGE],
        "audio_executions": kind_counts[workload.MEDIA_AUDIO],
        "video_executions": kind_counts[workload.MEDIA_VIDEO],
        "logical_units": logical_units,
        "output_bytes": output_bytes,
        "publications": len(executions),
        "closed_terminal_sessions": admitted,
    }
    if any(summary[field] != expected for field, expected in expected_summary.items()):
        raise ScheduledMediaPressureError("contradictory evidence summary")
    if summary["zero_orphan_ownership"] != 1:
        raise ScheduledMediaPressureError("evidence retains orphan ownership")


def _encode_header(
    header: Record,
    item_count: int,
    execution_count: int,
    item_root: bytes,
    execution_root: bytes,
    summary_root: bytes,
) -> bytes:
    required = {
        "scenario_sha256",
        "outcome_sha256",
        "trace_sha256",
        "workload_summary_sha256",
    }
    optional = {
        "flags",
        "item_count",
        "execution_count",
        "item_record_sha256",
        "execution_record_sha256",
        "evidence_summary_sha256",
    }
    _required_fields(header, required, optional)
    if header.get("flags", 0) != 0:
        raise ScheduledMediaPressureError("unsupported evidence flags")
    if header.get("item_count", item_count) != item_count:
        raise ScheduledMediaPressureError("item count mismatch")
    if header.get("execution_count", execution_count) != execution_count:
        raise ScheduledMediaPressureError("execution count mismatch")
    derived = (
        ("item_record_sha256", item_root),
        ("execution_record_sha256", execution_root),
        ("evidence_summary_sha256", summary_root),
    )
    for field, expected in derived:
        if field in header and header[field] != expected:
            raise ScheduledMediaPressureError(f"stale {field}")

    output = bytearray(HEADER_BYTES)
    output[:8] = EVIDENCE_MAGIC
    _write_u64(output, 8, EVIDENCE_ABI)
    _write_u64(output, 16, 0)
    _write_u64(output, 24, item_count)
    _write_u64(output, 32, execution_count)
    roots = (
        header["scenario_sha256"],
        header["outcome_sha256"],
        header["trace_sha256"],
        header["workload_summary_sha256"],
        item_root,
        execution_root,
        summary_root,
    )
    for index, root in enumerate(roots):
        start = 40 + index * 32
        output[start : start + 32] = _digest(root, zero_allowed=False)
    return bytes(output)


def encode_evidence(value: Record) -> bytes:
    """Encode and seal one canonical Evidence-v1 value."""

    _required_fields(
        value,
        {"header", "items", "executions", "summary"},
        {"evidence_sha256"},
    )
    items = value["items"]
    executions = value["executions"]
    if not isinstance(items, list) or not isinstance(executions, list):
        raise ScheduledMediaPressureError("invalid evidence record lists")
    if not 0 < len(items) <= MAXIMUM_ITEMS:
        raise ScheduledMediaPressureError("invalid item count")
    if not 0 <= len(executions) <= MAXIMUM_EXECUTIONS:
        raise ScheduledMediaPressureError("invalid execution count")
    if len(executions) > len(items):
        raise ScheduledMediaPressureError("execution count exceeds items")

    item_records = [_encode_item_record(record) for record in items]
    execution_records = [_encode_execution_record(record) for record in executions]
    summary = _encode_summary(value["summary"])
    item_root = _section_root(ITEM_DOMAIN, [record[256:288] for record in item_records])
    execution_root = _section_root(
        EXECUTION_DOMAIN,
        [record[960:992] for record in execution_records],
    )
    summary_root = summary[128:160]
    header = _encode_header(
        value["header"],
        len(items),
        len(executions),
        item_root,
        execution_root,
        summary_root,
    )
    body = header + b"".join(item_records) + b"".join(execution_records) + summary
    root = _sha(EVIDENCE_DOMAIN, body)
    if "evidence_sha256" in value and value["evidence_sha256"] != root:
        raise ScheduledMediaPressureError("stale evidence root")
    return body + root


def decode_evidence(encoded: bytes) -> Record:
    """Decode and structurally authenticate one canonical Evidence-v1 wire."""

    if not isinstance(encoded, bytes) or len(encoded) < (
        HEADER_BYTES + ITEM_RECORD_BYTES + SUMMARY_BYTES + FOOTER_BYTES
    ):
        raise ScheduledMediaPressureError("invalid evidence length")
    if encoded[:8] != EVIDENCE_MAGIC:
        raise ScheduledMediaPressureError("invalid evidence magic")
    if _read_u64(encoded, 8) != EVIDENCE_ABI:
        raise ScheduledMediaPressureError("unsupported evidence ABI")
    if _read_u64(encoded, 16) != 0:
        raise ScheduledMediaPressureError("unsupported evidence flags")
    item_count = _read_u64(encoded, 24)
    execution_count = _read_u64(encoded, 32)
    if not 0 < item_count <= MAXIMUM_ITEMS:
        raise ScheduledMediaPressureError("invalid item count")
    if not 0 <= execution_count <= MAXIMUM_EXECUTIONS:
        raise ScheduledMediaPressureError("invalid execution count")
    if execution_count > item_count:
        raise ScheduledMediaPressureError("execution count exceeds items")
    expected_length = (
        HEADER_BYTES
        + item_count * ITEM_RECORD_BYTES
        + execution_count * EXECUTION_RECORD_BYTES
        + SUMMARY_BYTES
        + FOOTER_BYTES
    )
    if len(encoded) != expected_length:
        raise ScheduledMediaPressureError("non-canonical evidence length")
    if any(encoded[264:288]):
        raise ScheduledMediaPressureError("non-zero header reserved bytes")

    roots = [encoded[40 + index * 32 : 72 + index * 32] for index in range(7)]
    if any(root == ZERO_DIGEST for root in roots):
        raise ScheduledMediaPressureError("zero evidence component root")
    header: Record = {
        "flags": 0,
        "item_count": item_count,
        "execution_count": execution_count,
        "scenario_sha256": roots[0],
        "outcome_sha256": roots[1],
        "trace_sha256": roots[2],
        "workload_summary_sha256": roots[3],
        "item_record_sha256": roots[4],
        "execution_record_sha256": roots[5],
        "evidence_summary_sha256": roots[6],
    }

    offset = HEADER_BYTES
    items = []
    for _ in range(item_count):
        items.append(_decode_item_record(encoded[offset : offset + ITEM_RECORD_BYTES]))
        offset += ITEM_RECORD_BYTES
    executions = []
    for _ in range(execution_count):
        executions.append(
            _decode_execution_record(encoded[offset : offset + EXECUTION_RECORD_BYTES])
        )
        offset += EXECUTION_RECORD_BYTES
    summary = _decode_summary(encoded[offset : offset + SUMMARY_BYTES])
    offset += SUMMARY_BYTES

    if header["item_record_sha256"] != _section_root(
        ITEM_DOMAIN, [record["record_sha256"] for record in items]
    ):
        raise ScheduledMediaPressureError("invalid item section root")
    if header["execution_record_sha256"] != _section_root(
        EXECUTION_DOMAIN,
        [record["record_sha256"] for record in executions],
    ):
        raise ScheduledMediaPressureError("invalid execution section root")
    if header["evidence_summary_sha256"] != summary["summary_sha256"]:
        raise ScheduledMediaPressureError("invalid summary binding")
    if (
        summary["item_count"] != item_count
        or summary["execution_count"] != execution_count
    ):
        raise ScheduledMediaPressureError("summary count mismatch")
    root = _sha(EVIDENCE_DOMAIN, encoded[:offset])
    if encoded[offset : offset + FOOTER_BYTES] != root:
        raise ScheduledMediaPressureError("invalid evidence root")
    value = {
        "header": header,
        "items": items,
        "executions": executions,
        "summary": summary,
        "evidence_sha256": root,
    }
    _validate_evidence_shape(value)
    return value


def _reconstruct_receipts(
    scenario: Record,
    result: Record,
) -> dict[int, Record]:
    items_by_ordinal = {item["ordinal"]: item for item in scenario["items"]}
    slots: list[int | None] = [None] * scenario["capacity"]
    receipts: dict[int, Record] = {}
    next_generation = 1
    for trace in result["trace"]:
        ordinal = trace["item_ordinal"]
        event_kind = trace["event_kind"]
        if event_kind == workload.EVENT_ADMISSION_ACCEPTED:
            if ordinal not in items_by_ordinal or ordinal in receipts:
                raise ScheduledMediaPressureError("invalid admitted item")
            try:
                slot_index = slots.index(None)
            except ValueError as error:
                raise ScheduledMediaPressureError(
                    "admission exceeds receipt slots"
                ) from error
            item = items_by_ordinal[ordinal]
            receipt = runtime.resource_receipt(
                scenario["bank_epoch"],
                slot_index,
                next_generation,
                item["resource_owner_key"],
                item["claim"],
            )
            receipts[ordinal] = receipt
            slots[slot_index] = ordinal
            next_generation += 1
        elif event_kind in (workload.EVENT_CANCEL, workload.EVENT_RETIRE):
            if ordinal not in receipts or ordinal not in slots:
                raise ScheduledMediaPressureError("terminal receipt mismatch")
            slots[slots.index(ordinal)] = None
    if any(slot is not None for slot in slots):
        raise ScheduledMediaPressureError("orphan resource receipt")
    return receipts


def _media_case(kind: int) -> Record:
    try:
        if kind == workload.MEDIA_IMAGE:
            spec = fixture.image_spec()
        elif kind == workload.MEDIA_AUDIO:
            spec = fixture.audio_spec()
        elif kind == workload.MEDIA_VIDEO:
            spec = fixture.video_spec()
        else:
            raise ScheduledMediaPressureError("unsupported media kind")
        encoded_fixture = fixture.encode_fixture(spec)
        parsed = fixture.parse_fixture(encoded_fixture)
        decode_plan = fixture.make_decode_plan(
            parsed,
            bytes((0xD1,)) * 32,
            bytes((0xE1,)) * 32,
        )
        encoded_decode_plan = fixture.encode_plan(decode_plan)
        decoded = bytearray(len(spec["payload"]))
        decode_receipt = fixture.decode_fixture(
            encoded_fixture,
            encoded_decode_plan,
            decoded,
        )
        if kind == workload.MEDIA_IMAGE:
            transform_plan = transform.make_image_plan(
                parsed,
                decode_receipt,
                1,
                0,
                1,
                2,
                2,
                2,
                1,
                1,
                bytes((0xF1,)) * 32,
                bytes((0xF2,)) * 32,
            )
        elif kind == workload.MEDIA_AUDIO:
            transform_plan = transform.make_audio_plan(
                parsed,
                decode_receipt,
                0,
                6,
                16_000,
                1,
                0,
                1,
                bytes((0xF1,)) * 32,
                bytes((0xF2,)) * 32,
            )
        else:
            transform_plan = transform.make_video_plan(
                parsed,
                decode_receipt,
                (1,),
                bytes((0xF1,)) * 32,
                bytes((0xF2,)) * 32,
            )
        encoded_transform_plan = transform.encode_plan(transform_plan)
        output = bytearray(transform_plan["output_bytes"])
        transform_receipt, mappings = transform.execute(
            encoded_fixture,
            encoded_decode_plan,
            encoded_transform_plan,
            output,
        )
        return {
            "encoded_fixture": encoded_fixture,
            "encoded_decode_plan": encoded_decode_plan,
            "encoded_transform_plan": encoded_transform_plan,
            "parsed_fixture": parsed,
            "transform_plan": transform_plan,
            "transform_receipt": transform_receipt,
            "output": bytes(output),
            "mappings": mappings,
        }
    except ValueError as error:
        if isinstance(error, ScheduledMediaPressureError):
            raise
        raise ScheduledMediaPressureError("media fixture replay failed") from error


def _execution_artifacts(
    scenario: Record,
    result: Record,
    receipts: dict[int, Record],
) -> list[Record]:
    items_by_ordinal = {item["ordinal"]: item for item in scenario["items"]}
    outcomes_by_ordinal = {
        outcome["ordinal"]: outcome for outcome in result["outcomes"]
    }
    completed = [
        outcome["ordinal"]
        for outcome in result["outcomes"]
        if outcome["kind"] == workload.OUTCOME_COMPLETED
    ]
    if tuple(completed) != COMPLETED_ORDINALS:
        raise ScheduledMediaPressureError("unsupported completed item set")

    artifacts = []
    for ordinal in completed:
        item = items_by_ordinal[ordinal]
        outcome = outcomes_by_ordinal[ordinal]
        matches = [
            (index, trace)
            for index, trace in enumerate(result["trace"])
            if trace["item_ordinal"] == ordinal
            and trace["event_kind"] == workload.EVENT_SERVICE
            and trace["remaining_after"] == 0
        ]
        if len(matches) != 1:
            raise ScheduledMediaPressureError("missing final service event")
        final_trace_index, final_trace = matches[0]
        if (
            final_trace["remaining_before"] != 1
            or final_trace["driver_step"] != outcome["terminal_step"]
            or final_trace_index + 1 >= len(result["trace"])
            or result["trace"][final_trace_index + 1]["event_kind"]
            != workload.EVENT_RETIRE
            or result["trace"][final_trace_index + 1]["record_sha256"]
            != outcome["terminal_trace_sha256"]
        ):
            raise ScheduledMediaPressureError("invalid final service ordering")

        media_case = _media_case(item["media_kind"])
        expected_claim = runtime.claim_for_execution(
            len(media_case["encoded_fixture"]),
            media_case["transform_plan"],
        )
        if expected_claim != item["claim"]:
            raise ScheduledMediaPressureError("media resource claim drift")
        request_epoch = _request_epoch(ordinal)
        state_before = media.initialize_publication_state(
            request_epoch,
            1,
            runtime.output_timeline_base(media_case["transform_plan"]),
            media_case["parsed_fixture"]["media_object_sha256"],
            bytes((0xA0 + ordinal,)) * 32,
        )
        execution_receipt, state_after = runtime.build_execution_receipt(
            state_before,
            media_case["encoded_fixture"],
            media_case["encoded_transform_plan"],
            media_case["transform_receipt"],
            media_case["output"],
            media_case["mappings"],
            receipts[ordinal],
        )
        runtime.verify_execution_receipt(
            state_before,
            media_case["encoded_fixture"],
            media_case["encoded_transform_plan"],
            media_case["transform_receipt"],
            media_case["output"],
            media_case["mappings"],
            execution_receipt,
        )
        artifacts.append(
            {
                **media_case,
                "ordinal": ordinal,
                "item": item,
                "outcome": outcome,
                "resource_receipt": receipts[ordinal],
                "request_epoch": request_epoch,
                "state_before": state_before,
                "state_after": state_after,
                "execution_receipt": execution_receipt,
                "final_trace_index": final_trace_index,
                "final_trace": final_trace,
            }
        )
    artifacts.sort(key=lambda value: value["final_trace_index"])
    if tuple(value["ordinal"] for value in artifacts) != COMPLETED_ORDINALS:
        raise ScheduledMediaPressureError("unexpected execution order")
    return artifacts


def reference_media_artifacts() -> list[Record]:
    """Return independently executed artifacts for the three completed items."""

    scenario = workload.reference_scenario()
    result = workload.replay_scenario(scenario)
    receipts = _reconstruct_receipts(scenario, result)
    return deepcopy(_execution_artifacts(scenario, result, receipts))


def build_reference_evidence() -> Record:
    """Build, seal, and decode the fixed mixed-media Evidence-v1 campaign."""

    scenario = workload.reference_scenario()
    result = workload.replay_scenario(scenario)
    workload.validate_result(scenario, result)
    receipts = _reconstruct_receipts(scenario, result)
    artifacts = _execution_artifacts(scenario, result, receipts)
    execution_index = {
        artifact["ordinal"]: index for index, artifact in enumerate(artifacts)
    }

    item_records: list[Record] = []
    for item, outcome in zip(scenario["items"], result["outcomes"]):
        ordinal = item["ordinal"]
        receipt = receipts.get(ordinal)
        if receipt is None:
            identity = {
                "resource_bank_epoch": 0,
                "resource_slot_index": 0,
                "resource_generation": 0,
                "resource_owner_key": 0,
                "resource_integrity": 0,
            }
            receipt_root = ZERO_DIGEST
        else:
            identity = {
                "resource_bank_epoch": receipt["bank_epoch"],
                "resource_slot_index": receipt["slot_index"],
                "resource_generation": receipt["generation"],
                "resource_owner_key": receipt["owner_key"],
                "resource_integrity": receipt["integrity"],
            }
            receipt_root = resource_receipt_sha256(receipt)
        item_records.append(
            {
                "ordinal": ordinal,
                "kind": item["media_kind"],
                "outcome": outcome["kind"],
                "action": outcome["terminal_action"],
                "admitted_step": outcome["admitted_step"],
                "terminal_step": outcome["terminal_step"],
                "execution_index": execution_index.get(ordinal, ABSENT),
                **identity,
                "item_sha256": workload.item_sha256(item),
                "admission_trace_sha256": outcome["admission_trace_sha256"],
                "terminal_trace_sha256": outcome["terminal_trace_sha256"],
                "resource_receipt_sha256": receipt_root,
            }
        )

    execution_records: list[Record] = []
    for artifact in artifacts:
        trace = artifact["final_trace"]
        item = artifact["item"]
        receipt = artifact["execution_receipt"]
        execution_records.append(
            {
                "ordinal": artifact["ordinal"],
                "kind": item["media_kind"],
                "final_trace_index": artifact["final_trace_index"],
                "driver_step": trace["driver_step"],
                "service_sequence": artifact["final_trace_index"],
                "logical_tick_before": trace["logical_tick_before"],
                "logical_tick_after": trace["logical_tick_after"],
                "remaining_before": trace["remaining_before"],
                "remaining_after": trace["remaining_after"],
                "wait_quanta": trace["wait_quanta"],
                "request_epoch": artifact["request_epoch"],
                "output_length": len(artifact["output"]),
                "mapping_count": len(artifact["mappings"]),
                "item_sha256": workload.item_sha256(item),
                "final_trace_sha256": trace["record_sha256"],
                "media_state_before_sha256": media.publication_state_root(
                    artifact["state_before"]
                ),
                "media_state_after_sha256": media.publication_state_root(
                    artifact["state_after"]
                ),
                "output_sha256": hashlib.sha256(artifact["output"]).digest(),
                "execution_receipt": receipt,
            }
        )

    summary = result["summary"]
    evidence_summary: Record = {
        "item_count": len(item_records),
        "execution_count": len(execution_records),
        "admitted": summary["admitted"],
        "rejected": summary["rejected"],
        "completed": summary["completed"],
        "cancelled": summary["cancelled"],
        "timed_out": summary["timed_out"],
        "image_executions": sum(
            record["kind"] == workload.MEDIA_IMAGE for record in execution_records
        ),
        "audio_executions": sum(
            record["kind"] == workload.MEDIA_AUDIO for record in execution_records
        ),
        "video_executions": sum(
            record["kind"] == workload.MEDIA_VIDEO for record in execution_records
        ),
        "logical_units": sum(
            record["execution_receipt"]["logical_units"] for record in execution_records
        ),
        "output_bytes": sum(record["output_length"] for record in execution_records),
        "publications": len(execution_records),
        "closed_terminal_sessions": summary["admitted"],
        "maximum_live_receipts": summary["maximum_live_receipts"],
        "zero_orphan_ownership": int(
            summary["zero_orphan_ownership"]
            and summary["final_active"] == 0
            and summary["final_active_reservations"] == 0
            and summary["final_committed_receipts"] == 0
        ),
    }
    value = {
        "header": {
            "scenario_sha256": workload.scenario_sha256(scenario),
            "outcome_sha256": workload.outcome_sha256(result["outcomes"]),
            "trace_sha256": workload.trace_sha256(result["trace"]),
            "workload_summary_sha256": workload.summary_sha256(summary),
        },
        "items": item_records,
        "executions": execution_records,
        "summary": evidence_summary,
    }
    return decode_evidence(encode_evidence(value))


def validate_reference_evidence(value: Record) -> Record:
    """Validate every field against an independent fixed-scenario replay."""

    try:
        actual = decode_evidence(encode_evidence(value))
        expected = build_reference_evidence()
    except ValueError as error:
        if isinstance(error, ScheduledMediaPressureError):
            raise
        raise ScheduledMediaPressureError("evidence validation failed") from error
    if actual != expected:
        raise ScheduledMediaPressureError(
            "evidence contradicts independent scheduled-media replay"
        )

    scenario = workload.reference_scenario()
    result = workload.replay_scenario(scenario)
    items_by_ordinal = {item["ordinal"]: item for item in scenario["items"]}
    receipts = _reconstruct_receipts(scenario, result)
    artifacts = {
        artifact["ordinal"]: artifact
        for artifact in _execution_artifacts(scenario, result, receipts)
    }
    for item_record in actual["items"]:
        ordinal = item_record["ordinal"]
        item = items_by_ordinal[ordinal]
        receipt = receipts.get(ordinal)
        if receipt is None:
            if (
                any(item_record[field] for field in ITEM_SCALAR_FIELDS[7:])
                or item_record["resource_receipt_sha256"] != ZERO_DIGEST
            ):
                raise ScheduledMediaPressureError(
                    "rejected item owns a resource receipt"
                )
        else:
            if item_record["resource_receipt_sha256"] != resource_receipt_sha256(
                receipt
            ):
                raise ScheduledMediaPressureError("resource receipt root drift")
            if receipt["claim"] != item["claim"]:
                raise ScheduledMediaPressureError("resource claim drift")
    for execution in actual["executions"]:
        artifact = artifacts[execution["ordinal"]]
        receipt = execution["execution_receipt"]
        runtime.verify_execution_receipt(
            artifact["state_before"],
            artifact["encoded_fixture"],
            artifact["encoded_transform_plan"],
            artifact["transform_receipt"],
            artifact["output"],
            artifact["mappings"],
            receipt,
        )
        if (
            receipt["resource_bank_epoch"] != artifact["resource_receipt"]["bank_epoch"]
            or receipt["resource_slot_index"]
            != artifact["resource_receipt"]["slot_index"]
            or receipt["resource_generation"]
            != artifact["resource_receipt"]["generation"]
            or receipt["resource_owner_key"]
            != artifact["resource_receipt"]["owner_key"]
            or receipt["resource_integrity"]
            != artifact["resource_receipt"]["integrity"]
            or receipt["claim"] != artifact["resource_receipt"]["claim"]
        ):
            raise ScheduledMediaPressureError(
                "execution uses a foreign resource receipt"
            )
    return actual
