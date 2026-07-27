# LeaseTree Device Allocation

`device_allocation_lease_tree.CoordinatorV1` is the execution-owned
device-allocation path. It binds the existing device selection, request,
adapter quote, backend object, and object-set contracts to
`ResourceBank.LeaseTreeV1` without changing the earlier `ChildLease` ABI.

The coordinator answers three lifecycle questions:

1. Was the complete adapter-quoted device charge reserved in the execution
   ownership tree before the first backend allocation?
2. Was that charge retained until every object was definitely freed under an
   irreversible `LeaseFreePermitV1`?
3. When a queue used those objects, did an exact ResourceBank pin prevent
   reclamation until the bound backend reported a safe terminal state?

The portable fake adapter proves the state machine and injected failures. The
native Metal gate runs the same coordinator against real direct Shared
`MTLBuffer` resources and submits one exact four-buffer INT4 dispatch while
the allocation set is pinned. The dispatch authority is described in
[Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md).

## Binding requirements

The surrounding execution owner prepares topology and authority:

1. commit a parent receipt whose `device_bytes` is zero;
2. open an additive LeaseTree;
3. open a device-only scope before publication binding;
4. bind the exact `(request_epoch, session_id)` publication session; and
5. initialize the coordinator with address-stable pointers to the shared tree
   token and publication sequence, plus caller-owned fixed object storage.

At admission, the object-storage length must equal the admitted manifest-entry
count exactly. Spare tail slots are not permitted for this one-wave
coordinator. The equality check happens before live quote replay and before any
Bank mutation, so a storage-shape mismatch cannot acquire backend resources or
reserve device bytes.

The device scope must be empty when the coordinator is initialized and before
each admission, and its device-byte ceiling must equal the request's complete
quoted wave. This makes two competing full-wave reservations mutually
exclusive inside ResourceBank even if their read-only empty-scope preflights
race. The scope may share a tree with sibling scopes, but no other owner may
place allocations in the device scope. Reclaim retires every direct allocation
child of that scope, so scope exclusivity is checked again before free
authority is issued.

The shared tree pointer is intentional. A sibling scope may change the current
tree generation while the device lease is live. Every owner observes the same
updated token instead of retaining incompatible by-value copies. The
coordinator keeps allocation batches, retire tickets, and free permits private;
public values contain pointer-free evidence snapshots rather than mutation
authority.

Public evidence validators also enforce the semantic root-scope topology, not
only the integrity checksums. The scope must be an active root scope of the
same tree, with the root-parent sentinel, the tree identity generation as its
parent generation, a non-sentinel Bank-global node index, nonzero
generation/node/tenant keys, an empty current claim, and a device-only ceiling
contained by the tree ceiling. The public token does not compare that global
index with the per-tree active-node count. The tree must have nonzero identity
and structural state, a current claim within its ceiling, and a generation
newer than its identity generation. Re-sealing an impossible topology therefore
does not make it admissible.

The coordinator mutex covers one coordinator only. The surrounding execution
owner must externally serialize every coordinator call with every other
mutation of the shared tree token or publication sequence. Independent owners
or unsynchronized threads are outside this contract.

Receipt-funded trees are rejected. Their current materialization endpoint is
specific to restored-publication activation, while ordinary device allocation
uses additive charge-before-allocate accounting.

## Admission and materialization

```text
current additive tree + empty device scope + idle publication session
                              │
                              │ replay selection, request, manifest and quotes
                              ▼
             reserveAllocationsForSession (whole wave)
                              │
              Bank charged; leaves reserved_unmaterialized
                              │
                              ▼
                  allocate objects in ordinal order
                    ┌─────────┴─────────┐
                    │ all valid         │ failure/cancellation
                    ▼                   ▼
       commitAllocationsAfterAllocate   reverse-free acquired objects
                    │                   │
                    ▼                   ├─ all freed → abort batch
        live LeaseTree object set       └─ free failed → recovery, charge kept
```

Admission performs every portable validation, live quote replay, coordinator
capacity check, and nonzero unique node/binding-key derivation before the Bank
mutation. `reserveAllocationsForSession` then atomically:

- charges the complete logical device-byte total;
- creates one allocation leaf per canonical manifest entry;
- marks every leaf `reserved_unmaterialized`; and
- blocks publication and session close until the wave is decided.

No allocation callback runs before that point. A successful backend response is
retained before protocol validation so a malformed response still receives a
cleanup attempt.

Every later transition replays the coordinator's cached evidence chain. The
cached request must reproduce its own root and match the admission's request,
authority, selection, capability, manifest, parent, count, and byte bindings.
Once materialized, the admission-to-lease roots, scope, leaf set, count, and
bytes must also agree. Caller-provided evidence alone cannot replace this
current-state replay.

Before invoking cancellation or adapter allocation/free callbacks, the
coordinator snapshots its exact address bindings, adapter function identity,
canonical entries, ordered leaves, calls, and backend-object evidence. Callback
return restores only through those prevalidated pointers and slices. Every leaf
is then replayed against its ordinal entry, deterministic node/binding keys,
scope parent, tenant, and exact charged-byte claim before Bank settlement.
Callback-side substitution of a later entry, leaf, call, object, or terminal
outcome therefore cannot alter the admitted wave.

The adapter's `charged_bytes` retains its existing meaning. For native Metal V1
it is exact logical `MTLBuffer.length`, not physical residency or an operating
system reclaim claim.

## Free authorization and recovery

Live release uses this order:

1. validate the exact coordinator, adapter instance, Bank, shared session,
   object set, leaf set, and exclusive scope sum;
2. call `beginRetireSubtreeForSession`;
3. compare the returned ticket count, scope identity, and claim with the live
   lease;
4. call `authorizeFree`, which irreversibly changes every leaf to
   `free_authorized`;
5. free backend objects in reverse ordinal order; and
6. call `commitFreeAfterAllocatorFree` only after no object remains.

Once free is authorized, retirement is never cancelled. A retry retains the
same private permit. Before accepting a recovery token, the coordinator
revalidates the current Bank tree, cached request/admission/lease chain, exact
allocation batch or FreePermit, coordinator identity and exact-length storage
binding, phase-valid object-slot contents, and canonical outstanding object
set. It also checks the shared publication sequence against the Bank's bound
`(request_epoch, session_id)` session while the tree decision is pending.
Sequence drift or a changed cached value rejects recovery; a cached token
cannot authorize cleanup after those private values drift.

| Recovery phase | Backend state | LeaseTree state | Accounting |
| --- | --- | --- | --- |
| `rollback_reserved` | a partial allocation prefix may remain | complete wave is `reserved_unmaterialized` | complete charge retained |
| `free_authorized` | some live objects may remain | complete wave is `free_authorized` | complete charge retained |
| `settlement_required` | no backend object remains | permit is still pending | safe overcharge retained |
| terminal | no backend object remains | device scope is empty | device charge returned |

Adapter V1 gives free errors a strict meaning: the named object remains live and
retryable. A backend with ambiguous release or device-loss outcomes needs a
later inspect/reconcile and quarantine authority; this coordinator does not
guess.

Device-loss Retirement V1 now reuses this exact release state machine for an
already quiesced allocation. A Coordinator-owned arm boundary validates its
retained lease, object set, leaves, adapter identity, Bank state, and absence
of dispatch while holding the coordinator lock, then publishes the adapter's
private loss permit before unlocking. The later ordinary `release` therefore
drops native references before committing the same FreePermit. This does not
resolve an ambiguous free or an in-flight/quarantined dispatch. See
[Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md).

## Evidence boundary

The new public values are distinct from the ChildLease evidence family:

- `LeaseTreeAllocationAdmissionV1`;
- `LeaseTreeDeviceAllocationLeaseV1`;
- `LeaseTreeAllocationRecoveryV1`; and
- `LeaseTreeAllocationTerminalReceiptV1`.

The optional dispatch phase adds:

- `LeaseTreeDispatchPinV1`;
- `DispatchTerminalEvidenceV1`; and
- `LeaseTreeDispatchCompletionV1`.

They bind canonical SHA-256 roots for the exact parent, reservation or
materialization tree observation, scope, private batch or permit authority,
ordered allocation-leaf set, publication binding, adapter authority, request,
selection, manifest, object set, outcome, and exact device-byte total.

ResourceBank tokens and their integrity fields are same-process
accidental-misuse fences. The additional SHA-256 transcripts provide
pointer-free composition evidence; neither mechanism is authentication.
`session_id` remains process-local and appears publicly only through an opaque
publication-binding digest.

## Verification

The portable tests cover:

- exact `0 → reserved → live → free_authorized → 0` accounting;
- two complete cycles with newer backend-object generations;
- cancellation at every boundary;
- allocation failure followed by partial-free recovery;
- live-release failure followed by FreePermit recovery;
- settlement failure after every backend object is already gone, without a
  duplicate free on retry;
- malformed cancellation probes with a still-cancellable charged admission;
- copied/rebound coordinator storage and foreign adapter rejection;
- oversized coordinator object storage rejected before live quotes or Bank
  mutation;
- cached request, admission, lease, object-slot, and publication-sequence drift
  rejected during transition or recovery;
- callback-side entry, leaf, call, object, adapter-binding, and outcome drift
  restored from the pre-callback lifecycle snapshot;
- reordered checksum-valid leaves rejected unless every ordinal retains its
  deterministic scope, key, tenant, and exact charged-byte binding;
- checksum-valid but semantically impossible root-scope topology rejected;
- Bank-global scope indices accepted independently of per-tree active-node
  counts;
- two coordinators racing after the same empty-scope preflight, with exactly
  one full-wave reservation admitted;
- sibling-scope isolation;
- overlapping exact object-set pins completed out of order;
- allocation release rejected while any dispatch pin remains active;
- copied, swapped, stale, foreign-adapter, and slot-reuse pin authority
  rejected without consuming either live Bank pin;
- re-sealed publication, authority, ceiling, generation, revision, and
  active-node substitutions rejected at completion composition;
- stale lease and recovery rejection; and
- receipt-funded rejection.

An independent standard-library Python oracle replays the public SHA-256
transcripts and ResourceBank integrity algorithms from fixed literals. Zig and
Python pin the same admission, lease, recovery, terminal, tree, scope, batch,
permit, leaf, call, and object roots.

Run the focused portable gate:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_allocation_lease_tree.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_allocation_lease_tree
```

The native gate additionally creates and inspects real Metal resources through
both the earlier ChildLease coordinator and the LeaseTree coordinator:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-allocation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

On the executing macOS host, the ownership cases prove three direct buffers,
exact logical `0 → 8,000 → 0` device-byte accounting, direct length and
`allocatedSize` observations, independent shim-registry balance, release under
a FreePermit, and newer generations on reuse. A separate cancellation wave
stops after two real buffers and proves both are freed before the complete
charge is returned. The pinned-dispatch case creates four exact buffers for a
37x64 INT4 matrix-vector operation, rejects release while the command pin is
live, submits those registry-owned resources to Metal, waits for completion,
checks the output against a CPU oracle, consumes the pin, and only then frees
the buffers. Cross-target compilation proves only source portability.

## Current boundary

This slice establishes allocation ownership and an exact synchronous
dispatch-to-allocation lifetime fence inside the execution LeaseTree. It does
not yet establish:

- physical residency or reclaim completion;
- post-creation `allocatedSize` settlement;
- in-flight or ambiguous device-loss reconciliation and quarantine;
- asynchronous queue scheduling, transfer ownership, or queue-depth evidence;
- concurrent materialized leases in one adapter context;
- multi-device partitioning and scheduling;
- direct utilization, power, thermal, frequency, or energy telemetry;
- cross-process cleanup; or
- a retained native device/driver support matrix.

Those remain separate authorities and evidence milestones.
