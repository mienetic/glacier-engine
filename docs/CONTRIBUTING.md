# Contributing to Glacier Engine

Thank you for helping build Glacier Engine. Contributions of code, tests,
documentation, fixtures, design review, reproduction, and issue triage are all
welcome.

## Start in ten minutes

```sh
git clone https://github.com/mienetic/glacier-engine.git
cd glacier-engine
tools/verify.sh
```

The default quick profile uses Debug compilation, no model or provider
credentials, and reports every gate as `PASS`, `FAIL`, or `SKIP` with a reason.
Run
`tools/verify.sh affected-fast --base origin/main` during ordinary iteration.
It runs changed-file checks plus selected focused roots; deferred broad
Darwin/AArch64 native suites, Metal, ReleaseSafe host, and foreign-target work
remains visible as `SKIP` rather than being reported as evidence. A
documentation-only plan runs no Zig build beyond formatting. Before release or
when the complete path-aware matrix is needed, run
`tools/verify.sh affected --base origin/main`; use `tools/verify.sh full` for
the broad local ReleaseSafe and Python suites.

The quick profile remains dependency-free. Use CPython 3.10–3.12 and install
`bench/requirements-test.txt` in a clean environment before running `full`,
`matrix`, or full unittest discovery.

Pull requests and pushes to `main` run `affected-fast` on Ubuntu. Manual CI
also defaults to `affected-fast` against `origin/main`; maintainers explicitly
select `affected`, `full`, or `matrix` only for promotion work. `v*` tags run
the Linux matrix plus the macOS Metal/durability frontier. There is no
scheduled exhaustive build.
Full Python discovery imports the retained numeric reference reporters and
installs their pinned dependency from `bench/requirements-test.txt`; the
embedding, dense-tensor classifier, and runtime-contract verifiers remain
standard-library-only. The macOS frontier compiles the complete Metal closure
but does not execute or measure it. Native Metal runtime and performance gates
remain explicit local or maintainer-run checks so hosted CI does not imply
hardware evidence it did not collect.

Then choose a bounded item from [Contributor projects](PROJECTS.md), open a
**Claim a contributor slice** issue, and tell us what command will prove it is
done. Draft pull requests are encouraged.

## Contribution workflow

1. Search existing issues and pull requests.
2. For anything larger than a typo, open or claim an issue.
3. Fork the repository and create a focused branch.
4. Add the smallest failing or rejection test first when practical.
5. Implement one independently useful behavior.
6. Run the relevant verification matrix.
7. Update user-facing documentation and claim boundaries.
8. Open a pull request and respond to review with new commits.

Maintainers may ask to split a pull request. This is about keeping review and
rollback safe, not reducing the value of the larger idea.

## What makes a strong issue

- One concrete user or contributor problem.
- The smallest behavior that solves part of it.
- Named malformed, stale, unsupported, or fault-injected cases.
- One acceptance command and expected evidence.
- Explicit exclusions so reviewers know what is not being claimed.

Use the issue template when possible. Exploratory design discussions are welcome;
label assumptions and questions clearly.

## Code and document style

- Run `zig fmt` on changed Zig files.
- Prefer explicit types and checked arithmetic at ABI, length, offset, and
  resource boundaries.
- Avoid silent fallback. Unsupported modes should return a named error.
- Preserve generation and epoch fencing when adding reusable handles.
- Keep network credentials and prompt text out of deterministic core fixtures.
- Keep read-only inspectors metadata-first. Treat roots, counts, epochs, and
  generations as correlatable metadata; require an explicit flag before
  rendering prompt, result, or other payload bytes.
- When byte-domain output may be invalid UTF-8, preserve exact bytes and expose
  text only after strict validation. Do not use replacement characters as
  evidence of the original output.
- Write comments that explain invariants and authority, not line-by-line syntax.
- Use relative Markdown links and explain project-specific terms in the
  [glossary](GLOSSARY.md).
- Do not publish unsupported performance superlatives. State only what retained
  evidence supports.

## Verification matrix

The quick and full profiles remain stable contributor entry points. Quick and
`affected-fast` use Debug compilation for the short feedback loop.
`affected-fast` is the iterative path-aware tier: it keeps focused high-risk
gates but deliberately defers broad ReleaseSafe/Python suites and the retained
cross-target plan. The `affected` profile switches to ReleaseSafe and adds
every row needed by the complete changed-path set; one narrow change never
hides the checks required by another changed path.

| Change | Required checks |
| --- | --- |
| Documentation or metadata only | Quick profile, links, spelling/manual review |
| GitHub workflow, action, or dependency automation | `affected-fast` runs the repository verification-policy regression suite without a generic Zig build; file-specific review, Python discovery, and unrelated native/retained-target compilation remain deferred to complete tiers |
| Verification policy, verifier wrapper, or policy regression test | `affected-fast` runs changed-file syntax plus `bench.tests.test_local_verify` and `bench.tests.test_verification_policy` once without a generic Zig build; broad native/target coverage remains deferred to complete tiers |
| Python verifier, harness, or retained result without a focused gate below | `affected-fast` runs changed-file Python syntax without a generic Zig build; complete tiers add full Python unittest discovery; no foreign Zig target |
| Portable workload report/campaign codec, verifier, or focused test | Changed-file Python syntax where applicable plus the portable workload report test, native compile, and four-target cross-compile gate; no hard native campaign unless another changed path selects one |
| W7b-b2 store-fault campaign (`bench/native_workload_store_fault_campaign.py` and `bench/tests/test_native_workload_store_fault_campaign.py`) | Changed-file Python syntax plus the hard native POSIX store-fault gate on Darwin, Linux, or FreeBSD; no foreign Zig target |
| Production campaign-store publisher (`bench/native_metal_soak_report.py` and `bench/tests/test_native_metal_soak_report.py`) | Changed-file Python syntax, full Python discovery, the hard native POSIX store-fault gate, and the serialized native Darwin Metal suite; no foreign Zig target |
| Native environment admission helper or focused test | Changed-file Python syntax, full Python discovery, and the serialized native Darwin Metal suite; no foreign target or performance claim |
| Native Metal cancellation-storm Zig producer | Serialized native Darwin Metal suite; no foreign Zig target or foreign GPU-execution claim |
| Native Metal cancellation-storm Python verifier or focused test | Changed-file Python syntax, full Python discovery, and the serialized native Darwin Metal suite; no foreign Zig target or foreign GPU-execution claim |
| Native Metal in-flight process-kill worker, controller, ready frame, or focused test | Ready-frame/controller model checks plus the serialized native Darwin Metal suite; changed Python also receives syntax and full discovery; no foreign GPU-execution claim |
| W7b-b5 supervisor/recovery-death report codec or verifier | Changed-file syntax, the portable Python/Zig report gate, native report compile, and retained-target cross-compile; no GPU or native signal claim |
| W7b-b5 supervisor/recovery-death controller or protocol test | Changed-file Python syntax, full Python discovery, the deterministic staged-store model plus real POSIX process/lock fixture, and the serialized native Darwin Metal suite; the host layers are not a composed GPU-execution claim |
| POSIX shell script | Syntax under its declared `sh` or `bash` shebang |
| Retained Rust interop consumer | Native Rust contract gate only; `rustc` is required, but foreign Zig targets cannot compile or validate this runtime consumer |
| Other Rust build input | Native Rust contract gate, native ReleaseSafe, Python discovery, and every retained target until its build graph is classified |
| Retained runtime interop `.hex` fixture | Quick C/C++/Python replay, full Python discovery, and the native Rust contract gate; no foreign Zig target; new fixture paths remain conservative until classified |
| Benchmark runtime data (`.ids`, paired manifests, evaluation text) | Full Python discovery; no foreign Zig target |
| Darwin Swift ProcessInfo probe | Full Python discovery plus focused native `swiftc -typecheck`; no broad Zig or foreign-target build |
| Audited C contract boundary | Native ReleaseSafe, Python discovery, and the core compile profile on every retained target |
| Dense-tensor reranker, embedding, classifier, retrieval, shared demo, or independent tensor-result oracle | `affected-fast` selects `dense-tensor-family-test`; an adapter-core change also selects `runtime-support-inspector-test`. `dense-tensor-family-compile` is the production-only retained-target frontier. Existing family names remain compatibility targets backed by the shared compiled artifacts, while their focused test routes keep distinct oracles. Python-test-only tensor, embedding, and retrieval changes independently select their exact unittest module; foreign compilation is not native execution, quality, or performance evidence |
| General `src/core/` implementation | Native ReleaseSafe, Python discovery, and the main `install test-compile` closure on every retained target; bulk benchmark staging and the standalone benchmark consumer closure remain a benchmark/build-graph or promotion-matrix gate, while device diagnostics already owned by `test-compile` remain in the main closure and `src/core/root.zig` remains full because it controls build reachability |
| CPU backend or model implementation | Native ReleaseSafe, Python discovery, and the main `install test-compile` closure on every retained target; bulk benchmark staging and the standalone benchmark consumer closure remain a benchmark/build-graph or promotion-matrix gate, while device diagnostics already owned by `test-compile` remain in the main closure |
| Shared durable core/runtime implementation | Native ReleaseSafe, Python discovery, and the complete consumer compile closure on every retained target |
| Audited durable recovery demo or worker | Native ReleaseSafe, Python discovery, and the durable profile on every retained target |
| Bounded unary prepared-text service kernel or its focused acceptance root | A focused acceptance-only change runs `unary-text-service-test` alone. A kernel implementation change selects the service, HTTP, and managed-process roots in one host Zig invocation. Complete affected verification selects the corresponding compile-only companions on each retained target without pulling the broad model-forward suite |
| Bounded unary HTTP contract, client, or focused acceptance root | `affected-fast` runs `unary-http-test` once; complete affected verification selects only `unary-http-compile` on retained targets |
| Managed unary server adapter/API or process acceptance root | A shared server implementation change selects `unary-http-test` and `unary-server-process-test` without the service-only root; a process-fixture-only change selects `unary-server-process-test` alone. Complete affected verification selects only the corresponding compile companions; foreign compilation is not native serving evidence |
| Ordinary model package producer, strict tensor-profile admission module, package-aware `text-run`, its explicit POSIX supervisor protocol/death controller, process-local variable-terminal module, or bounded-input helper | `affected-fast` reuses the existing installed-CLI `text-runtime-golden-path-test` host DAG once; supervisor/death cases add no executable or compile root, and the complete affected tier cross-compiles only the existing CLI artifact through `text-runtime-golden-path-compile` |
| Package/raw-input Python oracle implementation | Changed-file syntax plus the CLI-backed `text-runtime-golden-path-test`, which checks the independent oracle against executable output in one host DAG; no foreign target |
| Package/raw-input Python test only | Changed-file syntax plus exactly `bench.tests.test_prepared_text_raw_input` and `bench.tests.test_prepared_text_package`; no Zig build, generic host DAG, full Python discovery, or foreign target |
| Prepared-text session lifecycle | `affected-fast` runs the unary acceptance root and text-runtime golden path in one Zig invocation; the complete affected tier adds only the CPU, durable, and CLI-only text-runtime compile profiles instead of the complete consumer closure |
| Prepared-text committed-output inspector or oracle | `affected-fast` runs the inspector and package-module roots in one host DAG; the complete affected tier adds broad host and selected portability coverage |
| Prepared-text durable writer, runtime, or process-death campaign | `affected-fast` runs the recovery and package-module roots in one host DAG; when inspector paths change in the same worktree, all selected roots share that invocation |
| Provider evidence inspector, independent oracle, or focused test | `affected-fast` runs the existing `provider-evidence-inspector-test` root once for Zig CLI or oracle changes. Complete affected verification cross-compiles only `provider-evidence-inspector-compile` for a Zig CLI change. A focused-test-only change runs that exact Python unittest module without a generic Zig build or full discovery |
| CLI or retained read-only inspector | Native ReleaseSafe, Python discovery, and the host-tool profile on every retained target |
| Shared root, unclassified Zig/C/C++/header, or other build input | Native ReleaseSafe, Python discovery, and the full production-install, benchmark-install, and test-compile roots on every retained target |
| Zig build graph (`build.zig` or `build.zig.zon`) | Native ReleaseSafe, Python discovery, the hard native POSIX store-fault gate, the serialized native Darwin Metal suite, and the full production-install, benchmark-install, and test-compile roots on every retained target |
| AArch64 NEON/CRC C kernel | Native ReleaseSafe with explicit Apple Silicon (`arm64`/`aarch64`) Darwin evidence, Python discovery, and the CPU plus downstream host-tool profiles on the retained AArch64 Linux target; Intel macOS and Rosetta report unavailable instead of reusing an unrelated x86_64 pass |
| Linux-specific runtime | Native ReleaseSafe plus both retained Linux targets |
| Windows-specific runtime | Native ReleaseSafe plus the retained Windows target |
| FreeBSD-specific runtime | Native ReleaseSafe plus the retained FreeBSD target |
| Shared POSIX runtime | Native ReleaseSafe, explicit Darwin evidence, both Linux targets, and FreeBSD; the Darwin label reuses the native suite instead of compiling twice |
| Darwin- or macOS-specific runtime | Native Darwin ReleaseSafe tests; a non-Darwin skip is not passing evidence |
| Metal backend | Serialized native Darwin Metal suite, including the production-native workload report, controlled-disruption campaign, 60-second segmented-soak campaign, post-segment process-kill campaign, controlled in-flight process-kill campaign, supervisor/recovery-process death campaign, production-symbol isolation, and the build-isolated fault/race gate; a non-Darwin skip is not passing evidence |
| Unknown input under a code tree | Conservatively use every retained target |
| Concurrency or locking | Zig modes above, ThreadSanitizer where supported, fault/recovery tests |
| On-disk or wire ABI | Encoder/decoder tests, golden fixture, mutation/reorder/truncation tests, independent verifier |
| Performance | Correctness matrix plus the measurement contract in `BENCHMARKS.md` |

Common commands:

```sh
tools/verify.sh
python3 -m pip install --only-binary=:all: --require-hashes \
  -r bench/requirements-test.txt
tools/verify.sh affected-fast --base origin/main
tools/verify.sh affected --base origin/main
GLACIER_VERIFY_BASE=origin/main tools/verify.sh affected
GLACIER_VERIFY_REQUIRE_NATIVE=1 tools/verify.sh affected --base origin/main
tools/verify.sh full
tools/verify.sh matrix

zig build test -Doptimize=Debug -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false
zig build test -Doptimize=ReleaseFast -Dmetal=false
python3 -m unittest discover -s bench/tests

tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

zig build test -Doptimize=ReleaseSafe -Dmetal=false -Dsanitize-thread=true

tools/zig-with-ephemeral-cache.sh build \
  native-metal-fault-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2

tools/zig-with-ephemeral-cache.sh build \
  native-metal-soak-report-pure-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2

tools/zig-with-ephemeral-cache.sh build \
  native-metal-soak-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-soak-output-dir=PATH

tools/zig-with-ephemeral-cache.sh build \
  native-metal-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-process-kill-output-dir=PATH

tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-pure-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-report-cross-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2 \
  -Dnative-workload-store-fault-output=PATH

tools/zig-with-ephemeral-cache.sh build \
  native-metal-workload-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2

tools/zig-with-ephemeral-cache.sh build \
  native-metal-disruption-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2

tools/zig-with-ephemeral-cache.sh build \
  native-metal-cancellation-storm-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-cancellation-storm-report-output=PATH

tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-inflight-process-kill-report-output=PATH

tools/zig-with-ephemeral-cache.sh build \
  native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

`affected-fast` and `affected` resolve the merge base of `HEAD` and the explicit
`--base` value (or `GLACIER_VERIFY_BASE`). They then union four independent
NUL-delimited path streams: merge base to `HEAD`, `HEAD` to the index, index to
worktree, and untracked files. Keeping those states separate prevents a
worktree reversal from hiding a committed or staged change. Whitespace and
newlines in a valid Git path do not change the selection. Both commands print
every deduplicated path and its selection reason. `affected-fast` visibly marks
the broad native suite, full Python discovery, and selected portability plan as
`SKIP`; it does not convert those deferred gates into passing evidence.
`affected` executes the complete selected plan. A missing base, Git, Python, or
required Zig toolchain is a failure rather than a silent pass.

Changed `.sh` files must declare one of the retained `sh` or `bash` shebangs;
syntax is checked by that interpreter. Both affected tiers keep selected
changed-Python, shell, Rust, Darwin Swift, portable-report, POSIX store-fault,
and prepared-text focused gates. A generic Darwin flag currently has only the
broad host suite, and native Metal is a deep hardware frontier, so
`affected-fast` leaves either selection visible as `SKIP` instead of expanding
the short loop. Changed Rust source makes the native Rust gate required rather
than optional. On a non-Darwin host, selected Darwin and Metal gates remain
visible `SKIP` results for ordinary contributor planning.
The selected native POSIX store-fault gate runs on Darwin, Linux, or FreeBSD;
other hosts likewise report it as unavailable. Ordinary pull-request and
`main` and default manual CI use `affected-fast`. Maintainer and release
validation should use complete `affected` locally with
`GLACIER_VERIFY_REQUIRE_NATIVE=1`, or explicitly dispatch the hosted
`affected` profile with the intended `base_ref`. Hosted `full` and `matrix`
remain explicit broad promotion gates; `v*` tags select `matrix` and the macOS
frontier. Strict native mode turns any unavailable selected native gate into
`FAIL`.

Host routing is explicit rather than inferred from a foreign-target plan.
Plans limited to documentation, workflow control, policy, shell, or ordinary
Python work therefore do not start the generic contract/package Zig DAG.
An audited interop fixture or C contract change selects only
`contract-interop-test`; a package-module acceptance change selects only
`package-module-test`. If both are selected, their canonical union still runs
in one Zig invocation. Build controls and unclassified inputs retain both roots
until a narrower mapping is audited.
When one change set selects both a generic compiled path and a focused
prepared-text path, the verifier places all required host roots in one
`zig build` invocation so compile reduction cannot hide either side.
Unary-service-only test changes select one dedicated acceptance root. Leaf HTTP
codec, client, and acceptance changes select `unary-http-test`. A unary-kernel
implementation change selects the service, HTTP, and managed-process roots; a
shared server adapter/API change selects the HTTP and managed-process roots
without the service-only root. A process-fixture-only change selects only the
managed-process root. All selected host roots share one Zig
invocation. Shared prepared-text session changes select the unary root and
installed text-runtime golden path in that same invocation. Complete
affected verification compiles only the corresponding focused roots on
selected retained targets instead of expanding to the broad model-forward
suite. These are foreign compile checks, not native HTTP execution claims.

Prepared-text routing keeps the default loop bounded. Changes limited to the
direct-terminal controller or its Python tests select only the four-boundary
smoke. Direct-terminal Zig implementation changes select the deterministic
delivery gate and that smoke together; the shared checkpoint codec and
selector publisher do the same because they own the tested rename boundary.
Changes to the shared recovery worker or acknowledged recovery harness select
the combined recovery target, which already includes the smoke, so the
verifier omits the standalone smoke target. All selected prepared-text targets
are passed to one `zig build` invocation; the smoke and combined recovery
target reuse the same worker executable.

The text-runtime golden test depends on the exact CLI install child step and
executes `bin/glacier` from the selected prefix. Its compile-only companion
still depends directly on the CLI artifact, so retained cross-target compile
profiles do not stage another binary. The installed-shape run uses an empty
working directory and isolated ambient state without introducing another Zig
compile root. Ordinary package/raw-input Zig changes select that CLI-only
compile companion instead of the broader host-tool profile. Changes to either
independent package/raw-input Python oracle retain the CLI-backed golden path
because it verifies their relationship with executable output. Changes limited
to either exact Python test run the two matching unittest modules without
starting a Zig build.

Provider evidence inspector routing is similarly bounded. Inspector and
independent-oracle changes select the existing
`provider-evidence-inspector-test` root, whose Zig tests and subprocess oracle
share one host build. A Zig CLI change adds only the existing
`provider-evidence-inspector-compile` step on retained targets in complete
affected verification. An oracle-only change keeps changed-file syntax and the
focused root without foreign targets. A focused-test-only change runs exactly
`bench.tests.test_provider_evidence_inspector`, without a generic Zig build or
full unittest discovery. This route adds no executable or compile root.

Dense-tensor focused routing now selects `dense-tensor-family-test` once for
reranker, embedding, classifier, shared-demo, and independent tensor-result
changes. Its retained-target companion is `dense-tensor-family-compile`.
Existing reranker, embedding, and retrieval test, compile, and demo names remain
compatibility targets backed by the same compiled family artifacts, while
their focused test routes retain distinct independent oracle dependencies. The
demo selects the retained `rerank`, `embed`, `classify`, or `retrieve` mode without
compiling a second executable. An adapter-core change additionally selects
`runtime-support-inspector-test`. A Python-test-only tensor change selects
`bench.tests.test_stateless_tensor_result`, while an embedding change selects
`bench.tests.test_stateless_embedding_result` and a retrieval change selects
`bench.tests.test_stateless_retrieval_result`; each can run alone when full
Python discovery is not otherwise selected. Changes to the installed
support-discovery ABI continue to use the existing contract interop gates.
These checks establish deterministic contract behavior, not ANN, probability
or label semantics, production quality, GPU or native multi-OS execution,
performance, or provider-token reduction.

Hosted affected and exhaustive jobs reuse the pinned Zig setup action's cache,
configured with 1,024 MiB and 2,048 MiB action hard limits respectively.
Before saving it, verification soft-prunes an affected-job cache above 900 MiB
and an exhaustive/Metal cache above 1,800 MiB.
`tools/verify.sh` keeps local runs ephemeral by default even when the caller
exports Zig cache variables. Its reuse opt-in is restricted to GitHub Actions
and accepts only the action's exact physical workspace `.zig-cache` path;
temporary logs, prefixes, module caches, and all non-Zig state are still
removed after the run. If a Zig build reports the exact adjacent
`failed to parse archive: FileNotFound` diagnostic for
`.zig-cache/o/<hash>/libcompiler_rt.a`, the verifier preflights and clears only
the validated `.zig-cache` children, then retries the same build once. At most
one recovery is attempted across an affected or exhaustive verifier run,
including focused host, exhaustive host, and retained-target gates. Other
compiler failures are never retried or reclassified.

The retained cross-target set is:

- `x86_64-linux-musl`
- `aarch64-linux-musl`
- `x86_64-windows-gnu`
- `x86_64-freebsd`

The Python policy emits an ordered target list and a separate, closed
target-to-step plan. The shell rejects unknown, duplicate, missing,
out-of-order, mixed-full/focused, or unselected-target records before starting
any foreign build. Each selected target still gets exactly one `zig build`
invocation, but its named roots are now the smallest audited union of
`profile-core-compile`, `profile-cpu-compile`,
`profile-durable-compile`, `profile-device-compile`, and
`profile-host-tool-compile`. Shared producer APIs select
`profile-complete-compile`, which reaches every retained test, demo, CLI, and
benchmark compile consumer without staging the production CLI or benchmark
set; the installed C-contract consumer still stages its boundary artifacts.
General core, CPU, and model changes select the main
`install test-compile` closure, leaving bulk benchmark staging and the
standalone benchmark consumer closure to benchmark or build-graph changes and
the deliberate matrix/release boundary. Device diagnostics already owned by
`test-compile` remain in the main closure. Build controls, roots, and unknown
paths fail closed to the explicit
`install install-benchmarks test-compile` full plan.
That plan preserves production, benchmark/diagnostic, and compile-only test
coverage, and dominates focused roots only for the affected target, so a
Windows-specific full change does not expand unrelated Linux or FreeBSD
graphs.

Multiple named roots share one Zig dependency graph and identical Step
pointers execute once. Naming `install` remains required for a full plan
because Zig does not select its default step after another top-level step is
named. The default install now contains only the production CLI; use
`zig build install-benchmarks` to stage all benchmark and diagnostic
executables. `zig build run` also builds only the CLI.

The quick profile passes its compatible contract and package roots to one
Debug Zig invocation. The full profile first runs ReleaseSafe
`host-runtime-compile`, which closes
over the complete `test-compile` graph and the C/C++/Python contract artifacts
needed by the subsequent host runtime DAG. A compile failure stops the broad
runtime phase, while a successful frontier warms the same private caches used
by the subsequent `test` and contract roots. This separates build failures from
runtime failures without recompiling each compatible root in an independent
cold process.

Metal-only changes first complete `native-metal-suite-compile`. That frontier
uses an explicit inventory of every distinct native suite executable and test,
the cacheable shader library, and the isolated fault-symbol check. It does not
depend on the wider device or host-tool profile umbrellas, which keeps eleven
unrelated compile artifacts out of the macOS frontier. Its shader cache
identity tracks the selected Xcode tools, SDK settings, and Metal
standard-library contents rather than trusting a stale persistent toolchain
result. `tools/verify.sh` then runs `native-metal-suite-test` as a separate
`-j1` hardware phase with the same temporary cache, Metal output directory,
prefix, and build graph. The compile frontier completes every suite artifact
and static check before the first suite device process starts, and shared
artifacts are not rebuilt through independent cold invocations. The aggregate
runs diagnostic readiness,
real-resource
allocation ownership, one production-native 20-dispatch workload report,
controlled disruption, the W7b-b3 paired-thread cancellation-storm profile,
the W7b-a segmented soak, the W7b-b1 post-segment process-kill profile,
the W7b-b4 controlled in-flight process-kill profile, the W7b-b5
supervisor/recovery-process death profile, build-isolated fault/reconciliation,
and focused correctness without overlap. Before each
60-second campaign, a bounded admission step requires two explicit nominal
observations ten seconds apart within 180 seconds after its prerequisites; the
campaign still fails on a non-nominal retained boundary. The readiness
sub-gate retains its one-dispatch contract. Metal assertions run, the
production CLI plus diagnostics cannot escape compilation, and all roots share
one shader-library build step. Each
segmented campaign executes 12 by 50 paced epochs and 1,200 real commands
across two worker generations, so use
`native-metal-soak-report-pure-test` for supervisor/store-only changes when
native execution is not required. Use
`native-supervisor-recovery-death-host-test` for the W7b-b5 lock, signal,
ready-frame, grant, prepared-selector, and fresh-audit protocol without GPU
work. Omit `-Dnative-metal-soak-output-dir` unless a verified store is
intentionally retained for offline reopening. Process RSS is a host
observation; `currentAllocatedSize` is device-wide allocation context rather
than residency or owned GPU memory. Physical metrics remain unsupported unless
a named observer supplies them. See the
[Native Metal Segmented Soak Report](NATIVE_METAL_SOAK_REPORT.md) for the exact
clean-restart gate and the
[Native Metal Process-Kill Recovery Report](NATIVE_METAL_PROCESS_KILL_REPORT.md)
for the W7b-b1 claim boundary.
The
[Native Metal Cancellation-Storm Report](NATIVE_METAL_CANCELLATION_STORM_REPORT.md)
defines the W7b-b3 release-barrier evidence and its no-lock-overlap,
no-kernel-cancellation, and no-performance boundary.
The
[Native Metal In-Flight Process-Kill Report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md)
defines the W7b-b4 build-isolated controlled event barrier, real PID-only kill,
fresh production control, and active-kernel/output/state/reclamation
nonclaims.
The
[Native Metal Supervisor and Recovery-Process Death Report](NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md)
defines the W7b-b5 generation-six supervisor-death audit,
prepared-generation-twelve recovery-process-death boundary, two real PID-only
kills, controlled barriers/timing/pause/grants, exact `11 -> 12` roll-forward,
and 3,520-byte Python/Zig verification boundary.
The separate
[Native Workload Store-Fault Report](NATIVE_WORKLOAD_STORE_FAULT_REPORT.md)
uses real host processes and filesystem calls with controlled errno injection;
it runs no model or GPU command and grants no physical-storage or power-loss
claim.
Verification uses one protected temporary workspace, shared private Zig and
SDK compiler-module cache directories, temporary target prefixes, `-j2` for
compile and portable work, `-j1` for the serialized Metal hardware phase, and
repository fixtures only.
The caches are reused across compatible compile and runtime phases, then
removed with the workspace on normal exit so repeated target matrices do not
grow a repository cache. Foreign configurations are not merged into one Zig
graph: each selected target receives exactly one invocation containing its
audited root union. No persistent repository cache is needed. The Debug quick
profile intentionally marks broad native, Python, Rust, sanitizer, and
cross-target work as skipped. `affected-fast` adds changed-path syntax and
focused high-risk gates while still deferring broad suites and foreign targets.
Neither is evidence that the deferred ReleaseSafe matrices passed. The matrix
profile intentionally retains full `install install-benchmarks test-compile`
coverage for all four targets.

Record an unsupported ThreadSanitizer environment as **not run**, not passed.

## Durable directory authority

Every POSIX namespace transaction that claims directory durability must acquire
`core.durable_directory_sync.AuthorityV1` before its first create, link,
rename, replace, or unlink operation. Acquisition preflights directory
synchronization and owns one sync-capable descriptor for the full transaction.
Use only the `Dir` returned by `borrow()` for namespace operations, never close
or retain that borrowed alias, sync file contents in protocol order, and finish
the namespace boundary with `authority.commit()`.

The original caller `Dir` is needed only during acquisition and may be closed
afterward. A successful commit leaves the same authority available when one
logical transaction has another declared directory boundary. A failed commit
poisons it: do not retry, borrow, or mutate through it; close it and enter the
adapter's normal reopen/recovery path. Do not add a direct POSIX `fsync` call or
restore the removed one-shot sync wrapper. The directory-authority policy test
keeps raw synchronization centralized and rejects legacy calls.

Real `fsync` calls and process-death campaigns verify ordering and recovery on
the named host filesystem. They are not evidence of controller flushes,
physical-media persistence, sudden power loss, or an exactly-once power-loss
protocol.

## Testing contracts, not just success paths

Glacier's value comes from rejecting unsafe transitions. Tests should cover the
relevant cases below:

- stale or reused handle;
- foreign receipt, root, or domain;
- mutated digest or field;
- overflow, underflow, and exact-capacity boundary;
- duplicate, reordered, or truncated event;
- abort before commit and failure during preparation;
- crash between durable append phases;
- unsupported layout, backend, precision, or platform;
- cancellation racing settlement or retirement.

Native fault controls must stay in a non-installed test artifact. The
production shim must export no test-control symbols, and a test that overlays a
published completion must retain the physical device result and the published
result as separate facts. Describe such a case as a test-induced publication
fault, not as a physical driver, hardware, or device-loss failure. It is also
conformance evidence, not performance evidence.

Property and mutation tests are especially useful when a fixed wire or state
machine has many equivalent failure locations.

## Changing a public format or wire

Open a design issue before changing a published ABI. A format change needs:

1. an explicit version or compatibility decision;
2. canonical encoding rules independent of struct layout;
3. checked length, range, overlap, and reserved-byte validation;
4. a valid golden fixture;
5. malformed, mutation, reorder, truncation, and substitution tests;
6. an independent verifier where the format carries evidence;
7. updated specification and migration notes.

Do not reinterpret existing bytes under the same ABI.

## Performance contributions

Performance work begins with a hypothesis and stop rule. Keep raw samples and
pair order, verify output or quality, capture machine conditions, and distinguish
logical counters from physical measurements. A faster fixture is not a general
runtime claim.

See [Benchmark and evidence guide](BENCHMARKS.md) and
[Evidence policy](EVIDENCE_POLICY.md) before publishing a result.

## Provider contributions

Provider core is intentionally credential-free. New work should first use a fake
renderer, token observer, and transport. A later live adapter must keep secrets,
network authority, provider-specific parsing, and raw payload logging outside the
core state machines.

Context packing removes only declared idempotent exact duplicates. Token counts
must come from the exact rendered wire and be reconciled before admission. Never
describe a fixture reduction as guaranteed billing savings.

## Pull-request expectations

A reviewer should be able to answer:

- What exact behavior changed?
- What authority or state can it mutate?
- Which inputs now reject?
- Which command verifies it?
- What does the result not prove?
- Can the change be reverted independently?

Generated model files, local binaries, credentials, private traces, and unrelated
workspace files must not be committed.

## Review and recognition

Review is a technical contribution. Helpful review identifies an invariant,
supplies a counterexample, improves a test, clarifies a claim boundary, or makes a
proposal easier to merge. Significant contributors may be invited to become
reviewers as described in [Governance](../GOVERNANCE.md).

All contributions are licensed under the repository's
[Apache License 2.0](../LICENSE).
