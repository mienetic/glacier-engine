from __future__ import annotations

import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from bench import provider_evidence_inspector as inspector
from bench import provider_evidence_join_wire as join_wire


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class ProviderEvidenceInspectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workspace = tempfile.TemporaryDirectory(
            prefix="glacier-provider-inspector-"
        )
        workspace = Path(cls.workspace.name)
        cls.executable = workspace / (
            "provider-evidence-inspector" + (".exe" if os.name == "nt" else "")
        )
        compile_result = subprocess.run(
            (
                "zig",
                "build-exe",
                "-OReleaseSafe",
                "--dep",
                "glacier_core",
                "-Mroot=src/cli/provider_evidence_inspector.zig",
                "-OReleaseSafe",
                "-Mglacier_core=src/core/root.zig",
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
                "provider inspector compilation failed:\n"
                + compile_result.stderr.decode("utf-8", "replace")
            )
        cls.bundle = join_wire.build_demo_bundle()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.workspace.cleanup()

    def _invoke_path(
        self,
        path: Path,
        *prefix: str,
    ) -> subprocess.CompletedProcess[bytes]:
        before = path.read_bytes() if path.is_file() else None
        result = subprocess.run(
            (str(self.executable), *prefix, "--join", str(path)),
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        after = path.read_bytes() if path.is_file() else None
        self.assertEqual(before, after)
        return result

    def _invoke_payload(
        self,
        payload: bytes,
        *,
        basename: str = "private-prompt-payload-credentials.join",
    ) -> subprocess.CompletedProcess[bytes]:
        with tempfile.TemporaryDirectory(
            prefix="case-",
            dir=self.workspace.name,
        ) as name:
            path = Path(name) / basename
            path.write_bytes(payload)
            result = self._invoke_path(path)
            self.assertNotIn(str(path).encode(), result.stdout)
            self.assertNotIn(str(path).encode(), result.stderr)
            return result

    def assertRejected(
        self,
        result: subprocess.CompletedProcess[bytes],
    ) -> None:
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertTrue(result.stderr)
        self.assertTrue(
            result.stderr.startswith(b"provider-evidence-inspector: "),
            result.stderr,
        )
        self.assertTrue(result.stderr.endswith(b"\n"))

    def assertOuterAccepted(
        self,
        result: subprocess.CompletedProcess[bytes],
        encoded: bytes,
    ) -> dict[str, object]:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout, inspector.render_expected(encoded))
        document = inspector.parse_rendered(result.stdout)
        self.assertTrue(document["outer_envelope_verified"])
        self.assertFalse(document["composition_verified"])
        self.assertFalse(document["authority_granted"])
        return document

    def test_reference_join_matches_exact_independent_json(self) -> None:
        encoded = self.bundle["join"]
        result = self._invoke_payload(encoded)
        document = self.assertOuterAccepted(result, encoded)
        self.assertEqual(
            tuple(document),
            inspector.TOP_FIELDS,
        )
        self.assertEqual(
            tuple(document["roots"]),
            inspector.ROOT_FIELDS,
        )
        self.assertNotIn("verified", document)
        self.assertNotIn("closed", document)
        self.assertNotIn("prompt", document)
        self.assertNotIn("payload", document)
        self.assertNotIn("credentials", document)
        self.assertEqual(document["journal_sequence"], 1)
        self.assertEqual(document["gateway_event_index"], 5)
        self.assertEqual(document["transport_event_count"], 4)
        self.assertEqual(document["journal_frame_bytes"], 1_645)
        self.assertEqual(document["gateway_wire_bytes"], 5_984)
        self.assertEqual(document["transport_wire_bytes"], 2_758)
        self.assertEqual(
            document["roots"]["envelope_sha256"],
            "2fada5a5836deb0d5a8d2acdad08bd09"
            "f4eb3b759dcf5b8ee69a4e38d6ee5274",
        )

    def test_malformed_length_and_outer_root_reject_without_stdout(self) -> None:
        encoded = self.bundle["join"]
        corrupt_root = bytearray(encoded)
        corrupt_root[-1] ^= 0x01
        cases = {
            "short": encoded[:-1],
            "extended": encoded + b"\x00",
            "root-drift": bytes(corrupt_root),
        }
        for label, candidate in cases.items():
            with self.subTest(label=label):
                self.assertRejected(self._invoke_payload(candidate))
                with self.assertRaises(inspector.ProviderEvidenceInspectorError):
                    inspector.decode_outer(candidate)

    def test_structural_header_drift_rejects_even_after_reseal(self) -> None:
        encoded = self.bundle["join"]
        cases: dict[str, bytearray] = {}
        magic = bytearray(encoded)
        magic[0] ^= 0x01
        cases["magic"] = magic
        abi = bytearray(encoded)
        abi[8] ^= 0x01
        cases["abi"] = abi
        declared_length = bytearray(encoded)
        struct.pack_into("<Q", declared_length, 16, inspector.WIRE_BYTES - 1)
        cases["declared-length"] = declared_length
        flags = bytearray(encoded)
        struct.pack_into("<I", flags, 24, 0)
        cases["flags"] = flags
        reserved = bytearray(encoded)
        struct.pack_into("<I", reserved, 28, 1)
        cases["reserved"] = reserved
        for label, candidate in cases.items():
            resealed = inspector.reseal_outer(bytes(candidate))
            with self.subTest(label=label):
                self.assertRejected(self._invoke_payload(resealed))
                with self.assertRaises(inspector.ProviderEvidenceInspectorError):
                    inspector.decode_outer(resealed)

    def test_resealed_semantic_contradictions_remain_outer_only(self) -> None:
        encoded = self.bundle["join"]
        candidates: dict[str, bytes] = {
            "nonzero-request-substitution": (
                inspector.reseal_nonzero_contradiction(encoded)
            ),
        }
        zero_sequence = bytearray(encoded)
        struct.pack_into("<Q", zero_sequence, 32, 0)
        candidates["zero-journal-sequence"] = inspector.reseal_outer(
            bytes(zero_sequence)
        )
        odd_lengths = bytearray(encoded)
        struct.pack_into("<Q", odd_lengths, 48, 7)
        struct.pack_into("<Q", odd_lengths, 56, 9)
        struct.pack_into("<Q", odd_lengths, 64, 11)
        candidates["odd-self-asserted-lengths"] = inspector.reseal_outer(
            bytes(odd_lengths)
        )
        zero_request = bytearray(encoded)
        request_offset = 72 + inspector.ROOT_FIELDS.index("request_sha256") * 32
        zero_request[request_offset : request_offset + 32] = bytes(32)
        candidates["zero-self-asserted-request-root"] = inspector.reseal_outer(
            bytes(zero_request)
        )

        for label, candidate in candidates.items():
            with self.subTest(label=label):
                outer = inspector.decode_outer(candidate)
                result = self._invoke_payload(candidate)
                document = self.assertOuterAccepted(result, candidate)
                self.assertFalse(document["composition_verified"])
                self.assertFalse(document["authority_granted"])
                self.assertEqual(
                    document["roots"]["request_sha256"],
                    outer["request_sha256"].hex(),
                )
                with self.assertRaises(join_wire.WireError):
                    join_wire.decode_and_verify(
                        candidate,
                        self.bundle["header"],
                        self.bundle["frame"],
                        self.bundle["gateway"],
                        self.bundle["transport"],
                    )

    def test_directory_and_argument_errors_are_observable_and_path_safe(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="argument-case-",
            dir=self.workspace.name,
        ) as name:
            directory = Path(name)
            join_path = directory / "private-prompt-payload-credentials.join"
            join_path.write_bytes(self.bundle["join"])
            commands = (
                (str(self.executable),),
                (str(self.executable), "--join"),
                (str(self.executable), "--unknown", str(join_path)),
                (
                    str(self.executable),
                    "--join",
                    str(join_path),
                    "--join",
                    str(join_path),
                ),
                (str(self.executable), "--join", str(directory)),
                (str(self.executable), "--join", str(join_path), "extra"),
            )
            for command in commands:
                with self.subTest(command=command[1:]):
                    result = subprocess.run(
                        command,
                        cwd=REPOSITORY_ROOT,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=False,
                    )
                    self.assertRejected(result)
                    self.assertNotIn(str(join_path).encode(), result.stderr)
                    self.assertNotIn(str(directory).encode(), result.stderr)

    def test_symlink_to_stable_regular_file_is_read_only_and_observable(self) -> None:
        if not hasattr(os, "symlink"):
            self.skipTest("symbolic links are unavailable")
        with tempfile.TemporaryDirectory(
            prefix="symlink-case-",
            dir=self.workspace.name,
        ) as name:
            directory = Path(name)
            target = directory / "provider.join"
            target.write_bytes(self.bundle["join"])
            link = directory / "provider-link.join"
            link.symlink_to(target)
            before = target.read_bytes()
            result = self._invoke_path(link)
            self.assertOuterAccepted(result, self.bundle["join"])
            self.assertEqual(target.read_bytes(), before)

    def test_rendered_scalar_parser_enforces_wire_widths(self) -> None:
        document = inspector.expected_document(self.bundle["join"])
        cases = {
            "u64": ("journal_sequence", 1 << 64),
            "u32-index": ("gateway_event_index", 1 << 32),
            "u32-count": ("transport_event_count", 1 << 32),
        }
        for label, (field, value) in cases.items():
            with self.subTest(label=label):
                candidate = dict(document)
                candidate[field] = value
                rendered = (
                    json.dumps(
                        candidate,
                        ensure_ascii=True,
                        separators=(",", ":"),
                    ).encode("ascii")
                    + b"\n"
                )
                with self.assertRaises(
                    inspector.ProviderEvidenceInspectorError
                ):
                    inspector.parse_rendered(rendered)

    def test_independent_runner_covers_valid_contradictory_and_corrupt(self) -> None:
        inspector.verify_executable(self.executable)


if __name__ == "__main__":
    unittest.main()
