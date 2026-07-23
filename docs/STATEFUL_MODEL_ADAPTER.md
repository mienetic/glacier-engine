# Stateful Model Adapter and Latent-Step Fixture

Status: **prototype**. Glacier now uses one shared retained-state transaction
for exact synthetic latent-denoise, streaming transcript, and VFR
video-understanding fixtures. Model results and replacement states publish
together, and each family carries its intermediate state across a real process
restart under fresh ownership. This proves a reusable stateful runtime
boundary; it is not production-model or output-quality evidence.

## Why a second lifecycle exists

Stateless encoders can publish an output and release every model-local byte.
Iterative generators, recurrent models, agent policies, and other step-based
families must retain a successor state for the next operation. Publishing the
output without that state—or replacing the state without the output—would
create an unreplayable request.

`StatefulModelAdapter` therefore treats these as one transition:

```text
verified model publication + verified retained state
                         │
                exact ResourceBank claim
                         │
          private output + private successor state
                         │
              family candidate validation
                         │
          revalidate permit, lineage, and bytes
                         │
        publish output + replace state, or scrub both
```

## Canonical state publication

`StatePublicationV1` is a fixed 320-byte little-endian wire. It binds:

- request epoch;
- current and terminal step;
- exact retained-state byte length;
- artifact identity;
- current retained-state byte root;
- previous typed-result root;
- challenge; and
- a domain-separated publication root.

Reserved bytes must be zero. Strict decode reconstructs the canonical wire, and
the retained test mutates every serialized byte. Zig and Python share the same
initial publication root.

The session pins both the model-publication root and state-publication root at
initialization. A separately valid but substituted predecessor cannot enter
prepare or commit. The execution plan must bind the state publication through
its processor-state root and the exact current bytes through its cache-payload
root.

## Atomic state/result step

The generic lifecycle:

1. validates the family support record and adapter descriptor;
2. requires one exact claim for weights, conditioning input, private output,
   replacement-state staging, output journal, and queue slot;
3. verifies all mutable buffers are disjoint from each other and immutable
   inputs;
4. executes into private output and successor-state buffers;
5. validates both candidates and constructs a transition root over the state
   before, plan, output, state after, adapter, challenge, and next step;
6. uses that transition as the typed result's source mapping;
7. revalidates permit, pinned publications, current state, and both candidates
   at commit; and
8. copies output and successor state, advances both publication records, then scrubs
   candidates—or aborts and scrubs without changing retained state.

The predecessor state stays read-only for the whole step. A committed
successor lands in a separate visible buffer, so rollback never has to
reconstruct or overwrite the state that authorized the step.

No filesystem, network, provider, clock, device, or external publication
authority reaches the backend.

## Retained latent fixture

`LatentStepAdapter` registers:

- `image_generation / diffuse_step`;
- `latent_tensor` input;
- `media_chunk` output;
- exact unsigned-byte state and output; and
- zero ambient capability.

The tiny fixture starts from `[10, 20, 30, 40]`, uses conditioning
`[1, 2, 3, 4]` and scalar weight `2`, and produces the next state and output
`[8, 16, 24, 32]`. Its purpose is bit-exact lifecycle evidence, not useful
generation.

## Fail-closed cases

Retained tests reject:

- any mutation of the 320-byte state wire;
- a valid but foreign model-publication snapshot;
- plan/state/artifact/challenge substitution;
- current-state bytes that do not match the pinned root;
- candidate, visible, state, weight, or input buffer aliasing;
- candidate output/state disagreement;
- candidate mutation between prepare and commit;
- output outside the declared bound; and
- uncharged or incorrectly sized buffers.

Abort and candidate drift preserve the original retained state, keep both
publication counts and caller-visible buffers unchanged, scrub private
candidates, and release the exact claim.

## Claim boundary

The retained fixture performs two exact steps and one distinct-process restore.
Its checkpoint files are synced but not published through a crash-atomic
selector. It does not provide scheduler variants, floating-point latent
tensors, external weights, image decoding, accelerator execution,
physical-memory measurement, model quality, or compatibility evidence.

The same lifecycle now also powers the exact-integer
[Stateful Audio Transcript Continuation](AUDIO_TRANSCRIPT_CONTINUATION.md) and
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md).

## Run the retained proof

```sh
zig test src/core/latent_step_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_stateful_model_adapter
zig build stateful-model-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_stateful_model_continuation
zig test src/core/stateful_video_adapter.zig -OReleaseSafe
zig build video-model-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_video_model_continuation
```

The continuation details and exact claim boundary are in
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md). The next
generative-image slice should decode the terminal latent through a bounded
generated-media transaction with provenance.

See [Typed Model-Family Contracts and Vision Adapter](MODEL_FAMILY_ADAPTER.md),
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md), and
[Continuation Capsule](CONTINUATION_CAPSULE.md).
