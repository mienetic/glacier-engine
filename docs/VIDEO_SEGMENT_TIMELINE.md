# Canonical Video-Segment Timeline

Status: **integrated fixture**. Glacier can reduce an ordered chain of typed
video segments into a deterministic visible timeline. The retained proof
covers canonical overlap decisions, fixed state and receipt wires, exact
resource admission, transactional visibility, and cross-language verification.
It does not establish production event quality.

## Why timeline state is separate

`VideoSegmentV1` preserves the raw model result and its immediate predecessor.
After several overlapping results coalesce, however, the visible tail may start
earlier and end later than the newest raw segment. Using only that raw segment
for the next decision would lose part of the accumulated interval.

`VideoSegmentTimelineV1` therefore carries the current visible tail separately
from the immutable raw chain. Its fixed 384-byte wire records:

- request, next decision sequence, decision count, and visible segment count;
- latest raw segment index and root;
- accumulated tail frame/time bounds, event ID, and confidence;
- exact target time base;
- media, challenge, previous-decision, and merge-policy roots; and
- a root over the complete canonical state.

The state can be encoded and independently verified without pointers or native
layout dependencies. Durable file publication and fresh-process restore remain
separate future gates.

## Canonical decision policy

Every incoming result must be the exact next raw segment:

- index equals previous index plus one;
- `previous_segment_sha256` equals the previous raw segment root;
- request, media, challenge, and target time base match;
- generation does not move backwards;
- frame/time order does not move before the visible tail; and
- the timeline tail contains the latest raw segment it names.

After those checks, the policy has only two outcomes:

| Condition | Decision | Visible effect |
| --- | --- | --- |
| Same event and incoming interval overlaps or touches the tail | `coalesce` | Replace the tail with the union; visible count is unchanged |
| Time gap or different event | `retain_distinct` | Append the incoming result; visible count increases by one |

Coalescing keeps the earliest start, greatest frame/time end, shared event ID,
and maximum integer confidence. A different event remains distinct even when
its interval overlaps. A same-event result separated by a gap also remains
distinct. The policy does not invent missing coverage or choose semantic
priority between different events.

## Merge receipt

Each decision publishes one fixed 384-byte
`VideoSegmentMergeReceiptV1`. It binds:

- decision sequence and previous/incoming raw segment indices;
- action, output bounds, event, confidence, and measured overlap ticks;
- replaced-tail count and visible-segment delta;
- media, challenge, both segment roots, previous decision, and policy; and
- the canonical receipt root.

Receipts form their own chain while retaining both raw segment roots. Replaying
them reconstructs the same timeline without mutating the original model
results.

## Transactional runtime

The merge session admits an exact `ResourceBank` claim for one private
384-byte candidate, one 384-byte output journal, and one queue slot. Prepare
reserves a publication permit and writes only the candidate. Commit:

1. revalidates the permit and unchanged timeline state;
2. decodes and rechecks the complete candidate against both input segments;
3. computes the next canonical timeline before visibility;
4. copies the receipt to visible storage and advances state together; and
5. scrubs the candidate.

Abort and candidate drift publish nothing and preserve the prior timeline.
Closing the session releases the complete admitted claim to zero.

## Independent evidence

Zig and Python independently implement the policy, state/receipt encoders, and
roots. Both retain the same timeline and first-merge golden roots.
Mutation-complete tests flip every byte in both 384-byte wires and require
rejection.

Additional tests prove:

- repeated coalescing retains the accumulated start;
- same-event gaps remain distinct;
- overlapping different events remain distinct;
- foreign media, predecessor substitution, and skipped indices reject;
- abort and candidate drift leave state and visible output unchanged; and
- resource ownership returns to zero.

## Current boundary

The fixture consumes deterministic synthetic segments. The stateful VFR
continuation fixture now carries the timeline through a real process restart,
records a five-tick discontinuity explicitly, and commits `retain_distinct`
before advancing the cross-modal link. It does not run a useful event model,
infer labels, merge different event IDs, normalize external container
timestamps, or publish the complete file set through the atomic archive.

The next cross-modal source contract is now complete: one exact newly
publishable transcript range can link to the verified accumulated timeline
through [Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md). Stateful
video-model continuation is now integrated through
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md).

## Run the retained proof

```sh
zig test src/core/video_segment_timeline.zig -OReleaseSafe
python3 -m unittest bench.tests.test_video_segment_timeline
```

See [Typed Video-Segment Adapter](VIDEO_SEGMENT_ADAPTER.md),
[Stateful VFR Video-Model Continuation](STATEFUL_VIDEO_CONTINUATION.md),
[Typed Temporal-Video Encoder Adapter](TEMPORAL_VIDEO_ADAPTER.md),
[Exact Audio/Video Result Link](AUDIO_VIDEO_RESULT_LINK.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
