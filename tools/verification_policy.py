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
WINDOWS_TARGETS: Tuple[str, ...] = (RETAINED_TARGETS[2],)
FREEBSD_TARGETS: Tuple[str, ...] = (RETAINED_TARGETS[3],)
POSIX_TARGETS: Tuple[str, ...] = LINUX_TARGETS + FREEBSD_TARGETS
MAXIMUM_SHEBANG_BYTES = 256

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
        {"native-full", "python-changed", "python-full"}
    ),
    "tools/verify.sh": frozenset({"native-full", "python-full", "shell-changed"}),
    "tools/zig-with-ephemeral-cache.sh": frozenset(
        {"native-full", "python-full", "shell-changed"}
    ),
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
    "Cargo.lock",
    "Cargo.toml",
    "CMakeLists.txt",
    "Makefile",
}


@dataclass(frozen=True)
class PathDecision:
    path: str
    reason: str
    flags: FrozenSet[str]
    targets: Tuple[str, ...]


@dataclass(frozen=True)
class VerificationPlan:
    paths: Tuple[str, ...]
    decisions: Tuple[PathDecision, ...]
    flags: FrozenSet[str]
    targets: Tuple[str, ...]

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


def write_paths0(
    paths: Sequence[str], output: Union[os.PathLike, str]
) -> None:
    normalized = tuple(
        sorted({_validated_path(path) for path in paths}, key=os.fsencode)
    )
    Path(output).write_bytes(
        b"".join(os.fsencode(path) + b"\0" for path in normalized)
    )


def collect_git_paths(
    merge_base: str,
    repository: Union[os.PathLike, str] = ".",
) -> Tuple[str, ...]:
    """Collect each Git state separately so one state cannot mask another."""

    if (
        not isinstance(merge_base, str)
        or re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", merge_base)
        is None
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
    return tuple(
        sorted({_validated_path(path) for path in paths}, key=os.fsencode)
    )


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
    basename_tokens = tuple(
        token for token in re.split(r"[^a-z0-9]+", stem) if token
    )
    return name in basename_tokens


def _platform_requirements(
    path: str,
) -> Tuple[FrozenSet[str], Tuple[str, ...]]:
    flags = set()
    selected_targets = set()
    if _has_platform_token(path, "darwin") or _has_platform_token(
        path, "macos"
    ):
        flags.add("darwin-native")
    if _has_platform_token(path, "windows"):
        selected_targets.update(WINDOWS_TARGETS)
    if _has_platform_token(path, "linux"):
        selected_targets.update(LINUX_TARGETS)
    if _has_platform_token(path, "freebsd"):
        selected_targets.update(FREEBSD_TARGETS)
    if _has_platform_token(path, "posix") or _has_platform_token(path, "unix"):
        selected_targets.update(POSIX_TARGETS)
    targets = tuple(
        target for target in RETAINED_TARGETS if target in selected_targets
    )
    return frozenset(flags), targets


def _is_github_control(path: str) -> bool:
    lower = path.lower()
    return lower in GITHUB_CONTROL_PATHS or lower.startswith(
        GITHUB_CONTROL_PREFIXES
    )


def _compiled_flags(suffix: str) -> FrozenSet[str]:
    flags = {"native-full", "python-full"}
    if suffix == ".rs":
        flags.add("rust-native")
    return frozenset(flags)


def _decision_for_path(path: str) -> PathDecision:
    lower = path.lower()
    suffix = Path(lower).suffix
    first_component = lower.split("/", 1)[0]

    policy_flags = POLICY_CONTROL_PATHS.get(path)
    if policy_flags is not None:
        return PathDecision(
            path,
            "verification control changed; validate every retained target",
            policy_flags,
            RETAINED_TARGETS,
        )

    if _is_github_control(path):
        flags = set(_compiled_flags(suffix))
        if suffix == ".py":
            flags.add("python-changed")
        if suffix == ".sh":
            flags.add("shell-changed")
        return PathDecision(
            path,
            "GitHub workflow, action, or dependency automation changed",
            frozenset(flags),
            RETAINED_TARGETS,
        )

    if suffix == ".py":
        python_flags = {"python-changed", "python-full"}
        if lower == "bench/native_metal_readiness.py":
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

    special_flags = set()
    if (
        lower.startswith("src/backends/metal/")
        or lower == "tests/metal_correctness.zig"
        or (
            first_component in {"bench", "examples", "tests"}
            and suffix in SHARED_CODE_SUFFIXES
            and _has_basename_token(path, "metal")
        )
    ):
        special_flags.add("metal-native")

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

    if path in BUILD_CONTROL_PATHS:
        build_flags = {"native-full", "python-full"}
        if path in {"build.zig", "build.zig.zon"}:
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


def classify_paths(paths: Iterable[str]) -> VerificationPlan:
    unique_paths = {_validated_path(path) for path in paths}
    ordered_paths = tuple(sorted(unique_paths, key=os.fsencode))
    decisions = tuple(_decision_for_path(path) for path in ordered_paths)

    flags = frozenset(
        flag for decision in decisions for flag in decision.flags
    )
    selected_targets = {
        target for decision in decisions for target in decision.targets
    }
    targets = tuple(
        target for target in RETAINED_TARGETS if target in selected_targets
    )
    return VerificationPlan(ordered_paths, decisions, flags, targets)


def _gate_names(decision: PathDecision) -> Tuple[str, ...]:
    names = ["quick"]
    for flag, label in (
        ("python-changed", "python/changed-syntax"),
        ("python-full", "python/full-suite"),
        ("shell-changed", "shell/changed-syntax"),
        ("rust-native", "interop/rust"),
        ("native-full", "native/releasesafe-suite"),
        ("darwin-native", "native/darwin"),
        ("metal-native", "native/metal"),
    ):
        if flag in decision.flags:
            names.append(label)
    names.extend("portability/" + target for target in decision.targets)
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
        ("metal-native", "native/metal"),
    ):
        if plan.requires(flag):
            selected_gates.append(label)
    print("Selected gates: " + ", ".join(selected_gates))
    if plan.targets:
        print("Selected targets: " + ", ".join(plan.targets))
    else:
        print("Selected targets: (none)")


def write_flags(plan: VerificationPlan, output: Union[os.PathLike, str]) -> None:
    flags = ["quick"]
    flags.extend(sorted(plan.flags))
    Path(output).write_text("".join(flag + "\n" for flag in flags), encoding="utf-8")


def write_targets(
    targets: Sequence[str], output: Union[os.PathLike, str]
) -> None:
    if (
        len(set(targets)) != len(targets)
        or any(target not in RETAINED_TARGETS for target in targets)
    ):
        raise ValueError("target plan is not a unique retained-target subset")
    ordered_targets = tuple(
        target for target in RETAINED_TARGETS if target in targets
    )
    if tuple(targets) != ordered_targets:
        raise ValueError("target plan is not in retained-target order")
    Path(output).write_text(
        "".join(target + "\n" for target in ordered_targets),
        encoding="ascii",
    )


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
        raise ValueError(
            str(path) + " has a shebang outside the retained byte bound"
        )
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

    python_parser = subparsers.add_parser("python-syntax")
    python_parser.add_argument("--paths0", required=True)

    shell_parser = subparsers.add_parser("shell-syntax")
    shell_parser.add_argument("--paths0", required=True)

    git_paths_parser = subparsers.add_parser("git-paths")
    git_paths_parser.add_argument("--merge-base", required=True)
    git_paths_parser.add_argument("--paths0", required=True)

    target_parser = subparsers.add_parser("retained-targets")
    target_parser.add_argument("--targets", required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "git-paths":
            paths = collect_git_paths(arguments.merge_base)
            write_paths0(paths, arguments.paths0)
        elif arguments.command == "retained-targets":
            write_targets(RETAINED_TARGETS, arguments.targets)
            print("Selected targets: " + ", ".join(RETAINED_TARGETS))
        else:
            paths = read_paths0(arguments.paths0)
            if arguments.command == "plan":
                plan = classify_paths(paths)
                print_report(plan)
                write_flags(plan, arguments.flags)
                write_targets(plan.targets, arguments.targets)
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
