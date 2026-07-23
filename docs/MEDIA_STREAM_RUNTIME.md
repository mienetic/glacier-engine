# Bounded Media Stream Runtime

The bounded stream runtime composes multiple hierarchical media transactions
under one image, audio, or video timeline. Each chunk receives its own immutable
`ResourceBank` parent and per-buffer `LeaseTree`, while `StreamSession` keeps
every committed output lease live until the caller closes the stream.

This is a model-free streaming contract. The retained fixtures cover two chunks
per modality; the fixed session capacity is four chunks. It does not claim a
production codec, capture device, media model, playback system, or
cross-process restart.

## Chunk lifecycle

```text
declare exact target [units_before, units_after)
                 │
                 ├─ gap / overlap / length drift → reject before admission
                 ▼
open chunk parent + role scopes
                 ▼
charge source + mappings + output before use
                 ▼
execute → revalidate → commit one timeline publication
                 │
                 ├─ cancel/fail → scrub + reclaim unpublished chunk
                 ▼
retire source + mappings (+ declared scratch)
                 ▼
retain output lease and append portable chunk-chain receipt
                 ▼
next chunk or close all retained outputs and parents to zero
```

The declared target start must equal `PublicationStateV1.visible_units`, and
the declared target length must equal the sealed transform plan's logical unit
count. This rejects both gaps and overlaps without opening a Bank receipt.
Source-region semantics remain transform-specific: image regions may be
independent, while retained audio and video fixtures use adjacent source ranges.

A stream uses one address-stable `StreamSession`. It owns a fixed array of
single-chunk hierarchical sessions and rejects concurrent prepare operations,
copied transaction replay, and work beyond its declared chunk limit.

## Retained ownership

After each successful chunk:

- decoded-source and mapping allocations are scrubbed and retired;
- scratch would follow the same provisional lifetime when a future valid plan
  declares it;
- the output allocation and its parent remain charged;
- the media timeline and publication sequence advance exactly once; and
- the next chunk is chained to the prior stream receipt.

This means a two-chunk stream has exactly two live output allocations after its
second commit. `closeAndRelease` releases those outputs, closes both trees, and
releases both parents. Output bytes remain in caller-owned storage; releasing
logical ownership does not erase the caller's published result.

Cancellation calls the nested transaction abort, scrubs all provisional
regions, retires the unpublished allocation leaves, closes the empty tree, and
releases the parent. The stream index, visible units, publication sequence, and
prior retained outputs remain unchanged, so the same chunk boundary can retry.
Resource pressure follows the same fail-closed boundary: a rejected next chunk
does not release or mutate any output retained by an earlier commit.

## Portable chunk chain

`ChunkReceiptV1` is a fixed 352-byte body/footer record. It binds:

- media kind, request epoch, and stream identity;
- stream-local chunk index and media publication sequence;
- exact target units before and after the chunk;
- output bytes, mapping count, and lease-binding counts;
- media object and transform-plan roots;
- the fully verified 1,536-byte lease receipt root;
- output and publication-commit roots;
- the previous stream chunk root; and
- a SHA-256 footer over the canonical 320-byte body.

Chunk zero requires a zero previous root; every later chunk requires a nonzero
root matching its predecessor. `verifyChunkReceiptV1` assumes the referenced
lease execution receipt has already passed its full
`verifyLeaseExecutionReceiptV1` check, then verifies the stream boundary and
chain composition. The independent Python oracle follows the same separation.

## Run the proof

```sh
zig build media-stream-demo -Doptimize=ReleaseSafe -Dmetal=false
zig test src/core/media_stream_runtime.zig -OReleaseSafe
python3 -m unittest bench.tests.test_media_stream_runtime
```

The demo commits six chunks across image, audio, and video; retains two outputs
per stream; exercises one cancellation/retry; rejects one target gap and one
target overlap; performs 21 exact reclamation commits; and finishes with zero
Bank usage, live allocations, and active trees. Native and Python tests share a
two-chunk golden chain, flip all 352 serialized bytes, and reject rehashed
boundary, state, execution, stream-key, and predecessor substitutions.
The native suite also constrains the Bank to one committed chunk and proves
that pressure rejection leaves the earlier output allocation and tree live.

## Continuation boundary

The first continuation layer is complete in
[Media Stream Continuation](MEDIA_STREAM_CONTINUATION.md):

1. ~~a fixed stream checkpoint binding the latest chunk root, exact visible
   unit, publication sequence, retained output manifests, and ownership plan;~~
2. ~~fresh-generation reacquisition of retained output leases before resume;~~
3. ~~a real source/target process restart for image, audio, and video retained
   fixtures;~~
4. ~~place checkpoint and output objects under one crash-atomic archive/selector,
   then repeat process death at every write, sync, and root-switch boundary;~~
   complete for two whole image/audio/video generations and seven native
   `SIGKILL` boundaries;
5. ~~add repeated checkpoint generations after resumed chunks, rebinding fresh
   ownership without accepting stale source receipts;~~ complete for one
   generation-two to generation-three transition and another fresh resume;
6. add family-specific state for audio windows, video temporal caches, and
   image processor/cross-attention state; fixed image/audio/video processor and
   synchronized state is complete, while checkpoint binding and
   cross-attention state remain; and
7. define generated-media partial-output and cancellation policy.
