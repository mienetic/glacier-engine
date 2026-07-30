from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from bench import native_unary_server_load_publication as publication


GOLDEN_ENVELOPE = b"\x00Glacier\xff-envelope-v1\n"
GOLDEN_MANIFEST = {
    "environment": {
        "post": None,
        "pre": [1, 1.25],
    },
    "producer": {
        "sha256": "00" * 32,
        "size_bytes": 4096,
    },
    "profile": "successful-v1",
    "publication_eligible": False,
    "schema": (
        "glacier.native-unary-server-load-publication-test/v1"
    ),
}
GOLDEN_MANIFEST_BYTES = (
    b'{"environment":{"post":null,"pre":[1,1.25]},'
    b'"producer":{"sha256":"000000000000000000000000000000000000'
    b'0000000000000000000000000000","size_bytes":4096},'
    b'"profile":"successful-v1","publication_eligible":false,'
    b'"schema":"glacier.native-unary-server-load-publication-test/v1"}\n'
)
GOLDEN_ENVELOPE_SHA256 = (
    "ba031e5b4089e56d0cf3fdc1b7a906e1"
    "a5b6456c3022cffc11d7a0432930fcba"
)
GOLDEN_MANIFEST_SHA256 = (
    "4ce356d4295eac000d8cdd05f70c6176d"
    "a57b941a47a59d8668a375c8656a6ea"
)
GOLDEN_IDENTITY_SHA256 = (
    "c65577986c200cab3f5bb4910faa4ca7a"
    "b1159bd17631d86aaf22c773a80ecba"
)
GOLDEN_BUNDLE_SHA256 = (
    "f35432d0613df6561b487343ced32dafe"
    "d71bde8095dde5000d9ca2687700b70"
)
GOLDEN_CANONICAL_ROOT_SHA256 = (
    "77f30e79150646ea80dd1d29165aecad"
    "65f97457dfd90210a0d74ee28eaebaf5"
)


def _domain_hash(domain: bytes, *parts: bytes) -> bytes:
    digest = hashlib.sha256()
    digest.update(domain)
    for part in parts:
        digest.update(part)
    return digest.digest()


def _raw_bundle(
    manifest_bytes: bytes,
    envelope: bytes,
    *,
    magic: bytes = publication.PUBLICATION_MAGIC,
    abi: int = publication.PUBLICATION_ABI,
    flags: int = publication.PUBLICATION_FLAGS,
    declared_bytes: int | None = None,
    manifest_length: int | None = None,
    envelope_length: int | None = None,
    footer_length: int = publication.PUBLICATION_FOOTER_BYTES,
) -> bytes:
    actual_bytes = (
        publication.PUBLICATION_HEADER_BYTES
        + len(manifest_bytes)
        + len(envelope)
        + publication.PUBLICATION_FOOTER_BYTES
    )
    header = publication.PUBLICATION_HEADER_STRUCT.pack(
        magic,
        abi,
        actual_bytes if declared_bytes is None else declared_bytes,
        flags,
        (
            len(manifest_bytes)
            if manifest_length is None
            else manifest_length
        ),
        len(envelope) if envelope_length is None else envelope_length,
        footer_length,
    )
    envelope_sha256 = hashlib.sha256(envelope).digest()
    manifest_sha256 = hashlib.sha256(manifest_bytes).digest()
    identity = _domain_hash(
        publication.PUBLICATION_IDENTITY_DOMAIN,
        header,
        manifest_sha256,
        envelope_sha256,
    )
    footer_prefix = envelope_sha256 + manifest_sha256 + identity
    seal = _domain_hash(
        publication.PUBLICATION_SEAL_DOMAIN,
        header,
        manifest_bytes,
        envelope,
        footer_prefix,
    )
    return (
        header
        + manifest_bytes
        + envelope
        + footer_prefix
        + seal
    )


def _mutate_header(
    encoded: bytes,
    field_index: int,
    value: bytes | int,
) -> bytes:
    fields = list(
        publication.PUBLICATION_HEADER_STRUCT.unpack_from(encoded, 0)
    )
    fields[field_index] = value
    mutated = bytearray(encoded)
    mutated[: publication.PUBLICATION_HEADER_BYTES] = (
        publication.PUBLICATION_HEADER_STRUCT.pack(*fields)
    )
    return bytes(mutated)


class NativeUnaryServerLoadPublicationTests(unittest.TestCase):
    def test_golden_vector_and_stable_api(self) -> None:
        encoded = publication.encode_bundle(
            GOLDEN_ENVELOPE,
            GOLDEN_MANIFEST,
        )
        self.assertEqual(
            publication.encode_bundle(
                GOLDEN_ENVELOPE,
                dict(reversed(tuple(GOLDEN_MANIFEST.items()))),
            ),
            encoded,
        )
        decoded = publication.decode_bundle(encoded)
        self.assertIsInstance(decoded, publication.PublicationBundle)
        self.assertEqual(decoded.envelope, GOLDEN_ENVELOPE)
        self.assertEqual(decoded.manifest, GOLDEN_MANIFEST)
        self.assertEqual(decoded.manifest_bytes, GOLDEN_MANIFEST_BYTES)
        self.assertEqual(
            decoded.envelope_sha256.hex(),
            GOLDEN_ENVELOPE_SHA256,
        )
        self.assertEqual(
            decoded.manifest_sha256.hex(),
            GOLDEN_MANIFEST_SHA256,
        )
        self.assertEqual(
            decoded.publication_identity_sha256.hex(),
            GOLDEN_IDENTITY_SHA256,
        )
        self.assertEqual(
            decoded.bundle_sha256.hex(),
            GOLDEN_BUNDLE_SHA256,
        )
        self.assertEqual(
            hashlib.sha256(encoded).digest(),
            decoded.bundle_sha256,
        )
        self.assertEqual(
            len(encoded),
            publication.PUBLICATION_HEADER_BYTES
            + len(GOLDEN_MANIFEST_BYTES)
            + len(GOLDEN_ENVELOPE)
            + publication.PUBLICATION_FOOTER_BYTES,
        )
        self.assertEqual(
            publication.PUBLICATION_HEADER_STRUCT.unpack_from(
                encoded,
                0,
            ),
            (
                publication.PUBLICATION_MAGIC,
                publication.PUBLICATION_ABI,
                len(encoded),
                0,
                len(GOLDEN_MANIFEST_BYTES),
                len(GOLDEN_ENVELOPE),
                128,
            ),
        )

    def test_canonical_json_and_domain_root_are_deterministic(self) -> None:
        first = {
            "z": [True, False, None, -0.0, 2.5],
            "a": {"unicode": "หิมะ"},
        }
        second = {
            "a": {"unicode": "หิมะ"},
            "z": [True, False, None, -0.0, 2.5],
        }
        expected = (
            b'{"a":{"unicode":"\\u0e2b\\u0e34\\u0e21\\u0e30"},'
            b'"z":[true,false,null,-0.0,2.5]}\n'
        )
        self.assertEqual(
            publication.canonical_json_bytes(first),
            expected,
        )
        self.assertEqual(
            publication.canonical_json_bytes(second),
            expected,
        )
        root = publication.canonical_json_sha256(
            first,
            domain=b"test-publication-context-v1\x00",
        )
        self.assertEqual(root.hex(), GOLDEN_CANONICAL_ROOT_SHA256)
        self.assertNotEqual(
            root,
            publication.canonical_json_sha256(
                first,
                domain=b"test-publication-context-v2\x00",
            ),
        )
        for invalid_domain in (b"", "domain"):
            with self.subTest(domain=invalid_domain):
                with self.assertRaises(publication.PublicationError):
                    publication.canonical_json_sha256(
                        first,
                        domain=invalid_domain,  # type: ignore[arg-type]
                    )

    def test_nonfinite_and_unsupported_json_values_reject(self) -> None:
        for value in (
            {"value": float("nan")},
            {"value": float("inf")},
            {"value": float("-inf")},
            {"value": object()},
            {1: "non-string-key"},
        ):
            with self.subTest(value=repr(value)):
                with self.assertRaises(publication.PublicationError):
                    publication.canonical_json_bytes(value)

    def test_invalid_json_rejects_even_under_valid_structural_seal(
        self,
    ) -> None:
        invalid_values = {
            "duplicate": b'{"value":1,"value":2}\n',
            "nan": b'{"value":NaN}\n',
            "infinity": b'{"value":Infinity}\n',
            "overflowing-float": b'{"value":1e999}\n',
            "oversized-integer": (
                b'{"value":'
                + b"9" * 10_000
                + b"}\n"
            ),
            "noncanonical-space": b'{"a":1, "b":2}\n',
            "noncanonical-order": b'{"b":2,"a":1}\n',
            "noncanonical-unicode": (
                '{"value":"หิมะ"}\n'.encode("utf-8")
            ),
            "missing-newline": b'{"value":1}',
            "top-level-array": b'[1,2]\n',
        }
        for label, manifest_bytes in invalid_values.items():
            with self.subTest(label=label):
                encoded = _raw_bundle(manifest_bytes, b"envelope")
                with self.assertRaises(publication.PublicationError):
                    publication.decode_bundle(encoded)

    def test_deep_json_nesting_fails_closed(self) -> None:
        value: object = 0
        for _ in range(300):
            value = [value]
        with self.assertRaisesRegex(
            publication.PublicationError,
            "nesting",
        ):
            publication.canonical_json_bytes({"value": value})

        deep_manifest = (
            b'{"value":'
            + b"[" * 2_000
            + b"0"
            + b"]" * 2_000
            + b"}\n"
        )
        with self.assertRaises(publication.PublicationError):
            publication.decode_bundle(
                _raw_bundle(deep_manifest, b"envelope")
            )

    def test_header_bounds_truncation_and_trailing_bytes_reject(
        self,
    ) -> None:
        encoded = publication.encode_bundle(
            GOLDEN_ENVELOPE,
            GOLDEN_MANIFEST,
        )
        mutations = {
            "magic": _mutate_header(encoded, 0, b"GF1BAD01"),
            "abi": _mutate_header(
                encoded,
                1,
                publication.PUBLICATION_ABI + 1,
            ),
            "declared": _mutate_header(encoded, 2, len(encoded) + 1),
            "flags": _mutate_header(encoded, 3, 1),
            "empty-manifest": _mutate_header(encoded, 4, 0),
            "oversized-manifest": _mutate_header(
                encoded,
                4,
                publication.MAX_MANIFEST_BYTES + 1,
            ),
            "empty-envelope": _mutate_header(encoded, 5, 0),
            "oversized-envelope": _mutate_header(
                encoded,
                5,
                publication.MAX_ENVELOPE_BYTES + 1,
            ),
            "footer-length": _mutate_header(
                encoded,
                6,
                publication.PUBLICATION_FOOTER_BYTES - 1,
            ),
            "trailing": encoded + b"\x00",
        }
        for label, mutated in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(publication.PublicationError):
                    publication.decode_bundle(mutated)

        manifest_length = len(GOLDEN_MANIFEST_BYTES)
        envelope_start = (
            publication.PUBLICATION_HEADER_BYTES + manifest_length
        )
        for cut in (
            0,
            publication.PUBLICATION_HEADER_BYTES - 1,
            publication.PUBLICATION_HEADER_BYTES,
            envelope_start - 1,
            len(encoded) - publication.PUBLICATION_FOOTER_BYTES,
            len(encoded) - 1,
        ):
            with self.subTest(cut=cut):
                with self.assertRaises(publication.PublicationError):
                    publication.decode_bundle(encoded[:cut])

    def test_manifest_envelope_and_footer_mutations_reject(self) -> None:
        encoded = publication.encode_bundle(
            GOLDEN_ENVELOPE,
            GOLDEN_MANIFEST,
        )
        manifest_start = publication.PUBLICATION_HEADER_BYTES
        envelope_start = manifest_start + len(GOLDEN_MANIFEST_BYTES)
        footer_start = envelope_start + len(GOLDEN_ENVELOPE)
        indices = (
            manifest_start,
            envelope_start,
            footer_start,
            footer_start + 32,
            footer_start + 64,
            footer_start + 96,
        )
        for index in indices:
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(publication.PublicationError):
                    publication.decode_bundle(bytes(mutated))

    def test_cross_bundle_substitution_rejects(self) -> None:
        manifest_a = {"profile": "alpha-v1", "eligible": False}
        manifest_b = {"profile": "bravo-v1", "eligible": False}
        envelope_a = b"A" * 32
        envelope_b = b"B" * 32
        bundle_a = publication.encode_bundle(envelope_a, manifest_a)
        bundle_b = publication.encode_bundle(envelope_b, manifest_b)
        decoded_a = publication.decode_bundle(bundle_a)
        decoded_b = publication.decode_bundle(bundle_b)
        self.assertNotEqual(
            decoded_a.publication_identity_sha256,
            decoded_b.publication_identity_sha256,
        )

        header_a = bundle_a[: publication.PUBLICATION_HEADER_BYTES]
        manifest_a_end = (
            publication.PUBLICATION_HEADER_BYTES
            + len(decoded_a.manifest_bytes)
        )
        footer_a_start = manifest_a_end + len(envelope_a)
        footer_b_start = (
            publication.PUBLICATION_HEADER_BYTES
            + len(decoded_b.manifest_bytes)
            + len(envelope_b)
        )
        substitutions = (
            (
                header_a
                + decoded_b.manifest_bytes
                + envelope_a
                + bundle_a[footer_a_start:]
            ),
            (
                bundle_a[:manifest_a_end]
                + envelope_b
                + bundle_a[footer_a_start:]
            ),
            (
                bundle_a[:footer_a_start]
                + bundle_b[footer_b_start:]
            ),
        )
        for index, substituted in enumerate(substitutions):
            with self.subTest(index=index):
                with self.assertRaises(publication.PublicationError):
                    publication.decode_bundle(substituted)

    def test_input_types_and_fixed_size_bounds_reject(self) -> None:
        with self.assertRaises(publication.PublicationError):
            publication.encode_bundle(b"", {})
        with self.assertRaises(publication.PublicationError):
            publication.encode_bundle(
                bytearray(b"envelope"),  # type: ignore[arg-type]
                {},
            )
        with self.assertRaises(publication.PublicationError):
            publication.encode_bundle(
                b"envelope",
                [],  # type: ignore[arg-type]
            )
        with self.assertRaises(publication.PublicationError):
            publication.decode_bundle(bytearray(b"bundle"))  # type: ignore[arg-type]
        with self.assertRaises(publication.PublicationError):
            publication.canonical_json_bytes(
                {"blob": "x" * publication.MAX_MANIFEST_BYTES}
            )

    def test_atomic_write_success_and_bounded_read(self) -> None:
        first = publication.encode_bundle(b"first", {"generation": 1})
        second = publication.encode_bundle(b"second", {"generation": 2})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "nested" / "capture.glpub"
            publication.atomic_write(destination, first)
            self.assertEqual(
                publication.read_bundle(destination).bundle_sha256,
                hashlib.sha256(first).digest(),
            )
            publication.atomic_write(destination, second)
            decoded = publication.read_bundle(destination)
            self.assertEqual(decoded.envelope, b"second")
            self.assertEqual(decoded.manifest, {"generation": 2})
            self.assertEqual(
                sorted(path.name for path in destination.parent.iterdir()),
                ["capture.glpub"],
            )

    def test_invalid_write_has_no_filesystem_side_effect(self) -> None:
        predecessor = publication.encode_bundle(
            b"predecessor",
            {"generation": 1},
        )
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "capture.glpub"
            destination.write_bytes(predecessor)
            with self.assertRaises(publication.PublicationError):
                publication.atomic_write(destination, b"not-a-bundle")
            self.assertEqual(destination.read_bytes(), predecessor)
            self.assertEqual(
                sorted(path.name for path in destination.parent.iterdir()),
                ["capture.glpub"],
            )

    def test_replace_failure_preserves_predecessor_and_cleans_temp(
        self,
    ) -> None:
        predecessor = publication.encode_bundle(
            b"predecessor",
            {"generation": 1},
        )
        successor = publication.encode_bundle(
            b"successor",
            {"generation": 2},
        )
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "capture.glpub"
            destination.write_bytes(predecessor)
            with mock.patch.object(
                publication.os,
                "replace",
                side_effect=OSError("injected replace failure"),
            ):
                with self.assertRaises(publication.PublicationError):
                    publication.atomic_write(destination, successor)
            self.assertEqual(destination.read_bytes(), predecessor)
            self.assertEqual(
                sorted(path.name for path in destination.parent.iterdir()),
                ["capture.glpub"],
            )

    def test_file_sync_failure_preserves_predecessor_and_cleans_temp(
        self,
    ) -> None:
        predecessor = publication.encode_bundle(
            b"predecessor",
            {"generation": 1},
        )
        successor = publication.encode_bundle(
            b"successor",
            {"generation": 2},
        )
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "capture.glpub"
            destination.write_bytes(predecessor)
            with mock.patch.object(
                publication.os,
                "fsync",
                side_effect=OSError("injected fsync failure"),
            ), mock.patch.object(publication.os, "replace") as replace:
                with self.assertRaises(publication.PublicationError):
                    publication.atomic_write(destination, successor)
            replace.assert_not_called()
            self.assertEqual(destination.read_bytes(), predecessor)
            self.assertEqual(
                sorted(path.name for path in destination.parent.iterdir()),
                ["capture.glpub"],
            )

    def test_bounded_read_rejects_nonregular_and_oversized_files(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(publication.PublicationError):
                publication.read_bundle(root)

            oversized = root / "oversized.glpub"
            with oversized.open("wb") as output:
                output.truncate(publication.MAX_PUBLICATION_BYTES + 1)
            with self.assertRaises(publication.PublicationError):
                publication.read_bundle(oversized)


if __name__ == "__main__":
    unittest.main()
