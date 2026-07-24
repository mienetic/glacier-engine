# Atomic Generated-Media Checkpoints

Status: **integrated model-free composition path; production model adapters,
encoded payload archives, device evidence, and power-loss campaigns remain
gated**.

Glacier can seal one completed generated image, one acknowledged generated-audio
chunk, and one acknowledged generated-video segment behind a single atomic
selector. A reader observes either the complete previous generation or the
complete successor generation. It never accepts a set assembled from different
generations, tenants, policies, challenges, results, or completion receipts.

This layer composes already validated output transactions. It does not generate
media, encode an external file, grant file or device authority, or turn an
application acknowledgement into proof of physical playback or display.

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

The next production-facing slices are:

1. bind exact encoded image, audio, and video payload archives to each member;
2. adapt production decoders, renderers, codecs, and model outputs without
   weakening the typed admission boundary;
3. add multi-image, multi-chunk audio, and multi-segment video continuity;
4. retain native Linux filesystem campaigns and separately scoped power-loss
   evidence;
5. add authorized physical playback/display evidence outside the
   authority-free core; and
6. measure quality, latency, throughput, memory, energy, and durability under
   declared artifacts and numerical modes.

See [Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
