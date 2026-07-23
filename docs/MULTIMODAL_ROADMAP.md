# Multimodal Roadmap

Status: **integrated model-free image/audio/video runtime vertical; media-model
execution, streaming, and external formats remain gated**.

Glacier will expand from token-oriented execution into image, audio, and video
work only after a restarted request can reacquire exact resource ownership and
resume without duplicated visible output. Format research and tiny legal
fixtures may begin earlier, but production execution does not bypass that gate.
The model-free continuation proof now meets ownership, exact-output, atomic
whole-checkpoint, and phase-complete process-death requirements. Separately, a
model-free media runtime now supplies shared identity, sealed decode plans,
bounded RGB/PCM/intra-frame fixtures, exact source-unit mapping, rational
timeline events, exact `ResourceBank` admission, provisional execution,
candidate revalidation, atomic chunk publication, abort/retry, portable
receipts, and exact release. Media-model execution still waits for an
uninterrupted/resumed production-model comparison and retained platform
evidence.

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

1. ~~evidence publication is durably ordered before destructive payload
   removal;~~ complete for the current payload-store transition;
2. ~~a native durable payload-byte store can reconcile old/new transition
   snapshots after process death;~~ complete for canonical payload bytes across
   seven retained macOS process-death boundaries; lifecycle metadata is outside
   this completed slice;
3. ~~ResourceBank and LeaseTree ownership can be reacquired without
   duplication;~~ complete as a model-free fresh-Bank prototype;
4. ~~paged KV restoration rejects foreign model, tokenizer, or generation
   state;~~ complete through capsule composition plus fresh-generation remap;
5. ~~a process restart between token publications produces no duplicated
   output;~~ complete for the natural-exit model-free proof;
6. ~~the retained platform matrix distinguishes process death from device power
   loss;~~ the current evidence explicitly claims process death only;
7. ~~one atomic candidate/active protocol publishes the complete checkpoint set
   and survives termination at every durable phase;~~ complete for the
   seven-phase model-free root-switch campaign;
8. an uninterrupted and resumed production-model fixture has equivalent
   visible output under one declared numerical mode.

Until then, the bounded model-free runtime may advance independently, while
external decoder, model, provider, capture, playback, and generated-media paths
remain `idea` or `prototype fixture`, never `integrated`. This is the media
specialization of the broader
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).

## Shared media foundation

### MediaObject

Prototype complete. A pointer-free 272-byte `MediaObjectV1` identifies an
immutable source payload without embedding it:

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
The current contract validates distinct image, audio, and video axes/time bases,
uses separate content, tenant, metadata-policy, and provenance roots, and has
mutation-complete Zig/Python fixtures. A versioned container/codec registry and
bounded resolver remain future slices.

### MediaDecodePlan

Prototype complete as a fixed 416-byte wire. One sealed plan binds:

- decoder implementation and version;
- source and destination representations;
- color, channel, orientation, time-base, and normalization policy;
- exact output bounds and scratch requirements;
- accelerator capability and numerical policy;
- deterministic versus quality-oriented execution mode; and
- rejection behavior when a requested conversion is unavailable.

Silent codec fallback is not admissible. Two decoders producing different
semantic tensors receive different execution identities.
The current reference decoder accepts only deterministic exact-integer identity
plans with zero ambient capabilities, exact output length, zero scratch, and
the retained tiny fixture implementation root.

### MediaTimeline

Prototype core complete. Timeline values use checked integers and explicit
reduced numerators/denominators rather than floating-point wall-clock values.
Exact conversion rejects non-integral positions. Identity, trim, pad, resample,
frame-selection, and reorder events bind source/target spans, plan identity, and
prior event root. Image regions, gaps/overlaps, subtitles, discontinuities, and
cross-stream synchronization still need richer policies.

### MediaTxn

The first logical publication slice is complete: prepare binds the exact prior
state, sequence, chunk/unit range, media and event roots, output root,
resource-claim root, and previous commit. Commit revalidates the complete value,
advances the logical state once, and rejects stale replay without mutation.

The first integrated model-free transaction is also complete. It:

- derives and admits the exact decoded-source, mapping, scratch, output, I/O, and
  queue claim before execution;
- decodes and transforms into provisional caller-owned buffers;
- reconstructs output, every mapping, and the transform receipt before commit;
- prepares timeline and output publication against the exact prior media state;
- revalidates the `ResourceBank` permit and complete candidate;
- commits both publication sequences once or scrubs all provisional buffers on
  abort; and
- emits a fixed 640-byte receipt before closing and releasing the exact claim.

The current claim is request-wide rather than subdivided through `LeaseTree`.
The transaction does not durably store output, stream multiple chunks, retain
model embeddings or cross-attention state, or resume across process death. See
the [Shared Media Contract](MEDIA_CONTRACT.md) and
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md).

## Image track

Initial use cases:

- image understanding and visual question answering;
- document, chart, screenshot, and diagram analysis;
- image-conditioned local/provider routing; and
- later, generated-image publication through an output transaction.

First slices:

1. ~~tiny lossless RGB fixture with width, height, channels, row stride,
   orientation, color model, transfer function, and alpha semantics;~~ complete
   for the retained 2×2 RGB8 fixture;
2. ~~bounded decoder output into caller-owned storage;~~ complete for the
   identity fixture decoder with per-pixel source-byte mappings;
3. ~~canonical resize/crop/tile plan with source-region mapping;~~ complete for
   a sealed crop plus nearest-resize plan with 1×1 output tiles and exact source
   pixel mappings over the retained fixture;
4. ~~exact runtime admission, provisional execution, atomic publication,
   abort/retry, receipt, and release;~~ complete for the retained fixture;
5. patch/token correspondence evidence without storing private pixels;
6. vision-encoder capability negotiation and per-buffer lease ownership;
7. continuation binding for processed regions and cross-attention state;
8. generated-image chunk publication with cancellation and provenance.

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

1. ~~bounded PCM fixture with sample format, sample rate, channel count/layout,
   frame count, and rational start time;~~ complete for eight interleaved stereo
   s16le frames at 48 kHz with per-frame source/timeline mappings;
2. ~~canonical channel mix and resample plan with exact input/output ranges;~~
   complete for weighted stereo-to-mono mixing and exact integer decimation
   from 48 kHz to 16 kHz over the retained fixture; general resampling remains;
3. ~~exact runtime admission, provisional execution, atomic publication,
   abort/retry, receipt, and release;~~ complete for the retained fixture;
4. streaming chunk transaction with overlap and gap evidence;
5. feature-window or audio-token mapping back to source sample ranges;
6. partial transcript publication without duplicated text after restart;
7. generated-audio chunk ordering and playback acknowledgement;
8. microphone/network adapters outside the authority-free core.

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

1. ~~tiny intra-frame fixture with coded/display geometry, pixel model, frame
   count, and rational frame time;~~ complete for two 2×2 gray8 frames at 30
   fps;
2. bounded frame-index/keyframe map; the current fixture has a verified
   64-frame-bounded keyframe bitmap and per-frame byte/timeline mappings, while
   a seek/index structure remains;
3. ~~deterministic frame-selection plan with exact source coverage;~~ complete
   for keyframe-only selection with exact source bytes and source/target ticks
   over the retained fixture;
4. ~~exact runtime admission, provisional execution, atomic publication,
   abort/retry, receipt, and release;~~ complete for the retained fixture;
5. decode queue admission under deadline and cancellation ceilings;
6. audio/subtitle linkage through `MediaTimeline`;
7. temporal-cache ownership and continuation state;
8. generated segment publication with ordered manifest and chunk roots.

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

- extend canonical descriptor/plan codecs and mutation-complete verifiers;
- checked geometry and rational-time arithmetic;
- decompression and allocation ceiling tests;
- extend the completed deterministic crop/nearest, mix/exact-decimation, and
  keyframe-selection reference models with new bounded cases;
- subdivide the admitted media claim through `LeaseTree` and prove zero-state
  recovery under abort, commit, and cancellation;
- privacy-safe evidence renderers; and
- platform capability probes that report present/missing/denied explicitly.

Each contribution must name its authority, resource ceiling, rejection paths,
retained evidence, and nonclaims. See [Roadmap](ROADMAP.md) for sequencing and
[Evidence policy](EVIDENCE_POLICY.md) for promotion requirements. The completed
baseline is specified in
[Bounded Media Decode Fixtures](MEDIA_DECODE_FIXTURES.md), and the implemented
transform layer is specified in
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md).
