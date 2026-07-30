"""Independent oracle and subprocess contract for the provider inspector.

Outer-only inspection preserves the fixed framing boundary.  The optional
composed mode must replay every explicitly supplied nested artifact before it
may promote the same scalar/root document to composition-verified.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
from typing import Any

if __package__:
    from . import provider_cost_journal as cost_journal
    from . import provider_evidence_join_wire as join_wire
else:
    import provider_cost_journal as cost_journal
    import provider_evidence_join_wire as join_wire


Record = dict[str, Any]

SCHEMA = "glacier.provider-evidence-inspector/v1"
MAGIC = b"GPJOINR1"
WIRE_ABI = 0x47504A4F00000001
WIRE_BYTES = 712
FLAG_REQUIRE_CLOSED = 1
MAXIMUM_NESTED_WIRE_BYTES = 8 * 1024 * 1024
ENVELOPE_DOMAIN = b"glacier-provider-evidence-join-wire-v1\x00"

ROOT_FIELDS = (
    "journal_header_sha256",
    "journal_previous_chain_sha256",
    "journal_entry_sha256",
    "cost_envelope_sha256",
    "settlement_envelope_sha256",
    "request_sha256",
    "dispatch_key_sha256",
    "intent_sha256",
    "receipt_sha256",
    "price_sha256",
    "quote_sha256",
    "cost_settlement_sha256",
    "gateway_envelope_sha256",
    "gateway_event_sha256",
    "gateway_final_chain_sha256",
    "transport_envelope_sha256",
    "provider_request_sha256",
    "response_chain_sha256",
    "transport_outcome_sha256",
    "envelope_sha256",
)

TOP_FIELDS = (
    "schema",
    "wire_abi",
    "wire_bytes",
    "outer_envelope_verified",
    "composition_verified",
    "authority_granted",
    "journal_sequence",
    "gateway_event_index",
    "transport_event_count",
    "journal_frame_bytes",
    "gateway_wire_bytes",
    "transport_wire_bytes",
    "roots",
)


class ProviderEvidenceInspectorError(ValueError):
    """The outer join envelope or rendered document is not canonical."""


def _envelope_sha256(prefix: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(ENVELOPE_DOMAIN)
    hasher.update(prefix)
    return hasher.digest()


def decode_outer(encoded: bytes) -> Record:
    """Verify only fixed framing, flags, cursor position, and the outer SHA-256."""

    if type(encoded) is not bytes or len(encoded) != WIRE_BYTES:
        raise ProviderEvidenceInspectorError("invalid join length")
    if encoded[:8] != MAGIC:
        raise ProviderEvidenceInspectorError("invalid join magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != WIRE_ABI:
        raise ProviderEvidenceInspectorError("invalid join ABI")
    if struct.unpack_from("<Q", encoded, 16)[0] != WIRE_BYTES:
        raise ProviderEvidenceInspectorError("invalid declared join length")
    if struct.unpack_from("<I", encoded, 24)[0] != FLAG_REQUIRE_CLOSED:
        raise ProviderEvidenceInspectorError("invalid join flags")
    if struct.unpack_from("<I", encoded, 28)[0] != 0:
        raise ProviderEvidenceInspectorError("nonzero reserved field")

    value: Record = {
        "journal_sequence": struct.unpack_from("<Q", encoded, 32)[0],
        "gateway_event_index": struct.unpack_from("<I", encoded, 40)[0],
        "transport_event_count": struct.unpack_from("<I", encoded, 44)[0],
        "journal_frame_bytes": struct.unpack_from("<Q", encoded, 48)[0],
        "gateway_wire_bytes": struct.unpack_from("<Q", encoded, 56)[0],
        "transport_wire_bytes": struct.unpack_from("<Q", encoded, 64)[0],
    }
    cursor = 72
    for name in ROOT_FIELDS[:-1]:
        value[name] = encoded[cursor : cursor + 32]
        cursor += 32
    value["envelope_sha256"] = encoded[cursor : cursor + 32]
    cursor += 32
    if cursor != len(encoded):
        raise ProviderEvidenceInspectorError("outer cursor drift")
    if value["envelope_sha256"] != _envelope_sha256(encoded[:-32]):
        raise ProviderEvidenceInspectorError("outer envelope digest mismatch")
    return value


def expected_document(
    encoded: bytes,
    *,
    composition_verified: bool = False,
) -> Record:
    """Build the exact field-ordered document for one inspected join."""

    if type(composition_verified) is not bool:
        raise ProviderEvidenceInspectorError("invalid composition claim")
    value = decode_outer(encoded)
    document: Record = {
        "schema": SCHEMA,
        "wire_abi": f"{WIRE_ABI:016x}",
        "wire_bytes": WIRE_BYTES,
        "outer_envelope_verified": True,
        "composition_verified": composition_verified,
        "authority_granted": False,
        "journal_sequence": value["journal_sequence"],
        "gateway_event_index": value["gateway_event_index"],
        "transport_event_count": value["transport_event_count"],
        "journal_frame_bytes": value["journal_frame_bytes"],
        "gateway_wire_bytes": value["gateway_wire_bytes"],
        "transport_wire_bytes": value["transport_wire_bytes"],
        "roots": {name: value[name].hex() for name in ROOT_FIELDS},
    }
    if tuple(document) != TOP_FIELDS or tuple(document["roots"]) != ROOT_FIELDS:
        raise AssertionError("provider inspector field order drift")
    return document


def render_expected(
    encoded: bytes,
    *,
    composition_verified: bool = False,
) -> bytes:
    """Render the deterministic compact one-line JSON contract."""

    return (
        json.dumps(
            expected_document(
                encoded,
                composition_verified=composition_verified,
            ),
            ensure_ascii=True,
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )


def parse_rendered(encoded: bytes) -> Record:
    """Validate exact keys, order, scalar types, and lowercase digest rendering."""

    if (
        type(encoded) is not bytes
        or not encoded.endswith(b"\n")
        or encoded.count(b"\n") != 1
    ):
        raise ProviderEvidenceInspectorError("inspector output is not one line")
    try:
        document = json.loads(encoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderEvidenceInspectorError("invalid inspector JSON") from error
    if type(document) is not dict or tuple(document) != TOP_FIELDS:
        raise ProviderEvidenceInspectorError("invalid inspector fields")
    if (
        document["schema"] != SCHEMA
        or document["wire_abi"] != f"{WIRE_ABI:016x}"
        or document["wire_bytes"] != WIRE_BYTES
        or document["outer_envelope_verified"] is not True
        or type(document["composition_verified"]) is not bool
        or document["authority_granted"] is not False
    ):
        raise ProviderEvidenceInspectorError("invalid inspector claim boundary")
    scalar_limits = {
        "journal_sequence": (1 << 64) - 1,
        "gateway_event_index": (1 << 32) - 1,
        "transport_event_count": (1 << 32) - 1,
        "journal_frame_bytes": (1 << 64) - 1,
        "gateway_wire_bytes": (1 << 64) - 1,
        "transport_wire_bytes": (1 << 64) - 1,
    }
    for name, maximum in scalar_limits.items():
        if (
            type(document[name]) is not int
            or document[name] < 0
            or document[name] > maximum
        ):
            raise ProviderEvidenceInspectorError("invalid rendered scalar")
    roots = document["roots"]
    if type(roots) is not dict or tuple(roots) != ROOT_FIELDS:
        raise ProviderEvidenceInspectorError("invalid rendered roots")
    for root in roots.values():
        if (
            type(root) is not str
            or len(root) != 64
            or any(character not in "0123456789abcdef" for character in root)
        ):
            raise ProviderEvidenceInspectorError("invalid rendered digest")
    return document


def reseal_outer(encoded: bytes) -> bytes:
    """Recompute the outer checksum without invoking the composition oracle."""

    if type(encoded) is not bytes or len(encoded) != WIRE_BYTES:
        raise ProviderEvidenceInspectorError("invalid join length")
    return encoded[:-32] + _envelope_sha256(encoded[:-32])


def reseal_nonzero_contradiction(encoded: bytes) -> bytes:
    """Change one self-asserted digest, then recompute only the outer checksum."""

    request_index = ROOT_FIELDS.index("request_sha256")
    offset = 72 + request_index * 32
    mutated = bytearray(encoded)
    mutated[offset] ^= 0x01
    candidate = reseal_outer(bytes(mutated))
    decode_outer(candidate)
    return candidate


def _invoke(executable: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        (str(executable), *arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def verify_executable(executable: Path) -> None:
    """Run outer, composed, contradictory, and corrupt subprocess cases."""

    bundle = join_wire.build_demo_bundle()
    with tempfile.TemporaryDirectory(prefix="glacier-provider-inspector-oracle-") as name:
        directory = Path(name)
        valid_path = directory / "provider.join"
        valid_path.write_bytes(bundle["join"])
        valid = _invoke(executable, "--join", str(valid_path))
        if (
            valid.returncode != 0
            or valid.stderr != b""
            or valid.stdout != render_expected(bundle["join"])
        ):
            raise ProviderEvidenceInspectorError("valid inspector execution drift")
        parse_rendered(valid.stdout)

        nested_payloads = {
            "journal-header": cost_journal.encode_header(bundle["header"]),
            "cost-frame": bundle["frame"],
            "gateway-events": bundle["gateway"],
            "transport-events": bundle["transport"],
        }
        nested_paths: dict[str, Path] = {}
        for label, payload in nested_payloads.items():
            path = directory / f"private-{label}-credentials.bin"
            path.write_bytes(payload)
            nested_paths[label] = path
        composition_arguments = (
            "--join",
            str(valid_path),
            "--journal-header",
            str(nested_paths["journal-header"]),
            "--cost-frame",
            str(nested_paths["cost-frame"]),
            "--gateway-events",
            str(nested_paths["gateway-events"]),
            "--transport-events",
            str(nested_paths["transport-events"]),
        )
        before_nested = {
            label: path.read_bytes()
            for label, path in nested_paths.items()
        }
        join_wire.decode_and_verify(
            bundle["join"],
            bundle["header"],
            bundle["frame"],
            bundle["gateway"],
            bundle["transport"],
        )
        composed = _invoke(executable, *composition_arguments)
        if (
            composed.returncode != 0
            or composed.stderr != b""
            or composed.stdout
            != render_expected(
                bundle["join"],
                composition_verified=True,
            )
            or parse_rendered(composed.stdout)["composition_verified"]
            is not True
            or any(
                path.read_bytes() != before_nested[label]
                for label, path in nested_paths.items()
            )
        ):
            raise ProviderEvidenceInspectorError(
                "valid composed inspector execution drift"
            )

        contradictory = reseal_nonzero_contradiction(bundle["join"])
        contradiction_path = directory / "contradictory.join"
        contradiction_path.write_bytes(contradictory)
        accepted = _invoke(executable, "--join", str(contradiction_path))
        if (
            accepted.returncode != 0
            or accepted.stderr != b""
            or accepted.stdout != render_expected(contradictory)
        ):
            raise ProviderEvidenceInspectorError(
                "outer-only contradiction behavior drift"
            )
        try:
            join_wire.decode_and_verify(
                contradictory,
                bundle["header"],
                bundle["frame"],
                bundle["gateway"],
                bundle["transport"],
            )
        except join_wire.WireError:
            pass
        else:
            raise ProviderEvidenceInspectorError(
                "full composition accepted contradictory join"
            )
        composed_contradiction = _invoke(
            executable,
            "--join",
            str(contradiction_path),
            *composition_arguments[2:],
        )
        if (
            composed_contradiction.returncode != 2
            or composed_contradiction.stdout != b""
            or not composed_contradiction.stderr.startswith(
                b"provider-evidence-inspector: "
            )
            or not composed_contradiction.stderr.endswith(b"\n")
        ):
            raise ProviderEvidenceInspectorError(
                "composed contradiction was not rejected"
            )

        corrupt = bytearray(bundle["join"])
        corrupt[-1] ^= 0x01
        corrupt_path = directory / "corrupt.join"
        corrupt_path.write_bytes(corrupt)
        rejected = _invoke(executable, "--join", str(corrupt_path))
        if (
            rejected.returncode != 2
            or rejected.stdout != b""
            or not rejected.stderr.startswith(b"provider-evidence-inspector: ")
            or not rejected.stderr.endswith(b"\n")
            or str(corrupt_path).encode() in rejected.stderr
        ):
            raise ProviderEvidenceInspectorError("corrupt join was not rejected")

        partial = _invoke(
            executable,
            "--join",
            str(valid_path),
            "--journal-header",
            str(nested_paths["journal-header"]),
        )
        if partial.returncode != 2 or partial.stdout != b"":
            raise ProviderEvidenceInspectorError(
                "partial composition arguments were not rejected"
            )

        oversized = bytearray(bundle["join"])
        struct.pack_into(
            "<Q",
            oversized,
            56,
            MAXIMUM_NESTED_WIRE_BYTES + 1,
        )
        oversized_path = directory / "oversized-gateway.join"
        oversized_path.write_bytes(reseal_outer(bytes(oversized)))
        oversized_arguments = list(composition_arguments)
        oversized_arguments[1] = str(oversized_path)
        rejected_oversized = _invoke(executable, *oversized_arguments)
        if (
            rejected_oversized.returncode != 2
            or rejected_oversized.stdout != b""
        ):
            raise ProviderEvidenceInspectorError(
                "oversized nested wire claim was not rejected"
            )

        argument_positions = {
            "journal-header": 3,
            "cost-frame": 5,
            "gateway-events": 7,
            "transport-events": 9,
        }
        for label, position in argument_positions.items():
            mutated = bytearray(nested_payloads[label])
            mutated[-1] ^= 0x01
            mutated_path = directory / f"mutated-{label}-credentials.bin"
            mutated_path.write_bytes(mutated)
            arguments = list(composition_arguments)
            arguments[position] = str(mutated_path)
            rejected_nested = _invoke(executable, *arguments)
            if (
                rejected_nested.returncode != 2
                or rejected_nested.stdout != b""
                or not rejected_nested.stderr.startswith(
                    b"provider-evidence-inspector: "
                )
                or not rejected_nested.stderr.endswith(b"\n")
                or str(mutated_path).encode() in rejected_nested.stderr
            ):
                raise ProviderEvidenceInspectorError(
                    f"corrupt {label} evidence was not rejected"
                )

        swapped = list(composition_arguments)
        swapped[7], swapped[9] = swapped[9], swapped[7]
        rejected_swap = _invoke(executable, *swapped)
        if rejected_swap.returncode != 2 or rejected_swap.stdout != b"":
            raise ProviderEvidenceInspectorError(
                "swapped nested evidence was not rejected"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspector", required=True, type=Path)
    arguments = parser.parse_args()
    verify_executable(arguments.inspector)


if __name__ == "__main__":
    main()
