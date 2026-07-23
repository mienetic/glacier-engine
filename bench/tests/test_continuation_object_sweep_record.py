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

    @staticmethod
    def encoded_stream(count: int) -> bytes:
        previous = record.ZERO_DIGEST
        encoded_records = []
        for index in range(count):
            value = record.demo_input(0x6A + index, 0x6B + index)
            value["sequence"] = index + 1
            value["previous_record_sha256"] = previous
            encoded = record.encode(value)
            previous = record.decode(encoded)["record_sha256"]
            encoded_records.append(encoded)
        return b"".join(encoded_records)

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

    def test_recovery_classifier_clean_origin_and_suffix(self) -> None:
        stream = self.encoded_stream(3)
        anchor = record.origin_recovery_anchor()
        empty = record.classify_recovery(b"", anchor)
        self.assertEqual(empty["status"], "clean")
        self.assertEqual(empty["committed_records"], 0)
        self.assertEqual(empty["last_sequence"], 0)
        self.assertEqual(empty["final_record_sha256"], record.ZERO_DIGEST)

        clean = record.classify_recovery(stream, anchor)
        self.assertEqual(clean["status"], "clean")
        self.assertEqual(clean["committed_records"], 3)
        self.assertEqual(clean["first_sequence"], 1)
        self.assertEqual(clean["last_sequence"], 3)
        self.assertEqual(clean["committed_bytes"], len(stream))
        self.assertEqual(clean["tail_bytes"], 0)
        self.assertEqual(
            hashlib.sha256(stream).hexdigest(),
            "03c9ce6901d43ef0a7b262e003dc59a1e"
            "e1259cdb4fe9b9c28a0a429ac0396bf",
        )

        first = record.decode(stream[: record.ENCODED_BYTES])
        suffix_anchor = {
            "record_epoch": anchor["record_epoch"],
            "next_sequence": 2,
            "previous_record_sha256": first["record_sha256"],
        }
        empty_suffix = record.classify_recovery(b"", suffix_anchor)
        self.assertEqual(empty_suffix["status"], "clean")
        self.assertEqual(empty_suffix["committed_records"], 0)
        self.assertEqual(empty_suffix["last_sequence"], 1)
        self.assertEqual(
            empty_suffix["final_record_sha256"],
            first["record_sha256"],
        )
        suffix = record.classify_recovery(
            stream[record.ENCODED_BYTES :],
            suffix_anchor,
        )
        self.assertEqual(suffix["status"], "clean")
        self.assertEqual(suffix["committed_records"], 2)
        self.assertEqual(suffix["first_sequence"], 2)
        self.assertEqual(suffix["last_sequence"], 3)
        self.assertEqual(
            suffix["final_record_sha256"],
            clean["final_record_sha256"],
        )

    def test_recovery_classifier_every_append_boundary(self) -> None:
        stream = self.encoded_stream(2)
        anchor = record.origin_recovery_anchor()
        first = record.decode(stream[: record.ENCODED_BYTES])
        second = record.decode(stream[record.ENCODED_BYTES :])
        self.assertEqual(
            hashlib.sha256(stream).hexdigest(),
            "25009ee1f7e27989e54554fc797f19ce"
            "c21dd96d3c392f25364d7ab868ee5538",
        )
        for tail_length in range(record.ENCODED_BYTES + 1):
            classified = record.classify_recovery(
                stream[: record.ENCODED_BYTES + tail_length],
                anchor,
            )
            if tail_length in (0, record.ENCODED_BYTES):
                expected_status = "clean"
            elif tail_length < record.BODY_BYTES:
                expected_status = "short_body_tail"
            elif tail_length == record.BODY_BYTES:
                expected_status = "body_without_footer"
            else:
                expected_status = "partial_footer_tail"
            with self.subTest(tail_length=tail_length):
                self.assertEqual(classified["status"], expected_status)
                expected_records = (
                    2 if tail_length == record.ENCODED_BYTES else 1
                )
                self.assertEqual(
                    classified["committed_records"],
                    expected_records,
                )
                self.assertEqual(
                    classified["committed_bytes"],
                    expected_records * record.ENCODED_BYTES,
                )
                self.assertEqual(
                    classified["tail_bytes"],
                    0
                    if tail_length == record.ENCODED_BYTES
                    else tail_length,
                )
                self.assertEqual(
                    classified["final_record_sha256"],
                    second["record_sha256"]
                    if tail_length == record.ENCODED_BYTES
                    else first["record_sha256"],
                )

        corrupt_partial = bytearray(stream)
        corrupt_partial[
            record.ENCODED_BYTES + record.BODY_BYTES
        ] ^= 1
        classified = record.classify_recovery(
            bytes(
                corrupt_partial[
                    : record.ENCODED_BYTES + record.BODY_BYTES + 1
                ]
            ),
            anchor,
        )
        self.assertEqual(classified["status"], "corrupt_record")
        self.assertEqual(classified["committed_records"], 1)

    def test_recovery_classifier_mutation_semantics_and_chain(self) -> None:
        stream = self.encoded_stream(2)
        anchor = record.origin_recovery_anchor()
        first = record.decode(stream[: record.ENCODED_BYTES])
        for index in range(record.ENCODED_BYTES):
            corrupted = bytearray(stream)
            corrupted[record.ENCODED_BYTES + index] ^= 1
            classified = record.classify_recovery(bytes(corrupted), anchor)
            with self.subTest(kind="complete_mutation", index=index):
                self.assertEqual(classified["status"], "corrupt_record")
                self.assertEqual(classified["committed_records"], 1)
                self.assertEqual(
                    classified["committed_bytes"],
                    record.ENCODED_BYTES,
                )

        contradiction = bytearray(stream)
        contradiction[
            record.ENCODED_BYTES + record.ACCOUNTING_BEFORE_OFFSET
        ] += 1
        body_start = record.ENCODED_BYTES
        prefix_end = body_start + record.BODY_PREFIX_BYTES
        body_end = body_start + record.BODY_BYTES
        root = record.record_root(bytes(contradiction[body_start:prefix_end]))
        contradiction[prefix_end:body_end] = root
        footer_root = body_end + len(record.COMMIT_MAGIC) + 8
        contradiction[footer_root : body_start + record.ENCODED_BYTES] = root
        classified = record.classify_recovery(bytes(contradiction), anchor)
        self.assertEqual(classified["status"], "corrupt_record")

        foreign = record.demo_input(0x7A, 0x7B)
        foreign["sequence"] = 2
        foreign["previous_record_sha256"] = bytes((0x7C,)) * 32
        classified = record.classify_recovery(
            stream[: record.ENCODED_BYTES] + record.encode(foreign),
            anchor,
        )
        self.assertEqual(classified["status"], "corrupt_record")

        foreign["record_epoch"] += 1
        foreign["previous_record_sha256"] = first["record_sha256"]
        classified = record.classify_recovery(
            stream[: record.ENCODED_BYTES] + record.encode(foreign),
            anchor,
        )
        self.assertEqual(classified["status"], "corrupt_record")

        foreign["record_epoch"] = anchor["record_epoch"]
        foreign["sequence"] = 3
        classified = record.classify_recovery(
            stream[: record.ENCODED_BYTES] + record.encode(foreign),
            anchor,
        )
        self.assertEqual(classified["status"], "corrupt_record")

    def test_recovery_classifier_rejects_invalid_anchor(self) -> None:
        valid = record.origin_recovery_anchor()
        invalid = dict(valid)
        invalid["record_epoch"] = 0
        with self.assertRaises(record.SweepRecordError):
            record.classify_recovery(b"", invalid)
        invalid = dict(valid)
        invalid["next_sequence"] = 2
        with self.assertRaises(record.SweepRecordError):
            record.classify_recovery(b"", invalid)
        invalid = dict(valid)
        invalid["previous_record_sha256"] = bytes((0x81,)) * 32
        with self.assertRaises(record.SweepRecordError):
            record.classify_recovery(b"", invalid)

        terminal_input = record.demo_input(0x82, 0x83)
        terminal_input["sequence"] = 0xFFFFFFFFFFFFFFFF
        terminal_input["previous_record_sha256"] = bytes((0x84,)) * 32
        terminal_record = record.encode(terminal_input)
        terminal_anchor = {
            "record_epoch": terminal_input["record_epoch"],
            "next_sequence": terminal_input["sequence"],
            "previous_record_sha256": terminal_input[
                "previous_record_sha256"
            ],
        }
        terminal = record.classify_recovery(
            terminal_record,
            terminal_anchor,
        )
        self.assertEqual(terminal["status"], "clean")
        overflow = record.classify_recovery(
            terminal_record + b"\x00",
            terminal_anchor,
        )
        self.assertEqual(overflow["status"], "corrupt_record")
        self.assertEqual(overflow["committed_records"], 1)


if __name__ == "__main__":
    unittest.main()
