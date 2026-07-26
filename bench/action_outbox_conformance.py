"""Independent ActionOutbox journal and recovery conformance oracle.

This module reimplements the pointer-free little-endian wire, hash domains,
lifecycle replay, committed-prefix recovery, and retained W4b-b campaign.  It
does not import native code and grants no filesystem, network, credential,
clock, random-number, or external-provider authority.  Opaque acknowledgement
and reconciliation roots are evidence inputs, not proof that a remote effect
actually happened.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import struct
import subprocess
import sys
from copy import deepcopy
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping, Sequence

from bench import typed_tool_conformance as tool


class ActionOutboxError(ValueError):
    """The outbox wire, lifecycle, recovery, or report is invalid."""


Record = dict[str, Any]
Digest = bytes

U64_MAX = (1 << 64) - 1
ZERO_DIGEST = bytes(32)

HEADER_ABI = 0x4754_4F48_0000_0001
IDENTITY_ABI = 0x4754_4F49_0000_0001
RECORD_ABI = 0x4754_4F52_0000_0001
CLOSED_ANCHOR_ABI = 0x4754_4F43_0000_0001
REPORT_ABI = 0x4754_4F50_0000_0001

HEADER_MAGIC = b"GTAOBXH1"
RECORD_MAGIC = b"GTAOBXR1"
COMMIT_MAGIC = b"GTAOBCM1"

HEADER_BYTES = 320
RECORD_BODY_BYTES = 704
COMMIT_FOOTER_BYTES = 48
RECORD_BYTES = RECORD_BODY_BYTES + COMMIT_FOOTER_BYTES
MAXIMUM_SUPPORTED_ACTIONS = 64
MAXIMUM_SUPPORTED_RECORDS = 256

CAPABILITY_STABLE_IDEMPOTENCY = 1 << 0
CAPABILITY_AUTHORITATIVE_RECONCILIATION = 1 << 1
REQUIRED_CAPABILITIES = (
    CAPABILITY_STABLE_IDEMPOTENCY | CAPABILITY_AUTHORITATIVE_RECONCILIATION
)

PURPOSE_PRIMARY = 1
PURPOSE_COMPENSATION = 2

EVENT_ENQUEUED = 1
EVENT_DISPATCH_INTENT = 2
EVENT_AMBIGUITY_OBSERVED = 3
EVENT_ACKNOWLEDGED_SUCCESS = 4
EVENT_ACKNOWLEDGED_FAILURE = 5
EVENT_RECONCILED_NOT_APPLIED = 6
EVENT_RECONCILED_SUCCESS = 7
EVENT_RECONCILED_FAILURE = 8
EVENT_KINDS = frozenset(range(EVENT_ENQUEUED, EVENT_RECONCILED_FAILURE + 1))
EVENT_NAMES = {
    EVENT_ENQUEUED: "enqueued",
    EVENT_DISPATCH_INTENT: "dispatch_intent",
    EVENT_AMBIGUITY_OBSERVED: "ambiguity_observed",
    EVENT_ACKNOWLEDGED_SUCCESS: "acknowledged_success",
    EVENT_ACKNOWLEDGED_FAILURE: "acknowledged_failure",
    EVENT_RECONCILED_NOT_APPLIED: "reconciled_not_applied",
    EVENT_RECONCILED_SUCCESS: "reconciled_success",
    EVENT_RECONCILED_FAILURE: "reconciled_failure",
}
EVENT_VALUES = {name: kind for kind, name in EVENT_NAMES.items()}

PHASE_FREE = 0
PHASE_READY = 1
PHASE_UNCERTAIN = 2
PHASE_SUCCEEDED = 3
PHASE_FAILED = 4
PHASES = frozenset(range(PHASE_FREE, PHASE_FAILED + 1))

RECOVERY_CLEAN = 1
RECOVERY_SHORT_BODY_TAIL = 2
RECOVERY_BODY_WITHOUT_FOOTER = 3
RECOVERY_PARTIAL_FOOTER_TAIL = 4
RECOVERY_NAMES = {
    RECOVERY_CLEAN: "clean",
    RECOVERY_SHORT_BODY_TAIL: "short_body_tail",
    RECOVERY_BODY_WITHOUT_FOOTER: "body_without_footer",
    RECOVERY_PARTIAL_FOOTER_TAIL: "partial_footer_tail",
}

HEADER_DOMAIN = b"glacier-tool-action-outbox-header-v1\x00"
ACTION_DOMAIN = b"glacier-tool-action-outbox-identity-v1\x00"
REMOTE_REQUEST_DOMAIN = b"glacier-tool-action-outbox-remote-request-v1\x00"
DISPATCH_REQUEST_DOMAIN = b"glacier-tool-action-outbox-dispatch-request-v1\x00"
RECORD_DOMAIN = b"glacier-tool-action-outbox-record-v1\x00"
STATE_DOMAIN = b"glacier-tool-action-outbox-state-v1\x00"
LEDGER_DOMAIN = b"glacier-tool-action-outbox-ledger-v1\x00"
CLOSED_ANCHOR_DOMAIN = b"glacier-tool-action-outbox-closed-anchor-v1\x00"

CAMPAIGN_DOMAIN = b"glacier-action-outbox-campaign-v1\x00"
RECORD_SECTION_DOMAIN = b"glacier-action-outbox-record-section-v1\x00"
RECOVERY_CASE_DOMAIN = b"glacier-action-outbox-recovery-leaf-v1\x00"
RECOVERY_MATRIX_DOMAIN = b"glacier-action-outbox-recovery-matrix-v1\x00"
TORN_CASE_DOMAIN = b"glacier-action-outbox-torn-case-v1\x00"
REPORT_DOMAIN = b"glacier-action-outbox-conformance-report-v1\x00"

HEADER_FIELDS = (
    "abi_version",
    "flags",
    "outbox_epoch",
    "outbox_id",
    "tenant_key",
    "maximum_actions",
    "maximum_records",
    "maximum_payload_bytes",
    "capability_bits",
    "adapter_descriptor_sha256",
    "payload_store_descriptor_sha256",
    "challenge_sha256",
    "header_sha256",
)
IDENTITY_FIELDS = (
    "abi_version",
    "purpose",
    "action_ordinal",
    "payload_bytes",
    "parent_action_sha256",
    "descriptor_sha256",
    "arguments_sha256",
    "proposal_sha256",
    "policy_sha256",
    "authorization_sha256",
    "idempotency_key_sha256",
    "service_event_sha256",
    "payload_locator_sha256",
    "payload_sha256",
    "action_sha256",
    "stable_remote_request_sha256",
)
RECORD_FIELDS = (
    "abi_version",
    "sequence",
    "kind",
    "attempt_generation",
    "identity",
    "previous_action_event_sha256",
    "previous_journal_sha256",
    "dispatch_request_sha256",
    "observation_sha256",
    "result_sha256",
    "record_sha256",
)
STATE_FIELDS = (
    "occupied",
    "identity",
    "phase",
    "attempt_generation",
    "dispatch_request_sha256",
    "observation_sha256",
    "result_sha256",
    "last_event_sha256",
)
LEDGER_FIELDS = (
    "committed_records",
    "actions_enqueued",
    "primary_actions",
    "compensation_actions",
    "dispatch_intents",
    "safe_retry_dispatches",
    "ambiguity_observations",
    "acknowledged_successes",
    "acknowledged_failures",
    "reconciled_not_applied",
    "reconciled_successes",
    "reconciled_failures",
    "ready_actions",
    "uncertain_actions",
    "succeeded_actions",
    "failed_actions",
)
CLOSED_ANCHOR_FIELDS = (
    "abi_version",
    "header_sha256",
    "committed_bytes",
    "committed_records",
    "final_chain_sha256",
    "state_sha256",
    "ledger_sha256",
    "anchor_sha256",
)

REPORT_SCHEMA = "glacier.action-outbox-conformance/v1"
REPORT_FIELDS = (
    "schema",
    "report_abi",
    "header_abi",
    "identity_abi",
    "record_abi",
    "closed_anchor_abi",
    "header_bytes",
    "record_body_bytes",
    "commit_footer_bytes",
    "record_bytes",
    "journal_bytes",
    "record_count",
    "action_count",
    "recovery_cut_count",
    "header_sha256",
    "primary_proposal_sha256",
    "primary_authorization_sha256",
    "primary_action_sha256",
    "compensation_proposal_sha256",
    "compensation_authorization_sha256",
    "compensation_action_sha256",
    "record_section_sha256",
    "final_chain_sha256",
    "final_state_sha256",
    "ledger_sha256",
    "closed_anchor_sha256",
    "recovery_matrix_sha256",
    "torn_case_sha256",
    "report_sha256",
    "event_kinds",
    "attempt_generations",
    "ledger",
)
MAXIMUM_JSON_BYTES = 1024 * 1024

# Filled from the independent implementation and intentionally excludes a
# canonical-JSON byte count.  The binary semantic roots are the frozen ABI.
REFERENCE_ROOTS: Mapping[str, str] = {
    "header_sha256": (
        "23e2f979a3ada7b25b4f4d2b04b5dd372b4a30db3ea25ac63adcd7cabf45ed83"
    ),
    "primary_proposal_sha256": (
        "db94b0f1164303ad2b3bd0f0453f69d1b57aba6cd19faa21903c652f4d27f6af"
    ),
    "primary_authorization_sha256": (
        "daf1f3f4c3bc9c8cb5e18ebe90d9ff74e05a7b4436f726679f505de4841b8170"
    ),
    "primary_action_sha256": (
        "90537ae0826dbe2bac75198f10c62017b9ea89e0cf77e5cd99c16257d6344d14"
    ),
    "compensation_proposal_sha256": (
        "84f61a862df8e57009166b30ff2d663f2b268cd7c8811ac69af9f8ff7627bb8b"
    ),
    "compensation_authorization_sha256": (
        "0e1a132a718f48233e3fe3b7635e5de86f17c801ea2939e401a8780f648c6dde"
    ),
    "compensation_action_sha256": (
        "d80647ab9e9c2073898bd8cadc860d3972919c2d434c6abc87ef081a5bb951e1"
    ),
    "record_section_sha256": (
        "cbbd9870e0dd0269b31f4b2bb8ce0be3059f306c5ba52d840b706c67453b6ff2"
    ),
    "final_chain_sha256": (
        "c829759dac8a746ccaf4dfa62709447ab0685932bd8278e516f0f9155b278285"
    ),
    "final_state_sha256": (
        "67703ddfdf3a3cd05157db80cc13481b563c258eeef4805fbda7249aa3dab26b"
    ),
    "ledger_sha256": (
        "68f73e9b396db1e89d4cccd3f55316034cc81b6d0fad36eab71b75f26b37987e"
    ),
    "closed_anchor_sha256": (
        "6c7a4f9a801bf47070772fd8a91d9ac11a76583d5bfbd68e93e8ce09388bc8c7"
    ),
    "recovery_matrix_sha256": (
        "c2e33a0a49d66d559a1929bbd1cf11491a77b28dd0fc7d0c62278c0655ebc485"
    ),
    "torn_case_sha256": (
        "3f0b73d54b11c57f588a61a7dbee7c67096bd57a1aa7ad0d94d96b47fc9619ef"
    ),
    "report_sha256": (
        "23d6019e2b3b1171f12255bd353e2f90d0da38fa6b8d15a38503a938cb3f8f8e"
    ),
}
REFERENCE_RECORD_ROOTS: tuple[str, ...] = (
    "96e2764090c6b6fe6e859d3059bd36b38aa6ed11fd2e94568422630651ef505e",
    "504731064301e16cf9d63c9b0807f8b32e387173868bdbd0d4b5a59f94042b54",
    "d8bc46dbd6e1ca2410c27af434ae5cf35a46b312b4de84f99a402f52e06458e3",
    "138a11d350d27c151e4d771b9d5f18fe6787819c8bbab7d3c01f51ca7ff1dc88",
    "3177b8b8f4e8eed422e4919db8b8efee9da69d05e74befdd6fae2ffd3f31257b",
    "66a5f026e142cd002fc2119afe20ec79c35d6467bc0250beaf2d3dcfa2723b5e",
    "4e34108d8c646cbbc7060efb3eba63b1691df46e7bb10eceac7601cb4040e8e1",
    "659bdb3cc9d171355e2dca527125aca5d921ed4ce5de2c983418e4da68592ef8",
    "5b6633b4181979b0008e0bafb393e7f2089ab783783f4797137222a4975dc034",
    "c829759dac8a746ccaf4dfa62709447ab0685932bd8278e516f0f9155b278285",
)


def _strict_record(value: Any, fields: Sequence[str], where: str) -> Record:
    if not isinstance(value, dict) or tuple(value) != tuple(fields):
        raise ActionOutboxError(f"{where} has noncanonical fields")
    return value


def _u64(value: Any, where: str) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise ActionOutboxError(f"{where} is not u64")
    return value


def _bool(value: Any, where: str) -> bool:
    if type(value) is not bool:
        raise ActionOutboxError(f"{where} is not bool")
    return value


def _digest(value: Any, where: str, *, allow_zero: bool = False) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise ActionOutboxError(f"{where} is not a digest")
    if not allow_zero and hmac.compare_digest(value, ZERO_DIGEST):
        raise ActionOutboxError(f"{where} is zero")
    return value


def _enum(
    value: Any, allowed: Sequence[int] | set[int] | frozenset[int], where: str
) -> int:
    result = _u64(value, where)
    if result not in allowed:
        raise ActionOutboxError(f"{where} is not a known enum value")
    return result


def _add_u64(left: int, right: int) -> int:
    result = left + right
    return _u64(result, "u64 addition")


def _le_u8(value: int) -> bytes:
    checked = _u64(value, "u8")
    if checked > 0xFF:
        raise ActionOutboxError("u8 out of range")
    return struct.pack("<B", checked)


def _le_u64(value: int) -> bytes:
    return struct.pack("<Q", _u64(value, "u64"))


def _read_u64(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _sha(domain: bytes, *parts: bytes) -> Digest:
    result = hashlib.sha256()
    result.update(domain)
    for part in parts:
        result.update(part)
    return result.digest()


def _label(value: str) -> Digest:
    return hashlib.sha256(value.encode("ascii")).digest()


def _hex_digest(value: Any, where: str) -> Digest:
    if type(value) is not str or len(value) != 64:
        raise ActionOutboxError(f"{where} is not a lowercase digest")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise ActionOutboxError(f"{where} is not a lowercase digest") from error
    if decoded.hex() != value:
        raise ActionOutboxError(f"{where} is not a lowercase digest")
    return decoded


def _hex_u64(value: Any, where: str) -> int:
    if type(value) is not str or len(value) != 16:
        raise ActionOutboxError(f"{where} is not a 16-character lowercase u64")
    try:
        decoded = int(value, 16)
    except ValueError as error:
        raise ActionOutboxError(
            f"{where} is not a 16-character lowercase u64"
        ) from error
    if f"{decoded:016x}" != value:
        raise ActionOutboxError(f"{where} is not a 16-character lowercase u64")
    return decoded


def header_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        HEADER_DOMAIN,
        *(_le_u64(value[name]) for name in HEADER_FIELDS[:9]),
        _digest(value["adapter_descriptor_sha256"], "adapter descriptor"),
        _digest(value["payload_store_descriptor_sha256"], "payload store descriptor"),
        _digest(value["challenge_sha256"], "header challenge"),
    )


def make_header(
    outbox_epoch: int,
    outbox_id: int,
    tenant_key: int,
    maximum_actions: int,
    maximum_records: int,
    maximum_payload_bytes: int,
    adapter_descriptor_sha256: Digest,
    payload_store_descriptor_sha256: Digest,
    challenge_sha256: Digest,
) -> Record:
    result: Record = {
        "abi_version": HEADER_ABI,
        "flags": 0,
        "outbox_epoch": outbox_epoch,
        "outbox_id": outbox_id,
        "tenant_key": tenant_key,
        "maximum_actions": maximum_actions,
        "maximum_records": maximum_records,
        "maximum_payload_bytes": maximum_payload_bytes,
        "capability_bits": REQUIRED_CAPABILITIES,
        "adapter_descriptor_sha256": adapter_descriptor_sha256,
        "payload_store_descriptor_sha256": payload_store_descriptor_sha256,
        "challenge_sha256": challenge_sha256,
        "header_sha256": ZERO_DIGEST,
    }
    result["header_sha256"] = header_sha256(result)
    return validate_header(result)


def validate_header(value: Any) -> Record:
    result = _strict_record(value, HEADER_FIELDS, "outbox header")
    for name in HEADER_FIELDS[:9]:
        _u64(result[name], f"header {name}")
    for name in HEADER_FIELDS[9:]:
        _digest(result[name], f"header {name}")
    if (
        result["abi_version"] != HEADER_ABI
        or result["flags"] != 0
        or result["outbox_epoch"] == 0
        or result["outbox_id"] == 0
        or result["tenant_key"] == 0
        or not 0 < result["maximum_actions"] <= MAXIMUM_SUPPORTED_ACTIONS
        or not 0 < result["maximum_records"] <= MAXIMUM_SUPPORTED_RECORDS
        or result["maximum_records"] < result["maximum_actions"]
        or result["maximum_payload_bytes"] == 0
        or result["capability_bits"] != REQUIRED_CAPABILITIES
        or not hmac.compare_digest(result["header_sha256"], header_sha256(result))
    ):
        raise ActionOutboxError("invalid outbox header")
    return deepcopy(result)


def encode_header(value: Any) -> bytes:
    header = validate_header(value)
    encoded = bytearray(HEADER_BYTES)
    encoded[:8] = HEADER_MAGIC
    struct.pack_into(
        "<10Q",
        encoded,
        8,
        header["abi_version"],
        HEADER_BYTES,
        header["flags"],
        header["outbox_epoch"],
        header["outbox_id"],
        header["tenant_key"],
        header["maximum_actions"],
        header["maximum_records"],
        header["maximum_payload_bytes"],
        header["capability_bits"],
    )
    offset = 96
    for name in HEADER_FIELDS[9:]:
        encoded[offset : offset + 32] = header[name]
        offset += 32
    return bytes(encoded)


def decode_header(encoded: bytes, expected_header_sha256: Digest) -> Record:
    expected = _digest(expected_header_sha256, "expected header")
    if type(encoded) is not bytes or len(encoded) != HEADER_BYTES:
        raise ActionOutboxError("invalid header length")
    if (
        encoded[:8] != HEADER_MAGIC
        or _read_u64(encoded, 16) != HEADER_BYTES
        or any(encoded[88:96])
        or any(encoded[224:])
    ):
        raise ActionOutboxError("invalid header framing or reserved bytes")
    values = struct.unpack_from("<10Q", encoded, 8)
    result: Record = {
        "abi_version": values[0],
        "flags": values[2],
        "outbox_epoch": values[3],
        "outbox_id": values[4],
        "tenant_key": values[5],
        "maximum_actions": values[6],
        "maximum_records": values[7],
        "maximum_payload_bytes": values[8],
        "capability_bits": values[9],
        "adapter_descriptor_sha256": encoded[96:128],
        "payload_store_descriptor_sha256": encoded[128:160],
        "challenge_sha256": encoded[160:192],
        "header_sha256": encoded[192:224],
    }
    header = validate_header(result)
    if not hmac.compare_digest(header["header_sha256"], expected):
        raise ActionOutboxError("unpinned outbox header")
    return header


def _hash_identity_parts(value: Mapping[str, Any]) -> tuple[bytes, ...]:
    return (
        _le_u64(value["abi_version"]),
        _le_u8(value["purpose"]),
        _le_u64(value["action_ordinal"]),
        _le_u64(value["payload_bytes"]),
        *(
            _digest(
                value[name],
                f"identity {name}",
                allow_zero=name == "parent_action_sha256",
            )
            for name in IDENTITY_FIELDS[4:]
        ),
    )


def action_identity_sha256(header_value: Any, value: Mapping[str, Any]) -> Digest:
    header = validate_header(header_value)
    return _sha(
        ACTION_DOMAIN,
        header["header_sha256"],
        _le_u64(value["abi_version"]),
        _le_u8(value["purpose"]),
        _le_u64(value["action_ordinal"]),
        _le_u64(value["payload_bytes"]),
        *(
            _digest(
                value[name],
                f"identity {name}",
                allow_zero=name == "parent_action_sha256",
            )
            for name in IDENTITY_FIELDS[4:14]
        ),
    )


def stable_remote_request_sha256(
    header_value: Any,
    value: Mapping[str, Any],
) -> Digest:
    header = validate_header(header_value)
    return _sha(
        REMOTE_REQUEST_DOMAIN,
        header["header_sha256"],
        header["adapter_descriptor_sha256"],
        _digest(value["action_sha256"], "action identity"),
        _digest(value["idempotency_key_sha256"], "idempotency key"),
    )


def validate_action_identity(header_value: Any, value: Any) -> Record:
    header = validate_header(header_value)
    result = _strict_record(value, IDENTITY_FIELDS, "action identity")
    for name in ("abi_version", "purpose", "action_ordinal", "payload_bytes"):
        _u64(result[name], f"identity {name}")
    _enum(result["purpose"], {PURPOSE_PRIMARY, PURPOSE_COMPENSATION}, "purpose")
    for name in IDENTITY_FIELDS[4:]:
        _digest(
            result[name],
            f"identity {name}",
            allow_zero=name == "parent_action_sha256",
        )
    if (
        result["abi_version"] != IDENTITY_ABI
        or result["action_ordinal"] == 0
        or not 0 < result["payload_bytes"] <= header["maximum_payload_bytes"]
        or (
            result["purpose"] == PURPOSE_PRIMARY
            and not hmac.compare_digest(result["parent_action_sha256"], ZERO_DIGEST)
        )
        or (
            result["purpose"] == PURPOSE_COMPENSATION
            and hmac.compare_digest(result["parent_action_sha256"], ZERO_DIGEST)
        )
        or not hmac.compare_digest(
            result["action_sha256"], action_identity_sha256(header, result)
        )
        or not hmac.compare_digest(
            result["stable_remote_request_sha256"],
            stable_remote_request_sha256(header, result),
        )
    ):
        raise ActionOutboxError("invalid action identity")
    return deepcopy(result)


def make_action_identity(
    header_value: Any,
    purpose: int,
    parent_action_sha256: Digest,
    descriptor: Any,
    arguments: Any,
    proposal: Any,
    policy: Any,
    authorization: Any,
    service_event_sha256: Digest,
    payload_locator_sha256: Digest,
    payload_bytes: int,
    payload_sha256: Digest,
) -> Record:
    header = validate_header(header_value)
    proposal_value, descriptor_value, argument_value = (
        tool.validate_proposal_composition(proposal, descriptor, arguments)
    )
    authorization_value, _, policy_value = tool.validate_authorization_composition(
        authorization, proposal_value, policy
    )
    _enum(purpose, {PURPOSE_PRIMARY, PURPOSE_COMPENSATION}, "purpose")
    parent = _digest(parent_action_sha256, "parent action", allow_zero=True)
    service = _digest(service_event_sha256, "service event")
    locator = _digest(payload_locator_sha256, "payload locator")
    payload = _digest(payload_sha256, "payload")
    size = _u64(payload_bytes, "payload bytes")
    if (
        authorization_value["kind"] != tool.AUTHORIZATION_ALLOWED
        or proposal_value["tenant_key"] != header["tenant_key"]
        or policy_value["tenant_key"] != header["tenant_key"]
        or not hmac.compare_digest(
            policy_value["descriptor_sha256"],
            descriptor_value["descriptor_sha256"],
        )
        or not 0 < size <= header["maximum_payload_bytes"]
        or (purpose == PURPOSE_PRIMARY and not hmac.compare_digest(parent, ZERO_DIGEST))
        or (
            purpose == PURPOSE_COMPENSATION and hmac.compare_digest(parent, ZERO_DIGEST)
        )
    ):
        raise ActionOutboxError("invalid action identity composition")
    result: Record = {
        "abi_version": IDENTITY_ABI,
        "purpose": purpose,
        "action_ordinal": proposal_value["action_ordinal"],
        "payload_bytes": size,
        "parent_action_sha256": parent,
        "descriptor_sha256": descriptor_value["descriptor_sha256"],
        "arguments_sha256": argument_value["arguments_sha256"],
        "proposal_sha256": proposal_value["proposal_sha256"],
        "policy_sha256": policy_value["policy_sha256"],
        "authorization_sha256": authorization_value["authorization_sha256"],
        "idempotency_key_sha256": proposal_value["idempotency_key_sha256"],
        "service_event_sha256": service,
        "payload_locator_sha256": locator,
        "payload_sha256": payload,
        "action_sha256": ZERO_DIGEST,
        "stable_remote_request_sha256": ZERO_DIGEST,
    }
    result["action_sha256"] = action_identity_sha256(header, result)
    result["stable_remote_request_sha256"] = stable_remote_request_sha256(
        header, result
    )
    return validate_action_identity(header, result)


def dispatch_request_sha256(
    header_value: Any,
    identity_value: Any,
    attempt_generation: int,
) -> Digest:
    header = validate_header(header_value)
    identity = validate_action_identity(header, identity_value)
    generation = _u64(attempt_generation, "attempt generation")
    return _sha(
        DISPATCH_REQUEST_DOMAIN,
        header["header_sha256"],
        identity["stable_remote_request_sha256"],
        _le_u64(generation),
    )


def record_sha256(header_value: Any, value: Mapping[str, Any]) -> Digest:
    header = validate_header(header_value)
    identity = validate_action_identity(header, value["identity"])
    return _sha(
        RECORD_DOMAIN,
        header["header_sha256"],
        _le_u64(value["abi_version"]),
        _le_u64(value["sequence"]),
        _le_u8(value["kind"]),
        _le_u64(value["attempt_generation"]),
        *_hash_identity_parts(identity),
        _digest(
            value["previous_action_event_sha256"],
            "previous action event",
            allow_zero=True,
        ),
        _digest(value["previous_journal_sha256"], "previous journal"),
        _digest(value["dispatch_request_sha256"], "dispatch request", allow_zero=True),
        _digest(value["observation_sha256"], "observation", allow_zero=True),
        _digest(value["result_sha256"], "result", allow_zero=True),
    )


def validate_record(header_value: Any, value: Any) -> Record:
    header = validate_header(header_value)
    result = _strict_record(value, RECORD_FIELDS, "outbox record")
    for name in ("abi_version", "sequence", "kind", "attempt_generation"):
        _u64(result[name], f"record {name}")
    kind = _enum(result["kind"], EVENT_KINDS, "record kind")
    validate_action_identity(header, result["identity"])
    for name in RECORD_FIELDS[5:]:
        _digest(
            result[name],
            f"record {name}",
            allow_zero=name
            in {
                "previous_action_event_sha256",
                "dispatch_request_sha256",
                "observation_sha256",
                "result_sha256",
            },
        )
    if (
        result["abi_version"] != RECORD_ABI
        or result["sequence"] == 0
        or not hmac.compare_digest(
            result["record_sha256"], record_sha256(header, result)
        )
    ):
        raise ActionOutboxError("invalid outbox record")
    previous = result["previous_action_event_sha256"]
    dispatch = result["dispatch_request_sha256"]
    observation = result["observation_sha256"]
    output = result["result_sha256"]
    if kind == EVENT_ENQUEUED:
        valid = (
            result["attempt_generation"] == 0
            and hmac.compare_digest(previous, ZERO_DIGEST)
            and hmac.compare_digest(dispatch, ZERO_DIGEST)
            and hmac.compare_digest(observation, ZERO_DIGEST)
            and hmac.compare_digest(output, ZERO_DIGEST)
        )
    elif kind == EVENT_DISPATCH_INTENT:
        valid = (
            result["attempt_generation"] != 0
            and not hmac.compare_digest(previous, ZERO_DIGEST)
            and not hmac.compare_digest(dispatch, ZERO_DIGEST)
            and hmac.compare_digest(observation, ZERO_DIGEST)
            and hmac.compare_digest(output, ZERO_DIGEST)
        )
    elif kind in {EVENT_AMBIGUITY_OBSERVED, EVENT_RECONCILED_NOT_APPLIED}:
        valid = (
            result["attempt_generation"] != 0
            and not hmac.compare_digest(previous, ZERO_DIGEST)
            and not hmac.compare_digest(dispatch, ZERO_DIGEST)
            and not hmac.compare_digest(observation, ZERO_DIGEST)
            and hmac.compare_digest(output, ZERO_DIGEST)
        )
    else:
        valid = (
            result["attempt_generation"] != 0
            and not hmac.compare_digest(previous, ZERO_DIGEST)
            and not hmac.compare_digest(dispatch, ZERO_DIGEST)
            and not hmac.compare_digest(observation, ZERO_DIGEST)
            and not hmac.compare_digest(output, ZERO_DIGEST)
        )
    if not valid:
        raise ActionOutboxError("record fields contradict event kind")
    return deepcopy(result)


def make_enqueued_record(
    header_value: Any,
    sequence: int,
    previous_journal_sha256: Digest,
    identity_value: Any,
) -> Record:
    header = validate_header(header_value)
    identity = validate_action_identity(header, identity_value)
    result: Record = {
        "abi_version": RECORD_ABI,
        "sequence": _u64(sequence, "record sequence"),
        "kind": EVENT_ENQUEUED,
        "attempt_generation": 0,
        "identity": identity,
        "previous_action_event_sha256": ZERO_DIGEST,
        "previous_journal_sha256": _digest(previous_journal_sha256, "previous journal"),
        "dispatch_request_sha256": ZERO_DIGEST,
        "observation_sha256": ZERO_DIGEST,
        "result_sha256": ZERO_DIGEST,
        "record_sha256": ZERO_DIGEST,
    }
    result["record_sha256"] = record_sha256(header, result)
    return validate_record(header, result)


def make_transition_record(
    header_value: Any,
    sequence: int,
    previous_journal_sha256: Digest,
    state_value: Any,
    kind: int,
    attempt_generation: int,
    observation_sha256: Digest,
    result_sha256: Digest,
) -> Record:
    header = validate_header(header_value)
    state = validate_state(header, state_value)
    event_kind = _enum(kind, EVENT_KINDS - {EVENT_ENQUEUED}, "transition kind")
    generation = _u64(attempt_generation, "attempt generation")
    observation = _digest(observation_sha256, "observation", allow_zero=True)
    output = _digest(result_sha256, "result", allow_zero=True)
    if not state["occupied"]:
        raise ActionOutboxError("transition requires an occupied action")
    dispatch = state["dispatch_request_sha256"]
    if event_kind == EVENT_DISPATCH_INTENT:
        if (
            state["phase"] != PHASE_READY
            or generation != _add_u64(state["attempt_generation"], 1)
            or not hmac.compare_digest(observation, ZERO_DIGEST)
            or not hmac.compare_digest(output, ZERO_DIGEST)
        ):
            raise ActionOutboxError("invalid dispatch transition")
        dispatch = dispatch_request_sha256(header, state["identity"], generation)
    elif event_kind in {EVENT_AMBIGUITY_OBSERVED, EVENT_RECONCILED_NOT_APPLIED}:
        if (
            state["phase"] != PHASE_UNCERTAIN
            or generation != state["attempt_generation"]
            or hmac.compare_digest(dispatch, ZERO_DIGEST)
            or hmac.compare_digest(observation, ZERO_DIGEST)
            or not hmac.compare_digest(output, ZERO_DIGEST)
        ):
            raise ActionOutboxError("invalid nonterminal observation transition")
    elif (
        state["phase"] != PHASE_UNCERTAIN
        or generation != state["attempt_generation"]
        or hmac.compare_digest(dispatch, ZERO_DIGEST)
        or hmac.compare_digest(observation, ZERO_DIGEST)
        or hmac.compare_digest(output, ZERO_DIGEST)
    ):
        raise ActionOutboxError("invalid terminal observation transition")
    result: Record = {
        "abi_version": RECORD_ABI,
        "sequence": _u64(sequence, "record sequence"),
        "kind": event_kind,
        "attempt_generation": generation,
        "identity": state["identity"],
        "previous_action_event_sha256": state["last_event_sha256"],
        "previous_journal_sha256": _digest(previous_journal_sha256, "previous journal"),
        "dispatch_request_sha256": dispatch,
        "observation_sha256": observation,
        "result_sha256": output,
        "record_sha256": ZERO_DIGEST,
    }
    result["record_sha256"] = record_sha256(header, result)
    return validate_record(header, result)


def encode_record(header_value: Any, value: Any) -> bytes:
    header = validate_header(header_value)
    record = validate_record(header, value)
    encoded = bytearray(RECORD_BYTES)
    encoded[:8] = RECORD_MAGIC
    struct.pack_into(
        "<8Q",
        encoded,
        8,
        record["abi_version"],
        RECORD_BODY_BYTES,
        record["sequence"],
        record["kind"],
        record["attempt_generation"],
        record["identity"]["purpose"],
        record["identity"]["action_ordinal"],
        record["identity"]["payload_bytes"],
    )
    offset = 80
    for name in IDENTITY_FIELDS[4:]:
        encoded[offset : offset + 32] = record["identity"][name]
        offset += 32
    for name in RECORD_FIELDS[5:]:
        encoded[offset : offset + 32] = record[name]
        offset += 32
    encoded[RECORD_BODY_BYTES : RECORD_BODY_BYTES + 8] = COMMIT_MAGIC
    struct.pack_into("<Q", encoded, RECORD_BODY_BYTES + 8, record["sequence"])
    encoded[RECORD_BODY_BYTES + 16 :] = record["record_sha256"]
    return bytes(encoded)


def decode_record(
    header_value: Any,
    expected_sequence: int,
    expected_previous_journal_sha256: Digest,
    encoded: bytes,
) -> Record:
    header = validate_header(header_value)
    previous = _digest(expected_previous_journal_sha256, "expected previous journal")
    if type(encoded) is not bytes or len(encoded) != RECORD_BYTES:
        raise ActionOutboxError("invalid record length")
    if (
        encoded[:8] != RECORD_MAGIC
        or _read_u64(encoded, 16) != RECORD_BODY_BYTES
        or any(encoded[72:80])
        or any(encoded[656:RECORD_BODY_BYTES])
        or encoded[RECORD_BODY_BYTES : RECORD_BODY_BYTES + 8] != COMMIT_MAGIC
    ):
        raise ActionOutboxError("invalid record framing or reserved bytes")
    values = struct.unpack_from("<8Q", encoded, 8)
    offset = 80
    identity: Record = {
        "abi_version": IDENTITY_ABI,
        "purpose": values[5],
        "action_ordinal": values[6],
        "payload_bytes": values[7],
    }
    for name in IDENTITY_FIELDS[4:]:
        identity[name] = encoded[offset : offset + 32]
        offset += 32
    result: Record = {
        "abi_version": values[0],
        "sequence": values[2],
        "kind": values[3],
        "attempt_generation": values[4],
        "identity": identity,
    }
    for name in RECORD_FIELDS[5:]:
        result[name] = encoded[offset : offset + 32]
        offset += 32
    record = validate_record(header, result)
    if (
        record["sequence"] != _u64(expected_sequence, "expected sequence")
        or not hmac.compare_digest(record["previous_journal_sha256"], previous)
        or _read_u64(encoded, RECORD_BODY_BYTES + 8) != record["sequence"]
        or not hmac.compare_digest(
            encoded[RECORD_BODY_BYTES + 16 :], record["record_sha256"]
        )
    ):
        raise ActionOutboxError("record sequence, chain, or footer mismatch")
    return record


def append_plan(
    header_value: Any,
    expected_sequence: int,
    expected_previous_journal_sha256: Digest,
    encoded_record: bytes,
) -> tuple[bytes, bytes]:
    decode_record(
        header_value,
        expected_sequence,
        expected_previous_journal_sha256,
        encoded_record,
    )
    return encoded_record[:RECORD_BODY_BYTES], encoded_record[RECORD_BODY_BYTES:]


def empty_ledger() -> Record:
    return {name: 0 for name in LEDGER_FIELDS}


def make_state(identity_value: Any) -> Record:
    return {
        "occupied": True,
        "identity": deepcopy(identity_value),
        "phase": PHASE_READY,
        "attempt_generation": 0,
        "dispatch_request_sha256": ZERO_DIGEST,
        "observation_sha256": ZERO_DIGEST,
        "result_sha256": ZERO_DIGEST,
        "last_event_sha256": ZERO_DIGEST,
    }


def validate_state(header_value: Any, value: Any) -> Record:
    header = validate_header(header_value)
    result = _strict_record(value, STATE_FIELDS, "action state")
    _bool(result["occupied"], "state occupied")
    validate_action_identity(header, result["identity"])
    _enum(result["phase"], PHASES, "state phase")
    _u64(result["attempt_generation"], "state attempt generation")
    for name in STATE_FIELDS[4:]:
        _digest(result[name], f"state {name}", allow_zero=True)
    if not result["occupied"] or result["phase"] == PHASE_FREE:
        raise ActionOutboxError("replayed state must be occupied")
    return deepcopy(result)


def validate_ledger(value: Any) -> Record:
    result = _strict_record(value, LEDGER_FIELDS, "outbox ledger")
    for name in LEDGER_FIELDS:
        _u64(result[name], f"ledger {name}")
    return deepcopy(result)


def _clear_phase_counts(ledger: Record) -> None:
    for name in LEDGER_FIELDS[-4:]:
        ledger[name] = 0


def finalize_ledger(states_value: Sequence[Any], ledger_value: Any) -> Record:
    ledger = validate_ledger(ledger_value)
    _clear_phase_counts(ledger)
    for raw_state in states_value:
        state = raw_state
        phase = state["phase"]
        if phase == PHASE_READY:
            field = "ready_actions"
        elif phase == PHASE_UNCERTAIN:
            field = "uncertain_actions"
        elif phase == PHASE_SUCCEEDED:
            field = "succeeded_actions"
        elif phase == PHASE_FAILED:
            field = "failed_actions"
        else:
            raise ActionOutboxError("invalid occupied action phase")
        ledger[field] = _add_u64(ledger[field], 1)
    if ledger["actions_enqueued"] != _add_u64(
        ledger["primary_actions"], ledger["compensation_actions"]
    ) or ledger["actions_enqueued"] != sum(ledger[name] for name in LEDGER_FIELDS[-4:]):
        raise ActionOutboxError("ledger action counts do not close")
    return ledger


def _find_state(states: Sequence[Record], action_sha256: Digest) -> int | None:
    for index, state in enumerate(states):
        if hmac.compare_digest(state["identity"]["action_sha256"], action_sha256):
            return index
    return None


def apply_record(
    header_value: Any,
    record_value: Any,
    states_value: Sequence[Any],
    ledger_value: Any,
) -> tuple[list[Record], Record]:
    header = validate_header(header_value)
    record = validate_record(header, record_value)
    states = [validate_state(header, value) for value in states_value]
    ledger = validate_ledger(ledger_value)
    _clear_phase_counts(ledger)
    expected = _add_u64(ledger["committed_records"], 1)
    if record["sequence"] != expected:
        raise ActionOutboxError("noncontiguous record sequence")
    if expected > header["maximum_records"]:
        raise ActionOutboxError("record capacity exceeded")
    ledger["committed_records"] = expected
    identity = record["identity"]
    action_root = identity["action_sha256"]
    state_index = _find_state(states, action_root)
    if record["kind"] == EVENT_ENQUEUED:
        if state_index is not None:
            raise ActionOutboxError("duplicate action")
        for state in states:
            existing = state["identity"]
            if hmac.compare_digest(
                existing["idempotency_key_sha256"],
                identity["idempotency_key_sha256"],
            ):
                raise ActionOutboxError("duplicate idempotency key")
            if hmac.compare_digest(
                existing["stable_remote_request_sha256"],
                identity["stable_remote_request_sha256"],
            ):
                raise ActionOutboxError("duplicate stable remote request")
            if (
                identity["purpose"] == PURPOSE_COMPENSATION
                and existing["purpose"] == PURPOSE_COMPENSATION
                and hmac.compare_digest(
                    existing["parent_action_sha256"],
                    identity["parent_action_sha256"],
                )
            ):
                raise ActionOutboxError("duplicate compensation")
        if len(states) >= header["maximum_actions"]:
            raise ActionOutboxError("action capacity exceeded")
        if identity["purpose"] == PURPOSE_COMPENSATION:
            parent_index = _find_state(states, identity["parent_action_sha256"])
            if parent_index is None:
                raise ActionOutboxError("compensation parent is missing")
            parent = states[parent_index]
            if (
                parent["identity"]["purpose"] != PURPOSE_PRIMARY
                or parent["phase"] != PHASE_SUCCEEDED
            ):
                raise ActionOutboxError("compensation parent has not succeeded")
            ledger["compensation_actions"] = _add_u64(ledger["compensation_actions"], 1)
        else:
            ledger["primary_actions"] = _add_u64(ledger["primary_actions"], 1)
        ledger["actions_enqueued"] = _add_u64(ledger["actions_enqueued"], 1)
        state = make_state(identity)
        state["last_event_sha256"] = record["record_sha256"]
        states.append(state)
        return states, ledger
    if state_index is None:
        raise ActionOutboxError("transition action is not enqueued")
    state = states[state_index]
    if state["identity"] != identity or not hmac.compare_digest(
        state["last_event_sha256"], record["previous_action_event_sha256"]
    ):
        raise ActionOutboxError("transition identity or action chain drift")
    next_state = deepcopy(state)
    kind = record["kind"]
    if kind == EVENT_DISPATCH_INTENT:
        if (
            state["phase"] != PHASE_READY
            or record["attempt_generation"] != _add_u64(state["attempt_generation"], 1)
            or not hmac.compare_digest(
                record["dispatch_request_sha256"],
                dispatch_request_sha256(header, identity, record["attempt_generation"]),
            )
        ):
            raise ActionOutboxError("unsafe or stale dispatch")
        if state["attempt_generation"] != 0:
            ledger["safe_retry_dispatches"] = _add_u64(
                ledger["safe_retry_dispatches"], 1
            )
        ledger["dispatch_intents"] = _add_u64(ledger["dispatch_intents"], 1)
        next_state["phase"] = PHASE_UNCERTAIN
        next_state["attempt_generation"] = record["attempt_generation"]
        next_state["dispatch_request_sha256"] = record["dispatch_request_sha256"]
        next_state["observation_sha256"] = ZERO_DIGEST
        next_state["result_sha256"] = ZERO_DIGEST
    else:
        if (
            state["phase"] != PHASE_UNCERTAIN
            or record["attempt_generation"] != state["attempt_generation"]
            or not hmac.compare_digest(
                record["dispatch_request_sha256"],
                state["dispatch_request_sha256"],
            )
        ):
            raise ActionOutboxError("observation is not for the current attempt")
        if kind == EVENT_AMBIGUITY_OBSERVED:
            ledger["ambiguity_observations"] = _add_u64(
                ledger["ambiguity_observations"], 1
            )
            next_state["observation_sha256"] = record["observation_sha256"]
        elif kind == EVENT_ACKNOWLEDGED_SUCCESS:
            ledger["acknowledged_successes"] = _add_u64(
                ledger["acknowledged_successes"], 1
            )
            next_state["phase"] = PHASE_SUCCEEDED
        elif kind == EVENT_ACKNOWLEDGED_FAILURE:
            ledger["acknowledged_failures"] = _add_u64(
                ledger["acknowledged_failures"], 1
            )
            next_state["phase"] = PHASE_FAILED
        elif kind == EVENT_RECONCILED_NOT_APPLIED:
            ledger["reconciled_not_applied"] = _add_u64(
                ledger["reconciled_not_applied"], 1
            )
            next_state["phase"] = PHASE_READY
            next_state["dispatch_request_sha256"] = ZERO_DIGEST
        elif kind == EVENT_RECONCILED_SUCCESS:
            ledger["reconciled_successes"] = _add_u64(ledger["reconciled_successes"], 1)
            next_state["phase"] = PHASE_SUCCEEDED
        elif kind == EVENT_RECONCILED_FAILURE:
            ledger["reconciled_failures"] = _add_u64(ledger["reconciled_failures"], 1)
            next_state["phase"] = PHASE_FAILED
        else:
            raise ActionOutboxError("unknown transition kind")
        next_state["observation_sha256"] = record["observation_sha256"]
        next_state["result_sha256"] = record["result_sha256"]
    next_state["last_event_sha256"] = record["record_sha256"]
    states[state_index] = next_state
    return states, ledger


def _hash_ledger_parts(ledger_value: Any) -> tuple[bytes, ...]:
    ledger = validate_ledger(ledger_value)
    return tuple(_le_u64(ledger[name]) for name in LEDGER_FIELDS)


def state_sha256(
    header_value: Any,
    states_value: Sequence[Any],
    ledger_value: Any,
) -> Digest:
    header = validate_header(header_value)
    states = [validate_state(header, value) for value in states_value]
    ledger = validate_ledger(ledger_value)
    parts: list[bytes] = [
        header["header_sha256"],
        _le_u64(len(states)),
    ]
    for state in states:
        parts.extend(
            (
                _le_u8(int(state["occupied"])),
                *_hash_identity_parts(state["identity"]),
                _le_u8(state["phase"]),
                _le_u64(state["attempt_generation"]),
                state["dispatch_request_sha256"],
                state["observation_sha256"],
                state["result_sha256"],
                state["last_event_sha256"],
            )
        )
    parts.extend(_hash_ledger_parts(ledger))
    return _sha(STATE_DOMAIN, *parts)


def ledger_sha256(ledger_value: Any) -> Digest:
    return _sha(LEDGER_DOMAIN, *_hash_ledger_parts(ledger_value))


def recover(encoded: bytes, expected_header_sha256: Digest) -> Record:
    if type(encoded) is not bytes or len(encoded) < HEADER_BYTES:
        raise ActionOutboxError("outbox header is incomplete")
    header = decode_header(encoded[:HEADER_BYTES], expected_header_sha256)
    records: list[Record] = []
    states: list[Record] = []
    ledger = empty_ledger()
    final_chain = header["header_sha256"]
    offset = HEADER_BYTES
    status = RECOVERY_CLEAN
    while offset < len(encoded):
        remaining = len(encoded) - offset
        if remaining < RECORD_BODY_BYTES:
            status = RECOVERY_SHORT_BODY_TAIL
            break
        if remaining == RECORD_BODY_BYTES:
            status = RECOVERY_BODY_WITHOUT_FOOTER
            break
        if remaining < RECORD_BYTES:
            status = RECOVERY_PARTIAL_FOOTER_TAIL
            break
        if len(records) >= header["maximum_records"]:
            raise ActionOutboxError("record capacity exceeded")
        record = decode_record(
            header,
            len(records) + 1,
            final_chain,
            encoded[offset : offset + RECORD_BYTES],
        )
        states, ledger = apply_record(header, record, states, ledger)
        records.append(record)
        final_chain = record["record_sha256"]
        offset += RECORD_BYTES
    ledger = finalize_ledger(states, ledger)
    return {
        "header": header,
        "records": records,
        "states": states,
        "status": status,
        "committed_bytes": offset,
        "discarded_tail_bytes": len(encoded) - offset,
        "final_chain_sha256": final_chain,
        "state_sha256": state_sha256(header, states, ledger),
        "ledger": ledger,
    }


def closed_anchor_sha256(value: Mapping[str, Any]) -> Digest:
    return _sha(
        CLOSED_ANCHOR_DOMAIN,
        _le_u64(value["abi_version"]),
        _digest(value["header_sha256"], "anchor header"),
        _le_u64(value["committed_bytes"]),
        _le_u64(value["committed_records"]),
        _digest(value["final_chain_sha256"], "anchor final chain"),
        _digest(value["state_sha256"], "anchor state"),
        _digest(value["ledger_sha256"], "anchor ledger"),
    )


def make_closed_anchor(recovery_value: Any) -> Record:
    recovery = recovery_value
    ledger = validate_ledger(recovery["ledger"])
    if (
        recovery["status"] != RECOVERY_CLEAN
        or recovery["discarded_tail_bytes"] != 0
        or ledger["ready_actions"] != 0
        or ledger["uncertain_actions"] != 0
    ):
        raise ActionOutboxError("open or torn journal cannot be closed")
    result: Record = {
        "abi_version": CLOSED_ANCHOR_ABI,
        "header_sha256": recovery["header"]["header_sha256"],
        "committed_bytes": recovery["committed_bytes"],
        "committed_records": ledger["committed_records"],
        "final_chain_sha256": recovery["final_chain_sha256"],
        "state_sha256": recovery["state_sha256"],
        "ledger_sha256": ledger_sha256(ledger),
        "anchor_sha256": ZERO_DIGEST,
    }
    result["anchor_sha256"] = closed_anchor_sha256(result)
    return validate_closed_anchor(result)


def validate_closed_anchor(value: Any) -> Record:
    result = _strict_record(value, CLOSED_ANCHOR_FIELDS, "closed anchor")
    _u64(result["abi_version"], "anchor ABI")
    _u64(result["committed_bytes"], "anchor committed bytes")
    _u64(result["committed_records"], "anchor committed records")
    for name in (
        "header_sha256",
        "final_chain_sha256",
        "state_sha256",
        "ledger_sha256",
        "anchor_sha256",
    ):
        _digest(result[name], f"anchor {name}")
    if result["abi_version"] != CLOSED_ANCHOR_ABI or not hmac.compare_digest(
        result["anchor_sha256"], closed_anchor_sha256(result)
    ):
        raise ActionOutboxError("invalid closed anchor")
    return deepcopy(result)


def verify_closed(recovery_value: Any, expected_value: Any) -> None:
    expected = validate_closed_anchor(expected_value)
    if make_closed_anchor(recovery_value) != expected:
        raise ActionOutboxError("closed anchor mismatch")


def _reference_tool_action(
    ordinal: int,
    idempotency_label: str,
    delta: int,
    before: int,
) -> Record:
    descriptor = tool.make_descriptor(
        3,
        _label("tool namespace"),
        _label("arguments schema"),
        _label("result schema"),
        _label("implementation"),
    )
    arguments = tool.make_arguments(88, delta)
    proposal = tool.make_proposal(
        41,
        ordinal,
        _label("agent request"),
        descriptor,
        arguments,
        _label(idempotency_label),
    )
    policy = tool.make_policy(
        5,
        41,
        True,
        16,
        -100,
        100,
        descriptor,
        _label("policy challenge"),
    )
    authorization = tool.authorize_bounded_add(
        proposal,
        descriptor,
        arguments,
        policy,
        before,
    )
    return {
        "descriptor": descriptor,
        "arguments": arguments,
        "proposal": proposal,
        "policy": policy,
        "authorization": authorization,
    }


def _append_reference(
    header: Record,
    records: list[Record],
    states: list[Record],
    ledger: Record,
    encoded_parts: list[bytes],
    record: Record,
) -> tuple[list[Record], Record]:
    states, ledger = apply_record(header, record, states, ledger)
    records.append(record)
    encoded_parts.append(encode_record(header, record))
    return states, ledger


@lru_cache(maxsize=1)
def _reference_campaign_cached() -> Record:
    header = make_header(
        7,
        9,
        41,
        4,
        32,
        4096,
        _label("adapter"),
        _label("payload store"),
        _label("outbox challenge"),
    )
    primary_input = _reference_tool_action(1, "primary key", 3, 0)
    primary = make_action_identity(
        header,
        PURPOSE_PRIMARY,
        ZERO_DIGEST,
        primary_input["descriptor"],
        primary_input["arguments"],
        primary_input["proposal"],
        primary_input["policy"],
        primary_input["authorization"],
        _label("service event"),
        _label("primary payload"),
        32,
        _label("payload bytes"),
    )
    compensation_input = _reference_tool_action(2, "compensation key", -3, 3)
    compensation = make_action_identity(
        header,
        PURPOSE_COMPENSATION,
        primary["action_sha256"],
        compensation_input["descriptor"],
        compensation_input["arguments"],
        compensation_input["proposal"],
        compensation_input["policy"],
        compensation_input["authorization"],
        _label("service event"),
        _label("compensation payload"),
        32,
        _label("payload bytes"),
    )
    records: list[Record] = []
    states: list[Record] = []
    ledger = empty_ledger()
    encoded_parts = [encode_header(header)]

    def enqueue(identity: Record) -> None:
        nonlocal states, ledger
        previous = (
            header["header_sha256"] if not records else records[-1]["record_sha256"]
        )
        record = make_enqueued_record(header, len(records) + 1, previous, identity)
        states, ledger = _append_reference(
            header, records, states, ledger, encoded_parts, record
        )

    def transition(
        action_root: Digest,
        kind: int,
        generation: int,
        observation: Digest,
        output: Digest,
    ) -> None:
        nonlocal states, ledger
        index = _find_state(states, action_root)
        if index is None:
            raise ActionOutboxError("reference transition action is missing")
        record = make_transition_record(
            header,
            len(records) + 1,
            records[-1]["record_sha256"],
            states[index],
            kind,
            generation,
            observation,
            output,
        )
        states, ledger = _append_reference(
            header, records, states, ledger, encoded_parts, record
        )

    enqueue(primary)
    transition(
        primary["action_sha256"], EVENT_DISPATCH_INTENT, 1, ZERO_DIGEST, ZERO_DIGEST
    )
    transition(
        primary["action_sha256"],
        EVENT_AMBIGUITY_OBSERVED,
        1,
        _label("timeout observation"),
        ZERO_DIGEST,
    )
    transition(
        primary["action_sha256"],
        EVENT_RECONCILED_NOT_APPLIED,
        1,
        _label("not applied evidence"),
        ZERO_DIGEST,
    )
    transition(
        primary["action_sha256"], EVENT_DISPATCH_INTENT, 2, ZERO_DIGEST, ZERO_DIGEST
    )
    transition(
        primary["action_sha256"],
        EVENT_ACKNOWLEDGED_SUCCESS,
        2,
        _label("success acknowledgement"),
        _label("primary result"),
    )
    enqueue(compensation)
    transition(
        compensation["action_sha256"],
        EVENT_DISPATCH_INTENT,
        1,
        ZERO_DIGEST,
        ZERO_DIGEST,
    )
    transition(
        compensation["action_sha256"],
        EVENT_AMBIGUITY_OBSERVED,
        1,
        _label("compensation timeout"),
        ZERO_DIGEST,
    )
    transition(
        compensation["action_sha256"],
        EVENT_RECONCILED_SUCCESS,
        1,
        _label("compensation status"),
        _label("compensation result"),
    )
    encoded = b"".join(encoded_parts)
    recovered = recover(encoded, header["header_sha256"])
    anchor = make_closed_anchor(recovered)
    return {
        "header": header,
        "primary_parts": primary_input,
        "primary": primary,
        "compensation_parts": compensation_input,
        "compensation": compensation,
        "records": records,
        "encoded": encoded,
        "recovered": recovered,
        "anchor": anchor,
    }


def reference_campaign() -> Record:
    return deepcopy(_reference_campaign_cached())


def record_section_sha256(records_value: Sequence[Any]) -> Digest:
    encoded = b"".join(
        encode_record(_reference_campaign_cached()["header"], value)
        for value in records_value
    )
    return hashlib.sha256(encoded).digest()


def campaign_sha256(campaign: Mapping[str, Any]) -> Digest:
    return _sha(
        CAMPAIGN_DOMAIN,
        campaign["header"]["header_sha256"],
        campaign["primary"]["action_sha256"],
        campaign["compensation"]["action_sha256"],
        record_section_sha256(campaign["records"]),
    )


def recovery_case_sha256(cut: int, recovered: Mapping[str, Any]) -> Digest:
    return _sha(
        RECOVERY_CASE_DOMAIN,
        _le_u64(cut),
        _le_u8(recovered["status"]),
        _le_u64(recovered["committed_bytes"]),
        _le_u64(recovered["discarded_tail_bytes"]),
        _le_u64(recovered["ledger"]["committed_records"]),
        recovered["final_chain_sha256"],
        recovered["state_sha256"],
        ledger_sha256(recovered["ledger"]),
    )


def recovery_matrix_sha256(campaign: Mapping[str, Any]) -> Digest:
    encoded = campaign["encoded"]
    header_root = campaign["header"]["header_sha256"]
    roots = (
        recovery_case_sha256(cut, recover(encoded[:cut], header_root))
        for cut in range(HEADER_BYTES, len(encoded) + 1)
    )
    return _sha(
        RECOVERY_MATRIX_DOMAIN,
        _le_u64(HEADER_BYTES),
        _le_u64(len(encoded)),
        *roots,
    )


def retained_torn_case(campaign: Mapping[str, Any]) -> Record:
    # The fourth record is authoritative not-applied reconciliation.  Its body
    # without a footer must not clear the uncertainty created by record two.
    prefix = HEADER_BYTES + 3 * RECORD_BYTES
    torn = campaign["encoded"][: prefix + RECORD_BODY_BYTES]
    recovered = recover(torn, campaign["header"]["header_sha256"])
    repaired = torn[: recovered["committed_bytes"]] + campaign["encoded"][prefix:]
    repaired_recovery = recover(repaired, campaign["header"]["header_sha256"])
    if (
        recovered["status"] != RECOVERY_BODY_WITHOUT_FOOTER
        or recovered["discarded_tail_bytes"] != RECORD_BODY_BYTES
        or recovered["ledger"]["uncertain_actions"] != 1
        or repaired != campaign["encoded"]
        or repaired_recovery["final_chain_sha256"]
        != campaign["recovered"]["final_chain_sha256"]
        or repaired_recovery["state_sha256"] != campaign["recovered"]["state_sha256"]
    ):
        raise ActionOutboxError("retained torn-tail recovery changed")
    root = _sha(
        TORN_CASE_DOMAIN,
        _le_u64(len(torn)),
        _le_u8(recovered["status"]),
        _le_u64(recovered["committed_bytes"]),
        _le_u64(recovered["discarded_tail_bytes"]),
        recovered["final_chain_sha256"],
        recovered["state_sha256"],
        ledger_sha256(recovered["ledger"]),
        repaired_recovery["final_chain_sha256"],
        repaired_recovery["state_sha256"],
    )
    return {"encoded": torn, "recovered": recovered, "sha256": root}


def semantic_report_sha256(value: Mapping[str, Any]) -> Digest:
    if tuple(value) != REPORT_FIELDS:
        raise ActionOutboxError("report has noncanonical fields")
    if value["schema"] != REPORT_SCHEMA:
        raise ActionOutboxError("report schema changed")
    expected_abis = {
        "report_abi": REPORT_ABI,
        "header_abi": HEADER_ABI,
        "identity_abi": IDENTITY_ABI,
        "record_abi": RECORD_ABI,
        "closed_anchor_abi": CLOSED_ANCHOR_ABI,
    }
    for name, expected in expected_abis.items():
        if _hex_u64(value[name], f"report {name}") != expected:
            raise ActionOutboxError(f"report {name} changed")
    numeric_names = (
        "header_bytes",
        "record_body_bytes",
        "commit_footer_bytes",
        "record_bytes",
        "record_count",
        "action_count",
        "journal_bytes",
    )
    root_names = (
        "header_sha256",
        "primary_proposal_sha256",
        "primary_authorization_sha256",
        "primary_action_sha256",
        "compensation_proposal_sha256",
        "compensation_authorization_sha256",
        "compensation_action_sha256",
        "record_section_sha256",
        "final_chain_sha256",
        "final_state_sha256",
        "ledger_sha256",
        "closed_anchor_sha256",
        "recovery_matrix_sha256",
        "torn_case_sha256",
    )
    parts: list[bytes] = [
        _le_u64(REPORT_ABI),
        *(_le_u64(value[name]) for name in numeric_names),
        *(_hex_digest(value[name], f"report {name}") for name in root_names),
    ]
    if (
        value["recovery_cut_count"]
        != value["journal_bytes"] - value["header_bytes"] + 1
    ):
        raise ActionOutboxError("report recovery cut count changed")
    events = value["event_kinds"]
    if not isinstance(events, list) or len(events) != 10:
        raise ActionOutboxError("report event kinds are not a list")
    for name in events:
        if type(name) is not str or name not in EVENT_VALUES:
            raise ActionOutboxError("report has unknown event kind")
        parts.append(_le_u8(EVENT_VALUES[name]))
    attempts = value["attempt_generations"]
    if not isinstance(attempts, list) or len(attempts) != 10:
        raise ActionOutboxError("report attempt generations are not a list")
    parts.extend(_le_u64(value_) for value_ in attempts)
    ledger = _strict_record(value["ledger"], LEDGER_FIELDS, "report ledger")
    parts.extend(_le_u64(ledger[name]) for name in LEDGER_FIELDS)
    return _sha(REPORT_DOMAIN, *parts)


@lru_cache(maxsize=1)
def _build_report_cached() -> Record:
    campaign = _reference_campaign_cached()
    recovered = campaign["recovered"]
    ledger = recovered["ledger"]
    anchor = campaign["anchor"]
    section_root = record_section_sha256(campaign["records"])
    matrix_root = recovery_matrix_sha256(campaign)
    torn = retained_torn_case(campaign)
    report: Record = {
        "schema": REPORT_SCHEMA,
        "report_abi": f"{REPORT_ABI:016x}",
        "header_abi": f"{HEADER_ABI:016x}",
        "identity_abi": f"{IDENTITY_ABI:016x}",
        "record_abi": f"{RECORD_ABI:016x}",
        "closed_anchor_abi": f"{CLOSED_ANCHOR_ABI:016x}",
        "header_bytes": HEADER_BYTES,
        "record_body_bytes": RECORD_BODY_BYTES,
        "commit_footer_bytes": COMMIT_FOOTER_BYTES,
        "record_bytes": RECORD_BYTES,
        "journal_bytes": len(campaign["encoded"]),
        "record_count": len(campaign["records"]),
        "action_count": len(recovered["states"]),
        "recovery_cut_count": len(campaign["encoded"]) - HEADER_BYTES + 1,
        "header_sha256": campaign["header"]["header_sha256"].hex(),
        "primary_proposal_sha256": campaign["primary_parts"]["proposal"][
            "proposal_sha256"
        ].hex(),
        "primary_authorization_sha256": campaign["primary_parts"]["authorization"][
            "authorization_sha256"
        ].hex(),
        "primary_action_sha256": campaign["primary"]["action_sha256"].hex(),
        "compensation_proposal_sha256": campaign["compensation_parts"]["proposal"][
            "proposal_sha256"
        ].hex(),
        "compensation_authorization_sha256": campaign["compensation_parts"][
            "authorization"
        ]["authorization_sha256"].hex(),
        "compensation_action_sha256": campaign["compensation"]["action_sha256"].hex(),
        "record_section_sha256": section_root.hex(),
        "final_chain_sha256": recovered["final_chain_sha256"].hex(),
        "final_state_sha256": recovered["state_sha256"].hex(),
        "ledger_sha256": ledger_sha256(ledger).hex(),
        "closed_anchor_sha256": anchor["anchor_sha256"].hex(),
        "recovery_matrix_sha256": matrix_root.hex(),
        "torn_case_sha256": torn["sha256"].hex(),
        "report_sha256": "",
        "event_kinds": [EVENT_NAMES[record["kind"]] for record in campaign["records"]],
        "attempt_generations": [
            record["attempt_generation"] for record in campaign["records"]
        ],
        "ledger": {name: ledger[name] for name in LEDGER_FIELDS},
    }
    report["report_sha256"] = semantic_report_sha256(report).hex()
    if tuple(report) != REPORT_FIELDS:
        raise ActionOutboxError("report field order changed")
    for name, expected in REFERENCE_ROOTS.items():
        if report[name] != expected:
            raise ActionOutboxError(f"retained {name} changed")
    if (
        REFERENCE_RECORD_ROOTS
        and tuple(record["record_sha256"].hex() for record in campaign["records"])
        != REFERENCE_RECORD_ROOTS
    ):
        raise ActionOutboxError("retained record roots changed")
    return report


def build_report() -> Record:
    return deepcopy(_build_report_cached())


def render_report(value: Mapping[str, Any] | None = None) -> str:
    report = build_report() if value is None else value
    try:
        return (
            json.dumps(
                report,
                ensure_ascii=True,
                allow_nan=False,
                separators=(",", ":"),
            )
            + "\n"
        )
    except (TypeError, ValueError) as error:
        raise ActionOutboxError("report is not canonical JSON data") from error


def validate_report(value: Any) -> Record:
    expected = build_report()
    if (
        not isinstance(value, dict)
        or tuple(value) != REPORT_FIELDS
        or value != expected
        or render_report(value) != render_report(expected)
        or value["report_sha256"] != semantic_report_sha256(value).hex()
    ):
        raise ActionOutboxError("report contradicts independent outbox replay")
    return deepcopy(expected)


def load_json_exact(encoded: bytes, where: str) -> Record:
    if (
        type(encoded) is not bytes
        or not 0 < len(encoded) <= MAXIMUM_JSON_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise ActionOutboxError(f"{where} is not one canonical JSON line")

    def object_pairs(pairs: list[tuple[str, Any]]) -> Record:
        result: Record = {}
        for key, value in pairs:
            if key in result:
                raise ActionOutboxError(f"{where} contains duplicate fields")
            result[key] = value
        return result

    def reject_number(_: str) -> None:
        raise ActionOutboxError(f"{where} contains a non-integer number")

    try:
        decoded = json.loads(
            encoded.decode("ascii"),
            object_pairs_hook=object_pairs,
            parse_constant=reject_number,
            parse_float=reject_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActionOutboxError(f"{where} is invalid JSON") from error
    if (
        not isinstance(decoded, dict)
        or render_report(decoded).encode("ascii") != encoded
    ):
        raise ActionOutboxError(f"{where} is not canonical JSON")
    return decoded


def verify_runner(runner: Path | Sequence[str], fixture: Path) -> None:
    command = [str(runner)] if isinstance(runner, Path) else list(runner)
    if not command or not all(isinstance(value, str) and value for value in command):
        raise ActionOutboxError("invalid runner command")
    expected = build_report()
    expected_bytes = render_report(expected).encode("ascii")
    fixture_bytes = fixture.read_bytes()
    fixture_value = load_json_exact(fixture_bytes, "fixture")
    if fixture_value != expected or fixture_bytes != expected_bytes:
        raise ActionOutboxError("retained fixture is stale")
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if completed.returncode != 0 or completed.stderr:
        raise ActionOutboxError("ActionOutbox runner failed")
    runner_value = load_json_exact(completed.stdout, "runner output")
    if runner_value != expected or completed.stdout != expected_bytes:
        raise ActionOutboxError("runner contradicts independent Python oracle")


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render or verify retained ActionOutbox conformance",
    )
    parser.add_argument("--runner", type=Path)
    parser.add_argument("--fixture", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if arguments.runner is None and arguments.fixture is None:
            sys.stdout.write(render_report())
        elif arguments.runner is not None and arguments.fixture is not None:
            verify_runner(arguments.runner, arguments.fixture)
        else:
            raise ActionOutboxError("--runner and --fixture must be supplied together")
    except (ActionOutboxError, OSError, subprocess.SubprocessError) as error:
        print(f"action-outbox-conformance: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
