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

**Continuation object store** — A bounded, bundle-scoped in-memory store that
owns immutable tenant blob payloads, reuses duplicate references, accounts
payload/index/lifecycle state, and rolls partial imports back.

**Continuation object lifecycle** — Explicit-tick acquire, renew, release,
expiry, quarantine-fence, and repair transitions bound to separate
tenant/bundle/store capabilities and generation-fenced receipts.

**Continuation object collection plan** — A bounded dry-run classification of
every occupied store slot against one exact snapshot, complete semantic-root
multiplicity, and complete current-lease coverage. Its evidence root grants no
deallocation authority.

**Continuation object sweep journal** — A caller-owned functional state value
whose prepare transition regenerates one separately approved collection plan
and whose abort transition requires the pinned snapshot to remain current. It
stages exact totals but grants no commit or deallocation authority.

**Continuation object sweep commit** — A separately authorized in-memory
transition that regenerates one prepared plan, validates a canonical set of
retired targets before mutation, deallocates exactly that set, and binds exact
before/after store accounting into verifiable receipts. It does not imply
durability, secure erase, or lower process RSS.

**Continuation object sweep record** — A fixed pointer-free body/footer wire
that carries one sweep commit's chain position and enough canonical fields to
reconstruct and verify its grant and receipts. Its ordered append plan grants no
filesystem, deletion, recovery, or durability authority.

**Sweep recovery classifier** — A pure anchored scan of concatenated sweep
records that returns the semantically verified committed prefix and a named
clean, incomplete-body, incomplete-footer, or corrupt status. Classification is
evidence only and grants no truncation, repair, deletion, or filesystem
authority.

**Sweep publication capability** — A snapshot-bound exclusive operation view.
Its append form exposes only ordered body/footer write and sync; its separately
requested repair form exposes only truncate and sync for an explicitly
classified incomplete tail. Neither form grants payload deletion authority.

**Poisoned writer** — A process-local writer or repairer that observed an
uncertain I/O result and therefore rejects reuse until storage is reacquired,
read again, and reclassified under a fresh snapshot.

**Directory capability** — An already opened directory descriptor passed as
bounded namespace authority. Glacier combines it with one validated component
name; it is not permission to resolve arbitrary absolute paths or traverse
descendant directories.

**Process-death recovery** — Fresh acquisition and verification after the
publishing process terminates. It proves lock release and host page-cache/file
semantics for the observed run, but does not emulate device power loss.

**Retired entry** — A retained store payload with zero semantic references and
no active lease. It is eligible for a future separately authorized sweep only
after an exact collection plan classifies it as collectible.

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

**Object lease receipt** — A commitment to one blob, owner, retained generation,
explicit expiry tick, and lifecycle grant. It is valid only while every field
equals the active store slot.

**Repair receipt** — A commitment joining a repaired blob, repair generation,
declared source, prior quarantine reason, repair grant, and resulting store
snapshot.

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
