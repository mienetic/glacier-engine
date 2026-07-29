import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib


BENCH_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = BENCH_DIR / "model_conversion_durable_recovery.py"
SPEC = importlib.util.spec_from_file_location(
    "model_conversion_durable_recovery",
    MODULE_PATH,
)
assert SPEC is not None and SPEC.loader is not None
recovery = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = recovery
SPEC.loader.exec_module(recovery)


SOURCE_BYTES = b"strict-independent-source"
SOURCE_SHA256 = hashlib.sha256(SOURCE_BYTES).hexdigest()
PROFILE_SHA256 = hashlib.sha256(b"profile-root").hexdigest()
PLAN_SHA256 = hashlib.sha256(b"conversion-plan-root").hexdigest()


def _metadata_bytes(*, num_pages: int = 2) -> bytes:
    metadata = {
        "schema": recovery.METADATA_SCHEMA,
        "architecture": recovery.FIXTURE_ARCHITECTURE,
        "num_pages": num_pages,
        "page_size_bytes": recovery.PAGE_SIZE_BYTES,
        "source_bytes": len(SOURCE_BYTES),
        "source_sha256": SOURCE_SHA256,
        "conversion_profile_sha256": PROFILE_SHA256,
        "conversion_plan_sha256": PLAN_SHA256,
        "created_by": recovery.METADATA_CREATED_BY,
    }
    return json.dumps(
        metadata,
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("ascii")


def _entry(
    *,
    page_id: int,
    layer_idx: int,
    tensor_kind: int,
    row_start: int,
    row_end: int,
    precision: int,
    quant_group: int,
    data_offset: int,
    payload: bytes,
) -> bytes:
    return struct.pack(
        "<QIIQQBBHQQIII",
        page_id,
        layer_idx,
        tensor_kind,
        row_start,
        row_end,
        precision,
        quant_group,
        0,
        data_offset,
        len(payload),
        zlib.crc32(payload) & recovery.MAX_U32,
        0,
        0,
    )


def _fixture_bytes() -> bytes:
    metadata = _metadata_bytes()
    page_index_offset = recovery.GLACIER_HEADER_SIZE + len(metadata)
    page_data_offset = page_index_offset + 2 * recovery.PAGE_ENTRY_SIZE

    raw_payload = struct.pack("<4f", 1.0, 2.0, 3.0, 4.0)
    quant_payload = (
        struct.pack(
            "<IIIB3x",
            recovery.QUANT_PAYLOAD_MAGIC,
            8,
            4,
            1,
        )
        + struct.pack("<2f", 0.25, 0.5)
        + b"\x10\x32\x54\x76"
    )
    first_entry = _entry(
        page_id=0,
        layer_idx=1,
        tensor_kind=1,
        row_start=0,
        row_end=4,
        precision=6,
        quant_group=0,
        data_offset=page_data_offset,
        payload=raw_payload,
    )
    second_entry = _entry(
        page_id=1,
        layer_idx=2,
        tensor_kind=6,
        row_start=0,
        row_end=8,
        precision=3,
        quant_group=4,
        data_offset=page_data_offset + len(raw_payload),
        payload=quant_payload,
    )

    header = bytearray(recovery.GLACIER_HEADER_SIZE)
    struct.pack_into(
        "<4sHHQQQQQII",
        header,
        0,
        recovery.GLACIER_MAGIC,
        recovery.GLACIER_VERSION,
        recovery.GLACIER_HEADER_SIZE,
        recovery.GLACIER_HEADER_SIZE,
        len(metadata),
        2,
        page_index_offset,
        page_data_offset,
        recovery.PAGE_SIZE_LOG2,
        0,
    )
    return (
        bytes(header)
        + metadata
        + first_entry
        + second_entry
        + raw_payload
        + quant_payload
    )


def _write_fixture(path: Path, encoded: bytes) -> None:
    path.write_bytes(encoded)
    os.chmod(path, 0o600)


def _facts() -> tuple[recovery.GlacierFacts, recovery.SourceIdentity]:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "fixture.glacier"
        _write_fixture(path, _fixture_bytes())
        facts = recovery.parse_glacier_v1(path)
    source = recovery.SourceIdentity(
        source_bytes=len(SOURCE_BYTES),
        source_sha256=SOURCE_SHA256,
    )
    return facts, source


def _ready_frame(
    source: recovery.SourceIdentity,
    publication_plan: str,
    *,
    pid: int = 731,
    phase: str = "candidate_synced",
) -> dict[str, object]:
    return {
        "schema": recovery.READY_SCHEMA,
        "mode": "victim",
        "pid": pid,
        "disposition": "ready",
        "phase": "victim_ready",
        "crash_point": phase,
        "source_name": recovery.SOURCE_NAME,
        "target_name": recovery.TARGET_NAME,
        "source_bytes": source.source_bytes,
        "source_sha256": source.source_sha256,
        "publication_plan_sha256": publication_plan,
        "host_process_recovery": True,
        "power_loss_emulated": False,
    }


def _result_frame(
    facts: recovery.GlacierFacts,
    source: recovery.SourceIdentity,
    publication_plan: str,
    *,
    pid: int = 911,
) -> dict[str, object]:
    return {
        "schema": recovery.RESULT_SCHEMA,
        "mode": "recover",
        "pid": pid,
        "disposition": "published",
        "source_name": recovery.SOURCE_NAME,
        "target_name": recovery.TARGET_NAME,
        "source_bytes": source.source_bytes,
        "output_bytes": facts.container_bytes,
        "num_pages": facts.num_pages,
        "conversion_workspace_bytes_peak": (
            recovery.CONVERSION_WORKSPACE_BYTES_PEAK
        ),
        "source_sha256": source.source_sha256,
        "output_sha256": facts.container_sha256,
        "conversion_profile_sha256": facts.conversion_profile_sha256,
        "conversion_plan_sha256": facts.conversion_plan_sha256,
        "publication_plan_sha256": publication_plan,
        "stale_candidate_removed": False,
        "verified": True,
        "host_process_recovery": True,
        "power_loss_emulated": False,
    }


class GlacierV1ParserTests(unittest.TestCase):
    def test_parser_checks_header_metadata_pages_quant_crc_and_full_sha(
        self,
    ) -> None:
        encoded = _fixture_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.glacier"
            _write_fixture(path, encoded)
            facts = recovery.parse_glacier_v1(path)

        self.assertEqual(facts.container_bytes, len(encoded))
        self.assertEqual(
            facts.container_sha256,
            hashlib.sha256(encoded).hexdigest(),
        )
        self.assertEqual(
            facts.metadata_sha256,
            hashlib.sha256(_metadata_bytes()).hexdigest(),
        )
        self.assertEqual(facts.source_sha256, SOURCE_SHA256)
        self.assertEqual(facts.conversion_profile_sha256, PROFILE_SHA256)
        self.assertEqual(facts.conversion_plan_sha256, PLAN_SHA256)
        self.assertEqual(len(facts.pages), 2)
        self.assertEqual(
            (
                facts.pages[0].precision,
                facts.pages[0].quant_group,
                facts.pages[0].data_len,
            ),
            (6, 0, 16),
        )
        self.assertEqual(
            (
                facts.pages[1].precision,
                facts.pages[1].quant_group,
                facts.pages[1].data_len,
            ),
            (3, 4, 28),
        )

    def test_parser_rejects_each_strict_wire_domain(self) -> None:
        pristine = _fixture_bytes()
        meta_len = struct.unpack_from("<Q", pristine, 16)[0]
        index_offset = recovery.GLACIER_HEADER_SIZE + meta_len
        data_offset = index_offset + 2 * recovery.PAGE_ENTRY_SIZE
        quant_offset = data_offset + 16

        mutations: list[tuple[str, int, str]] = [
            ("header_reserved", 52, "header reserved"),
            ("header_padding", 80, "header reserved"),
            ("page_id", index_offset, "non-canonical ID"),
            ("entry_reserved", index_offset + 34, "reserved fields"),
            ("quant_reserved", quant_offset + 13, "reserved bytes"),
            ("payload_crc", quant_offset + 27, "CRC mismatch"),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, offset, expected_error in mutations:
                with self.subTest(domain=name):
                    mutated = bytearray(pristine)
                    mutated[offset] ^= 0x01
                    path = root / f"{name}.glacier"
                    _write_fixture(path, bytes(mutated))
                    with self.assertRaisesRegex(
                        recovery.CampaignError,
                        expected_error,
                    ):
                        recovery.parse_glacier_v1(path)

    def test_parser_rejects_layout_geometry_and_zero_metadata_root(self) -> None:
        pristine = _fixture_bytes()
        meta_len = struct.unpack_from("<Q", pristine, 16)[0]
        index_offset = recovery.GLACIER_HEADER_SIZE + meta_len

        bad_layout = bytearray(pristine)
        struct.pack_into("<Q", bad_layout, 32, index_offset + 1)

        bad_geometry = bytearray(pristine)
        struct.pack_into("<Q", bad_geometry, index_offset + 44, 15)

        bad_root = bytearray(pristine)
        marker = b'"source_sha256":"'
        root_offset = bad_root.find(marker) + len(marker)
        self.assertGreaterEqual(root_offset, len(marker))
        bad_root[root_offset : root_offset + 64] = b"0" * 64

        cases = (
            ("layout", bad_layout, "metadata"),
            ("geometry", bad_geometry, "geometry"),
            ("metadata_root", bad_root, "zero source_sha256"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, encoded, expected_error in cases:
                with self.subTest(domain=name):
                    path = root / f"{name}.glacier"
                    _write_fixture(path, bytes(encoded))
                    with self.assertRaisesRegex(
                        recovery.CampaignError,
                        expected_error,
                    ):
                        recovery.parse_glacier_v1(path)


class WorkerSchemaTests(unittest.TestCase):
    def test_ready_and_result_frames_bind_pid_plan_identity_and_scope(
        self,
    ) -> None:
        facts, source = _facts()
        publication_plan = recovery.publication_plan_sha256(source)
        ready = _ready_frame(source, publication_plan)
        recovery.validate_ready_frame(
            ready,
            process_pid=731,
            expected_phase="candidate_synced",
            expected_source=source,
            expected_plan_sha256=publication_plan,
        )

        result = _result_frame(facts, source, publication_plan)
        recovery.validate_result_frame(
            result,
            expected_process_pid=911,
            expected_mode="recover",
            expected_disposition="published",
            expected_source=source,
            expected_artifact=facts,
            expected_plan_sha256=publication_plan,
            expected_stale_candidate_removed=False,
        )

    def test_ready_rejects_wrong_pid_plan_and_scope_flags(self) -> None:
        _, source = _facts()
        publication_plan = recovery.publication_plan_sha256(source)
        mutations = (
            ("pid", 732, "PID"),
            (
                "publication_plan_sha256",
                hashlib.sha256(b"wrong-plan").hexdigest(),
                "publication plan",
            ),
            ("host_process_recovery", False, "host-process recovery"),
            ("power_loss_emulated", True, "power-loss emulation"),
        )
        for field, value, expected_error in mutations:
            with self.subTest(field=field):
                frame = _ready_frame(source, publication_plan)
                frame[field] = value
                with self.assertRaisesRegex(
                    recovery.CampaignError,
                    expected_error,
                ):
                    recovery.validate_ready_frame(
                        frame,
                        process_pid=731,
                        expected_phase="candidate_synced",
                        expected_source=source,
                        expected_plan_sha256=publication_plan,
                    )

    def test_result_rejects_shape_identity_plan_and_scope_drift(self) -> None:
        facts, source = _facts()
        publication_plan = recovery.publication_plan_sha256(source)
        mutations = (
            ("pid", 912, "PID"),
            (
                "publication_plan_sha256",
                hashlib.sha256(b"wrong-plan").hexdigest(),
                "publication plan",
            ),
            ("host_process_recovery", False, "host-process recovery"),
            ("power_loss_emulated", True, "power-loss emulation"),
            ("output_sha256", hashlib.sha256(b"wrong").hexdigest(), "output"),
        )
        for field, value, expected_error in mutations:
            with self.subTest(field=field):
                frame = _result_frame(facts, source, publication_plan)
                frame[field] = value
                with self.assertRaisesRegex(
                    recovery.CampaignError,
                    expected_error,
                ):
                    recovery.validate_result_frame(
                        frame,
                        expected_process_pid=911,
                        expected_mode="recover",
                        expected_disposition="published",
                        expected_source=source,
                        expected_artifact=facts,
                        expected_plan_sha256=publication_plan,
                        expected_stale_candidate_removed=False,
                    )

        extra = _result_frame(facts, source, publication_plan)
        extra["unexpected"] = True
        with self.assertRaisesRegex(recovery.CampaignError, "shape changed"):
            recovery.validate_result_frame(
                extra,
                expected_process_pid=911,
                expected_mode="recover",
                expected_disposition="published",
                expected_source=source,
                expected_artifact=facts,
                expected_plan_sha256=publication_plan,
                expected_stale_candidate_removed=False,
            )


class RecoveryStateModelTests(unittest.TestCase):
    def test_publication_plan_oracle_tracks_canonical_v2_domain(self) -> None:
        self.assertEqual(recovery.PUBLICATION_ABI, 0x474C_4450_0000_0002)
        self.assertEqual(
            recovery.PUBLICATION_PLAN_DOMAIN,
            b"glacier-conversion-publication-plan-v2\x00",
        )

    def test_all_eight_phases_have_one_exact_boundary_model(self) -> None:
        self.assertEqual(
            recovery.CRASH_PHASES,
            (
                "stale_candidate_removed",
                "candidate_created",
                "candidate_page_progress",
                "candidate_encoded",
                "candidate_synced",
                "candidate_validated",
                "target_replaced",
                "directory_committed",
            ),
        )
        self.assertEqual(len(recovery.CRASH_PHASES), 8)

        for phase in recovery.CRASH_PHASES:
            with self.subTest(phase=phase):
                boundary = recovery.boundary_expectation(phase)
                before_rename = phase in recovery.PRE_RENAME_PHASES
                self.assertEqual(
                    boundary.post_kill_target,
                    "predecessor" if before_rename else "successor",
                )
                self.assertEqual(
                    boundary.recovery_disposition,
                    "published" if before_rename else "already_current",
                )
                self.assertEqual(
                    boundary.candidate_visible,
                    phase in recovery.CANDIDATE_VISIBLE_PHASES,
                )
                self.assertEqual(
                    boundary.candidate_complete,
                    phase in recovery.COMPLETE_CANDIDATE_PHASES,
                )
                self.assertEqual(
                    boundary.recovery_removes_stale_candidate,
                    phase in recovery.STALE_ON_RECOVERY_PHASES,
                )

        stale_boundary = recovery.boundary_expectation(
            "stale_candidate_removed"
        )
        self.assertFalse(stale_boundary.candidate_visible)
        self.assertFalse(stale_boundary.recovery_removes_stale_candidate)
        self.assertIn("candidate_created", recovery.CANDIDATE_VISIBLE_PHASES)

    def test_publication_plan_binds_source_and_target(self) -> None:
        source = recovery.SourceIdentity(
            source_bytes=len(SOURCE_BYTES),
            source_sha256=SOURCE_SHA256,
        )
        baseline = recovery.publication_plan_sha256(source)
        changed_source = recovery.publication_plan_sha256(
            recovery.SourceIdentity(
                source_bytes=source.source_bytes + 1,
                source_sha256=source.source_sha256,
            )
        )
        changed_target = recovery.publication_plan_sha256(
            source,
            target_name="other.glacier",
        )
        self.assertNotEqual(baseline, changed_source)
        self.assertNotEqual(baseline, changed_target)


class CanonicalJsonAndCliTests(unittest.TestCase):
    def test_canonical_json_rejects_duplicate_and_noncompact_frames(self) -> None:
        self.assertEqual(
            recovery.decode_canonical_json_line(b'{"ok":true,"count":2}'),
            {"ok": True, "count": 2},
        )
        rejected = (
            b'{"value":1,"value":2}',
            b'{"value": 1}',
            b'{"value":1}\n',
            b'{"value":NaN}',
        )
        for encoded in rejected:
            with self.subTest(encoded=encoded):
                with self.assertRaises(recovery.CampaignError):
                    recovery.decode_canonical_json_line(encoded)

    def test_cli_requires_worker_and_directory_and_parses_timeout(self) -> None:
        parser = recovery._parser()
        parsed = parser.parse_args(
            (
                "--worker",
                "/tmp/worker",
                "--directory",
                "/tmp/evidence",
                "--timeout-seconds",
                "12.5",
            )
        )
        self.assertEqual(parsed.worker, "/tmp/worker")
        self.assertEqual(parsed.directory, "/tmp/evidence")
        self.assertEqual(parsed.timeout_seconds, 12.5)

        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(("--worker", "/tmp/worker"))
            with self.assertRaises(SystemExit):
                parser.parse_args(("--directory", "/tmp/evidence"))

    def test_cli_emits_one_compact_json_summary_without_spawning(self) -> None:
        summary = {
            "schema": recovery.CAMPAIGN_SCHEMA,
            "host_process_recovery": True,
            "power_loss_emulated": False,
            "verified": True,
        }
        stdout = io.StringIO()
        with (
            mock.patch.object(
                recovery,
                "_resolve_worker",
                return_value=Path("/worker"),
            ),
            mock.patch.object(
                recovery,
                "_prepare_output_directory",
                return_value=Path("/evidence"),
            ),
            mock.patch.object(
                recovery,
                "run_campaign",
                return_value=summary,
            ) as campaign,
            contextlib.redirect_stdout(stdout),
        ):
            result = recovery.main(
                (
                    "--worker",
                    "/worker",
                    "--directory",
                    "/evidence",
                )
            )

        self.assertEqual(result, 0)
        self.assertEqual(
            stdout.getvalue(),
            json.dumps(summary, ensure_ascii=True, separators=(",", ":"))
            + "\n",
        )
        campaign.assert_called_once_with(
            worker=Path("/worker"),
            directory=Path("/evidence"),
            timeout_seconds=recovery.DEFAULT_TIMEOUT_SECONDS,
        )


if __name__ == "__main__":
    unittest.main()
