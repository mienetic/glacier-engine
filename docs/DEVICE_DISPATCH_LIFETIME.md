# Device Dispatch Lifetime

The device-dispatch lifetime contract prevents a live accelerator command from
outliving the allocation objects it references. It composes the
execution-owned `LeaseTree` allocation lease with a bounded ResourceBank pin
registry and an exact backend terminal-completion authority.

This is a lifetime and evidence contract. It is not a claim about physical
residency, queue utilization, throughput, latency, power, or device-loss
recovery.

## Why allocation ownership is not enough

A materialized allocation lease proves that the complete ordered backend
object set exists and remains charged. It does not prove whether a queue has
started, completed, cancelled, or lost a command that references those
objects.

Releasing the allocation immediately after submission would therefore create a
use-after-free window. Waiting in application code without a Bank-visible
fence would make reclamation depend on convention rather than authority.

The dispatch contract closes that gap with two explicit phases:

```text
live allocation lease
        │
        │ seal intent; reserve exact adapter request
        │ before Bank mutation
        ▼
DispatchPinIntentV1
        │
        │ atomically acquire exact object-set pin
        ▼
LeaseTreeDispatchPinV1
        ├── reject / cancel before submit ── exact no-submit terminal ──┐
        │                                                              │
        └── submit once ── MetalAsyncDispatchTicketV1                  │
                                ├── pending ── retain pin and charge    │
                                ├── ambiguity / unknown ── sticky       │
                                │                         quarantine    │
                                ├── exact .error ── quarantine          │
                                │       └── exact 5/1/11 Phase A ──────┤
                                │                   terminal_failure   │
                                └── exact .completed ── succeeded ─────┤
                                                                       ▼
                                                       validate terminal state
                                                                       │
                                                       consume private Bank pin
                                                                       │
                                                       private settlement callback
                                                                       │
                                           exact native terminal finalization
                                                                       │
                                                       clear state / replay tombstone
                                                                       │
                                                       LeaseTreeDispatchCompletionV1
                                                                       │
                                                       allocation release may begin
```

## ResourceBank pin registry

`Bank.initWithLeaseTreePinStorage` opts one Bank into caller-owned,
fixed-capacity pin storage. Existing Bank, Receipt, LeaseTree, node, and
Snapshot layouts remain unchanged. A deployment chooses the maximum number of
simultaneously live pins by sizing `LeasePinSlotV1` storage.

Because Snapshot V3 predates this optional registry, its metadata-byte total
and counters intentionally exclude pin-slot capacity and active-pin telemetry.
Deployments must account for the caller-owned pin array separately. An
additive snapshot version can expose that capacity and activity without
silently changing the established V3 meaning.

One active slot retains:

- the exact parent Receipt and LeaseTree identity;
- publication request, session, and sequence binding;
- a generation-fenced owner identity;
- one exact scope;
- the complete ordered allocation-leaf membership;
- the aggregate pinned claim; and
- private permit and completion generations.

The Bank reconciles the registry against every live node pin counter on each
tree validation. Duplicate members, a reordered or corrupted member set,
orphan counters, nonzero trailing members, stale generations, claim drift, and
slot-reuse replay fail closed.

The immutable parent Receipt bounds simultaneous pins through
`queue_slots`. Registry capacity and queue capacity are separate limits: a
deployment may provision more storage than one Receipt is allowed to consume,
but it cannot exceed that Receipt's admitted queue use.

An active pin blocks:

- retirement of any member allocation;
- publication transitions for the parent Receipt;
- conflicting pending LeaseTree operations; and
- session closure through the existing live-tree ownership rules.

Pins do not add a second device-byte charge. They retain the lifetime of the
already charged allocation set.

## Coordinator phases

Callers that need dispatch pinning initialize
`device_allocation_lease_tree.CoordinatorV1` with
`initWithDispatchStorage`. Dispatch slots are fixed, caller-owned, and bounded
by both `maximum_dispatches` and the parent Receipt's `queue_slots`.

### Acquire

`acquireDispatchPin` accepts:

- the exact current `LeaseTreeDeviceAllocationLeaseV1`;
- one exact `DispatchAdapterV1`; and
- a nonzero dispatch-request root.

Before mutation it revalidates the complete cached allocation evidence,
ordered live object set, exact leaves, current tree, scope sum, and publication
session. It then seals `DispatchPinIntentV1` over the lease, generation,
authorities, request, scope, object set, and publication binding and sends that
intent to the adapter's pre-Bank reserve callback. The coordinator snapshots
and revalidates its callback-visible source boundaries. A callback failure
cannot retain partial adapter state; source drift or an atomic Bank acquisition
failure invokes the exact abort callback and revalidates the same boundaries.

Only after a successful reservation does ResourceBank atomically pin the entire
leaf set. The coordinator retains the mutation-capable `LeasePinPermitV1`
privately, validates the acquired pin against the sealed intent, and returns
only pointer-free `LeaseTreeDispatchPinV1` evidence.

For the bounded Metal INT4 profile, the dispatch-request root is not an
unstructured caller label. `MetalMatvecPreSubmitAttemptV1` canonically hashes
the raw group/input/output geometry, host packed-weight/scales/input/output
lengths, and all four semantic role-binding digests. Before pin acquisition the
adapter issues a generation-fenced `MetalMatvecDispatchRequestV1` that binds
the attempt plus dispatch and queue authorities. Its `request_sha256`, not the
raw attempt root, is the pin's dispatch-request root. Submission, rejection,
and cancellation all require that exact prepared request, reserved intent, and
pin binding. Slice contents remain outside the attempt root; the submitted
observation binds its input-content roots separately.

### Metal pre-submit outcomes

`rejectMatvecInt4BeforeSubmitObserved` handles only failures that the Metal
adapter can prove occurred before a native command was submitted. It first
revalidates the exact lease, intent-bound pin, prepared request, complete live
object set, and adapter authority. It then applies deterministic reason
precedence:

1. `invalid_geometry`;
2. `invalid_host_lengths`;
3. `invalid_role_bindings`; or
4. `invalid_role_mapping`, which additionally compares the canonical roles
   with the adapter's exact live allocation slots.

A valid attempt returns `DispatchPreflightPassed` and leaves the pin available
for either normal submission or the exact pure
`cancelMatvecBeforeSubmitObserved` path. Cancellation depends only on sealed
lease, request, intent, and pin bindings. It performs no native device or
resource inspection, constructs no command buffer, and establishes no native
queue ownership.

A proven malformed attempt produces
`MetalMatvecPreSubmitRejectionV1` plus a `rejected_before_submit` terminal whose
submission, backend-completion, and output roots are all zero. No upload,
command-buffer construction, submission, or completed-command-count increment
occurs. Classification may inspect the selected native device and live resource
roles, but that inspection is not GPU command execution.

Both pre-submit outcomes use the ordinary core settlement path with zero
submission, backend-completion, and output roots. Allocation, free, and new
dispatch remain blocked until private settlement succeeds. Repeating the
identical rejection or cancellation before completion returns the identical
terminal evidence. A consumed pin cannot authorize another terminal.

### Single-flight Metal async completion delivery

The bounded Metal INT4 adapter now implements **single-flight Metal async
completion delivery**. Single-flight is an adapter contract: one adapter-owned
queue slot can retain one live request and ticket. The lower native backend may
own commands for distinct buffer sets concurrently, so this is not a global
Metal queue-depth limit.

`submitMatvecInt4AsyncObserved` submits without waiting and returns
`MetalAsyncDispatchTicketV1`. The pointer-free ticket contains no native handle;
it seals queue slot zero, a monotonic ticket generation, the prepared request,
dispatch pin, authorities, and submission root. An exact replay returns the
same ticket without uploading or committing a second command. A different
request fails before native mutation while the slot is occupied.

The native registry retains the command buffer and strong references to the
exact packed-weight, scale, input, and output buffers. Its private command token
and submission binding remain outside portable evidence. Non-blocking poll and
blocking wait authenticate that exact native record. An output read additionally
requires the same command token, submission binding, immutable `Completed`
snapshot, and registered output role before copying bytes.

`pending` is level-triggered and explicitly nonterminal. It leaves caller
output unchanged and grants neither Bank release nor native-finalization
authority, so the allocation pin and its existing charge remain live. An exact
completed snapshot can authorize a `succeeded` terminal and can be replayed
before settlement, but the native record and all four buffer references still
remain retained.

Ambiguous submission, unknown completion, invalid completed evidence, and an
exact terminal command error first produce sticky
`MetalAsyncDispatchQuarantineV1`. This pointer-free value is bound to the
ticket, selected device and placement, native disposition/status, and bounded
error classification. Quarantine itself is diagnostic nonterminal evidence:
it never becomes `DispatchTerminalEvidenceV1`, never clears the adapter slot,
and never releases the pin, charge, native command, or buffers.

The exact command-buffer-error case has one narrower authority.
`reconcileTerminalCommandFailureObserved` takes the original live lease, pin,
and ticket, then authorizes only if the retained quarantine, submission, and
immutable native `.error` snapshot still match. It returns
`MetalAsyncDispatchTerminalFailureV1` and a matching core `terminal_failure`;
the sidecar binds the exact native error projection and backend-completion root
while the core terminal has no output root. This authorization does not clear
quarantine or release ownership. Ambiguous submission, unknown completion, and
invalid completion cannot use this path and remain sticky until the separate
loss-authorized Phase B callback-retirement protocol succeeds.

### Device-loss dispatch reconciliation Phase A

Phase A composes the command-error terminal machinery with one exact
source-bound device-loss transition. It is intentionally limited to native
Metal command-buffer status `5`, command-buffer error domain `1`, and
device-removed code `11`; a device-loss observation by itself is not terminal
authority.

The portable contract adds three pointer-free values:

- `LossDispatchRetentionV1` is 440 bytes and binds the selected capability,
  live allocation lease, leaf/object sets, active dispatch pin, request,
  submission, quarantine, exact `5/1/11` projection, and adapter challenge.
- `LossDispatchReconciliationPlanV1` is 240 bytes and binds that retention to
  the exact `present → lost` lifecycle transition, source sequence, and
  reconciliation generation after replaying deterministic selection.
- `LossDispatchReconciliationReceiptV1` is 448 bytes and composes the exact
  terminal failure, dispatch completion, Bank completion, adapter settlement,
  and one finalized native command. Its output, migration, reset, and
  physical-reclaim authority roots must remain zero.

The production gate accepts only native
`command_buffer_device_removed` evidence with the exact `5/1/11` fields and
the same retained backend loss. `test_injected` remains valid for structural
tests but cannot pass production authorization. The Coordinator's
`withActiveDispatchReconciliationBindingV1` path validates the exact active
lease, `.pinned` slot, intent, object set, calls, adapter identity, and live
Bank pin before invoking the already-bound adapter. It never exposes the
private Bank permit.

Authorization retains the quarantine, pin, logical charge, buffers, and native
command. Ordinary `completeDispatchPin` then consumes the Bank pin before its
private callback exact-finalizes that same command and records the adapter
settlement receipt and replay tombstone. A lost outer acknowledgement leaves
the Coordinator in `settlement_pending`; exact retry reuses the completion and
tombstone without another Bank release or native finalization.
Finalization targets the exact registered command token rather than requiring a
global native-command count of zero, so unrelated sibling commands remain
owned. Public receipt retrieval must replay the exact plan, retention, and
successful Coordinator completion stored in the tombstone.

Dispatch settlement does not release the allocation lease. Only after the
dispatch slot is gone may the separate
[Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md) flow drop
allocation-owned native references and return logical device bytes. Pending,
ambiguous, unknown, and invalid command states cannot be inferred terminal in
Phase A. See
[Device-loss Dispatch Reconciliation](DEVICE_LOSS_DISPATCH_RECONCILIATION.md).

### Device-loss dispatch callback retirement Phase B

Phase B provides the separate callback-safe ownership terminal for the exact
`pending`, `submission_ambiguous`, `completion_unknown`, and
`invalid_completion` states. Its portable evidence consists of:

- a 464-byte `LossDispatchCallbackRetentionV1` binding the live lease, pin,
  request, ticket, submission, state-specific quarantine shape, and adapter
  challenge;
- a 240-byte `LossDispatchCallbackRetirementPlanV1` binding that retention to
  one exact accepted `present → lost` transition;
- a 408-byte `LossDispatchCallbackFenceV1` proving the ARC-owned callback
  target is detached while the native command record remains retained; and
- a 504-byte `LossDispatchCallbackRetirementReceiptV1` composing the dedicated
  ownership-retired terminal, dispatch and Bank completions, exact native
  unlink, and adapter replay tombstone.

Native prepare detaches the callback gate without waiting for a callback that
is already running to exit. The handler can no longer reacquire the native
Metal context, while the command record and four command-held references
remain live for private settlement. The terminal outcome is
`ownership_retired_after_device_loss`, carries the original nonzero submission
and a fenced backend-terminal root, and has zero output. It is not relabelled
success, terminal failure, or cancellation.

Production arming accepts only exact native `removed_notification` or
`command_buffer_device_removed` loss and revalidates that same sticky source at
the backend. A removal request is insufficient. Core consumes the private Bank
pin before the post-Bank adapter callback commits the exact native unlink.
Exact replay returns the stored tombstone without a second Bank consumption or
native unlink.

The production native boundary also exposes a read-only 256-byte
`MetalDispatchRetirementTelemetryV1` snapshot. Registry ID plus context nonce
bind successful unique/replayed prepare and commit transitions to their
source. Direct buckets freeze completion observation, native command state,
submission disposition, and native-loss versus synthetic-test authorization
at unique prepare; live-prepared, callback-detached, retired-record,
four-reference-release, tombstone, and generation counters expose the
successful ownership lifecycle. Rejected operations do not increment it,
reads do not change it, and independently saturating counters retain a sticky
overflow mask. The snapshot takes only the native registry monitor and is
diagnostic: it never grants callback-exit, completion, output, Bank, release,
selection, migration, reset, residency, or reclaim authority.

Allocation ownership remains separate: Phase B clears the dispatch slot and
command-held references, not the allocation lease, allocation-owned native
references, logical device-byte charge, physical pages, or residency. See
[Device-loss Dispatch Callback Retirement](DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md).

### Complete

`completeDispatchPin` accepts the original pin, the exact adapter instance, and
`DispatchTerminalEvidenceV1`. It verifies:

- dispatch and queue authority roots;
- dispatch generation, request, pin, and terminal roots;
- the exact adapter context and callback function identity;
- the still-live private Bank permit;
- the unchanged allocation object set and publication binding; and
- backend-specific terminal state through the bound adapter callback.

Only after those checks does ResourceBank consume the private permit. Core then
constructs `LeaseTreeDispatchCompletionV1` and invokes the adapter's private
settlement callback with the exact pin, terminal, completion, Bank permit, and
Bank completion. For submitted Metal work, the callback validates the retained
ticket and exact immutable `.completed` or `.error` snapshot, finalizes that
exact native record only after Bank settlement, then clears the prepared
request, intent, pin, terminal, async slot, quarantine, and unresolved state
and records an exact replay tombstone while holding the adapter lock. A
reconciled error therefore retains the quarantine, pin, charge, command, and
four buffers until the Bank settlement is committed and the same native
`.error` record is finalized. No-submit terminals have no native record to
finalize. Core frees its dispatch slot only after the callback succeeds.

If the private callback fails after Bank release, the coordinator retains a
`settlement_pending` slot and retries the exact confirmation; it does not
reacquire or consume the Bank pin again. The public Metal
`acknowledgeDispatchCompletion` method is compatibility verification only: it
checks the tombstone idempotently and grants no authority or state-clearing
transition.

Copied completion attempts and a permit copied across slot reuse are rejected.
Overlapping pins may complete in any order without regressing the current tree
generation.

The adapter callback context and functions must remain alive for every pin
acquired through that adapter. Callbacks must not re-enter the coordinator.
Intent reservation, abort, terminal validation, and settlement confirmation
are exact and idempotent for their respective inputs. The execution owner must
also serialize the shared tree token and publication sequence exactly as
required by the allocation coordinator.

### Build-isolated native fault/race verification

The native Metal fault gate is a separate test artifact, not production
dispatch authority. Its shim is built with
`GLACIER_METAL_TEST_FAULTS=1`; an isolation check requires the production shim
to export no `glacier_metal_test_*` symbols. Plans are one-shot and local to one
native context. When two host threads race to arm the same context, native
synchronization admits exactly one winner.

The winning plan first allows one real Metal command to complete physically as
`.completed`. Its completion handler retains that physical snapshot and, only
after validating physical success, creates a separate test-published `.error`
snapshot. The adapter consumes only the published fact, so it follows the real
quarantine and terminal-failure reconciliation path while the test can still
prove that the device command itself succeeded.

The same gate observes the first settlement-callback boundary dynamically:
the Bank pin is already consumed, yet the native command record remains live.
After exact native finalization and private state clearing, a test proxy rejects
the first confirmation. Core therefore retains `settlement_pending`; an exact
retry replays the same completion/tombstone, clears the coordinator slot, and
does not release the Bank pin or finalize the native record again.

These are native host-thread, GPU-execution, and coordinator-settlement facts,
but the published error is a test-only overlay. The gate is not a physical
driver, hardware, or device-loss fault, device-loss recovery, or performance
test.

### Device lifecycle observation boundary

Device-loss Observation V1 is now a separate evidence layer. Each native Metal
context installs `MTLCopyAllDevicesWithObserver`, validates initial membership
for the selected registry ID, and retains removal-requested and removed as
distinct bits in a sticky source set whose effective state cannot downgrade.
Exact native command-buffer status `5`, Metal command-buffer error domain `1`,
and error code `11` publishes the separate command-buffer-removed bit before
any test-only overlay. A native admission lease linearizes new work and live
`MTLDevice` property reads used by `deviceInfo` and `allocationLimits` against
loss: already-admitted operations may settle, while admission after loss fails
closed. Loss observation uses retained initial identity rather than querying a
dead device.

The 40-byte source cursor, 280-byte observation, and 272-byte transition
receipt bind a native source instance and increasing source sequence to a prior
present inventory entry and recomputed inventory root. Its digest binds a
256-bit per-context nonce, observer-generation reset discriminator, registry
ID, and stable device/placement identities instead of relying on the 64-bit
generation alone. Gaps are valid, callers must durably and atomically commit
the advanced cursor, and the adapter claims each exact native snapshot at most
once. Source mismatch fails closed; fresh adoption requires a new inventory
and exact initial sequence 1. Normal
selection excludes the resulting newer `unavailable` or `lost` successor.
Hashes verify composition and integrity, not authenticity or attestation. The
observation alone does not terminalize an in-flight dispatch, release its pin
or charge, clear quarantine, create a fresh selection, or migrate work.
Command-specific Phase A reconciliation must separately replay the exact
lifecycle, selection, lease, pin, quarantine, terminal, and completion
bindings. See
[Device Lifecycle Observation V1](DEVICE_LIFECYCLE.md).

The separate [Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md) path now
handles only an allocation that is already quiesced. It binds the exact
accepted loss to the selected allocation lease, refuses every retained
dispatch/command/quarantine state, and uses the ordinary coordinator release
so native references drop before Bank uncharge. It does not invent a terminal
for an in-flight dispatch and therefore does not weaken the pin rules in this
document. Phase A must remove the exact dispatch slot first; retirement then
uses its separate allocation authority.

The actual built-in M1 development-host gate proved initial membership and an
unchanged no-event lifecycle snapshot around one real successful Metal
command. A native two-thread race requires one exact initial-snapshot
consumption and one stale result while the snapshot remains readable. It did
not exercise a physical removal callback. Synthetic lifecycle transition/error
tests and the build-isolated published-error overlay are not physical failures.

## Terminal outcomes

The public terminal enum contains only states that make allocation reclamation
safe:

- `succeeded`;
- `terminal_failure`;
- `cancelled_before_submit`;
- `cancelled_after_submit`; and
- `rejected_before_submit`.

Pending, timed-out, unknown, quarantined, and device-lost observations
intentionally have no terminal enum value. They retain the pin until a separate
backend authority can reconcile a safe terminal state. A timeout is not
completion, and `MetalAsyncDispatchQuarantineV1` is not terminal evidence. The
implemented Metal error path instead constructs a separately validated
`MetalAsyncDispatchTerminalFailureV1` from one exact retained `.error`
snapshot; it does not promote quarantine by itself.

The submission, backend-completion, and output roots must match the outcome:

| Outcome | Submission | Backend completion | Output |
| --- | --- | --- | --- |
| succeeded | required | required | required |
| terminal failure | required | required | absent |
| cancelled after submit | required | required | absent |
| cancelled before submit | absent | absent | absent |
| rejected before submit | absent | absent | absent |

The SHA-256 transcripts are deterministic composition evidence, not
authentication. Live completion additionally requires the exact same-process
adapter callback captured at acquisition.

## Failure behavior

The contract prefers a retained allocation over an unsafe release:

- invalid, stale, foreign, or tampered evidence leaves the pin active;
- adapter validation failure leaves the pin active;
- publication/session drift leaves the pin active;
- Bank settlement conflict leaves the pin active;
- a private post-Bank settlement-callback failure retains exact
  `settlement_pending` evidence for retry rather than clearing adapter state;
- generation or structural-revision exhaustion fails closed and may retain the
  pin rather than regress a tree token;
- an unavailable pin registry fails before coordinator mutation; and
- allocation `release` returns `DispatchInFlight` before issuing a FreePermit
  or invoking a backend free callback.

This can intentionally retain resources after ambiguous device failure.
The Metal path now detects ambiguous or unsafe post-submit observations and
records sticky quarantine. One exact retained native command-buffer `.error`
may now be authorized as core `terminal_failure` and settled without publishing
output; it remains pinned until Bank settlement and exact native error
finalization both succeed. Source-bound device-loss observation and
loss-bound retirement of an already quiesced allocation now exist, and Phase A
settles the exact command-specific native `5/1/11` case. Callback-safe
retirement of pending, submission-ambiguous, completion-unknown, and
invalid-completion ownership now exists as Phase B. It detaches the exact
native callback target and authorizes only the dedicated zero-output
ownership-retired terminal; it does not manufacture a successful completion
from missing evidence. A generic timeout still grants no authority. Fresh
selection and automatic migration remain separate roadmap work.
Other adapters that cannot prove a safe pre-submit rejection must likewise
retain the pin rather than infer one.

## Verification layers

The test suite separates claims instead of treating every test as a simulated
device:

1. **Portable deterministic tests** use Zig fake adapters and state-machine
   fixtures to cover intent reservation/abort, callback drift, failure,
   tamper, stale-token, copied-permit, slot-reuse, pre-submit terminal,
   settlement retry, out-of-order completion, acquire-versus-retire races, and
   the pointer-free async ticket/quarantine shapes and exact terminal-error
   reconciliation roots. The separate lifecycle contract tests cover every
   source/state mapping, exact code `11` classification, native/synthetic
   separation, and mutation/replay/substitution rejection. The Phase A tests
   additionally replay the fixed retention/plan/receipt bindings and require
   native-only production eligibility. Phase B adds fixed
   retention/plan/fence/receipt replay for all four retained ownership states,
   native-only production eligibility, detach-with-record-retained invariants,
   zero output authority, and duplicate/foreign/late-settlement rejection.
   They call no Metal API and execute no GPU work.
2. **Host integration tests** exercise the real ResourceBank, LeaseTree,
   mutexes, fixed storage, publication fences, and thread scheduling without
   claiming accelerator execution. The independent Python oracle separately
   rebuilds the exact error-sidecar, backend-completion, and core-terminal roots
   plus the Phase A roots and Phase B
   retention/plan/fence/receipt roots and substitution checks; it also executes
   no GPU work.
3. **Native Metal tests** open a real `MTLDevice`, create and inspect real Shared
   `MTLBuffer` resources, dispatch the exact registry-owned buffers on the
   selected device, separate submit from completion observation, authenticate
   the exact completed command and output role, compare output with a CPU
   oracle, and prove that the native record is finalized only through the
   private callback after Bank settlement. The rejection and cancellation
   cases retain the same real context and resource ownership but intentionally
   submit zero GPU commands. Rejection may inspect those resources;
   cancellation is native-free. All three paths settle through the same private
   callback and return ownership to zero. The focused correctness gate also
   verifies initial selected-device observer membership and an unchanged
   lifecycle snapshot around one real successful command on the built-in M1
   development host; it does not exercise a removal callback.
4. **Build-isolated native fault/race tests** run another real, physically
   successful Metal command while publishing a separate test-only `.error`
   overlay. They prove production-symbol isolation, a deterministic one-winner
   arm race, separate physical/published completion facts, Bank-first
   settlement, exact native finalization and state clearing, and
   `settlement_pending` confirmation retry without a second Bank release or
   native finalization. They do not induce or claim a physical driver,
   hardware, or device-loss failure and provide no performance evidence. The
   same isolated configuration separately creates real buffers and retires
   their native strong references through the ordinary LeaseTree release under
   an explicitly synthetic test-only loss permit. That proves ownership
   cleanup and logical settlement, not a reproduced removal or physical
   reclamation. Its code-`11`-shaped publication is likewise a synthetic Phase
   A overlay and cannot satisfy the native-only production gate. A separate
   four-state Phase B matrix submits real commands over real resources. Its
   pending case holds the completion handler before the ARC-owned callback
   gate. The other cases retain a post-commit ambiguous disposition
   authenticated by the native record, a valid unknown projection over
   independently verified physical success, or an exact completed-output-read
   rejection before caller memory is written. Synthetic loss then exercises
   Bank-first exact native unlink, tombstone replay, and unchanged caller
   output for every state; the held case additionally proves detachment before
   handler exit and safe later release. This is native command/resource and
   callback/record ownership evidence, not physical removal, driver or hardware
   failure, output recovery, performance, residency, migration, reset, or
   physical-reclaim evidence.

Cross-compilation proves source and build portability only. It is never
reported as native operating-system, driver, or accelerator evidence.

Run the portable contract and independent oracle with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_lifecycle_contract.zig -OReleaseSafe

tools/zig-with-ephemeral-cache.sh test \
  src/core/device_allocation_lease_tree.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_allocation_lease_tree

tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_dispatch_reconciliation.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_loss_dispatch_reconciliation

tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_dispatch_callback_retirement.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_loss_dispatch_callback_retirement
```

Run the hardware-backed gate on macOS with Metal enabled:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-allocation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the isolated publication-fault and settlement-race gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-fault-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run all native device gates without overlap with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

The suite order is readiness → allocation ownership → fault/reconciliation →
focused correctness.

## Open follow-up work

Contributor-ready extensions include:

- retain physical removal-requested and removed callbacks on removable
  hardware;
- add fresh device selection and explicit migration policy;
- bounded multi-slot completion scheduling without weakening adapter identity;
- additive snapshot capacity and active-pin telemetry;
- separate published-reference authority for outputs retained after dispatch;
- post-creation allocated-size settlement under a new accounting ABI;
- physical residency and eviction evidence;
- queue scheduling and transfer ownership across multiple devices;
- additional GPU backends with the same correctness and lifetime gates;
- direct utilization, thermal, frequency, power, and energy adapters;
- retained performance evidence under declared campaigns; and
- retained native evidence across supported operating-system and device
  matrices.
