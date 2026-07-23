# Typed Audio-Window Encoder Adapter

Status: **prototype**. Glacier now retains a deterministic audio-window
encoder fixture over live processor-cache ownership. It proves typed streaming
input and publication semantics; it is not speech recognition, audio quality,
or production-model evidence.

## Purpose

The vision fixture established the first model-family transaction. The audio
fixture tests whether the same runtime contract can represent a different
input element width and a time-based preprocessing lineage without adding
audio-only fields to the common model wire.

The adapter uses:

- `audio_understanding / encode`;
- signed 16-bit audio feature input;
- signed 16-bit weights;
- signed 32-bit embedding output;
- exact 64-bit integer accumulation;
- zero ambient capability; and
- the shared stateless prepare, candidate validation, publish/abort, and
  resource-release lifecycle.

## Retained fixture

Two non-overlapping feature windows each contain two signed 16-bit bins. A
two-by-two signed weight matrix produces this exact output:

```text
input windows       weights             output embeddings
[ 100, 200 ]        [ 1,  2 ]           [ 500,  500 ]
[-300, 400 ]        [-1,  3 ]           [ 500, 1500 ]
```

The projection is intentionally tiny and bit-exact. It exists to test runtime
semantics, not useful audio inference.

## Audio-specific binding

Before entering the shared stateless lifecycle,
`AudioWindowAdapter` verifies:

- the canonical processor bundle remains valid in memory after decode;
- the audio cache is live under the matching restore session and `LeaseTree`;
- request, generation, media, processor, cache, ownership, and challenge roots;
- batch count equals the processor's produced feature-window count;
- input width equals the declared feature-bin count;
- input element width equals the declared feature-byte width;
- retained window and hop sizes produce zero carried context for this first
  fixture; and
- weights, features, candidate, output, scratch, and queue admission are exact.

The source-mapping root binds the audio time base, cursor, produced windows,
sample rate, channels, window, hop, feature bins, context, feature width, and
model batch/input shape. Zig and Python retain the same mapping root.

## Shared stateless lifecycle

`StatelessModelAdapter` is the reusable family-neutral transaction used by this
slice:

1. match the manifest, plan, adapter descriptor, support record, dimensions,
   numerical policy, and capability mask;
2. reserve the exact `ResourceBank` claim and bind one publication session;
3. execute into private caller-owned candidate storage;
4. run the family candidate validator;
5. bind output, source mapping, adapter, resource receipt, and predecessor into
   a typed result envelope;
6. revalidate the Bank permit and candidate at commit;
7. publish and scrub, or abort and scrub without advancing state; and
8. close the model and cache sessions with exact zero logical ownership.

This shared layer does not validate modality semantics itself. Image, audio,
video, and future tensor adapters must construct their own binding proof before
calling it.

## Fail-closed cases

The retained tests reject:

- foreign feature-cache bytes;
- mutated processor state after strict decode;
- context-bearing windows not declared by this first adapter;
- unsupported schema, dimensions, or capabilities;
- output outside the declared absolute bound;
- candidate mutation between prepare and commit; and
- publication retry after an active result without closing the session.

Abort leaves output zero, preserves the publication predecessor and visible
count, and allows one clean retry.

## Claim boundary

This slice does not provide an external decoder, microphone access, spectral
quality, overlapping-window context support, recurrent state, transcript
publication, streaming restart through a model, accelerator execution,
physical memory measurement, or compatibility with downloaded weights.

## Run the retained proof

```sh
zig test src/core/audio_window_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_window_adapter
```

The next perception slice is a temporal video encoder over the existing
keyframe/window cache. The following audio slice should add overlap/context
ownership and a typed transcript transaction.

See [Typed Model-Family Contracts and Vision Adapter](MODEL_FAMILY_ADAPTER.md),
[Multimodal Processor and Cache State](MEDIA_PROCESSOR_STATE.md), and
[Materialized Multimodal Processor Caches](MEDIA_PROCESSOR_CACHE.md).
