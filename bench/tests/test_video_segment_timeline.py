from __future__ import annotations

import unittest

from bench import model_contract as model
from bench import video_segment_adapter as segment
from bench import video_segment_timeline as timeline


class VideoSegmentTimelineTests(unittest.TestCase):
    @staticmethod
    def make_segment(
        *,
        segment_index: int,
        first_frame: int,
        last_frame: int,
        start_tick: int,
        end_tick: int,
        event_id: int,
        confidence_ppm: int,
        previous_segment_sha256: bytes,
    ) -> segment.Record:
        value: segment.Record = {
            "request_epoch": 221,
            "generation": 7,
            "segment_index": segment_index,
            "first_frame": first_frame,
            "last_frame": last_frame,
            "frame_count": last_frame - first_frame + 1,
            "frame_stride": 1,
            "keyframe_ordinal": 0,
            "eviction_boundary": 0,
            "cache_generation": 7,
            "target_numerator": 1,
            "target_denominator": 1_000,
            "target_start_tick": start_tick,
            "target_end_tick": end_tick,
            "event_id": event_id,
            "confidence_ppm": confidence_ppm,
            "media_object_sha256": model.sha256(b"timeline media"),
            "processor_state_sha256": model.sha256(b"timeline processor"),
            "processor_bundle_sha256": model.sha256(b"timeline processor bundle"),
            "cache_bundle_sha256": model.sha256(b"timeline cache bundle"),
            "cache_payload_sha256": model.sha256(b"timeline cache payload"),
            "ownership_sha256": model.sha256(b"timeline ownership"),
            "selection_sha256": model.sha256(b"timeline selection"),
            "challenge_sha256": model.sha256(b"timeline challenge"),
            "previous_segment_sha256": previous_segment_sha256,
        }
        value["segment_sha256"] = segment.segment_root(value)
        return segment.validate_segment(value)

    def setUp(self) -> None:
        self.first = self.make_segment(
            segment_index=1,
            first_frame=0,
            last_frame=9,
            start_tick=0,
            end_tick=10,
            event_id=7,
            confidence_ppm=600_000,
            previous_segment_sha256=model.sha256(b"segment genesis"),
        )
        self.second = self.make_segment(
            segment_index=2,
            first_frame=8,
            last_frame=15,
            start_tick=8,
            end_tick=16,
            event_id=7,
            confidence_ppm=700_000,
            previous_segment_sha256=self.first["segment_sha256"],
        )
        self.initial = timeline.initialize_timeline(
            self.first,
            model.sha256(b"decision genesis"),
        )
        self.merge = timeline.make_receipt(
            self.initial,
            self.first,
            self.second,
        )

    def test_wires_and_roots_are_mutation_complete(self) -> None:
        timeline_wire = timeline.encode_timeline(self.initial)
        receipt_wire = timeline.encode_receipt(self.merge)
        self.assertEqual(
            timeline.decode_timeline(timeline_wire),
            self.initial,
        )
        self.assertEqual(
            timeline.decode_receipt(receipt_wire),
            self.merge,
        )
        self.assertEqual(
            self.initial["timeline_sha256"].hex(),
            "81e3e59397afb89fc38a772a7bd6dfba716275365a10f4d130afb3165c59ccbd",
        )
        self.assertEqual(
            self.merge["receipt_sha256"].hex(),
            "11e668efb1cc13432dda079d2341bc73ccbbf84b8c19b64a0ff842cca3f43319",
        )
        for wire, decoder in (
            (timeline_wire, timeline.decode_timeline),
            (receipt_wire, timeline.decode_receipt),
        ):
            for index in range(len(wire)):
                mutated = bytearray(wire)
                mutated[index] ^= 1
                with self.assertRaises(timeline.VideoSegmentTimelineError):
                    decoder(bytes(mutated))

    def test_overlap_coalesces_but_gap_and_event_change_do_not(self) -> None:
        self.assertEqual(self.merge["action"], timeline.COALESCE)
        self.assertEqual(self.merge["input_overlap_ticks"], 2)
        state = timeline.apply_receipt(
            self.initial,
            self.first,
            self.second,
            self.merge,
        )
        self.assertEqual(state["visible_segments"], 1)
        self.assertEqual(state["tail_start_tick"], 0)
        self.assertEqual(state["tail_end_tick"], 16)
        third = self.make_segment(
            segment_index=3,
            first_frame=20,
            last_frame=24,
            start_tick=20,
            end_tick=25,
            event_id=7,
            confidence_ppm=650_000,
            previous_segment_sha256=self.second["segment_sha256"],
        )
        gap = timeline.make_receipt(state, self.second, third)
        self.assertEqual(gap["action"], timeline.RETAIN_DISTINCT)
        state = timeline.apply_receipt(
            state,
            self.second,
            third,
            gap,
        )
        fourth = self.make_segment(
            segment_index=4,
            first_frame=23,
            last_frame=29,
            start_tick=23,
            end_tick=30,
            event_id=8,
            confidence_ppm=900_000,
            previous_segment_sha256=third["segment_sha256"],
        )
        changed = timeline.make_receipt(state, third, fourth)
        self.assertEqual(changed["action"], timeline.RETAIN_DISTINCT)
        self.assertEqual(changed["input_overlap_ticks"], 2)

    def test_foreign_lineage_and_order_reject(self) -> None:
        out_of_order = self.make_segment(
            segment_index=3,
            first_frame=8,
            last_frame=15,
            start_tick=8,
            end_tick=16,
            event_id=7,
            confidence_ppm=700_000,
            previous_segment_sha256=self.first["segment_sha256"],
        )
        with self.assertRaises(timeline.VideoSegmentTimelineError):
            timeline.make_receipt(
                self.initial,
                self.first,
                out_of_order,
            )
        foreign = dict(self.second)
        foreign["media_object_sha256"] = model.sha256(b"foreign timeline media")
        foreign["segment_sha256"] = segment.segment_root(foreign)
        with self.assertRaises(timeline.VideoSegmentTimelineError):
            timeline.make_receipt(
                self.initial,
                self.first,
                foreign,
            )


if __name__ == "__main__":
    unittest.main()
