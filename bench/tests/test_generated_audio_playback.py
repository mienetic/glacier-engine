from __future__ import annotations

import unittest

from bench import generated_audio_playback as audio


class GeneratedAudioPlaybackTests(unittest.TestCase):
    def test_reference_roots_and_all_wires_are_canonical(self) -> None:
        fixture = audio.reference_fixture()
        expected = {
            "state0": (
                "state_sha256",
                "7c6c4cf1519e02163a1b9009d8bc3c890566edf5bdd7d4fb1d63ddec9e2df654",
            ),
            "plan1": (
                "plan_sha256",
                "57f4887803a87eb795b98fd3a10bd8e19839807d14746de67e9482e4ebd14122",
            ),
            "provenance1": (
                "provenance_sha256",
                "f075731d49893ca58497090debcffcc736f1e61253577abe78e1fba646702567",
            ),
            "result1": (
                "result_sha256",
                "1055112e6118209e442ccb44b1fa39e55d765c76d9790357e5ec7d203d52bc13",
            ),
            "observation1": (
                "observation_sha256",
                "603e75167914c5a32f75cfd9baa20caefa2518a0bb5361132d835f742bc0350e",
            ),
            "ack_plan1": (
                "plan_sha256",
                "f134f093575d6f19b84c6d1885736856b4a67011ae99fdfca590426ddf5d83fd",
            ),
            "ack1": (
                "result_sha256",
                "455544e586d1e20191f3792430ce248fd914a51c0aa9d76150ea0818558c54a6",
            ),
            "state4": (
                "state_sha256",
                "eee498d7003a186732ed3a3e1bfb8824a0a69b01ef8020fa2cce8d667db1b2a9",
            ),
        }
        for key, (field, root) in expected.items():
            self.assertEqual(fixture[key][field].hex(), root)

        wires = (
            (fixture["state0"], audio.encode_state, audio.decode_state),
            (fixture["plan1"], audio.encode_plan, audio.decode_plan),
            (
                fixture["provenance1"],
                audio.encode_provenance,
                audio.decode_provenance,
            ),
            (fixture["result1"], audio.encode_result, audio.decode_result),
            (
                fixture["observation1"],
                audio.encode_observation,
                audio.decode_observation,
            ),
            (
                fixture["ack_plan1"],
                audio.encode_ack_plan,
                audio.decode_ack_plan,
            ),
            (
                fixture["ack1"],
                audio.encode_ack_result,
                audio.decode_ack_result,
            ),
        )
        for value, encode, decode in wires:
            encoded = encode(value)
            self.assertEqual(decode(encoded), value)
            for index in range(len(encoded)):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(audio.GeneratedAudioPlaybackError):
                    decode(bytes(mutated))

    def test_acknowledgement_gates_each_successor_chunk(self) -> None:
        fixture = audio.reference_fixture()
        state1 = fixture["state1"]
        self.assertEqual(state1["pending"], 1)
        self.assertEqual(state1["visible_chunks"], 1)
        self.assertEqual(state1["acknowledged_chunks"], 0)
        with self.assertRaises(audio.GeneratedAudioPlaybackError):
            audio.make_plan(
                state1,
                frame_count=2,
                source_output_bytes=2,
                source_result_sha256=audio.sha256("blocked result"),
                source_output_sha256=audio.sha256("blocked output"),
                media_object_sha256=audio.sha256("blocked media"),
            )

        state2 = fixture["state2"]
        self.assertEqual(state2["pending"], 0)
        self.assertEqual(state2["acknowledged_chunks"], 1)
        self.assertEqual(state2["acknowledged_frames"], 2)
        self.assertEqual(
            state2["previous_ack_result_sha256"],
            fixture["ack1"]["result_sha256"],
        )

        state4 = fixture["state4"]
        self.assertEqual(state4["generation"], 4)
        self.assertEqual(state4["visible_chunks"], 2)
        self.assertEqual(state4["visible_frames"], 4)
        self.assertEqual(state4["acknowledged_chunks"], 2)
        self.assertEqual(state4["acknowledged_frames"], 4)
        self.assertEqual(state4["playback_sequence"], 2)
        self.assertEqual(state4["pending"], 0)
        self.assertEqual(fixture["pcm1"], b"\x00\x01\x00\xff")
        self.assertEqual(fixture["pcm2"], b"\x00\x02\x00\xfe")

    def test_partial_foreign_and_duplicate_acknowledgements_fail_closed(
        self,
    ) -> None:
        fixture = audio.reference_fixture()
        state1 = fixture["state1"]
        result1 = fixture["result1"]
        observation1 = fixture["observation1"]
        ack_plan1 = fixture["ack_plan1"]

        partial = {
            **observation1,
            "consumed_frames": observation1["consumed_frames"] - 1,
            "observation_sha256": audio.ZERO,
        }
        partial["observation_sha256"] = audio._root(
            audio.OBSERVATION_DOMAIN,
            audio._observation_body(partial),
        )
        with self.assertRaises(audio.GeneratedAudioPlaybackError):
            audio.acknowledge(state1, result1, partial, ack_plan1)

        foreign = {
            **result1,
            "output_sha256": audio.sha256("foreign output"),
            "result_sha256": audio.ZERO,
        }
        foreign["result_sha256"] = audio._root(
            audio.RESULT_DOMAIN,
            audio._result_body(foreign),
        )
        with self.assertRaises(audio.GeneratedAudioPlaybackError):
            audio.acknowledge(state1, foreign, observation1, ack_plan1)

        with self.assertRaises(audio.GeneratedAudioPlaybackError):
            audio.make_ack_plan(
                fixture["state2"],
                result1,
                observation1,
            )

    def test_publication_chains_exact_media_and_resource_identity(self) -> None:
        fixture = audio.reference_fixture()
        for suffix in ("1", "2"):
            plan = fixture[f"plan{suffix}"]
            provenance = fixture[f"provenance{suffix}"]
            result = fixture[f"result{suffix}"]
            media_object = fixture[f"media{suffix}"]
            pcm = fixture[f"pcm{suffix}"]
            self.assertEqual(plan["plan_sha256"], provenance["plan_sha256"])
            audio.validate_provenance_binding(plan, provenance)
            self.assertEqual(
                provenance["provenance_sha256"],
                result["provenance_sha256"],
            )
            self.assertEqual(result["output_sha256"], audio.sha256(pcm))
            self.assertEqual(
                media_object["content_sha256"],
                result["output_sha256"],
            )
            self.assertEqual(media_object["kind"], 2)
            self.assertEqual(media_object["time_base"], (1, 16_000))
            self.assertNotEqual(result["resource_receipt_sha256"], audio.ZERO)

        plan1 = fixture["plan1"]
        rebound = {
            **fixture["provenance1"],
            "source_output_bytes": (
                fixture["provenance1"]["source_output_bytes"] + 1
            ),
            "provenance_sha256": audio.ZERO,
        }
        rebound["provenance_sha256"] = audio._root(
            audio.PROVENANCE_DOMAIN,
            audio._provenance_body(rebound),
        )
        with self.assertRaises(audio.GeneratedAudioPlaybackError):
            audio.validate_provenance_binding(plan1, rebound)


if __name__ == "__main__":
    unittest.main()
