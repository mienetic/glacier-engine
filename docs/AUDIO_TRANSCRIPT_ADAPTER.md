# Overlap-Safe Audio Transcript Adapter

Status: **prototype**. Glacier now publishes one typed transcript segment from
a context-bearing audio processor cache while proving that repeated context
samples are not part of the newly visible text range.

This is publication and ownership evidence for streaming speech systems. The
fixed ASCII output is not recognition-quality, language, tokenizer, or
production-model evidence.

## Why overlap needs an explicit contract

Streaming audio models retain samples from the end of an earlier window so the
next window has enough context. If those repeated samples have no explicit
ownership and range semantics, a runtime can lose samples, charge them twice,
or publish the same words twice.

`AudioOverlapPlanV1` is a fixed 512-byte record that binds:

- request, generation, and transcript segment index;
- complete source, context-only, and newly publishable sample intervals;
- sample rate, window, hop, feature-frame, feature-bin, and element sizes;
- media, processor state/bundle, cache bundle/payload, and ownership roots;
- challenge and previous-transcript roots; and
- one domain-separated overlap root.

For the retained fixture, two four-sample windows use a two-sample hop:

```text
source samples:      [4────────────────────10)
context only:        [4────6)
publishable samples:       [6──────────────10)
window 0:            [4──────────8)
window 1:                  [6──────────10)
```

The context interval ends exactly where the publishable interval begins. Both
cover the source span without a gap or overlap in visible ownership.

## Typed transcript segment

`TranscriptSegmentV1` is a fixed 384-byte record with up to 64 printable ASCII
bytes. It binds the context and publishable intervals, media, processor and
cache roots, overlap root, previous transcript, and text under one transcript
root.

The shared stateless lifecycle:

1. requires the full feature-plus-context cache payload to be live under its
   restored `LeaseTree` owner;
2. admits exact weight, activation, private candidate, output journal, and
   queue claims;
3. executes into a private 384-byte transcript candidate;
4. strictly decodes and validates the candidate against the pinned overlap
   plan;
5. revalidates the candidate and publication permit at commit;
6. copies the transcript to visible storage and scrubs the candidate; or
7. aborts and scrubs both buffers without advancing the result sequence.

The retained segment uses context `[4,6)`, publishes text for `[6,10)`, and binds
the prior transcript root. A separately valid overlap plan with a different
predecessor cannot enter the transaction.

## Independent evidence

Zig and Python share golden roots for the overlap and transcript records and
flip every byte of both serialized wires. Tests also reject foreign cache
bytes, foreign predecessor lineage, candidate drift, and abort leakage, then
return all model and cache ownership to zero.

Run the proof:

```sh
zig test src/core/audio_transcript_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_transcript_adapter
```

## Claim boundary

The fixture has no microphone, codec, network, provider, filesystem, device, or
clock authority. It uses a tiny exact-integer feature cache and emits the fixed
text `ice`. It does not yet restore a transcript-producing model across a
process restart, acknowledge playback, decode external audio, identify a
language, measure word error rate, or run a production speech model.

Transcript-model restart with exact segment continuity is now complete for the
retained exact-integer fixture through
[Stateful Audio Transcript Continuation](AUDIO_TRANSCRIPT_CONTINUATION.md).
Exact word offsets, sample-derived timestamps, opaque speaker identities, turn
counts, and integer confidence now have a bounded canonical transaction through
[Exact Speech Annotation Publication](SPEECH_ANNOTATION_PUBLICATION.md).
Language/punctuation, token-to-word mapping, overlapping-speaker ambiguity,
calibrated production confidence, generated-audio ordering, and playback
acknowledgement remain separate tracks.
The current newly publishable sample range can already be joined to a verified
video timeline through
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md); conditioning-only
context is excluded from that temporal link.

See [Typed Audio-Window Encoder Adapter](AUDIO_WINDOW_ADAPTER.md),
[Stateful Audio Transcript Continuation](AUDIO_TRANSCRIPT_CONTINUATION.md),
[Exact Speech Annotation Publication](SPEECH_ANNOTATION_PUBLICATION.md),
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
