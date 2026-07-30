from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools" / "verify.sh"
EPHEMERAL_ZIG = ROOT / "tools" / "zig-with-ephemeral-cache.sh"


class LocalVerifyTests(unittest.TestCase):
    def write_executable(self, path: Path, source: str) -> None:
        path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def make_fake_toolchain(self, root: Path) -> tuple[Path, Path]:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        log_path = root / "tool.log"

        self.write_executable(
            bin_dir / "zig",
            r"""
            #!/bin/sh
            set -u
            : "${VERIFY_FAKE_LOG:?}"
            : "${ZIG_LOCAL_CACHE_DIR:?}"
            : "${ZIG_GLOBAL_CACHE_DIR:?}"
            : "${CLANG_MODULE_CACHE_PATH:?}"
            : "${SWIFT_MODULECACHE_PATH:?}"
            mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
            : >"$ZIG_LOCAL_CACHE_DIR/fake-local-entry"
            : >"$ZIG_GLOBAL_CACHE_DIR/fake-global-entry"
            printf 'zig|args=%s|local=%s|global=%s|clang=%s|swift=%s\n' \
                "$*" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" \
                "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH" \
                >>"$VERIFY_FAKE_LOG"

            if [ "${1:-}" = "version" ]; then
                echo "0.15.2"
                exit "${VERIFY_FAKE_ZIG_VERSION_STATUS:-0}"
            fi
            if [ "${1:-}" = "fmt" ]; then
                exit "${VERIFY_FAKE_FORMAT_STATUS:-0}"
            fi
            if [ "${1:-}" = "build" ] \
                && [ "${2:-}" = "host-runtime-compile" ] \
                && [ "${VERIFY_FAKE_COMPILE_STATUS:-0}" -ne 0 ]; then
                echo "injected compile-frontier failure"
                exit "$VERIFY_FAKE_COMPILE_STATUS"
            fi
            case "$*" in
                *contract-interop-test*)
                    if [ "${VERIFY_FAKE_CONTRACT_STATUS:-0}" -ne 0 ]; then
                        echo "injected contract failure"
                        exit "$VERIFY_FAKE_CONTRACT_STATUS"
                    fi
                    ;;
            esac
            case "$*" in
                *package-module-test*)
                    if [ "${VERIFY_FAKE_PACKAGE_STATUS:-0}" -ne 0 ]; then
                        echo "injected package failure"
                        exit "$VERIFY_FAKE_PACKAGE_STATUS"
                    fi
                    ;;
            esac
            case "$*" in
                *contract-rust-test*)
                    exit "${VERIFY_FAKE_RUST_STATUS:-0}"
                    ;;
            esac
            case "$*" in
                *" build test "* | "build test "*)
                    exit "${VERIFY_FAKE_NATIVE_STATUS:-0}"
                    ;;
            esac
            exit 0
            """,
        )
        self.write_executable(
            bin_dir / "python3",
            r"""
            #!/bin/sh
            set -u
            : "${VERIFY_FAKE_LOG:?}"
            printf 'python|args=%s|dontwrite=%s\n' \
                "$*" "${PYTHONDONTWRITEBYTECODE:-}" >>"$VERIFY_FAKE_LOG"
            if [ "${1:-}" = "--version" ]; then
                echo "Python 3.11.9"
                exit "${VERIFY_FAKE_PYTHON_VERSION_STATUS:-0}"
            fi
            case "$*" in
                *test_public_markdown_policy*)
                    exit "${VERIFY_FAKE_MARKDOWN_STATUS:-0}"
                    ;;
                *"discover -s bench/tests"*)
                    exit "${VERIFY_FAKE_PYTHON_FULL_STATUS:-0}"
                    ;;
            esac
            exit 0
            """,
        )
        return bin_dir, log_path

    def run_verify(
        self,
        root: Path,
        profile: str = "quick",
        extra_env: dict[str, str] | None = None,
        verify_path: Path = VERIFY,
    ) -> subprocess.CompletedProcess[str]:
        bin_dir, log_path = self.make_fake_toolchain(root)
        temporary_parent = root / "tmp"
        temporary_parent.mkdir()
        outside_cwd = root / "outside"
        outside_cwd.mkdir()
        env = os.environ.copy()
        for variable in (
            "GITHUB_ACTIONS",
            "GLACIER_VERIFY_REUSE_ZIG_CACHE",
            "ZIG_LOCAL_CACHE_DIR",
            "ZIG_GLOBAL_CACHE_DIR",
        ):
            env.pop(variable, None)
        env.update(
            {
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "TMPDIR": str(temporary_parent),
                "VERIFY_FAKE_LOG": str(log_path),
            }
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(verify_path), profile],
            cwd=outside_cwd,
            env=env,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    def test_quick_profile_reports_passes_skips_and_isolates_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(root)

            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn("Glacier local verification (quick)", result.stdout)
            self.assertIn("Zig optimization tier: Debug", result.stdout)
            self.assertIn("PASS  format/zig:", result.stdout)
            self.assertIn("PASS  policy/public-markdown:", result.stdout)
            self.assertIn("PASS  host/quick-dag:", result.stdout)
            self.assertIn(
                "PASS  interop/c-cpp-python: covered by the shared host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  package/modules: covered by the shared host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: quick profile; "
                "run tools/verify.sh full",
                result.stdout,
            )
            self.assertIn("SKIP  portability/cross-target:", result.stdout)
            self.assertIn("Summary: 7 PASS, 6 SKIP, 0 FAIL", result.stdout)

            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertIn("|dontwrite=1", log)
            build_lines = [
                line for line in log.splitlines() if line.startswith("zig|args=build ")
            ]
            self.assertEqual(1, len(build_lines), log)
            self.assertIn(
                "build contract-interop-test package-module-test ",
                build_lines[0],
            )
            for line in build_lines:
                self.assertIn("--cache-dir ", line)
                self.assertIn("--global-cache-dir ", line)
                self.assertIn("--prefix ", line)
                self.assertIn("-Doptimize=Debug", line)
                self.assertIn("-Dmetal=false", line)
                self.assertIn("-j2", line)
                match = re.search(
                    r"\|local=([^|]+)\|global=([^|]+)"
                    r"\|clang=([^|]+)\|swift=([^\n]+)$",
                    line,
                )
                self.assertIsNotNone(match, line)
                assert match is not None
                local_cache = Path(match.group(1))
                global_cache = Path(match.group(2))
                clang_cache = Path(match.group(3))
                swift_cache = Path(match.group(4))
                self.assertIn("glacier-verify.", str(local_cache))
                self.assertIn("glacier-verify.", str(global_cache))
                expected_parent = (root / "tmp").resolve()
                for cache_path in (
                    local_cache,
                    global_cache,
                    clang_cache,
                    swift_cache,
                ):
                    with self.subTest(cache_path=cache_path):
                        self.assertTrue(
                            cache_path.resolve().is_relative_to(expected_parent)
                        )

            self.assertEqual(
                [],
                list((root / "tmp").glob("glacier-verify.*")),
                result.stdout,
            )

    def test_local_run_ignores_inherited_zig_cache_without_opt_in(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caller_cache = root / "caller-cache"
            result = self.run_verify(
                root,
                extra_env={
                    "ZIG_LOCAL_CACHE_DIR": str(caller_cache),
                    "ZIG_GLOBAL_CACHE_DIR": str(caller_cache),
                },
            )

            self.assertEqual(0, result.returncode, result.stdout)
            self.assertFalse(caller_cache.exists(), result.stdout)
            self.assertEqual(
                [],
                list((root / "tmp").glob("glacier-verify.*")),
                result.stdout,
            )

    def test_ci_opt_in_reuses_exact_setup_zig_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            tools_dir = repository / "tools"
            tools_dir.mkdir(parents=True)
            copied_verify = tools_dir / "verify.sh"
            shutil.copy2(VERIFY, copied_verify)
            action_cache = (repository / ".zig-cache").resolve()

            result = self.run_verify(
                root,
                extra_env={
                    "GITHUB_ACTIONS": "true",
                    "GLACIER_VERIFY_REUSE_ZIG_CACHE": "1",
                    "ZIG_LOCAL_CACHE_DIR": str(action_cache),
                    "ZIG_GLOBAL_CACHE_DIR": str(action_cache),
                },
                verify_path=copied_verify,
            )

            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn("PASS  cache/zig-prune:", result.stdout)
            self.assertTrue(
                (action_cache / "fake-local-entry").is_file(),
                result.stdout,
            )
            self.assertTrue(
                (action_cache / "fake-global-entry").is_file(),
                result.stdout,
            )
            log = (root / "tool.log").read_text(encoding="utf-8")
            build_lines = [
                line for line in log.splitlines() if line.startswith("zig|args=build ")
            ]
            self.assertEqual(1, len(build_lines), log)
            self.assertIn(f"|local={action_cache}|", build_lines[0])
            self.assertIn(f"|global={action_cache}|", build_lines[0])
            self.assertEqual(
                2,
                log.count(
                    "tools/verification_policy.py prune-zig-cache"
                ),
                log,
            )
            self.assertEqual(
                [],
                list((root / "tmp").glob("glacier-verify.*")),
                result.stdout,
            )

    def test_ci_cache_is_pruned_again_after_a_gate_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            tools_dir = repository / "tools"
            tools_dir.mkdir(parents=True)
            copied_verify = tools_dir / "verify.sh"
            shutil.copy2(VERIFY, copied_verify)
            action_cache = (repository / ".zig-cache").resolve()

            result = self.run_verify(
                root,
                extra_env={
                    "GITHUB_ACTIONS": "true",
                    "GLACIER_VERIFY_REUSE_ZIG_CACHE": "1",
                    "ZIG_LOCAL_CACHE_DIR": str(action_cache),
                    "ZIG_GLOBAL_CACHE_DIR": str(action_cache),
                    "VERIFY_FAKE_CONTRACT_STATUS": "7",
                },
                verify_path=copied_verify,
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn("FAIL  host/quick-dag: exit 7", result.stdout)
            self.assertIn("PASS  cache/zig-prune:", result.stdout)
            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertEqual(
                2,
                log.count(
                    "tools/verification_policy.py prune-zig-cache"
                ),
                log,
            )

    def test_ci_cache_opt_in_fails_closed_outside_github_actions(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                extra_env={"GLACIER_VERIFY_REUSE_ZIG_CACHE": "1"},
            )

            self.assertEqual(64, result.returncode, result.stdout)
            self.assertIn(
                "reuse is restricted to GitHub Actions",
                result.stdout,
            )
            self.assertFalse((root / "tool.log").exists())

    def test_ci_cache_opt_in_rejects_unexpected_action_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                extra_env={
                    "GITHUB_ACTIONS": "true",
                    "GLACIER_VERIFY_REUSE_ZIG_CACHE": "1",
                    "ZIG_LOCAL_CACHE_DIR": str(root / "local"),
                    "ZIG_GLOBAL_CACHE_DIR": str(root / "global"),
                },
            )

            self.assertEqual(64, result.returncode, result.stdout)
            self.assertIn(
                "action cache paths must both name",
                result.stdout,
            )
            self.assertFalse((root / "tool.log").exists())

    def test_ci_cache_opt_in_rejects_symlinked_action_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            tools_dir = repository / "tools"
            tools_dir.mkdir(parents=True)
            copied_verify = tools_dir / "verify.sh"
            shutil.copy2(VERIFY, copied_verify)
            outside_cache = root / "outside-cache"
            outside_cache.mkdir()
            action_cache = repository.resolve() / ".zig-cache"
            action_cache.symlink_to(outside_cache, target_is_directory=True)

            result = self.run_verify(
                root,
                extra_env={
                    "GITHUB_ACTIONS": "true",
                    "GLACIER_VERIFY_REUSE_ZIG_CACHE": "1",
                    "ZIG_LOCAL_CACHE_DIR": str(action_cache),
                    "ZIG_GLOBAL_CACHE_DIR": str(action_cache),
                },
                verify_path=copied_verify,
            )

            self.assertEqual(64, result.returncode, result.stdout)
            self.assertIn(
                "action cache path must not be a symlink",
                result.stdout,
            )
            self.assertFalse((root / "tool.log").exists())

    def test_failure_is_reported_continues_and_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                extra_env={"VERIFY_FAKE_CONTRACT_STATUS": "7"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn("FAIL  host/quick-dag: exit 7", result.stdout)
            self.assertIn("injected contract failure", result.stdout)
            self.assertIn(
                "SKIP  interop/c-cpp-python: shared host Zig DAG failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  package/modules: shared host Zig DAG failed",
                result.stdout,
            )
            self.assertIn("Summary: 4 PASS, 8 SKIP, 1 FAIL", result.stdout)
            self.assertEqual([], list((root / "tmp").glob("glacier-verify.*")))

    def test_quick_package_failure_is_attributed_to_the_shared_dag(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                extra_env={"VERIFY_FAKE_PACKAGE_STATUS": "9"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn("FAIL  host/quick-dag: exit 9", result.stdout)
            self.assertIn("injected package failure", result.stdout)
            self.assertNotIn(
                "FAIL  interop/c-cpp-python:",
                result.stdout,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: shared host Zig DAG failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  package/modules: shared host Zig DAG failed",
                result.stdout,
            )

    def test_full_profile_runs_broad_suites_and_reports_optional_skip(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir, log_path = self.make_fake_toolchain(root)
            self.write_executable(
                bin_dir / "uname",
                """
                #!/bin/sh
                echo TestOS
                """,
            )
            temporary_parent = root / "tmp"
            temporary_parent.mkdir()
            outside_cwd = root / "outside"
            outside_cwd.mkdir()
            environment = os.environ.copy()
            for variable in (
                "GLACIER_VERIFY_REQUIRE_NATIVE",
                "GLACIER_VERIFY_REUSE_ZIG_CACHE",
                "ZIG_LOCAL_CACHE_DIR",
                "ZIG_GLOBAL_CACHE_DIR",
            ):
                environment.pop(variable, None)
            environment.update(
                {
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "TMPDIR": str(temporary_parent),
                    "VERIFY_FAKE_LOG": str(log_path),
                }
            )
            result = subprocess.run(
                [str(VERIFY), "full"],
                cwd=outside_cwd,
                env=environment,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )

            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn(
                "Zig optimization tier: ReleaseSafe",
                result.stdout,
            )
            self.assertIn(
                "PASS  compile/host-test-frontier:",
                result.stdout,
            )
            self.assertIn("PASS  host/runtime-dag:", result.stdout)
            self.assertIn(
                "PASS  native/releasesafe-suite: covered by the shared "
                "host runtime DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  interop/c-cpp-python: covered by the shared host runtime DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  package/modules: covered by the shared host runtime DAG",
                result.stdout,
            )
            self.assertIn("PASS  python/full-suite:", result.stdout)
            self.assertIn(
                "SKIP  native/workload-store-fault: requires native "
                "Darwin, Linux, or FreeBSD POSIX execution",
                result.stdout,
            )
            self.assertIn("SKIP  interop/rust: unsupported host", result.stdout)
            self.assertIn("Summary: 10 PASS, 5 SKIP, 0 FAIL", result.stdout)

            log = (root / "tool.log").read_text(encoding="utf-8")
            host_build_lines = [
                line
                for line in log.splitlines()
                if line.startswith("zig|args=build host-runtime-compile ")
                or line.startswith("zig|args=build test contract-interop-test ")
            ]
            self.assertEqual(2, len(host_build_lines), log)
            self.assertTrue(
                all(
                    "-Doptimize=ReleaseSafe" in line
                    for line in host_build_lines
                ),
                host_build_lines,
            )
            self.assertTrue(
                host_build_lines[0].startswith("zig|args=build host-runtime-compile "),
                host_build_lines,
            )
            self.assertTrue(
                host_build_lines[1].startswith(
                    "zig|args=build test contract-interop-test "
                ),
                host_build_lines,
            )
            cache_pattern = re.compile(
                r"--cache-dir ([^ ]+) --global-cache-dir ([^ ]+) "
                r"--prefix ([^| ]+)"
            )
            cache_matches = [cache_pattern.search(line) for line in host_build_lines]
            self.assertTrue(
                all(match is not None for match in cache_matches),
                host_build_lines,
            )
            assert cache_matches[0] is not None
            assert cache_matches[1] is not None
            self.assertEqual(
                cache_matches[0].groups(),
                cache_matches[1].groups(),
            )
            self.assertNotIn(
                "zig|args=build contract-interop-test ",
                log,
            )
            self.assertNotIn(
                "zig|args=build package-module-test ",
                log,
            )
            self.assertIn("python|args=-m unittest discover -s bench/tests", log)

    def test_full_compile_failure_skips_runtime_and_hard_campaign(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                profile="full",
                extra_env={"VERIFY_FAKE_COMPILE_STATUS": "17"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn(
                "FAIL  compile/host-test-frontier: exit 17",
                result.stdout,
            )
            self.assertIn(
                "SKIP  host/runtime-dag: host test compile frontier failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: host test compile frontier failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/workload-store-fault: host test compile frontier failed",
                result.stdout,
            )
            self.assertIn("PASS  python/full-suite:", result.stdout)
            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertIn(
                "zig|args=build host-runtime-compile ",
                log,
            )
            self.assertNotIn(
                "zig|args=build test contract-interop-test ",
                log,
            )
            self.assertNotIn("native-workload-store-fault-test", log)
            self.assertEqual(
                [],
                list((root / "tmp").glob("glacier-verify.*")),
            )

    def test_full_runtime_failure_keeps_aggregate_attribution(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                profile="full",
                extra_env={"VERIFY_FAKE_NATIVE_STATUS": "23"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn(
                "PASS  compile/host-test-frontier:",
                result.stdout,
            )
            self.assertIn(
                "FAIL  host/runtime-dag: exit 23",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: shared host runtime DAG failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: shared host runtime DAG failed",
                result.stdout,
            )
            self.assertIn("PASS  python/full-suite:", result.stdout)

    def test_full_without_python_keeps_compile_and_package_evidence(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                profile="full",
                extra_env={"VERIFY_FAKE_PYTHON_VERSION_STATUS": "69"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn(
                "PASS  compile/host-test-frontier:",
                result.stdout,
            )
            self.assertIn(
                "SKIP  host/runtime-dag: requires a working python3 executable",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: requires a working python3 executable",
                result.stdout,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: requires a working python3 executable",
                result.stdout,
            )
            self.assertIn("PASS  package/modules:", result.stdout)
            self.assertIn(
                "SKIP  python/full-suite: requires a working python3 executable",
                result.stdout,
            )
            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertIn(
                "zig|args=build host-runtime-compile ",
                log,
            )
            self.assertIn("zig|args=build package-module-test ", log)
            self.assertNotIn("zig|args=build test ", log)
            self.assertNotIn("contract-interop-test", log)

    def test_full_without_zig_keeps_planned_runtime_gate_visible(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                profile="full",
                extra_env={"VERIFY_FAKE_ZIG_VERSION_STATUS": "72"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn("FAIL  toolchain/zig:", result.stdout)
            self.assertIn(
                "SKIP  compile/host-test-frontier: requires a working zig executable",
                result.stdout,
            )
            self.assertIn(
                "SKIP  host/runtime-dag: requires a working zig executable",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: requires a working zig executable",
                result.stdout,
            )
            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertNotIn("zig|args=build ", log)

    def test_invalid_profile_fails_before_creating_a_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {
                **os.environ,
                "TMPDIR": str(root),
            }
            result = subprocess.run(
                [str(VERIFY), "unknown"],
                cwd=root,
                env=env,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.assertEqual(64, result.returncode, result.stdout)
            self.assertIn("usage: tools/verify.sh", result.stdout)
            self.assertEqual([], list(root.glob("glacier-verify.*")))

    def test_ephemeral_zig_wrapper_exports_and_removes_compiler_caches(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir, log_path = self.make_fake_toolchain(root)
            temporary_parent = root / "tmp"
            temporary_parent.mkdir()
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "TMPDIR": str(temporary_parent),
                "VERIFY_FAKE_LOG": str(log_path),
            }
            result = subprocess.run(
                [str(EPHEMERAL_ZIG), "build", "probe"],
                cwd=ROOT,
                env=env,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )

            self.assertEqual(0, result.returncode, result.stdout)
            log = log_path.read_text(encoding="utf-8")
            self.assertIn("args=build probe --cache-dir ", log)
            match = re.search(
                r"\|local=([^|]+)\|global=([^|]+)"
                r"\|clang=([^|]+)\|swift=([^\n]+)$",
                log.strip(),
            )
            self.assertIsNotNone(match, log)
            assert match is not None
            for cache_path in match.groups():
                with self.subTest(cache_path=cache_path):
                    self.assertIn("glacier-zig-cache.", cache_path)
            self.assertEqual(
                [],
                list(temporary_parent.glob("glacier-zig-cache.*")),
                result.stdout,
            )

    def test_ephemeral_zig_wrapper_rejects_caller_cache_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir, log_path = self.make_fake_toolchain(root)
            temporary_parent = root / "tmp"
            temporary_parent.mkdir()
            result = subprocess.run(
                [str(EPHEMERAL_ZIG), "build", "--cache-dir", str(root / "x")],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "TMPDIR": str(temporary_parent),
                    "VERIFY_FAKE_LOG": str(log_path),
                },
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )

            self.assertEqual(64, result.returncode, result.stdout)
            self.assertIn("cache paths are managed", result.stdout)
            self.assertFalse(log_path.exists())
            self.assertEqual([], list(temporary_parent.glob("glacier-zig-cache.*")))


if __name__ == "__main__":
    unittest.main()
