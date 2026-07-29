# Platform portability

Glacier is intended to become a portable AI runtime, but portability is an
evidence claim rather than a property inferred from Zig source alone. A target
is not supported merely because the compiler accepts it. Native execution,
filesystem recovery, numerical correctness, device behavior, packaging, and
resource measurement require separate gates.

This document records the current evidence boundary and the architecture needed
to promote additional operating systems without weakening runtime invariants.

## Support vocabulary

- **Source-compiles**: the selected source set passes semantic analysis for a
  target. It does not prove that the complete runtime links or runs.
- **Cross-builds**: the complete declared artifact set compiles and links for a
  target. It does not prove native behavior.
- **Native-verified**: CPU correctness tests run on the named OS and
  architecture.
- **Recovery-verified**: process-death and durable-file campaigns run on a real
  filesystem on the named OS. This verifies the declared host protocol, not
  physical power-loss persistence.
- **Accelerator-verified**: a device backend passes numerical, lifetime, and
  synchronization checks against a CPU oracle on real hardware.
- **Observer-verified**: a named telemetry adapter runs on the real OS, retains
  metric provenance and explicit status for every unavailable field, and
  passes native admission/contamination fixtures. This does not by itself prove
  workload performance.
- **Supported**: the applicable compile, native, recovery, packaging, and
  backend gates are retained for a named OS/architecture/version range.

Unsupported combinations must reject explicitly. Silent fallback may be
offered only when the caller opted into it and the result records the backend
that actually executed.

## Current evidence matrix

The following matrix is deliberately narrower than the intended platform
surface.

| Target | Compile evidence | Native CPU evidence | Recovery evidence | Accelerator evidence | Current classification |
| --- | --- | --- | --- | --- | --- |
| macOS / AArch64 | Native build path exists; Metal is optional and macOS-only | Primary development-host tests exist, but no version/device support range is declared here | Retained host process-death fixtures include the 49-death ActionOutbox campaign, the 49-death R1j prepared-text source/target campaign, the W7b-b2 production-publisher/reference-recovery campaign-store gate across 27 real writer deaths, 54 controlled errno cases, and one clean control, exact predecessor/successor recovery for prepared `.glrt` publication, and eight-phase sealed `.glacier` conversion with independent all-page validation; physical storage and power-loss evidence remain absent | Portable Zig fake/state tests and an independent Python oracle model deterministic device contracts without a GPU; the native gates use a real `MTLDevice` and real `MTLBuffer` resources, submit and verify one fixed 37x64 INT4 readiness branch, retain zero-command reject/cancel branches, and exercise two disjoint native commands with deliberate out-of-order settlement after both complete, but no device support range is declared | Development host, not a broad platform certification |
| Linux / x86_64 | Full musl artifact and `test-compile` cross-build gates pass in `ReleaseSafe`; hosted Ubuntu also compiles the complete GNU host frontier before runtime | Hosted Ubuntu runs the ReleaseSafe runtime and language-interop gates; no CPU performance, packaging, machine range, or retained observation artifact is claimed | Hosted Ubuntu exercises POSIX restart paths, exact predecessor/successor recovery for prepared `.glrt` publication, eight-phase sealed `.glacier` conversion with independent all-page validation, and the 81-case controlled store-fault matrix through acquired descriptor-relative directory authority that preflights before namespace mutation and owns one sync-capable handle through commit; the ephemeral runner and its real `fsync`/process-death calls are not retained filesystem, physical-fault, or power-loss evidence | No retained Linux accelerator backend | Hosted native correctness/recovery CI plus cross-build evidence; not native-supported |
| Linux / AArch64 | Full musl artifact and `test-compile` cross-build gates pass in `ReleaseSafe`; the core GNU source probe also passes | Bounded `MemAvailable` adapter is architecture-neutral; native smoke is not retained | The strict initial-recovery primitive and full R1j gate are supported, but no native Linux filesystem campaign is retained | No retained Linux accelerator backend | Cross-build and observer-implementation candidate; not native-supported |
| Windows / x86_64 GNU | Full artifact and `test-compile` cross-build gates pass in `ReleaseSafe`; read-only model mapping and process fixture seams compile | Not established by cross-compilation | No native Windows durable-file adapter or recovery campaign | No Windows accelerator backend | Cross-build candidate; not native-supported |
| FreeBSD / x86_64 | Full artifact, `test-compile`, generated-media conformance, R1j, and sealed model-conversion worker cross-build gates pass in `ReleaseSafe` | Not established by cross-compilation | Strict initial recovery fails closed until an atomic no-replace primitive is implemented; no retained native FreeBSD filesystem campaign | No retained FreeBSD accelerator backend | Cross-build candidate; not native-supported |
| Android / AArch64 | Core source-compilation probe passed | No device or emulator execution evidence | No Android lifecycle/storage recovery campaign | No Android accelerator backend | Research target; not supported |
| iOS / AArch64 | Core source-compilation probe passed, including strict initial-recovery API availability | No device execution or application-lifecycle evidence | No full process or iOS protection-class/background recovery campaign | No iOS backend has been verified; the macOS Metal bridge is not iOS evidence | Research target; not supported |
| WASI / wasm32 | Core source-compilation currently fails | Not established | Durable local recovery is outside the current contract | None | Unsupported; requires a reduced edge profile |
| Other edge systems | No named target matrix yet | Not established | Not established | None | Unscoped |

W5a does not change a classification in this matrix. It adds one portable
native-observation contract and runner plus a bounded macOS read-only host
adapter. The focused gate includes a native macOS observer smoke on the
development host. The first follow-up adds a platform-neutral JSON seam and a
strict bounded Linux `/proc/meminfo` `MemAvailable` adapter implementation.
Its parser, availability mapping, and injected dispatcher tests run on any
Python host. Hosted Linux correctness is now gated, while the mandatory
observation artifact and reproducible machine envelope still need retained
native evidence. Portable records separate stable source identity from
per-event provenance and retain a nonzero reason identity only when
unavailable; present records carry none, and host JSON adds a bounded readable
reason only when unavailable.

The portable Stage-5 device slice also does not change a classification in this
matrix. `DeviceCapabilityV1`, canonical inventory entries, execution-plan-bound
requirements, and selection receipts provide deterministic allocation-free
selection before resource or scheduler mutation. The native macOS Metal adapter
projects stable device facts into that contract, binds one local discovery
epoch, and revalidates the selected fingerprint and registry identity against
the same readiness device. See
[Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md).

The follow-on [Device Allocation Lease](DEVICE_ALLOCATION_LEASE.md) and
[LeaseTree Device Allocation](LEASE_TREE_DEVICE_ALLOCATION.md) contracts add
receipt-bound and execution-owned quote/charge/materialize/release/recovery
lifecycles. Their
[native Metal adapter](NATIVE_METAL_ALLOCATION.md) creates and directly
inspects real resources on the executing host through both ownership paths,
but does not broaden the supported platform/device classification or claim
residency. The LeaseTree coordinator shares address-stable tree and publication
sequence pointers with its execution owner; that owner must externally
serialize coordinator calls with every other mutation of those shared values.

The serialized native suite's readiness gate makes exactly one real GPU
dispatch in total for a fixed synthetic 37x64 INT4 operation and requires
CPU-oracle correctness, Metal registry identity, `currentAllocatedSize`,
command-buffer GPU timestamps, ownership closure, no fallback, and composed
roots. Its allocation gate creates, inspects, and releases real buffers but
also contains a separate four-buffer LeaseTree case that pins the exact object
set. The adapter issues a generation-fenced
`MetalMatvecDispatchRequestV1`; its root, never the raw attempt root, is the
pin's dispatch-request root. Core seals `DispatchPinIntentV1`, calls reserve
before Bank mutation, aborts exactly on atomic acquisition failure, and
validates callback/source identity before binding the lease, request, intent,
and pin. Valid preflight submits one real INT4 command into an adapter-owned
async slot and returns a generation-fenced `MetalAsyncDispatchTicketV1`.
The adapter now has two fixed slot-local lanes: exact replay does not commit
again, a third distinct request rejects before native mutation, poll/wait
authenticate the selected command and buffers, and either slot may settle
first. The isolated native pressure proof submits both slots, observes two live
native records, waits for both commands, deliberately settles B before A,
checks both CPU oracles, and closes every record, pin, and buffer. This is
bounded coexistence and settlement isolation, not physical GPU parallelism or
command-completion-order evidence. A pure
`cancelled_before_submit` or malformed `rejected_before_submit` branch uses
zero submission, backend-completion, and output roots and the same settlement:
core consumes the private Bank pin, then a private callback finalizes the exact
native record when present, atomically clears adapter state, and records a
replay tombstone. Public
`acknowledgeDispatchCompletion` only verifies compatibility; it grants no
authority and clears no state. Rejection may inspect the real native
device/resources but creates and submits no command buffer. Cancellation is
native-free after the sealed binding even though its native gate retains real
context/resources; both reject and cancel issue zero GPU commands. Portable
Zig fake/state tests and the independent Python oracle model these deterministic
contracts without a GPU. The corrected tiled FP16 matmul path is
separately CPU-oracle-tested on asymmetric partial-edge shapes and rejects
zero, overflowing, short, or oversized buffer geometry without caller-output
mutation. These are bounded allocation/lifetime/correctness/readiness results,
not throughput, latency, or performance results.
W7a adds a finite controlled-disruption campaign on the same production path.
Its 50 fixed epochs retain 250 ordered records around 100 CPU-oracle-checked
real commands, 50 cancel-before-submit outcomes, 50 malformed pre-submit
rejections, and 50 full-two-slot capacity rejections. Every epoch returns to
the same persistent eight-buffer boundary before reuse, and final closure
proves 200/200 pins with zero live ownership. Those branches are controlled
runtime conditions, not physical removal, driver crash, power loss,
duration-bounded soak, performance, residency, utilization, or physical
parallelism evidence.
W7b-b3 separately runs 64 paired-thread waves around the same bounded
production adapter. In each wave, both real host threads reach the ready
barrier before one shared release store. Its 128 cancel-before-submit records
and 64 capacity probes issue zero GPU commands; 16 correctness controls
execute real Metal commands and pass CPU oracles. The barrier proves the
ready-before-release boundary, not simultaneous scheduling or execution,
critical-section overlap, GPU parallelism, kernel cancellation, preemption, or
performance.
W7b-b4 separately validates a real host-process death while one registered
Metal command remains nonterminal at a controlled event boundary. The
fault-linked victim reports committed-or-scheduled status, completion
unobserved, four live native buffers, one live command, and four active
allocation references before the controller sends real PID-only `SIGKILL` and
requires `-9` plus EOF. A distinct production-linked W6 process then completes
20 CPU-oracle-checked real Metal commands. The private `MTLSharedEvent` signal
`1`/wait `2` barrier is build-isolated and synthetic; the command, OS kill, and
fresh control are real. This proves no active-kernel interruption, output or
state recovery, complete resource reclamation, device loss, performance, or
physical GPU telemetry.
The serialized suite also runs a build-isolated reconciliation gate: a real
Metal command completes physically before a separate test-only `.error`
overlay drives the production quarantine and settlement path. Production
artifacts export no fault controls, and the overlay is not evidence of a
physical device, driver, or hardware failure.
`recommendedMaxWorkingSetSize` is capacity context only; physical-page
commitment/reclamation and residency authority, device-loss recovery,
multi-GPU scheduling, utilization, committed/resident bytes, queue depth,
temperature, frequency, power, and energy remain open or unsupported. The
verifier checks composition/corruption of self-asserted live output, not
cryptographic origin. No W5 readiness result or device range is retained here;
the separate W6b production-workload wire covers one exact Apple M1 session
only. W7a, W7b-b3, and W7b-b4 execute on demand but do not yet have committed
retained machine artifacts. Cross-compilation remains source/build evidence
rather than native OS or device support. W5b and non-macOS native observer
coverage remain open.

Run the serialized native device suite on macOS with:

```sh
metal_dir="$(mktemp -d)"
tools/zig-with-ephemeral-cache.sh build \
  native-metal-suite-test \
  profile-device-compile -Dmetal=true -Doptimize=ReleaseSafe \
  -Dmetal-output-dir="$metal_dir" -j2
```

### Probe record

On 2026-07-24, Zig 0.15.2 was used for source-only probes of
`src/core/root.zig` and full artifact cross-builds in `ReleaseSafe` mode. The
source probes used `--test-no-exec` and `-fno-emit-bin`.

Passed:

```sh
zig test src/core/root.zig -target x86_64-linux-gnu -OReleaseSafe --test-no-exec -fno-emit-bin
zig test src/core/root.zig -target aarch64-linux-gnu -OReleaseSafe --test-no-exec -fno-emit-bin
zig test src/core/root.zig -target aarch64-linux-android -OReleaseSafe --test-no-exec -fno-emit-bin
zig test src/core/root.zig -target aarch64-ios -OReleaseSafe --test-no-exec -fno-emit-bin
```

The full declared artifact set also cross-built for:

```sh
zig build -Dtarget=x86_64-linux-musl -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=x86_64-linux-musl -Dmetal=false -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=aarch64-linux-musl -Dmetal=false -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=x86_64-windows-gnu -Dmetal=false -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-freebsd -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=x86_64-freebsd -Dmetal=false -Doptimize=ReleaseSafe
```

Those historical commands recorded the two roots separately. Current
`tools/verify.sh matrix` runs pass `install`, `install-benchmarks`, and
`test-compile` to one Zig invocation per target. `tools/verify.sh affected`
uses the same full plan for shared roots and unknown inputs, but audited
changes select an ordered union of named core, CPU, durable, device, and
host-tool compile profiles instead. Shared producer APIs use a complete
consumer compile closure that includes retained demos and benchmarks without
installing those products. Full steps dominate compile profiles independently
per target.

The focused experimental C contract libraries, Zig ABI tests, and independent
C11 consumer also compiled and linked for the four full cross-build targets:

```sh
tools/zig-with-ephemeral-cache.sh build contract-c-compile \
  -Dtarget=x86_64-linux-musl -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build contract-c-compile \
  -Dtarget=aarch64-linux-musl -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build contract-c-compile \
  -Dtarget=x86_64-windows-gnu -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build contract-c-compile \
  -Dtarget=x86_64-freebsd -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Each focused cache was removed after the command; final sizes were about
89–121 MiB in this observation. These are compile/link observations. The
resulting foreign binaries were not executed on the macOS host. This is a dated
local observation with reproducible commands, not retained multi-host or native
evidence.

The Windows gate became possible after introducing one shared read-only
POSIX/Windows model-file mapping, compile-time rejection for unsupported
POSIX-only durable adapters, canonical `u32` process-ID normalization, and
platform-specific hard-termination fixtures. These changes establish G1
compile/link evidence only; no Windows binary was executed.

`wasm32-wasi` still fails the core source probe because the current test surface
assumes threads, 64-bit atomics, libc `fsync`, and a 64-bit `usize` in several
fixture paths.

These results prove only the named compile/link observations. They do not
promote Linux, Windows, FreeBSD, Android, or iOS to native support.

On 2026-07-26, the additive W4a `typed-workload-compile` target also passed in
`ReleaseSafe` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-windows-gnu`, and `x86_64-freebsd`. That focused target compiles the
typed-perception test root and canonical report runner; no foreign binary was
executed. It confirms portability of the new source slice, not native runtime
support or physical CPU/GPU behavior.

On 2026-07-26, the additive W4b-a `typed-tool-workload-compile` target likewise
passed in `ReleaseSafe` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-windows-gnu`, and `x86_64-freebsd`. That target compiles the
pointer-free tool records, fixed-storage transactional harness, typed-tool
campaign tests, and canonical report runner. The macOS host did not execute
the foreign binaries, so this is source/compile portability evidence only; it
does not establish native threading, CPU/GPU behavior, sandboxing, or external
tool dispatch on those systems.

On 2026-07-26, the additive W4b-b `action-outbox-record-compile` target passed
in `ReleaseSafe` for the same four targets. It compiles the fixed-storage
record/recovery tests and canonical report example. No foreign binary was
executed, no filesystem adapter was exercised, and no external action was
dispatched; this establishes source/compile portability only.

The W4b-c durable store is implemented only for the declared POSIX durable-file
capability. Its focused source gate compiles for the checked Linux, BSD,
illumos, iOS, and Windows targets, but unsupported targets compile out the
adapter and return `UnsupportedPlatform`; this is not native filesystem
evidence. On the macOS development host, the separate recovery gate exercises
3 initialization, 40 append, and 6 repair `SIGKILL` boundaries. No Windows
durable-file implementation or native Windows recovery campaign exists.

On 2026-07-26, the W4b-d `action-outbox-dispatch-test` passed on the macOS
development host in `ReleaseSafe`. It composes pointer-free portable adapter
values with the POSIX `StoreV1` driver and a bounded same-process fake authority.
The fake keeps an opaque synthetic credential, performs no external I/O, and
uses deterministic append faults rather than a new process-death campaign.
This focused result adds no native Linux, Windows, or FreeBSD execution claim,
no real-credential or OS-sandbox/security proof, no cryptographic-origin or
fake-service-restart-persistence proof, and no CPU, GPU, performance, power,
network/provider/tool-effect, or external-exactly-once evidence. The W4b-c
49-death campaign remains the applicable ActionOutbox recovery evidence in the
matrix above.

Prepared `.glrt` production writes now use the same acquired-directory
capability through a dedicated runtime-image publisher. It retains one
directory-scoped lock, one bounded candidate, synchronized candidate
validation, atomic replacement, and a directory commit. The native process
campaign kills a separate worker at provider, candidate, replacement, and
commit boundaries; fresh recovery must independently decode an exact
predecessor or successor and leave no candidate. This is filesystem/process
recovery evidence only. Static link, permission, corrupt-target, and identity
checks do not make a caller-writable directory an adversarial security
boundary.

The additive W4b-d `action-outbox-dispatch-compile` gate also passed in
`ReleaseSafe` for Linux x86_64/AArch64 musl, Windows x86_64 GNU, and FreeBSD
x86_64 after the canonical reference-report executable was added. Those
foreign binaries were compiled, not run. This establishes source and build
portability only; it exercises no native filesystem recovery, mutex
interleaving, credential backend, sandbox, service process, or external I/O on
those targets.

On 2026-07-28, the accelerator-independent POSIX-host W7b-b2 gate ran the
production campaign-store publisher on the macOS development host. It used real
subprocesses, advisory locking, native filesystem calls, and 27 writer
`SIGKILL` deaths, followed by fresh-process reference prepared roll-forward and
strict verification. Its 54 `EIO` and `ENOSPC` cases are deterministic
software injection. The gate runs no model or GPU command and does not
establish a general production recovery API, physical disk exhaustion,
controller/media failure, power-loss persistence, or native recovery on
another OS. The report-codec tests and standalone Zig report verifier also
cross-compile, but foreign compilation is not native filesystem evidence.

The build graph now also provides `native-observation-cross-compile` for
Linux x86_64/AArch64 GNU, Windows x86_64 GNU, and FreeBSD x86_64. It compiles
the portable observation contract, runner, and reference report without
executing the foreign products. Passing this gate is G1 source/build evidence
only. It cannot establish the behavior of a target's clock, CPU/load parser,
memory source, power/thermal source, accelerator, permissions, or workload.

## Existing portability seams and blockers

Useful seams already exist:

- public `glacier` and `glacier_core` Zig package modules let dependency
  consumers import runtime code without running or installing host CLI, demo,
  or benchmark products;
- a compile-time adapter inventory reports read-only mapping, POSIX durable
  files, hard-termination fixture, and Metal source availability separately
  from native verification or support;
- the portable device contract records stable capability fingerprints,
  adapter-defined discovery epochs, plan-bound requirements, explicit
  fallback, and deterministic selection without importing native handles or
  granting live authority;
- W5a keeps fixed observation records and policy evaluation in portable Zig
  while read-only host probes and callback contexts remain outside core; the
  post-W5a JSON dispatcher now gives Linux, Windows, and FreeBSD adapters a
  platform-shaped context, and only Linux has the first bounded source
  implementation;
- the macOS-only Metal readiness adapter binds one real command buffer and one
  local discovery epoch to the portable W5 runner, revalidates the selected
  fingerprint and registry identity, and keeps native device authority and
  timestamps outside core; its hard gate
  and asymmetric FP16 tiled-matmul oracle tests are diagnostic/correctness
  evidence and fail closed;
- `src/core/` contains canonical state, admission, scheduling, media, provider,
  and recovery logic that is largely independent of an accelerator;
- Metal enablement is a build-time option and is rejected for non-macOS
  targets;
- AArch64 CPU kernels use Apple-specific tuning only on macOS and portable
  flags elsewhere;
- model range advice already distinguishes macOS and Linux;
- serialized formats use explicit encodings rather than native struct layout.

The main blockers are boundary violations rather than language choice:

- durable state, including ActionOutbox storage, uses `openat`, `fstatat`,
  `flock`, `linkat`, `fsync`, Unix mode bits, and POSIX open flags directly;
- read-only model-file mapping now has POSIX and Windows implementations, but
  native Windows mapping, corruption, replacement, and pressure tests remain;
- restart fixtures now normalize process IDs and hard termination across POSIX
  and Windows at compile time, but Windows restart behavior is not yet
  native-verified;
- some telemetry and benchmark harnesses assume macOS commands, timers, and
  resource fields;
- Metal discovery, compilation, and linking are coupled to macOS tooling;
- the default install graph now stages only the production CLI, benchmark and
  diagnostic executables are opt-in through `install-benchmarks`, and affected
  verification has named core, CPU, durable, device, and host-tool compile
  profiles plus a complete consumer compile closure; the core now exports the
  acquired durable POSIX authority and related adapters, while the profiles
  remain verification roots rather than final distributable products;
- the current core test aggregation includes threaded and filesystem tests,
  which prevents a reduced single-threaded edge target from compiling;
- 32-bit targets expose unchecked conversions from canonical `u64` lengths and
  counters to `usize`.

## Target architecture

Portability should preserve one canonical runtime core and move authority into
explicit platform adapters.

```text
application / service / mobile host
                 |
          public runtime API
                 |
    portable contracts and state machines
     identity · bounds · scheduling · media
     provider control · checkpoints · formats
                 |
        declared platform capability set
        /        |          |          \
 filesystem   virtual     telemetry   accelerator
 recovery     memory      and clock     backend
        \        |          |          /
          OS and device adapters
```

### Portable core

The portable core should own:

- canonical wire formats, hashes, lineage, and validation;
- bounded allocation plans and integer overflow checks;
- model-family and operation contracts;
- CPU reference kernels and backend-neutral tensor views;
- scheduling, continuation, media, and provider state machines;
- recovery protocol decisions expressed as abstract store operations;
- deterministic fixtures that require no process, filesystem, clock, or
  device authority.

The portable core must not import operating-system APIs. A target-specific
adapter supplies capabilities at initialization, and admission rejects a
requested feature when its capability is absent.

The first compile-time inventory is
`core.platform_capabilities.current_adapter_availability_v1`. Its booleans mean
only that a source adapter is selected for the compile target. They never mean
native-verified, recovery-verified, accelerator-verified, or supported. This
distinction prevents a successful Windows mapping compile or POSIX API match
from becoming a platform-support claim.

### Filesystem and recovery adapter

One capability should cover safe file opening, regular-file identity, bounded
reads and writes, file locking, data sync, directory sync, atomic replacement,
and crash-fixture control.

The current POSIX path acquires a descriptor-relative, sync-capable directory
authority and performs a real preflight sync before any namespace mutation.
The authority owns that exact handle through commit; consumers use borrowed
aliases that they must not close or retain. Because acquisition duplicates the
pinned directory authority, the caller may close its original `Dir`
immediately afterward. A failed commit poisons the authority, after which
checked borrow and commit calls reject while observation and close remain
available. These `fsync` and process-death semantics are host-protocol evidence,
not a physical power-loss guarantee.

Current and candidate implementations:

- acquired POSIX authority and durable-file adapters for macOS and Linux;
- compile-checked FreeBSD use of the sealed model-conversion publisher, without
  native recovery evidence;
- Win32 adapter using Windows handles, sharing modes, mapping objects, flush
  operations, and replacement semantics;
- Android adapter over application-scoped file descriptors and documented
  storage behavior;
- iOS adapter over application containers with explicit data-protection and
  background-lifecycle policy;
- memory/object-store adapter for edge profiles that do not promise local
  durable recovery.

Recovery semantics must be tested per adapter. Similar API names are not proof
of equivalent persistence behavior.

### Virtual-memory adapter

Portable-model conversion now uses bounded positional file reads without a
whole-source mapping. Runtime-image loading uses the first bounded read-only
region interface instead of calling `mmap` directly. The current interface
covers map/unmap and alignment through POSIX mappings or a Windows read-only
section view. Prefetch/advice, optional page-residency observations, buffered
fallback, and native Windows validation remain.

Implementations may use POSIX mappings, Windows file-mapping objects, or
bounded buffered reads. Mapping is an optimization, not a required semantic
property of the model format.

### Process, concurrency, clock, and telemetry adapters

Process identity, spawn, termination injection, monotonic time, threads, memory
pressure, energy counters, and machine state are distinct capabilities. The
first process seam now normalizes fixture PIDs to `u32` and selects POSIX
`SIGKILL` or Windows process termination at compile time. Logical runtime
accounting remains portable even when physical telemetry is unavailable.

The first W5a contract makes that absence explicit as `missing`, `denied`, or
`unsupported` rather than zero. It separates host and accelerator metric
planes, subjects, stable source identity, per-sample provenance, units, the
nonzero reason identity present only when unavailable, the sample-clock
identity present on every record, and the value-clock identity present only
for a directly observed time value. Present records carry no reason identity.
Neither clock field claims cross-clock calibration.
The bounded macOS adapter directly supplies host monotonic time, logical CPU
count, total CPU busy, external CPU, CPU idle, process RSS, available memory,
swap, power source, low-power mode, and thermal constraint. Linux, Windows,
FreeBSD, mobile, and direct physical CPU/device adapters remain independent
platform work.
Portable domain checks require a positive logical CPU count and allow signed
physical temperatures only at or above absolute zero.

A recovery test may use an OS-specific hard-termination mechanism, but the
canonical recovery verifier must consume the same retained evidence on every
platform. WASI and small edge targets need a declared single-threaded profile
instead of pretending to supply threads.

### Accelerator adapters

The first common decision boundary is implemented. Portable
`DeviceCapabilityV1` fingerprints describe stable backend/device identity,
canonical tested operation/type/numerical profiles, derived aggregate bits,
lifecycle policy, and declared physical ceilings. Canonical inventory entries
add discovery epochs and state;
an execution-plan-bound requirement produces one deterministic selection
receipt with explicit fallback before admission. The receipt contains no
pointer or backend handle and cannot allocate, submit, publish, or prove
continued liveness.

The allocation layer now consumes that receipt through deterministic fake and
native Metal adapters. Both ownership paths replay exact quotes and charge
before allocation: the receipt-bound path uses a `ResourceBank.ChildLease`,
while the execution-owned path atomically reserves a complete wave in one
exclusive additive LeaseTree scope before materialization. Both bind opaque
object generations and release objects before returning the charge. The fake
tests inject partial failure, cancellation, and recovery at deterministic
boundaries. The native Metal gate creates and directly inspects real Shared
buffers on the executing host through both ownership paths, including
LeaseTree FreePermit release and cancellation rollback.

The LeaseTree coordinator is synchronous and address-stable. The surrounding
execution owner must serialize coordinator calls with every other mutation of
the shared tree token and publication sequence; cross-thread use without that
external serialization is outside the contract. Bounded exact object-set
dispatch pins, pin-aware SnapshotV4 telemetry, reserved completion headroom,
and two fixed Metal lanes are implemented; dynamic queue/stream scheduling,
physical residency, and multi-GPU partitioning/scheduling remain open. For the
bounded Metal INT4 path, an
adapter-issued, generation-fenced `MetalMatvecDispatchRequestV1` root is the pin
dispatch-request root. Core seals the intent and reserves before Bank mutation;
if that reserve succeeds but source validation drifts, or atomic Bank pin
acquisition fails, core invokes the exact abort callback. A reserve error must
retain no partial adapter state. Callback/source validation fences the bound
lease/request/intent/pin. Valid preflight can submit or settle pure
`cancelled_before_submit`; malformed attempts can settle exact
`rejected_before_submit`. Both no-submit outcomes set `submission_sha256`,
`backend_completion_sha256`, and `output_sha256` to zero and use private pin
consumption followed by a private settlement callback that
atomically clears adapter state and records the replay tombstone. The public
acknowledgement is compatibility verification only. Rejection may inspect
native device/resources without creating or submitting a command buffer;
cancellation is native-free after binding. The submitted branch now separates
submit from poll/wait, returns `MetalAsyncDispatchTicketV1`, preserves pending
output and ownership, and exact-finalizes its native record only after Bank
settlement. Ambiguous submission, unknown or invalid completion, and terminal
command errors are detected as sticky nonterminal quarantine; this slice does
not reconcile or clear quarantine, inspect physical device loss, or select a
fresh device. OS and accelerator support remain separate dimensions. See the
[device capability and selection contract](DEVICE_CAPABILITY_CONTRACT.md),
[device allocation lease](DEVICE_ALLOCATION_LEASE.md),
[LeaseTree device allocation](LEASE_TREE_DEVICE_ALLOCATION.md), and
[device dispatch lifetime](DEVICE_DISPATCH_LIFETIME.md).

Planned backend families may include:

- Metal on Apple platforms through platform-appropriate packaging;
- a portable GPU compute path for Linux and Android where drivers and devices
  permit it;
- a Windows-native GPU path;
- optional vendor backends behind isolated build options;
- CPU-only profiles for servers, mobile devices, and constrained edge systems.

No backend is promoted from API compilation alone. Each one needs real-device
numerical and lifecycle evidence.

## Build graph separation

The package now exports `glacier` and `glacier_core`, with a retained consumer
smoke test in native and cross-target compile gates. This is the first
Zig-consumption seam. A separate core-only experimental product now installs
`glacier/model_contract.h`, `glacier_contract` as a shared library, and
`glacier_contract_static` as a non-colliding static library. Its focused gate
links source and staged-install C consumers, compiles the C++ linkage path, and
loads the shared library through Python; a separate named Rust gate uses the
same C ABI without dependencies. This does not make the wider runtime API
stable or promote a cross-compiled target to native support. The default
project install graph is not yet split into all products below.

The build should expose independent products:

1. `core-contract`: portable formats and deterministic state-machine tests;
2. `runtime-cpu`: core plus CPU execution and memory adapter;
3. `runtime-durable`: runtime plus one filesystem/recovery adapter;
4. `runtime-device`: runtime plus a selected accelerator;
5. `cli`: desktop/server command-line host;
6. `mobile-library`: embeddable library without CLI or process-death workers;
7. `edge-core`: reduced, optionally single-threaded profile with an explicit
   capability manifest;
8. host-only benchmark and fault-injection tools.

This split prevents a Unix restart worker or desktop CLI dependency from
blocking otherwise portable core compilation.

## Promotion gates

Every promoted target must retain artifacts for the relevant gates.

### G0 — capability truth

- the build records target, architecture, ABI, enabled adapters, and backend;
- portable inventory validation and deterministic selection bind the exact
  execution-plan requirement, capability root, and discovery epoch;
- unsupported requested capabilities fail at build or initialization;
- fallback is explicit and observable.

### G1 — compile and link

- `core-contract` compiles for the target;
- the selected runtime and adapter compile and link with the target SDK;
- public headers or library metadata pass an independent consumer build;
- warnings and target-specific exclusions are recorded.

### G2 — native CPU correctness

- deterministic core tests run on the real OS and architecture;
- CPU kernels match retained scalar oracles;
- format and golden-root results match the portable fixtures;
- 32-bit targets pass explicit `u64`-to-`usize` bounds tests.

### G3 — native storage and mapping

- model open, exact range reads, mapping or buffered fallback, and corruption
  rejection run natively;
- symlink/reparse-point, replacement, concurrent-open, permissions, and path
  encoding behavior are covered;
- sync claims name the filesystem and storage configuration.

### G4 — recovery

- fresh-process resume and hard-termination campaigns run natively;
- torn body/footer, stale generation, namespace replacement, and lock
  contention are retained;
- logical publication-call injection is labeled separately from physical
  storage failure; and
- initial publication and storage-device power loss remain separate campaigns.

### G5 — accelerator correctness

- the adapter refreshes or validates its discovery view, then revalidates the
  selected capability fingerprint and native device identity against the
  device used for native work;
- real-device discovery, allocation failure, canonical pre-submit rejection,
  dispatch, fence, teardown, and cancellation paths run;
- outputs meet the declared numerical contract against the CPU oracle;
- backend and driver/device identity are retained.

### G6 — resource and performance evidence

- monotonic timing and physical metrics come from the named adapter;
- every metric retains present/missing/denied/unsupported, subject, stable
  source identity, per-event provenance, unit, and sample-clock identity; only
  a present time-valued metric carries a value-clock identity;
  unavailable telemetry carries nonzero reason identity and never becomes
  zero;
- idle state, power mode, thermal state, affinity, and competing load are
  captured where available;
- versioned open-loop arrival-rate and closed-loop concurrency campaigns report
  completed, rejected, cancelled, and timed-out work separately, with exact
  throughput, p50/p95/p99 queue and completion latency, fairness, memory
  high-water, and bounded-growth results;
- soak and disruption campaigns retain the duration, seed, fault schedule,
  recovery result, and zero-orphan ownership check;
- missing physical metrics are marked unavailable, never synthesized from
  logical counters.

### G7 — packaging and lifecycle

- install, load, update, rollback, and uninstall are verified for the native
  artifact;
- mobile background/foreground and memory-pressure transitions are tested;
- supported OS, architecture, SDK, filesystem, and device ranges are published.

## Staged delivery

### Stage 1 — make the boundary explicit

- ~~introduce a compile-time platform adapter-availability manifest;~~ complete
  for read-only mapping, POSIX durable files, hard-termination fixtures, and
  the Metal source adapter; runtime discovery and verification status remain
  separate future records;
- ~~export dependency-consumable runtime/core modules;~~ complete as `glacier`
  and `glacier_core` with a retained consumer smoke gate;
- split pure core tests from filesystem, process, thread, and device tests;
- wrap virtual memory and durable storage behind narrow interfaces;
- move telemetry and process-death injection out of canonical runtime modules;
- ~~add a portable, pointer-free observation ABI and fail-closed runner;~~ W5a
  complete, with direct native telemetry adapters still staged;
- add checked conversions for every canonical `u64` used as `usize`.

Exit: core-only compile gates are small, fast, and contain no OS imports.

### Stage 2 — desktop/server CPU

- retain macOS CPU behavior under the new adapters;
- add native x86_64 and AArch64 Linux runners and recovery campaigns;
- implement Windows file, mapping, process, and clock adapters;
- build the runtime library independently from demos and benchmark workers.

Exit: named macOS, Linux, and Windows CPU configurations pass G0–G4 and G7.

### Stage 3 — mobile

- package a library-first Android runtime and exercise application-scoped
  storage, lifecycle, and memory pressure;
- package an iOS runtime with an iOS-native device adapter and explicit
  background/data-protection policy;
- retain CPU correctness before enabling mobile accelerators.

Exit: named Android and iOS device/OS ranges pass the applicable gates; simulator
results remain labeled separately.

### Stage 4 — edge profiles

- define single-threaded and no-durable-filesystem capability profiles;
- separate 32-bit-safe fixtures from host-only tests;
- make object storage, buffered model input, and externally hosted recovery
  first-class adapter choices;
- consider WASI only after its capability limits have an explicit runtime
  contract.

Exit: each edge artifact declares what it can do; an unavailable capability is
not represented as partial support.

### Stage 5 — accelerator matrix

- ~~add a portable capability fingerprint, canonical inventory, plan-bound
  requirement, and deterministic selection receipt;~~ complete, including
  explicit CPU fallback, native Metal local-epoch binding, and
  fingerprint/registry-identity revalidation;
- ~~retain the existing Metal correctness path behind the common device
  decision contract;~~ complete for the tested readiness binding and corrected
  asymmetric FP16 tiled matmul CPU-oracle cases only;
- ~~add a receipt-bound fake allocation lifecycle;~~ complete for portable
  quote replay, exact adapter-quoted charge, failure/cancellation rollback,
  recovery, and stale-handle fencing only;
- ~~add a native direct-buffer allocation adapter with exact logical
  resource-length accounting, direct per-object `allocatedSize` evidence,
  release ordering, and generation-fenced reuse;~~ complete on the native
  Metal hard gate;
- ~~compose native allocation with a dedicated additive LeaseTree execution
  coordinator;~~ complete for whole-wave reserve/materialize/FreePermit
  ownership, conservative recovery, sibling-scope isolation, real Metal reuse,
  and synchronous cancellation rollback;
- ~~bind bounded dispatch lifetime to the exact LeaseTree-owned object set;~~
  complete with fixed Bank pin storage, private permit custody, terminal
  completion evidence, release fencing, and one real four-buffer Metal
  dispatch;
- ~~add adapter-authorized pre-submit rejection after pin acquisition;~~
  complete for the adapter-issued generation-fenced request, core-sealed
  intent, reserve-before-Bank-mutation acquisition, exact abort after
  post-reserve source drift or Bank acquisition failure, callback/source
  validation, zero submission/backend-completion/output roots for rejection
  and cancellation, private settlement and replay tombstone, and
  compatibility-only public acknowledgement;
- ~~add per-adapter bounded two-slot async completion delivery;~~ complete with
  slot-bound generation-fenced tickets, exact submit replay, third-request
  capacity rejection, separate poll/wait, pending ownership retention,
  out-of-order settlement, exact completed-output binding, post-Bank native
  finalization, sticky nonterminal quarantine, and native two-record evidence;
- add dynamic queue scheduling beyond the fixed two slots and multi-device
  partitioning;
- add explicit device-loss inspection and safe reconciliation, quarantine
  clearing, and fresh selection under a new receipt;
- add physical residency and direct device telemetry as separate authorities;
- add more GPU backends with CPU-oracle/lifecycle gates and expand native
  OS/device matrices.

Exit: G5 and G6 evidence is retained for every advertised cell in the device
matrix. The completed bounded selection, allocation-ownership, and readiness
slices do not satisfy this exit.

## Claim boundary

The source-compilation probes above do not establish native execution,
filesystem durability, mobile lifecycle safety, accelerator correctness,
installation quality, physical telemetry, or performance. The W5a
cross-compile gate likewise does not establish native observation. The
portable selection contract, fake allocation lifecycles, one real-Metal
allocation/pinned-dispatch ownership gate, and one Metal readiness binding do
not establish dynamic queue scheduling beyond two slots, physical residency,
multi-GPU behavior, physical telemetry, performance, or native support for any
cross-compiled target. The fake lifecycles establish deterministic
failure/recovery semantics for both ChildLease and LeaseTree ownership. The
native allocation gate additionally establishes direct resource creation,
inspection, release, cancellation cleanup, generation reuse, and per-adapter
bounded two-slot async completion delivery on its executing host only. It also
establishes exact zero-command rejection and pure cancellation before
submission for the bounded Metal profile. Portable Zig fake/state tests and
the Python oracle are contract models without a GPU; only the native macOS
gate uses real Metal devices and buffers. That gate separates submit from
poll/wait on the valid branch, validates exact output, settles Bank ownership,
then finalizes the native command; reject/cancel issue zero GPU commands.
Sticky quarantine detects post-submit uncertainty but does not reconcile or
clear it and does not establish physical device-loss recovery. This document is an
implementation plan and evidence ledger, not a declaration that every listed
platform is currently supported.
