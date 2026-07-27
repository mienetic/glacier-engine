from __future__ import annotations

from dataclasses import fields, replace
import unittest

from bench import device_capability_contract as device
from bench import device_lifecycle_contract as contract


def _flip(root: bytes) -> bytes:
    return bytes((root[0] ^ 1,)) + root[1:]


def _capability(
    name: str,
    *,
    device_loss_signal: bool = True,
) -> device.DeviceCapabilityV1:
    profile = device.PROFILE_MATVEC_INT4_F32_BOUNDED
    feature_bits = (
        device.FEATURE_ALLOCATION
        | device.FEATURE_DISPATCH
        | device.FEATURE_COMPLETION_FENCE
    )
    if device_loss_signal:
        feature_bits |= device.FEATURE_DEVICE_LOSS_SIGNAL
    return device.seal_capability(
        device.DeviceCapabilityV1(
            backend_kind=device.BACKEND_METAL,
            device_class=device.DEVICE_ACCELERATOR,
            operation_profile_bits=profile,
            operator_bits=device.profile_operator_bits(profile),
            element_type_bits=device.profile_element_type_bits(profile),
            numerical_policy_bits=(
                device.profile_numerical_policy_bits(profile)
            ),
            feature_bits=feature_bits,
            max_single_allocation_bytes=1 << 20,
            max_total_device_bytes=8 << 20,
            max_queue_slots=1,
            backend_sha256=device.digest_v1(
                "lifecycle golden backend"
            ),
            device_sha256=device.digest_v1(name),
            driver_sha256=device.digest_v1(
                "lifecycle golden driver"
            ),
            placement_sha256=device.digest_v1(
                "lifecycle golden placement"
            ),
        )
    )


def _entry(
    capability: device.DeviceCapabilityV1,
    *,
    epoch: int,
    rank: int,
    state: int = device.INVENTORY_PRESENT,
) -> device.DeviceInventoryEntryV1:
    return device.seal_inventory_entry(
        device.DeviceInventoryEntryV1(
            discovery_epoch=epoch,
            policy_rank=rank,
            state=state,
            capability=capability,
        )
    )


def _source_instance() -> bytes:
    return device.digest_v1("lifecycle test source instance")


def _cursor_before(
    source_sequence: int,
    source_instance_sha256: bytes | None = None,
) -> contract.SourceCursorV1:
    return contract.SourceCursorV1(
        source_instance_sha256=(
            _source_instance()
            if source_instance_sha256 is None
            else source_instance_sha256
        ),
        last_sequence=source_sequence - 1,
    )


def _cursor_at(
    source_sequence: int,
    source_instance_sha256: bytes | None = None,
) -> contract.SourceCursorV1:
    return contract.SourceCursorV1(
        source_instance_sha256=(
            _source_instance()
            if source_instance_sha256 is None
            else source_instance_sha256
        ),
        last_sequence=source_sequence,
    )


class DeviceLifecycleContractOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source_instance = _source_instance()
        self.capability = _capability("lifecycle golden gpu")
        self.prior = _entry(
            self.capability,
            epoch=41,
            rank=7,
        )
        self.inventory = (self.prior,)
        self.evidence = device.digest_v1(
            "lifecycle golden native command-buffer evidence"
        )
        self.observation = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            19,
            contract.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
            self.evidence,
            contract.COMMAND_BUFFER_STATUS_ERROR,
            contract.COMMAND_BUFFER_ERROR_DOMAIN,
            contract.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
        )
        self.successor = contract.make_successor_entry(
            self.observation,
            self.prior,
            self.inventory,
            _cursor_before(19),
            42,
        )
        self.receipt = contract.make_transition_receipt(
            self.observation,
            self.prior,
            self.inventory,
            self.successor,
            _cursor_before(19),
        )

    def test_literal_golden_roots_are_fixed_for_zig_fixture(self) -> None:
        self.assertEqual(0x4744_4C4F_0000_0001, contract.OBSERVATION_ABI)
        self.assertEqual(
            0x4744_4C54_0000_0001,
            contract.TRANSITION_RECEIPT_ABI,
        )
        self.assertEqual(40, contract.SOURCE_CURSOR_SIZE_BYTES)
        self.assertEqual(280, contract.OBSERVATION_SIZE_BYTES)
        self.assertEqual(272, contract.TRANSITION_RECEIPT_SIZE_BYTES)
        self.assertEqual(
            ("source_instance_sha256", "last_sequence"),
            tuple(
                field.name
                for field in fields(contract.SourceCursorV1)
            ),
        )
        self.assertIn(
            "source_instance_sha256",
            {
                field.name
                for field in fields(contract.ObservationV1)
            },
        )
        self.assertNotIn(
            "source_instance_sha256",
            {
                field.name
                for field in fields(contract.TransitionReceiptV1)
            },
        )
        self.assertEqual(
            b"glacier-device-lifecycle-observation-v1\x00",
            contract.OBSERVATION_DOMAIN,
        )
        self.assertEqual(
            b"glacier-device-lifecycle-transition-receipt-v1\x00",
            contract.TRANSITION_RECEIPT_DOMAIN,
        )
        actual = {
            "source_instance": self.source_instance.hex(),
            "observation": self.observation.observation_sha256.hex(),
            "transition": self.receipt.receipt_sha256.hex(),
        }
        expected = {
            "source_instance": (
                "52866097cde887ee870f95642bc47b34"
                "f4e7fe0e50bb4252638ccbe959639132"
            ),
            "observation": (
                "1c23285a0322059473e15b909ba82fbf"
                "3ffbfc03d4a206ad0f527170ccf98215"
            ),
            "transition": (
                "1636f05f5ae4953bb629a876bc92de4c"
                "fe2fc7d01219868e1819d7ebd04523ab"
            ),
        }
        self.assertEqual(expected, actual)
        self.assertEqual(
            self.observation.observation_sha256,
            contract.observation_root(self.observation),
        )
        self.assertEqual(
            self.receipt.receipt_sha256,
            contract.transition_receipt_root(self.receipt),
        )

    def test_source_semantics_are_exact_and_synthetic_is_distinct(
        self,
    ) -> None:
        cases = (
            (
                contract.SOURCE_INITIAL_MEMBERSHIP,
                contract.EVIDENCE_NATIVE,
                device.INVENTORY_PRESENT,
                (0, 0, 0),
            ),
            (
                contract.SOURCE_ADDED_NOTIFICATION,
                contract.EVIDENCE_NATIVE,
                device.INVENTORY_PRESENT,
                (0, 0, 0),
            ),
            (
                contract.SOURCE_INVENTORY_ABSENT,
                contract.EVIDENCE_NATIVE,
                device.INVENTORY_UNAVAILABLE,
                (0, 0, 0),
            ),
            (
                contract.SOURCE_REMOVAL_REQUESTED_NOTIFICATION,
                contract.EVIDENCE_NATIVE,
                device.INVENTORY_UNAVAILABLE,
                (0, 0, 0),
            ),
            (
                contract.SOURCE_REMOVED_NOTIFICATION,
                contract.EVIDENCE_NATIVE,
                device.INVENTORY_LOST,
                (0, 0, 0),
            ),
            (
                contract.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
                contract.EVIDENCE_NATIVE,
                device.INVENTORY_LOST,
                (
                    contract.COMMAND_BUFFER_STATUS_ERROR,
                    contract.COMMAND_BUFFER_ERROR_DOMAIN,
                    contract.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
                ),
            ),
            (
                contract.SOURCE_TEST_INJECTED,
                contract.EVIDENCE_SYNTHETIC,
                device.INVENTORY_LOST,
                (0, 0, 0),
            ),
        )
        for index, (
            source,
            evidence_class,
            state,
            native_fields,
        ) in enumerate(cases, 1):
            with self.subTest(source=source):
                if evidence_class == contract.EVIDENCE_SYNTHETIC:
                    evidence = device.digest_v1(
                        "explicit synthetic lifecycle injection plan"
                    )
                else:
                    evidence = device.digest_v1(
                        f"native lifecycle source evidence {source}"
                    )
                observation = contract.make_observation(
                    self.prior,
                    self.inventory,
                    self.source_instance,
                    index,
                    source,
                    evidence,
                    *native_fields,
                )
                self.assertEqual(
                    evidence_class,
                    observation.evidence_class,
                )
                self.assertEqual(state, observation.observed_state)
                contract.validate_observation(
                    observation,
                    self.prior,
                    self.inventory,
                    _cursor_before(index),
                )

        native_evidence = device.digest_v1(
            "native removed-notification evidence"
        )
        synthetic_evidence = device.digest_v1(
            "explicit synthetic test-injection plan"
        )
        native = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            30,
            contract.SOURCE_REMOVED_NOTIFICATION,
            native_evidence,
        )
        synthetic = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            30,
            contract.SOURCE_TEST_INJECTED,
            synthetic_evidence,
        )
        self.assertEqual(contract.EVIDENCE_NATIVE, native.evidence_class)
        self.assertEqual(
            contract.EVIDENCE_SYNTHETIC,
            synthetic.evidence_class,
        )
        self.assertEqual(0, synthetic.native_command_status)
        self.assertEqual(0, synthetic.native_error_domain_kind)
        self.assertEqual(0, synthetic.native_error_code_bits)
        self.assertNotEqual(
            native.evidence_sha256,
            synthetic.evidence_sha256,
        )
        self.assertNotEqual(
            native.observation_sha256,
            synthetic.observation_sha256,
        )

        native_successor = contract.make_successor_entry(
            native,
            self.prior,
            self.inventory,
            _cursor_before(30),
            43,
        )
        synthetic_successor = contract.make_successor_entry(
            synthetic,
            self.prior,
            self.inventory,
            _cursor_before(30),
            43,
        )
        native_receipt = contract.make_transition_receipt(
            native,
            self.prior,
            self.inventory,
            native_successor,
            _cursor_before(30),
        )
        synthetic_receipt = contract.make_transition_receipt(
            synthetic,
            self.prior,
            self.inventory,
            synthetic_successor,
            _cursor_before(30),
        )
        self.assertNotEqual(
            native_receipt.receipt_sha256,
            synthetic_receipt.receipt_sha256,
        )

    def test_command_buffer_removal_requires_exact_native_triple(
        self,
    ) -> None:
        wrong_fields = (
            (0, 0, 0),
            (
                4,
                contract.COMMAND_BUFFER_ERROR_DOMAIN,
                contract.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
            ),
            (
                contract.COMMAND_BUFFER_STATUS_ERROR,
                2,
                contract.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
            ),
            (
                contract.COMMAND_BUFFER_STATUS_ERROR,
                contract.COMMAND_BUFFER_ERROR_DOMAIN,
                1,
            ),
            (
                contract.COMMAND_BUFFER_STATUS_ERROR,
                contract.COMMAND_BUFFER_ERROR_DOMAIN,
                0,
            ),
        )
        for native_fields in wrong_fields:
            with self.subTest(native_fields=native_fields):
                with self.assertRaises(contract.InvalidObservation):
                    contract.make_observation(
                        self.prior,
                        self.inventory,
                        self.source_instance,
                        19,
                        contract.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
                        self.evidence,
                        *native_fields,
                    )

        exact = (
            contract.COMMAND_BUFFER_STATUS_ERROR,
            contract.COMMAND_BUFFER_ERROR_DOMAIN,
            contract.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
        )
        for source in (
            contract.SOURCE_INITIAL_MEMBERSHIP,
            contract.SOURCE_ADDED_NOTIFICATION,
            contract.SOURCE_INVENTORY_ABSENT,
            contract.SOURCE_REMOVAL_REQUESTED_NOTIFICATION,
            contract.SOURCE_REMOVED_NOTIFICATION,
            contract.SOURCE_TEST_INJECTED,
        ):
            with self.subTest(non_command_source=source):
                with self.assertRaises(contract.InvalidObservation):
                    contract.make_observation(
                        self.prior,
                        self.inventory,
                        self.source_instance,
                        19,
                        source,
                        self.evidence,
                        *exact,
                    )

    def test_device_loss_feature_prior_state_evidence_and_sequence_fence(
        self,
    ) -> None:
        no_signal = _capability(
            "lifecycle no-signal gpu",
            device_loss_signal=False,
        )
        no_signal_prior = _entry(no_signal, epoch=41, rank=7)
        with self.assertRaises(contract.InvalidObservation):
            contract.make_observation(
                no_signal_prior,
                (no_signal_prior,),
                self.source_instance,
                1,
                contract.SOURCE_INVENTORY_ABSENT,
                self.evidence,
            )

        lost_prior = _entry(
            self.capability,
            epoch=41,
            rank=7,
            state=device.INVENTORY_LOST,
        )
        with self.assertRaises(contract.InvalidObservation):
            contract.make_observation(
                lost_prior,
                (lost_prior,),
                self.source_instance,
                1,
                contract.SOURCE_REMOVED_NOTIFICATION,
                self.evidence,
            )
        with self.assertRaises(contract.InvalidObservation):
            contract.make_observation(
                self.prior,
                self.inventory,
                self.source_instance,
                1,
                contract.SOURCE_REMOVED_NOTIFICATION,
                contract.ZERO_DIGEST,
            )
        with self.assertRaises(contract.SourceInstanceChanged):
            contract.validate_observation(
                self.observation,
                self.prior,
                self.inventory,
                contract.SourceCursorV1(),
            )
        with self.assertRaises(contract.StaleObservation):
            contract.validate_observation(
                self.observation,
                self.prior,
                self.inventory,
                _cursor_at(19),
            )

        corrupt = replace(
            self.observation,
            observation_sha256=contract.ZERO_DIGEST,
        )
        with self.assertRaises(contract.StaleObservation):
            contract.validate_observation(
                corrupt,
                self.prior,
                self.inventory,
                _cursor_at(19),
            )

    def test_observation_rejects_every_field_mutation_and_substitution(
        self,
    ) -> None:
        replacements = {
            "abi_version": self.observation.abi_version + 1,
            "source": contract.SOURCE_REMOVED_NOTIFICATION,
            "evidence_class": contract.EVIDENCE_SYNTHETIC,
            "observed_state": device.INVENTORY_UNAVAILABLE,
            "source_sequence": 20,
            "native_command_status": 4,
            "native_error_domain_kind": 2,
            "native_error_code_bits": 10,
            "prior_discovery_epoch": 42,
            "prior_policy_rank": 8,
            "prior_inventory_count": 2,
            "source_instance_sha256": _flip(
                self.observation.source_instance_sha256
            ),
            "prior_inventory_sha256": _flip(
                self.observation.prior_inventory_sha256
            ),
            "prior_entry_sha256": _flip(
                self.observation.prior_entry_sha256
            ),
            "capability_sha256": _flip(
                self.observation.capability_sha256
            ),
            "evidence_sha256": _flip(
                self.observation.evidence_sha256
            ),
            "observation_sha256": _flip(
                self.observation.observation_sha256
            ),
        }
        self.assertEqual(
            {field.name for field in fields(contract.ObservationV1)},
            set(replacements),
        )
        for field_name, replacement in replacements.items():
            with self.subTest(field=field_name):
                mutated = replace(
                    self.observation,
                    **{field_name: replacement},
                )
                expected_error = (
                    contract.SourceInstanceChanged
                    if field_name == "source_instance_sha256"
                    else contract.InvalidObservation
                )
                with self.assertRaises(expected_error):
                    contract.validate_observation(
                        mutated,
                        self.prior,
                        self.inventory,
                        _cursor_before(19),
                    )

        notification = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            21,
            contract.SOURCE_REMOVAL_REQUESTED_NOTIFICATION,
            self.evidence,
        )
        invalid_rehashed = (
            replace(
                notification,
                evidence_class=contract.EVIDENCE_SYNTHETIC,
            ),
            replace(
                notification,
                observed_state=device.INVENTORY_LOST,
            ),
            replace(notification, source=99),
        )
        for mutation in invalid_rehashed:
            mutation = replace(
                mutation,
                observation_sha256=contract.observation_root(mutation),
            )
            with self.subTest(rehashed=mutation):
                with self.assertRaises(contract.InvalidObservation):
                    contract.validate_observation(
                        mutation,
                        self.prior,
                        self.inventory,
                        _cursor_before(21),
                    )

        sibling_capability = _capability("lifecycle sibling gpu")
        sibling = _entry(sibling_capability, epoch=44, rank=8)
        bound_inventory = (self.prior, sibling)
        bound = contract.make_observation(
            self.prior,
            bound_inventory,
            self.source_instance,
            22,
            contract.SOURCE_REMOVED_NOTIFICATION,
            self.evidence,
        )
        foreign_capability = _capability("lifecycle foreign gpu")
        foreign = _entry(foreign_capability, epoch=41, rank=7)
        with self.assertRaises(contract.InvalidObservation):
            contract.validate_observation(
                bound,
                self.prior,
                (self.prior, foreign),
                _cursor_before(22),
            )
        with self.assertRaises(contract.InvalidObservation):
            contract.validate_observation(
                bound,
                foreign,
                bound_inventory,
                _cursor_before(22),
            )

    def test_cursor_accepts_gaps_rejects_consumed_and_fences_instances(
        self,
    ) -> None:
        initial_cursor = contract.SourceCursorV1(
            source_instance_sha256=self.source_instance,
        )
        first = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            1,
            contract.SOURCE_INITIAL_MEMBERSHIP,
            device.digest_v1("cursor first native membership"),
        )
        contract.validate_observation(
            first,
            self.prior,
            self.inventory,
            initial_cursor,
        )
        after_first = contract.validate_and_advance_observation(
            first,
            self.prior,
            self.inventory,
            initial_cursor,
        )
        self.assertEqual(
            contract.SourceCursorV1(
                source_instance_sha256=self.source_instance,
                last_sequence=1,
            ),
            after_first,
        )
        with self.assertRaises(contract.StaleObservation):
            contract.validate_observation(
                first,
                self.prior,
                self.inventory,
                after_first,
            )

        after_gap = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            4,
            contract.SOURCE_ADDED_NOTIFICATION,
            device.digest_v1("cursor later native membership"),
        )
        advanced = contract.validate_and_advance_observation(
            after_gap,
            self.prior,
            self.inventory,
            after_first,
        )
        self.assertEqual(self.source_instance, advanced.source_instance_sha256)
        self.assertEqual(4, advanced.last_sequence)
        with self.assertRaises(contract.StaleObservation):
            contract.validate_observation(
                after_gap,
                self.prior,
                self.inventory,
                advanced,
            )

        replacement_instance = device.digest_v1(
            "replacement lifecycle source instance"
        )
        replacement = contract.make_observation(
            self.prior,
            self.inventory,
            replacement_instance,
            1,
            contract.SOURCE_INITIAL_MEMBERSHIP,
            device.digest_v1("replacement native membership"),
        )
        with self.assertRaises(contract.SourceInstanceChanged):
            contract.validate_observation(
                replacement,
                self.prior,
                self.inventory,
                advanced,
            )
        rebound_without_rehash = replace(
            self.observation,
            source_instance_sha256=replacement_instance,
        )
        with self.assertRaises(contract.InvalidObservation):
            contract.validate_observation(
                rebound_without_rehash,
                self.prior,
                self.inventory,
                _cursor_before(19, replacement_instance),
            )
        replacement_cursor = contract.SourceCursorV1(
            source_instance_sha256=replacement_instance,
        )
        replacement_advanced = (
            contract.validate_and_advance_observation(
                replacement,
                self.prior,
                self.inventory,
                replacement_cursor,
            )
        )
        self.assertEqual(
            replacement_instance,
            replacement_advanced.source_instance_sha256,
        )
        self.assertEqual(1, replacement_advanced.last_sequence)
        with self.assertRaises(contract.SourceInstanceChanged):
            contract.validate_observation(
                after_gap,
                self.prior,
                self.inventory,
                replacement_advanced,
            )

        with self.assertRaises(contract.StaleObservation):
            contract.validate_transition_receipt(
                self.receipt,
                self.observation,
                self.prior,
                self.inventory,
                self.successor,
                _cursor_at(19),
            )
        with self.assertRaises(contract.SourceInstanceChanged):
            contract.validate_transition_receipt(
                self.receipt,
                self.observation,
                self.prior,
                self.inventory,
                self.successor,
                contract.SourceCursorV1(
                    source_instance_sha256=replacement_instance,
                ),
            )

        replacement_same_event = contract.make_observation(
            self.prior,
            self.inventory,
            replacement_instance,
            19,
            contract.SOURCE_COMMAND_BUFFER_DEVICE_REMOVED,
            self.evidence,
            contract.COMMAND_BUFFER_STATUS_ERROR,
            contract.COMMAND_BUFFER_ERROR_DOMAIN,
            contract.COMMAND_BUFFER_DEVICE_REMOVED_ERROR,
        )
        with self.assertRaises(contract.InvalidTransitionReceipt):
            contract.validate_transition_receipt(
                self.receipt,
                replacement_same_event,
                self.prior,
                self.inventory,
                self.successor,
                _cursor_before(19, replacement_instance),
            )

    def test_successor_and_transition_constraints_are_exact(self) -> None:
        unavailable_observation = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            31,
            contract.SOURCE_INVENTORY_ABSENT,
            device.digest_v1("lifecycle absent inventory snapshot"),
        )
        unavailable = contract.make_successor_entry(
            unavailable_observation,
            self.prior,
            self.inventory,
            _cursor_before(31),
            50,
        )
        self.assertEqual(device.INVENTORY_UNAVAILABLE, unavailable.state)
        self.assertEqual(self.prior.policy_rank, unavailable.policy_rank)
        self.assertEqual(self.prior.capability, unavailable.capability)
        unavailable_receipt = contract.make_transition_receipt(
            unavailable_observation,
            self.prior,
            self.inventory,
            unavailable,
            _cursor_before(31),
        )
        contract.validate_transition_receipt(
            unavailable_receipt,
            unavailable_observation,
            self.prior,
            self.inventory,
            unavailable,
            _cursor_before(31),
        )

        present_observation = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            32,
            contract.SOURCE_INITIAL_MEMBERSHIP,
            device.digest_v1("lifecycle initial membership"),
        )
        with self.assertRaises(contract.InvalidTransitionReceipt):
            contract.make_successor_entry(
                present_observation,
                self.prior,
                self.inventory,
                _cursor_before(32),
                50,
            )
        for epoch in (40, 41):
            with self.subTest(successor_epoch=epoch):
                with self.assertRaises(
                    contract.InvalidTransitionReceipt
                ):
                    contract.make_successor_entry(
                        self.observation,
                        self.prior,
                        self.inventory,
                        _cursor_before(19),
                        epoch,
                    )

        foreign_capability = _capability("lifecycle transition foreign")
        invalid_successors = (
            _entry(
                self.capability,
                epoch=42,
                rank=7,
                state=device.INVENTORY_UNAVAILABLE,
            ),
            _entry(
                self.capability,
                epoch=42,
                rank=8,
                state=device.INVENTORY_LOST,
            ),
            _entry(
                foreign_capability,
                epoch=42,
                rank=7,
                state=device.INVENTORY_LOST,
            ),
        )
        for successor in invalid_successors:
            with self.subTest(successor=successor):
                with self.assertRaises(
                    contract.InvalidTransitionReceipt
                ):
                    contract.make_transition_receipt(
                        self.observation,
                        self.prior,
                        self.inventory,
                        successor,
                        _cursor_before(19),
                    )

    def test_transition_rejects_every_field_mutation_and_substitution(
        self,
    ) -> None:
        replacements = {
            "abi_version": self.receipt.abi_version + 1,
            "source": contract.SOURCE_TEST_INJECTED,
            "evidence_class": contract.EVIDENCE_SYNTHETIC,
            "prior_state": device.INVENTORY_LOST,
            "successor_state": device.INVENTORY_UNAVAILABLE,
            "source_sequence": 20,
            "prior_inventory_count": 2,
            "prior_discovery_epoch": 40,
            "successor_discovery_epoch": 43,
            "policy_rank": 8,
            "prior_inventory_sha256": _flip(
                self.receipt.prior_inventory_sha256
            ),
            "prior_entry_sha256": _flip(
                self.receipt.prior_entry_sha256
            ),
            "capability_sha256": _flip(
                self.receipt.capability_sha256
            ),
            "observation_sha256": _flip(
                self.receipt.observation_sha256
            ),
            "successor_entry_sha256": _flip(
                self.receipt.successor_entry_sha256
            ),
            "receipt_sha256": _flip(self.receipt.receipt_sha256),
        }
        self.assertEqual(
            {field.name for field in fields(contract.TransitionReceiptV1)},
            set(replacements),
        )
        for field_name, replacement in replacements.items():
            with self.subTest(field=field_name):
                mutated = replace(
                    self.receipt,
                    **{field_name: replacement},
                )
                with self.assertRaises(
                    contract.InvalidTransitionReceipt
                ):
                    contract.validate_transition_receipt(
                        mutated,
                        self.observation,
                        self.prior,
                        self.inventory,
                        self.successor,
                        _cursor_before(19),
                    )

        rehashed_source = replace(
            self.receipt,
            source=contract.SOURCE_TEST_INJECTED,
            evidence_class=contract.EVIDENCE_SYNTHETIC,
        )
        rehashed_source = replace(
            rehashed_source,
            receipt_sha256=contract.transition_receipt_root(
                rehashed_source
            ),
        )
        with self.assertRaises(contract.InvalidTransitionReceipt):
            contract.validate_transition_receipt(
                rehashed_source,
                self.observation,
                self.prior,
                self.inventory,
                self.successor,
                _cursor_before(19),
            )

        alternate_successor = _entry(
            self.capability,
            epoch=43,
            rank=7,
            state=device.INVENTORY_LOST,
        )
        with self.assertRaises(contract.InvalidTransitionReceipt):
            contract.validate_transition_receipt(
                self.receipt,
                self.observation,
                self.prior,
                self.inventory,
                alternate_successor,
                _cursor_before(19),
            )

        synthetic = contract.make_observation(
            self.prior,
            self.inventory,
            self.source_instance,
            19,
            contract.SOURCE_TEST_INJECTED,
            device.digest_v1("lifecycle synthetic substitution"),
        )
        with self.assertRaises(contract.InvalidTransitionReceipt):
            contract.validate_transition_receipt(
                self.receipt,
                synthetic,
                self.prior,
                self.inventory,
                self.successor,
                _cursor_before(19),
            )

        foreign_capability = _capability("lifecycle receipt foreign")
        foreign = _entry(foreign_capability, epoch=41, rank=7)
        with self.assertRaises(contract.InvalidObservation):
            contract.validate_transition_receipt(
                self.receipt,
                self.observation,
                self.prior,
                (foreign,),
                self.successor,
                _cursor_before(19),
            )
        with self.assertRaises(contract.StaleObservation):
            contract.validate_transition_receipt(
                self.receipt,
                self.observation,
                self.prior,
                self.inventory,
                self.successor,
                _cursor_at(19),
            )


if __name__ == "__main__":
    unittest.main()
