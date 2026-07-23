# Benchmark and Evidence Guide

Glacier treats benchmark output as evidence about one declared configuration,
not as a universal property of the project. A publishable result needs the raw
artifact, machine conditions, correctness gate, paired order, and an explicit
claim boundary.

## Evidence levels

| Level | Meaning | Suitable wording |
| --- | --- | --- |
| Conformance | A deterministic fixture satisfies a contract | “The fixture verifies…” |
| Diagnostic | One run exposes behavior for investigation | “This run observed…” |
| Paired experiment | Randomized same-machine pairs pass validity gates | “On this machine and workload…” |
| Replicated campaign | Several machines/workloads reproduce the effect | “Across the tested matrix…” |
| Release claim | Reproducible campaign, quality gates, and retained artifacts | Wording limited to the published matrix |

Passing a conformance demo does not establish throughput, physical memory,
energy, or production reliability.

## Current conformance surfaces

| Command | Contract exercised |
| --- | --- |
| `zig build lane-weave-demo -Dmetal=false` | Exact admission, deterministic weighted service, rejection, cancellation, final release |
| `zig build lane-publication-demo -Dmetal=false` | One-token prepare/commit/abort with KV, RNG, sampler, output, schedule, and resource roots |
| `zig build lane-contiguous-demo -Dmetal=false` | Concrete contiguous KV row publication and portable receipt |
| `zig build continuation-capsule-demo -Dmetal=false` | Fixed-size committed-checkpoint manifest, typed external object binding, and substitution rejection |
| `zig build continuation-resolver-demo -Dmetal=false` | Tenant-scoped exact-object lookup, bounded quotas, caller-owned output, and full composition verification |
| `zig build continuation-bundle-demo -Dmetal=false` | Fixed tenant bundle, semantic/blob identity separation, canonical ordinals, and exact logical/unique totals |
| `zig build continuation-store-demo -Dmetal=false` | Atomic bundle import, duplicate reuse, generation-fenced leases, quarantine repair, exact accounting, and v1/v2 snapshots |
| `zig build continuation-collection-demo -Dmetal=false` | Exact root multiplicity, complete lease coverage, bounded classification, and a non-mutating collection-plan root |
| `zig build continuation-sweep-demo -Dmetal=false` | Separately scoped plan regeneration, staging ceilings, functional prepare/abort roots, and zero payload deallocation |
| `zig build continuation-sweep-commit-demo -Dmetal=false` | Exact no-mutation preview, real file publication before deallocation, injected-boundary recovery, idempotent old/new reconciliation, exact accounting, and allocator tail reclamation |
| `zig build continuation-sweep-record-demo -Dmetal=false` | Fixed record verification, anchored tail classification, snapshot-bound append/repair capabilities, ordered sync, and deterministic crash-storage conformance |
| `zig build continuation-sweep-file-demo -Dmetal=false` | Descriptor-relative lock/identity/sync checks and six native subprocess-death recovery boundaries |
| `zig build continuation-payload-file-demo -Dmetal=false` | Canonical payload snapshots, fixed exact-target reclaim plans, copy-on-write promotion, and seven native subprocess-death recovery boundaries |
| `zig build continuation-live-restart-demo -Dmetal=false` | Fresh-process ownership/KV/RNG/output restore and exact-once publication of the next token |
| `zig build continuation-checkpoint-file-demo -Dmetal=false` | Immutable whole-checkpoint archive, atomic selector switch, seven process-death phases, and fresh live resume after each recovery |
| `zig build media-contract-demo -Dmetal=false` | Fixed image/audio/video descriptors, exact rational mapping, explicit event lineage, two logical chunk commits, and stale-replay rejection |
| `zig build media-decode-fixture-demo -Dmetal=false` | Sealed plans plus bounded RGB8, PCM s16le, and intra-frame gray8 fixture decode with complete per-unit source mapping |
| `zig build media-transform-demo -Dmetal=false` | Sealed image/audio/video transform plans, caller-owned allocation-free execution, exact output-unit mappings, and shared cross-language plan/receipt roots |
| `zig build media-runtime-demo -Dmetal=false` | Exact image/audio/video ResourceBank admission, provisional execution, candidate revalidation, atomic commit/abort/retry, fixed receipts, and complete release |
| `zig build media-runtime-lease-demo -Dmetal=false` | Per-buffer LeaseTree charge-before-use, abort reclamation, early provisional retirement, retained output ownership, fixed hierarchical receipts, and final zero state |
| `zig build media-stream-demo -Dmetal=false` | Six bounded image/audio/video chunks, two retained outputs per stream, cancellation-safe retry, exact target gap/overlap rejection, portable chunk chaining, and final zero state |
| `zig build media-stream-continuation-demo -Dmetal=false` | Three portable 2,048-byte checkpoints, fresh-Bank charge-before-materialization output restore, exact next-chunk publication, and final zero state |
| `zig build media-stream-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, synced image/audio/video checkpoints and retained outputs, three resumed chunks, zero duplicates, and explicit non-atomic-set disclosure |
| `zig build media-stream-checkpoint-set-demo -Dmetal=false` | Six-object materialized image/audio/video generations, canonical retained-output, processor-state, and cache-payload bundles, seven `SIGKILL` boundaries, restore-before-visible cache ownership, fresh-process generation three, idempotent recovery, and final zero ownership |
| `zig test src/core/vision_encoder_adapter.zig -OReleaseSafe` | Canonical model artifact/plan/result records, explicit support negotiation, a live-cache exact-integer vision projection, candidate drift rejection, transactional typed embedding publication, and final zero ownership |
| `zig test src/core/audio_window_adapter.zig -OReleaseSafe` | Live signed feature windows, exact sample/window/hop source mapping, shared stateless adapter publication, abort/drift rejection, and final zero ownership |
| `zig test src/core/audio_transcript_adapter.zig -OReleaseSafe` | Canonical overlap and transcript wires, context-only versus publishable sample ranges, live cache ownership, predecessor/candidate substitution rejection, transactional text visibility, and final zero ownership |
| `zig test src/core/temporal_video_adapter.zig -OReleaseSafe` | Live temporal cache, canonical strided-frame selection, keyframe/eviction lineage, charged-and-scrubbed gather scratch, exact target-time mapping, candidate drift rejection, and final zero ownership |
| `zig test src/core/video_segment_adapter.zig -OReleaseSafe` | Canonical 512-byte video segments, exact frame/time bounds, live selection/cache lineage, predecessor binding, mutation rejection, transactional visibility, and final zero ownership |
| `zig test src/core/video_segment_timeline.zig -OReleaseSafe` | Canonical 384-byte timeline/merge wires, same-event overlap coalescing, gap/event separation, raw/decision lineage, mutation and candidate-drift rejection, and final zero ownership |
| `zig test src/core/audio_video_result_link.zig -OReleaseSafe` | Canonical 320-byte state and 576-byte cross-modal result wires, publish-only audio mapping, exact time conversion, positive-overlap relations, dual-modality lineage, mutation/drift rejection, and final zero ownership |
| `zig test src/core/audio_transcript_continuation.zig -OReleaseSafe` | Exact 32-byte transcript state, canonical 576-byte composed checkpoint, previous/next sample continuity, foreign-lineage rejection before admission, fresh-Bank restore, second transcript/link publication, and final zero ownership |
| `zig build audio-transcript-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, synced transcript/state/link evidence, charge-before-materialization restore, context reuse without duplicate text, exact next sample range, cross-modal link continuation, and final zero ownership |
| `zig test src/core/speech_annotation_publication.zig -OReleaseSafe` | Fixed annotation state/plan/result wires, exact transcript-word/sample/speaker bindings, canonical palette ordering, mutation/substitution rejection, abort/drift preservation, atomic publication, and final zero ownership |
| `zig build speech-annotation-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, state validation before admission, exact `ice`/`berg` sample ranges, two speaker turns, one cancellation-safe retry, zero duplicate words, and final zero ownership |
| `zig test src/core/latent_step_adapter.zig -OReleaseSafe` | Canonical retained-state wire, pinned model/state snapshots, buffer-alias rejection, exact latent candidate, atomic state/result publication, abort/drift preservation, and final zero ownership |
| `zig build stateful-model-live-restart-demo -Dmetal=false` | Canonical intermediate checkpoint, distinct source/target PIDs, fresh-Bank charge-before-materialization latent restore, chained terminal plan, zero duplicate results, and final zero ownership |
| `zig test src/core/generated_image_publication.zig -OReleaseSafe` | Fixed generated-image plan/provenance/result wires, exact terminal-latent lineage, bounded private decode, abort/drift visibility preservation, atomic image publication, mutation rejection, and final zero ownership |
| `zig build generated-image-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, charge-before-materialization latent restore, exact terminal step, one cancelled image publication, atomic retry, bound provenance, zero duplicate images, and final zero ownership |
| `zig build provider-gateway-demo -Dmetal=false` | Request coalescing, reservation, settlement, fixed-point cost, and journal append |
| `zig build provider-transport-demo -Dmetal=false` | Credential-free chunk and terminal-usage transport replay |
| `zig build provider-cancel-demo -Dmetal=false` | Consumer withdrawal and active transport cancellation |
| `zig build provider-context-pack-demo -Dmetal=false` | Lossless exact-duplicate mapping and deterministic token fixture |
| `zig build provider-context-reconciliation-demo -Dmetal=false` | Raw/packed full-wire token observations bound to one execution identity |
| `zig build provider-context-adapter-demo -Dmetal=false` | Allocation-free renderer/token-counter adapter fixture |

All commands should normally use `-Doptimize=ReleaseSafe` when validating
contracts. They are credential-free. Most are model-free; the vision adapter
test runs only a deterministic exact-integer reference fixture.

The typed model-family proof records canonical artifact/plan/result roots,
explicit support decisions, exact integer fixture output, provisional candidate
behavior, publication state, and zero logical ownership after close. It is
adapter-contract evidence, not vision quality, production-model compatibility,
accelerator performance, or physical memory evidence.

The audio and temporal-video adapters add exact signed-window projection,
strided frame gathering, and cross-language source-mapping roots. The segment
fixture adds a fixed source/time-bound event result and predecessor lineage;
the timeline fixture adds deterministic overlap decisions and accumulated-tail
state. The cross-modal fixture maps only newly visible transcript samples onto
that tail, rejects fractional and non-overlapping ranges, and retains both
histories in one link. These fixtures do not measure transcription or video
quality, semantic alignment, streaming model restart, latency, throughput, or
physical memory. The transcript fixture's fixed ASCII text is not
recognition-quality evidence.

The stateful transcript continuation fixture adds a deterministic
`audio_understanding / transcribe` model transition, a fixed composed
checkpoint, and a real source/target process handoff. The first process
publishes samples `2..10`; the target reuses context `8..10`, publishes only
`10..18`, and advances the cross-modal link once. These fixed strings and tiny
integer features prove restart mechanics, not recognition quality, word
alignment, production-model compatibility, latency, throughput, or physical
memory.

The stateful VFR video continuation fixture adds explicit per-frame ordinal,
PTS, duration, keyframe, feature-payload, and declared-gap evidence. A source
process publishes frames `0,1` over ticks `[0,20)`; a fresh target restores the
model and publishes frames `2,3` over `[25,50)` after the exact five-tick gap,
then advances timeline and cross-modal link state. The retained durations
`8,12,10,15` prove contract-level VFR handling. They do not measure decode
correctness for external containers, event quality, production-model
compatibility, latency, throughput, energy, or physical memory.

The latent-step fixture adds state/result atomicity and a cross-language
transition root. The live-restart fixture then chains two exact steps across
distinct processes through a cross-language 512-byte checkpoint and fresh
retained-state ownership. It does not measure generation quality, production
scheduler fidelity, accelerator performance, crash-atomic checkpoint
publication, or production compatibility.

The generated-image fixture consumes that exact terminal lineage through a
bounded decoder. It emits four raw gray8 pixels plus fixed provenance and result
wires, preserves sentinel visibility through one abort, then publishes once in
the fresh target process. This is conformance evidence for binding,
cancellation, atomic visibility, and release—not image quality, production
decoder compatibility, external format support, latency, throughput, memory,
energy, or durable multi-file publication.

The speech-annotation fixture maps `ice` and `berg` onto exact adjacent sample
ranges and two opaque speaker identities. Its fresh target validates the
persisted annotation predecessor before resource admission, aborts one
candidate without visibility, then publishes word and turn two. This proves
wire, ordering, restart, cancellation, and ownership semantics—not ASR,
alignment, diarization, confidence calibration, language, latency, throughput,
memory, energy, or production compatibility.

## Shared media contract

The media conformance fixture accepts one synthetic image, audio, and video
descriptor through the same 272-byte wire. Zig and an independent Python model
share the audio-object and first-publication golden roots. Both verify
kind-specific fields, canonical rational bases, and exact publication lineage;
the descriptor test flips all 272 serialized bytes and rejects every mutation.

The demo maps a one-second 48 kHz audio span exactly into a 16 kHz timeline,
rejects one-sample conversion into a 44.1 kHz base, commits two ordered chunks,
and rejects replay of the first prepared commit without state mutation. It
loads no model or media library and requests no file, network, device, camera,
or microphone authority.

This is contract conformance, not an execution benchmark. It supports no claim
about codec coverage, model quality, provider units, throughput, latency,
memory, storage, or energy.

The bounded decode fixture adds three canonical inputs totaling 1,108 encoded
bytes and 52 decoded payload bytes. It maps four RGB pixels, eight stereo PCM
frames, and two video frames—14 units total—without heap allocation, scratch
storage, ambient capabilities, external codecs, or model execution. The
independent Python oracle shares all fixture, plan, and decode-receipt roots and
mutation-checks every byte of all six wires.

These deliberately tiny counts describe test coverage, not performance or
format support. See [Bounded Media Decode Fixtures](MEDIA_DECODE_FIXTURES.md)
for the exact claim boundary.

The transform conformance fixture adds three operations over those decoded
bytes: crop/nearest/tile mapping for the image, weighted stereo-to-mono mix with
an exact factor-three decimation for audio, and keyframe selection for video.
It emits 20 output bytes and seven exact mappings with zero heap allocation,
zero scratch, and zero ambient capabilities. Zig and the independent Python
oracle share all three 512-byte plan roots and all three receipt roots.

These are correctness fixtures, not latency, throughput, signal-quality,
format-coverage, or model-execution results. See
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md).

The runtime-transaction fixture composes those operations with exact logical
admission and publication. Across the three requests it admits 3,752 host bytes,
publishes 20 output bytes with seven exact mappings, exercises one explicit
abort/scrub/retry path, commits three media transitions, emits three fixed
640-byte receipts, releases all three claims, and ends with zero Bank usage.
The independent Python verifier reconstructs each transform, mapping chain,
resource receipt, timeline event, publication commit, and runtime receipt.

The hierarchical runtime demo admits the same 3,752 host bytes but separates
control-plane admission from six live allocation leaves per scratch-free
request. Across the three modalities it retires six provisional allocations
early, retains exactly one output allocation per committed request, performs 12
reclamation commits including the explicit audio abort/retry path, and returns
all Bank usage and live allocations to zero. Its fixed 1,536-byte receipt binds
the parent, tree state, and ordered scope/allocation evidence. A separate Python
oracle reconstructs the same no-abort golden roots and rejects every serialized
byte mutation.

The bounded stream demo commits six chunks—two per modality—while retaining two
output allocations at each stream's peak. It retires 12 provisional allocations
after successful publication, reclaims one cancelled audio chunk, rejects one
target gap and one target overlap before admission, performs 21 total
reclamation commits, and closes with zero Bank usage, live allocations, and
active trees. The fixed 352-byte chunk record chains each publication to its
predecessor; the independent oracle shares a two-chunk golden chain and
mutation-complete wire coverage.

The media continuation demo checkpoints after chunk zero for all three
modalities, releases each source Bank, restores one output allocation in a
fresh Bank, and appends chunk one. The two-process companion repeats the same
three paths under distinct source and target PIDs after file and directory
sync. Both finish with zero Bank usage, live allocations, and active trees. The
independent oracle shares the fixed 2,048-byte image checkpoint root and rejects
every serialized byte mutation. These first two commands are
restart-conformance counts and do not claim that their separate files form one
crash-atomic set.

The checkpoint-set demo closes that visibility gap. It packs three fixed
checkpoints, six retained outputs, one processor-state bundle, and one
cache-payload bundle into six archive objects, then publishes generation two
over generation one. Seven
publisher deaths expose generation one five times and generation two twice;
fresh targets resume all three streams both before repair and after idempotent
recovery. The observed campaign performs 42 resumed modality-chunks with zero
duplicates and zero final Bank usage. A fresh worker then restores generation
two, rebinds six output leases, charges and verifies `1,104` cache bytes,
advances processor state, appends three chunks, publishes a six-object
nine-output generation three with `1,288` cache bytes, and releases all
ownership. Another fresh worker opens that new root, restores its caches, and
resumes three more chunks, bringing the demo total to 45. It exercises real
process death and sync calls, not storage-device power loss.

The processor-state demo advances two generations of a fixed 2,272-byte
image/audio/video state bundle. Generation two records two processed image
tiles, two audio feature windows with a 400-sample window and 160-sample hop,
and two temporal video-cache entries. Exact integer mapping produces audio tick
560, video tick 800, and synchronized watermark 560 under a 400-tick skew
ceiling. Rehashed processor substitution, ownership replay, and skipped audio
windows reject. These are logical state and cache-byte conformance values, not
processor throughput or physical memory measurements.

These values are deterministic conformance counts. They do not measure process
memory, physical device residency, throughput, latency, model quality, codec
coverage, or provider usage. See
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md) and
[Hierarchical Media Buffer Ownership](MEDIA_RUNTIME_LEASE.md), followed by
[Multimodal Processor and Cache State](MEDIA_PROCESSOR_STATE.md),
[Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md) and
[Media Stream Continuation](MEDIA_STREAM_CONTINUATION.md), followed by
[Atomic Media Stream Checkpoint Sets](MEDIA_STREAM_CHECKPOINT_SET.md).

## Continuation checkpoint

The current fixture encodes a 608-byte manifest over nine external object types.
The demo's object payloads total 264 bytes but zero payload bytes are embedded in
the manifest; production model and KV objects can be much larger. Zig encoding
and verification are allocation-free. The independent Python suite shares the
golden root, flips every one of the 608 serialized byte positions, reseals the
outer digest where applicable, and requires rejection. A separately valid
foreign KV object also rejects.

This proves deterministic identity composition for the fixture. Later fixtures
exercise durable payload storage and a model-free live process restart, but the
capsule alone does not grant either property. No reduced RSS, storage savings,
or recovery after power loss follows from this identity proof.

The resolver fixture then admits all nine objects under a 16-entry catalog-scan
limit, 64-byte per-object limit, exact 264-byte total limit, and nine-resolution
limit. It rejects stale, denied, repeated, cross-tenant, corrupt, ambiguous,
oversized, over-budget, overlapping, substituted, and post-resolution-mutated
inputs in native tests; an independent Python model checks the portable
identity and state semantics. This is conformance evidence for bounded lookup,
not a storage, RSS, latency, deduplication, or restart-performance result.

The bundle fixture describes 280 logical payload bytes as eight unique blobs
totalling 255 bytes, so its canonical duplicate-payload delta is 25 bytes. The
bundle wire itself is 1,136 bytes, the capsule remains an external 608 bytes,
and the demo performs no storage writes. This proves the fixture's deterministic
tenant-scoped plan and totals—not net disk savings, cache savings, lower RSS, or
restore performance. Physical claims require a real store and complete overhead
measurement.

The in-memory store fixture imports nine semantic references into eight payload
allocations: 280 naive per-reference payload bytes become 255 allocated payload
bytes. It also uses a 1,024-byte logical index charge, a 3,200-byte fixed slot
array and 3,480-byte store value on the current 64-bit build, inside a
4,096-byte caller-provided payload backing buffer. Lifecycle metadata increased
the fixed slot array from the earlier 2,304 bytes; receipt-root compaction avoids
1,152 bytes versus the initial expanded layout. This proves one 25-byte
duplicate payload allocation is avoided, atomic rollback works, and counters
are exact. It does not establish net memory savings; the fixture's lifecycle,
index, and backing overhead is larger than its duplicate payload.

The same demo acquires and renews a model-object lease from generation 1 to 2,
releases it with the exact current receipt, then acquires a KV-object lease that
quarantine invalidates. A target/reason/source-scoped repair grant admits the
verified KV payload and produces a shared Zig/Python repair receipt and v2
snapshot. These are deterministic conformance results—not wall-clock lease
safety, replica attestation, crash durability, or repair-latency measurements.

The collection fixture presents all eight remaining semantic roots and the one
current lease receipt against an exact audit snapshot. Across eight occupied
entries it classifies five entries/five references as reachable, one entry/two
references as leased, one entry/one reference as quarantined, and one retired
30-byte entry as collectible. The store retains all 255 payload bytes and frees
zero. Zig and the independent Python model share the grant, input, snapshot,
and plan roots. This proves bounded dry-run classification for the fixture—not
safe deletion, lower RSS, durable sweep recovery, or global reachability across
stores.

The sweep fixture separately authorizes that plan, regenerates it from the same
eight roots and one lease receipt, stages one entry/30 bytes, and aborts while
the store remains at the exact audit snapshot. Its caller-owned journal is 184
bytes on the current 64-bit build, performs zero sweep heap allocations, and
does not enlarge the 3,480-byte store value. All 255 payload bytes remain
allocated and zero bytes are freed. Zig and Python share the sweep grant,
prepare, and abort roots. This is functional in-memory staging evidence—not a
destructive commit, durable journal, exactly-once transition, secure erase, or
memory reduction.

The sweep-commit fixture uses a separate prepared plan whose one collectible
object is the final 39-byte payload allocation. A second capability binds the
exact sweep grant, prepare root, snapshot, plan, and removal ceilings. Native
commit changes the store from 8 to 7 occupied entries, 1 to 0 retired entries,
255 to 216 payload-ledger bytes, and 1,024 to 896 logical-index bytes. It invokes
the allocator deallocation once. Because the target is deliberately the
fixed-buffer allocator tail, observed allocator consumption also changes from
255 to 216 bytes. The 3,480-byte fixed store value and 184-byte caller-owned
journal remain unchanged.

Zig and Python share the commit grant, target-set, store-commit, outer-commit,
and post-state roots. This proves exact atomic single-owner in-memory removal
for the fixture. The 39-byte allocator delta is a tail-layout observation—not a
general allocator, fragmentation, RSS, secure-erasure, durability, or garbage-
collection throughput result.

The sweep-record fixture encodes that transition evidence as a fixed 736-byte
body and 48-byte commit footer. Zig and Python share the record root
`a9adfd09…bba06` and complete-wire SHA-256 `3b3fb1ad…d7c6d3`. Both reject every
one-byte mutation across 784 positions, every truncation, an extension, a
correctly rehashed accounting contradiction, and a valid foreign record under a
pinned expectation. This proves the codec and semantic verifier for the named
fixture. It is not a filesystem throughput, sync latency, crash recovery, or
durability result; the append plan performs no I/O.

The anchored classifier then scans a two-record 1,568-byte stream with shared
Zig/Python SHA-256 `25009ee1…ee5538`. Both implementations classify all 785
possible second-record append lengths, reject a mutation at every second-record
byte, reject rehashed semantic contradictions and valid foreign chains, and
verify an authenticated suffix anchor. Native classification allocates no heap
memory and returns only committed-prefix metadata; this is not evidence of file
repair, sync behavior, restart correctness, or storage performance.

The writer fixture binds the first record to exclusive storage epoch 41 and
lease generation 1. Zig and Python share snapshot SHA-256
`b02d101a…ee3897`, then append the second record through body-write, body-sync,
footer-write, and footer-sync. The fault campaigns cover all eight before/after
I/O outcomes, all 737 body prefixes, all 49 footer prefixes, every incomplete
tail from 1 through 783 bytes, and both crash lengths around an uncertain
truncate. Append and repair capabilities expose disjoint operations, and every
uncertain error poisons the local state until fresh lease/snapshot reopen. This
is allocation-free deterministic storage-model evidence—not proof of real lock,
filesystem sync, directory durability, process restart, or storage performance.

The file-adapter demo adds retained host-filesystem evidence for four append
process deaths and two repair process deaths. It verifies exclusive advisory
locking, no-follow final lookup, one-link/private-mode admission, file and
directory sync, identity checks, replacement detection, and fresh-descriptor
reopen. The independent Python adapter repeats those child deaths and
cross-process lock contention. These are correctness fixtures, not throughput
benchmarks. They do not emulate device power loss, establish native Linux
behavior, or justify filesystem latency, energy, RSS, or durability claims
beyond the recorded host run.

The sweep-commit demo separately encodes its actual native store receipts into
the same 784-byte format and verifies record root `6f60f970…c7fa52`. Version 2
first predicts that exact receipt without mutation, publishes and syncs it
through the POSIX adapter, injects a failure before deallocation, then recovers
against the old snapshot, proves a second recovery is already applied, and
rejects a valid third store state. This specific commit fixture keeps payloads
and lifecycle metadata in memory, so it proves ordering and reconciliation, not
process-death mutation or power-loss behavior.

The payload-file demo then exercises the downstream durable byte plane. Its
three-entry canonical snapshot contains 55 logical payload bytes; one exact
13-byte target is removed into a two-entry, 42-byte successor. A fixed 968-byte
record binds the published sweep root, exact target list, old/new snapshot roots
and lengths, accounting, preview root, and challenge. Native workers terminate
after seven plan and promotion boundaries. Fresh recovery observes the old
snapshot in five cases and the already-promoted new snapshot in two, then a
second recovery is always `already_applied`. Zig and independent Python
implementations share sweep-record SHA-256
`871e9f22…a2a7cc977` and reclaim-record SHA-256
`f1105b70…35f926de34`; Python also rejects mutation of every reclaim-record
byte and a valid unrelated third snapshot.

The ownership fixture then consumes a capsule-bound 3,360-byte resource-state
plan. It requires a fresh target Bank epoch, charges two allocation nodes before
private materialization, keeps both nodes pending after a wrong-byte attempt,
commits exact bytes to `live`, acquires the restored publication sequence, and
rejects same-Bank replay plus the old source receipt. Zig and Python share
ownership root `59c777c9…fe68f394f` and reject mutation of every serialized
position plus a re-rooted semantic contradiction.

The paged-KV fixture adds two layers, dimension two, and 17 committed positions
across two real page allocations. It reconstructs the complete source
ownership chain from durable page images, restores the same logical KV
SHA-256 into a fresh cache instance, emits new target page generations, and
rejects source refs in the target. A changed source generation leaves a probe
cache fresh and publication remains blocked while ownership is pending. The
shared 752-byte codec fixture has root `e052306f…3437d1e4` and mutation-complete
Zig/Python coverage.

The live-restart fixture then joins the exact sequence, KV length/digest, RNG,
sampler count, output prefix, previous commit, and challenge in one fixed
304-byte runtime wire. A source process publishes token `503`, synchronizes six
checkpoint objects plus its process identity, releases its LeaseTree and Bank,
then exits. A different target process verifies and restores the checkpoint,
forces a target cache instance distinct from the source, publishes token `504`
at sequence `18`, observes output `[501, 502, 503, 504]`, chains the source
commit, and tears down to zero Bank usage. The runtime wire, output root, and
receipt root have independent Python fixtures with complete wire mutation and
stale-position rejection.

The checkpoint-file fixture packages seven real restart objects into one
6,421-byte archive in the observed run, then selects it with a fixed 192-byte
record. Workers die after archive write, archive sync, archive directory sync,
selector write, selector sync, selector rename, and selector directory sync.
Fresh recovery observes the previous root in five cases and the successor root
in two, reaches the successor idempotently, and launches a separate live-resume
process after every phase. The independent Python codec shares fixed two-object
archive/selector roots and rejects every serialized-byte mutation, re-rooted
semantic contradictions, and foreign recovery roots.

Together these fixtures prove canonical payload-byte encoding, exact target
reconstruction, copy-on-write ordering, fresh-process old/new reconciliation,
safe logical ownership reacquisition, model-free paged-KV reconstruction, and
one natural-exit process restart with exact-once next-token publication, and an
atomic whole-checkpoint root switch across seven process-death phases on the
retained host. They do not restore object-store lifecycle metadata, compare an
uninterrupted and resumed production model, restore accelerator allocations,
emulate device power loss, establish native Linux filesystem behavior, or
measure disk use, latency, RSS, or energy.

## Provider evidence checkpoint

The current provider fixture joins three independently replayed planes:

- one 1,645-byte committed cost-journal frame;
- one 5,984-byte gateway event stream;
- one 2,758-byte transport event stream;
- one fixed 712-byte `ProviderEvidenceJoinWire` manifest.

The manifest binds 20 digest fields representing the envelope and 19 semantic
roots. It does not copy the nested evidence. The Zig verifier replays each nested
format and the independent Python verifier checks the shared golden fixture. The
mutation suite rejects a single-byte change at every one of the 712 manifest byte
positions and rejects substitution of a valid but foreign transport stream.

This proves composition for the retained fixture. It does not prove the truth of
a provider's upstream usage report or grant filesystem/network authority.

The durable journal harness exercises process termination across append phases,
including 12 child-process kill cases. It checks body sync, footer sync, torn-tail
repair, poison/reopen behavior, advisory locking, path rejection, and replay.
Filesystem guarantees still need validation on each promoted platform.

## Context-efficiency checkpoint

The deterministic context fixture maps 440 logical tokens to 250 emitted tokens
and changes a conservative reservation from 490 to 300. The adapter fixture uses
one wiped 64-byte execution buffer where its comparison oracle uses two buffers
totalling 128 bytes.

These numbers are deliberately narrow:

- only exact rendered duplicates declared idempotent may share an emitted span;
- core stores hashes, mappings, and counts rather than prompt text;
- an external observer counts the exact rendered provider wire;
- the 64-byte result is a scratch-fixture property, not a general memory claim;
- logical and reserved-token reductions are not guaranteed billed-token savings.

## Measurement contract

### Identity

Retain:

- source commit and dirty-tree state;
- compiler, optimization mode, target, and feature flags;
- model/tokenizer hashes and runtime format identity;
- prompt or token fixture hash, seed, token count, and execution policy;
- benchmark harness version and schema.

### Machine envelope

Capture at minimum:

- hardware model, architecture, logical CPU count, and memory capacity;
- operating-system and kernel versions;
- power-source state when available;
- process priority, affinity policy, and requested worker count;
- load and memory state before each pair;
- warmup, cooldown, and execution timestamps;
- availability or absence of thermal, frequency, core-residency, and energy data.

The current envelope does not directly measure CPU temperature, effective
frequency, performance/efficiency-core residency, or package energy on every
host. “Plugged in” is useful context, not proof of equal machine state.

### Paired execution

Use randomized or balanced order within the same process and machine session:

```text
A B B A   or   B A A B
```

Each observation must name its pair and order. Reject a pair when cooldown, load,
correctness, configuration, or requested machine-state gates fail. Do not delete
valid slow samples because they are inconvenient.

### Metrics

For latency and throughput, retain per-sample values and report median, tail
quantiles, effect size, and uncertainty. Separate time-to-first-token, inter-token
latency, prefill, decode, and end-to-end latency.

For resources, label the evidence source:

- logical runtime ledger;
- allocator-observed bytes;
- process RSS or peak RSS;
- mapped/virtual bytes;
- device allocation or residency;
- energy/thermal sensor.

Never substitute one source for another in the claim.

### Correctness and quality

Performance pairs are invalid if the compared paths do not satisfy their declared
output contract. Depending on the experiment, use byte-identical tokens, bounded
numerical error, perplexity, task quality, or an explicitly different sampling
contract. Record the chosen gate before running the campaign.

## Reproduction

Core verification:

```sh
zig build test -Doptimize=Debug -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false
zig build test -Doptimize=ReleaseFast -Dmetal=false
python3 -m unittest discover -s bench/tests
```

Concurrency and portability gates:

```sh
zig build test -Doptimize=ReleaseSafe -Dmetal=false -Dsanitize-thread=true
zig build test-compile -Dtarget=x86_64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=aarch64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
```

Benchmark harnesses under `bench/` have their own `--help`, configuration, and
schema checks. Start with a tiny smoke run, inspect the artifact, then schedule a
campaign. Never publish only terminal output.

## Stop rules

Stop or redesign an experiment when:

- correctness or quality fails;
- the claimed resource is not directly observed;
- machine-state gates repeatedly fail;
- the effect disappears under paired order;
- overhead exceeds the declared budget;
- a representation adds complexity without a plausible end-to-end path;
- retained artifacts cannot be independently parsed.

Negative results are useful project evidence. Record the configuration and stop
reason in the relevant design document instead of hiding the result.
