#!/usr/bin/env python3
"""Independent codec and verifier for segmented native workload campaigns.

The module deliberately operates on the fixed little-endian campaign wire. It
does not import the Zig implementation and does not accept JSON as an evidence
format.  One manifest binds a fixed plan to an ordered, predecessor-linked set
of verified native workload report attempts; a separate fixed selector names
the completely verified manifest.
"""

from __future__ import annotations

import hashlib
import struct
from typing import Any, Iterable, Mapping, MutableMapping, Sequence


class CampaignManifestError(ValueError):
    """The campaign manifest or selector is structurally or semantically invalid."""


Record = dict[str, Any]
Digest = bytes

MANIFEST_ABI = 0x4757_434D_0000_0001
ATTEMPT_ABI = 0x4757_4345_0000_0001
SELECTOR_ABI = 0x4757_4353_0000_0001

PLAN_SCALAR_COUNT = 32
PLAN_DIGEST_COUNT = 12
ATTEMPT_SCALAR_COUNT = 32
ATTEMPT_DIGEST_COUNT = 20
SELECTOR_SCALAR_COUNT = 8
SELECTOR_DIGEST_COUNT = 4

MANIFEST_HEADER_BYTES = (
    PLAN_SCALAR_COUNT * 8 + PLAN_DIGEST_COUNT * 32
)
ATTEMPT_BYTES = (
    ATTEMPT_SCALAR_COUNT * 8 + ATTEMPT_DIGEST_COUNT * 32
)
MANIFEST_FOOTER_BYTES = 64
SELECTOR_BYTES = (
    SELECTOR_SCALAR_COUNT * 8 + SELECTOR_DIGEST_COUNT * 32
)
SELECTOR_BODY_BYTES = SELECTOR_BYTES - 32
MAX_SEGMENTS = 1024
# Plan flags are additive. Selector flags remain zero in V1.
PLAN_FLAG_FORCED_PROCESS_RESTART = 1 << 0
# ``ALLOWED_FLAGS`` remains the backward-compatible zero-flag plan default.
ALLOWED_MANIFEST_FLAGS = PLAN_FLAG_FORCED_PROCESS_RESTART
ALLOWED_SELECTOR_FLAGS = 0
ALLOWED_FLAGS = 0
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
TERMINATION_SIGNAL_KILL = 9

PLAN_DOMAIN = b"glacier-native-workload-campaign-plan-v1\x00"
CAMPAIGN_ID_DOMAIN = b"glacier-native-workload-campaign-id-v1\x00"
SEGMENT_CHALLENGE_DOMAIN = (
    b"glacier-native-workload-campaign-segment-challenge-v1\x00"
)
ATTEMPT_ENTRY_DOMAIN = (
    b"glacier-native-workload-campaign-attempt-entry-v1\x00"
)
MANIFEST_BODY_DOMAIN = (
    b"glacier-native-workload-campaign-manifest-body-v1\x00"
)
MANIFEST_FOOTER_DOMAIN = (
    b"glacier-native-workload-campaign-manifest-footer-v1\x00"
)
SELECTOR_DOMAIN = b"glacier-native-workload-campaign-selector-v1\x00"
SCHEDULED_ACTION_DOMAIN = (
    b"glacier-native-workload-campaign-scheduled-action-v1\x00"
)
RSS_UNAVAILABLE_DOMAIN = (
    b"glacier-native-workload-campaign-rss-unavailable-v1\x00"
)
DEVICE_ALLOCATION_UNAVAILABLE_DOMAIN = (
    b"glacier-native-workload-campaign-device-allocation-unavailable-v1\x00"
)
ENVIRONMENT_DOMAIN = (
    b"glacier-native-workload-campaign-environment-v1\x00"
)

ACTION_NORMAL = 1
ACTION_GRACEFUL_PHASE_END = 2
ACTION_FORCED_PHASE_END = 3
ACTION_VALUES = frozenset(
    (
        ACTION_NORMAL,
        ACTION_GRACEFUL_PHASE_END,
        ACTION_FORCED_PHASE_END,
    )
)

DISPOSITION_VERIFIED_REPORT = 1
DISPOSITION_VALUES = frozenset((DISPOSITION_VERIFIED_REPORT,))
DISPOSITION_COMPLETE = DISPOSITION_VERIFIED_REPORT

AVAILABILITY_MISSING = 0
AVAILABILITY_DENIED = 1
AVAILABILITY_UNSUPPORTED = 2
AVAILABILITY_PRESENT = 3
AVAILABILITY_VALUES = frozenset(
    (
        AVAILABILITY_MISSING,
        AVAILABILITY_DENIED,
        AVAILABILITY_UNSUPPORTED,
        AVAILABILITY_PRESENT,
    )
)
PROVENANCE_PRODUCTION_NATIVE = 1 << 0
PROVENANCE_CONTROLLED_SOFTWARE = 1 << 1
PROVENANCE_NATIVE_HOST_OBSERVATION = 1 << 2
PROVENANCE_DERIVED_SYNTHETIC = 1 << 3
PROVENANCE_PLANNED_GRACEFUL_RESTART = 1 << 4
PROVENANCE_FORCED_OS_PROCESS_KILL = 1 << 5
BASE_PROVENANCE_BITS = (
    PROVENANCE_PRODUCTION_NATIVE
    | PROVENANCE_CONTROLLED_SOFTWARE
    | PROVENANCE_NATIVE_HOST_OBSERVATION
    | PROVENANCE_DERIVED_SYNTHETIC
)
ALLOWED_PROVENANCE_BITS = (
    BASE_PROVENANCE_BITS
    | PROVENANCE_PLANNED_GRACEFUL_RESTART
    | PROVENANCE_FORCED_OS_PROCESS_KILL
)

PLAN_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "segment_count",
    "restart_after_segment",
    "epochs_per_segment",
    "records_per_epoch",
    "warmup_epochs_per_segment",
    "measured_epochs_per_segment",
    "completed_per_epoch",
    "cancelled_per_epoch",
    "failed_per_epoch",
    "capacity_rejected_per_epoch",
    "pins_per_epoch",
    "events_per_epoch",
    "epoch_cadence_ns",
    "minimum_segment_duration_ns",
    "maximum_segment_duration_ns",
    "report_wire_bytes",
    "artifact_store_max_bytes",
    "rss_growth_bound_bytes",
    "total_epochs",
    "total_records",
    "total_warmup_records",
    "total_measured_records",
    "total_completed",
    "total_cancelled",
    "total_failed",
    "total_capacity_rejected",
    "total_pin_acquisitions",
    "device_allocation_growth_bound_bytes",
    "total_events",
)

PLAN_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "workload_sha256",
    "schedule_sha256",
    "artifact_sha256",
    "build_sha256",
    "runner_sha256",
    "backend_library_sha256",
    "machine_sha256",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "campaign_id_sha256",
)

ATTEMPT_SCALAR_FIELDS = (
    "abi_version",
    "ordinal",
    "process_generation",
    "disposition",
    "provenance_bits",
    "epoch_count",
    "record_count",
    "warmup_record_count",
    "measured_record_count",
    "completed_count",
    "cancelled_count",
    "failed_count",
    "capacity_rejected_count",
    "pin_acquisitions",
    "pin_completions",
    "event_count",
    "report_wire_bytes",
    "duration_ns",
    "cumulative_duration_ns",
    "cumulative_records",
    "cumulative_completed",
    "rss_availability",
    "rss_before_bytes",
    "rss_max_bytes",
    "rss_after_bytes",
    "device_allocation_availability",
    "device_allocation_before_bytes",
    "device_allocation_max_bytes",
    "device_allocation_after_bytes",
    "exit_code_bits",
    "termination_signal",
    "reserved",
)

ATTEMPT_DIGEST_FIELDS = (
    "scheduled_action_sha256",
    "segment_challenge_sha256",
    "previous_entry_sha256",
    "previous_verified_report_sha256",
    "report_wire_sha256",
    "verified_report_sha256",
    "scenario_sha256",
    "closure_sha256",
    "build_sha256",
    "machine_sha256",
    "backend_sha256",
    "device_sha256",
    "placement_sha256",
    "host_source_sha256",
    "host_clock_sha256",
    "rss_source_sha256",
    "rss_unavailable_reason_sha256",
    "device_allocation_source_sha256",
    "device_allocation_unavailable_reason_sha256",
    "entry_sha256",
)

SELECTOR_SCALAR_FIELDS = (
    "abi_version",
    "encoded_bytes",
    "flags",
    "generation",
    "segment_count",
    "total_records",
    "total_completed",
    "total_events",
)

SELECTOR_DIGEST_FIELDS = (
    "campaign_challenge_sha256",
    "manifest_sha256",
    "environment_sha256",
    "selector_sha256",
)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CampaignManifestError(message)


def _u64(value: int, label: str = "u64") -> bytes:
    _require(
        isinstance(value, int) and not isinstance(value, bool),
        "%s is not an integer" % label,
    )
    _require(0 <= value <= U64_MAX, "%s is out of u64 range" % label)
    return struct.pack("<Q", value)


def _digest(value: Any, label: str) -> Digest:
    _require(
        isinstance(value, bytes) and len(value) == 32,
        "%s is not a 32-byte digest" % label,
    )
    return value


def _nonzero_digest(value: Digest, label: str) -> Digest:
    result = _digest(value, label)
    _require(result != ZERO_DIGEST, "%s is zero" % label)
    return result


def _hash(domain: bytes, parts: Iterable[bytes]) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _checked_add(left: int, right: int, label: str) -> int:
    result = left + right
    _require(result <= U64_MAX, "%s overflows u64" % label)
    return result


def _checked_mul(left: int, right: int, label: str) -> int:
    result = left * right
    _require(result <= U64_MAX, "%s overflows u64" % label)
    return result


def encoded_manifest_bytes(segment_count: int) -> int:
    _u64(segment_count, "segment_count")
    _require(
        0 < segment_count <= MAX_SEGMENTS,
        "segment_count is outside the manifest bound",
    )
    return (
        MANIFEST_HEADER_BYTES
        + segment_count * ATTEMPT_BYTES
        + MANIFEST_FOOTER_BYTES
    )


def _copy_fields(
    value: Mapping[str, Any],
    scalar_fields: Sequence[str],
    digest_fields: Sequence[str],
    label: str,
) -> Record:
    _require(isinstance(value, Mapping), "%s is not a mapping" % label)
    expected = set(scalar_fields) | set(digest_fields)
    _require(
        set(value) == expected,
        "%s fields are not canonical" % label,
    )
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


def _plan_preimage(plan: Mapping[str, Any]) -> bytes:
    # Machine/backend/device/placement are first learned from the first native
    # report.  They are committed by the manifest body and must match every
    # entry, but cannot participate in the preflight campaign identity used to
    # derive that first segment's challenge.
    return _encode_fields(
        plan,
        PLAN_SCALAR_FIELDS,
        PLAN_DIGEST_FIELDS[:7],
    )


def derive_plan_sha256(plan: Mapping[str, Any]) -> Digest:
    """Derive the plan root without trusting its stored campaign identity."""
    checked = _copy_fields(
        plan,
        PLAN_SCALAR_FIELDS,
        PLAN_DIGEST_FIELDS,
        "plan",
    )
    return _hash(PLAN_DOMAIN, (_plan_preimage(checked),))


def derive_campaign_id(plan: Mapping[str, Any]) -> Digest:
    checked = _copy_fields(
        plan,
        PLAN_SCALAR_FIELDS,
        PLAN_DIGEST_FIELDS,
        "plan",
    )
    return _hash(
        CAMPAIGN_ID_DOMAIN,
        (derive_plan_sha256(checked),),
    )


def derive_scheduled_action(
    campaign_id: Digest,
    schedule_sha256: Digest,
    ordinal: int,
    process_generation: int,
    action_tag: int,
    rss_source_sha256: Digest,
) -> Digest:
    _require(action_tag in ACTION_VALUES, "invalid scheduled action tag")
    return _hash(
        SCHEDULED_ACTION_DOMAIN,
        (
            _nonzero_digest(campaign_id, "campaign_id"),
            _nonzero_digest(schedule_sha256, "schedule_sha256"),
            _u64(ordinal, "ordinal"),
            _u64(process_generation, "process_generation"),
            _u64(action_tag, "action_tag"),
            _nonzero_digest(rss_source_sha256, "rss_source_sha256"),
        ),
    )


def derive_segment_challenge(
    campaign_id: Digest,
    ordinal: int,
    process_generation: int,
    previous_entry_sha256: Digest,
    previous_verified_report_sha256: Digest,
    scheduled_action_sha256: Digest,
) -> Digest:
    return _hash(
        SEGMENT_CHALLENGE_DOMAIN,
        (
            _nonzero_digest(campaign_id, "campaign_id"),
            _u64(ordinal, "ordinal"),
            _u64(process_generation, "process_generation"),
            _digest(previous_entry_sha256, "previous_entry_sha256"),
            _digest(
                previous_verified_report_sha256,
                "previous_verified_report_sha256",
            ),
            _nonzero_digest(
                scheduled_action_sha256,
                "scheduled_action_sha256",
            ),
        ),
    )


def derive_metric_unavailable_reason(
    campaign_id: Digest,
    ordinal: int,
    availability: int,
    source_sha256: Digest,
) -> Digest:
    _require(
        availability in AVAILABILITY_VALUES
        and availability != AVAILABILITY_PRESENT,
        "availability is not an unavailable state",
    )
    return _hash(
        RSS_UNAVAILABLE_DOMAIN,
        (
            _nonzero_digest(campaign_id, "campaign_id"),
            _u64(ordinal, "ordinal"),
            _u64(availability, "availability"),
            _nonzero_digest(source_sha256, "source_sha256"),
        ),
    )


def derive_device_allocation_unavailable_reason(
    campaign_id: Digest,
    ordinal: int,
    availability: int,
    source_sha256: Digest,
) -> Digest:
    _require(
        availability in AVAILABILITY_VALUES
        and availability != AVAILABILITY_PRESENT,
        "availability is not an unavailable state",
    )
    return _hash(
        DEVICE_ALLOCATION_UNAVAILABLE_DOMAIN,
        (
            _nonzero_digest(campaign_id, "campaign_id"),
            _u64(ordinal, "ordinal"),
            _u64(availability, "availability"),
            _nonzero_digest(source_sha256, "source_sha256"),
        ),
    )


def derive_environment_sha256(
    campaign_id: Digest,
    generation: int,
    before_snapshot_sha256: Digest,
    after_snapshot_sha256: Digest,
) -> Digest:
    return _hash(
        ENVIRONMENT_DOMAIN,
        (
            _nonzero_digest(campaign_id, "campaign_id"),
            _u64(generation, "generation"),
            _nonzero_digest(
                before_snapshot_sha256,
                "before_snapshot_sha256",
            ),
            _digest(after_snapshot_sha256, "after_snapshot_sha256"),
        ),
    )


def _expected_process_generation(plan: Mapping[str, Any], ordinal: int) -> int:
    boundary = plan["restart_after_segment"]
    if boundary == 0 or ordinal < boundary:
        return 1
    return 2


def _expected_attempt_control(
    plan: Mapping[str, Any],
    ordinal: int,
) -> tuple[int, int, int, int]:
    """Return action, provenance, exit code, and signal for one segment."""
    restart_boundary = (
        plan["restart_after_segment"] != 0
        and ordinal + 1 == plan["restart_after_segment"]
    )
    if restart_boundary:
        if plan["flags"] & PLAN_FLAG_FORCED_PROCESS_RESTART:
            return (
                ACTION_FORCED_PHASE_END,
                BASE_PROVENANCE_BITS
                | PROVENANCE_FORCED_OS_PROCESS_KILL,
                U64_MAX,
                TERMINATION_SIGNAL_KILL,
            )
        return (
            ACTION_GRACEFUL_PHASE_END,
            BASE_PROVENANCE_BITS
            | PROVENANCE_PLANNED_GRACEFUL_RESTART,
            0,
            0,
        )
    if ordinal + 1 == plan["segment_count"]:
        return (
            ACTION_GRACEFUL_PHASE_END,
            BASE_PROVENANCE_BITS,
            0,
            0,
        )
    return (
        ACTION_NORMAL,
        BASE_PROVENANCE_BITS,
        U64_MAX,
        0,
    )


def _validate_plan(plan: Mapping[str, Any]) -> Record:
    checked = _copy_fields(
        plan,
        PLAN_SCALAR_FIELDS,
        PLAN_DIGEST_FIELDS,
        "plan",
    )
    segments = checked["segment_count"]
    _require(checked["abi_version"] == MANIFEST_ABI, "invalid manifest ABI")
    _require(
        checked["flags"] & ~ALLOWED_MANIFEST_FLAGS == 0,
        "invalid manifest flags",
    )
    _require(0 < segments <= MAX_SEGMENTS, "invalid segment count")
    _require(
        checked["encoded_bytes"] == encoded_manifest_bytes(segments),
        "manifest encoded length does not match segment count",
    )
    restart = checked["restart_after_segment"]
    _require(
        restart == 0 or 0 < restart < segments,
        "restart boundary is outside the campaign",
    )
    _require(
        not (
            checked["flags"] & PLAN_FLAG_FORCED_PROCESS_RESTART
            and restart == 0
        ),
        "forced process restart requires a restart boundary",
    )
    for field in (
        "epochs_per_segment",
        "records_per_epoch",
        "measured_epochs_per_segment",
        "completed_per_epoch",
        "pins_per_epoch",
        "events_per_epoch",
        "epoch_cadence_ns",
        "minimum_segment_duration_ns",
        "maximum_segment_duration_ns",
        "report_wire_bytes",
        "artifact_store_max_bytes",
        "rss_growth_bound_bytes",
        "device_allocation_growth_bound_bytes",
    ):
        _require(checked[field] > 0, "%s is zero" % field)
    _require(
        checked["warmup_epochs_per_segment"]
        + checked["measured_epochs_per_segment"]
        == checked["epochs_per_segment"],
        "warmup and measured epochs do not cover one segment",
    )
    _require(
        checked["completed_per_epoch"]
        + checked["cancelled_per_epoch"]
        + checked["failed_per_epoch"]
        + checked["capacity_rejected_per_epoch"]
        == checked["records_per_epoch"],
        "per-epoch outcomes do not cover every record",
    )
    expected_minimum = _checked_mul(
        checked["epochs_per_segment"],
        checked["epoch_cadence_ns"],
        "minimum paced segment duration",
    )
    _require(
        checked["minimum_segment_duration_ns"] == expected_minimum,
        "minimum segment duration does not match fixed pacing",
    )
    _require(
        checked["maximum_segment_duration_ns"]
        >= checked["minimum_segment_duration_ns"],
        "maximum segment duration is below minimum",
    )

    expected_totals = {
        "total_epochs": _checked_mul(
            segments,
            checked["epochs_per_segment"],
            "total epochs",
        ),
        "total_records": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "total epoch slots",
            ),
            checked["records_per_epoch"],
            "total records",
        ),
        "total_warmup_records": _checked_mul(
            _checked_mul(
                segments,
                checked["warmup_epochs_per_segment"],
                "warmup epoch slots",
            ),
            checked["records_per_epoch"],
            "total warmup records",
        ),
        "total_measured_records": _checked_mul(
            _checked_mul(
                segments,
                checked["measured_epochs_per_segment"],
                "measured epoch slots",
            ),
            checked["records_per_epoch"],
            "total measured records",
        ),
        "total_completed": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "completed epoch slots",
            ),
            checked["completed_per_epoch"],
            "total completed",
        ),
        "total_cancelled": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "cancelled epoch slots",
            ),
            checked["cancelled_per_epoch"],
            "total cancelled",
        ),
        "total_failed": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "failed epoch slots",
            ),
            checked["failed_per_epoch"],
            "total failed",
        ),
        "total_capacity_rejected": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "capacity epoch slots",
            ),
            checked["capacity_rejected_per_epoch"],
            "total capacity rejected",
        ),
        "total_pin_acquisitions": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "pin epoch slots",
            ),
            checked["pins_per_epoch"],
            "total pin acquisitions",
        ),
        "total_events": _checked_mul(
            _checked_mul(
                segments,
                checked["epochs_per_segment"],
                "event epoch slots",
            ),
            checked["events_per_epoch"],
            "total events",
        ),
    }
    for field, expected in expected_totals.items():
        _require(
            checked[field] == expected,
            "%s does not match the fixed plan" % field,
        )
    _require(
        checked["total_warmup_records"]
        + checked["total_measured_records"]
        == checked["total_records"],
        "warmup and measured totals do not cover the campaign",
    )
    minimum_store = _checked_add(
        _checked_mul(
            segments,
            checked["report_wire_bytes"],
            "retained report bytes",
        ),
        _checked_add(
            checked["encoded_bytes"],
            SELECTOR_BYTES,
            "manifest and selector bytes",
        ),
        "minimum artifact store bytes",
    )
    _require(
        checked["artifact_store_max_bytes"] >= minimum_store,
        "artifact store bound cannot hold the campaign",
    )
    for field in PLAN_DIGEST_FIELDS[:-1]:
        _nonzero_digest(checked[field], "plan.%s" % field)
    _require(
        checked["campaign_id_sha256"] == derive_campaign_id(checked),
        "campaign identity mismatch",
    )
    return checked


def seal_plan(plan: Mapping[str, Any]) -> Record:
    """Return a canonical plan with its encoded length and campaign id sealed."""
    result = dict(plan)
    _require(
        set(result) == set(PLAN_SCALAR_FIELDS) | set(PLAN_DIGEST_FIELDS),
        "plan fields are not canonical",
    )
    result["abi_version"] = MANIFEST_ABI
    result["encoded_bytes"] = encoded_manifest_bytes(result["segment_count"])
    result["campaign_id_sha256"] = ZERO_DIGEST
    result["campaign_id_sha256"] = derive_campaign_id(result)
    return _validate_plan(result)


def entry_root(
    campaign_id: Digest,
    entry: Mapping[str, Any],
) -> Digest:
    checked = _copy_fields(
        entry,
        ATTEMPT_SCALAR_FIELDS,
        ATTEMPT_DIGEST_FIELDS,
        "entry",
    )
    return _hash(
        ATTEMPT_ENTRY_DOMAIN,
        (
            _nonzero_digest(campaign_id, "campaign_id"),
            _encode_fields(
                checked,
                ATTEMPT_SCALAR_FIELDS,
                ATTEMPT_DIGEST_FIELDS[:-1],
            ),
        ),
    )


def make_entry(
    plan: Mapping[str, Any],
    value: Mapping[str, Any],
) -> Record:
    checked_plan = _validate_plan(plan)
    result = dict(value)
    _require(
        set(result) == set(ATTEMPT_SCALAR_FIELDS)
        | set(ATTEMPT_DIGEST_FIELDS),
        "entry fields are not canonical",
    )
    _require(
        result["abi_version"] == ATTEMPT_ABI,
        "caller supplied an invalid attempt ABI",
    )
    _require(
        result["reserved"] == 0,
        "caller supplied a nonzero attempt reserved field",
    )
    action_tag, _provenance, _exit_code, _signal = (
        _expected_attempt_control(
            checked_plan,
            result["ordinal"],
        )
    )
    expected_action_sha256 = derive_scheduled_action(
        checked_plan["campaign_id_sha256"],
        checked_plan["schedule_sha256"],
        result["ordinal"],
        result["process_generation"],
        action_tag,
        result["rss_source_sha256"],
    )
    _require(
        result["scheduled_action_sha256"] == expected_action_sha256,
        "caller supplied a drifting scheduled action root",
    )
    expected_segment_challenge = derive_segment_challenge(
        checked_plan["campaign_id_sha256"],
        result["ordinal"],
        result["process_generation"],
        result["previous_entry_sha256"],
        result["previous_verified_report_sha256"],
        result["scheduled_action_sha256"],
    )
    _require(
        result["segment_challenge_sha256"]
        == expected_segment_challenge,
        "caller supplied a drifting segment challenge",
    )
    if result["rss_availability"] == AVAILABILITY_PRESENT:
        expected_rss_reason = ZERO_DIGEST
    else:
        expected_rss_reason = (
            derive_metric_unavailable_reason(
                checked_plan["campaign_id_sha256"],
                result["ordinal"],
                result["rss_availability"],
                result["rss_source_sha256"],
            )
        )
    _require(
        result["rss_unavailable_reason_sha256"] == expected_rss_reason,
        "caller supplied a drifting RSS reason root",
    )
    if result["device_allocation_availability"] == AVAILABILITY_PRESENT:
        expected_device_reason = ZERO_DIGEST
    else:
        expected_device_reason = (
            derive_device_allocation_unavailable_reason(
                checked_plan["campaign_id_sha256"],
                result["ordinal"],
                result["device_allocation_availability"],
                result["device_allocation_source_sha256"],
            )
        )
    _require(
        result["device_allocation_unavailable_reason_sha256"]
        == expected_device_reason,
        "caller supplied a drifting device-allocation reason root",
    )
    _require(
        result["entry_sha256"] == ZERO_DIGEST,
        "caller supplied a pre-sealed attempt root",
    )
    result["entry_sha256"] = entry_root(
        checked_plan["campaign_id_sha256"],
        result,
    )
    return _copy_fields(
        result,
        ATTEMPT_SCALAR_FIELDS,
        ATTEMPT_DIGEST_FIELDS,
        "entry",
    )


def _validate_entry(
    plan: Mapping[str, Any],
    entry: Mapping[str, Any],
    ordinal: int,
    previous_entry: Mapping[str, Any] | None,
    cumulative_duration_before: int,
    rss_phase_baselines: MutableMapping[int, int],
    device_phase_baselines: MutableMapping[int, int],
    rss_phase_sources: MutableMapping[int, Digest],
) -> tuple[Record, int]:
    checked = _copy_fields(
        entry,
        ATTEMPT_SCALAR_FIELDS,
        ATTEMPT_DIGEST_FIELDS,
        "entry",
    )
    _require(checked["abi_version"] == ATTEMPT_ABI, "invalid attempt ABI")
    _require(checked["ordinal"] == ordinal, "attempt ordinal mismatch")
    _require(checked["reserved"] == 0, "attempt reserved field is nonzero")
    _require(
        checked["disposition"] in DISPOSITION_VALUES,
        "invalid attempt disposition",
    )
    expected_generation = _expected_process_generation(plan, ordinal)
    _require(
        checked["process_generation"] == expected_generation,
        "attempt process generation mismatch",
    )
    (
        expected_action,
        expected_provenance,
        expected_exit,
        expected_signal,
    ) = _expected_attempt_control(
        plan,
        ordinal,
    )
    _require(
        checked["disposition"] == DISPOSITION_VERIFIED_REPORT,
        "campaign publishes only independently verified reports",
    )
    _require(
        checked["provenance_bits"] == expected_provenance,
        "attempt provenance does not match the schedule",
    )
    _require(
        checked["exit_code_bits"] == expected_exit
        and checked["termination_signal"] == expected_signal,
        "attempt process termination state does not match its phase boundary",
    )

    per_segment = {
        "epoch_count": plan["epochs_per_segment"],
        "record_count": _checked_mul(
            plan["epochs_per_segment"],
            plan["records_per_epoch"],
            "records per segment",
        ),
        "warmup_record_count": _checked_mul(
            plan["warmup_epochs_per_segment"],
            plan["records_per_epoch"],
            "warmup records per segment",
        ),
        "measured_record_count": _checked_mul(
            plan["measured_epochs_per_segment"],
            plan["records_per_epoch"],
            "measured records per segment",
        ),
        "completed_count": _checked_mul(
            plan["epochs_per_segment"],
            plan["completed_per_epoch"],
            "completed per segment",
        ),
        "cancelled_count": _checked_mul(
            plan["epochs_per_segment"],
            plan["cancelled_per_epoch"],
            "cancelled per segment",
        ),
        "failed_count": _checked_mul(
            plan["epochs_per_segment"],
            plan["failed_per_epoch"],
            "failed per segment",
        ),
        "capacity_rejected_count": _checked_mul(
            plan["epochs_per_segment"],
            plan["capacity_rejected_per_epoch"],
            "capacity rejected per segment",
        ),
        "pin_acquisitions": _checked_mul(
            plan["epochs_per_segment"],
            plan["pins_per_epoch"],
            "pin acquisitions per segment",
        ),
        "pin_completions": _checked_mul(
            plan["epochs_per_segment"],
            plan["pins_per_epoch"],
            "pin completions per segment",
        ),
        "event_count": _checked_mul(
            plan["epochs_per_segment"],
            plan["events_per_epoch"],
            "events per segment",
        ),
        "report_wire_bytes": plan["report_wire_bytes"],
    }
    for field, expected in per_segment.items():
        _require(
            checked[field] == expected,
            "%s does not match the segment plan" % field,
        )
    _require(
        plan["minimum_segment_duration_ns"]
        <= checked["duration_ns"]
        <= plan["maximum_segment_duration_ns"],
        "attempt duration is outside the declared bound",
    )
    cumulative_duration = _checked_add(
        cumulative_duration_before,
        checked["duration_ns"],
        "cumulative duration",
    )
    _require(
        checked["cumulative_duration_ns"] == cumulative_duration,
        "cumulative duration mismatch",
    )
    multiplier = ordinal + 1
    cumulative_fields = {
        "cumulative_records": per_segment["record_count"],
        "cumulative_completed": per_segment["completed_count"],
    }
    for field, per_value in cumulative_fields.items():
        _require(
            checked[field]
            == _checked_mul(
                multiplier,
                per_value,
                field,
            ),
            "%s mismatch" % field,
        )

    if ordinal == 0:
        _require(
            checked["previous_entry_sha256"] == ZERO_DIGEST
            and checked["previous_verified_report_sha256"] == ZERO_DIGEST,
            "first attempt has a predecessor",
        )
    else:
        _require(previous_entry is not None, "attempt predecessor missing")
        _require(
            checked["previous_entry_sha256"]
            == previous_entry["entry_sha256"],
            "attempt entry chain mismatch",
        )
        _require(
            checked["previous_verified_report_sha256"]
            == previous_entry["verified_report_sha256"],
            "verified report chain mismatch",
        )
    _require(
        checked["scheduled_action_sha256"]
        == derive_scheduled_action(
            plan["campaign_id_sha256"],
            plan["schedule_sha256"],
            ordinal,
            checked["process_generation"],
            expected_action,
            checked["rss_source_sha256"],
        ),
        "scheduled action root mismatch",
    )
    expected_challenge = derive_segment_challenge(
        plan["campaign_id_sha256"],
        ordinal,
        checked["process_generation"],
        checked["previous_entry_sha256"],
        checked["previous_verified_report_sha256"],
        checked["scheduled_action_sha256"],
    )
    _require(
        checked["segment_challenge_sha256"] == expected_challenge,
        "segment challenge mismatch",
    )
    for field in (
        "scheduled_action_sha256",
        "report_wire_sha256",
        "verified_report_sha256",
        "scenario_sha256",
        "closure_sha256",
        "host_source_sha256",
        "host_clock_sha256",
        "rss_source_sha256",
    ):
        _nonzero_digest(checked[field], "entry.%s" % field)
    retained_rss_source = rss_phase_sources.setdefault(
        checked["process_generation"],
        checked["rss_source_sha256"],
    )
    _require(
        checked["rss_source_sha256"] == retained_rss_source,
        "RSS source changed within one persistent process generation",
    )
    stable = {
        "build_sha256": "build_sha256",
        "machine_sha256": "machine_sha256",
        "backend_sha256": "backend_sha256",
        "device_sha256": "device_sha256",
        "placement_sha256": "placement_sha256",
    }
    for entry_field, plan_field in stable.items():
        _require(
            checked[entry_field] == plan[plan_field],
            "%s changed during the campaign" % entry_field,
        )

    availability = checked["rss_availability"]
    _require(
        availability in AVAILABILITY_VALUES,
        "invalid RSS availability",
    )
    if availability == AVAILABILITY_PRESENT:
        _require(
            checked["rss_unavailable_reason_sha256"] == ZERO_DIGEST,
            "present RSS has an unavailable reason",
        )
        _require(
            checked["rss_before_bytes"] > 0
            and checked["rss_after_bytes"] > 0
            and checked["rss_max_bytes"]
            >= max(
                checked["rss_before_bytes"],
                checked["rss_after_bytes"],
            ),
            "present RSS samples are invalid",
        )
        baseline = rss_phase_baselines.setdefault(
            checked["process_generation"],
            checked["rss_before_bytes"],
        )
        phase_limit = _checked_add(
            baseline,
            plan["rss_growth_bound_bytes"],
            "phase RSS growth bound",
        )
        _require(
            max(
                checked["rss_before_bytes"],
                checked["rss_max_bytes"],
                checked["rss_after_bytes"],
            )
            <= phase_limit,
            "RSS growth exceeds its persistent-process phase bound",
        )
    else:
        _require(
            checked["rss_before_bytes"] == 0
            and checked["rss_max_bytes"] == 0
            and checked["rss_after_bytes"] == 0,
            "unavailable RSS carries a value",
        )
        _require(
            checked["rss_unavailable_reason_sha256"]
            == derive_metric_unavailable_reason(
                plan["campaign_id_sha256"],
                ordinal,
                availability,
                checked["rss_source_sha256"],
            ),
            "RSS unavailable reason mismatch",
        )

    device_availability = checked["device_allocation_availability"]
    _require(
        device_availability in AVAILABILITY_VALUES,
        "invalid device allocation availability",
    )
    _nonzero_digest(
        checked["device_allocation_source_sha256"],
        "entry.device_allocation_source_sha256",
    )
    if device_availability == AVAILABILITY_PRESENT:
        _require(
            checked["device_allocation_unavailable_reason_sha256"]
            == ZERO_DIGEST,
            "present device allocation context has an unavailable reason",
        )
        _require(
            checked["device_allocation_before_bytes"] > 0
            and checked["device_allocation_after_bytes"] > 0
            and checked["device_allocation_max_bytes"]
            >= max(
                checked["device_allocation_before_bytes"],
                checked["device_allocation_after_bytes"],
            ),
            "present device allocation context samples are invalid",
        )
        baseline = device_phase_baselines.setdefault(
            checked["process_generation"],
            checked["device_allocation_before_bytes"],
        )
        phase_limit = _checked_add(
            baseline,
            plan["device_allocation_growth_bound_bytes"],
            "phase device allocation growth bound",
        )
        _require(
            max(
                checked["device_allocation_before_bytes"],
                checked["device_allocation_max_bytes"],
                checked["device_allocation_after_bytes"],
            )
            <= phase_limit,
            "device allocation context exceeds its phase growth bound",
        )
    else:
        _require(
            checked["device_allocation_before_bytes"] == 0
            and checked["device_allocation_max_bytes"] == 0
            and checked["device_allocation_after_bytes"] == 0,
            "unavailable device allocation context carries a value",
        )
        _require(
            checked["device_allocation_unavailable_reason_sha256"]
            == derive_device_allocation_unavailable_reason(
                plan["campaign_id_sha256"],
                ordinal,
                device_availability,
                checked["device_allocation_source_sha256"],
            ),
            "device allocation unavailable reason mismatch",
        )
    _require(
        checked["entry_sha256"]
        == entry_root(plan["campaign_id_sha256"], checked),
        "attempt entry root mismatch",
    )
    return checked, cumulative_duration


def _manifest_roots(
    body: bytes,
) -> tuple[Digest, Digest]:
    body_sha256 = _hash(MANIFEST_BODY_DOMAIN, (body,))
    manifest_sha256 = _hash(
        MANIFEST_FOOTER_DOMAIN,
        (body, body_sha256),
    )
    return body_sha256, manifest_sha256


def make_manifest(
    plan: Mapping[str, Any],
    entries: Sequence[Mapping[str, Any]],
) -> bytes:
    checked_plan = _validate_plan(plan)
    _require(
        isinstance(entries, Sequence)
        and not isinstance(entries, (bytes, bytearray, str)),
        "entries are not a sequence",
    )
    _require(
        0 < len(entries) <= checked_plan["segment_count"],
        "entry prefix is empty or exceeds segment count",
    )
    checked_entries: list[Record] = []
    cumulative_duration = 0
    previous: Record | None = None
    rss_phase_baselines: dict[int, int] = {}
    device_phase_baselines: dict[int, int] = {}
    rss_phase_sources: dict[int, Digest] = {}
    for ordinal, entry in enumerate(entries):
        checked, cumulative_duration = _validate_entry(
            checked_plan,
            entry,
            ordinal,
            previous,
            cumulative_duration,
            rss_phase_baselines,
            device_phase_baselines,
            rss_phase_sources,
        )
        checked_entries.append(checked)
        previous = checked
    _require(previous is not None, "manifest has no final entry")
    _require(
        len(set(rss_phase_sources.values()))
        == len(rss_phase_sources.values()),
        "RSS source did not change across process generations",
    )
    for field in (
        "scheduled_action_sha256",
        "segment_challenge_sha256",
        "report_wire_sha256",
        "verified_report_sha256",
        "scenario_sha256",
        "entry_sha256",
    ):
        roots = [entry[field] for entry in checked_entries]
        _require(
            len(set(roots)) == len(roots),
            "attempt %s values are not globally unique" % field,
        )
    for field in (
        "host_source_sha256",
        "host_clock_sha256",
        "device_allocation_source_sha256",
    ):
        _require(
            len({entry[field] for entry in checked_entries}) == 1,
            "%s changed across the campaign prefix" % field,
        )
    _require(
        sum(entry["pin_acquisitions"] for entry in checked_entries)
        == sum(entry["pin_completions"] for entry in checked_entries),
        "campaign pin acquisitions and completions do not balance",
    )
    _require(
        previous["cumulative_records"]
        == sum(entry["record_count"] for entry in checked_entries)
        and previous["cumulative_completed"]
        == sum(entry["completed_count"] for entry in checked_entries),
        "final prefix cumulative counters do not match entries",
    )
    if len(checked_entries) == checked_plan["segment_count"]:
        _require(
            previous["cumulative_records"] == checked_plan["total_records"]
            and previous["cumulative_completed"]
            == checked_plan["total_completed"]
            and sum(entry["cancelled_count"] for entry in checked_entries)
            == checked_plan["total_cancelled"]
            and sum(entry["failed_count"] for entry in checked_entries)
            == checked_plan["total_failed"]
            and sum(
                entry["capacity_rejected_count"]
                for entry in checked_entries
            )
            == checked_plan["total_capacity_rejected"]
            and sum(
                entry["pin_acquisitions"] for entry in checked_entries
            )
            == checked_plan["total_pin_acquisitions"]
            and sum(entry["event_count"] for entry in checked_entries)
            == checked_plan["total_events"],
            "complete manifest aggregate does not match plan",
        )
    header = _encode_fields(
        checked_plan,
        PLAN_SCALAR_FIELDS,
        PLAN_DIGEST_FIELDS,
    )
    encoded_entries = b"".join(
        _encode_fields(
            entry,
            ATTEMPT_SCALAR_FIELDS,
            ATTEMPT_DIGEST_FIELDS,
        )
        for entry in checked_entries
    )
    zero_suffix = bytes(
        (checked_plan["segment_count"] - len(checked_entries))
        * ATTEMPT_BYTES
    )
    body = header + encoded_entries + zero_suffix
    body_sha256, manifest_sha256 = _manifest_roots(body)
    encoded = body + body_sha256 + manifest_sha256
    _require(
        len(encoded) == checked_plan["encoded_bytes"],
        "encoded manifest length mismatch",
    )
    return encoded


def encode_manifest(manifest: Mapping[str, Any]) -> bytes:
    _require(isinstance(manifest, Mapping), "manifest is not a mapping")
    _require(
        set(manifest) >= {"plan", "entries"},
        "manifest lacks plan or entries",
    )
    return make_manifest(manifest["plan"], manifest["entries"])


def decode_manifest(encoded: bytes) -> Record:
    _require(isinstance(encoded, bytes), "manifest wire is not bytes")
    _require(
        len(encoded)
        >= MANIFEST_HEADER_BYTES + ATTEMPT_BYTES + MANIFEST_FOOTER_BYTES,
        "manifest wire is truncated",
    )
    plan, offset = _decode_fields(
        encoded,
        0,
        PLAN_SCALAR_FIELDS,
        PLAN_DIGEST_FIELDS,
    )
    checked_plan = _validate_plan(plan)
    _require(
        len(encoded) == checked_plan["encoded_bytes"],
        "manifest wire length mismatch",
    )
    entries: list[Record] = []
    saw_zero_slot = False
    for _ in range(checked_plan["segment_count"]):
        slot = encoded[offset : offset + ATTEMPT_BYTES]
        _require(len(slot) == ATTEMPT_BYTES, "truncated attempt slot")
        offset += ATTEMPT_BYTES
        if slot == bytes(ATTEMPT_BYTES):
            saw_zero_slot = True
            continue
        _require(
            not saw_zero_slot,
            "nonzero attempt follows the canonical zero suffix",
        )
        entry, entry_offset = _decode_fields(
            slot,
            0,
            ATTEMPT_SCALAR_FIELDS,
            ATTEMPT_DIGEST_FIELDS,
        )
        _require(entry_offset == ATTEMPT_BYTES, "invalid attempt slot")
        entries.append(entry)
    _require(
        offset + MANIFEST_FOOTER_BYTES == len(encoded),
        "manifest has a truncated or extended body",
    )
    body_sha256 = encoded[offset : offset + 32]
    manifest_sha256 = encoded[offset + 32 : offset + 64]
    _require(entries, "manifest has no completed attempt prefix")
    expected_body, expected_manifest = _manifest_roots(encoded[:offset])
    _require(body_sha256 == expected_body, "manifest body root mismatch")
    _require(
        manifest_sha256 == expected_manifest,
        "manifest footer root mismatch",
    )
    # Re-encoding performs complete entry, chain, aggregate, timing, metric,
    # and provenance validation and also rules out alternate encodings.
    _require(
        make_manifest(checked_plan, entries) == encoded,
        "manifest is not canonical",
    )
    return {
        "plan": checked_plan,
        "entries": entries,
        "completed_segment_count": len(entries),
        "body_sha256": body_sha256,
        "manifest_sha256": manifest_sha256,
    }


def verify_manifest(encoded: bytes) -> Record:
    return decode_manifest(encoded)


def make_selector(
    manifest: bytes | Mapping[str, Any],
    environment_sha256: Digest,
) -> bytes:
    decoded = (
        decode_manifest(manifest)
        if isinstance(manifest, bytes)
        else manifest
    )
    _require(
        isinstance(decoded, Mapping)
        and set(decoded) >= {"plan", "entries", "manifest_sha256"},
        "invalid decoded manifest",
    )
    plan = decoded["plan"]
    entries = decoded["entries"]
    _require(entries, "selector cannot name an empty manifest")
    selector: Record = {
        "abi_version": SELECTOR_ABI,
        "encoded_bytes": SELECTOR_BYTES,
        "flags": ALLOWED_SELECTOR_FLAGS,
        "generation": len(entries),
        "segment_count": plan["segment_count"],
        "total_records": entries[-1]["cumulative_records"],
        "total_completed": entries[-1]["cumulative_completed"],
        "total_events": _checked_mul(
            len(entries),
            entries[-1]["event_count"],
            "selector cumulative events",
        ),
        "campaign_challenge_sha256": plan[
            "campaign_challenge_sha256"
        ],
        "manifest_sha256": decoded["manifest_sha256"],
        "environment_sha256": _nonzero_digest(
            environment_sha256,
            "environment_sha256",
        ),
        "selector_sha256": ZERO_DIGEST,
    }
    body = _encode_fields(
        selector,
        SELECTOR_SCALAR_FIELDS,
        SELECTOR_DIGEST_FIELDS[:-1],
    )
    _require(len(body) == SELECTOR_BODY_BYTES, "selector body length mismatch")
    selector["selector_sha256"] = _hash(SELECTOR_DOMAIN, (body,))
    return _encode_fields(
        selector,
        SELECTOR_SCALAR_FIELDS,
        SELECTOR_DIGEST_FIELDS,
    )


def encode_selector(selector: Mapping[str, Any]) -> bytes:
    checked = _copy_fields(
        selector,
        SELECTOR_SCALAR_FIELDS,
        SELECTOR_DIGEST_FIELDS,
        "selector",
    )
    _validate_selector(checked)
    return _encode_fields(
        checked,
        SELECTOR_SCALAR_FIELDS,
        SELECTOR_DIGEST_FIELDS,
    )


def _validate_selector(selector: Mapping[str, Any]) -> None:
    _require(
        selector["abi_version"] == SELECTOR_ABI,
        "invalid selector ABI",
    )
    _require(
        selector["encoded_bytes"] == SELECTOR_BYTES,
        "invalid selector encoded length",
    )
    _require(
        selector["flags"] == ALLOWED_SELECTOR_FLAGS,
        "invalid selector flags",
    )
    _require(
        0 < selector["generation"] <= selector["segment_count"]
        and selector["segment_count"] <= MAX_SEGMENTS,
        "invalid selector generation",
    )
    _require(
        selector["total_records"] > 0
        and selector["total_completed"] > 0
        and selector["total_events"] > 0,
        "invalid selector totals",
    )
    for field in SELECTOR_DIGEST_FIELDS:
        _nonzero_digest(selector[field], "selector.%s" % field)
    body = _encode_fields(
        selector,
        SELECTOR_SCALAR_FIELDS,
        SELECTOR_DIGEST_FIELDS[:-1],
    )
    _require(
        selector["selector_sha256"] == _hash(SELECTOR_DOMAIN, (body,)),
        "selector root mismatch",
    )


def decode_selector(encoded: bytes) -> Record:
    _require(
        isinstance(encoded, bytes) and len(encoded) == SELECTOR_BYTES,
        "invalid selector length",
    )
    selector, offset = _decode_fields(
        encoded,
        0,
        SELECTOR_SCALAR_FIELDS,
        SELECTOR_DIGEST_FIELDS,
    )
    _require(offset == len(encoded), "selector has trailing bytes")
    _validate_selector(selector)
    return selector


def verify_selector(
    manifest_wire: bytes,
    selector_wire: bytes,
    expected_environment_sha256: Digest | None = None,
) -> Record:
    manifest = decode_manifest(manifest_wire)
    selector = decode_selector(selector_wire)
    plan = manifest["plan"]
    entries = manifest["entries"]
    expected = {
        "generation": len(entries),
        "segment_count": plan["segment_count"],
        "total_records": entries[-1]["cumulative_records"],
        "total_completed": entries[-1]["cumulative_completed"],
        "total_events": _checked_mul(
            len(entries),
            entries[-1]["event_count"],
            "selector cumulative events",
        ),
        "campaign_challenge_sha256": plan[
            "campaign_challenge_sha256"
        ],
        "manifest_sha256": manifest["manifest_sha256"],
    }
    for field, value in expected.items():
        _require(
            selector[field] == value,
            "selector %s does not match manifest" % field,
        )
    if expected_environment_sha256 is not None:
        _require(
            selector["environment_sha256"]
            == _nonzero_digest(
                expected_environment_sha256,
                "expected_environment_sha256",
            ),
            "selector environment does not match the supervisor envelope",
        )
    _require(
        make_selector(
            manifest,
            selector["environment_sha256"],
        )
        == selector_wire,
        "selector is not canonical",
    )
    return selector


__all__ = [
    "ALLOWED_FLAGS",
    "ALLOWED_MANIFEST_FLAGS",
    "ALLOWED_PROVENANCE_BITS",
    "ALLOWED_SELECTOR_FLAGS",
    "ACTION_FORCED_PHASE_END",
    "ACTION_GRACEFUL_PHASE_END",
    "ACTION_NORMAL",
    "ATTEMPT_ABI",
    "ATTEMPT_BYTES",
    "ATTEMPT_DIGEST_FIELDS",
    "ATTEMPT_SCALAR_FIELDS",
    "AVAILABILITY_DENIED",
    "AVAILABILITY_MISSING",
    "AVAILABILITY_PRESENT",
    "AVAILABILITY_UNSUPPORTED",
    "BASE_PROVENANCE_BITS",
    "CAMPAIGN_ID_DOMAIN",
    "CampaignManifestError",
    "DISPOSITION_COMPLETE",
    "DISPOSITION_VERIFIED_REPORT",
    "MANIFEST_ABI",
    "MANIFEST_FOOTER_BYTES",
    "MANIFEST_HEADER_BYTES",
    "PLAN_DIGEST_FIELDS",
    "PLAN_SCALAR_FIELDS",
    "PROVENANCE_CONTROLLED_SOFTWARE",
    "PROVENANCE_DERIVED_SYNTHETIC",
    "PROVENANCE_FORCED_OS_PROCESS_KILL",
    "PROVENANCE_NATIVE_HOST_OBSERVATION",
    "PROVENANCE_PLANNED_GRACEFUL_RESTART",
    "PROVENANCE_PRODUCTION_NATIVE",
    "PLAN_FLAG_FORCED_PROCESS_RESTART",
    "SELECTOR_ABI",
    "SELECTOR_BYTES",
    "SELECTOR_DIGEST_FIELDS",
    "SELECTOR_SCALAR_FIELDS",
    "TERMINATION_SIGNAL_KILL",
    "U64_MAX",
    "ZERO_DIGEST",
    "decode_manifest",
    "decode_selector",
    "derive_campaign_id",
    "derive_device_allocation_unavailable_reason",
    "derive_environment_sha256",
    "derive_metric_unavailable_reason",
    "derive_plan_sha256",
    "derive_scheduled_action",
    "derive_segment_challenge",
    "encode_manifest",
    "encode_selector",
    "encoded_manifest_bytes",
    "entry_root",
    "make_entry",
    "make_manifest",
    "make_selector",
    "seal_plan",
    "verify_manifest",
    "verify_selector",
]
