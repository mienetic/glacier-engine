# Stateful Model Continuation

Status: **prototype**. Glacier now checkpoints one committed retained-state
step, exits the source process, restores the intermediate state under a fresh
`ResourceBank`, and publishes the successor exactly once in a distinct target
process. The generic checkpoint is now composed by latent-step, streaming
transcript, and VFR video-understanding fixtures.

This is deterministic lifecycle evidence for iterative model families. It is
not image-quality, production scheduler, accelerator, or crash-atomic storage
evidence.

## Portable checkpoint

`StatefulModelContinuation.CheckpointV1` is a fixed 512-byte little-endian
record. It binds:

- request, current step, terminal step, and retained-state length;
- source and required restore Bank epochs;
- exact owner, tree, authority, tenant, scope, allocation, and binding keys;
- next model publication sequence and visible-result count;
- artifact, model-publication, and state-publication roots;
- previous result, last plan, and last output roots;
- current retained-state and challenge roots; and
- one domain-separated checkpoint root.

Reserved bytes must be zero. Zig and Python reconstruct the same root and reject
mutation of every serialized byte. The state publication remains a separate
canonical wire and its root must match the checkpoint before any ownership is
acquired.

## Restore ordering

The target process follows this order:

```text
decode checkpoint + state publication
              │
              ▼
reconstruct exact model publication
              │
              ▼
reserve fresh Bank receipt and LeaseTree allocation
              │
              ▼
verify and copy retained-state payload
              │
              ▼
mark allocation live
              │
              ▼
derive next plan from last-plan + current-state roots
              │
              ▼
publish terminal result + successor state once
              │
              ▼
retire predecessor and release every owner
```

Before the copy, `reserved_unmaterialized_allocations` is one and
`live_allocations` is zero. After verification and materialization those counts
become zero and one. A wrong payload or aliased source/destination rejects
without changing the destination.

The restored model publication begins at sequence one with one visible result.
The terminal plan is generation two, names the first plan as its predecessor,
and publishes sequence one. The final state reaches step two of two with
exactly two visible results; no result is replayed.

## Native process proof

The source worker:

1. executes and commits the first exact latent step;
2. writes the checkpoint, state-publication wire, four retained bytes, and PID;
3. syncs every file and the containing directory;
4. releases source ownership to zero; and
5. exits.

The target worker verifies a different PID, restores the four bytes under the
required fresh Bank epoch, derives the second plan, commits the terminal output
`[6, 12, 18, 24]`, retires the predecessor allocation, and finishes with zero
Bank usage and zero live lease allocations.

Run the proof:

```sh
zig test src/core/stateful_model_continuation.zig -OReleaseSafe
zig build stateful-model-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_stateful_model_continuation
```

## Authority and claim boundary

The checkpoint core has no filesystem, network, device, provider, clock, or
allocator authority. It operates on caller-owned wires and buffers. The native
worker has explicit filesystem authority only to demonstrate a real process
boundary and ordered sync.

The four checkpoint files are not one crash-atomic checkpoint set, and process
restart is not device power-loss evidence. The fixture uses unsigned-byte
arithmetic and synthetic weights. A separate bounded image decoder now consumes
the exact terminal latent and atomically publishes raw pixels, provenance, and
a typed result; it remains a deterministic runtime fixture rather than image
quality evidence.

Recurrent audio transcript state and temporal video-understanding state now
have their own scoped bindings, cancellation-safe publication, timeline/link
lineage, and distinct-process fixtures. Generated-image publication now meets
the bounded decode, provenance, cancellation, and visibility gate for one raw
image. A separate bounded generated-audio transaction now publishes ordered
raw PCM and gates its successor on exact application acknowledgement;
production audio/video models, physical playback, production image decoding,
and shared durable composition remain gated.

See [Stateful Model Adapter and Latent-Step Fixture](STATEFUL_MODEL_ADAPTER.md),
[Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Stateful Audio Transcript Continuation](AUDIO_TRANSCRIPT_CONTINUATION.md),
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md),
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md), and
[Benchmark and Evidence Guide](BENCHMARKS.md).
