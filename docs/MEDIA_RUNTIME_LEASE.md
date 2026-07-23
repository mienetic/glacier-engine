# Hierarchical Media Buffer Ownership

The hierarchical media runtime gives every transform buffer its own
generation-fenced `LeaseTree` identity before any caller-owned storage becomes
model-visible. It extends the request-wide
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md) without changing that ABI.

This is a model-free image/audio/video runtime slice. The retained executors use
small deterministic fixtures, not production codecs or media models.

## Ownership shape

One immutable parent receipt owns control-plane resources:

| Parent claim | Exact derivation |
| --- | --- |
| Capsule | 416-byte decode plan + 512-byte transform plan |
| I/O | Encoded fixture length |
| Queue | One publication slot |

The tree ceiling owns execution buffers:

| Lease role | Claim class | Lifetime |
| --- | --- | --- |
| Decoded source | Activation bytes | Provisional |
| Output mappings | Staging bytes, 128 per logical unit | Provisional |
| Scratch | Staging bytes, omitted when zero | Provisional |
| Output | Output-journal bytes | Retained after commit |

The parent and tree claims join exactly to the existing request-wide claim. A
scope and allocation leaf are created for each nonzero role. The current
fixtures therefore use three scopes and three allocation leaves. Their retained
transform ABIs require zero scratch. The fourth role is reserved and implemented
for a future valid transform plan that declares nonzero scratch; it is not an
end-to-end scratch-execution claim in this milestone.

## Lifecycle

```text
admit parent → open bounded tree → open exact role scopes
       │
       ▼
reserve all allocation leaves atomically
       │
       ▼
materialize caller buffers → mark leaves live
       │
       ▼
acquire publication permit → execute → verify candidate
       │
       ├─ abort/failure → scrub bytes → retire every allocation
       │
       ▼
commit media state + ResourceBank sequence
       │
       ▼
retire decoded source + mappings + scratch
       │
       ▼
retain output lease → release output → close tree → release parent
```

Allocation reservation is atomic. Capacity or node-pool exhaustion leaves the
tree at its parent-only state. After a successful reservation, failure scrubs
the caller-owned regions before the Bank uncharges their allocation leaves.
Copied or stale tree, scope, allocation, transaction, and publication handles
cannot repeat a completed transition.

`retireProvisional` is an explicit post-commit boundary. It clears decoded
source, mapping, and scratch storage and retires those allocation leaves while
keeping the output bytes and output lease live. `closeAndRelease` then retires
the output, closes the empty tree, and releases the immutable parent receipt.

## Receipt

`LeaseExecutionReceiptV1` has a fixed 1,536-byte body/footer wire. It binds:

- operation, media kind, request epoch, and both publication sequences;
- total claim plus the exact parent receipt and final live tree token;
- up to four ordered role bindings with scope and allocation identity;
- fixture, plan, transform receipt, output, and mapping-chain roots;
- the binding-manifest and resource-commitment roots;
- timeline event and publication commit roots; and
- tenant identity and a SHA-256 footer over the complete 1,504-byte body.

The compact node evidence is pointer-free. The verifier reconstructs the exact
scope/allocation claim and stable node handle for each role, checks parent
relationships and unique indices, validates node and tree integrity, reexecutes
the transform verifier, and reconstructs the resource and media publication.
Structural decoding alone is not semantic authorization; callers must run
`verifyLeaseExecutionReceiptV1`.

The receipt records the tree before provisional retirement. It proves which
buffers were live at the atomic publication boundary, while later Bank
transitions prove their reclamation.

## Run the proof

```sh
zig build media-runtime-lease-demo -Doptimize=ReleaseSafe -Dmetal=false
zig test src/core/media_runtime_lease.zig -OReleaseSafe
python3 -m unittest bench.tests.test_media_runtime_lease
```

The demo covers image, audio, and video, one explicit abort/retry, exact early
retirement, retained output, and final zero resource state. The independent
Python oracle reconstructs the same isolated-bank tree and receipt roots. Tests
flip every byte in the 1,536-byte wire and reject rehashed semantic
contradictions, authority substitution, output mutation, hard-cap admission,
node exhaustion, and stale handles.

## Deliberate limits

This milestone does not add production decoders, model execution, device
allocation authority, durable output storage, or cross-process media
continuation. Those are separate layers so each can retain charge-before-use,
exact publication, and zero-orphan guarantees.

The next media-runtime sequence is:

1. ~~bounded multi-chunk input and output streams under one timeline;~~ complete
   in [Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md);
2. checkpointable stream position and fresh-generation lease reacquisition;
3. typed image, audio, and video model adapters;
4. generated-media publication with partial-output cancellation policy; and
5. external codec adapters outside the authority-free core.
