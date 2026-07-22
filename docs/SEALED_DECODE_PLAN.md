# Sealed DecodePlan

Status: **experimental architecture track**. Several static layouts and strict
execution policies are integrated, but there is not yet one stable public sealed
plan ABI.

## Purpose

Decode repeatedly performs work whose structure does not change per token:

- model and tensor-role lookup;
- shape and group geometry validation;
- kernel and layout eligibility;
- scratch sizing and alignment;
- worker topology and partition boundaries;
- strict feature-policy compatibility.

A sealed plan validates this work once, binds its identity, and leaves only
dynamic token data and state transitions in the hot path.

## Four identities

A safe plan distinguishes:

1. **Model identity** — exact source/prepared content and configuration.
2. **Layout identity** — physical streams, shapes, alignment, and representation.
3. **Execution identity** — backend, ISA, kernel ABI, worker topology, and strict
   policies.
4. **Instance identity** — live model mapping, allocator/scratch ownership, and
   epoch.

Equal model bytes do not authorize a plan built for another mapping, backend,
layout, or instance generation.

## Static and dynamic work

| Sealed before decode | Supplied for each request/token |
| --- | --- |
| model and runtime-image roots | input token and position |
| tensor roles and physical views | committed KV root/state |
| kernel eligibility and exact fallback | RNG and sampler state |
| group/tile geometry | live lanes and cancellation |
| worker partition | ResourceBank and LaneWeave permits |
| scratch offsets and upper bounds | output sink acknowledgement |
| strict required policies | dynamic eligible-output certificate |

The plan may point into a live mapped model only through an instance-fenced
owner. Portable evidence stores identities and geometry, never raw process
pointers.

## Lifecycle

```text
unvalidated inputs
       │
       ▼
plan build ──failure──> no live plan
       │
       ▼
sealed plan ──bind──> live instance
       │                    │
       │                    ├─ execute token transactions
       │                    └─ reject stale/mismatched request
       ▼
retire instance → invalidate epoch → release scratch/model views
```

Plan creation must be side-effect-free until all bounds and capabilities pass.
Retiring an instance waits for active users or fails explicitly; it cannot free
memory still reachable by a token transaction.

## Resource contract

The plan declares exact upper bounds for persistent executor state, per-request
state, worker scratch, activation frames, KV requirements, and optional output
domains. ResourceBank admission uses those bounds before construction or
execution.

Smaller logical scratch declarations are not physical-memory proof. Campaigns
must separately observe allocator and process/device behavior.

## Strict policies

Experimental paths are selected with required policies such as prepared-image,
MLP layout, compact frame, paged KV, attention schedule, or constrained-output
mode. When a required feature is unavailable, the plan builder rejects. It does
not construct a different plan and label it equivalent.

The default checked path remains available under an explicit policy and serves as
the semantic oracle for same-binary experiments.

## Constrained output

A future or experimental plan may accept a verified eligible-token domain from a
grammar or policy provider. The certificate must bind request, prefix, step,
model/tokenizer identity, complete-domain authority, and bitset digest.

Post-head mode can use the same certified set only in the reducer. Pre-head mode
may skip projection work only when a qualifying kernel receives that exact
private certificate. Missing, stale, empty, malformed, or foreign certificates
reject the step; they never fall back under a `required` policy.

The certificate establishes which tokens are eligible only if its provider is a
trusted authority for that statement. A digest cannot prove grammar semantics by
itself.

## Relationship to token publication

DecodePlan produces candidate computation under a declared execution ABI. The
token transaction remains the publication authority. A plan cannot directly
advance KV, RNG, counters, or output; its results must be staged, acknowledged,
and committed through the exact ResourceBank and LaneWeave permits.

This separation allows plan caching without caching commit authority.

## Failure requirements

Tests must reject:

- model, layout, backend, kernel, or policy mismatch;
- stale live-instance epoch or use after retirement;
- undersized, overlapping, or misaligned scratch;
- arithmetic overflow in shape or extent derivation;
- unsupported worker topology;
- changed prepared-image fingerprint;
- missing strict capability;
- mutated eligible-output certificate;
- executor failure before publication.

Failures must not partially publish token state or leave ResourceBank ownership
unreleased.

## Promotion gates

A stable public plan ABI requires:

1. one canonical serializable descriptor without process pointers;
2. versioned model/layout/execution/instance identities;
3. exact resource upper bounds checked by ResourceBank;
4. mutation-complete compatibility tests;
5. integration across the supported model/backend matrix;
6. same-output or declared-quality gates against the checked path;
7. paired end-to-end evidence showing the sealed work improves a user-visible
   metric without hidden resource regressions;
8. documented migration and retirement behavior.

Until these gates pass, plan fields and experimental strict policies may change.

## Contributor slices

- Render a plan descriptor without pointers.
- Add one missing extent-overflow test.
- Build a fake instance-retirement race test.
- Bind one kernel capability to the execution identity.
- Compare declared scratch with allocator-observed bytes.
- Add a portable golden fixture for the current static geometry.

Each slice should preserve the checked path and avoid performance wording unless
it also supplies the evidence required by [Benchmarks](BENCHMARKS.md).
