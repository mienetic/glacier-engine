from __future__ import annotations

import hashlib
import struct
import unittest

from bench import native_workload_campaign as campaign
from bench import native_workload_store_fault_report as fault


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _selector(
    generation: int,
    *,
    manifest_label: str,
    environment_label: str,
    records: int,
    completed: int,
    events: int,
    authority_label: str = "selector-authority",
    segment_count: int = 12,
) -> bytes:
    value: dict[str, object] = {
        "abi_version": campaign.SELECTOR_ABI,
        "encoded_bytes": campaign.SELECTOR_BYTES,
        "flags": campaign.ALLOWED_SELECTOR_FLAGS,
        "generation": generation,
        "segment_count": segment_count,
        "total_records": records,
        "total_completed": completed,
        "total_events": events,
        "campaign_challenge_sha256": _digest(authority_label),
        "manifest_sha256": _digest(manifest_label),
        "environment_sha256": _digest(environment_label),
        "selector_sha256": campaign.ZERO_DIGEST,
    }
    body = (
        b"".join(
            struct.pack("<Q", int(value[field]))
            for field in campaign.SELECTOR_SCALAR_FIELDS
        )
        + b"".join(
            value[field]  # type: ignore[misc]
            for field in campaign.SELECTOR_DIGEST_FIELDS[:-1]
        )
    )
    value["selector_sha256"] = hashlib.sha256(campaign.SELECTOR_DOMAIN + body).digest()
    return campaign.encode_selector(value)


def _counts(
    *,
    case_count: int,
    errno: int,
    signal: int,
    expected_before: int,
    expected_after: int,
    expected_either: int,
    observed_before: int,
    observed_after: int,
) -> dict[str, int]:
    return {
        "failpoint_count": case_count,
        "errno_case_count": errno,
        "signal_case_count": signal,
        "expected_before_only_count": expected_before,
        "expected_after_only_count": expected_after,
        "expected_either_count": expected_either,
        "observed_before_count": observed_before,
        "observed_after_count": observed_after,
        "recovered_before_count": 0,
        "recovered_after_count": case_count,
        "synthetic_fault_count": errno,
        "real_signal_count": signal,
        "total_trigger_count": case_count,
    }


def _header(
    selector_before: bytes,
    selector_after: bytes,
    *,
    generation_before: int = 5,
    generation_after: int = 6,
    counts: dict[str, int] | None = None,
) -> dict[str, object]:
    values = counts or _counts(
        case_count=5,
        errno=4,
        signal=1,
        expected_before=2,
        expected_after=2,
        expected_either=1,
        observed_before=3,
        observed_after=2,
    )
    case_count = values["failpoint_count"]
    result: dict[str, object] = {
        "abi_version": fault.REPORT_ABI,
        "encoded_bytes": fault.encoded_report_bytes(case_count),
        "flags": fault.ALLOWED_FLAGS,
        "case_count": case_count,
        "case_bytes": fault.CASE_BYTES,
        "selector_bytes": fault.SELECTOR_BYTES,
        "generation_before": generation_before,
        "generation_after": generation_after,
        **values,
        "store_max_bytes": 4 * 1024 * 1024,
        "store_max_files": 32,
        "reserved": 0,
        "matrix_challenge_sha256": _digest("matrix-challenge"),
        "schedule_sha256": _digest("schedule"),
        "matrix_id_sha256": fault.ZERO_DIGEST,
        "campaign_id_sha256": _digest("campaign-id"),
        "plan_sha256": _digest("plan"),
        "manifest_before_sha256": (
            fault.ZERO_DIGEST if generation_before == 0 else _digest("manifest-before")
        ),
        "manifest_after_sha256": _digest("manifest-after"),
        "selector_before_wire_sha256": (
            fault.ZERO_DIGEST
            if generation_before == 0
            else hashlib.sha256(selector_before).digest()
        ),
        "selector_after_wire_sha256": hashlib.sha256(selector_after).digest(),
        "canonical_store_before_sha256": _digest("canonical-store-before"),
        "canonical_store_after_sha256": _digest("canonical-store-after"),
        "transition_entry_sha256": _digest("transition-entry"),
        "worker_sha256": _digest("worker"),
        "backend_library_sha256": _digest("backend-library"),
        "campaign_codec_sha256": _digest("campaign-codec"),
        "store_adapter_sha256": _digest("store-adapter"),
        "fault_injector_sha256": _digest("fault-injector"),
        "supervisor_sha256": _digest("supervisor"),
        "offline_verifier_sha256": _digest("offline-verifier"),
        "machine_sha256": _digest("machine"),
        "backend_sha256": _digest("backend"),
        "device_sha256": _digest("device"),
        "placement_sha256": _digest("placement"),
        "filesystem_profile_sha256": _digest("filesystem-profile"),
    }
    return fault.seal_header(result, selector_before, selector_after)


def _case_value(
    header: dict[str, object],
    ordinal: int,
    previous: bytes,
    *,
    object_kind: int,
    operation_kind: int,
    timing: int,
    fault_kind: int,
    error_class: int,
    observed_state: int,
    disposition: int,
    requested: int = 0,
    completed: int = 0,
) -> dict[str, object]:
    errno_fault = fault_kind in (
        fault.FAULT_INJECTED_ERRNO,
        fault.FAULT_PARTIAL_WRITE_ERRNO,
    )
    error_domain = (
        fault.ERROR_DOMAIN_POSIX_ERRNO if errno_fault else fault.ERROR_DOMAIN_NONE
    )
    error_code = (
        fault.POSIX_EIO
        if error_class == fault.ERROR_IO
        else fault.POSIX_ENOSPC
        if error_class == fault.ERROR_STORAGE_FULL
        else 0
    )
    observed_selector = (
        header["selector_before_wire_sha256"]
        if observed_state == fault.SELECTOR_STATE_BEFORE
        else header["selector_after_wire_sha256"]
    )
    raw_store = (
        header["canonical_store_after_sha256"]
        if disposition == fault.RECOVERY_UNCHANGED_AFTER
        else header["canonical_store_before_sha256"]
        if observed_state == fault.SELECTOR_STATE_BEFORE
        else _digest("raw-store-%d" % ordinal)
    )
    value: dict[str, object] = {
        "abi_version": fault.CASE_ABI,
        "encoded_bytes": fault.CASE_BYTES,
        "flags": fault.ALLOWED_FLAGS,
        "ordinal": ordinal,
        "object_kind": object_kind,
        "operation_kind": operation_kind,
        "timing": timing,
        "occurrence": 1,
        "fault_kind": fault_kind,
        "error_class": error_class,
        "native_error_domain": error_domain,
        "native_error_code": error_code,
        "injected_signal": (0 if errno_fault else fault.SIGNAL_KILL),
        "bytes_requested": requested,
        "bytes_completed": completed,
        "child_exit_code_bits": (
            fault.INJECTED_ERRNO_CHILD_EXIT if errno_fault else fault.U64_MAX
        ),
        "child_termination_signal": (0 if errno_fault else fault.SIGNAL_KILL),
        "provenance_bits": (
            fault.ERRNO_PROVENANCE_BITS if errno_fault else fault.SIGNAL_PROVENANCE_BITS
        ),
        "expected_state_mask": 0,
        "observed_selector_state": observed_state,
        "recovered_selector_state": fault.SELECTOR_STATE_AFTER,
        "recovery_disposition": disposition,
        "trigger_count": 1,
        "reserved": 0,
        "case_challenge_sha256": _digest("case-challenge-%d" % ordinal),
        "failpoint_sha256": fault.ZERO_DIGEST,
        "observed_selector_wire_sha256": observed_selector,
        "raw_store_snapshot_sha256": raw_store,
        "recovered_selector_wire_sha256": header["selector_after_wire_sha256"],
        "recovered_store_snapshot_sha256": header["canonical_store_after_sha256"],
        "fault_control_receipt_sha256": _digest("fault-control-receipt-%d" % ordinal),
        "recovery_result_sha256": _digest("recovery-result-%d" % ordinal),
        "previous_case_sha256": previous,
        "case_sha256": fault.ZERO_DIGEST,
    }
    value["expected_state_mask"] = fault.expected_state_mask(value)
    return value


def _fixture() -> tuple[
    dict[str, object],
    bytes,
    bytes,
    list[dict[str, object]],
    bytes,
]:
    before = _selector(
        5,
        manifest_label="manifest-before",
        environment_label="environment-before",
        records=1_250,
        completed=500,
        events=6_250,
    )
    after = _selector(
        6,
        manifest_label="manifest-after",
        environment_label="environment-after",
        records=1_500,
        completed=600,
        events=7_500,
    )
    header = _header(before, after)
    specifications = (
        {
            "object_kind": fault.OBJECT_SEGMENT,
            "operation_kind": fault.OPERATION_CREATE,
            "timing": fault.TIMING_BEFORE,
            "fault_kind": fault.FAULT_INJECTED_ERRNO,
            "error_class": fault.ERROR_IO,
            "observed_state": fault.SELECTOR_STATE_BEFORE,
            "disposition": fault.RECOVERY_CLEANED_TO_AFTER,
        },
        {
            "object_kind": fault.OBJECT_ENVIRONMENT,
            "operation_kind": fault.OPERATION_WRITE,
            "timing": fault.TIMING_AFTER,
            "fault_kind": fault.FAULT_PARTIAL_WRITE_ERRNO,
            "error_class": fault.ERROR_STORAGE_FULL,
            "observed_state": fault.SELECTOR_STATE_BEFORE,
            "disposition": fault.RECOVERY_CLEANED_TO_AFTER,
            "requested": 4_096,
            "completed": 1_024,
        },
        {
            "object_kind": fault.OBJECT_SELECTOR,
            "operation_kind": fault.OPERATION_REPLACE,
            "timing": fault.TIMING_AFTER,
            "fault_kind": fault.FAULT_INJECTED_ERRNO,
            "error_class": fault.ERROR_IO,
            "observed_state": fault.SELECTOR_STATE_BEFORE,
            "disposition": fault.RECOVERY_CLEANED_TO_AFTER,
        },
        {
            "object_kind": fault.OBJECT_SELECTOR,
            "operation_kind": fault.OPERATION_REPLACE,
            "timing": fault.TIMING_AFTER,
            "fault_kind": fault.FAULT_FORCED_SIGNAL,
            "error_class": fault.ERROR_NONE,
            "observed_state": fault.SELECTOR_STATE_AFTER,
            "disposition": fault.RECOVERY_UNCHANGED_AFTER,
        },
        {
            "object_kind": fault.OBJECT_STORE_ROOT,
            "operation_kind": fault.OPERATION_DIRECTORY_SYNC,
            "timing": fault.TIMING_AFTER,
            "fault_kind": fault.FAULT_INJECTED_ERRNO,
            "error_class": fault.ERROR_STORAGE_FULL,
            "observed_state": fault.SELECTOR_STATE_AFTER,
            "disposition": fault.RECOVERY_CLEANED_TO_AFTER,
        },
    )
    cases: list[dict[str, object]] = []
    previous = fault.ZERO_DIGEST
    for ordinal, specification in enumerate(specifications):
        value = _case_value(
            header,
            ordinal,
            previous,
            **specification,
        )
        sealed = fault.seal_case(header, value)
        cases.append(sealed)
        previous = sealed["case_sha256"]  # type: ignore[assignment]
    wire = fault.make_report(header, before, after, cases)
    return header, before, after, cases, wire


def _initial_fixture() -> bytes:
    before = bytes(fault.SELECTOR_BYTES)
    after = _selector(
        1,
        manifest_label="manifest-after",
        environment_label="environment-after",
        records=250,
        completed=100,
        events=1_250,
    )
    counts = _counts(
        case_count=1,
        errno=0,
        signal=1,
        expected_before=1,
        expected_after=0,
        expected_either=0,
        observed_before=1,
        observed_after=0,
    )
    header = _header(
        before,
        after,
        generation_before=0,
        generation_after=1,
        counts=counts,
    )
    value = _case_value(
        header,
        0,
        fault.ZERO_DIGEST,
        object_kind=fault.OBJECT_SELECTOR,
        operation_kind=fault.OPERATION_CREATE,
        timing=fault.TIMING_AFTER,
        fault_kind=fault.FAULT_FORCED_SIGNAL,
        error_class=fault.ERROR_NONE,
        observed_state=fault.SELECTOR_STATE_BEFORE,
        disposition=fault.RECOVERY_CLEANED_TO_AFTER,
    )
    case = fault.seal_case(header, value)
    return fault.make_report(header, before, after, [case])


class NativeWorkloadStoreFaultReportTests(unittest.TestCase):
    def test_five_vector_golden_layout_roots_and_roundtrip(self) -> None:
        header, before, after, cases, wire = _fixture()
        decoded = fault.verify_report(wire)
        self.assertEqual(3_968, len(wire))
        self.assertEqual(fault.HEADER_BYTES, 960)
        self.assertEqual(fault.CASE_BYTES, 512)
        self.assertEqual(fault.FIXED_BYTES, 1_408)
        self.assertEqual(header, decoded["header"])
        self.assertEqual(before, decoded["selector_before_wire"])
        self.assertEqual(after, decoded["selector_after_wire"])
        self.assertEqual(cases, decoded["cases"])
        self.assertEqual(fault.EXPECTED_AFTER, cases[4]["expected_state_mask"])
        self.assertEqual(
            "bd502cf19ee722379fb0ceceeabf6402973d312aa0e5984cceb10bea0e24b6b8",
            header["matrix_id_sha256"].hex(),  # type: ignore[union-attr]
        )
        self.assertEqual(
            "a88e145fe22062f0f9ae6eb89906c40ad71ffc23b6572d2fda77f6b777f507d3",
            decoded["body_sha256"].hex(),
        )
        self.assertEqual(
            "e8332398aa0552e2d5ec99f134e27fbc50e9750e8c32d18ded011ebc14271f56",
            decoded["report_sha256"].hex(),
        )
        self.assertEqual(
            "63742152cbba93d2b935e397b7353138c1d0c472f920899f707237f49a5a35fc",
            hashlib.sha256(wire).hexdigest(),
        )
        self.assertEqual(
            (
                "418222cda9341d87f4252e9afe1a531c502d9e5c1fbd525b9d60ebe9120529b8",
                "7747a4ca1c50883c7fc52f13560fc56c4a8dfc3da6c7013cba7a38a0ea7de5ab",
                "03627c9d7f7567e293b7ff0c31e6d24d8d16b67b80013e8018577349ea563992",
                "85644252502d5cbdcd70eafd8289f9478ad43c0f1a611f5be3468ec3c85b3d3c",
                "ade1bf2cce3fe530a1f48432f669256ab6e083afa10a62a49648bac49d7d9f5f",
            ),
            tuple(
                case["case_sha256"].hex()  # type: ignore[union-attr]
                for case in cases
            ),
        )
        self.assertEqual(
            (
                "95ae648f24a90f4fa5d84b35f60db93f30eff014def7dab6e96d5e956596179c",
                "57355ba8fa646dd8164e24cc420e3c40a4062965771b0e1143b64304ffb8c8de",
                "befb46e5c9011886bb934f5a6ce400fa82c856ad54cefffc47692e3b480a645a",
                "d0cf1afcfd0de2994ad79c869ac1a2ff1a2c1a430621c86d408f2b2c366ab11f",
                "6f1beeda70753cbaa6153ea5e1b6020637c5a21c47bc294a3ac4f65909772eb2",
            ),
            tuple(
                case["failpoint_sha256"].hex()  # type: ignore[union-attr]
                for case in cases
            ),
        )

    def test_every_wire_byte_mutation_rejects(self) -> None:
        wire = _fixture()[-1]
        for offset in range(len(wire)):
            mutated = bytearray(wire)
            mutated[offset] ^= 1
            with self.assertRaises(
                fault.StoreFaultReportError,
                msg="offset %d" % offset,
            ):
                fault.verify_report(bytes(mutated))

    def test_every_truncation_and_trailing_byte_rejects(self) -> None:
        wire = _fixture()[-1]
        for length in range(len(wire)):
            with self.assertRaises(fault.StoreFaultReportError):
                fault.verify_report(wire[:length])
        with self.assertRaises(fault.StoreFaultReportError):
            fault.verify_report(wire + b"\x00")

    def test_case_swap_drop_duplicate_and_chain_mutations_reject(self) -> None:
        header, before, after, cases, wire = _fixture()
        swapped = list(cases)
        swapped[1], swapped[2] = swapped[2], swapped[1]
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "ordinal",
        ):
            fault.make_report(header, before, after, swapped)
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "length",
        ):
            fault.make_report(header, before, after, cases[:-1])
        duplicated = list(cases)
        duplicated[1] = duplicated[0]
        with self.assertRaises(fault.StoreFaultReportError):
            fault.make_report(header, before, after, duplicated)
        dropped_wire = wire[: fault.HEADER_BYTES + 2 * fault.SELECTOR_BYTES]
        dropped_wire += wire[
            fault.HEADER_BYTES + 2 * fault.SELECTOR_BYTES + fault.CASE_BYTES :
        ]
        with self.assertRaises(fault.StoreFaultReportError):
            fault.verify_report(dropped_wire)
        changed = dict(cases[2])
        changed["previous_case_sha256"] = fault.ZERO_DIGEST
        changed["case_sha256"] = fault.derive_case_sha256(
            header["matrix_id_sha256"],  # type: ignore[arg-type]
            changed,
        )
        chained = list(cases)
        chained[2] = changed
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "predecessor",
        ):
            fault.make_report(header, before, after, chained)

    def test_logically_duplicate_failpoint_rejects_after_coherent_reseal(
        self,
    ) -> None:
        header, before, after, cases, _wire = _fixture()
        duplicate_value = dict(cases[2])
        duplicate_value.update(
            {
                "ordinal": 4,
                "case_challenge_sha256": _digest("logical-duplicate-challenge"),
                "fault_control_receipt_sha256": _digest("logical-duplicate-control"),
                "recovery_result_sha256": _digest("logical-duplicate-recovery"),
                "observed_selector_state": fault.SELECTOR_STATE_AFTER,
                "observed_selector_wire_sha256": header["selector_after_wire_sha256"],
                "raw_store_snapshot_sha256": _digest("logical-duplicate-raw-store"),
                "previous_case_sha256": cases[3]["case_sha256"],
                "failpoint_sha256": fault.ZERO_DIGEST,
                "case_sha256": fault.ZERO_DIGEST,
            }
        )
        duplicate = fault.seal_case(header, duplicate_value)
        self.assertNotEqual(
            cases[2]["case_challenge_sha256"],
            duplicate["case_challenge_sha256"],
        )
        self.assertNotEqual(
            cases[2]["ordinal"],
            duplicate["ordinal"],
        )
        self.assertNotEqual(
            cases[2]["observed_selector_state"],
            duplicate["observed_selector_state"],
        )
        self.assertEqual(
            cases[2]["failpoint_sha256"],
            duplicate["failpoint_sha256"],
        )
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "failpoint.*not unique",
        ):
            fault.make_report(
                header,
                before,
                after,
                [*cases[:4], duplicate],
            )

    def test_receipt_identities_reject_duplicates_after_coherent_reseal(
        self,
    ) -> None:
        header, before, after, cases, _wire = _fixture()
        for field in (
            "fault_control_receipt_sha256",
            "recovery_result_sha256",
        ):
            with self.subTest(field=field):
                values = [dict(case) for case in cases]
                values[4][field] = values[0][field]
                previous = fault.ZERO_DIGEST
                resealed: list[dict[str, object]] = []
                for value in values:
                    value["failpoint_sha256"] = fault.ZERO_DIGEST
                    value["previous_case_sha256"] = previous
                    value["case_sha256"] = fault.ZERO_DIGEST
                    sealed = fault.seal_case(header, value)
                    resealed.append(sealed)
                    previous = sealed["case_sha256"]  # type: ignore[assignment]
                with self.assertRaisesRegex(
                    fault.StoreFaultReportError,
                    "%s.*not unique" % field,
                ):
                    fault.make_report(
                        header,
                        before,
                        after,
                        resealed,
                    )

    def test_object_operation_and_partial_write_matrix_is_strict(self) -> None:
        header, _before, _after, cases, _wire = _fixture()
        invalid_pairs = (
            (fault.OBJECT_SEGMENT, fault.OPERATION_REPLACE),
            (fault.OBJECT_SELECTOR, fault.OPERATION_LINK),
            (fault.OBJECT_SELECTOR, fault.OPERATION_UNLINK),
            (fault.OBJECT_STORE_ROOT, fault.OPERATION_WRITE),
            (fault.OBJECT_STORE_ROOT, fault.OPERATION_UNLINK),
        )
        for object_kind, operation_kind in invalid_pairs:
            with self.subTest(
                object_kind=object_kind,
                operation_kind=operation_kind,
            ):
                value = _case_value(
                    header,
                    0,
                    fault.ZERO_DIGEST,
                    object_kind=object_kind,
                    operation_kind=operation_kind,
                    timing=fault.TIMING_BEFORE,
                    fault_kind=fault.FAULT_INJECTED_ERRNO,
                    error_class=fault.ERROR_IO,
                    observed_state=fault.SELECTOR_STATE_BEFORE,
                    disposition=fault.RECOVERY_CLEANED_TO_AFTER,
                )
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_case(header, value)
        for object_kind in (
            fault.OBJECT_SEGMENT,
            fault.OBJECT_ENVIRONMENT,
            fault.OBJECT_MANIFEST,
        ):
            with self.subTest(unlink_object_kind=object_kind):
                value = _case_value(
                    header,
                    0,
                    fault.ZERO_DIGEST,
                    object_kind=object_kind,
                    operation_kind=fault.OPERATION_UNLINK,
                    timing=fault.TIMING_AFTER,
                    fault_kind=fault.FAULT_FORCED_SIGNAL,
                    error_class=fault.ERROR_NONE,
                    observed_state=fault.SELECTOR_STATE_BEFORE,
                    disposition=fault.RECOVERY_CLEANED_TO_AFTER,
                )
                fault.seal_case(header, value)
        partial = dict(cases[1])
        for field, value in (
            ("timing", fault.TIMING_BEFORE),
            ("bytes_completed", 0),
            ("bytes_completed", partial["bytes_requested"]),
            ("operation_kind", fault.OPERATION_FILE_SYNC),
        ):
            with self.subTest(field=field, value=value):
                changed = dict(partial)
                changed[field] = value
                changed["failpoint_sha256"] = fault.ZERO_DIGEST
                changed["case_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_case(header, changed)
        for occurrence in (0, 3):
            with self.subTest(write_occurrence=occurrence):
                changed = dict(partial)
                changed["occurrence"] = occurrence
                changed["failpoint_sha256"] = fault.ZERO_DIGEST
                changed["case_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_case(header, changed)
        nonwrite = dict(cases[0])
        nonwrite["occurrence"] = 2
        nonwrite["failpoint_sha256"] = fault.ZERO_DIGEST
        nonwrite["case_sha256"] = fault.ZERO_DIGEST
        with self.assertRaises(fault.StoreFaultReportError):
            fault.seal_case(header, nonwrite)

    def test_errno_class_domain_code_exit_signal_and_provenance_are_exact(
        self,
    ) -> None:
        header, _before, _after, cases, _wire = _fixture()
        baseline = cases[0]
        mutations = (
            ("error_class", fault.ERROR_STORAGE_FULL),
            ("native_error_domain", fault.ERROR_DOMAIN_NONE),
            ("native_error_code", fault.POSIX_ENOSPC),
            ("injected_signal", fault.SIGNAL_KILL),
            ("child_exit_code_bits", 0),
            ("child_termination_signal", fault.SIGNAL_KILL),
            ("provenance_bits", fault.SIGNAL_PROVENANCE_BITS),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                changed = dict(baseline)
                changed[field] = value
                changed["failpoint_sha256"] = fault.ZERO_DIGEST
                changed["case_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_case(header, changed)

    def test_signal_error_exit_and_provenance_are_exact(self) -> None:
        header, _before, _after, cases, _wire = _fixture()
        baseline = cases[3]
        mutations = (
            ("error_class", fault.ERROR_IO),
            ("native_error_domain", fault.ERROR_DOMAIN_POSIX_ERRNO),
            ("native_error_code", fault.POSIX_EIO),
            ("injected_signal", 15),
            ("child_exit_code_bits", 137),
            ("child_termination_signal", 15),
            ("provenance_bits", fault.ERRNO_PROVENANCE_BITS),
            ("bytes_requested", 1),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                changed = dict(baseline)
                changed[field] = value
                changed["failpoint_sha256"] = fault.ZERO_DIGEST
                changed["case_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_case(header, changed)

    def test_expected_observed_recovered_and_disposition_matrix_is_strict(
        self,
    ) -> None:
        header, _before, _after, cases, _wire = _fixture()
        mutations = (
            (0, "expected_state_mask", fault.EXPECTED_EITHER),
            (0, "observed_selector_state", fault.SELECTOR_STATE_AFTER),
            (0, "recovered_selector_state", fault.SELECTOR_STATE_BEFORE),
            (0, "recovery_disposition", fault.RECOVERY_UNCHANGED_BEFORE),
            (
                0,
                "recovered_selector_wire_sha256",
                header["selector_before_wire_sha256"],
            ),
            (
                0,
                "recovered_store_snapshot_sha256",
                header["canonical_store_before_sha256"],
            ),
            (
                3,
                "raw_store_snapshot_sha256",
                header["canonical_store_before_sha256"],
            ),
            (
                4,
                "raw_store_snapshot_sha256",
                header["canonical_store_after_sha256"],
            ),
        )
        for index, field, value in mutations:
            with self.subTest(index=index, field=field):
                changed = dict(cases[index])
                changed[field] = value
                changed["failpoint_sha256"] = fault.ZERO_DIGEST
                changed["case_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_case(header, changed)
        store_root_before = dict(cases[4])
        store_root_before.update(
            {
                "observed_selector_state": fault.SELECTOR_STATE_BEFORE,
                "observed_selector_wire_sha256": header["selector_before_wire_sha256"],
                "raw_store_snapshot_sha256": header["canonical_store_before_sha256"],
                "failpoint_sha256": fault.ZERO_DIGEST,
                "case_sha256": fault.ZERO_DIGEST,
            }
        )
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "outside the expected mask",
        ):
            fault.seal_case(header, store_root_before)

    def test_header_counts_bounds_roots_and_selectors_are_strict(self) -> None:
        header, before, after, cases, _wire = _fixture()
        scalar_mutations = (
            ("flags", 1),
            ("case_count", 4),
            ("case_bytes", fault.CASE_BYTES + 1),
            ("selector_bytes", fault.SELECTOR_BYTES + 1),
            ("generation_after", 7),
            ("failpoint_count", 4),
            ("errno_case_count", 3),
            ("recovered_before_count", 1),
            ("recovered_after_count", 4),
            ("synthetic_fault_count", 5),
            ("real_signal_count", 0),
            ("store_max_bytes", 0),
            ("store_max_files", 0),
            ("total_trigger_count", 4),
            ("reserved", 1),
        )
        for field, value in scalar_mutations:
            with self.subTest(field=field):
                changed = dict(header)
                changed[field] = value
                changed["matrix_id_sha256"] = fault.ZERO_DIGEST
                try:
                    resealed = fault.seal_header(changed, before, after)
                except fault.StoreFaultReportError:
                    continue
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.make_report(resealed, before, after, cases)
        for field in (
            "matrix_challenge_sha256",
            "schedule_sha256",
            "campaign_id_sha256",
            "plan_sha256",
            "canonical_store_after_sha256",
            "worker_sha256",
            "filesystem_profile_sha256",
        ):
            with self.subTest(field=field):
                changed = dict(header)
                changed[field] = fault.ZERO_DIGEST
                changed["matrix_id_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_header(changed, before, after)
        mutated_selector = bytearray(after)
        mutated_selector[-1] ^= 1
        changed = dict(header)
        changed["matrix_id_sha256"] = fault.ZERO_DIGEST
        changed["selector_after_wire_sha256"] = hashlib.sha256(
            mutated_selector
        ).digest()
        with self.assertRaises(fault.StoreFaultReportError):
            fault.seal_header(changed, before, bytes(mutated_selector))

    def test_selector_transition_authority_segment_and_totals_are_strict(
        self,
    ) -> None:
        header, before, _after, _cases, _wire = _fixture()
        invalid_after = (
            _selector(
                6,
                manifest_label="manifest-after",
                environment_label="environment-after",
                records=1_500,
                completed=600,
                events=7_500,
                authority_label="other-authority",
            ),
            _selector(
                6,
                manifest_label="manifest-after",
                environment_label="environment-after",
                records=1_500,
                completed=600,
                events=7_500,
                segment_count=13,
            ),
            _selector(
                6,
                manifest_label="manifest-after",
                environment_label="environment-after",
                records=1_250,
                completed=600,
                events=7_500,
            ),
        )
        for after in invalid_after:
            changed = dict(header)
            changed["matrix_id_sha256"] = fault.ZERO_DIGEST
            changed["selector_after_wire_sha256"] = hashlib.sha256(after).digest()
            with self.assertRaises(fault.StoreFaultReportError):
                fault.seal_header(changed, before, after)

    def test_initial_generation_absence_sentinel_rolls_forward(self) -> None:
        wire = _initial_fixture()
        decoded = fault.verify_report(wire)
        header = decoded["header"]
        case = decoded["cases"][0]
        self.assertEqual(0, header["generation_before"])
        self.assertEqual(1, header["generation_after"])
        self.assertEqual(
            bytes(fault.SELECTOR_BYTES),
            decoded["selector_before_wire"],
        )
        self.assertEqual(
            fault.ZERO_DIGEST,
            header["manifest_before_sha256"],
        )
        self.assertEqual(
            fault.ZERO_DIGEST,
            case["observed_selector_wire_sha256"],
        )
        self.assertEqual(
            fault.SELECTOR_STATE_AFTER,
            case["recovered_selector_state"],
        )

    def test_initial_transition_rejects_nonzero_predecessor_sentinels(
        self,
    ) -> None:
        before = bytes(fault.SELECTOR_BYTES)
        after = _selector(
            1,
            manifest_label="manifest-after",
            environment_label="environment-after",
            records=250,
            completed=100,
            events=1_250,
        )
        counts = _counts(
            case_count=1,
            errno=0,
            signal=1,
            expected_before=1,
            expected_after=0,
            expected_either=0,
            observed_before=1,
            observed_after=0,
        )
        values = _header(
            before,
            after,
            generation_before=0,
            generation_after=1,
            counts=counts,
        )
        for field in (
            "manifest_before_sha256",
            "selector_before_wire_sha256",
        ):
            with self.subTest(field=field):
                changed = dict(values)
                changed[field] = _digest("forged-predecessor")
                changed["matrix_id_sha256"] = fault.ZERO_DIGEST
                with self.assertRaises(fault.StoreFaultReportError):
                    fault.seal_header(changed, before, after)

    def test_field_sets_u64_ranges_and_case_bound_are_strict(self) -> None:
        header, before, after, cases, _wire = _fixture()
        missing = dict(header)
        missing.pop("schedule_sha256")
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "canonical",
        ):
            fault.make_report(missing, before, after, cases)
        extra = dict(cases[0])
        extra["future"] = 0
        with self.assertRaisesRegex(
            fault.StoreFaultReportError,
            "canonical",
        ):
            fault.seal_case(header, extra)
        negative = dict(cases[0])
        negative["occurrence"] = -1
        with self.assertRaises(fault.StoreFaultReportError):
            fault.seal_case(header, negative)
        self.assertEqual(
            1_408 + 128 * 512,
            fault.encoded_report_bytes(128),
        )
        for count in (0, 129):
            with self.assertRaises(fault.StoreFaultReportError):
                fault.encoded_report_bytes(count)


if __name__ == "__main__":
    unittest.main()
