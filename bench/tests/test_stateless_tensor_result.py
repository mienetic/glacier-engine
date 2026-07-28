from __future__ import annotations

import hashlib
import json
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

from bench import stateless_tensor_result as oracle


IDS = (41, 7, 99, 5)
WEIGHTS = bytes((2, 0xFF, 3))
ROWS = (
    (5, 0, 0),
    (4, 0, 4),
    (5, 0, 0),
    (-1, 0, 0),
)


def _u64(value: int) -> bytes:
    return value.to_bytes(8, "little", signed=False)


def _i64(value: int) -> bytes:
    return value.to_bytes(8, "little", signed=True)


def _domain_root(domain: bytes, payload: bytes) -> bytes:
    return hashlib.sha256(domain + payload).digest()


def _batch_map(item_ids: tuple[int, ...] = IDS) -> bytes:
    length = (
        oracle.BATCH_MAP_HEADER_BYTES
        + len(item_ids) * oracle.BATCH_MAP_ITEM_BYTES
        + oracle.BATCH_MAP_FOOTER_BYTES
    )
    body = (
        oracle.BATCH_MAP_MAGIC
        + _u64(oracle.BATCH_MAP_ABI)
        + _u64(length)
        + _u64(len(item_ids))
        + b"".join(_u64(item_id) for item_id in item_ids)
    )
    return body + _domain_root(oracle.BATCH_MAP_DOMAIN, body)


def _score_policy() -> bytes:
    body = (
        oracle.SCORE_POLICY_MAGIC
        + _u64(oracle.SCORE_POLICY_ABI)
        + _u64(oracle.SCORE_POLICY_BYTES)
        + _u64(oracle.NORMALIZATION_NONE)
        + _u64(oracle.SCORE_DESCENDING)
        + _u64(oracle.INPUT_ORDINAL_ASCENDING)
        + _u64(0)
    )
    return body + _domain_root(oracle.SCORE_POLICY_DOMAIN, body)


def _ranked_result(
    items: tuple[oracle.RankedItemV1, ...],
    batch: bytes,
    policy: bytes,
) -> bytes:
    batch_root = batch[-32:]
    policy_root = policy[-32:]
    result = bytearray()
    for item in items:
        body = (
            _u64(item.item_id)
            + _u64(item.input_ordinal)
            + _u64(item.rank)
            + _i64(item.score)
        )
        root = hashlib.sha256(
            oracle.RANKED_ELEMENT_DOMAIN
            + batch_root
            + policy_root
            + body
        ).digest()
        result.extend(body)
        result.extend(root)
    return bytes(result)


def _tensor(rows: tuple[tuple[int, ...], ...] = ROWS) -> bytes:
    return b"".join(
        value.to_bytes(2, "little", signed=True)
        for row in rows
        for value in row
    )


def _fixture() -> tuple[bytes, bytes, bytes, tuple[oracle.RankedItemV1, ...]]:
    batch = _batch_map()
    policy = _score_policy()
    expected = (
        oracle.RankedItemV1(7, 1, 0, 20),
        oracle.RankedItemV1(41, 0, 1, 10),
        oracle.RankedItemV1(99, 2, 2, 10),
        oracle.RankedItemV1(5, 3, 3, -2),
    )
    return batch, policy, _ranked_result(expected, batch, policy), expected


def _demo_document() -> dict[str, object]:
    batch, policy, result, expected = _fixture()
    return {
        "schema": oracle.DEMO_SCHEMA,
        "batch_map_hex": batch.hex(),
        "score_policy_hex": policy.hex(),
        "ranked_result_hex": result.hex(),
        "weights_hex": WEIGHTS.hex(),
        "tensor_hex": _tensor().hex(),
        "input_features": 3,
        "source_mapping_sha256": hashlib.sha256(b"source-mapping").hexdigest(),
        "result_sha256": hashlib.sha256(b"result-envelope").hexdigest(),
        "output_sha256": hashlib.sha256(result).hexdigest(),
        "items": [item.document() for item in expected],
        "verified": True,
    }


class StatelessTensorResultOracleTests(unittest.TestCase):
    def test_retained_fixture_round_trip(self) -> None:
        batch, policy, result, expected = _fixture()

        batch_view = oracle.decode_batch_map(batch)
        self.assertEqual(IDS, batch_view.item_ids)
        self.assertEqual(batch[-32:], batch_view.batch_map_sha256)

        policy_view = oracle.decode_score_policy(policy)
        self.assertEqual(1, policy_view.normalization)
        self.assertEqual(1, policy_view.order)
        self.assertEqual(1, policy_view.tie_break)
        self.assertEqual(policy[-32:], policy_view.score_policy_sha256)

        result_view = oracle.decode_ranked_result(
            result,
            batch_view,
            policy_view,
        )
        self.assertEqual(expected, result_view.items)
        self.assertEqual(
            expected,
            oracle.reference_rerank(batch_view, WEIGHTS, _tensor(), 3),
        )

        verified = oracle.verify_demo_document(_demo_document())
        self.assertEqual(expected, verified.ranked_result.items)
        self.assertEqual(hashlib.sha256(result).digest(), verified.output_sha256)

    def test_every_single_byte_mutation_is_rejected(self) -> None:
        batch, policy, result, _ = _fixture()

        for index in range(len(batch)):
            with self.subTest(wire="batch", index=index):
                mutated = bytearray(batch)
                mutated[index] ^= 0x80
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_batch_map(bytes(mutated))

        for index in range(len(policy)):
            with self.subTest(wire="policy", index=index):
                mutated = bytearray(policy)
                mutated[index] ^= 0x80
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_score_policy(bytes(mutated))

        for index in range(len(result)):
            with self.subTest(wire="result", index=index):
                mutated = bytearray(result)
                mutated[index] ^= 0x80
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_ranked_result(bytes(mutated), batch, policy)

    def test_every_truncation_is_rejected(self) -> None:
        batch, policy, result, _ = _fixture()

        for end in range(len(batch)):
            with self.subTest(wire="batch", end=end):
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_batch_map(batch[:end])
        for end in range(len(policy)):
            with self.subTest(wire="policy", end=end):
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_score_policy(policy[:end])
        for end in range(len(result)):
            with self.subTest(wire="result", end=end):
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_ranked_result(result[:end], batch, policy)

    def test_coherently_resealed_duplicate_batch_id_is_rejected(self) -> None:
        forged = _batch_map((41, 41, 99, 5))
        with self.assertRaisesRegex(oracle.OracleError, "duplicate item ID"):
            oracle.decode_batch_map(forged)

    def test_coherently_resealed_duplicate_ordinal_is_rejected(self) -> None:
        batch, policy, _, expected = _fixture()
        forged_items = (
            expected[0],
            oracle.RankedItemV1(7, 1, 1, 10),
            expected[2],
            expected[3],
        )
        forged = _ranked_result(forged_items, batch, policy)
        with self.assertRaisesRegex(oracle.OracleError, "duplicate input ordinal"):
            oracle.decode_ranked_result(forged, batch, policy)

    def test_coherent_rank_reorder_is_rejected(self) -> None:
        batch, policy, _, expected = _fixture()
        forged = _ranked_result(
            (expected[1], expected[0], expected[2], expected[3]),
            batch,
            policy,
        )
        with self.assertRaisesRegex(oracle.OracleError, "rank"):
            oracle.decode_ranked_result(forged, batch, policy)

    def test_coherent_score_reorder_is_rejected(self) -> None:
        batch, policy, _, _ = _fixture()
        forged_items = (
            oracle.RankedItemV1(41, 0, 0, 10),
            oracle.RankedItemV1(7, 1, 1, 20),
            oracle.RankedItemV1(99, 2, 2, 10),
            oracle.RankedItemV1(5, 3, 3, -2),
        )
        forged = _ranked_result(forged_items, batch, policy)
        with self.assertRaisesRegex(oracle.OracleError, "not descending"):
            oracle.decode_ranked_result(forged, batch, policy)

    def test_coherent_tie_break_reversal_is_rejected(self) -> None:
        batch = _batch_map((11, 22, 33))
        policy = _score_policy()
        forged_items = (
            oracle.RankedItemV1(22, 1, 0, 6),
            oracle.RankedItemV1(11, 0, 1, 6),
            oracle.RankedItemV1(33, 2, 2, 1),
        )
        forged = _ranked_result(forged_items, batch, policy)
        with self.assertRaisesRegex(oracle.OracleError, "tie break"):
            oracle.decode_ranked_result(forged, batch, policy)

    def test_reference_rerank_rejects_shape_drift_and_non_integer_shape(
        self,
    ) -> None:
        batch = _batch_map()
        for weights, tensor, features in (
            (WEIGHTS[:-1], _tensor(), 3),
            (WEIGHTS, _tensor()[:-1], 3),
            (WEIGHTS, _tensor(), 0),
            (WEIGHTS, _tensor(), True),
        ):
            with self.subTest(
                weights=len(weights),
                tensor=len(tensor),
                features=features,
            ):
                with self.assertRaises(oracle.OracleError):
                    oracle.reference_rerank(batch, weights, tensor, features)

    def test_demo_rejects_batch_above_retained_profile_limit(self) -> None:
        item_ids = tuple(range(1, oracle.RERANKER_MAX_BATCH_ITEMS + 2))
        batch = _batch_map(item_ids)
        policy = _score_policy()
        weights = b"\x01"
        rows = tuple(
            (len(item_ids) - ordinal,)
            for ordinal in range(len(item_ids))
        )
        tensor = _tensor(rows)
        items = tuple(
            oracle.RankedItemV1(
                item_id=item_id,
                input_ordinal=ordinal,
                rank=ordinal,
                score=len(item_ids) - ordinal,
            )
            for ordinal, item_id in enumerate(item_ids)
        )
        result = _ranked_result(items, batch, policy)
        document = {
            "schema": oracle.DEMO_SCHEMA,
            "batch_map_hex": batch.hex(),
            "score_policy_hex": policy.hex(),
            "ranked_result_hex": result.hex(),
            "weights_hex": weights.hex(),
            "tensor_hex": tensor.hex(),
            "input_features": 1,
            "source_mapping_sha256": hashlib.sha256(
                b"source-mapping",
            ).hexdigest(),
            "result_sha256": hashlib.sha256(
                b"result-envelope",
            ).hexdigest(),
            "output_sha256": hashlib.sha256(result).hexdigest(),
            "items": [item.document() for item in items],
            "verified": True,
        }

        self.assertEqual(len(item_ids), oracle.decode_batch_map(batch).item_count)
        with self.assertRaisesRegex(
            oracle.OracleError,
            "exceeds retained reranker profile",
        ):
            oracle.verify_demo_document(document)

    def test_demo_subprocess_is_invoked_without_arguments(self) -> None:
        payload = (
            json.dumps(
                _demo_document(),
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            + b"\n"
        )
        completed = subprocess.CompletedProcess(
            args=["/tmp/reranker-demo"],
            returncode=0,
            stdout=payload,
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_tensor_result.subprocess.run",
            return_value=completed,
        ) as run:
            verified = oracle.run_demo("/tmp/reranker-demo")
        self.assertEqual(4, verified.batch_map.item_count)
        run.assert_called_once_with(
            ["/tmp/reranker-demo"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )

    def test_demo_protocol_rejects_transport_and_document_drift(self) -> None:
        canonical = _demo_document()
        canonical_line = json.dumps(
            canonical,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        cases: list[tuple[int, bytes, bytes]] = [
            (1, canonical_line + b"\n", b""),
            (0, canonical_line + b"\n", b"warning"),
            (0, canonical_line, b""),
            (0, canonical_line + b"\n\n", b""),
            (0, canonical_line + b"\r\n", b""),
            (0, b"\xff\n", b""),
            (0, b"{bad json}\n", b""),
        ]
        for returncode, stdout, stderr in cases:
            with self.subTest(
                returncode=returncode,
                stdout=stdout[-16:],
                stderr=stderr,
            ):
                completed = subprocess.CompletedProcess(
                    args=["/tmp/reranker-demo"],
                    returncode=returncode,
                    stdout=stdout,
                    stderr=stderr,
                )
                with mock.patch(
                    "bench.stateless_tensor_result.subprocess.run",
                    return_value=completed,
                ):
                    with self.assertRaises(oracle.OracleError):
                        oracle.run_demo("/tmp/reranker-demo")

    def test_demo_protocol_rejects_semantic_drift(self) -> None:
        documents: list[dict[str, object]] = []
        for field, value in (
            ("schema", "foreign"),
            ("verified", False),
            ("output_sha256", "00" * 32),
            ("source_mapping_sha256", "00" * 32),
            ("result_sha256", "00" * 32),
            ("input_features", True),
            ("extra", True),
        ):
            document = _demo_document()
            document[field] = value
            documents.append(document)

        uppercase_weights = _demo_document()
        uppercase_weights["weights_hex"] = cast(
            str,
            uppercase_weights["weights_hex"],
        ).upper()
        documents.append(uppercase_weights)

        short_tensor = _demo_document()
        short_tensor["tensor_hex"] = cast(str, short_tensor["tensor_hex"])[:-2]
        documents.append(short_tensor)

        changed_item = _demo_document()
        items = cast(list[dict[str, int]], changed_item["items"])
        items[0]["score"] = 999
        documents.append(changed_item)

        for index, document in enumerate(documents):
            with self.subTest(index=index):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_demo_document(document)

    def test_demo_protocol_rejects_duplicate_json_fields(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["/tmp/reranker-demo"],
            returncode=0,
            stdout=b'{"schema":"a","schema":"b"}\n',
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_tensor_result.subprocess.run",
            return_value=completed,
        ):
            with self.assertRaisesRegex(oracle.OracleError, "duplicate"):
                oracle.run_demo("/tmp/reranker-demo")

    def test_cli_accepts_a_real_temporary_demo_executable(self) -> None:
        payload = json.dumps(
            _demo_document(),
            sort_keys=True,
            separators=(",", ":"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "demo"
            script.write_text(
                "#!/bin/sh\n"
                "exec printf '%s\\n' "
                + repr(payload)
                + "\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            self.assertEqual(0, oracle.main(("--demo", str(script))))


if __name__ == "__main__":
    unittest.main()
