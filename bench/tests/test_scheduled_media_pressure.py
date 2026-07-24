from __future__ import annotations

import copy
import unittest

from bench import scheduled_media_pressure as pressure
from bench import workload_pressure as workload


ITEM_SECTION_ROOT = "3d55ecbeea1a131ed7f6562ec3d33259c157a6cbc3c194cf4f80b2318c73b4e9"
EXECUTION_SECTION_ROOT = (
    "46799e4e2b46c3b0152e7784a35389bc790f43999d01095c4467ed153152dd11"
)
SUMMARY_ROOT = "d832947ba869dec833e983178ce0cc67f725cccd783eeb5fbecfa61b2450b027"
EVIDENCE_ROOT = "f6d17a0d6471379c61bd38a5ac255c88f14dfb7585e150cda85b8d04631b880b"
EXECUTION_RECEIPT_ROOTS = (
    "f8789e249a80bbe29c462358e726a57f2d3245c73fd07787d7e01aabbd7317a4",
    "395546634b1e05868919934e5e4899efa8c1932f4cd52238daa78efe99c5fd06",
    "89ee7b79548b56f675c48df63dc3b07b5fd42ddcf04950b76aafad75de336fae",
)
RESOURCE_RECEIPT_ROOTS = {
    0: "c9811d73db4f23614759ad0f796118f576248db3b9b8d7610ce672caad564992",
    1: "dcfccd4d1988d8bbef16ccd72cc7e75b2e456cbcc8fb6615c0830755162121f9",
    2: "b5234caad9fc0b09bd948de5350738a81dab986dd671669a95c68dbba923f0ad",
    3: "ac95d90f1cc1426490f645f016f6c0b5eea8bf0cf1c97be79c9bda9eb0149d40",
    6: "79e140e77c8d0c78138f06ed82e9a68f0cdcadbb4a7e58688ac6e9dc1d2cd56b",
}
MAPPING_ROOTS = (
    (
        "ce3e1465b0dc6a6f2da9c3b22e751a459775cc5c752fc1432eaf83d844402cfb",
        "267f5427ad846812980f21e569591ce153eab292a42ac04f52efc390a8dd9dc4",
    ),
    ("6a618cb2e8e0ab927641f2260fd8927ba4d8af89eb9c608252513395ceba0881",),
    (
        "1c47e3d31eeb0c68c105375db4ac87104ef92dd1e94bd393ca4d3d7350792cb4",
        "f8e1c428db1f8cc3d0040b85782bd0473e27aeb4b05318c5b47e421b6cada7a0",
        "e3dbfb6c0493440b4b9016df5004ebc580f62f1e8a2d002c8267e84368a9de25",
        "b7ae6aec782fce70f797145a81d40b76354e466e73c9ec8179715f415d092031",
    ),
)


def reseal(value: dict[str, object]) -> bytes:
    changed = copy.deepcopy(value)
    changed.pop("evidence_sha256", None)
    header = changed["header"]
    assert isinstance(header, dict)
    for field in (
        "item_record_sha256",
        "execution_record_sha256",
        "evidence_summary_sha256",
    ):
        header.pop(field, None)
    items = changed["items"]
    assert isinstance(items, list)
    for item in items:
        item.pop("record_sha256", None)
    executions = changed["executions"]
    assert isinstance(executions, list)
    for execution in executions:
        execution.pop("record_sha256", None)
    summary = changed["summary"]
    assert isinstance(summary, dict)
    summary.pop("summary_sha256", None)
    return pressure.encode_evidence(changed)


class ScheduledMediaPressureTests(unittest.TestCase):
    def test_reference_wire_round_trip_and_golden_roots(self) -> None:
        evidence = pressure.build_reference_evidence()
        encoded = pressure.encode_evidence(evidence)

        self.assertEqual(len(encoded), 5472)
        self.assertEqual(
            pressure.decode_evidence(encoded),
            evidence,
        )
        self.assertEqual(
            pressure.validate_reference_evidence(evidence),
            evidence,
        )
        self.assertEqual(
            evidence["header"]["item_record_sha256"].hex(),
            ITEM_SECTION_ROOT,
        )
        self.assertEqual(
            evidence["header"]["execution_record_sha256"].hex(),
            EXECUTION_SECTION_ROOT,
        )
        self.assertEqual(
            evidence["header"]["evidence_summary_sha256"].hex(),
            SUMMARY_ROOT,
        )
        self.assertEqual(evidence["evidence_sha256"].hex(), EVIDENCE_ROOT)

        self.assertEqual(
            evidence["header"]["scenario_sha256"].hex(),
            "e6fc0e1b3d676c5ea89a2e54434bef0ac51e30f8b1ab85944bfc43e0cd34407b",
        )
        self.assertEqual(
            evidence["header"]["outcome_sha256"].hex(),
            "9eb52f76c2c68098d59f13bc6d5b456b2efd7297b936731543c33a2d9934596f",
        )
        self.assertEqual(
            evidence["header"]["trace_sha256"].hex(),
            "0868ce16006aa777bbc13d2454935607f375f5446e4c18cf78a958c2bee92169",
        )
        self.assertEqual(
            evidence["header"]["workload_summary_sha256"].hex(),
            "1c7d104f1d12627503c6d472f01bb0b07f41f200a8d1ecad23738d06dff80b0d",
        )

    def test_three_completed_items_execute_real_media_rules(self) -> None:
        artifacts = pressure.reference_media_artifacts()
        self.assertEqual(
            [artifact["ordinal"] for artifact in artifacts],
            [1, 2, 6],
        )
        self.assertEqual(
            [artifact["item"]["media_kind"] for artifact in artifacts],
            [
                workload.MEDIA_AUDIO,
                workload.MEDIA_VIDEO,
                workload.MEDIA_IMAGE,
            ],
        )
        self.assertEqual(
            [artifact["output"] for artifact in artifacts],
            [
                bytes.fromhex("00c05515"),
                bytes.fromhex("ff804000"),
                bytes.fromhex("00ff0000ff00ffffffffffff"),
            ],
        )
        self.assertEqual(
            [len(artifact["mappings"]) for artifact in artifacts],
            [2, 1, 4],
        )
        self.assertEqual(
            tuple(
                tuple(
                    mapping["mapping_sha256"].hex() for mapping in artifact["mappings"]
                )
                for artifact in artifacts
            ),
            MAPPING_ROOTS,
        )
        self.assertEqual(
            tuple(
                artifact["execution_receipt"]["receipt_sha256"].hex()
                for artifact in artifacts
            ),
            EXECUTION_RECEIPT_ROOTS,
        )
        self.assertEqual(
            [artifact["final_trace_index"] for artifact in artifacts],
            [25, 29, 31],
        )
        self.assertEqual(
            [artifact["final_trace"]["driver_step"] for artifact in artifacts],
            [16, 19, 20],
        )
        evidence = pressure.build_reference_evidence()
        self.assertEqual(
            [execution["service_sequence"] for execution in evidence["executions"]],
            [25, 29, 31],
        )

    def test_receipts_are_reconstructed_once_and_bound_to_executions(self) -> None:
        evidence = pressure.build_reference_evidence()
        expected_identity = {
            0: (0, 1, 0x7B55E0C2CCD6B860),
            1: (1, 2, 0x88FDCB3693B76844),
            2: (2, 3, 0xF9625428C79CCBE5),
            3: (3, 4, 0xC09104BF58980E96),
            6: (0, 5, 0x48702FDF726C4FFE),
        }
        for item in evidence["items"]:
            ordinal = item["ordinal"]
            if ordinal not in expected_identity:
                self.assertEqual(item["resource_bank_epoch"], 0)
                self.assertEqual(item["resource_receipt_sha256"], bytes(32))
                continue
            slot, generation, integrity = expected_identity[ordinal]
            self.assertEqual(item["resource_slot_index"], slot)
            self.assertEqual(item["resource_generation"], generation)
            self.assertEqual(item["resource_integrity"], integrity)
            self.assertEqual(
                item["resource_receipt_sha256"].hex(),
                RESOURCE_RECEIPT_ROOTS[ordinal],
            )

        by_ordinal = {item["ordinal"]: item for item in evidence["items"]}
        for execution in evidence["executions"]:
            item = by_ordinal[execution["ordinal"]]
            receipt = execution["execution_receipt"]
            self.assertEqual(
                (
                    receipt["resource_bank_epoch"],
                    receipt["resource_slot_index"],
                    receipt["resource_generation"],
                    receipt["resource_owner_key"],
                    receipt["resource_integrity"],
                ),
                (
                    item["resource_bank_epoch"],
                    item["resource_slot_index"],
                    item["resource_generation"],
                    item["resource_owner_key"],
                    item["resource_integrity"],
                ),
            )

    def test_terminal_negative_paths_have_no_execution(self) -> None:
        evidence = pressure.build_reference_evidence()
        execution_ordinals = {
            execution["ordinal"] for execution in evidence["executions"]
        }
        self.assertEqual(execution_ordinals, {1, 2, 6})
        for item in evidence["items"]:
            if item["ordinal"] in execution_ordinals:
                self.assertNotEqual(item["execution_index"], pressure.ABSENT)
            else:
                self.assertEqual(item["execution_index"], pressure.ABSENT)
        self.assertEqual(
            evidence["summary"],
            {
                "item_count": 7,
                "execution_count": 3,
                "admitted": 5,
                "rejected": 2,
                "completed": 3,
                "cancelled": 1,
                "timed_out": 1,
                "image_executions": 1,
                "audio_executions": 1,
                "video_executions": 1,
                "logical_units": 7,
                "output_bytes": 20,
                "publications": 3,
                "closed_terminal_sessions": 5,
                "maximum_live_receipts": 4,
                "zero_orphan_ownership": 1,
                "summary_sha256": bytes.fromhex(SUMMARY_ROOT),
            },
        )

    def test_every_wire_byte_mutation_and_truncation_rejects(self) -> None:
        encoded = pressure.encode_evidence(pressure.build_reference_evidence())
        for index in range(len(encoded)):
            mutated = bytearray(encoded)
            mutated[index] ^= 1
            try:
                pressure.decode_evidence(bytes(mutated))
            except pressure.ScheduledMediaPressureError:
                pass
            else:
                self.fail(f"byte mutation accepted at offset {index}")
        for length in range(len(encoded)):
            try:
                pressure.decode_evidence(encoded[:length])
            except pressure.ScheduledMediaPressureError:
                pass
            else:
                self.fail(f"truncation accepted at length {length}")
        with self.assertRaises(pressure.ScheduledMediaPressureError):
            pressure.decode_evidence(encoded + b"\x00")

    def test_rehashed_semantic_contradictions_reject(self) -> None:
        original = pressure.build_reference_evidence()
        contradictions = []

        changed = copy.deepcopy(original)
        changed["header"]["scenario_sha256"] = bytes((0x91,)) * 32
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["items"][1]["outcome"] = workload.OUTCOME_CANCELLED
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["items"][1]["resource_slot_index"] = 3
        changed["items"][1]["resource_receipt_sha256"] = bytes((0x92,)) * 32
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["executions"][0]["final_trace_index"] += 1
        changed["executions"][0]["service_sequence"] += 1
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["executions"][1]["request_epoch"] += 1
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["executions"][0]["execution_receipt"] = copy.deepcopy(
            changed["executions"][1]["execution_receipt"]
        )
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["executions"][2]["media_state_after_sha256"] = bytes((0x93,)) * 32
        contradictions.append(reseal(changed))

        changed = copy.deepcopy(original)
        changed["summary"]["publications"] = 2
        contradictions.append(reseal(changed))

        for index, contradiction in enumerate(contradictions):
            with self.subTest(index=index):
                try:
                    decoded = pressure.decode_evidence(contradiction)
                except pressure.ScheduledMediaPressureError:
                    continue
                with self.assertRaises(pressure.ScheduledMediaPressureError):
                    pressure.validate_reference_evidence(decoded)


if __name__ == "__main__":
    unittest.main()
