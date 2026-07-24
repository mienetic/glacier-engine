# Glacier AI Runtime Roadmap

Glacier is evolving into a full AI runtime: one evidence-carrying execution
fabric for local, edge, accelerator, and provider-backed models. The runtime is
not defined by one model architecture. It is defined by the contracts every
model family must satisfy before it can consume resources, retain state, call an
external system, or publish output.

This document is an architecture and contribution roadmap, not a claim that all
listed families run today. Status follows the project-wide sequence:

`idea → prototype → integrated → validated → shipped`

Unsupported artifacts, operations, numerical modes, and capabilities must
reject explicitly. A generic adapter interface never turns an untested family
into supported functionality.

Operating-system support follows the same rule: canonical runtime contracts
stay portable while filesystem, virtual memory, process control, telemetry,
and accelerators enter through explicit capabilities. The current evidence and
promotion sequence live in [Platform Portability](PLATFORM_PORTABILITY.md).

## North star

One request should be able to move between a local CPU, an admitted accelerator,
an edge worker, and an explicitly authorized provider while retaining:

- exact artifact and preprocessing identity;
- bounded resource ownership and scheduling state;
- family-specific continuation state;
- transactional output visibility;
- usage, cost, provenance, and cancellation evidence; and
- a verifier that does not need model weights, private inputs, or credentials.

The same runtime should serve interactive generation, batch inference, feature
extraction, streaming media, generative media, agent actions, and scientific
model execution without flattening their different state or output semantics.

## Runtime shape

```text
artifact + request + authority
              │
              ▼
       family adapter
  inspect → plan → declare state/output
              │
              ▼
┌──────────────── shared Glacier runtime ────────────────┐
│ artifact identity │ admission │ schedule │ execution   │
│ state/continuation│ media     │ provider │ publication │
│ evidence          │ security  │ distribution           │
└────────────────────────────────────────────────────────┘
              │
              ▼
 CPU / accelerator / edge / provider backend
              │
              ▼
 candidate tensors, tokens, media chunks, actions, scores
              │
              ▼
 family validator + one atomic publication boundary
```

A backend performs computation. A model-family adapter explains the meaning of
its artifacts, state, operations, and outputs. The shared runtime decides
whether the work is admitted and whether its result may become visible.

## The shared runtime planes

### 1. Artifact and identity plane

Responsibilities:

- content-addressed weights, tokenizer, processor, vocabulary, adapters, and
  auxiliary assets;
- immutable model-family, architecture, tensor-layout, quantization, and
  numerical-policy identity;
- source-to-prepared-artifact lineage;
- bounded parsing before allocation or device upload;
- provenance, license metadata, tenant scope, and compatibility declarations.

Current state: **prototype**. Glacier validates source and prepared `.glrt`
layouts for the current text-generation path and has typed continuation roots.
A universal `ArtifactManifest`, adapter/processor composition, and generated
compatibility registry remain planned.

Promotion gate: each advertised artifact combination has a redistributable
fixture, exact bounds, independent parsing evidence, and a named rejection for
unknown architecture, tensor, processor, or numerical mode.

### 2. Planning and execution plane

Responsibilities:

- sealed `ModelExecutionPlan` values derived before execution;
- explicit operation, input/output schema, bounds, scratch, numerical mode,
  backend requirements, and fallback policy;
- prefill, decode, encode, score, classify, retrieve, detect, segment,
  transcribe, synthesize, diffuse, and step operations;
- prepared kernel/tensor layouts and backend-neutral candidate results;
- no silent architecture, precision, device, or preprocessing fallback.

Current state: **prototype**. `DecodePlan`, CPU/optional Metal paths, INT4
experiments, sealed media decode plans, and deterministic media transform plans
exist. The common model-operation ABI and backend capability negotiation do not.

Promotion gate: the plan fully predicts memory and output ceilings, the backend
confirms exact capability identity, and unsupported combinations fail before
visible state or output changes.

### 3. Resource plane

Responsibilities:

- exact logical claims for weights, activations, KV, latent state, media
  buffers, scratch, output, device residency, network attempts, and tool calls;
- hierarchical `ResourceBank` and `LeaseTree` ownership;
- memory tiering, weight paging, cache admission, pinning, and retirement;
- per-tenant ceilings and cancellation-safe release;
- physical telemetry recorded separately from logical accounting.

Current state: **integrated for logical ownership**, **prototype for physical
residency**. Exact claims and hierarchical leases are used by current runtime
state paths. The model-free media vertical now derives and reserves exact
activation, output, staging, I/O, and queue claims before execution. Decoded
source, mapping, optional scratch, and output regions now receive distinct
`LeaseTree` allocations; provisional regions retire early after commit and all
paths return ownership to zero. The scheduled-media path additionally adopts
the exact admission receipt instead of reserving again, then performs one
failure-atomic bound close and release. Production weight paging and complete
device/network accounting remain planned.

Promotion gate: every retained allocation is owned, every rejection and
cancellation returns the declared delta, and measured physical counters are
never inferred from logical claims.

### 4. Scheduling plane

Responsibilities:

- admission, priority, weighted fairness, deadlines, batching, and backpressure;
- prefill/decode, encoder batch, diffusion-step, frame/audio-window, and tool
  action scheduling;
- safe preemption points declared by each family adapter;
- cancellation propagation through local, device, provider, and tool backends;
- replayable scheduling decisions without relying on wall-clock ordering.

Current state: **integrated control-plane prototype**. `LaneWeave` supplies
deterministic weighted service and cancellation. The first versioned
explicit-open-loop pressure fixture now composes real `LaneWeave`,
`ResourceBank`, and verifier state across image/audio/video profiles and retains
exact capacity/resource rejection, fairness, timeout, cancellation, delay,
high-water, and zero-orphan evidence. An additive sidecar now executes the
completed audio, video, and image media transactions on their final service
quanta and binds exact outputs/publication receipts without changing the
workload wires. The shared stateless lifecycle now also lets the retained
vision, audio-window, and temporal-video adapters adopt that scheduler receipt,
preflight their typed result, publish through the final V2 service commit, and
retire atomically without a second admission. A mixed typed-adapter workload
profile, family-aware batch formation, preemption, multi-device placement,
generated workloads, and closed-loop mode remain planned.

Promotion gate: retained mixed-family pressure campaigns meet declared
fairness, deadline, logical-resource, cancellation, and zero-orphan invariants;
native campaigns separately validate physical memory and timing.

### 5. State and continuation plane

Responsibilities:

- autoregressive KV, recurrent state, encoder caches, embeddings, retrieval
  cursors, diffusion latents, scheduler steps, media timelines, temporal caches,
  audio windows, generated chunks, and tool/action history;
- typed state roots rather than one universal opaque blob;
- checkpoint lineage, fresh-generation ownership reacquisition, and
  family-specific restore validation;
- process restart, host migration, and eventually device-failure policies;
- exact resumed publication position.

Current state: **integrated model-free continuation plus typed stateful-model
prototype**. Glacier has capsules, bounded object resolution/storage/lifecycle,
paged-KV remap, sampler/output restore, two-process next-token publication,
atomic complete checkpoint selection, and a synthetic two-step latent chain
that restores its intermediate state in a distinct process. Production-model
state adapters remain pending.

Promotion gate: uninterrupted and resumed output satisfy one declared numerical
mode, no output is duplicated, foreign state rejects, and all reacquired
ownership returns to zero after release.

### 6. Media plane

Responsibilities:

- content and policy identity for image, audio, and video;
- sealed decode and deterministic transform plans;
- exact region, sample, frame, timeline, patch, feature, and output mappings;
- bounded streaming input and generated-media chunk publication;
- model-visible processor identity and cross-modal synchronization.

Current state: **integrated model-free runtime vertical**. Fixed media objects,
rational timelines, bounded RGB8/PCM s16le/intra-frame gray8 decode, and
deterministic image crop/nearest/tile, audio weighted mix/exact decimation, and
video keyframe selection now compose with exact `ResourceBank` admission,
per-buffer `LeaseTree` ownership, provisional caller-owned storage, candidate
revalidation, atomic media/resource publication, abort scrubbing, retry, early
provisional retirement, exact release, and fixed independently verified runtime
receipts. A bounded stream session now commits two retained chunks for each
modality, rejects target gaps/overlaps before admission, reclaims cancelled
chunks, and emits a portable predecessor-bound receipt chain. A fixed stream
checkpoint now carries retained-output ownership through a real source/target
process restart; the target charges a fresh Bank before materialization and
publishes the next chunk exactly once for all three retained modalities.
Three checkpoints plus one canonical retained-output bundle now publish as one
atomic archive root. Two lineage-bound generations resume as complete
previous/successor sets across all seven native process-death boundaries.
A restarted runtime now rebinds all retained outputs, appends one chunk for
each modality, publishes generation three, and supports another fresh-process
resume from that new root. A separate fixed 2,272-byte processor-state bundle
now advances image tile/patch progress, audio feature windows, video temporal
cache state, and an exact integer synchronized watermark through two verified
generations. The bundle is now the fifth checkpoint object, while a sixth
object carries exact cache payloads through fresh-Bank charge-before-visibility
restore. Typed transcript/video-segment fixtures now preserve source/cache
lineage, a deterministic video timeline preserves accumulated event bounds, and
an exact cross-modal result-link transaction maps only newly publishable audio
samples onto that tail. External codecs, capture, playback, and production
media models remain gated. The first generative output slice now decodes one
exact post-restart terminal latent and atomically publishes a bounded raw image,
provenance, typed result, resource receipt, and media transition. Generated
audio now adds ordered bounded PCM publication, one-buffer backpressure,
application acknowledgement, cancellation, and a distinct-process restart
proof. The model-free generated-video fixture now publishes an ordered
two-frame manifest with exact durations, one-segment backpressure, application
display acknowledgement, cancellation, and a distinct-process restart proof.
One fixed generated-media member ABI now normalizes those three output paths.
An 800-byte checkpoint binds exactly one completed image, one acknowledged PCM
chunk, and one acknowledged raw-video segment, while a 352-byte selector makes
only the complete previous or successor generation visible. Independent Python
verification and four native process-death boundaries reject mixed generation,
scope, policy, challenge, result, output, state, and completion substitution.
A canonical 864-byte payload manifest now joins that checkpoint, its three
members, and three exact encoded payloads into one eight-object immutable
archive. Raw-output, encoded-payload, encoder-implementation, format, scope,
policy, challenge, archive-parent, and manifest-predecessor identities remain
separate. One outer filesystem selector recovers the exact previous generation
after five publication-phase process deaths and the exact successor after two,
then converges idempotently. An independent Python oracle verifies the archive
without model execution. An independent bounded registry ABI now orders one to
four outputs per present modality, up to twelve, and binds exact
ordinal/unit/timeline/predecessor continuity, opaque state/completion roots, and
exact payload bytes in three extension objects under the same selector. Typed
producer admission now closes that precondition: a separate gateway decodes
the retained typed image, audio, and video record sets, verifies exact raw media
bytes, derives their common request envelope and strict state/result/completion
predecessors, and constructs the unchanged registry generation. A
higher-assurance producer-transition path now adds exact deterministic
source-model and
materializer replay for the retained reference profiles. It reconstructs
one-shot image publication and complete audio/video acknowledgement
transitions, then emits fixed per-output receipts in a separate sidecar bound
to the exact unchanged registry archive. Strict allocation-free delivery
modules now emit and accept bounded canonical PNG, PCM/WAVE, and APNG profiles.
  An integrated bounded format-evidence sidecar binds those payloads to their
  producer plan or manifest, registry entry, transition receipt, format contract,
  and predecessor format lineage without changing the existing V1 wires. The
  leaf profiles have native macOS test evidence and module-level
  Linux/Windows/FreeBSD cross-compilation. Real two-generation PNG, WAVE, and
  APNG fixtures pass through the registry, producer-transition, and format
  validators with exact successor, missing/foreign predecessor,
  semantic-drift, and failure-atomic output checks. Audio and video use the
  typed playback/display acknowledgement chains. An independent Python oracle
  validates all three binary layers and producer semantics, and the read-only
  inspector optionally validates the exact current/predecessor format pair
  before rendering a versioned no-payload JSON document. The composed format
  target cross-compiles for x86_64 Linux musl, Windows GNU, and FreeBSD.
  Production encoder/container adapters, broader profiles, native
  Linux/Windows execution, physical playback/display evidence, quality
  evidence, and power-loss durability remain gated.

Promotion gate: accepted model inputs and visible outputs map to exact source or
generation plans, with bounded geometry/time, cancellation, continuation, and
provenance.

### 7. Provider and edge plane

Responsibilities:

- exact rendered request bytes, attempts, retries, cancellation, terminal usage,
  pricing identity, settlement, and durable cost evidence;
- local preprocessing and cache decisions with lossless logical mappings;
- provider capability and model identity negotiation;
- privacy policy, secret isolation, regional routing, and data-retention scope;
- edge/offline queue, synchronization, and conflict policy.

Current state: **integrated credential-free control-plane prototype**. Context
packing, gateway state, transport harness, settlement, cost journal, and compact
evidence join exist. Live adapters remain outside the authority-free core.

Promotion gate: credentials and private payloads never enter core evidence;
ambiguous attempts never double-settle; provider-reported usage attaches to the
exact terminal attempt; and no local byte count is presented as billed usage.

### 8. Publication plane

Responsibilities:

- atomic visibility for tokens, tensors, scores, labels, boxes, masks,
  embeddings, retrieval results, transcripts, video segments, media chunks,
  and actions;
- provisional output separated from visible output;
- sequence, lineage, ownership, scheduler permit, and evidence roots committed
  together;
- idempotent retry and replay rejection;
- streaming acknowledgement and partial-result policy.

Current state: **integrated for tokens, model-free media, bounded typed
perception fixtures, generated-image publication, generated audio/video
publication with application acknowledgement, and atomic three-modality
generated-output selection plus exact encoded-payload archive composition and
bounded multi-output registry continuity with canonical producer admission and
host-verified reference producer-transition replay**.
Media transactions compose
exact resource admission, transformed output, timeline advancement,
transcript/video-segment visibility, deterministic merge decisions, cross-modal
result links, terminal-latent image/provenance visibility, and ordered PCM
and raw-frame visibility behind explicit commit boundaries; abort scrubs
provisional bytes and leaves publication state unchanged. Audio and video paths
accept only complete sink-bound application observations before their
successors. One fixed checkpoint then cross-binds the image, audio, and video
results, outputs, post-publication states, completions, totals, and predecessor
behind one atomic selector. A downstream eight-object archive now binds that
typed generation to three exact encoded payloads behind one outer filesystem
selector. An independent registry ABI extends the retained shape to one through
four output entries per present modality, no more than twelve, using ordered
fixed entries and exact concatenated payload bytes in three archive objects
under the same selector. Registry completion/state roots remain opaque; typed
producer acknowledgement/state validation now occurs in the separate
pre-publication gateway, which also checks exact raw bytes and derives rather
than trusts the common envelope, registry generation/sequence, and
predecessors. A higher-assurance sibling replays the exact deterministic
source-model and materializer callbacks, reconstructs image or complete
audio/video completion transitions, and binds fixed receipts in a separate
  evidence sidecar to that unchanged registry. An integrated bounded additive
  format sidecar binds strict canonical PNG/WAVE/APNG payloads to those receipts
  and typed producer semantics across real two-generation fixtures without
  rewriting the registry or transition wire. Generic tensor/action envelopes,
  partial-stream policy, production
encoder/container adapters, broader format profiles, additional replay
profiles, native platform execution, and physical playback/display evidence
remain planned.

This replay proves deterministic reconstruction on the verifying host. It does
not prove historical execution, live resource authority, physical sink
behavior, external codec/container correctness, or performance.

Promotion gate: every output family has a named atomic unit, rollback behavior,
replay rule, and continuation position; cancellation cannot expose an
unaccounted partial result.

### 9. Evidence and observability plane

Responsibilities:

- portable wires, canonical roots, event chains, independent verifiers, and
  mutation-complete fixtures;
- versioned workload scenarios with fixed seeds, arrival schedules, family
  mixes, concurrency, duration, warmup, and resource ceilings;
- latency, throughput, memory, energy, utilization, quality, and cost reported
  under a captured machine/provider envelope;
- trace correlation without storing raw private inputs in core records;
- human-readable inspectors that never turn unverified bytes into authority;
- claim boundaries generated beside benchmark results.

Current state: **integrated evidence building blocks**, **prototype inspection
and workload tooling**. The experimental generated-media inspector validates a
registry archive plus its producer-transition evidence, requires the exact
predecessor pair for successors, and can optionally validate
current/predecessor format sidecars through the composed oracle. The first
portable workload-pressure contract drives a bounded mixed-media
explicit-open-loop scenario through the real scheduler and resource bank, with
exact Zig replay and an independent Python oracle. Its additive scheduled-media
sidecar executes the three completed image/audio/video transactions under the
same admission receipts and binds exact publication evidence. Both surfaces
emit deterministic versioned evidence only after validation and grant no
payload, filesystem-write, device, or live resource authority.

Promotion gate: every promoted claim names the workload, platform, numerical
mode, baseline conditions, verifier, retained artifacts, and nonclaims.

#### Workload, stress, and soak campaigns

Load evidence is a required runtime feature, not a single marketing number.
The complete W0–W8 sequence and report contract are defined in the
[Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md). The track has three
deliberately separate evidence levels:

1. **Deterministic pressure — first slice implemented.** V1 replays one bounded
   model-free explicit arrival schedule to verify admission, weighted fairness,
   deadline completion, timeout, cancellation, overload rejection, exact
   logical accounting, and zero orphaned ownership. Its canonical
   scenario/result wires, nearest-rank logical-step summaries, exact replay,
   and independent Python verifier are documented in
   [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md). A separate sidecar
   now proves final-quantum image/audio/video fixture execution, atomic
   publication, single-receipt ownership, and terminal absence for rejected,
   cancelled, and timed-out work. Generated scenarios, batching, typed
   model-adapter execution, real backpressure, and a separate closed-loop mode
   remain planned.
2. **Native workload** runs declared model-family mixes against a real CPU,
   accelerator, or provider adapter and records completed/rejected/cancelled
   work, throughput, p50/p95/p99 latency, queue delay, memory high-water,
   CPU and device utilization, host/device memory separately, accelerator
   submit/device/synchronization timing, fallback status, power/thermal/energy
   when available, and output-quality policy.
3. **Soak and disruption** runs a bounded long-duration campaign with a fixed
   fault schedule for process restart, adapter loss, storage pressure, and
   cancellation storms, then proves recovery, bounded growth, and zero leaked
   ownership.

Native open-loop arrival-rate campaigns and closed-loop concurrency campaigns
must remain distinct from each other and from deterministic logical-step
conformance. Native results retain exact scenario identity, warmup and
measurement windows, machine/OS/backend/power/thermal envelopes, raw
observations, summary algorithm identity, and independent validation.
Cross-compilation alone never counts as native load evidence, and a campaign on
one OS or device never promotes another.

### 10. Capability, extension, and distribution plane

Responsibilities:

- least-authority tokenizer, processor, storage, backend, provider, and tool
  extensions;
- versioned negotiation, revocation, time/byte/operation ceilings, and failure
  semantics;
- stable library and service APIs, CLI, packaging, deployment, and upgrade
  policy;
- single-host, multi-process, edge, and distributed worker identities;
- authenticated control plane separated from pure runtime verification.

Current state: **idea to prototype**, depending on component. Core contracts
already use scoped grants, but a public extension ABI, worker protocol, stable
SDK, installer, and compatibility policy do not yet exist. A first
core-only, experimental C ABI can now verify one complete Model Contract V1
artifact-plan-result chain from C, Python, or Rust without exposing runtime
struct layouts; it is a compatibility seed, not the stable SDK.

Promotion gate: an extension receives only declared operations and bounds;
revocation and process failure preserve accounting; version mismatch fails
closed; and packaging reproduces the verified artifact.

## Universal adapter contracts

Every `ModelFamilyAdapter` is expected to implement five narrow contracts:

1. **Inspect** — parse bounded artifact metadata and return an immutable family
   identity without loading unbounded payloads.
2. **Plan** — convert a typed operation and input schema into one sealed
   `ModelExecutionPlan` with exact resource, state, output, numerical, and
   capability declarations.
3. **Prepare** — validate inputs and family state, then produce backend-ready
   views without granting publication authority.
4. **Validate candidate** — check shapes, ranges, ordering, finite/numerical
   policy, source mappings, and family-specific invariants.
5. **Publish or abort** — convert a verified candidate into one typed visible
   transaction or release all provisional ownership.

Optional `StateAdapter`, `MediaProcessorAdapter`, `ProviderAdapter`, and
`ToolAdapter` contracts add only their declared state or authority. They do not
expand the base adapter's capabilities.

## Model-family coverage map

| Family | Representative operations | Current state | First retained slice | Integration gate |
| --- | --- | --- | --- | --- |
| Autoregressive text/code/chat | prefill, next-token decode, score | Prototype runtime; token publication integrated | Small legal artifact through uninterrupted and resumed output | Declared numerical equivalence, exact KV ownership, no duplicate token |
| Encoders, embeddings, rerankers, classifiers | encode, pool, rank, classify | Typed plan/result plus vision, audio, and temporal-video embedding fixtures integrated | Add a non-media stateless encoder under the same wire | Deterministic batch mapping, stable normalization, typed vector/score publication |
| Vision understanding | encode image, OCR, detect, segment, VQA inputs | Exact-integer encoder fixture integrated; production model gated | Extend from typed embedding to a bounded detection fixture | Geometry/color identity, bounded tensors, boxes/masks mapped to source regions |
| Speech and audio understanding | ASR, translation, audio classification | Exact-integer feature-window encoder, typed transcript transaction, fresh-process stateful transcript continuation, and restartable exact word-timing/speaker publication integrated; production model gated | Add language/punctuation, overlapping-speaker policy, and crash-atomic checkpoint composition | No sample loss/duplication, exact streaming restart, annotation lineage, calibrated production quality |
| Speech and audio generation | TTS, codec/audio token generation | Bounded exact-integer PCM publication, cancellation-safe retry, one-buffer backpressure, application acknowledgement, distinct-process restart, shared generated-output checkpoint composition, multi-chunk registry continuity with exact encoded payloads, host-verified retained source-model/renderer replay with separate registry-bound evidence, a validated bounded PCM s16le WAVE profile, and a real two-generation registry-transition-format chain with independent oracle coverage; production model/device paths gated | Add a production renderer/codec adapter, broader profiles, and additional replay profiles | Quality evidence, production container conformance, explicit device authority, physical playback evidence |
| Video understanding | frame/segment encode, search, summarize | Exact-integer strided-frame encoder, explicit VFR windows, fresh-process stateful segment continuation, canonical merge timeline, and exact audio/transcript-video result-link continuation integrated; production model gated | Add external container timestamp normalization and production backend conformance | Stateful continuation, explicit discontinuity evidence, production quality evidence |
| Image generation | diffusion/flow step, decode latent, publish image | Exact retained-state continuation plus bounded terminal-latent decode, cancellation-safe atomic image/provenance/result publication, distinct-process proof, shared generated-output checkpoint composition, multi-image registry continuity with exact encoded payloads, host-verified retained source-model/decoder replay with independent one-shot image state and derived collection order, a validated bounded canonical PNG profile, a real two-generation registry-transition-format chain, and independent oracle coverage; production model gated | Add a production decoder/encoder adapter, broader profiles, and additional replay profiles | Multi-step continuation, general external-format conformance, and quality/performance evidence |
| Video generation | temporal latent steps, frame/segment publication | Ordered two-frame raw manifest publication, cancellation-safe retry, one-segment backpressure, application display acknowledgement, distinct-process restart, shared generated-output checkpoint composition, multi-segment registry continuity with exact encoded payloads, host-verified retained source-model/renderer plus complete acknowledgement replay, a validated bounded two-frame gray8 APNG profile, and a real two-generation registry-transition-format chain with independent oracle coverage; production model/device paths gated | Add production adapters, broader profiles, and additional replay profiles | Production model quality, general external-container conformance, explicit display authority |
| Audio/music generation | acoustic or token steps, waveform decode | Shared bounded exact-integer waveform-output transaction, multi-chunk registry continuity, and a retained deterministic producer-transition replay profile integrated; music models gated | Add a legal production artifact, additional replay profile, or production renderer/codec fixture | Timeline continuity, chunk lineage, rights/provenance policy, calibrated quality |
| Multimodal fusion | cross-attention, joint embedding, interleaved generation | Idea; shared identities exist | Image+text or audio+text synthetic fusion fixture | Each modality retains source/state identity through one output transaction |
| Tool-use and agent policy | choose action, arguments, observation, continue | Idea; scheduler/provider primitives exist | Fake tool with bounded schema and no ambient I/O | Separate action authorization, idempotency, result identity, cancellation |
| Retrieval and recommendation | embed, search, rerank, recommend | Idea | In-memory fixed corpus and exact top-k tie policy | Index/version identity, tenant filtering, deterministic tie/evidence policy |
| Time-series and tabular | forecast, classify, anomaly score | Idea | Tiny typed table/window fixture | Schema/time identity, missing-value policy, exact output horizon |
| Graph, geospatial, and scientific | message passing, field inference, simulation surrogate | Idea | Small bounded graph or grid fixture | Topology/coordinate/unit identity, resource bound, typed scientific output |
| Mixture and routed models | expert route, sparse execution, merge | Idea | Fake experts with deterministic router | Expert identity, route evidence, capacity/drop policy, state ownership |
| Adapters and fine-tunes | compose base + adapter, merge or dynamic apply | Idea | Tiny low-rank adapter fixture | Base/adapter/tokenizer identity, composition order, numerical policy |
| On-device small models | offline encode/generate/classify | Prototype platform pieces | One CPU-only packaged legal fixture | Reproducible package, memory/energy envelope, offline capability boundary |
| Provider-hosted models | any typed remote operation | Control plane integrated; live execution gated | Fake adapter matching exact request/usage wires | Credential isolation, terminal usage settlement, provider identity and policy |

This map is extensible. A new family joins by specifying typed artifacts,
operations, state, output, publication unit, authority, and promotion evidence;
it does not require changing the meaning of existing families.

## Delivery sequence

### R0 — Runtime vocabulary and registry

- define `ModelFamilyId`, `OperationId`, typed input/output kinds, numerical
  policies, capability vocabulary, and explicit unsupported results; complete
  as a fixed prototype with a bounded support-record query;
- specify `ArtifactManifest`, `ModelExecutionPlan`, and family adapter lifecycle;
  canonical artifact/plan/result wires and the first
  prepare/validate/publish lifecycle are complete;
- generate a compatibility matrix from retained tests;
- add a read-only runtime inspector and fixture authoring guide.

Exit gate: two structurally different family fixtures use the shared contracts
without family-specific fields leaking into the common wire.

Current progress: vision u8 patches, audio i16 feature windows, and strided
video u8 frames now share the artifact/plan/result records while retaining
distinct source mappings. Video additionally proves charged gather scratch,
keyframe/eviction lineage, and exact target-time mapping. A generated
compatibility matrix and read-only inspector remain before the exit gate is
complete.

### R1 — Text path becomes the first complete runtime vertical

- bind current loader, prepared image, resource, schedule, KV, sampler, token
  publication, checkpoint, and evidence paths behind the common plan;
- run uninterrupted/resumed production-fixture comparison;
- retain macOS and native Linux evidence;
- stabilize the smallest local library API.

Exit gate: one declared artifact and numerical mode completes plan → execute →
publish → checkpoint → fresh-process resume with exact ownership and output
evidence.

### R2 — Stateless tensor families

- add encoder/embedding/reranker/classifier operations; vision, audio, and
  temporal-video encode operations are retained, while generic encoder,
  reranker, and classifier fixtures remain;
- define typed tensor/vector/score result envelopes; the fixed integer
  embedding envelope is complete;
- add deterministic batch-item mapping and tie/normalization policy; exact
  batch mapping is complete for vision, audio, and selected video frames, while
  normalization and tie policies remain;
- integrate `ResourceBank`, `LaneWeave`, cancellation, and provider routing;
  scheduler receipt handoff, final-service typed publication, cancellation,
  and retirement are integrated for the retained bounded media runtime and
  vision/audio/temporal-video stateless adapters, while mixed-family workload
  profiles and provider routing remain.

Exit gate: text generation and one stateless encoder share the runtime planes
while retaining different state and publication semantics.

### R3 — Streaming perception

- bind bounded image/audio/video transforms to exact request admission and one
  atomic media publication transaction; complete for retained model-free
  fixtures, including scheduler-receipt adoption and atomic final-service
  publication in the pressure campaign;
- add `LeaseTree` ownership for decoded source, mappings, output, and scratch;
  complete for retained model-free fixtures;
- compose bounded image/audio/video chunks under one target timeline with
  cancellation-safe ownership and portable chain receipts; complete for two
  retained chunks per modality;
- bind stream state and retained output ownership into a fixed checkpoint,
  release the source process, reacquire in a fresh Bank, and append the exact
  next chunk; complete for retained image/audio/video fixtures under distinct
  source and target PIDs;
- publish media checkpoint/output objects through one crash-atomic archive and
  selector; complete for two source-side generations, three modalities, and
  every archive/selector process-death boundary;
- create the next checkpoint generation after resumed chunks while rebinding
  retained ownership and rejecting stale source authority; complete for a
  fresh-process generation-two to generation-three transition, six rebound
  outputs, three appended chunks, and a second fresh-process resume;
- integrate image processors and vision encoder fixtures; bounded tile/patch
  progress, materialized cache ownership, exact-integer encoder execution,
  candidate validation, and typed embedding publication are complete for the
  retained fixture;
- add audio feature windows, transcript transactions, and streaming restart;
  fixed window/hop/context state, a non-overlapping exact-integer feature
  encoder, canonical overlap ownership, and typed transcript publication are
  complete; a stateful transcript fixture now restores exact sample/model state
  under fresh charged ownership in a distinct process, publishes only the next
  range, and advances its cross-modal link without duplicated text; production
  speech models, language/punctuation policy, overlapping-speaker ambiguity,
  and atomic multi-file composition remain; exact word sample ranges and
  first-occurrence speaker turns now publish across a distinct-process state
  restart;
- add video temporal selection, synchronized timeline state, and cache
  ownership; fixed window/eviction state plus exact audio/video watermark is
  complete together with materialized cache ownership; a typed strided-frame
  encoder now binds keyframe lineage, eviction boundary, charged gather
  scratch, and exact target time; a fixed typed video segment now adds
  event/confidence fields, complete source/cache lineage, predecessor chaining,
  and transactional visibility; fixed timeline and decision wires now coalesce
  only touching/overlapping same-event results and retain gaps or different
  events; a fixed cross-modal transaction now maps only newly publishable
  transcript samples to the accumulated video tail, rejects non-integral or
  non-overlapping time, and binds both histories; a stateful video fixture now
  crosses a real process boundary with explicit per-frame PTS/duration,
  declared-gap evidence, timeline continuation, and result-link continuation;
  external container normalization and production quality remain;
- extend checkpoints with family-specific processor/cache state; the fixed
  independently verified state and payload bundles now advance as the fifth
  and sixth atomic archive objects through a fresh-process successor.

Exit gate: image, audio, and video input paths preserve exact source mappings,
stay within admitted memory/time bounds, and resume or cancel at declared units.

### R4 — Generative media and multimodal fusion

- add diffusion/flow scheduler and latent-state adapters; a canonical
  state-publication wire plus two exact latent steps now commit typed results
  and replacement state; the intermediate checkpoint restores under fresh
  ownership in a distinct process and reaches the terminal step without a
  duplicate result;
- publish a bounded generated image from the exact terminal latent; fixed plan,
  provenance, and result wires now bind artifact/checkpoint/terminal state,
  decoder, tenant, media, resources, and publication predecessors; abort/retry,
  candidate drift, atomic visibility, independent mutation verification, and a
  real distinct-process proof are complete;
- publish bounded generated audio under exact frame ordering and backpressure;
  fixed state/plan/provenance/result plus observation/acknowledgement wires now
  bind source output, PCM, media, renderer, resource receipt, sink identity, and
  both predecessor chains; cancellation, partial/duplicate rejection,
  independent mutation verification, and a real distinct-process proof are
  complete;
- publish bounded generated video under an ordered two-frame manifest; fixed
  state/manifest/provenance/result plus observation/acknowledgement wires now
  bind exact frame roots and durations, source output, media, renderer,
  resources, sink identity, and both predecessor chains; cancellation,
  partial/duplicate rejection, independent mutation verification, and a real
  distinct-process proof are complete;
- compose generated image, acknowledged audio, and acknowledged video behind
  one atomic selector; fixed member/checkpoint/selector wires now bind exact
  modality roots, totals, scope, policy, challenge, predecessor continuity, and
  completion evidence. An independent Python oracle and four-boundary
  process-death campaign prove exact previous-or-successor recovery without a
  mixed generation;
- bind the checkpoint, three members, and exact encoded image/audio/video bytes
  into one canonical eight-object archive; complete for two model-free
  generations with explicit raw-output, encoded-payload,
  encoder-implementation, and format identities, one outer filesystem
  selector, an independent Python oracle, and seven process-death phases
  selecting the previous generation five times and successor twice before
  idempotent convergence;
- extend that fixed archive through an independent bounded output-registry ABI;
  complete for one to four outputs per present modality, at most twelve,
  canonical `(modality, ordinal)` entries, exact concatenated encoded payloads,
  structural completion fields, opaque state/completion roots, exact
  unit/timeline/predecessor continuity, and two model-free `2/3/2` then `2/2/3`
  image/audio/video generations in exactly three archive objects under the
  existing selector;
- admit canonical typed producers before registry construction; complete for
  the retained image plan/provenance/result set, audio quiescent
  state/plan/provenance/result/playback-acknowledgement set, and video
  quiescent state/manifest/provenance/result/display-acknowledgement set plus
  exact raw output bytes. The gateway derives the common envelope, registry
  generation and publication sequence, and strict
  state/result/completion predecessors while leaving the selected three-object
  registry unchanged;
- reconstruct stronger producer execution transitions; complete for the
  retained deterministic source-model and materializer profiles. Image uses a
  fresh one-shot local publication and a separately derived registry collection
  ordinal; audio/video replay publication, observation, acknowledgement plan,
  acknowledgement result, and exact final state. Fixed receipts live in a
  separate predecessor-bound sidecar paired with the unchanged registry
  archive;
- emit and accept bounded canonical lossless delivery profiles; complete for
  PNG with bounded 8-bit gray/gray-alpha/RGB/RGBA, PCM s16le mono/stereo WAVE,
  and two-frame full-canvas gray8 APNG. Their additive conformance sidecar is
  integrated through real two-generation registry-transition-format fixtures
  for every profile. An experimental read-only inspector optionally validates
  and renders exact triple roots without payload or write authority;
- retain exact successor, missing/foreign predecessor, semantic-drift, and
  failure-atomic output checks for all three profiles; complete. An independent
  Python oracle decodes and binds the registry, transition, format sidecar, and
  canonical producer wires across both generations;
- add production image decoder/encoder and audio/video
  renderer/codec/container adapters, broader profiles, and additional replay
  profiles;
- add authorized physical playback/display and quality evidence;
- retain native Linux filesystem campaigns and design separately scoped initial
  publication and power-loss durability evidence;
- add cross-modal cache/state identity and fusion fixtures;
- extend checkpoint and provider evidence to generative media units.

Current gate progress: deterministic generated-image, generated-audio, and
generated-video fixtures survive cancellation and process restart without
duplicate visible output; audio and video additionally gate their successors
on exact application acknowledgement. Shared generated-output checkpoint
composition, exact encoded-payload archive composition, and bounded
multi-image/chunk/segment registry continuity are complete for two model-free
generations. Canonical typed producer admission now verifies the retained
record sets and exact raw outputs before constructing that registry.
Host-verified transition evidence now additionally replays the exact retained
source-model and materializer profiles and binds the resulting receipts to that
unchanged registry. Strict bounded PNG/WAVE/APNG leaf profiles and their
additive sidecar are integrated through real two-generation
registry-transition-format fixtures, exact producer-semantic binding, and an
independent composed oracle. The R4 production exit gate still requires
production encoder/container adapters, broader profiles and replay coverage,
native platform and power-loss evidence, and quality/performance evidence under
declared artifacts.

See
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md)
for the replay, image-ordinal, and transition-sidecar lineage, then
[Generated-Media External-Format Profiles and Evidence](GENERATED_MEDIA_EXTERNAL_FORMATS.md)
for profile, format-sidecar, inspector, portability, and nonclaim boundaries.

### R5 — Agents, retrieval, and specialized families

- add action proposal separate from action authorization;
- add idempotent fake-tool/result transactions;
- add retrieval/index identity and deterministic result publication;
- publish templates for time-series, graph, geospatial, and scientific adapters;
- validate routed experts and adapter composition.

Exit gate: third-party family and tool adapters run under declared capabilities
without direct access to unrelated tenant, runtime, storage, or network state.

### R6 — Distribution and stable operations

- authenticated multi-process/worker control plane;
- placement, model caching, backpressure, and drain/upgrade protocols;
- packaging, stable API/ABI policy, migration tooling, and support matrix;
- promote the experimental contract verifier only after retained
  symbol/layout, native consumer, packaging, and migration gates;
- retained long-running correctness, pressure, crash, energy, and cost campaigns.

Exit gate: a published support matrix, reproducible packages, compatibility
policy, rollback path, operational inspection, and retained multi-platform
evidence.

## Where the runtime helps

The runtime is intended for:

- local assistants and coding systems that need bounded memory and resumable
  generation;
- embedding, reranking, classification, and document pipelines that need exact
  batch and artifact identity;
- voice, image, and video applications that must retain source/time provenance;
- generative-media queues that need cancellation and no duplicate publication;
- gateways that route between local and external providers with explicit usage
  and cost;
- agent systems that separate model-proposed actions from real authority;
- edge/offline applications with constrained resources and later synchronization;
- research on kernels, paging, scheduling, continuation, and verifiable AI
  operations.

Local preprocessing, exact deduplication, compatible cached state, routing, and
lossless context packing may reduce work sent to an external provider. They do
not guarantee fewer provider tokens, media units, latency, or cost. Glacier must
record logical input, exact transmitted bytes, provider-reported usage, cache
decisions, attempts, and settlement separately.

## Contributor lanes

Contributors can work on the runtime without downloading a large model:

- one model-family registry entry and malformed fixture;
- one tiny artifact/parser branch;
- one operation schema or result envelope;
- one resource/state/publication state machine;
- one deterministic processor or transform;
- one fake backend/provider/tool adapter;
- one independent verifier or mutation campaign;
- one experimental C ABI consumer or golden failure case in another language;
- one platform capability probe;
- one deterministic workload scenario, summary oracle, or native campaign
  adapter;
- one read-only evidence inspector or validated renderer extension;
- one compatibility-matrix row backed by a retained command.

Every slice should state its accepted inputs, maximum resources, authority,
rejection paths, evidence command, and nonclaims. See
[Contributor Projects](PROJECTS.md) and [Evidence Policy](EVIDENCE_POLICY.md).
