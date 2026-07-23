# Media Stream Continuation

Glacier can checkpoint a bounded image, audio, or video stream after a
committed chunk, release every source-process lease, reacquire the retained
output in a fresh `ResourceBank`, and append the exact next chunk under the
original media timeline.

The retained conformance path now runs in two distinct OS processes for all
three modalities. The source worker syncs checkpoint and output bytes, releases
its Bank, and exits. The target worker verifies the checkpoint, charges
fresh-epoch ownership before accepting materialized output bytes, reconstructs
`PublicationStateV1`, and publishes chunk index one with the checkpoint's chunk
root as its predecessor.

## Boundary

```text
source process
  commit chunk 0
      │
      ├─ retain output lease
      ├─ encode + sync CheckpointV1 and output bytes
      ├─ release source tree and Bank receipt to zero
      └─ exit

target process (different PID and Bank epoch)
  decode checkpoint + match expected root
      │
      ├─ reserve parent and output claim
      ├─ bind restored publication session
      ├─ reserve output allocation (not materialized yet)
      ├─ verify exact output length and SHA-256
      ├─ commit allocation as live
      ├─ reconstruct media state
      ├─ append chunk 1 once
      └─ release restored + new output ownership to zero
```

`ResumeSession` must remain at a stable address from `prepareV1` through
`closeAndRelease`. Its per-output address is part of the restored Bank session
fence. A copied or moved session is not a valid owner.

## Fixed checkpoint

`CheckpointV1` is a fixed 2,048-byte record:

- a 480-byte header;
- four fixed 384-byte retained-output entry slots; and
- a 32-byte SHA-256 footer over the canonical 2,016-byte body.

The header binds media kind, request epoch, checkpoint generation, stream key,
committed chunk count and total limit, exact publication state, restore Bank
epoch, next-chunk key bases, tenant, challenge, last chunk root, prior
checkpoint root, and retained-manifest root.

Each active output entry binds:

- exact stream chunk index and media publication sequence;
- source Bank epoch plus receipt slot/generation/owner identity;
- fresh restore owner, tree, authority, scope, allocation, and binding keys;
- restored resource-publication sequence;
- exact parent and output claims;
- output byte length and SHA-256;
- hierarchical lease receipt root; and
- stream chunk receipt root.

Inactive entry bytes must be zero. Entry identities must be unique, source Bank
epochs must agree, media publication sequences must be contiguous, and the
final entry must equal the header's last chunk root. Zig and Python reconstruct
the same image checkpoint root and reject every one-byte wire mutation.

Checkpoint creation revalidates the fixed lease and chunk receipt shapes plus
the complete predecessor chain held by the source session. A standalone decoder
verifies checkpoint structure and roots; an external acceptor must additionally
verify referenced lease/chunk receipt objects or require the checkpoint root
selected by its trusted continuation authority. `ResumeSession` requires that
expected root explicitly.

## Charge before materialization

Resume is deliberately two phase:

1. `prepareV1` verifies the checkpoint and requires an otherwise empty Bank
   with the exact restore epoch. It reserves parents, opens output-only trees,
   binds restored publication sessions, and charges allocations as
   `reserved_unmaterialized`.
2. `commitMaterializedV1` verifies every retained byte length and SHA-256 before
   converting any reservation to a live allocation. Only after all outputs are
   live does it expose restored media state and initialize the continuation
   stream.

A wrong output leaves the allocation reserved and permits an exact retry.
Expectation-root, foreign-epoch, and insufficient-capacity failures expose no
media state and leave the target Bank at zero.

## Run the proofs

```sh
zig test src/core/media_stream_continuation.zig -OReleaseSafe
python3 -m unittest bench.tests.test_media_stream_continuation
zig build media-stream-continuation-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-stream-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
```

The fresh-runtime demo performs three in-process source/target transitions. The
live-restart demo uses separate source and target PIDs, restores three outputs,
publishes three next chunks, records zero duplicates, and finishes with zero
Bank usage, live allocations, and active trees.

## Deliberate limits

The subsequent
[Atomic Media Stream Checkpoint Sets](MEDIA_STREAM_CHECKPOINT_SET.md) layer now
places all three checkpoints and one retained-output bundle under the existing
immutable archive and atomic selector. Its stateful form adds the fixed
processor/cache bundle as a fifth object, and its materialized form adds exact
cache payloads as a sixth. It accepts only the complete previous or successor
generation after every process-death write/sync/root-switch boundary. It also
rebinds the restored output and cache leases into generation three, advances
the processor lineage, appends one chunk per modality, publishes that successor
atomically, and resumes it from another fresh process.

It does not provide multi-writer leader election, emulate storage-device power
loss, or carry external codecs, capture/playback, media-model state, or
generated-media publication. Fixed family-specific audio windows, video
temporal caches, image processor state, and a synchronized watermark now exist
as an atomic stateful bundle, and exact cache payloads now restore under
fresh-Bank ownership. Typed vision and audio fixtures now consume their live
caches, and a typed temporal-video fixture gathers a charged strided selection
from its live window. A separate overlap-safe adapter publishes typed transcript
segments, the same video selection now publishes a fixed source-bound segment,
a canonical timeline reduces those segments, an exact result link joins newly
publishable transcript time to its accumulated tail, and stateful-model
continuation crosses one process boundary; transcript/video model restart and
production-model integration remain.
