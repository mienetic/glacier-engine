# Glacier Engine Roadmap

This roadmap is an invitation to contribute, not a promise of delivery dates.
Every track advances through evidence-backed states:

`idea → prototype → integrated → validated → shipped`

- **Prototype:** the contract and rejection paths work in isolation.
- **Integrated:** a real runtime or provider path uses the contract.
- **Validated:** retained multi-platform or workload evidence meets its gate.
- **Shipped:** the interface, documentation, migration policy, and operations are
  ready for users outside the project.

## North star

Build a full local, edge, accelerator, and provider-backed AI runtime where
every visible token, tensor, score, media chunk, retrieval result, or authorized
action can be connected to exact artifact identity, resource ownership,
scheduling, state, transactional publication, and independently verifiable
evidence. The plane and model-family sequence is specified in the
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).

## Current snapshot

| Track | Status | What works now | Main gap |
| --- | --- | --- | --- |
| Exact admission | Integrated | ResourceBank receipts, capacity rejection, release, snapshots | Physical telemetry adapters and long-running pressure campaigns |
| Hierarchical ownership | Integrated | LeaseTree child scopes, fresh-Bank reacquisition, paged-KV remap, two-process handoff, and seven-phase checkpoint root-switch recovery | Production-model continuation and durable lifecycle metadata |
| Deterministic QoS | Integrated | LaneWeave admission, weighted service, deadlines, cancellation, replay | Multi-tenant workload integration |
| Token publication | Integrated | Contiguous/paged transactions plus exact-once next-token publication after natural exit and every checkpoint root-switch death phase | Uninterrupted/resumed production comparison |
| Continuation identity | Prototype | Capsule, object lifecycle, durable payloads, ownership/KV/runtime reconstruction, atomic immutable checkpoint generations, and two-process resume | Production model/tokenizer state, native Linux execution, and durable lifecycle metadata |
| AI runtime | Mixed prototype/integrated planes | CPU execution, optional Metal, prepared `.glrt` images, admission, scheduling, token publication, continuation, provider control plane, canonical model-family contracts, shared stateless/stateful lifecycles, and an integrated model-free image/audio/video transaction vertical | More family adapters, stable API, physical resource integration, distribution, and generated compatibility matrix |
| Model-family breadth | Text-generation prototype, typed vision/audio/temporal-video encoders, and exact two-step latent continuation across distinct processes; other families gated | Shared artifact/plan/result wires, explicit support records, reusable stateless/stateful lifecycles, fresh-Bank retained-state restore, tensor, provider, media, and evidence building blocks | Generic embeddings/reranking/classification, bounded generated-image publication, then multimodal, agents/retrieval, and specialized families |
| Multimodal execution | Model-free runtime, streaming, continuation, post-restore generation three, processor/cache state, overlap-safe transcripts, and vision/audio/video fixtures integrated; production model execution gated | Shared identity/timeline, exact per-buffer ownership, six-object checkpoint sets, image tile/patch state, audio window/hop/context plus typed transcript state, video temporal-window state, exact cache payloads, restore-before-visible ownership, and typed media publication | Transcript model restart, bounded video segments, external formats, then generated-media publication |
| Provider gateway | Integrated | Coalescing, cancellation, usage settlement, cost and event wires | Isolated live adapters and user-facing tooling |
| Context efficiency | Integrated fixture | Lossless mapping, exact wire observations, reconciled admission | Real adapter campaigns and privacy review |
| Durable provider evidence | Integrated | Crash-recoverable journal and compact evidence join | Inspector, export, retention, and operational policy |
| Benchmark evidence | Prototype | Paired harnesses, machine envelope, independent verification | More complete CPU/energy telemetry and reproducible machines |
| Weight paging | Prototype | Tested mechanics and precision rejection | Real generation integration without eager duplicate weights |

## P0 — Open-source usability

### Contributor experience

- [x] Public architecture, quickstart, roadmap, support, security, and governance.
- [x] Model-free demos for scheduling, publication, and provider state machines.
- [x] Model-free continuation capsule with independent verifier and complete
  serialized-byte mutation coverage.
- [x] Model-free tenant-scoped object resolver with independent contract model,
  bounded scans/bytes, and adversarial failure coverage.
- [x] Fixed tenant-scoped continuation bundle with canonical dedup ordinals,
  exact logical/unique totals, and full serialized-byte mutation coverage.
- [x] Bounded in-memory tenant store with atomic bundle import, exact accounting,
  duplicate reuse, quarantine, and allocator-failure rollback.
- [x] Explicit-tick object leases with renewal generations, collection fencing,
  quarantine invalidation, scoped repair, and cross-language receipt roots.
- [x] Exact root/lease reachability evidence with retained retirement, bounded
  dry-run classification, cross-language plan roots, and no deallocation.
- [x] Separately scoped sweep prepare/abort journal with plan regeneration,
  staging ceilings, unchanged snapshots, and cross-language evidence roots.
- [x] Separately scoped destructive sweep commit with canonical targets, full
  pre-mutation validation, exact before/after accounting, allocator-call
  evidence, and cross-language roots.
- [x] Fixed 784-byte sweep evidence record with chain fields, separate commit
  footer, semantic receipt reconstruction, pinned expectations, and independent
  Zig/Python mutation-complete verification.
- [x] Allocation-free anchored sweep-record classifier with exact committed
  prefix, named body/footer tail states, semantic/chain rejection, and exhaustive
  cross-language append-boundary fixtures.
- [x] Snapshot-bound exclusive sweep writer with separate append/repair
  capabilities, ordered sync, uncertain-state poisoning, explicit repair, and
  exhaustive Zig/Python deterministic crash-boundary models.
- [x] Descriptor-relative POSIX sweep file adapter with exclusive locking,
  identity/link/mode fences, ordered file and directory sync, explicit repair,
  and six real subprocess-death boundaries on the macOS host.
- [x] Exact no-mutation destructive preview plus an ordered file adapter that
  syncs the predicted receipt before deallocation and reconciles old/new
  snapshots idempotently after an injected publication boundary failure.
- [x] Canonical tenant payload snapshots plus fixed exact-target reclaim records,
  copy-on-write file promotion, stable locking across inode replacement, and
  seven real process-death boundaries on the macOS host.
- [x] Canonical ownership manifest with fresh-epoch ResourceBank/LeaseTree
  reacquisition, charge-before-materialization ordering, exact restored
  publication sequence, and independent mutation-complete verification.
- [x] Canonical paged-KV images with durable membership, complete source-chain
  validation, atomic fresh-cache reconstruction, new target generations, and
  independent mutation-complete verification.
- [x] Fixed runtime state plus a natural-exit two-process continuation proof
  joining KV, RNG, sampler, output, sequence, commit lineage, and zero-leak
  ownership teardown.
- [x] Canonical whole-checkpoint archive and fixed root selector with exact
  previous/successor recovery, seven process-death phases, independent
  verification, and a fresh live resume after every phase.
- [x] Fixed shared image/audio/video descriptor, checked rational timeline,
  explicit event lineage, and exact-once logical chunk publication with a
  model-free demo and independent verifier.
- [x] Fixed sealed media decode plan plus bounded RGB, PCM, and intra-frame
  video fixtures with caller-owned output, complete unit mappings, and
  cross-language mutation-complete verification.
- [x] Fixed sealed media transform plan with allocation-free image
  crop/nearest/tile, audio weighted mix/exact decimation, and video keyframe
  selection, exact mappings, and shared Zig/Python plan and receipt roots.
- [x] Integrated model-free media runtime transaction with exact ResourceBank
  claims, provisional caller-owned storage, transform candidate revalidation,
  atomic image/audio/video publication, abort scrubbing, retry, exact release,
  a fixed receipt, and independent mutation-complete verification.
- [x] Per-buffer media LeaseTree ownership for decoded source, mappings,
  optional scratch, and output; atomic charge-before-use, abort reclamation,
  early provisional retirement, retained output ownership, fixed receipts, and
  independent cross-language golden vectors.
- [x] Bounded multi-chunk image/audio/video streams with exact contiguous target
  intervals, cancellation-safe unpublished reclamation, retained output leases,
  fixed predecessor-bound chunk receipts, and shared Zig/Python golden chains.
- [x] Fixed image/audio/video stream checkpoints, charge-before-materialization
  fresh-Bank output restore, shared Zig/Python roots, and a real two-process
  next-chunk resume with zero duplicate publication.
- [x] One-root image/audio/video checkpoint sets with a canonical retained
  output bundle, two lineage-bound generations, seven `SIGKILL` durability
  boundaries, exact previous/successor visibility, and fresh resume before and
  after idempotent recovery.
- [x] Stateful five-object media checkpoint sets that cross-bind the fixed
  processor/cache bundle to all three stream checkpoints, retain four-object
  archive compatibility, and advance processor lineage through fresh-process
  generation three.
- [x] Materialized six-object media checkpoint sets with canonical
  image/audio/video cache payloads, mutation-complete verification, fresh-Bank
  charge-before-visibility restore, successor cache lineage, and zero final
  ownership.
- [x] Full AI runtime architecture roadmap with shared planes, universal adapter
  contracts, model-family coverage map, promotion gates, and contributor lanes.
- [x] Canonical stateful-model checkpoint with fresh-Bank
  charge-before-materialization restore and a real two-process latent chain
  that publishes the terminal step exactly once.
- [x] Bounded contributor project catalog and issue template.
- [ ] One-command local verification wrapper with clear skipped-gate reporting.
- [ ] Read-only evidence inspector for provider and token transaction fixtures.
- [ ] Small redistributable fixtures covering the supported loader surface.
- [ ] First tagged experimental release with checksums and migration notes.

### Stable project surface

- [ ] Separate internal research APIs from the supported library boundary.
- [ ] Publish an API stability and deprecation policy.
- [ ] Add installation packages after cross-platform release artifacts are proven.
- [ ] Add automated repository checks only when they are stable, fast, and useful
  to contributors locally as well as remotely.

## P1 — Verifiable AI state

### Durable continuation capsule

Goal: resume model identity, execution plan, KV roots, RNG, sampler counters,
output position, and ResourceBank ownership after a process restart.

Next slices:

1. ~~Canonical pointer-free continuation identity.~~ Complete in v1.
2. ~~Mutation-complete Zig/Python verifier fixtures.~~ Complete for all 608
   serialized byte positions and foreign object substitution.
3. ~~Capability-bounded object resolver with kind/ABI/length/root admission.~~
   Complete in memory with tenant scope, stale-epoch rejection, caller-owned
   output, bounded scan/object/total/count limits, and final composition check.
4. ~~Content-addressed bundle manifest with deduplication and tenant scope.~~
   Complete as a fixed 1,136-byte plan with typed and tenant-bound roots,
   canonical first-occurrence ordinals, and independent verification.
5. ~~Bounded immutable in-memory store with atomic bundle import.~~ Complete
   with bundle provenance, duplicate reuse, references, quarantine, exact
   payload/index counters, snapshot root, and allocator rollback.
6. ~~Lease/generation fencing and provenance-aware repair.~~ Complete in memory
   with separate lifecycle/repair capabilities, explicit ticks, stale-receipt
   rejection, quarantine fencing, exact candidate verification, and v2 snapshot.
7. ~~Reachability evidence and dry-run collection eligibility.~~ Complete with
   explicit retirement, exact root multiplicity, complete lease receipts,
   bounded slot classification, and independent plan verification.
8. ~~Bounded sweep prepare/abort journal.~~ Complete with a separate capability,
   collection-plan regeneration, exact staging ceilings, functional journal
   values, stale-snapshot rejection, and independent verification.
9. ~~Destructive sweep commit with exact allocator/accounting receipt.~~
   Complete in memory with a second capability, repeated plan regeneration,
   canonical target derivation, a no-failure mutation suffix, replay rejection,
   and independent verification.
10. Durable sweep and file-publication crash-recovery state machine:
    - ~~fixed pointer-free body/footer evidence record;~~ complete as a 784-byte
      format with record chaining and semantic receipt reconstruction;
    - ~~pure recovery classifier over concatenated records and incomplete
      tails;~~ complete with exact epoch/sequence/previous-root anchors, semantic
      record replay, five statuses, and no I/O or repair authority;
    - ~~snapshot-bound capability writer with ordered sync, uncertain-writer
      poisoning, explicit repair policy, and deterministic crash storage;~~
      complete without real filesystem authority;
    - ~~directory-capability adapter with platform locking, file/directory
      sync, replacement detection, and subprocess death tests;~~ complete for
      the POSIX adapter on the macOS host, with Linux compilation retained and
      native Linux filesystem campaigns still pending;
    - ~~join durable evidence publication to destructive transition ordering;~~
      complete for the in-memory payload store with an exact precomputed receipt,
      real file sync, injected post-publication failure, and idempotent old/new
      snapshot reconciliation;
    - ~~native durable payload-byte adapter and real process-death campaign
      across plan write/sync, candidate write/sync, rename, and directory
      sync;~~ complete on the macOS host with exact old/new recovery,
      idempotence, fixed target reconstruction, and independent Python
      verification; native Linux filesystem campaigns remain pending.
11. ~~ResourceBank/LeaseTree reacquisition without duplicated ownership.~~
    Complete as a fixed 3,360-byte resource-state plan that requires a fresh
    target epoch, charges every allocation as reserved before materialization,
    verifies typed reconstructed bytes before making nodes live, restores the
    exact next publication sequence, and rejects same-Bank replay plus stale
    source receipts.
12. ~~Paged-KV restore with foreign-generation rejection.~~ Complete as
    committed-row page images that rebuild an actual fresh `PagedKVCache`,
    preserve the logical KV root, remap cache/page generations, require exact
    durable membership and ownership claims, and reject stale source refs before
    publication.
13. ~~End-to-end process restart between two token publications.~~ Complete as
    a model-free natural-exit proof with a fixed runtime wire, different source
    and target process/cache identities, exact output append, chained receipt,
    and zero Bank usage after each process.
14. ~~Atomic publication and phase-complete process-death recovery for the
    whole checkpoint set.~~ Complete as an immutable archive plus fixed selector
    root switch across seven write, sync, rename, and directory-sync phases,
    followed by a fresh live resume after every recovery.

Promotion gate: byte-identical continuation of the selected deterministic mode,
no duplicated output, no orphaned ownership, and crash coverage at every durable
phase.

The current capsule, resolver, bundle, store, lifecycle receipts, collection
plan, sweep journal, sweep commit, body/footer record, classifier, scoped
writer, POSIX evidence file, payload file, and ownership manifest form identity,
least-authority lookup, canonical planning, durable payload-byte recovery, and
safe in-memory runtime reacquisition—not a saved session. The adapters perform
real file/directory sync, locking, identity checks, and subprocess-death
recovery on the macOS host. The ownership plan then binds the durable payload
root to a new Bank epoch and restores charged LeaseTree nodes before they become
live. Canonical page images then rebuild an actual paged-KV map under fresh
cache/page generations while preserving the logical KV hash. A fixed runtime
wire joins sequence, RNG, sampler count, output prefix, KV digest, and commit
lineage; a source worker exits and a fresh target publishes the next model-free
token exactly once. The checkpoint-file layer packages all restart objects into
one immutable archive and atomically switches a fixed selector; fresh recovery
accepts only the previous or successor root across seven process-death phases,
then resumes live publication. This does not yet restore object-store
lease/quarantine/repair metadata or reconstruct and compare a production
request. Process death is not power loss, and Linux has compile evidence rather
than a retained native filesystem campaign.
The fixture avoids one 25-byte duplicate payload allocation and the commit
fixture reclaims a 39-byte allocator tail, but lifecycle metadata, fixed index,
and backing capacity remain larger than those deltas. No lower RSS, disk use, or
restart latency is claimed. Those require compact index experiments, durable
metadata integration, production execution comparisons, native campaigns, and
complete physical measurements.

### Evidence inspection

Goal: make portable evidence understandable without weakening verification.

Next slices:

- provider evidence envelope renderer;
- LaneWeave timeline JSON;
- token transaction root explorer;
- redaction-safe bundle manifest;
- schema-version and compatibility reporting.

Promotion gate: rendering never grants authority, never marks unverified bytes as
verified, and remains deterministic.

### Capability-isolated extensions

Goal: admit tokenizer, planner, storage, and provider adapters through declared
capabilities instead of direct access to all runtime state.

Next slices:

- capability vocabulary and threat model;
- fake extension negotiation;
- resource/evidence binding;
- process or sandbox boundary experiment;
- revocation and failure semantics.

## P1 — Provider efficiency and accountability

### Context and token plane

Current fixtures prove exact deduplication decisions and reconciled wire counts.
They do not prove universal billed-token savings.

Next slices:

- adapter contract for exact rendered bytes;
- tokenizer/execution identity registry;
- privacy-safe corpus fixture generation;
- cached prefix and tool-schema identity without raw text in core;
- provider-reported usage reconciliation across retries;
- campaign reports separating logical, observed, reserved, and billed tokens.

Promotion gate: no semantic span loss, exact mapping replay, provider terminal
usage attached to the correct attempt, and no credential or prompt leakage in
core evidence.

### Durable cost operations

Next slices:

- cross-filesystem crash/recovery campaigns;
- journal rotation and retention contract;
- multi-process reader and exporter;
- unknown-price and delayed-settlement operations;
- tenant-scoped evidence bundle lifecycle.

Promotion gate: no double counting across retry/ambiguous resolution, complete
valid prefixes survive process loss, and corrupt complete frames fail closed.

## P2 — Runtime breadth

### Model and tokenizer support

- define the common family, operation, artifact, state, and result vocabulary
  from the [Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md);
- expand tiny legal fixtures before adding large model downloads;
- separate architecture parsing from tensor naming;
- add tokenizer normalization and special-token conformance;
- report an explicit compatibility matrix generated from tests;
- validate quality and exact-output modes independently.

Promotion gate: every listed combination has a retained fixture, clear failure
for unsupported inputs, and reproducible generation instructions.

### Multimodal execution

Status: **integrated model-free runtime vertical plus typed vision, audio, and
temporal-video fixtures; production-model execution gated**.
Shared identity, rational timeline/events, sealed plans, bounded canonical
RGB/PCM/intra-frame decode, three deterministic transforms, exact
`ResourceBank` admission, candidate revalidation, atomic logical publication,
abort/retry, fixed receipts, and exact release now work as one lifecycle.
External format decoding or production-model execution still starts only after
its stated continuation and integration gates. Tiny legal fixtures do not
imply production-model support.

The implementation sequence is:

1. shared `MediaObject`, sealed `MediaDecodePlan`, rational `MediaTimeline`,
   bounded three-modality fixture decode, and logical transactional publication
   are complete as model-free prototypes;
2. bounded image crop/nearest/tile and exact source-pixel mapping are complete;
3. weighted stereo-to-mono mixing, exact integer decimation, bounded two-chunk
   publication, model-free two-process restart, fixed feature-window state, a
   non-overlapping exact-integer feature encoder, canonical overlap ownership,
   and typed transcript publication are complete; transcript model restart and
   playback state remain;
4. keyframe selection, exact frame/time mappings, temporal-cache ownership, and
   a typed strided-frame encoder with charged gather scratch are complete;
   audio/subtitle linkage and typed segment publication remain;
5. exact request admission, per-buffer `LeaseTree` ownership, provisional
   execution, full candidate revalidation, commit/abort/retry, bounded
   multi-chunk publication, portable receipt chains, early provisional
   retirement, retained outputs, fixed continuation checkpoints,
   charge-before-materialization restore, two-process next-chunk resume, and
   release are complete for all three retained fixtures; crash-atomic media
   selection, two source-side generations, restored ownership rebinding, a
   fresh-process generation-three checkpoint, and another resume from that
   checkpoint are complete; fixed image tile/patch, audio feature-window, video
   temporal-cache, and synchronized-watermark state now advances as the fifth
   object in that durable archive; exact cache payloads advance as the sixth
   object and restore under fresh-Bank ownership; and
6. generated image/audio/video output only after cancellation, restart, and
   provenance rules are proven.

Every modality uses content identity separate from tenant access, explicit
decoder/preprocessing identity, exact resource admission, and provider wire
observations. See [Multimodal Roadmap](MULTIMODAL_ROADMAP.md) for use cases,
first slices, promotion gates, and contributor-ready work.

### Production weight paging

The current pager is a mechanics prototype and is not the generation weight
path. The production sequence is:

1. logical page, representation, device, and tier identity;
2. true resident-byte reservations and pins;
3. async fake-backend state machine with cancellation;
4. one CPU projection consuming page views without eager duplication;
5. full generation integration behind an explicit required policy;
6. physical RSS/residency campaigns and corruption tests.

Promotion gate: a real model trace contains load, prefetch, hit, pin, and eviction
events while no full eager representation remains.

### Backend federation

Goal: let a sealed plan select CPU and accelerator capabilities explicitly.

Next slices:

- backend capability fingerprint;
- deterministic partition plan;
- transfer ownership and cancellation;
- per-backend numerical contract;
- heterogeneous failure rollback.

## P2 — Serving and isolation

### Multi-tenant LaneWeave

- bounded admission under mixed deadlines and weights;
- exact cancellation and retirement under load;
- per-tenant ResourceBank roots;
- long-run fairness and starvation campaigns;
- overload behavior that remains deterministic and observable.

### Tenant-safe immutable page store

- content identity separated from access authority;
- tenant-scoped capabilities and provenance;
- corruption quarantine and repair;
- bounded cache eviction and reference accounting;
- optional encrypted-at-rest adapter outside the core identity.

## P3 — Future ecosystem primitives

These tracks define how Glacier can grow beyond a single-process inference
runtime without turning every integration into trusted in-process code. They are
ideas unless a different status is stated.

| Track | Status | Ecosystem outcome |
| --- | --- | --- |
| Semantic Model Capsule | Idea | Stable operator/tokenizer/adapter meaning independent of source tensor names |
| Capability Grant | Prototype (resolver scope) | Least-authority extensions for planners, tokenizers, stores, tools, and transports |
| ToolTxn and ActionOutbox | Idea | Recoverable AI tool execution without duplicated external side effects |
| ModelTxn | Idea | Atomic model/adapter hot swap without split model/KV/output state |
| Object Fabric | Prototype (durable payload bytes and logical ownership reacquisition; in-memory object lifecycle) | Tenant-safe content-addressed model, plan, KV, continuation, media, and evidence objects |
| Media Capsule | Idea (gated) | Typed image, audio, and video identity with explicit decode/preprocess meaning |
| MediaTimeline and MediaTxn | Integrated model-free fixture, bounded stream, post-restore materialized successor, six-object atomic checkpoint, and typed vision/audio/temporal-video fixtures; production-model/external-format gated | Exact sample/frame position, per-buffer execution, retained-output/cache rebinding, image/audio/video processor progress, materialized temporal-cache accounting, typed media embeddings, and an integer synchronized watermark |
| Federated Execution Mesh | Idea | Deterministic ownership across local, accelerator, edge, and remote workers |
| Local/Provider Work Router | Idea | One budget and settlement plane across local computation and external tokens |
| Privacy Budget Capsule | Idea | Explicit data-use, retention, redaction, and export authority attached to work |
| EnergyQoS | Idea | Scheduling under measured energy/thermal budgets as well as latency |
| TraceTwin and Evidence Registry | Idea | Causal replay and promotion decisions bound to immutable evidence |

### Semantic Model Capsule

Goal: describe operator graph, tokenizer behavior, adapters, tensor semantics,
numerical policy, and representation lineage without coupling execution to one
converter's tensor names.

First slices:

1. tiny normalized operator IR for one supported fixture;
2. canonical model/tokenizer/adapter root;
3. source-to-semantic mapping with duplicate/missing-role rejection;
4. backend capability negotiation against semantic operators;
5. migration record when a semantic schema changes.

Promotion gate: two independently produced source artifacts with the same
declared semantics generate the same canonical identity and checked output, while
any operator/tokenizer/adapter drift rejects before allocation.

### Capability Grant and isolated extensions

Goal: let community extensions request only named authority such as read-model,
resolve-object, count-wire-tokens, execute-transport, publish-evidence, or invoke
one tool.

Current slice: `GrantV1` implements a local, digest-bound `resolve-object`
authority for one capsule and tenant, including stale epoch and resource limits.
It is supplied by a trusted caller and is not yet a general extension protocol
or authenticated cross-process credential.

First slices:

1. versioned capability vocabulary with resource ceilings;
2. deterministic negotiation and denial transcript;
3. process-local fake extension with no ambient filesystem/network access;
4. revocation, timeout, crash, and stale-grant handling;
5. optional process/sandbox transport with identical semantics.

Promotion gate: undeclared capability use is impossible through the extension
API, denial leaves no resource mutation, and every accepted use is bound to the
request and evidence chain.

### ToolTxn and ActionOutbox

Goal: connect model-selected tool actions to explicit policy and durable
exactly-once intent. External effects cannot be rolled back like KV, so the state
machine must represent prepared, dispatched, ambiguous, reconciled, terminal,
and compensated outcomes.

First slices:

1. pointer-free action proposal and schema identity;
2. capability/policy decision receipt;
3. durable outbox body/footer commit before dispatch;
4. idempotency key and ambiguous-outcome reconciliation;
5. output publication that cites the terminal action receipt;
6. compensation evidence for reversible actions.

Promotion gate: process termination at every phase never duplicates an action,
never publishes an unexecuted action as successful, and preserves enough state
to reconcile an ambiguous external outcome without exposing credentials.

### ModelTxn

Goal: stage a new model or adapter set, validate its semantic and execution
capsules, migrate or pin sessions, then atomically publish the active generation.

First slices:

- immutable active-model generation handle;
- staged load with complete ResourceBank claim;
- compatibility decision for existing continuation/KV objects;
- commit/rollback race tests;
- mixed-generation request rejection;
- evidence-bound retirement and garbage collection.

Promotion gate: no request observes a model/adapter/KV combination that was never
committed, and rollback releases every staged resource.

### Object Fabric

Goal: reuse immutable model, plan, KV-prefix, continuation, adapter, and evidence
objects through content identity while keeping access authority tenant-scoped.

First slices:

- ~~typed object key `(tenant_scope, kind, ABI, digest, length)`;~~
- ~~capability-bounded resolver for `ContinuationCapsule`;~~
- ~~fixed capsule bundle manifest and independent parser;~~
- ~~tenant-scoped immutable fake store with admitted put/get and no ambient I/O;~~
- ~~reference counts, bundle provenance, and quarantine state;~~
- ~~lease/generation fencing and target/reason/source-scoped repair admission;~~
- ~~retained retirement plus exact reachability and dry-run collection evidence;~~
- ~~separately scoped sweep prepare/abort with plan regeneration and no free;~~
- ~~destructive sweep commit with exact allocator/accounting evidence;~~
- ~~fixed sweep body/footer evidence format;~~
- ~~pure anchored recovery classification over record streams;~~
- ~~snapshot-bound sweep writer/repair contract and deterministic crash model;~~
- ~~descriptor-relative POSIX file adapter and subprocess recovery across every
  publication and repair crash point;~~ complete on the macOS host;
- ~~exact pre-mutation receipt preview plus file publication before
  deallocation and idempotent old/new snapshot recovery;~~ complete for the
  in-memory payload store with an injected post-publication boundary failure;
- ~~native durable payload-byte snapshots and process-death recovery across
  reclaim-plan and copy-on-write promotion phases;~~ complete on the macOS host
  with independent Python verification;
- ~~canonical durable ownership plan plus fresh-epoch ResourceBank/LeaseTree
  reacquisition without same-Bank duplication;~~ complete as a model-free
  prototype;
- ~~paged-KV generation and page-map restore under reacquired ownership;~~
  complete as a model-free actual-cache prototype;
- ~~sampler/RNG/output composition and end-to-end visible restart;~~ complete
  as a model-free natural-exit two-process proof;
- ~~atomic whole-checkpoint promotion and crash recovery at every durable
  phase;~~ complete for the model-free seven-phase root-switch campaign;
- uninterrupted/resumed production-model equivalence fixture;
- native Linux filesystem campaigns across evidence and payload transitions;
- trusted replica transport with independently verified fetch evidence;
- optional encrypted storage adapter whose ciphertext identity is separate from
  semantic content identity.

Promotion gate: cross-tenant lookup never follows content equality alone, live
leases survive collection, corrupt objects cannot enter execution, and measured
deduplication savings include metadata and cache overhead.

### Federated Execution Mesh

Goal: assign plan fragments to CPU, accelerator, edge, or remote workers using
capability, resource, deadline, and evidence contracts rather than backend names.

First slices:

1. worker capability capsule and liveness epoch;
2. immutable fragment ownership plan;
3. transfer object with source/destination resource handoff;
4. deterministic timeout and reassignment without duplicate publication;
5. partial-result quarantine and heterogeneous numerical verification;
6. network-credit admission integrated with ResourceBank.

Promotion gate: worker loss, replay, reordering, and partition cannot publish a
token twice or lose ownership accounting; a single-node path remains available
without distributed overhead.

### Local/provider work router

Goal: choose local execution, external execution, or a verified composition under
one request identity, quality policy, latency deadline, privacy grant, and cost/
resource ceiling.

First slices:

- canonical `WorkIntent` shared by local and external paths;
- comparable logical token/work and monetary quote units without converting
  unknown values to zero;
- deterministic fake-route decision and fallback state machine;
- cancellation and ambiguous remote-attempt reconciliation;
- one terminal output authority across all attempted routes;
- paired quality/latency/cost evidence per route envelope.

Promotion gate: retries or fallback never duplicate a user-visible response or
double-count settled cost, and private work cannot cross into a route lacking the
required privacy capability.

### Privacy Budget Capsule

Goal: attach explicit data categories, redaction policy, retention, geographic or
tenant boundary, logging permission, export permission, and expiry to every work
intent and evidence bundle.

First slices:

- closed vocabulary and fail-closed policy intersection;
- hash-only versus payload-bearing evidence classification;
- retention/expiry event wire;
- provider/extension capability matching;
- deletion receipt that distinguishes logical unlink from physical erasure.

Promotion gate: policy downgrade or missing classification rejects before
payload access, and audit output never claims physical deletion from a logical
ledger alone.

### EnergyQoS

Goal: make energy and thermal budgets schedulable resources alongside memory,
queue, and latency—only on platforms with trustworthy measurement.

First slices:

- read-only sensor adapter with present/missing/denied/stale states;
- energy interval bound to accepted tokens and monotonic time;
- conservative admission using a declared upper bound;
- LaneWeave policy simulation under per-tenant energy budgets;
- drift handling and checked fallback when sensors disappear.

Promotion gate: hardware energy values come from documented sensors, intervals
cover the complete charged work, and missing telemetry cannot become an inferred
savings claim.

### TraceTwin and Evidence Registry

Goal: reproduce the causal plan/admit/execute/fallback/publish path from portable
events and allow runtime policy to select only configurations with retained
passing evidence.

First slices:

- versioned causal event vocabulary;
- independent state-machine replay;
- immutable evidence envelope for binary, dependencies, model, workload,
  machine, raw samples, and statistical policy;
- registry query returning exact passing scope, not a transferred general claim;
- expiry/revocation when code, model, driver, or machine policy drifts.

Promotion gate: mutation, truncation, reordering, foreign evidence, and expired
scope reject; replay reaches the same committed roots without requiring private
payload text.

## Research tracks

### Prism progressive precision

Exact bitplane decomposition and scalar oracles exist. Dense progressive layouts
did not meet their feasibility gates, so broader runtime integration is paused.
Only a bounded storage or kernel result that clears the stop rules should reopen
the track. See [Prism Decode](PRISM_DECODE.md).

### Sealed DecodePlan

Static work, layout identities, scratch requirements, and compatibility checks
are moving toward an immutable prepared plan. Current pieces are experimental and
do not yet form a stable public ABI. See [Sealed DecodePlan](SEALED_DECODE_PLAN.md).

## Measurement roadmap

The machine envelope currently captures useful host and run identity but does not
directly prove CPU temperature, effective frequency, performance/efficiency core
residency, or package energy on every platform.

Priorities:

1. read-only platform adapters with present/missing/denied states;
2. paired randomized execution with cooldown and load gates;
3. physical memory and device-residency evidence;
4. energy and thermal capture where trustworthy APIs exist;
5. reproducible public artifact bundles with independent verification.

### Fair paired campaign contract

Any comparative runtime campaign must hold or explicitly model these variables:

- exact model and tokenizer bytes, prompt/token input, output contract, seed, and
  requested token count;
- compiler optimization, architecture, backend/device policy, thread count,
  affinity, process priority, and memory limits;
- power source, low-power mode, charger state, foreground/background processes,
  warmup, cooldown, and pre-pair system load;
- randomized or balanced pair order in the same machine session;
- correctness/quality, timeout, thermal, load, and telemetry validity gates fixed
  before observing results;
- raw TTFT, prefill, decode, ITL, end-to-end, RSS, device memory, transferred
  bytes, and energy values only when their observers are available;
- rejected pairs with reasons, not silent deletion.

MachineEnvelope v2 work items:

1. host capability report generated before either arm is named;
2. symmetric process-tree observer outside both arms;
3. charger/power and low-power-state adapters;
4. CPU effective-frequency and core-residency adapters where supported;
5. device allocation/residency and unified-memory pressure adapters;
6. signed monotonic interval and observer-loss events;
7. schema validator that prevents a campaign from claiming an unavailable
   physical metric.

Promotion gate: a same-machine result remains scoped to its exact matrix;
multi-platform wording requires independent machines, workloads, and retained
artifacts rather than repeated samples from one host.

## How roadmap work merges

Each pull request should advance one row by one observable step. A roadmap issue
must name:

- the current and target status;
- the smallest mergeable slice;
- success and rejection tests;
- evidence or artifact retained;
- claim boundary;
- rollback or stop condition.

See [Contributor projects](PROJECTS.md) for ready-to-split ideas. Contributors are
also welcome to propose new tracks when they fit the north star and can begin with
a bounded, testable slice.
