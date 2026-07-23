from __future__ import annotations

import unittest

from bench import generated_video_display as video


class GeneratedVideoDisplayTests(unittest.TestCase):
    def test_reference_roots_and_all_wires_are_canonical(self) -> None:
        fixture = video.reference_fixture()
        expected = {
            "state0": (
                "state_sha256",
                "5a2fa2c3417d77dd46aae71913db4bd1abad51d28a8e2ae4061589d432fc0a1d",
            ),
            "manifest1": (
                "manifest_sha256",
                "918566635a8f91d7e589aaedadefd96b97b2e32f376e7d6205ba9bff6818234f",
            ),
            "provenance1": (
                "provenance_sha256",
                "3676e6357a628f1716b291b9d7296a00a3ba48039655d91146db58c156421b70",
            ),
            "result1": (
                "result_sha256",
                "60105ba224ed598e52dad97f4d4dc29500ce8eaf33288190cef63a3b560c0cba",
            ),
            "observation1": (
                "observation_sha256",
                "952814aa06bee9a61fc98316949e8aa7e10762bc3a486608df2ef6c9126e5b5f",
            ),
            "ack_plan1": (
                "plan_sha256",
                "fc945471d54fd5907a84dc3fe1e72804399e7e0ec53b3218602bf8fd92e0c53f",
            ),
            "ack1": (
                "result_sha256",
                "53e78f9aea3ee263013fbf2700ceaffc4860a6aac7883090e6b05db587b41650",
            ),
            "state4": (
                "state_sha256",
                "ca533126a1234276aa97d2748f488567e96823534f509b5e2958a76a78f23d12",
            ),
        }
        for key, (field, root) in expected.items():
            self.assertEqual(fixture[key][field].hex(), root)

        wires = (
            (fixture["state0"], video.encode_state, video.decode_state),
            (
                fixture["manifest1"],
                video.encode_manifest,
                video.decode_manifest,
            ),
            (
                fixture["provenance1"],
                video.encode_provenance,
                video.decode_provenance,
            ),
            (fixture["result1"], video.encode_result, video.decode_result),
            (
                fixture["observation1"],
                video.encode_observation,
                video.decode_observation,
            ),
            (
                fixture["ack_plan1"],
                video.encode_ack_plan,
                video.decode_ack_plan,
            ),
            (
                fixture["ack1"],
                video.encode_ack_result,
                video.decode_ack_result,
            ),
        )
        for value, encode, decode in wires:
            encoded = encode(value)
            self.assertEqual(decode(encoded), value)
            for index in range(len(encoded)):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(video.GeneratedVideoDisplayError):
                    decode(bytes(mutated))

    def test_display_acknowledgement_gates_successor_segment(self) -> None:
        fixture = video.reference_fixture()
        state1 = fixture["state1"]
        self.assertEqual(state1["pending"], 1)
        self.assertEqual(state1["visible_segments"], 1)
        self.assertEqual(state1["visible_frames"], 2)
        self.assertEqual(state1["visible_end_tick"], 5)
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.make_manifest(
                state1,
                first_duration_ticks=4,
                second_duration_ticks=1,
                source_output_bytes=2,
                source_result_sha256=video.sha256("blocked result"),
                source_output_sha256=video.sha256("blocked output"),
                media_object_sha256=video.sha256("blocked media"),
                first_frame_sha256=video.sha256("blocked frame zero"),
                second_frame_sha256=video.sha256("blocked frame one"),
            )

        state4 = fixture["state4"]
        self.assertEqual(state4["generation"], 4)
        self.assertEqual(state4["visible_segments"], 2)
        self.assertEqual(state4["visible_frames"], 4)
        self.assertEqual(state4["visible_end_tick"], 10)
        self.assertEqual(state4["displayed_segments"], 2)
        self.assertEqual(state4["displayed_frames"], 4)
        self.assertEqual(state4["displayed_end_tick"], 10)
        self.assertEqual(state4["display_sequence"], 2)
        self.assertEqual(state4["pending"], 0)
        self.assertEqual(fixture["output1"], b"\x03" * 4 + b"\x07" * 4)
        self.assertEqual(fixture["output2"], b"\x0b" * 4 + b"\x0d" * 4)

    def test_partial_foreign_and_duplicate_display_receipts_fail(self) -> None:
        fixture = video.reference_fixture()
        state1 = fixture["state1"]
        result1 = fixture["result1"]
        observation1 = fixture["observation1"]

        partial = {
            **observation1,
            "consumed_frames": observation1["consumed_frames"] - 1,
            "observation_sha256": video.ZERO,
        }
        partial["observation_sha256"] = video._root(
            video.OBSERVATION_DOMAIN,
            video._observation_body(partial),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.make_ack_plan(state1, result1, partial)

        impossible_observation = {
            **observation1,
            "display_sequence": observation1["display_sequence"] + 1,
            "observation_sha256": video.ZERO,
        }
        impossible_observation["observation_sha256"] = video._root(
            video.OBSERVATION_DOMAIN,
            video._observation_body(impossible_observation),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.validate_observation(impossible_observation)

        foreign = {
            **result1,
            "output_sha256": video.sha256("foreign output"),
            "result_sha256": video.ZERO,
        }
        foreign["result_sha256"] = video._root(
            video.RESULT_DOMAIN,
            video._result_body(foreign),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.make_ack_plan(state1, foreign, observation1)

        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.make_observation(
                fixture["state2"],
                sink_implementation_sha256=video.sha256("sink"),
                sink_instance_sha256=video.sha256("instance"),
            )

    def test_manifest_binds_frames_media_resources_and_provenance(self) -> None:
        fixture = video.reference_fixture()
        impossible_state = {
            **fixture["state0"],
            "generation": fixture["state0"]["generation"] + 1,
            "state_sha256": video.ZERO,
        }
        impossible_state["state_sha256"] = video._root(
            video.STATE_DOMAIN,
            video._state_body(impossible_state),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.validate_state(impossible_state)

        impossible_manifest = {
            **fixture["manifest1"],
            "generation": fixture["manifest1"]["generation"] + 2,
            "manifest_sha256": video.ZERO,
        }
        impossible_manifest["manifest_sha256"] = video._root(
            video.MANIFEST_DOMAIN,
            video._manifest_body(impossible_manifest),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.validate_manifest(impossible_manifest)

        for suffix in ("1", "2"):
            manifest = fixture[f"manifest{suffix}"]
            provenance = fixture[f"provenance{suffix}"]
            result = fixture[f"result{suffix}"]
            output = fixture[f"output{suffix}"]
            video.validate_provenance_binding(manifest, provenance)
            self.assertEqual(
                provenance["provenance_sha256"],
                result["provenance_sha256"],
            )
            self.assertEqual(result["output_sha256"], video.sha256(output))
            self.assertEqual(
                result["first_frame_sha256"],
                video.sha256(output[:4]),
            )
            self.assertEqual(
                result["second_frame_sha256"],
                video.sha256(output[4:]),
            )
            self.assertNotEqual(result["resource_receipt_sha256"], video.ZERO)

        rebound = {
            **fixture["provenance1"],
            "source_output_bytes": (
                fixture["provenance1"]["source_output_bytes"] + 1
            ),
            "provenance_sha256": video.ZERO,
        }
        rebound["provenance_sha256"] = video._root(
            video.PROVENANCE_DOMAIN,
            video._provenance_body(rebound),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.validate_provenance_binding(
                fixture["manifest1"],
                rebound,
            )

        malformed_result = {
            **fixture["result1"],
            "total_output_bytes": (
                fixture["result1"]["total_output_bytes"] + 1
            ),
            "result_sha256": video.ZERO,
        }
        malformed_result["result_sha256"] = video._root(
            video.RESULT_DOMAIN,
            video._result_body(malformed_result),
        )
        with self.assertRaises(video.GeneratedVideoDisplayError):
            video.validate_result(malformed_result)


if __name__ == "__main__":
    unittest.main()
