# Native Observation Contract

Native observation is the boundary between a deterministic workload and claims
about the machine that ran it. W5a delivers the first bounded version of that
boundary: a portable observation contract, a family-neutral runner, a
download-free reference workload, and a shared read-only macOS host observer.
The first post-W5a platform slice adds a platform-neutral JSON record layer and
a bounded Linux available-memory adapter without changing the portable Zig V1
contract. A native macOS Metal readiness slice now binds the same runner to one
fixed synthetic accelerator dispatch. The separate W6a
[Native Workload Report](NATIVE_WORKLOAD_REPORT.md) now consumes the same
availability discipline in a portable raw-record/summary/closure wire, but it
does not turn unavailable observers into native measurements.

W5a is an integrated conformance slice, not completion of W5. Direct CPU and
accelerator power, temperature, frequency, energy, utilization, and residency
adapters still need native implementations and retained evidence. Native
replication on another operating system is also still required before any
multi-platform claim.

## What is implemented

The portable Zig contract defines fixed-size, pointer-free values for:

- an observer descriptor with declared and directly observed metric masks;
- a plan binding workload, artifact, build, machine, backend, device,
  placement, execution plane, worker count, queue count, challenge, and rules;
- bounded observation records with separate stable source, per-sample
  provenance, and availability-reason identities, plus phase bundles; and
- canonical SHA-256 identities for every descriptor, rule, plan, run,
  observation section, and bundle.

A plan admits at most 16 ordered rules. One phase bundle admits at most 32
ordered observations. Canonical tails must be zero, metric order and sample
sequence are checked, and semantic substitution changes the relevant identity.

The process-local runner supplies the authority boundary that portable records
intentionally lack. It accepts an observer callback and a workload callback,
then executes:

```text
validate descriptor + plan
          │
          ▼
       probe ──reject──> retained pre-run rejection; workload not started
          │
          ▼
      pre_run ─reject──> retained pre-run rejection; workload not started
          │
          ▼
        begin
          │
          ▼
       workload, at most once
          │
          ▼
         end
          │
          ▼
      post_run ──> publishable or retained post-run rejection
```

A probe, pre-run sample, or begin failure fails closed before workload
execution. Once a workload starts, its failure still runs the end transition
and attempts the post-run sample. Post-run contamination preserves the
workload receipt and observation bundle but marks the report nonpublishable.
Reports retain separate callback, availability, threshold, provenance,
subject, fallback, correctness, zero-orphan, and clock-regression reasons.
`validateRunReportV1` checks the report's own shape and digest.
`validateRunArtifactV1` is the composition gate: it validates the descriptor,
plan, every retained phase bundle, workload receipt, evaluation masks,
lifecycle counters, elapsed value, decision, and all report-to-evidence roots
together.

## Availability is data

Every metric uses one of four states:

| State | Meaning | Value rule |
| --- | --- | --- |
| `present` | The named adapter directly observed the metric | A valid value is retained; no reason identity; the fixed reason field is zero |
| `missing` | The source should have supplied the metric but did not produce a usable observation | No measured value; a nonzero reason identity is required |
| `denied` | The operating system or policy refused the observation | No measured value; a nonzero reason identity is required |
| `unsupported` | This adapter does not implement the metric on this platform | No measured value; a nonzero reason identity is required |

An unavailable metric is never represented as a measured zero. A present
metric is accepted only when the descriptor marks it directly observed.
Boolean and parts-per-million values also pass their fixed range checks.

Rules can require presence, require false, enforce an inclusive range, limit a
pre/post absolute delta, or require stable source and subject identity. The
`same_source` rule compares the stable source identity, not per-sample
provenance. Provenance identifies the individual sample or probe event and may
legitimately differ between pre-run and post-run observations from the same
source. Missing, denied, and unsupported required metrics retain distinct
rejection bits.

The portable reason identity is a canonical nonzero digest, not embedded human
text. It binds an unavailable record to a reason class without putting an
unbounded message into the pointer-free contract. A present record carries no
reason identity, so its fixed reason field must be all zero. The macOS JSON
adapter additionally retains a bounded human-readable reason for unavailable
metrics; present JSON metrics carry no reason. That text is diagnostic context,
not a substitute for the portable reason identity.

Metric ranges are unit- and metric-specific. A present logical CPU count is at
least one. Physical host and accelerator temperatures are signed millidegrees
Celsius: a negative temperature is valid, but a value below absolute zero
(`-273150` millidegrees Celsius) is not. Availability, rather than the sign or
a fabricated numeric sentinel, states whether a measurement exists.

## Host and accelerator planes

The contract keeps host and accelerator observations in separate planes.
Declared host metrics include monotonic time, logical CPU count, CPU busy, CPU
idle and external activity, process CPU/RSS, available memory, paging and
swap, power source, low-power mode, thermal constraint, and CPU
temperature/frequency/power/energy.

Declared accelerator metrics include device presence, CPU fallback,
utilization, allocated/committed/resident memory, queue depth,
temperature/frequency/power/energy, and device time. Declaring these IDs does
not claim that the current adapter can observe them.

Every record binds `observed_at_ticks` to a nonzero sample-clock identity. That
field answers when the adapter sampled the record. Only a present
nanosecond-valued metric also carries a nonzero value-clock identity describing
the clock that produced its numeric value. Non-time metrics and unavailable
time metrics carry no value-clock identity.

Host monotonic time and accelerator device time are therefore not
interchangeable. The reference tests retain distinct value-clock identities,
and host elapsed time is derived only when the pre/post host time values name
the same value clock and do not regress. The presence of both clock identities
does not assert that two clocks are calibrated or convertible.

Accelerator and mixed plans also carry explicit fallback evidence. A selected
accelerator run becomes nonpublishable when the workload receipt does not prove
fallback absent. CPU-only plans mark fallback not applicable.

## Download-free reference

The canonical example reuses the retained typed-perception workload:

- three profiles: vision, audio-window, and temporal-video;
- six fixed items;
- exact correctness and zero-orphan gates; and
- no model or artifact download.

The reference observer supplies deterministic records so Zig and the
independent verifier can reproduce the same roots. Its elapsed value verifies
the host time metric's value-clock and report composition only; it is not
wall-clock performance evidence.

Run the focused gate with:

```sh
zig build native-observation-test -Dmetal=false
```

The gate covers portable contract and runner tests, the canonical reference
report, independent verification, the macOS observer parser/capture tests, and
the existing paired-harness parser regression tests.

## Host JSON observers

`bench/native_observation_common.py` owns the fixed eleven-metric registry,
record validation, bounded reason and provenance rules, stable source
projection, and platform-shaped execution context. `bench/native_observer.py`
remains the compatible dispatcher and macOS parser facade. Every adapter emits
the same metric universe:

- host monotonic time and logical CPU count;
- total CPU busy, CPU idle, and CPU used outside the observed workload process
  group;
- process resident bytes;
- available memory and swap used;
- power source, low-power mode, and thermal constraint.

On macOS, it reads named system sources through fixed absolute commands and
bounded output: `pmset`, `top`, `vm_stat`, `sysctl`, and `ps`. Raw command
output is not copied into the observation. Stable source identity is kept
separate from per-capture provenance. Provenance retains command identity, time
bounds, exit status, byte counts, and output digests for that sample.
Malformed output is `missing`, a permission failure is `denied`, and a metric
without an adapter is `unsupported`. Each unavailable JSON record also carries
a bounded readable reason; a present record carries no reason.

On Linux, `bench/native_observer_linux.py` reads only the fixed
`/proc/meminfo` path and directly reports `MemAvailable` as
`host_available_memory_bytes`. The read retains at most 64 KiB plus one
overflow-detection byte. The parser requires strict ASCII, exactly one
`MemAvailable: <unsigned integer> kB` field, and checked KiB-to-byte conversion
within signed 64-bit range. Missing, denied, malformed, duplicate, wrong-unit,
overflow, and oversized results remain unavailable; no raw file contents enter
the observation. Stable identity binds the path, parser schema, and read bound,
while each event retains timestamps, status, byte count, and content digest.

The historical macOS JSON schema remains
`glacier.native-observation/macos-v1`. Other platform adapters use
`glacier.native-observation/host-v1`; this is a new versioned diagnostic
envelope, not a reinterpretation of the macOS value. On a platform without a
selected adapter, the dispatcher reports only the portable runtime monotonic
clock and logical CPU count and leaves the remaining metrics explicitly
`unsupported`. Non-Darwin execution does not request a POSIX process-group ID,
so future Windows adapters do not inherit a Unix-only runtime call.
Host V1 also records the actual operating system, `native` versus `simulated`
capture mode, and publication eligibility. An adapter injected across operating
systems remains useful for parser/model tests but is explicitly nonpublishable.

The strict `pmset`, `vm_stat`, `top`, and external-process CPU parsers were
extracted into this shared module. The existing paired harness now delegates to
the same parser seam while retaining its own campaign admission and pairing
policy. This avoids two different interpretations of the same macOS source
fields. The focused gate includes a native read-only macOS smoke when it runs
on Darwin.

Linux parser and injected-adapter tests run on every Python host. A native Linux
job makes the smoke mandatory with:

```sh
GLACIER_REQUIRE_NATIVE_OBSERVER=Linux \
  python3 -m unittest bench.tests.test_native_observer_linux
```

The command fails instead of silently skipping when the requirement is set on
the wrong operating system. Cross-host parser fixtures and cross-compilation
remain implementation evidence, not native Linux observation evidence.

## Native macOS Metal readiness

The focused Metal adapter runs only on a native macOS host with Metal enabled.
It constructs one fixed in-memory 37x64 INT4 matrix-vector workload, dispatches
it exactly once across the entire hard gate, and compares the result with the
CPU oracle. The remaining Zig and Python mutation checks use synthetic values;
they do not issue additional GPU work.

Run the hard gate with:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-observation-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

The gate fails rather than skips when a native Metal device, completed command
buffer, valid GPU start/end timestamps, correctness, zero leaked weight
ownership, or explicit no-fallback evidence is unavailable. Its diagnostic
report binds the W5 descriptor, plan, probe/pre/post bundles, workload receipt,
run report, device and placement identities, dispatch receipt, output root, and
one-queue/one-invocation cardinality. The live device context includes the Metal
registry identity, `currentAllocatedSize` before and after the dispatch, and
command-buffer GPU timestamps.

These fields establish execution readiness for that fixed operation on that
host session. They are not throughput, latency, or any other performance claim.
The timestamp-derived device duration is checked for internal consistency but
is not promoted as a benchmark sample. `recommendedMaxWorkingSetSize` is
capacity context only, never current usage or an admission ceiling. The adapter
leaves accelerator utilization, committed bytes, resident bytes, queue depth,
temperature, frequency, power, and energy explicitly `unsupported`.

The independent Python verifier checks bounded JSON, semantic composition, and
corruption or substitution of the self-asserted live capture. The report has no
signed or hardware-backed origin anchor, so successful verification is not
cryptographic authenticity or historical attestation. The repository currently
retains the implementation and its verifier, not an addressable native Metal
result. A passing invocation is native evidence only for the exact host and
session that produced it until a raw artifact is retained under the evidence
policy. W5b therefore remains open.

### Metal device lifecycle evidence

The selected Metal context also installs a real
`MTLCopyAllDevicesWithObserver`. Its fixed snapshot validates initial
membership by registry ID and keeps removal-requested, removed, and exact
command-buffer-removed as distinct sticky source facts. Exact command-buffer
removal requires native status/domain/code `5/1/11` and is fenced before any
test-only overlay; generic failures do not qualify. New work fails closed after
a loss fact. The portable
[Device Lifecycle Observation V1](DEVICE_LIFECYCLE.md) contract maps those
facts into a newer `unavailable` or `lost` inventory entry without granting
resource recovery or migration authority.

The actual built-in M1 development-host correctness run observed only initial
membership and an unchanged lifecycle snapshot around one real successful
Metal command. It did not exercise removal-requested, removed, or code `11`.
Synthetic lifecycle fixtures and the isolated published-error overlay are
separate, nonphysical evidence classes.

## Evidence and claim boundary

W5a proves:

- the fixed portable ABI and canonical identities;
- all four availability states and unavailable-not-zero behavior;
- stable source identity distinct from per-sample provenance, plus canonical
  unavailable-reason identity;
- family-neutral fail-closed admission and at-most-once workload invocation;
- retained post-run contamination and explicit rejection reasons;
- separate host and accelerator planes, per-record sample clocks, time-metric
  value clocks, placement, and fallback state;
- one download-free three-profile/six-item reference campaign; and
- one shared bounded macOS host-observer implementation.

W5a does not prove native workload throughput or latency, direct GPU
utilization, device residency, CPU or GPU temperature, effective frequency,
power, energy, broad platform support, soak behavior, or performance
improvement. Cross-compiling the portable contract for Linux, Windows, or
FreeBSD proves source and build portability only. It is not native observation
evidence for those systems.

The post-W5a Linux slice proves the bounded parser, adapter dispatch seam, and
all availability/error mappings with injected sources. A native Linux smoke is
still required before publishing Linux machine evidence.

The Metal readiness slice proves that its fixed correctness-gated INT4 command
can execute once with a completed receipt and the named diagnostic fields on a
native host. It does not turn those fields into a retained performance result,
broader backend certification, or support for another device or operating
system.

The W6a report foundation separately proves a versioned allocation-free codec,
deterministic synthetic reference runner, measured-only summary recomputation,
zero-orphan closure, independent Python decoding, mutation rejection, and
portable host/cross-target compilation. It does not execute the bounded Metal
load producer, retain a native workload artifact, observe physical utilization
or residency, or establish native behavior on a cross-compiled target.

## Contributor-ready next slices

Each adapter can merge independently when it preserves the V1 metric meaning
and availability rules:

1. retain the required `/proc/meminfo` smoke on a native Linux host;
2. add one Windows or FreeBSD host adapter without calling platform commands
   from the portable core;
3. add direct macOS CPU power, temperature, frequency, or energy observation
   only through a trustworthy named API, retaining permission and absence
   outcomes;
4. retain an addressable Metal readiness artifact for a named host/device while
   preserving diagnostic-only claim scope;
5. add direct accelerator utilization or memory-residency evidence without
   deriving it from logical resource claims; or
6. replicate the bounded W6b production workload on another native
   operating-system/backend pair while preserving every rejected observation,
   explicit unavailable metric, and machine-scoped claim.

A contribution should name its source, unit, subject, sample-clock identity,
bounds, permission behavior, native acceptance command, and nonclaims. A
present time-valued metric must also name its value-clock identity; other
metrics must not. Neither field by itself claims cross-clock calibration. A
contribution must keep stable source identity separate from event provenance,
retain a nonzero portable reason identity only for unavailable records, and
respect metric-specific signed ranges. It must never turn compilation, logical
accounting, or an unavailable sensor into physical evidence.
