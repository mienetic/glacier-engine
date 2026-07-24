# Host-Verified Generated-Media Producer Transitions

Status: **bounded deterministic transition gateway for the retained image,
audio, and video reference profiles; historical execution, live resource
authority, physical sink behavior, production adapters, external-format
conformance, and performance remain gated**.

The producer-transition layer adds a higher-assurance construction path in
front of the generated-media output registry. The host supplies canonical
source-model and producer records, exact byte witnesses, and trusted runtime
callbacks. The gateway replays the deterministic model and materializer work,
reconstructs publication and completion transitions, builds the unchanged
registry archive, and emits a separate evidence sidecar bound to that exact
archive.

The existing
[structural producer admission](GENERATED_MEDIA_PRODUCER_ADMISSION.md) remains
available and byte-for-byte unchanged. It continues to prove canonical producer
records, exact raw-output bytes, structural audio/video completion replay, and
registry mapping. It is not silently promoted to transition assurance.

## Assurance boundary

The transition gateway verifies more than a set of mutually consistent roots:

- canonical source-model artifact, plan, result, publication, retained-state,
  adapter, support-set, and resource evidence;
- exact model weights, input, prior state, candidate output, and successor-state
  witnesses required by the selected reference profile;
- the actual deterministic model callback selected by the host;
- exact image-decoder, audio-renderer, or video-renderer input, payload, output,
  and implementation bindings;
- the actual deterministic materializer callback selected by the host;
- producer publication state, media identity, resource receipt, provenance,
  publication result, and post-publication state;
- complete audio playback or video display observation, acknowledgement plan,
  acknowledgement result, and final quiescent state;
- normalized producer projection, encoded payload, registry entry, manifest,
  archive, and predecessor lineage; and
- a fixed transition receipt for every admitted output plus one bounded batch
  sidecar.

Trusted adapters are runtime values. Function pointers, callback contexts,
allocator state, device handles, and host addresses are never serialized.
Canonical adapter and implementation identities are serialized; the host must
resolve those identities to an allowed callback before verification.

Replaying the selected callback proves that the supplied witnesses reproduce
the declared deterministic transition on the verifying host. It does not prove
that the same callback ran historically, ran on a named device, held live
resource authority, or produced the originally observed bytes at a particular
time.

## Fixed wrapper wires

The labels in this document describe roles, not a promised public library API.
Callers should rely on the encoded contract and documented claim boundary until
the stable API milestone names a supported construction surface.

Four small wrappers make existing pointer-free values canonical at this
boundary.

| Wire | Bytes | Magic | Decoded value and root rule |
| --- | ---: | --- | --- |
| Model-publication wrapper | 160 | `GLMPUB1\0` | Existing model publication state; the value must reproduce its canonical publication-state root |
| Adapter-descriptor wrapper | 256 | `GLMADP1\0` | Existing adapter descriptor; the complete wrapper is covered by its canonical SHA-256 identity |
| Media-publication wrapper | 224 | `GLMMPB1\0` | Existing media publication state; the value must reproduce its canonical publication-state root |
| Resource-receipt wrapper | 192 | `GLMRCP1\0` | Existing resource receipt; the complete wrapper is covered by its canonical SHA-256 identity and must pass the receipt's structural integrity check |

Every wrapper uses a fixed ABI, exact length, zero reserved bytes, little-endian
integers, and mutation-complete root validation. Unknown ABI values, nonzero
flags, trailing data, and noncanonical encodings are rejected.

The resource receipt wrapper preserves an important distinction: its integrity
check detects structural drift or accidental token misuse. It is not
authentication and does not prove that the receipt is still committed in a
live resource authority.

## Transition and batch wires

Each verified output produces one fixed transition receipt.

| Wire | Encoded size | Magic | Root |
| --- | ---: | --- | --- |
| Transition receipt | 1,728 bytes | `GLMXTRN1` | Domain-separated receipt root |
| Batch evidence sidecar | `640 + N × 1,728` bytes | `GLMXBAT1` | Domain-separated batch root |

`N` is the number of admitted outputs. It is between 1 and 12 inclusive, with
no more than four outputs for any one modality. The smallest sidecar is 2,368
bytes and the largest is 21,376 bytes. Exact model, state, materializer, raw
media, and encoded-delivery bytes are verification inputs; the sidecar retains
their roots rather than duplicating those potentially large witnesses.

The receipt's canonical ordered digests cover:

- the common generation, tenant, policy, and challenge envelope;
- model artifact, adapter, support, plan, publications, retained state, exact
  weights/input/output/state witnesses, result, and transition or source
  mapping;
- producer plan or manifest, media object, pre-state, materializer payload and
  implementation, replayed execution, raw output, provenance, resource
  evidence, publication result, and post-publication state;
- completion observation, plan, result, and final state where the modality
  requires acknowledgement;
- encoder, format, and exact encoded-payload identity; and
- previous transition receipt, normalized producer projection, registry
  predecessor, entry, manifest, and complete archive identity.

Image has no application acknowledgement. Its completion observation, plan,
and result roots use the canonical absent form required by the image profile;
its final state is the exact committed per-image media publication state.
Audio and video must populate all completion roots and reproduce the supplied
final state exactly.

The 640-byte batch header binds the canonical receipt table, common generation
envelope, previous evidence batch, exact registry manifest and archive, first
receipt, and terminal receipt for each present modality.

Absent modality terminals use their canonical absent form. Receipt-table order
is the same canonical modality and collection order used by the registry.

## Conceptual integration surface

The current bounded integration has six roles:

- a previous pair carrying the preceding evidence sidecar and the exact
  preceding registry archive it binds;
- a current batch carrying canonical records, exact witnesses, trusted host
  adapters, delivery bytes, and generation identity;
- checked size calculations for evidence, replay scratch, and the unchanged
  registry archive;
- one verify-and-prepare operation that performs replay, transition
  reconstruction, registry construction, and sidecar construction;
- one self-contained pair validator, `validateArchiveAndEvidenceV1`, that
  checks an evidence sidecar against its exact registry archive and genesis
  shape; and
- one successor-pair validator, `validateSuccessorArchiveAndEvidenceV1`, that
  additionally anchors exact trusted predecessor roots and the first receipt
  for each present modality.

These are conceptual roles. Public type and function names remain part of the
stable-API milestone rather than this integration milestone.

All size calculations are checked before slicing or callback execution.
Overflow, zero outputs, more than twelve outputs, more than four outputs for a
modality, duplicate or noncanonical order, and inconsistent required sizes fail
before a prepared batch exists.

## Verification sequence

For each output, the verify-and-prepare operation follows one bounded sequence:

1. Decode every fixed wrapper and canonical source-model, producer, media,
   observation, acknowledgement, and delivery record.
2. Validate request, scope, policy, challenge, generation plan, model family,
   operation, numerical policy, support set, adapter descriptor, artifact,
   resource claim, publication position, and predecessor bindings.
3. Verify the exact weight, input, prior-state, expected-output, and
   successor-state byte witnesses against their declared roots and lengths.
4. Resolve the serialized adapter identity to a trusted host adapter and replay
   its deterministic execution into private scratch.
5. Validate and exact-compare the replayed model output and successor state;
   reconstruct the model result, source mapping or state transition, model
   publication successor, and state-publication successor.
6. Resolve the image decoder, audio renderer, or video renderer from trusted
   host policy and replay the deterministic materializer over the exact source
   and payload bytes.
7. Exact-compare the materialized raw output, rebuild provenance, verify the
   producer resource receipt, and reconstruct publication through its exact
   post-publication state.
8. For audio and video, reconstruct the pending state, observation,
   acknowledgement plan, acknowledgement result, and final quiescent state.
9. Derive the collection-aware producer projection and the next registry entry;
   callers do not supply registry predecessor roots as authority.
10. Build the unchanged registry archive, bind every receipt to its derived
    registry entry and the final manifest/archive roots, then encode the batch
    sidecar.

Any callback error, byte drift, record substitution, root mismatch, stale
predecessor, or reconstruction difference rejects the complete batch.

## Image collection semantics

Generated-image V1 publication is a local one-image media transaction. A
transition-verified image therefore keeps:

- producer-local `image_index == 1`;
- zero visible images and units before publication;
- one visible image and unit after publication; and
- a fresh, independently validated media publication before/after pair.

The gateway does not feed one image's media publication state into the next
image. That would conflate a single `MediaObject` transaction with collection
order and would not satisfy the image V1 publication contract.

Instead, the gateway derives a separate zero-based collection ordinal:

- the first registry image has collection ordinal zero;
- each subsequent image is the preceding validated registry image ordinal plus
  one;
- registry image `unit_start` and `timeline_start` equal the collection
  ordinal; and
- registry image `unit_end` and `timeline_end` equal the collection ordinal plus
  one.

The collection ordinal is derived from the validated current batch or preceding
registry terminal. It is not accepted as caller authority. The registry
previous-entry root and producer previous-result binding provide collection
continuity, while each entry's state-after root remains the genuine local image
publication successor.

This preserves the complete image V1 binding while allowing a bounded
multi-image registry. A separate mutable image-collection state is not part of
this milestone.

## Audio and video transitions

Audio and video retain their streaming producer coordinates rather than the
image-local/collection split.

For audio, the gateway verifies the source-model transition, replays the PCM
renderer, reconstructs the publication state before and pending state, validates
the playback observation and acknowledgement plan, reproduces the playback
acknowledgement result, and exact-compares the final quiescent audio state.
Chunk ordinal, frame range, previous publication result, previous
acknowledgement, output root, sink identities, and final state must form one
transition.

For video, the gateway verifies the source-model transition, replays the frame
renderer, reconstructs the publication state before and pending state,
validates the display observation and acknowledgement plan, reproduces the
display acknowledgement result, and exact-compares the final quiescent video
state. Segment ordinal, frame range, target ticks, previous publication result,
previous acknowledgement, output root, sink identities, and final state must
form one transition.

These completion transitions are deterministic application-state
reconstruction. They do not prove that samples reached a speaker or that frames
reached a physical display.

## Scratch and alias rules

Replay uses one caller-owned scratch range whose required size is checked
before execution. The gateway reuses that same bounded range sequentially for
callback work and unchanged-registry encoding; the required size is the checked
maximum of those phases, not their sum. Callback work is itself bounded by the
largest selected record: model candidate output plus successor state, or
materialized raw output. The range is private verification workspace, not
visible output and not part of either encoded artifact. Model and materializer
callbacks receive only their bounded candidate slices, and the scratch range is
scrubbed on every exit after replay workspace initialization. Preflight errors
that occur before workspace use leave caller memory unchanged.

The scratch range, evidence destination, registry destination, canonical input
wires, exact-byte witnesses, raw media, encoded payloads, previous evidence,
and previous registry archive must obey the gateway's disjointness rules.
Unsupported overlap and in-place encoding are rejected before callbacks can
turn an immutable witness into a candidate.

Candidates are exact-compared before either prepared output is returned. On
failure, destination contents carry no prepared-batch authority. Callers must
use only the exact slices returned after successful verification.

## Unchanged registry and paired lineage

The generated-media output registry remains its existing three-object V1
archive:

1. registry manifest;
2. fixed entry table; and
3. encoded payload pack.

No transition field is inserted into an existing registry entry, manifest, or
selector. For a given normalized output set, the transition gateway constructs
the same registry contract and then binds its exact entry, manifest, and archive
roots into the separate transition evidence.

A successor requires both halves of the previous pair:

- the completely validated previous evidence sidecar; and
- the exact previous generated-media registry archive bound by that evidence.

Supplying only one half, mixing evidence with a different registry, replacing a
previous receipt, changing a terminal modality receipt, or breaking either
registry previous-entry lineage or transition-receipt lineage is rejected. The
self-contained validator checks the current pair and genesis shape. Exact
successor lineage requires the successor-pair validator together with the
trusted preceding pair; a current pair cannot authenticate its own predecessor
anchor.

This sidecar is verification evidence, not a fourth registry object and not a
new visibility selector.

## Supported reference profiles

The milestone is intentionally narrow. It supports the retained deterministic
reference profiles needed to verify:

- an exact stateful source-model transition followed by generated-image
  decoding and one independent image publication;
- an exact source-model transition followed by generated-audio rendering,
  publication, playback observation, acknowledgement, and final state; and
- an exact source-model transition followed by generated-video rendering,
  publication, display observation, acknowledgement, and final state.

Each profile uses canonical adapter and materializer identities and callbacks
provided by the trusted host runtime. Unknown identities, mismatched
descriptors, unsupported model-family or operation combinations, ambient
capability requests, and alternative callback shapes fail closed.

There is no serialized profile selector or assurance flag in this milestone.
The admitted modality, model lifecycle shape, and complete canonical record set
determine the replay and completion path.

The reference profiles prove the shared gateway and evidence semantics. They do
not imply support for arbitrary models, decoders, renderers, codecs,
containers, devices, or numerical modes.

## Independent verification

Run the focused contract suites with:

```sh
zig test src/core/generated_media_producer_transition.zig -OReleaseSafe
python3 -m unittest bench.tests.test_generated_media_producer_transition
```

The independent Python oracle owns no Zig callback or runtime pointer. It
reconstructs the retained deterministic model/materializer behavior, validates
the complete sidecar and registry pair, checks two-generation predecessor
lineage, and rejects retained wrapper, witness, transition, image-ordinal,
completion, registry-binding, and paired-lineage substitutions.

## Failure matrix

| Boundary | Rejected examples |
| --- | --- |
| Wrapper and sidecar encoding | Wrong magic, ABI, length, flags, reserved bytes, footer root, receipt size, receipt count, or trailing bytes |
| Batch bounds | Zero outputs, more than twelve outputs, more than four of one modality, duplicate order, noncanonical order, or arithmetic overflow |
| Common identity | Mixed request epoch, generation plan, tenant scope, metadata policy, or challenge |
| Source model | Substituted artifact, support set, adapter descriptor, model plan, publication, state publication, result, or incompatible family/operation/policy |
| Exact model witnesses | Wrong weight, input, prior-state, output, or successor-state length or digest |
| Model replay | Callback failure, candidate drift, output/state mismatch, wrong transition or source-mapping root, or wrong publication successor |
| Runtime adapter | Unknown implementation, descriptor mismatch, unsupported bounds/capabilities, or serialized callback/context attempt |
| Materializer replay | Wrong source bytes, payload, implementation, candidate length, raw output, or materializer-execution root |
| Resource evidence | Noncanonical receipt wire, invalid structural integrity, claim mismatch, owner/epoch/slot/generation drift, or producer-resource root mismatch |
| Media publication | Wrong media object, pre-state, event, prepared commit, publication result, or post-publication state |
| Image mapping | Local image index other than one, non-fresh local state, caller-selected collection ordinal, ordinal gap, or image state chained as collection state |
| Audio completion | Wrong pending state, playback observation, acknowledgement plan/result, frame range, sink identity, predecessor, or final state |
| Video completion | Wrong pending state, display observation, acknowledgement plan/result, frame/tick range, sink identity, predecessor, or final state |
| Delivery binding | Wrong raw output, encoded payload, encoder identity, format identity, payload root, or source/output confusion |
| Registry binding | Wrong projection, previous entry, ordinal/unit/timeline continuity, entry root, manifest root, archive root, or encoded payload mapping |
| Evidence lineage | Missing prior pair, evidence/registry mix, wrong previous batch, receipt-table substitution, wrong first receipt, or wrong modality terminal |
| Memory safety | Insufficient scratch or destination, forbidden alias, overlapping mutable regions, or in-place encoding |
| Assurance downgrade | Missing transition evidence or trusted adapter when transition verification was requested |

A fully coherent replacement graph can still pass structural cryptographic
checks if the verifier has no trusted predecessor, implementation policy,
signature, or other external trust anchor. Hashes provide integrity and
identity, not authenticity.

## Runtime uses

This gateway provides a bounded integration point for:

- deterministic CI and release fixtures that must replay source-model,
  materializer, publication, and completion transitions before archiving
  outputs;
- local workers that need one canonical evidence receipt for every encoded
  image, audio chunk, or video segment;
- provider or process handoffs where exact returned bytes are checked by trusted
  local reference adapters before entering the registry;
- restart inspection that retains and validates the evidence sidecar together
  with its exact registry archive;
- multi-image batches whose registry collection order must remain distinct from
  each image's local media transaction; and
- contributor adapters that need a clear, fail-closed target for model,
  materializer, state, resource, and publication integration.

## Claim boundary

The milestone proves:

- canonical, bounded wrappers, receipts, batch evidence, and registry input;
- exact witness roots and deterministic replay on the verifying host;
- complete retained reference source-model transitions;
- complete image publication and audio/video publication-plus-completion
  reconstruction;
- exact raw and encoded byte binding;
- derived image collection order; and
- paired evidence and registry predecessor continuity.

It does not prove:

- that the reconstructed callback ran historically;
- that an implementation digest authenticates code without a trusted host
  policy;
- signature, identity, timestamp, provenance authority, or nonrepudiation;
- current `ResourceBank` ownership or authorization;
- provider, accelerator, operating-system, driver, kernel, or physical-device
  execution;
- physical playback, display, or user observation;
- external codec or container conformance;
- image, audio, or video quality;
- latency, throughput, memory, energy, or durability results; or
- production readiness.

Encoded payloads are retained and root-bound, but their declared format identity
is not an external-format validator.

## Next slices

Follow-on work can add:

1. crash-atomic retention and selection for the evidence sidecar together with
   its bound registry archive;
2. read-only inspection and compatibility reporting for retained transition
   batches;
3. signed provider evidence, measured device evidence, or live authority checks
   under separate, explicit trust policies;
4. additional model-family, numerical-policy, decoder, renderer, and
   materializer profiles with redistributable conformance fixtures;
5. external image, audio, and video format validators outside the
   authority-free core;
6. cancellation and restart campaigns at every replay and paired-publication
   boundary; and
7. benchmark evidence on explicitly named artifacts, platforms, and power
   conditions without weakening transition correctness.

See [Model-Family Adapter Contract](MODEL_FAMILY_ADAPTER.md),
[Stateful Model Adapter](STATEFUL_MODEL_ADAPTER.md),
[Stateful Model Continuation](STATEFUL_MODEL_CONTINUATION.md),
[Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md),
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md),
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md),
[Evidence Policy](EVIDENCE_POLICY.md), and
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
