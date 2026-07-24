# Canonical Generated-Media Producer Admission

Status: **integrated pre-publication gateway for canonical generated-image,
generated-audio, and generated-video records plus exact raw output bytes;
host-verified deterministic producer-transition evidence is available as a
separate higher-assurance path; production encoders/containers, external-format
conformance, authorization, device evidence, and production quality remain
gated**.

Glacier now provides a typed construction path into the bounded output
registry. The gateway connects modality-specific publication contracts to the
shared multi-output archive: it decodes the existing canonical wires, verifies
their cross-record bindings and exact raw output bytes, derives common request
metadata and predecessor continuity, and constructs the existing registry
input. The registry's lower-level structural construction API remains
independently available.

This is part of Glacier's broader AI Runtime boundary. Model inference is only
one possible source of a candidate. The runtime also needs to decide whether
artifacts, state, resources, scheduling position, output lineage, provider
work, media delivery, and publication evidence are coherent before anything
becomes visible.

The gateway introduces no new selected archive object, selector, or replacement
wire. The generated-media output-registry V1 remains byte-for-byte unchanged.

## Relationship to transition evidence

This admission gateway remains the structural, lower-assurance path. It accepts
canonical retained producer records, verifies exact raw bytes and typed
relations, and reconstructs audio/video acknowledgement state from those
records. It does not execute the source model or materializer.

The separate
[host-verified producer-transition gateway](GENERATED_MEDIA_PRODUCER_TRANSITION.md)
adds exact deterministic source-model and materializer replay. It reconstructs
image publication or complete audio/video observation and acknowledgement
transitions, constructs the same unchanged registry, and emits a distinct
evidence sidecar bound to that archive. Structural admission is not silently
promoted when transition evidence is absent.

The transition path also keeps two image coordinates distinct: every retained
image profile is a fresh one-shot local publication, while the zero-based
registry collection ordinal is derived separately from validated registry
lineage. This does not change the legacy structural normalization documented
below.

## Admitted producer sets

Each output supplies exact existing producer wires, the exact raw output bytes
identified by those wires, and a separate encoded-delivery description.

| Modality | Canonical producer wires | Fixed wire bytes | Raw bytes verified |
| --- | --- | ---: | --- |
| Image | 736-byte plan + 640-byte provenance + 704-byte result | 2,080 | Exact published pixels |
| Audio | 448-byte quiescent post-acknowledgement state + 576-byte plan + 512-byte provenance + 576-byte result + 512-byte playback-acknowledgement result | 2,624 | Exact published PCM |
| Video | 512-byte quiescent post-acknowledgement state + 736-byte manifest + 640-byte provenance + 672-byte result + 512-byte display-acknowledgement result | 3,072 | Exact published frame payload |

The encoded-delivery description keeps `encoding_abi`, exact encoded payload
bytes, encoder-implementation identity, and format identity separate from the
producer decoder or renderer. The gateway rejects empty raw or encoded
payloads, zero delivery identities, malformed canonical wires, contradictory
record sets, and raw byte lengths or digests that do not match the typed
result.

Admission inherits the registry limits: one to four outputs for each present
modality and no more than twelve outputs in one generation. The fixed typed
wire portion is therefore at most 31,104 bytes for a `4/4/4` batch, before the
caller-owned raw and encoded payload bytes.

## Exact normalization

The gateway derives registry fields rather than accepting caller-selected
roots:

- image registry ordinal is the one-based typed `image_index` minus one;
- audio and video registry ordinals are the typed chunk and segment indices;
- producer generation and registry ordinal remain independent; admission does
  not impose the synchronized generation mapping used by the separate fixed
  one-member-per-modality checkpoint ABI;
- source byte count is the published pixel, PCM, or frame-payload length;
- `source_output_sha256` is the digest of the produced raw media, not the
  upstream tensor or renderer-input digest;
- artifact, provenance, result, media-object, and post-publication state roots
  come from the validated typed producer records;
- image requires completed publication with no completion receipt;
- audio and video require completed application acknowledgement and a
  quiescent post-acknowledgement state;
- audio and video pre-publication, pending, observation, acknowledgement-plan,
  acknowledgement-result, and final-state roots are deterministically
  reconstructed and must reproduce the supplied acknowledgement and final
  state exactly; and
- payload, encoder, format, and external encoding ABI remain distinct from the
  raw producer identity.

All outputs in one batch must derive the same request epoch, tenant scope,
metadata policy, and challenge. The generation-plan root is supplied once for
the batch and must be nonzero.

## Typed and registry lineage

The gateway validates two different lifecycles without conflating them.

Producer generation identifies modality-specific publication and
acknowledgement transitions. Registry generation identifies a complete
multi-output archive. The latter is derived as generation one and publication
sequence one for an initial archive, or as the exact preceding registry
generation and publication sequence plus one for a successor.

Within each modality:

- the first registry entry starts at ordinal zero;
- every successor ordinal is exactly the preceding ordinal plus one;
- the typed state-before root equals the preceding admitted state-after root;
- the typed previous-result root equals the preceding admitted result root;
- audio and video also require the previous-completion root to equal the
  preceding acknowledgement-result root; and
- the registry previous-entry root is derived from the preceding canonical
  registry entry, never accepted as caller authority.

For an initial audio or video stream, the typed previous result and completion
roots must be zero. Image publication carries its own upstream publication
predecessor, so the initial registry origin does not reinterpret that
independent lineage as a registry predecessor.

For a successor archive, the gateway validates the complete preceding registry
archive view before using its terminal entries. Scope, policy, challenge,
modality set, ordinal, unit, timeline, result, state, completion, and
previous-entry continuity must all agree before the existing registry encoder
can produce the successor.

## Unchanged publication boundary

Successful admission feeds the existing three-object registry generation:

| Ordinal | Registry object | Canonical content |
| ---: | --- | --- |
| 1 | Registry manifest | Fixed 544-byte generation and aggregate binding |
| 2 | Entry table | Canonical fixed 544-byte entries |
| 3 | Payload pack | Exact concatenated encoded payload bytes |

The producer wires and raw output bytes are pre-publication inputs; they do not
become a fourth registry object. The existing registry selector remains the
only filesystem visibility authority.

The admission gateway itself has no filesystem or selector authority and adds
no separate restart claim. A successful call returns an archive compatible
with the existing registry publication APIs. The retained `2/3/2` to `2/2/3`
seven-phase process-death campaign validates the generic structural registry
path; it is separate evidence and does not attest that the gateway produced
those retained fixtures. Admission's retained `1/1/1` two-generation golden
chain instead validates typed construction and predecessor continuity in
memory.

## Independent verification

Run the focused contract tests with:

```sh
zig test src/core/generated_media_producer_admission.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_media_producer_admission
```

The independent Python model decodes the producer wires without executing Zig,
reconstructs their bindings, checks exact raw bytes, derives the same common
envelope and typed predecessors, and builds the existing registry archive.
Retained adversarial cases cover malformed records, mixed producer fields,
wrong raw bytes, one-based/zero-based image position drift, source/output
confusion, noncanonical ordering, predecessor substitution, completion
substitution, common-envelope mismatch, and invalid delivery metadata.

## Runtime uses

This gateway gives contributors a bounded integration point for:

- local or accelerator-backed image generation whose raw pixels and encoded
  deliverables must share one lineage;
- speech, music, or streaming-audio pipelines that resume at exact frame and
  acknowledgement boundaries;
- video generation workers that must preserve segment, frame, and timeline
  continuity before archive publication;
- provider or edge handoff paths that validate local typed outputs before
  retaining an encoded delivery; and
- future family adapters that need to enter the shared publication plane
  without bypassing typed state and evidence contracts.

## Claim boundary

Admission proves canonical record structure, the retained cross-record
relations, exact raw-output bytes, reconstructable audio/video application
acknowledgement transitions, strict typed predecessor continuity, and the
mapping into one canonical registry identity.

It does **not** prove that a model, decoder, renderer, playback sink, display
sink, or encoder actually ran. Replaying a canonical acknowledgement transition
is structural evidence, not device attestation. Self-consistent hashes are not
signatures or authorization. The gateway does not establish historical
execution, live resource authority, codec/container correctness,
external-format compatibility, physical playback/display, native Linux
behavior, storage-device power-loss durability, media quality, latency,
throughput, memory, energy, or production readiness.

## Next runtime slices

Contributor-sized follow-on work includes:

1. add crash-atomic paired retention and read-only inspection for the
   transition evidence sidecar plus its exact unchanged registry archive;
2. extend deterministic model/materializer replay profiles beyond the retained
   image/audio/video references;
3. extend model-family contracts and adapters beyond the retained perception
   and generative-media fixtures;
4. add backend capability, placement, transfer-ownership, and scheduling
   contracts across CPU, accelerator, edge, and provider execution;
5. add shared streaming, batching, cancellation, observability, and policy
   controls without weakening atomic publication;
6. integrate production image/audio/video encoders and containers with
   redistributable external-format conformance fixtures; and
7. expand richer image, speech, music, video, multimodal-fusion, retrieval,
   agent, and scientific-model workloads under the same runtime planes.

See [Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md),
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md),
[Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md),
[Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
