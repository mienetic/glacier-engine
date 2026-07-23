# Exact Audio/Video Result Link

Status: **prototype**. Glacier can now publish a canonical link between one
newly visible transcript range and the visible tail of one verified video
timeline. The link preserves exact source/time bounds, modality-specific
lineage, one shared challenge, and transactional publication. It does not
claim semantic alignment or production-model quality.

## Why this is a separate contract

An overlapping audio window contains two different kinds of samples:

- conditioning context retained from an earlier window; and
- the new sample range allowed to produce visible transcript text.

The context is useful to a speech model, but it must not become evidence that
the corresponding text covers an earlier video interval. The linker therefore
maps only `TranscriptSegmentV1.publish_start_sample..publish_end_sample`. The
context range remains bound through the transcript and overlap-plan roots, but
is excluded from the linked audio span.

The video side uses the accumulated visible tail from
`VideoSegmentTimelineV1`, not only the newest raw segment. This preserves the
complete interval produced by deterministic timeline decisions.

## Exact time and relation policy

The transcript publication range starts in the canonical audio time base
`1 / sample_rate`. It must map into the video timeline target base using exact
integer rational arithmetic. A fractional target tick rejects with no rounded
or inferred relationship.

After mapping, the audio and video intervals must have positive overlap.
Touching but non-overlapping and disjoint intervals reject. An accepted link
records one of four recomputable relations:

| Relation | Condition |
| --- | --- |
| `exact` | Audio and video bounds are identical |
| `audio_within_video` | The complete audio interval is inside the video interval |
| `video_within_audio` | The complete video interval is inside the audio interval |
| `partial_overlap` | The intervals overlap, but neither contains the other |

The canonical overlap is always
`max(audio_start, video_start)..min(audio_end, video_end)`. The runtime does
not stretch either interval, invent missing coverage, or infer that temporal
overlap means semantic agreement.

## Canonical state and result

`AudioVideoLinkStateV1` has a fixed 320-byte wire. It binds:

- request epoch, next sequence, visible count, and last link index;
- audio and video media roots;
- the shared request challenge;
- previous-link and fixed-policy roots; and
- one root over the complete canonical state.

`AudioVideoResultLinkV1` has a fixed 576-byte wire. It binds:

- sequence/index and temporal relation;
- the video target time base;
- original transcript publication samples;
- mapped audio, accumulated video-tail, and positive-overlap ticks;
- transcript index plus current video decision and visible-segment counts;
- audio media, processor, cache, overlap-plan, and transcript roots;
- video media, timeline, and latest raw-segment roots;
- previous-link, challenge, policy, and complete link roots.

The state forms an immutable result-link chain. The transcript and video roots
retain the independently verifiable modality histories behind each link.

## Transactional publication

The session admits one exact `ResourceBank` claim:

- 576 private candidate bytes;
- 576 output-journal bytes; and
- one publication queue slot.

Prepare writes only caller-owned private candidate storage. Commit revalidates
the publication permit, unchanged state root, candidate bytes, complete input
lineage, exact time mapping, and expected canonical link before copying the
576-byte result to visible output and advancing state. Abort or drift scrubs
the candidate and leaves visible output and link state unchanged. Closing the
session releases the complete claim to zero.

## Independent evidence

Zig and Python independently implement the policy, encoders, decoders, roots,
and state transition. They retain matching state and first-link golden roots.
Tests flip every byte of both fixed wires and require rejection. Additional
cases cover all four relations, disjoint ranges, non-integral mapping,
conditioning-context exclusion, foreign challenges, abort, candidate drift,
retry, and exact resource release.

Run the retained proof:

```sh
zig test src/core/audio_video_result_link.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_video_result_link
```

## Current boundary and next milestone

The fixture uses exact synthetic timestamps and fixed text. It does not produce
word-level timestamps, align meanings across modalities, resolve
variable-frame-rate discontinuities, persist the link chain, restart a speech
or video model, run external codecs, or measure quality, latency, throughput,
memory, or energy.

The next streaming-perception milestone carries transcript-model or
video-model state through a fresh-process restart while preserving the exact
link predecessor. Richer timestamp, speaker, subtitle, event, and confidence
contracts can follow without changing the meaning of the current wire.

See [Overlap-Safe Audio Transcript Adapter](AUDIO_TRANSCRIPT_ADAPTER.md),
[Canonical Video-Segment Timeline](VIDEO_SEGMENT_TIMELINE.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
