from __future__ import annotations

import hashlib
import struct
import unittest

from bench import continuation_live_restart as live


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def fixture() -> dict[str, object]:
    outputs = [0] * live.MAX_OUTPUT_TOKENS
    outputs[:2] = [101, 102]
    return {
        "request_epoch": 71,
        "publication_next_sequence": 17,
        "checkpoint_generation": 4,
        "kv_tokens": 16,
        "output_token_count": 2,
        "sampling_calls": 2,
        "rng_state": [1, 2, 3, 4],
        "previous_commit_sha256": digest(0x51),
        "logical_kv_sha256": digest(0x52),
        "challenge_sha256": digest(0x53),
        "output_tokens": outputs,
    }


def root(generation: int, committed_len: int, pages: int) -> dict[str, object]:
    return {
        "abi_version": live.PAGE_MAP_ROOT_ABI,
        "cache_instance": 900,
        "generation": generation,
        "committed_len": committed_len,
        "committed_pages": pages,
        "ownership_sha256": digest(0x70 + generation),
    }


class ContinuationLiveRestartTests(unittest.TestCase):
    def test_runtime_golden_and_every_byte_mutation(self) -> None:
        encoded = live.encode(fixture())
        self.assertEqual(len(encoded), live.RUNTIME_STATE_BYTES)
        self.assertEqual(live.decode(encoded), fixture())
        self.assertEqual(
            encoded[-32:].hex(),
            "3817f7c8078688de1b22072e8bc2f45a"
            "801f2de0d3b825d4cfdada6135b0ada9",
        )
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(live.LiveRestartError):
                    live.decode(bytes(mutated))

        contradiction = bytearray(encoded)
        struct.pack_into("<I", contradiction, 28, 1)
        contradiction[-32:] = hashlib.sha256(
            live.RUNTIME_STATE_DOMAIN + contradiction[:-32]
        ).digest()
        with self.assertRaises(live.LiveRestartError):
            live.decode(bytes(contradiction))

    def test_resume_appends_once_and_chains_previous_commit(self) -> None:
        before = fixture()
        next_state, receipt = live.advance(
            before,
            token_id=103,
            rng_after=[2, 3, 4, 5],
            sampling_calls_after=3,
            root_before=root(8, 16, 1),
            root_after=root(9, 17, 2),
            logical_kv_after_sha256=digest(0x54),
            permit_generation=7,
        )
        self.assertEqual(
            next_state["output_tokens"][:3],
            [101, 102, 103],
        )
        self.assertEqual(next_state["output_token_count"], 3)
        self.assertEqual(next_state["kv_tokens"], 17)
        self.assertEqual(next_state["publication_next_sequence"], 18)
        self.assertEqual(
            receipt["previous_commit_sha256"],
            before["previous_commit_sha256"],
        )
        self.assertEqual(
            next_state["previous_commit_sha256"],
            receipt["commit_sha256"],
        )
        self.assertEqual(
            receipt["commit_sha256"],
            live.resume_receipt_root(receipt),
        )
        self.assertEqual(
            receipt["output_sha256"].hex(),
            "9ee5866300196621498083280108d1cc"
            "36b322c28e93a234d20b231b8c6a42e2",
        )
        self.assertEqual(
            receipt["commit_sha256"].hex(),
            "42fd59983f808664141334276a05bec49"
            "7b8ebae91a728094ca926b60916ebb7",
        )

    def test_resume_rejects_stale_or_duplicate_position(self) -> None:
        with self.assertRaises(live.LiveRestartError):
            live.advance(
                fixture(),
                token_id=103,
                rng_after=[2, 3, 4, 5],
                sampling_calls_after=3,
                root_before=root(8, 15, 1),
                root_after=root(9, 17, 2),
                logical_kv_after_sha256=digest(0x54),
                permit_generation=7,
            )


if __name__ == "__main__":
    unittest.main()
