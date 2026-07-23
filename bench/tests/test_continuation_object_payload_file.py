from __future__ import annotations

import copy
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

from bench import continuation_bundle as bundle
from bench import continuation_capsule as capsule
from bench import continuation_object_payload_file as payload_file
from bench import continuation_object_payload_store as payload_store
from bench import continuation_object_store as object_store
from bench import continuation_object_sweep as sweep
from bench import continuation_object_sweep_record as sweep_record


def digest(byte: int) -> bytes:
    return bytes((byte,)) * 32


def payload_sweep_record(
    tenant: bytes,
    target: dict[str, object],
    entry_count_before: int,
    payload_bytes_before: int,
) -> bytes:
    targets = [target]
    targets.sort(key=lambda item: (item["sha256"], item["byte_length"]))
    targets_sha256 = object_store.retired_targets_root(targets)
    commit_grant = {
        "authority_epoch": 21,
        "tenant_scope_sha256": tenant,
        "bundle_sha256": digest(0x82),
        "store_grant_sha256": digest(0x83),
        "sweep_grant_sha256": digest(0x84),
        "prepare_sha256": digest(0x85),
        "expected_snapshot_sha256": digest(0x86),
        "collection_plan_sha256": digest(0x87),
        "max_freed_entries": 1,
        "max_freed_bytes": target["byte_length"],
        "challenge_sha256": digest(0x88),
    }
    grant_sha256 = sweep.commit_grant_root(commit_grant)
    live_entries = entry_count_before - 1
    store_receipt = {
        "authorization_sha256": grant_sha256,
        "targets_sha256": targets_sha256,
        "snapshot_before_sha256": commit_grant[
            "expected_snapshot_sha256"
        ],
        "snapshot_after_sha256": digest(0x89),
        "accounting_before": {
            "entry_count": entry_count_before,
            "live_entries": live_entries,
            "quarantined_entries": 0,
            "retired_entries": 1,
            "payload_bytes": payload_bytes_before,
            "logical_index_bytes": (
                entry_count_before * object_store.LOGICAL_INDEX_ENTRY_BYTES
            ),
            "reference_count": live_entries,
            "active_leases": 0,
            "repair_count": 0,
        },
        "accounting_after": {
            "entry_count": live_entries,
            "live_entries": live_entries,
            "quarantined_entries": 0,
            "retired_entries": 0,
            "payload_bytes": payload_bytes_before - target["byte_length"],
            "logical_index_bytes": (
                live_entries * object_store.LOGICAL_INDEX_ENTRY_BYTES
            ),
            "reference_count": live_entries,
            "active_leases": 0,
            "repair_count": 0,
        },
        "freed_entries": 1,
        "freed_payload_bytes": target["byte_length"],
        "freed_index_bytes": object_store.LOGICAL_INDEX_ENTRY_BYTES,
        "freed_repair_count": 0,
        "allocator_deallocation_calls": 1,
        "commit_sha256": capsule.ZERO_DIGEST,
    }
    store_receipt["commit_sha256"] = (
        object_store.retired_commit_receipt_root(store_receipt)
    )
    commit_receipt = {
        "commit_grant_sha256": grant_sha256,
        "sweep_grant_sha256": commit_grant["sweep_grant_sha256"],
        "prepare_sha256": commit_grant["prepare_sha256"],
        "collection_plan_sha256": commit_grant[
            "collection_plan_sha256"
        ],
        "targets_sha256": targets_sha256,
        "snapshot_before_sha256": store_receipt[
            "snapshot_before_sha256"
        ],
        "snapshot_after_sha256": store_receipt["snapshot_after_sha256"],
        "store_commit_sha256": store_receipt["commit_sha256"],
        "freed_entries": 1,
        "freed_payload_bytes": target["byte_length"],
        "freed_index_bytes": object_store.LOGICAL_INDEX_ENTRY_BYTES,
        "freed_repair_count": 0,
        "allocator_deallocation_calls": 1,
        "commit_sha256": capsule.ZERO_DIGEST,
    }
    commit_receipt["commit_sha256"] = sweep.commit_root(commit_receipt)
    return sweep_record.encode(
        {
            "record_epoch": 0x5357454550000001,
            "sequence": 1,
            "previous_record_sha256": capsule.ZERO_DIGEST,
            "record_challenge_sha256": digest(0x8A),
            "commit_grant": commit_grant,
            "commit_receipt": commit_receipt,
            "store_receipt": store_receipt,
        }
    )


class ContinuationObjectPayloadFileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tenant = bytes((0x6D,)) * 32
        payloads = (
            b"payload-alpha",
            b"payload-beta-beta",
            b"payload-gamma-gamma-gamma",
        )
        self.entries = payload_store.sort_entries(
            [
                {
                    "reference": bundle.blob_ref(self.tenant, payload),
                    "payload": payload,
                }
                for payload in payloads
            ]
        )
        self.initial = payload_store.encode_snapshot(
            self.tenant,
            self.entries,
        )
        self.targets = [self.entries[1]["reference"]]
        self.targets.sort(
            key=lambda item: (item["sha256"], item["byte_length"])
        )
        self.sweep_bytes = payload_sweep_record(
            self.tenant,
            self.targets[0],
            3,
            55,
        )
        self.sweep_root = sweep_record.decode(self.sweep_bytes)[
            "record_sha256"
        ]
        self.preview = payload_store.preview_reclaim(
            self.initial,
            self.tenant,
            self.targets,
        )
        self.prepared = payload_file.prepare_reclaim_record(
            self.preview,
            self.sweep_root,
            1000,
            digest(0xA0),
            self.targets,
        )

    def test_record_round_trip_golden_and_mutations(self) -> None:
        payload_file.verify_reclaim_record(
            self.prepared,
            self.preview,
            self.sweep_root,
        )
        decoded = payload_file.decode_reclaim_record(
            self.prepared["bytes"]
        )
        self.assertEqual(decoded["targets"], self.targets)
        self.assertEqual(
            decoded["record_sha256"],
            self.prepared["record_sha256"],
        )
        self.assertEqual(
            self.sweep_root.hex(),
            "871e9f220c7435070578bde3731bc7f30"
            "befa532cfa29b981292304a2a7cc977",
        )
        self.assertEqual(
            self.prepared["record_sha256"].hex(),
            "f1105b7058cc90e1ad9ec9ba09abfe78"
            "e34b6cbbebb014cf6b372b35f926de34",
        )
        for index in range(payload_file.RECLAIM_RECORD_BYTES):
            with self.subTest(index=index):
                mutated = bytearray(self.prepared["bytes"])
                mutated[index] ^= 1
                with self.assertRaises(payload_file.PayloadFileError):
                    payload_file.decode_reclaim_record(bytes(mutated))
        contradiction = bytearray(self.prepared["bytes"])
        contradiction[192] ^= 1
        contradiction[payload_file.RECORD_ROOT_OFFSET :] = hashlib.sha256(
            payload_file.RECLAIM_RECORD_DOMAIN
            + contradiction[: payload_file.RECORD_ROOT_OFFSET]
        ).digest()
        with self.assertRaises(payload_file.PayloadFileError):
            payload_file.decode_reclaim_record(bytes(contradiction))

    def test_process_death_at_every_promotion_phase_recovers_once(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as root:
            dispositions = []
            for index, phase in enumerate(payload_file.IO_PHASES):
                with self.subTest(phase=phase):
                    directory = Path(root) / f"death-{index}"
                    directory.mkdir()
                    sweep_path = directory / "sweep.records"
                    sweep_path.write_bytes(self.sweep_bytes)
                    sweep_path.chmod(0o600)
                    with sweep_path.open("r+b", buffering=0) as stream:
                        os.fsync(stream.fileno())
                    directory_fd = os.open(
                        directory,
                        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                    )
                    try:
                        os.fsync(directory_fd)
                    finally:
                        os.close(directory_fd)
                    prepared = payload_file.prepare_reclaim_record(
                        self.preview,
                        self.sweep_root,
                        1000 + index,
                        digest(0xA0 + index),
                        self.targets,
                    )
                    with payload_file.LockedPayloadStore.create(
                        directory,
                        self.tenant,
                        self.initial,
                        512,
                        1000 + index,
                    ) as store:
                        if phase not in {
                            payload_file.PHASE_PLAN_WRITE,
                            payload_file.PHASE_PLAN_SYNC,
                            payload_file.PHASE_PLAN_DIRECTORY_SYNC,
                        }:
                            store.publish_reclaim_record(prepared)
                    reclaim_name = "reclaim.candidate"
                    reclaim_path = directory / reclaim_name
                    reclaim_path.write_bytes(prepared["bytes"])
                    reclaim_path.chmod(0o600)
                    with reclaim_path.open("r+b", buffering=0) as stream:
                        os.fsync(stream.fileno())
                    child = subprocess.run(
                        (
                            sys.executable,
                            "-m",
                            "bench.continuation_object_payload_file",
                            "_child-recover",
                            str(directory),
                            "512",
                            str(1000 + index),
                            self.tenant.hex(),
                            "sweep.records",
                            reclaim_name,
                            phase,
                            "_end",
                        ),
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        child.returncode,
                        -signal.SIGKILL,
                        child.stderr,
                    )
                    with payload_file.LockedPayloadStore.open(
                        directory,
                        self.tenant,
                        512,
                        1000 + index,
                    ) as reopened:
                        reopened.publish_reclaim_record(prepared)
                        recovered = reopened.recover(
                            self.sweep_bytes,
                            prepared,
                        )
                        dispositions.append(recovered["disposition"])
                        repeated = reopened.recover(
                            self.sweep_bytes,
                            prepared,
                        )
                        self.assertEqual(
                            repeated["disposition"],
                            "already_applied",
                        )
                        self.assertEqual(
                            repeated["active_snapshot"][
                                "snapshot_sha256"
                            ],
                            self.preview["after"]["snapshot_sha256"],
                        )
            self.assertEqual(dispositions.count("applied"), 5)
            self.assertEqual(dispositions.count("already_applied"), 2)

    def test_foreign_sidecar_and_third_state_reject(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with payload_file.LockedPayloadStore.create(
                directory,
                self.tenant,
                self.initial,
                512,
                1000,
            ) as store:
                foreign_epoch = bytearray(self.prepared["bytes"])
                foreign_epoch[24:32] = (1001).to_bytes(8, "little")
                foreign_epoch[payload_file.RECORD_ROOT_OFFSET :] = (
                    hashlib.sha256(
                        payload_file.RECLAIM_RECORD_DOMAIN
                        + foreign_epoch[: payload_file.RECORD_ROOT_OFFSET]
                    ).digest()
                )
                with self.assertRaises(payload_file.PayloadFileError):
                    store.publish_reclaim_record(
                        {
                            "bytes": bytes(foreign_epoch),
                            "record_sha256": bytes(
                                foreign_epoch[
                                    payload_file.RECORD_ROOT_OFFSET :
                                ]
                            ),
                        }
                    )
                store.publish_reclaim_record(self.prepared)
                mutated = copy.deepcopy(self.prepared)
                damaged = bytearray(mutated["bytes"])
                damaged[0] ^= 1
                mutated["bytes"] = bytes(damaged)
                with self.assertRaises(payload_file.PayloadFileError):
                    store.recover(self.sweep_bytes, mutated)
                foreign_targets = [self.entries[0]["reference"]]
                foreign_targets.sort(
                    key=lambda item: (
                        item["sha256"],
                        item["byte_length"],
                    )
                )
                third_state = payload_store.preview_reclaim(
                    self.initial,
                    self.tenant,
                    foreign_targets,
                )["candidate"]
                active_path = Path(directory) / payload_file.ACTIVE_NAME
                active_path.write_bytes(third_state)
                with active_path.open("r+b", buffering=0) as stream:
                    os.fsync(stream.fileno())
                with self.assertRaises(payload_file.PayloadFileError):
                    store.recover(self.sweep_bytes, self.prepared)


if __name__ == "__main__":
    unittest.main()
