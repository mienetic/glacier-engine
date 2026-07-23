from __future__ import annotations

import unittest

from bench import media_contract as media
from bench import media_processor_state as processor
from bench import model_contract as model
from bench import video_segment_adapter as segment


class VideoSegmentAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.video_cache = bytes((1, 2, 3, 4, 5, 6, 7, 8))
        challenge = model.sha256(b"video challenge")
        self.video_state = processor.make_video_state(
            {
                "kind": media.VIDEO,
                "request_epoch": 221,
                "generation": 7,
                "stream_key": 41_003,
                "timeline_numerator": 1,
                "timeline_denominator": 30,
                "media_object_sha256": model.sha256(b"video media"),
                "processor_plan_sha256": model.sha256(b"video processor"),
                "previous_state_sha256": model.sha256(b"previous video state"),
                "challenge_sha256": challenge,
                "cache_content_sha256": model.sha256(self.video_cache),
                "output_chain_sha256": model.sha256(b"video output"),
                "ownership_receipt_sha256": model.sha256(b"video ownership"),
                "decoder_state_sha256": model.sha256(b"video decoder"),
            },
            4,
            2,
            10,
            14,
            10,
        )
        self.selection = model.make_temporal_video_selection(
            self.video_state,
            first_frame=10,
            frame_count=2,
            frame_stride=2,
            target_base=(1, 90_000),
        )
        self.previous = model.sha256(b"previous video segment")
        self.artifact = model.make_artifact(
            family=model.VIDEO_UNDERSTANDING,
            artifact_abi=0x5653454700000001,
            input_kind=model.VIDEO_FEATURE_U8,
            output_kind=model.VIDEO_SEGMENT,
            numerical_policy=model.EXACT_INTEGER,
            max_batch_items=1,
            input_features=4,
            output_dimensions=segment.VIDEO_SEGMENT_BYTES,
            input_element_bytes=1,
            output_element_bytes=1,
            weight_element_bytes=1,
            weights=b"\x56",
            metadata_sha256=model.sha256(b"video segment fixture metadata"),
            license_sha256=model.sha256(b"fixture-only license"),
        )
        digests = {
            "media_object_sha256": self.video_state["media_object_sha256"],
            "processor_state_sha256": self.video_state["state_sha256"],
            "processor_bundle_sha256": model.sha256(b"video processor bundle"),
            "cache_bundle_sha256": model.sha256(b"video cache bundle"),
            "cache_payload_sha256": self.video_state["cache_content_sha256"],
            "ownership_sha256": self.video_state["ownership_receipt_sha256"],
            "challenge_sha256": challenge,
            "previous_plan_sha256": model.sha256(b"previous video segment plan"),
            "input_schema_sha256": model.sha256(b"provisional segment source"),
            "output_schema_sha256": segment.schema_root(),
        }
        claim = {
            "capsule_bytes": 1,
            "kv_bytes": 0,
            "activation_bytes": 4,
            "partial_bytes": segment.VIDEO_SEGMENT_BYTES,
            "logits_bytes": 0,
            "output_journal_bytes": segment.VIDEO_SEGMENT_BYTES,
            "staging_bytes": 4,
            "device_bytes": 0,
            "io_bytes": 0,
            "queue_slots": 1,
        }

        def make_plan() -> model.Record:
            return model.make_plan(
                self.artifact,
                operation=model.SEGMENT,
                request_epoch=221,
                generation=7,
                batch_items=1,
                publication_next_sequence=0,
                maximum_absolute_output=255,
                required_capabilities=0,
                scratch_bytes=segment.VIDEO_SEGMENT_BYTES,
                claim=claim,
                digests=digests,
            )

        provisional = make_plan()
        digests["input_schema_sha256"] = segment.segment_source_root(
            provisional,
            self.selection,
            3,
            self.previous,
        )
        self.plan = make_plan()
        self.result = segment.make_segment(
            self.plan,
            self.selection,
            3,
            self.previous,
            15,
            500_014,
        )

    def test_wire_and_source_roots_are_mutation_complete(self) -> None:
        encoded = segment.encode_segment(self.result)
        self.assertEqual(segment.decode_segment(encoded), self.result)
        self.assertEqual(
            self.plan["input_schema_sha256"].hex(),
            "76eb274c3afc40640b4b0125ee886e88e915268380f19d7156fe2e7f1252e0ac",
        )
        self.assertEqual(
            self.result["segment_sha256"].hex(),
            "d7d3122d8fb22e872c8825f002e1b7b4f47b8bf912a2920a8eb41165b7d61cf4",
        )
        for index in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[index] ^= 1
            with self.assertRaises(segment.VideoSegmentAdapterError):
                segment.decode_segment(bytes(mutated))

    def test_selected_frames_drive_one_bounded_result(self) -> None:
        selected = model.materialize_temporal_video_frames(
            self.video_state,
            self.selection,
            self.video_cache,
        )
        self.assertEqual(selected, bytes((1, 2, 5, 6)))
        self.assertEqual(sum(selected) % 1_024 + 1, 15)
        self.assertEqual(self.result["first_frame"], 10)
        self.assertEqual(self.result["last_frame"], 12)
        self.assertEqual(self.result["target_start_tick"], 30_000)
        self.assertEqual(self.result["target_end_tick"], 39_000)

    def test_foreign_predecessor_and_selection_reject(self) -> None:
        foreign_previous = model.sha256(b"foreign segment")
        with self.assertRaises(segment.VideoSegmentAdapterError):
            segment.make_segment(
                self.plan,
                self.selection,
                3,
                foreign_previous,
                15,
                500_014,
            )
        stale = dict(self.selection)
        stale["selection_sha256"] = model.sha256(b"stale video selection")
        with self.assertRaises(segment.VideoSegmentAdapterError):
            segment.make_segment(
                self.plan,
                stale,
                3,
                self.previous,
                15,
                500_014,
            )


if __name__ == "__main__":
    unittest.main()
