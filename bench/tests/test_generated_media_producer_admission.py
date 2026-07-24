from __future__ import annotations

import copy
import unittest

from bench import generated_audio_playback as audio
from bench import generated_image_publication as image
from bench import generated_media_output_registry as registry
from bench import generated_media_producer_admission as admission
from bench import generated_video_display as video


ADMITTERS = {
    registry.IMAGE_MODALITY: admission.admit_image,
    registry.AUDIO_MODALITY: admission.admit_audio,
    registry.VIDEO_MODALITY: admission.admit_video,
}
WIRE_FIELDS = {
    registry.IMAGE_MODALITY: (
        "plan_wire",
        "provenance_wire",
        "result_wire",
    ),
    registry.AUDIO_MODALITY: (
        "state_wire",
        "plan_wire",
        "provenance_wire",
        "result_wire",
        "ack_result_wire",
    ),
    registry.VIDEO_MODALITY: (
        "state_wire",
        "manifest_wire",
        "provenance_wire",
        "result_wire",
        "ack_result_wire",
    ),
}


def _common_from_image(producer: admission.Record) -> admission.Record:
    plan = image.decode_plan(producer["plan_wire"])
    return {
        "request_epoch": plan["request_epoch"],
        "tenant_scope_sha256": plan["tenant_scope_sha256"],
        "metadata_policy_sha256": plan["metadata_policy_sha256"],
        "challenge_sha256": plan["challenge_sha256"],
    }


def _reseal_audio_records(
    state: admission.Record,
    plan: admission.Record,
    provenance: admission.Record,
    result: admission.Record,
    acknowledgement: admission.Record,
) -> tuple[
    admission.Record,
    admission.Record,
    admission.Record,
    admission.Record,
    admission.Record,
]:
    before = {
        **state,
        "generation": result["generation"] - 1,
        "next_chunk_index": result["chunk_index"],
        "next_start_frame": result["start_frame"],
        "visible_chunks": result["visible_chunks_before"],
        "visible_frames": result["visible_frames_before"],
        "acknowledged_chunks": result["visible_chunks_before"],
        "acknowledged_frames": result["visible_frames_before"],
        "playback_sequence": result["chunk_index"],
        "pending": 0,
        "pending_chunk_index": 0,
        "pending_start_frame": 0,
        "pending_frame_count": 0,
        "previous_publication_result_sha256": result[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": acknowledgement["previous_ack_result_sha256"],
        "pending_publication_result_sha256": registry.ZERO,
        "pending_output_sha256": registry.ZERO,
        "state_sha256": registry.ZERO,
    }
    before["state_sha256"] = audio._root(
        audio.STATE_DOMAIN,
        audio._state_body(before),
    )
    audio.validate_state(before)

    plan["state_before_sha256"] = before["state_sha256"]
    plan["plan_sha256"] = audio._root(
        audio.PLAN_DOMAIN,
        audio._plan_body(plan),
    )
    provenance["plan_sha256"] = plan["plan_sha256"]
    provenance["provenance_sha256"] = audio._root(
        audio.PROVENANCE_DOMAIN,
        audio._provenance_body(provenance),
    )
    result["plan_sha256"] = plan["plan_sha256"]
    result["provenance_sha256"] = provenance["provenance_sha256"]
    result["state_before_sha256"] = before["state_sha256"]
    result["result_sha256"] = audio._root(
        audio.RESULT_DOMAIN,
        audio._result_body(result),
    )

    pending = {
        **state,
        "generation": result["generation"],
        "acknowledged_chunks": result["visible_chunks_before"],
        "acknowledged_frames": result["visible_frames_before"],
        "playback_sequence": result["chunk_index"],
        "pending": 1,
        "pending_chunk_index": result["chunk_index"],
        "pending_start_frame": result["start_frame"],
        "pending_frame_count": result["frame_count"],
        "previous_publication_result_sha256": result[
            "previous_publication_result_sha256"
        ],
        "previous_ack_result_sha256": acknowledgement["previous_ack_result_sha256"],
        "pending_publication_result_sha256": result["result_sha256"],
        "pending_output_sha256": result["output_sha256"],
        "state_sha256": registry.ZERO,
    }
    pending["state_sha256"] = audio._root(
        audio.STATE_DOMAIN,
        audio._state_body(pending),
    )
    observation = audio.make_observation(
        pending,
        sink_implementation_sha256=acknowledgement["sink_implementation_sha256"],
        sink_instance_sha256=acknowledgement["sink_instance_sha256"],
    )
    acknowledgement_plan = audio.make_ack_plan(
        pending,
        result,
        observation,
    )
    state, acknowledgement = audio.acknowledge(
        pending,
        result,
        observation,
        acknowledgement_plan,
    )
    return state, plan, provenance, result, acknowledgement


class GeneratedMediaProducerAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = admission.reference_inputs()

    def test_reference_roots_mappings_and_derived_lifecycle(self) -> None:
        archives = admission.reference_archives()
        first = archives["first"]
        second = archives["second"]
        expected_roots = {
            "first_manifest": (
                first["manifest"]["manifest_sha256"],
                "d5d8129d2e6076cf541664c19a2e1870cf2c8d6c376d8c7764b9a3f0c8bf171b",
            ),
            "first_archive": (
                first["archive_sha256"],
                "1ffa14e1decad4edaf192b06528d154540c88007b4c6c3521914daf30532df6d",
            ),
            "second_manifest": (
                second["manifest"]["manifest_sha256"],
                "b97bada9db18b23213cf7d3fec7a8707f3f58870182d387a419f40977f51778e",
            ),
            "second_archive": (
                second["archive_sha256"],
                "c921975397d538952a66fac46d6a6980871bfb122595a0ea05d25e5d0f84461e",
            ),
        }
        for label, (actual, expected) in expected_roots.items():
            with self.subTest(label=label):
                self.assertEqual(actual.hex(), expected)
        expected_entry_roots = (
            (
                "d51b6eaa294c7cbe6ab8fef661bb0f2e81a8c97bc41e7b058a2ed957fa41c849",
                "185e88048ab586b58d461bba3fbb4b5937d5acf6e852403a85726c882ad4e015",
                "448dc2b27ab9740ea8cc1f55e6f559c0c3ca70ee43d083112ca2b09fe2b25515",
            ),
            (
                "cba3d86554734b761e040915bb8d665bfa25ffabbeff9f701580fe4e13025670",
                "9e4e91ada62d1890a6fd51d9953fe57434a103fc82841229c15c81b103918f1f",
                "7d44b6bd952548b2b1fa035f744936f15e79e6549fdea18d829d397501f0324f",
            ),
        )
        for archive, expected in zip(
            (first, second),
            expected_entry_roots,
        ):
            self.assertEqual(
                tuple(entry["entry_sha256"].hex() for entry in archive["entries"]),
                expected,
            )

        self.assertEqual(first["manifest"]["generation"], 1)
        self.assertEqual(first["manifest"]["publication_sequence"], 1)
        self.assertEqual(second["manifest"]["generation"], 2)
        self.assertEqual(second["manifest"]["publication_sequence"], 2)
        self.assertEqual(
            second["manifest"]["previous_manifest_sha256"],
            first["manifest"]["manifest_sha256"],
        )
        self.assertEqual(
            second["manifest"]["previous_archive_sha256"],
            first["archive_sha256"],
        )
        self.assertEqual(
            registry.decode_archive(first["archive_bytes"], None),
            first,
        )
        self.assertEqual(
            registry.decode_archive(second["archive_bytes"], first),
            second,
        )

        expected_positions = (
            (
                (registry.IMAGE_MODALITY, 0, 0, 1, 0, 1, 4),
                (registry.AUDIO_MODALITY, 0, 0, 2, 0, 2, 4),
                (registry.VIDEO_MODALITY, 0, 0, 2, 0, 5, 8),
            ),
            (
                (registry.IMAGE_MODALITY, 1, 1, 1, 1, 2, 4),
                (registry.AUDIO_MODALITY, 1, 2, 2, 2, 4, 4),
                (registry.VIDEO_MODALITY, 1, 2, 2, 5, 10, 8),
            ),
        )
        for batch, archive, positions in zip(
            (self.fixture["batch1"], self.fixture["batch2"]),
            (first, second),
            expected_positions,
        ):
            for producer, entry, payload, expected in zip(
                batch,
                archive["entries"],
                archive["payloads"],
                positions,
            ):
                admitted = ADMITTERS[producer["modality"]](producer)
                self.assertEqual(
                    admitted,
                    {
                        field: entry[field]
                        for field in registry.ENTRY_INPUT_FIELDS
                        if field != "payload"
                    }
                    | {"payload": producer["encoded_payload"]},
                )
                self.assertEqual(
                    (
                        entry["modality"],
                        entry["ordinal"],
                        entry["unit_start"],
                        entry["unit_count"],
                        entry["timeline_start"],
                        entry["timeline_end"],
                        entry["source_bytes"],
                    ),
                    expected,
                )
                self.assertEqual(
                    entry["source_output_sha256"],
                    admission.model.sha256(producer["raw_output"]),
                )
                self.assertEqual(
                    payload,
                    producer["encoded_payload"],
                )

    def test_every_typed_wire_byte_is_authenticated(self) -> None:
        for producer in self.fixture["batch1"]:
            admit = ADMITTERS[producer["modality"]]
            for field in WIRE_FIELDS[producer["modality"]]:
                wire = producer[field]
                for index in range(len(wire)):
                    with self.subTest(
                        modality=producer["modality"],
                        field=field,
                        index=index,
                    ):
                        malformed = dict(producer)
                        mutated = bytearray(wire)
                        mutated[index] ^= 1
                        malformed[field] = bytes(mutated)
                        with self.assertRaises(
                            admission.GeneratedMediaProducerAdmissionError
                        ):
                            admit(malformed)

    def test_cross_record_substitution_fails_closed(self) -> None:
        for first, second in zip(
            self.fixture["batch1"],
            self.fixture["batch2"],
        ):
            admit = ADMITTERS[first["modality"]]
            for field in WIRE_FIELDS[first["modality"]]:
                with self.subTest(modality=first["modality"], field=field):
                    substituted = dict(first)
                    substituted[field] = second[field]
                    with self.assertRaises(
                        admission.GeneratedMediaProducerAdmissionError
                    ):
                        admit(substituted)

    def test_raw_output_hash_length_and_exact_types_fail_closed(self) -> None:
        for producer in self.fixture["batch1"]:
            admit = ADMITTERS[producer["modality"]]
            mutated = dict(producer)
            raw = bytearray(producer["raw_output"])
            raw[0] ^= 1
            mutated["raw_output"] = bytes(raw)
            with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
                admit(mutated)

            truncated = dict(producer)
            truncated["raw_output"] = producer["raw_output"][:-1]
            with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
                admit(truncated)

            for field in (
                "raw_output",
                "encoded_payload",
                WIRE_FIELDS[producer["modality"]][0],
                "encoder_implementation_sha256",
                "format_sha256",
            ):
                with self.subTest(modality=producer["modality"], field=field):
                    wrong_type = dict(producer)
                    wrong_type[field] = bytearray(producer[field])
                    with self.assertRaises(
                        admission.GeneratedMediaProducerAdmissionError
                    ):
                        admit(wrong_type)

            boolean_abi = dict(producer)
            boolean_abi["encoding_abi"] = True
            with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
                admit(boolean_abi)

    def test_rehashed_semantic_contradictions_fail_closed(self) -> None:
        foreign_provenance_producer = dict(self.fixture["batch1"][0])
        foreign_provenance = image.decode_provenance(
            foreign_provenance_producer["provenance_wire"]
        )
        foreign_result = image.decode_result(foreign_provenance_producer["result_wire"])
        foreign_provenance["source_step"] += 1
        foreign_provenance["provenance_sha256"] = image.provenance_root(
            foreign_provenance
        )
        foreign_result["provenance_sha256"] = foreign_provenance["provenance_sha256"]
        foreign_result["result_sha256"] = image.result_root(foreign_result)
        foreign_provenance_producer["provenance_wire"] = image.encode_provenance(
            foreign_provenance
        )
        foreign_provenance_producer["result_wire"] = image.encode_result(foreign_result)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_image(foreign_provenance_producer)

        audio_shape_producer = dict(self.fixture["batch1"][1])
        audio_shape_state = audio.decode_state(audio_shape_producer["state_wire"])
        audio_shape_state["sample_rate"] = 48_000
        audio_shape_state["state_sha256"] = audio._root(
            audio.STATE_DOMAIN,
            audio._state_body(audio_shape_state),
        )
        audio_shape_producer["state_wire"] = audio.encode_state(audio_shape_state)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_audio(audio_shape_producer)

        audio_ack_producer = dict(self.fixture["batch1"][1])
        audio_ack_state = audio.decode_state(audio_ack_producer["state_wire"])
        audio_ack = audio.decode_ack_result(audio_ack_producer["ack_result_wire"])
        audio_ack["plan_sha256"] = admission._identity(b"foreign-audio-ack-plan")
        audio_ack["result_sha256"] = audio._root(
            audio.ACK_RESULT_DOMAIN,
            audio._ack_result_body(audio_ack),
        )
        audio_ack_state["previous_ack_result_sha256"] = audio_ack["result_sha256"]
        audio_ack_state["state_sha256"] = audio._root(
            audio.STATE_DOMAIN,
            audio._state_body(audio_ack_state),
        )
        audio_ack_producer["state_wire"] = audio.encode_state(audio_ack_state)
        audio_ack_producer["ack_result_wire"] = audio.encode_ack_result(audio_ack)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_audio(audio_ack_producer)

        video_shape_producer = dict(self.fixture["batch1"][2])
        video_shape_state = video.decode_state(video_shape_producer["state_wire"])
        video_shape_state["width"] = 3
        video_shape_state["state_sha256"] = video._root(
            video.STATE_DOMAIN,
            video._state_body(video_shape_state),
        )
        video_shape_producer["state_wire"] = video.encode_state(video_shape_state)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_video(video_shape_producer)

        video_ack_producer = dict(self.fixture["batch1"][2])
        video_ack_state = video.decode_state(video_ack_producer["state_wire"])
        video_ack = video.decode_ack_result(video_ack_producer["ack_result_wire"])
        video_ack["plan_sha256"] = admission._identity(b"foreign-video-ack-plan")
        video_ack["result_sha256"] = video._root(
            video.ACK_RESULT_DOMAIN,
            video._ack_result_body(video_ack),
        )
        video_ack_state["previous_ack_result_sha256"] = video_ack["result_sha256"]
        video_ack_state["state_sha256"] = video._root(
            video.STATE_DOMAIN,
            video._state_body(video_ack_state),
        )
        video_ack_producer["state_wire"] = video.encode_state(video_ack_state)
        video_ack_producer["ack_result_wire"] = video.encode_ack_result(video_ack)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_video(video_ack_producer)

    def test_source_generation_is_independent_from_output_ordinal(self) -> None:
        image_producer = dict(self.fixture["batch1"][0])
        image_plan = image.decode_plan(image_producer["plan_wire"])
        image_provenance = image.decode_provenance(image_producer["provenance_wire"])
        image_result = image.decode_result(image_producer["result_wire"])
        for value in (image_plan, image_provenance, image_result):
            value["generation"] = 2
        image_plan["plan_sha256"] = image.plan_root(image_plan)
        image_provenance["plan_sha256"] = image_plan["plan_sha256"]
        image_provenance["provenance_sha256"] = image.provenance_root(image_provenance)
        image_result["plan_sha256"] = image_plan["plan_sha256"]
        image_result["provenance_sha256"] = image_provenance["provenance_sha256"]
        image_result["result_sha256"] = image.result_root(image_result)
        image_producer["plan_wire"] = image.encode_plan(image_plan)
        image_producer["provenance_wire"] = image.encode_provenance(image_provenance)
        image_producer["result_wire"] = image.encode_result(image_result)
        admitted_image = admission.admit_image(image_producer)
        self.assertEqual(admitted_image["ordinal"], 0)
        self.assertEqual(image_result["generation"], 2)
        self.assertEqual(image_result["image_index"], 1)

        audio_producer = dict(self.fixture["batch1"][1])
        audio_state = audio.decode_state(audio_producer["state_wire"])
        audio_plan = audio.decode_plan(audio_producer["plan_wire"])
        audio_provenance = audio.decode_provenance(audio_producer["provenance_wire"])
        audio_result = audio.decode_result(audio_producer["result_wire"])
        audio_ack = audio.decode_ack_result(audio_producer["ack_result_wire"])
        for value in (audio_plan, audio_provenance, audio_result):
            value["generation"] = 2
        audio_ack["generation"] = 3
        audio_state["generation"] = 3
        (
            audio_state,
            audio_plan,
            audio_provenance,
            audio_result,
            audio_ack,
        ) = _reseal_audio_records(
            audio_state,
            audio_plan,
            audio_provenance,
            audio_result,
            audio_ack,
        )
        audio_producer["state_wire"] = audio.encode_state(audio_state)
        audio_producer["plan_wire"] = audio.encode_plan(audio_plan)
        audio_producer["provenance_wire"] = audio.encode_provenance(audio_provenance)
        audio_producer["result_wire"] = audio.encode_result(audio_result)
        audio_producer["ack_result_wire"] = audio.encode_ack_result(audio_ack)
        admitted_audio = admission.admit_audio(audio_producer)
        self.assertEqual(admitted_audio["ordinal"], 0)
        self.assertEqual(audio_result["generation"], 2)
        self.assertEqual(audio_result["chunk_index"], 0)

    def test_exact_batch_shape_order_common_envelope_and_caps(self) -> None:
        metadata = self.fixture["metadata1"]
        batch = self.fixture["batch1"]
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                None,
                {**metadata, "generation": 1},
                batch,
            )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(None, {}, batch)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(None, metadata, tuple(batch))

        class ListSubclass(list):
            pass

        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                None,
                metadata,
                ListSubclass(batch),
            )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(None, metadata, [])
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(None, metadata, [batch[0]] * 13)
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(None, metadata, list(reversed(batch)))

        extra = dict(batch[0])
        extra["unexpected"] = 1
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_image(extra)
        missing = dict(batch[0])
        del missing["plan_wire"]
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_image(missing)
        boolean_modality = dict(batch[0])
        boolean_modality["modality"] = True
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_image(boolean_modality)

        class DictSubclass(dict):
            pass

        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_image(DictSubclass(batch[0]))

        class IntSubclass(int):
            pass

        integer_subclass = dict(batch[0])
        integer_subclass["encoding_abi"] = IntSubclass(integer_subclass["encoding_abi"])
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.admit_image(integer_subclass)

        common = _common_from_image(batch[0])
        for field in (
            "request_epoch",
            "tenant_scope_sha256",
            "metadata_policy_sha256",
            "challenge_sha256",
        ):
            foreign_common = dict(common)
            if field == "request_epoch":
                foreign_common[field] += 1
            else:
                foreign_common[field] = admission._identity(
                    b"foreign-" + field.encode("ascii")
                )
            foreign_audio, _ = admission._reference_audio(foreign_common)
            mixed = [batch[0], foreign_audio, batch[2]]
            with (
                self.subTest(envelope_field=field),
                self.assertRaises(admission.GeneratedMediaProducerAdmissionError),
            ):
                admission.encode_archive(None, metadata, mixed)

        first_image = batch[0]
        first_plan = image.decode_plan(first_image["plan_wire"])
        first_result = image.decode_result(first_image["result_wire"])
        previous_plan = first_plan["previous_plan_sha256"]
        previous_result = first_result["previous_result_sha256"]
        previous_state = first_result["publication_state_before_sha256"]
        five_images = []
        for index in range(1, 6):
            producer, plan, result = admission._reference_image(
                index,
                common,
                previous_plan,
                previous_result,
                previous_state,
            )
            five_images.append(producer)
            previous_plan = plan["plan_sha256"]
            previous_result = result["result_sha256"]
            previous_state = result["publication_state_after_sha256"]
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(None, metadata, five_images)

    def test_typed_predecessor_lineage_uses_archived_and_current_entries(
        self,
    ) -> None:
        first = admission.encode_archive(
            None,
            self.fixture["metadata1"],
            self.fixture["batch1"],
        )
        second = admission.encode_archive(
            first,
            self.fixture["metadata2"],
            self.fixture["batch2"],
        )
        current_batch = [
            self.fixture["batch1"][0],
            self.fixture["batch2"][0],
            self.fixture["batch1"][1],
            self.fixture["batch2"][1],
            self.fixture["batch1"][2],
            self.fixture["batch2"][2],
        ]
        current = admission.encode_archive(
            None,
            self.fixture["metadata1"],
            current_batch,
        )
        self.assertEqual(current["manifest"]["generation"], 1)
        self.assertEqual(
            (
                current["manifest"]["image_count"],
                current["manifest"]["audio_count"],
                current["manifest"]["video_count"],
            ),
            (2, 2, 2),
        )
        payload_offset = 0
        for producer, entry, payload, expected_ordinal in zip(
            current_batch,
            current["entries"],
            current["payloads"],
            (0, 1, 0, 1, 0, 1),
        ):
            self.assertEqual(entry["payload_offset"], payload_offset)
            self.assertEqual(entry["ordinal"], expected_ordinal)
            self.assertEqual(payload, producer["encoded_payload"])
            payload_offset += len(payload)
        for first_index, second_index in ((0, 1), (2, 3), (4, 5)):
            first_current = current["entries"][first_index]
            second_current = current["entries"][second_index]
            self.assertEqual(first_current["previous_entry_sha256"], registry.ZERO)
            self.assertEqual(
                second_current["previous_entry_sha256"],
                first_current["entry_sha256"],
            )

        first_by_modality = {entry["modality"]: entry for entry in first["entries"]}
        for producer in self.fixture["batch1"][1:]:
            modality = producer["modality"]
            if modality == registry.AUDIO_MODALITY:
                result = audio.decode_result(producer["result_wire"])
                acknowledgement = audio.decode_ack_result(producer["ack_result_wire"])
            else:
                result = video.decode_result(producer["result_wire"])
                acknowledgement = video.decode_ack_result(producer["ack_result_wire"])
            self.assertEqual(
                result["previous_publication_result_sha256"],
                registry.ZERO,
            )
            self.assertEqual(
                acknowledgement["previous_ack_result_sha256"],
                registry.ZERO,
            )
        for producer in self.fixture["batch2"]:
            modality = producer["modality"]
            predecessor = first_by_modality[modality]
            if modality == registry.IMAGE_MODALITY:
                result = image.decode_result(producer["result_wire"])
                previous_result = result["previous_result_sha256"]
                state_before = result["publication_state_before_sha256"]
            elif modality == registry.AUDIO_MODALITY:
                result = audio.decode_result(producer["result_wire"])
                acknowledgement = audio.decode_ack_result(producer["ack_result_wire"])
                previous_result = result["previous_publication_result_sha256"]
                state_before = result["state_before_sha256"]
                self.assertEqual(
                    acknowledgement["previous_ack_result_sha256"],
                    predecessor["completion_sha256"],
                )
            else:
                result = video.decode_result(producer["result_wire"])
                acknowledgement = video.decode_ack_result(producer["ack_result_wire"])
                previous_result = result["previous_publication_result_sha256"]
                state_before = result["state_before_sha256"]
                self.assertEqual(
                    acknowledgement["previous_ack_result_sha256"],
                    predecessor["completion_sha256"],
                )
            self.assertEqual(
                previous_result,
                predecessor["result_sha256"],
            )
            self.assertEqual(
                state_before,
                predecessor["state_after_sha256"],
            )
        self.assertEqual(second["manifest"]["generation"], 2)

        common = _common_from_image(self.fixture["batch1"][0])
        image1, plan1, result1 = admission._reference_image(
            1,
            common,
            admission._identity(b"image-plan-genesis"),
            admission._identity(b"image-result-genesis"),
            admission._identity(b"image-state-genesis"),
        )
        wrong_image2, _, _ = admission._reference_image(
            2,
            common,
            plan1["plan_sha256"],
            admission._identity(b"wrong-image-predecessor"),
            result1["publication_state_after_sha256"],
        )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                None,
                self.fixture["metadata1"],
                [image1, wrong_image2],
            )
        wrong_state_image2, _, _ = admission._reference_image(
            2,
            common,
            plan1["plan_sha256"],
            result1["result_sha256"],
            admission._identity(b"wrong-image-state"),
        )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                None,
                self.fixture["metadata1"],
                [image1, wrong_state_image2],
            )

        audio1, _ = admission._reference_audio(common)
        _, foreign_audio2 = admission._reference_audio(
            common,
            (bytes((141, 115)), bytes((142, 114))),
        )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                None,
                self.fixture["metadata1"],
                [audio1, foreign_audio2],
            )

        video1, _ = admission._reference_video(common)
        _, foreign_video2 = admission._reference_video(
            common,
            (
                (bytes((17, 19)), 2, 3),
                (bytes((23, 29)), 4, 1),
            ),
        )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                None,
                self.fixture["metadata1"],
                [video1, foreign_video2],
            )

        malformed_previous = copy.deepcopy(first)
        malformed_previous["archive_sha256"] = admission._identity(
            b"malformed-archive-snapshot"
        )
        with self.assertRaises(admission.GeneratedMediaProducerAdmissionError):
            admission.encode_archive(
                malformed_previous,
                self.fixture["metadata2"],
                self.fixture["batch2"],
            )


if __name__ == "__main__":
    unittest.main()
