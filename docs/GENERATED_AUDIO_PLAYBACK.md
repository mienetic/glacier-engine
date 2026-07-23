# Generated Audio Publication and Playback Acknowledgement

Status: **integrated model-free conformance path; production synthesizers,
device playback, external codecs, and crash-atomic multi-file composition
remain gated**.

Glacier can publish bounded generated PCM chunks, carry an outstanding chunk
across a real process restart, and require an exact application acknowledgement
before admitting the successor chunk. The portable core owns no sound device,
network, provider, clock, or filesystem authority.

## Contract

`src/core/generated_audio_playback.zig` defines seven canonical little-endian
wires:

| Wire | Bytes | Purpose |
| --- | ---: | --- |
| `GeneratedAudioStateV1` | 448 | Chains timeline position, visible and acknowledged counts, one pending chunk, predecessors, policy, and challenge |
| `GeneratedAudioPlanV1` | 576 | Binds the source output, renderer, exact PCM shape, media object, predecessor state, and resource claim |
| `GeneratedAudioProvenanceV1` | 512 | Binds published PCM to the plan, artifact, source result/output, renderer, tenant, and policy |
| `GeneratedAudioResultV1` | 576 | Binds the atomic publication to provenance, PCM, media identity, resource receipt, counters, and predecessor |
| `PlaybackObservationV1` | 288 | Records an application sink's claim that it consumed the complete exact buffer |
| `PlaybackAckPlanV1` | 448 | Binds that observation to the outstanding publication and pre-ack state |
| `PlaybackAckResultV1` | 512 | Advances acknowledged chunks/frames and chains both publication and acknowledgement history |

The retained fixture uses raw interleaved PCM s16le. A chunk is bounded to
4,096 frames, 64 channels, a 768 kHz declared sample rate, and the checked
product of frames, channels, and two bytes per sample. Unsupported or
overflowing shapes fail before resource admission. The plan separately binds
the exact source-output byte count and charges that count as activation
ownership, so a renderer with a wider source representation cannot understate
its admitted input.

## Ordering and backpressure

State distinguishes four positions:

- `visible_chunks` and `visible_frames` count committed PCM;
- `acknowledged_chunks` and `acknowledged_frames` count buffers the application
  reports as fully consumed;
- `pending_*` identifies the single committed buffer awaiting acknowledgement;
- `next_chunk_index` and `next_start_frame` identify the only legal successor.

An idle state requires visible and acknowledged positions to be equal. A
pending state requires exactly one additional visible chunk and an exact frame
interval beginning at the acknowledged tail. `makePlanV1` rejects while that
pending interval exists. This makes playback acknowledgement an explicit
backpressure gate rather than an advisory event.

Partial observations are invalid. An acknowledgement must bind the complete
frame count, PCM root, publication-result root, sink implementation and
instance identities, playback sequence, request challenge, and previous
acknowledgement. Rejected or duplicate acknowledgements leave state unchanged.

## Publication transaction

`Session` performs one generated-audio publication:

1. validate state, plan, renderer, payload, and audio `MediaObjectV1`;
2. reserve and commit the exact `ResourceBank` claim;
3. bind a generation-fenced publication session;
4. render into disjoint private PCM, provenance, and result buffers;
5. revalidate every source, candidate, renderer, receipt, and state binding;
6. copy all visible bytes and replace state only on commit; and
7. scrub private candidates on commit, abort, renderer failure, or drift.

The reference renderer deterministically converts one unsigned audio token per
sample into little-endian signed PCM. It is a legal model-free fixture, not a
text-to-speech, codec, music, or quality claim.

## Process-restart proof

Run:

```sh
zig build generated-audio-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
```

The source process publishes two mono frames (`256`, `-256`), syncs the fixed
state, result, PCM, and PID files, releases its Bank, and exits with one pending
acknowledgement. A distinct target process:

1. decodes and verifies state/result/PCM before creating its Bank;
2. proves that the next publication is blocked;
3. rejects a rehashed partial observation without changing state;
4. acknowledges the first exact buffer;
5. aborts one private successor candidate and verifies unchanged visibility;
6. publishes two more frames (`512`, `-512`);
7. acknowledges the successor and rejects duplicate acknowledgement; and
8. finishes with two visible and two acknowledged chunks, four exact frames,
   and zero Bank, live-allocation, and lease-tree ownership.

The demo syncs each file and the containing directory. Those separate files are
not one crash-atomic filesystem transaction.

## Independent verification

`bench/generated_audio_playback.py` reconstructs all seven wires, resource
receipt identity, media descriptor, reference PCM, state transitions, and
cross-language golden roots without executing Zig. The corresponding tests
reject every single-byte mutation, rehashed plan/provenance contradictions,
partial consumption, foreign output substitution, publication before
acknowledgement, and duplicate acknowledgement.

## Evidence boundary

`PlaybackObservationV1` is an application-supplied completion receipt. It proves
that Glacier accepted one canonical, sink-bound observation and advanced its
logical output state exactly once. It does **not** prove that a physical audio
device emitted sound, that a user heard it, or that the sink behaved honestly.
Production device evidence requires a separately authorized adapter and its own
capability, failure, timing, privacy, and calibration policy.

Next work is production renderer/codec integration, multi-chunk manifests,
crash-atomic output/checkpoint composition, partial-buffer policy where a
product explicitly needs it, and physical playback adapters outside the
authority-free core.

The sibling ordered raw-video path is specified in
[Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md).
