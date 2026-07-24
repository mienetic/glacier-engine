from __future__ import annotations

import unittest
from typing import Any

from bench import generated_media_checkpoint as media
from bench import generated_media_payload_archive as payload_archive


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def rehash_manifest(
    value: payload_archive.Record,
    **changes: Any,
) -> payload_archive.Record:
    manifest = {
        **value,
        **changes,
        "manifest_sha256": payload_archive.ZERO,
    }
    manifest["manifest_sha256"] = payload_archive.manifest_root(manifest)
    return payload_archive.validate_manifest(manifest)


def rehash_checkpoint(
    value: payload_archive.Record,
    **changes: Any,
) -> payload_archive.Record:
    checkpoint = {
        **value,
        **changes,
        "checkpoint_sha256": media.ZERO,
    }
    checkpoint["checkpoint_sha256"] = media._root(
        media.CHECKPOINT_DOMAIN,
        media._checkpoint_body(checkpoint),
    )
    return media.validate_checkpoint(checkpoint)


def rehash_member(
    value: payload_archive.Record,
    **changes: Any,
) -> payload_archive.Record:
    member = {
        **value,
        **changes,
        "member_sha256": media.ZERO,
    }
    member["member_sha256"] = media._root(
        media.MEMBER_DOMAIN,
        media._member_body(member),
    )
    return media.validate_member(member)


def repack(
    base: payload_archive.Record,
    *,
    manifest: payload_archive.Record | None = None,
    checkpoint: payload_archive.Record | None = None,
    image_member: payload_archive.Record | None = None,
    audio_member: payload_archive.Record | None = None,
    video_member: payload_archive.Record | None = None,
    image_payload: bytes | None = None,
    audio_payload: bytes | None = None,
    video_payload: bytes | None = None,
) -> payload_archive.Record:
    selected_manifest = manifest or base["manifest"]
    selected_checkpoint = checkpoint or base["checkpoint"]
    selected_image = image_member or base["image_member"]
    selected_audio = audio_member or base["audio_member"]
    selected_video = video_member or base["video_member"]
    selected_image_payload = (
        base["image_payload"] if image_payload is None else image_payload
    )
    selected_audio_payload = (
        base["audio_payload"] if audio_payload is None else audio_payload
    )
    selected_video_payload = (
        base["video_payload"] if video_payload is None else video_payload
    )
    current_set = payload_archive._decode_set(base["archive_bytes"])
    current_objects = current_set["objects"]
    objects = (
        (
            payload_archive.MANIFEST_OBJECT_ORDINAL,
            payload_archive.MANIFEST_ABI,
            payload_archive.encode_manifest(selected_manifest),
        ),
        (
            payload_archive.CHECKPOINT_OBJECT_ORDINAL,
            media.CHECKPOINT_ABI,
            media.encode_checkpoint(selected_checkpoint),
        ),
        (
            payload_archive.IMAGE_MEMBER_OBJECT_ORDINAL,
            media.MEMBER_ABI,
            media.encode_member(selected_image),
        ),
        (
            payload_archive.AUDIO_MEMBER_OBJECT_ORDINAL,
            media.MEMBER_ABI,
            media.encode_member(selected_audio),
        ),
        (
            payload_archive.VIDEO_MEMBER_OBJECT_ORDINAL,
            media.MEMBER_ABI,
            media.encode_member(selected_video),
        ),
        (
            payload_archive.IMAGE_PAYLOAD_OBJECT_ORDINAL,
            current_objects[payload_archive.IMAGE_PAYLOAD_OBJECT_ORDINAL][
                "abi_version"
            ],
            selected_image_payload,
        ),
        (
            payload_archive.AUDIO_PAYLOAD_OBJECT_ORDINAL,
            current_objects[payload_archive.AUDIO_PAYLOAD_OBJECT_ORDINAL][
                "abi_version"
            ],
            selected_audio_payload,
        ),
        (
            payload_archive.VIDEO_PAYLOAD_OBJECT_ORDINAL,
            current_objects[payload_archive.VIDEO_PAYLOAD_OBJECT_ORDINAL][
                "abi_version"
            ],
            selected_video_payload,
        ),
    )
    raw = payload_archive._encode_set(
        generation=selected_manifest["generation"],
        request_epoch=selected_manifest["request_epoch"],
        publication_next_sequence=selected_manifest["publication_sequence"] + 1,
        parent_archive_sha256=current_set["parent_archive_sha256"],
        challenge_sha256=selected_manifest["challenge_sha256"],
        objects=objects,
    )
    return {
        "archive_sha256": raw[-payload_archive.SET_FOOTER_BYTES :],
        "archive_bytes": raw,
        "manifest": selected_manifest,
        "checkpoint": selected_checkpoint,
        "image_member": selected_image,
        "audio_member": selected_audio,
        "video_member": selected_video,
        "image_payload": selected_image_payload,
        "audio_payload": selected_audio_payload,
        "video_payload": selected_video_payload,
    }


class GeneratedMediaPayloadArchiveTests(unittest.TestCase):
    def test_golden_roots_and_every_wire_byte_are_canonical(self) -> None:
        archives = payload_archive.reference_archives()
        first = archives["first"]
        second = archives["second"]
        expected = {
            "first_manifest": (
                first["manifest"]["manifest_sha256"],
                "8c9c6294745a061d0da7c41268546db29063e92dba671c22e2ef79e90731d3dd",
            ),
            "first_archive": (
                first["archive_sha256"],
                "61f28f9e079827f2014d98b923f4334ec5f7c538ccf1c64c4afcf78f8362ab95",
            ),
            "second_manifest": (
                second["manifest"]["manifest_sha256"],
                "4035107bbe18c3310ca5977234dc8838841fc7f09cc1f8c18965a05de3ad2dec",
            ),
            "second_archive": (
                second["archive_sha256"],
                "d34d628564228dfdea53fd3f489691a2a1a29afe9dac44f1c6cf5df0a9cfd907",
            ),
        }
        for name, (actual, root) in expected.items():
            with self.subTest(name=name):
                self.assertEqual(actual.hex(), root)

        manifest_wire = payload_archive.encode_manifest(first["manifest"])
        self.assertEqual(
            payload_archive.decode_manifest(manifest_wire),
            first["manifest"],
        )
        for index in range(len(manifest_wire)):
            with self.subTest(kind="manifest", index=index):
                mutated = bytearray(manifest_wire)
                mutated[index] ^= 1
                with self.assertRaises(
                    payload_archive.GeneratedMediaPayloadArchiveError
                ):
                    payload_archive.decode_manifest(bytes(mutated))

        archive_wire = first["archive_bytes"]
        self.assertEqual(
            payload_archive.decode_archive(archive_wire, None),
            first,
        )
        for index in range(len(archive_wire)):
            with self.subTest(kind="archive", index=index):
                mutated = bytearray(archive_wire)
                mutated[index] ^= 1
                with self.assertRaises(
                    payload_archive.GeneratedMediaPayloadArchiveError
                ):
                    payload_archive.decode_archive(bytes(mutated), None)

    def test_exact_payload_objects_abis_and_lineage(self) -> None:
        archives = payload_archive.reference_archives()
        first = archives["first"]
        second = archives["second"]
        self.assertEqual(
            second["image_payload"],
            b"image-envelope-generation-two",
        )
        self.assertEqual(
            second["audio_payload"],
            b"audio-envelope-generation-two",
        )
        self.assertEqual(
            second["video_payload"],
            b"video-envelope-generation-two",
        )
        decoded_set = payload_archive._decode_set(second["archive_bytes"])
        self.assertEqual(
            (
                decoded_set["objects"][payload_archive.IMAGE_PAYLOAD_OBJECT_ORDINAL][
                    "abi_version"
                ],
                decoded_set["objects"][payload_archive.AUDIO_PAYLOAD_OBJECT_ORDINAL][
                    "abi_version"
                ],
                decoded_set["objects"][payload_archive.VIDEO_PAYLOAD_OBJECT_ORDINAL][
                    "abi_version"
                ],
            ),
            (1, 2, 3),
        )
        self.assertEqual(
            decoded_set["parent_archive_sha256"],
            first["archive_sha256"],
        )
        self.assertEqual(
            second["manifest"]["previous_manifest_sha256"],
            first["manifest"]["manifest_sha256"],
        )
        self.assertEqual(
            payload_archive.decode_archive(
                second["archive_bytes"],
                first,
            ),
            second,
        )
        self.assertEqual(
            payload_archive.validate_decoded_archive(second),
            second,
        )
        with self.assertRaises(ValueError):
            payload_archive.decode_archive(second["archive_bytes"], None)

        alternate = payload_archive.encode_archive(
            None,
            first["checkpoint"],
            first["image_member"],
            first["audio_member"],
            first["video_member"],
            {
                "encoding_abi": first["manifest"]["image_encoding_abi"],
                "bytes": b"alternate-image-envelope-generation-one",
                "encoder_implementation_sha256": first["manifest"][
                    "image_encoder_implementation_sha256"
                ],
                "format_sha256": first["manifest"]["image_format_sha256"],
            },
            {
                "encoding_abi": first["manifest"]["audio_encoding_abi"],
                "bytes": first["audio_payload"],
                "encoder_implementation_sha256": first["manifest"][
                    "audio_encoder_implementation_sha256"
                ],
                "format_sha256": first["manifest"]["audio_format_sha256"],
            },
            {
                "encoding_abi": first["manifest"]["video_encoding_abi"],
                "bytes": first["video_payload"],
                "encoder_implementation_sha256": first["manifest"][
                    "video_encoder_implementation_sha256"
                ],
                "format_sha256": first["manifest"]["video_format_sha256"],
            },
        )
        with self.assertRaises(ValueError):
            payload_archive.decode_archive(
                second["archive_bytes"],
                alternate,
            )

    def test_junk_nonbytes_and_altered_decoded_fields_fail(self) -> None:
        first = payload_archive.reference_archives()["first"]
        alterations: dict[str, Any] = {
            "archive_sha256": digest(0xA1),
            "archive_bytes": bytes((first["archive_bytes"][0] ^ 1,))
            + first["archive_bytes"][1:],
            "manifest": {
                **first["manifest"],
                "request_epoch": first["manifest"]["request_epoch"] + 1,
            },
            "checkpoint": {
                **first["checkpoint"],
                "request_epoch": first["checkpoint"]["request_epoch"] + 1,
            },
            "image_member": {
                **first["image_member"],
                "byte_count": first["image_member"]["byte_count"] + 1,
            },
            "audio_member": {
                **first["audio_member"],
                "byte_count": first["audio_member"]["byte_count"] + 1,
            },
            "video_member": {
                **first["video_member"],
                "byte_count": first["video_member"]["byte_count"] + 1,
            },
            "image_payload": first["image_payload"] + b"x",
            "audio_payload": first["audio_payload"] + b"x",
            "video_payload": first["video_payload"] + b"x",
        }
        for field, replacement in alterations.items():
            with self.subTest(field=field):
                altered = {**first, field: replacement}
                with self.assertRaises(ValueError):
                    payload_archive.validate_decoded_archive(altered)

        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                {**first, "archive_bytes": b"junk"}
            )
        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                {**first, "archive_bytes": object()}
            )
        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive({**first, "unexpected": True})

    def test_rehashed_split_bindings_fail_closed(self) -> None:
        first = payload_archive.reference_archives()["first"]

        split_manifest = rehash_manifest(
            first["manifest"],
            request_epoch=first["manifest"]["request_epoch"] + 1,
        )
        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                repack(first, manifest=split_manifest)
            )

        split_lengths = rehash_manifest(
            first["manifest"],
            total_encoded_bytes=first["manifest"]["total_encoded_bytes"] + 1,
            image_encoded_bytes=first["manifest"]["image_encoded_bytes"] + 1,
            image_source_bytes=first["manifest"]["image_source_bytes"] + 1,
        )
        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                repack(first, manifest=split_lengths)
            )

        split_checkpoint = rehash_checkpoint(
            first["checkpoint"],
            request_epoch=first["checkpoint"]["request_epoch"] + 1,
        )
        split_checkpoint_manifest = rehash_manifest(
            first["manifest"],
            request_epoch=split_checkpoint["request_epoch"],
            checkpoint_sha256=split_checkpoint["checkpoint_sha256"],
        )
        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                repack(
                    first,
                    manifest=split_checkpoint_manifest,
                    checkpoint=split_checkpoint,
                )
            )

        foreign_scope = digest(0xB7)
        foreign_image = rehash_member(
            first["image_member"],
            tenant_scope_sha256=foreign_scope,
        )
        split_member_checkpoint = rehash_checkpoint(
            first["checkpoint"],
            tenant_scope_sha256=foreign_scope,
            image_member_sha256=foreign_image["member_sha256"],
        )
        split_member_manifest = rehash_manifest(
            first["manifest"],
            tenant_scope_sha256=foreign_scope,
            image_member_sha256=foreign_image["member_sha256"],
            checkpoint_sha256=split_member_checkpoint["checkpoint_sha256"],
        )
        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                repack(
                    first,
                    manifest=split_member_manifest,
                    checkpoint=split_member_checkpoint,
                    image_member=foreign_image,
                )
            )

        with self.assertRaises(ValueError):
            payload_archive.validate_decoded_archive(
                repack(
                    first,
                    image_payload=b"foreign-encoded-image-envelope",
                )
            )

    def test_mixed_generation_rejects(self) -> None:
        fixture = media.reference_fixture()
        archives = payload_archive.reference_archives()
        second = archives["second"]

        def payload_input(prefix: str) -> payload_archive.Record:
            return {
                "encoding_abi": second["manifest"][f"{prefix}_encoding_abi"],
                "bytes": second[f"{prefix}_payload"],
                "encoder_implementation_sha256": second["manifest"][
                    f"{prefix}_encoder_implementation_sha256"
                ],
                "format_sha256": second["manifest"][f"{prefix}_format_sha256"],
            }

        with self.assertRaises(ValueError):
            payload_archive.encode_archive(
                archives["first"],
                fixture["checkpoint2"],
                fixture["image2"],
                fixture["audio1"],
                fixture["video2"],
                payload_input("image"),
                payload_input("audio"),
                payload_input("video"),
            )


if __name__ == "__main__":
    unittest.main()
