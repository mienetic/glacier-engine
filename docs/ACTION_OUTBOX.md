# ActionOutbox Record and Recovery Protocol

Status: W4b-b portable record contract. This is a canonical record and
recovery boundary, not a live dispatcher or durable file adapter.

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

## Body-first commit

A future store appends a frame in two observable phases:

1. append the complete canonical body;
2. append the fixed-size commit footer for exactly those bytes.

The footer repeats the sequence and record root. Only a complete, matching
footer commits the body.

The portable core exposes the body and footer as a two-slice append plan. It
does not write or sync either slice. Poisoned-writer, repair authority,
file-lock, and sync rules belong to the next store-adapter slice.

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

The intent record moves `ready` to `uncertain`. A future dispatcher must commit
that record before external work; there is no `sent` phase to hide a
termination window, and this slice has no dispatcher.

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

A future adapter is responsible for authenticating response and status evidence
before appending these record kinds. Positive acknowledgement may support
`succeeded`; a permanent negative may support `failed`.

The state machine returns from `uncertain` to `ready` only for a committed
`reconciled_not_applied` record. That structural rule does not prove the
external lookup was authoritative.
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

Recovery reports the exact committed boundary and discarded suffix. This core
does not truncate. A future store may grant explicit repair only for the three
incomplete-tail classes, then require close, reopen, and full recovery before
append. Complete invalid frames, chain mismatches, and invalid transitions
must never receive repair authority.

## Required invariants

The record tests must prove:

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
11. recovery exposes the exact boundary required by explicit repair; and
12. terminal actions cannot reopen.

## Nonclaims

W4b-b provides no live network, process, filesystem, device, credentials,
sandbox, provider integration, or provider truth. It performs no external
reconciliation or compensation and provides no external exactly-once delivery.

It also provides no `fsync`, actual durable file adapter, truncation authority,
cross-machine consensus, distributed lease, credential store, or live I/O.
Hashes prove byte identity and ordering, not that a reported external effect
occurred.

## Verification

The record implementation exposes:

```sh
tools/zig-with-ephemeral-cache.sh build action-outbox-record-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Later slices should add separate gates:

```sh
# planned: durable adapter and recovery
tools/zig-with-ephemeral-cache.sh build action-outbox-recovery-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

# planned: credential-free fake dispatcher
tools/zig-with-ephemeral-cache.sh build action-outbox-dispatch-harness-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The record gate lands before any live adapter. See
[Typed Tool Workload](TYPED_TOOL_WORKLOAD.md),
[Architecture](ARCHITECTURE.md), and [Roadmap](ROADMAP.md) for the surrounding
boundaries and contributor order.
