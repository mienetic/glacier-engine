from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_contract as media
from bench import media_decode_fixture as fixture
from bench import media_runtime_lease as lease
from bench import media_stream_runtime as stream
from bench import media_transform as transform


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def image_context() -> tuple[bytes, bytes, dict[str, object], dict[str, object]]:
    spec = fixture.image_spec()
    encoded_fixture = fixture.encode_fixture(spec)
    parsed = fixture.parse_fixture(encoded_fixture)
    decode_plan = fixture.make_decode_plan(parsed, digest(0xD1), digest(0xE1))
    encoded_decode_plan = fixture.encode_plan(decode_plan)
    decoded = bytearray(len(spec["payload"]))
    decode_receipt = fixture.decode_fixture(
        encoded_fixture, encoded_decode_plan, decoded
    )
    return encoded_fixture, encoded_decode_plan, parsed, decode_receipt


def execute_chain() -> tuple[
    list[dict[str, object]],
    list[dict[str, object]],
    list[dict[str, object]],
]:
    encoded_fixture, encoded_decode_plan, parsed, decode_receipt = image_context()
    state = media.initialize_publication_state(
        4100,
        1,
        (1, 1),
        parsed["media_object_sha256"],
        digest(0xA0),
    )
    executions: list[dict[str, object]] = []
    chunks: list[dict[str, object]] = []
    states: list[dict[str, object]] = []
    previous = stream.ZERO_DIGEST
    for chunk_index in range(2):
        plan = transform.make_image_plan(
            parsed,
            decode_receipt,
            0,
            chunk_index,
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
        state_before = dict(state)
        execution, state = lease.build_execution_receipt(
            state_before,
            encoded_fixture,
            encoded_plan,
            transform_receipt,
            bytes(output),
            mappings,
            4200 + chunk_index,
            4300 + chunk_index,
            4400 + chunk_index,
            4500 + chunk_index,
            4600,
        )
        chunk = stream.make_chunk_receipt(
            state_before,
            4700,
            chunk_index,
            previous,
            execution,
        )
        states.append(state_before)
        executions.append(execution)
        chunks.append(chunk)
        previous = chunk["receipt_sha256"]
    return states, executions, chunks


class MediaStreamRuntimeTests(unittest.TestCase):
    def test_two_chunk_chain_matches_native_golden_roots(self) -> None:
        expected = (
            "0eb696df27c1f226b84751fedce6f12efc566638753b16b278c22eb77ac52e15",
            "db980b306c8779fc7f3c0d44d83f1509b0f276a2bc433cab61e462db271461ec",
        )
        states, executions, chunks = execute_chain()
        for index, (state, execution, chunk, expected_root) in enumerate(
            zip(states, executions, chunks, expected)
        ):
            previous = (
                stream.ZERO_DIGEST
                if index == 0
                else chunks[index - 1]["receipt_sha256"]
            )
            stream.verify_chunk_receipt(
                state,
                4700,
                index,
                previous,
                execution,
                chunk,
            )
            self.assertEqual(chunk["receipt_sha256"].hex(), expected_root)
            encoded = stream.encode_receipt(chunk)
            self.assertEqual(len(encoded), stream.CHUNK_RECEIPT_BYTES)
            self.assertEqual(stream.decode_receipt(encoded), chunk)
        self.assertEqual(
            chunks[1]["previous_chunk_sha256"],
            chunks[0]["receipt_sha256"],
        )

    def test_every_wire_byte_and_rehashed_contradiction_reject(self) -> None:
        states, executions, chunks = execute_chain()
        encoded = stream.encode_receipt(chunks[1])
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(stream.MediaStreamRuntimeError):
                    stream.decode_receipt(bytes(mutated))

        contradictory = bytearray(encoded)
        struct.pack_into(
            "<Q",
            contradictory,
            80,
            chunks[1]["units_after"] + 1,
        )
        contradictory[-32:] = hashlib.sha256(
            stream.RECEIPT_DOMAIN + contradictory[:-32]
        ).digest()
        decoded = stream.decode_receipt(bytes(contradictory))
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.verify_chunk_receipt(
                states[1],
                4700,
                1,
                chunks[0]["receipt_sha256"],
                executions[1],
                decoded,
            )

        excessive_index = bytearray(encoded)
        struct.pack_into(
            "<Q",
            excessive_index,
            56,
            stream.MAXIMUM_STREAM_CHUNKS,
        )
        excessive_index[-32:] = hashlib.sha256(
            stream.RECEIPT_DOMAIN + excessive_index[:-32]
        ).digest()
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.decode_receipt(bytes(excessive_index))

        excessive_provisional = bytearray(encoded)
        struct.pack_into(
            "<Q",
            excessive_provisional,
            112,
            stream.U64_MAX,
        )
        excessive_provisional[-32:] = hashlib.sha256(
            stream.RECEIPT_DOMAIN + excessive_provisional[:-32]
        ).digest()
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.decode_receipt(bytes(excessive_provisional))

    def test_stream_key_previous_execution_and_state_substitution_reject(
        self,
    ) -> None:
        states, executions, chunks = execute_chain()
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.verify_chunk_receipt(
                states[1],
                4701,
                1,
                chunks[0]["receipt_sha256"],
                executions[1],
                chunks[1],
            )
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.verify_chunk_receipt(
                states[1],
                4700,
                1,
                digest(0xEE),
                executions[1],
                chunks[1],
            )
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.verify_chunk_receipt(
                states[0],
                4700,
                1,
                chunks[0]["receipt_sha256"],
                executions[1],
                chunks[1],
            )
        with self.assertRaises(stream.MediaStreamRuntimeError):
            stream.verify_chunk_receipt(
                states[1],
                4700,
                1,
                chunks[0]["receipt_sha256"],
                executions[0],
                chunks[1],
            )


if __name__ == "__main__":
    unittest.main()
