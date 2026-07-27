# Native Metal controlled-disruption report

W7a adds a fixed, independently checked recovery campaign around the
production macOS Metal allocation and dispatch path. It is a bounded
controlled-disruption gate, not a long-duration soak, a performance benchmark,
or a physical device-failure test.

## What runs

One invocation owns a persistent eight-buffer Metal allocation and executes 50
identical epochs. The first two epochs are warmup; the remaining 48 form the
measured cohort. Every epoch retains five raw Native Workload Report V1
records, in this order:

| Record | Adapter action | Native command |
| --- | --- | --- |
| 1 | admit, cancel before submit, and settle | none |
| 2 | admit, reject one malformed host length, and settle | none |
| 3 | submit and complete logical lane 0 | one real Metal command |
| 4 | submit and complete logical lane 1 | one real Metal command |
| 5 | attempt a distinct request while both bounded slots are live | none; exact capacity rejection |

Both real commands are submitted before the capacity probe. The probe must
leave the public allocation snapshot, exact active tickets, request/ticket
generation cursors, Resource Bank, coordinator, buffer counts, command count,
and completed-dispatch count unchanged. Both commands must then complete
against their CPU oracles, and lane 1 deliberately settles before lane 0. The
next epoch cannot begin until both lanes have settled.

The complete report therefore retains:

- 250 raw records;
- 100 completed production Metal commands;
- 50 cancellations before submission;
- 50 malformed pre-submit rejections;
- 50 full-slot capacity rejections; and
- 200 matched Resource Bank pin acquisitions and completions.

## Evidence boundary

The completed records are production-native observations from the invoking
macOS Metal device. They include CPU-oracle correctness, same-command Metal
GPU timestamps, device and placement identity, sampled
`currentAllocatedSize`, generation-fenced logical slot reuse, and terminal
ownership facts.

The cancellation, malformed-input, and capacity branches are controlled
logical disruptions through production adapter APIs. They construct or submit
no Metal command. They prove deterministic rejection, settlement, and reuse;
they do not represent a removed GPU, a driver crash, a power interruption, or
physical memory loss.

Two live adapter slots are logical ownership evidence. They do not establish
simultaneous GPU execution, hardware queue depth, occupancy, or physical
parallelism. `currentAllocatedSize` is allocation context, not residency.
Utilization, residency, power, energy, temperature, and effective frequency
remain unavailable until a named native observer reports them directly.

For admitted cancellation and malformed rejection, the producer stores the
actual request, pin, terminal, and completion roots. The malformed record also
retains its opaque adapter rejection-receipt root. The independent verifier
recomputes a domain-separated commitment over those roots, the declared
action, outcome, flow, epoch, and exact detail tag, so roots cannot be swapped
between the two actions or replaced with profile-derived capacity roots. The
producer validates that the opaque receipt is specifically
`invalid_host_lengths`; the verifier binds that receipt to the record but does
not reconstruct the adapter-private receipt fields. The report is
self-asserted native evidence, not remote attestation.

## Recovery and growth checks

Every epoch must return to the same reusable boundary:

- one persistent 5,544-byte logical device lease and eight native buffers;
- zero active dispatch pins;
- zero coordinator dispatches;
- zero native commands;
- unchanged accepting device lifecycle and placement identity; and
- no adapter quarantine or unresolved compatibility submission.

The final release additionally requires zero Bank reservations, lease nodes,
pins, adapter objects, native commands, and native buffers. The report wire is
sealed only after those facts hold. A failure after native submission remains
process-scoped and publishes no partial wire.

This finite campaign proves bounded repeated recovery for its declared
schedule. It does not complete long-duration soak coverage. A later W7 slice
must add duration-bounded segmented reports, process restart, storage
pressure, cancellation storms, and physical removable-device campaigns
without relabelling injected faults as hardware observations.

## Run the hard gate

Run the campaign only on a native macOS target with Metal enabled:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-disruption-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Add
`-Dnative-metal-disruption-report-output=bench/results/<capture>.bin` to retain
the raw wire after both the portable report verifier and the exact W7a profile
verifier accept it.

The verifier supplies a fresh 256-bit challenge and binds the scenario to the
exact runner and external Metal library hashes observed before and after the
process. This prevents stale-wire replay within the live gate; it is not remote
attestation or authentication of the person operating the machine.
