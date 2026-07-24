from __future__ import annotations

import hashlib
import io
import math
import struct
import unittest
import wave
import zlib

from bench import generated_media_external_format as external


IMAGE_PNG_HEX = (
    "89504e470d0a1a0a0000000d4948445200000002000000020800000000"
    "57dd52f80000000467414d41000186a031e8965f000000114944415478"
    "01010600f9ff00203000302001e600a1a9dbb8a00000000049454e44ae"
    "426082"
)
IMAGE_PNG_SHA256 = "8166b7e51cc4d0ba2e88e335349ccfbaf2c016b00e2b40c41d7d3a2fff93d807"

AUDIO_WAVE_HEX = (
    "524946462800000057415645666d74201000000001000100803e000000"
    "7d0000020010006461746104000000000100ff"
)
AUDIO_WAVE_SHA256 = "e38a9a172dae97f9a9dacd5fe7644124521681eba57afb75a31613f21865955d"

VIDEO_APNG_HEX = (
    "89504e470d0a1a0a0000000d4948445200000002000000020800000000"
    "57dd52f80000000467414d41000186a031e8965f000000086163544c00"
    "00000200000001848aa3e60000001a6663544c00000000000000020000"
    "00020000000000000000000101f40000efb2e5bf000000114944415478"
    "01010600f9ff000303000303002a000de203950d0000001a6663544c00"
    "00000100000002000000020000000000000000000303e80000b134ce94"
    "0000001566644154000000027801010600f9ff000707000707005a001d"
    "f128c7b70000000049454e44ae426082"
)
VIDEO_APNG_SHA256 = "068d239d13e873d7cef7ef122fa4d189c8d06ccd4fc5f94f7ebf4dda909a7dbf"

IMAGE_PNG = bytes.fromhex(IMAGE_PNG_HEX)
AUDIO_WAVE = bytes.fromhex(AUDIO_WAVE_HEX)
VIDEO_APNG = bytes.fromhex(VIDEO_APNG_HEX)


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def _chunks(encoded: bytes) -> list[tuple[bytes, bytes]]:
    result: list[tuple[bytes, bytes]] = []
    offset = len(external.PNG_SIGNATURE)
    while offset < len(encoded):
        length = struct.unpack_from(">I", encoded, offset)[0]
        kind = encoded[offset + 4 : offset + 8]
        data = encoded[offset + 8 : offset + 8 + length]
        result.append((kind, data))
        offset += 12 + length
    return result


def _rebuild_png(chunks: list[tuple[bytes, bytes]]) -> bytes:
    return external.PNG_SIGNATURE + b"".join(
        _chunk(kind, data) for kind, data in chunks
    )


def _stored(payload: bytes) -> bytes:
    return (
        b"\x78\x01\x01"
        + struct.pack("<HH", len(payload), len(payload) ^ 0xFFFF)
        + payload
        + struct.pack(">I", zlib.adler32(payload) & 0xFFFFFFFF)
    )


class GeneratedMediaExternalFormatTests(unittest.TestCase):
    def test_frozen_vectors_and_exact_mappings(self) -> None:
        references = external.reference_formats()
        expected = {
            "image": (
                IMAGE_PNG,
                IMAGE_PNG_SHA256,
                external.verify_reference_image_png,
            ),
            "audio": (
                AUDIO_WAVE,
                AUDIO_WAVE_SHA256,
                external.verify_reference_audio_wave,
            ),
            "video": (
                VIDEO_APNG,
                VIDEO_APNG_SHA256,
                external.verify_reference_video_apng,
            ),
        }
        for kind, (literal, expected_sha256, verifier) in expected.items():
            with self.subTest(kind=kind):
                self.assertEqual(references[kind], literal)
                self.assertEqual(
                    hashlib.sha256(literal).hexdigest(),
                    expected_sha256,
                )
                self.assertEqual(
                    verifier(literal)["encoded_sha256"].hex(),
                    expected_sha256,
                )

        image = external.decode_image_png(IMAGE_PNG)
        self.assertEqual(image["raw"], external.IMAGE_RAW)
        self.assertEqual(image["source_offsets"], (65, 66, 68, 69))

        audio = external.decode_audio_wave(AUDIO_WAVE)
        self.assertEqual(audio["raw"], external.AUDIO_RAW)
        self.assertEqual(audio["source_offsets"], (44, 46))

        video = external.decode_video_apng(VIDEO_APNG)
        self.assertEqual(
            video["frames"],
            (external.VIDEO_FRAME_ZERO, external.VIDEO_FRAME_ONE),
        )
        self.assertEqual(video["frame_delays"], ((1, 500), (3, 1000)))
        self.assertEqual(
            video["source_offsets"],
            ((123, 124, 126, 127), (194, 195, 197, 198)),
        )
        for numerator, denominator in video["frame_delays"]:
            self.assertEqual(math.gcd(numerator, denominator), 1)

    def test_checksums_and_standard_library_interoperability(self) -> None:
        samples = (
            b"",
            b"123456789",
            external.IMAGE_RAW,
            external.VIDEO_FRAME_ZERO + external.VIDEO_FRAME_ONE,
        )
        for sample in samples:
            with self.subTest(bytes=len(sample)):
                self.assertEqual(
                    external.crc32(sample),
                    zlib.crc32(sample) & 0xFFFFFFFF,
                )
                self.assertEqual(
                    external.adler32(sample),
                    zlib.adler32(sample) & 0xFFFFFFFF,
                )

        image_chunks = dict(_chunks(IMAGE_PNG))
        self.assertEqual(
            zlib.decompress(image_chunks[b"IDAT"]),
            b"\x00\x20\x30\x00\x30\x20",
        )

        video_chunks = _chunks(VIDEO_APNG)
        idat = next(data for kind, data in video_chunks if kind == b"IDAT")
        fdat = next(data for kind, data in video_chunks if kind == b"fdAT")
        self.assertEqual(
            zlib.decompress(idat),
            b"\x00\x03\x03\x00\x03\x03",
        )
        self.assertEqual(
            zlib.decompress(fdat[4:]),
            b"\x00\x07\x07\x00\x07\x07",
        )

        with wave.open(io.BytesIO(AUDIO_WAVE), "rb") as reader:
            self.assertEqual(reader.getnchannels(), 1)
            self.assertEqual(reader.getsampwidth(), 2)
            self.assertEqual(reader.getframerate(), 16_000)
            self.assertEqual(reader.getnframes(), 2)
            self.assertEqual(reader.readframes(2), external.AUDIO_RAW)

    def test_every_byte_mutation_rejects_retained_identity(self) -> None:
        profiles = (
            (
                "image",
                IMAGE_PNG,
                external.verify_reference_image_png,
            ),
            (
                "audio",
                AUDIO_WAVE,
                external.verify_reference_audio_wave,
            ),
            (
                "video",
                VIDEO_APNG,
                external.verify_reference_video_apng,
            ),
        )
        for kind, encoded, verifier in profiles:
            for index in range(len(encoded)):
                with self.subTest(kind=kind, mutation=index):
                    mutated = bytearray(encoded)
                    mutated[index] ^= 1
                    with self.assertRaises(external.GeneratedMediaExternalFormatError):
                        verifier(bytes(mutated))

    def test_every_truncation_and_insertion_rejects(self) -> None:
        profiles = (
            (
                "image",
                IMAGE_PNG,
                external.verify_reference_image_png,
            ),
            (
                "audio",
                AUDIO_WAVE,
                external.verify_reference_audio_wave,
            ),
            (
                "video",
                VIDEO_APNG,
                external.verify_reference_video_apng,
            ),
        )
        for kind, encoded, verifier in profiles:
            for length in range(len(encoded)):
                with self.subTest(kind=kind, truncation=length):
                    with self.assertRaises(external.GeneratedMediaExternalFormatError):
                        verifier(encoded[:length])
            for index in range(len(encoded) + 1):
                with self.subTest(kind=kind, insertion=index):
                    extended = encoded[:index] + b"\x00" + encoded[index:]
                    with self.assertRaises(external.GeneratedMediaExternalFormatError):
                        verifier(extended)

    def test_resealed_png_semantic_contradictions_reject(self) -> None:
        chunks = _chunks(IMAGE_PNG)

        geometry = list(chunks)
        geometry[0] = (
            b"IHDR",
            struct.pack(">IIBBBBB", 1, 4, 8, 0, 0, 0, 0),
        )
        geometry[2] = (
            b"IDAT",
            _stored(b"\x00\x20\x00\x30\x00\x30\x00\x20"),
        )

        transfer = list(chunks)
        transfer[1] = (b"gAMA", struct.pack(">I", 45_455))

        filter_one = list(chunks)
        filter_one[2] = (
            b"IDAT",
            _stored(b"\x01\x20\x30\x00\x30\x20"),
        )

        compressed = list(chunks)
        compressed[2] = (
            b"IDAT",
            zlib.compress(b"\x00\x20\x30\x00\x30\x20", level=9),
        )

        ancillary = list(chunks)
        ancillary.insert(2, (b"tEXt", b"foreign metadata"))

        for label, candidate in (
            ("geometry", geometry),
            ("transfer", transfer),
            ("filter", filter_one),
            ("deflate", compressed),
            ("ancillary", ancillary),
        ):
            with self.subTest(label=label):
                with self.assertRaises(external.GeneratedMediaExternalFormatError):
                    external.decode_image_png(_rebuild_png(candidate))

    def test_resealed_wave_semantic_contradictions_reject(self) -> None:
        rate = bytearray(AUDIO_WAVE)
        struct.pack_into("<I", rate, 24, 8000)
        struct.pack_into("<I", rate, 28, 16_000)

        tag = bytearray(AUDIO_WAVE)
        struct.pack_into("<H", tag, 20, 3)

        payload = bytearray(AUDIO_WAVE)
        payload[-1] ^= 1

        junk_body = AUDIO_WAVE[12:36] + b"JUNK" + struct.pack("<I", 0) + AUDIO_WAVE[36:]
        junk = b"RIFF" + struct.pack("<I", 4 + len(junk_body)) + b"WAVE" + junk_body
        with wave.open(io.BytesIO(junk), "rb") as reader:
            self.assertEqual(reader.readframes(2), external.AUDIO_RAW)

        for label, candidate, decoder in (
            ("rate", bytes(rate), external.decode_audio_wave),
            ("tag", bytes(tag), external.decode_audio_wave),
            (
                "payload",
                bytes(payload),
                external.verify_reference_audio_wave,
            ),
            ("chunk", junk, external.decode_audio_wave),
        ):
            with self.subTest(label=label):
                with self.assertRaises(external.GeneratedMediaExternalFormatError):
                    decoder(candidate)

    def test_resealed_apng_semantic_contradictions_reject(self) -> None:
        chunks = _chunks(VIDEO_APNG)

        unreduced_delay = list(chunks)
        first_control = bytearray(unreduced_delay[3][1])
        struct.pack_into(">HH", first_control, 20, 2, 1000)
        unreduced_delay[3] = (b"fcTL", bytes(first_control))

        plays_forever = list(chunks)
        plays_forever[2] = (b"acTL", struct.pack(">II", 2, 0))

        sequence_gap = list(chunks)
        second_control = bytearray(sequence_gap[5][1])
        struct.pack_into(">I", second_control, 0, 2)
        sequence_gap[5] = (b"fcTL", bytes(second_control))

        blend_over = list(chunks)
        blended = bytearray(blend_over[5][1])
        blended[-1] = 1
        blend_over[5] = (b"fcTL", bytes(blended))

        foreign_frame = list(chunks)
        foreign_frame[6] = (
            b"fdAT",
            struct.pack(">I", 2) + _stored(b"\x00\x08\x08\x00\x08\x08"),
        )

        for label, candidate, decoder in (
            (
                "unreduced-delay",
                unreduced_delay,
                external.decode_video_apng,
            ),
            ("plays", plays_forever, external.decode_video_apng),
            ("sequence", sequence_gap, external.decode_video_apng),
            ("blend", blend_over, external.decode_video_apng),
            (
                "frame",
                foreign_frame,
                external.verify_reference_video_apng,
            ),
        ):
            with self.subTest(label=label):
                with self.assertRaises(external.GeneratedMediaExternalFormatError):
                    decoder(_rebuild_png(candidate))

    def test_cross_profile_substitution_and_input_types_reject(self) -> None:
        substitutions = (
            (external.verify_reference_image_png, AUDIO_WAVE),
            (external.verify_reference_image_png, VIDEO_APNG),
            (external.verify_reference_audio_wave, IMAGE_PNG),
            (external.verify_reference_audio_wave, VIDEO_APNG),
            (external.verify_reference_video_apng, IMAGE_PNG),
            (external.verify_reference_video_apng, AUDIO_WAVE),
        )
        for verifier, encoded in substitutions:
            with self.subTest(
                verifier=verifier.__name__,
                bytes=len(encoded),
            ):
                with self.assertRaises(external.GeneratedMediaExternalFormatError):
                    verifier(encoded)

        for decoder in (
            external.decode_image_png,
            external.decode_audio_wave,
            external.decode_video_apng,
        ):
            with self.subTest(decoder=decoder.__name__):
                with self.assertRaises(external.GeneratedMediaExternalFormatError):
                    decoder(bytearray(b"not immutable bytes"))

    def test_profile_round_trip_keeps_reference_identity_separate(self) -> None:
        foreign_image_raw = bytes.fromhex("01020304")
        foreign_image = external.encode_image_png(foreign_image_raw)
        self.assertEqual(
            external.decode_image_png(foreign_image)["raw"],
            foreign_image_raw,
        )

        foreign_audio_raw = bytes.fromhex("04030201")
        foreign_audio = external.encode_audio_wave(foreign_audio_raw)
        self.assertEqual(
            external.decode_audio_wave(foreign_audio)["raw"],
            foreign_audio_raw,
        )

        foreign_frame_zero = bytes.fromhex("01010101")
        foreign_frame_one = bytes.fromhex("02020202")
        foreign_video = external.encode_video_apng(
            foreign_frame_zero,
            foreign_frame_one,
        )
        self.assertEqual(
            external.decode_video_apng(foreign_video)["frames"],
            (foreign_frame_zero, foreign_frame_one),
        )

        for verifier, encoded in (
            (external.verify_reference_image_png, foreign_image),
            (external.verify_reference_audio_wave, foreign_audio),
            (external.verify_reference_video_apng, foreign_video),
        ):
            with self.subTest(verifier=verifier.__name__):
                with self.assertRaises(external.GeneratedMediaExternalFormatError):
                    verifier(encoded)


if __name__ == "__main__":
    unittest.main()
