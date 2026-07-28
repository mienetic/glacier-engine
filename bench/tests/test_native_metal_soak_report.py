from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from bench import native_metal_disruption_report as inner
from bench import native_metal_soak_report as soak
from bench import native_workload_campaign as campaign
from bench import lane4_evidence
from bench.tests import test_native_metal_disruption_report as fixture


def _digest(label: bytes) -> bytes:
    return hashlib.sha256(label).digest()


def _environment(captured_at: dt.datetime) -> dict:
    host = {
        "system": "Darwin",
        "release": "25.0.0",
        "machine": "arm64",
        "cpu_brand": "Apple test CPU",
        "logical_cpu_count": 8,
        "boot_session_sha256": _digest(b"boot").hex(),
    }
    canonical_host = json.dumps(
        host,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")
    host["fingerprint_sha256"] = hashlib.sha256(
        canonical_host
    ).hexdigest()
    return {
        "schema": lane4_evidence.ENVIRONMENT_SCHEMA,
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
        "raw_pmset_battery_sha256": _digest(b"battery").hex(),
        "raw_pmset_thermal_sha256": _digest(b"thermal").hex(),
        "raw_foundation_process_info_sha256": _digest(
            b"foundation"
        ).hex(),
        "foundation_probe_source_sha256": (
            lane4_evidence.FOUNDATION_PROBE_SOURCE_SHA256
        ),
        "foundation_probe_runner_sha256": _digest(b"runner").hex(),
        "measurement_admitted": True,
        "reasons": [],
        "claim_scope": "environment-admission-only",
        "performance_claim": "not_evaluated",
        "promotion_decision": "not_evaluated",
        "measurements_publishable": False,
    }


def _wire(
    worker_sha256: bytes,
    metallib_sha256: bytes,
    challenge_sha256: bytes,
    *,
    paced: bool = True,
) -> bytes:
    build_sha256 = inner._native_build_sha256(
        worker_sha256,
        metallib_sha256,
    )

    def mutate(scenario: dict) -> None:
        scenario["identities"][3] = build_sha256
        scenario["identities"][12] = challenge_sha256

    def pace(records: list[dict]) -> None:
        for ordinal, record in enumerate(records):
            epoch = ordinal // soak.RECORDS_PER_EPOCH
            offset = (epoch + 1) * soak.EPOCH_CADENCE_NS
            record["points"] = [
                (timestamp + offset, sequence)
                if sequence != 0
                else (timestamp, sequence)
                for timestamp, sequence in record["points"]
            ]

    return fixture._disruption_fixture(
        scenario_mutator=mutate,
        records_mutator=pace if paced else None,
    )


class NativeMetalSoakReportTests(unittest.TestCase):
    def test_hard_offline_gate_rejects_a_canonical_partial_prefix(
        self,
    ) -> None:
        with (
            mock.patch.object(
                soak,
                "verify_retained_store",
                return_value={"complete": False},
            ) as verify,
            mock.patch.object(soak.sys, "stderr"),
        ):
            result = soak._main(
                [
                    "--worker",
                    "worker",
                    "--metallib",
                    "metallib",
                    "--output-dir",
                    "store",
                    "--verify-store",
                    "--require-complete",
                ]
            )
        self.assertEqual(1, result)
        verify.assert_called_once_with(
            "worker",
            "metallib",
            "store",
            False,
            True,
        )

    def test_internal_offline_gate_labels_ephemeral_store(self) -> None:
        verified = {
            "complete": True,
            "segments": soak.SEGMENT_COUNT,
            "process_generations": 2,
            "records": soak.EXPECTED_TOTAL_RECORDS,
            "completed": soak.EXPECTED_TOTAL_COMPLETED,
            "forced_process_restart": False,
            "forced_process_kills": 0,
            "campaign_id_sha256": _digest(b"campaign"),
            "final_entry_sha256": _digest(b"entry"),
            "output_dir": Path("deleted-store"),
        }
        with (
            mock.patch.object(
                soak,
                "verify_retained_store",
                return_value=verified,
            ),
            mock.patch("builtins.print") as printer,
        ):
            result = soak._main(
                [
                    "--worker",
                    "worker",
                    "--metallib",
                    "metallib",
                    "--output-dir",
                    "store",
                    "--verify-store",
                    "--require-complete",
                    "--ephemeral-output",
                ]
            )
        self.assertEqual(0, result)
        output = printer.call_args.args[0]
        self.assertIn("ephemeral=true", output)
        self.assertNotIn("retained=", output)
        self.assertNotIn("deleted-store", output)

    def test_fixed_campaign_totals_are_exact(self) -> None:
        self.assertEqual(12, soak.SEGMENT_COUNT)
        self.assertEqual(6, soak.SEGMENTS_PER_PROCESS)
        self.assertEqual(5_000_000_000, soak.MINIMUM_SEGMENT_DURATION_NS)
        self.assertEqual(3_000, soak.EXPECTED_TOTAL_RECORDS)
        self.assertEqual(120, soak.EXPECTED_TOTAL_WARMUP_RECORDS)
        self.assertEqual(2_880, soak.EXPECTED_TOTAL_MEASURED_RECORDS)
        self.assertEqual(1_200, soak.EXPECTED_TOTAL_COMPLETED)
        self.assertEqual(600, soak.EXPECTED_TOTAL_CANCELLED)
        self.assertEqual(600, soak.EXPECTED_TOTAL_FAILED)
        self.assertEqual(600, soak.EXPECTED_TOTAL_CAPACITY)
        self.assertEqual(2_400, soak.EXPECTED_TOTAL_PINS)
        self.assertEqual(15_000, soak.EXPECTED_TOTAL_EVENTS)

    def test_schedule_action_binds_campaign_process_and_phase_end(self) -> None:
        schedule = soak._schedule_sha256(_digest(b"supervisor"))
        campaign_id = _digest(b"campaign")
        process_a = _digest(b"process-a")
        process_b = _digest(b"process-b")
        baseline = soak._scheduled_action_sha256(
            campaign_id,
            schedule,
            process_a,
            0,
            1,
        )
        variants = (
            soak._scheduled_action_sha256(
                _digest(b"other-campaign"),
                schedule,
                process_a,
                0,
                1,
            ),
            soak._scheduled_action_sha256(
                campaign_id,
                schedule,
                process_b,
                0,
                1,
            ),
            soak._scheduled_action_sha256(
                campaign_id,
                schedule,
                process_a,
                1,
                1,
            ),
            soak._scheduled_action_sha256(
                campaign_id,
                schedule,
                process_a,
                soak.RESTART_AFTER_SEGMENT - 1,
                1,
            ),
        )
        self.assertTrue(all(value != baseline for value in variants))
        self.assertEqual(len(set((baseline, *variants))), 5)

    def test_forced_process_restart_has_a_distinct_sealed_schedule(self) -> None:
        supervisor = _digest(b"supervisor")
        graceful = soak._schedule_sha256(supervisor)
        forced = soak._schedule_sha256(supervisor, True)
        self.assertNotEqual(graceful, forced)

        campaign_id = _digest(b"campaign")
        process_source = _digest(b"process")
        ordinal = soak.RESTART_AFTER_SEGMENT - 1
        self.assertNotEqual(
            soak._scheduled_action_sha256(
                campaign_id,
                graceful,
                process_source,
                ordinal,
                1,
            ),
            soak._scheduled_action_sha256(
                campaign_id,
                forced,
                process_source,
                ordinal,
                1,
                True,
            ),
        )

    def test_forced_process_restart_entry_binds_exact_sigkill(self) -> None:
        worker = _digest(b"forced-worker")
        metallib = _digest(b"forced-metallib")
        schedule = soak._schedule_sha256(
            _digest(b"forced-supervisor"),
            True,
        )
        process_source = _digest(b"forced-process")
        initial = soak._initial_plan(
            _digest(b"forced-authority"),
            worker,
            metallib,
            schedule,
            True,
        )
        campaign_id = campaign.derive_campaign_id(initial)

        first_action = soak._scheduled_action_sha256(
            campaign_id,
            schedule,
            process_source,
            0,
            1,
            True,
        )
        first_challenge = campaign.derive_segment_challenge(
            campaign_id,
            0,
            1,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            first_action,
        )
        first_wire = _wire(worker, metallib, first_challenge)
        plan = soak._seal_plan_from_first_report(
            initial,
            inner._decode_after_portable_verification(first_wire),
        )

        ordinal = soak.RESTART_AFTER_SEGMENT - 1
        previous_entry = _digest(b"forced-previous-entry")
        previous_report = _digest(b"forced-previous-report")
        action = soak._scheduled_action_sha256(
            campaign_id,
            schedule,
            process_source,
            ordinal,
            1,
            True,
        )
        challenge = campaign.derive_segment_challenge(
            campaign_id,
            ordinal,
            1,
            previous_entry,
            previous_report,
            action,
        )
        wire = _wire(worker, metallib, challenge)
        verified = inner.verify_native_wire(
            wire,
            worker,
            metallib,
            challenge,
        )
        decoded = inner._decode_after_portable_verification(wire)
        duration = soak.MINIMUM_SEGMENT_DURATION_NS + 1
        value = soak._entry_value(
            plan,
            decoded,
            verified,
            ordinal,
            previous_entry,
            previous_report,
            action,
            duration,
            duration * (ordinal + 1),
            (16 << 20, 17 << 20, 16 << 20, 100),
            process_source,
            True,
        )
        entry = campaign.make_entry(plan, value)
        self.assertEqual(
            campaign.PLAN_FLAG_FORCED_PROCESS_RESTART,
            plan["flags"],
        )
        self.assertEqual(
            campaign.PROVENANCE_FORCED_OS_PROCESS_KILL,
            entry["provenance_bits"]
            & campaign.PROVENANCE_FORCED_OS_PROCESS_KILL,
        )
        self.assertEqual(
            campaign.U64_MAX,
            entry["exit_code_bits"],
        )
        self.assertEqual(
            campaign.TERMINATION_SIGNAL_KILL,
            entry["termination_signal"],
        )

    def test_environment_root_binds_generation_and_post_boundary(self) -> None:
        campaign_id = _digest(b"campaign")
        before = _digest(b"before")
        post = _digest(b"post")
        partial = soak.environment_sha256(campaign_id, 1, before)
        self.assertNotEqual(
            partial,
            soak.environment_sha256(campaign_id, 2, before),
        )
        self.assertNotEqual(
            partial,
            soak.environment_sha256(campaign_id, 1, before, post),
        )

    def test_first_challenge_needs_no_unretained_native_preflight(self) -> None:
        worker = _digest(b"worker")
        metallib = _digest(b"metallib")
        plan = soak._initial_plan(
            _digest(b"authority"),
            worker,
            metallib,
            soak._schedule_sha256(_digest(b"supervisor")),
        )
        baseline = campaign.derive_campaign_id(plan)
        for field in (
            "machine_sha256",
            "backend_sha256",
            "device_sha256",
            "placement_sha256",
        ):
            mutated = dict(plan)
            mutated[field] = _digest(field.encode("ascii"))
            self.assertEqual(
                baseline,
                campaign.derive_campaign_id(mutated),
                field,
            )
        mutated = dict(plan)
        mutated["epoch_cadence_ns"] += 1
        self.assertNotEqual(
            baseline,
            campaign.derive_campaign_id(mutated),
        )

    def test_segment_cadence_is_proven_from_inner_host_timestamps(
        self,
    ) -> None:
        wire = _wire(
            _digest(b"paced-worker"),
            _digest(b"paced-metallib"),
            _digest(b"paced-challenge"),
            paced=False,
        )
        decoded = inner._decode_after_portable_verification(wire)
        with self.assertRaisesRegex(
            soak.NativeMetalSoakError,
            "cadence target",
        ):
            soak._assert_segment_cadence(decoded)

    def test_partial_checkpoint_reopens_and_reverifies_inner_wire(self) -> None:
        worker = _digest(b"worker-component")
        metallib = _digest(b"metallib-component")
        schedule = soak._schedule_sha256(_digest(b"supervisor-component"))
        environment_snapshot = _environment(
            dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        )
        process_source = _digest(b"worker-process-one")
        initial = soak._initial_plan(
            _digest(b"authority-challenge"),
            worker,
            metallib,
            schedule,
        )
        campaign_id = campaign.derive_campaign_id(initial)
        scheduled_action = soak._scheduled_action_sha256(
            campaign_id,
            schedule,
            process_source,
            0,
            1,
        )
        challenge = campaign.derive_segment_challenge(
            campaign_id,
            0,
            1,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            scheduled_action,
        )
        wire = _wire(worker, metallib, challenge)
        verified = inner.verify_native_wire(
            wire,
            worker,
            metallib,
            challenge,
        )
        decoded = inner._decode_after_portable_verification(wire)
        plan = soak._seal_plan_from_first_report(initial, decoded)
        duration = soak.MINIMUM_SEGMENT_DURATION_NS + 1
        value = soak._entry_value(
            plan,
            decoded,
            verified,
            0,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            scheduled_action,
            duration,
            duration,
            (16 << 20, 17 << 20, 16 << 20, 100),
            process_source,
            False,
        )
        entry = campaign.make_entry(plan, value)

        with tempfile.TemporaryDirectory() as directory:
            store = soak.CampaignStore(directory)
            try:
                environment_before = store.write_environment(
                    environment_snapshot
                )
                environment_root = soak.environment_sha256(
                    campaign_id,
                    1,
                    environment_before,
                )
                self.assertEqual(
                    verified.wire_sha256,
                    store.write_segment(wire),
                )
                manifest_wire, selector_wire = store.publish(
                    plan,
                    [entry],
                    environment_root,
                )
                manifest = campaign.verify_manifest(manifest_wire)
                selector = campaign.verify_selector(
                    manifest_wire,
                    selector_wire,
                    environment_root,
                )
                self.assertEqual(1, len(manifest["entries"]))
                self.assertEqual(1, selector["generation"])
                self.assertEqual(
                    soak.SEGMENT_COUNT,
                    selector["segment_count"],
                )
                reopened, _ = store.recover(
                    plan,
                    1,
                    environment_root,
                    worker,
                    metallib,
                )
                self.assertEqual(entry, reopened["entries"][0])
                (
                    Path(directory)
                    / "environments"
                    / (environment_before.hex() + ".json")
                ).unlink()
                with self.assertRaisesRegex(
                    soak.NativeMetalSoakError,
                    "environment-object count",
                ):
                    store.recover(
                        plan,
                        1,
                        environment_root,
                        worker,
                        metallib,
                    )
                self.assertTrue(
                    (
                        Path(directory)
                        / soak.ACTIVE_SELECTOR_NAME
                    ).is_file()
                )
            finally:
                store.close()

    def test_recover_rejects_outer_facts_forged_away_from_inner_wire(
        self,
    ) -> None:
        worker = _digest(b"binding-worker")
        metallib = _digest(b"binding-metallib")
        schedule = soak._schedule_sha256(_digest(b"binding-supervisor"))
        process_source = _digest(b"binding-process")
        initial = soak._initial_plan(
            _digest(b"binding-authority"),
            worker,
            metallib,
            schedule,
        )
        campaign_id = campaign.derive_campaign_id(initial)
        action = soak._scheduled_action_sha256(
            campaign_id,
            schedule,
            process_source,
            0,
            1,
        )
        challenge = campaign.derive_segment_challenge(
            campaign_id,
            0,
            1,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            action,
        )
        wire = _wire(worker, metallib, challenge)
        verified = inner.verify_native_wire(
            wire,
            worker,
            metallib,
            challenge,
        )
        decoded = inner._decode_after_portable_verification(wire)
        plan = soak._seal_plan_from_first_report(initial, decoded)
        value = soak._entry_value(
            plan,
            decoded,
            verified,
            0,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            action,
            soak.MINIMUM_SEGMENT_DURATION_NS + 1,
            soak.MINIMUM_SEGMENT_DURATION_NS + 1,
            (16 << 20, 17 << 20, 16 << 20, 100),
            process_source,
            False,
        )
        value["closure_sha256"] = _digest(b"forged-closure")
        value["device_allocation_before_bytes"] = 1
        value["device_allocation_max_bytes"] = 1
        value["device_allocation_after_bytes"] = 1
        entry = campaign.make_entry(plan, value)
        environment_snapshot = _environment(
            dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        )

        with tempfile.TemporaryDirectory() as directory:
            store = soak.CampaignStore(directory)
            try:
                environment_before = store.write_environment(
                    environment_snapshot
                )
                environment_root = soak.environment_sha256(
                    campaign_id,
                    1,
                    environment_before,
                )
                store.write_segment(wire)
                store.publish(plan, [entry], environment_root)
                with self.assertRaisesRegex(
                    soak.NativeMetalSoakError,
                    "retained inner wire disagrees",
                ):
                    store.recover(
                        plan,
                        1,
                        environment_root,
                        worker,
                        metallib,
                    )
            finally:
                store.close()

    def test_failed_postpublication_bound_check_restores_selector(
        self,
    ) -> None:
        worker = _digest(b"rollback-worker")
        metallib = _digest(b"rollback-metallib")
        schedule = soak._schedule_sha256(_digest(b"rollback-supervisor"))
        process_source = _digest(b"rollback-process")
        initial = soak._initial_plan(
            _digest(b"rollback-authority"),
            worker,
            metallib,
            schedule,
        )
        campaign_id = campaign.derive_campaign_id(initial)
        action = soak._scheduled_action_sha256(
            campaign_id,
            schedule,
            process_source,
            0,
            1,
        )
        challenge = campaign.derive_segment_challenge(
            campaign_id,
            0,
            1,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            action,
        )
        wire = _wire(worker, metallib, challenge)
        verified = inner.verify_native_wire(
            wire,
            worker,
            metallib,
            challenge,
        )
        decoded = inner._decode_after_portable_verification(wire)
        plan = soak._seal_plan_from_first_report(initial, decoded)
        value = soak._entry_value(
            plan,
            decoded,
            verified,
            0,
            campaign.ZERO_DIGEST,
            campaign.ZERO_DIGEST,
            action,
            soak.MINIMUM_SEGMENT_DURATION_NS + 1,
            soak.MINIMUM_SEGMENT_DURATION_NS + 1,
            (16 << 20, 17 << 20, 16 << 20, 100),
            process_source,
            False,
        )
        entry = campaign.make_entry(plan, value)
        forged_value = dict(entry)
        forged_value["closure_sha256"] = _digest(b"rollback-forgery")
        forged_value["entry_sha256"] = campaign.ZERO_DIGEST
        forged_entry = campaign.make_entry(plan, forged_value)

        with tempfile.TemporaryDirectory() as directory:
            store = soak.CampaignStore(directory)
            try:
                before_environment = store.write_environment(
                    _environment(
                        dt.datetime(
                            2026,
                            1,
                            1,
                            tzinfo=dt.timezone.utc,
                        )
                    )
                )
                environment_root = soak.environment_sha256(
                    campaign_id,
                    1,
                    before_environment,
                )
                store.write_segment(wire)
                store.publish(plan, [entry], environment_root)
                active = Path(directory) / soak.ACTIVE_SELECTOR_NAME
                previous_selector = active.read_bytes()
                with mock.patch.object(
                    store,
                    "_enforce_bound",
                    side_effect=soak.NativeMetalSoakError(
                        "injected postpublication bound failure"
                    ),
                ):
                    with self.assertRaisesRegex(
                        soak.NativeMetalSoakError,
                        "injected",
                    ):
                        store.publish(
                            plan,
                            [forged_entry],
                            environment_root,
                        )
                self.assertEqual(previous_selector, active.read_bytes())
            finally:
                store.close()

    def test_full_two_process_retained_store_verifies_every_prefix(
        self,
    ) -> None:
        for forced_process_restart in (False, True):
            with self.subTest(
                forced_process_restart=forced_process_restart,
            ):
                self._assert_full_two_process_retained_store(
                    forced_process_restart
                )

    def _assert_full_two_process_retained_store(
        self,
        forced_process_restart: bool,
    ) -> None:
        worker_contents = b"synthetic native Metal soak worker\n"
        metallib_contents = b"synthetic native Metal shader library\n"
        before_snapshot = _environment(
            dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        )
        after_snapshot = _environment(
            dt.datetime(2026, 1, 1, 0, 10, tzinfo=dt.timezone.utc)
        )
        process_sources = (
            _digest(b"synthetic-process-generation-one"),
            _digest(b"synthetic-process-generation-two"),
        )

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            worker_path = base / "worker"
            metallib_path = base / "workload.metallib"
            output = base / "retained-store"
            worker_path.write_bytes(worker_contents)
            metallib_path.write_bytes(metallib_contents)
            worker_sha256 = hashlib.sha256(worker_contents).digest()
            metallib_sha256 = hashlib.sha256(metallib_contents).digest()
            schedule = soak._schedule_sha256(
                _digest(b"synthetic-supervisor"),
                forced_process_restart,
            )
            initial = soak._initial_plan(
                _digest(b"synthetic-authority-challenge"),
                worker_sha256,
                metallib_sha256,
                schedule,
                forced_process_restart,
            )
            campaign_id = campaign.derive_campaign_id(initial)
            previous_entry = campaign.ZERO_DIGEST
            previous_report = campaign.ZERO_DIGEST
            cumulative_duration = 0
            entries: list[dict] = []
            published_generations: list[int] = []
            plan = None
            after_environment = campaign.ZERO_DIGEST

            store = soak.CampaignStore(output)
            try:
                before_environment = store.write_environment(
                    before_snapshot
                )
                for ordinal in range(soak.SEGMENT_COUNT):
                    generation = soak._process_generation(ordinal)
                    process_source = process_sources[generation - 1]
                    scheduled_action = soak._scheduled_action_sha256(
                        campaign_id,
                        schedule,
                        process_source,
                        ordinal,
                        generation,
                        forced_process_restart,
                    )
                    challenge = campaign.derive_segment_challenge(
                        campaign_id,
                        ordinal,
                        generation,
                        previous_entry,
                        previous_report,
                        scheduled_action,
                    )
                    wire = _wire(
                        worker_sha256,
                        metallib_sha256,
                        challenge,
                    )
                    verified = inner.verify_native_wire(
                        wire,
                        worker_sha256,
                        metallib_sha256,
                        challenge,
                    )
                    decoded = inner._decode_after_portable_verification(
                        wire
                    )
                    if plan is None:
                        plan = soak._seal_plan_from_first_report(
                            initial,
                            decoded,
                        )
                    self.assertEqual(
                        verified.wire_sha256,
                        store.write_segment(wire),
                    )
                    duration = soak.MINIMUM_SEGMENT_DURATION_NS + 1
                    cumulative_duration += duration
                    rss_base = (16 + (generation - 1) * 4) << 20
                    value = soak._entry_value(
                        plan,
                        decoded,
                        verified,
                        ordinal,
                        previous_entry,
                        previous_report,
                        scheduled_action,
                        duration,
                        cumulative_duration,
                        (
                            rss_base,
                            rss_base + (1 << 20),
                            rss_base + (1 << 19),
                            100,
                        ),
                        process_source,
                        soak._is_phase_terminal(ordinal),
                    )
                    entry = campaign.make_entry(plan, value)
                    entries.append(entry)
                    previous_entry = entry["entry_sha256"]
                    previous_report = entry[
                        "verified_report_sha256"
                    ]

                    if ordinal == soak.SEGMENT_COUNT - 1:
                        after_environment = store.write_environment(
                            after_snapshot
                        )
                    environment_root = soak.environment_sha256(
                        campaign_id,
                        len(entries),
                        before_environment,
                        after_environment,
                    )
                    _manifest_wire, selector_wire = store.publish(
                        plan,
                        entries,
                        environment_root,
                    )
                    published_generations.append(
                        campaign.decode_selector(selector_wire)[
                            "generation"
                        ]
                    )
            finally:
                store.close()

            self.assertEqual(
                list(range(1, soak.SEGMENT_COUNT + 1)),
                published_generations,
            )
            result = soak.verify_retained_store(
                worker_path,
                metallib_path,
                output,
                forced_process_restart,
                True,
            )
            self.assertTrue(result["complete"])
            self.assertEqual(
                forced_process_restart,
                result["forced_process_restart"],
            )
            self.assertEqual(
                1 if forced_process_restart else 0,
                result["forced_process_kills"],
            )
            self.assertEqual(soak.SEGMENT_COUNT, result["segments"])
            self.assertEqual(2, result["process_generations"])
            self.assertEqual(
                soak.EXPECTED_TOTAL_RECORDS,
                result["records"],
            )
            self.assertEqual(
                entries[-1]["entry_sha256"],
                result["final_entry_sha256"],
            )

            (
                output
                / "environments"
                / (after_environment.hex() + ".json")
            ).unlink()
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "environment",
            ):
                soak.verify_retained_store(
                    worker_path,
                    metallib_path,
                    output,
                )

    def test_store_rejects_symlinked_object_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            target = Path(directory) / "outside"
            root.mkdir()
            target.mkdir()
            os.symlink(target, root / "segments")
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "object directory",
            ):
                soak.CampaignStore(root)

    def test_store_rejects_preexisting_active_selector_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.symlink(
                root / "missing-selector-target",
                root / soak.ACTIVE_SELECTOR_NAME,
            )
            with self.assertRaisesRegex(
                soak.NativeMetalSoakError,
                "active selector",
            ):
                soak.CampaignStore(root)


if __name__ == "__main__":
    unittest.main()
