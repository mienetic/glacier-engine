# Exact Speech Annotation Publication

Status: **integrated deterministic runtime fixture; production ASR,
diarization, and confidence calibration gated**.

Glacier can now publish word-level sample timing and speaker attribution as a
bounded transaction chained to its overlap-safe transcript records. The
annotation state survives a real process restart: a source publishes `ice` for
samples `[2,10)` with one speaker, and a fresh target publishes `berg` for
`[10,18)` with a different speaker without duplicating a word or turn.

This is runtime and evidence conformance for ASR, diarization, subtitle, meeting
analysis, and voice-agent infrastructure. The fixed words and confidence values
do not measure recognition, alignment, language, speaker-identification, or
production-model quality.

## Portable records

| Record | Size | Purpose |
| --- | ---: | --- |
| `SpeechAnnotationStateV1` | 384 bytes | Chains publication sequence, next sample, visible word/turn counts, last transcript/result/speaker, policy, and challenge |
| `SpeechAnnotationPlanV1` | 576 bytes | Pins one transcript/overlap, exact sample and text bounds, media/cache lineage, state predecessor, and output ceilings |
| `SpeechAnnotationResultV1` | 896 bytes | Publishes up to four word spans and two speaker identities with confidence, before/after counts, lineage, and one result root |

Every serialized byte is covered by a domain-separated root. Zig and an
independent Python oracle reconstruct the same golden state, plan, and result
roots and reject mutation of every byte.

Words refer to exact byte ranges in the existing canonical transcript rather
than copying text into another authority-bearing structure. Each word binds:

- text offset and byte length;
- inclusive start and exclusive end sample;
- speaker-palette index; and
- integer confidence in parts per million.

Text must have canonical single-space token boundaries. Word entries cover
every token exactly, are ordered and non-overlapping in sample time, start at
the transcript's publish boundary, and end at its exact final sample. Speaker
identities are opaque digests, unique within the bounded palette, and ordered by
first occurrence. The runtime counts a turn whenever the active speaker digest
changes, including across process boundaries.

## Transaction boundary

Before resource admission, the plan must match the complete annotation state,
overlap record, transcript segment, audio media, processor/cache lineage,
sample rate, challenge, and previous result.

Prepare derives the annotation into a private caller-owned 896-byte candidate.
Visible output and state remain unchanged. Commit revalidates the resource
permit, plan inputs, current state, candidate hash, canonical wire, word
coverage, timing, speaker order, and expected successor state before one
infallible visibility suffix. Abort or candidate drift scrubs the candidate and
does not advance any word, turn, sample, or sequence counter.

Closing releases the exact `ResourceBank` claim. Both native processes finish
with zero Bank bytes, live allocations, and active lease trees.

## Process-restart proof

The source publishes annotation one, syncs the 384-byte successor state, first
result, first transcript, and PID, releases its claim, and exits. A different
target PID:

1. decodes and verifies all persisted wires before admission;
2. requires the state predecessor to match the first result and transcript;
3. derives the exact second plan at sample 10;
4. aborts one prepared annotation and proves visibility is unchanged;
5. retries and commits `berg [10,18)` with the second speaker once; and
6. releases every target resource.

Run the retained evidence:

```sh
zig test src/core/speech_annotation_publication.zig -OReleaseSafe
python3 -m unittest bench.tests.test_speech_annotation_publication
zig build speech-annotation-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The portable core has no microphone, codec, filesystem, network, provider,
accelerator, playback, wall-clock, or device authority. The worker receives
filesystem authority only for the bounded native restart demonstration. Its
individually synced files are process-restart evidence, not one crash-atomic
checkpoint set or device-power-loss proof.

## Next audio slices

1. token-to-word and punctuation/language metadata under versioned policies;
2. multi-word and overlapping-speaker fixtures with explicit ambiguity;
3. crash-atomic composition with transcript-model and cross-modal checkpoints;
4. external container/timestamp normalization;
5. a generated-audio chunk transaction with exact waveform timeline,
   cancellation, provenance, and playback acknowledgement; and
6. production ASR/diarization adapters with quality, latency, memory, and
   energy evidence on named artifacts and platforms.

See [Overlap-Safe Audio Transcript Adapter](AUDIO_TRANSCRIPT_ADAPTER.md),
[Stateful Audio Transcript Continuation](AUDIO_TRANSCRIPT_CONTINUATION.md),
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
