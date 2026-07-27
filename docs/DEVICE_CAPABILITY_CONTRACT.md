# Device Capability and Selection Contract

Glacier separates a backend being compiled from a device being usable for one
sealed execution plan. `DeviceCapabilityV1` and its selection records provide a
portable, pointer-free decision boundary between those two facts.

The contract is deliberately additive. It binds to an existing Common Model
Contract execution-plan root instead of changing that wire, and it grants no
live device, allocation, queue, or publication authority.

## Contract values

### Device capability

A capability fingerprint describes stable facts that can be checked before
resource admission:

- backend and device class;
- canonical tested operation/type/numerical-profile bits, their derived
  aggregate operator/type/numerical bits, and lifecycle-feature bits;
- declared single-allocation, total-device-byte, and queue ceilings;
- backend, physical-device, optional driver/runtime, and placement identities;
  an unavailable driver/runtime identity is represented by the all-zero digest;
  and
- one canonical capability root over every field.

Dynamic observations do not belong in the fingerprint. Current allocated
bytes, utilization, residency, queue depth, temperature, frequency, power, and
energy remain observations with their own availability and provenance.

The aggregate operator, element-type, and numerical sets are descriptive only.
They must equal the union derived from the canonical operation profiles.
Compatibility requires the profiles themselves, so independent sets can never
invent an untested Cartesian-product combination such as an operator paired
with an element type that belongs only to another operator.

A zero physical ceiling means that the adapter does not claim that ceiling. It
is not interpreted as unlimited capacity. A request that asserts a nonzero
bound against an unknown ceiling fails compatibility rather than guessing.

### Inventory entry

An inventory entry attaches one capability to:

- a nonzero adapter-defined discovery epoch;
- a deterministic policy rank;
- an explicit `present`, `unavailable`, or `lost` state; and
- a canonical entry root.

The epoch is an adapter-defined inventory-generation value, not proof of
liveness by itself. It makes a receipt specific to one bounded discovery view.
Before granting later live authority, an adapter must obtain or validate a
fresh inventory view and reject an epoch, fingerprint, state, or device-identity
change.

### Device requirement

A requirement binds:

- the exact execution-plan root;
- required canonical operation profiles plus their derived aggregate
  operator, element-type, numerical-policy, and lifecycle-feature bits;
- requested device bytes and queue slots;
- an optional pinned capability; and
- either forbidden fallback or explicit CPU fallback.

The requirement is decision evidence. `ResourceBank` remains the authority for
logical resource admission, while native adapters remain responsible for
physical allocation.

### Selection receipt

Selection produces a receipt containing the requirement, canonical inventory,
selected inventory entry and capability, discovery epoch, selected device
class, and whether explicit CPU fallback was used.

The receipt does not contain a pointer or backend handle. It cannot allocate,
submit work, publish output, or prove that the selected device remained alive
after selection.

## Deterministic selection

Selection is allocation-free and bounded:

1. validate every capability and inventory entry before considering a winner;
2. reject duplicate entry or capability identity and duplicate device
   identity within one stable backend identity;
3. derive the inventory root independently of discovery order;
4. reject non-present entries and every missing operation profile, lifecycle,
   memory, or queue requirement;
5. honor a pinned capability without fallback;
6. prefer an exact requested device class;
7. consider CPU only when the requirement explicitly authorizes it; and
8. break equivalent candidates by policy rank and then capability root.

Malformed inventory is an error, even when another entry could satisfy the
request. This prevents an adapter from hiding contradictory discovery state
behind a usable candidate.

Selection happens before resource or scheduler mutation. Callers can therefore
reject an unavailable device without acquiring a `ResourceBank` receipt or
opening a publication transaction.

## Metal integration

The macOS Metal adapter projects a stable subset of `MetalDeviceInfo` into this
common contract. Registry-based device identity, tested operation bits,
queue/fence behavior, and placement identity belong in the capability. The
current bounded adapter does not retain a driver/runtime version, so that
identity is explicitly all-zero. `currentAllocatedSize` remains a dynamic
observation and is never hashed into the capability fingerprint.

The native readiness gate binds one local discovery epoch and revalidates the
selected fingerprint and registry identity from a fresh device query
immediately before its first Metal resource acquisition, then checks the
post-run device evidence again. The current native selection capability
advertises only the canonical INT4-to-FP32 matrix-vector profile exercised by
that gate. The FP16 matrix-multiplication path has a separate native CPU-oracle
correctness test; it is not added to the readiness capability merely because
its shader compiled.

Metal pipelines are resolved and cached independently. The readiness path
requires the exact INT4 matrix-vector pipeline before emitting its capability
decision and checks it again before acquisition; an absent unrelated dequant or
FP16-matmul pipeline does not invalidate that operation. Conversely, a library
without the required matrix-vector pipeline cannot advertise readiness.

The readiness requirement deliberately sets its largest-single-allocation
bound to zero because the retained Metal source exposes no trustworthy maximum
single-buffer value. That means this slice makes no per-buffer compatibility
claim. `recommendedMaxWorkingSetSize` is used only as total capacity context,
not as proof of allocation or residency.

The separate native allocation adapter emits a distinct allocation-aware
inventory entry. It uses `MTLDevice.maxBufferLength` as the hard requested
length ceiling and a caller-selected logical total no larger than
`recommendedMaxWorkingSetSize`. Allocation remains fallible. Its V1 quote and
ChildLease charge are exact logical `MTLBuffer.length` bytes; the
post-creation `MTLResource.allocatedSize` value is retained separately as
direct per-resource observation rather than retrofitted into the selection
capability or pre-allocation quote.

## Evidence

Portable contract checks:

```bash
tools/zig-with-ephemeral-cache.sh build test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

These portable Zig/Python and mutation-injection checks are deterministic
contract tests. They do not emulate a Metal driver or claim hardware behavior.

Native Metal readiness, allocation ownership, fault/reconciliation, and
correctness on a macOS Metal host:

```bash
metal_dir="$(mktemp -d)"
trap 'rm -rf "$metal_dir"' EXIT
tools/zig-with-ephemeral-cache.sh build \
  native-metal-suite-test \
  profile-device-compile \
  -Doptimize=ReleaseSafe -Dmetal=true \
  -Dmetal-output-dir="$metal_dir" -j2
```

That native command discovers the host's real `MTLDevice`, creates and directly
inspects real lease-bound Metal buffers, compiles the actual Metal shaders,
submits command buffers to the device, waits for completion, and compares
output with CPU oracles. The build-isolated fault stage lets a real command
complete physically before applying a separate test-only published-error
overlay; it does not simulate the GPU and does not claim a physical device,
driver, or hardware failure. This is bounded real-device
allocation/correctness/readiness and reconciliation evidence, not a performance
or broad device-support result.

The portable contract also participates in the retained foreign-target compile
profiles. Those builds prove source and ABI portability, not native driver,
device, or operating-system support.

## Claim boundary

This slice establishes a deterministic capability fingerprint and selection
decision. The selection receipt itself does not establish:

- physical allocation or residency;
- device-loss recovery or live migration;
- asynchronous cancellation after dispatch;
- multi-device partitioning or scheduling;
- driver/device support ranges;
- native support on a cross-compiled target; or
- latency, throughput, utilization, memory, power, thermal, or energy results.

The separate [Device Allocation Lease V1](DEVICE_ALLOCATION_LEASE.md) and
[LeaseTree Device Allocation](LEASE_TREE_DEVICE_ALLOCATION.md) contracts now
consume this decision through deterministic fake and real-Metal adapters. The
fake tests prove injected rollback/recovery. The native gate proves real
resource ownership, direct inspection, release, and generation reuse on the
executing host through both the receipt-bound ChildLease and execution-owned
additive LeaseTree paths, plus cancellation cleanup on the LeaseTree path.
This does not turn the selection receipt itself into allocation, residency, or
publication authority: the LeaseTree coordinator obtains a distinct scoped
execution authority before native creation.

That coordinator shares address-stable tree and publication-sequence pointers
with the surrounding execution owner. The owner must externally serialize
coordinator calls with every other mutation of those shared values; the
contract does not make independent owners or unsynchronized threads safe.

The next device-runtime slices bind dispatch and queue lifetime to the
LeaseTree-owned object set, add an explicit device-loss event and quarantine
transition, define deterministic repartition or fallback under a new selection
receipt, add separate residency authority, and bind a transactional stateless
model path that publishes only after native candidate validation.
