from __future__ import annotations

from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from bench import lane4_token_txn_event_evidence as evidence
from bench import token_txn_inspector as inspector
from bench.tests.test_lane4_token_txn_event_evidence import _fixture


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "bench" / "token_txn_inspector.py"


def _canonical_line(document: dict[str, object]) -> bytes:
    return (
        json.dumps(
            document,
            ensure_ascii=True,
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )


def _contains_key(value: object, key: str) -> bool:
    if isinstance(value, dict):
        return key in value or any(_contains_key(item, key) for item in value.values())
    if isinstance(value, list):
        return any(_contains_key(item, key) for item in value)
    return False


class TokenTxnInspectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        receipt, waves, expectation = _fixture()
        cls.expectation = expectation
        cls.evidence_bytes = evidence.encode_token_txn_evidence(
            receipt,
            waves,
        )
        cls.expectation_bytes = inspector.render_expectation_manifest(expectation)

    def _invoke(
        self,
        arguments: list[str],
    ) -> subprocess.CompletedProcess[bytes]:
        environment = dict(os.environ)
        # Exercise the script's own read-only bytecode policy even when the
        # outer test runner disables bytecode globally.
        environment.pop("PYTHONDONTWRITEBYTECODE", None)
        return subprocess.run(
            (sys.executable, str(SCRIPT), *arguments),
            cwd=REPOSITORY_ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _invoke_files(
        self,
        evidence_path: Path,
        expectation_path: Path,
        *,
        reveal: bool = False,
    ) -> subprocess.CompletedProcess[bytes]:
        arguments = [
            "--evidence",
            str(evidence_path),
            "--expectation",
            str(expectation_path),
        ]
        if reveal:
            arguments.append("--reveal-token-ids")
        return self._invoke(arguments)

    def assertRejected(
        self,
        result: subprocess.CompletedProcess[bytes],
        *private_paths: Path,
    ) -> None:
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, inspector.ERROR_LINE.encode("ascii"))
        for path in private_paths:
            rendered = str(path).encode()
            self.assertNotIn(rendered, result.stdout)
            self.assertNotIn(rendered, result.stderr)

    def test_canonical_expectation_round_trip_is_exact_and_bounded(self) -> None:
        parsed = inspector.parse_expectation_manifest(self.expectation_bytes)
        self.assertEqual(parsed, self.expectation)
        self.assertEqual(
            inspector.render_expectation_manifest(parsed),
            self.expectation_bytes,
        )
        self.assertLessEqual(
            len(self.expectation_bytes),
            inspector.MAX_EXPECTATION_BYTES,
        )
        document = json.loads(self.expectation_bytes)
        self.assertEqual(tuple(document), inspector.EXPECTATION_FIELDS)
        self.assertEqual(document["schema"], inspector.EXPECTATION_SCHEMA)
        self.assertEqual(
            document["request_epoch"],
            evidence.u64_hex(self.expectation.request_epoch),
        )
        self.assertEqual(len(document["lane_outputs"]), evidence.LANE_COUNT)
        self.assertTrue(
            all(
                len(lane) == evidence.TRANSACTION_COUNT
                for lane in document["lane_outputs"]
            )
        )
        self.assertTrue(
            all(
                len(token_id) == 8 and token_id == token_id.lower()
                for lane in document["lane_outputs"]
                for token_id in lane
            )
        )

    def test_manifest_requires_exact_order_ascii_hex_shape_and_newline(
        self,
    ) -> None:
        baseline = json.loads(self.expectation_bytes)
        reordered = {
            "request_epoch": baseline["request_epoch"],
            **{key: value for key, value in baseline.items() if key != "request_epoch"},
        }
        numeric_epoch = dict(baseline)
        numeric_epoch["request_epoch"] = self.expectation.request_epoch
        uppercase_root = dict(baseline)
        uppercase_root["head_sha256"] = baseline["head_sha256"].upper()
        short_lane = json.loads(self.expectation_bytes)
        short_lane["lane_outputs"][0].pop()
        extra = dict(baseline)
        extra["unexpected"] = "x"
        duplicate = self.expectation_bytes.replace(
            b'{"schema":',
            (
                b'{"schema":"'
                + inspector.EXPECTATION_SCHEMA.encode("ascii")
                + b'","schema":'
            ),
            1,
        )
        cases = (
            self.expectation_bytes[:-1],
            self.expectation_bytes + b"\n",
            b" " + self.expectation_bytes,
            _canonical_line(reordered),
            _canonical_line(numeric_epoch),
            _canonical_line(uppercase_root),
            _canonical_line(short_lane),
            _canonical_line(extra),
            duplicate,
            b"\xff\n",
            b"x" * (inspector.MAX_EXPECTATION_BYTES + 1),
        )
        for candidate in cases:
            with self.subTest(prefix=candidate[:24]):
                with self.assertRaises(inspector.TokenTxnInspectorError):
                    inspector.parse_expectation_manifest(candidate)

    def test_default_report_is_metadata_only_deterministic_and_exact(
        self,
    ) -> None:
        first = inspector.render_report(
            self.evidence_bytes,
            self.expectation_bytes,
        )
        second = inspector.render_report(
            self.evidence_bytes,
            self.expectation_bytes,
        )
        self.assertEqual(first, second)
        self.assertEqual(first.count(b"\n"), 1)
        self.assertTrue(first.endswith(b"\n"))
        self.assertLessEqual(len(first), inspector.MAX_REPORT_BYTES)

        document = inspector.parse_rendered_report(
            first,
            self.evidence_bytes,
            self.expectation_bytes,
        )
        self.assertEqual(tuple(document), inspector.REPORT_FIELDS)
        self.assertEqual(document["schema"], inspector.REPORT_SCHEMA)
        self.assertTrue(document["replay_verified"])
        self.assertTrue(document["read_only"])
        self.assertFalse(document["authority_granted"])
        self.assertFalse(document["token_ids_disclosed"])
        self.assertFalse(_contains_key(document, "token_ids"))
        self.assertEqual(
            document["request_epoch"],
            evidence.u64_hex(self.expectation.request_epoch),
        )
        self.assertEqual(
            document["roots"]["root_binding_sha256"],
            self.expectation.root_binding_sha256,
        )
        self.assertEqual(
            document["roots"]["resource_receipt_sha256"],
            self.expectation.resource_receipt_sha256,
        )
        self.assertEqual(
            document["roots"]["head_sha256"],
            self.expectation.head_sha256,
        )
        self.assertEqual(
            document["roots"]["evidence_sha256"],
            hashlib.sha256(self.evidence_bytes).hexdigest(),
        )
        self.assertEqual(
            document["roots"]["expectation_manifest_sha256"],
            hashlib.sha256(self.expectation_bytes).hexdigest(),
        )

        for lane_index, lane in enumerate(self.expectation.lane_outputs):
            digest = hashlib.sha256()
            digest.update(inspector.LANE_OUTPUT_HASH_DOMAIN)
            digest.update(bytes.fromhex(self.expectation.root_binding_sha256))
            digest.update(self.expectation.request_epoch.to_bytes(8, "little"))
            digest.update(lane_index.to_bytes(4, "little"))
            digest.update(len(lane).to_bytes(4, "little"))
            for token_id in lane:
                digest.update(token_id.to_bytes(4, "little"))
            self.assertEqual(
                document["lane_output_sha256"][lane_index],
                digest.hexdigest(),
            )

    def test_explicit_reveal_adds_only_fixed_width_token_ids(self) -> None:
        hidden = inspector.inspect_token_txn_evidence(
            self.evidence_bytes,
            self.expectation_bytes,
        )
        revealed_line = inspector.render_report(
            self.evidence_bytes,
            self.expectation_bytes,
            reveal_token_ids=True,
        )
        revealed = inspector.parse_rendered_report(
            revealed_line,
            self.evidence_bytes,
            self.expectation_bytes,
        )
        self.assertEqual(tuple(revealed), inspector.REVEALED_REPORT_FIELDS)
        self.assertTrue(revealed["token_ids_disclosed"])
        self.assertEqual(
            revealed["token_ids"],
            [
                [evidence.u32_hex(token_id) for token_id in lane]
                for lane in self.expectation.lane_outputs
            ],
        )
        without_disclosure = dict(revealed)
        without_disclosure.pop("token_ids")
        without_disclosure["token_ids_disclosed"] = False
        self.assertEqual(without_disclosure, hidden)

    def test_external_root_and_output_substitution_fail_replay(self) -> None:
        divergent_head = replace(
            self.expectation,
            head_sha256=(
                "1" + self.expectation.head_sha256[1:]
                if self.expectation.head_sha256[0] != "1"
                else "2" + self.expectation.head_sha256[1:]
            ),
        )
        outputs = [list(lane) for lane in self.expectation.lane_outputs]
        outputs[2][17] += 1
        divergent_output = replace(
            self.expectation,
            lane_outputs=tuple(tuple(lane) for lane in outputs),
        )
        for expectation in (divergent_head, divergent_output):
            with self.subTest(expectation=expectation):
                manifest = inspector.render_expectation_manifest(expectation)
                with self.assertRaisesRegex(
                    inspector.TokenTxnInspectorError,
                    "replay failed",
                ):
                    inspector.render_report(
                        self.evidence_bytes,
                        manifest,
                    )

    def test_rendered_parser_rejects_claim_and_disclosure_drift(self) -> None:
        hidden = json.loads(
            inspector.render_report(
                self.evidence_bytes,
                self.expectation_bytes,
            )
        )
        revealed = json.loads(
            inspector.render_report(
                self.evidence_bytes,
                self.expectation_bytes,
                reveal_token_ids=True,
            )
        )
        authority = dict(hidden)
        authority["authority_granted"] = True
        hidden_tokens = dict(hidden)
        hidden_tokens["token_ids"] = revealed["token_ids"]
        claimed_without_tokens = dict(revealed)
        claimed_without_tokens.pop("token_ids")
        malformed_token = json.loads(_canonical_line(revealed))
        malformed_token["token_ids"][0][0] = "1"
        inconsistent_initial = json.loads(_canonical_line(hidden))
        original_initial = inconsistent_initial["roots"]["initial_sha256"]
        inconsistent_initial["roots"]["initial_sha256"] = (
            "1" + original_initial[1:]
            if original_initial[0] != "1"
            else "2" + original_initial[1:]
        )
        forged_head = json.loads(_canonical_line(hidden))
        original_head = forged_head["roots"]["head_sha256"]
        forged_head["roots"]["head_sha256"] = (
            "1" + original_head[1:]
            if original_head[0] != "1"
            else "2" + original_head[1:]
        )
        forged_hidden_lane_root = json.loads(_canonical_line(hidden))
        original_lane_root = forged_hidden_lane_root["lane_output_sha256"][0]
        forged_hidden_lane_root["lane_output_sha256"][0] = (
            "1" + original_lane_root[1:]
            if original_lane_root[0] != "1"
            else "2" + original_lane_root[1:]
        )
        whitespace = (
            inspector.render_report(
                self.evidence_bytes,
                self.expectation_bytes,
            )[:-1]
            + b" \n"
        )
        for candidate in (
            _canonical_line(authority),
            _canonical_line(hidden_tokens),
            _canonical_line(claimed_without_tokens),
            _canonical_line(malformed_token),
            _canonical_line(inconsistent_initial),
            _canonical_line(forged_head),
            _canonical_line(forged_hidden_lane_root),
            whitespace,
        ):
            with self.subTest(prefix=candidate[:32]):
                with self.assertRaises(inspector.TokenTxnInspectorError):
                    inspector.parse_rendered_report(
                        candidate,
                        self.evidence_bytes,
                        self.expectation_bytes,
                    )

    def test_cli_reads_without_mutation_and_matches_library_contract(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="glacier-token-inspector-") as name:
            directory = Path(name)
            evidence_path = directory / "private-token-evidence.jsonl"
            expectation_path = directory / "private-token-expectation.json"
            evidence_path.write_bytes(self.evidence_bytes)
            expectation_path.write_bytes(self.expectation_bytes)
            os.chmod(evidence_path, 0o400)
            os.chmod(expectation_path, 0o400)
            before = {
                path.name: (
                    path.read_bytes(),
                    path.stat().st_mode,
                    path.stat().st_ino,
                )
                for path in directory.iterdir()
            }

            hidden = self._invoke_files(
                evidence_path,
                expectation_path,
            )
            self.assertEqual(hidden.returncode, 0, hidden.stderr)
            self.assertEqual(hidden.stderr, b"")
            self.assertEqual(
                hidden.stdout,
                inspector.render_report(
                    self.evidence_bytes,
                    self.expectation_bytes,
                ),
            )
            self.assertFalse(_contains_key(json.loads(hidden.stdout), "token_ids"))

            revealed = self._invoke_files(
                evidence_path,
                expectation_path,
                reveal=True,
            )
            self.assertEqual(revealed.returncode, 0, revealed.stderr)
            self.assertEqual(revealed.stderr, b"")
            self.assertEqual(
                revealed.stdout,
                inspector.render_report(
                    self.evidence_bytes,
                    self.expectation_bytes,
                    reveal_token_ids=True,
                ),
            )
            after = {
                path.name: (
                    path.read_bytes(),
                    path.stat().st_mode,
                    path.stat().st_ino,
                )
                for path in directory.iterdir()
            }
            self.assertEqual(before, after)

    def test_cli_rejects_symlinks_directories_and_bad_arguments_path_safely(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="glacier-token-inspector-private-"
        ) as name:
            directory = Path(name)
            evidence_path = directory / "prompt-token-evidence.jsonl"
            expectation_path = directory / "credential-expectation.json"
            evidence_path.write_bytes(self.evidence_bytes)
            expectation_path.write_bytes(self.expectation_bytes)

            commands = (
                [],
                ["--evidence"],
                [
                    "--evidence",
                    str(evidence_path),
                    "--expectation",
                    str(expectation_path),
                    "--unexpected-private-path",
                ],
                [
                    "--evidence",
                    str(evidence_path),
                    "--evidence",
                    str(evidence_path),
                    "--expectation",
                    str(expectation_path),
                ],
                [
                    "--evidence",
                    str(directory),
                    "--expectation",
                    str(expectation_path),
                ],
            )
            for command in commands:
                with self.subTest(command=command):
                    self.assertRejected(
                        self._invoke(command),
                        evidence_path,
                        expectation_path,
                        directory,
                    )

            if hasattr(os, "symlink"):
                evidence_link = directory / "private-evidence-link"
                expectation_link = directory / "private-expectation-link"
                try:
                    evidence_link.symlink_to(evidence_path)
                    expectation_link.symlink_to(expectation_path)
                except OSError:
                    pass
                else:
                    self.assertRejected(
                        self._invoke_files(
                            evidence_link,
                            expectation_path,
                        ),
                        evidence_link,
                        evidence_path,
                    )
                    self.assertRejected(
                        self._invoke_files(
                            evidence_path,
                            expectation_link,
                        ),
                        expectation_link,
                        expectation_path,
                    )

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_non_regular_fifo_rejects_before_open_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="glacier-token-inspector-fifo-"
        ) as name:
            fifo = Path(name) / "private-token-fifo"
            os.mkfifo(fifo)
            with self.assertRaises(inspector.TokenTxnInspectorError):
                inspector.read_stable_regular_file(
                    fifo,
                    inspector.MAX_EXPECTATION_BYTES,
                )

    def test_descriptor_reader_detects_change_during_read(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="glacier-token-inspector-race-"
        ) as name:
            path = Path(name) / "private-expectation.json"
            path.write_bytes(self.expectation_bytes)
            original = inspector._read_bounded_fd

            def mutate_after_read(
                file_descriptor: int,
                maximum_bytes: int,
            ) -> bytes:
                data = original(file_descriptor, maximum_bytes)
                replacement = bytearray(self.expectation_bytes)
                replacement[1] = ord("x") if replacement[1] != ord("x") else ord("y")
                path.write_bytes(replacement)
                return data

            with mock.patch.object(
                inspector,
                "_read_bounded_fd",
                side_effect=mutate_after_read,
            ):
                with self.assertRaisesRegex(
                    inspector.TokenTxnInspectorError,
                    "changed during read",
                ):
                    inspector.read_stable_regular_file(
                        path,
                        inspector.MAX_EXPECTATION_BYTES,
                    )

    def test_cli_bounds_oversized_inputs_before_replay(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="glacier-token-inspector-bound-"
        ) as name:
            directory = Path(name)
            valid_evidence = directory / "valid.evidence"
            valid_expectation = directory / "valid.expectation"
            oversized_evidence = directory / "private-oversized.evidence"
            oversized_expectation = directory / "private-oversized.expectation"
            valid_evidence.write_bytes(self.evidence_bytes)
            valid_expectation.write_bytes(self.expectation_bytes)
            oversized_evidence.write_bytes(b"x" * (evidence.MAX_EVIDENCE_BYTES + 1))
            oversized_expectation.write_bytes(
                b"x" * (inspector.MAX_EXPECTATION_BYTES + 1)
            )
            self.assertRejected(
                self._invoke_files(
                    oversized_evidence,
                    valid_expectation,
                ),
                oversized_evidence,
            )
            self.assertRejected(
                self._invoke_files(
                    valid_evidence,
                    oversized_expectation,
                ),
                oversized_expectation,
            )

    def test_help_is_fixed_and_has_no_input_side_effect(self) -> None:
        for option in ("--help", "-h"):
            with self.subTest(option=option):
                result = self._invoke([option])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, inspector.USAGE.encode("ascii"))
                self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
