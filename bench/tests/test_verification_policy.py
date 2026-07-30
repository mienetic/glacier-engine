import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import verification_policy as policy


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]

EXPECTED_INTEROP_RUNTIME_FIXTURE_PATHS = frozenset(
    {
        "examples/interop/fixtures/artifact_manifest_v1.hex",
        "examples/interop/fixtures/execution_plan_v1.hex",
        "examples/interop/fixtures/result_envelope_v1.hex",
    }
)

EXPECTED_BENCH_RUNTIME_DATA_PATHS = frozenset(
    {
        "bench/eval-qwen2.5.ids",
        "bench/eval.txt",
        "bench/pair-prefill-natural-pp128.ids",
        "bench/pair-prefill-natural-pp512.ids",
        "bench/pair-prefill-natural-pp2048.ids",
        "bench/pair-prefill-natural-provenance.json",
        "bench/paired.example.json",
    }
)

EXPECTED_AARCH64_CPU_SOURCE_PATHS = frozenset(
    {
        "src/backends/cpu/crc32_arm.c",
        "src/backends/cpu/int4_neon.c",
        "src/backends/cpu/progressive_int4_neon.c",
    }
)

EXPECTED_METAL_NATIVE_SOURCE_PATHS = frozenset(
    {
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
)

EXPECTED_METAL_PORTABLE_SOURCE_PATHS = frozenset(
    {
        "src/core/native_metal_inflight_process_kill_ready.zig",
        "src/backends/metal/allocation_adapter.zig",
        "src/backends/metal/backend.zig",
    }
)

EXPECTED_CORE_CONTRACT_PATHS = frozenset(
    {
        "src/ffi/model_contract_c.zig",
        "include/glacier/model_contract.h",
        "tests/model_contract_c_consumer.c",
        "tests/model_contract_cpp_consumer.cpp",
    }
)

EXPECTED_SHARED_RUNTIME_COMPLETE_PATHS = frozenset(
    {
        "src/model/package_manifest.zig",
        "src/prepared_text_handoff_archive.zig",
        "src/prepared_text_input_archive.zig",
        "src/prepared_text_durable_handoff.zig",
        "src/continuation_live_restart.zig",
    }
)

EXPECTED_DURABLE_RUNTIME_PROFILE_PATHS = frozenset(
    {
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
)

EXPECTED_PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS = frozenset(
    {
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
)

EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS = frozenset(
    {
        "src/prepared_text_direct_terminal.zig",
        "src/prepared_text_direct_terminal_output.zig",
        "src/prepared_text_durable_runtime.zig",
        "src/prepared_text_source_lease.zig",
        "src/prepared_text_terminal_equivalence.zig",
        "src/prepared_text_terminal_source_recovery.zig",
    }
)

EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_DEPENDENCY_PATHS = frozenset(
    {
        "src/core/continuation_checkpoint_file.zig",
        "src/prepared_text_checkpoint.zig",
    }
)

EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_SMOKE_PATHS = frozenset(
    {
        "bench/prepared_text_direct_terminal_recovery.py",
        "bench/tests/test_prepared_text_direct_terminal_recovery.py",
    }
)

EXPECTED_PREPARED_TEXT_RECOVERY_CAMPAIGN_PATHS = frozenset(
    {
        "bench/prepared_text_package.py",
        "bench/prepared_text_recovery_worker.zig",
        "bench/prepared_text_recovery_campaign.py",
        "bench/tests/test_prepared_text_package.py",
        "bench/tests/test_prepared_text_recovery_campaign.py",
    }
)

EXPECTED_PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS = frozenset(
    {
        "src/prepared_text_committed_output.zig",
        "src/prepared_text_committed_output_file.zig",
        "src/cli/prepared_text_result_inspector.zig",
        "bench/prepared_text_committed_output.py",
        "bench/tests/test_prepared_text_committed_output.py",
    }
)

EXPECTED_PROVIDER_EVIDENCE_INSPECTOR_FOCUSED_PATHS = frozenset(
    {
        "src/cli/provider_evidence_inspector.zig",
        "bench/provider_evidence_inspector.py",
        "bench/tests/test_provider_evidence_inspector.py",
    }
)

EXPECTED_DENSE_TENSOR_CLASSIFIER_FOCUSED_PATHS = frozenset(
    {
        "src/core/dense_tensor_classifier.zig",
        "src/core/dense_tensor_reranker.zig",
        "src/core/dense_tensor_family_test.zig",
        "examples/dense_tensor_reranker.zig",
    }
)

EXPECTED_DENSE_TENSOR_EMBEDDING_FOCUSED_PATHS = frozenset(
    {
        "src/core/dense_tensor_embedding.zig",
        "src/core/stateless_embedding_result.zig",
        "examples/dense_tensor_embedding_demo.zig",
    }
)

EXPECTED_DENSE_TENSOR_RETRIEVAL_FOCUSED_PATHS = frozenset(
    {
        "src/core/dense_tensor_retrieval.zig",
        "src/core/stateless_retrieval_result.zig",
    }
)

EXPECTED_DENSE_TENSOR_PYTHON_FOCUSED_PATHS = frozenset(
    {
        "bench/stateless_tensor_result.py",
        "bench/tests/test_stateless_tensor_result.py",
    }
)

EXPECTED_DENSE_TENSOR_RETRIEVAL_PYTHON_FOCUSED_PATHS = frozenset(
    {
        "bench/stateless_retrieval_result.py",
        "bench/tests/test_stateless_retrieval_result.py",
    }
)

EXPECTED_RUNTIME_SUPPORT_INSPECTOR_FOCUSED_PATHS = frozenset(
    {
        "src/core/runtime_support_registry.zig",
        "src/cli/runtime_support_inspector.zig",
        "bench/runtime_support_registry.py",
        "bench/tests/test_runtime_support_inspector.py",
    }
)

EXPECTED_RUNTIME_IMAGE_DURABLE_RECOVERY_CAMPAIGN_PATHS = frozenset(
    {
        "bench/runtime_image_durable_worker.zig",
        "bench/runtime_image_durable_recovery.py",
        "bench/tests/test_runtime_image_durable_recovery.py",
    }
)

EXPECTED_MODEL_CONVERSION_DURABLE_RECOVERY_CAMPAIGN_PATHS = frozenset(
    {
        "bench/model_conversion_durable_worker.zig",
        "bench/model_conversion_durable_recovery.py",
        "bench/tests/test_model_conversion_durable_recovery.py",
    }
)

EXPECTED_PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS = frozenset(
    {
        "src/bounded_file_input.zig",
        "src/cli/model_package.zig",
        "src/cli/text_run.zig",
        "src/model/dense_autoregressive_profile.zig",
        "src/model/package_producer.zig",
        "src/prepared_text_session.zig",
        "src/prepared_text_variable_terminal.zig",
        "bench/prepared_text_package.py",
        "bench/prepared_text_raw_input.py",
        "bench/text_runtime_golden_path.py",
    }
)

EXPECTED_PREPARED_TEXT_PACKAGE_PYTHON_FOCUSED_PATHS = frozenset(
    {
        "bench/tests/test_prepared_text_package.py",
        "bench/tests/test_prepared_text_raw_input.py",
    }
)

EXPECTED_PREPARED_TEXT_UNARY_SERVICE_FOCUSED_PATHS = frozenset(
    {
        "src/prepared_text_unary_service.zig",
        "tests/unary_text_service.zig",
    }
)

EXPECTED_PREPARED_TEXT_UNARY_HTTP_FOCUSED_PATHS = frozenset(
    {
        "src/prepared_text_unary_http_v1.zig",
        "src/server/cancellable_socket_writer.zig",
        "src/server/prepared_text_unary_http.zig",
        "src/client/prepared_text_unary_http.zig",
        "src/server/api.zig",
        "tests/prepared_text_unary_http.zig",
    }
)

EXPECTED_PREPARED_TEXT_UNARY_SERVER_PROCESS_FOCUSED_PATHS = (
    frozenset(
        {
            "tests/prepared_text_unary_server_process.zig",
        }
    )
)

EXPECTED_NATIVE_UNARY_LOAD_FOCUSED_PATHS = frozenset(
    {
        "bench/native_unary_server_load.py",
        "bench/native_unary_server_load_publication.py",
        "bench/tests/test_native_unary_server_load.py",
        "bench/tests/test_native_unary_server_load_publication.py",
    }
)

EXPECTED_WORKLOAD_REPORT_PORTABLE_PATHS = frozenset(
    {
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
        "bench/tests/test_native_metal_supervisor_recovery_death_report.py",
        "bench/tests/test_native_workload_campaign.py",
        "bench/tests/test_native_workload_report.py",
        "bench/tests/test_native_workload_store_fault_report.py",
    }
)

EXPECTED_WORKLOAD_STORE_FAULT_POSIX_PATHS = frozenset(
    {
        "bench/native_metal_soak_report.py",
        "bench/native_workload_store_fault_campaign.py",
        "bench/tests/test_native_metal_soak_report.py",
        "bench/tests/test_native_workload_store_fault_campaign.py",
    }
)

EXPECTED_WORKLOAD_STORE_FAULT_METAL_PATHS = frozenset(
    {
        "bench/native_metal_soak_report.py",
        "bench/tests/test_native_metal_soak_report.py",
    }
)


class VerificationPolicyTests(unittest.TestCase):
    def assert_targets(self, paths, expected):
        plan = policy.classify_paths(paths)
        self.assertEqual(plan.targets, tuple(expected))
        return plan

    def assert_target_steps(self, paths, expected):
        plan = policy.classify_paths(paths)
        self.assertEqual(
            tuple(
                (target_plan.target, target_plan.steps)
                for target_plan in plan.target_plans
            ),
            tuple(expected),
        )
        return plan

    def test_zig_cache_prune_evicts_oldest_top_level_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory).resolve()
            object_root = repository / ".zig-cache" / "o"
            object_root.mkdir(parents=True)
            oldest = object_root / ("1" * 32)
            newest = object_root / ("2" * 32)
            oldest.mkdir()
            newest.mkdir()
            (oldest / "artifact").write_bytes(b"a" * 700_000)
            (newest / "artifact").write_bytes(b"b" * 700_000)
            os.utime(oldest, ns=(1_000_000_000, 1_000_000_000))
            os.utime(newest, ns=(2_000_000_000, 2_000_000_000))

            result = policy.prune_zig_cache(
                repository,
                repository / ".zig-cache",
                1,
            )

            self.assertEqual(("1" * 32,), result.removed_entries)
            self.assertFalse(oldest.exists())
            self.assertTrue(newest.is_dir())
            self.assertLessEqual(result.after_bytes, 1024 * 1024)

    def test_zig_cache_prune_rejects_symlink_and_nonexact_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory).resolve()
            cache = repository / ".zig-cache"
            (cache / "o").mkdir(parents=True)
            outside = repository / "outside"
            outside.mkdir()
            (cache / "o" / ("a" * 32)).symlink_to(
                outside,
                target_is_directory=True,
            )
            with self.assertRaisesRegex(ValueError, "symlink|unexpected"):
                policy.prune_zig_cache(repository, cache, 1)
            with self.assertRaisesRegex(ValueError, "exactly name"):
                policy.prune_zig_cache(repository, outside, 1)

    def test_zig_cache_reset_preflights_then_removes_only_cache_children(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory).resolve()
            cache = repository / ".zig-cache"
            object_entry = cache / "o" / ("a" * 32)
            object_entry.mkdir(parents=True)
            (object_entry / "artifact").write_bytes(b"artifact")
            (cache / "timestamp").write_bytes(b"stamp")
            outside = repository / "outside-sentinel"
            outside.write_bytes(b"keep")

            result = policy.reset_zig_cache(repository, cache)

            self.assertEqual(("o", "timestamp"), result.removed_entries)
            self.assertGreater(result.before_bytes, result.after_bytes)
            self.assertTrue(cache.is_dir())
            self.assertEqual([], list(cache.iterdir()))
            self.assertEqual(b"keep", outside.read_bytes())

    def test_zig_cache_reset_rejects_symlink_before_removing_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory).resolve()
            cache = repository / ".zig-cache"
            cache.mkdir()
            retained = cache / "00-retained"
            retained.write_bytes(b"keep")
            outside = repository / "outside"
            outside.mkdir()
            (cache / "zz-escape").symlink_to(
                outside,
                target_is_directory=True,
            )

            with self.assertRaisesRegex(ValueError, "symlink|unexpected"):
                policy.reset_zig_cache(repository, cache)

            self.assertTrue(retained.is_file())
            with self.assertRaisesRegex(ValueError, "exactly name"):
                policy.reset_zig_cache(repository, outside)
            with self.assertRaisesRegex(ValueError, "filesystem root"):
                policy.reset_zig_cache(Path("/"), Path("/.zig-cache"))

    def test_documentation_only_selects_quick_gates(self):
        plan = self.assert_targets(
            [
                "README.md",
                "docs/CONTRIBUTING.md",
                "docs/example.zig",
                ".github/ISSUE_TEMPLATE/bug.yml",
            ],
            (),
        )
        self.assertEqual(plan.flags, frozenset())
        self.assertTrue(
            all(not decision.host_quick for decision in plan.decisions)
        )

    def test_github_execution_controls_defer_unrelated_target_compiles(self):
        for changed_path in (
            ".github/workflows/ci.yml",
            ".github/actions/setup/action.yml",
            ".github/actions/setup/helper.zig",
            ".github/dependabot.yml",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertFalse(plan.requires("native-full"))
                self.assertTrue(plan.requires("python-full"))
                self.assertTrue(
                    plan.requires("verification-policy-focused")
                )
                self.assertFalse(plan.decisions[0].host_quick)

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
            frozenset({"python-changed", "python-full", "metal-native"}),
        )

    def test_native_metal_workload_report_paths_select_hardware_gate(self):
        for changed_path in (
            "src/backends/metal/native_workload_report.zig",
            "examples/native_metal_workload_report.zig",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset({"metal-native"}),
                )
        for changed_path in (
            "bench/native_metal_workload_report.py",
            "bench/tests/test_native_metal_workload_report.py",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                        }
                    ),
                )

    def test_native_metal_disruption_report_paths_select_hardware_gate(self):
        plan = self.assert_targets(
            ["examples/native_metal_disruption_report.zig"],
            (),
        )
        self.assertEqual(
            plan.flags,
            frozenset({"metal-native"}),
        )
        for changed_path in (
            "bench/native_metal_disruption_report.py",
            "bench/tests/test_native_metal_disruption_report.py",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                        }
                    ),
                )

    def test_native_metal_cancellation_storm_paths_select_hardware_gate(self):
        plan = self.assert_targets(
            ["examples/native_metal_cancellation_storm_report.zig"],
            (),
        )
        self.assertEqual(
            plan.flags,
            frozenset({"metal-native"}),
        )
        for changed_path in (
            "bench/native_metal_cancellation_storm_report.py",
            "bench/tests/test_native_metal_cancellation_storm_report.py",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                        }
                    ),
                )

    def test_native_metal_inflight_process_kill_paths_select_hardware_gate(
        self,
    ):
        plan = self.assert_targets(
            ["examples/native_metal_inflight_process_kill_worker.zig"],
            (),
        )
        self.assertEqual(
            plan.flags,
            frozenset({"metal-native"}),
        )
        plan = self.assert_targets(
            ["src/core/native_metal_inflight_process_kill_ready.zig"],
            policy.RETAINED_TARGETS,
        )
        self.assertEqual(
            plan.flags,
            frozenset(
                {"metal-native", "native-full", "python-full"},
            ),
        )
        self.assertEqual(
            {target_plan.steps for target_plan in plan.target_plans},
            {("profile-device-compile",)},
        )
        for changed_path in (
            "bench/native_metal_inflight_process_kill_report.py",
            "bench/tests/test_native_metal_inflight_process_kill_report.py",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                        }
                    ),
                )

    def test_supervisor_recovery_death_campaign_selects_hardware_gate(
        self,
    ):
        for changed_path in (
            "bench/native_metal_supervisor_recovery_death_campaign.py",
            ("bench/tests/test_native_metal_supervisor_recovery_death_protocol.py"),
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                        }
                    ),
                )

    def test_native_metal_soak_paths_select_hardware_gate(self):
        plan = self.assert_targets(
            ["examples/native_metal_soak_worker.zig"],
            (),
        )
        self.assertEqual(plan.flags, frozenset({"metal-native"}))
        for changed_path in (
            "bench/native_environment_admission.py",
            "bench/tests/test_native_environment_admission.py",
            "bench/tests/test_native_metal_soak_protocol.py",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                        }
                    ),
                )
        for changed_path in sorted(EXPECTED_WORKLOAD_STORE_FAULT_METAL_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "python-changed",
                            "python-full",
                            "metal-native",
                            "workload-store-fault-posix",
                        }
                    ),
                )

    def test_retained_fixture_selects_python_without_zig(self):
        plan = self.assert_targets(["bench/results/reference.json"], ())
        self.assertEqual(plan.flags, frozenset({"python-full"}))

    def test_shared_code_and_build_control_select_every_target(self):
        for changed_path in (
            "src/runtime.zig",
            "include/glacier.h",
            "build.zig",
            "build.zig.zon",
            "cargo.lock",
            "cmakelists.txt",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], policy.RETAINED_TARGETS)
                self.assertTrue(plan.requires("native-full"))
                self.assertTrue(plan.requires("python-full"))
                if changed_path in policy.ZIG_BUILD_GRAPH_CONTROL_PATHS:
                    self.assertTrue(plan.requires("metal-native"))
                    self.assertTrue(plan.requires("build-graph-focused"))
                    self.assertFalse(plan.requires("workload-store-fault-posix"))
                self.assertEqual(
                    tuple(
                        policy.TargetBuildPlan(
                            target,
                            policy.FULL_TARGET_STEPS,
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                    plan.target_plans,
                )
                expected_host_roots = (
                    ()
                    if changed_path in policy.ZIG_BUILD_GRAPH_CONTROL_PATHS
                    else policy.HOST_QUICK_ROOTS
                )
                self.assertEqual(expected_host_roots, plan.decisions[0].host_roots)

    def test_audited_paths_select_focused_target_profiles(self):
        self.assertEqual(
            EXPECTED_CORE_CONTRACT_PATHS,
            policy.CORE_CONTRACT_PATHS,
        )
        self.assertEqual(
            EXPECTED_SHARED_RUNTIME_COMPLETE_PATHS,
            policy.SHARED_RUNTIME_COMPLETE_PATHS,
        )
        self.assertEqual(
            EXPECTED_DURABLE_RUNTIME_PROFILE_PATHS,
            policy.DURABLE_RUNTIME_PROFILE_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS,
            policy.PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS,
            policy.PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_DEPENDENCY_PATHS,
            policy.PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_DEPENDENCY_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_SMOKE_PATHS,
            policy.PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_SMOKE_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_RECOVERY_CAMPAIGN_PATHS,
            policy.PREPARED_TEXT_RECOVERY_CAMPAIGN_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS,
            policy.PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_PROVIDER_EVIDENCE_INSPECTOR_FOCUSED_PATHS,
            policy.PROVIDER_EVIDENCE_INSPECTOR_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_DENSE_TENSOR_CLASSIFIER_FOCUSED_PATHS,
            policy.DENSE_TENSOR_CLASSIFIER_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_DENSE_TENSOR_EMBEDDING_FOCUSED_PATHS,
            policy.DENSE_TENSOR_EMBEDDING_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_DENSE_TENSOR_RETRIEVAL_FOCUSED_PATHS,
            policy.DENSE_TENSOR_RETRIEVAL_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_DENSE_TENSOR_PYTHON_FOCUSED_PATHS,
            policy.DENSE_TENSOR_PYTHON_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_DENSE_TENSOR_RETRIEVAL_PYTHON_FOCUSED_PATHS,
            policy.DENSE_TENSOR_RETRIEVAL_PYTHON_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_RUNTIME_SUPPORT_INSPECTOR_FOCUSED_PATHS,
            policy.RUNTIME_SUPPORT_INSPECTOR_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_RUNTIME_IMAGE_DURABLE_RECOVERY_CAMPAIGN_PATHS,
            policy.RUNTIME_IMAGE_DURABLE_RECOVERY_CAMPAIGN_PATHS,
        )
        self.assertEqual(
            EXPECTED_MODEL_CONVERSION_DURABLE_RECOVERY_CAMPAIGN_PATHS,
            policy.MODEL_CONVERSION_DURABLE_RECOVERY_CAMPAIGN_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS,
            policy.PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_PACKAGE_PYTHON_FOCUSED_PATHS,
            policy.PREPARED_TEXT_PACKAGE_PYTHON_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_UNARY_SERVICE_FOCUSED_PATHS,
            policy.PREPARED_TEXT_UNARY_SERVICE_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_UNARY_HTTP_FOCUSED_PATHS,
            policy.PREPARED_TEXT_UNARY_HTTP_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_PREPARED_TEXT_UNARY_SERVER_PROCESS_FOCUSED_PATHS,
            policy.PREPARED_TEXT_UNARY_SERVER_PROCESS_FOCUSED_PATHS,
        )
        self.assertEqual(
            EXPECTED_NATIVE_UNARY_LOAD_FOCUSED_PATHS,
            policy.NATIVE_UNARY_LOAD_FOCUSED_PATHS,
        )
        for changed_path in sorted(EXPECTED_CORE_CONTRACT_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            ("profile-core-compile",),
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
                self.assertEqual(
                    policy.HOST_CONTRACT_ROOTS,
                    plan.decisions[0].host_roots,
                )
        for changed_path in sorted(EXPECTED_SHARED_RUNTIME_COMPLETE_PATHS):
            with self.subTest(changed_path=changed_path):
                self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            policy.COMPLETE_COMPILE_TARGET_STEPS,
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
        for changed_path in sorted(EXPECTED_DURABLE_RUNTIME_PROFILE_PATHS):
            with self.subTest(changed_path=changed_path):
                self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            ("profile-durable-compile",),
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
        for changed_path in sorted(EXPECTED_PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            ("profile-durable-compile",),
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
                expected_flags = {
                    "native-full",
                    "prepared-text-delivery-focused",
                    "python-full",
                }
                if (
                    changed_path
                    in EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS
                ):
                    expected_flags.add("prepared-text-direct-terminal-smoke-focused")
                if changed_path in EXPECTED_PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS:
                    expected_flags.add("prepared-text-inspector-focused")
                self.assertEqual(
                    frozenset(expected_flags),
                    plan.flags,
                )
                gate_names = policy._gate_names(plan.decisions[0])
                self.assertIn("native/prepared-text-delivery", gate_names)
                if (
                    changed_path
                    in EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_IMPLEMENTATION_PATHS
                ):
                    self.assertIn(
                        "native/prepared-text-direct-terminal-smoke",
                        gate_names,
                    )
                else:
                    self.assertNotIn(
                        "native/prepared-text-direct-terminal-smoke",
                        gate_names,
                    )
                self.assertNotIn("native/prepared-text-recovery", gate_names)
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_SMOKE_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    frozenset(
                        {
                            "prepared-text-direct-terminal-smoke-focused",
                            "python-changed",
                            "python-full",
                        }
                    ),
                    plan.flags,
                )
                self.assertFalse(plan.requires("prepared-text-delivery-focused"))
                self.assertFalse(plan.requires("prepared-text-recovery-focused"))
                gate_names = policy._gate_names(plan.decisions[0])
                self.assertIn(
                    "native/prepared-text-direct-terminal-smoke",
                    gate_names,
                )
                self.assertNotIn(
                    "native/prepared-text-recovery",
                    gate_names,
                )
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_DIRECT_TERMINAL_RECOVERY_DEPENDENCY_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                expected_steps = (
                    policy.COMPLETE_COMPILE_TARGET_STEPS
                    if changed_path == "src/core/continuation_checkpoint_file.zig"
                    else ("profile-durable-compile",)
                )
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (target, expected_steps) for target in policy.RETAINED_TARGETS
                    ),
                )
                self.assertTrue(plan.requires("prepared-text-delivery-focused"))
                self.assertTrue(
                    plan.requires("prepared-text-direct-terminal-smoke-focused")
                )
                self.assertFalse(plan.requires("prepared-text-recovery-focused"))
        for changed_path in sorted(EXPECTED_PREPARED_TEXT_RECOVERY_CAMPAIGN_PATHS):
            if changed_path in (
                EXPECTED_PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS
                | EXPECTED_PREPARED_TEXT_PACKAGE_PYTHON_FOCUSED_PATHS
            ):
                continue
            with self.subTest(changed_path=changed_path):
                expected_targets = (
                    () if changed_path.endswith(".py") else policy.POSIX_TARGETS
                )
                expected_steps = (
                    policy.FULL_TARGET_STEPS
                    if changed_path.endswith(".py")
                    else ("profile-durable-compile",)
                )
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple((target, expected_steps) for target in expected_targets),
                )
                expected_flags = {
                    "prepared-text-recovery-focused",
                    "python-full",
                }
                if changed_path.endswith(".py"):
                    expected_flags.add("python-changed")
                else:
                    expected_flags.add("native-full")
                self.assertEqual(
                    frozenset(expected_flags),
                    plan.flags,
                )
                self.assertFalse(plan.requires("prepared-text-delivery-focused"))
                self.assertFalse(
                    plan.requires("prepared-text-direct-terminal-smoke-focused")
                )
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_PACKAGE_TEXT_RUN_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                expected_targets = (
                    policy.RETAINED_TARGETS if changed_path.endswith(".zig") else ()
                )
                if changed_path == "src/prepared_text_session.zig":
                    expected_steps = (
                        "profile-cpu-compile",
                        "profile-durable-compile",
                        "text-runtime-golden-path-compile",
                    )
                else:
                    expected_steps = (
                        ("text-runtime-golden-path-compile",)
                        if changed_path.endswith(".zig")
                        else policy.FULL_TARGET_STEPS
                    )
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple((target, expected_steps) for target in expected_targets),
                )
                expected_flags = {
                    "prepared-text-package-text-run-focused",
                }
                if changed_path == "src/prepared_text_session.zig":
                    expected_flags.add(
                        "prepared-text-unary-service-focused"
                    )
                if changed_path.endswith(".py"):
                    expected_flags.add("python-changed")
                self.assertEqual(frozenset(expected_flags), plan.flags)
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertFalse(plan.requires("prepared-text-recovery-focused"))
                self.assertFalse(plan.requires("prepared-text-delivery-focused"))
                for target_plan in plan.target_plans:
                    self.assertNotIn(
                        "profile-complete-compile",
                        target_plan.steps,
                    )
                self.assertIn(
                    "native/prepared-text-package-text-run",
                    policy._gate_names(plan.decisions[0]),
                )
                if changed_path == "src/cli/text_run.zig":
                    self.assertNotIn(
                        "native/prepared-text-unary-service",
                        policy._gate_names(plan.decisions[0]),
                    )
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_PACKAGE_PYTHON_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps([changed_path], ())
                self.assertEqual(
                    frozenset(
                        {
                            "prepared-text-package-python-test-focused",
                            "python-changed",
                        }
                    ),
                    plan.flags,
                )
                self.assertEqual((), plan.decisions[0].host_roots)
                self.assertFalse(
                    plan.requires("prepared-text-package-text-run-focused")
                )
                self.assertFalse(plan.requires("python-full"))
                self.assertIn(
                    "python/prepared-text-package",
                    policy._gate_names(plan.decisions[0]),
                )
                self.assertNotIn(
                    "native/prepared-text-package-text-run",
                    policy._gate_names(plan.decisions[0]),
                )
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_UNARY_SERVICE_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                expected_steps = ["unary-text-service-compile"]
                expected_flags = {
                    "prepared-text-unary-service-focused",
                }
                if changed_path == "src/prepared_text_unary_service.zig":
                    expected_steps.extend(
                        (
                            "unary-http-compile",
                            "unary-server-process-compile",
                        )
                    )
                    expected_flags.update(
                        {
                            "prepared-text-unary-http-focused",
                            "prepared-text-unary-server-process-focused",
                        }
                    )
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            tuple(expected_steps),
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
                self.assertEqual(
                    frozenset(expected_flags),
                    plan.flags,
                )
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertIn(
                    "native/prepared-text-unary-service",
                    policy._gate_names(plan.decisions[0]),
                )
                if changed_path == "src/prepared_text_unary_service.zig":
                    self.assertIn(
                        "native/prepared-text-unary-http",
                        policy._gate_names(plan.decisions[0]),
                    )
                else:
                    self.assertNotIn(
                        "native/prepared-text-unary-http",
                        policy._gate_names(plan.decisions[0]),
                    )
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_UNARY_HTTP_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                expected_steps = ["unary-http-compile"]
                expected_flags = {
                    "prepared-text-unary-http-focused"
                }
                if changed_path in {
                    "src/server/api.zig",
                    "src/server/cancellable_socket_writer.zig",
                    "src/server/prepared_text_unary_http.zig",
                }:
                    expected_steps.append(
                        "unary-server-process-compile"
                    )
                    expected_flags.add(
                        "prepared-text-unary-server-process-focused"
                    )
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            tuple(expected_steps),
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
                self.assertEqual(
                    frozenset(expected_flags),
                    plan.flags,
                )
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertFalse(
                    plan.requires("prepared-text-unary-service-focused")
                )
                self.assertIn(
                    "native/prepared-text-unary-http",
                    policy._gate_names(plan.decisions[0]),
                )
        for changed_path in sorted(
            EXPECTED_PREPARED_TEXT_UNARY_SERVER_PROCESS_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            ("unary-server-process-compile",),
                        )
                        for target in policy.RETAINED_TARGETS
                    ),
                )
                self.assertEqual(
                    frozenset(
                        {
                            "prepared-text-unary-server-process-focused",
                            "native-unary-load-focused",
                        }
                    ),
                    plan.flags,
                )
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertFalse(plan.requires("metal-native"))
                self.assertIn(
                    "native/prepared-text-unary-server-process",
                    policy._gate_names(plan.decisions[0]),
                )
                self.assertIn(
                    "python/native-unary-load",
                    policy._gate_names(plan.decisions[0]),
                )
                self.assertEqual(
                    ("unary-server-process-compile",),
                    plan.target_plans[0].steps,
                )
        for changed_path in sorted(
            EXPECTED_RUNTIME_IMAGE_DURABLE_RECOVERY_CAMPAIGN_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            ("profile-durable-compile",),
                        )
                        for target in policy.POSIX_TARGETS
                    ),
                )
                expected_flags = {"native-full", "python-full"}
                if changed_path.endswith(".py"):
                    expected_flags.add("python-changed")
                self.assertEqual(
                    frozenset(expected_flags),
                    plan.flags,
                )
        for changed_path in sorted(
            EXPECTED_MODEL_CONVERSION_DURABLE_RECOVERY_CAMPAIGN_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (
                            target,
                            ("profile-durable-compile",),
                        )
                        for target in policy.POSIX_TARGETS
                    ),
                )
                expected_flags = {"native-full", "python-full"}
                if changed_path.endswith(".py"):
                    expected_flags.add("python-changed")
                self.assertEqual(
                    frozenset(expected_flags),
                    plan.flags,
                )
        cases = {
            "src/core/scheduler.zig": policy.MAIN_RUNTIME_TARGET_STEPS,
            "src/ffi/model_contract_c.zig": ("profile-core-compile",),
            "src/backends/cpu/backend.zig": policy.MAIN_RUNTIME_TARGET_STEPS,
            "src/model/runtime_image.zig": policy.MAIN_RUNTIME_TARGET_STEPS,
            "src/cli/main.zig": ("profile-host-tool-compile",),
            "src/continuation_live_restart.zig": ("profile-complete-compile",),
        }
        for changed_path, steps in cases.items():
            with self.subTest(changed_path=changed_path):
                self.assert_target_steps(
                    [changed_path],
                    tuple((target, steps) for target in policy.RETAINED_TARGETS),
                )

    def test_unary_http_adjacent_server_path_remains_conservative(self):
        plan = self.assert_target_steps(
            ["src/server/unrelated_transport.zig"],
            tuple(
                (target, policy.FULL_TARGET_STEPS)
                for target in policy.RETAINED_TARGETS
            ),
        )
        self.assertTrue(plan.requires("native-full"))
        self.assertTrue(plan.requires("python-full"))
        self.assertFalse(
            plan.requires("prepared-text-unary-http-focused")
        )

    def test_generic_benchmark_path_keeps_full_target_plan(self):
        plan = self.assert_target_steps(
            ["bench/main.zig"],
            tuple(
                (target, policy.FULL_TARGET_STEPS)
                for target in policy.RETAINED_TARGETS
            ),
        )
        self.assertTrue(plan.requires("native-full"))
        self.assertTrue(plan.requires("python-full"))

    def test_variable_terminal_paths_avoid_broad_compile_profiles(self):
        cases = {
            "src/prepared_text_session.zig": (
                "profile-cpu-compile",
                "profile-durable-compile",
                "text-runtime-golden-path-compile",
            ),
            "src/prepared_text_variable_terminal.zig": (
                "text-runtime-golden-path-compile",
            ),
        }
        for changed_path, expected_steps in cases.items():
            with self.subTest(changed_path=changed_path):
                plan = self.assert_target_steps(
                    [changed_path],
                    tuple(
                        (target, expected_steps)
                        for target in policy.RETAINED_TARGETS
                    ),
                )
                expected_flags = {
                    "prepared-text-package-text-run-focused"
                }
                if changed_path == "src/prepared_text_session.zig":
                    expected_flags.add(
                        "prepared-text-unary-service-focused"
                    )
                self.assertEqual(frozenset(expected_flags), plan.flags)
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                for target_plan in plan.target_plans:
                    self.assertNotEqual(
                        policy.COMPLETE_COMPILE_TARGET_STEPS,
                        target_plan.steps,
                    )
                    self.assertNotIn(
                        "profile-complete-compile",
                        target_plan.steps,
                    )

    def test_prepared_text_inspector_paths_select_focused_gate(self):
        for changed_path in sorted(EXPECTED_PREPARED_TEXT_INSPECTOR_FOCUSED_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = policy.classify_paths([changed_path])
                self.assertTrue(plan.requires("prepared-text-inspector-focused"))
                self.assertFalse(plan.requires("prepared-text-recovery-focused"))
                expected_flags = {
                    "prepared-text-inspector-focused",
                    "python-full",
                }
                if changed_path in EXPECTED_PREPARED_TEXT_ACKNOWLEDGED_DELIVERY_PATHS:
                    expected_flags.add("prepared-text-delivery-focused")
                    self.assertTrue(plan.requires("prepared-text-delivery-focused"))
                else:
                    self.assertFalse(plan.requires("prepared-text-delivery-focused"))
                if changed_path.endswith(".py"):
                    expected_flags.add("python-changed")
                    self.assertEqual((), plan.target_plans)
                elif changed_path.startswith("src/cli/"):
                    expected_flags.add("native-full")
                    self.assertEqual(
                        tuple(
                            policy.TargetBuildPlan(
                                target,
                                ("profile-host-tool-compile",),
                            )
                            for target in policy.RETAINED_TARGETS
                        ),
                        plan.target_plans,
                    )
                elif changed_path == "src/prepared_text_committed_output_file.zig":
                    expected_flags.add("native-full")
                    self.assertEqual(
                        tuple(
                            policy.TargetBuildPlan(
                                target,
                                ("profile-durable-compile",),
                            )
                            for target in policy.RETAINED_TARGETS
                        ),
                        plan.target_plans,
                    )
                else:
                    expected_flags.add("native-full")
                    self.assertEqual(
                        tuple(
                            policy.TargetBuildPlan(
                                target,
                                policy.FULL_TARGET_STEPS,
                            )
                            for target in policy.RETAINED_TARGETS
                        ),
                        plan.target_plans,
                    )
                self.assertEqual(frozenset(expected_flags), plan.flags)

    def test_provider_evidence_inspector_paths_select_focused_gate(self):
        for changed_path in sorted(
            EXPECTED_PROVIDER_EVIDENCE_INSPECTOR_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = policy.classify_paths([changed_path])
                if (
                    changed_path
                    == policy.PROVIDER_EVIDENCE_INSPECTOR_PYTHON_TEST_PATH
                ):
                    expected_flags = {
                        "provider-evidence-inspector-python-test-focused",
                        "python-changed",
                    }
                    self.assertEqual((), plan.target_plans)
                    self.assertNotIn(
                        "native/provider-evidence-inspector",
                        policy._gate_names(plan.decisions[0]),
                    )
                    self.assertIn(
                        "python/provider-evidence-inspector",
                        policy._gate_names(plan.decisions[0]),
                    )
                elif changed_path.endswith(".py"):
                    expected_flags = {
                        "provider-evidence-inspector-focused",
                        "python-changed",
                    }
                    self.assertEqual((), plan.target_plans)
                else:
                    expected_flags = {"provider-evidence-inspector-focused"}
                    self.assertEqual(
                        tuple(
                            policy.TargetBuildPlan(
                                target,
                                (
                                    "provider-evidence-inspector-compile",
                                ),
                            )
                            for target in policy.RETAINED_TARGETS
                        ),
                        plan.target_plans,
                    )
                self.assertEqual(frozenset(expected_flags), plan.flags)
                if changed_path != (
                    policy.PROVIDER_EVIDENCE_INSPECTOR_PYTHON_TEST_PATH
                ):
                    self.assertIn(
                        "native/provider-evidence-inspector",
                        policy._gate_names(plan.decisions[0]),
                    )
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertEqual((), plan.decisions[0].host_roots)

    def test_dense_tensor_implementations_select_shared_family_roots(self):
        all_paths = (
            EXPECTED_DENSE_TENSOR_CLASSIFIER_FOCUSED_PATHS
            | EXPECTED_DENSE_TENSOR_EMBEDDING_FOCUSED_PATHS
            | EXPECTED_DENSE_TENSOR_RETRIEVAL_FOCUSED_PATHS
        )
        for changed_path in sorted(all_paths):
            with self.subTest(changed_path=changed_path):
                plan = policy.classify_paths([changed_path])
                decision = plan.decisions[0]
                expected_steps = ("dense-tensor-family-compile",)
                expected_flags = {"dense-tensor-family-focused"}
                if changed_path in {
                    "src/core/dense_tensor_classifier.zig",
                    "src/core/dense_tensor_reranker.zig",
                    "src/core/dense_tensor_embedding.zig",
                    "src/core/dense_tensor_retrieval.zig",
                }:
                    expected_flags.add("runtime-support-inspector-focused")
                    expected_steps = (
                        "dense-tensor-family-compile",
                        "runtime-support-inspector-compile",
                    )
                self.assertEqual(frozenset(expected_flags), plan.flags)
                self.assertEqual((), decision.host_roots)
                self.assertEqual(
                    tuple(
                        policy.TargetBuildPlan(target, expected_steps)
                        for target in policy.RETAINED_TARGETS
                    ),
                    plan.target_plans,
                )
                self.assertIn(
                    "native/dense-tensor-family",
                    policy._gate_names(decision),
                )

    def test_dense_tensor_python_paths_select_exact_modules_without_zig(self):
        cases = (
            (
                policy.DENSE_TENSOR_PYTHON_FOCUSED_PATHS,
                "dense-tensor-family-python-test-focused",
                "python/dense-tensor-family",
            ),
            (
                policy.DENSE_TENSOR_EMBEDDING_PYTHON_FOCUSED_PATHS,
                "dense-tensor-embedding-python-test-focused",
                "python/dense-tensor-embedding",
            ),
            (
                policy.DENSE_TENSOR_RETRIEVAL_PYTHON_FOCUSED_PATHS,
                "dense-tensor-retrieval-python-test-focused",
                "python/dense-tensor-retrieval",
            ),
        )
        for paths, flag, gate in cases:
            for changed_path in sorted(paths):
                with self.subTest(changed_path=changed_path):
                    plan = policy.classify_paths([changed_path])
                    self.assertEqual(
                        frozenset({flag, "python-changed"}),
                        plan.flags,
                    )
                    self.assertEqual((), plan.target_plans)
                    self.assertEqual((), plan.decisions[0].host_roots)
                    self.assertIn(gate, policy._gate_names(plan.decisions[0]))

    def test_shared_stateless_tensor_result_selects_only_tensor_families(self):
        plan = policy.classify_paths(
            [policy.STATELESS_TENSOR_RESULT_SHARED_PATH]
        )

        self.assertEqual(
            frozenset({"dense-tensor-family-focused"}),
            plan.flags,
        )
        self.assertEqual(
            tuple(
                policy.TargetBuildPlan(
                    target,
                    ("dense-tensor-family-compile",),
                )
                for target in policy.RETAINED_TARGETS
            ),
            plan.target_plans,
        )
        self.assertEqual((), plan.decisions[0].host_roots)
        self.assertFalse(plan.requires("native-full"))
        self.assertFalse(plan.requires("python-full"))

    def test_python_contract_consumer_selects_exact_host_root(self):
        plan = policy.classify_paths([policy.INTEROP_PYTHON_CONSUMER_PATH])

        self.assertEqual(frozenset({"python-changed"}), plan.flags)
        self.assertEqual((), plan.target_plans)
        self.assertEqual(
            policy.HOST_CONTRACT_ROOTS,
            plan.decisions[0].host_roots,
        )
        self.assertFalse(plan.requires("native-full"))
        self.assertFalse(plan.requires("python-full"))

    def test_runtime_support_inspector_paths_select_exact_focused_roots(self):
        for changed_path in sorted(
            EXPECTED_RUNTIME_SUPPORT_INSPECTOR_FOCUSED_PATHS
        ):
            with self.subTest(changed_path=changed_path):
                plan = policy.classify_paths([changed_path])
                decision = plan.decisions[0]
                if (
                    changed_path
                    == policy.RUNTIME_SUPPORT_INSPECTOR_PYTHON_TEST_PATH
                ):
                    self.assertEqual(
                        frozenset(
                            {
                                "runtime-support-inspector-python-test-focused",
                                "python-changed",
                            }
                        ),
                        plan.flags,
                    )
                    self.assertEqual((), plan.target_plans)
                    self.assertEqual((), decision.host_roots)
                    continue
                if changed_path.endswith(".py"):
                    self.assertEqual(
                        frozenset(
                            {
                                "runtime-support-inspector-focused",
                                "python-changed",
                            }
                        ),
                        plan.flags,
                    )
                    self.assertEqual((), plan.target_plans)
                    self.assertEqual((), decision.host_roots)
                    continue

                expected_steps = ("runtime-support-inspector-compile",)
                expected_roots = ()
                if changed_path.startswith("src/core/"):
                    expected_steps = (
                        "profile-core-compile",
                        "runtime-support-inspector-compile",
                    )
                    expected_roots = policy.HOST_CONTRACT_ROOTS
                self.assertEqual(
                    frozenset({"runtime-support-inspector-focused"}),
                    plan.flags,
                )
                self.assertEqual(expected_roots, decision.host_roots)
                self.assertEqual(
                    tuple(
                        policy.TargetBuildPlan(target, expected_steps)
                        for target in policy.RETAINED_TARGETS
                    ),
                    plan.target_plans,
                )
                self.assertIn(
                    "native/runtime-support-inspector",
                    policy._gate_names(decision),
                )

    def test_profile_prefixes_are_case_sensitive_and_roots_fail_closed(self):
        for changed_path in (
            "src/core/root.zig",
            "Src/Core/scheduler.zig",
            "src/Core/windows.zig",
            "src/Backends/cpu/backend.zig",
            "Src/Backends/Metal/backend.zig",
            "src/platform/POSIX/files.zig",
            "src/cli/main.ZIG",
            "Bench/metal_kernel.zig",
            "Tests/metal_correctness.zig",
            "Examples/interop/rust_verify.rs",
            "src/backends/cuda/backend.zig",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets(
                    [changed_path],
                    policy.RETAINED_TARGETS,
                )
                self.assertTrue(
                    all(
                        target_plan.steps == policy.FULL_TARGET_STEPS
                        for target_plan in plan.target_plans
                    )
                )

    def test_target_profiles_union_and_full_dominance_are_per_target(self):
        main_plus_focused = self.assert_target_steps(
            [
                "src/core/scheduler.zig",
                "src/cli/main.zig",
            ],
            tuple(
                (
                    target,
                    policy.MAIN_RUNTIME_TARGET_STEPS,
                )
                for target in policy.RETAINED_TARGETS
            ),
        )
        self.assertTrue(main_plus_focused.requires("native-full"))

        main_plus_complete = self.assert_target_steps(
            [
                "src/core/scheduler.zig",
                "src/continuation_live_restart.zig",
            ],
            tuple(
                (
                    target,
                    policy.FULL_TARGET_STEPS,
                )
                for target in policy.RETAINED_TARGETS
            ),
        )
        self.assertTrue(main_plus_complete.requires("native-full"))

        per_target = self.assert_target_steps(
            [
                "src/core/scheduler.zig",
                "src/platform/windows/dispatch.zig",
            ],
            (
                (
                    policy.RETAINED_TARGETS[0],
                    policy.MAIN_RUNTIME_TARGET_STEPS,
                ),
                (
                    policy.RETAINED_TARGETS[1],
                    policy.MAIN_RUNTIME_TARGET_STEPS,
                ),
                (
                    policy.RETAINED_TARGETS[2],
                    policy.FULL_TARGET_STEPS,
                ),
                (
                    policy.RETAINED_TARGETS[3],
                    policy.MAIN_RUNTIME_TARGET_STEPS,
                ),
            ),
        )
        self.assertTrue(per_target.requires("native-full"))

    def test_rust_source_selects_the_native_rust_gate(self):
        plan = self.assert_targets(
            ["examples/interop/rust_verify.rs"],
            (),
        )
        self.assertEqual(plan.flags, frozenset({"rust-native"}))

    def test_runtime_inputs_do_not_select_foreign_compilation(self):
        self.assertEqual(
            EXPECTED_INTEROP_RUNTIME_FIXTURE_PATHS,
            policy.INTEROP_RUNTIME_FIXTURE_PATHS,
        )
        self.assertEqual(
            EXPECTED_BENCH_RUNTIME_DATA_PATHS,
            policy.BENCH_RUNTIME_DATA_PATHS,
        )
        for changed_path in sorted(EXPECTED_INTEROP_RUNTIME_FIXTURE_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    frozenset({"python-full", "rust-native"}),
                    plan.flags,
                )
                self.assertTrue(plan.decisions[0].host_quick)
                self.assertEqual(
                    policy.HOST_CONTRACT_ROOTS,
                    plan.decisions[0].host_roots,
                )
        for changed_path in sorted(EXPECTED_BENCH_RUNTIME_DATA_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(frozenset({"python-full"}), plan.flags)
                self.assertFalse(plan.decisions[0].host_quick)

    def test_prepared_text_result_sink_python_paths_stay_python_only(self):
        for changed_path in (
            "bench/prepared_text_result_sink.py",
            "bench/tests/test_prepared_text_result_sink.py",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    frozenset({"python-changed", "python-full"}),
                    plan.flags,
                )

    def test_workload_report_paths_select_only_the_focused_portable_gate(self):
        self.assertEqual(
            EXPECTED_WORKLOAD_REPORT_PORTABLE_PATHS,
            policy.WORKLOAD_REPORT_PORTABLE_PATHS,
        )
        for changed_path in sorted(EXPECTED_WORKLOAD_REPORT_PORTABLE_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                expected_flags = {"workload-report-portable"}
                if changed_path.endswith(".py"):
                    expected_flags.add("python-changed")
                self.assertEqual(frozenset(expected_flags), plan.flags)
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertFalse(plan.requires("metal-native"))
                gate_names = policy._gate_names(plan.decisions[0])
                self.assertIn("portable/workload-report", gate_names)
                self.assertNotIn("native/metal", gate_names)
                self.assertNotIn(
                    "native/workload-store-fault",
                    gate_names,
                )

    def test_native_unary_load_paths_select_only_the_focused_python_gate(self):
        self.assertEqual(
            EXPECTED_NATIVE_UNARY_LOAD_FOCUSED_PATHS,
            policy.NATIVE_UNARY_LOAD_FOCUSED_PATHS,
        )
        for changed_path in sorted(EXPECTED_NATIVE_UNARY_LOAD_FOCUSED_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                self.assertEqual(
                    frozenset(
                        {
                            "native-unary-load-focused",
                            "python-changed",
                        }
                    ),
                    plan.flags,
                )
                self.assertFalse(plan.requires("native-full"))
                self.assertFalse(plan.requires("python-full"))
                self.assertFalse(
                    plan.requires(
                        "prepared-text-unary-server-process-focused"
                    )
                )
                self.assertEqual(
                    ("quick", "python/changed-syntax", "python/native-unary-load"),
                    policy._gate_names(plan.decisions[0]),
                )

    def test_workload_store_fault_paths_select_the_native_posix_gate(self):
        self.assertEqual(
            EXPECTED_WORKLOAD_STORE_FAULT_POSIX_PATHS,
            policy.WORKLOAD_STORE_FAULT_POSIX_PATHS,
        )
        self.assertEqual(
            EXPECTED_WORKLOAD_STORE_FAULT_METAL_PATHS,
            policy.WORKLOAD_STORE_FAULT_METAL_PATHS,
        )
        for changed_path in sorted(EXPECTED_WORKLOAD_STORE_FAULT_POSIX_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                expected_flags = {
                    "python-changed",
                    "workload-store-fault-posix",
                }
                if changed_path in EXPECTED_WORKLOAD_STORE_FAULT_METAL_PATHS:
                    expected_flags.update({"metal-native", "python-full"})
                self.assertEqual(frozenset(expected_flags), plan.flags)
                self.assertFalse(plan.requires("native-full"))
                gate_names = policy._gate_names(plan.decisions[0])
                self.assertIn("native/workload-store-fault", gate_names)
                self.assertNotIn("portable/workload-report", gate_names)

    def test_workload_store_fault_codec_and_campaign_union_both_gates(self):
        plan = self.assert_targets(
            [
                "bench/native_workload_store_fault_report.py",
                "bench/native_workload_store_fault_campaign.py",
            ],
            (),
        )
        self.assertEqual(
            frozenset(
                {
                    "python-changed",
                    "workload-report-portable",
                    "workload-store-fault-posix",
                }
            ),
            plan.flags,
        )

    def test_workload_report_path_near_misses_fail_closed(self):
        cases = {
            "src/core/native_workload_report_v2.zig": frozenset(
                {"native-full", "python-full"}
            ),
            "examples/native_workload_report_copy.zig": frozenset(
                {"native-full", "python-full"}
            ),
            "bench/native_workload_report_copy.py": frozenset(
                {"python-changed", "python-full"}
            ),
            "bench/tests/test_native_workload_report_copy.py": frozenset(
                {"python-changed", "python-full"}
            ),
            "Src/Core/native_workload_report.zig": frozenset(
                {"native-full", "python-full"}
            ),
        }
        for changed_path, expected_flags in cases.items():
            with self.subTest(changed_path=changed_path):
                plan = policy.classify_paths([changed_path])
                self.assertEqual(expected_flags, plan.flags)
                self.assertFalse(plan.requires("workload-report-portable"))
                self.assertFalse(plan.requires("metal-native"))

    def test_workload_report_and_native_metal_gates_remain_independent(self):
        plan = policy.classify_paths(
            [
                "src/core/native_workload_report.zig",
                "tests/native_metal_observation.zig",
            ]
        )
        self.assertTrue(plan.requires("workload-report-portable"))
        self.assertTrue(plan.requires("metal-native"))
        self.assertFalse(plan.requires("native-full"))
        self.assertEqual((), plan.targets)

    def test_unknown_interop_hex_fixture_remains_conservative(self):
        for changed_path in (
            "examples/interop/fixtures/new.hex",
            "examples/interop/fixtures/nested/new.hex",
        ):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets(
                    [changed_path],
                    policy.RETAINED_TARGETS,
                )
                self.assertTrue(plan.requires("native-full"))
                self.assertTrue(plan.requires("python-full"))
                self.assertTrue(plan.decisions[0].host_quick)

    def test_swift_probe_uses_focused_darwin_typecheck_gate(self):
        plan = self.assert_targets(["bench/lane4_process_info.swift"], ())
        self.assertEqual(
            frozenset({"darwin-swift", "python-full"}),
            plan.flags,
        )

    def test_aarch64_cpu_sources_select_only_aarch64_linux(self):
        self.assertEqual(
            EXPECTED_AARCH64_CPU_SOURCE_PATHS,
            policy.AARCH64_CPU_SOURCE_PATHS,
        )
        for changed_path in sorted(EXPECTED_AARCH64_CPU_SOURCE_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets(
                    [changed_path],
                    policy.AARCH64_LINUX_TARGETS,
                )
                self.assertEqual(
                    (
                        policy.TargetBuildPlan(
                            policy.AARCH64_LINUX_TARGETS[0],
                            (
                                "profile-cpu-compile",
                                "profile-host-tool-compile",
                            ),
                        ),
                    ),
                    plan.target_plans,
                )
                self.assertTrue(plan.requires("darwin-aarch64-native"))
                self.assertTrue(plan.requires("native-full"))
                self.assertTrue(plan.requires("python-full"))

    def test_platform_specific_paths_select_only_relevant_targets(self):
        cases = {
            "src/platform/windows/dispatch.zig": policy.WINDOWS_TARGETS,
            "src/platform/linux/memory.zig": policy.LINUX_TARGETS,
            "src/platform/freebsd/memory.zig": policy.FREEBSD_TARGETS,
            "src/platform/posix/files.zig": policy.POSIX_TARGETS,
            "src/platform/unix/files.zig": policy.POSIX_TARGETS,
            "src/platform/windows.zig": policy.WINDOWS_TARGETS,
            "bench/native_observer_linux.zig": policy.LINUX_TARGETS,
        }
        for changed_path, expected in cases.items():
            with self.subTest(changed_path=changed_path):
                self.assert_targets([changed_path], expected)
        posix = policy.classify_paths(["src/platform/posix/files.zig"])
        self.assertTrue(posix.requires("darwin-native"))
        unix = policy.classify_paths(["src/platform/unix/files.zig"])
        self.assertTrue(unix.requires("darwin-native"))

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

    def test_mixed_aarch64_and_windows_changes_keep_ordered_union(self):
        plan = self.assert_targets(
            [
                "src/backends/cpu/int4_neon.c",
                "src/platform/windows/dispatch.zig",
            ],
            policy.AARCH64_LINUX_TARGETS + policy.WINDOWS_TARGETS,
        )
        self.assertEqual(
            (
                policy.TargetBuildPlan(
                    policy.AARCH64_LINUX_TARGETS[0],
                    (
                        "profile-cpu-compile",
                        "profile-host-tool-compile",
                    ),
                ),
                policy.TargetBuildPlan(
                    policy.WINDOWS_TARGETS[0],
                    policy.FULL_TARGET_STEPS,
                ),
            ),
            plan.target_plans,
        )
        self.assertTrue(plan.requires("darwin-aarch64-native"))
        self.assertTrue(plan.requires("native-full"))
        self.assertTrue(plan.requires("python-full"))

    def test_specialized_path_plus_shared_code_restores_every_target(self):
        plan = self.assert_targets(
            [
                "src/backends/cpu/int4_neon.c",
                "src/root.zig",
            ],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(plan.requires("darwin-aarch64-native"))
        self.assertTrue(plan.requires("native-full"))
        self.assertTrue(plan.requires("python-full"))

    def test_metal_paths_are_audited_and_unknowns_fail_closed(self):
        self.assertEqual(
            EXPECTED_METAL_NATIVE_SOURCE_PATHS,
            policy.METAL_NATIVE_SOURCE_PATHS,
        )
        self.assertEqual(
            EXPECTED_METAL_PORTABLE_SOURCE_PATHS,
            policy.METAL_PORTABLE_SOURCE_PATHS,
        )
        for changed_path in sorted(EXPECTED_METAL_PORTABLE_SOURCE_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets(
                    [changed_path],
                    policy.RETAINED_TARGETS,
                )
                self.assertEqual(
                    plan.flags,
                    frozenset(
                        {
                            "metal-native",
                            "native-full",
                            "python-full",
                        }
                    ),
                )
                self.assertTrue(
                    all(
                        target_plan.steps == ("profile-device-compile",)
                        for target_plan in plan.target_plans
                    )
                )
                self.assertTrue(
                    policy._requires_generic_host_zig(plan.decisions[0])
                )
        for changed_path in sorted(EXPECTED_METAL_NATIVE_SOURCE_PATHS):
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], ())
                expected_flags = {"metal-native"}
                if changed_path.endswith(".py"):
                    expected_flags.update({"python-changed", "python-full"})
                self.assertEqual(
                    plan.flags,
                    frozenset(expected_flags),
                )
                self.assertFalse(
                    policy._requires_generic_host_zig(plan.decisions[0])
                )

        for changed_path in (
            "tests/metal_future.zig",
            "src/backends/experimental/shader.metal",
        ):
            with self.subTest(changed_path=changed_path):
                unclassified = self.assert_targets(
                    [changed_path],
                    policy.RETAINED_TARGETS,
                )
                self.assertEqual(
                    frozenset({"metal-native", "native-full", "python-full"}),
                    unclassified.flags,
                )
                self.assertTrue(
                    all(
                        target_plan.steps == policy.FULL_TARGET_STEPS
                        for target_plan in unclassified.target_plans
                    )
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
                self.assertFalse(plan.decisions[0].host_quick)

    def test_python_shell_and_fixtures_override_platform_name(self):
        cases = {
            "bench/linux/adapter.py": frozenset({"python-changed", "python-full"}),
            "docs/linux/example.py": frozenset({"python-changed", "python-full"}),
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
        self.assertEqual(
            policy.HOST_QUICK_ROOTS,
            plan.decisions[0].host_roots,
        )

        root_plan = self.assert_targets(
            ["new-runtime-input"],
            policy.RETAINED_TARGETS,
        )
        self.assertTrue(root_plan.requires("native-full"))
        self.assertEqual(
            policy.HOST_QUICK_ROOTS,
            root_plan.decisions[0].host_roots,
        )

    def test_verifier_controls_select_every_target(self):
        self.assertEqual(
            {
                "tools/verification_policy.py",
                "tools/verify.sh",
                "bench/tests/test_local_verify.py",
                "bench/tests/test_verification_policy.py",
            },
            policy.VERIFICATION_POLICY_FOCUSED_PATHS,
        )
        shell_plan = self.assert_targets(
            ["tools/verify.sh"],
            (),
        )
        self.assertTrue(shell_plan.requires("shell-changed"))
        self.assertFalse(shell_plan.requires("native-full"))
        self.assertTrue(shell_plan.requires("verification-policy-focused"))
        self.assertFalse(shell_plan.requires("workload-store-fault-posix"))

        python_plan = self.assert_targets(
            ["tools/verification_policy.py"],
            (),
        )
        self.assertTrue(python_plan.requires("python-changed"))
        self.assertFalse(python_plan.requires("native-full"))
        self.assertTrue(python_plan.requires("verification-policy-focused"))
        self.assertFalse(python_plan.requires("workload-store-fault-posix"))

        regression_plan = self.assert_targets(
            ["bench/tests/test_verification_policy.py"],
            (),
        )
        self.assertEqual(
            frozenset(
                {
                    "python-changed",
                    "python-full",
                    "verification-policy-focused",
                }
            ),
            regression_plan.flags,
        )

        wrapper_plan = self.assert_targets(
            ["tools/zig-with-ephemeral-cache.sh"],
            (),
        )
        self.assertEqual(
            frozenset({"python-full", "shell-changed"}),
            wrapper_plan.flags,
        )

    def test_control_paths_are_case_normalized(self):
        cases = {
            "Tools/Verification_Policy.py": (
                (),
                frozenset(
                    {
                        "python-changed",
                        "python-full",
                        "verification-policy-focused",
                    }
                ),
            ),
            "Tools/Verify.SH": (
                (),
                frozenset(
                    {
                        "python-full",
                        "shell-changed",
                        "verification-policy-focused",
                    }
                ),
            ),
            "Tools/Zig-With-Ephemeral-Cache.SH": (
                (),
                frozenset({"python-full", "shell-changed"}),
            ),
            "Build.zig": (
                policy.RETAINED_TARGETS,
                frozenset(
                    {
                        "build-graph-focused",
                        "metal-native",
                        "native-full",
                        "python-full",
                    }
                ),
            ),
        }
        for changed_path, (targets, flags) in cases.items():
            with self.subTest(changed_path=changed_path):
                plan = self.assert_targets([changed_path], targets)
                self.assertEqual(flags, plan.flags)

    def test_build_graph_keeps_profiles_and_benchmarks_opt_in(self):
        source = (REPOSITORY_ROOT / "build.zig").read_text(encoding="utf-8")
        for step in policy.FOCUSED_TARGET_STEPS:
            with self.subTest(step=step):
                self.assertEqual(1, source.count('"' + step + '"'))
        self.assertEqual(
            1,
            source.count('"profile-complete-compile"'),
        )
        self.assertEqual(
            1,
            source.count('"native-metal-suite-compile"'),
        )
        self.assertEqual(
            1,
            source.count('"host-runtime-compile"'),
        )
        self.assertEqual(
            1,
            source.count('"text-runtime-golden-path-compile"'),
        )
        self.assertEqual(
            1,
            source.count('"text-runtime-golden-path-test"'),
        )
        self.assertIn(
            "text_runtime_golden_path_compile_step.dependOn(&exe.step);",
            source,
        )
        self.assertIn(
            "test_compile_step.dependOn(text_runtime_golden_path_compile_step);",
            source,
        )
        self.assertIn(
            "const text_runtime_golden_path_native_available =\n"
            "        (target.result.os.tag == .macos or\n"
            "            target.result.os.tag == .linux or\n"
            "            target.result.os.tag == .freebsd) and\n"
            "        target.result.cpu.arch == builtin.cpu.arch and\n"
            "        target.result.os.tag == builtin.os.tag and\n"
            "        target.result.abi == builtin.abi;",
            source,
        )
        self.assertIn(
            '"text-runtime-golden-path-test requires a native macOS, Linux, "'
            ' ++\n                "or FreeBSD target"',
            source,
        )
        self.assertEqual(
            1,
            source.count('"bench.tests.test_prepared_text_raw_input"'),
        )
        self.assertEqual(
            2,
            source.count('"bench.tests.test_prepared_text_package"'),
        )
        self.assertEqual(
            1,
            source.count('"bench.text_runtime_golden_path"'),
        )
        self.assertIn(
            'b.getInstallPath(.bin, "glacier"),',
            source,
        )
        self.assertIn(
            "run_text_runtime_golden_path.step.dependOn(cli_install_step);",
            source,
        )
        self.assertNotIn(
            "native_metal_suite_compile_step.dependOn(\n"
            "            profile_device_compile_step,",
            source,
        )
        self.assertNotIn(
            "native_metal_suite_compile_step.dependOn(\n"
            "            profile_host_tool_compile_step,",
            source,
        )
        self.assertIn(
            "run_text_runtime_golden_path.step.dependOn(\n"
            "            &run_text_runtime_binding_model.step,\n"
            "        );",
            source,
        )
        self.assertIn(
            "test_step.dependOn(text_runtime_golden_path_test_step);",
            source,
        )
        self.assertIn('"install-benchmarks"', source)
        self.assertIn('"native-metal-correctness-test"', source)
        self.assertEqual(
            1,
            source.count('"native-workload-store-fault-test"'),
        )
        self.assertIn(
            "test_step.dependOn(native_workload_store_fault_report_test_step)",
            source,
        )
        self.assertIn(
            "native_workload_store_fault_report_test_step.dependOn(\n"
            "        &run_native_workload_store_fault_report_verifier_tests.step,\n"
            "    )",
            source,
        )
        self.assertIn(
            "native_workload_store_fault_report_compile_step.dependOn(\n"
            "        &native_workload_store_fault_report_verifier_tests.step,\n"
            "    )",
            source,
        )
        self.assertNotIn(
            "test_step.dependOn(native_workload_store_fault_test_step)",
            source,
        )
        self.assertEqual(
            1,
            source.count(
                "b.getInstallStep().dependOn(&install_exe.step);"
            ),
        )
        self.assertEqual(
            1,
            source.count(
                "b.getInstallStep().dependOn(&install_stripped.step);"
            ),
        )
        self.assertNotIn(
            "run_cmd.step.dependOn(b.getInstallStep())",
            source,
        )
        self.assertNotIn(
            "profile_cpu_compile_step.dependOn(profile_core_compile_step)",
            source,
        )
        self.assertIn(
            "profile_core_compile_step.dependOn(\n"
            "        &contract_installed_c_consumer.step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "profile_host_tool_compile_step.dependOn(\n"
            "        runtime_support_inspector_compile_step,\n"
            "    );",
            source,
        )
        self.assertEqual(
            1,
            source.count('"prepared-text-acknowledged-delivery-test"'),
        )
        self.assertEqual(
            1,
            source.count('"prepared-text-acknowledged-delivery-compile"'),
        )
        self.assertIn(
            "prepared_text_acknowledged_delivery_compile_step"
            ".dependOn(\n"
            "        &prepared_text_acknowledged_delivery_tests.step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "test_step.dependOn(\n"
            "        prepared_text_acknowledged_delivery_test_step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "test_compile_step.dependOn(\n"
            "        prepared_text_acknowledged_delivery_compile_step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "profile_durable_compile_step.dependOn(\n"
            "        prepared_text_acknowledged_delivery_compile_step,\n"
            "    );",
            source,
        )
        self.assertNotIn(
            '"prepared-text-recovery-compile"',
            source,
        )
        self.assertEqual(
            1,
            source.count('"prepared-text-recovery-test"'),
        )
        self.assertEqual(
            1,
            source.count('"prepared-text-direct-terminal-recovery-smoke-test"'),
        )
        self.assertNotIn(
            '"prepared-text-direct-terminal-recovery-smoke-compile"',
            source,
        )
        self.assertEqual(
            1,
            source.count('"bench/prepared_text_recovery_worker.zig"'),
        )
        self.assertEqual(
            2,
            source.count('"bench.tests.test_prepared_text_package"'),
        )
        self.assertEqual(
            1,
            source.count('"bench.tests.test_prepared_text_direct_terminal_recovery"'),
        )
        self.assertEqual(
            1,
            source.count('"bench.prepared_text_direct_terminal_recovery"'),
        )
        self.assertEqual(
            1,
            source.count('"prepared-text-direct-terminal-recovery-smoke"'),
        )
        self.assertIn(
            "const prepared_text_recovery_target_available =\n"
            "        target.result.os.tag == .macos or\n"
            "        target.result.os.tag == .linux or\n"
            "        target.result.os.tag == .freebsd;",
            source,
        )
        self.assertIn(
            "if (!prepared_text_recovery_target_available) break :blk null;",
            source,
        )
        self.assertIn(
            "run_prepared_text_recovery_campaign.addArtifactArg(\n"
            "            prepared_text_recovery_worker_exe.?,\n"
            "        );",
            source,
        )
        self.assertIn(
            "run_prepared_text_direct_terminal_recovery_smoke"
            ".addArtifactArg(\n"
            "            prepared_text_recovery_worker_exe.?,\n"
            "        );",
            source,
        )
        self.assertIn(
            "run_prepared_text_direct_terminal_recovery_smoke"
            ".step.dependOn(\n"
            "            &run_prepared_text_recovery_model.step,\n"
            "        );",
            source,
        )
        self.assertIn(
            "prepared_text_recovery_test_step.dependOn(\n"
            "        prepared_text_direct_terminal_recovery_smoke_test_step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "test_step.dependOn(prepared_text_recovery_test_step);",
            source,
        )
        self.assertIn(
            "if (prepared_text_recovery_worker_exe) |worker|\n"
            "        test_compile_step.dependOn(&worker.step);",
            source,
        )
        self.assertIn(
            "if (prepared_text_recovery_worker_exe) |worker|\n"
            "        profile_durable_compile_step.dependOn(&worker.step);",
            source,
        )
        self.assertIn(
            '"prepared-text-recovery-test requires a native macOS or Linux "',
            source,
        )
        self.assertEqual(
            1,
            source.count('"runtime-image-durable-recovery-test"'),
        )
        self.assertEqual(
            1,
            source.count('"bench/runtime_image_durable_worker.zig"'),
        )
        self.assertIn(
            "const runtime_image_durable_recovery_target_available =\n"
            "        target.result.os.tag == .macos or\n"
            "        target.result.os.tag == .linux or\n"
            "        target.result.os.tag == .freebsd;",
            source,
        )
        self.assertIn(
            "run_runtime_image_durable_recovery_campaign.addArtifactArg(\n"
            "            runtime_image_durable_recovery_worker_exe.?,\n"
            "        );",
            source,
        )
        self.assertIn(
            "test_step.dependOn(runtime_image_durable_recovery_test_step);",
            source,
        )
        self.assertIn(
            "if (runtime_image_durable_recovery_worker_exe) |worker|\n"
            "        test_compile_step.dependOn(&worker.step);",
            source,
        )
        self.assertIn(
            "if (runtime_image_durable_recovery_worker_exe) |worker|\n"
            "        profile_durable_compile_step.dependOn(&worker.step);",
            source,
        )
        self.assertIn(
            '"runtime-image-durable-recovery-test requires a native macOS "',
            source,
        )
        self.assertEqual(
            1,
            source.count('"model-conversion-durable-recovery-test"'),
        )
        self.assertEqual(
            1,
            source.count('"bench/model_conversion_durable_worker.zig"'),
        )
        self.assertEqual(
            1,
            source.count('"bench.tests.test_model_conversion_durable_recovery"'),
        )
        self.assertEqual(
            1,
            source.count('"bench.model_conversion_durable_recovery"'),
        )
        self.assertIn(
            "const model_conversion_durable_recovery_target_available =\n"
            "        target.result.os.tag == .macos or\n"
            "        target.result.os.tag == .linux or\n"
            "        target.result.os.tag == .freebsd;",
            source,
        )
        self.assertIn(
            "run_model_conversion_durable_recovery_campaign"
            ".addArtifactArg(\n"
            "            model_conversion_durable_recovery_worker_exe.?,\n"
            "        );",
            source,
        )
        self.assertIn(
            "test_step.dependOn(\n"
            "        model_conversion_durable_recovery_test_step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "if (model_conversion_durable_recovery_worker_exe) |worker|\n"
            "        test_compile_step.dependOn(&worker.step);",
            source,
        )
        self.assertIn(
            "if (model_conversion_durable_recovery_worker_exe) |worker|\n"
            "        profile_durable_compile_step.dependOn(&worker.step);",
            source,
        )
        self.assertIn(
            '"model-conversion-durable-recovery-test requires a native "',
            source,
        )
        self.assertIn(
            "test_compile_step.dependOn(profile_core_compile_step)",
            source,
        )
        self.assertIn(
            "test_compile_step.dependOn(profile_host_tool_compile_step)",
            source,
        )
        self.assertIn(
            "host_runtime_compile_step.dependOn(test_compile_step)",
            source,
        )
        self.assertIn(
            "host_runtime_compile_step.dependOn(contract_c_compile_step)",
            source,
        )
        self.assertNotIn(
            "profile_durable_compile_step.dependOn(profile_cpu_compile_step)",
            source,
        )
        self.assertNotIn(
            "profile_device_compile_step.dependOn(profile_cpu_compile_step)",
            source,
        )
        self.assertIn(
            "profile_device_compile_step.dependOn(\n"
            "        &native_metal_inflight_process_kill_ready_tests.step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "profile_device_compile_step.dependOn(\n"
            "        &native_supervisor_recovery_death_report_tests.step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "profile_device_compile_step.dependOn(\n"
            "        &metal_kernel_bench_exe.step,\n"
            "    );",
            source,
        )
        self.assertEqual(
            1,
            source.count("buildMetalLib(b, metal_output_dir)"),
        )
        frontier_start = source.index("for ([_]*std.Build.Step.Compile{")
        frontier_source = source[
            frontier_start : source.index(
                "const run_native_metal_inflight_process_kill_report",
                frontier_start,
            )
        ]
        for artifact in (
            "metal_tests",
            "native_metal_inflight_process_kill_ready_tests",
            "native_supervisor_recovery_death_report_tests",
            "native_supervisor_recovery_death_report_verifier",
            "native_supervisor_recovery_death_report_verifier_tests",
            "native_metal_observation_tests",
            "native_metal_observation_exe",
            "native_metal_allocation_tests",
            "native_workload_report_tests",
            "native_workload_campaign_tests",
            "native_metal_workload_report_exe",
            "native_metal_disruption_report_exe",
            "native_metal_cancellation_storm_report_exe",
            "native_metal_soak_worker_exe",
            "native_metal_inflight_process_kill_worker_exe",
            "native_metal_fault_tests",
        ):
            with self.subTest(native_metal_compile_artifact=artifact):
                self.assertIn(artifact, frontier_source)
        self.assertIn(
            "}) |artifact| {\n"
            "            native_metal_suite_compile_step.dependOn(\n"
            "                &artifact.step,\n"
            "            );\n"
            "        }",
            frontier_source,
        )
        self.assertIn(
            "check_metal_fault_symbols.expectExitCode(0)",
            source,
        )
        self.assertIn(
            "run_native_metal_observation_verifier_suite.step.dependOn(\n"
            "            native_metal_suite_compile_step,\n"
            "        );",
            source,
        )
        self.assertIn(
            "native_supervisor_recovery_death_host_test_step.dependOn(\n"
            "        &run_native_supervisor_recovery_death_protocol_model.step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "native_supervisor_recovery_death_report_test_step.dependOn(\n"
            "        "
            "&run_python_to_zig_supervisor_recovery_death_interop.step,\n"
            "    );",
            source,
        )
        self.assertIn(
            "native_metal_supervisor_recovery_death_report_test_step"
            ".dependOn(\n"
            "            "
            "&run_native_metal_supervisor_recovery_death_report.step,\n"
            "        );",
            source,
        )
        self.assertIn(
            "run_native_metal_fault_suite.step.dependOn(\n"
            "            "
            "&run_native_metal_supervisor_recovery_death_report_suite.step,\n"
            "        );",
            source,
        )
        metal_lib_start = source.index("fn buildMetalLib(")
        metal_lib_source = source[
            metal_lib_start : source.index(
                "/// Compile src/backends/metal/shim.m",
                metal_lib_start,
            )
        ]
        self.assertEqual(
            4,
            metal_lib_source.count("addOutputFileArg("),
        )
        self.assertIn(
            "compile_dequant.addFileArg(",
            metal_lib_source,
        )
        self.assertIn(
            "compile_matmul.addFileArg(",
            metal_lib_source,
        )
        self.assertIn(
            "compile_metallib.addFileArg(dequant_air)",
            metal_lib_source,
        )
        self.assertIn(
            "compile_metallib.addFileArg(matmul_air)",
            metal_lib_source,
        )
        self.assertIn(
            "const module_cache_dir = b.cache_root.join(",
            metal_lib_source,
        )
        self.assertEqual(
            2,
            metal_lib_source.count("-fmodules-cache-path={s}"),
        )
        self.assertIn(
            'b.path("tools/metal-toolchain-identity.sh")',
            metal_lib_source,
        )
        self.assertIn(
            "capture_toolchain_identity.has_side_effects = true",
            metal_lib_source,
        )
        self.assertEqual(
            3,
            metal_lib_source.count("addFileInput(toolchain_identity)"),
        )
        self.assertIn(
            "run_native_metal_correctness_tests.step.dependOn(\n"
            "            &run_native_metal_observation_verifier.step,\n"
            "        );",
            source,
        )
        complete_profile_start = source.index("const profile_complete_compile_step")
        complete_profile_source = source[
            complete_profile_start : source.index(
                "const run_cmd",
                complete_profile_start,
            )
        ]
        self.assertIn(
            "profile_complete_compile_step.dependOn(test_compile_step)",
            complete_profile_source,
        )
        for artifact in (
            "bench_exe",
            "lane4_bench_exe",
            "paged_lane4_bench_exe",
            "paged_resident_bench_exe",
            "paged_lease_bench_exe",
            "paged_lease_admission_bench_exe",
            "int4_kernel_bench_exe",
            "eligible_argmax_bench_exe",
            "progressive_kernel_bench_exe",
            "metal_kernel_bench_exe",
            "quant_bench_exe",
        ):
            with self.subTest(complete_consumer=artifact):
                self.assertIn(
                    "&" + artifact + ".step",
                    complete_profile_source,
                )

    def test_ci_keeps_fast_default_and_explicit_exhaustive_frontiers(self):
        source = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("use-cache: false", source)
        self.assertEqual(3, source.count("          use-cache: true"))
        self.assertEqual(
            1,
            source.count("          cache-size-limit: 1024"),
        )
        self.assertEqual(
            2,
            source.count("          cache-size-limit: 2048"),
        )
        self.assertEqual(
            2,
            source.count('          GLACIER_VERIFY_REUSE_ZIG_CACHE: "1"'),
        )
        self.assertIn("          cache-key: affected", source)
        self.assertIn("          cache-key: exhaustive", source)
        self.assertIn("        default: affected-fast", source)
        self.assertIn("          - affected-fast", source)
        self.assertIn("        default: origin/main", source)
        self.assertIn(
            "github.event_name == 'workflow_dispatch' &&\n"
            "          inputs.profile == 'affected-fast'",
            source,
        )
        self.assertIn(
            "github.event_name == 'workflow_dispatch' &&\n"
            "          inputs.profile != 'affected-fast'",
            source,
        )
        self.assertIn(
            "MANUAL_BASE_REF: ${{ inputs.base_ref }}",
            source,
        )
        self.assertIn(
            "tools/verify.sh affected-fast\n"
            '          --base "${{ steps.affected-base.outputs.base }}"',
            source,
        )
        self.assertIn('run: tools/verify.sh "$VERIFY_PROFILE"', source)
        self.assertIn('      - "v*"', source)
        self.assertNotIn("  schedule:", source)
        self.assertEqual(
            3,
            source.count("      cancel-in-progress: true"),
        )
        self.assertIn(
            "ci-exhaustive-${{ inputs.profile || 'matrix' }}-${{ github.ref }}",
            source,
        )
        self.assertIn(
            "group: ci-macos-frontier-${{ github.ref }}",
            source,
        )
        metal_compile_at = source.index("zig build native-metal-suite-compile")
        model_recovery_at = source.index(
            "zig build model-conversion-durable-recovery-test"
        )
        self.assertLess(metal_compile_at, model_recovery_at)
        self.assertIn(
            "zig build model-conversion-durable-recovery-test\n"
            "          -Dmetal=false\n"
            "          -Doptimize=ReleaseSafe\n"
            "          -j2",
            source,
        )
        metal_prune_at = source.index(
            "python3 tools/verification_policy.py prune-zig-cache",
            model_recovery_at,
        )
        self.assertLess(model_recovery_at, metal_prune_at)
        self.assertIn(
            "      - name: Prune reusable Zig cache\n"
            "        if: always()\n"
            "        run: >-\n"
            "          python3 tools/verification_policy.py prune-zig-cache\n"
            '          --repository-root "$GITHUB_WORKSPACE"\n'
            '          --cache-root "$GITHUB_WORKSPACE/.zig-cache"\n'
            "          --limit-mib 1800",
            source,
        )

    def test_paths_are_deduplicated_and_byte_sorted(self):
        plan = policy.classify_paths(["docs/z.md", "docs/a\nname.md", "docs/z.md"])
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
        plan = policy.classify_paths(["src/platform/windows/dispatch.zig"])
        with tempfile.TemporaryDirectory() as temporary_directory:
            flags = Path(temporary_directory) / "flags"
            targets = Path(temporary_directory) / "targets"
            target_steps = Path(temporary_directory) / "target-steps"
            policy.write_flags(plan, flags)
            policy.write_targets(plan.targets, targets)
            policy.write_target_steps(plan.target_plans, target_steps)
            serialized_flags = flags.read_text(encoding="utf-8")
            self.assertNotIn("target:", serialized_flags)
            self.assertIn("host-contract\n", serialized_flags)
            self.assertIn("host-package\n", serialized_flags)
            self.assertEqual(
                targets.read_text(encoding="ascii").splitlines(),
                list(policy.WINDOWS_TARGETS),
            )
            self.assertEqual(
                target_steps.read_text(encoding="ascii").splitlines(),
                [
                    policy.WINDOWS_TARGETS[0] + " install",
                    policy.WINDOWS_TARGETS[0] + " install-benchmarks",
                    policy.WINDOWS_TARGETS[0] + " test-compile",
                ],
            )
            focused_plan = (
                policy.TargetBuildPlan(
                    policy.RETAINED_TARGETS[0],
                    (
                        "profile-core-compile",
                        "profile-cpu-compile",
                        "text-runtime-golden-path-compile",
                    ),
                ),
            )
            policy.write_target_steps(focused_plan, target_steps)
            self.assertEqual(
                [
                    policy.RETAINED_TARGETS[0] + " profile-core-compile",
                    policy.RETAINED_TARGETS[0] + " profile-cpu-compile",
                    policy.RETAINED_TARGETS[0]
                    + " text-runtime-golden-path-compile",
                ],
                target_steps.read_text(encoding="ascii").splitlines(),
            )
            complete_plan = (
                policy.TargetBuildPlan(
                    policy.RETAINED_TARGETS[0],
                    policy.COMPLETE_COMPILE_TARGET_STEPS,
                ),
            )
            policy.write_target_steps(complete_plan, target_steps)
            self.assertEqual(
                [policy.RETAINED_TARGETS[0] + " profile-complete-compile"],
                target_steps.read_text(encoding="ascii").splitlines(),
            )
            main_runtime_plan = (
                policy.TargetBuildPlan(
                    policy.RETAINED_TARGETS[0],
                    policy.MAIN_RUNTIME_TARGET_STEPS,
                ),
            )
            policy.write_target_steps(main_runtime_plan, target_steps)
            self.assertEqual(
                [
                    policy.RETAINED_TARGETS[0] + " install",
                    policy.RETAINED_TARGETS[0] + " test-compile",
                ],
                target_steps.read_text(encoding="ascii").splitlines(),
            )
            with self.assertRaises(ValueError):
                policy.write_targets(
                    tuple(reversed(policy.RETAINED_TARGETS)),
                    targets,
                )
            with self.assertRaises(ValueError):
                policy.write_targets(("unknown-target",), targets)
            invalid_target_plans = (
                (
                    policy.TargetBuildPlan(
                        "unknown-target",
                        ("profile-core-compile",),
                    ),
                ),
                (
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        (),
                    ),
                ),
                (
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        ("unknown-step",),
                    ),
                ),
                (
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        (
                            "install",
                            "install-benchmarks",
                            "profile-core-compile",
                            "test-compile",
                        ),
                    ),
                ),
                (
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        (
                            "profile-core-compile",
                            "profile-complete-compile",
                        ),
                    ),
                ),
                (
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        (
                            "profile-cpu-compile",
                            "profile-core-compile",
                        ),
                    ),
                ),
                (
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        ("profile-core-compile",),
                    ),
                    policy.TargetBuildPlan(
                        policy.RETAINED_TARGETS[0],
                        ("profile-cpu-compile",),
                    ),
                ),
            )
            for invalid_plan in invalid_target_plans:
                with self.subTest(invalid_plan=invalid_plan):
                    with self.assertRaises(ValueError):
                        policy.write_target_steps(
                            invalid_plan,
                            target_steps,
                        )

    def test_host_root_plan_is_closed_unique_and_canonical(self):
        valid = policy.PathDecision(
            path="src/runtime.zig",
            reason="test fixture",
            flags=frozenset(),
            targets=(),
            host_roots=policy.HOST_QUICK_ROOTS,
        )
        self.assertEqual(
            policy.HOST_QUICK_ROOTS,
            policy._validated_host_roots(valid),
        )
        for invalid_roots in (
            ("unknown-host-root",),
            (
                policy.HOST_PACKAGE_ROOTS[0],
                policy.HOST_CONTRACT_ROOTS[0],
            ),
            (
                policy.HOST_CONTRACT_ROOTS[0],
                policy.HOST_CONTRACT_ROOTS[0],
            ),
        ):
            with self.subTest(invalid_roots=invalid_roots):
                invalid = policy.PathDecision(
                    path="src/runtime.zig",
                    reason="test fixture",
                    flags=frozenset(),
                    targets=(),
                    host_roots=invalid_roots,
                )
                with self.assertRaises(ValueError):
                    policy._validated_host_roots(invalid)

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
            valid.write_bytes(b"# -*- coding: latin-1 -*-\nlabel = 'caf\\xe9'\n")
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
                policy.check_changed_shell((str(sh_script), str(bash_script)))
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
            oversized.write_bytes(b"#!" + b"x" * policy.MAXIMUM_SHEBANG_BYTES + b"\n")
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
            stdout=(subprocess.PIPE if capture else subprocess.DEVNULL),
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

            (repository / "unstaged.txt").write_text("unstaged\n", encoding="ascii")
            (repository / "untracked.txt").write_text("untracked\n", encoding="ascii")

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
        (repository / "bench" / "__init__.py").write_text("", encoding="ascii")
        (repository / "bench" / "tests" / "__init__.py").write_text(
            "", encoding="ascii"
        )
        (repository / "bench" / "tests" / "test_public_markdown_policy.py").write_text(
            "import unittest\n"
            "class PublicMarkdownPolicyTests(unittest.TestCase):\n"
            "    def test_fixture(self):\n"
            "        self.assertTrue(True)\n",
            encoding="ascii",
        )
        (repository / "bench" / "tests" / "test_local_verify.py").write_text(
            "import unittest\n"
            "class LocalVerifyTests(unittest.TestCase):\n"
            "    def test_fixture(self):\n"
            "        self.assertTrue(True)\n",
            encoding="ascii",
        )
        (
            repository / "bench" / "tests" / "test_verification_policy.py"
        ).write_text(
            "import unittest\n"
            "class VerificationPolicyTests(unittest.TestCase):\n"
            "    def test_fixture(self):\n"
            "        self.assertTrue(True)\n",
            encoding="ascii",
        )
        (
            repository / "bench" / "tests" / "test_native_unary_server_load.py"
        ).write_text(
            "import unittest\n"
            "class NativeUnaryServerLoadTests(unittest.TestCase):\n"
            "    def test_fixture(self):\n"
            "        self.assertTrue(True)\n",
            encoding="ascii",
        )
        (
            repository
            / "bench"
            / "tests"
            / "test_native_unary_server_load_publication.py"
        ).write_text(
            "import unittest\n"
            "class NativeUnaryServerLoadPublicationTests(unittest.TestCase):\n"
            "    def test_fixture(self):\n"
            "        self.assertTrue(True)\n",
            encoding="ascii",
        )
        (
            repository / "bench" / "native_unary_server_load_publication.py"
        ).write_text("", encoding="ascii")
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
            ': "${VERIFY_INTEGRATION_ZIG_LOG:?}"\n'
            'printf "%s\\n" "$*" >>"$VERIFY_INTEGRATION_ZIG_LOG"\n'
            'if [ "${1:-}" = "version" ]; then\n'
            "    printf '0.15.2\\n'\n"
            "fi\n"
            'if [ -n "${VERIFY_INTEGRATION_FAIL_TARGET:-}" ]; then\n'
            '    case "$*" in\n'
            '        *"-Dtarget=$VERIFY_INTEGRATION_FAIL_TARGET "*)\n'
            "            exit 19\n"
            "            ;;\n"
            "    esac\n"
            "fi\n"
            'if [ -n "${VERIFY_INTEGRATION_FAIL_NATIVE_TEST:-}" ] '
            '&& [ "${1:-}" = "build" ] '
            '&& [ "${2:-}" = "test" ]; then\n'
            "    exit 23\n"
            "fi\n"
            'if [ -n "${VERIFY_INTEGRATION_FAIL_HOST_ROOT:-}" ] '
            '&& [ "${1:-}" = "build" ]; then\n'
            '    case " $* " in\n'
            '        *" $VERIFY_INTEGRATION_FAIL_HOST_ROOT "*)\n'
            "            exit 37\n"
            "            ;;\n"
            "    esac\n"
            "fi\n"
            'if [ -n "${VERIFY_INTEGRATION_FAIL_HOST_COMPILE:-}" ] '
            '&& [ "${1:-}" = "build" ] '
            '&& [ "${2:-}" = "host-runtime-compile" ]; then\n'
            "    exit 29\n"
            "fi\n"
            'if [ -n "${VERIFY_INTEGRATION_FAIL_BUILD_GRAPH:-}" ] '
            '&& [ "${1:-}" = "build" ] '
            '&& [ "${2:-}" = "--help" ]; then\n'
            "    exit 41\n"
            "fi\n"
            'if [ -n "${VERIFY_INTEGRATION_FAIL_METAL_COMPILE:-}" ] '
            '&& [ "${1:-}" = "build" ] '
            '&& [ "${2:-}" = "native-metal-suite-compile" ]; then\n'
            "    exit 31\n"
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
        environment["VERIFY_INTEGRATION_ZIG_LOG"] = str(root / "zig.calls")
        environment.pop("GLACIER_VERIFY_BASE", None)
        environment.pop("GLACIER_VERIFY_REQUIRE_NATIVE", None)
        environment.pop("GLACIER_VERIFY_REUSE_ZIG_CACHE", None)
        environment.pop("ZIG_LOCAL_CACHE_DIR", None)
        environment.pop("ZIG_GLOBAL_CACHE_DIR", None)
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

    def run_affected_fast(self, repository, merge_base, environment):
        return subprocess.run(
            (
                str(repository / "tools" / "verify.sh"),
                "affected-fast",
                "--base",
                merge_base,
            ),
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def run_matrix(self, repository, environment):
        return subprocess.run(
            (
                str(repository / "tools" / "verify.sh"),
                "matrix",
            ),
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def run_full(self, repository, environment):
        return subprocess.run(
            (
                str(repository / "tools" / "verify.sh"),
                "full",
            ),
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_native_metal_gate_separates_compile_and_hardware_phases(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'Darwin\\n'\n",
            )
            metal_benchmark = repository / "bench" / "metal_kernel.zig"
            metal_benchmark.write_text("", encoding="ascii")

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn("PASS  native/metal:", result.stdout)
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            compile_calls = [
                line
                for line in calls
                if line.startswith("build native-metal-suite-compile ")
            ]
            native_calls = [
                line
                for line in calls
                if line.startswith("build native-metal-suite-test ")
            ]
            self.assertEqual(1, len(compile_calls), compile_calls)
            self.assertEqual(1, len(native_calls), native_calls)
            self.assertLess(
                calls.index(compile_calls[0]),
                calls.index(native_calls[0]),
            )
            for call in (*compile_calls, *native_calls):
                self.assertIn("-Dmetal-output-dir=", call)
                self.assertIn(" --cache-dir ", call)
                self.assertIn(" --global-cache-dir ", call)
                self.assertIn(" --prefix ", call)
            compile_tokens = compile_calls[0].split()
            native_tokens = native_calls[0].split()
            for option in (
                "--cache-dir",
                "--global-cache-dir",
                "--prefix",
            ):
                with self.subTest(shared_metal_option=option):
                    self.assertEqual(
                        compile_tokens[compile_tokens.index(option) + 1],
                        native_tokens[native_tokens.index(option) + 1],
                    )
            self.assertEqual(
                next(
                    token
                    for token in compile_tokens
                    if token.startswith("-Dmetal-output-dir=")
                ),
                next(
                    token
                    for token in native_tokens
                    if token.startswith("-Dmetal-output-dir=")
                ),
            )
            self.assertIn(" -j2 ", compile_calls[0])
            self.assertIn(" -j1 ", native_calls[0])
            self.assertNotIn(
                "native-metal-suite-compile",
                native_calls[0],
            )

    def test_native_metal_compile_failure_suppresses_hardware_phase(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'Darwin\\n'\n",
            )
            metal_benchmark = repository / "bench" / "metal_kernel.zig"
            metal_benchmark.write_text("", encoding="ascii")
            environment["VERIFY_INTEGRATION_FAIL_METAL_COMPILE"] = "1"

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "FAIL  native/metal: exit 31",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith("build native-metal-suite-compile ")
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(
                any(
                    line.startswith("build native-metal-suite-test ") for line in calls
                ),
                calls,
            )

    def test_workload_report_uses_one_portable_non_metal_build_graph(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            report_path = repository / "src" / "core" / "native_workload_report.zig"
            report_path.parent.mkdir(parents=True)
            report_path.write_text("", encoding="ascii")

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  portable/workload-report:",
                result.stdout,
            )
            self.assertNotIn("PASS  native/metal:", result.stdout)
            self.assertNotIn(
                "PASS  native/releasesafe-suite:",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [
                line
                for line in calls
                if line.startswith("build ")
            ]
            self.assertEqual(1, len(build_calls), build_calls)
            report_tokens = build_calls[0].split()
            first_option = next(
                index
                for index, token in enumerate(report_tokens[1:], 1)
                if token.startswith("-")
            )
            self.assertEqual(
                (
                    "native-workload-report-test",
                    "native-workload-report-compile",
                    "native-workload-report-cross-compile",
                    "native-workload-campaign-test",
                    "native-workload-campaign-compile",
                    "native-workload-campaign-cross-compile",
                    "native-workload-store-fault-report-test",
                    "native-workload-store-fault-report-compile",
                    "native-workload-store-fault-report-cross-compile",
                    "native-supervisor-recovery-death-report-test",
                    "native-supervisor-recovery-death-report-compile",
                    "native-supervisor-recovery-death-report-cross-compile",
                ),
                tuple(report_tokens[1:first_option]),
            )
            self.assertIn("-Dmetal=false ", build_calls[0])
            self.assertNotIn(
                "native-workload-store-fault-pure-test",
                build_calls[0],
            )
            self.assertNotIn(
                " native-workload-store-fault-test ",
                build_calls[0],
            )
            self.assertFalse(
                any("native-metal-suite-test" in line for line in calls),
                calls,
            )
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_workload_report_uses_host_tests_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            report_path = (
                repository
                / "src"
                / "core"
                / "native_workload_report.zig"
            )
            report_path.parent.mkdir(parents=True)
            report_path.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  portable/workload-report:",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [
                line
                for line in calls
                if line.startswith("build ")
            ]
            self.assertEqual(1, len(build_calls), build_calls)
            report_tokens = build_calls[0].split()
            first_option = next(
                index
                for index, token in enumerate(report_tokens[1:], 1)
                if token.startswith("-")
            )
            self.assertEqual(
                (
                    "native-workload-report-test",
                    "native-workload-campaign-test",
                    "native-workload-store-fault-report-test",
                    "native-supervisor-recovery-death-report-test",
                ),
                tuple(report_tokens[1:first_option]),
            )
            self.assertFalse(
                any(
                    token.endswith("-compile")
                    for line in build_calls
                    for token in line.split()
                ),
                build_calls,
            )
            self.assertFalse(
                any(
                    token.endswith("-cross-compile")
                    for line in build_calls
                    for token in line.split()
                ),
                build_calls,
            )
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_defers_broad_suites_and_cross_targets(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "src" / "runtime.zig").write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: affected-fast defers the broad suite",
                result.stdout,
            )
            self.assertIn(
                "SKIP  python/full-suite: affected-fast defers full discovery",
                result.stdout,
            )
            self.assertIn(
                "SKIP  portability/cross-target: affected-fast defers retained targets",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith("build contract-interop-test package-module-test ")
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(
                any(
                    line.startswith("build host-runtime-compile ")
                    or line.startswith("build test contract-interop-test ")
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_does_not_expand_darwin_flag_to_full_suite(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'Darwin\\n'\n",
            )
            posix = repository / "src" / "platform" / "posix"
            posix.mkdir(parents=True)
            (posix / "files.zig").write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "SKIP  native/darwin: affected-fast has no focused Darwin root",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(
                    line.startswith("build test ")
                    or line.startswith("build host-runtime-compile ")
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_evaluates_build_graph_without_runtime_compile(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'Darwin\\n'\n",
            )
            (repository / "build.zig").write_text(
                "// changed build graph\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "SKIP  native/metal: affected-fast defers native Metal",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any("native-metal-suite" in line for line in calls),
                calls,
            )
            graph_calls = [
                line for line in calls if line.startswith("build --help ")
            ]
            self.assertEqual(1, len(graph_calls), calls)
            self.assertIn("-Dmetal=false ", graph_calls[0])
            self.assertIn("-Doptimize=Debug ", graph_calls[0])
            self.assertFalse(
                any(
                    line.startswith(
                        "build contract-interop-test package-module-test "
                    )
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_build_graph_failure_is_final(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "build.zig").write_text(
                "// invalid changed build graph\n",
                encoding="ascii",
            )
            environment["VERIFY_INTEGRATION_FAIL_BUILD_GRAPH"] = "1"

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "FAIL  build/graph-evaluation: exit 41",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(line.startswith("build --help ") for line in calls),
                calls,
            )

    def test_affected_build_graph_failure_stops_before_promotion_compile(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "build.zig").write_text(
                "// invalid changed build graph\n",
                encoding="ascii",
            )
            environment["VERIFY_INTEGRATION_FAIL_BUILD_GRAPH"] = "1"

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "FAIL  build/graph-evaluation: exit 41",
                result.stdout,
            )
            self.assertIn(
                "stopping before promotion work: "
                "Zig build graph evaluation failed",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [
                line for line in calls if line.startswith("build ")
            ]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(build_calls[0].startswith("build --help "), calls)
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )
            self.assertFalse(
                any("native-metal-suite" in line for line in calls),
                calls,
            )

    def test_affected_fast_documentation_only_avoids_host_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            docs = repository / "docs"
            docs.mkdir()
            (docs / "example.zig").write_text(
                "// Documentation fixture\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: affected plan selected no "
                "generic host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "SKIP  package/modules: affected plan selected no generic "
                "host Zig DAG",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertTrue(
                any(line.startswith("fmt --check ") for line in calls),
                calls,
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_fast_without_python_stops_before_host_builds(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            fixtures = repository / "examples" / "interop" / "fixtures"
            fixtures.mkdir(parents=True)
            (fixtures / "artifact_manifest_v1.hex").write_text(
                "00\n",
                encoding="ascii",
            )
            self.make_fake_command(
                root / "fake-bin" / "python3",
                "exit 41\n",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "FAIL  toolchain/python: python3 --version failed",
                result.stdout,
            )
            self.assertIn(
                "FAIL  policy/affected-selection: requires a working "
                "python3 executable",
                result.stdout,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: affected plan selected no "
                "generic host Zig DAG",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_fast_darwin_only_avoids_unrelated_host_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            darwin = repository / "src" / "platform" / "darwin"
            darwin.mkdir(parents=True)
            (darwin / "files.zig").write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_fast_interop_fixture_replays_generic_host_dag(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            fixtures = repository / "examples" / "interop" / "fixtures"
            fixtures.mkdir(parents=True)
            (fixtures / "artifact_manifest_v1.hex").write_text(
                "00\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith(
                        "build contract-interop-test "
                    )
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(
                any("package-module-test" in line for line in calls),
                calls,
            )
            self.assertIn(
                "SKIP  package/modules: affected plan did not select "
                "package modules",
                result.stdout,
            )

    def test_affected_fast_python_contract_consumer_runs_only_contract_root(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            interop = repository / "examples" / "interop"
            interop.mkdir(parents=True)
            (interop / "python_verify.py").write_text(
                "PROFILE_COUNT = 11\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn("PASS  python/changed-syntax:", result.stdout)
            self.assertIn(
                "PASS  interop/c-cpp-python: covered by the shared host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "SKIP  python/full-suite: affected-fast defers",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith("build contract-interop-test "),
                build_calls,
            )
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_package_module_runs_only_package_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            tests = repository / "tests"
            (tests / "package_module.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [
                line for line in calls if line.startswith("build ")
            ]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build package-module-test "
                ),
                build_calls,
            )
            self.assertNotIn("contract-interop-test", build_calls[0])
            self.assertIn(
                "SKIP  interop/c-cpp-python: affected plan did not select "
                "contract interop",
                result.stdout,
            )

    def test_affected_fast_contract_failure_does_not_blame_package_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            fixtures = repository / "examples" / "interop" / "fixtures"
            fixtures.mkdir(parents=True)
            (fixtures / "artifact_manifest_v1.hex").write_text(
                "00\n",
                encoding="ascii",
            )
            environment["VERIFY_INTEGRATION_FAIL_HOST_ROOT"] = (
                policy.HOST_CONTRACT_ROOTS[0]
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("FAIL  host/quick-dag: exit 37", result.stdout)
            self.assertIn(
                "SKIP  interop/c-cpp-python: shared host Zig DAG failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  package/modules: affected plan did not select "
                "package modules",
                result.stdout,
            )
            self.assertNotIn(
                "SKIP  package/modules: shared host Zig DAG failed",
                result.stdout,
            )

    def test_affected_fast_package_failure_does_not_blame_contract_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "tests" / "package_module.zig").write_text(
                "",
                encoding="ascii",
            )
            environment["VERIFY_INTEGRATION_FAIL_HOST_ROOT"] = (
                policy.HOST_PACKAGE_ROOTS[0]
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("FAIL  host/quick-dag: exit 37", result.stdout)
            self.assertIn(
                "SKIP  package/modules: shared host Zig DAG failed",
                result.stdout,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: affected plan did not select "
                "contract interop",
                result.stdout,
            )
            self.assertNotIn(
                "SKIP  interop/c-cpp-python: shared host Zig DAG failed",
                result.stdout,
            )

    def test_affected_fast_contract_and_package_share_canonical_union(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            fixtures = repository / "examples" / "interop" / "fixtures"
            fixtures.mkdir(parents=True)
            (fixtures / "artifact_manifest_v1.hex").write_text(
                "00\n",
                encoding="ascii",
            )
            (repository / "tests" / "package_module.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            host_build_calls = [
                line
                for line in calls
                if line.startswith("build contract-interop-test ")
            ]
            self.assertEqual(1, len(host_build_calls), calls)
            self.assertTrue(
                host_build_calls[0].startswith(
                    "build contract-interop-test package-module-test "
                ),
                host_build_calls,
            )
            self.assertEqual(
                1,
                host_build_calls[0].count("contract-interop-test"),
            )
            self.assertEqual(
                1,
                host_build_calls[0].count("package-module-test"),
            )

    def test_affected_fast_conservative_input_keeps_generic_host_dag(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "src" / "runtime.codegen").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith(
                        "build contract-interop-test package-module-test "
                    )
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_runs_verification_policy_suite_once(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            policy_test = repository / "bench" / "tests" / "test_verification_policy.py"
            policy_test.write_text(
                "import unittest\n"
                "class VerificationPolicyTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertEqual(1, 1)\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertEqual(
                1,
                result.stdout.count("PASS  python/verification-policy:"),
                result.stdout,
            )
            self.assertIn(
                "SKIP  python/full-suite: affected-fast defers full discovery",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(
                    line.startswith("build ") or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_github_control_runs_policy_without_zig_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            workflows = repository / ".github" / "workflows"
            workflows.mkdir(parents=True)
            (workflows / "ci.yml").write_text("name: CI\n", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn("PASS  python/verification-policy:", result.stdout)
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_fast_python_only_avoids_generic_zig_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "bench" / "standalone_verifier.py").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn("PASS  python/changed-syntax:", result.stdout)
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_fast_runs_provider_evidence_focused_root_once(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "provider_evidence_inspector.zig").write_text(
                "",
                encoding="ascii",
            )
            (repository / "bench" / "provider_evidence_inspector.py").write_text(
                "",
                encoding="ascii",
            )
            (
                repository
                / "bench"
                / "tests"
                / "test_provider_evidence_inspector.py"
            ).write_text(
                "import unittest\n"
                "class ProviderEvidenceInspectorTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertTrue(True)\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  host/provider-evidence-focused-dag:",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/provider-evidence-inspector: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "SKIP  interop/c-cpp-python: provider-evidence focused DAG "
                "does not select generic interop",
                result.stdout,
            )
            self.assertIn(
                "SKIP  package/modules: provider-evidence focused DAG does "
                "not select generic package modules",
                result.stdout,
            )
            self.assertIn("PASS  python/changed-syntax:", result.stdout)
            self.assertIn(
                "PASS  python/provider-evidence-inspector:",
                result.stdout,
            )
            self.assertIn(
                "SKIP  python/full-suite: affected-fast defers full discovery",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build provider-evidence-inspector-test "
                ),
                build_calls,
            )
            self.assertEqual(
                1,
                build_calls[0].count("provider-evidence-inspector-test"),
            )
            self.assertNotIn("contract-interop-test", build_calls[0])
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_runs_provider_evidence_python_test_file(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            test_path = (
                repository
                / "bench"
                / "tests"
                / "test_provider_evidence_inspector.py"
            )
            test_path.write_text(
                "import unittest\n"
                "class ProviderEvidenceInspectorTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertTrue(True)\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  python/provider-evidence-inspector:",
                result.stdout,
            )
            self.assertIn("PASS  python/changed-syntax:", result.stdout)
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_provider_cli_cross_compiles_only_inspector(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "provider_evidence_inspector.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            target_calls = [
                line for line in calls if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            for call in target_calls:
                self.assertTrue(
                    call.startswith(
                        "build provider-evidence-inspector-compile "
                    ),
                    target_calls,
                )
                self.assertNotIn("profile-host-tool-compile", call)

    def test_affected_fast_runs_classifier_and_registry_roots_once(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            core = repository / "src" / "core"
            core.mkdir()
            (core / "dense_tensor_classifier.zig").write_text(
                "",
                encoding="ascii",
            )
            (core / "runtime_support_registry.zig").write_text(
                "",
                encoding="ascii",
            )
            (repository / "examples" / "dense_tensor_reranker.zig").write_text(
                "",
                encoding="ascii",
            )
            (repository / "bench" / "runtime_support_registry.py").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  host/dense-tensor-focused-dag:",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/dense-tensor-family:",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/runtime-support-inspector:",
                result.stdout,
            )
            self.assertIn(
                "PASS  interop/c-cpp-python: covered by the shared host Zig DAG",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build contract-interop-test "
                    "dense-tensor-family-test "
                    "runtime-support-inspector-test "
                ),
                build_calls,
            )
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_retrieval_reuses_family_and_registry_roots_once(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            core = repository / "src" / "core"
            core.mkdir()
            (core / "dense_tensor_retrieval.zig").write_text(
                "",
                encoding="ascii",
            )
            (core / "stateless_retrieval_result.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  host/dense-tensor-focused-dag:",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/dense-tensor-family:",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/runtime-support-inspector:",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build dense-tensor-family-test "
                    "runtime-support-inspector-test "
                ),
                build_calls,
            )
            self.assertNotIn("contract-interop-test", build_calls[0])
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_affected_fast_runs_exact_tensor_python_test_modules(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            tensor_test = (
                repository
                / "bench"
                / "tests"
                / "test_stateless_tensor_result.py"
            )
            tensor_test.write_text(
                "import unittest\n"
                "class TensorTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertTrue(True)\n",
                encoding="ascii",
            )
            registry_test = (
                repository
                / "bench"
                / "tests"
                / "test_runtime_support_inspector.py"
            )
            registry_test.write_text(
                "import unittest\n"
                "class RegistryTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertTrue(True)\n",
                encoding="ascii",
            )
            retrieval_test = (
                repository
                / "bench"
                / "tests"
                / "test_stateless_retrieval_result.py"
            )
            retrieval_test.write_text(
                "import unittest\n"
                "class RetrievalTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertTrue(True)\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  python/dense-tensor-family:",
                result.stdout,
            )
            self.assertIn(
                "PASS  python/runtime-support-inspector:",
                result.stdout,
            )
            self.assertIn(
                "PASS  python/dense-tensor-retrieval:",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_fast_shared_tensor_result_runs_family_root_once(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            core = repository / "src" / "core"
            core.mkdir()
            (core / "stateless_tensor_result.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/dense-tensor-family:",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: affected-fast defers",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build dense-tensor-family-test "
                ),
                build_calls,
            )
            self.assertNotIn("contract-interop-test", build_calls[0])
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertNotIn("runtime-support-inspector-test", build_calls[0])

    def test_affected_fast_dense_tensor_roots_run_on_freebsd(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'FreeBSD\\n'\n",
            )
            core = repository / "src" / "core"
            core.mkdir()
            (core / "stateless_tensor_result.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/dense-tensor-family:",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build dense-tensor-family-test "
                ),
                build_calls,
            )

    def test_affected_classifier_cross_compiles_only_related_roots(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            core = repository / "src" / "core"
            core.mkdir()
            (core / "dense_tensor_classifier.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            target_calls = [
                line for line in calls if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            for call in target_calls:
                self.assertTrue(
                    call.startswith(
                        "build dense-tensor-family-compile "
                        "runtime-support-inspector-compile "
                    ),
                    target_calls,
                )
                self.assertNotIn("profile-host-tool-compile", call)
                self.assertNotIn("profile-core-compile", call)
    def test_affected_profiles_run_native_unary_load_python_only(self):
        for profile in ("affected", "affected-fast"):
            with self.subTest(profile=profile):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    repository, merge_base, environment = self.make_repository(root)
                    (
                        repository
                        / "bench"
                        / "native_unary_server_load_publication.py"
                    ).write_text(
                        'raise SystemExit("native campaign must remain opt-in")\n',
                        encoding="ascii",
                    )

                    if profile == "affected":
                        result = self.run_verify(
                            repository,
                            merge_base,
                            environment,
                        )
                    else:
                        result = self.run_affected_fast(
                            repository,
                            merge_base,
                            environment,
                        )

                    self.assertEqual(
                        0,
                        result.returncode,
                        result.stdout + result.stderr,
                    )
                    self.assertIn(
                        "PASS  python/changed-syntax:",
                        result.stdout,
                    )
                    self.assertEqual(
                        1,
                        result.stdout.count(
                            "PASS  python/native-unary-load:"
                        ),
                        result.stdout,
                    )
                    calls = (
                        Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                        .read_text(encoding="ascii")
                        .splitlines()
                    )
                    self.assertFalse(
                        any(line.startswith("build ") for line in calls),
                        calls,
                    )
                    self.assertNotIn(
                        "native/prepared-text-unary-server-process",
                        result.stdout,
                    )

    def test_affected_fast_runs_prepared_text_focused_dag_once(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "src" / "prepared_text_durable_runtime.zig").write_text(
                "",
                encoding="ascii",
            )
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "prepared_text_result_inspector.zig").write_text(
                "",
                encoding="ascii",
            )
            (repository / "bench" / "prepared_text_recovery_campaign.py").write_text(
                "", encoding="ascii"
            )
            (
                repository / "bench" / "prepared_text_direct_terminal_recovery.py"
            ).write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  host/prepared-text-focused-dag:",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-delivery: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-inspector: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-recovery: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-direct-terminal-smoke: "
                "covered by the focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "SKIP  package/modules: prepared-text focused DAG does not "
                "select generic package modules",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            focused_calls = [
                line
                for line in calls
                if line.startswith(
                    "build prepared-text-acknowledged-delivery-test "
                    "prepared-text-recovery-test "
                    "prepared-text-result-inspector-test "
                )
            ]
            self.assertEqual(1, len(focused_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(focused_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "prepared-text-direct-terminal-recovery-smoke-test" in line
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(
                any(
                    line.startswith("build host-runtime-compile ")
                    or line.startswith("build test contract-interop-test ")
                    or "package-module-test" in line
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_unary_service_test_uses_one_focused_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            test_root = repository / "tests" / "unary_text_service.zig"
            test_root.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-service: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-unary-http",
                result.stdout,
            )
            self.assertNotIn(
                "native/releasesafe-suite: covered",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            focused_calls = [
                line
                for line in calls
                if line.startswith("build unary-text-service-test ")
            ]
            self.assertEqual(1, len(focused_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(focused_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "model_forward" in line
                    or "text-runtime-golden-path-test" in line
                    or "package-module-test" in line
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_unary_service_implementation_shares_http_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            service = repository / "src" / "prepared_text_unary_service.zig"
            service.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-service: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-http: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-server-process: covered by "
                "the focused host Zig DAG",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertIn("-Doptimize=Debug", build_calls[0])
            self.assertTrue(
                build_calls[0].startswith(
                    "build unary-text-service-test unary-http-test "
                    "unary-server-process-test "
                ),
                build_calls,
            )
            self.assertFalse(
                any(
                    "model_forward" in line
                    or "text-runtime-golden-path-test" in line
                    or "package-module-test" in line
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_unary_http_uses_one_focused_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            http = repository / "src" / "prepared_text_unary_http_v1.zig"
            http.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-http: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-unary-service",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            focused_calls = [
                line
                for line in calls
                if line.startswith("build unary-http-test ")
            ]
            self.assertEqual(1, len(focused_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(focused_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "unary-text-service-test" in line
                    or "model_forward" in line
                    or "text-runtime-golden-path-test" in line
                    or "package-module-test" in line
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_unary_server_process_uses_one_focused_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            process_test = (
                repository
                / "tests"
                / "prepared_text_unary_server_process.zig"
            )
            process_test.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-server-process: covered by "
                "the focused host Zig DAG",
                result.stdout,
            )
            self.assertEqual(
                1,
                result.stdout.count(
                    "PASS  python/native-unary-load:"
                ),
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-unary-service",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-unary-http",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: affected-fast defers "
                "the broad suite",
                result.stdout,
            )
            self.assertIn(
                "SKIP  python/full-suite: affected-fast defers full "
                "discovery",
                result.stdout,
            )
            self.assertIn(
                "SKIP  portability/cross-target: affected-fast defers "
                "retained targets",
                result.stdout,
            )
            self.assertNotIn("PASS  native/metal:", result.stdout)
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            focused_calls = [
                line
                for line in calls
                if line.startswith("build unary-server-process-test ")
            ]
            self.assertEqual(1, len(focused_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(focused_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "unary-text-service-test" in line
                    or "unary-http-test" in line
                    or "model_forward" in line
                    or "package-module-test" in line
                    or "native-metal" in line
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_unary_http_and_service_tests_share_one_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            http = repository / "src" / "prepared_text_unary_http_v1.zig"
            http.write_text("", encoding="ascii")
            service_test = repository / "tests" / "unary_text_service.zig"
            service_test.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build unary-text-service-test unary-http-test "
                ),
                build_calls,
            )
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertNotIn("text-runtime-golden-path-test", build_calls[0])
            self.assertNotIn("-Dtarget=", build_calls[0])

    def test_affected_fast_package_text_paths_share_one_focused_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            model = repository / "src" / "model"
            model.mkdir()
            (model / "dense_autoregressive_profile.zig").write_text(
                "",
                encoding="ascii",
            )
            (model / "package_producer.zig").write_text("", encoding="ascii")
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "text_run.zig").write_text("", encoding="ascii")
            (repository / "bench" / "prepared_text_package.py").write_text(
                "",
                encoding="ascii",
            )
            (repository / "bench" / "prepared_text_raw_input.py").write_text(
                "",
                encoding="ascii",
            )
            (repository / "bench" / "text_runtime_golden_path.py").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-package-text-run: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-unary-service",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-recovery",
                result.stdout,
            )
            self.assertNotIn(
                "native/releasesafe-suite: covered",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            focused_calls = [
                line
                for line in calls
                if line.startswith("build text-runtime-golden-path-test ")
            ]
            self.assertEqual(1, len(focused_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(focused_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "prepared-text-recovery-test" in line
                    or "host-runtime-compile" in line
                    or "package-module-test" in line
                    or " -Dtarget=" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_package_python_tests_run_without_zig_build(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            raw_marker = root / "raw-input.marker"
            package_marker = root / "package.marker"
            environment["VERIFY_RAW_INPUT_MARKER"] = str(raw_marker)
            environment["VERIFY_PACKAGE_MARKER"] = str(package_marker)

            (
                repository / "bench" / "tests" / "test_prepared_text_raw_input.py"
            ).write_text(
                "import os\n"
                "from pathlib import Path\n"
                "import unittest\n"
                "class RawInputTests(unittest.TestCase):\n"
                "    def test_exact_module(self):\n"
                "        Path(os.environ['VERIFY_RAW_INPUT_MARKER']).write_text(\n"
                "            'raw-input', encoding='ascii')\n",
                encoding="ascii",
            )
            (
                repository / "bench" / "tests" / "test_prepared_text_package.py"
            ).write_text(
                "import os\n"
                "from pathlib import Path\n"
                "import unittest\n"
                "class PackageTests(unittest.TestCase):\n"
                "    def test_exact_module(self):\n"
                "        Path(os.environ['VERIFY_PACKAGE_MARKER']).write_text(\n"
                "            'package', encoding='ascii')\n",
                encoding="ascii",
            )
            (repository / "bench" / "tests" / "test_unrelated.py").write_text(
                "import unittest\n"
                "class UnrelatedTests(unittest.TestCase):\n"
                "    def test_not_discovered(self):\n"
                "        self.fail('full discovery must remain deferred')\n",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  python/prepared-text-package:",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-package-text-run",
                result.stdout,
            )
            self.assertEqual(
                "raw-input",
                raw_marker.read_text(encoding="ascii"),
            )
            self.assertEqual(
                "package",
                package_marker.read_text(encoding="ascii"),
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertFalse(
                any(line.startswith("build ") for line in calls),
                calls,
            )

    def test_affected_package_text_cross_compiles_only_cli_root(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "text_run.zig").write_text("", encoding="ascii")

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            target_calls = [
                line for line in calls if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            for call in target_calls:
                self.assertTrue(
                    call.startswith(
                        "build text-runtime-golden-path-compile "
                    ),
                    target_calls,
                )
                self.assertNotIn("profile-host-tool-compile", call)
                self.assertNotIn("profile-cpu-compile", call)
                self.assertNotIn("profile-durable-compile", call)

    def test_affected_fast_mixed_host_roots_share_one_zig_invocation(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "text_run.zig").write_text("", encoding="ascii")
            (repository / "src" / "prepared_text_unary_service.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-package-text-run: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-service: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-http: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-unary-server-process: covered by "
                "the focused host Zig DAG",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(1, len(build_calls), calls)
            self.assertTrue(
                build_calls[0].startswith(
                    "build unary-text-service-test "
                    "unary-http-test "
                    "unary-server-process-test "
                    "text-runtime-golden-path-test "
                ),
                build_calls,
            )
            self.assertNotIn("package-module-test", build_calls[0])
            self.assertNotIn("-Dtarget=", build_calls[0])

    def test_affected_fast_direct_terminal_smoke_runs_only_smoke_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (
                repository / "bench" / "prepared_text_direct_terminal_recovery.py"
            ).write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-direct-terminal-smoke: "
                "covered by the focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-delivery",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-recovery",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-inspector",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            smoke_calls = [
                line
                for line in calls
                if line.startswith(
                    "build prepared-text-direct-terminal-recovery-smoke-test "
                )
            ]
            self.assertEqual(1, len(smoke_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(smoke_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "prepared-text-acknowledged-delivery-test" in line
                    or "prepared-text-recovery-test" in line
                    or "prepared-text-result-inspector-test" in line
                    or "package-module-test" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_direct_terminal_source_runs_delivery_and_smoke_once(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "src" / "prepared_text_direct_terminal.zig").write_text(
                "", encoding="ascii"
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-delivery: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-inspector",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-recovery",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/prepared-text-direct-terminal-smoke: "
                "covered by the focused host Zig DAG",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            delivery_calls = [
                line
                for line in calls
                if line.startswith(
                    "build prepared-text-acknowledged-delivery-test "
                    "prepared-text-direct-terminal-recovery-smoke-test "
                )
            ]
            self.assertEqual(1, len(delivery_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(delivery_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "prepared-text-result-inspector-test" in line
                    or "prepared-text-recovery-test" in line
                    or "package-module-test" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_recovery_campaign_only_runs_recovery_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            (repository / "bench" / "prepared_text_recovery_campaign.py").write_text(
                "", encoding="ascii"
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-recovery: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-delivery",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-inspector",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-direct-terminal-smoke",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            recovery_calls = [
                line
                for line in calls
                if line.startswith("build prepared-text-recovery-test ")
            ]
            self.assertEqual(1, len(recovery_calls), calls)
            build_calls = [line for line in calls if line.startswith("build ")]
            self.assertEqual(recovery_calls, build_calls, calls)
            self.assertFalse(
                any(
                    "prepared-text-acknowledged-delivery-test" in line
                    or "prepared-text-result-inspector-test" in line
                    or "prepared-text-direct-terminal-recovery-smoke-test" in line
                    or "package-module-test" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_inspector_only_avoids_death_campaign(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            cli = repository / "src" / "cli"
            cli.mkdir()
            (cli / "prepared_text_result_inspector.zig").write_text(
                "",
                encoding="ascii",
            )

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/prepared-text-inspector: covered by the "
                "focused host Zig DAG",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-recovery",
                result.stdout,
            )
            self.assertNotIn(
                "native/prepared-text-delivery",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            focused_calls = [
                line
                for line in calls
                if line.startswith("build prepared-text-result-inspector-test ")
            ]
            self.assertEqual(1, len(focused_calls), calls)
            self.assertFalse(
                any("prepared-text-recovery-test" in line for line in calls),
                calls,
            )
            self.assertFalse(
                any(
                    "prepared-text-acknowledged-delivery-test" in line
                    or "package-module-test" in line
                    for line in calls
                ),
                calls,
            )

    def test_affected_fast_keeps_selected_focused_native_gate(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            campaign_path = (
                repository / "bench" / "native_workload_store_fault_campaign.py"
            )
            campaign_path.write_text("", encoding="ascii")

            result = self.run_affected_fast(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn("PASS  python/changed-syntax:", result.stdout)
            self.assertIn(
                "PASS  native/workload-store-fault:",
                result.stdout,
            )
            self.assertIn(
                "SKIP  python/full-suite: affected-fast defers full discovery",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith("build native-workload-store-fault-test ")
                    for line in calls
                ),
                calls,
            )
            self.assertEqual(
                1,
                sum(line.startswith("build ") for line in calls),
                calls,
            )
            self.assertFalse(
                any(" -Dtarget=" in line for line in calls),
                calls,
            )

    def test_store_fault_campaign_and_store_changes_select_hard_gate(self):
        for changed_path in (
            "bench/native_workload_store_fault_campaign.py",
            "bench/native_metal_soak_report.py",
        ):
            with self.subTest(changed_path=changed_path):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    repository, merge_base, environment = self.make_repository(root)
                    path = repository / changed_path
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("", encoding="ascii")

                    result = self.run_verify(
                        repository,
                        merge_base,
                        environment,
                    )

                    self.assertEqual(
                        0,
                        result.returncode,
                        result.stdout + result.stderr,
                    )
                    self.assertIn(
                        "PASS  native/workload-store-fault:",
                        result.stdout,
                    )
                    self.assertNotIn(
                        "PASS  portable/workload-report:",
                        result.stdout,
                    )
                    calls = (
                        Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                        .read_text(encoding="ascii")
                        .splitlines()
                    )
                    hard_calls = [
                        line
                        for line in calls
                        if line.startswith("build native-workload-store-fault-test ")
                    ]
                    self.assertEqual(1, len(hard_calls), hard_calls)
                    self.assertIn("-Dmetal=false ", hard_calls[0])
                    self.assertFalse(
                        any(" -Dtarget=" in line for line in hard_calls),
                        hard_calls,
                    )

    def test_store_fault_gate_has_explicit_native_availability(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            campaign_path = (
                repository / "bench" / "native_workload_store_fault_campaign.py"
            )
            campaign_path.write_text("", encoding="ascii")
            uname = root / "fake-bin" / "uname"
            self.make_fake_command(uname, "printf 'Darwin\\n'\n")

            darwin = self.run_verify(repository, merge_base, environment)
            self.assertEqual(
                0,
                darwin.returncode,
                darwin.stdout + darwin.stderr,
            )
            self.assertIn(
                "PASS  native/workload-store-fault:",
                darwin.stdout,
            )

            self.make_fake_command(uname, "printf 'TestOS\\n'\n")
            ordinary = self.run_verify(repository, merge_base, environment)
            self.assertEqual(
                0,
                ordinary.returncode,
                ordinary.stdout + ordinary.stderr,
            )
            self.assertIn(
                "SKIP  native/workload-store-fault: requires native "
                "Darwin, Linux, or FreeBSD POSIX execution",
                ordinary.stdout,
            )

            strict_environment = dict(environment)
            strict_environment["GLACIER_VERIFY_REQUIRE_NATIVE"] = "1"
            strict = self.run_verify(
                repository,
                merge_base,
                strict_environment,
            )
            self.assertNotEqual(0, strict.returncode)
            self.assertIn(
                "FAIL  native/workload-store-fault: requires native "
                "Darwin, Linux, or FreeBSD POSIX execution",
                strict.stdout,
            )

    def test_shell_rejects_unknown_or_out_of_order_policy_targets(self):
        mutations = (
            (
                "unknown",
                '"x86_64-linux-musl",',
                '"a-valid-but-unknown-target",',
                "policy emitted an unknown target: a-valid-but-unknown-target",
            ),
            (
                "out-of-order",
                ('    "x86_64-linux-musl",\n    "aarch64-linux-musl",'),
                ('    "aarch64-linux-musl",\n    "x86_64-linux-musl",'),
                ("policy emitted targets out of retained order: x86_64-linux-musl"),
            ),
        )
        for name, before, after, expected_message in mutations:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    repository, merge_base, environment = self.make_repository(root)
                    policy_path = repository / "tools" / "verification_policy.py"
                    source = policy_path.read_text(encoding="utf-8")
                    self.assertEqual(1, source.count(before))
                    policy_path.write_text(
                        source.replace(before, after, 1),
                        encoding="utf-8",
                    )
                    (repository / "src" / "runtime.zig").write_text(
                        "changed\n",
                        encoding="ascii",
                    )

                    result = self.run_verify(
                        repository,
                        merge_base,
                        environment,
                    )

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(expected_message, result.stdout)
                    target_calls = [
                        line
                        for line in Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                        .read_text(encoding="ascii")
                        .splitlines()
                        if " -Dtarget=" in line
                    ]
                    self.assertEqual([], target_calls)

    def test_native_strict_mode_and_policy_emitted_target_execution(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)

            darwin_path = repository / "src" / "platform" / "darwin" / "runtime.zig"
            darwin_path.parent.mkdir(parents=True)
            darwin_path.write_text("", encoding="ascii")
            ordinary = self.run_verify(repository, merge_base, environment)
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
            strict = self.run_verify(repository, merge_base, strict_environment)
            self.assertNotEqual(strict.returncode, 0)
            self.assertIn(
                "FAIL  native/darwin: requires native Darwin execution",
                strict.stdout,
            )

            darwin_path.unlink()
            shared_path = repository / "src" / "runtime.zig"
            shared_path.write_text("", encoding="ascii")
            zig_log = Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
            zig_log.write_text("", encoding="ascii")
            shared = self.run_verify(repository, merge_base, environment)
            self.assertEqual(
                shared.returncode,
                0,
                shared.stdout + shared.stderr,
            )
            for target in policy.RETAINED_TARGETS:
                self.assertIn(
                    "PASS  portability/"
                    + target
                    + "/install+install-benchmarks+test-compile:",
                    shared.stdout,
                )
                self.assertNotIn(
                    "portability/" + target + "/build:",
                    shared.stdout,
                )
                self.assertNotIn(
                    "portability/" + target + "/test-compile:",
                    shared.stdout,
                )
            target_calls = [
                line
                for line in zig_log.read_text(encoding="ascii").splitlines()
                if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            self.assertTrue(
                all(
                    line.startswith("build install install-benchmarks test-compile ")
                    for line in target_calls
                ),
                target_calls,
            )
            for target in policy.RETAINED_TARGETS:
                self.assertEqual(
                    1,
                    sum(" -Dtarget=" + target + " " in line for line in target_calls),
                    target_calls,
                )

            shared_path.unlink()
            rust_path = repository / "examples" / "interop" / "rust_verify.rs"
            rust_path.parent.mkdir(parents=True)
            rust_path.write_text("fn main() {}\n", encoding="ascii")
            zig_log.write_text("", encoding="ascii")
            rust = self.run_verify(repository, merge_base, environment)
            self.assertEqual(
                rust.returncode,
                0,
                rust.stdout + rust.stderr,
            )
            self.assertIn("PASS  interop/rust:", rust.stdout)
            self.assertNotIn("PASS  portability/", rust.stdout)
            self.assertFalse(
                any(
                    " -Dtarget=" in line
                    for line in zig_log.read_text(encoding="ascii").splitlines()
                )
            )

    def test_combined_target_gate_propagates_one_target_failure(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            windows_path = repository / "src" / "platform" / "windows" / "runtime.zig"
            windows_path.parent.mkdir(parents=True)
            windows_path.write_text("", encoding="ascii")
            target = policy.WINDOWS_TARGETS[0]
            environment["VERIFY_INTEGRATION_FAIL_TARGET"] = target

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "FAIL  portability/"
                + target
                + "/install+install-benchmarks+test-compile: exit 19",
                result.stdout,
            )
            target_calls = [
                line
                for line in Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
                if " -Dtarget=" in line
            ]
            self.assertEqual(1, len(target_calls), target_calls)
            self.assertIn(
                "build install install-benchmarks test-compile -Dtarget="
                + target
                + " ",
                target_calls[0],
            )

    def test_main_runtime_closure_uses_one_invocation_per_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            core_path = repository / "src" / "core" / "scheduler.zig"
            core_path.parent.mkdir(parents=True)
            core_path.write_text("", encoding="ascii")
            cpu_path = repository / "src" / "backends" / "cpu" / "backend.zig"
            cpu_path.parent.mkdir(parents=True)
            cpu_path.write_text("", encoding="ascii")

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            target_calls = [
                line
                for line in Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
                if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            for target in policy.RETAINED_TARGETS:
                expected = "build install test-compile -Dtarget=" + target + " "
                self.assertEqual(
                    1,
                    sum(line.startswith(expected) for line in target_calls),
                    target_calls,
                )
                self.assertIn(
                    "PASS  portability/" + target + "/install+test-compile:",
                    result.stdout,
                )

    def test_full_steps_dominate_focused_profiles_per_target_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            core_path = repository / "src" / "core" / "scheduler.zig"
            core_path.parent.mkdir(parents=True)
            core_path.write_text("", encoding="ascii")
            windows_path = repository / "src" / "platform" / "windows" / "dispatch.zig"
            windows_path.parent.mkdir(parents=True)
            windows_path.write_text("", encoding="ascii")

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            target_calls = [
                line
                for line in Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
                if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            windows_target = policy.WINDOWS_TARGETS[0]
            for target in policy.RETAINED_TARGETS:
                if target == windows_target:
                    expected_steps = "install install-benchmarks test-compile"
                else:
                    expected_steps = "install test-compile"
                self.assertEqual(
                    1,
                    sum(
                        line.startswith(
                            "build " + expected_steps + " -Dtarget=" + target + " "
                        )
                        for line in target_calls
                    ),
                    target_calls,
                )

    def test_matrix_keeps_one_full_invocation_per_retained_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, _, environment = self.make_repository(root)

            result = self.run_matrix(repository, environment)

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            target_calls = [
                line
                for line in Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
                if " -Dtarget=" in line
            ]
            self.assertEqual(
                len(policy.RETAINED_TARGETS),
                len(target_calls),
                target_calls,
            )
            self.assertTrue(
                all(
                    line.startswith("build install install-benchmarks test-compile ")
                    for line in target_calls
                ),
                target_calls,
            )
            self.assertIn(
                "PASS  native/workload-store-fault:",
                result.stdout,
            )
            all_calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith("build native-workload-store-fault-test ")
                    for line in all_calls
                ),
                all_calls,
            )

    def test_full_profile_includes_the_hard_store_fault_gate(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, _, environment = self.make_repository(root)

            result = self.run_full(repository, environment)

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/workload-store-fault:",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            compile_calls = [
                line
                for line in calls
                if line.startswith("build host-runtime-compile ")
                and " -Dtarget=" not in line
            ]
            runtime_calls = [
                line
                for line in calls
                if line.startswith("build test contract-interop-test ")
            ]
            self.assertEqual(1, len(compile_calls), calls)
            self.assertEqual(1, len(runtime_calls), calls)
            self.assertLess(
                calls.index(compile_calls[0]),
                calls.index(runtime_calls[0]),
            )
            self.assertFalse(
                any(
                    line.startswith("build contract-interop-test ")
                    or line.startswith("build package-module-test ")
                    for line in calls
                ),
                calls,
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith("build native-workload-store-fault-test ")
                    for line in calls
                ),
                calls,
            )

    def test_full_compile_failure_suppresses_runtime_and_hard_campaign(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, _, environment = self.make_repository(root)
            environment["VERIFY_INTEGRATION_FAIL_HOST_COMPILE"] = "1"

            result = self.run_full(repository, environment)

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "FAIL  compile/host-test-frontier: exit 29",
                result.stdout,
            )
            self.assertIn(
                "SKIP  native/workload-store-fault: host test compile frontier failed",
                result.stdout,
            )
            calls = (
                Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
                .read_text(encoding="ascii")
                .splitlines()
            )
            self.assertEqual(
                1,
                sum(
                    line.startswith("build host-runtime-compile ")
                    and " -Dtarget=" not in line
                    for line in calls
                ),
                calls,
            )
            self.assertFalse(
                any(
                    line.startswith("build test contract-interop-test ")
                    or line.startswith("build native-workload-store-fault-test ")
                    for line in calls
                ),
                calls,
            )

    def test_posix_reuses_native_suite_for_darwin_evidence(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'Darwin\\n'\n",
            )
            posix_path = repository / "src" / "platform" / "posix" / "files.zig"
            posix_path.parent.mkdir(parents=True)
            posix_path.write_text("", encoding="ascii")
            zig_log = Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
            zig_log.write_text("", encoding="ascii")

            result = self.run_verify(
                repository,
                merge_base,
                environment,
            )

            self.assertEqual(
                0,
                result.returncode,
                result.stdout + result.stderr,
            )
            self.assertIn(
                "PASS  native/releasesafe-suite: covered by the shared "
                "host runtime DAG",
                result.stdout,
            )
            self.assertIn(
                "PASS  native/darwin: covered by the shared host runtime DAG",
                result.stdout,
            )
            calls = zig_log.read_text(encoding="ascii").splitlines()
            compile_calls = [
                line for line in calls if line.startswith("build host-runtime-compile ")
            ]
            native_test_calls = [
                line
                for line in calls
                if line.startswith("build test contract-interop-test ")
            ]
            self.assertEqual(1, len(compile_calls), compile_calls)
            self.assertEqual(1, len(native_test_calls), native_test_calls)
            self.assertLess(
                calls.index(compile_calls[0]),
                calls.index(native_test_calls[0]),
            )

            zig_log.write_text("", encoding="ascii")
            failure_environment = dict(environment)
            failure_environment["VERIFY_INTEGRATION_FAIL_NATIVE_TEST"] = "1"
            failed = self.run_verify(
                repository,
                merge_base,
                failure_environment,
            )
            self.assertNotEqual(0, failed.returncode)
            self.assertIn(
                "FAIL  host/runtime-dag: exit 23",
                failed.stdout,
            )
            self.assertIn(
                "SKIP  native/releasesafe-suite: shared host runtime DAG failed",
                failed.stdout,
            )
            self.assertIn(
                "FAIL  native/darwin: covering host compile or runtime DAG failed",
                failed.stdout,
            )
            failed_native_test_calls = [
                line
                for line in zig_log.read_text(encoding="ascii").splitlines()
                if line.startswith("build test contract-interop-test ")
            ]
            self.assertEqual(
                1,
                len(failed_native_test_calls),
                failed_native_test_calls,
            )

    def test_aarch64_kernel_requires_aarch64_darwin_evidence(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                'case "${1:-}" in\n'
                "    -m) printf 'x86_64\\n' ;;\n"
                "    *) printf 'Darwin\\n' ;;\n"
                "esac\n",
            )
            source_path = repository / "src" / "backends" / "cpu" / "int4_neon.c"
            source_path.parent.mkdir(parents=True)
            source_path.write_text("", encoding="ascii")
            zig_log = Path(environment["VERIFY_INTEGRATION_ZIG_LOG"])
            zig_log.write_text("", encoding="ascii")

            intel = self.run_verify(
                repository,
                merge_base,
                environment,
            )
            self.assertEqual(
                0,
                intel.returncode,
                intel.stdout + intel.stderr,
            )
            self.assertIn(
                "SKIP  native/darwin-aarch64: requires native Darwin AArch64 execution",
                intel.stdout,
            )
            native_test_calls = [
                line
                for line in zig_log.read_text(encoding="ascii").splitlines()
                if line.startswith("build test contract-interop-test ")
            ]
            self.assertEqual(1, len(native_test_calls), native_test_calls)

            strict_environment = dict(environment)
            strict_environment["GLACIER_VERIFY_REQUIRE_NATIVE"] = "1"
            strict = self.run_verify(
                repository,
                merge_base,
                strict_environment,
            )
            self.assertNotEqual(0, strict.returncode)
            self.assertIn(
                "FAIL  native/darwin-aarch64: requires native Darwin AArch64 execution",
                strict.stdout,
            )

            self.make_fake_command(
                root / "fake-bin" / "uname",
                'case "${1:-}" in\n'
                "    -m) printf 'arm64\\n' ;;\n"
                "    *) printf 'Darwin\\n' ;;\n"
                "esac\n",
            )
            zig_log.write_text("", encoding="ascii")
            arm64 = self.run_verify(
                repository,
                merge_base,
                environment,
            )
            self.assertEqual(
                0,
                arm64.returncode,
                arm64.stdout + arm64.stderr,
            )
            self.assertIn(
                "PASS  native/darwin-aarch64: covered by the shared host runtime DAG",
                arm64.stdout,
            )
            arm64_native_test_calls = [
                line
                for line in zig_log.read_text(encoding="ascii").splitlines()
                if line.startswith("build test contract-interop-test ")
            ]
            self.assertEqual(
                1,
                len(arm64_native_test_calls),
                arm64_native_test_calls,
            )
            arm64_target_calls = [
                line
                for line in zig_log.read_text(encoding="ascii").splitlines()
                if " -Dtarget=" in line
            ]
            self.assertEqual(1, len(arm64_target_calls))
            self.assertTrue(
                arm64_target_calls[0].startswith(
                    "build profile-cpu-compile profile-host-tool-compile "
                ),
                arm64_target_calls,
            )

    def test_swift_probe_requires_the_focused_darwin_gate(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            swift_path = repository / "bench" / "lane4_process_info.swift"
            swift_path.write_text(
                'import Foundation\nprint("probe")\n',
                encoding="ascii",
            )

            ordinary = self.run_verify(
                repository,
                merge_base,
                environment,
            )
            self.assertEqual(
                0,
                ordinary.returncode,
                ordinary.stdout + ordinary.stderr,
            )
            self.assertIn(
                "SKIP  native/darwin-swift: requires native Darwin execution",
                ordinary.stdout,
            )

            strict_environment = dict(environment)
            strict_environment["GLACIER_VERIFY_REQUIRE_NATIVE"] = "1"
            strict = self.run_verify(
                repository,
                merge_base,
                strict_environment,
            )
            self.assertNotEqual(0, strict.returncode)
            self.assertIn(
                "FAIL  native/darwin-swift: requires native Darwin execution",
                strict.stdout,
            )

    @unittest.skipUnless(
        Path("/usr/bin/swiftc").is_file(),
        "native Swift type-check integration requires /usr/bin/swiftc",
    )
    def test_swift_probe_typechecks_foundation_api_on_darwin(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository, merge_base, environment = self.make_repository(root)
            self.make_fake_command(
                root / "fake-bin" / "uname",
                "printf 'Darwin\\n'\n",
            )
            swift_path = repository / "bench" / "lane4_process_info.swift"
            swift_path.write_text(
                "import Foundation\n_ = ProcessInfo.processInfo.activeProcessorCount\n",
                encoding="ascii",
            )

            valid = self.run_verify(
                repository,
                merge_base,
                environment,
            )
            self.assertEqual(
                0,
                valid.returncode,
                valid.stdout + valid.stderr,
            )
            self.assertIn("PASS  native/darwin-swift:", valid.stdout)

            swift_path.write_text(
                "import Foundation\n_ = ProcessInfo.processInfo.definitelyMissing\n",
                encoding="ascii",
            )
            invalid = self.run_verify(
                repository,
                merge_base,
                environment,
            )
            self.assertNotEqual(0, invalid.returncode)
            self.assertIn("FAIL  native/darwin-swift:", invalid.stdout)


if __name__ == "__main__":
    unittest.main()
