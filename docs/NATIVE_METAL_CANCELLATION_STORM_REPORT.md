# Native Metal Cancellation-Storm Report

W7b-b3 adds a fixed concurrent-caller campaign around cancellation admission,
capacity rejection, settlement, and bounded adapter reuse on the production
macOS Metal path. Paired real host threads enter every cancellation wave, while
separate control records prove that the same adapter still completes correct
native Metal work.

This is cancellation-before-submit and release-barrier evidence. It is
not GPU-kernel cancellation, command preemption, a performance benchmark, or a
physical-device fault test.

## Fixed campaign

One invocation runs eight blocks of eight waves. Block 0 is warmup; blocks 1–7
form the measured cohort. Every wave retains three records in canonical order:

| Record | Adapter action | Native command |
| --- | --- | --- |
| 1 | Admit and cancel logical lane 0 before submit | none |
| 2 | Admit and cancel logical lane 1 before submit | none |
| 3 | Probe the fixed two-slot capacity boundary | none |

The two cancellation callers are real host threads. Both reach one ready
barrier before the controller performs one shared release store. This proves
the ready-before-release boundary. It does not prove simultaneous scheduling
or execution, that their critical sections overlap, that a particular lock
interleaving occurred, or that the GPU saw parallel work.

Each block ends with one completed control record for lane 0 and one for lane
1. Those 16 controls create and complete real Metal commands and must pass
their CPU oracles. The complete campaign therefore retains:

- 64 waves across eight blocks;
- 128 cancel-before-submit records;
- 64 capacity-probe records;
- 16 CPU-oracle-checked real Metal control commands;
- 208 records total; and
- 144 matched Resource Bank pin acquisitions and completions.

The warmup block contains 26 records. The measured seven-block cohort contains
182 records: 112 cancellations, 56 capacity probes, 14 completed controls, and
126 admitted pins. Measured records remain balanced at 91 per logical flow,
including seven completed controls per flow.

The profile fixes maximum in-flight work, queue count, and flow count at two.
It also retains the declared 5,544-byte persistent logical allocation and
2,368 logical work units per record.

## Wire and verification

The producer ABI is `0x4757434D00000001`. The campaign emits the existing
Native Workload Report V1 wire under profile name
`native-metal-cancellation-storm-report-v1`. Its exact length is 163,132 bytes:
2,556 bytes of fixed report framing plus 208 records of 772 bytes each.

The portable report verifier runs first. The exact native profile verifier
then requires:

- the fixed block, wave, record-role, outcome, and warmup/measured schedule;
- the invocation challenge and exact profile, build, source, machine, backend,
  device, and placement identities;
- exact runner and external Metal-library hashes before and after execution;
- the per-wave event partial order and challenge-selected settlement order;
- zero submit, ticket, dispatch, output, and oracle roots for every cancellation
  and capacity record;
- CPU-oracle correctness and native timing only for the 16 controls;
- unique generation roots with the fixed two-slot reuse rules;
- exact measured summaries and balanced flow counts;
- 144 acquisitions matched by 144 completions; and
- terminal zero Bank, pin, dispatch, command, buffer, quarantine, and unresolved
  submission ownership.

The verifier accepts exact stdout only, rejects stderr, and retains the report
only after both verification layers pass. The challenge and component hashes
bind one live invocation to one runner/library pair; they are integrity and
anti-stale-replay evidence, not remote attestation.

## What is real

The hard native gate uses:

- the production allocation and dispatch adapter;
- real paired host threads and a real release barrier;
- real cancellation-before-submit and capacity calls against the bounded
  adapter;
- real Metal device, command, and buffer execution for the 16 controls; and
- CPU-oracle validation before completed-control publication.

Cancellation and capacity records intentionally submit zero GPU commands.
Their value is the exact admission, cancellation, settlement, capacity, reuse,
and ownership evidence around the real adapter.

## Claim boundary

A passing hard gate proves the fixed finite schedule on the invoking native
macOS Metal host: two cancellation callers reach the ready barrier before one
shared release store in every wave, all cancellation and capacity attempts
remain native-command-free, later controls complete correctly through the
production adapter, logical flows stay balanced, and all retained ownership
closes exactly.

It does not prove:

- cancellation or preemption of a submitted or executing GPU command;
- overlap inside adapter locks or simultaneous GPU execution;
- physical hardware queue occupancy, parallelism, or scheduling order;
- latency, throughput, scalability, starvation freedom, or production-model
  performance;
- GPU utilization, residency, temperature, frequency, power, or energy;
- device removal, driver failure, reset, migration, or power loss; or
- native behavior on a cross-compiled or non-macOS target.

The separate
[Native Metal In-Flight Process-Kill Report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md)
covers one controlled event-blocked command and real victim-process kill.
Supervisor death, recovery-process interruption, active-kernel and adapter
faults, physical storage/power disruption, and physical device-fault schedules
remain separate W7b work.

## Run the gates

Run the pure Python model and mutation checks without opening a Metal device:

```sh
python3 -m unittest \
  bench.tests.test_native_metal_cancellation_storm_report
```

Run the hard campaign only on a native macOS target with Metal enabled:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-cancellation-storm-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Retain the independently verified raw wire:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-cancellation-storm-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-cancellation-storm-report-output=PATH
```

Compile the native producer without running the campaign:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-cancellation-storm-report-compile \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

The compile step is source/build evidence only. It executes no GPU command.
The producer is a native macOS Metal consumer, so this milestone adds no
foreign-target execution or GPU-support claim.
