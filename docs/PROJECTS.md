# Contributor Projects

Every item here is intentionally smaller than its parent architecture track. If
an item still feels large, open a **Claim a contributor slice** issue and ask a
maintainer to split it with you.

## Good first issues

### Document one failure path

Pick a public error from `src/core`, create a minimal example that triggers it,
and add the example to the relevant guide.

**Done when:** the example is deterministic, contains no secret or model
download, and a reviewer can reproduce it with one command.

### Add malformed-fixture coverage

Choose an independent Python wire verifier and add one byte-level mutation case
that is not already named by its test suite.

**Done when:** the valid fixture still passes and the mutation fails for the
intended reason.

### Improve platform diagnostics

Add a read-only parser fixture for one Linux machine-envelope field. Do not turn
missing telemetry into a false measurement.

**Done when:** present, missing, denied, and malformed inputs have tests.

### Build a glossary link check

Find unexplained project-specific terms in public documentation and link them to
the glossary, or add concise glossary entries.

**Done when:** Markdown links resolve and no definition overstates implementation
status.

### Create a fixture inspector

Add a read-only command that prints the identities and lengths in one provider
wire fixture without dumping payload text.

**Done when:** output is stable, bounded, and tested against malformed lengths.

## Intermediate projects

### Provider evidence viewer

Create a human-readable renderer for the compact evidence join and its nested
roots. Keep verification separate from presentation.

**First slice:** decode only the envelope, lengths, sequence, and root names.

### Cost-journal portability campaign

Run the crash/recovery harness on another supported filesystem and document which
sync and advisory-lock guarantees are observable.

**First slice:** add environment capture and one non-destructive smoke case.

### LaneWeave trace visualizer

Render admission, service, cancellation, and retirement events as a timeline.
The visualizer must consume verified events and label unverified input.

**First slice:** emit deterministic JSON suitable for a future UI.

### Model fixture expansion

Add a tiny, redistributable fixture covering one loader or tensor-layout branch.

**First slice:** parser and shape validation only; do not bundle large weights.

### Media transform reference models

The first transform slice is complete: one fixed plan now covers image
crop/nearest/tile mapping, weighted stereo-to-mono mixing with exact integer
decimation, and keyframe-only video selection. Zig and Python share plan and
receipt roots, every output unit maps to exact source units/bytes/time, and
unsupported geometry, rate, selection, identity, capacity, and overlap reject.

**Next slice:** add one bounded case—grayscale crop, a second convex channel
mix, a second exact rate factor, or multi-keyframe selection—without expanding
to a production codec. Preserve the existing plan/mapping identity or propose a
versioned ABI with migration fixtures. Reuse
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md).

### Media runtime LeaseTree ownership

This slice is complete for image, audio, and video. The hierarchical runtime
preserves the existing request-wide ABI while assigning exact decoded-source,
mapping, optional scratch, and output allocation leaves. It charges before use,
reclaims every dynamic leaf on abort, retires provisional leaves early after
commit, retains output ownership, emits a fixed pointer-free receipt, and
returns the tree and Bank to zero. Zig and Python share golden roots and
mutation-complete wire tests.

The bounded stream slice is also complete: one address-stable session commits
two chunks per retained modality, rejects target gap/overlap and length drift
before admission, reclaims cancelled unpublished chunks, retains one output
lease per commit, and chains fixed portable receipts.

The first continuation slice is complete too: a fixed 2,048-byte checkpoint
binds the last chunk, exact publication state, retained-output manifest, and
fresh-Bank ownership plan. Separate source and target processes exercise image,
audio, and video restore, with charge before materialization, no duplicate next
chunk, and final zero ownership.

The atomic-set and post-restore successor slices are complete. Three fixed
checkpoints and one canonical retained-output bundle share one immutable
archive root. Seven `SIGKILL` boundaries expose only the complete previous or
successor generation; fresh targets resume all modalities before repair and
again after idempotent convergence to generation two. A separate fresh process
then rebinds six retained outputs, appends three chunks, publishes generation
three, releases its ownership, and a second fresh process resumes that root.
Rehashed stale epochs, replayed receipts, and substituted restored owners
reject independently.

The first processor-state slice is complete too. Fixed records now bind image
tile/patch progress, audio window/hop/context and feature-cache accounting,
video temporal-window/eviction state, logical cache bytes, and an exact
audio/video watermark. Zig and Python share one canonical bundle root.

**Completed slice:** a bounded typed vision-encoder adapter now runs over the
processor-state and materialized-cache path. It preserves generation, request,
media, ownership, cancellation, source mapping, and output publication
identity without ambient authority. See
[Typed Model-Family Contracts and Vision Adapter](MODEL_FAMILY_ADAPTER.md).

**Completed slice:** a typed audio-window encoder now adds signed feature
inputs, sample/window/hop source mapping, and shared stateless publication
without changing the common artifact, plan, or result wire. See
[Typed Audio-Window Encoder Adapter](AUDIO_WINDOW_ADAPTER.md).

**Completed slice:** a typed temporal-video encoder now gathers a canonical
strided frame selection from the owned cache window into charged scratch. It
binds selected ordinals, keyframe lineage, eviction boundary, cache generation,
and exact target timeline without changing the common model wire. See
[Typed Temporal-Video Encoder Adapter](TEMPORAL_VIDEO_ADAPTER.md).

**Completed slice:** overlapping audio context now has a canonical ownership
plan and a fixed predecessor-bound transcript wire. Context-only samples cannot
be mistaken for newly publishable text. See
[Overlap-Safe Audio Transcript Adapter](AUDIO_TRANSCRIPT_ADAPTER.md).

**Completed slice:** a bounded typed video-segment result now reuses the
canonical strided selection, publishes exact frame/time boundaries plus
event/confidence fields, and binds live cache ownership and predecessor
lineage. See [Typed Video-Segment Adapter](VIDEO_SEGMENT_ADAPTER.md).

**Completed slice:** fixed timeline and merge-receipt wires now preserve an
accumulated visible tail across repeated decisions. Same-event overlap
coalesces, while gaps and event changes remain distinct under transactional
publication. See
[Canonical Video-Segment Timeline](VIDEO_SEGMENT_TIMELINE.md).

**Completed slice:** a fixed cross-modal state and result transaction maps only
newly publishable transcript samples onto the accumulated video tail. Exact
integer time, positive overlap, one challenge, and both modality lineages must
verify before publication. See
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md).

**Completed slice:** a stateful transcript family now carries exact next-sample
state through a real process restart. Its fixed composed checkpoint preserves
the previous/next overlap plans, transcript predecessor, video timeline, and
result-link predecessor before the fresh process publishes the next segment.
See
[Stateful Audio Transcript Continuation](AUDIO_TRANSCRIPT_CONTINUATION.md).

**Completed slice:** a stateful video-understanding family now binds explicit
per-frame PTS/duration, feature payload, declared discontinuity, retained model
state, segment predecessor, visible timeline, and result-link predecessor
across a real process restart. See
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md).

**Completed slice:** the exact post-restart terminal latent now enters a bounded
generated-image transaction. Fixed plan, provenance, and result wires bind the
artifact, checkpoint, terminal plan/result/state, decoder, tenant/policy,
resource receipt, timeline event, media commit, and publication predecessors.
Abort and candidate drift preserve visibility; Zig/Python reject every wire
mutation; a real target process commits the image once and returns ownership to
zero. See [Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md).

**Completed slice:** fixed speech annotation state, plan, and result records now
map canonical transcript words to exact sample ranges, first-occurrence speaker
identities, and confidence. Abort/drift preserve visibility, Zig/Python reject
all wire mutations, and a fresh process publishes the next word and turn
without duplication. See
[Exact Speech Annotation Publication](SPEECH_ANNOTATION_PUBLICATION.md).

**Next slices:** add external container timestamp normalization, a production
image decoder adapter, richer language/punctuation or overlapping-speaker
policy, or the first generated-audio chunk with playback acknowledgement. Each
is independently contributor-sized and must preserve the fixed core contracts.

### AI runtime family registry

Define one small part of the common vocabulary from the
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md): a family ID, operation ID,
typed input/output kind, numerical policy, or explicit unsupported result.

**Completed foundation:** fixed family, operation, input, output, and numerical
IDs plus bounded support records and malformed/unknown fixtures distinguish
vocabulary from executable support.

**Next slice:** generate a read-only compatibility renderer from retained
support records. It must not claim that registering a family makes it
executable.

### Stateless encoder result envelope

Design a typed result for one embedding, reranking, or classification fixture.
Keep logical batch-item identity, tensor shape, normalization/tie policy,
artifact root, execution-plan root, and publication sequence explicit.

**Completed foundation:** fixed artifact, execution-plan, and result envelopes
have strict Zig codecs, complete mutation tests, and an independent Python
oracle with shared golden roots.

**Next slice:** add score and ranked-item envelopes with explicit
normalization/tie policy; no model download or quality claim.

### Model-family adapter lifecycle

Prototype `inspect → plan → prepare → validate candidate → publish/abort` with
two fake families that have different state/output semantics.

**Current slice:** vision, audio, and temporal-video stateless vector families
run under zero ambient capabilities, fixed buffers, and deterministic rejection
tests. All three now use the shared family-neutral stateless lifecycle.

**Completed slice:** a family-neutral stateful lifecycle now pins model/state
publication roots and commits replacement state with its typed result. Its
canonical intermediate checkpoint restores under a fresh `ResourceBank` in a
distinct process, chains a terminal plan without duplicate publication, and
releases all ownership. See
[Stateful Model Adapter and Latent-Step Fixture](STATEFUL_MODEL_ADAPTER.md) and
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md).

**Next slice:** add a generic non-media encoder using the converged stateless
lifecycle, or adapt a second bounded generative output while preserving the
generated-image publication contract.

### ResourceBank property tests

Generate bounded sequences of admit, subdivide, publish, retire, cancel, and
release operations, then check exact zero-state recovery.

**First slice:** one deterministic seed and one minimized stale-handle failure.

### Paged-KV ownership restore fixture

This slice is now implemented with canonical committed-row images, durable
payload membership, full source-chain verification, an actual fresh cache, and
foreign-generation rejection.

The following slice is also complete: a fixed runtime state composes the
restored cache with sampler/RNG, output, sequence, and commit lineage, then a
fresh process publishes the next model-free token without duplicated output.
See [Continuation Live Restart](CONTINUATION_LIVE_RESTART.md).

The durability slice is now also complete as a model-free prototype: one
immutable archive plus a fixed selector survives worker termination after all
seven write, sync, rename, and directory-sync phases, then a fresh process
resumes the next token. See
[Continuation Checkpoint File](CONTINUATION_CHECKPOINT_FILE.md).

**Next slice:** compare uninterrupted and resumed output for one small legal
production-model fixture under a declared deterministic numerical mode.

### Live provider adapter boundary

Design a small out-of-core interface that renders requests, counts the exact
wire, performs transport, and returns terminal usage without importing secrets
into core.

**First slice:** fake adapter plus contract tests; no real network call.

## Advanced projects

### Durable sweep recovery state machine

The in-memory path now separates collection planning, prepare/abort staging, and
destructive commit capabilities. Commit regenerates the plan, validates every
canonical retired target before mutation, emits exact before/after accounting,
and rejects replay against the changed snapshot. A fixed 784-byte body/footer
record now carries the canonical commit evidence, reconstructs both receipts,
and passes independent Zig/Python mutation-complete verification. It performs no
filesystem I/O and does not make the transition durable. An allocation-free
anchored classifier now returns the exact committed prefix and distinguishes
short bodies, a body without footer, a matching partial footer, and corrupt
complete evidence. A snapshot-bound writer model now separates append from
repair authority, enforces ordered body/footer sync, poisons uncertain state,
and explores every partial-write boundary in Zig and Python.

**Completed slices:** fixed pointer-free evidence record, separate commit footer,
chain position, exact pinned expectations, semantic receipt reconstruction, a
pure stream classifier, exclusive snapshot binding, separate append/repair
capabilities, and exhaustive cross-language append, mutation, foreign-chain,
partial-I/O, poison/reopen, and repair fixtures.

The POSIX adapter now implements the next boundary with descriptor-relative
one-component admission, no-follow open, exclusive advisory locking,
device/inode/link/permission fencing, explicit-offset write-all, file and
directory sync, namespace-replacement detection, fresh-read reopen, and exact
repair. Native and Python workers terminate after all six append/repair phases.

**Completed slice:** real host-filesystem adapter and process-death conformance
on the promoted macOS development host, plus portable Linux compilation.

The destructive path now computes an exact receipt and predicted post-state
without mutation, syncs that fixed record before deallocation, proves an
injected post-publication failure leaves the store unchanged, and reconciles the
exact old/new snapshots idempotently in Zig and Python.

**Completed slice:** publication-before-deallocation ordering for the in-memory
payload store.

The payload byte plane now uses a canonical tenant snapshot, a fixed 968-byte
reclaim record carrying every exact target, and copy-on-write promotion under a
stable lock inode. Native and independent Python workers terminate after plan
write/sync/directory-sync and candidate write/sync/rename/directory-sync, then a
fresh process recovers the exact old or new root idempotently.

**Completed slice:** native durable payload bytes and seven-boundary
process-death conformance on the macOS development host.

**Completed slice:** a canonical ownership plan now reacquires a fresh
ResourceBank/LeaseTree and charges exact objects before they become live.

**Completed slice:** canonical committed-row images now rebuild a fresh
paged-KV cache under those reacquired nodes and reject foreign page identity
before publication.

**Completed slice:** a fixed runtime wire now composes sampler/RNG/output,
logical KV, exact sequence, and commit lineage; a fresh process publishes the
next token without duplication and returns ownership to zero.

**Completed slice:** an immutable complete checkpoint archive plus fixed root
selector now survives process death at every archive/selector durability phase
and launches a fresh live resume after recovery.

**Next slice:** add an uninterrupted/resumed small production-model comparison.
A separate contributor slice can run the existing evidence, payload, and
restart campaigns on native Linux filesystems.

### Resolver adversarial fixtures

Extend the in-memory resolver without adding storage authority.

**First slice:** table-driven malformed grants and catalogs covering every
public resolver error while proving destination bytes and accounting remain
unchanged on pre-copy failure.

### Tenant-safe immutable page store

Explore content-addressed immutable pages with tenant-scoped access, provenance,
and corruption handling.

**First slice:** threat model and fake-store state machine.

### Capability-isolated extensions

Define an extension boundary whose declared capabilities can be admitted and
recorded before executing third-party planner, tokenizer, or transport code.

**First slice:** capability vocabulary and fail-closed negotiation tests.

### Generative-media state adapter

Model a tiny deterministic latent plus scheduler-step state without an image or
video model. Bind artifact, numerical policy, current step, latent root,
candidate output, cancellation, checkpoint, and publication lineage.

**First slice:** pure state machine that survives one process restart and never
publishes the same synthetic media chunk twice.

### Agent action authorization boundary

Separate a model-proposed action from permission to invoke a tool. A proposal
may name a schema and arguments but cannot acquire network, filesystem, process,
or credential authority by itself.

**First slice:** one fake idempotent tool, exact proposal/result roots,
operation/byte ceilings, cancellation, replay rejection, and no real I/O.

### Production weight pager

Replace the mechanics prototype with logical representation identity, pins,
async reservations, actual resident-byte accounting, and execution integration.

**First slice:** pure state machine with a fake backend; no performance claim.

## Non-code contributions

- Reproduce a documented command on a new platform.
- Review a format table against the encoder and decoder.
- Improve diagrams, examples, error messages, or accessibility.
- Minimize a failing fixture.
- Translate an onboarding guide while keeping English as the normative contract.
- Review evidence claims for scope and reproducibility.

## Proposing a new project

A useful proposal identifies one user problem, one smallest mergeable behavior,
named rejection cases, an acceptance command, and what remains out of scope. New
ideas are welcome even when they do not fit an existing roadmap track.
