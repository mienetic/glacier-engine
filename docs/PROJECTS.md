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

### Add one cross-target core probe

Choose one target from the
[Platform Portability](PLATFORM_PORTABILITY.md) matrix and add a documented,
source-only `core-contract` compile probe. Keep host tools, process-death
workers, and device backends outside the probe.

**Done when:** the command is reproducible, its target and Zig version are
recorded, and the result is labeled compile evidence rather than native support.

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

### Extract one platform capability seam

Move one direct OS dependency—virtual memory, durable file operations, process
control, monotonic time, or telemetry—behind a narrow interface from
[Platform Portability](PLATFORM_PORTABILITY.md). Preserve the existing host
behavior and supply a deterministic test double; this task does not need to
implement another OS adapter.

**First slice:** propose the interface and migrate one call site with unchanged
golden fixtures and a focused test.

### LaneWeave trace visualizer

Render admission, service, cancellation, and retirement events as a timeline.
The visualizer must consume verified events and label unverified input.

**First slice:** emit deterministic JSON suitable for a future UI.

### Portable workload campaign foundation

Define the first bounded, versioned model-free workload scenario for mixed
runtime families. Keep open-loop arrival rate separate from closed-loop
concurrency, use explicit logical ticks and seeds, and record completed,
rejected, cancelled, and timed-out work without reading an ambient clock.

**First slice:** one deterministic pressure scenario plus an independent
summary oracle for queue delay, weighted fairness, resource high-water, and
zero orphaned ownership. Native timing, percentile, energy, and soak adapters
remain later slices described in the
[AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md#workload-stress-and-soak-campaigns).

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

**Completed slice:** bounded generated-audio state, plan, provenance, result,
observation, and acknowledgement records now publish exact raw PCM behind a
single-outstanding-buffer gate. A fresh process verifies the pending chunk,
rejects partial acknowledgement without changing state, acknowledges it,
cancels one private successor candidate, publishes the next chunk, rejects
duplicate acknowledgement, and releases ownership to zero. See
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md).

**Completed slice:** bounded generated-video state, ordered two-frame manifest,
provenance, result, observation, and acknowledgement records now publish exact
raw frame roots and durations behind a single-outstanding-segment gate. A fresh
process validates retained frames before admission, rejects partial display
without changing state, acknowledges the segment, cancels one private
successor, publishes the next manifest, rejects duplicate acknowledgement, and
releases ownership to zero. See
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md).

**Completed slice:** fixed generated-media member, checkpoint, and selector
records now compose one typed image completion, one acknowledged PCM chunk, and
one acknowledged raw-video segment. Exact totals, modality continuity,
scope/policy/challenge, result/output/state/completion roots, and predecessor
lineage reject mixed or replayed generations. Zig/Python share golden roots,
and four real process-death boundaries recover only the complete previous or
successor set. See
[Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md).

**Completed slice:** one canonical eight-object archive now binds a fixed
payload manifest, the generated-media checkpoint, its three typed members, and
three exact encoded payloads. Raw source outputs, encoded bytes,
encoder-implementation roots, format roots, scope, policy, challenge, archive
parent, and manifest predecessor remain explicit. Zig and an independent
Python oracle share golden roots; seven real process-death phases select only
the complete previous generation five times or successor twice through one
outer selector, then converge idempotently. See the
[Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md).

**Completed slice:** an independent generated-media output-registry ABI now
packs one to four output entries per present modality, at most twelve, as
canonical fixed entries plus exact encoded payloads. The retained generations
advance from `2/3/2` to `2/2/3` image/audio/video outputs in exactly three
extension objects under the existing selector. Image entries structurally
require no completion receipt; audio/video require a completed flag and nonzero
opaque completion root. Exact ordinal, unit, timeline, and predecessor
continuity plus bound opaque state, completion, encoder, format, and payload
roots reject mixed-lineage and stale-root substitutions. A fully rehashed
alternative has a new archive identity and still requires typed producer
authorization. See the
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md).

**Completed slice:** a canonical pre-publication gateway now decodes the
existing generated-image plan/provenance/result records, generated-audio
quiescent state/plan/provenance/result/playback acknowledgement, and
generated-video quiescent state/manifest/provenance/result/display
acknowledgement. It verifies exact raw pixels, PCM, or frame bytes; derives the
common request envelope, zero-based registry positions, registry
generation/sequence, and strict state/result/completion predecessors; and
constructs the unchanged three-object registry. The independent Python model
checks the same mapping. See
[Canonical Generated-Media Producer Admission](GENERATED_MEDIA_PRODUCER_ADMISSION.md).

**Completed slice:** a higher-assurance generated-media transition gateway now
replays exact deterministic source-model and materializer callbacks for the
retained image/audio/video reference profiles. It reconstructs one-shot image
publication with a separately derived collection ordinal, complete audio/video
observation and acknowledgement transitions, and the exact unchanged registry
archive. Fixed per-output receipts are emitted in a separate batch sidecar
paired with that archive and its predecessor. This is verifier-host
reconstruction, not historical execution, live authority, physical sink,
external-format, or performance evidence. See
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md).

**Completed capacity slice:** two frozen generations now each fill the
twelve-output ceiling with four image, four audio, and four video records.
Native Zig generation and an independent Python oracle share exact registry and
transition roots; the Python-composed canonical PNG/WAVE/APNG sidecars are then
validated by the real Zig inspector at the 21,376-byte transition and
14,400-byte format limits. The campaign covers repeated-modality and successor
lineage plus failure-atomic thirteenth-output, fifth-entry-per-modality,
missing-parent, and mutated-sidecar rejection. It is deterministic pressure
conformance, not native load, latency, or soak evidence.

**Next slices:** add external container timestamp normalization, a production
image decoder adapter, richer language/punctuation or overlapping-speaker
policy, a production image/audio/video encoder or container adapter with an
external-format fixture, an additional deterministic model/materializer replay
profile, crash-atomic paired sidecar/registry retention, a native Linux
checkpoint campaign, a separately scoped initial power-loss durability design,
a verified registry inspector, or authorized device/quality evidence.
Model-family contracts, backend placement, streaming/batching, observability,
and runtime policy are parallel contributor lanes rather than dependencies on
media-format work. Each slice must preserve the fixed core contracts.

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
tests. All three use the shared family-neutral stateless lifecycle and can
adopt one scheduler-owned receipt, preflight their exact result, publish only
through the final V2 service commit, then cancel or retire with atomic release.

**Completed slice:** a family-neutral stateful lifecycle now pins model/state
publication roots and commits replacement state with its typed result. Its
canonical intermediate checkpoint restores under a fresh `ResourceBank` in a
distinct process, chains a terminal plan without duplicate publication, and
releases all ownership. See
[Stateful Model Adapter and Latent-Step Fixture](STATEFUL_MODEL_ADAPTER.md) and
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md).

**Next slice:** add a generic non-media encoder using the converged stateless
lifecycle, adapt a production renderer/codec to the bounded generated-audio
transaction and output registry, add a redistributable deterministic
producer-transition profile, or build a read-only paired evidence/registry
inspector that labels unverified bytes before rendering entries.

### Portable workload-pressure campaign

**Completed foundation:** one bounded explicit-open-loop scenario now drives
the real scheduler, resource bank, and scheduler verifier across fixed
image/audio/video profiles. Versioned scenario/result wires retain exact
capacity and resource rejection, `1:2:4` fairness, deadline completion, timeout,
cancellation, logical delay percentiles and high-water marks, and final
zero-orphan ownership. Zig exact replay and an independent Python scheduler and
accounting model agree on every record and frozen root. See
[Deterministic Workload Pressure](WORKLOAD_PRESSURE.md).

**Completed execution slice:** an additive sidecar now adopts each accepted
scheduler receipt into one bounded media session. The completed audio, video,
and image requests run their bounded retained fixture
decode-transform-publication
lifecycle only on the final service quantum; cancel, timeout, and rejection
produce no media execution. One armed finalizer joins scheduler service and
media publication, five accepted receipts close exactly once, and independent
Zig/Python verification agrees on the 5,472-byte evidence wire. See
[Scheduled Media Pressure](SCHEDULED_MEDIA_PRESSURE.md).

This is deterministic conformance, not a throughput, wall-clock latency,
physical-memory, energy, or soak result.

Small independent follow-up slices include:

- generate bounded valid scenarios and minimize a failing seed;
- add one new media or non-media profile without weakening exact replay;
- specify a separately versioned closed-loop mode;
- build a read-only scenario/result inspector that exposes no authority;
- drive the completed scheduled vision/audio/temporal-video lifecycle through
  one mixed typed-adapter workload profile; or
- add one native platform observer with explicit present/missing/denied states.

**Done when:** the slice fixes all bounds and summary rules before execution,
retains malformed and semantic-substitution rejection, keeps logical and
physical metrics distinct, and adds an independent verification path.

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
