"""Focused Python-only tests for direct terminal recovery evidence."""

from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import textwrap
import unittest

from bench import prepared_text_direct_terminal_recovery as campaign
from bench import prepared_text_package as prepared_package
from bench import prepared_text_raw_input as raw_input
from bench import prepared_text_recovery_campaign as recovery


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _checkpoint_set(
    *,
    generation: int,
    request_epoch: int,
    parent: bytes,
    challenge: bytes,
    objects: tuple[tuple[int, int, int, bytes], ...],
) -> bytes:
    payload_bytes = sum(len(value[3]) for value in objects)
    total = (
        recovery.CHECKPOINT_SET_PAYLOAD_OFFSET
        + payload_bytes
        + recovery.CHECKPOINT_SET_FOOTER_BYTES
    )
    encoded = bytearray(total)
    encoded[:8] = recovery.CHECKPOINT_SET_MAGIC
    struct.pack_into(
        "<QQQQQQQ",
        encoded,
        8,
        recovery.CHECKPOINT_SET_ABI,
        total,
        generation,
        request_epoch,
        1,
        len(objects),
        0,
    )
    encoded[64:96] = parent
    encoded[96:128] = challenge
    cursor = recovery.CHECKPOINT_SET_PAYLOAD_OFFSET
    for index, (kind, ordinal, abi_version, payload) in enumerate(objects):
        root = recovery._hash(
            recovery.CHECKPOINT_OBJECT_DOMAIN,
            struct.pack(
                "<QQQQ",
                kind,
                ordinal,
                abi_version,
                len(payload),
            )
            + payload,
        )
        offset = (
            recovery.CHECKPOINT_SET_HEADER_BYTES
            + index * recovery.CHECKPOINT_SET_ENTRY_BYTES
        )
        struct.pack_into(
            "<QQQQQ",
            encoded,
            offset,
            kind,
            ordinal,
            abi_version,
            cursor,
            len(payload),
        )
        encoded[offset + 40 : offset + 72] = root
        encoded[cursor : cursor + len(payload)] = payload
        cursor += len(payload)
    encoded[-32:] = recovery._hash(
        recovery.CHECKPOINT_SET_DOMAIN,
        bytes(encoded[:-32]),
    )
    return bytes(encoded)


def _checkpoint_selector(
    checkpoint: bytes,
    *,
    generation: int,
    request_epoch: int,
    previous_selector: bytes,
    challenge: bytes,
) -> bytes:
    encoded = bytearray(recovery.CHECKPOINT_SELECTOR_BYTES)
    encoded[:8] = recovery.CHECKPOINT_SELECTOR_MAGIC
    struct.pack_into(
        "<QQQQQQQ",
        encoded,
        8,
        recovery.CHECKPOINT_SELECTOR_ABI,
        recovery.CHECKPOINT_SELECTOR_BYTES,
        generation,
        request_epoch,
        1,
        len(checkpoint),
        0,
    )
    encoded[64:96] = previous_selector
    encoded[96:128] = checkpoint[-32:]
    encoded[128:160] = challenge
    encoded[160:192] = recovery._hash(
        recovery.CHECKPOINT_SELECTOR_DOMAIN,
        bytes(encoded[:160]),
    )
    return bytes(encoded)


def _terminal_contract(
    *,
    tokens: tuple[int, ...],
    request_epoch: int,
    challenge: bytes,
    tokenizer_domain: bytes,
    tokenizer_config: bytes,
    license_sha256: bytes,
    local_plan: bytes,
    bound_plan: bytes,
    artifact: bytes,
    execution: bytes,
    residency: bytes,
) -> bytes:
    prompt_wire = struct.pack("<" + "I" * len(tokens), *tokens)
    total = (
        campaign.TERMINAL_CONTRACT_PROMPT_OFFSET
        + len(prompt_wire)
        + campaign.TERMINAL_CONTRACT_FOOTER_BYTES
    )
    encoded = bytearray(total)
    encoded[:8] = campaign.TERMINAL_CONTRACT_MAGIC
    struct.pack_into(
        "<QQQQQQQ",
        encoded,
        8,
        campaign.TERMINAL_CONTRACT_ABI,
        total,
        0,
        campaign.TERMINAL_CONTRACT_HEADER_BYTES,
        campaign.TERMINAL_CONTRACT_FIXED_PAYLOAD_BYTES,
        len(tokens),
        len(prompt_wire),
    )
    struct.pack_into("<QQQ", encoded, 128, 1, 255, 9)
    struct.pack_into("<QQQQQQ", encoded, 152, 11, 12, 1, 13, 1, 0)
    struct.pack_into("<Q", encoded, 200, request_epoch)
    encoded[208:240] = tokenizer_domain
    encoded[240:272] = tokenizer_config
    encoded[272:304] = license_sha256
    encoded[304:336] = campaign.ZERO_DIGEST
    struct.pack_into("<QQQ", encoded, 336, 21, 22, 23)
    struct.pack_into("<QQ", encoded, 360, request_epoch, 1)
    encoded[376:408] = challenge
    prompt_sha256 = recovery._hash(
        campaign.PROMPT_DOMAIN,
        struct.pack("<Q", len(tokens)) + prompt_wire,
    )
    for offset, root in zip(
        (408, 440, 472, 504, 536, 568),
        (
            local_plan,
            bound_plan,
            prompt_sha256,
            artifact,
            execution,
            residency,
        ),
        strict=True,
    ):
        encoded[offset : offset + 32] = root
    encoded[600 : 600 + len(prompt_wire)] = prompt_wire
    encoded[-32:] = recovery._hash(
        campaign.TERMINAL_CONTRACT_DOMAIN,
        bytes(encoded[:-32]),
    )
    return bytes(encoded)


def _terminal_semantic(
    *,
    contract: campaign.DirectTerminalContractFacts,
    image_container: bytes,
    output_token: int,
) -> bytes:
    encoded = bytearray(campaign.TERMINAL_SEMANTIC_BYTES)
    encoded[:8] = campaign.TERMINAL_SEMANTIC_MAGIC
    struct.pack_into(
        "<QQQ",
        encoded,
        8,
        campaign.TERMINAL_SEMANTIC_ABI,
        campaign.TERMINAL_SEMANTIC_BYTES,
        0,
    )
    prompt_count = len(contract.prompt_tokens)
    execution_abi = 31
    rng_abi = 32
    struct.pack_into(
        "<QQQQQQQQQQ",
        encoded,
        32,
        contract.request_epoch,
        1,
        prompt_count,
        1,
        prompt_count,
        1,
        1,
        4,
        execution_abi,
        rng_abi,
    )
    kv_state = _digest("kv-state")
    rng_state = _digest("rng-state")
    output_state = _digest("output-state")
    output_root = campaign._terminal_output_root(contract, output_token)
    state_root = recovery._hash(
        campaign.STATE_COMMITMENT_DOMAIN,
        struct.pack(
            "<QQQ",
            campaign.STATE_COMMITMENT_ABI,
            execution_abi,
            prompt_count,
        )
        + kv_state
        + struct.pack("<Q", rng_abi)
        + rng_state
        + struct.pack("<QQ", 1, 1)
        + output_state,
    )
    digests = (
        contract.local_plan_sha256,
        contract.artifact_sha256,
        contract.token_domain_sha256,
        contract.token_config_sha256,
        image_container,
        contract.prompt_sha256,
        output_root,
        _digest("logical-kv"),
        kv_state,
        rng_state,
        output_state,
        state_root,
    )
    for index, root in enumerate(digests):
        offset = 112 + index * 32
        encoded[offset : offset + 32] = root
    encoded[-32:] = recovery._hash(
        campaign.TERMINAL_SEMANTIC_DOMAIN,
        bytes(encoded[:-32]),
    )
    return bytes(encoded)


def _fixture() -> dict[str, object]:
    text = "Ice"
    raw_text = text.encode("utf-8")
    tokens, tokenizer_wire, tokenizer_prompt = raw_input.tokenize(
        text,
        vocab_size=256,
        max_input_bytes=4096,
    )
    tokenizer = raw_input.decode_manifest(tokenizer_wire)
    prompt = raw_input.decode_prompt(tokenizer_prompt)
    request_epoch = 7
    challenge = _digest("challenge")
    license_sha256 = _digest("license")
    local_plan = _digest("local-plan")
    bound_plan = _digest("bound-plan")
    artifact = _digest("artifact")
    execution = _digest("execution")
    residency = _digest("residency")

    package_wire = prepared_package.encode_manifest(
        {
            "family": 1,
            "source_format": 1,
            "portable_format_abi": 1,
            "conversion_profile_abi": 2,
            "conversion_plan_abi": 3,
            "tokenizer_manifest_abi": raw_input.MANIFEST_ABI,
            "tokenizer_manifest_bytes": raw_input.MANIFEST_BYTES,
            "source_bytes": 64,
            "portable_bytes": 32,
            "portable_page_count": 1,
            "license_bytes": 16,
            "config": {
                "dim": 4,
                "hidden_dim": 8,
                "layers": 1,
                "vocab": 256,
                "heads": 1,
                "head_dim": 4,
                "kv_heads": 1,
                "tie_embeddings": True,
                "rms_eps": 0.00001,
                "rope_theta": 10000.0,
            },
            "source_sha256": _digest("source"),
            "portable_artifact_sha256": _digest("portable"),
            "conversion_profile_sha256": _digest("conversion-profile"),
            "conversion_plan_sha256": _digest("conversion-plan"),
            "model_content_sha256": _digest("model-content"),
            "tokenizer_config_sha256": tokenizer["config_sha256"],
            "tokenizer_domain_sha256": tokenizer["domain_sha256"],
            "tokenizer_behavior_sha256": tokenizer["behavior_sha256"],
            "license_sha256": license_sha256,
        }
    )
    package = prepared_package.decode_manifest(package_wire)
    image_container = _digest("container")
    representation_wire = prepared_package.encode_prepared_representation(
        {
            "format_abi": 11,
            "format_version": 1,
            "container_bytes": 32,
            "package_sha256": package["package_sha256"],
            "resolved_config_sha256": package["resolved_config_sha256"],
            "source_fingerprint": _digest("model-content"),
            "abi_fingerprint": _digest("abi-fingerprint"),
            "container_sha256": image_container,
        }
    )
    contract_wire = _terminal_contract(
        tokens=tuple(tokens),
        request_epoch=request_epoch,
        challenge=challenge,
        tokenizer_domain=tokenizer["domain_sha256"],
        tokenizer_config=tokenizer["config_sha256"],
        license_sha256=license_sha256,
        local_plan=local_plan,
        bound_plan=bound_plan,
        artifact=artifact,
        execution=execution,
        residency=residency,
    )
    contract = campaign._decode_terminal_contract(contract_wire)
    binding_wire = raw_input.binding_wire_from_report(
        {
            "tokenizer_domain_sha256": tokenizer["domain_sha256"].hex(),
            "tokenizer_config_sha256": tokenizer["config_sha256"].hex(),
            "prompt_receipt_sha256": prompt["receipt_sha256"].hex(),
            "raw_text_sha256": raw_input.raw_text_sha256(raw_text).hex(),
            "token_ids_sha256": raw_input.token_ids_sha256(tokens).hex(),
            "prepared_prompt_sha256": contract.prompt_sha256.hex(),
            "local_plan_sha256": local_plan.hex(),
            "bound_plan_sha256": bound_plan.hex(),
            "artifact_sha256": artifact.hex(),
            "execution_plan_sha256": execution.hex(),
            "residency_binding_sha256": residency.hex(),
            "artifact_license_sha256": license_sha256.hex(),
            "request_epoch": request_epoch,
            "prompt_tokens": len(tokens),
            "prompt_bytes": len(raw_text),
        }
    )
    archive_wire = prepared_package.archive_wire(
        package=package_wire,
        representation=representation_wire,
        tokenizer_manifest=tokenizer_wire,
        tokenizer_prompt=tokenizer_prompt,
        binding=binding_wire,
        raw_text=raw_text,
    )
    generation_one = _checkpoint_set(
        generation=1,
        request_epoch=request_epoch,
        parent=campaign.ZERO_DIGEST,
        challenge=challenge,
        objects=(
            (
                7,
                0,
                campaign.SOURCE_LIVE_MARKER_ABI,
                campaign.SOURCE_LIVE_MARKER,
            ),
            (7, 1, campaign.TERMINAL_CONTRACT_ABI, contract_wire),
            (7, 2, prepared_package.ARCHIVE_ABI, archive_wire),
        ),
    )
    selector_one = _checkpoint_selector(
        generation_one,
        generation=1,
        request_epoch=request_epoch,
        previous_selector=campaign.ZERO_DIGEST,
        challenge=challenge,
    )
    output_token = 41
    semantic_wire = _terminal_semantic(
        contract=contract,
        image_container=image_container,
        output_token=output_token,
    )
    generation_two = _checkpoint_set(
        generation=2,
        request_epoch=request_epoch,
        parent=generation_one[-32:],
        challenge=challenge,
        objects=(
            (
                5,
                0,
                recovery.CHECKPOINT_SELECTOR_ABI,
                selector_one,
            ),
            (
                6,
                0,
                campaign.PREDECESSOR_ARCHIVE_ABI,
                generation_one,
            ),
            (
                7,
                1,
                campaign.TERMINAL_SEMANTIC_ABI,
                semantic_wire,
            ),
            (
                7,
                2,
                campaign.OUTPUT_TOKEN_ABI,
                struct.pack("<I", output_token),
            ),
        ),
    )
    selector_two = _checkpoint_selector(
        generation_two,
        generation=2,
        request_epoch=request_epoch,
        previous_selector=selector_one[-32:],
        challenge=challenge,
    )
    return {
        "contract": contract,
        "generation_one": generation_one,
        "selector_one": selector_one,
        "semantic": semantic_wire,
        "generation_two": generation_two,
        "selector_two": selector_two,
        "output_token": output_token,
    }


def _write_fixture_directory(
    directory: Path,
    value: dict[str, object],
    *,
    terminal: bool,
) -> None:
    directory.mkdir()
    for name in recovery.BASELINE_FIXTURE_NAMES[:4]:
        (directory / name).write_bytes(b"fixture")
    semantic = value["semantic"]
    assert isinstance(semantic, bytes)
    (directory / "prepared-text-terminal-semantic.bin").write_bytes(semantic)
    (directory / campaign.CHECKPOINT_LOCK_NAME).write_bytes(b"")
    generation_one = value["generation_one"]
    selector_one = value["selector_one"]
    assert isinstance(generation_one, bytes)
    assert isinstance(selector_one, bytes)
    one_name = f"checkpoint-{generation_one[-32:].hex()}.set"
    (directory / one_name).write_bytes(generation_one)
    if terminal:
        generation_two = value["generation_two"]
        selector_two = value["selector_two"]
        assert isinstance(generation_two, bytes)
        assert isinstance(selector_two, bytes)
        two_name = f"checkpoint-{generation_two[-32:].hex()}.set"
        (directory / two_name).write_bytes(generation_two)
        (directory / recovery.CHECKPOINT_ACTIVE_SELECTOR_NAME).write_bytes(selector_two)
    else:
        (directory / recovery.CHECKPOINT_ACTIVE_SELECTOR_NAME).write_bytes(selector_one)


class DirectTerminalRecoveryOracleTests(unittest.TestCase):
    def test_capture_rejects_fabricated_child_pid(self) -> None:
        script = textwrap.dedent(
            """\
            import json
            print(json.dumps({"pid": 1}, separators=(",", ":")))
            """
        )
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "frame PID does not match child process",
        ):
            recovery._capture_one_frame(
                (sys.executable, "-c", script),
                timeout_seconds=3,
                validate_frame=lambda _: None,
                process_label="fabricated-pid",
                require_frame_pid_match=True,
            )

    def test_crash_table_partition_and_ready_frame_are_exact(self) -> None:
        self.assertEqual(
            (
                "direct_after_step",
                "direct_after_retire",
                "direct_checkpoint_selector_rename",
                "direct_after_generation_two",
            ),
            campaign.DIRECT_CRASH_POINTS,
        )
        self.assertEqual(4, len(set(campaign.DIRECT_CRASH_POINTS)))
        self.assertEqual(
            set(campaign.DIRECT_CRASH_POINTS),
            set(campaign.GENERATION_ONE_CRASH_POINTS)
            | set(campaign.GENERATION_TWO_CRASH_POINTS),
        )
        self.assertFalse(
            campaign.GENERATION_ONE_CRASH_POINTS & campaign.GENERATION_TWO_CRASH_POINTS
        )
        selector = _digest("selected-selector").hex()
        ready = {
            "schema": recovery.CRASH_READY_SCHEMA,
            "phase": "crash_ready",
            "pid": 3,
            "crash_point": "direct_after_step",
            "input_generation": 1,
            "input_sequence": 1,
            "sink_count": 0,
            "sink_ledger_sha256": campaign.ZERO_DIGEST_HEX,
            "sink_selector_sha256": campaign.ZERO_DIGEST_HEX,
            "checkpoint_selector_sha256": selector,
        }
        campaign._validate_ready_frame(
            ready,
            crash_point="direct_after_step",
            expected_checkpoint_selector_sha256=selector,
        )
        ready["sink_ledger_sha256"] = _digest("sink-ledger").hex()
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "sink-free",
        ):
            campaign._validate_ready_frame(
                ready,
                crash_point="direct_after_step",
                expected_checkpoint_selector_sha256=selector,
            )
        ready["sink_ledger_sha256"] = campaign.ZERO_DIGEST_HEX
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "differs from durable state",
        ):
            campaign._validate_ready_frame(
                ready,
                crash_point="direct_after_step",
                expected_checkpoint_selector_sha256=(_digest("foreign-selector").hex()),
            )

    def test_exact_generation_one_and_terminal_view_are_accepted(self) -> None:
        value = _fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            generation_one_directory = root / "one"
            _write_fixture_directory(
                generation_one_directory,
                value,
                terminal=False,
            )
            generation_one = campaign.inspect_generation_one_directory(
                generation_one_directory
            )
            campaign.assert_checkpoint_only_namespace(
                generation_one_directory,
                generation_one.checkpoint,
            )
            self.assertEqual(1, generation_one.checkpoint.generation)

            terminal_directory = root / "two"
            _write_fixture_directory(
                terminal_directory,
                value,
                terminal=True,
            )
            terminal = campaign.inspect_terminal_directory(terminal_directory)
            campaign.assert_checkpoint_only_namespace(
                terminal_directory,
                terminal.selected,
                predecessor=terminal.generation_one.checkpoint,
            )
            self.assertEqual(value["output_token"], terminal.view.output_token)
            self.assertEqual(
                terminal.view.view_sha256,
                campaign._view_root(
                    output_token=terminal.view.output_token,
                    request_epoch=(terminal.generation_one.contract.request_epoch),
                    digests=tuple(
                        getattr(terminal.view, name)
                        for name in campaign._VIEW_DIGEST_FIELDS
                    ),
                ),
            )

    def test_direct_object_abi_drift_is_rejected_after_full_reroot(self) -> None:
        value = _fixture()
        generation_two = value["generation_two"]
        selector_one = value["selector_one"]
        generation_one = value["generation_one"]
        semantic = value["semantic"]
        contract = value["contract"]
        output_token = value["output_token"]
        assert isinstance(generation_two, bytes)
        assert isinstance(selector_one, bytes)
        assert isinstance(generation_one, bytes)
        assert isinstance(semantic, bytes)
        assert isinstance(
            contract,
            campaign.DirectTerminalContractFacts,
        )
        assert isinstance(output_token, int)
        changed = _checkpoint_set(
            generation=2,
            request_epoch=contract.request_epoch,
            parent=generation_one[-32:],
            challenge=contract.challenge_sha256,
            objects=(
                (
                    5,
                    0,
                    recovery.CHECKPOINT_SELECTOR_ABI,
                    selector_one,
                ),
                (
                    6,
                    0,
                    campaign.PREDECESSOR_ARCHIVE_ABI,
                    generation_one,
                ),
                (
                    7,
                    1,
                    campaign.TERMINAL_SEMANTIC_ABI + 1,
                    semantic,
                ),
                (
                    7,
                    2,
                    campaign.OUTPUT_TOKEN_ABI,
                    struct.pack("<I", output_token),
                ),
            ),
        )
        changed_selector = _checkpoint_selector(
            changed,
            generation=2,
            request_epoch=contract.request_epoch,
            previous_selector=selector_one[-32:],
            challenge=contract.challenge_sha256,
        )
        selected = recovery._decode_checkpoint_set(
            changed,
            expected_checkpoint_sha256=changed[-32:],
            selector_sha256=changed_selector[-32:],
            previous_selector_sha256=selector_one[-32:],
        )
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "shape changed",
        ):
            campaign._decode_generation_two(
                selected,
                semantic_oracle=semantic,
            )

    def test_embedded_predecessor_selector_lineage_is_rejected(self) -> None:
        value = _fixture()
        selector_one = value["selector_one"]
        generation_one = value["generation_one"]
        semantic = value["semantic"]
        contract = value["contract"]
        output_token = value["output_token"]
        assert isinstance(selector_one, bytes)
        assert isinstance(generation_one, bytes)
        assert isinstance(semantic, bytes)
        assert isinstance(
            contract,
            campaign.DirectTerminalContractFacts,
        )
        assert isinstance(output_token, int)
        foreign_selector = bytearray(selector_one)
        foreign_selector[64:96] = _digest("impossible-previous-selector")
        foreign_selector[160:192] = recovery._hash(
            recovery.CHECKPOINT_SELECTOR_DOMAIN,
            bytes(foreign_selector[:160]),
        )
        changed = _checkpoint_set(
            generation=2,
            request_epoch=contract.request_epoch,
            parent=generation_one[-32:],
            challenge=contract.challenge_sha256,
            objects=(
                (
                    5,
                    0,
                    recovery.CHECKPOINT_SELECTOR_ABI,
                    bytes(foreign_selector),
                ),
                (
                    6,
                    0,
                    campaign.PREDECESSOR_ARCHIVE_ABI,
                    generation_one,
                ),
                (
                    7,
                    1,
                    campaign.TERMINAL_SEMANTIC_ABI,
                    semantic,
                ),
                (
                    7,
                    2,
                    campaign.OUTPUT_TOKEN_ABI,
                    struct.pack("<I", output_token),
                ),
            ),
        )
        changed_selector = _checkpoint_selector(
            changed,
            generation=2,
            request_epoch=contract.request_epoch,
            previous_selector=bytes(foreign_selector[-32:]),
            challenge=contract.challenge_sha256,
        )
        selected = recovery._decode_checkpoint_set(
            changed,
            expected_checkpoint_sha256=changed[-32:],
            selector_sha256=changed_selector[-32:],
            previous_selector_sha256=bytes(foreign_selector[-32:]),
        )
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "embedded predecessor selector",
        ):
            campaign._decode_generation_two(
                selected,
                semantic_oracle=semantic,
            )

    def test_result_frames_use_exact_one_token_protocol(self) -> None:
        value = _fixture()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "terminal"
            _write_fixture_directory(directory, value, terminal=True)
            terminal = campaign.inspect_terminal_directory(directory)
        semantic = terminal.semantic.semantic_sha256.hex()
        baseline = {
            "schema": recovery.RESULT_SCHEMA,
            "mode": "direct-baseline",
            "pid": 1,
            "input_generation": 1,
            "input_sequence": 0,
            "output_generation": 1,
            "output_sequence": 1,
            "sink_disposition": "none",
            "sink_count": 0,
            "sink_next_sequence": 0,
            "sink_ledger_sha256": campaign.ZERO_DIGEST_HEX,
            "sink_selector_sha256": campaign.ZERO_DIGEST_HEX,
            "checkpoint_selector_sha256": campaign.ZERO_DIGEST_HEX,
            "terminal": True,
            "ownership_zero": True,
            "verified": True,
            "output_tokens": [terminal.view.output_token],
            "terminal_semantic_sha256": semantic,
        }
        campaign._validate_generic_result_frame(
            baseline,
            expected_mode="direct-baseline",
        )

        view_values = {
            name: getattr(terminal.view, name).hex()
            for name in campaign._VIEW_DIGEST_FIELDS
        }
        direct = {
            "schema": campaign.DIRECT_RESULT_SCHEMA,
            "mode": "direct-terminal",
            "pid": 2,
            "disposition": "advanced",
            "receipt_input_generation": 1,
            "receipt_input_sequence": 1,
            "receipt_output_generation": 2,
            "receipt_output_sequence": 1,
            "receipt_output_token": terminal.view.output_token,
            "receipt_checkpoint_sha256": view_values["selected_set_sha256"],
            "receipt_checkpoint_selector_sha256": view_values[
                "selected_selector_sha256"
            ],
            "receipt_terminal_source_contract_sha256": view_values[
                "terminal_source_contract_sha256"
            ],
            "receipt_terminal_semantic_sha256": view_values["terminal_semantic_sha256"],
            "ownership_zero": True,
            "view_abi": campaign.DIRECT_VIEW_ABI,
            "terminal": True,
            "generation": 2,
            "request_epoch": (terminal.generation_one.contract.request_epoch),
            "publication_next_sequence": 1,
            "acknowledgement_count": 0,
            "token_count": 1,
            "output_token": terminal.view.output_token,
            **view_values,
            "view_sha256": terminal.view.view_sha256.hex(),
        }
        campaign._validate_direct_result_against_wire(
            direct,
            terminal,
            expected_mode="direct-terminal",
            expected_disposition="advanced",
        )
        direct["view_sha256"] = _digest("foreign-view").hex()
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "ViewV1 root",
        ):
            campaign._validate_direct_result_against_wire(
                direct,
                terminal,
                expected_mode="direct-terminal",
                expected_disposition="advanced",
            )

    def test_result_sink_namespace_is_rejected(self) -> None:
        value = _fixture()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "terminal"
            _write_fixture_directory(directory, value, terminal=True)
            terminal = campaign.inspect_terminal_directory(directory)
            (directory / ".glacier-prepared-text-result-sink-active-v1").write_bytes(
                b"forbidden"
            )
            with self.assertRaisesRegex(
                campaign.CampaignError,
                "result-sink namespace",
            ):
                campaign.assert_checkpoint_only_namespace(
                    directory,
                    terminal.selected,
                    predecessor=terminal.generation_one.checkpoint,
                )

            baseline = Path(temporary) / "baseline"
            baseline.mkdir()
            for name in recovery.BASELINE_FIXTURE_NAMES:
                (baseline / name).write_bytes(b"fixture")
            (baseline / campaign.RUNTIME_IMAGE_PUBLICATION_LOCK_NAME).write_bytes(b"")
            campaign.assert_fixture_only_namespace(baseline)
            (baseline / "prepared-text-result-ledger-forbidden.bin").write_bytes(
                b"forbidden"
            )
            with self.assertRaisesRegex(
                campaign.CampaignError,
                "result-sink namespace",
            ):
                campaign.assert_fixture_only_namespace(baseline)


if __name__ == "__main__":
    unittest.main()
