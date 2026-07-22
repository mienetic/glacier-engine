from __future__ import annotations

import copy
import hashlib
import json
import sys
import unittest
from dataclasses import replace
from typing import Any, Iterator

from bench import lane4_token_txn_event_evidence as evidence


FIXTURE_DOMAIN = b"glacier-lane4-token-txn-v4-test-fixture\x00"
REQUEST_EPOCH = 0x166C_0C70_0C7F_0081
GOLDEN_CANONICAL_JSONL_SHA256 = (
    "381240f783f43054f16c98c6cd70e1688e4ac5f23a0f0fbfe88cadabf84c3eaa"
)
GOLDEN_RAW_JSONL_SHA256 = (
    "7eca0573541e78d86cb6dd24e2724282e3cc27837a2f1da218b21e8ddf34597b"
)


def _fixture_digest(label: str, sequence: int) -> str:
    encoded = label.encode("ascii")
    digest = hashlib.sha256()
    digest.update(FIXTURE_DOMAIN)
    digest.update(len(encoded).to_bytes(8, "little"))
    digest.update(encoded)
    digest.update(sequence.to_bytes(8, "little"))
    return digest.hexdigest()


def _resource_receipt() -> dict[str, Any]:
    return {
        "bank_epoch": evidence.u64_hex(0x4234_4241_4E4B_0080),
        "slot_index": evidence.u32_hex(0),
        "generation": evidence.u64_hex(1),
        "owner_key": evidence.u64_hex(0xC7EC_8FBC_6EAA_ED23),
        "claim": {
            "capsule_bytes": evidence.u64_hex(0x101),
            "kv_bytes": evidence.u64_hex(0x202),
            "activation_bytes": evidence.u64_hex(0x303),
            "partial_bytes": evidence.u64_hex(0x404),
            "logits_bytes": evidence.u64_hex(0x505),
            "output_journal_bytes": evidence.u64_hex(0x606),
            "staging_bytes": evidence.u64_hex(0x707),
            "device_bytes": evidence.u64_hex(0x808),
            "io_bytes": evidence.u64_hex(0x909),
            "queue_slots": evidence.u64_hex(evidence.LANE_COUNT),
        },
        "integrity": evidence.u64_hex(0xE295_A727_52C3_77D5),
    }


def _fixture() -> tuple[dict[str, Any], list[dict[str, Any]], evidence.ReplayExpectation]:
    root_binding = _fixture_digest("root-binding", 0)
    resource_receipt = _resource_receipt()
    resource_digest = evidence.derive_resource_receipt_sha256(resource_receipt)
    previous = evidence.derive_initial_sha256(root_binding, REQUEST_EPOCH)
    outputs: list[list[int]] = [[] for _ in range(evidence.LANE_COUNT)]
    waves: list[dict[str, Any]] = []

    for sequence in range(evidence.TRANSACTION_COUNT):
        tokens = [1 + lane * 10_000 + sequence for lane in range(evidence.LANE_COUNT)]
        for lane, token in enumerate(tokens):
            outputs[lane].append(token)
        proposal_sha256 = _fixture_digest("proposal", sequence)
        ack = {
            "abi_version": evidence.u64_hex(evidence.TOKEN_TXN_PREPARE_ACK_ABI),
            "proposal_sha256": proposal_sha256,
            "sink_epoch": evidence.u64_hex(REQUEST_EPOCH ^ evidence.SINK_EPOCH_XOR),
            "reservation_id": evidence.u64_hex(sequence + 1),
        }
        commit_sha256 = evidence.derive_commit_sha256(proposal_sha256, ack)
        receipt = {
            "abi_version": evidence.u64_hex(evidence.TOKEN_TXN_COMMIT_RECEIPT_ABI),
            "proposal_abi": evidence.u64_hex(evidence.TOKEN_TXN_ABI),
            "sink_abi": evidence.u64_hex(evidence.TOKEN_TXN_SINK_ABI),
            "request_epoch": evidence.u64_hex(REQUEST_EPOCH),
            "transaction_sequence": evidence.u64_hex(sequence),
            "resource_permit_generation": evidence.u64_hex(sequence + 1),
            "live_mask": evidence.u8_hex(0x0F),
            "live_lane_count": evidence.u8_hex(evidence.LANE_COUNT),
            "kv_transition_mask": evidence.u8_hex(0 if sequence == 0 else 0x0F),
            "terminal_mask": evidence.u8_hex(
                0x0F if sequence == evidence.TRANSACTION_COUNT - 1 else 0
            ),
            "lane_step_indices": [
                evidence.u64_hex(sequence) for _ in range(evidence.LANE_COUNT)
            ],
            "token_ids": [evidence.u32_hex(token) for token in tokens],
            "resource_receipt_sha256": resource_digest,
            "proposal_sha256": proposal_sha256,
            "prepare_ack": ack,
            "commit_sha256": commit_sha256,
        }
        wave_sha256 = evidence.derive_wave_sha256(previous, receipt)
        waves.append(
            {
                "abi_version": evidence.u64_hex(evidence.B4_TOKEN_TXN_JOURNAL_ABI),
                "token_txn_abi": evidence.u64_hex(evidence.TOKEN_TXN_ABI),
                "token_txn_sink_abi": evidence.u64_hex(evidence.TOKEN_TXN_SINK_ABI),
                "previous_sha256": previous,
                "receipt": receipt,
                "wave_sha256": wave_sha256,
            }
        )
        previous = wave_sha256

    journal_receipt = {
        "abi_version": evidence.u64_hex(evidence.B4_TOKEN_TXN_JOURNAL_ABI),
        "token_txn_abi": evidence.u64_hex(evidence.TOKEN_TXN_ABI),
        "token_txn_sink_abi": evidence.u64_hex(evidence.TOKEN_TXN_SINK_ABI),
        "token_txn_prepare_ack_abi": evidence.u64_hex(
            evidence.TOKEN_TXN_PREPARE_ACK_ABI
        ),
        "token_txn_commit_receipt_abi": evidence.u64_hex(
            evidence.TOKEN_TXN_COMMIT_RECEIPT_ABI
        ),
        "resource_bank_abi": evidence.u64_hex(evidence.RESOURCE_BANK_ABI),
        "request_epoch": evidence.u64_hex(REQUEST_EPOCH),
        "expected_transaction_count": evidence.u32_hex(evidence.TRANSACTION_COUNT),
        "prepare_count": evidence.u32_hex(evidence.TRANSACTION_COUNT),
        "commit_count": evidence.u32_hex(evidence.TRANSACTION_COUNT),
        "abort_count": evidence.u32_hex(0),
        "lane_transition_count": evidence.u32_hex(evidence.LANE_TRANSITION_COUNT),
        "kv_transition_count": evidence.u32_hex(evidence.KV_TRANSITION_COUNT),
        "first_sequence": evidence.u64_hex(0),
        "last_sequence": evidence.u64_hex(evidence.TRANSACTION_COUNT - 1),
        "root_binding_sha256": root_binding,
        "resource_receipt": resource_receipt,
        "initial_sha256": evidence.derive_initial_sha256(root_binding, REQUEST_EPOCH),
        "head_sha256": previous,
        "commit_timestamps_available": False,
    }
    expectation = evidence.ReplayExpectation(
        root_binding_sha256=root_binding,
        request_epoch=REQUEST_EPOCH,
        resource_receipt_sha256=resource_digest,
        head_sha256=previous,
        lane_outputs=tuple(tuple(lane) for lane in outputs),
    )
    return journal_receipt, waves, expectation


def _records(data: bytes) -> list[dict[str, Any]]:
    return [json.loads(line.decode("ascii")) for line in data.splitlines()]


def _encode_records(records: list[dict[str, Any]]) -> bytes:
    return b"".join(evidence.canonical_ascii_json(record) + b"\n" for record in records)


def _raw_document(
    journal_receipt: dict[str, Any],
    waves: list[dict[str, Any]],
) -> bytes:
    records = [
        {
            "schema": evidence.RAW_EVENT_SCHEMA,
            "kind": "journal_receipt",
            "observation_abi": evidence.u64_hex(evidence.OBSERVATION_ABI),
            "decode_lane4_abi": evidence.u64_hex(evidence.DECODE_LANE4_ABI),
            "journal_receipt": journal_receipt,
        }
    ]
    records.extend(
        {
            "schema": evidence.RAW_EVENT_SCHEMA,
            "kind": "token_txn_wave",
            "record_sequence": evidence.u64_hex(sequence),
            "wave": wave,
        }
        for sequence, wave in enumerate(waves)
    )
    return _encode_records(records)


def _rebind_resource_receipt(
    journal_receipt: dict[str, Any],
    waves: list[dict[str, Any]],
) -> tuple[str, str]:
    resource_digest = evidence.derive_resource_receipt_sha256(
        journal_receipt["resource_receipt"]
    )
    previous = journal_receipt["initial_sha256"]
    for wave in waves:
        wave["previous_sha256"] = previous
        wave["receipt"]["resource_receipt_sha256"] = resource_digest
        wave["wave_sha256"] = evidence.derive_wave_sha256(previous, wave["receipt"])
        previous = wave["wave_sha256"]
    journal_receipt["head_sha256"] = previous
    return resource_digest, previous


def _leaf_paths(value: Any, prefix: tuple[Any, ...] = ()) -> Iterator[tuple[Any, ...]]:
    if isinstance(value, dict):
        for key, item in value.items():
            yield from _leaf_paths(item, prefix + (key,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _leaf_paths(item, prefix + (index,))
    else:
        yield prefix


def _mapping_paths(value: Any, prefix: tuple[Any, ...] = ()) -> Iterator[tuple[Any, ...]]:
    if isinstance(value, dict):
        yield prefix
        for key, item in value.items():
            yield from _mapping_paths(item, prefix + (key,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _mapping_paths(item, prefix + (index,))


def _at(value: Any, path: tuple[Any, ...]) -> Any:
    result = value
    for component in path:
        result = result[component]
    return result


def _mutate_leaf(value: Any) -> Any:
    if isinstance(value, bool):
        return not value
    if isinstance(value, str):
        replacement = "1" if value[0] != "1" else "2"
        return replacement + value[1:]
    raise AssertionError(f"unexpected fixture leaf {value!r}")


class TokenTxnEventEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        receipt, waves, expectation = _fixture()
        self.receipt = receipt
        self.waves = waves
        self.expectation = expectation
        self.data = evidence.encode_token_txn_evidence(receipt, waves)

    def assertRejected(self, data: bytes, expectation: evidence.ReplayExpectation | None = None) -> None:
        with self.assertRaises(evidence.TokenTxnEvidenceError):
            evidence.decode_token_txn_evidence(
                data,
                self.expectation if expectation is None else expectation,
            )

    def test_golden_fixture_and_replay(self) -> None:
        validated = evidence.decode_token_txn_evidence(self.data, self.expectation)
        self.assertEqual(len(validated.waves), evidence.TRANSACTION_COUNT)
        self.assertEqual(validated.lane_outputs, self.expectation.lane_outputs)
        self.assertFalse(validated.journal_receipt.commit_timestamps_available)
        self.assertEqual(hashlib.sha256(self.data).hexdigest(), GOLDEN_RAW_JSONL_SHA256)
        self.assertEqual(
            evidence.derive_canonical_jsonl_sha256(self.data),
            GOLDEN_CANONICAL_JSONL_SHA256,
        )

    def test_every_top_and_wave_leaf_mutation_fails_closed(self) -> None:
        baseline = _records(self.data)
        for record_index in (0, 1):
            for path in _leaf_paths(baseline[record_index]):
                with self.subTest(record=record_index, path=path):
                    mutated = copy.deepcopy(baseline)
                    parent = _at(mutated[record_index], path[:-1])
                    parent[path[-1]] = _mutate_leaf(parent[path[-1]])
                    self.assertRejected(_encode_records(mutated))

    def test_each_of_the_64_serialized_waves_is_chain_checked(self) -> None:
        baseline = _records(self.data)
        for sequence in range(evidence.TRANSACTION_COUNT):
            with self.subTest(sequence=sequence):
                mutated = copy.deepcopy(baseline)
                token_ids = mutated[sequence + 1]["wave"]["receipt"]["token_ids"]
                token_ids[0] = evidence.u32_hex(int(token_ids[0], 16) + 1)
                self.assertRejected(_encode_records(mutated))

    def test_missing_and_extra_keys_fail_at_every_object_level(self) -> None:
        baseline = _records(self.data)
        for record_index in (0, 1):
            for path in _mapping_paths(baseline[record_index]):
                mapping = _at(baseline[record_index], path)
                for key in tuple(mapping):
                    with self.subTest(operation="missing", record=record_index, path=path, key=key):
                        mutated = copy.deepcopy(baseline)
                        del _at(mutated[record_index], path)[key]
                        self.assertRejected(_encode_records(mutated))
                with self.subTest(operation="extra", record=record_index, path=path):
                    mutated = copy.deepcopy(baseline)
                    _at(mutated[record_index], path)["unexpected"] = "x"
                    self.assertRejected(_encode_records(mutated))

    def test_array_shape_and_output_divergence_fail(self) -> None:
        baseline = _records(self.data)
        for field in ("lane_step_indices", "token_ids"):
            for operation in ("drop", "append"):
                with self.subTest(field=field, operation=operation):
                    mutated = copy.deepcopy(baseline)
                    values = mutated[1]["wave"]["receipt"][field]
                    if operation == "drop":
                        values.pop()
                    else:
                        values.append(values[-1])
                    self.assertRejected(_encode_records(mutated))

        outputs = [list(lane) for lane in self.expectation.lane_outputs]
        outputs[2][17] += 1
        divergent = replace(
            self.expectation,
            lane_outputs=tuple(tuple(lane) for lane in outputs),
        )
        self.assertRejected(self.data, divergent)

    def test_external_head_pins_opaque_proposal_chain(self) -> None:
        waves = copy.deepcopy(self.waves)
        proposal = _fixture_digest("rewritten-proposal", 0)
        waves[0]["receipt"]["proposal_sha256"] = proposal
        waves[0]["receipt"]["prepare_ack"]["proposal_sha256"] = proposal
        waves[0]["receipt"]["commit_sha256"] = evidence.derive_commit_sha256(
            proposal,
            waves[0]["receipt"]["prepare_ack"],
        )
        previous = self.receipt["initial_sha256"]
        for wave in waves:
            wave["previous_sha256"] = previous
            wave["wave_sha256"] = evidence.derive_wave_sha256(previous, wave["receipt"])
            previous = wave["wave_sha256"]
        receipt = copy.deepcopy(self.receipt)
        receipt["head_sha256"] = previous
        internally_valid = evidence.encode_token_txn_evidence(receipt, waves)
        self.assertRejected(internally_valid)
        with self.assertRaises(evidence.TokenTxnEvidenceError):
            evidence.decode_token_txn_evidence(internally_valid, None)  # type: ignore[arg-type]

    def test_public_decode_requires_a_real_replay_expectation(self) -> None:
        for invalid in (None, object(), {"head_sha256": self.expectation.head_sha256}):
            with self.subTest(expectation=type(invalid).__name__):
                with self.assertRaisesRegex(
                    evidence.TokenTxnEvidenceError,
                    "trusted ReplayExpectation",
                ):
                    evidence.decode_token_txn_evidence(  # type: ignore[arg-type]
                        self.data,
                        invalid,
                    )

    def test_invalid_bank_receipts_fail_even_when_chain_is_rehashed(self) -> None:
        mutations = (
            ("bank_epoch", evidence.u64_hex(0)),
            ("slot_index", evidence.u32_hex(1)),
            ("generation", evidence.u64_hex(0)),
            ("owner_key", evidence.u64_hex(0)),
            ("integrity", evidence.u64_hex(0)),
            ("queue_slots", evidence.u64_hex(0)),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                receipt = copy.deepcopy(self.receipt)
                waves = copy.deepcopy(self.waves)
                resource = receipt["resource_receipt"]
                if field == "queue_slots":
                    resource["claim"][field] = value
                else:
                    resource[field] = value
                resource_digest, head = _rebind_resource_receipt(receipt, waves)
                expectation = replace(
                    self.expectation,
                    resource_receipt_sha256=resource_digest,
                    head_sha256=head,
                )
                self.assertRejected(_raw_document(receipt, waves), expectation)

    def test_queue_slots_do_not_satisfy_nonzero_byte_claim(self) -> None:
        receipt = copy.deepcopy(self.receipt)
        waves = copy.deepcopy(self.waves)
        claim = receipt["resource_receipt"]["claim"]
        self.assertEqual(len(evidence.RESOURCE_BYTE_CLAIM_FIELDS), 9)
        self.assertNotIn("queue_slots", evidence.RESOURCE_BYTE_CLAIM_FIELDS)
        for field in evidence.RESOURCE_BYTE_CLAIM_FIELDS:
            claim[field] = evidence.u64_hex(0)
        self.assertEqual(
            claim["queue_slots"],
            evidence.u64_hex(evidence.LANE_COUNT),
        )
        resource_digest, head = _rebind_resource_receipt(receipt, waves)
        expectation = replace(
            self.expectation,
            resource_receipt_sha256=resource_digest,
            head_sha256=head,
        )
        self.assertRejected(_raw_document(receipt, waves), expectation)

    def test_zero_external_digests_fail_before_replay(self) -> None:
        for field in ("resource_receipt_sha256", "head_sha256"):
            with self.subTest(field=field):
                expectation = replace(self.expectation, **{field: "0" * 64})
                self.assertRejected(self.data, expectation)

    def test_canonical_jsonl_and_exact_record_sequence_fail_closed(self) -> None:
        self.assertRejected(self.data[:-1])
        self.assertRejected(b" " + self.data)
        self.assertRejected(self.data + self.data.splitlines(keepends=True)[-1])

        records = _records(self.data)
        records[1], records[2] = records[2], records[1]
        self.assertRejected(_encode_records(records))

        records = _records(self.data)
        top = records[0]
        records[0] = {
            "kind": top["kind"],
            "schema": top["schema"],
            **{key: value for key, value in top.items() if key not in {"kind", "schema"}},
        }
        self.assertRejected(_encode_records(records))

    def test_total_stream_bound_is_checked_before_line_splitting(self) -> None:
        oversized = b"\n" * (evidence.MAX_EVIDENCE_BYTES + 1)
        with self.assertRaisesRegex(
            evidence.TokenTxnEvidenceError,
            "exceeds the .*byte maximum",
        ):
            evidence.decode_token_txn_evidence(oversized, self.expectation)

    def test_deep_json_nesting_is_normalized_at_parser_and_encoder(self) -> None:
        previous_limit = sys.getrecursionlimit()
        try:
            sys.setrecursionlimit(200)
            depth = 300
            nested_line = b"[" * depth + b'"x"' + b"]" * depth + b"\n"
            remaining = b"".join(self.data.splitlines(keepends=True)[1:])
            self.assertRejected(nested_line + remaining)

            nested_value: Any = "x"
            for _ in range(depth):
                nested_value = [nested_value]
            with self.assertRaises(evidence.TokenTxnEvidenceError):
                evidence.canonical_ascii_json(nested_value)
        finally:
            sys.setrecursionlimit(previous_limit)

    def test_duplicate_keys_numbers_null_and_timestamp_are_rejected(self) -> None:
        line, rest = self.data.split(b"\n", 1)
        duplicate = line.replace(
            b'{"schema":',
            b'{"schema":"duplicate","schema":',
            1,
        )
        self.assertRejected(duplicate + b"\n" + rest)

        records = _records(self.data)
        numeric_line = evidence.canonical_ascii_json(records[0]) + b"\n"
        quoted = b'"0000000000000000"'
        wave_line = evidence.canonical_ascii_json(records[1]).replace(quoted, b"0", 1) + b"\n"
        remaining = b"".join(
            evidence.canonical_ascii_json(record) + b"\n" for record in records[2:]
        )
        self.assertRejected(numeric_line + wave_line + remaining)

        records = _records(self.data)
        records[1]["wave"]["receipt"]["proposal_sha256"] = None
        noncanonical_null = b"".join(
            json.dumps(record, separators=(",", ":")).encode("ascii") + b"\n"
            for record in records
        )
        self.assertRejected(noncanonical_null)

        records = _records(self.data)
        receipt = records[0]["journal_receipt"]
        receipt["commit_monotonic_ns"] = evidence.u64_hex(1)
        self.assertRejected(_encode_records(records))

        records = _records(self.data)
        wave_receipt = records[1]["wave"]["receipt"]
        wave_receipt["commit_monotonic_ns"] = evidence.u64_hex(1)
        self.assertRejected(_encode_records(records))


if __name__ == "__main__":
    unittest.main()
