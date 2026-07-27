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
LeaseTreeDispatchPinV1 ── submit / reject / cancel ──────────────┐
        │                                                        │
        │ release is rejected while the pin is active            │
        │                                                        ▼
        └──────── exact terminal evidence ◀── adapter observation or
                                              no-submit authority
                                 │
                                 │ adapter validates terminal state
                                 ▼
                    consume private Bank pin
                                 │
                                 ▼
                    private settlement callback
                                 │
                                 ▼
                    LeaseTreeDispatchCompletionV1
                                 │
                                 ▼
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
Bank completion. The Metal callback validates the full composition, atomically
clears its prepared request, intent, pin, terminal, and unresolved state, and
records an exact replay tombstone. Core frees its dispatch slot only after that
callback succeeds.

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

## Terminal outcomes

The public terminal enum contains only states that make allocation reclamation
safe:

- `succeeded`;
- `terminal_failure`;
- `cancelled_before_submit`;
- `cancelled_after_submit`; and
- `rejected_before_submit`.

Pending, timed-out, unknown, and device-lost observations intentionally have no
terminal enum value. They retain the pin until a separate backend authority can
reconcile a safe terminal state. A timeout is not completion.

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
Quarantine and device-loss reconciliation are later authorities; this contract
does not manufacture a successful completion from missing evidence.
The Metal helper can settle only its exact pure cancellation or canonical
deterministic geometry/host-length/role rejection before submission. Errors
after the native submission boundary, timeouts, unknown queue state, and device
loss remain pinned until their own reconciliation authority proves a safe
terminal state.
Other adapters that cannot prove a safe pre-submit rejection must likewise
retain the pin rather than infer one.

## Verification layers

The test suite separates claims instead of treating every test as a simulated
device:

1. **Portable deterministic tests** use Zig fake adapters and state-machine
   fixtures to cover intent reservation/abort, callback drift, failure,
   tamper, stale-token, copied-permit, slot-reuse, pre-submit terminal,
   settlement retry, out-of-order completion, and acquire-versus-retire races.
   They call no Metal API and execute no GPU work.
2. **Host integration tests** exercise the real ResourceBank, LeaseTree,
   mutexes, fixed storage, publication fences, and thread scheduling without
   claiming accelerator execution. The independent Python oracle separately
   rebuilds ABI roots and substitution checks; it also executes no GPU work.
3. **Native Metal tests** open a real `MTLDevice`, create and inspect real Shared
   `MTLBuffer` resources, dispatch the exact registry-owned buffers on the
   selected device, wait for the real command buffer, compare output with a CPU
   oracle, and prove that release is fenced through private settlement. The
   rejection and cancellation cases retain the same real context and resource
   ownership but intentionally submit zero GPU commands. Rejection may inspect
   those resources; cancellation is native-free. Both settle through the same
   private callback and return ownership to zero.

Cross-compilation proves source and build portability only. It is never
reported as native operating-system, driver, or accelerator evidence.

Run the portable contract and independent oracle with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_allocation_lease_tree.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_allocation_lease_tree
```

Run the hardware-backed gate on macOS with Metal enabled:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-allocation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

## Open follow-up work

Contributor-ready extensions include:

- device-loss inspection, quarantine, and safe terminal reconciliation;
- bounded asynchronous completion delivery without weakening adapter identity;
- additive snapshot capacity and active-pin telemetry;
- separate published-reference authority for outputs retained after dispatch;
- post-creation allocated-size settlement under a new accounting ABI;
- physical residency and eviction evidence;
- queue scheduling and transfer ownership across multiple devices;
- direct utilization, thermal, frequency, power, and energy adapters; and
- retained native evidence across supported operating-system and device
  matrices.
