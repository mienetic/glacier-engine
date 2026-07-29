import hashlib
import importlib.util
import os
import platform
import struct
import sys
import tempfile
import unittest
from pathlib import Path
import zlib


BENCH_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = BENCH_DIR / "runtime_image_durable_recovery.py"
SPEC = importlib.util.spec_from_file_location(
    "runtime_image_durable_recovery",
    MODULE_PATH,
)
assert SPEC is not None and SPEC.loader is not None
recovery = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = recovery
SPEC.loader.exec_module(recovery)


PREDECESSOR_RAW = bytes.fromhex(
    "0000803f"
    "00000040"
    "00004040"
    "00008040"
)
PREDECESSOR_PACKED = bytes.fromhex("1032547667452301")
PREDECESSOR_SCALE = bytes.fromhex("0000003f")
SUCCESSOR_RAW = bytes.fromhex(
    "00001041"
    "00002041"
    "00003041"
    "00004041"
)
SUCCESSOR_PACKED = bytes.fromhex("89abcdeffedcba98")
SUCCESSOR_SCALE = bytes.fromhex("0000803e")

ABI_FINGERPRINT_V2_AARCH64 = bytes.fromhex(
    "d0d7df06350af6b2d48e282f65ff873a"
    "3cf95bd6397b1d2d26cc6e679304e06f"
)
ABI_FINGERPRINT_V2_PORTABLE = bytes.fromhex(
    "8f291472be36fab2d8e32bfbb87671eb"
    "bb18a982036a2d17dc06cbe2907ec890"
)


def _host_abi_fingerprint() -> bytes:
    if platform.machine().lower() in ("aarch64", "arm64"):
        return ABI_FINGERPRINT_V2_AARCH64
    return ABI_FINGERPRINT_V2_PORTABLE


def _encode_record(
    *,
    kind: int,
    encoding: int,
    packed_layout: int,
    group_size: int,
    out_f: int,
    in_f: int,
    num_elements: int,
    ranges: tuple[tuple[int, int], ...],
    payloads: tuple[bytes, ...],
) -> bytes:
    descriptor = bytearray(recovery.GLRT_RECORD_SIZE)
    struct.pack_into("<II", descriptor, 0, 0, kind)
    struct.pack_into("<HH", descriptor, 8, encoding, packed_layout)
    struct.pack_into(
        "<IIII",
        descriptor,
        12,
        group_size,
        out_f,
        in_f,
        0,
    )
    crc = 0
    for payload in payloads:
        crc = zlib.crc32(payload, crc) & recovery.MAX_U32
    struct.pack_into("<I", descriptor, 28, crc)
    struct.pack_into("<Q", descriptor, 32, num_elements)
    for offset, value in zip(recovery.STREAM_RANGE_OFFSETS, ranges):
        struct.pack_into("<QQ", descriptor, offset, *value)
    struct.pack_into("<HH", descriptor, 120, 0, recovery.PAIR_NONE)

    digest = hashlib.sha256(descriptor[:128])
    for payload in payloads:
        digest.update(payload)
    descriptor[128:160] = digest.digest()
    return bytes(descriptor)


def _fixture_bytes(*, successor: bool = True) -> bytes:
    if successor:
        source_name = b"glacier-durable-recovery-successor-v1"
        raw, packed, scale = SUCCESSOR_RAW, SUCCESSOR_PACKED, SUCCESSOR_SCALE
    else:
        source_name = b"glacier-durable-recovery-predecessor-v1"
        raw, packed, scale = PREDECESSOR_RAW, PREDECESSOR_PACKED, PREDECESSOR_SCALE

    record_0 = _encode_record(
        kind=10,
        encoding=0,
        packed_layout=recovery.PACKED_NONE,
        group_size=0,
        out_f=1,
        in_f=4,
        num_elements=4,
        ranges=(
            (0, 0),
            (0, 0),
            (0, 0),
            (0, 0),
            (recovery.GLRT_DATA_OFFSET, len(raw)),
        ),
        payloads=(raw,),
    )
    record_1 = _encode_record(
        kind=1,
        encoding=1,
        packed_layout=0,
        group_size=16,
        out_f=1,
        in_f=16,
        num_elements=16,
        ranges=(
            (896, len(packed)),
            (960, len(scale)),
            (0, 0),
            (0, 0),
            (0, 0),
        ),
        payloads=(packed, scale),
    )
    index = record_0 + record_1
    assert len(index) == 2 * recovery.GLRT_RECORD_SIZE

    encoded = bytearray(recovery.GLRT_FILE_SIZE)
    encoded[:4] = b"GLRT"
    struct.pack_into(
        "<HHHHI",
        encoded,
        4,
        2,
        recovery.GLRT_HEADER_SIZE,
        recovery.GLRT_RECORD_SIZE,
        recovery.GLRT_ALIGNMENT,
        0,
    )
    struct.pack_into(
        "<QQQQ",
        encoded,
        16,
        2,
        recovery.GLRT_INDEX_OFFSET,
        recovery.GLRT_DATA_OFFSET,
        recovery.GLRT_FILE_SIZE,
    )
    encoded[48:80] = hashlib.sha256(source_name).digest()
    encoded[80:112] = _host_abi_fingerprint()
    struct.pack_into("<7I", encoded, 112, 16, 32, 2, 64, 2, 8, 1)
    encoded[140] = 1
    struct.pack_into("<ff", encoded, 144, 1e-6, 10_000.0)
    struct.pack_into("<I", encoded, 152, zlib.crc32(index) & recovery.MAX_U32)
    header_for_crc = bytes(encoded[: recovery.GLRT_HEADER_SIZE])
    struct.pack_into(
        "<I",
        encoded,
        156,
        zlib.crc32(header_for_crc) & recovery.MAX_U32,
    )

    encoded[recovery.GLRT_INDEX_OFFSET : recovery.GLRT_DATA_OFFSET] = index
    encoded[recovery.GLRT_DATA_OFFSET : recovery.GLRT_DATA_OFFSET + len(raw)] = raw
    encoded[896 : 896 + len(packed)] = packed
    encoded[960 : 960 + len(scale)] = scale
    return bytes(encoded)


def _write_fixture(path: Path, encoded: bytes) -> None:
    path.write_bytes(encoded)
    os.chmod(path, 0o600)


class GlrtV2ParserTests(unittest.TestCase):
    def test_parse_exact_two_record_worker_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parsed = []
            for generation, successor in (
                ("predecessor", False),
                ("successor", True),
            ):
                with self.subTest(generation=generation):
                    encoded = _fixture_bytes(successor=successor)
                    self.assertEqual(len(encoded), 1024)
                    path = root / f"{generation}.glrt"
                    _write_fixture(path, encoded)
                    facts = recovery.parse_glrt_v2(path)
                    parsed.append(facts)

                    self.assertEqual(facts.container_bytes, 1024)
                    self.assertEqual(
                        facts.container_sha256,
                        hashlib.sha256(encoded).hexdigest(),
                    )
                    self.assertEqual(
                        facts.config_values,
                        (16, 32, 2, 64, 2, 8, 1),
                    )
                    self.assertTrue(facts.tie_embeddings)
                    self.assertEqual(
                        facts.abi_fingerprint,
                        _host_abi_fingerprint().hex(),
                    )
                    self.assertEqual(
                        facts.records[0].stream_lengths,
                        (0, 0, 0, 0, 16),
                    )
                    self.assertEqual(
                        (
                            facts.records[0].kind,
                            facts.records[0].encoding,
                            facts.records[0].packed_layout,
                        ),
                        (10, 0, recovery.PACKED_NONE),
                    )
                    self.assertEqual(
                        facts.records[1].stream_lengths,
                        (8, 4, 0, 0, 0),
                    )
                    self.assertEqual(
                        (
                            facts.records[1].kind,
                            facts.records[1].encoding,
                            facts.records[1].packed_layout,
                            facts.records[1].group_size,
                        ),
                        (1, 1, 0, 16),
                    )

            self.assertNotEqual(
                parsed[0].source_fingerprint,
                parsed[1].source_fingerprint,
            )
            self.assertNotEqual(
                parsed[0].container_sha256,
                parsed[1].container_sha256,
            )

    def test_parse_rejects_header_index_payload_and_padding_corruption(
        self,
    ) -> None:
        pristine = _fixture_bytes()
        mutations = (
            ("header", 200, "GLRT header CRC mismatch"),
            ("index", recovery.GLRT_INDEX_OFFSET, "GLRT index CRC mismatch"),
            ("payload", recovery.GLRT_DATA_OFFSET, "payload CRC mismatch"),
            ("padding", recovery.GLRT_DATA_OFFSET + 32, "padding is non-zero"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, offset, expected_error in mutations:
                with self.subTest(corruption=name):
                    corrupted = bytearray(pristine)
                    corrupted[offset] ^= 0x01
                    path = root / f"{name}.glrt"
                    _write_fixture(path, bytes(corrupted))
                    with self.assertRaisesRegex(
                        recovery.CampaignError,
                        expected_error,
                    ):
                        recovery.parse_glrt_v2(path)


class CanonicalJsonTests(unittest.TestCase):
    def test_decode_accepts_one_canonical_compact_object(self) -> None:
        line = b'{"schema":"fixture-v1","ok":true,"count":2}'
        self.assertEqual(
            recovery.decode_canonical_json_line(line),
            {"schema": "fixture-v1", "ok": True, "count": 2},
        )

    def test_decode_rejects_duplicate_keys(self) -> None:
        with self.assertRaisesRegex(
            recovery.CampaignError,
            "duplicate JSON key",
        ):
            recovery.decode_canonical_json_line(b'{"value":1,"value":2}')

    def test_decode_rejects_noncanonical_whitespace(self) -> None:
        lines = (
            b' {"value":1}',
            b'{"value":1} ',
            b'{"value": 1}',
            b'{"value":1}\n',
            b'{"value":1}\r',
        )
        for line in lines:
            with self.subTest(line=line):
                with self.assertRaises(recovery.CampaignError):
                    recovery.decode_canonical_json_line(line)


class CampaignConstantsTests(unittest.TestCase):
    def test_phase_partition_and_reserved_names_are_exact(self) -> None:
        self.assertEqual(len(recovery.CRASH_PHASES), 8)
        self.assertEqual(
            recovery.PRE_RENAME_PHASES,
            frozenset(recovery.CRASH_PHASES[:6]),
        )
        self.assertEqual(
            recovery.CANDIDATE_VISIBLE_PHASES,
            frozenset(
                (
                    "provider_mid_record",
                    "candidate_created",
                    "candidate_encoded",
                    "candidate_synced",
                    "candidate_validated",
                )
            ),
        )

        lock_name, candidate_name = recovery._reserved_names(
            recovery.TARGET_NAME
        )
        self.assertEqual(lock_name, recovery.LOCK_NAME)
        self.assertEqual(candidate_name, recovery.CANDIDATE_NAME)


if __name__ == "__main__":
    unittest.main()
