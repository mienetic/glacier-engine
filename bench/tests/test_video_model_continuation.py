from __future__ import annotations

import unittest

from bench import audio_transcript_adapter as audio
from bench import audio_video_result_link as result_link
from bench import media_runtime_txn as resource
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as model_continuation
from bench import stateful_video_adapter as video_model
from bench import video_model_continuation as continuation
from bench import video_segment_adapter as video_segment
from bench import video_segment_timeline as video_timeline


class VideoModelContinuationTests(unittest.TestCase):
    def make_window(
        self,
        *,
        generation: int,
        previous_end_tick: int,
        frame_ordinals: tuple[int, ...],
        presentation_ticks: tuple[int, ...],
        duration_ticks: tuple[int, ...],
        previous_window_sha256: bytes,
    ) -> dict[str, object]:
        return video_model.make_window(
            request_epoch=531,
            generation=generation,
            segment_index=generation,
            target_base=(1, 1_000),
            previous_end_tick=previous_end_tick,
            frame_ordinals=frame_ordinals,
            presentation_ticks=presentation_ticks,
            duration_ticks=duration_ticks,
            keyframe_flags=(1, 0),
            digests={
                "media_object_sha256": model.sha256(
                    b"continued VFR video media"
                ),
                "processor_bundle_sha256": model.sha256(
                    b"continued VFR processor bundle"
                ),
                "cache_bundle_sha256": model.sha256(
                    b"continued VFR cache bundle"
                ),
                "ownership_sha256": model.sha256(
                    b"continued VFR ownership"
                ),
                "frame_payload_sha256": model.sha256(
                    video_model.REFERENCE_FIRST_FEATURES
                    if generation == 1
                    else video_model.REFERENCE_SECOND_FEATURES
                ),
                "previous_window_sha256": previous_window_sha256,
                "challenge_sha256": self.challenge,
            },
        )

    def make_overlap(
        self,
        *,
        generation: int,
        source_start: int,
        publish_start: int,
        publish_end: int,
        previous_transcript_sha256: bytes,
    ) -> dict[str, object]:
        overlap: dict[str, object] = {
            "request_epoch": 531,
            "generation": generation,
            "segment_index": generation,
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
            "feature_bins": 4,
            "feature_bytes": 8,
            "media_object_sha256": model.sha256(
                b"continued VFR audio media"
            ),
            "processor_state_sha256": model.sha256(
                b"continued VFR audio processor"
            ),
            "processor_bundle_sha256": model.sha256(
                b"continued VFR audio processor bundle"
            ),
            "cache_bundle_sha256": model.sha256(
                b"continued VFR audio cache bundle"
            ),
            "cache_payload_sha256": model.sha256(
                b"continued VFR audio feature cache"
            ),
            "ownership_sha256": model.sha256(
                b"continued VFR audio ownership"
            ),
            "challenge_sha256": self.challenge,
            "previous_transcript_sha256": previous_transcript_sha256,
        }
        overlap["overlap_sha256"] = audio.overlap_root(overlap)
        return audio.validate_overlap(overlap)

    def setUp(self) -> None:
        self.challenge = model.sha256(b"continued VFR challenge")
        self.previous_window = self.make_window(
            generation=1,
            previous_end_tick=0,
            frame_ordinals=(0, 1),
            presentation_ticks=(0, 8),
            duration_ticks=(8, 12),
            previous_window_sha256=model.sha256(
                b"continued VFR window genesis"
            ),
        )
        self.next_window = self.make_window(
            generation=2,
            previous_end_tick=20,
            frame_ordinals=(2, 3),
            presentation_ticks=(25, 35),
            duration_ticks=(10, 15),
            previous_window_sha256=self.previous_window["window_sha256"],
        )
        self.manifest = video_model.make_manifest()
        initial_state = video_model.initialize_state(self.previous_window)
        self.initial_state_wire = video_model.encode_state(initial_state)
        initial_publication = stateful.initialize_publication(
            request_epoch=531,
            total_steps=2,
            state_bytes=video_model.REFERENCE_STATE_BYTES,
            artifact_sha256=self.manifest["artifact_sha256"],
            current_state_sha256=model.sha256(self.initial_state_wire),
            challenge_sha256=self.challenge,
        )
        initial_model_publication = {
            "request_epoch": 531,
            "next_sequence": 0,
            "visible_results": 0,
            "artifact_sha256": self.manifest["artifact_sha256"],
            "previous_result_sha256": bytes(32),
        }
        first_plan = video_model.make_plan(
            manifest=self.manifest,
            model_publication=initial_model_publication,
            state_publication=initial_publication,
            window_value=self.previous_window,
            previous_plan_sha256=model.sha256(
                b"stateful VFR video genesis plan"
            ),
        )
        first_output, self.first_state_wire = video_model.reference_step(
            plan=first_plan,
            window_value=self.previous_window,
            previous_segment_sha256=model.sha256(
                b"continued VFR segment genesis"
            ),
            current_state_wire=self.initial_state_wire,
            features=video_model.REFERENCE_FIRST_FEATURES,
        )
        self.previous_segment = video_segment.decode_segment(first_output)
        adapter_sha256 = video_model.adapter_root(self.manifest)
        transition_sha256 = stateful.transition_root(
            initial_publication,
            first_plan,
            model.sha256(first_output),
            model.sha256(self.first_state_wire),
            adapter_sha256,
        )
        receipt = resource.resource_receipt(
            111_001,
            0,
            1,
            111_101,
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
            "request_epoch": 531,
            "next_sequence": 1,
            "visible_results": 1,
            "artifact_sha256": self.manifest["artifact_sha256"],
            "previous_result_sha256": first_result["result_sha256"],
        }
        self.stateful_checkpoint = model_continuation.make_checkpoint(
            source_bank_epoch=111_001,
            restore_plan={
                "restore_bank_epoch": 112_001,
                "restore_owner_key": 112_101,
                "restore_tree_key": 112_201,
                "restore_authority_key": 112_301,
                "tenant_key": 112_401,
                "scope_key": 112_501,
                "allocation_key": 112_601,
                "binding_key": 112_701,
            },
            model_publication=model_publication,
            state_publication=self.state_publication,
            last_result=first_result,
        )
        self.timeline = video_timeline.initialize_timeline(
            self.previous_segment,
            model.sha256(b"continued VFR timeline genesis"),
        )
        self.previous_overlap = self.make_overlap(
            generation=1,
            source_start=0,
            publish_start=2,
            publish_end=27,
            previous_transcript_sha256=model.sha256(
                b"continued VFR transcript genesis"
            ),
        )
        self.previous_transcript = audio.make_transcript(
            self.previous_overlap,
            b"alpha",
        )
        self.next_overlap = self.make_overlap(
            generation=2,
            source_start=25,
            publish_start=27,
            publish_end=48,
            previous_transcript_sha256=self.previous_transcript[
                "transcript_sha256"
            ],
        )
        self.next_transcript = audio.make_transcript(
            self.next_overlap,
            b"beta",
        )
        self.link_state = result_link.initialize_state(
            531,
            self.previous_overlap["media_object_sha256"],
            self.previous_window["media_object_sha256"],
            self.challenge,
            model.sha256(b"continued VFR link genesis"),
        )
        self.previous_link = result_link.make_link(
            self.link_state,
            self.previous_overlap,
            self.previous_transcript,
            self.timeline,
        )
        self.link_state = result_link.apply_link(
            self.link_state,
            self.previous_overlap,
            self.previous_transcript,
            self.timeline,
            self.previous_link,
        )
        self.checkpoint = continuation.make_checkpoint(
            self.stateful_checkpoint,
            self.state_publication,
            self.previous_window,
            self.previous_segment,
            self.next_window,
            self.timeline,
            self.previous_overlap,
            self.previous_transcript,
            self.next_overlap,
            self.next_transcript,
            self.previous_link,
            self.link_state,
        )

    def test_checkpoint_and_window_wires_reject_every_mutation(self) -> None:
        self.assertEqual(
            self.previous_window["window_sha256"].hex(),
            "675be9c8d94b3ec30fbe0f7a667449934e7cfe5c9b9a0a8ef8dedba291cef3b7",
        )
        self.assertEqual(
            self.next_window["window_sha256"].hex(),
            "126d9db409e7d4bf7d81b3c2f2cfec7112e326be6a4691c563e8d5207f4928b4",
        )
        self.assertEqual(
            self.stateful_checkpoint["checkpoint_sha256"].hex(),
            "9640bc8247bf6776afd5d62a3df728f9afaf806bfb7a58b22930f9967fb8a38a",
        )
        self.assertEqual(
            self.checkpoint["checkpoint_sha256"].hex(),
            "cfe9828b0e030d6683e0bc14c093e79dd497411021f800243619c645f9dfc8f9",
        )
        for encoded, decoder in (
            (
                video_model.encode_window(self.next_window),
                video_model.decode_window,
            ),
            (
                continuation.encode_checkpoint(self.checkpoint),
                continuation.decode_checkpoint,
            ),
        ):
            self.assertEqual(decoder(encoded), decoder(encoded))
            for index in range(len(encoded)):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(ValueError):
                    decoder(bytes(mutated))

    def test_restored_state_advances_vfr_timeline_and_link(self) -> None:
        restored_model_publication = (
            model_continuation.reconstruct_model_publication(
                self.stateful_checkpoint,
                self.state_publication,
            )
        )
        second_plan = video_model.make_plan(
            manifest=self.manifest,
            model_publication=restored_model_publication,
            state_publication=self.state_publication,
            window_value=self.next_window,
            previous_plan_sha256=self.stateful_checkpoint[
                "last_plan_sha256"
            ],
        )
        output, next_state_wire = video_model.reference_step(
            plan=second_plan,
            window_value=self.next_window,
            previous_segment_sha256=self.previous_segment[
                "segment_sha256"
            ],
            current_state_wire=self.first_state_wire,
            features=video_model.REFERENCE_SECOND_FEATURES,
        )
        next_segment = video_segment.decode_segment(output)
        self.assertEqual(next_segment["target_start_tick"], 25)
        self.assertEqual(next_segment["target_end_tick"], 50)
        next_state = video_model.decode_state(next_state_wire)
        self.assertEqual(next_state["next_frame_ordinal"], 4)
        receipt = video_timeline.make_receipt(
            self.timeline,
            self.previous_segment,
            next_segment,
        )
        next_timeline = video_timeline.apply_receipt(
            self.timeline,
            self.previous_segment,
            next_segment,
            receipt,
        )
        self.assertEqual(receipt["action"], video_timeline.RETAIN_DISTINCT)
        self.assertEqual(next_timeline["visible_segments"], 2)
        next_link = result_link.make_link(
            self.link_state,
            self.next_overlap,
            self.next_transcript,
            next_timeline,
        )
        next_link_state = result_link.apply_link(
            self.link_state,
            self.next_overlap,
            self.next_transcript,
            next_timeline,
            next_link,
        )
        self.assertEqual(next_link_state["visible_links"], 2)
        self.assertEqual(
            next_link["previous_link_sha256"],
            self.previous_link["link_sha256"],
        )

    def test_frame_payload_binds_exact_model_features(self) -> None:
        restored_model_publication = (
            model_continuation.reconstruct_model_publication(
                self.stateful_checkpoint,
                self.state_publication,
            )
        )
        second_plan = video_model.make_plan(
            manifest=self.manifest,
            model_publication=restored_model_publication,
            state_publication=self.state_publication,
            window_value=self.next_window,
            previous_plan_sha256=self.stateful_checkpoint[
                "last_plan_sha256"
            ],
        )
        with self.assertRaises(video_model.StatefulVideoAdapterError):
            video_model.reference_step(
                plan=second_plan,
                window_value=self.next_window,
                previous_segment_sha256=self.previous_segment[
                    "segment_sha256"
                ],
                current_state_wire=self.first_state_wire,
                features=bytes((3, 9, 0, 0)),
            )

    def test_rehashed_gap_substitution_rejects(self) -> None:
        foreign = dict(self.next_window)
        foreign["presentation_ticks"] = (24, 34, 0, 0)
        foreign["duration_ticks"] = (10, 16, 0, 0)
        foreign["start_tick"] = 24
        foreign["discontinuity_before_ticks"] = 4
        foreign["timestamp_payload_sha256"] = (
            video_model.timestamp_payload_root(foreign)
        )
        foreign["window_sha256"] = video_model.window_root(foreign)
        video_model.validate_window(foreign)
        with self.assertRaises(continuation.VideoModelContinuationError):
            continuation.validate_bindings(
                self.checkpoint,
                self.stateful_checkpoint,
                self.state_publication,
                self.previous_window,
                self.previous_segment,
                foreign,
                self.timeline,
                self.previous_overlap,
                self.previous_transcript,
                self.next_overlap,
                self.next_transcript,
                self.previous_link,
                self.link_state,
            )


if __name__ == "__main__":
    unittest.main()
