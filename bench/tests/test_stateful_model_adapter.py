from __future__ import annotations

import unittest

from bench import model_contract as model
from bench import stateful_model_adapter as stateful


class StatefulModelAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.weights = bytes((2,))
        self.conditioning = bytes((1, 2, 3, 4))
        self.current_state = bytes((10, 20, 30, 40))
        self.challenge = model.sha256(b"latent step challenge")
        self.artifact = model.make_artifact(
            family=7,
            artifact_abi=0x4C4154454E540001,
            input_kind=6,
            output_kind=6,
            numerical_policy=model.EXACT_INTEGER,
            max_batch_items=1,
            input_features=4,
            output_dimensions=4,
            input_element_bytes=1,
            output_element_bytes=1,
            weight_element_bytes=1,
            weights=self.weights,
            metadata_sha256=model.sha256(
                b"latent step fixture metadata"
            ),
            license_sha256=model.sha256(b"fixture-only license"),
        )
        self.publication = stateful.initialize_publication(
            request_epoch=301,
            total_steps=2,
            state_bytes=4,
            artifact_sha256=self.artifact["artifact_sha256"],
            current_state_sha256=model.sha256(self.current_state),
            challenge_sha256=self.challenge,
        )
        self.plan = model.make_plan(
            self.artifact,
            operation=8,
            request_epoch=301,
            generation=1,
            batch_items=1,
            publication_next_sequence=0,
            maximum_absolute_output=255,
            required_capabilities=0,
            scratch_bytes=4,
            claim={
                "capsule_bytes": 1,
                "kv_bytes": 0,
                "activation_bytes": 4,
                "partial_bytes": 4,
                "logits_bytes": 0,
                "output_journal_bytes": 8,
                "staging_bytes": 4,
                "device_bytes": 0,
                "io_bytes": 0,
                "queue_slots": 1,
            },
            digests={
                "media_object_sha256": model.sha256(
                    b"latent target image"
                ),
                "processor_state_sha256": self.publication[
                    "publication_sha256"
                ],
                "processor_bundle_sha256": model.sha256(
                    b"latent scheduler bundle"
                ),
                "cache_bundle_sha256": model.sha256(
                    b"latent cache bundle"
                ),
                "cache_payload_sha256": self.publication[
                    "current_state_sha256"
                ],
                "ownership_sha256": model.sha256(
                    b"latent state ownership"
                ),
                "challenge_sha256": self.challenge,
                "previous_plan_sha256": model.sha256(
                    b"latent genesis plan"
                ),
                "input_schema_sha256": model.sha256(
                    b"four u8 conditioning deltas"
                ),
                "output_schema_sha256": model.sha256(
                    b"four u8 next latent"
                ),
            },
        )
        self.adapter_sha256 = stateful.adapter_descriptor_root(
            adapter_abi=0x474C415400000001,
            family=7,
            operation=8,
            input_kind=6,
            output_kind=6,
            numerical_policy=model.EXACT_INTEGER,
            max_batch_items=1,
            max_input_features=4,
            max_output_dimensions=4,
            allowed_capabilities=0,
            implementation_sha256=model.sha256(
                b"reference exact latent denoise v1"
            ),
        )

    def test_state_wire_and_transition_golden(self) -> None:
        encoded = stateful.encode_publication(self.publication)
        self.assertEqual(
            stateful.decode_publication(encoded),
            self.publication,
        )
        self.assertEqual(
            self.publication["publication_sha256"].hex(),
            "7f337b3f2ff044d1222f42da227b7a98"
            "1c25661019ba91b76ec30a53fcc304d2",
        )
        candidate = stateful.reference_latent_step(
            self.current_state,
            self.conditioning,
            self.weights,
        )
        self.assertEqual(candidate, bytes((8, 16, 24, 32)))
        transition = stateful.transition_root(
            self.publication,
            self.plan,
            model.sha256(candidate),
            model.sha256(candidate),
            self.adapter_sha256,
        )
        self.assertEqual(
            transition.hex(),
            "efb7f3d05dc3c396756fcd53f38b8118"
            "ca286bff150733a6eb06b3dc0636a4db",
        )

    def test_mutation_and_foreign_lineage_reject(self) -> None:
        encoded = stateful.encode_publication(self.publication)
        for index in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[index] ^= 1
            with self.assertRaises(stateful.StatefulModelAdapterError):
                stateful.decode_publication(bytes(mutated))
        foreign = dict(self.publication)
        foreign["current_state_sha256"] = model.sha256(
            b"foreign latent"
        )
        with self.assertRaises(stateful.StatefulModelAdapterError):
            stateful.validate_publication(foreign)


if __name__ == "__main__":
    unittest.main()
