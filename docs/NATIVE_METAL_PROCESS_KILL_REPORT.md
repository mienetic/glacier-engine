# Native Metal Process-Kill Recovery Report

W7b-b1 adds a bounded abrupt-worker-death profile to the segmented native
Metal campaign. It preserves the zero-flag W7b-a codec semantics and golden
wires byte for byte, while using a separately sealed schedule for the live
fault run.

The hard gate performs a real POSIX `SIGKILL` on the first persistent worker
after its sixth segment has completed. The killed process still owns its
persistent Metal backend, device, and command-queue objects, while the verified
segment itself has returned logical and native buffers, live commands, pins,
dispatches, and quarantine ownership to zero. The supervisor then publishes
and re-reads the durable prefix before creating a fresh worker and Metal
backend for the remaining six segments.

This is post-segment process-death and fresh-process recovery evidence. It is
not an in-flight GPU-command interruption or physical device-loss test.

## Fixed campaign

The process-kill profile keeps the W7b-a workload geometry:

- 12 segments of 50 paced epochs;
- 600 epochs and 3,000 raw records;
- 1,200 CPU-oracle-checked real Metal commands;
- 600 cancel-before-submit outcomes;
- 600 malformed pre-submit rejections;
- 600 full-slot capacity rejections;
- 2,400 balanced Bank pins;
- at least 60 seconds of scheduled native work; and
- a 180-second whole-run watchdog.

Its process schedule is:

| Segment ordinals | Process generation | Terminal action |
| --- | ---: | --- |
| 0–4 | 1 | Worker remains live |
| 5 | 1 | Exact `SIGKILL` after verified segment |
| 6–10 | 2 | Fresh worker remains live |
| 11 | 2 | Clean final exit |

The clean W7b-a profile remains a separate gate. It still exits generation one
cleanly after ordinal 5.

## Forced-restart contract

The fixed campaign manifest layout is unchanged. A plan flag selects the
forced-restart semantics and therefore enters the plan root and campaign
identity. At ordinal 5 the flag requires:

- scheduled action `forced_phase_end`;
- the forced-OS-process-kill provenance bit;
- `exit_code_bits = U64_MAX`;
- `termination_signal = 9`; and
- a segment challenge derived from that exact action.

The flag is invalid without a nonterminal restart boundary. Unknown flags,
using the forced action in a clean profile, a graceful exit at the forced
boundary, a different signal, or attaching forced provenance to another
segment all fail closed.

Portable Zig and Python tests independently reconstruct these semantics.
Zero-flag clean-restart golden wires and hashes remain unchanged. Those
portable tests model the evidence contract and send no signal or GPU command.
A separate fake-worker protocol gate sends a real host `SIGKILL` to a bounded
Python worker but runs no Metal command. Only the hard native gate combines the
real signal with the real Metal workload.

## Live kill boundary

The native supervisor accepts a forced entry only after this order completes:

1. receive exactly one bounded worker frame;
2. verify the portable report and native Metal profile;
3. prove cadence, CPU-oracle correctness, and terminal logical closure;
4. synchronize the content-addressed segment object;
5. confirm that the intended worker is still alive;
6. send `SIGKILL` to that worker PID only;
7. reap an exact return status of `-9`;
8. drain its pipes and reject trailing output;
9. rehash the worker and Metal library;
10. publish the generation-six manifest and selector; and
11. re-read that active prefix before starting generation two.

The planned kill never targets the supervisor process group. Natural exit,
`SIGTERM`, early worker death, timeout, watchdog termination, or any other wait
status is a failed campaign and cannot be encoded as the scheduled kill.

After re-reading generation six, the supervisor reloads predecessor roots and
cumulative duration from the retained entry. Generation two must use a new
process-scoped RSS source while preserving the machine, backend, device,
placement, build, component, host-source, and host-clock identities.

## Store and watchdog verification

Every hard invocation now closes the live writer and starts a separate offline
verifier process before an ephemeral store is deleted or a retained store is
reported successful. The offline verifier:

- reconstructs every manifest prefix and active selector;
- verifies every inner native report again;
- checks the forced action, provenance, exit, and signal matrix;
- checks exact component and environment bindings;
- rejects missing, additional, corrupted, symlinked, or substituted objects;
  and
- confirms that the active selector did not change during the audit.

Offline verification proves the integrity of the retained signal claim. Only
the live gate observes the operating-system wait status. The internal hard-gate
audit requires the expected clean or forced profile and an exact complete
12-segment prefix; the public audit command can still report a canonical
partial prefix without calling it a completed campaign.

The whole-run watchdog owns a private process group. On timeout it escalates to
`SIGKILL` for the group even when the supervisor leader has already exited, so
a descendant that ignores `SIGTERM` cannot survive the gate. Watchdog
termination is always failure and is distinct from the one scheduled worker
kill.

## Running the gates

Run the portable campaign codec/model and pure supervisor tests:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-workload-campaign-test \
  native-metal-soak-report-pure-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the focused native process-kill campaign:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Retain the verified store:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-process-kill-output-dir=PATH
```

Audit a retained store without running Metal work:

```sh
python3 -m bench.native_metal_soak_report \
  --worker path/to/glacier-native-metal-soak-worker \
  --metallib path/to/shaders.metallib \
  --output-dir PATH \
  --forced-process-restart \
  --verify-store
```

## Claim boundary

A passing native gate proves one real macOS worker process was forcibly killed
at the declared quiescent boundary, the exact signal status was observed, the
durable verified prefix remained usable, and a fresh Metal process completed
the remaining fixed campaign with exact logical closure.

It does not prove:

- interruption or recovery of an in-flight command;
- preservation of process-local state from the killed worker;
- supervisor-crash resume or append authority;
- complete driver reclamation or GPU leak freedom;
- physical device removal, driver failure, or power loss;
- GPU residency, utilization, power, temperature, frequency, or energy;
- Windows termination semantics or native multi-OS replication; or
- throughput, latency, or production-model performance.

Storage exhaustion, crash points inside store publication, cancellation storms,
adapter loss, physical-device faults, and replay-safe prepared-text output
sinks remain later W7b-b work.
