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

The default quick profile uses no model or provider credentials and reports
every gate as `PASS`, `FAIL`, or `SKIP` with a reason. Run
`tools/verify.sh affected --base origin/main` to select the union of checks for
your branch, or `tools/verify.sh full` when you need the broad local ReleaseSafe
and Python suites.

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
- Write comments that explain invariants and authority, not line-by-line syntax.
- Use relative Markdown links and explain project-specific terms in the
  [glossary](GLOSSARY.md).
- Do not publish unsupported performance superlatives. State only what retained
  evidence supports.

## Verification matrix

The quick and full profiles remain stable contributor entry points. The
affected profile adds every row needed by the complete changed-path set; one
narrow change never hides the checks required by another changed path.

| Change | Required checks |
| --- | --- |
| Documentation or metadata only | Quick profile, links, spelling/manual review |
| GitHub workflow, action, or dependency automation | Quick gates, native ReleaseSafe, Python discovery, and every retained target |
| Python verifier, harness, or retained result | Changed-file Python syntax and full Python unittest discovery; no foreign Zig target |
| POSIX shell script | Syntax under its declared `sh` or `bash` shebang |
| Retained Rust interop consumer | Native Rust contract gate only; `rustc` is required, but foreign Zig targets cannot compile or validate this runtime consumer |
| Other Rust build input | Native Rust contract gate, native ReleaseSafe, Python discovery, and every retained target until its build graph is classified |
| Retained runtime interop `.hex` fixture | Quick C/C++/Python replay, full Python discovery, and the native Rust contract gate; no foreign Zig target; new fixture paths remain conservative until classified |
| Benchmark runtime data (`.ids`, paired manifests, evaluation text) | Full Python discovery; no foreign Zig target |
| Darwin Swift ProcessInfo probe | Full Python discovery plus focused native `swiftc -typecheck`; no broad Zig or foreign-target build |
| Audited C contract boundary | Native ReleaseSafe, Python discovery, and the core compile profile on every retained target |
| General `src/core/` implementation | Native ReleaseSafe, Python discovery, and the complete consumer compile closure on every retained target; `src/core/root.zig` remains full because it controls build reachability |
| CPU backend or model implementation | Native ReleaseSafe, Python discovery, and the complete consumer compile closure on every retained target |
| Shared durable core/runtime implementation | Native ReleaseSafe, Python discovery, and the complete consumer compile closure on every retained target |
| Audited durable recovery demo or worker | Native ReleaseSafe, Python discovery, and the durable profile on every retained target |
| CLI or retained read-only inspector | Native ReleaseSafe, Python discovery, and the host-tool profile on every retained target |
| Shared root, unclassified Zig/C/C++/header, or build input | Native ReleaseSafe, Python discovery, and the full production-install, benchmark-install, and test-compile roots on every retained target |
| AArch64 NEON/CRC C kernel | Native ReleaseSafe with explicit Apple Silicon (`arm64`/`aarch64`) Darwin evidence, Python discovery, and the CPU plus downstream host-tool profiles on the retained AArch64 Linux target; Intel macOS and Rosetta report unavailable instead of reusing an unrelated x86_64 pass |
| Linux-specific runtime | Native ReleaseSafe plus both retained Linux targets |
| Windows-specific runtime | Native ReleaseSafe plus the retained Windows target |
| FreeBSD-specific runtime | Native ReleaseSafe plus the retained FreeBSD target |
| Shared POSIX runtime | Native ReleaseSafe, explicit Darwin evidence, both Linux targets, and FreeBSD; the Darwin label reuses the native suite instead of compiling twice |
| Darwin- or macOS-specific runtime | Native Darwin ReleaseSafe tests; a non-Darwin skip is not passing evidence |
| Metal backend | Native Darwin Metal tests; a non-Darwin skip is not passing evidence |
| Unknown input under a code tree | Conservatively use every retained target |
| Concurrency or locking | Zig modes above, ThreadSanitizer where supported, fault/recovery tests |
| On-disk or wire ABI | Encoder/decoder tests, golden fixture, mutation/reorder/truncation tests, independent verifier |
| Performance | Correctness matrix plus the measurement contract in `BENCHMARKS.md` |

Common commands:

```sh
tools/verify.sh
tools/verify.sh affected --base origin/main
GLACIER_VERIFY_BASE=origin/main tools/verify.sh affected
GLACIER_VERIFY_REQUIRE_NATIVE=1 tools/verify.sh affected --base origin/main
tools/verify.sh full
tools/verify.sh matrix

zig build test -Doptimize=Debug -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false
zig build test -Doptimize=ReleaseFast -Dmetal=false
python3 -m unittest discover -s bench/tests

zig build test -Doptimize=ReleaseSafe -Dmetal=false -Dsanitize-thread=true
```

`affected` resolves the merge base of `HEAD` and the explicit `--base` value
(or `GLACIER_VERIFY_BASE`). It then unions four independent NUL-delimited path
streams: merge base to `HEAD`, `HEAD` to the index, index to worktree, and
untracked files. Keeping those states separate prevents a worktree reversal
from hiding a committed or staged change. Whitespace and newlines in a valid
Git path do not change the selection. The command prints every deduplicated
path, its selection reason, the union of gates, and the selected targets. A
missing base, Git, Python, or required Zig toolchain is a failure rather than a
silent pass.

Changed `.sh` files must declare one of the retained `sh` or `bash` shebangs;
syntax is checked by that interpreter. Changed Rust source makes the native
Rust gate required rather than optional. On a non-Darwin host, selected Darwin
and Metal gates remain visible `SKIP` results for ordinary contributor
planning. CI and release verification should set
`GLACIER_VERIFY_REQUIRE_NATIVE=1`, which turns either unavailable selected
native gate into `FAIL`.

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
Build controls, roots, and unknown paths fail closed to the explicit
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
executables. `zig build run` also builds only the CLI. Metal-only changes use
one native Darwin Zig invocation containing the
`native-metal-observation-test` hard gate, the focused
`native-metal-correctness-test`, and the orthogonal device and host-tool compile
profiles, so Metal assertions run and the production CLI plus diagnostics
cannot escape compilation. The readiness sub-gate retains its one-dispatch
contract and completes before the additional correctness dispatches begin; all
roots share one shader-library build step.
Verification uses one protected temporary workspace, shared private Zig cache
directories, temporary target prefixes, `-j2`, and repository fixtures only.
No persistent repository cache is needed. The quick profile intentionally
marks broad native, Python, Rust, sanitizer, and cross-target work as skipped;
it is a contributor smoke gate, not evidence that those matrices passed. The
matrix profile intentionally retains full
`install install-benchmarks test-compile` coverage for all four targets.

Record an unsupported ThreadSanitizer environment as **not run**, not passed.

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
