from __future__ import annotations

import copy
import hashlib
import unittest

from bench import continuation_object_sweep_record as record


class ContinuationObjectSweepRecordTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input = record.demo_input()
        self.encoded = record.encode(self.input)
        self.decoded = record.decode(self.encoded)

    def test_fixed_layout_round_trip_append_plan_and_golden(self) -> None:
        self.assertEqual(record.BODY_PREFIX_BYTES, 704)
        self.assertEqual(record.BODY_BYTES, 736)
        self.assertEqual(record.COMMIT_FOOTER_BYTES, 48)
        self.assertEqual(record.ENCODED_BYTES, 784)
        self.assertEqual(self.decoded["input"], self.input)
        plan = record.append_plan(self.encoded)
        self.assertEqual(plan["body"], self.encoded[:736])
        self.assertEqual(plan["commit_footer"], self.encoded[736:])
        self.assertEqual(
            self.decoded["record_sha256"].hex(),
            "a9adfd0946468252bd879acc81456e2a"
            "fe2e145b38f850869c75fd471d0bba06",
        )
        self.assertEqual(
            hashlib.sha256(self.encoded).hexdigest(),
            "3b3fb1adf8ed0b13b8e8719a3ade7db"
            "b2a7133c0ea6d307598ee3b2941d7c6d3",
        )
        chained = copy.deepcopy(self.input)
        chained["sequence"] = 2
        chained["previous_record_sha256"] = self.decoded[
            "record_sha256"
        ]
        chained_decoded = record.decode(record.encode(chained))
        self.assertEqual(chained_decoded["input"]["sequence"], 2)
        self.assertEqual(
            chained_decoded["input"]["previous_record_sha256"],
            self.decoded["record_sha256"],
        )

    def test_every_byte_mutation_truncation_and_extension_fail(self) -> None:
        for index in range(len(self.encoded)):
            corrupted = bytearray(self.encoded)
            corrupted[index] ^= 1
            with self.subTest(kind="mutation", index=index):
                with self.assertRaises(record.SweepRecordError):
                    record.decode(bytes(corrupted))
        for length in range(len(self.encoded)):
            with self.subTest(kind="truncation", length=length):
                with self.assertRaises(record.SweepRecordError):
                    record.decode(self.encoded[:length])
        with self.assertRaises(record.SweepRecordError):
            record.decode(self.encoded + b"\x00")

    def test_rehashed_semantic_contradiction_fails(self) -> None:
        contradiction = bytearray(self.encoded)
        contradiction[record.ACCOUNTING_BEFORE_OFFSET] += 1
        root = record.record_root(bytes(contradiction[: record.BODY_PREFIX_BYTES]))
        contradiction[
            record.BODY_PREFIX_BYTES : record.BODY_BYTES
        ] = root
        footer_root_offset = (
            record.BODY_BYTES + len(record.COMMIT_MAGIC) + 8
        )
        contradiction[footer_root_offset:] = root
        with self.assertRaises(record.SweepRecordError):
            record.decode(bytes(contradiction))

    def test_exact_expectation_rejects_valid_foreign_record(self) -> None:
        expected = record.expectation(
            self.input,
            self.decoded["record_sha256"],
        )
        self.assertEqual(
            record.decode_and_verify(self.encoded, expected),
            self.decoded,
        )
        foreign = record.encode(record.demo_input(0x7A, 0x7B))
        record.decode(foreign)
        with self.assertRaises(record.SweepRecordError):
            record.decode_and_verify(foreign, expected)

    def test_chain_and_embedded_receipt_fail_closed(self) -> None:
        invalid_chain = copy.deepcopy(self.input)
        invalid_chain["sequence"] = 2
        with self.assertRaises(record.SweepRecordError):
            record.encode(invalid_chain)

        invalid_receipt = copy.deepcopy(self.input)
        invalid_receipt["commit_receipt"]["freed_payload_bytes"] += 1
        with self.assertRaises(record.SweepRecordError):
            record.encode(invalid_receipt)


if __name__ == "__main__":
    unittest.main()
