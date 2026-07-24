# Scheduled Media Pressure

Glacier's scheduled-media pressure layer connects the deterministic
mixed-media workload to real bounded media transactions. It preserves the
existing WorkloadPressure V1 scenario and result bytes, then emits an additive
Evidence V1 sidecar for the image, audio, and video work that actually reaches
its final service quantum.

The retained campaign answers:

> Did one admitted receipt remain the sole resource authority from scheduling
> through media publication and terminal release, and did only completed work
> produce visible media output?

This is portable execution conformance. It is not a wall-clock throughput,
tail-latency, model-quality, codec-quality, physical-memory, power, or soak
measurement.

## Execution boundary

Each accepted workload item immediately binds its scheduler-owned
`ResourceBank` receipt to an address-stable media session. The media session
does not reserve or commit a second receipt.

Earlier service quanta remain scheduling budget. On the final quantum only:

1. the retained fixture is decoded into caller-owned provisional storage;
2. its sealed image, audio, or video transform runs;
3. output and source mappings are revalidated;
4. the media publication and final `LaneWeave` service event commit through one
   armed finalizer; and
5. the bound session closes and the scheduler retires the sole receipt.

Cancellation and timeout close the publication fence and release the same
receipt atomically without executing or publishing media. Admission rejection
never creates a media session.

The reference campaign therefore executes exactly:

| Work item | Final trace index | Output | Mappings |
| --- | ---: | --- | ---: |
| Audio 1 | 25 | `00c05515` | 2 |
| Video 2 | 29 | `ff804000` | 1 |
| Image 6 | 31 | `00ff0000ff00ffffffffffff` | 4 |

Image 0 is cancelled, Audio 3 times out before service, and Video 4/Image 5 are
rejected. None has an execution record or media publication.

## Single-receipt ownership

The five accepted items retain the scheduler's original receipt identities:

| Item | Slot | Generation | Owner |
| --- | ---: | ---: | ---: |
| Image 0 | 0 | 1 | `0x3001` |
| Audio 1 | 1 | 2 | `0x3002` |
| Video 2 | 2 | 3 | `0x3003` |
| Audio 3 | 3 | 4 | `0x3004` |
| Image 6 | 0 | 5 | `0x3007` |

The completed execution receipts carry those same Bank epochs, slots,
generations, owners, claims, and integrity values. The campaign still reports
five Bank commits and five releases, rather than adding three media-specific
admissions. Final active reservations, committed receipts, and orphan
ownership are zero.

`Bank.closePublicationSessionAndRelease` performs the bound close and release
under one Bank lock. `Scheduler.cancelBoundPublication` and
`Scheduler.retireBoundPublication` retain the existing scheduler event
semantics while using that atomic terminal transition.

## Atomic final service

Media candidate validation is fallible and happens before the scheduler
finalizer is invoked. Once armed, the remaining finalizer suffix contains only
bounded state assignments, publication commit, and permit consumption.

If candidate validation, receipt validation, or service arming fails, the
media publication permit and scheduler permit are aborted, provisional buffers
are scrubbed, logical time does not advance, and the request can retry the same
final service intent. The runtime tests include candidate drift followed by an
exact retry.

Sessions, transactions, publication state, and their caller-owned buffers must
remain address-stable from binding through terminal close. The current path
adopts a flat `ResourceBank` receipt; active child leases and `LeaseTree`
authority are rejected rather than silently flattened.

## Evidence V1

The sidecar is independent of the frozen workload wires:

```text
288-byte header
+ item_count × 288-byte item record
+ execution_count × 992-byte execution record
+ 160-byte summary
+ 32-byte footer
```

The retained seven-item/three-execution wire is 5,472 bytes.

The header binds the workload scenario, outcome, trace, and summary roots plus
ordered item, execution, and media-summary roots. Every item record binds its
workload item, admission and terminal trace records, exact receipt identity,
and optional execution index. Every execution record binds the final service
trace position and logical counters, before/after media-state roots, exact
output root, and the complete 640-byte media execution receipt.

The summary records:

- seven items, five admissions, and two rejections;
- three completions, one cancellation, and one timeout;
- one image, one audio, and one video execution;
- seven transformed logical units and 20 output bytes;
- three media publications and five closed admitted sessions;
- four maximum simultaneously live receipts; and
- zero orphan ownership.

Zig and the independent Python implementation agree on these retained roots:

| Root | SHA-256 |
| --- | --- |
| Item records | `3d55ecbeea1a131ed7f6562ec3d33259c157a6cbc3c194cf4f80b2318c73b4e9` |
| Execution records | `46799e4e2b46c3b0152e7784a35389bc790f43999d01095c4467ed153152dd11` |
| Summary | `d832947ba869dec833e983178ce0cc67f725cccd783eeb5fbecfa61b2450b027` |
| Complete evidence | `f6d17a0d6471379c61bd38a5ac255c88f14dfb7585e150cda85b8d04631b880b` |

Both implementations reconstruct receipt allocation, rerun the retained media
rules, verify complete execution receipts, and reject mutation, truncation,
reordering, substitution, and rehashed semantic contradictions.

## Run the retained gate

```sh
zig test src/core/scheduled_media_pressure.zig -OReleaseSafe
python3 -m unittest bench.tests.test_scheduled_media_pressure
```

The module is exported through both package surfaces as
`glacier.scheduled_media_pressure` / `glacier.ScheduledMediaPressure` and
`glacier_core.scheduled_media_pressure` /
`glacier_core.ScheduledMediaPressure`.

## What this proves

The campaign performs real deterministic fixture decode, image/audio/video
transform, mapping verification, transactional media publication, terminal
release, and cross-language evidence construction under the real scheduler and
Bank.

It does not yet perform:

- production model inference or a family model-adapter lifecycle;
- PNG, WAVE, APNG, or general external-container decoding in the scheduled
  path;
- asynchronous workers, threaded queues, batching, or accelerator overlap;
- native requests per second or p50/p95/p99 timing;
- physical RSS/device memory, power, thermal, or long-duration soak evidence;
- physical audio playback, video display, or visual/audio quality evaluation;
  or
- durable recovery while a scheduled media transaction is armed.

## Contributor follow-ups

The shared workload and native-measurement sequence is tracked in the
[Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md). The next bounded extensions
can proceed independently:

1. drive the completed scheduled vision/audio/temporal-video adapter lifecycle
   through one mixed typed workload profile;
2. add generated workloads without changing Evidence V1 semantics;
3. add a separately versioned closed-loop arrival contract;
4. add family-aware batching and safe preemption points;
5. schedule strict external PNG/WAVE/APNG ingestion under explicit byte and
   geometry ceilings;
6. add native per-OS observers for timing, CPU, memory, power, and thermals; and
7. add bounded soak and disruption campaigns with the same zero-orphan gate.

See [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Benchmark and Evidence Guide](BENCHMARKS.md) for the surrounding contracts and
promotion rules.
