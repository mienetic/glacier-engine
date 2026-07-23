# Continuation Ownership Restore v1

Status: prototype. The wire contract and model-free reacquisition path are
implemented and independently verified. The next layer now restores paged-KV
bytes into fresh cache/page generations, and the runtime layer composes those
objects into a model-free two-process publication proof.

## Purpose

Durable payload bytes are not enough to resume safely. A fresh process also
needs to reconstruct who owns each bounded allocation, which tenant scope it
belongs to, which publication sequence may run next, and which ResourceBank
authority is allowed to account it.

`ContinuationOwnershipManifest v1` is the `resource_state` object of a
continuation capsule. It binds:

- the source and target ResourceBank epochs;
- the source receipt generation and target owner identity;
- the exact request, checkpoint, and next publication sequence;
- one parent claim and one LeaseTree ceiling;
- up to four canonical tenant scopes;
- up to sixteen canonical allocation identities and claims;
- a typed, length-bound root for every materialized object;
- the tenant-scoped durable payload snapshot root; and
- one shared checkpoint challenge.

The manifest is evidence and a restore plan. It does not authenticate its own
creator, allocate memory, open files, or publish output.

## Restore ordering

```text
capsule + ownership manifest + payload snapshot
                  │
                  ▼
       verify all roots and scalar identity
                  │
                  ▼
       require a fresh target Bank epoch
                  │
                  ▼
 reserve parent → commit receipt → open tree/scopes
                  │
                  ▼
 bind exact restored publication sequence
                  │
                  ▼
 reserve and charge every allocation
       state = reserved_unmaterialized
                  │
                  ▼
 caller reconstructs private object bytes
                  │
                  ▼
 verify kind + length + domain-separated root
                  │
                  ▼
 commit batch; state = live
                  │
                  ▼
 publication may begin at the restored sequence
```

No allocation becomes `live` before its complete batch is charged. A
materialized-byte mismatch leaves the batch safely charged and pending so the
caller can retry or free private allocations and call the explicit abort path.

## Fixed wire

The encoded manifest is exactly 3,360 bytes.

| Region | Bytes | Contents |
| --- | ---: | --- |
| Header | 384 | Magic, ABI, epochs, sequence identity, counts, claims, tenant/payload/challenge roots, zero reserved field |
| Scope table | 384 | Four fixed 96-byte entries |
| Allocation table | 2,560 | Sixteen fixed 160-byte entries |
| Footer | 32 | Domain-separated SHA-256 of the complete body |

Unused entries must be all zero. Scope keys are unique and strictly ordered.
Allocation entries are strictly ordered by scope ordinal, node key, binding
key, kind, and object root. A `(scope, node)` identity and a binding key may each
appear only once.

Each allocation entry contains:

| Field | Meaning |
| --- | --- |
| Scope ordinal | Index into the canonical scope table |
| Node key | Durable logical allocation identity |
| Binding key | Unique binding presented to LeaseTree |
| Kind | KV page, output journal, sampler state, or runtime object |
| Object byte length | Exact private materialization length |
| Claim | Exact logical ResourceBank charge |
| Object SHA-256 | Domain-separated kind/length/byte root |

The current caps are deliberately small and fixed. Increasing them requires a
new ABI instead of silently changing memory or verification cost.

## Authority and replay rules

The target Bank must:

- have the exact `restore_bank_epoch`;
- use an epoch different from the source Bank;
- have zero current and peak usage;
- contain no reservation, receipt, child lease, tree, scope, or allocation;
- have no prior successful admission or LeaseTree transition; and
- have sufficient fixed node capacity and hard limits for the complete plan.

This freshness check rejects a second reacquisition into the same Bank before
any mutation. The source receipt is stale in the target Bank because its epoch
differs. A target epoch is therefore an authority identity and must not be
reused for two independently live Bank instances.

`bindRestoredPublicationSessionWithLeaseTree` is the only restore-specific
ResourceBank entry point. It accepts a validated current tree, rejects a source
epoch equal to the target, and installs the exact nonzero next sequence without
manufacturing intermediate publications.

## Public operations

The portable Zig module exposes:

- `encodeV1` and `decodeV1` for the canonical wire;
- `decodeAndVerifyBindingsV1` for capsule, resource-state, challenge, sequence,
  and payload-snapshot composition;
- `prepareReacquireV1` for fresh-Bank admission and charged allocation reserve;
- `commitMaterializedV1` for exact byte verification followed by lifecycle
  commit;
- `abortPreparedReacquireAfterFreeV1` for caller-ordered rollback; and
- `materializedObjectRootV1` for typed object identity.

The Python verifier in `bench/continuation_ownership_manifest.py` is an
independent codec and semantic model. It does not call Zig.

## Evidence

The shared model-free fixture has:

- two tenant scopes;
- one 8-byte KV claim and one 6-byte output-journal claim;
- a 128-byte parent capsule claim plus one queue slot;
- source Bank epoch 41 and target Bank epoch 42; and
- restored publication sequence 7.

Zig and Python agree on manifest root:

`59c777c9a576fdc87ecf8bb1d18ffbf1e98b30eef88e1ec8a5b312bfe68f394f`

Both implementations reject mutation of every one of the 3,360 encoded byte
positions. They also reject a semantic contradiction after the attacker-facing
fixture recomputes the outer root. Native tests prove that a wrong materialized
object stays `reserved_unmaterialized`, exact bytes become `live`, the restored
sequence can acquire a publication permit, a second restore into the same Bank
fails, and the old source receipt is stale.

Run focused verification:

```sh
zig test src/core/continuation_ownership_manifest.zig -OReleaseSafe
python3 -m unittest \
  bench.tests.test_continuation_ownership_manifest
```

## Evidence boundary

This prototype proves canonical ownership-plan identity and safe in-memory
reacquisition into a fresh ResourceBank/LeaseTree. The payload snapshot is
verified before admission, but this module does not itself perform filesystem
I/O. The current object-store lease, quarantine, reference, and repair metadata
are not yet restored through this plan.

It does not yet prove:

- accelerator allocation reconstruction;
- tokenizer or production-model reconstruction;
- cross-process prevention if an operator reuses one target epoch;
- device power-cut durability;
- native Linux filesystem recovery; or
- lower latency, memory use, disk use, token use, or energy.

The implemented
[paged-KV restore layer](CONTINUATION_PAGED_KV_RESTORE.md) joins allocation
entries to canonical page images, rebuilds page-map generations under the
reacquired nodes, and rejects foreign or stale page generations before any
publication can begin. The
[live-restart layer](CONTINUATION_LIVE_RESTART.md) adds sampler/RNG/output
composition and a visible natural-exit process restart. The
[checkpoint-file layer](CONTINUATION_CHECKPOINT_FILE.md) then adds atomic
whole-checkpoint root selection and seven-phase process-death recovery.
