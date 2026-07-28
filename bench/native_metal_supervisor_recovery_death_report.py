#!/usr/bin/env python3
"""Independent codec for the fixed W7b-b5 supervisor-death report.

The 3,520-byte wire joins two real PID-only ``SIGKILL`` receipts to three
durable campaign states: the complete generation-six prefix, the selected
generation-eleven predecessor plus fully prepared generation-twelve selector,
and the final generation-twelve roll-forward.  Role-specific grants are
cryptographic evidence inputs only.  Decoding this report grants no mutation,
append, resume, finalization, or audit authority.

The hard campaign uses this report to claim two observed host-process deaths,
1,200 production-native Metal commands checked against CPU oracles across
twelve retained segments, and the exact bounded store transition encoded
below. A valid wire alone proves only internal structure and joins, not
external OS, storage, GPU, or CPU provenance. The profile does not claim a
controlled fault injection, active-kernel interruption, physical device or
storage failure, power loss, driver reclamation, victim-output recovery,
device residency, performance, or leak freedom.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct
from typing import Any, Iterable, Mapping, Sequence


class SupervisorRecoveryDeathReportError(ValueError):
    """The W7b-b5 report is structurally or semantically invalid."""


Record = dict[str, Any]
Digest = bytes

ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
# The report ABI records the POSIX signal number, not the host Python
# module's availability. Keeping the value literal makes this codec and its
# offline verifier importable on non-POSIX hosts; only the native campaign
# is allowed to send the signal.
SIGKILL_NUMBER = 9
SIGKILL_RETURNCODE_BITS = (-SIGKILL_NUMBER) & U64_MAX

REPORT_ABI = 0x4757_5352_0000_0001
SUPERVISOR_READY_ABI = 0x4757_5355_0000_0001
SUPERVISOR_KILL_ABI = 0x4757_534B_0000_0001
GENERATION_SIX_AUDIT_ABI = 0x4757_5341_0000_0001
RECOVERY_READY_ABI = 0x4757_5252_0000_0001
RECOVERY_KILL_ABI = 0x4757_524B_0000_0001
FINAL_AUDIT_ABI = 0x4757_5241_0000_0001

HEADER_SCALAR_COUNT = 24
HEADER_DIGEST_COUNT = 26
SUPERVISOR_READY_SCALAR_COUNT = 16
SUPERVISOR_READY_DIGEST_COUNT = 12
KILL_SCALAR_COUNT = 8
KILL_DIGEST_COUNT = 8
AUDIT_SCALAR_COUNT = 16
AUDIT_DIGEST_COUNT = 8
RECOVERY_READY_SCALAR_COUNT = 16
RECOVERY_READY_DIGEST_COUNT = 12

HEADER_BYTES = 1_024
SUPERVISOR_READY_BYTES = 512
SUPERVISOR_KILL_BYTES = 320
GENERATION_SIX_AUDIT_BYTES = 384
RECOVERY_READY_BYTES = 512
RECOVERY_KILL_BYTES = 320
FINAL_AUDIT_BYTES = 384
FOOTER_BYTES = 64
REPORT_BYTES = 3_520
SELECTOR_BYTES = 192

ALLOWED_FLAGS = 0
SEGMENT_COUNT = 12
SUPERVISOR_GENERATION = 6
RECOVERY_SELECTED_GENERATION = 11
CANDIDATE_GENERATION = 12
WORKER_PROCESS_COUNT = 2
TOTAL_SIGKILL_COUNT = 2
TOTAL_RECORDS = 3_000
TOTAL_COMPLETED = 1_200
TOTAL_CANCELLED = 600
TOTAL_FAILED = 600
TOTAL_CAPACITY_REJECTED = 600
TOTAL_PIN_COMPLETIONS = 2_400
TOTAL_EVENTS = 15_000
GENERATION_SIX_RECORDS = 1_500
GENERATION_SIX_COMPLETED = 600
PUBLICATION_PHASE_SELECTOR_ACTIVE_REPLACE = 26

_DOMAIN_BASE = b"glacier-w7b-b5-supervisor-recovery-death-"


def _domain(slug: bytes) -> bytes:
    return _DOMAIN_BASE + slug + b"-v1\x00"


HEADER_DOMAIN = _domain(b"header")
SUPERVISOR_READY_DOMAIN = _domain(b"supervisor-ready")
SUPERVISOR_KILL_DOMAIN = _domain(b"supervisor-kill")
GENERATION_SIX_AUDIT_DOMAIN = _domain(b"generation-six-audit")
RECOVERY_READY_DOMAIN = _domain(b"recovery-ready")
RECOVERY_KILL_DOMAIN = _domain(b"recovery-kill")
FINAL_AUDIT_DOMAIN = _domain(b"final-audit")
BODY_DOMAIN = _domain(b"body")
REPORT_DOMAIN = _domain(b"report")
COMPONENT_SET_DOMAIN = _domain(b"component-set")
SUPERVISOR_CHALLENGE_DOMAIN = _domain(b"supervisor-challenge")
RECOVERY_CHALLENGE_DOMAIN = _domain(b"recovery-challenge")
MACHINE_JOIN_DOMAIN = _domain(b"machine-join")
RESUME_GRANT_DOMAIN = _domain(b"resume-grant")
FINALIZER_GRANT_DOMAIN = _domain(b"finalizer-grant")

HEADER_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "header_bytes",
    "supervisor_ready_bytes",
    "supervisor_kill_bytes",
    "generation_six_audit_bytes",
    "recovery_ready_bytes",
    "recovery_kill_bytes",
    "final_audit_bytes",
    "footer_bytes",
    "segment_count",
    "supervisor_generation",
    "recovery_selected_generation",
    "candidate_generation",
    "worker_process_count",
    "total_sigkill_count",
    "total_records",
    "total_completed",
    "total_cancelled",
    "total_failed",
    "total_capacity_rejected",
    "total_pin_completions",
    "total_events",
)

HEADER_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "schedule_sha256",
    "controller_authority_sha256",
    "component_set_sha256",
    "controller_sha256",
    "supervisor_sha256",
    "recovery_sha256",
    "worker_sha256",
    "metallib_sha256",
    "verifier_sha256",
    "machine_sha256",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "resume_grant_sha256",
    "finalizer_grant_sha256",
    "supervisor_ready_sha256",
    "supervisor_kill_sha256",
    "generation_six_audit_sha256",
    "recovery_ready_sha256",
    "recovery_kill_sha256",
    "final_audit_sha256",
    "generation_six_selector_sha256",
    "candidate_selector_sha256",
    "final_store_sha256",
    "header_sha256",
)

SUPERVISOR_READY_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "pid",
    "worker_pid",
    "worker_exit_code_bits",
    "worker_termination_signal",
    "active_worker_count",
    "lock_held",
    "selected_generation",
    "segment_count",
    "publication_inflight",
    "selector_bytes",
    "process_session_isolated",
    "lock_contended",
    "reserved",
)

SUPERVISOR_READY_DIGEST_FIELDS = (
    "supervisor_challenge_sha256",
    "supervisor_sha256",
    "worker_sha256",
    "metallib_sha256",
    "campaign_id_sha256",
    "manifest_sha256",
    "selector_sha256",
    "final_entry_sha256",
    "canonical_store_sha256",
    "lock_identity_sha256",
    "machine_join_sha256",
    "root_sha256",
)

KILL_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "pid",
    "termination_signal",
    "returncode_bits",
    "stdout_bytes",
    "stderr_bytes",
)

SUPERVISOR_KILL_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "supervisor_challenge_sha256",
    "supervisor_ready_sha256",
    "supervisor_sha256",
    "controller_sha256",
    "lock_identity_sha256",
    "component_set_sha256",
    "root_sha256",
)

GENERATION_SIX_AUDIT_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "auditor_pid",
    "selected_generation",
    "segment_count",
    "require_complete",
    "complete",
    "shared_lock",
    "unknown_object_count",
    "temporary_object_count",
    "hardlink_count",
    "symlink_count",
    "process_generation_count",
    "total_records",
    "total_completed",
)

GENERATION_SIX_AUDIT_DIGEST_FIELDS = (
    "resume_grant_sha256",
    "campaign_id_sha256",
    "manifest_sha256",
    "selector_sha256",
    "final_entry_sha256",
    "canonical_store_sha256",
    "lock_identity_sha256",
    "root_sha256",
)

RECOVERY_READY_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "pid",
    "worker_pid",
    "worker_exit_code_bits",
    "worker_termination_signal",
    "active_worker_count",
    "lock_held",
    "selected_generation",
    "candidate_generation",
    "segment_count",
    "controller_lock_contention_acknowledged",
    "candidate_selector_bytes",
    "root_sync_completed",
    "publication_phase_index",
)

RECOVERY_READY_DIGEST_FIELDS = (
    "resume_grant_sha256",
    "recovery_sha256",
    "worker_sha256",
    "recovery_challenge_sha256",
    "campaign_id_sha256",
    "selected_manifest_sha256",
    "selected_selector_sha256",
    "candidate_manifest_sha256",
    "candidate_selector_sha256",
    "prepared_store_sha256",
    "lock_identity_sha256",
    "root_sha256",
)

RECOVERY_KILL_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "resume_grant_sha256",
    "recovery_ready_sha256",
    "recovery_sha256",
    "controller_sha256",
    "lock_identity_sha256",
    "component_set_sha256",
    "root_sha256",
)

FINAL_AUDIT_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "finalizer_pid",
    "auditor_pid",
    "predecessor_generation",
    "final_generation",
    "segment_count",
    "rollforward_count",
    "replace_count",
    "root_sync_count",
    "complete",
    "unknown_object_count",
    "temporary_object_count",
    "total_records",
    "total_completed",
)

FINAL_AUDIT_DIGEST_FIELDS = (
    "finalizer_grant_sha256",
    "campaign_id_sha256",
    "predecessor_selector_sha256",
    "candidate_selector_sha256",
    "final_manifest_sha256",
    "final_selector_sha256",
    "final_store_sha256",
    "root_sha256",
)


@dataclass(frozen=True)
class ReportClaimBoundary:
    """Claims encoded by this profile, not external-provenance verification.

    A valid self-contained wire can be constructed from synthetic fixtures.
    The hard campaign must separately establish the OS, storage, and native
    device provenance before retaining the report as evidence.
    """

    reported_real_pid_only_sigkill_count: int = TOTAL_SIGKILL_COUNT
    reported_controlled_fault_injection_count: int = 0
    reported_production_native_metal_command_count: int = TOTAL_COMPLETED
    reported_cpu_oracle_checked_command_count: int = TOTAL_COMPLETED
    claims_supervisor_death: bool = True
    claims_recovery_process_death: bool = True
    claims_active_kernel_interruption: bool = False
    claims_physical_device_loss: bool = False
    claims_physical_storage_failure: bool = False
    claims_power_loss: bool = False
    claims_driver_reclamation: bool = False
    claims_victim_output_recovery: bool = False
    claims_device_residency: bool = False
    claims_performance: bool = False
    claims_leak_freedom: bool = False
    external_provenance_verified: bool = False
    grants_runtime_authority: bool = False


REPORT_CLAIM_BOUNDARY = ReportClaimBoundary()


@dataclass(frozen=True)
class DecodedReport:
    header: Mapping[str, Any]
    supervisor_ready: Mapping[str, Any]
    supervisor_kill: Mapping[str, Any]
    generation_six_audit: Mapping[str, Any]
    recovery_ready: Mapping[str, Any]
    recovery_kill: Mapping[str, Any]
    final_audit: Mapping[str, Any]
    body_sha256: Digest
    report_sha256: Digest
    encoded: bytes
    claim_boundary: ReportClaimBoundary = REPORT_CLAIM_BOUNDARY

    def __getitem__(self, name: str) -> Any:
        return getattr(self, name)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SupervisorRecoveryDeathReportError(message)


def _u64(value: Any, label: str) -> bytes:
    _require(
        isinstance(value, int) and not isinstance(value, bool),
        "%s is not an integer" % label,
    )
    _require(0 <= value <= U64_MAX, "%s is outside u64" % label)
    return struct.pack("<Q", value)


def _digest(value: Any, label: str, *, nonzero: bool = True) -> Digest:
    _require(
        isinstance(value, bytes) and len(value) == 32,
        "%s is not a 32-byte digest" % label,
    )
    _require(not nonzero or value != ZERO_DIGEST, "%s is zero" % label)
    return value


def _hash(domain: bytes, parts: Iterable[bytes]) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _copy_fields(
    value: Mapping[str, Any],
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    label: str,
    *,
    root_may_be_zero: bool = False,
) -> Record:
    _require(isinstance(value, Mapping), "%s is not a mapping" % label)
    expected = set(scalar_fields) | set(digest_fields)
    _require(set(value) == expected, "%s fields are not canonical" % label)
    result: Record = {}
    for field in scalar_fields:
        _u64(value[field], "%s.%s" % (label, field))
        result[field] = value[field]
    for field in digest_fields:
        allow_zero = root_may_be_zero and field == digest_fields[-1]
        result[field] = _digest(
            value[field],
            "%s.%s" % (label, field),
            nonzero=not allow_zero,
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
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
) -> Record:
    expected_bytes = len(scalar_fields) * 8 + len(digest_fields) * 32
    _require(len(encoded) == expected_bytes, "region length changed")
    scalar_bytes = len(scalar_fields) * 8
    scalars = struct.unpack(
        "<%dQ" % len(scalar_fields),
        encoded[:scalar_bytes],
    )
    result: Record = dict(zip(scalar_fields, scalars))
    for index, field in enumerate(digest_fields):
        offset = scalar_bytes + index * 32
        result[field] = encoded[offset : offset + 32]
    return result


def _derive_record_root(
    domain: bytes,
    value: Mapping[str, Any],
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    label: str,
) -> Digest:
    checked = _copy_fields(
        value,
        scalar_fields,
        digest_fields,
        label,
        root_may_be_zero=True,
    )
    return _hash(
        domain,
        (
            _encode_fields(checked, scalar_fields, ()),
            _encode_fields(checked, (), digest_fields[:-1]),
        ),
    )


def derive_component_set_sha256(
    controller_sha256: Digest,
    supervisor_sha256: Digest,
    recovery_sha256: Digest,
    worker_sha256: Digest,
    metallib_sha256: Digest,
    verifier_sha256: Digest,
) -> Digest:
    return _hash(
        COMPONENT_SET_DOMAIN,
        (
            _digest(controller_sha256, "controller_sha256"),
            _digest(supervisor_sha256, "supervisor_sha256"),
            _digest(recovery_sha256, "recovery_sha256"),
            _digest(worker_sha256, "worker_sha256"),
            _digest(metallib_sha256, "metallib_sha256"),
            _digest(verifier_sha256, "verifier_sha256"),
        ),
    )


def derive_supervisor_challenge_sha256(
    campaign_challenge_sha256: Digest,
    schedule_sha256: Digest,
    component_set_sha256: Digest,
) -> Digest:
    return _hash(
        SUPERVISOR_CHALLENGE_DOMAIN,
        (
            _digest(campaign_challenge_sha256, "campaign_challenge_sha256"),
            _digest(schedule_sha256, "schedule_sha256"),
            _digest(component_set_sha256, "component_set_sha256"),
        ),
    )


def derive_machine_join_sha256(
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
) -> Digest:
    return _hash(
        MACHINE_JOIN_DOMAIN,
        (
            _digest(machine_sha256, "machine_sha256"),
            _digest(backend_sha256, "backend_sha256"),
            _digest(device_sha256, "device_sha256"),
            _digest(placement_sha256, "placement_sha256"),
        ),
    )


def derive_recovery_challenge_sha256(
    resume_grant_sha256: Digest,
    generation_six_audit_sha256: Digest,
) -> Digest:
    """Bind R1 admission to the fresh generation-six audit."""
    return _hash(
        RECOVERY_CHALLENGE_DOMAIN,
        (
            _digest(resume_grant_sha256, "resume_grant_sha256"),
            _digest(
                generation_six_audit_sha256,
                "generation_six_audit_sha256",
            ),
        ),
    )


def derive_resume_grant_sha256(
    controller_authority_sha256: Digest,
    campaign_challenge_sha256: Digest,
    schedule_sha256: Digest,
    component_set_sha256: Digest,
    supervisor_ready_sha256: Digest,
    supervisor_kill_sha256: Digest,
    generation_six_selector_sha256: Digest,
    generation_six_store_sha256: Digest,
) -> Digest:
    return _hash(
        RESUME_GRANT_DOMAIN,
        tuple(
            _digest(value, label)
            for value, label in (
                (controller_authority_sha256, "controller_authority_sha256"),
                (campaign_challenge_sha256, "campaign_challenge_sha256"),
                (schedule_sha256, "schedule_sha256"),
                (component_set_sha256, "component_set_sha256"),
                (supervisor_ready_sha256, "supervisor_ready_sha256"),
                (supervisor_kill_sha256, "supervisor_kill_sha256"),
                (
                    generation_six_selector_sha256,
                    "generation_six_selector_sha256",
                ),
                (
                    generation_six_store_sha256,
                    "generation_six_store_sha256",
                ),
            )
        ),
    )


def derive_finalizer_grant_sha256(
    controller_authority_sha256: Digest,
    campaign_challenge_sha256: Digest,
    schedule_sha256: Digest,
    component_set_sha256: Digest,
    resume_grant_sha256: Digest,
    recovery_ready_sha256: Digest,
    recovery_kill_sha256: Digest,
    candidate_selector_sha256: Digest,
    prepared_store_sha256: Digest,
) -> Digest:
    return _hash(
        FINALIZER_GRANT_DOMAIN,
        tuple(
            _digest(value, label)
            for value, label in (
                (controller_authority_sha256, "controller_authority_sha256"),
                (campaign_challenge_sha256, "campaign_challenge_sha256"),
                (schedule_sha256, "schedule_sha256"),
                (component_set_sha256, "component_set_sha256"),
                (resume_grant_sha256, "resume_grant_sha256"),
                (recovery_ready_sha256, "recovery_ready_sha256"),
                (recovery_kill_sha256, "recovery_kill_sha256"),
                (candidate_selector_sha256, "candidate_selector_sha256"),
                (prepared_store_sha256, "prepared_store_sha256"),
            )
        ),
    )


def _validate_fixed_scalars(
    value: Mapping[str, Any],
    expected: Mapping[str, int],
    label: str,
) -> None:
    for field, expected_value in expected.items():
        _require(
            value[field] == expected_value,
            "%s.%s changed" % (label, field),
        )


def _validate_pid(value: Any, label: str) -> None:
    _require(0 < value < U64_MAX, "%s is invalid" % label)


def _validate_root(
    value: Record,
    domain: bytes,
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    label: str,
) -> Record:
    expected = _derive_record_root(
        domain,
        value,
        scalar_fields,
        digest_fields,
        label,
    )
    _require(value[digest_fields[-1]] == expected, "%s root mismatch" % label)
    return value


def _make_record(
    value: Mapping[str, Any],
    domain: bytes,
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    label: str,
    validator: Any,
) -> Record:
    checked = _copy_fields(
        value,
        scalar_fields,
        digest_fields,
        label,
        root_may_be_zero=True,
    )
    _require(
        checked[digest_fields[-1]] == ZERO_DIGEST,
        "%s is already sealed" % label,
    )
    validator(checked, check_root=False)
    checked[digest_fields[-1]] = _derive_record_root(
        domain,
        checked,
        scalar_fields,
        digest_fields,
        label,
    )
    return validator(checked, check_root=True)


def _decode_record(
    encoded: bytes,
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    validator: Any,
) -> Record:
    _require(
        isinstance(encoded, (bytes, bytearray, memoryview)),
        "region must be bytes",
    )
    return validator(
        _decode_fields(bytes(encoded), scalar_fields, digest_fields),
        check_root=True,
    )


_HEADER_FIXED = {
    "abi_version": REPORT_ABI,
    "encoded_bytes": REPORT_BYTES,
    "flags": ALLOWED_FLAGS,
    "header_bytes": HEADER_BYTES,
    "supervisor_ready_bytes": SUPERVISOR_READY_BYTES,
    "supervisor_kill_bytes": SUPERVISOR_KILL_BYTES,
    "generation_six_audit_bytes": GENERATION_SIX_AUDIT_BYTES,
    "recovery_ready_bytes": RECOVERY_READY_BYTES,
    "recovery_kill_bytes": RECOVERY_KILL_BYTES,
    "final_audit_bytes": FINAL_AUDIT_BYTES,
    "footer_bytes": FOOTER_BYTES,
    "segment_count": SEGMENT_COUNT,
    "supervisor_generation": SUPERVISOR_GENERATION,
    "recovery_selected_generation": RECOVERY_SELECTED_GENERATION,
    "candidate_generation": CANDIDATE_GENERATION,
    "worker_process_count": WORKER_PROCESS_COUNT,
    "total_sigkill_count": TOTAL_SIGKILL_COUNT,
    "total_records": TOTAL_RECORDS,
    "total_completed": TOTAL_COMPLETED,
    "total_cancelled": TOTAL_CANCELLED,
    "total_failed": TOTAL_FAILED,
    "total_capacity_rejected": TOTAL_CAPACITY_REJECTED,
    "total_pin_completions": TOTAL_PIN_COMPLETIONS,
    "total_events": TOTAL_EVENTS,
}


def _validate_header(value: Mapping[str, Any], *, check_root: bool) -> Record:
    checked = _copy_fields(
        value,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
        "header",
        root_may_be_zero=not check_root,
    )
    _validate_fixed_scalars(checked, _HEADER_FIXED, "header")
    expected_component_set = derive_component_set_sha256(
        checked["controller_sha256"],
        checked["supervisor_sha256"],
        checked["recovery_sha256"],
        checked["worker_sha256"],
        checked["metallib_sha256"],
        checked["verifier_sha256"],
    )
    _require(
        checked["component_set_sha256"] == expected_component_set,
        "header component-set root mismatch",
    )
    machine_facts = (
        checked["machine_sha256"],
        checked["backend_sha256"],
        checked["device_sha256"],
        checked["placement_sha256"],
    )
    _require(
        len(set(machine_facts)) == len(machine_facts),
        "machine/backend/device/placement identities are not distinct",
    )
    _require(
        checked["resume_grant_sha256"] != checked["finalizer_grant_sha256"],
        "role-specific grants are not distinct",
    )
    if check_root:
        return _validate_root(
            checked,
            HEADER_DOMAIN,
            HEADER_SCALAR_FIELDS,
            HEADER_DIGEST_FIELDS,
            "header",
        )
    return checked


_SUPERVISOR_READY_FIXED = {
    "abi_version": SUPERVISOR_READY_ABI,
    "encoded_bytes": SUPERVISOR_READY_BYTES,
    "flags": ALLOWED_FLAGS,
    "worker_exit_code_bits": 0,
    "worker_termination_signal": 0,
    "active_worker_count": 0,
    "lock_held": 1,
    "selected_generation": SUPERVISOR_GENERATION,
    "segment_count": SUPERVISOR_GENERATION,
    "publication_inflight": 0,
    "selector_bytes": SELECTOR_BYTES,
    "process_session_isolated": 1,
    "lock_contended": 1,
    "reserved": 0,
}


def _validate_supervisor_ready(
    value: Mapping[str, Any],
    *,
    check_root: bool,
) -> Record:
    checked = _copy_fields(
        value,
        SUPERVISOR_READY_SCALAR_FIELDS,
        SUPERVISOR_READY_DIGEST_FIELDS,
        "supervisor_ready",
        root_may_be_zero=not check_root,
    )
    _validate_fixed_scalars(
        checked,
        _SUPERVISOR_READY_FIXED,
        "supervisor_ready",
    )
    _validate_pid(checked["pid"], "supervisor_ready.pid")
    _validate_pid(checked["worker_pid"], "supervisor_ready.worker_pid")
    _require(
        checked["pid"] != checked["worker_pid"],
        "supervisor and its worker PID are equal",
    )
    if check_root:
        return _validate_root(
            checked,
            SUPERVISOR_READY_DOMAIN,
            SUPERVISOR_READY_SCALAR_FIELDS,
            SUPERVISOR_READY_DIGEST_FIELDS,
            "supervisor_ready",
        )
    return checked


def _validate_kill(
    value: Mapping[str, Any],
    *,
    abi: int,
    encoded_bytes: int,
    ready_bytes: int,
    digest_fields: Sequence[str],
    domain: bytes,
    label: str,
    check_root: bool,
) -> Record:
    checked = _copy_fields(
        value,
        KILL_SCALAR_FIELDS,
        digest_fields,
        label,
        root_may_be_zero=not check_root,
    )
    _validate_fixed_scalars(
        checked,
        {
            "abi_version": abi,
            "encoded_bytes": encoded_bytes,
            "flags": ALLOWED_FLAGS,
            "termination_signal": SIGKILL_NUMBER,
            "returncode_bits": SIGKILL_RETURNCODE_BITS,
            "stdout_bytes": ready_bytes,
            "stderr_bytes": 0,
        },
        label,
    )
    _validate_pid(checked["pid"], "%s.pid" % label)
    if check_root:
        return _validate_root(
            checked,
            domain,
            KILL_SCALAR_FIELDS,
            digest_fields,
            label,
        )
    return checked


_GENERATION_SIX_AUDIT_FIXED = {
    "abi_version": GENERATION_SIX_AUDIT_ABI,
    "encoded_bytes": GENERATION_SIX_AUDIT_BYTES,
    "flags": ALLOWED_FLAGS,
    "selected_generation": SUPERVISOR_GENERATION,
    "segment_count": SUPERVISOR_GENERATION,
    "require_complete": 0,
    "complete": 0,
    "shared_lock": 1,
    "unknown_object_count": 0,
    "temporary_object_count": 0,
    "hardlink_count": 0,
    "symlink_count": 0,
    "process_generation_count": 1,
    "total_records": GENERATION_SIX_RECORDS,
    "total_completed": GENERATION_SIX_COMPLETED,
}


def _validate_generation_six_audit(
    value: Mapping[str, Any],
    *,
    check_root: bool,
) -> Record:
    checked = _copy_fields(
        value,
        GENERATION_SIX_AUDIT_SCALAR_FIELDS,
        GENERATION_SIX_AUDIT_DIGEST_FIELDS,
        "generation_six_audit",
        root_may_be_zero=not check_root,
    )
    _validate_fixed_scalars(
        checked,
        _GENERATION_SIX_AUDIT_FIXED,
        "generation_six_audit",
    )
    _validate_pid(
        checked["auditor_pid"],
        "generation_six_audit.auditor_pid",
    )
    if check_root:
        return _validate_root(
            checked,
            GENERATION_SIX_AUDIT_DOMAIN,
            GENERATION_SIX_AUDIT_SCALAR_FIELDS,
            GENERATION_SIX_AUDIT_DIGEST_FIELDS,
            "generation_six_audit",
        )
    return checked


_RECOVERY_READY_FIXED = {
    "abi_version": RECOVERY_READY_ABI,
    "encoded_bytes": RECOVERY_READY_BYTES,
    "flags": ALLOWED_FLAGS,
    "worker_exit_code_bits": 0,
    "worker_termination_signal": 0,
    "active_worker_count": 0,
    "lock_held": 1,
    "selected_generation": RECOVERY_SELECTED_GENERATION,
    "candidate_generation": CANDIDATE_GENERATION,
    "segment_count": SEGMENT_COUNT,
    "controller_lock_contention_acknowledged": 1,
    "candidate_selector_bytes": SELECTOR_BYTES,
    "root_sync_completed": 0,
    "publication_phase_index": PUBLICATION_PHASE_SELECTOR_ACTIVE_REPLACE,
}


def _validate_recovery_ready(
    value: Mapping[str, Any],
    *,
    check_root: bool,
) -> Record:
    checked = _copy_fields(
        value,
        RECOVERY_READY_SCALAR_FIELDS,
        RECOVERY_READY_DIGEST_FIELDS,
        "recovery_ready",
        root_may_be_zero=not check_root,
    )
    _validate_fixed_scalars(
        checked,
        _RECOVERY_READY_FIXED,
        "recovery_ready",
    )
    _validate_pid(checked["pid"], "recovery_ready.pid")
    _validate_pid(checked["worker_pid"], "recovery_ready.worker_pid")
    _require(
        checked["pid"] != checked["worker_pid"],
        "recovery process and its worker PID are equal",
    )
    _require(
        checked["selected_manifest_sha256"]
        != checked["candidate_manifest_sha256"],
        "prepared transition did not change its manifest",
    )
    _require(
        checked["selected_selector_sha256"]
        != checked["candidate_selector_sha256"],
        "prepared transition did not change its selector",
    )
    if check_root:
        return _validate_root(
            checked,
            RECOVERY_READY_DOMAIN,
            RECOVERY_READY_SCALAR_FIELDS,
            RECOVERY_READY_DIGEST_FIELDS,
            "recovery_ready",
        )
    return checked


_FINAL_AUDIT_FIXED = {
    "abi_version": FINAL_AUDIT_ABI,
    "encoded_bytes": FINAL_AUDIT_BYTES,
    "flags": ALLOWED_FLAGS,
    "predecessor_generation": RECOVERY_SELECTED_GENERATION,
    "final_generation": CANDIDATE_GENERATION,
    "segment_count": SEGMENT_COUNT,
    "rollforward_count": 1,
    "replace_count": 1,
    "root_sync_count": 1,
    "complete": 1,
    "unknown_object_count": 0,
    "temporary_object_count": 0,
    "total_records": TOTAL_RECORDS,
    "total_completed": TOTAL_COMPLETED,
}


def _validate_final_audit(
    value: Mapping[str, Any],
    *,
    check_root: bool,
) -> Record:
    checked = _copy_fields(
        value,
        FINAL_AUDIT_SCALAR_FIELDS,
        FINAL_AUDIT_DIGEST_FIELDS,
        "final_audit",
        root_may_be_zero=not check_root,
    )
    _validate_fixed_scalars(checked, _FINAL_AUDIT_FIXED, "final_audit")
    _validate_pid(checked["finalizer_pid"], "final_audit.finalizer_pid")
    _validate_pid(checked["auditor_pid"], "final_audit.auditor_pid")
    _require(
        checked["finalizer_pid"] != checked["auditor_pid"],
        "finalizer and auditor PIDs are equal",
    )
    _require(
        checked["predecessor_selector_sha256"]
        != checked["candidate_selector_sha256"],
        "final transition has no distinct predecessor",
    )
    _require(
        checked["candidate_selector_sha256"]
        == checked["final_selector_sha256"],
        "final selector is not the prepared candidate",
    )
    if check_root:
        return _validate_root(
            checked,
            FINAL_AUDIT_DOMAIN,
            FINAL_AUDIT_SCALAR_FIELDS,
            FINAL_AUDIT_DIGEST_FIELDS,
            "final_audit",
        )
    return checked


def make_header(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        HEADER_DOMAIN,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
        "header",
        _validate_header,
    )


seal_header = make_header


def encode_header(value: Mapping[str, Any]) -> bytes:
    checked = _validate_header(value, check_root=True)
    return _encode_fields(checked, HEADER_SCALAR_FIELDS, HEADER_DIGEST_FIELDS)


def decode_header(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        HEADER_SCALAR_FIELDS,
        HEADER_DIGEST_FIELDS,
        _validate_header,
    )


def make_supervisor_ready(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        SUPERVISOR_READY_DOMAIN,
        SUPERVISOR_READY_SCALAR_FIELDS,
        SUPERVISOR_READY_DIGEST_FIELDS,
        "supervisor_ready",
        _validate_supervisor_ready,
    )


seal_supervisor_ready = make_supervisor_ready


def encode_supervisor_ready(value: Mapping[str, Any]) -> bytes:
    checked = _validate_supervisor_ready(value, check_root=True)
    return _encode_fields(
        checked,
        SUPERVISOR_READY_SCALAR_FIELDS,
        SUPERVISOR_READY_DIGEST_FIELDS,
    )


def decode_supervisor_ready(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        SUPERVISOR_READY_SCALAR_FIELDS,
        SUPERVISOR_READY_DIGEST_FIELDS,
        _validate_supervisor_ready,
    )


def _validate_supervisor_kill(
    value: Mapping[str, Any],
    *,
    check_root: bool,
) -> Record:
    return _validate_kill(
        value,
        abi=SUPERVISOR_KILL_ABI,
        encoded_bytes=SUPERVISOR_KILL_BYTES,
        ready_bytes=SUPERVISOR_READY_BYTES,
        digest_fields=SUPERVISOR_KILL_DIGEST_FIELDS,
        domain=SUPERVISOR_KILL_DOMAIN,
        label="supervisor_kill",
        check_root=check_root,
    )


def make_supervisor_kill(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        SUPERVISOR_KILL_DOMAIN,
        KILL_SCALAR_FIELDS,
        SUPERVISOR_KILL_DIGEST_FIELDS,
        "supervisor_kill",
        _validate_supervisor_kill,
    )


seal_supervisor_kill = make_supervisor_kill


def encode_supervisor_kill(value: Mapping[str, Any]) -> bytes:
    checked = _validate_supervisor_kill(value, check_root=True)
    return _encode_fields(
        checked,
        KILL_SCALAR_FIELDS,
        SUPERVISOR_KILL_DIGEST_FIELDS,
    )


def decode_supervisor_kill(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        KILL_SCALAR_FIELDS,
        SUPERVISOR_KILL_DIGEST_FIELDS,
        _validate_supervisor_kill,
    )


def make_generation_six_audit(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        GENERATION_SIX_AUDIT_DOMAIN,
        GENERATION_SIX_AUDIT_SCALAR_FIELDS,
        GENERATION_SIX_AUDIT_DIGEST_FIELDS,
        "generation_six_audit",
        _validate_generation_six_audit,
    )


seal_generation_six_audit = make_generation_six_audit


def encode_generation_six_audit(value: Mapping[str, Any]) -> bytes:
    checked = _validate_generation_six_audit(value, check_root=True)
    return _encode_fields(
        checked,
        GENERATION_SIX_AUDIT_SCALAR_FIELDS,
        GENERATION_SIX_AUDIT_DIGEST_FIELDS,
    )


def decode_generation_six_audit(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        GENERATION_SIX_AUDIT_SCALAR_FIELDS,
        GENERATION_SIX_AUDIT_DIGEST_FIELDS,
        _validate_generation_six_audit,
    )


def make_recovery_ready(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        RECOVERY_READY_DOMAIN,
        RECOVERY_READY_SCALAR_FIELDS,
        RECOVERY_READY_DIGEST_FIELDS,
        "recovery_ready",
        _validate_recovery_ready,
    )


seal_recovery_ready = make_recovery_ready


def encode_recovery_ready(value: Mapping[str, Any]) -> bytes:
    checked = _validate_recovery_ready(value, check_root=True)
    return _encode_fields(
        checked,
        RECOVERY_READY_SCALAR_FIELDS,
        RECOVERY_READY_DIGEST_FIELDS,
    )


def decode_recovery_ready(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        RECOVERY_READY_SCALAR_FIELDS,
        RECOVERY_READY_DIGEST_FIELDS,
        _validate_recovery_ready,
    )


def _validate_recovery_kill(
    value: Mapping[str, Any],
    *,
    check_root: bool,
) -> Record:
    return _validate_kill(
        value,
        abi=RECOVERY_KILL_ABI,
        encoded_bytes=RECOVERY_KILL_BYTES,
        ready_bytes=RECOVERY_READY_BYTES,
        digest_fields=RECOVERY_KILL_DIGEST_FIELDS,
        domain=RECOVERY_KILL_DOMAIN,
        label="recovery_kill",
        check_root=check_root,
    )


def make_recovery_kill(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        RECOVERY_KILL_DOMAIN,
        KILL_SCALAR_FIELDS,
        RECOVERY_KILL_DIGEST_FIELDS,
        "recovery_kill",
        _validate_recovery_kill,
    )


seal_recovery_kill = make_recovery_kill


def encode_recovery_kill(value: Mapping[str, Any]) -> bytes:
    checked = _validate_recovery_kill(value, check_root=True)
    return _encode_fields(
        checked,
        KILL_SCALAR_FIELDS,
        RECOVERY_KILL_DIGEST_FIELDS,
    )


def decode_recovery_kill(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        KILL_SCALAR_FIELDS,
        RECOVERY_KILL_DIGEST_FIELDS,
        _validate_recovery_kill,
    )


def make_final_audit(value: Mapping[str, Any]) -> Record:
    return _make_record(
        value,
        FINAL_AUDIT_DOMAIN,
        FINAL_AUDIT_SCALAR_FIELDS,
        FINAL_AUDIT_DIGEST_FIELDS,
        "final_audit",
        _validate_final_audit,
    )


seal_final_audit = make_final_audit


def encode_final_audit(value: Mapping[str, Any]) -> bytes:
    checked = _validate_final_audit(value, check_root=True)
    return _encode_fields(
        checked,
        FINAL_AUDIT_SCALAR_FIELDS,
        FINAL_AUDIT_DIGEST_FIELDS,
    )


def decode_final_audit(encoded: bytes) -> Record:
    return _decode_record(
        encoded,
        FINAL_AUDIT_SCALAR_FIELDS,
        FINAL_AUDIT_DIGEST_FIELDS,
        _validate_final_audit,
    )


def _validate_semantic_joins(
    header: Mapping[str, Any],
    supervisor_ready: Mapping[str, Any],
    supervisor_kill: Mapping[str, Any],
    generation_six_audit: Mapping[str, Any],
    recovery_ready: Mapping[str, Any],
    recovery_kill: Mapping[str, Any],
    final_audit: Mapping[str, Any],
) -> None:
    region_roots = (
        supervisor_ready["root_sha256"],
        supervisor_kill["root_sha256"],
        generation_six_audit["root_sha256"],
        recovery_ready["root_sha256"],
        recovery_kill["root_sha256"],
        final_audit["root_sha256"],
    )
    _require(
        len(set(region_roots)) == len(region_roots),
        "region roots are not distinct",
    )
    for header_field, actual in (
        ("supervisor_ready_sha256", region_roots[0]),
        ("supervisor_kill_sha256", region_roots[1]),
        ("generation_six_audit_sha256", region_roots[2]),
        ("recovery_ready_sha256", region_roots[3]),
        ("recovery_kill_sha256", region_roots[4]),
        ("final_audit_sha256", region_roots[5]),
    ):
        _require(
            header[header_field] == actual,
            "header %s join changed" % header_field,
        )

    expected_component_set = derive_component_set_sha256(
        header["controller_sha256"],
        header["supervisor_sha256"],
        header["recovery_sha256"],
        header["worker_sha256"],
        header["metallib_sha256"],
        header["verifier_sha256"],
    )
    _require(
        header["component_set_sha256"] == expected_component_set,
        "component-set derivation changed",
    )
    expected_supervisor_challenge = derive_supervisor_challenge_sha256(
        header["campaign_challenge_sha256"],
        header["schedule_sha256"],
        header["component_set_sha256"],
    )
    _require(
        supervisor_ready["supervisor_challenge_sha256"]
        == expected_supervisor_challenge
        and supervisor_kill["supervisor_challenge_sha256"]
        == expected_supervisor_challenge,
        "supervisor challenge join changed",
    )
    expected_machine_join = derive_machine_join_sha256(
        header["machine_sha256"],
        header["backend_sha256"],
        header["device_sha256"],
        header["placement_sha256"],
    )
    _require(
        supervisor_ready["machine_join_sha256"] == expected_machine_join,
        "machine join changed",
    )

    for actual, expected, label in (
        (
            supervisor_ready["supervisor_sha256"],
            header["supervisor_sha256"],
            "supervisor-ready component",
        ),
        (
            supervisor_kill["supervisor_sha256"],
            header["supervisor_sha256"],
            "supervisor-kill component",
        ),
        (
            recovery_ready["recovery_sha256"],
            header["recovery_sha256"],
            "recovery-ready component",
        ),
        (
            recovery_kill["recovery_sha256"],
            header["recovery_sha256"],
            "recovery-kill component",
        ),
        (
            supervisor_ready["worker_sha256"],
            header["worker_sha256"],
            "supervisor worker",
        ),
        (
            recovery_ready["worker_sha256"],
            header["worker_sha256"],
            "recovery worker",
        ),
        (
            supervisor_ready["metallib_sha256"],
            header["metallib_sha256"],
            "supervisor metallib",
        ),
        (
            supervisor_kill["controller_sha256"],
            header["controller_sha256"],
            "supervisor-kill controller",
        ),
        (
            recovery_kill["controller_sha256"],
            header["controller_sha256"],
            "recovery-kill controller",
        ),
        (
            supervisor_kill["component_set_sha256"],
            header["component_set_sha256"],
            "supervisor-kill component set",
        ),
        (
            recovery_kill["component_set_sha256"],
            header["component_set_sha256"],
            "recovery-kill component set",
        ),
        (
            supervisor_kill["campaign_challenge_sha256"],
            header["campaign_challenge_sha256"],
            "supervisor-kill campaign",
        ),
        (
            recovery_kill["campaign_challenge_sha256"],
            header["campaign_challenge_sha256"],
            "recovery-kill campaign",
        ),
    ):
        _require(actual == expected, "%s join changed" % label)

    campaign_ids = (
        supervisor_ready["campaign_id_sha256"],
        generation_six_audit["campaign_id_sha256"],
        recovery_ready["campaign_id_sha256"],
        final_audit["campaign_id_sha256"],
    )
    _require(
        len(set(campaign_ids)) == 1,
        "campaign identity changed across generations",
    )
    lock_identities = (
        supervisor_ready["lock_identity_sha256"],
        supervisor_kill["lock_identity_sha256"],
        generation_six_audit["lock_identity_sha256"],
        recovery_ready["lock_identity_sha256"],
        recovery_kill["lock_identity_sha256"],
    )
    _require(
        len(set(lock_identities)) == 1,
        "lock identity changed across process roles",
    )

    for ready_field, audit_field, label in (
        ("manifest_sha256", "manifest_sha256", "generation-six manifest"),
        ("selector_sha256", "selector_sha256", "generation-six selector"),
        ("final_entry_sha256", "final_entry_sha256", "generation-six entry"),
        (
            "canonical_store_sha256",
            "canonical_store_sha256",
            "generation-six store",
        ),
    ):
        _require(
            supervisor_ready[ready_field]
            == generation_six_audit[audit_field],
            "%s join changed" % label,
        )
    _require(
        header["generation_six_selector_sha256"]
        == supervisor_ready["selector_sha256"],
        "header generation-six selector join changed",
    )
    _require(
        supervisor_kill["supervisor_ready_sha256"]
        == supervisor_ready["root_sha256"],
        "supervisor kill does not bind its ready frame",
    )
    _require(
        supervisor_kill["pid"] == supervisor_ready["pid"],
        "supervisor kill PID does not bind its ready frame",
    )

    expected_resume_grant = derive_resume_grant_sha256(
        header["controller_authority_sha256"],
        header["campaign_challenge_sha256"],
        header["schedule_sha256"],
        header["component_set_sha256"],
        supervisor_ready["root_sha256"],
        supervisor_kill["root_sha256"],
        supervisor_ready["selector_sha256"],
        supervisor_ready["canonical_store_sha256"],
    )
    _require(
        header["resume_grant_sha256"] == expected_resume_grant
        and generation_six_audit["resume_grant_sha256"]
        == expected_resume_grant
        and recovery_ready["resume_grant_sha256"] == expected_resume_grant
        and recovery_kill["resume_grant_sha256"] == expected_resume_grant,
        "resume role grant changed",
    )
    expected_recovery_challenge = derive_recovery_challenge_sha256(
        expected_resume_grant,
        generation_six_audit["root_sha256"],
    )
    _require(
        recovery_ready["recovery_challenge_sha256"]
        == expected_recovery_challenge,
        "recovery challenge does not bind the fresh generation-six audit",
    )

    _require(
        recovery_kill["recovery_ready_sha256"]
        == recovery_ready["root_sha256"],
        "recovery kill does not bind its ready frame",
    )
    _require(
        recovery_kill["pid"] == recovery_ready["pid"],
        "recovery kill PID does not bind its ready frame",
    )
    _require(
        final_audit["predecessor_selector_sha256"]
        == recovery_ready["selected_selector_sha256"],
        "generation-eleven predecessor join changed",
    )
    candidate_selector = recovery_ready["candidate_selector_sha256"]
    _require(
        header["candidate_selector_sha256"] == candidate_selector
        and final_audit["candidate_selector_sha256"] == candidate_selector
        and final_audit["final_selector_sha256"] == candidate_selector,
        "generation-twelve selector join changed",
    )
    _require(
        final_audit["final_manifest_sha256"]
        == recovery_ready["candidate_manifest_sha256"],
        "generation-twelve manifest join changed",
    )
    _require(
        final_audit["final_store_sha256"]
        == header["final_store_sha256"],
        "generation-twelve store join changed",
    )
    _require(
        recovery_ready["prepared_store_sha256"]
        != header["final_store_sha256"],
        "prepared and final store roots are not distinct",
    )

    expected_finalizer_grant = derive_finalizer_grant_sha256(
        header["controller_authority_sha256"],
        header["campaign_challenge_sha256"],
        header["schedule_sha256"],
        header["component_set_sha256"],
        expected_resume_grant,
        recovery_ready["root_sha256"],
        recovery_kill["root_sha256"],
        candidate_selector,
        recovery_ready["prepared_store_sha256"],
    )
    _require(
        header["finalizer_grant_sha256"] == expected_finalizer_grant
        and final_audit["finalizer_grant_sha256"]
        == expected_finalizer_grant,
        "finalizer role grant changed",
    )

    observed_role_pids = (
        supervisor_ready["pid"],
        supervisor_ready["worker_pid"],
        generation_six_audit["auditor_pid"],
        recovery_ready["pid"],
        recovery_ready["worker_pid"],
        final_audit["finalizer_pid"],
        final_audit["auditor_pid"],
    )
    _require(
        len(set(observed_role_pids)) == len(observed_role_pids),
        "observed process roles do not have distinct PIDs",
    )


def make_report(
    header: Mapping[str, Any],
    supervisor_ready: Mapping[str, Any],
    supervisor_kill: Mapping[str, Any],
    generation_six_audit: Mapping[str, Any],
    recovery_ready: Mapping[str, Any],
    recovery_kill: Mapping[str, Any],
    final_audit: Mapping[str, Any],
) -> bytes:
    checked_header = _validate_header(header, check_root=True)
    checked_supervisor_ready = _validate_supervisor_ready(
        supervisor_ready,
        check_root=True,
    )
    checked_supervisor_kill = _validate_supervisor_kill(
        supervisor_kill,
        check_root=True,
    )
    checked_generation_six_audit = _validate_generation_six_audit(
        generation_six_audit,
        check_root=True,
    )
    checked_recovery_ready = _validate_recovery_ready(
        recovery_ready,
        check_root=True,
    )
    checked_recovery_kill = _validate_recovery_kill(
        recovery_kill,
        check_root=True,
    )
    checked_final_audit = _validate_final_audit(
        final_audit,
        check_root=True,
    )
    _validate_semantic_joins(
        checked_header,
        checked_supervisor_ready,
        checked_supervisor_kill,
        checked_generation_six_audit,
        checked_recovery_ready,
        checked_recovery_kill,
        checked_final_audit,
    )
    body_wire = b"".join(
        (
            encode_header(checked_header),
            encode_supervisor_ready(checked_supervisor_ready),
            encode_supervisor_kill(checked_supervisor_kill),
            encode_generation_six_audit(checked_generation_six_audit),
            encode_recovery_ready(checked_recovery_ready),
            encode_recovery_kill(checked_recovery_kill),
            encode_final_audit(checked_final_audit),
        )
    )
    _require(
        len(body_wire) == REPORT_BYTES - FOOTER_BYTES,
        "report body geometry changed",
    )
    body_sha256 = _hash(BODY_DOMAIN, (body_wire,))
    report_sha256 = _hash(REPORT_DOMAIN, (body_sha256,))
    encoded = body_wire + body_sha256 + report_sha256
    _require(len(encoded) == REPORT_BYTES, "report geometry changed")
    return encoded


def verify_report(encoded_value: bytes) -> DecodedReport:
    _require(
        isinstance(encoded_value, (bytes, bytearray, memoryview)),
        "report must be bytes",
    )
    encoded = bytes(encoded_value)
    _require(len(encoded) == REPORT_BYTES, "report length changed")
    offset = 0

    def take(size: int) -> bytes:
        nonlocal offset
        result = encoded[offset : offset + size]
        offset += size
        return result

    header = decode_header(take(HEADER_BYTES))
    supervisor_ready = decode_supervisor_ready(take(SUPERVISOR_READY_BYTES))
    supervisor_kill = decode_supervisor_kill(take(SUPERVISOR_KILL_BYTES))
    generation_six_audit = decode_generation_six_audit(
        take(GENERATION_SIX_AUDIT_BYTES)
    )
    recovery_ready = decode_recovery_ready(take(RECOVERY_READY_BYTES))
    recovery_kill = decode_recovery_kill(take(RECOVERY_KILL_BYTES))
    final_audit = decode_final_audit(take(FINAL_AUDIT_BYTES))
    body_end = offset
    body_sha256 = take(32)
    report_sha256 = take(32)
    _require(offset == REPORT_BYTES, "report trailing geometry changed")
    _require(
        body_sha256 == _hash(BODY_DOMAIN, (encoded[:body_end],)),
        "report body root mismatch",
    )
    _require(
        report_sha256 == _hash(REPORT_DOMAIN, (body_sha256,)),
        "report root mismatch",
    )
    _validate_semantic_joins(
        header,
        supervisor_ready,
        supervisor_kill,
        generation_six_audit,
        recovery_ready,
        recovery_kill,
        final_audit,
    )
    return DecodedReport(
        header=header,
        supervisor_ready=supervisor_ready,
        supervisor_kill=supervisor_kill,
        generation_six_audit=generation_six_audit,
        recovery_ready=recovery_ready,
        recovery_kill=recovery_kill,
        final_audit=final_audit,
        body_sha256=body_sha256,
        report_sha256=report_sha256,
        encoded=encoded,
    )


decode_report = verify_report
