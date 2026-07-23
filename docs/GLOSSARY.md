# Glossary

**Claim** — A typed declaration of logical resources a request needs before it
can execute.

**Commitment** — A digest or structured identity binding exact state. It proves
identity only within its verification contract.

**ContinuationCapsule** — A fixed-size manifest that binds a committed AI
checkpoint to typed external model, plan, resource, scheduling, KV, sampler,
output, and publication objects without embedding their payloads or granting
resume authority.

**Continuation object resolver** — An allocation-free lookup state machine that
admits exact capsule objects under a tenant-scoped grant and bounded catalog,
object, total-byte, and resolution limits.

**Continuation bundle** — A fixed manifest joining one capsule and nine semantic
object roots to tenant-bound storage blob roots and canonical deduplication
ordinals without embedding payloads or granting storage authority.

**Continuation object store** — A bounded, bundle-scoped in-memory store that
owns immutable tenant blob payloads, reuses duplicate references, accounts
payload/index/lifecycle state, and rolls partial imports back.

**Continuation object lifecycle** — Explicit-tick acquire, renew, release,
expiry, quarantine-fence, and repair transitions bound to separate
tenant/bundle/store capabilities and generation-fenced receipts.

**Continuation object collection plan** — A bounded dry-run classification of
every occupied store slot against one exact snapshot, complete semantic-root
multiplicity, and complete current-lease coverage. Its evidence root grants no
deallocation authority.

**Continuation object sweep journal** — A caller-owned functional state value
whose prepare transition regenerates one separately approved collection plan
and whose abort transition requires the pinned snapshot to remain current. It
stages exact totals but grants no commit or deallocation authority.

**Continuation object sweep commit** — A separately authorized in-memory
transition that regenerates one prepared plan, validates a canonical set of
retired targets before mutation, deallocates exactly that set, and binds exact
before/after store accounting into verifiable receipts. It does not imply
durability, secure erase, or lower process RSS.

**Continuation object sweep record** — A fixed pointer-free body/footer wire
that carries one sweep commit's chain position and enough canonical fields to
reconstruct and verify its grant and receipts. Its ordered append plan grants no
filesystem, deletion, recovery, or durability authority.

**Sweep recovery classifier** — A pure anchored scan of concatenated sweep
records that returns the semantically verified committed prefix and a named
clean, incomplete-body, incomplete-footer, or corrupt status. Classification is
evidence only and grants no truncation, repair, deletion, or filesystem
authority.

**Sweep publication capability** — A snapshot-bound exclusive operation view.
Its append form exposes only ordered body/footer write and sync; its separately
requested repair form exposes only truncate and sync for an explicitly
classified incomplete tail. Neither form grants payload deletion authority.

**Poisoned writer** — A process-local writer or repairer that observed an
uncertain I/O result and therefore rejects reuse until storage is reacquired,
read again, and reclassified under a fresh snapshot.

**Directory capability** — An already opened directory descriptor passed as
bounded namespace authority. Glacier combines it with one validated component
name; it is not permission to resolve arbitrary absolute paths or traverse
descendant directories.

**Process-death recovery** — Fresh acquisition and verification after the
publishing process terminates. It proves lock release and host page-cache/file
semantics for the observed run, but does not emulate device power loss.

**Publication-ordered commit** — A destructive transition whose exact predicted
receipt is fully published before mutation. Recovery compares the current state
with the receipt's old/new roots to apply once, accept an already-applied state,
or reject an unrelated state.

**Canonical payload snapshot** — A tenant-bound, explicitly serialized set of
payload references and bytes sorted by digest and length. Decode re-hashes every
payload and rejects mutation, duplication, reordering, or foreign tenant scope.

**Copy-on-write payload promotion** — A durable reclaim transition that writes
and syncs an exact successor snapshot before atomically renaming it over the
active file. Recovery accepts only the reclaim record's old or new root and
therefore never edits an ambiguous third state.

**Continuation ownership manifest** — A fixed resource-state plan binding one
checkpoint to source/target Bank epochs, exact claims, canonical LeaseTree
scopes, allocation identities, materialized-object roots, and the next
publication sequence. It enables logical ownership reacquisition but does not
restore runtime object contents by itself.

**Paged-KV checkpoint remap** — Verification of a complete historical
page-root/ref chain followed by reconstruction into a new cache instance and
new page ownership generations. Source refs remain stale evidence rather than
being promoted into live target authority.

**Restart publication bridge** — A runtime-state contract that joins a restored
paged-KV root, RNG, sampler count, output prefix, exact next sequence, and prior
commit so one fresh process can publish the next token atomically.

**Checkpoint root switch** — Selection of one immutable canonical checkpoint
archive through a fixed lineage-bound record whose atomic rename makes the
complete successor visible at one filesystem boundary.

**Glacier AI Runtime** — The complete shared execution fabric spanning artifact
identity, planning, resources, scheduling, state/continuation, media, providers,
publication, evidence, capabilities, and distribution. Individual planes have
different maturity; the name is an architectural scope, not a claim that every
model family is already supported.

**ModelFamilyAdapter** — A proposed least-authority adapter that inspects
bounded artifact metadata, creates a sealed family-specific plan, prepares
backend views, validates candidate results, and requests typed publication or
abort. Registration does not imply executable or validated support.

**ModelExecutionPlan** — A proposed sealed value binding one model operation to
artifact, input/output schema, state, exact resource/scratch/output ceilings,
numerical policy, backend capabilities, challenge, and rejection/fallback
policy before execution begins.

**StateAdapter** — A proposed family-specific contract for verifying,
checkpointing, restoring, and releasing typed state such as KV, recurrent
state, encoder caches, latents, temporal caches, media windows, retrieval
cursors, or action history.

**Typed result publication** — A proposed generalization of token and media
publication in which each family declares its atomic visible unit—such as a
token, tensor, score, box, mask, transcript span, media chunk, retrieval result,
or authorized action—and its replay, cancellation, and continuation rules.

**MediaObject** — A fixed pointer-free, content-addressed identity for an
immutable image, audio, or video payload plus exact byte length, kind-specific
axes, semantic ABI, policy, provenance, and tenant scope. It does not grant
file, network, camera, or microphone access.

**MediaTimeline** — A checked rational position and event-chain system for
exact media ranges and explicit trim, pad, resample, frame-selection, or reorder
history without floating-point wall-clock rounding.

**Media publication** — A prepared logical state transition binding one exact
next sequence, chunk/unit range, media and timeline roots, output root,
resource-claim root, and prior commit. The model-free runtime transaction now
joins this transition to exact `ResourceBank` admission, candidate
revalidation, and one commit/abort boundary; durable output and model execution
remain separate requirements.

**MediaDecodePlan** — A fixed sealed value binding one media object to an exact
decoder implementation, source/destination representation, execution and
numerical policies, required capabilities, output/scratch bounds, transform
policy, resource policy, and challenge. A valid plan grants no I/O authority.

**Tiny media fixture** — A bounded canonical test container whose header,
payload, provenance, and footer reconstruct one `MediaObject`. The reference
identity decoder maps every output pixel, PCM frame, or video frame to exact
source bytes; it is not a general external-format codec.

**MediaTransformPlan** — A fixed sealed plan binding decoded source evidence,
operation, geometry or time/rate parameters, exact output/scratch bounds,
implementation, resource policy, challenge, and capabilities. The current
reference operations are image crop/nearest/tile, audio weighted mix/exact
decimation, and video keyframe selection.

**MediaRuntimeTxn** — A request-local, single-owner lifecycle that derives and
admits one exact media claim, decodes and transforms into provisional
caller-owned storage, independently revalidates the candidate, atomically
publishes media/resource state, scrubs on abort, permits exact retry, and
releases the full claim.

**Media runtime receipt** — A fixed 640-byte evidence value binding the complete
resource receipt and claim, fixture, transform plan and receipt, output,
mapping chain, timeline event, publication commit, and both publication
sequences. Verification reconstructs the transition from its explicit inputs
without granting execution or I/O authority.

**Retired entry** — A retained store payload with zero semantic references and
no active lease. It is eligible for a future separately authorized sweep only
after an exact collection plan classifies it as collectible.

**Blob ordinal** — The deterministic first-occurrence number assigned to equal
tenant-bound payload bytes in a continuation bundle. It describes a storage
plan, not a live object handle.

**Capability grant** — A least-authority declaration of the exact identity,
scope, operations, and resource ceilings a trusted boundary permits. Its digest
binds the declaration but is not authentication by itself.

**ContextPack** — A lossless mapping that emits one copy of explicitly
idempotent, byte-identical rendered spans while retaining every logical span
decision.

**DecodePlan** — A validated description of static execution work and layout
identity prepared before token execution.

**Evidence join** — A compact manifest that binds already verified roots from
several evidence planes without duplicating their payloads.

**Fail closed** — Rejecting an operation when identity, support, capacity, or
evidence is uncertain instead of choosing an implicit fallback.

**GLRT** — Glacier native runtime image. A derived, execution-layout-bound file
with the `.glrt` extension.

**Lane** — One independently tracked request position in a scheduled execution
wave.

**LaneWeave** — Glacier's deterministic admission and weighted service scheduler.

**LeaseTree** — A hierarchy that subdivides one ResourceBank receipt into exact
child ownership and publication scopes.

**Media buffer lease** — A generation-fenced LeaseTree allocation for one
decoded-source, mapping, scratch, or output region. The logical lease is charged
before caller storage is used and retired only after that storage is no longer
runtime-visible.

**Media stream chunk** — One contiguous target-timeline publication backed by
its own hierarchical media transaction. Its portable receipt binds the exact
target interval, retained output lease receipt, publication commit, and previous
stream chunk.

**Media stream checkpoint** — A fixed record that binds one bounded stream's
publication state, last chunk root, retained output identities and bytes, plus
the exact fresh-Bank ownership plan required before resumed output becomes
runtime-visible.

**Media stream checkpoint set** — One immutable archive generation containing
fixed image, audio, and video stream checkpoints plus a canonical
retained-output bundle and, for stateful archives, one fixed processor/cache
bundle. Materialized archives add exact cache payloads as a sixth object. A
single selector root makes only the complete previous or successor multimodal
generation visible across process death.

**Media processor state** — A fixed record for lineage-bound preprocessing
progress and logical cache accounting. The current bounded forms cover image
tile/patch progress, audio feature windows, and video temporal windows.

**Media processor cache bundle** — A canonical image/audio/video payload set
whose exact bytes, sizes, roots, processor-state binding, predecessor, and
fresh-Bank restore plan travel as the sixth atomic media checkpoint object.

**Model family** — A typed semantic class such as autoregressive generation,
vision understanding, audio understanding, diffusion, retrieval, or agent
policy. A family ID is vocabulary only; a matching support record and adapter
are still required before execution.

**Model execution plan** — A fixed contract binding one operation to exact
input/output shapes, numerical policy, resource claim, required capabilities,
artifact identity, and media/processor/cache/ownership roots.

**Typed result envelope** — A fixed publication record binding output bytes to
their model plan, adapter, resource receipt, source mapping, predecessor, and
publication transition.

**Stateless model adapter** — The family-neutral lifecycle for an operation
whose result does not retain model state: exact admission, private candidate
execution, family validation, typed publication or scrub, and exact release.

**Stateful model adapter** — The family-neutral lifecycle for a step that must
publish a typed result and replace retained model state together. It pins both
publication snapshots and keeps output/state candidates private until commit.

**State publication** — A fixed record binding request, current/terminal step,
state byte length, artifact, current state root, previous result, challenge,
and publication root.

**State transition root** — A commitment joining the state publication before
a step, execution plan, output root, successor-state root, adapter, challenge,
and next step. It is carried as the typed result's source mapping.

**Stateful model checkpoint** — A fixed record binding one non-terminal state
publication to its model-publication root, last plan/result/output, source and
restore Bank epochs, retained-state bytes, and exact fresh ownership keys.

**Audio-window source mapping** — A commitment joining an audio result to its
time base, sample cursor, window/hop/context parameters, feature shape, live
cache payload, processor state, and model batch.

**Audio overlap plan** — A fixed record separating a source span into
conditioning-only context and newly publishable samples while binding the
processor/cache owner and previous transcript.

**Transcript segment** — A fixed typed text record binding its visible sample
range, excluded context range, media/cache/processor roots, overlap plan, and
previous transcript.

**Temporal-video selection** — A canonical bounded declaration of selected
frame ordinals, stride, keyframe lineage, eviction boundary, cache generation,
and exactly mapped target span. Its selected bytes are gathered into explicitly
charged caller-owned scratch.

**Temporal-video source mapping** — A commitment joining a temporal selection
to the complete live video-cache root, processor window, time base, model batch,
input shape, and typed result.

**Video segment** — A fixed typed video-understanding result carrying selected
frame ordinals, exact target-time span, event/confidence values, complete
processor/cache/selection lineage, and a previous-segment root.

**Video-segment timeline** — Canonical accumulated visible-tail state derived
from an immutable raw segment chain. Same-event intervals coalesce only when
they touch or overlap; gaps and different events remain distinct.

**Video-segment merge receipt** — A fixed decision record binding previous and
incoming raw segment roots, prior decision, merge policy, chosen output bounds,
overlap ticks, and visible-count effect.

**Audio/video result link** — A fixed cross-modal record mapping only newly
publishable transcript samples into the canonical video target time base. It
requires positive exact overlap and binds the transcript, processor/cache,
video timeline/tail, challenge, policy, and predecessor roots.

**Audio/video link state** — Canonical request-local chain state that pins the
audio and video media identities, shared challenge, next sequence, visible link
count, previous link, and fixed relation policy.

**Stateful transcript model state** — A fixed retained fixture state carrying
the latest transcript segment, exact next publishable sample, sample rate, and
cumulative visible text bytes. It advances atomically with typed transcript
model output.

**Audio transcript continuation checkpoint** — A fixed 576-byte composition
joining the generic stateful-model checkpoint to previous/next audio overlap
plans, transcript predecessor, video timeline, cross-modal link state, fresh
Bank epoch, and exact retained-state digest.

**VFR frame window** — A fixed 576-byte source contract carrying each active
frame ordinal, presentation tick, duration, keyframe flag, exact feature and
timestamp payload roots, previous end tick, declared discontinuity, media
lineage, and predecessor-window root without inferring a constant frame rate.

**Stateful video-model continuation checkpoint** — A fixed 768-byte composition
joining the generic retained-model checkpoint to previous/next VFR windows, the
previous typed video segment, visible timeline, transcript ranges, result-link
predecessor, fresh Bank epoch, and exact next frame/time boundary.

**Synchronized media watermark** — The lower exact master-clock tick reached by
the bound audio and video processor states, accepted only when integer mapping
is exact and declared stream skew remains within policy.

**Restored ownership receipt** — A domain-separated commitment that replaces a
dead source's retained-output authority with the fresh Bank epoch, receipt
identity, owner and claims actually reacquired during restore. It also binds the
prior checkpoint, lease, output and chunk roots so a successor cannot replay
stale source authority.

**Object lease receipt** — A commitment to one blob, owner, retained generation,
explicit expiry tick, and lifecycle grant. It is valid only while every field
equals the active store slot.

**Repair receipt** — A commitment joining a repaired blob, repair generation,
declared source, prior quarantine reason, repair grant, and resulting store
snapshot.

**Logical accounting** — Runtime-owned counters derived from declared state. It
does not by itself prove RSS, device residency, energy, or physical isolation.

**Machine envelope** — Captured host, software, load, power, and telemetry
conditions attached to benchmark evidence.

**Paged KV** — A key/value cache whose committed sequence is represented by
explicit logical pages, generation-fenced ownership, and a canonical root.

**Prepared image** — A `.glrt` artifact whose layouts and integrity are validated
before execution.

**Provider evidence** — Credential-free records describing request identity,
transport events, usage settlement, cost, and durable journal state.

**Publication** — The moment prepared KV, RNG, sampler, and output state becomes
visible as one committed transition.

**Receipt** — A generation-fenced proof that a specific operation was admitted or
committed under a particular runtime state.

**ResourceBank** — The exact logical admission and ownership ledger shared by
scheduling and publication.

**Root** — A canonical digest over a state or event chain. Roots are meaningful
only with their ABI, domain, and replay rules.

**Settlement** — Terminal reconciliation between a reserved provider request and
the authoritative usage outcome supplied by a transport adapter.

**Token transaction** — A prepare/commit/abort protocol for one token's KV, RNG,
sampler, output, and ownership mutations.

**Wire** — A versioned, explicitly encoded byte representation designed for
independent verification.
