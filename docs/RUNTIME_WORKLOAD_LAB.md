# Runtime Workload Lab

The Runtime Workload Lab makes workload, latency, resource, and resilience
evidence a versioned runtime surface instead of a collection of ad-hoc
benchmark commands.

It separates four kinds of evidence:

1. deterministic scheduling and accounting conformance;
2. native open-loop and closed-loop workload measurement;
3. CPU, GPU/accelerator, machine-state, and physical-resource observation; and
4. bounded soak and disruption recovery.

The deterministic open-loop, generated deterministic open-loop,
scheduler-coupled media, finite-source deterministic closed-loop, mixed
typed-perception, first process-local typed tool, and portable ActionOutbox
record/recovery layers are integrated. W4b-c also integrates a
descriptor-relative POSIX durable store and separates deterministic
write/repair fault matrices from a real host process-death campaign.
W4b-d now composes that store with pointer-free adapter values, a durable
dispatch/status driver, and a bounded same-process fake authority with an
opaque synthetic credential. W5a now adds a portable native-observation
contract, a family-neutral fail-closed runner, a download-free retained
three-profile/six-item workload, and a shared bounded macOS host observer.
W6a adds the portable, allocation-free raw-record/summary/closure report wire,
a deterministic synthetic reference runner, and independent Python
recomputation. W6b connects that wire to a fixed production-native macOS Metal
campaign with twenty real GPU dispatches, CPU-oracle correctness, exact
two-slot logical ownership, same-command device timing, sampled allocated-size
context, optional post-verification artifact retention, and terminal zero
ownership. W7a reuses the unchanged wire for 50 fixed controlled-disruption
epochs around 100 real Metal commands, retaining cancellation, malformed
pre-submit rejection, full-slot rejection, same-epoch recovery, bounded
ownership, and terminal closure without treating injected conditions as
physical device faults. W7b-a adds a fixed segmented native Metal soak: 12
paced segments cross one clean six-segment process restart while retaining a
content-addressed checkpoint after every segment and bounding observed RSS and
Metal allocation context within each process generation. W7b-b3 adds 64
paired-thread cancellation waves around the same bounded production adapter:
128 cancel-before-submit outcomes and 64 capacity probes submit no GPU command,
while 16 real Metal controls preserve CPU-oracle correctness and the complete
208-record campaign closes 144/144 pins. W7b-b4 adds one controlled
event-blocked in-flight process kill: a fault-linked victim reports one real
registered command and four live buffers before real PID-only `SIGKILL`, then
a distinct production-linked W6 process completes 20 real Metal commands.
W7b-b5 adds exact generation-six supervisor death and
prepared-generation-twelve recovery-process death to the complete
12-segment/1,200-command production campaign. Both workers exit cleanly before
their controller processes receive real PID-only `SIGKILL`; fresh processes
audit generation six, perform only the authorized `11 -> 12` roll-forward, and
audit the final store. The exact 3,520-byte outer result is independently
verified in Python and Zig.
Provider, stateful,
streaming, batched, preemptible, device-backed, live-service, and OS-isolated
real-credential profiles, direct physical CPU/device adapters, retained
multi-machine load matrices, broader disruption and physical-fault campaigns,
and native platform replication remain staged work.
A logical driver step is never reported as a millisecond, and a logical
resource claim is never reported as RSS, device residency, energy, or
temperature.

## Why this belongs in the runtime

A runtime can be correct for one request and still fail under pressure through
starvation, deadline drift, double admission, partial publication, leaked
ownership, or unbounded memory growth. The lab exercises those properties
through the same admission, scheduler, resource, cancellation, publication,
and recovery boundaries used by normal execution.

The lab is not part of the latency-sensitive execution path. Scenario
generation, native observers, report encoding, and verification remain
host-side tooling. Workload adapters enter the runtime only through bounded,
least-authority interfaces.

## Evidence levels

| Level | Question answered | Time and resource source |
| --- | --- | --- |
| Deterministic conformance | Does the same logical schedule preserve ordering, fairness, accounting, and ownership? | Logical steps and exact runtime ledgers |
| Native workload | What happened on this captured CPU-only or CPU-plus-accelerator machine, build, backend, placement, and workload? | Monotonic clocks, backend events, and named platform observers |
| Replicated campaign | Does the result reproduce across the declared machine and OS matrix? | Independently retained native runs |
| Soak and disruption | Does the runtime recover without growth, duplicate publication, or leaked ownership? | Native observations plus a fixed fault schedule |

Higher levels do not replace lower ones. A fast native run with a failed
correctness gate is invalid, while deterministic replay alone makes no
wall-clock performance claim.

## Workload modes

The modes remain separately versioned because they answer different questions.

- **Deterministic open-loop** replays declared arrivals at logical driver
  steps. It is the portable conformance mode.
- **Generated deterministic open-loop** creates bounded valid scenarios from a
  fixed seed and can retain exact-signature synthetic or regression shrink
  fixtures. The first retained fixture is synthetic. This mode still uses
  logical time.
- **Deterministic closed-loop** is a separately versioned finite-source
  conformance mode. Terminal outcomes create FIFO successor credits admitted
  at the next logical step toward a declared in-flight target. It still uses
  logical time and creates no native concurrency.
- **Native open-loop** schedules arrivals against a monotonic clock at a
  declared rate. It exposes queueing and overload behavior.
- **Native closed-loop** maintains a declared in-flight population and submits
  new work after terminal outcomes. It measures concurrency-limited service.
- **Soak and disruption** adds a bounded duration and fixed fault schedule.

Results from different modes are not merged into one headline number.

## Roadmap

- [x] **W0 — Deterministic open-loop conformance.** One bounded mixed
  image/audio/video scenario drives the real scheduler, resource bank, and
  verifier through capacity and resource rejection, weighted fairness,
  deadline completion, timeout, cancellation, logical p50/p95/p99 summaries,
  exact high-water accounting, full replay, and zero-orphan close.
- [x] **W1 — Scheduler-coupled bounded media execution.** Completed image,
  audio, and video work adopts the scheduler-owned receipt, executes only on
  the final service quantum, publishes atomically, and closes without double
  admission.
- [x] **W2 — Generated scenario corpus.** A versioned, coordinate-addressed SHA-256
  generator derives 32 bounded scenarios from four retained seeds and eight
  scenario classes. Zig and an independent Python implementation reproduce the
  same cases through unchanged W0 replay and W1 media execution. A synthetic
  exact-signature fixture proves deterministic local-minimum shrinking without
  changing either earlier evidence ABI or its reference goldens.
- [x] **W3 — Deterministic closed-loop contract.** A separately versioned,
  caller-storage-backed finite-source controller executes
  `admit_due → apply_actions → service_retire → seal_step`; terminal-trace
  order drives FIFO next-step successors under a declared in-flight target.
  Canonical plan/result wires, lineage, direct Zig/Python replay, mutation
  rejection, preserved earlier goldens, and final zero ownership are retained.
- [x] **W4a — Mixed typed-perception adapters.** A separate canonical plan
  drives retained exact-integer vision, audio-window, and temporal-video
  profiles through a family-neutral lifecycle driver. Five admitted requests
  share their exact scheduler receipts with typed execution; one rejected
  request receives no adapter/cache authority; completion, cancellation, and
  timeout publish or scrub exactly; concrete evidence and a fresh logical
  replay end with zero model/cache ownership. See
  [Typed Workload Conformance](TYPED_WORKLOAD_CONFORMANCE.md).
- [ ] **W4b — Broader typed workloads.** The first sub-slice is complete: one
  process-local typed tool transaction separates proposal and policy, commits
  execute/reuse/deny/conflict delivery with the exact scheduler service event
  only after a scheduler-locked precommit accepts retained tool state, and
  closes cancellation, timeout, rejection, and ownership to zero. Provider,
  stateful, streaming, batched, preemptible, and device-backed profiles remain.
  W4b-b adds a portable ActionOutbox record campaign: unresolved dispatch
  intent remains uncertain, only a `reconciled_not_applied` semantic record
  permits retry, and compensation is a separate authorized child. A future
  adapter must validate reconciliation evidence. W4b-c adds the canonical
  clean committed `320 + 752n` descriptor-relative POSIX stream with advisory
  locking,
  no-follow/identity/private-mode fences, semantic preflight, ordered
  body/footer sync, exact snapshot/lease/repair roots, explicit repair, and
  mandatory fresh reacquisition. Zig and Python cover 40 append phases, 754
  section-prefix cases, 751 incomplete tails, and 8 repair-fault outcomes; 49
  host
  `SIGKILL` deaths cover 3 initialization, 40 append, and 6 repair boundaries.
  W4b-d adds pointer-free descriptor/request/evidence contracts, driver-only
  intent-before-callback ordering, and a fixed-storage fake authority with an
  opaque synthetic credential. Dispatch protects one future reconciliation
  slot per existing uncertain action and requires three additional journal
  records; status runs only when free slots cover every uncertain action.
  Atomic
  `not_applied_fenced` at generation `G` rejects delayed attempts through `G`;
  only exact `G + 1` preserves the stable request while deriving a new dispatch
  root. Pending and unknown status never permit retry, and terminal duplicates
  keep the fake application count at one. Integrated Zig tests inject
  deterministic same-process faults at four terminal-transition and four
  fenced-transition append phases, then freshly reopen, repair when required,
  and reconcile. Twenty independent Python tests rebuild the portable
  semantics; a separate Python CLI invocation compares a live canonical Zig
  report. No JSON fixture is retained. The
  earlier 49-death W4b-c campaign remains the only
  ActionOutbox process-death evidence. Live dispatch, real credentials,
  network/provider/tool effects, OS-level isolation or security proof,
  cryptographic origin, fake-service restart persistence, power-loss behavior,
  Windows durable files, native platform behavior, performance, and external
  exactly-once delivery remain staged. Each profile must name its execution
  unit, exact claim,
  cancellation/preemption boundary, correctness gate, and publication
  authority without weakening W4a. See
  [Typed Tool Workload](TYPED_TOOL_WORKLOAD.md) and
  [ActionOutbox Protocol](ACTION_OUTBOX.md).
- [ ] **W5 — Native observation and machine comparability.**
  - [x] **W5a — Portable observation and admission foundation.** Fixed-size,
    pointer-free descriptor/rule/plan/observation/bundle contracts retain
    explicit `present`, `missing`, `denied`, and `unsupported` states,
    stable source identity, per-event provenance, nonzero unavailable-reason
    identity, no present-reason identity, subject, unit, host/accelerator plane,
    sample-clock identity on every observation, and value-clock identity only
    on present time-valued metrics.
    A family-neutral runner executes
    `probe → pre_run → begin → workload → end → post_run`, rejects failed
    pre-admission before starting the workload, retains post-run contamination,
    and requires correctness, zero-orphan, and explicit accelerator-fallback
    evidence. The canonical reference reuses three typed-perception profiles
    and six fixed items without a model download. The bounded macOS observer
    reads `pmset`, `top`, `vm_stat`, `sysctl`, and `ps`; the paired harness
    delegates its `pmset`, `vm_stat`, `top`, and external-process CPU parsing
    to that shared module. See
    [Native Observation Contract](NATIVE_OBSERVATION.md).
  - [ ] **W5b — Direct physical adapters.** Add trustworthy native CPU,
    GPU/accelerator, memory-residency, power, thermal, frequency, utilization,
    and energy sources while preserving explicit unavailability, per-record
    sample-clock identities, and value-clock identities for present time
    metrics. Two bounded implementation slices are now present: a
    platform-neutral host record layer plus a Linux `/proc/meminfo` adapter for
    the exact
    `MemAvailable` field, with bounded read/provenance, strict parsing, checked
    byte conversion, and injected tests for missing, denied, malformed,
    duplicate, overflow, and oversized input; and a native macOS Metal
    diagnostic-readiness adapter that runs one fixed 37x64 INT4 matrix-vector
    dispatch, checks it against the CPU oracle, and requires device identity,
    command-buffer timestamps, ownership closure, and no CPU fallback. The
    Metal gate performs exactly one real GPU dispatch in total. Logical CPU
    count must remain positive; signed physical temperatures may not fall below
    absolute zero. W5b remains open for the unsupported physical metrics and
    broader retained native observer coverage. Separately, the native
    allocation suite
    now includes a bounded two-slot pressure proof over real commands and
    disjoint buffers: two native command records coexist, exact replay adds no
    record, a third request rejects before native mutation, both commands and
    CPU oracles complete, and B is deliberately settled before A before
    ownership returns to zero. That test establishes runtime capacity and
    settlement isolation, not a physical utilization, completion-order, or
    performance metric.
  - [ ] **W5c — Native observer coverage.** Broaden retained native macOS
    evidence by retaining an addressable Metal readiness result, run the
    required Linux available-memory smoke on a native Linux host, and add
    Windows and FreeBSD adapter evidence as each platform becomes available.
    Cross-host parser tests, an unretained local native pass, and
    cross-compilation remain narrower than retained campaign evidence and do
    not complete this slice.
- [x] **W6 — Native workload reports.**
  - [x] **W6a — Portable report foundation.** The versioned allocation-free
    wire binds one scenario, every warmup and measured raw request, a summary
    recomputed only from the measured cohort, and an exact zero-orphan closure.
    A deterministic six-record synthetic runner emits the binary wire; an
    independent standard-library Python implementation decodes it and
    recomputes its identities and summary. Zig and independently encoded Python
    mutation coverage reject a one-bit change at every serialized-byte
    position, truncation, extension, record reorder or duplicate, and rehashed
    summary, physical-metric, or device-duration forgeries.
    Focused test and compile gates are integrated, and the codec plus runner
    cross-compile for Linux x86_64/AArch64, Windows x86_64, and FreeBSD x86_64.
    Cross-building these targets is portability evidence, not native execution.
    See [Native Workload Report](NATIVE_WORKLOAD_REPORT.md).
  - [x] **W6b — Bounded native producer and evidence.** The fixed
    production Metal path now feeds the unchanged W6a wire. One closed-loop run
    emits 4 warmup and 16 measured records for real 37x64 INT4 matrix-vector
    commands over two logical adapter slots and one persistent eight-buffer,
    5,544-byte logical lease. Both commands in each pair submit before either
    wait; every output passes a precomputed CPU oracle within `2e-5`, slot 1
    deliberately settles before slot 0, and the next pair starts only after
    both settle. A global host sequence, separate same-command GPU timestamps,
    device/lifecycle identity, sampled `currentAllocatedSize`, generation roots,
    no fallback, balanced flows, and zero terminal ownership are independently
    verified. The raw wire is retained only when an output path is explicitly
    requested and only after verification. Logical slots do not prove physical
    parallelism or hardware queue occupancy, and `currentAllocatedSize` is not
    residency. Physical queue depth, utilization, power, residency, thermal,
    frequency, energy, and parallelism remain unsupported unless a named
    native observer supplies them.
    The first retained machine result is the
    [2026-07-28 macOS arm64 wire](../bench/results/native-metal-workload-report-macos-arm64-2026-07-28.bin)
    and its
    [capture manifest](../bench/results/native-metal-workload-report-macos-arm64-2026-07-28.manifest.json);
    it remains one diagnostic capture rather than performance or replication
    evidence.
- [ ] **W7 — Soak and disruption.** Run bounded campaigns under a fixed fault
  schedule and prove recovery, bounded growth, exact publication, and zero
  leaked ownership.
  - [x] **W7a — Native controlled-disruption recovery.** One fixed
    production-native macOS Metal campaign executes 50 epochs and retains 250
    raw W6 records: 50 admitted cancellations before submit, 50 admitted
    malformed-length rejections, 100 completed real GPU commands, and 50
    distinct requests rejected while both logical adapter slots are live. Each
    epoch settles the two pre-submit outcomes before submitting both GPU lanes;
    the full-slot probe must preserve the public allocation snapshot, exact
    active tickets and generation cursors, Bank, coordinator, buffers,
    commands, and completed-dispatch count; both commands then pass their CPU
    oracles and settle lane 1 before lane 0. The next epoch begins only at the
    reusable eight-buffer, 5,544-byte logical-lease boundary with no active
    pin, dispatch, command, quarantine, or unresolved submission. A separate
    profile verifier recomputes the exact schedule identities, outcomes,
    event ordering, measured summary, 200/200 Bank-pin closure,
    generation-bound capacity roots, and action/evidence commitments over the
    admitted actual roots after the portable verifier accepts the wire. See
    [Native Metal controlled-disruption report](NATIVE_METAL_DISRUPTION_REPORT.md).
    The three controlled branches submit no GPU command and do not represent
    physical device loss, driver failure, power loss, residency loss, or a
    performance result.
  - [x] **W7b-a — Segmented native Metal soak.** The fixed production-native
    macOS Metal gate runs 12 paced segments across two worker processes, six
    segments per process, with one planned clean exit and restart. Each segment
    contains 50 epochs, 250 raw records, 100 completed real Metal commands, and
    a 5-second minimum/15-second maximum duration under a 180-second campaign
    watchdog. The complete campaign therefore verifies 600 epochs, 3,000 raw
    records (120 warmup and 2,880 measured), 1,200 completed commands, 600
    cancel-before-submit outcomes, 600 malformed pre-submit rejections, 600
    full-slot capacity rejections, 2,400 Bank-pin acquisitions and
    completions, and 15,000 ordered host event points. Segment challenges bind
    the campaign, scheduled action, process generation, and preceding entry
    and report; the RSS source remains stable within one process and changes
    across the restart.

    Worker RSS and Metal `currentAllocatedSize` before/maximum/after must remain
    within 64 MiB of the first observation in each process generation. The
    latter is device-wide allocation context, not owned, committed, or resident
    GPU memory. Strict before/after environment snapshots require AC power,
    low-power mode disabled, nominal `pmset` and Foundation thermal state, no
    admission reason, and the same host/boot-session fingerprint.

    The crash-atomic, content-addressed store publishes a canonical fixed-size
    manifest and active selector after every segment, retains raw segments and
    environment objects, and is bounded to 4 MiB and 32 regular files. It is
    ephemeral unless retention is requested. After the writer closes, a fresh
    offline-verifier process, independent of the live supervisor's in-memory
    state, reopens the active prefix and rebuilds
    the exact manifest sequence, reruns both verification layers over every
    retained inner wire, rechecks component and environment bindings, and
    rejects missing, additional, corrupted, symlinked, or chain-substituted
    objects. See
    [Native Metal segmented soak report](NATIVE_METAL_SOAK_REPORT.md).
    This is finite paced correctness, recovery, ownership, durable-continuity,
    and observed-growth evidence for the invoking host. It is not a latency or
    throughput benchmark, a no-leak proof, physical residency evidence, or a
    physical device, driver, power, or storage-failure campaign.
  - [x] **W7b-b1 — Quiescent worker process kill.** A separate sealed profile
    runs the same 12 segments and 1,200 real commands but changes ordinal 5 to
    a forced phase end. After that segment passes both verifiers, reaches zero
    logical ownership, and is synchronized as a content-addressed object, the
    supervisor sends real `SIGKILL` to that worker PID and requires wait status
    `-9`. It then publishes and re-reads generation six, restores predecessor
    and cumulative facts from the retained entry, starts a fresh Metal worker,
    and completes generation two. The plan flag, forced action, provenance,
    signal, entry, challenge, and selector semantics are independently
    reconstructed in Zig and Python while the zero-flag W7b-a golden remains
    byte-identical. The watchdog separately kills an entire timed-out private
    process group even after its leader exits. See
    [Native Metal process-kill recovery report](NATIVE_METAL_PROCESS_KILL_REPORT.md).
    This is real post-segment OS process-death evidence, not an in-flight
    command, supervisor-crash, driver-reclamation, or physical-device recovery
    claim.
  - [x] **W7b-b2 — Production store publication faults.** A
    accelerator-independent POSIX-host prepared generation transition runs
    through 27 ordered publication calls spanning environment, report,
    manifest, selector, and store-root objects. The hard matrix sends real
    `SIGKILL` after each call, separately returns controlled `EIO` and `ENOSPC`
    before each call, and runs one clean control. Every case uses
    two fresh recovery processes plus a fresh strict verifier; unknown residue,
    corrupt objects, symlinks, foreign hard links, selector substitution, lock
    contention, and directory-namespace replacement fail closed. The
    81-fault binary report has independent Zig/Python verification. This runs
    real host processes and filesystem calls but no model or GPU command;
    injected errno is not physical storage failure. Publication uses the
    production store writer; prepared roll-forward remains bounded campaign
    reference code rather than a general production recovery API. See the
    [Native workload store-fault report](NATIVE_WORKLOAD_STORE_FAULT_REPORT.md).
  - [x] **W7b-b3 — Native cancellation-storm concurrent callers.** In each of
    eight blocks of eight waves, two real host threads reach one ready barrier
    before a shared release store; each thread cancels one disjoint admitted
    lane before submission, and each wave retains one capacity probe. Every
    block then completes one real Metal control on
    each lane. The 163,132-byte report contains 128 cancellations, 64 capacity
    probes, 16 CPU-oracle-checked controls, and 208 records, with 144/144 pin
    closure and terminal zero ownership. Block 0 is warmup; blocks 1–7 retain
    182 measured records balanced 91:91 across the two flows. The exact verifier
    binds the host-event partial order, challenge-selected settlement order,
    unique generations, zero native-command roots for cancellation/capacity,
    component hashes, measured summary, and closure. The barrier proves the
    ready-before-release boundary, not simultaneous scheduling or execution,
    critical-section overlap, GPU parallelism, post-submit kernel cancellation,
    preemption, performance, or a physical fault. See the
    [Native Metal cancellation-storm report](NATIVE_METAL_CANCELLATION_STORM_REPORT.md).
  - [x] **W7b-b4 — Controlled in-flight process kill.** A fault-linked victim
    registers one real INT4 command that signals a private `MTLSharedEvent` at
    `1` after compute and waits for `2`. Its exact 512-byte ready frame must show
    committed-or-scheduled nonterminal status, completion unobserved, four live
    native buffers, one live command, and four active allocation references.
    Only after verifying the exact PID and frame does the controller send real
    PID-only `SIGKILL`, require status `-9` and exact EOF, and launch a distinct
    production-linked W6 process that completes 20 CPU-oracle-checked real Metal
    commands. The build-isolated event barrier is controlled and synthetic;
    the Metal command, OS kill, and fresh control are real. This proves no
    active-kernel interruption, victim-output recovery, state preservation,
    complete driver reclamation, physical device loss, performance, or direct
    GPU telemetry. See the
    [Native Metal in-flight process-kill report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md).
  - [x] **W7b-b5 — Supervisor and recovery-process death at durable
    boundaries.** Worker one completes ordinals `0..5`, exits cleanly, and is
    reaped before the supervisor synchronizes generation six, holds the
    exclusive store lock, and publishes a private pre-ready handoff. The
    controller validates that handoff, proves contention, and returns a
    challenge-bound acknowledgement before the supervisor emits its exact
    public ready frame. It then sends real PID-only `SIGKILL`, requires `-9`
    and EOF, derives the resume grant, and starts a fresh shared-lock
    generation-six audit whose frame binds it. The grant is withheld from
    recovery until that audit passes; worker two then completes ordinals
    `6..11`. Its recovery
    process keeps generation eleven active while synchronizing generation-twelve
    immutable objects and the exact 192-byte selector temporary. After worker
    two exits cleanly, the controller repeats the real kill. A separately
    authorized fresh process performs only the exact `11 -> 12` roll-forward
    before a final fresh audit. The complete 3,520-byte report binds both ready
    frames, kill receipts, audits, grants, store roots, identities, and fixed
    1,200-command/1,200-CPU-oracle campaign and passes independent Python and
    Zig verification. Locks, file writes, hard links, replacements, and
    `fsync` calls are real; ready barriers, kill timing, publication pause,
    and grants are controlled. See the
    [Native Metal supervisor and recovery-process death report](NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md).
  - [ ] **W7b-b — Remaining broader disruption.** Add the broader bounded
    supervisor/recovery interruption matrix, active-kernel and adapter-loss,
    physical storage/power, and
    physical-device fault schedules with explicit
    synthetic-versus-physical provenance. Include prepared-text repeated
    handoff, source/target death, idempotent sink replay, selector corruption,
    and lease contention without relabelling fail-closed unavailability as
    recovery.
- [ ] **W8 — Native platform replication.** Retain independently verifiable
  campaigns on every claimed operating system and backend. Cross-compilation
  does not count as native workload evidence.

## Workload profile contract

Every typed workload profile declares:

- family, operation, artifact, backend, device placement, and numerical policy;
- input source and output correctness or quality gate;
- arrival mode, concurrency or rate, warmup, measurement window, and seed;
- exact runtime claim and external resource ceilings;
- batching, backpressure, cancellation, deadline, and safe-preemption rules;
- publication authority and terminal cleanup behavior; and
- private-data retention and evidence-redaction policy.

Model, media, provider, and tool profiles use the same lifecycle vocabulary but
may not pretend to have identical work units. Tokens, frames, samples, tool
calls, and provider-reported input units remain distinct observations.

## Machine-state comparability

A native observation is comparable only when workload, artifact, build,
backend, CPU topology, worker count, affinity policy, process priority,
precision policy, resource ceilings, and any selected accelerator identity,
placement, and queue count match. Device placement, queue state, and device load
apply only when the selected profile uses a device. Its pre-run admission
window must pass fixed host and selected-device load plus memory-pressure
gates; directly observable CPU/GPU power and thermal constraint state must
remain stable; in-run external CPU and selected-device activity must stay
within policy; and the post-run contamination check must pass.

Every observer reports availability, stable source identity, and per-event
provenance. `same_source` applies to the stable source identity; a new
per-sample provenance identity does not imply source drift. Unavailable
temperature, frequency, energy, or device-residency telemetry retains a
nonzero reason identity, blocks claims about that metric, and never becomes a
zero value. Present records carry no reason identity. External power is
recorded context, not proof that two runs had equal CPU state.

Failed or unmatched observations remain in the artifact with rejection
reasons and are excluded by the versioned summary algorithm. They are never
silently deleted.

The macOS paired harness already demonstrates fail-closed admission using power
source, low-power mode, thermal constraint signals, load, CPU idle, page and
swap activity, adjacent-state matching, in-run external CPU activity, post-run
contamination checks, wall time, and peak RSS. W5a extracts the strict
`pmset`, `vm_stat`, and `top` parser seam into the shared bounded host observer;
the paired harness also delegates external-process CPU parsing while retaining
its campaign policy. The W5a host observer emits a fixed eleven-metric universe
and labels malformed, permission-denied, and unimplemented observations
separately, retaining a bounded readable JSON reason only when unavailable. It
does not directly observe CPU temperature, effective frequency, core residency,
package energy, GPU utilization, device residency, or accelerator energy. The
separate Metal readiness adapter observes command-buffer start/end timestamps
for its single fixed dispatch, but those timestamps remain diagnostic and are
not a workload-latency result.

## GPU and accelerator observation

Accelerator evidence is a first-class report plane, not an optional suffix on
CPU timing. A native accelerator run retains:

- backend/API, adapter implementation, device vendor/model/identity, driver,
  runtime, firmware when observable, and device topology;
- declared model/tensor placement, numerical policy, batch shape, queue count,
  maximum in-flight work, and host/device synchronization policy;
- cold compilation or pipeline creation separately from warm execution, plus
  shader/kernel and model-cache state;
- host submit, device start/end, synchronization, first-visible-output, and
  end-to-end times as distinct observations;
- allocated, committed, resident, and peak device memory when independently
  observable, with unified/shared memory kept distinct from summed host plus
  device memory;
- device utilization, queue occupancy, effective clocks, throttling reason,
  temperature, power, and energy only when a named observer directly reports
  them; and
- transfer bytes, transfer direction, peer-to-peer or shared-memory path, and
  multi-device placement when applicable.

An accelerator-labeled result is invalid if the selected execution silently
falls back to CPU. Mixed CPU/GPU execution is valid only when the placement and
work split are explicit. Every device observation names the clock used to
sample it; a present device time additionally names the clock that produced
the value. Those fields do not claim calibration and are not silently mixed
with host monotonic time values.

Platform observers are adapters. A Metal observer on macOS, a vendor or OS
observer on Linux or Windows, and a reduced mobile observer may expose
different fields, but all use the same availability states and provenance
rules. Missing GPU telemetry blocks only the affected physical claim; it does
not block correctness testing or become a fabricated zero.

### Current accelerator baseline

The current accelerator baseline is an optional macOS Metal path exposing INT4
dequantization, FP16 matrix multiplication, and persistent INT4 matrix-vector
execution. Retained CPU-oracle tests cover dequantization and the fused INT4
matrix-vector path; an isolated smoke microbenchmark covers persistent-weight
matrix-vector execution. The new readiness adapter additionally binds the
family-neutral W5 runner to one fixed synthetic 37x64 INT4 matrix-vector
operation on a native Metal device. Its hard gate makes exactly one real GPU
dispatch, requires a completed command buffer, checks output correctness and
zero leaked ownership, rejects CPU fallback, and composes device/placement,
observation, workload, run, dispatch, and output roots.

The allocation/lifetime gate separately proves bounded two-slot coexistence on
the built-in M1. One eight-object lease provides disjoint four-buffer roles for
two real commands. Both commands submit and complete, pass their CPU oracles,
and remain retained until B is deliberately settled before A. The native
registry reaches two records, replay stays at two, a third request is
capacity-rejected before native mutation, and final command, pin, and buffer
counts are zero. This remains allocation/lifetime conformance rather than a
report, latency, throughput, utilization, queue-depth, physical-parallel, or
completion-order result.

W6b now exercises the same production allocation and dispatch boundaries as a
finite report campaign. It reuses one persistent eight-buffer lease for 10
pairs: 2 warmup pairs and 8 measured pairs. Each pair reaches two live logical
adapter slots before waiting, all 20 outputs pass their CPU oracles, B settles
before A, and both slots settle before reuse. Every raw request, lifecycle
event, semantic root, device duration, allocated-size sample, and ownership
fact enters the versioned W6 wire before independent portable and native-profile
verification. This is real Metal execution on the invoking native macOS host,
not a simulated GPU environment. The two-slot schedule still does not observe
physical queue occupancy or prove that the GPU executed the commands
simultaneously.

The readiness report records Metal registry identity, pre/post
`currentAllocatedSize`, and command-buffer GPU timestamps.
`recommendedMaxWorkingSetSize` is capacity context only. Utilization,
committed/resident bytes, queue depth, temperature, frequency, power, and energy
remain explicit `unsupported` observations. The independent verifier checks
composition and corruption of a self-asserted live capture; it does not
authenticate the capture's origin.

W0 and W1 do not exercise this Metal path. A successful readiness invocation is
diagnostic evidence for only that exact host session; it is not a throughput,
latency, performance, or broad device-support result. The readiness gate does
not retain an addressable result. The W6b report gate can retain its raw wire,
but only at an explicitly requested path after complete verification, so
implementation evidence and retained campaign evidence remain distinct. Run
the gates with:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-observation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Platform and backend truth remains governed by
[Platform Portability](PLATFORM_PORTABILITY.md).

## Native report contract

The implemented W6 report retains every request before aggregation in a fixed
little-endian binary wire. W6a defines the backend-neutral codec and synthetic
reference; W6b supplies the first production-native Metal producer without
changing the wire. Its scenario binds the workload/profile, artifact, build,
machine, backend, device, placement, host/device observer and clock identities,
campaign mode, warmup/measured counts, logical in-flight target, adapter queue
count, flow count, challenge, and summary algorithm.

Each raw record retains its cohort, flow, outcome, work units, optional adapter
slot, the host-observed lifecycle from arrival through settlement, semantic
roots, correctness and fallback, available same-clock device timing and
allocated-size context, and logical Bank/pin/dispatch/native-command facts.
Warmup records remain in the chain but never enter the measured summary.

The canonical V1 summary recomputes:

- attempted, admitted, completed, capacity-rejected, failed, cancelled, and
  timed-out counts plus attempted and completed work units;
- completed work over the exact first-arrival-to-final-settlement interval as
  an integer rational;
- nearest-rank p50/p95/p99/max admission, queue, first-output, service,
  end-to-end, and available device-duration distributions;
- logical in-flight high-water from the ordered host event sequences;
- per-flow completion minimum, maximum, and spread;
- fallback and correctness counts; and
- sampled allocated-size context when present without relabelling it as device
  residency.

Host CPU time, RSS, device duration, allocated-size context, utilization,
physical queue depth, residency, power, energy, temperature, frequency, and
physical parallelism have fixed availability-bearing metric positions.
Unavailable metrics remain missing, denied, or unsupported rather than present
zeroes. The synthetic producer keeps direct physical metrics unsupported. The
native Metal producer makes device duration and sampled allocated-size context
present, while utilization, physical queue depth, residency, power, energy,
temperature, frequency, and physical parallelism remain unsupported.

The closure requires zero logical Bank usage, active pins, active dispatches,
native commands, and native buffers; equal acquisition/completion counts; and
explicit zero-orphan status. The decoder checks fixed lengths, reserved values,
causal event sequences, clock rules, record order and hash chain, exact summary
recomputation, metric availability, semantic roots, and closure.

Run the portable gates with:

```sh
tools/zig-with-ephemeral-cache.sh build native-workload-report-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-workload-report-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-workload-report-cross-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The first command executes a deterministic synthetic reference and an
independent Python verifier. It opens no device and performs no measured
production CPU or GPU workload. The last command only cross-compiles the codec
tests and runner; it does not execute them on the foreign operating systems. See
[Native Workload Report](NATIVE_WORKLOAD_REPORT.md) for the exact wire and
claim boundary.

Run the real production-native Metal campaign on a native macOS Metal host:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

This executes 20 real GPU commands through the production adapter and verifies
the resulting raw wire twice: first against the portable contract and then
against the exact native campaign profile. Add
`-Dnative-metal-report-output=PATH` to retain the raw wire atomically after
verification. The command is a correctness and evidence gate, not a
performance benchmark.

Run the W7a production-native controlled-disruption campaign separately:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-disruption-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

This executes 100 real GPU commands inside 50 fixed recovery epochs and
retains all successful and controlled non-submit outcomes in 250 raw records.
Add `-Dnative-metal-disruption-report-output=PATH` for atomic retention after
both verification layers pass. It is a finite recovery and ownership
campaign, not a duration-bounded soak, physical-fault test, or performance
benchmark.

Run the W7b-b3 production-native cancellation-storm campaign separately:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-cancellation-storm-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

In each of 64 waves, both real cancellation-caller threads reach the ready
barrier before one shared release store. The campaign retains 128
cancel-before-submit and 64 capacity records with zero native commands, and
verifies 16 real Metal controls against CPU oracles. Add
`-Dnative-metal-cancellation-storm-report-output=PATH` to retain the raw wire
after both verification layers pass. See
[Native Metal cancellation-storm report](NATIVE_METAL_CANCELLATION_STORM_REPORT.md).
The ready-before-release boundary does not prove simultaneous scheduling or
execution, lock overlap, physical GPU parallelism, or kernel cancellation.

Run the W7b-b4 in-flight process-kill campaign separately:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

The victim uses a build-isolated controlled event barrier around one real
registered INT4 command. After validating the exact 512-byte ready frame, the
controller sends real PID-only `SIGKILL`, requires `-9` and EOF, and verifies a
fresh production-linked 20-command W6 control. Add
`-Dnative-metal-inflight-process-kill-report-output=PATH` for retention after
complete verification. See the
[Native Metal in-flight process-kill report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md).
This gate does not prove active-kernel interruption, output recovery, state
preservation, or complete driver reclamation.

Run the W7b-b5 portable report and bounded host protocol without GPU work:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-supervisor-recovery-death-report-test \
  native-supervisor-recovery-death-host-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile its native frontier without starting a device process:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-compile \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the focused W7b-b5 hard gate:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Add `-Dnative-metal-supervisor-recovery-death-output-dir=PATH` to retain the
private verified report-and-store directory. The gate completes 1,200 real
Metal commands against 1,200 CPU oracles, sends two real PID-only `SIGKILL`
operations only after the corresponding worker is cleanly reaped, and accepts
only the fresh generation-six audit and exact `11 -> 12` roll-forward. See the
[Native Metal supervisor and recovery-process death report](NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md).

Run the W7b-a segmented production-native Metal soak separately:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-soak-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

This runs 12 independently challenged and verified segments across two clean
worker lifetimes. The bounded content-addressed checkpoint store is published
after every segment. Add `-Dnative-metal-soak-output-dir=PATH` to retain it;
otherwise it is ephemeral. In both cases the build gate closes the live writer
and launches the `--verify-store` offline path in a fresh process, which
reopens the selector, manifests, environment objects, and every referenced
inner wire without trusting the supervisor's in-memory results. See
[Native Metal segmented soak report](NATIVE_METAL_SOAK_REPORT.md). The gate is
finite paced recovery and observed-growth evidence, not a performance
benchmark, physical fault injection, device residency measurement, or an
unbounded no-leak proof.

Run the W7b-b1 post-segment process-kill profile separately:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Add `-Dnative-metal-process-kill-output-dir=PATH` to retain its store. The
first worker is killed only after its sixth report reaches a quiescent,
verified boundary; the second worker uses a fresh Metal backend. See
[Native Metal process-kill recovery report](NATIVE_METAL_PROCESS_KILL_REPORT.md).
This gate does not interrupt a GPU command, recover process-local state, or
model device removal.

Run the full native Metal suite in its fixed hardware order:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j1
```

Affected-path verification completes `native-metal-suite-compile` first. That
shared frontier builds every suite artifact and performs every static check
before the first suite device process starts. The serialized hardware phase
then reuses the same graph and private caches, avoiding repeated compilation
through separate cold invocations.

When retention is requested from the serialized `native-metal-suite-test`, use
`-Dnative-metal-suite-report-output=PATH`. It is mutually exclusive with the
focused gate's `-Dnative-metal-report-output=PATH` in one build invocation, so
two independently challenged campaigns cannot race to publish one file.

For each hard-gate invocation, the verifier generates a fresh 256-bit challenge
and supplies it through a dedicated, sanitized environment variable. The
zero-argument runner binds that value and a domain-separated build identity
over the producer ABI, its exact executable SHA-256, and the external
`shaders.metallib` SHA-256 into the scenario. The verifier hashes both files
before and after the run, rejecting replacement, stale-wire replay, and
identity mismatch. These controls bind a live capture to one invocation and
one host/GPU program pair; they do not turn the self-asserted report into
cryptographic code attestation.

## Promotion gate

A native result is publishable only when it retains the exact scenario,
artifact, build, backend, machine, and observer identities; every raw
observation and rejection reason; the versioned summary algorithm; the
correctness or quality gate; and the final zero-orphan result.

A same-machine result remains scoped to its exact machine and workload matrix.
One native operating system or backend never promotes another.

## Contributor slices

Independent contributions can add:

1. one retained generated seed, exact failure signature, or independent
   generator/shrinker check;
2. one retained deterministic closed-loop plan, phase/lineage mutation, or
   independent decoder while preserving every existing V1 root;
3. one real-service or OS-isolated dispatch/status adapter that preserves the
   driver ordering and generation-fence proof without weakening either tool
   proof;
4. one Linux, Windows, or FreeBSD native host metric adapter behind the
   completed W5a contract;
5. one direct CPU power/thermal/frequency or device
   identity/residency/utilization adapter with explicit availability and
   metric-specific signed ranges;
6. a bounded device observer slice for placement, host submit/sync timing,
   fallback detection, and explicit device-time value-clock identity;
7. one additional bounded production-native CPU or accelerator producer that
   feeds the completed W6 report without weakening its raw-record, clock,
   availability, correctness, or closure rules;
8. one bounded fault injector with an explicit authority ceiling; or
9. a native replication recipe for one supported backend.

Each slice must retain its fixtures, failure cases, exact acceptance command,
and nonclaims. See [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md),
[Generated Workload Corpus](GENERATED_WORKLOAD_CORPUS.md),
[Scheduled Media Pressure](SCHEDULED_MEDIA_PRESSURE.md), and
[Typed Tool Workload](TYPED_TOOL_WORKLOAD.md), plus the
[Native Observation Contract](NATIVE_OBSERVATION.md),
[Native Workload Report](NATIVE_WORKLOAD_REPORT.md),
[Native Metal Process-Kill Recovery Report](NATIVE_METAL_PROCESS_KILL_REPORT.md),
[Native Metal In-Flight Process-Kill Report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md),
[Native Metal Supervisor and Recovery-Process Death Report](NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md),
and [Benchmark and Evidence Guide](BENCHMARKS.md) for the existing foundations.
