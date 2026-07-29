"""Independent tests for canonical prepared-text raw input."""

from __future__ import annotations

import copy
import unittest

from bench import prepared_text_raw_input as raw_input
from bench import text_runtime_golden_path as golden


class PreparedTextRawInputTests(unittest.TestCase):
    def test_command_error_rendering_redacts_argv_prompt(self) -> None:
        self.assertEqual(
            (
                "glacier",
                "text-run",
                "model.glrt",
                "--text",
                "<redacted>",
                "--n",
                "1",
            ),
            golden._redacted_command(
                (
                    "glacier",
                    "text-run",
                    "model.glrt",
                    "--text",
                    "private prompt",
                    "--n",
                    "1",
                )
            ),
        )

    def test_report_digest_rejects_zero_identity(self) -> None:
        with self.assertRaises(golden.GoldenPathError):
            golden._report_digest(
                {"boundary_sha256": "00" * 32},
                "boundary_sha256",
            )

    def test_utf8_golden_matches_frozen_roots(self) -> None:
        text = "Glacier สวัสดี"
        tokens, manifest, prompt = raw_input.tokenize(
            text,
            vocab_size=512,
            max_input_bytes=4096,
        )
        self.assertEqual(tuple(text.encode("utf-8")), tokens)
        decoded_manifest = raw_input.decode_manifest(manifest)
        decoded_prompt = raw_input.decode_prompt(prompt)
        self.assertEqual(
            "96cdd6fe04e8717739f7a1dba92a30d9d80872a02fbd7a3e5c57d0125bd42ca9",
            raw_input.tokenizer_domain_sha256().hex(),
        )
        self.assertEqual(
            "fb26676e591065fb5808f56b8f1ce047ba4dcb4e4b94b03a697011b576fdd3c9",
            decoded_manifest["config_sha256"].hex(),
        )
        self.assertEqual(
            "4b4d165449392070e1f118bc6c638eb69d9c6d31b264e494e70597d8f89934a4",
            decoded_prompt["receipt_sha256"].hex(),
        )
        self.assertEqual(
            "5814d5cfd1dc516717cd52d1fde0c31d02fb17840d0794f6ae511cc99ed08d02",
            raw_input.prepared_prompt_sha256(tokens).hex(),
        )

    def test_manifest_and_prompt_reject_every_byte_mutation(self) -> None:
        _, manifest, prompt = raw_input.tokenize(
            "Ice",
            vocab_size=256,
            max_input_bytes=4096,
        )
        for index in range(len(manifest)):
            mutated = bytearray(manifest)
            mutated[index] ^= 1
            with self.assertRaises(raw_input.RawInputError):
                raw_input.decode_manifest(bytes(mutated))
        for index in range(len(prompt)):
            mutated = bytearray(prompt)
            mutated[index] ^= 1
            with self.assertRaises(raw_input.RawInputError):
                raw_input.decode_prompt(bytes(mutated))

    def test_tokenizer_has_no_modulo_or_special_token_fallback(self) -> None:
        with self.assertRaises(raw_input.RawInputError):
            raw_input.manifest_wire(255, 4096)
        with self.assertRaises(raw_input.RawInputError):
            raw_input.tokenize(
                "",
                vocab_size=256,
                max_input_bytes=4096,
            )
        with self.assertRaises(raw_input.RawInputError):
            raw_input.tokenize(
                "12345",
                vocab_size=256,
                max_input_bytes=4,
            )

    def test_binding_root_rejects_context_substitution(self) -> None:
        digest_names = (
            "tokenizer_domain_sha256",
            "tokenizer_config_sha256",
            "prompt_receipt_sha256",
            "raw_text_sha256",
            "token_ids_sha256",
            "prepared_prompt_sha256",
            "local_plan_sha256",
            "bound_plan_sha256",
            "artifact_sha256",
            "execution_plan_sha256",
            "residency_binding_sha256",
            "artifact_license_sha256",
        )
        report: dict[str, object] = {
            name: (bytes([index + 1]) * 32).hex()
            for index, name in enumerate(digest_names)
        }
        report["tokenizer_domain_sha256"] = (
            raw_input.tokenizer_domain_sha256().hex()
        )
        report.update(
            request_epoch=7,
            prompt_tokens=3,
            prompt_bytes=3,
        )
        wire = raw_input.binding_wire_from_report(report)
        decoded = raw_input.decode_binding(wire)
        root = raw_input.binding_root_from_report(report)
        self.assertEqual(32, len(root))
        self.assertEqual(root, decoded["binding_sha256"])
        for index in range(len(wire)):
            mutated_wire = bytearray(wire)
            mutated_wire[index] ^= 1
            with self.assertRaises(raw_input.RawInputError):
                raw_input.decode_binding(bytes(mutated_wire))
        for name in digest_names[1:]:
            mutated = copy.deepcopy(report)
            mutated[name] = "ab" * 32
            self.assertNotEqual(
                root,
                raw_input.binding_root_from_report(mutated),
            )
        for name in ("request_epoch", "prompt_tokens"):
            mutated = copy.deepcopy(report)
            mutated[name] = int(mutated[name]) + 1
            if name == "prompt_tokens":
                mutated["prompt_bytes"] = mutated[name]
            self.assertNotEqual(
                root,
                raw_input.binding_root_from_report(mutated),
            )

    def test_python_scalar_and_utf8_rules_match_the_wire_contract(self) -> None:
        for value in (True, -1, raw_input.U32_MAX + 1):
            with self.subTest(vocab_size=value):
                with self.assertRaises(raw_input.RawInputError):
                    raw_input.manifest_wire(value, 4096)
        for value in (True, -1, raw_input.U64_MAX + 1):
            with self.subTest(max_input_bytes=value):
                with self.assertRaises(raw_input.RawInputError):
                    raw_input.manifest_wire(256, value)
        with self.assertRaises(raw_input.RawInputError):
            raw_input.tokenize(
                "\ud800",
                vocab_size=256,
                max_input_bytes=4096,
            )

        digest_names = (
            "tokenizer_domain_sha256",
            "tokenizer_config_sha256",
            "prompt_receipt_sha256",
            "raw_text_sha256",
            "token_ids_sha256",
            "prepared_prompt_sha256",
            "local_plan_sha256",
            "bound_plan_sha256",
            "artifact_sha256",
            "execution_plan_sha256",
            "residency_binding_sha256",
            "artifact_license_sha256",
        )
        report: dict[str, object] = {
            name: (bytes([index + 1]) * 32).hex()
            for index, name in enumerate(digest_names)
        }
        report["tokenizer_domain_sha256"] = (
            raw_input.tokenizer_domain_sha256().hex()
        )
        report.update(
            request_epoch=7,
            prompt_tokens=3,
            prompt_bytes=3,
        )
        for name in ("request_epoch", "prompt_tokens", "prompt_bytes"):
            mutated = copy.deepcopy(report)
            mutated[name] = True
            with self.subTest(boolean_field=name):
                with self.assertRaises(raw_input.RawInputError):
                    raw_input.binding_root_from_report(mutated)
        oversized = copy.deepcopy(report)
        oversized["prompt_tokens"] = raw_input.MAX_INPUT_BYTES + 1
        oversized["prompt_bytes"] = raw_input.MAX_INPUT_BYTES + 1
        with self.assertRaises(raw_input.RawInputError):
            raw_input.binding_root_from_report(oversized)


if __name__ == "__main__":
    unittest.main()
