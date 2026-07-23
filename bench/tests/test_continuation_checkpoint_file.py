from __future__ import annotations

import hashlib
import struct
import unittest

from bench import continuation_checkpoint_file as checkpoint


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def first_set() -> bytes:
    return checkpoint.encode_set(
        {
            "generation": 1,
            "request_epoch": 71,
            "publication_next_sequence": 17,
            "parent_checkpoint_sha256": checkpoint.ZERO_DIGEST,
            "challenge_sha256": digest(0x53),
        },
        [
            {
                "kind": 1,
                "ordinal": 0,
                "abi_version": 11,
                "bytes": b"capsule-fixture",
            },
            {
                "kind": 5,
                "ordinal": 0,
                "abi_version": 12,
                "bytes": b"runtime-fixture",
            },
        ],
    )


class ContinuationCheckpointFileTests(unittest.TestCase):
    def test_set_and_selector_golden_mutation_complete(self) -> None:
        encoded = first_set()
        decoded = checkpoint.decode_set(encoded)
        self.assertEqual(
            [entry["kind"] for entry in decoded["objects"]],
            [1, 5],
        )
        self.assertEqual(
            decoded["checkpoint_sha256"].hex(),
            "28a31df6cf0972481ce2e17b3fb0b54f"
            "217c3c54025d746f05fe93b58ea697dc",
        )
        for index in range(len(encoded)):
            with self.subTest(kind="set", index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(checkpoint.CheckpointFileError):
                    checkpoint.decode_set(bytes(mutated))

        selector = checkpoint.prepare_selector(
            checkpoint.ZERO_DIGEST,
            encoded,
        )
        self.assertEqual(
            checkpoint.decode_selector(selector)[
                "selector_sha256"
            ].hex(),
            "789052b3ce4994889bee859e3f180b576"
            "bd26ce89ab8b90b51f9c8aae55a43df",
        )
        for index in range(len(selector)):
            with self.subTest(kind="selector", index=index):
                mutated = bytearray(selector)
                mutated[index] ^= 1
                with self.assertRaises(checkpoint.CheckpointFileError):
                    checkpoint.decode_selector(bytes(mutated))

    def test_rehashed_semantic_contradictions_reject(self) -> None:
        encoded = bytearray(first_set())
        struct.pack_into("<Q", encoded, 56, 1)
        encoded[-32:] = hashlib.sha256(
            checkpoint.SET_DOMAIN + encoded[:-32]
        ).digest()
        with self.assertRaises(checkpoint.CheckpointFileError):
            checkpoint.decode_set(bytes(encoded))

        selector = bytearray(
            checkpoint.prepare_selector(
                checkpoint.ZERO_DIGEST,
                first_set(),
            )
        )
        struct.pack_into("<Q", selector, 56, 1)
        selector[-32:] = hashlib.sha256(
            checkpoint.SELECTOR_DOMAIN + selector[:-32]
        ).digest()
        with self.assertRaises(checkpoint.CheckpointFileError):
            checkpoint.decode_selector(bytes(selector))

    def test_recovery_accepts_only_previous_or_successor(self) -> None:
        initial = first_set()
        initial_selector = checkpoint.prepare_selector(
            checkpoint.ZERO_DIGEST,
            initial,
        )
        initial_decoded = checkpoint.decode_set(initial)
        successor = checkpoint.encode_set(
            {
                "generation": 2,
                "request_epoch": 71,
                "publication_next_sequence": 18,
                "parent_checkpoint_sha256": initial_decoded[
                    "checkpoint_sha256"
                ],
                "challenge_sha256": digest(0x53),
            },
            [
                {
                    "kind": 1,
                    "ordinal": 0,
                    "abi_version": 11,
                    "bytes": b"capsule-successor",
                }
            ],
        )
        successor_selector = checkpoint.prepare_selector(
            checkpoint.decode_selector(initial_selector)[
                "selector_sha256"
            ],
            successor,
        )
        self.assertEqual(
            checkpoint.recover(
                initial,
                initial_selector,
                successor,
                successor_selector,
            ),
            "applied",
        )
        self.assertEqual(
            checkpoint.recover(
                successor,
                successor_selector,
                successor,
                successor_selector,
            ),
            "already_applied",
        )
        foreign = checkpoint.encode_set(
            {
                "generation": 1,
                "request_epoch": 71,
                "publication_next_sequence": 17,
                "parent_checkpoint_sha256": checkpoint.ZERO_DIGEST,
                "challenge_sha256": digest(0x53),
            },
            [
                {
                    "kind": 1,
                    "ordinal": 0,
                    "abi_version": 11,
                    "bytes": b"foreign",
                }
            ],
        )
        foreign_selector = checkpoint.prepare_selector(
            checkpoint.ZERO_DIGEST,
            foreign,
        )
        with self.assertRaises(checkpoint.CheckpointFileError):
            checkpoint.recover(
                foreign,
                foreign_selector,
                successor,
                successor_selector,
            )


if __name__ == "__main__":
    unittest.main()
