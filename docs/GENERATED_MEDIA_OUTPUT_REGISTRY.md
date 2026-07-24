# Bounded Generated-Media Output Registry

Status: **integrated model-free multi-output archive and process-death recovery
path; typed producer admission adapters, production encoder/container adapters,
external-format conformance, native Linux execution evidence, power-loss
durability, physical playback/display evidence, and quality claims remain
gated**.

Glacier can now publish a bounded generation containing multiple image, audio,
and video output entries as one canonical unit. The registry extends the
earlier fixed one-output-per-modality fixtures without changing any existing V1
wire. It gives queue workers, local generation pipelines, and future production
adapters one deterministic place to verify output order, structural completion
evidence, continuity, exact encoded bytes, and predecessor lineage before a
generation becomes visible.

This is an independent ABI. The fixed generated-media member, checkpoint,
payload-manifest, and eight-object payload-archive V1 records remain
byte-for-byte unchanged and independently decodable.

## Bounded shape

A valid registry generation contains:

- one to four output entries with `completed = true` for each modality present
  in the generation;
- no more than twelve entries in total;
- one fixed 544-byte entry per output;
- entries in canonical `(modality, ordinal)` order;
- one fixed 544-byte registry manifest; and
- one exact concatenated encoded-payload pack in the same order as the entries.

The canonical checkpoint archive contains exactly three extension objects:

| Ordinal | Object | Canonical content |
| ---: | --- | --- |
| 1 | Registry manifest | Fixed 544-byte generation, count, length, scope, policy, challenge, and predecessor binding |
| 2 | Entry table | Exact concatenation of fixed 544-byte entries in `(modality, ordinal)` order |
| 3 | Payload pack | Exact concatenation of every encoded payload in entry order |

No per-output file or selector creates another visibility boundary. The
existing generic checkpoint-file selector is the sole filesystem selector for
the complete three-object archive.

The retained reference generations deliberately change the distribution rather
than only the bytes:

| Generation | Images | Audio chunks | Video segments | Total entries |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 2 | 3 | 2 | 7 |
| 2 | 2 | 2 | 3 | 7 |

This exercises per-modality continuity and rejects a successor assembled by
silently carrying an output count or entry from the wrong generation.

## Entry admission

Each entry enforces one modality-specific structural completion shape:

- image requires `completion_required = false`, `completed = true`, and a zero
  completion root;
- audio requires `completion_required = true`, `completed = true`, and a
  nonzero completion root; and
- video requires `completion_required = true`, `completed = true`, and a
  nonzero completion root.

All three also require a nonzero post-publication state root. These roots are
opaque identities at the registry boundary. The registry does not decode the
earlier typed image result, audio playback acknowledgement, video display
acknowledgement, or modality state wires. A producer adapter must validate
those records before presenting their roots to the registry.

Every admitted entry binds its exact:

- modality and ordinal;
- logical units, byte counts, and timeline position;
- opaque artifact, provenance, result, raw source-output, media, and
  post-publication state identities;
- encoded-payload identity and byte range;
- encoder-implementation and format identities;
- structural completion fields and opaque completion identity; and
- previous-entry identity.

The registry manifest binds the complete ordered entry table and payload pack
to their exact totals, generation plan, request epoch, generation, publication
sequence, scope, policy, challenge, and preceding manifest/archive identities.

Image, audio, and video therefore share one registry shape without pretending
that their structural completion fields are interchangeable or that an opaque
root proves an external sink action.

## Continuity and canonical validation

The decoder reconstructs rather than trusts:

- the one-to-four per-present-modality and twelve-entry bounds;
- the same present-modality set across predecessor/successor lineage, while
  allowing each per-modality count to change within bounds;
- canonical `(modality, ordinal)` ordering with no duplicate or skipped
  ordinal;
- ordinal zero plus unit/timeline zero for each initial modality, followed by
  exact ordinal, logical-unit, timeline, and previous-entry continuity within
  and across generations;
- the required nonzero opaque state identity and modality-specific completion
  presence/zero shape;
- entry roots covering every opaque artifact, provenance, result, source,
  media, state, completion, encoder, format, and payload identity;
- each payload root from its exact bytes and declared modality, ordinal,
  encoding ABI, and source-output identity;
- entry-table and payload-pack lengths and roots;
- generation-plan, scope, policy, and challenge identity;
- exact payload offsets with no gaps, overlap, prefix, or trailing bytes; and
- the complete previous registry archive bytes for a successor.

A contradictory manifest, noncanonical entry order, stale-root payload
substitution, mixed lineage, or split predecessor metadata is not admissible
under the archive identity being verified. A fully rehashed alternative is a
different canonical archive identity; the registry does not authorize its
semantics. A typed producer/admission adapter must decide whether that new
identity is allowed. Requiring the exact previous archive bytes keeps
predecessor identity, decoded content, and canonical serialization in one
verifiable object.

## Process-death recovery

The registry reuses the established seven-phase archive promotion protocol:
1. write the successor archive;
2. sync the successor archive;
3. sync its directory entry;
4. write the selector candidate;
5. sync the selector candidate;
6. rename the candidate over the active selector; and
7. sync the selector directory entry.

The retained model-free campaign terminates the publisher with `SIGKILL` after
each phase. The first five deaths select the complete previous registry and the
last two select the complete successor. Recovery rejects mixed entry/payload
generations and converges idempotently.

This is host-filesystem process-death evidence. It does not emulate storage
device power loss, prove initial-publication durability after power failure, or
establish native Linux filesystem behavior.

## Independent verification

Run the focused retained suite with:

```sh
zig test src/core/generated_media_output_registry.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_media_output_registry
zig build generated-media-output-registry-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The independent Python oracle reconstructs the manifest, entry table, exact
payload pack, per-modality continuity, modality-specific structural completion
fields, and two-generation predecessor relation without executing Zig. The
restart demo emits machine-readable evidence for the two reference
distributions, exact payload recovery, seven process-death phases,
previous-or-successor selection, zero mixed generations, and idempotent
convergence.

These fixtures execute no model and use bounded reference encodings rather than
production image, audio, or video formats. They do not decode or independently
prove the earlier typed producer acknowledgements or quiescent modality states.
They also do not establish codec or container compatibility, native Linux
execution, storage-device power-loss durability, physical playback/display,
media quality, latency, throughput, memory, energy, or production readiness.

## Runtime uses

The registry is a foundation for:

- multi-image generation jobs whose previews and final candidates must retain
  exact ordinal and encoder identity;
- speech, music, or streaming-audio jobs that must resume on exact chunk and
  timeline boundaries after typed producer validation;
- multi-segment video jobs that must not expose a later segment before a typed
  producer adapter has validated every required predecessor;
- local or edge queues that need one bounded, content-addressed output unit
  without embedding private prompts or model weights; and
- production encoder/container adapters that can be verified without weakening
  existing typed publication contracts.

## Next contributor slices

Useful follow-on work is intentionally separable:

1. add typed producer adapters that decode existing image result, audio
   acknowledgement/state, and video acknowledgement/state wires before
   registry admission;
2. adapt one production image encoder behind explicit format, numerical, and
   capability policies, with a redistributable fixture;
3. adapt one audio or video codec/container and independently verify its
   external format;
4. retain native Linux process-death campaigns with a captured filesystem and
   machine envelope;
5. design initial-publication and storage-device power-loss durability as a
   separate protocol and evidence claim;
6. add authorized device playback/display observation outside the portable
   core; and
7. measure quality, latency, throughput, memory, energy, and storage under
   named artifacts and platforms.

See [Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md),
[Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md),
[Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
