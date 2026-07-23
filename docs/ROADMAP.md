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

Build a local and provider-backed AI execution fabric where every visible token
can be connected to exact resource ownership, deterministic scheduling,
transactional state publication, and independently verifiable evidence.

## Current snapshot

| Track | Status | What works now | Main gap |
| --- | --- | --- | --- |
| Exact admission | Integrated | ResourceBank receipts, capacity rejection, release, snapshots | Physical telemetry adapters and long-running pressure campaigns |
| Hierarchical ownership | Integrated | LeaseTree child scopes and paged-KV publication fences | Cross-worker and durable ownership identity |
| Deterministic QoS | Integrated | LaneWeave admission, weighted service, deadlines, cancellation, replay | Multi-tenant workload integration |
| Token publication | Integrated | Contiguous and paged KV, RNG, sampler, and output transactions | Restartable durable continuation |
| Continuation identity | Prototype | Capsule, resolver, bundle, tenant store, leases/repair, retirement, collection evidence, atomic in-memory sweep, fixed evidence record, pure anchored recovery classification, Zig/Python verification | Capability-scoped durable writer/repair policy, ownership reacquisition, and live restore |
| Model runtime | Prototype | CPU execution, optional Metal, INT4, prepared `.glrt` images | Broader models, platforms, quality campaigns, stable API |
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
    - directory-capability writer with locking, ordered sync, uncertain-writer
      poisoning, and bounded repair policy;
    - crash campaign joining durable publication to destructive transition
      ordering.
11. ResourceBank/LeaseTree reacquisition without duplicated ownership.
12. Paged-KV restore with foreign-generation rejection.
13. End-to-end process restart between two token publications.

Promotion gate: byte-identical continuation of the selected deterministic mode,
no duplicated output, no orphaned ownership, and crash coverage at every durable
phase.

The current capsule, resolver, bundle, store, lifecycle receipts, collection
plan, sweep journal, sweep commit, and body/footer evidence record form identity,
least-authority lookup, canonical planning, bounded payload ownership, a
deterministic destructive in-memory boundary, and portable commit evidence—not
a saved session. The record exposes the order a future writer must use, and its
pure classifier identifies complete and incomplete chain prefixes, but neither
writes, syncs, truncates, repairs, deletes, or recovers files. The fixture avoids
one 25-byte duplicate payload allocation and the commit fixture reclaims a
39-byte allocator tail, but lifecycle metadata, fixed index, and backing
capacity remain larger than those deltas. No lower RSS, disk use, or restart
latency is claimed. Those require compact index experiments, durable integration,
ownership reacquisition, and complete physical measurements.

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

- expand tiny legal fixtures before adding large model downloads;
- separate architecture parsing from tensor naming;
- add tokenizer normalization and special-token conformance;
- report an explicit compatibility matrix generated from tests;
- validate quality and exact-output modes independently.

Promotion gate: every listed combination has a retained fixture, clear failure
for unsupported inputs, and reproducible generation instructions.

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
| Object Fabric | Prototype (atomic in-memory sweep) | Tenant-safe content-addressed model, plan, KV, continuation, and evidence objects |
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
- capability-scoped durable sweep writer and recovery across every publication
  crash point;
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
