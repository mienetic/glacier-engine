# Continuation Bundle v1

Status: **prototype manifest ABI**. The fixed native codec, full verifier,
independent Python verifier, mutation suite, and model-free demo are implemented.
No object store, file writer, cache, lease system, or live restart exists yet.

`ContinuationBundle` binds one `ContinuationCapsule` and its nine exact external
objects into a canonical tenant-scoped storage plan. It preserves separate
semantic roots for each object kind while assigning equal payload bytes one
deterministic blob ordinal inside the same tenant scope.

## Boundary

```text
ContinuationCapsule + nine exact object payloads + expected tenant/config
                              │
                              ▼
                    ContinuationBundle v1
                ┌─────────────┴─────────────┐
                │ typed semantic roots      │ tenant-bound blob roots
                │ kind + ABI + length       │ length + canonical ordinal
                └─────────────┬─────────────┘
                              ▼
                  portable storage plan only
             no payloads, paths, handles, leases, or I/O
```

The bundle does not grant access to any payload. A future store must combine its
tenant scope and blob identity with an admitted capability before returning
bytes. The continuation resolver must still verify the result.

## Fixed wire

All integers are little-endian. The encoded length is exactly 1,136 bytes.

| Bytes | Field |
| --- | --- |
| `0..8` | Magic `GCBNDV01` |
| `8..16` | Wire ABI `0x4743424e00000001` |
| `16..24` | Encoded length `1136` |
| `24..28` | Required flags: all objects, tenant-bound blobs, canonical ordinals |
| `28..32` | Reserved zero |
| `32..40` | Capsule wire length; exactly `608` in v1 |
| `40..48` | Object count; exactly `9` |
| `48..56` | Logical payload bytes across all nine entries |
| `56..64` | Unique blob count |
| `64..72` | Unique blob payload bytes |
| `72..80` | Bundle generation |
| `80..112` | Nonzero tenant-scope SHA-256 |
| `112..144` | Exact capsule envelope SHA-256 |
| `144..176` | Tenant-bound capsule blob SHA-256 |
| `176..208` | Nonzero challenge SHA-256 |
| `208..240` | Parent bundle root; zero only for generation zero |
| `240..1104` | Nine canonical 96-byte entries |
| `1104..1136` | Bundle envelope SHA-256 |

Each entry is:

```text
u64 object_kind
u64 object_abi
u64 exact_payload_length
u64 canonical_blob_ordinal
u8  typed_semantic_sha256[32]
u8  tenant_blob_sha256[32]
```

Object entries appear in the fixed capsule kind order. Reordering or changing a
kind rejects even if every digest remains present.

## Two identities, two purposes

The typed semantic root comes from the capsule contract:

```text
SHA256(
  "glacier-continuation-object-v1\0" ||
  LE64(object_kind) || LE64(object_abi) || LE64(length) || payload
)
```

The storage blob root is deliberately tenant-bound:

```text
SHA256(
  "glacier-continuation-bundle-blob-v1\0" ||
  tenant_scope_sha256 || LE64(length) || payload
)
```

Equal payload bytes in two semantic positions therefore have different typed
roots but the same blob root and ordinal inside one tenant. The same bytes under
another tenant produce a different blob root. Cross-tenant sharing would require
a future explicit policy and is not the default identity.

The capsule itself receives a tenant-bound blob root under the same formula, but
its 608 bytes are not included in the nine-object logical/unique payload totals.

## Canonical ordinals

Entries are scanned in fixed object-kind order:

1. a never-before-seen `(blob root, length, exact bytes)` receives the next
   ordinal starting at zero;
2. later equal bytes reuse the first entry's ordinal;
3. skipped, reordered, or rewritten ordinals reject;
4. equal blob roots with unequal lengths reject during manifest parsing;
5. equal blob roots with unequal exact bytes reject during full encoding as a
   digest collision.

The decoder recomputes unique count and unique bytes from the canonical table
and compares them with the header. The full verifier additionally re-hashes the
capsule and all payload bytes, then reconstructs the entire wire.

## Resource accounting

Keep these values separate:

- **logical payload bytes:** sum of all nine referenced payload lengths;
- **unique blob bytes:** sum of first-occurrence payload lengths;
- **deduplicated payload bytes:** logical minus unique bytes;
- **manifest bytes:** fixed 1,136-byte bundle plus the external 608-byte capsule;
- **physical bytes:** future store data, index, metadata, alignment, encryption,
  cache, filesystem, and operating-system overhead.

The fixture has 280 logical payload bytes, 255 unique payload bytes, and 25
deduplicated payload bytes because two semantic kinds intentionally share one
25-byte payload. The demo performs zero storage writes. The 25-byte value proves
canonical planning for this fixture only; it is not net or physical savings, and
the manifest overhead is larger than this tiny fixture's duplicate payload.

## Evidence

Run the model-free native demo:

```sh
zig build continuation-bundle-demo -Doptimize=ReleaseSafe -Dmetal=false
```

The retained facts are:

- 1,136-byte fixed bundle wire and 608-byte capsule wire;
- nine semantic entries and eight tenant-bound unique blobs;
- 280 logical, 255 unique, and 25 deduplicated fixture payload bytes;
- zero embedded payload bytes and zero storage writes;
- different typed roots but one ordinal for the duplicate payload;
- different blob roots for the same bytes under another tenant;
- shared Zig/Python bundle root
  `390c29d58b4cf979f44606f611f10b811351d85cdbe1dedaeebe7b31b8564cc5`;
- rejection after mutation of every one of the 1,136 serialized byte positions,
  including mutations whose outer digest is recomputed.

Run the independent verifier:

```sh
python3 -m unittest bench.tests.test_continuation_bundle
```

Additional tests reject noncanonical ordinals, false totals, foreign tenant
scope, foreign object composition, invalid parent lineage, truncation,
extension, capsule substitution, and overlapping native output storage.

## Security and authority boundary

- Blob equality is scoped by the tenant digest; the digest is not user
  authentication by itself.
- Hashes bind bytes and structure; they do not establish trusted provenance.
- Ordinals describe a storage plan; they are not object handles or leases.
- Logical deduplication is not proof of physical allocation or deletion.
- The bundle cannot read, write, fetch, decrypt, evict, schedule, allocate, or
  publish anything.
- ResourceBank, LeaseTree, paged-KV, and output authority must be reacquired and
  verified after payload resolution.

## Next layers

1. ~~Tenant-scoped immutable fake store with admitted put/get operations.~~
   Implemented in memory with fixed index capacity and allocator-owned payloads.
2. ~~Bundle provenance, reference counts, corruption checks, and quarantine.~~
   Implemented with generation-fenced leases and scoped repair.
3. ~~Lease accounting and evidence-producing dry-run collection.~~ Implemented
   with retained retirement and exact root/lease coverage.
4. ~~Sweep prepare/abort consuming an exact plan.~~ Implemented with a separate
   capability, plan regeneration, and no deallocation.
5. ~~Destructive sweep commit with exact allocator/accounting evidence.~~
   Implemented as a separately authorized atomic in-memory transition.
6. ~~Fixed body/footer sweep commit evidence record.~~ Implemented without
   filesystem, deletion, or recovery authority.
7. ~~Pure anchored sweep-record classification.~~ Implemented without I/O or
   repair authority.
8. Compact/dynamic index experiment with full overhead measurement.
9. Atomic bundle publication and crash recovery.
10. Resource and paged-KV ownership reacquisition.
11. End-to-end restart and paired physical-resource campaigns.

The store must preserve the distinction between semantic identity, tenant-bound
blob identity, access authority, live ownership, and publication authority.

See [Continuation Object Store](CONTINUATION_OBJECT_STORE.md) for the implemented
in-memory ownership, rollback, and resource-accounting boundary.
See [Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for
the exact retired-target removal and accounting boundary.
See [Continuation Object Collection Plan](CONTINUATION_OBJECT_COLLECTION.md)
for the implemented dry-run evidence boundary.
See [Continuation Object Sweep Journal](CONTINUATION_OBJECT_SWEEP.md) for the
implemented prepare/abort staging boundary.
See [Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for
the fixed portable commit evidence and non-durable append plan.
