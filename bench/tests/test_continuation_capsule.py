from __future__ import annotations

import unittest

from bench import continuation_capsule as capsule


class ContinuationCapsuleTests(unittest.TestCase):
    def setUp(self) -> None:
        bundle = capsule.build_demo_bundle()
        self.config = bundle["config"]
        self.objects = bundle["objects"]
        self.encoded = bundle["encoded"]

    def test_cross_language_golden_round_trip(self) -> None:
        self.assertEqual(len(self.encoded), 608)
        self.assertEqual(
            self.encoded[-32:].hex(),
            "b03dfe6cc29b64da03377a2d0cf1b576"
            "35f04d4fe8a2ffa1a8497cb8e55e1aeb",
        )
        decoded = capsule.decode_and_verify(
            self.encoded,
            self.config,
            self.objects,
        )
        self.assertEqual(decoded["config"], self.config)
        self.assertEqual(
            decoded["refs"]["kv_state"]["byte_length"],
            len(self.objects["kv_state"][1]),
        )

    def test_every_capsule_byte_mutation_rejects(self) -> None:
        for offset in range(len(self.encoded)):
            with self.subTest(offset=offset):
                mutated = bytearray(self.encoded)
                mutated[offset] ^= 1
                candidate = bytes(mutated)
                if offset < len(self.encoded) - 32:
                    candidate = capsule.reseal_for_test(candidate)
                with self.assertRaises(capsule.CapsuleError):
                    capsule.decode_and_verify(
                        candidate,
                        self.config,
                        self.objects,
                    )

    def test_valid_foreign_object_substitution_rejects(self) -> None:
        foreign = dict(self.objects)
        foreign["kv_state"] = (
            self.objects["kv_state"][0],
            b"kv-v1:positions=35:root=foreign",
        )
        with self.assertRaises(capsule.CapsuleError):
            capsule.decode_and_verify(self.encoded, self.config, foreign)

    def test_scalar_substitution_and_parent_drift_reject(self) -> None:
        substituted = dict(self.config)
        substituted["publication_sequence"] = 4
        with self.assertRaises(capsule.CapsuleError):
            capsule.decode_and_verify(
                self.encoded,
                substituted,
                self.objects,
            )

        resumed = dict(self.config)
        resumed.update(
            publication_sequence=4,
            checkpoint_generation=1,
            kv_tokens=36,
            output_tokens=4,
            parent_capsule_sha256=self.encoded[-32:],
        )
        resumed_encoded = capsule.encode(resumed, self.objects)
        decoded = capsule.decode_and_verify(
            resumed_encoded,
            resumed,
            self.objects,
        )
        self.assertEqual(decoded["config"]["checkpoint_generation"], 1)

        invalid_parent = dict(resumed)
        invalid_parent["parent_capsule_sha256"] = capsule.ZERO_DIGEST
        with self.assertRaises(capsule.CapsuleError):
            capsule.encode(invalid_parent, self.objects)

    def test_object_domains_truncation_and_extension_reject(self) -> None:
        same_payload = (0x43414D4F00000001, b"same")
        model_ref = capsule.object_ref(0, same_payload)
        tokenizer_ref = capsule.object_ref(1, same_payload)
        self.assertNotEqual(model_ref["sha256"], tokenizer_ref["sha256"])
        for candidate in (self.encoded[:-1], self.encoded + b"\x00"):
            with self.assertRaises(capsule.CapsuleError):
                capsule.decode_and_verify(
                    candidate,
                    self.config,
                    self.objects,
                )


if __name__ == "__main__":
    unittest.main()
