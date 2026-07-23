# Glacier Engine Design

Glacier is designed around one rule: speculative AI computation may fail or be
discarded, but visible state and resource ownership must change through an exact,
verifiable commit.

This document defines the design invariants. For component orientation, start
with [Architecture](ARCHITECTURE.md).

## Design goals

1. Bound resources before execution begins.
2. Make scheduling decisions deterministic and replayable.
3. Publish KV, RNG, sampler, and output state atomically.
4. Keep file, wire, and event identities portable across processes and languages.
5. Reject stale, foreign, malformed, unsupported, or over-capacity work.
6. Separate credential-free state machines from network and secret authority.
7. Treat evidence and claim scope as part of the architecture.
8. Permit backend and representation research without weakening the checked path.

## Non-goals today

Glacier does not yet promise a stable public API, broad model compatibility,
production-grade sandboxing, universally lower token bills, or a general
performance advantage. The weight pager is not yet the generation path, live
provider adapters are not in core, and logical ledgers are not physical resource
measurements.

## Request lifecycle

Every request follows four conceptual phases:

```text
describe → admit → prepare → publish
              │        │         │
              └ reject ┴ abort ───┘
```

### Describe

The caller binds model, tokenizer, execution policy, randomness, resource claim,
and isolation identity. Defaults may fill ordinary options, but an option marked
`required` never silently falls back.

### Admit

`ResourceBank` checks the complete logical claim before executor, KV, frame,
logit, or output allocation. A successful admission creates a receipt fenced by
bank epoch, slot generation, owner identity, and integrity fields.

`LaneWeave` evaluates schedulability and creates bounded request state. Deadline
or capacity rejection cannot partially mutate the bank or queue.

### Prepare

Execution creates provisional results under one service permit. Paged work may
reserve page leaves and stage a new page-map root. No output callback or durable
consumer can observe provisional state.

### Publish

A trusted finalizer validates every identity again and atomically commits the
prepared transition. It consumes its one-use authority before another scheduler
mutation. Failure preserves the previous committed state.

After commit, a continuation manifest may bind the resulting state. It is an
identity/export boundary, not another publisher: it cannot mutate the live
session or make provisional state durable.

## Core invariants

### Identity is explicit

Reusable objects carry generations or epochs. Model content, execution ABI,
layout, request, attempt, provider domain, and evidence envelope use distinct
domain-separated identities. Two objects with equal payload hashes are not
interchangeable when their authority or semantic domain differs.

### Ownership precedes mutation

An allocator pointer does not prove ownership. ResourceBank and LeaseTree bind the
right request, scope, quantity, and lifecycle before a page or output becomes
part of a published state.

### Publication is all-or-nothing

A token proposal binds:

- resource receipt and publication permit;
- scheduling intent and service sequence;
- execution ABI and request epoch;
- KV before/after state or paged root transition;
- RNG before/after state;
- sampler-call count;
- output before/after position and token.

The sink acknowledges the prepared state before commit. A mismatched
acknowledgement, mutated proposal, stale permit, or failed sink rejects without a
partial visible transition.

`ContinuationCapsule v1` then binds nine typed objects under the exact execution,
request, publication, token-count, challenge, and parent-checkpoint identity. It
stores roots and lengths rather than copying model or KV payloads. Resume
authority remains external and must verify every referenced object.

The continuation resolver narrows that external authority to one tenant scope,
capsule root, request epoch, object-kind mask, and explicit catalog/object/total
limits. Equal content under another tenant is not interchangeable. Successful
lookup returns bytes into caller-owned storage, but those bytes remain
non-authoritative until all nine outputs pass the final capsule composition
check and live resource ownership is reacquired.

The continuation bundle adds a storage-plan identity without merging semantic
roles. Equal bytes can share one tenant-bound blob ordinal while model,
tokenizer, plan, KV, and other typed roots remain distinct. Bundle totals are
logical evidence; they do not become physical allocation claims until a store
reports its payload, index, metadata, cache, and platform overhead.

The in-memory store makes that distinction executable. Payload ownership changes
only after every quota and identity check, while a fixed reverse-action journal
keeps bundle import all-or-nothing across allocator failure. Equal tenant blob
identity can reuse payload allocation, but semantic references remain counted
individually. Quarantine retains evidence without authorizing reads or claiming
repair. The lifecycle layer adds explicit-tick leases without importing a clock:
acquire and renewal bind owner, deadline, capability, and increasing generation;
release and expiry require the exact current receipt. Quarantine fences that
receipt, while repair needs a separately scoped target/reason/source grant and a
fresh content-root check before it can restore live state.

Collection eligibility is also an explicit evidence transition. The caller may
retire only a live, unleased final reference, which preserves its bytes at zero
semantic references. A dry-run plan must then match the exact audit snapshot,
the complete semantic-root multiset, and the complete set of current lease
receipts. Every non-retired slot's presented root multiplicity must equal its
reference count; every active lease must have exactly one current receipt.
Missing evidence rejects rather than reclassifying live data as collectible.
Quarantined data is always retained. Successful planning writes a canonical
decision for every occupied slot but never frees bytes or mutates the store.

Sweep staging adds another explicit authority boundary. A grant must pin the
exact store, snapshot, reviewed collection-plan root, and staging ceilings.
Prepare regenerates the plan from the original root and lease evidence instead
of trusting a copied receipt. It returns a new immutable-style journal value
only when the regenerated plan and snapshot match. Abort likewise returns a new
value only while the store snapshot remains unchanged. Neither transition
mutates the input journal or grants deallocation authority.

Destructive sweep commit requires a second capability binding that exact sweep
grant, prepare root, snapshot, plan, and smaller-or-equal removal ceilings. The
plan is regenerated again, every derived target and all before/after counters
are validated, and only then may the store enter a no-failure mutation suffix:
free exact payloads, clear their fixed slots, and assign precomputed accounting.
The receipt distinguishes logical payload/index release, allocator `free` call
count, and post-state identity. It does not equate any of them with RSS,
durability, secure erase, or crash-atomic execution.

### State machines fail closed

Named errors are preferable to implicit recovery when the correct alternative is
uncertain. Retrying is allowed only when the state machine records whether the
prior attempt was unstarted, retryable, ambiguous, or terminal.

### Verification is independent of presentation

Encoders, stateful verifiers, and human-readable renderers are separate. A UI or
log line cannot turn unverified bytes into verified state. Portable evidence uses
explicit little-endian encoding rather than in-memory struct layout.

## Resource model

ResourceBank currently covers exact logical counters declared by the runtime.
LeaseTree subdivides a parent receipt into allocation and publication scopes.
The target resource model adds external observations without conflating them:

```text
logical receipt ──┐
allocator ledger ─┼─> reconciled evidence bundle
process RSS ──────┤
device residency ─┤
I/O / energy ─────┘
```

Each plane names its observer, units, time interval, and missing-data state.

## Scheduling model

LaneWeave uses deterministic weighted service over a bounded set of live
requests. Admission projects deadlines and resources before mutation. Service
permits bind the selected request and scheduling state; prepared commit/abort is
linearized, and event replay reconstructs accepted, rejected, serviced,
cancelled, retired, and final-zero states.

The next serving layer must retain these properties while adding unequal prompts,
continuous refill, tenant isolation, bounded drain, and heterogeneous workers.

## Memory and KV model

Contiguous KV remains the general baseline. Paged KV introduces:

- fixed logical page geometry;
- lazy payload allocation;
- cache instance and ownership generation;
- before/after canonical page-map roots;
- row-level preparation and commit;
- optional LeaseTree-backed page leaves and early terminal-lane reclamation.

Weight paging is a separate subsystem. It must not reuse KV terminology to imply
integration or resource evidence it does not have. See [Paging](PAGING.md).

## Provider model

Provider operations use the same describe/admit/prepare/publish pattern:

1. ContextPack produces a lossless logical-to-emitted mapping.
2. An adapter observes tokens on the exact rendered wire.
3. The gateway reserves a conservative ceiling and may coalesce exact requests.
4. The transport records ordered chunks, cancellation, and terminal usage.
5. Settlement reconciles known or unknown usage without converting unknown to
   zero.
6. Cost wires apply an effective-dated integer price table.
7. The journal durably commits body then footer and replays a valid prefix.
8. The evidence join binds the selected cost, gateway, and transport roots.

The core receives no credentials and stores no prompt text. Live adapters must
remain outside that boundary.

## Model and execution images

The draft `.glacier` model format is range-readable and representation-oriented.
The `.glrt` native image is derived for an execution ABI, architecture policy,
and exact stream layout. Writers publish v2 images atomically by same-directory
replacement after validation and hashing. Readers check structure, geometry,
identity, overlap, CRC, and record digests before returning typed views.

Unkeyed hashes provide integrity, not distributor authenticity. Signed manifests
and rollback policy remain future work.

## Adaptive execution axes

Future immutable plans may coordinate:

| Axis | Decision |
| --- | --- |
| W | weight presence and tier |
| P | precision and representation |
| D | draft depth and exact verification |
| E | expert choice and placement |
| N | neuron-block execution and replay |
| K | KV precision, ownership, and tier |
| B | batch, lane, and backend |
| A | activation lifetime and rematerialization |
| C | communication topology and credits |
| O | vocabulary domain, sampler, and output publication |

These axes are a target planning vocabulary, not a statement that one production
path implements all of them. Any approximate or selective path must preserve an
exact fallback or verifier and spend an explicit quality/resource budget.

## Extension rules

New backends, tokenizers, planners, storage engines, and provider adapters should
negotiate a minimal capability set before receiving authority. Capability records
must cover shape, dtype, layout, numerical contract, cancellation, resource
limits, and evidence output.

An extension must not:

- access credentials through core state;
- reinterpret an existing ABI or reserved byte;
- publish output outside the transaction boundary;
- claim resources it cannot observe;
- silently choose a weaker path when a strict policy is requested.

## Acceptance rules for architecture work

An isolated prototype can merge when its ABI is explicit, valid behavior is
deterministic, named malformed states reject, and the claim stays at conformance
level. It becomes integrated only when a real path consumes it, and validated
only after the evidence matrix in [Benchmarks](BENCHMARKS.md) passes.

This separation lets contributors land useful foundations without pretending
the entire destination already exists.
