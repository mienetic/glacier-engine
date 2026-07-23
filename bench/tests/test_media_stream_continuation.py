from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_contract as media
from bench import media_decode_fixture as fixture
from bench import media_runtime_lease as lease
from bench import media_stream_continuation as continuation
from bench import media_stream_runtime as stream
from bench import media_transform as transform


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def image_checkpoint() -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
    bytes,
]:
    spec = fixture.image_spec()
    encoded_fixture = fixture.encode_fixture(spec)
    parsed = fixture.parse_fixture(encoded_fixture)
    decode_plan = fixture.make_decode_plan(
        parsed,
        digest(0xD1),
        digest(0xE1),
    )
    encoded_decode_plan = fixture.encode_plan(decode_plan)
    decoded = bytearray(len(spec["payload"]))
    decode_receipt = fixture.decode_fixture(
        encoded_fixture,
        encoded_decode_plan,
        decoded,
    )
    state_before = media.initialize_publication_state(
        6200,
        1,
        (1, 1),
        parsed["media_object_sha256"],
        digest(0xA0),
    )
    plan = transform.make_image_plan(
        parsed,
        decode_receipt,
        0,
        0,
        2,
        1,
        2,
        1,
        1,
        1,
        digest(0xF1),
        digest(0xF2),
    )
    encoded_plan = transform.encode_plan(plan)
    output = bytearray(plan["output_bytes"])
    transform_receipt, mappings = transform.execute(
        encoded_fixture,
        encoded_decode_plan,
        encoded_plan,
        output,
    )
    execution, state_after = lease.build_execution_receipt(
        state_before,
        encoded_fixture,
        encoded_plan,
        transform_receipt,
        bytes(output),
        mappings,
        6100,
        6310,
        6320,
        6330,
        6340,
    )
    chunk = stream.make_chunk_receipt(
        state_before,
        6300,
        0,
        stream.ZERO_DIGEST,
        execution,
    )
    checkpoint = continuation.make_checkpoint(
        state_after,
        media.IMAGE,
        6300,
        {
            "checkpoint_generation": 1,
            "chunk_limit": 2,
            "restore_bank_epoch": 6400,
            "restore_owner_key_base": 6410,
            "restore_tree_key_base": 6420,
            "restore_authority_key_base": 6430,
            "next_owner_key_base": 6440,
            "next_tree_key_base": 6450,
            "next_authority_key_base": 6460,
            "tenant_key": 6470,
            "challenge_sha256": digest(0xC0),
        },
        [execution],
        [chunk],
        [bytes(output)],
    )
    return checkpoint, execution, chunk, bytes(output)


class MediaStreamContinuationTests(unittest.TestCase):
    def test_checkpoint_round_trip_and_golden_root(self) -> None:
        checkpoint, _execution, _chunk, output = image_checkpoint()
        expected = (
            "4ff87146ea02e635fd80bd90ea96fb98aac6a8592777f6147"
            "3f7aa58e6899bdf"
        )
        self.assertEqual(
            checkpoint["checkpoint_sha256"].hex(),
            expected,
        )
        encoded = continuation.encode_checkpoint(checkpoint)
        self.assertEqual(len(encoded), continuation.CHECKPOINT_BYTES)
        self.assertEqual(
            continuation.decode_checkpoint(encoded),
            checkpoint,
        )
        continuation.verify_materialized_outputs(
            checkpoint,
            [output],
        )

    def test_every_wire_byte_and_rehashed_contradiction_reject(self) -> None:
        checkpoint, _execution, _chunk, _output = image_checkpoint()
        encoded = continuation.encode_checkpoint(checkpoint)
        for index in range(len(encoded)):
            with self.subTest(index=index):
                corrupted = bytearray(encoded)
                corrupted[index] ^= 1
                with self.assertRaises(
                    continuation.MediaStreamContinuationError
                ):
                    continuation.decode_checkpoint(bytes(corrupted))

        contradictory = bytearray(encoded)
        struct.pack_into(
            "<Q",
            contradictory,
            128,
            checkpoint["entries"][0]["source_bank_epoch"],
        )
        contradictory[-32:] = hashlib.sha256(
            continuation.CHECKPOINT_DOMAIN + contradictory[:-32]
        ).digest()
        with self.assertRaises(
            continuation.MediaStreamContinuationError
        ):
            continuation.decode_checkpoint(bytes(contradictory))

    def test_materialization_and_input_substitution_reject(self) -> None:
        checkpoint, execution, chunk, output = image_checkpoint()
        wrong = bytearray(output)
        wrong[0] ^= 1
        with self.assertRaises(
            continuation.MediaStreamContinuationError
        ):
            continuation.verify_materialized_outputs(
                checkpoint,
                [bytes(wrong)],
            )

        state = {
            "request_epoch": checkpoint["request_epoch"],
            "next_sequence": checkpoint["next_sequence"],
            "visible_chunks": checkpoint["visible_chunks"],
            "visible_units": checkpoint["visible_units"],
            "timeline_base": (
                checkpoint["timeline_numerator"],
                checkpoint["timeline_denominator"],
            ),
            "media_object_sha256": checkpoint["media_object_sha256"],
            "timeline_sha256": checkpoint["timeline_sha256"],
            "previous_commit_sha256": checkpoint[
                "previous_commit_sha256"
            ],
        }
        substituted = dict(execution)
        substituted["output_sha256"] = digest(0xEE)
        with self.assertRaises(
            (
                continuation.MediaStreamContinuationError,
                lease.MediaRuntimeLeaseError,
            )
        ):
            continuation.make_checkpoint(
                state,
                media.IMAGE,
                6300,
                {
                    "checkpoint_generation": 1,
                    "chunk_limit": 2,
                    "restore_bank_epoch": 6400,
                    "restore_owner_key_base": 6410,
                    "restore_tree_key_base": 6420,
                    "restore_authority_key_base": 6430,
                    "next_owner_key_base": 6440,
                    "next_tree_key_base": 6450,
                    "next_authority_key_base": 6460,
                    "tenant_key": 6470,
                    "challenge_sha256": digest(0xC0),
                },
                [substituted],
                [chunk],
                [output],
            )


if __name__ == "__main__":
    unittest.main()
