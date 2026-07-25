# Prepared Text Successor Evidence

R1g adds an allocation-free, pointer-free evidence bridge from one verified
non-terminal prepared-text checkpoint to a canonical successor execution
identity. It is an integrated experimental evidence slice for the Glacier AI
Runtime: an inspector, archive writer, or later restored-admission
implementation can agree on the exact plan, residency projection, sequence
boundary, cache payload, and intended target ownership before any live target
authority exists.

The bridge deliberately reuses the Common Model Contract instead of
serializing native `BoundPlanV1` memory:

| Record | Bytes | Purpose |
| --- | ---: | --- |
| `ExecutionPlanV1` | 768 | Canonical successor model, operation, shape, policy, resource, lineage, and sequence identity |
| `ExecutionResidencyBindingV1` | 256 | Canonical projection from total logical resources to the exact request claim |
| `SuccessorSegmentV1` | 512 | Fixed source-checkpoint, transcript, state, cache, successor, ownership-intent, and challenge join |

These records are evidence, not capabilities. R1g does not exit the source,
admit a target, acquire a target `ResourceBank` receipt or service permit,
remap a `LeaseTree`, construct a runnable `SessionV3`, select a durable
generation, or resume execution in another process.

The successor-segment ABI is `0x474c545400000001` (`GLTT` v1), and the
ownership-intent ABI is `0x474c544f00000001` (`GLTO` v1). The plan and
residency records retain their Common Model Contract ABI identifiers.

## Source boundary

Let `N` be the number of already published output tokens. Successor evidence
can be derived only from the exact current checkpoint and retained live source
context when:

```text
0 < N < max_new_tokens
publication_next_sequence = N
sampling_calls = N
output_count = N
kv_positions = prompt_tokens + N - 1
remaining_quanta = max_new_tokens - N
```

The source transcript must be non-terminal, its KV position and state
commitment must equal the checkpoint, and its last resource-permit generation
must be nonzero. The source execution plan, residency binding, bound-plan root,
boundary root, exact receipt, request epoch, and request claim are supplied
independently of the checkpoint and compared contextually. The source plan's
publication base must precede `N`. This v1 prepared-text profile also requires
one autoregressive `generate_sequence` batch, token-ID input and output with
four-byte elements, the implementation-defined numerical policy, no required
capabilities, shared read-only artifact residency, exact request-local scratch
accounting, and the contiguous-publication execution and RNG state ABIs.

Deriving these expected values from the candidate wires would allow a
coherently re-rooted foreign candidate to authorize itself. Structural decoding
therefore remains separate from
`decodeAndVerifyForCheckpointV1`, which reconstructs the expected artifacts
from the caller-retained checkpoint and source/target context before exact
comparison.

## Successor plan projection

The successor is a canonical `ExecutionPlanV1`, not a second
prepared-text-only plan format. It changes exactly the continuation fields
needed at the checkpoint boundary:

| Successor field | Value |
| --- | --- |
| `generation` | source execution generation + 1 |
| `publication_next_sequence` | checkpoint `N` |
| `previous_plan_sha256` | source execution-plan root |
| `cache_payload_sha256` | checkpoint logical-KV root |
| `ownership_sha256` | canonical target ownership-intent root |
| `challenge_sha256` | checkpoint challenge |
| `plan_sha256` | Recomputed canonical Common Model Contract plan root |

Artifact, family, operation, input/output kinds, tensor shapes, numerical and
execution policies, token/cache schema roots, request epoch, total logical
claim, and every other canonical binding are retained from the source plan.
The successor residency binding is then recomputed canonically for the new plan
while retaining the source residency mode, resident weight bytes, and exact
request claim.

## Ownership intent

`TargetOwnershipV1` names the target proposed for a later restored admission:

- scheduler epoch and coordinator identity;
- target Bank epoch and request generation;
- resource owner, tree, authority, tenant, and scope keys;
- cache node and cache binding keys;
- intent generation; and
- the exact request claim.

Every identity is nonzero. The target Bank epoch and resource-owner key must
differ from the source receipt. Request and intent generations must equal the
successor execution generation, and the request claim must exactly equal the
source residency binding's request claim.

The ownership-intent root is SHA-256 over the domain
`glacier-prepared-text-successor-ownership-intent-v1\0`, followed in canonical
little-endian order by:

1. the ownership-intent, `ResourceBank`, `LeaseTree`, `LaneWeave`, and
   execution-plan ABI values;
2. the source receipt root, source ownership root, source plan root,
   checkpoint root, and source-boundary root;
3. source request epoch, sequence base, source generation, and successor
   generation;
4. every target identity and generation listed above;
5. the exact target request-claim fields in `Claim` declaration order:
   capsule, KV, activation, partial, logits, output-journal, staging, device,
   and I/O bytes, then queue slots; and
6. the checkpoint challenge.

This commitment proves only that the evidence set names one exact intended
target. It is not a target receipt, ownership grant, source-exit receipt,
exclusive handoff, or permission to publish.

## Successor transcript segment wire

`SuccessorSegmentV1` is exactly 512 bytes. All integer fields are unsigned
64-bit little-endian values. There is no encoded-length field; exact input
length is checked out of band. The flags field is currently zero.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GLTSEG01` magic |
| 8 | 8 | successor-segment ABI |
| 16 | 8 | flags, currently zero |
| 24 | 8 | request epoch |
| 32 | 8 | sequence base |
| 40 | 8 | terminal sequence |
| 48 | 8 | remaining quanta |
| 56 | 8 | source last resource-permit generation |
| 64 | 8 | source KV position |
| 72 | 8 | source sampling calls |
| 80 | 8 | source output length |
| 88 | 8 | source execution generation |
| 96 | 8 | successor execution generation |
| 104 | 8 | segment generation |
| 112 | 8 | execution ABI |
| 120 | 8 | RNG-state ABI |
| 128 | 32 | source checkpoint root |
| 160 | 32 | source bound-plan root |
| 192 | 32 | source execution-plan root |
| 224 | 32 | source boundary root |
| 256 | 32 | predecessor transcript root |
| 288 | 32 | source state-commitment root |
| 320 | 32 | source logical-KV root |
| 352 | 32 | successor execution-plan root |
| 384 | 32 | successor residency-binding root |
| 416 | 32 | ownership-intent root |
| 448 | 32 | checkpoint challenge |
| 480 | 32 | successor-segment root |

The final root is:

```text
SHA-256(
    "glacier-prepared-text-successor-transcript-segment-v1\0"
    || exact bytes [0, 480)
)
```

The segment consumes no token and emits no runtime event. Its sequence base is
the first sequence that a future target would need to continue from, while its
terminal sequence and remaining quanta preserve the fixed-length admission
boundary.

## Session capture

`SessionV3.captureSuccessorArtifactsV1` is a read-only helper:

```zig
const artifacts = try session.captureSuccessorArtifactsV1(
    checkpoint_bytes,
    checkpoint_challenge,
    target_ownership_intent,
);
```

It derives source expectations from the live `SessionV3`, validates and
constructs the three records, then derives the complete live context again and
exact-compares the before/after values. The caller must serialize the call with
all operations on the Session and its bound receipt authority.

The helper does not mutate output, KV, RNG, counters, Scheduler, Bank, receipt,
publication sequence, transcript, result state, or source authority. Encoding
all three artifacts is failure-atomic: validation and encoding complete in
private fixed-size temporaries before any destination byte is replaced.
Destination ranges must be disjoint; overlap is rejected before publication
and leaves every destination unchanged.

## Verification evidence

The retained Zig fixture freezes these roots:

| Root | SHA-256 |
| --- | --- |
| Successor execution plan | `f678322f4dae556ce2e660787d52811bcc17627a5b3538fa5a2ce9f03d64dfaa` |
| Successor residency binding | `6449605803a760b8f6748c60537f196c4faeb1ee272d397bc39b5903602db244` |
| Ownership intent | `7a27a8ae765d373cd05acd5bc5a9de213173b4a0f48538250756fdff7327d584` |
| Successor segment | `d4b64fea15cae72847f72d586dffae76a225a096de8e26e69a6025b1a452a818` |

The evidence gate includes canonical encode/decode, mutation of every byte in
all three records, every truncated segment length, an extended segment,
coherently re-rooted foreign ownership intent and plan, contextual
substitutions, coherently re-rooted terminal/KV/profile contradictions, invalid
target/source boundaries, overlapping outputs, and failure-atomic
destinations. An independent standard-library Python verifier reconstructs the
same records and roots.

```bash
tools/zig-with-ephemeral-cache.sh test \
  --dep core \
  -Mroot=src/prepared_text_successor.zig \
  -Mcore=src/core/root.zig \
  -lc \
  --test-filter 'prepared successor'
python3 -m unittest bench.tests.test_prepared_text_successor
tools/zig-with-ephemeral-cache.sh build test -Dmetal=false -j2
```

## Safety boundary and next gate

SHA-256 roots detect mutation and contextual substitution when trusted expected
values are retained independently. They do not provide authentication,
encryption, confidentiality, authority, or exactly-once execution.

R1g also does not provide:

- a live target `Scheduler`, `ResourceBank`, receipt, permit, or `LeaseTree`;
- restored admission or permit-generation fencing;
- source exit or proof that only one target can continue;
- a runnable target `SessionV3`;
- durable archive publication or atomic previous/successor selection;
- fresh-process continuation or uninterrupted/resumed terminal equivalence; or
- raw-text tokenizer, production-model, native-platform, quality, or
  performance evidence.

R1h is the next correctness slice: restored Scheduler admission, a newly
validated Bank receipt and permit-generation fence, and `LeaseTree`-aware
publication/receipt remapping against these exact successor records. Durable
selector composition and fresh-process source-exit/exclusive-target proof
follow as separate gates.
