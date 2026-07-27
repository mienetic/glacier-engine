# Architecture

Glacier Engine separates AI computation from the authority to consume resources
and publish state. Computation may be speculative; externally visible state is
not. The resulting system is a full AI Runtime architecture spanning artifacts,
execution, resources, scheduling, continuation, media, providers, publication,
evidence, policy, and distribution rather than a model-inference loop alone.

## Component map

| Layer | Primary components | Responsibility |
| --- | --- | --- |
| Family adaptation | future `ModelFamilyAdapter`, operation registry, typed state/output adapters | Describe family-specific artifacts, planning, state, candidate validation, and publication units without expanding authority |
| Model | `.glacier`, `.glrt`, loader, prepared model | Validate source and execution layouts before use |
| Execution | CPU kernels, optional Metal backend, DecodePlan, sealed media plans | Produce candidate activations, KV rows, tokens, tensors, or media outputs under explicit bounds |
| Device selection | `DeviceCapabilityV1`, canonical inventory, plan-bound requirement, selection receipt | Choose one compatible present CPU or accelerator deterministically before admission without granting allocation, queue, dispatch, or publication authority |
| Device lifecycle observation | `ObservationV1`, `TransitionReceiptV1`, native Metal lifecycle snapshot | Bind a source-specific native or synthetic fact to one exact prior present inventory and derive only a capability- and policy-preserving newer `unavailable` or `lost` entry; fail new native work closed without granting release, quarantine-clear, fresh-selection, recovery, or migration authority |
| Device-loss dispatch reconciliation Phase A | `LossDispatchRetentionV1`, `LossDispatchReconciliationPlanV1`, exact terminal/completion settlement, `LossDispatchReconciliationReceiptV1` | Join one exact command-specific native `5/1/11` loss to its retained terminal-failure dispatch and settle the Bank pin before exact native-command finalization without granting output, migration, reset, or reclaim authority |
| Device-loss dispatch callback retirement Phase B | `LossDispatchCallbackRetentionV1`, `LossDispatchCallbackRetirementPlanV1`, `LossDispatchCallbackFenceV1`, `LossDispatchCallbackRetirementReceiptV1`, ARC-owned native callback gate | Detach the exact callback target without waiting for callback exit while retaining the native command record, authorize only zero-output ownership retirement, settle the Bank pin before exact native unlink, and preserve replay while leaving allocation retirement separate |
| Phase B retirement diagnostics | `MetalDispatchRetirementTelemetryV1`, production native snapshot | Directly observe successful native prepare/commit transitions and replay, frozen native facts, detachment, live/retired ownership, tombstones, generations, and saturation without becoming lifecycle, retirement, completion, output, release, or migration authority |
| Device-loss retirement | `LossRetirementPlanV1`, private native permit, ordinary LeaseTree release, `LossRetirementReceiptV1` | Bind one exact lost source and quiesced allocation, drop retained native references before logical Bank uncharge without post-loss property reads, and grant no physical-reclaim, output, migration, reset, or residency authority |
| Device allocation and dispatch contracts | Adapter-quoted manifest, `ResourceBank.ChildLease`, additive `LeaseTree`, exact object-set pins, async ticket/quarantine/failure evidence, opaque object set, live/recovery/terminal receipts | Charge exact replayed accounting bytes before callbacks, retain charge through cleanup uncertainty, reject stale or substituted ownership, bind per-adapter single-flight Metal completion to exact Bank settlement, and authorize one exact quarantined native `.error` as core `terminal_failure` without releasing ownership early; native gates create, dispatch through, and directly inspect real buffers, while production-symbol-isolated fault gates keep physical success or real resources separate from test-only overlays and prove exact settlement retry without claiming residency, physical device failure, general scheduling, or performance |
| Resource | `ResourceBank`, additive and receipt-funded `LeaseTree` modes | Reserve exact logical capacity and track allocation ownership without ambiguous duplicate charge |
| Schedule | `LaneWeave` | Admit requests and issue deterministic service permits |
| Workload conformance | open-loop W0, scheduled-media W1, generated-corpus W2, closed-loop W3, typed-workload W4a, typed tool W4b-a, ActionOutbox W4b-b/W4b-c/W4b-d | Replay bounded admission, service, terminal outcomes, lifecycle callbacks, typed publication, process-local effect delivery, uncertain external-action handoff, generation-fenced fake reconciliation, and durable storage faults without presenting logical steps as native performance |
| State | contiguous/paged KV, token transactions | Prepare and atomically publish AI-visible state |
| Continuation | capsule, resolver, bundle, store, collection planner, sweep journal/commit/record/writer, payload file, ownership/KV/runtime state, checkpoint archive and selector | Bind complete checkpoint generations, atomically select one root, reacquire charged ownership, and resume publication across a process boundary |
| Media | `MediaObjectV1`, sealed decode/transform plans, bounded fixture executor, `MediaRuntimeTxn`, `MediaRuntimeLease`, `MediaStreamRuntime`, `MediaStreamContinuation`, `MediaStreamCheckpointSet`, `MediaProcessorState`, `MediaProcessorCache`, rational positions, timeline events, publication state | Bind image/audio/video identity and bounds, own buffers and caches exactly, advance bounded chunk chains, atomically select complete generations, and resume outputs plus processor caches after process death |
| Model adapters | `ModelContract`, `StatelessModelAdapter`, `StatefulModelAdapter`, `StatefulModelContinuation`, `VisionEncoderAdapter`, `AudioWindowAdapter`, `AudioTranscriptAdapter`, `StatefulTranscriptAdapter`, `AudioTranscriptContinuation`, `SpeechAnnotationPublication`, `TemporalVideoAdapter`, `VideoSegmentAdapter`, `VideoSegmentTimeline`, `StatefulVideoAdapter`, `VideoModelContinuation`, `AudioVideoResultLink`, `LatentStepAdapter`, `GeneratedImagePublication`, `GeneratedAudioPlayback`, `GeneratedVideoDisplay`, `GeneratedMediaCheckpoint`, `GeneratedMediaPayloadArchive`, `GeneratedMediaOutputRegistry`, `GeneratedMediaProducerAdmission`, producer-transition replay/evidence | Separate vocabulary from support, bind exact tensor/resource/source schemas, isolate caller-owned candidates, validate typed generated outputs and exact raw bytes, replay retained deterministic producer transitions, and publish only through explicit family and atomic visibility boundaries |
| Provider | context pack, gateway, transport harness | Reconcile tokens, coalesce work, cancel, and settle usage |
| Agent and tool action | `ToolActionContract`, fixed-storage tool harness, ActionOutbox record/recovery, POSIX file store, pointer-free adapter contract, dispatch driver, bounded fake authority | Keep model proposals separate from local authorization, publish bounded process-local effects atomically, durably retain external dispatch uncertainty, and allow retry only after status atomically fences the attempted generation |
| Durability | settlement/cost wires, cost journal, ActionOutbox snapshot/lease/repair roots | Commit replayable cost and external-action evidence across process failure without granting external-effect authority |
| Native observation | `NativeObservationContract`, `NativeObservationRunner`, host/device observer adapters | Bind workload and machine identity to explicit metric availability, admit before execution, keep per-record sample-clock identity distinct from time-metric value-clock identity, and retain contamination without granting portable records execution authority |
| Evidence | event wires, join roots, Python verifiers | Reconstruct and reject malformed or substituted history |

## Local execution flow

```text
validated model + request + sealed execution plan
          │
          ▼
 device requirement + canonical capability inventory
          │ incompatible / malformed
          ├────────────────────> reject; no resource or scheduler mutation
          │ selected receipt (decision evidence only)
          ▼
   derive exact logical claim
          │
          ▼
 ResourceBank admission ──reject──> no resource mutation
          │ receipt
          ▼
 LaneWeave admission ─────reject──> release receipt
          │ service permit
          ▼
 speculative execution
          │ prepared KV/RNG/output
          ▼
 publication transaction ─abort───> no visible mutation
          │ commit
          ▼
 new KV root + RNG + counters + output + receipt
          │
          ▼
 ContinuationCapsule ──> model/plan/resource/lane/KV/sampler/output roots
          │
          ▼
 bounded object resolver ──> verified caller-owned bytes; no live authority
          │
          └─ canonical bundle ──> tenant blob roots + dedup ordinals; no I/O
                       │
                       └─ bounded object store ──> owned bytes + references
                                  │
                                  └─ dry-run collection ──> retained/eligible evidence
                                              │
                                              └─ sweep prepare/abort ──> staged evidence
                                                          │
                                                          └─ scoped atomic commit ──> exact removal receipt
                                                               └─ fixed body/footer evidence record
                                                                    └─ anchored recovery + scoped writer model
                                                                         └─ locked descriptor-relative file
                                                                              └─ durable payload plan + promotion
                                                                                   └─ immutable checkpoint archive
                                                                                        └─ atomic root selector
                                                                                             └─ ownership + KV + runtime resume
```

## Shared media flow

```text
untrusted media declaration
          │
          ▼
fixed MediaObject decode ──reject──> no accepted identity
          │ object root
          ▼
sealed DecodePlan + bounded fixture
          │
          ├─ foreign decoder/object/bounds ──reject──> output unchanged
          │
          ▼
sealed TransformPlan
 crop/nearest/tile │ weighted mix/exact decimation │ keyframe select
          │
derive exact activation/output/staging/I/O claim
          │
          ├─ over capacity ──reject──> no reservation or output mutation
          │
          ▼
ResourceBank reservation + publication session
          │
          ▼
decode + transform into provisional caller-owned buffers
          │
          ├─ stale source/root/bounds/geometry ──> scrub buffers
          ├─ abort/candidate drift ──> scrub buffers; keep prior state
          │
          ▼
reverify output + every source mapping + transform receipt
          │
          ▼
exact rational source span + explicit transform event
          │
          ├─ non-integral/invalid mapping ──reject──> no timeline change
          │
          ▼
prepared media publication
  output root + resource-claim root + prior timeline/commit
          │
          ├─ stale/substituted/overlapping state ──reject──> unchanged state
          │
          ▼
next media/resource sequences + chunk count + logical units
          │
          ▼
fixed runtime receipt + exact ResourceBank release
```

The shared media layer is an integrated model-free runtime vertical. It verifies
descriptors, sealed decode and transform identity, exact logical resource
claims, provisional output, every source mapping, integer-only positions, event
lineage, and logical publication state before a single-owner commit. The
hierarchical variant gives decoded source, mappings, scratch, and output their
own generation-fenced allocation leaves. Abort scrubs and retires every dynamic
allocation; after commit, provisional allocations can retire while the output
lease remains live. Closing returns the tree and parent Bank receipt to zero.
The fixed runtime receipts let independent verifiers reconstruct the ownership,
transform evidence, timeline event, publication commit, and output.

`MediaStreamRuntime` composes up to four address-stable hierarchical chunk
sessions. Every declared target interval must begin at the current visible unit
and have the exact sealed-plan length. Each successful chunk retires provisional
buffers, retains its output lease, and appends a fixed predecessor-bound stream
receipt. Cancellation closes only the unpublished chunk and leaves the prior
timeline and outputs unchanged.

`MediaStreamContinuation` serializes that boundary into a fixed 2,048-byte
checkpoint. A source process can sync the checkpoint and retained output bytes,
release its Bank, and exit. A fresh target Bank reserves output ownership as
unmaterialized, verifies exact bytes, commits it live, reconstructs the media
timeline, and starts `MediaStreamRuntime` at the next global chunk index. The
native proof performs this transition under distinct PIDs and Bank epochs for
image, audio, and video.

`MediaStreamCheckpointSet` joins the three fixed checkpoints with canonical
retained-output, processor-state, and processor-cache bundles inside the
immutable checkpoint archive. One selector rename publishes the complete
multimodal generation. The source produces two
lineage-bound generations; native workers die after all seven archive/selector
durability phases, and fresh targets resume whichever complete generation is
selected before idempotent recovery converges to the successor. Another fresh
worker restores generation two, binds the retained leases to its new Bank
epochs, appends all three modality chunks, and publishes generation three.
The next process opens that root and resumes again.

`MediaProcessorState` adds a separate canonical state plane for the work
between bounded decode and future model adapters. Three fixed modality records
bind image tile/patch progress, audio feature windows, and video temporal-cache
windows. A fourth record maps audio/video cursors to one exact integer master
clock and binds the committed watermark, skew ceiling, ownership set, output
set, sync policy, and predecessor. The complete state bundle is 2,272 bytes and
has an independent verifier. Stateful media checkpoints store it as the fifth
archive object and cross-bind every processor record to the matching stream
checkpoint before advancing both lineages through generation three.
`MediaProcessorCache` adds the sixth object, verifies exact payload bytes
against those records, and uses fresh-Bank `activation_bytes` allocations to
keep all caches unmaterialized until verification succeeds.
`ModelContract` then gives model families fixed artifact, operation-plan, and
result records without treating vocabulary as execution support.
`VisionEncoderAdapter` is the first bounded implementation: it requires a live
owned image cache, executes an exact-integer fixture into provisional storage,
revalidates the candidate, and publishes one typed embedding or scrubs it.
`StatelessModelAdapter` supplies the reusable admission, private-candidate,
revalidation, publication, abort, and release lifecycle used by all three
retained perception adapters.
`AudioWindowAdapter` is the second family binding: it validates live audio
features plus exact sample/window/hop lineage before entering the lifecycle.
`AudioTranscriptAdapter` accepts a context-bearing cache through a canonical
overlap plan. It marks prefix samples as conditioning-only, binds the new sample
range and previous transcript root, and publishes a fixed transcript wire
without duplicating text for the overlap.
`StatefulTranscriptAdapter` moves the same operation onto the shared retained
state lifecycle. `AudioTranscriptContinuation` composes its generic model-state
checkpoint with the previous/next overlap plans, transcript predecessor, video
timeline, and cross-modal link state. A fresh process charges the 32-byte model
state before materialization, publishes the exact next sample range, advances
the link predecessor, and releases every target owner.
`SpeechAnnotationPublication` layers bounded word timing and speaker attribution
over those canonical transcript records. Fixed state, plan, and result wires
bind text offsets to exact sample ranges, first-occurrence speaker identities,
confidence, media/cache lineage, and predecessors. A fresh process validates
the persisted state before admission, aborts one private candidate, publishes
the next word/turn once, and releases its claim to zero.
`TemporalVideoAdapter` adds a canonical strided-frame selection. It binds
keyframe lineage, eviction boundary, cache generation, and an exactly mapped
target span, gathers only selected frames into charged caller-owned scratch,
scrubs the gather buffer on every return, and then enters the same publication
lifecycle.
`VideoSegmentAdapter` turns that verified selection into a fixed typed event
result. `VideoSegmentTimeline` preserves the immutable raw result chain while
reducing same-event overlap into a separate accumulated visible tail.
`StatefulVideoAdapter` adds a canonical VFR window whose active frame ordinals,
PTS values, durations, keyframe flags, feature payload, timestamp payload, and
declared predecessor gap are all fixed before execution.
`VideoModelContinuation` composes that source contract with retained model
state, the previous typed segment, visible timeline, two transcript ranges, and
the exact result-link predecessor. A fresh process charges the 48-byte state
before materialization, publishes the successor segment at the declared frame
and tick boundary, commits the deterministic gap decision, advances the
cross-modal link, and releases every owner.
`AudioVideoResultLink` then maps only the transcript's newly publishable sample
range onto that visible tail using exact integer time conversion. Positive
overlap, both media identities, processor/cache/timeline lineage, one challenge,
and the link predecessor must all verify before its fixed result and successor
state become visible together.
`StatefulModelAdapter` adds a distinct retained-state transaction. It pins the
model and state publication roots, executes into disjoint output/state
candidates, revalidates both, and makes the typed result plus successor state
visible together. `LatentStepAdapter` retains the first exact synthetic
denoise-step fixture over that lifecycle. `StatefulModelContinuation` binds the
intermediate model/state publications into a fixed checkpoint, charges a fresh
`LeaseTree` before materializing the retained latent in another process, and
chains the terminal step at the exact next result sequence.
`GeneratedImagePublication` is the first generative-media consumer of that
terminal state. Its fixed plan verifies the complete checkpoint, terminal
plan/result/state, latent, decoder, tenant/policy, and media predecessors before
admission. Decode occurs in disjoint private storage. Abort or drift scrubs all
candidates; commit copies raw pixels, provenance, and the typed result while
advancing the media timeline exactly once. The native proof performs the
terminal step and image publication in a fresh process and closes with zero
target ownership.
`GeneratedAudioPlayback` publishes bounded raw PCM behind one pending-buffer
gate, while `GeneratedVideoDisplay` publishes an ordered two-frame manifest
behind one pending-segment gate. Both render into private storage, bind exact
source/media/resource lineage, reject partial or duplicate application
observations, and prove successor publication across distinct processes.
Application acknowledgement advances logical backpressure; it does not prove
physical playback or display.
`GeneratedMediaCheckpoint` normalizes the completed image and acknowledged
audio/video outputs into one typed three-member generation.
`GeneratedMediaPayloadArchive` then places one fixed payload manifest, that
checkpoint, the three members, and three exact encoded payloads into one
canonical eight-object archive. The manifest keeps raw source-output roots,
encoded-payload roots and lengths, encoder implementation, format, scope,
policy, challenge, and predecessor lineage explicit. The generic
checkpoint-file selector is the sole filesystem visibility authority. Seven
publisher deaths select only the exact predecessor five times or successor
twice before idempotent recovery; the independent Python oracle verifies the
same archive without model execution.

`GeneratedMediaOutputRegistry` is an independent ABI layered beside those
unchanged V1 wires. It orders one to four output entries per present
modality, up to twelve, as fixed 544-byte entries plus an exact concatenated
payload pack. Entry admission preserves a modality-specific structural
completion shape: image requires no completion receipt, while audio and video
require a completed flag and nonzero completion root. State and completion
roots are opaque here; typed producer acknowledgement/state validation is a
precondition rather than a registry claim. One 544-byte manifest binds the
ordered entry table, exact payload pack, generation plan, scope, policy,
challenge, generation, and complete preceding archive bytes. These three
extension objects reuse the generic checkpoint-file selector as their only
filesystem visibility authority.

`GeneratedMediaProducerAdmission` is the pre-publication gateway in front of
that registry. It decodes the existing fixed image plan/provenance/result,
audio quiescent-state/plan/provenance/result/playback-acknowledgement, and video
quiescent-state/manifest/provenance/result/display-acknowledgement wires. Exact
raw pixel, PCM, or frame bytes must match the typed result. The gateway derives
one common request/scope/policy/challenge envelope, converts the one-based image
index to a zero-based registry ordinal, reconstructs registry
generation/publication sequence, and requires exact typed
state/result/completion predecessor continuity. It then constructs the
unchanged three-object registry; it creates no fourth object or selector.

The producer-transition layer is a higher-assurance sibling, not a silent
upgrade to structural admission. Trusted host callbacks replay the exact
retained source-model and image/audio/video materializer profiles into private
scratch. The gateway exact-compares model output, successor state, raw media,
publication, and completion transitions before it constructs the same
three-object registry. Image replay preserves a fresh one-shot local
publication and derives its separate zero-based collection ordinal from
validated registry lineage. Audio/video replay includes the pending state,
application observation, acknowledgement plan/result, and final quiescent
state. Fixed per-output receipts and one batch header form a separate evidence
sidecar bound to the registry manifest/archive; the sidecar is not a fourth
registry object or a selector. A successor must present the preceding evidence
and registry as an exact pair.

Callbacks and their contexts remain host runtime values and are never
serialized. Replaying them proves exact deterministic reconstruction on the
verifying host, not historical execution, current resource authority, a
physical playback/display sink, external codec/container correctness, or
performance.

The reference path supports only retained RGB8, PCM s16le, and intra-frame
gray8 fixtures plus image crop/nearest/tile, weighted audio mix/exact
decimation, and keyframe selection. Its encoded payload archive and output
registry contain bounded identity envelopes, not production containers. It has
no external codec, encoder, network, camera, microphone, model, or accelerator
authority. The atomic-set workers have explicit filesystem authority but do not
emulate device power loss or establish native Linux behavior. External formats,
measured accelerator residency, physical playback/display, quality evidence,
and production-model integrations remain future layers. See
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md) and
[Hierarchical Media Buffer Ownership](MEDIA_RUNTIME_LEASE.md), then
[Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md) and
[Media Stream Continuation](MEDIA_STREAM_CONTINUATION.md), followed by
[Atomic Media Stream Checkpoint Sets](MEDIA_STREAM_CHECKPOINT_SET.md) and
[Multimodal Processor and Cache State](MEDIA_PROCESSOR_STATE.md), then
[Materialized Multimodal Processor Caches](MEDIA_PROCESSOR_CACHE.md), followed
by [Generated-Image Publication](GENERATED_IMAGE_PUBLICATION.md).
The generative output chain continues with
[Generated Audio Publication and Playback Acknowledgement](GENERATED_AUDIO_PLAYBACK.md)
and [Generated Video Manifest and Display Acknowledgement](GENERATED_VIDEO_DISPLAY.md),
then [Atomic Generated-Media Checkpoints](GENERATED_MEDIA_CHECKPOINT.md) and the
[Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md),
followed by the
[Bounded Generated-Media Output Registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md),
[Canonical Generated-Media Producer Admission](GENERATED_MEDIA_PRODUCER_ADMISSION.md),
and
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md).

### ResourceBank

`ResourceBank` accounts for declared logical quantities such as KV bytes,
activation bytes, scratch bytes, page slots, and operations. Admission returns a
generation-fenced receipt. Stale, mutated, foreign, or over-capacity receipts
fail before state changes.

`LeaseTree` gives request allocations exact child ownership. Additive trees
extend a control-plane parent receipt with separately charged allocation
claims. Receipt-funded trees instead carve a bounded, queue-free ownership view
out of an immutable receipt that already carries the full charge. Funding mode,
ceiling, and restored-publication activation are integrity-bound. Neither mode
treats process RSS as proof of ownership.

### LaneWeave

`LaneWeave` is a bounded control-plane scheduler. It combines exact admission,
weighted service, deadline projection, cancellation, and replayable events.
Prepared permits are single-purpose and fenced against stale address reuse.

The scheduler derives outstanding Event-v1 capacity from its bounded slots
rather than storing another counter. Accepted work reserves capacity for its
admission event, every declared service event, and one terminal event.
Unrelated semantic events may consume only the remaining slack. Near sequence
exhaustion, an admission that policy would otherwise reject can therefore
return `SequenceOverflow` without emitting a rejection event when no slack
remains. This invariant adds no ABI, snapshot, or scheduler-state field.

### Token publication

A token transaction stages every AI-visible mutation:

- KV root or row transition;
- RNG state;
- sampling-call counter;
- output word;
- resource and scheduling commitments.

Preparation may fail without exposing partial state. Commit consumes the exact
permit and publishes the staged state once. Abort leaves the prior committed
root usable.

Paged variants add cache instance, logical page, ownership generation, and
before/after page-map roots. The LeaseTree-backed variant also binds allocation,
retirement, and request-wide publication authority.

The experimental `prepared_text_session.SessionV1` is the first text execution
path to use the contiguous transaction directly. It seals one mapped `.glrt`
image and pre-tokenized prompt into an exact local request plan, adopts the
existing `LaneWeave` receipt, and keeps serial greedy KV, RNG, and output state
alive across service permits.

R1c layers `SessionV2` and `BoundPlanV1` around that unchanged numerical and
publication lifecycle. The binding joins the local plan to a Common Model
Contract autoregressive `generate_sequence` artifact and
`implementation_defined` execution profile, then installs all roots before
admission. `SessionV2.start` reconstructs and compares the artifact, execution
plan, residency projection, and local plan against an independently retained
`BoundPlanInputV1` before delegating to the atomic R1b start path. This keeps a
coherently re-rooted caller-asserted identity from authorizing itself.

The execution plan describes total logical resources. For the mapped `.glrt`,
`ExecutionResidencyBindingV1` declares `shared_read_only`, records the complete
container as resident weight bytes, and projects the total to the exact local
claim charged by `ResourceBank` for this request. This is logical accounting,
not evidence of physical RSS, page residency, deduplication, or ownership of
the shared mapping.

The Common Model Contract artifact manifest is intentionally specific to the
request profile: prompt and output dimensions affect its root, while the
weight digest remains the exact `.glrt` container digest. It is not a stable
package identity. Token-domain, token-domain-configuration, and
artifact-license roots are opaque caller assertions; the bridge binds but does
not inspect or attest their bytes.

The bridge currently accepts only profiles whose local activation claim covers
the Common Execution Plan's exact `u32` prompt-input bytes. A
long-prompt/minimal-model profile can remain valid for `SessionV1` yet fail
R1c binding before admission. Resolving that remaining ownership and accounting
boundary is future work.

After publication begins, `BoundarySnapshotV2` groups the verified V1
in-process boundary with the bound-plan, artifact, execution-plan, and
residency-binding roots. `boundarySnapshotValidV2` verifies self-canonical root
composition, while `boundarySnapshotValidForBoundPlanV2` contextually joins the
snapshot to the expected bound plan, canonical local plan, and complete
prepared-image identity, including source and ABI fingerprints. It remains
neither a durable continuation payload nor a historical attestation.

R1d layers the preferred fixed-length `SessionV3` lifecycle over `SessionV2`.
At the terminal boundary it hashes the exact output tokens as canonical
little-endian `u32` values, joins that root to the verified V2 boundary through
a source-mapping root, and prepares one Common Model Contract
`ResultEnvelopeV1`. The envelope carries the actual request-charged
`ResourceBank` receipt from `ExecutionResidencyBindingV1.request_claim`; the
execution plan continues to describe the larger total logical claim.
Contextual validation joins the artifact, plan, prompt, token-domain/cache
configuration, ownership challenge, boundary transcript, adapter evidence, and
charged receipt before the Session validates that Receipt against the live Bank
publication session and advances a dedicated result-publication state exactly
once from zero to one on a successful explicit seal. Offline consumers can
revalidate the envelope's structural receipt or compare it with an
independently retained Receipt; only the live seal proves current Bank
authority.

An ordinary `SessionV3` rejects sealing before the fixed final token and rejects
duplicate sealing without mutating the result state. Its retirement requires a
sealed result; cancellation is valid only before sealing. The result envelope
and `TerminalResultEvidenceV1` are live in-process evidence, not a durable
external sink or a historical attestation.

R1e adds `prepared_text_checkpoint`, an adapter-level canonical state codec
rather than a core model contract. At a verified non-terminal `SessionV3`
boundary with `0 < output_count < max_new_tokens`,
`captureCheckpointV1` cross-binds the local and common plan roots, V2 boundary,
publication transcript and state commitment, output prefix, RNG words,
sampling count, and committed contiguous KV prefix. The KV wire uses the same
layer/K/V/raw-bit ordering as the live full-prefix commitment.

The independent decoder reconstructs both forms of KV evidence: the full
logical prefix root and the publication protocol's initial-prompt root plus
per-decode-row chain. It then reconstructs the complete state commitment rather
than trusting roots embedded in the image. A detached materializer allocates a
new output journal and contiguous cache, zeros all capacity, restores only the
committed prefixes, and verifies the resulting concrete roots again. Zig and
Python share a synthetic raw-bit golden and whole-image mutation rejection;
the real prepared model integration captures after its first output,
materializes a detached copy, and then finishes, seals, and retires the
unmodified live Session.

The detached value has no Scheduler, ResourceBank, receipt, permit, sink, or
publication authority. It cannot continue generation or publish another token.
The encoded and detached allocations are caller-owned and are not charged to
the live Session's ResourceBank.

R1f adds a narrower same-process operation:
`SessionV3.rebindCheckpointV1` replaces only the concrete output and contiguous
KV backing of the original Session at its exact current boundary. The live
Session supplies all decoder expectations and materializes the candidate
internally. It verifies the complete live context before and after
materialization, validates exact raw committed state and zero slack, and
performs no fallible work after takeover begins. The embedded publication
coordinator, Scheduler, ResourceBank, receipt, request epoch, sequence,
transcript/state roots, and address-bound scalar/cache fields remain unchanged.
No permit or authority is created, consumed, or transferred. Old borrowed
output/cache views become invalid after success.

This retained-authority rebind is not a fresh-process restore. The separate R1h
path uses successor evidence, a fresh target admission, receipt-funded
ownership, and a new address-bound Session rather than changing R1f authority.

R1g adds `prepared_text_successor`, a pointer-free evidence plane over that
same exact checkpoint boundary. It reuses the Common Model Contract's canonical
768-byte `ExecutionPlanV1` and 256-byte
`ExecutionResidencyBindingV1`, then adds one fixed 512-byte transcript segment.
The successor plan advances the execution generation, starts publication at
the current nonzero sequence, links the source plan, identifies the checkpoint
logical-KV payload, and carries the checkpoint challenge. The segment
cross-binds those records to the source checkpoint, bound plan, boundary,
predecessor transcript, state commitment, target ownership intent, and exact
remaining service count.

`SessionV3.captureSuccessorArtifactsV1` derives the trusted source context from
the live Session and exact-compares it again after constructing the records.
The operation is read-only: it does not mutate state or acquire, consume, or
transfer authority. The target ownership-intent root names proposed
Scheduler/Bank/LeaseTree/cache identities, successor generations, and the exact
request claim, but it is not a restored receipt, admission result, source-exit
record, or runnable target Session. Zig and independent Python verification
freeze the three wire records and reject every-byte mutation, length errors,
and coherently re-rooted foreign context.

R1h-a now turns that intent into a fresh, live Scheduler admission and Bank
receipt while retaining the non-runnable adoption barrier. It opens an
allocation-empty queue-free receipt-funded LeaseTree with one
zero-current-claim scope, restores sequence `N`, and seeds the Bank publication
generation from source `G`; a process-local bootstrap root binds all evidence
roots and live handles.

R1h-b consumes that exact bootstrap through `SessionV3.startRestoredV1`. It
reserves the queue-free request-local byte claim before allocator work,
materializes and revalidates checkpoint output/KV/RNG/sampling state, then
commits the funded batch with the pending Scheduler adoption. Token-publication
ABI v2 carries `sequence_base = N`, allowing global token sequence to continue
while the fresh target Scheduler starts with no completed local service. The
first target Bank permit is `G + 1`.

Restored close acquires a no-service Scheduler barrier before retiring the
funded allocation and freeing Session backing. The final Bank transition
atomically closes the publication namespace, empty tree, zero-charge scope, and
parent receipt before LaneWeave emits its ordinary cancel or retire event. The
retained synthetic-model path compares one target transition with uninterrupted
output, logical KV, RNG, and sampling state and returns target accounting to
zero.

This lifecycle does not add early EOS, fewer-than-admitted outputs, a raw-text
tokenizer, stable package or license byte attestation, durable prepared-session
checkpoint publication, durable successor selection, source exit, exclusive
process handoff, fresh-process resume, terminal resumed equivalence,
production-model evidence, strict cross-platform numerical equivalence, or
native-platform performance evidence.
The `deinit` safety path may abandon terminal evidence while closing and
releasing the adopted lifecycle; it does not count as a successful result seal.

The bound-plan and residency bridge is currently an experimental Zig/direct
API. It has no fixed `BoundPlanV1` wire, projected C verifier, or retained
`.generate_sequence` `SupportRecordV1`; cross-language ABI and support-registry
parity are future work. The residency-aware artifact/plan/result projection
and prepared terminal roots do have shared Zig/Python goldens and adversarial
mutation coverage.

The underlying `SessionV1.start` path owns admission and adoption as one sealed
control-plane transaction. It derives the claim and service count from the text
plan, commits the `ResourceBank` charge before materialization, and installs a
scheduler-wide adoption barrier before allocation or prefill begins.
`SessionV2` and `SessionV3` preserve this transaction after their common
binding is validated.
The ready session commits the single-use authority into its every-service
publication binding; failure emits the ordinary accepted-then-cancelled
scheduler history and releases the exact receipt. If cancellation returns a
transient cleanup error, the Session reports `RecoveryRequired` and retains the
exact, single-use cancellation authority for retry after that condition is
resolved. This path does not diagnose or repair Scheduler or Bank state.
Competing logical mutators fail with `AdoptionInFlight` until commit or cleanup,
eliminating shared-scheduler interposition without inventing a new semantic
event.

This barrier serializes logical progress during session startup. It is a
correctness primitive, not an asynchronous activation design. The older
`SessionV1.init` path remains an exclusive compatibility boundary for callers
that already hold an admission.

### Continuation capsule

`ContinuationCapsule v1` is a 608-byte pointer-free manifest created after a
successful publication. Nine position-typed references bind model, tokenizer,
execution plan, ResourceBank state, LaneWeave state, KV state, sampler/RNG state,
output state, and publication receipt. Each reference hashes its ABI, exact
length, and payload under a distinct object-kind domain.

The manifest does not duplicate those objects and grants no resolver,
filesystem, allocator, scheduler, or output authority. A resume boundary must
supply the expected request/execution identity and exact object bytes; the full
verifier reconstructs the canonical manifest and rejects substitution. Parent
roots form explicit checkpoint lineage. Durable storage and live runtime restore
are the next layer, not an implied property of the manifest.

### Continuation object resolver

The in-memory resolver accepts one capsule, an exact authority epoch, a
tenant-scoped grant, a bounded immutable catalog, and caller-owned output
buffers. The grant limits object kinds, catalog entries, bytes per object, total
bytes, and resolution count. A lookup must match tenant, kind, ABI, exact length,
and typed digest; missing, corrupt, ambiguous, stale, repeated, cross-tenant, or
overlapping requests reject before accounting changes.

After all nine objects resolve, the resolver re-hashes every output and verifies
the complete capsule composition. It allocates nothing and has no filesystem,
network, ResourceBank, scheduler, or publication authority. The caller remains
responsible for authenticating the grant and retaining output buffers. Durable
bundle storage and live ownership reacquisition remain separate layers.

### Continuation bundle

The 1,136-byte bundle manifest joins one capsule with its nine object references.
Each entry retains the capsule's kind/ABI/length typed root and adds a
tenant-bound blob root plus canonical first-occurrence ordinal. Equal payload
bytes may therefore share one planned blob inside a tenant without collapsing
their semantic object kinds. The same bytes under another tenant produce a
different blob root.

The bundle records exact logical and unique payload totals but embeds no payload
and performs no storage I/O. It is a portable plan, not a store, lease, cache, or
proof of physical savings. The in-memory store is a separate capability boundary
that accounts payload ownership and metadata explicitly.

### Continuation object store

The bounded in-memory store is scoped by one authority epoch, tenant, bundle
root, operation mask, and entry/object/payload/index/reference limits. Its slot
index has fixed native capacity while exact payload bytes come from a
caller-supplied allocator. Import verifies the bundle and all objects first,
then applies at most nine reversible insert/reference actions. Any later quota or
allocation failure rolls the whole import back.

Equal tenant blob roots reuse one owned payload allocation and increment a
reference count. Reads re-hash and copy into caller-owned storage; the last
release frees the payload unless a generation-fenced lease is active. Acquire,
renew, release, and explicit expiry consume a separate lifecycle capability;
renewal advances generation so stale receipts reject. Quarantine clears active
lease authority. Repair requires a target-specific grant binding the tenant,
bundle, store grant, blob, quarantine reason, source identity, and byte ceiling,
then re-hashes candidate bytes before mutation. The store reports logical index
charge separately from native fixed-index and allocator capacity, so duplicate
payload avoidance cannot be misreported as net memory savings.

The collection planner adds a non-destructive retirement path. A live,
unleased final reference can become a retained `retired` entry rather than
being freed immediately. Planning then consumes the exact audit snapshot, a
canonical multiset whose multiplicity equals every non-retired reference count,
and exactly one current receipt for every active lease. It classifies occupied
slots as reachable, leased, quarantined, or collectible under explicit scan and
collectible-byte ceilings. Missing roots or lease receipts reject instead of
making an object eligible. The output root binds every decision, while the
operation performs no allocation, deallocation, filesystem access, or state
mutation.

The sweep journal is a separate module and capability boundary. A sweep grant
pins one exact store scope, audit snapshot, previously reviewed collection-plan
root, and staging ceilings. Prepare does not trust that plan by assertion: it
regenerates the plan from the original root multiset and lease receipts, then
returns a new caller-owned journal value. Abort validates the prepared root and
requires the same live snapshot before returning another journal value. Neither
transition mutates the input journal or store, allocates heap memory, or frees
payloads.

Destructive commit adds a second grant that binds the exact sweep grant,
prepare root, snapshot, collection plan, and removal ceilings. It regenerates
the plan again, derives a canonical target set, audits every target and all
before/after accounting, and completes every fallible check before the first
deallocation. The store then frees only those exact retired targets and emits a
receipt binding post-state, payload/index release, and allocator call count.
This is an atomic single-owner in-memory suffix, not durable crash recovery,
secure erase, or a process-RSS claim.

The sweep-record codec is the next authority boundary. It encodes one verified
commit as a fixed 736-byte body plus a separate 48-byte footer. Decoding
reconstructs the commit grant, store receipt, and outer receipt and rechecks
their semantic accounting; exact expectations reject a valid record from a
different chain position. The append plan returns body and footer slices only.
An anchored allocation-free classifier then admits only a semantically verified
epoch/sequence/previous-root chain into its committed prefix and names short
body, absent footer, matching partial footer, and corrupt tails separately. The
codec and classifier do not open, write, sync, truncate, repair, delete, or
recover files.

The sweep writer is the next authority boundary. An exclusive lease snapshot
binds storage epoch, lease generation, exact observed bytes, and capacity.
Append authority exposes only ordered body/footer write and sync operations;
separate repair authority can truncate one explicitly classified incomplete
tail to the verified prefix and sync it. Any uncertain I/O poisons the local
writer or repairer and requires lease release, fresh read, and reclassification.
The deterministic caller-owned backend models partial writes and crash survival
at every byte boundary without real filesystem or payload-deletion authority.

The POSIX file adapter is the following authority boundary. It receives a
caller-opened directory descriptor and one component name, opens without
following the final symlink, acquires an exclusive advisory lock, and requires
one owner-private regular-file link. Device, inode, length, permissions, and
directory-entry identity are checked around every write, sync, and truncate.
Creation synchronizes both file and directory. Six native subprocess deaths
cover every append and repair phase, while the independent Python adapter
repeats the file and lock contract. This is process-death and
namespace-replacement evidence, not device power-cut evidence. Durable payload
promotion, ownership reacquisition, and live restore remain separate layers.
The advisory lock contract also requires cooperating writers; same-length
in-place writes that preserve visible identity metadata are outside its
detection boundary.

The publication-ordered commit layer removes the earlier record-after-delete
gap. Before mutation, the store derives the exact target set, before/after
accounting, predicted post-state snapshot, and both commit receipts. The POSIX
adapter publishes that fixed record through body/footer sync before invoking the
no-failure removal suffix. An injected failure at the boundary leaves the old
store untouched. Recovery verifies the anchored record and accepts only the
exact old snapshot (apply once) or predicted new snapshot (already applied).
That ordered commit fixture still uses the in-memory lifecycle store.

The durable payload-file layer persists the byte plane separately. Its canonical
snapshot re-hashes every tenant-bound payload and sorts exact references before
encoding. A fixed reclaim record binds the published sweep root, complete target
list, old/new payload roots and lengths, accounting, preview root, and
challenge. Under one stable lock inode, recovery writes and syncs a deterministic
candidate, verifies the active old root, atomically renames the candidate over
the active file, syncs the directory, and accepts only the exact new root.
Native and independent Python campaigns terminate after seven plan/promotion
boundaries and recover idempotently from fresh processes. Lease, quarantine,
reference, repair, and runtime ownership metadata remain in memory; power-cut
durability and whole-checkpoint atomicity remain later boundaries. Paged-KV
restoration is provided by the subsequent generation-remap layer described
below.

The ownership-manifest layer adds a canonical `resource_state` object after
payload recovery. Its fixed plan binds source and target Bank epochs, the exact
next publication sequence, parent/tree claims, canonical tenant scopes, and
typed roots for every allocation. Reacquisition requires a fresh target Bank,
then reserves the parent, opens the LeaseTree, binds the restored sequence, and
charges all allocation nodes as `reserved_unmaterialized`. Only exact
kind/length/byte matches may commit the batch to `live`; mismatch remains
charged for retry or explicit free-then-abort. This restores logical in-memory
ownership, not paged-KV contents, accelerator residency, object-store lifecycle
metadata, or a running request.

The paged-KV restore layer consumes that pending ownership. Each canonical page
image serializes committed rows only, verifies tenant-bound durable membership,
and retains the source root/ref chain as evidence. The cache validates the
complete source ownership digest before allocation, zero-fills target padding,
copies little-endian f32 values, and emits a new cache instance plus new page
generations. A changed source generation rejects while the target remains
fresh, and Bank publication stays blocked until exact images commit ownership
nodes to live.

The live-restart layer adds a fixed runtime object containing the exact next
publication sequence, logical KV digest, RNG, sampler counter, visible output
prefix, prior commit, and checkpoint challenge. A source worker publishes one
token, synchronizes the fixture files, releases its Bank ownership, and exits.
A fresh target worker verifies the capsule, reacquires charged ownership,
rebuilds KV under a different cache identity, then atomically publishes the next
KV row, RNG state, sampler count, output token, receipt chain, and Bank fence.
The standalone proof is model-free and uses a natural exit. The following
checkpoint-file layer adds atomic set promotion and crash phases; production
model reconstruction remains a separate gate.

The checkpoint-file layer closes the multi-file visibility gap for the
model-free proof. It encodes capsule, ownership, durable payload membership,
ordered KV pages, runtime state, and source-process evidence into one canonical
immutable archive. A fixed selector binds the archive root and length, request
position, challenge, and both checkpoint/selector lineages. Publication syncs
the archive before atomically renaming a selector candidate over the active
selector. Seven native worker deaths cover archive write/sync/directory-sync
and selector write/sync/rename/directory-sync; fresh recovery accepts only the
previous or successor root, then another process resumes token publication.
Device power loss, native Linux execution, and production-model numerical
comparison remain outside this evidence.

## Durable external-action flow

```text
proposal + local authorization
              │
              ▼
      canonical ActionOutbox record
              │ semantic ApplyPlan
              ▼
  body write ─> file sync ─> footer write ─> file sync
              │
              ▼
 exact readback + namespace/identity fence
              │
              ▼
 committed local state + durable receipt
```

The POSIX adapter opens one validated leaf beneath a caller-opened trusted
directory, holds an exclusive advisory lock, and admits only the expected
regular one-link private file. Device/inode equality, no-follow lookup,
replacement checks, and exact readback bind the descriptor to the canonical
clean committed `320 + 752n` stream. `ContentSnapshotV1`, `LeaseBindingV1`, and
`RepairPlanV1`
bind the observed bytes, process-local acquisition, and one classified
incomplete suffix. Repair verifies the full observed snapshot, truncates and
syncs only that suffix, then requires close and fresh replay before append.

The deterministic Zig/Python store models cover 40 append phases, 754
section-prefix
writes, 751 repair tails, and 8 repair faults. A separate host campaign kills
workers at 3 initialization, 40 append, and 6 repair boundaries. These are
storage-ordering and process-death claims only: the adapter has no credentials,
does not authenticate provider status, does not perform a live dispatch, does
not provide external exactly-once delivery, and does not emulate device power
loss. Windows durable storage remains a separate adapter.

W4b-d leaves that record and store format unchanged and adds a pointer-free
adapter contract, a trusted driver, and a bounded fixed-storage fake authority:

```text
ready state
    │ reserve 3 records
    ▼
durable dispatch_intent(G) ──> adapter callback
                                   │
                 terminal evidence│pending/error
                                   ▼
                       terminal or uncertain
                                   │ reserve 1 record
                                   ▼
                   authoritative status callback
                  ┌──────────────┴──────────────┐
                  │                             │
       pending / unknown              not_applied_fenced(G)
          stay uncertain              durable ready transition
                                                │
                                                ▼
                          retry G+1, stable remote request,
                              new dispatch request root
```

Dispatch admission protects one future reconciliation slot for every existing
uncertain action and requires three additional slots for the new intent,
immediate observation, and its possible later reconciliation. Status admission
requires free slots to cover every uncertain action before a callback may
install a remote fence. Resolving one action consumes one slot and removes one
obligation, so driver-only admission cannot overcommit a bounded journal. The
driver durably appends the exact intent before invoking adapter code. A fence installed at
generation `G` rejects every delayed dispatch through `G`, while the exact
`G + 1` retry retains the stable remote request identity and derives a new
dispatch root. Pending and unknown status do not create retry authority.
Terminal duplicate dispatches replay the same evidence and leave the fake
application count at one.

The fake authority serializes callbacks under a same-process mutex and keeps a
synthetic credential only in its opaque context. Portable descriptors,
requests, evidence, and transitions contain no pointers or credential
material. This is an API-boundary fixture, not an OS sandbox or credential
security proof. The low-level contract constructors and callbacks validate
integrity and composition but do not prove filesystem durability; the ordering
claim applies only to the driver entry points.

Integrated Zig tests inject deterministic same-process faults at four
terminal-transition and four fenced-transition append phases, then freshly
reopen, repair when required, and reconcile status. Twenty independent Python
tests check the portable contract and fake generation-fence semantics; a
separate Python CLI invocation compares a live canonical Zig reference report
byte-for-byte. No JSON fixture is retained. W4b-d
performs no network, provider, or tool effect and adds no real credential,
cryptographic-origin, fake-service restart-persistence, process-death, native
platform, performance, power, or external-exactly-once claim. The separate
W4b-c 49-death store campaign remains unchanged.

## Device capability and selection flow

The first Stage-5 device boundary separates portable compatibility decisions
from live backend authority:

```text
Common Model Contract execution-plan root
                 +
       DeviceRequirementV1
                 │
                 ▼
 canonical inventory of capability + discovery epoch + state
                 │ malformed / duplicate / incompatible
                 ├────────────────────> reject before admission
                 │
                 ▼
 deterministic selected entry
 rank, then capability root; explicit fallback only
                 │
                 ▼
       SelectionReceiptV1
       pointer-free decision evidence
                 │
       ┌─────────┴──────────────────┐
       ▼                            ▼
native readiness        allocation lifecycle
revalidates device      fake failure/recovery +
identity                real Metal buffer ownership
```

`DeviceCapabilityV1` hashes stable backend and physical-device identity,
canonical tested operation/type/numerical profiles, derived aggregate bits,
lifecycle policy, declared
single-allocation/total-byte/queue ceilings, optional driver/runtime identity,
and placement identity. An adapter that cannot retain driver/runtime identity
uses the all-zero digest. Dynamic allocated bytes, residency, utilization, queue
depth, temperature, frequency, power, and energy never enter the fingerprint.
The profile tuple is the compatibility key; aggregate sets cannot imply an
operator/type pairing that no profile advertises.
Canonical inventory validation rejects every malformed or duplicate entry
before choosing a winner; discovery order cannot change the inventory root.
Pinned capability requests never fall back, while CPU fallback is considered
only when explicitly authorized.

The native macOS Metal adapter projects a stable subset of `MetalDeviceInfo`
into this portable contract, binds one local discovery epoch, and revalidates
the selected fingerprint and registry identity from a fresh query immediately
before the first Metal resource acquisition and again through post-run device
evidence. The corrected tiled FP16
matmul path separately fixes asymmetric/partial edge-tile
loading and barrier participation, requires exact nonzero buffer geometry, and
matches a CPU oracle for shapes on both sides of the 16x16 tile boundary without
turning those tests into a performance result.

The lifecycle layer remains separate from both selection and allocation.
Every selected Metal context installs `MTLCopyAllDevicesWithObserver`, verifies
initial membership by registry ID, and retains source-specific
removal-requested, removed, and exact command-buffer-removed facts. The latter
requires native status `5`, Metal command-buffer error domain `1`, and code
`11` and is fenced before any test overlay. A sticky source bitset derives an
effective monotone state, so a weaker later callback cannot downgrade loss.
A native admission lease linearizes entry against lifecycle publication: work
admitted before loss may settle under existing authority, while admission
beginning after loss rejects. Live `MTLDevice` property reads used by
`deviceInfo` and `allocationLimits` acquire the same lease, closing the
precheck/use race. The backend uses retained initial device identity for loss
observation rather than querying a dead device.

The 40-byte `SourceCursorV1`, 280-byte `ObservationV1`, and 272-byte
`TransitionReceiptV1` bind a native source instance and monotonically
increasing source sequence to the prior inventory and successor. The
source-instance digest binds a 256-bit per-context nonce, the
observer-generation reset discriminator, registry ID, and stable
device/placement identities rather than relying on the 64-bit generation
alone. Gaps are valid; the caller must durably and atomically commit the
advanced cursor with dependent state. The live adapter claims each exact
native snapshot at most once. Source mismatch fails closed; fresh adoption
requires a new inventory and exact initial sequence 1. The transition derives a
newer `unavailable` or `lost` entry, which normal selection excludes, but does not
release existing native ownership, clear quarantine, create a fresh selection,
recover dead resources, or migrate state. Its hashes establish composition and
integrity, not authenticity or platform attestation.

The receipt itself grants no allocation, residency, queue, dispatch, or
publication authority.

The next portable layer is implemented through one common coordinator with a
deterministic fake adapter and a native Metal adapter. `AllocationRequestV1`
binds the exact selection, requirement,
authority, canonical multi-buffer quote manifest, and committed parent
receipt. Admission replays every live quote before opening an exact
device-byte `ResourceBank.ChildLease`; allocation calls then produce opaque
object identities and generations. Only a complete object set becomes a live
lease. Failure/cancellation frees partial objects before uncharging, while a
failed free returns recovery authority and preserves the child charge.

The fake path proves the portable ownership/accounting state machine and
injected recovery. The Metal path additionally creates and directly inspects
real Shared buffers, retaining logical `length` and separately observed
per-resource `allocatedSize` without inferring either from device-wide memory
samples. Receipt-bound `ChildLease` ownership and execution-owned additive
`LeaseTree` ownership are both integrated. Exact object-set pins fence release,
and the bounded INT4 path provides per-adapter single-flight async completion:
`MetalAsyncDispatchTicketV1`, exact submit replay, separate poll/wait, pending
ownership retention, exact completed-output binding, and native finalization
only after Bank settlement. Ambiguous, unknown, invalid, or command-error
observations first retain sticky nonterminal quarantine rather than
manufacturing a terminal. The exact retained command-buffer `.error` case has
a separate pointer-free sidecar that can authorize core `terminal_failure`
with no output root; quarantine, pin, charge, buffers, and native command stay
live through Bank settlement, then the private callback exact-finalizes the
same `.error` before private clearing. Ambiguity and unknown completion remain
sticky. Portable Zig and independent Python tests model the error contract
without GPU work; the ordinary native macOS gate uses a real `MTLDevice`, real
`MTLBuffer` resources, and a CPU output oracle as a successful-command
regression.

Device-loss Dispatch Reconciliation V1 composes the lifecycle and dispatch
layers only for the exact command-specific native status/domain/code
`5/1/11`. A 440-byte retention record binds the selected capability, active
lease and pin, request, submission, quarantine, and private adapter challenge.
A 240-byte plan binds that retention to one accepted `present -> lost`
transition. Production authorization requires the same sticky native loss and
retained `.error`; synthetic observations remain test-only. Core consumes the
Bank pin before the adapter exact-finalizes the target native record, and a
448-byte receipt binds the terminal failure, successful completion, Bank
settlement, and adapter settlement tombstone. A lost outer acknowledgement
keeps the Coordinator slot `settlement_pending`, while exact retry confirms the
same tombstone without a second Bank release or native finalization. Device
loss alone is never terminal: pending, ambiguous, unknown, and invalid
commands do not enter Phase A.

Device-loss Dispatch Callback Retirement V1 is the Phase B ownership path for
those exact `pending`, `submission_ambiguous`, `completion_unknown`, and
`invalid_completion` states. Its 464-byte retention, 240-byte plan, 408-byte
fence, and 504-byte receipt bind the live dispatch to an ARC-owned callback
gate that is detached while the native command record and four command-held
references remain retained. Callback exit is not a prerequisite. The adapter
authorizes only `ownership_retired_after_device_loss` with zero output; core
consumes the Bank pin before the private settlement callback unlinks the exact
native record and records its replay tombstone. Production requires an exact
native `removed_notification` or `command_buffer_device_removed` source and
same-source sticky revalidation. The build-isolated native matrix exercises all
four retained states with real Metal commands/resources. It combines a held
completion handler for pending with a post-commit disposition authenticated by
the native record, a physical-success completion overlay that changes only
`callback_fault`, and an exact completed-output-read rejection before caller
memory is written, then uses synthetic injected loss to authorize retirement.
It does not prove
physical removal, driver or hardware failure, output recovery, migration,
reset, physical reclaim, residency, or performance.

The production native context also exposes the fixed 256-byte
`MetalDispatchRetirementTelemetryV1` snapshot. Device registry ID and context
nonce bind its successful unique/replayed prepare and commit counters to one
source. Completion-observation, native-state, disposition, authorization,
callback-detachment, live-record, unlink/reference, tombstone, and generation
buckets are frozen at the exact native transitions; rejected operations and
reads do not advance the sequence, and counters saturate independently with a
sticky overflow mask. Collection takes the native registry monitor but not the
callback gate. The snapshot is diagnostic and cannot replace any Phase B
authority or prove callback exit, physical loss, completion/output, allocation
release, migration, reset, residency, reclaim, queue depth, or performance.

Device-loss Retirement V1 composes these previously separate layers only for
an already quiesced allocation. A pointer-free plan binds an exact accepted
`lost` transition to the historical selection, allocation authority, live
LeaseTree lease, leaf/object sets, recovery generation, and adapter challenge.
The production Metal adapter then requires the same sticky native source and
drops exact buffer strong references without post-loss device or buffer
property reads. The existing coordinator remains the sole FreePermit
authority, so native release precedes logical uncharge and partial failure
remains retryable. The receipt explicitly grants no output, migration, reset,
residency, or physical-reclaim authority.

A separate non-installed fault shim is compiled only for the build-isolated
native fault/race gate; the production shim is checked to export no
fault-control symbols. Two host threads race a context-local one-shot plan and
exactly one wins. The plan lets a real Metal command complete physically as
`.completed`, retains that physical snapshot, and only then overlays the
test-published snapshot as `.error`. The adapter therefore exercises
quarantine and terminal-failure reconciliation without mislabeling the device
outcome. At settlement, the gate observes the Bank pin consumed before the
native record is finalized, then deliberately rejects the first confirmation
after exact native finalization and state clearing. The coordinator retains
`settlement_pending`; an exact retry replays the same tombstone and clears the
slot without a second Bank release or native finalization.

The overlay is not a physical command-buffer, driver, hardware, or device-loss
fault and provides no performance evidence. The built-in M1 lifecycle run
separately proves initial observer membership and an unchanged no-event
snapshot around one real successful command. A native two-thread race requires
one exact initial-snapshot consumption and one stale result while the snapshot
remains readable; neither result is a physical removal callback.
Portable transition and error-path tests are deterministic synthetic/model
evidence rather than physical-removal evidence. The isolated native retirement
gate uses real buffers under an explicitly synthetic test-only loss permit; it
proves reference cleanup, not physical removal or reclaim.
Physical residency, fresh selection and migration, multi-slot and multi-device
scheduling, physical device telemetry, performance, retained driver/device
ranges, removable hardware campaigns, and native support on cross-compiled
targets remain open.
Cross-target builds are compile evidence only. See
[Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md),
[Device Lifecycle Observation V1](DEVICE_LIFECYCLE.md),
[Device-Loss Dispatch Reconciliation](DEVICE_LOSS_DISPATCH_RECONCILIATION.md),
[Device-Loss Dispatch Callback Retirement](DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md),
[Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md), and
[Device Allocation Lease V1](DEVICE_ALLOCATION_LEASE.md).

## Native observation flow

W5a separates portable observation identity from process-local authority:

```text
descriptor + sealed observation plan
                 │
                 ▼
              probe
                 │ fail
                 ├─────────────> rejected_pre_run; no workload invocation
                 ▼
             pre_run
                 │ policy fail
                 ├─────────────> rejected_pre_run; no workload invocation
                 ▼
              begin
                 │
                 ▼
       family-neutral workload, at most once
                 │
                 ▼
               end
                 │
                 ▼
             post_run
                 │
        ┌────────┴─────────┐
        ▼                  ▼
   publishable      rejected_post_run
                    receipt and reasons retained
```

`DescriptorV1`, `RuleV1`, `PlanV1`, `ObservationV1`, and
`ObservationBundleV1` are fixed-size and pointer-free. Their canonical roots
bind the workload profile, artifact, build, machine, backend, device,
placement, execution plane, worker/queue counts, phase, metric, availability,
unit, value, subject, stable source identity, per-event provenance,
availability-reason identity, sample-clock identity, and the time-metric-only
value-clock identity. Process handles, clocks, probe commands, and callback
contexts stay in `ObserverV1` and `WorkloadV1`; they never enter the portable
value.

Every metric is `present`, `missing`, `denied`, or `unsupported`. Unavailable
records have no measured value, cannot become numeric zero, and retain a
nonzero reason identity; present records carry none and require an all-zero
reason field. Rules can require presence or false, enforce ranges and pre/post
deltas, and bind the same stable source or subject. Per-event provenance may
change without failing `same_source`. Pre-run failures close before work
starts. Once work begins, the
runner attempts end and post-run collection even after a workload callback
failure. A post-run threshold, source/subject drift, accelerator fallback, or
clock regression retains the observation and receipt but makes the report
nonpublishable.

Host and accelerator metric spaces remain distinct. Every record carries the
identity of the clock used for `observed_at_ticks`. Only a present
nanosecond-valued metric additionally carries the identity of the clock that
produced its value. A device time value therefore cannot be interpreted as a
host monotonic value, and the two fields do not assert cross-clock calibration.
Metric domains remain explicit: a present logical CPU count is at least one,
while physical temperatures may be negative but never below absolute zero.
The download-free reference composes the existing three-profile/six-item
typed-perception fixture and checks correctness plus final zero-orphan
ownership. Its deterministic elapsed value proves composition, not native
performance.

The first host adapter is a bounded read-only macOS module using named system
commands with fixed output ceilings. It exposes host monotonic time, CPU count,
CPU busy, external-process CPU, idle, RSS, available memory, swap, power source,
low-power mode, and thermal constraint with provenance and explicit
availability. Its JSON output adds a bounded readable reason for unavailable
metrics and no reason for present metrics. The paired harness shares its strict
system-field parsers. A platform-neutral JSON registry and validation layer now
keeps the fixed metric universe, source projection, reason/provenance bounds,
and execution context outside individual adapters. The Linux implementation
uses that seam to read only bounded `/proc/meminfo` bytes and strictly map one
`MemAvailable` KiB value to checked bytes; native Linux retention remains a
separate gate. Non-Darwin dispatch does not request a POSIX process-group ID,
leaving the same seam usable by a future Windows adapter.

The native macOS Metal readiness adapter binds a separate accelerator observer
to this runner. Its hard gate makes exactly one real GPU dispatch in total for
a fixed synthetic 37x64 INT4 matrix-vector operation, compares output with the
CPU oracle, and requires a completed command buffer, registry-bound
device/placement identity, `currentAllocatedSize`, GPU start/end timestamps,
zero leaked ownership, explicit no fallback, and composed
descriptor/plan/bundle/run/dispatch roots. The derived duration is diagnostic
readiness evidence, not throughput, latency, or a performance result.
`recommendedMaxWorkingSetSize` is capacity context only. Utilization,
committed/resident bytes, queue depth, temperature, frequency, power, and energy
remain explicit `unsupported` records.

The same native context carries the lifecycle observer. The actual built-in M1
correctness run checked initial selected-device membership and an unchanged
snapshot before and after a real successful GPU command. This is no-event
observer evidence only: no removal-requested, removed, or exact code `11` event
occurred. Portable synthetic lifecycle tests remain a separate evidence class.

The independent Python verifier checks bounded semantic composition and
corruption in the self-asserted live capture; it does not provide cryptographic
authenticity. No addressable native Metal result is retained in the repository,
so implementation, a passing local native invocation, and retained campaign
evidence remain separate levels. W5b stays open. See
[Native Observation Contract](NATIVE_OBSERVATION.md).

## Provider execution flow

```text
logical spans
    │
    ▼
ContextPack ──> mapping receipt + raw/packed token observations
    │
    ▼
Gateway ──────> exact reservation + optional request coalescing
    │
    ▼
Transport ────> chunks + terminal usage + cancellation outcome
    │
    ▼
Settlement ───> quote, authoritative usage, and cost wire
    │
    ▼
CostJournal ──> durable body/footer append and recovery
    │
    ▼
EvidenceJoin ─> compact manifest over verified roots
```

### Context packing and token reconciliation

Core does not tokenize or store text. Callers supply domain-bound span hashes,
token observations, and explicit idempotence declarations. The packer removes
only exact rendered duplicates that are safe to share and retains a decision for
every logical span. A provider-specific adapter can render and count exact wire
bytes outside core, then submit the reconciled observation for admission.

### Gateway and transport

The gateway admits an exact request identity and conservative token reservation.
Identical logical requests may share one physical dispatch while retaining their
consumer identities. Terminal provider usage authoritatively settles the
reservation. Cancellation distinguishes consumer withdrawal from active
transport cancellation.

The transport harness is deterministic and credential-free. It exists to test
chunk ordering, terminal usage, retry state, and cancellation semantics before a
live adapter is introduced.

### Durable provider evidence

The cost journal appends a body and a separate commit footer, syncing each phase.
Recovery accepts a complete valid prefix, can repair a short torn tail, and
rejects a complete invalid frame. Writers are poisoned after an uncertain append
and must be closed and reopened before reuse.

`ProviderEvidenceJoinWire` is a fixed 712-byte manifest over the selected cost
frame, gateway event, and transport outcome. Verification replays the supplied
nested evidence rather than trusting copied roots. The manifest contains no
dispatch, filesystem, or network authority.

## Identity and trust rules

1. On-disk and wire layouts are serialized explicitly; Zig struct layout is not
   an ABI.
2. Every reusable handle carries an epoch or generation.
3. A hash proves byte identity and chain integrity, not the truth of the original
   observation.
4. Logical resource accounting and operating-system/device measurements are
   separate evidence planes.
5. Provider core stays credential-free; live credentials belong in isolated
   adapters.
6. Unsupported combinations reject rather than silently downgrade.

## Portability

The portable core is Zig. AArch64 has specialized CPU kernels and macOS can use
Metal through a small Objective-C bridge. Full artifact cross-builds cover
x86_64/AArch64 Linux musl and x86_64 Windows GNU. Model conversion and runtime
images share a bounded read-only mapping abstraction with POSIX and Windows
implementations; fixture process IDs and hard termination are selected per OS.
The W5a observation contract and family-neutral runner also cross-compile
without importing a native observer into the portable core. The device
capability fingerprint, inventory, requirement, and deterministic selector are
portable decision values; compiling them for a target does not prove a native
backend. The focused macOS-only Metal readiness gate keeps device authority in
the native adapter, binds one local discovery epoch, revalidates its selected
fingerprint and registry identity, and fails
rather than skipping when its one completed diagnostic dispatch cannot be
observed. A separate native allocation gate exercises real-buffer ownership and
per-adapter async submit/poll-or-wait/output-validation/settlement/finalization;
the build-isolated fault gate follows it with physical/published fact
separation, one-winner arm racing, and settlement retry. The serialized native
suite order is readiness → allocation ownership → fault/reconciliation →
focused correctness. Portable contract tests do not execute GPU work.
Execution, numerical, durable-recovery, and physical-resource validation still
require real machines for each promoted platform.

The full capability split, current compile evidence, OS-adapter boundaries, and
promotion gates are maintained in
[Platform Portability](PLATFORM_PORTABILITY.md). Windows, mobile, and edge
targets remain gated until their named native adapters and evidence pass.

## Where to go deeper

- [Design](DESIGN.md): invariants and extension rules.
- [Paging](PAGING.md): weight and KV paging boundaries.
- [Model format](FORMAT_SPEC.md): portable draft format.
- [Native runtime image](RUNTIME_IMAGE.md): execution image ABI.
- [Device capability and selection](DEVICE_CAPABILITY_CONTRACT.md): portable
  capability fingerprints, deterministic selection, native Metal binding, and
  the live-authority boundary.
- [Prepared text session](PREPARED_TEXT_SESSION.md): exact prepared-image
  execution, publication, boundary, and terminal-result lifecycle.
- [Prepared text checkpoint](PREPARED_TEXT_CHECKPOINT.md): canonical
  non-terminal output/RNG/contiguous-KV state, detached materialization, and
  same-process exact-boundary rebind under retained authority.
- [Prepared text successor evidence](PREPARED_TEXT_SUCCESSOR.md): canonical
  successor execution-plan/residency projection, fixed transcript segment,
  target ownership intent, and the restored-admission safety boundary.
- [Prepared text restore admission](PREPARED_TEXT_RESTORE_ADMISSION.md):
  barrier-held fresh target receipt, receipt-funded ownership,
  charge-before-materialize process-local activation, global sequence and Bank
  permit fencing, and restored cleanup to zero.
- [Continuation capsule](CONTINUATION_CAPSULE.md): checkpoint manifest ABI.
- [Continuation object resolver](CONTINUATION_OBJECT_RESOLVER.md): scoped
  lookup and quota contract.
- [Continuation bundle](CONTINUATION_BUNDLE.md): canonical tenant storage plan.
- [Continuation object store](CONTINUATION_OBJECT_STORE.md): bounded in-memory
  ownership and accounting.
- [Continuation object collection plan](CONTINUATION_OBJECT_COLLECTION.md):
  exact reachability and dry-run collection evidence.
- [Continuation object sweep journal](CONTINUATION_OBJECT_SWEEP.md):
  capability-scoped prepare/abort staging without deallocation.
- [Continuation object sweep commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md):
  separately authorized exact retired-target removal and accounting evidence.
- [Continuation object sweep record](CONTINUATION_OBJECT_SWEEP_RECORD.md):
  fixed body/footer commit evidence and pure anchored stream classification
  without file I/O or repair authority.
- [Continuation object sweep writer](CONTINUATION_OBJECT_SWEEP_WRITER.md):
  snapshot-bound append/repair capabilities, poisoned uncertain writers, and
  deterministic crash-boundary conformance without real filesystem authority.
- [Continuation object sweep file adapter](CONTINUATION_OBJECT_SWEEP_FILE.md):
  descriptor-relative locking, identity fencing, ordered sync, explicit repair,
  real subprocess-death conformance, and publication-ordered commit recovery.
- [Continuation object payload file](CONTINUATION_OBJECT_PAYLOAD_FILE.md):
  canonical durable payload bytes, fixed exact-target reclaim plans, and
  copy-on-write process-death recovery.
- [Continuation ownership restore](CONTINUATION_OWNERSHIP_RESTORE.md):
  canonical resource-state wire, fresh-epoch ResourceBank/LeaseTree
  reacquisition, and charge-before-live materialization.
- [Continuation paged-KV restore](CONTINUATION_PAGED_KV_RESTORE.md):
  canonical committed-row page images, complete source-chain validation, and
  fresh target cache/page generations.
- [Continuation live restart](CONTINUATION_LIVE_RESTART.md): fixed runtime
  state plus an exact-once two-process publication proof.
- [Continuation checkpoint file](CONTINUATION_CHECKPOINT_FILE.md): immutable
  whole-checkpoint archives, one atomic root selector, and seven-phase
  process-death recovery.
- [Atomic media stream checkpoint sets](MEDIA_STREAM_CHECKPOINT_SET.md):
  one-root image/audio/video generations, retained-output/processor/cache
  bundling, and previous/successor fresh-process resume under every selector
  boundary.
- [Materialized multimodal processor caches](MEDIA_PROCESSOR_CACHE.md):
  canonical cache payloads, processor-state binding, fresh-Bank
  charge-before-visibility restore, and exact release.
- [Mixed typed-workload conformance](TYPED_WORKLOAD_CONFORMANCE.md): separate
  canonical profile/item/plan contracts, family-neutral scheduler lifecycle
  callbacks, retained perception execution, authoritative replay, and final
  zero model/cache ownership.
- [Typed tool workload](TYPED_TOOL_WORKLOAD.md): separate proposal and local
  policy authority, fixed-storage idempotency and retained-state integrity,
  scheduler-before-mutation precommit plus infallible retained-lock publish,
  independent replay, and explicit external-effect nonclaims.
- [ActionOutbox protocol](ACTION_OUTBOX.md): stable external request identity,
  body/footer event records, uncertainty-preserving prefix recovery,
  acknowledgement/reconciliation separation, safe retry, separately authorized
  compensation children, and descriptor-relative POSIX durable storage without
  live dispatch authority.
- [Typed model-family contracts and vision adapter](MODEL_FAMILY_ADAPTER.md):
  canonical artifact/plan/result records, explicit support negotiation, and a
  cache-bound transactional embedding fixture with scheduler-owned
  final-service publication.
- [Typed audio-window encoder adapter](AUDIO_WINDOW_ADAPTER.md): signed feature
  windows, sample/window/hop source mapping, shared scheduled stateless
  publication, and exact cancellation/release.
- [Overlap-safe audio transcript adapter](AUDIO_TRANSCRIPT_ADAPTER.md):
  canonical context/new-sample ownership, predecessor-bound transcript
  segments, and transactional publication.
- [Typed temporal-video encoder adapter](TEMPORAL_VIDEO_ADAPTER.md): canonical
  strided-frame selection, keyframe/eviction lineage, charged gather scratch,
  exact target-time mapping, and scheduler-owned transactional embedding
  publication.
- [Typed video-segment adapter](VIDEO_SEGMENT_ADAPTER.md): fixed source/time
  bounds, event/confidence fields, processor/cache/selection lineage,
  predecessor chaining, and transactional typed publication.
- [Canonical video-segment timeline](VIDEO_SEGMENT_TIMELINE.md): fixed
  accumulated-tail state, deterministic coalesce/retain decisions, raw segment
  plus decision chains, and exact resource-backed publication.
- [Exact audio/video result link](AUDIO_VIDEO_RESULT_LINK.md): fixed
  cross-modal state/result wires, publish-only audio mapping, positive-overlap
  policy, dual-modality lineage, and atomic publication.
- [Stateful audio transcript continuation](AUDIO_TRANSCRIPT_CONTINUATION.md):
  exact transcript-model state, composed cross-modal checkpoint, fresh-process
  charge-before-materialization restore, and non-duplicated next publication.
- [Stateful VFR video-model continuation](STATEFUL_VIDEO_CONTINUATION.md):
  explicit per-frame timing/payload evidence, retained video-model state,
  composed timeline/link checkpoint, and fresh-process successor publication.
- [Stateful model adapter and latent-step fixture](STATEFUL_MODEL_ADAPTER.md):
  canonical retained-state publication, pinned lineage, disjoint candidates,
  and atomic state/result replacement.
- [Stateful model continuation](STATEFUL_MODEL_CONTINUATION.md): canonical
  intermediate checkpoint, fresh-Bank retained-state ownership, and exact-once
  terminal publication after a real process restart.
- [Generated-image publication](GENERATED_IMAGE_PUBLICATION.md): bounded
  terminal-latent decode, fixed provenance/result wires, atomic abort/retry
  visibility, and exact release after a real process restart.
- [Generated-audio publication and playback acknowledgement](GENERATED_AUDIO_PLAYBACK.md):
  bounded PCM rendering, one-outstanding-buffer backpressure, exact
  application acknowledgement, abort-safe visibility, and continuation across
  a real process restart.
- [Generated-video manifest and display acknowledgement](GENERATED_VIDEO_DISPLAY.md):
  ordered raw-frame publication, one-outstanding-segment backpressure, exact
  application acknowledgement, abort-safe visibility, and continuation across
  a real process restart.
- [Atomic generated-media checkpoints](GENERATED_MEDIA_CHECKPOINT.md): typed
  image/audio/video member admission, one lineage-bound checkpoint, and atomic
  previous-or-successor selection across four process-death boundaries.
- [Generated-media encoded payload archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md):
  one canonical manifest/checkpoint/member/payload generation, explicit
  raw/encoded/encoder/format identities, one outer selector, and idempotent
  previous-or-successor recovery across seven process-death phases.
- [Bounded generated-media output registry](GENERATED_MEDIA_OUTPUT_REGISTRY.md):
  an independent three-object archive ABI for canonical multi-image,
  multi-chunk audio, and multi-segment video ordering, structural completion
  fields, opaque state/completion roots, exact encoded payloads, and
  previous-or-successor recovery.
- [Canonical generated-media producer admission](GENERATED_MEDIA_PRODUCER_ADMISSION.md):
  exact typed image/audio/video record decoding, raw-output verification,
  common-envelope and predecessor derivation, and construction of the
  unchanged output registry before publication.
- [Host-verified generated-media producer transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md):
  exact deterministic source-model/materializer replay, independent one-shot
  image publication with derived collection order, complete audio/video
  acknowledgement reconstruction, and a separate evidence sidecar paired with
  the unchanged registry.
- [Exact speech annotation publication](SPEECH_ANNOTATION_PUBLICATION.md):
  canonical word/sample/speaker mapping, abort-safe publication, and annotation
  state continuation across a real process restart.
- [Shared media contract](MEDIA_CONTRACT.md): fixed image/audio/video identity,
  exact rational positions, explicit event roots, and logical chunk
  publication.
- [Bounded media decode fixtures](MEDIA_DECODE_FIXTURES.md): sealed plans,
  caller-owned RGB/PCM/video fixture decode, and complete source-unit mapping.
- [Deterministic media transforms](MEDIA_TRANSFORMS.md): sealed transform plans,
  allocation-free reference execution, exact mappings, and cross-language roots.
- [Multimodal roadmap](MULTIMODAL_ROADMAP.md): gated shared media identity,
  timeline, transaction, image, audio, and video tracks.
- [Glacier AI Runtime roadmap](AI_RUNTIME_ROADMAP.md): shared runtime planes,
  universal family adapters, coverage map, gates, and delivery sequence.
- [Native observation](NATIVE_OBSERVATION.md): portable availability,
  admission, sample-clock/value-clock identities, fallback, macOS adapter, and
  claim boundaries.
- [Evidence policy](EVIDENCE_POLICY.md): what results are allowed to claim.
