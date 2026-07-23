# Architecture

Glacier Engine separates AI computation from the authority to consume resources
and publish state. Computation may be speculative; externally visible state is
not.

## Component map

| Layer | Primary components | Responsibility |
| --- | --- | --- |
| Family adaptation | future `ModelFamilyAdapter`, operation registry, typed state/output adapters | Describe family-specific artifacts, planning, state, candidate validation, and publication units without expanding authority |
| Model | `.glacier`, `.glrt`, loader, prepared model | Validate source and execution layouts before use |
| Execution | CPU kernels, optional Metal backend, DecodePlan, sealed media plans | Produce candidate activations, KV rows, tokens, tensors, or media outputs under explicit bounds |
| Resource | `ResourceBank`, `LeaseTree` | Reserve exact logical capacity and track ownership |
| Schedule | `LaneWeave` | Admit requests and issue deterministic service permits |
| State | contiguous/paged KV, token transactions | Prepare and atomically publish AI-visible state |
| Continuation | capsule, resolver, bundle, store, collection planner, sweep journal/commit/record/writer, payload file, ownership/KV/runtime state, checkpoint archive and selector | Bind complete checkpoint generations, atomically select one root, reacquire charged ownership, and resume publication across a process boundary |
| Media | `MediaObjectV1`, sealed decode/transform plans, bounded fixture executor, `MediaRuntimeTxn`, `MediaRuntimeLease`, `MediaStreamRuntime`, `MediaStreamContinuation`, `MediaStreamCheckpointSet`, `MediaProcessorState`, `MediaProcessorCache`, rational positions, timeline events, publication state | Bind image/audio/video identity and bounds, own buffers and caches exactly, advance bounded chunk chains, atomically select complete generations, and resume outputs plus processor caches after process death |
| Model adapters | `ModelContract`, `StatelessModelAdapter`, `StatefulModelAdapter`, `StatefulModelContinuation`, `VisionEncoderAdapter`, `AudioWindowAdapter`, `TemporalVideoAdapter`, `LatentStepAdapter` | Separate vocabulary from support, bind exact tensor/resource/source schemas, isolate caller-owned candidates, and publish typed stateless results or restartable state/result transitions only after family validation |
| Provider | context pack, gateway, transport harness | Reconcile tokens, coalesce work, cancel, and settle usage |
| Durability | settlement/cost wires, cost journal | Commit replayable cost evidence across process failure |
| Evidence | event wires, join roots, Python verifiers | Reconstruct and reject malformed or substituted history |

## Local execution flow

```text
validated model + request
          │
          ▼
   derive exact claim
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
`TemporalVideoAdapter` adds a canonical strided-frame selection. It binds
keyframe lineage, eviction boundary, cache generation, and an exactly mapped
target span, gathers only selected frames into charged caller-owned scratch,
scrubs the gather buffer on every return, and then enters the same publication
lifecycle.
`StatefulModelAdapter` adds a distinct retained-state transaction. It pins the
model and state publication roots, executes into disjoint output/state
candidates, revalidates both, and makes the typed result plus successor state
visible together. `LatentStepAdapter` retains the first exact synthetic
denoise-step fixture over that lifecycle. `StatefulModelContinuation` binds the
intermediate model/state publications into a fixed checkpoint, charges a fresh
`LeaseTree` before materializing the retained latent in another process, and
chains the terminal step at the exact next result sequence.

The reference path supports only retained RGB8, PCM s16le, and intra-frame
gray8 fixtures plus image crop/nearest/tile, weighted audio mix/exact
decimation, and keyframe selection. It has no external codec, encoder,
network, camera, microphone, model, or accelerator authority. The atomic-set
worker has explicit filesystem authority but does not emulate device power
loss. External formats, measured accelerator residency, and production-model
integrations remain future layers. See
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md) and
[Hierarchical Media Buffer Ownership](MEDIA_RUNTIME_LEASE.md), then
[Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md) and
[Media Stream Continuation](MEDIA_STREAM_CONTINUATION.md), followed by
[Atomic Media Stream Checkpoint Sets](MEDIA_STREAM_CHECKPOINT_SET.md) and
[Multimodal Processor and Cache State](MEDIA_PROCESSOR_STATE.md), then
[Materialized Multimodal Processor Caches](MEDIA_PROCESSOR_CACHE.md).

### ResourceBank

`ResourceBank` accounts for declared logical quantities such as KV bytes,
activation bytes, scratch bytes, page slots, and operations. Admission returns a
generation-fenced receipt. Stale, mutated, foreign, or over-capacity receipts
fail before state changes.

`LeaseTree` subdivides one request receipt into exact child ownership. It is used
to connect physical KV page allocation and retirement to the parent resource
claim without treating process RSS as proof of ownership.

### LaneWeave

`LaneWeave` is a bounded control-plane scheduler. It combines exact admission,
weighted service, deadline projection, cancellation, and replayable events.
Prepared permits are single-purpose and fenced against stale address reuse.

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
Metal through a small Objective-C bridge. Cross-target test compilation covers
x86_64 and AArch64 Linux. Execution, numerical, and physical-resource validation
still require real machines for each promoted platform.

## Where to go deeper

- [Design](DESIGN.md): invariants and extension rules.
- [Paging](PAGING.md): weight and KV paging boundaries.
- [Model format](FORMAT_SPEC.md): portable draft format.
- [Native runtime image](RUNTIME_IMAGE.md): execution image ABI.
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
- [Typed model-family contracts and vision adapter](MODEL_FAMILY_ADAPTER.md):
  canonical artifact/plan/result records, explicit support negotiation, and a
  cache-bound transactional embedding fixture.
- [Typed audio-window encoder adapter](AUDIO_WINDOW_ADAPTER.md): signed feature
  windows, sample/window/hop source mapping, shared stateless publication, and
  exact cancellation/release.
- [Typed temporal-video encoder adapter](TEMPORAL_VIDEO_ADAPTER.md): canonical
  strided-frame selection, keyframe/eviction lineage, charged gather scratch,
  exact target-time mapping, and transactional embedding publication.
- [Stateful model adapter and latent-step fixture](STATEFUL_MODEL_ADAPTER.md):
  canonical retained-state publication, pinned lineage, disjoint candidates,
  and atomic state/result replacement.
- [Stateful model continuation](STATEFUL_MODEL_CONTINUATION.md): canonical
  intermediate checkpoint, fresh-Bank retained-state ownership, and exact-once
  terminal publication after a real process restart.
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
- [Evidence policy](EVIDENCE_POLICY.md): what results are allowed to claim.
