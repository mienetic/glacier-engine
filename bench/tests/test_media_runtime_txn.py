from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_contract as media
from bench import media_decode_fixture as fixture
from bench import media_runtime_txn as runtime
from bench import media_transform as transform


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def context(
    case_index: int,
) -> tuple[
    bytes,
    bytes,
    bytes,
    dict[str, object],
    dict[str, object],
]:
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
        900 + case_index,
        1,
        runtime.output_timeline_base(plan),
        parsed["media_object_sha256"],
        digest(0xA0 + case_index),
    )
    claim = runtime.claim_for_execution(len(encoded_fixture), plan)
    resource_receipt = runtime.resource_receipt(
        800 + case_index,
        0,
        1,
        700 + case_index,
        claim,
    )
    receipt, state_after = runtime.build_execution_receipt(
        state,
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        bytes(output),
        mappings,
        resource_receipt,
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


class MediaRuntimeTxnTests(unittest.TestCase):
    def test_three_modalities_match_native_golden_roots(self) -> None:
        expected_roots = (
            "4fd2368c0b7a34db2e69b378ca43fb87354a0363e27f0b58a63e1eda49b3b711",
            "a636e11e16f55a6fa1bf9ee6bfc1b7e5add14bf077b0afd913e11bd01dfb6025",
            "7b9f97e839e9b0f85bb361d634c695f73eb3b0d49316668ecea81c050d33eebb",
        )
        expected_claims = (
            (12, 12, 512, 364),
            (32, 4, 256, 384),
            (8, 4, 128, 360),
        )
        for case_index, expected_root, expected_claim in zip(
            range(3), expected_roots, expected_claims
        ):
            (
                receipt,
                state_after,
                encoded_fixture,
                encoded_transform_plan,
                output,
                transform_receipt,
                mappings,
            ) = execute_case(case_index)
            state_before = media.initialize_publication_state(
                900 + case_index,
                1,
                runtime.output_timeline_base(
                    transform.decode_plan(encoded_transform_plan)
                ),
                fixture.parse_fixture(encoded_fixture)["media_object_sha256"],
                digest(0xA0 + case_index),
            )
            runtime.verify_execution_receipt(
                state_before,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                mappings,
                receipt,
            )
            self.assertEqual(receipt["receipt_sha256"].hex(), expected_root)
            self.assertEqual(
                (
                    receipt["claim"]["activation_bytes"],
                    receipt["claim"]["output_journal_bytes"],
                    receipt["claim"]["staging_bytes"],
                    receipt["claim"]["io_bytes"],
                ),
                expected_claim,
            )
            self.assertEqual(state_after["visible_chunks"], 1)
            self.assertEqual(state_after["visible_units"], receipt["logical_units"])
            encoded = runtime.encode_receipt(receipt)
            self.assertEqual(len(encoded), runtime.RECEIPT_BYTES)
            self.assertEqual(runtime.decode_receipt(encoded), receipt)

    def test_every_wire_byte_and_rehashed_contradiction_rejects(
        self,
    ) -> None:
        receipt, *_ = execute_case(2)
        encoded = runtime.encode_receipt(receipt)
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(runtime.MediaRuntimeTxnError):
                    runtime.decode_receipt(bytes(mutated))

        contradictory = bytearray(encoded)
        struct.pack_into("<Q", contradictory, 88, 2)
        contradictory[-32:] = hashlib.sha256(
            runtime.RECEIPT_DOMAIN + contradictory[:-32]
        ).digest()
        with self.assertRaises(runtime.MediaRuntimeTxnError):
            runtime.decode_receipt(bytes(contradictory))

    def test_resource_output_mapping_and_state_substitution_reject(
        self,
    ) -> None:
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
        plan = transform.decode_plan(encoded_transform_plan)
        state = media.initialize_publication_state(
            900,
            1,
            runtime.output_timeline_base(plan),
            parsed["media_object_sha256"],
            digest(0xA0),
        )

        damaged_output = bytes((output[0] ^ 1,)) + output[1:]
        with self.assertRaises(
            (runtime.MediaRuntimeTxnError, transform.MediaTransformError)
        ):
            runtime.verify_execution_receipt(
                state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                damaged_output,
                mappings,
                receipt,
            )

        damaged_mappings = [dict(mapping) for mapping in mappings]
        damaged_mappings[0]["source_first_unit"] = 0
        with self.assertRaises(
            (runtime.MediaRuntimeTxnError, transform.MediaTransformError)
        ):
            runtime.verify_execution_receipt(
                state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                damaged_mappings,
                receipt,
            )

        stale_state = dict(state)
        stale_state["previous_commit_sha256"] = digest(0xEE)
        with self.assertRaises(runtime.MediaRuntimeTxnError):
            runtime.verify_execution_receipt(
                stale_state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                mappings,
                receipt,
            )

        forged_receipt = dict(receipt)
        forged_receipt["resource_integrity"] ^= 1
        forged_receipt["receipt_sha256"] = runtime.receipt_root(forged_receipt)
        with self.assertRaises(runtime.MediaRuntimeTxnError):
            runtime.verify_execution_receipt(
                state,
                encoded_fixture,
                encoded_transform_plan,
                transform_receipt,
                output,
                mappings,
                forged_receipt,
            )

    def test_claim_rejects_overflow(self) -> None:
        _, _, encoded_plan, _, plan = context(0)
        self.assertEqual(
            runtime.claim_for_execution(364, plan)["capsule_bytes"],
            fixture.PLAN_BYTES + transform.PLAN_BYTES,
        )
        with self.assertRaises(runtime.MediaRuntimeTxnError):
            runtime.claim_for_execution(
                runtime.U64_MAX + 1,
                transform.decode_plan(encoded_plan),
            )


if __name__ == "__main__":
    unittest.main()
