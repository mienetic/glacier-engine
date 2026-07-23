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
paths return ownership to zero. Production weight paging and complete
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
deterministic weighted service and cancellation. Family-aware batch formation,
preemption, and multi-device placement remain planned.

Promotion gate: retained mixed-family pressure campaigns meet declared fairness,
deadline, memory, cancellation, and zero-orphan invariants.

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

Current state: **integrated model-free continuation prototype**. Glacier has
capsules, bounded object resolution/storage/lifecycle, paged-KV remap,
sampler/output restore, two-process next-token publication, and atomic complete
checkpoint selection. Production-model and non-token state adapters are pending.

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
Post-restore successor checkpoint creation, external codecs, capture, playback,
media models, and generated-media publication remain gated.

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
  embeddings, retrieval results, transcripts, media chunks, and actions;
- provisional output separated from visible output;
- sequence, lineage, ownership, scheduler permit, and evidence roots committed
  together;
- idempotent retry and replay rejection;
- streaming acknowledgement and partial-result policy.

Current state: **integrated for tokens and model-free media fixtures**. The
media transaction composes exact resource admission, transformed output,
timeline advancement, and logical chunk visibility behind one commit boundary;
abort scrubs provisional bytes and leaves both publication sequences unchanged.
Generic tensor/action envelopes, streaming acknowledgement, durable media
output, and model-generated media transactions remain planned.

Promotion gate: every output family has a named atomic unit, rollback behavior,
replay rule, and continuation position; cancellation cannot expose an
unaccounted partial result.

### 9. Evidence and observability plane

Responsibilities:

- portable wires, canonical roots, event chains, independent verifiers, and
  mutation-complete fixtures;
- latency, throughput, memory, energy, utilization, quality, and cost reported
  under a captured machine/provider envelope;
- trace correlation without storing raw private inputs in core records;
- human-readable inspectors that never turn unverified bytes into authority;
- claim boundaries generated beside benchmark results.

Current state: **integrated evidence building blocks**, **prototype inspection
tooling**.

Promotion gate: every promoted claim names the workload, platform, numerical
mode, baseline conditions, verifier, retained artifacts, and nonclaims.

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
SDK, installer, and compatibility policy do not yet exist.

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
| Encoders, embeddings, rerankers, classifiers | encode, pool, rank, classify | Idea; shared tensor/kernel pieces exist | Tiny encoder fixture with exact tensor/output schema | Deterministic batch mapping, stable normalization, typed vector/score publication |
| Vision understanding | encode image, OCR, detect, segment, VQA inputs | Model-free image runtime vertical integrated; model gated | Tiny image processor plus patch/source mapping | Geometry/color identity, bounded tensors, boxes/masks mapped to source regions |
| Speech and audio understanding | ASR, translation, audio classification | Model-free audio runtime vertical integrated; model gated | PCM window to feature/source-range evidence | No sample loss/duplication, exact streaming restart, transcript transaction |
| Speech and audio generation | TTS, codec/audio token generation | Idea | Synthetic bounded waveform chunk fixture | Ordered chunk publication, playback acknowledgement, cancellation/provenance |
| Video understanding | frame/segment encode, search, summarize | Model-free video runtime vertical integrated; model gated | Keyframe selection plus temporal window plan | Exact frame/time mapping, temporal-cache ownership, synchronized stream policy |
| Image generation | diffusion/flow step, decode latent, publish image | Idea | Tiny deterministic latent scheduler state machine | Latent/step continuation, bounded decode, atomic image/provenance publication |
| Video generation | temporal latent steps, frame/segment publication | Idea | Two-frame synthetic generation fixture | Temporal ordering, restart/cancel semantics, manifest/chunk publication |
| Audio/music generation | acoustic or token steps, waveform decode | Idea | Short synthetic exact-integer output fixture | Timeline continuity, chunk lineage, rights/provenance policy |
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
  policies, capability vocabulary, and explicit unsupported results;
- specify `ArtifactManifest`, `ModelExecutionPlan`, and family adapter lifecycle;
- generate a compatibility matrix from retained tests;
- add a read-only runtime inspector and fixture authoring guide.

Exit gate: two structurally different family fixtures use the shared contracts
without family-specific fields leaking into the common wire.

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

- add encoder/embedding/reranker/classifier operations;
- define typed tensor/vector/score result envelopes;
- add deterministic batch-item mapping and tie/normalization policy;
- integrate ResourceBank, LaneWeave, cancellation, and provider routing.

Exit gate: text generation and one stateless encoder share the runtime planes
while retaining different state and publication semantics.

### R3 — Streaming perception

- bind bounded image/audio/video transforms to exact request admission and one
  atomic media publication transaction; complete for retained model-free
  fixtures;
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
  retained ownership and rejecting stale source authority;
- integrate image processors and vision encoder fixtures;
- add audio feature windows, transcript transactions, and streaming restart;
- add video temporal selection, synchronized timeline state, and cache ownership;
- extend checkpoints with family-specific processor/cache state.

Exit gate: image, audio, and video input paths preserve exact source mappings,
stay within admitted memory/time bounds, and resume or cancel at declared units.

### R4 — Generative media and multimodal fusion

- add diffusion/flow scheduler and latent-state adapters;
- add generated image/audio/video chunk manifests and provenance;
- add cross-modal cache/state identity and fusion fixtures;
- extend checkpoint and provider evidence to generative media units.

Exit gate: a deterministic synthetic generation fixture survives cancellation
and process restart without duplicate visible media chunks.

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
- one platform capability probe;
- one read-only evidence inspector;
- one compatibility-matrix row backed by a retained command.

Every slice should state its accepted inputs, maximum resources, authority,
rejection paths, evidence command, and nonclaims. See
[Contributor Projects](PROJECTS.md) and [Evidence Policy](EVIDENCE_POLICY.md).
