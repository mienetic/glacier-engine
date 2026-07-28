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
                        sequence - 1
                        if behavior == "good-before-sink"
                        else sequence
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
        self.assertEqual(len(set(campaign.CRASH_POINTS)), 19)
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
                ledger_sha256="11" * 32,
                selector_sha256="22" * 32,
                acknowledgement_tokens=acknowledged,
            ),
            checkpoint=campaign.CheckpointWireFacts(
                generation=generation,
                request_epoch=9,
                next_sequence=sequence,
                checkpoint_sha256="44" * 32,
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


if __name__ == "__main__":
    unittest.main()
