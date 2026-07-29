from __future__ import annotations

import hashlib
import struct
import unittest

from bench import model_contract as contract


def claim() -> dict[str, int]:
    return {
        "capsule_bytes": 8,
        "kv_bytes": 0,
        "activation_bytes": 8,
        "partial_bytes": 16,
        "logits_bytes": 0,
        "output_journal_bytes": 16,
        "staging_bytes": 0,
        "device_bytes": 0,
        "io_bytes": 0,
        "queue_slots": 1,
    }


def fixture() -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
    bytes,
    bytes,
]:
    weights = bytes((1, 2, 3, 4, 0xFF, 0xFE, 1, 2))
    features = bytes((1, 2, 3, 4, 5, 6, 7, 8))
    artifact = contract.make_artifact(
        family=contract.VISION_UNDERSTANDING,
        artifact_abi=0x564953494F4E0001,
        input_kind=contract.IMAGE_FEATURE_U8,
        output_kind=contract.EMBEDDING_I32,
        numerical_policy=contract.EXACT_INTEGER,
        max_batch_items=2,
        input_features=4,
        output_dimensions=2,
        input_element_bytes=1,
        output_element_bytes=4,
        weight_element_bytes=1,
        weights=weights,
        metadata_sha256=contract.sha256(b"fixture metadata"),
        license_sha256=contract.sha256(b"fixture license"),
    )
    plan = contract.make_plan(
        artifact,
        operation=contract.ENCODE,
        request_epoch=41,
        generation=7,
        batch_items=2,
        publication_next_sequence=0,
        maximum_absolute_output=4096,
        required_capabilities=0,
        scratch_bytes=16,
        claim=claim(),
        digests={
            "media_object_sha256": contract.sha256(b"media"),
            "processor_state_sha256": contract.sha256(
                b"processor state"
            ),
            "processor_bundle_sha256": contract.sha256(
                b"processor bundle"
            ),
            "cache_bundle_sha256": contract.sha256(b"cache bundle"),
            "cache_payload_sha256": contract.sha256(b"cache payload"),
            "ownership_sha256": contract.sha256(b"ownership"),
            "challenge_sha256": contract.sha256(b"challenge"),
            "previous_plan_sha256": contract.ZERO_DIGEST,
            "input_schema_sha256": contract.sha256(b"input schema"),
            "output_schema_sha256": contract.sha256(b"output schema"),
        },
    )
    state = {
        "request_epoch": 41,
        "next_sequence": 0,
        "visible_results": 0,
        "artifact_sha256": artifact["artifact_sha256"],
        "previous_result_sha256": contract.ZERO_DIGEST,
    }
    output = contract.reference_integer_projection(
        plan,
        weights,
        features,
    )
    result = contract.make_result(
        state,
        plan,
        {
            "bank_epoch": 3,
            "slot_index": 1,
            "generation": 9,
            "owner_key": 77,
            "claim": claim(),
            "integrity": 88,
        },
        output_sha256=contract.sha256(output),
        source_mapping_sha256=contract.sha256(b"mapping"),
        adapter_sha256=contract.sha256(b"adapter"),
    )
    return artifact, plan, result, weights, features


def shared_residency_fixture() -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
    dict[str, object],
    bytes,
]:
    artifact, plan, _, weights, features = fixture()
    request_claim = dict(plan["claim"])
    request_claim["capsule_bytes"] -= plan["weight_bytes"]
    residency = contract.make_residency_binding(
        plan,
        residency=contract.SHARED_READ_ONLY,
        resident_weight_bytes=plan["weight_bytes"],
        request_claim=request_claim,
    )
    state = {
        "request_epoch": plan["request_epoch"],
        "next_sequence": plan["publication_next_sequence"],
        "visible_results": plan["publication_next_sequence"],
        "artifact_sha256": artifact["artifact_sha256"],
        "previous_result_sha256": contract.ZERO_DIGEST,
    }
    output = contract.reference_integer_projection(
        plan,
        weights,
        features,
    )
    receipt = {
        "bank_epoch": 3,
        "slot_index": 1,
        "generation": 9,
        "owner_key": 77,
        "claim": request_claim,
        "integrity": 0,
    }
    receipt["integrity"] = contract.receipt_integrity(receipt)
    result = contract.make_residency_result(
        state,
        plan,
        residency,
        receipt,
        output_sha256=contract.sha256(output),
        source_mapping_sha256=contract.sha256(b"mapping"),
        adapter_sha256=contract.sha256(b"adapter"),
    )
    return artifact, plan, residency, result, output


def token_ids_fixture() -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
    bytes,
]:
    weights = bytes((1, 2, 3, 4, 0xFF, 0xFE, 1, 2))
    output = bytes((42, 0, 0, 0))
    token_claim = {
        "capsule_bytes": 8,
        "kv_bytes": 0,
        "activation_bytes": 16,
        "partial_bytes": 8,
        "logits_bytes": 0,
        "output_journal_bytes": 4,
        "staging_bytes": 0,
        "device_bytes": 0,
        "io_bytes": 0,
        "queue_slots": 1,
    }
    artifact = contract.make_artifact(
        family=contract.AUTOREGRESSIVE,
        artifact_abi=0x5445585400000001,
        input_kind=contract.TOKEN_ID_INPUT,
        output_kind=contract.TOKEN_IDS,
        numerical_policy=contract.EXACT_INTEGER,
        max_batch_items=1,
        input_features=4,
        output_dimensions=1,
        input_element_bytes=4,
        output_element_bytes=4,
        weight_element_bytes=1,
        weights=weights,
        metadata_sha256=contract.sha256(b"token ID fixture metadata"),
        license_sha256=contract.sha256(b"token ID fixture license"),
    )
    plan = contract.make_plan(
        artifact,
        operation=contract.DECODE_NEXT,
        request_epoch=73,
        generation=5,
        batch_items=1,
        publication_next_sequence=0,
        maximum_absolute_output=65535,
        required_capabilities=0,
        scratch_bytes=8,
        claim=token_claim,
        digests={
            "media_object_sha256": contract.sha256(b"token prompt"),
            "processor_state_sha256": contract.sha256(
                b"tokenizer state"
            ),
            "processor_bundle_sha256": contract.sha256(
                b"tokenizer bundle"
            ),
            "cache_bundle_sha256": contract.sha256(
                b"token cache bundle"
            ),
            "cache_payload_sha256": contract.sha256(
                b"token cache payload"
            ),
            "ownership_sha256": contract.sha256(b"token ownership"),
            "challenge_sha256": contract.sha256(b"token challenge"),
            "previous_plan_sha256": contract.ZERO_DIGEST,
            "input_schema_sha256": contract.sha256(
                b"token input schema"
            ),
            "output_schema_sha256": contract.sha256(
                b"token output schema"
            ),
        },
    )
    state = {
        "request_epoch": 73,
        "next_sequence": 0,
        "visible_results": 0,
        "artifact_sha256": artifact["artifact_sha256"],
        "previous_result_sha256": contract.ZERO_DIGEST,
    }
    result = contract.make_result(
        state,
        plan,
        {
            "bank_epoch": 4,
            "slot_index": 0,
            "generation": 2,
            "owner_key": 91,
            "claim": token_claim,
            "integrity": 123,
        },
        output_sha256=contract.sha256(output),
        source_mapping_sha256=contract.sha256(b"token mapping"),
        adapter_sha256=contract.sha256(b"token adapter"),
    )
    return artifact, plan, result, output


class ModelContractTests(unittest.TestCase):
    def test_canonical_wires_and_exact_projection(self) -> None:
        artifact, plan, result, weights, features = fixture()
        self.assertEqual(
            contract.decode_artifact(contract.encode_artifact(artifact)),
            artifact,
        )
        self.assertEqual(
            contract.decode_plan(contract.encode_plan(plan)),
            plan,
        )
        self.assertEqual(
            contract.decode_result(contract.encode_result(result)),
            result,
        )
        output = contract.reference_integer_projection(
            plan,
            weights,
            features,
        )
        self.assertEqual(
            output,
            (
                b"\x1e\x00\x00\x00"
                b"\x06\x00\x00\x00"
                b"\x46\x00\x00\x00"
                b"\x06\x00\x00\x00"
            ),
        )
        self.assertEqual(result["output_sha256"], contract.sha256(output))
        self.assertEqual(
            artifact["artifact_sha256"].hex(),
            "62ded12535e6029577afbf588c97077a"
            "88a12ffb03863eec476e75d49d003750",
        )
        self.assertEqual(
            plan["plan_sha256"].hex(),
            "7b931bcf9e4858b0c433d893812b770d"
            "eff7d3b022cf40aebec164bef4945786",
        )
        self.assertEqual(
            result["result_sha256"].hex(),
            "b522a4ed75ba657638a8fc162833ed87"
            "749647b3ba6cfdd73661de41041bd6c9",
        )
        contract.verify_relationships(artifact, plan, result)

    def test_shared_residency_is_canonical_and_relationship_complete(
        self,
    ) -> None:
        artifact, plan, residency, result, output = (
            shared_residency_fixture()
        )
        encoded = contract.encode_residency_binding(residency)
        self.assertEqual(contract.EXECUTION_RESIDENCY_BINDING_BYTES, 256)
        self.assertEqual(256, len(encoded))
        self.assertEqual(
            residency,
            contract.decode_residency_binding(encoded),
        )
        contract.validate_residency_binding(residency, plan)
        contract.verify_residency_relationships(
            artifact,
            plan,
            residency,
            result,
        )
        self.assertEqual(contract.SHARED_READ_ONLY, residency["residency"])
        self.assertEqual(
            plan["weight_bytes"],
            residency["resident_weight_bytes"],
        )
        self.assertEqual(
            plan["claim"]["capsule_bytes"],
            residency["request_claim"]["capsule_bytes"]
            + residency["resident_weight_bytes"],
        )
        self.assertEqual(
            residency["request_claim"],
            result["claim"],
        )
        self.assertNotEqual(plan["claim"], result["claim"])
        self.assertEqual(contract.sha256(output), result["output_sha256"])
        shared_receipt = {
            "bank_epoch": result["resource_bank_epoch"],
            "slot_index": result["resource_slot_index"],
            "generation": result["resource_generation"],
            "owner_key": result["resource_owner_key"],
            "claim": result["claim"],
            "integrity": result["resource_integrity"],
        }
        self.assertTrue(contract.receipt_integrity_valid(shared_receipt))
        self.assertEqual(
            0x8C92016812C6AD3D,
            result["resource_integrity"],
        )

        request_owned = contract.make_residency_binding(
            plan,
            residency=contract.REQUEST_OWNED,
            resident_weight_bytes=0,
            request_claim=plan["claim"],
        )
        contract.validate_residency_binding(request_owned, plan)
        self.assertEqual(
            request_owned,
            contract.decode_residency_binding(
                contract.encode_residency_binding(request_owned)
            ),
        )
        request_owned_receipt = {
            "bank_epoch": 3,
            "slot_index": 1,
            "generation": 9,
            "owner_key": 77,
            "claim": plan["claim"],
            "integrity": 0,
        }
        request_owned_receipt["integrity"] = (
            contract.receipt_integrity(request_owned_receipt)
        )
        request_owned_result = contract.make_residency_result(
            {
                "request_epoch": plan["request_epoch"],
                "next_sequence": plan["publication_next_sequence"],
                "visible_results": plan["publication_next_sequence"],
                "artifact_sha256": artifact["artifact_sha256"],
                "previous_result_sha256": contract.ZERO_DIGEST,
            },
            plan,
            request_owned,
            request_owned_receipt,
            output_sha256=contract.sha256(output),
            source_mapping_sha256=contract.sha256(b"mapping"),
            adapter_sha256=contract.sha256(b"adapter"),
        )
        request_owned_legacy_path = contract.make_result(
            {
                "request_epoch": plan["request_epoch"],
                "next_sequence": plan["publication_next_sequence"],
                "visible_results": plan["publication_next_sequence"],
                "artifact_sha256": artifact["artifact_sha256"],
                "previous_result_sha256": contract.ZERO_DIGEST,
            },
            plan,
            request_owned_receipt,
            output_sha256=contract.sha256(output),
            source_mapping_sha256=contract.sha256(b"mapping"),
            adapter_sha256=contract.sha256(b"adapter"),
        )
        self.assertEqual(request_owned_legacy_path, request_owned_result)

        forged_receipt = dict(request_owned_receipt)
        forged_receipt["integrity"] ^= 1
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "receipt integrity",
        ):
            contract.make_residency_result(
                {
                    "request_epoch": plan["request_epoch"],
                    "next_sequence": plan["publication_next_sequence"],
                    "visible_results": plan[
                        "publication_next_sequence"
                    ],
                    "artifact_sha256": artifact["artifact_sha256"],
                    "previous_result_sha256": contract.ZERO_DIGEST,
                },
                plan,
                request_owned,
                forged_receipt,
                output_sha256=contract.sha256(output),
                source_mapping_sha256=contract.sha256(b"mapping"),
                adapter_sha256=contract.sha256(b"adapter"),
            )

    def test_receipt_integrity_matches_resource_bank_v1(self) -> None:
        _, _, _, result, _ = shared_residency_fixture()
        receipt = {
            "bank_epoch": result["resource_bank_epoch"],
            "slot_index": result["resource_slot_index"],
            "generation": result["resource_generation"],
            "owner_key": result["resource_owner_key"],
            "claim": result["claim"],
            "integrity": result["resource_integrity"],
        }

        def mix64(value: int) -> int:
            value ^= value >> 30
            value = (
                value * 0xBF58476D1CE4E5B9
            ) & contract.U64_MAX
            value ^= value >> 27
            value = (
                value * 0x94D049BB133111EB
            ) & contract.U64_MAX
            value ^= value >> 31
            return value

        expected = mix64(
            0x7265636569707431 ^ receipt["bank_epoch"]
        )
        for value in (
            receipt["slot_index"],
            receipt["generation"],
            receipt["owner_key"],
            receipt["claim"]["capsule_bytes"],
            receipt["claim"]["kv_bytes"],
            receipt["claim"]["activation_bytes"],
            receipt["claim"]["partial_bytes"],
            receipt["claim"]["logits_bytes"],
            receipt["claim"]["output_journal_bytes"],
            receipt["claim"]["staging_bytes"],
            receipt["claim"]["device_bytes"],
            receipt["claim"]["io_bytes"],
            receipt["claim"]["queue_slots"],
        ):
            expected = mix64(expected ^ value)
        self.assertEqual(0x8C92016812C6AD3D, expected)
        self.assertEqual(expected, contract.receipt_integrity(receipt))
        self.assertTrue(contract.receipt_integrity_valid(receipt))

        native_bank_vector = {
            "bank_epoch": 17,
            "slot_index": 0,
            "generation": 1,
            "owner_key": 0xABC,
            "claim": {
                "capsule_bytes": 0,
                "kv_bytes": 400,
                "activation_bytes": 100,
                "partial_bytes": 0,
                "logits_bytes": 0,
                "output_journal_bytes": 16,
                "staging_bytes": 0,
                "device_bytes": 0,
                "io_bytes": 0,
                "queue_slots": 1,
            },
        }
        self.assertEqual(
            0x959D2A79F2EBBC26,
            contract.receipt_integrity(native_bank_vector),
        )

        forged = dict(receipt)
        forged["generation"] += 1
        self.assertFalse(contract.receipt_integrity_valid(forged))
        forged = dict(receipt)
        forged["claim"] = dict(receipt["claim"])
        forged["claim"]["device_bytes"] += 1
        self.assertFalse(contract.receipt_integrity_valid(forged))
        forged = dict(receipt)
        forged["integrity"] ^= 1
        self.assertFalse(contract.receipt_integrity_valid(forged))

    def test_prepared_session_v3_terminal_roots_are_canonical(
        self,
    ) -> None:
        plan_sha256 = bytes(range(32))
        token_domain_sha256 = bytes(range(32, 64))
        token_domain_config_sha256 = bytes(range(64, 96))
        bound_plan_sha256 = bytes(range(96, 128))
        boundary_sha256 = bytes(range(128, 160))
        transcript_sha256 = bytes(range(160, 192))
        result_sha256 = bytes(range(192, 224))
        state_after_sha256 = bytes(range(224, 256))
        tokens = tuple(range(253)) + (
            0x01020304,
            0x00000100,
            0x80000000,
            0xFFFFFFFF,
        )
        self.assertEqual(257, len(tokens))
        self.assertEqual(
            b"\x01\x01\x00\x00\x00\x00\x00\x00",
            struct.pack("<Q", len(tokens)),
        )
        self.assertEqual(
            b"\x04\x03\x02\x01",
            struct.pack("<I", tokens[-4]),
        )

        output_preimage = (
            b"glacier-prepared-text-terminal-output-v1\x00"
            + plan_sha256
            + token_domain_sha256
            + token_domain_config_sha256
            + struct.pack("<Q", len(tokens))
            + b"".join(struct.pack("<I", token) for token in tokens)
        )
        self.assertEqual(145 + 4 * len(tokens), len(output_preimage))
        output_sha256 = hashlib.sha256(output_preimage).digest()
        self.assertEqual(
            "8a2d3d7a69447459d11cac98415e4b59"
            "4f145199584fe66ed567d450c5b70b78",
            output_sha256.hex(),
        )
        self.assertEqual(
            output_sha256,
            contract.prepared_terminal_output_root_v1(
                plan_sha256,
                token_domain_sha256,
                token_domain_config_sha256,
                tokens,
            ),
        )
        contract.verify_prepared_terminal_output_root_v1(
            plan_sha256,
            token_domain_sha256,
            token_domain_config_sha256,
            tokens,
            output_token_count=len(tokens),
            expected_sha256=output_sha256,
        )

        mapping_preimage = (
            b"glacier-prepared-text-terminal-source-mapping-v1\x00"
            + bound_plan_sha256
            + boundary_sha256
            + transcript_sha256
            + output_sha256
            + struct.pack("<Q", len(tokens))
        )
        self.assertEqual(185, len(mapping_preimage))
        source_mapping_sha256 = hashlib.sha256(
            mapping_preimage
        ).digest()
        self.assertEqual(
            "3a58b88d176caec8c43833ddf8701f6b"
            "83e44bd1dc3dcf06b0a2a8b434efeddc",
            source_mapping_sha256.hex(),
        )
        self.assertEqual(
            source_mapping_sha256,
            contract.prepared_terminal_source_mapping_root_v1(
                bound_plan_sha256,
                boundary_sha256,
                transcript_sha256,
                output_sha256,
                len(tokens),
            ),
        )

        adapter_plan = {
            "family": contract.AUTOREGRESSIVE,
            "operation": contract.GENERATE_SEQUENCE,
            "input_kind": contract.TOKEN_ID_INPUT,
            "output_kind": contract.TOKEN_IDS,
            "numerical_policy": 4,
        }
        adapter_sha256 = contract.prepared_terminal_adapter_root_v1(
            adapter_plan,
            bytes(range(32)),
            bytes(range(32, 64)),
            bytes(range(64, 96)),
        )
        self.assertEqual(
            "29f668e7f0b3cdcfc44fe88d81f40836"
            "0a4f9578dbdadeac944dad11d37cbc75",
            adapter_sha256.hex(),
        )
        changed_adapter_plan = dict(adapter_plan)
        changed_adapter_plan["numerical_policy"] = 3
        self.assertNotEqual(
            adapter_sha256,
            contract.prepared_terminal_adapter_root_v1(
                changed_adapter_plan,
                bytes(range(32)),
                bytes(range(32, 64)),
                bytes(range(64, 96)),
            ),
        )

        self.assertEqual(
            b"\x01\x00\x00\x00RTLG",
            struct.pack(
                "<Q",
                contract.PREPARED_TERMINAL_RESULT_EVIDENCE_ABI,
            ),
        )
        evidence_preimage = (
            b"glacier-prepared-text-terminal-result-evidence-v1\x00"
            + struct.pack(
                "<Q",
                contract.PREPARED_TERMINAL_RESULT_EVIDENCE_ABI,
            )
            + boundary_sha256
            + result_sha256
            + state_after_sha256
        )
        self.assertEqual(154, len(evidence_preimage))
        evidence_sha256 = hashlib.sha256(evidence_preimage).digest()
        self.assertEqual(
            "d4b5a780bb8cfb3364738f6ae24a17e4"
            "cbae1a0c4de81b0b6096728d5d1f027a",
            evidence_sha256.hex(),
        )
        self.assertEqual(
            evidence_sha256,
            contract.prepared_terminal_result_evidence_root_v1(
                contract.PREPARED_TERMINAL_RESULT_EVIDENCE_ABI,
                boundary_sha256,
                result_sha256,
                state_after_sha256,
            ),
        )

        mutated_tokens = list(tokens)
        mutated_tokens[-1] ^= 1
        reordered_tokens = list(tokens)
        reordered_tokens[-1], reordered_tokens[-2] = (
            reordered_tokens[-2],
            reordered_tokens[-1],
        )
        for candidate in (mutated_tokens, reordered_tokens):
            with self.assertRaisesRegex(
                contract.ModelContractError,
                "root mismatch",
            ):
                contract.verify_prepared_terminal_output_root_v1(
                    plan_sha256,
                    token_domain_sha256,
                    token_domain_config_sha256,
                    candidate,
                    output_token_count=len(tokens),
                    expected_sha256=output_sha256,
                )
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "count mismatch",
        ):
            contract.verify_prepared_terminal_output_root_v1(
                plan_sha256,
                token_domain_sha256,
                token_domain_config_sha256,
                tokens,
                output_token_count=256,
                expected_sha256=output_sha256,
            )
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "u32 out of range",
        ):
            contract.prepared_terminal_output_root_v1(
                plan_sha256,
                token_domain_sha256,
                token_domain_config_sha256,
                tokens[:-1] + (1 << 32,),
            )

        self.assertNotEqual(
            source_mapping_sha256,
            contract.prepared_terminal_source_mapping_root_v1(
                boundary_sha256,
                bound_plan_sha256,
                transcript_sha256,
                output_sha256,
                len(tokens),
            ),
        )
        self.assertNotEqual(
            source_mapping_sha256,
            contract.prepared_terminal_source_mapping_root_v1(
                bound_plan_sha256,
                boundary_sha256,
                transcript_sha256,
                output_sha256,
                len(tokens) - 1,
            ),
        )
        mutated_boundary = bytearray(boundary_sha256)
        mutated_boundary[0] ^= 1
        self.assertNotEqual(
            evidence_sha256,
            contract.prepared_terminal_result_evidence_root_v1(
                contract.PREPARED_TERMINAL_RESULT_EVIDENCE_ABI,
                bytes(mutated_boundary),
                result_sha256,
                state_after_sha256,
            ),
        )
        self.assertNotEqual(
            evidence_sha256,
            contract.prepared_terminal_result_evidence_root_v1(
                contract.PREPARED_TERMINAL_RESULT_EVIDENCE_ABI,
                boundary_sha256,
                state_after_sha256,
                result_sha256,
            ),
        )

    def test_residency_rejects_mutation_substitution_and_overflow(
        self,
    ) -> None:
        artifact, plan, residency, shared_result, _ = (
            shared_residency_fixture()
        )
        encoded = contract.encode_residency_binding(residency)
        for index in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[index] ^= 1
            with self.assertRaises(contract.ModelContractError):
                contract.decode_residency_binding(bytes(mutated))

        foreign_plan = dict(plan)
        foreign_plan["media_object_sha256"] = contract.sha256(
            b"foreign residency media"
        )
        foreign_plan["plan_sha256"] = contract.ZERO_DIGEST
        foreign_plan = contract.decode_plan(
            contract.encode_plan(foreign_plan)
        )
        with self.assertRaises(contract.ModelContractError):
            contract.validate_residency_binding(residency, foreign_plan)

        foreign_request_claim = dict(
            residency["request_claim"]
        )
        foreign_binding = contract.make_residency_binding(
            foreign_plan,
            residency=contract.SHARED_READ_ONLY,
            resident_weight_bytes=foreign_plan["weight_bytes"],
            request_claim=foreign_request_claim,
        )
        with self.assertRaises(contract.ModelContractError):
            contract.verify_residency_relationships(
                artifact,
                plan,
                foreign_binding,
                shared_result,
            )

        _, _, legacy_result, _, _ = fixture()
        with self.assertRaises(contract.ModelContractError):
            contract.verify_residency_relationships(
                artifact,
                plan,
                residency,
                legacy_result,
            )

        substituted_results = []
        foreign_generation = dict(shared_result)
        foreign_generation["generation"] += 1
        foreign_generation["result_sha256"] = contract.ZERO_DIGEST
        substituted_results.append(
            contract.decode_result(
                contract.encode_result(foreign_generation)
            )
        )
        foreign_processor = dict(shared_result)
        foreign_processor["processor_state_sha256"] = contract.sha256(
            b"foreign result processor"
        )
        foreign_processor["result_sha256"] = contract.ZERO_DIGEST
        substituted_results.append(
            contract.decode_result(
                contract.encode_result(foreign_processor)
            )
        )
        foreign_state = dict(shared_result)
        foreign_state["publication_state_before_sha256"] = (
            contract.sha256(b"foreign publication state")
        )
        foreign_state["publication_commit_sha256"] = (
            contract.publication_commit_root(foreign_state)
        )
        foreign_state["result_sha256"] = contract.ZERO_DIGEST
        substituted_results.append(
            contract.decode_result(
                contract.encode_result(foreign_state)
            )
        )
        foreign_integrity = dict(shared_result)
        foreign_integrity["resource_integrity"] ^= 1
        foreign_integrity["result_sha256"] = contract.ZERO_DIGEST
        substituted_results.append(
            contract.decode_result(
                contract.encode_result(foreign_integrity)
            )
        )
        for substituted_result in substituted_results:
            with self.assertRaises(contract.ModelContractError):
                contract.verify_residency_relationships(
                    artifact,
                    plan,
                    residency,
                    substituted_result,
                )

        wrong_weight_count = plan["weight_bytes"] - 1
        with self.assertRaises(contract.ModelContractError):
            contract.make_residency_binding(
                plan,
                residency=contract.SHARED_READ_ONLY,
                resident_weight_bytes=wrong_weight_count,
                request_claim=residency["request_claim"],
            )
        with self.assertRaises(contract.ModelContractError):
            contract.make_residency_binding(
                plan,
                residency=contract.REQUEST_OWNED,
                resident_weight_bytes=1,
                request_claim=plan["claim"],
            )
        mismatched_request_owned = dict(plan["claim"])
        mismatched_request_owned["activation_bytes"] += 1
        with self.assertRaises(contract.ModelContractError):
            contract.make_residency_binding(
                plan,
                residency=contract.REQUEST_OWNED,
                resident_weight_bytes=0,
                request_claim=mismatched_request_owned,
            )

        host_overflow = dict(residency["request_claim"])
        host_overflow["kv_bytes"] = contract.U64_MAX
        host_overflow["activation_bytes"] = 1
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "host-byte overflow",
        ):
            contract.make_residency_binding(
                plan,
                residency=contract.SHARED_READ_ONLY,
                resident_weight_bytes=plan["weight_bytes"],
                request_claim=host_overflow,
            )

        near_limit_request = dict(plan["claim"])
        near_limit_request["capsule_bytes"] = 1
        near_limit_request["kv_bytes"] = 0
        fixed_host_bytes = contract.claim_host_bytes(
            near_limit_request
        )
        near_limit_request["kv_bytes"] = (
            contract.U64_MAX - fixed_host_bytes - 2
        )
        contract.claim_host_bytes(near_limit_request)
        aggregate_overflow_plan = dict(plan)
        aggregate_overflow_plan["claim"] = dict(near_limit_request)
        aggregate_overflow_plan["claim"]["capsule_bytes"] += plan[
            "weight_bytes"
        ]
        aggregate_overflow_plan["plan_sha256"] = contract.ZERO_DIGEST
        aggregate_overflow_plan = contract.decode_plan(
            contract.encode_plan(aggregate_overflow_plan)
        )
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "host-byte overflow",
        ):
            contract.make_residency_binding(
                aggregate_overflow_plan,
                residency=contract.SHARED_READ_ONLY,
                resident_weight_bytes=plan["weight_bytes"],
                request_claim=near_limit_request,
            )

        projection_overflow = dict(residency["request_claim"])
        projection_overflow["capsule_bytes"] = contract.U64_MAX
        projection_overflow["activation_bytes"] = 0
        with self.assertRaises(contract.ModelContractError):
            contract.make_residency_binding(
                plan,
                residency=contract.SHARED_READ_ONLY,
                resident_weight_bytes=plan["weight_bytes"],
                request_claim=projection_overflow,
            )

    def test_support_is_explicit_and_capability_closed(self) -> None:
        _, plan, _, _, _ = fixture()
        support = [
            {
                "family": contract.VISION_UNDERSTANDING,
                "operation": contract.ENCODE,
                "input_kind": contract.IMAGE_FEATURE_U8,
                "output_kind": contract.EMBEDDING_I32,
                "numerical_policy": contract.EXACT_INTEGER,
                "max_batch_items": 2,
                "max_input_features": 4,
                "max_output_dimensions": 2,
                "allowed_capabilities": 0,
            }
        ]
        contract.require_support(support, plan)
        unsupported = dict(plan)
        unsupported["operation"] = 4
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "unsupported operation",
        ):
            contract.require_support(support, unsupported)
        unsupported = dict(plan)
        unsupported["required_capabilities"] = 1
        with self.assertRaisesRegex(
            contract.ModelContractError,
            "unsupported capabilities",
        ):
            contract.require_support(support, unsupported)

    def test_token_ids_exact_shape_is_canonical(self) -> None:
        artifact, plan, result, output = token_ids_fixture()
        self.assertEqual(contract.TOKEN_IDS, artifact["output_kind"])
        self.assertEqual(contract.TOKEN_IDS, plan["output_kind"])
        self.assertEqual(contract.TOKEN_IDS, result["output_kind"])
        self.assertEqual(4, plan["input_features"])
        self.assertEqual(1, plan["output_dimensions"])
        self.assertEqual(16, plan["input_bytes"])
        self.assertEqual(4, plan["output_bytes"])
        self.assertEqual(contract.sha256(output), result["output_sha256"])
        self.assertEqual(
            artifact,
            contract.decode_artifact(contract.encode_artifact(artifact)),
        )
        self.assertEqual(
            plan,
            contract.decode_plan(contract.encode_plan(plan)),
        )
        self.assertEqual(
            result,
            contract.decode_result(contract.encode_result(result)),
        )

    def test_every_wire_byte_is_authenticated(self) -> None:
        artifact, plan, result, _, _ = fixture()
        cases = (
            (
                contract.encode_artifact(artifact),
                contract.decode_artifact,
            ),
            (contract.encode_plan(plan), contract.decode_plan),
            (contract.encode_result(result), contract.decode_result),
        )
        for wire, decoder in cases:
            for index in range(len(wire)):
                mutated = bytearray(wire)
                mutated[index] ^= 1
                with self.assertRaises(contract.ModelContractError):
                    decoder(bytes(mutated))

    def test_plan_and_result_substitution_reject(self) -> None:
        artifact, plan, result, _, _ = fixture()
        unknown_family = dict(artifact)
        unknown_family["family"] = 99
        unknown_family["artifact_sha256"] = contract.ZERO_DIGEST
        with self.assertRaises(contract.ModelContractError):
            contract.encode_artifact(unknown_family)
        foreign_artifact = dict(artifact)
        foreign_artifact["metadata_sha256"] = contract.sha256(
            b"foreign metadata"
        )
        with self.assertRaises(contract.ModelContractError):
            contract.encode_artifact(foreign_artifact)
        foreign_plan = dict(plan)
        foreign_plan["media_object_sha256"] = contract.sha256(
            b"foreign media"
        )
        with self.assertRaises(contract.ModelContractError):
            contract.encode_plan(foreign_plan)
        foreign_result = dict(result)
        foreign_result["output_sha256"] = contract.sha256(
            b"foreign output"
        )
        with self.assertRaises(contract.ModelContractError):
            contract.encode_result(foreign_result)


if __name__ == "__main__":
    unittest.main()
