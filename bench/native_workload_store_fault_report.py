#!/usr/bin/env python3
"""Independent V1 codec for native workload campaign-store fault evidence.

The fixed wire binds one prepared selector transition to an ordered matrix of
deterministic errno injections and real process-signal observations.  It is an
evidence format only: decoding a report grants no store mutation, append, or
resume authority.
"""

from __future__ import annotations

import hashlib
import struct
from typing import Any, Iterable, Mapping, Sequence

from bench import native_workload_campaign as campaign


class StoreFaultReportError(ValueError):
    """The store-fault report is structurally or semantically invalid."""


Record = dict[str, Any]
Digest = bytes

REPORT_ABI = 0x4757_4652_0000_0001
CASE_ABI = 0x4757_4643_0000_0001

HEADER_SCALAR_COUNT = 24
HEADER_DIGEST_COUNT = 24
CASE_SCALAR_COUNT = 24
CASE_DIGEST_COUNT = 10

HEADER_BYTES = HEADER_SCALAR_COUNT * 8 + HEADER_DIGEST_COUNT * 32
SELECTOR_BYTES = campaign.SELECTOR_BYTES
CASE_BYTES = CASE_SCALAR_COUNT * 8 + CASE_DIGEST_COUNT * 32
FOOTER_BYTES = 64
FIXED_BYTES = HEADER_BYTES + 2 * SELECTOR_BYTES + FOOTER_BYTES
MAX_CASES = 128

ALLOWED_FLAGS = 0
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1

MATRIX_ID_DOMAIN = b"glacier-native-workload-store-fault-matrix-id-v1\x00"
FAILPOINT_DOMAIN = b"glacier-native-workload-store-fault-failpoint-v1\x00"
CASE_DOMAIN = b"glacier-native-workload-store-fault-case-v1\x00"
REPORT_BODY_DOMAIN = b"glacier-native-workload-store-fault-report-body-v1\x00"
REPORT_FOOTER_DOMAIN = b"glacier-native-workload-store-fault-report-footer-v1\x00"

OBJECT_SEGMENT = 1
OBJECT_ENVIRONMENT = 2
OBJECT_MANIFEST = 3
OBJECT_SELECTOR = 4
OBJECT_STORE_ROOT = 5
OBJECT_VALUES = frozenset(
    (
        OBJECT_SEGMENT,
        OBJECT_ENVIRONMENT,
        OBJECT_MANIFEST,
        OBJECT_SELECTOR,
        OBJECT_STORE_ROOT,
    )
)

OPERATION_CREATE = 1
OPERATION_WRITE = 2
OPERATION_FILE_SYNC = 3
OPERATION_LINK = 4
OPERATION_REPLACE = 5
OPERATION_DIRECTORY_SYNC = 6
OPERATION_UNLINK = 7
OPERATION_VALUES = frozenset(
    (
        OPERATION_CREATE,
        OPERATION_WRITE,
        OPERATION_FILE_SYNC,
        OPERATION_LINK,
        OPERATION_REPLACE,
        OPERATION_DIRECTORY_SYNC,
        OPERATION_UNLINK,
    )
)

TIMING_BEFORE = 1
TIMING_AFTER = 2
TIMING_VALUES = frozenset((TIMING_BEFORE, TIMING_AFTER))

FAULT_INJECTED_ERRNO = 1
FAULT_PARTIAL_WRITE_ERRNO = 2
FAULT_FORCED_SIGNAL = 3
FAULT_VALUES = frozenset(
    (
        FAULT_INJECTED_ERRNO,
        FAULT_PARTIAL_WRITE_ERRNO,
        FAULT_FORCED_SIGNAL,
    )
)

ERROR_NONE = 0
ERROR_IO = 1
ERROR_STORAGE_FULL = 2
ERROR_VALUES = frozenset((ERROR_NONE, ERROR_IO, ERROR_STORAGE_FULL))

ERROR_DOMAIN_NONE = 0
ERROR_DOMAIN_POSIX_ERRNO = 1
ERROR_DOMAIN_VALUES = frozenset((ERROR_DOMAIN_NONE, ERROR_DOMAIN_POSIX_ERRNO))

SELECTOR_STATE_BEFORE = 1
SELECTOR_STATE_AFTER = 2
SELECTOR_STATE_VALUES = frozenset((SELECTOR_STATE_BEFORE, SELECTOR_STATE_AFTER))

EXPECTED_BEFORE = 1
EXPECTED_AFTER = 2
EXPECTED_EITHER = EXPECTED_BEFORE | EXPECTED_AFTER
EXPECTED_STATE_VALUES = frozenset((EXPECTED_BEFORE, EXPECTED_AFTER, EXPECTED_EITHER))

RECOVERY_UNCHANGED_BEFORE = 1
RECOVERY_CLEANED_TO_BEFORE = 2
RECOVERY_UNCHANGED_AFTER = 3
RECOVERY_CLEANED_TO_AFTER = 4
RECOVERY_DISPOSITION_VALUES = frozenset(
    (
        RECOVERY_UNCHANGED_BEFORE,
        RECOVERY_CLEANED_TO_BEFORE,
        RECOVERY_UNCHANGED_AFTER,
        RECOVERY_CLEANED_TO_AFTER,
    )
)

POSIX_EIO = 5
POSIX_ENOSPC = 28
SIGNAL_KILL = 9
INJECTED_ERRNO_CHILD_EXIT = 74

PROVENANCE_HOST_FILESYSTEM = 1 << 0
PROVENANCE_CONTROLLED = 1 << 1
PROVENANCE_SYNTHETIC = 1 << 2
PROVENANCE_FRESH_RECOVERY = 1 << 3
PROVENANCE_REAL_OS_SIGNAL = 1 << 4
ERRNO_PROVENANCE_BITS = (
    PROVENANCE_HOST_FILESYSTEM
    | PROVENANCE_CONTROLLED
    | PROVENANCE_SYNTHETIC
    | PROVENANCE_FRESH_RECOVERY
)
SIGNAL_PROVENANCE_BITS = (
    PROVENANCE_HOST_FILESYSTEM
    | PROVENANCE_CONTROLLED
    | PROVENANCE_FRESH_RECOVERY
    | PROVENANCE_REAL_OS_SIGNAL
)

HEADER_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "case_count",
    "case_bytes",
    "selector_bytes",
    "generation_before",
    "generation_after",
    "failpoint_count",
    "errno_case_count",
    "signal_case_count",
    "expected_before_only_count",
    "expected_after_only_count",
    "expected_either_count",
    "observed_before_count",
    "observed_after_count",
    "recovered_before_count",
    "recovered_after_count",
    "synthetic_fault_count",
    "real_signal_count",
    "store_max_bytes",
    "store_max_files",
    "total_trigger_count",
    "reserved",
)

HEADER_DIGEST_FIELDS = (
    "matrix_challenge_sha256",
    "schedule_sha256",
    "matrix_id_sha256",
    "campaign_id_sha256",
    "plan_sha256",
    "manifest_before_sha256",
    "manifest_after_sha256",
    "selector_before_wire_sha256",
    "selector_after_wire_sha256",
    "canonical_store_before_sha256",
    "canonical_store_after_sha256",
    "transition_entry_sha256",
    "worker_sha256",
    "backend_library_sha256",
    "campaign_codec_sha256",
    "store_adapter_sha256",
    "fault_injector_sha256",
    "supervisor_sha256",
    "offline_verifier_sha256",
    "machine_sha256",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "filesystem_profile_sha256",
)

CASE_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "ordinal",
    "object_kind",
    "operation_kind",
    "timing",
    "occurrence",
    "fault_kind",
    "error_class",
    "native_error_domain",
    "native_error_code",
    "injected_signal",
    "bytes_requested",
    "bytes_completed",
    "child_exit_code_bits",
    "child_termination_signal",
    "provenance_bits",
    "expected_state_mask",
    "observed_selector_state",
    "recovered_selector_state",
    "recovery_disposition",
    "trigger_count",
    "reserved",
)

CASE_DIGEST_FIELDS = (
    "case_challenge_sha256",
    "failpoint_sha256",
    "observed_selector_wire_sha256",
    "raw_store_snapshot_sha256",
    "recovered_selector_wire_sha256",
    "recovered_store_snapshot_sha256",
    "fault_control_receipt_sha256",
    "recovery_result_sha256",
    "previous_case_sha256",
    "case_sha256",
)

_IMMUTABLE_OPERATIONS = frozenset(
    (
        OPERATION_CREATE,
        OPERATION_WRITE,
        OPERATION_FILE_SYNC,
        OPERATION_LINK,
        OPERATION_DIRECTORY_SYNC,
        OPERATION_UNLINK,
    )
)
_SELECTOR_OPERATIONS = frozenset(
    (
        OPERATION_CREATE,
        OPERATION_WRITE,
        OPERATION_FILE_SYNC,
        OPERATION_REPLACE,
    )
)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise StoreFaultReportError(message)


def _u64(value: Any, label: str) -> bytes:
    _require(
        isinstance(value, int) and not isinstance(value, bool),
        "%s is not an integer" % label,
    )
    _require(0 <= value <= U64_MAX, "%s is outside u64" % label)
    return struct.pack("<Q", value)


def _digest(value: Any, label: str) -> Digest:
    _require(
        isinstance(value, bytes) and len(value) == 32,
        "%s is not a 32-byte digest" % label,
    )
    return value


def _nonzero_digest(value: Any, label: str) -> Digest:
    result = _digest(value, label)
    _require(result != ZERO_DIGEST, "%s is zero" % label)
    return result


def _hash(domain: bytes, parts: Iterable[bytes]) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def encoded_report_bytes(case_count: int) -> int:
    _u64(case_count, "case_count")
    _require(
        0 < case_count <= MAX_CASES,
        "case_count is outside the report bound",
    )
    return FIXED_BYTES + case_count * CASE_BYTES


def _copy_fields(
    value: Mapping[str, Any],
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    label: str,
) -> Record:
    _require(isinstance(value, Mapping), "%s is not a mapping" % label)
    expected = set(scalar_fields) | set(digest_fields)
    _require(set(value) == expected, "%s fields are not canonical" % label)
    result: Record = {}
    for field in scalar_fields:
        _u64(value[field], "%s.%s" % (label, field))
        result[field] = value[field]
    for field in digest_fields:
        result[field] = _digest(
            value[field],
            "%s.%s" % (label, field),
        )
    return result


def _encode_fields(
    value: Mapping[str, Any],
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
) -> bytes:
    return b"".join(
        [_u64(value[field], field) for field in scalar_fields]
        + [_digest(value[field], field) for field in digest_fields]
    )


def _decode_fields(
    encoded: bytes,
    offset: int,
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
) -> tuple[Record, int]:
    result: Record = {}
    for field in scalar_fields:
        _require(offset + 8 <= len(encoded), "truncated scalar field")
        result[field] = struct.unpack_from("<Q", encoded, offset)[0]
        offset += 8
    for field in digest_fields:
        _require(offset + 32 <= len(encoded), "truncated digest field")
        result[field] = encoded[offset : offset + 32]
        offset += 32
    return result, offset


def _raw_sha256(value: bytes) -> Digest:
    return hashlib.sha256(value).digest()


def derive_matrix_id(
    header: Mapping[str, Any],
    selector_before_wire: bytes,
    selector_after_wire: bytes,
) -> Digest:
    checked = _copy_fields(
        header,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
        "header",
    )
    _require(
        isinstance(selector_before_wire, bytes)
        and len(selector_before_wire) == SELECTOR_BYTES,
        "selector_before wire length changed",
    )
    _require(
        isinstance(selector_after_wire, bytes)
        and len(selector_after_wire) == SELECTOR_BYTES,
        "selector_after wire length changed",
    )
    scalar_wire = b"".join(
        _u64(checked[field], "header.%s" % field) for field in HEADER_SCALAR_FIELDS
    )
    digest_wire = b"".join(
        checked[field] for index, field in enumerate(HEADER_DIGEST_FIELDS) if index != 2
    )
    return _hash(
        MATRIX_ID_DOMAIN,
        (
            scalar_wire,
            digest_wire,
            selector_before_wire,
            selector_after_wire,
        ),
    )


def derive_failpoint(
    matrix_id_sha256: Digest,
    case: Mapping[str, Any],
) -> Digest:
    checked = _copy_fields(
        case,
        CASE_SCALAR_FIELDS,
        CASE_DIGEST_FIELDS,
        "case",
    )
    return _hash(
        FAILPOINT_DOMAIN,
        (
            _nonzero_digest(matrix_id_sha256, "matrix_id_sha256"),
            *(
                _u64(checked[field], "case.%s" % field)
                for field in CASE_SCALAR_FIELDS[4:18]
            ),
        ),
    )


def derive_case_sha256(
    matrix_id_sha256: Digest,
    case: Mapping[str, Any],
) -> Digest:
    checked = _copy_fields(
        case,
        CASE_SCALAR_FIELDS,
        CASE_DIGEST_FIELDS,
        "case",
    )
    return _hash(
        CASE_DOMAIN,
        (
            _nonzero_digest(matrix_id_sha256, "matrix_id_sha256"),
            _encode_fields(checked, CASE_SCALAR_FIELDS, ()),
            _encode_fields(checked, (), CASE_DIGEST_FIELDS[:9]),
        ),
    )


def expected_state_mask(case: Mapping[str, Any]) -> int:
    checked = _copy_fields(
        case,
        CASE_SCALAR_FIELDS,
        CASE_DIGEST_FIELDS,
        "case",
    )
    object_kind = checked["object_kind"]
    operation_kind = checked["operation_kind"]
    timing = checked["timing"]
    fault_kind = checked["fault_kind"]
    if object_kind == OBJECT_SELECTOR and operation_kind == OPERATION_REPLACE:
        if timing == TIMING_BEFORE:
            return EXPECTED_BEFORE
        if fault_kind == FAULT_FORCED_SIGNAL:
            return EXPECTED_AFTER
        return EXPECTED_EITHER
    if object_kind == OBJECT_STORE_ROOT and operation_kind == OPERATION_DIRECTORY_SYNC:
        return EXPECTED_AFTER
    return EXPECTED_BEFORE


def _validate_object_operation(case: Mapping[str, Any]) -> None:
    object_kind = case["object_kind"]
    operation_kind = case["operation_kind"]
    _require(object_kind in OBJECT_VALUES, "invalid object kind")
    _require(operation_kind in OPERATION_VALUES, "invalid operation kind")
    if object_kind in (
        OBJECT_SEGMENT,
        OBJECT_ENVIRONMENT,
        OBJECT_MANIFEST,
    ):
        allowed = _IMMUTABLE_OPERATIONS
    elif object_kind == OBJECT_SELECTOR:
        allowed = _SELECTOR_OPERATIONS
    else:
        allowed = frozenset((OPERATION_DIRECTORY_SYNC,))
    _require(
        operation_kind in allowed,
        "operation is invalid for its object kind",
    )


def _validate_fault_semantics(case: Mapping[str, Any]) -> None:
    fault_kind = case["fault_kind"]
    error_class = case["error_class"]
    error_domain = case["native_error_domain"]
    error_code = case["native_error_code"]
    requested = case["bytes_requested"]
    completed = case["bytes_completed"]
    operation = case["operation_kind"]
    _require(fault_kind in FAULT_VALUES, "invalid fault kind")
    _require(error_class in ERROR_VALUES, "invalid error class")
    _require(
        error_domain in ERROR_DOMAIN_VALUES,
        "invalid native error domain",
    )
    if fault_kind in (
        FAULT_INJECTED_ERRNO,
        FAULT_PARTIAL_WRITE_ERRNO,
    ):
        _require(
            error_class in (ERROR_IO, ERROR_STORAGE_FULL),
            "errno fault has invalid error class",
        )
        _require(
            error_domain == ERROR_DOMAIN_POSIX_ERRNO,
            "errno fault lacks POSIX error domain",
        )
        expected_code = POSIX_EIO if error_class == ERROR_IO else POSIX_ENOSPC
        _require(
            error_code == expected_code,
            "errno fault code and class disagree",
        )
        _require(
            case["injected_signal"] == 0
            and case["child_exit_code_bits"] == INJECTED_ERRNO_CHILD_EXIT
            and case["child_termination_signal"] == 0,
            "errno child termination fields changed",
        )
        _require(
            case["provenance_bits"] == ERRNO_PROVENANCE_BITS,
            "errno provenance changed",
        )
        if operation == OPERATION_WRITE:
            _require(requested > 0, "write errno has no requested bytes")
            if fault_kind == FAULT_INJECTED_ERRNO:
                _require(
                    completed == 0,
                    "injected write errno completed bytes",
                )
            else:
                _require(
                    case["timing"] == TIMING_AFTER and 0 < completed < requested,
                    "partial write errno is not a strict after-write prefix",
                )
        else:
            _require(
                fault_kind == FAULT_INJECTED_ERRNO
                and requested == 0
                and completed == 0,
                "non-write errno carries byte progress",
            )
        return

    _require(
        error_class == ERROR_NONE
        and error_domain == ERROR_DOMAIN_NONE
        and error_code == 0,
        "forced signal carries errno fields",
    )
    _require(
        case["injected_signal"] == SIGNAL_KILL
        and case["child_exit_code_bits"] == U64_MAX
        and case["child_termination_signal"] == SIGNAL_KILL,
        "forced signal termination fields changed",
    )
    _require(
        case["provenance_bits"] == SIGNAL_PROVENANCE_BITS,
        "forced signal provenance changed",
    )
    _require(
        requested == 0 and completed == 0,
        "forced signal carries byte progress",
    )


def _selector_digest_for_state(
    header: Mapping[str, Any],
    state: int,
) -> Digest:
    if state == SELECTOR_STATE_BEFORE:
        return header["selector_before_wire_sha256"]
    return header["selector_after_wire_sha256"]


def _canonical_store_for_state(
    header: Mapping[str, Any],
    state: int,
) -> Digest:
    if state == SELECTOR_STATE_BEFORE:
        return header["canonical_store_before_sha256"]
    return header["canonical_store_after_sha256"]


def _validate_case(
    header: Mapping[str, Any],
    case: Mapping[str, Any],
    ordinal: int,
    previous_case_sha256: Digest,
) -> Record:
    checked = _copy_fields(
        case,
        CASE_SCALAR_FIELDS,
        CASE_DIGEST_FIELDS,
        "case",
    )
    _require(checked["abi_version"] == CASE_ABI, "invalid case ABI")
    _require(
        checked["encoded_bytes"] == CASE_BYTES,
        "invalid case encoded length",
    )
    _require(checked["flags"] == ALLOWED_FLAGS, "invalid case flags")
    _require(checked["ordinal"] == ordinal, "case ordinal changed")
    _require(checked["reserved"] == 0, "case reserved field is nonzero")
    _require(checked["timing"] in TIMING_VALUES, "invalid fault timing")
    _require(
        (
            checked["operation_kind"] == OPERATION_WRITE
            and checked["occurrence"] in (1, 2)
        )
        or (
            checked["operation_kind"] != OPERATION_WRITE and checked["occurrence"] == 1
        ),
        "fault occurrence is invalid for its operation",
    )
    _require(checked["trigger_count"] == 1, "case trigger count changed")
    _validate_object_operation(checked)
    _validate_fault_semantics(checked)
    expected = expected_state_mask(checked)
    _require(
        checked["expected_state_mask"] == expected,
        "expected selector-state mask changed",
    )
    observed = checked["observed_selector_state"]
    recovered = checked["recovered_selector_state"]
    _require(
        observed in SELECTOR_STATE_VALUES and recovered in SELECTOR_STATE_VALUES,
        "invalid observed or recovered selector state",
    )
    _require(
        expected & observed != 0,
        "observed selector state is outside the expected mask",
    )
    _require(
        recovered == SELECTOR_STATE_AFTER,
        "prepared recovery did not roll forward to the after selector",
    )
    disposition = checked["recovery_disposition"]
    _require(
        disposition in RECOVERY_DISPOSITION_VALUES,
        "invalid recovery disposition",
    )
    _require(
        disposition in (RECOVERY_UNCHANGED_AFTER, RECOVERY_CLEANED_TO_AFTER),
        "successful V1 report uses a reserved before disposition",
    )
    expected_observed_selector = _selector_digest_for_state(
        header,
        observed,
    )
    _require(
        checked["observed_selector_wire_sha256"] == expected_observed_selector,
        "observed selector wire does not match its state",
    )
    _require(
        checked["recovered_selector_wire_sha256"]
        == header["selector_after_wire_sha256"],
        "recovered selector wire is not the prepared after selector",
    )
    raw_store = checked["raw_store_snapshot_sha256"]
    recovered_store = checked["recovered_store_snapshot_sha256"]
    _nonzero_digest(raw_store, "case.raw_store_snapshot_sha256")
    _require(
        recovered_store == header["canonical_store_after_sha256"],
        "recovered store is not the canonical after state",
    )
    if disposition == RECOVERY_UNCHANGED_AFTER:
        _require(
            observed == SELECTOR_STATE_AFTER
            and raw_store == header["canonical_store_after_sha256"],
            "unchanged-after disposition has noncanonical raw state",
        )
    else:
        _require(
            raw_store != header["canonical_store_after_sha256"],
            "cleaned-to-after disposition did not change the raw store",
        )
    for field in (
        "case_challenge_sha256",
        "failpoint_sha256",
        "fault_control_receipt_sha256",
        "recovery_result_sha256",
        "case_sha256",
    ):
        _nonzero_digest(checked[field], "case.%s" % field)
    _require(
        checked["previous_case_sha256"] == previous_case_sha256,
        "case predecessor chain changed",
    )
    _require(
        checked["failpoint_sha256"]
        == derive_failpoint(header["matrix_id_sha256"], checked),
        "case failpoint root mismatch",
    )
    _require(
        checked["case_sha256"]
        == derive_case_sha256(header["matrix_id_sha256"], checked),
        "case root mismatch",
    )
    return checked


def _validate_header_base(header: Mapping[str, Any]) -> Record:
    checked = _copy_fields(
        header,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
        "header",
    )
    count = checked["case_count"]
    _require(checked["abi_version"] == REPORT_ABI, "invalid report ABI")
    _require(
        checked["encoded_bytes"] == encoded_report_bytes(count),
        "invalid report encoded length",
    )
    _require(checked["flags"] == ALLOWED_FLAGS, "invalid report flags")
    _require(checked["case_bytes"] == CASE_BYTES, "invalid case size")
    _require(
        checked["selector_bytes"] == SELECTOR_BYTES,
        "invalid selector size",
    )
    _require(
        checked["generation_after"] == checked["generation_before"] + 1,
        "report generations are not adjacent",
    )
    _require(
        checked["store_max_bytes"] > 0 and checked["store_max_files"] > 0,
        "store bound is zero",
    )
    _require(checked["reserved"] == 0, "report reserved field is nonzero")
    _require(
        checked["failpoint_count"] == count
        and checked["errno_case_count"] + checked["signal_case_count"] == count
        and checked["expected_before_only_count"]
        + checked["expected_after_only_count"]
        + checked["expected_either_count"]
        == count
        and checked["observed_before_count"] + checked["observed_after_count"] == count
        and checked["recovered_before_count"] == 0
        and checked["recovered_after_count"] == count
        and checked["synthetic_fault_count"] == checked["errno_case_count"]
        and checked["real_signal_count"] == checked["signal_case_count"]
        and checked["total_trigger_count"] == count,
        "report header counts are inconsistent",
    )
    sentinel_fields = {
        "matrix_id_sha256",
        "manifest_before_sha256",
        "selector_before_wire_sha256",
    }
    for field in HEADER_DIGEST_FIELDS:
        if checked["generation_before"] == 0 and field in sentinel_fields:
            continue
        _nonzero_digest(checked[field], "header.%s" % field)
    if checked["generation_before"] == 0:
        _require(
            checked["manifest_before_sha256"] == ZERO_DIGEST
            and checked["selector_before_wire_sha256"] == ZERO_DIGEST,
            "initial transition has a predecessor selector root",
        )
    else:
        _nonzero_digest(
            checked["manifest_before_sha256"],
            "header.manifest_before_sha256",
        )
        _nonzero_digest(
            checked["selector_before_wire_sha256"],
            "header.selector_before_wire_sha256",
        )
    _require(
        checked["manifest_before_sha256"] != checked["manifest_after_sha256"]
        and checked["canonical_store_before_sha256"]
        != checked["canonical_store_after_sha256"],
        "prepared transition does not change its manifest and store roots",
    )
    return checked


def _decode_campaign_selector(encoded: bytes, label: str) -> Record:
    try:
        return campaign.decode_selector(encoded)
    except campaign.CampaignManifestError as error:
        raise StoreFaultReportError("%s is invalid: %s" % (label, error)) from error


def _validate_header_selectors(
    header: Mapping[str, Any],
    selector_before_wire: bytes,
    selector_after_wire: bytes,
) -> None:
    _require(
        len(selector_before_wire) == SELECTOR_BYTES
        and len(selector_after_wire) == SELECTOR_BYTES,
        "selector wire length changed",
    )
    after = _decode_campaign_selector(
        selector_after_wire,
        "selector_after",
    )
    _require(
        after["generation"] == header["generation_after"],
        "after selector generation changed",
    )
    _require(
        after["manifest_sha256"] == header["manifest_after_sha256"],
        "after selector manifest root changed",
    )
    _require(
        _raw_sha256(selector_after_wire) == header["selector_after_wire_sha256"],
        "after selector wire root changed",
    )
    if header["generation_before"] == 0:
        _require(
            selector_before_wire == bytes(SELECTOR_BYTES),
            "initial transition predecessor selector is not absent",
        )
        return
    before = _decode_campaign_selector(
        selector_before_wire,
        "selector_before",
    )
    _require(
        before["generation"] == header["generation_before"],
        "before selector generation changed",
    )
    _require(
        before["manifest_sha256"] == header["manifest_before_sha256"],
        "before selector manifest root changed",
    )
    _require(
        _raw_sha256(selector_before_wire) == header["selector_before_wire_sha256"],
        "before selector wire root changed",
    )
    _require(
        before["campaign_challenge_sha256"] == after["campaign_challenge_sha256"]
        and before["segment_count"] == after["segment_count"],
        "selector transition changed authority or segment count",
    )
    for field in ("total_records", "total_completed", "total_events"):
        _require(
            after[field] > before[field],
            "selector transition did not increase %s" % field,
        )


def seal_header(
    value: Mapping[str, Any],
    selector_before_wire: bytes,
    selector_after_wire: bytes,
) -> Record:
    checked = _copy_fields(
        value,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
        "header",
    )
    _require(
        checked["matrix_id_sha256"] == ZERO_DIGEST,
        "unsealed header already has a matrix root",
    )
    checked["matrix_id_sha256"] = derive_matrix_id(
        checked,
        selector_before_wire,
        selector_after_wire,
    )
    checked = _validate_header_base(checked)
    _validate_header_selectors(
        checked,
        selector_before_wire,
        selector_after_wire,
    )
    return checked


def seal_case(
    header: Mapping[str, Any],
    value: Mapping[str, Any],
) -> Record:
    checked_header = _validate_header_base(header)
    checked = _copy_fields(
        value,
        CASE_SCALAR_FIELDS,
        CASE_DIGEST_FIELDS,
        "case",
    )
    _require(
        checked["failpoint_sha256"] == ZERO_DIGEST
        and checked["case_sha256"] == ZERO_DIGEST,
        "unsealed case already has a derived root",
    )
    checked["failpoint_sha256"] = derive_failpoint(
        checked_header["matrix_id_sha256"],
        checked,
    )
    checked["case_sha256"] = derive_case_sha256(
        checked_header["matrix_id_sha256"],
        checked,
    )
    return _validate_case(
        checked_header,
        checked,
        checked["ordinal"],
        checked["previous_case_sha256"],
    )


def _header_counts(cases: Sequence[Mapping[str, Any]]) -> Record:
    errno_cases = sum(
        case["fault_kind"] in (FAULT_INJECTED_ERRNO, FAULT_PARTIAL_WRITE_ERRNO)
        for case in cases
    )
    signal_cases = len(cases) - errno_cases
    return {
        "failpoint_count": len({case["failpoint_sha256"] for case in cases}),
        "errno_case_count": errno_cases,
        "signal_case_count": signal_cases,
        "expected_before_only_count": sum(
            case["expected_state_mask"] == EXPECTED_BEFORE for case in cases
        ),
        "expected_after_only_count": sum(
            case["expected_state_mask"] == EXPECTED_AFTER for case in cases
        ),
        "expected_either_count": sum(
            case["expected_state_mask"] == EXPECTED_EITHER for case in cases
        ),
        "observed_before_count": sum(
            case["observed_selector_state"] == SELECTOR_STATE_BEFORE for case in cases
        ),
        "observed_after_count": sum(
            case["observed_selector_state"] == SELECTOR_STATE_AFTER for case in cases
        ),
        "recovered_before_count": sum(
            case["recovered_selector_state"] == SELECTOR_STATE_BEFORE for case in cases
        ),
        "recovered_after_count": sum(
            case["recovered_selector_state"] == SELECTOR_STATE_AFTER for case in cases
        ),
        "synthetic_fault_count": errno_cases,
        "real_signal_count": signal_cases,
        "total_trigger_count": sum(case["trigger_count"] for case in cases),
    }


def _validate_report_values(
    header: Mapping[str, Any],
    selector_before_wire: bytes,
    selector_after_wire: bytes,
    cases: Sequence[Mapping[str, Any]],
) -> tuple[Record, list[Record]]:
    checked_header = _validate_header_base(header)
    _validate_header_selectors(
        checked_header,
        selector_before_wire,
        selector_after_wire,
    )
    _require(
        checked_header["matrix_id_sha256"]
        == derive_matrix_id(
            checked_header,
            selector_before_wire,
            selector_after_wire,
        ),
        "matrix root mismatch",
    )
    _require(
        isinstance(cases, Sequence)
        and not isinstance(cases, (bytes, bytearray, str))
        and len(cases) == checked_header["case_count"],
        "case sequence length changed",
    )
    checked_cases: list[Record] = []
    previous = ZERO_DIGEST
    for ordinal, case in enumerate(cases):
        checked = _validate_case(
            checked_header,
            case,
            ordinal,
            previous,
        )
        checked_cases.append(checked)
        previous = checked["case_sha256"]
    for field in (
        "case_challenge_sha256",
        "failpoint_sha256",
        "fault_control_receipt_sha256",
        "recovery_result_sha256",
        "case_sha256",
    ):
        values = [case[field] for case in checked_cases]
        _require(
            len(set(values)) == len(values),
            "case %s values are not unique" % field,
        )
    counts = _header_counts(checked_cases)
    for field, value in counts.items():
        _require(
            checked_header[field] == value,
            "header %s does not match cases" % field,
        )
    _require(
        checked_header["failpoint_count"] == len(checked_cases),
        "case failpoints are not one-to-one",
    )
    return checked_header, checked_cases


def make_report(
    header: Mapping[str, Any],
    selector_before_wire: bytes,
    selector_after_wire: bytes,
    cases: Sequence[Mapping[str, Any]],
) -> bytes:
    checked_header, checked_cases = _validate_report_values(
        header,
        selector_before_wire,
        selector_after_wire,
        cases,
    )
    body = (
        _encode_fields(
            checked_header,
            HEADER_SCALAR_FIELDS,
            HEADER_DIGEST_FIELDS,
        )
        + selector_before_wire
        + selector_after_wire
        + b"".join(
            _encode_fields(case, CASE_SCALAR_FIELDS, CASE_DIGEST_FIELDS)
            for case in checked_cases
        )
    )
    body_sha256 = _hash(REPORT_BODY_DOMAIN, (body,))
    report_sha256 = _hash(
        REPORT_FOOTER_DOMAIN,
        (body, body_sha256),
    )
    encoded = body + body_sha256 + report_sha256
    _require(
        len(encoded) == checked_header["encoded_bytes"],
        "encoded report length changed",
    )
    return encoded


def decode_report(encoded: bytes) -> Record:
    _require(isinstance(encoded, bytes), "report wire is not bytes")
    _require(
        len(encoded) >= FIXED_BYTES + CASE_BYTES,
        "report wire is truncated",
    )
    header, offset = _decode_fields(
        encoded,
        0,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
    )
    _require(
        header["encoded_bytes"] == len(encoded),
        "report wire length does not match header",
    )
    _require(
        len(encoded) == encoded_report_bytes(header["case_count"]),
        "report case count does not match wire length",
    )
    selector_before_wire = encoded[offset : offset + SELECTOR_BYTES]
    offset += SELECTOR_BYTES
    selector_after_wire = encoded[offset : offset + SELECTOR_BYTES]
    offset += SELECTOR_BYTES
    cases: list[Record] = []
    for _ in range(header["case_count"]):
        case, offset = _decode_fields(
            encoded,
            offset,
            CASE_SCALAR_FIELDS,
            CASE_DIGEST_FIELDS,
        )
        cases.append(case)
    body_end = len(encoded) - FOOTER_BYTES
    _require(offset == body_end, "report body has trailing bytes")
    body_sha256 = encoded[body_end : body_end + 32]
    report_sha256 = encoded[body_end + 32 :]
    body = encoded[:body_end]
    expected_body = _hash(REPORT_BODY_DOMAIN, (body,))
    expected_report = _hash(
        REPORT_FOOTER_DOMAIN,
        (body, expected_body),
    )
    _require(body_sha256 == expected_body, "report body root mismatch")
    _require(report_sha256 == expected_report, "report footer root mismatch")
    checked_header, checked_cases = _validate_report_values(
        header,
        selector_before_wire,
        selector_after_wire,
        cases,
    )
    _require(
        make_report(
            checked_header,
            selector_before_wire,
            selector_after_wire,
            checked_cases,
        )
        == encoded,
        "report wire is not canonical",
    )
    return {
        "header": checked_header,
        "selector_before_wire": selector_before_wire,
        "selector_after_wire": selector_after_wire,
        "cases": checked_cases,
        "body_sha256": body_sha256,
        "report_sha256": report_sha256,
    }


def verify_report(encoded: bytes) -> Record:
    """Decode and completely verify one canonical V1 report."""
    return decode_report(encoded)
