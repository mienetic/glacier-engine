from __future__ import annotations

import os
import re
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
            mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
            : >"$ZIG_LOCAL_CACHE_DIR/fake-local-entry"
            : >"$ZIG_GLOBAL_CACHE_DIR/fake-global-entry"
            printf 'zig|args=%s|local=%s|global=%s\n' \
                "$*" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" \
                >>"$VERIFY_FAKE_LOG"

            if [ "${1:-}" = "version" ]; then
                echo "0.15.2"
                exit 0
            fi
            if [ "${1:-}" = "fmt" ]; then
                exit "${VERIFY_FAKE_FORMAT_STATUS:-0}"
            fi
            case "$*" in
                *contract-interop-test*)
                    if [ "${VERIFY_FAKE_CONTRACT_STATUS:-0}" -ne 0 ]; then
                        echo "injected contract failure"
                        exit "$VERIFY_FAKE_CONTRACT_STATUS"
                    fi
                    ;;
                *package-module-test*)
                    exit "${VERIFY_FAKE_PACKAGE_STATUS:-0}"
                    ;;
                *contract-rust-test*)
                    exit "${VERIFY_FAKE_RUST_STATUS:-0}"
                    ;;
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
                exit 0
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
    ) -> subprocess.CompletedProcess[str]:
        bin_dir, log_path = self.make_fake_toolchain(root)
        temporary_parent = root / "tmp"
        temporary_parent.mkdir()
        outside_cwd = root / "outside"
        outside_cwd.mkdir()
        env = os.environ.copy()
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
            [str(VERIFY), profile],
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
            self.assertIn("PASS  format/zig:", result.stdout)
            self.assertIn("PASS  policy/public-markdown:", result.stdout)
            self.assertIn("PASS  interop/c-cpp-python:", result.stdout)
            self.assertIn("PASS  package/modules:", result.stdout)
            self.assertIn(
                "SKIP  native/releasesafe-suite: quick profile; "
                "run tools/verify.sh full",
                result.stdout,
            )
            self.assertIn(
                "SKIP  portability/cross-target:", result.stdout
            )
            self.assertIn("Summary: 6 PASS, 6 SKIP, 0 FAIL", result.stdout)

            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertIn("|dontwrite=1", log)
            build_lines = [
                line
                for line in log.splitlines()
                if line.startswith("zig|args=build ")
            ]
            self.assertEqual(2, len(build_lines), log)
            for line in build_lines:
                self.assertIn("--cache-dir ", line)
                self.assertIn("--global-cache-dir ", line)
                self.assertIn("--prefix ", line)
                self.assertIn("-Dmetal=false", line)
                self.assertIn("-j2", line)
                match = re.search(
                    r"\|local=([^|]+)\|global=([^\n]+)$", line
                )
                self.assertIsNotNone(match, line)
                assert match is not None
                local_cache = Path(match.group(1))
                global_cache = Path(match.group(2))
                self.assertIn("glacier-verify.", str(local_cache))
                self.assertIn("glacier-verify.", str(global_cache))
                expected_parent = (root / "tmp").resolve()
                self.assertTrue(
                    local_cache.resolve().is_relative_to(expected_parent)
                )
                self.assertTrue(
                    global_cache.resolve().is_relative_to(expected_parent)
                )

            self.assertEqual(
                [],
                list((root / "tmp").glob("glacier-verify.*")),
                result.stdout,
            )

    def test_failure_is_reported_continues_and_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_verify(
                root,
                extra_env={"VERIFY_FAKE_CONTRACT_STATUS": "7"},
            )

            self.assertEqual(1, result.returncode, result.stdout)
            self.assertIn(
                "FAIL  interop/c-cpp-python: exit 7", result.stdout
            )
            self.assertIn("injected contract failure", result.stdout)
            self.assertIn("PASS  package/modules:", result.stdout)
            self.assertLess(
                result.stdout.index("FAIL  interop/c-cpp-python:"),
                result.stdout.index("PASS  package/modules:"),
            )
            self.assertIn("Summary: 5 PASS, 6 SKIP, 1 FAIL", result.stdout)
            self.assertEqual(
                [], list((root / "tmp").glob("glacier-verify.*"))
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
            result = subprocess.run(
                [str(VERIFY), "full"],
                cwd=outside_cwd,
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

            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn("PASS  native/releasesafe-suite:", result.stdout)
            self.assertIn("PASS  python/full-suite:", result.stdout)
            self.assertIn(
                "SKIP  interop/rust: unsupported host", result.stdout
            )
            self.assertIn("Summary: 8 PASS, 4 SKIP, 0 FAIL", result.stdout)

            log = (root / "tool.log").read_text(encoding="utf-8")
            self.assertIn("zig|args=build test ", log)
            self.assertIn("python|args=-m unittest discover -s bench/tests", log)

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

    def test_ephemeral_zig_wrapper_exports_and_removes_both_caches(self) -> None:
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
                r"\|local=([^|]+)\|global=([^\n]+)$", log.strip()
            )
            self.assertIsNotNone(match, log)
            assert match is not None
            self.assertIn("glacier-zig-cache.", match.group(1))
            self.assertIn("glacier-zig-cache.", match.group(2))
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
            self.assertEqual(
                [], list(temporary_parent.glob("glacier-zig-cache.*"))
            )


if __name__ == "__main__":
    unittest.main()
