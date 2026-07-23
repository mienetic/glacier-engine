# Continuation Object Sweep File Adapter

Status: **prototype POSIX filesystem adapter with real process-death evidence**.
The Zig adapter and independent Python implementation use descriptor-relative
lookup, exclusive advisory locks, stable file identity, ordered file sync, and
explicit incomplete-tail repair. Native tests run against the host filesystem;
Linux implementations are cross-compiled but still need retained native
filesystem campaigns.

This layer connects the allocation-free
[sweep writer contract](CONTINUATION_OBJECT_SWEEP_WRITER.md) to one real file
without widening append or repair authority:

```text
caller-opened directory descriptor
              │
              └─ one validated component name
                    │
                    ├─ open without following final symlink
                    ├─ exclusive advisory lock
                    ├─ regular file + one hard link + private mode
                    ├─ device/inode/length identity fence
                    └─ caller-owned snapshot buffer
                              │
             ┌────────────────┴────────────────┐
             │                                 │
       append capability                 repair capability
 body → sync → footer → sync       exact truncate → sync
 no truncate/rename/delete         no append/rename/delete
```

## Acquisition contract

`FileLeaseV1.create` and `FileLeaseV1.open` receive:

- an already opened `std.fs.Dir`;
- one component name of at most 255 bytes;
- a nonzero caller-pinned storage epoch;
- a maximum stream length;
- caller-owned memory for the observed stream; and
- optional non-allocating phase observation.

Names that are empty, `.`, `..`, contain a separator or NUL, or exceed the
component limit reject before opening storage. The adapter never accepts an
absolute path and does not traverse child directories.

The final component is opened with close-on-exec and no-follow semantics. The
adapter then requires all of the following:

- the descriptor and directory entry are the same device/inode pair;
- both views are regular files;
- the file has exactly one hard link;
- group and other permission bits are absent by default;
- the observed length fits both the configured maximum and caller buffer; and
- a second identity check after reading returns the same identity and length.

The directory descriptor remains caller-owned and must stay open for the full
lease lifetime. The returned lease owns only the file descriptor and its
advisory lock. Once append or repair capabilities are minted, the lease must
remain at a stable address until those capabilities are discarded; moving it
would invalidate their context pointer. `close` invalidates the lease generation
before releasing the descriptor and lock.

## Creation durability

Creation uses an exclusive new-file operation with mode `0600`. Before the
lease returns, it:

1. verifies the empty descriptor and directory entry;
2. synchronizes the file;
3. synchronizes the containing directory;
4. verifies the same identity and zero length again; and
5. hashes the empty observed stream into a new storage snapshot.

If an error occurs after the exclusive create, an empty artifact may remain.
The adapter does not silently delete that evidence because failure of one sync
also makes cleanup durability uncertain.

## Append and repair ordering

The file adapter implements the callbacks consumed by `WriterV1`:

```text
pwrite-all exact 736-byte body at committed length
verify directory entry + descriptor identity and length
file sync
verify identity and length
pwrite-all exact 48-byte commit footer
verify identity and length
file sync
verify identity and length
```

Writes use explicit offsets rather than shared seek state. Each phase checks the
generation, snapshot binding, expected phase, current length, capacity, and
namespace identity. The lease enters `poisoned` before every fallible external
operation. Only a completed operation plus its postcondition advances the phase.

Repair authority is minted only after anchored classification returns an
incomplete tail. It binds the exact old length and verified committed prefix.
The adapter truncates only that pre-bound target, synchronizes the file, and
requires close/reacquire before append.

## Publication-ordered commit

The adapter now joins the file boundary to the in-memory destructive sweep:

1. `previewCommitV1` regenerates the exact targets and predicts before/after
   accounting, the post-state snapshot, and both receipts without mutation;
2. `prepareCommitRecordV1` encodes that prediction as the existing fixed
   784-byte sweep record;
3. `publishThenCommitV1` completes body write, file sync, footer write, and file
   sync before calling the destructive preview-bound primitive; and
4. `recoverPublishedCommitV1` accepts only a fully anchored record plus either
   the exact old snapshot (`applied`) or exact predicted new snapshot
   (`already_applied`).

The commit demo injects a failure immediately after synced publication. Store
payloads and counters remain unchanged, fresh-open recovery applies the
transition once, and a repeated recovery performs no second deallocation.
Both the native demo and independent Python model reject a valid third store
state; the Python model also repeats record-mutation rejection.

This closes the ordering gap for the in-memory payload store. The low-level
in-memory commit primitive remains available for authority-free fixtures; a
caller requiring publication ordering must use the ordered adapter. The
downstream [payload file](CONTINUATION_OBJECT_PAYLOAD_FILE.md) now carries the
exact published sweep authority into canonical payload-byte promotion and real
process-death recovery.

## Replacement and link defense

An advisory lock protects cooperating users of the opened inode; it does not
freeze a POSIX directory namespace. A different process may still rename or
replace the visible entry.

To fail closed, the adapter compares the locked descriptor with a no-follow
directory-entry stat before and after every operation. A replacement, unlink,
new hard link, permission widening, unexpected length, or identity change
poisons the lease. Tests replace the entry immediately after the body write:
the replacement remains empty, the old moved inode contains only the body, and
publication rejects before sync/footer continuation.

This is replacement **detection**, not immunity against a hostile kernel or a
non-cooperating process that can mutate and restore the namespace entirely
between checks. A deployment must protect the containing directory and treat
the passed directory descriptor as trusted authority. The adapter also cannot
detect a same-length in-place overwrite that preserves the visible device,
inode, link count, mode, and length between checks; writers sharing this file
must honor the advisory lock.

## Process-death matrix

The build demo launches a separate native worker and sends `SIGKILL` after each
completed operation:

| Death boundary | Fresh-open result |
| --- | --- |
| body write | incomplete body; explicit repair to prior prefix |
| body sync | incomplete body; explicit repair to prior prefix |
| footer write | complete record accepted by anchored verification |
| footer sync | complete record accepted by anchored verification |
| repair truncate | verified prior prefix |
| repair sync | verified prior prefix |

The independent Python adapter repeats the same six process deaths and also
checks lock contention in a second process.

Process death does not emulate sudden power loss: the operating system may keep
dirty pages and metadata alive after one process is killed. Power-loss
uncertainty remains represented by the deterministic storage model, including
both old and new lengths around an unsynchronized truncate. Hardware and
filesystem-specific power-cut evidence is a separate promotion gate.

## Resource properties

The Zig adapter:

- performs no heap allocation;
- stores the component name in a fixed 255-byte field;
- reads into caller-owned storage;
- keeps one file descriptor and one borrowed directory descriptor;
- writes records directly without a duplicate stream buffer; and
- reuses the existing snapshot, classifier, writer, and repair state machines.

These are code-path properties, not proof of lower RSS or storage overhead for
a complete application. The Python implementation is an independent verifier,
not a resource-equivalent runtime.

## Verification

```sh
zig test src/core/continuation_object_sweep_file.zig -O ReleaseSafe
zig test src/core/continuation_object_sweep_file.zig -O ReleaseFast
python3 -m unittest bench.tests.test_continuation_object_sweep_file
zig build continuation-sweep-file-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-sweep-commit-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-payload-file-demo -Doptimize=ReleaseSafe -Dmetal=false
```

The focused native root currently runs 49 tests including imported record,
writer, sweep, store, bundle, and capsule invariants. Four Python methods cover
independent file semantics, six child deaths, cross-process lock exclusion, and
namespace/link/permission rejection.

The demo emits
`glacier.continuation-object-sweep-file/demo-v1` with four append deaths, two
repair deaths, both required incomplete-tail repairs, and explicit
`power_loss_emulated: false`.

## Claim boundary and next layer

This prototype does not yet prove:

- native Linux filesystem behavior beyond compilation;
- network, FUSE, removable, or copy-on-write filesystem guarantees;
- protection from privileged or kernel-level namespace mutation;
- detection of same-length in-place writes by a process ignoring the lock;
- power-cut durability on any device;
- durable lease, quarantine, reference-count, or repair metadata;
- ResourceBank/LeaseTree ownership reacquisition; or
- live restoration of model, tokenizer, KV, RNG, sampler, and output state.

Canonical payload-byte durability is implemented in the downstream
[Continuation Object Payload File](CONTINUATION_OBJECT_PAYLOAD_FILE.md). The
next continuation milestone persists lifecycle metadata and reacquires exact
runtime ownership before any restored payload becomes visible.
