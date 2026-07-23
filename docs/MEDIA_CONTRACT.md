# Shared Media Contract

Status: **model-free prototype**.

Glacier has one authority-free contract for image, audio, and video identity,
checked rational positions, explicit timeline events, and ordered chunk
publication. It gives future decoders, models, provider adapters, and generated
media paths a common substrate without placing filesystem, network, camera,
microphone, or device access in the portable core.

This contract module does not decode media or run a multimodal model. The
companion [Bounded Media Decode Fixtures](MEDIA_DECODE_FIXTURES.md) now exercise
sealed plans and identity decoding for three tiny canonical inputs; external
formats and model execution remain outside both prototypes.

## What the prototype provides

- one fixed 272-byte `MediaObjectV1` wire for image, audio, and video;
- content, tenant, metadata-policy, and provenance roots kept as separate
  identities;
- kind-specific geometry and time-base rejection before identity is accepted;
- canonical rational time bases and exact integer-only position conversion;
- explicit timeline events for identity, trim, pad, resample, frame selection,
  and reorder;
- a prepare/commit publication chain binding output and resource-claim roots;
- exact-once sequence, chunk, logical-unit, timeline, and commit advancement;
- a model-free Zig demo and independent Python contract model; and
- mutation-complete verification of every descriptor byte.

## Media object wire

The descriptor contains identity and bounded semantic declarations, never the
payload itself:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GMOBJ01` magic |
| 8 | 8 | descriptor ABI |
| 16 | 8 | exact encoded length |
| 24 | 8 | flags; v1 requires zero |
| 32 | 8 | media kind |
| 40 | 8 | semantic ABI |
| 48 | 8 | exact payload byte length |
| 56 | 8 | container identity |
| 64 | 8 | codec identity |
| 72 | 24 | three kind-specific axes |
| 96 | 16 | rational time-base numerator and denominator |
| 112 | 32 | tenant-scope root |
| 144 | 32 | content root |
| 176 | 32 | metadata-policy root |
| 208 | 32 | provenance root |
| 240 | 32 | domain-separated descriptor root |

All integers are unsigned 64-bit little-endian values. The footer is SHA-256
over the domain and the exact first 240 bytes. Decoding requires the exact
length, known ABI and kind, zero reserved flags, valid footer, and consistent
kind-specific fields.

The current axes are deliberately small:

| Kind | Axis 0 | Axis 1 | Axis 2 | Time base |
| --- | --- | --- | --- | --- |
| Image | width | height | channels | static `0/1` |
| Audio | frame count | channels | sample rate | `1/sample_rate` |
| Video | width | height | frame count | canonical positive rational |

Image channels are currently bounded to four. Audio channels are bounded to 64
and sample rate to 768,000. These are descriptor admission limits, not a claim
that codecs or model paths for every admitted value exist.

Container and codec values are typed identities, not ambient decoder selection.
A future registry and sealed `MediaDecodePlan` must define their semantics
before an execution path can be integrated.

## Exact rational timeline

A `TimeBaseV1` is a reduced positive fraction:

```text
seconds per tick = numerator / denominator
```

A static image descriptor alone may use `0/1`; timeline positions may not.
Timeline spans require one canonical base and `start < end`.

Conversion from a source position to a target base uses checked integer
arithmetic:

```text
target_ticks =
  source_ticks × source_numerator × target_denominator
  ---------------------------------------------------
       source_denominator × target_numerator
```

The conversion succeeds only when the quotient is integral and fits in `u64`.
There is no floating-point rounding and no nearest-sample fallback. The fixture
maps 48,000–96,000 ticks at `1/48000` exactly to 16,000–32,000 ticks at
`1/16000`; mapping one 48 kHz sample into a 44.1 kHz base rejects because it is
not integral.

Each `TimelineEventV1` binds:

- event kind and exact sequence;
- media-object root;
- source and target spans;
- preprocessing-plan root; and
- previous event root.

The domain-separated event root makes trim, padding, resampling, frame
selection, and reordering explicit history rather than invisible decoder
behavior. The current validator constrains identity and non-expanding
trim/frame-selection events. Rich region, gap, overlap, and synchronization
policies remain later slices.

## Publication transaction

`PublicationStateV1` tracks one request epoch, next sequence, visible chunk
count, visible logical units, timeline base, media object, timeline head, and
previous commit.

`preparePublicationV1` accepts only an event that:

- has the exact next sequence and media-object identity;
- extends the current timeline head;
- starts at the exact visible-unit boundary;
- uses the declared target time base; and
- supplies non-zero output and resource-claim roots.

The prepared commit binds all of those values plus the state-before root, chunk
ordinal, unit range, event root, output root, resource-claim root, and prior
commit. `commitPublicationV1` revalidates the complete prepared value before an
infallible bounded mutation suffix advances state.

Replaying a committed value, substituting a root, skipping a unit boundary, or
using an exhausted sequence rejects without changing publication state.

The resource-claim root is evidence binding in this prototype. This module does
not itself reserve or release a `ResourceBank`, store output bytes, or publish a
file. Integration must compose those concrete transitions and prove abort
cleanup before the media transaction can be promoted beyond prototype.

## Run the conformance demo

```sh
zig build media-contract-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_media_contract
```

The demo is deterministic, model-free, credential-free, allocation-free in the
contract path, and requires no media device. It reports three accepted object
kinds, exact rational mapping, two visible chunks, stale-replay rejection, and
the final object/timeline/publication roots.

The Zig and Python implementations share these golden roots:

```text
audio object
255d59c3ad202eececf7c206583ad3ef62cda5f3710966aa0f7cf3c4079285f5

first publication
d26ae55bd2f88036e829c725d91c448bf5efafad20710f7bc84334e611157fb6
```

The suites also flip every byte in the descriptor and require rejection, then
re-hash an invalid reserved flag to prove that semantic validation is separate
from checksum validation.

## Claim boundary

This contract prototype proves deterministic identity, timeline, and
publication behavior for tiny synthetic values. By itself it does not prove:

- external-format media decoding, encoding, capture, playback, rendering, or
  generation;
- compatibility with a particular container, codec, model, or provider;
- image region or audio/video synchronization correctness;
- lower latency, memory, storage, energy, provider tokens, or cost;
- durable publication or restart recovery for media chunks; or
- safety of untrusted compressed payloads.

The companion fixture prototype adds sealed plans and bounded identity decode
for three retained canonical inputs. Broader claims still require external
format parsers, concrete resource ownership, transform reference models, crash
campaigns, and model/provider integration evidence.

## Contributor slices

The foundation makes several independent contributions possible:

1. extend the completed tiny RGB, PCM, and intra-frame video fixture baseline
   with additional legal edge cases whose manifests resolve to `MediaObjectV1`;
2. define a versioned container/codec identity registry without linking decoder
   choice to ambient host state;
3. extend the completed sealed `MediaDecodePlan` with transform-specific
   constraints while retaining exact output and scratch ceilings;
4. extend timeline validation for image regions, audio gaps/overlaps, and
   audio/video synchronization;
5. connect a prepared publication to real `ResourceBank` ownership and prove
   complete abort cleanup; and
6. add privacy-safe evidence rendering for verified media roots and ranges.

Each slice should remain model-free where possible, reject unsupported
combinations explicitly, and name both its authority and its nonclaims. The
sequencing and promotion gates are in the
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md).
