"""Independent oracle for atomic multimodal stream checkpoint sets."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import continuation_checkpoint_file as archive
from bench import media_contract as media
from bench import media_processor_state as processor
from bench import media_stream_continuation as continuation


class MediaStreamCheckpointSetError(ValueError):
    """A retained-output bundle or multimodal generation is invalid."""


Record = dict[str, Any]
BUNDLE_ABI = 0x474D534200000001
BUNDLE_MAGIC = b"GMSBND1\x00"
STREAM_COUNT = 3
MAXIMUM_OUTPUTS = (
    STREAM_COUNT * continuation.MAXIMUM_RETAINED_OUTPUTS
)
BUNDLE_HEADER_BYTES = 192
BUNDLE_ENTRY_BYTES = 96
BUNDLE_DIRECTORY_BYTES = MAXIMUM_OUTPUTS * BUNDLE_ENTRY_BYTES
BUNDLE_PAYLOAD_OFFSET = BUNDLE_HEADER_BYTES + BUNDLE_DIRECTORY_BYTES
BUNDLE_FOOTER_BYTES = 32
ARCHIVE_OBJECT_COUNT = STREAM_COUNT + 1
STATEFUL_ARCHIVE_OBJECT_COUNT = ARCHIVE_OBJECT_COUNT + 1
CHECKPOINT_OBJECT_ABI = continuation.CHECKPOINT_ABI
BUNDLE_OBJECT_ABI = BUNDLE_ABI
PROCESSOR_OBJECT_ABI = processor.PROCESSOR_BUNDLE_ABI
EXTENSION_OBJECT_KIND = 7
ALLOWED_FLAGS = 0
ZERO_DIGEST = bytes(32)
BUNDLE_DOMAIN = b"glacier-media-stream-output-bundle-v1\x00"
U64_MAX = (1 << 64) - 1
KINDS = (media.IMAGE, media.AUDIO, media.VIDEO)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaStreamCheckpointSetError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if (
        not isinstance(value, bytes)
        or len(value) != 32
        or (not allow_zero and value == ZERO_DIGEST)
    ):
        raise MediaStreamCheckpointSetError("invalid digest")
    return value


def _hash(domain: bytes, data: bytes) -> bytes:
    return hashlib.sha256(domain + data).digest()


def bundle_root(body: bytes) -> bytes:
    if not isinstance(body, bytes):
        raise MediaStreamCheckpointSetError("invalid bundle body")
    return _hash(BUNDLE_DOMAIN, body)


def encode_bundle(plan: Record, streams: list[Record]) -> bytes:
    try:
        generation = plan["generation"]
        request_epoch = plan["request_epoch"]
        challenge = _digest(plan["challenge_sha256"])
    except (KeyError, TypeError):
        raise MediaStreamCheckpointSetError("invalid bundle plan") from None
    _u64(generation)
    _u64(request_epoch)
    if generation == 0 or request_epoch == 0 or len(streams) != STREAM_COUNT:
        raise MediaStreamCheckpointSetError("invalid bundle plan")

    checked: list[Record] = []
    total_payload = 0
    output_count = 0
    for stream_index, stream in enumerate(streams):
        try:
            kind = stream["kind"]
            checkpoint_sha256 = _digest(stream["checkpoint_sha256"])
            outputs = stream["outputs"]
        except (KeyError, TypeError):
            raise MediaStreamCheckpointSetError(
                "invalid bundle stream"
            ) from None
        if (
            kind != KINDS[stream_index]
            or not isinstance(outputs, list)
            or not 0 < len(outputs)
            <= continuation.MAXIMUM_RETAINED_OUTPUTS
        ):
            raise MediaStreamCheckpointSetError("invalid bundle stream")
        checked_outputs: list[Record] = []
        for chunk_index, entry in enumerate(outputs):
            try:
                output = entry["output"]
                output_sha256 = _digest(entry["output_sha256"])
                chunk_receipt_sha256 = _digest(
                    entry["chunk_receipt_sha256"]
                )
                encoded_chunk_index = entry["chunk_index"]
            except (KeyError, TypeError):
                raise MediaStreamCheckpointSetError(
                    "invalid bundle output"
                ) from None
            _u64(encoded_chunk_index)
            if (
                encoded_chunk_index != chunk_index
                or not isinstance(output, bytes)
                or not output
                or hashlib.sha256(output).digest() != output_sha256
            ):
                raise MediaStreamCheckpointSetError(
                    "invalid bundle output"
                )
            checked_outputs.append(
                {
                    "chunk_index": encoded_chunk_index,
                    "output": output,
                    "output_sha256": output_sha256,
                    "chunk_receipt_sha256": chunk_receipt_sha256,
                }
            )
            output_count += 1
            total_payload += len(output)
        checked.append(
            {
                "kind": kind,
                "checkpoint_sha256": checkpoint_sha256,
                "outputs": checked_outputs,
            }
        )
    if not 0 < output_count <= MAXIMUM_OUTPUTS:
        raise MediaStreamCheckpointSetError("invalid output count")

    total = (
        BUNDLE_PAYLOAD_OFFSET + total_payload + BUNDLE_FOOTER_BYTES
    )
    output = bytearray(total)
    output[:64] = b"".join(
        (
            BUNDLE_MAGIC,
            _u64(BUNDLE_ABI),
            _u64(total),
            _u64(generation),
            _u64(request_epoch),
            _u64(STREAM_COUNT),
            _u64(output_count),
            _u64(ALLOWED_FLAGS),
        )
    )
    output[64:96] = challenge
    for stream_index, stream in enumerate(checked):
        start = 96 + stream_index * 32
        output[start : start + 32] = stream["checkpoint_sha256"]

    directory_index = 0
    cursor = BUNDLE_PAYLOAD_OFFSET
    for stream in checked:
        for entry in stream["outputs"]:
            offset = BUNDLE_HEADER_BYTES + directory_index * BUNDLE_ENTRY_BYTES
            payload = entry["output"]
            output[offset : offset + BUNDLE_ENTRY_BYTES] = b"".join(
                (
                    _u64(stream["kind"]),
                    _u64(entry["chunk_index"]),
                    _u64(cursor),
                    _u64(len(payload)),
                    entry["output_sha256"],
                    entry["chunk_receipt_sha256"],
                )
            )
            end = cursor + len(payload)
            output[cursor:end] = payload
            cursor = end
            directory_index += 1
    output[-BUNDLE_FOOTER_BYTES:] = bundle_root(
        bytes(output[:-BUNDLE_FOOTER_BYTES])
    )
    encoded = bytes(output)
    decode_bundle(encoded)
    return encoded


def decode_bundle(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) < BUNDLE_PAYLOAD_OFFSET + BUNDLE_FOOTER_BYTES
        or encoded[:8] != BUNDLE_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != BUNDLE_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != len(encoded)
        or struct.unpack_from("<Q", encoded, 40)[0] != STREAM_COUNT
        or struct.unpack_from("<Q", encoded, 56)[0] != ALLOWED_FLAGS
        or encoded[-32:] != bundle_root(encoded[:-32])
    ):
        raise MediaStreamCheckpointSetError("invalid bundle")
    generation, request_epoch, output_count = (
        struct.unpack_from("<Q", encoded, offset)[0]
        for offset in (24, 32, 48)
    )
    challenge = _digest(encoded[64:96])
    if (
        generation == 0
        or request_epoch == 0
        or not STREAM_COUNT <= output_count <= MAXIMUM_OUTPUTS
    ):
        raise MediaStreamCheckpointSetError("invalid bundle metadata")
    checkpoint_roots = [
        _digest(encoded[96 + index * 32 : 128 + index * 32])
        for index in range(STREAM_COUNT)
    ]
    inactive_start = (
        BUNDLE_HEADER_BYTES + output_count * BUNDLE_ENTRY_BYTES
    )
    if any(encoded[inactive_start:BUNDLE_PAYLOAD_OFFSET]):
        raise MediaStreamCheckpointSetError("nonzero bundle directory")

    outputs: list[Record] = []
    cursor = BUNDLE_PAYLOAD_OFFSET
    previous_kind: int | None = None
    previous_chunk_index = 0
    seen_streams = 0
    for index in range(output_count):
        offset = BUNDLE_HEADER_BYTES + index * BUNDLE_ENTRY_BYTES
        kind, chunk_index, payload_offset, payload_bytes = struct.unpack_from(
            "<QQQQ", encoded, offset
        )
        output_sha256 = _digest(encoded[offset + 32 : offset + 64])
        chunk_receipt_sha256 = _digest(
            encoded[offset + 64 : offset + 96]
        )
        end = cursor + payload_bytes
        if (
            kind not in KINDS
            or payload_bytes == 0
            or payload_offset != cursor
            or end > len(encoded) - BUNDLE_FOOTER_BYTES
        ):
            raise MediaStreamCheckpointSetError("invalid bundle entry")
        if previous_kind is None:
            if kind != media.IMAGE or chunk_index != 0:
                raise MediaStreamCheckpointSetError(
                    "non-canonical bundle order"
                )
            seen_streams = 1
        elif (
            kind < previous_kind
            or kind == previous_kind
            and chunk_index != previous_chunk_index + 1
            or kind > previous_kind
            and (kind != previous_kind + 1 or chunk_index != 0)
        ):
            raise MediaStreamCheckpointSetError(
                "non-canonical bundle order"
            )
        elif kind > previous_kind:
            seen_streams += 1
        payload = encoded[cursor:end]
        if hashlib.sha256(payload).digest() != output_sha256:
            raise MediaStreamCheckpointSetError("bundle output mismatch")
        outputs.append(
            {
                "kind": kind,
                "chunk_index": chunk_index,
                "output": payload,
                "output_sha256": output_sha256,
                "chunk_receipt_sha256": chunk_receipt_sha256,
            }
        )
        previous_kind = kind
        previous_chunk_index = chunk_index
        cursor = end
    if (
        seen_streams != STREAM_COUNT
        or previous_kind != media.VIDEO
        or cursor != len(encoded) - BUNDLE_FOOTER_BYTES
    ):
        raise MediaStreamCheckpointSetError("incomplete bundle")
    return {
        "generation": generation,
        "request_epoch": request_epoch,
        "challenge_sha256": challenge,
        "checkpoint_sha256": checkpoint_roots,
        "outputs": outputs,
        "bundle_sha256": encoded[-32:],
    }


def encode_set(
    streams: list[Record],
    parent_archive_sha256: bytes,
) -> bytes:
    return _encode_set(streams, parent_archive_sha256, None)


def encode_stateful_set(
    streams: list[Record],
    processor_states: list[Record],
    sync: Record,
    parent_archive_sha256: bytes,
) -> bytes:
    processor_bundle = processor.encode_bundle(
        processor_states,
        sync,
    )
    return _encode_set(
        streams,
        parent_archive_sha256,
        processor_bundle,
    )


def _encode_set(
    streams: list[Record],
    parent_archive_sha256: bytes,
    processor_bundle: bytes | None,
) -> bytes:
    if len(streams) != STREAM_COUNT:
        raise MediaStreamCheckpointSetError("invalid stream count")
    parent = _digest(parent_archive_sha256, allow_zero=True)
    checkpoints: list[Record] = []
    checkpoint_wires: list[bytes] = []
    bundle_streams: list[Record] = []
    for stream_index, stream in enumerate(streams):
        try:
            checkpoint = continuation.decode_checkpoint(
                continuation.encode_checkpoint(stream["checkpoint"])
            )
            retained_outputs = stream["retained_outputs"]
        except (KeyError, TypeError):
            raise MediaStreamCheckpointSetError(
                "invalid stream input"
            ) from None
        if (
            checkpoint["kind"] != KINDS[stream_index]
            or not isinstance(retained_outputs, list)
        ):
            raise MediaStreamCheckpointSetError("invalid stream input")
        continuation.verify_materialized_outputs(
            checkpoint, retained_outputs
        )
        if any(
            checkpoint["stream_key"] == prior["stream_key"]
            or checkpoint["restore_bank_epoch"]
            == prior["restore_bank_epoch"]
            for prior in checkpoints
        ):
            raise MediaStreamCheckpointSetError(
                "duplicate stream identity"
            )
        checkpoints.append(checkpoint)
        checkpoint_wires.append(continuation.encode_checkpoint(checkpoint))
        bundle_streams.append(
            {
                "kind": checkpoint["kind"],
                "checkpoint_sha256": checkpoint["checkpoint_sha256"],
                "outputs": [
                    {
                        "chunk_index": index,
                        "output": output,
                        "output_sha256": checkpoint["entries"][index][
                            "output_sha256"
                        ],
                        "chunk_receipt_sha256": checkpoint["entries"][
                            index
                        ]["chunk_receipt_sha256"],
                    }
                    for index, output in enumerate(retained_outputs)
                ],
            }
        )
    first = checkpoints[0]
    if any(
        checkpoint["checkpoint_generation"]
        != first["checkpoint_generation"]
        or checkpoint["request_epoch"] != first["request_epoch"]
        or checkpoint["next_sequence"] != first["next_sequence"]
        or checkpoint["challenge_sha256"] != first["challenge_sha256"]
        for checkpoint in checkpoints[1:]
    ):
        raise MediaStreamCheckpointSetError("stream metadata mismatch")
    generation = first["checkpoint_generation"]
    if generation == 1 and parent != ZERO_DIGEST or (
        generation > 1 and parent == ZERO_DIGEST
    ):
        raise MediaStreamCheckpointSetError("archive lineage mismatch")
    bundle = encode_bundle(
        {
            "generation": generation,
            "request_epoch": first["request_epoch"],
            "challenge_sha256": first["challenge_sha256"],
        },
        bundle_streams,
    )
    objects = [
        {
            "kind": EXTENSION_OBJECT_KIND,
            "ordinal": index,
            "abi_version": CHECKPOINT_OBJECT_ABI,
            "bytes": checkpoint_wires[index],
        }
        for index in range(STREAM_COUNT)
    ]
    objects.append(
        {
            "kind": EXTENSION_OBJECT_KIND,
            "ordinal": STREAM_COUNT,
            "abi_version": BUNDLE_OBJECT_ABI,
            "bytes": bundle,
        }
    )
    if processor_bundle is not None:
        processor.decode_bundle(processor_bundle)
        objects.append(
            {
                "kind": EXTENSION_OBJECT_KIND,
                "ordinal": ARCHIVE_OBJECT_COUNT,
                "abi_version": PROCESSOR_OBJECT_ABI,
                "bytes": processor_bundle,
            }
        )
    encoded = archive.encode_set(
        {
            "generation": generation,
            "request_epoch": first["request_epoch"],
            "publication_next_sequence": first["next_sequence"],
            "parent_checkpoint_sha256": parent,
            "challenge_sha256": first["challenge_sha256"],
        },
        objects,
    )
    if processor_bundle is None:
        decode_set(encoded)
    else:
        decode_stateful_set(encoded)
    return encoded


def decode_set(encoded: bytes) -> Record:
    return _decode_set(encoded, ARCHIVE_OBJECT_COUNT)


def decode_compatible_set(encoded: bytes) -> Record:
    decoded_archive = archive.decode_set(encoded)
    object_count = len(decoded_archive["objects"])
    if object_count not in (
        ARCHIVE_OBJECT_COUNT,
        STATEFUL_ARCHIVE_OBJECT_COUNT,
    ):
        raise MediaStreamCheckpointSetError(
            "invalid archive object count"
        )
    return _decode_set(encoded, object_count)


def decode_stateful_set(encoded: bytes) -> Record:
    result = _decode_set(encoded, STATEFUL_ARCHIVE_OBJECT_COUNT)
    object_entry = result["archive"]["objects"][
        ARCHIVE_OBJECT_COUNT
    ]
    if (
        object_entry["kind"] != EXTENSION_OBJECT_KIND
        or object_entry["ordinal"] != ARCHIVE_OBJECT_COUNT
        or object_entry["abi_version"] != PROCESSOR_OBJECT_ABI
    ):
        raise MediaStreamCheckpointSetError(
            "invalid processor object"
        )
    try:
        bundle = processor.decode_bundle(object_entry["bytes"])
    except processor.MediaProcessorStateError:
        raise MediaStreamCheckpointSetError(
            "invalid processor bundle"
        ) from None
    _validate_processor_binding(result, bundle)
    result["processor_bundle"] = bundle
    return result


def _decode_set(encoded: bytes, expected_object_count: int) -> Record:
    decoded_archive = archive.decode_set(encoded)
    objects = decoded_archive["objects"]
    if len(objects) != expected_object_count:
        raise MediaStreamCheckpointSetError("invalid archive object count")
    checkpoints: list[Record] = []
    for index in range(STREAM_COUNT):
        entry = objects[index]
        if (
            entry["kind"] != EXTENSION_OBJECT_KIND
            or entry["ordinal"] != index
            or entry["abi_version"] != CHECKPOINT_OBJECT_ABI
        ):
            raise MediaStreamCheckpointSetError(
                "invalid checkpoint object"
            )
        checkpoint = continuation.decode_checkpoint(entry["bytes"])
        metadata = decoded_archive["metadata"]
        if (
            checkpoint["kind"] != KINDS[index]
            or checkpoint["checkpoint_generation"]
            != metadata["generation"]
            or checkpoint["request_epoch"] != metadata["request_epoch"]
            or checkpoint["next_sequence"]
            != metadata["publication_next_sequence"]
            or checkpoint["challenge_sha256"]
            != metadata["challenge_sha256"]
        ):
            raise MediaStreamCheckpointSetError(
                "checkpoint metadata mismatch"
            )
        if any(
            checkpoint["stream_key"] == prior["stream_key"]
            or checkpoint["restore_bank_epoch"]
            == prior["restore_bank_epoch"]
            for prior in checkpoints
        ):
            raise MediaStreamCheckpointSetError(
                "duplicate stream identity"
            )
        checkpoints.append(checkpoint)
    bundle_object = objects[STREAM_COUNT]
    if (
        bundle_object["kind"] != EXTENSION_OBJECT_KIND
        or bundle_object["ordinal"] != STREAM_COUNT
        or bundle_object["abi_version"] != BUNDLE_OBJECT_ABI
    ):
        raise MediaStreamCheckpointSetError("invalid bundle object")
    bundle = decode_bundle(bundle_object["bytes"])
    metadata = decoded_archive["metadata"]
    if (
        bundle["generation"] != metadata["generation"]
        or bundle["request_epoch"] != metadata["request_epoch"]
        or bundle["challenge_sha256"] != metadata["challenge_sha256"]
    ):
        raise MediaStreamCheckpointSetError("bundle metadata mismatch")
    expected_outputs = 0
    for stream_index, checkpoint in enumerate(checkpoints):
        if (
            bundle["checkpoint_sha256"][stream_index]
            != checkpoint["checkpoint_sha256"]
        ):
            raise MediaStreamCheckpointSetError(
                "checkpoint root mismatch"
            )
        stream_outputs = [
            entry
            for entry in bundle["outputs"]
            if entry["kind"] == checkpoint["kind"]
        ]
        if len(stream_outputs) != len(checkpoint["entries"]):
            raise MediaStreamCheckpointSetError("output count mismatch")
        for entry, output in zip(checkpoint["entries"], stream_outputs):
            if (
                output["chunk_index"] != entry["chunk_index"]
                or len(output["output"]) != entry["output_bytes"]
                or output["output_sha256"] != entry["output_sha256"]
                or output["chunk_receipt_sha256"]
                != entry["chunk_receipt_sha256"]
            ):
                raise MediaStreamCheckpointSetError(
                    "checkpoint output mismatch"
                )
        expected_outputs += len(stream_outputs)
    if expected_outputs != len(bundle["outputs"]):
        raise MediaStreamCheckpointSetError("foreign bundle output")
    return {
        "archive": decoded_archive,
        "checkpoints": checkpoints,
        "bundle": bundle,
    }


def _validate_processor_binding(
    media_set: Record,
    processor_bundle: Record,
) -> None:
    metadata = media_set["archive"]["metadata"]
    sync = processor_bundle["sync"]
    if (
        sync["generation"] != metadata["generation"]
        or sync["request_epoch"] != metadata["request_epoch"]
        or sync["challenge_sha256"] != metadata["challenge_sha256"]
    ):
        raise MediaStreamCheckpointSetError(
            "processor metadata mismatch"
        )
    for checkpoint, state in zip(
        media_set["checkpoints"],
        processor_bundle["states"],
    ):
        if (
            state["kind"] != checkpoint["kind"]
            or state["generation"]
            != checkpoint["checkpoint_generation"]
            or state["request_epoch"] != checkpoint["request_epoch"]
            or state["stream_key"] != checkpoint["stream_key"]
            or state["media_object_sha256"]
            != checkpoint["media_object_sha256"]
            or state["challenge_sha256"]
            != checkpoint["challenge_sha256"]
            or state["output_chain_sha256"]
            != checkpoint["last_chunk_sha256"]
            or state["ownership_receipt_sha256"]
            != checkpoint["retained_manifest_sha256"]
        ):
            raise MediaStreamCheckpointSetError(
                "processor checkpoint mismatch"
            )


def validate_successor(previous: Record, successor: Record) -> None:
    prior = decode_compatible_set(
        archive.encode_set(
            previous["archive"]["metadata"],
            previous["archive"]["objects"],
        )
    )
    next_set = decode_compatible_set(
        archive.encode_set(
            successor["archive"]["metadata"],
            successor["archive"]["objects"],
        )
    )
    prior_metadata = prior["archive"]["metadata"]
    next_metadata = next_set["archive"]["metadata"]
    if (
        next_metadata["generation"] != prior_metadata["generation"] + 1
        or next_metadata["request_epoch"] != prior_metadata["request_epoch"]
        or next_metadata["publication_next_sequence"]
        != prior_metadata["publication_next_sequence"] + 1
        or next_metadata["parent_checkpoint_sha256"]
        != prior["archive"]["checkpoint_sha256"]
        or next_metadata["challenge_sha256"]
        != prior_metadata["challenge_sha256"]
    ):
        raise MediaStreamCheckpointSetError("invalid successor metadata")
    for stream_index, (old, new) in enumerate(
        zip(prior["checkpoints"], next_set["checkpoints"])
    ):
        if (
            new["kind"] != old["kind"]
            or new["stream_key"] != old["stream_key"]
            or new["request_epoch"] != old["request_epoch"]
            or new["chunk_limit"] != old["chunk_limit"]
            or new["tenant_key"] != old["tenant_key"]
            or new["committed_chunks"] != old["committed_chunks"] + 1
            or new["visible_chunks"] != old["visible_chunks"] + 1
            or new["next_sequence"] != old["next_sequence"] + 1
            or new["visible_units"] <= old["visible_units"]
            or new["timeline_numerator"] != old["timeline_numerator"]
            or new["timeline_denominator"] != old["timeline_denominator"]
            or new["media_object_sha256"] != old["media_object_sha256"]
            or new["timeline_sha256"] == old["timeline_sha256"]
            or new["previous_commit_sha256"]
            == old["previous_commit_sha256"]
            or new["previous_checkpoint_sha256"]
            != old["checkpoint_sha256"]
        ):
            raise MediaStreamCheckpointSetError(
                "invalid stream successor"
            )
        for chunk_index, old_entry in enumerate(old["entries"]):
            new_entry = new["entries"][chunk_index]
            for field in (
                "chunk_index",
                "publication_sequence",
                "output_bytes",
                "output_sha256",
                "chunk_receipt_sha256",
            ):
                if new_entry[field] != old_entry[field]:
                    raise MediaStreamCheckpointSetError(
                        "rewritten retained entry"
                    )
            old_output = _output(prior, stream_index, chunk_index)
            new_output = _output(next_set, stream_index, chunk_index)
            if old_output != new_output:
                raise MediaStreamCheckpointSetError(
                    "rewritten retained output"
                )


def validate_restored_successor(
    previous: Record,
    successor: Record,
) -> None:
    validate_successor(previous, successor)
    prior = decode_compatible_set(
        archive.encode_set(
            previous["archive"]["metadata"],
            previous["archive"]["objects"],
        )
    )
    next_set = decode_compatible_set(
        archive.encode_set(
            successor["archive"]["metadata"],
            successor["archive"]["objects"],
        )
    )
    for old, new in zip(
        prior["checkpoints"],
        next_set["checkpoints"],
    ):
        if new["restore_bank_epoch"] == old["restore_bank_epoch"]:
            raise MediaStreamCheckpointSetError(
                "reused restore bank epoch"
            )
        for index, entry in enumerate(new["entries"]):
            if entry["source_bank_epoch"] != old["restore_bank_epoch"]:
                raise MediaStreamCheckpointSetError(
                    "foreign restored authority"
                )
            if index < len(old["entries"]):
                prior_entry = old["entries"][index]
                expected_root = (
                    continuation.restored_ownership_receipt_root(
                        old["checkpoint_sha256"],
                        prior_entry,
                        entry,
                    )
                )
                if (
                    entry["source_owner_key"]
                    != prior_entry["restore_owner_key"]
                    or entry["publication_next_sequence"]
                    != prior_entry["publication_next_sequence"]
                    or entry["parent_claim"]
                    != prior_entry["parent_claim"]
                    or entry["output_claim"]
                    != prior_entry["output_claim"]
                    or entry["lease_receipt_sha256"] != expected_root
                ):
                    raise MediaStreamCheckpointSetError(
                        "invalid restored ownership rebind"
                    )
            elif entry["source_owner_key"] != old["next_owner_key_base"]:
                raise MediaStreamCheckpointSetError(
                    "invalid resumed output owner"
                )


def validate_stateful_successor(
    previous: Record,
    successor: Record,
) -> None:
    prior = decode_stateful_set(
        archive.encode_set(
            previous["archive"]["metadata"],
            previous["archive"]["objects"],
        )
    )
    next_set = decode_stateful_set(
        archive.encode_set(
            successor["archive"]["metadata"],
            successor["archive"]["objects"],
        )
    )
    validate_successor(prior, next_set)
    try:
        processor.validate_successor(
            prior["processor_bundle"],
            next_set["processor_bundle"],
        )
    except processor.MediaProcessorStateError:
        raise MediaStreamCheckpointSetError(
            "invalid processor successor"
        ) from None


def validate_restored_stateful_successor(
    previous: Record,
    successor: Record,
) -> None:
    prior = decode_stateful_set(
        archive.encode_set(
            previous["archive"]["metadata"],
            previous["archive"]["objects"],
        )
    )
    next_set = decode_stateful_set(
        archive.encode_set(
            successor["archive"]["metadata"],
            successor["archive"]["objects"],
        )
    )
    validate_restored_successor(prior, next_set)
    try:
        processor.validate_successor(
            prior["processor_bundle"],
            next_set["processor_bundle"],
        )
    except processor.MediaProcessorStateError:
        raise MediaStreamCheckpointSetError(
            "invalid processor successor"
        ) from None


def _output(value: Record, stream_index: int, chunk_index: int) -> bytes:
    kind = KINDS[stream_index]
    for entry in value["bundle"]["outputs"]:
        if entry["kind"] == kind and entry["chunk_index"] == chunk_index:
            return entry["output"]
    raise MediaStreamCheckpointSetError("missing retained output")
