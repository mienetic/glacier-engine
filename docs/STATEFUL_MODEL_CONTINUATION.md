# Stateful Model Continuation

Status: **prototype**. Glacier now checkpoints one committed retained-state
step, exits the source process, restores the intermediate state under a fresh
`ResourceBank`, and publishes the terminal step exactly once in a distinct
target process.

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

The four files are not one crash-atomic checkpoint set, and process restart is
not device power-loss evidence. The fixture uses unsigned-byte arithmetic,
synthetic weights, and no image decoder. The next image-generation slice is a
bounded terminal-latent decode and generated-image publication transaction.

The same continuation contract is intended for recurrent audio state and
temporal video generation, but those family bindings remain gated until their
own state, timeline, cancellation, and publication fixtures exist.

See [Stateful Model Adapter and Latent-Step Fixture](STATEFUL_MODEL_ADAPTER.md),
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md), and
[Benchmark and Evidence Guide](BENCHMARKS.md).
