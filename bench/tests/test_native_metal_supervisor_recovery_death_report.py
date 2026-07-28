from __future__ import annotations

import hashlib
import unittest

from bench import native_metal_supervisor_recovery_death_report as report


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _fixture(
    *,
    alias_controller_roles: bool = False,
) -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
    dict[str, object],
    dict[str, object],
    dict[str, object],
    dict[str, object],
    bytes,
]:
    campaign_challenge = _digest("campaign-challenge")
    schedule = _digest("schedule")
    controller_authority = _digest("controller-authority")
    role_component = _digest("role-component")
    controller = (
        role_component if alias_controller_roles else _digest("controller")
    )
    supervisor = (
        role_component if alias_controller_roles else _digest("supervisor")
    )
    recovery = (
        role_component if alias_controller_roles else _digest("recovery")
    )
    worker = _digest("worker")
    metallib = _digest("metallib")
    verifier = _digest("verifier")
    machine = _digest("machine")
    backend = _digest("backend")
    device = _digest("device")
    placement = _digest("placement")
    component_set = report.derive_component_set_sha256(
        controller,
        supervisor,
        recovery,
        worker,
        metallib,
        verifier,
    )
    supervisor_challenge = report.derive_supervisor_challenge_sha256(
        campaign_challenge,
        schedule,
        component_set,
    )
    machine_join = report.derive_machine_join_sha256(
        machine,
        backend,
        device,
        placement,
    )
    campaign_id = _digest("campaign-id")
    lock_identity = _digest("lock-identity")
    generation_six_manifest = _digest("generation-six-manifest")
    generation_six_selector = _digest("generation-six-selector")
    generation_six_entry = _digest("generation-six-entry")
    generation_six_store = _digest("generation-six-store")

    supervisor_ready = report.make_supervisor_ready(
        {
            "abi_version": report.SUPERVISOR_READY_ABI,
            "encoded_bytes": report.SUPERVISOR_READY_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "pid": 1_001,
            "worker_pid": 1_002,
            "worker_exit_code_bits": 0,
            "worker_termination_signal": 0,
            "active_worker_count": 0,
            "lock_held": 1,
            "selected_generation": report.SUPERVISOR_GENERATION,
            "segment_count": report.SUPERVISOR_GENERATION,
            "publication_inflight": 0,
            "selector_bytes": report.SELECTOR_BYTES,
            "process_session_isolated": 1,
            "lock_contended": 1,
            "reserved": 0,
            "supervisor_challenge_sha256": supervisor_challenge,
            "supervisor_sha256": supervisor,
            "worker_sha256": worker,
            "metallib_sha256": metallib,
            "campaign_id_sha256": campaign_id,
            "manifest_sha256": generation_six_manifest,
            "selector_sha256": generation_six_selector,
            "final_entry_sha256": generation_six_entry,
            "canonical_store_sha256": generation_six_store,
            "lock_identity_sha256": lock_identity,
            "machine_join_sha256": machine_join,
            "root_sha256": report.ZERO_DIGEST,
        }
    )
    supervisor_kill = report.make_supervisor_kill(
        {
            "abi_version": report.SUPERVISOR_KILL_ABI,
            "encoded_bytes": report.SUPERVISOR_KILL_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "pid": supervisor_ready["pid"],
            "termination_signal": 9,
            "returncode_bits": report.SIGKILL_RETURNCODE_BITS,
            "stdout_bytes": report.SUPERVISOR_READY_BYTES,
            "stderr_bytes": 0,
            "campaign_challenge_sha256": campaign_challenge,
            "supervisor_challenge_sha256": supervisor_challenge,
            "supervisor_ready_sha256": supervisor_ready["root_sha256"],
            "supervisor_sha256": supervisor,
            "controller_sha256": controller,
            "lock_identity_sha256": lock_identity,
            "component_set_sha256": component_set,
            "root_sha256": report.ZERO_DIGEST,
        }
    )
    resume_grant = report.derive_resume_grant_sha256(
        controller_authority,
        campaign_challenge,
        schedule,
        component_set,
        supervisor_ready["root_sha256"],  # type: ignore[arg-type]
        supervisor_kill["root_sha256"],  # type: ignore[arg-type]
        generation_six_selector,
        generation_six_store,
    )
    generation_six_audit = report.make_generation_six_audit(
        {
            "abi_version": report.GENERATION_SIX_AUDIT_ABI,
            "encoded_bytes": report.GENERATION_SIX_AUDIT_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "auditor_pid": 1_003,
            "selected_generation": report.SUPERVISOR_GENERATION,
            "segment_count": report.SUPERVISOR_GENERATION,
            "require_complete": 0,
            "complete": 0,
            "shared_lock": 1,
            "unknown_object_count": 0,
            "temporary_object_count": 0,
            "hardlink_count": 0,
            "symlink_count": 0,
            "process_generation_count": 1,
            "total_records": report.GENERATION_SIX_RECORDS,
            "total_completed": report.GENERATION_SIX_COMPLETED,
            "resume_grant_sha256": resume_grant,
            "campaign_id_sha256": campaign_id,
            "manifest_sha256": generation_six_manifest,
            "selector_sha256": generation_six_selector,
            "final_entry_sha256": generation_six_entry,
            "canonical_store_sha256": generation_six_store,
            "lock_identity_sha256": lock_identity,
            "root_sha256": report.ZERO_DIGEST,
        }
    )
    recovery_challenge = report.derive_recovery_challenge_sha256(
        resume_grant,
        generation_six_audit["root_sha256"],  # type: ignore[arg-type]
    )

    selected_manifest = _digest("generation-eleven-manifest")
    selected_selector = _digest("generation-eleven-selector")
    candidate_manifest = _digest("generation-twelve-manifest")
    candidate_selector = _digest("generation-twelve-selector")
    prepared_store = _digest("generation-twelve-prepared-store")
    final_store = _digest("generation-twelve-final-store")
    recovery_ready = report.make_recovery_ready(
        {
            "abi_version": report.RECOVERY_READY_ABI,
            "encoded_bytes": report.RECOVERY_READY_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "pid": 2_001,
            "worker_pid": 2_002,
            "worker_exit_code_bits": 0,
            "worker_termination_signal": 0,
            "active_worker_count": 0,
            "lock_held": 1,
            "selected_generation": report.RECOVERY_SELECTED_GENERATION,
            "candidate_generation": report.CANDIDATE_GENERATION,
            "segment_count": report.SEGMENT_COUNT,
            "controller_lock_contention_acknowledged": 1,
            "candidate_selector_bytes": report.SELECTOR_BYTES,
            "root_sync_completed": 0,
            "publication_phase_index": (
                report.PUBLICATION_PHASE_SELECTOR_ACTIVE_REPLACE
            ),
            "resume_grant_sha256": resume_grant,
            "recovery_sha256": recovery,
            "worker_sha256": worker,
            "recovery_challenge_sha256": recovery_challenge,
            "campaign_id_sha256": campaign_id,
            "selected_manifest_sha256": selected_manifest,
            "selected_selector_sha256": selected_selector,
            "candidate_manifest_sha256": candidate_manifest,
            "candidate_selector_sha256": candidate_selector,
            "prepared_store_sha256": prepared_store,
            "lock_identity_sha256": lock_identity,
            "root_sha256": report.ZERO_DIGEST,
        }
    )
    recovery_kill = report.make_recovery_kill(
        {
            "abi_version": report.RECOVERY_KILL_ABI,
            "encoded_bytes": report.RECOVERY_KILL_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "pid": recovery_ready["pid"],
            "termination_signal": 9,
            "returncode_bits": report.SIGKILL_RETURNCODE_BITS,
            "stdout_bytes": report.RECOVERY_READY_BYTES,
            "stderr_bytes": 0,
            "campaign_challenge_sha256": campaign_challenge,
            "resume_grant_sha256": resume_grant,
            "recovery_ready_sha256": recovery_ready["root_sha256"],
            "recovery_sha256": recovery,
            "controller_sha256": controller,
            "lock_identity_sha256": lock_identity,
            "component_set_sha256": component_set,
            "root_sha256": report.ZERO_DIGEST,
        }
    )
    finalizer_grant = report.derive_finalizer_grant_sha256(
        controller_authority,
        campaign_challenge,
        schedule,
        component_set,
        resume_grant,
        recovery_ready["root_sha256"],  # type: ignore[arg-type]
        recovery_kill["root_sha256"],  # type: ignore[arg-type]
        candidate_selector,
        prepared_store,
    )
    final_audit = report.make_final_audit(
        {
            "abi_version": report.FINAL_AUDIT_ABI,
            "encoded_bytes": report.FINAL_AUDIT_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "finalizer_pid": 3_001,
            "auditor_pid": 3_002,
            "predecessor_generation": report.RECOVERY_SELECTED_GENERATION,
            "final_generation": report.CANDIDATE_GENERATION,
            "segment_count": report.SEGMENT_COUNT,
            "rollforward_count": 1,
            "replace_count": 1,
            "root_sync_count": 1,
            "complete": 1,
            "unknown_object_count": 0,
            "temporary_object_count": 0,
            "total_records": report.TOTAL_RECORDS,
            "total_completed": report.TOTAL_COMPLETED,
            "finalizer_grant_sha256": finalizer_grant,
            "campaign_id_sha256": campaign_id,
            "predecessor_selector_sha256": selected_selector,
            "candidate_selector_sha256": candidate_selector,
            "final_manifest_sha256": candidate_manifest,
            "final_selector_sha256": candidate_selector,
            "final_store_sha256": final_store,
            "root_sha256": report.ZERO_DIGEST,
        }
    )
    header = report.make_header(
        {
            "abi_version": report.REPORT_ABI,
            "encoded_bytes": report.REPORT_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "header_bytes": report.HEADER_BYTES,
            "supervisor_ready_bytes": report.SUPERVISOR_READY_BYTES,
            "supervisor_kill_bytes": report.SUPERVISOR_KILL_BYTES,
            "generation_six_audit_bytes": (
                report.GENERATION_SIX_AUDIT_BYTES
            ),
            "recovery_ready_bytes": report.RECOVERY_READY_BYTES,
            "recovery_kill_bytes": report.RECOVERY_KILL_BYTES,
            "final_audit_bytes": report.FINAL_AUDIT_BYTES,
            "footer_bytes": report.FOOTER_BYTES,
            "segment_count": report.SEGMENT_COUNT,
            "supervisor_generation": report.SUPERVISOR_GENERATION,
            "recovery_selected_generation": (
                report.RECOVERY_SELECTED_GENERATION
            ),
            "candidate_generation": report.CANDIDATE_GENERATION,
            "worker_process_count": report.WORKER_PROCESS_COUNT,
            "total_sigkill_count": report.TOTAL_SIGKILL_COUNT,
            "total_records": report.TOTAL_RECORDS,
            "total_completed": report.TOTAL_COMPLETED,
            "total_cancelled": report.TOTAL_CANCELLED,
            "total_failed": report.TOTAL_FAILED,
            "total_capacity_rejected": report.TOTAL_CAPACITY_REJECTED,
            "total_pin_completions": report.TOTAL_PIN_COMPLETIONS,
            "total_events": report.TOTAL_EVENTS,
            "campaign_challenge_sha256": campaign_challenge,
            "schedule_sha256": schedule,
            "controller_authority_sha256": controller_authority,
            "component_set_sha256": component_set,
            "controller_sha256": controller,
            "supervisor_sha256": supervisor,
            "recovery_sha256": recovery,
            "worker_sha256": worker,
            "metallib_sha256": metallib,
            "verifier_sha256": verifier,
            "machine_sha256": machine,
            "backend_sha256": backend,
            "device_sha256": device,
            "placement_sha256": placement,
            "resume_grant_sha256": resume_grant,
            "finalizer_grant_sha256": finalizer_grant,
            "supervisor_ready_sha256": supervisor_ready["root_sha256"],
            "supervisor_kill_sha256": supervisor_kill["root_sha256"],
            "generation_six_audit_sha256": (
                generation_six_audit["root_sha256"]
            ),
            "recovery_ready_sha256": recovery_ready["root_sha256"],
            "recovery_kill_sha256": recovery_kill["root_sha256"],
            "final_audit_sha256": final_audit["root_sha256"],
            "generation_six_selector_sha256": generation_six_selector,
            "candidate_selector_sha256": candidate_selector,
            "final_store_sha256": final_store,
            "header_sha256": report.ZERO_DIGEST,
        }
    )
    wire = report.make_report(
        header,
        supervisor_ready,
        supervisor_kill,
        generation_six_audit,
        recovery_ready,
        recovery_kill,
        final_audit,
    )
    return (
        header,
        supervisor_ready,
        supervisor_kill,
        generation_six_audit,
        recovery_ready,
        recovery_kill,
        final_audit,
        wire,
    )


def _reseal_header(
    header: dict[str, object],
    **changes: object,
) -> dict[str, object]:
    value = dict(header)
    value.update(changes)
    value["header_sha256"] = report.ZERO_DIGEST
    return report.make_header(value)


def _reseal_region(
    value: dict[str, object],
    constructor: object,
    **changes: object,
) -> dict[str, object]:
    changed = dict(value)
    changed.update(changes)
    changed["root_sha256"] = report.ZERO_DIGEST
    return constructor(changed)  # type: ignore[operator,no-any-return]


class NativeMetalSupervisorRecoveryDeathReportTests(unittest.TestCase):
    def test_fixed_geometry_round_trip_and_public_region_codecs(self) -> None:
        (
            header,
            supervisor_ready,
            supervisor_kill,
            generation_six_audit,
            recovery_ready,
            recovery_kill,
            final_audit,
            wire,
        ) = _fixture()
        self.assertEqual(
            report.REPORT_BYTES,
            report.HEADER_BYTES
            + report.SUPERVISOR_READY_BYTES
            + report.SUPERVISOR_KILL_BYTES
            + report.GENERATION_SIX_AUDIT_BYTES
            + report.RECOVERY_READY_BYTES
            + report.RECOVERY_KILL_BYTES
            + report.FINAL_AUDIT_BYTES
            + report.FOOTER_BYTES,
        )
        self.assertEqual(3_520, len(wire))
        decoded = report.verify_report(wire)
        self.assertEqual(header, decoded.header)
        self.assertEqual(supervisor_ready, decoded.supervisor_ready)
        self.assertEqual(supervisor_kill, decoded.supervisor_kill)
        self.assertEqual(
            generation_six_audit,
            decoded.generation_six_audit,
        )
        self.assertEqual(recovery_ready, decoded.recovery_ready)
        self.assertEqual(recovery_kill, decoded.recovery_kill)
        self.assertEqual(final_audit, decoded.final_audit)
        self.assertEqual(wire, decoded.encoded)
        self.assertEqual(
            header,
            report.decode_header(report.encode_header(header)),
        )
        self.assertEqual(
            supervisor_ready,
            report.decode_supervisor_ready(
                report.encode_supervisor_ready(supervisor_ready)
            ),
        )
        self.assertEqual(
            supervisor_kill,
            report.decode_supervisor_kill(
                report.encode_supervisor_kill(supervisor_kill)
            ),
        )
        self.assertEqual(
            generation_six_audit,
            report.decode_generation_six_audit(
                report.encode_generation_six_audit(
                    generation_six_audit
                )
            ),
        )
        self.assertEqual(
            recovery_ready,
            report.decode_recovery_ready(
                report.encode_recovery_ready(recovery_ready)
            ),
        )
        self.assertEqual(
            recovery_kill,
            report.decode_recovery_kill(
                report.encode_recovery_kill(recovery_kill)
            ),
        )
        self.assertEqual(
            final_audit,
            report.decode_final_audit(
                report.encode_final_audit(final_audit)
            ),
        )

    def test_golden_roots_are_stable(self) -> None:
        values = _fixture()
        roots = tuple(
            value["root_sha256"].hex()  # type: ignore[union-attr]
            for value in values[1:7]
        )
        self.assertEqual(
            (
                "7f1c4e2d1b52275e2ab94718f0ff2d6b77a17742f18ab5dbaa54c17d24846d01",
                "9330d28b6d058b486fa0aaebc9703cc980e6e5c958bbc0f56fd77417336d648c",
                "56d96ce5093e4c5b22b2e8fba687ac285d79fdd2c8fc1af68cbb1b380d41d30e",
                "103e9e98f684867d61118343e1df79a809eb9e6aa69335a61e488edf3f4821dc",
                "4e4039341a67b72b3e95a8f9d8fe84e77f8344dd86fd1372b7bc2e23097c6cb4",
                "fea73e6ef648f43f1b7086e7e7f7f7d354b978befc546966af0027a65ad0892f",
            ),
            roots,
        )
        self.assertEqual(
            "f88c7df352973ae119ef95a05cc1576e79afed0c496afbc4fb3f998b11ac11e8",
            values[0]["header_sha256"].hex(),  # type: ignore[union-attr]
        )
        decoded = report.verify_report(values[-1])
        self.assertEqual(
            "f17873d08cf38205b02162fc8035517c49096c00898f476913228d0a1071b23b",
            decoded.body_sha256.hex(),
        )
        self.assertEqual(
            "0260c4a008fa5b27c78ed793feceb1107bf7615b373b76982f4d96a2b9cf58c9",
            decoded.report_sha256.hex(),
        )

    def test_every_wire_byte_mutation_rejects(self) -> None:
        wire = _fixture()[-1]
        for offset in range(len(wire)):
            mutated = bytearray(wire)
            mutated[offset] ^= 1
            with self.assertRaises(
                report.SupervisorRecoveryDeathReportError,
                msg="offset %d" % offset,
            ):
                report.verify_report(bytes(mutated))

    def test_every_truncation_and_trailing_data_rejects(self) -> None:
        wire = _fixture()[-1]
        for length in range(len(wire)):
            with self.assertRaises(
                report.SupervisorRecoveryDeathReportError,
                msg="length %d" % length,
            ):
                report.verify_report(wire[:length])
        with self.assertRaises(report.SupervisorRecoveryDeathReportError):
            report.verify_report(wire + b"\x00")

    def test_generation_six_eleven_twelve_joins_are_strict(self) -> None:
        values = list(_fixture())
        header = values[0]
        final_audit = values[6]
        mutations = (
            (
                "campaign_id_sha256",
                _digest("other-campaign"),
                "campaign identity",
            ),
            (
                "predecessor_selector_sha256",
                _digest("other-predecessor"),
                "predecessor",
            ),
            (
                "final_manifest_sha256",
                _digest("other-final-manifest"),
                "manifest",
            ),
            (
                "final_store_sha256",
                _digest("other-final-store"),
                "store",
            ),
        )
        for field, changed_value, message in mutations:
            with self.subTest(field=field):
                changed_final = _reseal_region(
                    final_audit,
                    report.make_final_audit,
                    **{field: changed_value},
                )
                changed_header = _reseal_header(
                    header,
                    final_audit_sha256=changed_final["root_sha256"],
                )
                with self.assertRaisesRegex(
                    report.SupervisorRecoveryDeathReportError,
                    message,
                ):
                    report.make_report(
                        changed_header,
                        *values[1:6],
                        changed_final,
                    )

    def test_prepared_and_final_store_roots_are_distinct(self) -> None:
        values = list(_fixture())
        header = values[0]
        self.assertNotEqual(
            values[4]["prepared_store_sha256"],
            header["final_store_sha256"],
        )
        changed_ready = _reseal_region(
            values[4],
            report.make_recovery_ready,
            prepared_store_sha256=header["final_store_sha256"],
        )
        changed_kill = _reseal_region(
            values[5],
            report.make_recovery_kill,
            recovery_ready_sha256=changed_ready["root_sha256"],
        )
        finalizer_grant = report.derive_finalizer_grant_sha256(
            header["controller_authority_sha256"],  # type: ignore[arg-type]
            header["campaign_challenge_sha256"],  # type: ignore[arg-type]
            header["schedule_sha256"],  # type: ignore[arg-type]
            header["component_set_sha256"],  # type: ignore[arg-type]
            header["resume_grant_sha256"],  # type: ignore[arg-type]
            changed_ready["root_sha256"],  # type: ignore[arg-type]
            changed_kill["root_sha256"],  # type: ignore[arg-type]
            header["candidate_selector_sha256"],  # type: ignore[arg-type]
            changed_ready["prepared_store_sha256"],  # type: ignore[arg-type]
        )
        changed_final = _reseal_region(
            values[6],
            report.make_final_audit,
            finalizer_grant_sha256=finalizer_grant,
        )
        changed_header = _reseal_header(
            header,
            recovery_ready_sha256=changed_ready["root_sha256"],
            recovery_kill_sha256=changed_kill["root_sha256"],
            finalizer_grant_sha256=finalizer_grant,
            final_audit_sha256=changed_final["root_sha256"],
        )
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "prepared and final store roots",
        ):
            report.make_report(
                changed_header,
                *values[1:4],
                changed_ready,
                changed_kill,
                changed_final,
            )

    def test_role_grants_are_derived_bound_distinct_and_non_authorizing(
        self,
    ) -> None:
        values = list(_fixture())
        header = values[0]
        swapped = _reseal_header(
            header,
            resume_grant_sha256=header["finalizer_grant_sha256"],
            finalizer_grant_sha256=header["resume_grant_sha256"],
        )
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "resume role grant",
        ):
            report.make_report(swapped, *values[1:7])
        same = dict(header)
        same["finalizer_grant_sha256"] = same["resume_grant_sha256"]
        same["header_sha256"] = report.ZERO_DIGEST
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "role-specific grants",
        ):
            report.make_header(same)
        boundary = report.verify_report(values[-1]).claim_boundary
        self.assertEqual(2, boundary.reported_real_pid_only_sigkill_count)
        self.assertEqual(
            0,
            boundary.reported_controlled_fault_injection_count,
        )
        self.assertEqual(
            1_200,
            boundary.reported_production_native_metal_command_count,
        )
        self.assertEqual(
            1_200,
            boundary.reported_cpu_oracle_checked_command_count,
        )
        self.assertTrue(boundary.claims_supervisor_death)
        self.assertTrue(boundary.claims_recovery_process_death)
        self.assertFalse(boundary.claims_active_kernel_interruption)
        self.assertFalse(boundary.claims_physical_device_loss)
        self.assertFalse(boundary.claims_physical_storage_failure)
        self.assertFalse(boundary.claims_power_loss)
        self.assertFalse(boundary.claims_driver_reclamation)
        self.assertFalse(boundary.claims_victim_output_recovery)
        self.assertFalse(boundary.claims_device_residency)
        self.assertFalse(boundary.claims_performance)
        self.assertFalse(boundary.claims_leak_freedom)
        self.assertFalse(boundary.external_provenance_verified)
        self.assertFalse(boundary.grants_runtime_authority)

    def test_real_pid_only_kill_receipts_are_exact(self) -> None:
        self.assertEqual(9, report.SIGKILL_NUMBER)
        values = list(_fixture())
        constructors = (
            (2, report.make_supervisor_kill),
            (5, report.make_recovery_kill),
        )
        mutations = (
            ("termination_signal", 15),
            ("returncode_bits", 9),
            ("stdout_bytes", 0),
            ("stderr_bytes", 1),
            ("pid", 0),
        )
        for index, constructor in constructors:
            baseline = values[index]
            for field, changed_value in mutations:
                with self.subTest(index=index, field=field):
                    with self.assertRaises(
                        report.SupervisorRecoveryDeathReportError,
                    ):
                        _reseal_region(
                            baseline,
                            constructor,
                            **{field: changed_value},
                        )

    def test_ready_and_audit_boundaries_are_exact(self) -> None:
        values = list(_fixture())
        cases = (
            (
                values[1],
                report.make_supervisor_ready,
                (
                    ("worker_exit_code_bits", 1),
                    ("active_worker_count", 1),
                    ("lock_held", 0),
                    ("selected_generation", 5),
                    ("segment_count", 5),
                    ("publication_inflight", 1),
                    ("selector_bytes", 191),
                    ("process_session_isolated", 0),
                    ("lock_contended", 0),
                    ("reserved", 1),
                ),
            ),
            (
                values[3],
                report.make_generation_six_audit,
                (
                    ("selected_generation", 5),
                    ("require_complete", 1),
                    ("complete", 1),
                    ("shared_lock", 0),
                    ("temporary_object_count", 1),
                    ("process_generation_count", 2),
                    ("total_records", 1_499),
                ),
            ),
            (
                values[4],
                report.make_recovery_ready,
                (
                    ("active_worker_count", 1),
                    ("selected_generation", 10),
                    ("candidate_generation", 11),
                    ("segment_count", 11),
                    ("controller_lock_contention_acknowledged", 0),
                    ("candidate_selector_bytes", 191),
                    ("root_sync_completed", 1),
                    ("publication_phase_index", 25),
                ),
            ),
            (
                values[6],
                report.make_final_audit,
                (
                    ("predecessor_generation", 10),
                    ("final_generation", 11),
                    ("rollforward_count", 0),
                    ("replace_count", 0),
                    ("root_sync_count", 0),
                    ("complete", 0),
                    ("temporary_object_count", 1),
                    ("total_records", 2_999),
                ),
            ),
        )
        for baseline, constructor, mutations in cases:
            for field, changed_value in mutations:
                with self.subTest(
                    constructor=getattr(constructor, "__name__", "?"),
                    field=field,
                ):
                    with self.assertRaises(
                        report.SupervisorRecoveryDeathReportError,
                    ):
                        _reseal_region(
                            baseline,
                            constructor,
                            **{field: changed_value},
                        )

    def test_component_role_alias_is_allowed_but_machine_alias_is_not(
        self,
    ) -> None:
        decoded = report.verify_report(
            _fixture(alias_controller_roles=True)[-1]
        )
        self.assertEqual(
            decoded.header["controller_sha256"],
            decoded.header["supervisor_sha256"],
        )
        self.assertEqual(
            decoded.header["supervisor_sha256"],
            decoded.header["recovery_sha256"],
        )
        header = dict(_fixture()[0])
        header["backend_sha256"] = header["machine_sha256"]
        header["header_sha256"] = report.ZERO_DIGEST
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "not distinct",
        ):
            report.make_header(header)

    def test_process_role_and_ready_receipt_pid_joins_are_strict(self) -> None:
        values = list(_fixture())
        header = values[0]
        supervisor_kill = _reseal_region(
            values[2],
            report.make_supervisor_kill,
            pid=9_999,
        )
        header = _reseal_header(
            header,
            supervisor_kill_sha256=supervisor_kill["root_sha256"],
        )
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "PID",
        ):
            report.make_report(
                header,
                values[1],
                supervisor_kill,
                *values[3:7],
            )
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "distinct PIDs",
        ):
            changed_final = _reseal_region(
                values[6],
                report.make_final_audit,
                finalizer_pid=values[4]["pid"],
            )
            changed_header = _reseal_header(
                values[0],
                final_audit_sha256=changed_final["root_sha256"],
            )
            report.make_report(
                changed_header,
                *values[1:6],
                changed_final,
            )
        for index, constructor, header_field, rejection in (
            (
                3,
                report.make_generation_six_audit,
                "generation_six_audit_sha256",
                "fresh generation-six audit",
            ),
            (
                6,
                report.make_final_audit,
                "final_audit_sha256",
                "distinct PIDs",
            ),
        ):
            with self.subTest(auditor_region=index):
                changed_audit = _reseal_region(
                    values[index],
                    constructor,
                    auditor_pid=values[1]["pid"],
                )
                changed_header = _reseal_header(
                    values[0],
                    **{header_field: changed_audit["root_sha256"]},
                )
                changed_regions = list(values[1:7])
                changed_regions[index - 1] = changed_audit
                with self.assertRaisesRegex(
                    report.SupervisorRecoveryDeathReportError,
                    rejection,
                ):
                    report.make_report(
                        changed_header,
                        *changed_regions,
                    )

    def test_canonical_fields_types_ranges_and_sealing_are_strict(self) -> None:
        values = list(_fixture())
        missing = dict(values[0])
        missing.pop("schedule_sha256")
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "canonical",
        ):
            report.make_header(missing)
        extra = dict(values[1])
        extra["future"] = 0
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "canonical",
        ):
            report.encode_supervisor_ready(extra)
        for invalid in (-1, report.U64_MAX + 1, True, 1.5):
            with self.subTest(invalid=invalid):
                changed = dict(values[4])
                changed["pid"] = invalid
                changed["root_sha256"] = report.ZERO_DIGEST
                with self.assertRaises(
                    report.SupervisorRecoveryDeathReportError,
                ):
                    report.make_recovery_ready(changed)
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "already sealed",
        ):
            report.make_final_audit(values[6])
        changed_digest = dict(values[3])
        changed_digest["campaign_id_sha256"] = b"x" * 31
        changed_digest["root_sha256"] = report.ZERO_DIGEST
        with self.assertRaisesRegex(
            report.SupervisorRecoveryDeathReportError,
            "32-byte",
        ):
            report.make_generation_six_audit(changed_digest)

    def test_footer_is_domain_separated_from_body(self) -> None:
        wire = _fixture()[-1]
        decoded = report.verify_report(wire)
        body = wire[: -report.FOOTER_BYTES]
        self.assertEqual(
            hashlib.sha256(report.BODY_DOMAIN + body).digest(),
            decoded.body_sha256,
        )
        self.assertEqual(
            hashlib.sha256(
                report.REPORT_DOMAIN + decoded.body_sha256
            ).digest(),
            decoded.report_sha256,
        )
        self.assertNotEqual(decoded.body_sha256, decoded.report_sha256)


if __name__ == "__main__":
    unittest.main()
