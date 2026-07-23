from __future__ import annotations

import unittest

from bench import media_contract as media
from bench import media_processor_state as processor


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def state_plan(
    kind: int,
    generation: int,
    previous_state_sha256: bytes,
    stream_key: int,
    timeline: tuple[int, int],
    seed: int,
) -> dict[str, object]:
    return {
        "kind": kind,
        "request_epoch": 24_000,
        "generation": generation,
        "stream_key": stream_key,
        "timeline_numerator": timeline[0],
        "timeline_denominator": timeline[1],
        "media_object_sha256": digest(seed),
        "processor_plan_sha256": digest(seed + 1),
        "previous_state_sha256": previous_state_sha256,
        "challenge_sha256": digest(0x72),
        "cache_content_sha256": digest(seed + 2 + generation),
        "output_chain_sha256": digest(seed + 4 + generation),
        "ownership_receipt_sha256": digest(seed + 6 + generation),
        "decoder_state_sha256": digest(seed + 8),
    }


def generation_states(
    generation: int,
    previous: dict[str, object] | None = None,
) -> list[dict[str, object]]:
    prior_roots = (
        [state["state_sha256"] for state in previous["states"]]
        if previous is not None
        else [processor.ZERO_DIGEST] * processor.PROCESSOR_COUNT
    )
    return [
        processor.make_image_state(
            state_plan(
                media.IMAGE,
                generation,
                prior_roots[0],
                24_100,
                (0, 1),
                0x10,
            ),
            generation,
            4,
            4,
            4,
            2,
            2,
            3,
        ),
        processor.make_audio_state(
            state_plan(
                media.AUDIO,
                generation,
                prior_roots[1],
                24_200,
                (1, 48_000),
                0x30,
            ),
            generation,
            48_000,
            1,
            400,
            160,
            80,
            2,
        ),
        processor.make_video_state(
            state_plan(
                media.VIDEO,
                generation,
                prior_roots[2],
                24_300,
                (1, 120),
                0x50,
            ),
            2,
            128,
            0,
            generation,
            0,
        ),
    ]


def generation_bundle(
    generation: int,
    previous: dict[str, object] | None = None,
) -> bytes:
    states = generation_states(generation, previous)
    sync = processor.make_sync_state(
        states,
        {
            "generation": generation,
            "request_epoch": 24_000,
            "master_ticks_per_second": 48_000,
            "maximum_skew_ticks": 400,
            "challenge_sha256": digest(0x72),
            "sync_policy_sha256": digest(0x99),
            "previous_sync_sha256": (
                previous["sync"]["sync_sha256"]
                if previous is not None
                else processor.ZERO_DIGEST
            ),
        },
    )
    return processor.encode_bundle(states, sync)


def reroot_bundle(
    previous: dict[str, object],
    states: list[dict[str, object]],
) -> dict[str, object]:
    sync = processor.make_sync_state(
        states,
        {
            "generation": 2,
            "request_epoch": 24_000,
            "master_ticks_per_second": 48_000,
            "maximum_skew_ticks": 400,
            "challenge_sha256": digest(0x72),
            "sync_policy_sha256": digest(0x99),
            "previous_sync_sha256": previous["sync"]["sync_sha256"],
        },
    )
    return processor.decode_bundle(processor.encode_bundle(states, sync))


class MediaProcessorStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.first = processor.decode_bundle(generation_bundle(1))
        self.second_wire = generation_bundle(2, self.first)
        self.second = processor.decode_bundle(self.second_wire)

    def test_shared_golden_and_successor(self) -> None:
        self.assertEqual(
            self.second["bundle_sha256"].hex(),
            "51a723cbb2919db803a865eb971d080e"
            "4a66df8f791ea4d50be35de7192c8609",
        )
        processor.validate_successor(self.first, self.second)
        self.assertEqual(self.second["states"][0]["cursor_units"], 2)
        self.assertEqual(self.second["states"][1]["produced_units"], 2)
        self.assertEqual(self.second["states"][2]["cache_entries"], 2)
        self.assertEqual(self.second["sync"]["audio_end_tick"], 560)
        self.assertEqual(self.second["sync"]["video_end_tick"], 800)
        self.assertEqual(self.second["sync"]["watermark_tick"], 560)

    def test_every_bundle_byte_mutation_rejects(self) -> None:
        for index in range(len(self.second_wire)):
            with self.subTest(index=index):
                corrupted = bytearray(self.second_wire)
                corrupted[index] ^= 1
                with self.assertRaises(
                    processor.MediaProcessorStateError
                ):
                    processor.decode_bundle(bytes(corrupted))

    def test_rehashed_lineage_and_cache_replay_reject(self) -> None:
        for attack in (
            "processor_substitution",
            "stale_lineage",
            "ownership_replay",
            "cache_replay",
        ):
            states = [dict(state) for state in self.second["states"]]
            states[1]["parameters"] = list(states[1]["parameters"])
            if attack == "processor_substitution":
                states[1]["processor_plan_sha256"] = digest(0xEE)
            elif attack == "stale_lineage":
                states[1]["previous_state_sha256"] = digest(0xDD)
            elif attack == "ownership_replay":
                states[1]["ownership_receipt_sha256"] = self.first[
                    "states"
                ][1]["ownership_receipt_sha256"]
            else:
                states[1]["cache_content_sha256"] = self.first["states"][1][
                    "cache_content_sha256"
                ]
            states[1]["state_sha256"] = processor.state_root(states[1])
            forged = reroot_bundle(self.first, states)
            with self.subTest(attack=attack), self.assertRaises(
                processor.MediaProcessorStateError
            ):
                processor.validate_successor(self.first, forged)

    def test_rehashed_audio_window_skip_rejects(self) -> None:
        states = [dict(state) for state in self.second["states"]]
        states[1] = processor.make_audio_state(
            {
                **state_plan(
                    media.AUDIO,
                    2,
                    self.first["states"][1]["state_sha256"],
                    24_200,
                    (1, 48_000),
                    0x30,
                ),
            },
            3,
            48_000,
            1,
            400,
            160,
            80,
            2,
        )
        forged = reroot_bundle(self.first, states)
        with self.assertRaises(processor.MediaProcessorStateError):
            processor.validate_successor(self.first, forged)

    def test_non_integral_time_mapping_rejects(self) -> None:
        states = generation_states(1)
        states[2] = dict(states[2])
        states[2]["timeline_denominator"] = 121
        states[2]["state_sha256"] = processor.state_root(states[2])
        with self.assertRaises(processor.MediaProcessorStateError):
            processor.make_sync_state(
                states,
                {
                    "generation": 1,
                    "request_epoch": 24_000,
                    "master_ticks_per_second": 48_000,
                    "maximum_skew_ticks": 400,
                    "challenge_sha256": digest(0x72),
                    "sync_policy_sha256": digest(0x99),
                },
            )


if __name__ == "__main__":
    unittest.main()
