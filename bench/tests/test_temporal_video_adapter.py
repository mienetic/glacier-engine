from __future__ import annotations

import struct
import unittest

from bench import media_contract as media
from bench import media_processor_state as processor
from bench import model_contract as contract


class TemporalVideoAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.weights = struct.pack("<bbbb", 1, 2, -1, 3)
        self.video_cache = bytes((1, 2, 3, 4, 5, 6, 7, 8))
        self.challenge = contract.sha256(b"video challenge")
        self.video_state = processor.make_video_state(
            {
                "kind": media.VIDEO,
                "request_epoch": 221,
                "generation": 7,
                "stream_key": 41_003,
                "timeline_numerator": 1,
                "timeline_denominator": 30,
                "media_object_sha256": contract.sha256(b"video media"),
                "processor_plan_sha256": contract.sha256(
                    b"video processor"
                ),
                "previous_state_sha256": contract.sha256(
                    b"previous video state"
                ),
                "challenge_sha256": self.challenge,
                "cache_content_sha256": contract.sha256(
                    self.video_cache
                ),
                "output_chain_sha256": contract.sha256(b"video output"),
                "ownership_receipt_sha256": contract.sha256(
                    b"video ownership"
                ),
                "decoder_state_sha256": contract.sha256(
                    b"video decoder"
                ),
            },
            4,
            2,
            10,
            14,
            10,
        )
        self.selection = contract.make_temporal_video_selection(
            self.video_state,
            first_frame=10,
            frame_count=2,
            frame_stride=2,
            target_base=(1, 90_000),
        )
        self.assertEqual(
            self.selection["selection_sha256"].hex(),
            "05910857e31e4c92c9124a22533a6d43"
            "51491e0c5fe4dfe83312c4eefb049ae4",
        )
        self.artifact = contract.make_artifact(
            family=contract.VIDEO_UNDERSTANDING,
            artifact_abi=0x564944454F000001,
            input_kind=contract.VIDEO_FEATURE_U8,
            output_kind=contract.EMBEDDING_I32,
            numerical_policy=contract.EXACT_INTEGER,
            max_batch_items=2,
            input_features=2,
            output_dimensions=2,
            input_element_bytes=1,
            output_element_bytes=4,
            weight_element_bytes=1,
            weights=self.weights,
            metadata_sha256=contract.sha256(
                b"video fixture metadata"
            ),
            license_sha256=contract.sha256(b"fixture-only license"),
        )
        self.plan = contract.make_plan(
            self.artifact,
            operation=contract.ENCODE,
            request_epoch=221,
            generation=7,
            batch_items=2,
            publication_next_sequence=0,
            maximum_absolute_output=100,
            required_capabilities=0,
            scratch_bytes=16,
            claim={
                "capsule_bytes": 4,
                "kv_bytes": 0,
                "activation_bytes": 4,
                "partial_bytes": 16,
                "logits_bytes": 0,
                "output_journal_bytes": 16,
                "staging_bytes": 4,
                "device_bytes": 0,
                "io_bytes": 0,
                "queue_slots": 1,
            },
            digests={
                "media_object_sha256": self.video_state[
                    "media_object_sha256"
                ],
                "processor_state_sha256": self.video_state[
                    "state_sha256"
                ],
                "processor_bundle_sha256": contract.sha256(
                    b"processor bundle"
                ),
                "cache_bundle_sha256": contract.sha256(b"cache bundle"),
                "cache_payload_sha256": self.video_state[
                    "cache_content_sha256"
                ],
                "ownership_sha256": self.video_state[
                    "ownership_receipt_sha256"
                ],
                "challenge_sha256": self.challenge,
                "previous_plan_sha256": contract.sha256(
                    b"previous video plan"
                ),
                "input_schema_sha256": contract.sha256(
                    b"two strided frames by two u8 features"
                ),
                "output_schema_sha256": contract.sha256(
                    b"two frames by two i32 embedding"
                ),
            },
        )

    def test_strided_gather_projection_and_mapping(self) -> None:
        selected = contract.materialize_temporal_video_selection(
            self.plan,
            self.video_state,
            self.selection,
            self.video_cache,
        )
        self.assertEqual(selected, bytes((1, 2, 5, 6)))
        output = contract.reference_integer_projection(
            self.plan,
            self.weights,
            selected,
        )
        self.assertEqual(struct.unpack("<iiii", output), (5, 5, 17, 13))
        mapping = contract.temporal_video_source_mapping_root(
            self.plan,
            self.video_state,
            self.selection,
        )
        self.assertEqual(
            mapping.hex(),
            "cbdf30f05789216a9a4c3e57d91eed91"
            "4f8a970a90edc3ecf3fde6db17eeb1ed",
        )

    def test_stale_selection_and_foreign_cache_reject(self) -> None:
        stale = dict(self.selection)
        stale["eviction_boundary"] += 1
        with self.assertRaises(contract.ModelContractError):
            contract.validate_temporal_video_selection(
                self.video_state,
                stale,
            )
        foreign = bytearray(self.video_cache)
        foreign[0] ^= 1
        with self.assertRaises(contract.ModelContractError):
            contract.materialize_temporal_video_selection(
                self.plan,
                self.video_state,
                self.selection,
                bytes(foreign),
            )


if __name__ == "__main__":
    unittest.main()
