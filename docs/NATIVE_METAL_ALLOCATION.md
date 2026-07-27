# Native Metal Allocation Adapter

The native Metal allocation adapter binds the portable allocation-adapter
contract to real direct Shared `MTLBuffer` resources on macOS through both the
receipt-bound ChildLease coordinator and the execution-owned LeaseTree
coordinator. It is a bounded allocation-ownership prototype, not a residency
or performance subsystem. Its optional dispatch path adds per-adapter
**single-flight Metal async completion delivery**; it is neither a global
native queue-depth limit nor a general queue scheduler.

## What is implemented

For one exact `MetalBackend` context, the adapter:

1. revalidates the selected Metal device fingerprint and registry identity;
2. replays a side-effect-free quote for every canonical allocation;
3. lets either `ResourceBank.ChildLease` or the execution-owned additive
   LeaseTree charge the complete logical resource length before the first
   native allocation;
4. creates real buffers with
   `newBufferWithLength:options:`;
5. validates the resource's device, requested length, storage mode, cache
   mode, and direct per-resource `allocatedSize`;
6. retains only a copyable pointer-free native token in a private
   fixed-capacity slot while the shim registry owns the Objective-C resource;
7. exposes a pointer-free, generation-fenced backend object identity;
8. releases every native object before returning the ChildLease charge or
   committing a LeaseTree FreePermit; and
9. rejects copied leases after release and reuses slots only under newer
   generations.

For the bounded LeaseTree dispatch profile, the same adapter also binds four
exact live objects to packed weights, scales, input, and output roles. One
adapter-owned slot retains one exact request and a pointer-free,
generation-fenced `MetalAsyncDispatchTicketV1`. Submit is separate from
non-blocking poll and blocking wait; an exact submit replay returns the same
ticket without uploading or committing twice. The underlying native backend
may own commands for distinct buffer sets concurrently, so the single-flight
claim is deliberately scoped to this adapter.

The native command registry strongly retains the command buffer and the exact
four registered buffers until exact finalization. Pending completion is
nonterminal, leaves caller output unchanged, and preserves the allocation pin
and charge. Output copying requires the exact command token, submission
binding, immutable completed snapshot, and output-role token while both native
records remain live.

The Metal INT4 profile also has an adapter-authorized pre-submit rejection
path. `MetalMatvecPreSubmitAttemptV1` seals raw geometry, host
packed-weight/scales/input/output lengths, and the four semantic role bindings.
Before pin acquisition, the adapter issues a generation-fenced
`MetalMatvecDispatchRequestV1` over that attempt and the exact dispatch and
queue authorities. Its `request_sha256`, not `attempt_sha256`, is the pin's
dispatch-request root. Normal submission, rejection, and cancellation require
the same prepared request. The pre-submit attempt does not hash slice contents;
the normal submitted observation binds those content roots separately.

Core seals a `DispatchPinIntentV1` for that exact request and invokes the
adapter's reserve callback before ResourceBank mutation. Callback-visible core
state is snapshotted and revalidated. If source validation or atomic Bank pin
acquisition fails, core invokes the exact abort callback and verifies the same
boundaries; a successful pin is validated against the reserved intent before
use.

`rejectMatvecInt4BeforeSubmitObserved` revalidates the exact lease, object set,
intent-bound pin, prepared request, and adapter before applying deterministic
reason precedence: `invalid_geometry`, `invalid_host_lengths`,
`invalid_role_bindings`, then adapter-owned `invalid_role_mapping`. A valid
preflight remains eligible for normal dispatch or the exact pure
`cancelMatvecBeforeSubmitObserved` branch. That cancellation depends only on
the sealed lease, request, intent, and pin bindings; it performs no live native
inspection and constructs or submits no command buffer.

A malformed request authorizes a
`rejected_before_submit` terminal with zero submission, backend-completion,
and output roots. Rejection may inspect the selected device and live resource
roles, but it performs no upload, constructs or submits no command buffer, and
does not increase the backend's completed-command count.

Submitted, reconciled-failure, rejected, and cancelled terminals all use the
same core settlement. For an exact completed submission or exact retained
command-buffer error, the adapter retains the native submission and immutable
completion snapshot even after it authorizes terminal evidence. The
coordinator first consumes the private Bank pin, then invokes the private
settlement callback with the exact permit and completion. Under the adapter
lock, that callback finalizes the exact native `.completed` or `.error` command
record after Bank settlement, then clears prepared request, reserved intent,
bound pin, async slot, quarantine, and terminal state together and records an
exact replay tombstone. Rejection and cancellation have no native command
record to finalize. Callback failure leaves core settlement pending for exact
retry. Public
`acknowledgeDispatchCompletion` only verifies that tombstone idempotently; it
does not grant authority or clear state. A changed attempt is rejected while
settlement is pending, and a consumed pin is stale.

Ambiguous submission, unknown completion, invalid completed evidence, and an
exact terminal command error first install sticky nonterminal
`MetalAsyncDispatchQuarantineV1`. Quarantine retains the adapter slot, native
record, four buffer references, pin, and charge. Only a quarantine containing
the exact retained native command-buffer `.error` snapshot can be explicitly
reconciled: `MetalAsyncDispatchTerminalFailureV1` binds that snapshot,
submission, ticket, quarantine, object set, and pin to a core
`terminal_failure` with no output root. Authorization alone releases nothing;
the quarantine, pin, charge, buffers, and native command remain live through
Bank settlement. The private callback then exact-finalizes the same native
`.error` record before clearing private state.

Submission ambiguity, unknown completion, and invalid completion still lack
terminal authority and remain sticky. This slice does not detect physical
device loss, infer a terminal from device state, migrate work, select a fresh
device, or provide multi-slot scheduling.

The native hard gate now exercises both coordinators. The LeaseTree path uses
distinct admission/lease/recovery/terminal evidence and keeps its allocation
batch and FreePermit private. See
[LeaseTree Device Allocation](LEASE_TREE_DEVICE_ALLOCATION.md) and
[Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md).
Its coordinator holds address-stable pointers to the execution owner's shared
tree token and publication sequence. The owner must externally serialize
coordinator calls with every other mutation of those shared values; the
coordinator does not make unsynchronized owners or threads safe.

## Byte meanings

The adapter deliberately keeps logical accounting and native observation
separate:

| Field | Source | Meaning |
| --- | --- | --- |
| `requested_bytes` | execution plan | requested logical buffer length |
| `charged_bytes` | replayable adapter quote | exact direct `MTLBuffer.length`, equal to the requested length in V1 |
| `buffer_length_bytes` | live `MTLBuffer.length` | direct confirmation of the charged logical resource |
| `resource_allocated_size_bytes` | live `MTLResource.allocatedSize` | direct value reported for that resource at inspection time |
| `currentAllocatedSize` | `MTLDevice` | device-wide diagnostic context only; never used to infer object ownership |

Metal exposes `allocatedSize` only after resource creation. The adapter
therefore does not use it as a pre-allocation quote and does not infer it from
`heapBufferSizeAndAlignWithLength`, whose documented scope is heap
suballocation. A future reserve/materialize/settle ABI may charge a
conservative ceiling and then settle from a separately observed post-creation
`MTLResource.allocatedSize` value.

`MTLDevice.maxBufferLength` bounds an individual requested length. It does not
guarantee allocation success. `recommendedMaxWorkingSetSize` is accepted only
as policy context for the caller-selected total logical budget; it is not
presented as physical capacity or residency.

## Token and lifetime fencing

Raw Objective-C pointers do not cross the shim boundary, and neither pointers
nor GPU addresses enter portable evidence. Each private adapter slot retains:

- one token containing a random context nonce and a buffer generation that is
  never reused within that live context;
- the complete allocation call;
- the portable backend object;
- the direct per-object Metal observation; and
- an adapter-wide monotonically increasing backend-object generation.

The context-owned shim registry resolves that token under a lock and strongly
owns the corresponding `id<MTLBuffer>`. Copied stale tokens are rejected
deterministically within the context. Context separation uses a 256-bit random
nonce: cross-context collision is computationally negligible rather than
globally registered, and the hard gate verifies rejection across two distinct
live contexts on the tested host. Every adapter authority also includes that
native-context nonce and a monotonically issued per-context adapter instance,
so repeated caller nonces produce distinct authorities within one live
context. The public object identity is a domain-separated digest over that
authority, Metal registry identity, private slot index, generation, and
allocation-call root. The coordinator additionally binds the exact adapter
context and callback addresses and the exact `ResourceBank` instance.

Async commands use a separate private command token. Its native registry record
binds the submission digest, command buffer, completion-publication fence, four
ordered allocation records, and strong references to the same four
`MTLBuffer`s. Poll, wait, output read, and finalize require exact token and
binding replay. Output read and finalize additionally require the byte-for-byte
immutable terminal snapshot; finalize unlinks the record and drops all four
active-command references exactly once. None of these native handles enters
`MetalAsyncDispatchTicketV1`, `MetalAsyncDispatchQuarantineV1`, or
`MetalAsyncDispatchTerminalFailureV1`.

In assertion-enabled builds, backend deinitialization asserts that its
Zig-side live weight/allocation counters and the independently maintained shim
registry count are zero. Normal lease release removes the shim registry entry
and its strong reference synchronously. That proves ownership relinquishment
by the adapter; it does not prove when a driver reclaims physical pages.

## Evidence and tests

The portable allocation contract and fake-adapter failure campaign are
deterministic contract models. Zig state tests cover reservation, abort, pin,
terminal, rejected-settlement retention, exact command-error authorization,
mutation rejection, and replay boundaries; the independent Python mirror
rebuilds the fixed
failure and terminal roots and rejects substitutions. They open no
`MTLDevice`, create no `MTLBuffer`, and execute no GPU command. These tests
model an exact native `.error` projection; they do not induce or claim a
hardware or driver error.

The native allocation hard gate is different. On the executing macOS host it:

- opens the real default `MTLDevice`;
- creates three direct Shared Metal buffers for 1,000, 3,000, and 4,000 logical
  bytes;
- reads `device`, `length`, `allocatedSize`, storage mode, and cache mode from
  each live resource;
- verifies complete `0 → 8,000 → 0` device-byte lifecycles through both
  ChildLease and LeaseTree ownership;
- verifies the LeaseTree transitions from `reserved_unmaterialized` to `live`
  to `free_authorized` and finally an empty device scope;
- creates a separate exact four-buffer 37x64 INT4 allocation wave, acquires a
  ResourceBank dispatch pin, proves release is rejected while pinned, submits
  those four real registry-owned buffers through the adapter's async entry
  point, retains the exact ticket, observes completion through the separated
  wait path, authenticates the command/snapshot/output role, compares output
  with the CPU oracle, proves the native command is still retained before
  settlement, completes private Bank settlement and exact native
  finalization, verifies the compatibility acknowledgement, and then returns
  all ownership to zero. This is a successful-command regression and does not
  induce a native command-buffer error;
- uses adapter-issued, generation-fenced request roots and reserved intents for
  separate real-resource pins describing invalid geometry, host length,
  duplicate role binding, and foreign live-role mapping; proves rejection may
  inspect the real context/resources but submits no command buffer,
  `submission_sha256`, `backend_completion_sha256`, and `output_sha256` are
  zero, the completed command count is unchanged, exact settlement is
  replay-safe, and every pin returns before final release;
- takes a valid prepared request through pure `cancelled_before_submit` on the
  same real context and resources, proves no native inspection or command
  submission, then uses the same private settlement path;
- cancels a separate LeaseTree wave after two real buffer creations and proves
  that both buffers are released before the complete charge is returned;
- verifies `0 → 3 → 0` through both adapter bookkeeping and the independent
  shim-owned live-resource registry;
- repeats three buffers in a second cycle using the same private slots,
  requires newer object generations, and releases all six creations;
- rejects copied stale tokens and foreign-context inspection/release without
  changing either context's counters;
- proves duplicate caller nonces receive distinct native adapter authorities;
- rejects sealed backend, operation-profile, and feature overclaims;
- exercises four concurrent callers across 32 additional real buffer
  create/inspect/release cycles; and
- pins the portable observation hash to a fixed digest vector.

Run it with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-allocation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

The separate readiness/correctness gates compile real Metal shaders, submit
real command buffers, wait for completion, and compare GPU results with CPU
oracles:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-observation-test \
  native-metal-correctness-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

For one non-overlapping verification run, the aggregate step serializes the
native device gates as readiness → allocation → correctness:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Foreign-target profiles compile the portable public surface only. They are not
native Metal, OS, driver, or device evidence.

The allocation-aware inventory helper validates the
`matvec_int4_f32_bounded` pipeline and publishes that operation profile. The
native allocation gate now includes one correctness-only pinned dispatch for
that exact profile; it is not yet a generic allocation-only Metal profile or a
performance gate.

The next native validation slice is a build-isolated Metal fault/race harness.
It must record physical observations separately from injected overlays and
must export no fault-control symbols or test hooks in production artifacts.

## Claim boundary

This slice establishes direct Metal resource creation, per-object inspection,
adapter ownership, logical precharge, release ordering, and generation-fenced
reuse plus per-adapter single-flight async completion delivery on the host that
executes the hard gate. It separately establishes the pointer-free
authorization and pre-settlement retention contract for exact terminal command
errors through pure Zig and independent Python mirror tests; the native gate is
a successful-command regression. It
does not establish:

- physical residency or reclaim completion;
- heap allocation or fragmentation accounting;
- physical device-loss inspection or recovery, general quarantine clearing,
  fresh selection, or automatic migration;
- multi-slot queue scheduling, a global native queue-depth limit, queue-depth
  evidence, or transfer ownership;
- inferred terminal state or quarantine reconciliation after ambiguous queue
  ownership or unknown completion;
- multiple simultaneously materialized coordinator leases per adapter context;
- multi-device partitioning;
- additional GPU backends;
- a supported device/OS range; or
- latency, throughput, utilization, power, temperature, frequency, or energy.

Those claims require separate authorities and retained evidence rather than a
reinterpretation of the V1 logical resource charge.
