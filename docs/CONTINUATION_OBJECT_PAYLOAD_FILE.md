# Continuation Object Payload File

Status: **prototype durable payload-byte adapter with process-death evidence**.

The payload file is the first durable backing boundary for continuation object
bytes. It does not serialize live runtime ownership or lifecycle metadata.
Instead, it gives one exact sweep record a canonical old/new payload snapshot
and a recoverable copy-on-write filesystem transition.

Implementation:

- `src/core/continuation_object_payload_store.zig`
- `src/core/continuation_object_payload_file.zig`
- `bench/continuation_object_payload_store.py`
- `bench/continuation_object_payload_file.py`

## Canonical payload snapshot

The snapshot wire contains:

- magic and schema version;
- exact tenant scope;
- entry and payload-byte counts;
- canonical entries containing byte length, tenant-bound digest, and payload;
  and
- a domain-separated footer over the complete body.

Entries sort by digest and length. Every payload is rehashed against its tenant
scope during decode. Duplicate, reordered, truncated, extended, foreign-tenant,
or mutated inputs reject. Encoding performs validation and capacity checks
before changing caller output.

`previewReclaimV1` verifies the active wire, removes only an exact canonical
target set into caller-owned candidate storage, and returns:

- old and predicted new payload snapshot roots;
- exact encoded lengths and logical payload counts;
- target root;
- freed entries and bytes; and
- a functional preview root.

The active bytes remain unchanged.

## Durable reclaim record

The fixed 968-byte reclaim record binds:

- storage epoch and tenant scope;
- the already-published sweep-record root;
- all exact target references in a bounded fixed array;
- old/new payload snapshot roots and encoded lengths;
- target root and reclaim accounting;
- payload-preview root and challenge; and
- a domain-separated record root.

Persisting exact targets is important: a fresh process reconstructs sweep
authority from the fixed sweep record plus this canonical list. It does not
depend on a surviving native `CommitPreviewV1` value.

## Copy-on-write protocol

One stable lock inode serializes the directory while the active payload inode
may change:

1. verify the anchored sweep publication;
2. derive the exact payload successor without active mutation;
3. write, sync, and directory-sync the reclaim record;
4. write and sync a deterministic candidate snapshot;
5. reverify that the active snapshot is still the exact old root;
6. atomically rename the candidate over the active file;
7. sync the directory; and
8. reopen and accept only the exact new root.

The plan and candidate names derive from the reclaim-record root. Retrying an
exact existing plan or candidate is idempotent; changed bytes reject.
Publication and recovery also require the record's tenant and storage epoch to
match the active lease before any candidate can be promoted. After rename and
directory sync, the adapter reopens and verifies the active successor instead
of trusting its in-memory candidate.

## Process-death matrix

The native demo and independent Python test terminate a worker with `SIGKILL`
after each boundary:

1. reclaim-plan write;
2. reclaim-plan file sync;
3. reclaim-plan directory sync;
4. candidate write;
5. candidate file sync;
6. atomic rename; and
7. active-directory sync.

After every death a fresh lease reconstructs targets from durable records.
Crashes before rename recover from the old snapshot; crashes after rename
recognize the new snapshot. A second recovery is always `already_applied`.
Both implementations also reject a valid unrelated third payload snapshot.

The shared golden roots are:

| Evidence | SHA-256 |
| --- | --- |
| Sweep record | `871e9f220c7435070578bde3731bc7f30befa532cfa29b981292304a2a7cc977` |
| Payload reclaim record | `f1105b7058cc90e1ad9ec9ba09abfe78e34b6cbbebb014cf6b372b35f926de34` |

Run focused verification:

```sh
zig test src/core/continuation_object_payload_store.zig -OReleaseSafe
zig test src/core/continuation_object_payload_file.zig -OReleaseSafe
zig build continuation-payload-file-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest \
  bench.tests.test_continuation_object_payload_store \
  bench.tests.test_continuation_object_payload_file
```

The next authority layer is
[Continuation Ownership Restore](CONTINUATION_OWNERSHIP_RESTORE.md), which binds
this verified payload root into a fresh ResourceBank/LeaseTree before restored
objects may become live.

## Evidence boundary

This prototype proves on the retained host:

- canonical durable payload-byte snapshots;
- exact target reconstruction after process death;
- plan publication before payload replacement;
- stable exclusive locking across active-inode replacement;
- old/new copy-on-write recovery and idempotence; and
- native/Python agreement for the retained fixture.

It does not yet prove:

- device power-cut durability;
- native Linux filesystem behavior beyond compilation;
- durable lease, quarantine, reference-count, or repair metadata;
- paged-KV and other runtime object reconstruction under reacquired ownership;
- paged-KV, RNG, sampler, tokenizer, or output restoration;
- live request restart; or
- lower RSS, disk use, latency, or energy.

The next continuation layer persists and reacquires exact ownership/lifecycle
state before any restored payload becomes runtime-visible.
