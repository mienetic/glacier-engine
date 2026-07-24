from __future__ import annotations

import copy
import unittest
from typing import Any

from bench import generated_media_output_registry as registry


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def rehash_entry(
    value: registry.Record,
    **changes: Any,
) -> registry.Record:
    entry = {
        **value,
        **changes,
        "entry_sha256": registry.ZERO,
    }
    entry["entry_sha256"] = registry.entry_root(entry)
    return entry


def raw_entry(value: registry.Record) -> bytes:
    return registry._entry_body(value) + value["entry_sha256"]


def rehash_manifest(
    value: registry.Record,
    **changes: Any,
) -> registry.Record:
    manifest = {
        **value,
        **changes,
        "manifest_sha256": registry.ZERO,
    }
    manifest["manifest_sha256"] = registry.manifest_root(manifest)
    return manifest


def raw_manifest(value: registry.Record) -> bytes:
    return registry._manifest_body(value) + value["manifest_sha256"]


def repack(
    base: registry.Record,
    *,
    manifest: registry.Record | None = None,
    entry_table: bytes | None = None,
    payload_pack: bytes | None = None,
    parent_archive_sha256: bytes | None = None,
    challenge_sha256: bytes | None = None,
) -> bytes:
    selected_manifest = manifest or base["manifest"]
    selected_table = base["entry_table"] if entry_table is None else entry_table
    selected_pack = base["payload_pack"] if payload_pack is None else payload_pack
    set_value = registry._decode_set(base["archive_bytes"])
    parent = (
        set_value["parent_archive_sha256"]
        if parent_archive_sha256 is None
        else parent_archive_sha256
    )
    challenge = (
        selected_manifest["challenge_sha256"]
        if challenge_sha256 is None
        else challenge_sha256
    )
    return registry._encode_set(
        generation=selected_manifest["generation"],
        request_epoch=selected_manifest["request_epoch"],
        publication_next_sequence=(selected_manifest["publication_sequence"] + 1),
        parent_archive_sha256=parent,
        challenge_sha256=challenge,
        objects=(
            (
                registry.MANIFEST_OBJECT_ORDINAL,
                registry.MANIFEST_ABI,
                raw_manifest(selected_manifest),
            ),
            (
                registry.ENTRY_TABLE_OBJECT_ORDINAL,
                registry.ENTRY_TABLE_ABI,
                selected_table,
            ),
            (
                registry.PAYLOAD_PACK_OBJECT_ORDINAL,
                registry.PAYLOAD_PACK_ABI,
                selected_pack,
            ),
        ),
    )


def repack_entries(
    base: registry.Record,
    entries: list[registry.Record],
) -> bytes:
    entry_table = b"".join(raw_entry(entry) for entry in entries)
    manifest = registry._make_manifest(
        registry._metadata_from_manifest(base["manifest"]),
        entries,
        entry_table,
        base["payload_pack"],
        base["manifest"]["previous_manifest_sha256"],
        base["manifest"]["previous_archive_sha256"],
    )
    return repack(
        base,
        manifest=manifest,
        entry_table=entry_table,
    )


def maximum_initial_entries() -> list[registry.Record]:
    names = {
        registry.IMAGE_MODALITY: b"image",
        registry.AUDIO_MODALITY: b"audio",
        registry.VIDEO_MODALITY: b"video",
    }
    values: list[registry.Record] = []
    for modality in registry.MODALITIES:
        for ordinal in range(4):
            values.append(
                registry._reference_entry(
                    modality=modality,
                    ordinal=ordinal,
                    unit_start=ordinal,
                    unit_count=1,
                    timeline_start=ordinal * 10,
                    timeline_end=(ordinal + 1) * 10,
                    source_bytes=100 * modality + ordinal + 1,
                    generation_word=b"one",
                )
            )
            self_name = names[modality]
            if not values[-1]["payload"].startswith(self_name):
                raise AssertionError("fixture modality mismatch")
    return values


class GeneratedMediaOutputRegistryTests(unittest.TestCase):
    def test_golden_roots_and_every_archive_byte_are_canonical(
        self,
    ) -> None:
        archives = registry.reference_archives()
        first = archives["first"]
        second = archives["second"]
        expected = {
            "first_entry_table": (
                first["manifest"]["entry_table_sha256"],
                ("293d7d3700e1b9490160cb59212fcc93524e88a4820ade872a4e1c73e8bbd864"),
            ),
            "first_payload_pack": (
                first["manifest"]["payload_pack_sha256"],
                ("e09f479e220632f6339b90bf2e850560d75456658431d87a18cab51cfb5f1633"),
            ),
            "first_manifest": (
                first["manifest"]["manifest_sha256"],
                ("289a212c944c8f80f487786314288ee23832af3ddd1e683688503178e381c840"),
            ),
            "first_archive": (
                first["archive_sha256"],
                ("b526e7084aaaa54997a546a172cac3147b85333a16c2b45cee8525caf658f43d"),
            ),
            "second_entry_table": (
                second["manifest"]["entry_table_sha256"],
                ("2db55d88b81dd5d20dc8fc6f01bd8bf554ff304da4e71808de45989027692e79"),
            ),
            "second_payload_pack": (
                second["manifest"]["payload_pack_sha256"],
                ("133a523325776bd2a7690c7403bbfe3e60cdd5f99d518d07b9ab31cd4b6b0801"),
            ),
            "second_manifest": (
                second["manifest"]["manifest_sha256"],
                ("70a6a92d8dc01ed3696195ca8064e7b066be6ffde9a907a7c2d38d5c61bd6388"),
            ),
            "second_archive": (
                second["archive_sha256"],
                ("e1cda1d7c618afdb561a6447d62060700cbbc89b34929769ed53533ba96cba75"),
            ),
        }
        for name, (actual, expected_hex) in expected.items():
            with self.subTest(name=name):
                self.assertEqual(actual.hex(), expected_hex)

        self.assertEqual(
            registry.decode_archive(first["archive_bytes"], None),
            first,
        )
        self.assertEqual(
            registry.decode_archive(second["archive_bytes"], first),
            second,
        )
        self.assertEqual(registry.validate_decoded_archive(second), second)
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(second["archive_bytes"], None)

        manifest_wire = registry.encode_manifest(first["manifest"])
        self.assertEqual(len(manifest_wire), registry.MANIFEST_BYTES)
        self.assertEqual(
            registry.decode_manifest(manifest_wire),
            first["manifest"],
        )
        for index in range(len(manifest_wire)):
            with self.subTest(kind="manifest", index=index):
                mutated = bytearray(manifest_wire)
                mutated[index] ^= 1
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.decode_manifest(bytes(mutated))

        entry_wire = registry.encode_entry(first["entries"][0])
        self.assertEqual(len(entry_wire), registry.ENTRY_BYTES)
        self.assertEqual(
            registry.decode_entry(entry_wire),
            first["entries"][0],
        )
        for index in range(len(entry_wire)):
            with self.subTest(kind="entry", index=index):
                mutated = bytearray(entry_wire)
                mutated[index] ^= 1
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.decode_entry(bytes(mutated))

        archive_wire = first["archive_bytes"]
        for index in range(len(archive_wire)):
            with self.subTest(kind="archive", index=index):
                mutated = bytearray(archive_wire)
                mutated[index] ^= 1
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.decode_archive(bytes(mutated), None)

    def test_exact_payloads_offsets_objects_and_aggregates(self) -> None:
        archives = registry.reference_archives()
        first = archives["first"]
        second = archives["second"]
        expected_payloads = {
            "first": [
                b"image-0-generation-one",
                b"image-1-generation-one",
                b"audio-0-generation-one",
                b"audio-1-generation-one",
                b"audio-2-generation-one",
                b"video-0-generation-one",
                b"video-1-generation-one",
            ],
            "second": [
                b"image-2-generation-two",
                b"image-3-generation-two",
                b"audio-3-generation-two",
                b"audio-4-generation-two",
                b"video-2-generation-two",
                b"video-3-generation-two",
                b"video-4-generation-two",
            ],
        }
        expected_scalars = {
            "first": {
                "entry_count": 7,
                "entry_table_bytes": 3808,
                "payload_pack_bytes": 154,
                "total_source_bytes": 1412,
                "total_encoded_bytes": 154,
                "total_units": 486,
                "image_count": 2,
                "audio_count": 3,
                "video_count": 2,
                "image_units": 3,
                "audio_units": 480,
                "video_units": 3,
                "image_encoded_bytes": 44,
                "audio_encoded_bytes": 66,
                "video_encoded_bytes": 44,
                "image_unit_end": 3,
                "audio_unit_end": 480,
                "video_unit_end": 3,
                "image_timeline_end": 260,
                "audio_timeline_end": 480,
                "video_timeline_end": 99,
                "modality_mask": 7,
            },
            "second": {
                "entry_count": 7,
                "entry_table_bytes": 3808,
                "payload_pack_bytes": 154,
                "total_source_bytes": 1528,
                "total_encoded_bytes": 154,
                "total_units": 327,
                "image_count": 2,
                "audio_count": 2,
                "video_count": 3,
                "image_units": 3,
                "audio_units": 320,
                "video_units": 4,
                "image_encoded_bytes": 44,
                "audio_encoded_bytes": 44,
                "video_encoded_bytes": 66,
                "image_unit_end": 6,
                "audio_unit_end": 800,
                "video_unit_end": 7,
                "image_timeline_end": 600,
                "audio_timeline_end": 800,
                "video_timeline_end": 231,
                "modality_mask": 7,
            },
        }
        for name, archive in archives.items():
            with self.subTest(name=name):
                self.assertEqual(
                    archive["payloads"],
                    expected_payloads[name],
                )
                self.assertEqual(
                    archive["payload_pack"],
                    b"".join(expected_payloads[name]),
                )
                self.assertEqual(
                    archive["entry_table"],
                    b"".join(
                        registry.encode_entry(entry) for entry in archive["entries"]
                    ),
                )
                for field, expected in expected_scalars[name].items():
                    self.assertEqual(
                        archive["manifest"][field],
                        expected,
                        field,
                    )
                cursor = 0
                for entry, payload in zip(
                    archive["entries"],
                    archive["payloads"],
                ):
                    self.assertEqual(entry["payload_offset"], cursor)
                    self.assertEqual(entry["payload_bytes"], len(payload))
                    self.assertEqual(
                        entry["payload_sha256"],
                        registry.payload_root(
                            entry["modality"],
                            entry["ordinal"],
                            entry["encoding_abi"],
                            entry["source_output_sha256"],
                            payload,
                        ),
                    )
                    cursor += len(payload)
                self.assertEqual(cursor, len(archive["payload_pack"]))
                set_value = registry._decode_set(archive["archive_bytes"])
                self.assertEqual(
                    tuple(set_value["objects"]),
                    (1, 2, 3),
                )
                self.assertEqual(
                    tuple(
                        value["abi_version"] for value in set_value["objects"].values()
                    ),
                    (1, 1, 1),
                )
        self.assertEqual(
            second["manifest"]["previous_manifest_sha256"],
            first["manifest"]["manifest_sha256"],
        )
        self.assertEqual(
            second["manifest"]["previous_archive_sha256"],
            first["archive_sha256"],
        )
        self.assertNotEqual(
            second["manifest"]["generation_plan_sha256"],
            first["manifest"]["generation_plan_sha256"],
        )

    def test_order_gaps_duplicates_and_entry_caps_reject(self) -> None:
        fixture = registry.reference_inputs()
        metadata = fixture["metadata1"]
        original = fixture["entries1"]
        cases: dict[str, list[registry.Record]] = {}

        shuffled = copy.deepcopy(original)
        shuffled[0], shuffled[1] = shuffled[1], shuffled[0]
        cases["ordering"] = shuffled

        gap = copy.deepcopy(original)
        gap[1]["ordinal"] = 2
        cases["gap"] = gap

        duplicate = copy.deepcopy(original)
        duplicate[1]["ordinal"] = 0
        cases["duplicate"] = duplicate

        five_images = maximum_initial_entries()[:4]
        five_images.append(
            registry._reference_entry(
                modality=registry.IMAGE_MODALITY,
                ordinal=4,
                unit_start=4,
                unit_count=1,
                timeline_start=40,
                timeline_end=50,
                source_bytes=105,
                generation_word=b"one",
            )
        )
        cases["more-than-four"] = five_images

        thirteen = maximum_initial_entries()
        thirteen.insert(
            4,
            registry._reference_entry(
                modality=registry.IMAGE_MODALITY,
                ordinal=4,
                unit_start=4,
                unit_count=1,
                timeline_start=40,
                timeline_end=50,
                source_bytes=105,
                generation_word=b"one",
            ),
        )
        cases["more-than-twelve"] = thirteen

        for name, entries in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.encode_archive(None, metadata, entries)

        maximum = registry.encode_archive(
            None,
            metadata,
            maximum_initial_entries(),
        )
        self.assertEqual(maximum["manifest"]["entry_count"], 12)
        self.assertEqual(
            (
                maximum["manifest"]["image_count"],
                maximum["manifest"]["audio_count"],
                maximum["manifest"]["video_count"],
            ),
            (4, 4, 4),
        )

    def test_completion_semantics_fail_closed(self) -> None:
        fixture = registry.reference_inputs()
        cases: dict[str, tuple[int, dict[str, Any]]] = {
            "image-required": (0, {"completion_required": True}),
            "image-incomplete": (0, {"completed": False}),
            "image-completion-root": (
                0,
                {"completion_sha256": digest(0x81)},
            ),
            "audio-not-required": (
                2,
                {"completion_required": False},
            ),
            "audio-incomplete": (2, {"completed": False}),
            "audio-zero-completion": (
                2,
                {"completion_sha256": registry.ZERO},
            ),
            "video-not-required": (
                5,
                {"completion_required": False},
            ),
        }
        for name, (index, changes) in cases.items():
            with self.subTest(name=name):
                entries = copy.deepcopy(fixture["entries1"])
                entries[index].update(changes)
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.encode_archive(
                        None,
                        fixture["metadata1"],
                        entries,
                    )

        first = registry.reference_archives()["first"]
        altered = list(first["entries"])
        altered[0] = rehash_entry(
            altered[0],
            completion_required=True,
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack_entries(first, altered),
                None,
            )

    def test_successor_metadata_and_predecessors_are_exact(self) -> None:
        fixture = registry.reference_inputs()
        first = registry.encode_archive(
            None,
            fixture["metadata1"],
            fixture["entries1"],
        )
        metadata_cases: dict[str, Any] = {
            "request": 24,
            "generation": 3,
            "publication": 3,
            "tenant": digest(0x91),
            "policy": digest(0x92),
            "challenge": digest(0x93),
        }
        metadata_fields = {
            "request": "request_epoch",
            "generation": "generation",
            "publication": "publication_sequence",
            "tenant": "tenant_scope_sha256",
            "policy": "metadata_policy_sha256",
            "challenge": "challenge_sha256",
        }
        for name, value in metadata_cases.items():
            with self.subTest(name=name):
                metadata = {
                    **fixture["metadata2"],
                    metadata_fields[name]: value,
                }
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.encode_archive(
                        first,
                        metadata,
                        fixture["entries2"],
                    )

        without_video = [
            value
            for value in fixture["entries2"]
            if value["modality"] != registry.VIDEO_MODALITY
        ]
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.encode_archive(
                first,
                fixture["metadata2"],
                without_video,
            )

        second = registry.encode_archive(
            first,
            fixture["metadata2"],
            fixture["entries2"],
        )
        for index in (0, 2, 4):
            for field, value in (
                ("ordinal", second["entries"][index]["ordinal"] + 1),
                (
                    "unit_start",
                    second["entries"][index]["unit_start"] + 1,
                ),
                (
                    "timeline_start",
                    second["entries"][index]["timeline_start"] + 1,
                ),
                ("previous_entry_sha256", digest(0xA0 + index)),
            ):
                with self.subTest(index=index, field=field):
                    entries = list(second["entries"])
                    entries[index] = rehash_entry(
                        entries[index],
                        **{field: value},
                    )
                    with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                        registry.decode_archive(
                            repack_entries(second, entries),
                            first,
                        )

        self.assertEqual(registry.validate_decoded_archive(second), second)

    def test_payload_substitution_and_mixed_lineage_reject(self) -> None:
        fixture = registry.reference_inputs()
        archives = registry.reference_archives()
        first = archives["first"]
        second = archives["second"]

        substituted = bytearray(first["payload_pack"])
        substituted[0] ^= 1
        substituted_pack = bytes(substituted)
        substituted_manifest = registry._make_manifest(
            registry._metadata_from_manifest(first["manifest"]),
            first["entries"],
            first["entry_table"],
            substituted_pack,
            first["manifest"]["previous_manifest_sha256"],
            first["manifest"]["previous_archive_sha256"],
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack(
                    first,
                    manifest=substituted_manifest,
                    payload_pack=substituted_pack,
                ),
                None,
            )

        entries = list(first["entries"])
        entries[0] = rehash_entry(
            entries[0],
            source_output_sha256=digest(0xB1),
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack_entries(first, entries),
                None,
            )

        alternate_inputs = copy.deepcopy(fixture["entries1"])
        alternate_inputs[0]["payload"] = b"image-0-alternate-lineage"
        alternate = registry.encode_archive(
            None,
            fixture["metadata1"],
            alternate_inputs,
        )
        self.assertNotEqual(
            alternate["archive_sha256"],
            first["archive_sha256"],
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                second["archive_bytes"],
                alternate,
            )

        altered_snapshot = {
            **first,
            "archive_sha256": digest(0xB2),
        }
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                second["archive_bytes"],
                altered_snapshot,
            )

        class AlwaysEqual:
            def __eq__(self, other: object) -> bool:
                return True

        equality_poisoned = copy.deepcopy(first)
        equality_poisoned["archive_sha256"] = AlwaysEqual()
        equality_poisoned["manifest"]["manifest_sha256"] = AlwaysEqual()
        equality_poisoned["entries"][-1]["entry_sha256"] = AlwaysEqual()
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                second["archive_bytes"],
                equality_poisoned,
            )

    def test_rehashed_aggregate_offsets_and_archive_metadata_reject(
        self,
    ) -> None:
        first = registry.reference_archives()["first"]

        wrong_total = rehash_manifest(
            first["manifest"],
            total_source_bytes=(first["manifest"]["total_source_bytes"] + 1),
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack(first, manifest=wrong_total),
                None,
            )

        entries = list(first["entries"])
        entries[1] = rehash_entry(
            entries[1],
            payload_offset=entries[1]["payload_offset"] + 1,
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack_entries(first, entries),
                None,
            )

        wrong_table_digest = rehash_manifest(
            first["manifest"],
            entry_table_sha256=digest(0xC1),
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack(first, manifest=wrong_table_digest),
                None,
            )

        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.decode_archive(
                repack(first, challenge_sha256=digest(0xC2)),
                None,
            )

    def test_junk_truncation_nonbytes_and_decoded_mutation_reject(
        self,
    ) -> None:
        first = registry.reference_archives()["first"]

        class PoisonBytes(bytes):
            def __eq__(self, other: object) -> bool:
                return True

            def __ne__(self, other: object) -> bool:
                return False

            def __len__(self) -> int:
                return 32

        bad_raw: list[Any] = [
            None,
            "",
            bytearray(first["archive_bytes"]),
            memoryview(first["archive_bytes"]),
            PoisonBytes(first["archive_bytes"]),
            b"",
            first["archive_bytes"][:-1],
            first["archive_bytes"] + b"\x00",
            b"junk",
        ]
        for index, value in enumerate(bad_raw):
            with self.subTest(index=index):
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.decode_archive(value, None)

        for decoder, encoded in (
            (
                registry.decode_entry,
                registry.encode_entry(first["entries"][0]),
            ),
            (
                registry.decode_manifest,
                registry.encode_manifest(first["manifest"]),
            ),
        ):
            for bad in (
                None,
                bytearray(encoded),
                PoisonBytes(encoded),
                encoded[:-1],
                encoded + b"\x00",
            ):
                with self.subTest(
                    decoder=decoder.__name__,
                    kind=type(bad).__name__,
                ):
                    with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                        decoder(bad)

        poisoned_entry = {
            **first["entries"][0],
            "entry_sha256": PoisonBytes(digest(0xD0)),
        }
        poisoned_manifest = {
            **first["manifest"],
            "manifest_sha256": PoisonBytes(digest(0xD0)),
        }
        for validator, value in (
            (registry.validate_entry, poisoned_entry),
            (registry.encode_entry, poisoned_entry),
            (registry.validate_manifest, poisoned_manifest),
            (registry.encode_manifest, poisoned_manifest),
        ):
            with self.subTest(validator=validator.__name__):
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    validator(value)

        fixture = registry.reference_inputs()
        poisoned_metadata = {
            **fixture["metadata1"],
            "challenge_sha256": PoisonBytes(digest(0xD0)),
        }
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.encode_archive(
                None,
                poisoned_metadata,
                fixture["entries1"],
            )
        poisoned_inputs = copy.deepcopy(fixture["entries1"])
        poisoned_inputs[0]["payload"] = PoisonBytes(poisoned_inputs[0]["payload"])
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.encode_archive(
                None,
                fixture["metadata1"],
                poisoned_inputs,
            )

        class DictSubclass(dict[str, Any]):
            pass

        class ListSubclass(list[registry.Record]):
            pass

        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.validate_entry(DictSubclass(first["entries"][0]))
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.encode_archive(
                None,
                fixture["metadata1"],
                ListSubclass(fixture["entries1"]),
            )

        mutations: dict[str, Any] = {
            "archive_sha256": digest(0xD1),
            "archive_bytes": first["archive_bytes"][:-1],
            "manifest": {
                **first["manifest"],
                "request_epoch": 24,
            },
            "entries": first["entries"][:-1],
            "payloads": first["payloads"][:-1],
            "entry_table": first["entry_table"][:-1],
            "payload_pack": first["payload_pack"][:-1],
        }
        for field, value in mutations.items():
            with self.subTest(field=field):
                altered = {**first, field: value}
                with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
                    registry.validate_decoded_archive(altered)

        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.validate_decoded_archive({**first, "extra": True})

        integer_bool = copy.deepcopy(first)
        integer_bool["entries"][0]["completed"] = 1
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.validate_decoded_archive(integer_bool)

        mutable_payload = copy.deepcopy(first)
        mutable_payload["payloads"][0] = bytearray(
            mutable_payload["payloads"][0],
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.validate_decoded_archive(mutable_payload)

        non_string_key = copy.deepcopy(first)
        non_string_key["manifest"][1] = non_string_key["manifest"].pop(
            "request_epoch",
        )
        with self.assertRaises(registry.GeneratedMediaOutputRegistryError):
            registry.validate_decoded_archive(non_string_key)

        canonical = registry.validate_decoded_archive(first)
        self.assertEqual(canonical, first)
        self.assertIsNot(canonical, first)
        self.assertIsNot(canonical["manifest"], first["manifest"])
        self.assertIsNot(canonical["entries"], first["entries"])
        self.assertIsNot(canonical["entries"][0], first["entries"][0])
        self.assertIsNot(canonical["payloads"], first["payloads"])


if __name__ == "__main__":
    unittest.main()
