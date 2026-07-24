# Generated-Media Encoded Payload Archive

Status: **integrated model-free archive and process-death recovery path;
bounded multi-output continuity is integrated under a separate ABI; production
encoders/containers, retained native Linux campaigns, and power-loss durability
remain gated**.

Glacier can now package one generated image, one acknowledged generated-audio
chunk, and one acknowledged generated-video segment together with their exact
encoded bytes in one canonical archive. The archive reconnects application-ready
payloads to the typed result, raw source output, encoder implementation, format,
tenant, policy, challenge, and generation that produced them.

This closes the model-free encoded-byte composition slice. It does not execute a
model, run a production encoder, interpret an external container, grant device
or filesystem authority to the portable core, or prove physical playback,
display, quality, performance, or power-loss behavior.

The downstream
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md)
extends the retained generation to multiple images, audio chunks, and video
segments under an independent ABI. This V1 manifest, checkpoint, members, and
eight-object archive remain byte-for-byte unchanged.

## One eight-object generation

`src/core/generated_media_payload_archive.zig` encodes exactly eight objects in
the existing immutable checkpoint archive:

| Ordinal | Object | Canonical content |
| ---: | --- | --- |
| 1 | Payload manifest | Fixed 864-byte binding over all typed and encoded identities |
| 2 | Generated-media checkpoint | Fixed 800-byte three-modality checkpoint |
| 3 | Image member | Fixed 480-byte completed-image member |
| 4 | Audio member | Fixed 480-byte acknowledged-audio member |
| 5 | Video member | Fixed 480-byte acknowledged-video member |
| 6 | Image payload | Exact encoded image bytes under their declared ABI |
| 7 | Audio payload | Exact encoded audio bytes under their declared ABI |
| 8 | Video payload | Exact encoded video bytes under their declared ABI |

The three payload objects are distinct even when a higher-level application
stores or transports them together. Each object keeps its exact length and
encoding ABI, so a modality swap, truncation, appended byte, or ABI substitution
fails before the generation is accepted.

## Identity and binding rules

The payload manifest keeps source and encoded identities separate:

- each member retains the digest and byte count of the canonical raw pixels,
  PCM, or frame bytes produced by the typed output transaction;
- each encoded-payload root binds modality, encoding ABI, exact length, and
  exact encoded bytes;
- separate roots identify the encoder implementation and external format
  contract used for each modality;
- the manifest binds the generated-media checkpoint and all three normalized
  member roots;
- request epoch, generation, publication sequence, tenant scope, metadata
  policy, and challenge must agree with the checkpoint; and
- a successor binds both the preceding manifest root and the preceding archive
  root.

The checkpoint totals continue to describe the canonical raw source outputs.
Encoded byte counts live in the payload manifest. This prevents compressed or
containerized length from silently changing the meaning of the typed output
checkpoint.

Validation reconstructs these relations from the eight archive objects. Merely
rehashing a contradictory manifest, checkpoint, member, payload, or predecessor
does not make the archive admissible.

## One filesystem authority

The immutable eight-object archive is the generation. The existing
checkpoint-file selector is the only replaceable filesystem visibility record;
there is no nested generated-media selector controlling a second publication
boundary.

Promotion follows seven observed phases:

1. write the successor archive;
2. sync the successor archive;
3. sync the archive directory entry;
4. write the selector candidate;
5. sync the selector candidate;
6. rename the selector candidate over the active selector; and
7. sync the selector directory entry.

A reader validates the selected archive, manifest, checkpoint, three members,
three exact payloads, and both predecessor bindings before accepting the
generation. Recovery can then converge idempotently to the prepared successor.

## Retained process-death evidence

The native model-free campaign publishes two generations and terminates the
publisher with `SIGKILL` once after each phase. Reopening selects:

- the exact previous generation after the first five deaths; and
- the exact successor generation after the last two deaths.

All seven cases then run recovery twice. The first recovery either applies the
prepared successor or recognizes it as already applied; the second always
recognizes the same successor. No mixed generation is accepted, and the decoded
image, audio, and video payload slices remain byte-exact.

This is host-filesystem process-death evidence. It does **not** emulate storage
device power loss, establish initial archive durability after sudden power
failure, or establish native Linux filesystem behavior.

## Independent verification

Run the smallest retained suite with:

```sh
zig test src/core/generated_media_payload_archive.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_media_payload_archive
zig build generated-media-payload-archive-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The independent Python oracle reconstructs the manifest, the generic
eight-object archive, typed checkpoint/member bindings, exact payload roots, and
two-generation lineage without executing Zig. The retained tests share four
golden roots, reject mutation of every manifest and archive byte, and reject
rehashed split bindings, substituted payloads, mixed members, and corrupt
predecessors.

The restart demo emits machine-readable counts for three modalities, three
encoded payloads, two generations, seven process deaths, five previous
selections, two successor selections, one outer selector, exact payload
recovery, and idempotent convergence.

## Runtime uses

This layer is useful as a foundation for:

- restartable local generation pipelines that need output records and encoded
  deliverables to advance as one generation;
- media job queues that must reject a checkpoint whose image, audio, or video
  file belongs to another request or encoding policy;
- reproducible encoder/container experiments where raw output, encoder
  implementation, format identity, and resulting bytes must remain distinct;
- provider or edge handoff evidence that needs one bounded generated-output
  identity without embedding model weights or private prompts; and
- multi-output adapters that need a stable V1 single-output fixture beside the
  independent bounded registry ABI.

The retained fixture proves the archive contract, not production readiness for
those applications.

## Next slices

Contributor-sized follow-on work includes:

1. production image encoder and audio/video codec/container adapters behind
   explicit capability and numerical policies;
2. external-format conformance fixtures for those adapters;
3. retained process-death campaigns on native Linux filesystems;
4. a separately designed initial-publication and power-loss durability
   protocol; and
5. quality, latency, throughput, memory, energy, and storage evidence under
   named artifacts and platforms.

See [Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md),
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md),
[Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
