# Generated Video Manifest and Display Acknowledgement

Status: **integrated model-free conformance path with bounded downstream
multi-segment registry continuity; production video models, external
codecs/containers, physical display evidence, and crash-atomic publication of
source records remain gated**.

Glacier can publish an ordered bounded raw-video segment, carry its outstanding
display receipt across a real process restart, and require exact application
acknowledgement before admitting the successor segment. The portable core owns
no display device, compositor, window server, network, provider, clock, or
filesystem authority.

## Contract

`src/core/generated_video_display.zig` defines seven canonical little-endian
wires:

| Wire | Bytes | Purpose |
| --- | ---: | --- |
| `GeneratedVideoStateV1` | 512 | Chains visible/displayed segment, frame, and timeline watermarks plus one pending segment |
| `GeneratedVideoManifestV1` | 736 | Binds two ordered frame roots, exact durations, geometry, renderer, source output, media object, predecessor state, and resource shape |
| `GeneratedVideoProvenanceV1` | 640 | Binds the published raw frames to the manifest, artifact, source result/output, renderer, tenant, and policy |
| `GeneratedVideoResultV1` | 672 | Binds atomic publication to provenance, frame roots, media identity, resource receipt, counters, and predecessor |
| `DisplayObservationV1` | 320 | Records an application sink's claim that it consumed the complete exact segment |
| `DisplayAckPlanV1` | 480 | Binds the observation to the pending result and pre-ack state |
| `DisplayAckResultV1` | 512 | Advances displayed segment/frame/timeline watermarks and chains publication and acknowledgement history |

The retained fixture uses two frame-major 2×2 gray8 frames with a `1/1000`
timeline base. Each manifest carries separate frame roots and positive
per-frame durations. Geometry, row stride, frame bytes, total output bytes,
source-output bytes, timeline addition, and logical units use checked
arithmetic. Production implementations may use other bounded shapes under a
new semantic contract; this fixture is not a general video format.

## Ordering and backpressure

State separates:

- committed `visible_*` watermarks;
- application-confirmed `displayed_*` watermarks;
- the one exact `pending_*` segment;
- the only legal successor segment, frame ordinal, and start tick.

An idle state requires visible and displayed positions to match. A pending state
requires exactly one additional visible segment, two exact frames, and a
timeline interval beginning at the displayed tail. `makeManifestV1` fails while
that interval is pending.

An acknowledgement must consume both frames and bind the exact publication
result, output root, segment/frame/timeline range, sink implementation and
instance, request challenge, and previous acknowledgement. Partial, foreign,
stale, or duplicate evidence leaves state unchanged.

## Publication transaction

`Session` performs one generated-video publication:

1. validate state, manifest, renderer, payload, and video `MediaObjectV1`;
2. reserve and commit the exact `ResourceBank` claim;
3. bind a generation-fenced publication session;
4. render into disjoint private output, provenance, and result buffers;
5. verify both ordered frame roots and revalidate every source, candidate,
   renderer, receipt, and state binding;
6. copy all visible bytes and replace state only at commit; and
7. scrub private candidates on commit, abort, renderer failure, or drift.

The reference renderer expands two unsigned fixture tokens into two constant
gray8 frames. It is a deterministic model-free fixture, not a generative-video
quality, compression, temporal-coherence, or performance claim.

## Process-restart proof

Run:

```sh
zig build generated-video-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The source process publishes frames filled with `3` and `7`, with durations
`2` and `3`, syncs state, manifest, provenance, result, media descriptor,
output, and PID files, releases its Bank, and exits with one pending
acknowledgement. A distinct target process:

1. decodes and cross-validates all retained records and both frame roots before
   creating its Bank;
2. proves the successor manifest is blocked;
3. rejects a rehashed one-frame observation without changing state;
4. acknowledges the first complete segment;
5. aborts one private successor and verifies unchanged visibility;
6. publishes frames filled with `11` and `13`, with durations `4` and `1`;
7. acknowledges the successor and rejects duplicate acknowledgement; and
8. finishes with two visible/displayed segments, four frames, timeline tick
   `10`, and zero Bank, live-allocation, and lease-tree ownership.

Each file and the containing directory are synced. The separate files are not
one crash-atomic filesystem transaction.

## Independent verification

`bench/generated_video_display.py` reconstructs all seven wires, ordered frame
roots, media identity, resource receipt, state transitions, and cross-language
golden roots without executing Zig. Its tests reject every single-byte
mutation, rehashed lineage contradictions, partial display, foreign output,
publication before acknowledgement, and duplicate acknowledgement.

## Evidence boundary

`DisplayObservationV1` is an application-supplied completion receipt. It proves
that Glacier accepted one canonical sink-bound observation and advanced its
logical display watermark exactly once. It does **not** prove that a physical
display showed a frame, that a compositor presented it, that a user saw it, or
that the sink behaved honestly.

Shared image/audio/video checkpoint selection is now integrated for fully
acknowledged video: a pending or partially displayed segment cannot enter the
checkpoint. One exact encoded video payload now also composes with its typed
member, the image/audio members, and the shared checkpoint in the canonical
eight-object payload archive. A separate registry ABI now composes two then
three video entries with multiple image/audio entries and exact encoded
payloads while preserving frame, timeline, and predecessor continuity and
binding opaque state/completion roots. Registry admission structurally
requires `completion_required`, `completed`, and a nonzero completion root; it
does not decode these display acknowledgement/state wires. Typed producer
validation, production image/audio/video encoder/container adapters,
external-format conformance, native Linux and separately scoped power-loss
campaigns, and authorized physical playback/display evidence remain. See
[Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md) and the
[Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md),
then the
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md).
