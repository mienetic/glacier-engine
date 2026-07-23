from __future__ import annotations

import unittest

from bench import audio_transcript_adapter as audio
from bench import audio_video_result_link as link
from bench import model_contract as model
from bench import video_segment_adapter as video_segment
from bench import video_segment_timeline as video_timeline


class AudioVideoResultLinkTests(unittest.TestCase):
    @staticmethod
    def make_fixture(
        *,
        audio_start: int,
        audio_end: int,
        sample_rate: int,
        video_start: int,
        video_end: int,
    ) -> tuple[link.Record, link.Record, link.Record, link.Record]:
        challenge = model.sha256(b"audio video link challenge")
        context_units = 2
        source_start = max(0, audio_start - context_units)
        source_units = audio_end - source_start
        overlap: link.Record = {
            "request_epoch": 221,
            "generation": 7,
            "segment_index": 1,
            "source_start_sample": source_start,
            "source_end_sample": audio_end,
            "context_start_sample": source_start,
            "context_end_sample": audio_start,
            "publish_start_sample": audio_start,
            "publish_end_sample": audio_end,
            "sample_rate": sample_rate,
            "window_samples": source_units,
            "hop_samples": source_units - context_units,
            "feature_frames": 1,
            "feature_bins": 8,
            "feature_bytes": 16,
            "media_object_sha256": model.sha256(b"link audio media"),
            "processor_state_sha256": model.sha256(
                b"link audio processor"
            ),
            "processor_bundle_sha256": model.sha256(
                b"link audio processor bundle"
            ),
            "cache_bundle_sha256": model.sha256(
                b"link audio cache bundle"
            ),
            "cache_payload_sha256": model.sha256(
                b"link audio cache payload"
            ),
            "ownership_sha256": model.sha256(
                b"link audio ownership"
            ),
            "challenge_sha256": challenge,
            "previous_transcript_sha256": model.sha256(
                b"link previous transcript"
            ),
        }
        overlap["overlap_sha256"] = audio.overlap_root(overlap)
        overlap = audio.validate_overlap(overlap)
        transcript = audio.make_transcript(overlap, b"ice")
        segment: link.Record = {
            "request_epoch": 221,
            "generation": 7,
            "segment_index": 1,
            "first_frame": video_start,
            "last_frame": video_end - 1,
            "frame_count": video_end - video_start,
            "frame_stride": 1,
            "keyframe_ordinal": 0,
            "eviction_boundary": 0,
            "cache_generation": 7,
            "target_numerator": 1,
            "target_denominator": 1_000,
            "target_start_tick": video_start,
            "target_end_tick": video_end,
            "event_id": 9,
            "confidence_ppm": 800_000,
            "media_object_sha256": model.sha256(b"link video media"),
            "processor_state_sha256": model.sha256(
                b"link video processor"
            ),
            "processor_bundle_sha256": model.sha256(
                b"link video processor bundle"
            ),
            "cache_bundle_sha256": model.sha256(
                b"link video cache bundle"
            ),
            "cache_payload_sha256": model.sha256(
                b"link video cache payload"
            ),
            "ownership_sha256": model.sha256(
                b"link video ownership"
            ),
            "selection_sha256": model.sha256(
                b"link video selection"
            ),
            "challenge_sha256": challenge,
            "previous_segment_sha256": model.sha256(
                b"link previous video segment"
            ),
        }
        segment["segment_sha256"] = video_segment.segment_root(segment)
        segment = video_segment.validate_segment(segment)
        timeline = video_timeline.initialize_timeline(
            segment,
            model.sha256(b"link decision genesis"),
        )
        state = link.initialize_state(
            221,
            overlap["media_object_sha256"],
            segment["media_object_sha256"],
            challenge,
            model.sha256(b"audio video link genesis"),
        )
        return state, overlap, transcript, timeline

    def test_wires_roots_and_every_mutation(self) -> None:
        state, overlap, transcript, timeline = self.make_fixture(
            audio_start=2,
            audio_end=10,
            sample_rate=1_000,
            video_start=0,
            video_end=10,
        )
        result = link.make_link(state, overlap, transcript, timeline)
        self.assertEqual(result["relation"], link.AUDIO_WITHIN_VIDEO)
        self.assertEqual(
            (result["audio_start_tick"], result["audio_end_tick"]),
            (2, 10),
        )
        self.assertEqual(
            state["state_sha256"].hex(),
            "2052d23dc2c56b207f9fa159f85c177c291e0f08f2b5414e7620ab48915ed98f",
        )
        self.assertEqual(
            result["link_sha256"].hex(),
            "e8790644683c583f170436fea1e30ff2ba257f879d1d48b4950d18c2f6f63cf9",
        )
        non_canonical_time = dict(result)
        non_canonical_time["target_numerator"] = 2
        non_canonical_time["target_denominator"] = 2_000
        non_canonical_time["link_sha256"] = link.link_root(
            non_canonical_time
        )
        with self.assertRaises(link.AudioVideoResultLinkError):
            link.validate_link(non_canonical_time)
        impossible_visible_count = dict(result)
        impossible_visible_count["timeline_visible_segments"] = 2
        impossible_visible_count["link_sha256"] = link.link_root(
            impossible_visible_count
        )
        with self.assertRaises(link.AudioVideoResultLinkError):
            link.validate_link(impossible_visible_count)
        state_wire = link.encode_state(state)
        result_wire = link.encode_link(result)
        self.assertEqual(link.decode_state(state_wire), state)
        self.assertEqual(link.decode_link(result_wire), result)
        for wire, decoder in (
            (state_wire, link.decode_state),
            (result_wire, link.decode_link),
        ):
            for index in range(len(wire)):
                mutated = bytearray(wire)
                mutated[index] ^= 1
                with self.assertRaises(link.AudioVideoResultLinkError):
                    decoder(bytes(mutated))

    def test_relations_disjoint_and_non_integral_reject(self) -> None:
        cases = (
            ((2, 10, 2, 10), link.EXACT),
            ((2, 10, 0, 10), link.AUDIO_WITHIN_VIDEO),
            ((2, 12, 4, 10), link.VIDEO_WITHIN_AUDIO),
            ((2, 10, 8, 14), link.PARTIAL_OVERLAP),
        )
        for (audio_start, audio_end, video_start, video_end), relation in cases:
            state, overlap, transcript, timeline = self.make_fixture(
                audio_start=audio_start,
                audio_end=audio_end,
                sample_rate=1_000,
                video_start=video_start,
                video_end=video_end,
            )
            self.assertEqual(
                link.make_link(
                    state,
                    overlap,
                    transcript,
                    timeline,
                )["relation"],
                relation,
            )
        state, overlap, transcript, timeline = self.make_fixture(
            audio_start=20,
            audio_end=30,
            sample_rate=1_000,
            video_start=0,
            video_end=10,
        )
        with self.assertRaises(link.AudioVideoResultLinkError):
            link.make_link(state, overlap, transcript, timeline)
        state, overlap, transcript, timeline = self.make_fixture(
            audio_start=2,
            audio_end=10,
            sample_rate=16_000,
            video_start=0,
            video_end=10,
        )
        with self.assertRaises(link.AudioVideoResultLinkError):
            link.make_link(state, overlap, transcript, timeline)

    def test_context_is_excluded_and_lineage_is_closed(self) -> None:
        state, overlap, transcript, timeline = self.make_fixture(
            audio_start=2,
            audio_end=10,
            sample_rate=1_000,
            video_start=0,
            video_end=10,
        )
        result = link.make_link(state, overlap, transcript, timeline)
        self.assertEqual(result["audio_source_start_sample"], 2)
        self.assertNotEqual(
            result["audio_source_start_sample"],
            transcript["context_start_sample"],
        )
        next_state = link.apply_link(
            state,
            overlap,
            transcript,
            timeline,
            result,
        )
        self.assertEqual(next_state["visible_links"], 1)
        self.assertEqual(
            next_state["previous_link_sha256"],
            result["link_sha256"],
        )
        foreign_timeline = dict(timeline)
        foreign_timeline["challenge_sha256"] = model.sha256(
            b"foreign challenge"
        )
        foreign_timeline["timeline_sha256"] = video_timeline.timeline_root(
            foreign_timeline
        )
        with self.assertRaises(link.AudioVideoResultLinkError):
            link.make_link(
                state,
                overlap,
                transcript,
                foreign_timeline,
            )


if __name__ == "__main__":
    unittest.main()
