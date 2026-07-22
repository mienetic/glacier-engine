import hashlib
import json
import unittest

from bench import lane4_event_evidence as events


CAMPAIGN_ID = "11" * 32
OBSERVATION_ID = "22" * 32
OTHER_OBSERVATION_ID = "33" * 32
PROCESS_ID = 4242
COORDINATOR_THREAD_ID = 10
MODEL_INSTANCE_SHA256 = "44" * 32
BINARY_SHA256 = "55" * 32
MODEL_SHA256 = "66" * 32
WORKLOAD_SHA256 = "77" * 32
OPTIONS_SHA256 = "88" * 32

# This vector is intentionally literal.  It is the cross-language ABI anchor,
# not a value derived by the assertions below.
GOLDEN_LANE0_ROOT = "d2786d2e73e0569acf86a19d669ca9e3da03dd431fb7f2604c2c8b599a594964"
GOLDEN_EVENT_HASH = "49dcd944047aedc72f0b54a04251829019bd40f51a523ba5effd80930ca422f5"
GOLDEN_OBSERVATION_ROOT = (
    "d02b694da784074b664b1d2eeef241969d760724e21aa5645cc77af1d5af3216"
)
GOLDEN_PROMPT_SHA256 = (
    "45274d0d283fd1717ba4779c6ad51cd4537d74345100578cc6bbf632a5ab02c2"
)
GOLDEN_LANE_BINDING_SHA256 = (
    "bb23d15dc58f938f98e2728a182d206d605a41b8197eec12a25483c06257bab0"
)


def _json_wrapper(line: bytes) -> dict:
    return json.loads(line.decode("ascii"))


def _canonical_line(wrapper: dict) -> bytes:
    return events.canonical_ascii_json(wrapper) + b"\n"


def _token_payload(step: int, token: int, terminal: bool = False) -> dict:
    return {
        "observer_abi": "4754504f00000001",
        "step_index": events.u64_hex(step),
        "terminal": terminal,
        "token_id": events.u32_hex(token),
    }


def _prompt_tokens(lane: int) -> tuple[int, ...]:
    return tuple(100 + lane * 16 + index for index in range(16))


def _lane_expectation(lane: int) -> events.LaneExpectation:
    prompt_tokens = _prompt_tokens(lane)
    prompt_sha256 = events.derive_prompt_sha256(prompt_tokens)
    seed = 100 + lane
    return events.LaneExpectation(
        lane_index=lane,
        binding_sha256=events.derive_lane_binding_sha256(
            lane,
            prompt_sha256,
            len(prompt_tokens),
            seed,
        ),
        prompt_sha256=prompt_sha256,
        seed=seed,
        prompt_token_count=len(prompt_tokens),
    )


def _build_segment(
    *,
    observation_id: str = OBSERVATION_ID,
    segment: str = "lane-0",
    count: int = 3,
) -> events.EncodedSegment:
    builder = events.SegmentBuilder(CAMPAIGN_ID, observation_id, segment)
    for index in range(count):
        builder.append(
            monotonic_ns=1_000 + index * 10,
            thread_id=7,
            kind="token_published",
            payload=_token_payload(index, 40 + index, index + 1 == count),
        )
    return builder.finish()


def _golden_observation_segments() -> list[events.EncodedSegment]:
    result: list[events.EncodedSegment] = []
    for segment in events.SEGMENT_ORDER:
        builder = events.SegmentBuilder(CAMPAIGN_ID, OBSERVATION_ID, segment)
        if segment == "lane-0":
            builder.append(
                monotonic_ns=123_456_789,
                thread_id=7,
                kind="token_published",
                payload=_token_payload(0, 42),
            )
        result.append(builder.finish())
    return result


def _semantic_expectation(mode: str) -> events.ObservationExpectation:
    return events.ObservationExpectation(
        campaign_id=CAMPAIGN_ID,
        observation_id=OBSERVATION_ID,
        mode=mode,
        process_id=PROCESS_ID,
        model_instance_sha256=MODEL_INSTANCE_SHA256,
        binary_sha256=BINARY_SHA256,
        model_sha256=MODEL_SHA256,
        workload_sha256=WORKLOAD_SHA256,
        options_sha256=OPTIONS_SHA256,
        monotonic_clock_abi=events.MONOTONIC_CLOCK_ABI,
        monotonic_clock_source=events.PRODUCTION_CLOCK_SOURCE,
        lanes=tuple(_lane_expectation(lane) for lane in range(events.LANE_COUNT)),
    )


def _identity_payload() -> dict:
    return {
        "process_id": events.u64_hex(PROCESS_ID),
        "model_instance_sha256": MODEL_INSTANCE_SHA256,
    }


def _semantic_specs(mode: str) -> dict[str, list[dict]]:
    coordinator = [
        {
            "monotonic_ns": 90,
            "thread_id": COORDINATOR_THREAD_ID,
            "kind": "observation_contract",
            "payload": {
                "raw_schema": events.RAW_EVENT_SCHEMA,
                "observation_abi": events.u64_hex(events.OBSERVATION_ABI),
                "decode_lane4_abi": events.u64_hex(events.DECODE_LANE4_ABI),
                "m1_execution_abi": events.u64_hex(events.M1_EXECUTION_ABI),
                "token_publication_abi": events.u64_hex(events.TOKEN_PUBLICATION_ABI),
                "resource_bank_abi": events.u64_hex(events.RESOURCE_BANK_ABI),
                "resource_commit_observer_abi": events.u64_hex(
                    events.RESOURCE_COMMIT_OBSERVER_ABI
                ),
                "m1_barrier_abi": events.u64_hex(events.M1_BARRIER_ABI),
                "b4_post_commit_abi": events.u64_hex(events.B4_POST_COMMIT_ABI),
                "generation_state_abi": events.u64_hex(events.GENERATION_STATE_ABI),
                "generation_rng_abi": events.u64_hex(events.GENERATION_RNG_ABI),
                "monotonic_clock_abi": events.u64_hex(events.MONOTONIC_CLOCK_ABI),
                "monotonic_clock_source": events.PRODUCTION_CLOCK_SOURCE,
                "mode": mode,
                "process_id": events.u64_hex(PROCESS_ID),
                "coordinator_thread_id": events.u64_hex(COORDINATOR_THREAD_ID),
                "model_instance_sha256": MODEL_INSTANCE_SHA256,
                "binary_sha256": BINARY_SHA256,
                "model_sha256": MODEL_SHA256,
                "workload_sha256": WORKLOAD_SHA256,
                "options_sha256": OPTIONS_SHA256,
                "lane_count": events.u32_hex(events.LANE_COUNT),
                "worker_count": events.u32_hex(events.WORKER_COUNT),
                "tokens_per_lane": events.u32_hex(events.TOKENS_PER_LANE),
                "eos_disabled": True,
                "greedy_sampling": True,
                "physical_metrics_claimed": False,
            },
        },
        {
            "monotonic_ns": 100,
            "thread_id": COORDINATOR_THREAD_ID,
            "kind": "observation_begin",
            "payload": {"mode": mode, **_identity_payload()},
        },
    ]
    if mode == "m1x4":
        for lane in range(events.LANE_COUNT):
            coordinator.append(
                {
                    "monotonic_ns": 120 + lane,
                    "thread_id": 20 + lane,
                    "kind": "resource_committed",
                    "payload": {
                        **_identity_payload(),
                        "lane_index": events.u32_hex(lane),
                        "resource_bank_abi": events.u64_hex(events.RESOURCE_BANK_ABI),
                        "resource_commit_observer_abi": events.u64_hex(
                            events.RESOURCE_COMMIT_OBSERVER_ABI
                        ),
                        "claim_sha256": "90" * 32,
                        "receipt_sha256": f"{0xA0 + lane:02x}" * 32,
                    },
                }
            )
        coordinator.append(
            {
                "monotonic_ns": 130,
                "thread_id": 23,
                "kind": "resource_barrier",
                "payload": {
                    **_identity_payload(),
                    "barrier_abi": events.u64_hex(events.M1_BARRIER_ABI),
                    "arrival_count": events.u32_hex(events.LANE_COUNT),
                    "committed_snapshot_sha256": "b0" * 32,
                    "barrier_receipt_sha256": "b1" * 32,
                },
            }
        )
    else:
        coordinator.append(
            {
                "monotonic_ns": 120,
                "thread_id": 20,
                "kind": "resource_committed",
                "payload": {
                    **_identity_payload(),
                    "resource_bank_abi": events.u64_hex(events.RESOURCE_BANK_ABI),
                    "resource_commit_observer_abi": events.u64_hex(
                        events.RESOURCE_COMMIT_OBSERVER_ABI
                    ),
                    "b4_post_commit_abi": events.u64_hex(events.B4_POST_COMMIT_ABI),
                    "claim_sha256": "90" * 32,
                    "receipt_sha256": "a0" * 32,
                },
            }
        )
    coordinator.extend(
        [
            {
                "monotonic_ns": 1_000,
                "thread_id": COORDINATOR_THREAD_ID,
                "kind": "resource_released",
                "payload": {
                    **_identity_payload(),
                    "resource_bank_abi": events.u64_hex(events.RESOURCE_BANK_ABI),
                    "release_count": events.u32_hex(
                        events.LANE_COUNT if mode == "m1x4" else 1
                    ),
                    "released_snapshot_sha256": "c0" * 32,
                    "used_zero": True,
                },
            },
            {
                "monotonic_ns": 1_010,
                "thread_id": COORDINATOR_THREAD_ID,
                "kind": "observation_end",
                "payload": {
                    **_identity_payload(),
                    "mode": mode,
                    "status": "complete",
                    "published_token_count": events.u32_hex(events.TOTAL_TOKEN_EVENTS),
                },
            },
        ]
    )

    specs = {"coordinator": coordinator}
    for lane in range(events.LANE_COUNT):
        thread_id = 20 + lane if mode == "m1x4" else 20
        lane_expectation = _lane_expectation(lane)
        binding = lane_expectation.binding_sha256
        lane_specs = [
            {
                "monotonic_ns": 140 + lane if mode == "m1x4" else 110 + lane,
                "thread_id": thread_id,
                "kind": "lane_begin",
                "payload": {
                    **_identity_payload(),
                    "mode": mode,
                    "lane_index": events.u32_hex(lane),
                    "binding_sha256": binding,
                    "prompt_sha256": lane_expectation.prompt_sha256,
                    "seed": events.u64_hex(lane_expectation.seed),
                },
            }
        ]
        for step in range(events.TOKENS_PER_LANE):
            lane_specs.append(
                {
                    "monotonic_ns": 200 + step * 10 + lane,
                    "thread_id": thread_id,
                    "kind": "token_published",
                    "payload": _token_payload(
                        step,
                        1_000 + lane * events.TOKENS_PER_LANE + step,
                        step + 1 == events.TOKENS_PER_LANE,
                    ),
                }
            )
        output_tokens = [
            1_000 + lane * events.TOKENS_PER_LANE + step
            for step in range(events.TOKENS_PER_LANE)
        ]
        lane_specs.append(
            {
                "monotonic_ns": 900 + lane,
                "thread_id": thread_id,
                "kind": "lane_end",
                "payload": {
                    **_identity_payload(),
                    "mode": mode,
                    "lane_index": events.u32_hex(lane),
                    "binding_sha256": binding,
                    "published_count": events.u32_hex(events.TOKENS_PER_LANE),
                    "output_sha256": events.derive_output_token_sha256(output_tokens),
                    "kv_sha256": f"{0x70 + lane:02x}" * 32,
                    "generation_state_abi": events.u64_hex(events.GENERATION_STATE_ABI),
                    "generation_rng_abi": events.u64_hex(events.GENERATION_RNG_ABI),
                    "execution_abi": events.u64_hex(
                        events.M1_EXECUTION_ABI
                        if mode == "m1x4"
                        else events.DECODE_LANE4_ABI
                    ),
                    "thread_participants": events.u32_hex(
                        1 if mode == "m1x4" else events.WORKER_COUNT
                    ),
                    "kv_positions": events.u64_hex(
                        lane_expectation.prompt_token_count + events.TOKENS_PER_LANE - 1
                    ),
                    "sampling_calls": events.u64_hex(events.TOKENS_PER_LANE),
                    "rng_state": [
                        events.u64_hex(word)
                        for word in events.derive_xoshiro256_initial_state(
                            lane_expectation.seed
                        )
                    ],
                    "complete": True,
                },
            }
        )
        specs[f"lane-{lane}"] = lane_specs
    specs["sampler"] = [
        {
            "monotonic_ns": 0,
            "thread_id": 0,
            "kind": "physical_metrics_unavailable",
            "payload": {
                "status": "unavailable",
                "physical_metrics_claimed": False,
                "external_sampler_required": True,
                "symmetric_arms_required": True,
            },
        }
    ]
    return specs


def _encode_semantic_specs(
    specs: dict[str, list[dict]],
) -> tuple[list[events.EncodedSegment], str]:
    encoded: list[events.EncodedSegment] = []
    for segment in events.SEGMENT_ORDER:
        builder = events.SegmentBuilder(CAMPAIGN_ID, OBSERVATION_ID, segment)
        for spec in specs[segment]:
            builder.append(**spec)
        encoded.append(builder.finish())
    root = events.derive_observation_root(
        CAMPAIGN_ID,
        OBSERVATION_ID,
        [segment.commitment for segment in encoded],
    )
    return encoded, root


def _build_semantic_observation(
    mode: str,
) -> tuple[list[events.EncodedSegment], str, events.ObservationExpectation]:
    encoded, root = _encode_semantic_specs(_semantic_specs(mode))
    return encoded, root, _semantic_expectation(mode)


class Lane4EventEvidenceTests(unittest.TestCase):
    def test_prompt_and_lane_binding_cross_language_golden_vectors(self):
        tokens = (1, 0x01020304, 32_000, 0xFFFFFFFF)
        self.assertEqual(
            events.derive_prompt_sha256(tokens),
            GOLDEN_PROMPT_SHA256,
        )
        self.assertEqual(
            events.derive_lane_binding_sha256(
                2,
                GOLDEN_PROMPT_SHA256,
                len(tokens),
                0x0102030405060708,
            ),
            GOLDEN_LANE_BINDING_SHA256,
        )

    def test_prompt_and_binding_domain_length_and_endianness_are_pinned(self):
        tokens = (1, 0x01020304, 32_000, 0xFFFFFFFF)
        little_tokens = b"".join(token.to_bytes(4, "little") for token in tokens)
        prompt_variants = {
            "domain": (
                b"glacier-lane4-prompt-v2\x00"
                + len(tokens).to_bytes(8, "little")
                + little_tokens
            ),
            "length": (
                events.PROMPT_HASH_DOMAIN
                + (len(tokens) + 1).to_bytes(8, "little")
                + little_tokens
            ),
            "endianness": (
                events.PROMPT_HASH_DOMAIN
                + len(tokens).to_bytes(8, "big")
                + b"".join(token.to_bytes(4, "big") for token in tokens)
            ),
        }
        for mismatch, preimage in prompt_variants.items():
            with self.subTest(prompt=mismatch):
                self.assertNotEqual(
                    hashlib.sha256(preimage).hexdigest(),
                    GOLDEN_PROMPT_SHA256,
                )

        abi_values = (
            events.OBSERVATION_ABI,
            events.DECODE_LANE4_ABI,
            events.GENERATION_STATE_ABI,
            events.GENERATION_RNG_ABI,
        )

        def binding_preimage(
            domain: bytes,
            prompt_count: int,
            byteorder: str,
        ) -> bytes:
            return b"".join(
                (
                    domain,
                    *(value.to_bytes(8, byteorder) for value in abi_values),
                    (2).to_bytes(4, byteorder),
                    prompt_count.to_bytes(8, byteorder),
                    bytes.fromhex(GOLDEN_PROMPT_SHA256),
                    (0x0102030405060708).to_bytes(8, byteorder),
                    events.TOKENS_PER_LANE.to_bytes(4, byteorder),
                    b"\x01\x01",
                )
            )

        canonical = binding_preimage(
            events.LANE_BINDING_HASH_DOMAIN,
            len(tokens),
            "little",
        )
        self.assertEqual(
            hashlib.sha256(canonical).hexdigest(),
            GOLDEN_LANE_BINDING_SHA256,
        )
        binding_variants = {
            "domain": binding_preimage(
                b"glacier-lane4-lane-binding-v2\x00",
                len(tokens),
                "little",
            ),
            "length": binding_preimage(
                events.LANE_BINDING_HASH_DOMAIN,
                len(tokens) + 1,
                "little",
            ),
            "endianness": binding_preimage(
                events.LANE_BINDING_HASH_DOMAIN,
                len(tokens),
                "big",
            ),
        }
        for mismatch, preimage in binding_variants.items():
            with self.subTest(binding=mismatch):
                self.assertNotEqual(
                    hashlib.sha256(preimage).hexdigest(),
                    GOLDEN_LANE_BINDING_SHA256,
                )

        with self.assertRaisesRegex(events.EventEvidenceError, "non-empty"):
            events.derive_prompt_sha256(())
        with self.assertRaisesRegex(events.EventEvidenceError, "four lanes"):
            events.derive_lane_binding_sha256(
                4,
                GOLDEN_PROMPT_SHA256,
                len(tokens),
                0x0102030405060708,
            )

    def test_explicit_golden_vector(self):
        encoded = _golden_observation_segments()
        lane0 = encoded[1]
        self.assertEqual(
            lane0.commitment.segment_root_sha256,
            GOLDEN_LANE0_ROOT,
        )
        record = events.decode_event_line(lane0.data)
        self.assertEqual(record.previous_sha256, GOLDEN_LANE0_ROOT)
        self.assertEqual(record.event_sha256, GOLDEN_EVENT_HASH)
        self.assertEqual(lane0.commitment.segment_tip_sha256, GOLDEN_EVENT_HASH)

        commitments = [item.commitment for item in encoded]
        root = events.derive_observation_root(
            CAMPAIGN_ID,
            OBSERVATION_ID,
            commitments,
        )
        self.assertEqual(root, GOLDEN_OBSERVATION_ROOT)
        self.assertEqual(
            events.verify_observation_root(
                CAMPAIGN_ID,
                OBSERVATION_ID,
                commitments,
                GOLDEN_OBSERVATION_ROOT,
            ),
            GOLDEN_OBSERVATION_ROOT,
        )

    def test_canonical_line_round_trip_and_exact_fields(self):
        encoded = _build_segment(count=1)
        records = events.verify_segment(encoded.data, encoded.commitment)
        self.assertEqual(len(records), 1)
        core = records[0].core
        self.assertEqual(set(core), events.CORE_FIELDS)
        self.assertEqual(core["local_sequence"], "0000000000000000")
        self.assertEqual(core["monotonic_ns"], "00000000000003e8")
        self.assertEqual(core["thread_id"], "0000000000000007")
        self.assertEqual(core["payload"]["token_id"], "00000028")
        self.assertTrue(core["payload"]["terminal"])

    def test_wrapper_unknown_and_missing_fields_are_rejected(self):
        line = _build_segment(count=1).data
        wrapper = _json_wrapper(line)
        wrapper["asserted_valid"] = True
        with self.assertRaisesRegex(events.EventEvidenceError, "unknown"):
            events.decode_event_line(_canonical_line(wrapper))

        wrapper = _json_wrapper(line)
        del wrapper["event_sha256"]
        with self.assertRaisesRegex(events.EventEvidenceError, "missing"):
            events.decode_event_line(_canonical_line(wrapper))

    def test_core_unknown_and_missing_fields_are_rejected(self):
        line = _build_segment(count=1).data
        wrapper = _json_wrapper(line)
        wrapper["core"]["duration_ns"] = "0000000000000001"
        with self.assertRaisesRegex(events.EventEvidenceError, "unknown"):
            events.decode_event_line(_canonical_line(wrapper))

        wrapper = _json_wrapper(line)
        del wrapper["core"]["thread_id"]
        with self.assertRaisesRegex(events.EventEvidenceError, "missing"):
            events.decode_event_line(_canonical_line(wrapper))

    def test_noncanonical_json_is_rejected_before_use(self):
        line = _build_segment(count=1).data
        noncanonical = line.replace(b'{"core"', b'{ "core"', 1)
        with self.assertRaisesRegex(events.EventEvidenceError, "not canonical"):
            events.decode_event_line(noncanonical)

        wrapper = _json_wrapper(line)
        reordered = (
            b'{"previous_sha256":'
            + json.dumps(wrapper["previous_sha256"]).encode("ascii")
            + b',"event_sha256":'
            + json.dumps(wrapper["event_sha256"]).encode("ascii")
            + b',"core":'
            + events.canonical_ascii_json(wrapper["core"])
            + b"}\n"
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "not canonical"):
            events.decode_event_line(reordered)

    def test_duplicate_json_keys_are_rejected_at_every_depth(self):
        line = _build_segment(count=1).data
        duplicate_wrapper = line.replace(
            b'{"core":',
            b'{"core":{},"core":',
            1,
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "duplicate JSON key"):
            events.decode_event_line(duplicate_wrapper)

        duplicate_core = line.replace(
            b'{"campaign_id":',
            b'{"campaign_id":"' + b"00" * 32 + b'","campaign_id":',
            1,
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "duplicate JSON key"):
            events.decode_event_line(duplicate_core)

    def test_fixed_width_and_lowercase_encodings_are_mandatory(self):
        line = _build_segment(count=1).data
        wrapper = _json_wrapper(line)
        wrapper["core"]["local_sequence"] = "0"
        with self.assertRaisesRegex(events.EventEvidenceError, "sixteen lowercase"):
            events.decode_event_line(_canonical_line(wrapper))

        wrapper = _json_wrapper(line)
        wrapper["core"]["thread_id"] = "000000000000000A"
        with self.assertRaisesRegex(events.EventEvidenceError, "sixteen lowercase"):
            events.decode_event_line(_canonical_line(wrapper))

        wrapper = _json_wrapper(line)
        wrapper["previous_sha256"] = "0" * 63
        with self.assertRaisesRegex(events.EventEvidenceError, "64 lowercase"):
            events.decode_event_line(_canonical_line(wrapper))

    def test_json_numbers_null_and_non_ascii_are_forbidden(self):
        with self.assertRaisesRegex(events.EventEvidenceError, "JSON numbers"):
            events.canonical_ascii_json({"timestamp": 1})
        with self.assertRaisesRegex(events.EventEvidenceError, "JSON numbers"):
            events.canonical_ascii_json({"timestamp": None})
        with self.assertRaisesRegex(events.EventEvidenceError, "printable ASCII"):
            events.canonical_ascii_json(
                {"label": "caf\N{LATIN SMALL LETTER E WITH ACUTE}"}
            )

    def test_payload_mutation_breaks_the_event_commitment(self):
        line = _build_segment(count=1).data
        wrapper = _json_wrapper(line)
        wrapper["core"]["payload"]["token_id"] = "00000029"
        mutated = _canonical_line(wrapper)
        with self.assertRaisesRegex(events.EventEvidenceError, "inconsistent"):
            events.decode_event_line(mutated)

    def test_delete_event_is_detected(self):
        encoded = _build_segment()
        lines = encoded.data.splitlines(keepends=True)
        deleted = lines[0] + lines[2]
        with self.assertRaisesRegex(events.EventEvidenceError, "event count"):
            events.verify_segment(deleted, encoded.commitment)

    def test_duplicate_event_is_detected(self):
        encoded = _build_segment()
        lines = encoded.data.splitlines(keepends=True)
        duplicated = lines[0] + lines[1] + lines[1] + lines[2]
        with self.assertRaisesRegex(events.EventEvidenceError, "event count"):
            events.verify_segment(duplicated, encoded.commitment)

    def test_reordered_events_are_detected(self):
        encoded = _build_segment()
        lines = encoded.data.splitlines(keepends=True)
        reordered = lines[1] + lines[0] + lines[2]
        with self.assertRaisesRegex(events.EventEvidenceError, "local_sequence"):
            events.verify_segment(reordered, encoded.commitment)

    def test_truncated_event_or_segment_tip_is_detected(self):
        encoded = _build_segment()
        with self.assertRaisesRegex(events.EventEvidenceError, "truncated"):
            events.verify_segment(encoded.data[:-1], encoded.commitment)

        shortened_commitment = events.SegmentCommitment(
            campaign_id=encoded.commitment.campaign_id,
            observation_id=encoded.commitment.observation_id,
            segment=encoded.commitment.segment,
            event_count=encoded.commitment.event_count,
            segment_root_sha256=encoded.commitment.segment_root_sha256,
            segment_tip_sha256="00" * 32,
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "committed tip"):
            events.verify_segment(encoded.data, shortened_commitment)

    def test_previous_link_mutation_is_detected_even_with_a_rehashed_event(self):
        encoded = _build_segment()
        lines = encoded.data.splitlines(keepends=True)
        wrapper = _json_wrapper(lines[1])
        wrapper["previous_sha256"] = encoded.commitment.segment_root_sha256
        wrapper["event_sha256"] = events.derive_event_sha256(
            wrapper["previous_sha256"],
            wrapper["core"],
        )
        lines[1] = _canonical_line(wrapper)
        with self.assertRaisesRegex(events.EventEvidenceError, "chain is broken"):
            events.verify_segment(b"".join(lines), encoded.commitment)

    def test_replay_across_observations_is_rejected(self):
        first = _build_segment(observation_id=OBSERVATION_ID, count=1)
        second = _build_segment(observation_id=OTHER_OBSERVATION_ID, count=1)
        with self.assertRaisesRegex(events.EventEvidenceError, "another observation"):
            events.verify_segment(first.data, second.commitment)

    def test_observation_root_requires_all_segments_in_fixed_order(self):
        commitments = [item.commitment for item in _golden_observation_segments()]
        with self.assertRaisesRegex(events.EventEvidenceError, "fixed order"):
            events.derive_observation_root(
                CAMPAIGN_ID,
                OBSERVATION_ID,
                list(reversed(commitments)),
            )
        with self.assertRaisesRegex(events.EventEvidenceError, "exactly six"):
            events.derive_observation_root(
                CAMPAIGN_ID,
                OBSERVATION_ID,
                commitments[:-1],
            )

        replayed = commitments.copy()
        replayed[1] = _build_segment(
            observation_id=OTHER_OBSERVATION_ID,
            count=0,
        ).commitment
        with self.assertRaisesRegex(events.EventEvidenceError, "another observation"):
            events.derive_observation_root(
                CAMPAIGN_ID,
                OBSERVATION_ID,
                replayed,
            )

    def test_monotonic_segment_time_is_enforced(self):
        builder = events.SegmentBuilder(CAMPAIGN_ID, OBSERVATION_ID, "lane-0")
        builder.append(
            monotonic_ns=10,
            thread_id=1,
            kind="lane_begin",
            payload={},
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "moved backwards"):
            builder.append(
                monotonic_ns=9,
                thread_id=1,
                kind="token_published",
                payload=_token_payload(0, 1, True),
            )


class Lane4SemanticEvidenceTests(unittest.TestCase):
    def _validate_specs(
        self,
        mode: str,
        specs: dict[str, list[dict]],
    ) -> events.ValidatedObservationEvidence:
        encoded, root = _encode_semantic_specs(specs)
        return events.validate_raw_event_v3_observation(
            encoded,
            root,
            _semantic_expectation(mode),
        )

    def test_complete_m1x4_and_b4_logical_observations(self):
        for mode in ("m1x4", "b4"):
            with self.subTest(mode=mode):
                encoded, root, expectation = _build_semantic_observation(mode)
                result = events.validate_raw_event_v3_observation(
                    encoded,
                    root,
                    expectation,
                )
                self.assertEqual(result.contract.mode, mode)
                self.assertEqual(
                    result.contract.monotonic_clock_abi,
                    events.MONOTONIC_CLOCK_ABI,
                )
                self.assertEqual(
                    result.contract.monotonic_clock_source,
                    events.PRODUCTION_CLOCK_SOURCE,
                )
                self.assertEqual(len(result.lanes), events.LANE_COUNT)
                self.assertTrue(result.logical_observation_available)
                self.assertFalse(result.campaign_publication_available)
                self.assertIn(
                    "schedule balance",
                    result.campaign_publication_unavailable_reason,
                )
                self.assertFalse(result.physical_metrics_available)
                self.assertFalse(result.physical_performance_publication_available)
                self.assertTrue(
                    all(
                        len(lane.token_ids) == events.TOKENS_PER_LANE
                        for lane in result.lanes
                    )
                )
                self.assertTrue(all(lane.kv_positions == 79 for lane in result.lanes))
                self.assertTrue(all(lane.sampling_calls == 64 for lane in result.lanes))
                self.assertTrue(all(len(lane.rng_state) == 4 for lane in result.lanes))
                distinct_threads = {lane.thread_id for lane in result.lanes}
                self.assertEqual(
                    len(distinct_threads),
                    events.WORKER_COUNT if mode == "m1x4" else 1,
                )

    def test_semantic_api_requires_out_of_band_identity_and_root(self):
        encoded, root, expectation = _build_semantic_observation("m1x4")
        substituted = events.ObservationExpectation(
            **{
                **expectation.__dict__,
                "binary_sha256": "99" * 32,
            }
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "binary_sha256"):
            events.validate_raw_event_v3_observation(encoded, root, substituted)
        with self.assertRaisesRegex(events.EventEvidenceError, "root commitment"):
            events.validate_raw_event_v3_observation(
                encoded,
                "00" * 32,
                expectation,
            )

    def test_production_monotonic_clock_is_pinned_on_wire_and_out_of_band(self):
        specs = _semantic_specs("m1x4")
        specs["coordinator"][0]["payload"]["monotonic_clock_abi"] = events.u64_hex(
            events.MONOTONIC_CLOCK_ABI + 1
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "admitted ABI"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["coordinator"][0]["payload"]["monotonic_clock_source"] = "wall-clock"
        with self.assertRaisesRegex(events.EventEvidenceError, "boot-monotonic source"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        del specs["coordinator"][0]["payload"]["monotonic_clock_source"]
        with self.assertRaisesRegex(events.EventEvidenceError, "missing"):
            self._validate_specs("m1x4", specs)

        encoded, root, expectation = _build_semantic_observation("m1x4")
        wrong_abi = events.ObservationExpectation(
            **{
                **expectation.__dict__,
                "monotonic_clock_abi": events.MONOTONIC_CLOCK_ABI + 1,
            }
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "production clock ABI"):
            events.validate_raw_event_v3_observation(encoded, root, wrong_abi)

        wrong_source = events.ObservationExpectation(
            **{
                **expectation.__dict__,
                "monotonic_clock_source": "injected-test-clock",
            }
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "boot-monotonic source"):
            events.validate_raw_event_v3_observation(encoded, root, wrong_source)

    def test_missing_duplicate_and_unknown_lane_events_fail_closed(self):
        cases = []
        missing = _semantic_specs("m1x4")
        del missing["lane-0"][5]
        cases.append(("missing", missing, "requires lane_begin"))

        duplicate = _semantic_specs("m1x4")
        duplicate["lane-0"].insert(1, dict(duplicate["lane-0"][1]))
        cases.append(("duplicate", duplicate, "requires lane_begin"))

        unknown = _semantic_specs("m1x4")
        unknown["lane-0"][1]["kind"] = "aggregate_token"
        cases.append(("unknown", unknown, "kind must be 'token_published'"))

        for label, specs, message in cases:
            with self.subTest(case=label):
                with self.assertRaisesRegex(events.EventEvidenceError, message):
                    self._validate_specs("m1x4", specs)

    def test_token_step_terminal_and_observer_abi_are_exact(self):
        mutations = (
            ("step", "step_index", events.u64_hex(9), "not contiguous"),
            ("terminal", "terminal", True, "only on token 64"),
            (
                "observer ABI",
                "observer_abi",
                events.u64_hex(events.TOKEN_PUBLICATION_ABI + 1),
                "observer ABI",
            ),
        )
        for label, field, value, message in mutations:
            with self.subTest(case=label):
                specs = _semantic_specs("b4")
                specs["lane-2"][4]["payload"][field] = value
                with self.assertRaisesRegex(events.EventEvidenceError, message):
                    self._validate_specs("b4", specs)

    def test_pid_and_model_instance_substitution_fail_closed(self):
        for field, value, message in (
            ("process_id", events.u64_hex(PROCESS_ID + 1), "another process"),
            ("model_instance_sha256", "99" * 32, "another model instance"),
        ):
            with self.subTest(field=field):
                specs = _semantic_specs("m1x4")
                specs["lane-1"][-1]["payload"][field] = value
                with self.assertRaisesRegex(events.EventEvidenceError, message):
                    self._validate_specs("m1x4", specs)

    def test_lane_binding_prompt_and_seed_require_out_of_band_match(self):
        encoded, root, expectation = _build_semantic_observation("m1x4")
        for field, value in (
            ("binding_sha256", "91" * 32),
            ("prompt_sha256", "92" * 32),
            ("seed", 9_999),
        ):
            with self.subTest(field=field):
                lanes = list(expectation.lanes)
                original = lanes[2]
                lanes[2] = events.LaneExpectation(
                    **{
                        **original.__dict__,
                        field: value,
                    }
                )
                substituted = events.ObservationExpectation(
                    **{
                        **expectation.__dict__,
                        "lanes": tuple(lanes),
                    }
                )
                with self.assertRaisesRegex(
                    events.EventEvidenceError,
                    "trusted workload binding",
                ):
                    events.validate_raw_event_v3_observation(
                        encoded,
                        root,
                        substituted,
                    )

    def test_output_digest_is_recomputed_from_all_published_tokens(self):
        specs = _semantic_specs("b4")
        specs["lane-3"][-1]["payload"]["output_sha256"] = "93" * 32
        with self.assertRaisesRegex(events.EventEvidenceError, "output digest"):
            self._validate_specs("b4", specs)

        token_ids = tuple(range(events.TOKENS_PER_LANE))
        self.assertEqual(
            events.derive_output_token_sha256(token_ids),
            "57535f3a8fc35680183d6f1494a32ea7cdce749d35f353861cfa0c4f808698d7",
        )

    def test_complete_generation_state_receipt_is_exact_and_fixed_width(self):
        mutations = (
            ("kv positions", "kv_positions", events.u64_hex(78), "KV position"),
            (
                "sampling calls",
                "sampling_calls",
                events.u64_hex(63),
                "sampling call count",
            ),
            (
                "rng word count",
                "rng_state",
                [events.u64_hex(1)] * 3,
                "four words",
            ),
            (
                "rng width",
                "rng_state",
                ["1", events.u64_hex(2), events.u64_hex(3), events.u64_hex(4)],
                "sixteen lowercase",
            ),
            (
                "zero rng",
                "rng_state",
                [events.u64_hex(0)] * 4,
                "must not be all zero",
            ),
            (
                "wrong transition",
                "rng_state",
                [events.u64_hex(word) for word in (1, 2, 3, 4)],
                "does not match its greedy workload seed",
            ),
        )
        for label, field, value, message in mutations:
            with self.subTest(case=label):
                specs = _semantic_specs("m1x4")
                specs["lane-0"][-1]["payload"][field] = value
                with self.assertRaisesRegex(events.EventEvidenceError, message):
                    self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["lane-0"][-1]["payload"]["rng_probe"] = events.u64_hex(1)
        with self.assertRaisesRegex(events.EventEvidenceError, "unknown"):
            self._validate_specs("m1x4", specs)

        self.assertEqual(
            events.derive_xoshiro256_initial_state(0),
            (
                0xE220_A839_7B1D_CDAF,
                0x6E78_9E6A_A1B9_65F4,
                0x06C4_5D18_8009_454F,
                0xF88B_B8A8_724C_81EC,
            ),
        )

    def test_thread_substitution_and_topology_fail_closed(self):
        specs = _semantic_specs("m1x4")
        specs["lane-1"][5]["thread_id"] = 99
        with self.assertRaisesRegex(events.EventEvidenceError, "thread substitution"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        for record in specs["lane-1"]:
            record["thread_id"] = 20
        specs["coordinator"][3]["thread_id"] = 20
        with self.assertRaisesRegex(events.EventEvidenceError, "four distinct"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("b4")
        for record in specs["lane-3"]:
            record["thread_id"] = 23
        with self.assertRaisesRegex(events.EventEvidenceError, "one cohort root"):
            self._validate_specs("b4", specs)

        specs = _semantic_specs("b4")
        specs["coordinator"][-1]["thread_id"] = 99
        with self.assertRaisesRegex(
            events.EventEvidenceError, "coordinator substitution"
        ):
            self._validate_specs("b4", specs)

    def test_resource_commit_barrier_and_release_are_mode_exact(self):
        specs = _semantic_specs("m1x4")
        specs["coordinator"][3]["payload"]["lane_index"] = events.u32_hex(0)
        with self.assertRaisesRegex(events.EventEvidenceError, "lanes are not unique"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["coordinator"][6]["payload"]["arrival_count"] = events.u32_hex(3)
        with self.assertRaisesRegex(events.EventEvidenceError, "four arrivals"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("b4")
        specs["coordinator"][2]["payload"]["b4_post_commit_abi"] = events.u64_hex(
            events.B4_POST_COMMIT_ABI + 1
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "post-commit ABI"):
            self._validate_specs("b4", specs)

        specs = _semantic_specs("b4")
        specs["coordinator"][-2]["payload"]["used_zero"] = False
        with self.assertRaisesRegex(events.EventEvidenceError, "not fully released"):
            self._validate_specs("b4", specs)

    def test_cross_segment_causality_and_m1_overlap_are_required(self):
        specs = _semantic_specs("m1x4")
        specs["lane-0"][0]["monotonic_ns"] = 125
        with self.assertRaisesRegex(events.EventEvidenceError, "four-way barrier"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["lane-0"][-1]["monotonic_ns"] = 1_001
        with self.assertRaisesRegex(events.EventEvidenceError, "release preceded"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["lane-0"][-1]["monotonic_ns"] = 142
        with self.assertRaisesRegex(events.EventEvidenceError, "moved backwards"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        for record in specs["lane-0"]:
            record["monotonic_ns"] += 1_000
        with self.assertRaisesRegex(
            events.EventEvidenceError, "four-way execution overlap"
        ):
            self._validate_specs("m1x4", specs)

    def test_contract_abi_shape_and_mode_are_fail_closed(self):
        specs = _semantic_specs("m1x4")
        specs["coordinator"][0]["payload"]["decode_lane4_abi"] = events.u64_hex(
            events.DECODE_LANE4_ABI - 1
        )
        with self.assertRaisesRegex(events.EventEvidenceError, "admitted ABI"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["coordinator"][0]["payload"]["worker_count"] = events.u32_hex(5)
        with self.assertRaisesRegex(events.EventEvidenceError, "must equal 4"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["coordinator"][0]["payload"]["greedy_sampling"] = False
        with self.assertRaisesRegex(events.EventEvidenceError, "greedy sampling"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        del specs["coordinator"][0]["payload"]["options_sha256"]
        with self.assertRaisesRegex(events.EventEvidenceError, "missing"):
            self._validate_specs("m1x4", specs)

        specs = _semantic_specs("m1x4")
        specs["coordinator"][0]["payload"]["self_asserted"] = True
        with self.assertRaisesRegex(events.EventEvidenceError, "unknown"):
            self._validate_specs("m1x4", specs)

    def test_physical_claims_fail_until_external_symmetric_sampler_abi_exists(self):
        specs = _semantic_specs("b4")
        specs["coordinator"][0]["payload"]["physical_metrics_claimed"] = True
        with self.assertRaisesRegex(
            events.EventEvidenceError,
            "external symmetric sampler ABI",
        ):
            self._validate_specs("b4", specs)

        specs = _semantic_specs("b4")
        specs["sampler"] = []
        with self.assertRaisesRegex(events.EventEvidenceError, "exactly one"):
            self._validate_specs("b4", specs)

        specs = _semantic_specs("b4")
        specs["sampler"][0]["thread_id"] = 77
        with self.assertRaisesRegex(events.EventEvidenceError, "zero thread sentinel"):
            self._validate_specs("b4", specs)

        specs = _semantic_specs("b4")
        specs["sampler"][0]["payload"]["symmetric_arms_required"] = False
        with self.assertRaisesRegex(events.EventEvidenceError, "symmetric sampling"):
            self._validate_specs("b4", specs)

    def test_semantic_segment_from_another_observation_is_rejected(self):
        encoded, root, expectation = _build_semantic_observation("m1x4")
        foreign_builder = events.SegmentBuilder(
            CAMPAIGN_ID,
            OTHER_OBSERVATION_ID,
            "lane-2",
        )
        foreign = foreign_builder.finish()
        substituted = list(encoded)
        substituted[3] = foreign
        with self.assertRaisesRegex(events.EventEvidenceError, "another observation"):
            events.validate_raw_event_v3_observation(
                substituted,
                root,
                expectation,
            )


if __name__ == "__main__":
    unittest.main()
