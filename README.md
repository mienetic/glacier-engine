<p align="center">
  <img src="assets/brand/glacier-engine-logo.png" width="190" alt="Glacier Engine logo">
</p>

<h1 align="center">Glacier Engine</h1>

<p align="center"><strong>A proof-carrying runtime for local and provider-backed AI execution.</strong></p>

Glacier Engine is an experimental AI systems project written in Zig. It treats
resource admission, scheduling, KV ownership, token publication, provider usage,
and cost as explicit state transitions that can be rejected, replayed, and
verified.

The project is early enough for contributors to shape its public APIs and mature
enough to offer tested building blocks, credential-free demos, portable evidence
formats, and independent verifiers.

> **Project status:** experimental. The core contracts are heavily tested, but
> model coverage, platform coverage, API stability, packaging, and production
> operations are still under active development.

## Why Glacier Engine

- **Atomic token publication.** KV rows, RNG state, sampler counters, and output
  words are committed together or remain invisible.
- **Exact resource admission.** `ResourceBank` and `LeaseTree` make logical
  ownership and release part of the execution contract.
- **Deterministic multi-request scheduling.** `LaneWeave` provides bounded,
  weighted service with replayable decisions and fail-closed permits.
- **Paged KV ownership.** Physical page identity, generations, references, and
  publication fences are bound into token receipts.
- **Proof-carrying continuation.** A fixed-size manifest binds model, tokenizer,
  plan, resource, schedule, KV, sampler, output, and publication state without
  duplicating those external objects.
- **Tenant-scoped object resolution.** A least-authority grant admits only exact
  capsule objects under bounded scan, object, total-byte, and resolution limits.
- **Canonical continuation bundles.** Semantic roots remain kind-specific while
  equal in-tenant payloads receive one deterministic storage blob ordinal.
- **Bounded tenant object storage.** Atomic in-memory bundle import owns one copy
  per unique blob with exact payload, index, and reference accounting.
- **Verifiable provider operations.** Request coalescing, cancellation,
  settlement, cost journals, transport events, and a compact evidence root can
  be checked without provider credentials.
- **Lossless context packing.** Exact rendered duplicates declared idempotent by
  the caller can share one emitted span while every logical span remains mapped.
- **Evidence-aware performance work.** Benchmarks record machine conditions,
  paired execution order, correctness gates, and explicit claim boundaries.

## What you can build with it

Glacier Engine is useful for AI infrastructure work where a result alone is not
enough:

- local inference experiments with explicit model and memory layouts;
- agent or batch systems that need fair, bounded scheduling;
- provider gateways that need token, retry, cancellation, and cost accounting;
- durable audit records for AI requests without storing prompt text in core
  evidence structures;
- fault-injection research for KV, output, RNG, and journal publication;
- reproducible runtime, kernel, format, and verification research.

The provider context fixtures demonstrate a logical count change from 440 to
250 tokens and a reservation change from 490 to 300. Those are deterministic
fixture results—not proof of lower billed tokens for every provider or workload.

## Architecture at a glance

```text
request
  │
  ├─ ResourceBank ── exact claim, receipt, LeaseTree
  │
  ├─ LaneWeave ───── admission, fairness, service permit
  │
  ├─ execution ───── CPU / Metal, prepared image, paged KV
  │
  └─ publication ─── KV + RNG + sampler + output (one transaction)
                         │
                         ├─ portable receipts and replay roots
                         └─ ContinuationCapsule (typed external object roots)
                                  │
                                  ├─ bounded tenant-scoped object resolver
                                  ├─ canonical tenant bundle
                                  └─ bounded in-memory object store (no file I/O)

provider request
  │
  ├─ ContextPack ─── lossless mapping and token reconciliation
  ├─ Gateway ─────── coalescing, cancellation, usage settlement
  ├─ CostJournal ─── crash-recoverable append and replay
  └─ EvidenceJoin ── compact root over gateway, transport, and cost evidence
```

See [Architecture](docs/ARCHITECTURE.md) for the component map and
[Design](docs/DESIGN.md) for the invariants behind it.

## Quick start

Requirements:

- Zig 0.15.0 or newer;
- macOS or Linux;
- Python 3 for the independent evidence tests.

Build the portable CLI and run two model-free demos:

```sh
zig build -Doptimize=ReleaseSafe -Dmetal=false
./zig-out/bin/glacier --version

zig build lane-publication-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-capsule-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-resolver-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-bundle-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-store-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build provider-gateway-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the main verification suites:

```sh
zig build test -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest discover -s bench/tests
```

The first build may take a few minutes. Subsequent builds use Zig's cache. For
model conversion, generation, and every demo command, continue with the
[Quickstart guide](docs/QUICKSTART.md).

## Current feature map

| Area | Available today | Next public milestone |
| --- | --- | --- |
| Runtime | CPU execution, optional Metal backend, INT4 paths, prepared `.glrt` images | Broader model and platform validation |
| State | Token transactions, capsule, bounded resolver, canonical bundle, in-memory tenant store | Leases, durable publication, ownership reacquisition, and restart |
| Scheduling | Exact admission and deterministic weighted QoS | Multi-tenant pressure and cancellation campaigns |
| Providers | Context packing, gateway, transport harness, settlement and cost wires | Pluggable live adapters outside the credential-free core |
| Evidence | Hash-chained events, independent Python verifiers, compact provider evidence join | Human-readable inspection tooling |
| Tooling | Zig build, deterministic demos, benchmark harnesses | Installer, stable library surface, simpler fixture workflow |

Detailed status, acceptance gates, and contributor-sized work items live in the
[roadmap](docs/ROADMAP.md).

## Choose a contribution

You do not need AI kernel experience to contribute. Useful work includes Zig,
Python, Metal, Linux portability, property tests, fault injection, documentation,
format tooling, visualizers, examples, and reproducibility.

Good starting points:

1. Read [Contributing](docs/CONTRIBUTING.md) and pick a small item from
   [Contributor projects](docs/PROJECTS.md).
2. Open a **Claim a contributor slice** issue describing one mergeable outcome
   and its acceptance command.
3. Submit a focused pull request. Draft pull requests are welcome.

Maintainers will help reduce an ambitious idea into an independently mergeable
slice. Correctness fixes, clearer explanations, and rejection-path tests are as
valuable as new features.

## Documentation

- [Quickstart](docs/QUICKSTART.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Contributor projects](docs/PROJECTS.md)
- [Benchmark and evidence guide](docs/BENCHMARKS.md)
- [Evidence policy](docs/EVIDENCE_POLICY.md)
- [Model format](docs/FORMAT_SPEC.md)
- [Native runtime image](docs/RUNTIME_IMAGE.md)
- [Paging contract](docs/PAGING.md)
- [Continuation capsule](docs/CONTINUATION_CAPSULE.md)
- [Continuation object resolver](docs/CONTINUATION_OBJECT_RESOLVER.md)
- [Continuation bundle](docs/CONTINUATION_BUNDLE.md)
- [Continuation object store](docs/CONTINUATION_OBJECT_STORE.md)
- [Glossary](docs/GLOSSARY.md)

Research tracks are documented separately in
[Prism Decode](docs/PRISM_DECODE.md) and
[Sealed DecodePlan](docs/SEALED_DECODE_PLAN.md). They are proposals with explicit
promotion and stop gates, not production promises.

## Project principles

1. Fail closed when identity, ownership, capacity, or evidence is ambiguous.
2. Publish AI-visible state atomically.
3. Keep logical accounting separate from physical measurements.
4. Bind claims to reproducible artifacts and honest scope boundaries.
5. Design large ideas as small contributions that can merge independently.

## Community and support

Questions and design discussions belong in GitHub issues. Please read
[Support](SUPPORT.md), [Governance](GOVERNANCE.md), and the
[Code of Conduct](CODE_OF_CONDUCT.md) before participating. Report sensitive
vulnerabilities through the private process in [Security](SECURITY.md).

## License

Glacier Engine is available under the [Apache License 2.0](LICENSE).
