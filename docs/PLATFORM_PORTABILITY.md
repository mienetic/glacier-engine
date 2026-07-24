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
  filesystem on the named OS.
- **Accelerator-verified**: a device backend passes numerical, lifetime, and
  synchronization checks against a CPU oracle on real hardware.
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
| macOS / AArch64 | Native build path exists; Metal is optional and macOS-only | Primary development-host tests exist, but no version/device support range is declared here | Retained host process-death fixtures exist | Optional Metal path exists; promotion still requires per-device retained gates | Development host, not a broad platform certification |
| Linux / x86_64 | Full musl artifact and `test-compile` cross-build gates pass in `ReleaseSafe`; the core GNU source probe also passes | Not established by cross-compilation | Native Linux filesystem campaign is pending | No retained Linux accelerator backend | Cross-build candidate |
| Linux / AArch64 | Full musl artifact and `test-compile` cross-build gates pass in `ReleaseSafe`; the core GNU source probe also passes | Not established by cross-compilation | Native Linux filesystem campaign is pending | No retained Linux accelerator backend | Cross-build candidate |
| Windows / x86_64 GNU | Full artifact and `test-compile` cross-build gates pass in `ReleaseSafe`; read-only model mapping and process fixture seams compile | Not established by cross-compilation | No native Windows durable-file adapter or recovery campaign | No Windows accelerator backend | Cross-build candidate; not native-supported |
| FreeBSD / x86_64 | Full artifact, `test-compile`, and generated-media conformance cross-build gates pass in `ReleaseSafe` | Not established by cross-compilation | No retained native FreeBSD filesystem campaign | No retained FreeBSD accelerator backend | Cross-build candidate; not native-supported |
| Android / AArch64 | Core source-compilation probe passed | No device or emulator execution evidence | No Android lifecycle/storage recovery campaign | No Android accelerator backend | Research target; not supported |
| iOS / AArch64 | Core source-compilation probe passed | No device execution or application-lifecycle evidence | No iOS protection-class/background recovery campaign | No iOS backend has been verified; the macOS Metal bridge is not iOS evidence | Research target; not supported |
| WASI / wasm32 | Core source-compilation currently fails | Not established | Durable local recovery is outside the current contract | None | Unsupported; requires a reduced edge profile |
| Other edge systems | No named target matrix yet | Not established | Not established | None | Unscoped |

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

## Existing portability seams and blockers

Useful seams already exist:

- public `glacier` and `glacier_core` Zig package modules let dependency
  consumers import runtime code without running or installing host CLI, demo,
  or benchmark products;
- a compile-time adapter inventory reports read-only mapping, POSIX durable
  files, hard-termination fixture, and Metal source availability separately
  from native verification or support;
- `src/core/` contains canonical state, admission, scheduling, media, provider,
  and recovery logic that is largely independent of an accelerator;
- Metal enablement is a build-time option and is rejected for non-macOS
  targets;
- AArch64 CPU kernels use Apple-specific tuning only on macOS and portable
  flags elsewhere;
- model range advice already distinguishes macOS and Linux;
- serialized formats use explicit encodings rather than native struct layout.

The main blockers are boundary violations rather than language choice:

- durable state uses `openat`, `fstatat`, `flock`, `linkat`, `fsync`, Unix mode
  bits, and POSIX open flags directly;
- read-only model-file mapping now has POSIX and Windows implementations, but
  native Windows mapping, corruption, replacement, and pressure tests remain;
- restart fixtures now normalize process IDs and hard termination across POSIX
  and Windows at compile time, but Windows restart behavior is not yet
  native-verified;
- some telemetry and benchmark harnesses assume macOS commands, timers, and
  resource fields;
- Metal discovery, compilation, and linking are coupled to macOS tooling;
- the default install graph still includes host-oriented CLI and benchmark
  products even though dependency consumers can import the exported modules
  independently; named core, CPU, durable, mobile, and host-tool product
  profiles are still missing;
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

Candidate implementations:

- POSIX adapter for macOS and Linux;
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

Model loading now uses the first bounded read-only region interface instead of
calling `mmap` from model conversion and runtime-image code. The current
interface covers map/unmap and alignment through POSIX mappings or a Windows
read-only section view. Prefetch/advice, optional page-residency observations,
buffered fallback, and native Windows validation remain.

Implementations may use POSIX mappings, Windows file-mapping objects, or
bounded buffered reads. Mapping is an optimization, not a required semantic
property of the model format.

### Process, concurrency, clock, and telemetry adapters

Process identity, spawn, termination injection, monotonic time, threads, memory
pressure, energy counters, and machine state are distinct capabilities. The
first process seam now normalizes fixture PIDs to `u32` and selects POSIX
`SIGKILL` or Windows process termination at compile time. Logical runtime
accounting remains portable even when physical telemetry is unavailable.

A recovery test may use an OS-specific hard-termination mechanism, but the
canonical recovery verifier must consume the same retained evidence on every
platform. WASI and small edge targets need a declared single-threaded profile
instead of pretending to supply threads.

### Accelerator adapters

The backend interface should describe capabilities, buffer ownership, queue or
stream ordering, synchronization, supported element types, and deterministic
fallback policy. OS and accelerator support are separate dimensions.

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
- initial publication and storage-device power loss remain separate campaigns.

### G5 — accelerator correctness

- real-device discovery, allocation failure, dispatch, fence, teardown, and
  cancellation paths run;
- outputs meet the declared numerical contract against the CPU oracle;
- backend and driver/device identity are retained.

### G6 — resource and performance evidence

- monotonic timing and physical metrics come from the named adapter;
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

- retain the existing backend behind the common device contract;
- add backends only with CPU-oracle and lifecycle tests;
- publish support by OS, architecture, device family, driver/runtime version,
  element type, and operation rather than by backend name alone.

Exit: G5 and G6 evidence is retained for every advertised cell in the device
matrix.

## Claim boundary

The source-compilation probes above do not establish native execution,
filesystem durability, mobile lifecycle safety, accelerator correctness,
installation quality, or performance. This document is an implementation plan
and evidence ledger, not a declaration that every listed platform is currently
supported.
