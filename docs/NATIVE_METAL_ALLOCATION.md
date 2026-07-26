# Native Metal Allocation Adapter

The native Metal allocation adapter binds the portable
`DeviceAllocationLeaseV1` lifecycle to real direct Shared `MTLBuffer`
resources on macOS. It is a bounded allocation-ownership prototype, not a
residency or performance subsystem.

## What is implemented

For one exact `MetalBackend` context, the adapter:

1. revalidates the selected Metal device fingerprint and registry identity;
2. replays a side-effect-free quote for every canonical allocation;
3. lets `ResourceBank.ChildLease` charge the complete logical resource length
   before the first native allocation;
4. creates real buffers with
   `newBufferWithLength:options:`;
5. validates the resource's device, requested length, storage mode, cache
   mode, and direct per-resource `allocatedSize`;
6. retains only a copyable pointer-free native token in a private
   fixed-capacity slot while the shim registry owns the Objective-C resource;
7. exposes a pointer-free, generation-fenced backend object identity;
8. releases every native object before returning the child charge; and
9. rejects copied leases after release and reuses slots only under newer
   generations.

The current coordinator still uses the `ChildLease` sidecar. LeaseTree-backed
execution ownership is the next device-runtime slice and requires a distinct
tree admission/lease/recovery ABI.

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

In assertion-enabled builds, backend deinitialization asserts that its
Zig-side live weight/allocation counters and the independently maintained shim
registry count are zero. Normal lease release removes the shim registry entry
and its strong reference synchronously. That proves ownership relinquishment
by the adapter; it does not prove when a driver reclaims physical pages.

## Evidence and tests

The portable allocation contract and fake-adapter failure campaign are
deterministic state-machine tests. They do not simulate Metal.

The native allocation hard gate is different. On the executing macOS host it:

- opens the real default `MTLDevice`;
- creates three direct Shared Metal buffers for 1,000, 3,000, and 4,000 logical
  bytes;
- reads `device`, `length`, `allocatedSize`, storage mode, and cache mode from
  each live resource;
- verifies the complete `0 → 8,000 → 0` ChildLease device-byte lifecycle;
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

The allocation-aware inventory helper currently validates the
`matvec_int4_f32_bounded` pipeline and publishes that operation profile. The
allocation gate itself performs no dispatch, but this V1 inventory helper is
not yet a generic allocation-only Metal profile.

## Claim boundary

This slice establishes direct Metal resource creation, per-object inspection,
adapter ownership, logical precharge, release ordering, and generation-fenced
reuse on the host that executes the hard gate. It does not establish:

- physical residency or reclaim completion;
- heap allocation or fragmentation accounting;
- dispatch-to-allocation lifetime pins;
- device-loss inspection or reconciliation;
- asynchronous cleanup;
- LeaseTree execution integration;
- multiple simultaneous leases per adapter;
- multi-device partitioning;
- a supported device/OS range; or
- latency, throughput, utilization, power, temperature, frequency, or energy.

Those claims require separate authorities and retained evidence rather than a
reinterpretation of the V1 logical resource charge.
