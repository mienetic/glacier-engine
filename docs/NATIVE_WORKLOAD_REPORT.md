# Native Workload Report

The native workload report is the W6 evidence boundary between a declared
workload campaign and its aggregate results. It retains every request before
aggregation, uses a versioned allocation-free binary wire, and lets an
independent implementation recompute the report from raw observations.

The report is backend-neutral. A CPU-only run, an accelerator-backed run, and
a provider or media workload may share the envelope while keeping their work
units, device placement, observers, and correctness rules distinct.

## Claim boundary

A valid report proves internal composition of:

- one exact scenario, artifact, build, machine, backend, device, placement,
  observer set, and clock set;
- every warmup and measured request retained in canonical order;
- request outcomes, host-observed lifecycle boundaries, correctness, fallback,
  logical ownership, and available device observations;
- a summary recomputed only from the measured cohort; and
- a terminal zero-orphan closure.

The digest chain detects accidental or unacknowledged mutation. It does not
authenticate who captured the observations. Native publication additionally
requires an addressable artifact, its source commit, a clean capture state,
and the declared machine-state envelope.

Outcome labels and opaque roots are producer assertions unless an external
receipt verifier is supplied for the named backend. The independent verifier
proves that those assertions are internally composed, ordered, summarized, and
closed exactly. It checks root presence and composition, not the backend-
specific content hidden behind an opaque root.

Adapter queue slots and runtime in-flight counts are logical scheduling facts.
They are not hardware queue depth, occupancy, utilization, or proof of physical
parallel execution.

## Scenario identity

`ScenarioV1` declares closed-loop or open-loop arrival policy and keeps those
campaign types separate. It binds:

- warmup and measured request counts;
- maximum logical in-flight work, adapter queue count, and flow count;
- workload, profile, artifact, and build identities;
- machine, backend, device, and placement identities;
- host observer and monotonic clock identities;
- device observer and device value-clock identities; and
- a campaign challenge plus the summary-algorithm version.

Warmup records are retained and verified but never enter measured counts,
throughput, percentiles, fairness, or resource summaries.
Every warmup request must settle before the first measured request arrives.

## Raw request observations

Each record retains an ordinal, cohort, flow, outcome, work units, and either
an adapter-local queue slot or an explicit not-applicable sentinel. Outcomes
include completed, capacity-rejected, failed, cancelled, and timed-out work.

The host event plane can retain:

1. arrival;
2. admission;
3. first host service boundary;
4. submit-call return;
5. first visible output;
6. terminal observation; and
7. settlement return.

Every present event has both a monotonic timestamp and an event sequence.
Adjacent timestamps may be equal; the sequence preserves causal order without
inventing time. Capacity rejection has no queue slot and retains only the
boundaries that actually occurred.

The sequence is global to the campaign. It is unique, cannot order a later
timestamp before an earlier timestamp, and orders request arrivals by ordinal.
Admitted requests that name the same adapter queue slot may not overlap over
their half-open `[admission, settlement)` sequence intervals. The declared
maximum logical in-flight count applies to both cohorts, even though only the
measured cohort is summarized.

Completed records bind request, ticket, pin, dispatch, submission, output,
oracle, terminal, and completion roots. They also retain correctness,
maximum absolute error, fallback status, logical Bank and native-command
facts, and any available accelerator observations.

Every admitted request has one or more balanced logical Bank acquisitions.
`bank_used_before` is the pre-admission baseline and must equal the value after
that request settles. Per-request acquisitions and completions must balance;
pin, dispatch, and native-command after-settlement counts must be zero.
Nonzero pin-before facts require admission; nonzero dispatch-before or
native-command-before facts require submit return. Their converses are not
required because backend-neutral CPU and provider records may have no native
counter.
Capacity rejection cannot claim fallback or logical ownership.

## Clock separation

Host timestamps and accelerator timestamps remain separate clock domains.
For Metal, `GPUStartTime` and `GPUEndTime` support a same-command device
duration only. They are not subtracted from host monotonic timestamps unless a
future contract names and validates an explicit cross-clock correlation
authority.

Host first service is the runtime dispatch-start boundary, not an inferred GPU
start. Host output visibility includes the runtime boundary that copied and
validated the output. Settlement includes Bank-first ownership settlement and
native finalization.

## Canonical summary

The V1 summary is recomputed from measured raw records and reports:

- attempted, admitted, completed, capacity-rejected, failed, cancelled, and
  timed-out counts;
- attempted and completed work units;
- the exact first-arrival through final-settlement interval;
- throughput as completed-work numerator over nanosecond denominator, without
  a floating-point identity;
- nearest-rank p50, p95, p99, and maximum for admission, queue, first-output,
  service, end-to-end, and available device-duration samples;
- logical in-flight high-water derived from ordered admission and settlement
  events;
- per-flow completion minimum, maximum, and spread;
- fallback and correctness counts; and
- directly sampled allocated-size context without relabelling it as residency.

No request is silently removed. A terminal outcome remains part of the raw
campaign and its corresponding measured count.

V1 requires a strictly positive measured interval from the earliest measured
arrival to the latest measured settlement. Equal timestamps remain legal
inside a record, but a campaign whose complete measured interval is zero
cannot represent a throughput denominator and is rejected.

## Metric availability

Every metric carries availability, source, clock, and reason semantics.
Unavailable values are never encoded as present zeroes. V1 reserves explicit
metric positions for:

- host CPU time;
- process resident memory;
- device duration;
- sampled device allocated-size context;
- device utilization;
- physical queue depth;
- device residency;
- power and energy;
- temperature and frequency; and
- physical parallelism.

The raw device-duration and allocated-size summaries may become present only
when their request records name and retain the corresponding observers.
Device timing is eligible only after submit returns; allocated-size context is
eligible only after admission. Partial eligible coverage produces a
deterministic `missing` aggregate instead of summing a subset or presenting
zero.
Physical queue depth, utilization, residency, power, energy, thermal,
frequency, and parallelism remain `unsupported` in the initial producer.

`currentAllocatedSize` is allocated-byte context sampled from the device. It
is not committed or resident memory. Likewise, a pin may protect a full shared
lease even when one request uses a disjoint role subset; per-request pin bytes
must not be summed into memory usage.

## Closure and verification

The closure requires:

- logical Bank usage, active pins, and active dispatches at zero;
- native command and buffer records at zero;
- acquisition and completion counts equal; and
- explicit zero-orphan status.

The decoder checks fixed wire lengths, reserved fields, enums, booleans,
event masks, causal sequences, clock rules, record ordinals, the record chain,
all semantic roots, exact summary recomputation, unsupported-metric rules, and
closure. The independent verifier must parse the wire itself rather than trust
a producer-generated JSON projection.

The first native accelerator producer targets a finite closed-loop,
concurrency-two Metal campaign over a fixed INT4 matrix-vector profile. It must
reuse one persistent eight-buffer lease, retain warmup and measured requests,
precompute CPU oracles outside the measured interval, use the production Metal
shim, and finish with zero ownership. Its result is scoped to that exact
machine and campaign; cross-compilation is not native execution evidence.

## Normative V1 wire

The V1 wire is independent of Zig struct layout. All integers are unsigned
little-endian values, booleans and enums occupy one byte, digests are raw
32-byte SHA-256 values, and every reserved byte must be zero. Binary64 values
are carried as their raw IEEE 754 bit patterns in a little-endian `u64`.

The complete length is:

```text
2,556 + record_count * 772 bytes
```

`record_count` is at most 256. The canonical reference has six records, is
7,188 bytes long, has SHA-256
`7b61707818f7a4acc0f3f66ee2c8d7299a3e1fffc4336ae3fc9d34e11c56d954`,
and is emitted without text framing by
`examples/native_workload_report.zig`.

| Block | Bytes | Order |
| --- | ---: | --- |
| Header | 40 | magic, wire ABI, length, flags, reserved, count, reserved |
| Scenario | 484 | scenario fields and root |
| Records | `772 × N` | canonical ordinal order |
| Summary | 1,856 | measured-only fields and root |
| Closure | 80 | terminal ownership fields and root |
| Report root | 32 | composition root |
| Body digest | 32 | domain-separated digest of the body |
| Footer digest | 32 | digest of header, body, and body digest |

The header layout is fixed:

| Offset | Type | Value |
| ---: | --- | --- |
| 0 | `[8]u8` | ASCII `GW6RPT01` |
| 8 | `u64` | `0x4757365700000001` |
| 16 | `u64` | exact total byte length |
| 24 | `u32` | flags, exactly `1` |
| 28 | `u32` | zero |
| 32 | `u32` | record count |
| 36 | `u32` | zero |

The component ABI values are:

| Component | ABI |
| --- | --- |
| Scenario | `0x4757365300000001` |
| Record | `0x4757365200000001` |
| Summary | `0x4757365500000001` |
| Closure | `0x4757364300000001` |
| Report | `0x4757365000000001` |
| Wire | `0x4757365700000001` |

The body begins at byte 40. Its dynamic offsets are:

```text
scenario = 40
records  = 524
summary  = 524 + 772 * N
closure  = summary + 1,856
report   = closure + 80
body_sha = report + 32
foot_sha = body_sha + 32
```

### Nested block order

`ScenarioV1` uses this order:

```text
u64 abi
u8 mode, u8 evidence, u8 summary_algorithm, u8 reserved
u32 warmup_count, measured_count, max_in_flight, queue_count, flow_count
u32 reserved
13 * digest:
  workload, profile, artifact, build, machine, backend, device, placement,
  host_source, host_clock, device_source, device_clock, challenge
digest scenario_sha256
```

`RecordV1` uses this order:

```text
u64 abi, u32 ordinal
u8 cohort, u8 outcome, u8 correctness, u8 fallback
u32 flow_id, u64 work_units, u32 adapter_queue_slot
u8 event_presence_mask, 3 reserved bytes
7 * (u64 monotonic_ns, u64 sequence):
  arrival, admission, first_service, submit_return, first_output,
  terminal, settlement
9 * digest:
  request, ticket, pin, dispatch, submission, output, oracle,
  terminal, completion
u64 maximum_abs_error_f64_bits
u8 device_availability, 7 reserved bytes
u64 device_start_f64_bits, device_end_f64_bits, device_duration_ns
digest device_source, device_clock, device_unavailable_reason
u8 allocated_context_availability, 7 reserved bytes
u64 allocated_before_bytes, allocated_after_bytes
digest allocated_source, allocated_unavailable_reason
u32 bank_acquisitions, bank_completions
u64 bank_used_before, bank_used_after_settlement
u32 pin_before, pin_after_settlement
u32 dispatch_before, dispatch_after_settlement
u32 native_command_before, native_command_after_settlement
digest previous_record_sha256, record_sha256
```

A distribution is 40 bytes: `u32 sample_count`, four reserved bytes, then
`u64 p50`, `p95`, `p99`, and `max`. A metric is 120 bytes: `u8 kind`,
`u8 availability`, six reserved bytes, `u64 numerator`, `u64 denominator`,
then source, clock, and reason digests.

`SummaryV1` uses this order:

```text
u64 abi
7 * u32:
  measured, admitted, completed, capacity_rejected, failed, cancelled,
  timed_out
8 * u64:
  attempted_work, completed_work, interval_start, interval_end,
  interval_numerator, interval_denominator,
  throughput_work_numerator, throughput_interval_denominator_ns
6 * distribution:
  admission, queue, first_output, service, end_to_end, device_duration
7 * u32:
  logical_in_flight_high_water, flow_min, flow_max, flow_spread,
  fallback_count, correctness_correct, correctness_incorrect
u8 allocated_context_max_available, 7 reserved bytes
u64 allocated_context_max_bytes
12 * metric in MetricKindV1 order
digest summary_sha256
```

`ClosureV1` uses this order:

```text
u64 abi
u32 bank_count, pin_count, dispatch_count, native_command_count,
    native_buffer_count
u64 acquisitions, completions
u8 zero_orphan, 3 reserved bytes
digest closure_sha256
```

### Enum values

Enum discriminants are declaration-order values:

- mode: `closed=0`, `open=1`;
- evidence: `synthetic=0`, `production_native=1`;
- summary algorithm: `nearest_rank_v1=0`;
- cohort: `warmup=0`, `measured=1`;
- outcome: `completed=0`, `capacity_rejected=1`, `failed=2`,
  `cancelled=3`, `timed_out=4`;
- correctness: `not_applicable=0`, `correct=1`, `incorrect=2`;
- availability: `missing=0`, `denied=1`, `unsupported=2`, `present=3`; and
- metrics: CPU time, RSS, device-duration total, allocated-size maximum,
  utilization, physical queue depth, residency, power, energy, temperature,
  frequency, and physical parallelism use values `0` through `11`.

The event-presence bits, from least significant to most significant, are
arrival, admission, first service, submit return, first output, terminal, and
settlement. `adapter_queue_slot = 0xffffffff` means not applicable.

### Device-duration conversion

Raw device start and end values are finite, nonnegative binary64 seconds in
the named device clock. End must be greater than start. V1 computes:

```text
binary64_duration = (end - start) * 1,000,000,000
duration_ns = truncate_toward_zero(binary64_duration)
```

The binary64 result must be finite, at least one nanosecond, and less than
`2^64 - 1` nanoseconds. The stored `duration_ns` must match exactly. Host and
device values are never subtracted from one another.

### Hash preimages

Semantic hashes use the same little-endian scalar representation as the wire,
omit reserved bytes and their own output field, and include raw digest bytes.
The NUL byte shown as `\0` is part of every domain:

```text
glacier-native-workload-scenario-v1\0
glacier-native-workload-record-v1\0
glacier-native-workload-summary-v1\0
glacier-native-workload-closure-v1\0
glacier-native-workload-report-v1\0
glacier-native-workload-body-wire-v1\0
glacier-native-workload-footer-wire-v1\0
glacier-native-workload-metric-unsupported-v1\0
glacier-native-workload-metric-aggregate-reason-v1\0
```

The scenario, record, summary, and closure roots hash their semantic fields in
the nested order above. A record additionally prefixes the scenario root and
ends with the previous-record root. The first previous root is the scenario
root. The report root hashes: report ABI, scenario root, record count, final
record root, summary root, and closure root.

The body digest hashes its domain followed by every byte from the scenario
through the report root. The footer digest hashes its domain followed by every
byte from the header through the body digest. Unsupported-metric reasons hash
their domain plus the metric `u8`. Aggregate reasons hash their domain, metric
`u8`, then `no_eligible_samples=1` or `incomplete_samples=2`.

Nearest-rank percentiles use rank `ceil(percentile * sample_count / 100)` over
the retained measured samples. The independent Python implementation parses
these bytes and recomputes every semantic root and summary rather than calling
the Zig decoder.
