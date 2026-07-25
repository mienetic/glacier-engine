from __future__ import annotations

import copy
import hashlib
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from bench import typed_workload_conformance as oracle


PLAN_ROOT = "dea9aa88a3ea6c159989a769dbcf91659b9aa5d860d9c92155a12487dcd02347"
PLAN_WIRE_ROOT = "66b0dfffc5b7c5fa780aac0da111595e2752aacff13d6f9dc5f68141df9afbad"
OUTCOME_ROOT = "42065963e33f29d088d0ad87933147d65df7439bdc1740685ef16519a2acaa6f"
RESULT_ROOT = "b2fcb522dac425eee47a54697bc2c05d19f88d06cba4c5b0e06f569d3a97cdee"
TRACE_ROOT = "f65e74a653520e378a96f5f8a99c01ac3f02ac9fa1188943e3d4cc41a60f6ca4"
SUMMARY_ROOT = "9024ea81959bc53db7b789752169e9f6ab15668519311a3cc197557eac3caa72"
ITEM_SECTION_ROOT = "020b3af8abd9ef97e7d5871d17fb2e51f51d0ec1ce0e49d7e9256b2cf137703a"
EVIDENCE_SUMMARY_ROOT = (
    "a6174f75ae22ec3bec57ee184f69fb116a6bd57d8c16d487705bc64c78f23660"
)
EVIDENCE_ROOT = "fcfbacf21be1e549f2402c9bf0a1d7bf94b6252a4a46f6f5ca8f0f6f0d6fe1f2"
REPORT_ROOT = "603ec85abb6023abb7055c56ae778de5e30f6517ce00d75b1d7a8295f3a9444a"


def digest(value: str | bytes) -> bytes:
    if isinstance(value, str):
        value = value.encode("utf-8")
    return hashlib.sha256(value).digest()


def support_record(index: int) -> oracle.Record:
    return (
        {
            "family": 3,
            "operation": 3,
            "input_kind": 3,
            "output_kind": 2,
            "numerical_policy": 1,
            "max_batch_items": 64,
            "max_input_features": 65_536,
            "max_output_dimensions": 16_384,
            "allowed_capabilities": 0,
        }
        if index == 0
        else {
            "family": 4 if index == 1 else 6,
            "operation": 3,
            "input_kind": 4 if index == 1 else 5,
            "output_kind": 2,
            "numerical_policy": 1,
            "max_batch_items": 4_096,
            "max_input_features": 16_384 if index == 1 else 1_048_576,
            "max_output_dimensions": 16_384,
            "allowed_capabilities": 0,
        }
    )


def profile_claim(index: int) -> oracle.Record:
    return (
        oracle.claim(
            capsule_bytes=8,
            activation_bytes=8,
            partial_bytes=16,
            output_journal_bytes=16,
            queue_slots=1,
        )
        if index < 2
        else oracle.claim(
            capsule_bytes=4,
            activation_bytes=4,
            partial_bytes=16,
            output_journal_bytes=16,
            staging_bytes=4,
            queue_slots=1,
        )
    )


def make_profile(index: int) -> oracle.Record:
    support = support_record(index)
    adapter_abis = (
        0x4756454E00000001,
        0x4741574500000001,
        0x4754564500000001,
    )
    implementation_labels = (
        "glacier reference vision implementation v1",
        "glacier reference audio-window implementation v1",
        "glacier reference temporal-video implementation v1",
    )
    artifact_roots = (
        "834970076a3a58c3049e4daae7ff27ae9c133a430d9ec8fd915828d17c5ca36f",
        "646c6e43b173de2b115d773f4f83936344625c947383b70a6f407d3561cae7d4",
        "d7effeac9770e889f7e6d1f68e94ff0ce41b09a867eebc28ed4117a75675f3c8",
    )
    execution_plan_roots = (
        "9002aaae47c69f3b5963ad7571ddfeaeb100df4e344cac33e30e67adf65bf38d",
        "1e7987c3f9b86926c548ce810d3749a9da2c3520e2ba78fb49b6de6d4bbd30cf",
        "0005da45e66510150f3f00288c2b769e0ff73f03ade97fa8ca5e9a65da7e0553",
    )
    outputs = (
        (30, 6, 70, 6),
        (500, 500, 500, 1500),
        (5, 5, 17, 13),
    )
    output_bytes = b"".join(
        value.to_bytes(4, "little", signed=True) for value in outputs[index]
    )
    return oracle.seal_profile(
        {
            "index": index,
            "family": support["family"],
            "operation": support["operation"],
            "input_kind": support["input_kind"],
            "output_kind": support["output_kind"],
            "numerical_policy": support["numerical_policy"],
            "adapter_abi": adapter_abis[index],
            "lifecycle": oracle.LIFECYCLE_STATELESS,
            "execution_unit": oracle.EXECUTION_OPERATION,
            "cancellation_boundary": oracle.CANCELLATION_BETWEEN_UNITS,
            "publication_policy": oracle.PUBLICATION_FINAL_ONLY,
            "correctness_gate": oracle.CORRECTNESS_EXACT,
            "claim": profile_claim(index),
            "support_sha256": oracle.support_record_sha256(support),
            "artifact_sha256": bytes.fromhex(artifact_roots[index]),
            "execution_plan_sha256": bytes.fromhex(execution_plan_roots[index]),
            "adapter_implementation_sha256": digest(implementation_labels[index]),
            "correctness_sha256": digest(output_bytes),
            "profile_sha256": oracle.ZERO_DIGEST,
        }
    )


def make_item(
    ordinal: int,
    profile: oracle.Record,
    arrival: int,
    work: int,
    action_step: int,
    action: int,
) -> oracle.Record:
    input_roots = (
        "e7365d346e47dc802f909b3a84484767bbada232de7a6383fc193fc1eb566dee",
        "b65fce1e3bd5486b480cd700b7e8b586ebd6f0d14a65ab172af4d7a4c9e6cedd",
        "cbdf30f05789216a9a4c3e57d91eed914f8a970a90edc3ecf3fde6db17eeb1ed",
    )
    identity = ordinal + 1
    return oracle.seal_item(
        {
            "ordinal": ordinal,
            "profile_index": profile["index"],
            "profile_sha256": profile["profile_sha256"],
            "arrival_step": arrival,
            "weight": 1,
            "work_quanta": work,
            "deadline_tick": 0,
            "terminal_action_step": action_step,
            "terminal_action": action,
            "fairness_member": True,
            "tenant_key": 0x7100 + identity,
            "request_key": 0x7200 + identity,
            "request_generation": 1,
            "resource_owner_key": 0x7300 + identity,
            "claim": copy.deepcopy(profile["claim"]),
            "input_binding_sha256": bytes.fromhex(input_roots[profile["index"]]),
            "item_sha256": oracle.ZERO_DIGEST,
        }
    )


def reference_plan() -> oracle.Record:
    profiles = [make_profile(index) for index in range(3)]
    item_specs = (
        (0, 0, 0, 8, 1, oracle.ACTION_CANCEL),
        (1, 1, 0, 8, 2, oracle.ACTION_TIMEOUT),
        (2, 2, 0, 1, oracle.ABSENT, oracle.ACTION_NONE),
        (3, 2, 1, 1, oracle.ABSENT, oracle.ACTION_NONE),
        (4, 0, 2, 1, oracle.ABSENT, oracle.ACTION_NONE),
        (5, 1, 3, 1, oracle.ABSENT, oracle.ACTION_NONE),
    )
    items = [
        make_item(
            ordinal,
            profiles[profile_index],
            arrival,
            work,
            action_step,
            action,
        )
        for (
            ordinal,
            profile_index,
            arrival,
            work,
            action_step,
            action,
        ) in item_specs
    ]
    return oracle.validate_plan(
        {
            "seed": 0x4757504300000001,
            "capacity": 3,
            "max_driver_steps": 32,
            "max_service_quanta": 32,
            "fairness_start_tick": 0,
            "fairness_end_tick": 16,
            "bank_epoch": 0x47575043424B0001,
            "scheduler_epoch": 0x4757504353430001,
            "max_weight": 1,
            "max_projection_quanta": 64,
            "max_projection_operations": 256,
            "limits": oracle.limits(
                host_bytes=1024 * 1024,
                capsule_bytes=1024 * 1024,
                kv_bytes=1024 * 1024,
                activation_bytes=1024 * 1024,
                partial_bytes=1024 * 1024,
                logits_bytes=1024 * 1024,
                output_journal_bytes=1024 * 1024,
                staging_bytes=1024 * 1024,
                device_bytes=1024 * 1024,
                io_bytes=1024 * 1024,
                queue_slots=3,
            ),
            "challenge": digest("typed perception reference campaign v1"),
            "profiles": profiles,
            "items": items,
        }
    )


def reseal_invalid_wire(plan: oracle.Record) -> bytes:
    valid = oracle.encode_plan(reference_plan())
    output = bytearray(valid)
    offset = oracle.PLAN_HEADER_BYTES
    for profile in plan["profiles"]:
        encoded = oracle._encode_profile_record(profile)
        output[offset : offset + oracle.PROFILE_RECORD_BYTES] = encoded
        offset += oracle.PROFILE_RECORD_BYTES
    for item in plan["items"]:
        encoded = oracle._encode_item_record(item)
        output[offset : offset + oracle.ITEM_RECORD_BYTES] = encoded
        offset += oracle.ITEM_RECORD_BYTES
    output[288:320] = oracle.profile_section_sha256(plan["profiles"])
    output[320:352] = oracle.item_section_sha256(plan["items"])
    output[352:384] = oracle._plan_sha256_canonical(plan)
    output[-32:] = oracle._sha(oracle.PLAN_WIRE_DOMAIN, bytes(output[:-32]))
    return bytes(output)


class TypedWorkloadConformanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.plan = reference_plan()
        self.result = oracle.replay_plan(self.plan)

    def test_module_reference_fixture_matches_independent_reconstruction(
        self,
    ) -> None:
        self.assertEqual(oracle.reference_plan(), self.plan)

    def test_exact_plan_wire_and_semantic_parity_constants(self) -> None:
        wire = oracle.encode_plan(self.plan)
        self.assertEqual(oracle.PLAN_ABI, 0x4757545750000001)
        self.assertEqual(oracle.PROFILE_ABI, 0x4757545746000001)
        self.assertEqual(oracle.ITEM_ABI, 0x4757545749000001)
        self.assertEqual(oracle.PLAN_HEADER_BYTES, 384)
        self.assertEqual(oracle.PROFILE_RECORD_BYTES, 368)
        self.assertEqual(oracle.ITEM_RECORD_BYTES, 280)
        self.assertEqual(len(wire), 3200)
        self.assertEqual(oracle.decode_plan(wire), self.plan)
        self.assertEqual(oracle.plan_sha256(self.plan).hex(), PLAN_ROOT)
        self.assertEqual(hashlib.sha256(wire).hexdigest(), PLAN_WIRE_ROOT)

    def test_direct_replay_covers_every_terminal_path(self) -> None:
        outcomes = self.result["outcomes"]
        self.assertEqual(
            [outcome["kind"] for outcome in outcomes],
            [
                oracle.OUTCOME_CANCELLED,
                oracle.OUTCOME_TIMED_OUT,
                oracle.OUTCOME_COMPLETED,
                oracle.OUTCOME_REJECTED,
                oracle.OUTCOME_COMPLETED,
                oracle.OUTCOME_COMPLETED,
            ],
        )
        self.assertEqual(outcomes[3]["rejection_reason"], oracle.REJECTION_NO_SLOT)
        summary = self.result["summary"]
        self.assertEqual(summary["attempted"], 6)
        self.assertEqual(summary["admitted"], 5)
        self.assertEqual(summary["rejected"], 1)
        self.assertEqual(summary["completed"], 3)
        self.assertEqual(summary["cancelled"], 1)
        self.assertEqual(summary["timed_out"], 1)
        self.assertTrue(summary["zero_orphan_ownership"])
        self.assertEqual(
            oracle.validate_result_by_replay(self.plan, self.result),
            self.result,
        )
        self.assertEqual(self.result["result_sha256"].hex(), RESULT_ROOT)
        self.assertEqual(self.result["trace_sha256"].hex(), TRACE_ROOT)
        self.assertEqual(self.result["summary_sha256"].hex(), SUMMARY_ROOT)

    def test_every_plan_byte_mutation_and_truncation_rejects(self) -> None:
        wire = oracle.encode_plan(self.plan)
        for index in range(len(wire)):
            with self.subTest(kind="mutation", index=index):
                mutated = bytearray(wire)
                mutated[index] ^= 1
                with self.assertRaises(oracle.TypedWorkloadError):
                    oracle.decode_plan(bytes(mutated))
        for length in range(len(wire)):
            with self.subTest(kind="truncation", length=length):
                with self.assertRaises(oracle.TypedWorkloadError):
                    oracle.decode_plan(wire[:length])
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.decode_plan(wire + b"\x00")

    def test_fully_resealed_semantic_substitution_rejects(self) -> None:
        forged = copy.deepcopy(self.plan)
        forged["items"][0]["claim"] = copy.deepcopy(forged["profiles"][2]["claim"])
        forged["items"][0] = oracle.seal_item(forged["items"][0])
        wire = reseal_invalid_wire(forged)
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.decode_plan(wire)

        duplicate = copy.deepcopy(self.plan)
        duplicate["profiles"][1] = copy.deepcopy(duplicate["profiles"][0])
        wire = reseal_invalid_wire(duplicate)
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.decode_plan(wire)

    def test_resealed_result_contradictions_fail_closed(self) -> None:
        forged = copy.deepcopy(self.result)
        forged["summary"]["completed"] += 1
        forged["summary_sha256"] = oracle.summary_sha256(forged["summary"])
        forged["result_sha256"] = oracle.result_sha256(
            forged["plan_sha256"],
            forged["outcome_sha256"],
            forged["trace_sha256"],
            forged["summary_sha256"],
        )
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.validate_result_structure(self.plan, forged)

        substituted = copy.deepcopy(self.result)
        service_index = next(
            index
            for index, record in enumerate(substituted["trace"])
            if record["event_kind"] == oracle.EVENT_SERVICE
        )
        substituted["trace"][service_index]["item_ordinal"] = 5
        substituted["trace"][service_index]["record_sha256"] = (
            oracle.trace_record_sha256(substituted["trace"][service_index])
        )
        substituted["trace_sha256"] = oracle.trace_sha256(substituted["trace"])
        substituted["result_sha256"] = oracle.result_sha256(
            substituted["plan_sha256"],
            substituted["outcome_sha256"],
            substituted["trace_sha256"],
            substituted["summary_sha256"],
        )
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.validate_result_by_replay(self.plan, substituted)

    def test_support_hash_and_exact_bindings_cover_each_field(self) -> None:
        baseline = support_record(0)
        root = oracle.support_record_sha256(baseline)
        for name in oracle.SUPPORT_RECORD_FIELDS:
            with self.subTest(field=name):
                changed = copy.deepcopy(baseline)
                changed[name] += 1
                self.assertNotEqual(
                    oracle.support_record_sha256(changed),
                    root,
                )

        invalid = copy.deepcopy(self.plan)
        invalid["items"][0]["profile_sha256"] = invalid["profiles"][2]["profile_sha256"]
        invalid["items"][0] = oracle.seal_item(invalid["items"][0])
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.validate_plan(invalid)

    def test_nonzero_deadline_must_follow_arrival(self) -> None:
        invalid = copy.deepcopy(self.plan)
        invalid["items"][4]["deadline_tick"] = invalid["items"][4]["arrival_step"]
        invalid["items"][4] = oracle.seal_item(invalid["items"][4])
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.validate_plan(invalid)

    def test_canonical_json_roundtrip_and_fail_closed_parsing(self) -> None:
        plan_document = oracle.plan_document(self.plan)
        result_document = oracle.result_document(self.plan, self.result)
        for document in (plan_document, result_document):
            payload = oracle.encode_document(document)
            self.assertEqual(oracle.decode_document(payload), document)
            with self.assertRaises(oracle.TypedWorkloadError):
                oracle.decode_document(b" " + payload)
            with self.assertRaises(oracle.TypedWorkloadError):
                oracle.decode_document(payload.rstrip(b"\n"))

        duplicate = b'{"kind":"plan","kind":"plan"}\n'
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.canonical_json_loads(duplicate)
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.canonical_json_loads(b'{"value":NaN}\n')

    def test_atomic_file_write_and_input_preservation(self) -> None:
        original_plan = copy.deepcopy(self.plan)
        invalid_document = oracle.plan_document(self.plan)
        invalid_document["plan_wire_bytes"] += 1
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "fixture.json")
            path.write_bytes(b"retained")
            with self.assertRaises(oracle.TypedWorkloadError):
                oracle.write_document(path, invalid_document)
            self.assertEqual(path.read_bytes(), b"retained")

            valid_document = oracle.result_document(self.plan, self.result)
            oracle.write_document(path, valid_document)
            self.assertEqual(oracle.read_document(path), valid_document)
        self.assertEqual(self.plan, original_plan)

    def test_runner_and_concrete_evidence_hooks_are_authority_bounded(
        self,
    ) -> None:
        observed: list[tuple[oracle.Record, oracle.Record]] = []

        def observer(plan: oracle.Record, result: oracle.Record) -> None:
            observed.append((plan, result))
            plan["seed"] = 0
            result["summary"]["attempted"] = 0

        document = oracle.run_fixture(
            oracle.reference_plan,
            result_observer=observer,
        )
        self.assertEqual(document["plan"]["seed"], self.plan["seed"])
        self.assertEqual(document["result"]["summary"]["attempted"], 6)
        self.assertEqual(len(observed), 1)

        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.verify_fixture(document, concrete_evidence={"root": "x"})

        checked: list[object] = []

        def verifier(
            plan: oracle.Record,
            result: oracle.Record,
            evidence: object,
        ) -> None:
            self.assertEqual(plan, self.plan)
            self.assertEqual(result, self.result)
            checked.append(evidence)

        self.assertEqual(
            oracle.verify_fixture(
                document,
                concrete_evidence={"future": True},
                evidence_verifier=verifier,
            ),
            document,
        )
        self.assertEqual(checked, [{"future": True}])

    def test_retained_report_freezes_schema_roots_and_counters(self) -> None:
        report = oracle.build_report()
        self.assertEqual(
            tuple(report),
            (
                "schema",
                "plan_abi",
                "profile_abi",
                "item_abi",
                "driver_result_abi",
                "driver_outcome_abi",
                "driver_trace_abi",
                "driver_summary_abi",
                "evidence_abi",
                "item_evidence_abi",
                "evidence_summary_abi",
                "profile_count",
                "item_count",
                "trace_count",
                "plan_wire_bytes",
                "plan_wire_sha256",
                "plan_sha256",
                "outcome_sha256",
                "trace_sha256",
                "summary_sha256",
                "result_sha256",
                "item_section_sha256",
                "evidence_summary_sha256",
                "evidence_sha256",
                "outcomes",
                "driver_summary",
                "evidence_summary",
            ),
        )
        self.assertEqual(
            {
                name: report[name]
                for name in (
                    "plan_abi",
                    "profile_abi",
                    "item_abi",
                    "driver_result_abi",
                    "driver_outcome_abi",
                    "driver_trace_abi",
                    "driver_summary_abi",
                    "evidence_abi",
                    "item_evidence_abi",
                    "evidence_summary_abi",
                )
            },
            {
                "plan_abi": "4757545750000001",
                "profile_abi": "4757545746000001",
                "item_abi": "4757545749000001",
                "driver_result_abi": "4754574452000001",
                "driver_outcome_abi": "475457444f000001",
                "driver_trace_abi": "4754574454000001",
                "driver_summary_abi": "4754574453000001",
                "evidence_abi": "4754505745000001",
                "item_evidence_abi": "4754505749000001",
                "evidence_summary_abi": "4754505753000001",
            },
        )
        self.assertEqual(
            {
                name: report[name]
                for name in (
                    "profile_count",
                    "item_count",
                    "trace_count",
                    "plan_wire_bytes",
                )
            },
            {
                "profile_count": 3,
                "item_count": 6,
                "trace_count": 17,
                "plan_wire_bytes": 3200,
            },
        )
        self.assertEqual(report["plan_wire_sha256"], PLAN_WIRE_ROOT)
        self.assertEqual(report["plan_sha256"], PLAN_ROOT)
        self.assertEqual(report["outcome_sha256"], OUTCOME_ROOT)
        self.assertEqual(report["trace_sha256"], TRACE_ROOT)
        self.assertEqual(report["summary_sha256"], SUMMARY_ROOT)
        self.assertEqual(report["result_sha256"], RESULT_ROOT)
        self.assertEqual(report["item_section_sha256"], ITEM_SECTION_ROOT)
        self.assertEqual(
            report["evidence_summary_sha256"],
            EVIDENCE_SUMMARY_ROOT,
        )
        self.assertEqual(report["evidence_sha256"], EVIDENCE_ROOT)
        self.assertEqual(
            report["outcomes"],
            [
                "cancelled",
                "timed_out",
                "completed",
                "rejected",
                "completed",
                "completed",
            ],
        )
        self.assertEqual(
            report["driver_summary"],
            {
                "profile_count": 3,
                "item_count": 6,
                "attempted": 6,
                "admitted": 5,
                "rejected": 1,
                "completed": 3,
                "cancelled": 1,
                "timed_out": 1,
                "service_quanta": 5,
                "driver_steps": 5,
                "final_logical_tick": 5,
                "maximum_live_receipts": 3,
                "peak_host_bytes": 140,
                "peak": {
                    "capsule_bytes": 20,
                    "kv_bytes": 0,
                    "activation_bytes": 20,
                    "partial_bytes": 48,
                    "logits_bytes": 0,
                    "output_journal_bytes": 48,
                    "staging_bytes": 4,
                    "device_bytes": 0,
                    "io_bytes": 0,
                    "queue_slots": 3,
                },
                "maximum_wait_quanta": 3,
                "maximum_service_gap": 3,
                "fairness_cross_product_error": 1,
                "bind_callbacks": 5,
                "cancel_callbacks": 2,
                "service_callbacks": 5,
                "final_service_callbacks": 3,
                "retire_callbacks": 3,
                "final_active": 0,
                "final_finished": 0,
                "final_active_reservations": 0,
                "final_committed_receipts": 0,
                "successful_commits": 5,
                "releases": 5,
                "bank_cancellations": 0,
                "bank_rejected_capacity": 0,
                "bank_rejected_slots": 0,
                "zero_orphan_ownership": True,
            },
        )
        self.assertEqual(
            report["evidence_summary"],
            {
                "profile_count": 3,
                "item_count": 6,
                "admitted": 5,
                "rejected": 1,
                "completed": 3,
                "cancelled": 1,
                "timed_out": 1,
                "vision_completed": 1,
                "audio_window_completed": 1,
                "temporal_video_completed": 1,
                "publications": 3,
                "nonpublished_terminal_items": 3,
                "cache_restores": 5,
                "cache_closures": 5,
                "cache_successful_commits": 15,
                "cache_releases": 15,
                "cache_live_allocations": 0,
                "model_successful_commits": 5,
                "model_releases": 5,
                "model_final_active_reservations": 0,
                "model_final_committed_receipts": 0,
                "zero_model_ownership": True,
                "zero_cache_ownership": True,
                "zero_orphan_ownership": True,
            },
        )
        encoded = oracle.render_report(report).encode("ascii")
        self.assertEqual(len(encoded), 2763)
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), REPORT_ROOT)
        self.assertEqual(oracle._load_json_exact(encoded, "report"), report)
        self.assertEqual(oracle.validate_report(report), report)
        fixture = (
            Path(__file__).resolve().parents[1]
            / "results"
            / "typed-workload-conformance-v1.json"
        )
        self.assertEqual(fixture.read_bytes(), encoded)

    def test_report_mutations_and_noncanonical_json_fail_closed(self) -> None:
        report = oracle.build_report()
        encoded = oracle.render_report(report).encode("ascii")
        malformed = (
            encoded[:-1],
            encoded + b"\n",
            encoded.replace(b"{", b"{ ", 1),
            b'{"schema":"a","schema":"b"}\n',
            b'{"value":NaN}\n',
            b'{"value":1.0}\n',
            b"[]\n",
            b"\xff\n",
        )
        for index, value in enumerate(malformed):
            with self.subTest(kind="encoding", index=index):
                with self.assertRaises(oracle.TypedWorkloadError):
                    oracle._load_json_exact(value, "report")

        def mutate(value: object) -> object:
            if type(value) is bool:
                return not value
            if type(value) is int:
                return value + 1
            if isinstance(value, str):
                return value + "x"
            if isinstance(value, list):
                return [*value, "unexpected"]
            if isinstance(value, dict):
                changed = copy.deepcopy(value)
                first = next(iter(changed))
                changed[first] = mutate(changed[first])
                return changed
            raise AssertionError("unsupported report value")

        for name in report:
            with self.subTest(kind="top-level", field=name):
                changed = copy.deepcopy(report)
                changed[name] = mutate(changed[name])
                with self.assertRaises(oracle.TypedWorkloadError):
                    oracle.validate_report(changed)
        for summary_name in ("driver_summary", "evidence_summary"):
            for name in report[summary_name]:
                with self.subTest(kind=summary_name, field=name):
                    changed = copy.deepcopy(report)
                    changed[summary_name][name] = mutate(changed[summary_name][name])
                    with self.assertRaises(oracle.TypedWorkloadError):
                        oracle.validate_report(changed)
        for name in report["driver_summary"]["peak"]:
            with self.subTest(kind="peak", field=name):
                changed = copy.deepcopy(report)
                changed["driver_summary"]["peak"][name] += 1
                with self.assertRaises(oracle.TypedWorkloadError):
                    oracle.validate_report(changed)

        reordered = dict((*tuple(report.items())[1:], tuple(report.items())[0]))
        with self.assertRaises(oracle.TypedWorkloadError):
            oracle.validate_report(reordered)

        invalid = copy.deepcopy(report)
        invalid["result_sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "report.json")
            path.write_bytes(b"retained")
            with self.assertRaises(oracle.TypedWorkloadError):
                oracle.write_report(path, invalid)
            self.assertEqual(path.read_bytes(), b"retained")
            oracle.write_report(path)
            self.assertEqual(path.read_bytes(), encoded)

    def test_report_runner_and_cli_require_exact_output(self) -> None:
        expected = oracle.render_report().encode("ascii")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "fixture.json"
            runner = root / "runner.py"
            oracle.write_report(fixture)

            def install_runner(
                stdout: bytes,
                *,
                stderr: bytes = b"",
                returncode: int = 0,
            ) -> None:
                runner.write_text(
                    "#!/usr/bin/env python3\n"
                    "import sys\n"
                    f"sys.stdout.buffer.write({stdout!r})\n"
                    f"sys.stderr.buffer.write({stderr!r})\n"
                    f"raise SystemExit({returncode})\n",
                    encoding="ascii",
                )
                runner.chmod(0o755)

            install_runner(expected)
            oracle.verify_runner([sys.executable, str(runner)], fixture)
            self.assertEqual(
                oracle.main(
                    [
                        "--runner",
                        str(runner),
                        "--fixture",
                        str(fixture),
                    ]
                ),
                0,
            )

            substituted = oracle.build_report()
            substituted["result_sha256"] = "0" * 64
            install_runner(
                oracle.render_report(substituted).encode("ascii"),
            )
            with self.assertRaisesRegex(
                oracle.TypedWorkloadError,
                "contradicts Python oracle",
            ):
                oracle.verify_runner([sys.executable, str(runner)], fixture)

            install_runner(expected, stderr=b"unexpected")
            with self.assertRaisesRegex(
                oracle.TypedWorkloadError,
                "runner failed",
            ):
                oracle.verify_runner([sys.executable, str(runner)], fixture)

            fixture.write_bytes(b"{}\n")
            with self.assertRaisesRegex(
                oracle.TypedWorkloadError,
                "fixture is stale",
            ):
                oracle.verify_runner([sys.executable, str(runner)], fixture)
            with redirect_stderr(io.StringIO()):
                self.assertEqual(
                    oracle.main(
                        [
                            "--runner",
                            str(runner),
                            "--fixture",
                            str(fixture),
                        ]
                    ),
                    2,
                )
            with self.assertRaises(oracle.TypedWorkloadError):
                oracle.verify_runner([], fixture)


if __name__ == "__main__":
    unittest.main()
