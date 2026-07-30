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
CLASSIFIER_IDS = (501, 502, 503)
CLASS_IDS = (11, 22, 33, 44)
CLASSIFIER_WEIGHTS = bytes(
    (
        1,
        2,
        0,
        0,
        0xFF,
        2,
        2,
        0,
        1,
        2,
        0,
        1,
    )
)
CLASSIFIER_ROWS = (
    (2, -1, 3),
    (2, 0, 0),
    (0, 5, -3),
)
CLASSIFIER_SCORES = (
    (0, 7, 7, 7),
    (2, 0, 4, 4),
    (10, -11, -3, -3),
)
CLASSIFIER_BATCH_HEX = (
    "475354424d4150310100004d4254534758000000000000000300000000000000"
    "f501000000000000f601000000000000f701000000000000"
    "967a68a4ab9d76d76f5385dbd36eddb31e303e13a2f4986482e73d339dd8565d"
)
CLASS_MAP_HEX = (
    "475354434d4150310100004d4354534760000000000000000400000000000000"
    "0b00000000000000160000000000000021000000000000002c00000000000000"
    "006b50dcbba78c2264881c73631f4f4760826fc620566e2c30751723ad5f4103"
)
CLASS_SCORE_POLICY_HEX = (
    "47535443504f4c31010000504354534760000000000000000100000000000000"
    "0100000000000000010000000000000001000000000000000000000000000000"
    "c8d7cea358e99df69660d1f2c332fd791c053451d6897b4ee62ab2610cbb3b28"
)
CLASS_SCORE_MATRIX_HEX = (
    "0000000000000000070000000000000007000000000000000700000000000000"
    "0200000000000000000000000000000004000000000000000400000000000000"
    "0a00000000000000f5fffffffffffffffdfffffffffffffffdffffffffffffff"
)
CLASS_SCORE_MATRIX_CONTEXT_SHA256 = (
    "d2bff5ce812db6152b9624570ebc6d96edab8c9539cfe61f11224d77f28c09e4"
)
CLASS_SCORE_MATRIX_RAW_SHA256 = (
    "1e12efb3b5965736e12c476dd9d4d5422b23b13b0cb79dd57badb585e993fd7d"
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


def _class_map(class_ids: tuple[int, ...] = CLASS_IDS) -> bytes:
    length = (
        oracle.CLASS_MAP_HEADER_BYTES
        + len(class_ids) * oracle.CLASS_MAP_ITEM_BYTES
        + oracle.CLASS_MAP_FOOTER_BYTES
    )
    body = (
        oracle.CLASS_MAP_MAGIC
        + _u64(oracle.CLASS_MAP_ABI)
        + _u64(length)
        + _u64(len(class_ids))
        + b"".join(_u64(class_id) for class_id in class_ids)
    )
    return body + _domain_root(oracle.CLASS_MAP_DOMAIN, body)


def _class_score_policy() -> bytes:
    body = (
        oracle.CLASS_SCORE_POLICY_MAGIC
        + _u64(oracle.CLASS_SCORE_POLICY_ABI)
        + _u64(oracle.CLASS_SCORE_POLICY_BYTES)
        + _u64(oracle.CLASS_SCORE_SIGNED_I64_LE)
        + _u64(oracle.NORMALIZATION_NONE)
        + _u64(oracle.SCORE_DESCENDING)
        + _u64(oracle.CLASS_ORDINAL_ASCENDING)
        + _u64(0)
    )
    return body + _domain_root(oracle.CLASS_SCORE_POLICY_DOMAIN, body)


def _class_score_matrix(
    scores: tuple[tuple[int, ...], ...] = CLASSIFIER_SCORES,
) -> bytes:
    return b"".join(_i64(score) for row in scores for score in row)


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
            oracle.RANKED_ELEMENT_DOMAIN + batch_root + policy_root + body
        ).digest()
        result.extend(body)
        result.extend(root)
    return bytes(result)


def _tensor(rows: tuple[tuple[int, ...], ...] = ROWS) -> bytes:
    return b"".join(
        value.to_bytes(2, "little", signed=True) for row in rows for value in row
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


def _classifier_fixture() -> tuple[bytes, bytes, bytes, bytes]:
    return (
        _batch_map(CLASSIFIER_IDS),
        _class_map(),
        _class_score_policy(),
        _class_score_matrix(),
    )


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


def _classifier_demo_document() -> dict[str, object]:
    batch, classes, policy, matrix = _classifier_fixture()
    matrix_view = oracle.decode_class_score_matrix(
        matrix,
        batch,
        classes,
        policy,
    )
    class_view = oracle.decode_class_map(classes)
    rows = []
    for item_index, scores in enumerate(CLASSIFIER_SCORES):
        rows.append(
            {
                "item_id": CLASSIFIER_IDS[item_index],
                "input_ordinal": item_index,
                "scores": list(scores),
                "winner": matrix_view.winner(
                    class_view,
                    item_index,
                ).document(),
            }
        )
    return {
        "schema": oracle.CLASSIFIER_DEMO_SCHEMA,
        "weights_hex": CLASSIFIER_WEIGHTS.hex(),
        "tensor_hex": _tensor(CLASSIFIER_ROWS).hex(),
        "input_features": 3,
        "batch_map_hex": batch.hex(),
        "class_map_hex": classes.hex(),
        "class_score_policy_hex": policy.hex(),
        "class_score_matrix_hex": matrix.hex(),
        "class_score_matrix_sha256": (matrix_view.class_score_matrix_sha256.hex()),
        "output_sha256": hashlib.sha256(matrix).hexdigest(),
        "source_mapping_sha256": hashlib.sha256(
            b"classifier-source-mapping",
        ).hexdigest(),
        "result_sha256": hashlib.sha256(
            b"classifier-result-envelope",
        ).hexdigest(),
        "rows": rows,
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
        rows = tuple((len(item_ids) - ordinal,) for ordinal in range(len(item_ids)))
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
        reranker_payload = json.dumps(
            _demo_document(),
            sort_keys=True,
            separators=(",", ":"),
        )
        classifier_payload = json.dumps(
            _classifier_demo_document(),
            sort_keys=True,
            separators=(",", ":"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "demo"
            script.write_text(
                "#!/bin/sh\n"
                'if [ "${1-}" = "classify" ]; then\n'
                "  exec printf '%s\\n' "
                + repr(classifier_payload)
                + "\nfi\n"
                + "exec printf '%s\\n' "
                + repr(reranker_payload)
                + "\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            self.assertEqual(0, oracle.main(("--demo", str(script))))


class DenseTensorClassifierOracleTests(unittest.TestCase):
    def test_reference_fixture_wires_roots_scores_and_tie_break(self) -> None:
        batch, classes, policy, matrix = _classifier_fixture()

        self.assertEqual(CLASSIFIER_BATCH_HEX, batch.hex())
        self.assertEqual(CLASS_MAP_HEX, classes.hex())
        self.assertEqual(CLASS_SCORE_POLICY_HEX, policy.hex())
        self.assertEqual(CLASS_SCORE_MATRIX_HEX, matrix.hex())
        batch_view = oracle.decode_batch_map(batch)
        class_view = oracle.decode_class_map(classes)
        policy_view = oracle.decode_class_score_policy(policy)
        matrix_view = oracle.decode_class_score_matrix(
            matrix,
            batch_view,
            class_view,
            policy_view,
        )

        self.assertEqual(CLASSIFIER_IDS, batch_view.item_ids)
        self.assertEqual(CLASS_IDS, class_view.class_ids)
        self.assertEqual(CLASSIFIER_SCORES, matrix_view.scores)
        self.assertEqual(
            CLASSIFIER_SCORES,
            oracle.reference_classify(
                batch_view,
                class_view,
                CLASSIFIER_WEIGHTS,
                _tensor(CLASSIFIER_ROWS),
                3,
            ),
        )
        self.assertEqual(
            oracle.ClassWinnerV1(22, 1, 7),
            matrix_view.winner(class_view, 0),
        )
        self.assertEqual(
            oracle.ClassWinnerV1(33, 2, 4),
            matrix_view.winner(class_view, 1),
        )
        self.assertEqual(
            oracle.ClassWinnerV1(11, 0, 10),
            matrix_view.winner(class_view, 2),
        )
        self.assertNotEqual(
            hashlib.sha256(matrix).digest(),
            matrix_view.class_score_matrix_sha256,
        )
        self.assertEqual(
            CLASS_SCORE_MATRIX_CONTEXT_SHA256,
            matrix_view.class_score_matrix_sha256.hex(),
        )
        self.assertEqual(
            CLASS_SCORE_MATRIX_RAW_SHA256,
            hashlib.sha256(matrix).hexdigest(),
        )

        verified = oracle.verify_classifier_demo_document(_classifier_demo_document())
        self.assertEqual(CLASSIFIER_SCORES, verified.class_score_matrix.scores)
        self.assertEqual(
            hashlib.sha256(matrix).digest(),
            verified.output_sha256,
        )

    def test_class_wires_reject_every_mutation_and_truncation(self) -> None:
        _, classes, policy, _ = _classifier_fixture()

        for label, wire, decoder in (
            ("class map", classes, oracle.decode_class_map),
            (
                "class score policy",
                policy,
                oracle.decode_class_score_policy,
            ),
        ):
            for index in range(len(wire)):
                with self.subTest(label=label, mutation=index):
                    mutated = bytearray(wire)
                    mutated[index] ^= 0x80
                    with self.assertRaises(oracle.OracleError):
                        decoder(bytes(mutated))
            for end in range(len(wire)):
                with self.subTest(label=label, truncation=end):
                    with self.assertRaises(oracle.OracleError):
                        decoder(wire[:end])

        with self.assertRaisesRegex(oracle.OracleError, "duplicate class ID"):
            oracle.decode_class_map(_class_map((11, 22, 22, 44)))

    def test_matrix_mutation_truncation_and_context_drift_are_rejected(
        self,
    ) -> None:
        canonical = _classifier_demo_document()
        matrix_hex = cast(str, canonical["class_score_matrix_hex"])
        matrix = bytes.fromhex(matrix_hex)

        for index in range(len(matrix)):
            with self.subTest(mutation=index):
                document = _classifier_demo_document()
                mutated = bytearray(matrix)
                mutated[index] ^= 0x80
                document["class_score_matrix_hex"] = bytes(mutated).hex()
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_classifier_demo_document(document)
        for end in range(len(matrix)):
            with self.subTest(truncation=end):
                document = _classifier_demo_document()
                document["class_score_matrix_hex"] = matrix[:end].hex()
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_classifier_demo_document(document)

        batch, classes, policy, matrix = _classifier_fixture()
        canonical_view = oracle.decode_class_score_matrix(
            matrix,
            batch,
            classes,
            policy,
        )
        alternate_batch = _batch_map((601, 602, 603))
        alternate_classes = _class_map((111, 122, 133, 144))
        alternate_batch_view = oracle.decode_class_score_matrix(
            matrix,
            alternate_batch,
            classes,
            policy,
        )
        alternate_class_view = oracle.decode_class_score_matrix(
            matrix,
            batch,
            alternate_classes,
            policy,
        )
        self.assertNotEqual(
            canonical_view.class_score_matrix_sha256,
            alternate_batch_view.class_score_matrix_sha256,
        )
        self.assertNotEqual(
            canonical_view.class_score_matrix_sha256,
            alternate_class_view.class_score_matrix_sha256,
        )

        changed_policy = bytearray(policy)
        changed_policy[56] = 1
        body = bytes(changed_policy[:64])
        changed_policy[64:] = _domain_root(
            oracle.CLASS_SCORE_POLICY_DOMAIN,
            body,
        )
        with self.assertRaises(oracle.OracleError):
            oracle.decode_class_score_matrix(
                matrix,
                batch,
                classes,
                bytes(changed_policy),
            )

    def test_reference_classify_rejects_all_shape_drift(self) -> None:
        batch, classes, _, _ = _classifier_fixture()
        tensor = _tensor(CLASSIFIER_ROWS)
        cases: tuple[tuple[object, object, object], ...] = (
            (CLASSIFIER_WEIGHTS[:-1], tensor, 3),
            (CLASSIFIER_WEIGHTS + b"\x00", tensor, 3),
            (CLASSIFIER_WEIGHTS, tensor[:-1], 3),
            (CLASSIFIER_WEIGHTS, tensor + b"\x00", 3),
            (CLASSIFIER_WEIGHTS, tensor, 0),
            (CLASSIFIER_WEIGHTS, tensor, True),
        )
        for weights, encoded_tensor, features in cases:
            with self.subTest(
                weights=len(cast(bytes, weights)),
                tensor=len(cast(bytes, encoded_tensor)),
                features=features,
            ):
                with self.assertRaises(oracle.OracleError):
                    oracle.reference_classify(
                        batch,
                        classes,
                        cast(bytes, weights),
                        cast(bytes, encoded_tensor),
                        cast(int, features),
                    )

    def test_classifier_document_rejects_strict_semantic_drift(self) -> None:
        documents: list[dict[str, object]] = []
        for field, value in (
            ("schema", "foreign"),
            ("verified", False),
            ("class_score_matrix_sha256", "00" * 32),
            ("output_sha256", "00" * 32),
            ("source_mapping_sha256", "00" * 32),
            ("result_sha256", "00" * 32),
            ("input_features", True),
            ("extra", True),
        ):
            document = _classifier_demo_document()
            document[field] = value
            documents.append(document)

        uppercase = _classifier_demo_document()
        uppercase["weights_hex"] = cast(
            str,
            uppercase["weights_hex"],
        ).upper()
        documents.append(uppercase)

        short_weights = _classifier_demo_document()
        short_weights["weights_hex"] = cast(
            str,
            short_weights["weights_hex"],
        )[:-2]
        documents.append(short_weights)

        changed_scores = _classifier_demo_document()
        score_rows = cast(list[dict[str, object]], changed_scores["rows"])
        cast(list[int], score_rows[0]["scores"])[0] = 99
        documents.append(changed_scores)

        changed_winner = _classifier_demo_document()
        winner_rows = cast(list[dict[str, object]], changed_winner["rows"])
        winner = cast(dict[str, int], winner_rows[0]["winner"])
        winner["class_ordinal"] = 2
        documents.append(changed_winner)

        for index, document in enumerate(documents):
            with self.subTest(index=index):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_classifier_demo_document(document)

    def test_classifier_subprocess_uses_exact_mode_argument(self) -> None:
        payload = (
            json.dumps(
                _classifier_demo_document(),
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
            + b"\n"
        )
        completed = subprocess.CompletedProcess(
            args=["/tmp/reranker-demo", "classify"],
            returncode=0,
            stdout=payload,
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_tensor_result.subprocess.run",
            return_value=completed,
        ) as run:
            verified = oracle.run_classifier_demo("/tmp/reranker-demo")
        self.assertEqual(3, verified.batch_map.item_count)
        run.assert_called_once_with(
            ["/tmp/reranker-demo", "classify"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )

    def test_classifier_subprocess_rejects_duplicate_json_fields(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["/tmp/reranker-demo", "classify"],
            returncode=0,
            stdout=b'{"schema":"a","schema":"b"}\n',
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_tensor_result.subprocess.run",
            return_value=completed,
        ):
            with self.assertRaisesRegex(oracle.OracleError, "duplicate"):
                oracle.run_classifier_demo("/tmp/reranker-demo")


if __name__ == "__main__":
    unittest.main()
