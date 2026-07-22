#!/usr/bin/env python3
"""Canonical, hash-chained event primitives for grounded DecodeLane4 evidence.

This module is deliberately narrower than a benchmark runner.  It defines the
legacy lane-at-a-time observer profile for raw-event-v3, shared with the
standalone Zig wire codec and the offline Python validator.  It cannot encode
TokenTxn wave prepare/commit receipts and must not be used as runner-v6
transaction evidence.  The actual-model adapter remains fail-closed until a
new transaction-aware schema can capture every required field; no Zig
six-segment runner emitter exists in this tranche:

* a canonical ASCII JSONL event wrapper;
* exact fixed-width integer and digest encodings;
* independent per-segment SHA-256 chains;
* an observation root that commits the six segments in a fixed order; and
* a fail-closed, fixed-four-lane logical observation contract.

It does not accept raw-v2 envelopes, synthesize events from aggregates, or
calculate performance.  The semantic contract proves logical execution
identity, token publication, resource lifecycle, and causal intervals.  It
does not prove a balanced campaign, environment brackets, emitter challenge,
repetitions/confidence intervals, or a thread-temperature policy, so one valid
observation is never publication-ready performance evidence.  It also
does *not* make physical power/RSS/energy evidence available: until a separate
external, symmetric sampler ABI exists, the sampler segment must contain one
explicit ``physical_metrics_unavailable`` marker and a physical claim fails
closed.  Payload values are restricted to canonical maps, arrays, printable
ASCII strings, and booleans so JSON numbers cannot silently lose u64 precision.

Resource claim, receipt, and snapshot digests in this profile are opaque
summary commitments.  Their values cannot be recomputed from the event stream;
their truth still depends on the future pinned-emitter identity/challenge gate.
Consequently they are useful for equality and tamper detection only, never as
standalone proof that the engine performed the asserted resource transition.

Semantic timestamps admit only runner clock ABI ``0x474d4e4300000001`` with
wire source ``os-boot-monotonic``.  That source names the production
``MonotonicClock.system().isSystem()`` path (Darwin ``UPTIME_RAW``, Linux
``MONOTONIC_RAW``, and the OS monotonic clock elsewhere); injected test clocks
and wall time are not valid semantic evidence.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


RAW_EVENT_SCHEMA = "glacier.decode-lane4/raw-event-evidence-v3"
EVENT_STREAM_SCHEMA = "glacier.decode-lane4/event-stream-v1"
EVENT_SCHEMA = "glacier.decode-lane4/event-v1"

# Exact engine and runner ABIs admitted by the legacy-observer raw-event-v3
# profile. DecodeLane4 v4 identifies the engine build; it does not make this
# lane-at-a-time wire profile TokenTxn-aware.
# These are encoded as fixed-width lowercase strings in JSON; Python integers
# are used only by the in-process API and never appear on the wire.
OBSERVATION_ABI = 0x474C_344F_0000_0001
DECODE_LANE4_ABI = 0x4744_4C34_0000_0004
M1_EXECUTION_ABI = 0x474D_3145_0000_0002
TOKEN_PUBLICATION_ABI = 0x4754_504F_0000_0001
RESOURCE_BANK_ABI = 0x4752_424B_0000_0001
RESOURCE_COMMIT_OBSERVER_ABI = 0x4752_434F_0000_0001
M1_BARRIER_ABI = 0x474D_3142_0000_0001
B4_POST_COMMIT_ABI = 0x4742_3443_0000_0001
GENERATION_STATE_ABI = 0x4747_5354_0000_0001
GENERATION_RNG_ABI = 0x584F_5332_3536_0001
MONOTONIC_CLOCK_ABI = 0x474D_4E43_0000_0001
PRODUCTION_CLOCK_SOURCE = "os-boot-monotonic"

OUTPUT_TOKEN_HASH_DOMAIN = b"glacier-output-token-state-v1\x00"
PROMPT_HASH_DOMAIN = b"glacier-lane4-prompt-v1\x00"
LANE_BINDING_HASH_DOMAIN = b"glacier-lane4-lane-binding-v1\x00"

LANE_COUNT = 4
WORKER_COUNT = 4
TOKENS_PER_LANE = 64
TOTAL_TOKEN_EVENTS = LANE_COUNT * TOKENS_PER_LANE
MODES = frozenset({"m1x4", "b4"})

SEGMENT_ORDER = (
    "coordinator",
    "lane-0",
    "lane-1",
    "lane-2",
    "lane-3",
    "sampler",
)

SEGMENT_ROOT_DOMAIN = b"glacier-lane4-segment-root-v1\x00"
EVENT_DOMAIN = b"glacier-lane4-event-v1\x00"
OBSERVATION_ROOT_DOMAIN = b"glacier-lane4-observation-root-v1\x00"

CORE_FIELDS = frozenset(
    {
        "schema",
        "campaign_id",
        "observation_id",
        "segment",
        "local_sequence",
        "monotonic_ns",
        "thread_id",
        "kind",
        "payload",
    }
)
WRAPPER_FIELDS = frozenset({"core", "previous_sha256", "event_sha256"})

CONTRACT_PAYLOAD_FIELDS = frozenset(
    {
        "raw_schema",
        "observation_abi",
        "decode_lane4_abi",
        "m1_execution_abi",
        "token_publication_abi",
        "resource_bank_abi",
        "resource_commit_observer_abi",
        "m1_barrier_abi",
        "b4_post_commit_abi",
        "generation_state_abi",
        "generation_rng_abi",
        "monotonic_clock_abi",
        "monotonic_clock_source",
        "mode",
        "process_id",
        "coordinator_thread_id",
        "model_instance_sha256",
        "binary_sha256",
        "model_sha256",
        "workload_sha256",
        "options_sha256",
        "lane_count",
        "worker_count",
        "tokens_per_lane",
        "eos_disabled",
        "greedy_sampling",
        "physical_metrics_claimed",
    }
)
OBSERVATION_BEGIN_PAYLOAD_FIELDS = frozenset(
    {"mode", "process_id", "model_instance_sha256"}
)
M1_RESOURCE_COMMITTED_PAYLOAD_FIELDS = frozenset(
    {
        "process_id",
        "model_instance_sha256",
        "lane_index",
        "resource_bank_abi",
        "resource_commit_observer_abi",
        "claim_sha256",
        "receipt_sha256",
    }
)
B4_RESOURCE_COMMITTED_PAYLOAD_FIELDS = frozenset(
    {
        "process_id",
        "model_instance_sha256",
        "resource_bank_abi",
        "resource_commit_observer_abi",
        "b4_post_commit_abi",
        "claim_sha256",
        "receipt_sha256",
    }
)
M1_RESOURCE_BARRIER_PAYLOAD_FIELDS = frozenset(
    {
        "process_id",
        "model_instance_sha256",
        "barrier_abi",
        "arrival_count",
        "committed_snapshot_sha256",
        "barrier_receipt_sha256",
    }
)
RESOURCE_RELEASED_PAYLOAD_FIELDS = frozenset(
    {
        "process_id",
        "model_instance_sha256",
        "resource_bank_abi",
        "release_count",
        "released_snapshot_sha256",
        "used_zero",
    }
)
OBSERVATION_END_PAYLOAD_FIELDS = frozenset(
    {
        "mode",
        "process_id",
        "model_instance_sha256",
        "status",
        "published_token_count",
    }
)
LANE_BEGIN_PAYLOAD_FIELDS = frozenset(
    {
        "mode",
        "process_id",
        "model_instance_sha256",
        "lane_index",
        "binding_sha256",
        "prompt_sha256",
        "seed",
    }
)
TOKEN_PUBLISHED_PAYLOAD_FIELDS = frozenset(
    {"observer_abi", "step_index", "terminal", "token_id"}
)
LANE_END_PAYLOAD_FIELDS = frozenset(
    {
        "mode",
        "process_id",
        "model_instance_sha256",
        "lane_index",
        "binding_sha256",
        "published_count",
        "output_sha256",
        "kv_sha256",
        "generation_state_abi",
        "generation_rng_abi",
        "execution_abi",
        "thread_participants",
        "kv_positions",
        "sampling_calls",
        "rng_state",
        "complete",
    }
)
PHYSICAL_UNAVAILABLE_PAYLOAD_FIELDS = frozenset(
    {
        "status",
        "physical_metrics_claimed",
        "external_sampler_required",
        "symmetric_arms_required",
    }
)

U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1
MAX_EVENT_LINE_BYTES = 1 << 20

_U32_HEX_RE = re.compile(r"[0-9a-f]{8}")
_U64_HEX_RE = re.compile(r"[0-9a-f]{16}")
_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_KIND_RE = re.compile(r"[a-z][a-z0-9_-]{0,63}")


class EventEvidenceError(RuntimeError):
    """An event stream is malformed, noncanonical, or fails its commitment."""


@dataclass(frozen=True)
class EventRecord:
    """One decoded canonical event and its chain links."""

    core: dict[str, Any]
    previous_sha256: str
    event_sha256: str


@dataclass(frozen=True)
class SegmentCommitment:
    """Expected identity and terminal commitment for one event segment."""

    campaign_id: str
    observation_id: str
    segment: str
    event_count: int
    segment_root_sha256: str
    segment_tip_sha256: str


@dataclass(frozen=True)
class EncodedSegment:
    """Canonical JSONL bytes plus the commitment needed to detect truncation."""

    data: bytes
    commitment: SegmentCommitment


@dataclass(frozen=True)
class LaneExpectation:
    """Trusted binding for one lane in the fixed campaign workload."""

    lane_index: int
    binding_sha256: str
    prompt_sha256: str
    seed: int
    prompt_token_count: int


@dataclass(frozen=True)
class ObservationExpectation:
    """Out-of-band identity that one observation is required to match.

    Requiring this value prevents a fully valid, hash-consistent observation
    from another campaign, process, model instance, binary, model, workload,
    or option set from being accepted merely because it is internally
    self-consistent.
    """

    campaign_id: str
    observation_id: str
    mode: str
    process_id: int
    model_instance_sha256: str
    binary_sha256: str
    model_sha256: str
    workload_sha256: str
    options_sha256: str
    monotonic_clock_abi: int
    monotonic_clock_source: str
    lanes: tuple[LaneExpectation, ...]


@dataclass(frozen=True)
class ObservationContract:
    """Validated fixed-four-lane contract decoded from the coordinator."""

    campaign_id: str
    observation_id: str
    mode: str
    process_id: int
    coordinator_thread_id: int
    model_instance_sha256: str
    binary_sha256: str
    model_sha256: str
    workload_sha256: str
    options_sha256: str
    monotonic_clock_abi: int
    monotonic_clock_source: str
    physical_metrics_claimed: bool


@dataclass(frozen=True)
class ValidatedLaneEvidence:
    """Semantic result for one lane after all 64 publications are checked."""

    lane_index: int
    thread_id: int
    binding_sha256: str
    prompt_sha256: str
    seed: int
    begin_ns: int
    first_publish_ns: int
    last_publish_ns: int
    end_ns: int
    token_ids: tuple[int, ...]
    output_sha256: str
    kv_sha256: str
    kv_positions: int
    sampling_calls: int
    rng_state: tuple[int, int, int, int]


@dataclass(frozen=True)
class ValidatedObservationEvidence:
    """A hash-valid and semantically valid raw-event-v3 observation."""

    contract: ObservationContract
    lanes: tuple[ValidatedLaneEvidence, ...]
    records_by_segment: tuple[tuple[EventRecord, ...], ...]
    observation_root_sha256: str
    observation_begin_ns: int
    observation_end_ns: int
    physical_metrics_available: bool
    logical_observation_available: bool
    campaign_publication_available: bool
    campaign_publication_unavailable_reason: str
    physical_performance_publication_available: bool


def _exact_keys(value: Mapping[str, Any], expected: Iterable[str], where: str) -> None:
    expected_set = set(expected)
    actual_set = set(value)
    missing = sorted(expected_set - actual_set)
    unknown = sorted(actual_set - expected_set)
    if not missing and not unknown:
        return
    details: list[str] = []
    if missing:
        details.append("missing " + ", ".join(missing))
    if unknown:
        details.append("unknown " + ", ".join(unknown))
    raise EventEvidenceError(f"{where} fields are not exact: {'; '.join(details)}")


def _mapping(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise EventEvidenceError(f"{where} must be an object with string keys")
    return value


def _printable_ascii(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise EventEvidenceError(f"{where} must be a non-empty string")
    if any(ord(character) < 0x20 or ord(character) > 0x7E for character in value):
        raise EventEvidenceError(f"{where} must contain printable ASCII only")
    return value


def u32_hex(value: int) -> str:
    """Encode one unsigned 32-bit value as exactly eight lowercase hex digits."""

    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not 0 <= value <= U32_MAX
    ):
        raise EventEvidenceError("u32 value is outside [0, 2^32 - 1]")
    return f"{value:08x}"


def u64_hex(value: int) -> str:
    """Encode one unsigned 64-bit value as exactly sixteen lowercase hex digits."""

    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not 0 <= value <= U64_MAX
    ):
        raise EventEvidenceError("u64 value is outside [0, 2^64 - 1]")
    return f"{value:016x}"


def derive_output_token_sha256(token_ids: Sequence[int]) -> str:
    """Match ``generate.tokenSequenceSha256`` for a logical token journal."""

    digest = hashlib.sha256()
    digest.update(OUTPUT_TOKEN_HASH_DOMAIN)
    digest.update(len(token_ids).to_bytes(8, "little"))
    for index, token in enumerate(token_ids):
        if (
            isinstance(token, bool)
            or not isinstance(token, int)
            or not 0 <= token <= U32_MAX
        ):
            raise EventEvidenceError(f"token_ids[{index}] must be a u32")
        digest.update(token.to_bytes(4, "little"))
    return digest.hexdigest()


def derive_prompt_sha256(token_ids: Sequence[int]) -> str:
    """Commit one non-empty prompt token sequence using a pinned byte layout.

    The preimage is ``PROMPT_HASH_DOMAIN || count:u64-le || tokens:u32-le[]``.
    A domain or integer-endianness change therefore requires an explicit ABI
    version bump instead of silently changing trusted workload identities.
    """

    if not isinstance(token_ids, Sequence) or isinstance(
        token_ids, (str, bytes, bytearray)
    ):
        raise EventEvidenceError("prompt token_ids must be a sequence of u32 values")
    if not 0 < len(token_ids) <= U64_MAX:
        raise EventEvidenceError(
            "prompt token_ids must be a non-empty u64-length sequence"
        )
    digest = hashlib.sha256()
    digest.update(PROMPT_HASH_DOMAIN)
    digest.update(len(token_ids).to_bytes(8, "little"))
    for index, token in enumerate(token_ids):
        if (
            isinstance(token, bool)
            or not isinstance(token, int)
            or not 0 <= token <= U32_MAX
        ):
            raise EventEvidenceError(f"prompt token_ids[{index}] must be a u32")
        digest.update(token.to_bytes(4, "little"))
    return digest.hexdigest()


def derive_lane_binding_sha256(
    lane_index: int,
    prompt_sha256: str,
    prompt_token_count: int,
    seed: int,
) -> str:
    """Bind one lane to its prompt and deterministic generation contract.

    The versioned preimage pins the observation/decode/state/RNG ABIs, lane,
    prompt length and digest, seed, fixed output length, EOS-disabled flag,
    and greedy-sampling flag.  Mode is deliberately excluded: M1x4 and B4
    must consume the same trusted lane binding for a symmetric comparison.
    All integers are little-endian.
    """

    if (
        isinstance(lane_index, bool)
        or not isinstance(lane_index, int)
        or not 0 <= lane_index < LANE_COUNT
    ):
        raise EventEvidenceError(
            "lane binding lane_index must identify one of four lanes"
        )
    prompt = require_sha256(prompt_sha256, "lane binding prompt_sha256")
    if prompt == "0" * 64:
        raise EventEvidenceError("lane binding prompt_sha256 must be nonzero")
    if (
        isinstance(prompt_token_count, bool)
        or not isinstance(prompt_token_count, int)
        or not 0 < prompt_token_count <= U64_MAX - (TOKENS_PER_LANE - 1)
    ):
        raise EventEvidenceError(
            "lane binding prompt_token_count must be a nonzero u64"
        )
    if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= U64_MAX:
        raise EventEvidenceError("lane binding seed must be a u64")

    digest = hashlib.sha256()
    digest.update(LANE_BINDING_HASH_DOMAIN)
    for abi in (
        OBSERVATION_ABI,
        DECODE_LANE4_ABI,
        GENERATION_STATE_ABI,
        GENERATION_RNG_ABI,
    ):
        digest.update(abi.to_bytes(8, "little"))
    digest.update(lane_index.to_bytes(4, "little"))
    digest.update(prompt_token_count.to_bytes(8, "little"))
    digest.update(bytes.fromhex(prompt))
    digest.update(seed.to_bytes(8, "little"))
    digest.update(TOKENS_PER_LANE.to_bytes(4, "little"))
    digest.update(b"\x01\x01")  # eos_disabled=true, greedy_sampling=true
    return digest.hexdigest()


def derive_xoshiro256_initial_state(seed: int) -> tuple[int, int, int, int]:
    """Match Zig ``DefaultPrng.init(seed).s`` for this greedy-only profile."""

    if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= U64_MAX:
        raise EventEvidenceError("Xoshiro256 seed must be a u64")
    mask = U64_MAX
    splitmix_state = seed
    words: list[int] = []
    for _ in range(4):
        splitmix_state = (splitmix_state + 0x9E37_79B9_7F4A_7C15) & mask
        value = splitmix_state
        value = ((value ^ (value >> 30)) * 0xBF58_476D_1CE4_E5B9) & mask
        value = ((value ^ (value >> 27)) * 0x94D0_49BB_1331_11EB) & mask
        words.append(value ^ (value >> 31))
    return (words[0], words[1], words[2], words[3])


def require_u32_hex(value: Any, where: str) -> int:
    text = _printable_ascii(value, where)
    if _U32_HEX_RE.fullmatch(text) is None:
        raise EventEvidenceError(
            f"{where} must be exactly eight lowercase hexadecimal digits"
        )
    return int(text, 16)


def require_u64_hex(value: Any, where: str) -> int:
    text = _printable_ascii(value, where)
    if _U64_HEX_RE.fullmatch(text) is None:
        raise EventEvidenceError(
            f"{where} must be exactly sixteen lowercase hexadecimal digits"
        )
    return int(text, 16)


def require_sha256(value: Any, where: str) -> str:
    text = _printable_ascii(value, where)
    if _SHA256_RE.fullmatch(text) is None:
        raise EventEvidenceError(
            f"{where} must be exactly 64 lowercase hexadecimal digits"
        )
    return text


def _validate_canonical_value(value: Any, where: str) -> None:
    if isinstance(value, bool):
        return
    if isinstance(value, str):
        _printable_ascii(value, where)
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_canonical_value(item, f"{where}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            _printable_ascii(key, f"{where} key")
            _validate_canonical_value(item, f"{where}.{key}")
        return
    raise EventEvidenceError(
        f"{where} must use only objects, arrays, printable ASCII strings, "
        "or booleans; JSON numbers and null are forbidden"
    )


def canonical_ascii_json(value: Any) -> bytes:
    """Return the sole accepted JSON encoding for an event value.

    Integer-like payload fields must be passed as fixed-width strings produced
    by :func:`u32_hex` or :func:`u64_hex`.  Event-specific validators are
    responsible for assigning the correct width to each payload field.
    """

    _validate_canonical_value(value, "value")
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError) as exc:
        raise EventEvidenceError(f"value cannot be encoded canonically: {exc}") from exc
    return encoded


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EventEvidenceError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_json_number(value: str) -> None:
    raise EventEvidenceError(f"JSON number {value!r} is forbidden")


def _load_json_line(line: bytes) -> dict[str, Any]:
    if not isinstance(line, bytes):
        raise EventEvidenceError("event line must be bytes")
    if not line:
        raise EventEvidenceError("event line is empty")
    if len(line) > MAX_EVENT_LINE_BYTES:
        raise EventEvidenceError("event line exceeds the one-mebibyte limit")
    if not line.endswith(b"\n"):
        raise EventEvidenceError("event line is truncated or lacks its final newline")
    if line.count(b"\n") != 1:
        raise EventEvidenceError("event input must contain exactly one JSONL record")
    try:
        text = line[:-1].decode("ascii")
    except UnicodeDecodeError as exc:
        raise EventEvidenceError("event line must be ASCII") from exc
    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_int=_reject_json_number,
            parse_float=_reject_json_number,
            parse_constant=_reject_json_number,
        )
    except EventEvidenceError:
        raise
    except json.JSONDecodeError as exc:
        raise EventEvidenceError(f"event line is invalid JSON: {exc}") from exc
    return _mapping(value, "event wrapper")


def _validate_core(value: Any) -> dict[str, Any]:
    core = _mapping(value, "event core")
    _exact_keys(core, CORE_FIELDS, "event core")
    if core["schema"] != EVENT_SCHEMA:
        raise EventEvidenceError(f"event core.schema must be {EVENT_SCHEMA!r}")
    require_sha256(core["campaign_id"], "event core.campaign_id")
    require_sha256(core["observation_id"], "event core.observation_id")
    segment = _printable_ascii(core["segment"], "event core.segment")
    if segment not in SEGMENT_ORDER:
        raise EventEvidenceError(f"event core.segment {segment!r} is unsupported")
    require_u64_hex(core["local_sequence"], "event core.local_sequence")
    require_u64_hex(core["monotonic_ns"], "event core.monotonic_ns")
    require_u64_hex(core["thread_id"], "event core.thread_id")
    kind = _printable_ascii(core["kind"], "event core.kind")
    if _KIND_RE.fullmatch(kind) is None:
        raise EventEvidenceError("event core.kind is not a canonical event identifier")
    _mapping(core["payload"], "event core.payload")
    _validate_canonical_value(core["payload"], "event core.payload")
    return core


def make_event_core(
    *,
    campaign_id: str,
    observation_id: str,
    segment: str,
    local_sequence: int,
    monotonic_ns: int,
    thread_id: int,
    kind: str,
    payload: Mapping[str, Any],
) -> dict[str, Any]:
    """Construct and validate one event core using fixed-width encodings."""

    core: dict[str, Any] = {
        "schema": EVENT_SCHEMA,
        "campaign_id": campaign_id,
        "observation_id": observation_id,
        "segment": segment,
        "local_sequence": u64_hex(local_sequence),
        "monotonic_ns": u64_hex(monotonic_ns),
        "thread_id": u64_hex(thread_id),
        "kind": kind,
        "payload": dict(payload),
    }
    return _validate_core(core)


def derive_segment_root(campaign_id: str, observation_id: str, segment: str) -> str:
    """Derive the non-secret root for one campaign/observation segment."""

    campaign = bytes.fromhex(require_sha256(campaign_id, "campaign_id"))
    observation = bytes.fromhex(require_sha256(observation_id, "observation_id"))
    segment_text = _printable_ascii(segment, "segment")
    if segment_text not in SEGMENT_ORDER:
        raise EventEvidenceError(f"segment {segment_text!r} is unsupported")
    segment_bytes = segment_text.encode("ascii")
    digest = hashlib.sha256()
    digest.update(SEGMENT_ROOT_DOMAIN)
    digest.update(campaign)
    digest.update(observation)
    digest.update(len(segment_bytes).to_bytes(2, "little"))
    digest.update(segment_bytes)
    return digest.hexdigest()


def derive_event_sha256(previous_sha256: str, core: Mapping[str, Any]) -> str:
    """Commit one canonical event core to its previous segment link."""

    previous = bytes.fromhex(require_sha256(previous_sha256, "previous_sha256"))
    validated = _validate_core(dict(core))
    core_bytes = canonical_ascii_json(validated)
    local_sequence = require_u64_hex(
        validated["local_sequence"], "event core.local_sequence"
    )
    digest = hashlib.sha256()
    digest.update(EVENT_DOMAIN)
    digest.update(previous)
    digest.update(local_sequence.to_bytes(8, "little"))
    digest.update(len(core_bytes).to_bytes(8, "little"))
    digest.update(core_bytes)
    return digest.hexdigest()


def encode_event(core: Mapping[str, Any], previous_sha256: str) -> bytes:
    """Encode one canonical wrapper and calculate its event hash."""

    validated = _validate_core(dict(core))
    previous = require_sha256(previous_sha256, "previous_sha256")
    wrapper = {
        "core": validated,
        "previous_sha256": previous,
        "event_sha256": derive_event_sha256(previous, validated),
    }
    return canonical_ascii_json(wrapper) + b"\n"


def decode_event_line(line: bytes) -> EventRecord:
    """Decode one line, require canonical bytes, and verify its event hash."""

    wrapper = _load_json_line(line)
    _exact_keys(wrapper, WRAPPER_FIELDS, "event wrapper")
    core = _validate_core(wrapper["core"])
    previous = require_sha256(
        wrapper["previous_sha256"], "event wrapper.previous_sha256"
    )
    event_sha = require_sha256(wrapper["event_sha256"], "event wrapper.event_sha256")
    canonical = canonical_ascii_json(wrapper) + b"\n"
    if line != canonical:
        raise EventEvidenceError("event line is valid JSON but not canonical JSONL")
    expected_event_sha = derive_event_sha256(previous, core)
    if event_sha != expected_event_sha:
        raise EventEvidenceError("event wrapper.event_sha256 is inconsistent")
    return EventRecord(
        core=core,
        previous_sha256=previous,
        event_sha256=event_sha,
    )


class SegmentBuilder:
    """Small in-memory reference emitter for tests and cross-language vectors.

    A production runner should use preallocated single-writer lane segments;
    this class defines their bytes but is not a benchmark collection loop.
    """

    def __init__(self, campaign_id: str, observation_id: str, segment: str):
        self._campaign_id = require_sha256(campaign_id, "campaign_id")
        self._observation_id = require_sha256(observation_id, "observation_id")
        self._segment = _printable_ascii(segment, "segment")
        self._root = derive_segment_root(campaign_id, observation_id, segment)
        self._previous = self._root
        self._last_monotonic_ns: int | None = None
        self._lines: list[bytes] = []

    def append(
        self,
        *,
        monotonic_ns: int,
        thread_id: int,
        kind: str,
        payload: Mapping[str, Any],
    ) -> EventRecord:
        if (
            self._last_monotonic_ns is not None
            and monotonic_ns < self._last_monotonic_ns
        ):
            raise EventEvidenceError("segment monotonic timestamp moved backwards")
        core = make_event_core(
            campaign_id=self._campaign_id,
            observation_id=self._observation_id,
            segment=self._segment,
            local_sequence=len(self._lines),
            monotonic_ns=monotonic_ns,
            thread_id=thread_id,
            kind=kind,
            payload=payload,
        )
        line = encode_event(core, self._previous)
        record = decode_event_line(line)
        self._lines.append(line)
        self._previous = record.event_sha256
        self._last_monotonic_ns = monotonic_ns
        return record

    def finish(self) -> EncodedSegment:
        commitment = SegmentCommitment(
            campaign_id=self._campaign_id,
            observation_id=self._observation_id,
            segment=self._segment,
            event_count=len(self._lines),
            segment_root_sha256=self._root,
            segment_tip_sha256=self._previous,
        )
        return EncodedSegment(data=b"".join(self._lines), commitment=commitment)


def _split_jsonl(data: bytes) -> list[bytes]:
    if not isinstance(data, bytes):
        raise EventEvidenceError("segment data must be bytes")
    if not data:
        return []
    if not data.endswith(b"\n"):
        raise EventEvidenceError("segment is truncated or lacks its final newline")
    return data.splitlines(keepends=True)


def _validate_commitment(commitment: SegmentCommitment) -> None:
    require_sha256(commitment.campaign_id, "commitment.campaign_id")
    require_sha256(commitment.observation_id, "commitment.observation_id")
    if commitment.segment not in SEGMENT_ORDER:
        raise EventEvidenceError("commitment.segment is unsupported")
    if (
        isinstance(commitment.event_count, bool)
        or not isinstance(commitment.event_count, int)
        or not 0 <= commitment.event_count <= U64_MAX
    ):
        raise EventEvidenceError("commitment.event_count must be a u64")
    root = require_sha256(
        commitment.segment_root_sha256,
        "commitment.segment_root_sha256",
    )
    expected_root = derive_segment_root(
        commitment.campaign_id,
        commitment.observation_id,
        commitment.segment,
    )
    if root != expected_root:
        raise EventEvidenceError("commitment.segment_root_sha256 is inconsistent")
    require_sha256(
        commitment.segment_tip_sha256,
        "commitment.segment_tip_sha256",
    )
    if commitment.event_count == 0 and commitment.segment_tip_sha256 != root:
        raise EventEvidenceError("an empty segment tip must equal its segment root")


def verify_segment(
    data: bytes, commitment: SegmentCommitment
) -> tuple[EventRecord, ...]:
    """Verify canonical records, identity, ordering, chain, count, and tip."""

    _validate_commitment(commitment)
    lines = _split_jsonl(data)
    if len(lines) != commitment.event_count:
        raise EventEvidenceError(
            "segment event count differs from its committed event_count"
        )
    expected_previous = commitment.segment_root_sha256
    last_monotonic_ns: int | None = None
    records: list[EventRecord] = []
    for index, line in enumerate(lines):
        record = decode_event_line(line)
        core = record.core
        if core["campaign_id"] != commitment.campaign_id:
            raise EventEvidenceError("event was replayed from another campaign")
        if core["observation_id"] != commitment.observation_id:
            raise EventEvidenceError("event was replayed from another observation")
        if core["segment"] != commitment.segment:
            raise EventEvidenceError("event was replayed from another segment")
        sequence = require_u64_hex(core["local_sequence"], "event core.local_sequence")
        if sequence != index:
            raise EventEvidenceError("segment local_sequence is not contiguous")
        if record.previous_sha256 != expected_previous:
            raise EventEvidenceError("segment previous_sha256 chain is broken")
        monotonic_ns = require_u64_hex(core["monotonic_ns"], "event core.monotonic_ns")
        if last_monotonic_ns is not None and monotonic_ns < last_monotonic_ns:
            raise EventEvidenceError("segment monotonic timestamp moved backwards")
        expected_previous = record.event_sha256
        last_monotonic_ns = monotonic_ns
        records.append(record)
    if expected_previous != commitment.segment_tip_sha256:
        raise EventEvidenceError("segment terminal hash differs from its committed tip")
    return tuple(records)


def derive_observation_root(
    campaign_id: str,
    observation_id: str,
    commitments: Sequence[SegmentCommitment],
) -> str:
    """Commit all six segment identities in the one permitted segment order."""

    campaign = bytes.fromhex(require_sha256(campaign_id, "campaign_id"))
    observation = bytes.fromhex(require_sha256(observation_id, "observation_id"))
    if len(commitments) != len(SEGMENT_ORDER):
        raise EventEvidenceError("observation requires exactly six segment commitments")
    if tuple(item.segment for item in commitments) != SEGMENT_ORDER:
        raise EventEvidenceError(
            "observation segment commitments are not in fixed order"
        )

    digest = hashlib.sha256()
    digest.update(OBSERVATION_ROOT_DOMAIN)
    digest.update(campaign)
    digest.update(observation)
    for expected_segment, commitment in zip(SEGMENT_ORDER, commitments):
        _validate_commitment(commitment)
        if commitment.campaign_id != campaign_id:
            raise EventEvidenceError("segment commitment belongs to another campaign")
        if commitment.observation_id != observation_id:
            raise EventEvidenceError(
                "segment commitment belongs to another observation"
            )
        if commitment.segment != expected_segment:
            raise EventEvidenceError("segment commitment order changed")
        segment_bytes = expected_segment.encode("ascii")
        digest.update(len(segment_bytes).to_bytes(2, "little"))
        digest.update(segment_bytes)
        digest.update(commitment.event_count.to_bytes(8, "little"))
        digest.update(bytes.fromhex(commitment.segment_root_sha256))
        digest.update(bytes.fromhex(commitment.segment_tip_sha256))
    return digest.hexdigest()


def verify_observation_root(
    campaign_id: str,
    observation_id: str,
    commitments: Sequence[SegmentCommitment],
    expected_root_sha256: str,
) -> str:
    """Derive and compare one fixed-order observation-root commitment."""

    expected = require_sha256(expected_root_sha256, "expected observation root")
    actual = derive_observation_root(campaign_id, observation_id, commitments)
    if actual != expected:
        raise EventEvidenceError("observation root commitment is inconsistent")
    return actual


def _require_nonzero_sha256(value: Any, where: str) -> str:
    digest = require_sha256(value, where)
    if digest == "0" * 64:
        raise EventEvidenceError(f"{where} must not be the all-zero digest")
    return digest


def _require_bool(value: Any, where: str) -> bool:
    if not isinstance(value, bool):
        raise EventEvidenceError(f"{where} must be a boolean")
    return value


def _require_mode(value: Any, where: str) -> str:
    mode = _printable_ascii(value, where)
    if mode not in MODES:
        raise EventEvidenceError(f"{where} must be 'm1x4' or 'b4'")
    return mode


def _payload(
    record: EventRecord,
    expected_fields: Iterable[str],
    where: str,
) -> dict[str, Any]:
    payload = _mapping(record.core["payload"], f"{where} payload")
    _exact_keys(payload, expected_fields, f"{where} payload")
    return payload


def _timestamp(record: EventRecord) -> int:
    return require_u64_hex(record.core["monotonic_ns"], "event core.monotonic_ns")


def _thread_id(record: EventRecord) -> int:
    return require_u64_hex(record.core["thread_id"], "event core.thread_id")


def _require_kind(record: EventRecord, kind: str, where: str) -> None:
    if record.core["kind"] != kind:
        raise EventEvidenceError(
            f"{where} kind must be {kind!r}, got {record.core['kind']!r}"
        )


def _require_identity_payload(
    payload: Mapping[str, Any],
    contract: ObservationContract,
    where: str,
) -> None:
    process_id = require_u64_hex(payload["process_id"], f"{where}.process_id")
    model_instance = _require_nonzero_sha256(
        payload["model_instance_sha256"],
        f"{where}.model_instance_sha256",
    )
    if process_id != contract.process_id:
        raise EventEvidenceError(f"{where} substituted another process")
    if model_instance != contract.model_instance_sha256:
        raise EventEvidenceError(f"{where} substituted another model instance")


def _validate_expectation(expectation: ObservationExpectation) -> None:
    if not isinstance(expectation, ObservationExpectation):
        raise EventEvidenceError("expectation must be an ObservationExpectation")
    _require_nonzero_sha256(expectation.campaign_id, "expectation.campaign_id")
    _require_nonzero_sha256(
        expectation.observation_id,
        "expectation.observation_id",
    )
    _require_mode(expectation.mode, "expectation.mode")
    if (
        isinstance(expectation.process_id, bool)
        or not isinstance(expectation.process_id, int)
        or not 0 < expectation.process_id <= U64_MAX
    ):
        raise EventEvidenceError("expectation.process_id must be a nonzero u64")
    _require_nonzero_sha256(
        expectation.model_instance_sha256,
        "expectation.model_instance_sha256",
    )
    _require_nonzero_sha256(expectation.binary_sha256, "expectation.binary_sha256")
    _require_nonzero_sha256(expectation.model_sha256, "expectation.model_sha256")
    _require_nonzero_sha256(
        expectation.workload_sha256,
        "expectation.workload_sha256",
    )
    _require_nonzero_sha256(expectation.options_sha256, "expectation.options_sha256")
    if (
        isinstance(expectation.monotonic_clock_abi, bool)
        or not isinstance(expectation.monotonic_clock_abi, int)
        or expectation.monotonic_clock_abi != MONOTONIC_CLOCK_ABI
    ):
        raise EventEvidenceError(
            "expectation.monotonic_clock_abi is not the production clock ABI"
        )
    if expectation.monotonic_clock_source != PRODUCTION_CLOCK_SOURCE:
        raise EventEvidenceError(
            "expectation.monotonic_clock_source is not the production OS "
            "boot-monotonic source"
        )
    if not isinstance(expectation.lanes, tuple) or len(expectation.lanes) != LANE_COUNT:
        raise EventEvidenceError("expectation.lanes must be an exact four-item tuple")
    binding_digests: set[str] = set()
    prompt_counts: set[int] = set()
    for lane, lane_expectation in enumerate(expectation.lanes):
        where = f"expectation.lanes[{lane}]"
        if not isinstance(lane_expectation, LaneExpectation):
            raise EventEvidenceError(f"{where} must be a LaneExpectation")
        if lane_expectation.lane_index != lane:
            raise EventEvidenceError(f"{where}.lane_index is not contiguous")
        binding = _require_nonzero_sha256(
            lane_expectation.binding_sha256,
            f"{where}.binding_sha256",
        )
        prompt = _require_nonzero_sha256(
            lane_expectation.prompt_sha256,
            f"{where}.prompt_sha256",
        )
        if (
            isinstance(lane_expectation.seed, bool)
            or not isinstance(lane_expectation.seed, int)
            or not 0 <= lane_expectation.seed <= U64_MAX
        ):
            raise EventEvidenceError(f"{where}.seed must be a u64")
        if (
            isinstance(lane_expectation.prompt_token_count, bool)
            or not isinstance(lane_expectation.prompt_token_count, int)
            or not 0
            < lane_expectation.prompt_token_count
            <= U64_MAX - (TOKENS_PER_LANE - 1)
        ):
            raise EventEvidenceError(
                f"{where}.prompt_token_count must be a nonzero u64"
            )
        canonical_binding = derive_lane_binding_sha256(
            lane,
            prompt,
            lane_expectation.prompt_token_count,
            lane_expectation.seed,
        )
        if binding != canonical_binding:
            raise EventEvidenceError(
                f"{where}.binding_sha256 is not the canonical trusted workload binding"
            )
        if binding in binding_digests:
            raise EventEvidenceError("expectation lane bindings must be distinct")
        binding_digests.add(binding)
        prompt_counts.add(lane_expectation.prompt_token_count)
    if len(prompt_counts) != 1:
        raise EventEvidenceError("all four expected prompts must have equal length")


def _parse_contract(
    record: EventRecord,
    expectation: ObservationExpectation,
) -> ObservationContract:
    _require_kind(record, "observation_contract", "coordinator event 0")
    payload = _payload(
        record,
        CONTRACT_PAYLOAD_FIELDS,
        "observation_contract",
    )
    if payload["raw_schema"] != RAW_EVENT_SCHEMA:
        raise EventEvidenceError(
            f"observation_contract.raw_schema must be {RAW_EVENT_SCHEMA!r}"
        )

    exact_u64 = {
        "observation_abi": OBSERVATION_ABI,
        "decode_lane4_abi": DECODE_LANE4_ABI,
        "m1_execution_abi": M1_EXECUTION_ABI,
        "token_publication_abi": TOKEN_PUBLICATION_ABI,
        "resource_bank_abi": RESOURCE_BANK_ABI,
        "resource_commit_observer_abi": RESOURCE_COMMIT_OBSERVER_ABI,
        "m1_barrier_abi": M1_BARRIER_ABI,
        "b4_post_commit_abi": B4_POST_COMMIT_ABI,
        "generation_state_abi": GENERATION_STATE_ABI,
        "generation_rng_abi": GENERATION_RNG_ABI,
        "monotonic_clock_abi": MONOTONIC_CLOCK_ABI,
    }
    for field, expected in exact_u64.items():
        actual = require_u64_hex(payload[field], f"observation_contract.{field}")
        if actual != expected:
            raise EventEvidenceError(
                f"observation_contract.{field} is not the admitted ABI"
            )

    mode = _require_mode(payload["mode"], "observation_contract.mode")
    process_id = require_u64_hex(
        payload["process_id"],
        "observation_contract.process_id",
    )
    coordinator_thread_id = require_u64_hex(
        payload["coordinator_thread_id"],
        "observation_contract.coordinator_thread_id",
    )
    if process_id == 0 or coordinator_thread_id == 0:
        raise EventEvidenceError(
            "observation process and coordinator thread IDs must be nonzero"
        )
    digests = {
        field: _require_nonzero_sha256(
            payload[field],
            f"observation_contract.{field}",
        )
        for field in (
            "model_instance_sha256",
            "binary_sha256",
            "model_sha256",
            "workload_sha256",
            "options_sha256",
        )
    }
    exact_u32 = {
        "lane_count": LANE_COUNT,
        "worker_count": WORKER_COUNT,
        "tokens_per_lane": TOKENS_PER_LANE,
    }
    for field, expected in exact_u32.items():
        actual = require_u32_hex(payload[field], f"observation_contract.{field}")
        if actual != expected:
            raise EventEvidenceError(
                f"observation_contract.{field} must equal {expected}"
            )
    if not _require_bool(payload["eos_disabled"], "observation_contract.eos_disabled"):
        raise EventEvidenceError("raw-event-v3 requires EOS-disabled observations")
    if not _require_bool(
        payload["greedy_sampling"],
        "observation_contract.greedy_sampling",
    ):
        raise EventEvidenceError("raw-event-v3 requires deterministic greedy sampling")
    clock_source = _printable_ascii(
        payload["monotonic_clock_source"],
        "observation_contract.monotonic_clock_source",
    )
    if clock_source != PRODUCTION_CLOCK_SOURCE:
        raise EventEvidenceError(
            "observation_contract.monotonic_clock_source is not the production "
            "OS boot-monotonic source"
        )
    if (
        expectation.monotonic_clock_abi != MONOTONIC_CLOCK_ABI
        or expectation.monotonic_clock_source != clock_source
    ):
        raise EventEvidenceError(
            "observation clock differs from its trusted clock expectation"
        )
    physical_claimed = _require_bool(
        payload["physical_metrics_claimed"],
        "observation_contract.physical_metrics_claimed",
    )
    if physical_claimed:
        raise EventEvidenceError(
            "physical-performance publication is unavailable until an external "
            "symmetric sampler ABI is defined"
        )

    if mode != expectation.mode:
        raise EventEvidenceError("observation mode differs from its expectation")
    if process_id != expectation.process_id:
        raise EventEvidenceError("observation substituted another process")
    for field in (
        "model_instance_sha256",
        "binary_sha256",
        "model_sha256",
        "workload_sha256",
        "options_sha256",
    ):
        if digests[field] != getattr(expectation, field):
            raise EventEvidenceError(
                f"observation_contract.{field} differs from its expectation"
            )

    if _thread_id(record) != coordinator_thread_id:
        raise EventEvidenceError(
            "observation_contract was emitted by a substituted coordinator thread"
        )
    return ObservationContract(
        campaign_id=expectation.campaign_id,
        observation_id=expectation.observation_id,
        mode=mode,
        process_id=process_id,
        coordinator_thread_id=coordinator_thread_id,
        model_instance_sha256=digests["model_instance_sha256"],
        binary_sha256=digests["binary_sha256"],
        model_sha256=digests["model_sha256"],
        workload_sha256=digests["workload_sha256"],
        options_sha256=digests["options_sha256"],
        monotonic_clock_abi=MONOTONIC_CLOCK_ABI,
        monotonic_clock_source=clock_source,
        physical_metrics_claimed=physical_claimed,
    )


def _parse_lane(
    lane_index: int,
    records: tuple[EventRecord, ...],
    contract: ObservationContract,
    expectation: LaneExpectation,
) -> ValidatedLaneEvidence:
    where = f"lane-{lane_index}"
    expected_count = TOKENS_PER_LANE + 2
    if len(records) != expected_count:
        raise EventEvidenceError(
            f"{where} requires lane_begin, exactly {TOKENS_PER_LANE} "
            "token_published events, and lane_end"
        )
    _require_kind(records[0], "lane_begin", f"{where} event 0")
    _require_kind(records[-1], "lane_end", f"{where} terminal event")
    begin = _payload(records[0], LANE_BEGIN_PAYLOAD_FIELDS, f"{where} lane_begin")
    end = _payload(records[-1], LANE_END_PAYLOAD_FIELDS, f"{where} lane_end")
    _require_identity_payload(begin, contract, f"{where} lane_begin")
    _require_identity_payload(end, contract, f"{where} lane_end")
    if begin["mode"] != contract.mode or end["mode"] != contract.mode:
        raise EventEvidenceError(f"{where} substituted another execution mode")
    begin_lane = require_u32_hex(begin["lane_index"], f"{where}.lane_index")
    end_lane = require_u32_hex(end["lane_index"], f"{where}.lane_end.lane_index")
    if begin_lane != lane_index or end_lane != lane_index:
        raise EventEvidenceError(f"{where} contains cross-lane evidence")

    binding = _require_nonzero_sha256(
        begin["binding_sha256"],
        f"{where}.binding_sha256",
    )
    prompt = _require_nonzero_sha256(
        begin["prompt_sha256"],
        f"{where}.prompt_sha256",
    )
    if (
        _require_nonzero_sha256(
            end["binding_sha256"],
            f"{where}.lane_end.binding_sha256",
        )
        != binding
    ):
        raise EventEvidenceError(f"{where} lane binding changed before lane_end")
    seed = require_u64_hex(begin["seed"], f"{where}.seed")
    if (
        expectation.lane_index != lane_index
        or binding != expectation.binding_sha256
        or prompt != expectation.prompt_sha256
        or seed != expectation.seed
    ):
        raise EventEvidenceError(f"{where} differs from its trusted workload binding")

    lane_thread = _thread_id(records[0])
    if lane_thread == 0 or lane_thread == contract.coordinator_thread_id:
        raise EventEvidenceError(
            f"{where} must use a nonzero inference thread distinct from coordinator"
        )
    for record in records[1:]:
        if _thread_id(record) != lane_thread:
            raise EventEvidenceError(f"{where} contains a thread substitution")

    token_ids: list[int] = []
    token_times: list[int] = []
    for step, record in enumerate(records[1:-1]):
        _require_kind(record, "token_published", f"{where} token event {step}")
        payload = _payload(
            record,
            TOKEN_PUBLISHED_PAYLOAD_FIELDS,
            f"{where} token event {step}",
        )
        observer_abi = require_u64_hex(
            payload["observer_abi"],
            f"{where} token event {step}.observer_abi",
        )
        if observer_abi != TOKEN_PUBLICATION_ABI:
            raise EventEvidenceError(f"{where} token observer ABI is unsupported")
        actual_step = require_u64_hex(
            payload["step_index"],
            f"{where} token event {step}.step_index",
        )
        if actual_step != step:
            raise EventEvidenceError(f"{where} token steps are not contiguous")
        terminal = _require_bool(
            payload["terminal"],
            f"{where} token event {step}.terminal",
        )
        if terminal != (step + 1 == TOKENS_PER_LANE):
            raise EventEvidenceError(
                f"{where} terminal marker must appear only on token 64"
            )
        token_ids.append(
            require_u32_hex(
                payload["token_id"],
                f"{where} token event {step}.token_id",
            )
        )
        token_times.append(_timestamp(record))

    published = require_u32_hex(
        end["published_count"],
        f"{where}.lane_end.published_count",
    )
    if published != TOKENS_PER_LANE:
        raise EventEvidenceError(f"{where} did not publish exactly 64 tokens")
    if not _require_bool(end["complete"], f"{where}.lane_end.complete"):
        raise EventEvidenceError(f"{where} is not complete")
    generation_abi = require_u64_hex(
        end["generation_state_abi"],
        f"{where}.lane_end.generation_state_abi",
    )
    if generation_abi != GENERATION_STATE_ABI:
        raise EventEvidenceError(f"{where} generation-state ABI is unsupported")
    generation_rng_abi = require_u64_hex(
        end["generation_rng_abi"],
        f"{where}.lane_end.generation_rng_abi",
    )
    if generation_rng_abi != GENERATION_RNG_ABI:
        raise EventEvidenceError(f"{where} generation RNG ABI is unsupported")
    expected_execution_abi = (
        M1_EXECUTION_ABI if contract.mode == "m1x4" else DECODE_LANE4_ABI
    )
    execution_abi = require_u64_hex(
        end["execution_abi"],
        f"{where}.lane_end.execution_abi",
    )
    if execution_abi != expected_execution_abi:
        raise EventEvidenceError(f"{where} execution ABI does not match its mode")
    expected_participants = 1 if contract.mode == "m1x4" else WORKER_COUNT
    participants = require_u32_hex(
        end["thread_participants"],
        f"{where}.lane_end.thread_participants",
    )
    if participants != expected_participants:
        raise EventEvidenceError(
            f"{where} thread participant count does not match its mode"
        )
    kv_positions = require_u64_hex(
        end["kv_positions"],
        f"{where}.lane_end.kv_positions",
    )
    expected_kv_positions = expectation.prompt_token_count + TOKENS_PER_LANE - 1
    if kv_positions != expected_kv_positions:
        raise EventEvidenceError(
            f"{where} KV position count does not match prompt plus decode"
        )
    sampling_calls = require_u64_hex(
        end["sampling_calls"],
        f"{where}.lane_end.sampling_calls",
    )
    if sampling_calls != TOKENS_PER_LANE:
        raise EventEvidenceError(f"{where} sampling call count must equal 64")
    raw_rng_state = end["rng_state"]
    if not isinstance(raw_rng_state, list) or len(raw_rng_state) != 4:
        raise EventEvidenceError(f"{where}.lane_end.rng_state must contain four words")
    rng_state = tuple(
        require_u64_hex(word, f"{where}.lane_end.rng_state[{index}]")
        for index, word in enumerate(raw_rng_state)
    )
    if rng_state == (0, 0, 0, 0):
        raise EventEvidenceError(f"{where} Xoshiro state must not be all zero")
    if rng_state != derive_xoshiro256_initial_state(seed):
        raise EventEvidenceError(
            f"{where} Xoshiro state does not match its greedy workload seed"
        )

    begin_ns = _timestamp(records[0])
    end_ns = _timestamp(records[-1])
    if not begin_ns <= token_times[0] <= token_times[-1] <= end_ns:
        raise EventEvidenceError(f"{where} publication interval is not causal")
    output_sha256 = _require_nonzero_sha256(
        end["output_sha256"],
        f"{where}.lane_end.output_sha256",
    )
    expected_output_sha256 = derive_output_token_sha256(token_ids)
    if output_sha256 != expected_output_sha256:
        raise EventEvidenceError(
            f"{where} output digest does not match its 64 published tokens"
        )
    return ValidatedLaneEvidence(
        lane_index=lane_index,
        thread_id=lane_thread,
        binding_sha256=binding,
        prompt_sha256=prompt,
        seed=seed,
        begin_ns=begin_ns,
        first_publish_ns=token_times[0],
        last_publish_ns=token_times[-1],
        end_ns=end_ns,
        token_ids=tuple(token_ids),
        output_sha256=output_sha256,
        kv_sha256=_require_nonzero_sha256(
            end["kv_sha256"],
            f"{where}.lane_end.kv_sha256",
        ),
        kv_positions=kv_positions,
        sampling_calls=sampling_calls,
        rng_state=rng_state,
    )


def _validate_sampler(
    records: tuple[EventRecord, ...], contract: ObservationContract
) -> None:
    if contract.physical_metrics_claimed:
        raise EventEvidenceError(
            "physical-performance publication is unavailable in this semantic ABI"
        )
    if len(records) != 1:
        raise EventEvidenceError(
            "sampler must contain exactly one physical_metrics_unavailable marker"
        )
    record = records[0]
    _require_kind(record, "physical_metrics_unavailable", "sampler event 0")
    payload = _payload(
        record,
        PHYSICAL_UNAVAILABLE_PAYLOAD_FIELDS,
        "physical_metrics_unavailable",
    )
    if _thread_id(record) != 0:
        raise EventEvidenceError(
            "an unavailable physical sampler must use the zero thread sentinel"
        )
    if payload["status"] != "unavailable":
        raise EventEvidenceError("physical sampler status must be 'unavailable'")
    if _require_bool(
        payload["physical_metrics_claimed"],
        "physical_metrics_unavailable.physical_metrics_claimed",
    ):
        raise EventEvidenceError("unavailable sampler cannot claim physical metrics")
    if not _require_bool(
        payload["external_sampler_required"],
        "physical_metrics_unavailable.external_sampler_required",
    ):
        raise EventEvidenceError("physical metrics require an external sampler")
    if not _require_bool(
        payload["symmetric_arms_required"],
        "physical_metrics_unavailable.symmetric_arms_required",
    ):
        raise EventEvidenceError("physical metrics require symmetric sampling")


def _validate_coordinator(
    records: tuple[EventRecord, ...],
    contract: ObservationContract,
    lanes: tuple[ValidatedLaneEvidence, ...],
) -> tuple[int, int]:
    mode = contract.mode
    expected_count = 9 if mode == "m1x4" else 5
    if len(records) != expected_count:
        raise EventEvidenceError(
            f"coordinator {mode} event sequence has an invalid event count"
        )
    _require_kind(records[0], "observation_contract", "coordinator event 0")
    _require_kind(records[1], "observation_begin", "coordinator event 1")
    commit_count = LANE_COUNT if mode == "m1x4" else 1
    commit_records = records[2 : 2 + commit_count]
    for index, record in enumerate(commit_records):
        _require_kind(record, "resource_committed", f"resource commit {index}")
    cursor = 2 + commit_count
    barrier_record: EventRecord | None = None
    if mode == "m1x4":
        barrier_record = records[cursor]
        _require_kind(barrier_record, "resource_barrier", "M1 resource barrier")
        cursor += 1
    release_record = records[cursor]
    end_record = records[cursor + 1]
    _require_kind(release_record, "resource_released", "resource release")
    _require_kind(end_record, "observation_end", "observation end")

    begin = _payload(
        records[1],
        OBSERVATION_BEGIN_PAYLOAD_FIELDS,
        "observation_begin",
    )
    _require_identity_payload(begin, contract, "observation_begin")
    if begin["mode"] != mode:
        raise EventEvidenceError("observation_begin mode changed")
    for record, label in (
        (records[0], "observation_contract"),
        (records[1], "observation_begin"),
        (release_record, "resource_released"),
        (end_record, "observation_end"),
    ):
        if _thread_id(record) != contract.coordinator_thread_id:
            raise EventEvidenceError(f"{label} contains a coordinator substitution")

    lane_threads = tuple(lane.thread_id for lane in lanes)
    receipt_digests: set[str] = set()
    committed_times: list[int] = []
    committed_lanes: set[int] = set()
    for index, record in enumerate(commit_records):
        fields = (
            M1_RESOURCE_COMMITTED_PAYLOAD_FIELDS
            if mode == "m1x4"
            else B4_RESOURCE_COMMITTED_PAYLOAD_FIELDS
        )
        payload = _payload(record, fields, f"resource commit {index}")
        _require_identity_payload(payload, contract, f"resource commit {index}")
        if (
            require_u64_hex(
                payload["resource_bank_abi"],
                f"resource commit {index}.resource_bank_abi",
            )
            != RESOURCE_BANK_ABI
        ):
            raise EventEvidenceError("resource commit uses another ResourceBank ABI")
        if (
            require_u64_hex(
                payload["resource_commit_observer_abi"],
                f"resource commit {index}.resource_commit_observer_abi",
            )
            != RESOURCE_COMMIT_OBSERVER_ABI
        ):
            raise EventEvidenceError("resource commit observer ABI is unsupported")
        _require_nonzero_sha256(
            payload["claim_sha256"],
            f"resource commit {index}.claim_sha256",
        )
        receipt = _require_nonzero_sha256(
            payload["receipt_sha256"],
            f"resource commit {index}.receipt_sha256",
        )
        if receipt in receipt_digests:
            raise EventEvidenceError("resource receipt was duplicated")
        receipt_digests.add(receipt)
        if mode == "m1x4":
            lane = require_u32_hex(
                payload["lane_index"],
                f"resource commit {index}.lane_index",
            )
            if lane >= LANE_COUNT or lane in committed_lanes:
                raise EventEvidenceError("M1 resource commit lanes are not unique")
            committed_lanes.add(lane)
            if _thread_id(record) != lane_threads[lane]:
                raise EventEvidenceError(
                    "M1 resource commit contains a worker thread substitution"
                )
        else:
            if (
                require_u64_hex(
                    payload["b4_post_commit_abi"],
                    "B4 resource commit.b4_post_commit_abi",
                )
                != B4_POST_COMMIT_ABI
            ):
                raise EventEvidenceError("B4 post-commit ABI is unsupported")
            if _thread_id(record) != lane_threads[0]:
                raise EventEvidenceError(
                    "B4 resource commit contains a root-thread substitution"
                )
        committed_times.append(_timestamp(record))

    barrier_ns: int | None = None
    if barrier_record is not None:
        barrier = _payload(
            barrier_record,
            M1_RESOURCE_BARRIER_PAYLOAD_FIELDS,
            "M1 resource barrier",
        )
        _require_identity_payload(barrier, contract, "M1 resource barrier")
        if (
            require_u64_hex(
                barrier["barrier_abi"],
                "M1 resource barrier.barrier_abi",
            )
            != M1_BARRIER_ABI
        ):
            raise EventEvidenceError("M1 resource barrier ABI is unsupported")
        if (
            require_u32_hex(
                barrier["arrival_count"],
                "M1 resource barrier.arrival_count",
            )
            != LANE_COUNT
        ):
            raise EventEvidenceError("M1 resource barrier requires four arrivals")
        _require_nonzero_sha256(
            barrier["committed_snapshot_sha256"],
            "M1 resource barrier.committed_snapshot_sha256",
        )
        _require_nonzero_sha256(
            barrier["barrier_receipt_sha256"],
            "M1 resource barrier.barrier_receipt_sha256",
        )
        if _thread_id(barrier_record) not in lane_threads:
            raise EventEvidenceError(
                "M1 resource barrier contains a worker thread substitution"
            )
        barrier_ns = _timestamp(barrier_record)
        if any(commit_ns > barrier_ns for commit_ns in committed_times):
            raise EventEvidenceError("M1 barrier preceded a resource commit")

    released = _payload(
        release_record,
        RESOURCE_RELEASED_PAYLOAD_FIELDS,
        "resource_released",
    )
    _require_identity_payload(released, contract, "resource_released")
    if (
        require_u64_hex(
            released["resource_bank_abi"],
            "resource_released.resource_bank_abi",
        )
        != RESOURCE_BANK_ABI
    ):
        raise EventEvidenceError("resource release uses another ResourceBank ABI")
    expected_releases = LANE_COUNT if mode == "m1x4" else 1
    if (
        require_u32_hex(
            released["release_count"],
            "resource_released.release_count",
        )
        != expected_releases
    ):
        raise EventEvidenceError("resource release count does not match its mode")
    if not _require_bool(released["used_zero"], "resource_released.used_zero"):
        raise EventEvidenceError("ResourceBank was not fully released")
    _require_nonzero_sha256(
        released["released_snapshot_sha256"],
        "resource_released.released_snapshot_sha256",
    )

    end = _payload(end_record, OBSERVATION_END_PAYLOAD_FIELDS, "observation_end")
    _require_identity_payload(end, contract, "observation_end")
    if end["mode"] != mode or end["status"] != "complete":
        raise EventEvidenceError("observation_end is not complete for this mode")
    if (
        require_u32_hex(
            end["published_token_count"],
            "observation_end.published_token_count",
        )
        != TOTAL_TOKEN_EVENTS
    ):
        raise EventEvidenceError("observation_end token count must equal 256")

    observation_begin_ns = _timestamp(records[1])
    release_ns = _timestamp(release_record)
    observation_end_ns = _timestamp(end_record)
    if _timestamp(records[0]) > observation_begin_ns:
        raise EventEvidenceError("observation contract followed observation_begin")
    if any(
        not observation_begin_ns <= commit_ns <= observation_end_ns
        for commit_ns in committed_times
    ):
        raise EventEvidenceError("resource commit lies outside the observation")
    if mode == "m1x4" and barrier_ns is not None:
        if any(barrier_ns > lane.begin_ns for lane in lanes):
            raise EventEvidenceError("an M1 lane began before the four-way barrier")
    if mode == "b4" and committed_times[0] > min(
        lane.first_publish_ns for lane in lanes
    ):
        raise EventEvidenceError("B4 published a token before resource commit")
    if any(lane.end_ns > release_ns for lane in lanes):
        raise EventEvidenceError("ResourceBank release preceded a lane end")
    if not release_ns <= observation_end_ns:
        raise EventEvidenceError("observation ended before ResourceBank release")
    if any(
        lane.begin_ns < observation_begin_ns or lane.end_ns > observation_end_ns
        for lane in lanes
    ):
        raise EventEvidenceError("lane interval lies outside the observation")
    return observation_begin_ns, observation_end_ns


def validate_raw_event_v3_observation(
    segments: Sequence[EncodedSegment],
    expected_root_sha256: str,
    expectation: ObservationExpectation,
) -> ValidatedObservationEvidence:
    """Validate one complete fixed-four-lane logical raw-event-v3 observation.

    ``segments`` must contain coordinator, lane-0 through lane-3, and sampler
    in :data:`SEGMENT_ORDER`.  The function first verifies canonical JSONL,
    every segment hash chain and commitment, then the six-way observation
    root, and only then evaluates the exact semantic event contract.  A caller
    must supply independently trusted identity/digest expectations; the event
    stream is never allowed to choose its own comparison boundary.

    The M1x4 coordinator sequence is ``contract, begin, commit*4, barrier,
    release, end``; B4 is ``contract, begin, commit, release, end``.  Every
    lane is exactly ``lane_begin, token_published*64, lane_end``.  In this
    logical-only profile the sampler is exactly one
    ``physical_metrics_unavailable`` marker.  The payload-key sets declared at
    module scope are exact: missing and unknown fields are both rejected.

    A successful return proves only this observation's logical contract.  It
    deliberately does not promote a performance result: ABBA/BAAB balance,
    environment brackets, emitter identity/challenge binding, repetitions and
    confidence intervals, and campaign thread-temperature policy are outside
    this per-observation ABI.  Physical publication additionally remains
    unavailable until a separate external symmetric sampler ABI exists.
    """

    _validate_expectation(expectation)
    if len(segments) != len(SEGMENT_ORDER):
        raise EventEvidenceError("semantic observation requires exactly six segments")
    if not all(isinstance(segment, EncodedSegment) for segment in segments):
        raise EventEvidenceError("segments must contain EncodedSegment values")
    commitments = tuple(segment.commitment for segment in segments)
    if tuple(item.segment for item in commitments) != SEGMENT_ORDER:
        raise EventEvidenceError("semantic observation segments are not in fixed order")
    for commitment in commitments:
        if commitment.campaign_id != expectation.campaign_id:
            raise EventEvidenceError("segment substituted another campaign")
        if commitment.observation_id != expectation.observation_id:
            raise EventEvidenceError("segment substituted another observation")

    records_by_segment = tuple(
        verify_segment(segment.data, segment.commitment) for segment in segments
    )
    observation_root = verify_observation_root(
        expectation.campaign_id,
        expectation.observation_id,
        commitments,
        expected_root_sha256,
    )
    coordinator_records = records_by_segment[0]
    if not coordinator_records:
        raise EventEvidenceError("coordinator segment is empty")
    contract = _parse_contract(coordinator_records[0], expectation)
    lanes = tuple(
        _parse_lane(
            lane,
            records_by_segment[lane + 1],
            contract,
            expectation.lanes[lane],
        )
        for lane in range(LANE_COUNT)
    )
    lane_threads = tuple(lane.thread_id for lane in lanes)
    if contract.mode == "m1x4":
        if len(set(lane_threads)) != WORKER_COUNT:
            raise EventEvidenceError("M1x4 requires four distinct root worker threads")
        if max(lane.begin_ns for lane in lanes) >= min(lane.end_ns for lane in lanes):
            raise EventEvidenceError("M1x4 lacks a proven four-way execution overlap")
    elif len(set(lane_threads)) != 1:
        raise EventEvidenceError(
            "B4 lane publications must originate from its one cohort root thread"
        )
    if len({lane.binding_sha256 for lane in lanes}) != LANE_COUNT:
        raise EventEvidenceError("the four lane workload bindings are not distinct")

    observation_begin_ns, observation_end_ns = _validate_coordinator(
        coordinator_records,
        contract,
        lanes,
    )
    _validate_sampler(records_by_segment[-1], contract)
    return ValidatedObservationEvidence(
        contract=contract,
        lanes=lanes,
        records_by_segment=records_by_segment,
        observation_root_sha256=observation_root,
        observation_begin_ns=observation_begin_ns,
        observation_end_ns=observation_end_ns,
        physical_metrics_available=False,
        logical_observation_available=True,
        campaign_publication_available=False,
        campaign_publication_unavailable_reason=(
            "per-observation evidence does not prove campaign schedule balance, "
            "environment brackets, emitter identity challenge, repetitions/CI, "
            "or thread-temperature policy"
        ),
        physical_performance_publication_available=False,
    )
