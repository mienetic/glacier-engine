# Native Metal In-Flight Process-Kill Report

W7b-b4 adds a bounded native macOS Metal process-death boundary while one real
registered command remains nonterminal. A build-isolated fault shim inserts a
controlled `MTLSharedEvent` barrier after one real INT4 compute operation. The
victim publishes a canonical ready frame only after the event has signaled
value `1` and the same command is waiting for value `2`.

The controller validates that frame, sends real PID-only `SIGKILL`, requires
wait status `-9` and exact end-of-file, then launches a distinct
production-linked W6 process. That fresh control process must complete the
fixed 20-command Metal workload against CPU oracles.

This is real command-registration, OS-process-kill, and fresh-process control
evidence around a controlled event barrier. It is not evidence that an active
GPU kernel was interrupted or preempted.

## Fixed victim boundary

The victim uses the private fault-shim build, not the production Metal shim.
Its one-shot command sequence is:

1. allocate and register the four real native buffers required by the fixed
   INT4 matrix-vector operation;
2. encode one real INT4 compute operation;
3. encode `MTLSharedEvent` signal value `1` after that compute operation;
4. encode a wait for value `2`, which the campaign never signals;
5. commit the command and wait until the shared event reports value `1`;
6. inspect the still-registered command and publish one ready frame; and
7. remain blocked until the controller terminates the process.

The event barrier makes the boundary deterministic enough to inspect, but it
is a controlled synthetic seam. Reaching signal value `1` does not show that a
kernel is still executing when the process dies; the command may be waiting
between encoded operations.

## Ready frame

The victim emits one exact 512-byte `ReadyFrameV1` with ABI
`0x4757494b00000001`. The controller accepts it only when all fixed facts hold:

- the PID is positive and names the victim the controller launched;
- barrier and command generations are positive;
- submission disposition is submitted;
- command-buffer status is committed or scheduled, and therefore nonterminal;
- commit was invoked and completion remains unobserved;
- shared-event value, encoded signal value, and encoded wait value are exactly
  `1`, `1`, and `2`;
- four native buffers, one native command, and four active allocation
  references remain live; and
- the challenge, victim, Metal library, build, machine, backend, device,
  placement, ticket, pin, submission, and canonical frame roots are nonzero
  and internally consistent.

The ready frame proves the declared pre-kill state observed inside the victim.
By itself it proves neither that a signal was sent nor that the process died,
and it carries no authority to recover output or process-local state.

## Controller and fresh control

Only after the complete ready frame verifies does the controller:

1. confirm that the victim is still the exact child process bound by the
   frame;
2. send `SIGKILL` to that PID only, never to a process group;
3. require the operating-system wait result to be exactly `-9`;
4. require exact end-of-file with no additional victim frame; and
5. start a distinct production-linked W6 Metal process.

The fresh process uses the normal production shim and must emit a valid W6
native workload report for 20 real INT4 commands. Every command must pass its
CPU oracle, and the existing W6 verifier must accept correctness, component
identity, timing, and terminal ownership facts.

That final process is an independent post-kill control. It does not resume the
victim, recover its output, inherit its resource authorities, or prove that the
driver reclaimed every resource previously owned by the killed process.

## What is real and what is controlled

| Evidence | Provenance |
| --- | --- |
| Four Metal buffers and one registered INT4 command in the victim | Real native Metal resources and command |
| `MTLSharedEvent` signal `1` followed by wait `2` | Controlled synthetic barrier exported only by the build-isolated fault shim |
| Victim PID, `SIGKILL`, wait status `-9`, and exact EOF | Real host process and operating-system observations |
| Fresh W6 process and its 20 CPU-oracle-checked commands | Real production-linked Metal control |
| Ready-frame codec, mutations, and controller protocol fixtures | Deterministic model evidence; no GPU or signal claim unless the hard gate runs |

Production-linked artifacts do not export the fault-shim barrier authority.
The hard gate deliberately combines the controlled barrier with real Metal and
process behavior without relabelling the barrier as a physical device fault.

## Verification boundary

The hard verifier binds one fresh invocation to the exact victim, recovery
runner, both Metal libraries, challenge, machine, backend, device, placement,
dispatch identities, ready frame, kill receipt, and independently verified W6
wire. It rejects an early or natural victim exit, a different PID, a signal
other than `SIGKILL`, a wait result other than `-9`, trailing victim output,
terminal or completion-observed command state, the wrong event values, changed
live counts, component substitution, malformed roots, and any invalid fresh
W6 control.

An optional output path retains the verified report only after the ready
frame, real kill receipt, and fresh W6 report all pass. The canonical outer
report is exactly 19,468 bytes: a 640-byte header, the 512-byte ready frame, a
256-byte kill receipt, the complete 17,996-byte W6 wire, and a 64-byte footer.

## Claim boundary

A passing hard gate proves that, on the invoking native macOS host:

- a fault-linked victim registered and committed one real Metal INT4 command;
- the controlled event reached `1` while the command remained nonterminal,
  completion-unobserved, and associated with four live buffers, one live
  command, and four active allocation references;
- the controller validated that state before sending real PID-only `SIGKILL`;
- the victim reaped with exact status `-9` and produced exact EOF; and
- a distinct production-linked process subsequently completed 20 real Metal
  commands with CPU-oracle correctness.

It does not prove:

- interruption or preemption of an actively executing GPU kernel;
- recovery of the victim's output;
- preservation or restoration of process-local state;
- physical device loss, driver failure, reset, or migration;
- complete driver or native-resource reclamation after process death;
- latency, throughput, scalability, or production-model performance;
- GPU residency, utilization, queue occupancy, power, temperature, frequency,
  or energy; or
- native behavior on another operating system or GPU backend.

Supervisor death, recovery-process interruption, active-kernel fault
campaigns, adapter loss, and physical storage, device, driver, and power faults
remain separate W7b work.

## Run the gates

Run the ready-frame and controller model tests without making a native GPU or
process-kill claim:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-pure-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile the native victim without running it:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-compile \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the focused hard gate:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Retain the report after complete verification:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-inflight-process-kill-report-output=PATH
```

The underlying controller interface is:

```sh
python3 -m bench.native_metal_inflight_process_kill_report \
  --victim path/to/glacier-native-metal-inflight-process-kill-worker \
  --victim-metallib path/to/victim-shaders.metallib \
  --recovery-runner path/to/glacier-native-metal-workload-report \
  --recovery-metallib path/to/recovery-shaders.metallib \
  --output PATH
```

Audit a retained report without rerunning the victim or Metal control:

```sh
python3 -m bench.native_metal_inflight_process_kill_report \
  --verify PATH
```
