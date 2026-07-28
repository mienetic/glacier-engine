from __future__ import annotations

import ast
from dataclasses import replace
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

from bench import native_metal_soak_report as production_store
from bench import native_workload_store_fault_campaign as store_fault
from bench import native_workload_store_fault_report as fault_report
from bench.tests import test_native_workload_store_fault_report as report_fixture


def _tree_sha256(root: Path) -> bytes:
    records: list[bytes] = []
    for directory, subdirectories, files in os.walk(
        root,
        followlinks=False,
    ):
        subdirectories.sort()
        files.sort()
        directory_path = Path(directory)
        for name in (*subdirectories, *files):
            path = directory_path / name
            info = path.lstat()
            relative = path.relative_to(root).as_posix().encode("utf-8")
            if stat.S_ISREG(info.st_mode):
                payload = path.read_bytes()
            elif stat.S_ISLNK(info.st_mode):
                payload = os.readlink(path).encode("utf-8")
            else:
                payload = b""
            records.append(
                b"\0".join(
                    (
                        relative,
                        str(stat.S_IFMT(info.st_mode)).encode("ascii"),
                        str(stat.S_IMODE(info.st_mode)).encode("ascii"),
                        str(info.st_nlink).encode("ascii"),
                        hashlib.sha256(payload).digest(),
                    )
                )
            )
    return hashlib.sha256(b"\n".join(records)).digest()


def _report_receipt(encoded: bytes) -> dict[str, object]:
    return {
        "schema": "glacier.native-workload-store-fault/report-verifier-v1",
        "case_count": 81,
        "encoded_bytes": len(encoded),
        "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
        "generation_before": 1,
        "generation_after": 2,
        "matrix_challenge_sha256": "11" * 32,
        "matrix_id_sha256": "22" * 32,
        "report_sha256": "33" * 32,
        "verified": True,
    }


def _completed_json(value: dict[str, object]) -> mock.Mock:
    return mock.Mock(
        returncode=0,
        stdout=json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        stderr="",
    )


def _source_component_paths(root: Path) -> dict[str, Path]:
    return {name: root / ("%s.py" % name) for name in store_fault.SOURCE_COMPONENT_KEYS}


def _bench_python_import_closure(entrypoint: Path) -> set[Path]:
    source_root = entrypoint.parent
    module_paths = {
        "bench.%s" % path.stem: path.resolve() for path in source_root.glob("*.py")
    }
    pending = [entrypoint.resolve()]
    closure: set[Path] = set()
    while pending:
        path = pending.pop()
        if path in closure:
            continue
        closure.add(path)
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        imported_modules: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported_modules.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.module == "bench":
                    imported_modules.update(
                        "bench.%s" % alias.name for alias in node.names
                    )
                elif node.module is not None:
                    imported_modules.add(node.module)
        pending.extend(
            module_paths[name]
            for name in sorted(imported_modules)
            if name in module_paths and module_paths[name] not in closure
        )
    return closure


def _source_commitment_report(
    snapshot: dict[str, bytes],
) -> tuple[bytes, bytes]:
    base_header, before, after, base_cases, _wire = report_fixture._fixture()
    header_seed = dict(base_header)
    header_seed["matrix_id_sha256"] = fault_report.ZERO_DIGEST
    header_seed.update(store_fault._report_source_identities(snapshot))
    header = fault_report.seal_header(header_seed, before, after)
    cases: list[dict[str, object]] = []
    previous = fault_report.ZERO_DIGEST
    for base_case in base_cases:
        case_seed = dict(base_case)
        case_seed["failpoint_sha256"] = fault_report.ZERO_DIGEST
        case_seed["previous_case_sha256"] = previous
        case_seed["case_sha256"] = fault_report.ZERO_DIGEST
        sealed = fault_report.seal_case(header, case_seed)
        cases.append(sealed)
        previous = sealed["case_sha256"]  # type: ignore[assignment]
    encoded = fault_report.make_report(header, before, after, cases)
    decoded = fault_report.verify_report(encoded)
    return header["matrix_id_sha256"], decoded["report_sha256"]  # type: ignore[return-value]


def _synthetic_report_input() -> dict[str, object]:
    prepared = store_fault.prepare_publication()
    canonical_before = hashlib.sha256(b"synthetic-canonical-before").digest()
    canonical_after = hashlib.sha256(b"synthetic-canonical-after").digest()
    source_snapshot = {
        name: hashlib.sha256(("synthetic-" + name).encode("ascii")).digest()
        for name in store_fault.SOURCE_COMPONENT_KEYS
    }
    records: list[dict[str, object]] = []
    previous_case = store_fault.ZERO_DIGEST
    coordinates: list[tuple[str, store_fault.PublicationPhase | None]] = [
        (fault_mode, phase)
        for fault_mode in store_fault.FAULT_MODES
        for phase in store_fault.PHASES
    ]
    coordinates.append((store_fault.FAULT_NONE, None))
    for ordinal, (fault_mode, phase) in enumerate(coordinates):
        if phase is None:
            expected_generation = 2
            phase_id = 0
            phase_name = "clean-control"
            object_kind = "transaction"
            operation = "complete"
            exit_code = 0
            termination_signal = 0
        else:
            expected_generation = store_fault.expected_raw_generation(
                phase.phase_id,
                fault_mode,
            )
            phase_id = phase.phase_id
            phase_name = phase.name
            object_kind = phase.object_kind
            operation = phase.operation
            exit_code = (
                store_fault.U64_MAX
                if fault_mode == store_fault.FAULT_SIGKILL
                else store_fault.CHILD_INJECTED_ERRNO_EXIT
            )
            termination_signal = (
                int(store_fault.signal.SIGKILL)
                if fault_mode == store_fault.FAULT_SIGKILL
                else 0
            )
        raw_shape = (
            canonical_after
            if expected_generation == 2
            else hashlib.sha256(
                b"synthetic-raw-shape-" + ordinal.to_bytes(8, "little")
            ).digest()
        )
        core: dict[str, object] = {
            "case_ordinal": ordinal,
            "fault_mode": fault_mode,
            "phase_id": phase_id,
            "phase_name": phase_name,
            "object_kind": object_kind,
            "operation": operation,
            "expected_raw_generation": expected_generation,
            "observed_raw_generation": expected_generation,
            "writer_exit_code_bits": exit_code,
            "writer_termination_signal": termination_signal,
            "first_recovery_disposition": (
                "applied" if expected_generation == 1 else "already_applied"
            ),
            "second_recovery_disposition": "already_applied",
            "known_residue_files": 0,
            "known_residue_bytes": 0,
            "raw_shape_sha256": raw_shape,
            "final_shape_sha256": canonical_after,
            "final_manifest_sha256": prepared.successor_manifest_sha256,
            "final_selector_sha256": prepared.successor_selector_sha256,
            "final_entry_sha256": prepared.fixture.entries[1]["entry_sha256"],
            "transaction_sha256": prepared.transaction_sha256,
            "previous_case_sha256": previous_case,
        }
        case_sha256 = store_fault._case_root(core)
        record = dict(core)
        record["case_sha256"] = case_sha256
        records.append(record)
        previous_case = case_sha256
    matrix_sha256 = store_fault._hash_parts(
        store_fault.MATRIX_DOMAIN,
        prepared.fixture.fixture_sha256,
        prepared.transaction_sha256,
        b"".join(record["case_sha256"] for record in records),
    )
    result: dict[str, object] = {
        "schema": "glacier.native-workload-store-fault/report-input-v1",
        "fixture_sha256": prepared.fixture.fixture_sha256,
        "campaign_id_sha256": prepared.fixture.plan["campaign_id_sha256"],
        "plan_sha256": prepared.plan_sha256,
        "transaction_sha256": prepared.transaction_sha256,
        "previous_manifest_sha256": prepared.previous_manifest_sha256,
        "successor_manifest_sha256": prepared.successor_manifest_sha256,
        "previous_selector_sha256": prepared.previous_selector_sha256,
        "successor_selector_sha256": prepared.successor_selector_sha256,
        "records": records,
        "fault_cases": 81,
        "clean_controls": 1,
        "sigkill_cases": 27,
        "eio_cases": 27,
        "enospc_cases": 27,
        "first_recovery_applied": 77,
        "first_recovery_already_applied": 5,
        "raw_previous_generations": 77,
        "raw_successor_generations": 5,
        "second_recovery_already_applied": 82,
        "strict_verified_cases": 82,
        "final_case_sha256": previous_case,
        "matrix_sha256": matrix_sha256,
        "canonical_store_before_sha256": canonical_before,
        "canonical_store_after_sha256": canonical_after,
        "machine_sha256": hashlib.sha256(b"synthetic-machine").digest(),
        "filesystem_profile_sha256": hashlib.sha256(b"synthetic-filesystem").digest(),
        "source_snapshot": source_snapshot,
        "source_snapshot_sha256": store_fault._source_snapshot_sha256(source_snapshot),
        "host_process_execution": True,
        "host_filesystem_operations": True,
        "workload_execution": False,
        "gpu_execution": False,
        "synthetic_errno": True,
        "physical_storage_fault": False,
        "power_loss_emulated": False,
    }
    result["report_input_sha256"] = store_fault._hash_parts(
        store_fault.REPORT_CHALLENGE_DOMAIN,
        store_fault._canonical_record_bytes(result),
    )
    store_fault.verify_report_input_v1(result)
    return result


def _coherently_reseal_campaign_report(
    encoded: bytes,
    *,
    header_updates: dict[str, object] | None = None,
    case_updates: dict[int, dict[str, object]] | None = None,
) -> bytes:
    decoded = fault_report.verify_report(encoded)
    header_seed = dict(decoded["header"])
    if header_updates is not None:
        header_seed.update(header_updates)
    header_seed["matrix_id_sha256"] = fault_report.ZERO_DIGEST
    header = fault_report.seal_header(
        header_seed,
        decoded["selector_before_wire"],
        decoded["selector_after_wire"],
    )
    cases: list[dict[str, object]] = []
    previous_case = fault_report.ZERO_DIGEST
    updates = {} if case_updates is None else case_updates
    for ordinal, original in enumerate(decoded["cases"]):
        case_seed = dict(original)
        case_seed.update(updates.get(ordinal, {}))
        case_seed["failpoint_sha256"] = fault_report.ZERO_DIGEST
        case_seed["previous_case_sha256"] = previous_case
        case_seed["case_sha256"] = fault_report.ZERO_DIGEST
        sealed = fault_report.seal_case(header, case_seed)
        cases.append(sealed)
        previous_case = sealed["case_sha256"]  # type: ignore[assignment]
    return fault_report.make_report(
        header,
        decoded["selector_before_wire"],
        decoded["selector_after_wire"],
        cases,
    )


class NativeWorkloadStoreFaultCampaignTests(unittest.TestCase):
    def test_fixed_prepared_transition_and_phase_table(self) -> None:
        prepared = store_fault.prepare_publication()
        store_fault.validate_prepared_publication(prepared)
        self.assertEqual(27, len(store_fault.PHASES))
        self.assertEqual(
            tuple(range(1, 28)),
            tuple(phase.phase_id for phase in store_fault.PHASES),
        )
        self.assertEqual(
            ("store_root", "directory_sync"),
            (
                store_fault.PHASES[-1].object_kind,
                store_fault.PHASES[-1].operation,
            ),
        )
        self.assertEqual(1, prepared.previous_generation)
        self.assertEqual(2, prepared.successor_generation)
        self.assertNotEqual(
            prepared.previous_selector_sha256,
            prepared.successor_selector_sha256,
        )

    def test_clean_publication_and_repeat_recovery_are_exact(self) -> None:
        prepared = store_fault.prepare_publication()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            store_fault.create_seed_store(root, prepared)
            before = store_fault.verify_store(
                root,
                prepared,
                generation=1,
            )
            self.assertEqual(1, before["selected_generation"])
            self.assertEqual((0, 0), store_fault._clean_writer(root))
            first = store_fault._fresh_recover(root)
            second = store_fault._fresh_recover(root)
            after = store_fault._fresh_verify(root)
            self.assertEqual("already_applied", first["disposition"])
            self.assertEqual("already_applied", second["disposition"])
            self.assertEqual(2, after["selected_generation"])
            self.assertEqual(
                prepared.transaction_sha256.hex(),
                after["transaction_sha256"],
            )

    def test_representative_real_signal_and_errno_cases_converge(
        self,
    ) -> None:
        prepared = store_fault.prepare_publication()
        cases = (
            (1, store_fault.FAULT_EIO, 1),
            (26, store_fault.FAULT_SIGKILL, 2),
            (27, store_fault.FAULT_ENOSPC, 2),
        )
        with tempfile.TemporaryDirectory() as directory:
            for phase_id, fault_mode, expected_generation in cases:
                with self.subTest(
                    phase_id=phase_id,
                    fault_mode=fault_mode,
                ):
                    root = Path(directory) / ("case-%02d-%s" % (phase_id, fault_mode))
                    store_fault.create_seed_store(root, prepared)
                    store_fault._writer_case(
                        root,
                        store_fault.PHASE_BY_ID[phase_id],
                        fault_mode,
                    )
                    first = store_fault._fresh_recover(root)
                    second = store_fault._fresh_recover(root)
                    strict = store_fault._fresh_verify(root)
                    self.assertEqual(
                        expected_generation,
                        first["raw_generation"],
                    )
                    self.assertEqual(
                        ("applied" if expected_generation == 1 else "already_applied"),
                        first["disposition"],
                    )
                    self.assertEqual(
                        "already_applied",
                        second["disposition"],
                    )
                    self.assertEqual(2, strict["selected_generation"])

    def test_unknown_root_entry_fails_closed_without_mutation(self) -> None:
        prepared = store_fault.prepare_publication()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            store_fault.create_seed_store(root, prepared)
            foreign = root / "foreign"
            foreign.write_bytes(b"foreign")
            foreign.chmod(store_fault.FILE_MODE)
            before = _tree_sha256(root)
            with self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "unknown or missing",
            ):
                store_fault.recover_store(root, prepared)
            self.assertEqual(before, _tree_sha256(root))

    def test_corrupt_candidate_fails_closed_without_mutation(self) -> None:
        prepared = store_fault.prepare_publication()
        spec = prepared.object_specs[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            store_fault.create_seed_store(root, prepared)
            target = root / spec.directory_name / spec.target_name
            target.write_bytes(b"corrupt")
            target.chmod(store_fault.FILE_MODE)
            before = _tree_sha256(root)
            with self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "target object is corrupt",
            ):
                store_fault.recover_store(root, prepared)
            self.assertEqual(before, _tree_sha256(root))

    def test_symlinked_residue_fails_closed_without_mutation(self) -> None:
        prepared = store_fault.prepare_publication()
        spec = prepared.object_specs[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            outside = Path(directory) / "outside"
            outside.write_bytes(b"outside")
            store_fault.create_seed_store(root, prepared)
            temporary = root / spec.directory_name / spec.temporary_name
            temporary.symlink_to(outside)
            before = _tree_sha256(root)
            outside_before = outside.read_bytes()
            with self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "not a regular file",
            ):
                store_fault.recover_store(root, prepared)
            self.assertEqual(before, _tree_sha256(root))
            self.assertEqual(outside_before, outside.read_bytes())

    def test_foreign_hard_link_and_lock_contention_fail_closed(self) -> None:
        prepared = store_fault.prepare_publication()
        spec = prepared.object_specs[2]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            outside = Path(directory) / "outside-link"
            store_fault.create_seed_store(root, prepared)
            target = root / spec.directory_name / spec.target_name
            target.write_bytes(spec.data)
            target.chmod(store_fault.FILE_MODE)
            os.link(target, outside)
            before = _tree_sha256(root)
            with self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "foreign hard link",
            ):
                store_fault.recover_store(root, prepared)
            self.assertEqual(before, _tree_sha256(root))
            outside.unlink()
            target.unlink()

            with store_fault.StoreLease(root, exclusive=True):
                locked_before = _tree_sha256(root)
                with self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "already locked",
                ):
                    store_fault.recover_store(root, prepared)
                self.assertEqual(locked_before, _tree_sha256(root))

    def test_directory_namespace_swap_is_rejected(self) -> None:
        prepared = store_fault.prepare_publication()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            displaced = Path(directory) / "segments-displaced"
            store_fault.create_seed_store(root, prepared)
            with store_fault.StoreLease(root, exclusive=True) as lease:
                (root / store_fault.SEGMENTS_NAME).rename(displaced)
                (root / store_fault.SEGMENTS_NAME).mkdir(
                    mode=store_fault.DIRECTORY_MODE
                )
                with self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "object-directory namespace changed",
                ):
                    lease.verify_strict(prepared, generation=1)

    def test_rejected_directory_open_closes_untransferred_descriptor(
        self,
    ) -> None:
        prepared = store_fault.prepare_publication()
        real_open = os.open
        real_inspect = store_fault._inspect_private_directory

        def assert_closed(descriptors: list[int]) -> None:
            self.assertEqual(1, len(descriptors))
            with self.assertRaises(OSError) as raised:
                os.fstat(descriptors[0])
            self.assertEqual(errno.EBADF, raised.exception.errno)

        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            root = parent / "malformed-store"
            store_fault.create_seed_store(root, prepared)
            (root / store_fault.SEGMENTS_NAME).chmod(0o755)
            opened: list[int] = []

            def capture_open(
                path: os.PathLike[str] | str,
                flags: int,
                mode: int = 0o777,
                *,
                dir_fd: int | None = None,
            ) -> int:
                descriptor = real_open(
                    path,
                    flags,
                    mode,
                    dir_fd=dir_fd,
                )
                if path == store_fault.SEGMENTS_NAME and dir_fd is not None:
                    opened.append(descriptor)
                return descriptor

            with (
                mock.patch.object(
                    store_fault.os,
                    "open",
                    side_effect=capture_open,
                ),
                self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "owner-private",
                ),
            ):
                store_fault.StoreLease(root, exclusive=True)
            assert_closed(opened)

            forced_root = parent / "forced-seed"
            opened = []

            def reject_first_object_directory(
                descriptor: int,
                expected_device: int | None = None,
            ) -> os.stat_result:
                if expected_device is not None:
                    raise store_fault.StoreFaultCampaignError(
                        "forced directory validation failure"
                    )
                return real_inspect(descriptor, expected_device)

            with (
                mock.patch.object(
                    store_fault.os,
                    "open",
                    side_effect=capture_open,
                ),
                mock.patch.object(
                    store_fault,
                    "_inspect_private_directory",
                    side_effect=reject_first_object_directory,
                ),
                self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "forced directory validation",
                ),
            ):
                store_fault.StoreLease.create_seed(
                    forced_root,
                    prepared,
                )
            assert_closed(opened)

    def test_prepared_open_does_not_recreate_a_missing_lock(self) -> None:
        prepared = store_fault.prepare_publication()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            store_fault.create_seed_store(root, prepared)
            lock = root / store_fault.LOCK_NAME
            lock.unlink()
            with self.assertRaises(FileNotFoundError):
                production_store.CampaignStore.open_prepared(
                    root,
                    expected_active_selector=(prepared.fixture.selector_one),
                    expected_objects=store_fault._expected_object_sets(
                        prepared,
                        generation=1,
                    ),
                )
            self.assertFalse(lock.exists())

    def test_prepared_open_rejects_non_private_directory_without_mutation(
        self,
    ) -> None:
        prepared = store_fault.prepare_publication()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            store_fault.create_seed_store(root, prepared)
            segments = root / store_fault.SEGMENTS_NAME
            segments.chmod(0o755)
            before = _tree_sha256(root)
            with self.assertRaisesRegex(
                production_store.NativeMetalSoakError,
                "private real directory",
            ):
                production_store.CampaignStore.open_prepared(
                    root,
                    expected_active_selector=prepared.fixture.selector_one,
                    expected_objects=store_fault._expected_object_sets(
                        prepared,
                        generation=1,
                    ),
                )
            self.assertEqual(before, _tree_sha256(root))

    def test_prepared_open_rejects_foreign_hard_link_without_mutation(
        self,
    ) -> None:
        prepared = store_fault.prepare_publication()
        spec = prepared.object_specs[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "store"
            outside = Path(directory) / "foreign-link"
            store_fault.create_seed_store(root, prepared)
            expected = store_fault._expected_object_sets(
                prepared,
                generation=1,
            )[spec.directory_name]
            target = root / spec.directory_name / next(iter(expected))
            os.link(target, outside)
            before = _tree_sha256(root)
            with self.assertRaisesRegex(
                production_store.NativeMetalSoakError,
                "private and canonical",
            ):
                production_store.CampaignStore.open_prepared(
                    root,
                    expected_active_selector=prepared.fixture.selector_one,
                    expected_objects=store_fault._expected_object_sets(
                        prepared,
                        generation=1,
                    ),
                )
            self.assertEqual(before, _tree_sha256(root))
            self.assertTrue(outside.exists())

    def test_report_write_failure_removes_prepared_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "report.bin"
            temporary = parent / ".report.bin.prepared-v1.tmp"
            with (
                mock.patch.object(
                    store_fault,
                    "_write_all",
                    side_effect=OSError(errno.EIO, "controlled write failure"),
                ),
                self.assertRaises(OSError),
            ):
                store_fault._write_report_atomic(output, b"report")
            self.assertFalse(output.exists())
            self.assertFalse(temporary.exists())

    def test_minimal_fabricated_report_input_is_rejected(self) -> None:
        fabricated = {
            "schema": ("glacier.native-workload-store-fault/report-input-v1"),
            "records": [],
        }
        with self.assertRaisesRegex(
            store_fault.StoreFaultCampaignError,
            "top-level schema",
        ):
            store_fault.encode_report_v1(fabricated)

    def test_campaign_report_rejects_coherently_resealed_semantic_drift(
        self,
    ) -> None:
        report_input = _synthetic_report_input()
        with mock.patch.object(
            store_fault,
            "_verify_source_components_unchanged",
        ):
            encoded = store_fault.encode_report_v1(report_input)
        store_fault.verify_campaign_report_v1(encoded)

        forged_challenge = _coherently_reseal_campaign_report(
            encoded,
            case_updates={
                0: {
                    "case_challenge_sha256": hashlib.sha256(
                        b"coherently-forged-case-challenge"
                    ).digest()
                }
            },
        )
        fault_report.verify_report(forged_challenge)
        with self.assertRaisesRegex(
            store_fault.StoreFaultCampaignError,
            "case challenge",
        ):
            store_fault.verify_campaign_report_v1(forged_challenge)

        for field, value in (
            ("store_max_bytes", store_fault.STORE_MAX_BYTES + 1),
            ("store_max_files", store_fault.STORE_MAX_FILES + 1),
        ):
            with self.subTest(field=field):
                forged_bound = _coherently_reseal_campaign_report(
                    encoded,
                    header_updates={field: value},
                )
                fault_report.verify_report(forged_bound)
                with self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "header is not the fixed campaign",
                ):
                    store_fault.verify_campaign_report_v1(forged_bound)

    def test_campaign_record_and_report_input_domains_are_distinct(self) -> None:
        report_input = _synthetic_report_input()
        root_input = dict(report_input)
        report_input_sha256 = root_input.pop("report_input_sha256")
        self.assertNotEqual(
            store_fault.CASE_RECORD_DOMAIN,
            fault_report.CASE_DOMAIN,
        )
        self.assertNotEqual(
            store_fault.REPORT_CHALLENGE_DOMAIN,
            store_fault.MATRIX_DOMAIN,
        )
        self.assertEqual(
            report_input_sha256,
            store_fault._hash_parts(
                store_fault.REPORT_CHALLENGE_DOMAIN,
                store_fault._canonical_record_bytes(root_input),
            ),
        )
        self.assertNotEqual(
            report_input_sha256,
            store_fault._hash_parts(
                store_fault.MATRIX_DOMAIN,
                store_fault._canonical_record_bytes(root_input),
            ),
        )
        store_fault.verify_report_input_v1(report_input)

    def test_prepared_authority_mutations_reject_without_store_change(
        self,
    ) -> None:
        prepared = store_fault.prepare_publication()
        forged_object = replace(
            prepared.object_specs[0],
            data=b"x" * len(prepared.object_specs[0].data),
        )
        forged_selector = replace(
            prepared.selector_spec,
            data=bytes([prepared.selector_spec.data[0] ^ 1])
            + prepared.selector_spec.data[1:],
        )
        mutations = (
            (
                "fixture-environment-digest",
                replace(
                    prepared,
                    fixture=replace(
                        prepared.fixture,
                        environment_after_sha256=bytes.fromhex("a1" * 32),
                    ),
                ),
            ),
            (
                "fixture-environment-root",
                replace(
                    prepared,
                    fixture=replace(
                        prepared.fixture,
                        environment_root_two_sha256=bytes.fromhex("a2" * 32),
                    ),
                ),
            ),
            (
                "fixture-root",
                replace(
                    prepared,
                    fixture=replace(
                        prepared.fixture,
                        fixture_sha256=bytes.fromhex("a3" * 32),
                    ),
                ),
            ),
            (
                "plan-root",
                replace(prepared, plan_sha256=bytes.fromhex("a5" * 32)),
            ),
            (
                "object-spec",
                replace(
                    prepared,
                    object_specs=(
                        forged_object,
                        *prepared.object_specs[1:],
                    ),
                ),
            ),
            (
                "selector-spec",
                replace(prepared, selector_spec=forged_selector),
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            for ordinal, (label, mutated) in enumerate(mutations):
                with self.subTest(label=label):
                    root = parent / ("store-%d" % ordinal)
                    store_fault.create_seed_store(root, prepared)
                    before = _tree_sha256(root)
                    with self.assertRaisesRegex(
                        store_fault.StoreFaultCampaignError,
                        "prepared",
                    ):
                        store_fault.verify_store(
                            root,
                            mutated,
                            generation=1,
                        )
                    self.assertEqual(before, _tree_sha256(root))
                    with self.assertRaisesRegex(
                        store_fault.StoreFaultCampaignError,
                        "prepared",
                    ):
                        store_fault.recover_store(root, mutated)
                    self.assertEqual(before, _tree_sha256(root))

    def test_retain_cases_requires_an_explicit_work_root(self) -> None:
        with (
            mock.patch.object(
                store_fault,
                "_snapshot_source_components",
            ) as snapshot,
            mock.patch("builtins.print") as output,
        ):
            with self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "explicit work root",
            ):
                store_fault.run_matrix(retain_cases=True)
            self.assertEqual(
                1,
                store_fault._main(["run-matrix", "--retain-cases"]),
            )
        snapshot.assert_not_called()
        output.assert_called_once()

    def test_source_component_paths_match_exact_python_import_closure(self) -> None:
        source_root = Path(store_fault.__file__).resolve().parent
        expected_names = {
            "campaign_module_sha256": "native_workload_store_fault_campaign.py",
            "campaign_codec_sha256": "native_workload_campaign.py",
            "store_adapter_sha256": "native_metal_soak_report.py",
            "lane4_evidence_sha256": "lane4_evidence.py",
            "metal_disruption_report_sha256": ("native_metal_disruption_report.py"),
            "metal_workload_report_sha256": "native_metal_workload_report.py",
            "native_observation_common_sha256": "native_observation_common.py",
            "native_observer_sha256": "native_observer.py",
            "native_observer_linux_sha256": "native_observer_linux.py",
            "portable_workload_report_sha256": "native_workload_report.py",
            "report_codec_sha256": "native_workload_store_fault_report.py",
        }
        expected_paths = {
            name: (source_root / filename).resolve()
            for name, filename in expected_names.items()
        }
        self.assertEqual(11, len(expected_paths))
        self.assertEqual(
            frozenset(expected_paths),
            store_fault.SOURCE_COMPONENT_KEYS,
        )
        self.assertEqual(expected_paths, store_fault._source_component_paths())
        self.assertEqual(
            set(expected_paths.values()),
            _bench_python_import_closure(
                expected_paths["campaign_module_sha256"],
            ),
        )

    def test_run_matrix_rejects_mid_run_source_component_swap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work_root = root / "work"
            source_root = root / "sources"
            work_root.mkdir()
            source_root.mkdir()
            component_paths = _source_component_paths(source_root)
            for name, path in component_paths.items():
                path.write_bytes(("original-%s" % name).encode("ascii"))
            replacement = source_root / "replacement.py"
            replacement.write_bytes(b"swapped-campaign-source")

            def swap_source(
                _case_directory: Path,
                _phase: store_fault.PublicationPhase,
                _fault_mode: str,
            ) -> tuple[int, int]:
                os.replace(
                    replacement,
                    component_paths["campaign_module_sha256"],
                )
                return store_fault.U64_MAX, int(store_fault.signal.SIGKILL)

            writer = mock.Mock(side_effect=swap_source)
            recovery = mock.Mock(
                side_effect=AssertionError("recovery must not run after a source swap")
            )
            with (
                mock.patch.object(
                    store_fault,
                    "_source_component_paths",
                    return_value=component_paths,
                ),
                mock.patch.object(store_fault, "create_seed_store"),
                mock.patch.object(
                    store_fault,
                    "verify_store",
                    return_value={"shape_sha256": bytes.fromhex("11" * 32)},
                ),
                mock.patch.object(store_fault, "_writer_case", writer),
                mock.patch.object(store_fault, "_fresh_recover", recovery),
                self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "source component changed during campaign execution",
                ),
            ):
                store_fault.run_matrix(work_root)

            self.assertEqual(1, writer.call_count)
            recovery.assert_not_called()

    def test_persistent_change_is_rejected_for_every_source_component(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_root = Path(directory)
            component_paths = _source_component_paths(source_root)
            original = {
                name: ("original-%s" % name).encode("ascii")
                for name in store_fault.SOURCE_COMPONENT_KEYS
            }
            for name, path in component_paths.items():
                path.write_bytes(original[name])
            with mock.patch.object(
                store_fault,
                "_source_component_paths",
                return_value=component_paths,
            ):
                snapshot = store_fault._snapshot_source_components()
                for name, path in component_paths.items():
                    with self.subTest(component=name):
                        path.write_bytes(("changed-%s" % name).encode("ascii"))
                        with self.assertRaisesRegex(
                            store_fault.StoreFaultCampaignError,
                            "source component changed",
                        ):
                            store_fault._verify_source_components_unchanged(snapshot)
                        path.write_bytes(original[name])
                        store_fault._verify_source_components_unchanged(snapshot)

    def test_source_snapshot_root_binds_every_component(self) -> None:
        snapshot = {
            name: hashlib.sha256(name.encode("ascii")).digest()
            for name in store_fault.SOURCE_COMPONENT_KEYS
        }
        root = store_fault._source_snapshot_sha256(snapshot)
        for name in store_fault.SOURCE_COMPONENT_KEYS:
            mutated = dict(snapshot)
            mutated[name] = hashlib.sha256(("mutated-" + name).encode("ascii")).digest()
            self.assertNotEqual(
                root,
                store_fault._source_snapshot_sha256(mutated),
            )
        with self.assertRaisesRegex(
            store_fault.StoreFaultCampaignError,
            "source snapshot schema",
        ):
            store_fault._source_snapshot_sha256(
                {
                    name: digest
                    for name, digest in snapshot.items()
                    if name != "store_adapter_sha256"
                }
            )

    def test_every_source_component_changes_header_and_report_root(self) -> None:
        snapshot = {
            name: hashlib.sha256(name.encode("ascii")).digest()
            for name in store_fault.SOURCE_COMPONENT_KEYS
        }
        header_root, report_root = _source_commitment_report(snapshot)
        for name in store_fault.SOURCE_COMPONENT_KEYS:
            with self.subTest(component=name):
                mutated = dict(snapshot)
                mutated[name] = hashlib.sha256(
                    ("mutated-" + name).encode("ascii")
                ).digest()
                changed_header, changed_report = _source_commitment_report(mutated)
                self.assertNotEqual(header_root, changed_header)
                self.assertNotEqual(report_root, changed_report)

    def test_bounded_report_read_rejects_a_namespace_swap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.bin"
            replacement = Path(directory) / "replacement.bin"
            report.write_bytes(b"original")
            replacement.write_bytes(b"replaced")
            real_read = os.read
            swapped = False

            def swap_after_read(descriptor: int, length: int) -> bytes:
                nonlocal swapped
                result = real_read(descriptor, length)
                if not swapped:
                    swapped = True
                    os.replace(replacement, report)
                return result

            with (
                mock.patch.object(
                    store_fault.os,
                    "read",
                    side_effect=swap_after_read,
                ),
                self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "changed while reading",
                ),
            ):
                store_fault._read_bounded_regular_file(
                    report,
                    minimum_bytes=1,
                    maximum_bytes=32,
                )

    def test_fresh_verifier_rejects_mismatched_python_receipt(self) -> None:
        encoded = b"expected-report"
        expected = _report_receipt(encoded)
        mismatched = dict(expected)
        mismatched["matrix_id_sha256"] = "ff" * 32
        with (
            mock.patch.object(
                store_fault,
                "_report_receipt_from_encoded",
                return_value=expected,
            ),
            mock.patch.object(
                store_fault,
                "_read_report_file",
                return_value=encoded,
            ),
            mock.patch.object(
                store_fault,
                "_run_child",
                return_value=_completed_json(mismatched),
            ),
            self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "Python report verifier receipt",
            ),
        ):
            store_fault._verify_report_fresh(
                Path("report.bin"),
                None,
                expected_encoded=encoded,
                expected_matrix_challenge_sha256=bytes.fromhex("11" * 32),
                expected_case_count=81,
                expected_source_snapshot=(store_fault._snapshot_source_components()),
            )

    def test_cli_matrix_receipt_has_exact_schema(self) -> None:
        encoded = b"verified-report"
        report_receipt = _report_receipt(encoded)
        result = {
            "source_snapshot": {},
            "source_snapshot_sha256": bytes.fromhex("44" * 32),
            "matrix_sha256": bytes.fromhex("11" * 32),
            "report_input_sha256": bytes.fromhex("22" * 32),
            "fault_cases": 81,
            "clean_controls": 1,
            "sigkill_cases": 27,
            "eio_cases": 27,
            "enospc_cases": 27,
            "first_recovery_applied": 77,
            "first_recovery_already_applied": 5,
            "second_recovery_already_applied": 82,
            "strict_verified_cases": 82,
        }
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(store_fault, "run_matrix", return_value=result),
            mock.patch.object(
                store_fault,
                "encode_report_v1",
                return_value=encoded,
            ),
            mock.patch.object(store_fault, "_verify_source_components_unchanged"),
            mock.patch.object(store_fault, "_write_report_atomic"),
            mock.patch.object(
                store_fault,
                "_verify_report_fresh",
                return_value=report_receipt,
            ),
            mock.patch("builtins.print") as output,
        ):
            self.assertEqual(
                0,
                store_fault._main(
                    [
                        "run-matrix",
                        "--output",
                        str(Path(directory) / "report.bin"),
                    ]
                ),
            )
        output.assert_called_once()
        actual = json.loads(output.call_args.args[0])
        expected = {
            "schema": "glacier.native-workload-store-fault/matrix-v1",
            "fault_cases": 81,
            "clean_controls": 1,
            "sigkill_cases": 27,
            "eio_cases": 27,
            "enospc_cases": 27,
            "first_recovery_applied": 77,
            "first_recovery_already_applied": 5,
            "second_recovery_already_applied": 82,
            "strict_verified_cases": 82,
            "report_case_count": 81,
            "encoded_bytes": len(encoded),
            "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
            "report_sha256": "33" * 32,
            "source_snapshot_sha256": "44" * 32,
            "matrix_sha256": "11" * 32,
            "report_input_sha256": "22" * 32,
            "host_process_execution": True,
            "host_filesystem_operations": True,
            "workload_execution": False,
            "gpu_execution": False,
            "synthetic_errno": True,
            "physical_storage_fault": False,
            "power_loss_emulated": False,
            "verified": True,
        }
        self.assertEqual(expected, actual)
        self.assertEqual(set(expected), set(actual))

    def test_fresh_verifier_rejects_persistent_report_codec_change(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_root = Path(directory)
            component_paths = _source_component_paths(source_root)
            for name, path in component_paths.items():
                path.write_bytes(("original-%s" % name).encode("ascii"))
            with mock.patch.object(
                store_fault,
                "_source_component_paths",
                return_value=component_paths,
            ):
                snapshot = store_fault._snapshot_source_components()
                component_paths["report_codec_sha256"].write_bytes(
                    b"changed-report-codec"
                )
                with self.assertRaisesRegex(
                    store_fault.StoreFaultCampaignError,
                    "source component changed",
                ):
                    store_fault._verify_report_fresh(
                        Path("report.bin"),
                        None,
                        expected_encoded=b"unused",
                        expected_matrix_challenge_sha256=bytes.fromhex("11" * 32),
                        expected_case_count=81,
                        expected_source_snapshot=snapshot,
                    )

    def test_fresh_verifier_rejects_current_report_swap(self) -> None:
        encoded = b"expected-report"
        expected = _report_receipt(encoded)
        with (
            mock.patch.object(
                store_fault,
                "_report_receipt_from_encoded",
                return_value=expected,
            ),
            mock.patch.object(
                store_fault,
                "_read_report_file",
                side_effect=(encoded, b"swapped-report"),
            ),
            mock.patch.object(
                store_fault,
                "_run_child",
                return_value=_completed_json(expected),
            ),
            self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "changed during fresh verification",
            ),
        ):
            store_fault._verify_report_fresh(
                Path("report.bin"),
                None,
                expected_encoded=encoded,
                expected_matrix_challenge_sha256=bytes.fromhex("11" * 32),
                expected_case_count=81,
                expected_source_snapshot=(store_fault._snapshot_source_components()),
            )

    def test_fresh_verifier_rejects_mismatched_zig_receipt(self) -> None:
        encoded = b"expected-report"
        expected = _report_receipt(encoded)
        zig_result = mock.Mock(
            returncode=0,
            stdout=(
                "verified=true cases=81 generation=1->2 "
                "report_sha256=%s\n" % ("ff" * 32)
            ),
            stderr="",
        )
        with (
            mock.patch.object(
                store_fault,
                "_report_receipt_from_encoded",
                return_value=expected,
            ),
            mock.patch.object(
                store_fault,
                "_read_report_file",
                return_value=encoded,
            ),
            mock.patch.object(
                store_fault,
                "_run_child",
                side_effect=(_completed_json(expected), zig_result),
            ),
            self.assertRaisesRegex(
                store_fault.StoreFaultCampaignError,
                "Zig report verifier receipt",
            ),
        ):
            store_fault._verify_report_fresh(
                Path("report.bin"),
                "zig-verifier",
                expected_encoded=encoded,
                expected_matrix_challenge_sha256=bytes.fromhex("11" * 32),
                expected_case_count=81,
                expected_source_snapshot=(store_fault._snapshot_source_components()),
            )


if __name__ == "__main__":
    unittest.main()
