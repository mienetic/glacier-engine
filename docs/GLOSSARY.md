# Glossary

**Claim** — A typed declaration of logical resources a request needs before it
can execute.

**Commitment** — A digest or structured identity binding exact state. It proves
identity only within its verification contract.

**ContinuationCapsule** — A fixed-size manifest that binds a committed AI
checkpoint to typed external model, plan, resource, scheduling, KV, sampler,
output, and publication objects without embedding their payloads or granting
resume authority.

**Continuation object resolver** — An allocation-free lookup state machine that
admits exact capsule objects under a tenant-scoped grant and bounded catalog,
object, total-byte, and resolution limits.

**Continuation bundle** — A fixed manifest joining one capsule and nine semantic
object roots to tenant-bound storage blob roots and canonical deduplication
ordinals without embedding payloads or granting storage authority.

**Blob ordinal** — The deterministic first-occurrence number assigned to equal
tenant-bound payload bytes in a continuation bundle. It describes a storage
plan, not a live object handle.

**Capability grant** — A least-authority declaration of the exact identity,
scope, operations, and resource ceilings a trusted boundary permits. Its digest
binds the declaration but is not authentication by itself.

**ContextPack** — A lossless mapping that emits one copy of explicitly
idempotent, byte-identical rendered spans while retaining every logical span
decision.

**DecodePlan** — A validated description of static execution work and layout
identity prepared before token execution.

**Evidence join** — A compact manifest that binds already verified roots from
several evidence planes without duplicating their payloads.

**Fail closed** — Rejecting an operation when identity, support, capacity, or
evidence is uncertain instead of choosing an implicit fallback.

**GLRT** — Glacier native runtime image. A derived, execution-layout-bound file
with the `.glrt` extension.

**Lane** — One independently tracked request position in a scheduled execution
wave.

**LaneWeave** — Glacier's deterministic admission and weighted service scheduler.

**LeaseTree** — A hierarchy that subdivides one ResourceBank receipt into exact
child ownership and publication scopes.

**Logical accounting** — Runtime-owned counters derived from declared state. It
does not by itself prove RSS, device residency, energy, or physical isolation.

**Machine envelope** — Captured host, software, load, power, and telemetry
conditions attached to benchmark evidence.

**Paged KV** — A key/value cache whose committed sequence is represented by
explicit logical pages, generation-fenced ownership, and a canonical root.

**Prepared image** — A `.glrt` artifact whose layouts and integrity are validated
before execution.

**Provider evidence** — Credential-free records describing request identity,
transport events, usage settlement, cost, and durable journal state.

**Publication** — The moment prepared KV, RNG, sampler, and output state becomes
visible as one committed transition.

**Receipt** — A generation-fenced proof that a specific operation was admitted or
committed under a particular runtime state.

**ResourceBank** — The exact logical admission and ownership ledger shared by
scheduling and publication.

**Root** — A canonical digest over a state or event chain. Roots are meaningful
only with their ABI, domain, and replay rules.

**Settlement** — Terminal reconciliation between a reserved provider request and
the authoritative usage outcome supplied by a transport adapter.

**Token transaction** — A prepare/commit/abort protocol for one token's KV, RNG,
sampler, output, and ownership mutations.

**Wire** — A versioned, explicitly encoded byte representation designed for
independent verification.
