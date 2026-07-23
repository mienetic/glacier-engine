from __future__ import annotations

import unittest

from bench import audio_transcript_adapter as audio
from bench import audio_transcript_continuation as continuation
from bench import audio_video_result_link as result_link
from bench import media_runtime_txn as resource
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as model_continuation
from bench import stateful_transcript_adapter as transcript_model
from bench import video_segment_adapter as video_segment
from bench import video_segment_timeline as video_timeline


class AudioTranscriptContinuationTests(unittest.TestCase):
    @staticmethod
    def make_overlap(
        *,
        generation: int,
        segment_index: int,
        source_start: int,
        publish_start: int,
        publish_end: int,
        previous_transcript_sha256: bytes,
        challenge_sha256: bytes,
    ) -> dict[str, object]:
        overlap: dict[str, object] = {
            "request_epoch": 431,
            "generation": generation,
            "segment_index": segment_index,
            "source_start_sample": source_start,
            "source_end_sample": publish_end,
            "context_start_sample": source_start,
            "context_end_sample": publish_start,
            "publish_start_sample": publish_start,
            "publish_end_sample": publish_end,
            "sample_rate": 1_000,
            "window_samples": publish_end - source_start,
            "hop_samples": publish_end - publish_start,
            "feature_frames": 1,
            "feature_bins": transcript_model.REFERENCE_INPUT_FEATURES,
            "feature_bytes": len(
                transcript_model.REFERENCE_FIRST_FEATURES
            ),
            "media_object_sha256": model.sha256(
                b"continued transcript audio"
            ),
            "processor_state_sha256": model.sha256(
                b"continued transcript processor"
            ),
            "processor_bundle_sha256": model.sha256(
                b"continued transcript processor bundle"
            ),
            "cache_bundle_sha256": model.sha256(
                b"continued transcript cache bundle"
            ),
            "cache_payload_sha256": model.sha256(
                b"continued transcript feature cache"
            ),
            "ownership_sha256": model.sha256(
                b"continued transcript ownership"
            ),
            "challenge_sha256": challenge_sha256,
            "previous_transcript_sha256": previous_transcript_sha256,
        }
        overlap["overlap_sha256"] = audio.overlap_root(overlap)
        return audio.validate_overlap(overlap)

    @staticmethod
    def make_timeline(
        challenge_sha256: bytes,
    ) -> dict[str, object]:
        segment: dict[str, object] = {
            "request_epoch": 431,
            "generation": 1,
            "segment_index": 1,
            "first_frame": 0,
            "last_frame": 19,
            "frame_count": 20,
            "frame_stride": 1,
            "keyframe_ordinal": 0,
            "eviction_boundary": 0,
            "cache_generation": 1,
            "target_numerator": 1,
            "target_denominator": 1_000,
            "target_start_tick": 0,
            "target_end_tick": 20,
            "event_id": 7,
            "confidence_ppm": 900_000,
            "media_object_sha256": model.sha256(
                b"continued transcript video"
            ),
            "processor_state_sha256": model.sha256(
                b"continued video processor"
            ),
            "processor_bundle_sha256": model.sha256(
                b"continued video processor bundle"
            ),
            "cache_bundle_sha256": model.sha256(
                b"continued video cache bundle"
            ),
            "cache_payload_sha256": model.sha256(
                b"continued video cache payload"
            ),
            "ownership_sha256": model.sha256(
                b"continued video ownership"
            ),
            "selection_sha256": model.sha256(
                b"continued video selection"
            ),
            "challenge_sha256": challenge_sha256,
            "previous_segment_sha256": model.sha256(
                b"continued video genesis"
            ),
        }
        segment["segment_sha256"] = video_segment.segment_root(segment)
        segment = video_segment.validate_segment(segment)
        return video_timeline.initialize_timeline(
            segment,
            model.sha256(b"continued timeline genesis"),
        )

    def setUp(self) -> None:
        self.challenge = model.sha256(b"continued transcript challenge")
        self.first_overlap = self.make_overlap(
            generation=1,
            segment_index=1,
            source_start=0,
            publish_start=2,
            publish_end=10,
            previous_transcript_sha256=model.sha256(
                b"continued transcript genesis"
            ),
            challenge_sha256=self.challenge,
        )
        self.manifest = transcript_model.make_manifest()
        initial_state = transcript_model.initialize_state(self.first_overlap)
        self.initial_state_wire = transcript_model.encode_state(initial_state)
        initial_publication = stateful.initialize_publication(
            request_epoch=431,
            total_steps=2,
            state_bytes=transcript_model.REFERENCE_STATE_BYTES,
            artifact_sha256=self.manifest["artifact_sha256"],
            current_state_sha256=model.sha256(self.initial_state_wire),
            challenge_sha256=self.challenge,
        )
        initial_model_publication = {
            "request_epoch": 431,
            "next_sequence": 0,
            "visible_results": 0,
            "artifact_sha256": self.manifest["artifact_sha256"],
            "previous_result_sha256": bytes(32),
        }
        first_plan = transcript_model.make_plan(
            manifest=self.manifest,
            model_publication=initial_model_publication,
            state_publication=initial_publication,
            overlap_value=self.first_overlap,
            previous_plan_sha256=model.sha256(
                b"stateful transcript genesis plan"
            ),
        )
        first_output, self.first_state_wire = (
            transcript_model.reference_step(
                overlap_value=self.first_overlap,
                current_state_wire=self.initial_state_wire,
                features=transcript_model.REFERENCE_FIRST_FEATURES,
                text_bytes=3,
            )
        )
        adapter_sha256 = transcript_model.adapter_root(self.manifest)
        transition_sha256 = stateful.transition_root(
            initial_publication,
            first_plan,
            model.sha256(first_output),
            model.sha256(self.first_state_wire),
            adapter_sha256,
        )
        receipt = resource.resource_receipt(
            101_001,
            0,
            1,
            101_101,
            first_plan["claim"],
        )
        first_result = model.make_result(
            initial_model_publication,
            first_plan,
            receipt,
            output_sha256=model.sha256(first_output),
            source_mapping_sha256=transition_sha256,
            adapter_sha256=adapter_sha256,
        )
        self.state_publication = dict(initial_publication)
        self.state_publication.update(
            {
                "current_step": 1,
                "current_state_sha256": model.sha256(
                    self.first_state_wire
                ),
                "previous_result_sha256": first_result["result_sha256"],
            }
        )
        self.state_publication["publication_sha256"] = (
            stateful.publication_root(self.state_publication)
        )
        model_publication = {
            "request_epoch": 431,
            "next_sequence": 1,
            "visible_results": 1,
            "artifact_sha256": self.manifest["artifact_sha256"],
            "previous_result_sha256": first_result["result_sha256"],
        }
        self.stateful_checkpoint = model_continuation.make_checkpoint(
            source_bank_epoch=101_001,
            restore_plan={
                "restore_bank_epoch": 102_001,
                "restore_owner_key": 102_101,
                "restore_tree_key": 102_201,
                "restore_authority_key": 102_301,
                "tenant_key": 102_401,
                "scope_key": 102_501,
                "allocation_key": 102_601,
                "binding_key": 102_701,
            },
            model_publication=model_publication,
            state_publication=self.state_publication,
            last_result=first_result,
        )
        self.previous_transcript = audio.make_transcript(
            self.first_overlap,
            first_output[:3],
        )
        self.next_overlap = self.make_overlap(
            generation=2,
            segment_index=2,
            source_start=8,
            publish_start=10,
            publish_end=18,
            previous_transcript_sha256=self.previous_transcript[
                "transcript_sha256"
            ],
            challenge_sha256=self.challenge,
        )
        self.timeline = self.make_timeline(self.challenge)
        self.link_state = result_link.initialize_state(
            431,
            self.first_overlap["media_object_sha256"],
            self.timeline["media_object_sha256"],
            self.challenge,
            model.sha256(b"continued link genesis"),
        )
        self.first_link = result_link.make_link(
            self.link_state,
            self.first_overlap,
            self.previous_transcript,
            self.timeline,
        )
        self.link_state = result_link.apply_link(
            self.link_state,
            self.first_overlap,
            self.previous_transcript,
            self.timeline,
            self.first_link,
        )
        self.checkpoint = continuation.make_checkpoint(
            self.stateful_checkpoint,
            self.state_publication,
            self.first_overlap,
            self.previous_transcript,
            self.first_link,
            self.next_overlap,
            self.timeline,
            self.link_state,
        )

    def test_checkpoint_wire_mutation_and_golden(self) -> None:
        encoded = continuation.encode_checkpoint(self.checkpoint)
        self.assertEqual(
            continuation.decode_checkpoint(encoded),
            self.checkpoint,
        )
        self.assertEqual(
            self.stateful_checkpoint["checkpoint_sha256"].hex(),
            "dfb92dd4895a10a91c9de6c7cbe48e4ce47da5b5fce154fec23b2acd8d500d75",
        )
        self.assertEqual(
            self.checkpoint["checkpoint_sha256"].hex(),
            "7c70fd73db93752fad108aab54894402617a864ba0ec7032d044a69fa7538816",
        )
        self.assertEqual(
            self.stateful_checkpoint["last_output_sha256"],
            model.sha256(self.previous_transcript["text"]),
        )
        for index in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[index] ^= 1
            with self.assertRaises(
                continuation.AudioTranscriptContinuationError
            ):
                continuation.decode_checkpoint(bytes(mutated))

    def test_restored_state_publishes_and_links_exact_next_segment(self) -> None:
        restored_publication = (
            model_continuation.reconstruct_model_publication(
                self.stateful_checkpoint,
                self.state_publication,
            )
        )
        second_plan = transcript_model.make_plan(
            manifest=self.manifest,
            model_publication=restored_publication,
            state_publication=self.state_publication,
            overlap_value=self.next_overlap,
            previous_plan_sha256=self.stateful_checkpoint[
                "last_plan_sha256"
            ],
        )
        second_output, second_state_wire = (
            transcript_model.reference_step(
                overlap_value=self.next_overlap,
                current_state_wire=self.first_state_wire,
                features=transcript_model.REFERENCE_SECOND_FEATURES,
                text_bytes=4,
            )
        )
        self.assertEqual(second_output[:4], b"berg")
        second_state = transcript_model.decode_state(second_state_wire)
        self.assertEqual(second_state["segment_index"], 2)
        self.assertEqual(second_state["next_sample"], 18)
        self.assertEqual(second_plan["generation"], 2)
        next_transcript = audio.make_transcript(
            self.next_overlap,
            second_output[:4],
        )
        audio.validate_predecessor(
            self.next_overlap,
            self.previous_transcript,
        )
        next_link = result_link.make_link(
            self.link_state,
            self.next_overlap,
            next_transcript,
            self.timeline,
        )
        next_link_state = result_link.apply_link(
            self.link_state,
            self.next_overlap,
            next_transcript,
            self.timeline,
            next_link,
        )
        self.assertEqual(next_link_state["visible_links"], 2)
        self.assertEqual(
            next_link["previous_link_sha256"],
            self.link_state["previous_link_sha256"],
        )

    def test_foreign_next_overlap_rejects(self) -> None:
        foreign = dict(self.next_overlap)
        foreign["challenge_sha256"] = model.sha256(
            b"foreign continuation challenge"
        )
        foreign["overlap_sha256"] = audio.overlap_root(foreign)
        with self.assertRaises(
            continuation.AudioTranscriptContinuationError
        ):
            continuation.validate_bindings(
                self.checkpoint,
                self.stateful_checkpoint,
                self.state_publication,
                self.first_overlap,
                self.previous_transcript,
                self.first_link,
                foreign,
                self.timeline,
                self.link_state,
            )

    def test_rehashed_output_and_link_substitutions_reject(self) -> None:
        foreign_stateful = dict(self.stateful_checkpoint)
        foreign_stateful["last_output_sha256"] = model.sha256(
            b"substituted transcript output"
        )
        foreign_stateful["checkpoint_sha256"] = (
            model_continuation.checkpoint_root(foreign_stateful)
        )
        foreign_output_checkpoint = dict(self.checkpoint)
        foreign_output_checkpoint["stateful_checkpoint_sha256"] = (
            foreign_stateful["checkpoint_sha256"]
        )
        foreign_output_checkpoint["checkpoint_sha256"] = (
            continuation.checkpoint_root(foreign_output_checkpoint)
        )
        with self.assertRaises(
            continuation.AudioTranscriptContinuationError
        ):
            continuation.validate_bindings(
                foreign_output_checkpoint,
                foreign_stateful,
                self.state_publication,
                self.first_overlap,
                self.previous_transcript,
                self.first_link,
                self.next_overlap,
                self.timeline,
                self.link_state,
            )

        foreign_link = dict(self.first_link)
        foreign_link["transcript_sha256"] = model.sha256(
            b"substituted linked transcript"
        )
        foreign_link["link_sha256"] = result_link.link_root(foreign_link)
        result_link.validate_link(foreign_link)
        foreign_link_state = dict(self.link_state)
        foreign_link_state["previous_link_sha256"] = foreign_link[
            "link_sha256"
        ]
        foreign_link_state["state_sha256"] = result_link.state_root(
            foreign_link_state
        )
        foreign_link_checkpoint = dict(self.checkpoint)
        foreign_link_checkpoint["link_state_sha256"] = foreign_link_state[
            "state_sha256"
        ]
        foreign_link_checkpoint["previous_link_sha256"] = foreign_link[
            "link_sha256"
        ]
        foreign_link_checkpoint["checkpoint_sha256"] = (
            continuation.checkpoint_root(foreign_link_checkpoint)
        )
        with self.assertRaises(
            continuation.AudioTranscriptContinuationError
        ):
            continuation.validate_bindings(
                foreign_link_checkpoint,
                self.stateful_checkpoint,
                self.state_publication,
                self.first_overlap,
                self.previous_transcript,
                foreign_link,
                self.next_overlap,
                self.timeline,
                foreign_link_state,
            )


if __name__ == "__main__":
    unittest.main()
