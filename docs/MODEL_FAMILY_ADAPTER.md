# Typed Model-Family Contracts and Vision Adapter

Status: **prototype**. Glacier now has a capability-closed common model
contract and retained vision, audio, and temporal-video encoder fixtures. They
prove execution lifecycle and evidence semantics; they are not production
models or quality benchmarks.

## Why this layer exists

A full AI runtime cannot treat every model as “tokens in, tokens out.” Encoders,
speech models, diffusion systems, retrieval pipelines, and agent policies have
different input, state, result, and publication semantics. They can still share
resource admission, scheduling, cancellation, ownership, and evidence if those
differences remain typed.

The common contract therefore separates three questions:

1. Can the runtime describe this family and operation?
2. Does an installed adapter explicitly support the exact schema and numerical
   policy?
3. Did one admitted execution produce a verified candidate that may become
   visible?

A family ID answers only the first question. It never grants execution support.

## Canonical records

`src/core/model_contract.zig` defines three fixed, pointer-free records:

| Record | Bytes | Purpose |
| --- | ---: | --- |
| `ArtifactManifestV1` | 320 | Family, typed input/output, numerical policy, dimensions, weight representation, and artifact roots |
| `ExecutionPlanV1` | 768 | Exact request/generation, tensor sizes, resource claim, media/processor/cache/ownership roots, schemas, and capability requirement |
| `ResultEnvelopeV1` | 768 | Typed output identity, resource receipt, source mapping, publication predecessor, adapter identity, and commit root |

Each record uses little-endian integers, zeroed reserved bytes, a
domain-separated SHA-256 footer, strict decode, and complete byte-mutation
tests. Zig and the independent Python oracle retain the same artifact, plan,
and result golden roots.

The vocabulary covers model-family, operation, input, output, and numerical
policy IDs needed by the roadmap. Support remains a separate bounded
`SupportRecordV1`. Unknown IDs, mismatched schemas, excessive dimensions, and
undeclared capabilities reject explicitly.

## First executable adapter

`src/core/vision_encoder_adapter.zig` implements the first typed lifecycle:

```text
verified processor state + live image cache + artifact + request
                            │
                            ▼
               sealed vision execution plan
                            │
             exact ResourceBank admission
                            │
                            ▼
        exact-integer reference projection into private candidate
                            │
             bounds + source/cache/ownership revalidation
                            │
                    publish or scrub
```

The fixture consumes two four-feature image items and an eight-byte signed
weight matrix. It performs deterministic `u8 × i8 → i64 → i32` projection and
publishes a typed two-by-two embedding. This intentionally tiny computation
keeps the test legal, portable, and bit-exact while exercising the real
adapter boundary.

Before execution, the adapter verifies:

- the manifest, plan, support record, adapter descriptor, and zero-capability
  requirement;
- request and generation equality with the image processor state;
- media, processor-state, processor-bundle, cache-bundle, cache-payload,
  ownership, challenge, input-schema, and output-schema roots;
- exact input, output, scratch, weight, and queue-slot accounting; and
- that the image cache is currently live under the restored `LeaseTree`, not
  merely present as unowned bytes.

The backend receives no file, network, device, provider, or publication
authority. It writes only to a caller-owned provisional buffer.

## Publication and cancellation

`Session.prepareV1` begins one generation-fenced `ResourceBank` publication,
runs the backend, validates every fixed-point result against the declared
absolute bound, and constructs the result envelope. Visible output remains
zero.

`Session.commitV1` validates the Bank permit and candidate a second time,
rejects candidate drift, prepares the next publication state, copies the
candidate to the visible buffer, commits the sequence, and scrubs provisional
bytes. `abortV1` scrubs both buffers and leaves the visible-result count and
predecessor unchanged. Closing both model and cache sessions returns all
logical ownership to zero.

## What this proves

The retained tests prove:

- canonical cross-language artifact, execution-plan, and result identities;
- explicit unsupported-operation and unsupported-capability results;
- cache bytes cannot substitute for a foreign processor/cache lineage;
- candidate mutation between prepare and commit cannot become visible;
- cancellation does not advance publication state;
- output bytes are bound to source mapping, adapter, resource receipt, and
  predecessor; and
- model and cache ownership return to exact zero.

It does not prove model usefulness, external image decoding, floating-point
equivalence, accelerator execution, physical memory residency, production
throughput, or compatibility with downloaded weights.

## Run the retained proof

```sh
zig test src/core/model_contract.zig -OReleaseSafe
zig test src/core/vision_encoder_adapter.zig -OReleaseSafe
zig test src/core/audio_window_adapter.zig -OReleaseSafe
zig test src/core/temporal_video_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_model_contract
```

## Additional adapters

The common records are intentionally reusable. A typed audio-window encoder now
uses different input width and streaming source semantics through the shared
stateless lifecycle without changing the common wire. See
[Typed Audio-Window Encoder Adapter](AUDIO_WINDOW_ADAPTER.md).

A typed temporal-video encoder now adds strided frame gathering, exact target
timeline mapping, and keyframe/eviction lineage through that same common wire.
See [Typed Temporal-Video Encoder Adapter](TEMPORAL_VIDEO_ADAPTER.md).

An overlap-safe audio transcript adapter now separates conditioning context
from newly publishable samples and emits a predecessor-bound typed transcript.
See [Overlap-Safe Audio Transcript Adapter](AUDIO_TRANSCRIPT_ADAPTER.md).

Vision, audio, transcripts, and temporal video use the extracted shared
stateless lifecycle.
The stateful lifecycle and exact latent-step fixture now publish replacement
state with each result, checkpoint the intermediate publication, restore it
under fresh ownership in another process, and commit the terminal step exactly
once. See
[Stateful Model Adapter and Latent-Step Fixture](STATEFUL_MODEL_ADAPTER.md) and
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md).

The next stateless family work is a generic non-media encoder with typed score
or ranked-item output.

See [Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Materialized Multimodal Processor Caches](MEDIA_PROCESSOR_CACHE.md).
