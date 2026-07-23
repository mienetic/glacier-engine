# Stateful Audio Transcript Continuation

Status: **integrated fixture**. Glacier now carries a bounded transcript-model
state across a real process boundary, charges restored ownership before
materialization, publishes the exact next transcript range, and advances its
audio/video result-link chain without duplicated text.

This is a deterministic exact-integer fixture, not a production speech model.

## Runtime path

The retained proof executes two transcript segments:

| Process | Context samples | Newly publishable samples | Visible text |
| --- | ---: | ---: | --- |
| Source | `0..2` | `2..10` | `ice` |
| Fresh target | `8..10` | `10..18` | `berg` |

The second process reuses samples `8..10` as conditioning context, but visible
publication begins exactly at sample 10. The transcript predecessor requires
the first segment root, so the resumed path cannot skip, duplicate, or
substitute the prior text.

`StatefulTranscriptAdapter` runs through the shared `StatefulModelAdapter`
lifecycle with the typed family/operation pair
`audio_understanding / transcribe`. Its fixed 32-byte reference state records:

- the latest segment index;
- the exact next publishable sample;
- sample rate; and
- cumulative visible text bytes.

The first process commits output plus successor state atomically. Abort and
candidate drift scrub only private candidates; previously visible output and
state buffers remain byte-for-byte unchanged.

## Composed checkpoint

`AudioTranscriptContinuation.CheckpointV1` is a fixed 576-byte record. It
cross-binds:

- the generic stateful-model checkpoint and state-publication roots;
- source and restore Bank epochs plus the retained-state digest;
- completed/next generations and model publication sequence;
- the previous overlap plan, transcript segment, model-output digest, and
  canonical result-link wire;
- the exact next overlap plan and sample boundaries;
- audio and video media identities;
- the current video timeline;
- the audio/video link-state root, next sequence, visible count, and previous
  link; and
- one shared challenge plus a root over the complete checkpoint.

Validation occurs before target resource admission. A foreign next overlap,
challenge, media object, transcript predecessor, prior model output, previous
result link, video timeline, link state, state publication, or generic
checkpoint therefore rejects without changing the target Bank. Even a
separately rehashed output or link is rejected when its semantic lineage does
not match the transcript and timeline.

## Fresh-process restore

The native demonstration uses distinct source and target PIDs:

1. The source publishes the first transcript and cross-modal link.
2. It writes and syncs the stateful checkpoint, composed checkpoint, state
   payload, both overlap plans, previous transcript, previous result link,
   video timeline, and link state.
3. Source model ownership returns to exact zero.
4. A target Bank with the declared fresh epoch reserves one unmaterialized
   retained-state allocation.
5. Only after the durable 32-byte state hashes exactly does the allocation
   become live.
6. The target publishes `berg`, advances model/state publication to step 2,
   derives transcript segment 2, and commits cross-modal link 2.
7. The restored predecessor allocation and both target transactions release;
   Bank usage, live allocations, and active LeaseTrees return to zero.

The files are individually synced and the directory is synced. This fixture
does not yet publish the complete file set through one crash-atomic selector;
the existing immutable checkpoint archive is the intended durable composition
layer.

## Independent evidence

Zig and Python independently implement the 32-byte transcript state, exact
reference transition, 576-byte checkpoint encoder/decoder, composition checks,
and roots. Both retain matching generic and transcript-continuation golden
roots. Tests flip every checkpoint byte and require rejection.

Run the retained evidence:

```sh
zig test src/core/stateful_transcript_adapter.zig -OReleaseSafe
zig test src/core/audio_transcript_continuation.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_transcript_continuation
zig build audio-transcript-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

## Current boundary and next milestone

The fixture has filesystem authority only for its bounded checkpoint files. It
has no microphone, codec, network, provider, accelerator, playback, or device
authority. It does not identify a language, emit word timestamps or speakers,
measure recognition quality, prove physical memory, or run production weights.
The transcript-model fixture itself stops at the segment boundary. Exact word
sample ranges and first-occurrence speaker identities now publish in a separate
bounded annotation transaction whose state continues across a real process
restart. The transcript-model and annotation-state file sets are not yet
composed into one crash-atomic checkpoint.

The same composition now also carries stateful video-model temporal position,
explicit variable-frame-rate discontinuity evidence, timeline predecessor, and
exact audio/video link continuation through
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md).
Language/punctuation, overlapping-speaker ambiguity, production confidence,
and crash-atomic composition remain separate tracks. A bounded generated-audio
transaction now implements application acknowledgement and successor
backpressure independently; production renderers, physical playback, and
composition with this transcript checkpoint remain gated.

See [Overlap-Safe Audio Transcript Adapter](AUDIO_TRANSCRIPT_ADAPTER.md),
[Exact Speech Annotation Publication](SPEECH_ANNOTATION_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md),
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
