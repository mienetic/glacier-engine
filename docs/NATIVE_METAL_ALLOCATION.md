# Native Metal Allocation Adapter

The native Metal allocation adapter binds the portable allocation-adapter
contract to real direct Shared `MTLBuffer` resources on macOS through both the
receipt-bound ChildLease coordinator and the execution-owned LeaseTree
coordinator. It is a bounded allocation-ownership prototype, not a residency
or performance subsystem. Its optional dispatch path adds per-adapter
**bounded two-slot Metal async completion delivery**; it is neither a global
native queue-depth limit, physical-parallel execution claim, nor a general
queue scheduler.

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
   generations; and
10. routes two independently fenced async dispatch lanes with exact replay,
    capacity rejection, and out-of-order settlement.

## Device lifecycle observation

Every `MetalBackend` context now installs
`MTLCopyAllDevicesWithObserver` and validates that the selected device's
`registryID` appears in the initial device array. The callback captures a
separate ARC-owned lifecycle state rather than the malloc-owned context, and
teardown removes the observer before releasing the context.

The fixed native snapshot keeps initial membership and source-specific
`added`, `removal_requested`, `removed`, and `command_buffer_removed` events.
A sticky source bitset derives a monotone effective state, so later weaker
notifications cannot downgrade loss. Generic API failures do not become
device-loss facts; an unmodified native command completion publishes
`command_buffer_removed` only for exact status `5`, Metal command-buffer error
domain `1`, and error code `11`, before any test-only completion overlay.
A native admission lease linearizes entry against that publication: work
admitted first may settle, while new allocation and dispatch admitted after
loss fail closed. Live `MTLDevice` property reads used by `deviceInfo` and
`allocationLimits` acquire the same native lease, closing the precheck/use
race. Loss reporting uses retained initial device identity rather than querying
a dead device.

The portable [Device Lifecycle Observation V1](DEVICE_LIFECYCLE.md) contract
uses a 40-byte source cursor, 280-byte observation, and 272-byte transition
receipt. It binds a native source instance and increasing source sequence to
the prior present inventory entry and recomputed inventory root; gaps are valid
and the caller must durably and atomically commit the advanced cursor. The
source-instance digest binds a 256-bit per-context nonce,
observer-generation reset discriminator, registry ID, and stable
device/placement identities, rather than relying on the 64-bit generation
alone. The adapter claims each exact native snapshot at most once. Source
mismatch fails closed; fresh adoption requires a new inventory and exact initial
sequence 1 and grants no recovery or migration authority. Inventory absence or
removal-requested becomes `unavailable`; removed or exact code `11` becomes
`lost`. Existing selection excludes either state. Contract hashes verify
composition and integrity, not authenticity or attestation. Synthetic injected
evidence has an explicit synthetic class and is not native failure evidence.

The actual built-in M1 development-host correctness gate retained the same
initial-membership snapshot while one real Metal command succeeded. The native
allocation gate races two threads to consume that exact initial snapshot and
requires one consumed and one stale result while the snapshot remains readable.
That proves observer installation, real GPU execution, and at-most-once
consumption on the no-event path for that host session. It did not exercise a
physical removal-requested or removed callback; transition and error-path
coverage is deterministic synthetic/model evidence.

## Loss-bound retirement

Device-loss Retirement V1 composes the accepted lifecycle transition with one
exact selected LeaseTree allocation. Its portable 544-byte plan binds the
selection, allocation authority, lease, leaf/object sets, recovery generation,
and adapter-local challenge. The challenge is a digest binding, not native free
authority.

The production adapter arms its private permit only after full plan replay,
an exact match against the native snapshot previously consumed for that
observation, and a read-only revalidation of the same currently sticky native
loss source. A caller-resealed sequence, native tuple, or evidence root rejects.
It accepts native removed notification or exact native command-buffer removal;
synthetic loss cannot enter this path. Arming fails while any prepared,
reserved, pinned, submitted, terminal-validation, native-command, or quarantine
state remains.

Once armed, the normal LeaseTree coordinator owns the release transaction. Its
private `FreePermit` remains the sole logical-accounting authority. For each
exact live slot, the loss path revalidates the private permit and token, checks
the retained lifecycle state, and drops the registry's strong `MTLBuffer`
reference without querying a live `MTLBuffer` or `MTLDevice` property. Partial
free failure retains the remaining objects and coordinator recovery state.
Only after all references are dropped does Bank settlement return the logical
bytes.

The resulting 440-byte receipt binds the ordinary
`released` / `normal_release` terminal, exact logical bytes, reference count,
and adapter settlement. It explicitly carries zero physical-reclaim,
output-publication, migration, and reset authority. Exact completion replay
returns a private tombstone; foreign replay rejects.

The build-isolated test path is intentionally different. It creates real Metal
buffers but arms an explicitly synthetic, test-only loss permit, then exercises
the same LeaseTree free and strong-reference release lifecycle. This proves
native ownership cleanup on the executing host. It does not reproduce a
hardware removal callback or prove physical reclamation. See
[Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md).

## Dispatch pin and async completion

For the bounded LeaseTree dispatch profile, the same adapter binds four exact
live objects to packed weights, scales, input, and output roles for each
command. Two fixed adapter-local lanes may retain independent requests and
pointer-free, generation-fenced `MetalAsyncDispatchTicketV1` values. The
ticket's `queue_slot` is part of its integrity root and routes poll, wait,
quarantine, terminal validation, settlement, loss reconciliation, and replay
to the exact lane. Submit is separate from non-blocking poll and blocking wait;
an exact replay returns the same ticket without uploading or committing twice.
A distinct request selects the lowest free canonical lane, while a third
distinct request rejects before native upload or commit when both are
occupied. This bounded capacity does not assert that the device executes two
commands physically in parallel.

The native command registry strongly retains the command buffer and the exact
four registered buffers until exact finalization. Pending completion is
nonterminal, leaves caller output unchanged, and preserves the allocation pin
and charge. Output copying requires the exact command token, submission
binding, immutable completed snapshot, and output-role token. One lane can
complete and settle before its sibling without clearing or mutating the
sibling's request, pin, command, quarantine, terminal, or tombstone state.

`ResourceBank.snapshotV4()` is the additive pin-aware observation boundary. It
reports fixed pin-slot capacity and metadata bytes, current and peak active
slots, acquisitions, completions, queue-capacity and physical-slot rejections,
and reserved completion headroom. Snapshots V1–V3 retain their prior layouts
and meanings. Every accepted pin reserves one future LeaseTree generation and
one structural revision on its exact root. Other mutations cannot consume that
tail, so out-of-order releases remain monotonic even near counter exhaustion.

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

### Device-loss dispatch reconciliation Phase A

The generic terminal-error sidecar does not by itself classify device loss.
Phase A adds the exact lifecycle and ownership composition for native Metal
command-buffer status/domain/code `5/1/11`:

- a 440-byte pointer-free `LossDispatchRetentionV1` binds the selected
  capability, live lease, allocation leaf/object sets, active pin, request,
  submission, quarantine, and adapter challenge;
- a 240-byte `LossDispatchReconciliationPlanV1` replays deterministic
  selection and the exact `present → lost` transition; and
- a 448-byte `LossDispatchReconciliationReceiptV1` binds terminal failure,
  dispatch completion, Bank completion, exact native finalization, and the
  adapter settlement root without granting output, migration, reset, or
  physical-reclaim authority.

Production authorization accepts only native
`command_buffer_device_removed` evidence carrying exact `5/1/11` and matching
the retained sticky backend loss. Synthetic evidence is structurally valid for
tests but production-ineligible. The Coordinator validates and presents the
exact live lease, `.pinned` slot, intent, object set, calls, and already-bound
adapter through its active-reconciliation callback; the private Bank permit
never crosses that boundary.

Authorization changes no ownership. The adapter retains quarantine, pin,
charge, buffers, and command until core consumes the Bank pin and its private
settlement callback exact-finalizes the same native record. The adapter then
retains the Phase A receipt and a replay tombstone. If outer confirmation is
lost, exact `settlement_pending` retry confirms the same completion without a
second Bank release or native finalization. Allocation retirement is separate
and can start only after the dispatch slot is gone.
Native finalization names the exact registered command token and does not
require unrelated sibling command counts to reach zero. Public receipt
retrieval likewise requires the exact plan, retention, and successful
Coordinator completion retained in the tombstone. See
[Device-loss Dispatch Reconciliation](DEVICE_LOSS_DISPATCH_RECONCILIATION.md).

Submission ambiguity, unknown completion, invalid completion, and pending work
still cannot use Phase A terminal authority. The separate callback-safe Phase B
protocol below retires only their ownership and does not infer success, output,
or terminal command failure. Source-bound lifecycle observation by itself does
not infer a dispatch terminal.

### Device-loss dispatch callback retirement Phase B

Phase B binds exact pending, submission-ambiguous, completion-unknown, and
invalid-completion ownership in a 464-byte retention, a 240-byte loss plan, a
408-byte callback fence, and a 504-byte settlement receipt. Production accepts
only exact native `removed_notification` or
`command_buffer_device_removed` evidence with same-source sticky backend
revalidation.

The Objective-C completion handler captures an ARC-owned callback gate instead
of depending on the malloc-owned native Metal context. Native prepare freezes
the current command facts and clears the gate's context owner while the command
record and all four command-held buffer references stay registered. This
detachment does not wait for callback exit; an already-running handler observes
the detached gate and cannot return to the context.

The adapter then authorizes only core
`ownership_retired_after_device_loss` with the original submission, a fenced
backend-terminal root, and zero output. Core consumes its private Bank pin
before the settlement callback commits the exact native unlink. Commit removes
one command record, drops its four command-held references, and stores replay
tombstones so duplicate receipt retrieval cannot unlink or consume twice.
Allocation ownership and its logical charge stay live until a separate
allocation release. See
[Device-loss Dispatch Callback Retirement](DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md).

The production shim provides a separate read-only
`MetalDispatchRetirementTelemetryV1` ABI. Its fixed 256-byte snapshot binds the
native registry ID and context nonce to successful fresh/replayed
prepare/commit counts, live prepared ownership, callback detachment, frozen
completion/state/disposition/authorization buckets, retired command and
four-reference totals, retained tombstones, generations, and sticky
per-counter saturation. It is read under the existing device registry monitor
without acquiring the callback gate. No snapshot field is consumed as
retirement, completion, output, Bank, allocation-release, migration, reset,
residency, or reclaim authority.

The native hard gate now exercises both coordinators. The LeaseTree path uses
distinct admission/lease/recovery/terminal evidence and keeps its allocation
batch and FreePermit private. See
[LeaseTree Device Allocation](LEASE_TREE_DEVICE_ALLOCATION.md) and
[Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md).
Its coordinator holds address-stable pointers to the execution owner's shared
tree token and publication sequence. The owner must externally serialize
coordinator calls with every other mutation of those shared values; the
coordinator does not make unsynchronized owners or threads safe.

## Build-isolated fault and settlement gate

The native fault/race gate links a second, non-installed build of the
Objective-C shim with `GLACIER_METAL_TEST_FAULTS=1`. The production shim is
checked to export no `glacier_metal_test_*` symbols; only the test artifact
exposes the bounded plan/facts ABI. Fault plans are context-local and one-shot,
with no environment-variable or process-global control. Two host threads race
to arm one context, and synchronization at the native device admits exactly one
winner while the loser receives `PlanAlreadyArmed`.

The same isolated artifact contains a bounded two-slot pressure proof that is
separate from loss classification. One adapter materializes an eight-object
lease containing two disjoint four-buffer INT4 role sets, then prepares, pins,
and submits both commands. The native registry reaches two live command records
before either is settled; replaying A or B does not create a third record, and
a third distinct request is rejected before native mutation. After both native
commands complete and match their CPU oracles, the gate consumes B's Bank pin
and finalizes B while A's completed record and pin remain live, then settles A.
SnapshotV4 records the exact `0 → 2 → 1 → 0` pin lifecycle, and the final gate
requires zero live commands, pins, and buffers. The result proves bounded
coexistence and out-of-order settlement isolation, not physical GPU parallel
execution, command-completion order, throughput, or a production queue-depth
measurement.

The admitted plan does not make Metal fail physically. It submits one real
four-buffer command, waits for the native command buffer to complete
successfully, and retains the physical `.completed` snapshot, GPU start/end
timestamps, and device allocation observation. Only after validating that exact
physical success does the test-only completion handler publish a separate
`.error` snapshot with a nonzero internal command-buffer error. The native
registry retains both fact planes, and exact finalization compares against the
published snapshot used by the adapter. Host output remains unpublished and
unchanged.

The adapter observes the published error, installs quarantine, and exercises
the structurally valid synthetic Phase A authorization for the matching
terminal failure. This does not satisfy or bypass the native-only production
gate. At the first settlement-callback entry, the gate proves the Bank pin is
already consumed while the native command record is still live. The callback
then exact-finalizes that record, stores the Phase A receipt and tombstone, and
clears the async slot, quarantine, request, pin, and terminal state. A test
proxy deliberately rejects the first confirmation after successful native
finalization, so the coordinator retains `settlement_pending`. Repeating
`completeDispatchPin` replays the same private completion and tombstone, clears
the coordinator slot, and performs neither a second Bank release nor a second
native finalization.

The same isolated build has a separate Phase B four-state matrix. Every case
submits a real Metal command over four real buffers. A test-only hold stops the
pending completion handler before it enters the ARC-owned callback gate.
Context-local one-shot seams separately preserve a post-commit ambiguous
disposition authenticated by the native record; after independently verified
physical success, publish a valid unknown projection by changing only
`callback_fault`; or reject one exact completed output read before caller
memory is written, which the adapter retains as completion validation code `6`.
The adapter derives `submission_ambiguous`, `completion_unknown`, and
`invalid_completion` from those live paths. Synthetic injected loss authorizes
native prepare for each state. The matrix proves callback detachment,
Bank-first settlement while the command record is live, exact native unlink,
zero caller-output mutation, replay, and safe held-handler release afterward.
Allocation-owned references and logical charge remain live until the separate
allocation release.

This gate is native conformance evidence for production-symbol isolation,
host-thread arm racing, real GPU commands/resources, and the exact
reconciliation/settlement lifecycle plus all four Phase B retained states. The
published error, retained-state seams, and injected loss are test-only. They
are not evidence of a physical driver, hardware, or device-loss fault,
device-loss recovery, successful-output recovery, residency, migration, reset,
physical reclaim, or performance.

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

For Phase B, each registered command also owns an ARC callback gate. Prepare
authenticates the exact token and binding, detaches the gate's context owner,
and retains the command record. The post-Bank commit authenticates the frozen
permit before unlinking that record and storing a native replay tombstone.
Callback exit is intentionally outside the retirement prerequisite.

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
rebuilds the fixed failure and terminal roots and rejects substitutions. The
separate Phase A Zig/Python pair independently rebuilds the 440/240/448-byte
retention, plan, and receipt roots, replays lifecycle/selection/lease/pin and
terminal/completion bindings, and rejects synthetic production authorization.
The Phase B Zig/Python pair independently rebuilds the 464/240/408/504-byte
retention, plan, fence, and receipt roots for all four retained ownership
states, verifies zero output authority and callback-detached/record-retained
shape, and rejects mutation, substitution, duplicate, foreign, and late
settlement. They open no
`MTLDevice`, create no `MTLBuffer`, and execute no GPU command. These tests
model canonical native fact projections; they do not induce or claim a
hardware or driver error.

Run the Phase A and Phase B portable contracts and independent oracles with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_dispatch_reconciliation.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_loss_dispatch_reconciliation

tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_dispatch_callback_retirement.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_loss_dispatch_callback_retirement
```

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

Run the build-isolated fault/race and settlement gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-fault-test \
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
native device gates as readiness → allocation ownership → fault/reconciliation
→ focused correctness:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Foreign-target profiles compile the portable public surface only. They are not
native Metal, OS, driver, or device evidence.

The allocation-aware inventory helper validates the
`matvec_int4_f32_bounded` pipeline and publishes that operation profile. The
native allocation gates include the ordinary correctness-only pinned dispatch
and the isolated two-slot out-of-order pressure proof for that exact profile;
they are not yet a generic allocation-only Metal profile or a performance
gate.

## Claim boundary

This slice establishes direct Metal resource creation, per-object inspection,
adapter ownership, logical precharge, release ordering, and generation-fenced
reuse plus per-adapter bounded two-slot async completion delivery on the host
that executes the hard gates. The native pressure proof retains two real
commands over disjoint buffers, settles them out of order, rejects a third
request without native mutation, and closes every command, pin, and buffer. It
establishes bounded slot isolation, not physical parallel execution or
performance. The slice also establishes pointer-free authorization and
pre-settlement retention for exact terminal command errors through pure Zig
and independent Python mirror tests. The build-isolated native gate exercises
that reconciliation path after a real command physically completes
successfully, using a separately recorded test-only publication overlay and
exact coordinator retry. Phase A additionally binds only the exact native
`5/1/11` lifecycle transition to the retained active pin through fixed
pointer-free retention, plan, and receipt evidence, a native-only production
gate, Bank-first finalization, and separate later allocation retirement.
Phase B additionally binds the four retained nonterminal ownership states to
callback detachment, a dedicated zero-output ownership terminal, Bank-first
exact native unlink, and replay through fixed 464/240/408/504-byte evidence.
Its isolated native matrix runs real commands/resources for all four states
under build-isolated one-shot state seams and synthetic loss; it does not
reproduce a physical device failure or prove successful-output recovery,
residency, migration, reset, physical reclaim, or performance.
Separately, the lifecycle slice
establishes real observer installation, initial selected-device membership,
source-specific sticky removal facts, exact code `11` classification, and
fail-closed new work. Its M1 evidence is the unchanged no-event path around a
successful command. Loss-bound retirement additionally releases real buffer
references and settles logical ownership in the isolated build under an
explicitly synthetic test-only loss permit. It does not establish:

- physical residency or reclaim completion;
- heap allocation or fragmentation accounting;
- a physical command-buffer, driver, hardware, or device-loss failure from the
  test-published error;
- a physical removal-callback campaign;
- an additional-backend Phase B implementation;
- fresh selection or automatic migration;
- dynamic or unbounded queue scheduling beyond two slots, a global native
  queue-depth limit, physical queue-depth evidence, or transfer ownership;
- inferred terminal state or quarantine reconciliation after ambiguous queue
  ownership or unknown completion;
- multiple simultaneously materialized coordinator leases per adapter context;
- multi-device partitioning;
- additional GPU backends;
- a supported device/OS range; or
- latency, throughput, utilization, power, temperature, frequency, or energy.

Those claims require separate authorities and retained evidence rather than a
reinterpretation of the V1 logical resource charge.
