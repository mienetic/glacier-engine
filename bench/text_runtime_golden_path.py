"""Composed raw-text fixture for conversion, preparation, and SessionV3."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import struct
import subprocess
import tempfile
import zlib
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import Iterator, Mapping, Sequence

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
EXPERIMENTAL_MODEL_PROFILE = "ordinary-package-v1"
MODEL_PROFILE_ABI = 0x474C_4D50_0000_0001
MODEL_PROFILE_ID = 1
MODEL_PROFILE_DOMAIN = b"glacier-model-package-profile-v1\x00"
TENSOR_PROFILE_ABI = 0x474C_5450_0000_0001
TENSOR_INVENTORY_DOMAIN = (
    b"glacier/ordinary-package/tensor-inventory/v1\x00"
)
CONVERSION_PROFILE_ABI = 0x474C_4350_0000_0001
CONVERSION_PROFILE_DOMAIN = b"glacier-model-conversion-profile-v1\x00"
CONVERSION_ARCHITECTURE = b"glacier-ordinary-package-v1"
QUANTIZED_TENSOR_KINDS = (0, 1, 2, 3, 4, 5, 6, 7, 9, 255)
PROMPT = "Ice"
NEW_TOKENS = 3
DURABLE_REQUEST_ID = "18c4d5a16c7f7a5df70c6c7d4e6f6dd1" * 2
DURABLE_MAX_SET_BYTES = 8 * 1024 * 1024
DURABLE_ACKNOWLEDGED_CHALLENGE_DOMAIN = (
    b"glacier-prepared-text-durable-cli-acknowledged-challenge-v1\x00"
)
DURABLE_RUNTIME_IDENTITY_DOMAIN = (
    b"glacier-prepared-text-durable-cli-runtime-v1\x00"
)
DURABLE_SINK_INSTANCE_IDENTITY_DOMAIN = (
    b"glacier-prepared-text-durable-cli-sink-instance-v1\x00"
)
DURABLE_SINK_IMPLEMENTATION_DOMAIN = (
    b"glacier-prepared-text-durable-cli-sink-implementation-v1\x00"
)
TERMINAL_SEMANTIC_MAGIC = b"GPTSEM1\x00"
TERMINAL_SEMANTIC_ABI = 0x4750_5453_0000_0001
TERMINAL_SEMANTIC_BYTES = 640
TERMINAL_SEMANTIC_BODY_BYTES = TERMINAL_SEMANTIC_BYTES - 32
TERMINAL_SEMANTIC_DOMAIN = (
    b"glacier-prepared-text-terminal-semantic-v1\x00"
)
TERMINAL_OUTPUT_DOMAIN = (
    b"glacier-prepared-text-terminal-output-semantic-v1\x00"
)
STATE_COMMITMENT_ABI = 0x474C_5053_0000_0001
STATE_COMMITMENT_DOMAIN = b"glacier-lane-publication-state-v1\x00"
COMPLETED_EARLY_ABI = 0x4750_5445_0000_0001
VARIABLE_TERMINAL_EVIDENCE_ABI = 0x4750_5456_0000_0001
COMPLETED_EARLY_DOMAIN = b"glacier-prepared-text-completed-early-v1\x00"
VARIABLE_TERMINAL_EVIDENCE_DOMAIN = (
    b"glacier-prepared-text-variable-terminal-evidence-v1\x00"
)
VARIABLE_TERMINAL_REPORT_KEYS = frozenset(
    {
        "schema",
        "profile",
        "model_profile",
        "prompt_source",
        "output_rendering",
        "prepared_image",
        "common_plan",
        "transactional_publication",
        "fixed_result_envelope",
        "durable_result_sink",
        "fresh_process_recovery",
        "durable_eos_supported",
        "package_admission",
        "prompt_bytes",
        "prompt_tokens",
        "tokenizer_vocab_size",
        "variable_terminal_evidence_abi",
        "completed_early_abi",
        "request_epoch",
        "max_token_count",
        "actual_token_count",
        "eos_token",
        "termination_reason",
        "unused_quanta",
        "close_event_kind",
        "close_event_sequence",
        "ownership_closed",
        "resource_bank_zero",
        "scheduler_closed",
        "package_sha256",
        "representation_sha256",
        "completed_early_sha256",
        "variable_terminal_evidence_sha256",
        "terminal_boundary_sha256",
        "terminal_semantic_sha256",
        "output_sha256",
        "final_service_event_sha256",
        "publication_transcript_sha256",
        "close_event_sha256",
        "local_plan_sha256",
        "bound_plan_sha256",
        "scheduler_challenge_sha256",
        "output_tokens",
        "runtime_self_verified",
    }
)
TIMEOUT_SECONDS = 30
COMMAND_CWD: ContextVar[Path | None] = ContextVar(
    "glacier_golden_command_cwd",
    default=None,
)
COMMAND_ENV: ContextVar[Mapping[str, str] | None] = ContextVar(
    "glacier_golden_command_env",
    default=None,
)


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
        cwd=COMMAND_CWD.get(),
        env=COMMAND_ENV.get(),
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


def _installed_tree_manifest(
    root: Path,
) -> tuple[tuple[str, str, int, int, str], ...]:
    if root.is_symlink() or not root.is_dir():
        raise GoldenPathError("installed prefix is not a stable directory")
    manifest = []
    for path in sorted(
        root.rglob("*"),
        key=lambda value: os.fsencode(value.relative_to(root).as_posix()),
    ):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISREG(metadata.st_mode):
            manifest.append(
                (relative, "file", mode, metadata.st_size, _file_sha256(path))
            )
        elif stat.S_ISDIR(metadata.st_mode):
            manifest.append((relative, "directory", mode, 0, ""))
        elif stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            manifest.append(
                (
                    relative,
                    "symlink",
                    mode,
                    len(os.fsencode(target)),
                    os.fsdecode(target),
                )
            )
        else:
            raise GoldenPathError(
                f"unsafe installed-prefix entry: {relative!r}"
            )
    return tuple(manifest)


def _tree_entries(root: Path) -> tuple[str, ...]:
    return tuple(
        path.relative_to(root).as_posix()
        for path in sorted(
            root.rglob("*"),
            key=lambda value: os.fsencode(
                value.relative_to(root).as_posix()
            ),
        )
    )


@contextmanager
def _isolated_command_state(
    working_directory: Path,
    environment: Mapping[str, str],
) -> Iterator[None]:
    cwd_token = COMMAND_CWD.set(working_directory)
    environment_token = COMMAND_ENV.set(dict(environment))
    try:
        yield
    finally:
        COMMAND_ENV.reset(environment_token)
        COMMAND_CWD.reset(cwd_token)


def _installed_clean_room_golden_path(
    executable: Path,
    license_path: Path,
) -> dict[str, object]:
    if executable.is_symlink():
        raise GoldenPathError("installed CLI must not be a symlink")
    executable = executable.resolve(strict=True)
    license_path = license_path.resolve(strict=True)
    if (
        executable.name != "glacier"
        or executable.parent.name != "bin"
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
    ):
        raise GoldenPathError(
            "golden path requires an executable installed as bin/glacier"
        )

    install_namespace = executable.parent
    install_manifest_before = _installed_tree_manifest(install_namespace)
    executable_sha256 = _file_sha256(executable)

    try:
        with tempfile.TemporaryDirectory(
            prefix="glacier-r1kb-installed-"
        ) as directory:
            clean_root = Path(directory)
            working_directory = clean_root / "cwd"
            home_directory = clean_root / "home"
            temporary_directory = clean_root / "tmp"
            config_directory = clean_root / "config"
            cache_directory = clean_root / "cache"
            for path in (
                working_directory,
                home_directory,
                temporary_directory,
                config_directory,
                cache_directory,
            ):
                path.mkdir(mode=0o700)

            child_environment = {
                "HOME": str(home_directory),
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": os.defpath,
                "TMPDIR": str(temporary_directory),
                "XDG_CACHE_HOME": str(cache_directory),
                "XDG_CONFIG_HOME": str(config_directory),
            }
            with _isolated_command_state(
                working_directory,
                child_environment,
            ):
                report = run_golden_path(
                    executable,
                    license_path,
                    temporary_parent=temporary_directory,
                )

            ambient_entries = {
                "cwd": _tree_entries(working_directory),
                "home": _tree_entries(home_directory),
                "config": _tree_entries(config_directory),
                "cache": _tree_entries(cache_directory),
            }
            if any(ambient_entries.values()):
                raise GoldenPathError(
                    "installed CLI wrote undeclared ambient state: "
                    + repr(ambient_entries)
                )
    finally:
        try:
            if _file_sha256(executable) != executable_sha256:
                raise GoldenPathError(
                    "installed CLI changed during the golden path"
                )
            if (
                _installed_tree_manifest(install_namespace)
                != install_manifest_before
            ):
                raise GoldenPathError(
                    "installed CLI namespace changed during the golden path"
                )
        except OSError as error:
            raise GoldenPathError(
                "installed CLI namespace became unreadable"
            ) from error

    result = dict(report)
    result.update(
        {
            "installed_cli_verified": True,
            "installed_cli_sha256": executable_sha256,
            "installed_cli_namespace_unchanged": True,
            "installed_cli_namespace_entries": len(
                install_manifest_before
            ),
            "clean_working_directory_verified": True,
            "minimal_child_environment_verified": True,
            "ambient_user_state_unchanged": True,
            "repository_working_directory_required": False,
        }
    )
    return result


def _model_profile_sha256() -> bytes:
    return hashlib.sha256(
        MODEL_PROFILE_DOMAIN
        + struct.pack("<Q", MODEL_PROFILE_ABI)
        + struct.pack("<Q", MODEL_PROFILE_ID)
    ).digest()


def _conversion_profile_sha256(group_size: int) -> bytes:
    if group_size not in (1, 2, 4, 8, 16, 32, 64, 128):
        raise GoldenPathError("unsupported conversion group size")
    digest = hashlib.sha256()
    digest.update(CONVERSION_PROFILE_DOMAIN)
    digest.update(
        struct.pack(
            "<7Q",
            CONVERSION_PROFILE_ABI,
            1,
            256,
            64,
            0x514F_4954,
            16,
            1 << 18,
        )
    )
    digest.update(struct.pack("<Q", len(CONVERSION_ARCHITECTURE)))
    digest.update(CONVERSION_ARCHITECTURE)
    digest.update(b"\x01")
    digest.update(struct.pack("<Q", len(QUANTIZED_TENSOR_KINDS)))
    for kind in QUANTIZED_TENSOR_KINDS:
        digest.update(struct.pack("<II", kind, group_size))
    return digest.digest()


def _ordinary_tensor_inventory_sha256(
    config: Mapping[str, object],
) -> tuple[int, bytes]:
    geometry_names = (
        "dim",
        "hidden_dim",
        "layers",
        "vocab",
        "heads",
        "head_dim",
        "kv_heads",
    )
    geometry: dict[str, int] = {}
    for name in geometry_names:
        value = config.get(name)
        if type(value) is not int or value <= 0 or value > 0xFFFF_FFFF:
            raise GoldenPathError(f"invalid tensor inventory geometry {name!r}")
        geometry[name] = value

    dim = geometry["dim"]
    hidden_dim = geometry["hidden_dim"]
    vocab = geometry["vocab"]
    tensors: list[tuple[int, int, tuple[int, ...]]] = [
        (0xFFFF_FFFF, 1, (vocab, dim)),
        (0xFFFF_FFFF, 2, (dim,)),
        (0xFFFF_FFFF, 3, (vocab, dim)),
    ]
    for layer in range(geometry["layers"]):
        tensors.extend(
            (
                (layer, 4, (dim,)),
                (layer, 5, (dim, dim)),
                (layer, 6, (dim, dim)),
                (layer, 7, (dim, dim)),
                (layer, 8, (dim, dim)),
                (layer, 9, (dim,)),
                (layer, 10, (hidden_dim, dim)),
                (layer, 11, (hidden_dim, dim)),
                (layer, 12, (dim, hidden_dim)),
            )
        )

    digest = hashlib.sha256()
    digest.update(TENSOR_INVENTORY_DOMAIN)
    digest.update(struct.pack("<QQ", TENSOR_PROFILE_ABI, len(tensors)))
    digest.update(
        struct.pack(
            "<7I",
            *(geometry[name] for name in geometry_names),
        )
    )
    for layer, role, shape in tensors:
        digest.update(struct.pack("<IBBB", layer, role, 1, len(shape)))
        for extent in shape:
            digest.update(struct.pack("<Q", extent))
    return len(tensors), digest.digest()


def _write_safetensors_variant(
    source: Path,
    destination: Path,
    *,
    tensor_name: str,
    expected_shape: Sequence[int],
    replacement_name: str | None = None,
    replacement_shape: Sequence[int] | None = None,
    replacement_dtype: str | None = None,
) -> None:
    wire = source.read_bytes()
    if len(wire) < 8:
        raise GoldenPathError("fixture safetensors header is truncated")
    header_bytes = struct.unpack_from("<Q", wire)[0]
    data_offset = 8 + header_bytes
    if data_offset > len(wire):
        raise GoldenPathError("fixture safetensors header exceeds the file")
    try:
        document = json.loads(wire[8:data_offset])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GoldenPathError("fixture safetensors header is invalid") from error
    if not isinstance(document, dict):
        raise GoldenPathError("fixture safetensors header is not an object")
    tensor = document.get(tensor_name)
    if not isinstance(tensor, dict):
        raise GoldenPathError(f"fixture tensor {tensor_name!r} is missing")
    if tensor.get("dtype") != "F32" or tensor.get("shape") != list(expected_shape):
        raise GoldenPathError(f"fixture tensor {tensor_name!r} drifted")

    replacement = dict(tensor)
    if replacement_shape is not None:
        replacement["shape"] = list(replacement_shape)
    if replacement_dtype is not None:
        replacement["dtype"] = replacement_dtype
    if replacement_name is not None:
        if replacement_name in document:
            raise GoldenPathError("replacement tensor name already exists")
        del document[tensor_name]
        document[replacement_name] = replacement
    else:
        document[tensor_name] = replacement

    encoded_header = json.dumps(
        document,
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("ascii")
    destination.write_bytes(
        struct.pack("<Q", len(encoded_header))
        + encoded_header
        + wire[data_offset:]
    )


def _assert_package_rejected_without_namespace_mutation(
    executable: Path,
    source: Path,
    license_path: Path,
    root: Path,
    label: str,
    package_arguments: Sequence[str],
    retained_files: Mapping[str, bytes] | None = None,
) -> None:
    namespace = root / f"{label}-outputs"
    namespace.mkdir()
    expected_files = dict(retained_files or {})
    for name, payload in expected_files.items():
        retained = namespace / name
        retained.write_bytes(payload)
        retained.chmod(0o600)
    _run(
        (
            str(executable),
            "package-model",
            str(source),
            str(namespace / "model.glacier"),
            str(namespace / "model.glrt"),
            str(namespace / "model.glpkg"),
            "--license",
            str(license_path),
            *package_arguments,
        ),
        expect_success=False,
    )
    observed_files = {
        path.name: path.read_bytes()
        for path in namespace.iterdir()
        if path.is_file()
    }
    if observed_files != expected_files:
        raise GoldenPathError(
            f"rejected package case {label!r} mutated output namespace: "
            f"{tuple(sorted(observed_files))!r}"
        )


def _assert_package_config_rejected(
    executable: Path,
    source: Path,
    license_path: Path,
    root: Path,
    label: str,
    config_arguments: Sequence[str],
) -> None:
    _assert_package_rejected_without_namespace_mutation(
        executable,
        source,
        license_path,
        root,
        label,
        (
            "--experimental-profile",
            EXPERIMENTAL_MODEL_PROFILE,
            *config_arguments,
        ),
    )


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
    new_tokens: int = NEW_TOKENS,
    eos_token: int | None = None,
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
        str(new_tokens),
    ]
    if package_path is not None:
        command.extend(("--package", str(package_path)))
    if eos_token is not None:
        command.extend(("--eos-token", str(eos_token)))
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


def _durable_acknowledged_challenge(
    *,
    request_id: str,
    package_sha256: bytes,
    representation_sha256: bytes,
    license_sha256: bytes,
    raw_text_sha256: bytes,
    output_count: int,
) -> bytes:
    return hashlib.sha256(
        DURABLE_ACKNOWLEDGED_CHALLENGE_DOMAIN
        + bytes.fromhex(request_id)
        + package_sha256
        + representation_sha256
        + license_sha256
        + raw_text_sha256
        + struct.pack("<Q", output_count)
    ).digest()


def _durable_derived_root(domain: bytes, challenge: bytes) -> bytes:
    return hashlib.sha256(domain + challenge).digest()


def _durable_u64(root: bytes, offset: int) -> int:
    value = struct.unpack_from("<Q", root, offset)[0]
    return value if value != 0 else 1


def _acknowledged_bootstrap_facts(
    directory: Path,
) -> tuple[
    direct_oracle.recovery.CheckpointWireFacts,
    direct_oracle.recovery.SourceContractFacts,
    direct_oracle.recovery.DurableInputFacts,
]:
    checkpoint = direct_oracle.recovery._decode_checkpoint_wire(directory)
    if checkpoint is None or checkpoint.generation != 1:
        raise GoldenPathError(
            "acknowledged bootstrap checkpoint is not generation one"
        )
    contract, durable_input = (
        direct_oracle.recovery._decode_checkpoint_input_lineage(
            directory,
            checkpoint,
        )
    )
    if durable_input is None:
        raise GoldenPathError(
            "acknowledged bootstrap lacks durable input lineage"
        )
    return checkpoint, contract, durable_input


def _verify_acknowledged_bootstrap_report(
    report: Mapping[str, object],
    *,
    checkpoint: direct_oracle.recovery.CheckpointWireFacts,
    contract: direct_oracle.recovery.SourceContractFacts,
    durable_input: direct_oracle.recovery.DurableInputFacts,
    package_sha256: bytes,
    representation_sha256: bytes,
    license_sha256: bytes,
    raw_text: bytes,
    output_count: int,
    selection_before: str,
    bootstrap_disposition: str,
) -> None:
    challenge = _durable_acknowledged_challenge(
        request_id=DURABLE_REQUEST_ID,
        package_sha256=package_sha256,
        representation_sha256=representation_sha256,
        license_sha256=license_sha256,
        raw_text_sha256=raw_input.raw_text_sha256(raw_text),
        output_count=output_count,
    )
    request_epoch = _durable_u64(
        _durable_derived_root(
            DURABLE_RUNTIME_IDENTITY_DOMAIN,
            challenge,
        ),
        0,
    )
    sink_instance = _durable_derived_root(
        DURABLE_SINK_INSTANCE_IDENTITY_DOMAIN,
        challenge,
    )
    sink_implementation = hashlib.sha256(
        DURABLE_SINK_IMPLEMENTATION_DOMAIN
    ).digest()
    expected = {
        "schema": "glacier.prepared-text-durable-run/v1",
        "operation": "bootstrap",
        "profile": "ordinary-package-acknowledged-v1",
        "route": "acknowledged",
        "selection_before": selection_before,
        "bootstrap_disposition": bootstrap_disposition,
        "requested_token_count": output_count,
        "sink_capacity": output_count - 1,
        "durable_checkpoint": True,
        "fresh_process_boundary_ready": True,
        "checked_committed_output": False,
        "terminal": False,
        "ownership_closed": True,
        "request_epoch": request_epoch,
        "generation": 1,
        "publication_next_sequence": 1,
        "max_set_bytes": DURABLE_MAX_SET_BYTES,
        "request_id_sha256": hashlib.sha256(
            bytes.fromhex(DURABLE_REQUEST_ID)
        ).hexdigest(),
        "package_sha256": package_sha256.hex(),
        "representation_sha256": representation_sha256.hex(),
        "challenge_sha256": challenge.hex(),
        "sink_implementation_sha256": sink_implementation.hex(),
        "sink_instance_sha256": sink_instance.hex(),
        "checkpoint_set_sha256": checkpoint.checkpoint_sha256,
        "checkpoint_selector_sha256": checkpoint.selector_sha256,
        "source_recovery_contract_sha256": (
            contract.contract_sha256.hex()
        ),
        "input_archive_sha256": durable_input.archive_sha256.hex(),
    }
    if dict(report) != expected:
        differing = sorted(
            name
            for name in set(report) | set(expected)
            if report.get(name) != expected.get(name)
        )
        decoded_challenge = _durable_acknowledged_challenge(
            request_id=DURABLE_REQUEST_ID,
            package_sha256=durable_input.package_sha256,
            representation_sha256=durable_input.representation_sha256,
            license_sha256=contract.bound_artifact_license_sha256,
            raw_text_sha256=durable_input.raw_text_sha256,
            output_count=output_count,
        )
        raise GoldenPathError(
            "acknowledged bootstrap report mismatch: "
            + ", ".join(
                f"{name}={report.get(name)!r}/{expected.get(name)!r}"
                for name in differing
            )
            + f"; decoded_challenge={decoded_challenge.hex()}"
            + (
                "; inputs="
                f"package:{durable_input.package_sha256 == package_sha256},"
                "representation:"
                f"{durable_input.representation_sha256 == representation_sha256},"
                "license:"
                f"{contract.bound_artifact_license_sha256 == license_sha256},"
                "raw:"
                f"{durable_input.raw_text_sha256 == raw_input.raw_text_sha256(raw_text)}"
            )
        )
    if (
        checkpoint.request_epoch != request_epoch
        or checkpoint.next_sequence != 1
        or checkpoint.challenge_sha256 != challenge.hex()
        or contract.options[0] != output_count
        or contract.sink_capacity != output_count - 1
        or contract.sink_initial_sequence != 1
        or contract.challenge_sha256 != challenge
        or contract.sink_implementation_sha256
        != sink_implementation
        or contract.sink_instance_sha256 != sink_instance
        or contract.bound_artifact_license_sha256 != license_sha256
        or durable_input.package_sha256 != package_sha256
        or durable_input.representation_sha256
        != representation_sha256
        or durable_input.raw_text != raw_text
    ):
        raise GoldenPathError(
            "acknowledged bootstrap lineage mismatch"
        )


def _terminal_semantic_sha256(
    checkpoint: direct_oracle.recovery.CheckpointWireFacts,
    contract: direct_oracle.recovery.SourceContractFacts,
    tokens: Sequence[int],
    image_container_sha256: bytes,
) -> str:
    if len(checkpoint.objects) != 5:
        raise GoldenPathError(
            "acknowledged terminal semantic object is absent"
        )
    encoded = checkpoint.objects[2].payload
    if (
        len(encoded) != TERMINAL_SEMANTIC_BYTES
        or encoded[:8] != TERMINAL_SEMANTIC_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0]
        != TERMINAL_SEMANTIC_ABI
        or struct.unpack_from("<Q", encoded, 16)[0]
        != TERMINAL_SEMANTIC_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[496:TERMINAL_SEMANTIC_BODY_BYTES])
    ):
        raise GoldenPathError(
            "acknowledged terminal semantic header is invalid"
        )
    (
        request_epoch,
        publication_next_sequence,
        prompt_token_count,
        max_new_tokens,
        kv_position,
        sampling_calls,
        output_length,
        output_bytes,
        execution_abi,
        rng_state_abi,
    ) = struct.unpack_from("<10Q", encoded, 32)
    output_root = hashlib.sha256(
        TERMINAL_OUTPUT_DOMAIN
        + contract.artifact_sha256
        + contract.bound_token_domain_sha256
        + contract.bound_token_domain_config_sha256
        + struct.pack("<Q", len(tokens))
        + b"".join(struct.pack("<I", token) for token in tokens)
    ).digest()
    expected_root = hashlib.sha256(
        TERMINAL_SEMANTIC_DOMAIN
        + encoded[:TERMINAL_SEMANTIC_BODY_BYTES]
    ).digest()
    expected_state_commitment = hashlib.sha256(
        STATE_COMMITMENT_DOMAIN
        + struct.pack(
            "<QQQ",
            STATE_COMMITMENT_ABI,
            execution_abi,
            kv_position,
        )
        + encoded[368:400]
        + struct.pack("<Q", rng_state_abi)
        + encoded[400:432]
        + struct.pack("<QQ", sampling_calls, output_length)
        + encoded[432:464]
    ).digest()
    actual_root = encoded[TERMINAL_SEMANTIC_BODY_BYTES:]
    if (
        request_epoch != checkpoint.request_epoch
        or publication_next_sequence != len(tokens)
        or prompt_token_count != len(contract.prompt_tokens)
        or max_new_tokens != len(tokens)
        or kv_position != prompt_token_count + len(tokens) - 1
        or sampling_calls != len(tokens)
        or output_length != len(tokens)
        or output_bytes != len(tokens) * 4
        or execution_abi == 0
        or rng_state_abi == 0
        or encoded[112:144] != contract.plan_sha256
        or encoded[144:176] != contract.artifact_sha256
        or encoded[176:208] != contract.bound_token_domain_sha256
        or encoded[208:240]
        != contract.bound_token_domain_config_sha256
        or encoded[240:272] != image_container_sha256
        or encoded[272:304] != contract.prompt_sha256
        or encoded[304:336] != output_root
        or any(
            encoded[offset : offset + 32] == bytes(32)
            for offset in range(240, 496, 32)
        )
        or encoded[464:496] != expected_state_commitment
        or actual_root != expected_root
        or actual_root == bytes(32)
    ):
        raise GoldenPathError(
            "acknowledged terminal semantic lineage mismatch"
        )
    return actual_root.hex()


def _archive_container_sha256(
    durable_input: direct_oracle.recovery.DurableInputFacts,
) -> bytes:
    try:
        archive = package_oracle.decode_archive(durable_input.encoded)
    except package_oracle.PreparedTextPackageError as error:
        raise GoldenPathError(
            "acknowledged durable input archive is invalid"
        ) from error
    representation = archive.get("representation")
    if not isinstance(representation, dict):
        raise GoldenPathError(
            "acknowledged archive representation is absent"
        )
    container_sha256 = representation.get("container_sha256")
    if (
        not isinstance(container_sha256, bytes)
        or len(container_sha256) != 32
        or container_sha256 == bytes(32)
    ):
        raise GoldenPathError(
            "acknowledged archive container root is invalid"
        )
    return container_sha256


def _tokens_are_utf8(tokens: Sequence[int]) -> bool:
    try:
        bytes(tokens).decode("utf-8", "strict")
    except UnicodeDecodeError:
        return False
    return True


def _acknowledged_terminal_facts(
    directory: Path,
    *,
    output_count: int,
    package_sha256: bytes,
    representation_sha256: bytes,
    license_sha256: bytes,
    raw_text: bytes,
    expected_tokens: Sequence[int],
) -> tuple[
    direct_oracle.recovery.WireFacts,
    dict[str, str],
]:
    checkpoint = direct_oracle.recovery._decode_checkpoint_wire(directory)
    sink = direct_oracle.recovery._decode_sink_wire(directory)
    if checkpoint is None or sink is None:
        raise GoldenPathError(
            "acknowledged terminal selection is incomplete"
        )
    contract, durable_input = (
        direct_oracle.recovery._decode_checkpoint_input_lineage(
            directory,
            checkpoint,
        )
    )
    if durable_input is None or checkpoint.terminal_tokens is None:
        raise GoldenPathError(
            "acknowledged terminal lineage is incomplete"
        )
    challenge = _durable_acknowledged_challenge(
        request_id=DURABLE_REQUEST_ID,
        package_sha256=package_sha256,
        representation_sha256=representation_sha256,
        license_sha256=license_sha256,
        raw_text_sha256=raw_input.raw_text_sha256(raw_text),
        output_count=output_count,
    )
    tokens = tuple(expected_tokens)
    if (
        not tokens
        or any(
            type(token) is not int or token < 0 or token > 0xFF
            for token in tokens
        )
        or contract.bound_artifact_license_sha256 != license_sha256
        or checkpoint.generation != output_count + 1
        or checkpoint.next_sequence != output_count
        or checkpoint.request_epoch != contract.request_epoch
        or checkpoint.challenge_sha256 != challenge.hex()
        or checkpoint.terminal_tokens != tokens
        or sink.generation != output_count
        or sink.count != output_count - 1
        or sink.initial_sequence != 1
        or sink.next_sequence != output_count
        or sink.request_epoch != contract.request_epoch
        or sink.request_sha256 != contract.plan_sha256.hex()
        or sink.sink_implementation_sha256
        != contract.sink_implementation_sha256.hex()
        or sink.sink_instance_sha256
        != contract.sink_instance_sha256.hex()
        or sink.acknowledgement_tokens != tokens[1:]
        or contract.options[0] != output_count
        or contract.sink_capacity != output_count - 1
        or contract.sink_initial_sequence != 1
        or contract.challenge_sha256 != challenge
        or durable_input.package_sha256 != package_sha256
        or durable_input.representation_sha256
        != representation_sha256
        or durable_input.raw_text != raw_text
        or durable_input.raw_text_sha256
        != raw_input.raw_text_sha256(raw_text)
    ):
        raise GoldenPathError(
            "acknowledged terminal wire lineage mismatch"
        )
    terminal_acknowledgement = checkpoint.objects[3].payload
    if (
        len(terminal_acknowledgement)
        != direct_oracle.recovery.ACK_BYTES
        or terminal_acknowledgement[-32:].hex()
        != sink.head_acknowledgement_sha256
    ):
        raise GoldenPathError(
            "terminal acknowledgement is not the sink head"
        )
    _terminal_semantic_sha256(
        checkpoint,
        contract,
        tokens,
        _archive_container_sha256(durable_input),
    )
    wire = direct_oracle.recovery.WireFacts(
        sink=sink,
        checkpoint=checkpoint,
        source_contract=contract,
        durable_input=durable_input,
    )
    roots = direct_oracle.recovery._expected_committed_output_roots(
        wire,
        tokens,
    )
    if len(_durable_directory_manifest(directory)) != 2 * output_count + 5:
        raise GoldenPathError(
            "acknowledged terminal namespace size mismatch"
        )
    return wire, roots


def _verify_acknowledged_terminal_report(
    report: Mapping[str, object],
    *,
    wire: direct_oracle.recovery.WireFacts,
    roots: Mapping[str, str],
    output_count: int,
    selection_before: str,
    disposition: str,
    bootstrap_disposition: str | None,
    source_disposition: str | None,
    target_call_count: int,
    advanced_target_count: int,
    output_disclosed: bool,
) -> None:
    checkpoint = wire.checkpoint
    sink = wire.sink
    contract = wire.source_contract
    durable_input = wire.durable_input
    if (
        checkpoint is None
        or sink is None
        or contract is None
        or durable_input is None
    ):
        raise GoldenPathError("acknowledged report lacks wire facts")
    challenge = checkpoint.challenge_sha256
    tokens = tuple(checkpoint.terminal_tokens or ())
    terminal_semantic_sha256 = _terminal_semantic_sha256(
        checkpoint,
        contract,
        tokens,
        _archive_container_sha256(durable_input),
    )
    expected_scalars: dict[str, object] = {
        "schema": "glacier.prepared-text-durable-run/v1",
        "operation": "advance",
        "profile": "ordinary-package-acknowledged-v1",
        "route": "acknowledged",
        "selection_before": selection_before,
        "disposition": disposition,
        "bootstrap_disposition": bootstrap_disposition,
        "source_disposition": source_disposition,
        "requested_token_count": output_count,
        "sink_capacity": output_count - 1,
        "target_call_count": target_call_count,
        "advanced_target_count": advanced_target_count,
        "durable_checkpoint": True,
        "fresh_process_continuation_supported": True,
        "preexisting_generation_continuation_performed": (
            selection_before != "absent"
            and (source_disposition == "advanced"
                 or advanced_target_count != 0)
        ),
        "checked_committed_output": True,
        "terminal": True,
        "ownership_closed": True,
        "model_execution_performed": (
            source_disposition == "advanced"
            or advanced_target_count != 0
        ),
        "output_disclosed": output_disclosed,
        "output_encoding": "token-ids",
        "request_epoch": checkpoint.request_epoch,
        "generation": output_count + 1,
        "publication_next_sequence": output_count,
        "visible_next_sequence": output_count,
        "acknowledgement_count": output_count - 1,
        "token_count": output_count,
        "max_set_bytes": DURABLE_MAX_SET_BYTES,
        "request_id_sha256": hashlib.sha256(
            bytes.fromhex(DURABLE_REQUEST_ID)
        ).hexdigest(),
        "challenge_sha256": challenge,
        "terminal_semantic_sha256": terminal_semantic_sha256,
        "utf8_valid": _tokens_are_utf8(tokens),
        "output_tokens": (
            list(tokens)
            if output_disclosed
            else None
        ),
    }
    expected = {**expected_scalars, **roots}
    if dict(report) != expected:
        differing = sorted(
            name
            for name in set(report) | set(expected)
            if report.get(name) != expected.get(name)
        )
        raise GoldenPathError(
            "acknowledged terminal report mismatch: "
            + ", ".join(differing)
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


def _verify_variable_terminal_report(
    report: Mapping[str, object],
    *,
    expected_output: list[int],
    max_token_count: int,
    eos_token: int,
    termination_reason: str,
    close_event_kind: str,
    model_profile: str,
    prompt_source: str,
    prompt_bytes: int,
    prompt_tokens: int,
    tokenizer_vocab_size: int,
    package_sha256: str | None,
    representation_sha256: str | None,
    request_epoch: int,
    scheduler_challenge_sha256: bytes,
) -> bytes:
    actual_keys = frozenset(report)
    if actual_keys != VARIABLE_TERMINAL_REPORT_KEYS:
        missing = sorted(VARIABLE_TERMINAL_REPORT_KEYS - actual_keys)
        extra = sorted(actual_keys - VARIABLE_TERMINAL_REPORT_KEYS)
        raise GoldenPathError(
            "variable terminal report key mismatch: "
            f"missing={missing}, extra={extra}"
        )
    actual_count = len(expected_output)
    expected_scalars: dict[str, object] = {
        "schema": "glacier.prepared-text-variable-run/v1",
        "profile": "utf8-byte-eos-v1",
        "model_profile": model_profile,
        "prompt_source": prompt_source,
        "output_rendering": "token-ids",
        "prepared_image": True,
        "common_plan": True,
        "transactional_publication": True,
        "fixed_result_envelope": False,
        "durable_result_sink": False,
        "fresh_process_recovery": False,
        "durable_eos_supported": False,
        "package_admission": package_sha256 is not None,
        "prompt_bytes": prompt_bytes,
        "prompt_tokens": prompt_tokens,
        "tokenizer_vocab_size": tokenizer_vocab_size,
        "variable_terminal_evidence_abi": VARIABLE_TERMINAL_EVIDENCE_ABI,
        "completed_early_abi": COMPLETED_EARLY_ABI,
        "request_epoch": request_epoch,
        "max_token_count": max_token_count,
        "actual_token_count": actual_count,
        "eos_token": eos_token,
        "termination_reason": termination_reason,
        "unused_quanta": max_token_count - actual_count,
        "close_event_kind": close_event_kind,
        "ownership_closed": True,
        "resource_bank_zero": True,
        "scheduler_closed": True,
        "package_sha256": package_sha256,
        "representation_sha256": representation_sha256,
        "runtime_self_verified": True,
    }
    for name, expected in expected_scalars.items():
        actual = report.get(name)
        if type(actual) is not type(expected) or actual != expected:
            raise GoldenPathError(
                f"variable terminal field {name!r}: "
                f"{actual!r} != {expected!r}"
            )

    report_output = report.get("output_tokens")
    if (
        not isinstance(report_output, list)
        or len(report_output) != actual_count
        or any(
            type(token) is not int or not 0 <= token <= 255
            for token in report_output
        )
        or report_output != expected_output
    ):
        raise GoldenPathError("invalid variable terminal output")

    close_event_sequence = _report_int(report, "close_event_sequence")
    if close_event_sequence != actual_count + 1:
        raise GoldenPathError(
            "variable terminal close sequence changed: "
            f"{close_event_sequence} != {actual_count + 1}"
        )
    digest_names = (
        "variable_terminal_evidence_sha256",
        "terminal_boundary_sha256",
        "terminal_semantic_sha256",
        "output_sha256",
        "final_service_event_sha256",
        "publication_transcript_sha256",
        "close_event_sha256",
        "local_plan_sha256",
        "bound_plan_sha256",
        "scheduler_challenge_sha256",
    )
    digests = {
        name: _report_digest(report, name)
        for name in digest_names
    }
    if (
        digests["scheduler_challenge_sha256"]
        != scheduler_challenge_sha256
    ):
        raise GoldenPathError("variable terminal scheduler challenge changed")

    completed = report.get("completed_early_sha256")
    if actual_count < max_token_count:
        completed_root = _report_digest(
            report,
            "completed_early_sha256",
        )
        expected_completed_root = hashlib.sha256(
            COMPLETED_EARLY_DOMAIN
            + struct.pack("<Q", COMPLETED_EARLY_ABI)
            + struct.pack("<B", 1)
            + struct.pack(
                "<QQQQI",
                request_epoch,
                max_token_count,
                actual_count,
                max_token_count - actual_count,
                eos_token,
            )
            + digests["local_plan_sha256"]
            + digests["bound_plan_sha256"]
            + digests["scheduler_challenge_sha256"]
            + digests["terminal_boundary_sha256"]
            + digests["terminal_semantic_sha256"]
            + digests["output_sha256"]
            + struct.pack("<Q", close_event_sequence)
            + digests["close_event_sha256"]
        ).digest()
        if completed_root != expected_completed_root:
            raise GoldenPathError(
                "completed-early root did not independently verify"
            )
    elif completed is not None:
        raise GoldenPathError(
            "full-length terminal emitted completed-early evidence"
        )
    else:
        completed_root = bytes(32)

    reason_codes = {
        "length": 0,
        "eos": 1,
        "eos_at_limit": 2,
    }
    reason_code = reason_codes.get(termination_reason)
    if reason_code is None:
        raise GoldenPathError("invalid expected variable terminal reason")
    expected_evidence_root = hashlib.sha256(
        VARIABLE_TERMINAL_EVIDENCE_DOMAIN
        + struct.pack("<Q", VARIABLE_TERMINAL_EVIDENCE_ABI)
        + struct.pack("<B", reason_code)
        + struct.pack("<QQI", max_token_count, actual_count, eos_token)
        + digests["terminal_boundary_sha256"]
        + digests["terminal_semantic_sha256"]
        + digests["publication_transcript_sha256"]
        + digests["final_service_event_sha256"]
        + digests["close_event_sha256"]
        + struct.pack("<B", int(actual_count < max_token_count))
        + completed_root
    ).digest()
    if (
        digests["variable_terminal_evidence_sha256"]
        != expected_evidence_root
    ):
        raise GoldenPathError(
            "variable terminal evidence root did not independently verify"
        )
    return digests["terminal_semantic_sha256"]


def _verify_package_artifacts(
    *,
    source: Path,
    portable: Path,
    prepared: Path,
    package_path: Path,
    license_bytes: bytes,
    report: Mapping[str, object],
    config_input: bytes,
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
    expected_model_profile_sha256 = _model_profile_sha256()
    (
        expected_tensor_count,
        expected_tensor_inventory_sha256,
    ) = _ordinary_tensor_inventory_sha256(config)
    expected_conversion_profile_sha256 = (
        _conversion_profile_sha256(16)
    )
    expected_model_content = (
        package_oracle.profiled_model_content_sha256(
            package_facts
        )
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
        or package_facts["model_profile_abi"] != MODEL_PROFILE_ABI
        or package_facts["model_profile_id"] != MODEL_PROFILE_ID
        or package_facts["model_profile_sha256"]
        != expected_model_profile_sha256
        or package_facts["tensor_profile_abi"] != TENSOR_PROFILE_ABI
        or package_facts["tensor_count"] != expected_tensor_count
        or package_facts["tensor_inventory_sha256"]
        != expected_tensor_inventory_sha256
        or package_facts["conversion_profile_sha256"]
        != expected_conversion_profile_sha256
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
        "model_profile": EXPERIMENTAL_MODEL_PROFILE,
        "model_profile_abi": f"{MODEL_PROFILE_ABI:016x}",
        "model_profile_id": MODEL_PROFILE_ID,
        "model_profile_sha256": expected_model_profile_sha256.hex(),
        "tensor_profile_abi": f"{TENSOR_PROFILE_ABI:016x}",
        "tensor_count": expected_tensor_count,
        "tensor_inventory_sha256": (
            expected_tensor_inventory_sha256.hex()
        ),
        "experimental_profile_explicit": True,
        "tensor_inventory_verified": True,
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
        "config_source": "explicit",
        "config_input_bytes": len(config_input),
        "config_input_sha256": hashlib.sha256(
            config_input
        ).hexdigest(),
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
        "resolved_config_sha256": package_facts[
            "resolved_config_sha256"
        ].hex(),
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
    replacement = hashlib.sha256(
        b"glacier-golden-path-reroot-v1\x00" + digest_name.encode("ascii")
    ).digest()
    if replacement == package_facts[digest_name]:
        raise GoldenPathError("reroot digest unexpectedly unchanged")
    return _rewrite_package(
        package_facts,
        representation_facts,
        {digest_name: replacement},
    )


def _rewrite_package(
    package_facts: Mapping[str, object],
    representation_facts: Mapping[str, object],
    replacements: Mapping[str, object],
    *,
    recompute_model_content: bool = False,
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
    for name, replacement in replacements.items():
        if name not in value:
            raise GoldenPathError(f"cannot rewrite unknown package field {name!r}")
        value[name] = replacement
    if recompute_model_content:
        value["model_content_sha256"] = (
            package_oracle.profiled_model_content_sha256(value)
        )
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
    expected_new_tokens: int = NEW_TOKENS,
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
        or len(output_tokens) != expected_new_tokens
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


def run_golden_path(
    executable: Path,
    license_path: Path,
    *,
    temporary_parent: Path | None = None,
) -> dict[str, object]:
    executable = executable.resolve(strict=True)
    license_path = license_path.resolve(strict=True)
    license_bytes = license_path.read_bytes()
    if not license_bytes:
        raise GoldenPathError("empty license")
    if hashlib.sha256(license_bytes).hexdigest() != EXPECTED_LICENSE_SHA256:
        raise GoldenPathError("retained fixture license identity drift")

    with tempfile.TemporaryDirectory(
        prefix="glacier-r1kb-",
        dir=temporary_parent,
    ) as directory:
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
        ordinary_config = root / "ordinary-config.json"
        ordinary_config_bytes = (
            b'{"hidden_size":32,'
            b'"intermediate_size":64,"num_hidden_layers":1,'
            b'"vocab_size":256,"num_attention_heads":4,'
            b'"num_key_value_heads":4,'
            b'"rms_norm_eps":0.00001,"rope_theta":500000,'
            b'"tie_word_embeddings":false}\n'
        )
        ordinary_config.write_bytes(ordinary_config_bytes)
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
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "missing-experimental-profile",
            ("--config", str(ordinary_config)),
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "missing-experimental-profile-value",
            (
                "--config",
                str(ordinary_config),
                "--experimental-profile",
            ),
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "duplicate-experimental-profile",
            (
                "--config",
                str(ordinary_config),
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
            ),
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "unknown-experimental-profile",
            (
                "--config",
                str(ordinary_config),
                "--experimental-profile",
                "unknown-package-v1",
            ),
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "missing-required-config",
            (
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
            ),
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "unsupported-quant-group-geometry",
            (
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
                "--group-size",
                "7",
            ),
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            ordinary_source,
            license_path,
            root,
            "duplicate-quant-group-option",
            (
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
                "--group-size",
                "16",
                "--group-size",
                "32",
            ),
        )
        undersized_vocab_source = root / "undersized-vocab.safetensors"
        undersized_vocab_config = root / "undersized-vocab-config.json"
        undersized_vocab_config.write_bytes(
            b'{"hidden_size":32,"intermediate_size":64,'
            b'"num_hidden_layers":1,"vocab_size":255,'
            b'"num_attention_heads":4,"num_key_value_heads":4,'
            b'"rms_norm_eps":1e-5,"rope_theta":5e5,'
            b'"tie_word_embeddings":false}\n'
        )
        _run(
            (
                str(executable),
                "gen-fixture",
                str(undersized_vocab_source),
                "--dim",
                "32",
                "--hidden",
                "64",
                "--layers",
                "1",
                "--vocab",
                "255",
            )
        )
        _assert_package_rejected_without_namespace_mutation(
            executable,
            undersized_vocab_source,
            license_path,
            root,
            "undersized-byte-vocabulary",
            (
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(undersized_vocab_config),
            ),
        )

        q_projection = "model.layers.0.self_attn.q_proj.weight"
        unknown_projection = "model.layers.0.self_attn.x_proj.weight"
        if len(q_projection) != len(unknown_projection):
            raise GoldenPathError("unknown tensor rename changed name length")
        strict_tensor_variants = (
            (
                "unknown-same-length-tensor",
                {
                    "tensor_name": q_projection,
                    "expected_shape": (32, 32),
                    "replacement_name": unknown_projection,
                },
            ),
            (
                "transposed-nonsquare-mlp",
                {
                    "tensor_name": "model.layers.0.mlp.down_proj.weight",
                    "expected_shape": (32, 64),
                    "replacement_shape": (64, 32),
                },
            ),
            (
                "wrong-rank-attention",
                {
                    "tensor_name": q_projection,
                    "expected_shape": (32, 32),
                    "replacement_shape": (1024,),
                },
            ),
            (
                "wrong-dtype-attention",
                {
                    "tensor_name": q_projection,
                    "expected_shape": (32, 32),
                    "replacement_dtype": "I32",
                },
            ),
        )
        for label, mutation in strict_tensor_variants:
            mutated_source = root / f"{label}.safetensors"
            _write_safetensors_variant(
                ordinary_source,
                mutated_source,
                **mutation,
            )
            _assert_package_rejected_without_namespace_mutation(
                executable,
                mutated_source,
                license_path,
                root,
                label,
                (
                    "--experimental-profile",
                    EXPERIMENTAL_MODEL_PROFILE,
                    "--config",
                    str(ordinary_config),
                    "--group-size",
                    "16",
                ),
                retained_files=(
                    {
                        ".glacier-conversion-publication.candidate-v1":
                            b"retained-preflight-candidate"
                    }
                    if label == "unknown-same-length-tensor"
                    else None
                ),
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
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
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
            config_input=ordinary_config_bytes,
        )
        expected_explicit_config = {
            "dim": 32,
            "hidden_dim": 64,
            "layers": 1,
            "vocab": 256,
            "heads": 4,
            "head_dim": 8,
            "kv_heads": 4,
            "rms_eps": struct.unpack(
                "<f",
                struct.pack("<f", 0.00001),
            )[0],
            "rms_eps_bits": struct.unpack(
                "<I",
                struct.pack("<f", 0.00001),
            )[0],
            "rope_theta": 500000.0,
            "rope_theta_bits": struct.unpack(
                "<I",
                struct.pack("<f", 500000.0),
            )[0],
            "tie_embeddings": False,
        }
        if package_facts["config"] != expected_explicit_config:
            raise GoldenPathError(
                "explicit config did not become the resolved package config: "
                f"{package_facts['config']!r}"
            )
        initial_config_input_sha256 = hashlib.sha256(
            ordinary_config_bytes
        ).hexdigest()
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
        variable_baseline = ordinary_report.get("output_tokens")
        if (
            not isinstance(variable_baseline, list)
            or len(variable_baseline) != NEW_TOKENS
            or any(
                type(token) is not int or not 0 <= token <= 255
                for token in variable_baseline
            )
        ):
            raise GoldenPathError("ordinary output cannot seed EOS cases")
        variable_hit_eos = variable_baseline[0]
        used_tokens = set(variable_baseline)
        variable_miss_eos = next(
            token for token in range(256) if token not in used_tokens
        )
        variable_context = {
            "model_profile": "ordinary-package-v1",
            "prompt_source": "file",
            "prompt_bytes": len(PROMPT.encode("utf-8")),
            "prompt_tokens": ordinary_report["prompt_tokens"],
            "tokenizer_vocab_size": ordinary_report[
                "tokenizer_vocab_size"
            ],
            "package_sha256": package_facts["package_sha256"].hex(),
            "representation_sha256": representation_sha256,
            "request_epoch": ordinary_report["request_epoch"],
            "scheduler_challenge_sha256": _report_digest(
                ordinary_report,
                "prompt_receipt_sha256",
            ),
        }
        variable_hit_report = _run_text(
            executable,
            foreign_image,
            license_path,
            PROMPT,
            prompt_path,
            package_path=foreign_package,
            eos_token=variable_hit_eos,
        )
        variable_hit_semantic = _verify_variable_terminal_report(
            variable_hit_report,
            expected_output=variable_baseline[:1],
            max_token_count=NEW_TOKENS,
            eos_token=variable_hit_eos,
            termination_reason="eos",
            close_event_kind="cancel",
            **variable_context,
        )
        variable_miss_report = _run_text(
            executable,
            foreign_image,
            license_path,
            PROMPT,
            prompt_path,
            package_path=foreign_package,
            eos_token=variable_miss_eos,
        )
        variable_miss_semantic = _verify_variable_terminal_report(
            variable_miss_report,
            expected_output=variable_baseline,
            max_token_count=NEW_TOKENS,
            eos_token=variable_miss_eos,
            termination_reason="length",
            close_event_kind="retire",
            **variable_context,
        )
        variable_limit_report = _run_text(
            executable,
            foreign_image,
            license_path,
            PROMPT,
            prompt_path,
            package_path=foreign_package,
            new_tokens=1,
            eos_token=variable_hit_eos,
        )
        variable_limit_semantic = _verify_variable_terminal_report(
            variable_limit_report,
            expected_output=variable_baseline[:1],
            max_token_count=1,
            eos_token=variable_hit_eos,
            termination_reason="eos_at_limit",
            close_event_kind="retire",
            **variable_context,
        )
        if len(
            {
                variable_hit_semantic,
                variable_miss_semantic,
                variable_limit_semantic,
            }
        ) != 3:
            raise GoldenPathError(
                "variable terminal cases shared terminal semantics"
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
        different_config = root / "different-package-config.json"
        different_config_bytes = (
            b'{"dim":32,"hidden_dim":32,"num_layers":1,'
            b'"vocab_size":256,"num_heads":1,"head_dim":32,'
            b'"num_kv_heads":1,"rms_eps":1e-5,'
            b'"rope_theta":10000,"tie_word_embeddings":false}\n'
        )
        different_config.write_bytes(different_config_bytes)
        ambient_config = Path(f"{different_package}.json")
        ambient_config_bytes = (
            b'{"hidden_size":"must-not-be-discovered"}\n'
        )
        ambient_config.write_bytes(ambient_config_bytes)
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
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(different_config),
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
                config_input=different_config_bytes,
            )
        )
        if ambient_config.read_bytes() != ambient_config_bytes:
            raise GoldenPathError("ambient config sidecar was mutated")
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
            license_path,
            prompt_path,
            durable_directory,
            new_tokens=2,
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
        before_eos_rejection = _durable_directory_manifest(
            durable_directory
        )
        durable_eos_rejection = _run(
            (
                str(executable),
                "text-run",
                str(foreign_image),
                "--text-file",
                str(prompt_path),
                "--license",
                str(license_path),
                "--package",
                str(foreign_package),
                "--n",
                "1",
                "--eos-token",
                str(variable_hit_eos),
                "--durable-dir",
                str(durable_directory),
                "--request-id",
                DURABLE_REQUEST_ID,
                "--max-set-bytes",
                str(DURABLE_MAX_SET_BYTES),
            ),
            expect_success=False,
        )
        if (
            "DurableEosUnsupported" not in durable_eos_rejection.stderr
            or _durable_directory_manifest(durable_directory)
            != before_eos_rejection
        ):
            raise GoldenPathError(
                "durable EOS rejection was not mutation-free"
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
                str(foreign_package),
                "--durable-dir",
                str(durable_directory),
                "--request-id",
                DURABLE_REQUEST_ID,
                "--max-set-bytes",
                str(DURABLE_MAX_SET_BYTES),
            ),
            expect_success=False,
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

        # The acknowledged route uses the same compiled CLI artifact. N=4
        # proves a fresh-process source continuation, while N=2 and N=64
        # cover the minimum and maximum runtime-selected sink capacities.
        acknowledged_tokens: dict[int, tuple[int, ...]] = {}
        for acknowledged_output_count in (4, 2, 64):
            acknowledged_ordinary = _run_text(
                executable,
                foreign_image,
                license_path,
                PROMPT,
                prompt_path,
                package_path=foreign_package,
                new_tokens=acknowledged_output_count,
            )
            _verify_report(
                acknowledged_ordinary,
                text=PROMPT,
                license_bytes=license_bytes,
                image=foreign_image,
                package_facts=package_facts,
                representation_sha256=representation_sha256,
                expected_new_tokens=acknowledged_output_count,
            )
            ordinary_tokens_value = acknowledged_ordinary.get(
                "output_tokens"
            )
            if not isinstance(ordinary_tokens_value, list):
                raise GoldenPathError(
                    "acknowledged ordinary output is absent"
                )
            ordinary_tokens = tuple(ordinary_tokens_value)
            acknowledged_tokens[acknowledged_output_count] = (
                ordinary_tokens
            )
            acknowledged_directory = (
                root
                / (
                    "durable-acknowledged-"
                    + str(acknowledged_output_count)
                )
            )
            acknowledged_directory.mkdir(mode=0o700)
            prompt_path.write_bytes(PROMPT.encode("utf-8"))

            if acknowledged_output_count == 4:
                acknowledged_bootstrap = _run_durable_text(
                    executable,
                    foreign_image,
                    foreign_package,
                    license_path,
                    prompt_path,
                    acknowledged_directory,
                    new_tokens=acknowledged_output_count,
                    bootstrap_only=True,
                )
                if acknowledged_bootstrap is None:
                    raise GoldenPathError(
                        "acknowledged bootstrap report is absent"
                    )
                (
                    acknowledged_checkpoint,
                    acknowledged_contract,
                    acknowledged_input,
                ) = _acknowledged_bootstrap_facts(
                    acknowledged_directory
                )
                _verify_acknowledged_bootstrap_report(
                    acknowledged_bootstrap,
                    checkpoint=acknowledged_checkpoint,
                    contract=acknowledged_contract,
                    durable_input=acknowledged_input,
                    package_sha256=package_facts["package_sha256"],
                    representation_sha256=bytes.fromhex(
                        representation_sha256
                    ),
                    license_sha256=hashlib.sha256(
                        license_bytes
                    ).digest(),
                    raw_text=PROMPT.encode("utf-8"),
                    output_count=acknowledged_output_count,
                    selection_before="absent",
                    bootstrap_disposition="created",
                )
                acknowledged_source_manifest = (
                    _durable_directory_manifest(
                        acknowledged_directory
                    )
                )
                acknowledged_bootstrap_retry = _run_durable_text(
                    executable,
                    foreign_image,
                    foreign_package,
                    license_path,
                    prompt_path,
                    acknowledged_directory,
                    new_tokens=acknowledged_output_count,
                    bootstrap_only=True,
                )
                if acknowledged_bootstrap_retry is None:
                    raise GoldenPathError(
                        "acknowledged bootstrap retry is absent"
                    )
                (
                    retry_checkpoint,
                    retry_contract,
                    retry_input,
                ) = _acknowledged_bootstrap_facts(
                    acknowledged_directory
                )
                _verify_acknowledged_bootstrap_report(
                    acknowledged_bootstrap_retry,
                    checkpoint=retry_checkpoint,
                    contract=retry_contract,
                    durable_input=retry_input,
                    package_sha256=package_facts["package_sha256"],
                    representation_sha256=bytes.fromhex(
                        representation_sha256
                    ),
                    license_sha256=hashlib.sha256(
                        license_bytes
                    ).digest(),
                    raw_text=PROMPT.encode("utf-8"),
                    output_count=acknowledged_output_count,
                    selection_before="source-live",
                    bootstrap_disposition="already_selected",
                )
                if (
                    _durable_directory_manifest(
                        acknowledged_directory
                    )
                    != acknowledged_source_manifest
                ):
                    raise GoldenPathError(
                        "acknowledged bootstrap retry changed state"
                    )
                _run_durable_text(
                    executable,
                    foreign_image,
                    foreign_package,
                    license_path,
                    prompt_path,
                    acknowledged_directory,
                    new_tokens=acknowledged_output_count + 1,
                    expect_success=False,
                    expected_error="DurableRequestMismatch",
                )
                if (
                    _durable_directory_manifest(
                        acknowledged_directory
                    )
                    != acknowledged_source_manifest
                ):
                    raise GoldenPathError(
                        "changed output count mutated durable state"
                    )

            acknowledged_report = _run_durable_text(
                executable,
                foreign_image,
                foreign_package,
                license_path,
                prompt_path,
                acknowledged_directory,
                new_tokens=acknowledged_output_count,
                reveal_output=acknowledged_output_count != 4,
            )
            if acknowledged_report is None:
                raise GoldenPathError(
                    "acknowledged terminal report is absent"
                )
            acknowledged_wire, acknowledged_roots = (
                _acknowledged_terminal_facts(
                    acknowledged_directory,
                    output_count=acknowledged_output_count,
                    package_sha256=package_facts["package_sha256"],
                    representation_sha256=bytes.fromhex(
                        representation_sha256
                    ),
                    license_sha256=hashlib.sha256(
                        license_bytes
                    ).digest(),
                    raw_text=PROMPT.encode("utf-8"),
                    expected_tokens=ordinary_tokens,
                )
            )
            _verify_acknowledged_terminal_report(
                acknowledged_report,
                wire=acknowledged_wire,
                roots=acknowledged_roots,
                output_count=acknowledged_output_count,
                selection_before=(
                    "source-live"
                    if acknowledged_output_count == 4
                    else "absent"
                ),
                disposition="advanced",
                bootstrap_disposition=(
                    "already_selected"
                    if acknowledged_output_count == 4
                    else "created"
                ),
                source_disposition="advanced",
                target_call_count=acknowledged_output_count - 1,
                advanced_target_count=acknowledged_output_count - 1,
                output_disclosed=acknowledged_output_count != 4,
            )

            acknowledged_terminal_manifest = (
                _durable_directory_manifest(
                    acknowledged_directory
                )
            )
            if acknowledged_output_count == 4:
                prompt_path.write_bytes(
                    (PROMPT + "!").encode("utf-8")
                )
                _run_durable_text(
                    executable,
                    foreign_image,
                    foreign_package,
                    license_path,
                    prompt_path,
                    acknowledged_directory,
                    new_tokens=acknowledged_output_count,
                    reveal_output=True,
                    expect_success=False,
                    expected_error="DurableRequestMismatch",
                )
                prompt_path.write_bytes(PROMPT.encode("utf-8"))
                if (
                    _durable_directory_manifest(
                        acknowledged_directory
                    )
                    != acknowledged_terminal_manifest
                ):
                    raise GoldenPathError(
                        "foreign terminal input mutated durable state"
                    )
                acknowledged_retry = _run_durable_text(
                    executable,
                    foreign_image,
                    foreign_package,
                    license_path,
                    prompt_path,
                    acknowledged_directory,
                    new_tokens=acknowledged_output_count,
                    reveal_output=True,
                )
                if acknowledged_retry is None:
                    raise GoldenPathError(
                        "acknowledged terminal retry is absent"
                    )
                retry_wire, retry_roots = (
                    _acknowledged_terminal_facts(
                        acknowledged_directory,
                        output_count=acknowledged_output_count,
                        package_sha256=package_facts[
                            "package_sha256"
                        ],
                        representation_sha256=bytes.fromhex(
                            representation_sha256
                        ),
                        license_sha256=hashlib.sha256(
                            license_bytes
                        ).digest(),
                        raw_text=PROMPT.encode("utf-8"),
                        expected_tokens=ordinary_tokens,
                    )
                )
                _verify_acknowledged_terminal_report(
                    acknowledged_retry,
                    wire=retry_wire,
                    roots=retry_roots,
                    output_count=acknowledged_output_count,
                    selection_before="terminal",
                    disposition="already_terminal",
                    bootstrap_disposition=None,
                    source_disposition=None,
                    target_call_count=1,
                    advanced_target_count=0,
                    output_disclosed=True,
                )
                if (
                    _durable_directory_manifest(
                        acknowledged_directory
                    )
                    != acknowledged_terminal_manifest
                ):
                    raise GoldenPathError(
                        "acknowledged terminal retry changed state"
                    )

        equivalent_config_bytes = (
            b'{"dim":32,"hidden_dim":64,"num_layers":1,'
            b'"vocab_size":256,"num_heads":4,"head_dim":8,'
            b'"num_kv_heads":4,"rms_eps":1e-5,'
            b'"rope_theta":5e5,"tie_word_embeddings":false}\n'
        )
        ordinary_config.write_bytes(equivalent_config_bytes)
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
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
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
                config_input=equivalent_config_bytes,
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
            or retry_report.get("config_input_sha256")
            == initial_config_input_sha256
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

        unsupported_profile_package = root / "unsupported-profile.glpkg"
        unsupported_profile_package.write_bytes(
            _rewrite_package(
                package_facts,
                representation_facts,
                {"model_profile_id": 2},
            )
        )
        rerooted_tensor_package = root / "rerooted-tensor-inventory.glpkg"
        rerooted_tensor_package.write_bytes(
            _reroot_package(
                package_facts,
                representation_facts,
                "tensor_inventory_sha256",
            )
        )
        rerooted_conversion_package = (
            root / "rerooted-conversion-profile.glpkg"
        )
        rerooted_conversion_package.write_bytes(
            _reroot_package(
                package_facts,
                representation_facts,
                "conversion_profile_sha256",
            )
        )
        relabelled_conversion_package = (
            root / "relabelled-valid-conversion-profile.glpkg"
        )
        alternate_conversion_profile = _conversion_profile_sha256(32)
        if (
            alternate_conversion_profile
            == package_facts["conversion_profile_sha256"]
        ):
            raise GoldenPathError("alternate conversion profile did not change")
        relabelled_conversion_package.write_bytes(
            _rewrite_package(
                package_facts,
                representation_facts,
                {
                    "conversion_profile_sha256":
                        alternate_conversion_profile
                },
                recompute_model_content=True,
            )
        )
        for rejected_profile_package in (
            unsupported_profile_package,
            rerooted_tensor_package,
            rerooted_conversion_package,
            relabelled_conversion_package,
        ):
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
                    str(rejected_profile_package),
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
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
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
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
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
            "--experimental-profile",
            EXPERIMENTAL_MODEL_PROFILE,
            "--config",
            str(ordinary_config),
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
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(ordinary_config),
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

        invalid_config_inputs = {
            "empty-config": b"{}\n",
            "incomplete-config": b'{"num_attention_heads":4}\n',
            "malformed-config": b'{"hidden_size":32\n',
            "wrong-type-config": b'{"hidden_size":"32"}\n',
            "duplicate-config": b'{"hidden_size":32,"hidden_size":32}\n',
            "conflicting-config": (
                b'{"dim":32,"hidden_size":64}\n'
            ),
            "invalid-geometry-config": (
                b'{"hidden_size":32,"intermediate_size":64,'
                b'"num_hidden_layers":1,"vocab_size":256,'
                b'"num_attention_heads":3,"num_key_value_heads":1,'
                b'"rms_norm_eps":1e-5,"rope_theta":5e5,'
                b'"tie_word_embeddings":false}\n'
            ),
            "unknown-semantic-config": (
                b'{"hidden_size":32,"intermediate_size":64,'
                b'"num_hidden_layers":1,"vocab_size":256,'
                b'"num_attention_heads":4,"num_key_value_heads":4,'
                b'"rms_norm_eps":1e-5,"rope_theta":5e5,'
                b'"tie_word_embeddings":false,"hidden_act":"gelu"}\n'
            ),
            "unsupported-gqa-config": (
                b'{"hidden_size":32,"intermediate_size":64,'
                b'"num_hidden_layers":1,"vocab_size":256,'
                b'"num_attention_heads":4,"num_key_value_heads":1,'
                b'"rms_norm_eps":1e-5,"rope_theta":5e5,'
                b'"tie_word_embeddings":false}\n'
            ),
            "unsupported-tied-embeddings-config": (
                b'{"hidden_size":32,"intermediate_size":64,'
                b'"num_hidden_layers":1,"vocab_size":256,'
                b'"num_attention_heads":4,"num_key_value_heads":4,'
                b'"rms_norm_eps":1e-5,"rope_theta":5e5,'
                b'"tie_word_embeddings":true}\n'
            ),
        }
        for label, invalid_config_bytes in invalid_config_inputs.items():
            invalid_config_path = root / f"{label}.json"
            invalid_config_path.write_bytes(invalid_config_bytes)
            _assert_package_config_rejected(
                executable,
                ordinary_source,
                license_path,
                root,
                label,
                ("--config", str(invalid_config_path)),
            )

        tensor_mismatch_config = root / "tensor-mismatch-config.json"
        tensor_mismatch_config.write_bytes(
            b'{"dim":32,"hidden_dim":96,"num_layers":1,'
            b'"vocab_size":256,"num_heads":4,"head_dim":8,'
            b'"num_kv_heads":4,"rms_eps":1e-5,'
            b'"rope_theta":5e5,"tie_word_embeddings":false}\n'
        )
        tensor_mismatch_portable = root / "tensor-mismatch.glacier"
        tensor_mismatch_prepared = root / "tensor-mismatch.glrt"
        tensor_mismatch_package = root / "tensor-mismatch.glpkg"
        _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(tensor_mismatch_portable),
                str(tensor_mismatch_prepared),
                str(tensor_mismatch_package),
                "--license",
                str(license_path),
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(tensor_mismatch_config),
            ),
            expect_success=False,
        )
        if (
            tensor_mismatch_portable.exists()
            or tensor_mismatch_prepared.exists()
            or tensor_mismatch_package.exists()
        ):
            raise GoldenPathError(
                "tensor/config mismatch reached output publication"
            )

        oversized_config = root / "oversized-config.json"
        oversized_config.write_bytes(
            b'{"hidden_size":32,"padding":"'
            + b"x" * (1024 * 1024)
            + b'"}'
        )
        _assert_package_config_rejected(
            executable,
            ordinary_source,
            license_path,
            root,
            "oversized-config",
            ("--config", str(oversized_config)),
        )

        symlink_config = root / "config-link.json"
        symlink_config.symlink_to(ordinary_config)
        _assert_package_config_rejected(
            executable,
            ordinary_source,
            license_path,
            root,
            "symlink-config",
            ("--config", str(symlink_config)),
        )
        directory_config = root / "config-directory"
        directory_config.mkdir()
        _assert_package_config_rejected(
            executable,
            ordinary_source,
            license_path,
            root,
            "directory-config",
            ("--config", str(directory_config)),
        )
        fifo_config = root / "config-fifo"
        os.mkfifo(fifo_config)
        _assert_package_config_rejected(
            executable,
            ordinary_source,
            license_path,
            root,
            "fifo-config",
            ("--config", str(fifo_config)),
        )
        _assert_package_config_rejected(
            executable,
            ordinary_source,
            license_path,
            root,
            "missing-config-value",
            ("--config",),
        )
        _assert_package_config_rejected(
            executable,
            ordinary_source,
            license_path,
            root,
            "duplicate-config-option",
            (
                "--config",
                str(ordinary_config),
                "--config",
                str(ordinary_config),
            ),
        )

        aliased_config = root / "aliased-config.glacier"
        aliased_config_bytes = ordinary_config.read_bytes()
        aliased_config.write_bytes(aliased_config_bytes)
        aliased_prepared = root / "aliased-config.glrt"
        aliased_package = root / "aliased-config.glpkg"
        _run(
            (
                str(executable),
                "package-model",
                str(ordinary_source),
                str(aliased_config),
                str(aliased_prepared),
                str(aliased_package),
                "--license",
                str(license_path),
                "--experimental-profile",
                EXPERIMENTAL_MODEL_PROFILE,
                "--config",
                str(aliased_config),
            ),
            expect_success=False,
        )
        if (
            aliased_config.read_bytes() != aliased_config_bytes
            or aliased_prepared.exists()
            or aliased_package.exists()
        ):
            raise GoldenPathError("config/output alias mutated package outputs")

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
            "experimental_profile_cli_required": True,
            "unsupported_conversion_options_rejected_before_mutation": True,
            "undersized_tokenizer_vocabulary_rejected_before_mutation": True,
            "unsupported_model_geometry_rejected_before_mutation": True,
            "model_profile_root_independently_verified": True,
            "unsupported_model_profile_rejected": True,
            "strict_tensor_inventory_profile_verified": True,
            "tensor_inventory_runtime_binding_verified": True,
            "conversion_profile_runtime_binding_verified": True,
            "prepared_image_profile_binding_verified": True,
            "strict_tensor_rejections_preserved_output_namespace": True,
            "explicit_bounded_config_verified": True,
            "explicit_config_required": True,
            "canonical_config_retry_verified": True,
            "ambient_config_ignored": True,
            "invalid_config_admission_rejected_before_conversion": True,
            "config_tensor_mismatch_rejected_before_package_publication": True,
            "variable_eos_hit_verified": True,
            "variable_eos_miss_verified": True,
            "variable_eos_at_limit_verified": True,
            "variable_terminal_accounting_verified": True,
            "durable_eos_rejected_before_mutation": True,
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
            "durable_result_sink": True,
            "durable_direct_terminal": True,
            "durable_output_count": 1,
            "durable_acknowledged": True,
            "durable_acknowledged_output_range": [2, 64],
            "durable_acknowledged_capacities_verified": [1, 3, 63],
            "durable_acknowledged_fresh_process_continuation": True,
            "durable_acknowledged_count_bound_identity": True,
            "durable_acknowledged_independent_lineage_decode": True,
            "durable_acknowledged_output_matches_ordinary": True,
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
            _installed_clean_room_golden_path(
                arguments.executable,
                arguments.license,
            ),
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
