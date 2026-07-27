# Device-loss Retirement V1

Device-loss Retirement V1 closes one narrow ownership gap: after an exact
device-loss transition, a quiesced native adapter may relinquish the strong
references for one exact `LeaseTree` allocation and return its logical charge
through the existing `FreePermit` settlement path.

This is a loss-bound cleanup protocol. It is not device recovery, output
publication, migration, reset, residency, or proof of physical memory
reclamation.

## Contract boundary

The portable layer defines two fixed-width, pointer-free values:

- `LossRetirementPlanV1` is 544 bytes. It binds the source instance,
  observation, present-to-lost transition, requirement, prior inventory,
  selected entry and capability, selection receipt, allocation authority,
  request, lease, allocation-leaf set, backend-object set, recovery generation,
  and an adapter-local challenge.
- `LossRetirementReceiptV1` is 440 bytes. It binds the exact plan to the
  ordinary LeaseTree `released` / `normal_release` terminal, the returned
  logical bytes, the number of released native references, and an
  adapter-settlement root.

The plan is composition evidence, not a free permit. Construction requires the
source cursor immediately before the loss event, so callers must compose it
while atomically accepting the lifecycle transition. A plan cannot be rebuilt
from an already advanced cursor.

Production eligibility is deliberately narrower than structural validity.
Only native `removed_notification` or exact native
`command_buffer_device_removed` evidence can arm the production path.
`test_injected` evidence remains structurally valid for deterministic tests but
is always production-ineligible.

## Authority and settlement

The cleanup sequence is:

1. Accept an exact source-bound transition from the selected `present` entry to
   its newer `lost` successor.
2. Build and validate a plan against the exact live allocation lease and the
   private adapter challenge.
3. Enter the Coordinator-owned arm boundary. While holding its mutex, the
   coordinator validates its byte-for-byte retained live lease, ordered object
   set, allocation leaves, adapter identity, current Bank/tree/session state,
   and zero active dispatches.
4. Under that same lock, let the native adapter recompute its live object set,
   require the byte-for-byte native snapshot previously consumed for the
   observation, revalidate the same currently sticky loss source without
   consuming it again, refuse command/terminal-validation/quarantine state,
   and retain the private permit. A caller-resealed same-source sequence or
   evidence root rejects. Production callers cannot bypass this
   Coordinator-to-adapter path.
5. Ask the existing LeaseTree coordinator to release the allocation. The
   coordinator obtains and retains the private Bank `FreePermit`; the adapter
   drops exact native references first, and logical accounting commits only
   after every required release succeeds.
6. Complete the retirement from the exact ordinary release terminal and retain
   an idempotent adapter tombstone.

Partial adapter failure keeps coordinator recovery authority and the logical
charge. Exact retry visits only objects that remain live; it does not release
an already retired object twice.

`AdapterV1` callbacks are trusted, same-process Coordinator capabilities in
this V1 architecture. Completion must use the terminal returned by the exact
bound Coordinator. Hash and receipt validation detect substitution and support
deterministic replay, but do not authenticate Bank state to an untrusted
same-process caller or independent verifier. A future untrusted-plugin/process
boundary would need a separate post-Bank confirmation capability.

For the Metal backend, the production release path checks the retained
lifecycle source and private token registry. It deliberately performs no
post-loss `MTLDevice` or `MTLBuffer` property read. Dropping an Objective-C
strong reference proves that Glacier relinquished that reference; it does not
prove when the driver reclaimed pages.

## Receipt non-authorities

Every valid retirement receipt requires:

- `physical_reclaim_observed == 0`;
- an all-zero output-authority root;
- an all-zero migration-authority root;
- an all-zero reset-authority root; and
- an all-zero physical-reclaim-authority root.

Consequently, the receipt cannot be used as a successful inference result, a
replacement-device decision, a reset permit, or a physical-memory measurement.

## Evidence layers

The tests intentionally make different claims:

1. Portable Zig contract tests use deterministic lifecycle and allocation
   models. They cover literal ABI/layout checks, stable roots, native-versus-
   synthetic eligibility, unavailable-state rejection, substitution,
   mutation, replay, terminal mismatch, and forbidden authority claims. They
   call no Metal API.
2. The independent standard-library Python oracle reconstructs the canonical
   little-endian roots and repeats the semantic rejection matrix. It also calls
   no Metal API.
3. The build-isolated macOS fault gate opens a real `MTLDevice`, creates real
   `MTLBuffer` objects, and exercises the real LeaseTree release and
   strong-reference-drop path under an explicitly synthetic, test-only loss
   permit. It proves native ownership cleanup and logical settlement on that
   host; it does not reproduce physical device removal.
4. The production path accepts only a live same-source native sticky loss. A
   retained physical-removal callback campaign still requires removable
   hardware and remains separate work.

Cross-compilation is source/build evidence only and is never reported as native
device-loss execution.

## Focused verification

Run the portable contract and independent oracle with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_loss_retirement.zig -OReleaseSafe

python3 -m unittest \
  bench.tests.test_device_loss_retirement
```

Run the isolated native Metal fault gate on a supported macOS host with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-fault-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

## Open follow-up work

- retain a real removal callback artifact on removable hardware;
- classify and reconcile retained in-flight/quarantined work after device loss;
- create a fresh inventory and deterministic replacement selection;
- define explicit retry, restart, and migration policy;
- add separate physical residency and reclaim evidence;
- add multi-device scheduling and additional GPU backends; and
- retain native device-loss evidence across the supported OS/device matrix.
