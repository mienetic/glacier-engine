import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import verification_policy as policy


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class VerificationPolicyTests(unittest.TestCase):
    def assert_targets(self, paths, expected):
        plan = policy.classify_paths(paths)
        self.assertEqual(plan.targets, tuple(expected))
        return plan

    def test_documentation_only_selects_quick_gates(self):
        plan = self.assert_targets(
            ["README.md", "docs/CONTRIBUTING.md", ".github/ISSUE_TEMPLATE/bug.yml"],
            (),
        )
        self.assertEqual(plan.flags, frozenset())

    def test_github_execution_controls_are_conservative(self):
        for changed_path in (
            ".github/workflows/ci.yml",
            ".github/actions/setup/action.yml",
            ".github/dependabot.yml",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets(
                    [changed_path], policy.RETAINED_TARGETS
                )
                self.assertTrue(plan.requires("native-full"))
                self.assertTrue(plan.requires("python-full"))

    def test_python_only_does_not_select_zig_or_foreign_targets(self):
        plan = self.assert_targets(
            ["bench/verify_results.py", "bench/tests/test_report.py"],
            (),
        )
        self.assertTrue(plan.requires("python-changed"))
        self.assertTrue(plan.requires("python-full"))
        self.assertFalse(plan.requires("native-full"))

    def test_native_metal_verifier_selects_its_single_dispatch_gate(self):
        plan = self.assert_targets(["bench/native_metal_readiness.py"], ())
        self.assertEqual(
            plan.flags,
            frozenset(
                {"python-changed", "python-full", "metal-native"}
            ),
        )

    def test_retained_fixture_selects_python_without_zig(self):
        plan = self.assert_targets(["bench/results/reference.json"], ())
        self.assertEqual(plan.flags, frozenset({"python-full"}))

    def test_shared_code_and_build_control_select_every_target(self):
        for changed_path in ("src/runtime.zig", "include/glacier.h", "build.zig"):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], policy.RETAINED_TARGETS)
                self.assertTrue(plan.requires("native-full"))
                self.assertTrue(plan.requires("python-full"))
                if changed_path == "build.zig":
                    self.assertTrue(plan.requires("metal-native"))

    def test_rust_source_selects_the_native_rust_gate(self):
        plan = self.assert_targets(
            ["examples/interop/rust_verify.rs"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(plan.requires("rust-native"))
        self.assertTrue(plan.requires("native-full"))

    def test_platform_specific_paths_select_only_relevant_targets(self):
        cases = {
            "src/platform/windows/dispatch.zig": policy.WINDOWS_TARGETS,
            "src/platform/linux/memory.zig": policy.LINUX_TARGETS,
            "src/platform/freebsd/memory.zig": policy.FREEBSD_TARGETS,
            "src/platform/posix/files.zig": policy.POSIX_TARGETS,
            "src/platform/windows.zig": policy.WINDOWS_TARGETS,
            "bench/native_observer_linux.zig": policy.LINUX_TARGETS,
        }
        for changed_path, expected in cases.items():
            with self.subTest(changed_path=changed_path):
                self.assert_targets([changed_path], expected)

    def test_selection_is_the_union_of_all_changed_paths(self):
        plan = self.assert_targets(
            [
                "docs/ROADMAP.md",
                "src/platform/windows/dispatch.zig",
                "src/platform/freebsd/memory.zig",
                "bench/tests/test_report.py",
            ],
            policy.WINDOWS_TARGETS + policy.FREEBSD_TARGETS,
        )
        self.assertTrue(plan.requires("python-changed"))
        self.assertTrue(plan.requires("python-full"))
        self.assertTrue(plan.requires("native-full"))

    def test_mixed_platform_tokens_are_unioned(self):
        plan = self.assert_targets(
            ["src/platform/darwin_linux_windows_bridge.zig"],
            policy.LINUX_TARGETS + policy.WINDOWS_TARGETS,
        )
        self.assertTrue(plan.requires("darwin-native"))
        self.assertTrue(plan.requires("native-full"))
        self.assertTrue(plan.requires("python-full"))

    def test_metal_change_requires_native_darwin_without_foreign_targets(self):
        for changed_path in (
            "src/backends/metal/command_queue.zig",
            "tests/native_metal_observation.zig",
            "examples/native_metal_observation.zig",
            "bench/metal_kernel.zig",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset({"metal-native"}),
                )

        shared = self.assert_targets(
            ["src/root.zig"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(shared.requires("native-full"))

    def test_darwin_platform_change_requires_native_darwin_only(self):
        for changed_path in (
            "src/platform/darwin/files.zig",
            "src/runtime/native_observer_macos.zig",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(plan.flags, frozenset({"darwin-native"}))

    def test_python_shell_and_fixtures_override_platform_name(self):
        cases = {
            "bench/linux/adapter.py": frozenset(
                {"python-changed", "python-full"}
            ),
            "docs/linux/example.py": frozenset(
                {"python-changed", "python-full"}
            ),
            "tools/windows/bootstrap.sh": frozenset({"shell-changed"}),
            "tests/fixtures/linux/reference.json": frozenset({"python-full"}),
        }
        for changed_path, expected_flags in cases.items():
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(plan.flags, expected_flags)

    def test_platform_tokens_do_not_match_substrings(self):
        plan = self.assert_targets(
            ["src/native_linuxer_runtime.zig"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(plan.requires("native-full"))

    def test_unknown_code_tree_input_is_conservative(self):
        plan = self.assert_targets(
            ["src/runtime.codegen"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(plan.requires("native-full"))

        root_plan = self.assert_targets(
            ["new-runtime-input"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(root_plan.requires("native-full"))

    def test_verifier_controls_select_every_target(self):
        shell_plan = self.assert_targets(
            ["tools/verify.sh"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(shell_plan.requires("shell-changed"))
        self.assertTrue(shell_plan.requires("native-full"))

        python_plan = self.assert_targets(
            ["tools/verification_policy.py"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(python_plan.requires("python-changed"))
        self.assertTrue(python_plan.requires("native-full"))

    def test_paths_are_deduplicated_and_byte_sorted(self):
        plan = policy.classify_paths(
            ["docs/z.md", "docs/a\nname.md", "docs/z.md"]
        )
        self.assertEqual(
            plan.paths,
            tuple(sorted({"docs/z.md", "docs/a\nname.md"}, key=os.fsencode)),
        )

    def test_nul_reader_preserves_newlines_and_requires_termination(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            path_stream = Path(temporary_directory) / "paths"
            path_stream.write_bytes(b"docs/a\nname.md\0src/runtime.zig\0")
            self.assertEqual(
                policy.read_paths0(path_stream),
                ("docs/a\nname.md", "src/runtime.zig"),
            )

            roundtrip = Path(temporary_directory) / "roundtrip"
            policy.write_paths0(
                ("src/runtime.zig", "docs/a\nname.md"),
                roundtrip,
            )
            self.assertEqual(
                policy.read_paths0(roundtrip),
                ("docs/a\nname.md", "src/runtime.zig"),
            )

            path_stream.write_bytes(b"docs/not-terminated.md")
            with self.assertRaises(ValueError):
                policy.read_paths0(path_stream)

    def test_target_plan_is_ordered_validated_and_separate_from_flags(self):
        plan = policy.classify_paths(
            ["src/platform/windows/dispatch.zig"]
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            flags = Path(temporary_directory) / "flags"
            targets = Path(temporary_directory) / "targets"
            policy.write_flags(plan, flags)
            policy.write_targets(plan.targets, targets)
            self.assertNotIn("target:", flags.read_text(encoding="utf-8"))
            self.assertEqual(
                targets.read_text(encoding="ascii").splitlines(),
                list(policy.WINDOWS_TARGETS),
            )
            with self.assertRaises(ValueError):
                policy.write_targets(
                    tuple(reversed(policy.RETAINED_TARGETS)),
                    targets,
                )
            with self.assertRaises(ValueError):
                policy.write_targets(("unknown-target",), targets)

    def test_rejects_paths_outside_repository(self):
        for invalid_path in ("/tmp/runtime.zig", "../runtime.zig", "src//runtime.zig"):
            with self.subTest(invalid_path=invalid_path):
                with self.assertRaises(ValueError):
                    policy.classify_paths([invalid_path])

    def test_changed_syntax_checks_skip_deleted_files(self):
        policy.check_changed_python(["bench/tests/deleted.py"])
        policy.check_changed_shell(["tools/deleted.sh"])

    def test_changed_python_compiles_bytes_without_tokenize_import(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            valid = root / "valid.py"
            invalid = root / "invalid.py"
            valid.write_bytes(
                b"# -*- coding: latin-1 -*-\nlabel = 'caf\\xe9'\n"
            )
            invalid.write_bytes(b"if True print('broken')\n")
            policy.check_changed_python([str(valid)])
            with self.assertRaises(SyntaxError):
                policy.check_changed_python([str(invalid)])

    def test_shell_syntax_uses_the_declared_retained_interpreter(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            sh_script = root / "portable.sh"
            bash_script = root / "arrays.sh"
            sh_script.write_text("#!/bin/sh\ntrue\n", encoding="ascii")
            bash_script.write_text(
                "#!/usr/bin/env bash\nvalues=(one two)\n",
                encoding="ascii",
            )
            with mock.patch.object(policy.subprocess, "run") as run:
                policy.check_changed_shell(
                    (str(sh_script), str(bash_script))
                )
            self.assertEqual(
                run.call_args_list,
                [
                    mock.call(
                        ("sh", "-n", str(sh_script.resolve())),
                        check=True,
                    ),
                    mock.call(
                        ("bash", "-n", str(bash_script.resolve())),
                        check=True,
                    ),
                ],
            )

    def test_shell_syntax_rejects_unknown_or_unbounded_shebang(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            unknown = root / "unknown.sh"
            oversized = root / "oversized.sh"
            unknown.write_text("#!/usr/bin/env zsh\n", encoding="ascii")
            oversized.write_bytes(
                b"#!" + b"x" * policy.MAXIMUM_SHEBANG_BYTES + b"\n"
            )
            with self.assertRaises(ValueError):
                policy.check_changed_shell((str(unknown),))
            with self.assertRaises(ValueError):
                policy.check_changed_shell((str(oversized),))


class GitRepositoryMixin:
    def run_git(self, repository, *arguments, capture=False):
        return subprocess.run(
            ("git",) + arguments,
            cwd=repository,
            check=True,
            stdout=(
                subprocess.PIPE if capture else subprocess.DEVNULL
            ),
            text=True,
        )

    def initialize_repository(self, repository):
        self.run_git(repository, "init", "-q")
        self.run_git(repository, "config", "user.name", "Verifier Test")
        self.run_git(
            repository,
            "config",
            "user.email",
            "verifier@example.invalid",
        )


@unittest.skipUnless(shutil.which("git"), "Git integration requires git")
class VerificationGitIntegrationTests(GitRepositoryMixin, unittest.TestCase):
    def test_git_collection_keeps_masked_states_and_untracked_paths(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            for name in (
                "committed-mask.txt",
                "staged-mask.txt",
                "unstaged.txt",
            ):
                (repository / name).write_text("base\n", encoding="ascii")
            self.run_git(repository, "add", ".")
            self.run_git(repository, "commit", "-q", "-m", "base")
            merge_base = self.run_git(
                repository, "rev-parse", "HEAD", capture=True
            ).stdout.strip()

            committed = repository / "committed-mask.txt"
            committed.write_text("committed\n", encoding="ascii")
            self.run_git(repository, "add", committed.name)
            self.run_git(repository, "commit", "-q", "-m", "branch")
            committed.write_text("base\n", encoding="ascii")

            staged = repository / "staged-mask.txt"
            staged.write_text("staged\n", encoding="ascii")
            self.run_git(repository, "add", staged.name)
            staged.write_text("base\n", encoding="ascii")

            (repository / "unstaged.txt").write_text(
                "unstaged\n", encoding="ascii"
            )
            (repository / "untracked.txt").write_text(
                "untracked\n", encoding="ascii"
            )

            self.assertEqual(
                policy.collect_git_paths(merge_base, repository),
                tuple(
                    sorted(
                        (
                            "committed-mask.txt",
                            "staged-mask.txt",
                            "unstaged.txt",
                            "untracked.txt",
                        ),
                        key=os.fsencode,
                    )
                ),
            )


@unittest.skipUnless(
    os.name == "posix" and shutil.which("git") and shutil.which("sh"),
    "verify.sh integration requires a POSIX shell and git",
)
class VerificationShellIntegrationTests(GitRepositoryMixin, unittest.TestCase):
    def make_fake_command(self, path, body):
        path.write_text("#!/bin/sh\n" + body, encoding="ascii")
        path.chmod(0o755)

    def make_repository(self, root):
        repository = root / "repository"
        (repository / "tools").mkdir(parents=True)
        (repository / "bench" / "tests").mkdir(parents=True)
        (repository / "src").mkdir()
        (repository / "examples").mkdir()
        (repository / "tests").mkdir()
        shutil.copy2(
            REPOSITORY_ROOT / "tools" / "verify.sh",
            repository / "tools" / "verify.sh",
        )
        shutil.copy2(
            REPOSITORY_ROOT / "tools" / "verification_policy.py",
            repository / "tools" / "verification_policy.py",
        )
        (repository / "tools" / "verify.sh").chmod(0o755)
        (repository / "bench" / "__init__.py").write_text(
            "", encoding="ascii"
        )
        (repository / "bench" / "tests" / "__init__.py").write_text(
            "", encoding="ascii"
        )
        (
            repository
            / "bench"
            / "tests"
            / "test_public_markdown_policy.py"
        ).write_text(
            "import unittest\n"
            "class PublicMarkdownPolicyTests(unittest.TestCase):\n"
            "    def test_fixture(self):\n"
            "        self.assertTrue(True)\n",
            encoding="ascii",
        )
        (repository / "build.zig").write_text("", encoding="ascii")
        self.initialize_repository(repository)
        self.run_git(repository, "add", ".")
        self.run_git(repository, "commit", "-q", "-m", "base")
        merge_base = self.run_git(
            repository, "rev-parse", "HEAD", capture=True
        ).stdout.strip()

        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        self.make_fake_command(
            fake_bin / "zig",
            'if [ "${1:-}" = "version" ]; then\n'
            "    printf '0.15.2\\n'\n"
            "fi\n"
            "exit 0\n",
        )
        self.make_fake_command(
            fake_bin / "uname",
            "printf 'Linux\\n'\n",
        )
        self.make_fake_command(fake_bin / "rustc", "exit 0\n")
        environment = dict(os.environ)
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        environment["TMPDIR"] = str(root)
        environment.pop("GLACIER_VERIFY_BASE", None)
        environment.pop("GLACIER_VERIFY_REQUIRE_NATIVE", None)
        environment.pop("PYTHONPATH", None)
        return repository, merge_base, environment

    def run_verify(self, repository, merge_base, environment):
        return subprocess.run(
            (
                str(repository / "tools" / "verify.sh"),
                "affected",
                "--base",
                merge_base,
            ),
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_native_strict_mode_and_policy_emitted_target_execution(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)

            darwin_path = (
                repository / "src" / "platform" / "darwin" / "runtime.zig"
            )
            darwin_path.parent.mkdir(parents=True)
            darwin_path.write_text("", encoding="ascii")
            ordinary = self.run_verify(
                repository, merge_base, environment
            )
            self.assertEqual(
                ordinary.returncode,
                0,
                ordinary.stdout + ordinary.stderr,
            )
            self.assertIn(
                "SKIP  native/darwin: requires native Darwin execution",
                ordinary.stdout,
            )

            strict_environment = dict(environment)
            strict_environment["GLACIER_VERIFY_REQUIRE_NATIVE"] = "1"
            strict = self.run_verify(
                repository, merge_base, strict_environment
            )
            self.assertNotEqual(strict.returncode, 0)
            self.assertIn(
                "FAIL  native/darwin: requires native Darwin execution",
                strict.stdout,
            )

            darwin_path.unlink()
            rust_path = (
                repository / "examples" / "interop" / "rust_verify.rs"
            )
            rust_path.parent.mkdir(parents=True)
            rust_path.write_text("fn main() {}\n", encoding="ascii")
            rust = self.run_verify(repository, merge_base, environment)
            self.assertEqual(
                rust.returncode,
                0,
                rust.stdout + rust.stderr,
            )
            self.assertIn("PASS  interop/rust:", rust.stdout)
            for target in policy.RETAINED_TARGETS:
                self.assertIn(
                    "PASS  portability/" + target + "/build:",
                    rust.stdout,
                )
                self.assertIn(
                    "PASS  portability/" + target + "/test-compile:",
                    rust.stdout,
                )


if __name__ == "__main__":
    unittest.main()
