from __future__ import annotations

from dataclasses import fields, replace
from itertools import permutations
import unittest

from bench import device_capability_contract as contract


class DeviceCapabilityContractOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.gpu_a = contract.make_fixture_capability(
            contract.BACKEND_METAL,
            contract.DEVICE_ACCELERATOR,
            "test gpu a",
        )
        self.gpu_b = contract.make_fixture_capability(
            contract.BACKEND_PORTABLE_COMPUTE,
            contract.DEVICE_ACCELERATOR,
            "test gpu b",
        )
        self.cpu = contract.make_fixture_capability(
            contract.BACKEND_CPU,
            contract.DEVICE_CPU,
            "test cpu",
        )
        self.entry_a = contract.make_fixture_entry(
            self.gpu_a, epoch=10, rank=5
        )
        self.entry_b = contract.make_fixture_entry(
            self.gpu_b, epoch=20, rank=1
        )
        self.entry_cpu = contract.make_fixture_entry(
            self.cpu, epoch=30, rank=0
        )
        self.requirement = contract.make_fixture_requirement(
            contract.FALLBACK_EXPLICIT_CPU
        )
        self.inventory = (
            self.entry_a,
            self.entry_b,
            self.entry_cpu,
        )

    def test_literal_golden_roots_are_independent_and_fixed(self) -> None:
        selection = contract.select_device(
            self.requirement, self.inventory
        )
        actual = {
            "gpu_a_capability": self.gpu_a.capability_sha256.hex(),
            "gpu_b_capability": self.gpu_b.capability_sha256.hex(),
            "cpu_capability": self.cpu.capability_sha256.hex(),
            "gpu_a_entry": self.entry_a.entry_sha256.hex(),
            "gpu_b_entry": self.entry_b.entry_sha256.hex(),
            "cpu_entry": self.entry_cpu.entry_sha256.hex(),
            "requirement": self.requirement.requirement_sha256.hex(),
            "inventory": contract.inventory_root(self.inventory).hex(),
            "selection": selection.receipt.receipt_sha256.hex(),
        }
        expected = {
            "gpu_a_capability": (
                "e60b628ce213fa5af30dd2b5b3887475"
                "88c9edc68c9503490799253461463855"
            ),
            "gpu_b_capability": (
                "3b7285ee03e211332bbba63105633bc2"
                "61eaf0295a755afd3b9906487667d255"
            ),
            "cpu_capability": (
                "f5566dcde38e7ee8ed44cbdd6c21613b"
                "284af5d1c30492d5e5ccd566118f3902"
            ),
            "gpu_a_entry": (
                "b1ab1dd19213127f5ce9e8ae776c0c1f"
                "07a4fec759290ee2f8930eb48668d7f1"
            ),
            "gpu_b_entry": (
                "2bf11a9c20bf6e2c90d6b5619512b6ab"
                "f152a053f490abf6d32c4e1f5c64409f"
            ),
            "cpu_entry": (
                "e48176e389602e0cc21fd96f3f3591bd"
                "6e24972f2cd859ce1eb4e0c9428cd0ea"
            ),
            "requirement": (
                "16473fa6529e34802c9fe20556588c0e"
                "3a69c58a501acf89b09f88d4b31d8488"
            ),
            "inventory": (
                "91964f9334fa667cd45e1da054da2c68"
                "4ca083983897e411a0ca17ede11dbbf2"
            ),
            "selection": (
                "25a3339e96e33bc7742a0051cafc047f"
                "1b96e4205365739a8ba849afaf692813"
            ),
        }
        self.assertEqual(expected, actual)

    def test_all_six_discovery_permutations_select_identically(self) -> None:
        discovered = tuple(permutations(self.inventory))
        self.assertEqual(6, len(discovered))

        receipts = []
        for inventory in discovered:
            with self.subTest(
                order=tuple(entry.discovery_epoch for entry in inventory)
            ):
                selection = contract.select_device(
                    self.requirement, inventory
                )
                self.assertEqual(
                    self.gpu_b.capability_sha256,
                    selection.receipt.selected_capability_sha256,
                )
                self.assertEqual(2, selection.receipt.compatible_count)
                self.assertEqual(0, selection.receipt.fallback_used)
                contract.validate_selection_receipt(
                    selection.receipt,
                    self.requirement,
                    inventory,
                )
                receipts.append(selection.receipt)
        self.assertTrue(all(receipt == receipts[0] for receipt in receipts))

    def test_explicit_cpu_fallback_is_observable_and_golden(self) -> None:
        incompatible_gpu = contract.make_fixture_capability(
            contract.BACKEND_METAL,
            contract.DEVICE_ACCELERATOR,
            "fallback gpu",
            contract.PROFILE_DEQUANTIZE_INT4_F16,
        )
        fallback_cpu = contract.make_fixture_capability(
            contract.BACKEND_CPU,
            contract.DEVICE_CPU,
            "fallback cpu",
        )
        inventory = (
            contract.make_fixture_entry(
                incompatible_gpu, epoch=1, rank=0
            ),
            contract.make_fixture_entry(
                fallback_cpu, epoch=2, rank=99
            ),
        )
        allowed = contract.make_fixture_requirement(
            contract.FALLBACK_EXPLICIT_CPU
        )
        selection = contract.select_device(allowed, inventory)

        self.assertEqual(contract.DEVICE_CPU, selection.receipt.selected_device_class)
        self.assertEqual(contract.BACKEND_CPU, selection.receipt.selected_backend_kind)
        self.assertEqual(1, selection.receipt.fallback_used)
        self.assertEqual(
            fallback_cpu.capability_sha256,
            selection.receipt.selected_capability_sha256,
        )
        self.assertEqual(
            "6dfb63e822d74f15303d1faccf0d926f"
            "5432a1d3a006d8cb5de362f0828fa06d",
            selection.receipt.inventory_sha256.hex(),
        )
        self.assertEqual(
            "c16b4b89a5165a36a87ebd75a097ab9"
            "d0dbc9b94607016f4d14003b3433a20de",
            selection.receipt.receipt_sha256.hex(),
        )

        forbidden = contract.make_fixture_requirement(
            contract.FALLBACK_FORBIDDEN
        )
        with self.assertRaises(contract.NoCompatibleDevice):
            contract.select_device(forbidden, inventory)

    def test_direct_cpu_requirement_is_not_fallback(self) -> None:
        requirement = contract.seal_requirement(
            replace(
                self.requirement,
                requirement_sha256=contract.ZERO_DIGEST,
                required_device_class=contract.DEVICE_CPU,
                fallback_policy=contract.FALLBACK_FORBIDDEN,
            )
        )
        inventory = (
            contract.make_fixture_entry(
                self.cpu,
                epoch=7,
                rank=0,
            ),
        )
        selection = contract.select_device(requirement, inventory)
        self.assertEqual(
            contract.DEVICE_CPU,
            selection.receipt.selected_device_class,
        )
        self.assertEqual(0, selection.receipt.fallback_used)
        contract.validate_selection_receipt(
            selection.receipt,
            requirement,
            inventory,
        )

    def test_pin_is_exact_and_never_falls_back(self) -> None:
        incompatible_gpu = contract.make_fixture_capability(
            contract.BACKEND_METAL,
            contract.DEVICE_ACCELERATOR,
            "pinned incompatible gpu",
            contract.PROFILE_DEQUANTIZE_INT4_F16,
        )
        fallback_cpu = contract.make_fixture_capability(
            contract.BACKEND_CPU,
            contract.DEVICE_CPU,
            "pinned fallback cpu",
        )
        inventory = (
            contract.make_fixture_entry(
                incompatible_gpu, epoch=1, rank=0
            ),
            contract.make_fixture_entry(
                fallback_cpu, epoch=2, rank=1
            ),
        )
        forbidden = contract.make_fixture_requirement(
            contract.FALLBACK_FORBIDDEN
        )
        pinned = contract.seal_requirement(
            replace(
                forbidden,
                requirement_sha256=contract.ZERO_DIGEST,
                pinned_capability_sha256=(
                    incompatible_gpu.capability_sha256
                ),
            )
        )
        with self.assertRaises(contract.NoCompatibleDevice):
            contract.select_device(pinned, inventory)

        absent_pin = contract.seal_requirement(
            replace(
                forbidden,
                requirement_sha256=contract.ZERO_DIGEST,
                pinned_capability_sha256=contract.digest_v1(
                    "absent capability"
                ),
            )
        )
        with self.assertRaises(contract.NoCompatibleDevice):
            contract.select_device(absent_pin, inventory)

        allowed = contract.make_fixture_requirement(
            contract.FALLBACK_EXPLICIT_CPU
        )
        with self.assertRaises(contract.InvalidRequirement):
            contract.seal_requirement(
                replace(
                    allowed,
                    requirement_sha256=contract.ZERO_DIGEST,
                    pinned_capability_sha256=(
                        incompatible_gpu.capability_sha256
                    ),
                )
            )

    def test_duplicate_entry_capability_and_device_reject(self) -> None:
        with self.assertRaises(contract.DuplicateInventoryEntry):
            contract.inventory_root((self.entry_a, self.entry_a))

        same_capability_new_entry = contract.make_fixture_entry(
            self.gpu_a, epoch=99, rank=99
        )
        with self.assertRaises(contract.DuplicateCapability):
            contract.inventory_root(
                (self.entry_a, same_capability_new_entry)
            )

        different_capability_same_device = contract.seal_capability(
            replace(
                self.gpu_a,
                backend_kind=contract.BACKEND_PORTABLE_COMPUTE,
                capability_sha256=contract.ZERO_DIGEST,
            )
        )
        same_device_entry = contract.make_fixture_entry(
            different_capability_same_device, epoch=100, rank=100
        )
        with self.assertRaises(contract.DuplicateDevice):
            contract.inventory_root((self.entry_a, same_device_entry))

        same_physical_device_other_backend = contract.seal_capability(
            replace(
                self.gpu_a,
                backend_kind=contract.BACKEND_PORTABLE_COMPUTE,
                backend_sha256=contract.digest_v1(
                    "independent portable backend"
                ),
                capability_sha256=contract.ZERO_DIGEST,
            )
        )
        other_backend_entry = contract.make_fixture_entry(
            same_physical_device_other_backend,
            epoch=101,
            rank=101,
        )
        self.assertNotEqual(
            contract.ZERO_DIGEST,
            contract.inventory_root(
                (self.entry_a, other_backend_entry)
            ),
        )

    def test_non_present_entries_never_win(self) -> None:
        for state in (
            contract.INVENTORY_UNAVAILABLE,
            contract.INVENTORY_LOST,
        ):
            with self.subTest(state=state):
                inventory = (
                    contract.make_fixture_entry(
                        self.gpu_a, epoch=1, rank=0, state=state
                    ),
                )
                self.assertNotEqual(
                    contract.ZERO_DIGEST,
                    contract.inventory_root(inventory),
                )
                with self.assertRaises(contract.NoCompatibleDevice):
                    contract.select_device(
                        self.requirement, inventory
                    )

    def test_unknown_physical_ceilings_reject_nonzero_requirements(self) -> None:
        for field_name in (
            "max_single_allocation_bytes",
            "max_total_device_bytes",
            "max_queue_slots",
        ):
            with self.subTest(field=field_name):
                unknown = contract.seal_capability(
                    replace(
                        self.gpu_a,
                        capability_sha256=contract.ZERO_DIGEST,
                        **{field_name: 0},
                    )
                )
                inventory = (
                    contract.make_fixture_entry(
                        unknown, epoch=1, rank=0
                    ),
                )
                with self.assertRaises(contract.NoCompatibleDevice):
                    contract.select_device(
                        self.requirement, inventory
                    )

        no_single_claim = contract.seal_requirement(
            replace(
                self.requirement,
                requirement_sha256=contract.ZERO_DIGEST,
                largest_single_allocation_bytes=0,
                fallback_policy=contract.FALLBACK_FORBIDDEN,
            )
        )
        unknown_single = contract.seal_capability(
            replace(
                self.gpu_a,
                capability_sha256=contract.ZERO_DIGEST,
                max_single_allocation_bytes=0,
            )
        )
        selection = contract.select_device(
            no_single_claim,
            (
                contract.make_fixture_entry(
                    unknown_single, epoch=1, rank=0
                ),
            ),
        )
        self.assertEqual(
            unknown_single.capability_sha256,
            selection.receipt.selected_capability_sha256,
        )

    def test_unknown_bits_and_u64_overflow_reject(self) -> None:
        with self.assertRaises(contract.InvalidCapability):
            contract.seal_capability(
                replace(
                    self.gpu_a,
                    capability_sha256=contract.ZERO_DIGEST,
                    operation_profile_bits=(
                        self.gpu_a.operation_profile_bits | (1 << 63)
                    ),
                )
            )
        with self.assertRaises(contract.InvalidCapability):
            contract.seal_capability(
                replace(
                    self.gpu_a,
                    capability_sha256=contract.ZERO_DIGEST,
                    operator_bits=(
                        self.gpu_a.operator_bits | (1 << 63)
                    ),
                )
            )
        with self.assertRaises(contract.InvalidRequirement):
            contract.seal_requirement(
                replace(
                    self.requirement,
                    requirement_sha256=contract.ZERO_DIGEST,
                    required_feature_bits=1 << 63,
                )
            )
        with self.assertRaises(contract.InvalidRequirement):
            contract.seal_requirement(
                replace(
                    self.requirement,
                    requirement_sha256=contract.ZERO_DIGEST,
                    required_operation_profile_bits=(
                        contract.PROFILE_MATMUL_F16_BOUNDED
                    ),
                    required_operator_bits=contract.OPERATOR_MATMUL_F16,
                    required_element_type_bits=(
                        contract.ELEMENT_PACKED_INT4
                    ),
                    required_numerical_policy_bits=(
                        contract.NUMERICAL_BOUNDED_FLOAT16
                    ),
                )
            )
        with self.assertRaises(contract.InvalidCapability):
            contract.seal_capability(
                replace(
                    self.gpu_a,
                    capability_sha256=contract.ZERO_DIGEST,
                    max_total_device_bytes=contract.U64_MAX + 1,
                )
            )
        with self.assertRaises(contract.InvalidInventoryEntry):
            contract.seal_inventory_entry(
                replace(
                    self.entry_a,
                    entry_sha256=contract.ZERO_DIGEST,
                    discovery_epoch=contract.U64_MAX + 1,
                )
            )

    def test_capability_fingerprint_has_no_dynamic_allocation_sample(self) -> None:
        field_names = {field.name for field in fields(self.gpu_a)}
        self.assertNotIn("current_allocated_size", field_names)
        self.assertNotIn("available_device_bytes", field_names)

        drifted = replace(self.gpu_a, max_queue_slots=5)
        with self.assertRaises(contract.InvalidCapability):
            contract.validate_capability(drifted)

    def test_receipt_substitution_rejects_after_rehash(self) -> None:
        selection = contract.select_device(
            self.requirement, self.inventory
        )
        substituted = replace(
            selection.receipt,
            selected_discovery_epoch=(
                selection.receipt.selected_discovery_epoch + 1
            ),
            receipt_sha256=contract.ZERO_DIGEST,
        )
        substituted = replace(
            substituted,
            receipt_sha256=contract.selection_receipt_root(substituted),
        )
        with self.assertRaises(contract.InvalidSelectionReceipt):
            contract.validate_selection_receipt(
                substituted,
                self.requirement,
                self.inventory,
            )


if __name__ == "__main__":
    unittest.main()
