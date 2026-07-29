"""Independent tests for package identity and durable raw-input archives."""

from __future__ import annotations

import copy
import unittest

from bench import prepared_text_package as package
from bench import prepared_text_raw_input as raw_input


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def manifest_input(
    tokenizer_manifest: bytes,
) -> dict[str, object]:
    tokenizer = raw_input.decode_manifest(tokenizer_manifest)
    return {
        "family": 1,
        "source_format": 1,
        "portable_format_abi": 0x474C_4143_0000_0001,
        "conversion_profile_abi": 0x474C_4350_0000_0001,
        "conversion_plan_abi": 0x474C_434E_0000_0001,
        "tokenizer_manifest_abi": raw_input.MANIFEST_ABI,
        "tokenizer_manifest_bytes": raw_input.MANIFEST_BYTES,
        "source_bytes": 1000,
        "portable_bytes": 700,
        "portable_page_count": 4,
        "license_bytes": 21,
        "model_profile_id": package.ORDINARY_PACKAGE_PROFILE_ID,
        "tensor_profile_abi": 0x474C_5450_0000_0001,
        "tensor_count": 21,
        "tensor_inventory_sha256": digest(0xAA),
        "config": {
            "dim": 64,
            "hidden_dim": 128,
            "layers": 2,
            "vocab": tokenizer["vocab_size"],
            "heads": 1,
            "head_dim": 64,
            "kv_heads": 1,
            "rms_eps": 1e-5,
            "rope_theta": 10000.0,
            "tie_embeddings": False,
        },
        "source_sha256": digest(0x11),
        "portable_artifact_sha256": digest(0x22),
        "conversion_profile_sha256": digest(0x33),
        "conversion_plan_sha256": digest(0x44),
        "model_content_sha256": digest(0x55),
        "tokenizer_config_sha256": tokenizer["config_sha256"],
        "tokenizer_domain_sha256": tokenizer["domain_sha256"],
        "tokenizer_behavior_sha256": tokenizer["behavior_sha256"],
        "license_sha256": digest(0x99),
    }


def fixture(text: str = "Glacier สวัสดี") -> dict[str, object]:
    tokens, tokenizer_manifest, tokenizer_prompt = raw_input.tokenize(
        text,
        vocab_size=512,
        max_input_bytes=4096,
    )
    raw_text = text.encode("utf-8")
    package_input = manifest_input(tokenizer_manifest)
    package_wire = package.encode_manifest(package_input)
    decoded_package = package.decode_manifest(package_wire)
    representation_input = {
        "format_abi": 0x474C_5254_0000_0002,
        "format_version": 2,
        "container_bytes": 901,
        "package_sha256": decoded_package["package_sha256"],
        "resolved_config_sha256": decoded_package["resolved_config_sha256"],
        "source_fingerprint": decoded_package["model_content_sha256"],
        "abi_fingerprint": digest(0xA1),
        "container_sha256": digest(0xA2),
    }
    representation_wire = package.encode_prepared_representation(representation_input)
    admission_bundle = package.encode_admission_bundle(
        package_wire,
        representation_wire,
    )
    prompt = raw_input.decode_prompt(tokenizer_prompt)
    binding_report = {
        "tokenizer_domain_sha256": raw_input.tokenizer_domain_sha256().hex(),
        "tokenizer_config_sha256": decoded_package["tokenizer_config_sha256"].hex(),
        "prompt_receipt_sha256": prompt["receipt_sha256"].hex(),
        "raw_text_sha256": package.raw_text_sha256(raw_text).hex(),
        "token_ids_sha256": package.token_ids_sha256(raw_text).hex(),
        "prepared_prompt_sha256": package.prepared_prompt_sha256(raw_text).hex(),
        "local_plan_sha256": digest(0xB1).hex(),
        "bound_plan_sha256": digest(0xB2).hex(),
        "artifact_sha256": digest(0xB3).hex(),
        "execution_plan_sha256": digest(0xB4).hex(),
        "residency_binding_sha256": digest(0xB5).hex(),
        "artifact_license_sha256": decoded_package["license_sha256"].hex(),
        "request_epoch": 7,
        "prompt_tokens": len(tokens),
        "prompt_bytes": len(raw_text),
    }
    binding_wire = raw_input.binding_wire_from_report(binding_report)
    archive_wire = package.archive_wire(
        package=package_wire,
        representation=representation_wire,
        tokenizer_manifest=tokenizer_manifest,
        tokenizer_prompt=tokenizer_prompt,
        binding=binding_wire,
        raw_text=raw_text,
    )
    return {
        "text": text,
        "tokens": tokens,
        "raw_text": raw_text,
        "package_input": package_input,
        "package_wire": package_wire,
        "representation_input": representation_input,
        "representation_wire": representation_wire,
        "admission_bundle": admission_bundle,
        "tokenizer_manifest": tokenizer_manifest,
        "tokenizer_prompt": tokenizer_prompt,
        "binding_report": binding_report,
        "binding_wire": binding_wire,
        "archive_wire": archive_wire,
    }


def supported_manifest_input(
    group_size: int = 16,
) -> dict[str, object]:
    _, tokenizer_manifest, _ = raw_input.tokenize(
        "Ice",
        vocab_size=512,
        max_input_bytes=4096,
    )
    value = manifest_input(tokenizer_manifest)
    tensor_count, tensor_root = (
        package.ordinary_tensor_inventory_sha256(
            value["config"]
        )
    )
    value["tensor_profile_abi"] = package.TENSOR_PROFILE_ABI
    value["tensor_count"] = tensor_count
    value["tensor_inventory_sha256"] = tensor_root
    value["conversion_profile_sha256"] = (
        package.conversion_profile_sha256(group_size)
    )
    value["model_content_sha256"] = (
        package.profiled_model_content_sha256(value)
    )
    return value


class PreparedTextPackageTests(unittest.TestCase):
    def test_supported_ordinary_profile_is_independently_admitted(
        self,
    ) -> None:
        value = supported_manifest_input()
        decoded = package.decode_manifest(
            package.encode_manifest(value)
        )
        self.assertEqual(
            16,
            package.validate_supported_ordinary_package(
                decoded
            ),
        )
        self.assertEqual(21, decoded["tensor_count"])

        group_32 = copy.deepcopy(value)
        group_32["conversion_profile_sha256"] = (
            package.conversion_profile_sha256(32)
        )
        group_32["model_content_sha256"] = (
            package.profiled_model_content_sha256(group_32)
        )
        self.assertEqual(
            32,
            package.validate_supported_ordinary_package(
                package.decode_manifest(
                    package.encode_manifest(group_32)
                )
            ),
        )

        mutations: list[tuple[str, dict[str, object]]] = []
        wrong_inventory = copy.deepcopy(decoded)
        wrong_inventory["tensor_inventory_sha256"] = digest(
            0x71
        )
        wrong_inventory["model_content_sha256"] = (
            package.profiled_model_content_sha256(
                wrong_inventory
            )
        )
        mutations.append(("inventory", wrong_inventory))

        wrong_conversion = copy.deepcopy(decoded)
        wrong_conversion["conversion_profile_sha256"] = digest(
            0x72
        )
        wrong_conversion["model_content_sha256"] = (
            package.profiled_model_content_sha256(
                wrong_conversion
            )
        )
        mutations.append(("conversion", wrong_conversion))

        tied = copy.deepcopy(decoded)
        tied["config"]["tie_embeddings"] = True
        tied["model_content_sha256"] = (
            package.profiled_model_content_sha256(tied)
        )
        mutations.append(("tied", tied))

        wrong_profile = copy.deepcopy(decoded)
        wrong_profile["model_profile_id"] = 2
        wrong_profile["model_profile_sha256"] = (
            package.model_profile_sha256(2)
        )
        wrong_profile["model_content_sha256"] = (
            package.profiled_model_content_sha256(
                wrong_profile
            )
        )
        mutations.append(("profile", wrong_profile))

        for label, changed in mutations:
            with self.subTest(label=label):
                with self.assertRaises(
                    package.PreparedTextPackageError
                ):
                    package.validate_supported_ordinary_package(
                        changed
                    )

    def test_admission_bundle_roundtrip_authenticates_both_records(
        self,
    ) -> None:
        value = fixture("Ice")
        decoded = package.decode_admission_bundle(value["admission_bundle"])
        self.assertEqual(896, package.ADMISSION_BUNDLE_BYTES)
        self.assertEqual(
            package.ADMISSION_BUNDLE_BYTES,
            len(value["admission_bundle"]),
        )
        self.assertEqual(
            value["package_wire"],
            value["admission_bundle"][: package.MANIFEST_BYTES],
        )
        self.assertEqual(
            value["representation_wire"],
            value["admission_bundle"][package.MANIFEST_BYTES :],
        )
        self.assertEqual(
            decoded["package"]["package_sha256"],
            decoded["representation"]["package_sha256"],
        )
        self.assertEqual(
            decoded["package"]["model_content_sha256"],
            decoded["representation"]["source_fingerprint"],
        )

    def test_admission_bundle_rejects_every_byte_mutation(self) -> None:
        wire = fixture("Ice")["admission_bundle"]
        for index in range(len(wire)):
            mutated = bytearray(wire)
            mutated[index] ^= 1
            with self.subTest(byte=index):
                with self.assertRaises(package.PreparedTextPackageError):
                    package.decode_admission_bundle(bytes(mutated))

    def test_admission_bundle_rejects_foreign_relationship(self) -> None:
        value = fixture("Ice")
        changed = copy.deepcopy(value["package_input"])
        changed["source_sha256"] = digest(0xD1)
        foreign_manifest = package.encode_manifest(changed)
        mismatched = foreign_manifest + value["representation_wire"]

        with self.assertRaises(package.PreparedTextPackageError):
            package.encode_admission_bundle(
                foreign_manifest,
                value["representation_wire"],
            )
        with self.assertRaises(package.PreparedTextPackageError):
            package.decode_admission_bundle(mismatched)

    def test_model_content_root_binds_portable_artifact_and_config(
        self,
    ) -> None:
        value = fixture("Ice")["package_input"]
        root = package.model_content_sha256(
            value["portable_artifact_sha256"],
            value["config"],
        )
        self.assertEqual(
            "9836d18147e0bb120249360edd1a07705597b0f52ffd4b1afe230a99332b265f",
            root.hex(),
        )

        changed_artifact = package.model_content_sha256(
            digest(0x23),
            value["config"],
        )
        changed_config = copy.deepcopy(value["config"])
        changed_config["hidden_dim"] = 256
        changed_geometry = package.model_content_sha256(
            value["portable_artifact_sha256"],
            changed_config,
        )
        self.assertNotEqual(root, changed_artifact)
        self.assertNotEqual(root, changed_geometry)

    def test_profiled_model_content_binds_execution_semantics(
        self,
    ) -> None:
        value = copy.deepcopy(fixture("Ice")["package_input"])
        root = package.profiled_model_content_sha256(value)
        self.assertNotEqual(bytes(32), root)

        mutations = {
            "family": 2,
            "source_format": 2,
            "portable_format_abi": value["portable_format_abi"] + 1,
            "conversion_profile_abi": value["conversion_profile_abi"] + 1,
            "conversion_plan_abi": value["conversion_plan_abi"] + 1,
            "model_profile_id": 2,
            "tensor_profile_abi": value["tensor_profile_abi"] + 1,
            "tensor_count": value["tensor_count"] + 1,
            "portable_artifact_sha256": digest(0xA1),
            "conversion_profile_sha256": digest(0xA2),
            "conversion_plan_sha256": digest(0xA3),
            "tensor_inventory_sha256": digest(0xA4),
        }
        for name, replacement in mutations.items():
            changed = copy.deepcopy(value)
            changed[name] = replacement
            with self.subTest(field=name):
                self.assertNotEqual(
                    root,
                    package.profiled_model_content_sha256(changed),
                )

        changed_config = copy.deepcopy(value)
        changed_config["config"]["hidden_dim"] += 1
        self.assertNotEqual(
            root,
            package.profiled_model_content_sha256(
                changed_config
            ),
        )

    def test_model_profile_root_is_canonical_and_manifest_bound(
        self,
    ) -> None:
        value = fixture("Ice")
        decoded = package.decode_manifest(value["package_wire"])
        expected = package.model_profile_sha256(
            package.ORDINARY_PACKAGE_PROFILE_ID
        )
        self.assertEqual(
            "ec0c880425e992f83d6609748288f300b8facf6e802ee181f9dad9ba2a766095",
            expected.hex(),
        )
        self.assertEqual(package.MODEL_PROFILE_ABI, decoded["model_profile_abi"])
        self.assertEqual(
            package.ORDINARY_PACKAGE_PROFILE_ID,
            decoded["model_profile_id"],
        )
        self.assertEqual(expected, decoded["model_profile_sha256"])

        changed = copy.deepcopy(value["package_input"])
        changed["model_profile_id"] = 2
        alternate = package.decode_manifest(
            package.encode_manifest(changed)
        )
        self.assertEqual(2, alternate["model_profile_id"])
        self.assertEqual(
            package.model_profile_sha256(2),
            alternate["model_profile_sha256"],
        )
        self.assertNotEqual(
            decoded["package_sha256"],
            alternate["package_sha256"],
        )

    def test_manifest_requires_profile_flag_and_tensor_identity(
        self,
    ) -> None:
        value = fixture("Ice")
        wire = value["package_wire"]
        self.assertEqual(
            package.MANIFEST_ALLOWED_FLAGS,
            int.from_bytes(wire[24:32], "little"),
        )
        self.assertEqual(
            value["package_input"]["tensor_inventory_sha256"],
            wire[560:592],
        )

        for field, invalid in (
            ("model_profile_id", 0),
            ("tensor_profile_abi", 0),
            ("tensor_count", 0),
            ("tensor_inventory_sha256", bytes(32)),
        ):
            changed = copy.deepcopy(value["package_input"])
            changed[field] = invalid
            with self.subTest(field=field):
                with self.assertRaises(package.PreparedTextPackageError):
                    package.encode_manifest(changed)

        missing_flag = bytearray(wire)
        missing_flag[24:32] = bytes(8)
        missing_flag[-32:] = package.package_sha256(
            bytes(missing_flag[:-32])
        )
        with self.assertRaises(package.PreparedTextPackageError):
            package.decode_manifest(bytes(missing_flag))

        legacy_v1 = bytearray(wire)
        legacy_v1[0:8] = b"GLPKG01\x00"
        legacy_v1[8:16] = (0x474C_504B_0000_0001).to_bytes(
            8,
            "little",
        )
        legacy_v1[24:32] = bytes(8)
        with self.assertRaises(package.PreparedTextPackageError):
            package.decode_manifest(bytes(legacy_v1))

    def test_package_archive_golden_and_fresh_retokenization(self) -> None:
        value = fixture()
        decoded = package.decode_archive(value["archive_wire"])
        self.assertEqual(value["raw_text"], decoded["raw_text"])
        self.assertEqual(value["tokens"], decoded["tokens"])
        self.assertEqual(
            decoded["package"]["package_sha256"],
            decoded["representation"]["package_sha256"],
        )
        self.assertEqual(
            "7260ad48dd13c6f052e48f15dc25a9f0293b3f5b6bc985cc938ce1422816ba5f",
            decoded["package"]["resolved_config_sha256"].hex(),
        )
        self.assertEqual(
            "53f717ab3b0f0dedb859e6077c6e220f7963c887653989500bb0dd9da1f9f97a",
            package.raw_text_sha256(value["raw_text"]).hex(),
        )
        self.assertEqual(
            "7d3093422da5b6c1b879657cdc56d1efaf9a622eb8bec5b6c909504d8355a68f",
            package.token_ids_sha256(value["raw_text"]).hex(),
        )
        self.assertEqual(
            "5814d5cfd1dc516717cd52d1fde0c31d02fb17840d0794f6ae511cc99ed08d02",
            package.prepared_prompt_sha256(value["raw_text"]).hex(),
        )
        self.assertEqual(
            "3ac2f8a5e8a4831b019e775e4797e6c4e0a5bef228b3eef11227844011ba4e7b",
            decoded["package"]["package_sha256"].hex(),
        )
        self.assertEqual(
            "4e6425fa67b9c285d9e28dd86cd55536c640dd9b9aa16a741c3c24b64852ce6f",
            decoded["representation"]["representation_sha256"].hex(),
        )
        self.assertEqual(
            "a74cbd45cf903a1b429319832a17a472ac55b72a5b7fd46991573fbfca099257",
            decoded["archive_sha256"].hex(),
        )

    def test_component_codecs_reject_every_byte_mutation(self) -> None:
        value = fixture("Ice")
        for name, decoder in (
            ("package_wire", package.decode_manifest),
            (
                "representation_wire",
                package.decode_prepared_representation,
            ),
        ):
            wire = value[name]
            for index in range(len(wire)):
                mutated = bytearray(wire)
                mutated[index] ^= 1
                with self.subTest(component=name, byte=index):
                    with self.assertRaises(package.PreparedTextPackageError):
                        decoder(bytes(mutated))

    def test_archive_rejects_every_byte_mutation(self) -> None:
        wire = fixture("Ice")["archive_wire"]
        for index in range(len(wire)):
            mutated = bytearray(wire)
            mutated[index] ^= 1
            with self.subTest(byte=index):
                with self.assertRaises(package.PreparedTextPackageError):
                    package.decode_archive(bytes(mutated))

    def test_archive_rejects_re_rooted_context_substitution(self) -> None:
        value = fixture("Ice")
        report = copy.deepcopy(value["binding_report"])
        report["tokenizer_config_sha256"] = digest(0xE1).hex()
        foreign_binding = raw_input.binding_wire_from_report(report)
        foreign_archive = package.archive_wire(
            package=value["package_wire"],
            representation=value["representation_wire"],
            tokenizer_manifest=value["tokenizer_manifest"],
            tokenizer_prompt=value["tokenizer_prompt"],
            binding=foreign_binding,
            raw_text=value["raw_text"],
        )
        with self.assertRaises(package.PreparedTextPackageError):
            package.decode_archive(foreign_archive)

        report = copy.deepcopy(value["binding_report"])
        report["prepared_prompt_sha256"] = digest(0xE2).hex()
        foreign_binding = raw_input.binding_wire_from_report(report)
        foreign_archive = package.archive_wire(
            package=value["package_wire"],
            representation=value["representation_wire"],
            tokenizer_manifest=value["tokenizer_manifest"],
            tokenizer_prompt=value["tokenizer_prompt"],
            binding=foreign_binding,
            raw_text=value["raw_text"],
        )
        with self.assertRaises(package.PreparedTextPackageError):
            package.decode_archive(foreign_archive)

    def test_package_identity_is_request_and_representation_independent(
        self,
    ) -> None:
        value = fixture("Ice")
        changed = copy.deepcopy(value["representation_input"])
        changed["container_sha256"] = digest(0xD1)
        changed["abi_fingerprint"] = digest(0xD2)
        second_wire = package.encode_prepared_representation(changed)
        first = package.decode_prepared_representation(value["representation_wire"])
        second = package.decode_prepared_representation(second_wire)
        self.assertEqual(
            first["package_sha256"],
            second["package_sha256"],
        )
        self.assertNotEqual(
            first["representation_sha256"],
            second["representation_sha256"],
        )

        second_request = fixture("Snow")
        self.assertEqual(
            package.decode_manifest(value["package_wire"])["package_sha256"],
            package.decode_manifest(second_request["package_wire"])["package_sha256"],
        )

    def test_package_scalar_and_geometry_rules_are_strict(self) -> None:
        value = fixture("Ice")
        for field, invalid in (
            ("family", True),
            ("source_format", 4),
            ("source_bytes", 0),
        ):
            changed = copy.deepcopy(value["package_input"])
            changed[field] = invalid
            with self.subTest(field=field):
                with self.assertRaises(package.PreparedTextPackageError):
                    package.encode_manifest(changed)
        for field, invalid in (
            ("dim", 65),
            ("kv_heads", 2),
            ("rms_eps", float("inf")),
            ("rope_theta", -1.0),
            ("tie_embeddings", 1),
        ):
            changed = copy.deepcopy(value["package_input"])
            changed["config"][field] = invalid
            with self.subTest(config_field=field):
                with self.assertRaises(package.PreparedTextPackageError):
                    package.encode_manifest(changed)

    def test_archive_rejects_invalid_utf8_after_full_reroot(self) -> None:
        value = fixture("Ice")
        invalid = package.archive_wire(
            package=value["package_wire"],
            representation=value["representation_wire"],
            tokenizer_manifest=value["tokenizer_manifest"],
            tokenizer_prompt=value["tokenizer_prompt"],
            binding=value["binding_wire"],
            raw_text=b"\xffce",
        )
        with self.assertRaises(package.PreparedTextPackageError):
            package.decode_archive(invalid)


if __name__ == "__main__":
    unittest.main()
