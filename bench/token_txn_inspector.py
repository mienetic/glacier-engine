#!/usr/bin/env python3
"""Read-only, metadata-first inspection of strict-B4 TokenTxn evidence.

The evidence is admitted only after replay against a separately supplied,
canonical expectation manifest.  That manifest carries the independently
trusted roots and complete 4 x 64 output matrix required by
``decode_token_txn_evidence``.  Reports omit token IDs unless the caller
explicitly requests disclosure.
"""

# ruff: noqa: E402

from __future__ import annotations

import sys

# The documented direct-script entry point must remain filesystem read-only
# even when the caller did not set PYTHONDONTWRITEBYTECODE. Library imports
# must not change the embedding process's global bytecode policy.
if __name__ == "__main__":
    sys.dont_write_bytecode = True

import hashlib
import json
import os
import stat
from typing import Any, Sequence

if __package__:
    from . import lane4_token_txn_event_evidence as evidence
else:
    import lane4_token_txn_event_evidence as evidence


EXPECTATION_SCHEMA = "glacier.decode-lane4/token-txn-replay-expectation-v1"
REPORT_SCHEMA = "glacier.decode-lane4/token-txn-inspector-v1"

# A canonical expectation is currently below 4 KiB.  Keep a separate fixed
# ceiling so future evidence growth cannot silently turn this small trust input
# into an unbounded parser surface.
MAX_EXPECTATION_BYTES = 4 * 1024
MAX_REPORT_BYTES = 16 * 1024

LANE_OUTPUT_HASH_DOMAIN = b"glacier-token-txn-inspector-lane-output-v1\x00"

EXPECTATION_FIELDS = (
    "schema",
    "root_binding_sha256",
    "request_epoch",
    "resource_receipt_sha256",
    "head_sha256",
    "lane_outputs",
)

REPORT_FIELDS = (
    "schema",
    "replay_verified",
    "read_only",
    "authority_granted",
    "token_ids_disclosed",
    "evidence_bytes",
    "record_count",
    "lane_count",
    "transaction_count",
    "prepare_count",
    "commit_count",
    "abort_count",
    "lane_transition_count",
    "kv_transition_count",
    "first_sequence",
    "last_sequence",
    "commit_timestamps_available",
    "request_epoch",
    "abis",
    "roots",
    "resource_claim",
    "lane_output_sha256",
)
REVEALED_REPORT_FIELDS = REPORT_FIELDS + ("token_ids",)

ABI_FIELDS = (
    "observation",
    "decode_lane4",
    "journal",
    "token_txn",
    "token_txn_sink",
    "token_txn_prepare_ack",
    "token_txn_commit_receipt",
    "resource_bank",
)
ROOT_FIELDS = (
    "root_binding_sha256",
    "resource_receipt_sha256",
    "initial_sha256",
    "head_sha256",
    "evidence_sha256",
    "canonical_jsonl_sha256",
    "expectation_manifest_sha256",
)
RESOURCE_CLAIM_FIELDS = (
    "bank_epoch",
    "slot_index",
    "generation",
    *evidence.RESOURCE_CLAIM_FIELDS,
)

USAGE = (
    "usage: token-txn-inspector --evidence FILE --expectation FILE "
    "[--reveal-token-ids]\n"
)
ERROR_LINE = "token-txn-inspector: inspection failed\n"


class TokenTxnInspectorError(ValueError):
    """The trust manifest, input file, or rendered report is not canonical."""


def _canonical_json_line(document: dict[str, Any]) -> bytes:
    try:
        return (
            json.dumps(
                document,
                ensure_ascii=True,
                separators=(",", ":"),
            ).encode("ascii")
            + b"\n"
        )
    except (RecursionError, TypeError, UnicodeError, ValueError) as error:
        raise TokenTxnInspectorError("document is not canonical ASCII JSON") from error


def _expectation_document(
    expectation: evidence.ReplayExpectation,
) -> dict[str, Any]:
    if not isinstance(expectation, evidence.ReplayExpectation):
        raise TokenTxnInspectorError("expectation must be a ReplayExpectation")
    try:
        root_binding = evidence.require_sha256(
            expectation.root_binding_sha256,
            "expectation.root_binding_sha256",
        )
        resource_receipt = evidence.require_sha256(
            expectation.resource_receipt_sha256,
            "expectation.resource_receipt_sha256",
        )
        head = evidence.require_sha256(
            expectation.head_sha256,
            "expectation.head_sha256",
        )
        request_epoch = evidence.u64_hex(expectation.request_epoch)
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("invalid expectation identity") from error
    if (
        root_binding == "0" * 64
        or resource_receipt == "0" * 64
        or head == "0" * 64
        or expectation.request_epoch == 0
        or expectation.request_epoch ^ evidence.SINK_EPOCH_XOR == 0
    ):
        raise TokenTxnInspectorError("invalid expectation identity")
    if (
        type(expectation.lane_outputs) is not tuple
        or len(expectation.lane_outputs) != evidence.LANE_COUNT
    ):
        raise TokenTxnInspectorError("invalid expectation lane shape")

    lane_outputs: list[list[str]] = []
    for lane in expectation.lane_outputs:
        if type(lane) is not tuple or len(lane) != evidence.TRANSACTION_COUNT:
            raise TokenTxnInspectorError("invalid expectation lane shape")
        try:
            lane_outputs.append([evidence.u32_hex(token_id) for token_id in lane])
        except evidence.TokenTxnEvidenceError as error:
            raise TokenTxnInspectorError("invalid expectation token ID") from error

    document: dict[str, Any] = {
        "schema": EXPECTATION_SCHEMA,
        "root_binding_sha256": root_binding,
        "request_epoch": request_epoch,
        "resource_receipt_sha256": resource_receipt,
        "head_sha256": head,
        "lane_outputs": lane_outputs,
    }
    if tuple(document) != EXPECTATION_FIELDS:
        raise AssertionError("expectation field order drift")
    return document


def render_expectation_manifest(
    expectation: evidence.ReplayExpectation,
) -> bytes:
    """Render one exact ordered ASCII expectation manifest."""

    encoded = _canonical_json_line(_expectation_document(expectation))
    if len(encoded) > MAX_EXPECTATION_BYTES:
        raise TokenTxnInspectorError("expectation exceeds its fixed bound")
    return encoded


def parse_expectation_manifest(
    encoded: bytes,
) -> evidence.ReplayExpectation:
    """Parse one exact ordered ASCII manifest into the replay trust type."""

    if (
        type(encoded) is not bytes
        or not encoded
        or len(encoded) > MAX_EXPECTATION_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise TokenTxnInspectorError("invalid expectation framing")
    try:
        document = json.loads(encoded.decode("ascii"))
    except (
        json.JSONDecodeError,
        RecursionError,
        UnicodeDecodeError,
    ) as error:
        raise TokenTxnInspectorError("invalid expectation JSON") from error
    if type(document) is not dict or tuple(document) != EXPECTATION_FIELDS:
        raise TokenTxnInspectorError("invalid expectation fields")
    if document["schema"] != EXPECTATION_SCHEMA:
        raise TokenTxnInspectorError("invalid expectation schema")

    try:
        root_binding = evidence.require_sha256(
            document["root_binding_sha256"],
            "expectation.root_binding_sha256",
        )
        request_epoch = evidence.require_u64_hex(
            document["request_epoch"],
            "expectation.request_epoch",
        )
        resource_receipt = evidence.require_sha256(
            document["resource_receipt_sha256"],
            "expectation.resource_receipt_sha256",
        )
        head = evidence.require_sha256(
            document["head_sha256"],
            "expectation.head_sha256",
        )
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("invalid expectation identity") from error

    raw_outputs = document["lane_outputs"]
    if type(raw_outputs) is not list or len(raw_outputs) != evidence.LANE_COUNT:
        raise TokenTxnInspectorError("invalid expectation lane shape")
    lane_outputs: list[tuple[int, ...]] = []
    for lane_index, lane in enumerate(raw_outputs):
        if type(lane) is not list or len(lane) != evidence.TRANSACTION_COUNT:
            raise TokenTxnInspectorError("invalid expectation lane shape")
        try:
            lane_outputs.append(
                tuple(
                    evidence.require_u32_hex(
                        token_id,
                        (f"expectation.lane_outputs[{lane_index}][{sequence}]"),
                    )
                    for sequence, token_id in enumerate(lane)
                )
            )
        except evidence.TokenTxnEvidenceError as error:
            raise TokenTxnInspectorError("invalid expectation token ID") from error

    expectation = evidence.ReplayExpectation(
        root_binding_sha256=root_binding,
        request_epoch=request_epoch,
        resource_receipt_sha256=resource_receipt,
        head_sha256=head,
        lane_outputs=tuple(lane_outputs),
    )
    canonical = render_expectation_manifest(expectation)
    if encoded != canonical:
        raise TokenTxnInspectorError("expectation is not canonical")
    return expectation


def _lane_output_sha256(
    root_binding_sha256: str,
    request_epoch: int,
    lane_index: int,
    token_ids: tuple[int, ...],
) -> str:
    digest = hashlib.sha256()
    digest.update(LANE_OUTPUT_HASH_DOMAIN)
    digest.update(bytes.fromhex(root_binding_sha256))
    digest.update(request_epoch.to_bytes(8, "little"))
    digest.update(lane_index.to_bytes(4, "little"))
    digest.update(len(token_ids).to_bytes(4, "little"))
    for token_id in token_ids:
        digest.update(token_id.to_bytes(4, "little"))
    return digest.hexdigest()


def _report_document(
    evidence_bytes: bytes,
    expectation_bytes: bytes,
    validated: evidence.ValidatedTokenTxnEvidence,
    *,
    reveal_token_ids: bool,
) -> dict[str, Any]:
    if type(reveal_token_ids) is not bool:
        raise TokenTxnInspectorError("reveal_token_ids must be boolean")
    journal = validated.journal_receipt
    resource = journal.resource_receipt
    claim = resource.claim

    abis = {
        "observation": evidence.u64_hex(evidence.OBSERVATION_ABI),
        "decode_lane4": evidence.u64_hex(evidence.DECODE_LANE4_ABI),
        "journal": evidence.u64_hex(journal.abi_version),
        "token_txn": evidence.u64_hex(journal.token_txn_abi),
        "token_txn_sink": evidence.u64_hex(journal.token_txn_sink_abi),
        "token_txn_prepare_ack": evidence.u64_hex(journal.token_txn_prepare_ack_abi),
        "token_txn_commit_receipt": evidence.u64_hex(
            journal.token_txn_commit_receipt_abi
        ),
        "resource_bank": evidence.u64_hex(journal.resource_bank_abi),
    }
    if tuple(abis) != ABI_FIELDS:
        raise AssertionError("report ABI field order drift")

    roots = {
        "root_binding_sha256": journal.root_binding_sha256,
        "resource_receipt_sha256": (
            evidence.derive_resource_receipt_sha256(
                {
                    "bank_epoch": evidence.u64_hex(resource.bank_epoch),
                    "slot_index": evidence.u32_hex(resource.slot_index),
                    "generation": evidence.u64_hex(resource.generation),
                    "owner_key": evidence.u64_hex(resource.owner_key),
                    "claim": {
                        field: evidence.u64_hex(getattr(claim, field))
                        for field in evidence.RESOURCE_CLAIM_FIELDS
                    },
                    "integrity": evidence.u64_hex(resource.integrity),
                }
            )
        ),
        "initial_sha256": journal.initial_sha256,
        "head_sha256": journal.head_sha256,
        "evidence_sha256": hashlib.sha256(evidence_bytes).hexdigest(),
        "canonical_jsonl_sha256": (
            evidence.derive_canonical_jsonl_sha256(evidence_bytes)
        ),
        "expectation_manifest_sha256": hashlib.sha256(expectation_bytes).hexdigest(),
    }
    if tuple(roots) != ROOT_FIELDS:
        raise AssertionError("report root field order drift")

    resource_claim = {
        "bank_epoch": evidence.u64_hex(resource.bank_epoch),
        "slot_index": evidence.u32_hex(resource.slot_index),
        "generation": evidence.u64_hex(resource.generation),
        **{
            field: evidence.u64_hex(getattr(claim, field))
            for field in evidence.RESOURCE_CLAIM_FIELDS
        },
    }
    if tuple(resource_claim) != RESOURCE_CLAIM_FIELDS:
        raise AssertionError("report resource field order drift")

    document: dict[str, Any] = {
        "schema": REPORT_SCHEMA,
        "replay_verified": True,
        "read_only": True,
        "authority_granted": False,
        "token_ids_disclosed": reveal_token_ids,
        "evidence_bytes": len(evidence_bytes),
        "record_count": evidence.RECORD_COUNT,
        "lane_count": evidence.LANE_COUNT,
        "transaction_count": evidence.TRANSACTION_COUNT,
        "prepare_count": journal.prepare_count,
        "commit_count": journal.commit_count,
        "abort_count": journal.abort_count,
        "lane_transition_count": journal.lane_transition_count,
        "kv_transition_count": journal.kv_transition_count,
        "first_sequence": journal.first_sequence,
        "last_sequence": journal.last_sequence,
        "commit_timestamps_available": journal.commit_timestamps_available,
        "request_epoch": evidence.u64_hex(journal.request_epoch),
        "abis": abis,
        "roots": roots,
        "resource_claim": resource_claim,
        "lane_output_sha256": [
            _lane_output_sha256(
                journal.root_binding_sha256,
                journal.request_epoch,
                lane_index,
                token_ids,
            )
            for lane_index, token_ids in enumerate(validated.lane_outputs)
        ],
    }
    if reveal_token_ids:
        document["token_ids"] = [
            [evidence.u32_hex(token_id) for token_id in lane]
            for lane in validated.lane_outputs
        ]
    expected_fields = REVEALED_REPORT_FIELDS if reveal_token_ids else REPORT_FIELDS
    if tuple(document) != expected_fields:
        raise AssertionError("report field order drift")
    return document


def inspect_token_txn_evidence(
    evidence_bytes: bytes,
    expectation_bytes: bytes,
    *,
    reveal_token_ids: bool = False,
) -> dict[str, Any]:
    """Replay bounded evidence and return its deterministic report document."""

    if type(reveal_token_ids) is not bool:
        raise TokenTxnInspectorError("reveal_token_ids must be boolean")
    expectation = parse_expectation_manifest(expectation_bytes)
    try:
        validated = evidence.decode_token_txn_evidence(
            evidence_bytes,
            expectation,
        )
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("token transaction replay failed") from error
    return _report_document(
        evidence_bytes,
        expectation_bytes,
        validated,
        reveal_token_ids=reveal_token_ids,
    )


def render_report(
    evidence_bytes: bytes,
    expectation_bytes: bytes,
    *,
    reveal_token_ids: bool = False,
) -> bytes:
    """Replay and render exactly one compact ASCII JSON line."""

    encoded = _canonical_json_line(
        inspect_token_txn_evidence(
            evidence_bytes,
            expectation_bytes,
            reveal_token_ids=reveal_token_ids,
        )
    )
    if len(encoded) > MAX_REPORT_BYTES:
        raise TokenTxnInspectorError("report exceeds its fixed bound")
    return encoded


def parse_rendered_report(
    encoded: bytes,
    evidence_bytes: bytes,
    expectation_bytes: bytes,
) -> dict[str, Any]:
    """Verify one report by replaying its inputs and comparing exact bytes."""

    if (
        type(encoded) is not bytes
        or not encoded
        or len(encoded) > MAX_REPORT_BYTES
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise TokenTxnInspectorError("invalid report framing")
    try:
        document = json.loads(encoded.decode("ascii"))
    except (
        json.JSONDecodeError,
        RecursionError,
        UnicodeDecodeError,
    ) as error:
        raise TokenTxnInspectorError("invalid report JSON") from error
    if type(document) is not dict:
        raise TokenTxnInspectorError("invalid report object")
    disclosed = document.get("token_ids_disclosed")
    expected_fields = REVEALED_REPORT_FIELDS if disclosed is True else REPORT_FIELDS
    if tuple(document) != expected_fields:
        raise TokenTxnInspectorError("invalid report fields")
    if (
        document["schema"] != REPORT_SCHEMA
        or document["replay_verified"] is not True
        or document["read_only"] is not True
        or document["authority_granted"] is not False
        or type(disclosed) is not bool
        or document["commit_timestamps_available"] is not False
    ):
        raise TokenTxnInspectorError("invalid report claim boundary")

    fixed_scalars = {
        "record_count": evidence.RECORD_COUNT,
        "lane_count": evidence.LANE_COUNT,
        "transaction_count": evidence.TRANSACTION_COUNT,
        "prepare_count": evidence.TRANSACTION_COUNT,
        "commit_count": evidence.TRANSACTION_COUNT,
        "abort_count": 0,
        "lane_transition_count": evidence.LANE_TRANSITION_COUNT,
        "kv_transition_count": evidence.KV_TRANSITION_COUNT,
        "first_sequence": 0,
        "last_sequence": evidence.TRANSACTION_COUNT - 1,
    }
    if (
        type(document["evidence_bytes"]) is not int
        or not 0 < document["evidence_bytes"] <= evidence.MAX_EVIDENCE_BYTES
    ):
        raise TokenTxnInspectorError("invalid report evidence length")
    for field, expected in fixed_scalars.items():
        if type(document[field]) is not int or document[field] != expected:
            raise TokenTxnInspectorError("invalid report scalar")
    try:
        request_epoch = evidence.require_u64_hex(
            document["request_epoch"],
            "report.request_epoch",
        )
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("invalid report epoch") from error
    if request_epoch == 0 or request_epoch ^ evidence.SINK_EPOCH_XOR == 0:
        raise TokenTxnInspectorError("invalid report epoch")

    abis = document["abis"]
    expected_abis = (
        evidence.OBSERVATION_ABI,
        evidence.DECODE_LANE4_ABI,
        evidence.B4_TOKEN_TXN_JOURNAL_ABI,
        evidence.TOKEN_TXN_ABI,
        evidence.TOKEN_TXN_SINK_ABI,
        evidence.TOKEN_TXN_PREPARE_ACK_ABI,
        evidence.TOKEN_TXN_COMMIT_RECEIPT_ABI,
        evidence.RESOURCE_BANK_ABI,
    )
    if type(abis) is not dict or tuple(abis) != ABI_FIELDS:
        raise TokenTxnInspectorError("invalid report ABIs")
    for value, expected in zip(abis.values(), expected_abis):
        if value != evidence.u64_hex(expected):
            raise TokenTxnInspectorError("invalid report ABI")

    roots = document["roots"]
    if type(roots) is not dict or tuple(roots) != ROOT_FIELDS:
        raise TokenTxnInspectorError("invalid report roots")
    try:
        for field, value in roots.items():
            evidence.require_sha256(value, f"report.roots.{field}")
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("invalid report root") from error
    if any(
        roots[field] == "0" * 64
        for field in (
            "root_binding_sha256",
            "resource_receipt_sha256",
            "head_sha256",
        )
    ):
        raise TokenTxnInspectorError("invalid report root")
    if roots["initial_sha256"] != evidence.derive_initial_sha256(
        roots["root_binding_sha256"],
        request_epoch,
    ):
        raise TokenTxnInspectorError("inconsistent report initial root")

    resource_claim = document["resource_claim"]
    if (
        type(resource_claim) is not dict
        or tuple(resource_claim) != RESOURCE_CLAIM_FIELDS
    ):
        raise TokenTxnInspectorError("invalid report resource claim")
    try:
        bank_epoch = evidence.require_u64_hex(
            resource_claim["bank_epoch"],
            "report.resource_claim.bank_epoch",
        )
        slot_index = evidence.require_u32_hex(
            resource_claim["slot_index"],
            "report.resource_claim.slot_index",
        )
        resource_values: dict[str, int] = {}
        for field in RESOURCE_CLAIM_FIELDS[2:]:
            resource_values[field] = evidence.require_u64_hex(
                resource_claim[field],
                f"report.resource_claim.{field}",
            )
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("invalid report resource claim") from error
    if (
        bank_epoch == 0
        or slot_index != 0
        or resource_values["generation"] == 0
        or resource_values["queue_slots"] != evidence.LANE_COUNT
        or not any(
            resource_values[field] != 0 for field in evidence.RESOURCE_BYTE_CLAIM_FIELDS
        )
    ):
        raise TokenTxnInspectorError("invalid report resource claim")

    lane_roots = document["lane_output_sha256"]
    if type(lane_roots) is not list or len(lane_roots) != evidence.LANE_COUNT:
        raise TokenTxnInspectorError("invalid report lane roots")
    try:
        for lane_index, root in enumerate(lane_roots):
            evidence.require_sha256(
                root,
                f"report.lane_output_sha256[{lane_index}]",
            )
    except evidence.TokenTxnEvidenceError as error:
        raise TokenTxnInspectorError("invalid report lane root") from error

    if disclosed:
        token_ids = document["token_ids"]
        if type(token_ids) is not list or len(token_ids) != evidence.LANE_COUNT:
            raise TokenTxnInspectorError("invalid revealed token shape")
        decoded_token_ids: list[tuple[int, ...]] = []
        try:
            for lane_index, lane in enumerate(token_ids):
                if type(lane) is not list or len(lane) != evidence.TRANSACTION_COUNT:
                    raise TokenTxnInspectorError("invalid revealed token shape")
                decoded_token_ids.append(
                    tuple(
                        evidence.require_u32_hex(
                            token_id,
                            (f"report.token_ids[{lane_index}][{sequence}]"),
                        )
                        for sequence, token_id in enumerate(lane)
                    )
                )
        except evidence.TokenTxnEvidenceError as error:
            raise TokenTxnInspectorError("invalid revealed token ID") from error
        root_binding = roots["root_binding_sha256"]
        expected_lane_roots = [
            _lane_output_sha256(
                root_binding,
                request_epoch,
                lane_index,
                token_ids_for_lane,
            )
            for lane_index, token_ids_for_lane in enumerate(decoded_token_ids)
        ]
        if lane_roots != expected_lane_roots:
            raise TokenTxnInspectorError("revealed tokens do not match lane roots")
    elif "token_ids" in document:
        raise TokenTxnInspectorError("hidden report contains token IDs")

    if encoded != _canonical_json_line(document):
        raise TokenTxnInspectorError("report is not canonical")
    expected = render_report(
        evidence_bytes,
        expectation_bytes,
        reveal_token_ids=disclosed,
    )
    if encoded != expected:
        raise TokenTxnInspectorError(
            "report does not match the replayed evidence and expectation"
        )
    return document


def _stat_fingerprint(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_bounded_fd(file_descriptor: int, maximum_bytes: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while total <= maximum_bytes:
        request_bytes = min(64 * 1024, maximum_bytes + 1 - total)
        if request_bytes == 0:
            break
        try:
            chunk = os.read(file_descriptor, request_bytes)
        except InterruptedError:
            continue
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    if total > maximum_bytes:
        raise TokenTxnInspectorError("input exceeds its fixed bound")
    return b"".join(chunks)


def read_stable_regular_file(
    path: str | os.PathLike[str],
    maximum_bytes: int,
) -> bytes:
    """Read one bounded regular file without following a final symbolic link."""

    if (
        type(maximum_bytes) is not int
        or isinstance(maximum_bytes, bool)
        or maximum_bytes <= 0
    ):
        raise TokenTxnInspectorError("invalid file bound")
    try:
        rendered_path = os.fspath(path)
    except TypeError as error:
        raise TokenTxnInspectorError("invalid input path") from error
    if type(rendered_path) is not str or not rendered_path or "\x00" in rendered_path:
        raise TokenTxnInspectorError("invalid input path")

    try:
        path_before = os.lstat(rendered_path)
        if (
            not stat.S_ISREG(path_before.st_mode)
            or path_before.st_size <= 0
            or path_before.st_size > maximum_bytes
        ):
            raise TokenTxnInspectorError("input is not a bounded regular file")

        flags = os.O_RDONLY
        for name in (
            "O_CLOEXEC",
            "O_NOFOLLOW",
            "O_NONBLOCK",
            "O_BINARY",
            "O_NOINHERIT",
        ):
            flags |= getattr(os, name, 0)
        file_descriptor = os.open(rendered_path, flags)
        try:
            descriptor_before = os.fstat(file_descriptor)
            if not stat.S_ISREG(descriptor_before.st_mode) or _stat_fingerprint(
                descriptor_before
            ) != _stat_fingerprint(path_before):
                raise TokenTxnInspectorError("input identity changed before read")
            data = _read_bounded_fd(file_descriptor, maximum_bytes)
            descriptor_after = os.fstat(file_descriptor)
        finally:
            os.close(file_descriptor)
        path_after = os.lstat(rendered_path)
    except TokenTxnInspectorError:
        raise
    except OSError as error:
        raise TokenTxnInspectorError("input is not a stable regular file") from error

    fingerprint = _stat_fingerprint(path_before)
    if (
        fingerprint != _stat_fingerprint(descriptor_after)
        or fingerprint != _stat_fingerprint(path_after)
        or len(data) != descriptor_after.st_size
    ):
        raise TokenTxnInspectorError("input changed during read")
    return data


def _parse_arguments(
    arguments: Sequence[str],
) -> tuple[str, str, bool]:
    if (
        not isinstance(arguments, Sequence)
        or isinstance(arguments, (str, bytes, bytearray))
        or not all(type(argument) is str for argument in arguments)
    ):
        raise TokenTxnInspectorError("invalid arguments")
    evidence_path: str | None = None
    expectation_path: str | None = None
    reveal_token_ids = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--reveal-token-ids":
            if reveal_token_ids:
                raise TokenTxnInspectorError("duplicate arguments")
            reveal_token_ids = True
            index += 1
            continue
        if argument not in ("--evidence", "--expectation"):
            raise TokenTxnInspectorError("invalid arguments")
        if index + 1 >= len(arguments):
            raise TokenTxnInspectorError("missing argument value")
        value = arguments[index + 1]
        if not value or "\x00" in value:
            raise TokenTxnInspectorError("invalid argument value")
        if argument == "--evidence":
            if evidence_path is not None:
                raise TokenTxnInspectorError("duplicate arguments")
            evidence_path = value
        else:
            if expectation_path is not None:
                raise TokenTxnInspectorError("duplicate arguments")
            expectation_path = value
        index += 2
    if evidence_path is None or expectation_path is None:
        raise TokenTxnInspectorError("missing required arguments")
    return evidence_path, expectation_path, reveal_token_ids


def main(arguments: Sequence[str] | None = None) -> int:
    argv = tuple(sys.argv[1:] if arguments is None else arguments)
    if argv in (("--help",), ("-h",)):
        sys.stdout.write(USAGE)
        return 0
    try:
        evidence_path, expectation_path, reveal = _parse_arguments(argv)
        expectation_bytes = read_stable_regular_file(
            expectation_path,
            MAX_EXPECTATION_BYTES,
        )
        evidence_bytes = read_stable_regular_file(
            evidence_path,
            evidence.MAX_EVIDENCE_BYTES,
        )
        rendered = render_report(
            evidence_bytes,
            expectation_bytes,
            reveal_token_ids=reveal,
        )
    except Exception:
        # CLI diagnostics intentionally collapse parser, filesystem, manifest,
        # and replay failures so neither a caller path nor evidence content is
        # reflected to stderr.
        sys.stderr.write(ERROR_LINE)
        return 2
    sys.stdout.buffer.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
