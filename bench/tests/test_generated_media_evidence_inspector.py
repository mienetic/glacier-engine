from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from bench import generated_media_evidence_inspector as inspector
from bench import generated_media_producer_transition as transition


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class GeneratedMediaEvidenceInspectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workspace = tempfile.TemporaryDirectory(prefix="glacier-media-inspector-")
        workspace = Path(cls.workspace.name)
        cls.executable = workspace / (
            "generated-media-evidence-inspector" + (".exe" if os.name == "nt" else "")
        )
        compile_result = subprocess.run(
            (
                "zig",
                "build-exe",
                "-OReleaseSafe",
                "--dep",
                "core",
                "--dep",
                "format_evidence",
                "-Mroot=bench/generated_media_evidence_inspector.zig",
                "-OReleaseSafe",
                "-Mcore=src/core/root.zig",
                "-OReleaseSafe",
                "--dep",
                "core",
                "-Mformat_evidence=src/media/generated_media_format_conformance.zig",
                f"-femit-bin={cls.executable}",
                "--cache-dir",
                str(workspace / "cache"),
                "--global-cache-dir",
                str(workspace / "global-cache"),
            ),
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if compile_result.returncode != 0:
            raise AssertionError(
                "inspector compilation failed:\n"
                + compile_result.stderr.decode("utf-8", "replace")
            )
        cls.batches = transition.reference_batches()
        cls.format_batches = inspector.reference_format_batches()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.workspace.cleanup()

    def _invoke(
        self,
        archive: bytes,
        evidence: bytes,
        *,
        format_evidence: bytes | None = None,
        previous_archive: bytes | None = None,
        previous_evidence: bytes | None = None,
        previous_format_evidence: bytes | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        with tempfile.TemporaryDirectory(
            prefix="case-",
            dir=self.workspace.name,
        ) as case_name:
            case = Path(case_name)
            archive_path = case / "current.registry"
            evidence_path = case / "current.evidence"
            archive_path.write_bytes(archive)
            evidence_path.write_bytes(evidence)
            command = [
                str(self.executable),
                "--archive",
                str(archive_path),
                "--evidence",
                str(evidence_path),
            ]
            if format_evidence is not None:
                format_path = case / "current.format-evidence"
                format_path.write_bytes(format_evidence)
                command.extend(("--format-evidence", str(format_path)))
            if previous_archive is not None:
                previous_archive_path = case / "previous.registry"
                previous_archive_path.write_bytes(previous_archive)
                command.extend(("--previous-archive", str(previous_archive_path)))
            if previous_evidence is not None:
                previous_evidence_path = case / "previous.evidence"
                previous_evidence_path.write_bytes(previous_evidence)
                command.extend(("--previous-evidence", str(previous_evidence_path)))
            if previous_format_evidence is not None:
                previous_format_path = case / "previous.format-evidence"
                previous_format_path.write_bytes(previous_format_evidence)
                command.extend(
                    (
                        "--previous-format-evidence",
                        str(previous_format_path),
                    )
                )
            before = {
                path.name: path.read_bytes()
                for path in case.iterdir()
                if path.is_file()
            }
            result = subprocess.run(
                command,
                cwd=REPOSITORY_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            after = {
                path.name: path.read_bytes()
                for path in case.iterdir()
                if path.is_file()
            }
            self.assertEqual(before, after)
            return result

    def _invoke_batch(
        self,
        batch: transition.Record,
        *,
        predecessor: transition.Record | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        return self._invoke(
            batch["registry"]["archive_bytes"],
            batch["evidence_bytes"],
            previous_archive=(
                None
                if predecessor is None
                else predecessor["registry"]["archive_bytes"]
            ),
            previous_evidence=(
                None if predecessor is None else predecessor["evidence_bytes"]
            ),
        )

    def _invoke_format_batch(
        self,
        batch: transition.Record,
        *,
        predecessor: transition.Record | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        return self._invoke(
            batch["registry"]["archive_bytes"],
            batch["evidence_bytes"],
            format_evidence=batch["format_evidence_bytes"],
            previous_archive=(
                None
                if predecessor is None
                else predecessor["registry"]["archive_bytes"]
            ),
            previous_evidence=(
                None if predecessor is None else predecessor["evidence_bytes"]
            ),
            previous_format_evidence=(
                None if predecessor is None else predecessor["format_evidence_bytes"]
            ),
        )

    def assertRejected(
        self,
        result: subprocess.CompletedProcess[bytes],
    ) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertTrue(result.stderr)

    def test_reference_generations_match_independent_renderer(self) -> None:
        cases = (
            ("first", self.batches["first"], None),
            (
                "second",
                self.batches["second"],
                self.batches["first"],
            ),
        )
        for label, batch, predecessor in cases:
            with self.subTest(label=label):
                result = self._invoke_batch(
                    batch,
                    predecessor=predecessor,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(
                    result.stdout,
                    inspector.render_expected(batch),
                )
                self.assertEqual(
                    inspector.parse_rendered(result.stdout),
                    inspector.expected_document(batch),
                )

    def test_format_generations_match_independent_renderer(self) -> None:
        first = self.format_batches["first"]
        second = self.format_batches["second"]
        cases = (
            ("first", first, None),
            ("second", second, first),
        )
        for label, batch, predecessor in cases:
            with self.subTest(label=label):
                result = self._invoke_format_batch(
                    batch,
                    predecessor=predecessor,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, b"")
                expected = inspector.render_expected(
                    batch,
                    batch["format_evidence_bytes"],
                    (
                        None
                        if predecessor is None
                        else predecessor["format_evidence_bytes"]
                    ),
                )
                self.assertEqual(result.stdout, expected)
                decoded = inspector.parse_rendered(result.stdout)
                self.assertEqual(
                    {entry["delivery_profile"] for entry in decoded["entries"]},
                    {
                        "png",
                        "wave-pcm-s16le",
                        "apng-two-frame-gray8",
                    },
                )
                self.assertTrue(
                    all(
                        entry["plain_encoded_payload_sha256"]
                        == entry["encoded_payload_sha256"]
                        for entry in decoded["entries"]
                    )
                )

    def test_format_output_is_deterministic_and_contains_no_payload(self) -> None:
        batch = self.format_batches["first"]
        first = self._invoke_format_batch(batch)
        second = self._invoke_format_batch(batch)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertNotIn(b"\x89PNG\r\n\x1a\n", first.stdout)
        self.assertNotIn(b"RIFF", first.stdout)
        self.assertNotIn(b"IDAT", first.stdout)

    def test_format_mutation_truncation_and_extension_reject(self) -> None:
        first = self.format_batches["first"]
        archive = first["registry"]["archive_bytes"]
        evidence = first["evidence_bytes"]
        format_bytes = first["format_evidence_bytes"]
        mutated = bytearray(format_bytes)
        mutated[-1] ^= 1
        for label, candidate in (
            ("mutation", bytes(mutated)),
            ("truncation", format_bytes[:-1]),
            ("extension", format_bytes + b"\x00"),
        ):
            with self.subTest(label=label):
                self.assertRejected(
                    self._invoke(
                        archive,
                        evidence,
                        format_evidence=candidate,
                    )
                )

    def test_format_missing_foreign_and_extra_predecessors_reject(self) -> None:
        first = self.format_batches["first"]
        second = self.format_batches["second"]
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                second["evidence_bytes"],
                format_evidence=second["format_evidence_bytes"],
                previous_archive=first["registry"]["archive_bytes"],
                previous_evidence=first["evidence_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                second["evidence_bytes"],
                format_evidence=second["format_evidence_bytes"],
                previous_archive=first["registry"]["archive_bytes"],
                previous_evidence=first["evidence_bytes"],
                previous_format_evidence=second["format_evidence_bytes"],
            )
        )
        legacy_first = self.batches["first"]
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                second["evidence_bytes"],
                format_evidence=second["format_evidence_bytes"],
                previous_archive=legacy_first["registry"]["archive_bytes"],
                previous_evidence=first["evidence_bytes"],
                previous_format_evidence=first["format_evidence_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                second["evidence_bytes"],
                format_evidence=second["format_evidence_bytes"],
                previous_archive=first["registry"]["archive_bytes"],
                previous_evidence=legacy_first["evidence_bytes"],
                previous_format_evidence=first["format_evidence_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                first["evidence_bytes"],
                format_evidence=first["format_evidence_bytes"],
                previous_format_evidence=first["format_evidence_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                first["evidence_bytes"],
                format_evidence=first["format_evidence_bytes"],
                previous_archive=first["registry"]["archive_bytes"],
                previous_evidence=first["evidence_bytes"],
                previous_format_evidence=first["format_evidence_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                first["evidence_bytes"],
                previous_format_evidence=first["format_evidence_bytes"],
            )
        )

    def test_format_foreign_current_pair_rejects(self) -> None:
        first = self.format_batches["first"]
        second = self.format_batches["second"]
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                first["evidence_bytes"],
                format_evidence=second["format_evidence_bytes"],
            )
        )

    def test_output_is_deterministic(self) -> None:
        first = self._invoke_batch(self.batches["first"])
        second = self._invoke_batch(self.batches["first"])
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, second.stdout)

    def test_truncation_and_extension_reject_without_stdout(self) -> None:
        first = self.batches["first"]
        archive = first["registry"]["archive_bytes"]
        evidence = first["evidence_bytes"]
        cases = (
            ("archive_truncated", archive[:-1], evidence),
            ("archive_extended", archive + b"\x00", evidence),
            ("evidence_truncated", archive, evidence[:-1]),
            ("evidence_extended", archive, evidence + b"\x00"),
        )
        for label, current_archive, current_evidence in cases:
            with self.subTest(label=label):
                self.assertRejected(self._invoke(current_archive, current_evidence))

    def test_mixed_archive_and_sidecar_reject_without_stdout(self) -> None:
        first = self.batches["first"]
        second = self.batches["second"]
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                second["evidence_bytes"],
                previous_archive=first["registry"]["archive_bytes"],
                previous_evidence=first["evidence_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                first["evidence_bytes"],
            )
        )

    def test_missing_or_incomplete_predecessor_rejects(self) -> None:
        first = self.batches["first"]
        second = self.batches["second"]
        self.assertRejected(self._invoke_batch(second))
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                second["evidence_bytes"],
                previous_archive=first["registry"]["archive_bytes"],
            )
        )
        self.assertRejected(
            self._invoke(
                second["registry"]["archive_bytes"],
                second["evidence_bytes"],
                previous_evidence=first["evidence_bytes"],
            )
        )

    def test_valid_but_foreign_predecessor_rejects(self) -> None:
        fixture = transition.reference_inputs()
        foreign = transition.verify_and_encode_batch(
            None,
            hashlib.sha256(b"foreign generation plan").digest(),
            copy.deepcopy(fixture["batch1"]),
        )
        self.assertRejected(
            self._invoke_batch(
                self.batches["second"],
                predecessor=foreign,
            )
        )

    def test_hard_input_ceilings_reject_before_rendering(self) -> None:
        first = self.batches["first"]
        over_archive = b"\x00" * (inspector.MAX_ARCHIVE_BYTES + 1)
        over_evidence = b"\x00" * (inspector.MAX_EVIDENCE_BYTES + 1)
        over_format = b"\x00" * (inspector.MAX_FORMAT_EVIDENCE_BYTES + 1)
        self.assertRejected(self._invoke(over_archive, first["evidence_bytes"]))
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                over_evidence,
            )
        )
        self.assertRejected(
            self._invoke(
                first["registry"]["archive_bytes"],
                first["evidence_bytes"],
                format_evidence=over_format,
            )
        )

    def test_encoded_payload_sentinel_is_never_rendered(self) -> None:
        fixture = transition.reference_inputs()
        altered = copy.deepcopy(fixture["batch1"])
        sentinel = b"PAYLOAD_SENTINEL_MUST_NOT_APPEAR"
        altered[0]["delivery"]["encoded_payload"] = (
            sentinel + b":" + altered[0]["delivery"]["encoded_payload"]
        )
        batch = transition.verify_and_encode_batch(
            None,
            fixture["generation_plan1_sha256"],
            altered,
        )
        result = self._invoke_batch(batch)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(sentinel, result.stdout)
        self.assertNotIn(b"transition-fixture:", result.stdout)
        self.assertEqual(
            result.stdout,
            inspector.render_expected(batch),
        )

    def test_parser_rejects_noncanonical_or_duplicate_fields(self) -> None:
        canonical = inspector.render_expected(self.batches["first"])
        decoded = json.loads(canonical)
        reordered = {
            "verified": decoded["verified"],
            "schema": decoded["schema"],
            **{
                key: value
                for key, value in decoded.items()
                if key not in ("verified", "schema")
            },
        }
        with self.assertRaises(inspector.GeneratedMediaEvidenceInspectorError):
            inspector.parse_rendered(
                (
                    json.dumps(
                        reordered,
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("ascii")
            )
        duplicate = canonical.replace(
            b'{"schema":',
            b'{"schema":"duplicate","schema":',
            1,
        )
        with self.assertRaises(inspector.GeneratedMediaEvidenceInspectorError):
            inspector.parse_rendered(duplicate)

        format_batch = self.format_batches["first"]
        rendered_format = inspector.render_expected(
            format_batch,
            format_batch["format_evidence_bytes"],
        )
        wrong_profile = json.loads(rendered_format)
        wrong_profile["entries"][0]["delivery_profile"] = "wave-pcm-s16le"
        with self.assertRaises(inspector.GeneratedMediaEvidenceInspectorError):
            inspector.parse_rendered(
                (
                    json.dumps(
                        wrong_profile,
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("ascii")
            )


if __name__ == "__main__":
    unittest.main()
