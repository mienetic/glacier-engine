# Bounded Media Decode Fixtures

Status: **model-free image/audio/video fixture prototype**.

Glacier now has one sealed decode-plan ABI and one tiny canonical fixture
container exercised by image, audio, and video inputs. The reference decoder
validates the complete fixture and plan before copying canonical payload bytes
into caller-owned storage. Every decoded pixel, PCM frame, or video frame maps
back to one exact source-byte interval.

This is a contributor and conformance surface. It is not a general image,
audio, or video codec and does not run a multimodal model.

## What is implemented

- a fixed 416-byte `DecodePlanV1` wire;
- a bounded fixture container with a 320-byte canonical header;
- a 2×2 RGB8 image with four exact pixel mappings;
- eight stereo PCM s16le frames at 48 kHz with exact frame mappings;
- two 2×2 intra-frame gray8 video frames at 30 fps with a keyframe bitmap;
- allocation-free identity decoding into caller-owned output;
- exact output and zero-scratch admission;
- foreign-plan, short-output, overlap, truncation, and semantic-contradiction
  rejection;
- cross-language golden fixture, plan, and receipt roots; and
- every-byte mutation coverage for all three fixtures and plans.

## Sealed decode plan

The plan is a value, not a pointer to ambient decoder configuration:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GMDPLN1` magic |
| 8 | 8 | plan ABI |
| 16 | 8 | exact wire length |
| 24 | 8 | reserved flags; v1 requires zero |
| 32 | 8 | media kind |
| 40 | 8 | decoder ABI |
| 48 | 16 | source container and codec identities |
| 64 | 8 | destination representation |
| 72 | 24 | execution, numerical, and rejection policies |
| 96 | 8 | required capability mask |
| 104 | 32 | source, output, scratch, and logical-unit bounds |
| 136 | 48 | source and target axes |
| 184 | 32 | source and target rational time bases |
| 216 | 32 | media-object root |
| 248 | 32 | decoder-implementation root |
| 280 | 32 | transform-policy root |
| 312 | 32 | resource-policy root |
| 344 | 32 | challenge root |
| 376 | 8 | reserved zero |
| 384 | 32 | domain-separated plan root |

Decoding requires exact agreement between the plan and `MediaObjectV1` for kind,
payload length, container, codec, axes, time base, and object root. Unknown
enums, capability bits, non-canonical time, reserved values, or a non-fail-closed
policy reject before output mutation.

The fixture decoder accepts only:

- deterministic execution;
- exact-integer numerical policy;
- zero required ambient capabilities;
- the published decoder implementation root;
- the exact identity-transform root;
- output length equal to the verified payload length; and
- zero scratch bytes.

A plan for one valid object therefore cannot authorize another valid object or
modality.

## Tiny fixture container

The fixture wire is:

```text
320-byte canonical header
exact canonical payload
32-byte domain-separated footer
```

The header binds:

- media kind, semantic ABI, fixture container, and codec;
- three source/coded axes, three target/display axes, and a rational time base;
- exact payload offset, length, and storage stride;
- representation, layout, orientation, transfer, and alpha semantics;
- start tick and a bounded keyframe bitmap;
- tenant, metadata-policy, and provenance roots; and
- zero reserved bytes.

The payload digest becomes the `MediaObjectV1` content root. The object
descriptor is reconstructed and verified rather than copied from an untrusted
embedded descriptor. The whole header and payload are independently protected
by the fixture footer.

The decoder rejects payloads above 4,096 bytes before accepting a fixture. This
small ceiling is intentional: these wires are redistributable test artifacts,
not an extensible compressed-media format.

## Image fixture

The image fixture contains four row-major RGB8 pixels:

```text
red   green
blue  white
```

Its manifest declares:

- width 2, height 2, channels 3;
- six-byte tight row stride;
- top-left orientation;
- sRGB transfer;
- no alpha channel; and
- static `0/1` time base.

Each pixel maps to exactly three consecutive source and output bytes. Row
padding, orientation changes, color conversion, alpha synthesis, and resizing
are not silently inferred.

## Audio fixture

The audio fixture contains eight interleaved stereo PCM s16le frames at 48 kHz.
Its values include signed extrema, zero, positive/negative pairs, and a
non-power-of-two sample pair.

Each audio frame maps to exactly four source and output bytes and one timeline
tick. The fixture does not mix channels, resample, normalize, capture audio, or
infer a channel layout beyond the declared interleaved stereo representation.

## Video fixture

The video fixture contains two 2×2 gray8 frames at a canonical `1/30` second
time base. Coded and display geometry are both explicitly bound as 2×2 rather
than inferred. Both frames are independently decodable and marked in the
two-bit keyframe map.

Each frame maps to exactly four source and output bytes and one timeline tick.
The keyframe bitmap is bounded to 64 frames, requires frame zero, and rejects
bits outside the declared frame count. The fixture performs no seeking,
inter-frame prediction, color conversion, audio synchronization, or frame
selection.

## Mapping and receipt

`mapUnitV1` returns:

- kind and unit ordinal;
- exact source offset and length;
- exact output offset and length;
- whether the unit has a timeline position; and
- the exact source tick for audio and video.

`verifyCompleteMappingV1` walks every unit and requires contiguous, equal-length
source/output ranges ending at the exact payload boundary. A domain-separated
mapping root commits to the complete coverage geometry.

The decode receipt binds:

- media kind and logical-unit count;
- source payload offset and length;
- output length and digest;
- media-object, plan, fixture, and mapping roots; and
- its own domain-separated receipt root.

The receipt is evidence of this identity decoder's result. It grants no
filesystem, network, device, model, resource, or publication authority.

## Run it

```sh
zig build media-decode-fixture-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_media_decode_fixture
```

The demo reports:

```text
3 fixtures
416-byte sealed plans
1,108 total fixture bytes
52 decoded payload bytes
14 completely mapped units
0 heap allocations
0 scratch bytes
0 required ambient capabilities
```

Zig and the independent Python implementation share the following fixture
roots:

```text
image  5891de6bfad27654fa993b8a31c71749ab5346bd3701b2cbcf62ef8ef43cd8eb
audio  e3bf4bc1015c30431150acb9d70b418319ba7109caf98952942e2ada6f5b6daf
video  7c16ff3eb368dab477fafef9414cf3d6310dec334c6d8d3051bf04e5e2de0282
```

They also share three plan roots and three decode-receipt roots. Tests flip
every serialized byte of every fixture and plan, reject each mutation, then
re-root selected semantic contradictions to prove that valid checksums do not
override validation.

## Claim boundary

This milestone proves a fixed test container, sealed plan, bounded identity
decoder, and exact unit mapping for the retained tiny fixtures. It does not
prove:

- decoding of PNG, JPEG, WAV, FLAC, MP4, WebM, or another external format;
- safety of third-party codec libraries or compressed untrusted input;
- crop, resize, channel mix, resampling, frame selection, or synchronization
  within this decoder milestone; a separate retained transform prototype now
  implements a narrow crop/nearest/tile, weighted mix/exact-decimation, and
  keyframe-selection subset;
- model embeddings, attention state, inference quality, or generated media;
- durable media publication, capture, playback, or provider integration; or
- throughput, latency, memory, energy, token, or cost improvements.

## Next contributor slices

The next work should preserve the sealed-plan and mapping roots:

1. ~~image: deterministic crop/tile reference plan with source-region
   coverage;~~ complete for crop/nearest/tile over the retained RGB fixture;
2. ~~audio: exact channel-mix and rational-resample reference plan;~~ complete
   for weighted stereo-to-mono mix plus exact factor-three decimation;
3. ~~video: deterministic frame-selection plan over the keyframe/index
   surface;~~ complete for retained keyframe selection;
4. resource: bind exact output/scratch ceilings to a concrete
   `ResourceBank`/`LeaseTree` transaction;
5. publication: compose decoded bytes, ownership, timeline, and output visibility
   with complete abort cleanup; and
6. integration: retain one legal model fixture only after the production
   continuation gate is met.

See the [Shared Media Contract](MEDIA_CONTRACT.md) for identity and publication
semantics and the [Multimodal Roadmap](MULTIMODAL_ROADMAP.md) for promotion
gates. See [Deterministic Media Transforms](MEDIA_TRANSFORMS.md) for the
completed follow-on slice and its narrower claim boundary.
