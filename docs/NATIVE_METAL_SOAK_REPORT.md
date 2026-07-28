# Native Metal Segmented Soak Report

W7b-a adds a bounded, production-native Metal soak campaign without changing
the 256-record Native Workload Report V1 ABI. Each segment remains one
independently verified W7 controlled-disruption report. A separate canonical
campaign manifest chains those reports, records process and memory boundaries,
and publishes a durable active prefix after every segment whose report and
required process-exit state verify.

## Fixed campaign

The exact W7b-a profile is:

- 12 segments split across two native worker processes;
- 6 segments per process with one planned clean exit and restart boundary;
- 50 epochs per segment, paced so epoch `e` cannot begin before
  `(e + 1) * 100 ms`;
- a minimum of 5 seconds and maximum of 15 seconds per segment;
- a parent-supervisor 180-second whole-run watchdog;
- 250 raw records and 100 completed Metal commands per segment; and
- 195,556 bytes in every independently verified inner wire.

The complete campaign therefore retains:

- 600 epochs;
- 3,000 raw records: 120 warmup and 2,880 measured;
- 1,200 completed real Metal commands;
- 600 cancel-before-submit outcomes;
- 600 malformed pre-submit rejections;
- 600 full-slot capacity rejections;
- 2,400 Bank pin acquisitions and 2,400 completions; and
- 15,000 ordered host event points.

The verifier reads the first retained host timestamp in every epoch and rejects
an epoch whose timestamp precedes its absolute cadence target. The whole-run
watchdog starts the campaign in a private process group; expiry terminates the
supervised child and its persistent worker, and the run fails. Pacing makes this
a bounded recovery and ownership soak. It is not a latency or throughput
benchmark.

## Process and challenge continuity

One worker keeps the same `MetalBackend` alive for six segments while every
segment uses fresh bounded report storage. The worker accepts exactly one
lowercase 256-bit challenge per line and emits one framed raw report. It exits
cleanly only after the supervisor closes stdin. A second worker then continues
segments 6–11.

Every segment challenge commits:

- the campaign identity;
- the segment ordinal and process generation;
- the previous manifest entry;
- the previous independently verified report;
- the scheduled action; and
- a process-scoped RSS source identity.

The scheduled action distinguishes a normal segment from a planned clean phase
end. The process-scoped source remains stable inside one worker and must change
at the restart. The worker executable and Metal shader library are hashed
before and after each process lifetime. Every inner report binds the same
component hashes through its native build identity.

This is a planned worker-process boundary inside one supervised run. It is not
supervisor-crash recovery and does not authorize a later invocation to append
to an existing active prefix.

The first challenge does not require an unretained probe. Campaign identity is
derived from the authority challenge and immutable schedule/component fields.
The first verified report supplies machine, backend, device, and placement
identities; the final manifest requires them to remain stable.

## Canonical campaign wire

The campaign manifest uses fixed-width little-endian values:

- a 640-byte plan header;
- twelve 896-byte attempt slots;
- a 64-byte footer; and
- a separate 192-byte active selector.

An in-progress checkpoint contains a contiguous prefix of verified entries and
canonical all-zero remaining slots. A nonzero slot after the zero suffix is
invalid. The selector records the verified prefix generation and never treats
an incomplete prefix as a complete campaign.

Each entry retains the exact schedule counts, duration, cumulative records and
completed commands, process generation and termination state, report roots,
machine/device identities, RSS observations, Metal allocation context, and
both predecessor roots. Entry, body, footer, and selector hashes are
domain-separated.

Verification does not trust those duplicated outer fields by themselves. It
reopens each retained inner wire, runs both inner verification layers, checks
the epoch timestamps, and requires the outer wire/report/scenario/closure roots,
build and machine/backend/device/placement identities, host source and clock,
and recomputed Metal allocation tuple and source to match the inner report
exactly.

## Memory observations

The supervisor samples worker RSS from the native macOS `ps` adapter before,
during, and after every segment. The Metal producer supplies
`currentAllocatedSize` before and after each completed command; the supervisor
recomputes the segment maximum from all 100 completed raw records. Reopening a
checkpoint and offline store verification repeat the Metal allocation
recomputation and bind it to the outer entry.

Within each six-segment process generation:

- RSS before/maximum/after must stay within 64 MiB of that process generation's
  first pre-segment RSS; and
- `currentAllocatedSize` before/maximum/after must stay within 64 MiB of that
  process generation's first observed value.

RSS is a process observation. `currentAllocatedSize` is device-wide allocation
context and can include driver or unrelated allocations. It is not owned,
committed, or resident GPU memory. Passing this finite envelope proves bounded
growth only for the declared schedule and duration; it does not prove that no
leak can exist indefinitely.

## Environment admission

The supervisor captures strict native boundaries before and after the
campaign. Both boundaries must report:

- AC power;
- low-power mode disabled;
- nominal `pmset` and Foundation thermal state;
- no admission reason; and
- the same host and boot-session fingerprint.

Canonical environment snapshots are retained as immutable JSON objects. The
active selector commits an environment envelope over the before snapshot, the
current checkpoint generation, and the final after snapshot when complete.
Partial prefixes retain exactly one before-boundary object; a complete campaign
retains exactly one before and one later after-boundary object.

Recovery and offline verification bound each lowercase content-addressed
filename to its bytes, require canonical ASCII JSON, revalidate the environment
schema, uniquely resolve the selector envelope, and, for a complete campaign,
require increasing capture times and matching admitted host boundaries. These
observations make the host state auditable but do not turn the soak into a
performance comparison.

## Durable progress store

The optional retained store contains:

- `segments/<wire-sha256>.bin`;
- `manifests/<manifest-sha256>.bin`;
- `environments/<snapshot-sha256>.json`; and
- `.glacier-workload-campaign-active-v1`.

For each segment, the supervisor writes and synchronizes the segment object,
writes and synchronizes a new immutable manifest, then writes a selector
candidate, atomically replaces the active selector, and synchronizes the
directory. Before each object or selector write, projected byte and file usage
must fit the declared bounds. A defensive post-publication bound check follows
the selector swap; if it fails, the previous selector is restored atomically,
or the first selector is removed.

The fixed campaign store is bounded to 4 MiB and 32 regular files. Symlinks,
content-address collisions, malformed prefixes, missing objects, and component
replacement fail closed.

An interrupted run can leave an active selector naming the last published
prefix. That prefix is an audit anchor, not a resume token. Offline verification
can report it as `partial` when the retained store is still canonical; orphaned,
temporary, or unreferenced objects fail closed. A fresh campaign invocation
requires a new or empty canonical output directory and never appends to an
existing active selector.

## Verification

Run the portable campaign codec and independent Python model:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-workload-campaign-test \
  native-workload-campaign-compile \
  native-workload-campaign-cross-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Cross-compilation is source portability evidence only.

Run the pure supervisor/store tests without starting the 60-second campaign:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-soak-report-pure-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the production-native campaign:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-soak-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Add `-Dnative-metal-soak-output-dir=PATH` to retain the verified store.
When that option is present, the build gate follows the native run with offline
verification of the retained store.

Audit a retained active prefix without starting native GPU work:

```sh
python3 bench/native_metal_soak_report.py \
  --worker path/to/glacier-native-metal-soak-worker \
  --metallib path/to/glacier_native.metallib \
  --output-dir PATH \
  --verify-store
```

The command takes a shared store lock, requires the exact canonical directory
and object sets, verifies every manifest prefix and inner wire against the
supplied worker and Metal library bytes, validates the environment objects and
artifact bounds, and confirms that the active selector did not change during
the audit. Its result explicitly reports `status=partial` or `status=complete`;
it does not resume execution.

## Claim boundary

For a completed gate, W7b-a proves the fixed finite paced campaign on the
invoking macOS Metal host: native command correctness with zero CPU fallback,
controlled software disruption recovery, one planned clean worker restart,
timestamp-backed cadence, exact outer/inner evidence agreement, durable
hash-chain continuity, bounded observed RSS and Metal allocation-context growth,
strict admitted environment boundaries, exact resource closure, and zero
orphans. The parent watchdog bounds the entire supervised invocation to 180
seconds; a watchdog expiry is a failed campaign, not a successful partial run.

Offline verification proves that a retained active prefix is canonical and
internally consistent with the supplied worker and Metal library bytes. It does
not rerun Metal commands, re-admit the current host, append missing segments, or
convert a partial prefix into a completed campaign. Content hashes provide
integrity and identity binding, not a signature or remote attestation.

It does not inject physical device removal, driver failure, power loss, true
storage exhaustion, process kill during a native command, or a cancellation
storm. It does not observe GPU utilization, physical queue occupancy,
residency, temperature, frequency, power, energy, or physical parallelism.
Sampled RSS is not a continuous process high-water mark, and
`currentAllocatedSize` is not owned or resident GPU memory. The finite envelope
does not prove indefinite leak freedom. Supervisor-crash resume, those physical
faults and observations, longer soak schedules, and native-platform replication
remain later work.
