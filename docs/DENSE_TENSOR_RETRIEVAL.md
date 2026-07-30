# Dense-Tensor Retrieval

Status: **integrated experimental retained reference fixture**.

Glacier has a download-free fixed-corpus retrieval path for normalized dense
embeddings. A sealed index artifact contains one authenticated corpus and its
identity records. Each request supplies one authenticated query embedding. The
reference adapter filters corpus visibility before scoring, performs an exact
flat scan, and publishes a deterministic bounded top-k result through the
shared stateless adapter, `ResourceBank`, and optional LaneWeave lifecycle.

This slice proves exact composition, not semantic search quality. It has no
network access, model download, approximate-nearest-neighbour structure, or
production vector database.

## Public contract

The retained profile declares:

- family `retrieval`;
- operation `retrieve`;
- input kind `embedding_i32`;
- output kind `retrieval_hits`;
- numerical policy `exact_integer`;
- one query per request;
- at most 64 corpus items;
- at most 4,096 embedding dimensions; and
- zero ambient capabilities.

The immutable artifact joins an index identifier and generation with:

- the canonical corpus batch-map root;
- an authenticated per-item visibility map;
- the canonical normalized-embedding policy root;
- the exact corpus embedding-matrix root; and
- the complete packed corpus embedding bytes.

The request joins one query batch map and one query embedding row with the exact
index, retrieval-policy, tenant, ownership, and publication challenge roots.
Raw document text, labels, credentials, and tenant secrets are not present in
the core retrieval evidence.

## Visibility and deterministic scoring

Each corpus ordinal has one visibility scope. Scope zero is public. A nonzero
scope is eligible only when it equals the request tenant. Filtering completes
before ranking, so an inaccessible high-scoring item cannot occupy a result
slot or influence the visible tie order.

For every eligible corpus row, the V1 score is the exact Q30 dot product:

```text
wide = sum(query[d] * corpus[item,d])
score = round_nearest_ties_to_even(wide / 2^30)
```

Products and accumulation use checked `i128`. The published score is a checked
signed `i64` Q30 value. Higher scores sort first; equal scores retain ascending
authenticated corpus ordinal. The policy and both embedding matrices are
identity-bound, so callers cannot silently change normalization, dimensions,
corpus order, tenant visibility, or tie meaning.

## Retrieval result

The output uses a retrieval-specific wire because the generic reranker result
represents a complete permutation, while retrieval may expose only a filtered
top-k subset.

The retained result has exactly one fixed 96-byte slot per corpus item:

1. the first `K` slots contain canonical hits;
2. each hit carries item ID, corpus ordinal, rank, exact score, and an
   identity-bound record root; and
3. every unused tail slot is zero.

A contextual result root binds the complete output to the index, query,
visibility, retrieval policy, corpus geometry, and requested `K`. Truncation,
extension, reordering, foreign roots, noncanonical ties, nonzero tail bytes,
and item-ID substitution fail closed.

The fixed-capacity representation intentionally spends bounded bytes to keep
the execution-plan geometry exact and mutation verification simple. It is not
a compact production index format.

## Execution and publication

The fixed corpus is artifact data; the query is request input. The family
wrapper reuses `stateless_model_adapter.Session`:

1. validate the adapter, artifact, plan, index, maps, policies, matrices, and
   request binding;
2. reserve or adopt the exact request claim;
3. filter and score into caller-owned provisional storage;
4. independently reconstruct and validate the complete candidate;
5. publish one typed result atomically, or scrub and abort it; and
6. cancel or retire until Scheduler and Bank ownership return to zero.

The scheduled path adopts its existing LaneWeave receipt instead of charging
the request twice. No result becomes visible before the final service quantum.
Invalid roots, aliasing, candidate drift, cancellation, and failed validation
leave no visible partial result or orphan ownership.

## Demo and focused verification

The shared dense-tensor executable exposes retrieval without adding another
compiled demo artifact:

```sh
zig build dense-tensor-retrieval-demo -Dmetal=false
```

Its retained fixture includes a foreign-tenant best match that is excluded and
two eligible equal-score matches ordered by corpus ordinal. The JSON record
contains the canonical maps, policies, packed index, query, fixed result,
contextual roots, and decoded visible hits. A standard-library Python oracle
reconstructs the same contract independently.

Run the focused family and registry roots together:

```sh
zig build dense-tensor-family-test \
  runtime-support-inspector-test -Dmetal=false
```

Reranking, embedding, classification, and retrieval still share one Zig test
artifact and one multi-mode production demo executable.

## Useful scope

This contract can support deterministic document-pipeline fixtures, offline
tenant-scoped search, adapter conformance tests, and future exact handoff into
a reranker. It establishes the identities that a persistent or accelerated
index must preserve without prescribing one storage engine or search
algorithm.

## Current nonclaims

This retained profile does not establish:

- approximate nearest-neighbour search, persistent indexing, distributed
  shards, or vector-database semantics;
- trained embedding quality, recall, relevance, calibration, or production
  model provenance;
- production tenant authentication or authorization outside the exact
  visibility-map contract;
- GPU execution, device residency, native multi-OS evidence, or performance;
- provider routing, network serving, or live model loading;
- reduced external-provider tokens, usage, latency, or cost;
- a stable C retrieval-execution ABI; the current C surface is discovery only;
  or
- persistence or fresh-process restart of an in-flight stateless request.

## Contributor follow-ups

Useful next slices include:

- bind the exact selected candidates to an optional reranker handoff without
  changing retrieval or reranker result semantics;
- add a durable index-generation selector and crash-safe corpus publication;
- retain production embedding and index adapters under explicit quality and
  resource campaigns;
- add device implementations that preserve or explicitly version the exact
  scoring policy;
- add native multi-OS and corruption campaigns; and
- compare exact flat search with separately identified approximate strategies
  under correctness-preserving workload evidence.
