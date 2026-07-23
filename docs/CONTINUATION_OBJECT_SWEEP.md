# Continuation Object Sweep Journal v1

Status: **prototype bounded in-memory prepare/abort journal**. Native Zig and an
independent Python model share canonical sweep-grant, prepare, and abort roots.
Prepare regenerates an approved collection plan from its original root and
lease evidence. Abort verifies the store is still at the pinned snapshot.
A separately authorized atomic in-memory destructive commit is implemented as
the next boundary. Durable persistence, crash recovery, concurrent mutation,
secure erasure, and exactly-once execution are not implemented.

This layer creates a separate authority boundary between answering “which
objects are collectible?” and authorizing a future destructive transition. A
collection-plan root alone cannot start staging. The caller must provide a
sweep grant that pins the exact store, snapshot, plan, and staging ceilings.

## Boundary

```text
trusted caller approves one CollectionPlan root
              │
              ├─ SweepGrantV1
              ├─ original CollectionGrantV1
              ├─ canonical semantic-root multiset
              └─ canonical active-lease receipts
              │
              ▼
prepare
  ├─ regenerate complete collection plan
  ├─ require exact plan + snapshot roots
  ├─ require nonzero collectible totals within grant ceilings
  └─ return caller-owned prepared journal
              │
              ▼
abort
  ├─ verify prepared journal and roots
  ├─ require unchanged audit snapshot
  └─ return caller-owned aborted journal

store payload mutation: none
payload deallocation: none
filesystem/network/clock authority: none
```

The journal transitions are functional. Each operation consumes a journal value
and returns a new value; it does not mutate the input value. Journal values can
still be copied and replayed by a caller, so this prototype is not an
exactly-once or durable state machine.

## Sweep grant

`GrantV1` binds staging authority to one exact collection decision:

| Field | Meaning |
| --- | --- |
| `authority_epoch` | Exact store authority generation |
| `tenant_scope_sha256` | Exact store tenant |
| `bundle_sha256` | Exact bundle provenance |
| `store_grant_sha256` | Canonical admitted store-grant identity |
| `expected_snapshot_sha256` | Audit snapshot that must remain current |
| `collection_plan_sha256` | Exact previously reviewed dry-run plan |
| `max_staged_entries` | Maximum collectible entries that may be staged |
| `max_staged_bytes` | Maximum collectible payload bytes that may be staged |
| `challenge_sha256` | Nonzero caller-selected domain challenge |

Its canonical identity is:

```text
SHA256(
  "glacier-continuation-store-sweep-grant-v1\0" ||
  LE64(authority_epoch) || tenant_scope_sha256 || bundle_sha256 ||
  store_grant_sha256 || expected_snapshot_sha256 ||
  collection_plan_sha256 ||
  LE64(max_staged_entries) || LE64(max_staged_bytes) ||
  challenge_sha256
)
```

The shared fixture grant root is
`062021af17762a0d259073ce5bb2bcf3860d146f621b86d2149efcd7a615612c`.
The digest identifies capability contents; authentication and grant issuance
remain responsibilities of the embedding boundary.

## Prepare transition

Prepare accepts only an all-zero `empty` journal. It then:

1. validates the sweep grant against the store epoch, tenant, bundle, and store
   grant;
2. requires the collection grant to pin the same expected snapshot;
3. runs `planCollectionV1` again from the original canonical root multiset and
   complete active-lease receipts;
4. requires the regenerated plan and snapshot roots to equal the sweep grant;
5. rejects an empty collectible set;
6. checks staged entry and byte totals against the sweep ceilings; and
7. checks the audit snapshot again before returning evidence.

This regeneration is intentional. A caller cannot substitute a structurally
plausible receipt, omit a root, omit a lease, or change a classification after
the plan was approved.

The prepare root is:

```text
SHA256(
  "glacier-continuation-store-sweep-prepare-v1\0" ||
  sweep_grant_sha256 || collection_plan_sha256 || snapshot_sha256 ||
  LE64(staged_entries) || LE64(staged_bytes)
)
```

The fixture prepare root is
`4e660266135b3a4aa7f5116fffb8191ef4c931e479320fbfd6366abbe5999474`.
It stages one retired entry and 30 payload bytes while retaining all store
payloads.

## Abort transition

Abort accepts only a canonical prepared journal whose grant, plan, snapshot,
totals, and prepare root recompute exactly. It then audits the live store again.
Any intervening reference, lease, quarantine, repair, retirement, or payload
state change produces another snapshot and rejects the abort.

The abort root is:

```text
SHA256(
  "glacier-continuation-store-sweep-abort-v1\0" ||
  sweep_grant_sha256 || collection_plan_sha256 || snapshot_sha256 ||
  LE64(staged_entries) || LE64(staged_bytes) || prepare_sha256
)
```

The fixture abort root is
`603535a93206cfafcee6a1a58c58cb97de21c94e0e433f184bd9a9ee09513c1e`.
The returned journal retains both prepare and abort roots for deterministic
inspection.

## Journal representation

`JournalV1` contains:

- state: `empty`, `prepared`, or `aborted`;
- sweep-grant, collection-plan, and snapshot roots;
- staged entry and byte totals; and
- prepare and abort roots.

Its current 64-bit native Zig value is 184 bytes. This is a compile-target
layout observation, not a serialized ABI, heap measurement, process RSS, or
durable storage claim. The implementation uses fixed stack/caller-owned values
and performs no heap allocation. Keeping the journal in a separate module leaves
the existing 3,480-byte store value unchanged; callers hold journal state only
for a sweep workflow.

The fixture retains 255 payload bytes before prepare, after prepare, and after
abort. It stages 30 bytes and frees **zero** bytes. Commit reports actual
allocator and accounting changes separately using another fixture whose final
39-byte allocation can be physically reclaimed; see
[Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md).

## Failure and evidence coverage

Run the native demonstration:

```sh
zig build continuation-sweep-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent model:

```sh
python3 -m unittest bench.tests.test_continuation_object_sweep
```

The native and Python suites cover:

- exact shared grant, prepare, and abort roots;
- unchanged store snapshot, payload bytes, allocator consumption, and input
  journal;
- foreign scope, wrong plan, stale snapshot, and staging ceilings;
- root omission and active-lease omission during plan regeneration;
- invalid, tampered, already prepared, empty, and aborted journal states;
- store mutation between prepare and abort; and
- rejection of a valid collection plan containing no collectible entries.

This proves deterministic prepare/abort conformance for the fixture. The
separate commit layer covers exact in-memory deletion; this journal result does
not imply commit authority, secure erasure, durable recovery, distributed
coordination, liveness, or exactly-once execution.

## Next layers

1. ~~A commit transition that revalidates the prepared journal, validates every
   retired target before mutation, and frees exactly the staged entries only
   after all checks pass.~~ Implemented in memory.
2. ~~Exact post-commit snapshot, allocator, entry, index, and payload accounting
   bound into a sweep receipt.~~ Implemented with independent verification.
3. ~~Fixed body/footer record carrying one committed sweep.~~ Implemented with
   semantic receipt reconstruction and no filesystem authority.
4. ~~Pure anchored recovery classification.~~ Implemented with exact committed
   prefix and distinct short-body, absent-footer, partial-footer, and corrupt
   states without I/O.
5. Capability-scoped durable publication with crash points before and after the
   footer.
6. Multi-bundle and parent-checkpoint reachability composition.
7. ResourceBank/LeaseTree reacquisition and end-to-end restart.

See [Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for
the fixed evidence wire and the remaining durability boundary.
