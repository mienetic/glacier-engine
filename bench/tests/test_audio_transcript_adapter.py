from __future__ import annotations

import hashlib
import struct
import unittest

from bench import audio_transcript_adapter as transcript
from bench import media_contract as media
from bench import media_processor_cache as cache
from bench import media_processor_state as processor
from bench import model_contract as model


class AudioTranscriptAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        image_cache = bytes((1, 2))
        audio_cache = struct.pack(
            "<6h",
            100,
            200,
            -300,
            400,
            -10,
            10,
        )
        video_cache = bytes((3,))
        request_epoch = 221
        generation = 4
        challenge = model.sha256(b"audio transcript challenge")

        def state_plan(
            *,
            kind: int,
            stream_key: int,
            timeline: tuple[int, int],
            media_name: bytes,
            processor_name: bytes,
            previous_name: bytes,
            payload: bytes,
            output_name: bytes,
            ownership_name: bytes,
            decoder_name: bytes,
        ) -> dict[str, object]:
            return {
                "kind": kind,
                "request_epoch": request_epoch,
                "generation": generation,
                "stream_key": stream_key,
                "timeline_numerator": timeline[0],
                "timeline_denominator": timeline[1],
                "media_object_sha256": model.sha256(media_name),
                "processor_plan_sha256": model.sha256(processor_name),
                "previous_state_sha256": model.sha256(previous_name),
                "challenge_sha256": challenge,
                "cache_content_sha256": hashlib.sha256(payload).digest(),
                "output_chain_sha256": model.sha256(output_name),
                "ownership_receipt_sha256": model.sha256(
                    ownership_name
                ),
                "decoder_state_sha256": model.sha256(decoder_name),
            }

        states = [
            processor.make_image_state(
                state_plan(
                    kind=media.IMAGE,
                    stream_key=41_001,
                    timeline=(0, 1),
                    media_name=b"image media",
                    processor_name=b"image processor",
                    previous_name=b"previous image state",
                    payload=image_cache,
                    output_name=b"image output",
                    ownership_name=b"image ownership",
                    decoder_name=b"image decoder",
                ),
                1,
                2,
                1,
                1,
                1,
                1,
                1,
            ),
            processor.make_audio_state(
                state_plan(
                    kind=media.AUDIO,
                    stream_key=41_002,
                    timeline=(1, 16_000),
                    media_name=b"transcript audio media",
                    processor_name=b"overlap feature processor",
                    previous_name=b"previous overlap state",
                    payload=audio_cache,
                    output_name=b"previous audio output chain",
                    ownership_name=b"overlap audio ownership",
                    decoder_name=b"overlap audio decoder",
                ),
                2,
                16_000,
                1,
                4,
                2,
                2,
                2,
            ),
            processor.make_video_state(
                state_plan(
                    kind=media.VIDEO,
                    stream_key=41_003,
                    timeline=(1, 48_000),
                    media_name=b"video media",
                    processor_name=b"video processor",
                    previous_name=b"previous video state",
                    payload=video_cache,
                    output_name=b"video output",
                    ownership_name=b"video ownership",
                    decoder_name=b"video decoder",
                ),
                1,
                1,
                0,
                1,
                0,
            ),
        ]
        sync = processor.make_sync_state(
            states,
            {
                "generation": generation,
                "request_epoch": request_epoch,
                "master_ticks_per_second": 48_000,
                "maximum_skew_ticks": 24,
                "challenge_sha256": challenge,
                "sync_policy_sha256": model.sha256(
                    b"transcript sync policy"
                ),
                "previous_sync_sha256": model.sha256(
                    b"previous transcript sync"
                ),
            },
        )
        processor_bundle = processor.decode_bundle(
            processor.encode_bundle(states, sync)
        )
        cache_bundle = cache.decode_bundle(
            cache.encode_bundle(
                processor_bundle,
                {
                    "processor_bundle_sha256": processor_bundle[
                        "bundle_sha256"
                    ],
                    "previous_cache_bundle_sha256": model.sha256(
                        b"previous transcript cache bundle"
                    ),
                    "source_bank_epoch": 210,
                    "restore_bank_epoch": 211,
                    "restore_owner_key_base": 42_000,
                    "restore_tree_key_base": 43_000,
                    "restore_authority_key_base": 44_000,
                    "tenant_key": 45_000,
                    "publication_next_sequence": 2,
                },
                [image_cache, audio_cache, video_cache],
            )
        )
        previous_overlap = transcript.make_overlap(
            audio_state=processor_bundle["states"][1],
            processor_bundle_sha256=processor_bundle["bundle_sha256"],
            cache_bundle_sha256=cache_bundle["bundle_sha256"],
            segment_index=1,
            source_start_sample=0,
            previous_transcript_sha256=model.sha256(
                b"transcript genesis"
            ),
        )
        self.previous = transcript.make_transcript(
            previous_overlap,
            b"snow",
        )
        self.overlap = transcript.make_overlap(
            audio_state=processor_bundle["states"][1],
            processor_bundle_sha256=processor_bundle["bundle_sha256"],
            cache_bundle_sha256=cache_bundle["bundle_sha256"],
            segment_index=2,
            source_start_sample=4,
            previous_transcript_sha256=self.previous[
                "transcript_sha256"
            ],
        )
        self.segment = transcript.make_transcript(
            self.overlap,
            b"ice",
        )
        transcript.validate_predecessor(
            self.overlap,
            self.previous,
        )

    def test_overlap_and_transcript_wires_are_mutation_complete(self) -> None:
        overlap_wire = transcript.encode_overlap(self.overlap)
        segment_wire = transcript.encode_transcript(self.segment)
        self.assertEqual(
            transcript.decode_overlap(overlap_wire),
            self.overlap,
        )
        self.assertEqual(
            transcript.decode_transcript(segment_wire),
            self.segment,
        )
        self.assertEqual(
            self.overlap["overlap_sha256"].hex(),
            "4747e104ce7b0a7b09f270ca72ad04bb"
            "cde759c67f858df710eefe75c1242635",
        )
        self.assertEqual(
            self.segment["transcript_sha256"].hex(),
            "062bd3166b979591f4ba9771606b6284"
            "b00ce7edc93378674cdeb1747597c625",
        )
        for index in range(len(overlap_wire)):
            mutated = bytearray(overlap_wire)
            mutated[index] ^= 1
            with self.assertRaises(
                transcript.AudioTranscriptAdapterError
            ):
                transcript.decode_overlap(bytes(mutated))
        for index in range(len(segment_wire)):
            mutated = bytearray(segment_wire)
            mutated[index] ^= 1
            with self.assertRaises(
                transcript.AudioTranscriptAdapterError
            ):
                transcript.decode_transcript(bytes(mutated))

    def test_context_is_not_in_the_publishable_range(self) -> None:
        self.assertEqual(
            (
                self.overlap["source_start_sample"],
                self.overlap["context_start_sample"],
                self.overlap["context_end_sample"],
                self.overlap["publish_start_sample"],
                self.overlap["publish_end_sample"],
                self.overlap["source_end_sample"],
            ),
            (4, 4, 6, 6, 10, 10),
        )
        self.assertEqual(self.segment["text"][:3], b"ice")
        foreign = dict(self.overlap)
        foreign["previous_transcript_sha256"] = model.sha256(
            b"foreign transcript predecessor"
        )
        foreign["overlap_sha256"] = transcript.overlap_root(foreign)
        foreign_segment = transcript.make_transcript(foreign, b"ice")
        with self.assertRaises(transcript.AudioTranscriptAdapterError):
            transcript.validate_transcript_for_overlap(
                foreign_segment,
                self.overlap,
            )
        foreign_previous = transcript.make_transcript(
            transcript.make_overlap(
                audio_state={
                    "request_epoch": self.overlap["request_epoch"],
                    "generation": self.overlap["generation"],
                    "cursor_units": 6,
                    "produced_units": 2,
                    "parameters": [16_000, 1, 4, 2, 2, 2, 2, 0],
                    "media_object_sha256": self.overlap[
                        "media_object_sha256"
                    ],
                    "state_sha256": self.overlap[
                        "processor_state_sha256"
                    ],
                    "cache_content_sha256": self.overlap[
                        "cache_payload_sha256"
                    ],
                    "ownership_receipt_sha256": self.overlap[
                        "ownership_sha256"
                    ],
                    "challenge_sha256": self.overlap[
                        "challenge_sha256"
                    ],
                },
                processor_bundle_sha256=self.overlap[
                    "processor_bundle_sha256"
                ],
                cache_bundle_sha256=self.overlap[
                    "cache_bundle_sha256"
                ],
                segment_index=1,
                source_start_sample=0,
                previous_transcript_sha256=model.sha256(
                    b"transcript genesis"
                ),
            ),
            b"rain",
        )
        with self.assertRaises(transcript.AudioTranscriptAdapterError):
            transcript.validate_predecessor(
                self.overlap,
                foreign_previous,
            )


if __name__ == "__main__":
    unittest.main()
