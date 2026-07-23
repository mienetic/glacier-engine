from __future__ import annotations

import hashlib
import struct
import unittest

from bench import media_contract as media


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def audio_object() -> dict[str, object]:
    return {
        "kind": media.AUDIO,
        "semantic_abi": 2,
        "byte_length": 192_000,
        "container_id": 2,
        "codec_id": 2,
        "axes": (48_000, 2, 48_000),
        "time_base": (1, 48_000),
        "tenant_scope_sha256": digest(0x51),
        "content_sha256": digest(0x52),
        "metadata_policy_sha256": digest(0x53),
        "provenance_sha256": digest(0x54),
    }


def first_event() -> dict[str, object]:
    return {
        "kind": media.RESAMPLE,
        "sequence": 7,
        "media_object_sha256": digest(0x71),
        "source": ((0, (1, 48_000)), (48_000, (1, 48_000))),
        "target": ((0, (1, 16_000)), (16_000, (1, 16_000))),
        "plan_sha256": digest(0x73),
        "previous_event_sha256": media.ZERO_DIGEST,
    }


class MediaContractTests(unittest.TestCase):
    def test_three_kinds_and_mutation_complete_golden(self) -> None:
        fixtures = [
            {
                **audio_object(),
                "kind": media.IMAGE,
                "semantic_abi": 1,
                "byte_length": 12,
                "container_id": 1,
                "codec_id": 1,
                "axes": (2, 2, 3),
                "time_base": (0, 1),
                "tenant_scope_sha256": digest(0x41),
                "content_sha256": digest(0x42),
                "metadata_policy_sha256": digest(0x43),
                "provenance_sha256": digest(0x44),
            },
            audio_object(),
            {
                **audio_object(),
                "kind": media.VIDEO,
                "semantic_abi": 3,
                "byte_length": 4096,
                "container_id": 3,
                "codec_id": 3,
                "axes": (16, 16, 30),
                "time_base": (1, 30),
                "tenant_scope_sha256": digest(0x61),
                "content_sha256": digest(0x62),
                "metadata_policy_sha256": digest(0x63),
                "provenance_sha256": digest(0x64),
            },
        ]
        for fixture in fixtures:
            self.assertEqual(
                media.decode_media_object(
                    media.encode_media_object(fixture)
                ),
                fixture,
            )
        encoded = media.encode_media_object(audio_object())
        self.assertEqual(
            media.media_object_sha256(encoded).hex(),
            "255d59c3ad202eececf7c206583ad3ef62cda5f3710966aa0f7cf3c4079285f5",
        )
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(media.MediaContractError):
                    media.decode_media_object(bytes(mutated))

    def test_rehashed_semantic_contradictions_reject(self) -> None:
        encoded = bytearray(media.encode_media_object(audio_object()))
        struct.pack_into("<Q", encoded, 24, 1)
        encoded[240:] = hashlib.sha256(
            media.DESCRIPTOR_DOMAIN + encoded[:240]
        ).digest()
        with self.assertRaises(media.MediaContractError):
            media.decode_media_object(bytes(encoded))

        invalid = audio_object()
        invalid["time_base"] = (1, 44_100)
        with self.assertRaises(media.MediaContractError):
            media.encode_media_object(invalid)

    def test_rational_mapping_is_exact_or_rejects(self) -> None:
        mapped = media.map_span_exact(
            (
                (48_000, (1, 48_000)),
                (96_000, (1, 48_000)),
            ),
            (1, 16_000),
        )
        self.assertEqual(
            mapped,
            (
                (16_000, (1, 16_000)),
                (32_000, (1, 16_000)),
            ),
        )
        with self.assertRaises(media.MediaContractError):
            media.convert_exact((1, (1, 48_000)), (1, 44_100))

    def test_publication_appends_once_and_rejects_stale_replay(self) -> None:
        state = media.initialize_publication_state(
            91,
            7,
            (1, 16_000),
            digest(0x71),
            digest(0x72),
        )
        prepared = media.prepare_publication(
            state,
            first_event(),
            digest(0x74),
            digest(0x75),
        )
        self.assertEqual(
            prepared["commit_sha256"].hex(),
            "d26ae55bd2f88036e829c725d91c448bf5efafad20710f7bc84334e611157fb6",
        )
        committed = media.commit_publication(state, prepared)
        self.assertEqual(committed["next_sequence"], 8)
        self.assertEqual(committed["visible_chunks"], 1)
        self.assertEqual(committed["visible_units"], 16_000)
        with self.assertRaises(media.MediaContractError):
            media.commit_publication(committed, prepared)
        self.assertEqual(state["next_sequence"], 7)

        exhausted = {
            **state,
            "next_sequence": media.U64_MAX,
        }
        forged = {
            **prepared,
            "sequence": media.U64_MAX,
            "state_before_sha256": media.publication_state_root(
                exhausted
            ),
        }
        forged["commit_sha256"] = media.publication_root(forged)
        with self.assertRaises(media.MediaContractError):
            media.commit_publication(exhausted, forged)


if __name__ == "__main__":
    unittest.main()
