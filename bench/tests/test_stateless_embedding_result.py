from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

from bench import stateless_embedding_result as oracle


IDS = (101, 202, 303)
INPUT_FEATURES = 2
OUTPUT_DIMENSIONS = 3
WEIGHT_ROWS = (
    (2, 0),
    (-1, 1),
    (0, 3),
)
INPUT_ROWS = (
    (3, 1),
    (-2, 4),
    (1, 1),
)


def _u64(value: int) -> bytes:
    return value.to_bytes(8, "little", signed=False)


def _domain_root(domain: bytes, payload: bytes) -> bytes:
    return hashlib.sha256(domain + payload).digest()


def _batch_map(item_ids: tuple[int, ...] = IDS) -> bytes:
    header_bytes = 32
    item_bytes = 8
    footer_bytes = 32
    magic = b"GSTBMAP1"
    abi = 0x4753_5442_4D00_0001
    domain = b"glacier-stateless-tensor-batch-map-v1\x00"
    length = header_bytes + len(item_ids) * item_bytes + footer_bytes
    body = (
        magic
        + _u64(abi)
        + _u64(length)
        + _u64(len(item_ids))
        + b"".join(_u64(item_id) for item_id in item_ids)
    )
    return body + _domain_root(domain, body)


def _embedding_policy(
    *,
    normalization: int = oracle.NORMALIZATION_Q30_L2,
    component_format: int = oracle.COMPONENT_SIGNED_I32_LE,
    norm_algorithm: int = oracle.NORM_EXACT_SQUARED_THRESHOLD,
    rounding: int = oracle.ROUND_NEAREST_TIES_TO_EVEN,
    zero_policy: int = oracle.ZERO_VECTOR_REJECT,
    scale: int = oracle.Q30_SCALE,
    reserved: int = 0,
) -> bytes:
    body = (
        oracle.EMBEDDING_POLICY_MAGIC
        + _u64(oracle.EMBEDDING_POLICY_ABI)
        + _u64(oracle.EMBEDDING_POLICY_BYTES)
        + _u64(normalization)
        + _u64(component_format)
        + _u64(norm_algorithm)
        + _u64(rounding)
        + _u64(zero_policy)
        + _u64(scale)
        + _u64(reserved)
    )
    return body + _domain_root(oracle.EMBEDDING_POLICY_DOMAIN, body)


def _weights(
    rows: tuple[tuple[int, ...], ...] = WEIGHT_ROWS,
) -> bytes:
    return bytes(value % 256 for row in rows for value in row)


def _tensor(
    rows: tuple[tuple[int, ...], ...] = INPUT_ROWS,
) -> bytes:
    return b"".join(
        value.to_bytes(2, "little", signed=True)
        for row in rows
        for value in row
    )


def _fixture() -> tuple[
    bytes,
    bytes,
    bytes,
    tuple[oracle.EmbeddingRowV1, ...],
]:
    batch = _batch_map()
    policy = _embedding_policy()
    rows = oracle.reference_embedding(
        batch,
        _weights(),
        _tensor(),
        INPUT_FEATURES,
        OUTPUT_DIMENSIONS,
    )
    return batch, policy, oracle.encode_embedding_rows(rows), rows


def _demo_document() -> dict[str, object]:
    batch, policy, embedding, rows = _fixture()
    policy_view = oracle.decode_embedding_policy(policy)
    matrix_root = oracle.embedding_matrix_sha256(
        batch[-32:],
        policy_view.embedding_policy_sha256,
        len(IDS),
        OUTPUT_DIMENSIONS,
        embedding,
    )
    return {
        "schema": oracle.DEMO_SCHEMA,
        "batch_map_hex": batch.hex(),
        "embedding_policy_hex": policy.hex(),
        "embedding_hex": embedding.hex(),
        "weights_hex": _weights().hex(),
        "tensor_hex": _tensor().hex(),
        "input_features": INPUT_FEATURES,
        "output_dimensions": OUTPUT_DIMENSIONS,
        "source_mapping_sha256": hashlib.sha256(b"source-map").hexdigest(),
        "result_sha256": hashlib.sha256(b"result-envelope").hexdigest(),
        "output_sha256": hashlib.sha256(embedding).hexdigest(),
        "embedding_sha256": matrix_root.hex(),
        "rows": [row.document() for row in rows],
        "verified": True,
    }


class StatelessEmbeddingResultOracleTests(unittest.TestCase):
    def test_retained_fixture_round_trip_and_known_vectors(self) -> None:
        batch, policy, embedding, expected_rows = _fixture()
        policy_view = oracle.decode_embedding_policy(policy)
        self.assertEqual(oracle.Q30_SCALE, policy_view.scale)
        matrix = oracle.decode_embedding_matrix(
            embedding,
            batch,
            policy_view,
            OUTPUT_DIMENSIONS,
        )
        self.assertEqual(expected_rows, matrix.rows)
        self.assertEqual(
            (
                oracle.EmbeddingRowV1(
                    101,
                    0,
                    (920350135, -306783378, 460175067),
                ),
                oracle.EmbeddingRowV1(
                    202,
                    1,
                    (-306783378, 460175067, 920350135),
                ),
                oracle.EmbeddingRowV1(
                    303,
                    2,
                    (595604800, 0, 893407201),
                ),
            ),
            expected_rows,
        )
        verified = oracle.verify_demo_document(_demo_document())
        self.assertEqual(expected_rows, verified.embedding_matrix.rows)
        self.assertEqual(hashlib.sha256(embedding).digest(), verified.output_sha256)

    def test_axis_mixed_sign_and_rounding(self) -> None:
        q = oracle.Q30_SCALE
        self.assertEqual((q, 0), oracle.normalize_q30_l2((7, 0)))
        self.assertEqual((-q, 0), oracle.normalize_q30_l2((-7, 0)))
        self.assertEqual(
            (644245094, -858993459),
            oracle.normalize_q30_l2((3, -4)),
        )

    def test_squared_threshold_ties_round_to_even(self) -> None:
        self.assertEqual(
            0,
            oracle.round_sqrt_ratio_nearest_even(
                target=1,
                denominator=4,
                maximum=2,
            ),
        )
        self.assertEqual(
            2,
            oracle.round_sqrt_ratio_nearest_even(
                target=9,
                denominator=4,
                maximum=2,
            ),
        )
        self.assertEqual(
            1,
            oracle.round_sqrt_ratio_nearest_even(
                target=2,
                denominator=1,
                maximum=2,
            ),
        )

    def test_policy_mutation_footer_reserved_and_noncanonical_fields(self) -> None:
        policy = _embedding_policy()
        for index in range(len(policy)):
            with self.subTest(index=index):
                mutated = bytearray(policy)
                mutated[index] ^= 0x80
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_embedding_policy(bytes(mutated))

        with self.assertRaisesRegex(oracle.OracleError, "reserved"):
            oracle.decode_embedding_policy(_embedding_policy(reserved=1))
        for keywords in (
            {"normalization": 2},
            {"component_format": 2},
            {"norm_algorithm": 2},
            {"rounding": 2},
            {"zero_policy": 2},
            {"scale": oracle.Q30_SCALE - 1},
        ):
            with self.subTest(keywords=keywords):
                with self.assertRaisesRegex(oracle.OracleError, "canonical"):
                    oracle.decode_embedding_policy(
                        _embedding_policy(**keywords)
                    )

    def test_every_policy_truncation_is_rejected(self) -> None:
        policy = _embedding_policy()
        for end in range(len(policy)):
            with self.subTest(end=end):
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_embedding_policy(policy[:end])

    def test_shape_truncation_weights_mismatch_and_zero_row(self) -> None:
        batch, policy, embedding, _ = _fixture()
        for end in range(len(embedding)):
            with self.subTest(end=end):
                with self.assertRaises(oracle.OracleError):
                    oracle.decode_embedding_matrix(
                        embedding[:end],
                        batch,
                        policy,
                        OUTPUT_DIMENSIONS,
                    )

        cases = (
            (_weights()[:-1], _tensor(), INPUT_FEATURES, OUTPUT_DIMENSIONS),
            (_weights(), _tensor()[:-1], INPUT_FEATURES, OUTPUT_DIMENSIONS),
            (_weights(), _tensor(), 0, OUTPUT_DIMENSIONS),
            (_weights(), _tensor(), INPUT_FEATURES, 0),
            (_weights(), _tensor(), True, OUTPUT_DIMENSIONS),
        )
        for weights, tensor, features, dimensions in cases:
            with self.subTest(
                weights=len(weights),
                tensor=len(tensor),
                features=features,
                dimensions=dimensions,
            ):
                with self.assertRaises(oracle.OracleError):
                    oracle.reference_embedding(
                        batch,
                        weights,
                        tensor,
                        features,
                        dimensions,
                    )

        zero_weights = bytes(OUTPUT_DIMENSIONS * INPUT_FEATURES)
        with self.assertRaisesRegex(oracle.OracleError, "zero projection"):
            oracle.reference_embedding(
                batch,
                zero_weights,
                _tensor(),
                INPUT_FEATURES,
                OUTPUT_DIMENSIONS,
            )

    def test_profile_limits_are_enforced(self) -> None:
        too_many_ids = tuple(
            range(1, oracle.EMBEDDING_MAX_BATCH_ITEMS + 2)
        )
        with self.assertRaisesRegex(oracle.OracleError, "batch exceeds"):
            oracle.reference_embedding(
                _batch_map(too_many_ids),
                b"\x01",
                b"\x01\x00" * len(too_many_ids),
                1,
                1,
            )
        batch = _batch_map((1,))
        with self.assertRaisesRegex(oracle.OracleError, "input_features"):
            oracle.reference_embedding(
                batch,
                bytes(oracle.MAXIMUM_INPUT_FEATURES + 1),
                bytes((oracle.MAXIMUM_INPUT_FEATURES + 1) * 2),
                oracle.MAXIMUM_INPUT_FEATURES + 1,
                1,
            )
        with self.assertRaisesRegex(oracle.OracleError, "output_dimensions"):
            oracle.reference_embedding(
                batch,
                bytes(oracle.MAXIMUM_OUTPUT_DIMENSIONS + 1),
                b"\x01\x00",
                1,
                oracle.MAXIMUM_OUTPUT_DIMENSIONS + 1,
            )

    def test_output_mutation_hash_and_declared_row_drift_are_rejected(self) -> None:
        documents: list[dict[str, object]] = []

        changed_output = _demo_document()
        encoded = bytearray.fromhex(
            cast(str, changed_output["embedding_hex"])
        )
        encoded[0] ^= 1
        changed_output["embedding_hex"] = encoded.hex()
        documents.append(changed_output)

        for field in ("output_sha256", "embedding_sha256"):
            changed_hash = _demo_document()
            changed_hash[field] = "00" * 32
            documents.append(changed_hash)

        changed_row = _demo_document()
        rows = cast(list[dict[str, object]], changed_row["rows"])
        components = cast(list[int], rows[0]["components"])
        components[0] += 1
        documents.append(changed_row)

        for index, document in enumerate(documents):
            with self.subTest(index=index):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_demo_document(document)

    def test_demo_rejects_schema_hex_lifecycle_shape_and_field_drift(self) -> None:
        documents: list[dict[str, object]] = []
        for field, value in (
            ("schema", "foreign"),
            ("verified", False),
            ("source_mapping_sha256", "00" * 32),
            ("result_sha256", "00" * 32),
            ("input_features", True),
            ("output_dimensions", oracle.MAXIMUM_OUTPUT_DIMENSIONS + 1),
            ("extra", True),
        ):
            document = _demo_document()
            document[field] = value
            documents.append(document)

        uppercase = _demo_document()
        uppercase["weights_hex"] = cast(
            str,
            uppercase["weights_hex"],
        ).upper()
        documents.append(uppercase)

        odd_hex = _demo_document()
        odd_hex["tensor_hex"] = cast(str, odd_hex["tensor_hex"])[:-1]
        documents.append(odd_hex)

        short_weights = _demo_document()
        short_weights["weights_hex"] = cast(
            str,
            short_weights["weights_hex"],
        )[:-2]
        documents.append(short_weights)

        for index, document in enumerate(documents):
            with self.subTest(index=index):
                with self.assertRaises(oracle.OracleError):
                    oracle.verify_demo_document(document)

    def test_demo_subprocess_invocation_and_extra_output_rejection(self) -> None:
        payload = json.dumps(
            _demo_document(),
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        completed = subprocess.CompletedProcess(
            args=["/tmp/embedding-demo"],
            returncode=0,
            stdout=payload + b"\n",
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_embedding_result.subprocess.run",
            return_value=completed,
        ) as run:
            verified = oracle.run_demo("/tmp/embedding-demo")
        self.assertEqual(len(IDS), verified.embedding_matrix.item_count)
        run.assert_called_once_with(
            ["/tmp/embedding-demo"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )

        transports = (
            (0, payload, b""),
            (0, payload + b"\n\n", b""),
            (0, payload + b"\r\n", b""),
            (0, payload + b"\nextra\n", b""),
            (0, payload + b"\n", b"warning"),
            (1, payload + b"\n", b""),
            (0, b"\xff\n", b""),
            (0, b"{bad json}\n", b""),
        )
        for returncode, stdout, stderr in transports:
            with self.subTest(
                returncode=returncode,
                stdout=stdout[-12:],
                stderr=stderr,
            ):
                completed = subprocess.CompletedProcess(
                    args=["/tmp/embedding-demo"],
                    returncode=returncode,
                    stdout=stdout,
                    stderr=stderr,
                )
                with mock.patch(
                    "bench.stateless_embedding_result.subprocess.run",
                    return_value=completed,
                ):
                    with self.assertRaises(oracle.OracleError):
                        oracle.run_demo("/tmp/embedding-demo")

    def test_shared_demo_selects_embedding_mode(self) -> None:
        payload = json.dumps(
            _demo_document(),
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        completed = subprocess.CompletedProcess(
            args=["/tmp/dense-tensor-demo", "embed"],
            returncode=0,
            stdout=payload + b"\n",
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_embedding_result.subprocess.run",
            return_value=completed,
        ) as run:
            verified = oracle.run_shared_demo("/tmp/dense-tensor-demo")
        self.assertEqual(len(IDS), verified.embedding_matrix.item_count)
        run.assert_called_once_with(
            ["/tmp/dense-tensor-demo", "embed"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )

    def test_duplicate_json_fields_are_rejected(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["/tmp/embedding-demo"],
            returncode=0,
            stdout=b'{"schema":"a","schema":"b"}\n',
            stderr=b"",
        )
        with mock.patch(
            "bench.stateless_embedding_result.subprocess.run",
            return_value=completed,
        ):
            with self.assertRaisesRegex(oracle.OracleError, "duplicate"):
                oracle.run_demo("/tmp/embedding-demo")

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
                "test \"$#\" -eq 0 || exit 64\n"
                "exec printf '%s\\n' "
                + repr(payload)
                + "\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            self.assertEqual(0, oracle.main(("--demo", str(script))))

    def test_shared_demo_cli_passes_embedding_mode(self) -> None:
        payload = json.dumps(
            _demo_document(),
            sort_keys=True,
            separators=(",", ":"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "demo"
            script.write_text(
                "#!/bin/sh\n"
                "test \"$#\" -eq 1 || exit 64\n"
                "test \"$1\" = embed || exit 64\n"
                "exec printf '%s\\n' "
                + repr(payload)
                + "\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            self.assertEqual(
                0,
                oracle.main(("--shared-demo", str(script))),
            )

    def test_direct_cli_bootstraps_repo_import_without_pythonpath(self) -> None:
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
