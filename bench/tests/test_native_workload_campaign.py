from __future__ import annotations

import hashlib
import unittest

from bench import native_workload_campaign as campaign


MIB = 1024 * 1024
SEGMENTS = 12
RESTART_AFTER = 6
REPORT_BYTES = 195_556


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _plan_fields(
    *,
    segment_count: int = SEGMENTS,
    restart_after: int = RESTART_AFTER,
    rss_growth_bound: int = 64 * MIB,
    device_growth_bound: int = 64 * MIB,
    flags: int = campaign.ALLOWED_FLAGS,
) -> dict[str, object]:
    epochs = 50
    records_per_epoch = 5
    warmup_epochs = 2
    measured_epochs = 48
    result: dict[str, object] = {
        "abi_version": campaign.MANIFEST_ABI,
        "encoded_bytes": campaign.encoded_manifest_bytes(segment_count),
        "flags": flags,
        "segment_count": segment_count,
        "restart_after_segment": restart_after,
        "epochs_per_segment": epochs,
        "records_per_epoch": records_per_epoch,
        "warmup_epochs_per_segment": warmup_epochs,
        "measured_epochs_per_segment": measured_epochs,
        "completed_per_epoch": 2,
        "cancelled_per_epoch": 1,
        "failed_per_epoch": 1,
        "capacity_rejected_per_epoch": 1,
        "pins_per_epoch": 4,
        "events_per_epoch": 25,
        "epoch_cadence_ns": 100_000_000,
        "minimum_segment_duration_ns": 5_000_000_000,
        "maximum_segment_duration_ns": 15_000_000_000,
        "report_wire_bytes": REPORT_BYTES,
        "artifact_store_max_bytes": 8 * MIB,
        "rss_growth_bound_bytes": rss_growth_bound,
        "total_epochs": segment_count * epochs,
        "total_records": segment_count * epochs * records_per_epoch,
        "total_warmup_records": (
            segment_count * warmup_epochs * records_per_epoch
        ),
        "total_measured_records": (
            segment_count * measured_epochs * records_per_epoch
        ),
        "total_completed": segment_count * epochs * 2,
        "total_cancelled": segment_count * epochs,
        "total_failed": segment_count * epochs,
        "total_capacity_rejected": segment_count * epochs,
        "total_pin_acquisitions": segment_count * epochs * 4,
        "device_allocation_growth_bound_bytes": device_growth_bound,
        "total_events": segment_count * epochs * 25,
        "campaign_challenge_sha256": _digest("authority"),
        "workload_sha256": _digest("workload"),
        "schedule_sha256": _digest("schedule"),
        "artifact_sha256": _digest("artifact"),
        "build_sha256": _digest("build"),
        "runner_sha256": _digest("runner"),
        "backend_library_sha256": _digest("metallib"),
        "machine_sha256": _digest("machine"),
        "backend_sha256": _digest("backend"),
        "device_sha256": _digest("device"),
        "placement_sha256": _digest("placement"),
        "campaign_id_sha256": campaign.ZERO_DIGEST,
    }
    return result


def _plan(**kwargs: object) -> dict[str, object]:
    return campaign.seal_plan(_plan_fields(**kwargs))


def _entries(
    plan: dict[str, object],
    *,
    rss_step_bytes: int = 256 * 1024,
    device_step_bytes: int = 128 * 1024,
    rss_availability: int = campaign.AVAILABILITY_PRESENT,
    device_availability: int = campaign.AVAILABILITY_PRESENT,
    distinct_process_sources: bool = True,
    change_source_within_phase: bool = False,
) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    previous_entry = campaign.ZERO_DIGEST
    previous_report = campaign.ZERO_DIGEST
    cumulative_duration = 0
    segment_count = int(plan["segment_count"])
    restart_after = int(plan["restart_after_segment"])
    for ordinal in range(segment_count):
        generation = 1 if restart_after == 0 or ordinal < restart_after else 2
        phase_ordinal = (
            ordinal
            if generation == 1
            else ordinal - restart_after
        )
        rss_source_generation = (
            generation if distinct_process_sources else 1
        )
        if change_source_within_phase and ordinal == 2:
            rss_source_generation = 99
        rss_source = _digest("rss-source-%d" % rss_source_generation)
        rss_baseline = (100 + generation * 20) * MIB
        rss_before = rss_baseline + phase_ordinal * rss_step_bytes
        rss_max = rss_before + 128 * 1024
        rss_after = rss_before + 64 * 1024
        if rss_availability != campaign.AVAILABILITY_PRESENT:
            rss_before = rss_max = rss_after = 0

        device_baseline = (40 + generation * 4) * MIB
        device_before = (
            device_baseline + phase_ordinal * device_step_bytes
        )
        device_max = device_before + 64 * 1024
        device_after = device_before + 32 * 1024
        if device_availability != campaign.AVAILABILITY_PRESENT:
            device_before = device_max = device_after = 0

        duration = 5_000_000_000 + ordinal * 1_000_000
        cumulative_duration += duration
        restart_boundary = (
            restart_after != 0 and ordinal + 1 == restart_after
        )
        forced_restart = bool(
            restart_boundary
            and int(plan["flags"])
            & campaign.PLAN_FLAG_FORCED_PROCESS_RESTART
        )
        phase_terminal = restart_boundary or ordinal + 1 == segment_count
        provenance = campaign.BASE_PROVENANCE_BITS
        if forced_restart:
            provenance |= campaign.PROVENANCE_FORCED_OS_PROCESS_KILL
        elif restart_boundary:
            provenance |= campaign.PROVENANCE_PLANNED_GRACEFUL_RESTART
        action_tag = (
            campaign.ACTION_FORCED_PHASE_END
            if forced_restart
            else campaign.ACTION_GRACEFUL_PHASE_END
            if phase_terminal
            else campaign.ACTION_NORMAL
        )
        exit_code_bits = (
            campaign.U64_MAX
            if forced_restart or not phase_terminal
            else 0
        )
        termination_signal = (
            campaign.TERMINATION_SIGNAL_KILL
            if forced_restart
            else 0
        )
        scheduled_action = campaign.derive_scheduled_action(
            plan["campaign_id_sha256"],
            plan["schedule_sha256"],
            ordinal,
            generation,
            action_tag,
            rss_source,
        )
        segment_challenge = campaign.derive_segment_challenge(
            plan["campaign_id_sha256"],
            ordinal,
            generation,
            previous_entry,
            previous_report,
            scheduled_action,
        )
        rss_reason = (
            campaign.ZERO_DIGEST
            if rss_availability == campaign.AVAILABILITY_PRESENT
            else campaign.derive_metric_unavailable_reason(
                plan["campaign_id_sha256"],
                ordinal,
                rss_availability,
                rss_source,
            )
        )
        device_source = _digest("device-allocation-source")
        device_reason = (
            campaign.ZERO_DIGEST
            if device_availability == campaign.AVAILABILITY_PRESENT
            else campaign.derive_device_allocation_unavailable_reason(
                plan["campaign_id_sha256"],
                ordinal,
                device_availability,
                device_source,
            )
        )
        value: dict[str, object] = {
            "abi_version": campaign.ATTEMPT_ABI,
            "ordinal": ordinal,
            "process_generation": generation,
            "disposition": campaign.DISPOSITION_COMPLETE,
            "provenance_bits": provenance,
            "epoch_count": 50,
            "record_count": 250,
            "warmup_record_count": 10,
            "measured_record_count": 240,
            "completed_count": 100,
            "cancelled_count": 50,
            "failed_count": 50,
            "capacity_rejected_count": 50,
            "pin_acquisitions": 200,
            "pin_completions": 200,
            "event_count": 1_250,
            "report_wire_bytes": REPORT_BYTES,
            "duration_ns": duration,
            "cumulative_duration_ns": cumulative_duration,
            "cumulative_records": (ordinal + 1) * 250,
            "cumulative_completed": (ordinal + 1) * 100,
            "rss_availability": rss_availability,
            "rss_before_bytes": rss_before,
            "rss_max_bytes": rss_max,
            "rss_after_bytes": rss_after,
            "device_allocation_availability": device_availability,
            "device_allocation_before_bytes": device_before,
            "device_allocation_max_bytes": device_max,
            "device_allocation_after_bytes": device_after,
            "exit_code_bits": exit_code_bits,
            "termination_signal": termination_signal,
            "reserved": 0,
            "scheduled_action_sha256": scheduled_action,
            "segment_challenge_sha256": segment_challenge,
            "previous_entry_sha256": previous_entry,
            "previous_verified_report_sha256": previous_report,
            "report_wire_sha256": _digest("wire-%d" % ordinal),
            "verified_report_sha256": _digest("report-%d" % ordinal),
            "scenario_sha256": _digest("scenario-%d" % ordinal),
            "closure_sha256": _digest("closure"),
            "build_sha256": plan["build_sha256"],
            "machine_sha256": plan["machine_sha256"],
            "backend_sha256": plan["backend_sha256"],
            "device_sha256": plan["device_sha256"],
            "placement_sha256": plan["placement_sha256"],
            "host_source_sha256": _digest("host-source"),
            "host_clock_sha256": _digest("host-clock"),
            "rss_source_sha256": rss_source,
            "rss_unavailable_reason_sha256": rss_reason,
            "device_allocation_source_sha256": device_source,
            "device_allocation_unavailable_reason_sha256": (
                device_reason
            ),
            "entry_sha256": campaign.ZERO_DIGEST,
        }
        entry = campaign.make_entry(plan, value)
        result.append(entry)
        previous_entry = entry["entry_sha256"]
        previous_report = entry["verified_report_sha256"]
    return result


def _raw_manifest(
    plan: dict[str, object],
    entries: list[dict[str, object]],
) -> bytes:
    header = campaign._encode_fields(  # type: ignore[attr-defined]
        plan,
        campaign.PLAN_SCALAR_FIELDS,
        campaign.PLAN_DIGEST_FIELDS,
    )
    body = header + b"".join(
        campaign._encode_fields(  # type: ignore[attr-defined]
            entry,
            campaign.ATTEMPT_SCALAR_FIELDS,
            campaign.ATTEMPT_DIGEST_FIELDS,
        )
        for entry in entries
    )
    body += bytes(
        (int(plan["segment_count"]) - len(entries))
        * campaign.ATTEMPT_BYTES
    )
    body_root, footer_root = campaign._manifest_roots(  # type: ignore[attr-defined]
        body
    )
    return body + body_root + footer_root


def _reseal_entry(
    plan: dict[str, object],
    entry: dict[str, object],
) -> dict[str, object]:
    result = dict(entry)
    result["entry_sha256"] = campaign.ZERO_DIGEST
    result["entry_sha256"] = campaign.entry_root(
        plan["campaign_id_sha256"],  # type: ignore[arg-type]
        result,
    )
    return result


def _reseal_selector(value: dict[str, object]) -> bytes:
    result = dict(value)
    result["selector_sha256"] = campaign.ZERO_DIGEST
    body = campaign._encode_fields(  # type: ignore[attr-defined]
        result,
        campaign.SELECTOR_SCALAR_FIELDS,
        campaign.SELECTOR_DIGEST_FIELDS[:-1],
    )
    result["selector_sha256"] = hashlib.sha256(
        campaign.SELECTOR_DOMAIN + body
    ).digest()
    return campaign._encode_fields(  # type: ignore[attr-defined]
        result,
        campaign.SELECTOR_SCALAR_FIELDS,
        campaign.SELECTOR_DIGEST_FIELDS,
    )


class NativeWorkloadCampaignTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = _plan()
        cls.entries = _entries(cls.plan)
        cls.manifest = campaign.make_manifest(cls.plan, cls.entries)
        cls.decoded = campaign.decode_manifest(cls.manifest)
        cls.before_environment = _digest("environment-before")
        cls.after_environment = _digest("environment-after")
        cls.environment = campaign.derive_environment_sha256(
            cls.plan["campaign_id_sha256"],
            SEGMENTS,
            cls.before_environment,
            cls.after_environment,
        )
        cls.selector = campaign.make_selector(
            cls.decoded,
            cls.environment,
        )

    def test_fixed_dimensions_roundtrip_and_roots(self) -> None:
        self.assertEqual(campaign.MANIFEST_HEADER_BYTES, 640)
        self.assertEqual(campaign.ATTEMPT_BYTES, 896)
        self.assertEqual(campaign.MANIFEST_FOOTER_BYTES, 64)
        self.assertEqual(campaign.SELECTOR_BYTES, 192)
        self.assertEqual(
            len(self.manifest),
            640 + SEGMENTS * 896 + 64,
        )
        self.assertEqual(self.decoded["completed_segment_count"], SEGMENTS)
        self.assertEqual(
            campaign.encode_manifest(self.decoded),
            self.manifest,
        )
        self.assertEqual(
            self.plan["campaign_id_sha256"].hex(),
            "5105081b9bf8388df21c66b48f8184c3912fba42ff5bb75f660e4b4c01584dbe",
        )
        self.assertEqual(
            self.entries[0]["entry_sha256"].hex(),
            "b66833a889da51e892a65939299d2c23df00ad4737c6508da4c8b725b19204f0",
        )
        self.assertEqual(
            self.decoded["body_sha256"].hex(),
            "226dd248e1effcbc2abecbd44df0243035b5fec3cd552a950f0c6fa9946afeb6",
        )
        self.assertEqual(
            self.decoded["manifest_sha256"].hex(),
            "447cf61a1035e88557fda9591d60fa2e5e55ed55ed9258aa3d1ec0e2823a92eb",
        )
        self.assertEqual(
            hashlib.sha256(self.manifest).hexdigest(),
            "135b6fa000e02b870bdebba8da1c3e95b254861ddd733b3f8b85d35069ef46fc",
        )
        selector = campaign.verify_selector(
            self.manifest,
            self.selector,
            self.environment,
        )
        self.assertEqual(selector["generation"], SEGMENTS)
        self.assertEqual(selector["total_records"], 3_000)
        self.assertEqual(selector["total_completed"], 1_200)
        self.assertEqual(selector["total_events"], 15_000)
        self.assertEqual(
            selector["selector_sha256"].hex(),
            "d3ca4b9cb32eec8060315547cb1256e73555d77cfa4828248c42fe6d94381ce2",
        )

    def test_forced_restart_roundtrip_and_cross_language_roots(self) -> None:
        plan = _plan(
            flags=campaign.PLAN_FLAG_FORCED_PROCESS_RESTART,
        )
        entries = _entries(plan)
        manifest = campaign.make_manifest(plan, entries)
        decoded = campaign.decode_manifest(manifest)
        self.assertEqual(campaign.encode_manifest(decoded), manifest)
        self.assertNotEqual(
            plan["campaign_id_sha256"],
            self.plan["campaign_id_sha256"],
        )
        self.assertEqual(
            plan["campaign_id_sha256"].hex(),
            "520b63429b034796f8f4db3ea748bc636d45a7290feff24815c52f010621f977",
        )

        boundary = entries[RESTART_AFTER - 1]
        self.assertEqual(
            boundary["provenance_bits"],
            campaign.BASE_PROVENANCE_BITS
            | campaign.PROVENANCE_FORCED_OS_PROCESS_KILL,
        )
        self.assertEqual(boundary["exit_code_bits"], campaign.U64_MAX)
        self.assertEqual(
            boundary["termination_signal"],
            campaign.TERMINATION_SIGNAL_KILL,
        )
        self.assertEqual(
            boundary["scheduled_action_sha256"].hex(),
            "3b60f035a18e77896ec8f9289eebb5aa6b14a93065abb6a0f15be799a675972c",
        )
        self.assertEqual(
            boundary["segment_challenge_sha256"].hex(),
            "12f868af28158496519d94f1529da4f2a6442f873e7ea2ae597c130ed5542f76",
        )
        self.assertEqual(
            boundary["entry_sha256"].hex(),
            "0ef594636c22dbce6c5c92347f4b86490c92718e7e9cadec0302083e4ae5d372",
        )

        final = entries[-1]
        self.assertEqual(
            final["provenance_bits"],
            campaign.BASE_PROVENANCE_BITS,
        )
        self.assertEqual(final["exit_code_bits"], 0)
        self.assertEqual(final["termination_signal"], 0)
        self.assertEqual(
            final["scheduled_action_sha256"].hex(),
            "b691620f4ba54632eaaa088f87442da8f4cb1c8f38c492a25d13356a89fdc0eb",
        )
        self.assertEqual(
            final["entry_sha256"].hex(),
            "a57a516bd3dd9c871986347be82d7ef86051aac9dbe301fe83e44ec24097584c",
        )
        self.assertEqual(
            decoded["body_sha256"].hex(),
            "859cd33a83f35b56b3e6d805b83405a42396b405aea8a6c030955ec2a18ca6df",
        )
        self.assertEqual(
            decoded["manifest_sha256"].hex(),
            "2846478ac665ca2c35b32721bf0c0a6f40bd29b2e81e812f05ac39e6cb559bf8",
        )
        self.assertEqual(
            hashlib.sha256(manifest).hexdigest(),
            "83beb4589cba2c4c3cd94bd9f6d77b3628af5d8935bc5645bbb727df8a897d7d",
        )

        environment = campaign.derive_environment_sha256(
            plan["campaign_id_sha256"],
            SEGMENTS,
            self.before_environment,
            self.after_environment,
        )
        selector_wire = campaign.make_selector(decoded, environment)
        selector = campaign.verify_selector(
            manifest,
            selector_wire,
            environment,
        )
        self.assertEqual(selector["flags"], campaign.ALLOWED_SELECTOR_FLAGS)
        self.assertEqual(
            selector["selector_sha256"].hex(),
            "eecb769e8b704e12aabf9a413e288e80918e6777a8f11290579f6eaa98695ee2",
        )

    def test_forced_restart_rejects_invalid_flags_and_control_drift(self) -> None:
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "invalid manifest flags",
        ):
            _plan(flags=1 << 1)
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "requires a restart boundary",
        ):
            _plan(
                flags=campaign.PLAN_FLAG_FORCED_PROCESS_RESTART,
                restart_after=0,
            )

        plan = _plan(
            flags=campaign.PLAN_FLAG_FORCED_PROCESS_RESTART,
        )
        canonical_entries = _entries(plan)
        boundary_ordinal = RESTART_AFTER - 1
        mutations = (
            ("exit_code_bits", 0),
            ("termination_signal", 0),
            (
                "provenance_bits",
                campaign.BASE_PROVENANCE_BITS
                | campaign.PROVENANCE_PLANNED_GRACEFUL_RESTART,
            ),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                entries = [dict(entry) for entry in canonical_entries]
                entries[boundary_ordinal][field] = value
                entries[boundary_ordinal] = _reseal_entry(
                    plan,
                    entries[boundary_ordinal],
                )
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.decode_manifest(_raw_manifest(plan, entries))

        entries = [dict(entry) for entry in canonical_entries]
        boundary = entries[boundary_ordinal]
        boundary["scheduled_action_sha256"] = (
            campaign.derive_scheduled_action(
                plan["campaign_id_sha256"],
                plan["schedule_sha256"],
                boundary_ordinal,
                int(boundary["process_generation"]),
                campaign.ACTION_GRACEFUL_PHASE_END,
                boundary["rss_source_sha256"],
            )
        )
        boundary["segment_challenge_sha256"] = (
            campaign.derive_segment_challenge(
                plan["campaign_id_sha256"],
                boundary_ordinal,
                int(boundary["process_generation"]),
                boundary["previous_entry_sha256"],
                boundary["previous_verified_report_sha256"],
                boundary["scheduled_action_sha256"],
            )
        )
        entries[boundary_ordinal] = _reseal_entry(plan, boundary)
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.decode_manifest(_raw_manifest(plan, entries))

        final_entries = [dict(entry) for entry in canonical_entries]
        final_entries[-1]["exit_code_bits"] = campaign.U64_MAX
        final_entries[-1]["termination_signal"] = (
            campaign.TERMINATION_SIGNAL_KILL
        )
        final_entries[-1]["provenance_bits"] = (
            campaign.BASE_PROVENANCE_BITS
            | campaign.PROVENANCE_FORCED_OS_PROCESS_KILL
        )
        final_entries[-1] = _reseal_entry(plan, final_entries[-1])
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.decode_manifest(_raw_manifest(plan, final_entries))

        selector = campaign.decode_selector(self.selector)
        selector["flags"] = campaign.PLAN_FLAG_FORCED_PROCESS_RESTART
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "selector flags",
        ):
            campaign.decode_selector(_reseal_selector(selector))

    def test_every_prefix_is_fixed_size_checkpoint_and_resumes(self) -> None:
        previous_manifest_root = None
        for length in range(1, SEGMENTS + 1):
            with self.subTest(length=length):
                wire = campaign.make_manifest(
                    self.plan,
                    self.entries[:length],
                )
                self.assertEqual(len(wire), len(self.manifest))
                decoded = campaign.verify_manifest(wire)
                self.assertEqual(decoded["completed_segment_count"], length)
                self.assertEqual(len(decoded["entries"]), length)
                zero_start = (
                    campaign.MANIFEST_HEADER_BYTES
                    + length * campaign.ATTEMPT_BYTES
                )
                zero_end = (
                    campaign.MANIFEST_HEADER_BYTES
                    + SEGMENTS * campaign.ATTEMPT_BYTES
                )
                self.assertEqual(
                    wire[zero_start:zero_end],
                    bytes(zero_end - zero_start),
                )
                after = (
                    self.after_environment
                    if length == SEGMENTS
                    else campaign.ZERO_DIGEST
                )
                environment = campaign.derive_environment_sha256(
                    self.plan["campaign_id_sha256"],
                    length,
                    self.before_environment,
                    after,
                )
                selector_wire = campaign.make_selector(
                    decoded,
                    environment,
                )
                selector = campaign.verify_selector(
                    wire,
                    selector_wire,
                    environment,
                )
                self.assertEqual(selector["generation"], length)
                self.assertEqual(selector["segment_count"], SEGMENTS)
                self.assertEqual(selector["total_records"], length * 250)
                self.assertEqual(selector["total_completed"], length * 100)
                self.assertEqual(selector["total_events"], length * 1_250)
                if length > 1:
                    self.assertEqual(
                        decoded["entries"][-1][
                            "previous_entry_sha256"
                        ],
                        decoded["entries"][-2]["entry_sha256"],
                    )
                    self.assertNotEqual(
                        decoded["manifest_sha256"],
                        previous_manifest_root,
                    )
                previous_manifest_root = decoded["manifest_sha256"]

    def test_forced_restart_every_prefix_roundtrips(self) -> None:
        plan = _plan(
            flags=campaign.PLAN_FLAG_FORCED_PROCESS_RESTART,
        )
        entries = _entries(plan)
        for length in range(1, SEGMENTS + 1):
            with self.subTest(length=length):
                wire = campaign.make_manifest(plan, entries[:length])
                decoded = campaign.verify_manifest(wire)
                self.assertEqual(
                    decoded["completed_segment_count"],
                    length,
                )
                after = (
                    self.after_environment
                    if length == SEGMENTS
                    else campaign.ZERO_DIGEST
                )
                environment = campaign.derive_environment_sha256(
                    plan["campaign_id_sha256"],
                    length,
                    self.before_environment,
                    after,
                )
                selector_wire = campaign.make_selector(
                    decoded,
                    environment,
                )
                selector = campaign.verify_selector(
                    wire,
                    selector_wire,
                    environment,
                )
                self.assertEqual(selector["generation"], length)
                self.assertEqual(
                    selector["flags"],
                    campaign.ALLOWED_SELECTOR_FLAGS,
                )
                if length >= RESTART_AFTER:
                    boundary = decoded["entries"][
                        RESTART_AFTER - 1
                    ]
                    self.assertEqual(
                        boundary["termination_signal"],
                        campaign.TERMINATION_SIGNAL_KILL,
                    )

    def test_manifest_rejects_every_one_bit_mutation(self) -> None:
        for index in range(len(self.manifest)):
            with self.subTest(index=index):
                mutated = bytearray(self.manifest)
                mutated[index] ^= 1
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.decode_manifest(bytes(mutated))

    def test_selector_rejects_every_one_bit_mutation(self) -> None:
        for index in range(len(self.selector)):
            with self.subTest(index=index):
                mutated = bytearray(self.selector)
                mutated[index] ^= 1
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.decode_selector(bytes(mutated))

    def test_truncation_extension_and_zero_gap_reject(self) -> None:
        for encoded, decoder in (
            (self.manifest, campaign.decode_manifest),
            (self.selector, campaign.decode_selector),
        ):
            for truncated in (encoded[:-1], encoded[: len(encoded) // 2]):
                with self.assertRaises(campaign.CampaignManifestError):
                    decoder(truncated)
            with self.assertRaises(campaign.CampaignManifestError):
                decoder(encoded + b"\x00")

        prefix = bytearray(
            campaign.make_manifest(self.plan, self.entries[:2])
        )
        source_start = campaign.MANIFEST_HEADER_BYTES
        source_end = source_start + campaign.ATTEMPT_BYTES
        gap_target = source_start + 3 * campaign.ATTEMPT_BYTES
        prefix[gap_target : gap_target + campaign.ATTEMPT_BYTES] = (
            prefix[source_start:source_end]
        )
        body_end = (
            campaign.MANIFEST_HEADER_BYTES
            + SEGMENTS * campaign.ATTEMPT_BYTES
        )
        roots = campaign._manifest_roots(  # type: ignore[attr-defined]
            bytes(prefix[:body_end])
        )
        prefix[body_end:] = roots[0] + roots[1]
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "zero suffix",
        ):
            campaign.decode_manifest(bytes(prefix))

    def test_drop_swap_duplicate_and_replay_reject(self) -> None:
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.make_manifest(
                self.plan,
                [self.entries[0], *self.entries[2:]],
            )
        swapped = list(self.entries)
        swapped[1], swapped[2] = swapped[2], swapped[1]
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.make_manifest(self.plan, swapped)
        duplicated = list(self.entries)
        duplicated[2] = duplicated[1]
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.make_manifest(self.plan, duplicated)
        replayed = list(self.entries)
        replayed[-1] = replayed[0]
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.make_manifest(self.plan, replayed)

        partial = campaign.make_manifest(self.plan, self.entries[:3])
        partial_decoded = campaign.decode_manifest(partial)
        partial_environment = campaign.derive_environment_sha256(
            self.plan["campaign_id_sha256"],
            3,
            self.before_environment,
            campaign.ZERO_DIGEST,
        )
        partial_selector = campaign.make_selector(
            partial_decoded,
            partial_environment,
        )
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.verify_selector(
                self.manifest,
                partial_selector,
                partial_environment,
            )

    def test_plan_bounds_counts_and_time_semantics_reject(self) -> None:
        mutations = (
            ("flags", 1),
            ("restart_after_segment", SEGMENTS),
            ("measured_epochs_per_segment", 47),
            ("records_per_epoch", 6),
            ("minimum_segment_duration_ns", 4_999_999_999),
            ("maximum_segment_duration_ns", 4_000_000_000),
            ("artifact_store_max_bytes", 1),
            ("rss_growth_bound_bytes", 0),
            ("device_allocation_growth_bound_bytes", 0),
            ("total_records", 2_999),
            ("total_capacity_rejected", 599),
            ("total_pin_acquisitions", 2_399),
            ("total_events", 14_999),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                candidate = dict(self.plan)
                candidate[field] = value
                candidate["campaign_id_sha256"] = campaign.derive_campaign_id(
                    candidate
                )
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.make_manifest(candidate, self.entries)

    def test_dynamic_identity_excluded_from_preflight_id_but_bound(self) -> None:
        initial = _plan_fields()
        for field in (
            "machine_sha256",
            "backend_sha256",
            "device_sha256",
            "placement_sha256",
        ):
            initial[field] = campaign.ZERO_DIGEST
        initial_id = campaign.derive_campaign_id(initial)
        changed_dynamic = dict(initial)
        changed_dynamic["machine_sha256"] = _digest("foreign-machine")
        changed_dynamic["device_sha256"] = _digest("foreign-device")
        self.assertEqual(
            campaign.derive_campaign_id(changed_dynamic),
            initial_id,
        )
        changed_schedule = dict(initial)
        changed_schedule["schedule_sha256"] = _digest("foreign-schedule")
        self.assertNotEqual(
            campaign.derive_campaign_id(changed_schedule),
            initial_id,
        )

        changed_plan = dict(self.plan)
        changed_plan["machine_sha256"] = _digest("foreign-machine")
        changed_plan["campaign_id_sha256"] = campaign.derive_campaign_id(
            changed_plan
        )
        with self.assertRaises(campaign.CampaignManifestError):
            campaign.make_manifest(changed_plan, self.entries)

    def test_rehashed_count_time_provenance_and_exit_mutations_reject(self) -> None:
        cases = (
            (0, "record_count", 249),
            (0, "warmup_record_count", 9),
            (0, "duration_ns", 4_999_999_999),
            (0, "cumulative_records", 249),
            (0, "provenance_bits", campaign.ALLOWED_PROVENANCE_BITS),
            (0, "exit_code_bits", 0),
            (5, "exit_code_bits", campaign.U64_MAX),
            (5, "termination_signal", 9),
            (6, "process_generation", 1),
            (11, "provenance_bits", campaign.ALLOWED_PROVENANCE_BITS),
        )
        for ordinal, field, value in cases:
            with self.subTest(ordinal=ordinal, field=field):
                entries = [dict(entry) for entry in self.entries]
                entries[ordinal][field] = value
                entries[ordinal] = _reseal_entry(
                    self.plan,
                    entries[ordinal],
                )
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.decode_manifest(
                        _raw_manifest(self.plan, entries)
                    )

    def test_scheduled_action_challenge_and_chain_mutations_reject(self) -> None:
        for field in (
            "scheduled_action_sha256",
            "segment_challenge_sha256",
            "previous_entry_sha256",
            "previous_verified_report_sha256",
        ):
            entries = [dict(entry) for entry in self.entries]
            entries[7][field] = _digest("wrong-" + field)
            entries[7] = _reseal_entry(self.plan, entries[7])
            with self.subTest(field=field):
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.decode_manifest(
                        _raw_manifest(self.plan, entries)
                    )

    def test_make_entry_rejects_caller_derived_root_drift(self) -> None:
        canonical = dict(self.entries[0])
        canonical["entry_sha256"] = campaign.ZERO_DIGEST
        self.assertEqual(
            campaign.make_entry(self.plan, canonical),
            self.entries[0],
        )
        mutations = (
            ("scheduled_action_sha256", _digest("drift-action")),
            ("segment_challenge_sha256", _digest("drift-challenge")),
            ("rss_unavailable_reason_sha256", _digest("drift-rss")),
            (
                "device_allocation_unavailable_reason_sha256",
                _digest("drift-device"),
            ),
            ("entry_sha256", _digest("presealed-entry")),
            ("abi_version", campaign.ATTEMPT_ABI + 1),
            ("reserved", 1),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                candidate = dict(canonical)
                candidate[field] = value
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.make_entry(self.plan, candidate)

    def test_rss_and_device_availability_semantics(self) -> None:
        unavailable_entries = _entries(
            self.plan,
            rss_availability=campaign.AVAILABILITY_UNSUPPORTED,
            device_availability=campaign.AVAILABILITY_UNSUPPORTED,
        )
        wire = campaign.make_manifest(self.plan, unavailable_entries)
        decoded = campaign.decode_manifest(wire)
        self.assertEqual(
            decoded["entries"][0]["rss_before_bytes"],
            0,
        )
        self.assertNotEqual(
            decoded["entries"][0]["rss_unavailable_reason_sha256"],
            campaign.ZERO_DIGEST,
        )
        self.assertNotEqual(
            decoded["entries"][0][
                "device_allocation_unavailable_reason_sha256"
            ],
            campaign.ZERO_DIGEST,
        )

        for field, value in (
            ("rss_before_bytes", 1),
            ("rss_unavailable_reason_sha256", _digest("wrong-rss-reason")),
            ("device_allocation_max_bytes", 1),
            (
                "device_allocation_unavailable_reason_sha256",
                _digest("wrong-device-reason"),
            ),
        ):
            entries = [dict(entry) for entry in unavailable_entries]
            entries[0][field] = value
            entries[0] = _reseal_entry(self.plan, entries[0])
            with self.subTest(field=field):
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.make_manifest(self.plan, entries)

    def test_phase_growth_uses_first_baseline_not_local_baseline(self) -> None:
        rss_plan = _plan(rss_growth_bound=2 * MIB)
        rss_creep = _entries(
            rss_plan,
            rss_step_bytes=MIB,
        )
        # Every local max is far below rss_before + 2 MiB, but segment three
        # exceeds the first persistent-process baseline.
        self.assertTrue(
            all(
                int(entry["rss_max_bytes"])
                <= int(entry["rss_before_bytes"]) + 2 * MIB
                for entry in rss_creep
            )
        )
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "phase bound",
        ):
            campaign.make_manifest(rss_plan, rss_creep)

        device_plan = _plan(device_growth_bound=MIB)
        device_creep = _entries(
            device_plan,
            device_step_bytes=768 * 1024,
        )
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "device allocation context",
        ):
            campaign.make_manifest(device_plan, device_creep)

    def test_rss_source_is_stable_per_process_and_changes_at_restart(self) -> None:
        same_source = _entries(
            self.plan,
            distinct_process_sources=False,
        )
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "did not change",
        ):
            campaign.make_manifest(self.plan, same_source)

        changed_inside = _entries(
            self.plan,
            change_source_within_phase=True,
        )
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "changed within",
        ):
            campaign.make_manifest(self.plan, changed_inside)

    def test_selector_semantic_mutations_and_environment_binding_reject(self) -> None:
        selector = campaign.decode_selector(self.selector)
        mutations = (
            ("generation", SEGMENTS - 1),
            ("segment_count", SEGMENTS - 1),
            ("total_records", 2_999),
            ("total_completed", 1_199),
            ("total_events", 14_999),
            ("campaign_challenge_sha256", _digest("foreign-authority")),
            ("manifest_sha256", _digest("foreign-manifest")),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                candidate = dict(selector)
                candidate[field] = value
                encoded = _reseal_selector(candidate)
                with self.assertRaises(campaign.CampaignManifestError):
                    campaign.verify_selector(
                        self.manifest,
                        encoded,
                        self.environment,
                    )
        foreign_environment = _digest("foreign-environment")
        candidate = dict(selector)
        candidate["environment_sha256"] = foreign_environment
        encoded = _reseal_selector(candidate)
        with self.assertRaisesRegex(
            campaign.CampaignManifestError,
            "environment",
        ):
            campaign.verify_selector(
                self.manifest,
                encoded,
                self.environment,
            )

    def test_selector_codec_rejects_out_of_range_geometry_and_zero_totals(
        self,
    ) -> None:
        selector = campaign.decode_selector(self.selector)
        mutations = (
            ("segment_count", campaign.MAX_SEGMENTS + 1),
            ("total_records", 0),
            ("total_completed", 0),
            ("total_events", 0),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                candidate = dict(selector)
                candidate[field] = value
                encoded = _reseal_selector(candidate)
                candidate["selector_sha256"] = encoded[-32:]
                with self.assertRaises(
                    campaign.CampaignManifestError
                ):
                    campaign.decode_selector(encoded)
                with self.assertRaises(
                    campaign.CampaignManifestError
                ):
                    campaign.encode_selector(candidate)


if __name__ == "__main__":
    unittest.main()
