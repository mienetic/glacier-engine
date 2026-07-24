# Generated-Media External-Format Profiles and Evidence

Status is deliberately split into three claims:

- **Validated bounded profiles:** allocation-free Zig modules emit and accept
  strict canonical PNG, PCM/WAVE, and APNG subsets. They have native macOS
  tests, frozen independent vectors, mutation rejection, and module-level
  Linux/Windows/FreeBSD cross-compilation.
- **Integrated bounded format-conformance sidecar:** canonical two-generation
  PNG, WAVE, and APNG fixtures pass through the registry,
  producer-transition, and format validators with exact successor,
  missing/foreign predecessor, semantic-drift, and failure-atomic output
  checks. The audio and video fixtures use the real playback/display
  acknowledgement state machines. An independent Python oracle validates all
  three binary layers and producer semantics without executing Zig.
- **Experimental read-only inspector:** a CLI validates a generated-media
  registry archive and producer-transition sidecar, optionally validates the
  current and predecessor format sidecars, and renders deterministic JSON
  without payload bytes.

These claims do not imply general codec/container support, lossy compression,
compression quality, media quality, historical execution, native execution on
every cross-compiled OS, physical playback/display, or production readiness.

## Why these layers stay separate

| Layer | What it establishes | What it does not establish |
| --- | --- | --- |
| Output registry archive | Exact ordered entries and encoded payload bytes for one generation | Typed producer correctness or external-format semantics |
| Producer-transition sidecar | Deterministic reconstruction of the retained typed producer/materializer transition | Historical execution, live authority, or external-format correctness |
| Format-conformance sidecar | Exact payload/profile semantics joined to the registry entry, transition receipt, and producer plan or manifest | General format acceptance, device behavior, quality, or performance |
| Read-only inspector | Human-readable identities, lineage, sizes, entry metadata, and optional format-profile/root fields after exact triple validation | Payload export, callbacks, or mutation authority |

Keeping the layers additive preserves the existing registry and
producer-transition V1 wires. A verifier can reject a format sidecar without
rewriting or reinterpreting either earlier artifact.

## Strict canonical profiles

All V1 readers accept only the byte-exact subset their paired writer emits.
Unsupported structure rejects; it is not normalized into the accepted form.

### PNG V1

The bounded still-image profile accepts:

- 8-bit, non-interlaced gray, gray plus straight alpha, RGB, or RGBA;
- either linear transfer through `gAMA=100000` or sRGB rendering intent 0;
- filter type 0 on every row;
- zlib header `78 01` and stored DEFLATE blocks of at most 65,535 bytes;
- exactly one `IDAT`, followed by `IEND`, with no extra chunks;
- width and height from 1 through 8,192; and
- no more than 16 MiB of raw pixel bytes.

The retained independent Python vector is a smaller 2×2 linear gray8 case. It
does not independently cover every shape admitted by the Zig leaf profile.

### PCM/WAVE V1

The bounded audio profile accepts:

- RIFF/WAVE PCM format tag 1;
- one or two interleaved signed 16-bit little-endian channels;
- a positive sample rate no greater than 768,000 Hz;
- from 1 through 4,096 frames;
- one 16-byte `fmt ` chunk and one `data` chunk in an exact 44-byte header; and
- no padding, ancillary chunks, trailing bytes, or RF64.

The retained independent Python vector is mono, 16 kHz, and two frames. It is a
frozen interoperability fixture, not evidence for every allowed rate or stereo
shape.

### APNG V1

The bounded animated-image profile accepts:

- exactly two full-canvas gray8 frames;
- linear transfer through `gAMA=100000`;
- one animation play, dispose-none, and source blend;
- sequence numbers 0, 1, and 2;
- exact frame delays reduced to `u16` numerator/denominator pairs;
- one `IDAT` for frame one and one `fdAT` for frame two, with stored DEFLATE
  blocks and no extra chunks;
- width and height from 1 through 4,096; and
- an aggregate safety guard of 256 MiB; the exact two-frame gray8 geometry
  makes 32 MiB the reachable maximum.

The retained independent vector is 2×2 with delays `1/500` and `3/1000`. An
equivalent but unreduced delay such as `2/1000` rejects because V1 requires one
canonical representation.

The independent external-format oracle is intentionally narrower than the Zig
leaf profiles: encoded inputs, raw payloads, and individual chunks are each
capped at 4,096 bytes, and its parsers accept only the retained 2×2 gray PNG,
mono 16 kHz two-frame WAVE, and 2×2 two-frame APNG shapes. It does not
independently validate the larger dimensions, multiblock cases, channel shapes,
sample rates, or frame counts admitted by the bounded Zig modules.

## Additive format-conformance sidecar

`generated_media_format_conformance` defines one fixed 576-byte batch header
plus one 1,152-byte record per registry entry, up to the registry limit of
twelve records. The maximum V1 sidecar is therefore 14,400 bytes.

Each record binds:

- modality, strict delivery profile, registry ordinal, and encoding ABI;
- the exact typed image plan, audio plan, or video manifest wire;
- raw-output length and digest;
- encoded-payload length and digest;
- registry payload, entry, and encoder-implementation identities;
- the format-contract and producer-transition receipt identities; and
- the preceding format record for the same modality.

The validator additionally decodes the embedded producer wire and cross-binds
request/generation/producer order, state generations, model and materializer
identity, output identity and size, exact audio/video ranges and timelines, and
the required playback/display completion sequence to the transition receipt.
For stateful images it also binds the model step, model plan, and state
publication claimed by the image plan.

The batch binds the registry generation and publication sequence, request
epoch, generation plan, tenant scope, metadata policy, challenge, transition
batch, registry manifest/archive, ordered record table, profile set, preceding
format batch, and terminal record for each modality.

Generation one requires zero predecessor format roots. A successor requires the
exact preceding registry archive, producer-transition sidecar, and format
sidecar; substituting another valid generation is not accepted.

The implementation has canonical record/batch encoding, structural and
mutation tests, strict payload/profile validation, and exact predecessor
validation. Retained two-generation PNG, WAVE, and APNG fixtures are
constructed through the actual registry archive and producer-transition
validators. WAVE and APNG construct publication, observation,
acknowledgement-plan, acknowledgement-result, and final-state chains through
the typed producer APIs. Every profile covers missing/foreign predecessor
rejection, semantic drift, and failure-atomic destination handling. The
fixtures also assert that plain encoded-payload SHA-256 is distinct from the
registry's domain-separated payload root.

The independent Python oracle implements the exact 576/1,152-byte wires without
importing Zig. It decodes the registry archive, producer-transition sidecar,
canonical image plan, audio plan, video manifest, and format sidecar, verifies
their roots, and cross-checks producer state, identity, ranges, geometry,
sample rate, timing, and frame hashes against parsed PNG/WAVE/APNG payloads.
Its retained two-generation all-profile chain also covers frozen contract,
profile-set, record-table, batch, and whole-evidence roots; every record and
batch byte mutation; every batch truncation and insertion; canonical ordering,
aggregates, terminals, zero padding, and successor lineage.

The sidecar embeds the producer plan or manifest, not the complete
playback/display observation, acknowledgement-plan, or acknowledgement-result
wires. Their exact roots and completion state remain bound through the paired
transition receipt and registry entry; replaying those acknowledgement wires
independently still requires retaining the producer-transition evidence.

## Read-only producer-transition inspector

Inspect a first-generation registry and transition sidecar:

```sh
zig build generated-media-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -- \
  --archive path/to/current.registry \
  --evidence path/to/current.transition-evidence
```

Inspect a successor:

```sh
zig build generated-media-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -- \
  --archive path/to/current.registry \
  --evidence path/to/current.transition-evidence \
  --previous-archive path/to/previous.registry \
  --previous-evidence path/to/previous.transition-evidence
```

Add exact format-sidecar validation to genesis inspection:

```sh
zig build generated-media-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -- \
  --archive path/to/current.registry \
  --evidence path/to/current.transition-evidence \
  --format-evidence path/to/current.format-evidence
```

For a successor, add both `--format-evidence` and
`--previous-format-evidence` alongside the preceding registry/transition
pair. A format predecessor without a current format sidecar, a missing
successor predecessor, or an extra genesis predecessor rejects.

The inspector:

- accepts regular read-only files only;
- caps each registry archive at 16 MiB, each transition sidecar at 21,376
  bytes, and each optional format sidecar at 14,400 bytes;
- rejects a predecessor pair for genesis and requires both predecessor files
  for a successor;
- validates exact file lengths, registry structure, transition receipts,
  optional format profiles and producer semantics, and predecessor lineage
  before initializing semantic stdout;
- emits one compact, field-ordered JSON document with generation, lineage,
  roots, aggregate sizes, and per-entry metadata;
- never renders encoded payload bytes; and
- has no model callback, credential, device, network, or filesystem-write path.

Invalid input exits nonzero and emits no semantic stdout. The JSON output is an
inspection result, not new authority and not a substitute for retaining the
verified binary artifacts.

Legacy registry/transition-only output remains the original byte-stable schema.
Format mode uses a separate schema and adds only profile names, format-record
and contract roots, plain encoded-payload hashes, and current/predecessor format
batch roots.

## Verification

Run the native format modules and conformance-sidecar tests:

```sh
zig build media-external-format-test \
  -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent retained external-format vectors and rejection campaign:

```sh
python3 -m unittest bench.tests.test_generated_media_external_format
```

Run the independent format-sidecar wire/root and mutation oracle:

```sh
python3 -m unittest bench.tests.test_generated_media_format_conformance
```

Run the independent inspector renderer/parser and adversarial CLI campaign:

```sh
python3 -m unittest bench.tests.test_generated_media_evidence_inspector
```

The retained portability envelope is narrower than source portability:

- PNG/APNG and WAVE leaf tests execute natively on the macOS development host;
- those leaf modules pass compile-only gates for x86_64 Linux musl, Windows
  GNU, and FreeBSD;
- both independent Python format suites use the standard library and execute on
  the macOS host; native Linux/Windows execution remains unretained;
- the inspector executes on the macOS host and passes x86_64 Linux musl,
  Windows GNU, and FreeBSD compile gates; and
- the composed format-conformance test target executes on the macOS host and
  passes x86_64 Linux musl, Windows GNU, and FreeBSD compile gates.

Cross-compilation is not runtime execution evidence. Filesystem behavior,
process control, display/audio devices, and power-loss durability require their
own native campaigns.

## Contributor-ready next slices

1. **Broaden the independent stress envelope.** Add maximum-entry and multiple
   records-per-modality vectors while preserving the frozen V1 roots and
   bounded mutation strategy.
2. **Retain native portability evidence.** Run the format target and inspector
   campaign on Linux and Windows, record the exact toolchain/machine envelope,
   and keep compile-only claims separate from runtime results.
3. **Add production adapters.** Join one redistributable production
   decoder/renderer and encoder/container path to these bounded contracts while
   retaining separate quality, performance, and device-authority evidence.
4. **Add profiles by version, not ambiguity.** A new channel shape, WAVE layout,
   animation shape, compression mode, or chunk policy needs a new explicit
   encoding ABI, golden vectors, ceilings, independent parser coverage, and
   rejection tests. V1 must not silently broaden.

Related contracts:

- [Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md)
- [Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md)
- [Canonical Generated-Media Producer Admission](GENERATED_MEDIA_PRODUCER_ADMISSION.md)
- [Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md)
- [Evidence Policy](EVIDENCE_POLICY.md)
- [Platform Portability](PLATFORM_PORTABILITY.md)
