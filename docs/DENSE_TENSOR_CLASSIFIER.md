# Dense-Tensor Classifier

Status: **integrated experimental retained reference fixture**.

Glacier has a download-free stateless classification path for bounded dense
tensors. It multiplies a row-major `B × F` little-endian `i16` input matrix by a
row-major `C × F` `i8` projection matrix, accumulates every dot product in a
checked `i64`, and publishes the resulting `B × C` class-score matrix through
the shared stateless adapter, `ResourceBank`, and optional LaneWeave lifecycle.

This slice proves exact arithmetic, stable batch and class identity,
deterministic winner selection, candidate validation, atomic publication,
scheduled cancellation, and exact ownership release. It is a generic
classification contract, not a production classifier or quality claim.

## Public contract

The retained profile declares:

- family `stateless_encoder`;
- operation `classify`;
- input kind `dense_tensor`;
- output kind `class_scores`;
- numerical policy `exact_integer`;
- `B <= 64` batch items;
- `F <= 4,096` input features;
- `C <= 256` classes; and
- zero ambient capabilities.

For item `b` and class `c`, the exact score is:

```text
score[b,c] = sum(input[b,f] * weight[c,f])
```

The implementation validates the exact shape and maximum absolute score before
execution. Input elements are signed `i16`, weights are signed `i8`, and the
accumulator and published score are signed `i64`. There is no floating-point
conversion or normalization.

## Canonical maps, policy, and score matrix

`stateless_tensor_result.zig` keeps classification records separate from the
frozen reranker policy:

1. The existing authenticated batch map assigns each nonzero, unique item ID
   to its stable zero-based input ordinal.
2. A separate authenticated class map assigns each nonzero, unique class ID to
   its stable zero-based class ordinal.
3. The fixed class-score policy declares signed little-endian `i64` encoding,
   no normalization, descending score order, and ascending class ordinal as
   the only V1 winner tie break.
4. The output is exactly `B × C × 8` bytes: a compact row-major signed-`i64`
   matrix without an in-band header.

The contextual matrix root binds the exact batch-map root, class-map root,
policy root, item count, class count, and every score byte. A matrix is not
meaningful without those authenticated inputs.

Winner selection scans one row in class-ordinal order. A strictly larger score
replaces the current winner; equal scores preserve the earlier authenticated
class ordinal. The retained fixture contains intentional score ties and checks
the same winner IDs, ordinals, scores, and matrix root across repeated runs.
Class IDs are opaque caller-facing identities, not human-readable labels.

## Non-media input binding

`ModelExecutionPlanV1` predates generic dense tensors. The classifier therefore
uses an explicit compatibility projection instead of treating tensor roots as
media:

| Plan V1 field | Dense-classifier meaning |
| --- | --- |
| `media_object_sha256` | caller-declared input-object root |
| `processor_state_sha256` | canonical batch-map root |
| `processor_bundle_sha256` | canonical class-score-policy root |
| `cache_bundle_sha256` | derived input-bundle root |
| `cache_payload_sha256` | exact dense-tensor payload root |
| `output_schema_sha256` | canonical class-map root |
| `ownership_sha256` | exact request ownership root |
| `challenge_sha256` | exact publication challenge |

The input-bundle root joins the input object, batch map, class map, score
policy, tensor, ownership, and challenge. A separate source-mapping root also
binds request epoch, generation, publication sequence, and `B/F/C` geometry.
Zero, substituted, or coherently resealed foreign roots fail closed.

## Execution and publication

The family wrapper reuses `stateless_model_adapter.Session`:

1. validate the artifact, plan, support row, tensor binding, batch map, class
   map, and class-score policy;
2. reserve or adopt the exact plan claim;
3. compute into caller-owned provisional storage;
4. independently recompute every `i64` score and validate the complete matrix
   before visibility;
5. publish one typed `ResultEnvelopeV1` atomically, or scrub and abort the
   provisional result; and
6. cancel or retire until Scheduler and Bank ownership return to zero.

The scheduled path adopts the LaneWeave admission receipt rather than charging
the claim twice. It publishes only at final service. Cancellation, candidate
drift, aliasing, invalid bounds, and substituted class evidence leave no
visible result or orphan ownership.

## Registry and language discovery

The classifier is append-only runtime-support profile index 10 with slug
`dense-tensor-classifier-reference`, profile ABI
`0x4744434c00000001`, and mask bit `1 << 10`. The registry now contains 12
profiles; retrieval is index 11, indices 0 through 9 retain their original
meanings, and the classifier remains fixed at index 10.

The C, standard-library Python, and dependency-free Rust consumers agree on the
count, ABI, fixed profile fields, exact mask, successful maximum-bound query,
and explicit dimension and capability rejection. The C++ consumer locks the
header layout, linkage, count, ABI, index, and mask constants at compile time.
This is compatibility discovery only. The C boundary does not expose
classifier execution or compiler-specific Zig layouts.

## Demo and focused verification

The existing dense-tensor reranker demo executable also exposes the classifier
record. Pass `classify` after the build separator:

```sh
zig build dense-tensor-reranker-demo -Dmetal=false -- classify
```

The JSON record contains the exact weights and tensor, canonical batch and
class maps, class-score policy, compact score matrix, semantic matrix root,
publication roots, decoded score rows, and deterministic winner for each item.
It performs no network access or model download.

Run the existing focused roots together so Zig reuses one dependency graph:

```sh
zig build dense-tensor-reranker-test \
  runtime-support-inspector-test -Dmetal=false
```

No classifier-specific build root was added. The first existing root reaches
the shared tensor-result and classifier lifecycle coverage; the second checks
the appended registry record and queries. Existing contract interop gates
cover the C, C++, Python, and Rust discovery surfaces.

## Useful scope

The contract can support deterministic tests for local classification
adapters, rule-bound score publication, offline fixtures, and future
production backends that can reproduce or explicitly version the same
batch/class/output identities. It is AI-runtime infrastructure because it
binds model-shaped execution to admission, scheduling, publication, and
evidence; the retained arithmetic alone does not supply model semantics.

Only this generic classification slice is established here. Fixed-corpus
retrieval now has a separate contract; production adapters, retained
model-quality evidence, and stable execution bindings remain separate work.

## Current nonclaims

This retained profile does not establish:

- probabilities, softmax, calibration, confidence thresholds, or label
  semantics;
- semantic classification accuracy, trained-weight provenance, or production
  model quality;
- GPU execution, device residency, or a production accelerator backend;
- native multi-OS execution or support evidence;
- throughput, latency, memory, energy, thermal, or performance results;
- reduced external-provider tokens, usage, latency, or cost;
- provider routing, network serving, or live model loading;
- a stable C classifier-execution ABI; the current C surface is discovery
  only; or
- persistence or fresh-process restart of an in-flight stateless request.

## Contributor follow-ups

Useful independent next slices include:

- bind exact retrieval candidates to the existing reranker without changing
  either result contract;
- add a production classifier adapter while preserving explicit batch, class,
  policy, and publication identity;
- define versioned label metadata without reinterpreting opaque class IDs;
- add bounded numerical policies with declared tolerances and independent
  oracles;
- add device adapters that preserve or explicitly version result semantics;
  and
- retain native multi-OS, quality, resource, and performance evidence under
  separately declared campaigns.
