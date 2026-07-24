from __future__ import annotations

import copy
import hashlib
import struct
import unittest

from bench import generated_audio_playback as audio_producer
from bench import generated_image_publication as image_producer
from bench import generated_media_external_format as external
from bench import generated_media_format_conformance as conformance
from bench import generated_media_output_registry as registry
from bench import generated_media_producer_transition as transition
from bench import generated_video_display as video_producer


PNG_CONTRACT_SHA256 = "4a976a0b4bdb38026c4844fc5d0ec64d17bbe43fd9db0a5d051915a328a8d6e2"
WAVE_CONTRACT_SHA256 = (
    "47919dc5fdc5024a1834132048f063cc9fed163e346c2b9572368c8b7f4544c8"
)
APNG_CONTRACT_SHA256 = (
    "92ca80f8f1eed5071753f47183c6c121cb3d88752fc3232534779b2f99bb9512"
)
PROFILE_SET_SHA256 = "aab136a5855abd2cff2a6ac8c55667b57de47add07e10d0b88c7de9d83d3d484"

# Exact deterministic three-modality batch vector.  The full record-table
# identity and whole-evidence identity below bind the bytes following this
# literal 576-byte header without embedding four kilobytes of redundant hex.
FROZEN_BATCH_HEADER_HEX = (
    "474c4d46424154310100000000000000c00f000000000000000000000000000011000000000000000100000000000000"
    "09000000000000000300000000000000800d000000000000100000000000000065010000000000000700000000000000"
    "e661f4c935e8a5a83349afb5e347695c2e972e967b50efcd618f93b0b7b4c24be9da86d351cf9a7642d8c50195c3f466"
    "220911a15c177809bd1161a51e8c5f24823412d1eacb67956220e532959f0104603057c88704863ca38e7cd188fda812"
    "2dd00bd77e0222ced882665481a9c1d9f907309d16e05ed007a1ea63928477a90362400e31542f3ad02f1488ddf892bb"
    "fbaec4f40efa84c11c0bc68ae7c38d5105b3abf2579a5eb66403cd78be557fd860633a1fe2103c7642030defe32c657f"
    "0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa38af4dbb2f0ca70f424cfe80eeb08f7dd"
    "971d42d9d233693e09d1d63902edbff8aab136a5855abd2cff2a6ac8c55667b57de47add07e10d0b88c7de9d83d3d484"
    "000000000000000000000000000000000000000000000000000000000000000079bc01e9100305119ab13474b9f5c3be"
    "775e2bdc00432fccd78749879c47528679bc01e9100305119ab13474b9f5c3be775e2bdc00432fccd78749879c475286"
    "26215834a740cc28e1973c7aab6ea25df738ebfb7deae63d4765a91a8dbb210c63994a0f4538f139a7b85e1b7fb1868f"
    "6910898386ebf4a38e173f03db6cba635f30f47be1e5d46b9e494a63063d2739951e819b0dc907daa8765de2d8a1465f"
)
FROZEN_BATCH_SHA256 = "5f30f47be1e5d46b9e494a63063d2739951e819b0dc907daa8765de2d8a1465f"
FROZEN_RECORD_TABLE_SHA256 = (
    "8af4dbb2f0ca70f424cfe80eeb08f7dd971d42d9d233693e09d1d63902edbff8"
)
FROZEN_EVIDENCE_SHA256 = (
    "ac44c06e58d097b4a6f62312709a7a5691fd6af4c776b81ecfe91311ccd76172"
)
FROZEN_RECORD_SHA256 = (
    "79bc01e9100305119ab13474b9f5c3be775e2bdc00432fccd78749879c475286",
    "26215834a740cc28e1973c7aab6ea25df738ebfb7deae63d4765a91a8dbb210c",
    "63994a0f4538f139a7b85e1b7fb1868f6910898386ebf4a38e173f03db6cba63",
)

PAYLOADS = {
    conformance.IMAGE_MODALITY: external.encode_image_png(),
    conformance.AUDIO_MODALITY: external.encode_audio_wave(),
    conformance.VIDEO_MODALITY: external.encode_video_apng(),
}


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("ascii")).digest()


def _canonical_image_plan_wire() -> bytes:
    one = _digest("test-image-plan")
    plan: conformance.Record = {
        "request_epoch": 1,
        "generation": 1,
        "image_index": 1,
        "source_step": 1,
        "width": 2,
        "height": 2,
        "channels": 1,
        "row_stride": 2,
        "latent_bytes": 1,
        "pixel_bytes": 4,
        "maximum_output_bytes": 4,
        "decoder_abi": 1,
        "color_model": image_producer.GRAY,
        "transfer_function": image_producer.LINEAR,
        "alpha_mode": image_producer.ALPHA_NONE,
        "publication_sequence": 1,
        "visible_images_before": 0,
        "visible_images_after": 1,
        "logical_units": 1,
        "required_capabilities": 0,
        **{field: one for field in image_producer.PLAN_DIGESTS},
        "plan_sha256": image_producer.ZERO_DIGEST,
    }
    plan["plan_sha256"] = image_producer.plan_root(plan)
    return image_producer.encode_plan(plan)


def _canonical_producer_wires() -> dict[int, bytes]:
    audio_fixture = audio_producer.reference_fixture()
    video_fixture = video_producer.reference_fixture()
    return {
        conformance.IMAGE_MODALITY: _canonical_image_plan_wire(),
        conformance.AUDIO_MODALITY: audio_producer.encode_plan(audio_fixture["plan1"]),
        conformance.VIDEO_MODALITY: video_producer.encode_manifest(
            video_fixture["manifest1"]
        ),
    }


CANONICAL_PRODUCER_WIRES = _canonical_producer_wires()


def _producer_wire(modality: int) -> bytes:
    return CANONICAL_PRODUCER_WIRES[modality]


def _record_input(
    modality: int,
    ordinal: int,
    previous: bytes = conformance.ZERO,
    label_suffix: str = "",
) -> conformance.Record:
    label = {
        conformance.IMAGE_MODALITY: "image",
        conformance.AUDIO_MODALITY: "audio",
        conformance.VIDEO_MODALITY: "video",
    }[modality]
    return conformance.make_record_input(
        modality=modality,
        registry_ordinal=ordinal,
        producer_wire=_producer_wire(modality),
        producer_plan_or_manifest_sha256=conformance.producer_wire_root(
            modality,
            _producer_wire(modality),
        ),
        encoded_payload=PAYLOADS[modality],
        encoder_implementation_sha256=_digest(f"encoder-{label}{label_suffix}"),
        transition_receipt_sha256=_digest(f"transition-{label}{label_suffix}"),
        registry_entry_sha256=_digest(f"entry-{label}{label_suffix}"),
        previous_format_record_sha256=previous,
    )


def _metadata(generation: int = 1) -> conformance.Record:
    suffix = "" if generation == 1 else f"-{generation}"
    return {
        "request_epoch": 17,
        "registry_generation": generation,
        "publication_sequence": 8 + generation,
        "generation_plan_sha256": _digest(f"generation{suffix}"),
        "tenant_scope_sha256": _digest("tenant"),
        "metadata_policy_sha256": _digest("policy"),
        "challenge_sha256": _digest("challenge"),
        "transition_batch_sha256": _digest(f"transition-batch{suffix}"),
        "registry_manifest_sha256": _digest(f"manifest{suffix}"),
        "registry_archive_sha256": _digest(f"archive{suffix}"),
    }


def _initial_records() -> list[bytes]:
    return [
        conformance.encode_format_record(_record_input(modality, index))
        for index, modality in enumerate(conformance.MODALITIES)
    ]


def _initial_evidence() -> bytes:
    return conformance.encode_format_evidence(
        _metadata(),
        _initial_records(),
    )


def _reseal_record(record: bytearray) -> None:
    record[conformance.FORMAT_RECORD_BODY_BYTES :] = hashlib.sha256(
        conformance.FORMAT_RECORD_DOMAIN
        + bytes(record[: conformance.FORMAT_RECORD_BODY_BYTES])
    ).digest()


def _reseal_batch(evidence: bytearray, *, reseal_table: bool) -> None:
    if reseal_table:
        evidence[320:352] = hashlib.sha256(
            conformance.FORMAT_RECORD_TABLE_DOMAIN
            + bytes(evidence[conformance.FORMAT_BATCH_HEADER_BYTES :])
        ).digest()
    evidence[
        conformance.FORMAT_BATCH_BODY_BYTES : conformance.FORMAT_BATCH_HEADER_BYTES
    ] = hashlib.sha256(
        conformance.FORMAT_BATCH_DOMAIN
        + bytes(evidence[: conformance.FORMAT_BATCH_BODY_BYTES])
    ).digest()


class GeneratedMediaFormatConformanceTests(unittest.TestCase):
    def test_codec_owned_contract_roots_are_frozen(self) -> None:
        expected = (
            (conformance.PNG_PROFILE, PNG_CONTRACT_SHA256),
            (conformance.WAVE_PCM_S16LE_PROFILE, WAVE_CONTRACT_SHA256),
            (
                conformance.APNG_TWO_FRAME_GRAY8_PROFILE,
                APNG_CONTRACT_SHA256,
            ),
        )
        for profile, root in expected:
            with self.subTest(profile=profile):
                self.assertEqual(
                    conformance.format_contract_root(profile).hex(),
                    root,
                )
        self.assertEqual(
            conformance.profile_set_root().hex(),
            PROFILE_SET_SHA256,
        )
        self.assertEqual(
            conformance.encoding_abi(conformance.PNG_PROFILE),
            conformance.PNG_ENCODING_ABI,
        )
        self.assertEqual(
            conformance.encoding_abi(conformance.WAVE_PCM_S16LE_PROFILE),
            conformance.WAVE_ENCODING_ABI,
        )
        self.assertEqual(
            conformance.encoding_abi(conformance.APNG_TWO_FRAME_GRAY8_PROFILE),
            conformance.APNG_ENCODING_ABI,
        )

    def test_frozen_batch_vector_offsets_and_distinct_payload_roots(
        self,
    ) -> None:
        evidence = _initial_evidence()
        decoded = conformance.decode_format_evidence(evidence)
        self.assertEqual(
            len(evidence),
            conformance.FORMAT_BATCH_HEADER_BYTES + 3 * conformance.FORMAT_RECORD_BYTES,
        )
        self.assertEqual(
            evidence[: conformance.FORMAT_BATCH_HEADER_BYTES].hex(),
            FROZEN_BATCH_HEADER_HEX,
        )
        self.assertEqual(
            decoded["batch"]["batch_sha256"].hex(),
            FROZEN_BATCH_SHA256,
        )
        self.assertEqual(
            decoded["batch"]["record_table_sha256"].hex(),
            FROZEN_RECORD_TABLE_SHA256,
        )
        self.assertEqual(
            hashlib.sha256(evidence).hexdigest(),
            FROZEN_EVIDENCE_SHA256,
        )
        self.assertEqual(
            tuple(record["record_sha256"].hex() for record in decoded["records"]),
            FROZEN_RECORD_SHA256,
        )
        self.assertEqual(decoded["batch"]["record_count"], 3)
        self.assertEqual(decoded["batch"]["aggregate_raw_output_bytes"], 16)
        self.assertEqual(
            decoded["batch"]["aggregate_encoded_payload_bytes"],
            90 + 48 + 219,
        )
        self.assertEqual(decoded["batch"]["modality_mask"], 0x7)
        self.assertEqual(evidence[0:8], conformance.FORMAT_BATCH_MAGIC)
        self.assertEqual(
            evidence[
                conformance.FORMAT_BATCH_HEADER_BYTES : conformance.FORMAT_BATCH_HEADER_BYTES
                + 8
            ],
            conformance.FORMAT_RECORD_MAGIC,
        )

        for record, payload in zip(
            decoded["records"],
            (PAYLOADS[modality] for modality in conformance.MODALITIES),
        ):
            with self.subTest(modality=record["modality"]):
                self.assertEqual(
                    record["encoded_payload_sha256"],
                    hashlib.sha256(payload).digest(),
                )
                self.assertNotEqual(
                    record["encoded_payload_sha256"],
                    record["registry_payload_sha256"],
                )
                expected_registry_root = registry.payload_root(
                    record["modality"],
                    record["registry_ordinal"],
                    record["encoding_abi"],
                    record["raw_output_sha256"],
                    payload,
                )
                self.assertEqual(
                    record["registry_payload_sha256"],
                    expected_registry_root,
                )

        audio_wire = _initial_records()[1]
        audio_padding_start = (
            384 + conformance.PRODUCER_WIRE_BYTES[conformance.AUDIO_MODALITY]
        )
        self.assertEqual(
            audio_wire[audio_padding_start : conformance.FORMAT_RECORD_BODY_BYTES],
            bytes(conformance.FORMAT_RECORD_BODY_BYTES - audio_padding_start),
        )

    def test_record_reserved_bytes_padding_profile_and_abi_are_strict(
        self,
    ) -> None:
        audio = bytearray(_initial_records()[1])
        audio_padding_start = (
            384 + conformance.PRODUCER_WIRE_BYTES[conformance.AUDIO_MODALITY]
        )
        audio[audio_padding_start] = 1
        _reseal_record(audio)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_record(bytes(audio))

        reserved = bytearray(_initial_records()[0])
        reserved[88] = 1
        _reseal_record(reserved)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_record(bytes(reserved))

        wrong_abi = bytearray(_initial_records()[0])
        struct.pack_into("<Q", wrong_abi, 56, 1)
        _reseal_record(wrong_abi)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_record(bytes(wrong_abi))

        wrong_contract = bytearray(_initial_records()[0])
        wrong_contract[256] ^= 1
        _reseal_record(wrong_contract)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_record(bytes(wrong_contract))

    def test_producer_headers_reserved_footer_and_claimed_roots_are_strict(
        self,
    ) -> None:
        layouts = {
            conformance.IMAGE_MODALITY: (
                image_producer.PLAN_BODY_BYTES,
                image_producer.PLAN_DOMAIN,
                192,
                "plan_sha256",
            ),
            conformance.AUDIO_MODALITY: (
                audio_producer.PLAN_BODY_BYTES,
                audio_producer.PLAN_DOMAIN,
                32
                + len(audio_producer.PLAN_SCALARS) * 8
                + len(audio_producer.PLAN_DIGESTS) * 32,
                "plan_sha256",
            ),
            conformance.VIDEO_MODALITY: (
                video_producer.MANIFEST_BODY_BYTES,
                video_producer.MANIFEST_DOMAIN,
                32
                + len(video_producer.MANIFEST_SCALARS) * 8
                + len(video_producer.MANIFEST_DIGESTS) * 32,
                "manifest_sha256",
            ),
        }
        for modality, layout in layouts.items():
            body_bytes, domain, reserved_offset, root_field = layout
            wire = _producer_wire(modality)
            with self.subTest(modality=modality, check="canonical"):
                decoded = conformance.decode_producer_wire(
                    modality,
                    wire,
                )
                self.assertEqual(
                    conformance.producer_wire_root(modality, wire),
                    decoded[root_field],
                )

            with self.subTest(modality=modality, check="header"):
                bad_header = bytearray(wire)
                bad_header[0] ^= 1
                bad_header[body_bytes:] = hashlib.sha256(
                    domain + bytes(bad_header[:body_bytes])
                ).digest()
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_producer_wire(
                        modality,
                        bytes(bad_header),
                    )

            self.assertLess(reserved_offset, body_bytes)
            with self.subTest(modality=modality, check="reserved"):
                bad_reserved = bytearray(wire)
                bad_reserved[reserved_offset] = 1
                bad_reserved[body_bytes:] = hashlib.sha256(
                    domain + bytes(bad_reserved[:body_bytes])
                ).digest()
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_producer_wire(
                        modality,
                        bytes(bad_reserved),
                    )

            with self.subTest(modality=modality, check="footer"):
                bad_footer = bytearray(wire)
                bad_footer[-1] ^= 1
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_producer_wire(
                        modality,
                        bytes(bad_footer),
                    )

            with self.subTest(modality=modality, check="opaque"):
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_producer_wire(
                        modality,
                        bytes(len(wire)),
                    )

        wrong_claim = _record_input(conformance.IMAGE_MODALITY, 0)
        wrong_claim["producer_plan_or_manifest_sha256"] = _digest(
            "foreign producer claim"
        )
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.encode_format_record(wrong_claim)

    def test_external_parsing_and_producer_wire_size_are_enforced(self) -> None:
        invalid_png = bytearray(PAYLOADS[conformance.IMAGE_MODALITY])
        invalid_png[45] ^= 1
        kwargs = {
            "modality": conformance.IMAGE_MODALITY,
            "registry_ordinal": 0,
            "producer_wire": _producer_wire(conformance.IMAGE_MODALITY),
            "producer_plan_or_manifest_sha256": _digest("producer"),
            "encoded_payload": bytes(invalid_png),
            "encoder_implementation_sha256": _digest("encoder"),
            "transition_receipt_sha256": _digest("transition"),
            "registry_entry_sha256": _digest("entry"),
        }
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.make_record_input(**kwargs)

        valid = _record_input(conformance.AUDIO_MODALITY, 1)
        valid["producer_wire"] = valid["producer_wire"] + b"\x00"
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.encode_format_record(valid)

        foreign_shape = image_producer.decode_plan(
            _producer_wire(conformance.IMAGE_MODALITY)
        )
        foreign_shape.update(
            {
                "width": 1,
                "height": 4,
                "row_stride": 1,
                "plan_sha256": image_producer.ZERO_DIGEST,
            }
        )
        foreign_shape["plan_sha256"] = image_producer.plan_root(foreign_shape)
        foreign_wire = image_producer.encode_plan(foreign_shape)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.make_record_input(
                modality=conformance.IMAGE_MODALITY,
                registry_ordinal=0,
                producer_wire=foreign_wire,
                producer_plan_or_manifest_sha256=foreign_shape["plan_sha256"],
                encoded_payload=PAYLOADS[conformance.IMAGE_MODALITY],
                encoder_implementation_sha256=_digest("encoder"),
                transition_receipt_sha256=_digest("transition"),
                registry_entry_sha256=_digest("entry"),
            )

    def test_producer_receipt_semantics_are_cross_bound(self) -> None:
        fixture = transition.reference_inputs()
        first = transition.verify_and_encode_batch(
            None,
            fixture["generation_plan1_sha256"],
            fixture["batch1"],
        )
        second = transition.verify_and_encode_batch(
            first,
            fixture["generation_plan2_sha256"],
            fixture["batch2"],
        )
        for batch, witnesses in (
            (first, fixture["batch1"]),
            (second, fixture["batch2"]),
        ):
            for receipt, witness in zip(batch["receipts"], witnesses):
                modality = receipt["modality"]
                producer_field = (
                    "manifest_wire"
                    if modality == conformance.VIDEO_MODALITY
                    else "plan_wire"
                )
                producer = conformance.decode_producer_wire(
                    modality,
                    witness["producer"][producer_field],
                )
                conformance._validate_producer_receipt_binding(
                    modality,
                    producer,
                    receipt,
                )
                drift_fields = [
                    "producer_state_generation_before",
                    "producer_state_generation_after_publication",
                    "producer_state_generation_after_completion",
                ]
                if modality == conformance.IMAGE_MODALITY:
                    drift_fields.extend(
                        (
                            "model_step_before",
                            "model_step_after",
                            "model_plan_sha256",
                            "model_state_publication_after_sha256",
                        )
                    )
                else:
                    drift_fields.append("completion_sequence")
                for field in drift_fields:
                    with self.subTest(
                        generation=batch["header"]["registry_generation"],
                        modality=modality,
                        field=field,
                    ):
                        drifted = dict(receipt)
                        value = drifted[field]
                        drifted[field] = (
                            bytes((value[0] ^ 1,)) + value[1:]
                            if type(value) is bytes
                            else value + 1
                        )
                        with self.assertRaises(
                            conformance.GeneratedMediaFormatConformanceError
                        ):
                            conformance._validate_producer_receipt_binding(
                                modality,
                                producer,
                                drifted,
                            )

    def test_full_archive_transition_and_format_composition(self) -> None:
        from bench import generated_media_evidence_inspector as inspector

        batches = inspector.reference_format_batches()
        first_batch = batches["first"]
        second_batch = batches["second"]
        first = conformance.validate_archive_transition_and_format_evidence(
            first_batch["registry"]["archive_bytes"],
            first_batch["evidence_bytes"],
            first_batch["format_evidence_bytes"],
        )
        second = conformance.validate_archive_transition_and_format_evidence(
            second_batch["registry"]["archive_bytes"],
            second_batch["evidence_bytes"],
            second_batch["format_evidence_bytes"],
            first,
        )
        self.assertEqual(first["format"]["batch"]["registry_generation"], 1)
        self.assertEqual(first["format"]["batch"]["record_count"], 4)
        self.assertEqual(second["format"]["batch"]["registry_generation"], 2)
        self.assertEqual(second["format"]["batch"]["record_count"], 3)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.validate_archive_transition_and_format_evidence(
                second_batch["registry"]["archive_bytes"],
                second_batch["evidence_bytes"],
                second_batch["format_evidence_bytes"],
            )
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.validate_archive_transition_and_format_evidence(
                second_batch["registry"]["archive_bytes"],
                second_batch["evidence_bytes"],
                second_batch["format_evidence_bytes"],
                second,
            )

        fixture = inspector._canonical_profile_reference_inputs()
        witnesses_two = copy.deepcopy(fixture["batch2"])
        for index, witness in enumerate(witnesses_two):
            inspector._install_canonical_delivery(
                witness,
                f"generation-2-entry-{index}".encode("ascii"),
            )
        foreign_format = _initial_evidence()
        split_second_format = inspector._encode_format_evidence(
            second_batch,
            witnesses_two,
            foreign_format,
        )
        split_previous = {
            "registry": first["registry"],
            "transition": first["transition"],
            "format": conformance.decode_format_evidence(foreign_format),
        }
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.validate_transition_and_format_evidence(
                second_batch,
                split_second_format,
                foreign_format,
            )
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.validate_archive_transition_and_format_evidence(
                second_batch["registry"]["archive_bytes"],
                second_batch["evidence_bytes"],
                split_second_format,
                split_previous,
            )

    def test_every_record_and_batch_byte_mutation_rejects(self) -> None:
        record = _initial_records()[1]
        for index in range(len(record)):
            with self.subTest(wire="record", mutation=index):
                mutated = bytearray(record)
                mutated[index] ^= 1
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_format_record(bytes(mutated))

        evidence = _initial_evidence()
        for index in range(len(evidence)):
            with self.subTest(wire="batch", mutation=index):
                mutated = bytearray(evidence)
                mutated[index] ^= 1
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_format_evidence(bytes(mutated))

    def test_every_record_and_batch_truncation_and_extension_rejects(
        self,
    ) -> None:
        record = _initial_records()[1]
        for length in range(len(record)):
            with self.subTest(wire="record", truncation=length):
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_format_record(record[:length])
        for index in range(len(record) + 1):
            with self.subTest(wire="record", extension=index):
                extended = record[:index] + b"\x00" + record[index:]
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_format_record(extended)

        evidence = _initial_evidence()
        for length in range(len(evidence)):
            with self.subTest(wire="batch", truncation=length):
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_format_evidence(evidence[:length])
        for index in range(len(evidence) + 1):
            with self.subTest(wire="batch", extension=index):
                extended = evidence[:index] + b"\x00" + evidence[index:]
                with self.assertRaises(
                    conformance.GeneratedMediaFormatConformanceError
                ):
                    conformance.decode_format_evidence(extended)

    def test_sorted_modalities_aggregates_and_terminals_are_bound(
        self,
    ) -> None:
        evidence = bytearray(_initial_evidence())
        table_start = conformance.FORMAT_BATCH_HEADER_BYTES
        first = bytes(
            evidence[table_start : table_start + conformance.FORMAT_RECORD_BYTES]
        )
        second = bytes(
            evidence[
                table_start + conformance.FORMAT_RECORD_BYTES : table_start
                + 2 * conformance.FORMAT_RECORD_BYTES
            ]
        )
        evidence[table_start : table_start + conformance.FORMAT_RECORD_BYTES] = second
        evidence[
            table_start + conformance.FORMAT_RECORD_BYTES : table_start
            + 2 * conformance.FORMAT_RECORD_BYTES
        ] = first
        _reseal_batch(evidence, reseal_table=True)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_evidence(bytes(evidence))

        aggregate = bytearray(_initial_evidence())
        struct.pack_into("<Q", aggregate, 72, 17)
        _reseal_batch(aggregate, reseal_table=False)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_evidence(bytes(aggregate))

        terminal = bytearray(_initial_evidence())
        terminal[448] ^= 1
        _reseal_batch(terminal, reseal_table=False)
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.decode_format_evidence(bytes(terminal))

    def test_intra_batch_and_successor_lineage(self) -> None:
        first = conformance.encode_format_record(
            _record_input(conformance.IMAGE_MODALITY, 0)
        )
        first_root = conformance.decode_format_record(first)["record_sha256"]
        second = conformance.encode_format_record(
            _record_input(
                conformance.IMAGE_MODALITY,
                1,
                previous=first_root,
                label_suffix="-second",
            )
        )
        same_modality = conformance.encode_format_evidence(
            _metadata(),
            [first, second],
        )
        decoded_same = conformance.decode_format_evidence(same_modality)
        self.assertEqual(
            decoded_same["batch"]["terminal_image_sha256"],
            conformance.decode_format_record(second)["record_sha256"],
        )

        broken = conformance.encode_format_record(
            _record_input(
                conformance.IMAGE_MODALITY,
                1,
                label_suffix="-broken",
            )
        )
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.encode_format_evidence(
                _metadata(),
                [first, broken],
            )

        previous = _initial_evidence()
        previous_decoded = conformance.decode_format_evidence(previous)
        successor_record = conformance.encode_format_record(
            _record_input(
                conformance.IMAGE_MODALITY,
                3,
                previous=previous_decoded["batch"]["terminal_image_sha256"],
                label_suffix="-successor",
            )
        )
        successor = conformance.encode_format_evidence(
            _metadata(2),
            [successor_record],
            previous,
        )
        validated = conformance.validate_successor_format_evidence(
            successor,
            previous,
        )
        self.assertEqual(
            validated["batch"]["previous_format_batch_sha256"],
            previous_decoded["batch"]["batch_sha256"],
        )
        with self.assertRaises(conformance.GeneratedMediaFormatConformanceError):
            conformance.encode_format_evidence(
                _metadata(2),
                [successor_record],
            )


if __name__ == "__main__":
    unittest.main()
