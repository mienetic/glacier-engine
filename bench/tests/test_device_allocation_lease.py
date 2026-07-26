from __future__ import annotations

from dataclasses import replace
import unittest

from bench import device_allocation_lease as contract


class DeviceAllocationLeaseOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = contract.make_fixture()

    def _campaign(self):
        fixture = self.fixture
        backend = contract.ReferenceFakeBackend(fixture.authority)
        coordinator = contract.ReferenceCoordinator(
            51,
            fixture.authority,
            fixture.request,
            fixture.selection,
            fixture.parent,
            fixture.manifest,
            fixture.entries,
            backend,
        )

        admission_1 = coordinator.admit()
        child_1 = coordinator._live.child
        terminal_cancel_1 = coordinator.cancel(admission_1)

        admission_2 = coordinator.admit()
        child_2 = coordinator._live.child
        lease_2 = coordinator.materialize(admission_2)
        calls_2 = coordinator.current_calls()
        objects_2 = coordinator.current_objects()

        backend.fail_next_free_for(fixture.entries[1].binding_sha256)
        terminal, recovery_1 = coordinator.release(lease_2)
        self.assertIsNone(terminal)
        self.assertIsNotNone(recovery_1)
        assert recovery_1 is not None
        terminal_release_2, recovery_2 = coordinator.retry_recovery(
            recovery_1
        )
        self.assertIsNone(recovery_2)
        self.assertIsNotNone(terminal_release_2)
        assert terminal_release_2 is not None
        return {
            "backend": backend,
            "coordinator": coordinator,
            "admission_1": admission_1,
            "child_1": child_1,
            "terminal_cancel_1": terminal_cancel_1,
            "admission_2": admission_2,
            "child_2": child_2,
            "lease_2": lease_2,
            "calls_2": calls_2,
            "objects_2": objects_2,
            "recovery_1": recovery_1,
            "terminal_release_2": terminal_release_2,
        }

    def test_literal_golden_roots_cover_complete_composition(self) -> None:
        fixture = self.fixture
        campaign = self._campaign()
        objects = campaign["objects_2"]
        actual = {
            "selection": fixture.selection.receipt_sha256.hex(),
            "authority": fixture.authority.authority_sha256.hex(),
            "quote_0": fixture.entries[0].quote_sha256.hex(),
            "quote_1": fixture.entries[1].quote_sha256.hex(),
            "quote_2": fixture.entries[2].quote_sha256.hex(),
            "manifest": fixture.manifest.manifest_sha256.hex(),
            "parent": contract.resource_receipt_root(
                fixture.parent
            ).hex(),
            "request": fixture.request.request_sha256.hex(),
            "child_1": contract.resource_child_root(
                campaign["child_1"]
            ).hex(),
            "admission_1": campaign[
                "admission_1"
            ].admission_sha256.hex(),
            "terminal_cancel_1": campaign[
                "terminal_cancel_1"
            ].terminal_sha256.hex(),
            "child_2": contract.resource_child_root(
                campaign["child_2"]
            ).hex(),
            "admission_2": campaign[
                "admission_2"
            ].admission_sha256.hex(),
            "call_0": objects[0].allocation_call_sha256.hex(),
            "call_1": objects[1].allocation_call_sha256.hex(),
            "call_2": objects[2].allocation_call_sha256.hex(),
            "object_0": objects[0].object_sha256.hex(),
            "object_1": objects[1].object_sha256.hex(),
            "object_2": objects[2].object_sha256.hex(),
            "object_set_2": campaign[
                "lease_2"
            ].backend_object_set_sha256.hex(),
            "lease_2": campaign["lease_2"].lease_sha256.hex(),
            "outstanding_1": campaign[
                "recovery_1"
            ].outstanding_set_sha256.hex(),
            "recovery_1": campaign["recovery_1"].recovery_sha256.hex(),
            "terminal_release_2": campaign[
                "terminal_release_2"
            ].terminal_sha256.hex(),
        }
        expected = {
            "selection": (
                "561a5b05d02d933773147d26b3686b84"
                "5900ed8896a4254f27f3a3bfdeb19034"
            ),
            "authority": (
                "9cb59d992fd5e0ada234f70f8113c197"
                "8ca576988144a62c1ccf554c1622820c"
            ),
            "quote_0": (
                "f2b861b318c11f007fe94b8796a13eb9"
                "4bb49c001f670dfdf0c6eae14b45324f"
            ),
            "quote_1": (
                "9c4f99ce7d60ef3d53b40f30c8abca0"
                "791e2fc4a0be2f2053bdc67825372704f"
            ),
            "quote_2": (
                "30855f74cd6211672a90394e1080ae66"
                "57c7019df4248aa873c5a9139ea82aae"
            ),
            "manifest": (
                "3a9de9c57e4ad39c820e439965322bc8"
                "f0110d978bcb01c9e4fc1c1509215d8e"
            ),
            "parent": (
                "2bb3c84cccbab6fd65e803e2dd645b3b"
                "825e8f433562ed8767c29dd7f8dd73b0"
            ),
            "request": (
                "ade7fd932b2d2a3f827b0d3368735f38"
                "f65c207dcce035d637669a4a3d72f229"
            ),
            "child_1": (
                "61b24a34f6cd886c12e9fdda7bc2b986"
                "fe467b3493d58bdb2d4a79d123843691"
            ),
            "admission_1": (
                "9b1cc692024666a2235634bf5360e72e5"
                "c00d47703f36c284602369311dbfea9"
            ),
            "terminal_cancel_1": (
                "9cf1c97a579d687846d48f63207b71b3"
                "1ecd020d8f43e2d81d518adea9d7e912"
            ),
            "child_2": (
                "937fe7a990c712997ba4677ad086d5aa"
                "722d0a0fee9ec183a0810911e7539057"
            ),
            "admission_2": (
                "4e15ba09b470c1fefdf68d32544fc56c"
                "00c771a7a40c9dfb095f97d7aa659199"
            ),
            "call_0": (
                "1d04656e70f498a1c2e304716071687e"
                "97ef036c625196269b8ca2b2b21ed193"
            ),
            "call_1": (
                "aa760b751b316c2ae90cf171bffc281a"
                "80a8f644227be56648b3b71ac897b172"
            ),
            "call_2": (
                "56f72de627f18b795146df2af0b3ca42"
                "5901300d3fbb1f04dc72cfbd40ea152e"
            ),
            "object_0": (
                "e8ffbb4d54493a0411f26d7d523063aa"
                "ffe0342bb6bfda1be943a08fb1298cb9"
            ),
            "object_1": (
                "705a4e183e0e631065b8455f8f74ec25"
                "9f3c319b673fcf2efabee95a0fd28c0c"
            ),
            "object_2": (
                "abc474a8495b67b44ce2edd54dd36326"
                "1534b3e1f33c49269537e062ace3c07b"
            ),
            "object_set_2": (
                "29b38cab3cc7d7aa06959ce3e9f19612"
                "742bf22d3d292b22527b220f8d6b40b6"
            ),
            "lease_2": (
                "e42a511222aa3f91b853a810b5c5f21b"
                "b49ca8d3dcb0bf7a1a42792b1fd2c6b6"
            ),
            "outstanding_1": (
                "c7ba3cd55db25c4066520d1f99536f4c"
                "39bbc8e4d5e04308e495e2899d289601"
            ),
            "recovery_1": (
                "eb4ded83c6ab2327f083c54bbb079433"
                "74ffe245e4c77ccf88233b6b527c5bdb"
            ),
            "terminal_release_2": (
                "fa5fb28efc490c4be5f2060e58e21b6b"
                "77f0b574c33e6016ee046b48e19199d0"
            ),
        }
        self.assertEqual(expected, actual)

    def test_fixture_is_canonical_and_exactly_charged(self) -> None:
        entries = self.fixture.entries
        self.assertEqual(
            sorted(entry.binding_sha256 for entry in entries),
            [entry.binding_sha256 for entry in entries],
        )
        self.assertEqual(
            [(3000, 3072), (4000, 4096), (1000, 1024)],
            [
                (entry.requested_bytes, entry.charged_bytes)
                for entry in entries
            ],
        )
        self.assertEqual(8000, self.fixture.manifest.total_requested_bytes)
        self.assertEqual(8192, self.fixture.manifest.total_charged_bytes)
        self.assertEqual(4096, self.fixture.manifest.largest_charged_bytes)

    def test_quote_rejects_self_consistent_misaligned_charge(self) -> None:
        fixture = self.fixture
        draft = contract.AllocationQuoteV1(
            authority_sha256=fixture.authority.authority_sha256,
            binding_sha256=fixture.entries[2].binding_sha256,
            requested_bytes=1000,
            charged_bytes=1001,
        )
        misaligned = replace(
            draft,
            quote_sha256=contract.quote_root(draft),
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_quote(misaligned, fixture.authority)
        with self.assertRaises(contract.ContractError):
            contract.make_quote(
                fixture.authority,
                draft.binding_sha256,
                draft.requested_bytes,
                draft.charged_bytes,
            )

    def test_mutations_and_reorder_fail_closed(self) -> None:
        fixture = self.fixture
        changed_entry = replace(
            fixture.entries[0],
            requested_bytes=fixture.entries[0].requested_bytes + 1,
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_quote(
                contract.AllocationQuoteV1(
                    authority_sha256=fixture.authority.authority_sha256,
                    binding_sha256=changed_entry.binding_sha256,
                    requested_bytes=changed_entry.requested_bytes,
                    charged_bytes=changed_entry.charged_bytes,
                    quote_sha256=changed_entry.quote_sha256,
                ),
                fixture.authority,
            )
        with self.assertRaises(contract.ContractError):
            contract.validate_manifest(
                fixture.manifest,
                (changed_entry,) + fixture.entries[1:],
            )
        with self.assertRaises(contract.ContractError):
            contract.seal_manifest(tuple(reversed(fixture.entries)))
        with self.assertRaises(contract.ContractError):
            contract.validate_request(
                replace(
                    fixture.request,
                    total_device_bytes=fixture.request.total_device_bytes
                    - 1,
                ),
                fixture.authority,
                fixture.selection,
                fixture.parent,
                fixture.manifest,
                fixture.entries,
            )

    def test_u64_overflow_is_rejected_before_sealing(self) -> None:
        entries = (
            contract.AllocationEntryV1(
                binding_sha256=bytes([1]) * 32,
                requested_bytes=contract.U64_MAX,
                charged_bytes=contract.U64_MAX,
                quote_sha256=bytes([3]) * 32,
            ),
            contract.AllocationEntryV1(
                binding_sha256=bytes([2]) * 32,
                requested_bytes=1,
                charged_bytes=1,
                quote_sha256=bytes([4]) * 32,
            ),
        )
        with self.assertRaises(contract.ArithmeticOverflow):
            contract.seal_manifest(entries)
        with self.assertRaises(contract.ArithmeticOverflow):
            contract.align_forward(contract.U64_MAX, 1024)

    def test_resource_receipt_and_child_bind_every_field(self) -> None:
        fixture = self.fixture
        with self.assertRaises(contract.ContractError):
            contract.validate_resource_receipt(
                replace(
                    fixture.parent,
                    claim=replace(fixture.parent.claim, queue_slots=2),
                )
            )
        child = contract.open_resource_child(
            fixture.parent,
            contract.allocation_child_key(
                51, 0, 1, fixture.request.request_sha256
            ),
            1,
            contract.ClaimV1(device_bytes=8192),
            contract.ClaimV1(device_bytes=8192),
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_resource_child(
                replace(
                    child,
                    claim=contract.ClaimV1(device_bytes=4096),
                )
            )

    def test_foreign_authority_is_rejected_before_admission(self) -> None:
        fixture = self.fixture
        foreign = contract.seal_authority(
            replace(
                fixture.authority,
                backend_authority_sha256=contract.digest_v1(
                    b"foreign allocator"
                ),
                authority_sha256=contract.ZERO_DIGEST,
            )
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_request(
                fixture.request,
                foreign,
                fixture.selection,
                fixture.parent,
                fixture.manifest,
                fixture.entries,
            )
        with self.assertRaises(contract.ContractError):
            contract.validate_quote(
                contract.AllocationQuoteV1(
                    authority_sha256=fixture.authority.authority_sha256,
                    binding_sha256=fixture.entries[0].binding_sha256,
                    requested_bytes=fixture.entries[0].requested_bytes,
                    charged_bytes=fixture.entries[0].charged_bytes,
                    quote_sha256=fixture.entries[0].quote_sha256,
                ),
                foreign,
            )

    def test_self_consistent_multi_lease_authority_is_rejected(self) -> None:
        draft = replace(
            self.fixture.authority,
            maximum_leases=2,
            authority_sha256=contract.ZERO_DIGEST,
        )
        multi_lease = replace(
            draft,
            authority_sha256=contract.authority_root(draft),
        )
        self.assertEqual(
            multi_lease.authority_sha256,
            contract.authority_root(multi_lease),
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_authority(multi_lease)
        with self.assertRaises(contract.ContractError):
            contract.seal_authority(draft)

    def test_authority_cannot_exceed_selected_capability_ceilings(self) -> None:
        fixture = self.fixture
        mutations = (
            {"max_single_allocation_bytes": 8192},
            {"max_total_device_bytes": 16384},
            {"max_queue_slots": 2},
        )
        for mutation in mutations:
            authority = contract.seal_authority(
                replace(
                    fixture.authority,
                    **mutation,
                    authority_sha256=contract.ZERO_DIGEST,
                )
            )
            entries = []
            for entry in fixture.entries:
                quote = contract.make_fake_quote(
                    authority,
                    entry.binding_sha256,
                    entry.requested_bytes,
                )
                entries.append(
                    replace(
                        entry,
                        charged_bytes=quote.charged_bytes,
                        quote_sha256=quote.quote_sha256,
                    )
                )
            manifest = contract.seal_manifest(tuple(entries))
            with self.assertRaises(contract.ContractError):
                contract.make_request(
                    fixture.request.request_epoch,
                    fixture.request.owner_sha256,
                    authority,
                    fixture.selection,
                    fixture.parent,
                    manifest,
                    tuple(entries),
                )

    def test_object_order_and_downstream_mutations_are_detected(self) -> None:
        fixture = self.fixture
        backend = contract.ReferenceFakeBackend(fixture.authority)
        coordinator = contract.ReferenceCoordinator(
            51,
            fixture.authority,
            fixture.request,
            fixture.selection,
            fixture.parent,
            fixture.manifest,
            fixture.entries,
            backend,
        )
        admission = coordinator.admit()
        lease = coordinator.materialize(admission)
        calls = coordinator.current_calls()
        objects = coordinator.current_objects()
        object_set = contract.BackendObjectSetV1(
            admission_sha256=admission.admission_sha256,
            allocation_count=3,
            total_allocated_bytes=8192,
            object_set_sha256=lease.backend_object_set_sha256,
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_object_set(
                object_set,
                admission,
                calls,
                tuple(reversed(objects)),
            )
        with self.assertRaises(contract.ContractError):
            contract.validate_backend_object(
                replace(objects[0], allocated_bytes=objects[0].allocated_bytes + 1),
                contract.make_allocation_call(
                    fixture.authority,
                    admission,
                    0,
                    fixture.entries[0],
                ),
            )
        with self.assertRaises(contract.ContractError):
            contract.validate_lease(
                replace(lease, materialized_bytes=lease.materialized_bytes - 1)
            )
        terminal, recovery = coordinator.release(lease)
        self.assertIsNone(recovery)
        assert terminal is not None
        with self.assertRaises(contract.ContractError):
            contract.validate_terminal(
                replace(terminal, returned_device_bytes=4096)
            )

    def test_object_set_replays_call_ordinal_authority_and_admission(self) -> None:
        campaign = self._campaign()
        admission = campaign["admission_2"]
        calls = campaign["calls_2"]
        objects = campaign["objects_2"]

        def reseal_call(call, **changes):
            draft = replace(
                call,
                call_sha256=contract.ZERO_DIGEST,
                **changes,
            )
            return replace(
                draft,
                call_sha256=contract.allocation_call_root(draft),
            )

        def assert_rejected(mutated_call) -> None:
            mutated_calls = list(calls)
            mutated_objects = list(objects)
            mutated_calls[0] = mutated_call
            mutated_objects[0] = contract.make_backend_object(
                mutated_call,
                objects[0].backend_object_sha256,
                objects[0].backend_object_generation,
            )
            with self.assertRaises(contract.ContractError):
                contract.make_object_set(
                    admission,
                    mutated_calls,
                    mutated_objects,
                )
            candidate = contract.BackendObjectSetV1(
                admission_sha256=admission.admission_sha256,
                allocation_count=len(mutated_objects),
                total_allocated_bytes=sum(
                    item.allocated_bytes for item in mutated_objects
                ),
            )
            candidate = replace(
                candidate,
                object_set_sha256=contract.object_set_root(
                    candidate, mutated_objects
                ),
            )
            with self.assertRaises(contract.ContractError):
                contract.validate_object_set(
                    candidate,
                    admission,
                    mutated_calls,
                    mutated_objects,
                )

        assert_rejected(reseal_call(calls[0], ordinal=1))
        assert_rejected(
            reseal_call(
                calls[0],
                authority_sha256=contract.digest_v1(
                    b"foreign call authority"
                ),
            )
        )
        assert_rejected(
            reseal_call(
                calls[0],
                admission_sha256=contract.digest_v1(
                    b"foreign call admission"
                ),
            )
        )

    def test_cancel_generation_one_then_recover_release_generation_two(self) -> None:
        fixture = self.fixture
        backend = contract.ReferenceFakeBackend(fixture.authority)
        coordinator = contract.ReferenceCoordinator(
            51,
            fixture.authority,
            fixture.request,
            fixture.selection,
            fixture.parent,
            fixture.manifest,
            fixture.entries,
            backend,
        )

        first = coordinator.admit()
        self.assertEqual(1, first.generation)
        self.assertEqual(8192, coordinator.charged_device_bytes)
        cancelled = coordinator.cancel(first)
        self.assertEqual(contract.OUTCOME_CANCELLED, cancelled.outcome)
        self.assertEqual(0, coordinator.charged_device_bytes)
        with self.assertRaises(contract.StaleHandle):
            coordinator.cancel(first)

        second = coordinator.admit()
        self.assertEqual(2, second.generation)
        lease = coordinator.materialize(second)
        objects = coordinator.current_objects()
        self.assertEqual(8192, backend.used_bytes)
        self.assertEqual(3, backend.live_objects)

        backend.fail_next_free_for(fixture.entries[1].binding_sha256)
        terminal, recovery = coordinator.release(lease)
        self.assertIsNone(terminal)
        self.assertIsNotNone(recovery)
        assert recovery is not None
        self.assertEqual(1, recovery.recovery_generation)
        self.assertEqual(1, recovery.outstanding_object_count)
        self.assertEqual(fixture.entries[1].charged_bytes, recovery.outstanding_bytes)
        self.assertEqual(8192, coordinator.charged_device_bytes)
        self.assertEqual(1, backend.live_objects)
        with self.assertRaises(contract.StaleHandle):
            coordinator.release(lease)

        released, retry = coordinator.retry_recovery(recovery)
        self.assertIsNone(retry)
        self.assertIsNotNone(released)
        assert released is not None
        self.assertEqual(contract.OUTCOME_RELEASED, released.outcome)
        self.assertEqual(0, coordinator.charged_device_bytes)
        self.assertEqual(0, backend.used_bytes)
        self.assertEqual(0, backend.live_objects)
        with self.assertRaises(contract.StaleHandle):
            coordinator.retry_recovery(recovery)
        with self.assertRaises(contract.StaleHandle):
            coordinator.release(lease)
        with self.assertRaises(contract.StaleHandle):
            backend.free(objects[0])

    def test_recovery_and_terminal_pair_mutations_fail_closed(self) -> None:
        campaign = self._campaign()
        recovery = campaign["recovery_1"]
        terminal = campaign["terminal_release_2"]
        with self.assertRaises(contract.ContractError):
            contract.validate_recovery(
                replace(
                    recovery,
                    target_reason=contract.REASON_EXPLICIT_CANCELLATION,
                )
            )
        oversized = replace(
            recovery,
            outstanding_object_count=contract.MAXIMUM_ALLOCATIONS + 1,
            recovery_sha256=contract.ZERO_DIGEST,
        )
        oversized = replace(
            oversized,
            recovery_sha256=contract.recovery_root(oversized),
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_recovery(oversized)
        with self.assertRaises(contract.ContractError):
            contract.validate_terminal(
                replace(
                    terminal,
                    outcome=contract.OUTCOME_CANCELLED,
                )
            )


if __name__ == "__main__":
    unittest.main()
