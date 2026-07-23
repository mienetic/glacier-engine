from __future__ import annotations

import struct
import unittest

from bench import media_contract as media
from bench import media_processor_state as processor
from bench import model_contract as contract


class AudioWindowAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.weights = struct.pack("<hhhh", 1, 2, -1, 3)
        self.features = struct.pack("<hhhh", 100, 200, -300, 400)
        self.challenge = contract.sha256(b"audio challenge")
        self.audio_state = processor.make_audio_state(
            {
                "kind": media.AUDIO,
                "request_epoch": 121,
                "generation": 4,
                "stream_key": 31_002,
                "timeline_numerator": 1,
                "timeline_denominator": 16_000,
                "media_object_sha256": contract.sha256(b"audio media"),
                "processor_plan_sha256": contract.sha256(
                    b"audio processor"
                ),
                "previous_state_sha256": contract.sha256(
                    b"previous audio state"
                ),
                "challenge_sha256": self.challenge,
                "cache_content_sha256": contract.sha256(self.features),
                "output_chain_sha256": contract.sha256(b"audio output"),
                "ownership_receipt_sha256": contract.sha256(
                    b"audio ownership"
                ),
                "decoder_state_sha256": contract.sha256(b"audio decoder"),
            },
            2,
            16_000,
            1,
            4,
            4,
            2,
            2,
        )
        self.artifact = contract.make_artifact(
            family=4,
            artifact_abi=0x415544494F000001,
            input_kind=4,
            output_kind=contract.EMBEDDING_I32,
            numerical_policy=contract.EXACT_INTEGER,
            max_batch_items=2,
            input_features=2,
            output_dimensions=2,
            input_element_bytes=2,
            output_element_bytes=4,
            weight_element_bytes=2,
            weights=self.weights,
            metadata_sha256=contract.sha256(
                b"audio fixture metadata"
            ),
            license_sha256=contract.sha256(b"fixture-only license"),
        )
        self.plan = contract.make_plan(
            self.artifact,
            operation=contract.ENCODE,
            request_epoch=121,
            generation=4,
            batch_items=2,
            publication_next_sequence=0,
            maximum_absolute_output=10_000,
            required_capabilities=0,
            scratch_bytes=16,
            claim={
                "capsule_bytes": 8,
                "kv_bytes": 0,
                "activation_bytes": 8,
                "partial_bytes": 16,
                "logits_bytes": 0,
                "output_journal_bytes": 16,
                "staging_bytes": 0,
                "device_bytes": 0,
                "io_bytes": 0,
                "queue_slots": 1,
            },
            digests={
                "media_object_sha256": self.audio_state[
                    "media_object_sha256"
                ],
                "processor_state_sha256": self.audio_state[
                    "state_sha256"
                ],
                "processor_bundle_sha256": contract.sha256(
                    b"processor bundle"
                ),
                "cache_bundle_sha256": contract.sha256(b"cache bundle"),
                "cache_payload_sha256": self.audio_state[
                    "cache_content_sha256"
                ],
                "ownership_sha256": self.audio_state[
                    "ownership_receipt_sha256"
                ],
                "challenge_sha256": self.challenge,
                "previous_plan_sha256": contract.sha256(
                    b"previous audio plan"
                ),
                "input_schema_sha256": contract.sha256(
                    b"two windows by two i16 bins"
                ),
                "output_schema_sha256": contract.sha256(
                    b"two windows by two i32 embedding"
                ),
            },
        )

    def test_exact_projection_and_source_mapping(self) -> None:
        output = contract.reference_i16_projection(
            self.plan,
            self.weights,
            self.features,
        )
        self.assertEqual(
            struct.unpack("<iiii", output),
            (500, 500, 500, 1500),
        )
        mapping = contract.audio_source_mapping_root(
            self.plan,
            self.audio_state,
        )
        self.assertEqual(
            mapping.hex(),
            "b65fce1e3bd5486b480cd700b7e8b586"
            "ebd6f0d14a65ab172af4d7a4c9e6cedd",
        )

    def test_foreign_state_and_candidate_bound_reject(self) -> None:
        foreign = dict(self.audio_state)
        foreign["cursor_units"] += 1
        with self.assertRaises(contract.ModelContractError):
            contract.audio_source_mapping_root(self.plan, foreign)
        bounded = dict(self.plan)
        bounded["maximum_absolute_output"] = 499
        with self.assertRaises(contract.ModelContractError):
            contract.reference_i16_projection(
                bounded,
                self.weights,
                self.features,
            )


if __name__ == "__main__":
    unittest.main()
