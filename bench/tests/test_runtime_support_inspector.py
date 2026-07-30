from __future__ import annotations

import hashlib
import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock

from bench import runtime_support_registry as oracle


EXPECTED_PROFILE_SEMANTICS = (
    (
        0,
        "vision-encoder-reference",
        0x4756_454E_0000_0001,
        "stateless",
        "vision_understanding",
        3,
        "encode",
        3,
        "image_feature_u8",
        3,
        "embedding_i32",
        2,
        64,
        65_536,
        16_384,
    ),
    (
        1,
        "audio-window-reference",
        0x4741_5745_0000_0001,
        "stateless",
        "audio_understanding",
        4,
        "encode",
        3,
        "audio_feature_i16",
        4,
        "embedding_i32",
        2,
        4_096,
        16_384,
        16_384,
    ),
    (
        2,
        "audio-transcript-reference",
        0x4154_524E_0000_0001,
        "stateless",
        "audio_understanding",
        4,
        "transcribe",
        6,
        "audio_feature_i16",
        4,
        "transcript",
        5,
        1,
        4_096,
        384,
    ),
    (
        3,
        "stateful-transcript-reference",
        0x5354_5254_524E_0001,
        "stateful",
        "audio_understanding",
        4,
        "transcribe",
        6,
        "audio_feature_i16",
        4,
        "transcript",
        5,
        1,
        4,
        64,
    ),
    (
        4,
        "temporal-video-reference",
        0x4754_5645_0000_0001,
        "stateless",
        "video_understanding",
        6,
        "encode",
        3,
        "video_feature_u8",
        5,
        "embedding_i32",
        2,
        4_096,
        1_048_576,
        16_384,
    ),
    (
        5,
        "video-segment-reference",
        0x4756_5341_0000_0001,
        "stateless",
        "video_understanding",
        6,
        "segment",
        10,
        "video_feature_u8",
        5,
        "video_segment",
        10,
        1,
        1_048_576,
        512,
    ),
    (
        6,
        "stateful-video-reference",
        0x5354_5656_4652_0001,
        "stateful",
        "video_understanding",
        6,
        "segment",
        10,
        "video_feature_u8",
        5,
        "video_segment",
        10,
        1,
        4,
        512,
    ),
    (
        7,
        "latent-step-reference",
        0x474C_4154_0000_0001,
        "stateful",
        "image_generation",
        7,
        "diffuse_step",
        8,
        "latent_tensor",
        6,
        "media_chunk",
        6,
        1,
        1_048_576,
        1_048_576,
    ),
    (
        8,
        "dense-tensor-reranker-reference",
        0x4744_5252_0000_0001,
        "stateless",
        "stateless_encoder",
        2,
        "rerank",
        5,
        "dense_tensor",
        2,
        "ranked_items",
        4,
        64,
        4_096,
        1,
    ),
    (
        9,
        "dense-tensor-embedding-reference",
        0x4744_454D_0000_0001,
        "stateless",
        "stateless_encoder",
        2,
        "encode",
        3,
        "dense_tensor",
        2,
        "embedding_i32",
        2,
        64,
        4_096,
        256,
    ),
    (
        10,
        "dense-tensor-classifier-reference",
        0x4744_434C_0000_0001,
        "stateless",
        "stateless_encoder",
        2,
        "classify",
        4,
        "dense_tensor",
        2,
        "class_scores",
        3,
        64,
        4_096,
        256,
    ),
    (
        11,
        "dense-tensor-retrieval-reference",
        0x4744_5254_0000_0001,
        "stateless",
        "retrieval",
        12,
        "retrieve",
        15,
        "embedding_i32",
        8,
        "retrieval_hits",
        13,
        1,
        4_096,
        6_144,
    ),
)


class RuntimeSupportInspectorOracleTests(unittest.TestCase):
    def test_profile_order_and_semantic_values_are_fixed(self) -> None:
        actual = tuple(
            (
                profile.index,
                profile.slug,
                profile.profile_abi,
                profile.lifecycle,
                profile.support.family,
                profile.support.family_id,
                profile.support.operation,
                profile.support.operation_id,
                profile.support.input_kind,
                profile.support.input_kind_id,
                profile.support.output_kind,
                profile.support.output_kind_id,
                profile.support.max_batch_items,
                profile.support.max_input_features,
                profile.support.max_output_dimensions,
            )
            for profile in oracle.PROFILES
        )
        self.assertEqual(EXPECTED_PROFILE_SEMANTICS, actual)

        for profile in oracle.PROFILES:
            self.assertEqual("retained_reference_fixture", profile.evidence)
            self.assertEqual("exact_integer", profile.support.numerical_policy)
            self.assertEqual(1, profile.support.numerical_policy_id)
            self.assertEqual(0, profile.support.allowed_capabilities)

    def test_profile_identifiers_are_unique(self) -> None:
        indices = [profile.index for profile in oracle.PROFILES]
        slugs = [profile.slug for profile in oracle.PROFILES]
        profile_abis = [profile.profile_abi for profile in oracle.PROFILES]

        self.assertEqual(list(range(12)), indices)
        self.assertEqual(len(slugs), len(set(slugs)))
        self.assertEqual(len(profile_abis), len(set(profile_abis)))

    def test_classifier_profile_keeps_exact_append_only_mask_bit(self) -> None:
        classifier = oracle.PROFILES[10]

        self.assertEqual("dense-tensor-classifier-reference", classifier.slug)
        self.assertEqual(0x4744_434C_0000_0001, classifier.profile_abi)
        self.assertEqual(1 << classifier.index, 0x400)
        self.assertEqual(
            (1 << 10) - 1,
            sum(1 << profile.index for profile in oracle.PROFILES[:10]),
        )
        self.assertEqual(
            (1 << 11) - 1,
            sum(1 << profile.index for profile in oracle.PROFILES[:11]),
        )

    def test_retrieval_profile_appends_exact_mask_bit(self) -> None:
        retrieval = oracle.PROFILES[11]

        self.assertEqual("dense-tensor-retrieval-reference", retrieval.slug)
        self.assertEqual(0x4744_5254_0000_0001, retrieval.profile_abi)
        self.assertEqual(1 << retrieval.index, 0x800)
        self.assertEqual(
            (1 << 11) - 1,
            sum(1 << profile.index for profile in oracle.PROFILES[:11]),
        )
        self.assertEqual(
            (1 << 12) - 1,
            sum(1 << profile.index for profile in oracle.PROFILES),
        )

    def test_document_has_nonclaim_metadata_and_fixed_capacity(self) -> None:
        document = oracle.registry_document()

        self.assertEqual(
            "glacier.runtime-support-registry/v1",
            document["schema"],
        )
        self.assertEqual("4752535200000001", document["registry_abi"])
        self.assertFalse(document["production_model_support"])
        self.assertFalse(document["host_backend_probed"])
        self.assertEqual(
            "retained_reference_fixture_contracts",
            document["claim_scope"],
        )
        self.assertEqual(12, document["profile_count"])
        self.assertEqual(64, document["max_profiles"])

    def test_rendering_is_compact_ascii_json_with_exact_hex_width(self) -> None:
        rendered = oracle.render_registry_bytes()

        self.assertTrue(rendered.endswith(b"\n"))
        self.assertEqual(1, rendered.count(b"\n"))
        self.assertEqual(oracle.registry_document(), json.loads(rendered))
        self.assertEqual(rendered.decode("ascii"), oracle.render_registry())
        for profile in json.loads(rendered)["profiles"]:
            self.assertRegex(profile["profile_abi"], r"^[0-9a-f]{16}$")
            self.assertRegex(
                profile["support"]["allowed_capabilities"],
                r"^[0-9a-f]{16}$",
            )

        self.assertEqual(
            "c107d55282b7ce4560d156b12bb82e76"
            "7d0efae03d6d4eaf5f54c79e5ef57849",
            hashlib.sha256(rendered).hexdigest(),
        )

    def test_verifier_checks_exact_and_unexpected_argument_paths(self) -> None:
        inspector = Path("/tmp/glacier-test-runtime-support-inspector")
        success = subprocess.CompletedProcess(
            args=[str(inspector)],
            returncode=0,
            stdout=oracle.render_registry_bytes(),
            stderr=b"",
        )
        rejected = subprocess.CompletedProcess(
            args=[str(inspector), oracle.UNEXPECTED_INSPECTOR_ARGUMENT],
            returncode=64,
            stdout=b"",
            stderr=b"usage\n",
        )

        with mock.patch.object(
            oracle.subprocess,
            "run",
            side_effect=(success, rejected),
        ) as run:
            oracle.verify_inspector(inspector)

        self.assertEqual(2, run.call_count)
        self.assertEqual(
            [str(inspector.resolve())],
            run.call_args_list[0].args[0],
        )
        self.assertEqual(
            [
                str(inspector.resolve()),
                oracle.UNEXPECTED_INSPECTOR_ARGUMENT,
            ],
            run.call_args_list[1].args[0],
        )
        for call in run.call_args_list:
            self.assertFalse(call.kwargs["check"])
            self.assertEqual(subprocess.PIPE, call.kwargs["stdout"])
            self.assertEqual(subprocess.PIPE, call.kwargs["stderr"])


if __name__ == "__main__":
    unittest.main()
