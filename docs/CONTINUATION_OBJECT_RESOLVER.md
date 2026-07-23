# Continuation Object Resolver v1

Status: **prototype in-memory resolver**. The native resolver, independent
Python model, adversarial tests, and model-free demo are implemented. Durable
storage, process restart, cache eviction, and resource reacquisition are not.

`ContinuationObjectResolver` turns the nine external roots in one verified
`ContinuationCapsule` into exact caller-owned bytes under a least-authority,
tenant-scoped grant. It does not open files, use the network, allocate memory,
or publish AI-visible state.

## Boundary

```text
trusted caller
  │
  ├─ capsule wire + expected authority epoch
  ├─ tenant-scoped GrantV1
  ├─ bounded immutable catalog
  └─ caller-owned output buffers
           │
           ▼
 ContinuationObjectResolver
   verify capsule/grant identity
   admit exact kind/ABI/length/root
   enforce scan/object/total/count limits
   reject ambiguity, corruption, overlap, and reuse
           │
           ▼
 nine verified outputs ──> full capsule composition check
```

The caller that constructs and supplies `GrantV1` remains trusted. The grant
root is an auditable identity, not a signature or credential. Supplying a tenant
digest proves only exact equality with the admitted scope; it does not
authenticate a person or process.

## Grant contract

| Field | Meaning |
| --- | --- |
| `authority_epoch` | Exact local authority generation; stale epochs reject |
| `request_epoch` | Must equal the capsule request epoch |
| `capsule_sha256` | Exact continuation capsule envelope root |
| `tenant_scope_sha256` | Opaque tenant/access scope used by every catalog lookup |
| `allowed_kind_mask` | Nonempty subset of the nine capsule object kinds |
| `max_object_bytes` | Maximum admitted payload length for one object |
| `max_total_bytes` | Maximum successful payload bytes across the session |
| `max_resolutions` | Must equal the number of allowed kind bits |
| `max_catalog_entries` | Maximum entries that may be scanned |
| `challenge_sha256` | Nonzero caller-selected domain challenge |

The canonical audit root is:

```text
SHA256(
  "glacier-continuation-resolver-grant-v1\0" ||
  LE64(authority_epoch) ||
  LE64(request_epoch) ||
  capsule_sha256 ||
  tenant_scope_sha256 ||
  LE64(allowed_kind_mask) ||
  LE64(max_object_bytes) ||
  LE64(max_total_bytes) ||
  LE64(max_resolutions) ||
  LE64(max_catalog_entries) ||
  challenge_sha256
)
```

The fixture root is
`d3609c14ddc29235c74f5b1163fff3f4694dd9d0607d30610e5d87bbccc0d2d8`
in both Zig and Python.

## Catalog key

Every immutable entry has this effective key:

```text
(tenant_scope_sha256, object_kind, object_abi, exact_length, typed_sha256)
```

Content equality never bypasses tenant equality. The typed digest is recomputed
from the exact payload using the object-kind domain defined by the continuation
capsule. A missing key rejects. More than one exact key rejects as ambiguous,
even when both entries point to equal bytes.

The current catalog is supplied in memory by the trusted caller. It is not a
filesystem layout, database API, cache, or discovery protocol.

## Resolution state machine

For one requested kind, `resolveV1` performs these checks before writing or
changing accounting:

1. the session is not finalized;
2. the grant allows the kind and the kind was not already resolved;
3. resolution count, object bytes, total bytes, and catalog entries are within
   their declared limits;
4. the destination is large enough and overlaps neither the capsule, any prior
   output, nor any catalog payload;
5. exactly one catalog entry matches tenant, kind, ABI, length, and root;
6. hashing the exact entry payload reproduces the capsule reference.

Only then are bytes copied and counters advanced. Failure preserves the caller's
destination and resolver accounting. `finishFullV1` requires all nine kinds,
re-hashes the caller-owned outputs, and verifies the complete capsule again. If
an output changed after resolution, the resolver becomes terminal and rejects.

## Resource contract

The native implementation:

- performs no heap allocation;
- uses a fixed nine-slot resolution table;
- performs at most `max_catalog_entries` comparisons per lookup;
- admits at most `max_object_bytes` for one object;
- admits at most `max_total_bytes` and `max_resolutions` per session; and
- never creates an implicit second copy beyond the caller-provided output.

These are logical and algorithmic bounds. They do not prove lower process RSS,
storage use, restore latency, or energy. A future object store must measure its
index, metadata, cache, encryption, and operating-system overhead before making
physical resource claims.

## Evidence

Run the model-free native demo:

```sh
zig build continuation-resolver-demo -Doptimize=ReleaseSafe -Dmetal=false
```

The retained fixture resolves nine objects and exactly 264 payload bytes under a
64-byte per-object limit, 264-byte total limit, nine-resolution limit, and
16-entry scan limit. It rejects a byte-identical catalog under a foreign tenant
scope and reports no filesystem or network authority.

Run the independent contract model:

```sh
python3 -m unittest bench.tests.test_continuation_object_resolver
```

The Zig and Python suites cover successful full composition, stale authority,
denied and repeated kinds, incomplete grants, cross-tenant lookup, corrupt and
ambiguous entries, catalog/object/total limits, unsafe destination overlap,
capsule substitution, and changed resolved output.

## Security boundary

- SHA-256 binds identity; it does not prove who granted access.
- Tenant scope is mandatory lookup context; it is not inferred from content.
- Historical resource receipts remain evidence, not live ResourceBank or
  LeaseTree authority.
- Resolved output remains caller-owned and must not be mutated before final
  verification or runtime import.
- The resolver cannot discover paths, fetch missing objects, decrypt payloads,
  schedule work, allocate KV, or publish tokens.

## Next layers

1. ~~Fixed bundle manifest for the capsule and its nine typed objects.~~
   Implemented with tenant-bound blob roots and canonical ordinals.
2. ~~Tenant-scoped immutable fake store with provenance and quarantine.~~
   Implemented with atomic bundle import and exact accounting.
3. ~~Lease/generation accounting and evidence-producing dry-run collection.~~
   Implemented with explicit retirement, complete root/lease coverage, and
   cross-language plan roots.
4. ~~Sweep prepare/abort consuming an exact plan.~~ Implemented with plan
   regeneration and cross-language journal roots.
5. ~~Destructive sweep commit with exact allocator/accounting evidence.~~
   Implemented as a separately authorized atomic in-memory transition.
6. ~~Fixed body/footer sweep commit evidence record.~~ Implemented without
   filesystem or recovery authority.
7. ~~Pure anchored sweep-record classification.~~ Implemented without I/O or
   repair authority.
8. Atomic bundle publication and crash recovery.
9. ResourceBank/LeaseTree and paged-KV reacquisition.
10. End-to-end restart with paired physical measurements.

Each layer must preserve the separation between content identity, access
authority, live resource ownership, and token publication authority.

See [Continuation Bundle](CONTINUATION_BUNDLE.md) for the implemented portable
storage plan and its evidence boundary.
See [Continuation Object Store](CONTINUATION_OBJECT_STORE.md) for the bounded
payload-ownership and rollback boundary.
See [Continuation Object Collection Plan](CONTINUATION_OBJECT_COLLECTION.md)
for the non-destructive reachability evidence boundary.
See [Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for
the exact retired-target removal and accounting boundary.
See [Continuation Object Sweep Journal](CONTINUATION_OBJECT_SWEEP.md) for the
non-destructive prepare/abort staging boundary.
See [Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for
the portable commit evidence and its non-durable boundary.
