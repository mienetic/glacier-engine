# Multimodal Roadmap

Status: **integrated model-free image/audio/video runtime plus typed
vision/audio/temporal-video fixtures, stateful transcript and explicit-VFR
video-model restart, bounded streaming, generated-image publication after
terminal-latent restart, generated-PCM publication with exact application
acknowledgement across process restart, two-process continuation, crash-atomic
checkpoint sets, and a post-restore generation-three successor; bounded
processor/cache state and payloads integrated as fifth and sixth durable
archive objects with fresh-Bank restore; production-model execution, physical
playback, and external formats remain gated**.

Glacier will expand from token-oriented execution into image, audio, and video
work only after a restarted request can reacquire exact resource ownership and
resume without duplicated visible output. Format research and tiny legal
fixtures may begin earlier, but production execution does not bypass that gate.
The model-free continuation proof now meets ownership, exact-output, atomic
whole-checkpoint, and phase-complete process-death requirements. Separately, a
model-free media runtime now supplies shared identity, sealed decode plans,
bounded RGB/PCM/intra-frame fixtures, exact source-unit mapping, rational
timeline events, exact `ResourceBank` admission, provisional execution,
candidate revalidation, per-buffer `LeaseTree` ownership, atomic chunk
publication, abort/retry, early provisional retirement, portable receipts, and
exact release. A bounded stream now composes two retained chunks per modality,
rejects target gaps/overlaps before admission, reclaims cancellation without
advancing state, and chains portable chunk receipts. Media-model execution and
production promotion still waits for an uninterrupted/resumed production-model
comparison and retained platform evidence. The model-free stream itself now
crosses a real process boundary: a fixed checkpoint restores retained outputs
under a fresh Bank and publishes the next chunk for every modality. Three
checkpoints, one retained-output bundle, the optional processor-state bundle,
and the optional verified cache-payload bundle now share an atomic archive
root; fresh targets resume the complete previous or successor generation across
all seven root-switch process-death boundaries.
Another fresh process now restores generation two, rebinds six retained-output
leases under three fresh Banks, advances processor state, appends one
image/audio/video chunk, and atomically publishes generation three.
A second fresh process opens generation three and continues all three streams.
A fixed processor-state layer now advances image tile/patch progress, audio
feature windows, and video temporal-cache windows together. It maps audio and
video cursors to one exact integer master clock and commits the lower end tick
as a synchronized watermark. The complete processor bundle is the fifth
stateful checkpoint object, cross-bound to each stream's media, output, and
ownership roots, and advances through the fresh-process generation-three
publication. A sixth canonical bundle carries the exact three cache payloads;
the target charges generation-fenced `activation_bytes` before verification
and visibility, then releases every cache owner to zero.
A typed vision adapter now consumes the live image cache through a sealed
artifact/plan/result contract, computes a deterministic integer embedding into
provisional storage, and publishes only after source, ownership, and candidate
revalidation. Production vision models and quality evidence remain gated.
A typed audio adapter now consumes non-overlapping signed feature windows from
the live audio cache and binds sample rate, window, hop, feature shape, and
source cursor into the same result contract. A second adapter now binds
overlap/context ownership, predecessor continuity, and a fixed transcript
segment. A fresh-process stateful transcript fixture now advances the exact next
sample range. A fixed speech-annotation layer now maps canonical transcript
word bytes onto exact sample ranges, opaque speaker identities, and integer
confidence. Its state chains the next sample, last transcript/result/speaker,
visible words, and speaker turns across a real process restart. Production
audio models, language/punctuation, overlapping-speaker ambiguity, and
calibrated confidence remain gated.
A typed temporal-video adapter now selects a bounded strided frame set from the
live video cache into explicitly charged scratch. Its source mapping binds
frame ordinals, keyframe lineage, eviction boundary, cache generation, and an
exact rational target span; the gather scratch is scrubbed before return.
A typed segment adapter now publishes that selection as a fixed
predecessor-bound event/confidence result with complete source/cache lineage.
A fixed timeline and merge receipt now preserve the accumulated visible tail,
coalesce only same-event overlap/touch, and retain gaps or different events.
A fixed audio/video result-link transaction now maps only newly publishable
transcript samples into that tail, rejects non-integral or non-overlapping
time, and binds both modality lineages. A stateful transcript fixture now
crosses a real process boundary under fresh charged ownership, publishes the
exact next sample range, and advances that link without duplicated text.
An explicit VFR window now binds each frame ordinal, PTS, duration, keyframe,
feature payload, declared inter-window gap, and predecessor. A fresh process
restores retained video-model state, publishes the exact successor segment,
retains the gap in the canonical timeline, and advances the cross-modal link.
External container timestamp normalization, richer subtitle semantics, and
production quality remain gated.
A bounded generative-image output path now verifies the exact restored
checkpoint, terminal plan/result/state, latent digest, decoder identity,
tenant/policy roots, and media publication predecessor before admission. It
decodes into private buffers, preserves visibility on abort or candidate drift,
and commits pixels, provenance, typed result, resource receipt, and media state
together. The native fixture performs the terminal step and publication in a
fresh process, then releases every target resource to zero.
A bounded generated-audio path now publishes raw interleaved PCM behind a
single-outstanding-buffer gate. Fixed state, plan, provenance, result,
observation, and acknowledgement wires bind exact frames, renderer, source
output, media identity, resources, sink identity, and both predecessor chains.
A fresh process verifies the pending buffer before admission, rejects partial
acknowledgement without state change, acknowledges it, aborts one private
successor, publishes the next exact frames, and returns ownership to zero.
This is application acknowledgement; physical playback remains outside the
authority-free core.

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
external decoder, production model, provider, capture, and playback paths
remain `idea` or `prototype fixture`, never `integrated`. The bounded
terminal-latent generated-image path is integrated as runtime conformance, not
production-model or quality evidence. This is the media specialization of the
broader
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

The hierarchical variant now preserves the request-wide claim while splitting
it into a parent receipt plus decoded-source, mapping, optional scratch, and
output allocation leaves. It atomically charges all leaves before use, includes
their pointer-free identities in a fixed 1,536-byte receipt, reclaims every leaf
on abort, and can retire provisional leaves after commit while retaining the
output. By itself it does not durably store output, compose multiple chunks,
retain model embeddings or cross-attention state, or resume across process
death.

The bounded stream layer composes multiple hierarchical transactions under
one target timeline. It retains one output lease per committed chunk, reclaims
unpublished cancellation, rejects target gaps/overlaps and length drift before
admission, and binds each commit to its predecessor in a fixed 352-byte receipt.

The continuation layer adds a fixed 2,048-byte checkpoint. A source process
syncs checkpoint/output bytes, releases its Bank, and exits; a distinct target
process reserves fresh output ownership before materialization, verifies exact
bytes, reconstructs the timeline, and publishes chunk one after chunk zero.
The checkpoint-set layer packages the image, audio, and video checkpoints plus
one canonical retained-output bundle into a single immutable archive selected
by one atomic root. Two lineage-bound generations survive `SIGKILL` after every
archive and selector durability phase without mixed visibility. See the
[Shared Media Contract](MEDIA_CONTRACT.md),
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md), and
[Hierarchical Media Buffer Ownership](MEDIA_RUNTIME_LEASE.md), followed by
[Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md) and
[Media Stream Continuation](MEDIA_STREAM_CONTINUATION.md), then
[Atomic Media Stream Checkpoint Sets](MEDIA_STREAM_CHECKPOINT_SET.md) and
[Multimodal Processor and Cache State](MEDIA_PROCESSOR_STATE.md).

### MediaProcessorState

The bounded model-free state ABI is complete. Three fixed 512-byte processor
records and one fixed 512-byte synchronized record form a canonical 2,272-byte
bundle. The records bind image tile/patch progress, audio window/hop/context
and feature-cache accounting, video temporal-window/eviction state, exact
logical cache bytes, processor/decoder identities, ownership and output roots,
generation predecessors, and an integer audio/video watermark. Zig and Python
share the bundle golden and reject every byte mutation.

Durable logical-state integration is complete: the processor-state bundle is
the fifth object in the stateful atomic media checkpoint set, its records are
cross-bound to all three stream checkpoints, and the fresh-process successor
advances stream and processor lineage together. Four-object archives remain
readable through the explicit compatibility reader.

Caller-owned cache integration is also complete. The sixth object binds exact
image/audio/video payload bytes and predecessor lineage; a fresh
`ResourceBank`/`LeaseTree` keeps all three allocations unmaterialized until byte
verification succeeds. Measured RSS, allocator fragmentation, and device
residency remain outside the claim.

## Image track

Initial use cases:

- image understanding and visual question answering;
- document, chart, screenshot, and diagram analysis;
- image-conditioned local/provider routing; and
- generated-image publication through a terminal-latent output transaction.

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
6. ~~per-buffer lease ownership;~~ complete in the shared hierarchical runtime,
   followed by vision-encoder capability negotiation;
7. ~~bounded two-region chunk publication with target continuity and retained
   outputs;~~ complete for the two retained image rows;
8. continuation binding for processed regions and cross-attention state;
9. ~~generated-image publication with cancellation and provenance;~~ complete
   for one bounded raw gray8 image decoded from the exact post-restart terminal
   latent, with fixed plan/provenance/result wires, atomic abort/retry
   visibility, and independent mutation-complete verification;
10. multi-image/chunk manifests, production decoder integration, and
    crash-atomic external-format composition.

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
4. ~~per-buffer lease ownership;~~ complete in the shared hierarchical runtime;
5. ~~bounded streaming chunk transaction with target overlap/gap evidence and
   cancellation-safe retry;~~ complete for two adjacent retained source ranges;
6. feature-window or audio-token mapping back to source sample ranges; exact
   window/hop/context cursor state is complete for the bounded feature fixture,
   while token mapping remains;
7. ~~partial transcript publication without duplicated text after restart;~~
   complete for a stateful exact-integer fixture: a fresh process reuses
   conditioning context, publishes only the exact next sample range, preserves
   transcript/link predecessors, and releases restored ownership to zero;
8. ~~word timestamps and speaker attribution;~~ complete for fixed state, plan,
   and result wires mapping two chained transcript words to exact sample ranges
   and first-occurrence speaker identities across a real process restart;
   language/punctuation and overlapping-speaker ambiguity remain;
9. ~~generated-audio chunk ordering and playback acknowledgement;~~ complete
   for two bounded raw mono PCM s16le chunks: one outstanding buffer gates its
   successor, exact application observations survive a process restart,
   partial/duplicate acknowledgements fail closed, and cancellation preserves
   visibility;
10. production renderer/codec adapters, shared generated-media manifests, and
    authorized physical playback evidence; and
11. microphone/network adapters outside the authority-free core.

Promotion gate: no sample is silently dropped, duplicated, reordered, mixed, or
resampled; streaming restart resumes at an exact sample/timeline boundary; input
capture and physical output playback require separate capabilities. A logical
application acknowledgement is not evidence that a device emitted sound.

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
5. ~~per-buffer lease ownership;~~ complete in the shared hierarchical runtime;
6. ~~bounded two-frame chunk publication with target continuity, retained
   outputs, and cancellation-safe ownership;~~ complete for the fixture;
7. decode queue admission under deadline and cancellation ceilings;
8. ~~exact audio/transcript linkage to the accumulated video timeline;~~
   complete for one positive-overlap result using exact integer target-time
   mapping and dual-modality lineage; word/subtitle semantics remain;
9. ~~temporal-cache ownership and continuation state;~~ complete for an explicit
   VFR fixture: per-frame timing and feature payloads, retained model state,
   fresh-Bank materialization, successor segment, visible timeline, and
   cross-modal link all advance across distinct processes;
10. external container timestamp/edit-list normalization;
11. generated segment publication with ordered manifest and chunk roots.

Promotion gate: frame selection and temporal ordering replay exactly; explicit
VFR and restart fixtures are integrated, while external-container seek,
corrupt-frame, missing-audio, cancellation, and production campaigns must still
preserve resource accounting and never publish a segment twice.

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
- extend the bounded typed vision, audio, and temporal-video adapters with
  detection and richer transcript result forms over the completed post-restore
  cache ownership path; the first fixed predecessor-bound video-segment result
  deterministic merge timeline, and exact audio/video result link are complete;
- privacy-safe evidence renderers; and
- platform capability probes that report present/missing/denied explicitly.

Each contribution must name its authority, resource ceiling, rejection paths,
retained evidence, and nonclaims. See [Roadmap](ROADMAP.md) for sequencing and
[Evidence policy](EVIDENCE_POLICY.md) for promotion requirements. The completed
baseline is specified in
[Bounded Media Decode Fixtures](MEDIA_DECODE_FIXTURES.md), and the implemented
transform layer is specified in
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md), and the ownership layer
is specified in
[Hierarchical Media Buffer Ownership](MEDIA_RUNTIME_LEASE.md). The completed
bounded stream layer is specified in
[Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md).
