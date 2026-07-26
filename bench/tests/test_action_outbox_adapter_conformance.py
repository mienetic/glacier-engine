from __future__ import annotations

import copy
from concurrent.futures import ThreadPoolExecutor
import inspect
import unittest

from bench import action_outbox_adapter_conformance as adapter
from bench import action_outbox_conformance as outbox


def changed_digest(value: bytes) -> bytes:
    changed = bytearray(value)
    changed[0] ^= 1
    return bytes(changed)


class AdapterContractMirrorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = adapter.reference_fixture()
        cls.descriptor = cls.fixture["descriptor"]
        cls.dispatch_request = adapter.make_dispatch_request(
            cls.descriptor,
            cls.fixture["header"],
            cls.fixture["intent"],
        )
        cls.status_request = adapter.make_status_request(
            cls.descriptor,
            cls.fixture["header"],
            cls.fixture["state"],
            1,
        )

    def test_abis_field_order_and_roots_match_the_landed_contract(self) -> None:
        self.assertEqual(0x4754_4144_0000_0001, adapter.DESCRIPTOR_ABI)
        self.assertEqual(0x4754_4451_0000_0001, adapter.DISPATCH_REQUEST_ABI)
        self.assertEqual(0x4754_4445_0000_0001, adapter.DISPATCH_EVIDENCE_ABI)
        self.assertEqual(0x4754_5351_0000_0001, adapter.STATUS_REQUEST_ABI)
        self.assertEqual(0x4754_5345_0000_0001, adapter.STATUS_EVIDENCE_ABI)
        self.assertEqual(adapter.DESCRIPTOR_FIELDS, tuple(self.descriptor))
        self.assertEqual(
            adapter.DISPATCH_REQUEST_FIELDS,
            tuple(self.dispatch_request),
        )
        self.assertEqual(
            adapter.STATUS_REQUEST_FIELDS,
            tuple(self.status_request),
        )
        self.assertEqual(
            self.descriptor["descriptor_sha256"],
            adapter.descriptor_sha256(self.descriptor),
        )
        self.assertEqual(
            self.dispatch_request["request_sha256"],
            adapter.dispatch_request_sha256(self.dispatch_request),
        )
        self.assertEqual(
            self.status_request["request_sha256"],
            adapter.status_request_sha256(self.status_request),
        )

    def test_dispatch_dispositions_map_to_existing_record_kinds(self) -> None:
        expected = {
            adapter.DISPATCH_SUCCEEDED: outbox.EVENT_ACKNOWLEDGED_SUCCESS,
            adapter.DISPATCH_TERMINAL_FAILURE: (outbox.EVENT_ACKNOWLEDGED_FAILURE),
            adapter.DISPATCH_INDETERMINATE: outbox.EVENT_AMBIGUITY_OBSERVED,
            adapter.DISPATCH_REJECTED_STALE_GENERATION: (
                outbox.EVENT_AMBIGUITY_OBSERVED
            ),
        }
        for disposition, kind in expected.items():
            terminal = disposition in {
                adapter.DISPATCH_SUCCEEDED,
                adapter.DISPATCH_TERMINAL_FAILURE,
            }
            evidence = adapter.make_dispatch_evidence(
                self.descriptor,
                self.dispatch_request,
                1,
                disposition,
                adapter._label(f"dispatch event {disposition}"),  # noqa: SLF001
                (
                    adapter._label(f"dispatch result {disposition}")  # noqa: SLF001
                    if terminal
                    else adapter.ZERO_DIGEST
                ),
            )
            transition = adapter.transition_from_dispatch(
                self.descriptor,
                self.dispatch_request,
                evidence,
            )
            with self.subTest(disposition=disposition):
                self.assertEqual(adapter.TRANSITION_FIELDS, tuple(transition))
                self.assertEqual(kind, transition["kind"])
                self.assertEqual(
                    self.dispatch_request["attempt_generation"],
                    transition["attempt_generation"],
                )

    def test_status_dispositions_map_only_fenced_or_terminal_records(self) -> None:
        expected = {
            adapter.STATUS_PENDING: None,
            adapter.STATUS_UNKNOWN: None,
            adapter.STATUS_NOT_APPLIED_FENCED: (outbox.EVENT_RECONCILED_NOT_APPLIED),
            adapter.STATUS_SUCCEEDED: outbox.EVENT_RECONCILED_SUCCESS,
            adapter.STATUS_FAILED: outbox.EVENT_RECONCILED_FAILURE,
        }
        for disposition, kind in expected.items():
            terminal = disposition in {
                adapter.STATUS_SUCCEEDED,
                adapter.STATUS_FAILED,
            }
            evidence = adapter.make_status_evidence(
                self.descriptor,
                self.status_request,
                1,
                disposition,
                (
                    self.status_request["attempt_generation"]
                    if disposition == adapter.STATUS_NOT_APPLIED_FENCED
                    else 0
                ),
                adapter._label(f"status event {disposition}"),  # noqa: SLF001
                (
                    adapter._label(f"status result {disposition}")  # noqa: SLF001
                    if terminal
                    else adapter.ZERO_DIGEST
                ),
            )
            transition = adapter.transition_from_status(
                self.descriptor,
                self.status_request,
                evidence,
            )
            with self.subTest(disposition=disposition):
                if kind is None:
                    self.assertIsNone(transition)
                else:
                    self.assertIsNotNone(transition)
                    self.assertEqual(kind, transition["kind"])

    def test_semantic_reseals_do_not_bypass_composition_or_fence_rules(
        self,
    ) -> None:
        request = copy.deepcopy(self.dispatch_request)
        request["action_sha256"] = changed_digest(request["action_sha256"])
        request["request_sha256"] = adapter.dispatch_request_sha256(request)
        adapter.validate_dispatch_request(request)
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.validate_dispatch_request_composition(
                self.descriptor,
                self.fixture["header"],
                self.fixture["intent"],
                request,
            )

        valid_dispatch = adapter.make_dispatch_evidence(
            self.descriptor,
            self.dispatch_request,
            1,
            adapter.DISPATCH_SUCCEEDED,
            adapter._label("bound dispatch event"),  # noqa: SLF001
            adapter._label("bound dispatch result"),  # noqa: SLF001
        )
        foreign_dispatch = copy.deepcopy(self.dispatch_request)
        foreign_dispatch["adapter_descriptor_sha256"] = changed_digest(
            foreign_dispatch["adapter_descriptor_sha256"]
        )
        foreign_dispatch["request_sha256"] = adapter.dispatch_request_sha256(
            foreign_dispatch
        )
        rebound_dispatch = copy.deepcopy(valid_dispatch)
        rebound_dispatch["request_sha256"] = foreign_dispatch["request_sha256"]
        rebound_dispatch["evidence_sha256"] = adapter.dispatch_evidence_sha256(
            rebound_dispatch
        )
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.validate_dispatch_evidence(
                self.descriptor,
                foreign_dispatch,
                rebound_dispatch,
            )

        fenced = adapter.make_status_evidence(
            self.descriptor,
            self.status_request,
            1,
            adapter.STATUS_NOT_APPLIED_FENCED,
            self.status_request["attempt_generation"],
            adapter._label("fence"),  # noqa: SLF001
            adapter.ZERO_DIGEST,
        )
        forged = copy.deepcopy(fenced)
        forged["fence_through_generation"] += 1
        forged["evidence_sha256"] = adapter.status_evidence_sha256(forged)
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.transition_from_status(
                self.descriptor,
                self.status_request,
                forged,
            )
        foreign_status = copy.deepcopy(self.status_request)
        foreign_status["adapter_descriptor_sha256"] = changed_digest(
            foreign_status["adapter_descriptor_sha256"]
        )
        foreign_status["request_sha256"] = adapter.status_request_sha256(foreign_status)
        rebound_status = copy.deepcopy(fenced)
        rebound_status["request_sha256"] = foreign_status["request_sha256"]
        rebound_status["evidence_sha256"] = adapter.status_evidence_sha256(
            rebound_status
        )
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.validate_status_evidence(
                self.descriptor,
                foreign_status,
                rebound_status,
            )

    def test_descriptor_epoch_reseal_does_not_change_header_authority(self) -> None:
        foreign = copy.deepcopy(self.descriptor)
        foreign["authority_epoch"] += 1
        foreign["descriptor_sha256"] = adapter.descriptor_sha256(foreign)
        adapter.validate_descriptor(foreign)
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.validate_descriptor_header_binding(
                foreign,
                self.fixture["header"],
            )


class ReferenceReportTests(unittest.TestCase):
    def test_reference_report_is_deterministic_and_canonical(self) -> None:
        first = adapter.build_reference_report()
        second = adapter.build_reference_report()
        self.assertEqual(first, second)
        self.assertEqual(adapter.REFERENCE_REPORT_FIELDS, tuple(first))
        self.assertEqual(
            0x4754_4152_0000_0001,
            first["abi_version"],
        )
        self.assertEqual(
            first["report_sha256"],
            adapter.reference_report_sha256(first),
        )

        json_report = adapter.build_reference_json()
        self.assertEqual(adapter.REFERENCE_JSON_FIELDS, tuple(json_report))
        self.assertEqual(
            "glacier.action-outbox-adapter-reference/v1",
            json_report["schema"],
        )
        encoded = adapter.render_reference_json(json_report).encode("ascii")
        self.assertEqual(
            json_report,
            adapter.load_reference_json_exact(encoded, "test report"),
        )

    def test_reference_report_mutations_are_rejected(self) -> None:
        portable = adapter.build_reference_report()
        portable["action_sha256"] = changed_digest(portable["action_sha256"])
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.validate_reference_report(portable)

        json_report = adapter.build_reference_json()
        json_report["action_sha256"] = changed_digest(
            bytes.fromhex(json_report["action_sha256"])
        ).hex()
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.validate_reference_json(json_report)

    def test_reference_json_rejects_oversized_runner_output(self) -> None:
        encoded = b"x" * (adapter.MAXIMUM_RUNNER_STDOUT_BYTES + 1)
        with self.assertRaises(adapter.ActionOutboxAdapterError):
            adapter.load_reference_json_exact(encoded, "runner output")


class FakeAuthorityFenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = adapter.reference_fixture()
        cls.request = adapter.make_dispatch_request(
            cls.fixture["descriptor"],
            cls.fixture["header"],
            cls.fixture["intent"],
        )
        cls.status_request = adapter.make_status_request(
            cls.fixture["descriptor"],
            cls.fixture["header"],
            cls.fixture["state"],
            1,
        )

    def _runtime(self, credential: bytes = b"credential") -> adapter.RuntimeAdapter:
        authority = adapter.FakeAuthority(
            self.fixture["descriptor"],
            credential,
        )
        return adapter.RuntimeAdapter(
            self.fixture["descriptor"],
            authority,
            adapter.RuntimeCredential(credential),
        )

    def _status_request_for_generation(
        self,
        generation: int,
        query_ordinal: int,
        *,
        dispatch_request_sha256: bytes | None = None,
    ) -> adapter.Record:
        request = copy.deepcopy(self.status_request)
        request["attempt_generation"] = generation
        request["query_ordinal"] = query_ordinal
        if dispatch_request_sha256 is not None:
            request["dispatch_request_sha256"] = dispatch_request_sha256
        elif generation != self.status_request["attempt_generation"]:
            request["dispatch_request_sha256"] = adapter._label(  # noqa: SLF001
                f"status dispatch generation {generation}"
            )
        request["request_sha256"] = adapter.status_request_sha256(request)
        return adapter.validate_status_request(request)

    def _retry_request_after_fence(
        self,
        runtime: adapter.RuntimeAdapter,
    ) -> adapter.Record:
        fenced = adapter.status(runtime, self.status_request)
        self.assertEqual(
            adapter.STATUS_NOT_APPLIED_FENCED,
            fenced["disposition"],
        )
        transition = adapter.transition_from_status(
            self.fixture["descriptor"],
            self.status_request,
            fenced,
        )
        self.assertIsNotNone(transition)
        reconciliation = outbox.make_transition_record(
            self.fixture["header"],
            3,
            self.fixture["intent"]["record_sha256"],
            self.fixture["state"],
            transition["kind"],
            transition["attempt_generation"],
            transition["observation_sha256"],
            transition["result_sha256"],
        )
        states, ledger = outbox.apply_record(
            self.fixture["header"],
            reconciliation,
            self.fixture["states"],
            self.fixture["ledger"],
        )
        self.assertEqual(outbox.PHASE_READY, states[0]["phase"])
        retry_intent = outbox.make_transition_record(
            self.fixture["header"],
            4,
            reconciliation["record_sha256"],
            states[0],
            outbox.EVENT_DISPATCH_INTENT,
            2,
            adapter.ZERO_DIGEST,
            adapter.ZERO_DIGEST,
        )
        states, ledger = outbox.apply_record(
            self.fixture["header"],
            retry_intent,
            states,
            ledger,
        )
        self.assertEqual(outbox.PHASE_UNCERTAIN, states[0]["phase"])
        return adapter.make_dispatch_request(
            self.fixture["descriptor"],
            self.fixture["header"],
            retry_intent,
        )

    def test_atomic_fence_rejects_delayed_g_and_admits_exact_g_plus_one(
        self,
    ) -> None:
        runtime = self._runtime()
        retry = self._retry_request_after_fence(runtime)
        self.assertEqual(
            self.request["stable_remote_request_sha256"],
            retry["stable_remote_request_sha256"],
        )
        self.assertNotEqual(
            self.request["dispatch_request_sha256"],
            retry["dispatch_request_sha256"],
        )
        skipped = adapter.request_for_generation(retry, 3)
        with self.assertRaises(adapter.RequestRejected):
            adapter.dispatch(runtime, skipped)
        delayed = adapter.dispatch(runtime, self.request)
        self.assertEqual(
            adapter.DISPATCH_REJECTED_STALE_GENERATION,
            delayed["disposition"],
        )
        admitted = adapter.dispatch(runtime, retry)
        self.assertEqual(adapter.DISPATCH_SUCCEEDED, admitted["disposition"])
        late = adapter.dispatch(runtime, self.request)
        self.assertEqual(
            adapter.DISPATCH_REJECTED_STALE_GENERATION,
            late["disposition"],
        )
        self.assertEqual(
            1,
            runtime.authority.fence_for(self.request["stable_remote_request_sha256"]),
        )

    def test_indeterminate_dispatch_replays_exactly_and_remains_pending(
        self,
    ) -> None:
        runtime = self._runtime()
        runtime.authority.plan_dispatch(
            self.request["stable_remote_request_sha256"],
            adapter.DISPATCH_INDETERMINATE,
        )
        first = adapter.dispatch(runtime, self.request)
        duplicate = adapter.dispatch(runtime, self.request)
        self.assertEqual(first, duplicate)
        pending = adapter.status(runtime, self.status_request)
        self.assertEqual(adapter.STATUS_PENDING, pending["disposition"])
        self.assertIsNone(
            adapter.transition_from_status(
                self.fixture["descriptor"],
                self.status_request,
                pending,
            )
        )

    def test_status_dispatch_race_has_only_two_serialized_outcomes(self) -> None:
        allowed = {
            (
                adapter.DISPATCH_SUCCEEDED,
                adapter.STATUS_SUCCEEDED,
            ),
            (
                adapter.DISPATCH_REJECTED_STALE_GENERATION,
                adapter.STATUS_NOT_APPLIED_FENCED,
            ),
        }
        for _ in range(32):
            runtime = self._runtime()
            with ThreadPoolExecutor(max_workers=2) as executor:
                dispatch_future = executor.submit(
                    adapter.dispatch,
                    runtime,
                    self.request,
                )
                status_future = executor.submit(
                    adapter.status,
                    runtime,
                    self.status_request,
                )
                outcome = (
                    dispatch_future.result()["disposition"],
                    status_future.result()["disposition"],
                )
            self.assertIn(outcome, allowed)

    def test_foreign_stable_identity_conflicts_have_no_second_effect(
        self,
    ) -> None:
        runtime = self._runtime()
        first = adapter.dispatch(runtime, self.request)
        revision = runtime.authority.authority_revision

        same_action = copy.deepcopy(self.request)
        same_action["stable_remote_request_sha256"] = adapter._label(  # noqa: SLF001
            "foreign stable with same action"
        )
        same_action["idempotency_key_sha256"] = changed_digest(
            same_action["idempotency_key_sha256"]
        )
        same_action["request_sha256"] = adapter.dispatch_request_sha256(
            same_action
        )
        adapter.validate_dispatch_request(same_action)
        with self.assertRaises(adapter.RequestRejected):
            adapter.dispatch(runtime, same_action)

        same_idempotency = copy.deepcopy(self.request)
        same_idempotency["stable_remote_request_sha256"] = adapter._label(  # noqa: SLF001
            "foreign stable with same idempotency"
        )
        same_idempotency["action_sha256"] = changed_digest(
            same_idempotency["action_sha256"]
        )
        same_idempotency["request_sha256"] = adapter.dispatch_request_sha256(
            same_idempotency
        )
        adapter.validate_dispatch_request(same_idempotency)
        with self.assertRaises(adapter.RequestRejected):
            adapter.dispatch(runtime, same_idempotency)

        foreign_status = copy.deepcopy(self.status_request)
        foreign_status["stable_remote_request_sha256"] = adapter._label(  # noqa: SLF001
            "foreign overridden status"
        )
        foreign_status["request_sha256"] = adapter.status_request_sha256(
            foreign_status
        )
        adapter.validate_status_request(foreign_status)
        runtime.authority.override_status(
            foreign_status["stable_remote_request_sha256"],
            adapter.STATUS_UNKNOWN,
        )
        with self.assertRaises(adapter.RequestRejected):
            adapter.status(runtime, foreign_status)

        self.assertEqual(revision, runtime.authority.authority_revision)
        self.assertEqual(first, adapter.dispatch(runtime, self.request))

    def test_fake_control_maps_are_bounded(self) -> None:
        authority = adapter.FakeAuthority(
            self.fixture["descriptor"],
            b"credential",
            maximum_entries=1,
        )
        first = adapter._label("first bounded control")  # noqa: SLF001
        second = adapter._label("second bounded control")  # noqa: SLF001

        authority.plan_dispatch(first, adapter.DISPATCH_SUCCEEDED)
        authority.plan_dispatch(first, adapter.DISPATCH_TERMINAL_FAILURE)
        with self.assertRaises(adapter.CapacityExceeded):
            authority.plan_dispatch(second, adapter.DISPATCH_SUCCEEDED)

        authority.override_status(first, adapter.STATUS_UNKNOWN)
        authority.override_status(first, adapter.STATUS_PENDING)
        with self.assertRaises(adapter.CapacityExceeded):
            authority.override_status(second, adapter.STATUS_UNKNOWN)
        authority.override_status(first, None)
        authority.override_status(second, adapter.STATUS_UNKNOWN)

    def test_status_generation_rules_match_fenced_and_pending_entries(
        self,
    ) -> None:
        fenced_runtime = self._runtime()
        adapter.status(fenced_runtime, self.status_request)
        generation_two = self._status_request_for_generation(2, 2)
        adapter.status(fenced_runtime, generation_two)
        revision = fenced_runtime.authority.authority_revision
        older = self._status_request_for_generation(1, 3)
        older_evidence = adapter.status(fenced_runtime, older)
        self.assertEqual(
            adapter.STATUS_NOT_APPLIED_FENCED,
            older_evidence["disposition"],
        )
        self.assertEqual(1, older_evidence["fence_through_generation"])
        self.assertEqual(revision, fenced_runtime.authority.authority_revision)

        pending_runtime = self._runtime()
        retry = self._retry_request_after_fence(pending_runtime)
        pending_runtime.authority.plan_dispatch(
            retry["stable_remote_request_sha256"],
            adapter.DISPATCH_INDETERMINATE,
        )
        adapter.dispatch(pending_runtime, retry)
        stale = adapter.status(pending_runtime, self.status_request)
        self.assertEqual(
            adapter.STATUS_NOT_APPLIED_FENCED,
            stale["disposition"],
        )
        current = self._status_request_for_generation(
            2,
            2,
            dispatch_request_sha256=retry["dispatch_request_sha256"],
        )
        self.assertEqual(
            adapter.STATUS_PENDING,
            adapter.status(pending_runtime, current)["disposition"],
        )
        future = self._status_request_for_generation(3, 3)
        with self.assertRaises(adapter.RequestRejected):
            adapter.status(pending_runtime, future)

    def test_terminal_state_replays_by_stable_request(self) -> None:
        runtime = self._runtime()
        retry = self._retry_request_after_fence(runtime)
        first = adapter.dispatch(runtime, retry)
        later = adapter.request_for_generation(retry, 3)
        replay = adapter.dispatch(runtime, later)
        self.assertEqual(first["disposition"], replay["disposition"])
        self.assertEqual(first["authority_revision"], replay["authority_revision"])
        self.assertEqual(
            first["service_event_sha256"],
            replay["service_event_sha256"],
        )
        self.assertEqual(first["result_sha256"], replay["result_sha256"])
        self.assertNotEqual(first["evidence_sha256"], replay["evidence_sha256"])

        resealed = copy.deepcopy(retry)
        resealed["intent_record_sha256"] = changed_digest(
            resealed["intent_record_sha256"]
        )
        resealed["request_sha256"] = adapter.dispatch_request_sha256(resealed)
        adapter.validate_dispatch_request(resealed)
        with self.assertRaises(adapter.RequestRejected):
            adapter.dispatch(runtime, resealed)

        changed_payload = copy.deepcopy(later)
        changed_payload["payload_sha256"] = changed_digest(
            changed_payload["payload_sha256"]
        )
        changed_payload["request_sha256"] = adapter.dispatch_request_sha256(
            changed_payload
        )
        with self.assertRaises(adapter.RequestRejected):
            adapter.dispatch(runtime, changed_payload)

    def test_pending_and_unknown_never_create_retry_transition(self) -> None:
        pending_runtime = self._runtime()
        pending_runtime.authority.begin_inflight(
            self.request,
            pending_runtime.credential,
        )
        pending = adapter.status(pending_runtime, self.status_request)
        self.assertEqual(adapter.STATUS_PENDING, pending["disposition"])
        self.assertIsNone(
            adapter.transition_from_status(
                self.fixture["descriptor"],
                self.status_request,
                pending,
            )
        )
        self.assertEqual(
            0,
            pending_runtime.authority.fence_for(
                self.request["stable_remote_request_sha256"]
            ),
        )

        unknown_runtime = self._runtime()
        unknown_runtime.authority.override_status(
            self.request["stable_remote_request_sha256"],
            adapter.STATUS_UNKNOWN,
        )
        unknown = adapter.status(unknown_runtime, self.status_request)
        self.assertEqual(adapter.STATUS_UNKNOWN, unknown["disposition"])
        self.assertIsNone(
            adapter.transition_from_status(
                self.fixture["descriptor"],
                self.status_request,
                unknown,
            )
        )
        self.assertEqual(
            0,
            unknown_runtime.authority.fence_for(
                self.request["stable_remote_request_sha256"]
            ),
        )

    def test_dispatch_wins_status_returns_exact_terminal(self) -> None:
        runtime = self._runtime()
        dispatched = adapter.dispatch(runtime, self.request)
        status_evidence = adapter.status(runtime, self.status_request)
        self.assertEqual(adapter.STATUS_SUCCEEDED, status_evidence["disposition"])
        self.assertEqual(
            dispatched["service_event_sha256"],
            status_evidence["service_event_sha256"],
        )
        self.assertEqual(
            dispatched["result_sha256"],
            status_evidence["result_sha256"],
        )
        self.assertEqual(
            outbox.EVENT_RECONCILED_SUCCESS,
            adapter.transition_from_status(
                self.fixture["descriptor"],
                self.status_request,
                status_evidence,
            )["kind"],
        )


class CredentialIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = adapter.reference_fixture()
        cls.request = adapter.make_dispatch_request(
            cls.fixture["descriptor"],
            cls.fixture["header"],
            cls.fixture["intent"],
        )
        cls.status_request = adapter.make_status_request(
            cls.fixture["descriptor"],
            cls.fixture["header"],
            cls.fixture["state"],
            1,
        )

    def test_valid_credential_values_have_identical_portable_evidence(self) -> None:
        credentials = (
            b"a",
            b"seventeen-bytes!!!",
            bytes(range(32)),
            bytes(range(255)),
        )
        outputs = []
        for material in credentials:
            authority = adapter.FakeAuthority(
                self.fixture["descriptor"],
                material,
            )
            runtime = adapter.RuntimeAdapter(
                self.fixture["descriptor"],
                authority,
                adapter.RuntimeCredential(material),
            )
            outputs.append(adapter.status(runtime, self.status_request))
        self.assertTrue(all(value == outputs[0] for value in outputs[1:]))

    def test_invalid_credential_produces_no_fence_or_portable_evidence(self) -> None:
        authority = adapter.FakeAuthority(
            self.fixture["descriptor"],
            b"accepted",
        )
        runtime = adapter.RuntimeAdapter(
            self.fixture["descriptor"],
            authority,
            adapter.RuntimeCredential(b"rejected"),
        )
        before = authority.authority_revision
        with self.assertRaises(adapter.CredentialRejected):
            adapter.status(runtime, self.status_request)
        self.assertEqual(before, authority.authority_revision)
        self.assertEqual(
            0,
            authority.fence_for(self.request["stable_remote_request_sha256"]),
        )

    def test_portable_builder_api_and_fields_never_accept_credentials(self) -> None:
        builders = (
            adapter.make_descriptor,
            adapter.make_dispatch_request,
            adapter.make_dispatch_evidence,
            adapter.make_status_request,
            adapter.make_status_evidence,
            adapter.transition_from_dispatch,
            adapter.transition_from_status,
        )
        for builder in builders:
            with self.subTest(builder=builder.__name__):
                self.assertNotIn("credential", inspect.signature(builder).parameters)
        portable_fields = (
            adapter.DESCRIPTOR_FIELDS
            + adapter.DISPATCH_REQUEST_FIELDS
            + adapter.DISPATCH_EVIDENCE_FIELDS
            + adapter.STATUS_REQUEST_FIELDS
            + adapter.STATUS_EVIDENCE_FIELDS
            + adapter.TRANSITION_FIELDS
        )
        self.assertFalse(any("credential" in name for name in portable_fields))


if __name__ == "__main__":
    unittest.main()
