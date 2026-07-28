# Normalized Dense-Tensor Embedding

Status: **integrated retained reference fixture**.

Glacier has a model-free stateless encoder path for deterministic normalized
embeddings. It multiplies a bounded row-major `i16` input tensor by row-major
`i8` projection weights with checked `i64` accumulation, normalizes every
nonzero output row to Q30 L2 coordinates, and publishes the compact `i32`
matrix through the shared stateless adapter, `ResourceBank`, and optional
LaneWeave lifecycle.

This slice proves portable arithmetic, tensor identity, normalization policy,
candidate validation, atomic publication, cancellation, and exact ownership
release. It does not claim that the retained weights have semantic quality.

## Public contract

The retained profile declares:

- family `stateless_encoder`;
- operation `encode`;
- input kind `dense_tensor`;
- output kind `embedding_i32`;
- numerical policy `exact_integer`;
- at most 64 batch items, 4,096 input features, and 256 output dimensions;
- `i16` input elements, `i8` weights, and `i32` output components; and
- zero ambient capabilities.

The profile is append-only registry index 9 with slug
`dense-tensor-embedding-reference`. Existing registry indices retain their
original meanings.

## Exact Q30 L2 normalization

Each raw component is:

```text
raw[b,d] = sum(input[b,f] * weight[d,f])
```

The fixed scale is `Q = 2^30`. For each nonzero raw row, the canonical
component is the nearest integer to:

```text
raw[b,d] * Q / sqrt(sum(raw[b,*]^2))
```

The implementation does not evaluate a floating-point square root. It uses
`u256` squared-threshold comparisons to binary-search the floor component, then
compares the exact half-step midpoint. An exact midpoint rounds to the even
integer. The sign is restored only after the magnitude is fixed.

This construction avoids platform floating-point mode, library, and
instruction differences. Axis-aligned vectors map exactly to `±Q`; every
component magnitude is at most `Q`; a zero raw row is rejected rather than
assigned an arbitrary direction. Overflow, invalid shape, overlap, or zero-row
failure leaves caller output unchanged.

## Canonical policy and matrix

`stateless_embedding_result.zig` defines:

1. A fixed 112-byte `EmbeddingPolicyV1` wire. It binds Q30 L2 normalization,
   signed little-endian `i32` components, the squared-threshold algorithm,
   nearest-ties-to-even rounding, zero-vector rejection, and the exact Q30
   scale under a domain-separated SHA-256 footer.
2. A compact row-major matrix containing exactly
   `batch_items × output_dimensions × 4` bytes. It carries no in-band header,
   so `ModelExecutionPlanV1.output_bytes` keeps its existing element-count
   meaning.
3. A separate matrix root over the canonical batch-map root, policy root,
   batch count, output dimensions, and raw matrix bytes.

The compact bytes are meaningful only with their authenticated batch map,
policy, dimensions, and result envelope. The decoder requires the exact byte
length, bounded components, and a nonzero row; the family wrapper additionally
recomputes the full projection and normalization before publication.

## Non-media input binding

The V1 execution plan predates generic dense tensors. The embedding adapter
therefore declares the same explicit compatibility projection used by the
generic reranker, with a distinct embedding policy:

| Plan V1 field | Dense-embedding meaning |
| --- | --- |
| `media_object_sha256` | caller-declared input-object root |
| `processor_state_sha256` | canonical batch-map root |
| `processor_bundle_sha256` | canonical embedding-policy root |
| `cache_bundle_sha256` | caller-declared input-bundle root |
| `cache_payload_sha256` | exact dense-tensor payload root |
| `ownership_sha256` | exact request ownership root |
| `challenge_sha256` | exact publication challenge |

The adapter binds these roots, epoch, generation, publication sequence, and
`B/F/D` geometry into a separate source-mapping digest. It does not reinterpret
the frozen reranker score policy.

## Execution and verification

The wrapper:

1. validates the artifact, plan, support record, tensor binding, batch map, and
   embedding policy;
2. reserves or adopts the exact plan claim;
3. computes into provisional caller-owned storage;
4. independently recomputes and compares the candidate before visibility;
5. publishes one typed result atomically or scrubs and aborts; and
6. cancels or retires until Scheduler and Bank ownership return to zero.

The demo emits one strict JSON record. A standard-library Python oracle
independently decodes the policy and batch map, recomputes the dot products and
exact squared-threshold normalization with arbitrary-precision integers, and
checks the compact output, output SHA-256, matrix root, and mapped rows. It
requires lifecycle source/result roots to be nonzero canonical digests but
does not reconstruct those roots without the complete plan and result wires.

Run the focused compile-once gate:

```sh
zig build dense-tensor-embedding-test -Dmetal=false
```

The focused step compiles one Zig test artifact and one demo executable. The
same demo artifact is passed to the Python oracle, avoiding a second demo
compile.

## Uses and next composition

Production weights can reuse this result contract for local semantic-search
features, document or media clustering, similarity-based deduplication, and
retrieval inputs. A later retrieval slice can use the stable batch, policy, and
matrix identities to select a small context set before calling an external AI
provider. That composition can reduce provider input tokens; this fixture by
itself neither selects context nor measures token savings.

Natural follow-ups are:

- a versioned in-memory corpus and exact top-k similarity policy;
- canonical query-to-corpus evidence followed by the existing reranker;
- typed class scores and immutable label maps;
- bounded float or quantized production policies with independent tolerances;
- device adapters that preserve the same normalized bytes; and
- retained quality, performance, energy, and native multi-OS evidence.

## Current nonclaims

This retained profile does not establish:

- semantic similarity, embedding quality, or production model correctness;
- tokenizer, pooling, corpus, index, nearest-neighbor, or retrieval behavior;
- a reduction in external-provider tokens or cost;
- GPU execution, physical residency, provider routing, or network serving;
- a stable C model-execution ABI; the current C boundary exposes discovery;
- persistence of an in-flight stateless encode request; or
- throughput, latency, memory, energy, thermal, or native multi-OS results.
