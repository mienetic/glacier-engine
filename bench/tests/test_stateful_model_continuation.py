from __future__ import annotations

import unittest

from bench import media_runtime_txn as resource
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as continuation


class StatefulModelContinuationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.weights = bytes((2,))
        self.conditioning = bytes((1, 2, 3, 4))
        self.initial_state = bytes((10, 20, 30, 40))
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
        initial_publication = stateful.initialize_publication(
            request_epoch=301,
            total_steps=2,
            state_bytes=4,
            artifact_sha256=self.artifact["artifact_sha256"],
            current_state_sha256=model.sha256(self.initial_state),
            challenge_sha256=self.challenge,
        )
        self.first_plan = self._make_plan(
            initial_publication,
            publication_next_sequence=0,
            previous_plan_sha256=model.sha256(
                b"latent genesis plan"
            ),
        )
        adapter_sha256 = stateful.adapter_descriptor_root(
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
        first_state = stateful.reference_latent_step(
            self.initial_state,
            self.conditioning,
            self.weights,
        )
        transition = stateful.transition_root(
            initial_publication,
            self.first_plan,
            model.sha256(first_state),
            model.sha256(first_state),
            adapter_sha256,
        )
        publication_before = {
            "request_epoch": 301,
            "next_sequence": 0,
            "visible_results": 0,
            "artifact_sha256": self.artifact["artifact_sha256"],
            "previous_result_sha256": bytes(32),
        }
        receipt = resource.resource_receipt(
            81_001,
            0,
            1,
            81_101,
            self.first_plan["claim"],
        )
        first_result = model.make_result(
            publication_before,
            self.first_plan,
            receipt,
            output_sha256=model.sha256(first_state),
            source_mapping_sha256=transition,
            adapter_sha256=adapter_sha256,
        )
        self.state_publication = dict(initial_publication)
        self.state_publication.update(
            {
                "current_step": 1,
                "current_state_sha256": model.sha256(first_state),
                "previous_result_sha256": first_result["result_sha256"],
            }
        )
        self.state_publication["publication_sha256"] = (
            stateful.publication_root(self.state_publication)
        )
        self.model_publication = {
            "request_epoch": 301,
            "next_sequence": 1,
            "visible_results": 1,
            "artifact_sha256": self.artifact["artifact_sha256"],
            "previous_result_sha256": first_result["result_sha256"],
        }
        self.checkpoint = continuation.make_checkpoint(
            source_bank_epoch=81_001,
            restore_plan={
                "restore_bank_epoch": 82_001,
                "restore_owner_key": 82_101,
                "restore_tree_key": 82_201,
                "restore_authority_key": 82_301,
                "tenant_key": 82_401,
                "scope_key": 82_501,
                "allocation_key": 82_601,
                "binding_key": 82_701,
            },
            model_publication=self.model_publication,
            state_publication=self.state_publication,
            last_result=first_result,
        )
        self.first_state = first_state

    def _make_plan(
        self,
        state_publication: dict[str, object],
        *,
        publication_next_sequence: int,
        previous_plan_sha256: bytes,
    ) -> dict[str, object]:
        return model.make_plan(
            self.artifact,
            operation=8,
            request_epoch=301,
            generation=int(state_publication["current_step"]) + 1,
            batch_items=1,
            publication_next_sequence=publication_next_sequence,
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
                "processor_state_sha256": state_publication[
                    "publication_sha256"
                ],
                "processor_bundle_sha256": model.sha256(
                    b"latent scheduler bundle"
                ),
                "cache_bundle_sha256": model.sha256(
                    b"latent cache bundle"
                ),
                "cache_payload_sha256": state_publication[
                    "current_state_sha256"
                ],
                "ownership_sha256": model.sha256(
                    b"latent state ownership"
                ),
                "challenge_sha256": self.challenge,
                "previous_plan_sha256": previous_plan_sha256,
                "input_schema_sha256": model.sha256(
                    b"four u8 conditioning deltas"
                ),
                "output_schema_sha256": model.sha256(
                    b"four u8 next latent"
                ),
            },
        )

    def test_checkpoint_wire_mutation_and_golden(self) -> None:
        encoded = continuation.encode_checkpoint(self.checkpoint)
        self.assertEqual(
            continuation.decode_checkpoint(encoded),
            self.checkpoint,
        )
        self.assertEqual(
            self.checkpoint["checkpoint_sha256"].hex(),
            "e7c583987b17c0d13498e59a965b2106"
            "18ceb364f94acd541f0f7b44e6a4625d",
        )
        for index in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[index] ^= 1
            with self.assertRaises(
                continuation.StatefulModelContinuationError
            ):
                continuation.decode_checkpoint(bytes(mutated))

    def test_restore_lineage_builds_only_terminal_plan(self) -> None:
        restored = continuation.reconstruct_model_publication(
            self.checkpoint,
            self.state_publication,
        )
        self.assertEqual(restored, self.model_publication)
        second_plan = self._make_plan(
            self.state_publication,
            publication_next_sequence=restored["next_sequence"],
            previous_plan_sha256=self.checkpoint["last_plan_sha256"],
        )
        self.assertEqual(second_plan["generation"], 2)
        self.assertEqual(second_plan["publication_next_sequence"], 1)
        self.assertEqual(
            second_plan["previous_plan_sha256"],
            self.first_plan["plan_sha256"],
        )
        self.assertEqual(
            stateful.reference_latent_step(
                self.first_state,
                self.conditioning,
                self.weights,
            ),
            bytes((6, 12, 18, 24)),
        )
        foreign = dict(self.state_publication)
        foreign["current_state_sha256"] = model.sha256(
            b"foreign intermediate state"
        )
        foreign["publication_sha256"] = stateful.publication_root(
            foreign
        )
        with self.assertRaises(
            continuation.StatefulModelContinuationError
        ):
            continuation.reconstruct_model_publication(
                self.checkpoint,
                foreign,
            )


if __name__ == "__main__":
    unittest.main()
