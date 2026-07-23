from __future__ import annotations

import unittest

from bench import generated_image_publication as image
from bench import media_contract as media
from bench import media_runtime_txn as resource
from bench import model_contract as model
from bench import stateful_model_adapter as stateful
from bench import stateful_model_continuation as continuation


class GeneratedImagePublicationTests(unittest.TestCase):
    def _make_latent_plan(
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
        initial_state_publication = stateful.initialize_publication(
            request_epoch=301,
            total_steps=2,
            state_bytes=4,
            artifact_sha256=self.artifact["artifact_sha256"],
            current_state_sha256=model.sha256(self.initial_state),
            challenge_sha256=self.challenge,
        )
        first_plan = self._make_latent_plan(
            initial_state_publication,
            publication_next_sequence=0,
            previous_plan_sha256=model.sha256(b"latent genesis plan"),
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
        first_transition = stateful.transition_root(
            initial_state_publication,
            first_plan,
            model.sha256(first_state),
            model.sha256(first_state),
            adapter_sha256,
        )
        initial_model_publication = {
            "request_epoch": 301,
            "next_sequence": 0,
            "visible_results": 0,
            "artifact_sha256": self.artifact["artifact_sha256"],
            "previous_result_sha256": bytes(32),
        }
        first_receipt = resource.resource_receipt(
            121_001,
            0,
            1,
            121_101,
            first_plan["claim"],
        )
        first_result = model.make_result(
            initial_model_publication,
            first_plan,
            first_receipt,
            output_sha256=model.sha256(first_state),
            source_mapping_sha256=first_transition,
            adapter_sha256=adapter_sha256,
        )
        intermediate_state_publication = dict(initial_state_publication)
        intermediate_state_publication.update(
            {
                "current_step": 1,
                "current_state_sha256": model.sha256(first_state),
                "previous_result_sha256": first_result["result_sha256"],
            }
        )
        intermediate_state_publication["publication_sha256"] = (
            stateful.publication_root(intermediate_state_publication)
        )
        intermediate_model_publication = {
            "request_epoch": 301,
            "next_sequence": 1,
            "visible_results": 1,
            "artifact_sha256": self.artifact["artifact_sha256"],
            "previous_result_sha256": first_result["result_sha256"],
        }
        self.checkpoint = continuation.make_checkpoint(
            source_bank_epoch=121_001,
            restore_plan={
                "restore_bank_epoch": 122_001,
                "restore_owner_key": 122_101,
                "restore_tree_key": 122_201,
                "restore_authority_key": 122_301,
                "tenant_key": 122_401,
                "scope_key": 122_501,
                "allocation_key": 122_601,
                "binding_key": 122_701,
            },
            model_publication=intermediate_model_publication,
            state_publication=intermediate_state_publication,
            last_result=first_result,
        )
        self.terminal_plan = self._make_latent_plan(
            intermediate_state_publication,
            publication_next_sequence=1,
            previous_plan_sha256=self.checkpoint["last_plan_sha256"],
        )
        self.terminal_latent = stateful.reference_latent_step(
            first_state,
            self.conditioning,
            self.weights,
        )
        terminal_transition = stateful.transition_root(
            intermediate_state_publication,
            self.terminal_plan,
            model.sha256(self.terminal_latent),
            model.sha256(self.terminal_latent),
            adapter_sha256,
        )
        terminal_receipt = resource.resource_receipt(
            122_001,
            1,
            2,
            123_001,
            self.terminal_plan["claim"],
        )
        self.terminal_result = model.make_result(
            intermediate_model_publication,
            self.terminal_plan,
            terminal_receipt,
            output_sha256=model.sha256(self.terminal_latent),
            source_mapping_sha256=terminal_transition,
            adapter_sha256=adapter_sha256,
        )
        self.terminal_state_publication = dict(
            intermediate_state_publication
        )
        self.terminal_state_publication.update(
            {
                "current_step": 2,
                "current_state_sha256": model.sha256(
                    self.terminal_latent
                ),
                "previous_result_sha256": self.terminal_result[
                    "result_sha256"
                ],
            }
        )
        self.terminal_state_publication["publication_sha256"] = (
            stateful.publication_root(self.terminal_state_publication)
        )
        self.pixels = image.reference_decode(self.terminal_latent)
        tenant_scope_sha256 = model.sha256(b"generated image tenant")
        metadata_policy_sha256 = model.sha256(
            b"generated image metadata policy"
        )
        source_provenance_sha256 = image.source_provenance_root(
            self.artifact,
            self.checkpoint,
            self.terminal_plan,
            self.terminal_result,
            self.terminal_state_publication,
            model.sha256(image.REFERENCE_DECODER_PAYLOAD),
            image.decoder_implementation_root(),
            tenant_scope_sha256,
            metadata_policy_sha256,
            self.challenge,
        )
        self.media_object = {
            "kind": media.IMAGE,
            "semantic_abi": image.RAW_IMAGE_SEMANTIC_ABI,
            "byte_length": len(self.pixels),
            "container_id": image.RAW_CONTAINER_ID,
            "codec_id": image.INTERLEAVED_U8_CODEC_ID,
            "axes": (2, 2, 1),
            "time_base": (0, 1),
            "tenant_scope_sha256": tenant_scope_sha256,
            "content_sha256": model.sha256(self.pixels),
            "metadata_policy_sha256": metadata_policy_sha256,
            "provenance_sha256": source_provenance_sha256,
        }
        media_root = media.media_object_sha256(
            media.encode_media_object(self.media_object)
        )
        self.publication_state = media.initialize_publication_state(
            301,
            1,
            (1, 1),
            media_root,
            model.sha256(b"generated image publication genesis"),
        )
        self.plan = image.make_plan(
            manifest=self.artifact,
            checkpoint=self.checkpoint,
            terminal_plan=self.terminal_plan,
            terminal_result=self.terminal_result,
            terminal_state_publication=self.terminal_state_publication,
            media_object=self.media_object,
            decoder_payload=image.REFERENCE_DECODER_PAYLOAD,
            publication_state=self.publication_state,
            previous_plan_sha256=model.sha256(
                b"generated image plan genesis"
            ),
            previous_result_sha256=model.sha256(
                b"generated image result genesis"
            ),
        )
        self.provenance = image.make_provenance(
            self.plan,
            model.sha256(self.pixels),
        )
        claim = image.claim_for_plan(
            self.plan,
            len(image.REFERENCE_DECODER_PAYLOAD),
        )
        self.image_receipt = resource.resource_receipt(
            122_001,
            0,
            3,
            124_001,
            claim,
        )
        self.result, self.state_after = image.make_result(
            plan_value=self.plan,
            provenance_value=self.provenance,
            media_object=self.media_object,
            receipt=self.image_receipt,
            publication_state_before=self.publication_state,
        )

    def test_wires_reject_every_mutation(self) -> None:
        for encoded, decoder in (
            (image.encode_plan(self.plan), image.decode_plan),
            (
                image.encode_provenance(self.provenance),
                image.decode_provenance,
            ),
            (image.encode_result(self.result), image.decode_result),
        ):
            self.assertEqual(decoder(encoded), decoder(encoded))
            for index in range(len(encoded)):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(
                    image.GeneratedImagePublicationError
                ):
                    decoder(bytes(mutated))

    def test_terminal_latent_publishes_exact_image_and_provenance(self) -> None:
        self.assertEqual(
            self.plan["plan_sha256"].hex(),
            "19c59a1a1cdcecb3f3159ea4ac920a19"
            "7261dd6070e69beb1aff81c15a6f6b02",
        )
        self.assertEqual(
            self.provenance["provenance_sha256"].hex(),
            "c61c2944db031743f420b675a768fa37"
            "0921388a01f331138f1b6da392f0516c",
        )
        self.assertEqual(
            self.result["result_sha256"].hex(),
            "3c45c797c20d2582af287d790ba759fe"
            "2bab615e2651c802e2bcbd4b381376e3",
        )
        self.assertEqual(
            self.terminal_latent,
            image.REFERENCE_TERMINAL_LATENT,
        )
        self.assertEqual(self.pixels, image.REFERENCE_PIXELS)
        self.assertEqual(
            self.provenance["output_sha256"],
            self.media_object["content_sha256"],
        )
        self.assertEqual(self.state_after["visible_chunks"], 1)
        self.assertEqual(self.state_after["visible_units"], 1)
        self.assertEqual(
            self.result["publication_state_before_sha256"],
            media.publication_state_root(self.publication_state),
        )
        self.assertEqual(
            self.result["publication_state_after_sha256"],
            media.publication_state_root(self.state_after),
        )

    def test_rehashed_terminal_substitution_rejects(self) -> None:
        foreign = dict(self.plan)
        foreign["terminal_output_sha256"] = model.sha256(
            b"foreign terminal latent"
        )
        foreign["plan_sha256"] = image.plan_root(foreign)
        image.validate_plan(foreign)
        with self.assertRaises(image.GeneratedImagePublicationError):
            image.validate_bindings(
                foreign,
                self.artifact,
                self.checkpoint,
                self.terminal_plan,
                self.terminal_result,
                self.terminal_state_publication,
                self.media_object,
                image.REFERENCE_DECODER_PAYLOAD,
                self.publication_state,
            )
        foreign_provenance = image.make_provenance(
            self.plan,
            model.sha256(b"foreign decoded pixels"),
        )
        image.validate_provenance(foreign_provenance)
        with self.assertRaises(image.GeneratedImagePublicationError):
            image.validate_provenance_bindings(
                self.plan,
                foreign_provenance,
                self.media_object,
            )


if __name__ == "__main__":
    unittest.main()
