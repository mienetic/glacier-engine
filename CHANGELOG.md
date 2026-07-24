# Changelog

Significant user-visible changes will be recorded here. The project follows the
spirit of Keep a Changelog, but it does not claim semantic-versioning stability
before the first stable release.

## Unreleased

### Changed

- Stateful model prepare/rollback now leave caller-visible output and successor
  state buffers unchanged until commit; abort and drift scrub only private
  candidates.
- Vision now uses the same family-neutral stateless adapter lifecycle as audio
  and temporal video, removing its duplicate admission/publication state
  machine while preserving live-cache checks, candidate revalidation,
  abort scrubbing, and exact release behavior.
- Shared stateless adapters now reject candidate, visible-output, weight, and
  input buffer overlap before execution, preserving pre-commit invisibility
  under caller-owned storage.

### Added

- Bounded generated-media output registry: an independent canonical ABI packs
  one to four output entries per present image/audio/video modality, up to
  twelve total, as fixed 544-byte entries in `(modality, ordinal)` order, one
  fixed 544-byte manifest, and exact concatenated encoded payloads in exactly
  three archive extension objects. Exact ordinal/unit/timeline/predecessor
  continuity, exact raw/encoded/encoder/format/state/completion roots, and the
  complete preceding archive are verified without changing existing V1 wires.
  Completion fields are structurally enforced and roots are opaque; typed
  producer acknowledgement/state validation remains an adapter precondition.
  The retained generations contain `2/3/2` then `2/2/3` image/audio/video
  outputs; an independent Python oracle and seven-phase `SIGKILL` campaign
  select the previous generation five times and successor twice, reject mixed
  generations, and converge through the existing outer filesystem selector.
- Generated-media encoded payload archives: one canonical eight-object
  generation binds an 864-byte manifest, the shared checkpoint, three typed
  members, and exact encoded image/audio/video bytes while keeping raw-output,
  encoded-payload, encoder-implementation, and format identities separate. An
  independent Python oracle verifies the wire and two-generation lineage; a
  seven-phase `SIGKILL` campaign selects the exact previous generation five
  times and successor twice, rejects mixed generations, and converges
  idempotently through one outer filesystem selector.
- Atomic generated-media checkpoints: fixed 480-byte typed member, 800-byte
  checkpoint, and 352-byte selector records compose one generated image, one
  acknowledged PCM chunk, and one acknowledged raw-video segment without
  mixed-generation visibility. Exact scope, policy, challenge, result, output,
  state, completion, totals, and predecessor bindings are independently
  verified in Python; a four-boundary `SIGKILL` campaign recovers only the
  complete previous or successor generation.
- Generated-video manifest publication and display acknowledgement: canonical
  state, two-frame manifest, provenance, publication result, observation,
  acknowledgement plan, and acknowledgement result records bind exact raw
  frame roots, per-frame durations, media/resource lineage, one outstanding
  segment, and sink-bound application completion. An abort-safe transaction,
  independent mutation-complete Python oracle, and real two-process proof
  reject partial/duplicate display, gate the successor segment, preserve
  visibility on cancellation, and release ownership to zero.
- Generated-audio publication and playback acknowledgement: canonical
  448-byte state, 576-byte plan, 512-byte provenance, 576-byte result, 288-byte
  observation, 448-byte acknowledgement plan, and 512-byte acknowledgement
  result records bind exact PCM frames, source/renderer/media/resource lineage,
  one outstanding buffer, and sink-bound application completion. An abort-safe
  transaction, independent mutation-complete Python oracle, and real
  two-process proof reject partial/duplicate acknowledgement, gate the
  successor chunk, and release ownership to zero.
- Exact speech annotation publication: fixed state, plan, and result records
  bind canonical transcript words to sample-derived timing, first-occurrence
  speaker identities, confidence, media/cache lineage, and predecessor state.
  An abort-safe transaction, independent mutation-complete Python oracle, and
  real two-process proof publish two exact words and speaker turns without
  duplication, then release ownership to zero.
- Generated-image publication after latent restart: fixed 736-byte plan,
  640-byte provenance, and 704-byte result records bind artifact, checkpoint,
  terminal plan/result/state, decoder, media, tenant, resources, and
  publication lineage. An abort-safe transaction publishes a bounded raw image
  atomically, an independent Python oracle rejects every wire mutation, and a
  real target process reaches the terminal latent, retries after cancellation,
  commits once, and releases ownership to zero.
- Stateful VFR video-model continuation: canonical per-frame
  ordinal/PTS/duration/keyframe evidence, a fixed 48-byte retained model state,
  a 768-byte composed checkpoint, independent Python oracle, and native
  two-process proof publish the exact successor segment after a declared gap,
  advance video timeline and cross-modal link state, and release ownership to
  zero.
- Stateful audio transcript continuation: a typed exact-integer transcript
  family, fixed 576-byte composed checkpoint, independent Python oracle, and
  native two-process proof restore model state under fresh charged ownership,
  publish the next non-duplicated sample range, advance its video-result link,
  and release all ownership to zero.
- Exact audio/video result linking: canonical 320-byte state and 576-byte result
  wires map only newly publishable transcript samples to the accumulated video
  timeline using exact integer time conversion, reject non-overlap and
  fractional mapping, preserve both modality lineages, and publish through an
  exact resource-backed transaction with independent golden roots.
- Canonical video-segment timeline: fixed 384-byte state and merge receipts
  coalesce only touching/overlapping results of the same event, retain gaps or
  different events, preserve raw predecessor lineage, and publish through an
  exact resource-backed transaction with independent golden roots.
- Typed video-segment adapter: a fixed 512-byte result binds a bounded strided
  frame selection, exact target-time span, event/confidence fields, live
  processor/cache ownership, and predecessor lineage to transactional
  publication with cross-language golden roots and mutation-complete tests.
- Overlapping-audio transcript adapter: a canonical context/new-sample plan
  binds live processor-cache ownership to a fixed transcript segment, excludes
  context samples from the publishable range, rejects predecessor/candidate
  substitution, and publishes through the shared stateless lifecycle.
- Stateful model continuation: a canonical 512-byte intermediate checkpoint
  reconstructs model/state publications in a distinct process, charges a fresh
  `LeaseTree` before latent materialization, chains the terminal plan, prevents
  duplicate publication, and releases predecessor and successor ownership to
  zero.
- Stateful model publication and exact latent-step fixture: a canonical
  320-byte state record, pinned model/state snapshots, disjoint candidate
  buffers, and one transition root publish replacement state with its typed
  result or preserve the predecessor on abort/drift.
- Typed temporal-video encoder: a canonical strided-frame selection binds
  keyframe lineage, eviction boundary, cache generation, and exact target
  timeline mapping; charged gather scratch is always scrubbed before the shared
  stateless lifecycle publishes deterministic embeddings or aborts.
- Typed audio-window encoder and shared stateless adapter lifecycle: exact i16
  feature windows bind sample/window/hop lineage and live audio-cache ownership,
  publish deterministic i32 embeddings, reject in-memory state mutation and
  candidate drift, and release model/cache claims to zero.
- Typed model-family contracts and the first vision-encoder adapter: canonical
  artifact, execution-plan, and result wires distinguish vocabulary from
  executable support, while a zero-capability exact-integer fixture consumes a
  live restored image cache, rejects candidate drift, publishes a typed
  embedding, and returns model/cache ownership to zero.
- Materialized multimodal processor caches: a sixth atomic checkpoint object
  carries exact image/audio/video cache bytes. A fresh process charges
  generation-fenced `activation_bytes` before verification and visibility,
  advances generation three, and releases every cache owner to zero.
- Stateful atomic media checkpoints: the fixed processor/cache bundle is now a
  fifth lineage-bound archive object cross-checked against all three stream
  checkpoints. Four-object archives remain readable, while a fresh process
  restores generation two and publishes processor-aware generation three.
- Fixed multimodal processor/cache state: image tile/patch progress, audio
  feature windows, video temporal-cache windows, and an exact synchronized
  watermark share a 2,272-byte lineage-bound bundle with an independent Python
  verifier and mutation-complete tests.
- Post-restore multimodal successor checkpoints: a fresh process rebinds six
  retained image/audio/video outputs, appends three chunks, atomically
  publishes generation three, releases ownership, and supports another
  fresh-process resume. Independent verification rejects rehashed stale Bank
  epochs, receipt replay, and restored-owner substitution.
- One-root image/audio/video checkpoint generations: three fixed stream
  checkpoints plus a canonical retained-output bundle publish through the
  immutable archive and atomic selector. A seven-boundary `SIGKILL` campaign
  resumes the complete previous or successor generation in fresh processes,
  then proves idempotent recovery to generation two.
- Public contributor documentation, governance, support, security, and conduct
  policies.
- Glacier Engine visual identity and repository metadata.
- Proof-carrying provider evidence join over cost, gateway, and transport roots.
- Crash-recoverable provider cost journal store and recovery tests.
- Lossless context packing, token reconciliation, and allocation-free adapter
  fixtures.
- Transactional token publication with contiguous and paged KV state.
- Exact resource admission, LeaseTree ownership, and deterministic LaneWeave
  scheduling.
- Fixed 608-byte continuation capsule binding nine typed external AI-state
  objects, with allocation-free Zig verification and an independent Python
  verifier.
- Allocation-free continuation object resolver with tenant-scoped capability
  grants, bounded catalog scans and byte quotas, caller-owned output, and full
  post-resolution composition verification.
- Fixed continuation bundle manifest with separate semantic and tenant-bound
  blob roots, canonical first-occurrence dedup ordinals, exact logical/unique
  byte totals, and an independent Python verifier.
- Bounded tenant continuation object store with atomic bundle import, immutable
  payload ownership, duplicate reference reuse, exact payload/index accounting,
  quarantine, corruption checks, and allocator-failure rollback.
- Deterministic object lifecycle with generation-fenced leases, explicit logical
  expiry, quarantine invalidation, capability-bound repair, v2 snapshots, and
  matching Zig/Python receipt roots.
- Retained object retirement and bounded dry-run collection planning with exact
  root multiplicity, complete current-lease coverage, per-slot decisions,
  collectible ceilings, and matching Zig/Python evidence roots.
- Capability-scoped functional sweep prepare/abort journals that regenerate an
  approved collection plan, reject stale snapshots and tampered journals, stage
  exact collectible totals, and leave all payload bytes untouched.
- Atomic in-memory object sweep commit with a separate destructive capability,
  complete plan regeneration, canonical retired-target validation, exact
  before/after accounting, allocator-call evidence, and matching Zig/Python
  roots.
- Fixed 784-byte continuation sweep evidence record with body/footer framing,
  record chaining, semantic reconstruction of the commit grant and both
  receipts, pinned expectation checks, and independent Zig/Python fixtures.
- Pure anchored sweep-record classifier with exact committed-prefix metadata,
  five clean/incomplete/corrupt statuses, semantic and chain verification, and
  exhaustive cross-language append-boundary and mutation fixtures.
- Snapshot-bound continuation sweep publication with exclusive lease
  generations, separate append/repair capabilities, ordered body/footer sync,
  poisoned uncertain writers, explicit incomplete-tail repair, and exhaustive
  Zig/Python deterministic crash-boundary models.
- Descriptor-relative continuation sweep files with no-follow lookup,
  exclusive advisory locks, device/inode/link/permission fencing, ordered file
  and directory sync, replacement detection, independent Python verification,
  and six native plus Python subprocess-death boundaries.
- Exact no-mutation sweep commit previews with predicted post-state roots,
  file-synced publication before payload deallocation, injected-boundary
  recovery, and idempotent old/new snapshot reconciliation in Zig and Python.
- Canonical tenant payload snapshots and a descriptor-relative durable payload
  adapter with fixed exact-target reclaim records, copy-on-write promotion,
  stable locking across inode replacement, independent Python verification, and
  seven native plus Python process-death boundaries.
- Fixed continuation ownership manifest with capsule/payload binding,
  fresh-epoch ResourceBank/LeaseTree reacquisition, exact restored publication
  sequence, charge-before-materialization ordering, explicit abort, and
  mutation-complete Zig/Python verification.
- Canonical paged-KV page images with durable payload membership, complete
  source ownership-chain verification, atomic fresh-cache reconstruction, new
  target generations, and stale source-ref rejection.
- Fixed 304-byte continuation runtime state joining the exact publication
  sequence, logical KV digest, RNG, sampler count, output prefix, checkpoint
  challenge, and previous commit, with mutation-complete Zig/Python verification.
- A model-free two-process continuation proof that synchronizes a checkpoint,
  releases source ownership, exits, reacquires a fresh Bank and paged cache,
  resumes the next token exactly once, chains its receipt, and returns target
  ownership to zero.
- Cross-process paged-KV cache-instance collision detection and forced target
  remapping so process-local identity counters cannot revive source PageRefs.
- Canonical whole-checkpoint archives plus a fixed root selector, immutable
  content-addressed generations, exact previous/successor recovery, and seven
  native process-death boundaries followed by seven fresh live resumes.
- An independent checkpoint archive/selector verifier with shared golden roots,
  mutation-complete wire coverage, re-rooted contradiction rejection, and a
  pure foreign-state recovery model.
- A fixed 272-byte shared image/audio/video object descriptor with independent
  Zig/Python golden roots, mutation-complete verification, and re-rooted
  semantic contradiction rejection.
- Checked rational media positions, explicit transform-event roots, and an
  exact-once logical chunk publication chain that binds output and
  resource-claim evidence without granting device, filesystem, or network
  authority.
- A model-free shared media demo plus a gated roadmap from the new contract
  prototype through bounded image, streaming audio, and video execution.
- A fixed 416-byte sealed media decode plan binding object, decoder,
  representation, execution/numerical/rejection policy, exact output/scratch
  bounds, transform, resource policy, challenge, and required capabilities.
- Tiny bounded RGB8, PCM s16le, and intra-frame gray8 video fixtures with a
  canonical 320-byte header, allocation-free caller-owned identity decode,
  complete per-pixel/frame source mappings, keyframe bounds, and shared
  Zig/Python fixture, plan, and receipt roots.
- Mutation-complete verification for all three fixture and decode-plan wires
  plus foreign-plan, output-capacity, overlap, truncation, and re-rooted
  semantic contradiction rejection.
- A fixed 512-byte sealed media transform plan binding source decode evidence,
  implementation, exact geometry/time/rate parameters, resource policy,
  challenge, capabilities, output bounds, and its domain-separated root.
- Allocation-free caller-owned image crop/nearest/tile, audio weighted
  stereo-to-mono mix with exact integer decimation, and video keyframe-selection
  executors with one exact mapping per visible output unit.
- Shared Zig/Python transform plan, mapping-chain, output, and receipt evidence,
  including every-byte plan mutation, re-rooted contradiction, stale binding,
  capacity, substitution, and native overlap rejection.
- An integrated model-free media runtime transaction that derives exact
  image/audio/video `ResourceBank` claims, executes into provisional
  caller-owned storage, revalidates transformed output and every mapping,
  atomically commits media and resource publication, scrubs on abort, permits
  exact retry, and releases each complete claim.
- A fixed 640-byte media runtime receipt with independent Python reconstruction
  of resource integrity, transform evidence, timeline events, output mappings,
  publication lineage, and every-byte mutation rejection.
- A native three-modality runtime demo covering three admitted/committed
  sessions, explicit audio abort/scrub/retry, seven exact mappings, three
  releases, and final zero Bank usage without filesystem, network, device, or
  model authority.
- A hierarchical media runtime that splits every request into exact decoded
  source, mapping, optional scratch, and output LeaseTree allocations before
  execution; abort reclaims all dynamic leases, while committed requests can
  retire provisional storage early and retain only output ownership.
- A fixed 1,536-byte hierarchical media receipt with pointer-free tree/node
  evidence, independent Zig/Python golden roots, every-byte mutation rejection,
  authority and candidate substitution tests, node/capacity exhaustion tests,
  and a native three-modality zero-leak demo.
- A bounded multi-chunk media stream runtime that commits two image, audio, and
  video chunks under one exact target timeline; rejects gaps, overlaps, length
  drift, copied transactions, and capacity overflow; reclaims cancelled or
  mutated unpublished chunks; and retains one output lease per commit.
- A fixed 352-byte predecessor-bound media chunk receipt with shared Zig/Python
  golden chains, every-byte mutation rejection, state/execution/key/predecessor
  substitution tests, and a six-chunk native demo ending with zero Bank usage,
  live allocations, and active trees.
- A fixed 2,048-byte media stream checkpoint with exact retained-output
  ownership plans, shared Zig/Python golden roots, every-byte mutation
  rejection, and charge-before-materialization restore into a fresh Bank.
- A two-process image/audio/video restart proof that syncs checkpoint/output
  bytes, releases all source ownership before exit, restores under a distinct
  PID and Bank epoch, appends the exact next chunks without duplicates, and
  closes every restored and new lease to zero.
- A full Glacier AI Runtime roadmap defining shared runtime planes, universal
  family adapters, model-family coverage, promotion gates, delivery sequence,
  use cases, and contributor-sized lanes.

### Status

- The project remains experimental; public API and file formats may change.
