<p align="center">
  <img src="assets/brand/glacier-engine-logo.png" width="190" alt="Glacier Engine logo">
</p>

<h1 align="center">Glacier Engine</h1>

<p align="center"><strong>A proof-carrying runtime for local and provider-backed AI execution.</strong></p>

Glacier Engine is an experimental full AI Runtime project written in Zig. It
treats artifact identity, resource admission, placement, scheduling, execution,
continuation, token and media publication, provider usage, and cost as explicit
state transitions that can be rejected, replayed, and verified. Model inference
is one runtime plane, not the boundary of the project.

The project is early enough for contributors to shape its public APIs and mature
enough to offer tested building blocks, credential-free demos, portable evidence
formats, and independent verifiers.

> **Project status:** experimental. The core contracts are heavily tested, but
> model coverage, platform coverage, API stability, packaging, and production
> operations are still under active development.

## Why Glacier Engine

- **Atomic token publication.** KV rows, RNG state, sampler counters, and output
  words are committed together or remain invisible.
- **Exact resource admission.** `ResourceBank` and `LeaseTree` make logical
  ownership and release part of the execution contract.
- **Deterministic multi-request scheduling.** `LaneWeave` provides bounded,
  weighted service with replayable decisions and fail-closed permits.
- **Portable workload-pressure evidence.** A versioned mixed image/audio/video
  scenario drives real admission, weighted service, overload rejection,
  timeout, cancellation, and final release; Zig exact replay and an independent
  Python verifier agree on every outcome, trace, summary, and root.
- **Paged KV ownership.** Physical page identity, generations, references, and
  publication fences are bound into token receipts.
- **Generation-remapped KV restore.** Canonical committed-row images rebuild a
  fresh paged cache under charged ownership; historical cache/page generations
  remain stale evidence and never become target authority.
- **Cross-process token continuation.** A fixed runtime wire joins paged KV,
  RNG, sampler count, output prefix, publication sequence, and commit lineage;
  a two-process proof resumes the next token exactly once and returns ownership
  to zero.
- **Atomic checkpoint root switching.** Complete checkpoint objects live in one
  immutable archive selected by a fixed 192-byte record; seven process-death
  phases recover only the exact previous or successor root before live resume.
- **Shared media contracts.** One fixed image/audio/video identity, checked
  rational timeline, explicit transform history, and exact-once chunk
  publication give future multimodal paths a verifiable model-free foundation.
- **Bounded media inputs.** Sealed decode plans and tiny RGB, PCM, and
  intra-frame video fixtures decode into caller-owned storage while mapping
  every pixel, audio frame, and video frame to exact source bytes.
- **Deterministic media transforms.** A sealed 512-byte plan drives
  allocation-free image crop/nearest/tile, audio weighted mix/exact decimation,
  and video keyframe selection with exact per-output-unit mappings and
  cross-language receipts.
- **Transactional media execution.** One request-local runtime lifecycle admits
  an exact image/audio/video claim, executes into provisional caller-owned
  buffers, revalidates every output mapping, commits media and resource
  publication together, scrubs on abort, and releases the claim to zero.
- **Per-buffer media ownership.** Decoded source, mapping, declared scratch
  (zero in the retained plans), and output storage have distinct
  generation-fenced `LeaseTree` roles. A committed request can scrub and retire
  provisional buffers early while retaining only the published output lease.
- **Bounded multimodal streams.** Image, audio, and video chunks share one exact
  target timeline while each chunk keeps an independently owned output.
  Gap/overlap, cancellation, candidate drift, capacity, and chain substitution
  reject without orphaning unpublished leases.
- **Two-process media continuation.** A fixed checkpoint carries exact stream
  state and retained-output ownership across a real process exit. The target
  charges a fresh Bank before materialization and appends the next image,
  audio, or video chunk without duplicating publication.
- **Atomic multimodal generations.** Three stream checkpoints, one canonical
  retained-output bundle, an optional fixed processor-state bundle, and an
  optional verified cache-payload bundle share a single immutable archive root.
  Process-death campaigns prove that readers resume the complete previous or
  successor image/audio/video generation, never a mixed set.
- **Post-restore checkpoint successor.** A fresh process rebinds retained
  ownership from the selected generation, appends image/audio/video chunks,
  atomically publishes generation three, releases its Banks, and supports
  another fresh-process resume without accepting stale source authority.
- **Multimodal processor/cache state.** Fixed image tile/patch progress, audio
  feature windows, video temporal-cache windows, and an exact synchronized
  watermark form one lineage-bound, independently verified state bundle. A
  stateful checkpoint stores it as a fifth atomic object and advances it through
  fresh-process generation three.
- **Restore-before-visible processor caches.** A sixth atomic object carries
  exact image/audio/video cache payloads. Fresh processes charge three
  generation-fenced `activation_bytes` allocations before byte verification,
  make them live only after success, and release every cache owner to zero.
- **Typed model-family execution.** Fixed artifact, execution-plan, and result
  records separate runtime vocabulary from executable support. Capability-free
  vision, audio, and temporal-video adapters read only verified live caches,
  compute into provisional storage, reject candidate drift, and publish
  source- and ownership-bound embedding transactions. Video selection gathers
  strided frames through explicitly charged scratch and scrubs it on return.
- **Overlap-safe transcripts.** A canonical audio plan separates prefix context
  from newly publishable samples, binds both to live processor-cache ownership,
  and commits a fixed transcript segment without turning repeated context into
  duplicate visible text.
- **Source-bound video segments.** A canonical strided selection now publishes
  a fixed typed result carrying exact frame/time bounds, keyframe and eviction
  lineage, model event/confidence fields, and a predecessor-bound segment root.
- **Deterministic video timelines.** Fixed state and receipt wires coalesce only
  touching or overlapping results of the same event, retain gaps and different
  events, preserve raw segment lineage, and publish each decision atomically.
- **Exact cross-modal result links.** A fixed transaction maps only newly
  publishable transcript samples onto the accumulated video timeline, rejects
  fractional or non-overlapping time, excludes conditioning context, and
  preserves both modality lineages in one independently verified chain.
- **Fresh-process transcript continuation.** A stateful transcript family and
  fixed composed checkpoint restore exact sample/model state under fresh
  charged ownership, publish only the next text range, advance its video link,
  and return every target allocation to zero.
- **Exact word timing and speaker turns.** Fixed annotation state, plan, and
  result wires map transcript token bytes onto exact sample ranges and
  first-occurrence speaker identities. Abort preserves visibility, while a
  distinct target process resumes the next word and turn without duplication.
- **Stateful VFR video continuation.** Explicit per-frame PTS and duration wires
  bind exact feature bytes, declared gaps, retained temporal state, typed video
  segments, timeline decisions, and cross-modal links across a real process
  restart under fresh charged ownership.
- **Atomic retained-state steps.** A separate stateful lifecycle pins model and
  state publication snapshots, executes into disjoint private output/state
  candidates, and publishes both together. A canonical two-step latent fixture
  checkpoints the intermediate state, reacquires it in a distinct process
  before materialization, and publishes the terminal result exactly once.
- **Generated images after restart.** A bounded decoder turns that exact
  terminal latent into a caller-owned image, then publishes pixels,
  provenance, typed result, resource receipt, and media timeline atomically.
  Abort and candidate drift preserve visible state, while a real two-process
  proof returns every target resource to zero.
- **Acknowledged generated-audio streams.** Canonical state, plan, provenance,
  result, observation, and acknowledgement wires publish bounded PCM chunks
  atomically and permit only one unacknowledged buffer. A distinct target
  process verifies the pending chunk, rejects partial acknowledgement, opens
  backpressure only after exact application consumption, and publishes the
  successor without duplication.
- **Ordered generated-video manifests.** Canonical state, two-frame manifest,
  provenance, result, observation, and acknowledgement wires bind raw frame
  roots and exact durations. A fresh process validates retained output before
  admission, rejects partial display, opens the successor gate only after full
  application consumption, and preserves visibility on cancellation.
- **Atomic generated-media checkpoints.** Typed image completion, acknowledged
  audio, and acknowledged video normalize into three fixed members behind one
  checkpoint and atomic selector. Four process-death boundaries recover only
  the complete previous or successor generation, never a mixed output set.
- **Exact generated-media payload archives.** One canonical eight-object
  generation joins the manifest, checkpoint, three typed members, and exact
  encoded image/audio/video bytes. Raw-output, encoded-payload,
  encoder-implementation, and format identities remain explicit; one outer
  filesystem selector recovers only the complete previous or successor
  generation across seven process-death phases.
- **Bounded multi-output media registries.** An independent canonical ABI packs
  one to four output entries per present modality, up to twelve total, into
  ordered fixed entries plus their exact encoded bytes. Image entries require
  no completion receipt; audio/video entries require a completed flag and
  nonzero completion root. One existing selector exposes only a complete
  previous or successor three-object archive.
- **Canonical generated-media producer admission.** A pre-publication gateway
  decodes the existing typed image, audio, and video records, verifies exact
  raw pixels/PCM/frame bytes, derives the common request envelope and strict
  state/result/completion predecessors, replays canonical audio/video
  application acknowledgements, and derives registry entry and predecessor
  roots for an unchanged registry generation.
- **Host-verified generated-media transitions.** A higher-assurance gateway
  replays the retained deterministic source-model and image/audio/video
  materializer profiles over exact witnesses, reconstructs image publication
  plus complete audio/video acknowledgement transitions, derives registry
  order, and emits a separate evidence sidecar bound to the unchanged
  three-object registry. Image collection order remains separate from each
  one-shot local image transaction. Replay on the verifying host is not proof
  of historical execution, live resource authority, physical playback/display,
  external codec/container conformance, or performance.
- **Bounded lossless delivery profiles.** Strict emit-and-accept modules cover
  canonical PNG for bounded 8-bit gray/gray-alpha/RGB/RGBA images, canonical
  PCM s16le WAVE for bounded mono/stereo audio, and canonical two-frame gray8
  APNG. Golden vectors, mutation rejection, native macOS execution, and
  module-level Linux/Windows/FreeBSD cross-compilation are retained. These are
  narrow profiles, not general codec, container, quality, or playback support.
- **Integrated bounded format evidence.** A separate sidecar binds those
  strict profiles, exact payloads, producer plan or manifest, registry entries,
  transition receipts, and predecessor format records without changing the
  existing registry or producer-transition V1 wires. Real two-generation PNG,
  WAVE, and APNG registry-transition fixtures cover exact successor,
  missing/foreign predecessor, semantic drift, and failure-atomic output;
  audio/video fixtures use the typed playback/display acknowledgement chains.
  A separate capacity-pressure chain fills two generations with four records
  per modality, reaching twelve transition receipts and format records per
  generation; the real inspector validates both maximum-entry triples.
  An independent Python oracle validates all three binary layers and producer
  semantics, including frozen sidecar roots, every-byte mutation, truncation,
  insertion, ordering, aggregates, padding, and successor lineage.
- **Read-only generated-media inspection.** An experimental CLI validates a
  registry archive and its producer-transition evidence, requires the exact
  predecessor pair for a successor, optionally validates current/predecessor
  format sidecars, and emits deterministic field-ordered JSON only after exact
  pair or triple validation. It renders identities and roots, never payload
  bytes, and has no callback or filesystem-write path.
- **Proof-carrying continuation.** A fixed-size manifest binds model, tokenizer,
  plan, resource, schedule, KV, sampler, output, and publication state without
  duplicating those external objects.
- **Restore-before-visible ownership.** A canonical resource-state plan
  reacquires a fresh `ResourceBank`/`LeaseTree`, charges every allocation before
  materialization, verifies exact reconstructed bytes, and only then marks the
  batch live at its restored publication sequence.
- **Tenant-scoped object resolution.** A least-authority grant admits only exact
  capsule objects under bounded scan, object, total-byte, and resolution limits.
- **Canonical continuation bundles.** Semantic roots remain kind-specific while
  equal in-tenant payloads receive one deterministic storage blob ordinal.
- **Bounded tenant object storage.** Atomic in-memory bundle import owns one copy
  per unique blob with exact payload, index, and reference accounting.
- **Generation-fenced object lifecycle.** Explicit-tick leases prevent stale
  owners and final collection; exact repair capabilities restore quarantined
  bytes only after target, reason, source, and payload verification.
- **Evidence-first object retirement.** Exact root multiplicity and complete
  lease coverage classify every stored object before any future sweep; the
  current planner is deterministic, bounded, cross-language, and dry-run only.
- **Capability-scoped object reclamation.** A separately approved plan is
  regenerated before staging, then a distinct commit grant authorizes only the
  exact canonical retired set. Receipts bind before/after snapshots and exact
  entry, payload, index, and allocator-call accounting.
- **Portable sweep evidence.** A fixed 784-byte body/footer record reconstructs
  and verifies the commit grant plus both receipts, rejects foreign chain
  positions, and exposes an ordered future append plan. An allocation-free
  anchored classifier identifies a verified committed prefix and distinguishes
  short body, missing-footer, partial-footer, and corrupt tails without receiving
  file, repair, deletion, or recovery authority.
- **Least-authority crash publication.** Snapshot-bound exclusive capabilities
  separate ordered body/footer append from explicit incomplete-tail repair.
  Uncertain I/O poisons the writer, and an allocation-free reference backend
  explores every modeled byte boundary without granting real filesystem or
  payload-deletion authority.
- **Identity-fenced file publication.** A descriptor-relative POSIX adapter
  adds exclusive locking, no-follow lookup, single-link/private-mode checks,
  file and directory sync, namespace-replacement detection, and six real
  subprocess-death boundaries without adding payload deletion authority.
- **Publication-ordered reclamation.** Glacier predicts the exact post-removal
  receipt without mutation, syncs that record before freeing payloads, and
  reconciles exact old/new snapshots so recovery applies once or recognizes an
  already-applied transition.
- **Durable payload promotion.** Canonical tenant payload snapshots use a
  copy-on-write candidate and fixed reclaim plan that preserve exact targets
  across process death. Fresh recovery accepts only the old or predicted new
  root across seven write, sync, rename, and directory-sync boundaries.
- **Verifiable provider operations.** Request coalescing, cancellation,
  settlement, cost journals, transport events, and a compact evidence root can
  be checked without provider credentials.
- **Lossless context packing.** Exact rendered duplicates declared idempotent by
  the caller can share one emitted span while every logical span remains mapped.
- **Evidence-aware performance work.** Benchmarks record machine conditions,
  paired execution order, correctness gates, and explicit claim boundaries.

## What you can build with it

Glacier Engine is useful for AI infrastructure work where a result alone is not
enough:

- local inference experiments with explicit model and memory layouts;
- agent or batch systems that need fair, bounded scheduling;
- provider gateways that need token, retry, cancellation, and cost accounting;
- durable audit records for AI requests without storing prompt text in core
  evidence structures;
- fault-injection research for KV, output, RNG, and journal publication;
- media preprocessing and streaming prototypes that need exact source ranges,
  provenance, and ordered output state;
- generative-media runtime experiments that need terminal-state identity,
  cancellation-safe output, and independently verifiable provenance;
- restartable media pipelines that need typed generated results and their exact
  encoded image/audio/video deliverables to advance together;
- model-family and backend experiments that need one runtime contract across
  artifacts, resources, scheduling, state, streaming, publication, and
  evidence; and
- reproducible runtime, kernel, format, and verification research.

The provider context fixtures demonstrate a logical count change from 440 to
250 tokens and a reservation change from 490 to 300. Those are deterministic
fixture results—not proof of lower billed tokens for every provider or workload.

## Architecture at a glance

```text
request
  │
  ├─ ResourceBank ── exact claim, receipt, LeaseTree
  │
  ├─ LaneWeave ───── admission, fairness, service permit
  │
  ├─ execution ───── CPU / Metal, prepared image, paged KV
  │
  └─ publication ─── KV + RNG + sampler + output (one transaction)
                         │
                         ├─ portable receipts and replay roots
                         └─ ContinuationCapsule (typed external object roots)
                                  │
                                  ├─ bounded tenant-scoped object resolver
                                  ├─ canonical tenant bundle
                                  └─ bounded in-memory object store
                                     ├─ lease, quarantine, repair
                                     ├─ retire + collection plan
                                     └─ sweep prepare/abort + atomic commit
                                        └─ fixed body/footer evidence record
                                           └─ pure anchored stream classifier
                                              └─ scoped writer/repair model
                                                 └─ locked real-file adapter
                                                    └─ exact preview publication
                                                       └─ durable payload plan
                                                          └─ copy-on-write apply

provider request
  │
  ├─ ContextPack ─── lossless mapping and token reconciliation
  ├─ Gateway ─────── coalescing, cancellation, usage settlement
  ├─ CostJournal ─── crash-recoverable append and replay
  └─ EvidenceJoin ── compact root over gateway, transport, and cost evidence

media object
  │
  ├─ MediaObject ─── fixed image/audio/video content + policy identity
  ├─ DecodePlan ───── sealed decoder + representation + exact bounds
  ├─ fixture decode ─ caller-owned RGB / PCM / intra-frame bytes + mappings
  ├─ TransformPlan ── crop/nearest/tile, mix/decimate, keyframe selection
  ├─ MediaTimeline ─ checked rational positions + explicit transform events
  ├─ ResourceBank ─── exact parent admission + bounded LeaseTree
  └─ MediaRuntimeLease
       ├─ prepare ─── charge source/mapping/scratch/output before use
       ├─ abort ───── scrub provisional bytes + retire every allocation
       ├─ commit ──── output + resource root + timeline (one boundary)
       └─ retire ──── drop provisional leases; retain output until release
             │
             └─ MediaStreamRuntime
                  ├─ append ── exact contiguous target interval
                  ├─ retain ── one output lease per committed chunk
                  └─ chain ─── portable predecessor-bound chunk receipts
                       │
                       └─ MediaStreamContinuation
                            ├─ checkpoint ─ fixed state + output plan
                            ├─ reacquire ── charge before materialize
                            ├─ resume ───── next chunk in a fresh process
                            └─ CheckpointSet
                                 ├─ bundle ── all retained media outputs
                                 └─ select ── atomic generation root
```

See [Architecture](docs/ARCHITECTURE.md) for the component map and
[Glacier AI Runtime Roadmap](docs/AI_RUNTIME_ROADMAP.md) for the full runtime
planes, model-family adapter map, promotion gates, and contributor sequence.
The [Platform Portability](docs/PLATFORM_PORTABILITY.md) ledger separates
compile evidence from native, recovery, accelerator, and packaging support.

## Quick start

Requirements:

- Zig 0.15.0 or newer;
- macOS for the retained native development-host workflow; Linux, Windows, and
  FreeBSD currently have cross-build evidence only;
- Python 3 for the independent evidence tests.

Compile-only core probes also exist for additional targets. They are not native
support claims; see [Platform Portability](docs/PLATFORM_PORTABILITY.md).

Build the portable CLI and run deterministic model-free demos:

```sh
zig build -Doptimize=ReleaseSafe -Dmetal=false
./zig-out/bin/glacier --version

zig build lane-publication-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-capsule-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-resolver-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-bundle-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-store-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-collection-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-commit-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-record-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-file-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-payload-file-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-checkpoint-file-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-contract-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-decode-fixture-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-transform-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-runtime-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-runtime-lease-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-stream-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-stream-continuation-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-stream-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build media-stream-checkpoint-set-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build generated-image-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build generated-audio-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build generated-video-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build generated-media-checkpoint-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build generated-media-payload-archive-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build generated-media-output-registry-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig test src/core/generated_media_producer_admission.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_media_producer_admission
zig build media-external-format-test -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_generated_media_external_format
python3 -m unittest bench.tests.test_generated_media_format_conformance
python3 -m unittest bench.tests.test_generated_media_evidence_inspector
zig test src/core/workload_pressure.zig -OReleaseSafe
python3 -m unittest bench.tests.test_workload_pressure
zig build speech-annotation-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build provider-gateway-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the main verification suites:

```sh
zig build test -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest discover -s bench/tests
```

The first build may take a few minutes. Subsequent builds use Zig's cache. For
model conversion, generation, and every demo command, continue with the
[Quickstart guide](docs/QUICKSTART.md).

Zig dependency consumers can import the runtime or core module without taking
a dependency on the CLI, demos, or benchmark executables:

```zig
const glacier_dep = b.dependency("glacier_engine", .{
    .target = target,
    .optimize = optimize,
});
app.root_module.addImport("glacier", glacier_dep.module("glacier"));
// Or use glacier_dep.module("glacier_core") for the core surface.
```

The `glacier` module propagates its target-specific libc, AArch64 INT4, and
optional macOS Metal link requirements. The `glacier_core` module retains the
hardware-independent surface without those native backend dependencies.

## Current feature map

| Area | Available today | Next public milestone |
| --- | --- | --- |
| AI runtime | CPU execution, optional Metal backend, prepared `.glrt` images, typed family/operation contracts, exact admission/scheduling/publication, continuation, provider and media planes | More family adapters, stable API, distribution and retained compatibility matrix |
| Model families | Text-generation prototype, cache-bound vision/audio/temporal-video embedding fixtures, stateful transcript and VFR video restart, exact word/speaker annotations, typed video segments, canonical merge timelines, exact audio/video result links, shared stateless/stateful lifecycles, exact latent continuation, atomic generated-image publication, restartable generated-audio publication, acknowledged generated-video manifests, atomic cross-modality generated-output checkpoints, exact encoded-payload archive composition, bounded multi-output image/audio/video registry continuity, canonical typed producer admission, and exact deterministic producer-transition replay for retained reference profiles | Generic embeddings/reranking/classification, richer language/punctuation and ambiguous-speaker policy, production generative-media adapters, multimodal fusion, agent/tool, retrieval, time-series, graph/scientific, routed and adapter families |
| State | Token transactions, capsule, resolver, bundle, tenant store, durable payload recovery, ownership/KV remap, fixed runtime state, two-process resume, and a seven-phase atomic checkpoint root switch | Production-model uninterrupted/resumed comparison, native Linux recovery, and durable lifecycle metadata |
| Scheduling | Exact admission, deterministic weighted QoS, and one bounded mixed-media pressure campaign with exact replay | Family-aware batching, preemption, multi-device placement, and broader multi-tenant campaigns |
| Providers | Context packing, gateway, transport harness, settlement and cost wires | Pluggable live adapters outside the credential-free core |
| Evidence | Hash-chained events, independent Python verifiers, compact provider evidence join, and an experimental read-only generated-media inspector with exact optional format-sidecar validation, including a two-generation 12-entry-per-generation capacity campaign | Provider/token inspectors, privacy-safe export and retention policy, and native multi-OS evidence |
| Multimodal | Shared identity/timeline, bounded decode/transforms, per-buffer ownership, chunk chains, six-object input checkpoints, post-restore generation three, image processor progress, overlapping audio context plus fresh-process transcript continuation, exact word/speaker annotation restart, explicit VFR windows plus stateful video restart, typed segments and deterministic merge timelines, exact audio/transcript-video result links, synchronized watermark, restore-before-visible cache ownership, typed perception results, generated-image publication, acknowledged generated-PCM/video publication, one atomic generated image/audio/video checkpoint, one exact eight-object encoded-payload archive, a bounded multi-output registry, typed producer/raw-output admission, host replay of exact deterministic source-model/materializer transitions, validated bounded PNG/WAVE/APNG profiles, and an integrated additive format-conformance sidecar with a maximum-entry repeated-modality composed oracle | External video-timeline normalization, production encoder/container adapters and broader profiles, richer language/punctuation and overlapping-speaker policy, native Linux/Windows execution and power-loss campaigns, additional model/materializer profiles, and authorized physical playback/display and quality evidence |
| Platforms | Native macOS development-host evidence; full build and test-compile gates for Linux x86_64/AArch64 musl, Windows x86_64 GNU, and FreeBSD x86_64; exported package modules; compile-time adapter-availability inventory; read-only POSIX/Windows model-file mapping; portable process-ID and forced-termination fixtures; compile-only core probes for Android and iOS AArch64 | Split named core/CPU/durable/device/host-tool profiles; run native Linux/Windows/FreeBSD CPU, mapping, and recovery campaigns; finish Windows durable-file, clock, telemetry, and packaging adapters; then add mobile and reduced edge profiles |
| Load and resilience | Prototype: one portable versioned explicit-open-loop scenario/result contract covers mixed-media overload, fairness, timeout, cancellation, logical resource high-water marks, and zero-orphan close with Zig/Python replay | Generated scenarios, a separate closed-loop mode, real adapter workloads, native p50/p95/p99 and physical-resource evidence, then bounded soak and disruption campaigns |
| Tooling | Zig build, exported `glacier`/`glacier_core` package modules, deterministic demos, benchmark harnesses | Product-specific build profiles, installer, stable library API, and simpler fixture workflow |

Detailed status, acceptance gates, and contributor-sized work items live in the
[roadmap](docs/ROADMAP.md).

## Choose a contribution

You do not need AI kernel experience to contribute. Useful work includes Zig,
Python, device backends, Linux/Windows/mobile portability, property tests, fault
injection, documentation, format tooling, visualizers, examples, and
reproducibility.

Good starting points:

1. Read [Contributing](docs/CONTRIBUTING.md) and pick a small item from
   [Contributor projects](docs/PROJECTS.md).
2. Open a **Claim a contributor slice** issue describing one mergeable outcome
   and its acceptance command.
3. Submit a focused pull request. Draft pull requests are welcome.

Maintainers will help reduce an ambitious idea into an independently mergeable
slice. Correctness fixes, clearer explanations, and rejection-path tests are as
valuable as new features.

## Documentation

- [Quickstart](docs/QUICKSTART.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Glacier AI Runtime roadmap](docs/AI_RUNTIME_ROADMAP.md)
- [Platform portability](docs/PLATFORM_PORTABILITY.md)
- [Contributor projects](docs/PROJECTS.md)
- [Benchmark and evidence guide](docs/BENCHMARKS.md)
- [Deterministic workload pressure](docs/WORKLOAD_PRESSURE.md)
- [Evidence policy](docs/EVIDENCE_POLICY.md)
- [Model format](docs/FORMAT_SPEC.md)
- [Native runtime image](docs/RUNTIME_IMAGE.md)
- [Hierarchical media buffer ownership](docs/MEDIA_RUNTIME_LEASE.md)
- [Bounded media stream runtime](docs/MEDIA_STREAM_RUNTIME.md)
- [Media stream continuation](docs/MEDIA_STREAM_CONTINUATION.md)
- [Atomic media stream checkpoint sets](docs/MEDIA_STREAM_CHECKPOINT_SET.md)
- [Multimodal processor and cache state](docs/MEDIA_PROCESSOR_STATE.md)
- [Materialized multimodal processor caches](docs/MEDIA_PROCESSOR_CACHE.md)
- [Typed model-family contracts and vision adapter](docs/MODEL_FAMILY_ADAPTER.md)
- [Typed audio-window encoder adapter](docs/AUDIO_WINDOW_ADAPTER.md)
- [Overlap-safe audio transcript adapter](docs/AUDIO_TRANSCRIPT_ADAPTER.md)
- [Typed temporal-video encoder adapter](docs/TEMPORAL_VIDEO_ADAPTER.md)
- [Typed video-segment adapter](docs/VIDEO_SEGMENT_ADAPTER.md)
- [Canonical video-segment timeline](docs/VIDEO_SEGMENT_TIMELINE.md)
- [Exact audio/video result link](docs/AUDIO_VIDEO_RESULT_LINK.md)
- [Stateful audio transcript continuation](docs/AUDIO_TRANSCRIPT_CONTINUATION.md)
- [Stateful VFR video-model continuation](docs/STATEFUL_VIDEO_CONTINUATION.md)
- [Generated-image publication](docs/GENERATED_IMAGE_PUBLICATION.md)
- [Generated-audio publication and playback acknowledgement](docs/GENERATED_AUDIO_PLAYBACK.md)
- [Generated-video manifest and display acknowledgement](docs/GENERATED_VIDEO_DISPLAY.md)
- [Atomic generated-media checkpoints](docs/GENERATED_MEDIA_CHECKPOINT.md)
- [Generated-media encoded payload archive](docs/GENERATED_MEDIA_PAYLOAD_ARCHIVE.md)
- [Bounded generated-media output registry](docs/GENERATED_MEDIA_OUTPUT_REGISTRY.md)
- [Canonical generated-media producer admission](docs/GENERATED_MEDIA_PRODUCER_ADMISSION.md)
- [Host-verified generated-media producer transitions](docs/GENERATED_MEDIA_PRODUCER_TRANSITION.md)
- [Generated-media external-format profiles and evidence](docs/GENERATED_MEDIA_EXTERNAL_FORMATS.md)
- [Exact speech annotation publication](docs/SPEECH_ANNOTATION_PUBLICATION.md)
- [Stateful model adapter and latent-step fixture](docs/STATEFUL_MODEL_ADAPTER.md)
- [Stateful model continuation](docs/STATEFUL_MODEL_CONTINUATION.md)
- [Paging contract](docs/PAGING.md)
- [Continuation capsule](docs/CONTINUATION_CAPSULE.md)
- [Continuation object resolver](docs/CONTINUATION_OBJECT_RESOLVER.md)
- [Continuation bundle](docs/CONTINUATION_BUNDLE.md)
- [Continuation object store](docs/CONTINUATION_OBJECT_STORE.md)
- [Continuation object lifecycle](docs/CONTINUATION_OBJECT_LIFECYCLE.md)
- [Continuation object collection plan](docs/CONTINUATION_OBJECT_COLLECTION.md)
- [Continuation object sweep journal](docs/CONTINUATION_OBJECT_SWEEP.md)
- [Continuation object sweep commit](docs/CONTINUATION_OBJECT_SWEEP_COMMIT.md)
- [Continuation object sweep record](docs/CONTINUATION_OBJECT_SWEEP_RECORD.md)
- [Continuation object sweep writer](docs/CONTINUATION_OBJECT_SWEEP_WRITER.md)
- [Continuation object sweep file adapter](docs/CONTINUATION_OBJECT_SWEEP_FILE.md)
- [Continuation object payload file](docs/CONTINUATION_OBJECT_PAYLOAD_FILE.md)
- [Continuation ownership restore](docs/CONTINUATION_OWNERSHIP_RESTORE.md)
- [Continuation paged-KV restore](docs/CONTINUATION_PAGED_KV_RESTORE.md)
- [Continuation live restart](docs/CONTINUATION_LIVE_RESTART.md)
- [Continuation checkpoint file](docs/CONTINUATION_CHECKPOINT_FILE.md)
- [Shared media contract](docs/MEDIA_CONTRACT.md)
- [Bounded media decode fixtures](docs/MEDIA_DECODE_FIXTURES.md)
- [Deterministic media transforms](docs/MEDIA_TRANSFORMS.md)
- [Media runtime transaction](docs/MEDIA_RUNTIME_TXN.md)
- [Multimodal roadmap](docs/MULTIMODAL_ROADMAP.md)
- [Glossary](docs/GLOSSARY.md)

Research tracks are documented separately in
[Prism Decode](docs/PRISM_DECODE.md) and
[Sealed DecodePlan](docs/SEALED_DECODE_PLAN.md). They are proposals with explicit
promotion and stop gates, not production promises.

## Project principles

1. Fail closed when identity, ownership, capacity, or evidence is ambiguous.
2. Publish AI-visible state atomically.
3. Keep logical accounting separate from physical measurements.
4. Bind claims to reproducible artifacts and honest scope boundaries.
5. Design large ideas as small contributions that can merge independently.

## Community and support

Questions and design discussions belong in GitHub issues. Please read
[Support](SUPPORT.md), [Governance](GOVERNANCE.md), and the
[Code of Conduct](CODE_OF_CONDUCT.md) before participating. Report sensitive
vulnerabilities through the private process in [Security](SECURITY.md).

## License

Glacier Engine is available under the [Apache License 2.0](LICENSE).
