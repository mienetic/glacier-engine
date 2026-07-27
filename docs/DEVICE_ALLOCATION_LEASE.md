# Device Allocation Lease V1

`DeviceAllocationLeaseV1` is the first resource-authority layer after
deterministic device selection. It binds one exact selection decision to a
committed `ResourceBank` parent, an adapter-quoted multi-buffer manifest, and a
generation-fenced backend object set.

This contract answers a narrow question:

> Was the exact replayed adapter-quoted accounting charge admitted before allocation,
> and was that charge retained until every acquired object was freed?

Two adapters now exercise the contract. The deterministic fake proves the
portable lifecycle, injected failure, and recovery rules. The native Metal
adapter creates and directly inspects real Shared `MTLBuffer` resources on the
host running its hard gate. Neither adapter proves physical-page residency,
dispatch ownership, or performance. A separate
[LeaseTree Device Allocation](LEASE_TREE_DEVICE_ALLOCATION.md) coordinator now
reuses these adapter contracts under execution-owned allocation nodes without
changing this ChildLease ABI.

V1 accepts only a present accelerator selection with allocation capability and
`fallback_used == 0`. “Backend-neutral” describes the portable contract shape;
it does not mean that this V1 allocation lifecycle accepts CPU fallback.

## Why selection and allocation stay separate

`DeviceSelectionReceiptV1` remains immutable decision evidence. It does not
gain a pointer, allocator handle, queue, or publication permit.

The allocation layer replays the complete selection against the requirement
and inventory, then adds distinct live authorities:

- a backend allocator authority and epoch;
- the exact adapter context and quote/allocate/free callback instance;
- the exact `ResourceBank` instance and one of its committed receipts;
- one exact `ResourceBank.ChildLease` charge;
- coordinator slot and generation;
- opaque backend object identities and generations; and
- a terminal or recovery receipt.

This separation lets discovery and policy remain portable while allocator
lifetime stays explicit and fail closed.

## Canonical byte meanings

Every manifest entry records two quantities:

- `requested_bytes`: payload bytes requested by the plan;
- `charged_bytes`: the exact quantity returned by the bound adapter quote.

The fake V1 authority declares a power-of-two allocation granularity and rounds
requested bytes upward with checked arithmetic. The native Metal V1 authority
uses granularity one: its replayable charge is the exact logical
`MTLBuffer.length`, equal to the requested length. Admission invokes the live
quote callback again and requires byte-for-byte equality with the sealed quote
before any Bank mutation. Every quote callback is required to be
side-effect-free and replayable.

The manifest records both requested and charged largest/total values.
`DeviceRequirementV1.largest_single_allocation_bytes` and
`total_device_bytes` must equal the charged values exactly, not merely bound
them from above. Unknown zero ceilings reject.

`charged_bytes` is an adapter accounting quantity. It is not evidence of:

- an operating-system physical page;
- device residency;
- committed GPU memory;
- allocator metadata outside the quote policy; or
- memory that remained resident for any duration.

The Metal adapter separately retains direct per-object `MTLResource.allocatedSize`
in `MetalAllocationObservationV1`. Metal exposes that value only after
creation, so it is not used as a V1 pre-allocation quote. Device-wide
`currentAllocatedSize` is not used to infer object ownership. See
[Native Metal Allocation Adapter](NATIVE_METAL_ALLOCATION.md).

## Admission and materialization

The synchronous V1 sequence is:

```text
selection + requirement + inventory
                │ replay
                ▼
authority + live adapter quote + canonical manifest
                │ validate, no Bank mutation
                ▼
committed parent Receipt (device_bytes = 0)
                │ open ChildLease with exact charged total
                ▼
charged / unmaterialized admission
                │ allocate each object
          ┌─────┴──────────┐
          │ all succeeded  │ failure or cancellation
          ▼                ▼
 generation-fenced     free every acquired object
 live object set       before closing ChildLease
          │                │
          │                ├─ cleanup complete → terminal receipt
          │                └─ free failed → recovery_required, charge retained
          ▼
 release in reverse order
          │
          ├─ all freed → close ChildLease → released receipt
          └─ free failed → recovery_required, charge retained
```

The parent receipt must:

- still be committed in the exact Bank;
- have `device_bytes == 0`, so this V1 owns the complete device charge;
- have `queue_slots` equal to the selected requirement; and
- use a Bank initialized with caller-owned `ChildSlot` storage.

Opening the child happens before the first allocation callback. While the child
is active, `ResourceBank.release(parent)` rejects, so a copied parent receipt
cannot return the logical budget early.

V1 permits exactly one materialized lease per adapter context. Both adapters
enforce that limit and their live-object ceilings under adapter-local mutexes,
including when multiple coordinators share the same adapter. Supporting
concurrent materialized leases requires authority-wide collision quarantine
plus an inspect/reconcile ABI and is intentionally deferred.

## Cancellation

Materialization checks a synchronous cancellation probe at every boundary:
before allocation ordinal zero, between every pair of allocations, and after
the final allocation.

The callback/context pair is validated once before the first object is
allocated. Cancellation and adapter callbacks execute while the coordinator
mutex is held and must not re-enter that coordinator.

Cancellation never changes an already-active lease. During admission it:

1. fences the coordinator slot under its generation;
2. calls the backend free callback for acquired objects in reverse order;
3. closes the Bank child only after every free succeeds; and
4. emits a canonical terminal receipt.

This is bounded same-process cancellation. It is not asynchronous
post-dispatch cancellation.

## Recovery

The adapter contract gives callbacks strict failure semantics:

- allocation error means no object was created;
- free error means the named object remains live and can be retried.

If any free fails, the coordinator keeps:

- the exact parent and child authority;
- every outstanding backend object identity;
- the intended terminal outcome;
- the full original lease/object-set roots when release had begun; and
- a generation-fenced `AllocationRecoveryV1`.

`outstanding_bytes` is summed from the sealed allocation-call charges, never
from an unvalidated backend-object response. This keeps recovery conservative
even when the response that triggered cleanup reported zero or an overflowing
value.

The ChildLease charge is not reduced. A retry may free the remaining objects
and settle the Bank child. Copied recovery tickets and copied live leases fail
after the state transition.

An adapter whose release result can be ambiguous cannot implement this V1
callback truthfully. A later native ABI must expose explicit inspect/reconcile
evidence and keep the charge conservative while the outcome is unknown.

## Pointer-free evidence

Portable values use domain-separated SHA-256 over explicit little-endian
fields. Raw struct bytes and padding are never hashed.

The evidence chain is:

```text
authority
  └─ quote per binding
      └─ canonical manifest
          └─ allocation request
              └─ Bank ChildLease-bound admission
                  └─ allocation calls
                      └─ opaque backend objects
                          └─ backend-object-set root
                              └─ live lease
                                  └─ released or recovery receipt
```

Hashes detect accidental substitution and make independent replay possible.
They are not authentication. Live authority always requires the exact
coordinator slot, generation, adapter context/function identity, adapter
authority, `ResourceBank` pointer identity, and Bank state. A separately
recreated Bank with identical deterministic fields is not interchangeable.

Within one adapter authority epoch, `(backend_object_sha256,
backend_object_generation)` is the unique live-object namespace. The
single-materialized-lease V1 avoids ambiguous cross-lease aliases; a future
multi-lease ABI must quarantine the entire affected authority rather than free
an alias speculatively.

## Fake adapter evidence

The deterministic fake adapter uses fixed caller-owned object slots. Tests
cover:

- cancel followed by slot reuse with a new generation;
- exact-capacity materialize and release;
- allocation failure at every ordinal;
- cancellation at every boundary;
- partial-allocation rollback;
- adapter-reported byte drift;
- zero and maximum malformed byte reports followed by cleanup failure;
- self-consistent forged quotes rejected by live re-quote;
- misaligned quotes rejected before admission;
- free failure retaining Bank charge;
- cleanup recovery and stale recovery rejection;
- foreign authority rejection;
- exact adapter-instance binding;
- mirrored same-epoch Bank rejection;
- one materialized lease enforced across coordinators sharing an adapter;
- malformed cancellation probes rejected before allocation;
- double cancel, double release, and copied-handle rejection; and
- zero fake objects and zero device charge after terminal cleanup.

The independent Python oracle reproduces the canonical roots and mutation
campaign without parsing Zig sources or loading Glacier symbols.

Focused checks:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_allocation_lease.zig -OReleaseSafe
python3 -m unittest bench.tests.test_device_allocation_lease
```

## Native and cross-target evidence

The fake tests run as ordinary host unit tests. They do not simulate a GPU
instruction set or driver. They exercise the portable state machine through a
deterministic adapter.

The native macOS allocation hard gate uses the host's real `MTLDevice` and
direct Shared buffers. It verifies per-resource device identity, logical
length, `allocatedSize`, storage/cache modes, ChildLease accounting, release,
generation-fenced reuse, foreign/stale-token rejection, distinct native
adapter authorities, an independently counted shim registry, and concurrent
registry balance. A separate LeaseTree case in the same gate acquires an exact
object-set pin, submits one four-buffer shader command, checks it against a CPU
oracle, consumes completion, and proves final zero ownership. That case
validates the execution-owned path rather than adding dispatch authority to
this compact ChildLease V1. Neither case claims residency or performance. The
separate Metal readiness gate also uses a real shader pipeline and command
buffer for its bounded diagnostic profile.

Focused native allocation check:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-allocation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Foreign-target builds prove that the portable source and public types compile.
They do not prove native allocator, driver, device, or operating-system
behavior.

## Current limitations

V1 deliberately does not provide:

- a portable-compute or additional vendor allocation adapter;
- physical-page commitment/reclamation or residency evidence;
- device-loss detection, quarantine, or migration;
- queue, stream, dispatch, or publication authority;
- asynchronous or cross-process cleanup;
- concurrent materialized leases within one adapter context;
- multi-device partitioning;
- retained device/driver support ranges;
- direct telemetry; or
- latency, throughput, power, thermal, or energy evidence.

`ResourceBank` opts into either the `ChildLease` sidecar or the `LeaseTree`
sidecar. This coordinator remains the compact receipt-bound path. Execution
owners use the separate LeaseTree coordinator, which has distinct
admission/lease/recovery/terminal evidence and keeps Bank mutation permits
private.

## Next slices

The next accelerator-runtime work is intentionally split:

1. add a reserve/materialize/settle ABI if the post-creation
   `MTLResource.allocatedSize` observation must be charged rather than V1
   logical resource length;
2. add device-loss events, quarantine, and mandatory fresh selection;
3. add deterministic two-device partition planning before live multi-device
   execution;
4. add residency as a separate optional authority and evidence contract;
5. add asynchronous queue scheduling above the completed bounded LeaseTree
   dispatch-lifetime pin; and
6. replicate native lifecycle evidence on named OS/device/driver cells.

Allocation ownership can be proven before residency. Neither one should be
inferred from a cross-build or from a device-wide dynamic memory sample.
See [Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md) for the distinct
execution-owned pin contract.
