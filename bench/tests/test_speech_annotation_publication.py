from __future__ import annotations

import unittest

from bench import audio_transcript_adapter as audio
from bench import model_contract as model
from bench import speech_annotation_publication as annotation
from bench import stateful_transcript_adapter as transcript_model


class SpeechAnnotationPublicationTests(unittest.TestCase):
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

    def setUp(self) -> None:
        self.challenge = model.sha256(b"continued transcript challenge")
        transcript_genesis = model.sha256(
            b"continued transcript genesis"
        )
        self.first_overlap = self.make_overlap(
            generation=1,
            segment_index=1,
            source_start=0,
            publish_start=2,
            publish_end=10,
            previous_transcript_sha256=transcript_genesis,
            challenge_sha256=self.challenge,
        )
        self.first_transcript = audio.make_transcript(
            self.first_overlap, b"ice"
        )
        self.second_overlap = self.make_overlap(
            generation=2,
            segment_index=2,
            source_start=8,
            publish_start=10,
            publish_end=18,
            previous_transcript_sha256=self.first_transcript[
                "transcript_sha256"
            ],
            challenge_sha256=self.challenge,
        )
        self.second_transcript = audio.make_transcript(
            self.second_overlap, b"berg"
        )
        self.first_words: tuple[annotation.Word, ...] = (
            (0, 3, 2, 10, 0, 950_000),
        )
        self.second_words: tuple[annotation.Word, ...] = (
            (0, 4, 10, 18, 0, 925_000),
        )
        self.first_speakers = (
            model.sha256(b"speech annotation speaker one"),
        )
        self.second_speakers = (
            model.sha256(b"speech annotation speaker two"),
        )
        self.initial_state = annotation.initialize_state(
            request_epoch=431,
            audio_media_sha256=self.first_overlap[
                "media_object_sha256"
            ],
            sample_rate=1_000,
            next_sample=2,
            last_transcript_sha256=transcript_genesis,
            genesis_result_sha256=model.sha256(
                b"speech annotation result genesis"
            ),
            genesis_speaker_sha256=model.sha256(
                b"speech annotation speaker genesis"
            ),
            challenge_sha256=self.challenge,
        )
        self.first_plan = annotation.make_plan(
            self.initial_state,
            self.first_overlap,
            self.first_transcript,
        )
        self.first_result = annotation.make_result(
            self.initial_state,
            self.first_plan,
            self.first_overlap,
            self.first_transcript,
            self.first_words,
            self.first_speakers,
        )
        self.second_state = annotation.apply_result(
            self.initial_state,
            self.first_plan,
            self.first_overlap,
            self.first_transcript,
            self.first_result,
        )
        self.second_plan = annotation.make_plan(
            self.second_state,
            self.second_overlap,
            self.second_transcript,
        )
        self.second_result = annotation.make_result(
            self.second_state,
            self.second_plan,
            self.second_overlap,
            self.second_transcript,
            self.second_words,
            self.second_speakers,
        )
        self.final_state = annotation.apply_result(
            self.second_state,
            self.second_plan,
            self.second_overlap,
            self.second_transcript,
            self.second_result,
        )

    def test_wires_reject_every_mutation(self) -> None:
        for encoded, decoder in (
            (
                annotation.encode_state(self.initial_state),
                annotation.decode_state,
            ),
            (
                annotation.encode_plan(self.first_plan),
                annotation.decode_plan,
            ),
            (
                annotation.encode_result(self.first_result),
                annotation.decode_result,
            ),
        ):
            self.assertEqual(decoder(encoded), decoder(encoded))
            for index in range(len(encoded)):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(annotation.SpeechAnnotationError):
                    decoder(bytes(mutated))

    def test_exact_words_and_speaker_turns_chain(self) -> None:
        self.assertEqual(
            self.initial_state["state_sha256"].hex(),
            "35343461c17a639e5c28d877d72a5fb4"
            "b14603bc8a4adcfab24a18747cbe5b9e",
        )
        self.assertEqual(
            self.first_plan["plan_sha256"].hex(),
            "2bd1094e8421818e4ad7f31643460fc0"
            "053a1c139873c473cedbcb20bf768987",
        )
        self.assertEqual(
            self.first_result["result_sha256"].hex(),
            "354403f1c299a2e665ec3727d32f9dcd"
            "79a40888483e456a2f9eaff4b5b1e2a3",
        )
        self.assertEqual(self.first_result["word_count"], 1)
        self.assertEqual(self.first_result["visible_speaker_turns_after"], 1)
        self.assertEqual(self.second_result["word_count"], 1)
        self.assertEqual(self.second_result["visible_speaker_turns_after"], 2)
        self.assertEqual(self.final_state["visible_annotations"], 2)
        self.assertEqual(self.final_state["visible_words"], 2)
        self.assertEqual(self.final_state["visible_speaker_turns"], 2)
        self.assertEqual(self.final_state["next_sample"], 18)
        self.assertEqual(
            self.final_state["last_speaker_sha256"],
            self.second_speakers[0],
        )

    def test_rehashed_substitutions_and_bad_timing_reject(self) -> None:
        foreign_plan = dict(self.first_plan)
        foreign_plan["transcript_sha256"] = model.sha256(
            b"foreign transcript"
        )
        foreign_plan["plan_sha256"] = annotation.plan_root(
            foreign_plan
        )
        annotation.validate_plan(foreign_plan)
        with self.assertRaises(annotation.SpeechAnnotationError):
            annotation.validate_plan_bindings(
                self.initial_state,
                foreign_plan,
                self.first_overlap,
                self.first_transcript,
            )
        with self.assertRaises(annotation.SpeechAnnotationError):
            annotation.make_result(
                self.initial_state,
                self.first_plan,
                self.first_overlap,
                self.first_transcript,
                ((0, 3, 2, 9, 0, 950_000),),
                self.first_speakers,
            )
        with self.assertRaises(annotation.SpeechAnnotationError):
            annotation.make_result(
                self.initial_state,
                self.first_plan,
                self.first_overlap,
                self.first_transcript,
                self.first_words,
                (
                    self.first_speakers[0],
                    self.first_speakers[0],
                ),
            )

    def test_multi_word_speaker_palette_is_first_occurrence_order(self) -> None:
        overlap = self.make_overlap(
            generation=1,
            segment_index=1,
            source_start=0,
            publish_start=2,
            publish_end=18,
            previous_transcript_sha256=self.first_overlap[
                "previous_transcript_sha256"
            ],
            challenge_sha256=self.challenge,
        )
        transcript = audio.make_transcript(overlap, b"ice berg")
        plan = annotation.make_plan(
            self.initial_state,
            overlap,
            transcript,
        )
        result = annotation.make_result(
            self.initial_state,
            plan,
            overlap,
            transcript,
            (
                (0, 3, 2, 10, 0, 950_000),
                (4, 4, 10, 18, 1, 925_000),
            ),
            (
                self.first_speakers[0],
                self.second_speakers[0],
            ),
        )
        self.assertEqual(result["word_count"], 2)
        self.assertEqual(result["speaker_count"], 2)
        self.assertEqual(result["visible_speaker_turns_after"], 2)
        with self.assertRaises(annotation.SpeechAnnotationError):
            annotation.make_result(
                self.initial_state,
                plan,
                overlap,
                transcript,
                (
                    (0, 3, 2, 10, 1, 950_000),
                    (4, 4, 10, 18, 0, 925_000),
                ),
                (
                    self.first_speakers[0],
                    self.second_speakers[0],
                ),
            )


if __name__ == "__main__":
    unittest.main()
