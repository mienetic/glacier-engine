from __future__ import annotations

import unittest

from bench import provider_cost_journal as journal
from bench import provider_settlement_wire as settlement_wire


class ProviderCostJournalTests(unittest.TestCase):
    def test_cross_language_golden_and_ledger(self) -> None:
        header, encoded, final_root = journal.build_demo_journal()
        self.assertEqual(len(encoded), 5_079)
        self.assertEqual(
            header["header_sha256"].hex(),
            "f778fb16cab3df661e58f8f10fe94e2d"
            "49686da594c45c6824ddfddffeab93ef",
        )
        self.assertEqual(
            final_root.hex(),
            "b8eeb5f018c5be473bdf1e12634a2b2"
            "605b39c3bfde96696f05659b009998edc",
        )
        recovered = journal.verify_closed(
            encoded, header["header_sha256"], final_root
        )
        body, footer = journal.append_plan(
            encoded[
                journal.HEADER_BYTES : journal.HEADER_BYTES + journal.FRAME_BYTES
            ]
        )
        self.assertEqual(len(body), 1_597)
        self.assertEqual(len(footer), 48)
        ledger = recovered["ledger"]
        self.assertEqual(ledger["committed_frames"], 3)
        self.assertEqual(ledger["physical_attempts"], 2)
        self.assertEqual(ledger["settled_attempts"], 2)
        self.assertEqual(ledger["retryable_no_charge_records"], 1)
        self.assertEqual(ledger["ambiguous_records"], 1)
        self.assertEqual(ledger["resolved_records"], 1)
        self.assertEqual(ledger["terminal_requests"], 1)
        self.assertEqual(ledger["open_ambiguous_requests"], 0)
        self.assertEqual(ledger["quoted_nanos"], {"known": True, "value": 1_400_000})
        self.assertEqual(ledger["settled_nanos"], {"known": True, "value": 316_000})
        self.assertEqual(ledger["savings_nanos"], {"known": True, "value": 1_084_000})
        self.assertEqual(ledger["overrun_nanos"], {"known": True, "value": 0})

    def test_every_append_crash_boundary_recovers_committed_prefix(self) -> None:
        header, encoded, _ = journal.build_demo_journal()
        for length in range(journal.HEADER_BYTES, len(encoded) + 1):
            recovered = journal.recover(
                encoded[:length], header["header_sha256"]
            )
            payload = length - journal.HEADER_BYTES
            expected_frames, expected_tail = divmod(payload, journal.FRAME_BYTES)
            self.assertEqual(
                recovered["ledger"]["committed_frames"], expected_frames
            )
            self.assertEqual(recovered["discarded_tail_bytes"], expected_tail)
            self.assertEqual(
                recovered["status"],
                "clean" if expected_tail == 0 else "torn_tail",
            )

    def test_suffix_loss_and_corrupt_committed_footer_reject(self) -> None:
        header, encoded, final_root = journal.build_demo_journal()
        with self.assertRaises(journal.JournalError):
            journal.verify_closed(
                encoded[: -journal.FRAME_BYTES],
                header["header_sha256"],
                final_root,
            )
        torn = journal.recover(encoded[:-1], header["header_sha256"])
        self.assertEqual(torn["status"], "torn_tail")
        self.assertEqual(torn["ledger"]["committed_frames"], 2)

        corrupt = bytearray(encoded)
        corrupt[-journal.COMMIT_FOOTER_BYTES] ^= 1
        with self.assertRaises(journal.JournalError):
            journal.recover(bytes(corrupt), header["header_sha256"])

    def test_duplicate_attempt_and_unmatched_resolution_reject(self) -> None:
        header, encoded, _ = journal.build_demo_journal()
        first = encoded[
            journal.HEADER_BYTES : journal.HEADER_BYTES + journal.FRAME_BYTES
        ]
        first_root = first[
            journal.FRAME_PREFIX_BYTES : journal.FRAME_BODY_BYTES
        ]
        duplicate_cost = journal._cost_envelope(  # noqa: SLF001
            settlement_wire.RETRYABLE_NO_CHARGE, 4
        )
        duplicate = (
            encoded[: journal.HEADER_BYTES]
            + first
            + journal.encode_frame(header, 2, first_root, duplicate_cost)
        )
        with self.assertRaises(journal.JournalError):
            journal.recover(duplicate, header["header_sha256"])

        resolution = journal._cost_envelope(  # noqa: SLF001
            settlement_wire.RESOLVED_SUCCESS, 4
        )
        unmatched = encoded[: journal.HEADER_BYTES] + journal.encode_frame(
            header,
            1,
            header["header_sha256"],
            resolution,
        )
        with self.assertRaises(journal.JournalError):
            journal.recover(unmatched, header["header_sha256"])

    def test_every_serialized_mutation_rejects_under_pinned_roots(self) -> None:
        header, encoded, final_root = journal.build_demo_journal()
        for offset in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[offset] ^= 1
            if offset < 112:
                mutated[: journal.HEADER_BYTES] = journal.reseal_header_for_test(
                    bytes(mutated[: journal.HEADER_BYTES])
                )
            elif offset >= journal.HEADER_BYTES:
                relative = offset - journal.HEADER_BYTES
                frame_index, frame_offset = divmod(relative, journal.FRAME_BYTES)
                if frame_offset < journal.FRAME_PREFIX_BYTES:
                    start = journal.HEADER_BYTES + frame_index * journal.FRAME_BYTES
                    end = start + journal.FRAME_BYTES
                    mutated[start:end] = journal.reseal_frame_for_test(
                        bytes(mutated[start:end]), header["header_sha256"]
                    )
            with self.assertRaises(journal.JournalError, msg=f"offset {offset}"):
                journal.verify_closed(
                    bytes(mutated), header["header_sha256"], final_root
                )


if __name__ == "__main__":
    unittest.main()
