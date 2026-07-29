"""Composed raw-text fixture for conversion, preparation, and SessionV3."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Mapping, Sequence

from bench import model_contract as contract
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
) -> dict[str, object]:
    prompt_path.write_bytes(text.encode("utf-8", "strict"))
    result = _run(
        (
            str(executable),
            "text-run",
            str(image),
            "--text-file",
            str(prompt_path),
            "--license",
            str(license_path),
            "--n",
            str(NEW_TOKENS),
        )
    )
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GoldenPathError("text-run did not emit one JSON value") from error
    if not isinstance(report, dict):
        raise GoldenPathError("text-run report is not an object")
    return report


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


def _verify_report(
    report: Mapping[str, object],
    *,
    text: str,
    license_bytes: bytes,
    image: Path,
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
        "model_profile": "retained-r1kb1-fixture-v1",
        "prompt_source": "file",
        "output_rendering": "token-ids",
        "prepared_image": True,
        "common_plan": True,
        "transactional_publication": True,
        "durable_result_sink": False,
        "fresh_process_recovery": False,
        "production_model": False,
        "retained_fixture_profile_verified": True,
        "prompt_hashes_are_anonymized": False,
        "replay_safe": False,
        "boundary_snapshot_independently_verified": False,
        "publication_transcript_replayed": False,
        "prompt_bytes": len(text.encode("utf-8")),
        "prompt_tokens": len(tokens),
        "tokenizer_vocab_size": 256,
        "tokenizer_max_input_bytes": 4096,
        "tokenizer_domain_sha256": raw_input.tokenizer_domain_sha256().hex(),
        "tokenizer_behavior_sha256": (
            raw_input.tokenizer_behavior_sha256().hex()
        ),
        "tokenizer_config_sha256": manifest_facts["config_sha256"].hex(),
        "prompt_receipt_sha256": prompt_facts["receipt_sha256"].hex(),
        "raw_text_sha256": prompt_facts["raw_text_sha256"].hex(),
        "token_ids_sha256": prompt_facts["token_ids_sha256"].hex(),
        "prepared_prompt_sha256": raw_input.prepared_prompt_sha256(tokens).hex(),
        "prepared_image_sha256": _file_sha256(image),
        "prepared_source_fingerprint": (
            EXPECTED_PREPARED_SOURCE_FINGERPRINT
        ),
        "artifact_license_sha256": hashlib.sha256(license_bytes).hexdigest(),
        "final_bank_host_bytes": 0,
        "runtime_self_verified": True,
    }
    for name, value in expected.items():
        if (
            type(report.get(name)) is not type(value)
            or report.get(name) != value
        ):
            raise GoldenPathError(
                f"report field {name!r}: {report.get(name)!r} != {value!r}"
            )
    output_tokens = report.get("output_tokens")
    if (
        not isinstance(output_tokens, list)
        or len(output_tokens) != NEW_TOKENS
        or any(
            type(token) is not int or not 0 <= token < 256
            for token in output_tokens
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
    if (
        binding_wire != raw_input.binding_wire_from_report(report)
        or binding["binding_sha256"]
        != _report_digest(report, "raw_input_binding_sha256")
    ):
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
    local_max_new_tokens = _report_int(
        report, "local_plan_max_new_tokens"
    )
    if (
        artifact["weights_sha256"] != image_sha256
        or artifact["weight_bytes"] != image.stat().st_size
        or prepared_image_bytes != artifact["weight_bytes"]
        or artifact["license_sha256"] != license_sha256
        or local_max_new_tokens != artifact["output_dimensions"]
        or local_max_new_tokens != plan["output_dimensions"]
        or local_max_new_tokens != result["output_dimensions"]
        or len(output_tokens) != local_max_new_tokens
        or plan["maximum_absolute_output"]
        != manifest_facts["vocab_size"] - 1
        or any(
            token > plan["maximum_absolute_output"]
            for token in output_tokens
        )
        or plan["processor_state_sha256"]
        != raw_input.tokenizer_domain_sha256()
        or plan["processor_bundle_sha256"]
        != manifest_facts["config_sha256"]
        or plan["media_object_sha256"]
        != raw_input.prepared_prompt_sha256(tokens)
        or plan["challenge_sha256"] != prompt_facts["receipt_sha256"]
        or plan["request_epoch"] != report.get("request_epoch")
    ):
        raise GoldenPathError("Common contract context mismatch")

    claim = report.get("local_claim")
    if not isinstance(claim, dict) or claim != residency["request_claim"]:
        raise GoldenPathError("local claim mismatch")
    local_plan_root = raw_input.local_plan_sha256(
        source_fingerprint=_report_digest(
            report, "prepared_source_fingerprint"
        ),
        abi_fingerprint=_report_digest(
            report, "prepared_abi_fingerprint"
        ),
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
    if (
        output_root != result["output_sha256"]
        or output_root != _report_digest(report, "output_sha256")
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
        "request_epoch": _report_int(
            report,
            "publication_state_after_request_epoch"
        ),
        "next_sequence": _report_int(
            report,
            "publication_state_after_next_sequence"
        ),
        "visible_results": _report_int(
            report,
            "publication_state_after_visible_results"
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
        or publication_after["previous_result_sha256"]
        != result["result_sha256"]
    ):
        raise GoldenPathError("terminal publication successor mismatch")
    publication_after_root = contract.publication_state_root(
        publication_after
    )
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
            _field(conversion.stdout, "source_sha256")
            != EXPECTED_SOURCE_SHA256
            or _field(conversion.stdout, "artifact_sha256")
            != EXPECTED_GLACIER_SHA256
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
            raise GoldenPathError(
                "identical fresh invocation was not deterministic"
            )

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

        foreign_container = root / "foreign.glacier"
        foreign_image = root / "foreign.glrt"
        _run(
            (
                str(executable),
                "convert",
                "--int4",
                "--group-size",
                "32",
                str(source),
                str(foreign_container),
            )
        )
        _run(
            (
                str(executable),
                "prepare",
                str(foreign_container),
                str(foreign_image),
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
                "--n",
                str(NEW_TOKENS),
            ),
            expect_success=False,
        )

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
            "prepared_source_fingerprint": (
                EXPECTED_PREPARED_SOURCE_FINGERPRINT
            ),
            "prepared_artifact_platform_bound": True,
            "prompt_bytes": len(PROMPT.encode("utf-8")),
            "output_tokens": NEW_TOKENS,
            "conversion_retry_idempotent": True,
            "identical_fresh_invocation_deterministic": True,
            "prompt_changes_identity": True,
            "license_substitution_rejected": True,
            "foreign_fixture_profile_rejected": True,
            "oversized_input_rejected": True,
            "invalid_utf8_rejected": True,
            "network_required": False,
            "production_model": False,
            "durable_result_sink": False,
            "fresh_process_recovery": False,
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
