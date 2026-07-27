# Device-Loss Dispatch Reconciliation

Device-loss dispatch reconciliation closes one narrow lifetime gap: an exact
native command can report Metal command-buffer status `5`, command-buffer error
domain `1`, and device-removed code `11` while its LeaseTree dispatch pin, Bank
charge, native command record, and allocation still have to remain owned.

Phase A handles only that command-specific terminal signature. Device loss by
itself is not command completion. Pending, ambiguous, unknown, malformed, or
non-command-specific observations retain every pin, charge, buffer, and native
record unless the separate callback-safe Phase B ownership protocol detaches
the exact native callback and completes its Bank-first settlement.

## Portable evidence

The hardware-independent contract defines three pointer-free values:

| Value | Size | Purpose |
| --- | ---: | --- |
| `LossDispatchRetentionV1` | 440 bytes | Binds the exact selected capability, live allocation lease, dispatch pin, request, submission, quarantine, native `5/1/11` projection, and adapter challenge. |
| `LossDispatchReconciliationPlanV1` | 240 bytes | Binds the retention to one canonical `present -> lost` lifecycle transition and reconciliation generation. |
| `LossDispatchReconciliationReceiptV1` | 448 bytes | Composes the exact terminal failure, successful dispatch completion, Bank settlement, native finalization, and adapter settlement root. |

Canonical SHA-256 roots cover every field. Validators replay the nested
capability selection, lifecycle transition, allocation lease, dispatch pin,
terminal evidence, and completion evidence instead of trusting copied digests.

These records are composition evidence, not runtime authority. They contain no
pointer or private Bank permit and grant no output publication, retry,
restart, migration, fresh device selection, device reset, allocation release,
physical reclaim, or residency claim.

## Exact settlement flow

For one retained command:

1. The Coordinator validates the exact active lease and `.pinned` dispatch
   slot, the exact bound adapter, the live Bank pin, the object and leaf sets,
   and the absence of terminal or completion state.
2. The Metal adapter validates the exact ticket and sticky quarantine, then
   seals the retention challenge without exposing the Bank permit.
3. Production authorization accepts only native
   `command_buffer_device_removed` evidence with status/domain/code `5/1/11`
   and the same sticky backend lifecycle loss. Synthetic evidence cannot enter
   this gate.
4. Existing terminal-failure construction produces zero output authority.
   The Coordinator then consumes the Bank pin before asking the adapter to
   finalize the exact native command record.
5. The adapter stores an exact settlement tombstone and receipt. If an outer
   confirmation is lost, the Coordinator keeps the slot
   `settlement_pending`; retry replays confirmation without consuming the Bank
   pin or finalizing the native command twice.
6. Public receipt retrieval requires the exact successful
   `LeaseTreeDispatchCompletionV1`. Only after the dispatch slot is gone may
   the separate device-loss retirement contract release allocation-owned
   native references and logical device charge.

The receipt proves one Bank pin settlement and one target-command
finalization. It does not require a global zero native-command count because
unrelated sibling adapters may still own commands.

## Native and deterministic tests

The Zig and Python contract tests are deterministic models. They open no Metal
device and execute no GPU work; they independently rebuild canonical roots and
reject mutation, substitution, replay, and authority drift.

The build-isolated native Metal fault gate uses real `MTLDevice`,
`MTLBuffer`, command-buffer, and GPU execution. One command first completes
physically as `.completed`; only then does the non-installed fault shim publish
a code-`11`-shaped `.error` overlay. Lifecycle classification happens before
that overlay, so the native lifecycle snapshot must remain unchanged.

That path proves the synthetic authorization boundary, exact retention,
Bank-first settlement, one-time native finalization, confirmation retry, and
composition with allocation retirement. It is not evidence of a physical
device removal, driver or hardware failure, successful output from the
published error, automatic migration, or performance.

Run the portable gates with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_dispatch_reconciliation.zig -OReleaseSafe
python3 -m unittest \
  bench.tests.test_device_loss_dispatch_reconciliation
```

Run the native macOS gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-fault-test -Dmetal=true -Doptimize=ReleaseSafe -j2
```

## Phase B and later work

[Device-loss Dispatch Callback Retirement](DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md)
is the integrated Phase B path for `pending`, `submission_ambiguous`,
`completion_unknown`, and `invalid_completion`. It detaches an ARC-owned native
callback gate while retaining the exact command record, authorizes the
dedicated `ownership_retired_after_device_loss` terminal with zero output,
settles the Bank pin before exact native unlink, and stores a replay tombstone.
It never converts loss, timeout, or missing completion into successful output.
Allocation retirement remains separate.

The current native gate combines real Metal commands and resources with
build-isolated, one-shot state seams and synthetic injected loss. It exercises
pending, submission-ambiguous, completion-unknown, and invalid-completion
retirement end to end without constructing the adapter retention by hand. This
is not evidence of physical removal, driver or hardware failure, recovered
output, performance, residency, migration, reset, or physical reclaim. Later
work includes removable-hardware callback campaigns, direct physical device
telemetry, fresh-device selection, explicit migration policy, multiple queue
slots, multi-device scheduling, additional GPU backends, and retained native
OS/device matrices. Direct Phase B retirement-protocol telemetry is separately
integrated and grants no reconciliation authority.
