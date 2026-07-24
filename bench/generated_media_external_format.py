"""Independent oracle for three bounded generated-media delivery profiles.

The profiles are deliberately narrower than the underlying formats:

* PNG Third Edition, 2x2 linear gray8, one stored-DEFLATE IDAT;
* RIFF/WAVE PCM, two mono s16le frames at 16 kHz; and
* PNG Third Edition APNG, two full-canvas linear gray8 frames.

They are conformance fixtures, not general-purpose media decoders.
"""

from __future__ import annotations

import hashlib
import math
import struct
from dataclasses import dataclass
from typing import Any


class GeneratedMediaExternalFormatError(ValueError):
    """An encoded delivery does not match its canonical bounded profile."""


Record = dict[str, Any]

MAXIMUM_ENCODED_BYTES = 4096
MAXIMUM_RAW_BYTES = 4096
MAXIMUM_CHUNK_BYTES = 4096
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_GAMMA_LINEAR = 100_000
PNG_ZLIB_HEADER = b"\x78\x01"
PNG_STORED_BLOCK = 0x01

IMAGE_WIDTH = 2
IMAGE_HEIGHT = 2
IMAGE_RAW = bytes.fromhex("20303020")

AUDIO_CHANNELS = 1
AUDIO_SAMPLE_RATE = 16_000
AUDIO_BITS_PER_SAMPLE = 16
AUDIO_FRAME_COUNT = 2
AUDIO_RAW = bytes.fromhex("000100ff")

VIDEO_WIDTH = 2
VIDEO_HEIGHT = 2
VIDEO_FRAME_COUNT = 2
VIDEO_FRAME_ZERO = bytes.fromhex("03030303")
VIDEO_FRAME_ONE = bytes.fromhex("07070707")
VIDEO_TIME_BASE = (1, 1000)
VIDEO_DURATION_TICKS = (2, 3)
VIDEO_DELAYS = ((1, 500), (3, 1000))

REFERENCE_IMAGE_PNG_SHA256 = bytes.fromhex(
    "8166b7e51cc4d0ba2e88e335349ccfbaf2c016b00e2b40c41d7d3a2fff93d807"
)
REFERENCE_AUDIO_WAVE_SHA256 = bytes.fromhex(
    "e38a9a172dae97f9a9dacd5fe7644124521681eba57afb75a31613f21865955d"
)
REFERENCE_VIDEO_APNG_SHA256 = bytes.fromhex(
    "068d239d13e873d7cef7ef122fa4d189c8d06ccd4fc5f94f7ebf4dda909a7dbf"
)


@dataclass(frozen=True)
class _PngChunk:
    kind: bytes
    data: bytes
    start: int
    data_offset: int
    end: int


def _require_bytes(value: Any, where: str) -> bytes:
    if not isinstance(value, bytes):
        raise GeneratedMediaExternalFormatError(f"{where} must be immutable bytes")
    return value


def _sha256(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def crc32(value: bytes) -> int:
    """Return the PNG/IEEE CRC-32 without using a media or zlib library."""

    data = _require_bytes(value, "CRC input")
    result = 0xFFFFFFFF
    for byte in data:
        result ^= byte
        for _ in range(8):
            if result & 1:
                result = (result >> 1) ^ 0xEDB88320
            else:
                result >>= 1
    return result ^ 0xFFFFFFFF


def adler32(value: bytes) -> int:
    """Return RFC 1950 Adler-32 using the normative two-sum algorithm."""

    data = _require_bytes(value, "Adler input")
    first = 1
    second = 0
    for byte in data:
        first = (first + byte) % 65_521
        second = (second + first) % 65_521
    return (second << 16) | first


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    chunk_kind = _require_bytes(kind, "PNG chunk kind")
    chunk_data = _require_bytes(data, "PNG chunk data")
    if len(chunk_kind) != 4 or len(chunk_data) > MAXIMUM_CHUNK_BYTES:
        raise GeneratedMediaExternalFormatError("invalid PNG chunk")
    return (
        struct.pack(">I", len(chunk_data))
        + chunk_kind
        + chunk_data
        + struct.pack(">I", crc32(chunk_kind + chunk_data))
    )


def _stored_zlib(payload: bytes) -> bytes:
    raw = _require_bytes(payload, "stored-DEFLATE payload")
    if not 0 < len(raw) <= min(MAXIMUM_RAW_BYTES, 0xFFFF):
        raise GeneratedMediaExternalFormatError(
            "stored-DEFLATE payload outside profile"
        )
    return (
        PNG_ZLIB_HEADER
        + bytes((PNG_STORED_BLOCK,))
        + struct.pack("<HH", len(raw), len(raw) ^ 0xFFFF)
        + raw
        + struct.pack(">I", adler32(raw))
    )


def _decode_stored_zlib(
    encoded: bytes,
    expected_payload_bytes: int,
) -> bytes:
    stream = _require_bytes(encoded, "zlib stream")
    if (
        expected_payload_bytes <= 0
        or expected_payload_bytes > MAXIMUM_RAW_BYTES
        or len(stream) != 11 + expected_payload_bytes
        or stream[:2] != PNG_ZLIB_HEADER
        or stream[2] != PNG_STORED_BLOCK
    ):
        raise GeneratedMediaExternalFormatError("unsupported canonical zlib stream")
    length, complement = struct.unpack_from("<HH", stream, 3)
    if length != expected_payload_bytes or complement != (length ^ 0xFFFF):
        raise GeneratedMediaExternalFormatError("invalid stored-DEFLATE length")
    payload = stream[7 : 7 + length]
    if struct.unpack_from(">I", stream, 7 + length)[0] != adler32(payload):
        raise GeneratedMediaExternalFormatError("invalid stored-DEFLATE Adler-32")
    return payload


def _parse_png_chunks(encoded: bytes) -> tuple[_PngChunk, ...]:
    source = _require_bytes(encoded, "PNG source")
    if (
        len(source) < len(PNG_SIGNATURE) + 12
        or len(source) > MAXIMUM_ENCODED_BYTES
        or source[:8] != PNG_SIGNATURE
    ):
        raise GeneratedMediaExternalFormatError("invalid PNG envelope")

    chunks: list[_PngChunk] = []
    offset = len(PNG_SIGNATURE)
    while offset < len(source):
        if len(source) - offset < 12:
            raise GeneratedMediaExternalFormatError("truncated PNG chunk")
        length = struct.unpack_from(">I", source, offset)[0]
        if length > MAXIMUM_CHUNK_BYTES:
            raise GeneratedMediaExternalFormatError("PNG chunk exceeds profile")
        data_offset = offset + 8
        end = data_offset + length + 4
        if end > len(source):
            raise GeneratedMediaExternalFormatError("truncated PNG chunk data")
        kind = source[offset + 4 : offset + 8]
        data = source[data_offset : data_offset + length]
        expected_crc = struct.unpack_from(">I", source, data_offset + length)[0]
        if expected_crc != crc32(kind + data):
            raise GeneratedMediaExternalFormatError("PNG chunk CRC mismatch")
        chunks.append(
            _PngChunk(
                kind=kind,
                data=data,
                start=offset,
                data_offset=data_offset,
                end=end,
            )
        )
        offset = end
        if kind == b"IEND":
            if offset != len(source):
                raise GeneratedMediaExternalFormatError("trailing PNG bytes")
            break
    if not chunks or chunks[-1].kind != b"IEND":
        raise GeneratedMediaExternalFormatError("missing PNG IEND")
    return tuple(chunks)


def _gray8_header(width: int, height: int) -> bytes:
    return struct.pack(
        ">IIBBBBB",
        width,
        height,
        8,
        0,
        0,
        0,
        0,
    )


def _filtered_gray2x2(raw: bytes) -> bytes:
    pixels = _require_bytes(raw, "gray8 pixels")
    if len(pixels) != IMAGE_WIDTH * IMAGE_HEIGHT:
        raise GeneratedMediaExternalFormatError(
            "gray8 fixture must contain four pixels"
        )
    return b"\x00" + pixels[:2] + b"\x00" + pixels[2:]


def _unfilter_gray2x2(filtered: bytes) -> bytes:
    scanlines = _require_bytes(filtered, "filtered gray8 scanlines")
    if len(scanlines) != 6 or scanlines[0] != 0 or scanlines[3] != 0:
        raise GeneratedMediaExternalFormatError("unsupported PNG row filter")
    return scanlines[1:3] + scanlines[4:6]


def encode_image_png(raw: bytes = IMAGE_RAW) -> bytes:
    """Encode one canonical 2x2 linear-gray PNG delivery."""

    filtered = _filtered_gray2x2(raw)
    encoded = (
        PNG_SIGNATURE
        + _png_chunk(
            b"IHDR",
            _gray8_header(IMAGE_WIDTH, IMAGE_HEIGHT),
        )
        + _png_chunk(b"gAMA", struct.pack(">I", PNG_GAMMA_LINEAR))
        + _png_chunk(b"IDAT", _stored_zlib(filtered))
        + _png_chunk(b"IEND", b"")
    )
    if len(encoded) > MAXIMUM_ENCODED_BYTES:
        raise GeneratedMediaExternalFormatError("PNG output exceeds profile")
    return encoded


def decode_image_png(encoded: bytes) -> Record:
    """Decode and structurally verify the canonical PNG profile."""

    source = _require_bytes(encoded, "PNG source")
    chunks = _parse_png_chunks(source)
    if tuple(chunk.kind for chunk in chunks) != (
        b"IHDR",
        b"gAMA",
        b"IDAT",
        b"IEND",
    ):
        raise GeneratedMediaExternalFormatError("unsupported PNG chunk sequence")
    if chunks[0].data != _gray8_header(IMAGE_WIDTH, IMAGE_HEIGHT):
        raise GeneratedMediaExternalFormatError("unsupported PNG image header")
    if chunks[1].data != struct.pack(">I", PNG_GAMMA_LINEAR):
        raise GeneratedMediaExternalFormatError(
            "PNG transfer is not canonical linear gray"
        )
    if chunks[3].data:
        raise GeneratedMediaExternalFormatError("nonempty PNG IEND")

    filtered = _decode_stored_zlib(chunks[2].data, 6)
    raw = _unfilter_gray2x2(filtered)
    filtered_offset = chunks[2].data_offset + 7
    return {
        "kind": "image",
        "width": IMAGE_WIDTH,
        "height": IMAGE_HEIGHT,
        "channels": 1,
        "transfer": "linear",
        "raw": raw,
        "raw_sha256": _sha256(raw),
        "encoded_sha256": _sha256(source),
        "source_offsets": (
            filtered_offset + 1,
            filtered_offset + 2,
            filtered_offset + 4,
            filtered_offset + 5,
        ),
    }


def verify_reference_image_png(encoded: bytes) -> Record:
    """Verify the retained image bytes and their exact encoded identity."""

    result = decode_image_png(encoded)
    if (
        result["encoded_sha256"] != REFERENCE_IMAGE_PNG_SHA256
        or result["raw"] != IMAGE_RAW
    ):
        raise GeneratedMediaExternalFormatError(
            "image delivery differs from retained reference"
        )
    return result


def encode_audio_wave(raw: bytes = AUDIO_RAW) -> bytes:
    """Encode one canonical two-frame mono PCM RIFF/WAVE delivery."""

    pcm = _require_bytes(raw, "PCM payload")
    block_align = AUDIO_CHANNELS * AUDIO_BITS_PER_SAMPLE // 8
    if len(pcm) != AUDIO_FRAME_COUNT * block_align:
        raise GeneratedMediaExternalFormatError(
            "PCM payload does not match the retained frame count"
        )
    byte_rate = AUDIO_SAMPLE_RATE * block_align
    return (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVE"
        + b"fmt "
        + struct.pack(
            "<IHHIIHH",
            16,
            1,
            AUDIO_CHANNELS,
            AUDIO_SAMPLE_RATE,
            byte_rate,
            block_align,
            AUDIO_BITS_PER_SAMPLE,
        )
        + b"data"
        + struct.pack("<I", len(pcm))
        + pcm
    )


def decode_audio_wave(encoded: bytes) -> Record:
    """Decode and structurally verify the canonical RIFF/WAVE profile."""

    source = _require_bytes(encoded, "WAVE source")
    expected_bytes = 44 + len(AUDIO_RAW)
    if (
        len(source) != expected_bytes
        or len(source) > MAXIMUM_ENCODED_BYTES
        or source[:4] != b"RIFF"
        or source[8:12] != b"WAVE"
        or source[12:16] != b"fmt "
        or source[36:40] != b"data"
    ):
        raise GeneratedMediaExternalFormatError("unsupported RIFF/WAVE envelope")
    riff_bytes = struct.unpack_from("<I", source, 4)[0]
    (
        format_bytes,
        format_tag,
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
    ) = struct.unpack_from("<IHHIIHH", source, 16)
    data_bytes = struct.unpack_from("<I", source, 40)[0]
    expected_block_align = AUDIO_CHANNELS * AUDIO_BITS_PER_SAMPLE // 8
    if (
        riff_bytes != len(source) - 8
        or format_bytes != 16
        or format_tag != 1
        or channels != AUDIO_CHANNELS
        or sample_rate != AUDIO_SAMPLE_RATE
        or bits_per_sample != AUDIO_BITS_PER_SAMPLE
        or block_align != expected_block_align
        or byte_rate != AUDIO_SAMPLE_RATE * expected_block_align
        or data_bytes != len(AUDIO_RAW)
        or data_bytes % block_align != 0
        or data_bytes // block_align != AUDIO_FRAME_COUNT
    ):
        raise GeneratedMediaExternalFormatError("contradictory RIFF/WAVE fields")
    raw = source[44:]
    return {
        "kind": "audio",
        "channels": channels,
        "sample_rate": sample_rate,
        "bits_per_sample": bits_per_sample,
        "frame_count": AUDIO_FRAME_COUNT,
        "raw": raw,
        "raw_sha256": _sha256(raw),
        "encoded_sha256": _sha256(source),
        "source_offsets": (44, 46),
    }


def verify_reference_audio_wave(encoded: bytes) -> Record:
    """Verify the retained PCM bytes and their exact encoded identity."""

    result = decode_audio_wave(encoded)
    if (
        result["encoded_sha256"] != REFERENCE_AUDIO_WAVE_SHA256
        or result["raw"] != AUDIO_RAW
    ):
        raise GeneratedMediaExternalFormatError(
            "audio delivery differs from retained reference"
        )
    return result


def _frame_control(
    sequence: int,
    delay: tuple[int, int],
) -> bytes:
    numerator, denominator = delay
    if (
        sequence < 0
        or sequence > 0xFFFFFFFF
        or numerator <= 0
        or numerator > 0xFFFF
        or denominator <= 0
        or denominator > 0xFFFF
        or math.gcd(numerator, denominator) != 1
    ):
        raise GeneratedMediaExternalFormatError("non-canonical APNG frame control")
    return struct.pack(
        ">IIIIIHHBB",
        sequence,
        VIDEO_WIDTH,
        VIDEO_HEIGHT,
        0,
        0,
        numerator,
        denominator,
        0,
        0,
    )


def encode_video_apng(
    frame_zero: bytes = VIDEO_FRAME_ZERO,
    frame_one: bytes = VIDEO_FRAME_ONE,
) -> bytes:
    """Encode the canonical two-frame, exact-delay APNG delivery."""

    filtered_zero = _filtered_gray2x2(frame_zero)
    filtered_one = _filtered_gray2x2(frame_one)
    encoded = (
        PNG_SIGNATURE
        + _png_chunk(
            b"IHDR",
            _gray8_header(VIDEO_WIDTH, VIDEO_HEIGHT),
        )
        + _png_chunk(b"gAMA", struct.pack(">I", PNG_GAMMA_LINEAR))
        + _png_chunk(
            b"acTL",
            struct.pack(">II", VIDEO_FRAME_COUNT, 1),
        )
        + _png_chunk(b"fcTL", _frame_control(0, VIDEO_DELAYS[0]))
        + _png_chunk(b"IDAT", _stored_zlib(filtered_zero))
        + _png_chunk(b"fcTL", _frame_control(1, VIDEO_DELAYS[1]))
        + _png_chunk(
            b"fdAT",
            struct.pack(">I", 2) + _stored_zlib(filtered_one),
        )
        + _png_chunk(b"IEND", b"")
    )
    if len(encoded) > MAXIMUM_ENCODED_BYTES:
        raise GeneratedMediaExternalFormatError("APNG output exceeds profile")
    return encoded


def _decode_frame_control(
    encoded: bytes,
) -> tuple[int, int, int, int, int, int, int, int, int]:
    if len(encoded) != 26:
        raise GeneratedMediaExternalFormatError("invalid APNG frame-control length")
    return struct.unpack(">IIIIIHHBB", encoded)


def decode_video_apng(encoded: bytes) -> Record:
    """Decode and structurally verify the canonical APNG profile."""

    source = _require_bytes(encoded, "APNG source")
    chunks = _parse_png_chunks(source)
    if tuple(chunk.kind for chunk in chunks) != (
        b"IHDR",
        b"gAMA",
        b"acTL",
        b"fcTL",
        b"IDAT",
        b"fcTL",
        b"fdAT",
        b"IEND",
    ):
        raise GeneratedMediaExternalFormatError("unsupported APNG chunk sequence")
    if chunks[0].data != _gray8_header(VIDEO_WIDTH, VIDEO_HEIGHT):
        raise GeneratedMediaExternalFormatError("unsupported APNG image header")
    if chunks[1].data != struct.pack(">I", PNG_GAMMA_LINEAR):
        raise GeneratedMediaExternalFormatError(
            "APNG transfer is not canonical linear gray"
        )
    if chunks[2].data != struct.pack(">II", VIDEO_FRAME_COUNT, 1):
        raise GeneratedMediaExternalFormatError("unsupported APNG animation control")
    if _decode_frame_control(chunks[3].data) != (
        0,
        VIDEO_WIDTH,
        VIDEO_HEIGHT,
        0,
        0,
        *VIDEO_DELAYS[0],
        0,
        0,
    ):
        raise GeneratedMediaExternalFormatError("non-canonical first APNG frame")
    if _decode_frame_control(chunks[5].data) != (
        1,
        VIDEO_WIDTH,
        VIDEO_HEIGHT,
        0,
        0,
        *VIDEO_DELAYS[1],
        0,
        0,
    ):
        raise GeneratedMediaExternalFormatError("non-canonical second APNG frame")
    if (
        len(chunks[6].data) < 4
        or struct.unpack_from(">I", chunks[6].data, 0)[0] != 2
        or chunks[7].data
    ):
        raise GeneratedMediaExternalFormatError("invalid APNG frame-data sequence")

    filtered_zero = _decode_stored_zlib(chunks[4].data, 6)
    filtered_one = _decode_stored_zlib(chunks[6].data[4:], 6)
    frame_zero = _unfilter_gray2x2(filtered_zero)
    frame_one = _unfilter_gray2x2(filtered_one)
    first_filtered_offset = chunks[4].data_offset + 7
    second_filtered_offset = chunks[6].data_offset + 4 + 7
    raw = frame_zero + frame_one
    return {
        "kind": "video",
        "width": VIDEO_WIDTH,
        "height": VIDEO_HEIGHT,
        "channels": 1,
        "frame_count": VIDEO_FRAME_COUNT,
        "transfer": "linear",
        "time_base": VIDEO_TIME_BASE,
        "duration_ticks": VIDEO_DURATION_TICKS,
        "frame_delays": VIDEO_DELAYS,
        "frames": (frame_zero, frame_one),
        "raw": raw,
        "raw_sha256": _sha256(raw),
        "encoded_sha256": _sha256(source),
        "source_offsets": (
            (
                first_filtered_offset + 1,
                first_filtered_offset + 2,
                first_filtered_offset + 4,
                first_filtered_offset + 5,
            ),
            (
                second_filtered_offset + 1,
                second_filtered_offset + 2,
                second_filtered_offset + 4,
                second_filtered_offset + 5,
            ),
        ),
    }


def verify_reference_video_apng(encoded: bytes) -> Record:
    """Verify retained video frames and their exact encoded identity."""

    result = decode_video_apng(encoded)
    if result["encoded_sha256"] != REFERENCE_VIDEO_APNG_SHA256 or result["frames"] != (
        VIDEO_FRAME_ZERO,
        VIDEO_FRAME_ONE,
    ):
        raise GeneratedMediaExternalFormatError(
            "video delivery differs from retained reference"
        )
    return result


def reference_formats() -> Record:
    """Return independently encoded reference deliveries."""

    return {
        "image": encode_image_png(),
        "audio": encode_audio_wave(),
        "video": encode_video_apng(),
    }
