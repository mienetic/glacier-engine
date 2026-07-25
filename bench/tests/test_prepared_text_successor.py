from __future__ import annotations

import copy
import struct
import unittest

from bench import model_contract as contract
from bench import prepared_text_checkpoint as checkpoint
from bench import prepared_text_successor as successor


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def request_claim() -> dict[str, int]:
    return {
        "capsule_bytes": 64,
        "kv_bytes": 224,
        "activation_bytes": 12,
        "partial_bytes": 64,
        "logits_bytes": 1024,
        "output_journal_bytes": 20,
        "staging_bytes": 32,
        "device_bytes": 0,
        "io_bytes": 0,
        "queue_slots": 1,
    }


def artifact_from_digest() -> dict[str, object]:
    value: dict[str, object] = {
        "family": contract.AUTOREGRESSIVE,
        "artifact_abi": 0x474C544600000001,
        "input_kind": contract.TOKEN_ID_INPUT,
        "output_kind": contract.TOKEN_IDS,
        "numerical_policy": 4,
        "max_batch_items": 1,
        "input_features": 3,
        "output_dimensions": 5,
        "weight_elements": 4096,
        "weight_bytes": 4096,
        "weights_sha256": digest(0x41),
        "metadata_sha256": digest(0x42),
        "license_sha256": digest(0x43),
        "weight_element_bytes": 1,
        "input_element_bytes": 4,
        "output_element_bytes": 4,
    }
    return contract.decode_artifact(contract.encode_artifact(value))


def canonical_kv_payload() -> bytes:
    bits = []
    for layer in range(2):
        bits.extend(
            0x3F000000 + layer * 0x1000 + index
            for index in range(8)
        )
        bits.extend(
            0xBF000000 + layer * 0x1000 + index
            for index in range(8)
        )
    return b"".join(struct.pack("<I", value) for value in bits)


def fixture() -> dict[str, object]:
    claim = request_claim()
    total_claim = dict(claim)
    total_claim["capsule_bytes"] = 4160
    artifact = artifact_from_digest()
    source_plan = contract.make_plan(
        artifact,
        operation=contract.GENERATE_SEQUENCE,
        request_epoch=0x0102030405060708,
        generation=7,
        batch_items=1,
        publication_next_sequence=0,
        maximum_absolute_output=255,
        required_capabilities=0,
        scratch_bytes=claim["partial_bytes"],
        claim=total_claim,
        digests={
            "media_object_sha256": digest(0x31),
            "processor_state_sha256": digest(0x32),
            "processor_bundle_sha256": digest(0x33),
            "cache_bundle_sha256": digest(0x34),
            "cache_payload_sha256": digest(0x35),
            "ownership_sha256": digest(0x36),
            "challenge_sha256": digest(0xCC),
            "previous_plan_sha256": contract.ZERO_DIGEST,
            "input_schema_sha256": digest(0x37),
            "output_schema_sha256": digest(0x38),
        },
    )
    source_residency = contract.make_residency_binding(
        source_plan,
        residency=contract.SHARED_READ_ONLY,
        resident_weight_bytes=4096,
        request_claim=claim,
    )
    payload = canonical_kv_payload()
    output_tokens = (17, 29)
    rng_state = (
        0x0102030405060708,
        0x1112131415161718,
        0x2122232425262728,
        0x3132333435363738,
    )
    kv_state = checkpoint.incremental_kv_state_root(
        2,
        2,
        4,
        3,
        payload,
    )
    rng_root = checkpoint.rng_state_root(rng_state)
    output_root = checkpoint.output_state_root(output_tokens)
    state: dict[str, object] = {
        "abi_version": successor.STATE_COMMITMENT_ABI,
        "execution_abi": checkpoint.CONTIGUOUS_ABI,
        "kv_position": 4,
        "kv_state_sha256": kv_state,
        "rng_state_abi": checkpoint.RNG_STATE_ABI,
        "rng_state_sha256": rng_root,
        "sampling_calls": 2,
        "output_length": 2,
        "output_state_sha256": output_root,
    }
    state["commitment_sha256"] = successor.publication_state_root(state)
    expected_checkpoint: dict[str, object] = {
        "local_plan_sha256": digest(0x11),
        "bound_plan_sha256": digest(0x22),
        "artifact_sha256": artifact["artifact_sha256"],
        "execution_plan_sha256": source_plan["plan_sha256"],
        "residency_binding_sha256": source_residency[
            "binding_sha256"
        ],
        "boundary_sha256": digest(0x66),
        "transcript_sha256": digest(0x77),
        "state_commitment_sha256": state["commitment_sha256"],
        "request_epoch": source_plan["request_epoch"],
        "publication_next_sequence": 2,
        "prompt_tokens": 3,
        "max_new_tokens": 5,
        "vocab_size": 256,
        "num_layers": 2,
        "kv_dim": 2,
        "max_kv_positions": 7,
        "kv_positions": 4,
        "output_count": 2,
        "sampling_calls": 2,
        "challenge_sha256": digest(0xCC),
    }
    checkpoint_input = {
        **expected_checkpoint,
        "output_tokens": output_tokens,
        "rng_state": rng_state,
        "canonical_kv_f32_le": payload,
    }
    encoded_checkpoint = checkpoint.encode(checkpoint_input)
    receipt: dict[str, object] = {
        "bank_epoch": 41,
        "slot_index": 0,
        "generation": 1,
        "owner_key": 1001,
        "claim": dict(claim),
        "integrity": 0,
    }
    receipt["integrity"] = contract.receipt_integrity(receipt)
    source: dict[str, object] = {
        "bound_plan_sha256": digest(0x22),
        "execution": source_plan,
        "residency": source_residency,
        "boundary_sha256": digest(0x66),
        "publication": {
            "abi_version": successor.TRANSCRIPT_SNAPSHOT_ABI,
            "request_epoch": source_plan["request_epoch"],
            "execution_abi": checkpoint.CONTIGUOUS_ABI,
            "next_sequence": 2,
            "last_resource_permit_generation": 19,
            "terminal": False,
            "state": state,
            "transcript_sha256": digest(0x77),
        },
        "receipt": receipt,
    }
    target: dict[str, object] = {
        "scheduler_epoch": 51,
        "coordinator_id": 52,
        "bank_epoch": 42,
        "request_generation": 8,
        "resource_owner_key": 2001,
        "tree_key": 2002,
        "authority_key": 2003,
        "tenant_key": 2004,
        "scope_key": 2005,
        "cache_node_key": 2006,
        "cache_binding_key": 2007,
        "intent_generation": 8,
        "request_claim": dict(claim),
    }
    artifacts = successor.make_for_checkpoint(
        encoded_checkpoint,
        expected_checkpoint,
        source,
        target,
    )
    encoded = successor.encode_artifacts(artifacts)
    return {
        "encoded_checkpoint": encoded_checkpoint,
        "expected_checkpoint": expected_checkpoint,
        "checkpoint_input": checkpoint_input,
        "source": source,
        "target": target,
        "artifacts": artifacts,
        "encoded_plan": encoded[0],
        "encoded_residency": encoded[1],
        "encoded_segment": encoded[2],
    }


def reroot_segment(value: dict[str, object]) -> dict[str, object]:
    result = copy.deepcopy(value)
    result["segment_sha256"] = successor.successor_segment_root(result)
    return result


def rebind_artifact_plan(
    artifacts: dict[str, object],
    changes: dict[str, object],
    *,
    residency: int = contract.SHARED_READ_ONLY,
    request_claim_override: dict[str, int] | None = None,
) -> dict[str, object]:
    result = copy.deepcopy(artifacts)
    plan = result["successor_plan"]
    plan.update(changes)
    plan["input_bytes"] = (
        plan["batch_items"]
        * plan["input_features"]
        * plan["input_element_bytes"]
    )
    plan["output_bytes"] = (
        plan["batch_items"]
        * plan["output_dimensions"]
        * plan["output_element_bytes"]
    )
    plan["plan_sha256"] = contract.ZERO_DIGEST
    plan = contract.decode_plan(contract.encode_plan(plan))
    if request_claim_override is None:
        if residency == contract.SHARED_READ_ONLY:
            request_claim_override = copy.deepcopy(
                result["successor_residency"]["request_claim"]
            )
        else:
            request_claim_override = copy.deepcopy(plan["claim"])
    resident_weight_bytes = (
        4096 if residency == contract.SHARED_READ_ONLY else 0
    )
    binding = contract.make_residency_binding(
        plan,
        residency=residency,
        resident_weight_bytes=resident_weight_bytes,
        request_claim=request_claim_override,
    )
    segment = result["segment"]
    segment["successor_execution_plan_sha256"] = plan["plan_sha256"]
    segment["successor_residency_binding_sha256"] = binding[
        "binding_sha256"
    ]
    result.update(
        {
            "successor_plan": plan,
            "successor_residency": binding,
            "segment": reroot_segment(segment),
        }
    )
    return result


def coherent_source_plan_variant(
    value: dict[str, object],
    changes: dict[str, object],
    *,
    residency_kind: int = contract.SHARED_READ_ONLY,
    request_claim_override: dict[str, int] | None = None,
) -> tuple[bytes, dict[str, object], dict[str, object]]:
    source = copy.deepcopy(value["source"])
    plan = source["execution"]
    plan.update(changes)
    plan["input_bytes"] = (
        plan["batch_items"]
        * plan["input_features"]
        * plan["input_element_bytes"]
    )
    plan["output_bytes"] = (
        plan["batch_items"]
        * plan["output_dimensions"]
        * plan["output_element_bytes"]
    )
    plan["plan_sha256"] = contract.ZERO_DIGEST
    plan = contract.decode_plan(contract.encode_plan(plan))
    if request_claim_override is None:
        if residency_kind == contract.SHARED_READ_ONLY:
            request_claim_override = copy.deepcopy(
                source["residency"]["request_claim"]
            )
        else:
            request_claim_override = copy.deepcopy(plan["claim"])
    residency = contract.make_residency_binding(
        plan,
        residency=residency_kind,
        resident_weight_bytes=(
            4096
            if residency_kind == contract.SHARED_READ_ONLY
            else 0
        ),
        request_claim=request_claim_override,
    )
    source["execution"] = plan
    source["residency"] = residency
    expected = copy.deepcopy(value["expected_checkpoint"])
    expected["execution_plan_sha256"] = plan["plan_sha256"]
    expected["residency_binding_sha256"] = residency["binding_sha256"]
    checkpoint_input = copy.deepcopy(value["checkpoint_input"])
    checkpoint_input.update(expected)
    return checkpoint.encode(checkpoint_input), expected, source


class PreparedTextSuccessorTests(unittest.TestCase):
    def test_frozen_roots_roundtrip_and_exact_header(self) -> None:
        value = fixture()
        artifacts = value["artifacts"]
        segment = artifacts["segment"]
        self.assertEqual(
            artifacts["successor_plan"]["plan_sha256"].hex(),
            "f678322f4dae556ce2e660787d52811b"
            "cc17627a5b3538fa5a2ce9f03d64dfaa",
        )
        self.assertEqual(
            artifacts["successor_residency"]["binding_sha256"].hex(),
            "6449605803a760b8f6748c60537f196c"
            "4faeb1ee272d397bc39b5903602db244",
        )
        self.assertEqual(
            segment["ownership_intent_sha256"].hex(),
            "7a27a8ae765d373cd05acd5bc5a9de21"
            "3173b4a0f48538250756fdff7327d584",
        )
        self.assertEqual(
            segment["segment_sha256"].hex(),
            "d4b64fea15cae72847f72d586dffae76"
            "a225a096de8e26e69a6025b1a452a818",
        )
        self.assertEqual(len(value["encoded_plan"]), 768)
        self.assertEqual(len(value["encoded_residency"]), 256)
        self.assertEqual(len(value["encoded_segment"]), 512)
        self.assertEqual(
            value["encoded_segment"][:32].hex(),
            "474c5453454730310100000054544c47"
            "00000000000000000807060504030201",
        )
        decoded = successor.decode_and_verify_for_checkpoint(
            value["encoded_plan"],
            value["encoded_residency"],
            value["encoded_segment"],
            value["encoded_checkpoint"],
            value["expected_checkpoint"],
            value["source"],
            value["target"],
        )
        self.assertEqual(decoded, artifacts)

    def test_every_segment_byte_mutation_truncation_and_extension(
        self,
    ) -> None:
        value = fixture()
        encoded = value["encoded_segment"]
        for index in range(len(encoded)):
            with self.subTest(kind="mutation", index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.decode_artifacts(
                        value["encoded_plan"],
                        value["encoded_residency"],
                        bytes(mutated),
                    )
        for length in range(len(encoded)):
            with self.subTest(kind="truncation", length=length):
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.decode_segment(encoded[:length])
        with self.assertRaises(successor.PreparedTextSuccessorError):
            successor.decode_segment(encoded + b"\x00")

    def test_coherent_foreign_target_is_only_structurally_valid(
        self,
    ) -> None:
        value = fixture()
        foreign_target = copy.deepcopy(value["target"])
        foreign_target["resource_owner_key"] += 1
        foreign = successor.make_for_checkpoint(
            value["encoded_checkpoint"],
            value["expected_checkpoint"],
            value["source"],
            foreign_target,
        )
        encoded = successor.encode_artifacts(foreign)
        self.assertEqual(
            successor.decode_artifacts(*encoded),
            foreign,
        )
        with self.assertRaises(successor.PreparedTextSuccessorError):
            successor.decode_and_verify_for_checkpoint(
                *encoded,
                value["encoded_checkpoint"],
                value["expected_checkpoint"],
                value["source"],
                value["target"],
            )

    def test_retained_context_and_cache_substitutions_reject(
        self,
    ) -> None:
        value = fixture()
        encoded = (
            value["encoded_plan"],
            value["encoded_residency"],
            value["encoded_segment"],
        )

        foreign_source = copy.deepcopy(value["source"])
        foreign_plan = copy.deepcopy(foreign_source["execution"])
        foreign_plan["media_object_sha256"] = digest(0x91)
        foreign_plan["plan_sha256"] = contract.ZERO_DIGEST
        foreign_plan = contract.decode_plan(
            contract.encode_plan(foreign_plan)
        )
        foreign_source["execution"] = foreign_plan
        foreign_source["residency"] = contract.make_residency_binding(
            foreign_plan,
            residency=contract.SHARED_READ_ONLY,
            resident_weight_bytes=4096,
            request_claim=request_claim(),
        )
        with self.subTest(binding="source plan"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *encoded,
                    value["encoded_checkpoint"],
                    value["expected_checkpoint"],
                    foreign_source,
                    value["target"],
                )

        wrong_boundary = copy.deepcopy(value["source"])
        wrong_boundary["boundary_sha256"] = digest(0x92)
        with self.subTest(binding="boundary"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *encoded,
                    value["encoded_checkpoint"],
                    value["expected_checkpoint"],
                    wrong_boundary,
                    value["target"],
                )

        foreign_checkpoint = bytearray(value["encoded_checkpoint"])
        foreign_checkpoint[checkpoint.HEADER_BYTES] ^= 1
        with self.subTest(binding="checkpoint"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *encoded,
                    bytes(foreign_checkpoint),
                    value["expected_checkpoint"],
                    value["source"],
                    value["target"],
                )

        foreign_cache = copy.deepcopy(value["artifacts"])
        cache_plan = foreign_cache["successor_plan"]
        cache_plan["cache_payload_sha256"] = digest(0x93)
        cache_plan["plan_sha256"] = contract.ZERO_DIGEST
        cache_plan = contract.decode_plan(contract.encode_plan(cache_plan))
        foreign_cache["successor_plan"] = cache_plan
        foreign_cache["successor_residency"] = (
            contract.make_residency_binding(
                cache_plan,
                residency=contract.SHARED_READ_ONLY,
                resident_weight_bytes=4096,
                request_claim=request_claim(),
            )
        )
        cache_segment = foreign_cache["segment"]
        cache_segment["source_logical_kv_sha256"] = digest(0x93)
        cache_segment["successor_execution_plan_sha256"] = cache_plan[
            "plan_sha256"
        ]
        cache_segment["successor_residency_binding_sha256"] = (
            foreign_cache["successor_residency"]["binding_sha256"]
        )
        foreign_cache["segment"] = reroot_segment(cache_segment)
        foreign_encoded = successor.encode_artifacts(foreign_cache)
        self.assertEqual(
            successor.decode_artifacts(*foreign_encoded),
            foreign_cache,
        )
        with self.subTest(binding="cache"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *foreign_encoded,
                    value["encoded_checkpoint"],
                    value["expected_checkpoint"],
                    value["source"],
                    value["target"],
                )

        wrong_challenge = copy.deepcopy(value["expected_checkpoint"])
        wrong_challenge["challenge_sha256"] = digest(0x94)
        with self.subTest(binding="challenge"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *encoded,
                    value["encoded_checkpoint"],
                    wrong_challenge,
                    value["source"],
                    value["target"],
                )

        wrong_sequence = copy.deepcopy(value["source"])
        wrong_sequence["publication"]["next_sequence"] += 1
        with self.subTest(binding="sequence"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *encoded,
                    value["encoded_checkpoint"],
                    value["expected_checkpoint"],
                    wrong_sequence,
                    value["target"],
                )

        wrong_generation = copy.deepcopy(value["target"])
        wrong_generation["request_generation"] += 1
        with self.subTest(binding="generation"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.decode_and_verify_for_checkpoint(
                    *encoded,
                    value["encoded_checkpoint"],
                    value["expected_checkpoint"],
                    value["source"],
                    wrong_generation,
                )

    def test_strengthened_profile_and_geometry_invariants_reject(
        self,
    ) -> None:
        value = fixture()
        base = value["artifacts"]

        terminal_mismatch = copy.deepcopy(base)
        terminal_mismatch["segment"]["terminal_sequence"] += 1
        terminal_mismatch["segment"]["remaining_quanta"] += 1
        terminal_mismatch["segment"] = reroot_segment(
            terminal_mismatch["segment"]
        )
        with self.subTest(structural="terminal sequence"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.encode_artifacts(terminal_mismatch)

        kv_mismatch = copy.deepcopy(base)
        kv_mismatch["segment"]["source_kv_position"] += 1
        kv_mismatch["segment"] = reroot_segment(
            kv_mismatch["segment"]
        )
        with self.subTest(structural="source KV position"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.encode_artifacts(kv_mismatch)

        for field, replacement in (
            ("execution_abi", successor.CONTIGUOUS_EXECUTION_ABI + 1),
            ("rng_state_abi", successor.CONTIGUOUS_RNG_STATE_ABI + 1),
        ):
            incompatible = copy.deepcopy(base)
            incompatible["segment"][field] = replacement
            incompatible["segment"] = reroot_segment(
                incompatible["segment"]
            )
            with self.subTest(structural=field):
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.encode_artifacts(incompatible)

        profile_changes = (
            ("family", {"family": contract.VISION_UNDERSTANDING}),
            ("operation", {"operation": contract.ENCODE}),
            ("input kind", {"input_kind": contract.IMAGE_FEATURE_U8}),
            ("output kind", {"output_kind": contract.EMBEDDING_I32}),
            (
                "numerical policy",
                {"numerical_policy": contract.EXACT_INTEGER},
            ),
            ("batch", {"batch_items": 2}),
            ("capabilities", {"required_capabilities": 1}),
            (
                "element width",
                {
                    "input_element_bytes": 2,
                    "output_element_bytes": 2,
                },
            ),
            ("scratch projection", {"scratch_bytes": 63}),
        )
        for name, changes in profile_changes:
            plan_claim = None
            request = None
            if name == "batch":
                plan_claim = copy.deepcopy(
                    base["successor_plan"]["claim"]
                )
                plan_claim["activation_bytes"] = 24
                plan_claim["output_journal_bytes"] = 40
                request = copy.deepcopy(
                    base["successor_residency"]["request_claim"]
                )
                request["activation_bytes"] = 24
                request["output_journal_bytes"] = 40
                changes = {**changes, "claim": plan_claim}
            incompatible = rebind_artifact_plan(
                base,
                changes,
                request_claim_override=request,
            )
            with self.subTest(profile=name):
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.encode_artifacts(incompatible)

        request_owned = rebind_artifact_plan(
            base,
            {},
            residency=contract.REQUEST_OWNED,
        )
        with self.subTest(profile="request-owned residency"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.encode_artifacts(request_owned)

    def test_strengthened_source_invariants_reject_coherent_inputs(
        self,
    ) -> None:
        value = fixture()
        source_variants = (
            ("family", {"family": contract.VISION_UNDERSTANDING}),
            ("operation", {"operation": contract.ENCODE}),
            ("input kind", {"input_kind": contract.IMAGE_FEATURE_U8}),
            ("output kind", {"output_kind": contract.EMBEDDING_I32}),
            (
                "numerical policy",
                {"numerical_policy": contract.EXACT_INTEGER},
            ),
            ("batch", {"batch_items": 2}),
            ("capabilities", {"required_capabilities": 1}),
            (
                "element width",
                {
                    "input_element_bytes": 2,
                    "output_element_bytes": 2,
                },
            ),
            ("scratch projection", {"scratch_bytes": 63}),
        )
        for name, changes in source_variants:
            request = None
            if name == "batch":
                plan_claim = copy.deepcopy(
                    value["source"]["execution"]["claim"]
                )
                plan_claim["activation_bytes"] = 24
                plan_claim["output_journal_bytes"] = 40
                request = copy.deepcopy(request_claim())
                request["activation_bytes"] = 24
                request["output_journal_bytes"] = 40
                changes = {**changes, "claim": plan_claim}
            encoded_checkpoint, expected, source = (
                coherent_source_plan_variant(
                    value,
                    changes,
                    request_claim_override=request,
                )
            )
            with self.subTest(source_profile=name):
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.make_for_checkpoint(
                        encoded_checkpoint,
                        expected,
                        source,
                        value["target"],
                    )

        encoded_checkpoint, expected, request_owned = (
            coherent_source_plan_variant(
                value,
                {},
                residency_kind=contract.REQUEST_OWNED,
            )
        )
        with self.subTest(source_profile="request-owned residency"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.make_for_checkpoint(
                    encoded_checkpoint,
                    expected,
                    request_owned,
                    value["target"],
                )

        outer_abi = copy.deepcopy(value["source"])
        outer_abi["publication"]["execution_abi"] += 1
        with self.subTest(source_profile="outer execution ABI"):
            with self.assertRaises(
                successor.PreparedTextSuccessorError
            ):
                successor.make_for_checkpoint(
                    value["encoded_checkpoint"],
                    value["expected_checkpoint"],
                    outer_abi,
                    value["target"],
                )

    def test_invalid_source_and_target_rules_reject(self) -> None:
        value = fixture()
        for field in successor.TARGET_FIELDS:
            with self.subTest(target_zero=field):
                invalid = copy.deepcopy(value["target"])
                invalid[field] = 0
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.make_for_checkpoint(
                        value["encoded_checkpoint"],
                        value["expected_checkpoint"],
                        value["source"],
                        invalid,
                    )

        for name, mutate in (
            (
                "source bank",
                lambda target: target.update(
                    bank_epoch=value["source"]["receipt"]["bank_epoch"]
                ),
            ),
            (
                "source owner",
                lambda target: target.update(
                    resource_owner_key=value["source"]["receipt"][
                        "owner_key"
                    ]
                ),
            ),
            (
                "request generation",
                lambda target: target.update(request_generation=9),
            ),
            (
                "intent generation",
                lambda target: target.update(intent_generation=9),
            ),
            (
                "claim",
                lambda target: target["request_claim"].update(
                    queue_slots=2
                ),
            ),
        ):
            with self.subTest(target=name):
                invalid = copy.deepcopy(value["target"])
                mutate(invalid)
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.make_for_checkpoint(
                        value["encoded_checkpoint"],
                        value["expected_checkpoint"],
                        value["source"],
                        invalid,
                    )

        invalid_sources = []
        invalid_receipt = copy.deepcopy(value["source"])
        invalid_receipt["receipt"]["integrity"] ^= 1
        invalid_sources.append(("receipt", invalid_receipt))
        terminal = copy.deepcopy(value["source"])
        terminal["publication"]["terminal"] = True
        invalid_sources.append(("terminal", terminal))
        no_permit = copy.deepcopy(value["source"])
        no_permit["publication"][
            "last_resource_permit_generation"
        ] = 0
        invalid_sources.append(("permit", no_permit))
        wrong_state = copy.deepcopy(value["source"])
        wrong_state["publication"]["state"]["sampling_calls"] += 1
        invalid_sources.append(("state", wrong_state))
        wrong_claim = copy.deepcopy(value["source"])
        wrong_claim["receipt"]["claim"]["queue_slots"] = 2
        wrong_claim["receipt"]["integrity"] = contract.receipt_integrity(
            wrong_claim["receipt"]
        )
        invalid_sources.append(("claim", wrong_claim))
        for name, invalid in invalid_sources:
            with self.subTest(source=name):
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.make_for_checkpoint(
                        value["encoded_checkpoint"],
                        value["expected_checkpoint"],
                        invalid,
                        value["target"],
                    )

    def test_resealed_segment_semantic_mismatches_reject(self) -> None:
        value = fixture()
        base = value["artifacts"]["segment"]
        mutations = {
            "request_epoch": 0,
            "sequence_base": 0,
            "terminal_sequence": base["sequence_base"],
            "remaining_quanta": base["remaining_quanta"] + 1,
            "source_last_resource_permit_generation": 0,
            "source_kv_position": 0,
            "source_sampling_calls": base["source_sampling_calls"] + 1,
            "source_output_length": base["source_output_length"] + 1,
            "source_execution_generation": 0,
            "successor_execution_generation": (
                base["successor_execution_generation"] + 1
            ),
            "segment_generation": base["segment_generation"] + 1,
            "execution_abi": 0,
            "rng_state_abi": 0,
        }
        for field, replacement in mutations.items():
            with self.subTest(field=field):
                invalid = copy.deepcopy(base)
                invalid[field] = replacement
                invalid = reroot_segment(invalid)
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.encode_segment(invalid)
        for field in successor.SEGMENT_DIGEST_FIELDS:
            with self.subTest(zero_digest=field):
                invalid = copy.deepcopy(base)
                invalid[field] = successor.ZERO_DIGEST
                invalid = reroot_segment(invalid)
                with self.assertRaises(
                    successor.PreparedTextSuccessorError
                ):
                    successor.encode_segment(invalid)
        same_plan = copy.deepcopy(base)
        same_plan["successor_execution_plan_sha256"] = same_plan[
            "source_execution_plan_sha256"
        ]
        same_plan = reroot_segment(same_plan)
        with self.assertRaises(successor.PreparedTextSuccessorError):
            successor.encode_segment(same_plan)


if __name__ == "__main__":
    unittest.main()
