# Continuation Live Restart v1

Status: prototype. A model-free source process publishes one token, synchronizes
a complete checkpoint fixture, releases all logical ownership, and exits. A
fresh target process verifies the checkpoint, reacquires ownership, remaps the
paged-KV cache, restores RNG/sampler/output state, and publishes the next token
exactly once.

## Purpose

A set of valid checkpoint objects is not yet a running request. The target also
needs one canonical runtime position that joins:

- the request epoch and exact next publication sequence;
- checkpoint generation and committed KV length;
- RNG words and sampling-call count;
- the visible output prefix;
- the previous publication commit;
- the logical KV digest; and
- the checkpoint challenge.

`RuntimeStateV1` binds those values into one fixed wire. The same bytes occupy
the capsule's sampler, output, and publication-receipt slots under their
distinct typed object domains. Full capsule verification therefore rejects a
valid runtime object substituted into the wrong checkpoint composition.

## Fixed runtime wire

The runtime state is exactly 304 bytes.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GCLIVE01` magic |
| 8 | 8 | Runtime-state ABI |
| 16 | 8 | Exact encoded length |
| 24 | 4 | Flags; currently zero |
| 28 | 4 | Reserved; must be zero |
| 32 | 8 | Request epoch |
| 40 | 8 | Exact next publication sequence |
| 48 | 8 | Checkpoint generation |
| 56 | 8 | Committed KV token count |
| 64 | 8 | Visible output token count |
| 72 | 8 | Sampling-call count |
| 80 | 32 | Four little-endian RNG words |
| 112 | 32 | Previous publication commit SHA-256 |
| 144 | 32 | Logical KV SHA-256 |
| 176 | 32 | Checkpoint challenge SHA-256 |
| 208 | 64 | Sixteen fixed output-token slots |
| 272 | 32 | Domain-separated body SHA-256 |

Unused output slots must be zero. The fixed sixteen-token ceiling belongs to the
conformance fixture, not a proposed production output limit.

## Restore and publication ordering

```text
source process
  publish token 503
       │
       ▼
  encode capsule + ownership + pages + runtime state
       │
       ▼
  sync each fixture file and the directory
       │
       ▼
  retire pages → release LeaseTree/Bank → exit

fresh target process
  verify every capsule object and runtime field
       │
       ▼
  reacquire charged ownership at sequence 18
       │
       ▼
  rebuild paged KV under a different cache identity
       │
       ▼
  verify logical KV digest + restored output/RNG position
       │
       ▼
  prepare row 18 privately and acquire publication permit
       │
       ▼
  atomically publish KV + RNG + sampler + output + commit
       │
       ▼
  retire pages → release LeaseTree/Bank → usage zero
```

`resumeOneTokenV1` performs all fallible validation and private row preparation
before it acquires the exact ResourceBank publication permit. Its bounded commit
suffix advances the page-map root, logical KV digest, RNG, sampling counter,
output prefix, commit chain, and publication fence together.

The bridge rejects a row that would allocate a new physical page. Page
allocation must first use the leased allocation planner so the Bank charges it
before allocator materialization. The demonstration checkpoints a reusable
second page, so the resumed row needs no new allocation.

## Cross-process identity remap

Cache-instance counters are process-local. After a restart, an ordinary fresh
cache could receive the same numeric instance as the source cache even though
it represents different authority.

`PagedKVCache.initForCheckpoint` detects that collision and reserves another
target instance before restore. `restoreCheckpointV1` independently requires
source and target instances to differ. Historical source refs therefore remain
invalid even when a process-local allocator restarts from its initial value.

## Evidence

The two-process fixture proves:

- source and target operating-system process identifiers differ;
- the source publishes token `503` at sequence `17`;
- the target resumes at sequence `18` and publishes token `504`;
- visible output is exactly `[501, 502, 503, 504]`;
- the target receipt chains to the source commit;
- restored and post-publication logical KV digests match their live caches;
- source and target cache instances differ; and
- both source and target teardown return Bank usage to zero.

The fixed runtime fixture has footer:

`3817f7c8078688de1b22072e8bc2f45a801f2de0d3b825d4cfdada6135b0ada9`

Zig and the independent Python verifier agree on output root
`9ee5866300196621498083280108d1cc36b322c28e93a234d20b231b8c6a42e2`
and receipt root
`42fd59983f808664141334276a05bec497b8ebae91a728094ca926b60916ebb7`.
Both reject mutation of every runtime-wire byte and stale publication position.

Run the full process-boundary proof:

```sh
zig build continuation-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest \
  bench.tests.test_continuation_live_restart
```

## Evidence boundary

This is a model-free natural-exit process restart. It does not yet prove:

- one atomic durable promotion for the complete multi-file checkpoint set;
- recovery after termination at every checkpoint write/promotion phase;
- device power-cut durability;
- production model or tokenizer reconstruction;
- numerical equivalence for production kernels;
- accelerator residency, worker pins, or a complete leased-paged coordinator;
- output prefixes longer than the fixed conformance wire; or
- restart latency, throughput, RSS, disk, token, or energy improvements.

The next durability slice should publish the complete checkpoint set through one
root-selected candidate/active protocol, inject process death at every durable
phase, and accept only the previous or complete successor checkpoint.
