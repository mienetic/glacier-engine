from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_decode_fixture as fixture


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def encoded_pair(
    spec: dict[str, object],
) -> tuple[bytes, bytes, dict[str, object]]:
    encoded_fixture = fixture.encode_fixture(spec)
    parsed = fixture.parse_fixture(encoded_fixture)
    plan = fixture.make_decode_plan(
        parsed,
        digest(0xD1),
        digest(0xE1),
    )
    return encoded_fixture, fixture.encode_plan(plan), parsed


class MediaDecodeFixtureTests(unittest.TestCase):
    def test_three_fixtures_plans_and_receipts_match_goldens(self) -> None:
        expected_units = (4, 8, 2)
        expected_fixture_roots = (
            "5891de6bfad27654fa993b8a31c71749"
            "ab5346bd3701b2cbcf62ef8ef43cd8eb",
            "e3bf4bc1015c30431150acb9d70b4183"
            "19ba7109caf98952942e2ada6f5b6daf",
            "7c16ff3eb368dab477fafef9414cf3d6"
            "310dec334c6d8d3051bf04e5e2de0282",
        )
        expected_plan_roots = (
            "6930f3135b2821f2a47eceb6f83db94"
            "b5853418c3a9177fe334648a87138d9ea",
            "25b0032855459ec3d7b80bbedeb5f561"
            "28cf583c78d748354b8f2544e8ed547b",
            "4f951425133820d2b0119de9b889126a"
            "45dca1909c34c4139c4e8d0121a2e680",
        )
        expected_receipt_roots = (
            "b4445f2763effc0310621a3d9209ee71"
            "368e008bf6b0e717e7e81d515f00235e",
            "d1e4072db08208f64a91db6113a35fce"
            "c636884a0f14c16ffa8988a4ba4c8bf0",
            "bb21e899d7aa97ea92ce2297af98fbad"
            "b8b5f0b0343883eb01277c90de931911",
        )
        specs = (
            fixture.image_spec(),
            fixture.audio_spec(),
            fixture.video_spec(),
        )
        for (
            spec,
            units,
            fixture_root,
            plan_root,
            receipt_root,
        ) in zip(
            specs,
            expected_units,
            expected_fixture_roots,
            expected_plan_roots,
            expected_receipt_roots,
        ):
            encoded_fixture, encoded_plan, parsed = encoded_pair(spec)
            self.assertEqual(
                parsed["fixture_sha256"].hex(), fixture_root
            )
            self.assertEqual(
                fixture.plan_sha256(encoded_plan).hex(), plan_root
            )
            self.assertEqual(
                fixture.decode_plan(encoded_plan),
                fixture.make_decode_plan(
                    parsed,
                    digest(0xD1),
                    digest(0xE1),
                ),
            )
            output = bytearray(len(spec["payload"]))
            receipt = fixture.decode_fixture(
                encoded_fixture,
                encoded_plan,
                output,
            )
            self.assertEqual(bytes(output), spec["payload"])
            self.assertEqual(receipt["logical_units"], units)
            self.assertEqual(
                receipt["receipt_sha256"].hex(), receipt_root
            )
            self.assertEqual(
                fixture.verify_complete_mapping(encoded_fixture),
                units,
            )

    def test_every_fixture_and_plan_byte_mutation_rejects(self) -> None:
        for spec in (
            fixture.image_spec(),
            fixture.audio_spec(),
            fixture.video_spec(),
        ):
            encoded_fixture, encoded_plan, _ = encoded_pair(spec)
            for label, encoded, decoder in (
                (
                    "fixture",
                    encoded_fixture,
                    fixture.parse_fixture,
                ),
                ("plan", encoded_plan, fixture.decode_plan),
            ):
                for index in range(len(encoded)):
                    with self.subTest(
                        kind=spec["kind"],
                        wire=label,
                        index=index,
                    ):
                        mutated = bytearray(encoded)
                        mutated[index] ^= 1
                        with self.assertRaises(
                            fixture.MediaDecodeFixtureError
                        ):
                            decoder(bytes(mutated))

    def test_rehashed_contradictions_and_substitution_reject(self) -> None:
        image_fixture, image_plan, _ = encoded_pair(
            fixture.image_spec()
        )
        audio_fixture, _, _ = encoded_pair(fixture.audio_spec())

        contradictory_fixture = bytearray(image_fixture)
        struct.pack_into("<Q", contradictory_fixture, 128, 7)
        contradictory_fixture[-32:] = hashlib.sha256(
            fixture.FIXTURE_DOMAIN + contradictory_fixture[:-32]
        ).digest()
        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.parse_fixture(bytes(contradictory_fixture))

        contradictory_geometry = bytearray(image_fixture)
        struct.pack_into("<Q", contradictory_geometry, 288, 3)
        contradictory_geometry[-32:] = hashlib.sha256(
            fixture.FIXTURE_DOMAIN + contradictory_geometry[:-32]
        ).digest()
        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.parse_fixture(bytes(contradictory_geometry))

        contradictory_plan = bytearray(image_plan)
        struct.pack_into("<Q", contradictory_plan, 24, 1)
        contradictory_plan[-32:] = hashlib.sha256(
            fixture.PLAN_DOMAIN + contradictory_plan[:-32]
        ).digest()
        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.decode_plan(bytes(contradictory_plan))

        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.decode_fixture(
                audio_fixture,
                image_plan,
                bytearray(len(fixture.AUDIO_PAYLOAD)),
            )

    def test_mapping_and_capacity_fail_closed(self) -> None:
        image_fixture, image_plan, _ = encoded_pair(
            fixture.image_spec()
        )
        mappings = [
            fixture.map_unit(image_fixture, index)
            for index in range(4)
        ]
        self.assertEqual(
            [mapping["source_offset"] for mapping in mappings],
            [320, 323, 326, 329],
        )
        self.assertEqual(
            [mapping["output_offset"] for mapping in mappings],
            [0, 3, 6, 9],
        )
        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.map_unit(image_fixture, 4)

        destination = bytearray(b"\x5a" * 11)
        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.decode_fixture(
                image_fixture,
                image_plan,
                destination,
            )
        self.assertEqual(destination, bytearray(b"\x5a" * 11))
        with self.assertRaises(fixture.MediaDecodeFixtureError):
            fixture.parse_fixture(image_fixture[:-1])


if __name__ == "__main__":
    unittest.main()
