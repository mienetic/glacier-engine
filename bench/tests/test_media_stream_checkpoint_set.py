from __future__ import annotations

import hashlib
import unittest

from bench import continuation_checkpoint_file as archive
from bench import media_contract as media
from bench import media_decode_fixture as fixture
from bench import media_runtime_lease as lease
from bench import media_stream_checkpoint_set as checkpoint_set
from bench import media_stream_continuation as continuation
from bench import media_stream_runtime as stream
from bench import media_transform as transform


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def bundle_fixture() -> tuple[bytes, list[dict[str, object]]]:
    streams = [
        {
            "kind": media.IMAGE,
            "checkpoint_sha256": digest(0x11),
            "outputs": [
                {
                    "chunk_index": 0,
                    "output": b"image-0",
                    "output_sha256": hashlib.sha256(
                        b"image-0"
                    ).digest(),
                    "chunk_receipt_sha256": digest(0x31),
                },
                {
                    "chunk_index": 1,
                    "output": b"image-1",
                    "output_sha256": hashlib.sha256(
                        b"image-1"
                    ).digest(),
                    "chunk_receipt_sha256": digest(0x32),
                },
            ],
        },
        {
            "kind": media.AUDIO,
            "checkpoint_sha256": digest(0x12),
            "outputs": [
                {
                    "chunk_index": 0,
                    "output": b"audio-0",
                    "output_sha256": hashlib.sha256(
                        b"audio-0"
                    ).digest(),
                    "chunk_receipt_sha256": digest(0x41),
                }
            ],
        },
        {
            "kind": media.VIDEO,
            "checkpoint_sha256": digest(0x13),
            "outputs": [
                {
                    "chunk_index": 0,
                    "output": b"video-0",
                    "output_sha256": hashlib.sha256(
                        b"video-0"
                    ).digest(),
                    "chunk_receipt_sha256": digest(0x51),
                }
            ],
        },
    ]
    encoded = checkpoint_set.encode_bundle(
        {
            "generation": 2,
            "request_epoch": 7000,
            "challenge_sha256": digest(0xC7),
        },
        streams,
    )
    return encoded, streams


def stream_generations(
    stream_index: int,
) -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
    list[bytes],
]:
    spec = (
        fixture.image_spec(),
        fixture.audio_spec(),
        fixture.video_spec(),
    )[stream_index]
    encoded_fixture = fixture.encode_fixture(spec)
    parsed = fixture.parse_fixture(encoded_fixture)
    decode_plan = fixture.make_decode_plan(
        parsed,
        digest(0xD1),
        digest(0xE1),
    )
    encoded_decode_plan = fixture.encode_plan(decode_plan)
    decoded = bytearray(len(spec["payload"]))
    decode_receipt = fixture.decode_fixture(
        encoded_fixture,
        encoded_decode_plan,
        decoded,
    )
    state: dict[str, object] | None = None
    executions: list[dict[str, object]] = []
    chunks: list[dict[str, object]] = []
    outputs: list[bytes] = []
    checkpoints: list[dict[str, object]] = []
    previous_chunk = stream.ZERO_DIGEST
    previous_checkpoint = continuation.ZERO_DIGEST
    for chunk_index in range(3):
        if stream_index == 0:
            plan = transform.make_image_plan(
                parsed,
                decode_receipt,
                0,
                chunk_index % 2,
                2,
                1,
                2,
                1,
                1,
                1,
                digest(0xF1),
                digest(0xF2),
            )
        elif stream_index == 1:
            plan = transform.make_audio_plan(
                parsed,
                decode_receipt,
                (chunk_index % 2) * 3,
                3,
                16_000,
                1,
                0,
                1,
                digest(0xF1),
                digest(0xF2),
            )
        else:
            plan = transform.make_video_plan(
                parsed,
                decode_receipt,
                (chunk_index % 2,),
                digest(0xF1),
                digest(0xF2),
            )
        if state is None:
            state = media.initialize_publication_state(
                15_000,
                1,
                (1, 1)
                if stream_index == 0
                else plan["target_time_base"],
                parsed["media_object_sha256"],
                digest(0xA0 + stream_index),
            )
        encoded_plan = transform.encode_plan(plan)
        output = bytearray(plan["output_bytes"])
        transform_receipt, mappings = transform.execute(
            encoded_fixture,
            encoded_decode_plan,
            encoded_plan,
            output,
        )
        state_before = dict(state)
        execution, state = lease.build_execution_receipt(
            state_before,
            encoded_fixture,
            encoded_plan,
            transform_receipt,
            bytes(output),
            mappings,
            16_000 + stream_index,
            16_100 + stream_index * 100 + chunk_index,
            16_110 + stream_index * 100 + chunk_index,
            16_120 + stream_index * 100 + chunk_index,
            16_130 + stream_index,
            chunk_index,
            1,
        )
        chunk = stream.make_chunk_receipt(
            state_before,
            16_200 + stream_index,
            chunk_index,
            previous_chunk,
            execution,
        )
        executions.append(execution)
        chunks.append(chunk)
        outputs.append(bytes(output))
        generation = chunk_index + 1
        generation_base = (
            17_000
            if generation == 1
            else 18_000
            if generation == 2
            else 19_000
        ) + stream_index * 100
        checkpoint = continuation.make_checkpoint(
            state,
            (media.IMAGE, media.AUDIO, media.VIDEO)[stream_index],
            16_200 + stream_index,
            {
                "checkpoint_generation": generation,
                "chunk_limit": 4,
                "restore_bank_epoch": generation_base,
                "restore_owner_key_base": generation_base + 10,
                "restore_tree_key_base": generation_base + 20,
                "restore_authority_key_base": generation_base + 30,
                "next_owner_key_base": generation_base + 40,
                "next_tree_key_base": generation_base + 50,
                "next_authority_key_base": generation_base + 60,
                "tenant_key": 16_130 + stream_index,
                "challenge_sha256": digest(0x72),
                "previous_checkpoint_sha256": previous_checkpoint,
            },
            executions,
            chunks,
            outputs,
        )
        checkpoints.append(checkpoint)
        previous_chunk = chunk["receipt_sha256"]
        previous_checkpoint = checkpoint["checkpoint_sha256"]
    return checkpoints[0], checkpoints[1], checkpoints[2], outputs


def checkpoint_generations() -> tuple[bytes, bytes]:
    first_streams: list[dict[str, object]] = []
    second_streams: list[dict[str, object]] = []
    for stream_index in range(checkpoint_set.STREAM_COUNT):
        first, second, _third, outputs = stream_generations(
            stream_index
        )
        first_streams.append(
            {
                "checkpoint": first,
                "retained_outputs": outputs[:1],
            }
        )
        second_streams.append(
            {
                "checkpoint": second,
                "retained_outputs": outputs[:2],
            }
        )
    first_set = checkpoint_set.encode_set(
        first_streams,
        checkpoint_set.ZERO_DIGEST,
    )
    second_set = checkpoint_set.encode_set(
        second_streams,
        archive.decode_set(first_set)["checkpoint_sha256"],
    )
    return first_set, second_set


def restored_checkpoint_generations() -> tuple[bytes, bytes]:
    second_streams: list[dict[str, object]] = []
    third_streams: list[dict[str, object]] = []
    for stream_index in range(checkpoint_set.STREAM_COUNT):
        _first, second, direct_third, outputs = stream_generations(
            stream_index
        )
        restored_third = dict(direct_third)
        entries = [dict(entry) for entry in direct_third["entries"]]
        for index, entry in enumerate(entries):
            entry["source_bank_epoch"] = second["restore_bank_epoch"]
            if index < len(second["entries"]):
                prior = second["entries"][index]
                entry["source_owner_key"] = prior["restore_owner_key"]
                entry["parent_claim"] = prior["parent_claim"]
                entry["output_claim"] = prior["output_claim"]
                entry["publication_next_sequence"] = prior[
                    "publication_next_sequence"
                ]
                entry["lease_receipt_sha256"] = (
                    continuation.restored_ownership_receipt_root(
                        second["checkpoint_sha256"],
                        prior,
                        entry,
                    )
                )
            else:
                entry["source_owner_key"] = second[
                    "next_owner_key_base"
                ]
        restored_third["entries"] = entries
        restored_third["retained_manifest_sha256"] = (
            continuation.retained_manifest_root(entries)
        )
        restored_third["checkpoint_sha256"] = (
            continuation.checkpoint_root(restored_third)
        )
        second_streams.append(
            {
                "checkpoint": second,
                "retained_outputs": outputs[:2],
            }
        )
        third_streams.append(
            {
                "checkpoint": restored_third,
                "retained_outputs": outputs,
            }
        )
    second_set = checkpoint_set.encode_set(
        second_streams,
        digest(0x91),
    )
    third_set = checkpoint_set.encode_set(
        third_streams,
        archive.decode_set(second_set)["checkpoint_sha256"],
    )
    return second_set, third_set


class MediaStreamCheckpointSetTests(unittest.TestCase):
    def test_bundle_round_trip_and_native_golden_root(self) -> None:
        encoded, _streams = bundle_fixture()
        decoded = checkpoint_set.decode_bundle(encoded)
        self.assertEqual(decoded["generation"], 2)
        self.assertEqual(len(decoded["outputs"]), 4)
        self.assertEqual(decoded["outputs"][1]["output"], b"image-1")
        self.assertEqual(
            decoded["bundle_sha256"].hex(),
            "3a2aa313d1afdbcd650c68e42700ed9e"
            "baa2032208459334d3a145edb7911314",
        )

    def test_every_bundle_byte_mutation_rejects(self) -> None:
        encoded, _streams = bundle_fixture()
        for index in range(len(encoded)):
            with self.subTest(index=index):
                corrupted = bytearray(encoded)
                corrupted[index] ^= 1
                with self.assertRaises(
                    checkpoint_set.MediaStreamCheckpointSetError
                ):
                    checkpoint_set.decode_bundle(bytes(corrupted))

    def test_output_substitution_rejects_before_encoding(self) -> None:
        _encoded, streams = bundle_fixture()
        streams[2]["outputs"][0]["output"] = b"foreign"
        with self.assertRaises(
            checkpoint_set.MediaStreamCheckpointSetError
        ):
            checkpoint_set.encode_bundle(
                {
                    "generation": 2,
                    "request_epoch": 7000,
                    "challenge_sha256": digest(0xC7),
                },
                streams,
            )

    def test_multimodal_successor_preserves_every_retained_output(
        self,
    ) -> None:
        first_wire, second_wire = checkpoint_generations()
        first = checkpoint_set.decode_set(first_wire)
        second = checkpoint_set.decode_set(second_wire)
        checkpoint_set.validate_successor(first, second)
        self.assertEqual(first["archive"]["metadata"]["generation"], 1)
        self.assertEqual(second["archive"]["metadata"]["generation"], 2)
        self.assertEqual(len(first["bundle"]["outputs"]), 3)
        self.assertEqual(len(second["bundle"]["outputs"]), 6)
        self.assertEqual(
            second["archive"]["metadata"]["parent_checkpoint_sha256"],
            first["archive"]["checkpoint_sha256"],
        )

    def test_post_restore_successor_rebinds_every_stream(self) -> None:
        second_wire, third_wire = restored_checkpoint_generations()
        second = checkpoint_set.decode_set(second_wire)
        third = checkpoint_set.decode_set(third_wire)
        checkpoint_set.validate_restored_successor(second, third)
        self.assertEqual(third["archive"]["metadata"]["generation"], 3)
        self.assertEqual(len(third["bundle"]["outputs"]), 9)
        for old, new in zip(
            second["checkpoints"],
            third["checkpoints"],
        ):
            self.assertNotEqual(
                new["restore_bank_epoch"],
                old["restore_bank_epoch"],
            )
            for index, entry in enumerate(new["entries"]):
                self.assertEqual(
                    entry["source_bank_epoch"],
                    old["restore_bank_epoch"],
                )
                if index < len(old["entries"]):
                    self.assertEqual(
                        entry["source_owner_key"],
                        old["entries"][index]["restore_owner_key"],
                    )
                else:
                    self.assertEqual(
                        entry["source_owner_key"],
                        old["next_owner_key_base"],
                    )

    def test_rehashed_stale_restored_authority_rejects(self) -> None:
        second_wire, third_wire = restored_checkpoint_generations()
        second = checkpoint_set.decode_set(second_wire)
        third = checkpoint_set.decode_set(third_wire)

        for attack in ("stale_epoch", "receipt_replay", "foreign_owner"):
            streams: list[dict[str, object]] = []
            for stream_index, (old, checkpoint) in enumerate(
                zip(second["checkpoints"], third["checkpoints"])
            ):
                forged = dict(checkpoint)
                entries = [dict(entry) for entry in checkpoint["entries"]]
                if attack == "stale_epoch":
                    for entry in entries:
                        entry["source_bank_epoch"] += 10_000
                    for index, prior in enumerate(old["entries"]):
                        entries[index]["lease_receipt_sha256"] = (
                            continuation.restored_ownership_receipt_root(
                                old["checkpoint_sha256"],
                                prior,
                                entries[index],
                            )
                        )
                elif attack == "receipt_replay":
                    entries[0]["lease_receipt_sha256"] = old["entries"][0][
                        "lease_receipt_sha256"
                    ]
                else:
                    entries[0]["source_owner_key"] += 1
                    entries[0]["lease_receipt_sha256"] = (
                        continuation.restored_ownership_receipt_root(
                            old["checkpoint_sha256"],
                            old["entries"][0],
                            entries[0],
                        )
                    )
                forged["entries"] = entries
                forged["retained_manifest_sha256"] = (
                    continuation.retained_manifest_root(entries)
                )
                forged["checkpoint_sha256"] = (
                    continuation.checkpoint_root(forged)
                )
                outputs = [
                    entry["output"]
                    for entry in third["bundle"]["outputs"]
                    if entry["kind"] == checkpoint_set.KINDS[stream_index]
                ]
                streams.append(
                    {
                        "checkpoint": forged,
                        "retained_outputs": outputs,
                    }
                )
            forged_wire = checkpoint_set.encode_set(
                streams,
                second["archive"]["checkpoint_sha256"],
            )
            forged_set = checkpoint_set.decode_set(forged_wire)
            checkpoint_set.validate_successor(second, forged_set)
            with self.subTest(attack=attack), self.assertRaises(
                checkpoint_set.MediaStreamCheckpointSetError
            ):
                checkpoint_set.validate_restored_successor(
                    second,
                    forged_set,
                )

    def test_foreign_rehashed_bundle_root_rejects(self) -> None:
        _first_wire, second_wire = checkpoint_generations()
        decoded = archive.decode_set(second_wire)
        objects = [dict(entry) for entry in decoded["objects"]]
        bundle = checkpoint_set.decode_bundle(objects[-1]["bytes"])
        foreign_streams: list[dict[str, object]] = []
        for stream_index, kind in enumerate(checkpoint_set.KINDS):
            foreign_streams.append(
                {
                    "kind": kind,
                    "checkpoint_sha256": (
                        digest(0xEE)
                        if stream_index == 1
                        else bundle["checkpoint_sha256"][stream_index]
                    ),
                    "outputs": [
                        {
                            "chunk_index": entry["chunk_index"],
                            "output": entry["output"],
                            "output_sha256": entry["output_sha256"],
                            "chunk_receipt_sha256": entry[
                                "chunk_receipt_sha256"
                            ],
                        }
                        for entry in bundle["outputs"]
                        if entry["kind"] == kind
                    ],
                }
            )
        objects[-1]["bytes"] = checkpoint_set.encode_bundle(
            {
                "generation": bundle["generation"],
                "request_epoch": bundle["request_epoch"],
                "challenge_sha256": bundle["challenge_sha256"],
            },
            foreign_streams,
        )
        rerooted = archive.encode_set(decoded["metadata"], objects)
        with self.assertRaises(
            checkpoint_set.MediaStreamCheckpointSetError
        ):
            checkpoint_set.decode_set(rerooted)


if __name__ == "__main__":
    unittest.main()
