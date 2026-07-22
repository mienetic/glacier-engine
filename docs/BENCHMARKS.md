# Benchmark and Evidence Guide

Glacier treats benchmark output as evidence about one declared configuration,
not as a universal property of the project. A publishable result needs the raw
artifact, machine conditions, correctness gate, paired order, and an explicit
claim boundary.

## Evidence levels

| Level | Meaning | Suitable wording |
| --- | --- | --- |
| Conformance | A deterministic fixture satisfies a contract | “The fixture verifies…” |
| Diagnostic | One run exposes behavior for investigation | “This run observed…” |
| Paired experiment | Randomized same-machine pairs pass validity gates | “On this machine and workload…” |
| Replicated campaign | Several machines/workloads reproduce the effect | “Across the tested matrix…” |
| Release claim | Reproducible campaign, quality gates, and retained artifacts | Wording limited to the published matrix |

Passing a conformance demo does not establish throughput, physical memory,
energy, or production reliability.

## Current conformance surfaces

| Command | Contract exercised |
| --- | --- |
| `zig build lane-weave-demo -Dmetal=false` | Exact admission, deterministic weighted service, rejection, cancellation, final release |
| `zig build lane-publication-demo -Dmetal=false` | One-token prepare/commit/abort with KV, RNG, sampler, output, schedule, and resource roots |
| `zig build lane-contiguous-demo -Dmetal=false` | Concrete contiguous KV row publication and portable receipt |
| `zig build continuation-capsule-demo -Dmetal=false` | Fixed-size committed-checkpoint manifest, typed external object binding, and substitution rejection |
| `zig build continuation-resolver-demo -Dmetal=false` | Tenant-scoped exact-object lookup, bounded quotas, caller-owned output, and full composition verification |
| `zig build provider-gateway-demo -Dmetal=false` | Request coalescing, reservation, settlement, fixed-point cost, and journal append |
| `zig build provider-transport-demo -Dmetal=false` | Credential-free chunk and terminal-usage transport replay |
| `zig build provider-cancel-demo -Dmetal=false` | Consumer withdrawal and active transport cancellation |
| `zig build provider-context-pack-demo -Dmetal=false` | Lossless exact-duplicate mapping and deterministic token fixture |
| `zig build provider-context-reconciliation-demo -Dmetal=false` | Raw/packed full-wire token observations bound to one execution identity |
| `zig build provider-context-adapter-demo -Dmetal=false` | Allocation-free renderer/token-counter adapter fixture |

All commands should normally use `-Doptimize=ReleaseSafe` when validating
contracts. They are model-free and credential-free.

## Continuation checkpoint

The current fixture encodes a 608-byte manifest over nine external object types.
The demo's object payloads total 264 bytes but zero payload bytes are embedded in
the manifest; production model and KV objects can be much larger. Zig encoding
and verification are allocation-free. The independent Python suite shares the
golden root, flips every one of the 608 serialized byte positions, reseals the
outer digest where applicable, and requires rejection. A separately valid
foreign KV object also rejects.

This proves deterministic identity composition for the fixture. It does not yet
prove durable storage, live process restart, reduced RSS, content-addressed cache
savings, or recovery after power loss.

The resolver fixture then admits all nine objects under a 16-entry catalog-scan
limit, 64-byte per-object limit, exact 264-byte total limit, and nine-resolution
limit. It rejects stale, denied, repeated, cross-tenant, corrupt, ambiguous,
oversized, over-budget, overlapping, substituted, and post-resolution-mutated
inputs in native tests; an independent Python model checks the portable
identity and state semantics. This is conformance evidence for bounded lookup,
not a storage, RSS, latency, deduplication, or restart-performance result.

## Provider evidence checkpoint

The current provider fixture joins three independently replayed planes:

- one 1,645-byte committed cost-journal frame;
- one 5,984-byte gateway event stream;
- one 2,758-byte transport event stream;
- one fixed 712-byte `ProviderEvidenceJoinWire` manifest.

The manifest binds 20 digest fields representing the envelope and 19 semantic
roots. It does not copy the nested evidence. The Zig verifier replays each nested
format and the independent Python verifier checks the shared golden fixture. The
mutation suite rejects a single-byte change at every one of the 712 manifest byte
positions and rejects substitution of a valid but foreign transport stream.

This proves composition for the retained fixture. It does not prove the truth of
a provider's upstream usage report or grant filesystem/network authority.

The durable journal harness exercises process termination across append phases,
including 12 child-process kill cases. It checks body sync, footer sync, torn-tail
repair, poison/reopen behavior, advisory locking, path rejection, and replay.
Filesystem guarantees still need validation on each promoted platform.

## Context-efficiency checkpoint

The deterministic context fixture maps 440 logical tokens to 250 emitted tokens
and changes a conservative reservation from 490 to 300. The adapter fixture uses
one wiped 64-byte execution buffer where its comparison oracle uses two buffers
totalling 128 bytes.

These numbers are deliberately narrow:

- only exact rendered duplicates declared idempotent may share an emitted span;
- core stores hashes, mappings, and counts rather than prompt text;
- an external observer counts the exact rendered provider wire;
- the 64-byte result is a scratch-fixture property, not a general memory claim;
- logical and reserved-token reductions are not guaranteed billed-token savings.

## Measurement contract

### Identity

Retain:

- source commit and dirty-tree state;
- compiler, optimization mode, target, and feature flags;
- model/tokenizer hashes and runtime format identity;
- prompt or token fixture hash, seed, token count, and execution policy;
- benchmark harness version and schema.

### Machine envelope

Capture at minimum:

- hardware model, architecture, logical CPU count, and memory capacity;
- operating-system and kernel versions;
- power-source state when available;
- process priority, affinity policy, and requested worker count;
- load and memory state before each pair;
- warmup, cooldown, and execution timestamps;
- availability or absence of thermal, frequency, core-residency, and energy data.

The current envelope does not directly measure CPU temperature, effective
frequency, performance/efficiency-core residency, or package energy on every
host. “Plugged in” is useful context, not proof of equal machine state.

### Paired execution

Use randomized or balanced order within the same process and machine session:

```text
A B B A   or   B A A B
```

Each observation must name its pair and order. Reject a pair when cooldown, load,
correctness, configuration, or requested machine-state gates fail. Do not delete
valid slow samples because they are inconvenient.

### Metrics

For latency and throughput, retain per-sample values and report median, tail
quantiles, effect size, and uncertainty. Separate time-to-first-token, inter-token
latency, prefill, decode, and end-to-end latency.

For resources, label the evidence source:

- logical runtime ledger;
- allocator-observed bytes;
- process RSS or peak RSS;
- mapped/virtual bytes;
- device allocation or residency;
- energy/thermal sensor.

Never substitute one source for another in the claim.

### Correctness and quality

Performance pairs are invalid if the compared paths do not satisfy their declared
output contract. Depending on the experiment, use byte-identical tokens, bounded
numerical error, perplexity, task quality, or an explicitly different sampling
contract. Record the chosen gate before running the campaign.

## Reproduction

Core verification:

```sh
zig build test -Doptimize=Debug -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false
zig build test -Doptimize=ReleaseFast -Dmetal=false
python3 -m unittest discover -s bench/tests
```

Concurrency and portability gates:

```sh
zig build test -Doptimize=ReleaseSafe -Dmetal=false -Dsanitize-thread=true
zig build test-compile -Dtarget=x86_64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=aarch64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
```

Benchmark harnesses under `bench/` have their own `--help`, configuration, and
schema checks. Start with a tiny smoke run, inspect the artifact, then schedule a
campaign. Never publish only terminal output.

## Stop rules

Stop or redesign an experiment when:

- correctness or quality fails;
- the claimed resource is not directly observed;
- machine-state gates repeatedly fail;
- the effect disappears under paired order;
- overhead exceeds the declared budget;
- a representation adds complexity without a plausible end-to-end path;
- retained artifacts cannot be independently parsed.

Negative results are useful project evidence. Record the configuration and stop
reason in the relevant design document instead of hiding the result.
