# Prepared Text Checkpoint

The prepared-text checkpoint combines an experimental R1e codec with an R1f
same-process rebind, an R1g successor-evidence bridge, and an R1h-a
barrier-held target admission for one exact non-terminal `SessionV3` boundary.
It captures the committed output prefix, RNG state, sampling count, and
contiguous KV prefix as a canonical little-endian byte image. A verified image
can be materialized into a fresh detached allocation, used to replace only the
concrete state backing of the original live Session, joined to canonical
pointer-free successor records, or joined with those successor records and
independently retained source/target context to acquire a non-runnable fresh
target receipt/tree bootstrap.

Detached is an important boundary. The materialized payload has no Scheduler,
ResourceBank, receipt, service permit, sink, or publication authority. It is
not a runnable restored Session, a durable checkpoint, or fresh-process resume.
R1f does not attach authority to that detached value; the live Session decodes
and materializes the image internally while retaining its existing authority.
R1g likewise creates no target authority by itself: its target ownership intent
and successor plan/residency/transcript records are evidence, not a receipt or
runnable Session. See
[Prepared Text Successor Evidence](PREPARED_TEXT_SUCCESSOR.md).
R1h-a acquires live target admission/receipt/tree authority, but leaves the
adoption barrier pending and an allocation-empty LeaseTree with one
zero-current-claim scope; it still does not attach authority to the detached
payload or create a runnable restored Session. See
[Prepared Text Restore Admission](PREPARED_TEXT_RESTORE_ADMISSION.md).

## What the slice proves

- `SessionV3.captureCheckpointV1` accepts only a live, idle, non-terminal
  boundary after at least one published output.
- The image binds independently retained local-plan, bound-plan, artifact,
  execution-plan, residency, boundary, transcript, state-commitment, and
  challenge roots.
- Output tokens use canonical little-endian `u32`.
- KV payload order is layer ascending, committed K prefix, then committed V
  prefix. Every `f32` is preserved as its exact IEEE bit pattern encoded as a
  little-endian `u32`.
- The verifier reconstructs the output chain, RNG root, full logical KV root,
  incremental publication KV chain, and complete publication state commitment.
- `materializeDetachedV1` zeros every output and KV allocation before copying
  the committed prefixes. Uncommitted capacity is therefore deterministic
  zero, not allocator residue.
- `SessionV3.rebindCheckpointV1` validates the live context both before and
  after internal materialization, verifies exact output/KV bytes and zero
  slack, then replaces only the original Session's output and KV backing.
- A successful rebind preserves the embedded publication-coordinator address,
  Scheduler, ResourceBank, receipt, request epoch, sequence, transcript/state
  roots, cache-field address, and scalar-field addresses. It consumes no
  service permit and emits no Scheduler or Bank event.
- Rebinding the same exact boundary again is logically idempotent. A checkpoint
  from an earlier sequence cannot rewind or branch the Session.
- A service permit acquired before rebind remains valid for the ordinary next
  step; the complete next transition, output/RNG/counters, and logical KV state
  match a separately executed uninterrupted reference.
- Failure atomicity is swept across every candidate-allocation boundary.
  Coherently footer-resealed payload corruption, allocation failure, challenge
  mismatch, moved authority, and an active row transaction leave the live
  Session, Scheduler, Bank, receipt, and concrete backing unchanged.
- The retained synthetic fixture has independent Zig and Python encoders,
  decoders, component roots, whole-wire golden, every-byte mutation rejection,
  coherent contradiction rejection, and raw `+0`, `-0`, infinity, and NaN
  payload coverage.
- `SessionV3.captureSuccessorArtifactsV1` contextually derives a canonical
  successor Common Model Contract plan and residency binding plus a fixed
  transcript segment at the exact checkpoint sequence. It verifies that the
  complete live source context is unchanged before returning and grants no
  target authority.
- `prepareRestoredAdmissionV1` consumes those records into a fresh target
  admission and receipt, an exact allocation-empty LeaseTree with one
  zero-current-claim scope, restored sequence, and cross-Bank
  publication-permit fence while retaining the non-runnable adoption barrier.

## State constraints

Let `N` be the number of published output tokens:

```text
0 < N < max_new_tokens
publication_next_sequence = N
sampling_calls = N
kv_positions = prompt_tokens + N - 1
max_kv_positions = prompt_tokens + max_new_tokens - 1
terminal = false
```

Sequence zero is excluded because the next token would depend on prefill
logits, which are not serialized. For `N > 0`, the prepared execution path
recomputes the next logits from the last output token and committed KV state.
The payload therefore contains the numerical inputs needed for the next decode
only when it is joined to the original compatible model, scratch/rope state,
live Session, and authority. It is not sufficient to construct a new runnable
Session or authorize a continuation by itself.

Capture also requires:

- the result receipt is still live;
- terminal evidence is not sealed;
- the nested admission receipt still equals the retained receipt;
- the ResourceBank validates the embedded publication-coordinator address
  (`&publication_session.inner`), request epoch, and current publication
  sequence;
- no KV row transaction or publication attempt is active;
- the V2 boundary remains contextually valid for the retained local and bound
  plans; and
- the dedicated result-publication state is still its initial zero-result
  state.

## Canonical wire

All integers are little-endian. The fixed header is 544 bytes.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GLTCKP01` magic |
| 8 | 8 | checkpoint ABI |
| 16 | 8 | total encoded bytes |
| 24 | 4 | allowed flags, currently zero |
| 28 | 4 | reserved zero |
| 32 | 256 | eight 32-byte identity/boundary/state roots |
| 288 | 96 | twelve `u64` state and geometry fields |
| 384 | 32 | four raw RNG `u64` words |
| 416 | 128 | output, RNG, logical-KV, and challenge roots |
| 544 | `4 × N` | canonical output-token payload |
| variable | `4 × KV elements` | canonical committed KV payload |
| final 32 | 32 | domain-separated whole-image SHA-256 |

The total size is:

```text
576 + 4 × output_count + 4 ×
    (num_layers × 2 × kv_positions × kv_dim)
```

The whole-image root detects accidental or adversarial mutation when the
expected roots and challenge are retained independently. SHA-256 alone is not
authentication, authorization, encryption, or confidentiality. Output and KV
bytes may reveal information about the prompt and must be protected according
to the embedding application's data policy.

Every `f32` bit pattern is valid and distinct. The codec does not normalize
negative zero, infinities, subnormals, or NaN payloads because the live
contiguous commitment also hashes their raw bits.

## Zig flow

```zig
const checkpoint_bytes = try session.captureCheckpointV1(
    allocator,
    checkpoint_challenge,
);
defer allocator.free(checkpoint_bytes);

const decoded = try glacier.prepared_text_checkpoint.decodeCheckpointV1(
    checkpoint_bytes,
    expected_bindings,
);
var detached =
    try glacier.prepared_text_checkpoint.materializeDetachedV1(
        allocator,
        decoded,
    );
defer detached.deinit();

const installed_root = try session.rebindCheckpointV1(
    checkpoint_bytes,
    checkpoint_challenge,
);
std.debug.assert(std.mem.eql(
    u8,
    &installed_root,
    &decoded.checkpoint_sha256,
));
```

The caller must construct `ExpectedBindingsV1` from roots and scalar context
retained outside the checkpoint: request/sequence, prompt/output bounds,
vocabulary, KV geometry, output count, and sampling count are compared
directly as well as through their nested commitments. Deriving expectations
from the untrusted image would make coherent substitution self-authorizing.

Do not move or copy the live Session while capturing. The returned byte slice
belongs to the supplied allocator. `DecodedV1` borrows the encoded slice;
retain the bytes until decoding and detached materialization are complete.
The checkpoint bytes and detached output/KV allocations are caller-owned and
are not charged to the live Session's `ResourceBank`. Applications must apply
their own memory admission to caller materialization.

`rebindCheckpointV1` does not accept a caller-built detached payload. It derives
all expected roots and scalar bindings from the current live Session, decodes
the bytes against those expectations, materializes with the Session allocator,
and verifies the unchanged live context a second time before mutation. After
all fallible checks, it moves the fresh cache/output descriptors into their
existing fields and releases the old backing. Previously borrowed output
slices, cache slices, and row-transaction marks are invalid after success.

The brief overlap between old and candidate allocations is not a new
`ResourceBank` admission or evidence of physical peak-memory accounting. The
logical capacity and charged ownership are unchanged; integrations that impose
a physical peak limit must enforce it outside this experimental rebind.
Calls must be serialized with every other operation on the same Session.

The experimental API preserves the checkpoint decoder's error categories
rather than collapsing every rejection into one code. Examples include
`ChallengeMismatch` for the caller challenge, `BindingMismatch` for a stale or
foreign live context, `InvalidCheckpoint` for internally inconsistent payload
bytes, and `OutOfMemory` for private materialization. Invalid live-Session
state is reported as the prepared-session `InvalidState`.

## What is deliberately not implemented

- moving the state into a new Session or rewinding the original Session to an
  earlier boundary;
- running the detached payload;
- moving publication authority to a new Session address;
- concurrent Session operations during rebind;
- exactly-once continuation from a nonzero sequence;
- durable filesystem publication or crash recovery;
- source/target exclusivity or fresh-process handoff;
- target admission, a remapped receipt/permit, or a runnable successor Session;
- cross-backend numerical equivalence; or
- confidentiality and authenticated storage.

The current publication Session and ResourceBank bind authority to the exact
embedded publication-coordinator address (`&publication_session.inner`).
Their initializers also begin at sequence zero. Bypassing those fences would
make duplicate or stale publication possible.

## Roadmap from same-process rebind to fresh-process continuation

1. ~~Add a verified retained-authority rebind at the exact current boundary,
   without changing Scheduler, Bank, receipt, sequence, or coordinator
   address.~~ Complete in R1f for the original same-process Session.
2. ~~Define a successor plan/residency and transcript segment ABI with a
   nonzero sequence base, source-boundary lineage, nonempty cache payload root,
   and explicit target ownership intent.~~ Complete in R1g as pointer-free
   evidence; it deliberately does not claim an authority handoff.
3. ~~Add barrier-held Scheduler restored admission, a fresh ResourceBank
   receipt/permit-generation fence, and allocation-empty LeaseTree-aware
   publication/receipt remapping.~~ Complete in R1h-a without KV allocation or
   target activation.
4. Partition request accounting, restore KV/output/RNG state under charge,
   construct a restored Session, and commit LeaseTree-aware adoption.
5. Wrap the state image and authority records in the existing immutable
   checkpoint archive and atomic selector.
6. Prove source exit, target exclusivity, fresh-process continuation, no
   duplicate token, and final terminal-result equivalence.

Each step is a separate contributor-sized correctness gate. The codec and R1g
successor records remain useful before resume as portable inspector inputs,
deterministic state snapshots, corruption detectors, archive building blocks,
and cross-language conformance targets.

## Acceptance commands

```bash
tools/zig-with-ephemeral-cache.sh build test -Dmetal=false -j2
python3 -m unittest bench.tests.test_prepared_text_checkpoint
python3 -m unittest bench.tests.test_prepared_text_successor
```

The repository wrapper uses disposable local and global Zig caches and removes
them after each command.
