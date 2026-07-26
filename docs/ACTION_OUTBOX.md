# ActionOutbox Record and Recovery Protocol

Status: W4b-b portable record contract, W4b-c descriptor-relative POSIX
durable store, plus the W4b-d portable adapter contract, ordering driver, and
bounded fixed-storage same-process fake dispatch/status authority. This is not
a live network, provider, or tool adapter.

## Purpose

`ActionOutbox-v1` turns an authorized proposal into recoverable intent without treating an external effect as rollback.
After a process stop, its history must establish:

1. which exact action was authorized;
2. whether dispatch was permitted to begin;
3. whether the external outcome is known or ambiguous; and
4. which evidence permits a terminal decision or another attempt.

The outbox never infers provider state from local phase, elapsed time, transport failure, or an absent response.

## Proposal and authorization composition

Proposal and authorization remain separate records and authorities.

- The proposal selects descriptor, arguments, tenant, agent request, and
  idempotency identity.
- Authorization records allow or deny for one exact proposal digest under one
  exact policy record.
- A proposal cannot grant itself authority.
- Authorization cannot rewrite proposal content.
- Only an allowed authorization with exact proposal digest and identity matches may compose into an outbox action.
- Denied or mismatched authorization cannot create `ready`.
- Composition grants no dispatch authority until the complete `ready` frame is committed.

The enqueue constructor validates the complete descriptor, arguments, proposal,
policy, and allowed authorization before it seals an action identity. The
journal stores their roots. Recovery verifies that sealed identity and its
append-only transitions; it does not recreate policy authority from hashes
alone.

## Canonical encoding

The format is explicit bytes, never an in-memory struct ABI.

- Integers are fixed-width little-endian.
- Digests are 32-byte SHA-256 with named domain separation.
- Enum and record-kind values are pinned by version.
- Reserved bytes are written and read as zero.
- No pointers, file descriptors, allocator state, or host paths are serialized.
- Header and record decoders require exact canonical lengths. Journal recovery
  separately classifies an incomplete final frame.
- Readers reject unknown required flags, invalid enum values, and arithmetic
  overflow.

Every journal starts with one fixed-size 320-byte `HeaderV1`:

| Field | Meaning |
| --- | --- |
| magic, ABI, length, flags | pinned format and zero optional flags |
| outbox epoch and ID | journal identity |
| tenant key | policy domain for every enqueued action |
| action and record limits | fixed caller-storage bounds |
| maximum payload bytes | bound checked by action construction |
| capability bits | adapter contract requires stable idempotency and authoritative reconciliation |
| adapter descriptor | remote adapter identity |
| payload-store descriptor | durable payload namespace identity |
| challenge and header root | caller-pinned journal identity |
| reserved | zero-filled forward-compatibility bytes |

Each event is a 704-byte canonical body followed by a 48-byte commit footer.
The body repeats the sealed action identity and binds event sequence, kind,
attempt generation, previous action event, previous journal record, dispatch
request, observation, result, and record root. Different magic, ABI, pinned
length, chain, or reserved bytes are invalid. Version 1 never guesses a newer
layout.

## Body-first durable commit

The durable store appends a frame in two observable phases:

1. append the complete canonical body;
2. append the fixed-size commit footer for exactly those bytes.

The footer repeats the sequence and record root. Only a complete, matching
footer commits the body.

The portable core exposes the body and footer as a two-slice append plan. Before
I/O, `ApplyPlanV1` validates the complete lifecycle transition without mutating
caller state. The POSIX store then writes the body, synchronizes the file,
writes the footer, synchronizes again, verifies the namespace and exact bytes,
and only then applies the infallible in-memory plan. Any uncertain append error
poisons the local store and blocks journal, record, and state views until close
and fresh reopen.

A clean committed file or committed prefix remains exactly:

```text
320-byte HeaderV1 + N × 752-byte RecordV1
```

There is no filesystem envelope, mutable sidecar, or hidden trailer.
During body-first append or incomplete-tail recovery, the observed file may
temporarily include an additional uncommitted suffix of 1–751 bytes.

## Descriptor-relative POSIX store

The caller supplies an already opened trusted directory and one validated leaf
name. The adapter:

- opens relative to that directory with no-follow and close-on-exec behavior;
- acquires one exclusive advisory file lock;
- accepts only a regular, one-link file and, by default, private permissions;
- compares descriptor and directory-entry device/inode identity;
- rejects namespace replacement, size drift, and exact-byte drift around
  publication and repair;
- synchronizes a new header before synchronizing the containing directory; and
- reads and replays the complete bounded stream through caller-provided
  storage.

`ContentSnapshotV1` binds the exact observed stream, declared capacity, recovery
classification, committed prefix, state, and ledger. `LeaseBindingV1` binds one
process-local lease generation to that snapshot and outbox epoch.
`RepairPlanV1` binds repair authority to one classified incomplete suffix.
These SHA-256 roots are integrity commitments, not authenticated bearer
credentials.

The live `StoreV1` value owns its file descriptor and is a single-owner,
single-mutator handle. Callers must not copy it or use concurrent copies.

Repair is explicit and truncate-only. It is available only for the three
incomplete-tail classifications, verifies the complete observed snapshot before
truncation, synchronizes and verifies the committed prefix, then leaves the
store in `repair_complete`. Append authority returns only after close, fresh
exclusive reacquisition, and full replay.

## Bounded same-process dispatch and status

W4b-d adds a credential-free sidecar contract without changing the 320-byte
header, 752-byte records, event kinds, replay rules, or `StoreV1` format.
Its pointer-free values bind:

- one public adapter descriptor and authority epoch to the descriptor root
  already pinned by the outbox header;
- one dispatch request to the exact committed intent, stable request,
  idempotency key, attempt generation, payload identity, and dispatch root;
- dispatch evidence to that request, authority revision, disposition, service
  event, and terminal result when present;
- one separate status request to the currently uncertain attempt; and
- status evidence to the same adapter epoch and an authoritative disposition.

The process-local adapter boundary is an opaque context plus dispatch and
status callbacks. Credentials may exist only behind that boundary; they are
not fields of the portable descriptor, request, evidence, transition, record,
or recovery state. The public namespace and schema roots must not be derived
from credentials. Evidence hashes commit to byte identity but do not
cryptographically prove who produced a callback.

The driver first durably appends the exact next-generation
`dispatch_intent`. That successful append is the callback-invocation
linearization point: no adapter code runs before it. A callback error, invalid
evidence, or failure to append the resulting acknowledgement leaves the
committed action recoverably `uncertain`; none grants retry authority.
The lower-level contract constructors and callback wrappers validate hashes
and composition only; they cannot prove a store commit or authoritative
replayed state. The intent-before-callback and status-from-uncertain guarantees
apply to the driver entry points, not to direct low-level callback invocation.

The bounded fake authority retains stable-request state in caller-provided
fixed storage. A status result of `not_applied_fenced` atomically fences the
queried generation `G` before it can authorize the existing
`reconciled_not_applied` transition. A delayed dispatch at generation `G` or
earlier is then rejected. The next dispatch is exactly generation `G + 1`,
retains the stable request and idempotency identity, and derives a new dispatch
root. `pending`, `unknown`, plain absence, timeout, and transport or callback
failure remain uncertain and cannot authorize another attempt.

## Record kinds

| Kind | Required content |
| --- | --- |
| `enqueued` | proposal/auth roots, payload identity, stable request root |
| `dispatch_intent` | preceding action-event root, local attempt generation, derived dispatch-request root |
| `ambiguity_observed` | exact intent and opaque ambiguity evidence |
| `acknowledged_success` | exact intent, response evidence, and result root |
| `acknowledged_failure` | exact intent, terminal evidence, and result root |
| `reconciled_not_applied` | reconciliation classification returning action to `ready` |
| `reconciled_success` | reconciliation classification closing as `succeeded` |
| `reconciled_failure` | reconciliation classification closing as `failed` |

Every transition cites the preceding action-event root. Forked, skipped,
reordered, or cross-action transitions are invalid.

## Action phases

| Phase | Meaning |
| --- | --- |
| `ready` | authorized and committed; no unresolved dispatch intent |
| `uncertain` | dispatch may have begun; application may or may not exist |
| `succeeded` | a committed acknowledgement or reconciliation record classifies success |
| `failed` | a committed acknowledgement or reconciliation record classifies terminal failure |

The intent record moves `ready` to `uncertain`. The W4b-d driver commits that
record before its same-process fake adapter callback; there is no `sent` phase
to hide the ordering boundary. Live external dispatch remains outside this
slice.

Timeout, disconnect, partial response, process stop, or adapter crash remains `uncertain`. Terminal phases never reopen.

## Stable remote request

The stable semantic request digest binds the header identity, pinned adapter
descriptor, complete action-identity digest, and idempotency-key digest. The
action identity transitively binds the descriptor, arguments, proposal,
policy, authorization, tenant-scoped header, service event, purpose/parent, and
payload locator/length/digest.

Attempt generation is excluded from the stable request digest; it orders local
evidence only. Version 1 defines no serialized remote-request bytes.

The record derives a distinct dispatch-request root from the stable request and
attempt generation. Future transport envelopes may add adapter metadata, but
cannot change the stable request or idempotency identity.

## Payload binding

An action stores a payload-locator digest, exact length, and payload SHA-256;
it stores neither locator bytes nor a pointer or host path.

Before dispatch, a future adapter must accept canonical locator bytes whose
digest matches the action, resolve them through the pinned payload-store
descriptor, and verify exact payload length and digest. The portable record
core binds only those digests and the length; it has no locator wire or blob
resolver.

A future store must retain payloads for live phases and promised terminal
replay. Object-store integration is a later slice.

## Acknowledgement versus reconciliation

These are different evidence:

- An acknowledgement arrives on one attempt's response path and binds its exact dispatch intent.
- Reconciliation is a separate authoritative lookup by stable request identity after an outcome became ambiguous.
- Cached acknowledgement cannot be relabeled as reconciliation.
- Socket completion, local counters, status code alone, or local-cache absence is not reconciliation.
- Both record an adapter classification and opaque nonzero evidence digest.
  The portable core cannot authenticate that digest or invent provider truth.

The bounded fake authority classifies response and status evidence through a
trusted same-process callback before the driver appends these record kinds.
Positive acknowledgement may support `succeeded`; a permanent negative may
support `failed`. A future live adapter must establish its own authenticated
origin and authoritative service semantics.

The state machine returns from `uncertain` to `ready` only for a committed
`reconciled_not_applied` record. In the W4b-d driver, only validated
`not_applied_fenced` status evidence for the exact attempt can produce that
record. The portable record rule and evidence hashes alone do not prove an
external lookup was authoritative.
Before dispatch, the driver protects one future reconciliation slot for every
existing uncertain action and requires three additional slots for the new
intent, immediate observation, and possible reconciliation. Status runs only
when the remaining slots can cover every uncertain action. This prevents
driver-only multi-action admission from overcommitting the bounded journal;
direct store appends remain caller discipline.
`reconciled_success` closes as `succeeded`; `reconciled_failure` closes as
`failed`. Pending or unknown observations do not create a terminal or
safe-retry record and therefore leave the committed action `uncertain`.

## Compensation

Compensation never rewrites or erases the parent action. It is a new child with:

- its own proposal and matching authorization;
- its own idempotency identity;
- its own payload-locator digest, length, and payload digest;
- an immutable parent-action link; and
- its own complete `ready` → `uncertain` → terminal lifecycle.

Enqueue succeeds only while replay shows that primary parent in `succeeded`;
the child does not store a separate terminal-evidence root. Child failure or
ambiguity does not alter the parent's terminal phase.

## Recovery

Recovery starts at offset zero and accepts one contiguous committed prefix.
An incomplete suffix receives one classification:

| Classification | Handling |
| --- | --- |
| `clean` | bytes end at an exact committed boundary |
| `short_body_tail` | incomplete uncommitted tail; explicit repair possible |
| `body_without_footer` | complete body with no footer |
| `partial_footer_tail` | complete body plus incomplete footer |

Complete frames with invalid encoding, footer, digest, sequence, chain, or
lifecycle are errors rather than tail classifications. Recovery never searches
ahead for magic or resynchronizes. Bytes after the first fault are untrusted.

Recovery reports the exact committed boundary and discarded suffix. The
portable core never truncates. The POSIX store grants explicit repair only for
the three incomplete-tail classes, then requires close, reopen, and full
recovery before append. Complete invalid frames, chain mismatches, and invalid
transitions never receive repair authority.

## Required invariants

The record and durable-store gates must prove:

1. native and independent oracle bytes and roots match on the development host;
2. proposal/auth mismatch never produces `ready`;
3. body without footer is invisible as committed state;
4. every retained cut from a complete header through the reference journal
   recovers the same valid prefix or a precise tail class;
5. corruption never causes forward resynchronization;
6. dispatch intent affects replay only with a complete matching footer;
7. `uncertain` cannot retry without `reconciled_not_applied`;
8. attempt generation cannot alter the stable remote request;
9. payload identity substitution or an out-of-bounds length fails before intent;
10. compensation is a separately authorized child action;
11. recovery exposes the exact boundary required by explicit repair;
12. terminal actions cannot reopen;
13. all 40 ordered append-phase cases, 754 section-prefix cases, 751
    incomplete tails, and 8 repair-fault outcomes agree between Zig and the
    independent Python model; and
14. 49 real host process deaths—3 initialization, 40 append, and 6 repair
    deaths—reopen to the exact committed prefix and converge to the same final
    semantic state;
15. the W4b-d driver invokes no adapter callback until its exact dispatch
    intent is durably committed;
16. only `not_applied_fenced` status evidence for generation `G` maps to
    `reconciled_not_applied`, while pending, unknown, and plain absence do not;
17. the fake authority rejects delayed dispatch at generation `G` or earlier
    after fencing, and retry advances exactly to `G + 1` with the same stable
    request and a new dispatch root;
18. portable adapter values contain neither pointers nor credential fields;
    and
19. an independent standard-library Python model rebuilds the adapter roots,
    transition mapping, fence ordering, terminal replay, and credential
    noninterference cases.

## Nonclaims

W4b-d is a bounded fixed-storage, same-process fake dispatch/status authority.
It performs no network, provider, or tool effect and uses no real credentials.
Its opaque callback boundary is API separation, not an OS sandbox, process
isolation, hostile-code security proof, or cryptographic proof of evidence
origin. The fake service has no restart-persistent authority state. This slice
adds no new process-death, multi-platform, performance, power-loss, or external
exactly-once evidence. Live and provider-backed integration remains planned.

The current durable adapter is POSIX-only; a Windows durable-file adapter is
not implemented. Its locks are advisory and coordinate cooperating processes,
not distributed or hostile writers. The retained `SIGKILL` campaign proves
ordered host filesystem calls and fresh-process recovery on the development
host. It does not emulate storage-device power loss, establish native behavior
on another operating system, or claim filesystem latency, throughput, energy,
or production reliability. Hashes prove byte identity and ordering, not that a
reported external effect occurred.

## Verification

The retained W4b-b/c ActionOutbox gates are:

```sh
tools/zig-with-ephemeral-cache.sh build action-outbox-record-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

# Durable model/oracle plus the 49-process-death POSIX campaign
tools/zig-with-ephemeral-cache.sh build action-outbox-recovery-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

# Independent deterministic storage-model tests
python3 -m unittest bench.tests.test_action_outbox_store_conformance
```

The bounded same-process W4b-d gate is:

```sh
tools/zig-with-ephemeral-cache.sh build action-outbox-dispatch-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The recovery command is correctness evidence and may take longer because it
spawns and terminates 49 workers. See
[Typed Tool Workload](TYPED_TOOL_WORKLOAD.md),
[Architecture](ARCHITECTURE.md), and [Roadmap](ROADMAP.md) for the surrounding
boundaries and contributor order. W4b-d adds bounded contract, driver,
fake-authority, durable append-fault integration, and independent Python model
coverage, including a live canonical Zig-to-Python report comparison. It does
not add a retained JSON fixture, process-death campaign, or
platform/performance matrix.
