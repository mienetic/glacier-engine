# Atomic Generated-Media Checkpoints

Status: **integrated model-free composition path; exact encoded-payload archive
composition and bounded multi-output registry continuity are integrated
downstream, while production adapters, external formats, device evidence, and
power-loss campaigns remain gated**.

Glacier can seal one completed generated image, one acknowledged generated-audio
chunk, and one acknowledged generated-video segment behind a single atomic
selector. A reader observes either the complete previous generation or the
complete successor generation. It never accepts a set assembled from different
generations, tenants, policies, challenges, results, or completion receipts.

This layer composes already validated output transactions. It does not generate
media, encode an external file, grant file or device authority, or turn an
application acknowledgement into proof of physical playback or display.
The downstream
[Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md)
binds this checkpoint, its members, and exact encoded image/audio/video bytes
without changing the checkpoint's raw-output semantics.
The later
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md)
uses an independent ABI to compose multiple structurally described outputs and
payloads without changing this V1 checkpoint or selector wire. The
[Canonical Generated-Media Producer Admission](GENERATED_MEDIA_PRODUCER_ADMISSION.md)
gateway now validates the retained typed producer records and exact raw output
bytes before their derived fields enter that unchanged registry.

## Portable records

`src/core/generated_media_checkpoint.zig` defines three canonical
little-endian records:

| Record | Wire size | Purpose |
| --- | ---: | --- |
| `GeneratedMediaMemberV1` | 480 bytes | Normalizes one typed image, audio, or video completion into a common modality member |
| `GeneratedMediaCheckpointV1` | 800 bytes | Cross-binds exactly three members, their outputs/results/states/completions, exact totals, continuity, scope, policy, challenge, and predecessor |
| `GeneratedMediaSelectorV1` | 352 bytes | Selects one complete checkpoint generation and chains the previous selector/checkpoint |

Every record has a fixed magic, ABI, body length, zero reserved bytes, and a
domain-separated SHA-256 root. The Zig fixture and an independent Python model
share golden roots and reject every serialized-byte mutation.

## Typed member admission

The common member wire is produced only from the corresponding typed output
records:

- image admission verifies the generated-image plan, provenance, result,
  terminal-state lineage, decoder identity, output, media object, scope, policy,
  and challenge;
- audio admission verifies the generated-audio plan, provenance, result,
  quiescent post-acknowledgement state, and exact playback acknowledgement; and
- video admission verifies the generated-video manifest, provenance, result,
  quiescent post-acknowledgement state, and exact display acknowledgement.

Image publication is already complete at its atomic commit, so its normalized
member does not require a second acknowledgement. Audio and video members are
admissible only after complete application acknowledgement and after their
pending-output gates have returned to quiescent state.

## Checkpoint invariants

One checkpoint contains exactly one image member, one audio member, and one
video member. Validation reconstructs rather than trusts:

- request epoch, tenant scope, metadata policy, and challenge equality;
- member modality and generation/ordinal mapping;
- exact per-modality and aggregate bytes and logical units;
- exact result, output, state, media, provenance, and completion roots;
- image index, audio frame, video frame, and video timeline continuity; and
- previous-checkpoint lineage for every successor.

Substituting a canonical member from another generation or tenant still fails.
Rehashing a contradictory checkpoint or selector does not make it admissible.

## Durable selection protocol

The filesystem proof uses immutable member and checkpoint objects plus one
replaceable selector:

1. write and sync all three member objects;
2. write and sync the complete checkpoint object;
3. sync the containing directory;
4. write and sync a selector candidate;
5. atomically rename the candidate over the active selector; and
6. sync the containing directory again.

Recovery validates the active selector first, then its checkpoint and all three
members, including predecessor chains. The selector is the visibility boundary;
an unselected successor checkpoint is not visible runtime state.

The retained native campaign terminates the promoting process after selector
write, file sync, rename, and directory sync. Recovery returns generation one
for the first two boundaries and generation two for the latter two. All four
recoveries run in a different process and report no mixed generation.

This campaign proves process-death behavior on the retained host filesystem. It
does not emulate device power loss.

## Verification

```sh
zig test src/core/generated_media_checkpoint.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_media_checkpoint
zig build generated-media-checkpoint-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The restart demo emits machine-readable evidence for two checkpoint
generations, four process-death boundaries, two previous-generation recoveries,
two successor-generation recoveries, and zero mixed-generation observations.

## Promotion path

The first downstream composition slice is complete: one fixed manifest, this
checkpoint, its three members, and three exact encoded payloads now form a
canonical eight-object generation behind one outer filesystem selector. It
keeps raw-output, encoded-payload, encoder-implementation, and format identities
separate, verifies two-generation lineage independently in Python, and accepts
only the exact previous or successor archive across seven process-death phases.

The next composition slice is also complete under an independent ABI: fixed
544-byte entries order one to four outputs per present modality, up to twelve,
while one fixed manifest and exact concatenated payload pack produce exactly
three archive extension objects under the existing outer selector. The
registry structurally requires image entries with no completion receipt and
audio/video entries with a completed flag plus nonzero opaque completion root.
The registry itself does not decode this checkpoint's typed producer records;
the separate producer-admission gateway now enforces that pre-publication
validation.

The next production-facing slices are:

1. adapt production decoders, encoders, renderers, codecs, containers, and
   model outputs without weakening the typed admission boundary;
2. add external-format conformance fixtures for those production adapters;
3. retain native Linux filesystem campaigns and separately scoped
   initial-publication and power-loss evidence;
4. add authorized physical playback/display evidence outside the
   authority-free core; and
5. measure quality, latency, throughput, memory, energy, and durability under
   declared artifacts and numerical modes.

See [Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md),
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
