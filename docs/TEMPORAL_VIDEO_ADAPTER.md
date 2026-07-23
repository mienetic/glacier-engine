# Typed Temporal-Video Encoder Adapter

Status: **prototype**. Glacier retains a deterministic temporal-video encoder
fixture over a live processor-cache window. It proves selected-frame,
keyframe, eviction, timeline, resource, and publication semantics; it is not
video-quality or production-model evidence.

## Purpose

Image and audio fixtures consume contiguous model inputs. Video selection adds
a different problem: the owned cache can contain a full temporal window while
one model request consumes a bounded, strided subset. The adapter must prove
which frame ordinals were gathered without copying modality-specific fields
into the common model wire.

The retained adapter uses:

- `video_understanding / encode`;
- unsigned 8-bit per-frame features and signed 8-bit weights;
- signed 32-bit embedding output with exact 64-bit accumulation;
- a caller-declared first frame, count, and stride;
- exact rational mapping into a target timeline;
- charged caller-owned gather scratch; and
- the shared stateless prepare, validate, publish/abort, and release lifecycle.

## Temporal selection contract

`TemporalSelectionV1` binds:

- first, last, count, and stride of selected source frames;
- the keyframe ordinal required by the selected tail;
- the current eviction boundary and cache generation;
- target time base and exact target start/end ticks; and
- the canonical video processor-state root.

The adapter accepts only selections fully inside the current cache window. The
retained form also requires the selected range to begin at or after the tracked
keyframe. Target positions are recomputed with checked rational arithmetic;
non-integral or overflowing mappings reject.

## Charged strided gather

The live cache contains four two-byte frame entries. The fixture selects source
frames 10 and 12 from window `[10, 14)`:

```text
cache frame       features      selected
10                [1, 2]        yes
11                [3, 4]        no
12                [5, 6]        yes
13                [7, 8]        no
```

The gathered bytes occupy caller-owned scratch whose exact length is charged as
`staging_bytes`. Gathering uses checked offsets and the scratch is scrubbed on
success or failure before `prepareV1` returns. The model backend never receives
the full temporal cache.

With weights `[1, 2]` and `[-1, 3]`, exact projection produces embeddings
`[5, 5]` and `[17, 13]`.

## Binding and publication

Before entering `StatelessModelAdapter`, the video adapter verifies:

- canonical processor and cache bundles remain valid in memory;
- the complete video cache is live under the matching restore session;
- request, generation, media, processor, cache, ownership, and challenge roots;
- frame count, bytes per entry, selected input size, and output shape;
- keyframe lineage, eviction boundary, cache generation, and target span;
- exact weight, activation, staging, candidate, output, and queue claims; and
- zero undeclared capability.

The source-mapping root joins the selection root to the full cache root, video
time base, window state, model batch, and input shape. Zig and Python retain
the same selection and source-mapping golden roots.

Execution writes only to a private candidate. Commit revalidates its contents
and publication permit, copies the verified result to visible output, advances
one typed result sequence, and scrubs the candidate. Abort or candidate drift
publishes nothing and scrubs provisional bytes. Closing model and cache
sessions returns logical ownership to zero.

## Fail-closed cases

Retained tests reject:

- selection outside the owned temporal window;
- stale or mutated keyframe, eviction, cache-generation, or timeline fields;
- non-integral target timeline mapping;
- foreign or mutated cache bytes;
- uncharged or incorrectly sized gather scratch;
- unsupported schema, dimensions, or capabilities;
- output beyond the declared absolute bound; and
- candidate mutation between prepare and commit.

## Claim boundary

This stateless slice does not decode external video, seek through a container,
infer missing frames, link subtitles, run on an accelerator, measure physical
memory, or establish useful video embeddings. Separate composed fixtures now
bind exact audio results and carry explicit VFR timing plus retained
video-model state across a process restart.

## Run the retained proof

```sh
zig test src/core/temporal_video_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_temporal_video_adapter
```

The selection and charged gather are now also reused by the
[Typed Video-Segment Adapter](VIDEO_SEGMENT_ADAPTER.md), which publishes one
fixed source/time-bound event result. The
[Canonical Video-Segment Timeline](VIDEO_SEGMENT_TIMELINE.md) now resolves
adjacent overlap deterministically, and
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md) binds newly
publishable transcript time to that accumulated tail. Remaining video slices
include external container normalization, richer subtitle semantics, and
generated-segment publication. Stateful VFR continuation is integrated through
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md).

See [Typed Model-Family Contracts and Vision Adapter](MODEL_FAMILY_ADAPTER.md),
[Typed Audio-Window Encoder Adapter](AUDIO_WINDOW_ADAPTER.md), and
[Materialized Multimodal Processor Caches](MEDIA_PROCESSOR_CACHE.md).
