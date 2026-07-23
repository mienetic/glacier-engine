from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_decode_fixture as fixture
from bench import media_transform as transform


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def context(
    spec: dict[str, object],
) -> tuple[
    bytes,
    bytes,
    dict[str, object],
    dict[str, object],
]:
    encoded_fixture = fixture.encode_fixture(spec)
    parsed = fixture.parse_fixture(encoded_fixture)
    decode_plan = fixture.make_decode_plan(
        parsed, digest(0xD1), digest(0xE1)
    )
    encoded_decode_plan = fixture.encode_plan(decode_plan)
    decoded = bytearray(len(spec["payload"]))
    receipt = fixture.decode_fixture(
        encoded_fixture, encoded_decode_plan, decoded
    )
    return encoded_fixture, encoded_decode_plan, parsed, receipt


class MediaTransformTests(unittest.TestCase):
    def test_image_audio_video_outputs_and_mappings(self) -> None:
        cases = (
            (
                fixture.image_spec(),
                lambda parsed, receipt: transform.make_image_plan(
                    parsed,
                    receipt,
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
                ),
                bytes(
                    (
                        0,
                        255,
                        0,
                        0,
                        255,
                        0,
                        255,
                        255,
                        255,
                        255,
                        255,
                        255,
                    )
                ),
                (1, 1, 3, 3),
            ),
            (
                fixture.audio_spec(),
                lambda parsed, receipt: transform.make_audio_plan(
                    parsed,
                    receipt,
                    0,
                    6,
                    16_000,
                    1,
                    0,
                    1,
                    digest(0xF1),
                    digest(0xF2),
                ),
                bytes((0x00, 0xC0, 0x55, 0x15)),
                (0, 3),
            ),
            (
                fixture.video_spec(),
                lambda parsed, receipt: transform.make_video_plan(
                    parsed,
                    receipt,
                    (1,),
                    digest(0xF1),
                    digest(0xF2),
                ),
                bytes((255, 128, 64, 0)),
                (1,),
            ),
        )
        for spec, make_plan, expected, source_units in cases:
            (
                encoded_fixture,
                encoded_decode_plan,
                parsed,
                decode_receipt,
            ) = context(spec)
            encoded_plan = transform.encode_plan(
                make_plan(parsed, decode_receipt)
            )
            destination = bytearray(len(expected))
            receipt, mappings = transform.execute(
                encoded_fixture,
                encoded_decode_plan,
                encoded_plan,
                destination,
            )
            self.assertEqual(bytes(destination), expected)
            self.assertEqual(
                tuple(
                    mapping["source_first_unit"]
                    for mapping in mappings
                ),
                source_units,
            )
            self.assertEqual(
                receipt["mapping_count"], len(source_units)
            )
            self.assertEqual(
                receipt["output_sha256"],
                hashlib.sha256(expected).digest(),
            )

    def test_three_plan_and_receipt_roots_match_goldens(self) -> None:
        expected_plan_roots = (
            "d2f61e8923d642d9dfd0eb9d69cb9d22"
            "03058d02d91a50a3a17ce45f450c0d31",
            "202ed6b0ed607614ebe335d7a4d1f51c9"
            "8c094bb04254a8f5e68912b9fca60ba",
            "9f64b26c5e926893649bfc6f0c09bd16"
            "563c3d500bebc8cd54440422303e6662",
        )
        expected_receipt_roots = (
            "97c68e6b178db4e7b807b80e6987186f"
            "fa1b4ef856a8b1bbbba03b57d3f35da0",
            "02f9d7547a276339cb62666adcbb5568f"
            "8ae23e4f855e0f7966d2616a8e8adc3",
            "9e9fcce71a4419697d2affc2ca6fbe0f"
            "5e4161b5e31f23c3ddee90ba4a4bb1bb",
        )
        makers = (
            (
                fixture.image_spec(),
                lambda parsed, receipt: transform.make_image_plan(
                    parsed,
                    receipt,
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
                ),
            ),
            (
                fixture.audio_spec(),
                lambda parsed, receipt: transform.make_audio_plan(
                    parsed,
                    receipt,
                    0,
                    6,
                    16_000,
                    1,
                    0,
                    1,
                    digest(0xF1),
                    digest(0xF2),
                ),
            ),
            (
                fixture.video_spec(),
                lambda parsed, receipt: transform.make_video_plan(
                    parsed,
                    receipt,
                    (1,),
                    digest(0xF1),
                    digest(0xF2),
                ),
            ),
        )
        for (
            spec,
            make_plan,
        ), expected_plan, expected_receipt in zip(
            makers, expected_plan_roots, expected_receipt_roots
        ):
            (
                encoded_fixture,
                encoded_decode_plan,
                parsed,
                decode_receipt,
            ) = context(spec)
            encoded_plan = transform.encode_plan(
                make_plan(parsed, decode_receipt)
            )
            plan = transform.decode_plan(encoded_plan)
            destination = bytearray(plan["output_bytes"])
            receipt, _ = transform.execute(
                encoded_fixture,
                encoded_decode_plan,
                encoded_plan,
                destination,
            )
            self.assertEqual(
                transform.plan_sha256(encoded_plan).hex(),
                expected_plan,
            )
            self.assertEqual(
                receipt["receipt_sha256"].hex(), expected_receipt
            )

    def test_every_plan_byte_mutation_and_contradiction_reject(self) -> None:
        _, _, parsed, decode_receipt = context(
            fixture.image_spec()
        )
        encoded = transform.encode_plan(
            transform.make_image_plan(
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
        )
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(transform.MediaTransformError):
                    transform.decode_plan(bytes(mutated))

        contradictory = bytearray(encoded)
        struct.pack_into("<Q", contradictory, 176, 2)
        contradictory[-32:] = hashlib.sha256(
            transform.PLAN_DOMAIN + contradictory[:-32]
        ).digest()
        with self.assertRaises(transform.MediaTransformError):
            transform.decode_plan(bytes(contradictory))

    def test_stale_receipt_capacity_and_substitution_fail_closed(
        self,
    ) -> None:
        (
            encoded_fixture,
            encoded_decode_plan,
            parsed,
            decode_receipt,
        ) = context(fixture.video_spec())
        plan = transform.make_video_plan(
            parsed,
            decode_receipt,
            (1,),
            digest(0xF1),
            digest(0xF2),
        )
        plan["decode_receipt_sha256"] = digest(0x99)
        stale = transform.encode_plan(plan)
        destination = bytearray(b"\x5a" * 4)
        with self.assertRaises(transform.MediaTransformError):
            transform.execute(
                encoded_fixture,
                encoded_decode_plan,
                stale,
                destination,
            )
        self.assertEqual(destination, bytearray(b"\x5a" * 4))

        plan["decode_receipt_sha256"] = decode_receipt[
            "receipt_sha256"
        ]
        valid = transform.encode_plan(plan)
        short = bytearray(b"\x5a" * 3)
        with self.assertRaises(transform.MediaTransformError):
            transform.execute(
                encoded_fixture,
                encoded_decode_plan,
                valid,
                short,
            )
        self.assertEqual(short, bytearray(b"\x5a" * 3))

        image_fixture, _, _, _ = context(fixture.image_spec())
        with self.assertRaises(transform.MediaTransformError):
            transform.execute(
                image_fixture,
                encoded_decode_plan,
                valid,
                bytearray(4),
            )


if __name__ == "__main__":
    unittest.main()
