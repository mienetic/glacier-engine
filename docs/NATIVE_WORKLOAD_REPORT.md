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

The authoritative single-file publication boundary for retained native-load
evidence is `.glpub`. Its 56-byte fixed little-endian header contains magic
`GF1PUB01`, publication ABI `0x4746315000000001`, exact total length, zero
flags, canonical-manifest length, envelope length, and the fixed 128-byte
footer length. The body is canonical compact ASCII JSON—with sorted keys,
compact separators, and one trailing newline—followed by the exact binary
envelope. The footer contains, in order, the raw envelope SHA-256, raw
canonical-manifest SHA-256, a domain-separated publication identity over the
header and both component digests, and a domain-separated seal over the
header, both body sections, and the first three footer digests.

The strict offline decoder accepts no compatibility JSON spelling: it rejects
duplicate keys, non-finite numbers, bytes that are not the one canonical
encoding of the decoded value, unknown flags, empty or over-bound sections,
length disagreement, truncation, trailing bytes, digest substitution, identity
drift, and seal mismatch. A successful decode returns the exact envelope and
manifest bytes under one publication identity. The raw SHA-256 of the whole
encoded bundle is a separate addressable bundle identity.

The native-load publication verifier then applies the workload-specific layer
without probing the current host. It requires the exact capture and
publication-context schemas and cross-binds the retained profile, supported
operating system, producer digest and size metadata, and envelope length and
digest. It independently recomputes the machine fingerprint, challenge digest,
domain-separated pre/post environment roots, eligibility policy and decision,
exact report summary, claim scope, and limitations. The retained producer
digest, machine fingerprint, challenge, system, and profile are the inputs
supplied to the existing envelope verifier. Producer size is integrity-bound
capture metadata and an exact manifest alias, not an offline measurement of an
available executable. A structurally valid `.glpub` with a substituted but
consistently resealed context therefore still fails when a field cross-bound to
the envelope, retained environment, or derived summary no longer agrees.

Before replacing a destination, the bounded writer verifies the full encoded
bundle, writes and synchronizes a temporary file in the destination directory,
and atomically replaces that one path. This is a single-file visibility
boundary. The writer does not synchronize the parent directory. It is not an
atomic protocol for the legacy envelope/manifest pair and does not prove crash
recovery or physical power-loss durability. The digest identities establish
integrity and exact composition, not signer authentication, trusted
provenance, or capture truth. The codec and writer are integrated primitives;
the manual native-load target emits `.glpub` only when
`-Dunary-server-native-load-publication-output=PATH/report.glpub` is selected.
Verify that retained file without a producer or current-host probe with
`python3 bench/native_unary_server_load.py --verify-publication
PATH/report.glpub`.

The Phase F1 unary load producer embeds a complete Native Workload Report V1
inside a profile-specific transport outer envelope. The generic W6 verifier
validates the inner report; the dedicated native-unary verifier additionally
validates request-to-transport correlation, owner generations, completed HTTP
handles or the exact rejected semantic tuple, applicable work and
output/terminal/completion roots, HTTP timing boundaries, exact serving
closure, producer challenge, and capture-environment eligibility. Passing only
the inner verifier is therefore not complete Phase F1 load evidence.

The default profile retains 8 warmup and 64 measured all-completed records.
The same target and artifact select
`-Dunary-server-native-load-profile=retention-capacity-v1` for 8 completed
warmups followed by exactly 32 completed and 32 HTTP 429 `service_capacity`
measured outcomes, balanced `4/4` in each of eight flows. Its transport
sidecar preserves enqueue, dispatch, owner, HTTP, and retirement observations
for all 72 requests. Its embedded W6 capacity-rejected records retain only
arrival, terminal, and settlement with no queue slot or logical ownership, as
required by the backend-neutral V1 outcome.

The same target and artifact also select
`-Dunary-server-native-load-profile=queued-receive-timeout-v1`. Eight
sequential warmups complete before eight deterministic measured epochs, each
with two running requests that complete after six accepted FIFO peers reach
their exact 2-second queued receive deadline. Across the measured cohort this
is 16 completed and 48 timed-out attempts; flow rotation gives every flow
exactly `2 completed / 6 timed_out`. Exact closure retains
accepted/enqueued `72`, dispatched/completed `24`,
failed/queued-receive-timeout `48`, queue/running high-water `6/2`,
pause/resume `8/8`, 24 completed Service records, event ordinal `184`, and zero
live connection, Service, Scheduler, and Bank ownership.
The verifier admits client arrival to server timeout only in `2..4` seconds,
enqueue to timeout at no more than 3 seconds, and timeout to
peer-close/no-response transport settlement at no more than 1 second.
Settlement requires zero response bytes and accepts a zero-length read or
connection reset/abort. These are campaign-admissibility bounds, not general
runtime latency promises. The configured timeout and all three caps are bound
into the canonical profile identity:

```text
glacier-f1-native-unary-load-profile/queued-receive-timeout-8-warmup-16-completed-48-timed-out-8-flow-2-worker-6-pending-2000000000ns-timeout-4000000000ns-observation-cap-3000000000ns-queue-cap-1000000000ns-settlement-cap/v1
```

A queued-timeout W6 record has only arrival, terminal, and settlement,
not-applicable correctness, and no Bank, work, dispatch, or output. Its outer
record retains the client-observed canonical request root, an opaque
domain-separated digest of the raw outbound HTTP bytes, exact
enqueue/lease/`.queued_receive_timeout` evidence, and independently
recomputable transport-semantic, terminal, and completion roots. The socket
emits only `.queued_receive_timeout`, never a separate `.retired` event; any
`retired_*` sidecar fields are profile-defined aliases of that terminal event.
The raw outbound bytes are not retained. The queued socket is never
server-parsed, so request-to-lease association proves the campaign's
deterministic
single-outstanding client-plan/transmit correlation rather than server-parsed
request attestation.

For this transport profile, the first three W6 timing distributions are
explicitly completed-only: arrival to FIFO accept/enqueue, FIFO enqueue to
worker dispatch, and HTTP first positive read. Their verified sample counts
are 64 for the default profile, 32 for `retention-capacity-v1`, and 16 for
`queued-receive-timeout-v1`. Capacity rejections and queued timeouts remain in
the 64-attempt terminal/outcome accounting but are not relabelled as samples
for stages they never completed. The capture manifest and CLI expose these as
`completed_*_{sample_count,p99_ns}` fields.

For each rejection, the sidecar `response_handle_sha256` is a
domain-separated producer observation over the raw HTTP response. It is
opaque to the offline verifier because the envelope retains only its byte
count, not the raw bytes, so the verifier cannot reconstruct or recompute that
digest. The rejected-only sidecar `output_sha256` slot instead holds a
separately domain-separated semantic root that the verifier independently
recomputes from the request SHA-256, `service_capacity`,
`same_request_after_backoff`, HTTP 429, and response byte count. This is not a
model-output claim: the embedded W6 output root remains zero. The sidecar
completion root binds both the opaque raw-response digest and semantic root.
Service terminal-record capacity is exactly 40 and final active ownership is
zero. This proves retained-record capacity saturation, not
transient/general/open-loop overload or queued-timeout behavior. The queued
receive-timeout profile separately proves deterministic closed-loop queued
pressure, not explicit open-loop/transient/general overload, generic queue
latency, throughput superiority, first-token latency, production-model
behavior, fairness, physical parallelism, GPU behavior, or native foreign-OS
evidence. See
[Bounded Prepared-Text Unary Service](PREPARED_TEXT_UNARY_SERVICE.md) and
[Benchmarks](BENCHMARKS.md).

The hard native Metal verifier creates a fresh 256-bit challenge for every
invocation and passes it through a dedicated, sanitized environment variable;
the runner accepts no command-line arguments. The runner binds that challenge
and a domain-separated build identity derived from the producer ABI, its exact
executable SHA-256, and the external `shaders.metallib` SHA-256 into the
scenario. The verifier hashes both files before and after execution, rejects
replacement during the run, and requires exact build and challenge identities
in the emitted wire. This prevents stale-wire replay and accidental host or GPU
program substitution. It remains execution binding rather than cryptographic
code attestation: a retained wire is still self-asserted evidence whose source
commit and capture manifest must be published separately.

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

The first native accelerator producer is implemented as a finite closed-loop,
two-logical-slot Metal campaign over a fixed INT4 matrix-vector profile. It
uses the production allocation and dispatch adapter, not a fake backend or a
simulated device. One run reuses a persistent eight-buffer lease charged at
5,544 logical device bytes and emits exactly 20 records: 4 warmup and 16
measured 37x64 requests, each carrying 2,368 work units. The producer
precomputes two CPU oracles before the campaign timer starts, submits both
requests in each pair before waiting for either, validates every output within
an absolute error of `2e-5`, deliberately settles slot 1 before slot 0, and
reuses the slots only after both settle.

The producer keeps one global monotonic host sequence, retains Metal
`GPUStartTime`/`GPUEndTime` only as a same-command device duration, and samples
`currentAllocatedSize` as device-wide allocated-byte context. It revalidates
device lifecycle and identity, forbids fallback, requires unique
generation-fenced request/ticket/pin/dispatch/submission/terminal/completion
roots, and seals no report until Bank, pin, dispatch, native-command, and
native-buffer ownership are all zero. An error after native submission fails
closed and emits no partial wire; retained live state remains process-scoped
for higher-level recovery.

The two slots prove bounded logical ownership, capacity, settlement isolation,
and generation-fenced reuse. They do not prove physical GPU parallelism,
hardware queue occupancy, or command completion order. `currentAllocatedSize`
does not prove committed or resident memory. Utilization, physical queue depth,
residency, power, energy, temperature, frequency, and physical parallelism
remain `unsupported`. The result is scoped to that exact machine and campaign;
cross-compilation is not native execution evidence.

## Implemented producers and gates

The portable W6a reference remains the device-free conformance producer:

```sh
tools/zig-with-ephemeral-cache.sh build native-workload-report-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-workload-report-cross-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Those commands exercise and cross-compile the codec and synthetic runner. They
do not execute a native GPU workload.

The Phase F1 native unary producer embeds W6 in its transport envelope and is
manual on a native macOS or Linux host:

```sh
zig build unary-server-native-load-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j1

zig build unary-server-native-load-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j1 \
  -Dunary-server-native-load-profile=retention-capacity-v1

zig build unary-server-native-load-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j1 \
  -Dunary-server-native-load-profile=queued-receive-timeout-v1
```

All commands reuse the same managed-process artifact and compile root. The
capacity command's balanced completed/rejected result and the queued-timeout
command's exact completed/timed-out result are fixed-profile outcomes, not
evidence that an uncontrolled arrival stream, transient queue pressure, or
another machine would produce either ratio. The live profiles remain manual
and are not run by GitHub CI.

The W6b producer is compiled and executed only by a native macOS Metal gate:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-compile \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

The compile step opens no device. The test runner emits only the 17,996-byte
raw V1 wire. The standard-library Python verifier first applies the
backend-neutral decoder and complete summary/root recomputation, then enforces
the exact native campaign profile, pair lifecycle, generation-root uniqueness,
CPU-oracle bound, metric availability, and terminal closure. It bounds process
time and output size, rejects nonempty stderr, supplies a fresh 256-bit
challenge, and verifies the exact runner and Metal-library SHA-256 values
before and after execution. To retain an artifact, choose an explicit path:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-report-output=artifacts/native-metal-workload-report.bin
```

The verifier writes that path atomically only after the complete wire and
native profile pass. Without the option, the hard gate validates the live
campaign but intentionally retains no file. The serialized
`native-metal-suite-test` uses
`-Dnative-metal-suite-report-output=PATH` instead; focused and suite retention
options are mutually exclusive in one build invocation so independent
campaigns cannot race to replace one artifact.

## Retained production-native capture

The first retained W6b machine result is the
[17,996-byte raw report](../bench/results/native-metal-workload-report-macos-arm64-2026-07-28.bin)
with its
[capture manifest](../bench/results/native-metal-workload-report-macos-arm64-2026-07-28.manifest.json).
It references clean source commit `36011d4`, records the Apple M1/macOS/AC-power
machine envelope, binds the exact runner and Metal-library identities, and
publishes the supported raw observations and explicit nonclaims. The wire
SHA-256 is
`933d0eb3ffdffacfe0e49a95467d5d781133caadd9c9814d3b90fc19f042fa2b`;
the semantic report root is
`df7c8e20c5e682410d9bd92ff207bc180b5ef9a6b94767a4a24e9fdc60d719ec`.

This single diagnostic capture proves neither performance nor replication.
Future native runs retain distinct challenges and machine envelopes rather
than replacing or averaging this artifact.

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
