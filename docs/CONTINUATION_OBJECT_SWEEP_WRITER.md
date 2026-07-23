# Continuation Object Sweep Writer

Status: **prototype capability and crash-conformance state machine**. Native Zig
and an independent Python model implement the same snapshot binding, append
order, recovery decisions, writer poisoning, and explicit incomplete-tail
repair policy. The included storage backend is deterministic caller-owned
memory. It does not claim operating-system durability.

This layer turns the sweep record's body/footer plan into a least-authority
publication contract:

```text
exclusive storage lease
        │
        ├─ immutable snapshot
        │    storage epoch + lease generation
        │    observed length + capacity
        │    stream digest + snapshot digest
        │
        ├─ append capability
        │    body write → body sync → footer write → footer sync
        │    no read / truncate / rename / delete
        │
        └─ separately requested repair capability
             exact incomplete tail → truncate verified prefix → sync
             no append / rename / delete

any uncertain I/O result → poison local state → crash/reopen classification
```

## Why the snapshot is part of the capability

An exclusive lock alone does not prove which bytes the caller classified. A
`StorageSnapshotV1` binds:

- writer ABI;
- storage epoch;
- exclusive-lease generation;
- observed byte length and maximum capacity;
- SHA-256 of the exact observed stream; and
- a domain-separated snapshot root over those fields.

`WriterV1.openClean` and `RepairerV1.init` recompute that binding from the
caller-supplied bytes. Changed bytes, stale generations, released leases,
different lengths, and different capacities reject before I/O. Append authority
also checks the backend's current length before every record. The same open
writer may advance that length, but a copied pre-append capability cannot reopen
an older snapshot after storage has grown. Entering repair revokes append
authorization for that lease generation.

For the first deterministic record, storage epoch 41, lease generation 1, and a
2,352-byte capacity, the shared Zig/Python values are:

| Field | SHA-256 |
| --- | --- |
| Observed 784-byte stream | `3b3fb1adf8ed0b13b8e8719a3ade7dbb2a7133c0ea6d307598ee3b2941d7c6d3` |
| Storage snapshot | `b02d101a0c8152e112562ed4d70ea5b957192ba5886e35188ea8ef9a9aee3897` |

These are fixture identities, not authentication. A production adapter must
acquire and validate its exclusive lease at a trusted boundary.

## Append state machine

Before the first write, the writer verifies the complete record, exact epoch,
next sequence, previous committed root, and remaining capacity. Preflight
rejection leaves the writer ready and performs no I/O.

Once I/O begins, the writer is poisoned until all four operations succeed:

| Phase | Required effect | Crash evidence that may reopen |
| --- | --- | --- |
| body write | Append exactly 736 canonical bytes | Prior clean prefix or a 1–736 byte body tail |
| body sync | Make the complete body durable before footer publication | Complete body without footer |
| footer write | Append exactly 48 canonical commit bytes | Complete body plus a 1–48 byte footer prefix |
| footer sync | Make the complete footer durable | New record enters the verified committed chain |

An error before or after any operation is uncertain. The same writer cannot
retry, because the record may already be partly or fully present. The caller
must release the process-local state, reacquire storage, read a fresh snapshot,
and run anchored classification. A complete valid record is accepted on reopen
even if the previous process did not receive success from its final sync.

## Recovery and repair decisions

`planRecoveryV1` converts classification evidence into one of three actions:

| Classification | Action |
| --- | --- |
| `clean` | `open_clean` |
| `short_body_tail`, `body_without_footer`, `partial_footer_tail` | `repair_incomplete_tail` |
| `corrupt_record` | `reject_corrupt` |

Repair is never implicit. `WriterV1.openClean` rejects an incomplete tail. A
caller must separately ask the exclusive lease to prepare repair under the same
pinned snapshot. The lease reruns classification before it mints the capability
and binds the exact current length, verified-prefix target, discarded tail, and
final record root. The truncate callback accepts no caller-selected target. A
complete corrupt record never receives a repair capability. `committed_bytes`
is therefore evidence used by one explicit policy, not a general truncation
grant.

Any truncate or repair-sync error poisons the repairer. Because an unsynced
truncate may leave either the old or new length after a crash, the deterministic
backend retains both as admissible outcomes. Even successful repair requires
lease release, a fresh snapshot, and clean reopen before append authority can be
used.

## Capability separation

The public adapter contract deliberately has two non-overlapping operation
sets:

- `AppendCapabilityV1` exposes body/footer append and sync callbacks only;
- `RepairCapabilityV1` exposes one pre-bound truncate and sync callback only.

Neither capability exposes path lookup, directory traversal, rename, payload
deletion, object-store mutation, network, clock, or allocator authority. A real
adapter remains responsible for preventing forged in-process capabilities,
binding callbacks to one locked file, and rejecting calls after lease release.

## Deterministic crash backend

`DeterministicStorageV1` uses caller-owned fixed-capacity bytes and allocates no
heap memory. It models:

- one exclusive generation at a time;
- stale capability rejection;
- exact operation-order tracing;
- errors before and after every I/O call;
- partial body and footer writes at an exact byte count;
- the last synchronized length and current volatile length;
- crash survival of any prefix between those lengths; and
- reverse uncertainty when an unsynced truncate shortened the live view.

The reference backend contains no real file handle. It exists so filesystem,
object-store, or remote-log adapters can be checked against one deterministic
contract before receiving external authority.

## Verification

```sh
zig test src/core/continuation_object_sweep_writer.zig -OReleaseSafe
python3 -m unittest bench.tests.test_continuation_object_sweep_writer
zig build continuation-sweep-record-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Both implementations cover:

- all eight before/after outcomes across four append calls;
- all 737 body-write prefixes and all 49 footer-write prefixes;
- every incomplete second-record tail from 1 through 783 bytes;
- clean, incomplete-body, incomplete-footer, and corrupt reopen decisions;
- exclusive acquisition, stale generation/snapshot reuse, byte mutation, and
  capacity checks;
- poisoned append and repair state; and
- both admissible crash lengths around an uncertain truncate.

The focused native file currently runs 44 tests including imported record,
sweep, store, bundle, and capsule invariants. The independent Python writer file
adds six test methods over the same phase matrix and golden snapshot.

## What this proves

The retained fixtures prove allocation-free state-machine conformance,
cross-language snapshot identity, operation ordering, fail-closed recovery
decisions, and exhaustive modeled byte-boundary behavior.

The deterministic backend alone does not prove:

- filesystem, device, or distributed-log durability;
- advisory or mandatory lock behavior on a promoted platform;
- short-write and sync semantics of a particular adapter;
- directory-entry durability, replacement resistance, or path safety;
- process restart of live AI state;
- lower RSS, disk usage, latency, or energy.

The downstream descriptor-relative POSIX adapter now provides platform-specific
locking, write-all loops, file and directory sync, fresh-read reopen, identity
fences, and subprocess-death tests on the macOS host. It does not turn the
deterministic backend into power-loss evidence. Native Linux filesystem
campaigns remain pending. The downstream ordered commit path now syncs an exact
predicted receipt before in-memory payload removal and reconciles old/new
snapshots. The payload-file layer now carries that authority into canonical
payload-byte promotion across seven process-death boundaries. A separate
ownership-manifest prototype reacquires logical ResourceBank/LeaseTree state;
later layers now reconstruct paged KV and prove a model-free natural-exit
restart. Object-store lifecycle metadata and atomic whole-checkpoint crash
recovery remain pending.

See [Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for
the wire format and pure classifier, and
[Continuation Object Sweep File Adapter](CONTINUATION_OBJECT_SWEEP_FILE.md) for
the real-file implementation and its claim boundary, and
[Continuation Object Payload File](CONTINUATION_OBJECT_PAYLOAD_FILE.md) for the
durable payload-byte transition, and
[Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for the
in-memory transition whose evidence is published.
