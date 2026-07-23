# Continuation Object Sweep Commit v1

Status: **prototype atomic in-memory destructive commit**. Native Zig and an
independent Python state model share canonical commit-grant, target-set, store
commit, outer commit, and post-commit snapshot roots. The native fixture also
observes one real allocator deallocation and exact tail reclamation. Durable
persistence, crash recovery, concurrent mutation, secure erasure, and
multi-bundle reachability are not implemented.

This transition is deliberately separate from collection planning and sweep
staging. A collection plan identifies eligible objects without granting
deallocation authority. A sweep grant authorizes plan regeneration and staging.
Only a second commit grant can authorize removal of the exact prepared set.

## Boundary

```text
canonical prepared sweep journal
  + original CollectionGrantV1
  + complete semantic-root multiset
  + complete active-lease receipts
  + separate CommitGrantV1
                 │
                 ▼
commit
  ├─ verify store, sweep, journal, commit scope, snapshot, and ceilings
  ├─ regenerate the complete collection plan again
  ├─ derive and canonically sort the exact collectible targets
  ├─ verify every target is retired, unreferenced, unleased, and unquarantined
  ├─ precompute exact before/after accounting
  ├─ finish every fallible check
  ├─ deallocate each exact target and clear its fixed slot
  └─ emit store and outer commit receipts
                 │
                 ▼
post-commit audit snapshot + exact logical accounting evidence

filesystem/network/clock authority: none
durability/secure erase: none
```

The current store is single-owner and not concurrency-safe. The embedding
boundary must prevent concurrent mutation while planning, preparing, and
committing. Snapshot checks detect prior mutation; they are not a lock or a
distributed coordination protocol.

## Separate commit authority

`CommitGrantV1` binds destructive authority to one already prepared operation:

| Field | Meaning |
| --- | --- |
| `authority_epoch` | Exact store authority generation |
| `tenant_scope_sha256` | Exact store tenant |
| `bundle_sha256` | Exact bundle provenance |
| `store_grant_sha256` | Canonical admitted store-grant identity |
| `sweep_grant_sha256` | Exact staging capability that produced the journal |
| `prepare_sha256` | Exact prepared transition being authorized |
| `expected_snapshot_sha256` | Store snapshot that must still be current |
| `collection_plan_sha256` | Exact reviewed and regenerated plan |
| `max_freed_entries` | Maximum entries this commit may remove |
| `max_freed_bytes` | Maximum payload bytes this commit may remove |
| `challenge_sha256` | Nonzero caller-selected domain challenge |

Its canonical identity is:

```text
SHA256(
  "glacier-continuation-store-sweep-commit-grant-v1\0" ||
  LE64(authority_epoch) || tenant_scope_sha256 || bundle_sha256 ||
  store_grant_sha256 || sweep_grant_sha256 || prepare_sha256 ||
  expected_snapshot_sha256 || collection_plan_sha256 ||
  LE64(max_freed_entries) || LE64(max_freed_bytes) ||
  challenge_sha256
)
```

The commit ceilings cannot exceed the staging ceilings. A digest binds the
grant contents but does not authenticate its issuer; authentication remains an
embedding-boundary responsibility.

## Commit algorithm

`commitV1` performs these checks before the first deallocation:

1. verify the store admits release and verification operations;
2. verify the sweep grant against the store scope;
3. recompute the prepared journal root and reject aborted, empty, or tampered
   journals;
4. verify the commit grant binds that exact sweep grant, prepare root, store
   scope, snapshot, plan, and ceilings;
5. regenerate the collection plan from the original canonical roots and lease
   receipts;
6. require the regenerated plan, snapshot, collectible count, and collectible
   bytes to equal the prepared journal and commit grant;
7. derive the collectible target set and sort it by digest then length;
8. reject empty, duplicate, noncanonical, missing, live, leased, referenced, or
   quarantined targets;
9. audit the full store and require the pinned snapshot;
10. check target count, payload bytes, index bytes, and repair-generation
    accounting for overflow, underflow, and ceilings; and
11. precompute the complete post-commit logical accounting value.

After step 11, the implementation only calls the allocator's non-failing
`free`, clears exact fixed slots, assigns precomputed counters, computes the
unchecked post-state root, and constructs receipts. There is no fallible
operation or rollback path after the first deallocation.

This is an atomic in-memory mutation boundary for the current single-owner
store. It is not crash atomicity: process or power loss can interrupt memory
mutation. A portable body/footer evidence record now exists, but no file writer,
sync protocol, recovery policy, or durable mutation ordering exists yet.

## Canonical target set

Targets are nonempty `(byte_length, blob_sha256)` references in strict canonical
order. Strict ordering rejects duplicates before mutation. Their root is:

```text
SHA256(
  "glacier-continuation-store-retired-targets-v1\0" ||
  LE64(target_count) ||
  for each target: LE64(byte_length) || blob_sha256
)
```

The store copies the bounded target slice into fixed local storage before
mutation. Caller aliasing therefore cannot change which targets are freed after
validation starts.

## Store commit receipt

`RetiredCommitReceiptV1` binds:

- authorization and canonical target roots;
- exact before/after v2 audit snapshots;
- before/after entry, live, quarantined, retired, payload, logical-index,
  reference, active-lease, and repair counters;
- freed entry, payload-byte, logical-index-byte, and repair-generation totals;
  and
- allocator deallocation call count.

Its root is:

```text
SHA256(
  "glacier-continuation-store-retired-commit-v1\0" ||
  authorization_sha256 || targets_sha256 ||
  snapshot_before_sha256 || snapshot_after_sha256 ||
  all nine LE64(accounting_before fields) ||
  all nine LE64(accounting_after fields) ||
  LE64(freed_entries) || LE64(freed_payload_bytes) ||
  LE64(freed_index_bytes) || LE64(freed_repair_count) ||
  LE64(allocator_deallocation_calls)
)
```

Logical index bytes are accounting charges, not heap bytes returned by a fixed
slot array. Allocator deallocation calls prove that `free` was invoked for each
target, not that process RSS fell or that bytes were securely erased.

## Outer sweep commit receipt

`CommitReceiptV1` joins authorization, plan, target, store, and post-state
evidence:

```text
SHA256(
  "glacier-continuation-store-sweep-commit-v1\0" ||
  commit_grant_sha256 || sweep_grant_sha256 || prepare_sha256 ||
  collection_plan_sha256 || targets_sha256 ||
  snapshot_before_sha256 || snapshot_after_sha256 ||
  store_commit_sha256 ||
  LE64(freed_entries) || LE64(freed_payload_bytes) ||
  LE64(freed_index_bytes) || LE64(freed_repair_count) ||
  LE64(allocator_deallocation_calls)
)
```

Receipt verification recomputes both the commit grant and store receipt roots,
checks all shared fields and grant ceilings, and independently validates every
accounting relation. A receipt that is re-hashed after making its before/after
counters contradictory still rejects.

## Measured fixture

The model-free fixture imports nine semantic references as eight unique payload
allocations. It retires the final imported `publication_receipt` allocation,
quarantines one lane object, and holds one generation-fenced model lease. The
complete root and lease evidence classifies exactly one 39-byte target as
collectible.

| Observation | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Occupied store entries | 8 | 7 | -1 |
| Retired entries | 1 | 0 | -1 |
| Store payload ledger | 255 bytes | 216 bytes | -39 bytes |
| Logical index ledger | 1,024 bytes | 896 bytes | -128 bytes |
| Retained repair-generation ledger | 0 | 0 | 0 |
| Fixed-buffer allocator consumed tail | 255 bytes | 216 bytes | -39 bytes |
| Allocator deallocation calls | 0 | 1 | +1 call |

The physical allocator delta is observable because the retired payload is the
last allocation in this fixture and the fixed-buffer allocator can rewind its
tail. Removing a non-tail allocation, using a different allocator, or measuring
RSS can produce a different physical result even when the logical receipt is
identical. The 3,480-byte native store value and 184-byte caller-owned journal
do not shrink.

The shared fixture roots are:

| Evidence | SHA-256 |
| --- | --- |
| Sweep grant | `4b351c7ff50a450fec56858ede90fae631c06ed5bb2de6b714d85b3b9c48750b` |
| Collection plan | `46c54e726e18dc0d080f300fa94aa0c4ecceb9b40199da0e3adf1a7dda3c3094` |
| Prepare | `892441e052efe6666e2f49d030d3271ff968579dea6d39c9326b0b3889ce336e` |
| Commit grant | `4bb165e6809e00403cc17997d3bdbcc13787c051d895b4ff7eadde9d24991d3e` |
| Target set | `d5e185b91d3aae5e6d96f249c69cc59b213e9cdd43717669fee2192d2752988e` |
| Store commit | `4dc638ad333478ba67e7273f6bdd3e5c3bb7b82c2b3df0fef0d7ad3aa22a2c88` |
| Sweep commit | `e40010e0a26dbfe6cd94ecfdb3b1fbf49b9b3f4421b1cf40247fa6304ad309b5` |
| Snapshot before | `6d583ed8669424a74f7ee7a22d355da338fefe2cf24a4d81783c9ac0d5716480` |
| Snapshot after | `2e537f05538bcb1ef378a600f55fd1bcf35c85c9c1f4185cb908a128ec147ab2` |

Run the native evidence demo:

```sh
zig build continuation-sweep-commit-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent model:

```sh
python3 -m unittest bench.tests.test_continuation_object_sweep
```

## Failure coverage

Native and independent tests cover:

- exact shared commit-grant, target, store-commit, outer-commit, and post-state
  roots;
- foreign tenant/bundle/store scope and stale snapshots;
- wrong sweep grant, prepare root, plan root, and byte ceilings;
- omitted semantic roots and omitted active-lease receipts;
- tampered prepared journals;
- empty, duplicate, noncanonical, missing, and live targets;
- mixed target sets where a valid retired target precedes an invalid live target,
  with no partial removal;
- exact entry/payload/index/deallocation accounting;
- semantic rejection of an internally contradictory but correctly re-hashed
  accounting receipt;
- unchanged snapshot and counters after every pre-mutation rejection;
- removed-target lookup failure and valid post-state full-store audit; and
- replayed commit rejection against the changed snapshot.

This proves deterministic atomic in-memory commit conformance for the fixture.
It does not prove durable exactly-once execution, recovery after process loss,
secure erasure, multi-process safety, distributed reachability, lower RSS, or
production garbage-collection performance.

## Next layers

1. ~~Fixed body/footer sweep commit evidence record.~~ Implemented as a
   784-byte pointer-free wire with chain fields and semantic receipt
   reconstruction; it performs no I/O.
2. ~~Pure anchored recovery classification.~~ Implemented over concatenated
   records with exact committed-prefix metadata and named incomplete/corrupt
   tails; it performs no I/O or repair.
3. ~~Snapshot-bound capability writer with explicit crash points and separate
   repair authority.~~ Implemented with a deterministic allocation-free backend.
4. ~~Descriptor-relative POSIX file adapter and subprocess recovery under
   platform lock/sync/identity semantics.~~ Implemented on the macOS host;
   native Linux filesystem campaigns remain.
5. Publication-before-deallocation ordering without double deallocation.
6. Durable retirement and file-publication ordering.
7. Multi-bundle and parent-checkpoint reachability composition.
8. Allocator campaigns covering non-tail reuse, fragmentation, RSS, and peak
   memory without conflating them with logical accounting.
9. ResourceBank/LeaseTree reacquisition and end-to-end continuation restore.

See [Continuation Object Sweep Journal](CONTINUATION_OBJECT_SWEEP.md) for the
non-destructive prepare/abort boundary and
[Continuation Object Collection Plan](CONTINUATION_OBJECT_COLLECTION.md) for
eligibility evidence, and
[Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for the
portable commit-evidence format, and
[Continuation Object Sweep Writer](CONTINUATION_OBJECT_SWEEP_WRITER.md) for its
least-authority modeled publication boundary, and
[Continuation Object Sweep File Adapter](CONTINUATION_OBJECT_SWEEP_FILE.md) for
the real-file implementation and its claim boundary.
