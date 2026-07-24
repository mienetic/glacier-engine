from __future__ import annotations

import unittest

from bench import generated_media_checkpoint as media


class GeneratedMediaCheckpointTests(unittest.TestCase):
    def test_reference_chain_and_every_wire_byte_are_canonical(self) -> None:
        fixture = media.reference_fixture()
        expected = {
            "image1": (
                "member_sha256",
                "8eb5fb1951d0e0fb358ba418456327c6752c23ec8342363f22ff945f2e00227e",
            ),
            "audio1": (
                "member_sha256",
                "122e084af15cf69167f3f2e88f94719bec62c96bc1f759a4b5e113a3d887c167",
            ),
            "video1": (
                "member_sha256",
                "ac25f1f95f9466e49252e5d10769cf862fbb40e58aef8cc0e29891a8d1811d94",
            ),
            "checkpoint1": (
                "checkpoint_sha256",
                "543c160372a565b2663cddc3ac6b15c385d3d56723e9cdf40cb253c696eebddd",
            ),
            "selector1": (
                "selector_sha256",
                "423ac653e10b4ef4e4b5eb21707700f08b3e2836acc4ee8a4dcd1ee76b0de60d",
            ),
            "checkpoint2": (
                "checkpoint_sha256",
                "372bd7c26248520a7293715caa6e7872897454d350041d2d0a1bb0c475330d59",
            ),
            "selector2": (
                "selector_sha256",
                "2222c55c70e63a50e1bb23c2542f0c39a0f5179ee68c6fe3be69134671692d7e",
            ),
        }
        for key, (field, root) in expected.items():
            self.assertEqual(fixture[key][field].hex(), root)
        wires = (
            (fixture["image1"], media.encode_member, media.decode_member),
            (fixture["audio1"], media.encode_member, media.decode_member),
            (fixture["video1"], media.encode_member, media.decode_member),
            (
                fixture["checkpoint1"],
                media.encode_checkpoint,
                media.decode_checkpoint,
            ),
            (
                fixture["selector1"],
                media.encode_selector,
                media.decode_selector,
            ),
            (
                fixture["checkpoint2"],
                media.encode_checkpoint,
                media.decode_checkpoint,
            ),
            (
                fixture["selector2"],
                media.encode_selector,
                media.decode_selector,
            ),
        )
        for value, encode, decode in wires:
            raw = encode(value)
            self.assertEqual(decode(raw), value)
            for index in range(len(raw)):
                mutated = bytearray(raw)
                mutated[index] ^= 1
                with self.assertRaises(
                    media.GeneratedMediaCheckpointError
                ):
                    decode(bytes(mutated))

    def test_mixed_scope_generation_and_replay_fail_closed(self) -> None:
        fixture = media.reference_fixture()
        with self.assertRaises(media.GeneratedMediaCheckpointError):
            media.make_checkpoint(
                fixture["checkpoint1"],
                fixture["image2"],
                fixture["audio1"],
                fixture["video2"],
            )
        foreign = {
            **fixture["video2"],
            "tenant_scope_sha256": media._reference_digest(99, 0, 0),
            "member_sha256": media.ZERO,
        }
        foreign["member_sha256"] = media._root(
            media.MEMBER_DOMAIN,
            media._member_body(foreign),
        )
        media.validate_member(foreign)
        with self.assertRaises(media.GeneratedMediaCheckpointError):
            media.make_checkpoint(
                fixture["checkpoint1"],
                fixture["image2"],
                fixture["audio2"],
                foreign,
            )

    def test_rehashed_semantic_contradictions_fail(self) -> None:
        fixture = media.reference_fixture()
        malformed = {
            **fixture["audio1"],
            "source_generation": fixture["audio1"]["source_generation"] + 2,
            "member_sha256": media.ZERO,
        }
        malformed["member_sha256"] = media._root(
            media.MEMBER_DOMAIN,
            media._member_body(malformed),
        )
        with self.assertRaises(media.GeneratedMediaCheckpointError):
            media.validate_member(malformed)

        selector = {
            **fixture["selector2"],
            "previous_selector_sha256": media._reference_digest(77, 0, 0),
            "selector_sha256": media.ZERO,
        }
        selector["selector_sha256"] = media._root(
            media.SELECTOR_DOMAIN,
            media._selector_body(selector),
        )
        media.validate_selector(selector)
        self.assertNotEqual(selector, fixture["selector2"])
        with self.assertRaises(media.GeneratedMediaCheckpointError):
            media.make_selector(selector, fixture["checkpoint2"])

    def test_checkpoint_exposes_one_complete_generation(self) -> None:
        fixture = media.reference_fixture()
        first = fixture["checkpoint1"]
        second = fixture["checkpoint2"]
        self.assertEqual(first["member_count"], 3)
        self.assertEqual(first["total_bytes"], 16)
        self.assertEqual(first["total_units"], 5)
        self.assertEqual(second["generation"], 2)
        self.assertEqual(second["image_unit_end"], 2)
        self.assertEqual(second["audio_unit_end"], 4)
        self.assertEqual(second["video_unit_end"], 4)
        self.assertEqual(second["video_timeline_end"], 10)
        self.assertEqual(
            second["previous_checkpoint_sha256"],
            first["checkpoint_sha256"],
        )


if __name__ == "__main__":
    unittest.main()
