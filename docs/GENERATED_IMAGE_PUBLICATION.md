# Generated-Image Publication

Status: **integrated deterministic runtime fixture; production decoder and
image-quality evidence gated**.

Glacier can now take a terminal retained latent produced after a real process
restart, decode it into a bounded caller-owned image, and publish the image,
provenance, typed result, resource receipt, and media timeline transition as one
logical visibility boundary.

This is the first complete generative-media output vertical in the Glacier AI
Runtime. It proves lifecycle and evidence semantics. It does not claim useful
image quality, production diffusion/flow execution, accelerator performance,
external image-container encoding, or durable multi-file publication.

## What is bound

The generated-image plan does not accept an arbitrary byte array and label it
as a model result. Its fixed identity joins:

- the artifact manifest and terminal model plan/result;
- the intermediate stateful checkpoint restored under a fresh
  `ResourceBank`;
- the terminal state publication and exact terminal-latent digest;
- decoder ABI, implementation, payload, and zero ambient capabilities;
- tenant scope, metadata policy, source provenance, and output `MediaObject`;
- prior generated-image plan/result roots; and
- the exact media publication sequence and visible-image count.

A separately rehashed plan that substitutes a terminal output, state, artifact,
decoder, media object, tenant, or lineage remains structurally valid but fails
the complete binding check before resource admission.

## Portable records

Three pointer-free little-endian records make the transaction independently
verifiable:

| Record | Size | Purpose |
| --- | ---: | --- |
| `GeneratedImagePlanV1` | 736 bytes | Seals source lineage, decoder, bounds, media identity, publication position, and predecessors |
| `GeneratedImageProvenanceV1` | 640 bytes | Joins decoded content to the artifact, terminal latent/result/state, decoder, tenant, and policy |
| `GeneratedImageResultV1` | 704 bytes | Joins plan and provenance to resource, timeline, media commit, and before/after publication roots |

Reserved bytes are zero and every serialized byte is covered by a
domain-separated root. Zig and the independent Python oracle reconstruct the
same golden roots and reject mutation of every wire byte.

The retained fixture is deliberately small: terminal latent
`[6, 12, 18, 24]` plus decoder weights `[4, 3, 2, 1]` produce one 2×2
linear-gray image with pixels `[24, 36, 36, 24]`. The runtime accepts raw
interleaved unsigned-byte images with checked geometry, dimensions no larger
than 8,192, and no more than 16 MiB of latent or pixel data in this ABI.

## Atomic publication

The session follows one bounded lifecycle:

```text
verify terminal lineage and current media state
                 │
                 ▼
admit the exact ResourceBank claim
                 │
                 ▼
decode into private caller-owned output
                 │
                 ▼
revalidate pixels + build media/provenance/result candidates
                 │
                 ▼
prepare the exact timeline/publication successor
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
     abort               commit
scrub candidates    revalidate all inputs
keep visible state  copy output/provenance/result
unchanged           advance visibility once
```

Candidate and visible buffers must be disjoint from each other and from every
immutable input. Before commit, visible output, provenance, result, and
publication state remain byte-for-byte unchanged. Abort and candidate drift
scrub provisional buffers. The commit path revalidates the full source
lineage, exact latent, decoder output, candidate hashes, resource permit, and
publication predecessor before its infallible visibility suffix.

Closing the session releases the exact claim. The native proof finishes with
zero Bank bytes, zero live allocations, and zero active lease trees.

## Process-restart proof

The source process executes the first retained-state step, syncs its checkpoint
artifacts, releases ownership, and exits. A target process with a different PID:

1. restores the intermediate state under the required fresh Bank epoch;
2. charges ownership before materializing the retained bytes;
3. executes and commits the terminal latent step;
4. releases the restored latent ownership;
5. prepares then aborts one image publication, proving visibility is unchanged;
6. retries and commits the exact image, provenance, and result once; and
7. releases all target resources.

Run the retained evidence:

```sh
zig test src/core/generated_image_publication.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_image_publication
zig build generated-image-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The portable core has no filesystem, network, provider, device, accelerator,
display, or clock authority. Filesystem authority exists only in the bounded
native demonstration to cross a real process boundary and sync its fixture
files.

## Promotion path

The next image-generation slices are:

1. a production decoder adapter with explicit numerical and device policy;
2. multi-step scheduler continuation and cancellation at declared latent
   boundaries;
3. multi-image and chunk-manifest publication under retained ownership;
4. external image format encoding outside the authority-free core;
5. crash-atomic composition of encoded bytes, provenance, and result records;
6. quality, memory, energy, and latency evidence on named artifacts and
   platforms.

Generated audio and video now reuse these principles in their own bounded
publication contracts with timeline continuity, cancellation, and application
playback/display acknowledgement. Shared checkpoint composition is integrated:
one typed image completion plus acknowledged audio/video outputs now become
visible through one atomic selector. Production adapters, durable encoded
payload archives, and multi-output continuity remain.

See [Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md),
[Shared Media Contract](MEDIA_CONTRACT.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
