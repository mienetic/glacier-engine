import copy
import datetime as dt
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "lane4_evidence.py"
SPEC = importlib.util.spec_from_file_location("lane4_evidence", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
lane4 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lane4)


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class Lane4EvidenceTests(unittest.TestCase):
    def _runner(
        self,
        *,
        battery: str,
        thermal: str,
        foundation_thermal: str = "nominal",
        low_power_mode: bool = False,
    ):
        process_info = json.dumps(
            {
                "schema": lane4.PROCESS_INFO_SCHEMA,
                "thermal_state": foundation_thermal,
                "low_power_mode_enabled": low_power_mode,
            },
            sort_keys=True,
        )
        responses = {
            (lane4.PMSET, "-g", "batt"): battery,
            (lane4.PMSET, "-g", "therm"): thermal,
            (lane4.SYSCTL, "-n", "machdep.cpu.brand_string"): "Apple M1\n",
            (lane4.SYSCTL, "-n", "kern.bootsessionuuid"): "same-boot-session\n",
            (lane4.SWIFT, str(lane4.FOUNDATION_PROBE_SOURCE)): process_info,
        }

        def run(argv):
            return subprocess.CompletedProcess(
                argv, 0, stdout=responses[tuple(argv)], stderr=""
            )

        return run

    def test_power_probe_fails_closed_on_battery(self):
        runner = self._runner(
            battery=(
                "Now drawing from 'Battery Power'\n"
                " -InternalBattery-0\t70%; discharging; 2:39 remaining\n"
            ),
            thermal=(
                "Note: No thermal warning level has been recorded\n"
                "Note: No performance warning level has been recorded\n"
            ),
        )
        with (
            mock.patch.object(lane4.platform, "system", return_value="Darwin"),
            mock.patch.object(
                lane4,
                "_foundation_runner_sha256",
                return_value=(_sha(b"swift-runner"), None),
            ),
        ):
            snapshot = lane4.capture_environment(runner)
        self.assertFalse(snapshot["measurement_admitted"])
        self.assertFalse(snapshot["measurements_publishable"])
        self.assertEqual(snapshot["performance_claim"], "not_evaluated")
        self.assertIn("battery is discharging", snapshot["reasons"])

    def test_power_probe_admits_only_explicit_ac_nominal(self):
        runner = self._runner(
            battery=(
                "Now drawing from 'AC Power'\n"
                " -InternalBattery-0\t100%; charged; 0:00 remaining\n"
            ),
            thermal=(
                "Note: No thermal warning level has been recorded\n"
                "Note: No performance warning level has been recorded\n"
                "CPU_Speed_Limit = 100\n"
                "Scheduler_Limit = 100\n"
            ),
        )
        with (
            mock.patch.object(lane4.platform, "system", return_value="Darwin"),
            mock.patch.object(
                lane4,
                "_foundation_runner_sha256",
                return_value=(_sha(b"swift-runner"), None),
            ),
        ):
            snapshot = lane4.capture_environment(runner)
        self.assertTrue(snapshot["measurement_admitted"])
        self.assertEqual(snapshot["thermal_state"], "nominal")
        self.assertEqual(snapshot["foundation_thermal_state"], "nominal")
        self.assertFalse(snapshot["low_power_mode_enabled"])
        self.assertEqual(
            snapshot["foundation_probe_source_sha256"],
            lane4.FOUNDATION_PROBE_SOURCE_SHA256,
        )
        self.assertFalse(snapshot["measurements_publishable"])
        self.assertEqual(snapshot["promotion_decision"], "not_evaluated")

    def test_foundation_probe_fails_closed_on_thermal_or_low_power_mode(self):
        battery = (
            "Now drawing from 'AC Power'\n"
            " -InternalBattery-0\t100%; charged; 0:00 remaining\n"
        )
        thermal = (
            "Note: No thermal warning level has been recorded\n"
            "Note: No performance warning level has been recorded\n"
        )
        for foundation_thermal, low_power_mode in (
            ("fair", False),
            ("nominal", True),
        ):
            with self.subTest(
                foundation_thermal=foundation_thermal,
                low_power_mode=low_power_mode,
            ):
                runner = self._runner(
                    battery=battery,
                    thermal=thermal,
                    foundation_thermal=foundation_thermal,
                    low_power_mode=low_power_mode,
                )
                with (
                    mock.patch.object(
                        lane4.platform, "system", return_value="Darwin"
                    ),
                    mock.patch.object(
                        lane4,
                        "_foundation_runner_sha256",
                        return_value=(_sha(b"swift-runner"), None),
                    ),
                ):
                    snapshot = lane4.capture_environment(runner)
                self.assertFalse(snapshot["measurement_admitted"])
                self.assertFalse(snapshot["measurements_publishable"])

    def test_foundation_probe_source_pin_fails_closed(self):
        runner = self._runner(
            battery="Now drawing from 'AC Power'\nNo batteries\n",
            thermal=(
                "Note: No thermal warning level has been recorded\n"
                "Note: No performance warning level has been recorded\n"
            ),
        )
        with (
            mock.patch.object(lane4.platform, "system", return_value="Darwin"),
            mock.patch.object(
                lane4,
                "FOUNDATION_PROBE_SOURCE_SHA256",
                "0" * 64,
            ),
            mock.patch.object(
                lane4,
                "_foundation_runner_sha256",
                return_value=(_sha(b"swift-runner"), None),
            ),
        ):
            snapshot = lane4.capture_environment(runner)
        self.assertFalse(snapshot["measurement_admitted"])
        self.assertTrue(
            any("source SHA-256" in reason for reason in snapshot["reasons"])
        )

    def test_thermal_probe_rejects_unknown_or_reduced_state(self):
        unknown = lane4.parse_pmset_thermal("no useful thermal data\n")
        self.assertFalse(unknown["admitted"])
        reduced = lane4.parse_pmset_thermal(
            "Note: No thermal warning level has been recorded\n"
            "Note: No performance warning level has been recorded\n"
            "CPU_Speed_Limit = 80\n"
        )
        self.assertFalse(reduced["admitted"])

    def _environment(self, captured_at: dt.datetime) -> dict:
        host = {
            "system": "Darwin",
            "release": "24.5.0",
            "machine": "arm64",
            "cpu_brand": "Apple M1",
            "logical_cpu_count": 8,
            "boot_session_sha256": _sha(b"same-boot-session"),
        }
        canonical = json.dumps(
            host, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("ascii")
        host["fingerprint_sha256"] = _sha(canonical)
        return {
            "schema": lane4.ENVIRONMENT_SCHEMA,
            "captured_at_utc": captured_at.isoformat(),
            "host": host,
            "power_source": "AC Power",
            "battery_state": "charged",
            "thermal_state": "nominal",
            "foundation_thermal_state": "nominal",
            "low_power_mode_enabled": False,
            "cpu_speed_limit_percent": 100,
            "scheduler_limit_percent": 100,
            "available_cpus": 8,
            "raw_pmset_battery_sha256": _sha(b"ac-power"),
            "raw_pmset_thermal_sha256": _sha(b"nominal-thermal"),
            "raw_foundation_process_info_sha256": _sha(b"foundation-nominal"),
            "foundation_probe_source_sha256": (
                lane4.FOUNDATION_PROBE_SOURCE_SHA256
            ),
            "foundation_probe_runner_sha256": _sha(b"swift-runner"),
            "measurement_admitted": True,
            "reasons": [],
            "claim_scope": "environment-admission-only",
            "performance_claim": "not_evaluated",
            "promotion_decision": "not_evaluated",
            "measurements_publishable": False,
        }

    def _execution_counters(
        self, mode: str, terminal: int, layer_count: int
    ) -> dict:
        if mode == lane4.MODE_B4:
            return {
                "abi_version": lane4.DECODE_LANE4_ABI,
                "layer_count": layer_count,
                "token_graphs": terminal,
                "layer_m4_graphs": terminal * layer_count,
                "projection_m4_dispatches": 5 * terminal * layer_count,
                "qkv_projection_dispatches": 3 * terminal * layer_count,
                "qkv_activation_quantizations": terminal * layer_count,
                "qkv_quantization_reuses": 2 * terminal * layer_count,
                "weight_stationary_norm_dispatches": (
                    2 * terminal * layer_count + lane4.NEW_TOKENS_PER_LANE
                ),
                "lane_parallel_attention_dispatches": terminal * layer_count,
                "lane_parallel_attention_tasks": (
                    lane4.WIDTH * terminal * layer_count
                ),
                "lane_attention_enqueue_rejects": 0,
                "pair_m4_dispatches": terminal * layer_count,
                "lm_head_m4_dispatches": lane4.NEW_TOKENS_PER_LANE,
                "active_lane_steps": lane4.WIDTH * terminal,
                "padded_lane_steps": 0,
                "fallbacks": 0,
                "admitted_cohorts": 1,
                "cohort_width": lane4.WIDTH,
                "thread_participants": lane4.TOTAL_WORKER_THREADS,
            }
        return {
            "abi_version": lane4.M1X4_EXECUTION_ABI,
            "layer_count": layer_count,
            "token_graphs_per_lane": [terminal] * lane4.WIDTH,
            "layer_graphs_per_lane": [terminal * layer_count] * lane4.WIDTH,
            "projection_dispatches_per_lane": [
                5 * terminal * layer_count
            ] * lane4.WIDTH,
            "qkv_projection_dispatches_per_lane": [
                3 * terminal * layer_count
            ] * lane4.WIDTH,
            "pair_dispatches_per_lane": [terminal * layer_count] * lane4.WIDTH,
            "lm_head_dispatches_per_lane": [
                lane4.NEW_TOKENS_PER_LANE
            ] * lane4.WIDTH,
            "active_lane_steps": lane4.WIDTH * terminal,
            "padded_lane_steps": 0,
        }

    def _m1_concurrency(self, run_start_ns: int, run_end_ns: int) -> dict:
        epoch = run_start_ns + 17
        release_ns = run_start_ns + 1000
        return {
            "abi_version": lane4.M1X4_CONCURRENCY_ABI,
            "clock_abi": lane4.MONOTONIC_CLOCK_ABI,
            "start_barrier": {
                "owner": "runner",
                "parties": 4,
                "arrival_count": 4,
                "release_count": 1,
                "epoch": epoch,
                "release_ns": release_ns,
            },
            "lane_intervals": [
                {
                    "lane": lane,
                    "barrier_epoch": epoch,
                    "ready_ns": run_start_ns + 100 + lane * 10,
                    "start_ns": release_ns + lane * 10,
                    "end_ns": run_end_ns - lane * 10,
                }
                for lane in range(lane4.WIDTH)
            ],
        }

    def _resource_bank_evidence(self, mode: str, bank_epoch: int) -> tuple[dict, int]:
        if mode == lane4.MODE_M1X4:
            claims = [
                {
                    "capsule_bytes": 16,
                    "kv_bytes": 1024,
                    "activation_bytes": 128,
                    "partial_bytes": 0,
                    "logits_bytes": 256,
                    "output_journal_bytes": 256,
                    "staging_bytes": 64,
                    "device_bytes": 0,
                    "io_bytes": 0,
                    "queue_slots": 1,
                }
                for _lane in range(lane4.WIDTH)
            ]
        else:
            claims = [
                {
                    "capsule_bytes": 64,
                    "kv_bytes": 4096,
                    "activation_bytes": 512,
                    "partial_bytes": 0,
                    "logits_bytes": 1024,
                    "output_journal_bytes": 1024,
                    "staging_bytes": 256,
                    "device_bytes": 0,
                    "io_bytes": 0,
                    "queue_slots": 4,
                }
            ]
        aggregate = {
            field: sum(claim[field] for claim in claims)
            for field in lane4.CLAIM_FIELDS
        }
        host_bytes = sum(aggregate[field] for field in lane4.HOST_CLAIM_FIELDS)
        limits = {"host_bytes": host_bytes, **aggregate}
        zero = {field: 0 for field in lane4.CLAIM_FIELDS}
        receipt_count = len(claims)

        def snapshot(
            used,
            peak,
            *,
            peak_host_bytes,
            committed_receipts,
            successful_reservations,
            successful_commits,
            releases,
        ):
            return {
                "abi_version": lane4.RESOURCE_BANK_ABI,
                "bank_epoch": bank_epoch,
                "limits": copy.deepcopy(limits),
                "used": copy.deepcopy(used),
                "peak": copy.deepcopy(peak),
                "peak_host_bytes": peak_host_bytes,
                "active_reservations": 0,
                "committed_receipts": committed_receipts,
                "successful_reservations": successful_reservations,
                "successful_commits": successful_commits,
                "cancellations": 0,
                "releases": releases,
                "rejected_capacity": 0,
                "rejected_slots": 0,
            }

        receipts = [
            {
                "bank_epoch": bank_epoch,
                "slot_index": index,
                "generation": index + 1,
                "owner_key": 1000 + bank_epoch * 10 + index,
                "integrity": 2000 + bank_epoch * 10 + index,
                "claim": copy.deepcopy(claim),
            }
            for index, claim in enumerate(claims)
        ]
        return (
            {
                "abi_version": lane4.RESOURCE_BANK_ABI,
                "scope": "fresh-bank-per-observation/v1",
                "limits": copy.deepcopy(limits),
                "receipts": receipts,
                "snapshots": {
                    "before": snapshot(
                        zero,
                        zero,
                        peak_host_bytes=0,
                        committed_receipts=0,
                        successful_reservations=0,
                        successful_commits=0,
                        releases=0,
                    ),
                    "committed": snapshot(
                        aggregate,
                        aggregate,
                        peak_host_bytes=host_bytes,
                        committed_receipts=receipt_count,
                        successful_reservations=receipt_count,
                        successful_commits=receipt_count,
                        releases=0,
                    ),
                    "released": snapshot(
                        zero,
                        aggregate,
                        peak_host_bytes=host_bytes,
                        committed_receipts=0,
                        successful_reservations=receipt_count,
                        successful_commits=receipt_count,
                        releases=receipt_count,
                    ),
                },
            },
            host_bytes,
        )

    def _raw_evidence(self, root: Path) -> dict:
        runner_path = root / "runner"
        runner_path.write_bytes(b"runner-v1")
        runner_path.chmod(0o755)
        model_path = root / "model.glrt"
        model_path.write_bytes(b"model-v1")
        foundation_runner_path = root / "swift"
        foundation_runner_path.write_bytes(b"swift-runner")
        foundation_runner_path.chmod(0o755)
        runner_sha = _sha(runner_path.read_bytes())
        model_sha = _sha(model_path.read_bytes())
        foundation_runner_sha = _sha(foundation_runner_path.read_bytes())
        layer_count = 24
        vocab_size = 8192
        workloads = {}
        for terminal in lane4.EXPECTED_TERMINAL_KV_POSITIONS:
            prompt_length = terminal - lane4.NEW_TOKENS_PER_LANE + 1
            workload = {
                "abi_version": lane4.WORKLOAD_ABI,
                "terminal_kv_positions": terminal,
                "prompt_token_ids_by_lane": [
                    [
                        (terminal + lane * 97 + index) % vocab_size
                        for index in range(prompt_length)
                    ]
                    for lane in range(lane4.WIDTH)
                ],
                "seeds": [101, 202, 303, 404],
                "request_options": {
                    "max_new_tokens": lane4.NEW_TOKENS_PER_LANE,
                    "eos_policy": "disabled-u32-max",
                    "eos_token": (1 << 32) - 1,
                    "forced_token_ids_by_lane": [[], [], [], []],
                    "sampler": {
                        "temperature_f32_bits": 0,
                        "top_k": 0,
                        "top_p_f32_bits": 0x3F800000,
                    },
                },
                "execution_options": {
                    "m1_threads_per_request": 1,
                    "m1_runner_workers": 4,
                    "b4_thread_participants": 4,
                    "artifact_policy": "prepared-pair-nibble-required",
                    "decode_frame_policy": "compact-pair-required",
                    "concurrency_abi": lane4.M1X4_CONCURRENCY_ABI,
                    "clock_abi": lane4.MONOTONIC_CLOCK_ABI,
                },
            }
            workload["sha256"] = lane4.canonical_workload_sha256(workload)
            workloads[str(terminal)] = workload
        observations = []
        sequence_index = 0
        origin = dt.datetime(2026, 7, 21, tzinfo=dt.timezone.utc)
        patterns = tuple(
            pattern
            for _round in range(lane4.MIN_BLOCKS_PER_PATTERN)
            for pattern in lane4.VALID_PATTERNS
        )
        for terminal in lane4.EXPECTED_TERMINAL_KV_POSITIONS:
            prompt_tokens = terminal - lane4.NEW_TOKENS_PER_LANE + 1
            lane_states = [
                {
                    "abi_version": lane4.GENERATION_STATE_ABI,
                    "rng_abi": lane4.GENERATION_RNG_ABI,
                    "lane": lane,
                    "prompt_tokens": prompt_tokens,
                    "published_tokens": lane4.NEW_TOKENS_PER_LANE,
                    "kv_positions": terminal,
                    "sampling_calls": lane4.NEW_TOKENS_PER_LANE,
                    "complete": True,
                    "token_ids": [
                        terminal + lane * 1000 + token
                        for token in range(lane4.NEW_TOKENS_PER_LANE)
                    ],
                    "kv_sha256": _sha(f"kv-{terminal}-{lane}".encode("ascii")),
                    "rng_state": [lane + 1, lane + 2, lane + 3, lane + 4],
                }
                for lane in range(lane4.WIDTH)
            ]
            for state in lane_states:
                state["output_sha256"] = lane4.canonical_token_ids_sha256(
                    state["token_ids"]
                )
            for block_index, pattern in enumerate(patterns):
                for position, letter in enumerate(pattern):
                    before = origin + dt.timedelta(seconds=sequence_index * 4)
                    started = before + dt.timedelta(seconds=1)
                    ended = before + dt.timedelta(seconds=2)
                    after = before + dt.timedelta(seconds=3)
                    mode = lane4.MODE_FOR_LETTER[letter]
                    run_start_ns = sequence_index * 10_000_000 + 1_000
                    run_end_ns = run_start_ns + 9_000_000
                    resource_evidence, logical_host_bytes = (
                        self._resource_bank_evidence(mode, sequence_index + 1)
                    )
                    observations.append(
                        {
                            "terminal_kv_positions": terminal,
                            "mode": mode,
                            "sequence_index": sequence_index,
                            "block_index": block_index,
                            "position_in_block": position,
                            "pattern": pattern,
                            "runner_sha256": runner_sha,
                            "model_sha256": model_sha,
                            "workload_sha256": workloads[str(terminal)]["sha256"],
                            "lane4_abi": lane4.DECODE_LANE4_ABI,
                            "resource_bank_abi": lane4.RESOURCE_BANK_ABI,
                            "process_count": 1,
                            "lane_count": 4,
                            "worker_threads": 4,
                            "request_threads": (
                                [1, 1, 1, 1]
                                if mode == lane4.MODE_M1X4
                                else [4]
                            ),
                            "execution_counters": self._execution_counters(
                                mode, terminal, layer_count
                            ),
                            "run_interval_monotonic_ns": {
                                "clock_abi": lane4.MONOTONIC_CLOCK_ABI,
                                "start_ns": run_start_ns,
                                "end_ns": run_end_ns,
                            },
                            "m1_concurrency": (
                                self._m1_concurrency(run_start_ns, run_end_ns)
                                if mode == lane4.MODE_M1X4
                                else None
                            ),
                            "resource_bank_evidence": resource_evidence,
                            "logical_host_claim_bytes": logical_host_bytes,
                            "rss_evidence": {
                                "classification": "non-admissible",
                                "method": "none",
                                "samples": [],
                            },
                            "environment_before": self._environment(before),
                            "environment_after": self._environment(after),
                            "started_at_utc": started.isoformat(),
                            "ended_at_utc": ended.isoformat(),
                            "lane_states": copy.deepcopy(lane_states),
                            "published_tokens_total": 256,
                        }
                    )
                    sequence_index += 1
        return {
            "schema": lane4.RAW_SCHEMA,
            "comparison": lane4.COMPARISON,
            "contract": {
                "width": 4,
                "terminal_kv_positions": list(
                    lane4.EXPECTED_TERMINAL_KV_POSITIONS
                ),
                "minimum_blocks_per_pattern": lane4.MIN_BLOCKS_PER_PATTERN,
                "minimum_observations_per_arm_per_terminal": (
                    lane4.MIN_OBSERVATIONS_PER_ARM
                ),
                "total_worker_threads": 4,
                "comparison_policy": "one-runner-one-model-process/v1",
                "cache_regime": "same-process-shared-prepared-weights",
                "lane4_abi": lane4.DECODE_LANE4_ABI,
                "resource_bank_abi": lane4.RESOURCE_BANK_ABI,
                "new_tokens_per_lane": lane4.NEW_TOKENS_PER_LANE,
                "generation_state_abi": lane4.GENERATION_STATE_ABI,
                "generation_rng_abi": lane4.GENERATION_RNG_ABI,
                "output_token_hash_abi": lane4.OUTPUT_TOKEN_HASH_ABI,
                "model_topology": {
                    "layer_count": layer_count,
                    "vocab_size": vocab_size,
                    "qkv_distinct_group_passes_by_layer": [1] * layer_count,
                },
                "workloads_by_terminal_kv_positions": workloads,
            },
            "artifacts": {
                "runner": {"path": str(runner_path), "sha256": runner_sha},
                "model": {"path": str(model_path), "sha256": model_sha},
                "foundation_probe_source": {
                    "path": str(lane4.FOUNDATION_PROBE_SOURCE),
                    "sha256": lane4.FOUNDATION_PROBE_SOURCE_SHA256,
                },
                "foundation_probe_runner": {
                    "path": str(foundation_runner_path),
                    "sha256": foundation_runner_sha,
                },
            },
            "observations": observations,
        }

    def test_valid_contract_shape_keeps_analysis_unavailable(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = lane4.validate_raw_evidence(
                self._raw_evidence(Path(temporary))
            )
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["checked_observations"], 256)
        self.assertEqual(
            result["checked_terminal_kv_positions"],
            list(lane4.EXPECTED_TERMINAL_KV_POSITIONS),
        )
        self.assertEqual(
            result["minimum_observations_per_arm_per_terminal"], 32
        )
        self.assertTrue(result["exact_lane_state_gate_passed"])
        self.assertTrue(result["evidence_contract_shape_validated"])
        self.assertFalse(result["grounded_runner_telemetry_available"])
        self.assertEqual(
            result["evidence_availability"],
            "unavailable-no-grounded-runner-in-v2",
        )
        self.assertFalse(result["raw_measurements_admissible_for_separate_analysis"])
        self.assertFalse(result["performance_analysis_available"])
        self.assertFalse(result["resource_analysis_available"])
        self.assertFalse(result["resource_measurements_admissible"])
        self.assertFalse(result["measurements_publishable"])
        self.assertEqual(result["performance_claim"], "not_evaluated")
        self.assertNotIn("speedup", result)

    def test_validator_rejects_consistent_execution_and_bank_abi_downgrades(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            old_lane4_abi = 0x47444C3400000001
            evidence["contract"]["lane4_abi"] = old_lane4_abi
            for observation in evidence["observations"]:
                observation["lane4_abi"] = old_lane4_abi
                if observation["mode"] == lane4.MODE_B4:
                    observation["execution_counters"]["abi_version"] = (
                        old_lane4_abi
                    )
            with self.assertRaisesRegex(
                lane4.EvidenceError, "lane4_abi is not DecodeLane4 v2"
            ):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            fake_bank_abi = lane4.RESOURCE_BANK_ABI + 1
            evidence["contract"]["resource_bank_abi"] = fake_bank_abi
            for observation in evidence["observations"]:
                observation["resource_bank_abi"] = fake_bank_abi
                bank_evidence = observation["resource_bank_evidence"]
                bank_evidence["abi_version"] = fake_bank_abi
                for snapshot in bank_evidence["snapshots"].values():
                    snapshot["abi_version"] = fake_bank_abi
            with self.assertRaisesRegex(
                lane4.EvidenceError, "resource_bank_abi is not ResourceBank v1"
            ):
                lane4.validate_raw_evidence(evidence)

    def test_validator_rejects_unbalanced_schedule(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            for observation in evidence["observations"]:
                if (
                    observation["terminal_kv_positions"] == 128
                    and observation["block_index"] == 15
                ):
                    observation["pattern"] = "ABBA"
                    observation["mode"] = lane4.MODE_FOR_LETTER[
                        "ABBA"[observation["position_in_block"]]
                    ]
                    observation["request_threads"] = (
                        [1, 1, 1, 1]
                        if observation["mode"] == lane4.MODE_M1X4
                        else [4]
                    )
                    observation["execution_counters"] = self._execution_counters(
                        observation["mode"], 128, 24
                    )
                    run_interval = observation["run_interval_monotonic_ns"]
                    observation["m1_concurrency"] = (
                        self._m1_concurrency(
                            run_interval["start_ns"], run_interval["end_ns"]
                        )
                        if observation["mode"] == lane4.MODE_M1X4
                        else None
                    )
                    resource_evidence, logical_host_bytes = (
                        self._resource_bank_evidence(
                            observation["mode"], observation["sequence_index"] + 1
                        )
                    )
                    observation["resource_bank_evidence"] = resource_evidence
                    observation["logical_host_claim_bytes"] = logical_host_bytes
            with self.assertRaisesRegex(
                lane4.EvidenceError, "at least 8 ABBA and 8 BAAB"
            ):
                lane4.validate_raw_evidence(evidence)

    def test_validator_rejects_state_mismatch_and_battery_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][1]["lane_states"][0]["rng_state"][3] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "exact stable"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            boundary = evidence["observations"][0]["environment_before"]
            boundary["power_source"] = "Battery Power"
            boundary["battery_state"] = "discharging"
            boundary["measurement_admitted"] = False
            with self.assertRaisesRegex(lane4.EvidenceError, "AC Power"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            boundary = evidence["observations"][0]["environment_before"]
            boundary["low_power_mode_enabled"] = True
            boundary["measurement_admitted"] = False
            with self.assertRaisesRegex(lane4.EvidenceError, "Low Power|low_power"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_rejects_noncanonical_token_ids_and_state_abi(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["lane_states"][0]["token_ids"][0] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "canonical full-ID"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["lane_states"][0]["abi_version"] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "generation-state v1"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["lane_states"][0]["rng_abi"] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "Xoshiro256 state v1"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["lane_states"][0]["complete"] = False
            with self.assertRaisesRegex(lane4.EvidenceError, "complete must be true"):
                lane4.validate_raw_evidence(evidence)

    def test_terminal_kv_targets_bound_the_4096_workload(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            terminal = [
                observation
                for observation in evidence["observations"]
                if observation["terminal_kv_positions"] == 4096
            ][0]
            lane = terminal["lane_states"][0]
            self.assertEqual(lane["prompt_tokens"], 4096 - 64 + 1)
            self.assertEqual(lane["published_tokens"], 64)
            self.assertEqual(lane["kv_positions"], 4096)
            lane["kv_positions"] = 4095
            with self.assertRaisesRegex(lane4.EvidenceError, "terminal target 4096"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_requires_32_observations_per_arm_per_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"] = [
                observation
                for observation in evidence["observations"]
                if not (
                    observation["terminal_kv_positions"] == 128
                    and observation["block_index"] >= 14
                )
            ]
            for sequence_index, observation in enumerate(evidence["observations"]):
                observation["sequence_index"] = sequence_index
            with self.assertRaisesRegex(lane4.EvidenceError, "at least 16"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_rejects_unequal_thread_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["worker_threads"] = 8
            with self.assertRaisesRegex(lane4.EvidenceError, "worker_threads"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_binds_no_eos_graph_and_projection_counts(self):
        mutations = {
            "token_graphs": lambda counters: counters.__setitem__(
                "token_graphs", counters["token_graphs"] - 1
            ),
            "active_lane_steps": lambda counters: counters.__setitem__(
                "active_lane_steps", counters["active_lane_steps"] - 1
            ),
            "projection_m4_dispatches": lambda counters: counters.__setitem__(
                "projection_m4_dispatches",
                counters["projection_m4_dispatches"] - 1,
            ),
            "qkv_activation_quantizations": lambda counters: counters.__setitem__(
                "qkv_activation_quantizations",
                counters["qkv_activation_quantizations"] - 1,
            ),
            "lane_parallel_attention_dispatches": lambda counters: counters.__setitem__(
                "lane_parallel_attention_dispatches",
                counters["lane_parallel_attention_dispatches"] - 1,
            ),
            "lane_parallel_attention_tasks": lambda counters: counters.__setitem__(
                "lane_parallel_attention_tasks",
                counters["lane_parallel_attention_tasks"] - 1,
            ),
            "pair_m4_dispatches": lambda counters: counters.__setitem__(
                "pair_m4_dispatches", counters["pair_m4_dispatches"] - 1
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            for field, mutate in mutations.items():
                with self.subTest(field=field):
                    evidence = self._raw_evidence(Path(temporary))
                    b4 = next(
                        observation
                        for observation in evidence["observations"]
                        if observation["mode"] == lane4.MODE_B4
                    )
                    mutate(b4["execution_counters"])
                    with self.assertRaisesRegex(lane4.EvidenceError, field):
                        lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["lane_states"][0]["sampling_calls"] = 63
            with self.assertRaisesRegex(lane4.EvidenceError, "sampling_calls"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_requires_runner_barrier_and_all_four_overlap(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            m1 = next(
                observation
                for observation in evidence["observations"]
                if observation["mode"] == lane4.MODE_M1X4
            )
            m1["m1_concurrency"]["start_barrier"]["owner"] = "request"
            with self.assertRaisesRegex(lane4.EvidenceError, "owner must be runner"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            m1 = evidence["observations"][0]
            m1["m1_concurrency"]["start_barrier"]["arrival_count"] = 3
            with self.assertRaisesRegex(lane4.EvidenceError, "arrival_count"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            m1 = evidence["observations"][0]
            intervals = m1["m1_concurrency"]["lane_intervals"]
            intervals[0]["end_ns"] = intervals[3]["start_ns"]
            with self.assertRaisesRegex(lane4.EvidenceError, "all-four execution overlap"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_binds_prompt_seeds_options_and_eos_disabled(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"]["workloads_by_terminal_kv_positions"][
                "128"
            ]
            workload["prompt_token_ids_by_lane"][0][0] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "sha256 is not canonical"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"]["workloads_by_terminal_kv_positions"][
                "128"
            ]
            workload["seeds"][0] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "sha256 is not canonical"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"]["workloads_by_terminal_kv_positions"][
                "128"
            ]
            workload["prompt_token_ids_by_lane"][1] = workload[
                "prompt_token_ids_by_lane"
            ][0].copy()
            workload["seeds"][1] = workload["seeds"][0]
            workload["sha256"] = lane4.canonical_workload_sha256(
                {key: value for key, value in workload.items() if key != "sha256"}
            )
            with self.assertRaisesRegex(
                lane4.EvidenceError, "four distinct logical requests"
            ):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"]["workloads_by_terminal_kv_positions"][
                "128"
            ]
            workload["request_options"]["eos_policy"] = "token"
            with self.assertRaisesRegex(lane4.EvidenceError, "must disable EOS"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"]["workloads_by_terminal_kv_positions"][
                "128"
            ]
            workload["execution_options"]["m1_runner_workers"] = 3
            with self.assertRaisesRegex(lane4.EvidenceError, "execution_options"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_rejects_undefined_timing_rss_and_assertion_booleans(self):
        forbidden = {
            "decode_seconds": 1.0,
            "decode_p99_ms": 1.0,
            "peak_rss_bytes": 1024,
            "model_loaded_once": True,
            "resource_claim_released": True,
        }
        with tempfile.TemporaryDirectory() as temporary:
            for field, value in forbidden.items():
                with self.subTest(field=field):
                    evidence = self._raw_evidence(Path(temporary))
                    evidence["observations"][0][field] = value
                    with self.assertRaisesRegex(lane4.EvidenceError, "unknown"):
                        lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["contract"]["same_binary"] = True
            with self.assertRaisesRegex(lane4.EvidenceError, "unknown same_binary"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["artifacts"]["runner"]["verified"] = True
            with self.assertRaisesRegex(lane4.EvidenceError, "unknown verified"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["environment_before"][
                "runner_owned_barrier"
            ] = True
            with self.assertRaisesRegex(
                lane4.EvidenceError, "unknown runner_owned_barrier"
            ):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"][
                "workloads_by_terminal_kv_positions"
            ]["128"]
            workload["request_options"]["max_new_tokens"] = True
            with self.assertRaisesRegex(lane4.EvidenceError, "must be an integer"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            workload = evidence["contract"][
                "workloads_by_terminal_kv_positions"
            ]["128"]
            workload["request_options"]["sampler"][
                "temperature_f32_bits"
            ] = False
            with self.assertRaisesRegex(lane4.EvidenceError, "must be an integer"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            evidence["observations"][0]["rss_evidence"] = {
                "classification": "admissible",
                "method": "ru_maxrss",
                "samples": [1024],
            }
            with self.assertRaisesRegex(lane4.EvidenceError, "non-admissible"):
                lane4.validate_raw_evidence(evidence)

    def test_validator_binds_resource_receipts_limits_and_final_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._raw_evidence(Path(temporary))
            m1 = evidence["observations"][0]["resource_bank_evidence"]
            m1["receipts"].pop()
            with self.assertRaisesRegex(lane4.EvidenceError, "exactly 4"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            b4 = next(
                observation
                for observation in evidence["observations"]
                if observation["mode"] == lane4.MODE_B4
            )["resource_bank_evidence"]
            b4["receipts"][0]["claim"]["queue_slots"] = 3
            with self.assertRaisesRegex(lane4.EvidenceError, "queue_slots must be 4"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            released = evidence["observations"][0]["resource_bank_evidence"][
                "snapshots"
            ]["released"]
            released["used"]["kv_bytes"] = 1
            with self.assertRaisesRegex(lane4.EvidenceError, "claim state is invalid"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            resource = evidence["observations"][0]["resource_bank_evidence"]
            resource["snapshots"]["released"]["releases"] = 3
            with self.assertRaisesRegex(lane4.EvidenceError, "counters are invalid"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            resource = evidence["observations"][0]["resource_bank_evidence"]
            resource["limits"]["host_bytes"] += 1
            with self.assertRaisesRegex(lane4.EvidenceError, "aggregate hard cap"):
                lane4.validate_raw_evidence(evidence)

            evidence = self._raw_evidence(Path(temporary))
            resource = evidence["observations"][0]["resource_bank_evidence"]
            resource["receipts"][1]["generation"] = 1
            with self.assertRaisesRegex(lane4.EvidenceError, "global sequence"):
                lane4.validate_raw_evidence(evidence)


if __name__ == "__main__":
    unittest.main()
