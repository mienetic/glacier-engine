# Deterministic Media Transforms

Glacier's first media-plane execution slice applies three bounded,
allocation-free reference transforms to the canonical image, audio, and video
fixtures. It proves plan sealing, exact source/output mappings, cross-language
roots, and fail-closed execution. It is not a production codec, signal-processing
library, or media-model integration.

## Supported operations

| Operation | Retained fixture | Exact behavior | Output unit |
| --- | --- | --- | --- |
| Image crop/nearest/tile | 2×2 RGB8 | crop `(1,0,1,2)`, nearest resize to 2×2, 1×1 mapping tiles | Pixel |
| Audio mix/decimate | 8 stereo s16le frames at 48 kHz | weights `(left=1,right=0)/1`, source frames `[0,6)`, exact integer factor 3 to 16 kHz mono | Output PCM frame |
| Video keyframe select | two 2×2 intra-frame gray8 frames at 30 fps | select verified keyframe index 1 | Output frame |

The image output is two green pixels followed by two white pixels. The audio
output contains signed samples `-16384` and `5461`. The video output is the
second frame, with bytes `ff 80 40 00`.

## Sealed transform plan

`TransformPlanV1` is a fixed 512-byte little-endian wire:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic `GMTRFM1\0` |
| 8 | 8 | Plan ABI |
| 16 | 8 | Exact wire bytes |
| 24 | 8 | Flags; currently zero |
| 32 | 8 | Operation |
| 40 | 8 | Media kind |
| 48 | 16 | Input and output representation IDs |
| 64 | 32 | Source, output, scratch bytes, logical units |
| 96 | 24 | Source axes |
| 120 | 24 | Target axes |
| 144 | 32 | Source and target rational time bases |
| 176 | 64 | Eight operation parameters |
| 240 | 32 | Media object root |
| 272 | 32 | Decode plan root |
| 304 | 32 | Decode receipt root |
| 336 | 32 | Decoded-source root |
| 368 | 32 | Transform implementation root |
| 400 | 32 | Resource-policy root |
| 432 | 32 | Challenge root |
| 464 | 8 | Required capabilities; currently zero |
| 472 | 8 | Reserved zero |
| 480 | 32 | Domain-separated plan root |

The plan cannot be reused with a different media object, decode plan, decode
receipt, decoded source, implementation, resource policy, or challenge.
Recomputing the footer does not make contradictory geometry, time, weights,
rates, selections, or byte counts valid.

## Execution contract

The executor:

1. parses the bounded fixture and sealed decode/transform plans;
2. checks output and mapping capacity before writing;
3. rejects input, output, source, or mapping memory overlap;
4. decodes into caller-owned storage;
5. reconstructs and verifies all plan-to-source bindings;
6. executes with no heap allocation and zero scratch for the retained plans;
7. produces one exact mapping per output pixel, PCM frame, or video frame; and
8. returns a receipt over the transform plan, decode receipt, source, output,
   mapping chain, and operation identity.

Image mappings identify the exact source pixel selected by nearest-neighbor
sampling. Audio mappings identify the complete source-frame interval and byte
range mixed into one output frame. Video mappings identify the selected source
frame, byte span, and source/target timeline ticks.

## Evidence

Run the native conformance demo:

```sh
zig build media-transform-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent Python oracle:

```sh
python3 -m unittest bench.tests.test_media_transform
```

Both implementations retain the same plan and receipt roots:

| Kind | Plan root prefix | Receipt root prefix |
| --- | --- | --- |
| Image | `d2f61e8923d642d9` | `97c68e6b178db4e7` |
| Audio | `202ed6b0ed607614` | `02f9d7547a276339` |
| Video | `9f64b26c5e926893` | `9e9fcce71a441969` |

Tests cover every serialized plan-byte mutation, a footer-rehashed semantic
contradiction, foreign fixture/decode-plan substitution, stale decode-receipt
identity, short destination capacity without mutation, and native overlapping
storage rejection.

## Claim boundary

This slice accepts only the retained canonical RGB8, interleaved stereo s16le,
and intra-frame gray8 fixtures. It does not provide interpolation filters beyond
nearest selection, general sample-rate conversion, arbitrary channel layouts,
compressed format decode, variable-frame-rate video, non-keyframe seeking,
capture, playback, filesystem/network access, accelerator execution, or model
execution.

It is the first implemented transform layer under the
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md) and
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md). The next composed layer is the
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md), which adds exact admission,
candidate revalidation, atomic publication, abort/retry, and release.
