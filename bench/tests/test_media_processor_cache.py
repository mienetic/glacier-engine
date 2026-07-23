from __future__ import annotations

import hashlib
import unittest

from bench import media_contract as media
from bench import media_processor_cache as cache
from bench import media_processor_state as processor


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def processor_bundle(
    generation: int,
    payloads: list[bytes],
    previous: dict[str, object] | None = None,
) -> dict[str, object]:
    kinds = (media.IMAGE, media.AUDIO, media.VIDEO)
    timelines = ((0, 1), (1, 48_000), (1, 120))
    plans: list[dict[str, object]] = []
    for index, (kind, timeline, payload) in enumerate(
        zip(kinds, timelines, payloads)
    ):
        plans.append(
            {
                "kind": kind,
                "request_epoch": 25_000,
                "generation": generation,
                "stream_key": 25_100 + index,
                "timeline_numerator": timeline[0],
                "timeline_denominator": timeline[1],
                "media_object_sha256": digest(0x10 + index),
                "processor_plan_sha256": digest(0x20 + index),
                "previous_state_sha256": (
                    previous["states"][index]["state_sha256"]
                    if previous is not None
                    else processor.ZERO_DIGEST
                ),
                "challenge_sha256": digest(0x72),
                "cache_content_sha256": hashlib.sha256(
                    payload
                ).digest(),
                "output_chain_sha256": digest(
                    0x40 + index + generation
                ),
                "ownership_receipt_sha256": digest(
                    0x50 + index + generation
                ),
                "decoder_state_sha256": digest(0x60 + index),
            }
        )
    window_start = max(0, generation - 2)
    states = [
        processor.make_image_state(
            plans[0],
            generation,
            4,
            4,
            4,
            2,
            2,
            3,
        ),
        processor.make_audio_state(
            plans[1],
            generation,
            48_000,
            1,
            400,
            160,
            80,
            2,
        ),
        processor.make_video_state(
            plans[2],
            2,
            128,
            window_start,
            generation,
            window_start,
        ),
    ]
    sync = processor.make_sync_state(
        states,
        {
            "generation": generation,
            "request_epoch": 25_000,
            "master_ticks_per_second": 48_000,
            "maximum_skew_ticks": 800,
            "challenge_sha256": digest(0x72),
            "sync_policy_sha256": digest(0x70),
            "previous_sync_sha256": (
                previous["sync"]["sync_sha256"]
                if previous is not None
                else processor.ZERO_DIGEST
            ),
        },
    )
    return processor.decode_bundle(
        processor.encode_bundle(states, sync)
    )


def cache_generation(
    generation: int,
    payloads: list[bytes],
    processor_value: dict[str, object],
    previous: dict[str, object] | None = None,
) -> bytes:
    source_bank_epoch = 30_000 + (generation - 1) * 1_000
    restore_bank_epoch = 30_000 + generation * 1_000
    return cache.encode_bundle(
        processor_value,
        {
            "processor_bundle_sha256": processor_value[
                "bundle_sha256"
            ],
            "previous_cache_bundle_sha256": (
                previous["bundle_sha256"]
                if previous is not None
                else cache.ZERO_DIGEST
            ),
            "source_bank_epoch": source_bank_epoch,
            "restore_bank_epoch": restore_bank_epoch,
            "restore_owner_key_base": restore_bank_epoch + 100,
            "restore_tree_key_base": restore_bank_epoch + 200,
            "restore_authority_key_base": restore_bank_epoch + 300,
            "tenant_key": 31_400,
            "publication_next_sequence": generation + 1,
        },
        payloads,
    )


class MediaProcessorCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.first_payloads = [
            bytes((0x11,)) * 24,
            bytes((0x22,)) * 640,
            bytes((0x33,)) * 128,
        ]
        self.first_processor = processor_bundle(
            1,
            self.first_payloads,
        )
        self.first_wire = cache_generation(
            1,
            self.first_payloads,
            self.first_processor,
        )
        self.first = cache.decode_bundle(self.first_wire)
        self.second_payloads = [
            bytes((0x14,)) * 48,
            bytes((0x25,)) * 800,
            bytes((0x36,)) * 256,
        ]
        self.second_processor = processor_bundle(
            2,
            self.second_payloads,
            self.first_processor,
        )
        self.second_wire = cache_generation(
            2,
            self.second_payloads,
            self.second_processor,
            self.first,
        )
        self.second = cache.decode_bundle(self.second_wire)

    def test_shared_golden_binding_and_successor(self) -> None:
        cache.validate_binding(
            self.first,
            self.first_processor,
            self.first_processor["bundle_sha256"],
        )
        cache.validate_binding(
            self.second,
            self.second_processor,
            self.second_processor["bundle_sha256"],
        )
        cache.validate_successor(self.first, self.second)
        self.assertEqual(self.first["total_cache_bytes"], 792)
        self.assertEqual(self.second["total_cache_bytes"], 1104)
        self.assertEqual(
            self.first["bundle_sha256"].hex(),
            "b11ac37dd0125a6086a44dce9c0e394f"
            "cfa5435715cc21b4ed5182cb74e7528c",
        )

    def test_every_cache_bundle_byte_mutation_rejects(self) -> None:
        for index in range(len(self.second_wire)):
            with self.subTest(index=index):
                corrupted = bytearray(self.second_wire)
                corrupted[index] ^= 1
                with self.assertRaises(
                    cache.MediaProcessorCacheError
                ):
                    cache.decode_bundle(bytes(corrupted))

    def test_processor_and_payload_substitution_reject(self) -> None:
        foreign_payloads = list(self.first_payloads)
        foreign_payloads[0] = bytes((0xEE,)) * 24
        foreign_processor = processor_bundle(1, foreign_payloads)
        with self.assertRaises(cache.MediaProcessorCacheError):
            cache.validate_binding(
                self.first,
                foreign_processor,
                foreign_processor["bundle_sha256"],
            )
        substituted = list(self.first_payloads)
        substituted[2] = bytes((0xEF,)) * 128
        with self.assertRaises(cache.MediaProcessorCacheError):
            cache.encode_bundle(
                self.first_processor,
                {
                    "processor_bundle_sha256": self.first_processor[
                        "bundle_sha256"
                    ],
                    "previous_cache_bundle_sha256": cache.ZERO_DIGEST,
                    "source_bank_epoch": 30_000,
                    "restore_bank_epoch": 30_001,
                    "restore_owner_key_base": 31_100,
                    "restore_tree_key_base": 31_200,
                    "restore_authority_key_base": 31_300,
                    "tenant_key": 31_400,
                    "publication_next_sequence": 2,
                },
                substituted,
            )

    def test_stale_cache_lineage_rejects(self) -> None:
        forged = dict(self.second)
        forged["previous_cache_bundle_sha256"] = digest(0xEE)
        body = bytearray(cache.encode_decoded_bundle(forged))
        body[-cache.CACHE_BUNDLE_FOOTER_BYTES :] = cache.bundle_root(
            bytes(body[:-cache.CACHE_BUNDLE_FOOTER_BYTES])
        )
        rerooted = cache.decode_bundle(bytes(body))
        with self.assertRaises(cache.MediaProcessorCacheError):
            cache.validate_successor(self.first, rerooted)


if __name__ == "__main__":
    unittest.main()
