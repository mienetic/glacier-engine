# Continuation Object Lifecycle v1

Status: **prototype deterministic lease and repair state machine**. Native Zig
and independent Python implementations share canonical grant, receipt, and
snapshot roots. Acquire, renew, release, explicit expiry, quarantine fencing,
trusted-source repair, stale-generation rejection, and accounting verification
are implemented. Wall-clock integration, concurrent access, replica transport,
durable recovery, destructive collection, and remote attestation are not. A
separate dry-run planner now verifies reachability and collection eligibility.

The lifecycle layer answers two questions that a reference count cannot:

1. which owner may rely on an object until which declared logical tick; and
2. which exact authority may replace quarantined bytes from which declared
   source.

It adds no filesystem, network, clock, or scheduler authority. The caller
supplies logical ticks and separately trusted grants. Every transition is exact,
bounded, and represented in the full store snapshot.

## State machine

```text
                        acquire(generation + 1)
                ┌────────────────────────────────┐
                │                                ▼
          live / unleased                  live / leased
                ▲                         generation = g
                │                         owner + expiry
                │                                │
       release or expire                         │ renew
       exact receipt only                        │ generation = g + 1
                │                                │
                └────────────────────────────────┘
                │
                │ quarantine (fences active receipt)
                ▼
        quarantined / unleased
                │
                │ exact repair grant + verified candidate
                ▼
          live / unleased
        repair_generation + 1
```

There is at most one active lease per stored blob. A lease does not change the
semantic reference count. A final reference release rejects while the lease is
active; non-final reference release remains legal because the payload stays
owned.

## Lifecycle grant

`LifecycleGrantV1` binds lease authority to one already validated store grant:

| Field | Meaning |
| --- | --- |
| `authority_epoch` | Must exactly equal the store authority epoch |
| `tenant_scope_sha256` | Must exactly equal the store tenant |
| `bundle_sha256` | Must exactly equal the store bundle provenance |
| `store_grant_sha256` | Canonical identity of the admitted store grant |
| `allowed_operation_mask` | Acquire, renew, release, and/or expire |
| `max_active_leases` | Store-wide active-lease ceiling under this capability |
| `max_lease_span_ticks` | Maximum `expiry - observed_tick` per transition |
| `challenge_sha256` | Nonzero caller-selected domain challenge |

Its canonical identity is:

```text
SHA256(
  "glacier-continuation-store-lifecycle-grant-v1\0" ||
  LE64(authority_epoch) || tenant_scope_sha256 || bundle_sha256 ||
  store_grant_sha256 || LE64(allowed_operation_mask) ||
  LE64(max_active_leases) || LE64(max_lease_span_ticks) ||
  challenge_sha256
)
```

The shared fixture lifecycle-grant root is
`cfd5df486b00f6fcf2fb61792a49bd4c4ad358be183b9ec2b4df517a4b79b85b`.
The digest identifies capability contents; it is not a signature or bearer-token
authentication scheme.

## Logical time contract

The lifecycle layer never reads a clock. Acquire and renew receive
`observed_tick` and `expires_at_tick`; expire receives `observed_tick`.

- acquire requires `expiry > observed`;
- renew requires `observed < current_expiry` and `new_expiry > current_expiry`;
- each proposed window must be no larger than `max_lease_span_ticks`;
- expiry requires `observed >= current_expiry`; and
- merely presenting a later tick does not expire anything implicitly.

Explicit expiry prevents hidden time reads from changing deterministic replay.
The embedding system remains responsible for defining the tick source,
persistence, monotonicity, and relationship—if any—to wall time.

## Generation-fenced receipt

Acquire increments the slot's retained lease generation. Successful renewal
increments it again, so the prior receipt becomes stale immediately. Release and
expiry require the complete current receipt. Quarantine clears active lease
fields while retaining the last generation; the next acquisition increments it,
preventing replay of a pre-quarantine receipt.

```text
lease_sha256 = SHA256(
  "glacier-continuation-store-lease-receipt-v1\0" ||
  LE64(target.byte_length) || target.sha256 ||
  LE64(generation) || owner_sha256 || LE64(expires_at_tick) ||
  lifecycle_grant_sha256
)
```

The shared fixture roots are:

| Transition | Generation | Receipt root |
| --- | ---: | --- |
| Acquire at tick 100, expire at 120 | 1 | `a95418f46e56d7105b73c40dc5138e56b64ff881ebf84e2cc958cf26615b348a` |
| Renew at tick 110, expire at 150 | 2 | `3ff1c7b5f4d83e40dccce97e424e4362ccd7b04920b2141f71658f2922d5069d` |

A structurally valid receipt still rejects if its generation, owner, expiry, or
lifecycle-grant root no longer equals the active slot.

## Quarantine fence

Quarantine has safety priority over an active lease. The transition:

1. validates the nonzero quarantine reason and exact object key;
2. clears the current lease-receipt root, which commits owner, expiry, and grant;
3. decrements the active-lease counter;
4. retains the last lease generation; and
5. moves the entry to quarantined state, where reads and acquisitions reject.

This is an invalidation fence, not proof that a consumer stopped using bytes it
already copied. Embeddings must pair the receipt with their own execution
ownership checks before publishing AI-visible state.

## Repair grant

Repair authority is deliberately narrower than store or lifecycle authority.
`RepairGrantV1` binds one target blob, one expected quarantine reason, and one
trusted source identity:

```text
SHA256(
  "glacier-continuation-store-repair-grant-v1\0" ||
  LE64(authority_epoch) || tenant_scope_sha256 || bundle_sha256 ||
  store_grant_sha256 ||
  LE64(target.byte_length) || target.sha256 ||
  trusted_source_sha256 || expected_quarantine_reason_sha256 ||
  LE64(max_repair_bytes) || challenge_sha256
)
```

The shared fixture repair-grant root is
`5d4fa957f3e163b5fc3cf7cb2fed8fcc8df28eaa74cff1b574c56ee69e787e7a`.

`repairV1` rejects unless all of the following hold before mutation:

- authority epoch, tenant, bundle, and store-grant identity match;
- target length/root exactly match the quarantined slot;
- presented source identity equals the grant's trusted source;
- recorded quarantine reason equals the grant's expected reason;
- no lease is active;
- target length fits `max_repair_bytes`;
- recomputing the tenant-bound blob identity over candidate bytes yields the
  exact target; and
- candidate bytes do not overlap store metadata or any owned payload.

Only then are bytes copied into the existing equal-length allocation. The slot
returns to live state and its repair generation increments. Source identity is
retained in the repair receipt instead of being duplicated in every store slot.
No failure remains after the first mutation, so the transition is atomic within
this single-threaded in-memory boundary.

The repair receipt binds target, repair generation, source, prior quarantine
reason, repair grant, and the resulting full snapshot:

```text
repair_sha256 = SHA256(
  "glacier-continuation-store-repair-receipt-v1\0" ||
  LE64(target.byte_length) || target.sha256 || LE64(repair_generation) ||
  source_provenance_sha256 || quarantine_reason_sha256 ||
  repair_grant_sha256 || snapshot_sha256
)
```

The shared fixture repair receipt is
`59d39a2e4ab40382012505a326e3bec3f8f1f27453d1a47928c3a4f27e282875`.
Source identity remains a trusted declaration, not proof of transport security,
remote possession, freshness, or independent operator identity.

## Full snapshot v2

The v1 content/accounting snapshot remains stable. `snapshotRootV2` hashes:

```text
"glacier-continuation-store-snapshot-v2\0" ||
snapshot_v1 || LE64(active_leases) || LE64(repair_count) ||
for each occupied slot in native index order:
  LE64(slot_index) || LE64(lease_active) || LE64(lease_generation) ||
  lease_receipt_sha256 || LE64(repair_generation)
```

The shared final fixture root is
`239ea7e7555388fab740d3d1fdb8040a7f3706b102e9572c05f7dc612822e1bd`.
`repair_count` is the sum of repair generations for currently occupied slots;
final object release removes that slot's retained repair count. The standalone
repair receipt remains verifiable after collection.

This compact representation stores one receipt root rather than repeating its
owner, deadline, and lifecycle-grant fields in every slot. On the current 64-bit
fixture it uses a 3,200-byte fixed slot array and 3,480-byte store value. The
store value includes the retired-entry counter added by the collection planner.
Receipt-root compaction remains 1,152 bytes below the first expanded slot
layout. These are compile-target layout observations, not RSS measurements.

## Evidence and rejection coverage

```sh
zig build continuation-store-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_continuation_object_store
python3 -m unittest bench.tests.test_continuation_object_sweep
```

Native and independent tests cover:

- exact shared lifecycle grant, acquire, renew, repair grant, repair receipt,
  and v2 snapshot roots;
- stale generation, tampered receipt, foreign bundle, denied operation, lease
  count, invalid window, excessive span, early expiry, and final-release fence;
- quarantine invalidation of an active receipt;
- corrupt, wrong-target, wrong-source, wrong-reason, and aliased repair inputs;
- repair-generation accounting through final object release; and
- reconstruction of active lease and repair counters during full verification.

This proves deterministic state-machine conformance for the fixture. It does not
prove distributed consensus, wall-clock lease safety, crash durability, memory
savings, replica trust, secure erasure, or end-to-end restart.

## Next layers

1. ~~Sweep prepare/abort consuming an exact dry-run plan.~~ Implemented with a
   separate capability, plan regeneration, and no deallocation.
2. Destructive sweep commit with exact allocator/accounting evidence.
3. Replica transport separated from repair admission and content verification.
4. Durable transition journal with crash points before and after publication.
5. ResourceBank/LeaseTree ownership reacquisition using generation-linked
   receipts.
6. Paged-KV restore and end-to-end restart without duplicated output.
