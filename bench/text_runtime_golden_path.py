"""Composed raw-text fixture for conversion, preparation, and SessionV3."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path
from typing import Mapping, Sequence

from bench import model_contract as contract
from bench import prepared_text_direct_terminal_recovery as direct_oracle
from bench import prepared_text_package as package_oracle
from bench import prepared_text_raw_input as raw_input


EXPECTED_SOURCE_SHA256 = (
    "3bbf8d6647660c3b848bcc18fc45365555b55e3d9e887cb05a2823182f87dd45"
)
EXPECTED_GLACIER_SHA256 = (
    "64b46e86672b3bc5fa17df8cc9c0771399a90a402f2c8d077ac71130b7778930"
)
EXPECTED_PREPARED_SOURCE_FINGERPRINT = (
    "853fd0c24d0c5a847417292afe09e29847c7ef72070e2a6fd6408a90677cf747"
)
EXPECTED_LICENSE_SHA256 = (
    "43c3afa81d9ea0ffdde3293b4dcc0f8d17e2a0fb76b7d2d8ff8a841fd56f5888"
)
PROMPT = "Ice"
NEW_TOKENS = 3
DURABLE_REQUEST_ID = "18c4d5a16c7f7a5df70c6c7d4e6f6dd1" * 2
DURABLE_MAX_SET_BYTES = 8 * 1024 * 1024
TIMEOUT_SECONDS = 30


class GoldenPathError(RuntimeError):
    """A command or independent identity check failed."""


def _redacted_command(command: Sequence[str]) -> tuple[str, ...]:
    redacted = list(command)
    for index, argument in enumerate(redacted[:-1]):
        if argument == "--text":
            redacted[index + 1] = "<redacted>"
    return tuple(redacted)


def _run(
    command: Sequence[str],
    *,
    expect_success: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
    )
    if expect_success != (result.returncode == 0):
        raise GoldenPathError(
            f"unexpected exit {result.returncode}: "
            f"{_redacted_command(command)!r}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _field(output: str, name: str) -> str:
    match = re.search(rf"(?m)^  {re.escape(name)}=([0-9a-f]{{64}})$", output)
    if match is None:
        raise GoldenPathError(f"missing {name}")
    return match.group(1)


def _run_text(
    executable: Path,
    image: Path,
    license_path: Path,
    text: str,
    prompt_path: Path,
    *,
    package_path: Path | None = None,
) -> dict[str, object]:
    prompt_path.write_bytes(text.encode("utf-8", "strict"))
    command = [
        str(executable),
        "text-run",
        str(image),
        "--text-file",
        str(prompt_path),
        "--license",
        str(license_path),
        "--n",
        str(NEW_TOKENS),
    ]
    if package_path is not None:
        command.extend(("--package", str(package_path)))
    result = _run(command)
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GoldenPathError("text-run did not emit one JSON value") from error
    if not isinstance(report, dict):
        raise GoldenPathError("text-run report is not an object")
    return report


def _run_durable_text(
    executable: Path,
    image: Path,
    package_path: Path,
    license_path: Path,
    prompt_path: Path,
    durable_directory: Path,
    *,
    request_id: str = DURABLE_REQUEST_ID,
    new_tokens: int = 1,
    max_set_bytes: int = DURABLE_MAX_SET_BYTES,
    bootstrap_only: bool = False,
    reveal_output: bool = False,
    expect_success: bool = True,
    expected_error: str | None = None,
) -> dict[str, object] | None:
    command = [
        str(executable),
        "text-run",
        str(image),
        "--text-file",
        str(prompt_path),
        "--license",
        str(license_path),
        "--package",
        str(package_path),
        "--n",
        str(new_tokens),
        "--durable-dir",
        str(durable_directory),
        "--request-id",
        request_id,
        "--max-set-bytes",
        str(max_set_bytes),
    ]
    if bootstrap_only:
        command.append("--bootstrap-only")
    if reveal_output:
        command.append("--reveal-output")
    result = _run(command, expect_success=expect_success)
    if not expect_success:
        if expected_error is not None and expected_error not in result.stderr:
            raise GoldenPathError(
                f"durable rejection omitted {expected_error}: "
                f"{result.stderr!r}"
            )
        return None
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GoldenPathError(
            "durable text-run did not emit one JSON value"
        ) from error
    if not isinstance(report, dict):
        raise GoldenPathError("durable text-run report is not an object")
    return report


def _durable_directory_manifest(
    directory: Path,
) -> tuple[tuple[str, int, int, str], ...]:
    manifest = []
    for entry in sorted(directory.iterdir(), key=lambda value: value.name):
        if entry.is_symlink() or not entry.is_file():
            raise GoldenPathError(
                f"unsafe durable state entry: {entry.name}"
            )
        metadata = entry.stat(follow_symlinks=False)
        manifest.append(
            (
                entry.name,
                metadata.st_mode & 0o7777,
                metadata.st_size,
                hashlib.sha256(entry.read_bytes()).hexdigest(),
            )
        )
    return tuple(manifest)


def _active_checkpoint(directory: Path) -> direct_oracle.recovery.CheckpointWireFacts:
    checkpoint = direct_oracle.recovery._decode_checkpoint_wire(directory)
    if checkpoint is None:
        raise GoldenPathError("durable checkpoint is absent")
    return checkpoint


def _direct_terminal_facts(
    directory: Path,
) -> direct_oracle.DirectTerminalWireFacts:
    facts = direct_oracle._decode_generation_two(
        _active_checkpoint(directory)
    )
    predecessor_name = (
        "checkpoint-"
        + facts.generation_one.checkpoint.checkpoint_sha256
        + ".set"
    )
    predecessor_path = directory / predecessor_name
    if (
        not predecessor_path.is_file()
        or predecessor_path.is_symlink()
        or predecessor_path.read_bytes()
        != facts.selected.objects[1].payload
    ):
        raise GoldenPathError(
            "durable predecessor archive differs from embedded lineage"
        )
    return facts


def _verify_durable_bootstrap_report(
    report: Mapping[str, object],
    facts: direct_oracle.DirectGenerationOneFacts,
    *,
    package_sha256: bytes,
    representation_sha256: str,
    selection_before: str,
    bootstrap_disposition: str,
) -> None:
    expected: dict[str, object] = {
        "schema": "glacier.prepared-text-durable-run/v1",
        "operation": "bootstrap",
        "profile": "ordinary-package-direct-terminal-v1",
        "route": "direct-terminal",
        "selection_before": selection_before,
        "bootstrap_disposition": bootstrap_disposition,
        "durable_checkpoint": True,
        "fresh_process_boundary_ready": True,
        "checked_committed_output": False,
        "terminal": False,
        "ownership_closed": True,
        "request_epoch": facts.contract.request_epoch,
        "generation": 1,
        "publication_next_sequence": 1,
        "max_set_bytes": DURABLE_MAX_SET_BYTES,
        "request_id_sha256": hashlib.sha256(
            bytes.fromhex(DURABLE_REQUEST_ID)
        ).hexdigest(),
        "package_sha256": package_sha256.hex(),
        "representation_sha256": representation_sha256,
        "challenge_sha256": facts.contract.challenge_sha256.hex(),
        "checkpoint_set_sha256": facts.checkpoint.checkpoint_sha256,
        "checkpoint_selector_sha256": facts.checkpoint.selector_sha256,
        "terminal_source_contract_sha256": (
            facts.contract.contract_sha256.hex()
        ),
        "input_archive_sha256": facts.input.archive_sha256.hex(),
    }
    if (
        facts.input.package_sha256 != package_sha256
        or facts.input.representation_sha256.hex()
        != representation_sha256
        or dict(report) != expected
    ):
        raise GoldenPathError(
            "durable bootstrap report or archived lineage mismatch"
        )


def _verify_durable_terminal_report(
    report: Mapping[str, object],
    facts: direct_oracle.DirectTerminalWireFacts,
    *,
    package_sha256: bytes,
    representation_sha256: str,
    selection_before: str,
    disposition: str,
    bootstrap_disposition: str | None,
    output_disclosed: bool,
) -> None:
    view = facts.view
    expected_scalars: dict[str, object] = {
        "schema": "glacier.prepared-text-durable-run/v1",
        "operation": "advance",
        "profile": "ordinary-package-direct-terminal-v1",
        "route": "direct-terminal",
        "selection_before": selection_before,
        "disposition": disposition,
        "bootstrap_disposition": bootstrap_disposition,
        "durable_checkpoint": True,
        "fresh_process_continuation_supported": True,
        "preexisting_generation_continuation_performed": (
            bootstrap_disposition in {"recovered", "already_selected"}
            and disposition == "advanced"
        ),
        "checked_committed_output": True,
        "terminal": True,
        "ownership_closed": True,
        "model_execution_performed": disposition == "advanced",
        "output_disclosed": output_disclosed,
        "output_encoding": "token-ids",
        "request_epoch": facts.generation_one.contract.request_epoch,
        "generation": 2,
        "publication_next_sequence": 1,
        "acknowledgement_count": 0,
        "token_count": 1,
        "max_set_bytes": DURABLE_MAX_SET_BYTES,
        "request_id_sha256": hashlib.sha256(
            bytes.fromhex(DURABLE_REQUEST_ID)
        ).hexdigest(),
        "package_sha256": package_sha256.hex(),
        "representation_sha256": representation_sha256,
        "input_archive_sha256": view.input_archive_sha256.hex(),
        "terminal_source_contract_sha256": (
            view.terminal_source_contract_sha256.hex()
        ),
        "terminal_semantic_sha256": view.terminal_semantic_sha256.hex(),
        "terminal_output_sha256": view.terminal_output_sha256.hex(),
        "terminal_state_sha256": view.terminal_state_sha256.hex(),
        "checkpoint_selector_sha256": view.selected_selector_sha256.hex(),
        "checkpoint_set_sha256": view.selected_set_sha256.hex(),
        "predecessor_selector_sha256": (
            view.predecessor_selector_sha256.hex()
        ),
        "predecessor_set_sha256": view.predecessor_set_sha256.hex(),
        "challenge_sha256": view.challenge_sha256.hex(),
        "view_sha256": view.view_sha256.hex(),
        "output_tokens": [view.output_token] if output_disclosed else None,
    }
    if dict(report) != expected_scalars:
        differing = sorted(
            name
            for name in set(report) | set(expected_scalars)
            if report.get(name) != expected_scalars.get(name)
        )
        raise GoldenPathError(
            "durable terminal report mismatch: " + ", ".join(differing)
        )


def _report_digest(report: Mapping[str, object], name: str) -> bytes:
    value = report.get(name)
    if not isinstance(value, str) or len(value) != 64:
        raise GoldenPathError(f"invalid {name}")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise GoldenPathError(f"invalid {name}") from error
    if len(decoded) != 32 or decoded == bytes(32):
        raise GoldenPathError(f"invalid {name}")
    return decoded


def _report_wire(
    report: Mapping[str, object],
    name: str,
    size: int,
) -> bytes:
    value = report.get(name)
    if not isinstance(value, str) or len(value) != size * 2:
        raise GoldenPathError(f"invalid {name}")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise GoldenPathError(f"invalid {name}") from error
    if len(decoded) != size:
        raise GoldenPathError(f"invalid {name}")
    return decoded


def _report_int(report: Mapping[str, object], name: str) -> int:
    value = report.get(name)
    if type(value) is not int or not 0 <= value <= raw_input.U64_MAX:
        raise GoldenPathError(f"invalid {name}")
    return value


def _verify_package_artifacts(
    *,
    source: Path,
    portable: Path,
    prepared: Path,
    package_path: Path,
    license_bytes: bytes,
    report: Mapping[str, object],
) -> tuple[dict[str, object], str]:
    bundle_wire = package_path.read_bytes()
    bundle_facts = package_oracle.decode_admission_bundle(bundle_wire)
    package_facts = bundle_facts["package"]
    representation_facts = bundle_facts["representation"]
    source_bytes = source.read_bytes()
    portable_bytes = portable.read_bytes()
    prepared_bytes = prepared.read_bytes()
    if len(portable_bytes) < 256 or portable_bytes[:4] != b"GLAC":
        raise GoldenPathError("invalid portable package artifact")
    (
        portable_version,
        header_size,
        metadata_offset,
        metadata_bytes,
        page_count,
    ) = struct.unpack_from("<HHQQQ", portable_bytes, 4)
    if (
        portable_version != 1
        or header_size != 256
        or metadata_offset + metadata_bytes > len(portable_bytes)
    ):
        raise GoldenPathError("invalid portable package header")
    try:
        metadata = json.loads(
            portable_bytes[metadata_offset : metadata_offset + metadata_bytes]
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GoldenPathError("invalid portable conversion metadata") from error
    if not isinstance(metadata, dict):
        raise GoldenPathError("invalid portable conversion metadata")

    portable_sha256 = hashlib.sha256(portable_bytes).digest()
    source_sha256 = hashlib.sha256(source_bytes).digest()
    config = package_facts["config"]
    expected_model_content = package_oracle.model_content_sha256(
        portable_sha256,
        config,
    )
    _, tokenizer_wire, _ = raw_input.tokenize(
        "Ice",
        vocab_size=config["vocab"],
        max_input_bytes=4096,
    )
    tokenizer_facts = raw_input.decode_manifest(tokenizer_wire)
    if (
        package_facts["family"] != 1
        or package_facts["source_format"] != 1
        or package_facts["portable_format_abi"] != 0x474C_4143_0000_0001
        or package_facts["conversion_profile_abi"] != 0x474C_4350_0000_0001
        or package_facts["conversion_plan_abi"] != 0x474C_434E_0000_0001
        or package_facts["tokenizer_manifest_abi"] != raw_input.MANIFEST_ABI
        or package_facts["tokenizer_manifest_bytes"] != raw_input.MANIFEST_BYTES
        or package_facts["source_bytes"] != len(source_bytes)
        or package_facts["portable_bytes"] != len(portable_bytes)
        or package_facts["portable_page_count"] != page_count
        or package_facts["license_bytes"] != len(license_bytes)
        or package_facts["source_sha256"] != source_sha256
        or package_facts["portable_artifact_sha256"] != portable_sha256
        or package_facts["model_content_sha256"] != expected_model_content
        or package_facts["tokenizer_config_sha256"] != tokenizer_facts["config_sha256"]
        or package_facts["tokenizer_domain_sha256"] != tokenizer_facts["domain_sha256"]
        or package_facts["tokenizer_behavior_sha256"]
        != tokenizer_facts["behavior_sha256"]
        or package_facts["license_sha256"] != hashlib.sha256(license_bytes).digest()
        or metadata.get("source_bytes") != len(source_bytes)
        or metadata.get("source_sha256") != source_sha256.hex()
        or metadata.get("num_pages") != page_count
        or metadata.get("conversion_profile_sha256")
        != package_facts["conversion_profile_sha256"].hex()
        or metadata.get("conversion_plan_sha256")
        != package_facts["conversion_plan_sha256"].hex()
    ):
        raise GoldenPathError("package/portable relation mismatch")

    if (
        len(prepared_bytes) < 512
        or prepared_bytes[:4] != b"GLRT"
        or struct.unpack_from("<H", prepared_bytes, 4)[0] != 2
        or struct.unpack_from("<Q", prepared_bytes, 40)[0] != len(prepared_bytes)
        or prepared_bytes[48:80] != expected_model_content
        or struct.unpack_from("<7I", prepared_bytes, 112)
        != tuple(config[name] for name in package_oracle.CONFIG_U32_FIELDS)
        or prepared_bytes[140] != int(config["tie_embeddings"])
        or any(prepared_bytes[141:144])
        or struct.unpack_from("<I", prepared_bytes, 144)[0] != config["rms_eps_bits"]
        or struct.unpack_from("<I", prepared_bytes, 148)[0] != config["rope_theta_bits"]
    ):
        raise GoldenPathError("package/prepared relation mismatch")
    prepared_sha256 = hashlib.sha256(prepared_bytes).digest()
    representation_wire = package_oracle.encode_prepared_representation(
        {
            "format_abi": 0x474C_5254_0000_0002,
            "format_version": 2,
            "container_bytes": len(prepared_bytes),
            "package_sha256": package_facts["package_sha256"],
            "resolved_config_sha256": package_facts["resolved_config_sha256"],
            "source_fingerprint": expected_model_content,
            "abi_fingerprint": prepared_bytes[80:112],
            "container_sha256": prepared_sha256,
        }
    )
    if (
        bundle_wire[: package_oracle.MANIFEST_BYTES]
        != package_oracle.encode_manifest(
            {
                "family": package_facts["family"],
                "source_format": package_facts["source_format"],
                "config": package_facts["config"],
                **{
                    name: package_facts[name]
                    for name in package_oracle.MANIFEST_U64_FIELDS
                },
                **{
                    name: package_facts[name]
                    for name in package_oracle.MANIFEST_DIGEST_FIELDS
                },
            }
        )
        or bundle_wire[package_oracle.MANIFEST_BYTES :] != representation_wire
        or representation_facts["container_bytes"] != len(prepared_bytes)
        or representation_facts["container_sha256"] != prepared_sha256
        or representation_facts["abi_fingerprint"] != prepared_bytes[80:112]
    ):
        raise GoldenPathError("package/prepared representation mismatch")
    representation_sha256 = representation_facts["representation_sha256"].hex()

    expected_report = {
        "schema": "glacier.model-package-producer/v1",
        "family": "autoregressive",
        "source_format": "safetensors",
        "tokenizer_profile": "utf8-byte-v1",
        "prepared_layout": "separate",
        "source_bytes": len(source_bytes),
        "portable_bytes": len(portable_bytes),
        "portable_page_count": page_count,
        "prepared_bytes": len(prepared_bytes),
        "package_bytes": package_oracle.ADMISSION_BUNDLE_BYTES,
        "package_manifest_bytes": package_oracle.MANIFEST_BYTES,
        "prepared_representation_bytes": (package_oracle.PREPARED_REPRESENTATION_BYTES),
        "license_bytes": len(license_bytes),
        "tokenizer_max_input_bytes": 4096,
        "config": {
            **{name: config[name] for name in package_oracle.CONFIG_U32_FIELDS},
            "rms_eps_bits": config["rms_eps_bits"],
            "rope_theta_bits": config["rope_theta_bits"],
            "tie_embeddings": config["tie_embeddings"],
        },
        "source_sha256": source_sha256.hex(),
        "portable_artifact_sha256": portable_sha256.hex(),
        "conversion_profile_sha256": package_facts["conversion_profile_sha256"].hex(),
        "conversion_plan_sha256": package_facts["conversion_plan_sha256"].hex(),
        "model_content_sha256": expected_model_content.hex(),
        "package_sha256": package_facts["package_sha256"].hex(),
        "representation_sha256": representation_sha256,
        "prepared_artifact_sha256": prepared_sha256.hex(),
        "prepared_abi_fingerprint": prepared_bytes[80:112].hex(),
        "tokenizer_domain_sha256": tokenizer_facts["domain_sha256"].hex(),
        "tokenizer_behavior_sha256": tokenizer_facts["behavior_sha256"].hex(),
        "tokenizer_config_sha256": tokenizer_facts["config_sha256"].hex(),
        "license_sha256": hashlib.sha256(license_bytes).hexdigest(),
        "request_independent": True,
        "prepared_representation_separate": False,
        "prepared_representation_embedded": True,
        "network_required": False,
        "publisher_authenticity_proven": False,
        "production_model_verified": False,
    }
    for name, expected in expected_report.items():
        if report.get(name) != expected:
            raise GoldenPathError(f"package report field {name!r} mismatch")
    return package_facts, representation_sha256


def _reroot_package(
    package_facts: Mapping[str, object],
    representation_facts: Mapping[str, object],
    digest_name: str,
) -> bytes:
    value: dict[str, object] = {
        "family": package_facts["family"],
        "source_format": package_facts["source_format"],
        "config": package_facts["config"],
    }
    for name in package_oracle.MANIFEST_U64_FIELDS:
        value[name] = package_facts[name]
    for name in package_oracle.MANIFEST_DIGEST_FIELDS:
        value[name] = package_facts[name]
    replacement = hashlib.sha256(
        b"glacier-golden-path-reroot-v1\x00" + digest_name.encode("ascii")
    ).digest()
    if replacement == value[digest_name]:
        raise GoldenPathError("reroot digest unexpectedly unchanged")
    value[digest_name] = replacement
    manifest = package_oracle.encode_manifest(value)
    rerooted_package = package_oracle.decode_manifest(manifest)
    representation = package_oracle.encode_prepared_representation(
        {
            "format_abi": representation_facts["format_abi"],
            "format_version": representation_facts["format_version"],
            "container_bytes": representation_facts["container_bytes"],
            "package_sha256": rerooted_package["package_sha256"],
            "resolved_config_sha256": rerooted_package["resolved_config_sha256"],
            "source_fingerprint": rerooted_package["model_content_sha256"],
            "abi_fingerprint": representation_facts["abi_fingerprint"],
            "container_sha256": representation_facts["container_sha256"],
        }
    )
    return package_oracle.encode_admission_bundle(
        manifest,
        representation,
    )


def _verify_report(
    report: Mapping[str, object],
    *,
    text: str,
    license_bytes: bytes,
    image: Path,
    package_facts: Mapping[str, object] | None = None,
    representation_sha256: str | None = None,
) -> None:
    tokens, manifest, prompt = raw_input.tokenize(
        text,
        vocab_size=256,
        max_input_bytes=4096,
    )
    manifest_facts = raw_input.decode_manifest(manifest)
    prompt_facts = raw_input.decode_prompt(prompt)
    expected = {
        "schema": "glacier.prepared-text-raw-run/v1",
        "profile": "utf8-byte-v1",
        "model_profile": (
            "ordinary-package-v1"
            if package_facts is not None
            else "retained-r1kb1-fixture-v1"
        ),
        "prompt_source": "file",
        "output_rendering": "token-ids",
        "prepared_image": True,
        "common_plan": True,
        "transactional_publication": True,
        "durable_result_sink": False,
        "fresh_process_recovery": False,
        "production_model": False,
        "package_admission": package_facts is not None,
        "user_supplied_model": package_facts is not None,
        "retained_fixture_profile_verified": package_facts is None,
        "prompt_hashes_are_anonymized": False,
        "replay_safe": False,
        "boundary_snapshot_independently_verified": False,
        "publication_transcript_replayed": False,
        "prompt_bytes": len(text.encode("utf-8")),
        "prompt_tokens": len(tokens),
        "tokenizer_vocab_size": 256,
        "tokenizer_max_input_bytes": 4096,
        "tokenizer_domain_sha256": raw_input.tokenizer_domain_sha256().hex(),
        "tokenizer_behavior_sha256": (raw_input.tokenizer_behavior_sha256().hex()),
        "tokenizer_config_sha256": manifest_facts["config_sha256"].hex(),
        "prompt_receipt_sha256": prompt_facts["receipt_sha256"].hex(),
        "raw_text_sha256": prompt_facts["raw_text_sha256"].hex(),
        "token_ids_sha256": prompt_facts["token_ids_sha256"].hex(),
        "prepared_prompt_sha256": raw_input.prepared_prompt_sha256(tokens).hex(),
        "prepared_image_sha256": _file_sha256(image),
        "prepared_source_fingerprint": (
            package_facts["model_content_sha256"].hex()
            if package_facts is not None
            else EXPECTED_PREPARED_SOURCE_FINGERPRINT
        ),
        "package_sha256": (
            package_facts["package_sha256"].hex() if package_facts is not None else None
        ),
        "representation_sha256": representation_sha256,
        "artifact_license_sha256": hashlib.sha256(license_bytes).hexdigest(),
        "final_bank_host_bytes": 0,
        "runtime_self_verified": True,
    }
    for name, value in expected.items():
        if type(report.get(name)) is not type(value) or report.get(name) != value:
            raise GoldenPathError(
                f"report field {name!r}: {report.get(name)!r} != {value!r}"
            )
    output_tokens = report.get("output_tokens")
    if (
        not isinstance(output_tokens, list)
        or len(output_tokens) != NEW_TOKENS
        or any(
            type(token) is not int or not 0 <= token < 256 for token in output_tokens
        )
    ):
        raise GoldenPathError("invalid output token list")

    if (
        _report_wire(
            report,
            "tokenizer_manifest_wire_hex",
            raw_input.MANIFEST_BYTES,
        )
        != manifest
        or _report_wire(
            report,
            "prompt_receipt_wire_hex",
            raw_input.PROMPT_BYTES,
        )
        != prompt
    ):
        raise GoldenPathError("tokenizer wire mismatch")

    binding_wire = _report_wire(
        report,
        "raw_input_binding_wire_hex",
        raw_input.BINDING_BYTES,
    )
    binding = raw_input.decode_binding(binding_wire)
    if binding_wire != raw_input.binding_wire_from_report(report) or binding[
        "binding_sha256"
    ] != _report_digest(report, "raw_input_binding_sha256"):
        raise GoldenPathError("raw-input binding mismatch")

    artifact = contract.decode_artifact(
        _report_wire(
            report,
            "artifact_manifest_wire_hex",
            contract.ARTIFACT_MANIFEST_BYTES,
        )
    )
    plan = contract.decode_plan(
        _report_wire(
            report,
            "execution_plan_wire_hex",
            contract.EXECUTION_PLAN_BYTES,
        )
    )
    residency = contract.decode_residency_binding(
        _report_wire(
            report,
            "residency_binding_wire_hex",
            contract.EXECUTION_RESIDENCY_BINDING_BYTES,
        )
    )
    result = contract.decode_result(
        _report_wire(
            report,
            "result_envelope_wire_hex",
            contract.RESULT_ENVELOPE_BYTES,
        )
    )
    contract.verify_residency_relationships(
        artifact,
        plan,
        residency,
        result,
    )
    root_fields = (
        ("artifact_sha256", artifact["artifact_sha256"]),
        ("execution_plan_sha256", plan["plan_sha256"]),
        ("residency_binding_sha256", residency["binding_sha256"]),
        ("result_envelope_sha256", result["result_sha256"]),
    )
    for name, value in root_fields:
        if _report_digest(report, name) != value:
            raise GoldenPathError(f"{name} wire root mismatch")
    image_sha256 = bytes.fromhex(_file_sha256(image))
    license_sha256 = hashlib.sha256(license_bytes).digest()
    prepared_image_bytes = _report_int(report, "prepared_image_bytes")
    local_max_new_tokens = _report_int(report, "local_plan_max_new_tokens")
    if (
        artifact["weights_sha256"] != image_sha256
        or artifact["weight_bytes"] != image.stat().st_size
        or prepared_image_bytes != artifact["weight_bytes"]
        or artifact["license_sha256"] != license_sha256
        or local_max_new_tokens != artifact["output_dimensions"]
        or local_max_new_tokens != plan["output_dimensions"]
        or local_max_new_tokens != result["output_dimensions"]
        or len(output_tokens) != local_max_new_tokens
        or plan["maximum_absolute_output"] != manifest_facts["vocab_size"] - 1
        or any(token > plan["maximum_absolute_output"] for token in output_tokens)
        or plan["processor_state_sha256"] != raw_input.tokenizer_domain_sha256()
        or plan["processor_bundle_sha256"] != manifest_facts["config_sha256"]
        or plan["media_object_sha256"] != raw_input.prepared_prompt_sha256(tokens)
        or plan["challenge_sha256"] != prompt_facts["receipt_sha256"]
        or plan["request_epoch"] != report.get("request_epoch")
    ):
        raise GoldenPathError("Common contract context mismatch")

    claim = report.get("local_claim")
    if not isinstance(claim, dict) or claim != residency["request_claim"]:
        raise GoldenPathError("local claim mismatch")
    local_plan_root = raw_input.local_plan_sha256(
        source_fingerprint=_report_digest(report, "prepared_source_fingerprint"),
        abi_fingerprint=_report_digest(report, "prepared_abi_fingerprint"),
        container_bytes=prepared_image_bytes,
        container_sha256=image_sha256,
        prompt_tokens=len(tokens),
        prompt_sha256=raw_input.prepared_prompt_sha256(tokens),
        max_new_tokens=local_max_new_tokens,
        eos_token=_report_int(report, "local_plan_eos_token"),
        seed=_report_int(report, "local_plan_seed"),
        claim=claim,
    )
    if local_plan_root != _report_digest(report, "local_plan_sha256"):
        raise GoldenPathError("local plan root mismatch")
    bound_plan_root = raw_input.bound_plan_sha256(
        local_plan_sha256=local_plan_root,
        artifact_sha256=artifact["artifact_sha256"],
        execution_plan_sha256=plan["plan_sha256"],
        residency_binding_sha256=residency["binding_sha256"],
        tokenizer_domain_sha256=raw_input.tokenizer_domain_sha256(),
        tokenizer_config_sha256=manifest_facts["config_sha256"],
        artifact_license_sha256=license_sha256,
    )
    if bound_plan_root != _report_digest(report, "bound_plan_sha256"):
        raise GoldenPathError("bound plan root mismatch")

    output_root = contract.prepared_terminal_output_root_v1(
        plan["plan_sha256"],
        raw_input.tokenizer_domain_sha256(),
        manifest_facts["config_sha256"],
        output_tokens,
    )
    if output_root != result["output_sha256"] or output_root != _report_digest(
        report, "output_sha256"
    ):
        raise GoldenPathError("terminal output root mismatch")
    source_mapping_root = contract.prepared_terminal_source_mapping_root_v1(
        bound_plan_root,
        _report_digest(report, "boundary_sha256"),
        _report_digest(report, "last_sink_transcript_sha256"),
        output_root,
        len(output_tokens),
    )
    if source_mapping_root != result["source_mapping_sha256"]:
        raise GoldenPathError("terminal source mapping mismatch")
    adapter_root = contract.prepared_terminal_adapter_root_v1(
        plan,
        artifact["metadata_sha256"],
        _report_digest(report, "prepared_source_fingerprint"),
        _report_digest(report, "prepared_abi_fingerprint"),
    )
    if adapter_root != result["adapter_sha256"]:
        raise GoldenPathError("terminal adapter mismatch")

    publication_after = {
        "request_epoch": _report_int(report, "publication_state_after_request_epoch"),
        "next_sequence": _report_int(report, "publication_state_after_next_sequence"),
        "visible_results": _report_int(
            report, "publication_state_after_visible_results"
        ),
        "artifact_sha256": artifact["artifact_sha256"],
        "previous_result_sha256": _report_digest(
            report,
            "publication_state_after_previous_result_sha256",
        ),
    }
    publication_sequence = result["publication_sequence"]
    if (
        publication_sequence == raw_input.U64_MAX
        or publication_after["request_epoch"] != result["request_epoch"]
        or publication_after["next_sequence"] != publication_sequence + 1
        or publication_after["visible_results"] != publication_sequence + 1
        or publication_after["previous_result_sha256"] != result["result_sha256"]
    ):
        raise GoldenPathError("terminal publication successor mismatch")
    publication_after_root = contract.publication_state_root(publication_after)
    if publication_after_root != _report_digest(
        report,
        "publication_state_after_sha256",
    ):
        raise GoldenPathError("terminal publication state mismatch")
    evidence_root = contract.prepared_terminal_result_evidence_root_v1(
        contract.PREPARED_TERMINAL_RESULT_EVIDENCE_ABI,
        _report_digest(report, "boundary_sha256"),
        result["result_sha256"],
        publication_after_root,
    )
    if evidence_root != _report_digest(report, "result_evidence_sha256"):
        raise GoldenPathError("terminal evidence root mismatch")


def run_golden_path(executable: Path, license_path: Path) -> dict[str, object]:
    executable = executable.resolve(strict=True)
    license_path = license_path.resolve(strict=True)
    license_bytes = license_path.read_bytes()
    if not license_bytes:
        raise GoldenPathError("empty license")
    if hashlib.sha256(license_bytes).hexdigest() != EXPECTED_LICENSE_SHA256:
        raise GoldenPathError("retained fixture license identity drift")

    with tempfile.TemporaryDirectory(prefix="glacier-r1kb-") as directory:
        root = Path(directory)
        source = root / "model.safetensors"
        container = root / "model.glacier"
        image = root / "model.glrt"
        prompt_path = root / "prompt.txt"

        _run(
            (
                str(executable),
                "gen-fixture",
                str(source),
                "--dim",
                "32",
                "--hidden",
                "32",
                "--layers",
                "1",
                "--vocab",
                "256",
            )
        )
        if _file_sha256(source) != EXPECTED_SOURCE_SHA256:
            raise GoldenPathError("redistributable source fixture drift")

        conversion = _run(
            (
                str(executable),
                "convert",
                "--int4",
                "--group-size",
                "16",
                str(source),
                str(container),
            )
        )
        if "ok: published" not in conversion.stdout:
            raise GoldenPathError("first conversion did not publish")
        if (
            _field(conversion.stdout, "source_sha256") != EXPECTED_SOURCE_SHA256
            or _field(conversion.stdout, "artifact_sha256") != EXPECTED_GLACIER_SHA256
            or _file_sha256(container) != EXPECTED_GLACIER_SHA256
        ):
            raise GoldenPathError("portable artifact identity drift")

        _run((str(executable), "prepare", str(container), str(image)))
        prepared_artifact_sha256 = _file_sha256(image)
        first = _run_text(
            executable,
            image,
            license_path,
            PROMPT,
            prompt_path,
        )
        _verify_report(
            first,
            text=PROMPT,
            license_bytes=license_bytes,
            image=image,
        )

        conversion_retry = _run(
            (
                str(executable),
                "convert",
                "--int4",
                "--group-size",
                "16",
                str(source),
                str(container),
            )
        )
        if "ok: already_current" not in conversion_retry.stdout:
            raise GoldenPathError("conversion retry was not idempotent")
        _run((str(executable), "prepare", str(container), str(image)))
        if _file_sha256(image) != prepared_artifact_sha256:
            raise GoldenPathError("same-platform prepared artifact drift")
        second = _run_text(
            executable,
            image,
            license_path,
            PROMPT,
            prompt_path,
        )
        if first != second:
            raise GoldenPathError("identical fresh invocation was not deterministic")

        changed_prompt = _run_text(
            executable,
            image,
            license_path,
            PROMPT + "!",
            prompt_path,
        )
        _verify_report(
            changed_prompt,
            text=PROMPT + "!",
            license_bytes=license_bytes,
            image=image,
        )
        for name in (
            "tokenizer_config_sha256",
            "prepared_image_sha256",
            "artifact_license_sha256",
        ):
            if changed_prompt[name] != first[name]:
                raise GoldenPathError(f"prompt changed stable {name}")
        for name in (
            "prompt_receipt_sha256",
            "raw_text_sha256",
            "token_ids_sha256",
            "prepared_prompt_sha256",
            "local_plan_sha256",
            "bound_plan_sha256",
            "raw_input_binding_sha256",
            "artifact_sha256",
            "execution_plan_sha256",
        ):
            if changed_prompt[name] == first[name]:
                raise GoldenPathError(f"prompt failed to change {name}")

        changed_license_path = root / "changed-license.txt"
        changed_license_bytes = license_bytes + b"\nfixture-license-mutation\n"
        changed_license_path.write_bytes(changed_license_bytes)
        prompt_path.write_bytes(PROMPT.encode("utf-8"))
        _run(
            (
                str(executable),
                "text-run",
                str(image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(changed_license_path),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        ordinary_source = root / "ordinary.safetensors"
        foreign_container = root / "foreign.glacier"
        foreign_image = root / "foreign.glrt"
        foreign_package = root / "foreign.glpkg"
        _run(
            (
                str(executable),
                "gen-fixture",
                str(ordinary_source),
                "--dim",
                "32",
                "--hidden",
                "64",
                "--layers",
                "1",
                "--vocab",
                "256",
            )
        )
        package_result = _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(foreign_container),
                str(foreign_image),
                str(foreign_package),
                "--license",
                str(license_path),
                "--group-size",
                "16",
            )
        )
        try:
            package_report = json.loads(package_result.stdout)
        except json.JSONDecodeError as error:
            raise GoldenPathError(
                "package-model did not emit one JSON value"
            ) from error
        if not isinstance(package_report, dict):
            raise GoldenPathError("package-model report is not an object")
        package_facts, representation_sha256 = _verify_package_artifacts(
            source=ordinary_source,
            portable=foreign_container,
            prepared=foreign_image,
            package_path=foreign_package,
            license_bytes=license_bytes,
            report=package_report,
        )
        if (
            package_report.get("conversion_disposition") != "published"
            or package_report.get("package_disposition") != "published"
        ):
            raise GoldenPathError("first package publication was not new")

        first_package_wire = foreign_package.read_bytes()
        first_bundle_facts = package_oracle.decode_admission_bundle(
            first_package_wire
        )
        representation_facts = first_bundle_facts["representation"]
        same_package_modified_image = root / "same-package-modified.glrt"
        modified_image_wire = bytearray(foreign_image.read_bytes())
        modified_image_wire.extend(bytes(64))
        struct.pack_into("<Q", modified_image_wire, 40, len(modified_image_wire))
        struct.pack_into("<I", modified_image_wire, 156, 0)
        struct.pack_into(
            "<I",
            modified_image_wire,
            156,
            zlib.crc32(modified_image_wire[:512]),
        )
        modified_image_sha256 = hashlib.sha256(modified_image_wire).digest()
        if (
            modified_image_wire[48:112] != foreign_image.read_bytes()[48:112]
            or modified_image_sha256
            == representation_facts["container_sha256"]
        ):
            raise GoldenPathError(
                "same-package image mutation did not preserve provenance"
            )
        same_package_modified_image.write_bytes(modified_image_wire)
        modified_representation_wire = (
            package_oracle.encode_prepared_representation(
                {
                    "format_abi": representation_facts["format_abi"],
                    "format_version": representation_facts["format_version"],
                    "container_bytes": len(modified_image_wire),
                    "package_sha256": package_facts["package_sha256"],
                    "resolved_config_sha256": package_facts[
                        "resolved_config_sha256"
                    ],
                    "source_fingerprint": package_facts[
                        "model_content_sha256"
                    ],
                    "abi_fingerprint": representation_facts[
                        "abi_fingerprint"
                    ],
                    "container_sha256": modified_image_sha256,
                }
            )
        )
        modified_bundle_path = root / "same-package-modified.glpkg"
        modified_bundle_path.write_bytes(
            package_oracle.encode_admission_bundle(
                first_package_wire[: package_oracle.MANIFEST_BYTES],
                modified_representation_wire,
            )
        )
        modified_representation_facts = (
            package_oracle.decode_prepared_representation(
                modified_representation_wire
            )
        )

        ordinary_report = _run_text(
            executable,
            foreign_image,
            license_path,
            PROMPT,
            prompt_path,
            package_path=foreign_package,
        )
        _verify_report(
            ordinary_report,
            text=PROMPT,
            license_bytes=license_bytes,
            image=foreign_image,
            package_facts=package_facts,
            representation_sha256=representation_sha256,
        )
        modified_report = _run_text(
            executable,
            same_package_modified_image,
            license_path,
            PROMPT,
            prompt_path,
            package_path=modified_bundle_path,
        )
        _verify_report(
            modified_report,
            text=PROMPT,
            license_bytes=license_bytes,
            image=same_package_modified_image,
            package_facts=package_facts,
            representation_sha256=modified_representation_facts[
                "representation_sha256"
            ].hex(),
        )

        different_container = root / "different-package.glacier"
        different_image = root / "different-package.glrt"
        different_package = root / "different-package.glpkg"
        different_result = _run(
            (
                str(executable),
                "package-model",
                str(source),
                str(different_container),
                str(different_image),
                str(different_package),
                "--license",
                str(license_path),
                "--group-size",
                "16",
            )
        )
        try:
            different_package_report = json.loads(different_result.stdout)
        except json.JSONDecodeError as error:
            raise GoldenPathError(
                "different package did not emit one JSON value"
            ) from error
        if not isinstance(different_package_report, dict):
            raise GoldenPathError("different package report is not an object")
        different_package_facts, different_representation_sha256 = (
            _verify_package_artifacts(
                source=source,
                portable=different_container,
                prepared=different_image,
                package_path=different_package,
                license_bytes=license_bytes,
                report=different_package_report,
            )
        )
        different_report = _run_text(
            executable,
            different_image,
            license_path,
            PROMPT,
            prompt_path,
            package_path=different_package,
        )
        _verify_report(
            different_report,
            text=PROMPT,
            license_bytes=license_bytes,
            image=different_image,
            package_facts=different_package_facts,
            representation_sha256=different_representation_sha256,
        )
        if (
            different_package_facts["package_sha256"]
            == package_facts["package_sha256"]
        ):
            raise GoldenPathError("different package root unexpectedly matched")

        # The durable direct-terminal slice deliberately stages generation
        # one in one process and resumes it in another. Both the writer receipt
        # and the final user-visible result are then checked against an
        # independent decoder of the selected filesystem wires.
        durable_directory = root / "durable-direct-terminal"
        durable_directory.mkdir(mode=0o700)
        prompt_path.write_bytes(PROMPT.encode("utf-8"))
        bootstrap_report = _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory,
            bootstrap_only=True,
        )
        if bootstrap_report is None:
            raise GoldenPathError("durable bootstrap report is absent")
        generation_one = direct_oracle._decode_generation_one(
            _active_checkpoint(durable_directory)
        )
        _verify_durable_bootstrap_report(
            bootstrap_report,
            generation_one,
            package_sha256=package_facts["package_sha256"],
            representation_sha256=representation_sha256,
            selection_before="absent",
            bootstrap_disposition="created",
        )
        source_manifest = _durable_directory_manifest(durable_directory)
        bootstrap_retry_report = _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory,
            bootstrap_only=True,
        )
        if bootstrap_retry_report is None:
            raise GoldenPathError("durable bootstrap retry report is absent")
        bootstrap_retry_facts = direct_oracle._decode_generation_one(
            _active_checkpoint(durable_directory)
        )
        _verify_durable_bootstrap_report(
            bootstrap_retry_report,
            bootstrap_retry_facts,
            package_sha256=package_facts["package_sha256"],
            representation_sha256=representation_sha256,
            selection_before="source-live",
            bootstrap_disposition="already_selected",
        )
        if (
            bootstrap_retry_facts != generation_one
            or _durable_directory_manifest(durable_directory)
            != source_manifest
        ):
            raise GoldenPathError(
                "durable bootstrap retry changed generation one"
            )

        prompt_path.write_bytes((PROMPT + "!").encode("utf-8"))
        _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory,
            expect_success=False,
            expected_error="DurableRequestMismatch",
        )
        prompt_path.write_bytes(PROMPT.encode("utf-8"))
        _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory,
            request_id="ab" * 32,
            expect_success=False,
            expected_error="DurableRequestMismatch",
        )
        _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            changed_license_path,
            prompt_path,
            durable_directory,
            expect_success=False,
        )
        _run_durable_text(
            executable,
            different_image,
            different_package,
            license_path,
            prompt_path,
            durable_directory,
            expect_success=False,
            expected_error="DurableRequestMismatch",
        )
        _run_durable_text(
            executable,
            same_package_modified_image,
            modified_bundle_path,
            license_path,
            prompt_path,
            durable_directory,
            expect_success=False,
            expected_error="DurableRequestMismatch",
        )
        for invalid_options in (
            {"new_tokens": 2},
            {"request_id": DURABLE_REQUEST_ID.upper()},
            {"max_set_bytes": 0},
            {"max_set_bytes": 64 * 1024 * 1024 + 1},
            {"bootstrap_only": True, "reveal_output": True},
        ):
            _run_durable_text(
                executable,
                foreign_image,
                foreign_package,
                license_path,
                prompt_path,
                durable_directory,
                expect_success=False,
                **invalid_options,
            )
        durable_directory_link = root / "durable-direct-terminal-link"
        durable_directory_link.symlink_to(
            durable_directory,
            target_is_directory=True,
        )
        _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory_link,
            expect_success=False,
        )
        if _durable_directory_manifest(durable_directory) != source_manifest:
            raise GoldenPathError(
                "foreign durable resume changed generation one"
            )

        terminal_report = _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory,
        )
        if terminal_report is None:
            raise GoldenPathError("durable terminal report is absent")
        terminal_facts = _direct_terminal_facts(durable_directory)
        _verify_durable_terminal_report(
            terminal_report,
            terminal_facts,
            package_sha256=package_facts["package_sha256"],
            representation_sha256=representation_sha256,
            selection_before="source-live",
            disposition="advanced",
            bootstrap_disposition="already_selected",
            output_disclosed=False,
        )
        ordinary_output_tokens = ordinary_report.get("output_tokens")
        if (
            not isinstance(ordinary_output_tokens, list)
            or not ordinary_output_tokens
            or terminal_facts.view.output_token != ordinary_output_tokens[0]
        ):
            raise GoldenPathError(
                "durable output differs from ordinary execution"
            )
        terminal_manifest = _durable_directory_manifest(
            durable_directory
        )
        expected_terminal_names = {
            direct_oracle.CHECKPOINT_LOCK_NAME,
            direct_oracle.recovery.CHECKPOINT_ACTIVE_SELECTOR_NAME,
            (
                "checkpoint-"
                + terminal_facts.generation_one.checkpoint.checkpoint_sha256
                + ".set"
            ),
            "checkpoint-" + terminal_facts.selected.checkpoint_sha256 + ".set",
        }
        if {entry[0] for entry in terminal_manifest} != expected_terminal_names:
            raise GoldenPathError(
                "direct durable state contains an unexpected namespace"
            )

        retry_report = _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            durable_directory,
            reveal_output=True,
        )
        if retry_report is None:
            raise GoldenPathError("durable terminal retry report is absent")
        retry_facts = _direct_terminal_facts(durable_directory)
        _verify_durable_terminal_report(
            retry_report,
            retry_facts,
            package_sha256=package_facts["package_sha256"],
            representation_sha256=representation_sha256,
            selection_before="terminal",
            disposition="already_selected",
            bootstrap_disposition=None,
            output_disclosed=True,
        )
        if (
            retry_facts != terminal_facts
            or _durable_directory_manifest(durable_directory)
            != terminal_manifest
        ):
            raise GoldenPathError(
                "fresh terminal retry changed durable state"
            )

        one_shot_directory = root / "durable-direct-terminal-one-shot"
        one_shot_directory.mkdir(mode=0o700)
        one_shot_report = _run_durable_text(
            executable,
            foreign_image,
            foreign_package,
            license_path,
            prompt_path,
            one_shot_directory,
            reveal_output=True,
        )
        if one_shot_report is None:
            raise GoldenPathError("durable one-shot report is absent")
        one_shot_facts = _direct_terminal_facts(one_shot_directory)
        _verify_durable_terminal_report(
            one_shot_report,
            one_shot_facts,
            package_sha256=package_facts["package_sha256"],
            representation_sha256=representation_sha256,
            selection_before="absent",
            disposition="advanced",
            bootstrap_disposition="created",
            output_disclosed=True,
        )
        if one_shot_facts != terminal_facts:
            raise GoldenPathError(
                "one-shot and continued durable terminal facts differ"
            )

        retry_result = _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(foreign_container),
                str(foreign_image),
                str(foreign_package),
                "--license",
                str(license_path),
                "--group-size",
                "16",
            )
        )
        try:
            retry_report = json.loads(retry_result.stdout)
        except json.JSONDecodeError as error:
            raise GoldenPathError(
                "package-model retry did not emit one JSON value"
            ) from error
        if isinstance(retry_report, dict):
            retry_facts, retry_representation_sha256 = _verify_package_artifacts(
                source=ordinary_source,
                portable=foreign_container,
                prepared=foreign_image,
                package_path=foreign_package,
                license_bytes=license_bytes,
                report=retry_report,
            )
        else:
            retry_facts = {}
            retry_representation_sha256 = ""
        if (
            not isinstance(retry_report, dict)
            or retry_report.get("conversion_disposition") != "already_current"
            or retry_report.get("package_disposition") != "already_current"
            or foreign_package.read_bytes() != first_package_wire
            or retry_facts.get("package_sha256") != package_facts["package_sha256"]
            or retry_representation_sha256 != representation_sha256
        ):
            raise GoldenPathError("package retry was not idempotent")

        # A user-model image still requires its exact package admission.
        _run(
            (
                str(executable),
                "text-run",
                str(foreign_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        # Neither a valid package nor a valid image can be substituted alone.
        _run(
            (
                str(executable),
                "text-run",
                str(image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(foreign_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )
        _run(
            (
                str(executable),
                "text-run",
                str(foreign_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(changed_license_path),
                "--package",
                str(foreign_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        _run(
            (
                str(executable),
                "text-run",
                str(same_package_modified_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(foreign_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )
        mutated_package = root / "mutated.glpkg"
        mutated_wire = bytearray(first_package_wire)
        mutated_wire[208] ^= 1
        mutated_package.write_bytes(mutated_wire)
        _run(
            (
                str(executable),
                "text-run",
                str(foreign_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(mutated_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        rerooted_tokenizer_package = root / "rerooted-tokenizer.glpkg"
        rerooted_tokenizer_package.write_bytes(
            _reroot_package(
                package_facts,
                representation_facts,
                "tokenizer_config_sha256",
            )
        )
        _run(
            (
                str(executable),
                "text-run",
                str(foreign_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(rerooted_tokenizer_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        rerooted_model_package = root / "rerooted-model-content.glpkg"
        rerooted_model_package.write_bytes(
            _reroot_package(
                package_facts,
                representation_facts,
                "model_content_sha256",
            )
        )
        _run(
            (
                str(executable),
                "text-run",
                str(foreign_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(rerooted_model_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        symlink_image = root / "foreign-link.glrt"
        symlink_image.symlink_to(foreign_image)
        _run(
            (
                str(executable),
                "text-run",
                str(symlink_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(foreign_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )
        fifo_image = root / "foreign-fifo.glrt"
        os.mkfifo(fifo_image)
        _run(
            (
                str(executable),
                "text-run",
                str(fifo_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(foreign_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )
        directory_image = root / "foreign-directory.glrt"
        directory_image.mkdir()
        _run(
            (
                str(executable),
                "text-run",
                str(directory_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(foreign_package),
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

        conflicting_package = root / "preexisting-package.glpkg"
        conflicting_package_bytes = b"preexisting unrelated package\n"
        conflicting_package.write_bytes(conflicting_package_bytes)
        _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(root / "preexisting-package.glacier"),
                str(root / "preexisting-package.glrt"),
                str(conflicting_package),
                "--license",
                str(license_path),
                "--group-size",
                "16",
            ),
            expect_success=False,
        )
        if conflicting_package.read_bytes() != conflicting_package_bytes:
            raise GoldenPathError("different pre-existing package was overwritten")

        dangling_target = root / "missing-package-target"
        dangling_package = root / "dangling-package.glpkg"
        dangling_package.symlink_to(dangling_target)
        _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(root / "dangling-package.glacier"),
                str(root / "dangling-package.glrt"),
                str(dangling_package),
                "--license",
                str(license_path),
                "--group-size",
                "16",
            ),
            expect_success=False,
        )
        if (
            not dangling_package.is_symlink()
            or dangling_package.readlink() != dangling_target
            or dangling_target.exists()
        ):
            raise GoldenPathError("dangling package symlink was clobbered")

        publication_lock = root / ".glacier-model-package-publication.lock-v1"
        lock_descriptor = os.open(publication_lock, os.O_RDWR)
        contended_command = (
            str(executable),
            "package-model",
            str(ordinary_source),
            str(root / "contended.glacier"),
            str(root / "contended.glrt"),
            str(foreign_package),
            "--license",
            str(license_path),
            "--group-size",
            "16",
        )
        try:
            fcntl.flock(
                lock_descriptor,
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
            _run(contended_command, expect_success=False)
            if foreign_package.read_bytes() != first_package_wire:
                raise GoldenPathError("contended publication changed the package")
        finally:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
            os.close(lock_descriptor)
        contended_result = _run(contended_command)
        try:
            contended_report = json.loads(contended_result.stdout)
        except json.JSONDecodeError as error:
            raise GoldenPathError(
                "publication retry did not emit one JSON value"
            ) from error
        if (
            not isinstance(contended_report, dict)
            or contended_report.get("package_disposition") != "already_current"
            or foreign_package.read_bytes() != first_package_wire
        ):
            raise GoldenPathError("publication did not converge after contention")

        symlink_license = root / "license-link"
        symlink_license.symlink_to(license_path)
        rejected_container = root / "symlink-license.glacier"
        rejected_image = root / "symlink-license.glrt"
        rejected_package = root / "symlink-license.glpkg"
        _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(rejected_container),
                str(rejected_image),
                str(rejected_package),
                "--license",
                str(symlink_license),
            ),
            expect_success=False,
        )
        if any(
            path.exists()
            for path in (
                rejected_container,
                rejected_image,
                rejected_package,
            )
        ):
            raise GoldenPathError("rejected symlink license mutated package outputs")

        oversized_prompt = root / "oversized-prompt.txt"
        oversized_prompt.write_bytes(b"x" * 4097)
        _run(
            (
                str(executable),
                "text-run",
                str(image),
                "--text-file",
                str(oversized_prompt),
                "--license",
                str(license_path),
                "--n",
                "1",
            ),
            expect_success=False,
        )
        invalid_prompt = root / "invalid-prompt.txt"
        invalid_prompt.write_bytes(b"\xc0\xaf")
        _run(
            (
                str(executable),
                "text-run",
                str(image),
                "--text-file",
                str(invalid_prompt),
                "--license",
                str(license_path),
                "--n",
                "1",
            ),
            expect_success=False,
        )

        return {
            "schema": "glacier.text-runtime-golden-path/v1",
            "source_sha256": EXPECTED_SOURCE_SHA256,
            "portable_artifact_sha256": EXPECTED_GLACIER_SHA256,
            "prepared_artifact_sha256": prepared_artifact_sha256,
            "prepared_source_fingerprint": (EXPECTED_PREPARED_SOURCE_FINGERPRINT),
            "prepared_artifact_platform_bound": True,
            "prompt_bytes": len(PROMPT.encode("utf-8")),
            "output_tokens": NEW_TOKENS,
            "conversion_retry_idempotent": True,
            "identical_fresh_invocation_deterministic": True,
            "prompt_changes_identity": True,
            "license_substitution_rejected": True,
            "foreign_fixture_profile_rejected": True,
            "ordinary_package_produced": True,
            "ordinary_package_admitted": True,
            "ordinary_package_independently_decoded": True,
            "prepared_representation_independently_verified": True,
            "package_manifest_retry_idempotent": True,
            "cross_package_image_substitution_rejected": True,
            "same_package_modified_image_rejected": True,
            "same_package_alternate_bundle_admitted": True,
            "package_license_substitution_rejected": True,
            "package_mutation_rejected": True,
            "rerooted_tokenizer_package_rejected": True,
            "rerooted_model_content_package_rejected": True,
            "symlink_model_input_rejected": True,
            "fifo_model_input_rejected": True,
            "directory_model_input_rejected": True,
            "different_preexisting_package_preserved": True,
            "dangling_package_symlink_preserved": True,
            "competing_package_publication_rejected": True,
            "package_publication_retry_converged": True,
            "symlink_license_rejected_before_publication": True,
            "oversized_input_rejected": True,
            "invalid_utf8_rejected": True,
            "network_required": False,
            "production_model": False,
            "durable_result_sink": False,
            "durable_direct_terminal": True,
            "durable_output_count": 1,
            "fresh_process_continuation": True,
            "checked_committed_output": True,
            "durable_output_matches_ordinary": True,
            "durable_one_shot_verified": True,
            "durable_retry_idempotent": True,
            "durable_invalid_options_rejected": True,
            "durable_foreign_input_rejected": True,
            "durable_package_root_substitution_rejected": True,
            "durable_state_namespace_verified": True,
            "tokenizer_wires_independently_verified": True,
            "raw_input_binding_independently_verified": True,
            "common_contract_wires_independently_verified": True,
            "terminal_result_relationships_independently_verified": True,
            "boundary_snapshot_independently_verified": False,
            "publication_transcript_replayed": False,
            "declared_evidence_scope_verified": True,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument(
        "--license",
        type=Path,
        default=Path("LICENSE"),
    )
    arguments = parser.parse_args()
    print(
        json.dumps(
            run_golden_path(arguments.executable, arguments.license),
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
