# Continuation Object Store v1

Status: **prototype bounded in-memory store**. Native storage, independent
Python state model, exact accounting, duplicate reuse, reference release,
quarantine, corruption verification, atomic bundle import, and allocator-failure
rollback are implemented. Filesystem durability, leases, repair, encryption,
concurrent access, and live restart are not.

`ContinuationObjectStore` turns the canonical bundle plan into owned immutable
payload copies under one tenant and one bundle-scoped grant. Its index has fixed
native capacity, payloads come from a caller-supplied allocator, and every
successful mutation updates explicit payload/index/reference counters.

## Boundary

```text
trusted caller + StoreGrantV1 + allocator
                  │
verified ContinuationBundle + exact payload objects
                  │
                  ▼
       bounded tenant object store
       ├─ fixed-capacity slot index
       ├─ allocator-owned immutable payloads
       ├─ reference reuse/release
       ├─ corruption verification
       ├─ quarantine retention
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

- live or quarantined state;
- exact payload length and tenant-bound blob root;
- allocator-owned payload bytes;
- nonzero semantic reference count;
- provenance fixed to the grant's bundle root; and
- a nonzero quarantine reason only in quarantined state.

`putV1` re-hashes tenant, length, and payload before mutation. A new blob checks
entry, object, payload, logical-index, and reference limits before allocation.
An existing equal blob increments only its reference count and allocates no
payload. Equal digests with unequal length or bytes fail as a collision.

`releaseV1` decrements one semantic reference. Only the final release frees the
payload and index slot. `quarantineV1` retains bytes and references for evidence
but blocks reads. Cleanup can still release a quarantined entry.

`verifyAllV1` independently recomputes every blob root and all counters. It also
rejects duplicate occupied roots, foreign provenance, invalid live/quarantine
state, and any reconstructed value beyond the grant.

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
| Native slot capacity on the current 64-bit build | 2,304 |
| Native store value on the current 64-bit build | 2,560 |
| Fixed allocator backing capacity in the demo | 4,096 |
| Fixed allocator consumed bytes after import | 255 |

The store therefore proves one 25-byte duplicate payload allocation is avoided
in this fixture, but it does **not** prove net memory savings: index and reserved
backing capacity dominate this tiny example. Larger workloads require paired
measurements, and a compact/dynamic index must include allocator and metadata
overhead before making net claims.

## Evidence

Run the model-free native demo:

```sh
zig build continuation-store-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent state model:

```sh
python3 -m unittest bench.tests.test_continuation_object_store
```

The suites cover exact cross-language grant/snapshot roots, successful atomic
import, duplicate reuse, final-reference freeing, stale and denied authority,
foreign provenance and bundle scope, entry/payload/index/reference limits,
allocator rollback, missing reads, corruption, quarantine, and output overlap
with store metadata.

## Security and authority boundary

- One store instance is scoped to one tenant and one bundle provenance root.
- Public reads copy verified bytes; they do not return internal allocation
  handles.
- Quarantine blocks reads but is not repair or secure erasure.
- Reference count is not a lease, ownership generation, or garbage-collection
  proof.
- Logical index charge is not native or physical memory measurement.
- The store cannot access paths, sync data, communicate, decrypt, schedule,
  reacquire ResourceBank/LeaseTree state, or publish tokens.

## Next layers

1. Lease/generation fencing around references and collection eligibility.
2. Provenance-aware repair from a separately trusted source.
3. Compact or dynamic index experiment with complete overhead measurement.
4. Atomic filesystem publication and crash recovery.
5. Resource and paged-KV ownership reacquisition.
6. End-to-end restart and paired physical-resource campaigns.
