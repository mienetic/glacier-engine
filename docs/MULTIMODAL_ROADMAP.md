# Multimodal Roadmap

Status: **planned after the durable-continuation promotion gate**.

Glacier will expand from token-oriented execution into image, audio, and video
work only after a restarted request can reacquire exact resource ownership and
resume without duplicated visible output. Format research and tiny legal
fixtures may begin earlier, but production execution does not bypass that gate.

The goal is one typed media substrate rather than three unrelated pipelines.
Every modality must preserve the same Glacier properties:

- content identity is separate from access authority;
- decoding and preprocessing are explicit plans, not ambient library behavior;
- every allocation, frame, sample, patch, and cached representation is admitted;
- provisional model-visible state commits through a transaction;
- continuation state binds exact media position and preprocessing lineage;
- external-provider use records exact transmitted bytes and reported usage; and
- claims remain scoped to retained fixtures and measured platforms.

## Entry gate

Multimodal execution starts after all of these continuation requirements pass:

1. evidence publication is durably ordered before destructive payload removal;
2. ~~a native durable payload-byte store can reconcile old/new transition
   snapshots after process death;~~ complete for canonical payload bytes across
   seven retained macOS process-death boundaries; lifecycle metadata is outside
   this completed slice;
3. ResourceBank and LeaseTree ownership can be reacquired without duplication;
4. paged KV restoration rejects foreign model, tokenizer, or generation state;
5. a process restart between token publications produces no duplicated output;
6. the retained platform matrix distinguishes process death from device power
   loss.

Until then, the tracks below remain `idea` or `prototype fixture`, never
`integrated`.

## Shared media foundation

### MediaObject

A pointer-free `MediaObjectV1` will identify an immutable source payload without
embedding it:

```text
tenant scope + media kind + semantic ABI
content digest + exact byte length
container/codec identity
declared logical geometry or time base
metadata-policy root + provenance root
```

The descriptor is not permission to read a file, URL, camera, or microphone.
A separately scoped resolver grants access to one exact object and byte ceiling.
Container metadata is treated as untrusted input until canonical validation.

### MediaDecodePlan

One sealed plan binds:

- decoder implementation and version;
- source and destination representations;
- color, channel, orientation, time-base, and normalization policy;
- exact output bounds and scratch requirements;
- accelerator capability and numerical policy;
- deterministic versus quality-oriented execution mode; and
- rejection behavior when a requested conversion is unavailable.

Silent codec fallback is not admissible. Two decoders producing different
semantic tensors receive different execution identities.

### MediaTimeline

Audio samples, image regions, video frames, subtitles, and generated tokens need
one rational time/position vocabulary. Timeline values use checked integers and
explicit numerators/denominators rather than floating-point wall-clock values.
Discontinuity, trim, pad, resample, frame drop, and reordering are explicit
events.

### MediaTxn

A media transaction stages:

- decoded or generated chunks;
- model embeddings and cross-attention state;
- logical timeline advancement;
- ResourceBank/LeaseTree ownership;
- output bytes or references; and
- evidence roots.

Commit makes all of them visible together. Cancellation or failure releases the
provisional resources and leaves the previous media/timeline root unchanged.

## Image track

Initial use cases:

- image understanding and visual question answering;
- document, chart, screenshot, and diagram analysis;
- image-conditioned local/provider routing; and
- later, generated-image publication through an output transaction.

First slices:

1. tiny lossless RGB/gray fixture with width, height, channels, row stride,
   orientation, color model, transfer function, and alpha semantics;
2. bounded decoder output into caller-owned storage;
3. canonical resize/crop/tile plan with source-region mapping;
4. patch/token correspondence evidence without storing private pixels;
5. vision-encoder capability negotiation and exact resource admission;
6. continuation binding for processed regions and cross-attention state;
7. generated-image chunk publication with cancellation and provenance.

Promotion gate: every accepted pixel maps to an exact source region and
preprocessing plan; orientation/color drift, decompression bombs, foreign
metadata, truncated payloads, and over-budget geometry reject before model
execution.

## Audio track

Initial use cases:

- speech recognition and translation;
- speech/audio understanding;
- streaming voice interaction;
- text-to-speech; and
- local preprocessing before an explicitly authorized provider request.

First slices:

1. bounded PCM fixture with sample format, sample rate, channel count/layout,
   frame count, and rational start time;
2. canonical channel mix and resample plan with exact input/output ranges;
3. streaming chunk transaction with overlap and gap evidence;
4. feature-window or audio-token mapping back to source sample ranges;
5. partial transcript publication without duplicated text after restart;
6. generated-audio chunk ordering and playback acknowledgement;
7. microphone/network adapters outside the authority-free core.

Promotion gate: no sample is silently dropped, duplicated, reordered, mixed, or
resampled; streaming restart resumes at an exact sample/timeline boundary; input
capture and output playback require separate capabilities.

## Video track

Initial use cases:

- video understanding, search, summarization, and event extraction;
- frame/segment-conditioned generation;
- synchronized audio/video analysis; and
- later, transactional generated-video publication.

First slices:

1. tiny intra-frame fixture with coded/display geometry, pixel model, frame
   count, and rational frame time;
2. bounded frame-index/keyframe map;
3. deterministic frame-selection plan with exact source coverage;
4. decode queue admission under memory, deadline, and cancellation ceilings;
5. audio/subtitle linkage through `MediaTimeline`;
6. temporal-cache ownership and continuation state;
7. generated segment publication with ordered manifest and chunk roots.

Promotion gate: frame selection and temporal ordering replay exactly; seek,
variable-frame-rate, corrupt-frame, missing-audio, cancellation, and restart
cases preserve resource accounting and never publish a segment twice.

## Provider efficiency

Media support may reduce external work when Glacier can safely:

- deduplicate identical immutable media objects;
- reuse a compatible local preprocessing result;
- cache exact media prefixes, patches, or feature windows;
- route privacy-restricted work locally; or
- send only explicitly selected regions or time ranges.

These are possible mechanisms, not universal token or cost savings. Evidence
must separately report source bytes, decoded bytes, logical media units,
provider-transmitted bytes, provider-reported input units, cache decisions,
latency, and cost. A provider-specific tokenizer or media accounting rule is
never inferred from local byte counts.

## Contributor-ready boundaries

Early contributions can proceed without a large model:

- canonical descriptor codecs and mutation-complete verifiers;
- tiny redistributable image/audio/video fixtures;
- checked geometry and rational-time arithmetic;
- decompression and allocation ceiling tests;
- deterministic crop/resample/frame-selection reference models;
- privacy-safe evidence renderers; and
- platform capability probes that report present/missing/denied explicitly.

Each contribution must name its authority, resource ceiling, rejection paths,
retained evidence, and nonclaims. See [Roadmap](ROADMAP.md) for sequencing and
[Evidence policy](EVIDENCE_POLICY.md) for promotion requirements.
