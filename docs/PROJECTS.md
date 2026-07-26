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

**Done when:** present, missing, denied, unsupported, and malformed inputs have
tests; every record names stable source identity, per-sample provenance, unit,
subject, and sample-clock identity, while only a present time-valued metric
names a value-clock identity. Unavailable records retain a nonzero reason
identity and bounded readable diagnostic; present records retain neither.

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

### Add one contract-binding failure example

Use the experimental C contract ABI from a language with a built-in or
dependency-free C foreign-function interface. Start with the retained tiny
fixtures, substitute one individually valid foreign wire, and show that the
call returns `BINDING_MISMATCH` with a zero output root.

**Done when:** the valid chain passes, the foreign chain fails closed, no model
or package download is required, and the example links from
[Language interop](LANGUAGE_INTEROP.md).

## Intermediate projects

### Provider evidence viewer

Create a human-readable renderer for the compact evidence join and its nested
roots. Keep verification separate from presentation.

**First slice delivered:** the read-only
[Provider Evidence Inspector](PROVIDER_EVIDENCE_INSPECTOR.md) checks only the
fixed outer framing and checksum, then renders the sequence, lengths, event
counts, and named digests as self-asserted JSON. It exposes no raw prompt,
payload, response, or credential bytes and makes no nested-composition,
authenticity, usage, cost, or authority claim.

**Next slice:** accept every required nested journal, gateway, transport, and
cost artifact explicitly, run the full composition verifier, and preserve the
same deterministic, raw-payload-free presentation boundary.

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

### Device capability and deterministic selection

The first Stage-5 slice is complete. Portable pointer-free
`DeviceCapabilityV1`, inventory-entry, requirement, and selection-receipt
values bind stable backend/device facts, canonical tested
operation/type/numerical profiles with derived aggregate bits, lifecycle
policy, declared physical ceilings, the exact Common
Model Contract execution-plan root, discovery epoch, and explicit fallback.
Selection validates the complete inventory, canonicalizes discovery order,
rejects duplicate or non-present entries, and chooses deterministically by
policy rank then capability root before any resource or scheduler mutation.

The native macOS Metal adapter now projects stable device information into the
common contract, binds one bounded local discovery epoch, and revalidates the
selected fingerprint and registry identity from a fresh query before the first
Metal resource acquisition and again through post-run evidence. The
corrected tiled FP16 matmul path also matches
the CPU oracle for asymmetric partial-edge cases, keeps all edge threads
through required barriers, and rejects malformed exact buffer geometry without
caller-output mutation. These are bounded correctness and binding claims, not
performance or device-range claims. See
[Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md).

Small next slices:

- add a receipt-bound fake allocation lease with exact physical-byte ceilings
  and cancellation-safe release;
- add explicit device-loss, quarantine, and stale-selection rejection before a
  fresh selection receipt;
- add deterministic two-device partition planning without live multi-GPU
  execution;
- bind one stateless native candidate transaction to a selection receipt while
  keeping publication atomic; or
- add a new native backend capability projection only with CPU-oracle and
  lifecycle evidence on the named device.

**Done when:** the new slice keeps stable capability facts separate from dynamic
observations, consumes or replaces a selection receipt explicitly, rejects
unknown ceilings and undeclared fallback, and preserves zero resource/scheduler
mutation on selection failure. Physical allocation/residency, device-loss
recovery, multi-GPU scheduling, telemetry, performance, retained device ranges,
and native support remain unimplemented unless the slice supplies direct named
evidence for that exact claim. Cross-compilation never counts as native
support.

### Native observation adapters

The W5a foundation is complete: fixed portable descriptor, rule, plan,
observation, and bundle values; all four availability states; separate
host/accelerator planes plus sample-clock and time-metric value-clock
identities; stable source identity distinct from event provenance; nonzero
reason identity only when unavailable; a fail-closed family-neutral runner;
retained post-run contamination; explicit fallback; and a download-free
three-profile/six-item reference. The bounded macOS observer and paired harness
share strict system-field and external-process CPU parsers. See
[Native Observation Contract](NATIVE_OBSERVATION.md).

The first platform follow-up is also implemented: the JSON observer now has a
platform-neutral registry/validator and injectable dispatcher, and the Linux
adapter strictly parses one bounded `/proc/meminfo` `MemAvailable` source.
Cross-host fixtures cover parser and availability behavior; native Linux
retention remains open.

The native macOS Metal readiness follow-up is implemented as a hard diagnostic
gate. It makes exactly one real GPU dispatch in total for a fixed synthetic
37x64 INT4 matrix-vector operation, checks the output against the CPU oracle,
and binds command-buffer timestamps, `currentAllocatedSize`, registry-based
device/placement identity, ownership, fallback, composed evidence roots, and
revalidation of the selected portable capability fingerprint and discovery
epoch. Separately, asymmetric partial-edge FP16 tiled matmul shapes match their
CPU oracle and malformed exact lengths reject without caller-output mutation.
It retains `recommendedMaxWorkingSetSize` only as capacity context and leaves
utilization, committed/resident bytes, queue depth, temperature, frequency,
power, and energy unsupported. The repository does not yet retain an
addressable native result, so W5b remains open.

Small next slices:

- retain the mandatory available-memory smoke on a native Linux host;
- add one Windows or FreeBSD host adapter without adding OS calls to the
  portable contract;
- add one trustworthy direct CPU power, thermal, frequency, or energy source,
  retaining signed temperature down to absolute zero;
- retain one native Metal readiness artifact for a named device and host under
  the evidence policy; or
- add one direct accelerator utilization or residency source without deriving
  it from logical accounting.

**Done when:** present, missing, denied, unsupported, malformed, permission,
overflow, source-substitution, sample-clock, and time-metric value-clock cases
are retained; stable source identity is tested separately from per-event
provenance; nonzero unavailable-reason identity, absent present-reason identity,
and bounded readable unavailable diagnostics are covered; logical CPU count
zero and temperature below absolute zero reject; the two clock fields are not
treated as calibration; the acceptance command runs
natively on the named platform; and cross-compilation is reported only as
source/build evidence.

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

**Completed R0 slice:** eight append-only exact-integer reference profiles now
derive directly from retained adapter support constants. A deterministic
read-only JSON inspector, fixed-width C enumeration/query surface,
standard-library Python and dependency-free Rust consumers, and focused
mask/rejection tests expose the matrix without probing a host or granting
execution authority. See
[Runtime Support Registry and Inspector](RUNTIME_SUPPORT_INSPECTOR.md).

**Next slice:** append one tiny, legally redistributable profile by following
the fixture-authoring guide, including maximum-bound and first-rejected-value
tests. Do not reorder an existing index or describe registration as production,
platform, backend, quality, or performance support.

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

**Completed generated-corpus slice:** four retained seeds expand into eight
scenario classes each through coordinate-addressed SHA-256 decisions. All 32 bounded
open-loop scenarios run through unchanged W0 replay and W1 media execution;
Zig and an independent Python implementation agree on the retained case
identities. One explicitly synthetic exact-signature fixture reaches the same
local minimum in both implementations without changing any W0/W1 reference
wire or golden. See
[Generated Workload Corpus](GENERATED_WORKLOAD_CORPUS.md).

**Completed deterministic closed-loop slice:** one separately versioned,
finite-source controller drives repeated admissions and terminal turnover
toward a declared logical in-flight target. The exact
`admit_due → apply_actions → service_retire → seal_step` order makes every
rejection, cancellation, timeout, and completion eligible for at most one FIFO
successor on the next logical step. Canonical plan/result wires bind lineage,
phase-aware trace, target and credit high-water marks, finite-budget drain, and
zero ownership. Zig and an independent direct Python replay agree without
converting the plan into a precomputed open-loop schedule. See
[Deterministic Closed-Loop Workload](DETERMINISTIC_CLOSED_LOOP.md).

**Completed typed-workload slice:** one separate W4a plan and family-neutral
lifecycle driver now compose the retained exact-integer vision, audio-window,
and temporal-video adapters. Accepted work adopts the scheduler receipt;
rejected work receives no adapter/cache authority; only final service may
publish a typed result; cancellation, timeout, failure, and retirement close
all model/cache ownership. Native mutation tests validate the concrete
evidence while an independent Python implementation derives the plan wire and
logical replay; one retained report binds both sets of roots. See
[Typed Workload Conformance](TYPED_WORKLOAD_CONFORMANCE.md).

**Completed W4b-a tool slice:** one separately versioned process-local tool
profile now separates proposal from local policy, commits a bounded counter
effect and delivery receipt with the exact armed scheduler service event,
reuses an exact duplicate without a second mutation, denies out-of-policy work,
rejects an idempotency conflict, and gives cancelled, timed-out, and rejected
work no effect authority. Native mutation tests and an independent Python
implementation retain the eight-item campaign and final zero state without
changing W4a. See [Typed Tool Workload](TYPED_TOOL_WORKLOAD.md).

**Completed W4b-b record slice:** a separate ActionOutbox journal now retains
the allowed action, payload identity, and stable remote-request identity. A
committed intent remains uncertain after restart, and only the
`reconciled_not_applied` semantic record permits retry; authenticating that
classification belongs to a future adapter. Compensation is a newly
authorized child action. Native and independent Python replay cover all 7,521
retained cuts from the complete header through the journal.

**Completed W4b-c durable-store slice:** the clean committed `320 + 752n`
stream now
has a descriptor-relative POSIX adapter with an exclusive advisory lock,
no-follow/device+inode/one-link/private-mode/replacement fences, semantic
preflight, ordered body/footer sync, exact content-snapshot/lease/repair roots,
and explicit repair followed by mandatory fresh reacquisition. Zig/Python
matrices cover `40 + 754 + 751 + 8` append/section-prefix/repair cases, and 49
real host
process deaths cover initialization, append, and repair. It is not a live
dispatcher, provider-truth proof, external exactly-once mechanism, power-loss
test, or Windows durable-file implementation. See
[ActionOutbox Protocol](ACTION_OUTBOX.md).

**Completed W4b-d fenced-adapter slice:** pointer-free request/evidence values,
a driver that commits intent before callback, and a bounded same-process fake
authority now enforce atomic generation fencing, stale rejection before and
after terminal completion, and retry only at exact `G + 1`. Deterministic
same-process faults cover four terminal-transition plus four fenced-transition
append phases with fresh reopen/repair/reconciliation. The independent Python
model has no retained JSON fixture; the gate separately validates a live
canonical Zig report. This is not live dispatch, real credential handling,
OS isolation, service-restart persistence, or external exactly-once evidence.

**Completed W5a native-observation slice:** fixed pointer-free observation
values and a family-neutral runner now gate probe and pre-run state before
starting the workload, invoke work at most once, retain post-run contamination,
and keep host/accelerator metrics, sample-clock and time-metric value-clock
identities, stable source and event provenance, unavailable reasons, fallback,
correctness, and zero-orphan evidence explicit. The canonical
three-profile/six-item
reference needs no model download and is checked independently. A shared
bounded macOS host observer supplies the first native adapter seam. W5 remains
open for direct physical CPU/device adapters. A platform-neutral JSON seam and
strict bounded Linux available-memory source are implemented, but native Linux
retention and W8 native multi-platform replication remain open.

**Completed native Metal readiness implementation:** the macOS-only hard gate
executes one fixed 37x64 INT4 matrix-vector command exactly once across the
gate, checks CPU-oracle correctness, command-buffer completion and GPU
timestamps, registry identity, allocation context, zero leaked ownership, no
fallback, evidence composition, local discovery-epoch binding, and selected
capability/registry revalidation. The separate corrected tiled FP16 matmul
tests cover asymmetric
partial-edge shapes against a CPU oracle and fail before output mutation on
invalid geometry. These are diagnostic/correctness claims, not throughput,
latency, or performance claims. The independent readiness verifier detects
composition errors and corruption in self-asserted live output; it does not
authenticate origin. No native Metal JSON result or device support range is
retained in the repository, so W5b and repeated native coverage remain open.

These are deterministic conformance and named-host recovery fixtures, not
throughput, wall-clock latency, physical-memory, energy, or soak results.

Small independent follow-up slices include:

- add one retained seed, exact failure signature, or independent
  generator/shrinker check while preserving every prior case root;
- add one retained W3 plan, phase/lineage mutation, or independent decoder
  while preserving every existing V1 root;
- add one provider, stateful, streaming, OS-isolated live-tool, or
  non-media W4 profile without
  weakening authoritative replay or receipt ownership;
- build a read-only scenario/result inspector that exposes no authority;
- add a bounded family-aware batch or safe-preemption profile with an explicit
  execution unit and cancellation boundary; or
- retain the Linux available-memory adapter on a native Linux host, add one
  Windows or FreeBSD observer, retain a named-device Metal readiness result, or
  add one direct CPU/device metric behind W5a with all four availability states.

**Done when:** the slice fixes all bounds and summary rules before execution,
retains malformed and semantic-substitution rejection, keeps logical and
physical metrics distinct, preserves earlier roots unless it introduces a new
ABI, and adds an independent verification path.

### ResourceBank property tests

Generate bounded sequences of admit, subdivide, publish, retire, cancel, and
release operations, then check exact zero-state recovery.

**First slice:** one deterministic seed and one minimized stale-handle failure.

### Prepared-session successor admission

The data-plane foundation is complete: a live non-terminal `SessionV3`
captures canonical output/RNG/contiguous-KV bytes, independent Zig/Python
verifiers reconstruct every state root, and a fresh detached allocation
round-trips with zero slack. See
[Prepared Text Checkpoint](PREPARED_TEXT_CHECKPOINT.md). The evidence-plane
bridge is also complete: the same boundary now derives canonical successor
plan, residency, transcript, and ownership-intent records. See
[Prepared Text Successor Evidence](PREPARED_TEXT_SUCCESSOR.md).

**Completed R1f slice:** `SessionV3.rebindCheckpointV1` privately decodes and
materializes the exact current checkpoint, rechecks the live boundary, then
replaces only concrete KV/output backing under the original authority.
Internal publication bindings remain valid before old backing is released;
previously borrowed external output/cache views are invalid after success.
Same-boundary repetition succeeds, while moved, active-row, recovery,
terminal, challenge-mismatched, and stale checkpoints reject without takeover.
The next-token transaction and terminal seal/retirement continue through the
unchanged live receipt, Scheduler, ResourceBank, epoch, sequence, and embedded
publication-coordinator address. The retained test carries one permit across
rebind, compares the complete next transition and numerical state with an
uninterrupted reference, and sweeps every candidate-allocation failure without
leak or live-state mutation.

**Completed R1g slice:** `SessionV3.captureSuccessorArtifactsV1` reuses the
fixed Common Model Contract execution-plan and residency wires, then adds a
512-byte transcript segment at the exact nonzero source sequence. The records
bind source checkpoint/boundary/transcript/state lineage, logical KV identity,
the next execution generation, and a canonical target ownership intent.
Capture rechecks the complete live context without mutating Session,
Scheduler, Bank, receipt, sequence, or state. Shared Zig/Python roots,
every-byte mutation rejection, length rejection, contextual substitutions, and
failure-atomic three-record encoding form the retained gate. The ownership
intent is evidence only, not a receipt or authority handoff.

**Completed R1h-a slice:** `prepareRestoredAdmissionV1` consumes those exact
records against a fresh, explicitly LeaseTree-enabled Scheduler/Bank. It
acquires the intended admission and receipt, retains the non-runnable
publication-adoption barrier, opens an allocation-empty queue-free
receipt-funded LeaseTree with one zero-current-claim tenant scope, restores
sequence `N`, and seeds the Bank publication generation at source `G`. The
process-local bootstrap root binds the artifact roots, target intent,
adoption, receipt, tree, scope, `N/G`, Scheduler/Bank/session addresses, and
canonical scheduling projection. Validation is read-only; abort closes session
then tree before cancelling the adoption. See
[Prepared Text Restore Admission](PREPARED_TEXT_RESTORE_ADMISSION.md).

**Completed R1h-b slice:** `SessionV3.startRestoredV1` reserves one funded
allocation covering the queue-free request-local claim before its first
allocator call, materializes exact checkpoint KV/output/RNG/sampling state, and
commits that allocation with the pending Scheduler adoption. Publication ABI
v2 carries `sequence_base = N`; the first target Bank permit is source `G + 1`.
The retained synthetic-model path uses an exact target hard limit, matches one
restored transition with uninterrupted output, logical KV, RNG, and sampling
state, then closes allocator backing, funded ownership, the tree, receipt, and
Scheduler lane to zero. Fresh-session publication remains base zero.

**Next slice:** compose the prepared checkpoint and successor records through a
durable selector, prove source exit and exclusive target ownership across a
process boundary, then compare uninterrupted and resumed terminal results.
Process-local activation is not evidence for those properties.

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

**Completed first slice:** one fixed-storage idempotent `bounded_add` tool now
retains exact descriptor, proposal, policy, authorization, effect, delivery,
scheduler, and replay roots with no ambient or real I/O. A scheduler-locked
precommit rejects participant drift before Event-v1 mutation and retains the
tool-state lock through its bounded, non-failing publish callback.

**Completed second slice:** the portable ActionOutbox record/recovery boundary
defines acknowledgement, ambiguity reconciliation, safe retry, payload
identity, and a separately authorized compensation child. That portable layer
by itself grants no file or dispatcher authority.

**Completed third slice:** a descriptor-relative POSIX store adds ordered
body-sync/footer-sync, advisory locking and namespace/identity fences,
snapshot-bound incomplete-tail repair, mandatory close/reopen reacquisition,
independent deterministic fault matrices, and 49 host process-death fixtures.

**Completed fourth slice:** W4b-d adds the credential-free pointer-free adapter
contract, durable-ordering driver, and bounded same-process fake dispatcher.
Its synthetic credential remains separated inside the opaque callback context;
authoritative generation-fenced status does not prove credential isolation.

**Next slice:** add one capability-scoped live dispatch/status adapter and an
OS-isolated credential boundary without changing the portable record,
durable-store, or same-process conformance proofs.

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
