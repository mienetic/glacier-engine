"""Independent process-death campaign for direct one-token terminal recovery.

The Zig worker owns inference and durable publication.  This controller starts
one worker process per action, accepts injected deaths only after a bounded
ready frame, and independently authenticates the selected checkpoint lineage.
The selector-rename case is deliberately a host-process-death claim; this
campaign does not claim power-loss durability.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import struct
import sys
from typing import Mapping, Sequence, cast

from bench import prepared_text_package as prepared_package
from bench import prepared_text_recovery_campaign as recovery


CampaignError = recovery.CampaignError

DIRECT_RESULT_SCHEMA = "glacier.prepared-text-direct-terminal-recovery/result-v1"
CAMPAIGN_SCHEMA = "glacier.prepared-text-direct-terminal-recovery/campaign-v1"
DIRECT_CRASH_POINTS = (
    "direct_after_step",
    "direct_after_retire",
    "direct_checkpoint_selector_rename",
    "direct_after_generation_two",
)
GENERATION_ONE_CRASH_POINTS = frozenset(DIRECT_CRASH_POINTS[:2])
GENERATION_TWO_CRASH_POINTS = frozenset(DIRECT_CRASH_POINTS[2:])

ZERO_DIGEST = bytes(32)
ZERO_DIGEST_HEX = "0" * 64
DEFAULT_TIMEOUT_SECONDS = recovery.DEFAULT_TIMEOUT_SECONDS

SOURCE_LIVE_MARKER = b"glacier-prepared-text-source-live-v1"
SOURCE_LIVE_MARKER_ABI = 0x4750_544C_0000_0001
TERMINAL_CONTRACT_MAGIC = b"GPTTRM01"
TERMINAL_CONTRACT_ABI = 0x4750_5454_0000_0001
TERMINAL_CONTRACT_HEADER_BYTES = 128
TERMINAL_CONTRACT_FIXED_PAYLOAD_BYTES = 472
TERMINAL_CONTRACT_PROMPT_OFFSET = 600
TERMINAL_CONTRACT_FOOTER_BYTES = 32
TERMINAL_CONTRACT_DOMAIN = (
    b"glacier-prepared-text-terminal-source-recovery-contract-v1\x00"
)
PROMPT_DOMAIN = b"glacier-prepared-text-prompt-v1\x00"

PREDECESSOR_ARCHIVE_ABI = 0x4750_5444_0000_0001
OUTPUT_TOKEN_ABI = 0x4750_5444_0000_0002
TERMINAL_SEMANTIC_MAGIC = b"GPTSEM1\x00"
TERMINAL_SEMANTIC_ABI = 0x4750_5453_0000_0001
TERMINAL_SEMANTIC_BYTES = 640
TERMINAL_SEMANTIC_BODY_BYTES = 608
TERMINAL_SEMANTIC_DOMAIN = b"glacier-prepared-text-terminal-semantic-v1\x00"
TERMINAL_OUTPUT_DOMAIN = b"glacier-prepared-text-terminal-output-semantic-v1\x00"
STATE_COMMITMENT_ABI = 0x474C_5053_0000_0001
STATE_COMMITMENT_DOMAIN = b"glacier-lane-publication-state-v1\x00"

DIRECT_VIEW_ABI = 0x4750_4456_0000_0001
DIRECT_VIEW_DOMAIN = b"glacier-prepared-text-direct-terminal-output-view-v1\x00"

CHECKPOINT_LOCK_NAME = ".glacier-checkpoint-lock-v1"
RUNTIME_IMAGE_PUBLICATION_LOCK_NAME = ".glacier-glrt-publication.lock-v1"
RESULT_SINK_FORBIDDEN_NAMES = frozenset(
    {
        ".glacier-prepared-text-result-sink-lock-v1",
        ".glacier-prepared-text-result-sink-active-v1",
    }
)
RESULT_SINK_FORBIDDEN_PREFIXES = (
    "prepared-text-result-ledger-",
    ".prepared-text-result-ledger-",
    ".prepared-text-result-selector-",
)

_GENERIC_RESULT_KEYS = (
    "schema",
    "mode",
    "pid",
    "input_generation",
    "input_sequence",
    "output_generation",
    "output_sequence",
    "sink_disposition",
    "sink_count",
    "sink_next_sequence",
    "sink_ledger_sha256",
    "sink_selector_sha256",
    "checkpoint_selector_sha256",
    "terminal",
    "ownership_zero",
    "verified",
    "output_tokens",
    "terminal_semantic_sha256",
)
_DIRECT_RESULT_KEYS = (
    "schema",
    "mode",
    "pid",
    "disposition",
    "receipt_input_generation",
    "receipt_input_sequence",
    "receipt_output_generation",
    "receipt_output_sequence",
    "receipt_output_token",
    "receipt_checkpoint_sha256",
    "receipt_checkpoint_selector_sha256",
    "receipt_terminal_source_contract_sha256",
    "receipt_terminal_semantic_sha256",
    "ownership_zero",
    "view_abi",
    "terminal",
    "generation",
    "request_epoch",
    "publication_next_sequence",
    "acknowledgement_count",
    "token_count",
    "output_token",
    "package_sha256",
    "representation_sha256",
    "input_archive_sha256",
    "tokenizer_domain_sha256",
    "tokenizer_behavior_sha256",
    "tokenizer_config_sha256",
    "local_plan_sha256",
    "bound_plan_sha256",
    "terminal_source_contract_sha256",
    "terminal_semantic_sha256",
    "terminal_output_sha256",
    "terminal_state_sha256",
    "selected_selector_sha256",
    "selected_set_sha256",
    "predecessor_selector_sha256",
    "predecessor_set_sha256",
    "challenge_sha256",
    "view_sha256",
)
_READY_KEYS = (
    "schema",
    "phase",
    "pid",
    "crash_point",
    "input_generation",
    "input_sequence",
    "sink_count",
    "sink_ledger_sha256",
    "sink_selector_sha256",
    "checkpoint_selector_sha256",
)
_VIEW_DIGEST_FIELDS = (
    "package_sha256",
    "representation_sha256",
    "input_archive_sha256",
    "tokenizer_domain_sha256",
    "tokenizer_behavior_sha256",
    "tokenizer_config_sha256",
    "local_plan_sha256",
    "bound_plan_sha256",
    "terminal_source_contract_sha256",
    "terminal_semantic_sha256",
    "terminal_output_sha256",
    "terminal_state_sha256",
    "selected_selector_sha256",
    "selected_set_sha256",
    "predecessor_selector_sha256",
    "predecessor_set_sha256",
    "challenge_sha256",
)


@dataclass(frozen=True)
class DirectTerminalContractFacts:
    encoded: bytes
    contract_sha256: bytes
    prompt_tokens: tuple[int, ...]
    options: tuple[int, int, int]
    scheduling: tuple[int, int, int, int, int, int]
    bound_request_epoch: int
    token_domain_sha256: bytes
    token_config_sha256: bytes
    artifact_license_sha256: bytes
    previous_plan_sha256: bytes
    source_runtime: tuple[int, int, int]
    request_epoch: int
    publication_next_sequence: int
    challenge_sha256: bytes
    local_plan_sha256: bytes
    bound_plan_sha256: bytes
    prompt_sha256: bytes
    artifact_sha256: bytes
    execution_plan_sha256: bytes
    residency_binding_sha256: bytes


@dataclass(frozen=True)
class DirectInputFacts:
    encoded: bytes
    package_sha256: bytes
    representation_sha256: bytes
    archive_sha256: bytes
    tokenizer_domain_sha256: bytes
    tokenizer_behavior_sha256: bytes
    tokenizer_config_sha256: bytes
    image_container_sha256: bytes


@dataclass(frozen=True)
class DirectSemanticFacts:
    encoded: bytes
    semantic_sha256: bytes
    request_epoch: int
    publication_next_sequence: int
    prompt_tokens: int
    max_new_tokens: int
    kv_position: int
    sampling_calls: int
    output_length: int
    output_bytes: int
    execution_abi: int
    rng_state_abi: int
    local_plan_sha256: bytes
    artifact_sha256: bytes
    token_domain_sha256: bytes
    token_config_sha256: bytes
    image_container_sha256: bytes
    prompt_sha256: bytes
    output_sha256: bytes
    logical_kv_sha256: bytes
    kv_state_sha256: bytes
    rng_state_sha256: bytes
    output_state_sha256: bytes
    state_commitment_sha256: bytes


@dataclass(frozen=True)
class DirectGenerationOneFacts:
    checkpoint: recovery.CheckpointWireFacts
    contract: DirectTerminalContractFacts
    input: DirectInputFacts


@dataclass(frozen=True)
class DirectViewFacts:
    output_token: int
    package_sha256: bytes
    representation_sha256: bytes
    input_archive_sha256: bytes
    tokenizer_domain_sha256: bytes
    tokenizer_behavior_sha256: bytes
    tokenizer_config_sha256: bytes
    local_plan_sha256: bytes
    bound_plan_sha256: bytes
    terminal_source_contract_sha256: bytes
    terminal_semantic_sha256: bytes
    terminal_output_sha256: bytes
    terminal_state_sha256: bytes
    selected_selector_sha256: bytes
    selected_set_sha256: bytes
    predecessor_selector_sha256: bytes
    predecessor_set_sha256: bytes
    challenge_sha256: bytes
    view_sha256: bytes


@dataclass(frozen=True)
class DirectTerminalWireFacts:
    selected: recovery.CheckpointWireFacts
    predecessor_selector: recovery.EmbeddedSelectorFacts
    generation_one: DirectGenerationOneFacts
    semantic: DirectSemanticFacts
    view: DirectViewFacts


def _require(condition: bool, message: str) -> None:
    recovery._require(condition, message)


def _u64(encoded: bytes, offset: int) -> int:
    return recovery._u64(encoded, offset)


def _digest_at(encoded: bytes, offset: int) -> bytes:
    _require(
        0 <= offset and offset + 32 <= len(encoded),
        "truncated digest",
    )
    return encoded[offset : offset + 32]


def _nonzero_digest(value: bytes, label: str) -> bytes:
    _require(
        isinstance(value, bytes) and len(value) == 32 and value != ZERO_DIGEST,
        f"invalid {label}",
    )
    return value


def _mapping(value: object, label: str) -> Mapping[str, object]:
    _require(isinstance(value, Mapping), f"invalid {label}")
    return cast(Mapping[str, object], value)


def _mapping_digest(
    value: Mapping[str, object],
    name: str,
    *,
    allow_zero: bool = False,
) -> bytes:
    digest = value.get(name)
    _require(
        isinstance(digest, bytes)
        and len(digest) == 32
        and (allow_zero or digest != ZERO_DIGEST),
        f"invalid archive {name}",
    )
    return cast(bytes, digest)


def _mapping_int(
    value: Mapping[str, object],
    name: str,
    *,
    minimum: int = 0,
) -> int:
    scalar = value.get(name)
    _require(
        type(scalar) is int and cast(int, scalar) >= minimum,
        f"invalid archive {name}",
    )
    return cast(int, scalar)


def _decode_terminal_contract(
    encoded: bytes,
) -> DirectTerminalContractFacts:
    minimum = TERMINAL_CONTRACT_PROMPT_OFFSET + TERMINAL_CONTRACT_FOOTER_BYTES
    _require(len(encoded) >= minimum + 4, "terminal contract is too small")
    body = encoded[:-TERMINAL_CONTRACT_FOOTER_BYTES]
    contract_sha256 = encoded[-TERMINAL_CONTRACT_FOOTER_BYTES:]
    prompt_count = _u64(encoded, 48)
    prompt_bytes = _u64(encoded, 56)
    _require(
        encoded[:8] == TERMINAL_CONTRACT_MAGIC
        and _u64(encoded, 8) == TERMINAL_CONTRACT_ABI
        and _u64(encoded, 16) == len(encoded)
        and _u64(encoded, 24) == 0
        and _u64(encoded, 32) == TERMINAL_CONTRACT_HEADER_BYTES
        and _u64(encoded, 40) == TERMINAL_CONTRACT_FIXED_PAYLOAD_BYTES
        and prompt_count > 0
        and prompt_bytes == prompt_count * 4
        and len(encoded) == minimum + prompt_bytes
        and encoded[64:128] == bytes(64)
        and contract_sha256 == recovery._hash(TERMINAL_CONTRACT_DOMAIN, body),
        "invalid terminal contract framing or root",
    )
    options = cast(
        tuple[int, int, int],
        struct.unpack_from("<QQQ", encoded, 128),
    )
    scheduling = cast(
        tuple[int, int, int, int, int, int],
        struct.unpack_from("<QQQQQQ", encoded, 152),
    )
    bound_request_epoch = _u64(encoded, 200)
    token_domain_sha256 = _digest_at(encoded, 208)
    token_config_sha256 = _digest_at(encoded, 240)
    artifact_license_sha256 = _digest_at(encoded, 272)
    previous_plan_sha256 = _digest_at(encoded, 304)
    source_runtime = cast(
        tuple[int, int, int],
        struct.unpack_from("<QQQ", encoded, 336),
    )
    request_epoch = _u64(encoded, 360)
    publication_next_sequence = _u64(encoded, 368)
    challenge_sha256 = _digest_at(encoded, 376)
    derived = tuple(
        _digest_at(encoded, offset) for offset in (408, 440, 472, 504, 536, 568)
    )
    prompt_wire = encoded[
        TERMINAL_CONTRACT_PROMPT_OFFSET : len(encoded) - TERMINAL_CONTRACT_FOOTER_BYTES
    ]
    prompt_tokens = cast(
        tuple[int, ...],
        struct.unpack("<" + "I" * prompt_count, prompt_wire),
    )
    expected_prompt_sha256 = recovery._hash(
        PROMPT_DOMAIN,
        struct.pack("<Q", prompt_count) + prompt_wire,
    )
    _require(
        options[0] == 1
        and all(scheduling[index] > 0 for index in range(5))
        and scheduling[4] <= (1 << 16) - 1
        and bound_request_epoch == request_epoch
        and request_epoch > 0
        and publication_next_sequence == 1
        and all(value > 0 for value in source_runtime)
        and token_domain_sha256 != ZERO_DIGEST
        and token_config_sha256 != ZERO_DIGEST
        and artifact_license_sha256 != ZERO_DIGEST
        and challenge_sha256 != ZERO_DIGEST
        and all(value != ZERO_DIGEST for value in derived)
        and derived[2] == expected_prompt_sha256,
        "terminal contract context is not canonical",
    )
    return DirectTerminalContractFacts(
        encoded=encoded,
        contract_sha256=contract_sha256,
        prompt_tokens=prompt_tokens,
        options=options,
        scheduling=scheduling,
        bound_request_epoch=bound_request_epoch,
        token_domain_sha256=token_domain_sha256,
        token_config_sha256=token_config_sha256,
        artifact_license_sha256=artifact_license_sha256,
        previous_plan_sha256=previous_plan_sha256,
        source_runtime=source_runtime,
        request_epoch=request_epoch,
        publication_next_sequence=publication_next_sequence,
        challenge_sha256=challenge_sha256,
        local_plan_sha256=derived[0],
        bound_plan_sha256=derived[1],
        prompt_sha256=derived[2],
        artifact_sha256=derived[3],
        execution_plan_sha256=derived[4],
        residency_binding_sha256=derived[5],
    )


def _decode_direct_input(
    encoded: bytes,
    contract: DirectTerminalContractFacts,
) -> DirectInputFacts:
    try:
        decoded = prepared_package.decode_archive(encoded)
    except prepared_package.PreparedTextPackageError as error:
        raise CampaignError("invalid direct input archive") from error
    binding = _mapping(decoded.get("binding"), "archive binding")
    package = _mapping(decoded.get("package"), "archive package")
    representation = _mapping(
        decoded.get("representation"),
        "archive representation",
    )
    tokenizer = _mapping(
        decoded.get("tokenizer_manifest"),
        "archive tokenizer manifest",
    )
    tokens = decoded.get("tokens")
    raw_text = decoded.get("raw_text")
    _require(
        isinstance(tokens, tuple)
        and tokens == contract.prompt_tokens
        and isinstance(raw_text, bytes)
        and len(raw_text) == len(contract.prompt_tokens)
        and _mapping_int(binding, "request_epoch", minimum=1) == contract.request_epoch
        and _mapping_int(binding, "prompt_tokens", minimum=1)
        == len(contract.prompt_tokens)
        and _mapping_int(binding, "prompt_bytes", minimum=1)
        == len(contract.prompt_tokens)
        and _mapping_digest(binding, "tokenizer_domain_sha256")
        == contract.token_domain_sha256
        and _mapping_digest(binding, "tokenizer_config_sha256")
        == contract.token_config_sha256
        and _mapping_digest(binding, "prepared_prompt_sha256") == contract.prompt_sha256
        and _mapping_digest(binding, "local_plan_sha256") == contract.local_plan_sha256
        and _mapping_digest(binding, "bound_plan_sha256") == contract.bound_plan_sha256
        and _mapping_digest(binding, "artifact_sha256") == contract.artifact_sha256
        and _mapping_digest(binding, "execution_plan_sha256")
        == contract.execution_plan_sha256
        and _mapping_digest(binding, "residency_binding_sha256")
        == contract.residency_binding_sha256
        and _mapping_digest(binding, "artifact_license_sha256")
        == contract.artifact_license_sha256
        and _mapping_digest(package, "license_sha256")
        == contract.artifact_license_sha256,
        "direct input archive does not match terminal contract",
    )
    package_sha256 = _mapping_digest(package, "package_sha256")
    representation_sha256 = _mapping_digest(
        representation,
        "representation_sha256",
    )
    archive_sha256 = _mapping_digest(decoded, "archive_sha256")
    tokenizer_domain_sha256 = _mapping_digest(tokenizer, "domain_sha256")
    tokenizer_behavior_sha256 = _mapping_digest(
        tokenizer,
        "behavior_sha256",
    )
    tokenizer_config_sha256 = _mapping_digest(tokenizer, "config_sha256")
    image_container_sha256 = _mapping_digest(
        representation,
        "container_sha256",
    )
    _require(
        tokenizer_domain_sha256 == contract.token_domain_sha256
        and tokenizer_config_sha256 == contract.token_config_sha256,
        "archive tokenizer does not match terminal contract",
    )
    return DirectInputFacts(
        encoded=encoded,
        package_sha256=package_sha256,
        representation_sha256=representation_sha256,
        archive_sha256=archive_sha256,
        tokenizer_domain_sha256=tokenizer_domain_sha256,
        tokenizer_behavior_sha256=tokenizer_behavior_sha256,
        tokenizer_config_sha256=tokenizer_config_sha256,
        image_container_sha256=image_container_sha256,
    )


def _decode_terminal_semantic(encoded: bytes) -> DirectSemanticFacts:
    _require(
        len(encoded) == TERMINAL_SEMANTIC_BYTES
        and encoded[:8] == TERMINAL_SEMANTIC_MAGIC
        and _u64(encoded, 8) == TERMINAL_SEMANTIC_ABI
        and _u64(encoded, 16) == TERMINAL_SEMANTIC_BYTES
        and _u64(encoded, 24) == 0
        and encoded[496:TERMINAL_SEMANTIC_BODY_BYTES] == bytes(112)
        and encoded[TERMINAL_SEMANTIC_BODY_BYTES:]
        == recovery._hash(
            TERMINAL_SEMANTIC_DOMAIN,
            encoded[:TERMINAL_SEMANTIC_BODY_BYTES],
        ),
        "invalid terminal semantic framing or root",
    )
    scalars = cast(
        tuple[int, int, int, int, int, int, int, int, int, int],
        struct.unpack_from("<QQQQQQQQQQ", encoded, 32),
    )
    digests = tuple(_digest_at(encoded, 112 + index * 32) for index in range(12))
    (
        request_epoch,
        publication_next_sequence,
        prompt_tokens,
        max_new_tokens,
        kv_position,
        sampling_calls,
        output_length,
        output_bytes,
        execution_abi,
        rng_state_abi,
    ) = scalars
    state_commitment = recovery._hash(
        STATE_COMMITMENT_DOMAIN,
        struct.pack(
            "<QQQ",
            STATE_COMMITMENT_ABI,
            execution_abi,
            kv_position,
        )
        + digests[8]
        + struct.pack("<Q", rng_state_abi)
        + digests[9]
        + struct.pack("<QQ", sampling_calls, output_length)
        + digests[10],
    )
    _require(
        request_epoch > 0
        and publication_next_sequence == 1
        and prompt_tokens > 0
        and max_new_tokens == 1
        and kv_position == prompt_tokens
        and sampling_calls == 1
        and output_length == 1
        and output_bytes == 4
        and execution_abi > 0
        and rng_state_abi > 0
        and all(value != ZERO_DIGEST for value in digests)
        and digests[11] == state_commitment,
        "invalid terminal semantic state",
    )
    return DirectSemanticFacts(
        encoded=encoded,
        semantic_sha256=encoded[TERMINAL_SEMANTIC_BODY_BYTES:],
        request_epoch=request_epoch,
        publication_next_sequence=publication_next_sequence,
        prompt_tokens=prompt_tokens,
        max_new_tokens=max_new_tokens,
        kv_position=kv_position,
        sampling_calls=sampling_calls,
        output_length=output_length,
        output_bytes=output_bytes,
        execution_abi=execution_abi,
        rng_state_abi=rng_state_abi,
        local_plan_sha256=digests[0],
        artifact_sha256=digests[1],
        token_domain_sha256=digests[2],
        token_config_sha256=digests[3],
        image_container_sha256=digests[4],
        prompt_sha256=digests[5],
        output_sha256=digests[6],
        logical_kv_sha256=digests[7],
        kv_state_sha256=digests[8],
        rng_state_sha256=digests[9],
        output_state_sha256=digests[10],
        state_commitment_sha256=digests[11],
    )


def _terminal_output_root(
    contract: DirectTerminalContractFacts,
    output_token: int,
) -> bytes:
    _require(0 <= output_token <= (1 << 32) - 1, "output token exceeds u32")
    return recovery._hash(
        TERMINAL_OUTPUT_DOMAIN,
        contract.artifact_sha256
        + contract.token_domain_sha256
        + contract.token_config_sha256
        + struct.pack("<Q", 1)
        + struct.pack("<I", output_token),
    )


def _validate_semantic_context(
    semantic: DirectSemanticFacts,
    contract: DirectTerminalContractFacts,
    input_facts: DirectInputFacts,
    output_token: int,
) -> None:
    _require(
        semantic.request_epoch == contract.request_epoch
        and semantic.publication_next_sequence == contract.publication_next_sequence
        and semantic.prompt_tokens == len(contract.prompt_tokens)
        and semantic.local_plan_sha256 == contract.local_plan_sha256
        and semantic.artifact_sha256 == contract.artifact_sha256
        and semantic.token_domain_sha256 == contract.token_domain_sha256
        and semantic.token_config_sha256 == contract.token_config_sha256
        and semantic.image_container_sha256 == input_facts.image_container_sha256
        and semantic.prompt_sha256 == contract.prompt_sha256
        and semantic.output_sha256 == _terminal_output_root(contract, output_token),
        "terminal semantic does not match direct lineage",
    )


def _decode_generation_one(
    checkpoint: recovery.CheckpointWireFacts,
) -> DirectGenerationOneFacts:
    expected_shape = (
        (7, 0, SOURCE_LIVE_MARKER_ABI),
        (7, 1, TERMINAL_CONTRACT_ABI),
        (7, 2, prepared_package.ARCHIVE_ABI),
    )
    actual_shape = tuple(
        (value.kind, value.ordinal, value.abi_version) for value in checkpoint.objects
    )
    _require(
        checkpoint.generation == 1
        and checkpoint.next_sequence == 1
        and checkpoint.parent_checkpoint_sha256 == ZERO_DIGEST_HEX
        and checkpoint.previous_selector_sha256 == ZERO_DIGEST_HEX
        and actual_shape == expected_shape
        and checkpoint.objects[0].payload == SOURCE_LIVE_MARKER,
        "generation-one direct checkpoint shape changed",
    )
    contract = _decode_terminal_contract(checkpoint.objects[1].payload)
    input_facts = _decode_direct_input(
        checkpoint.objects[2].payload,
        contract,
    )
    _require(
        checkpoint.request_epoch == contract.request_epoch
        and checkpoint.challenge_sha256 == contract.challenge_sha256.hex(),
        "generation-one checkpoint metadata does not match contract",
    )
    return DirectGenerationOneFacts(
        checkpoint=checkpoint,
        contract=contract,
        input=input_facts,
    )


def _view_root(
    *,
    output_token: int,
    request_epoch: int,
    digests: Sequence[bytes],
) -> bytes:
    _require(len(digests) == len(_VIEW_DIGEST_FIELDS), "invalid view roots")
    body = (
        struct.pack(
            "<QQQQQQQ",
            DIRECT_VIEW_ABI,
            1,
            2,
            request_epoch,
            1,
            0,
            1,
        )
        + struct.pack("<I", output_token)
        + b"".join(digests)
    )
    return recovery._hash(DIRECT_VIEW_DOMAIN, body)


def _decode_generation_two(
    selected: recovery.CheckpointWireFacts,
    *,
    semantic_oracle: bytes | None = None,
) -> DirectTerminalWireFacts:
    expected_shape = (
        (5, 0, recovery.CHECKPOINT_SELECTOR_ABI),
        (6, 0, PREDECESSOR_ARCHIVE_ABI),
        (7, 1, TERMINAL_SEMANTIC_ABI),
        (7, 2, OUTPUT_TOKEN_ABI),
    )
    actual_shape = tuple(
        (value.kind, value.ordinal, value.abi_version) for value in selected.objects
    )
    _require(
        selected.generation == 2
        and selected.next_sequence == 1
        and actual_shape == expected_shape
        and len(selected.objects[3].payload) == 4,
        "generation-two direct checkpoint shape changed",
    )
    embedded_selector = recovery._decode_embedded_selector(selected.objects[0].payload)
    predecessor_bytes = selected.objects[1].payload
    _require(
        embedded_selector.generation == 1
        and embedded_selector.next_sequence == 1
        and embedded_selector.previous_selector_sha256 == ZERO_DIGEST
        and embedded_selector.checkpoint_bytes == len(predecessor_bytes)
        and selected.previous_selector_sha256 == embedded_selector.selector_sha256.hex()
        and selected.parent_checkpoint_sha256
        == embedded_selector.checkpoint_sha256.hex(),
        "embedded predecessor selector lineage changed",
    )
    predecessor = recovery._decode_checkpoint_set(
        predecessor_bytes,
        expected_checkpoint_sha256=embedded_selector.checkpoint_sha256,
        selector_sha256=embedded_selector.selector_sha256,
        previous_selector_sha256=ZERO_DIGEST,
    )
    generation_one = _decode_generation_one(predecessor)
    output_token = cast(
        int,
        struct.unpack("<I", selected.objects[3].payload)[0],
    )
    semantic = _decode_terminal_semantic(selected.objects[2].payload)
    if semantic_oracle is not None:
        _require(
            selected.objects[2].payload == semantic_oracle,
            "selected semantic differs from uninterrupted oracle",
        )
    _validate_semantic_context(
        semantic,
        generation_one.contract,
        generation_one.input,
        output_token,
    )
    _require(
        selected.request_epoch == generation_one.contract.request_epoch
        and selected.challenge_sha256 == generation_one.contract.challenge_sha256.hex()
        and embedded_selector.request_epoch == selected.request_epoch
        and embedded_selector.challenge_sha256
        == generation_one.contract.challenge_sha256,
        "generation-two request or challenge lineage changed",
    )
    input_facts = generation_one.input
    contract = generation_one.contract
    view_digests = (
        input_facts.package_sha256,
        input_facts.representation_sha256,
        input_facts.archive_sha256,
        input_facts.tokenizer_domain_sha256,
        input_facts.tokenizer_behavior_sha256,
        input_facts.tokenizer_config_sha256,
        contract.local_plan_sha256,
        contract.bound_plan_sha256,
        contract.contract_sha256,
        semantic.semantic_sha256,
        semantic.output_sha256,
        semantic.state_commitment_sha256,
        bytes.fromhex(selected.selector_sha256),
        bytes.fromhex(selected.checkpoint_sha256),
        embedded_selector.selector_sha256,
        embedded_selector.checkpoint_sha256,
        contract.challenge_sha256,
    )
    view = DirectViewFacts(
        output_token=output_token,
        package_sha256=view_digests[0],
        representation_sha256=view_digests[1],
        input_archive_sha256=view_digests[2],
        tokenizer_domain_sha256=view_digests[3],
        tokenizer_behavior_sha256=view_digests[4],
        tokenizer_config_sha256=view_digests[5],
        local_plan_sha256=view_digests[6],
        bound_plan_sha256=view_digests[7],
        terminal_source_contract_sha256=view_digests[8],
        terminal_semantic_sha256=view_digests[9],
        terminal_output_sha256=view_digests[10],
        terminal_state_sha256=view_digests[11],
        selected_selector_sha256=view_digests[12],
        selected_set_sha256=view_digests[13],
        predecessor_selector_sha256=view_digests[14],
        predecessor_set_sha256=view_digests[15],
        challenge_sha256=view_digests[16],
        view_sha256=_view_root(
            output_token=output_token,
            request_epoch=contract.request_epoch,
            digests=view_digests,
        ),
    )
    return DirectTerminalWireFacts(
        selected=selected,
        predecessor_selector=embedded_selector,
        generation_one=generation_one,
        semantic=semantic,
        view=view,
    )


def _semantic_oracle(directory: Path) -> bytes:
    encoded = recovery._read_regular_file(
        directory / "prepared-text-terminal-semantic.bin",
        exact_bytes=TERMINAL_SEMANTIC_BYTES,
    )
    _decode_terminal_semantic(encoded)
    return encoded


def inspect_generation_one_directory(
    directory: Path,
) -> DirectGenerationOneFacts:
    """Authenticate an active direct bootstrap checkpoint."""

    checkpoint = recovery._decode_checkpoint_wire(directory)
    _require(checkpoint is not None, "direct checkpoint is absent")
    return _decode_generation_one(cast(recovery.CheckpointWireFacts, checkpoint))


def inspect_terminal_directory(
    directory: Path,
) -> DirectTerminalWireFacts:
    """Authenticate the active direct-terminal checkpoint and embedded parent."""

    checkpoint = recovery._decode_checkpoint_wire(directory)
    _require(checkpoint is not None, "direct terminal checkpoint is absent")
    facts = _decode_generation_two(
        cast(recovery.CheckpointWireFacts, checkpoint),
        semantic_oracle=_semantic_oracle(directory),
    )
    predecessor_name = (
        "checkpoint-" + facts.generation_one.checkpoint.checkpoint_sha256 + ".set"
    )
    retained = recovery._read_regular_file(
        directory / predecessor_name,
        exact_bytes=len(facts.selected.objects[1].payload),
    )
    _require(
        retained == facts.selected.objects[1].payload,
        "retained predecessor archive differs from embedded lineage",
    )
    return facts


def _checkpoint_set_names(
    checkpoint: recovery.CheckpointWireFacts,
    predecessor: recovery.CheckpointWireFacts | None = None,
) -> frozenset[str]:
    roots = [checkpoint.checkpoint_sha256]
    if predecessor is not None:
        roots.append(predecessor.checkpoint_sha256)
    return frozenset(f"checkpoint-{root}.set" for root in roots)


def assert_checkpoint_only_namespace(
    directory: Path,
    checkpoint: recovery.CheckpointWireFacts,
    *,
    predecessor: recovery.CheckpointWireFacts | None = None,
) -> None:
    """Reject all non-fixture/non-checkpoint entries, especially sink files."""

    expected = set(recovery.BASELINE_FIXTURE_NAMES)
    expected.update(
        {
            CHECKPOINT_LOCK_NAME,
            recovery.CHECKPOINT_ACTIVE_SELECTOR_NAME,
        }
    )
    expected.update(_checkpoint_set_names(checkpoint, predecessor))
    try:
        entries = tuple(os.scandir(directory))
    except OSError as error:
        raise CampaignError("cannot inspect direct recovery directory") from error
    observed = {entry.name for entry in entries}
    for name in observed:
        _require(
            name not in RESULT_SINK_FORBIDDEN_NAMES
            and not any(
                name.startswith(prefix) for prefix in RESULT_SINK_FORBIDDEN_PREFIXES
            ),
            "result-sink namespace appeared in direct recovery",
        )
    _require(
        observed == expected,
        "direct recovery directory checkpoint allowlist changed",
    )
    for entry in entries:
        try:
            metadata = entry.stat(follow_symlinks=False)
        except OSError as error:
            raise CampaignError(
                f"cannot inspect directory entry: {entry.name}"
            ) from error
        _require(
            stat.S_ISREG(metadata.st_mode)
            and not entry.is_symlink()
            and metadata.st_nlink == 1
            and (
                entry.name == CHECKPOINT_LOCK_NAME
                or 0 < metadata.st_size <= recovery.MAX_FIXTURE_BYTES
            ),
            f"unsafe direct recovery directory entry: {entry.name}",
        )


def assert_fixture_only_namespace(directory: Path) -> None:
    """Require the immutable fixtures plus the durable image writer's lock."""

    expected = set(recovery.BASELINE_FIXTURE_NAMES)
    expected.add(RUNTIME_IMAGE_PUBLICATION_LOCK_NAME)
    try:
        entries = tuple(os.scandir(directory))
    except OSError as error:
        raise CampaignError("cannot inspect direct baseline directory") from error
    observed = {entry.name for entry in entries}
    for name in observed:
        _require(
            name not in RESULT_SINK_FORBIDDEN_NAMES
            and not any(
                name.startswith(prefix) for prefix in RESULT_SINK_FORBIDDEN_PREFIXES
            ),
            "result-sink namespace appeared in direct baseline",
        )
    _require(observed == expected, "direct baseline fixture allowlist changed")
    for entry in entries:
        try:
            metadata = entry.stat(follow_symlinks=False)
        except OSError as error:
            raise CampaignError(
                f"cannot inspect baseline entry: {entry.name}"
            ) from error
        _require(
            stat.S_ISREG(metadata.st_mode)
            and not entry.is_symlink()
            and metadata.st_nlink == 1
            and (
                (
                    entry.name == RUNTIME_IMAGE_PUBLICATION_LOCK_NAME
                    and metadata.st_size == 0
                )
                or 0 < metadata.st_size <= recovery.MAX_FIXTURE_BYTES
            ),
            f"unsafe direct baseline entry: {entry.name}",
        )


def _validate_generic_result_frame(
    frame: dict[str, object],
    *,
    expected_mode: str,
) -> None:
    _require(
        tuple(frame) == _GENERIC_RESULT_KEYS,
        "generic direct result frame shape changed",
    )
    _require(
        frame["schema"] == recovery.RESULT_SCHEMA and frame["mode"] == expected_mode,
        "wrong generic direct result schema or mode",
    )
    recovery._required_int(frame, "pid", minimum=1)
    _require(
        recovery._required_bool(frame, "ownership_zero")
        and recovery._required_bool(frame, "verified"),
        "generic direct worker leaked ownership or skipped verification",
    )
    for name in (
        "sink_ledger_sha256",
        "sink_selector_sha256",
    ):
        _require(
            recovery._required_digest_hex(frame, name) == ZERO_DIGEST_HEX,
            "direct generic frame exposed result-sink state",
        )
    _require(
        frame["sink_disposition"] == "none"
        and recovery._required_int(frame, "sink_count") == 0
        and recovery._required_int(frame, "sink_next_sequence") == 0,
        "direct generic frame exposed result-sink progress",
    )
    tokens = frame.get("output_tokens")
    _require(type(tokens) is list, "invalid direct generic output tokens")
    raw_tokens = cast(list[object], tokens)
    for token in raw_tokens:
        _require(
            type(token) is int and 0 <= cast(int, token) <= (1 << 32) - 1,
            "direct generic token exceeds u32",
        )
    if expected_mode == "direct-baseline":
        _require(
            (
                recovery._required_int(frame, "input_generation"),
                recovery._required_int(frame, "input_sequence"),
                recovery._required_int(frame, "output_generation"),
                recovery._required_int(frame, "output_sequence"),
            )
            == (1, 0, 1, 1)
            and recovery._required_digest_hex(
                frame,
                "checkpoint_selector_sha256",
            )
            == ZERO_DIGEST_HEX
            and recovery._required_bool(frame, "terminal")
            and len(raw_tokens) == 1
            and recovery._is_digest_hex(
                frame.get("terminal_semantic_sha256"),
                allow_zero=False,
            ),
            "direct baseline is not the exact one-token terminal state",
        )
    elif expected_mode == "direct-bootstrap":
        _require(
            (
                recovery._required_int(frame, "input_generation"),
                recovery._required_int(frame, "input_sequence"),
                recovery._required_int(frame, "output_generation"),
                recovery._required_int(frame, "output_sequence"),
            )
            == (0, 0, 1, 1)
            and recovery._is_digest_hex(
                frame.get("checkpoint_selector_sha256"),
                allow_zero=False,
            )
            and not recovery._required_bool(frame, "terminal")
            and raw_tokens == []
            and frame["terminal_semantic_sha256"] is None,
            "direct bootstrap frame is not exact generation one",
        )
    else:
        raise CampaignError("unknown generic direct result mode")


def _validate_direct_result_shape(
    frame: dict[str, object],
    *,
    expected_mode: str,
    expected_disposition: str,
) -> None:
    _require(
        tuple(frame) == _DIRECT_RESULT_KEYS,
        "direct terminal result frame shape changed",
    )
    _require(
        frame["schema"] == DIRECT_RESULT_SCHEMA
        and frame["mode"] == expected_mode
        and frame["disposition"] == expected_disposition,
        "wrong direct terminal result schema, mode, or disposition",
    )
    recovery._required_int(frame, "pid", minimum=1)
    _require(
        (
            recovery._required_int(frame, "receipt_input_generation"),
            recovery._required_int(frame, "receipt_input_sequence"),
            recovery._required_int(frame, "receipt_output_generation"),
            recovery._required_int(frame, "receipt_output_sequence"),
        )
        == (1, 1, 2, 1)
        and recovery._required_bool(frame, "ownership_zero")
        and recovery._required_int(frame, "view_abi") == DIRECT_VIEW_ABI
        and recovery._required_bool(frame, "terminal")
        and recovery._required_int(frame, "generation") == 2
        and recovery._required_int(frame, "request_epoch", minimum=1) > 0
        and recovery._required_int(frame, "publication_next_sequence") == 1
        and recovery._required_int(frame, "acknowledgement_count") == 0
        and recovery._required_int(frame, "token_count") == 1,
        "direct terminal result scalars changed",
    )
    receipt_token = recovery._required_int(
        frame,
        "receipt_output_token",
    )
    output_token = recovery._required_int(frame, "output_token")
    _require(
        receipt_token == output_token and output_token <= (1 << 32) - 1,
        "direct terminal result token mismatch",
    )
    for name in (
        "receipt_checkpoint_sha256",
        "receipt_checkpoint_selector_sha256",
        "receipt_terminal_source_contract_sha256",
        "receipt_terminal_semantic_sha256",
        *_VIEW_DIGEST_FIELDS,
        "view_sha256",
    ):
        recovery._required_digest_hex(frame, name, allow_zero=False)


def _view_digest_mapping(view: DirectViewFacts) -> dict[str, bytes]:
    return {name: cast(bytes, getattr(view, name)) for name in _VIEW_DIGEST_FIELDS}


def _validate_direct_result_against_wire(
    frame: dict[str, object],
    facts: DirectTerminalWireFacts,
    *,
    expected_mode: str,
    expected_disposition: str,
) -> None:
    _validate_direct_result_shape(
        frame,
        expected_mode=expected_mode,
        expected_disposition=expected_disposition,
    )
    view = facts.view
    _require(
        recovery._required_int(frame, "receipt_output_token") == view.output_token
        and recovery._required_int(frame, "output_token") == view.output_token
        and recovery._required_int(frame, "request_epoch")
        == facts.generation_one.contract.request_epoch
        and frame["receipt_checkpoint_sha256"] == view.selected_set_sha256.hex()
        and frame["receipt_checkpoint_selector_sha256"]
        == view.selected_selector_sha256.hex()
        and frame["receipt_terminal_source_contract_sha256"]
        == view.terminal_source_contract_sha256.hex()
        and frame["receipt_terminal_semantic_sha256"]
        == view.terminal_semantic_sha256.hex(),
        "direct terminal receipt does not match durable wire",
    )
    for name, value in _view_digest_mapping(view).items():
        _require(
            frame[name] == value.hex(),
            f"direct terminal frame {name} differs from oracle",
        )
    _require(
        frame["view_sha256"] == view.view_sha256.hex(),
        "direct terminal ViewV1 root differs from oracle",
    )


def _validate_ready_frame(
    frame: dict[str, object],
    *,
    crash_point: str,
    expected_checkpoint_selector_sha256: str | None = None,
) -> None:
    _require(
        tuple(frame) == _READY_KEYS,
        "direct crash-ready frame shape changed",
    )
    _require(
        frame["schema"] == recovery.CRASH_READY_SCHEMA
        and frame["phase"] == "crash_ready"
        and frame["crash_point"] == crash_point,
        "wrong direct crash-ready schema, phase, or point",
    )
    recovery._required_int(frame, "pid", minimum=1)
    _require(
        recovery._required_int(frame, "input_generation") == 1
        and recovery._required_int(frame, "input_sequence") == 1
        and recovery._required_int(frame, "sink_count") == 0
        and recovery._required_digest_hex(
            frame,
            "sink_ledger_sha256",
        )
        == ZERO_DIGEST_HEX
        and recovery._required_digest_hex(
            frame,
            "sink_selector_sha256",
        )
        == ZERO_DIGEST_HEX
        and recovery._is_digest_hex(
            frame.get("checkpoint_selector_sha256"),
            allow_zero=False,
        ),
        "direct crash-ready state is not sink-free generation one input",
    )
    if expected_checkpoint_selector_sha256 is not None:
        _require(
            recovery._is_digest_hex(
                expected_checkpoint_selector_sha256,
                allow_zero=False,
            )
            and frame["checkpoint_selector_sha256"]
            == expected_checkpoint_selector_sha256,
            "direct crash-ready selector differs from durable state",
        )


def _worker_command(
    worker: Path,
    mode: str,
    directory: Path,
    crash_point: str | None = None,
) -> tuple[str, ...]:
    command = [str(worker), mode, str(directory)]
    if crash_point is not None:
        command.append(crash_point)
    return tuple(command)


def _run_generic_worker(
    worker: Path,
    mode: str,
    directory: Path,
    *,
    timeout_seconds: float,
) -> dict[str, object]:
    def validate(frame: dict[str, object]) -> None:
        _validate_generic_result_frame(frame, expected_mode=mode)

    frame, return_code = recovery._capture_one_frame(
        _worker_command(worker, mode, directory),
        timeout_seconds=timeout_seconds,
        validate_frame=validate,
        process_label=mode,
        require_frame_pid_match=True,
    )
    _require(return_code == 0, f"{mode} worker exited unsuccessfully")
    return frame


def _run_direct_worker(
    worker: Path,
    mode: str,
    directory: Path,
    *,
    expected_disposition: str,
    timeout_seconds: float,
) -> tuple[dict[str, object], DirectTerminalWireFacts]:
    def validate(frame: dict[str, object]) -> None:
        _validate_direct_result_shape(
            frame,
            expected_mode=mode,
            expected_disposition=expected_disposition,
        )

    frame, return_code = recovery._capture_one_frame(
        _worker_command(worker, mode, directory),
        timeout_seconds=timeout_seconds,
        validate_frame=validate,
        process_label=mode,
        require_frame_pid_match=True,
    )
    _require(return_code == 0, f"{mode} worker exited unsuccessfully")
    facts = inspect_terminal_directory(directory)
    _validate_direct_result_against_wire(
        frame,
        facts,
        expected_mode=mode,
        expected_disposition=expected_disposition,
    )
    return frame, facts


def _run_crash_worker(
    worker: Path,
    directory: Path,
    crash_point: str,
    *,
    timeout_seconds: float,
) -> dict[str, object]:
    def validate(frame: dict[str, object]) -> None:
        _validate_ready_frame(frame, crash_point=crash_point)

    frame, return_code = recovery._capture_one_frame(
        _worker_command(
            worker,
            "direct-terminal",
            directory,
            crash_point,
        ),
        timeout_seconds=timeout_seconds,
        validate_frame=validate,
        process_label=f"direct-terminal:{crash_point}",
        require_frame_pid_match=True,
    )
    _require(
        return_code == -signal.SIGKILL,
        "direct crash worker did not terminate by SIGKILL",
    )
    return frame


def _record_pid(
    frame: Mapping[str, object],
    seen: set[int],
    role: str,
) -> int:
    return recovery._record_distinct_pid(frame, seen, role)


def _same_generation_one(
    left: DirectGenerationOneFacts,
    right: DirectGenerationOneFacts,
) -> bool:
    return (
        left.checkpoint.checkpoint_sha256 == right.checkpoint.checkpoint_sha256
        and left.checkpoint.selector_sha256 == right.checkpoint.selector_sha256
        and left.contract == right.contract
        and left.input == right.input
    )


def _same_terminal(
    left: DirectTerminalWireFacts,
    right: DirectTerminalWireFacts,
) -> bool:
    return (
        left.selected.checkpoint_sha256 == right.selected.checkpoint_sha256
        and left.selected.selector_sha256 == right.selected.selector_sha256
        and left.semantic == right.semantic
        and left.view == right.view
    )


def run_campaign(
    worker: Path,
    directory: Path,
    *,
    crash_points: Sequence[str] = DIRECT_CRASH_POINTS,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, object]:
    """Run one uninterrupted reference and isolated SIGKILL recovery cases."""

    selected_points = tuple(crash_points)
    _require(
        bool(selected_points)
        and len(selected_points) == len(set(selected_points))
        and all(point in DIRECT_CRASH_POINTS for point in selected_points),
        "invalid direct-terminal crash-point selection",
    )
    _require(
        timeout_seconds > 0 and directory.is_absolute(),
        "invalid direct-terminal campaign path or timeout",
    )
    recovery._require_executable_regular(worker, "direct recovery worker")
    worker_image = recovery._read_regular_file(
        worker,
        maximum_bytes=recovery.MAX_FIXTURE_BYTES,
    )
    worker_sha256 = hashlib.sha256(worker_image).hexdigest()
    recovery._prepare_campaign_root(directory)
    seen_pids: set[int] = set()

    baseline_directory = directory / "baseline"
    recovery._fresh_directory(baseline_directory)
    baseline = _run_generic_worker(
        worker,
        "direct-baseline",
        baseline_directory,
        timeout_seconds=timeout_seconds,
    )
    _record_pid(baseline, seen_pids, "direct-baseline")
    assert_fixture_only_namespace(baseline_directory)
    baseline_semantic_bytes = _semantic_oracle(baseline_directory)
    baseline_semantic = _decode_terminal_semantic(baseline_semantic_bytes)
    _require(
        baseline["terminal_semantic_sha256"] == baseline_semantic.semantic_sha256.hex(),
        "direct baseline semantic frame differs from fixture",
    )
    baseline_tokens = cast(list[object], baseline["output_tokens"])
    baseline_token = cast(int, baseline_tokens[0])

    reference_directory = directory / "reference"
    recovery._fresh_directory(reference_directory)
    recovery._copy_baseline_fixtures(
        baseline_directory,
        reference_directory,
    )
    reference_bootstrap = _run_generic_worker(
        worker,
        "direct-bootstrap",
        reference_directory,
        timeout_seconds=timeout_seconds,
    )
    _record_pid(reference_bootstrap, seen_pids, "reference:bootstrap")
    reference_generation_one = inspect_generation_one_directory(reference_directory)
    _require(
        reference_bootstrap["checkpoint_selector_sha256"]
        == reference_generation_one.checkpoint.selector_sha256,
        "reference bootstrap frame differs from generation one",
    )
    assert_checkpoint_only_namespace(
        reference_directory,
        reference_generation_one.checkpoint,
    )

    reference_result, reference_terminal = _run_direct_worker(
        worker,
        "direct-terminal",
        reference_directory,
        expected_disposition="advanced",
        timeout_seconds=timeout_seconds,
    )
    _record_pid(reference_result, seen_pids, "reference:terminal")
    _require(
        reference_terminal.semantic.encoded == baseline_semantic_bytes
        and reference_terminal.view.output_token == baseline_token,
        "uninterrupted direct result differs from one-token baseline",
    )
    assert_checkpoint_only_namespace(
        reference_directory,
        reference_terminal.selected,
        predecessor=reference_terminal.generation_one.checkpoint,
    )
    reference_audit, reference_audited = _run_direct_worker(
        worker,
        "direct-audit",
        reference_directory,
        expected_disposition="already_selected",
        timeout_seconds=timeout_seconds,
    )
    _record_pid(reference_audit, seen_pids, "reference:audit")
    _require(
        _same_terminal(reference_terminal, reference_audited),
        "read-only reference audit changed direct terminal selection",
    )
    assert_checkpoint_only_namespace(
        reference_directory,
        reference_audited.selected,
        predecessor=reference_audited.generation_one.checkpoint,
    )

    cases: list[dict[str, object]] = []
    for crash_point in selected_points:
        case_directory = directory / f"case-{crash_point}"
        recovery._fresh_directory(case_directory)
        recovery._copy_baseline_fixtures(
            baseline_directory,
            case_directory,
        )
        bootstrap = _run_generic_worker(
            worker,
            "direct-bootstrap",
            case_directory,
            timeout_seconds=timeout_seconds,
        )
        _record_pid(bootstrap, seen_pids, f"{crash_point}:bootstrap")
        generation_one = inspect_generation_one_directory(case_directory)
        _require(
            _same_generation_one(
                generation_one,
                reference_generation_one,
            )
            and bootstrap["checkpoint_selector_sha256"]
            == generation_one.checkpoint.selector_sha256,
            "case bootstrap differs from exact reference generation one",
        )
        assert_checkpoint_only_namespace(
            case_directory,
            generation_one.checkpoint,
        )

        ready = _run_crash_worker(
            worker,
            case_directory,
            crash_point,
            timeout_seconds=timeout_seconds,
        )
        victim_pid = _record_pid(
            ready,
            seen_pids,
            f"{crash_point}:victim",
        )
        if crash_point in GENERATION_ONE_CRASH_POINTS:
            visible_generation = 1
            visible = inspect_generation_one_directory(case_directory)
            _validate_ready_frame(
                ready,
                crash_point=crash_point,
                expected_checkpoint_selector_sha256=(
                    visible.checkpoint.selector_sha256
                ),
            )
            _require(
                _same_generation_one(visible, generation_one)
                and ready["checkpoint_selector_sha256"]
                == visible.checkpoint.selector_sha256,
                "pre-selection crash changed exact generation one",
            )
            assert_checkpoint_only_namespace(
                case_directory,
                visible.checkpoint,
            )
            expected_disposition = "advanced"
        else:
            visible_generation = 2
            visible_terminal = inspect_terminal_directory(case_directory)
            _validate_ready_frame(
                ready,
                crash_point=crash_point,
                expected_checkpoint_selector_sha256=(
                    visible_terminal.selected.selector_sha256
                ),
            )
            _require(
                _same_terminal(
                    visible_terminal,
                    reference_terminal,
                )
                and ready["checkpoint_selector_sha256"]
                == visible_terminal.selected.selector_sha256,
                "post-selection crash differs from exact generation two",
            )
            assert_checkpoint_only_namespace(
                case_directory,
                visible_terminal.selected,
                predecessor=visible_terminal.generation_one.checkpoint,
            )
            expected_disposition = "already_selected"

        recovery_result, recovered = _run_direct_worker(
            worker,
            "direct-terminal",
            case_directory,
            expected_disposition=expected_disposition,
            timeout_seconds=timeout_seconds,
        )
        recovery_pid = _record_pid(
            recovery_result,
            seen_pids,
            f"{crash_point}:recovery",
        )
        _require(
            _same_terminal(recovered, reference_terminal),
            "fresh direct recovery differs from uninterrupted reference",
        )
        assert_checkpoint_only_namespace(
            case_directory,
            recovered.selected,
            predecessor=recovered.generation_one.checkpoint,
        )
        audit_result, audited = _run_direct_worker(
            worker,
            "direct-audit",
            case_directory,
            expected_disposition="already_selected",
            timeout_seconds=timeout_seconds,
        )
        audit_pid = _record_pid(
            audit_result,
            seen_pids,
            f"{crash_point}:audit",
        )
        _require(
            _same_terminal(audited, reference_terminal),
            "post-recovery audit differs from uninterrupted reference",
        )
        assert_checkpoint_only_namespace(
            case_directory,
            audited.selected,
            predecessor=audited.generation_one.checkpoint,
        )
        cases.append(
            {
                "crash_point": crash_point,
                "victim_pid": victim_pid,
                "visible_generation_after_sigkill": visible_generation,
                "fresh_disposition": expected_disposition,
                "recovery_pid": recovery_pid,
                "audit_pid": audit_pid,
                "selected_set_sha256": (audited.view.selected_set_sha256.hex()),
                "selected_selector_sha256": (
                    audited.view.selected_selector_sha256.hex()
                ),
                "view_sha256": audited.view.view_sha256.hex(),
                "checkpoint_only_namespace": True,
                "verified": True,
            }
        )

    worker_after = recovery._read_regular_file(
        worker,
        maximum_bytes=recovery.MAX_FIXTURE_BYTES,
    )
    _require(
        hashlib.sha256(worker_after).hexdigest() == worker_sha256,
        "direct recovery worker image changed during campaign",
    )
    return {
        "schema": CAMPAIGN_SCHEMA,
        "process_death_count": len(selected_points),
        "crash_point_count": len(selected_points),
        "crash_points": list(selected_points),
        "worker_sha256": worker_sha256,
        "worker_compilations_during_campaign": 0,
        "baseline_output_token": baseline_token,
        "baseline_terminal_semantic_sha256": (baseline_semantic.semantic_sha256.hex()),
        "reference_selected_set_sha256": (
            reference_terminal.view.selected_set_sha256.hex()
        ),
        "reference_view_sha256": (reference_terminal.view.view_sha256.hex()),
        "generation_one_preselection_case_count": sum(
            point in GENERATION_ONE_CRASH_POINTS for point in selected_points
        ),
        "generation_two_selected_case_count": sum(
            point in GENERATION_TWO_CRASH_POINTS for point in selected_points
        ),
        "selector_rename_durability_scope": "host_process_death_only",
        "power_loss_durability_claimed": False,
        "result_sink_namespace_absent": True,
        "distinct_pid_count": len(seen_pids),
        "cases": cases,
        "verified": True,
    }


def _parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=("Run the direct one-token terminal process-death campaign"),
    )
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument(
        "--crash-point",
        action="append",
        choices=DIRECT_CRASH_POINTS,
        dest="crash_points",
        help="run only this point (repeatable); defaults to all four",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    parsed = _parse_arguments(sys.argv[1:] if arguments is None else arguments)
    crash_points = (
        DIRECT_CRASH_POINTS
        if parsed.crash_points is None
        else tuple(parsed.crash_points)
    )
    try:
        report = run_campaign(
            parsed.worker.resolve(),
            parsed.directory.resolve(),
            crash_points=crash_points,
            timeout_seconds=parsed.timeout_seconds,
        )
    except CampaignError as error:
        print(
            f"direct terminal recovery campaign failed: {error}",
            file=sys.stderr,
        )
        return 1
    print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
