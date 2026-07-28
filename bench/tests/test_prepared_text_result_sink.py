from __future__ import annotations

import hashlib
import os
from pathlib import Path
import struct
import tempfile
import unittest

from bench import prepared_text_result_sink as sink


def digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("utf-8")).digest()


def identity(
    *,
    base_global_sequence: int = 37,
    maximum_results: int = 4,
) -> dict[str, object]:
    return {
        "request_sha256": digest("request identity"),
        "request_epoch": 701,
        "sink_implementation_sha256": digest("sink implementation"),
        "sink_instance_sha256": digest("sink instance"),
        "base_global_sequence": base_global_sequence,
        "maximum_results": maximum_results,
    }


def acknowledgement_chain(
    count: int,
    *,
    values: dict[str, object] | None = None,
) -> tuple[bytes, ...]:
    configuration = identity() if values is None else values
    request = configuration["request_sha256"]
    epoch = configuration["request_epoch"]
    implementation = configuration["sink_implementation_sha256"]
    instance = configuration["sink_instance_sha256"]
    base = configuration["base_global_sequence"]
    assert isinstance(request, bytes)
    assert isinstance(epoch, int)
    assert isinstance(implementation, bytes)
    assert isinstance(instance, bytes)
    assert isinstance(base, int)

    predecessor_ack = sink.ZERO_DIGEST
    predecessor_prefix = sink.ZERO_DIGEST
    result: list[bytes] = []
    for index in range(count):
        sequence = base + index
        encoded = sink.encode_acknowledgement_v1(
            request_sha256=request,
            request_epoch=epoch,
            transaction_sequence=sequence,
            token_id=1000 + index,
            proposal_sha256=digest(f"proposal:{sequence}"),
            transition_sha256=digest(f"transition:{sequence}"),
            commit_receipt_sha256=digest(f"receipt:{sequence}"),
            sink_implementation_sha256=implementation,
            sink_instance_sha256=instance,
            application_ordinal=index + 1,
            predecessor_acknowledgement_sha256=predecessor_ack,
            predecessor_sink_prefix_sha256=predecessor_prefix,
        )
        decoded = sink.decode_acknowledgement_v1(encoded)
        predecessor_ack = decoded.acknowledgement_sha256
        predecessor_prefix = decoded.result_sink_prefix_sha256
        result.append(encoded)
    return tuple(result)


def create_store(
    parent: Path,
    values: dict[str, object],
) -> tuple[Path, sink.ResultSinkV1]:
    directory = parent / "result-sink"
    store = sink.ResultSinkV1.create(directory, **values)
    return directory, store


def rehash_acknowledgement(mutated: bytearray) -> bytes:
    request_epoch, sequence, token, ordinal, count = struct.unpack_from(
        "<QQQQQ",
        mutated,
        32,
    )
    delivery = hashlib.sha256(
        sink.DELIVERY_KEY_DOMAIN
        + struct.pack("<Q", sink.ACKNOWLEDGEMENT_ABI)
        + mutated[72:104]
        + struct.pack("<QQ", request_epoch, sequence)
    ).digest()
    mutated[264:296] = delivery
    mutated[360:392] = hashlib.sha256(
        sink.SINK_PREFIX_DOMAIN
        + struct.pack(
            "<QQQQQQ",
            sink.ACKNOWLEDGEMENT_ABI,
            request_epoch,
            sequence,
            token,
            ordinal,
            count,
        )
        + mutated[72:264]
        + delivery
        + mutated[296:360]
    ).digest()
    mutated[392:424] = hashlib.sha256(
        sink.ACKNOWLEDGEMENT_DOMAIN + mutated[:392]
    ).digest()
    return bytes(mutated)


def decode_ledger(
    encoded: bytes,
    values: dict[str, object],
) -> sink._LedgerV1:
    request = values["request_sha256"]
    epoch = values["request_epoch"]
    implementation = values["sink_implementation_sha256"]
    instance = values["sink_instance_sha256"]
    base = values["base_global_sequence"]
    maximum = values["maximum_results"]
    assert isinstance(request, bytes)
    assert isinstance(epoch, int)
    assert isinstance(implementation, bytes)
    assert isinstance(instance, bytes)
    assert isinstance(base, int)
    assert isinstance(maximum, int)
    return sink._decode_ledger(
        encoded,
        expected_request_sha256=request,
        expected_request_epoch=epoch,
        expected_sink_implementation_sha256=implementation,
        expected_sink_instance_sha256=instance,
        expected_base_global_sequence=base,
        expected_maximum_results=maximum,
    )


def decode_selector(
    encoded: bytes,
    values: dict[str, object],
) -> sink._SelectorV1:
    request = values["request_sha256"]
    epoch = values["request_epoch"]
    implementation = values["sink_implementation_sha256"]
    instance = values["sink_instance_sha256"]
    base = values["base_global_sequence"]
    maximum = values["maximum_results"]
    assert isinstance(request, bytes)
    assert isinstance(epoch, int)
    assert isinstance(implementation, bytes)
    assert isinstance(instance, bytes)
    assert isinstance(base, int)
    assert isinstance(maximum, int)
    return sink._decode_selector(
        encoded,
        expected_request_sha256=request,
        expected_request_epoch=epoch,
        expected_sink_implementation_sha256=implementation,
        expected_sink_instance_sha256=instance,
        expected_base_global_sequence=base,
        expected_maximum_results=maximum,
    )


class AcknowledgementCodecTests(unittest.TestCase):
    def test_zig_golden_acknowledgement_and_manual_hashes(self) -> None:
        request = digest("request")
        implementation = digest("sink implementation")
        instance = digest("sink instance")
        encoded = sink.encode_acknowledgement_v1(
            request_sha256=request,
            request_epoch=71,
            transaction_sequence=9,
            token_id=42,
            proposal_sha256=digest("proposal:first:9"),
            transition_sha256=digest("transition:first:9"),
            commit_receipt_sha256=digest("receipt:first:9"),
            sink_implementation_sha256=implementation,
            sink_instance_sha256=instance,
            application_ordinal=1,
        )
        decoded = sink.decode_acknowledgement_v1(encoded)

        expected_delivery = hashlib.sha256(
            sink.DELIVERY_KEY_DOMAIN
            + struct.pack("<Q", sink.ACKNOWLEDGEMENT_ABI)
            + request
            + struct.pack("<QQ", 71, 9)
        ).digest()
        expected_prefix = hashlib.sha256(
            sink.SINK_PREFIX_DOMAIN
            + struct.pack(
                "<QQQQQQ",
                sink.ACKNOWLEDGEMENT_ABI,
                71,
                9,
                42,
                1,
                1,
            )
            + request
            + digest("proposal:first:9")
            + digest("transition:first:9")
            + digest("receipt:first:9")
            + implementation
            + instance
            + expected_delivery
            + sink.ZERO_DIGEST
            + sink.ZERO_DIGEST
        ).digest()
        expected_root = hashlib.sha256(
            sink.ACKNOWLEDGEMENT_DOMAIN + encoded[: sink.ACKNOWLEDGEMENT_BODY_BYTES]
        ).digest()

        self.assertEqual(len(encoded), 424)
        self.assertEqual(encoded[:8], b"GPRSACK1")
        self.assertEqual(struct.unpack_from("<Q", encoded, 8)[0], 0x4750525300000001)
        self.assertEqual(decoded.delivery_key_sha256, expected_delivery)
        self.assertEqual(decoded.result_sink_prefix_sha256, expected_prefix)
        self.assertEqual(decoded.acknowledgement_sha256, expected_root)
        self.assertEqual(
            decoded.delivery_key_sha256.hex(),
            "e3187fb40ed3f4e98fbb453b7ae7a3b1fa006f45fe6de12d0bd18be8fc488821",
        )
        self.assertEqual(
            decoded.result_sink_prefix_sha256.hex(),
            "64933c85cb744c5213a143ad7e2bbf0de1e1a958ddd4b0c39ae3131e142bd49f",
        )
        self.assertEqual(
            decoded.acknowledgement_sha256.hex(),
            "d377155aaa28cf6027ebf1751fa8f73540f66bc366c6b8efbfc6ea8285396c48",
        )

    def test_every_acknowledgement_byte_is_authenticated(self) -> None:
        encoded = acknowledgement_chain(1)[0]
        for index in range(len(encoded)):
            with self.subTest(index=index):
                mutated = bytearray(encoded)
                mutated[index] ^= 1
                with self.assertRaises(sink.AcknowledgementError):
                    sink.decode_acknowledgement_v1(bytes(mutated))

    def test_identity_expectations_and_predecessor_shape_fail_closed(
        self,
    ) -> None:
        values = identity()
        first, second = acknowledgement_chain(2, values=values)
        decoded_first = sink.decode_acknowledgement_v1(
            first,
            expected_request_sha256=values["request_sha256"],
            expected_request_epoch=values["request_epoch"],
            expected_sink_implementation_sha256=(values["sink_implementation_sha256"]),
            expected_sink_instance_sha256=values["sink_instance_sha256"],
        )
        decoded_second = sink.decode_acknowledgement_v1(second)
        self.assertEqual(
            decoded_second.predecessor_acknowledgement_sha256,
            decoded_first.acknowledgement_sha256,
        )
        self.assertEqual(
            decoded_second.predecessor_sink_prefix_sha256,
            decoded_first.result_sink_prefix_sha256,
        )

        with self.assertRaises(sink.SinkIdentityMismatch):
            sink.decode_acknowledgement_v1(
                first,
                expected_request_sha256=digest("foreign request"),
            )
        with self.assertRaises(sink.AcknowledgementError):
            sink.encode_acknowledgement_v1(
                request_sha256=values["request_sha256"],
                request_epoch=values["request_epoch"],
                transaction_sequence=values["base_global_sequence"],
                token_id=1,
                proposal_sha256=digest("proposal"),
                transition_sha256=digest("transition"),
                commit_receipt_sha256=digest("receipt"),
                sink_implementation_sha256=(values["sink_implementation_sha256"]),
                sink_instance_sha256=values["sink_instance_sha256"],
                application_ordinal=1,
                predecessor_acknowledgement_sha256=digest("unexpected"),
                predecessor_sink_prefix_sha256=digest("unexpected prefix"),
            )
        with self.assertRaises(sink.AcknowledgementError):
            sink.encode_acknowledgement_v1(
                request_sha256=values["request_sha256"],
                request_epoch=values["request_epoch"],
                transaction_sequence=values["base_global_sequence"],
                token_id=1,
                proposal_sha256=digest("proposal"),
                transition_sha256=digest("transition"),
                commit_receipt_sha256=digest("receipt"),
                sink_implementation_sha256=(values["sink_implementation_sha256"]),
                sink_instance_sha256=values["sink_instance_sha256"],
                application_ordinal=2,
            )

    def test_scalar_validation_rejects_noncanonical_values(self) -> None:
        values = identity()
        common = {
            "request_sha256": values["request_sha256"],
            "request_epoch": values["request_epoch"],
            "transaction_sequence": values["base_global_sequence"],
            "proposal_sha256": digest("proposal"),
            "transition_sha256": digest("transition"),
            "commit_receipt_sha256": digest("receipt"),
            "sink_implementation_sha256": (values["sink_implementation_sha256"]),
            "sink_instance_sha256": values["sink_instance_sha256"],
            "application_ordinal": 1,
        }
        with self.assertRaises(sink.AcknowledgementError):
            sink.encode_acknowledgement_v1(
                **common,
                token_id=1 << 32,
            )
        with self.assertRaises(sink.AcknowledgementError):
            sink.encode_acknowledgement_v1(
                **{**common, "application_ordinal": 0},
                token_id=1,
            )
        with self.assertRaises(sink.AcknowledgementError):
            sink.encode_acknowledgement_v1(
                **{**common, "request_epoch": 0},
                token_id=1,
            )

    def test_coherently_rehashed_invalid_acknowledgements_reject(
        self,
    ) -> None:
        encoded = acknowledgement_chain(1)[0]
        mutations = (
            (32, 0),
            (48, 1 << 32),
            (56, 0),
            (64, 2),
        )
        for offset, value in mutations:
            with self.subTest(offset=offset, value=value):
                mutated = bytearray(encoded)
                struct.pack_into("<Q", mutated, offset, value)
                coherent = rehash_acknowledgement(mutated)
                with self.assertRaises(sink.AcknowledgementError):
                    sink.decode_acknowledgement_v1(coherent)

        unexpected_predecessor = bytearray(encoded)
        unexpected_predecessor[296:328] = digest("unexpected predecessor")
        unexpected_predecessor[328:360] = digest("unexpected prefix")
        coherent = rehash_acknowledgement(unexpected_predecessor)
        with self.assertRaises(sink.AcknowledgementError):
            sink.decode_acknowledgement_v1(coherent)


class DurableWireCodecTests(unittest.TestCase):
    def test_zig_golden_ledger_and_selector(self) -> None:
        values = {
            "request_sha256": digest("wire request"),
            "request_epoch": 501,
            "sink_implementation_sha256": digest("wire implementation"),
            "sink_instance_sha256": digest("wire instance"),
            "base_global_sequence": 7,
            "maximum_results": 2,
        }
        acknowledgement = sink.encode_acknowledgement_v1(
            request_sha256=values["request_sha256"],
            request_epoch=501,
            transaction_sequence=7,
            token_id=91,
            proposal_sha256=digest("proposal:7"),
            transition_sha256=digest("transition:7"),
            commit_receipt_sha256=digest("receipt:7"),
            sink_implementation_sha256=(values["sink_implementation_sha256"]),
            sink_instance_sha256=values["sink_instance_sha256"],
            application_ordinal=1,
        )
        decoded_ack = sink.decode_acknowledgement_v1(acknowledgement)
        self.assertEqual(
            decoded_ack.acknowledgement_sha256.hex(),
            "9265bf42a1f61591565204297d07255368f0257f49cddf6d92710f6f890b28d8",
        )

        ledger_wire = sink._encode_ledger(
            request_sha256=values["request_sha256"],
            request_epoch=values["request_epoch"],
            sink_implementation_sha256=(values["sink_implementation_sha256"]),
            sink_instance_sha256=values["sink_instance_sha256"],
            base_global_sequence=values["base_global_sequence"],
            acknowledgement_wires=(acknowledgement,),
        )
        ledger = decode_ledger(ledger_wire, values)
        self.assertEqual(len(ledger_wire), 712)
        self.assertEqual(ledger_wire[:8], b"GPRSLED1")
        self.assertEqual(
            ledger.ledger_sha256.hex(),
            "86afd3be9d7e0da5d15de2da194c8758361eeaa3630a00df4b7e6713584e87a1",
        )

        selector_wire = sink._encode_selector(
            ledger=ledger,
            previous_selector_sha256=digest("previous"),
        )
        selector = decode_selector(selector_wire, values)
        self.assertEqual(len(selector_wire), 272)
        self.assertEqual(selector_wire[:8], b"GPRSSEL1")
        self.assertEqual(selector.generation, 2)
        self.assertEqual(
            selector.selector_sha256.hex(),
            "ca19dbee6b3562b12d460b12a2f07f9e70a6d0f6bb134d76abcaff532bafac70",
        )

    def test_every_ledger_and_selector_byte_is_authenticated(self) -> None:
        values = identity(maximum_results=2)
        acknowledgement = acknowledgement_chain(1, values=values)[0]
        ledger_wire = sink._encode_ledger(
            request_sha256=values["request_sha256"],
            request_epoch=values["request_epoch"],
            sink_implementation_sha256=(values["sink_implementation_sha256"]),
            sink_instance_sha256=values["sink_instance_sha256"],
            base_global_sequence=values["base_global_sequence"],
            acknowledgement_wires=(acknowledgement,),
        )
        ledger = decode_ledger(ledger_wire, values)
        selector_wire = sink._encode_selector(
            ledger=ledger,
            previous_selector_sha256=digest("previous selector"),
        )

        for index in range(len(ledger_wire)):
            with self.subTest(wire="ledger", index=index):
                mutated = bytearray(ledger_wire)
                mutated[index] ^= 1
                with self.assertRaises(sink.PreparedTextResultSinkError):
                    decode_ledger(bytes(mutated), values)
        for index in range(len(selector_wire)):
            with self.subTest(wire="selector", index=index):
                mutated = bytearray(selector_wire)
                mutated[index] ^= 1
                with self.assertRaises(sink.PreparedTextResultSinkError):
                    decode_selector(bytes(mutated), values)

    def test_coherent_reserved_and_chain_substitutions_reject(self) -> None:
        values = identity(maximum_results=3)
        first, _ = acknowledgement_chain(2, values=values)
        first_decoded = sink.decode_acknowledgement_v1(first)
        wrong_second = sink.encode_acknowledgement_v1(
            request_sha256=values["request_sha256"],
            request_epoch=values["request_epoch"],
            transaction_sequence=values["base_global_sequence"] + 1,
            token_id=1001,
            proposal_sha256=digest("proposal:wrong"),
            transition_sha256=digest("transition:wrong"),
            commit_receipt_sha256=digest("receipt:wrong"),
            sink_implementation_sha256=(values["sink_implementation_sha256"]),
            sink_instance_sha256=values["sink_instance_sha256"],
            application_ordinal=2,
            predecessor_acknowledgement_sha256=digest("wrong predecessor"),
            predecessor_sink_prefix_sha256=digest("wrong prefix"),
        )
        self.assertNotEqual(
            sink.decode_acknowledgement_v1(
                wrong_second
            ).predecessor_acknowledgement_sha256,
            first_decoded.acknowledgement_sha256,
        )
        wrong_chain = sink._encode_ledger(
            request_sha256=values["request_sha256"],
            request_epoch=values["request_epoch"],
            sink_implementation_sha256=(values["sink_implementation_sha256"]),
            sink_instance_sha256=values["sink_instance_sha256"],
            base_global_sequence=values["base_global_sequence"],
            acknowledgement_wires=(first, wrong_second),
        )
        with self.assertRaises(sink.SinkStorageError):
            decode_ledger(wrong_chain, values)

        valid_ledger = sink._encode_ledger(
            request_sha256=values["request_sha256"],
            request_epoch=values["request_epoch"],
            sink_implementation_sha256=(values["sink_implementation_sha256"]),
            sink_instance_sha256=values["sink_instance_sha256"],
            base_global_sequence=values["base_global_sequence"],
            acknowledgement_wires=(first,),
        )
        reserved = bytearray(valid_ledger)
        reserved[240] = 1
        reserved[-sink.LEDGER_FOOTER_BYTES :] = hashlib.sha256(
            sink.LEDGER_DOMAIN + reserved[: -sink.LEDGER_FOOTER_BYTES]
        ).digest()
        with self.assertRaises(sink.SinkStorageError):
            decode_ledger(bytes(reserved), values)

        ledger = decode_ledger(valid_ledger, values)
        selector_wire = bytearray(
            sink._encode_selector(
                ledger=ledger,
                previous_selector_sha256=digest("previous selector"),
            )
        )
        selector_wire[176:208] = sink.ZERO_DIGEST
        selector_wire[-32:] = hashlib.sha256(
            sink.SELECTOR_DOMAIN + selector_wire[: sink.SELECTOR_BODY_BYTES]
        ).digest()
        with self.assertRaises(sink.SinkStorageError):
            decode_selector(bytes(selector_wire), values)


class ResultSinkStoreTests(unittest.TestCase):
    def test_zero_is_a_valid_initial_global_sequence(self) -> None:
        values = identity(
            base_global_sequence=0,
            maximum_results=1,
        )
        acknowledgement = acknowledgement_chain(1, values=values)[0]
        with tempfile.TemporaryDirectory() as temporary:
            _, store = create_store(Path(temporary), values)
            receipt = store.apply(acknowledgement)
            snapshot = store.snapshot()
            self.assertEqual(receipt.transaction_sequence, 0)
            self.assertEqual(snapshot.base_global_sequence, 0)
            self.assertEqual(snapshot.next_global_sequence, 1)
            store.close()

    def test_apply_replay_reopen_and_phase_order(self) -> None:
        values = identity(maximum_results=4)
        acknowledgements = acknowledgement_chain(3, values=values)
        with tempfile.TemporaryDirectory() as temporary:
            directory, store = create_store(Path(temporary), values)
            initial = store.snapshot()
            self.assertEqual(initial.generation, 1)
            self.assertEqual(initial.applied_count, 0)
            self.assertEqual(
                initial.next_global_sequence,
                values["base_global_sequence"],
            )
            self.assertEqual(
                initial.ledger_bytes,
                sink.LEDGER_HEADER_BYTES + sink.LEDGER_FOOTER_BYTES,
            )

            phases: list[str] = []
            applied = store.apply(
                acknowledgements[0],
                phase_observer=phases.append,
            )
            self.assertEqual(applied.disposition, sink.APPLIED)
            self.assertEqual(phases, list(sink.IO_PHASES))
            replay_phases: list[str] = []
            replay = store.apply(
                acknowledgements[0],
                phase_observer=replay_phases.append,
            )
            self.assertEqual(replay.disposition, sink.ALREADY_APPLIED)
            self.assertEqual(replay_phases, [])
            store.apply(acknowledgements[1])
            expected = store.snapshot()
            store.close()

            reopened = sink.ResultSinkV1.open(directory, **values)
            self.assertEqual(reopened.snapshot(), expected)
            self.assertEqual(
                reopened.apply(acknowledgements[0]).disposition,
                sink.ALREADY_APPLIED,
            )
            self.assertEqual(
                reopened.apply(acknowledgements[2]).disposition,
                sink.APPLIED,
            )
            final = reopened.snapshot()
            self.assertEqual(final.applied_count, 3)
            self.assertEqual(final.generation, 4)
            reopened.close()

            active = (directory / sink.ACTIVE_SELECTOR_NAME).read_bytes()
            ledger_root = active[208:240]
            ledger_path = directory / (
                "prepared-text-result-ledger-" + ledger_root.hex() + ".bin"
            )
            self.assertTrue(ledger_path.is_file())

    def test_conflicts_gaps_identity_and_capacity_fail_closed(self) -> None:
        values = identity(maximum_results=2)
        first, second = acknowledgement_chain(2, values=values)
        with tempfile.TemporaryDirectory() as temporary:
            _, store = create_store(Path(temporary), values)
            with self.assertRaises(sink.SinkSequenceGap):
                store.apply(second)
            store.apply(first)

            conflicting = sink.encode_acknowledgement_v1(
                request_sha256=values["request_sha256"],
                request_epoch=values["request_epoch"],
                transaction_sequence=values["base_global_sequence"],
                token_id=999,
                proposal_sha256=digest("conflicting proposal"),
                transition_sha256=digest("conflicting transition"),
                commit_receipt_sha256=digest("conflicting receipt"),
                sink_implementation_sha256=(values["sink_implementation_sha256"]),
                sink_instance_sha256=values["sink_instance_sha256"],
                application_ordinal=1,
            )
            with self.assertRaises(sink.SinkConflict):
                store.apply(conflicting)

            wrong_predecessor = sink.encode_acknowledgement_v1(
                request_sha256=values["request_sha256"],
                request_epoch=values["request_epoch"],
                transaction_sequence=values["base_global_sequence"] + 1,
                token_id=1001,
                proposal_sha256=digest("next proposal"),
                transition_sha256=digest("next transition"),
                commit_receipt_sha256=digest("next receipt"),
                sink_implementation_sha256=(values["sink_implementation_sha256"]),
                sink_instance_sha256=values["sink_instance_sha256"],
                application_ordinal=2,
                predecessor_acknowledgement_sha256=digest("wrong ack"),
                predecessor_sink_prefix_sha256=digest("wrong prefix"),
            )
            with self.assertRaises(sink.SinkConflict):
                store.apply(wrong_predecessor)

            foreign_values = dict(values)
            foreign_values["request_sha256"] = digest("foreign request")
            foreign = acknowledgement_chain(
                1,
                values=foreign_values,
            )[0]
            with self.assertRaises(sink.SinkIdentityMismatch):
                store.apply(foreign)

            store.apply(second)
            full_snapshot = store.snapshot()
            with self.assertRaises(sink.SinkCapacityExceeded):
                third = acknowledgement_chain(
                    3,
                    values={**values, "maximum_results": 3},
                )[2]
                store.apply(third)
            self.assertEqual(store.snapshot(), full_snapshot)
            with self.assertRaises(sink.PreparedTextResultSinkError):
                store.apply(first, crash_after="not-a-phase")
            self.assertEqual(store.snapshot(), full_snapshot)
            store.close()

    def test_exclusive_lease(self) -> None:
        values = identity()
        with tempfile.TemporaryDirectory() as temporary:
            directory, store = create_store(Path(temporary), values)
            with self.assertRaises(sink.SinkBusy):
                sink.ResultSinkV1.open(directory, **values)
            store.close()
            reopened = sink.ResultSinkV1.open(directory, **values)
            reopened.close()

    def test_every_injected_crash_recovers_old_or_exact_successor(
        self,
    ) -> None:
        values = identity(maximum_results=3)
        first, second = acknowledgement_chain(2, values=values)
        for phase_index, phase in enumerate(sink.IO_PHASES):
            with self.subTest(phase=phase):
                with tempfile.TemporaryDirectory() as temporary:
                    directory, store = create_store(
                        Path(temporary),
                        values,
                    )
                    store.apply(first)
                    observed: list[str] = []
                    with self.assertRaises(sink.InjectedCrash) as raised:
                        store.apply(
                            second,
                            crash_after=phase,
                            phase_observer=observed.append,
                        )
                    self.assertEqual(raised.exception.phase, phase)
                    self.assertEqual(
                        observed,
                        list(sink.IO_PHASES[: phase_index + 1]),
                    )
                    with self.assertRaises(sink.SinkStorageError):
                        store.snapshot()
                    store.close()

                    recovered = sink.ResultSinkV1.open(
                        directory,
                        **values,
                    )
                    expected_count = (
                        2
                        if phase_index >= sink.IO_PHASES.index(sink.SELECTOR_REPLACE)
                        else 1
                    )
                    self.assertEqual(
                        recovered.snapshot().applied_count,
                        expected_count,
                    )
                    disposition = recovered.apply(second).disposition
                    self.assertEqual(
                        disposition,
                        (sink.ALREADY_APPLIED if expected_count == 2 else sink.APPLIED),
                    )
                    self.assertEqual(
                        recovered.snapshot().applied_count,
                        2,
                    )
                    recovered.close()

                    verified = sink.ResultSinkV1.open(
                        directory,
                        **values,
                    )
                    self.assertEqual(verified.snapshot().applied_count, 2)
                    verified.close()

    def test_corrupt_selector_and_referenced_ledger_fail_closed(self) -> None:
        values = identity(maximum_results=2)
        first = acknowledgement_chain(1, values=values)[0]
        with tempfile.TemporaryDirectory() as temporary:
            directory, store = create_store(Path(temporary), values)
            store.apply(first)
            store.close()
            selector_path = directory / sink.ACTIVE_SELECTOR_NAME
            selector_wire = selector_path.read_bytes()
            ledger_path = directory / sink._ledger_name(selector_wire[208:240])

            corrupted_ledger = bytearray(ledger_path.read_bytes())
            corrupted_ledger[256] ^= 1
            ledger_path.write_bytes(corrupted_ledger)
            with self.assertRaises(sink.SinkStorageError):
                sink.ResultSinkV1.open(directory, **values)

        with tempfile.TemporaryDirectory() as temporary:
            directory, store = create_store(Path(temporary), values)
            store.apply(first)
            store.close()
            selector_path = directory / sink.ACTIVE_SELECTOR_NAME
            corrupted_selector = bytearray(selector_path.read_bytes())
            corrupted_selector[80] ^= 1
            selector_path.write_bytes(corrupted_selector)
            with self.assertRaises(sink.SinkStorageError):
                sink.ResultSinkV1.open(directory, **values)

    def test_orphan_temps_are_ignored_and_unsafe_files_reject(self) -> None:
        values = identity(maximum_results=2)
        first = acknowledgement_chain(1, values=values)[0]
        with tempfile.TemporaryDirectory() as temporary:
            directory, store = create_store(Path(temporary), values)
            store.apply(first)
            store.close()
            orphan = directory / (sink.TEMP_NAME_PREFIX + "ledger-orphan")
            orphan.write_bytes(b"partial")
            reopened = sink.ResultSinkV1.open(directory, **values)
            self.assertEqual(reopened.snapshot().applied_count, 1)
            reopened.close()

            selector = (directory / sink.ACTIVE_SELECTOR_NAME).read_bytes()
            ledger_path = directory / sink._ledger_name(selector[208:240])
            os.chmod(ledger_path, 0o644)
            with self.assertRaises(sink.SinkStorageError):
                sink.ResultSinkV1.open(directory, **values)

        with tempfile.TemporaryDirectory() as temporary:
            directory, store = create_store(Path(temporary), values)
            store.close()
            selector_path = directory / sink.ACTIVE_SELECTOR_NAME
            selector_copy = directory / "selector-copy"
            selector_copy.write_bytes(selector_path.read_bytes())
            os.chmod(selector_copy, 0o600)
            selector_path.unlink()
            selector_path.symlink_to(selector_copy.name)
            with self.assertRaises(sink.SinkStorageError):
                sink.ResultSinkV1.open(directory, **values)


if __name__ == "__main__":
    unittest.main()
