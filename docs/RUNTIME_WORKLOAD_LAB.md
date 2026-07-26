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
record/recovery layers are integrated.
Provider, stateful, streaming, batched, preemptible, device-backed, and durable
file/live-dispatch tool profiles, native multi-request reports, and soak
campaigns remain staged work. A logical driver step is never reported as a
millisecond, and a logical resource claim is never reported as RSS, device
residency, energy, or temperature.

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
  W4b-b now adds a portable ActionOutbox record campaign: unresolved dispatch
  intent remains uncertain, only a `reconciled_not_applied` semantic record
  permits retry, and compensation is a separate authorized child. A future
  adapter must authenticate reconciliation evidence. Synced storage and live
  dispatch remain staged. Each profile must name its execution unit, exact
  claim, cancellation/preemption boundary, correctness gate, and publication
  authority without weakening W4a. See
  [Typed Tool Workload](TYPED_TOOL_WORKLOAD.md) and
  [ActionOutbox Protocol](ACTION_OUTBOX.md).
- [ ] **W5 — Native observation and machine comparability.** Add a
  family-neutral runner plus CPU, GPU/accelerator, memory, power, and thermal
  observers with explicit `present`, `missing`, `denied`, and `unsupported`
  states.
- [ ] **W6 — Native workload reports.** Retain raw request observations and
  versioned throughput, latency, CPU, accelerator, memory, fairness, and
  outcome summaries.
- [ ] **W7 — Soak and disruption.** Run bounded campaigns under a fixed fault
  schedule and prove recovery, bounded growth, exact publication, and zero
  leaked ownership.
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

Every observer reports availability and provenance. Unavailable temperature,
frequency, energy, or device-residency telemetry blocks claims about that
metric but never becomes a zero value. External power is recorded context, not
proof that two runs had equal CPU state.

Failed or unmatched observations remain in the artifact with rejection
reasons and are excluded by the versioned summary algorithm. They are never
silently deleted.

The existing macOS paired harness already demonstrates fail-closed admission
using power source, low-power mode, thermal constraint signals, load, CPU idle,
page and swap activity, adjacent-state matching, in-run external CPU activity,
post-run contamination checks, wall time, and peak RSS. That observer must be
extracted behind the family-neutral interface rather than duplicated. It does
not directly observe CPU temperature, effective frequency, core residency,
package energy, GPU utilization, command timing, device residency, or
accelerator energy.

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
work split are explicit. Device timestamps must name their clock domain and
calibration method; they are not silently mixed with host monotonic timestamps.

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
matrix-vector execution. This is not yet the family-neutral Workload Lab
runner, a complete model-family backend, a device-telemetry plane, or native
Linux/Windows accelerator support.

W0 and W1 do not exercise this Metal path. A successful baseline run
demonstrates only those retained kernels on that exact host; it does not
promote a backend/device support cell. Platform and backend truth remains
governed by
[Platform Portability](PLATFORM_PORTABILITY.md).

## Native report contract

The report retains every request observation before aggregation. Each record
contains arrival, admission, first service, first visible output, terminal
outcome, family and profile identity, resource receipt, correctness result,
and observer status.

A versioned summary reports:

- admitted, completed, rejected, cancelled, and timed-out counts;
- completed work per measured second and the exact measurement interval;
- queue, first-output, service, and end-to-end p50/p95/p99/max;
- fairness, deadline misses, backpressure, and concurrency high-water;
- process CPU time or utilization and observed external CPU interference;
- accelerator submit/device/synchronization timing only when a named timing
  observer reports it, explicit fallback status whenever a device backend is
  selected, and utilization or queue pressure only when named observers report
  them;
- logical ledger, allocator, RSS, peak RSS, mapped memory, and device
  residency as separate sources; and
- CPU and accelerator power, thermal, frequency, throttling, and energy only
  when their named observers are present and valid.

The percentile algorithm, raw unrounded inputs, rejected observations, and
observer provenance are part of report identity.

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
3. one typed workload-driver profile, durable ActionOutbox storage adapter, or
   reconciliation/dispatch harness that does not weaken either tool proof;
4. a family-neutral observer interface and one native OS implementation;
5. a bounded Metal observer slice for device identity, host submit/sync timing,
   fallback detection, and explicit availability states;
6. the raw-request and native-summary report codecs plus independent verifier;
7. one bounded fault injector with an explicit authority ceiling; or
8. a native replication recipe for one supported backend.

Each slice must retain its fixtures, failure cases, exact acceptance command,
and nonclaims. See [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md),
[Generated Workload Corpus](GENERATED_WORKLOAD_CORPUS.md),
[Scheduled Media Pressure](SCHEDULED_MEDIA_PRESSURE.md), and
[Typed Tool Workload](TYPED_TOOL_WORKLOAD.md), plus the
[Benchmark and Evidence Guide](BENCHMARKS.md) for the existing foundations.
