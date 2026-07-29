from __future__ import annotations

from dataclasses import replace
import hashlib
import json
import struct
import unittest

from bench import prepared_text_committed_output as committed


def digest(label: str) -> bytes:
    return hashlib.sha256(label.encode("utf-8")).digest()


REQUEST_EPOCH = 0x5231_4B42_3300_0001
CHECKPOINT_GENERATION = 3
PACKAGE_SHA256 = digest("R1k-b3 package")
REPRESENTATION_SHA256 = digest("R1k-b3 representation")
INPUT_ARCHIVE_SHA256 = digest("R1k-b3 input archive")
TOKENIZER_DOMAIN_SHA256 = digest("R1k-b3 tokenizer domain")
TOKENIZER_BEHAVIOR_SHA256 = digest("R1k-b3 tokenizer behavior")
TOKENIZER_CONFIG_SHA256 = digest("R1k-b3 tokenizer config")
LOCAL_PLAN_SHA256 = digest("R1k-b3 local plan")
REQUEST_SHA256 = digest("R1k-b3 request")
CHECKPOINT_SELECTOR_SHA256 = digest("R1k-b3 checkpoint selector")
CHECKPOINT_SET_SHA256 = digest("R1k-b3 checkpoint set")
CHECKPOINT_STATE_SHA256 = digest("R1k-b3 checkpoint state")
SINK_SELECTOR_SHA256 = digest("R1k-b3 sink selector")
SINK_LEDGER_SHA256 = digest("R1k-b3 sink ledger")
SINK_IMPLEMENTATION_SHA256 = digest("R1k-b3 sink implementation")
SINK_INSTANCE_SHA256 = digest("R1k-b3 sink instance")


def acknowledgement_chain(
    *,
    initial_sequence: int,
    tokens: tuple[int, ...],
) -> tuple[committed.DecodedAcknowledgementV1, ...]:
    previous_acknowledgement = committed.ZERO_DIGEST
    previous_prefix = committed.ZERO_DIGEST
    acknowledgements: list[committed.DecodedAcknowledgementV1] = []
    for index, token in enumerate(tokens):
        sequence = initial_sequence + index
        acknowledgement_sha256 = digest(f"acknowledgement:{sequence}:{token}:{index}")
        result_sink_prefix_sha256 = digest(f"sink-prefix:{sequence}:{token}:{index}")
        acknowledgements.append(
            committed.DecodedAcknowledgementV1(
                request_epoch=REQUEST_EPOCH,
                transaction_sequence=sequence,
                token_id=token,
                application_ordinal=index + 1,
                application_count=1,
                request_sha256=REQUEST_SHA256,
                sink_implementation_sha256=SINK_IMPLEMENTATION_SHA256,
                sink_instance_sha256=SINK_INSTANCE_SHA256,
                predecessor_acknowledgement_sha256=(previous_acknowledgement),
                predecessor_sink_prefix_sha256=previous_prefix,
                result_sink_prefix_sha256=result_sink_prefix_sha256,
                acknowledgement_sha256=acknowledgement_sha256,
            )
        )
        previous_acknowledgement = acknowledgement_sha256
        previous_prefix = result_sink_prefix_sha256
    return tuple(acknowledgements)


def ledger_for_tokens(
    *,
    initial_sequence: int,
    tokens: tuple[int, ...],
) -> committed.DecodedSinkLedgerV1:
    acknowledgements = acknowledgement_chain(
        initial_sequence=initial_sequence,
        tokens=tokens,
    )
    return committed.DecodedSinkLedgerV1(
        request_epoch=REQUEST_EPOCH,
        initial_sequence=initial_sequence,
        next_sequence=initial_sequence + len(tokens),
        request_sha256=REQUEST_SHA256,
        sink_implementation_sha256=SINK_IMPLEMENTATION_SHA256,
        sink_instance_sha256=SINK_INSTANCE_SHA256,
        selector_sha256=SINK_SELECTOR_SHA256,
        ledger_sha256=SINK_LEDGER_SHA256,
        acknowledgements=acknowledgements,
        last_acknowledgement_sha256=(
            acknowledgements[-1].acknowledgement_sha256
            if acknowledgements
            else committed.ZERO_DIGEST
        ),
        result_sink_prefix_sha256=(
            acknowledgements[-1].result_sink_prefix_sha256
            if acknowledgements
            else committed.ZERO_DIGEST
        ),
    )


def checkpoint_for_aligned(
    output_tokens: tuple[int, ...],
    ledger: committed.DecodedSinkLedgerV1,
) -> committed.VerifiedCheckpointOutputV1:
    return committed.VerifiedCheckpointOutputV1(
        generation=CHECKPOINT_GENERATION,
        terminal=False,
        request_epoch=REQUEST_EPOCH,
        next_sequence=len(output_tokens),
        sink_initial_sequence=ledger.initial_sequence,
        output_tokens=output_tokens,
        package_sha256=PACKAGE_SHA256,
        representation_sha256=REPRESENTATION_SHA256,
        input_archive_sha256=INPUT_ARCHIVE_SHA256,
        tokenizer_domain_sha256=TOKENIZER_DOMAIN_SHA256,
        tokenizer_behavior_sha256=TOKENIZER_BEHAVIOR_SHA256,
        tokenizer_config_sha256=TOKENIZER_CONFIG_SHA256,
        local_plan_sha256=LOCAL_PLAN_SHA256,
        request_sha256=REQUEST_SHA256,
        sink_implementation_sha256=SINK_IMPLEMENTATION_SHA256,
        sink_instance_sha256=SINK_INSTANCE_SHA256,
        head_acknowledgement_sha256=ledger.last_acknowledgement_sha256,
        result_sink_prefix_sha256=ledger.result_sink_prefix_sha256,
        checkpoint_selector_sha256=CHECKPOINT_SELECTOR_SHA256,
        checkpoint_set_sha256=CHECKPOINT_SET_SHA256,
        checkpoint_state_sha256=CHECKPOINT_STATE_SHA256,
    )


def aligned_case(
    output_tokens: tuple[int, ...],
    *,
    initial_sequence: int = 1,
) -> tuple[
    committed.VerifiedCheckpointOutputV1,
    committed.DecodedSinkLedgerV1,
]:
    ledger = ledger_for_tokens(
        initial_sequence=initial_sequence,
        tokens=output_tokens[initial_sequence:],
    )
    return checkpoint_for_aligned(output_tokens, ledger), ledger


def one_ahead_case(
    checkpoint_tokens: tuple[int, ...],
    extra_token: int,
    *,
    initial_sequence: int = 1,
) -> tuple[
    committed.VerifiedCheckpointOutputV1,
    committed.DecodedSinkLedgerV1,
]:
    ledger = ledger_for_tokens(
        initial_sequence=initial_sequence,
        tokens=checkpoint_tokens[initial_sequence:] + (extra_token,),
    )
    if len(ledger.acknowledgements) == 1:
        checkpoint_acknowledgement = committed.ZERO_DIGEST
        checkpoint_prefix = committed.ZERO_DIGEST
    else:
        checkpoint_acknowledgement = ledger.acknowledgements[-2].acknowledgement_sha256
        checkpoint_prefix = ledger.acknowledgements[-2].result_sink_prefix_sha256
    checkpoint = committed.VerifiedCheckpointOutputV1(
        generation=CHECKPOINT_GENERATION,
        terminal=False,
        request_epoch=REQUEST_EPOCH,
        next_sequence=len(checkpoint_tokens),
        sink_initial_sequence=initial_sequence,
        output_tokens=checkpoint_tokens,
        package_sha256=PACKAGE_SHA256,
        representation_sha256=REPRESENTATION_SHA256,
        input_archive_sha256=INPUT_ARCHIVE_SHA256,
        tokenizer_domain_sha256=TOKENIZER_DOMAIN_SHA256,
        tokenizer_behavior_sha256=TOKENIZER_BEHAVIOR_SHA256,
        tokenizer_config_sha256=TOKENIZER_CONFIG_SHA256,
        local_plan_sha256=LOCAL_PLAN_SHA256,
        request_sha256=REQUEST_SHA256,
        sink_implementation_sha256=SINK_IMPLEMENTATION_SHA256,
        sink_instance_sha256=SINK_INSTANCE_SHA256,
        head_acknowledgement_sha256=checkpoint_acknowledgement,
        result_sink_prefix_sha256=checkpoint_prefix,
        checkpoint_selector_sha256=CHECKPOINT_SELECTOR_SHA256,
        checkpoint_set_sha256=CHECKPOINT_SET_SHA256,
        checkpoint_state_sha256=CHECKPOINT_STATE_SHA256,
    )
    return checkpoint, ledger


class ReconciliationTests(unittest.TestCase):
    def test_aligned_ledger_reconciles_exact_checkpoint_bytes(self) -> None:
        tokens = tuple("Ice ❄".encode("utf-8"))
        checkpoint, ledger = aligned_case(tokens, initial_sequence=3)

        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        self.assertEqual(view.sequence_state, committed.ALIGNED)
        self.assertEqual(view.visible_tokens, tokens)
        self.assertEqual(view.visible_bytes, b"Ice \xe2\x9d\x84")
        self.assertEqual(
            view.visible_bytes_sha256,
            hashlib.sha256(
                committed.COMMITTED_OUTPUT_BYTES_DOMAIN
                + struct.pack("<Q", len(view.visible_bytes))
                + view.visible_bytes
            ).digest(),
        )
        canonical_tokens = b"".join(struct.pack("<I", token) for token in tokens)
        self.assertEqual(
            view.visible_tokens_sha256,
            hashlib.sha256(
                committed.COMMITTED_OUTPUT_TOKEN_DOMAIN
                + struct.pack("<Q", len(tokens))
                + canonical_tokens
            ).digest(),
        )
        self.assertTrue(view.utf8_valid)
        self.assertEqual(view.utf8_text, "Ice ❄")
        self.assertEqual(view.visible_next_sequence, len(tokens))
        self.assertEqual(
            view.head_acknowledgement_sha256,
            ledger.last_acknowledgement_sha256,
        )

    def test_one_ahead_ledger_extends_exact_checkpoint_head(self) -> None:
        checkpoint, ledger = one_ahead_case((73, 99, 101), 33)

        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        self.assertEqual(view.sequence_state, committed.SINK_ONE_AHEAD)
        self.assertEqual(view.visible_tokens, (73, 99, 101, 33))
        self.assertEqual(view.visible_bytes, b"Ice!")
        self.assertEqual(view.checkpoint_next_sequence, 3)
        self.assertEqual(view.visible_next_sequence, 4)
        self.assertEqual(view.utf8_text, "Ice!")

    def test_one_ahead_accepts_first_sink_ack_after_checkpoint_prefix(self) -> None:
        checkpoint, ledger = one_ahead_case(
            (73, 99, 101),
            33,
            initial_sequence=3,
        )

        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        self.assertEqual(view.visible_bytes, b"Ice!")
        self.assertEqual(view.acknowledgement_count, 1)
        self.assertEqual(
            checkpoint.head_acknowledgement_sha256,
            committed.ZERO_DIGEST,
        )

    def test_terminal_requires_alignment_and_acknowledged_output(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101, 33))
        terminal = replace(checkpoint, terminal=True)

        view = committed.reconcile_committed_output_v1(terminal, ledger)

        self.assertTrue(view.terminal)
        self.assertFalse(view.checkpoint_pending)

        ahead_checkpoint, ahead_ledger = one_ahead_case((73, 99, 101), 33)
        with self.assertRaisesRegex(
            committed.SequenceMismatch,
            "terminal checkpoint is not sink aligned",
        ):
            committed.reconcile_committed_output_v1(
                replace(ahead_checkpoint, terminal=True),
                ahead_ledger,
            )

        empty_checkpoint, empty_ledger = aligned_case(
            (73, 99, 101),
            initial_sequence=3,
        )
        with self.assertRaisesRegex(
            committed.AcknowledgementMismatch,
            "terminal checkpoint has no acknowledged output",
        ):
            committed.reconcile_committed_output_v1(
                replace(empty_checkpoint, terminal=True),
                empty_ledger,
            )

    def test_aligned_empty_ledger_accepts_process_local_prefix(self) -> None:
        tokens = (73, 99, 101)
        checkpoint, ledger = aligned_case(tokens, initial_sequence=len(tokens))

        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        self.assertEqual(view.visible_bytes, b"Ice")
        self.assertEqual(view.acknowledgement_count, 0)
        self.assertEqual(
            view.head_acknowledgement_sha256,
            committed.ZERO_DIGEST,
        )

    def test_view_root_is_exact_zig_golden_binary_commitment(self) -> None:
        checkpoint, ledger = one_ahead_case((73, 99, 101), 33)
        view = committed.reconcile_committed_output_v1(checkpoint, ledger)
        state_code = 2
        body = (
            struct.pack(
                "<QQQQQQQQQQ",
                committed.COMMITTED_OUTPUT_VIEW_ABI,
                state_code,
                0,
                CHECKPOINT_GENERATION,
                REQUEST_EPOCH,
                ledger.initial_sequence,
                checkpoint.next_sequence,
                ledger.next_sequence,
                len(ledger.acknowledgements),
                len(view.visible_bytes),
            )
            + PACKAGE_SHA256
            + REPRESENTATION_SHA256
            + INPUT_ARCHIVE_SHA256
            + TOKENIZER_DOMAIN_SHA256
            + TOKENIZER_BEHAVIOR_SHA256
            + TOKENIZER_CONFIG_SHA256
            + LOCAL_PLAN_SHA256
            + REQUEST_SHA256
            + CHECKPOINT_SELECTOR_SHA256
            + CHECKPOINT_SET_SHA256
            + CHECKPOINT_STATE_SHA256
            + SINK_SELECTOR_SHA256
            + SINK_LEDGER_SHA256
            + SINK_IMPLEMENTATION_SHA256
            + SINK_INSTANCE_SHA256
            + ledger.last_acknowledgement_sha256
            + ledger.result_sink_prefix_sha256
            + view.visible_tokens_sha256
            + view.visible_bytes_sha256
        )
        expected = hashlib.sha256(
            committed.COMMITTED_OUTPUT_VIEW_DOMAIN + body
        ).digest()

        self.assertEqual(view.view_sha256, expected)
        self.assertEqual(
            view.view_sha256.hex(),
            "1bc766c0e45628814d661993f61602b466c0b91c389f84985f733d843d079567",
        )
        self.assertNotEqual(
            view.view_sha256,
            hashlib.sha256(view.visible_bytes).digest(),
        )

    def test_terminal_toggle_changes_full_view_root(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101, 33))

        nonterminal = committed.reconcile_committed_output_v1(
            checkpoint,
            ledger,
        )
        terminal = committed.reconcile_committed_output_v1(
            replace(checkpoint, terminal=True),
            ledger,
        )

        self.assertEqual(nonterminal.visible_bytes, terminal.visible_bytes)
        self.assertNotEqual(nonterminal.view_sha256, terminal.view_sha256)

    def test_context_and_selected_root_toggles_change_full_view_root(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101, 33))
        baseline = committed.reconcile_committed_output_v1(checkpoint, ledger)
        mutations = (
            (
                replace(
                    checkpoint,
                    package_sha256=digest("foreign package"),
                ),
                ledger,
            ),
            (
                replace(
                    checkpoint,
                    checkpoint_selector_sha256=digest("foreign checkpoint selector"),
                ),
                ledger,
            ),
            (
                checkpoint,
                replace(
                    ledger,
                    selector_sha256=digest("foreign sink selector"),
                ),
            ),
        )

        for changed_checkpoint, changed_ledger in mutations:
            with self.subTest(
                checkpoint=changed_checkpoint,
                ledger=changed_ledger,
            ):
                changed = committed.reconcile_committed_output_v1(
                    changed_checkpoint,
                    changed_ledger,
                )
                self.assertEqual(changed.visible_bytes, baseline.visible_bytes)
                self.assertNotEqual(changed.view_sha256, baseline.view_sha256)

    def test_same_bytes_in_aligned_and_one_ahead_views_have_distinct_roots(
        self,
    ) -> None:
        aligned_checkpoint, aligned_ledger = aligned_case((73, 99, 101, 33))
        ahead_checkpoint, ahead_ledger = one_ahead_case((73, 99, 101), 33)

        aligned = committed.reconcile_committed_output_v1(
            aligned_checkpoint,
            aligned_ledger,
        )
        ahead = committed.reconcile_committed_output_v1(
            ahead_checkpoint,
            ahead_ledger,
        )

        self.assertEqual(aligned.visible_bytes, ahead.visible_bytes)
        self.assertEqual(
            aligned.visible_bytes_sha256,
            ahead.visible_bytes_sha256,
        )
        self.assertEqual(
            aligned.visible_tokens_sha256,
            ahead.visible_tokens_sha256,
        )
        self.assertNotEqual(aligned.view_sha256, ahead.view_sha256)


class DisclosurePolicyTests(unittest.TestCase):
    def test_default_document_never_contains_output_payload_fields(self) -> None:
        checkpoint, ledger = aligned_case((84, 120, 219, 105))
        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        document = committed.committed_output_document_v1(view)
        encoded = committed.encode_committed_output_document_v1(view)

        self.assertEqual(
            document["schema"],
            "glacier.prepared-text-committed-output-oracle/v1",
        )
        self.assertEqual(document["milestone"], "R1k-b3")
        self.assertFalse(document["output_disclosed"])
        self.assertFalse(document["wire_bytes_verified"])
        self.assertTrue(document["read_only"])
        self.assertFalse(document["authority"])
        self.assertNotIn("authority_granted", document)
        self.assertEqual(
            document["checkpoint_generation"],
            CHECKPOINT_GENERATION,
        )
        expected_roots = {
            "package_sha256": PACKAGE_SHA256,
            "representation_sha256": REPRESENTATION_SHA256,
            "input_archive_sha256": INPUT_ARCHIVE_SHA256,
            "tokenizer_domain_sha256": TOKENIZER_DOMAIN_SHA256,
            "tokenizer_behavior_sha256": TOKENIZER_BEHAVIOR_SHA256,
            "tokenizer_config_sha256": TOKENIZER_CONFIG_SHA256,
            "local_plan_sha256": LOCAL_PLAN_SHA256,
            "request_sha256": REQUEST_SHA256,
            "checkpoint_selector_sha256": CHECKPOINT_SELECTOR_SHA256,
            "checkpoint_set_sha256": CHECKPOINT_SET_SHA256,
            "checkpoint_state_sha256": CHECKPOINT_STATE_SHA256,
            "sink_selector_sha256": SINK_SELECTOR_SHA256,
            "sink_ledger_sha256": SINK_LEDGER_SHA256,
            "sink_implementation_sha256": SINK_IMPLEMENTATION_SHA256,
            "sink_instance_sha256": SINK_INSTANCE_SHA256,
        }
        for name, root in expected_roots.items():
            with self.subTest(root=name):
                self.assertEqual(document[name], root.hex())
        self.assertNotIn("output", document)
        for forbidden in (
            b"token_ids",
            b"bytes_hex",
            b"escaped_bytes",
            b"utf8_text",
            b"5478db69",
        ):
            self.assertNotIn(forbidden, encoded)
        self.assertTrue(encoded.endswith(b"\n"))
        self.assertEqual(encoded.count(b"\n"), 1)

    def test_reveal_document_includes_every_lossless_representation(self) -> None:
        raw = b'A"\\\n\xe2\x9d\x84'
        checkpoint, ledger = aligned_case(
            tuple(raw),
            initial_sequence=len(raw),
        )
        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        document = committed.committed_output_document_v1(
            view,
            reveal_output=True,
        )

        self.assertTrue(document["output_disclosed"])
        output = document["output"]
        self.assertIsInstance(output, dict)
        assert isinstance(output, dict)
        self.assertEqual(output["token_ids"], list(raw))
        self.assertEqual(output["bytes_hex"], raw.hex())
        self.assertEqual(
            output["escaped_bytes"],
            'A"\\\\\\x0a\\xe2\\x9d\\x84',
        )
        self.assertEqual(output["utf8_text"], 'A"\\\n❄')
        self.assertTrue(document["output_utf8_valid"])

    def test_invalid_utf8_is_lossless_and_never_replacement_decoded(self) -> None:
        tokens = (84, 120, 219, 105)
        checkpoint, ledger = aligned_case(tokens)
        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        document = committed.committed_output_document_v1(
            view,
            reveal_output=True,
        )
        output = document["output"]
        assert isinstance(output, dict)

        self.assertFalse(view.utf8_valid)
        self.assertIsNone(view.utf8_text)
        self.assertFalse(document["output_utf8_valid"])
        self.assertEqual(output["token_ids"], list(tokens))
        self.assertEqual(output["bytes_hex"], "5478db69")
        self.assertEqual(output["escaped_bytes"], r"Tx\xdbi")
        self.assertIsNone(output["utf8_text"])
        self.assertNotIn("\ufffd", output["escaped_bytes"])

    def test_escaped_bytes_cover_control_quote_slash_and_high_byte(self) -> None:
        value = b'\x00\t\n\r"\\ ~\xff'
        self.assertEqual(
            committed.escape_visible_bytes_v1(value),
            r'\x00\x09\x0a\x0d"\\ ~\xff',
        )

    def test_renderer_is_deterministic_and_round_trips_json(self) -> None:
        checkpoint, ledger = aligned_case(tuple("สวัสดี".encode("utf-8")))
        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        first = committed.encode_committed_output_document_v1(
            view,
            reveal_output=True,
        )
        second = committed.encode_committed_output_document_v1(
            view,
            reveal_output=True,
        )
        decoded = json.loads(first)

        self.assertEqual(first, second)
        self.assertEqual(decoded["output"]["utf8_text"], "สวัสดี")
        self.assertEqual(decoded["output"]["bytes_hex"], view.visible_bytes.hex())


class SequenceRejectionTests(unittest.TestCase):
    def test_rejects_sink_rollback(self) -> None:
        checkpoint, _ = aligned_case((73, 99, 101, 33))
        rolled_back = ledger_for_tokens(
            initial_sequence=1,
            tokens=(99, 101),
        )

        with self.assertRaisesRegex(
            committed.SequenceMismatch,
            "rolled back",
        ):
            committed.reconcile_committed_output_v1(checkpoint, rolled_back)

    def test_rejects_sink_more_than_one_ahead(self) -> None:
        checkpoint, _ = aligned_case((73, 99, 101), initial_sequence=3)
        ahead = ledger_for_tokens(
            initial_sequence=3,
            tokens=(33, 63),
        )

        with self.assertRaisesRegex(
            committed.SequenceMismatch,
            "more than one",
        ):
            committed.reconcile_committed_output_v1(checkpoint, ahead)

    def test_rejects_foreign_sink_initial_even_if_position_is_one_ahead(
        self,
    ) -> None:
        checkpoint, _ = aligned_case((73, 99, 101), initial_sequence=3)
        gap = ledger_for_tokens(initial_sequence=4, tokens=())

        with self.assertRaisesRegex(
            committed.IdentityMismatch,
            "sink initial sequence is foreign",
        ):
            committed.reconcile_committed_output_v1(checkpoint, gap)

    def test_rejects_ledger_count_gap(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        malformed = replace(
            ledger,
            acknowledgements=ledger.acknowledgements[:-1],
        )

        with self.assertRaisesRegex(
            committed.SequenceMismatch,
            "count leaves a sequence gap",
        ):
            committed.reconcile_committed_output_v1(checkpoint, malformed)

    def test_rejects_acknowledgement_transaction_gap(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        acknowledgements = list(ledger.acknowledgements)
        acknowledgements[1] = replace(
            acknowledgements[1],
            transaction_sequence=4,
        )
        malformed = replace(
            ledger,
            acknowledgements=tuple(acknowledgements),
        )

        with self.assertRaisesRegex(
            committed.SequenceMismatch,
            "transaction sequence gap",
        ):
            committed.reconcile_committed_output_v1(checkpoint, malformed)

    def test_rejects_checkpoint_output_length_gap(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        malformed = replace(checkpoint, next_sequence=4)

        with self.assertRaisesRegex(
            committed.SequenceMismatch,
            "checkpoint output leaves a sequence gap",
        ):
            committed.reconcile_committed_output_v1(malformed, ledger)


class IdentityAndChainRejectionTests(unittest.TestCase):
    def test_rejects_each_foreign_ledger_identity(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        mutations = {
            "request epoch": {"request_epoch": REQUEST_EPOCH + 1},
            "request root": {"request_sha256": digest("foreign request")},
            "sink implementation": {
                "sink_implementation_sha256": digest("foreign implementation")
            },
            "sink instance": {"sink_instance_sha256": digest("foreign instance")},
        }
        for label, changes in mutations.items():
            with self.subTest(label=label):
                with self.assertRaisesRegex(
                    committed.IdentityMismatch,
                    "foreign",
                ):
                    committed.reconcile_committed_output_v1(
                        checkpoint,
                        replace(ledger, **changes),
                    )

    def test_rejects_each_foreign_acknowledgement_identity(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        mutations = {
            "request epoch": {"request_epoch": REQUEST_EPOCH + 1},
            "request root": {"request_sha256": digest("foreign request")},
            "sink implementation": {
                "sink_implementation_sha256": digest("foreign implementation")
            },
            "sink instance": {"sink_instance_sha256": digest("foreign instance")},
        }
        for label, changes in mutations.items():
            with self.subTest(label=label):
                acknowledgements = list(ledger.acknowledgements)
                acknowledgements[0] = replace(
                    acknowledgements[0],
                    **changes,
                )
                malformed = replace(
                    ledger,
                    acknowledgements=tuple(acknowledgements),
                )
                with self.assertRaisesRegex(
                    committed.IdentityMismatch,
                    "foreign",
                ):
                    committed.reconcile_committed_output_v1(
                        checkpoint,
                        malformed,
                    )

    def test_rejects_both_acknowledgement_predecessor_chain_mutations(
        self,
    ) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101, 33))
        for field in (
            "predecessor_acknowledgement_sha256",
            "predecessor_sink_prefix_sha256",
        ):
            with self.subTest(field=field):
                acknowledgements = list(ledger.acknowledgements)
                acknowledgements[1] = replace(
                    acknowledgements[1],
                    **{field: digest(f"foreign {field}")},
                )
                malformed = replace(
                    ledger,
                    acknowledgements=tuple(acknowledgements),
                )
                with self.assertRaisesRegex(
                    committed.AcknowledgementMismatch,
                    "predecessor",
                ):
                    committed.reconcile_committed_output_v1(
                        checkpoint,
                        malformed,
                    )

    def test_rejects_both_ledger_head_mutations(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        for field in (
            "last_acknowledgement_sha256",
            "result_sink_prefix_sha256",
        ):
            with self.subTest(field=field):
                malformed = replace(
                    ledger,
                    **{field: digest(f"foreign {field}")},
                )
                with self.assertRaisesRegex(
                    committed.AcknowledgementMismatch,
                    "head mismatches",
                ):
                    committed.reconcile_committed_output_v1(
                        checkpoint,
                        malformed,
                    )

    def test_rejects_aligned_checkpoint_head_mismatch(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        malformed = replace(
            checkpoint,
            head_acknowledgement_sha256=digest("foreign checkpoint head"),
        )

        with self.assertRaisesRegex(
            committed.AcknowledgementMismatch,
            "aligned checkpoint acknowledgement head",
        ):
            committed.reconcile_committed_output_v1(malformed, ledger)

    def test_rejects_one_ahead_extension_of_foreign_checkpoint_head(self) -> None:
        checkpoint, ledger = one_ahead_case((73, 99, 101), 33)
        malformed = replace(
            checkpoint,
            head_acknowledgement_sha256=digest("foreign checkpoint head"),
            result_sink_prefix_sha256=digest("foreign checkpoint prefix"),
        )

        with self.assertRaisesRegex(
            committed.AcknowledgementMismatch,
            "does not extend",
        ):
            committed.reconcile_committed_output_v1(malformed, ledger)

    def test_rejects_partial_zero_checkpoint_and_ledger_heads(self) -> None:
        checkpoint, ledger = aligned_case(
            (73, 99, 101),
            initial_sequence=3,
        )
        bad_checkpoint = replace(
            checkpoint,
            head_acknowledgement_sha256=digest("only checkpoint ack"),
        )
        bad_ledger = replace(
            ledger,
            last_acknowledgement_sha256=digest("only ledger ack"),
        )
        for value_checkpoint, value_ledger, label in (
            (bad_checkpoint, ledger, "checkpoint"),
            (checkpoint, bad_ledger, "ledger"),
        ):
            with self.subTest(label=label):
                with self.assertRaisesRegex(
                    committed.AcknowledgementMismatch,
                    "partially zero",
                ):
                    committed.reconcile_committed_output_v1(
                        value_checkpoint,
                        value_ledger,
                    )


class TokenRejectionTests(unittest.TestCase):
    def test_rejects_checkpoint_token_above_byte_range(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        malformed = replace(
            checkpoint,
            output_tokens=(73, 99, 256),
        )

        with self.assertRaisesRegex(
            committed.OutputTokenError,
            "outside the byte-token range",
        ):
            committed.reconcile_committed_output_v1(malformed, ledger)

    def test_rejects_boolean_checkpoint_token(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        malformed = replace(
            checkpoint,
            output_tokens=(73, True, 101),
        )

        with self.assertRaises(committed.OutputTokenError):
            committed.reconcile_committed_output_v1(malformed, ledger)

    def test_rejects_acknowledgement_token_above_byte_range(self) -> None:
        checkpoint, ledger = one_ahead_case((73, 99, 101), 33)
        acknowledgements = list(ledger.acknowledgements)
        acknowledgements[-1] = replace(
            acknowledgements[-1],
            token_id=256,
        )
        malformed = replace(
            ledger,
            acknowledgements=tuple(acknowledgements),
        )

        with self.assertRaisesRegex(
            committed.OutputTokenError,
            "outside the byte-token range",
        ):
            committed.reconcile_committed_output_v1(checkpoint, malformed)

    def test_rejects_acknowledged_token_different_from_checkpoint(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        acknowledgements = list(ledger.acknowledgements)
        acknowledgements[0] = replace(
            acknowledgements[0],
            token_id=120,
        )
        malformed = replace(
            ledger,
            acknowledgements=tuple(acknowledgements),
        )

        with self.assertRaisesRegex(
            committed.AcknowledgementMismatch,
            "differs from checkpoint output",
        ):
            committed.reconcile_committed_output_v1(checkpoint, malformed)

    def test_rejects_output_above_retained_terminal_limit(self) -> None:
        tokens = (65,) * (committed.MAXIMUM_VISIBLE_TOKENS + 1)
        checkpoint = committed.VerifiedCheckpointOutputV1(
            generation=CHECKPOINT_GENERATION,
            terminal=False,
            request_epoch=REQUEST_EPOCH,
            next_sequence=len(tokens),
            sink_initial_sequence=len(tokens),
            output_tokens=tokens,
            package_sha256=PACKAGE_SHA256,
            representation_sha256=REPRESENTATION_SHA256,
            input_archive_sha256=INPUT_ARCHIVE_SHA256,
            tokenizer_domain_sha256=TOKENIZER_DOMAIN_SHA256,
            tokenizer_behavior_sha256=TOKENIZER_BEHAVIOR_SHA256,
            tokenizer_config_sha256=TOKENIZER_CONFIG_SHA256,
            local_plan_sha256=LOCAL_PLAN_SHA256,
            request_sha256=REQUEST_SHA256,
            sink_implementation_sha256=SINK_IMPLEMENTATION_SHA256,
            sink_instance_sha256=SINK_INSTANCE_SHA256,
            head_acknowledgement_sha256=committed.ZERO_DIGEST,
            result_sink_prefix_sha256=committed.ZERO_DIGEST,
            checkpoint_selector_sha256=CHECKPOINT_SELECTOR_SHA256,
            checkpoint_set_sha256=CHECKPOINT_SET_SHA256,
            checkpoint_state_sha256=CHECKPOINT_STATE_SHA256,
        )
        ledger = ledger_for_tokens(
            initial_sequence=len(tokens),
            tokens=(),
        )

        with self.assertRaisesRegex(
            committed.CommittedOutputError,
            "exceeds the retained limit",
        ):
            committed.reconcile_committed_output_v1(checkpoint, ledger)

    def test_rejects_non_boolean_reveal_policy(self) -> None:
        checkpoint, ledger = aligned_case((73, 99, 101))
        view = committed.reconcile_committed_output_v1(checkpoint, ledger)

        with self.assertRaisesRegex(
            committed.CommittedOutputError,
            "reveal_output is not boolean",
        ):
            committed.committed_output_document_v1(
                view,
                reveal_output=1,  # type: ignore[arg-type]
            )


if __name__ == "__main__":
    unittest.main()
