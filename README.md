<p align="center">
  <img src="assets/brand/glacier-engine-logo.png" width="190" alt="Glacier Engine logo">
</p>

<h1 align="center">Glacier Engine</h1>

<p align="center"><strong>A proof-carrying runtime for local and provider-backed AI execution.</strong></p>

Glacier Engine is an experimental full AI Runtime project written in Zig. It
treats artifact identity, resource admission, placement, scheduling, execution,
continuation, token and media publication, provider usage, and cost as explicit
state transitions that can be rejected, replayed, and verified. Model inference
is one runtime plane, not the boundary of the project.

The project is early enough for contributors to shape its public APIs and mature
enough to offer tested building blocks, credential-free demos, portable evidence
formats, and independent verifiers.

> **Project status:** experimental. The core contracts are heavily tested, but
> model coverage, platform coverage, API stability, packaging, and production
> operations are still under active development.

## Why Glacier Engine

- **Atomic token publication.** KV rows, RNG state, sampler counters, and output
  words are committed together or remain invisible.
- **Exact resource admission.** `ResourceBank` and `LeaseTree` make logical
  ownership and release part of the execution contract.
- **Deterministic multi-request scheduling.** `LaneWeave` provides bounded,
  weighted service with replayable decisions and fail-closed permits.
- **Portable workload-pressure evidence.** A versioned mixed image/audio/video
  scenario drives real admission, weighted service, overload rejection,
  timeout, cancellation, and final release; Zig exact replay and an independent
  Python verifier agree on every outcome, trace, summary, and root.
- **Generated workload corpus.** Four retained seeds expand into 32 bounded
  deterministic open-loop scenarios through coordinate-addressed SHA-256
  decisions. Zig and an independent Python implementation reproduce every
  unchanged W0/W1 case, while an exact-signature synthetic fixture proves
  deterministic local-minimum shrinking.
- **Deterministic closed-loop conformance.** A separately versioned,
  finite-source controller maintains a declared logical in-flight target.
  Terminal outcomes create FIFO successor credits for the next logical step;
  canonical lineage and phase-aware evidence are replayed independently in
  Zig and Python through final zero ownership.
- **Mixed typed-workload conformance.** One separate W4a contract drives the
  retained vision, audio-window, and temporal-video adapters through exact
  scheduler admission, final-service execution, typed publication, cancellation,
  timeout, rejection, cache cleanup, and authoritative replay without changing
  the earlier workload ABIs.
- **Typed tool transaction conformance.** The W4b-a profile separates an
  agent proposal from local policy authority. A scheduler-locked precommit
  rejects drift before logical mutation; its retained-lock publish phase binds
  a bounded process-local effect to the exact service event. The profile proves
  execute, exact duplicate reuse, denial, idempotency conflict, cancellation,
  timeout, rejection, and zero-authority cleanup without ambient I/O.
- **Durable recoverable action handoff.** W4b-c keeps every clean committed
  ActionOutbox prefix at `320 + 752n` bytes and adds a descriptor-relative
  POSIX store with an exclusive advisory lock, no-follow/private/one-link
  admission, descriptor-versus-entry identity fences, semantic preflight,
  ordered body/footer sync, snapshot-bound repair, and mandatory fresh
  reacquisition after an incomplete tail. Zig and Python agree across 40
  append-phase, 754 section-prefix, 751 repair-tail, and 8 repair-fault cases;
  49 real host `SIGKILL` deaths cover initialization, append, and repair.
  A committed dispatch intent remains `uncertain` until validated adapter
  evidence permits a terminal decision or safe retry. This W4b-c campaign
  remains the separate real process-death proof.
- **Generation-fenced dispatch conformance.** W4b-d composes the unchanged
  store with pointer-free descriptor, request, and evidence values plus a
  bounded same-process fake authority. Its opaque callback context holds only a
  synthetic credential. Driver entry points protect one future reconciliation
  slot per existing uncertain action, require three additional slots before
  dispatch, durably append the exact intent before the callback, and never
  infer retry from callback failure. Status runs only while free slots can
  cover every uncertain action. An atomic
  `not_applied_fenced` result at generation `G` rejects delayed dispatches
  through `G`; only the exact `G + 1` retry preserves the stable remote request
  while deriving a new dispatch root. Pending and unknown status remain
  uncertain, terminal duplicates replay with an application count of one, and
  deterministic same-process faults cover four terminal-transition plus four
  fenced-transition append phases before fresh reopen, repair, and
  reconciliation. The
  focused gate runs integrated Zig tests, 20 independent Python tests, and a
  live canonical Zig-to-Python reference-report comparison. The report is
  generated during the gate rather than stored as a retained JSON fixture.
  Low-level contract callbacks alone do not prove durable ordering.
  This is not a network, provider, or tool effect; it uses no real credential
  and proves no OS sandbox, credential security, cryptographic origin,
  fake-service restart persistence, new process-death behavior, native
  platform behavior, performance, power behavior, or external exactly-once
  delivery.
- **Scheduled mixed-media execution.** The same accepted scheduler receipt now
  drives one real bounded audio, video, or image decode-transform-publication
  transaction on the final service quantum. Cancelled, timed-out, and rejected
  work publishes nothing; the additive Zig/Python sidecar proves exact outputs,
  mappings, receipt reuse, atomic final service, and zero orphan ownership.
- **Paged KV ownership.** Physical page identity, generations, references, and
  publication fences are bound into token receipts.
- **Generation-remapped KV restore.** Canonical committed-row images rebuild a
  fresh paged cache under charged ownership; historical cache/page generations
  remain stale evidence and never become target authority.
- **Cross-process token continuation.** A fixed runtime wire joins paged KV,
  RNG, sampler count, output prefix, publication sequence, and commit lineage;
  a two-process proof resumes the next token exactly once and returns ownership
  to zero.
- **Atomic checkpoint root switching.** Complete checkpoint objects live in one
  immutable archive selected by a fixed 192-byte record; seven process-death
  phases recover only the exact previous or successor root before live resume.
- **Shared media contracts.** One fixed image/audio/video identity, checked
  rational timeline, explicit transform history, and exact-once chunk
  publication give future multimodal paths a verifiable model-free foundation.
- **Bounded media inputs.** Sealed decode plans and tiny RGB, PCM, and
  intra-frame video fixtures decode into caller-owned storage while mapping
  every pixel, audio frame, and video frame to exact source bytes.
- **Deterministic media transforms.** A sealed 512-byte plan drives
  allocation-free image crop/nearest/tile, audio weighted mix/exact decimation,
  and video keyframe selection with exact per-output-unit mappings and
  cross-language receipts.
- **Transactional media execution.** One request-local runtime lifecycle admits
  an exact image/audio/video claim, executes into provisional caller-owned
  buffers, revalidates every output mapping, commits media and resource
  publication together, scrubs on abort, and releases the claim to zero.
- **Per-buffer media ownership.** Decoded source, mapping, declared scratch
  (zero in the retained plans), and output storage have distinct
  generation-fenced `LeaseTree` roles. A committed request can scrub and retire
  provisional buffers early while retaining only the published output lease.
- **Bounded multimodal streams.** Image, audio, and video chunks share one exact
  target timeline while each chunk keeps an independently owned output.
  Gap/overlap, cancellation, candidate drift, capacity, and chain substitution
  reject without orphaning unpublished leases.
- **Two-process media continuation.** A fixed checkpoint carries exact stream
  state and retained-output ownership across a real process exit. The target
  charges a fresh Bank before materialization and appends the next image,
  audio, or video chunk without duplicating publication.
- **Atomic multimodal generations.** Three stream checkpoints, one canonical
  retained-output bundle, an optional fixed processor-state bundle, and an
  optional verified cache-payload bundle share a single immutable archive root.
  Process-death campaigns prove that readers resume the complete previous or
  successor image/audio/video generation, never a mixed set.
- **Post-restore checkpoint successor.** A fresh process rebinds retained
  ownership from the selected generation, appends image/audio/video chunks,
  atomically publishes generation three, releases its Banks, and supports
  another fresh-process resume without accepting stale source authority.
- **Multimodal processor/cache state.** Fixed image tile/patch progress, audio
  feature windows, video temporal-cache windows, and an exact synchronized
  watermark form one lineage-bound, independently verified state bundle. A
  stateful checkpoint stores it as a fifth atomic object and advances it through
  fresh-process generation three.
- **Restore-before-visible processor caches.** A sixth atomic object carries
  exact image/audio/video cache payloads. Fresh processes charge three
  generation-fenced `activation_bytes` allocations before byte verification,
  make them live only after success, and release every cache owner to zero.
- **Typed model-family execution.** Fixed artifact, execution-plan, and result
  records separate runtime vocabulary from executable support. Capability-free
  vision, audio, and temporal-video adapters read only verified live caches,
  compute into provisional storage, reject candidate drift, and publish
  source- and ownership-bound embedding transactions. Video selection gathers
  strided frames through explicitly charged scratch and scrubs it on return.
- **Inspectable reference compatibility.** A deterministic read-only command
  renders eight append-only exact-integer fixture profiles as versioned JSON.
  The experimental C, standard-library Python, and dependency-free Rust paths
  can enumerate the same fixed records and query every matching profile bit
  without loading a model or probing the host.
- **Overlap-safe transcripts.** A canonical audio plan separates prefix context
  from newly publishable samples, binds both to live processor-cache ownership,
  and commits a fixed transcript segment without turning repeated context into
  duplicate visible text.
- **Source-bound video segments.** A canonical strided selection now publishes
  a fixed typed result carrying exact frame/time bounds, keyframe and eviction
  lineage, model event/confidence fields, and a predecessor-bound segment root.
- **Deterministic video timelines.** Fixed state and receipt wires coalesce only
  touching or overlapping results of the same event, retain gaps and different
  events, preserve raw segment lineage, and publish each decision atomically.
- **Exact cross-modal result links.** A fixed transaction maps only newly
  publishable transcript samples onto the accumulated video timeline, rejects
  fractional or non-overlapping time, excludes conditioning context, and
  preserves both modality lineages in one independently verified chain.
- **Fresh-process transcript continuation.** A stateful transcript family and
  fixed composed checkpoint restore exact sample/model state under fresh
  charged ownership, publish only the next text range, advance its video link,
  and return every target allocation to zero.
- **Exact word timing and speaker turns.** Fixed annotation state, plan, and
  result wires map transcript token bytes onto exact sample ranges and
  first-occurrence speaker identities. Abort preserves visibility, while a
  distinct target process resumes the next word and turn without duplication.
- **Stateful VFR video continuation.** Explicit per-frame PTS and duration wires
  bind exact feature bytes, declared gaps, retained temporal state, typed video
  segments, timeline decisions, and cross-modal links across a real process
  restart under fresh charged ownership.
- **Atomic retained-state steps.** A separate stateful lifecycle pins model and
  state publication snapshots, executes into disjoint private output/state
  candidates, and publishes both together. A canonical two-step latent fixture
  checkpoints the intermediate state, reacquires it in a distinct process
  before materialization, and publishes the terminal result exactly once.
- **Generated images after restart.** A bounded decoder turns that exact
  terminal latent into a caller-owned image, then publishes pixels,
  provenance, typed result, resource receipt, and media timeline atomically.
  Abort and candidate drift preserve visible state, while a real two-process
  proof returns every target resource to zero.
- **Acknowledged generated-audio streams.** Canonical state, plan, provenance,
  result, observation, and acknowledgement wires publish bounded PCM chunks
  atomically and permit only one unacknowledged buffer. A distinct target
  process verifies the pending chunk, rejects partial acknowledgement, opens
  backpressure only after exact application consumption, and publishes the
  successor without duplication.
- **Ordered generated-video manifests.** Canonical state, two-frame manifest,
  provenance, result, observation, and acknowledgement wires bind raw frame
  roots and exact durations. A fresh process validates retained output before
  admission, rejects partial display, opens the successor gate only after full
  application consumption, and preserves visibility on cancellation.
- **Atomic generated-media checkpoints.** Typed image completion, acknowledged
  audio, and acknowledged video normalize into three fixed members behind one
  checkpoint and atomic selector. Four process-death boundaries recover only
  the complete previous or successor generation, never a mixed output set.
- **Exact generated-media payload archives.** One canonical eight-object
  generation joins the manifest, checkpoint, three typed members, and exact
  encoded image/audio/video bytes. Raw-output, encoded-payload,
  encoder-implementation, and format identities remain explicit; one outer
  filesystem selector recovers only the complete previous or successor
  generation across seven process-death phases.
- **Bounded multi-output media registries.** An independent canonical ABI packs
  one to four output entries per present modality, up to twelve total, into
  ordered fixed entries plus their exact encoded bytes. Image entries require
  no completion receipt; audio/video entries require a completed flag and
  nonzero completion root. One existing selector exposes only a complete
  previous or successor three-object archive.
- **Canonical generated-media producer admission.** A pre-publication gateway
  decodes the existing typed image, audio, and video records, verifies exact
  raw pixels/PCM/frame bytes, derives the common request envelope and strict
  state/result/completion predecessors, replays canonical audio/video
  application acknowledgements, and derives registry entry and predecessor
  roots for an unchanged registry generation.
- **Host-verified generated-media transitions.** A higher-assurance gateway
  replays the retained deterministic source-model and image/audio/video
  materializer profiles over exact witnesses, reconstructs image publication
  plus complete audio/video acknowledgement transitions, derives registry
  order, and emits a separate evidence sidecar bound to the unchanged
  three-object registry. Image collection order remains separate from each
  one-shot local image transaction. Replay on the verifying host is not proof
  of historical execution, live resource authority, physical playback/display,
  external codec/container conformance, or performance.
- **Bounded lossless delivery profiles.** Strict emit-and-accept modules cover
  canonical PNG for bounded 8-bit gray/gray-alpha/RGB/RGBA images, canonical
  PCM s16le WAVE for bounded mono/stereo audio, and canonical two-frame gray8
  APNG. Golden vectors, mutation rejection, native macOS execution, and
  module-level Linux/Windows/FreeBSD cross-compilation are retained. These are
  narrow profiles, not general codec, container, quality, or playback support.
- **Integrated bounded format evidence.** A separate sidecar binds those
  strict profiles, exact payloads, producer plan or manifest, registry entries,
  transition receipts, and predecessor format records without changing the
  existing registry or producer-transition V1 wires. Real two-generation PNG,
  WAVE, and APNG registry-transition fixtures cover exact successor,
  missing/foreign predecessor, semantic drift, and failure-atomic output;
  audio/video fixtures use the typed playback/display acknowledgement chains.
  A separate capacity-pressure chain fills two generations with four records
  per modality, reaching twelve transition receipts and format records per
  generation; the real inspector validates both maximum-entry triples.
  An independent Python oracle validates all three binary layers and producer
  semantics, including frozen sidecar roots, every-byte mutation, truncation,
  insertion, ordering, aggregates, padding, and successor lineage.
- **Read-only generated-media inspection.** An experimental CLI validates a
  registry archive and its producer-transition evidence, requires the exact
  predecessor pair for a successor, optionally validates current/predecessor
  format sidecars, and emits deterministic field-ordered JSON only after exact
  pair or triple validation. It renders identities and roots, never payload
  bytes, and has no callback or filesystem-write path.
- **Proof-carrying continuation.** A fixed-size manifest binds model, tokenizer,
  plan, resource, schedule, KV, sampler, output, and publication state without
  duplicating those external objects.
- **Receipt-funded restored execution.** A fresh prepared-text target keeps one
  immutable request charge while a queue-free `LeaseTree` records exact
  allocator ownership. Verified checkpoint state becomes runnable only when
  materialization and adoption commit together, and restored close returns the
  Scheduler and Bank to zero.
- **Restore-before-visible ownership.** A canonical resource-state plan
  reacquires a fresh `ResourceBank`/`LeaseTree`, charges every allocation before
  materialization, verifies exact reconstructed bytes, and only then marks the
  batch live at its restored publication sequence.
- **Exclusive fresh-process prepared-text handoff.** A five-object canonical
  restart archive carries checkpoint, successor, and bounded manifest context
  without native pointers or JSON sidecars. One durable selector advances from
  source-live to source-exited to terminal; an exclusive POSIX lease and
  one-shot activation grant fence the restored target, while a
  receipt-independent terminal semantic compares it with a separately retired
  uninterrupted oracle.
- **Tenant-scoped object resolution.** A least-authority grant admits only exact
  capsule objects under bounded scan, object, total-byte, and resolution limits.
- **Canonical continuation bundles.** Semantic roots remain kind-specific while
  equal in-tenant payloads receive one deterministic storage blob ordinal.
- **Bounded tenant object storage.** Atomic in-memory bundle import owns one copy
  per unique blob with exact payload, index, and reference accounting.
- **Generation-fenced object lifecycle.** Explicit-tick leases prevent stale
  owners and final collection; exact repair capabilities restore quarantined
  bytes only after target, reason, source, and payload verification.
- **Evidence-first object retirement.** Exact root multiplicity and complete
  lease coverage classify every stored object before any future sweep; the
  current planner is deterministic, bounded, cross-language, and dry-run only.
- **Capability-scoped object reclamation.** A separately approved plan is
  regenerated before staging, then a distinct commit grant authorizes only the
  exact canonical retired set. Receipts bind before/after snapshots and exact
  entry, payload, index, and allocator-call accounting.
- **Portable sweep evidence.** A fixed 784-byte body/footer record reconstructs
  and verifies the commit grant plus both receipts, rejects foreign chain
  positions, and exposes an ordered future append plan. An allocation-free
  anchored classifier identifies a verified committed prefix and distinguishes
  short body, missing-footer, partial-footer, and corrupt tails without receiving
  file, repair, deletion, or recovery authority.
- **Least-authority crash publication.** Snapshot-bound exclusive capabilities
  separate ordered body/footer append from explicit incomplete-tail repair.
  Uncertain I/O poisons the writer, and an allocation-free reference backend
  explores every modeled byte boundary without granting real filesystem or
  payload-deletion authority.
- **Identity-fenced file publication.** A descriptor-relative POSIX adapter
  adds exclusive locking, no-follow lookup, single-link/private-mode checks,
  file and directory sync, namespace-replacement detection, and six real
  subprocess-death boundaries without adding payload deletion authority.
- **Publication-ordered reclamation.** Glacier predicts the exact post-removal
  receipt without mutation, syncs that record before freeing payloads, and
  reconciles exact old/new snapshots so recovery applies once or recognizes an
  already-applied transition.
- **Durable payload promotion.** Canonical tenant payload snapshots use a
  copy-on-write candidate and fixed reclaim plan that preserve exact targets
  across process death. Fresh recovery accepts only the old or predicted new
  root across seven write, sync, rename, and directory-sync boundaries.
- **Verifiable provider operations.** Request coalescing, cancellation,
  settlement, cost journals, transport events, and a compact evidence root can
  be checked without provider credentials.
- **Raw-payload-free provider evidence inspection.** A deterministic JSON command
  checks the fixed outer join framing and checksum while labeling every nested
  scalar and digest as self-asserted. It renders no prompt, payload, response,
  or credential bytes and grants no authority.
- **Lossless context packing.** Exact rendered duplicates declared idempotent by
  the caller can share one emitted span while every logical span remains mapped.
- **Evidence-aware performance work.** Benchmarks record machine conditions,
  paired execution order, correctness gates, and explicit claim boundaries.
- **Fail-closed native observation.** A pointer-free W5a contract records host
  and accelerator metrics with explicit `present`, `missing`, `denied`, or
  `unsupported` state, stable source identity, per-sample provenance, subject,
  unit, a sample-clock identity on every observation, and a value-clock
  identity only on present time-valued metrics. Unavailable portable records
  retain a nonzero reason identity; present records carry none. Its runner
  rejects unsuitable pre-run conditions before invoking work, always closes a
  begun observation, retains post-run contamination as nonpublishable
  evidence, and rejects undeclared accelerator-to-CPU fallback. The retained
  download-free report wraps the existing three-profile/six-item typed
  workload; an independent Python oracle verifies every root. A shared macOS
  probe adapter now supplies the existing paired harness and retains bounded
  readable reasons for unavailable JSON metrics. A platform-neutral JSON seam
  and strict bounded Linux `/proc/meminfo` `MemAvailable` adapter are also
  implemented with cross-host parser/model tests; native Linux retention is
  still pending. Neither adapter fabricates unavailable temperature, frequency,
  power, energy, or GPU telemetry.
- **Portable reports with production-native Metal campaigns.** The W6a
  foundation adds a versioned, allocation-free binary codec for one declared
  scenario, every warmup and measured request record, a measured-cohort
  summary, and zero-orphan closure. A deterministic synthetic reference runner
  emits only the raw wire, while an independent standard-library Python
  implementation decodes it and recomputes its roots and summary. Focused
  coverage rejects a one-bit mutation at every serialized-byte position,
  truncation, extension, record reordering or duplication, and rehashed
  semantic forgeries. W6b now connects that unchanged wire to the production
  macOS Metal allocation and dispatch path: one fixed closed-loop campaign
  runs 4 warmup and 16 measured 37x64 INT4 matrix-vector requests over two
  logical adapter slots and one persistent eight-buffer lease. Both requests
  in each pair are submitted before either wait; every output must pass its CPU
  oracle, and publication occurs only after Bank, pin, dispatch, command, and
  buffer ownership all return to zero. The native report carries direct
  same-command GPU timing and sampled `currentAllocatedSize` context.
  `currentAllocatedSize` is not residency, and two logical live slots are not
  proof of physical GPU parallelism or hardware queue occupancy. Utilization,
  residency, physical queue depth, power, energy, temperature, frequency, and
  physical parallelism remain explicitly unsupported. The codec and synthetic
  runner cross-compile for the retained Linux, Windows, and FreeBSD targets;
  those builds prove source portability only and execute no native GPU work.
  W7a reuses that production path for a finite controlled-disruption campaign:
  50 fixed epochs retain 250 ordered records, including 100 CPU-oracle-checked
  Metal commands plus explicit cancel-before-submit, malformed pre-submit
  rejection, and full-two-slot capacity-rejection outcomes. Each epoch proves
  settlement and unchanged persistent-buffer ownership before reuse, and the
  final closure proves zero live ownership. Action-bound commitments prevent
  admitted actual roots from being swapped with another outcome, while
  generation-bound capacity roots preserve the exact request/ticket cursors.
  These are controlled runtime conditions, not physical device removal, driver
  crash, power loss, long-duration soak, or performance evidence.
  W7b-a adds the bounded segmented soak above that same native path: 12
  independently verified 50-epoch segments execute 1,200 CPU-oracle-checked
  Metal commands across two persistent worker generations, with one planned
  clean restart and a paced minimum duration of 60 seconds. A canonical
  campaign manifest and active selector publish each contiguous verified
  prefix. Every W7b segmented production gate writes a private
  content-addressed store,
  closes the live writer, and reopens that store through a fresh
  offline-verifier process; an output option retains it after the gate instead
  of deleting it. An active prefix is an audit anchor, not a token that
  authorizes append or resume. W7b-b1 adds a distinct forced-restart profile:
  after ordinal 5 (the sixth segment) has completed, verified, synchronized,
  and returned all logical ownership, the supervisor sends real `SIGKILL` to
  that quiescent
  worker, requires wait status `-9`, publishes and re-reads the boundary, then
  completes the final six segments through a fresh Metal worker. The production
  gates perform real Metal work; separate pure supervisor/store and fake-worker
  protocol gates are deterministic model evidence.
  W7b-b2 separately exercises the production campaign-store publisher at 27
  ordered filesystem boundaries: 27 real writer `SIGKILL` cases, 27 controlled
  `EIO` cases, 27 controlled `ENOSPC` cases, and one clean control. Every case
  uses fresh roll-forward recovery twice and a fresh strict audit; the
  fixed-width report is checked by independent Zig and Python verifiers. This
  gate runs no model or GPU command, and its injected errors are not physical
  disk-failure evidence. Publication uses the production store writer; the
  bounded prepared roll-forward path is campaign reference code, not yet a
  general production recovery API.
  W7b-b3 adds a focused production-native cancellation-storm profile: in each
  of eight blocks of eight waves, two real host threads reach a ready barrier
  before one shared release store. The campaign retains 128 cancellations and
  64 capacity probes that submit no GPU command, and interleaves 16
  CPU-oracle-checked real Metal controls. The 208-record report closes 144/144
  admitted pins. The barrier proves the ready-before-release boundary, not
  simultaneous scheduling or execution, critical-section overlap, physical GPU
  parallelism, kernel cancellation, or performance.
  Process RSS is a host observation. Metal `currentAllocatedSize` is retained
  only as device-wide allocation context and is not GPU residency, owned
  memory, utilization, or physical-parallelism evidence. The forced restart is
  post-segment, not an in-flight command or physical-device fault. Remaining
  W7b-b work covers supervisor and in-flight process death, recovery-process
  interruption, adapter loss, physical quota/media/power faults, and native
  multi-filesystem replication.
  The first retained native machine result is the
  [2026-07-28 macOS arm64 wire](bench/results/native-metal-workload-report-macos-arm64-2026-07-28.bin)
  with its
  [capture manifest](bench/results/native-metal-workload-report-macos-arm64-2026-07-28.manifest.json);
  it is diagnostic evidence for that exact session, not a performance or
  replication claim. See
  [Native Workload Report](docs/NATIVE_WORKLOAD_REPORT.md) and
  [Native Metal Disruption Report](docs/NATIVE_METAL_DISRUPTION_REPORT.md),
  [Native Metal Cancellation-Storm Report](docs/NATIVE_METAL_CANCELLATION_STORM_REPORT.md),
  [Native Metal Segmented Soak Report](docs/NATIVE_METAL_SOAK_REPORT.md), and
  [Native Metal Process-Kill Recovery](docs/NATIVE_METAL_PROCESS_KILL_REPORT.md).
  The accelerator-independent publication/recovery slice is documented in the
  [Native Workload Store-Fault Report](docs/NATIVE_WORKLOAD_STORE_FAULT_REPORT.md).
- **Deterministic device selection.** A portable, pointer-free
  `DeviceCapabilityV1` fingerprint, canonical inventory, execution-plan-bound
  requirement, and selection receipt choose one compatible CPU or accelerator
  before resource or scheduler mutation. Selection rejects malformed or
  duplicate inventory, missing canonical operation/type/numerical profiles or
  lifecycle bits, unknown required physical ceilings, zero discovery epochs,
  receipt/inventory substitution, and undeclared fallback. Aggregate
  operator/type/numerical sets are derived from those profiles, preventing
  unsupported cross-product combinations. The
  receipt is decision evidence only: it grants no allocation, queue, dispatch,
  residency, or publication authority.
- **Source-bound device lifecycle observation.** Every native Metal context now
  installs `MTLCopyAllDevicesWithObserver`, verifies that the selected
  registry ID is present in the initial device set, and exposes a fixed-width
  snapshot from an ARC-owned observer state that never captures the
  malloc-owned context. `removal_requested`, `removed`, and
  `command_buffer_removed` enter a sticky source bitset whose effective state
  cannot be downgraded by a later weaker callback; they are not inferred from
  a generic API failure. A native admission lease linearizes new allocation,
  dispatch, and live `MTLDevice` property reads used by `deviceInfo` and
  `allocationLimits` against loss publication: work admitted first may settle,
  while later work and property access fail closed. The command-buffer
  source is published only from an unmodified native completion with exact
  status `5`, Metal command-buffer error domain `1`, and error code `11`,
  before any test-only overlay. The 40-byte `SourceCursorV1`, 280-byte
  `ObservationV1`, and 272-byte `TransitionReceiptV1` bind one native source
  instance and monotonically increasing source sequence to the prior present
  entry, canonical inventory root, and a capability- and policy-preserving
  successor in a newer discovery epoch. Sequence gaps are valid; the caller
  must durably and atomically commit the returned advanced cursor. The live
  adapter claims an exact native snapshot at most once. Its source-instance
  digest binds a 256-bit per-context nonce, observer-generation reset
  discriminator, registry ID, and stable device/placement identities rather
  than treating the 64-bit generation alone as durable freshness. Loss uses
  retained initial device identity instead of querying a dead device, and a
  source-instance mismatch fails closed. Fresh adoption requires a new
  inventory and exact initial sequence 1 and grants no recovery or migration.
  Absence or
  removal-requested becomes `unavailable`, while removed or exact code `11`
  becomes `lost`; normal selection excludes both. These hashes check
  composition and integrity, not authenticity or attestation. Synthetic
  injected loss remains an explicit evidence class and is never presented as
  a native failure.
- **Device-loss dispatch reconciliation Phase A.** The pointer-free
  `LossDispatchRetentionV1` (440 bytes),
  `LossDispatchReconciliationPlanV1` (240 bytes), and
  `LossDispatchReconciliationReceiptV1` (448 bytes) bind one exact active
  dispatch pin to a canonical `present → lost` transition and its eventual
  terminal settlement. Production accepts only the native
  `command_buffer_device_removed` status/domain/code tuple `5/1/11`; synthetic
  evidence remains structurally testable but cannot pass that gate. The
  coordinator exposes the exact retained lease, pin, intent, object set, and
  calls to the bound adapter without exposing its private Bank permit. The
  quarantine, pin, charge, buffers, and native command remain live until core
  settles the Bank pin first and the adapter exact-finalizes the same command,
  stores the receipt and replay tombstone, and clears the exact adapter slot.
  Lost confirmation retries from `settlement_pending` without another Bank release or native
  finalization. Allocation retirement remains a separate, later operation
  after the dispatch slot is gone. See
  [Device-loss Dispatch Reconciliation](docs/DEVICE_LOSS_DISPATCH_RECONCILIATION.md).
- **Device-loss dispatch callback retirement Phase B.** The pointer-free
  `LossDispatchCallbackRetentionV1` (464 bytes),
  `LossDispatchCallbackRetirementPlanV1` (240 bytes),
  `LossDispatchCallbackFenceV1` (408 bytes), and
  `LossDispatchCallbackRetirementReceiptV1` (504 bytes) cover the exact
  `pending`, `submission_ambiguous`, `completion_unknown`, and
  `invalid_completion` ownership states after accepted device loss. Native
  prepare detaches an ARC-owned callback gate without requiring callback exit
  while retaining the command record and its four command-held references.
  Core then consumes the Bank pin before the private adapter callback unlinks
  that exact native record and stores a replay tombstone. The dedicated
  `ownership_retired_after_device_loss` outcome has no output authority and is
  not success, terminal failure, cancellation, migration, reset, physical
  reclaim, or allocation retirement. Production requires exact native
  `removed_notification` or `command_buffer_device_removed` evidence and
  revalidates the same sticky source. A production 256-byte
  `MetalDispatchRetirementTelemetryV1` snapshot directly reports successful
  native prepare/commit transitions and replays, live prepared records,
  callback detachment, frozen completion/state/disposition/authorization
  buckets, exact native unlink/reference totals, retained tombstones,
  retirement generations, and sticky per-counter saturation. Its registry ID
  and context nonce prevent cross-context aggregation, and the read-only
  snapshot never grants retirement, completion, output, release, or migration
  authority. The build-isolated native matrix runs all
  four retained states through real Metal commands and real buffers and checks
  telemetry deltas at the native transition boundaries. Its
  pending case holds the completion handler before the callback gate; the other
  cases use a post-commit ambiguous disposition authenticated by the native
  record, a physical-success completion overlay that changes only
  `callback_fault` to publish a valid unknown projection, and an exact completed
  output-read rejection before caller memory is written.
  Synthetic injected loss authorizes each retirement. This is native
  ownership/lifetime conformance, not a reproduced physical removal, driver or
  hardware fault, successful-output recovery, performance, residency,
  migration, reset, or physical-reclaim result. See
  [Device-loss Dispatch Callback Retirement](docs/DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md).
- **Loss-bound GPU resource retirement.** A 544-byte pointer-free
  `LossRetirementPlanV1` binds one exact lost transition to the selected
  capability, allocation authority, live LeaseTree lease, leaf/object sets,
  recovery generation, and private adapter challenge. The production Metal
  path accepts only the exact previously consumed native snapshot plus the same
  retained sticky removal source, refuses active dispatch or quarantine, and
  releases exact `MTLBuffer` strong
  references without reading live device or buffer properties after loss. The
  existing coordinator keeps the Bank `FreePermit`, so logical bytes return
  only after every reference release succeeds and partial failure remains
  retryable. A 440-byte receipt binds the ordinary release terminal and forces
  physical-reclaim, output, migration, and reset authority to zero. Portable
  Zig/Python tests are deterministic models; the isolated native gate uses real
  buffers under an explicitly synthetic test-only loss permit and therefore
  does not claim a reproduced hardware removal. See
  [Device-loss Retirement V1](docs/DEVICE_LOSS_RETIREMENT.md).
- **Device allocation ownership contracts.** A fixed-storage allocator boundary
  replays the complete selection and a live quote for every canonical buffer,
  charges exact replayed adapter-quoted bytes through a `ResourceBank.ChildLease`
  before allocation, and returns a generation-fenced opaque object-set lease
  only after every allocation succeeds. Partial failure and synchronous
  cancellation free acquired objects before returning the charge. A failed
  free keeps the charge and returns retryable recovery authority. V1 binds the
  exact adapter instance and permits one materialized lease per context. The
  fake adapter proves deterministic failure/recovery semantics. A native Metal
  adapter now creates real direct Shared `MTLBuffer` objects, verifies the
  exact resource device and logical length, retains direct per-object
  `allocatedSize` observations, releases ownership before returning the
  charge, and proves generation-fenced slot reuse in a hard native gate.
  A separate additive LeaseTree coordinator now reserves the full allocation
  wave before native creation, retains the charge across rollback/recovery,
  releases under a private FreePermit, and composes with that same Metal
  adapter. The surrounding execution owner must externally serialize
  coordinator calls with every other mutation of the shared tree and
  publication sequence. Logical resource length is not relabelled as physical
  residency. An optional fixed-capacity dispatch registry now pins the exact
  LeaseTree object set before submission, rejects allocation release while a
  command is live, and consumes the private pin only after exact terminal
  validation. For Metal INT4, the adapter seals geometry, host lengths, and
  four role bindings into `MetalMatvecPreSubmitAttemptV1`, then issues a
  generation-fenced `MetalMatvecDispatchRequestV1`; that request root, not the
  raw attempt root, becomes the pin dispatch-request root. Core seals a
  `DispatchPinIntentV1` and reserves it through the adapter before Bank
  mutation, invokes exact abort on atomic acquisition failure, and revalidates
  callback/source boundaries.

  A valid preflight can submit a real command or take the pure
  `cancelled_before_submit` branch. A malformed attempt may inspect the native
  device and resources before authorizing `rejected_before_submit`, but it
  constructs and submits no command buffer. Cancellation performs no native
  inspection. Both pre-submit terminals carry zero
  submission/backend-completion/output roots and use the same core settlement:
  core consumes the private Bank pin, then a private callback atomically clears
  adapter state and records an exact replay tombstone. Public completion
  acknowledgement only verifies that tombstone.

  The submitted branch now provides **bounded two-slot Metal async completion
  delivery** per adapter. Each pointer-free, generation-fenced
  `MetalAsyncDispatchTicketV1` names its adapter-local queue slot; exact replay
  returns the same ticket without a second native submission, while a third
  distinct request is rejected before native mutation when both slots are
  occupied. Poll, wait, quarantine, terminal authorization, Bank settlement,
  and replay tombstones are isolated per slot, so either slot may complete and
  settle first. The native registry retains each command and its exact four
  buffers; output reads additionally require the exact command, submission
  binding, completed snapshot, and output role. Pending is nonterminal, leaves
  caller output unchanged, and retains its pin and charge. After an exact
  completed snapshot authorizes terminal evidence, core consumes that private
  Bank pin before the private settlement callback finalizes the exact native
  record and clears only its slot. Ambiguous submission, unknown or invalid
  completion, and terminal command errors first retain a sticky, nonterminal
  `MetalAsyncDispatchQuarantineV1`. One exact retained command-buffer `.error`
  can be explicitly bound to `MetalAsyncDispatchTerminalFailureV1` and core
  `terminal_failure` with no output root. Authorization retains the
  quarantine, pin, charge, buffers, and command; only the private post-Bank
  callback exact-finalizes that same native `.error` before clearing state.
  Ambiguous, unknown, and invalid completion remain sticky until the separate
  loss-authorized Phase B callback-retirement protocol succeeds. Two
  adapter-local evidence lanes are not a physical-parallelism claim, a global
  native queue-depth limit, device-loss recovery, or automatic migration.

  `ResourceBank.snapshotV4()` now exposes the optional pin registry's exact
  capacity, metadata bytes, active and peak slots, acquisition/completion and
  rejection counters, and reserved completion headroom without changing
  Snapshot V1–V3 meanings. Accepted pins reserve generation and per-root
  structural-revision headroom, so later mutations cannot strand completion
  near counter exhaustion and out-of-order release remains monotonic.

  The native allocation gate uses a real `MTLDevice` and real registry-owned
  buffers; its valid branch exercises separated submit, completion observation,
  exact output validation, post-Bank native finalization, and a CPU oracle. Its
  reject/cancel branches intentionally execute zero GPU commands. A second
  build-isolated bounded-pressure case materializes one eight-object lease with
  two disjoint four-buffer role sets, submits both commands, and observes two
  live native command records. After both commands complete, it deliberately
  settles B before A. Exact replays leave the record count at two, a third
  request rejects before native submission, both outputs match CPU oracles, and
  all commands, pins, and buffers return to zero. This proves bounded
  coexistence and out-of-order settlement isolation on the executing M1; it
  does not prove physical GPU parallelism or command-completion order. Portable Zig fake-adapter
  tests and the independent Python oracle remain deterministic contract models
  and execute no GPU work. Other build-isolated fault cases execute real
  commands to physical success, retain immutable completion facts separately,
  and apply one-shot test-only overlays to drive quarantine, reconciliation,
  Bank-first settlement retry, exact native finalization, and zero residual
  state. An exported-symbol gate requires the test hooks in the private fault
  archive and forbids them in the production archive. This is deterministic
  fault injection, not a physical hardware, driver, or device-loss failure.
- **Native Metal execution readiness.** On a native macOS Metal device, the
  focused hard gate executes one fixed synthetic 37x64 INT4 matrix-vector
  operation, exactly once across the entire gate, and checks its output against
  the CPU oracle. Command-buffer GPU timestamps, `currentAllocatedSize`, Metal
  registry identity, ownership closure, correctness, fallback state, and root
  composition are diagnostic readiness evidence only. They are not throughput,
  latency, or other performance claims. `recommendedMaxWorkingSetSize` is
  capacity context only; utilization, committed/resident bytes, queue depth,
  temperature, frequency, power, and energy stay explicitly `unsupported`.
  The same native adapter projects stable Metal device information into the
  common capability contract, binds one bounded local discovery epoch, and
  revalidates the selected fingerprint and registry identity from a fresh
  query immediately before its first Metal resource acquisition, with a
  second post-run device fence. Operation pipelines are lazy and independent;
  readiness requires the exact INT4 matrix-vector pipeline without depending
  on unrelated kernels. On the actual built-in M1 development host, the
  selected-device initial-membership snapshot remained unchanged while a real
  Metal command completed successfully. This proves observer installation,
  selected-device membership, real GPU execution, and the normal no-event path
  for that run. A native two-thread claim race also requires exactly one
  consumer and one stale result while leaving the snapshot readable; the
  machine cannot exercise a physical removal callback.
  Transition and error-path tests are deterministic synthetic/model evidence.
  Separately, the
  corrected tiled
  FP16 matrix multiplication path now matches a CPU oracle on asymmetric,
  partial-edge shapes and rejects zero, overflowing, short, or oversized
  buffers without mutating caller output.

The device milestone does not yet provide physical residency authority, a
hardware-removal callback campaign, fresh device selection, automatic
migration, dynamic queue scheduling beyond the fixed two-slot adapter,
multi-device or multi-GPU placement, additional GPU backends, native support
on a cross-compiled target, retained physical device telemetry, or performance
evidence. Direct Phase B and pin-registry counters do not fill those physical
evidence gaps. See the
[device capability and selection contract](docs/DEVICE_CAPABILITY_CONTRACT.md),
[device lifecycle observation contract](docs/DEVICE_LIFECYCLE.md),
[device-loss dispatch-reconciliation contract](docs/DEVICE_LOSS_DISPATCH_RECONCILIATION.md),
[device-loss dispatch callback-retirement contract](docs/DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md),
[device-loss retirement contract](docs/DEVICE_LOSS_RETIREMENT.md),
[LeaseTree device-allocation contract](docs/LEASE_TREE_DEVICE_ALLOCATION.md),
[device dispatch-lifetime contract](docs/DEVICE_DISPATCH_LIFETIME.md), and
[native Metal allocation adapter](docs/NATIVE_METAL_ALLOCATION.md).

Run the fail-closed native readiness, allocation, production workload-report,
controlled-disruption, cancellation-storm, segmented-soak, forced-process-restart,
fault-settlement, and correctness gates serially on macOS with:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Add `-Dnative-metal-report-output=PATH` to the focused W6b report gate, or
`-Dnative-metal-suite-report-output=PATH` to the serialized suite, only when
an addressable W6b raw wire should be retained after complete independent
verification. The two W6b retention options are mutually exclusive in one
build invocation. Use `-Dnative-metal-disruption-report-output=PATH` with the
focused W7a gate to retain its independently verified raw wire.

Run the focused W7b-b3 cancellation-storm gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-cancellation-storm-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-cancellation-storm-report-output=PATH
```

It retains 128 zero-command cancel-before-submit outcomes, 64 zero-command
capacity probes, and 16 real Metal controls across paired real host threads.
Omit the output option for an ephemeral verified wire. See the
[Native Metal Cancellation-Storm Report](docs/NATIVE_METAL_CANCELLATION_STORM_REPORT.md).

Run W7b-a
directly, with optional verified-store retention, using:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-soak-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-soak-output-dir=PATH
```

Omit `-Dnative-metal-soak-output-dir` when no retained store is needed. The
focused native gate takes at least 60 seconds by schedule; the separate
`native-metal-soak-report-pure-test` checks the supervisor, canonical campaign
codec, store, and offline verifier without claiming native GPU execution.
Both W7b segmented hard campaigns close their writer and verify the complete
store again in a fresh process before an ephemeral store is deleted.

Run the separate W7b-b1 post-segment process-kill profile with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-process-kill-output-dir=PATH
```

This profile executes the same 1,200 real Metal commands, sends a real
`SIGKILL` to the first worker after its sixth verified segment, re-reads the
durable prefix, and continues in a fresh Metal process. It does not kill an
in-flight command or model physical device failure. See the
[Native Metal Process-Kill Recovery Report](docs/NATIVE_METAL_PROCESS_KILL_REPORT.md).

Run the accelerator-independent POSIX-host W7b-b2 campaign-store fault gate
with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2 \
  -Dnative-workload-store-fault-output=PATH
```

Omit the output option for an ephemeral independently verified report. The
`SIGKILL` deaths and host filesystem calls are real; `EIO` and `ENOSPC` are
controlled software injection. See the
[Native Workload Store-Fault Report](docs/NATIVE_WORKLOAD_STORE_FAULT_REPORT.md).

## What you can build with it

Glacier Engine is useful for AI infrastructure work where a result alone is not
enough:

- local inference experiments with explicit model and memory layouts;
- agent or batch systems that need fair, bounded scheduling;
- provider gateways that need token, retry, cancellation, and cost accounting;
- durable audit records for AI requests without storing prompt text in core
  evidence structures;
- fault-injection research for KV, output, RNG, and journal publication;
- media preprocessing and streaming prototypes that need exact source ranges,
  provenance, and ordered output state;
- generative-media runtime experiments that need terminal-state identity,
  cancellation-safe output, and independently verifiable provenance;
- restartable media pipelines that need typed generated results and their exact
  encoded image/audio/video deliverables to advance together;
- model-family and backend experiments that need one runtime contract across
  artifacts, resources, scheduling, state, streaming, publication, and
  evidence; and
- reproducible runtime, kernel, format, and verification research.

The provider context fixtures demonstrate a logical count change from 440 to
250 tokens and a reservation change from 490 to 300. Those are deterministic
fixture results—not proof of lower billed tokens for every provider or workload.

## Architecture at a glance

```text
request
  │
  ├─ ResourceBank ── exact claim, receipt, LeaseTree
  │
  ├─ LaneWeave ───── admission, fairness, service permit
  │
  ├─ execution ───── CPU / Metal, prepared image, paged KV
  │
  └─ publication ─── KV + RNG + sampler + output (one transaction)
                         │
                         ├─ portable receipts and replay roots
                         └─ ContinuationCapsule (typed external object roots)
                                  │
                                  ├─ bounded tenant-scoped object resolver
                                  ├─ canonical tenant bundle
                                  └─ bounded in-memory object store
                                     ├─ lease, quarantine, repair
                                     ├─ retire + collection plan
                                     └─ sweep prepare/abort + atomic commit
                                        └─ fixed body/footer evidence record
                                           └─ pure anchored stream classifier
                                              └─ scoped writer/repair model
                                                 └─ locked real-file adapter
                                                    └─ exact preview publication
                                                       └─ durable payload plan
                                                          └─ copy-on-write apply

provider request
  │
  ├─ ContextPack ─── lossless mapping and token reconciliation
  ├─ Gateway ─────── coalescing, cancellation, usage settlement
  ├─ CostJournal ─── crash-recoverable append and replay
  └─ EvidenceJoin ── compact root over gateway, transport, and cost evidence

media object
  │
  ├─ MediaObject ─── fixed image/audio/video content + policy identity
  ├─ DecodePlan ───── sealed decoder + representation + exact bounds
  ├─ fixture decode ─ caller-owned RGB / PCM / intra-frame bytes + mappings
  ├─ TransformPlan ── crop/nearest/tile, mix/decimate, keyframe selection
  ├─ MediaTimeline ─ checked rational positions + explicit transform events
  ├─ ResourceBank ─── exact parent admission + bounded LeaseTree
  └─ MediaRuntimeLease
       ├─ prepare ─── charge source/mapping/scratch/output before use
       ├─ abort ───── scrub provisional bytes + retire every allocation
       ├─ commit ──── output + resource root + timeline (one boundary)
       └─ retire ──── drop provisional leases; retain output until release
             │
             └─ MediaStreamRuntime
                  ├─ append ── exact contiguous target interval
                  ├─ retain ── one output lease per committed chunk
                  └─ chain ─── portable predecessor-bound chunk receipts
                       │
                       └─ MediaStreamContinuation
                            ├─ checkpoint ─ fixed state + output plan
                            ├─ reacquire ── charge before materialize
                            ├─ resume ───── next chunk in a fresh process
                            └─ CheckpointSet
                                 ├─ bundle ── all retained media outputs
                                 └─ select ── atomic generation root
```

See [Architecture](docs/ARCHITECTURE.md) for the component map and
[Glacier AI Runtime Roadmap](docs/AI_RUNTIME_ROADMAP.md) for the full runtime
planes, model-family adapter map, promotion gates, and contributor sequence.
The [Platform Portability](docs/PLATFORM_PORTABILITY.md) ledger separates
compile evidence from native, recovery, accelerator, and packaging support.

## Quick start

Requirements:

- Zig 0.15.0 or newer;
- macOS for the retained native development-host workflow; Linux, Windows, and
  FreeBSD currently have cross-build evidence only;
- Python 3 for the independent evidence tests;
- Rust is optional and needed only for `contract-rust-test`.

Compile-only core probes also exist for additional targets. They are not native
support claims; see [Platform Portability](docs/PLATFORM_PORTABILITY.md).

Run the bounded contributor check first. It uses only repository fixtures,
keeps compiler caches and build products in a private temporary workspace, and
does not download a model or contact a provider:

```sh
tools/verify.sh
```

Every gate is reported as `PASS`, `FAIL`, or `SKIP` with a reason. The default
quick profile verifies formatting, public-document policy, package imports, and
the Zig/C/C++/Python contract chain. Use `tools/verify.sh full` to add the broad
native ReleaseSafe and Python suites plus the optional Rust gate.

Build the portable CLI and run one deterministic, model-free publication demo:

```sh
zig build -Doptimize=ReleaseSafe -Dmetal=false
./zig-out/bin/glacier --version

zig build lane-publication-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Build the experimental C contract library and verify the same canonical chain
from Zig, C, and Python without retaining a compiler cache:

```sh
tools/zig-with-ephemeral-cache.sh build contract-c \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
python3 examples/interop/python_verify.py

tools/zig-with-ephemeral-cache.sh build contract-interop-test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

Inspect the retained reference compatibility registry as deterministic JSON:

```sh
tools/zig-with-ephemeral-cache.sh build runtime-support-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

Inspect one 712-byte provider evidence join as deterministic JSON without raw
prompt, payload, response, or credential bytes:

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --join path/to/provider.join
```

This command verifies only the outer framing and checksum. The rendered lengths,
sequence, event counts, and named digests remain self-asserted; nested
composition, authenticity, provider execution, usage, cost, and authority are
not established. See
[Provider Evidence Inspector](docs/PROVIDER_EVIDENCE_INSPECTOR.md).

The C ABI is a narrow verifier and support-query surface, not a stable
inference SDK. See
[Language interop](docs/LANGUAGE_INTEROP.md) for C, Python, and dependency-free
Rust instructions, and
[Runtime Support Registry and Inspector](docs/RUNTIME_SUPPORT_INSPECTOR.md) for
query semantics, fixture authoring, and explicit nonclaims.

Run the broad verification suites when working across the whole repository:

```sh
tools/verify.sh full
```

The full profile can use substantially more temporary compiler storage than the
quick profile, but removes its validated workspace on normal exit. Use
`tools/zig-with-ephemeral-cache.sh` for any other focused Zig step when
incremental cache retention is not worth the disk space. For model conversion,
generation, and the complete demo index, continue with the
[Quickstart guide](docs/QUICKSTART.md).

Zig dependency consumers can import the runtime or core module without taking
a dependency on the CLI, demos, or benchmark executables:

```zig
const glacier_dep = b.dependency("glacier_engine", .{
    .target = target,
    .optimize = optimize,
});
app.root_module.addImport("glacier", glacier_dep.module("glacier"));
// Or use glacier_dep.module("glacier_core") for the core surface.
```

The `glacier` module propagates its target-specific libc, AArch64 INT4, and
optional macOS Metal link requirements. The `glacier_core` module retains the
hardware-independent surface without those native backend dependencies.

## Current feature map

| Area | Available today | Next public milestone |
| --- | --- | --- |
| AI runtime | CPU execution, an optional macOS Metal kernel path, prepared `.glrt` images, typed family/operation contracts, a Common Model Contract bridge for eligible serial pre-tokenized text request profiles, exact total-versus-request logical claim projection for shared read-only artifact residency, V2 boundary evidence, a single-seal fixed-length terminal `ResultEnvelopeV1`, canonical non-terminal prepared-state capture, same-process exact-current-boundary rebind, canonical successor evidence, receipt-funded restored activation at sequence `N`, and an experimental fresh-process handoff with a five-object restart archive, source-live/source-exited/terminal selector chain, exclusive lease, one-shot target grant, and terminal-semantic oracle comparison, plus exact admission/scheduling/publication, continuation, provider and media planes, an experimental allocation-free C verifier, and a deterministic eight-profile retained-reference compatibility inspector | Close the source-before-generation-two recovery gap; add an idempotent durable result sink and acknowledged progress generation; extend ownership/accounting coverage, verify raw-text tokenizer identity, add production fixtures, native multi-OS validation, and broader production device execution |
| Language interop | Installed experimental C header plus shared/static contract libraries; source and staged-install C consumers; C++ linkage check; standard-library Python `ctypes`; dependency-free Rust `extern "C"` gate; fixed profile enumeration and support-mask queries | Retained symbol/layout gates, native multi-OS consumers, stability policy, packages, then model/session execution bindings |
| Model families | Text-generation prototype, cache-bound vision/audio/temporal-video embedding fixtures with scheduler-owned final-result publication, stateful transcript and VFR video restart, exact word/speaker annotations, typed video segments, canonical merge timelines, exact audio/video result links, shared stateless/stateful lifecycles, exact latent continuation, atomic generated-image publication, restartable generated-audio publication, acknowledged generated-video manifests, atomic cross-modality generated-output checkpoints, exact encoded-payload archive composition, bounded multi-output image/audio/video registry continuity, canonical typed producer admission, exact deterministic producer-transition replay, one process-local typed tool transaction, a durable POSIX external-action handoff store, and a same-process generation-fenced fake dispatch/status authority for retained reference profiles | Generic embeddings/reranking/classification, richer language/punctuation and ambiguous-speaker policy, production generative-media adapters, multimodal fusion, OS-isolated real-credential adapters, live tools and agent loops, retrieval, time-series, graph/scientific, routed and adapter families |
| State | Token transactions, canonical prepared-text state images with detached materialization, same-process retained-authority rebind, pointer-free successor evidence, receipt-funded restored activation with a global publication sequence base, and experimental durable prepared-text selection, exact source exit, exclusive fresh-process activation, three-generation terminal lineage, and semantic oracle comparison; plus capsule, resolver, bundle, tenant store, durable payload recovery, ownership/KV remap, fixed runtime state, model-free two-process resume, and a seven-phase atomic checkpoint root switch | Pre-generation-two source recovery, acknowledged target progress and idempotent external delivery, native Linux recovery, Win32 durable files, device-resident continuation, and durable lifecycle metadata |
| Scheduling | Exact admission, deterministic weighted QoS, one fixed and 32 generated bounded mixed-media open-loop pressure cases, a separately versioned finite-source deterministic closed-loop campaign with FIFO next-step replacement and exact replay, final-quantum image/audio/video media transactions, deterministic exact-signature shrinking, one mixed typed vision/audio/temporal-video workload with typed result publication under the scheduler-owned receipt, and one atomic process-local typed tool transaction profile | Family-aware batching, preemption, multi-device placement, provider/stateful/live-tool workload profiles, and broader multi-tenant campaigns |
| Device runtime | Portable capability selection, Device-loss Observation V1, command-specific Device-loss Dispatch Reconciliation Phase A, callback-safe Dispatch Callback Retirement Phase B, and loss-bound quiesced-resource retirement; canonical present-to-newer-unavailable/lost transitions; fixed 440/240/448-byte Phase A evidence and 464/240/408/504-byte Phase B retention/plan/fence/receipt evidence; native-only production authorization with same-source sticky-loss revalidation; exact active-pin binding without exposing the Bank permit; ARC-owned callback-gate detachment without a callback-exit prerequisite; dedicated zero-output `ownership_retired_after_device_loss`; Bank-first settlement, exact native unlink, replay tombstones, confirmation retry, a production 256-byte identity-bound direct retirement-telemetry snapshot, and additive pin-aware SnapshotV4 with completion headroom; real Metal commands and buffers under CPU-oracle gates; build-isolated synthetic loss/error and held-callback controls with production-symbol isolation; adapter-quoted allocation, exact charge-before-allocate accounting, ChildLease and additive LeaseTree ownership, bounded object-set pins, two isolated async slots with exact replay and out-of-order settlement, sticky quarantine, pre-submit rejection/cancellation, direct Metal length/`allocatedSize` observation, generation-fenced reuse, sibling isolation, and asymmetric FP16 tiled-matmul correctness | Retain requested/removed callback artifacts on removable hardware; add fresh selection and explicit migration policy; then dynamic multi-device queue scheduling, separate physical residency and direct physical telemetry, additional GPU backends, retained native OS/device matrices, and performance evidence under declared campaigns |
| Providers | Context packing, gateway, transport harness, settlement and cost wires, a read-only outer-envelope inspector, and a pointer-free ActionOutbox adapter contract exercised by a same-process fake authority whose portable values contain no credentials or payload bytes | Pluggable live adapters outside the credential-free core, OS-isolated credential handling, and optional caller-supplied full-composition inspection |
| Evidence | Hash-chained events, independent Python verifiers, a scheduled-media execution sidecar with exact receipt/output replay, compact provider evidence join, an experimental read-only provider outer-envelope inspector, a generated-media inspector with exact optional format-sidecar validation, independent ActionOutbox dispatch/status model tests with live canonical Zig-report parity, a fixed native-observation contract with availability, stable source identity, per-event provenance, unavailable-reason identity, per-record sample-clock identity, and value-clock identity for present time metrics, a versioned allocation-free W6a raw-record/summary/closure report codec with deterministic reference runner and independent recomputation, a W6b production-native macOS Metal producer with one retained independently verified 20-record machine result after zero-ownership closure, a W7a finite controlled-disruption producer with 250 ordered records and 100 correctness-gated native Metal commands, the W7b-b3 208-record native cancellation-storm profile with 16 correctness-gated controls, the W7b-a canonical segmented-soak campaign, the W7b-b1 sealed post-segment process-kill profile, and the W7b-b2 production-publisher/reference-recovery 81-fault/one-control campaign with independent binary-report verification | Token transaction inspector, provider nested-composition workflow, privacy-safe export and retention policy, retained native campaign matrices, remaining W7b-b supervisor/in-flight/recovery-process and physical disruption evidence, direct CPU/GPU utilization, residency, thermal, frequency, power, and energy adapters, and native multi-OS evidence |
| Multimodal | Shared identity/timeline, bounded decode/transforms, scheduler-coupled final-quantum image/audio/video transactions and typed perception results, per-buffer ownership, chunk chains, six-object input checkpoints, post-restore generation three, image processor progress, overlapping audio context plus fresh-process transcript continuation, exact word/speaker annotation restart, explicit VFR windows plus stateful video restart, typed segments and deterministic merge timelines, exact audio/transcript-video result links, synchronized watermark, restore-before-visible cache ownership, generated-image publication, acknowledged generated-PCM/video publication, one atomic generated image/audio/video checkpoint, one exact eight-object encoded-payload archive, a bounded multi-output registry, typed producer/raw-output admission, host replay of exact deterministic source-model/materializer transitions, validated bounded PNG/WAVE/APNG profiles, and an integrated additive format-conformance sidecar with a maximum-entry repeated-modality composed oracle | External video-timeline normalization, production encoder/container adapters and broader profiles, richer language/punctuation and overlapping-speaker policy, native Linux/Windows execution and power-loss campaigns, additional model/materializer profiles, and authorized physical playback/display and quality evidence |
| Platforms | Native macOS development-host evidence, including the 49-death ActionOutbox POSIX recovery campaign, the 27-death/54-injected-error workload-store production-publisher/reference-recovery campaign, and on-demand Metal diagnostic-readiness, allocation-ownership, production workload-report, controlled-disruption, cancellation-storm, segmented-soak, and post-segment process-kill gates; affected-path verification with target-specific core/CPU/durable/device/host-tool compile profiles, a complete consumer compile closure for shared APIs, full per-target fallback, and one shared DAG per selected target; full opt-in production, benchmark/diagnostic, and test-compile gates for Linux x86_64/AArch64 musl, Windows x86_64 GNU, and FreeBSD x86_64; a CLI-only default install plus opt-in benchmark installation; a bounded Linux available-memory adapter implementation with native retention still pending; exported package modules; compile-time adapter-availability inventory; read-only POSIX/Windows model-file mapping; portable process-ID and forced-termination fixtures; compile-only core probes for Android and iOS AArch64 | Separate the transitional core from durable POSIX authority and turn verification profiles into distributable products; replicate workload-store recovery natively on POSIX filesystems; run native Linux/Windows/FreeBSD CPU, observer, mapping, recovery, telemetry, and packaging gates; implement the Windows durable-file adapter; then add mobile and reduced edge profiles |
| Runtime Workload Lab | W0 deterministic mixed-media open-loop conformance, W1 scheduler-coupled media execution, the W2 four-seed/32-case generated corpus, W3 finite-source closed-loop conformance, W4a mixed typed-perception conformance, the W4b-a typed tool transaction, W4b-b ActionOutbox record recovery, the W4b-c durable POSIX store, W4b-d generation-fenced fake dispatch/status, W5a native observation, a bounded Linux host-source implementation, native macOS Metal readiness, pinned-allocation and bounded two-slot pressure gates, the portable W6a raw-record/summary/closure foundation, the W6b production-native 20-request Metal report producer, W7a finite controlled disruption, W7b-b3 paired-thread concurrent-caller cancellation, W7b-a bounded segmented soak, W7b-b1 quiescent-worker process kill, and the W7b-b2 production-publisher/reference-recovery campaign-store process-death/error roll-forward cover overload, fairness, timeout, cancellation, turnover, typed publication/effect delivery, uncertain external handoff, fenced safe retry, deterministic crash modeling, explicit machine-state availability, fail-closed pre-run admission, retained post-run contamination, strict unavailable-not-zero behavior, independently recomputed workload evidence, correctness-gated accelerator dispatches, clean and forced worker restart, canonical checkpoint publication/offline audit, and controlled recovery without performance or physical-residency claims | Complete W7b-b supervisor/in-flight/recovery-process and physical device/storage/power campaigns; retain native Linux and broader accelerator campaign matrices; add trustworthy direct CPU/GPU metrics where platform sources exist; then W8 multi-OS replication |
| Tooling | Zig build, exported `glacier`/`glacier_core` package modules, deterministic demos, benchmark harnesses, five domain compile profiles plus one complete consumer-closure profile, CLI-only default install, and opt-in benchmark installation | Distributable product profiles, installer, stable library API, and simpler fixture workflow |

The R1d prepared-text path binds a request-profile manifest, not a stable
package identity. Shared read-only residency is logical accounting rather than
physical RSS evidence, and its token-domain, configuration, and license roots
are caller assertions. For a completed fixed-length run, `SessionV3` seals one
terminal `ResultEnvelopeV1` against the actual request-charged receipt,
canonical little-endian `u32` output root, and V2 boundary/source mapping, then
advances its result state exactly once from zero to one before explicit
retirement. The `deinit` safety path may instead abandon terminal evidence while
closing the adopted lifecycle.
Retained Zig and independent Python evidence share exact projected
artifact/plan/residency/result and terminal-root goldens, including Receipt
integrity and adversarial substitutions.

R1e adds a canonical non-terminal state image after at least one published
token. `SessionV3.captureCheckpointV1` binds the independently retained
plan/boundary/transcript roots to exact output, RNG, sampling, and committed
contiguous-KV bytes. The verifier reconstructs both the full logical KV root
and the incremental publication state commitment. A fresh detached allocation
round-trips those bytes with zeroed slack, and a shared Zig/Python bit-pattern
golden rejects mutation across the entire image.

R1f adds `SessionV3.rebindCheckpointV1`. It rematerializes a verified image
with the original Session's allocator and replaces only concrete KV/output
backing at the same current `N > 0` non-terminal boundary. The embedded
publication coordinator, Scheduler, ResourceBank, receipt, request epoch,
sequence, transcript/result state, cache-field address, and scalar-field
addresses remain unchanged. The operation neither transfers authority nor
creates another Session. Previously borrowed output/cache views and row marks
are invalid after success.

R1g adds `SessionV3.captureSuccessorArtifactsV1`, a read-only bridge from that
same checkpoint boundary to the existing 768-byte Common Model Contract
`ExecutionPlanV1`, its canonical 256-byte residency binding, and a new fixed
512-byte transcript segment. The successor plan starts at `N`, identifies the
logical KV payload and source-plan lineage, and binds a canonical target
ownership intent. The Session verifies its complete source context before and
after capture, and Zig/Python evidence rejects every-byte mutation and coherent
foreign substitution. Ownership intent is evidence only: it is not a target
receipt, restored admission, authority handoff, or runnable successor Session.

R1h-a adds `prepareRestoredAdmissionV1`. It consumes those exact records
against a genuinely fresh LeaseTree-enabled Scheduler/Bank, acquires the
intended admission and receipt, opens a queue-free receipt-funded tree and
zero-current-claim tenant scope, restores publication sequence `N`, and seeds
the target Bank publication-permit fence from source generation `G`. The
pending adoption barrier remains live, so the bootstrap cannot receive service
before checkpoint materialization.

R1h-b adds `SessionV3.startRestoredV1`. It reserves one funded ownership node
for every request-local byte class before allocator materialization, restores
and revalidates KV/output/RNG state, and commits the funded allocation batch
with the pending Scheduler adoption. Token-publication ABI v2 carries
`sequence_base = N`, so the first target transaction remains global sequence
`N` while target-local completed service starts at zero; the first target Bank
permit is `G + 1`. A no-service close barrier frees concrete backing and the
funded node before atomically closing the publication session, tree, and parent
receipt. The retained synthetic-model integration matches one restored
next-token transition, output, logical KV, RNG, and sampling state against its
uninterrupted reference, then returns Scheduler and Bank usage to zero.

The durable handoff slice composes those process-local contracts with a
canonical restart manifest and selector authority. The source holds generation
one under an address-stable live grant, captures a five-object restart archive,
commits an exact publication handoff, and selects generation two only after its
Scheduler lane, Bank receipt, and publication binding are closed. A different
process opens that source-exited generation under the exclusive lease, creates
one live lease-backed activation grant at a time, restores at `N`, and retains
the active grant until it selects generation three with the exact
receipt-independent terminal semantic. A released non-terminal grant permits a
deterministic retry. The retained demo runs baseline, source, and target as
separate subprocesses, rejects a concurrent lease/grant, compares the resumed
terminal semantic with the already-retired baseline oracle, and returns source
and target logical ownership to zero.

The path still accepts pre-tokenized input only, does not cover every V1-valid
request shape, and does not execute or attest a raw-text tokenizer, provide
stable package/license byte identity, publish to a durable external result
sink, recover a source crash before generation-two selection, suppress replay
after a target crash before generation three, support early EOS or
fewer-than-admitted outputs, provide concurrent Session mutation, execute the
handoff on GPU, or establish production native performance. The durable adapter
for this path is POSIX-only; Windows durable files remain roadmap work. An
idempotent sink keyed by request and global sequence is required for external
effects because a fresh target may replay from `N` while generation two remains
selected. The detached R1e payload cannot publish another token by itself; R1f
installs it only through the original address-stable live Session. R1g supplies
exact successor evidence, R1h-a creates a barrier-held target bootstrap, and
R1h-b activates it; the durable selector/lease/grant layer supplies the
fresh-process authority composition. The bound-plan bridge remains an
experimental Zig/direct API
without a fixed bound-plan wire, projected C verifier, or `.generate_sequence`
support record; cross-language ABI parity is future work.

Detailed status, acceptance gates, and contributor-sized work items live in the
[roadmap](docs/ROADMAP.md).

## Choose a contribution

You do not need AI kernel experience to contribute. Useful work includes Zig,
Python, device backends, Linux/Windows/mobile portability, property tests, fault
injection, documentation, format tooling, visualizers, examples, and
reproducibility.

Good starting points:

1. Read [Contributing](docs/CONTRIBUTING.md) and pick a small item from
   [Contributor projects](docs/PROJECTS.md).
2. Open a **Claim a contributor slice** issue describing one mergeable outcome
   and its acceptance command.
3. Submit a focused pull request. Draft pull requests are welcome.

Maintainers will help reduce an ambitious idea into an independently mergeable
slice. Correctness fixes, clearer explanations, and rejection-path tests are as
valuable as new features.

## Documentation

- [Quickstart](docs/QUICKSTART.md)
- [Language interop](docs/LANGUAGE_INTEROP.md)
- [Runtime support registry and inspector](docs/RUNTIME_SUPPORT_INSPECTOR.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Glacier AI Runtime roadmap](docs/AI_RUNTIME_ROADMAP.md)
- [Platform portability](docs/PLATFORM_PORTABILITY.md)
- [Device capability and selection](docs/DEVICE_CAPABILITY_CONTRACT.md)
- [Device allocation lease](docs/DEVICE_ALLOCATION_LEASE.md)
- [Device lifecycle observation](docs/DEVICE_LIFECYCLE.md)
- [Device-loss dispatch reconciliation](docs/DEVICE_LOSS_DISPATCH_RECONCILIATION.md)
- [Device-loss dispatch callback retirement](docs/DEVICE_LOSS_DISPATCH_CALLBACK_RETIREMENT.md)
- [Device-loss retirement](docs/DEVICE_LOSS_RETIREMENT.md)
- [Device dispatch lifetime](docs/DEVICE_DISPATCH_LIFETIME.md)
- [Native Metal allocation adapter](docs/NATIVE_METAL_ALLOCATION.md)
- [Contributor projects](docs/PROJECTS.md)
- [Benchmark and evidence guide](docs/BENCHMARKS.md)
- [Native observation contract and runner](docs/NATIVE_OBSERVATION.md)
- [Native workload report](docs/NATIVE_WORKLOAD_REPORT.md)
- [Native Metal disruption report](docs/NATIVE_METAL_DISRUPTION_REPORT.md)
- [Native Metal segmented soak report](docs/NATIVE_METAL_SOAK_REPORT.md)
- [Deterministic workload pressure](docs/WORKLOAD_PRESSURE.md)
- [Scheduled media pressure](docs/SCHEDULED_MEDIA_PRESSURE.md)
- [Generated workload corpus](docs/GENERATED_WORKLOAD_CORPUS.md)
- [Deterministic closed-loop workload](docs/DETERMINISTIC_CLOSED_LOOP.md)
- [Typed workload conformance](docs/TYPED_WORKLOAD_CONFORMANCE.md)
- [Typed tool workload](docs/TYPED_TOOL_WORKLOAD.md)
- [ActionOutbox protocol](docs/ACTION_OUTBOX.md)
- [Runtime Workload Lab](docs/RUNTIME_WORKLOAD_LAB.md)
- [Evidence policy](docs/EVIDENCE_POLICY.md)
- [Model format](docs/FORMAT_SPEC.md)
- [Native runtime image](docs/RUNTIME_IMAGE.md)
- [Prepared text session](docs/PREPARED_TEXT_SESSION.md)
- [Prepared text checkpoint](docs/PREPARED_TEXT_CHECKPOINT.md)
- [Prepared text successor evidence](docs/PREPARED_TEXT_SUCCESSOR.md)
- [Prepared text restore admission](docs/PREPARED_TEXT_RESTORE_ADMISSION.md)
- [Durable prepared-text handoff](docs/PREPARED_TEXT_DURABLE_HANDOFF.md)
- [Hierarchical media buffer ownership](docs/MEDIA_RUNTIME_LEASE.md)
- [Bounded media stream runtime](docs/MEDIA_STREAM_RUNTIME.md)
- [Media stream continuation](docs/MEDIA_STREAM_CONTINUATION.md)
- [Atomic media stream checkpoint sets](docs/MEDIA_STREAM_CHECKPOINT_SET.md)
- [Multimodal processor and cache state](docs/MEDIA_PROCESSOR_STATE.md)
- [Materialized multimodal processor caches](docs/MEDIA_PROCESSOR_CACHE.md)
- [Typed model-family contracts and vision adapter](docs/MODEL_FAMILY_ADAPTER.md)
- [Typed audio-window encoder adapter](docs/AUDIO_WINDOW_ADAPTER.md)
- [Overlap-safe audio transcript adapter](docs/AUDIO_TRANSCRIPT_ADAPTER.md)
- [Typed temporal-video encoder adapter](docs/TEMPORAL_VIDEO_ADAPTER.md)
- [Typed video-segment adapter](docs/VIDEO_SEGMENT_ADAPTER.md)
- [Canonical video-segment timeline](docs/VIDEO_SEGMENT_TIMELINE.md)
- [Exact audio/video result link](docs/AUDIO_VIDEO_RESULT_LINK.md)
- [Stateful audio transcript continuation](docs/AUDIO_TRANSCRIPT_CONTINUATION.md)
- [Stateful VFR video-model continuation](docs/STATEFUL_VIDEO_CONTINUATION.md)
- [Generated-image publication](docs/GENERATED_IMAGE_PUBLICATION.md)
- [Generated-audio publication and playback acknowledgement](docs/GENERATED_AUDIO_PLAYBACK.md)
- [Generated-video manifest and display acknowledgement](docs/GENERATED_VIDEO_DISPLAY.md)
- [Atomic generated-media checkpoints](docs/GENERATED_MEDIA_CHECKPOINT.md)
- [Generated-media encoded payload archive](docs/GENERATED_MEDIA_PAYLOAD_ARCHIVE.md)
- [Bounded generated-media output registry](docs/GENERATED_MEDIA_OUTPUT_REGISTRY.md)
- [Canonical generated-media producer admission](docs/GENERATED_MEDIA_PRODUCER_ADMISSION.md)
- [Host-verified generated-media producer transitions](docs/GENERATED_MEDIA_PRODUCER_TRANSITION.md)
- [Generated-media external-format profiles and evidence](docs/GENERATED_MEDIA_EXTERNAL_FORMATS.md)
- [Exact speech annotation publication](docs/SPEECH_ANNOTATION_PUBLICATION.md)
- [Stateful model adapter and latent-step fixture](docs/STATEFUL_MODEL_ADAPTER.md)
- [Stateful model continuation](docs/STATEFUL_MODEL_CONTINUATION.md)
- [Paging contract](docs/PAGING.md)
- [Continuation capsule](docs/CONTINUATION_CAPSULE.md)
- [Continuation object resolver](docs/CONTINUATION_OBJECT_RESOLVER.md)
- [Continuation bundle](docs/CONTINUATION_BUNDLE.md)
- [Continuation object store](docs/CONTINUATION_OBJECT_STORE.md)
- [Continuation object lifecycle](docs/CONTINUATION_OBJECT_LIFECYCLE.md)
- [Continuation object collection plan](docs/CONTINUATION_OBJECT_COLLECTION.md)
- [Continuation object sweep journal](docs/CONTINUATION_OBJECT_SWEEP.md)
- [Continuation object sweep commit](docs/CONTINUATION_OBJECT_SWEEP_COMMIT.md)
- [Continuation object sweep record](docs/CONTINUATION_OBJECT_SWEEP_RECORD.md)
- [Continuation object sweep writer](docs/CONTINUATION_OBJECT_SWEEP_WRITER.md)
- [Continuation object sweep file adapter](docs/CONTINUATION_OBJECT_SWEEP_FILE.md)
- [Continuation object payload file](docs/CONTINUATION_OBJECT_PAYLOAD_FILE.md)
- [Continuation ownership restore](docs/CONTINUATION_OWNERSHIP_RESTORE.md)
- [Continuation paged-KV restore](docs/CONTINUATION_PAGED_KV_RESTORE.md)
- [Continuation live restart](docs/CONTINUATION_LIVE_RESTART.md)
- [Continuation checkpoint file](docs/CONTINUATION_CHECKPOINT_FILE.md)
- [Shared media contract](docs/MEDIA_CONTRACT.md)
- [Bounded media decode fixtures](docs/MEDIA_DECODE_FIXTURES.md)
- [Deterministic media transforms](docs/MEDIA_TRANSFORMS.md)
- [Media runtime transaction](docs/MEDIA_RUNTIME_TXN.md)
- [Multimodal roadmap](docs/MULTIMODAL_ROADMAP.md)
- [Glossary](docs/GLOSSARY.md)

Research tracks are documented separately in
[Prism Decode](docs/PRISM_DECODE.md) and
[Sealed DecodePlan](docs/SEALED_DECODE_PLAN.md). They are proposals with explicit
promotion and stop gates, not production promises.

## Project principles

1. Fail closed when identity, ownership, capacity, or evidence is ambiguous.
2. Publish AI-visible state atomically.
3. Keep logical accounting separate from physical measurements.
4. Bind claims to reproducible artifacts and honest scope boundaries.
5. Design large ideas as small contributions that can merge independently.

## Community and support

Questions and design discussions belong in GitHub issues. Please read
[Support](SUPPORT.md), [Governance](GOVERNANCE.md), and the
[Code of Conduct](CODE_OF_CONDUCT.md) before participating. Report sensitive
vulnerabilities through the private process in [Security](SECURITY.md).

## License

Glacier Engine is available under the [Apache License 2.0](LICENSE).
