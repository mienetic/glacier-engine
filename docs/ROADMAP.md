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

1. Canonical in-memory continuation identity.
2. Mutation-complete verifier fixtures.
3. Atomic file publication and recovery state machine.
4. Paged-KV restore with foreign-generation rejection.
5. End-to-end restart between two token publications.

Promotion gate: byte-identical continuation of the selected deterministic mode,
no duplicated output, no orphaned ownership, and crash coverage at every durable
phase.

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
