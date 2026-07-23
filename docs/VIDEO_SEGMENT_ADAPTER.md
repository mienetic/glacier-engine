# Typed Video-Segment Adapter

Status: **integrated fixture**. Glacier can publish a bounded
video-understanding result from a canonical strided selection over a live
processor cache. The
fixture proves source/time lineage, exact resource admission, transactional
visibility, and cross-language wire agreement. It does not establish video
quality or production-model support.

## Purpose

A video embedding says little about which interval it describes. Event search,
chaptering, monitoring, indexing, and retrieval need a result that carries its
own source boundary and can be validated after it leaves the execution
process.

`VideoSegmentV1` is a fixed 512-byte typed result for that boundary. It records:

- request, generation, and ordered segment index;
- first/last frame, selected-frame count, and stride;
- keyframe ordinal, eviction boundary, and cache generation;
- exact target time base and start/end ticks;
- model-selected event ID and confidence in integer parts per million;
- media, processor-state, processor-bundle, cache-bundle, cache-payload,
  ownership, selection, challenge, and previous-segment roots; and
- a root over the complete canonical body.

The predecessor root makes each visible segment part of an explicit ordered
chain. A separately valid result from another media/cache lineage cannot be
substituted into the current publication.

## Source selection and materialization

The adapter reuses `TemporalSelectionV1`; it does not define a second frame
selection vocabulary. The retained fixture selects frames 10 and 12 from the
live cache window `[10, 14)`. Four selected bytes are gathered into
caller-owned scratch:

```text
cache frame       features      selected
10                [1, 2]        yes
11                [3, 4]        no
12                [5, 6]        yes
13                [7, 8]        no
```

The generalized gather primitive validates the complete cache root, checked
offsets, selected byte length, keyframe/eviction state, and exact rational time
mapping. The scratch is charged as activation/staging memory and scrubbed
before `prepareV1` returns.

## Transactional publication

The model-family vocabulary now includes:

- family `video_understanding`;
- operation `segment`;
- input `video_feature_u8`;
- output `video_segment`; and
- exact-integer numerical policy.

Before execution, the adapter joins the request, selection, processor/cache
lineage, challenge, segment index, and predecessor into one source root. The
execution plan must carry that exact root as its input schema and the
512-byte segment schema root as its output schema.

Execution writes only to a private candidate. Candidate validation decodes the
canonical wire and rechecks every source/time field against the plan and
selection. Commit revalidates the candidate, copies it to visible storage,
advances one result sequence, and scrubs provisional bytes. Abort, stale cache
state, foreign predecessors, or candidate drift publish nothing. Closing model
and cache sessions returns logical ownership to zero.

## Independent evidence

Zig and Python independently encode, decode, validate, and hash the segment.
Both retain the same source and segment golden roots. Mutation-complete tests
flip every byte of the 512-byte wire and require rejection.

The transactional Zig fixture also proves:

- only selected frames reach the model adapter;
- selected scratch is scrubbed after preparation;
- output remains invisible until commit;
- stale selection and foreign cache bytes reject;
- abort and candidate drift preserve publication state; and
- every admitted resource is released.

## Current boundary

The reference backend maps four synthetic bytes to one deterministic event ID
and confidence. A separate stateful fixture now binds explicit per-frame
PTS/duration and restores the segment model across a real process boundary. It
does not decode external containers, infer useful events, normalize edit lists
or B-frame timestamps, infer subtitle semantics, run on an accelerator, or
measure physical memory.

Useful next slices are:

1. ~~canonical overlap/merge policy for adjacent segment candidates~~ —
   complete through fixed timeline and receipt wires;
2. ~~transcript/audio linkage under one synchronized source range~~ —
   complete through an exact publish-only result-link transaction;
3. ~~stateful video-model continuation across a process boundary;~~ complete
   through explicit VFR windows, retained model state, timeline continuation,
   and cross-modal link continuation; and
4. production backend conformance against the same candidate validator.

## Run the retained proof

```sh
zig test src/core/video_segment_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_video_segment_adapter
```

See [Typed Temporal-Video Encoder Adapter](TEMPORAL_VIDEO_ADAPTER.md),
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md),
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md),
[Canonical Video-Segment Timeline](VIDEO_SEGMENT_TIMELINE.md),
[Typed Model-Family Contracts and Vision Adapter](MODEL_FAMILY_ADAPTER.md),
[Materialized Multimodal Processor Caches](MEDIA_PROCESSOR_CACHE.md), and
[AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
