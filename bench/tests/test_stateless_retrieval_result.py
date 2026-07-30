from __future__ import annotations

import hashlib
import json
import os
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from typing import cast
from unittest import mock

from bench import stateless_retrieval_result as oracle


def _u64(value: int) -> bytes:
    return value.to_bytes(8, "little")


def _root(domain: bytes, body: bytes) -> bytes:
    return hashlib.sha256(domain + body).digest()


def _batch_map(ids: tuple[int, ...]) -> bytes:
    body = (
        oracle.BATCH_MAP_MAGIC
        + _u64(oracle.BATCH_MAP_ABI)
        + _u64(64 + len(ids) * 8)
        + _u64(len(ids))
        + b"".join(_u64(value) for value in ids)
    )
    return body + _root(oracle.BATCH_MAP_DOMAIN, body)


def _embedding_policy() -> bytes:
    body = (
        oracle.EMBEDDING_POLICY_MAGIC
        + _u64(oracle.EMBEDDING_POLICY_ABI)
        + _u64(oracle.EMBEDDING_POLICY_BYTES)
        + b"".join(
            _u64(value)
            for value in (1, 1, 1, 1, 1, oracle.Q30_SCALE, 0)
        )
    )
    return body + _root(oracle.EMBEDDING_POLICY_DOMAIN, body)


def _retrieval_policy(top_k: int = oracle.REFERENCE_TOP_K) -> bytes:
    body = (
        oracle.RETRIEVAL_POLICY_MAGIC
        + _u64(oracle.RETRIEVAL_POLICY_ABI)
        + _u64(oracle.RETRIEVAL_POLICY_BYTES)
        + b"".join(_u64(value) for value in (1, 1, 1, 1, 1, top_k, 0))
    )
    return body + _root(oracle.RETRIEVAL_POLICY_DOMAIN, body)


def _visibility(corpus_map: bytes, scopes: tuple[int, ...]) -> bytes:
    body = (
        oracle.VISIBILITY_MAGIC
        + _u64(oracle.VISIBILITY_ABI)
        + _u64(96 + len(scopes) * 8)
        + _u64(len(scopes))
        + corpus_map[-32:]
        + b"".join(_u64(value) for value in scopes)
    )
    return body + _root(oracle.VISIBILITY_DOMAIN, body)


def _matrix_root(
    batch_root: bytes,
    policy_root: bytes,
    items: int,
    dimensions: int,
    encoded: bytes,
) -> bytes:
    return _root(
        oracle.EMBEDDING_MATRIX_DOMAIN,
        batch_root
        + policy_root
        + _u64(items)
        + _u64(dimensions)
        + encoded,
    )


def _i32(values: tuple[int, ...]) -> bytes:
    return b"".join(value.to_bytes(4, "little", signed=True) for value in values)


def _index(
    corpus_map_root: bytes,
    visibility_root: bytes,
    embedding_policy_root: bytes,
    corpus_embedding_root: bytes,
) -> bytes:
    body = (
        oracle.INDEX_MAGIC
        + _u64(oracle.INDEX_ABI)
        + _u64(oracle.INDEX_BYTES)
        + _u64(1)
        + _u64(len(oracle.REFERENCE_CORPUS_IDS))
        + _u64(oracle.REFERENCE_DIMENSIONS)
        + _u64(0)
        + _u64(0)
        + hashlib.sha256(b"reference fixed corpus index").digest()
        + corpus_map_root
        + visibility_root
        + embedding_policy_root
        + corpus_embedding_root
    )
    return body + _root(oracle.INDEX_DOMAIN, body)


def _query_binding(
    query_map_root: bytes,
    policy_root: bytes,
    query_embedding_root: bytes,
    index_root: bytes,
    retrieval_policy_root: bytes,
) -> bytes:
    body = (
        oracle.QUERY_BINDING_MAGIC
        + _u64(oracle.QUERY_BINDING_ABI)
        + _u64(oracle.QUERY_BINDING_BYTES)
        + _u64(oracle.REFERENCE_QUERY_TENANT)
        + _u64(oracle.REFERENCE_DIMENSIONS)
        + bytes(24)
        + hashlib.sha256(b"reference retrieval query object").digest()
        + query_map_root
        + policy_root
        + query_embedding_root
        + index_root
        + retrieval_policy_root
        + hashlib.sha256(b"reference retrieval challenge").digest()
    )
    return body + _root(oracle.QUERY_BINDING_DOMAIN, body)


def _fixture_parts() -> dict[str, bytes]:
    corpus_map = _batch_map(oracle.REFERENCE_CORPUS_IDS)
    query_map = _batch_map(oracle.REFERENCE_QUERY_IDS)
    embedding_policy = _embedding_policy()
    retrieval_policy = _retrieval_policy()
    corpus_embedding = _i32(oracle.REFERENCE_CORPUS_COMPONENTS)
    query_embedding = _i32(oracle.REFERENCE_QUERY_COMPONENTS)
    visibility = _visibility(corpus_map, oracle.REFERENCE_VISIBILITY)
    corpus_embedding_root = _matrix_root(
        corpus_map[-32:],
        embedding_policy[-32:],
        len(oracle.REFERENCE_CORPUS_IDS),
        oracle.REFERENCE_DIMENSIONS,
        corpus_embedding,
    )
    query_embedding_root = _matrix_root(
        query_map[-32:],
        embedding_policy[-32:],
        1,
        oracle.REFERENCE_DIMENSIONS,
        query_embedding,
    )
    index = _index(
        corpus_map[-32:],
        visibility[-32:],
        embedding_policy[-32:],
        corpus_embedding_root,
    )
    query_binding = _query_binding(
        query_map[-32:],
        embedding_policy[-32:],
        query_embedding_root,
        index[-32:],
        retrieval_policy[-32:],
    )
    packed_weights = index + corpus_embedding

    output = bytearray(
        len(oracle.REFERENCE_CORPUS_IDS) * oracle.RETRIEVAL_HIT_BYTES
    )
    for rank, (item_id, ordinal, score) in enumerate(
        ((201, 1, 0), (202, 2, 0))
    ):
        offset = rank * oracle.RETRIEVAL_HIT_BYTES
        body = struct.pack("<QQQq", item_id, ordinal, rank, score) + bytes(32)
        output[offset : offset + 64] = body
        output[offset + 64 : offset + 96] = hashlib.sha256(
            oracle.RETRIEVAL_HIT_DOMAIN
            + index[-32:]
            + query_binding[-32:]
            + retrieval_policy[-32:]
            + body
        ).digest()
    retrieval_result = bytes(output)
    return {
        "corpus_map": corpus_map,
        "query_map": query_map,
        "embedding_policy": embedding_policy,
        "retrieval_policy": retrieval_policy,
        "visibility": visibility,
        "index": index,
        "query_binding": query_binding,
        "packed_weights": packed_weights,
        "query_embedding": query_embedding,
        "retrieval_result": retrieval_result,
    }


def _document() -> dict[str, object]:
    parts = _fixture_parts()
    corpus_map = oracle.decode_batch_map(parts["corpus_map"])
    query_map = oracle.decode_batch_map(parts["query_map"])
    embedding_policy = oracle.decode_embedding_policy(parts["embedding_policy"])
    retrieval_policy = oracle.decode_retrieval_policy(parts["retrieval_policy"])
    visibility = oracle.decode_visibility_map(parts["visibility"], corpus_map)
    index = oracle.decode_index(parts["index"])
    query_binding = oracle.decode_query_binding(parts["query_binding"])
    corpus_embedding = oracle.decode_embedding_matrix(
        parts["packed_weights"][oracle.INDEX_BYTES :],
        corpus_map,
        embedding_policy,
        index.dimensions,
    )
    query_embedding = oracle.decode_embedding_matrix(
        parts["query_embedding"],
        query_map,
        embedding_policy,
        index.dimensions,
    )
    result = oracle.reference_retrieval(
        corpus_map,
        visibility,
        corpus_embedding,
        index,
        query_embedding,
        retrieval_policy,
        query_binding,
    )
    source_root, result_root = oracle._lifecycle_roots(
        index,
        query_binding,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        corpus_embedding,
        query_embedding,
        parts["packed_weights"],
        result.encoded,
    )
    return {
        "schema": oracle.DEMO_SCHEMA,
        "corpus_map_hex": parts["corpus_map"].hex(),
        "query_map_hex": parts["query_map"].hex(),
        "embedding_policy_hex": parts["embedding_policy"].hex(),
        "retrieval_policy_hex": parts["retrieval_policy"].hex(),
        "visibility_hex": parts["visibility"].hex(),
        "index_hex": parts["index"].hex(),
        "query_binding_hex": parts["query_binding"].hex(),
        "packed_weights_hex": parts["packed_weights"].hex(),
        "query_embedding_hex": parts["query_embedding"].hex(),
        "retrieval_result_hex": result.encoded.hex(),
        "output_sha256": hashlib.sha256(result.encoded).hexdigest(),
        "source_mapping_sha256": source_root.hex(),
        "result_sha256": result_root.hex(),
        "retrieval_result_sha256": result.retrieval_result_sha256.hex(),
        "hits": [hit.document() for hit in result.hits],
        "verified": True,
    }


class StatelessRetrievalResultTests(unittest.TestCase):
    def test_reference_fixture_round_trip_and_exact_roots(self) -> None:
        document = _document()
        verified = oracle.verify_demo_document(document)
        self.assertEqual(
            (
                oracle.RetrievalHitV1(0, 201, 1, 0),
                oracle.RetrievalHitV1(1, 202, 2, 0),
            ),
            verified.retrieval_result.hits,
        )
        self.assertEqual(
            document["output_sha256"], verified.output_sha256.hex()
        )
        self.assertEqual(
            document["source_mapping_sha256"],
            verified.source_mapping_sha256.hex(),
        )
        self.assertEqual(
            document["result_sha256"], verified.result_sha256.hex()
        )

    def test_q60_rounding_is_symmetric_ties_to_even(self) -> None:
        half = 1 << 29
        unit = 1 << 30
        cases = {
            0: 0,
            half: 0,
            unit + half: 2,
            2 * unit + half: 2,
            -half: 0,
            -(unit + half): -2,
            -(2 * unit + half): -2,
            unit + half + 1: 2,
            -(unit + half + 1): -2,
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(
                    expected, oracle.downscale_q60_to_q30(value)
                )

    def test_every_authenticated_wire_byte_mutation_is_rejected(self) -> None:
        fields = (
            "corpus_map_hex",
            "query_map_hex",
            "embedding_policy_hex",
            "retrieval_policy_hex",
            "visibility_hex",
            "index_hex",
            "query_binding_hex",
        )
        for field in fields:
            original = bytes.fromhex(cast(str, _document()[field]))
            for index in range(len(original)):
                with self.subTest(field=field, index=index):
                    document = _document()
                    mutated = bytearray(original)
                    mutated[index] ^= 1
                    document[field] = mutated.hex()
                    with self.assertRaises(oracle.OracleError):
                        oracle.verify_demo_document(document)

    def test_payload_result_and_root_substitutions_are_rejected(self) -> None:
        for field in (
            "packed_weights_hex",
            "query_embedding_hex",
            "retrieval_result_hex",
        ):
            document = _document()
            value = bytearray.fromhex(cast(str, document[field]))
            for index in range(len(value)):
                with self.subTest(field=field, index=index):
                    changed = dict(document)
                    mutated = bytearray(value)
                    mutated[index] ^= 1
                    changed[field] = mutated.hex()
                    with self.assertRaises(oracle.OracleError):
                        oracle.verify_demo_document(changed)
        for field in (
            "output_sha256",
            "source_mapping_sha256",
            "result_sha256",
            "retrieval_result_sha256",
        ):
            document = _document()
            document[field] = hashlib.sha256(field.encode()).hexdigest()
            with self.subTest(field=field):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_demo_document(document)

    def test_truncation_extension_and_malformed_hex_are_rejected(self) -> None:
        binary_fields = tuple(
            field for field in oracle.DEMO_FIELDS if field.endswith("_hex")
        )
        for field in binary_fields:
            document = _document()
            original = cast(str, document[field])
            uppercase_or_invalid = original.upper()
            if uppercase_or_invalid == original:
                uppercase_or_invalid = original + "gg"
            variants = (
                original[:-2],
                original + "00",
                original[:-1],
                uppercase_or_invalid,
            )
            for number, value in enumerate(variants):
                with self.subTest(field=field, number=number):
                    changed = dict(document)
                    changed[field] = value
                    with self.assertRaises(oracle.OracleError):
                        oracle.verify_demo_document(changed)

    def test_foreign_tenant_exposure_tie_reorder_score_and_tail_fail(self) -> None:
        mutations: list[dict[str, object]] = []
        for offset in (0, 96, 24, 2 * 96):
            document = _document()
            encoded = bytearray.fromhex(
                cast(str, document["retrieval_result_hex"])
            )
            if offset == 0:
                encoded[0:8] = _u64(101)
                encoded[8:16] = _u64(0)
            elif offset == 96:
                first = bytes(encoded[:96])
                encoded[:96] = encoded[96:192]
                encoded[96:192] = first
            elif offset == 24:
                encoded[24:32] = (1).to_bytes(8, "little", signed=True)
            else:
                encoded[offset] = 1
            document["retrieval_result_hex"] = encoded.hex()
            mutations.append(document)
        changed_hits = _document()
        hits = cast(list[dict[str, int]], changed_hits["hits"])
        hits[0]["item_id"] = 101
        mutations.append(changed_hits)
        for number, document in enumerate(mutations):
            with self.subTest(number=number):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_demo_document(document)

    def test_missing_unknown_schema_types_and_hit_shape_are_rejected(self) -> None:
        documents: list[dict[str, object]] = []
        missing = _document()
        missing.pop("index_hex")
        documents.append(missing)
        extra = _document()
        extra["extra"] = True
        documents.append(extra)
        for field, value in (
            ("schema", "foreign"),
            ("verified", False),
            ("hits", {}),
        ):
            document = _document()
            document[field] = value
            documents.append(document)
        bad_hit = _document()
        cast(list[dict[str, object]], bad_hit["hits"])[0]["extra"] = 1
        documents.append(bad_hit)
        bool_hit = _document()
        cast(list[dict[str, object]], bool_hit["hits"])[0]["rank"] = True
        documents.append(bool_hit)
        for number, document in enumerate(documents):
            with self.subTest(number=number):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_demo_document(document)

    def test_subprocess_contract_modes_and_transport_rejections(self) -> None:
        payload = json.dumps(
            _document(), sort_keys=True, separators=(",", ":")
        ).encode()
        completed = subprocess.CompletedProcess(
            args=["/tmp/retrieval"], returncode=0, stdout=payload + b"\n", stderr=b""
        )
        with mock.patch(
            "bench.stateless_retrieval_result.subprocess.run",
            return_value=completed,
        ) as run:
            oracle.run_demo("/tmp/retrieval")
        run.assert_called_once_with(
            ["/tmp/retrieval"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        with mock.patch(
            "bench.stateless_retrieval_result.subprocess.run",
            return_value=completed,
        ) as run:
            oracle.run_shared_demo("/tmp/retrieval")
        self.assertEqual(["/tmp/retrieval", "retrieve"], run.call_args.args[0])

        transports = (
            (0, payload, b""),
            (0, payload + b"\n\n", b""),
            (0, payload + b"\r\n", b""),
            (0, payload + b"\nextra\n", b""),
            (0, payload + b"\n", b"warning"),
            (1, payload + b"\n", b""),
            (0, b"\xff\n", b""),
            (0, b"{bad}\n", b""),
            (0, b'{"schema":"a","schema":"b"}\n', b""),
        )
        for returncode, stdout, stderr in transports:
            completed = subprocess.CompletedProcess(
                args=["/tmp/retrieval"],
                returncode=returncode,
                stdout=stdout,
                stderr=stderr,
            )
            with self.subTest(returncode=returncode, stdout=stdout[-8:]):
                with mock.patch(
                    "bench.stateless_retrieval_result.subprocess.run",
                    return_value=completed,
                ):
                    with self.assertRaises(oracle.OracleError):
                        oracle.run_demo("/tmp/retrieval")

    def test_timeout_and_os_errors_are_wrapped(self) -> None:
        for error in (
            subprocess.TimeoutExpired(["demo"], 30),
            OSError("missing"),
        ):
            with self.subTest(error=type(error).__name__):
                with mock.patch(
                    "bench.stateless_retrieval_result.subprocess.run",
                    side_effect=error,
                ):
                    with self.assertRaisesRegex(
                        oracle.OracleError, "could not run demo"
                    ):
                        oracle.run_demo("/tmp/retrieval")

    def test_cli_real_temporary_executables_and_canonical_receipt(self) -> None:
        payload = json.dumps(
            _document(), sort_keys=True, separators=(",", ":")
        )
        with tempfile.TemporaryDirectory() as temporary:
            standalone = Path(temporary) / "standalone"
            shared = Path(temporary) / "shared"
            standalone.write_text(
                "#!/bin/sh\n"
                "test \"$#\" -eq 0 || exit 64\n"
                f"exec printf '%s\\n' '{payload}'\n",
                encoding="utf-8",
            )
            shared.write_text(
                "#!/bin/sh\n"
                "test \"$#\" -eq 1 || exit 64\n"
                "test \"$1\" = retrieve || exit 64\n"
                f"exec printf '%s\\n' '{payload}'\n",
                encoding="utf-8",
            )
            standalone.chmod(standalone.stat().st_mode | stat.S_IXUSR)
            shared.chmod(shared.stat().st_mode | stat.S_IXUSR)
            capture = StringIO()
            with redirect_stdout(capture):
                self.assertEqual(0, oracle.main(("--demo", str(standalone))))
            line = capture.getvalue()
            self.assertTrue(line.endswith("\n"))
            self.assertEqual(1, line.count("\n"))
            receipt = json.loads(line)
            self.assertEqual(oracle.VERIFICATION_SCHEMA, receipt["schema"])
            self.assertTrue(receipt["verified"])
            with redirect_stdout(StringIO()):
                self.assertEqual(
                    0, oracle.main(("--shared-demo", str(shared)))
                )

    def test_cli_modes_are_mutually_exclusive_and_direct_help_bootstraps(self) -> None:
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit):
                oracle.main(())
            with self.assertRaises(SystemExit):
                oracle.main(("--demo", "a", "--shared-demo", "b"))
        environment = dict(os.environ)
        environment.pop("PYTHONPATH", None)
        script = Path(oracle.__file__).resolve()
        with tempfile.TemporaryDirectory() as temporary:
            completed = subprocess.run(
                [sys.executable, str(script), "--help"],
                cwd=temporary,
                env=environment,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn(b"--demo", completed.stdout)
        self.assertIn(b"--shared-demo", completed.stdout)


if __name__ == "__main__":
    unittest.main()
