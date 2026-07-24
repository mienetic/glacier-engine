from __future__ import annotations

import copy
import hashlib
import unittest

from bench import generated_audio_playback as audio
from bench import generated_image_publication as image
from bench import generated_media_output_registry as registry
from bench import generated_media_producer_transition as transition
from bench import model_contract as model


def _reseal_evidence(
    header: transition.Record,
    receipts: list[transition.Record],
) -> bytes:
    receipt_table = b"".join(
        transition.encode_transition_receipt(receipt) for receipt in receipts
    )
    terminals = {modality: None for modality in registry.MODALITIES}
    for receipt in receipts:
        terminals[receipt["modality"]] = receipt
    resealed = {
        **header,
        "receipt_count": len(receipts),
        "receipt_table_bytes": len(receipt_table),
        "receipt_table_sha256": transition.receipt_table_root(receipt_table),
        "first_receipt_sha256": receipts[0]["transition_receipt_sha256"],
        "terminal_image_receipt_sha256": (
            transition.ZERO
            if terminals[registry.IMAGE_MODALITY] is None
            else terminals[registry.IMAGE_MODALITY]["transition_receipt_sha256"]
        ),
        "terminal_audio_receipt_sha256": (
            transition.ZERO
            if terminals[registry.AUDIO_MODALITY] is None
            else terminals[registry.AUDIO_MODALITY]["transition_receipt_sha256"]
        ),
        "terminal_video_receipt_sha256": (
            transition.ZERO
            if terminals[registry.VIDEO_MODALITY] is None
            else terminals[registry.VIDEO_MODALITY]["transition_receipt_sha256"]
        ),
        "batch_sha256": transition.ZERO,
    }
    resealed["batch_sha256"] = transition.batch_root(resealed)
    return transition.encode_batch_header(resealed) + receipt_table


def _rehashed_receipt_digest_contradiction(
    receipt: transition.Record,
    field: str,
) -> bytes:
    raw = bytearray(transition.encode_transition_receipt(receipt))
    index = transition.TRANSITION_DIGESTS.index(field)
    start = 256 + index * 32
    raw[start : start + 32] = model.sha256(b"foreign " + field.encode("ascii"))
    raw[1696:1728] = hashlib.sha256(
        transition.TRANSITION_RECEIPT_DOMAIN + raw[:1696]
    ).digest()
    return bytes(raw)


class GeneratedMediaProducerTransitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = transition.reference_inputs()
        cls.batches = transition.reference_batches()
        cls.maximum_fixture = transition.maximum_reference_inputs()
        cls.maximum_batches = transition.maximum_reference_batches()

    def test_golden_roots_and_two_generation_lineage(self) -> None:
        first = self.batches["first"]
        second = self.batches["second"]
        expected = {
            "first_batch": (
                first["header"]["batch_sha256"],
                "378f2f3bd09244959394bdcc57002561796b852950cdaf20a9704ac69a9c4a04",
            ),
            "first_registry": (
                first["registry"]["archive_sha256"],
                "9d2e61b94d8ab277e9b791e743d7021a89056cbd4e2d315beadad90bfd690451",
            ),
            "second_batch": (
                second["header"]["batch_sha256"],
                "eb61927cf2de6bb3ffa3749c632de86e8d3cffe2e19d3b88a9014570f9b81a9a",
            ),
            "second_registry": (
                second["registry"]["archive_sha256"],
                "01daaf273535e7aa3a40dc87e771aeeaacd5408bcc54bcb9d5904ff7eaf80374",
            ),
        }
        for label, (actual, expected_hex) in expected.items():
            with self.subTest(label=label):
                self.assertEqual(actual.hex(), expected_hex)

        self.assertEqual(
            len(first["evidence_bytes"]),
            transition.BATCH_BYTES + 4 * transition.TRANSITION_RECEIPT_BYTES,
        )
        self.assertEqual(
            len(second["evidence_bytes"]),
            transition.BATCH_BYTES + 3 * transition.TRANSITION_RECEIPT_BYTES,
        )
        self.assertEqual(
            second["header"]["previous_batch_sha256"],
            first["header"]["batch_sha256"],
        )
        self.assertEqual(
            second["registry"]["manifest"]["previous_archive_sha256"],
            first["registry"]["archive_sha256"],
        )
        self.assertEqual(
            transition.decode_batch(
                first["evidence_bytes"],
                first["registry"]["archive_bytes"],
                None,
            )["header"],
            first["header"],
        )
        self.assertEqual(
            transition.decode_batch(
                second["evidence_bytes"],
                second["registry"]["archive_bytes"],
                first,
            )["header"],
            second["header"],
        )

    def test_maximum_entry_generations_are_exact_and_lineage_bound(self) -> None:
        first = self.maximum_batches["first"]
        second = self.maximum_batches["second"]
        expected_roots = {
            "first_batch": (
                first["header"]["batch_sha256"],
                "b0f1b0fca6f858236593d06588bc9b8fd8ff2907eefea43be6ed1f16b9c13942",
            ),
            "first_registry": (
                first["registry"]["archive_sha256"],
                "132c566ebef9d879b7db1f46c096ac3ec7eabfbf3d5e107b8451810dc5987dc0",
            ),
            "second_batch": (
                second["header"]["batch_sha256"],
                "6a881b8ab70c36aff4369f01a81a9ce0282e882f83bceeaf8f10376ac35c7fb6",
            ),
            "second_registry": (
                second["registry"]["archive_sha256"],
                "d37d1654a9829e7117b52cced06c723fe6c61f1403be2ce8271771304e34b2e8",
            ),
        }
        for label, (actual, expected_hex) in expected_roots.items():
            with self.subTest(root=label):
                self.assertEqual(actual.hex(), expected_hex)

        previous_terminals = {
            modality: transition.ZERO for modality in registry.MODALITIES
        }
        for generation, batch in enumerate((first, second), start=1):
            with self.subTest(generation=generation):
                self.assertEqual(
                    batch["header"]["receipt_count"],
                    registry.MAX_ENTRIES,
                )
                self.assertEqual(
                    batch["registry"]["manifest"]["entry_count"],
                    registry.MAX_ENTRIES,
                )
                self.assertEqual(
                    len(batch["evidence_bytes"]),
                    transition.BATCH_BYTES
                    + registry.MAX_ENTRIES * transition.TRANSITION_RECEIPT_BYTES,
                )
                self.assertEqual(
                    (
                        batch["registry"]["manifest"]["image_count"],
                        batch["registry"]["manifest"]["audio_count"],
                        batch["registry"]["manifest"]["video_count"],
                    ),
                    (4, 4, 4),
                )
                self.assertEqual(batch["header"]["modality_mask"], 0x7)
                self.assertEqual(batch["header"]["total_raw_output_bytes"], 64)
                self.assertEqual(
                    batch["header"]["total_encoded_payload_bytes"],
                    484,
                )

                for modality_index, modality in enumerate(registry.MODALITIES):
                    start = modality_index * registry.MAX_ENTRIES_PER_MODALITY
                    receipts = batch["receipts"][
                        start : start + registry.MAX_ENTRIES_PER_MODALITY
                    ]
                    expected_ordinals = range(
                        (generation - 1) * registry.MAX_ENTRIES_PER_MODALITY,
                        generation * registry.MAX_ENTRIES_PER_MODALITY,
                    )
                    self.assertEqual(
                        [receipt["modality"] for receipt in receipts],
                        [modality] * registry.MAX_ENTRIES_PER_MODALITY,
                    )
                    self.assertEqual(
                        [receipt["registry_ordinal"] for receipt in receipts],
                        list(expected_ordinals),
                    )
                    predecessor = previous_terminals[modality]
                    for receipt in receipts:
                        self.assertEqual(
                            receipt["previous_transition_receipt_sha256"],
                            predecessor,
                        )
                        predecessor = receipt["transition_receipt_sha256"]
                    previous_terminals[modality] = predecessor

                self.assertEqual(
                    batch["header"]["terminal_image_receipt_sha256"],
                    batch["receipts"][3]["transition_receipt_sha256"],
                )
                self.assertEqual(
                    batch["header"]["terminal_audio_receipt_sha256"],
                    batch["receipts"][7]["transition_receipt_sha256"],
                )
                self.assertEqual(
                    batch["header"]["terminal_video_receipt_sha256"],
                    batch["receipts"][11]["transition_receipt_sha256"],
                )
                self.assertEqual(
                    transition.decode_batch(
                        batch["evidence_bytes"],
                        batch["registry"]["archive_bytes"],
                        None if generation == 1 else first,
                    )["header"],
                    batch["header"],
                )

        self.assertEqual(
            second["header"]["previous_batch_sha256"],
            first["header"]["batch_sha256"],
        )
        self.assertEqual(
            second["registry"]["manifest"]["previous_archive_sha256"],
            first["registry"]["archive_sha256"],
        )

    def test_maximum_entry_fixture_rejects_thirteenth_and_fifth_image(
        self,
    ) -> None:
        thirteen = self.maximum_fixture["batch1"] + [self.maximum_fixture["batch2"][0]]
        five_images = self.maximum_fixture["batch1"][
            : registry.MAX_ENTRIES_PER_MODALITY
        ] + [self.maximum_fixture["batch2"][0]]
        for label, witnesses in (
            ("thirteenth", thirteen),
            ("fifth-image", five_images),
        ):
            with self.subTest(label=label):
                with self.assertRaises(
                    transition.GeneratedMediaProducerTransitionError
                ):
                    transition.verify_and_encode_batch(
                        None,
                        self.maximum_fixture["generation_plan1_sha256"],
                        witnesses,
                    )

    def test_every_fixed_wire_byte_is_authenticated(self) -> None:
        first_witness = self.fixture["batch1"][0]
        fixed_wires = (
            (
                first_witness["model"]["publication_before_wire"],
                transition.decode_model_publication,
            ),
            (
                first_witness["model"]["adapter_descriptor_wire"],
                transition.decode_adapter_descriptor,
            ),
            (
                first_witness["producer"]["publication_before_wire"],
                transition.decode_media_publication,
            ),
            (
                first_witness["producer"]["resource_receipt_wire"],
                transition.decode_resource_receipt,
            ),
            (
                self.batches["first"]["receipt_table"][
                    : transition.TRANSITION_RECEIPT_BYTES
                ],
                transition.decode_transition_receipt,
            ),
            (
                self.batches["first"]["evidence_bytes"][: transition.BATCH_BYTES],
                transition.decode_batch_header,
            ),
        )
        for wire, decoder in fixed_wires:
            decoder(wire)
            for index in range(len(wire)):
                with self.subTest(
                    bytes=len(wire),
                    index=index,
                ):
                    mutated = bytearray(wire)
                    mutated[index] ^= 1
                    with self.assertRaises(
                        transition.GeneratedMediaProducerTransitionError
                    ):
                        decoder(bytes(mutated))

    def test_image_publications_are_local_but_collection_ordinals_advance(
        self,
    ) -> None:
        images = self.batches["first"]["receipts"][:2]
        self.assertEqual(
            [(item["producer_ordinal"], item["registry_ordinal"]) for item in images],
            [(1, 0), (1, 1)],
        )
        self.assertEqual(
            [(item["unit_start"], item["timeline_start"]) for item in images],
            [(0, 0), (1, 1)],
        )
        self.assertNotEqual(
            images[0]["producer_state_before_sha256"],
            images[1]["producer_state_before_sha256"],
        )
        self.assertEqual(
            images[1]["previous_transition_receipt_sha256"],
            images[0]["transition_receipt_sha256"],
        )
        for witness in self.fixture["batch1"][:2]:
            plan = image.decode_plan(witness["producer"]["plan_wire"])
            self.assertEqual(plan["image_index"], 1)
            self.assertEqual(plan["visible_images_before"], 0)
            self.assertEqual(plan["visible_images_after"], 1)

    def test_actual_model_and_materializer_substitutions_fail(self) -> None:
        altered = copy.deepcopy(self.fixture["batch1"])
        altered[2]["model"]["output"] = bytes((130, 127))
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )

        altered = copy.deepcopy(self.fixture["batch1"])
        altered[0]["producer"]["raw_output"] = bytes((1, 2, 3, 4))
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )

    def test_rehashed_semantic_contradictions_fail(self) -> None:
        altered = copy.deepcopy(self.fixture["batch1"])
        producer_plan = image.decode_plan(altered[0]["producer"]["plan_wire"])
        producer_plan["terminal_output_sha256"] = model.sha256(
            b"foreign terminal latent"
        )
        producer_plan["plan_sha256"] = image.plan_root(producer_plan)
        altered[0]["producer"]["plan_wire"] = image.encode_plan(producer_plan)
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )

        altered = copy.deepcopy(self.fixture["batch1"])
        observation = audio.decode_observation(
            altered[2]["producer"]["observation_wire"]
        )
        observation["sink_instance_sha256"] = model.sha256(b"foreign audio sink")
        observation["observation_sha256"] = audio._root(
            audio.OBSERVATION_DOMAIN,
            audio._observation_body(observation),
        )
        altered[2]["producer"]["observation_wire"] = audio.encode_observation(
            observation
        )
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )

        altered = copy.deepcopy(self.fixture["batch1"])
        result = model.decode_result(altered[2]["model"]["result_wire"])
        result["source_mapping_sha256"] = model.sha256(b"foreign model mapping")
        result["publication_commit_sha256"] = model.publication_commit_root(result)
        result["result_sha256"] = model.ZERO_DIGEST
        altered[2]["model"]["result_wire"] = model.encode_result(result)
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )

    def test_rehashed_receipt_registry_contradiction_fails(self) -> None:
        first = self.batches["first"]
        receipts = copy.deepcopy(first["receipts"])
        receipts[1]["registry_ordinal"] = 2
        receipts[1]["unit_start"] = 2
        receipts[1]["timeline_start"] = 2
        receipts[1]["timeline_end"] = 3
        receipts[1]["producer_projection_sha256"] = (
            transition._producer_projection_root_from_receipt(receipts[1])
        )
        receipts[1]["transition_receipt_sha256"] = transition.transition_receipt_root(
            receipts[1]
        )
        evidence = _reseal_evidence(first["header"], receipts)
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.decode_batch(
                evidence,
                first["registry"]["archive_bytes"],
                None,
            )

    def test_rehashed_derived_receipt_roots_fail(self) -> None:
        receipt = self.batches["first"]["receipts"][2]
        for field in (
            "materializer_execution_sha256",
            "producer_projection_sha256",
        ):
            with self.subTest(field=field):
                raw = _rehashed_receipt_digest_contradiction(
                    receipt,
                    field,
                )
                with self.assertRaises(
                    transition.GeneratedMediaProducerTransitionError
                ):
                    transition.decode_transition_receipt(raw)

    def test_rehashed_noncanonical_receipt_order_fails(self) -> None:
        first = self.batches["first"]
        receipts = copy.deepcopy(first["receipts"])
        receipts[0], receipts[1] = receipts[1], receipts[0]
        evidence = _reseal_evidence(first["header"], receipts)
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.decode_batch(
                evidence,
                first["registry"]["archive_bytes"],
                None,
            )

    def test_prior_evidence_substitution_fails(self) -> None:
        foreign_first = transition.verify_and_encode_batch(
            None,
            model.sha256(b"foreign generation plan"),
            self.fixture["batch1"],
        )
        second = self.batches["second"]
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.decode_batch(
                second["evidence_bytes"],
                second["registry"]["archive_bytes"],
                foreign_first,
            )
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.decode_batch(
                second["evidence_bytes"],
                second["registry"]["archive_bytes"],
                None,
            )

    def test_canonical_foreign_producer_lineage_fails(self) -> None:
        first_audio_plan = audio.decode_plan(
            self.fixture["batch1"][2]["producer"]["plan_wire"]
        )
        foreign_first, foreign_model, foreign_state = transition._audio_output_fixture(
            label=b"foreign-audio-one",
            request_epoch=first_audio_plan["request_epoch"],
            tenant_scope_sha256=first_audio_plan["tenant_scope_sha256"],
            metadata_policy_sha256=first_audio_plan["metadata_policy_sha256"],
            challenge_sha256=first_audio_plan["challenge_sha256"],
            model_input=bytes((140, 120)),
            previous_model=None,
            state_before=None,
        )
        self.assertEqual(
            audio.decode_plan(foreign_first["producer"]["plan_wire"])["chunk_index"],
            0,
        )
        foreign_second, _, _ = transition._audio_output_fixture(
            label=b"foreign-audio-two",
            request_epoch=first_audio_plan["request_epoch"],
            tenant_scope_sha256=first_audio_plan["tenant_scope_sha256"],
            metadata_policy_sha256=first_audio_plan["metadata_policy_sha256"],
            challenge_sha256=first_audio_plan["challenge_sha256"],
            model_input=bytes((130, 126)),
            previous_model=foreign_model,
            state_before=foreign_state,
        )
        altered = copy.deepcopy(self.fixture["batch2"])
        altered[1] = foreign_second
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                self.batches["first"],
                self.fixture["generation_plan2_sha256"],
                altered,
            )

    def test_sizes_order_and_caps_fail_closed(self) -> None:
        first = self.batches["first"]
        for evidence in (
            first["evidence_bytes"][:-1],
            first["evidence_bytes"] + b"\x00",
        ):
            with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
                transition.decode_batch(
                    evidence,
                    first["registry"]["archive_bytes"],
                    None,
                )

        noncanonical = copy.deepcopy(self.fixture["batch1"])
        noncanonical[0], noncanonical[2] = (
            noncanonical[2],
            noncanonical[0],
        )
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                noncanonical,
            )
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                self.fixture["batch1"] * 4,
            )
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                [self.fixture["batch1"][0]] * 5,
            )

    def test_support_set_order_and_resource_integrity_fail(self) -> None:
        altered = copy.deepcopy(self.fixture["batch1"])
        support = altered[2]["model"]["support_records"][0]
        foreign = {**support, "max_batch_items": 2}
        altered[2]["model"]["support_records"] = [foreign, support]
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )

        altered = copy.deepcopy(self.fixture["batch1"])
        receipt = bytearray(altered[2]["producer"]["resource_receipt_wire"])
        receipt[144] ^= 1
        receipt[160:] = transition._root(
            transition.RESOURCE_RECEIPT_DOMAIN,
            bytes(receipt[:160]),
        )
        altered[2]["producer"]["resource_receipt_wire"] = bytes(receipt)
        with self.assertRaises(transition.GeneratedMediaProducerTransitionError):
            transition.verify_and_encode_batch(
                None,
                self.fixture["generation_plan1_sha256"],
                altered,
            )


if __name__ == "__main__":
    unittest.main()
