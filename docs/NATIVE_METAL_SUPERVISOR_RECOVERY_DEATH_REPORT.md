# Native Metal Supervisor and Recovery-Process Death Report

W7b-b5 adds two bounded control-plane process-death boundaries to the
production-native segmented Metal campaign. One controller first kills the
supervisor after generation six is durable and its worker has exited cleanly.
A fresh auditor accepts that exact prefix. A recovery process then resumes at
ordinal six, prepares generation twelve while generation eleven remains
active, and is killed before the selector replacement. A second recovery
process may perform only the exact `11 -> 12` roll-forward before a final fresh
audit.

The hard gate executes the complete 12-segment workload: 1,200 real Metal
commands, each checked against its CPU oracle. It also performs two real
PID-only `SIGKILL` operations, real process reaping, advisory-lock contention,
regular-file writes, hard links, same-filesystem replacement, and file and
directory `fsync` calls.

The ready barriers, kill timing, generation-twelve publication pause, and
resume/finalizer grants are controlled protocol inputs. This campaign does not
claim active-kernel interruption, victim-output recovery, a physical
storage/power/device/driver fault, GPU residency, performance, or leak freedom.

## Fixed campaign and process schedule

The workload geometry remains the fixed W7b segmented profile:

- 12 segments of 50 paced epochs;
- 600 epochs and 3,000 raw records;
- 1,200 CPU-oracle-checked real Metal commands;
- 600 cancel-before-submit outcomes;
- 600 malformed pre-submit rejections;
- 600 full-slot capacity rejections;
- 2,400 balanced Bank pins; and
- 15,000 ordered host event points.

The process schedule is:

| Phase | Required boundary |
| --- | --- |
| Supervisor `S1` and worker `W1` | `W1` completes ordinals `0..5`, exits cleanly, and is reaped. `S1` synchronizes generation six, holds the exclusive store lock, and publishes a private pre-ready handoff. The controller validates that handoff and proves lock contention before returning an exact challenge-bound acknowledgement; only then may `S1` emit the public supervisor-ready frame with `lock_contended=1`. |
| First controller kill | The controller validates the acknowledged ready frame, sends `SIGKILL` to the exact `S1` PID only, and requires status `-9`, exact EOF, and empty standard error. |
| Fresh auditor `A1` | After the first kill, the controller derives the resume grant and supplies it to a new shared-lock process. `A1` binds that grant while reconstructing exactly generation six; its audit is not inherited from the dead supervisor, and the grant remains withheld from `R1` until this audit passes. |
| Recovery `R1` and worker `W2` | Under the resume grant, `W2` starts at ordinal six and completes ordinals `6..11`. `R1` publishes through generation eleven, then synchronizes generation-twelve immutable objects and the exact 192-byte selector temporary file while leaving generation eleven active. `W2` exits cleanly and is reaped; `R1` publishes a private pre-ready handoff while retaining the exclusive lock. |
| Second controller kill | The controller validates the prepared handoff, proves contention, and returns a challenge-bound acknowledgement before `R1` emits the public recovery-ready frame. The controller validates that acknowledged frame, sends PID-only `SIGKILL`, and requires status `-9`, exact EOF, and empty standard error. |
| Finalizer `R2` | Only after the second kill, a fresh process receives the derived finalizer grant and may perform only the prepared selector transition from generation eleven to generation twelve, followed by the required root-directory synchronization. |
| Fresh auditor `A2` | A final shared-lock process reconstructs the complete generation-twelve store and emits the final audit used by both report verifiers. |

No killed process owns an active worker or an in-flight Metal command at its
declared ready boundary. Both worker processes have already exited cleanly and
been reaped before the corresponding control-plane kill.

## Authority and publication boundaries

The controller derives a supervisor challenge from the campaign, schedule, and
complete component set. Component identities, machine, backend, device, and
placement identities are bound into the fixed report.

The resume grant is derived only after the first ready frame, first kill
receipt, and generation-six selector/store roots exist. The dead supervisor
never receives that future grant. The controller supplies the grant to the
fresh auditor so its generation-six frame can bind it, but withholds it from
the first recovery process until that audit passes. It then authorizes only the
fixed continuation from ordinal six. The recovery challenge is derived from
that resume grant plus the fresh audit root and is carried by the
recovery-ready frame, so a stale or substituted generation-six audit cannot be
spliced into the retained chain.

The finalizer grant is created only after the recovery-ready frame and second
kill receipt exist. The first recovery process never receives that future
grant. It authorizes only the already prepared `11 -> 12` selector transition;
it grants no arbitrary append, repair, or rewrite authority.

Generation twelve is considered prepared only when its immutable objects and
canonical 192-byte selector temporary file have been synchronized and the
active selector still names generation eleven. Unknown residue, extra files,
symlinks, foreign hard links, selector substitution, changed inode or namespace
identity, unexpected generation shape, or lock-rule violation fails closed.

## Exact 3,520-byte report

The public report has eight fixed regions:

| Region | Bytes | Purpose |
| --- | ---: | --- |
| Header | 1,024 | Campaign geometry, component/machine identities, grants, selector/store roots, and the roots of every following region |
| Supervisor ready | 512 | Exact generation-six synchronized state, clean worker reap, held-lock identity, and supervisor challenge |
| Supervisor kill | 320 | Exact target PID, signal, wait status, EOF/error observations, and the acknowledged-ready root that carries the prior contention observation |
| Generation-six audit | 384 | Fresh shared-lock reconstruction of the exact active prefix and store shape |
| Recovery ready | 512 | Exact generation-eleven active state plus synchronized prepared-generation-twelve state, clean second-worker reap, fresh-audit challenge, and controller contention acknowledgement |
| Recovery kill | 320 | Second exact PID-only signal, wait status, EOF/error, and the acknowledged recovery-ready root |
| Final audit | 384 | Exact `11 -> 12` roll-forward and fresh complete-store reconstruction |
| Footer | 64 | Canonical body root and complete report root |

The header ABI is `0x4757535200000001`. The fixed encoded size, region sizes,
campaign counts, process count, two-signal count, nonzero identities, derived
grants, per-region roots, body root, and report root all fail closed.

The standard-library Python implementation constructs and verifies the report.
The allocation-free Zig codec independently decodes and verifies the same
3,520 bytes. Portable tests cover canonical round trips, cross-language parity,
truncation, extension, mutation, region substitution, stale grants, incorrect
generation transitions, component substitution, and malformed roots without
opening a GPU or claiming a process kill. A portable pass authenticates the
wire's internal claims and joins only; it does not independently establish
their OS, filesystem, GPU, CPU, or build provenance.

## What is real and what is controlled

| Evidence | Provenance |
| --- | --- |
| Twelve segments and 1,200 CPU-oracle-checked Metal commands | Real production-native Metal execution |
| Two worker processes and their clean reap boundaries | Real host processes and wait observations |
| Two control-plane PIDs, PID-only `SIGKILL`, and exact `-9` waits | Real host process and operating-system behavior |
| Advisory locks, contention probes, file writes, hard links, replacements, and `fsync` | Real host filesystem operations |
| Ready barriers and the selected kill instants | Controlled campaign schedule |
| Pause after the prepared generation-twelve selector temporary is synchronized | Controlled publication boundary |
| Resume and finalizer grants | Controlled, hash-bound least-authority protocol inputs |
| Python fixtures and portable Zig codec tests | Deterministic model evidence only |

The campaign intentionally keeps controlled timing separate from physical
fault provenance. A real process kill at a controlled publication point is not
a power cut, media failure, driver reset, device removal, or proof about an
actively executing kernel.

## Running the gates

Run the portable Python/Zig codec and verifier:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-supervisor-recovery-death-report-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile the portable artifacts for the retained foreign targets without
executing them:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-supervisor-recovery-death-report-compile \
  native-supervisor-recovery-death-report-cross-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Run the two-layer host conformance gate. One deterministic model covers the
staged generation-six/resume/prepared/final store APIs and grant-use receipts;
a separate fixture covers real processes, advisory-lock contention,
acknowledgements, PID-only signals, waits, and selector replacement. These
layers intentionally do not claim one composed native campaign or GPU work.
The store model accepts caller-supplied opaque nonzero grants and verifies
their exact use bindings, while the process fixture uses static test
challenges. Only the native hard gate composes the controller-derived grants,
fresh audits, two deaths, durable store, and Metal workers end to end:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-supervisor-recovery-death-host-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile every native artifact used by the focused gate without launching the
campaign:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-compile \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the focused hard gate:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Retain its private verified directory, containing the outer report and
campaign store, only after both verification layers pass:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-supervisor-recovery-death-output-dir=PATH
```

`PATH` must not already exist. Successful retention publishes exactly the
private `report.bin` plus `campaign/` store after the final Python and Zig
verification; a failed or incomplete run does not replace an existing result.

Run all native Metal gates in their fixed serialized order:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j1
```

Affected-path verification first completes
`native-metal-suite-compile`. That single compile frontier closes over every
suite artifact and static check before the first suite device process starts.
The subsequent serialized hardware phase reuses the same build graph and
private caches, so shared artifacts are compiled once instead of being rebuilt
by independent cold invocations.

## Claim boundary

A passing hard gate establishes the following bounded evidence for the exact
invoking native macOS host, campaign, build, Metal program, and store:

- generation six survived real supervisor death and was accepted by a fresh
  shared-lock auditor;
- an authorized fresh recovery resumed at exact ordinal six;
- generation twelve was durably prepared while generation eleven remained
  active;
- a second fresh recovery completed only the exact `11 -> 12` roll-forward
  after real recovery-process death;
- a fresh final auditor accepted the complete store;
- both workers had exited cleanly before their control-plane process was
  killed; and
- all 1,200 real Metal commands passed CPU oracles and the complete report
  passed independent Python and Zig verification.

It does not prove:

- interruption, preemption, or recovery of an actively executing GPU kernel;
- recovery of output or process-local state from either killed process;
- physical storage failure, quota exhaustion, power loss, reboot, or torn
  media writes;
- physical device removal, adapter loss, driver failure, reset, or migration;
- native replication on another operating system, filesystem, or accelerator;
- GPU residency, utilization, physical queue occupancy, power, thermal,
  frequency, or energy;
- throughput, latency, scalability, or production-model performance; or
- indefinite resource or driver leak freedom.

Active-kernel work, the broader supervisor/recovery interruption matrix,
adapter-loss and physical storage/device/driver/power campaigns, and native
multi-platform replication remain open.
