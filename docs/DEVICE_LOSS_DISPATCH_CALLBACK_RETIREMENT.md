# Device-Loss Dispatch Callback Retirement

Device-loss Dispatch Callback Retirement is the callback-safe Phase B
ownership protocol for one exact Metal dispatch that is still `pending`,
`submission_ambiguous`, `completion_unknown`, or `invalid_completion` after an
accepted `present -> lost` transition.

The protocol does not infer command completion from device loss, elapsed time,
or a missing callback. Instead, an ARC-owned callback gate detaches the
completion handler from its native Metal context while the command record and
its command-held resource references remain retained. Callback exit is
diagnostic only and is not a prerequisite for that fence.

## Portable evidence

`src/core/device_loss_dispatch_callback_retirement.zig` defines four
pointer-free values:

| Value | Size | Purpose |
| --- | ---: | --- |
| `LossDispatchCallbackRetentionV1` | 464 bytes | Binds the selected capability, exact live lease and dispatch pin, request, async ticket, submission, optional quarantine, native classification, and adapter challenge. |
| `LossDispatchCallbackRetirementPlanV1` | 240 bytes | Binds that retention to one accepted `present -> lost` lifecycle transition and one retirement generation. |
| `LossDispatchCallbackFenceV1` | 408 bytes | Proves that the exact callback target is detached while the exact native command record remains retained for private settlement. |
| `LossDispatchCallbackRetirementReceiptV1` | 504 bytes | Composes the fence, `ownership_retired_after_device_loss` terminal, dispatch and Bank completions, exact native retirement, and adapter replay tombstone. |

Canonical SHA-256 roots cover every field and validators replay the nested
selection, lifecycle, lease, pin, terminal, completion, and settlement
bindings. The four canonical retained states preserve their different native
facts:

- `pending` retains a submitted command with no adapter-retained completion or
  quarantine; native prepare may later freeze an already-published callback
  snapshot without granting output authority;
- `submission_ambiguous` retains a commit-started disposition and sticky
  native-bridge quarantine;
- `completion_unknown` retains the submitted command, its bounded observation
  failure, and sticky quarantine; and
- `invalid_completion` retains the observed completed status, completion
  validation failure, and sticky quarantine.

None of these states is relabelled as success, terminal command failure, or
cancellation. The retirement terminal has a nonzero submission root and
backend-terminal root, the dedicated
`ownership_retired_after_device_loss` outcome, and a zero output root.

## Native settlement protocol

Production arming accepts only an exact native `removed_notification` or
`command_buffer_device_removed` `present -> lost` transition and revalidates
the same sticky native source at the live backend. A
`removal_requested_notification` is not sufficient. The synthetic test entry
point accepts only `test_injected` evidence and is compiled into the
non-installed fault-test build; production artifacts expose no synthetic
retirement controls.

Settlement has two native phases:

1. The adapter validates the exact active lease, `.pinned` dispatch, object
   set, ticket, submission, retained state, lifecycle transition, and
   adapter-local challenge.
2. Native prepare freezes the current command facts, detaches the ARC-owned
   callback gate from the native Metal context, and returns an exact permit. The
   native command record and its four command-held resource references remain
   live. A callback that is already running may finish later, but after
   detachment it cannot reacquire the native Metal context.
3. The adapter seals `LossDispatchCallbackFenceV1` and authorizes only the
   dedicated ownership-retired terminal. It grants no output authority.
4. The Coordinator validates that terminal and consumes the private Bank
   dispatch pin first.
5. Only the private post-Bank callback commits the exact native permit. Commit
   unlinks one native command record, releases its command-held references,
   and records the native and adapter replay tombstones.
6. Exact receipt replay returns the retained 504-byte receipt without
   consuming another Bank pin or unlinking another native command.

This ordering is narrower than allocation release. The allocation lease,
allocation-owned native references, and logical device-byte charge remain live
after dispatch retirement. The separate
[Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md) or ordinary release
path may run only after the dispatch slot is gone.

## Evidence layers

The portable Zig contract tests and independent Python oracle are deterministic
structural evidence. They open no Metal device, execute no GPU work, and cover
all four retained states plus mutation, substitution, replay, duplicate,
foreign, and late-settlement rejection.

The build-isolated native Metal gate is different. It creates real
`MTLDevice`/`MTLBuffer` resources and submits real commands for all four retained
states. The pending case stops its completion handler before the callback gate
and later releases that handler safely. Separate one-shot test seams retain a
post-commit ambiguous disposition authenticated by the native record; after
independently verified physical success, publish a valid unknown projection by
changing only `callback_fault`; or reject one exact completed output read
before caller memory is written, which the adapter retains as completion
validation code `6`. Those paths make the adapter retain
`submission_ambiguous`, `completion_unknown`, and `invalid_completion`
respectively; they do not construct portable retention evidence by hand.
Synthetic loss then authorizes callback detachment, Bank-first settlement,
exact native unlink, replay, unchanged caller output, and separate later
allocation release for each state.

The state-producing seams and lifecycle loss are synthetic, context-local,
one-shot, and compiled only into the non-installed fault shim. The production
shim exports no fault controls. This matrix does not reproduce a physical
device removal, driver fault, hardware fault, or native removal callback. It
also establishes no successful output, migration, reset, physical reclaim,
residency, queue-depth, latency, throughput, utilization, power, thermal, or
energy claim.

Cross-target builds are compile evidence only. They do not establish native
Metal, operating-system, driver, or device behavior on the target.

Run the portable gates with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_dispatch_callback_retirement.zig -OReleaseSafe
python3 -m unittest \
  bench.tests.test_device_loss_dispatch_callback_retirement
```

Run the build-isolated native gate on macOS with Metal enabled:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-fault-test -Dmetal=true -Doptimize=ReleaseSafe -j2
```

## Open follow-up work

Phase B is integrated for the current portable contracts, independent oracle,
Metal adapter, ARC-owned callback gate, and the build-isolated native
four-state retained-state matrix. All four states traverse the real Metal
command/resource registry, adapter-derived retention, synthetic-loss
authorization, callback detachment, Bank-first settlement, native unlink, and
receipt replay.

The following remain separate roadmap work:

- retain native removal-requested and removed callback artifacts on suitable
  removable hardware;
- add direct dispatch-retirement telemetry without weakening lock or authority
  boundaries;
- create a fresh inventory, fresh selection, and explicit migration policy;
- add bounded multi-slot and multi-device scheduling;
- implement additional GPU backends with equivalent callback-lifetime gates;
- add physical residency and reclaim evidence under separate authorities;
- retain native OS/device/driver matrices; and
- publish performance evidence only through declared reproducible campaigns.
