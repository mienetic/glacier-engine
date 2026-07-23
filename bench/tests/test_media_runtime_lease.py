from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_contract as media
from bench import media_decode_fixture as fixture
from bench import media_runtime_lease as runtime
from bench import media_transform as transform


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def context(
    case_index: int,
) -> tuple[bytes, bytes, bytes, dict[str, object], dict[str, object]]:
    spec = (
        fixture.image_spec(),
        fixture.audio_spec(),
        fixture.video_spec(),
    )[case_index]
    encoded_fixture = fixture.encode_fixture(spec)
    parsed = fixture.parse_fixture(encoded_fixture)
    decode_plan = fixture.make_decode_plan(parsed, digest(0xD1), digest(0xE1))
    encoded_decode_plan = fixture.encode_plan(decode_plan)
    decoded = bytearray(len(spec["payload"]))
    decode_receipt = fixture.decode_fixture(
        encoded_fixture, encoded_decode_plan, decoded
    )
    if case_index == 0:
        plan = transform.make_image_plan(
            parsed,
            decode_receipt,
            1,
            0,
            1,
            2,
            2,
            2,
            1,
            1,
            digest(0xF1),
            digest(0xF2),
        )
    elif case_index == 1:
        plan = transform.make_audio_plan(
            parsed,
            decode_receipt,
            0,
            6,
            16_000,
            1,
            0,
            1,
            digest(0xF1),
            digest(0xF2),
        )
    else:
        plan = transform.make_video_plan(
            parsed,
            decode_receipt,
            (1,),
            digest(0xF1),
            digest(0xF2),
        )
    return (
        encoded_fixture,
        encoded_decode_plan,
        transform.encode_plan(plan),
        parsed,
        plan,
    )


def execute_case(
    case_index: int,
) -> tuple[
    dict[str, object],
    dict[str, object],
    bytes,
    bytes,
    bytes,
    dict[str, object],
    list[dict[str, object]],
]:
    (
        encoded_fixture,
        encoded_decode_plan,
        encoded_transform_plan,
        parsed,
        plan,
    ) = context(case_index)
    output = bytearray(plan["output_bytes"])
    transform_receipt, mappings = transform.execute(
        encoded_fixture,
        encoded_decode_plan,
        encoded_transform_plan,
        output,
    )
    state = media.initialize_publication_state(
        2200 + case_index,
        1,
        (1, 1) if case_index == 0 else plan["target_time_base"],
        parsed["media_object_sha256"],
        digest(0xA0 + case_index),
    )
    receipt, state_after = runtime.build_execution_receipt(
        state,
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        bytes(output),
        mappings,
        2100 + case_index,
        2300 + case_index,
        2400 + case_index,
        2500 + case_index,
        2600 + case_index,
    )
    return (
        receipt,
        state_after,
        encoded_fixture,
        encoded_transform_plan,
        bytes(output),
        transform_receipt,
        mappings,
    )


class MediaRuntimeLeaseTests(unittest.TestCase):
    def test_three_modalities_match_native_golden_roots(self) -> None:
        expected_roots = (
            "cca83ca5035449ec2b29e648b87eda12c89aea4cdd5ab4b83cc0f93bfba2f5b7",
            "9c91be075337da603b2a11097b89e54e77e39ba59634d6ae53e82f01a4ae8190",
            "3b8fa40256d53f38ab1e75e790a44af3d354ac478b8725905bbbab9d43d38d2f",
        )
        for case_index, expected_root in enumerate(expected_roots):
            (
                receipt,
                state_after,
                encoded_fixture,
                encoded_transform_plan,
                output,
                transform_receipt,
                mappings,
            ) = execute_case(case_index)
            parsed = fixture.parse_fixture(encoded_fixture)
            plan = transform.decode_plan(encoded_transform_plan)
            state_before = media.initialize_publication_state(
                2200 + case_index,
                1,
                (1, 1) if case_index == 0 else plan["target_time_base"],
                parsed["media_object_sha256"],
                digest(0xA0 + case_index),
            )
            runtime.verify_execution_receipt(
                state_before,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                mappings,
                2300 + case_index,
                2400 + case_index,
                2500 + case_index,
                2600 + case_index,
                receipt,
            )
            self.assertEqual(receipt["receipt_sha256"].hex(), expected_root)
            self.assertEqual(receipt["binding_count"], 3)
            self.assertEqual(receipt["tree"]["active_nodes"], 6)
            self.assertEqual(state_after["visible_chunks"], 1)
            encoded = runtime.encode_receipt(receipt)
            self.assertEqual(len(encoded), runtime.RECEIPT_BYTES)
            self.assertEqual(runtime.decode_receipt(encoded), receipt)

    def test_exact_claim_split_and_binding_roles(self) -> None:
        receipt, *_ = execute_case(0)
        parent = receipt["tree"]["parent"]["claim"]
        dynamic = receipt["tree"]["current"]
        self.assertEqual(
            receipt["total_claim"], runtime._add_claims(parent, dynamic)
        )
        self.assertEqual(
            [binding["role"] for binding in receipt["bindings"][:3]],
            [runtime.DECODED_SOURCE, runtime.MAPPINGS, runtime.OUTPUT],
        )
        self.assertEqual(parent["activation_bytes"], 0)
        self.assertEqual(dynamic["io_bytes"], 0)

    def test_every_wire_byte_and_rehashed_semantics_reject(self) -> None:
        receipt, *_ = execute_case(2)
        encoded = runtime.encode_receipt(receipt)
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(runtime.MediaRuntimeLeaseError):
                    runtime.decode_receipt(bytes(mutated))

        for offset, invalid_value in (
            (32, 99),
            (352, runtime.U32_MAX + 1),
        ):
            with self.subTest(offset=offset, invalid_value=invalid_value):
                malformed = bytearray(encoded)
                struct.pack_into("<Q", malformed, offset, invalid_value)
                malformed[-32:] = hashlib.sha256(
                    runtime.RECEIPT_DOMAIN + malformed[:-32]
                ).digest()
                with self.assertRaises(runtime.MediaRuntimeLeaseError):
                    runtime.decode_receipt(bytes(malformed))

        contradictory = bytearray(encoded)
        struct.pack_into(
            "<Q",
            contradictory,
            112 + 5 * 8,
            receipt["total_claim"]["output_journal_bytes"] + 1,
        )
        contradictory[-32:] = hashlib.sha256(
            runtime.RECEIPT_DOMAIN + contradictory[:-32]
        ).digest()
        decoded = runtime.decode_receipt(bytes(contradictory))
        (
            _,
            _,
            encoded_fixture,
            encoded_transform_plan,
            output,
            transform_receipt,
            mappings,
        ) = execute_case(2)
        plan = transform.decode_plan(encoded_transform_plan)
        parsed = fixture.parse_fixture(encoded_fixture)
        state = media.initialize_publication_state(
            2202,
            1,
            plan["target_time_base"],
            parsed["media_object_sha256"],
            digest(0xA2),
        )
        with self.assertRaises(runtime.MediaRuntimeLeaseError):
            runtime.verify_execution_receipt(
                state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                mappings,
                2302,
                2402,
                2502,
                2602,
                decoded,
            )

    def test_output_binding_and_authority_substitution_reject(self) -> None:
        (
            receipt,
            _,
            encoded_fixture,
            encoded_transform_plan,
            output,
            transform_receipt,
            mappings,
        ) = execute_case(0)
        parsed = fixture.parse_fixture(encoded_fixture)
        state = media.initialize_publication_state(
            2200,
            1,
            (1, 1),
            parsed["media_object_sha256"],
            digest(0xA0),
        )
        damaged_output = bytes((output[0] ^ 1,)) + output[1:]
        with self.assertRaises(
            (runtime.MediaRuntimeLeaseError, transform.MediaTransformError)
        ):
            runtime.verify_execution_receipt(
                state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                damaged_output,
                mappings,
                2300,
                2400,
                2500,
                2600,
                receipt,
            )
        with self.assertRaises(runtime.MediaRuntimeLeaseError):
            runtime.verify_execution_receipt(
                state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                mappings,
                2300,
                2401,
                2500,
                2600,
                receipt,
            )


if __name__ == "__main__":
    unittest.main()
