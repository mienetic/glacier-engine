# Device Lifecycle Observation V1

Device Lifecycle Observation V1 records source-specific device availability
changes without granting resource-release or recovery authority. It composes
with the existing capability inventory and deterministic selection contract:
an observation can replace one exact present entry with an `unavailable` or
`lost` successor in a strictly newer discovery epoch, after which normal
selection excludes that entry.

The earlier selection receipt remains historical evidence for its original
inventory only; it cannot validate against the successor inventory root.
Creating and acting on a fresh selection remains a separate operation.

This milestone is observation and fail-closed admission, not automatic device
recovery.

## Portable contracts

`src/core/device_lifecycle_contract.zig` exports three fixed-width,
pointer-free values:

- `SourceCursorV1` is 40 bytes and binds one 32-byte source-instance digest
  plus the last accepted native source sequence.
- `ObservationV1` is 280 bytes and binds that source instance and source
  sequence, the native or synthetic evidence class, exact prior present entry,
  capability root, evidence root, and recomputed canonical prior-inventory
  root.
- `TransitionReceiptV1` is 272 bytes and binds that observation to one sealed
  successor entry. The successor must preserve the capability and policy rank
  and use a strictly newer discovery epoch.

The native adapter derives the source instance and monotonically increasing
source sequence; neither is a caller-selected observation label. Its
source-instance digest binds a 256-bit per-context nonce, the observer
generation as a reset discriminator, the selected registry ID, and the stable
device and placement identities. Freshness therefore does not rely on the
64-bit observer generation alone. Validation requires the same source instance
and a sequence greater than the cursor's last accepted sequence. Sequence gaps
are valid because callbacks may coalesce before a caller observes them. After
acceptance, the caller must durably and atomically commit the returned advanced
cursor with any dependent state; an in-memory or separately committed cursor
is not a crash-safe replay fence. Mutation, stale-sequence replay,
source-instance mismatch, prior-inventory substitution, cross-device
substitution, observation substitution, and successor substitution reject.

The live native adapter additionally claims the exact native snapshot
at most once. Concurrent or delayed attempts to wrap the same snapshot cannot
create another accepted observation even if they hold an older portable
cursor. Portable hashes provide deterministic composition and integrity
checking; they do not authenticate the observer, establish cryptographic
origin, or provide hardware or platform attestation.

The canonical mappings are:

| Source | Evidence class | Observed state | Transition |
| --- | --- | --- | --- |
| `initial_membership` | native | `present` | none |
| `added_notification` | native | `present` | none |
| `inventory_absent` | native | `unavailable` | present → unavailable |
| `removal_requested_notification` | native | `unavailable` | present → unavailable |
| `removed_notification` | native | `lost` | present → lost |
| `command_buffer_device_removed` | native | `lost` | present → lost |
| `test_injected` | synthetic | `lost` | present → lost |

`command_buffer_device_removed` is valid only for exact command-buffer status
`5`, Metal command-buffer error domain `1`, and error code `11`. Other command
errors remain distinct. `test_injected` is always synthetic and cannot carry
raw native command fields, so it cannot be presented as a physical failure.

Neither contract grants allocation, dispatch, free, unpin, quarantine-clear,
context-reset, fresh-selection, migration, or output-publication authority.

## Native Metal observation

Each `MetalBackend` context installs
`MTLCopyAllDevicesWithObserver` and verifies that its selected `registryID`
appears in the initial device array. The notification block captures an
ARC-owned lifecycle state, not the malloc-owned Metal context. Teardown removes
the observer before releasing the context.

The fixed native snapshot retains:

- observer generation and monotonically increasing event sequence;
- exact selected-device registry ID;
- initial membership;
- distinct `added`, `removal_requested`, `removed`, and
  `command_buffer_removed` event kinds;
- a sticky source bitset from which the effective state is selected
  monotonically, so a later weaker callback cannot downgrade a stronger loss;
  and
- explicit observer-active and observer-fault fields.

Generic API failure is not relabelled as removal. An unmodified native
completion publishes the sticky `command_buffer_removed` event only from the
exact status/domain/code tuple above, before any test-only overlay.

New Metal work acquires a native admission lease whose begin step is the
linearization point against lifecycle publication. Live `MTLDevice` property
reads used by `deviceInfo` and `allocationLimits` acquire the same lease rather
than relying on a separate Zig precheck. Work admitted before a loss may
continue and settle under its existing command, buffer, pin, charge, and
quarantine authorities; new work or live property access whose admission
begins after the loss is rejected. The lease therefore closes both the
check-then-submit and check-then-property-read races without turning the
lifecycle snapshot into release, recovery, or migration authority.

The backend retains the selected device's initial identity. A loss observation
uses that retained identity instead of querying a device that may already be
dead or detached.

The observer generation is a reset discriminator inside the nonce-bound native
source-instance boundary. A generation mismatch fails closed rather than
resetting the caller's cursor. Fresh adoption requires a newly validated
inventory and an exact initial snapshot at source sequence 1; it does not
inherit prior authority and grants no dead-resource recovery, quarantine
clearing, or migration.

## Evidence layers

Run the portable contract gate with:

```sh
tools/zig-with-ephemeral-cache.sh test \
  src/core/device_lifecycle_contract.zig -OReleaseSafe
```

These tests are deterministic contract models. They open no Metal device and
exercise source transitions, replay, mutation, and native-versus-synthetic
error classification without reproducing the corresponding physical device
events.

Run the native correctness gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-correctness-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

On the actual built-in M1 development host, this gate proved that the observer
was installed, the selected registry ID was an initial member, and the
lifecycle snapshot remained unchanged while one real Metal command completed
successfully. The native allocation gate races two threads against exact
consumption of that initial snapshot and requires one `consumed` result and one
`stale` result; the snapshot remains readable afterward. That is real-GPU
evidence for observer installation, initial membership, normal command
execution, admission, and at-most-once consumption on that no-event host
session.

The build-isolated fault gate is a different evidence layer. Its published
command error is deliberately injected after a real command succeeds. It is
not a physical command-buffer, driver, hardware, or device-loss failure.

## Current boundary and next work

The M1 GPU used for the native gate is built in. No physical
removal-requested or removed callback was exercised, so this milestone does
not claim a removable-device campaign or safe recovery from one. Loss
transitions and error paths are covered by deterministic synthetic/model tests,
not by pretending that the built-in GPU was physically removed.

Still open:

- retain removal-requested and removed callbacks on suitable removable
  hardware;
- define safe retirement or abandonment of dead native resources;
- reconcile or clear quarantines without releasing ownership early;
- create and validate a fresh inventory and selection receipt;
- create a fresh backend context and rehydrate model/input state; and
- authorize explicit migration without reusing stale device authority.

See [Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md),
[Device Allocation Lease V1](DEVICE_ALLOCATION_LEASE.md),
[Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md), and
[Native Metal Allocation Adapter](NATIVE_METAL_ALLOCATION.md).
