# Stateful VFR Video-Model Continuation

Status: **integrated fixture**. Glacier now carries a bounded
video-understanding model state across a real process boundary, preserves
explicit variable-frame-rate timestamps and a declared discontinuity, publishes
the exact successor segment, advances the canonical video timeline and
audio/video result-link chain, and releases all target ownership.

This is a deterministic exact-integer fixture, not a production video model.

## Explicit VFR source contract

`StatefulVideoAdapter.FrameWindowV1` is a fixed 576-byte wire. It records up to
four frames without inferring a constant frame rate:

- frame ordinal, presentation tick, duration, and keyframe flag for every
  active frame;
- exact target time base;
- previous end tick, current start/end ticks, and the declared discontinuity
  before the window;
- duration-transition and keyframe counts;
- media, processor-bundle, cache-bundle, ownership, frame-payload, timestamp
  payload, predecessor-window, and challenge roots; and
- a root over the complete canonical body.

The timestamp-payload digest is derived from the active ordinal/PTS/duration/
keyframe tuples. The frame-payload digest must equal the exact feature bytes
given to the model. Padding is zero and canonical. A changed timestamp,
duration, frame feature, hidden ordinal, or undeclared gap therefore rejects.

The retained source contains:

| Segment | Frame ordinals | PTS ticks | Durations | Span |
| --- | --- | --- | --- | --- |
| Source | `0, 1` | `0, 8` | `8, 12` | `[0, 20)` |
| Fresh target | `2, 3` | `25, 35` | `10, 15` | `[25, 50)` |

The second window names the first window root and declares the five-tick gap
between tick 20 and tick 25. Both windows contain a duration transition, so the
proof exercises VFR rather than a constant-duration approximation.

## Stateful model execution

The adapter uses the shared `StatefulModelAdapter` lifecycle with the typed
family/operation pair `video_understanding / segment`. Its fixed 48-byte state
records:

- latest segment index;
- exact next frame ordinal;
- latest end tick;
- target time base; and
- number of visible segments emitted by the model.

The source process publishes a canonical 512-byte `VideoSegmentV1` and successor
state atomically. The target must resume at frame ordinal 2 with previous end
tick 20. It publishes segment 2 over `[25, 50)`, with segment 1 as its exact
predecessor. Candidate output and successor state remain private until commit.

## Composed continuation checkpoint

`VideoModelContinuation.CheckpointV1` is a fixed 768-byte record. It cross-binds:

- the generic stateful-model checkpoint, state publication, and retained state;
- previous and next VFR frame-window roots;
- the exact previous model result and its canonical segment wire;
- current video timeline and tail segment;
- previous and next audio overlap/transcript transactions;
- current result-link state and exact previous result link;
- fresh restore epoch, next model/timeline/link sequences;
- next frame/time/discontinuity values; and
- shared audio/video media identities and challenge.

Validation occurs before target resource admission. It reconstructs the prior
cross-modal link from its exact audio transcript and video timeline, checks that
the generic model output digest equals the previous segment wire, and verifies
the complete VFR predecessor. A valid but separately rehashed gap or substituted
lineage still rejects without changing the target Bank.

## Fresh-process result

The native demonstration uses distinct source and target PIDs:

1. The source publishes video segment 1, initializes the visible timeline, and
   publishes cross-modal link 1.
2. It writes and syncs the composed checkpoint plus every referenced canonical
   wire and retained 48-byte state, then releases source ownership.
3. A fresh Bank reserves the retained state as unmaterialized.
4. Only the exact durable bytes can make that allocation live.
5. The target model publishes segment 2, retaining the declared five-tick gap.
6. The timeline commits `retain_distinct`, increasing visible segments to two.
7. The next transcript range links to the new video tail and advances the link
   chain to two.
8. Model, timeline, link, and restored-state ownership all release; Bank usage,
   live allocations, and active LeaseTrees return to zero.

Files and the containing directory are synced. The fixture does not yet publish
this complete file set through one crash-atomic selector; the existing immutable
checkpoint archive is the intended durable composition layer.

## Independent evidence

Zig and Python independently implement and hash the VFR window, retained model
state, model transition, 768-byte composed checkpoint, segment/timeline
transition, and cross-modal lineage checks. Matching golden roots cover both
frame windows, the generic checkpoint, and the composed checkpoint. Tests flip
every byte of the fixed VFR and checkpoint wires and require rejection.

Run the retained evidence:

```sh
zig test src/core/stateful_video_adapter.zig -OReleaseSafe
zig test src/core/video_model_continuation.zig -OReleaseSafe
python3 -m unittest bench.tests.test_video_model_continuation
zig build video-model-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

## Current boundary and next milestones

The fixture has filesystem authority only for its bounded checkpoint files. It
has no camera, demuxer, codec, network, provider, accelerator, display, or
device authority. It does not infer useful events, process B-frames, normalize
container edit lists, measure video quality, prove physical memory, or run
production weights.

With stateful audio/video continuation, exact word/speaker annotation, bounded
generated-image publication, acknowledgement-gated generated PCM, and ordered
generated-video manifest publication integrated, the next multimodal runtime
slices are external media format adapters, richer language/punctuation and
overlapping-speaker policy, production generative-media adapters, shared
manifest/checkpoint composition, and multi-segment continuity. Physical
playback and display evidence remain separate promotion tracks.

See [Typed Video-Segment Adapter](VIDEO_SEGMENT_ADAPTER.md),
[Canonical Video-Segment Timeline](VIDEO_SEGMENT_TIMELINE.md),
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md),
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md),
[Exact Speech Annotation Publication](SPEECH_ANNOTATION_PUBLICATION.md),
[Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
