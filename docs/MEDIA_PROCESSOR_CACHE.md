# Materialized Multimodal Processor Caches

Glacier can now carry exact image, audio, and video processor-cache bytes
through an atomic checkpoint and reacquire their resource ownership in a fresh
process before those bytes become runtime-visible.

This layer composes the fixed processor-state bundle, immutable checkpoint
archive, `ResourceBank`, and `LeaseTree`. It does not treat a digest or logical
byte count as proof that memory was charged.

## Six-object checkpoint

The materialized media checkpoint contains:

1. the image stream checkpoint;
2. the audio stream checkpoint;
3. the video stream checkpoint;
4. the retained-output bundle;
5. the processor-state and synchronization bundle; and
6. the processor-cache payload bundle.

Four-object stream-only and five-object logical-state archives retain strict
readers. `decodeCompatibleSetV1` can recover streams from any of the three
shapes, while `decodeMaterializedSetV1` requires and verifies all six objects.
This prevents a caller that needs cache restart from silently accepting an
archive that contains only logical state.

## Canonical cache bundle

The variable-length cache bundle has:

```text
header (256 bytes)
  generation, request, challenge, processor and sync roots
  previous cache-bundle root
  source and target Bank epochs
  target owner/tree/authority bases, tenant and publication sequence
  exact aggregate cache bytes

directory (3 × 64 bytes)
  media kind, canonical payload offset, exact length and SHA-256

image, audio and video cache bytes
domain-separated SHA-256 footer
```

Entries are always image, audio, then video. Payload offsets are contiguous,
unused fields are zero, and the footer covers the complete header, directory,
and payload. The cache root in every directory entry must equal the matching
`ProcessorStateV1.cache_content_sha256`, while its length must equal
`ProcessorStateV1.cache_bytes`.

The generation predecessor is explicit. A successor binds the exact prior
cache-bundle root, uses the prior target Bank as its source Bank, and declares a
different target Bank. Rehashing a stale or foreign payload does not satisfy
the processor-state binding.

## Restore-before-visible ownership

`RestoreSession.prepareV1` requires a fresh Bank at the exact target epoch. It
creates one generation-fenced receipt, tree, scope, and allocation per modality.
Each allocation charges its exact cache size as `activation_bytes` and remains
`reserved_unmaterialized`.

`commitMaterializedV1` first verifies all three caller-owned payloads byte for
byte and by SHA-256. Only then does it commit the allocation batches to `live`.
A failed payload check leaves all charges reserved and retryable. Closing the
session retires each scope, authorizes the exact free transition, closes every
tree and receipt, and returns the Bank to zero.

The fresh-process checkpoint campaign proves:

- generation two restores `1,104` cache bytes before visibility;
- image, audio, and video use three independently fenced allocations;
- the restored process advances all processor states and cache roots;
- generation three atomically publishes `1,288` cache bytes;
- another fresh process restores generation three; and
- every cache Bank ends with zero usage, live allocations, and active trees.

## Run the proofs

```sh
zig test src/core/media_processor_cache.zig -OReleaseSafe
python3 -m pytest -q bench/tests/test_media_processor_cache.py
python3 -m pytest -q bench/tests/test_media_stream_checkpoint_set.py
zig build media-stream-checkpoint-set-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Zig and Python share the generation-one cache-bundle root
`b11ac37dd0125a6086a44dce9c0e394fcfa5435715cc21b4ed5182cb74e7528c`.
The decoders reject mutation of every serialized byte. Independent tests also
reject payload substitution, processor substitution, stale cache lineage, and
archive-shape downgrade.

## Deliberate limits

The retained payloads are deterministic caller-owned fixtures. Exact
`activation_bytes` accounting is not measured RSS, accelerator residency,
allocator fragmentation, cache quality, or processor throughput. The runtime
now executes only tiny exact-integer vision, audio, and temporal-video
fixtures; it does not execute a production perception model, external codec,
camera, microphone, or production generated-media pipeline. A separate bounded
generated-image transaction consumes the exact terminal latent without turning
these input caches into output authority.

Audio-window and temporal-video encoders now reuse these durable input, state,
cache, and typed publication contracts while preserving the same cancellation
and release rules.
