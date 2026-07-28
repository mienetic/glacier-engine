from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import textwrap
import unittest

from bench import prepared_text_recovery_campaign as campaign
from bench import prepared_text_result_sink as reference_sink


class CrashWorkerProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.worker = Path(self.temporary.name) / "fake_recovery_worker.py"
        self.worker.write_text(
            textwrap.dedent(
                """\
                import json
                import os
                import signal
                import sys

                behavior = sys.argv[1]
                point = sys.argv[2]
                generation = int(sys.argv[3])
                sequence = int(sys.argv[4])
                if behavior == "result-normal":
                    result = {
                        "schema": "glacier.prepared-text-recovery/result-v1",
                        "mode": "target",
                        "pid": os.getpid(),
                        "input_generation": generation,
                        "input_sequence": sequence,
                        "output_generation": generation + 1,
                        "output_sequence": sequence + 1,
                        "sink_disposition": "applied",
                        "sink_count": sequence + 1,
                        "sink_next_sequence": sequence + 1,
                        "sink_ledger_sha256": "11" * 32,
                        "sink_selector_sha256": "22" * 32,
                        "checkpoint_selector_sha256": "33" * 32,
                        "terminal": False,
                        "ownership_zero": True,
                        "verified": True,
                        "output_tokens": [7, 11],
                        "terminal_semantic_sha256": None,
                    }
                    os.write(
                        sys.stdout.fileno(),
                        json.dumps(result, separators=(",", ":")).encode("ascii") + b"\\n",
                    )
                    raise SystemExit(0)
                if behavior == "silent-kill":
                    os.kill(os.getpid(), signal.SIGKILL)

                emitted_point = "after_sink_before_selector" if behavior == "wrong" else point
                frame = {
                    "schema": "glacier.prepared-text-recovery/crash-ready-v1",
                    "phase": "crash_ready",
                    "pid": os.getpid(),
                    "crash_point": emitted_point,
                    "input_generation": generation,
                    "input_sequence": sequence,
                    "sink_count": (
                        sequence
                        if behavior == "wrong-count"
                        else sequence - 1
                    ),
                    "sink_ledger_sha256": "11" * 32,
                    "sink_selector_sha256": "22" * 32,
                    "checkpoint_selector_sha256": "33" * 32,
                }
                encoded = json.dumps(frame, separators=(",", ":")).encode("ascii") + b"\\n"
                os.write(sys.stdout.fileno(), encoded)
                if behavior in ("good", "good-before-sink", "wrong"):
                    os.kill(os.getpid(), signal.SIGKILL)
                if behavior == "term":
                    os.kill(os.getpid(), signal.SIGTERM)
                if behavior == "normal":
                    raise SystemExit(0)
                raise SystemExit(91)
                """
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, behavior: str) -> tuple[str, ...]:
        return (
            sys.executable,
            str(self.worker),
            behavior,
            campaign.AFTER_STEP_BEFORE_SINK,
            "2",
            "1",
        )

    def run_crash(self, behavior: str) -> dict[str, object]:
        return campaign.run_crash_worker(
            self.command(behavior),
            expected_crash_point=campaign.AFTER_STEP_BEFORE_SINK,
            expected_generation=2,
            expected_sequence=1,
            timeout_seconds=3,
        )

    def test_exact_ready_frame_gates_real_sigkill(self) -> None:
        frame = self.run_crash("good")
        self.assertEqual(
            frame["crash_point"],
            campaign.AFTER_STEP_BEFORE_SINK,
        )
        self.assertEqual(frame["input_generation"], 2)
        self.assertEqual(frame["input_sequence"], 1)

    def test_ready_frame_accepts_pre_sink_empty_suffix(self) -> None:
        frame = self.run_crash("good-before-sink")
        self.assertEqual(frame["sink_count"], 0)

    def test_ready_frame_rejects_wrong_exact_sink_visibility(self) -> None:
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "sink visibility changed",
        ):
            self.run_crash("wrong-count")

    def test_sigkill_without_ready_frame_is_not_accepted(self) -> None:
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "without a JSON frame",
        ):
            self.run_crash("silent-kill")

    def test_wrong_ready_frame_is_rejected_before_death_is_accepted(self) -> None:
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "wrong crash point",
        ):
            self.run_crash("wrong")

    def test_normal_exit_after_ready_frame_is_not_a_crash(self) -> None:
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "did not terminate by SIGKILL",
        ):
            self.run_crash("normal")

    def test_normal_result_mode_requires_and_accepts_exit_zero(self) -> None:
        frame = campaign.run_result_worker(
            self.command("result-normal"),
            expected_mode="target",
            timeout_seconds=3,
        )
        self.assertEqual(frame["output_generation"], 3)
        self.assertEqual(frame["output_sequence"], 2)

    def test_only_sigkill_returncode_has_crash_semantics(self) -> None:
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "did not terminate by SIGKILL",
        ):
            self.run_crash("term")

    def test_crash_point_table_is_exact_and_unique(self) -> None:
        expected = (
            "bootstrap_checkpoint_archive_write",
            "bootstrap_checkpoint_archive_sync",
            "bootstrap_checkpoint_archive_directory_sync",
            "bootstrap_checkpoint_selector_write",
            "bootstrap_checkpoint_selector_sync",
            "bootstrap_checkpoint_selector_rename",
            "bootstrap_checkpoint_selector_directory_sync",
            "source_after_recovery_admission",
            "source_sink_ledger_body_write",
            "source_sink_ledger_body_sync",
            "source_sink_ledger_footer_write",
            "source_sink_ledger_file_sync",
            "source_sink_ledger_immutable_rename",
            "source_sink_ledger_directory_sync",
            "source_sink_selector_temp_write",
            "source_sink_selector_temp_sync",
            "source_sink_selector_replace",
            "source_sink_selector_directory_sync",
            "source_after_initial_sink",
            "source_after_step",
            "source_after_handoff_prepare",
            "source_after_exit_commit",
            "source_checkpoint_archive_write",
            "source_checkpoint_archive_sync",
            "source_checkpoint_archive_directory_sync",
            "source_checkpoint_selector_write",
            "source_checkpoint_selector_sync",
            "source_checkpoint_selector_rename",
            "source_checkpoint_selector_directory_sync",
            "source_after_generation_two",
            "after_step_before_sink",
            "sink_ledger_body_write",
            "sink_ledger_body_sync",
            "sink_ledger_footer_write",
            "sink_ledger_file_sync",
            "sink_ledger_immutable_rename",
            "sink_ledger_directory_sync",
            "sink_selector_temp_write",
            "sink_selector_temp_sync",
            "sink_selector_replace",
            "sink_selector_directory_sync",
            "after_sink_before_selector",
            "checkpoint_archive_write",
            "checkpoint_archive_sync",
            "checkpoint_archive_directory_sync",
            "checkpoint_selector_write",
            "checkpoint_selector_sync",
            "checkpoint_selector_rename",
            "checkpoint_selector_directory_sync",
        )
        self.assertEqual(campaign.CRASH_POINTS, expected)
        self.assertEqual(len(set(campaign.CRASH_POINTS)), 49)
        self.assertEqual(len(campaign.BOOTSTRAP_CHECKPOINT_PHASES), 7)
        self.assertEqual(len(campaign.SOURCE_CRASH_POINTS), 23)
        self.assertEqual(len(campaign.TARGET_CRASH_POINTS), 19)
        self.assertEqual(
            campaign.BOOTSTRAP_CHECKPOINT_SELECTED_POINTS,
            frozenset(campaign.BOOTSTRAP_CHECKPOINT_PHASES[-2:]),
        )
        self.assertEqual(len(campaign.BOOTSTRAP_CHECKPOINT_SELECTED_POINTS), 2)
        self.assertEqual(
            campaign.SOURCE_SINK_SELECTED_POINTS,
            frozenset(campaign.SOURCE_CRASH_POINTS[9:]),
        )
        self.assertEqual(len(campaign.SOURCE_SINK_SELECTED_POINTS), 14)
        self.assertEqual(
            campaign.SOURCE_CHECKPOINT_GENERATION_TWO_POINTS,
            frozenset(campaign.SOURCE_CRASH_POINTS[20:]),
        )
        self.assertEqual(
            len(campaign.SOURCE_CHECKPOINT_GENERATION_TWO_POINTS),
            3,
        )
        self.assertEqual(
            campaign.SINK_SUCCESSOR_VISIBLE_POINTS,
            frozenset(
                {
                    "sink_selector_replace",
                    "sink_selector_directory_sync",
                    "after_sink_before_selector",
                    *campaign.CHECKPOINT_PHASES,
                }
            ),
        )
        self.assertEqual(
            campaign.CHECKPOINT_SUCCESSOR_VISIBLE_POINTS,
            frozenset(
                {
                    "checkpoint_selector_rename",
                    "checkpoint_selector_directory_sync",
                }
            ),
        )


class ReadyVisibilityTests(unittest.TestCase):
    def frame(
        self,
        *,
        point: str,
        generation: int,
        sequence: int,
        sink_count: int,
        sink_selected: bool,
        checkpoint_selected: bool,
    ) -> dict[str, object]:
        zero = "0" * 64
        return {
            "schema": campaign.CRASH_READY_SCHEMA,
            "phase": "crash_ready",
            "pid": 101,
            "crash_point": point,
            "input_generation": generation,
            "input_sequence": sequence,
            "sink_count": sink_count,
            "sink_ledger_sha256": "11" * 32 if sink_selected else zero,
            "sink_selector_sha256": "22" * 32 if sink_selected else zero,
            "checkpoint_selector_sha256": (
                "33" * 32 if checkpoint_selected else zero
            ),
        }

    def validate(
        self,
        frame: dict[str, object],
        *,
        generation: int,
        sequence: int,
    ) -> None:
        campaign._validate_ready_frame(
            frame,
            expected_crash_point=str(frame["crash_point"]),
            expected_generation=generation,
            expected_sequence=sequence,
        )

    def test_bootstrap_accepts_absent_then_selected_checkpoint(self) -> None:
        before = self.frame(
            point="bootstrap_checkpoint_selector_sync",
            generation=0,
            sequence=0,
            sink_count=0,
            sink_selected=False,
            checkpoint_selected=False,
        )
        self.validate(before, generation=0, sequence=0)
        after = self.frame(
            point="bootstrap_checkpoint_selector_rename",
            generation=0,
            sequence=0,
            sink_count=0,
            sink_selected=False,
            checkpoint_selected=True,
        )
        self.validate(after, generation=0, sequence=0)

    def test_source_accepts_absent_then_exact_empty_sink(self) -> None:
        before = self.frame(
            point="source_sink_selector_temp_sync",
            generation=1,
            sequence=1,
            sink_count=0,
            sink_selected=False,
            checkpoint_selected=True,
        )
        self.validate(before, generation=1, sequence=1)
        after = self.frame(
            point="source_sink_selector_replace",
            generation=1,
            sequence=1,
            sink_count=0,
            sink_selected=True,
            checkpoint_selected=True,
        )
        self.validate(after, generation=1, sequence=1)

    def test_source_rejects_zero_selected_checkpoint(self) -> None:
        frame = self.frame(
            point="source_after_generation_two",
            generation=1,
            sequence=1,
            sink_count=0,
            sink_selected=True,
            checkpoint_selected=False,
        )
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "selector visibility changed",
        ):
            self.validate(frame, generation=1, sequence=1)


class WireFrameCouplingTests(unittest.TestCase):
    def frame(
        self,
        *,
        generation: int,
        sequence: int,
        count: int,
        tokens: list[int],
    ) -> dict[str, object]:
        return {
            "sink_count": count,
            "sink_next_sequence": sequence,
            "sink_ledger_sha256": "11" * 32,
            "sink_selector_sha256": "22" * 32,
            "checkpoint_selector_sha256": "33" * 32,
            "output_generation": generation,
            "output_sequence": sequence,
            "output_tokens": tokens,
        }

    def wire(
        self,
        *,
        generation: int,
        sequence: int,
        acknowledged: tuple[int, ...],
        terminal: tuple[int, ...] | None,
    ) -> campaign.WireFacts:
        return campaign.WireFacts(
            sink=campaign.SinkWireFacts(
                generation=len(acknowledged) + 1,
                count=len(acknowledged),
                initial_sequence=1,
                next_sequence=sequence,
                request_epoch=9,
                request_sha256="88" * 32,
                sink_implementation_sha256="99" * 32,
                sink_instance_sha256="aa" * 32,
                previous_selector_sha256="77" * 32,
                ledger_sha256="11" * 32,
                selector_sha256="22" * 32,
                acknowledgement_tokens=acknowledged,
            ),
            checkpoint=campaign.CheckpointWireFacts(
                generation=generation,
                request_epoch=9,
                next_sequence=sequence,
                parent_checkpoint_sha256="44" * 32,
                checkpoint_sha256="44" * 32,
                challenge_sha256="55" * 32,
                previous_selector_sha256="66" * 32,
                selector_sha256="33" * 32,
                objects=(),
                terminal_tokens=terminal,
            ),
        )

    def test_source_full_output_can_precede_empty_sink_suffix(self) -> None:
        campaign._require_frame_matches_wire(
            self.frame(generation=2, sequence=1, count=0, tokens=[7]),
            self.wire(
                generation=2,
                sequence=1,
                acknowledged=(),
                terminal=None,
            ),
        )

    def test_terminal_full_output_contains_three_acknowledged_results(self) -> None:
        tokens = (7, 11, 13, 17)
        campaign._require_frame_matches_wire(
            self.frame(
                generation=5,
                sequence=4,
                count=3,
                tokens=list(tokens),
            ),
            self.wire(
                generation=5,
                sequence=4,
                acknowledged=tokens[1:],
                terminal=tokens,
            ),
        )

    def test_pid_reuse_is_rejected(self) -> None:
        observed: set[int] = set()
        campaign._record_distinct_pid({"pid": 101}, observed, "source")
        with self.assertRaisesRegex(campaign.CampaignError, "PID was reused"):
            campaign._record_distinct_pid({"pid": 101}, observed, "audit")

    def test_coherently_rehashed_wrong_delivery_key_is_rejected(self) -> None:
        def digest(label: str) -> bytes:
            return hashlib.sha256(label.encode("ascii")).digest()

        encoded = reference_sink.encode_acknowledgement_v1(
            request_sha256=digest("request"),
            request_epoch=71,
            transaction_sequence=1,
            token_id=19,
            proposal_sha256=digest("proposal"),
            transition_sha256=digest("transition"),
            commit_receipt_sha256=digest("receipt"),
            sink_implementation_sha256=digest("implementation"),
            sink_instance_sha256=digest("instance"),
            application_ordinal=1,
        )
        campaign._validate_acknowledgement_derived_roots(encoded)

        mutated = bytearray(encoded)
        mutated[264] ^= 0x01
        request_epoch = struct.unpack_from("<Q", mutated, 32)[0]
        sequence = struct.unpack_from("<Q", mutated, 40)[0]
        token_id = struct.unpack_from("<Q", mutated, 48)[0]
        ordinal = struct.unpack_from("<Q", mutated, 56)[0]
        count = struct.unpack_from("<Q", mutated, 64)[0]
        mutated[360:392] = hashlib.sha256(
            campaign.SINK_PREFIX_DOMAIN
            + struct.pack(
                "<QQQQQQ",
                campaign.ACK_ABI,
                request_epoch,
                sequence,
                token_id,
                ordinal,
                count,
            )
            + mutated[72:360]
        ).digest()
        mutated[392:424] = hashlib.sha256(campaign.ACK_DOMAIN + mutated[:392]).digest()
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "delivery key mismatch",
        ):
            campaign._validate_acknowledgement_derived_roots(bytes(mutated))

    def test_coherently_rerooted_one_ahead_selector_parent_is_rejected(
        self,
    ) -> None:
        def digest(label: str) -> bytes:
            return hashlib.sha256(label.encode("ascii")).digest()

        contract = campaign._decode_source_replay_contract(
            SourceReplayContractTests().contract()
        )
        request = contract.plan_sha256
        request_epoch = contract.request_epoch
        initial_sequence = contract.sink_initial_sequence
        implementation = contract.sink_implementation_sha256
        instance = contract.sink_instance_sha256
        acknowledgement = reference_sink.encode_acknowledgement_v1(
            request_sha256=request,
            request_epoch=request_epoch,
            transaction_sequence=initial_sequence,
            token_id=19,
            proposal_sha256=digest("lineage-proposal"),
            transition_sha256=digest("lineage-transition"),
            commit_receipt_sha256=digest("lineage-receipt"),
            sink_implementation_sha256=implementation,
            sink_instance_sha256=instance,
            application_ordinal=1,
        )
        ledger_encoded = reference_sink._encode_ledger(
            request_sha256=request,
            request_epoch=request_epoch,
            sink_implementation_sha256=implementation,
            sink_instance_sha256=instance,
            base_global_sequence=initial_sequence,
            acknowledgement_wires=(acknowledgement,),
        )
        ledger = reference_sink._decode_ledger(
            ledger_encoded,
            expected_request_sha256=request,
            expected_request_epoch=request_epoch,
            expected_sink_implementation_sha256=implementation,
            expected_sink_instance_sha256=instance,
            expected_base_global_sequence=initial_sequence,
            expected_maximum_results=3,
        )
        foreign_parent = digest("foreign-empty-selector")
        selector_encoded = reference_sink._encode_selector(
            ledger=ledger,
            previous_selector_sha256=foreign_parent,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ledger_name = (
                "prepared-text-result-ledger-"
                + ledger.ledger_sha256.hex()
                + ".bin"
            )
            (root / ledger_name).write_bytes(ledger_encoded)
            (root / campaign.SINK_ACTIVE_SELECTOR_NAME).write_bytes(
                selector_encoded
            )
            decoded = campaign._decode_sink_wire(root)
        self.assertIsNotNone(decoded)
        assert decoded is not None
        self.assertEqual(
            decoded.previous_selector_sha256,
            foreign_parent.hex(),
        )
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "identity or source-empty lineage mismatch",
        ):
            campaign._require_one_ahead_sink_parent(
                decoded,
                contract,
            )

    def test_coherently_rooted_foreign_one_ahead_identity_is_rejected(
        self,
    ) -> None:
        contract = campaign._decode_source_replay_contract(
            SourceReplayContractTests().contract()
        )
        foreign_request = hashlib.sha256(
            b"foreign-one-ahead-request"
        ).digest()
        acknowledgement = reference_sink.encode_acknowledgement_v1(
            request_sha256=foreign_request,
            request_epoch=contract.request_epoch,
            transaction_sequence=contract.sink_initial_sequence,
            token_id=23,
            proposal_sha256=hashlib.sha256(b"foreign-proposal").digest(),
            transition_sha256=hashlib.sha256(b"foreign-transition").digest(),
            commit_receipt_sha256=hashlib.sha256(b"foreign-receipt").digest(),
            sink_implementation_sha256=contract.sink_implementation_sha256,
            sink_instance_sha256=contract.sink_instance_sha256,
            application_ordinal=1,
        )
        ledger_encoded = reference_sink._encode_ledger(
            request_sha256=foreign_request,
            request_epoch=contract.request_epoch,
            sink_implementation_sha256=contract.sink_implementation_sha256,
            sink_instance_sha256=contract.sink_instance_sha256,
            base_global_sequence=contract.sink_initial_sequence,
            acknowledgement_wires=(acknowledgement,),
        )
        ledger = reference_sink._decode_ledger(
            ledger_encoded,
            expected_request_sha256=foreign_request,
            expected_request_epoch=contract.request_epoch,
            expected_sink_implementation_sha256=(
                contract.sink_implementation_sha256
            ),
            expected_sink_instance_sha256=contract.sink_instance_sha256,
            expected_base_global_sequence=contract.sink_initial_sequence,
            expected_maximum_results=contract.sink_capacity,
        )
        selector_encoded = reference_sink._encode_selector(
            ledger=ledger,
            previous_selector_sha256=contract.sink_empty_selector_sha256,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ledger_name = (
                "prepared-text-result-ledger-"
                + ledger.ledger_sha256.hex()
                + ".bin"
            )
            (root / ledger_name).write_bytes(ledger_encoded)
            (root / campaign.SINK_ACTIVE_SELECTOR_NAME).write_bytes(
                selector_encoded
            )
            decoded = campaign._decode_sink_wire(root)
        self.assertIsNotNone(decoded)
        assert decoded is not None
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "identity or source-empty lineage mismatch",
        ):
            campaign._require_one_ahead_sink_parent(decoded, contract)


class OptionalWireSelectionTests(unittest.TestCase):
    def test_both_absent_selectors_are_an_explicit_valid_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            facts = campaign.audit_wire_state(
                Path(temporary),
                require_terminal=False,
                expected_sink_state="absent",
                expected_checkpoint_state="absent",
            )
        self.assertIsNone(facts.sink)
        self.assertIsNone(facts.checkpoint)

    def test_missing_is_not_accepted_when_selection_is_required(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                campaign.CampaignError,
                "presence changed",
            ):
                campaign.audit_wire_state(
                    Path(temporary),
                    require_terminal=False,
                )

    def test_partial_active_sink_is_corruption_not_absence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / campaign.SINK_ACTIVE_SELECTOR_NAME).write_bytes(b"x")
            with self.assertRaisesRegex(
                campaign.CampaignError,
                "wrong size",
            ):
                campaign.audit_wire_state(
                    root,
                    require_terminal=False,
                    expected_sink_state="absent",
                    expected_checkpoint_state="absent",
                )

    def test_partial_active_checkpoint_is_corruption_not_absence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / campaign.CHECKPOINT_ACTIVE_SELECTOR_NAME).write_bytes(b"x")
            with self.assertRaisesRegex(
                campaign.CampaignError,
                "wrong size",
            ):
                campaign.audit_wire_state(
                    root,
                    require_terminal=False,
                    expected_sink_state="absent",
                    expected_checkpoint_state="absent",
                )


class SourceReplayContractTests(unittest.TestCase):
    @staticmethod
    def digest(label: str) -> bytes:
        return hashlib.sha256(label.encode("ascii")).digest()

    def contract(self) -> bytes:
        prompt = (7, 11)
        encoded = bytearray(
            campaign.SOURCE_REPLAY_PROMPT_OFFSET
            + len(prompt) * 4
            + campaign.SOURCE_REPLAY_FOOTER_BYTES
        )

        def put_u64(offset: int, value: int) -> None:
            struct.pack_into("<Q", encoded, offset, value)

        encoded[:8] = campaign.SOURCE_REPLAY_CONTRACT_MAGIC
        put_u64(8, campaign.SOURCE_REPLAY_CONTRACT_ABI)
        put_u64(16, len(encoded))
        put_u64(24, 0)
        put_u64(32, campaign.SOURCE_REPLAY_HEADER_BYTES)
        put_u64(40, campaign.SOURCE_REPLAY_FIXED_PAYLOAD_BYTES)
        put_u64(48, len(prompt))
        put_u64(56, len(prompt) * 4)

        max_new_tokens = 4
        put_u64(128, max_new_tokens)
        put_u64(136, 2)
        put_u64(144, 991)
        scheduling = (101, 102, 3, 104, 1, 1000)
        for index, value in enumerate(scheduling):
            put_u64(152 + index * 8, value)
        request_epoch = 701
        put_u64(200, request_epoch)
        encoded[208:240] = self.digest("token-domain")
        encoded[240:272] = self.digest("token-config")
        encoded[272:304] = self.digest("artifact-license")
        encoded[304:336] = bytes(32)
        source_runtime = (801, 802, 803)
        for index, value in enumerate(source_runtime):
            put_u64(336 + index * 8, value)
        put_u64(360, request_epoch)
        put_u64(368, 1)
        encoded[376:408] = self.digest("challenge")

        prompt_wire = struct.pack("<II", *prompt)
        prompt_root = hashlib.sha256(
            campaign.SOURCE_PROMPT_DOMAIN
            + struct.pack("<Q", len(prompt))
            + prompt_wire
        ).digest()
        bindings = (
            self.digest("plan"),
            self.digest("bound-plan"),
            prompt_root,
            self.digest("artifact"),
            self.digest("execution"),
            self.digest("residency"),
        )
        for index, binding in enumerate(bindings):
            encoded[408 + index * 32 : 440 + index * 32] = binding

        target_values = (
            901,
            902,
            903,
            4,
            905,
            906,
            907,
            908,
            909,
            910,
            911,
            4,
            10,
            11,
            12,
            13,
            14,
            16,
            16,
            17,
            18,
            1,
        )
        target_wire = struct.pack("<" + "Q" * len(target_values), *target_values)
        encoded[600:776] = target_wire
        encoded[776:808] = hashlib.sha256(
            campaign.SOURCE_TARGET_DOMAIN
            + struct.pack(
                "<QQQ",
                campaign.SOURCE_REPLAY_CONTRACT_ABI,
                campaign.SOURCE_OWNERSHIP_INTENT_ABI,
                campaign.RESOURCE_BANK_ABI,
            )
            + target_wire
        ).digest()

        put_u64(808, 1001)
        put_u64(816, max_new_tokens - 1)
        put_u64(824, 1)
        implementation = self.digest("sink-implementation")
        instance = self.digest("sink-instance")
        encoded[832:864] = implementation
        encoded[864:896] = instance
        empty_ledger, empty_selector = campaign._empty_sink_roots(
            bindings[0],
            request_epoch,
            1,
            implementation,
            instance,
        )
        encoded[896:928] = empty_ledger
        encoded[928:960] = empty_selector
        encoded[960:968] = prompt_wire
        self.reroot(encoded)
        return bytes(encoded)

    @staticmethod
    def reroot(encoded: bytearray) -> None:
        encoded[-32:] = hashlib.sha256(
            campaign.SOURCE_REPLAY_DOMAIN + encoded[:-32]
        ).digest()

    def contract_and_execution(
        self,
    ) -> tuple[bytes, bytes]:
        contract = bytearray(self.contract())
        facts = campaign._decode_source_replay_contract(bytes(contract))
        execution = bytearray(campaign.MODEL_EXECUTION_PLAN_BYTES)
        execution[:8] = campaign.MODEL_EXECUTION_PLAN_MAGIC
        struct.pack_into(
            "<Q",
            execution,
            8,
            campaign.EXECUTION_PLAN_OBJECT_ABI,
        )
        struct.pack_into(
            "<Q",
            execution,
            16,
            campaign.MODEL_EXECUTION_PLAN_BYTES,
        )
        struct.pack_into("<Q", execution, 72, facts.request_epoch)
        struct.pack_into("<Q", execution, 80, facts.scheduling[2])
        struct.pack_into("<Q", execution, 144, 0)
        execution[320:352] = facts.prompt_sha256
        execution[352:384] = facts.bound_token_domain_sha256
        execution[384:416] = (
            facts.bound_token_domain_config_sha256
        )
        execution[480:512] = campaign._source_ownership_root(facts)
        execution[512:544] = facts.challenge_sha256
        execution[544:576] = facts.bound_previous_plan_sha256
        execution[campaign.MODEL_EXECUTION_PLAN_BODY_BYTES :] = (
            hashlib.sha256(
                campaign.MODEL_EXECUTION_PLAN_DOMAIN
                + execution[: campaign.MODEL_EXECUTION_PLAN_BODY_BYTES]
            ).digest()
        )
        contract[536:568] = execution[-32:]
        self.reroot(contract)
        return bytes(contract), bytes(execution)

    def bind_restart_plan(
        self,
        contract: bytearray,
        plan: bytearray,
    ) -> campaign.SourceContractFacts:
        plan_root = hashlib.sha256(
            campaign.RESTART_PLAN_DOMAIN
            + plan[:164]
            + plan[168:256]
        ).digest()
        plan[256:288] = plan_root
        contract[408:440] = plan_root
        request_epoch = struct.unpack_from("<Q", contract, 360)[0]
        initial_sequence = struct.unpack_from("<Q", contract, 824)[0]
        empty_ledger, empty_selector = campaign._empty_sink_roots(
            plan_root,
            request_epoch,
            initial_sequence,
            bytes(contract[832:864]),
            bytes(contract[864:896]),
        )
        contract[896:928] = empty_ledger
        contract[928:960] = empty_selector
        self.reroot(contract)
        return campaign._decode_source_replay_contract(bytes(contract))

    def restart_plan_fixture(
        self,
    ) -> tuple[bytearray, bytearray, campaign.SourceContractFacts]:
        contract = bytearray(self.contract())
        facts = campaign._decode_source_replay_contract(bytes(contract))
        plan = bytearray(288)
        struct.pack_into("<Q", plan, 0, campaign.PREPARED_TEXT_PLAN_ABI)
        plan[8:40] = self.digest("plan-source-fingerprint")
        plan[40:72] = self.digest("plan-abi-fingerprint")
        struct.pack_into("<Q", plan, 72, 4096)
        plan[80:112] = self.digest("plan-container")
        struct.pack_into("<Q", plan, 112, len(facts.prompt_tokens))
        plan[120:152] = facts.prompt_sha256
        struct.pack_into("<Q", plan, 152, facts.options[0])
        struct.pack_into("<I", plan, 160, facts.options[1])
        struct.pack_into("<Q", plan, 168, facts.options[2])
        struct.pack_into(
            "<" + "Q" * 10,
            plan,
            176,
            *facts.target_values[12:],
        )
        facts = self.bind_restart_plan(contract, plan)
        return contract, plan, facts

    def prepared_profile_fixture(
        self,
    ) -> tuple[
        bytearray,
        bytearray,
        bytearray,
        campaign.SourceContractFacts,
    ]:
        _, plan, facts = self.restart_plan_fixture()
        claim = facts.target_values[12:]
        resident = struct.unpack_from("<Q", plan, 72)[0]
        artifact = bytearray(campaign.MODEL_ARTIFACT_BYTES)
        artifact[:8] = campaign.MODEL_ARTIFACT_MAGIC
        struct.pack_into("<Q", artifact, 8, campaign.MODEL_ARTIFACT_ABI)
        struct.pack_into(
            "<Q",
            artifact,
            16,
            campaign.MODEL_ARTIFACT_BYTES,
        )
        for offset, value in (
            (32, 1),
            (40, campaign.PREPARED_TEXT_ARTIFACT_PROFILE_ABI),
            (48, 1),
            (56, 11),
            (64, 4),
            (72, 1),
            (80, len(facts.prompt_tokens)),
            (88, facts.options[0]),
            (96, resident),
            (104, resident),
            (208, 1),
            (216, 4),
            (224, 4),
        ):
            struct.pack_into("<Q", artifact, offset, value)
        artifact[112:144] = plan[80:112]
        artifact[144:176] = self.digest("artifact-metadata")
        artifact[176:208] = facts.bound_artifact_license_sha256
        artifact[-32:] = hashlib.sha256(
            campaign.MODEL_ARTIFACT_DOMAIN
            + artifact[: campaign.MODEL_ARTIFACT_BODY_BYTES]
        ).digest()

        execution = bytearray(campaign.MODEL_EXECUTION_PLAN_BYTES)
        execution[:8] = campaign.MODEL_EXECUTION_PLAN_MAGIC
        struct.pack_into(
            "<Q",
            execution,
            8,
            campaign.EXECUTION_PLAN_OBJECT_ABI,
        )
        struct.pack_into(
            "<Q",
            execution,
            16,
            campaign.MODEL_EXECUTION_PLAN_BYTES,
        )
        for offset, value in (
            (32, 1),
            (40, 13),
            (48, 1),
            (56, 11),
            (64, 4),
            (72, facts.request_epoch),
            (80, facts.scheduling[2]),
            (88, 1),
            (96, len(facts.prompt_tokens)),
            (104, facts.options[0]),
            (112, len(facts.prompt_tokens) * 4),
            (120, facts.options[0] * 4),
            (128, claim[3]),
            (136, 0),
            (144, 0),
            (152, 1),
            (160, resident),
            (168, 0),
            (640, 4),
            (648, 4),
        ):
            struct.pack_into("<Q", execution, offset, value)
        struct.pack_into(
            "<" + "Q" * 10,
            execution,
            176,
            claim[0] + resident,
            *claim[1:],
        )
        execution[256:288] = artifact[-32:]
        execution[288:320] = artifact[112:144]
        execution[320:352] = facts.prompt_sha256
        execution[352:384] = facts.bound_token_domain_sha256
        execution[384:416] = facts.bound_token_domain_config_sha256
        execution[416:448] = self.digest("cache-bundle")
        execution[448:480] = self.digest("cache-payload")
        execution[480:512] = campaign._source_ownership_root(facts)
        execution[512:544] = facts.challenge_sha256
        execution[544:576] = facts.bound_previous_plan_sha256
        execution[576:608] = self.digest("input-schema")
        execution[608:640] = self.digest("output-schema")
        execution[-32:] = hashlib.sha256(
            campaign.MODEL_EXECUTION_PLAN_DOMAIN
            + execution[: campaign.MODEL_EXECUTION_PLAN_BODY_BYTES]
        ).digest()
        return plan, artifact, execution, facts

    def restart_manifest_fixture(
        self,
    ) -> tuple[bytearray, campaign.SourceContractFacts]:
        plan, artifact, execution, facts = self.prepared_profile_fixture()
        contract = bytearray(facts.encoded)
        plan_claim = facts.target_values[12:]
        resident_weight_bytes = struct.unpack_from("<Q", plan, 72)[0]

        residency = bytearray(campaign.MODEL_RESIDENCY_BYTES)
        residency[:8] = campaign.MODEL_RESIDENCY_MAGIC
        struct.pack_into(
            "<Q",
            residency,
            8,
            campaign.EXECUTION_RESIDENCY_OBJECT_ABI,
        )
        struct.pack_into(
            "<Q",
            residency,
            16,
            campaign.MODEL_RESIDENCY_BYTES,
        )
        struct.pack_into("<Q", residency, 32, 2)
        struct.pack_into("<Q", residency, 40, resident_weight_bytes)
        residency[48:80] = artifact[-32:]
        residency[80:112] = artifact[112:144]
        residency[112:144] = execution[-32:]
        struct.pack_into(
            "<" + "Q" * 10,
            residency,
            144,
            *plan_claim,
        )
        residency[-32:] = hashlib.sha256(
            campaign.MODEL_RESIDENCY_DOMAIN
            + residency[: campaign.MODEL_RESIDENCY_BODY_BYTES]
        ).digest()

        bound_root = hashlib.sha256(
            campaign.RESTART_BOUND_PLAN_DOMAIN
            + struct.pack("<Q", campaign.PREPARED_TEXT_BOUND_PLAN_ABI)
            + plan[-32:]
            + artifact[-32:]
            + execution[-32:]
            + residency[-32:]
            + facts.bound_token_domain_sha256
            + facts.bound_token_domain_config_sha256
            + facts.bound_artifact_license_sha256
        ).digest()
        contract[440:472] = bound_root
        contract[504:536] = artifact[-32:]
        contract[536:568] = execution[-32:]
        contract[568:600] = residency[-32:]
        self.reroot(contract)
        facts = campaign._decode_source_replay_contract(bytes(contract))

        bound = bytearray(168)
        struct.pack_into(
            "<Q",
            bound,
            0,
            campaign.PREPARED_TEXT_BOUND_PLAN_ABI,
        )
        bound[8:40] = plan[-32:]
        bound[40:72] = facts.bound_token_domain_sha256
        bound[72:104] = facts.bound_token_domain_config_sha256
        bound[104:136] = facts.bound_artifact_license_sha256
        bound[136:168] = bound_root

        state = bytearray(176)
        struct.pack_into(
            "<QQQ",
            state,
            0,
            campaign.LANE_STATE_COMMITMENT_ABI,
            campaign.LANE_CONTIGUOUS_EXECUTION_ABI,
            2,
        )
        state[24:56] = self.digest("restart-kv-state")
        struct.pack_into(
            "<Q",
            state,
            56,
            campaign.LANE_CONTIGUOUS_RNG_STATE_ABI,
        )
        state[64:96] = self.digest("restart-rng-state")
        struct.pack_into("<QQ", state, 96, 1, 1)
        state[112:144] = self.digest("restart-output-state")
        state[144:176] = hashlib.sha256(
            campaign.LANE_STATE_COMMITMENT_DOMAIN + state[:144]
        ).digest()

        source = bytearray(448)
        boundary_root = self.digest("restart-boundary")
        transcript_root = self.digest("restart-transcript")
        source[0:32] = bound_root
        source[32:64] = boundary_root
        struct.pack_into(
            "<" + "Q" * 7,
            source,
            64,
            campaign.LANE_TRANSCRIPT_SNAPSHOT_ABI,
            facts.request_epoch,
            campaign.LANE_CONTIGUOUS_EXECUTION_ABI,
            0,
            facts.publication_next_sequence,
            1,
            0,
        )
        source[120:296] = state
        source[296:328] = transcript_root
        receipt_without_integrity = (
            facts.source_runtime[2],
            7,
            3,
            facts.scheduling[3],
            *plan_claim,
            0,
        )
        receipt = (
            *receipt_without_integrity[:-1],
            campaign._resource_receipt_integrity(
                receipt_without_integrity
            ),
        )
        struct.pack_into("<" + "Q" * 15, source, 328, *receipt)

        expected = bytearray(376)
        expected[0:32] = plan[-32:]
        expected[32:64] = bound_root
        expected[64:96] = artifact[-32:]
        expected[96:128] = execution[-32:]
        expected[128:160] = residency[-32:]
        expected[160:192] = boundary_root
        expected[192:224] = transcript_root
        expected[224:256] = state[144:176]
        struct.pack_into(
            "<" + "Q" * 11,
            expected,
            256,
            facts.request_epoch,
            facts.publication_next_sequence,
            len(facts.prompt_tokens),
            facts.options[0],
            2,
            2,
            8,
            5,
            2,
            1,
            1,
        )
        expected[344:376] = facts.challenge_sha256

        prompt_wire = facts.encoded[
            campaign.SOURCE_REPLAY_PROMPT_OFFSET :
            -campaign.SOURCE_REPLAY_FOOTER_BYTES
        ]
        encoded = bytearray(
            campaign.RESTART_MANIFEST_PROMPT_OFFSET
            + len(prompt_wire)
            + campaign.SOURCE_REPLAY_FOOTER_BYTES
        )
        encoded[:8] = campaign.RESTART_MANIFEST_MAGIC
        for offset, value in (
            (8, campaign.RESTART_MANIFEST_ABI),
            (16, len(encoded)),
            (24, 0),
            (32, campaign.RESTART_MANIFEST_HEADER_BYTES),
            (40, campaign.RESTART_MANIFEST_FIXED_PAYLOAD_BYTES),
            (48, len(facts.prompt_tokens)),
            (56, len(prompt_wire)),
            (64, campaign.MODEL_ARTIFACT_BYTES),
            (72, campaign.MODEL_EXECUTION_PLAN_BYTES),
            (80, campaign.MODEL_RESIDENCY_BYTES),
            (88, 0),
            (96, facts.options[0]),
            (112, facts.options[2]),
        ):
            struct.pack_into("<Q", encoded, offset, value)
        struct.pack_into("<I", encoded, 104, facts.options[1])
        encoded[120:408] = plan
        encoded[408:576] = bound
        encoded[576:896] = artifact
        encoded[896:1664] = execution
        encoded[1664:1920] = residency
        encoded[1920:2296] = expected
        encoded[2296:2744] = source
        encoded[2744:2920] = facts.target_wire
        encoded[2920:-32] = prompt_wire
        self.reroot_restart_manifest(encoded)
        return encoded, facts

    @staticmethod
    def reroot_restart_manifest(encoded: bytearray) -> None:
        encoded[-32:] = hashlib.sha256(
            campaign.RESTART_MANIFEST_DOMAIN + encoded[:-32]
        ).digest()

    def test_valid_contract_reconstructs_prompt_target_and_empty_sink(self) -> None:
        facts = campaign._decode_source_replay_contract(self.contract())
        self.assertEqual(facts.prompt_tokens, (7, 11))
        self.assertEqual(facts.options, (4, 2, 991))
        self.assertEqual(facts.publication_next_sequence, 1)
        self.assertEqual(facts.sink_capacity, 3)
        self.assertNotEqual(facts.contract_sha256, bytes(32))

    def test_bad_contract_footer_is_rejected(self) -> None:
        encoded = bytearray(self.contract())
        encoded[-1] ^= 1
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "contract root mismatch",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rehashed_wrong_target_root_is_rejected(self) -> None:
        encoded = bytearray(self.contract())
        encoded[776] ^= 1
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "target root mismatch",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rehashed_invalid_target_identity_is_rejected(self) -> None:
        encoded = bytearray(self.contract())
        source_bank_epoch = struct.unpack_from("<Q", encoded, 352)[0]
        struct.pack_into("<Q", encoded, 616, source_bank_epoch)
        target_wire = bytes(encoded[600:776])
        encoded[776:808] = hashlib.sha256(
            campaign.SOURCE_TARGET_DOMAIN
            + struct.pack(
                "<QQQ",
                campaign.SOURCE_REPLAY_CONTRACT_ABI,
                campaign.SOURCE_OWNERSHIP_INTENT_ABI,
                campaign.RESOURCE_BANK_ABI,
            )
            + target_wire
        ).digest()
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "target identity",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rehashed_wrong_empty_sink_root_is_rejected(self) -> None:
        encoded = bytearray(self.contract())
        encoded[896] ^= 1
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "empty sink roots mismatch",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rehashed_prompt_mutation_is_rejected(self) -> None:
        encoded = bytearray(self.contract())
        encoded[960] ^= 1
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "prompt root mismatch",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rerooted_weight_must_fit_scheduler_u16(self) -> None:
        encoded = bytearray(self.contract())
        struct.pack_into("<Q", encoded, 184, 1 << 16)
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "request identity",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rerooted_target_host_claim_cannot_overflow(
        self,
    ) -> None:
        encoded = bytearray(self.contract())
        struct.pack_into("<Q", encoded, 696, campaign.U64_MAX)
        struct.pack_into("<Q", encoded, 704, 1)
        target_wire = bytes(encoded[600:776])
        encoded[776:808] = hashlib.sha256(
            campaign.SOURCE_TARGET_DOMAIN
            + struct.pack(
                "<QQQ",
                campaign.SOURCE_REPLAY_CONTRACT_ABI,
                campaign.SOURCE_OWNERSHIP_INTENT_ABI,
                campaign.RESOURCE_BANK_ABI,
            )
            + target_wire
        ).digest()
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "host-byte claim overflows",
        ):
            campaign._decode_source_replay_contract(bytes(encoded))

    def test_coherently_rerooted_ownership_inputs_cannot_reuse_execution(
        self,
    ) -> None:
        contract, execution = self.contract_and_execution()
        original = campaign._decode_source_replay_contract(contract)
        self.assertEqual(original.execution_plan_sha256, execution[-32:])
        for label, offset in (
            ("weight", 184),
            ("deadline", 192),
            ("scheduler_epoch", 336),
            ("bank_epoch", 352),
        ):
            with self.subTest(field=label):
                encoded = bytearray(contract)
                struct.pack_into(
                    "<Q",
                    encoded,
                    offset,
                    struct.unpack_from("<Q", encoded, offset)[0] + 1,
                )
                self.reroot(encoded)
                rerooted = campaign._decode_source_replay_contract(
                    bytes(encoded)
                )
                with self.assertRaisesRegex(
                    campaign.CampaignError,
                    r"source execution (?:context|ownership) differs",
                ):
                    campaign._validate_source_execution_bindings(
                        execution,
                        rerooted,
                    )

        encoded = bytearray(contract)
        request_epoch = struct.unpack_from("<Q", encoded, 360)[0] + 1
        struct.pack_into("<Q", encoded, 200, request_epoch)
        struct.pack_into("<Q", encoded, 360, request_epoch)
        empty_ledger, empty_selector = campaign._empty_sink_roots(
            bytes(encoded[408:440]),
            request_epoch,
            struct.unpack_from("<Q", encoded, 824)[0],
            bytes(encoded[832:864]),
            bytes(encoded[864:896]),
        )
        encoded[896:928] = empty_ledger
        encoded[928:960] = empty_selector
        self.reroot(encoded)
        rerooted = campaign._decode_source_replay_contract(bytes(encoded))
        with self.assertRaisesRegex(
            campaign.CampaignError,
            r"source execution (?:context|ownership) differs",
        ):
            campaign._validate_source_execution_bindings(
                execution,
                rerooted,
            )

    def test_coherently_rerooted_previous_plan_cannot_reuse_execution(
        self,
    ) -> None:
        contract, execution = self.contract_and_execution()
        encoded = bytearray(contract)
        encoded[304:336] = self.digest("foreign-previous-plan")
        self.reroot(encoded)
        rerooted = campaign._decode_source_replay_contract(bytes(encoded))
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "source execution context differs",
        ):
            campaign._validate_source_execution_bindings(
                execution,
                rerooted,
            )

    def test_restart_plan_requires_exact_abi_after_coherent_reroot(
        self,
    ) -> None:
        contract, plan, _ = self.restart_plan_fixture()
        struct.pack_into(
            "<Q",
            plan,
            0,
            campaign.PREPARED_TEXT_PLAN_ABI + 1,
        )
        rerooted = self.bind_restart_plan(contract, plan)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "invalid restart manifest plan",
        ):
            campaign._decode_restart_plan(bytes(plan), rerooted)

    def test_restart_plan_claim_must_equal_contract_target_claim(
        self,
    ) -> None:
        contract, plan, _ = self.restart_plan_fixture()
        struct.pack_into(
            "<Q",
            plan,
            176,
            struct.unpack_from("<Q", plan, 176)[0] + 1,
        )
        rerooted = self.bind_restart_plan(contract, plan)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "invalid restart manifest plan",
        ):
            campaign._decode_restart_plan(bytes(plan), rerooted)

    def test_execution_claim_projection_rejects_coherent_mutation(
        self,
    ) -> None:
        _, plan, facts = self.restart_plan_fixture()
        _, plan_claim = campaign._decode_restart_plan(bytes(plan), facts)
        resident = struct.unpack_from("<Q", plan, 72)[0]
        execution = bytearray(campaign.MODEL_EXECUTION_PLAN_BYTES)
        struct.pack_into("<Q", execution, 128, plan_claim[3])
        struct.pack_into("<Q", execution, 160, resident)
        struct.pack_into(
            "<" + "Q" * 10,
            execution,
            176,
            plan_claim[0] + resident,
            *plan_claim[1:],
        )
        execution[256:288] = self.digest("execution-artifact")
        execution[288:320] = self.digest("execution-weights")
        execution[-32:] = hashlib.sha256(
            campaign.MODEL_EXECUTION_PLAN_DOMAIN
            + execution[: campaign.MODEL_EXECUTION_PLAN_BODY_BYTES]
        ).digest()
        residency = bytearray(campaign.MODEL_RESIDENCY_BYTES)
        struct.pack_into("<Q", residency, 32, 2)
        struct.pack_into("<Q", residency, 40, resident)
        residency[48:80] = execution[256:288]
        residency[80:112] = execution[288:320]
        residency[112:144] = execution[-32:]
        struct.pack_into(
            "<" + "Q" * 10,
            residency,
            144,
            *plan_claim,
        )
        campaign._validate_restart_execution_context(
            bytes(plan),
            bytes(execution),
            bytes(execution[-32:]),
            bytes(residency),
            plan_claim,
        )

        struct.pack_into(
            "<Q",
            execution,
            176,
            struct.unpack_from("<Q", execution, 176)[0] + 1,
        )
        execution[-32:] = hashlib.sha256(
            campaign.MODEL_EXECUTION_PLAN_DOMAIN
            + execution[: campaign.MODEL_EXECUTION_PLAN_BODY_BYTES]
        ).digest()
        residency[112:144] = execution[-32:]
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "execution residency differs",
        ):
            campaign._validate_restart_execution_context(
                bytes(plan),
                bytes(execution),
                bytes(execution[-32:]),
                bytes(residency),
                plan_claim,
            )

    def test_coherently_rerooted_foreign_execution_operation_is_rejected(
        self,
    ) -> None:
        plan, artifact, execution, facts = (
            self.prepared_profile_fixture()
        )
        campaign._validate_prepared_bound_profile(
            bytes(plan),
            bytes(artifact),
            bytes(execution),
            facts,
        )
        struct.pack_into("<Q", execution, 40, 4)
        execution[-32:] = hashlib.sha256(
            campaign.MODEL_EXECUTION_PLAN_DOMAIN
            + execution[: campaign.MODEL_EXECUTION_PLAN_BODY_BYTES]
        ).digest()
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "prepared execution profile mismatch",
        ):
            campaign._validate_prepared_bound_profile(
                bytes(plan),
                bytes(artifact),
                bytes(execution),
                facts,
            )

    def test_valid_restart_expected_source_context_is_accepted(self) -> None:
        encoded, facts = self.restart_manifest_fixture()
        execution, residency, receipt = campaign._decode_restart_manifest(
            bytes(encoded),
            facts,
        )
        self.assertEqual(
            execution[-32:],
            facts.execution_plan_sha256,
        )
        self.assertEqual(
            residency[-32:],
            facts.residency_binding_sha256,
        )
        self.assertEqual(
            struct.unpack_from("<Q", receipt, 0)[0],
            facts.source_runtime[2],
        )

    def test_coherently_rerooted_zero_num_layers_is_rejected(self) -> None:
        encoded, facts = self.restart_manifest_fixture()
        struct.pack_into(
            "<Q",
            encoded,
            campaign.RESTART_EXPECTED_BINDINGS_OFFSET + 296,
            0,
        )
        self.reroot_restart_manifest(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "expected bindings differ",
        ):
            campaign._decode_restart_manifest(bytes(encoded), facts)

    def test_coherent_foreign_state_commitment_is_rejected(self) -> None:
        encoded, facts = self.restart_manifest_fixture()
        expected_commitment_offset = (
            campaign.RESTART_EXPECTED_BINDINGS_OFFSET + 224
        )
        source_commitment_offset = 2296 + 264
        encoded[expected_commitment_offset] ^= 1
        encoded[source_commitment_offset] ^= 1
        self.reroot_restart_manifest(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "source context mismatch",
        ):
            campaign._decode_restart_manifest(bytes(encoded), facts)

    def test_coherently_rerooted_snapshot_abi_mutation_is_rejected(
        self,
    ) -> None:
        encoded, facts = self.restart_manifest_fixture()
        struct.pack_into(
            "<Q",
            encoded,
            2296 + 64,
            campaign.LANE_TRANSCRIPT_SNAPSHOT_ABI + 1,
        )
        self.reroot_restart_manifest(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "source context mismatch",
        ):
            campaign._decode_restart_manifest(bytes(encoded), facts)


class SourceExitSemanticOracleTests(unittest.TestCase):
    @staticmethod
    def digest(label: str) -> bytes:
        return hashlib.sha256(label.encode("ascii")).digest()

    @staticmethod
    def reroot(encoded: bytearray) -> None:
        encoded[512:544] = campaign._source_exit_semantic_root(
            bytes(encoded)
        )
        encoded[608:640] = hashlib.sha256(
            campaign.SOURCE_EXIT_WIRE_DOMAIN + encoded[:608]
        ).digest()

    @staticmethod
    def reroot_outer(encoded: bytearray) -> None:
        encoded[608:640] = hashlib.sha256(
            campaign.SOURCE_EXIT_WIRE_DOMAIN + encoded[:608]
        ).digest()

    @staticmethod
    def refresh_receipt_root(encoded: bytearray) -> None:
        receipt = tuple(
            struct.unpack_from("<Q", encoded, 128 + index * 8)[0]
            for index in range(15)
        )
        encoded[256:288] = hashlib.sha256(
            campaign.RESOURCE_RECEIPT_DOMAIN
            + campaign._canonical_resource_receipt_wire(receipt)
        ).digest()

    def wire(self) -> bytes:
        encoded = bytearray(campaign.SOURCE_EXIT_WIRE_BYTES)
        encoded[:8] = campaign.SOURCE_EXIT_WIRE_MAGIC
        struct.pack_into(
            "<Q",
            encoded,
            8,
            campaign.SOURCE_EXIT_WIRE_ABI,
        )
        struct.pack_into(
            "<Q",
            encoded,
            16,
            campaign.SOURCE_EXIT_WIRE_BYTES,
        )
        identities = (
            101,
            102,
            103,
            101,
            7,
            108,
            109,
            110,
            111,
            112,
            113,
            114,
        )
        struct.pack_into("<" + "Q" * 12, encoded, 32, *identities)
        claim = (10, 11, 12, 13, 14, 16, 16, 17, 18, 1)
        receipt_without_integrity = (
            201,
            identities[4],
            identities[5],
            204,
            *claim,
            0,
        )
        integrity = campaign._resource_receipt_integrity(
            receipt_without_integrity
        )
        receipt = (*receipt_without_integrity[:-1], integrity)
        struct.pack_into("<" + "Q" * 15, encoded, 128, *receipt)
        struct.pack_into("<Q", encoded, 248, 301)
        self.refresh_receipt_root(encoded)
        for index, offset in enumerate(range(288, 512, 32)):
            encoded[offset : offset + 32] = self.digest(
                f"source-exit-digest-{index}"
            )
        self.reroot(encoded)
        return bytes(encoded)

    def test_valid_source_exit_semantics_are_accepted(self) -> None:
        campaign._validate_source_exit_semantics(self.wire())

    def test_coherently_rerooted_foreign_receipt_root_is_rejected(self) -> None:
        encoded = bytearray(self.wire())
        encoded[256] ^= 1
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "source receipt root mismatch",
        ):
            campaign._validate_source_exit_semantics(bytes(encoded))

    def test_outer_reroot_cannot_hide_bad_semantic_exit_root(self) -> None:
        encoded = bytearray(self.wire())
        encoded[512] ^= 1
        self.reroot_outer(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "semantic root mismatch",
        ):
            campaign._validate_source_exit_semantics(bytes(encoded))

    def test_coherently_rerooted_handle_receipt_mismatch_is_rejected(
        self,
    ) -> None:
        encoded = bytearray(self.wire())
        struct.pack_into("<Q", encoded, 64, 8)
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "invalid structural source-exit receipt",
        ):
            campaign._validate_source_exit_semantics(bytes(encoded))

    def test_coherent_bad_receipt_integrity_is_rejected(self) -> None:
        encoded = bytearray(self.wire())
        struct.pack_into(
            "<Q",
            encoded,
            240,
            struct.unpack_from("<Q", encoded, 240)[0] ^ 1,
        )
        self.refresh_receipt_root(encoded)
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "invalid structural source-exit receipt",
        ):
            campaign._validate_source_exit_semantics(bytes(encoded))

    def test_coherent_zero_cancel_sequence_is_rejected(self) -> None:
        encoded = bytearray(self.wire())
        struct.pack_into("<Q", encoded, 248, 0)
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "zero structural source-exit evidence",
        ):
            campaign._validate_source_exit_semantics(bytes(encoded))

    def test_coherent_maximum_last_permit_generation_is_rejected(
        self,
    ) -> None:
        encoded = bytearray(self.wire())
        struct.pack_into("<Q", encoded, 120, campaign.U64_MAX)
        self.reroot(encoded)
        with self.assertRaisesRegex(
            campaign.CampaignError,
            "invalid structural source-exit receipt",
        ):
            campaign._validate_source_exit_semantics(bytes(encoded))


if __name__ == "__main__":
    unittest.main()
