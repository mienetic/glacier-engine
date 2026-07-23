# Multimodal Processor and Cache State

Glacier now has a fixed, model-free state contract for the processor state that
sits between decoded media and a future model adapter. It covers image
tile/patch progress, audio feature windows, video temporal caches, and one exact
audio/video synchronization watermark without placing codec or model behavior
inside the runtime core.

This is a state and verification layer. It does not claim production image
normalization, spectrogram computation, video embedding execution, or device
residency.

## Fixed records

Each modality uses a 512-byte `ProcessorStateV1`:

```text
common header and progress counters
eight modality-specific u64 parameters
media-object and processor-plan roots
previous-state and challenge roots
cache-content and output-chain roots
ownership-receipt and decoder-state roots
reserved zero bytes
SHA-256 footer
```

The common fields bind request, generation, stream, rational time base,
consumed input units, produced units, cache entries, and exact logical cache
bytes. Generation one has a zero predecessor. Every later generation must bind
the exact prior state root.

The synchronized state is another fixed 512-byte record. It binds the three
processor roots, request and generation, master tick rate, maximum permitted
skew, audio and video end ticks, committed watermark, image progress barrier,
sync policy, ownership set, output set, challenge, and predecessor.

A canonical 2,272-byte bundle contains:

1. a 192-byte header with the four state roots;
2. the image processor state;
3. the audio feature-window state;
4. the video temporal-cache state;
5. the synchronized state; and
6. a domain-separated bundle footer.

The order is fixed. Reserved bytes must be zero. The Zig decoder and independent
Python decoder reject a mutation to every serialized byte.

The bundle is also the fifth object in the stateful atomic media checkpoint
archive. Its three processor records are cross-bound to the matching stream
checkpoints through media, output-chain, and retained-ownership roots. The
stateful successor validator advances stream and processor lineage together.
The materialized archive adds a sixth cache-payload object whose exact bytes,
lengths, and roots must match these records.

## Image processor progress

The retained fixture records processed and total tiles, tile geometry, patch
geometry, channels, normalized elements, cache entries, and exact logical
cache bytes. The fixture represents each normalized element with two bytes.

The successor must process exactly one additional tile. Media identity,
processor plan, geometry, decoder state, request, stream, challenge, and total
tile count remain stable. Cache, output-chain, and ownership roots must advance.

## Audio feature windows

The retained fixture records:

- 48,000 source samples per second;
- one channel;
- a 400-sample window;
- a 160-sample hop;
- 240 samples of carried context;
- 80 feature bins;
- two bytes per feature value; and
- cumulative feature-frame and logical cache accounting.

For `N` produced feature frames, the exact source cursor is
`window + (N - 1) × hop`. Logical cache bytes equal the feature values plus the
carried PCM context. A successor advances exactly one feature frame and one
hop. Skipped windows reject even when every enclosing hash is recomputed.

## Video temporal cache

The retained fixture uses a two-entry temporal window and 128 logical bytes per
entry. State binds window start/end, last keyframe, cache generation, eviction
count, entries, bytes, and consumed frame cursor.

Each successor advances the end by one frame. Once capacity is exceeded, the
start and eviction count advance to `end - capacity`. A last keyframe must stay
inside the live window.

## Exact synchronization

Audio and video positions map to a 48,000-tick master clock using checked
integer arithmetic:

```text
ticks = units × time_base_numerator × master_ticks_per_second
        / time_base_denominator
```

The division must be exact. The committed watermark is the smaller of the audio
and video end ticks, and their absolute difference must not exceed the declared
maximum skew. Image progress is a generation-scoped barrier rather than a
fabricated media timestamp.

The generation-two fixture proves:

- audio end tick `560`;
- video end tick `800`;
- synchronized watermark `560`; and
- skew `240` under a maximum of `400`.

## Run the proofs

```sh
zig test src/core/media_processor_state.zig -OReleaseSafe
python3 -m pytest -q bench/tests/test_media_processor_state.py
zig build media-processor-state-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Zig and Python share the generation-two bundle root
`51a723cbb2919db803a865eb971d080e4a66df8f791ea4d50be35de7192c8609`.
Both reject processor substitution, stale predecessor roots, ownership/cache
replay, skipped audio windows, non-integral time mapping, and byte mutation.

## Deliberate limits

The roots bind declared fixture state; they are not proof that a particular
codec, processor, model, allocator, or accelerator executed. The crash-atomic
archive now preserves logical processor state and exact caller-owned cache
payloads across a fresh process. Each cache is charged through
`ResourceBank`/`LeaseTree` before visibility and released to zero. This still
does not prove measured process memory, allocator behavior, or device
residency.

Typed vision, audio, transcript, temporal-video, bounded video-segment, and
exact audio/video result-link adapters now consume these contracts. The next
state milestone carries video-model temporal state across a fresh process while
preserving the same cache, timeline, publication, and cross-modal predecessor
lineage. Transcript-model continuation now meets that gate for the retained
exact-integer fixture.
