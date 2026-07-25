# Deterministic Workload Pressure

Glacier's first load-system foundation is a bounded, model-free conformance
campaign. It drives the real `LaneWeave` scheduler, `ResourceBank`, and
`LaneWeave` verifier with a fixed mixed-media workload, then emits canonical
scenario and result evidence that an independent Python implementation replays
from first principles.

This answers a narrower question than a native load benchmark:

> Given the same admitted work, logical resource limits, and scheduling
> contract, do overload, fairness, deadlines, cancellation, release, and the
> final evidence remain exact and reproducible?

The answer is retained without relying on wall-clock order, threads, random
timing, a model download, a device, or network access.

An additive scheduled-media layer now consumes the same accepted receipts and
executes the retained image, audio, and video transactions on their final
service quanta without changing any WorkloadPressure V1 scenario/result byte or
root. See [Scheduled Media Pressure](SCHEDULED_MEDIA_PRESSURE.md).

## What V1 exercises

The reference campaign contains seven typed image, audio, and video work items:

| Item | Arrival | Weight | Work | Planned terminal action | Expected result |
| --- | ---: | ---: | ---: | --- | --- |
| Image 0 | 0 | 1 | 8 quanta | Cancel at step 7 | Cancelled |
| Audio 1 | 0 | 2 | 6 quanta | None | Completed |
| Video 2 | 0 | 4 | 12 quanta | None | Completed |
| Audio 3 | 0 | 1 | 8 quanta | Timeout at step 3 | Timed out before service |
| Video 4 | 0 | 2 | 2 quanta | None | Rejected: no scheduler slot |
| Image 5 | 4 | 1 | 2 quanta | None | Rejected: logical resource limit |
| Image 6 | 8 | 1 | 2 quanta | None | Completed |

The first four items fill the four-slot capacity. The next arrival proves
capacity rejection. Timing out Audio 3 frees one slot, but the next image still
exceeds the fixed host-resource ceiling and proves independent resource
rejection. Cancelling Image 0 releases enough ownership for the final image to
enter and complete.

The first seven service decisions are exactly:

```text
image, audio, video, audio, video, video, video
```

That is the declared `1:2:4` weighted share over the retained fairness window.
The full campaign produces:

- five admissions and two rejections;
- three completions, one cancellation, and one timeout;
- 21 service quanta across 21 driver steps;
- 34 trace records;
- four maximum simultaneously live committed receipts;
- five commits and five releases; and
- zero active work, reservations, receipts, or orphan ownership at close.

## Logical resource profiles

Each work item carries a complete `ResourceBank.Claim` and a profile root. The
reference profile identities bind the typed model family, `encode` operation,
media kind, and exact claim. Compile-time checks also bind the claims to the
retained media plan and fixture component sizes.

The fixed logical host claims are:

| Media kind | Logical host bytes | I/O bytes | Queue slots |
| --- | ---: | ---: | ---: |
| Image | 1,464 | 364 | 1 |
| Audio | 1,220 | 384 | 1 |
| Video | 1,068 | 360 | 1 |

The campaign ceiling is 4,972 logical host bytes and four queue slots. These
numbers describe declared ownership inside `ResourceBank`; they are not process
RSS, allocator overhead, device residency, or operating-system memory pressure.

## Portable evidence contract

V1 accepts only the `explicit_open_loop` mode. Every arrival and terminal
action uses an absolute logical driver step, and every service decision advances
the scheduler's logical tick. The fixed bounds are:

| Bound | V1 maximum |
| --- | ---: |
| Work items | 16 |
| Trace records | 64 |
| Driver steps | 512 |
| Service quanta | 256 |

The scenario wire is:

```text
256-byte header + item_count × 272-byte item + 32-byte footer
```

The result wire is:

```text
544-byte header
+ item_count × 160-byte outcome
+ trace_count × 112-byte trace record
+ 32-byte footer
```

Every trace record has a recomputable SHA-256 identity. Separate roots bind the
scenario, ordered outcomes, ordered trace, summary, and complete result body.
The reference fixture freezes the same roots in Zig and Python and rejects
every single-byte wire mutation, truncation, foreign scenario, reordered item,
rehashed summary contradiction, and rehashed trace or outcome substitution.

The Zig projection validator checks structural and aggregate consistency. The
exact validator reruns the scenario into caller-owned storage and compares
every outcome, trace record, summary field, and root. The Python verifier
independently implements admission, weighted scheduling, cancellation, resource
accounting, summary calculation, wire encoding, and exact replay rather than
calling into the Zig implementation.

Percentiles use the nearest-rank rule over logical driver-step delays. They are
deterministic scheduling observations, not milliseconds:

- queue delay p50/p95/p99/max: `1/5/5/5` steps;
- completion delay p50/p95/p99/max: `16/19/19/19` steps.

## Additive scheduled-media execution

The separately versioned scheduled-media sidecar adopts the exact scheduler
receipt for all five accepted items. It runs a real bounded media transaction
only for the three completed requests:

- Audio 1 transforms to `00c05515` with two exact mappings;
- Video 2 transforms to `ff804000` with one exact mapping; and
- Image 6 transforms to `00ff0000ff00ffffffffffff` with four exact mappings.

Candidate validation completes before one armed finalizer commits both media
publication and the last scheduler service quantum. Cancelled and timed-out
sessions close their publication fences and release the scheduler-owned receipt
without media execution; rejected items never bind a session. The Bank still
records five commits and five releases, proving that media execution did not
double-charge the workload.

The additive 5,472-byte evidence wire binds all seven workload outcomes, the
five accepted receipt identities, three final-service trace positions, complete
media execution receipts, exact output roots, before/after publication roots,
and a zero-orphan summary. Zig and Python independently reconstruct and verify
the same wire and retained root.

## Generated deterministic corpus

W2 retains the W0 and W1 contracts while expanding their schedule coverage.
Four retained seeds and eight scenario classes per seed produce 32 canonical
`explicit_open_loop` scenarios through coordinate-addressed, domain-separated
SHA-256 decisions. Zig and an independent Python implementation regenerate each
scenario, replay its unchanged W0 result, run its unchanged W1 media sidecar,
and require exact roots plus zero orphan ownership.

The corpus also retains one explicitly synthetic failure predicate. Its
deterministic shrinker accepts only valid candidates preserving the exact
failure signature and stops at a local fixed point under the declared
reductions. This demonstrates the shrinking contract; it is not a historical
defect or a claim of global minimality.

See [Generated Workload Corpus](GENERATED_WORKLOAD_CORPUS.md) for the generator
ABI, retained artifact, shrink contract, acceptance commands, and nonclaims.

## Deterministic closed-loop conformance

W3 is a separate finite-source contract rather than a new
`WorkloadPressure V1` mode. Its candidates have no precomputed absolute
arrival schedule. A declared logical in-flight target submits the initial
prefix; rejections, cancellations, timeouts, and completed retirement create
FIFO credits admitted on the next driver step. Phase-aware trace and lineage
records prove the predecessor, trigger, successor order, target bound, bounded
drain, and final zero ownership.

The direct Zig runner and independent Python oracle retain separate canonical
plan/result wires and reproduce the same state machine without changing any
W0/W1/W2 ABI or golden. W3 remains model-free and does not run the W1 media
transaction, typed adapters, asynchronous workers, or native timing. See
[Deterministic Closed-Loop Workload](DETERMINISTIC_CLOSED_LOOP.md).

## Run the retained campaign

```sh
zig test src/core/workload_pressure.zig -OReleaseSafe
python3 -m unittest bench.tests.test_workload_pressure
zig test src/core/scheduled_media_pressure.zig -OReleaseSafe
python3 -m unittest bench.tests.test_scheduled_media_pressure
tools/zig-with-ephemeral-cache.sh build workload-scenario-corpus-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
python3 -m unittest bench.tests.test_workload_scenario_corpus
tools/zig-with-ephemeral-cache.sh build workload-closed-loop-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
python3 -m unittest bench.tests.test_workload_closed_loop
```

The module is exported through both package surfaces as
`glacier.workload_pressure` / `glacier.WorkloadPressure` and
`glacier_core.workload_pressure` / `glacier_core.WorkloadPressure`. The
additive executor is exported as
`glacier.scheduled_media_pressure` / `glacier.ScheduledMediaPressure` and
`glacier_core.scheduled_media_pressure` /
`glacier_core.ScheduledMediaPressure`. The generated corpus is exported as
`glacier.workload_scenario_corpus` / `glacier.WorkloadScenarioCorpus` and
`glacier_core.workload_scenario_corpus` /
`glacier_core.WorkloadScenarioCorpus`. The W3 contract is exported separately
as `glacier.workload_closed_loop` / `glacier.WorkloadClosedLoop` and
`glacier_core.workload_closed_loop` / `glacier_core.WorkloadClosedLoop`.

## Claim boundary

The base V1 reference campaign proves deterministic contract behavior for one
bounded logical workload. The generated corpus repeats those unchanged
contracts over its retained 32-case matrix. W3 separately proves bounded
terminal-driven logical turnover for its retained finite-source plan. The
additive media campaign also proves deterministic fixture decode, transform,
mapping verification, transactional publication, and terminal release. These
layers do not measure:

- native throughput, requests per second, first-output latency, or tail latency;
- process RSS, allocator behavior, device memory, energy, or thermals;
- threaded execution, asynchronous queues, real batching, or kernel overlap;
- production model, tokenizer, external codec, playback, or display work;
- filesystem, process, backend, or device disruption under sustained load; or
- long-duration leak, soak, capacity-planning, or service-level behavior.

Cross-building this module checks portability of the contract; it does not
replace native execution evidence on each operating system.

## Next contributor slices

The complete sequencing and native report contract live in the
[Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md). The load track can grow
without mixing conformance and performance claims:

1. extend the completed W4a mixed vision/audio/temporal-video profile with
   provider, tool, stateful, streaming, or device-backed profiles;
2. add family-aware batching, safe preemption, and multi-tenant campaigns;
3. build native per-OS runners that retain CPU, memory, power, thermal, backend,
   and machine-condition envelopes; and
4. add bounded soak and scheduled disruption campaigns with recovery and
   zero-orphan gates.

Native timing evidence belongs under the paired campaign rules in
[Benchmark and Evidence Guide](BENCHMARKS.md), while platform promotion follows
[Platform Portability](PLATFORM_PORTABILITY.md).
