"""Pure R1k-b3 committed-output reconciliation and disclosure policy.

This module accepts values that a caller has already decoded and verified from
the checkpoint and result-sink wires.  It performs no filesystem I/O and does
not grant storage authority.  The oracle reconciles the checkpoint output
prefix with a complete sink acknowledgement ledger, accepting only an aligned
ledger or one that is exactly one visible result ahead.

The retained tokenizer profile maps one token id to one byte.  Arbitrary model
output is not necessarily valid UTF-8, so the reveal document always retains a
lossless byte representation and emits text only after strict UTF-8 decoding.
Rendered documents use an oracle-only schema and explicitly deny authority, so
they cannot be confused with the filesystem inspector's wire-verified report.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import struct


Digest = bytes
ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
MAXIMUM_VISIBLE_TOKENS = 16 * 1024

MILESTONE = "R1k-b3"
SCHEMA = "glacier.prepared-text-committed-output-oracle/v1"
OUTPUT_ENCODING = "utf8-byte-v1"

COMMITTED_OUTPUT_VIEW_ABI = 0x4750_434F_0000_0001
COMMITTED_OUTPUT_TOKEN_DOMAIN = b"glacier-prepared-text-committed-output-token-v1\x00"
COMMITTED_OUTPUT_BYTES_DOMAIN = b"glacier-prepared-text-committed-output-bytes-v1\x00"
COMMITTED_OUTPUT_VIEW_DOMAIN = b"glacier-prepared-text-committed-output-view-v1\x00"

ALIGNED = "aligned"
SINK_ONE_AHEAD = "sink-exactly-one-ahead"
_STATE_CODES = {
    ALIGNED: 1,
    SINK_ONE_AHEAD: 2,
}


class CommittedOutputError(ValueError):
    """The caller-supplied checkpoint/ledger view is not reconcilable."""


class IdentityMismatch(CommittedOutputError):
    """The checkpoint, ledger, or acknowledgement has a foreign identity."""


class SequenceMismatch(CommittedOutputError):
    """The sink sequence is rolled back, gapped, or too far ahead."""


class AcknowledgementMismatch(CommittedOutputError):
    """The acknowledgement sequence, chain, head, or token is inconsistent."""


class OutputTokenError(CommittedOutputError):
    """A committed token cannot be represented by the retained byte profile."""


@dataclass(frozen=True)
class DecodedAcknowledgementV1:
    """Wire-verified acknowledgement facts required by the pure join."""

    request_epoch: int
    transaction_sequence: int
    token_id: int
    application_ordinal: int
    application_count: int
    request_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    predecessor_acknowledgement_sha256: Digest
    predecessor_sink_prefix_sha256: Digest
    result_sink_prefix_sha256: Digest
    acknowledgement_sha256: Digest


@dataclass(frozen=True)
class VerifiedCheckpointOutputV1:
    """Output-prefix facts admitted by the prepared-text progress decoder."""

    generation: int
    terminal: bool
    request_epoch: int
    next_sequence: int
    sink_initial_sequence: int
    output_tokens: tuple[int, ...]
    package_sha256: Digest
    representation_sha256: Digest
    input_archive_sha256: Digest
    tokenizer_domain_sha256: Digest
    tokenizer_behavior_sha256: Digest
    tokenizer_config_sha256: Digest
    local_plan_sha256: Digest
    request_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    head_acknowledgement_sha256: Digest
    result_sink_prefix_sha256: Digest
    checkpoint_selector_sha256: Digest
    checkpoint_set_sha256: Digest
    checkpoint_state_sha256: Digest


@dataclass(frozen=True)
class DecodedSinkLedgerV1:
    """Complete canonical ledger facts admitted by the sink wire decoder."""

    request_epoch: int
    initial_sequence: int
    next_sequence: int
    request_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    selector_sha256: Digest
    ledger_sha256: Digest
    acknowledgements: tuple[DecodedAcknowledgementV1, ...]
    last_acknowledgement_sha256: Digest
    result_sink_prefix_sha256: Digest


@dataclass(frozen=True)
class CommittedOutputViewR1kB3:
    """Exact reconciled view; rendering decides whether payload is disclosed."""

    sequence_state: str
    terminal: bool
    checkpoint_pending: bool
    generation: int
    request_epoch: int
    checkpoint_next_sequence: int
    sink_initial_sequence: int
    visible_next_sequence: int
    acknowledgement_count: int
    package_sha256: Digest
    representation_sha256: Digest
    input_archive_sha256: Digest
    tokenizer_domain_sha256: Digest
    tokenizer_behavior_sha256: Digest
    tokenizer_config_sha256: Digest
    local_plan_sha256: Digest
    request_sha256: Digest
    checkpoint_selector_sha256: Digest
    checkpoint_set_sha256: Digest
    checkpoint_state_sha256: Digest
    sink_selector_sha256: Digest
    sink_ledger_sha256: Digest
    sink_implementation_sha256: Digest
    sink_instance_sha256: Digest
    head_acknowledgement_sha256: Digest
    result_sink_prefix_sha256: Digest
    visible_tokens: tuple[int, ...]
    visible_bytes: bytes
    visible_tokens_sha256: Digest
    visible_bytes_sha256: Digest
    view_sha256: Digest
    utf8_valid: bool
    utf8_text: str | None


def _u64(value: object, where: str) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise CommittedOutputError(f"{where} is outside u64")
    return value


def _digest(
    value: object,
    where: str,
    *,
    allow_zero: bool,
) -> Digest:
    if type(value) is not bytes or len(value) != 32:
        raise CommittedOutputError(f"{where} is not a 32-byte digest")
    if not allow_zero and value == ZERO_DIGEST:
        raise CommittedOutputError(f"{where} is zero")
    return value


def _head_pair(
    acknowledgement_sha256: object,
    sink_prefix_sha256: object,
    where: str,
) -> tuple[Digest, Digest]:
    acknowledgement = _digest(
        acknowledgement_sha256,
        f"{where} acknowledgement",
        allow_zero=True,
    )
    prefix = _digest(
        sink_prefix_sha256,
        f"{where} sink prefix",
        allow_zero=True,
    )
    if (acknowledgement == ZERO_DIGEST) != (prefix == ZERO_DIGEST):
        raise AcknowledgementMismatch(f"{where} head is only partially zero")
    return acknowledgement, prefix


def _byte_token(value: object, where: str) -> int:
    if type(value) is not int or not 0 <= value <= 0xFF:
        raise OutputTokenError(f"{where} is outside the byte-token range")
    return value


def _checkpoint_tokens(
    checkpoint: VerifiedCheckpointOutputV1,
) -> tuple[int, ...]:
    if type(checkpoint.output_tokens) is not tuple:
        raise CommittedOutputError("checkpoint output tokens are not a tuple")
    if not checkpoint.output_tokens:
        raise CommittedOutputError("checkpoint output is empty")
    if len(checkpoint.output_tokens) > MAXIMUM_VISIBLE_TOKENS:
        raise CommittedOutputError("checkpoint output exceeds the retained limit")
    return tuple(
        _byte_token(token, f"checkpoint token {index}")
        for index, token in enumerate(checkpoint.output_tokens)
    )


def _validate_identity(
    checkpoint: VerifiedCheckpointOutputV1,
    ledger: DecodedSinkLedgerV1,
) -> tuple[int, int, Digest, Digest, Digest]:
    request_epoch = _u64(checkpoint.request_epoch, "checkpoint request epoch")
    if request_epoch == 0:
        raise CommittedOutputError("checkpoint request epoch is zero")
    checkpoint_initial = _u64(
        checkpoint.sink_initial_sequence,
        "checkpoint sink initial sequence",
    )
    ledger_initial = _u64(ledger.initial_sequence, "ledger initial sequence")
    if ledger_initial != checkpoint_initial:
        raise IdentityMismatch("ledger sink initial sequence is foreign")
    for name, value in (
        ("checkpoint package", checkpoint.package_sha256),
        ("checkpoint representation", checkpoint.representation_sha256),
        ("checkpoint input archive", checkpoint.input_archive_sha256),
        ("checkpoint tokenizer domain", checkpoint.tokenizer_domain_sha256),
        ("checkpoint tokenizer behavior", checkpoint.tokenizer_behavior_sha256),
        ("checkpoint tokenizer config", checkpoint.tokenizer_config_sha256),
        ("checkpoint local plan", checkpoint.local_plan_sha256),
        ("checkpoint selector", checkpoint.checkpoint_selector_sha256),
        ("checkpoint set", checkpoint.checkpoint_set_sha256),
        ("checkpoint state", checkpoint.checkpoint_state_sha256),
        ("ledger selector", ledger.selector_sha256),
        ("ledger root", ledger.ledger_sha256),
    ):
        _digest(value, name, allow_zero=False)
    request = _digest(
        checkpoint.request_sha256,
        "checkpoint request",
        allow_zero=False,
    )
    implementation = _digest(
        checkpoint.sink_implementation_sha256,
        "checkpoint sink implementation",
        allow_zero=False,
    )
    instance = _digest(
        checkpoint.sink_instance_sha256,
        "checkpoint sink instance",
        allow_zero=False,
    )

    ledger_epoch = _u64(ledger.request_epoch, "ledger request epoch")
    ledger_request = _digest(
        ledger.request_sha256,
        "ledger request",
        allow_zero=False,
    )
    ledger_implementation = _digest(
        ledger.sink_implementation_sha256,
        "ledger sink implementation",
        allow_zero=False,
    )
    ledger_instance = _digest(
        ledger.sink_instance_sha256,
        "ledger sink instance",
        allow_zero=False,
    )
    if ledger_epoch != request_epoch:
        raise IdentityMismatch("ledger request epoch is foreign")
    if ledger_request != request:
        raise IdentityMismatch("ledger request root is foreign")
    if ledger_implementation != implementation:
        raise IdentityMismatch("ledger sink implementation is foreign")
    if ledger_instance != instance:
        raise IdentityMismatch("ledger sink instance is foreign")
    return request_epoch, checkpoint_initial, request, implementation, instance


def _validate_acknowledgements(
    ledger: DecodedSinkLedgerV1,
    *,
    request_epoch: int,
    request_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
) -> tuple[DecodedAcknowledgementV1, ...]:
    if type(ledger.acknowledgements) is not tuple:
        raise CommittedOutputError("ledger acknowledgements are not a tuple")

    initial = _u64(ledger.initial_sequence, "ledger initial sequence")
    next_sequence = _u64(ledger.next_sequence, "ledger next sequence")
    if next_sequence < initial:
        raise SequenceMismatch("ledger next sequence precedes its initial sequence")
    expected_count = next_sequence - initial
    if expected_count != len(ledger.acknowledgements):
        raise SequenceMismatch("ledger acknowledgement count leaves a sequence gap")
    if expected_count > MAXIMUM_VISIBLE_TOKENS:
        raise CommittedOutputError("ledger exceeds the retained acknowledgement limit")

    previous_acknowledgement = ZERO_DIGEST
    previous_prefix = ZERO_DIGEST
    validated: list[DecodedAcknowledgementV1] = []
    for index, acknowledgement in enumerate(ledger.acknowledgements):
        sequence = initial + index
        if (
            _u64(
                acknowledgement.request_epoch,
                f"acknowledgement {index} request epoch",
            )
            != request_epoch
        ):
            raise IdentityMismatch(f"acknowledgement {index} request epoch is foreign")
        if (
            _u64(
                acknowledgement.transaction_sequence,
                f"acknowledgement {index} transaction sequence",
            )
            != sequence
        ):
            raise SequenceMismatch(
                f"acknowledgement {index} leaves a transaction sequence gap"
            )
        if (
            _u64(
                acknowledgement.application_ordinal,
                f"acknowledgement {index} application ordinal",
            )
            != index + 1
        ):
            raise AcknowledgementMismatch(
                f"acknowledgement {index} has a foreign application ordinal"
            )
        if (
            _u64(
                acknowledgement.application_count,
                f"acknowledgement {index} application count",
            )
            != 1
        ):
            raise AcknowledgementMismatch(
                f"acknowledgement {index} is not a single application"
            )
        _byte_token(
            acknowledgement.token_id,
            f"acknowledgement {index} token",
        )

        if (
            _digest(
                acknowledgement.request_sha256,
                f"acknowledgement {index} request",
                allow_zero=False,
            )
            != request_sha256
        ):
            raise IdentityMismatch(f"acknowledgement {index} request root is foreign")
        if (
            _digest(
                acknowledgement.sink_implementation_sha256,
                f"acknowledgement {index} sink implementation",
                allow_zero=False,
            )
            != sink_implementation_sha256
        ):
            raise IdentityMismatch(
                f"acknowledgement {index} sink implementation is foreign"
            )
        if (
            _digest(
                acknowledgement.sink_instance_sha256,
                f"acknowledgement {index} sink instance",
                allow_zero=False,
            )
            != sink_instance_sha256
        ):
            raise IdentityMismatch(f"acknowledgement {index} sink instance is foreign")

        predecessor_acknowledgement = _digest(
            acknowledgement.predecessor_acknowledgement_sha256,
            f"acknowledgement {index} predecessor acknowledgement",
            allow_zero=True,
        )
        predecessor_prefix = _digest(
            acknowledgement.predecessor_sink_prefix_sha256,
            f"acknowledgement {index} predecessor sink prefix",
            allow_zero=True,
        )
        if predecessor_acknowledgement != previous_acknowledgement:
            raise AcknowledgementMismatch(
                f"acknowledgement {index} predecessor acknowledgement mismatches"
            )
        if predecessor_prefix != previous_prefix:
            raise AcknowledgementMismatch(
                f"acknowledgement {index} predecessor sink prefix mismatches"
            )

        previous_acknowledgement = _digest(
            acknowledgement.acknowledgement_sha256,
            f"acknowledgement {index} root",
            allow_zero=False,
        )
        previous_prefix = _digest(
            acknowledgement.result_sink_prefix_sha256,
            f"acknowledgement {index} sink prefix",
            allow_zero=False,
        )
        validated.append(acknowledgement)

    ledger_acknowledgement, ledger_prefix = _head_pair(
        ledger.last_acknowledgement_sha256,
        ledger.result_sink_prefix_sha256,
        "ledger",
    )
    if ledger_acknowledgement != previous_acknowledgement:
        raise AcknowledgementMismatch(
            "ledger acknowledgement head mismatches its chain"
        )
    if ledger_prefix != previous_prefix:
        raise AcknowledgementMismatch("ledger sink-prefix head mismatches its chain")
    return tuple(validated)


def _strict_utf8(value: bytes) -> tuple[bool, str | None]:
    try:
        return True, value.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return False, None


def escape_visible_bytes_v1(value: bytes) -> str:
    """Return a deterministic, ASCII-only and lossless byte display."""

    if type(value) is not bytes:
        raise CommittedOutputError("visible bytes are not immutable bytes")
    escaped: list[str] = []
    for byte in value:
        if byte == 0x5C:
            escaped.append(r"\\")
        elif 0x20 <= byte <= 0x7E:
            escaped.append(chr(byte))
        else:
            escaped.append(f"\\x{byte:02x}")
    return "".join(escaped)


def _token_root_v1(visible_tokens: tuple[int, ...]) -> Digest:
    canonical_u32_le = b"".join(struct.pack("<I", token) for token in visible_tokens)
    return hashlib.sha256(
        COMMITTED_OUTPUT_TOKEN_DOMAIN
        + struct.pack("<Q", len(visible_tokens))
        + canonical_u32_le
    ).digest()


def _bytes_root_v1(visible_bytes: bytes) -> Digest:
    return hashlib.sha256(
        COMMITTED_OUTPUT_BYTES_DOMAIN
        + struct.pack("<Q", len(visible_bytes))
        + visible_bytes
    ).digest()


def _view_root_v1(
    *,
    sequence_state: str,
    terminal: bool,
    generation: int,
    request_epoch: int,
    sink_initial_sequence: int,
    checkpoint_next_sequence: int,
    visible_next_sequence: int,
    acknowledgement_count: int,
    visible_token_count: int,
    package_sha256: Digest,
    representation_sha256: Digest,
    input_archive_sha256: Digest,
    tokenizer_domain_sha256: Digest,
    tokenizer_behavior_sha256: Digest,
    tokenizer_config_sha256: Digest,
    local_plan_sha256: Digest,
    request_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    checkpoint_set_sha256: Digest,
    checkpoint_state_sha256: Digest,
    sink_selector_sha256: Digest,
    sink_ledger_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    head_acknowledgement_sha256: Digest,
    result_sink_prefix_sha256: Digest,
    visible_tokens_sha256: Digest,
    visible_bytes_sha256: Digest,
) -> Digest:
    """Hash the exact Zig `ViewRootInputV1` preimage.

    After the domain, the order is ten little-endian u64 values: ABI, sequence
    state, terminal, generation, request epoch, sink initial, checkpoint next,
    visible next, acknowledgement count, and visible-token count. The digest
    order is package, representation, input archive, tokenizer domain,
    tokenizer behavior, tokenizer config, local plan, request, checkpoint
    selector, checkpoint set, checkpoint state, sink selector, sink ledger,
    sink implementation, sink instance, head acknowledgement, result-sink
    prefix, visible tokens, and visible bytes.
    """

    state_code = _STATE_CODES.get(sequence_state)
    if state_code is None:
        raise CommittedOutputError("unknown committed-output sequence state")
    body = (
        struct.pack(
            "<QQQQQQQQQQ",
            COMMITTED_OUTPUT_VIEW_ABI,
            state_code,
            int(terminal),
            generation,
            request_epoch,
            sink_initial_sequence,
            checkpoint_next_sequence,
            visible_next_sequence,
            acknowledgement_count,
            visible_token_count,
        )
        + package_sha256
        + representation_sha256
        + input_archive_sha256
        + tokenizer_domain_sha256
        + tokenizer_behavior_sha256
        + tokenizer_config_sha256
        + local_plan_sha256
        + request_sha256
        + checkpoint_selector_sha256
        + checkpoint_set_sha256
        + checkpoint_state_sha256
        + sink_selector_sha256
        + sink_ledger_sha256
        + sink_implementation_sha256
        + sink_instance_sha256
        + head_acknowledgement_sha256
        + result_sink_prefix_sha256
        + visible_tokens_sha256
        + visible_bytes_sha256
    )
    return hashlib.sha256(COMMITTED_OUTPUT_VIEW_DOMAIN + body).digest()


def reconcile_committed_output_v1(
    checkpoint: VerifiedCheckpointOutputV1,
    ledger: DecodedSinkLedgerV1,
) -> CommittedOutputViewR1kB3:
    """Reconcile one verified output prefix with an aligned/one-ahead ledger."""

    if type(checkpoint.terminal) is not bool:
        raise CommittedOutputError("checkpoint terminal flag is not boolean")
    generation = _u64(checkpoint.generation, "checkpoint generation")
    if generation < 2:
        raise CommittedOutputError("checkpoint generation precedes committed output")
    checkpoint_tokens = _checkpoint_tokens(checkpoint)
    checkpoint_next = _u64(
        checkpoint.next_sequence,
        "checkpoint next sequence",
    )
    if checkpoint_next == 0:
        raise CommittedOutputError("checkpoint next sequence is zero")
    if checkpoint_next != len(checkpoint_tokens):
        raise SequenceMismatch("checkpoint output leaves a sequence gap")
    checkpoint_acknowledgement, checkpoint_prefix = _head_pair(
        checkpoint.head_acknowledgement_sha256,
        checkpoint.result_sink_prefix_sha256,
        "checkpoint",
    )

    (
        request_epoch,
        sink_initial,
        request,
        implementation,
        instance,
    ) = _validate_identity(checkpoint, ledger)
    if sink_initial > checkpoint_next:
        raise SequenceMismatch("checkpoint sink initial sequence leaves a visible gap")
    acknowledgements = _validate_acknowledgements(
        ledger,
        request_epoch=request_epoch,
        request_sha256=request,
        sink_implementation_sha256=implementation,
        sink_instance_sha256=instance,
    )
    sink_next = _u64(ledger.next_sequence, "ledger next sequence")

    if sink_next < checkpoint_next:
        raise SequenceMismatch("sink sequence rolled back behind the checkpoint")
    if sink_next > checkpoint_next + 1:
        raise SequenceMismatch("sink is more than one sequence ahead")
    if sink_initial > checkpoint_next:
        raise SequenceMismatch("sink initial sequence leaves a visible gap")
    if checkpoint.terminal and sink_next != checkpoint_next:
        raise SequenceMismatch("terminal checkpoint is not sink aligned")
    if checkpoint.terminal and not acknowledgements:
        raise AcknowledgementMismatch("terminal checkpoint has no acknowledged output")

    for index, acknowledgement in enumerate(acknowledgements):
        sequence = sink_initial + index
        if sequence < checkpoint_next:
            checkpoint_token = checkpoint_tokens[sequence]
            if acknowledgement.token_id != checkpoint_token:
                raise AcknowledgementMismatch(
                    f"acknowledgement {index} token differs from checkpoint output"
                )

    if sink_next == checkpoint_next:
        sequence_state = ALIGNED
        if ledger.last_acknowledgement_sha256 != checkpoint_acknowledgement:
            raise AcknowledgementMismatch(
                "aligned checkpoint acknowledgement head mismatches the ledger"
            )
        if ledger.result_sink_prefix_sha256 != checkpoint_prefix:
            raise AcknowledgementMismatch(
                "aligned checkpoint sink-prefix head mismatches the ledger"
            )
        visible_tokens = checkpoint_tokens
    else:
        sequence_state = SINK_ONE_AHEAD
        if not acknowledgements:
            raise SequenceMismatch("one-ahead sink has no visible acknowledgement")
        one_ahead = acknowledgements[-1]
        if one_ahead.transaction_sequence != checkpoint_next:
            raise SequenceMismatch("one-ahead sink leaves a visible sequence gap")
        if one_ahead.predecessor_acknowledgement_sha256 != checkpoint_acknowledgement:
            raise AcknowledgementMismatch(
                "one-ahead acknowledgement does not extend the checkpoint head"
            )
        if one_ahead.predecessor_sink_prefix_sha256 != checkpoint_prefix:
            raise AcknowledgementMismatch(
                "one-ahead acknowledgement does not extend the checkpoint prefix"
            )
        visible_tokens = checkpoint_tokens + (one_ahead.token_id,)

    if len(visible_tokens) > MAXIMUM_VISIBLE_TOKENS:
        raise CommittedOutputError("visible output exceeds the retained limit")
    visible_bytes = bytes(visible_tokens)
    visible_tokens_sha256 = _token_root_v1(visible_tokens)
    visible_bytes_sha256 = _bytes_root_v1(visible_bytes)
    utf8_valid, utf8_text = _strict_utf8(visible_bytes)
    view_sha256 = _view_root_v1(
        sequence_state=sequence_state,
        terminal=checkpoint.terminal,
        generation=generation,
        request_epoch=request_epoch,
        sink_initial_sequence=sink_initial,
        checkpoint_next_sequence=checkpoint_next,
        visible_next_sequence=sink_next,
        acknowledgement_count=len(acknowledgements),
        visible_token_count=len(visible_tokens),
        package_sha256=checkpoint.package_sha256,
        representation_sha256=checkpoint.representation_sha256,
        input_archive_sha256=checkpoint.input_archive_sha256,
        tokenizer_domain_sha256=checkpoint.tokenizer_domain_sha256,
        tokenizer_behavior_sha256=checkpoint.tokenizer_behavior_sha256,
        tokenizer_config_sha256=checkpoint.tokenizer_config_sha256,
        local_plan_sha256=checkpoint.local_plan_sha256,
        request_sha256=request,
        checkpoint_selector_sha256=checkpoint.checkpoint_selector_sha256,
        checkpoint_set_sha256=checkpoint.checkpoint_set_sha256,
        checkpoint_state_sha256=checkpoint.checkpoint_state_sha256,
        sink_selector_sha256=ledger.selector_sha256,
        sink_ledger_sha256=ledger.ledger_sha256,
        sink_implementation_sha256=implementation,
        sink_instance_sha256=instance,
        head_acknowledgement_sha256=ledger.last_acknowledgement_sha256,
        result_sink_prefix_sha256=ledger.result_sink_prefix_sha256,
        visible_tokens_sha256=visible_tokens_sha256,
        visible_bytes_sha256=visible_bytes_sha256,
    )
    return CommittedOutputViewR1kB3(
        sequence_state=sequence_state,
        terminal=checkpoint.terminal,
        checkpoint_pending=sequence_state == SINK_ONE_AHEAD,
        generation=generation,
        request_epoch=request_epoch,
        checkpoint_next_sequence=checkpoint_next,
        sink_initial_sequence=sink_initial,
        visible_next_sequence=sink_next,
        acknowledgement_count=len(acknowledgements),
        package_sha256=checkpoint.package_sha256,
        representation_sha256=checkpoint.representation_sha256,
        input_archive_sha256=checkpoint.input_archive_sha256,
        tokenizer_domain_sha256=checkpoint.tokenizer_domain_sha256,
        tokenizer_behavior_sha256=checkpoint.tokenizer_behavior_sha256,
        tokenizer_config_sha256=checkpoint.tokenizer_config_sha256,
        local_plan_sha256=checkpoint.local_plan_sha256,
        request_sha256=request,
        checkpoint_selector_sha256=checkpoint.checkpoint_selector_sha256,
        checkpoint_set_sha256=checkpoint.checkpoint_set_sha256,
        checkpoint_state_sha256=checkpoint.checkpoint_state_sha256,
        sink_selector_sha256=ledger.selector_sha256,
        sink_ledger_sha256=ledger.ledger_sha256,
        sink_implementation_sha256=implementation,
        sink_instance_sha256=instance,
        head_acknowledgement_sha256=ledger.last_acknowledgement_sha256,
        result_sink_prefix_sha256=ledger.result_sink_prefix_sha256,
        visible_tokens=visible_tokens,
        visible_bytes=visible_bytes,
        visible_tokens_sha256=visible_tokens_sha256,
        visible_bytes_sha256=visible_bytes_sha256,
        view_sha256=view_sha256,
        utf8_valid=utf8_valid,
        utf8_text=utf8_text,
    )


def committed_output_document_v1(
    view: CommittedOutputViewR1kB3,
    *,
    reveal_output: bool = False,
) -> dict[str, object]:
    """Render deterministic metadata, disclosing payload only by explicit opt-in."""

    if type(reveal_output) is not bool:
        raise CommittedOutputError("reveal_output is not boolean")
    document: dict[str, object] = {
        "schema": SCHEMA,
        "milestone": MILESTONE,
        "input_scope": "caller-verified-checkpoint-and-decoded-ledger",
        "wire_bytes_verified": False,
        "read_only": True,
        "authority": False,
        "output_disclosed": reveal_output,
        "output_encoding": OUTPUT_ENCODING,
        "sequence_state": view.sequence_state,
        "terminal": view.terminal,
        "checkpoint_pending": view.checkpoint_pending,
        "checkpoint_generation": view.generation,
        "checkpoint_next_sequence": view.checkpoint_next_sequence,
        "sink_initial_sequence": view.sink_initial_sequence,
        "visible_next_sequence": view.visible_next_sequence,
        "output_token_count": len(view.visible_tokens),
        "acknowledgement_count": view.acknowledgement_count,
        "request_epoch": view.request_epoch,
        "package_sha256": view.package_sha256.hex(),
        "representation_sha256": view.representation_sha256.hex(),
        "input_archive_sha256": view.input_archive_sha256.hex(),
        "tokenizer_domain_sha256": view.tokenizer_domain_sha256.hex(),
        "tokenizer_behavior_sha256": view.tokenizer_behavior_sha256.hex(),
        "tokenizer_config_sha256": view.tokenizer_config_sha256.hex(),
        "local_plan_sha256": view.local_plan_sha256.hex(),
        "request_sha256": view.request_sha256.hex(),
        "checkpoint_selector_sha256": (view.checkpoint_selector_sha256.hex()),
        "checkpoint_set_sha256": view.checkpoint_set_sha256.hex(),
        "checkpoint_state_sha256": view.checkpoint_state_sha256.hex(),
        "sink_selector_sha256": view.sink_selector_sha256.hex(),
        "sink_ledger_sha256": view.sink_ledger_sha256.hex(),
        "sink_implementation_sha256": view.sink_implementation_sha256.hex(),
        "sink_instance_sha256": view.sink_instance_sha256.hex(),
        "head_acknowledgement_sha256": (view.head_acknowledgement_sha256.hex()),
        "result_sink_prefix_sha256": view.result_sink_prefix_sha256.hex(),
        "visible_tokens_sha256": view.visible_tokens_sha256.hex(),
        "visible_bytes_sha256": view.visible_bytes_sha256.hex(),
        "view_sha256": view.view_sha256.hex(),
        "output_utf8_valid": view.utf8_valid,
    }
    if reveal_output:
        document["output"] = {
            "token_ids": list(view.visible_tokens),
            "bytes_hex": view.visible_bytes.hex(),
            "escaped_bytes": escape_visible_bytes_v1(view.visible_bytes),
            "utf8_text": view.utf8_text,
        }
    return document


def inspect_committed_output_v1(
    checkpoint: VerifiedCheckpointOutputV1,
    ledger: DecodedSinkLedgerV1,
    *,
    reveal_output: bool = False,
) -> dict[str, object]:
    """Convenience wrapper for reconciliation followed by policy rendering."""

    return committed_output_document_v1(
        reconcile_committed_output_v1(checkpoint, ledger),
        reveal_output=reveal_output,
    )


def encode_committed_output_document_v1(
    view: CommittedOutputViewR1kB3,
    *,
    reveal_output: bool = False,
) -> bytes:
    """Encode one stable, newline-terminated UTF-8 JSON document."""

    document = committed_output_document_v1(
        view,
        reveal_output=reveal_output,
    )
    return (
        json.dumps(
            document,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
