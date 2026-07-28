# Dense-Tensor Reranker

Status: **integrated retained reference fixture**.

Glacier now has a non-media stateless model-family path for deterministic
reranking. It accepts a bounded batch of dense `i16` feature rows, scores each
row against one `i8` query vector with an overflow-checked `i64` accumulator,
and publishes canonical ranked items through the shared stateless adapter,
`ResourceBank`, and optional LaneWeave lifecycle.

This slice is deliberately download-free. It proves typed batch identity,
ranking policy, candidate validation, atomic result publication, cancellation,
and exact ownership release. It does not claim production model quality.

## Public contract

The retained profile declares:

- family `stateless_encoder`;
- operation `rerank`;
- input kind `dense_tensor`;
- output kind `ranked_items`;
- numerical policy `exact_integer`;
- at most 64 batch items and 4,096 input features;
- exactly one ranked-item output dimension; and
- zero ambient capabilities.

The reference profile is append-only registry index 8 with slug
`dense-tensor-reranker-reference`. Existing registry indices keep their
original meanings.

## Canonical batch and result records

`stateless_tensor_result.zig` defines three independent values:

1. A bounded batch map assigns every nonzero, unique item ID to its canonical
   zero-based input ordinal. Its variable-length wire carries an exact count,
   fixed entry width, and a domain-separated footer.
2. A fixed score policy declares no normalization, descending score order, and
   ascending input ordinal as the only V1 tie break.
3. A ranked result contains exactly one fixed-width item per batch entry. Each
   item carries the item ID, input ordinal, rank, signed `i64` score, and a
   domain-separated record root bound to the exact batch-map and score-policy
   roots.

A valid result must be a complete permutation of the batch map. Ranks are
contiguous, scores never increase as rank advances, and equal scores preserve
input-ordinal order. Truncation, duplicate IDs or ordinals, reordered ranks,
foreign batch maps, foreign policies, and record mutation fail closed.

## Non-media input binding

`ModelExecutionPlanV1` predates the generic tensor slice and retains several
field names first used by media adapters. The reranker does not reinterpret
those roots as media. It defines one explicit compatibility projection:

| Plan V1 field | Dense-tensor meaning |
| --- | --- |
| `media_object_sha256` | caller-declared input-object root |
| `processor_state_sha256` | canonical batch-map root |
| `processor_bundle_sha256` | canonical score-policy root |
| `cache_bundle_sha256` | caller-declared input-bundle root |
| `cache_payload_sha256` | exact dense-tensor payload root |
| `ownership_sha256` | exact request ownership root |
| `challenge_sha256` | exact publication challenge |

The family wrapper validates every projection before backend execution and
derives a separate source-mapping root over the complete binding. No random
sentinel root is accepted as evidence.

## Execution and publication

The wrapper reuses `stateless_model_adapter.Session`:

1. validate the artifact, plan, support row, tensor binding, batch map, and
   score policy;
2. reserve or adopt the exact plan claim;
3. execute into caller-owned provisional storage;
4. validate the full ranked permutation and policy before visibility;
5. publish the typed `ResultEnvelopeV1` atomically, or scrub and abort the
   provisional result; and
6. cancel or retire the lifecycle until Scheduler and Bank ownership return to
   zero.

The scheduled path adopts the LaneWeave receipt instead of reserving the same
claim a second time. Final visibility still occurs only through the service
finalizer.

## Verification boundary

The retained fixture includes four item IDs and an intentional equal-score
pair. Zig tests cover the direct and scheduler-owned paths, deterministic tie
ordering, candidate drift, cancellation, capacity rejection, malformed maps
and results, and final zero ownership.

The download-free demo emits the canonical batch map, score policy, ranked
result, typed result roots, and decoded items as one JSON record. An independent
standard-library Python verifier decodes and recomputes the batch, policy,
integer scores, ranked-element roots, and output root without loading Glacier
code. It also requires the emitted source-mapping and result
digests to be canonical nonzero SHA-256 values; it does not reconstruct those
two lifecycle roots from a plan.

Run the focused gates with:

```sh
zig build dense-tensor-reranker-test -Dmetal=false
zig build runtime-support-inspector-test -Dmetal=false
```

## Current nonclaims

This retained profile does not establish:

- semantic relevance, calibrated scores, or production model quality;
- floating-point normalization, learned pooling, cross-encoder tokenization,
  or variable query/document shapes;
- GPU execution, device residency, provider routing, or network serving;
- a stable C model-execution ABI; the C surface exposes discovery for this
  reranker, not reranker execution;
- persistence or restart of an in-flight stateless rerank request; or
- performance, energy, thermal, or multi-OS native evidence.

## Contributor entry points

The same bounded contracts now support the normalized embedding fixture and
can support independent follow-ups:

- compose the normalized embedding into an in-memory retrieval fixture;
- add class-score publication and a stable label map;
- build an in-memory retrieval fixture that feeds exact top-k candidates into
  this reranker;
- add a production adapter without changing batch/result identity;
- add bounded float policies with declared tolerances and independent oracles;
  or
- add provider and device adapters while preserving the shared publication and
  ownership lifecycle.
