# Continuation Object Collection Plan v1

Status: **prototype deterministic dry-run planner**. Native Zig and an
independent Python model share canonical collection-grant, root-set,
lease-set, audit-snapshot, and plan roots. Retirement and classification are
implemented. A separately scoped in-memory sweep prepare/abort journal is also
implemented, followed by a separately scoped atomic in-memory destructive
commit. Durable journal persistence, concurrent mutation, secure erasure, and
multi-bundle reachability are not.

The planner answers a deliberately narrow question: given one exact store
snapshot, a complete multiset of semantic roots, and one current receipt for
every active lease, which occupied slots are reachable, leased, quarantined, or
eligible for a future collection transition?

It does not free bytes. Successful planning writes decisions to caller-owned
storage only after every identity, coverage, quota, and alias check succeeds.

## Boundary

```text
trusted caller
  ├─ CollectionGrantV1
  ├─ canonical semantic-root multiset
  └─ canonical active-lease receipt set
             │
             ▼
bounded in-memory store at one audit snapshot
             │
             ├─ verify exact root multiplicity
             ├─ verify complete current-lease coverage
             ├─ scan fixed slot capacity
             └─ classify every occupied slot
             │
             ▼
caller-owned decisions + CollectionReceiptV1
no allocation, deallocation, filesystem, network, or clock authority
```

The root input is a multiset, not a unique set. If one stored blob represents
two semantic bundle objects, its blob reference must appear twice. Omitting a
root cannot make the object collectible: the operation rejects because the
presented multiplicity no longer equals the slot's reference count.

## Retirement before collection

`retireV1` is an explicit transition for a live, unleased entry with exactly
one remaining semantic reference. It changes the slot to `retired`, changes its
reference count from one to zero, and retains the payload and metadata. It does
not free memory.

Retirement rejects for shared references, active leases, quarantined entries,
already retired entries, missing objects, or denied store authority. Retired
entries cannot be read, leased, quarantined, released through the immediate
release path, or presented as semantic roots. This creates a reviewable gap
between loss of semantic reachability and any future destructive sweep.

The existing `releaseV1` path remains available for immediate final release.
Callers that need collection evidence use `retireV1` instead.

## Collection grant

`CollectionGrantV1` binds a plan to one already admitted store state:

| Field | Meaning |
| --- | --- |
| `authority_epoch` | Exact store authority generation |
| `tenant_scope_sha256` | Exact store tenant |
| `bundle_sha256` | Exact bundle provenance |
| `store_grant_sha256` | Canonical identity of the admitted store grant |
| `expected_snapshot_sha256` | Exact audit snapshot that may be classified |
| `max_root_references` | Maximum presented semantic-root multiplicity |
| `max_lease_receipts` | Maximum presented active-lease receipts |
| `max_slot_scans` | Maximum fixed-capacity slots inspected |
| `max_collectible_entries` | Maximum entries a successful plan may mark collectible |
| `max_collectible_bytes` | Maximum payload bytes a successful plan may mark collectible |
| `challenge_sha256` | Nonzero caller-selected domain challenge |

Its canonical identity is:

```text
SHA256(
  "glacier-continuation-store-collection-grant-v1\0" ||
  LE64(authority_epoch) || tenant_scope_sha256 || bundle_sha256 ||
  store_grant_sha256 || expected_snapshot_sha256 ||
  LE64(max_root_references) || LE64(max_lease_receipts) ||
  LE64(max_slot_scans) || LE64(max_collectible_entries) ||
  LE64(max_collectible_bytes) || challenge_sha256
)
```

The fixture grant root is
`e50faf088020f0e274d97596878334795ce62535a6145c64b226fad8c03e14ee`.
As with other grants, this digest identifies the declaration; authentication
of the trusted boundary remains external.

## Canonical inputs

Root references are sorted by blob digest and then byte length. Their root
binds the count and every duplicate in order:

```text
SHA256(
  "glacier-continuation-store-collection-roots-v1\0" ||
  LE64(root_count) ||
  for each root: LE64(byte_length) || blob_sha256
)
```

The fixture root-reference root is
`b7ea28e55d1452b5221a12abcb6f648d63355a3eecb1aee2c60fcb5be42edf72`.

Lease receipts are sorted by target blob, generation, and receipt root. Their
set root binds the count and each already self-verifying lease root:

```text
SHA256(
  "glacier-continuation-store-collection-leases-v1\0" ||
  LE64(lease_count) ||
  for each receipt: lease_sha256
)
```

The fixture lease-set root is
`000b5c1c68b5c120a203d5593a305389001556cc2b2d1f3fcc624b0c13f8d824`.
A missing, duplicate, stale, inactive, malformed, or unknown receipt rejects.
Every active store lease must have exactly one current receipt, including a
lease on an otherwise reachable blob.

## Classification contract

The planner scans the complete fixed slot capacity in native slot order. Every
occupied slot receives exactly one decision:

| Class | Required state | Meaning |
| --- | --- | --- |
| `reachable` | Live, unleased, exact root multiplicity | Retain for semantic users |
| `leased` | Live, actively leased, exact root multiplicity and receipt | Retain for semantic users and the current owner |
| `quarantined` | Quarantined, exact root multiplicity, no active lease | Retain for diagnosis or repair; never collect |
| `collectible` | Retired, zero roots, zero references, no lease | Eligible for a future separately authorized sweep |

Classification is fail-closed. A live entry with missing roots is not converted
to collectible. A retired entry with any root or lease is invalid. A
quarantined entry has retention priority even when its payload is corrupt.

`auditSnapshotRootV2` verifies all accounting and all non-quarantined payloads.
It deliberately permits content corruption only for entries already marked
quarantined, so a damaged payload cannot prevent a safe retention plan. The
snapshot binds that slot's identity, state, reference count, reason, lease
generation, and repair generation, but not the altered quarantined payload
bytes. Strict `verifyAllV1` continues to reject any payload corruption.

## Plan evidence

Each `CollectionDecisionV1` binds native slot index, class, target blob,
reference count, lease generation, and repair generation. The plan root hashes:

```text
"glacier-continuation-store-collection-plan-v1\0" ||
collection_grant_sha256 || snapshot_sha256 ||
root_references_sha256 || lease_receipts_sha256 ||
all scan/input/class count fields || collectible_bytes ||
for each occupied slot in native slot order:
  LE64(slot_index) || LE64(class) ||
  LE64(target.byte_length) || target.sha256 ||
  LE64(reference_count) || LE64(lease_generation) ||
  LE64(repair_generation)
```

The fixture audit snapshot and final plan roots are:

- audit snapshot:
  `b8b82e6eb574f7cef0f4e1c855054f4d9f1cd53e347bbb97f2250b3a72e871bf`;
- collection plan:
  `b283dc923a974897ba9427c6ef9db4acde41f5bb3a11d907e717645984894bc4`.

The caller supplies the decision buffer. It must hold every occupied entry and
must not overlap store metadata, owned payloads, root inputs, or lease inputs.
The native implementation computes into fixed temporary storage and copies
decisions only after all checks pass, so a rejected plan leaves both store and
output buffer unchanged.

## Fixture checkpoint

The model-free fixture imports nine semantic references as eight unique entries,
leases the one entry shared by the model and tokenizer, retires the KV entry,
and quarantines the lane entry.

| Result | Entries | Semantic references | Payload bytes |
| --- | ---: | ---: | ---: |
| Reachable | 5 | 5 | retained |
| Leased | 1 | 2 | retained |
| Quarantined | 1 | 1 | retained |
| Collectible | 1 | 0 | 30 |
| Total occupied | 8 | 8 presented roots | 255 retained |

The planner scans 16 fixed slots and consumes one lease receipt. It reports 30
collectible bytes while freeing **zero** bytes. The current 64-bit native store
value is 3,480 bytes; this is a compile-target layout observation, not RSS.

## Evidence and rejection coverage

Run the native demonstration:

```sh
zig build continuation-collection-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent state model:

```sh
python3 -m unittest bench.tests.test_continuation_object_collection
```

The suites cover shared cross-language roots and counts, dry-run immutability,
exact duplicate-root multiplicity, current-lease coverage, canonical ordering,
unknown and duplicate inputs, stale snapshots, root/receipt/scan/collectible
budgets, insufficient output, unsafe aliases, corrupt quarantine retention, and
unchanged outputs on rejection.

This proves deterministic classification for the fixture. The separate commit
layer proves exact in-memory removal for its own fixture; neither result proves
crash durability, distributed liveness, secure erasure, or multi-bundle global
reachability.

## Next layers

1. ~~Separately authorized sweep prepare/abort journal.~~ Implemented with plan
   regeneration, exact staging ceilings, functional values, and no deallocation.
2. ~~Destructive commit with exact post-sweep allocator/accounting evidence.~~
   Implemented in memory with a separate grant and repeated plan regeneration.
3. ~~Fixed body/footer commit evidence record.~~ Implemented without file or
   recovery authority.
4. ~~Pure anchored record classification.~~ Implemented without I/O or repair.
5. ~~Snapshot-bound append/repair capability and deterministic crash model.~~
   Implemented without real filesystem or deletion authority.
6. Real crash-safe publication and recovery of retirement/sweep decisions.
7. Multi-bundle and parent-checkpoint reachability composition.
8. Replica transport that keeps admission, verification, and deletion authority
   separate.
9. ResourceBank/LeaseTree reacquisition and end-to-end restart.

See [Continuation Object Sweep Journal](CONTINUATION_OBJECT_SWEEP.md) for the
implemented staging boundary and
[Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for the
destructive boundary, and
[Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for the
portable commit evidence, and
[Continuation Object Sweep Writer](CONTINUATION_OBJECT_SWEEP_WRITER.md) for the
scoped publication model and remaining platform boundary.
