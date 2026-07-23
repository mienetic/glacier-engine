# Continuation Object Store v1

Status: **prototype bounded in-memory store**. Native storage, independent
Python state model, exact accounting, duplicate reuse, reference release,
quarantine, corruption verification, atomic bundle import, and allocator-failure
rollback are implemented. Generation-fenced leases, deterministic expiry,
quarantine fencing, capability-bound repair, explicit retirement, and
evidence-producing dry-run collection planning are also implemented. Filesystem
durability, concurrent access, replica transport, encryption, secure erase, and
live restart are not. A separately authorized in-memory sweep commit now removes
an exact validated retired set and emits before/after accounting evidence.

`ContinuationObjectStore` turns the canonical bundle plan into owned immutable
payload copies under one tenant and one bundle-scoped grant. Its index has fixed
native capacity, payloads come from a caller-supplied allocator, and every
successful mutation updates explicit payload/index/reference counters.

## Boundary

```text
trusted caller + StoreGrantV1 + allocator
               + LifecycleGrantV1 / RepairGrantV1
                  │
verified ContinuationBundle + exact payload objects
                  │
                  ▼
       bounded tenant object store
       ├─ fixed-capacity slot index
       ├─ allocator-owned immutable payloads
       ├─ reference reuse/release
       ├─ generation-fenced lease ownership
       ├─ corruption verification
       ├─ quarantine + verified repair
       ├─ retained retirement + dry-run collection plan
       ├─ separately authorized atomic retired-target commit
       └─ atomic import rollback
                  │
                  ▼
       caller-owned verified get buffer
       no filesystem/network/live-runtime authority
```

The store never exposes its owned mutable allocation through the public API.
`getV1` verifies the blob again and copies into caller-owned non-overlapping
storage. Resolver and capsule verification remain separate admission layers.

## Store grant

| Field | Meaning |
| --- | --- |
| `authority_epoch` | Exact local authority generation; stale epochs reject |
| `tenant_scope_sha256` | Single tenant scope used for every blob root |
| `bundle_sha256` | Only admitted bundle and provenance root |
| `allowed_operation_mask` | Explicit put, get, release, quarantine, and verify authority |
| `max_entries` | Maximum occupied unique-blob slots |
| `max_object_bytes` | Maximum one-payload allocation |
| `max_payload_bytes` | Maximum sum of owned payload lengths |
| `max_index_bytes` | Maximum logical index charge |
| `max_references` | Maximum semantic references across all slots |
| `challenge_sha256` | Nonzero caller-selected domain challenge |

The canonical grant identity is:

```text
SHA256(
  "glacier-continuation-store-grant-v1\0" ||
  LE64(authority_epoch) ||
  tenant_scope_sha256 || bundle_sha256 ||
  LE64(allowed_operation_mask) ||
  LE64(max_entries) || LE64(max_object_bytes) ||
  LE64(max_payload_bytes) || LE64(max_index_bytes) ||
  LE64(max_references) || challenge_sha256
)
```

The fixture grant root is
`1d7b766cd09f48421c8638916716299cbbe0d7046aa7c24c54b5971c68d91771`
in both Zig and Python. The digest is an auditable identity, not authentication
or a signature; the boundary supplying the grant remains trusted.

## Entry lifecycle

Each occupied slot contains:

- live, quarantined, or retired state;
- exact payload length and tenant-bound blob root;
- allocator-owned payload bytes;
- semantic reference count, which is zero only when retired;
- provenance fixed to the grant's bundle root; and
- a nonzero quarantine reason only in quarantined state.

`putV1` re-hashes tenant, length, and payload before mutation. A new blob checks
entry, object, payload, logical-index, and reference limits before allocation.
An existing equal blob increments only its reference count and allocates no
payload. Equal digests with unequal length or bytes fail as a collision.

`releaseV1` decrements one semantic reference. Only the final release frees the
payload and index slot, and that final transition rejects while a lease is
active. `quarantineV1` retains bytes and references for evidence, blocks reads,
and clears an active lease so its receipt becomes unusable. Cleanup can still
release a quarantined entry.

`retireV1` offers a non-destructive alternative to final release. It accepts
only a live, unleased entry with exactly one reference, changes that reference
to zero, and retains the payload in a retired slot. A separately scoped dry-run
planner can then prove its collection eligibility without freeing it. See
[Continuation object collection plan](CONTINUATION_OBJECT_COLLECTION.md).

`verifyAllV1` independently recomputes every blob root and all counters. It also
rejects duplicate occupied roots, foreign provenance, invalid live/quarantine
state, invalid lease/repair accounting, and any reconstructed value beyond the
grant.

Lease and repair authority are separate from the storage grant. See
[Continuation object lifecycle](CONTINUATION_OBJECT_LIFECYCLE.md) for exact
grant roots, receipt identities, logical-tick rules, stale-generation rejection,
and repair admission.

## Atomic bundle import

Import first verifies the complete bundle, capsule, tenant, bundle root, and nine
payload objects before touching store state. It then records one bounded action
per semantic object:

```text
insert new slot  ── action(inserted, slot)
reuse live slot  ── action(reference increment, slot)
failure          ── reverse actions; undo references; free inserted payloads
success          ── return exact receipt + store snapshot root
```

Because the bundle has exactly nine object entries, the rollback journal is a
fixed nine-action stack. Tests force allocator failure after several insert and
reuse operations and require entry, payload, index, and reference counters to
return to exact zero.

## Snapshot identity

The snapshot root hashes the grant root, all six accounting counters, then every
occupied slot in native slot-index order with state, length, blob root, reference
count, provenance, and quarantine reason. It does not hash payload bytes again;
`snapshotRootV1` first calls full payload verification.

The shared post-import fixture root is
`5ef533c5bbf2db216806736f6a12c59503f668b02e3c12dba8dc8b503121860f`.
It identifies this in-memory state only and is not a durable commit receipt.

`snapshotRootV2` preserves that content/accounting root and additionally binds
active-lease and repair counters plus each occupied slot's lease generation,
current lease-receipt root, and repair generation. The receipt root transitively
binds owner, deadline, and lifecycle grant without copying those fields into
every slot. The shared post-lifecycle fixture root is
`239ea7e7555388fab740d3d1fdb8040a7f3706b102e9572c05f7dc612822e1bd`.

## Resource accounting

The store reports these categories separately:

- **payload bytes:** exact sum of owned allocation lengths;
- **logical index bytes:** 128 bytes per occupied blob by contract;
- **references:** semantic object uses, including reused blobs;
- **native slot capacity bytes:** compile-target `@sizeOf` of the complete fixed
  slot array, occupied or not;
- **native store bytes:** compile-target `@sizeOf` of the whole store value;
- **allocator backing/overhead:** owned by the caller and not inferred from
  payload counters.

Current fixture evidence:

| Quantity | Bytes/count |
| --- | ---: |
| Semantic references | 9 |
| Unique occupied entries | 8 |
| Naive per-reference payload bytes | 280 |
| Allocated payload bytes | 255 |
| Duplicate payload allocation avoided | 25 |
| Logical index bytes | 1,024 |
| Native slot capacity on the current 64-bit build | 3,200 |
| Native store value on the current 64-bit build | 3,480 |
| Fixed allocator backing capacity in the demo | 4,096 |
| Fixed allocator consumed bytes after import | 255 |

The additional lifecycle metadata deliberately raises fixed slot capacity from
the earlier 2,304-byte prototype to 3,200 bytes. Storing one receipt root instead
of duplicate owner/deadline/grant fields avoids another 1,152 bytes versus the
initial lifecycle layout. The store therefore proves one 25-byte duplicate
payload allocation is avoided in this fixture, but it does **not** prove net
memory savings: lifecycle/index metadata and reserved backing capacity dominate
this tiny example. Larger workloads require paired
measurements, and a compact/dynamic index must include allocator and metadata
overhead before making net claims.

## Evidence

Run the model-free native demo:

```sh
zig build continuation-store-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-collection-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-commit-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-record-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent state model:

```sh
python3 -m unittest bench.tests.test_continuation_object_store
python3 -m unittest bench.tests.test_continuation_object_collection
python3 -m unittest bench.tests.test_continuation_object_sweep
python3 -m unittest bench.tests.test_continuation_object_sweep_record
```

The suites cover exact cross-language store/lifecycle/repair grant and receipt
roots, successful atomic import, duplicate reuse, lease-fenced final-reference
freeing, renewal and explicit expiry, stale and denied authority, foreign
provenance and bundle scope, entry/payload/index/reference/lease limits,
allocator rollback, missing reads, corruption, quarantine fencing, repair-source
and reason rejection, retirement, exact root/lease coverage, collection budgets,
dry-run immutability, sweep plan regeneration, prepare/abort journal tamper and
stale-snapshot rejection, canonical retired-target commit, exact before/after
accounting, double-commit rejection, fixed body/footer encoding, semantic record
verification, and output/source overlap with store memory.

## Security and authority boundary

- One store instance is scoped to one tenant and one bundle provenance root.
- Public reads copy verified bytes; they do not return internal allocation
  handles.
- Quarantine blocks reads and fences active leases; repair restores bytes only
  after exact target, source, reason, tenant, bundle, and payload verification.
- Reference count and lease generation remain separate. Collection eligibility
  additionally requires an exact audit snapshot, complete root multiplicity,
  complete current-lease coverage, and an explicit retired state.
- Logical ticks are explicit inputs, not wall-clock evidence or a timer service.
- Repair source identity is capability metadata, not remote attestation.
- Logical index charge is not native or physical memory measurement.
- The store cannot access paths, sync data, communicate, decrypt, schedule,
  reacquire ResourceBank/LeaseTree state, or publish tokens.

## Next layers

1. Compact or dynamic index experiment with complete overhead measurement.
2. ~~Sweep prepare/abort consuming an exact plan.~~ Implemented with separate
   capability scope, plan regeneration, and zero payload deallocation.
3. ~~Destructive sweep commit with exact allocator/accounting evidence.~~
   Implemented in memory with canonical targets, complete pre-mutation checks,
   and matching Zig/Python roots.
4. ~~Fixed sweep commit evidence record.~~ Implemented as a pointer-free
   body/footer wire without filesystem authority.
5. Replica adapter with independently verified repair transport.
6. Atomic filesystem publication and crash recovery.
7. Resource and paged-KV ownership reacquisition.
8. End-to-end restart and paired physical-resource campaigns.

See [Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for
the portable commit evidence and non-durable append plan.
