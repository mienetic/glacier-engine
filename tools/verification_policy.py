#!/usr/bin/env python3
"""Select bounded verification gates from a NUL-delimited Git path set."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import FrozenSet, Iterable, Optional, Sequence, Tuple, Union


RETAINED_TARGETS: Tuple[str, ...] = (
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-windows-gnu",
    "x86_64-freebsd",
)

LINUX_TARGETS: Tuple[str, ...] = RETAINED_TARGETS[0:2]
AARCH64_LINUX_TARGETS: Tuple[str, ...] = (RETAINED_TARGETS[1],)
WINDOWS_TARGETS: Tuple[str, ...] = (RETAINED_TARGETS[2],)
FREEBSD_TARGETS: Tuple[str, ...] = (RETAINED_TARGETS[3],)
POSIX_TARGETS: Tuple[str, ...] = LINUX_TARGETS + FREEBSD_TARGETS
MAXIMUM_SHEBANG_BYTES = 256

FULL_TARGET_STEPS: Tuple[str, ...] = (
    "install",
    "install-benchmarks",
    "test-compile",
)
FOCUSED_TARGET_STEPS: Tuple[str, ...] = (
    "profile-core-compile",
    "profile-cpu-compile",
    "profile-durable-compile",
    "profile-device-compile",
    "profile-host-tool-compile",
)
COMPLETE_COMPILE_TARGET_STEPS: Tuple[str, ...] = ("profile-complete-compile",)

GITHUB_CONTROL_PREFIXES = (
    ".github/workflows/",
    ".github/actions/",
)
GITHUB_CONTROL_PATHS = {
    ".github/dependabot.yml",
    ".github/dependabot.yaml",
    ".github/renovate.json",
    ".github/renovate.json5",
}

POLICY_CONTROL_PATHS = {
    "tools/verification_policy.py": frozenset(
        {
            "python-changed",
            "python-full",
            "verification-policy-focused",
        }
    ),
    "tools/verify.sh": frozenset(
        {
            "python-full",
            "shell-changed",
            "verification-policy-focused",
        }
    ),
    "tools/zig-with-ephemeral-cache.sh": frozenset({"python-full", "shell-changed"}),
    "tools/check-metal-fault-isolation.sh": frozenset(
        {"metal-native", "shell-changed"}
    ),
}

VERIFICATION_POLICY_FOCUSED_PATHS = {
    "tools/verification_policy.py",
    "tools/verify.sh",
    "bench/tests/test_local_verify.py",
    "bench/tests/test_verification_policy.py",
}

SHARED_CODE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".h",
    ".hh",
    ".hpp",
    ".m",
    ".metal",
    ".mm",
    ".rs",
    ".zig",
    ".zon",
}

PASSIVE_DATA_SUFFIXES = {
    ".bin",
    ".csv",
    ".json",
    ".jsonl",
    ".tsv",
    ".txt",
}

CODE_ROOTS = {
    "bench",
    "bindings",
    "examples",
    "include",
    "scripts",
    "src",
    "tests",
    "tools",
}

BUILD_CONTROL_PATHS = {
    "build.zig",
    "build.zig.zon",
    "cargo.lock",
    "cargo.toml",
    "cmakelists.txt",
    "makefile",
}

INTEROP_RUNTIME_FIXTURE_PATHS = {
    "examples/interop/fixtures/artifact_manifest_v1.hex",
    "examples/interop/fixtures/execution_plan_v1.hex",
    "examples/interop/fixtures/result_envelope_v1.hex",
}

BENCH_RUNTIME_DATA_PATHS = {
    "bench/eval-qwen2.5.ids",
    "bench/eval.txt",
    "bench/pair-prefill-natural-pp128.ids",
    "bench/pair-prefill-natural-pp512.ids",
    "bench/pair-prefill-natural-pp2048.ids",
    "bench/pair-prefill-natural-provenance.json",
    "bench/paired.example.json",
}

AARCH64_CPU_SOURCE_PATHS = {
    "src/backends/cpu/crc32_arm.c",
    "src/backends/cpu/int4_neon.c",
    "src/backends/cpu/progressive_int4_neon.c",
}

METAL_NATIVE_SOURCE_PATHS = {
    "src/backends/metal/native_observer.zig",
    "src/backends/metal/native_workload_report.zig",
    "src/backends/metal/shaders/dequant.metal",
    "src/backends/metal/shaders/matmul.metal",
    "src/backends/metal/shim.m",
    "tests/metal_correctness.zig",
    "tests/native_metal_allocation.zig",
    "tests/native_metal_observation.zig",
    "tests/support/metal_fault_control.zig",
    "examples/native_metal_cancellation_storm_report.zig",
    "examples/native_metal_disruption_report.zig",
    "examples/native_metal_inflight_process_kill_worker.zig",
    "bench/native_metal_supervisor_recovery_death_campaign.py",
    "bench/tests/test_native_metal_supervisor_recovery_death_protocol.py",
    "examples/native_metal_observation.zig",
    "examples/native_metal_soak_worker.zig",
    "examples/native_metal_workload_report.zig",
    "bench/metal_kernel.zig",
}

METAL_PORTABLE_SOURCE_PATHS = {
    "src/core/native_metal_inflight_process_kill_ready.zig",
    "src/backends/metal/allocation_adapter.zig",
    "src/backends/metal/backend.zig",
}

CORE_CONTRACT_PATHS = {
    "src/ffi/model_contract_c.zig",
    "include/glacier/model_contract.h",
    "tests/model_contract_c_consumer.c",
    "tests/model_contract_cpp_consumer.cpp",
}

SHARED_RUNTIME_COMPLETE_PATHS = {
    "src/model/package_manifest.zig",
    "src/prepared_text_handoff_archive.zig",
    "src/prepared_text_input_archive.zig",
    "src/prepared_text_durable_handoff.zig",
    "src/continuation_live_restart.zig",
}

DURABLE_RUNTIME_PROFILE_PATHS = {
    "examples/action_outbox_file_recovery.zig",
    "examples/action_outbox_store.zig",
    "examples/continuation_object_sweep_file.zig",
    "examples/continuation_object_payload_file.zig",
    "examples/continuation_live_restart.zig",
    "examples/prepared_text_live_restart.zig",
    "examples/continuation_checkpoint_file.zig",
    "bench/action_outbox_file_worker.zig",
    "bench/continuation_object_sweep_file_worker.zig",
    "bench/continuation_object_payload_file_worker.zig",
    "bench/continuation_live_restart_worker.zig",
    "bench/prepared_text_live_restart_worker.zig",
    "bench/continuation_checkpoint_file_worker.zig",
}

PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS = {
    "src/prepared_text_acknowledged_delivery.zig",
    "src/prepared_text_acknowledged_progress.zig",
    "src/prepared_text_acknowledged_restore.zig",
    "src/prepared_text_committed_output_file.zig",
    "src/prepared_text_direct_terminal.zig",
    "src/prepared_text_direct_terminal_output.zig",
    "src/prepared_text_durable_runtime.zig",
    "src/prepared_text_result_sink.zig",
    "src/prepared_text_result_sink_file.zig",
    "src/prepared_text_source_recovery.zig",
    "src/prepared_text_source_lease.zig",
    "src/prepared_text_terminal_equivalence.zig",
    "src/prepared_text_terminal_source_recovery.zig",
}

PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS = {
    "src/prepared_text_direct_terminal.zig",
    "src/prepared_text_direct_terminal_output.zig",
    "src/prepared_text_durable_runtime.zig",
    "src/prepared_text_source_lease.zig",
    "src/prepared_text_terminal_equivalence.zig",
    "src/prepared_text_terminal_source_recovery.zig",
}

PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_DEPENDENCY_PATHS = {
    "src/core/continuation_checkpoint_file.zig",
    "src/prepared_text_checkpoint.zig",
}

PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_SMOKE_PATHS = {
    "bench/prepared_text_direct_terminal_recovery.py",
    "bench/tests/test_prepared_text_direct_terminal_recovery.py",
}

PREPARED_TEXT_RECOVERY_CAMPAIGN_PATHS = {
    "bench/prepared_text_package.py",
    "bench/prepared_text_recovery_worker.zig",
    "bench/prepared_text_recovery_campaign.py",
    "bench/tests/test_prepared_text_package.py",
    "bench/tests/test_prepared_text_recovery_campaign.py",
}

PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS = {
    "src/prepared_text_committed_output.zig",
    "src/prepared_text_committed_output_file.zig",
    "src/cli/prepared_text_result_inspector.zig",
    "bench/prepared_text_committed_output.py",
    "bench/tests/test_prepared_text_committed_output.py",
}

RUNTIME_IMAGE_DURABLE_RECOVERY_CAMPAIGN_PATHS = {
    "bench/runtime_image_durable_worker.zig",
    "bench/runtime_image_durable_recovery.py",
    "bench/tests/test_runtime_image_durable_recovery.py",
}

MODEL_CONVERSION_DURABLE_RECOVERY_CAMPAIGN_PATHS = {
    "bench/model_conversion_durable_worker.zig",
    "bench/model_conversion_durable_recovery.py",
    "bench/tests/test_model_conversion_durable_recovery.py",
}

TEXT_RUNTIME_GOLDEN_PATH_PATHS = {
    "bench/prepared_text_raw_input.py",
    "bench/tests/test_prepared_text_raw_input.py",
}

PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS = {
    "src/bounded_file_input.zig",
    "src/cli/model_package.zig",
    "src/cli/text_run.zig",
    "src/model/package_producer.zig",
    "bench/prepared_text_package.py",
    "bench/tests/test_prepared_text_package.py",
    "bench/text_runtime_golden_path.py",
}

WORKLOAD_REPORT_PORTABLE_PATHS = {
    "src/core/native_metal_supervisor_recovery_death_report.zig",
    "src/core/native_workload_campaign_manifest.zig",
    "src/core/native_workload_report.zig",
    "src/core/native_workload_store_fault_report.zig",
    "examples/native_metal_supervisor_recovery_death_report.zig",
    "examples/native_workload_report.zig",
    "examples/native_workload_store_fault_report.zig",
    "bench/native_metal_supervisor_recovery_death_report.py",
    "bench/native_workload_campaign.py",
    "bench/native_workload_report.py",
    "bench/native_workload_store_fault_report.py",
    "bench/tests/test_native_workload_campaign.py",
    "bench/tests/test_native_workload_report.py",
    "bench/tests/test_native_workload_store_fault_report.py",
    "bench/tests/test_native_metal_supervisor_recovery_death_report.py",
}

WORKLOAD_STORE_FAULT_POSIX_PATHS = {
    "bench/native_metal_soak_report.py",
    "bench/native_workload_store_fault_campaign.py",
    "bench/tests/test_native_metal_soak_report.py",
    "bench/tests/test_native_workload_store_fault_campaign.py",
}

WORKLOAD_STORE_FAULT_METAL_PATHS = {
    "bench/native_metal_soak_report.py",
    "bench/tests/test_native_metal_soak_report.py",
}


@dataclass(frozen=True)
class PathDecision:
    path: str
    reason: str
    flags: FrozenSet[str]
    targets: Tuple[str, ...]
    target_steps: Tuple[str, ...] = FULL_TARGET_STEPS


@dataclass(frozen=True)
class TargetBuildPlan:
    target: str
    steps: Tuple[str, ...]


@dataclass(frozen=True)
class VerificationPlan:
    paths: Tuple[str, ...]
    decisions: Tuple[PathDecision, ...]
    flags: FrozenSet[str]
    targets: Tuple[str, ...]
    target_plans: Tuple[TargetBuildPlan, ...]

    def requires(self, flag: str) -> bool:
        return flag in self.flags


def _validated_path(path: str) -> str:
    if not path:
        raise ValueError("empty paths are not valid Git paths")
    if "\0" in path:
        raise ValueError("Git paths must not contain NUL bytes")
    if os.path.isabs(path):
        raise ValueError("affected paths must be relative to the repository")
    components = path.split("/")
    if any(component in {"", ".", ".."} for component in components):
        raise ValueError("affected paths must be normalized repository paths")
    return path


def _decode_paths0(raw: bytes, source: str) -> Tuple[str, ...]:
    if raw and not raw.endswith(b"\0"):
        raise ValueError(source + " is not NUL terminated")
    decoded = [os.fsdecode(item) for item in raw.split(b"\0") if item]
    return tuple(decoded)


def read_paths0(path: Union[os.PathLike, str]) -> Tuple[str, ...]:
    return _decode_paths0(Path(path).read_bytes(), "the affected path stream")


def write_paths0(paths: Sequence[str], output: Union[os.PathLike, str]) -> None:
    normalized = tuple(
        sorted({_validated_path(path) for path in paths}, key=os.fsencode)
    )
    Path(output).write_bytes(b"".join(os.fsencode(path) + b"\0" for path in normalized))


def collect_git_paths(
    merge_base: str,
    repository: Union[os.PathLike, str] = ".",
) -> Tuple[str, ...]:
    """Collect each Git state separately so one state cannot mask another."""

    if (
        not isinstance(merge_base, str)
        or re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", merge_base) is None
    ):
        raise ValueError("merge base must be a full Git commit object ID")
    commands = (
        (
            "git",
            "diff",
            "--no-ext-diff",
            "--name-only",
            "--no-renames",
            "-z",
            merge_base,
            "HEAD",
            "--",
        ),
        (
            "git",
            "diff",
            "--cached",
            "--no-ext-diff",
            "--name-only",
            "--no-renames",
            "-z",
            "HEAD",
            "--",
        ),
        (
            "git",
            "diff",
            "--no-ext-diff",
            "--name-only",
            "--no-renames",
            "-z",
            "--",
        ),
        (
            "git",
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
        ),
    )
    paths = []
    for command in commands:
        completed = subprocess.run(
            command,
            cwd=repository,
            check=True,
            stdout=subprocess.PIPE,
        )
        paths.extend(
            _decode_paths0(
                completed.stdout,
                "Git path output from " + " ".join(command[:3]),
            )
        )
    return tuple(sorted({_validated_path(path) for path in paths}, key=os.fsencode))


def _is_documentation_or_metadata(path: str) -> bool:
    lower = path.lower()
    name = lower.rsplit("/", 1)[-1]
    suffix = Path(lower).suffix
    if lower.startswith("docs/"):
        return True
    if lower.startswith(".github/"):
        return True
    if lower.startswith("assets/"):
        return True
    if suffix in {".adoc", ".md", ".mdx", ".rst"}:
        return True
    if name in {
        ".editorconfig",
        ".gitattributes",
        ".gitignore",
        "authors",
        "changelog",
        "code_of_conduct",
        "contributing",
        "governance",
        "license",
        "notice",
        "readme",
        "security",
    }:
        return True
    return False


def _has_platform_token(path: str, name: str) -> bool:
    lower = path.lower()
    components = lower.split("/")
    return name in components[:-1] or _has_basename_token(path, name)


def _has_basename_token(path: str, name: str) -> bool:
    lower = path.lower()
    components = lower.split("/")
    stem = Path(components[-1]).stem
    basename_tokens = tuple(token for token in re.split(r"[^a-z0-9]+", stem) if token)
    return name in basename_tokens


def _platform_requirements(
    path: str,
) -> Tuple[FrozenSet[str], Tuple[str, ...]]:
    flags = set()
    selected_targets = set()
    if _has_platform_token(path, "darwin") or _has_platform_token(path, "macos"):
        flags.add("darwin-native")
    if _has_platform_token(path, "windows"):
        selected_targets.update(WINDOWS_TARGETS)
    if _has_platform_token(path, "linux"):
        selected_targets.update(LINUX_TARGETS)
    if _has_platform_token(path, "freebsd"):
        selected_targets.update(FREEBSD_TARGETS)
    if _has_platform_token(path, "posix") or _has_platform_token(path, "unix"):
        selected_targets.update(POSIX_TARGETS)
        flags.add("darwin-native")
    targets = tuple(target for target in RETAINED_TARGETS if target in selected_targets)
    return frozenset(flags), targets


def _is_github_control(path: str) -> bool:
    lower = path.lower()
    return lower in GITHUB_CONTROL_PATHS or lower.startswith(GITHUB_CONTROL_PREFIXES)


def _compiled_flags(suffix: str) -> FrozenSet[str]:
    flags = {"native-full", "python-full"}
    if suffix == ".rs":
        flags.add("rust-native")
    return frozenset(flags)


def _decision_for_path(path: str) -> PathDecision:
    lower = path.lower()
    suffix = Path(lower).suffix
    first_component = lower.split("/", 1)[0]

    if (
        first_component in CODE_ROOTS
        and path != lower
        and suffix in SHARED_CODE_SUFFIXES
    ):
        return PathDecision(
            path,
            "non-canonical code path; conservatively validate every target",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
        )

    policy_flags = POLICY_CONTROL_PATHS.get(lower)
    if policy_flags is not None:
        policy_targets = (
            ()
            if lower
            in {
                "tools/verification_policy.py",
                "tools/verify.sh",
                "tools/zig-with-ephemeral-cache.sh",
            }
            else RETAINED_TARGETS
        )
        return PathDecision(
            path,
            (
                "verification control changed; validate shell and Python "
                "integration without compiling unrelated targets"
                if not policy_targets
                else "verification control changed; validate every retained target"
            ),
            policy_flags,
            policy_targets,
        )

    if lower in VERIFICATION_POLICY_FOCUSED_PATHS:
        return PathDecision(
            path,
            "verification policy regression suite changed",
            frozenset(
                {
                    "python-changed",
                    "python-full",
                    "verification-policy-focused",
                }
            ),
            (),
        )

    if _is_github_control(path):
        flags = {"python-full"}
        if suffix == ".py":
            flags.add("python-changed")
        if suffix == ".sh":
            flags.add("shell-changed")
        return PathDecision(
            path,
            (
                "GitHub execution control changed; run static policy "
                "coverage and defer exhaustive target execution"
            ),
            frozenset(flags),
            (),
        )

    if lower == "examples/interop/rust_verify.rs":
        return PathDecision(
            path,
            "native Rust contract consumer changed",
            frozenset({"rust-native"}),
            (),
        )

    if lower in WORKLOAD_STORE_FAULT_POSIX_PATHS:
        store_fault_flags = {
            "python-changed",
            "workload-store-fault-posix",
        }
        if lower in WORKLOAD_STORE_FAULT_METAL_PATHS:
            store_fault_flags.update({"metal-native", "python-full"})
        return PathDecision(
            path,
            (
                "POSIX workload campaign store, hard fault runner, "
                "or focused recovery test changed"
            ),
            frozenset(store_fault_flags),
            (),
        )

    if path in WORKLOAD_REPORT_PORTABLE_PATHS:
        report_flags = {"workload-report-portable"}
        if suffix == ".py":
            report_flags.add("python-changed")
        return PathDecision(
            path,
            (
                "portable workload evidence codec, reference runner, "
                "independent verifier, or focused test changed"
            ),
            frozenset(report_flags),
            (),
        )

    if lower in INTEROP_RUNTIME_FIXTURE_PATHS:
        return PathDecision(
            path,
            "runtime interop fixture changed; replay native consumers",
            frozenset({"python-full", "rust-native"}),
            (),
        )

    if lower in BENCH_RUNTIME_DATA_PATHS:
        return PathDecision(
            path,
            "benchmark runtime data changed; replay Python consumers",
            frozenset({"python-full"}),
            (),
        )

    if lower == "bench/lane4_process_info.swift":
        return PathDecision(
            path,
            "Darwin ProcessInfo probe changed; type-check Swift and replay its verifier",
            frozenset({"darwin-swift", "python-full"}),
            (),
        )

    if path in AARCH64_CPU_SOURCE_PATHS:
        return PathDecision(
            path,
            "AArch64 CPU kernel changed; validate Linux and native Darwin branches",
            frozenset(
                {
                    "darwin-aarch64-native",
                    "native-full",
                    "python-full",
                }
            ),
            AARCH64_LINUX_TARGETS,
            (
                "profile-cpu-compile",
                "profile-host-tool-compile",
            ),
        )

    if path in METAL_PORTABLE_SOURCE_PATHS:
        return PathDecision(
            path,
            "portable Metal public surface changed; compile every retained target and run native Metal",
            _compiled_flags(suffix) | frozenset({"metal-native"}),
            RETAINED_TARGETS,
            ("profile-device-compile",),
        )

    if path in METAL_NATIVE_SOURCE_PATHS:
        native_metal_flags = {"metal-native"}
        if suffix == ".py":
            native_metal_flags.update({"python-changed", "python-full"})
        return PathDecision(
            path,
            "audited native Metal implementation or consumer changed",
            frozenset(native_metal_flags),
            (),
        )

    if path in CORE_CONTRACT_PATHS:
        return PathDecision(
            path,
            "portable core language-contract boundary changed",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
            ("profile-core-compile",),
        )

    if path in PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_DEPENDENCY_PATHS:
        dependency_steps = (
            COMPLETE_COMPILE_TARGET_STEPS
            if path == "src/core/continuation_checkpoint_file.zig"
            else ("profile-durable-compile",)
        )
        return PathDecision(
            path,
            "shared checkpoint dependency of direct-terminal recovery changed",
            _compiled_flags(suffix)
            | frozenset(
                {
                    "prepared-text-delivery-focused",
                    "prepared-text-direct-terminal-smoke-focused",
                }
            ),
            RETAINED_TARGETS,
            dependency_steps,
        )

    if (
        path in PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS
        and path not in PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS
    ):
        delivery_flags = set(_compiled_flags(suffix))
        delivery_flags.add("prepared-text-delivery-focused")
        if path in PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS:
            delivery_flags.add("prepared-text-direct-terminal-smoke-focused")
        return PathDecision(
            path,
            "prepared-text acknowledged or direct delivery changed",
            frozenset(delivery_flags),
            RETAINED_TARGETS,
            ("profile-durable-compile",),
        )

    if path in SHARED_RUNTIME_COMPLETE_PATHS:
        return PathDecision(
            path,
            "shared durable runtime producer changed",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
            COMPLETE_COMPILE_TARGET_STEPS,
        )

    if path in DURABLE_RUNTIME_PROFILE_PATHS:
        return PathDecision(
            path,
            "durable runtime or process-recovery consumer changed",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
            ("profile-durable-compile",),
        )

    if path in PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS:
        inspector_flags = (
            {"python-full"} if suffix == ".py" else set(_compiled_flags(suffix))
        )
        inspector_flags.add("prepared-text-inspector-focused")
        if path in PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS:
            inspector_flags.add("prepared-text-delivery-focused")
        if suffix == ".py":
            inspector_flags.add("python-changed")
        if suffix == ".py":
            inspector_targets: Tuple[str, ...] = ()
            inspector_steps = FULL_TARGET_STEPS
        elif path.startswith("src/cli/"):
            inspector_targets = RETAINED_TARGETS
            inspector_steps = ("profile-host-tool-compile",)
        elif path == "src/prepared_text_committed_output_file.zig":
            inspector_targets = RETAINED_TARGETS
            inspector_steps = ("profile-durable-compile",)
        else:
            inspector_targets = RETAINED_TARGETS
            inspector_steps = FULL_TARGET_STEPS
        return PathDecision(
            path,
            "prepared-text committed-output inspector or oracle changed",
            frozenset(inspector_flags),
            inspector_targets,
            inspector_steps,
        )

    if path in PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_SMOKE_PATHS:
        return PathDecision(
            path,
            "prepared-text direct-terminal process-death smoke changed",
            frozenset(
                {
                    "prepared-text-direct-terminal-smoke-focused",
                    "python-changed",
                    "python-full",
                }
            ),
            (),
        )

    if lower in PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS:
        package_text_flags = {"prepared-text-package-text-run-focused"}
        if suffix == ".py":
            package_text_flags.add("python-changed")
        package_text_targets = RETAINED_TARGETS if suffix == ".zig" else ()
        package_text_steps = (
            ("profile-host-tool-compile",) if suffix == ".zig" else FULL_TARGET_STEPS
        )
        return PathDecision(
            path,
            "ordinary model package producer, admission, or focused oracle changed",
            frozenset(package_text_flags),
            package_text_targets,
            package_text_steps,
        )

    if path in PREPARED_TEXT_RECOVERY_CAMPAIGN_PATHS:
        recovery_flags = (
            {"python-full"} if suffix == ".py" else set(_compiled_flags(suffix))
        )
        recovery_flags.add("prepared-text-recovery-focused")
        if suffix == ".py":
            recovery_flags.add("python-changed")
        recovery_targets = () if suffix == ".py" else POSIX_TARGETS
        recovery_steps = (
            FULL_TARGET_STEPS if suffix == ".py" else ("profile-durable-compile",)
        )
        return PathDecision(
            path,
            "prepared-text real process-death campaign changed",
            frozenset(recovery_flags),
            recovery_targets,
            recovery_steps,
        )

    if path in RUNTIME_IMAGE_DURABLE_RECOVERY_CAMPAIGN_PATHS:
        recovery_flags = set(_compiled_flags(suffix))
        if suffix == ".py":
            recovery_flags.add("python-changed")
        return PathDecision(
            path,
            "runtime-image durable publication process-death campaign changed",
            frozenset(recovery_flags),
            POSIX_TARGETS,
            ("profile-durable-compile",),
        )

    if path in MODEL_CONVERSION_DURABLE_RECOVERY_CAMPAIGN_PATHS:
        recovery_flags = set(_compiled_flags(suffix))
        if suffix == ".py":
            recovery_flags.add("python-changed")
        return PathDecision(
            path,
            "model-conversion durable publication process-death campaign changed",
            frozenset(recovery_flags),
            POSIX_TARGETS,
            ("profile-durable-compile",),
        )

    if lower in TEXT_RUNTIME_GOLDEN_PATH_PATHS:
        return PathDecision(
            path,
            "raw-text identity model or composed native golden path changed",
            frozenset(
                {
                    "native-full",
                    "python-changed",
                    "python-full",
                }
            ),
            (),
        )

    if (
        path != "src/core/root.zig"
        and path.startswith("src/core/")
        and Path(path).suffix == ".zig"
    ):
        return PathDecision(
            path,
            "portable core implementation changed",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
            COMPLETE_COMPILE_TARGET_STEPS,
        )

    if (path.startswith("src/backends/cpu/") or path.startswith("src/model/")) and Path(
        path
    ).suffix == ".zig":
        return PathDecision(
            path,
            "CPU runtime or model implementation changed",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
            COMPLETE_COMPILE_TARGET_STEPS,
        )

    if path.startswith("src/cli/") and Path(path).suffix == ".zig":
        return PathDecision(
            path,
            "CLI or retained host inspector changed",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
            ("profile-host-tool-compile",),
        )

    if suffix == ".py":
        python_flags = {"python-changed", "python-full"}
        if lower in {
            "bench/native_environment_admission.py",
            "bench/native_metal_cancellation_storm_report.py",
            "bench/native_metal_disruption_report.py",
            "bench/native_metal_inflight_process_kill_report.py",
            "bench/native_metal_readiness.py",
            "bench/native_metal_soak_report.py",
            "bench/native_metal_workload_report.py",
            "bench/tests/test_native_environment_admission.py",
            "bench/tests/test_native_metal_cancellation_storm_report.py",
            "bench/tests/test_native_metal_disruption_report.py",
            "bench/tests/test_native_metal_inflight_process_kill_report.py",
            "bench/tests/test_native_metal_soak_protocol.py",
            "bench/tests/test_native_metal_soak_report.py",
            "bench/tests/test_native_metal_workload_report.py",
        }:
            python_flags.add("metal-native")
        return PathDecision(
            path,
            "Python verifier, harness, or test changed",
            frozenset(python_flags),
            (),
        )

    if suffix == ".sh":
        return PathDecision(
            path,
            "shell tooling changed; check each changed script",
            frozenset({"shell-changed"}),
            (),
        )

    if _is_documentation_or_metadata(path):
        return PathDecision(
            path,
            "documentation or repository metadata; the quick gates cover it",
            frozenset(),
            (),
        )

    if suffix in PASSIVE_DATA_SUFFIXES and (
        lower.startswith("bench/results/")
        or lower.startswith("bench/fixtures/")
        or lower.startswith("tests/fixtures/")
    ):
        return PathDecision(
            path,
            "verification fixture or retained result changed",
            frozenset({"python-full"}),
            (),
        )

    if suffix == ".metal":
        return PathDecision(
            path,
            "unclassified Metal shader; run native Metal and fail closed",
            _compiled_flags(suffix) | frozenset({"metal-native"}),
            RETAINED_TARGETS,
        )

    if suffix in SHARED_CODE_SUFFIXES and (
        path.startswith("src/backends/metal/")
        or (
            first_component in {"bench", "examples", "tests"}
            and _has_basename_token(path, "metal")
        )
    ):
        return PathDecision(
            path,
            "unclassified Metal code path; run native Metal and fail closed",
            _compiled_flags(suffix) | frozenset({"metal-native"}),
            RETAINED_TARGETS,
        )

    special_flags = set()
    platform_flags, platform_targets = _platform_requirements(path)
    special_flags.update(platform_flags)
    if platform_targets:
        special_flags.update(_compiled_flags(suffix))
    if (special_flags or platform_targets) and suffix == ".rs":
        special_flags.add("rust-native")
    if special_flags or platform_targets:
        return PathDecision(
            path,
            "platform-specific runtime or backend code changed",
            frozenset(special_flags),
            platform_targets,
        )

    if lower in BUILD_CONTROL_PATHS:
        build_flags = {"native-full", "python-full"}
        if lower in {"build.zig", "build.zig.zon"}:
            build_flags.add("metal-native")
        return PathDecision(
            path,
            "build or package control changed; validate every retained target",
            frozenset(build_flags),
            RETAINED_TARGETS,
        )

    if suffix in SHARED_CODE_SUFFIXES:
        return PathDecision(
            path,
            "shared compiled code changed; validate every retained target",
            _compiled_flags(suffix),
            RETAINED_TARGETS,
        )

    if first_component in CODE_ROOTS:
        return PathDecision(
            path,
            "unknown code-tree input changed; conservatively validate every target",
            frozenset({"native-full", "python-full"}),
            RETAINED_TARGETS,
        )

    return PathDecision(
        path,
        "unknown repository input; conservatively validate every target",
        frozenset({"native-full", "python-full"}),
        RETAINED_TARGETS,
    )


def _validated_decision_steps(
    decision: PathDecision,
) -> Tuple[str, ...]:
    steps = decision.target_steps
    if steps in (
        FULL_TARGET_STEPS,
        COMPLETE_COMPILE_TARGET_STEPS,
    ):
        return steps
    if (
        not steps
        or len(set(steps)) != len(steps)
        or any(step not in FOCUSED_TARGET_STEPS for step in steps)
        or tuple(step for step in FOCUSED_TARGET_STEPS if step in steps) != steps
    ):
        raise ValueError(
            "path decision has an invalid target-step plan: " + decision.path
        )
    return steps


def _build_target_plans(
    decisions: Sequence[PathDecision],
) -> Tuple[TargetBuildPlan, ...]:
    selected_steps = {target: set() for target in RETAINED_TARGETS}
    full_targets = set()
    complete_compile_targets = set()
    for decision in decisions:
        if not decision.targets:
            continue
        steps = _validated_decision_steps(decision)
        for target in decision.targets:
            if target not in selected_steps:
                raise ValueError("path decision selected an unknown target: " + target)
            if steps == FULL_TARGET_STEPS:
                full_targets.add(target)
            elif steps == COMPLETE_COMPILE_TARGET_STEPS:
                complete_compile_targets.add(target)
            else:
                selected_steps[target].update(steps)

    plans = []
    for target in RETAINED_TARGETS:
        if target in full_targets:
            plans.append(TargetBuildPlan(target, FULL_TARGET_STEPS))
            continue
        if target in complete_compile_targets:
            plans.append(
                TargetBuildPlan(
                    target,
                    COMPLETE_COMPILE_TARGET_STEPS,
                )
            )
            continue
        steps = tuple(
            step for step in FOCUSED_TARGET_STEPS if step in selected_steps[target]
        )
        if steps:
            plans.append(TargetBuildPlan(target, steps))
    return tuple(plans)


def classify_paths(paths: Iterable[str]) -> VerificationPlan:
    unique_paths = {_validated_path(path) for path in paths}
    ordered_paths = tuple(sorted(unique_paths, key=os.fsencode))
    decisions = tuple(_decision_for_path(path) for path in ordered_paths)

    flags = frozenset(flag for decision in decisions for flag in decision.flags)
    target_plans = _build_target_plans(decisions)
    targets = tuple(target_plan.target for target_plan in target_plans)
    return VerificationPlan(
        ordered_paths,
        decisions,
        flags,
        targets,
        target_plans,
    )


def _gate_names(decision: PathDecision) -> Tuple[str, ...]:
    names = ["quick"]
    for flag, label in (
        ("python-changed", "python/changed-syntax"),
        ("python-full", "python/full-suite"),
        ("shell-changed", "shell/changed-syntax"),
        ("rust-native", "interop/rust"),
        ("native-full", "native/releasesafe-suite"),
        ("darwin-native", "native/darwin"),
        ("darwin-aarch64-native", "native/darwin-aarch64"),
        ("darwin-swift", "native/darwin-swift"),
        ("metal-native", "native/metal"),
        ("prepared-text-delivery-focused", "native/prepared-text-delivery"),
        (
            "prepared-text-direct-terminal-smoke-focused",
            "native/prepared-text-direct-terminal-smoke",
        ),
        ("prepared-text-inspector-focused", "native/prepared-text-inspector"),
        (
            "prepared-text-package-text-run-focused",
            "native/prepared-text-package-text-run",
        ),
        ("prepared-text-recovery-focused", "native/prepared-text-recovery"),
        ("verification-policy-focused", "python/verification-policy"),
        ("workload-report-portable", "portable/workload-report"),
        ("workload-store-fault-posix", "native/workload-store-fault"),
    ):
        if flag in decision.flags:
            names.append(label)
    target_step_label = "+".join(decision.target_steps)
    names.extend(
        "portability/" + target + "/" + target_step_label for target in decision.targets
    )
    return tuple(names)


def print_report(plan: VerificationPlan) -> None:
    print("Affected paths and reasons:")
    if not plan.decisions:
        print("  (none; quick gates only)")
    for decision in plan.decisions:
        print("  PATH " + json.dumps(decision.path, ensure_ascii=True))
        print("    reason: " + decision.reason)
        print("    gates: " + ", ".join(_gate_names(decision)))

    selected_gates = ["quick"]
    for flag, label in (
        ("python-changed", "python/changed-syntax"),
        ("python-full", "python/full-suite"),
        ("shell-changed", "shell/changed-syntax"),
        ("rust-native", "interop/rust"),
        ("native-full", "native/releasesafe-suite"),
        ("darwin-native", "native/darwin"),
        ("darwin-aarch64-native", "native/darwin-aarch64"),
        ("darwin-swift", "native/darwin-swift"),
        ("metal-native", "native/metal"),
        ("prepared-text-delivery-focused", "native/prepared-text-delivery"),
        (
            "prepared-text-direct-terminal-smoke-focused",
            "native/prepared-text-direct-terminal-smoke",
        ),
        ("prepared-text-inspector-focused", "native/prepared-text-inspector"),
        (
            "prepared-text-package-text-run-focused",
            "native/prepared-text-package-text-run",
        ),
        ("prepared-text-recovery-focused", "native/prepared-text-recovery"),
        ("verification-policy-focused", "python/verification-policy"),
        ("workload-report-portable", "portable/workload-report"),
        ("workload-store-fault-posix", "native/workload-store-fault"),
    ):
        if plan.requires(flag):
            selected_gates.append(label)
    print("Selected gates: " + ", ".join(selected_gates))
    if plan.target_plans:
        print("Selected target plans:")
        for target_plan in plan.target_plans:
            print("  " + target_plan.target + ": " + ", ".join(target_plan.steps))
    else:
        print("Selected target plans: (none)")


def write_flags(plan: VerificationPlan, output: Union[os.PathLike, str]) -> None:
    flags = ["quick"]
    flags.extend(sorted(plan.flags))
    Path(output).write_text("".join(flag + "\n" for flag in flags), encoding="utf-8")


def write_targets(targets: Sequence[str], output: Union[os.PathLike, str]) -> None:
    if len(set(targets)) != len(targets) or any(
        target not in RETAINED_TARGETS for target in targets
    ):
        raise ValueError("target plan is not a unique retained-target subset")
    ordered_targets = tuple(target for target in RETAINED_TARGETS if target in targets)
    if tuple(targets) != ordered_targets:
        raise ValueError("target plan is not in retained-target order")
    Path(output).write_text(
        "".join(target + "\n" for target in ordered_targets),
        encoding="ascii",
    )


def write_target_steps(
    target_plans: Sequence[TargetBuildPlan],
    output: Union[os.PathLike, str],
) -> None:
    targets = tuple(target_plan.target for target_plan in target_plans)
    if (
        len(set(targets)) != len(targets)
        or any(target not in RETAINED_TARGETS for target in targets)
        or targets != tuple(target for target in RETAINED_TARGETS if target in targets)
    ):
        raise ValueError("target-step plan is not a unique retained-target subset")

    records = []
    for target_plan in target_plans:
        decision = PathDecision(
            path="<target-plan>",
            reason="serialized target plan",
            flags=frozenset(),
            targets=(target_plan.target,),
            target_steps=target_plan.steps,
        )
        steps = _validated_decision_steps(decision)
        for step in steps:
            records.append(target_plan.target + " " + step + "\n")
    Path(output).write_text("".join(records), encoding="ascii")


def check_changed_python(paths: Sequence[str]) -> None:
    for path in paths:
        if Path(path).suffix.lower() != ".py" or not Path(path).is_file():
            continue
        # Compile bytes directly so Python honors PEP 263 encoding cookies
        # without importing the stdlib ``tokenize`` module. Executing this
        # policy as ``tools/verification_policy.py`` puts ``tools/`` first on
        # sys.path, where the repository's tokenizer CLI would otherwise
        # shadow that stdlib module.
        compile(Path(path).read_bytes(), path, "exec", dont_inherit=True)


def _shell_syntax_command(path: Path) -> Tuple[str, ...]:
    with path.open("rb") as source:
        first_line = source.readline(MAXIMUM_SHEBANG_BYTES + 1)
    if len(first_line) > MAXIMUM_SHEBANG_BYTES:
        raise ValueError(str(path) + " has a shebang outside the retained byte bound")
    try:
        shebang = first_line.rstrip(b"\r\n").decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError(str(path) + " has a non-ASCII shebang") from error
    interpreters = {
        "#!/bin/sh": "sh",
        "#!/usr/bin/sh": "sh",
        "#!/usr/bin/env sh": "sh",
        "#!/usr/bin/env -S sh": "sh",
        "#!/bin/bash": "bash",
        "#!/usr/bin/bash": "bash",
        "#!/usr/bin/env bash": "bash",
        "#!/usr/bin/env -S bash": "bash",
    }
    try:
        interpreter = interpreters[shebang]
    except KeyError as error:
        raise ValueError(
            str(path)
            + " must declare a retained sh or bash shebang without extra arguments"
        ) from error
    return (interpreter, "-n", str(path.resolve()))


def check_changed_shell(paths: Sequence[str]) -> None:
    for path in paths:
        if Path(path).suffix.lower() != ".sh" or not Path(path).is_file():
            continue
        subprocess.run(
            _shell_syntax_command(Path(path)),
            check=True,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--paths0", required=True)
    plan_parser.add_argument("--flags", required=True)
    plan_parser.add_argument("--targets", required=True)
    plan_parser.add_argument("--target-steps", required=True)

    python_parser = subparsers.add_parser("python-syntax")
    python_parser.add_argument("--paths0", required=True)

    shell_parser = subparsers.add_parser("shell-syntax")
    shell_parser.add_argument("--paths0", required=True)

    git_paths_parser = subparsers.add_parser("git-paths")
    git_paths_parser.add_argument("--merge-base", required=True)
    git_paths_parser.add_argument("--paths0", required=True)

    target_parser = subparsers.add_parser("retained-targets")
    target_parser.add_argument("--targets", required=True)
    target_parser.add_argument("--target-steps", required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "git-paths":
            paths = collect_git_paths(arguments.merge_base)
            write_paths0(paths, arguments.paths0)
        elif arguments.command == "retained-targets":
            write_targets(RETAINED_TARGETS, arguments.targets)
            target_plans = tuple(
                TargetBuildPlan(target, FULL_TARGET_STEPS)
                for target in RETAINED_TARGETS
            )
            write_target_steps(target_plans, arguments.target_steps)
            print("Selected targets: " + ", ".join(RETAINED_TARGETS))
        else:
            paths = read_paths0(arguments.paths0)
            if arguments.command == "plan":
                plan = classify_paths(paths)
                print_report(plan)
                write_flags(plan, arguments.flags)
                write_targets(plan.targets, arguments.targets)
                write_target_steps(
                    plan.target_plans,
                    arguments.target_steps,
                )
            elif arguments.command == "python-syntax":
                check_changed_python(paths)
            elif arguments.command == "shell-syntax":
                check_changed_shell(paths)
            else:
                raise AssertionError("unhandled command")
    except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError) as error:
        print("verification policy: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
