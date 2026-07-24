from __future__ import annotations

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
