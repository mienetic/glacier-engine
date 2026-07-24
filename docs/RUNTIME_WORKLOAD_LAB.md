# Runtime Workload Lab

The Runtime Workload Lab makes workload, latency, resource, and resilience
evidence a versioned runtime surface instead of a collection of ad-hoc
benchmark commands.

It separates four kinds of evidence:

1. deterministic scheduling and accounting conformance;
2. native open-loop and closed-loop workload measurement;
3. CPU, GPU/accelerator, machine-state, and physical-resource observation; and
4. bounded soak and disruption recovery.

The deterministic open-loop and scheduler-coupled media layers are integrated.
Generated scenarios, closed-loop arrivals, broader typed workloads, native
multi-request reports, and soak campaigns remain staged work. A logical driver
step is never reported as a millisecond, and a logical resource claim is never
reported as RSS, device residency, energy, or temperature.

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
  fixed seed and retains minimized failures. It still uses logical time.
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
- [ ] **W2 — Generated scenario corpus.** Add a versioned generator ABI, fixed
  seeds and bounds, an independent oracle, deterministic shrinking, and a
  retained minimized failure corpus without changing W0 evidence semantics.
- [ ] **W3 — Closed-loop contract.** Add a separately versioned mode whose
  arrivals are driven by terminal work and a declared in-flight target.
- [ ] **W4 — Typed workload adapters.** Drive declared model, media, provider,
  and tool lifecycles through the existing workload-driver seam. Each profile
  names its execution unit, claim, cancellation or preemption boundary,
  correctness gate, and publication authority. The retained vision,
  audio-window, and temporal-video adapters already implement the shared
  scheduler-owned final-result lifecycle; the mixed workload-driver profile is
  the remaining first integration slice.
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

1. a bounded scenario generator and deterministic shrinker;
2. the separately versioned closed-loop contract;
3. one typed workload-driver profile;
4. a family-neutral observer interface and one native OS implementation;
5. a bounded Metal observer slice for device identity, host submit/sync timing,
   fallback detection, and explicit availability states;
6. the raw-request and native-summary report codecs plus independent verifier;
7. one bounded fault injector with an explicit authority ceiling; or
8. a native replication recipe for one supported backend.

Each slice must retain its fixtures, failure cases, exact acceptance command,
and nonclaims. See [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md),
[Scheduled Media Pressure](SCHEDULED_MEDIA_PRESSURE.md), and
[Benchmark and Evidence Guide](BENCHMARKS.md) for the existing foundations.
