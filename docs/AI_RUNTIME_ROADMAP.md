# Glacier AI Runtime Roadmap

Glacier is evolving into a full AI runtime: one evidence-carrying execution
fabric for local, edge, accelerator, and provider-backed models. The runtime is
not defined by one model architecture. It is defined by the contracts every
model family must satisfy before it can consume resources, retain state, call an
external system, or publish output.

This document is an architecture and contribution roadmap, not a claim that all
listed families run today. Status follows the project-wide sequence:

`idea → prototype → integrated → validated → shipped`

Unsupported artifacts, operations, numerical modes, and capabilities must
reject explicitly. A generic adapter interface never turns an untested family
into supported functionality.

Operating-system support follows the same rule: canonical runtime contracts
stay portable while filesystem, virtual memory, process control, telemetry,
and accelerators enter through explicit capabilities. The current evidence and
promotion sequence live in [Platform Portability](PLATFORM_PORTABILITY.md).

## North star

One request should be able to move between a local CPU, an admitted accelerator,
an edge worker, and an explicitly authorized provider while retaining:

- exact artifact and preprocessing identity;
- bounded resource ownership and scheduling state;
- family-specific continuation state;
- transactional output visibility;
- usage, cost, provenance, and cancellation evidence; and
- a verifier that does not need model weights, private inputs, or credentials.

The same runtime should serve interactive generation, batch inference, feature
extraction, streaming media, generative media, agent actions, and scientific
model execution without flattening their different state or output semantics.

## Runtime shape

```text
artifact + request + authority
              │
              ▼
       family adapter
  inspect → plan → declare state/output
              │
              ▼
┌──────────────── shared Glacier runtime ────────────────┐
│ artifact identity │ admission │ schedule │ execution   │
│ state/continuation│ media     │ provider │ publication │
│ evidence          │ security  │ distribution           │
└────────────────────────────────────────────────────────┘
              │
              ▼
 CPU / accelerator / edge / provider backend
              │
              ▼
 candidate tensors, tokens, media chunks, actions, scores
              │
              ▼
 family validator + one atomic publication boundary
```

A backend performs computation. A model-family adapter explains the meaning of
its artifacts, state, operations, and outputs. The shared runtime decides
whether the work is admitted and whether its result may become visible.

## The shared runtime planes

### 1. Artifact and identity plane

Responsibilities:

- content-addressed weights, tokenizer, processor, vocabulary, adapters, and
  auxiliary assets;
- immutable model-family, architecture, tensor-layout, quantization, and
  numerical-policy identity;
- source-to-prepared-artifact lineage;
- bounded parsing before allocation or device upload;
- provenance, license metadata, tenant scope, and compatibility declarations.

Current state: **prototype with the R0 contract registry integrated**. Glacier
validates source and prepared `.glrt` layouts for the current text-generation
path, has typed continuation roots, and exposes canonical `ArtifactManifest`
wires plus a generated retained-reference compatibility registry. The text
loader does not yet bind its mapped artifact to that common manifest.
Adapter/processor composition remains planned.

Promotion gate: each advertised artifact combination has a redistributable
fixture, exact bounds, independent parsing evidence, and a named rejection for
unknown architecture, tensor, processor, or numerical mode.

### 2. Planning and execution plane

Responsibilities:

- sealed `ModelExecutionPlan` values derived before execution;
- explicit operation, input/output schema, bounds, scratch, numerical mode,
  backend requirements, and fallback policy;
- deterministic capability/inventory selection bound to the exact execution
  plan before resource or scheduler mutation;
- prefill, decode, encode, score, classify, retrieve, detect, segment,
  transcribe, synthesize, diffuse, and step operations;
- prepared kernel/tensor layouts and backend-neutral candidate results;
- no silent architecture, precision, device, or preprocessing fallback.

Current state: **prototype**. `DecodePlan`, CPU/optional Metal paths, INT4
experiments, sealed media decode plans, deterministic media transform plans,
and the canonical Model Contract V1 execution-plan ABI exist. Retained family
adapters and an experimental C boundary verify that common ABI, but the current
text execution path does not consume it. The first device-negotiation slice is
now integrated: portable pointer-free capability fingerprints, canonical
discovery-epoch inventory, canonical operation/type/numerical profiles,
plan-bound requirements, and allocation-free deterministic selection reject
incompatible or malformed devices before resource or scheduler mutation.
Derived aggregate bit sets cannot invent an untested cross-profile
combination. The native macOS Metal adapter projects stable device information
into that contract, binds one bounded local discovery epoch, and revalidates
the selected fingerprint and registry identity before the first Metal resource
acquisition and again through post-run evidence. See
[Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md).

Device-loss Observation V1 is the next completed decision-evidence layer.
The 40-byte `SourceCursorV1`, 280-byte `ObservationV1`, and 272-byte
`TransitionReceiptV1` bind a native source instance, increasing source
sequence, and native/synthetic evidence class to an exact prior present entry
and recomputed inventory root. Sequence gaps are valid; callers must durably
and atomically commit the advanced cursor. The native Metal context installs
`MTLCopyAllDevicesWithObserver`, validates and retains initial selected-device
identity, records source facts in a sticky bitset with a monotone effective
state, and claims each exact snapshot at most once. The source-instance digest
binds a 256-bit per-context nonce, observer-generation reset discriminator,
registry ID, and stable device/placement identities; it does not rely on the
64-bit generation alone for durable freshness. A native admission lease covers
new work and live `deviceInfo`/`allocationLimits` property reads:
already-admitted operations may settle, while admission after loss rejects.
Source mismatch fails closed; fresh adoption requires a new inventory and exact
initial sequence 1 and grants no recovery or migration. Exact native
command-buffer removal requires status/domain/code `5/1/11` before any
test-only overlay. Transition receipts preserve capability and policy rank
while deriving a newer `unavailable` or `lost` successor. Their hashes verify
composition and integrity, not authenticity or attestation.
See [Device Lifecycle Observation V1](DEVICE_LIFECYCLE.md).

Device-loss Retirement V1 is the completed loss-bound ownership follow-up for
one exact quiesced allocation. Its fixed-width plan composes the accepted
`lost` transition with selection, allocation authority, LeaseTree lease,
leaf/object sets, recovery generation, and a private adapter challenge.
Production Metal arming requires the same live sticky native loss source and
drops exact buffer strong references without reading live device or buffer
properties after loss. The existing coordinator retains FreePermit authority,
so logical charge returns only after every release succeeds. The receipt
explicitly grants no physical-reclaim, output, migration, reset, or residency
authority. See [Device-loss Retirement V1](DEVICE_LOSS_RETIREMENT.md).

Capability-selection/execution promotion gate: the execution plan fully
predicts memory and output ceilings, the backend confirms exact capability
identity, and unsupported combinations fail before visible state or output
changes.

The selection receipt is decision evidence only. Physical-page commitment,
reclamation, and residency authority/evidence, fresh selection/migration,
multi-GPU
partitioning/scheduling, direct physical telemetry, performance evidence,
native device ranges, and native support on cross-compiled targets remain
open.

### 3. Resource plane

Responsibilities:

- exact logical claims for weights, activations, KV, latent state, media
  buffers, scratch, output, device residency, network attempts, and tool calls;
- hierarchical `ResourceBank` and `LeaseTree` ownership;
- memory tiering, weight paging, cache admission, pinning, and retirement;
- per-tenant ceilings and cancellation-safe release;
- physical telemetry recorded separately from logical accounting.

Current state: **integrated for logical ownership**, **prototype for physical
residency**. Exact claims and hierarchical leases are used by current runtime
state paths. The model-free media vertical now derives and reserves exact
activation, output, staging, I/O, and queue claims before execution. Decoded
source, mapping, optional scratch, and output regions now receive distinct
`LeaseTree` allocations; provisional regions retire early after commit and all
paths return ownership to zero. The scheduled-media path additionally adopts
the exact admission receipt instead of reserving again, then performs one
failure-atomic bound close and release. The device path now reserves complete
adapter-quoted waves before allocation, retains private FreePermit recovery,
and can pin the exact live object set across a bounded dispatch. The Metal
adapter now exposes two fixed async lanes. Each pointer-free,
generation-fenced `MetalAsyncDispatchTicketV1` binds its adapter-local slot;
exact replay does not commit again, a third distinct request rejects before
native submission, poll/wait are separate, and pending preserves output, its
pin, and its charge. Either slot may complete and settle first without
mutating its sibling. Exact completed output is bound to the command,
submission, snapshot, and output role, checked against a CPU oracle, and
retained until Bank settlement authorizes that slot's native finalization.
`ResourceBank.snapshotV4()` adds exact pin capacity, metadata, current/peak
activity, operation/rejection counters, and reserved completion headroom while
preserving earlier snapshot ABIs. Accepted pins reserve generation and
structural-revision headroom so out-of-order completion cannot be stranded near
exhaustion. For the bounded INT4 profile,
the adapter issues a
generation-fenced `MetalMatvecDispatchRequestV1`; that sealed request root,
never the raw attempt root, is the pin's dispatch-request root. Core seals
`DispatchPinIntentV1`, calls reserve before Bank mutation, aborts exactly if
atomic pin acquisition fails, and validates the callback source before binding
the lease, request, intent, and pin. Valid preflight either submits or settles
the pure `cancelled_before_submit` path; malformed attempts settle exact
`rejected_before_submit`. Both no-submit terminals use zero submission,
backend-completion, and output roots and the same private settlement path.
Ambiguous submission, unknown or invalid completion, and a terminal command
error first retain sticky nonterminal `MetalAsyncDispatchQuarantineV1`. One
exact retained native command-buffer `.error` can be explicitly bound to
`MetalAsyncDispatchTerminalFailureV1` and a matching core
`terminal_failure` with no output root. Authorization retains quarantine, pin,
charge, buffers, and native command. Core then consumes its private Bank pin;
only the private post-Bank callback exact-finalizes that same native `.error`
record before atomically clearing adapter state and recording a replay
tombstone. Ambiguity, unknown, and invalid completion remain sticky until the
separate loss-authorized Phase B protocol succeeds. Public
`acknowledgeDispatchCompletion` only verifies compatibility; it grants no
authority and clears no state. This terminal-error sidecar does not classify
device loss or migrate work on its own. The separate lifecycle layer observes
source-bound removal signals and fails new work closed without making this
dispatch path a recovery authority. A separate retirement path can now close
an already quiesced loss-bound allocation through ordinary FreePermit
settlement, but cannot terminalize retained work.

Device-loss Dispatch Reconciliation Phase A covers one narrower retained case:
an active command with exact native Metal status/domain/code `5/1/11`. Its
pointer-free 440-byte retention, 240-byte plan, and 448-byte receipt replay the
lifecycle transition, deterministic selection, live lease and pin, terminal
failure, dispatch completion, and Bank completion. The production gate is
native-only. Core retains the private Bank permit and settles it before the
adapter exact-finalizes the same native command; a settlement tombstone makes
lost confirmation retryable without another Bank release or native
finalization. Allocation retirement remains a separate operation after the
dispatch slot is gone. The real-GPU fault gate reaches this flow through an
explicitly synthetic published-error overlay, so it is not physical
device-loss evidence. See
[Device-loss Dispatch Reconciliation](DEVICE_LOSS_DISPATCH_RECONCILIATION.md).

Device-loss Dispatch Callback Retirement Phase B covers the exact `pending`,
`submission_ambiguous`, `completion_unknown`, and `invalid_completion`
ownership states. Its pointer-free 464-byte retention, 240-byte plan, 408-byte
fence, and 504-byte receipt bind the same live dispatch to an ARC-owned native
callback detachment, dedicated zero-output ownership-retired terminal,
Bank-first settlement, exact native unlink, and replay tombstone. Callback exit
is not a fence prerequisite, and allocation retirement remains separate.
Production requires exact native `removed_notification` or
`command_buffer_device_removed` evidence plus same-source sticky revalidation.
Portable Zig/Python coverage is structural; the build-isolated native matrix
runs real Metal commands/resources for all four states. It combines a held
pending handler, a post-commit ambiguous disposition authenticated by the
native record, a valid unknown projection over independently verified physical
success, and an exact completed-output-read rejection before caller memory is
written. Synthetic injected loss authorizes retirement. This is not physical
removal, driver or hardware failure, output recovery, performance, residency,
migration, reset, or physical reclaim. See
[Device-loss Dispatch Callback Retirement](DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md).

The Metal backend now retains direct Phase B protocol telemetry separately
from that authority. Its production 256-byte
`MetalDispatchRetirementTelemetryV1` snapshot binds native registry/context
identity to successful unique/replayed prepare and commit transitions, live
prepared ownership, callback detachment, frozen native fact buckets, exact
record/reference/tombstone totals, retirement generations, and sticky
saturation. Reads and failed operations do not advance it. It is diagnostic
only: these logical/native ownership counters are not physical residency,
utilization, queue, power, thermal, frequency, energy, performance, callback
exit, completion, output, release, or migration evidence.

Physical residency, fresh selection, dynamic scheduling beyond the fixed
two-slot adapter, multi-device placement, production weight paging, direct
physical device telemetry, additional GPU backends, and native OS matrices
remain planned.

Promotion gate: every retained allocation is owned, every rejection and
cancellation returns the declared delta, and measured physical counters are
never inferred from logical claims.

### 4. Scheduling plane

Responsibilities:

- admission, priority, weighted fairness, deadlines, batching, and backpressure;
- prefill/decode, encoder batch, diffusion-step, frame/audio-window, and tool
  action scheduling;
- safe preemption points declared by each family adapter;
- cancellation propagation through local, device, provider, and tool backends;
- replayable scheduling decisions without relying on wall-clock ordering.

Current state: **integrated control-plane prototype**. `LaneWeave` supplies
deterministic weighted service and cancellation. The first versioned
explicit-open-loop pressure fixture now composes real `LaneWeave`,
`ResourceBank`, and verifier state across image/audio/video profiles and retains
exact capacity/resource rejection, fairness, timeout, cancellation, delay,
high-water, and zero-orphan evidence. An additive sidecar now executes the
completed audio, video, and image media transactions on their final service
quanta and binds exact outputs/publication receipts without changing the
workload wires. The shared stateless lifecycle now also lets the retained
vision, audio-window, and temporal-video adapters adopt that scheduler receipt,
preflight their typed result, publish through the final V2 service commit, and
retire atomically without a second admission. A separate coordinate-addressed
generator retains 32 bounded W0/W1 cases from four seeds, with independent
Python generation and verification plus deterministic exact-signature
shrinking. W3 now adds a separately versioned, finite-source deterministic
closed-loop controller with FIFO next-step replacement, exact lineage,
independent replay, and final zero ownership. W4a now adds a separate typed
plan and family-neutral lifecycle driver that composes the retained vision,
audio-window, and temporal-video adapters under the exact scheduler receipt,
with completion-only publication, authoritative replay, and final zero
model/cache ownership. W4b-a now adds a process-local typed tool
transaction with separate proposal/policy authority, exact execute/reuse/deny/
conflict evidence, and atomic delivery on the scheduler service event.
W4b-b adds a separate portable ActionOutbox record/recovery campaign with
stable remote-request identity, explicit uncertainty, a reconciliation record
required before safe retry, and separately authorized compensation. W4b-c adds
a descriptor-relative POSIX durable store over the unchanged canonical stream:
semantic preflight, advisory locking and namespace/identity fences, ordered
body/footer sync, exact snapshot/lease/repair roots, explicit repair and fresh
reacquisition, independent write/repair matrices, and 49 real host process
deaths. W4b-d adds a credential-free pointer-free adapter contract, a driver
that durably commits intent before invoking a callback, protects one future
reconciliation slot per uncertain action, and admits status only when free
slots cover all uncertain actions, plus a bounded fixed-storage same-process
fake dispatch/status authority. Only an atomic
`not_applied_fenced` status for attempt `G` returns the action to `ready`;
delayed dispatch through `G` rejects, while a retry uses exactly `G + 1`, the
same stable request, and a new dispatch root. Live provider/tool effects, real
credential handling, OS isolation, service-restart persistence, stateful and
streaming profiles, family-aware batch, preemption, and multi-device profiles
remain planned.

Promotion gate: retained mixed-family pressure campaigns meet declared
fairness, deadline, logical-resource, cancellation, and zero-orphan invariants;
native campaigns separately validate physical memory and timing.

### 5. State and continuation plane

Responsibilities:

- autoregressive KV, recurrent state, encoder caches, embeddings, retrieval
  cursors, diffusion latents, scheduler steps, media timelines, temporal caches,
  audio windows, generated chunks, and tool/action history;
- typed state roots rather than one universal opaque blob;
- checkpoint lineage, fresh-generation ownership reacquisition, and
  family-specific restore validation;
- process restart, host migration, and eventually device-failure policies;
- exact resumed publication position.

Current state: **integrated model-free continuation plus typed stateful-model
prototype**. Glacier has capsules, bounded object resolution/storage/lifecycle,
paged-KV remap, sampler/output restore, two-process next-token publication,
atomic complete checkpoint selection, and a synthetic two-step latent chain
that restores its intermediate state in a distinct process. The prepared-text
slice now also carries a canonical restart manifest and checkpoint/successor
evidence through source-live, source-exited, and terminal selector generations;
an exclusive POSIX lease and one-shot activation grant fence the fresh target,
and a receipt-independent terminal semantic matches a separately retired
baseline. Production-model state adapters, GPU-resident continuation, Windows
durable files, and native multi-OS recovery campaigns remain pending.

Promotion gate: uninterrupted and resumed output satisfy one declared numerical
mode, foreign state rejects, and all reacquired ownership returns to zero after
release. Exactly-once external delivery additionally requires acknowledged
durable sink progress; an in-memory no-duplicate fixture is not that claim.

### 6. Media plane

Responsibilities:

- content and policy identity for image, audio, and video;
- sealed decode and deterministic transform plans;
- exact region, sample, frame, timeline, patch, feature, and output mappings;
- bounded streaming input and generated-media chunk publication;
- model-visible processor identity and cross-modal synchronization.

Current state: **integrated model-free runtime vertical**. Fixed media objects,
rational timelines, bounded RGB8/PCM s16le/intra-frame gray8 decode, and
deterministic image crop/nearest/tile, audio weighted mix/exact decimation, and
video keyframe selection now compose with exact `ResourceBank` admission,
per-buffer `LeaseTree` ownership, provisional caller-owned storage, candidate
revalidation, atomic media/resource publication, abort scrubbing, retry, early
provisional retirement, exact release, and fixed independently verified runtime
receipts. A bounded stream session now commits two retained chunks for each
modality, rejects target gaps/overlaps before admission, reclaims cancelled
chunks, and emits a portable predecessor-bound receipt chain. A fixed stream
checkpoint now carries retained-output ownership through a real source/target
process restart; the target charges a fresh Bank before materialization and
publishes the next chunk exactly once for all three retained modalities.
Three checkpoints plus one canonical retained-output bundle now publish as one
atomic archive root. Two lineage-bound generations resume as complete
previous/successor sets across all seven native process-death boundaries.
A restarted runtime now rebinds all retained outputs, appends one chunk for
each modality, publishes generation three, and supports another fresh-process
resume from that new root. A separate fixed 2,272-byte processor-state bundle
now advances image tile/patch progress, audio feature windows, video temporal
cache state, and an exact integer synchronized watermark through two verified
generations. The bundle is now the fifth checkpoint object, while a sixth
object carries exact cache payloads through fresh-Bank charge-before-visibility
restore. Typed transcript/video-segment fixtures now preserve source/cache
lineage, a deterministic video timeline preserves accumulated event bounds, and
an exact cross-modal result-link transaction maps only newly publishable audio
samples onto that tail. External codecs, capture, playback, and production
media models remain gated. The first generative output slice now decodes one
exact post-restart terminal latent and atomically publishes a bounded raw image,
provenance, typed result, resource receipt, and media transition. Generated
audio now adds ordered bounded PCM publication, one-buffer backpressure,
application acknowledgement, cancellation, and a distinct-process restart
proof. The model-free generated-video fixture now publishes an ordered
two-frame manifest with exact durations, one-segment backpressure, application
display acknowledgement, cancellation, and a distinct-process restart proof.
One fixed generated-media member ABI now normalizes those three output paths.
An 800-byte checkpoint binds exactly one completed image, one acknowledged PCM
chunk, and one acknowledged raw-video segment, while a 352-byte selector makes
only the complete previous or successor generation visible. Independent Python
verification and four native process-death boundaries reject mixed generation,
scope, policy, challenge, result, output, state, and completion substitution.
A canonical 864-byte payload manifest now joins that checkpoint, its three
members, and three exact encoded payloads into one eight-object immutable
archive. Raw-output, encoded-payload, encoder-implementation, format, scope,
policy, challenge, archive-parent, and manifest-predecessor identities remain
separate. One outer filesystem selector recovers the exact previous generation
after five publication-phase process deaths and the exact successor after two,
then converges idempotently. An independent Python oracle verifies the archive
without model execution. An independent bounded registry ABI now orders one to
four outputs per present modality, up to twelve, and binds exact
ordinal/unit/timeline/predecessor continuity, opaque state/completion roots, and
exact payload bytes in three extension objects under the same selector. Typed
producer admission now closes that precondition: a separate gateway decodes
the retained typed image, audio, and video record sets, verifies exact raw media
bytes, derives their common request envelope and strict state/result/completion
predecessors, and constructs the unchanged registry generation. A
higher-assurance producer-transition path now adds exact deterministic
source-model and
materializer replay for the retained reference profiles. It reconstructs
one-shot image publication and complete audio/video acknowledgement
transitions, then emits fixed per-output receipts in a separate sidecar bound
to the exact unchanged registry archive. Strict allocation-free delivery
modules now emit and accept bounded canonical PNG, PCM/WAVE, and APNG profiles.
  An integrated bounded format-evidence sidecar binds those payloads to their
  producer plan or manifest, registry entry, transition receipt, format contract,
  and predecessor format lineage without changing the existing V1 wires. The
  leaf profiles have native macOS test evidence and module-level
  Linux/Windows/FreeBSD cross-compilation. Real two-generation PNG, WAVE, and
  APNG fixtures pass through the registry, producer-transition, and format
  validators with exact successor, missing/foreign predecessor,
  semantic-drift, and failure-atomic output checks. Audio and video use the
  typed playback/display acknowledgement chains. An independent Python oracle
  validates all three binary layers and producer semantics, and the read-only
  inspector optionally validates the exact current/predecessor format pair
  before rendering a versioned no-payload JSON document. The composed format
  target cross-compiles for x86_64 Linux musl, Windows GNU, and FreeBSD.
  Production encoder/container adapters, broader profiles, native
  Linux/Windows execution, physical playback/display evidence, quality
  evidence, and power-loss durability remain gated.

Promotion gate: accepted model inputs and visible outputs map to exact source or
generation plans, with bounded geometry/time, cancellation, continuation, and
provenance.

### 7. Provider and edge plane

Responsibilities:

- exact rendered request bytes, attempts, retries, cancellation, terminal usage,
  pricing identity, settlement, and durable cost evidence;
- local preprocessing and cache decisions with lossless logical mappings;
- provider capability and model identity negotiation;
- privacy policy, secret isolation, regional routing, and data-retention scope;
- edge/offline queue, synchronization, and conflict policy.

Current state: **integrated credential-free control-plane prototype**. Context
packing, gateway state, transport harness, settlement, cost journal, and compact
evidence join exist. An experimental read-only inspector verifies the join's
fixed outer framing and checksum, then renders only self-asserted scalars and
digests as deterministic JSON. It does not verify nested composition, provider
execution, usage, cost, authenticity, or authority. Live adapters remain
outside the authority-free core.

Promotion gate: credentials and private payloads never enter core evidence;
ambiguous attempts never double-settle; provider-reported usage attaches to the
exact terminal attempt; and no local byte count is presented as billed usage.

### 8. Publication plane

Responsibilities:

- atomic visibility for tokens, tensors, scores, labels, boxes, masks,
  embeddings, retrieval results, transcripts, video segments, media chunks,
  and actions;
- provisional output separated from visible output;
- sequence, lineage, ownership, scheduler permit, and evidence roots committed
  together;
- idempotent retry and replay rejection;
- streaming acknowledgement and partial-result policy.

Current state: **integrated for tokens, model-free media, bounded typed
perception fixtures, generated-image publication, generated audio/video
publication with application acknowledgement, and atomic three-modality
generated-output selection plus exact encoded-payload archive composition and
bounded multi-output registry continuity with canonical producer admission and
host-verified reference producer-transition replay**.
Media transactions compose
exact resource admission, transformed output, timeline advancement,
transcript/video-segment visibility, deterministic merge decisions, cross-modal
result links, terminal-latent image/provenance visibility, and ordered PCM
and raw-frame visibility behind explicit commit boundaries; abort scrubs
provisional bytes and leaves publication state unchanged. Audio and video paths
accept only complete sink-bound application observations before their
successors. One fixed checkpoint then cross-binds the image, audio, and video
results, outputs, post-publication states, completions, totals, and predecessor
behind one atomic selector. A downstream eight-object archive now binds that
typed generation to three exact encoded payloads behind one outer filesystem
selector. An independent registry ABI extends the retained shape to one through
four output entries per present modality, no more than twelve, using ordered
fixed entries and exact concatenated payload bytes in three archive objects
under the same selector. Registry completion/state roots remain opaque; typed
producer acknowledgement/state validation now occurs in the separate
pre-publication gateway, which also checks exact raw bytes and derives rather
than trusts the common envelope, registry generation/sequence, and
predecessors. A higher-assurance sibling replays the exact deterministic
source-model and materializer callbacks, reconstructs image or complete
audio/video completion transitions, and binds fixed receipts in a separate
  evidence sidecar to that unchanged registry. An integrated bounded additive
  format sidecar binds strict canonical PNG/WAVE/APNG payloads to those receipts
  and typed producer semantics across real two-generation fixtures without
  rewriting the registry or transition wire. Generic tensor/action envelopes,
  partial-stream policy, production
encoder/container adapters, broader format profiles, additional replay
profiles, native platform execution, and physical playback/display evidence
remain planned.

This replay proves deterministic reconstruction on the verifying host. It does
not prove historical execution, live resource authority, physical sink
behavior, external codec/container correctness, or performance.

Promotion gate: every output family has a named atomic unit, rollback behavior,
replay rule, and continuation position; cancellation cannot expose an
unaccounted partial result.

### 9. Evidence and observability plane

Responsibilities:

- portable wires, canonical roots, event chains, independent verifiers, and
  mutation-complete fixtures;
- versioned workload scenarios with fixed seeds, arrival schedules, family
  mixes, concurrency, duration, warmup, and resource ceilings;
- latency, throughput, memory, energy, utilization, quality, and cost reported
  under a captured machine/provider envelope;
- trace correlation without storing raw private inputs in core records;
- human-readable inspectors that never turn unverified bytes into authority;
- claim boundaries generated beside benchmark results.

Current state: **integrated evidence building blocks**, **prototype inspection
and workload tooling**. The experimental generated-media inspector validates a
registry archive plus its producer-transition evidence, requires the exact
predecessor pair for successors, and can optionally validate
current/predecessor format sidecars through the composed oracle. A separate
provider evidence command intentionally has a narrower boundary: it validates
only the 712-byte join envelope's framing and checksum and labels all rendered
nested values self-asserted, with composition and authority fixed to false. The
first portable workload-pressure contract drives a bounded mixed-media
explicit-open-loop scenario through the real scheduler and resource bank, with
exact Zig replay and an independent Python oracle. Its additive scheduled-media
sidecar executes the three completed image/audio/video transactions under the
same admission receipts and binds exact publication evidence. A separate
prepared-text restart fixture runs baseline, source, and target subprocesses,
checks exclusive lease/grant behavior, selector generations, terminal-semantic
equality, and zero final logical ownership. It uses a narrowly scoped POSIX
durable-file adapter for the archive and selector while granting no general
payload, device, or live resource authority. The inspection and evidence
formats remain deterministic, versioned, and non-authoritative. W5a now adds a
separate portable native-observation descriptor/rule/plan/record/bundle ABI and
a family-neutral runner. It preserves explicit
`present`/`missing`/`denied`/`unsupported` states, host and accelerator planes,
stable source identity distinct from per-event provenance, nonzero reason
identity only for unavailable records, sample-clock identity on every
observation, value-clock identity only on present time-valued metrics,
fail-closed probe/pre-run admission, retained post-run contamination,
correctness, zero-orphan, and accelerator-fallback evidence. Its canonical
three-profile/six-item typed-perception reference needs no model download. A
bounded macOS adapter supplies the first shared native host-observer seam and a
bounded readable JSON reason only when unavailable. The first follow-up
introduces a platform-neutral JSON registry/validator and dispatcher plus a
strict bounded Linux `/proc/meminfo` `MemAvailable` adapter; cross-host tests
cover its parser and availability behavior, while native Linux retention
remains open. A native macOS Metal readiness adapter now binds the runner to
exactly one fixed synthetic 37x64 INT4 matrix-vector dispatch across its hard
gate. It requires CPU-oracle correctness, completed command-buffer GPU
timestamps, registry-bound device/placement identity, allocation context, zero
leaked ownership, no fallback, and composed roots. This is diagnostic readiness
evidence, not a throughput, latency, or performance claim. That native adapter
now also binds the portable selection to one local discovery epoch and
revalidates its selected capability and registry identity against the same
Metal device. Separately, the corrected tiled FP16 matmul
matches its CPU oracle on asymmetric partial-edge shapes and rejects malformed
exact buffer geometry before output mutation. This expands tested correctness,
not advertised device range or performance. A separate receipt-bound
allocation contract now uses a deterministic fake adapter to prove quote
replay, exact adapter-quoted charge-before-allocate ordering, multi-buffer rollback,
cleanup recovery, and stale ownership fencing. Its native Metal adapter
creates and directly inspects real per-object resources, releases them before
uncharge, and proves generation-fenced slot reuse on the executing host. It
does not claim residency. The LeaseTree path binds each pin to the
adapter-issued, generation-fenced `MetalMatvecDispatchRequestV1` root through a
core-sealed `DispatchPinIntentV1`. Core reserves before Bank mutation and
aborts exactly on atomic acquisition failure. Callback/source validation
precedes the exact lease/request/intent/pin binding. Valid preflight can submit
into either of two bounded adapter-owned async slots or produce pure
`cancelled_before_submit`; malformed input can produce exact
`rejected_before_submit`. Submit returns `MetalAsyncDispatchTicketV1`; exact
replay does not recommit, pending preserves output and ownership, and poll/wait
authenticate the retained command and four exact buffers. A third distinct
request rejects before native mutation while both slots are occupied. Exact
completed output is bound to the submission, immutable snapshot, and output
role. Core consumes the matching private Bank pin before the private callback
finalizes that exact native record, clears only its slot, and records a replay
tombstone. Both no-submit terminals carry zero submission,
backend-completion, and output roots and use the same settlement without a
native record. Public
`acknowledgeDispatchCompletion` is compatibility verification only. Rejection
may inspect the native device and resources but creates and submits no command
buffer; cancellation is native-free after the sealed binding. Ambiguous
submission, unknown or invalid completion, and terminal command errors first
become sticky nonterminal quarantine evidence. An exact retained native
command-buffer `.error` can now authorize core `terminal_failure`; its
quarantine, pin, charge, buffers, and command remain live through Bank
settlement, then the private callback exact-finalizes that same `.error` before
clearing private state. Ambiguity and unknown completion remain sticky until
the separate loss-authorized Phase B protocol succeeds.
Portable Zig state tests and the independent Python mirror exercise the exact
failure roots, mutations, and pre-settlement retention contract without GPU
work. The native
macOS gate opens a real `MTLDevice`, creates real `MTLBuffer` resources, and
executes the valid command on the device as a success regression; it does not
induce or claim a hardware error. Its isolated two-slot pressure case uses one
eight-object lease with two disjoint four-buffer role sets, submits both
commands, observes two live native records, waits for both completions, and
deliberately settles the second before the first. Both outputs match CPU
oracles and all records, pins, and buffers close. This proves bounded
coexistence and settlement isolation on the executing M1, not physical GPU
parallelism, command-completion order, or throughput. The same native lifecycle surface installs a
real observer and fails new work closed after removal-requested, removed, or an
exact native command-buffer code `11`, which is fenced before any test-only
overlay. Admission is linearized by a native lease, so already-admitted work
and live `deviceInfo`/`allocationLimits` property reads share the same race
boundary: earlier operations may settle while admission after loss rejects. On
the built-in M1 development host, the snapshot stayed at initial membership
around a real successful command. A native two-thread exact-consumption race
required one consumed result and one stale result while leaving the snapshot
readable. None of those loss sources occurred. Transition and error paths are
covered by deterministic synthetic/model tests. The isolated native retirement
gate separately releases real buffers under an explicitly synthetic test-only
loss permit; it proves ownership cleanup, not physical removal. The same
isolated configuration exercises command-specific Phase A reconciliation
after a real GPU command succeeds by publishing a separate synthetic
code-`11`-shaped error overlay. That proves exact retention, Bank-first
settlement, tombstone replay, and native finalization on the test path, not a
physical failure. The same build-isolated native configuration now runs all
four Phase B retained states over real commands/resources. It combines a held
pending handler with synthetic disposition, physical-success completion, and
completed-output-read seams, then exercises Bank-first native unlink and
replay; the held case additionally proves detach-before-exit and later handler
release. It is not a physical removal, driver-failure, output-recovery,
performance, residency, migration, reset, or physical-reclaim campaign. A
removable-hardware callback campaign, fresh selection and migration,
dynamic scheduling beyond two slots, multi-device placement, physical
residency and device telemetry, additional GPU backends, and broader native
OS/device matrices stay open.
Contract validation requires a present logical CPU count of at least one and
accepts signed physical temperatures down to, but never below, absolute zero.

Promotion gate: every promoted claim names the workload, platform, numerical
mode, baseline conditions, verifier, retained artifacts, and nonclaims.

#### Workload, stress, and soak campaigns

Load evidence is a required runtime feature, not a single marketing number.
The complete W0–W8 sequence and report contract are defined in the
[Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md). The track has three
deliberately separate campaign classes; replicated execution is a higher
evidence level applied to retained native campaigns. W5a supplies the common
observation and admission foundation between deterministic pressure and native
reporting:

1. **Deterministic pressure — W0 through W4a plus the W4b-a tool slice
   implemented.** V1 replays one bounded
   model-free explicit arrival schedule to verify admission, weighted fairness,
   deadline completion, timeout, cancellation, overload rejection, exact
   logical accounting, and zero orphaned ownership. Its canonical
   scenario/result wires, nearest-rank logical-step summaries, exact replay,
   and independent Python verifier are documented in
   [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md). A separate sidecar
   now proves final-quantum image/audio/video fixture execution, atomic
   publication, single-receipt ownership, and terminal absence for rejected,
   cancelled, and timed-out work. W2 adds a coordinate-addressed 32-case
   generated deterministic open-loop corpus, independent Python reproduction, and a
   synthetic exact-signature local-minimum shrink fixture while preserving the
   earlier wires and reference roots. W3 adds an independent finite-source
   plan/result ABI: terminal outcomes create trace-ordered FIFO credits,
   successors arrive only on the next logical step, lineage and target bounds
   replay exactly, and ownership reaches zero. It does not execute W1 media,
   models, providers, tools, asynchronous workers, or native concurrency.
   W4a separately drives retained vision, audio-window, and temporal-video
   adapters through canonical typed profiles and items. It binds admitted work
   to the scheduler-owned receipt, executes only at final service, publishes
   only completed typed results, independently replays the logical schedule,
   and closes model/cache ownership to zero. A separate W4b-a report drives one
   bounded process-local tool through proposal authorization, locked
   scheduler-before-mutation precommit, exact-once logical execution, duplicate
   receipt reuse, denial, conflict, cancellation, timeout, rejection,
   independent replay, and zero authority. W4b-b separately retains canonical
   external-action intent records: every unresolved dispatch remains uncertain,
   retry requires a committed `reconciled_not_applied` record, and compensation
   is a new child action. Its native/Python campaign covers all 7,521 retained
   cuts from the complete header through the journal. W4b-c separately tests
   durable storage with 40 append-phase, 754 section-prefix, 751 repair-tail,
   and 8 repair-fault deterministic cases, then 49 real `SIGKILL` deaths across
   initialization, append, and repair. This proves the named POSIX host
   process-death fixture, not power-loss behavior, authenticated provider truth,
   live dispatch, external exactly-once delivery, or Windows durability.
   The adjacent W4b-d code slice now provides a bounded same-process fake
   dispatch/status authority: intent is durable before callback, and only an
   atomic generation fence authorizes retry. An independent Python model
   rebuilds its roots and fence/transition behavior and verifies a live
   canonical Zig report, but there is no retained JSON fixture. The slice adds
   no process-death, platform,
   performance, or external exactly-once evidence. Provider, stateful,
   streaming, live external-tool dispatch, OS-isolated credential handling,
   batching, preemption, device execution, and real backpressure remain
   planned.

   **W5a observation foundation — implemented.** Fixed portable observation
   values bind workload, artifact, build, machine, backend, device, placement,
   worker/queue counts, rules, units, subjects, stable source identity,
   per-event provenance, per-record sample-clock identity, and value-clock
   identity only for present time-valued metrics. Stable source identity drives
   `same_source`; per-event provenance may change. Unavailable records retain a
   nonzero reason identity while present records carry none.
   The runner rejects probe or pre-run violations before starting a workload,
   invokes work at most once, and retains a completed receipt plus post-run
   contamination as nonpublishable evidence. The reference reuses three
   retained typed-perception profiles and six items without downloads. The
   macOS adapter and paired harness share strict system-field and
   external-process CPU parsers. A platform-neutral JSON layer and bounded
   Linux available-memory adapter are now implemented, but the required native
   Linux smoke is not retained. Accelerator metric IDs and fallback rules are
   present. The separate native macOS Metal readiness implementation runs one
   fixed 37x64 INT4 dispatch exactly once across the hard gate and directly
   records registry identity, `currentAllocatedSize`, and command-buffer
   start/end timestamps while checking correctness, ownership, no fallback, and
   root composition. `recommendedMaxWorkingSetSize` is capacity context only;
   direct utilization, committed/resident bytes, queue depth, power, thermal,
   frequency, and energy remain unsupported. A separate native allocation gate
   performs one four-buffer hardware-backed dispatch while an exact LeaseTree
   pin fences release, then compares output with a CPU oracle and closes all
   ownership. Portable Zig fake/state tests and the independent Python oracle
   model this deterministic contract without a GPU. The native macOS Metal gate
   uses a real `MTLDevice` and real `MTLBuffer` resources: its valid branch
   submits a real command, waits, and checks a CPU oracle. Its reject and cancel
   branches retain real context/resources but issue zero GPU commands;
   rejection may inspect them, while cancellation logic remains native-free
   after the sealed lease/request/intent/pin binding. Neither native gate is a
   performance benchmark. See
   [Native Observation Contract](NATIVE_OBSERVATION.md).

   **W5b readiness progress — implemented, milestone open.** A successful
   native gate is diagnostic evidence for its exact macOS host session. Its
   independent verifier checks bounded semantic composition and corruption of a
   self-asserted live capture, not cryptographic authenticity. The repository
   retains no addressable W5 readiness result yet; the separate retained W6b
   production-workload wire and manifest do not substitute for readiness
   observation. W5b still requires the unsupported physical adapters, a
   retained readiness artifact, and broader platform coverage.

2. **Native workload** runs declared model-family mixes against a real CPU,
   accelerator, or provider adapter and records completed/rejected/cancelled
   work, throughput, p50/p95/p99 latency, queue delay, memory high-water,
   CPU and device utilization, host/device memory separately, accelerator
   submit/device/synchronization timing, fallback status, power/thermal/energy
   when available, and output-quality policy.
3. **Soak and disruption — W7a, W7b-a, W7b-b1 through W7b-b4
   implemented; remaining W7b-b work is open.**
   W7a runs 50 fixed production-native Metal epochs and retains 250 raw records
   around 100 real GPU commands. Each epoch settles an admitted cancellation
   and one exact malformed pre-submit rejection, then submits both bounded
   logical lanes, proves that a distinct full-slot request preserves the named
   public snapshots, tickets, and request/ticket generation cursors, completes
   both commands against CPU oracles, revalidates device/placement identity,
   and returns to the same persistent-allocation boundary. The portable and
   exact profile verifiers recompute the five-record outcome pattern, 25-event
   schedule, summary, action/evidence commitments, generation-bound capacity
   roots, unique generation roots, 200/200 Bank-pin closure, and final zero
   ownership. See
   [Native Metal controlled-disruption report](NATIVE_METAL_DISRUPTION_REPORT.md).

   W7b-b3 adds a focused concurrent-caller cancellation profile. In each of
   eight blocks of eight waves, two real host threads reach one ready barrier
   before a shared release store; each wave retains one cancel-before-submit
   result per lane and one capacity probe, and each block ends with one
   CPU-oracle-checked real Metal control per lane. The
   fixed 163,132-byte wire therefore contains 128 cancellations, 64 capacity
   probes, 16 completed controls, and 208 records, with 144/144 pin closure.
   Cancellation and capacity records submit no GPU command. The exact verifier
   binds the host-event partial order, challenge-selected settlement order,
   zero-command roots, unique generation roots, measured 91:91 flow balance,
   component identities, and terminal zero ownership. The barrier proves the
   ready-before-release boundary, not simultaneous scheduling or execution,
   lock overlap, physical GPU parallelism, kernel cancellation, preemption, or
   performance. See
   [Native Metal cancellation-storm report](NATIVE_METAL_CANCELLATION_STORM_REPORT.md).

   W7b-b4 adds a controlled in-flight process-kill boundary. A fault-linked
   victim registers and commits one real INT4 command whose private
   `MTLSharedEvent` sequence signals `1` after compute and waits for `2`. The
   controller accepts the exact 512-byte ready frame only while command status
   is committed or scheduled, completion is unobserved, and four native
   buffers, one native command, and four allocation references remain live. It
   then sends real `SIGKILL` to that PID only, requires exact wait status `-9`
   and EOF, and launches a distinct production-linked W6 process whose 20 real
   Metal commands must pass CPU oracles. The event barrier exists only in the
   build-isolated fault shim and is controlled synthetic evidence; the Metal
   work, OS kill, and fresh control are real. It does not prove active-kernel
   interruption or preemption, victim-output recovery, state preservation,
   complete driver reclamation, physical device loss, performance, or physical
   GPU telemetry. See
   [Native Metal in-flight process-kill report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md).

   W7b-a adds the fixed segmented production-native Metal soak. Twelve paced
   segments run across two worker processes, six per process with one planned
   clean restart. Every segment contains 50 epochs, 250 raw records, 100
   completed real Metal commands, and a 5-second minimum/15-second maximum
   duration under a 180-second whole-campaign watchdog. The final chain
   accounts for 600 epochs, 3,000 records (120 warmup and 2,880 measured),
   1,200 completed commands, 600 cancellations, 600 malformed pre-submit
   rejections, 600 full-slot capacity rejections, 2,400 balanced Bank pins,
   and 15,000 ordered host event points.

   Each segment binds its process generation, scheduled action, challenge, and
   preceding entry/report roots. Within each process generation, worker RSS
   and Metal `currentAllocatedSize` before/maximum/after must remain within
   64 MiB of that generation's first observation. Strict admitted environment
   boundaries require AC power, low-power mode disabled, nominal `pmset` and
   Foundation thermal state, and unchanged host/boot identity. A canonical
   checkpoint is published after every segment to a content-addressed store
   bounded to 4 MiB and 32 regular files. After the live writer closes, a
   fresh offline-verifier process reconstructs every retained manifest prefix,
   reruns both inner verification layers, rechecks
   component/environment/selector bindings, and rejects missing, additional,
   corrupted, symlinked, or chain-substituted objects. See
   [Native Metal segmented soak report](NATIVE_METAL_SOAK_REPORT.md).

   W7b-b1 seals a second profile over the same bounded workload. Ordinal 5
   changes from a clean phase end to a forced action bound into the campaign
   ID, challenge, provenance, exit bits, and signal. Once that segment has
   passed both verifiers, reached zero logical ownership, and been synchronized
   as a segment object, the supervisor sends real `SIGKILL` to the worker PID
   and requires wait status `-9`. It publishes and re-reads generation six,
   reloads predecessor and cumulative facts from the retained entry, creates a
   fresh Metal worker, and completes the remaining six segments. The W7b-a
   zero-flag golden remains byte-identical. See
   [Native Metal process-kill recovery report](NATIVE_METAL_PROCESS_KILL_REPORT.md).

   W7b-b2 separates storage publication from device execution. The production
   campaign-store writer advances one exact prepared generation across 27
   ordered filesystem calls under 27 real writer `SIGKILL` deaths, 27
   controlled `EIO` returns, 27 controlled `ENOSPC` returns, and one clean
   control. Each case then uses two fresh roll-forward recovery processes and
   a fresh strict verifier. The fixed binary report binds raw/canonical store
   states and explicit real-signal versus synthetic-errno provenance, with
   independent Zig/Python verification. It runs no model or GPU command. See
   [Native workload store-fault report](NATIVE_WORKLOAD_STORE_FAULT_REPORT.md).
   The publisher is production code; prepared roll-forward remains a bounded
   campaign reference path until a general production recovery API and its own
   interruption matrix are integrated.

   These completed slices prove finite controlled software disruption, the
   ready-before-release boundary with pre-submit cancellation, correctness,
   ownership closure, clean restart, one post-segment process kill, one
   controlled event-blocked in-flight process kill followed by a fresh
   production control, prepared store roll-forward, fsync-bounded
   same-filesystem process-restart continuity, and bounded observed growth for
   the invoking host.
   They are not latency or throughput benchmarks, indefinite no-leak proofs,
   active-kernel interruption or recovery, physical residency measurements, or
   physical device-loss, driver, power, or storage-failure evidence. W7b-b
   remains open for supervisor death, recovery-process interruption,
   active-kernel and adapter faults, physical storage/power, and
   physical-device-fault schedules with explicit synthetic-versus-physical
   provenance. Prepared-text
   additions should cover repeated handoffs, source death before generation
   two, target death before generation three, idempotent-sink replay, selector
   corruption, lease contention, and recovery memory growth without
   relabelling fail-closed unavailability as success.

Native open-loop arrival-rate campaigns and closed-loop concurrency campaigns
must remain distinct from each other and from deterministic logical-step
conformance. Native results retain exact scenario identity, warmup and
measurement windows, machine/OS/backend/power/thermal envelopes, raw
observations, summary algorithm identity, and independent validation.
Cross-compilation alone never counts as native load evidence, and a campaign on
one OS or device never promotes another.

### 10. Capability, extension, and distribution plane

Responsibilities:

- least-authority tokenizer, processor, storage, backend, provider, and tool
  extensions;
- versioned negotiation, revocation, time/byte/operation ceilings, and failure
  semantics;
- stable library and service APIs, CLI, packaging, deployment, and upgrade
  policy;
- single-host, multi-process, edge, and distributed worker identities;
- authenticated control plane separated from pure runtime verification.

Current state: **idea to prototype**, depending on component. Core contracts
already use scoped grants, but a public extension ABI, worker protocol, stable
SDK, installer, and compatibility policy do not yet exist. A first
core-only, experimental C ABI can now verify one complete Model Contract V1
artifact-plan-result chain, enumerate eight retained-reference profiles, and
query matching support-mask bits from C, Python, or Rust without exposing
runtime struct layouts; it is a compatibility seed, not the stable SDK.

Promotion gate: an extension receives only declared operations and bounds;
revocation and process failure preserve accounting; version mismatch fails
closed; and packaging reproduces the verified artifact.

## Universal adapter contracts

Every `ModelFamilyAdapter` is expected to implement five narrow contracts:

1. **Inspect** — parse bounded artifact metadata and return an immutable family
   identity without loading unbounded payloads.
2. **Plan** — convert a typed operation and input schema into one sealed
   `ModelExecutionPlan` with exact resource, state, output, numerical, and
   capability declarations.
3. **Prepare** — validate inputs and family state, then produce backend-ready
   views without granting publication authority.
4. **Validate candidate** — check shapes, ranges, ordering, finite/numerical
   policy, source mappings, and family-specific invariants.
5. **Publish or abort** — convert a verified candidate into one typed visible
   transaction or release all provisional ownership.

Optional `StateAdapter`, `MediaProcessorAdapter`, `ProviderAdapter`, and
`ToolAdapter` contracts add only their declared state or authority. They do not
expand the base adapter's capabilities.

## Model-family coverage map

| Family | Representative operations | Current state | First retained slice | Integration gate |
| --- | --- | --- | --- | --- |
| Autoregressive text/code/chat | prefill, next-token decode, score | Prototype runtime; token publication and experimental fresh-process prepared-text handoff integrated on the POSIX durable adapter | Extend the retained synthetic baseline/source/target proof to one small legal artifact and acknowledged sink progress | Declared numerical equivalence, exact KV ownership, recoverable source exit, replay-safe external publication |
| Encoders, embeddings, rerankers, classifiers | encode, pool, rank, classify | Typed plan/result plus vision, audio, and temporal-video embedding fixtures integrated | Add a non-media stateless encoder under the same wire | Deterministic batch mapping, stable normalization, typed vector/score publication |
| Vision understanding | encode image, OCR, detect, segment, VQA inputs | Exact-integer encoder fixture integrated; production model gated | Extend from typed embedding to a bounded detection fixture | Geometry/color identity, bounded tensors, boxes/masks mapped to source regions |
| Speech and audio understanding | ASR, translation, audio classification | Exact-integer feature-window encoder, typed transcript transaction, fresh-process stateful transcript continuation, and restartable exact word-timing/speaker publication integrated; production model gated | Add language/punctuation, overlapping-speaker policy, and crash-atomic checkpoint composition | No sample loss/duplication, exact streaming restart, annotation lineage, calibrated production quality |
| Speech and audio generation | TTS, codec/audio token generation | Bounded exact-integer PCM publication, cancellation-safe retry, one-buffer backpressure, application acknowledgement, distinct-process restart, shared generated-output checkpoint composition, multi-chunk registry continuity with exact encoded payloads, host-verified retained source-model/renderer replay with separate registry-bound evidence, a validated bounded PCM s16le WAVE profile, and a real two-generation registry-transition-format chain with independent oracle coverage; production model/device paths gated | Add a production renderer/codec adapter, broader profiles, and additional replay profiles | Quality evidence, production container conformance, explicit device authority, physical playback evidence |
| Video understanding | frame/segment encode, search, summarize | Exact-integer strided-frame encoder, explicit VFR windows, fresh-process stateful segment continuation, canonical merge timeline, and exact audio/transcript-video result-link continuation integrated; production model gated | Add external container timestamp normalization and production backend conformance | Stateful continuation, explicit discontinuity evidence, production quality evidence |
| Image generation | diffusion/flow step, decode latent, publish image | Exact retained-state continuation plus bounded terminal-latent decode, cancellation-safe atomic image/provenance/result publication, distinct-process proof, shared generated-output checkpoint composition, multi-image registry continuity with exact encoded payloads, host-verified retained source-model/decoder replay with independent one-shot image state and derived collection order, a validated bounded canonical PNG profile, a real two-generation registry-transition-format chain, and independent oracle coverage; production model gated | Add a production decoder/encoder adapter, broader profiles, and additional replay profiles | Multi-step continuation, general external-format conformance, and quality/performance evidence |
| Video generation | temporal latent steps, frame/segment publication | Ordered two-frame raw manifest publication, cancellation-safe retry, one-segment backpressure, application display acknowledgement, distinct-process restart, shared generated-output checkpoint composition, multi-segment registry continuity with exact encoded payloads, host-verified retained source-model/renderer plus complete acknowledgement replay, a validated bounded two-frame gray8 APNG profile, and a real two-generation registry-transition-format chain with independent oracle coverage; production model/device paths gated | Add production adapters, broader profiles, and additional replay profiles | Production model quality, general external-container conformance, explicit display authority |
| Audio/music generation | acoustic or token steps, waveform decode | Shared bounded exact-integer waveform-output transaction, multi-chunk registry continuity, and a retained deterministic producer-transition replay profile integrated; music models gated | Add a legal production artifact, additional replay profile, or production renderer/codec fixture | Timeline continuity, chunk lineage, rights/provenance policy, calibrated quality |
| Multimodal fusion | cross-attention, joint embedding, interleaved generation | Idea; shared identities exist | Image+text or audio+text synthetic fusion fixture | Each modality retains source/state identity through one output transaction |
| Tool-use and agent policy | choose action, arguments, observation, continue | Process-local typed transaction plus portable ActionOutbox record/recovery, ambiguity reconciliation, safe retry, compensation-child protocol, descriptor-relative POSIX durable storage, and a bounded same-process fake dispatch/status authority integrated; live adapters gated | Add a live provider/tool adapter with real credential handling, restart-persistent authoritative state, and an optional OS-isolated transport without changing the retained protocol or storage proofs | Separate action authorization, idempotency, result identity, cancellation, capability isolation, durable dispatch |
| Retrieval and recommendation | embed, search, rerank, recommend | Idea | In-memory fixed corpus and exact top-k tie policy | Index/version identity, tenant filtering, deterministic tie/evidence policy |
| Time-series and tabular | forecast, classify, anomaly score | Idea | Tiny typed table/window fixture | Schema/time identity, missing-value policy, exact output horizon |
| Graph, geospatial, and scientific | message passing, field inference, simulation surrogate | Idea | Small bounded graph or grid fixture | Topology/coordinate/unit identity, resource bound, typed scientific output |
| Mixture and routed models | expert route, sparse execution, merge | Idea | Fake experts with deterministic router | Expert identity, route evidence, capacity/drop policy, state ownership |
| Adapters and fine-tunes | compose base + adapter, merge or dynamic apply | Idea | Tiny low-rank adapter fixture | Base/adapter/tokenizer identity, composition order, numerical policy |
| On-device small models | offline encode/generate/classify | Prototype platform pieces | One CPU-only packaged legal fixture | Reproducible package, memory/energy envelope, offline capability boundary |
| Provider-hosted models | any typed remote operation | Control plane integrated; live execution gated | Fake adapter matching exact request/usage wires | Credential isolation, terminal usage settlement, provider identity and policy |

This map is extensible. A new family joins by specifying typed artifacts,
operations, state, output, publication unit, authority, and promotion evidence;
it does not require changing the meaning of existing families.

## Delivery sequence

### R0 — Runtime vocabulary and registry — complete

- [x] Define `ModelFamilyId`, `OperationId`, typed input/output kinds, numerical
  policies, capability vocabulary, and explicit unsupported results; complete
  as a fixed prototype with a bounded support-record query;
- [x] Specify `ArtifactManifest`, `ModelExecutionPlan`, and family adapter
  lifecycle;
  canonical artifact/plan/result wires and the first
  prepare/validate/publish lifecycle are complete;
- [x] Generate a compatibility matrix from retained tests;
- [x] Add a read-only runtime inspector and
  [fixture-authoring guide](RUNTIME_SUPPORT_INSPECTOR.md).

Exit gate: two structurally different family fixtures use the shared contracts
without family-specific fields leaking into the common wire.

Exit evidence: vision u8 patches, audio i16 feature windows, strided video u8
frames, transcript/segment outputs, and a stateful latent step share the common
contract vocabulary while retaining distinct adapter behavior. Eight
append-only exact-integer profiles are derived directly from retained adapter
support constants. Compile-time coverage checks, bounded query/rejection tests,
fixed-width C consumers, standard-library Python, dependency-free Rust, and a
deterministic versioned JSON inspector retain the matrix.

R0 completion is scoped to these reference contracts. The inspector does not
load or execute a production model/checkpoint, parse a
loader/container/tokenizer, probe CPU/GPU or the current host, establish native
OS support, or measure quality/performance/memory/energy. Registration is not
execution. The active delivery milestone is R1.

### R1 — Text path becomes the first complete runtime vertical

- bind current loader, prepared image, resource, schedule, KV, sampler, token
  publication, checkpoint, and evidence paths behind the common plan;
- run uninterrupted/resumed production-fixture comparison;
- retain macOS and native Linux evidence;
- stabilize the smallest local library API.

#### R1a — Prepared text session

Status: **integrated experimental slice**. The first retained text-session
vertical now:

- seals the exact prepared `.glrt` identity, including source and ABI
  fingerprints, mapped container length, and full container digest;
- derives a prompt/options-bound plan with the exact request claim for one
  serial, greedy, fixed-length run;
- keeps prefill/decode KV, sampler RNG, sampling count, and output ownership in
  one persistent in-process session;
- adopts the already committed `LaneWeave` admission receipt instead of
  admitting the same request a second time;
- commits the first service permit with RNG/output state and each later permit
  with exactly one preceding-token KV row, RNG state, output token, and
  transcript evidence as one transaction;
- produces exactly the same retained token sequence as the configured legacy
  numerical oracle, exposes a verified boundary snapshot, and returns the
  admitted resources to zero after retirement.

The common contract vocabulary also accepts a prehashed artifact digest and a
typed `token_ids` output kind. These are R1 foundations; R1a's local
prepared-text plan does not consume the common Model Contract execution plan
without the R1c bridge below.

The retained fixture is synthetic and download-free. It does not establish a
production-model result, tokenizer wire identity, durable checkpoint payload,
fresh-process resume, native Linux execution, or a performance result. Early
EOS is deliberately disabled in this slice so the admission's fixed service
count remains exact. The compatibility `init` path retains its exclusive
admission-to-initialization boundary. The Zig API remains experimental. See the
[prepared text session lifecycle](PREPARED_TEXT_SESSION.md) and the retained
test named `compact multi-page INT4 generation matches eager generation` in
[`tests/model_forward.zig`](../tests/model_forward.zig).

#### R1b — Atomic prepared-session start

Status: **integrated experimental control-plane slice**. The preferred
`SessionV1.start` path now:

- constructs the scheduler claim and fixed work quanta directly from the
  validated prepared-text plan;
- atomically admits the request and installs a sealed, single-use
  publication-adoption barrier before releasing the scheduler mutex;
- commits the exact `ResourceBank` charge before allocating session resources
  or running prefill;
- commits the ready, address-stable every-service publication binding, or
  consumes an accepted adoption through a normal cancellation event and exact
  resource release; a transient cleanup error reports `RecoveryRequired` and
  retains the exact, single-use cancellation authority for retry after that
  condition is resolved, without diagnosing or repairing Scheduler or Bank
  state;
- prevents the admission-to-adoption race on a shared scheduler: competing
  logical mutators fail with `AdoptionInFlight` until start commits or cancels.

This slice favors lifecycle correctness over startup concurrency. Allocation
and prefill occur while the scheduler-wide logical barrier is live, so other
work on that scheduler does not progress during start. Non-blocking staged
activation remains future work. R1b alone does not bind the text session to the
common Model Contract execution plan or add tokenizer identity, durable
checkpoint payloads, fresh-process resume, a production fixture, native Linux
evidence, or performance evidence.

#### R1c — Common-plan prepared text bridge

Status: **integrated experimental identity and evidence slice**. The preferred
`SessionV2` path now:

- cross-binds the existing prepared-text `PlanV1` to a Common Model Contract
  autoregressive `generate_sequence` artifact and `implementation_defined`
  execution profile;
- declares the mapped `.glrt` as shared read-only residency:
  `ExecutionPlanV1.claim` records total logical resources, including the
  container, while `ExecutionResidencyBindingV1.request_claim` records the exact
  claim charged to this request;
- reconstructs and validates the artifact, execution, residency, and local
  plan against an independently retained `BoundPlanInputV1` before scheduler
  admission, then preserves the R1b charge-before-materialize and rollback
  transaction;
- installs all common roots before publication adoption can commit; and
- emits `BoundarySnapshotV2`, which binds the V1 boundary to the bound-plan,
  artifact, execution-plan, and residency-binding roots. Consumers with the
  expected bound plan and canonical local plan can verify that contextual join
  and the complete prepared-image identity with
  `boundarySnapshotValidForBoundPlanV2`.

The artifact manifest in this slice is deliberately a request-profile identity:
prompt and output dimensions change its root. It is not a stable package
identity, although its weight digest remains the exact mapped `.glrt` container
digest. Shared logical residency does not prove physical RSS, deduplication, or
page residency. Token-domain, token-domain-configuration, and artifact-license
roots are caller assertions whose bytes are not inspected or attested.

R1c covers only request profiles whose local activation claim satisfies the
Common Execution Plan's exact token-input byte lower bound. Some
long-prompt/minimal-model profiles accepted by `SessionV1` can therefore fail
`makeBoundPlanV1` before admission. Extending the bridge to those shapes
requires a later ownership and accounting decision; R1c does not claim complete
V1 shape coverage.

R1c does not execute a raw-text tokenizer, add a prepared-session checkpoint or
fresh-process resume, or establish production-model, native-platform, quality,
or performance evidence. It also does not establish strict cross-platform
numerical equivalence. `BoundPlanV1`, `ExecutionResidencyBindingV1`, and the
bridge remain an experimental Zig/direct API: there is no fixed bound-plan
wire, projected C verifier, or `.generate_sequence` `SupportRecordV1`.
Cross-language ABI and support-registry parity, plus non-blocking staged
activation, remain future work.

#### R1d — Residency-aware terminal result

Status: **integrated experimental terminal-evidence slice**. The preferred
fixed-length `SessionV3` path now:

- preserves the R1c bound-plan validation and R1b atomic admission transaction;
- derives a canonical, domain-separated terminal output root from the exact
  little-endian `u32` output tokens and binds it to the execution plan,
  token-domain configuration, and fixed output count;
- joins that output to `BoundarySnapshotV2` through a terminal source-mapping
  root, so the artifact, plan, prompt, publication transcript, and final token
  sequence cannot be substituted independently;
- prepares and validates one Common Model Contract `ResultEnvelopeV1` whose
  resource receipt is the actual `ResourceBank` charge from
  `ExecutionResidencyBindingV1.request_claim`, not the execution plan's total
  logical claim;
- permits at most one explicit terminal seal; a successful seal advances the
  dedicated result-publication state exactly once from `0 → 1`, early and
  duplicate sealing reject before mutation, explicit retirement requires a
  sealed result, and cancellation is allowed only before sealing; and
- retains native Zig numerical, lifecycle, mutation, and zero-resource
  retirement evidence plus shared Zig/Python goldens for the canonical
  artifact/plan/residency/result records, Receipt integrity, terminal output,
  source mapping, result evidence, and their substitution failures.

This slice is deliberately fixed-length: `output_length` must equal
`max_new_tokens`, and `SessionV3` does not add early-EOS or
fewer-than-admitted-output semantics. `SessionV2` remains available as the R1c
boundary API. R1d binds caller-supplied token-domain, configuration, and
license roots but does not inspect the raw bytes they name; it therefore does
not establish raw-text tokenizer identity, a stable package identity, or
license-byte attestation.

The terminal envelope and `TerminalResultEvidenceV1` are in-process evidence,
not a durable external result sink or a historical attestation. R1d adds no
fixed `BoundPlanV1` wire, projected C verifier, prepared-session checkpoint, or
fresh-process resume. Production fixtures, strict cross-platform numerical
equivalence, native multi-OS execution, quality/performance evidence, complete
V1 ownership coverage, and non-blocking staged startup remain future work.
The `deinit` safety path can abandon terminal evidence while closing the
adopted lifecycle; it is cleanup, not a successful terminal-result publication.

#### R1e — Canonical prepared-state image

Status: **integrated experimental state-codec slice**. The preferred
non-terminal `SessionV3` path now:

- captures only an idle, live-receipt boundary satisfying
  `0 < output_count < max_new_tokens`;
- binds independently retained local-plan, bound-plan, artifact, execution,
  residency, V2 boundary, transcript, state-commitment, and challenge roots to
  exact output, RNG, sampling, and committed contiguous-KV bytes;
- serializes output IDs and raw `f32` KV bit patterns canonically in
  little-endian order without normalizing negative zero, infinities, or NaN
  payloads;
- independently reconstructs the output chain, RNG root, full logical KV root,
  initial prompt-KV root, every subsequent row root, incremental publication KV
  chain, and final state commitment;
- materializes a fresh detached output/KV allocation with all uncommitted
  capacity zeroed, then revalidates the concrete roots; and
- retains a shared Zig/Python raw-bit golden, every-byte mutation rejection,
  coherent contradiction/context-substitution tests, and a real prepared-model
  integration that continues the original Session through terminal seal.

The state image is portable data, but its materialized value has no Scheduler,
ResourceBank, receipt, permit, sink, or publication authority. It is not a
runnable restored Session. The live authority remains address- and
sequence-bound to the source Session, and sequence zero remains excluded
because prefill logits are not serialized. Its encoded and detached
allocations are caller-owned and are not charged to the live Session's
ResourceBank.

R1e does not attach runtime authority to the detached payload and does not
claim rewind, durable checkpointing, crash recovery, exactly-once resume,
confidentiality, authentication, or cross-backend numerical identity.

#### R1f — Exact-boundary state rebind under retained authority

Status: **integrated experimental same-process control-plane slice**.
`SessionV3.rebindCheckpointV1` now:

- accepts only the exact current, idle, non-terminal boundary of the original
  live Session;
- derives every decoder expectation from that Session and validates the
  address-bound ownership, V2 boundary, plans, receipt, ResourceBank fence,
  sequence, result state, and publication bindings before materialization;
- decodes and materializes the candidate internally with the Session allocator,
  then validates the complete live context again;
- compares exact output IDs, raw committed KV bytes, logical/publication KV
  roots, RNG/counters, geometry, and deterministic zero slack;
- replaces only the existing cache/output field values after all fallible
  checks, then releases their former backing; and
- preserves the embedded publication-coordinator address, Scheduler,
  ResourceBank, receipt, request epoch, sequence, transcript/state roots, and
  cache/RNG/counter/output-length field addresses without consuming a permit or
  emitting a Scheduler/Bank event.

The same-boundary operation may repeat with fresh backing, and the next token
matches the complete ordinary uninterrupted transition and post-step numerical
state. A retained permit crosses rebind unchanged, while a phase-gated
allocator sweeps every private materialization failure with zero live-state or
accounting mutation. Once the Session advances, the old image rejects rather
than rewinding or branching authority. Active row transactions, copied/moved
Sessions, recovery adoption, sequence zero, terminal state, and substituted
context also reject. Previously borrowed output/cache views and row marks are
invalid after success.

R1f remains a same-process buffer replacement inside the original Session. It
does not create a new Session, transfer authority, provide concurrency,
publish durable state, or resume after process death.

#### R1g — Canonical prepared-text successor evidence

Status: **integrated experimental identity and evidence slice**.
`prepared_text_successor` and
`SessionV3.captureSuccessorArtifactsV1` now:

- reuse the existing fixed 768-byte Common Model Contract
  `ExecutionPlanV1` and 256-byte `ExecutionResidencyBindingV1` rather than
  serializing native `BoundPlanV1` memory;
- derive a canonical successor generation at the exact current non-terminal
  `0 < N < max_new_tokens` boundary, with publication base `N`, previous-plan
  lineage, checkpoint logical-KV payload identity, and checkpoint challenge;
- preserve the source plan's artifact, family, operation, shape, policy,
  schema, total-resource, and other canonical bindings while recomputing the
  plan and residency roots;
- add one fixed 512-byte transcript segment joining the source checkpoint,
  bound plan, execution plan, boundary, predecessor transcript, state
  commitment, logical KV, successor records, target ownership intent, and
  challenge;
- commit an exact proposed target scheduler/coordinator, fresh Bank and owner,
  LeaseTree/cache keys, successor generations, and request claim through a
  domain-separated ownership-intent root; and
- rederive and exact-compare the complete live source context before returning,
  without mutating the Session, Scheduler, Bank, receipt, sequence, state, or
  publication evidence.

Canonical Zig and independent Python paths freeze the successor
plan/residency/intent/segment roots, reject mutation across every byte, reject
all truncated or extended segment lengths, and reject coherently re-rooted
foreign ownership/plan substitutions against caller-retained context. See
[Prepared Text Successor Evidence](PREPARED_TEXT_SUCCESSOR.md) for the exact
projection, wire offsets, and acceptance gates.

R1g ownership intent is pointer-free evidence, not an authority handoff or
receipt. It does not exit the source, admit a target, acquire a live Bank
receipt or service permit, remap a `LeaseTree`, create a runnable target
Session, durably select a successor, resume after process death, or prove
exactly-once continuation.

#### R1h-a — Barrier-held restored admission and receipt remap

Status: **integrated experimental live-authority slice**.
`prepared_text_restore_admission` now:

- consumes the exact R1g plan, residency, segment, checkpoint, retained source,
  target ownership intent, and the same lease-backed generation-two activation
  grant before any target mutation;
- requires a genuinely fresh LeaseTree-enabled Bank and an explicitly opted-in
  fresh Scheduler whose live epoch, coordinator ID, and Bank epoch match the
  target intent, while its challenge matches the successor segment;
- derives one fixed missing scheduling policy: authority key as request key,
  weight one, no deadline, and only the successor's remaining quanta;
- acquires the exact target admission and fresh receipt, then retains the
  publication-adoption barrier so no service can observe partial restore state;
- opens the intended queue-free receipt-funded LeaseTree with one
  zero-current-claim tenant scope and restores the Bank publication namespace
  at sequence `N`; and
- seeds the target Bank's publication-permit generation from the source fence,
  making its first future permit strictly greater across the fresh receipt.

The live capabilities are process-local and single-use. Read-only validation
rechecks the pending adoption, receipt, funded tree, scope, publication
namespace, activation-grant address/root/phase, live lease consumer claim, and
exact Scheduler/Bank accounting. Before activation, abort closes the restored
publication namespace and empty tree, cancels the adoption, releases the
receipt, and returns the grant to its ready generation-two phase; copied or
replayed authority is stale after the first winner.

R1h-a intentionally allocates no request-local backing. The immutable receipt
already charges the complete request claim, so the tree uses the explicit
`receipt_funded` mode and excludes the Scheduler-owned queue slot. Its retained
cache node/binding keys are consumed by R1h-b. See
[Prepared Text Restore Admission](PREPARED_TEXT_RESTORE_ADMISSION.md).

#### R1h-b — Receipt-funded restored Session activation

Status: **integrated experimental process-local runtime slice**.
`SessionV3.startRestoredV1` now:

- revalidates the R1g checkpoint, successor records, source bound plan, target
  ownership intent, live R1h-a capability, and the same prepared activation
  grant before allocator work;
- reserves one queue-free funded allocation covering every request-local byte
  class while leaving aggregate Scheduler and Bank usage equal to the
  immutable parent receipt;
- materializes exact output, contiguous KV, RNG, and sampling state into fresh
  Session backing, with deterministic zero slack and reconstructed roots;
- initializes publication ABI v2 with `sequence_base = N`, the checkpoint
  transcript and state, and source Bank permit generation `G`;
- commits the funded allocation batch and consumes the pending Scheduler
  adoption plus one-shot activation grant through one protected activation
  path, so service cannot observe partial restored state; and
- closes through a no-service barrier that reclaims allocator backing and the
  funded allocation before atomically releasing the publication namespace,
  tree, receipt, and Scheduler lane.

The retained synthetic-model path constrains the target Bank to the exact
request hard limit, publishes the first target transaction at global sequence
`N` with Bank permit `G + 1`, matches uninterrupted output, logical KV, RNG,
and sampling state for that transition, and returns Scheduler/Bank accounting
to zero after cancellation. Lower-level tests retain fresh-session behavior
with `sequence_base = 0` and cover funded activation/abort single-winner
semantics.

R1h-b remains the process-local activation transaction. The durable handoff
slice below supplies its selected source-exit and lease/grant authority.

#### Durable prepared-text handoff

Status: **integrated experimental fresh-process slice**. The composed path now:

- serializes prompt tokens, options, local and bound plans, Common Model
  Contract records, checkpoint expectations, source context/receipt evidence,
  and target ownership into one pointer-free canonical restart manifest;
- publishes that manifest with the checkpoint, successor execution plan,
  successor residency binding, and successor transcript segment as one ordered
  five-object restart archive;
- binds a live source to the generation-one selector through an
  address-stable source-live grant backed by the lease's sole consumer claim;
- closes the exact source publication binding, Scheduler lane, and Bank receipt
  through a handoff barrier before selecting generation two with the canonical
  source-exit receipt and restart archive;
- lets a different process open generation two under the exclusive lease and
  create one address-stable target activation grant; duplicate grants, copies,
  selector drift, and early lease release reject;
- activates R1h-b at global sequence `N`, retains the grant across resumed
  execution, and requires the exact generation-three selector before terminal
  retirement; and
- runs baseline, source, and target as separate subprocesses, compares the
  target's receipt-independent terminal semantic with the completed baseline,
  and returns both source and target logical ownership to zero.

The three selected meanings are deliberately narrow:

```text
generation 1 source-live
  → generation 2 source-exited + canonical restart archive
  → generation 3 terminal semantic + exact predecessor lineage
```

This slice closes the evidence-only-to-runnable-target gap for its retained
synthetic fixed-length profile, but two durability gaps remain explicit. A
source crash before generation-two publication leaves generation one selected
and the request fail-closed/unavailable. A target crash after external output
but before generation three can retry generation two and replay from `N`.
Exactly-once external effects therefore require an idempotent sink keyed by
request/global sequence and a future acknowledged progress generation.

The current durable adapter is descriptor-relative POSIX. Cross-compilation
does not establish Win32 durable-file behavior or native OS support. GPU
execution, device-resident checkpointing, device-loss recovery, production
models, early EOS, native multi-OS recovery, and production workload evidence
remain roadmap work. See
[Durable Prepared-Text Handoff](PREPARED_TEXT_DURABLE_HANDOFF.md).

Overall R1 exit gate (**not yet met**): one declared artifact and numerical mode
completes plan → execute → publish → checkpoint → fresh-process resume with
exact ownership and output evidence on the promoted native platform, including
recoverable source-exit and replay-safe external publication. The retained
synthetic fresh-process proof advances this gate but does not complete its
production artifact, sink-progress, GPU, or multi-OS requirements.

### R2 — Stateless tensor families

- add encoder/embedding/reranker/classifier operations; vision, audio, and
  temporal-video encode operations are retained, while generic encoder,
  reranker, and classifier fixtures remain;
- define typed tensor/vector/score result envelopes; the fixed integer
  embedding envelope is complete;
- add deterministic batch-item mapping and tie/normalization policy; exact
  batch mapping is complete for vision, audio, and selected video frames, while
  normalization and tie policies remain;
- integrate `ResourceBank`, `LaneWeave`, cancellation, and provider routing;
  scheduler receipt handoff, final-service typed publication, cancellation,
  and retirement are integrated for the retained bounded media runtime and
  vision/audio/temporal-video stateless adapters, while mixed-family workload
  profiles and provider routing remain.

Exit gate: text generation and one stateless encoder share the runtime planes
while retaining different state and publication semantics.

### R3 — Streaming perception

- bind bounded image/audio/video transforms to exact request admission and one
  atomic media publication transaction; complete for retained model-free
  fixtures, including scheduler-receipt adoption and atomic final-service
  publication in the pressure campaign;
- add `LeaseTree` ownership for decoded source, mappings, output, and scratch;
  complete for retained model-free fixtures;
- compose bounded image/audio/video chunks under one target timeline with
  cancellation-safe ownership and portable chain receipts; complete for two
  retained chunks per modality;
- bind stream state and retained output ownership into a fixed checkpoint,
  release the source process, reacquire in a fresh Bank, and append the exact
  next chunk; complete for retained image/audio/video fixtures under distinct
  source and target PIDs;
- publish media checkpoint/output objects through one crash-atomic archive and
  selector; complete for two source-side generations, three modalities, and
  every archive/selector process-death boundary;
- create the next checkpoint generation after resumed chunks while rebinding
  retained ownership and rejecting stale source authority; complete for a
  fresh-process generation-two to generation-three transition, six rebound
  outputs, three appended chunks, and a second fresh-process resume;
- integrate image processors and vision encoder fixtures; bounded tile/patch
  progress, materialized cache ownership, exact-integer encoder execution,
  candidate validation, and typed embedding publication are complete for the
  retained fixture;
- add audio feature windows, transcript transactions, and streaming restart;
  fixed window/hop/context state, a non-overlapping exact-integer feature
  encoder, canonical overlap ownership, and typed transcript publication are
  complete; a stateful transcript fixture now restores exact sample/model state
  under fresh charged ownership in a distinct process, publishes only the next
  range, and advances its cross-modal link without duplicated text; production
  speech models, language/punctuation policy, overlapping-speaker ambiguity,
  and atomic multi-file composition remain; exact word sample ranges and
  first-occurrence speaker turns now publish across a distinct-process state
  restart;
- add video temporal selection, synchronized timeline state, and cache
  ownership; fixed window/eviction state plus exact audio/video watermark is
  complete together with materialized cache ownership; a typed strided-frame
  encoder now binds keyframe lineage, eviction boundary, charged gather
  scratch, and exact target time; a fixed typed video segment now adds
  event/confidence fields, complete source/cache lineage, predecessor chaining,
  and transactional visibility; fixed timeline and decision wires now coalesce
  only touching/overlapping same-event results and retain gaps or different
  events; a fixed cross-modal transaction now maps only newly publishable
  transcript samples to the accumulated video tail, rejects non-integral or
  non-overlapping time, and binds both histories; a stateful video fixture now
  crosses a real process boundary with explicit per-frame PTS/duration,
  declared-gap evidence, timeline continuation, and result-link continuation;
  external container normalization and production quality remain;
- extend checkpoints with family-specific processor/cache state; the fixed
  independently verified state and payload bundles now advance as the fifth
  and sixth atomic archive objects through a fresh-process successor.

Exit gate: image, audio, and video input paths preserve exact source mappings,
stay within admitted memory/time bounds, and resume or cancel at declared units.

### R4 — Generative media and multimodal fusion

- add diffusion/flow scheduler and latent-state adapters; a canonical
  state-publication wire plus two exact latent steps now commit typed results
  and replacement state; the intermediate checkpoint restores under fresh
  ownership in a distinct process and reaches the terminal step without a
  duplicate result;
- publish a bounded generated image from the exact terminal latent; fixed plan,
  provenance, and result wires now bind artifact/checkpoint/terminal state,
  decoder, tenant, media, resources, and publication predecessors; abort/retry,
  candidate drift, atomic visibility, independent mutation verification, and a
  real distinct-process proof are complete;
- publish bounded generated audio under exact frame ordering and backpressure;
  fixed state/plan/provenance/result plus observation/acknowledgement wires now
  bind source output, PCM, media, renderer, resource receipt, sink identity, and
  both predecessor chains; cancellation, partial/duplicate rejection,
  independent mutation verification, and a real distinct-process proof are
  complete;
- publish bounded generated video under an ordered two-frame manifest; fixed
  state/manifest/provenance/result plus observation/acknowledgement wires now
  bind exact frame roots and durations, source output, media, renderer,
  resources, sink identity, and both predecessor chains; cancellation,
  partial/duplicate rejection, independent mutation verification, and a real
  distinct-process proof are complete;
- compose generated image, acknowledged audio, and acknowledged video behind
  one atomic selector; fixed member/checkpoint/selector wires now bind exact
  modality roots, totals, scope, policy, challenge, predecessor continuity, and
  completion evidence. An independent Python oracle and four-boundary
  process-death campaign prove exact previous-or-successor recovery without a
  mixed generation;
- bind the checkpoint, three members, and exact encoded image/audio/video bytes
  into one canonical eight-object archive; complete for two model-free
  generations with explicit raw-output, encoded-payload,
  encoder-implementation, and format identities, one outer filesystem
  selector, an independent Python oracle, and seven process-death phases
  selecting the previous generation five times and successor twice before
  idempotent convergence;
- extend that fixed archive through an independent bounded output-registry ABI;
  complete for one to four outputs per present modality, at most twelve,
  canonical `(modality, ordinal)` entries, exact concatenated encoded payloads,
  structural completion fields, opaque state/completion roots, exact
  unit/timeline/predecessor continuity, and two model-free `2/3/2` then `2/2/3`
  image/audio/video generations in exactly three archive objects under the
  existing selector;
- admit canonical typed producers before registry construction; complete for
  the retained image plan/provenance/result set, audio quiescent
  state/plan/provenance/result/playback-acknowledgement set, and video
  quiescent state/manifest/provenance/result/display-acknowledgement set plus
  exact raw output bytes. The gateway derives the common envelope, registry
  generation and publication sequence, and strict
  state/result/completion predecessors while leaving the selected three-object
  registry unchanged;
- reconstruct stronger producer execution transitions; complete for the
  retained deterministic source-model and materializer profiles. Image uses a
  fresh one-shot local publication and a separately derived registry collection
  ordinal; audio/video replay publication, observation, acknowledgement plan,
  acknowledgement result, and exact final state. Fixed receipts live in a
  separate predecessor-bound sidecar paired with the unchanged registry
  archive;
- emit and accept bounded canonical lossless delivery profiles; complete for
  PNG with bounded 8-bit gray/gray-alpha/RGB/RGBA, PCM s16le mono/stereo WAVE,
  and two-frame full-canvas gray8 APNG. Their additive conformance sidecar is
  integrated through real two-generation registry-transition-format fixtures
  for every profile. An experimental read-only inspector optionally validates
  and renders exact triple roots without payload or write authority;
- retain exact successor, missing/foreign predecessor, semantic-drift, and
  failure-atomic output checks for all three profiles; complete. An independent
  Python oracle decodes and binds the registry, transition, format sidecar, and
  canonical producer wires across both generations;
- add production image decoder/encoder and audio/video
  renderer/codec/container adapters, broader profiles, and additional replay
  profiles;
- add authorized physical playback/display and quality evidence;
- retain native Linux filesystem campaigns and design separately scoped initial
  publication and power-loss durability evidence;
- add cross-modal cache/state identity and fusion fixtures;
- extend checkpoint and provider evidence to generative media units.

Current gate progress: deterministic generated-image, generated-audio, and
generated-video fixtures survive cancellation and process restart without
duplicate visible output; audio and video additionally gate their successors
on exact application acknowledgement. Shared generated-output checkpoint
composition, exact encoded-payload archive composition, and bounded
multi-image/chunk/segment registry continuity are complete for two model-free
generations. Canonical typed producer admission now verifies the retained
record sets and exact raw outputs before constructing that registry.
Host-verified transition evidence now additionally replays the exact retained
source-model and materializer profiles and binds the resulting receipts to that
unchanged registry. Strict bounded PNG/WAVE/APNG leaf profiles and their
additive sidecar are integrated through real two-generation
registry-transition-format fixtures, exact producer-semantic binding, and an
independent composed oracle. The R4 production exit gate still requires
production encoder/container adapters, broader profiles and replay coverage,
native platform and power-loss evidence, and quality/performance evidence under
declared artifacts.

See
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md)
for the replay, image-ordinal, and transition-sidecar lineage, then
[Generated-Media External-Format Profiles and Evidence](GENERATED_MEDIA_EXTERNAL_FORMATS.md)
for profile, format-sidecar, inspector, portability, and nonclaim boundaries.

### R5 — Agents, retrieval, and specialized families

- [x] add action proposal separate from action authorization through W4b-a;
- [x] add an idempotent bounded fake-tool/result transaction through W4b-a;
- add capability-scoped live tool dispatch with OS-isolated credentials;
- add retrieval/index identity and deterministic result publication;
- publish templates for time-series, graph, geospatial, and scientific adapters;
- validate routed experts and adapter composition.

Exit gate: third-party family and tool adapters run under declared capabilities
without direct access to unrelated tenant, runtime, storage, or network state.

### R6 — Distribution and stable operations

- authenticated multi-process/worker control plane;
- placement, model caching, backpressure, and drain/upgrade protocols;
- packaging, stable API/ABI policy, migration tooling, and support matrix;
- promote the experimental contract verifier only after retained
  symbol/layout, native consumer, packaging, and migration gates;
- retained long-running correctness, pressure, crash, energy, and cost campaigns.

Exit gate: a published support matrix, reproducible packages, compatibility
policy, rollback path, operational inspection, and retained multi-platform
evidence.

## Where the runtime helps

The runtime is intended for:

- local assistants and coding systems that need bounded memory and resumable
  generation;
- embedding, reranking, classification, and document pipelines that need exact
  batch and artifact identity;
- voice, image, and video applications that must retain source/time provenance;
- generative-media queues that need cancellation and no duplicate publication;
- gateways that route between local and external providers with explicit usage
  and cost;
- agent systems that separate model-proposed actions from real authority;
- edge/offline applications with constrained resources and later synchronization;
- research on kernels, paging, scheduling, continuation, and verifiable AI
  operations.

Local preprocessing, exact deduplication, compatible cached state, routing, and
lossless context packing may reduce work sent to an external provider. They do
not guarantee fewer provider tokens, media units, latency, or cost. Glacier must
record logical input, exact transmitted bytes, provider-reported usage, cache
decisions, attempts, and settlement separately.

## Contributor lanes

Contributors can work on the runtime without downloading a large model:

- one model-family registry entry and malformed fixture;
- one tiny artifact/parser branch;
- one operation schema or result envelope;
- one resource/state/publication state machine;
- one deterministic processor or transform;
- one fake backend/provider/tool adapter;
- one independent verifier or mutation campaign;
- one experimental C ABI consumer or golden failure case in another language;
- one platform capability probe;
- one native-observer parser or adapter that preserves all four availability
  states, separates stable source from per-event provenance, retains a nonzero
  reason identity only when unavailable, names the sample clock for every
  record, and names a value clock only for a present time-valued metric;
- one retained generated-workload seed, exact shrink signature, deterministic
  closed-loop plan or lineage mutation, summary oracle, or native campaign
  adapter;
- one prepared-text source-exit journal state or acknowledged sink-progress
  generation with explicit crash boundaries;
- one replicated non-macOS POSIX recovery campaign or bounded Win32
  durable-file adapter slice;
- one additional native-backend allocation, LeaseTree composition, residency,
  placement, device-loss, or multi-device evidence slice that consumes a fresh
  selection receipt, builds on the bounded lifecycle, and rejects unsupported
  fallback;
- one Phase B implementation for an additional backend that preserves the
  portable retention/fence/receipt contract and keeps the native record live
  until Bank-first exact unlink;
- one repeated-handoff, lease-contention, replay, disruption, or bounded-soak
  workload profile;
- one read-only evidence inspector or validated renderer extension;
- one compatibility-matrix row backed by a retained command.

Every slice should state its accepted inputs, maximum resources, authority,
rejection paths, evidence command, and nonclaims. See
[Contributor Projects](PROJECTS.md),
[Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md),
[Device Allocation Lease](DEVICE_ALLOCATION_LEASE.md),
[Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md),
[Device-loss Dispatch Reconciliation](DEVICE_LOSS_DISPATCH_RECONCILIATION.md),
[Device-loss Dispatch Callback Retirement](DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md),
and
[Evidence Policy](EVIDENCE_POLICY.md).
