# Architecture

Glacier Engine separates AI computation from the authority to consume resources
and publish state. Computation may be speculative; externally visible state is
not.

## Component map

| Layer | Primary components | Responsibility |
| --- | --- | --- |
| Model | `.glacier`, `.glrt`, loader, prepared model | Validate source and execution layouts before use |
| Execution | CPU kernels, optional Metal backend, DecodePlan | Produce candidate activations, KV rows, and tokens |
| Resource | `ResourceBank`, `LeaseTree` | Reserve exact logical capacity and track ownership |
| Schedule | `LaneWeave` | Admit requests and issue deterministic service permits |
| State | contiguous/paged KV, token transactions | Prepare and atomically publish AI-visible state |
| Continuation | capsule, resolver, bundle, store | Bind a checkpoint, admit tenant objects, plan deduplication, and own bounded payloads |
| Provider | context pack, gateway, transport harness | Reconcile tokens, coalesce work, cancel, and settle usage |
| Durability | settlement/cost wires, cost journal | Commit replayable cost evidence across process failure |
| Evidence | event wires, join roots, Python verifiers | Reconstruct and reject malformed or substituted history |

## Local execution flow

```text
validated model + request
          │
          ▼
   derive exact claim
          │
          ▼
 ResourceBank admission ──reject──> no resource mutation
          │ receipt
          ▼
 LaneWeave admission ─────reject──> release receipt
          │ service permit
          ▼
 speculative execution
          │ prepared KV/RNG/output
          ▼
 publication transaction ─abort───> no visible mutation
          │ commit
          ▼
 new KV root + RNG + counters + output + receipt
          │
          ▼
 ContinuationCapsule ──> model/plan/resource/lane/KV/sampler/output roots
          │
          ▼
 bounded object resolver ──> verified caller-owned bytes; no live authority
          │
          └─ canonical bundle ──> tenant blob roots + dedup ordinals; no I/O
                       │
                       └─ bounded object store ──> owned bytes + references
```

### ResourceBank

`ResourceBank` accounts for declared logical quantities such as KV bytes,
activation bytes, scratch bytes, page slots, and operations. Admission returns a
generation-fenced receipt. Stale, mutated, foreign, or over-capacity receipts
fail before state changes.

`LeaseTree` subdivides one request receipt into exact child ownership. It is used
to connect physical KV page allocation and retirement to the parent resource
claim without treating process RSS as proof of ownership.

### LaneWeave

`LaneWeave` is a bounded control-plane scheduler. It combines exact admission,
weighted service, deadline projection, cancellation, and replayable events.
Prepared permits are single-purpose and fenced against stale address reuse.

### Token publication

A token transaction stages every AI-visible mutation:

- KV root or row transition;
- RNG state;
- sampling-call counter;
- output word;
- resource and scheduling commitments.

Preparation may fail without exposing partial state. Commit consumes the exact
permit and publishes the staged state once. Abort leaves the prior committed
root usable.

Paged variants add cache instance, logical page, ownership generation, and
before/after page-map roots. The LeaseTree-backed variant also binds allocation,
retirement, and request-wide publication authority.

### Continuation capsule

`ContinuationCapsule v1` is a 608-byte pointer-free manifest created after a
successful publication. Nine position-typed references bind model, tokenizer,
execution plan, ResourceBank state, LaneWeave state, KV state, sampler/RNG state,
output state, and publication receipt. Each reference hashes its ABI, exact
length, and payload under a distinct object-kind domain.

The manifest does not duplicate those objects and grants no resolver,
filesystem, allocator, scheduler, or output authority. A resume boundary must
supply the expected request/execution identity and exact object bytes; the full
verifier reconstructs the canonical manifest and rejects substitution. Parent
roots form explicit checkpoint lineage. Durable storage and live runtime restore
are the next layer, not an implied property of the manifest.

### Continuation object resolver

The in-memory resolver accepts one capsule, an exact authority epoch, a
tenant-scoped grant, a bounded immutable catalog, and caller-owned output
buffers. The grant limits object kinds, catalog entries, bytes per object, total
bytes, and resolution count. A lookup must match tenant, kind, ABI, exact length,
and typed digest; missing, corrupt, ambiguous, stale, repeated, cross-tenant, or
overlapping requests reject before accounting changes.

After all nine objects resolve, the resolver re-hashes every output and verifies
the complete capsule composition. It allocates nothing and has no filesystem,
network, ResourceBank, scheduler, or publication authority. The caller remains
responsible for authenticating the grant and retaining output buffers. Durable
bundle storage and live ownership reacquisition remain separate layers.

### Continuation bundle

The 1,136-byte bundle manifest joins one capsule with its nine object references.
Each entry retains the capsule's kind/ABI/length typed root and adds a
tenant-bound blob root plus canonical first-occurrence ordinal. Equal payload
bytes may therefore share one planned blob inside a tenant without collapsing
their semantic object kinds. The same bytes under another tenant produce a
different blob root.

The bundle records exact logical and unique payload totals but embeds no payload
and performs no storage I/O. It is a portable plan, not a store, lease, cache, or
proof of physical savings. The in-memory store is a separate capability boundary
that accounts payload ownership and metadata explicitly.

### Continuation object store

The bounded in-memory store is scoped by one authority epoch, tenant, bundle
root, operation mask, and entry/object/payload/index/reference limits. Its slot
index has fixed native capacity while exact payload bytes come from a
caller-supplied allocator. Import verifies the bundle and all objects first,
then applies at most nine reversible insert/reference actions. Any later quota or
allocation failure rolls the whole import back.

Equal tenant blob roots reuse one owned payload allocation and increment a
reference count. Reads re-hash and copy into caller-owned storage; the last
release frees the payload unless a generation-fenced lease is active. Acquire,
renew, release, and explicit expiry consume a separate lifecycle capability;
renewal advances generation so stale receipts reject. Quarantine clears active
lease authority. Repair requires a target-specific grant binding the tenant,
bundle, store grant, blob, quarantine reason, source identity, and byte ceiling,
then re-hashes candidate bytes before mutation. The store reports logical index
charge separately from native fixed-index and allocator capacity, so duplicate
payload avoidance cannot be misreported as net memory savings.

## Provider execution flow

```text
logical spans
    │
    ▼
ContextPack ──> mapping receipt + raw/packed token observations
    │
    ▼
Gateway ──────> exact reservation + optional request coalescing
    │
    ▼
Transport ────> chunks + terminal usage + cancellation outcome
    │
    ▼
Settlement ───> quote, authoritative usage, and cost wire
    │
    ▼
CostJournal ──> durable body/footer append and recovery
    │
    ▼
EvidenceJoin ─> compact manifest over verified roots
```

### Context packing and token reconciliation

Core does not tokenize or store text. Callers supply domain-bound span hashes,
token observations, and explicit idempotence declarations. The packer removes
only exact rendered duplicates that are safe to share and retains a decision for
every logical span. A provider-specific adapter can render and count exact wire
bytes outside core, then submit the reconciled observation for admission.

### Gateway and transport

The gateway admits an exact request identity and conservative token reservation.
Identical logical requests may share one physical dispatch while retaining their
consumer identities. Terminal provider usage authoritatively settles the
reservation. Cancellation distinguishes consumer withdrawal from active
transport cancellation.

The transport harness is deterministic and credential-free. It exists to test
chunk ordering, terminal usage, retry state, and cancellation semantics before a
live adapter is introduced.

### Durable provider evidence

The cost journal appends a body and a separate commit footer, syncing each phase.
Recovery accepts a complete valid prefix, can repair a short torn tail, and
rejects a complete invalid frame. Writers are poisoned after an uncertain append
and must be closed and reopened before reuse.

`ProviderEvidenceJoinWire` is a fixed 712-byte manifest over the selected cost
frame, gateway event, and transport outcome. Verification replays the supplied
nested evidence rather than trusting copied roots. The manifest contains no
dispatch, filesystem, or network authority.

## Identity and trust rules

1. On-disk and wire layouts are serialized explicitly; Zig struct layout is not
   an ABI.
2. Every reusable handle carries an epoch or generation.
3. A hash proves byte identity and chain integrity, not the truth of the original
   observation.
4. Logical resource accounting and operating-system/device measurements are
   separate evidence planes.
5. Provider core stays credential-free; live credentials belong in isolated
   adapters.
6. Unsupported combinations reject rather than silently downgrade.

## Portability

The portable core is Zig. AArch64 has specialized CPU kernels and macOS can use
Metal through a small Objective-C bridge. Cross-target test compilation covers
x86_64 and AArch64 Linux. Execution, numerical, and physical-resource validation
still require real machines for each promoted platform.

## Where to go deeper

- [Design](DESIGN.md): invariants and extension rules.
- [Paging](PAGING.md): weight and KV paging boundaries.
- [Model format](FORMAT_SPEC.md): portable draft format.
- [Native runtime image](RUNTIME_IMAGE.md): execution image ABI.
- [Continuation capsule](CONTINUATION_CAPSULE.md): checkpoint manifest ABI.
- [Continuation object resolver](CONTINUATION_OBJECT_RESOLVER.md): scoped
  lookup and quota contract.
- [Continuation bundle](CONTINUATION_BUNDLE.md): canonical tenant storage plan.
- [Continuation object store](CONTINUATION_OBJECT_STORE.md): bounded in-memory
  ownership and accounting.
- [Evidence policy](EVIDENCE_POLICY.md): what results are allowed to claim.
