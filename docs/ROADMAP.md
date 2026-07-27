# Glacier Engine Roadmap

This roadmap is an invitation to contribute, not a promise of delivery dates.
Every track advances through evidence-backed states:

`idea → prototype → integrated → validated → shipped`

- **Prototype:** the contract and rejection paths work in isolation.
- **Integrated:** a real runtime or provider path uses the contract.
- **Validated:** retained multi-platform or workload evidence meets its gate.
- **Shipped:** the interface, documentation, migration policy, and operations are
  ready for users outside the project.

## North star

Build a full local, edge, accelerator, and provider-backed AI runtime where
every visible token, tensor, score, media chunk, retrieval result, or authorized
action can be connected to exact artifact identity, resource ownership,
scheduling, state, transactional publication, and independently verifiable
evidence. The plane and model-family sequence is specified in the
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).

## Current snapshot

| Track | Status | What works now | Main gap |
| --- | --- | --- | --- |
| Exact admission | Integrated | ResourceBank receipts, capacity rejection, release, snapshots | Physical telemetry adapters and long-running pressure campaigns |
| Hierarchical ownership | Integrated | LeaseTree child scopes, fresh-Bank reacquisition, paged-KV remap, two-process handoff, seven-phase checkpoint root-switch recovery, and lease-backed single-consumer prepared-text source/target grants | Production-model continuation, acknowledged target progress, and durable lifecycle metadata |
| Deterministic QoS | Integrated | LaneWeave admission, weighted service, deadlines, cancellation, replay, bounded open-loop and finite-source closed-loop pressure campaigns, exact scheduler-receipt handoff to final-quantum media transactions, one mixed typed vision/audio/temporal-video workload with scheduler-owned publication, and one atomic process-local typed tool transaction profile | Family-aware batching, preemption, placement, provider/stateful/live-tool workload profiles, and broader multi-tenant integration |
| Token publication | Integrated | Contiguous/paged transactions plus exact-once next-token publication after natural exit and every checkpoint root-switch death phase | Uninterrupted/resumed production comparison |
| Continuation identity | Prototype | Capsule, object lifecycle, durable payloads, ownership/KV/runtime reconstruction, atomic immutable checkpoint generations, two-process resume, and a three-generation prepared-text source-live/source-exited/terminal authority chain | Production model/tokenizer state, generation-one source recovery, acknowledged target progress, native Linux execution, and durable lifecycle metadata |
| AI runtime | Mixed prototype/integrated planes; R0 registry complete and R1a/R1b/R1c/R1d/R1e/R1f/R1g/R1h-a/R1h-b plus the durable handoff slice integrated experimentally | CPU execution, an optional macOS Metal kernel path, prepared `.glrt` images, an exact-identity serial greedy prepared-text session with plan-derived atomic start, Common Model Contract request-profile binding, total-versus-request claim projection for shared read-only artifact residency, fixed-length terminal results, canonical non-terminal state, same-process rebind, canonical successor evidence, receipt-funded restored activation at sequence `N`, and a five-object canonical restart archive with exact source exit, exclusive POSIX lease, one-shot target activation, fresh-process resume, generation-three terminal selection, and terminal-semantic oracle comparison; plus admission, scheduling, continuation, provider, media, package, C verifier, and retained-reference inspector surfaces | Recover source death before generation-two publication; add an idempotent durable result sink and acknowledged progress generation for target-crash replay; complete request-shape accounting, raw-text tokenizer identity, variable-length results, non-blocking startup, stable APIs, production fixtures, native multi-OS validation, GPU/device continuation, physical resource integration, and distribution |
| Device runtime | Portable selection, fake/native allocation ownership, bounded dispatch-to-allocation lifetime fencing, per-adapter single-flight Metal async completion, and exact terminal-command-error reconciliation integrated; native Metal readiness and pinned-dispatch bindings implemented | Pointer-free capability selection; adapter-quoted manifests; exact logical charge-before-allocate accounting; additive LeaseTree reserve/materialize/FreePermit recovery; exact object-set pins; adapter-issued generation-fenced INT4 request roots; sealed pre-Bank pin intents with exact post-reserve abort; callback/source validation; submitted, terminal-failure, pure-cancelled, and inspected-but-unsubmitted rejection branches; `MetalAsyncDispatchTicketV1` with exact submit replay and separate poll/wait; pending nonterminal retention; native command/four-buffer and exact output-role binding; exact quarantined `.error` authorization as core `terminal_failure`; Bank-first settlement and exact native terminal finalization; sticky ambiguity/unknown quarantine; replay tombstones; one real successful four-buffer Metal command under a live pin with CPU-oracle correctness; per-resource length/`allocatedSize`; generation-fenced reuse; and native fingerprint revalidation | Physical device-loss inspection and recovery; general quarantine clearing, fresh selection, and migration policy; multi-slot and multi-device scheduling; separate physical residency and direct telemetry; additional GPU backends; retained native OS/device matrices; then performance evidence under declared campaigns |
| Model-family breadth | Text-generation prototype, typed vision/audio/temporal-video encoders, fresh-process stateful transcript and VFR video models, exact word/speaker annotations, video-segment results, canonical video timelines, exact audio/video result links, exact latent continuation, generated-image publication, acknowledged generated-PCM/video publication, atomic generated-output checkpoints, exact encoded-payload archive composition, bounded multi-output registry continuity, canonical typed producer admission, exact deterministic producer-transition replay, validated bounded lossless delivery profiles for retained image/audio/video shapes, a typed pure-tool transaction fixture, a durable POSIX external-action handoff fixture, and a bounded same-process fake dispatch/status authority; other families gated | Shared artifact/plan/result wires, explicit support records, reusable stateless/stateful lifecycles, fresh-Bank retained-state restore, tensor, provider, media, tool-authorization, ActionOutbox, and evidence building blocks | Generic embeddings/reranking/classification, richer multimodal fusion, live provider-backed and OS-isolated dispatch/status adapters, production generative-media adapters and broader formats, additional replay profiles, agents/retrieval, and specialized families |
| Multimodal execution | Model-free runtime, scheduler-coupled final-quantum transactions, streaming, continuation, post-restore generation three, processor/cache state, stateful transcript/video restart, exact word/speaker annotation restart, explicit VFR discontinuity evidence, exact audio/video result links, generated-image publication, acknowledged generated-PCM/video publication, atomic three-modality generated-output selection, exact encoded-payload archive composition, bounded multi-output registry continuity, typed producer/raw-output admission, deterministic source-model/materializer replay, and vision/audio/video fixtures integrated; bounded canonical PNG/WAVE/APNG profiles and their additive format sidecar integrated; production model execution gated | Shared identity/timeline, exact per-buffer ownership, six-object input checkpoint sets, image tile/patch state, audio window/hop/context plus fresh-process transcript state, sample-derived word timing and speaker-turn state, per-frame video PTS/duration plus retained temporal state, typed segment, deterministic merge state, cross-modal link state, exact cache payloads, restore-before-visible ownership, terminal-latent provenance, atomic media publication, exact application backpressure, canonical audio/video acknowledgement replay, complete previous-or-successor generated-output checkpoints, one eight-object archive for typed records plus exact payloads, a canonical typed-admission construction path, transition and format-evidence sidecars, strict lossless emit-and-accept modules, real two-generation PNG/WAVE/APNG registry-transition-format fixtures, an independent composed Python oracle, and optional format-aware read-only inspection without changing earlier V1 wires | Production encoder/container adapters and broader profiles, additional model/materializer profiles, richer language/punctuation and overlapping-speaker policy, native Linux/Windows execution and power-loss campaigns, and physical playback/display and quality evidence |
| Provider gateway | Integrated | Coalescing, cancellation, usage settlement, cost and event wires | Isolated live adapters and user-facing tooling |
| Context efficiency | Integrated fixture | Lossless mapping, exact wire observations, reconciled admission | Real adapter campaigns and privacy review |
| Durable provider evidence | Integrated; outer inspection prototype | Crash-recoverable journal, compact evidence join, and a deterministic read-only inspector for outer framing/checksum and self-asserted fields | Optional caller-supplied nested-composition inspection, export, retention, and operational policy |
| Platform portability | macOS development host plus cross-build candidates | Portable wires/state machines, CPU fallbacks, exported package modules, a compile-time adapter-availability inventory, target-specific affected-path selection with named core/CPU/durable/device/host-tool profiles, a complete consumer compile closure, and full per-target fallback, one shared DAG per selected target, a CLI-only default install with opt-in benchmarks, full production/benchmark/test-compile gates for Linux x86_64/AArch64 musl, Windows x86_64 GNU, and FreeBSD x86_64, POSIX/Windows read-only model mapping, portable process-ID/forced-termination fixtures, and Android/iOS AArch64 core compile probes | Separate durable POSIX authority from the transitional core; promote verification profiles into distributable products; add native Linux/Windows/FreeBSD CPU, mapping, recovery, telemetry, and packaging gates; then add mobile lifecycle gates and a reduced edge profile |
| Benchmark evidence | Prototype with W5a, a bounded Linux host source, native macOS Metal diagnostic readiness, and native allocation/pinned-dispatch ownership integrated | Paired harnesses, machine envelope, fixed native-observation ABI, stable source identity separate from event provenance, nonzero unavailable-reason identity with no present-reason identity, fail-closed family-neutral runner, independent reference verification, a shared bounded macOS host observer, a strict bounded Linux `MemAvailable` adapter with cross-host parser/model tests, one fixed readiness Metal dispatch with command-buffer timestamps and explicit unsupported telemetry, and a separate real-buffer ownership gate with exact dispatch pins, CPU-oracle correctness, context/stale-token fencing, and an independent shim registry | Retained native Linux and Metal artifacts; direct CPU/device power, thermal, frequency, utilization, residency, and energy adapters; plus reproducible native machines |
| Runtime Workload Lab | W0–W4a, W4b-a through W4b-d, W5a, and bounded W5b Linux-source and macOS Metal readiness implementations integrated; W4b and W5 remain open | Portable pressure, typed workloads, external-action handoff, deterministic storage faults, real host process-death recovery, and a download-free three-profile/six-item observation reference now retain explicit machine-state availability, stable source and per-event provenance, nonzero unavailable-reason identity with no present-reason identity, host/device planes, per-record sample-clock identity, value-clock identity only for present time metrics, fail-closed pre-admission, post-run contamination, fallback, correctness, and zero-orphan evidence without relabeling logical steps as native timing; the host JSON seam adds checked bounded Linux available-memory parsing, the native Metal readiness gate performs exactly one fixed 37x64 INT4 dispatch, and a separately serialized ownership gate performs one exact four-buffer pinned dispatch without making a performance claim | Remaining W4 profiles; retained native Linux and Metal observer evidence; direct physical CPU/GPU adapters; W6 native reports; W7 soak/disruption; and W8 native multi-OS replication |
| Weight paging | Prototype | Tested mechanics and precision rejection | Real generation integration without eager duplicate weights |

## P0 — Open-source usability

### Contributor experience

- [x] Public architecture, quickstart, roadmap, support, security, and governance.
- [x] Exported `glacier` and `glacier_core` Zig package modules with a retained
  dependency-consumer smoke test independent of CLI/demo/benchmark execution.
- [x] Model-free demos for scheduling, publication, and provider state machines.
- [x] Model-free continuation capsule with independent verifier and complete
  serialized-byte mutation coverage.
- [x] Model-free tenant-scoped object resolver with independent contract model,
  bounded scans/bytes, and adversarial failure coverage.
- [x] Fixed tenant-scoped continuation bundle with canonical dedup ordinals,
  exact logical/unique totals, and full serialized-byte mutation coverage.
- [x] Bounded in-memory tenant store with atomic bundle import, exact accounting,
  duplicate reuse, quarantine, and allocator-failure rollback.
- [x] Explicit-tick object leases with renewal generations, collection fencing,
  quarantine invalidation, scoped repair, and cross-language receipt roots.
- [x] Exact root/lease reachability evidence with retained retirement, bounded
  dry-run classification, cross-language plan roots, and no deallocation.
- [x] Separately scoped sweep prepare/abort journal with plan regeneration,
  staging ceilings, unchanged snapshots, and cross-language evidence roots.
- [x] Separately scoped destructive sweep commit with canonical targets, full
  pre-mutation validation, exact before/after accounting, allocator-call
  evidence, and cross-language roots.
- [x] Fixed 784-byte sweep evidence record with chain fields, separate commit
  footer, semantic receipt reconstruction, pinned expectations, and independent
  Zig/Python mutation-complete verification.
- [x] Allocation-free anchored sweep-record classifier with exact committed
  prefix, named body/footer tail states, semantic/chain rejection, and exhaustive
  cross-language append-boundary fixtures.
- [x] Snapshot-bound exclusive sweep writer with separate append/repair
  capabilities, ordered sync, uncertain-state poisoning, explicit repair, and
  exhaustive Zig/Python deterministic crash-boundary models.
- [x] Descriptor-relative POSIX sweep file adapter with exclusive locking,
  identity/link/mode fences, ordered file and directory sync, explicit repair,
  and six real subprocess-death boundaries on the macOS host.
- [x] Exact no-mutation destructive preview plus an ordered file adapter that
  syncs the predicted receipt before deallocation and reconciles old/new
  snapshots idempotently after an injected publication boundary failure.
- [x] Canonical tenant payload snapshots plus fixed exact-target reclaim records,
  copy-on-write file promotion, stable locking across inode replacement, and
  seven real process-death boundaries on the macOS host.
- [x] Canonical ownership manifest with fresh-epoch ResourceBank/LeaseTree
  reacquisition, charge-before-materialization ordering, exact restored
  publication sequence, and independent mutation-complete verification.
- [x] Canonical paged-KV images with durable membership, complete source-chain
  validation, atomic fresh-cache reconstruction, new target generations, and
  independent mutation-complete verification.
- [x] Fixed runtime state plus a natural-exit two-process continuation proof
  joining KV, RNG, sampler, output, sequence, commit lineage, and zero-leak
  ownership teardown.
- [x] Canonical whole-checkpoint archive and fixed root selector with exact
  previous/successor recovery, seven process-death phases, independent
  verification, and a fresh live resume after every phase.
- [x] Canonical five-object prepared-text restart archive, exact source-exit
  receipt, source-live/source-exited/terminal selector lineage, exclusive
  POSIX lease, one-shot activation grant, and a separate-process
  baseline/source/target terminal-semantic comparison.
- [x] Fixed shared image/audio/video descriptor, checked rational timeline,
  explicit event lineage, and exact-once logical chunk publication with a
  model-free demo and independent verifier.
- [x] Fixed sealed media decode plan plus bounded RGB, PCM, and intra-frame
  video fixtures with caller-owned output, complete unit mappings, and
  cross-language mutation-complete verification.
- [x] Fixed sealed media transform plan with allocation-free image
  crop/nearest/tile, audio weighted mix/exact decimation, and video keyframe
  selection, exact mappings, and shared Zig/Python plan and receipt roots.
- [x] Integrated model-free media runtime transaction with exact ResourceBank
  claims, provisional caller-owned storage, transform candidate revalidation,
  atomic image/audio/video publication, abort scrubbing, retry, exact release,
  a fixed receipt, and independent mutation-complete verification.
- [x] Per-buffer media LeaseTree ownership for decoded source, mappings,
  optional scratch, and output; atomic charge-before-use, abort reclamation,
  early provisional retirement, retained output ownership, fixed receipts, and
  independent cross-language golden vectors.
- [x] Bounded multi-chunk image/audio/video streams with exact contiguous target
  intervals, cancellation-safe unpublished reclamation, retained output leases,
  fixed predecessor-bound chunk receipts, and shared Zig/Python golden chains.
- [x] Fixed image/audio/video stream checkpoints, charge-before-materialization
  fresh-Bank output restore, shared Zig/Python roots, and a real two-process
  next-chunk resume with zero duplicate publication.
- [x] One-root image/audio/video checkpoint sets with a canonical retained
  output bundle, two lineage-bound generations, seven `SIGKILL` durability
  boundaries, exact previous/successor visibility, and fresh resume before and
  after idempotent recovery.
- [x] Stateful five-object media checkpoint sets that cross-bind the fixed
  processor/cache bundle to all three stream checkpoints, retain four-object
  archive compatibility, and advance processor lineage through fresh-process
  generation three.
- [x] Materialized six-object media checkpoint sets with canonical
  image/audio/video cache payloads, mutation-complete verification, fresh-Bank
  charge-before-visibility restore, successor cache lineage, and zero final
  ownership.
- [x] Full AI runtime architecture roadmap with shared planes, universal adapter
  contracts, model-family coverage map, promotion gates, and contributor lanes.
- [x] Canonical stateful-model checkpoint with fresh-Bank
  charge-before-materialization restore and a real two-process latent chain
  that publishes the terminal step exactly once.
- [x] Bounded generated-image plan, provenance, and result wires with exact
  terminal-latent binding, atomic abort/retry publication, independent
  mutation-complete verification, and a real two-process restart proof.
- [x] Fixed speech annotation state, plan, and result wires with exact
  transcript-word/sample/speaker lineage, abort-safe atomic publication,
  independent mutation-complete verification, and a real two-process state
  continuation proof.
- [x] Bounded generated-audio state, plan, provenance, result, observation, and
  acknowledgement wires with exact PCM/frame lineage, one-buffer backpressure,
  cancellation-safe atomic publication, independent mutation-complete
  verification, and a real two-process acknowledgement/publication proof.
- [x] Bounded generated-video state, two-frame manifest, provenance, result,
  observation, and acknowledgement wires with exact frame roots/durations,
  one-segment backpressure, cancellation-safe atomic publication, independent
  mutation-complete verification, and a real two-process proof.
- [x] Fixed generated-media member, checkpoint, and selector wires composing one
  typed image completion plus exact audio/video acknowledgements; independent
  mutation-complete verification and four process-death boundaries recover
  only the complete previous or successor generation.
- [x] Canonical eight-object generated-media payload archive binding one
  manifest, checkpoint, three typed members, and three exact encoded payloads;
  independent verification, one outer filesystem selector, seven
  process-death phases, exact previous-or-successor selection, and idempotent
  recovery.
- [x] Independent bounded generated-media output-registry ABI packing one to
  four output entries per present modality, up to twelve, into fixed
  `(modality, ordinal)` entries plus exact encoded payloads in exactly three
  archive objects; ordinal/unit/timeline/predecessor continuity, exact
  previous-archive binding, opaque completion-root binding, independent
  verification, and seven-phase previous-or-successor recovery.
- [x] Canonical generated-media producer-admission gateway decoding the exact
  image `736/640/704`, audio `448/576/512/576/512`, and video
  `512/736/640/672/512`-byte typed wire sets; verifying exact raw media bytes,
  common request/scope/policy/challenge, and strict
  state/result/completion predecessors; deriving registry generation,
  publication sequence, and entry lineage; and feeding the unchanged
  three-object registry with independent Python verification.
- [x] Host-verified generated-media producer-transition gateway replaying exact
  deterministic source-model and materializer callbacks for the retained
  image/audio/video reference profiles; reconstructing one-shot image
  publication plus complete audio/video acknowledgement transitions; deriving
  collection-aware registry order; and emitting fixed per-output receipts in a
  separate predecessor-bound evidence sidecar paired with the unchanged
  registry archive.
- [x] Strict allocation-free PNG, PCM/WAVE, and APNG emit-and-accept modules
  with explicit resource ceilings, frozen vectors, every-byte mutation
  rejection, native macOS tests, and module-level Linux/Windows/FreeBSD
  cross-compilation.
- [x] Experimental read-only generated-media evidence inspector with hard input
  ceilings, exact predecessor-pair validation, optional exact
  registry/transition/format triple validation, deterministic versioned JSON,
  empty semantic output on rejection, and no payload, callback, or write
  authority.
- [x] Integrated additive generated-media format-conformance sidecar with
  canonical failure-atomic encoding, real two-generation PNG/WAVE/APNG
  registry-transition validation, typed playback/display acknowledgement
  chains, missing/foreign predecessor and semantic-drift rejection, and an
  independent composed Python oracle for all three binary layers.
- [x] Deterministic read-only runtime support registry and inspector generated
  from eight retained exact-integer adapter profiles, with append-only mask
  positions, fixed-width C enumeration/query calls, standard-library Python
  and dependency-free Rust consumers, focused rejection tests, and a
  [fixture-authoring guide](RUNTIME_SUPPORT_INSPECTOR.md). Registration is not
  execution and no host backend is probed.
- [x] Bounded contributor project catalog and issue template.
- [x] One-command quick/full local verification wrapper with deterministic
  pass/fail/skip summaries, explicit skipped-gate reasons, bootstrap-safe
  temporary Zig caches, temporary install products, bounded parallelism, no
  model downloads, and fake-tool regression coverage for cleanup and exit
  behavior.
- [x] Read-only provider evidence outer-envelope inspector with deterministic
  JSON, independent oracle coverage, explicit self-asserted nested fields, and
  no payload, credential, composition, or authority claim.
- [ ] Read-only token transaction inspector.
- [ ] Small redistributable fixtures covering the supported loader surface.
- [ ] First tagged experimental release with checksums and migration notes.

### Stable project surface

- [x] Establish a narrow experimental C boundary for allocation-free Model
  Contract V1 chain verification, with installed shared/static libraries,
  a public C/C++ header, source and staged-install C consumers,
  standard-library Python `ctypes`, and a named dependency-free Rust gate.
- [ ] Separate internal research APIs from the supported library boundary.
- [ ] Publish an API stability and deprecation policy.
- [ ] Retain an exported-symbol/layout allowlist, native multi-OS consumers,
  packaging metadata, and migration fixtures before promoting the experimental
  C boundary.
- [ ] Add installation packages after cross-platform release artifacts are proven.
- [ ] Add automated repository checks only when they are stable, fast, and useful
  to contributors locally as well as remotely.

### Platform portability

Goal: keep one canonical AI Runtime core while moving filesystem, mapping,
process, clock, telemetry, and accelerator authority into explicit adapters.

- [x] Define compile, native CPU, recovery, accelerator, resource, and packaging
  evidence levels without treating cross-compilation as support.
- [x] Record full cross-build gates for Linux x86_64/AArch64 musl, Windows
  x86_64 GNU, and FreeBSD x86_64, compile-only core probes for Android/iOS
  AArch64, and the current WASI blockers.
- [x] Add a bounded read-only model-file mapping abstraction with POSIX and
  Windows implementations, plus portable process-ID and forced-termination
  fixture seams.
- [x] Export the first consumer-facing `glacier` and `glacier_core` package
  modules and retain a native/cross-target import smoke gate.
- [x] Add a core-only experimental C contract library with distinct shared and
  static products, an installed header, focused compile/test steps, and
  cache-safe C/Python/Rust examples.
- [x] Add one reproducible focused C contract library/consumer compile-link
  step and record a dated local observation for Linux x86_64/AArch64 musl,
  Windows x86_64 GNU, and FreeBSD x86_64 without relabeling those cross-builds
  as native support.
- [x] Centralize compile-time adapter availability for read-only mapping,
  POSIX durable files, forced-termination fixtures, and Metal without treating
  source selection as native verification or platform support.
- [x] Add the portable Stage-5 device capability and selection contract:
  pointer-free fingerprints, canonical operation/type/numerical profiles,
  derived aggregate bits, canonical discovery-epoch inventory,
  execution-plan-bound requirements, explicit fallback, and bounded
  deterministic selection before resource or scheduler mutation.
- [x] Bind stable native macOS Metal device information and one local discovery
  epoch to the selection, then revalidate its fingerprint and registry identity
  on the readiness device.
  Correct the tiled FP16 matrix multiplication path for asymmetric and partial
  edge tiles, with exact-length rejection and CPU-oracle correctness tests.
- [x] Add the receipt-bound fake device-allocation lifecycle: live adapter
  quote replay, canonical multi-buffer manifests, exact pre-allocation
  `ChildLease` charge, generation-fenced object sets, failure/cancellation
  rollback, conservative cleanup recovery, and independent root replay.
- [x] Add native Metal direct-buffer allocation with logical resource-length
  precharge, direct per-resource `allocatedSize` observation,
  release-before-uncharge, and generation-fenced reuse on the hard native
  gate.
- [x] Add a dedicated additive LeaseTree allocation coordinator with exact
  reserve/materialize/FreePermit recovery, shared-tree/session fencing,
  exclusive-scope validation, sibling isolation, and native Metal composition.
- [x] Bind dispatch lifetime to the exact LeaseTree-owned object set with
  bounded Bank pin storage, private permit custody, terminal-evidence
  completion, sealed pre-Bank `DispatchPinIntentV1` reservation with exact
  atomic-failure abort and callback/source validation, private post-Bank
  settlement, release fencing, overlapping out-of-order completion, an
  independent Python oracle, and one real four-buffer Metal dispatch.
- [x] Add single-flight Metal async completion delivery per adapter:
  pointer-free `MetalAsyncDispatchTicketV1`, exact submit replay, separate
  poll/wait, pending as nonterminal, native command-plus-four-buffer retention,
  exact completed-output binding, native finalization only after private Bank
  settlement, and sticky nonterminal `MetalAsyncDispatchQuarantineV1`.
- [x] Reconcile one exact quarantined Metal command-buffer `.error` as core
  `terminal_failure`: bind the retained ticket/quarantine/native projection,
  keep quarantine, pin, charge, buffers, and command through Bank settlement,
  then exact-finalize the native `.error` record before private clearing.
  Ambiguity and unknown completion remain sticky.
- [ ] Add residency as a separate authority, physical device-loss inspection
  and recovery, general quarantine clearing, fresh selection and migration
  policy, multi-slot and
  multi-device partitioning/scheduling, additional GPU backends, direct device
  telemetry, retained performance evidence, and advertised native device
  support matrices.
- [ ] Add pin-aware Snapshot V4 capacity/activity telemetry, reduce repeated
  full-tree validation inside the Bank lock, and reserve explicit completion
  headroom before generation or structural-revision exhaustion.
- [x] Add a bounded adapter-authorized pre-submit validation/rejection
  transition: a canonical Metal attempt binds geometry, host lengths, and
  roles; an adapter-issued generation-fenced request root binds that attempt
  and becomes the pin request. Valid preflight may submit or take pure
  `cancelled_before_submit`; deterministic malformed attempts may inspect
  native resources but construct and submit no command buffer. Both pre-submit
  terminals carry zero submission/backend/output roots and use the same private
  Bank/adapter settlement without requiring device-loss reconciliation.
- [ ] Split `core-contract`, CPU runtime, durable runtime, device runtime, CLI,
  mobile library, reduced edge profile, and host-only tools in the build graph.
- [ ] Finish replacing direct durable-file calls with bounded recovery
  adapters; model conversion and runtime images now share the first bounded
  POSIX/Windows read-only mapping seam.
- [ ] Retain native Linux x86_64/AArch64 and FreeBSD x86_64 CPU and
  filesystem-recovery campaigns.
- [ ] Add the remaining Win32 durable-file, clock, telemetry, recovery, and
  packaging adapters, then retain native campaigns before declaring Windows
  support.
- [ ] Add Android/iOS library packaging, lifecycle, storage, memory-pressure,
  and native-device correctness gates.
- [ ] Define explicit single-threaded/no-durable-filesystem edge capabilities
  and checked 32-bit `u64`-to-`usize` boundaries.
- [x] Add the first portable versioned explicit-open-loop workload-scenario and
  result format with fixed arrivals/seed, nearest-rank logical-step
  percentiles, queue/fairness/accounting summaries, exact resource ceilings,
  full replay, and an independent verifier.
- [x] Connect that frozen workload to one bounded image, audio, and video media
  transaction on completed requests only, adopting the scheduler receipt
  without double admission and retaining a separate exact Zig/Python execution
  sidecar with atomic final service and zero-orphan close.
- [x] Let the retained typed vision, audio-window, and temporal-video adapters
  adopt the exact scheduler receipt, preflight every fallible result check,
  expose output only through the final V2 service commit, and retire with zero
  model/cache ownership while preserving all existing V1 wires.
- [x] Add a generated deterministic open-loop corpus with four retained seeds,
  eight scenario classes per seed, coordinate-addressed SHA-256 decisions, unchanged W0/W1
  evidence ABIs and reference goldens, independent Python generation and
  verification, plus a synthetic exact-signature local-minimum shrink fixture.
- [x] Add a separately versioned finite-source deterministic closed-loop
  contract with a declared in-flight target, exact four-phase step order,
  terminal-trace-ordered FIFO credits admitted on the next logical step,
  canonical lineage/result wires, direct Zig/Python replay, and zero-orphan
  close while preserving every W0/W1/W2 ABI and retained root.
- [x] Add the separate W4a typed-workload plan and family-neutral lifecycle
  driver, then compose retained vision, audio-window, and temporal-video
  adapters under the exact scheduler receipt. Retain canonical plan/result and
  concrete evidence roots, independent Python replay, semantic-substitution
  rejection, publication only for completion, and final zero model/cache
  ownership without changing W0–W3.
- [x] Add the W4b-a typed tool transaction with separate proposal and
  policy authority, fixed-storage idempotency and integrity fencing, a
  scheduler-before-mutation precommit with retained-lock process-local effect
  delivery on the exact service event, independent replay, and zero-authority
  cleanup without changing W4a.
- [x] Add W4b-b portable ActionOutbox records with pinned payload and stable
  remote-request identity, body/footer commit framing, uncertainty-preserving
  recovery, acknowledgement versus reconciliation record kinds, retry only
  after a committed `reconciled_not_applied` record, separately authorized
  compensation children, all 7,521 retained cuts from the complete header
  through the journal, and an independent oracle. External evidence
  authentication remains adapter work.
- [x] Add W4b-c descriptor-relative POSIX storage while keeping each clean
  committed prefix at `320 + 752n`: exclusive advisory locking, no-follow and
  file-identity fences, semantic `ApplyPlanV1` preflight, ordered body/footer
  sync, snapshot/lease/repair roots, explicit tail repair, mandatory fresh
  reacquisition, 40 append-phase + 754 section-prefix + 751 repair-tail + 8
  repair-fault Zig/Python cases, and 49 real host process deaths.
- [x] Add the bounded W4b-d same-process dispatch/status slice without changing
  the W4b-b/c record or store ABI: pointer-free credential-free request and
  evidence values, exact descriptor/attempt composition, durable intent before
  callback, a multi-action capacity guard that protects one future slot per
  uncertain action, fixed-storage fake authority, atomic generation fencing,
  delayed dispatch rejection before and after terminal completion, retry only at
  `G + 1`, deterministic same-process faults across four terminal-transition
  plus four fenced-transition append phases with fresh reopen/reconciliation,
  and an independent standard-library Python model.
  The gate also compares a live canonical Zig report through the Python model;
  it adds no retained JSON fixture or new process-death matrix.
- [x] Add W5a as a separately versioned native-observation foundation:
  pointer-free descriptor/rule/plan/observation/bundle values, explicit
  `present`/`missing`/`denied`/`unsupported`, host and accelerator planes,
  stable source identity distinct from per-event provenance, nonzero reason
  identity only for unavailable records and no reason identity when present,
  sample-clock identity on every observation and value-clock identity only on
  present time-valued metrics, a fail-closed family-neutral runner, retained
  post-run contamination, explicit accelerator fallback, and the download-free
  three-profile/six-item typed-perception reference. Extract the bounded macOS
  host parsers into one shared observer used by the paired harness, and keep
  foreign-target compilation distinct from native evidence.
- [x] Add the first post-W5a platform adapter slice: a platform-neutral JSON
  metric registry/validator and dispatcher seam plus a fixed-path, 64 KiB
  bounded Linux `/proc/meminfo` `MemAvailable` parser. Preserve the historical
  macOS JSON schema, separate stable source identity from per-read event
  provenance, avoid Unix process-group calls on non-Darwin dispatch, and make
  native Linux acceptance explicitly required rather than silently skipped.
  Native Linux evidence remains pending.
- [x] Add the bounded native macOS Metal readiness slice without promoting it
  to a benchmark: run one fixed synthetic 37x64 INT4 matrix-vector dispatch
  exactly once across the hard gate; require CPU-oracle correctness, completed
  command-buffer GPU timestamps, registry-bound device/placement identity,
  allocation context, zero leaked ownership, explicit no-fallback evidence, and
  composed descriptor/plan/run/dispatch roots. Treat
  `recommendedMaxWorkingSetSize` only as capacity context and keep utilization,
  committed/resident bytes, queue depth, temperature, frequency, power, and
  energy explicitly unsupported. The verifier checks composition/corruption of
  self-asserted live output; a retained native result remains pending.
- [ ] Extend W4 through separately retained provider, stateful, streaming,
  batched, preemptible, device-backed, live provider-backed, and OS-isolated
  dispatch/status profiles.
- [ ] Complete W5 with direct CPU, GPU/accelerator, memory-residency, power,
  thermal, frequency, utilization, energy, and native per-OS observer adapters.
- [ ] Retain native per-OS mixed-family load and bounded soak campaigns with
  CPU/GPU identity and placement, host/device timing, memory residency, power,
  thermal, backend, fault-schedule, memory-growth, recovery, and zero-orphan
  evidence.

See [Deterministic Workload Pressure](WORKLOAD_PRESSURE.md) for the implemented
V1 contract, exact reference campaign, claim boundary, and contributor slices.
See [Scheduled Media Pressure](SCHEDULED_MEDIA_PRESSURE.md) for the additive
single-receipt image/audio/video execution and publication evidence.
See [Generated Workload Corpus](GENERATED_WORKLOAD_CORPUS.md) for the W2
generator ABI, retained 32-case matrix, shrinking contract, and nonclaims.
See [Deterministic Closed-Loop Workload](DETERMINISTIC_CLOSED_LOOP.md) for the
W3 finite-source controller, phase order, lineage evidence, retained fixture,
and logical-only claim boundary.
See [Typed Workload Conformance](TYPED_WORKLOAD_CONFORMANCE.md) for the W4a
plan, generic lifecycle driver, retained mixed-perception campaign, evidence
roots, independent replay, and logical-only claim boundary.
See [Typed Tool Workload](TYPED_TOOL_WORKLOAD.md) for the W4b-a
proposal/policy/idempotency/effect transaction and its external-effect
nonclaims.
See [ActionOutbox Protocol](ACTION_OUTBOX.md) for W4b-b/c stable request,
uncertainty, reconciliation, compensation, durable POSIX publication, and
explicit prefix repair plus the bounded W4b-d same-process adapter boundary,
generation fence, and retry rules.
See [Native Observation Contract](NATIVE_OBSERVATION.md) for W5a availability,
admission, two-clock semantics, fallback, host observers, native Metal
readiness, verification, and nonclaim rules.
See [Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md) for the W0–W8 workload,
native-observation, resilience, and platform-replication sequence.
See [Platform Portability](PLATFORM_PORTABILITY.md) for the evidence matrix,
adapter architecture, G0–G7 promotion gates, and staged target sequence.

## P1 — Verifiable AI state

### Prepared text state capture

Goal: turn an exact live prepared-text boundary into portable, independently
verifiable state without weakening the current publication authority fence.

1. ~~Canonical non-terminal state image over independently retained
   plan/boundary/transcript roots, output prefix, RNG, sampling count, and
   committed contiguous KV.~~ Complete in R1e.
2. ~~Independent reconstruction of full logical KV and incremental publication
   KV/state commitments.~~ Complete in Zig and Python with a raw-bit golden and
   every-byte mutation rejection.
3. ~~Fresh detached materialization with deterministic zero output/KV slack.~~
   Complete in process; the value intentionally has no publication authority.
4. ~~Add a retained-authority rebind at the exact current boundary without
   changing coordinator address, receipt, Scheduler, Bank, or sequence.~~
   Complete in R1f for the original same-process Session with full
   allocation-failure atomicity, a retained-permit transition comparison, and
   stale/moved/active-row rejection; old borrowed state views are invalid after
   a successful backing replacement.
5. ~~Define a successor plan/residency and transcript segment with nonzero
   sequence base, source-boundary lineage, nonempty cache payload identity, and
   explicit target ownership intent.~~ Complete in R1g with canonical Common
   Model Contract plan/residency records, a fixed 512-byte segment, independent
   Zig/Python verification, and no authority handoff claim.
6. ~~Add a fresh target Scheduler admission, ResourceBank receipt and
   permit-generation fence, and a queue-free receipt-funded LeaseTree bootstrap
   behind a non-runnable barrier.~~ Complete in R1h-a without allocation or
   adoption commit.
7. ~~Reserve request-local byte ownership without double-counting, materialize
   checkpoint state under charge, construct a runnable Session, and commit
   restored LeaseTree-aware adoption.~~ Complete in R1h-b with publication
   `sequence_base`, one uninterrupted/restored next-token comparison, and
   barrier-held teardown to zero.
8. ~~Compose the records through the durable checkpoint selector, then prove
   source exit, exclusive fresh-process target, and uninterrupted/resumed
   terminal-semantic equivalence.~~ Complete experimentally with a canonical
   five-object restart archive, source-live/source-exited/terminal generations,
   a lease-backed one-shot target grant, and separate baseline/source/target
   subprocesses.
9. Add a source-side recovery journal for death before generation-two
   publication. Until then the protocol remains fail-closed and unavailable in
   that window.
10. Add an idempotent external sink contract and acknowledged progress
    generation. Until then a target death before generation three can replay
    publication from `N`.

See [Prepared Text Checkpoint](PREPARED_TEXT_CHECKPOINT.md) for the state wire
and same-process safety boundary, and
[Prepared Text Successor Evidence](PREPARED_TEXT_SUCCESSOR.md) for the R1g
records and ownership-intent boundary, and
[Prepared Text Restore Admission](PREPARED_TEXT_RESTORE_ADMISSION.md) for the
R1h-a bootstrap and R1h-b process-local activation boundary. See
[Durable Prepared-Text Handoff](PREPARED_TEXT_DURABLE_HANDOFF.md) for the
five-object restart archive, three selector generations, lease/grant
lifecycle, separate-process fixture, and current crash-window limits.

### Durable continuation capsule

Goal: resume model identity, execution plan, KV roots, RNG, sampler counters,
output position, and ResourceBank ownership after a process restart.

Next slices:

1. ~~Canonical pointer-free continuation identity.~~ Complete in v1.
2. ~~Mutation-complete Zig/Python verifier fixtures.~~ Complete for all 608
   serialized byte positions and foreign object substitution.
3. ~~Capability-bounded object resolver with kind/ABI/length/root admission.~~
   Complete in memory with tenant scope, stale-epoch rejection, caller-owned
   output, bounded scan/object/total/count limits, and final composition check.
4. ~~Content-addressed bundle manifest with deduplication and tenant scope.~~
   Complete as a fixed 1,136-byte plan with typed and tenant-bound roots,
   canonical first-occurrence ordinals, and independent verification.
5. ~~Bounded immutable in-memory store with atomic bundle import.~~ Complete
   with bundle provenance, duplicate reuse, references, quarantine, exact
   payload/index counters, snapshot root, and allocator rollback.
6. ~~Lease/generation fencing and provenance-aware repair.~~ Complete in memory
   with separate lifecycle/repair capabilities, explicit ticks, stale-receipt
   rejection, quarantine fencing, exact candidate verification, and v2 snapshot.
7. ~~Reachability evidence and dry-run collection eligibility.~~ Complete with
   explicit retirement, exact root multiplicity, complete lease receipts,
   bounded slot classification, and independent plan verification.
8. ~~Bounded sweep prepare/abort journal.~~ Complete with a separate capability,
   collection-plan regeneration, exact staging ceilings, functional journal
   values, stale-snapshot rejection, and independent verification.
9. ~~Destructive sweep commit with exact allocator/accounting receipt.~~
   Complete in memory with a second capability, repeated plan regeneration,
   canonical target derivation, a no-failure mutation suffix, replay rejection,
   and independent verification.
10. Durable sweep and file-publication crash-recovery state machine:
    - ~~fixed pointer-free body/footer evidence record;~~ complete as a 784-byte
      format with record chaining and semantic receipt reconstruction;
    - ~~pure recovery classifier over concatenated records and incomplete
      tails;~~ complete with exact epoch/sequence/previous-root anchors, semantic
      record replay, five statuses, and no I/O or repair authority;
    - ~~snapshot-bound capability writer with ordered sync, uncertain-writer
      poisoning, explicit repair policy, and deterministic crash storage;~~
      complete without real filesystem authority;
    - ~~directory-capability adapter with platform locking, file/directory
      sync, replacement detection, and subprocess death tests;~~ complete for
      the POSIX adapter on the macOS host, with Linux compilation retained and
      native Linux filesystem campaigns still pending;
    - ~~join durable evidence publication to destructive transition ordering;~~
      complete for the in-memory payload store with an exact precomputed receipt,
      real file sync, injected post-publication failure, and idempotent old/new
      snapshot reconciliation;
    - ~~native durable payload-byte adapter and real process-death campaign
      across plan write/sync, candidate write/sync, rename, and directory
      sync;~~ complete on the macOS host with exact old/new recovery,
      idempotence, fixed target reconstruction, and independent Python
      verification; native Linux filesystem campaigns remain pending.
11. ~~ResourceBank/LeaseTree reacquisition without duplicated ownership.~~
    Complete as a fixed 3,360-byte resource-state plan that requires a fresh
    target epoch, charges every allocation as reserved before materialization,
    verifies typed reconstructed bytes before making nodes live, restores the
    exact next publication sequence, and rejects same-Bank replay plus stale
    source receipts.
12. ~~Paged-KV restore with foreign-generation rejection.~~ Complete as
    committed-row page images that rebuild an actual fresh `PagedKVCache`,
    preserve the logical KV root, remap cache/page generations, require exact
    durable membership and ownership claims, and reject stale source refs before
    publication.
13. ~~End-to-end process restart between two token publications.~~ Complete as
    a model-free natural-exit proof with a fixed runtime wire, different source
    and target process/cache identities, exact output append, chained receipt,
    and zero Bank usage after each process.
14. ~~Atomic publication and phase-complete process-death recovery for the
    whole checkpoint set.~~ Complete as an immutable archive plus fixed selector
    root switch across seven write, sync, rename, and directory-sync phases,
    followed by a fresh live resume after every recovery.

Promotion gate: byte-identical continuation of the selected deterministic mode,
no duplicated output, no orphaned ownership, and crash coverage at every durable
phase.

The current capsule, resolver, bundle, store, lifecycle receipts, collection
plan, sweep journal, sweep commit, body/footer record, classifier, scoped
writer, POSIX evidence file, payload file, and ownership manifest form identity,
least-authority lookup, canonical planning, durable payload-byte recovery, and
safe in-memory runtime reacquisition—not a saved session. The adapters perform
real file/directory sync, locking, identity checks, and subprocess-death
recovery on the macOS host. The ownership plan then binds the durable payload
root to a new Bank epoch and restores charged LeaseTree nodes before they become
live. Canonical page images then rebuild an actual paged-KV map under fresh
cache/page generations while preserving the logical KV hash. A fixed runtime
wire joins sequence, RNG, sampler count, output prefix, KV digest, and commit
lineage; a source worker exits and a fresh target publishes the next model-free
token exactly once. The checkpoint-file layer packages all restart objects into
one immutable archive and atomically switches a fixed selector; fresh recovery
accepts only the previous or successor root across seven process-death phases,
then resumes live publication. This does not yet restore object-store
lease/quarantine/repair metadata or reconstruct and compare a production
request. Process death is not power loss, and Linux has compile evidence rather
than a retained native filesystem campaign.
The fixture avoids one 25-byte duplicate payload allocation and the commit
fixture reclaims a 39-byte allocator tail, but lifecycle metadata, fixed index,
and backing capacity remain larger than those deltas. No lower RSS, disk use, or
restart latency is claimed. Those require compact index experiments, durable
metadata integration, production execution comparisons, native campaigns, and
complete physical measurements.

### Evidence inspection

Goal: make portable evidence understandable without weakening verification.

Next slices:

- [x] provider evidence outer-envelope renderer;
- [ ] optional provider nested-composition verification with every required
  input supplied explicitly;
- LaneWeave timeline JSON;
- token transaction root explorer;
- redaction-safe bundle manifest;
- schema-version and compatibility reporting.

Promotion gate: rendering never grants authority, never marks unverified bytes as
verified, and remains deterministic.

### Capability-isolated extensions

Goal: admit tokenizer, planner, storage, and provider adapters through declared
capabilities instead of direct access to all runtime state.

Next slices:

- capability vocabulary and threat model;
- fake extension negotiation;
- resource/evidence binding;
- process or sandbox boundary experiment;
- revocation and failure semantics.

## P1 — Provider efficiency and accountability

### Context and token plane

Current fixtures prove exact deduplication decisions and reconciled wire counts.
They do not prove universal billed-token savings.

Next slices:

- adapter contract for exact rendered bytes;
- tokenizer/execution identity registry;
- privacy-safe corpus fixture generation;
- cached prefix and tool-schema identity without raw text in core;
- provider-reported usage reconciliation across retries;
- campaign reports separating logical, observed, reserved, and billed tokens.

Promotion gate: no semantic span loss, exact mapping replay, provider terminal
usage attached to the correct attempt, and no credential or prompt leakage in
core evidence.

### Durable cost operations

Next slices:

- cross-filesystem crash/recovery campaigns;
- journal rotation and retention contract;
- multi-process reader and exporter;
- unknown-price and delayed-settlement operations;
- tenant-scoped evidence bundle lifecycle.

Promotion gate: no double counting across retry/ambiguous resolution, complete
valid prefixes survive process loss, and corrupt complete frames fail closed.

## P2 — Runtime breadth

### Model and tokenizer support

- define the common family, operation, artifact, state, and result vocabulary
  from the [Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md);
- expand tiny legal fixtures before adding large model downloads;
- separate architecture parsing from tensor naming;
- add tokenizer normalization and special-token conformance;
- report an explicit compatibility matrix generated from tests; complete for
  the eight append-only R0 retained-reference profiles and required for every
  newly admitted profile;
- validate quality and exact-output modes independently.

Promotion gate: every listed combination has a retained fixture, clear failure
for unsupported inputs, and reproducible generation instructions.

### Multimodal execution

Status: **integrated model-free runtime vertical plus scheduler-coupled typed
vision, audio, and temporal-video fixtures; production-model execution
gated**.
Shared identity, rational timeline/events, sealed plans, bounded canonical
RGB/PCM/intra-frame decode, three deterministic transforms, exact
`ResourceBank` admission, candidate revalidation, atomic logical publication,
abort/retry, fixed receipts, and exact release now work as one lifecycle. The
media lifecycle now adopts scheduler-owned receipts and executes one completed
image, audio, and video transaction atomically with its final service quantum.
The stateless model lifecycle separately adopts the same receipt for retained
vision, audio-window, and temporal-video adapters, preflights every fallible
result check, publishes the exact typed output through a bounded V2 finalizer,
and cancels or retires with one failure-atomic terminal release.
Three strict generated-output delivery modules now emit and accept bounded
canonical PNG, PCM/WAVE, and APNG profiles. They do not provide general external
format decoding, production encoder/container integration, quality evidence, or
physical playback/display. Tiny legal fixtures do not imply production-model
support.

The implementation sequence is:

1. shared `MediaObject`, sealed `MediaDecodePlan`, rational `MediaTimeline`,
   bounded three-modality fixture decode, and logical transactional publication
   are complete as model-free prototypes;
2. bounded image crop/nearest/tile and exact source-pixel mapping are complete;
3. weighted stereo-to-mono mixing, exact integer decimation, bounded two-chunk
   publication, model-free two-process restart, fixed feature-window state, a
   non-overlapping exact-integer feature encoder, canonical overlap ownership,
   typed transcript publication, and a fresh-process stateful transcript
   continuation with exact next-sample/link predecessor are complete; fixed
   word offsets, sample-derived timestamps, speaker identities/turn counts, and
   confidence now continue across a real annotation-state process restart;
   production speech models, language/punctuation and overlapping-speaker
   policy, crash-atomic composition, production renderers/codecs, and physical
   playback evidence remain;
4. keyframe selection, exact frame/time mappings, temporal-cache ownership, and
   a typed strided-frame encoder with charged gather scratch are complete; one
   fixed predecessor-bound typed segment now publishes exact source/time and
   event/confidence fields; fixed merge state and receipts deterministically
   coalesce same-event overlap while retaining gaps and event changes; one
   fixed result-link state and transaction map only newly publishable transcript
   samples to the accumulated video tail using exact integer time and
   dual-modality lineage; stateful transcript and video restart are complete
   for retained exact-integer fixtures, including per-frame PTS/duration and a
   declared VFR discontinuity; external container normalization remains;
5. exact request admission, per-buffer `LeaseTree` ownership, provisional
   execution, full candidate revalidation, commit/abort/retry, bounded
   multi-chunk publication, portable receipt chains, early provisional
   retirement, retained outputs, fixed continuation checkpoints,
   charge-before-materialization restore, two-process next-chunk resume, and
   release are complete for all three retained fixtures; crash-atomic media
   selection, two source-side generations, restored ownership rebinding, a
   fresh-process generation-three checkpoint, and another resume from that
   checkpoint are complete; fixed image tile/patch, audio feature-window, video
   temporal-cache, and synchronized-watermark state now advances as the fifth
   object in that durable archive; exact cache payloads advance as the sixth
   object and restore under fresh-Bank ownership; and
6. terminal-latent generated-image output now has bounded decode, exact source
   provenance, cancellation-safe retry, atomic visibility, and a real
   process-restart proof; its exact encoded payload now composes into the shared
   archive and its bounded multi-image registry continuity is complete, while
   production decoder/encoder and broader external-format profiles remain
   gated;
7. generated-audio output now has bounded exact-integer PCM rendering, exact
   frame/source/provenance/resource lineage, one outstanding-buffer gate,
   cancellation-safe retry, application acknowledgement, and a real
   process-restart proof; shared generated-output checkpoint composition is
   complete, its exact encoded payload composes into the shared archive, and
   bounded multi-chunk registry continuity is complete, while production
   renderers/codecs, broader external-format profiles, and physical device
   evidence remain gated; the two-generation WAVE
   registry-transition-format chain is integrated;
8. generated-video output now has an ordered two-frame raw manifest, exact
   frame roots and durations, source/provenance/resource lineage, one
   outstanding-segment gate, cancellation-safe retry, application display
   acknowledgement, and a real process-restart proof; bounded multi-segment
   registry continuity and the two-generation APNG
   registry-transition-format chain are complete, while production adapters,
   broader external-container profiles, and physical display evidence remain
   gated;
9. shared generated-output checkpoint composition is complete across image,
   audio, and video output transactions, including exact scope/completion
   binding, independent verification, and atomic previous-or-successor
   recovery;
10. exact encoded payload archive composition is complete as one canonical
    eight-object generation with explicit raw/encoded/encoder/format identity,
    two-generation lineage, an independent Python oracle, one outer selector,
    and seven process-death phases selecting only the exact previous or
    successor generation;
11. bounded multi-image/chunk/segment continuity is complete under an
    independent ABI with one to four outputs per present modality, at most
    twelve, fixed 544-byte entries, exact structural and encoded lineage, opaque
    state/completion roots, complete preceding archive bytes, and one
    three-object archive selected atomically;
12. canonical typed producer admission is complete before that registry:
    fixed image, audio, and video record sets plus exact raw output bytes derive
    the shared envelope, zero-based registry position, state/result/completion
    predecessors, registry generation/sequence, and entry chain without adding
    an archive object or selector;
13. host-verified producer-transition reconstruction is complete for the
    retained deterministic source-model and materializer profiles. Image
    outputs remain independent one-shot local media transactions while their
    registry collection ordinals are derived from validated lineage;
    audio/video replay includes publication, observation, acknowledgement, and
    final quiescent state. Fixed receipts live in a separate evidence sidecar
    bound to the unchanged registry archive;
14. bounded lossless PNG, PCM/WAVE, and APNG delivery profiles and their
    additive sidecar are integrated through real two-generation
    registry-transition-format fixtures. The sidecar binds profile, payload,
    producer semantics, registry entry, transition receipt, and predecessor
    format identity without changing either existing V1 wire. The read-only
    inspector optionally validates and renders this exact triple;
15. deterministic scheduled-media execution is complete for the retained
    pressure scenario: one completed audio, video, and image request adopts its
    existing scheduler receipt, publishes only through the final armed service
    commit, and emits a separate cross-language evidence sidecar. Cancel,
    timeout, and rejection publish no media and all accepted receipts close
    exactly once;
16. scheduler-coupled typed perception is complete for the retained vision,
    audio-window, and temporal-video adapters: each adopts rather than
    re-reserves the receipt, exposes no output before final service, binds the
    exact typed result to that receipt, and returns model/cache ownership to
    zero; and
17. production encoder/container adapters and broader format profiles,
    additional model/materializer profiles,
    retained native Linux filesystem campaigns, separately scoped initial
    power-loss durability, authorized physical playback/display, and quality
    evidence follow.

The transition milestone proves exact reconstruction on the verifying host. It
does not prove historical execution, live resource authority, a physical sink,
external codec/container correctness, or performance.

Every modality uses content identity separate from tenant access, explicit
decoder/preprocessing identity, exact resource admission, and provider wire
observations. See
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md)
and
[Generated-Media External-Format Profiles and Evidence](GENERATED_MEDIA_EXTERNAL_FORMATS.md),
then the [Multimodal Roadmap](MULTIMODAL_ROADMAP.md) for use cases, promotion
gates, and contributor-ready work.

### Production weight paging

The current pager is a mechanics prototype and is not the generation weight
path. The production sequence is:

1. logical page, representation, device, and tier identity;
2. true resident-byte reservations and pins;
3. async fake-backend state machine with cancellation;
4. one CPU projection consuming page views without eager duplication;
5. full generation integration behind an explicit required policy;
6. physical RSS/residency campaigns and corruption tests.

Promotion gate: a real model trace contains load, prefetch, hit, pin, and eviction
events while no full eager representation remains.

### Backend federation

Goal: let a sealed plan select CPU and accelerator capabilities explicitly.

Status: **portable capability fingerprint and deterministic selection
integrated; native Metal binding integrated for readiness and for both
ChildLease and LeaseTree allocation ownership; exact dispatch-lifetime pinning
and per-adapter single-flight async completion delivery plus exact
terminal-command-error reconciliation integrated; successful execution is
regressed through one hardware-backed Metal composition gate**.
`DeviceCapabilityV1`, canonical inventory entries, plan-bound requirements, and
selection receipts choose a compatible present entry without allocation or
resource/scheduler mutation. Canonical profiles prevent independent aggregate
sets from implying an untested operator/type pairing. The Metal adapter
projects stable device facts into that contract, binds one bounded local
discovery epoch, and revalidates the selected fingerprint and registry identity
immediately before its first Metal resource acquisition and again after the
diagnostic dispatch.
See the
[device capability and selection contract](DEVICE_CAPABILITY_CONTRACT.md).

Completed slices:

- ~~backend capability fingerprint and bounded deterministic selection;~~
- ~~explicit pinned-device and opt-in CPU-fallback decisions;~~
- ~~native Metal capability projection and dispatch-device revalidation.~~
- ~~receipt-bound fake allocation lifecycle with exact live quote replay,
  charge-before-allocate ordering, cancellation rollback, and cleanup
  recovery.~~
- ~~native direct-`MTLBuffer` allocation ownership with exact logical length,
  direct per-resource `allocatedSize` observation, release ordering, and
  generation-fenced slot reuse.~~
- ~~dedicated additive LeaseTree allocation ownership with whole-wave reserve,
  ordered materialization, private FreePermit recovery, sibling-scope
  isolation, native Metal composition, and cancellation rollback.~~
- ~~bounded exact object-set dispatch pins with private Bank permits,
  sealed pre-Bank intents and exact abort, callback/source validation,
  terminal-evidence completion, private post-Bank adapter settlement, release
  fencing, out-of-order settlement, and a real four-buffer Metal dispatch
  checked against a CPU oracle.~~
- ~~adapter-authorized Metal pre-submit outcomes for one generation-fenced
  request-root-bound attempt: pure cancellation or deterministic
  geometry/length/role rejection, zero submission/backend/output roots, zero
  GPU command submissions, shared private settlement, and exact replay
  tombstones.~~
- ~~single-flight Metal async completion delivery per adapter with
  pointer-free `MetalAsyncDispatchTicketV1`, exact submit replay, separate
  poll/wait, pending as nonterminal, native command-plus-four-buffer retention,
  completed-command/snapshot/output-role binding, exact native finalization
  only from private post-Bank settlement, and sticky nonterminal
  `MetalAsyncDispatchQuarantineV1`.~~
- ~~exact terminal-command-error reconciliation from one retained
  `MetalAsyncDispatchQuarantineV1`: pointer-free failure roots authorize core
  `terminal_failure`, Bank settlement precedes exact native `.error`
  finalization and private clearing, and ambiguity/unknown remain sticky.~~

Next slices:

- optional reserve/materialize/settle accounting when the post-creation
  `MTLResource.allocatedSize` observation rather than logical resource length
  must be charged;
- separate physical residency authority and evidence;
- physical device-loss inspection and safe recovery;
- a build-isolated native Metal fault/race harness that records physical and
  injected completion facts separately and exports no test hooks in production;
- general quarantine clearing, fresh selection under a new receipt, and
  explicit migration policy;
- deterministic partition plan;
- transfer ownership and cancellation;
- per-backend numerical contract;
- heterogeneous failure rollback;
- multi-slot queue scheduling and multi-GPU partitioning;
- direct residency and telemetry;
- additional GPU backends and retained native OS/device matrices; and
- performance evidence under declared campaigns.

The selection receipt still grants no allocation, queue, dispatch, residency,
or publication authority. The fake coordinator tests prove deterministic
lifecycle/accounting semantics. The Metal gate owns real resources through
both the receipt-bound ChildLease and execution-owned additive LeaseTree paths
inside its exact adapter context. Its pinned-dispatch case binds four exact
objects to one adapter-owned async slot and prevents release until settlement.
Submit returns `MetalAsyncDispatchTicketV1`; poll/wait retain pending as
nonterminal, and exact output publication requires the matching command,
submission binding, completed snapshot, and output role. Core consumes the
private Bank pin before the callback exact-finalizes the native record.
Ambiguous, unknown, invalid, or command-error observations first retain sticky
`MetalAsyncDispatchQuarantineV1` without core terminal evidence. One exact
retained command-buffer `.error` can then authorize a matching core
`terminal_failure`; quarantine, pin, charge, buffers, and native command remain
live through Bank settlement, after which the private callback exact-finalizes
the same `.error` record and clears private state. Ambiguity, unknown, and
invalid completion remain sticky. This is not physical device-loss detection
or automatic migration. The native backend may own commands for distinct
buffer sets concurrently, so the single-flight claim is per adapter rather
than a global queue-depth limit.

The separate pre-submit branch binds the pin request to an adapter-issued
generation-fenced request over the canonical Metal attempt. A valid preflight
may proceed to native submission, or cancel purely from sealed
lease/request/intent/pin evidence. A malformed attempt may inspect the native
device and resources before deterministic rejection but constructs and submits
no command buffer. Both pre-submit outcomes set `submission_sha256`,
`backend_completion_sha256`, and `output_sha256` to zero and settle through the
same private callback after core consumes the Bank pin. That callback clears
adapter state and records the replay tombstone; public acknowledgement is
compatibility verification only. These paths do not establish physical
residency, physical device-loss inspection/recovery, general quarantine
clearing, fresh selection, migration, multi-slot scheduling, or transfer
ownership. The LeaseTree
coordinator shares address-stable tree and publication-sequence pointers with
its surrounding owner; that owner must externally serialize coordinator calls
with every other mutation of those shared values.
Cross-compilation remains source/build evidence rather than native device or
operating-system support. See
[Device Allocation Lease V1](DEVICE_ALLOCATION_LEASE.md),
[LeaseTree Device Allocation](LEASE_TREE_DEVICE_ALLOCATION.md),
[Device Dispatch Lifetime](DEVICE_DISPATCH_LIFETIME.md), and the
[native Metal adapter](NATIVE_METAL_ALLOCATION.md).

The portable Zig fake-adapter/state tests and independent Python oracle are
deterministic contract models; they open no device and execute no GPU work. The
native macOS gate opens a real `MTLDevice`, creates and inspects real
`MTLBuffer` resources, and makes the valid branch submit through the async
adapter, wait for exact completion, bind the output to that command snapshot,
settle Bank ownership before native finalization, and pass a CPU oracle. Its
rejection and cancellation branches keep the same real context and resources
but intentionally submit zero GPU commands. These are correctness and lifetime
results, not performance claims. Exact terminal-error roots, mutation
rejection, and pre-settlement retention are covered by pure Zig and independent
Python mirror tests; the native gate remains a successful-command regression
and does not induce or claim a hardware or driver error.

## P2 — Serving and isolation

### Multi-tenant LaneWeave

- bounded admission under mixed deadlines and weights;
- exact cancellation and retirement under load;
- per-tenant ResourceBank roots;
- long-run fairness and starvation campaigns;
- overload behavior that remains deterministic and observable.

### Tenant-safe immutable page store

- content identity separated from access authority;
- tenant-scoped capabilities and provenance;
- corruption quarantine and repair;
- bounded cache eviction and reference accounting;
- optional encrypted-at-rest adapter outside the core identity.

## P3 — Future ecosystem primitives

These tracks define how Glacier can grow beyond a single-process inference
runtime without turning every integration into trusted in-process code. They are
ideas unless a different status is stated.

| Track | Status | Ecosystem outcome |
| --- | --- | --- |
| Semantic Model Capsule | Idea | Stable operator/tokenizer/adapter meaning independent of source tensor names |
| Capability Grant | Prototype (resolver scope) | Least-authority extensions for planners, tokenizers, stores, tools, and transports |
| ToolTxn and ActionOutbox | Prototype (process-local transaction, portable outbox record/recovery, descriptor-relative POSIX durable store, and bounded same-process fake dispatch/status authority; live external dispatch gated) | Recoverable AI tool execution with stable idempotency and explicit ambiguous outcomes |
| ModelTxn | Idea | Atomic model/adapter hot swap without split model/KV/output state |
| Object Fabric | Prototype (durable payload bytes and logical ownership reacquisition; in-memory object lifecycle) | Tenant-safe content-addressed model, plan, KV, continuation, media, and evidence objects |
| Media Capsule | Idea (gated) | Typed image, audio, and video identity with explicit decode/preprocess meaning |
| MediaTimeline and MediaTxn | Integrated model-free fixture, scheduler-coupled final-quantum transaction sidecar, bounded stream, post-restore materialized successor, six-object input checkpoint, typed vision/audio/temporal-video fixtures, exact cross-modal result links, atomic generated image/audio/video checkpoint, exact eight-object encoded-payload archive, bounded multi-output registry archive, separately bound deterministic producer-transition evidence, validated bounded PNG/WAVE/APNG profiles, and an integrated additive two-generation format sidecar with optional read-only inspection; production-model/general-format support gated | Exact sample/frame position, per-buffer execution, retained-output/cache rebinding, image/audio/video processor progress, materialized temporal-cache accounting, typed media embeddings, cross-modal lineage, integer synchronized watermark, complete previous-or-successor generated output plus ordered multi-output payload visibility, and strict lossless delivery identity |
| Federated Execution Mesh | Idea | Deterministic ownership across local, accelerator, edge, and remote workers |
| Local/Provider Work Router | Idea | One budget and settlement plane across local computation and external tokens |
| Privacy Budget Capsule | Idea | Explicit data-use, retention, redaction, and export authority attached to work |
| EnergyQoS | Idea | Scheduling under measured energy/thermal budgets as well as latency |
| TraceTwin and Evidence Registry | Idea | Causal replay and promotion decisions bound to immutable evidence |

### Semantic Model Capsule

Goal: describe operator graph, tokenizer behavior, adapters, tensor semantics,
numerical policy, and representation lineage without coupling execution to one
converter's tensor names.

First slices:

1. tiny normalized operator IR for one supported fixture;
2. canonical model/tokenizer/adapter root;
3. source-to-semantic mapping with duplicate/missing-role rejection;
4. backend capability negotiation against semantic operators;
5. migration record when a semantic schema changes.

Promotion gate: two independently produced source artifacts with the same
declared semantics generate the same canonical identity and checked output, while
any operator/tokenizer/adapter drift rejects before allocation.

### Capability Grant and isolated extensions

Goal: let community extensions request only named authority such as read-model,
resolve-object, count-wire-tokens, execute-transport, publish-evidence, or invoke
one tool.

Current slice: `GrantV1` implements a local, digest-bound `resolve-object`
authority for one capsule and tenant, including stale epoch and resource limits.
It is supplied by a trusted caller and is not yet a general extension protocol
or authenticated cross-process credential.

First slices:

1. versioned capability vocabulary with resource ceilings;
2. deterministic negotiation and denial transcript;
3. process-local fake extension with no ambient filesystem/network access;
4. revocation, timeout, crash, and stale-grant handling;
5. optional process/sandbox transport with identical semantics.

Promotion gate: undeclared capability use is impossible through the extension
API, denial leaves no resource mutation, and every accepted use is bound to the
request and evidence chain.

### ToolTxn and ActionOutbox

Goal: connect model-selected tool actions to explicit policy, durable
idempotent intent, and honest ambiguous-outcome handling. External effects
cannot be rolled back like KV, so the state machine must represent prepared,
dispatch-uncertain, reconciled, terminal, and separately compensated outcomes.

Current slices:

1. integrated pointer-free proposal, schema identity, policy decision, and
   bounded process-local transaction;
2. integrated portable ActionOutbox header, body/footer records, stable remote
   request and payload identities, acknowledgement/reconciliation record
   classes, safe-retry transition, separately authorized compensation child,
   and all retained recovery cuts from the complete header onward;
3. integrated descriptor-relative POSIX storage with advisory locking,
   semantic preflight, ordered body/footer sync, exact snapshot/lease/repair
   roots, explicit repair/reacquisition, independent deterministic matrices,
   and a 49-process-death host campaign;
4. integrated credential-free pointer-free adapter evidence, durable-intent
   ordering driver, and bounded fixed-storage same-process fake authority:
   only an atomic `not_applied_fenced` result for generation `G` permits the
   existing safe-retry transition, delayed dispatch through `G` rejects, and
   the next attempt is exactly `G + 1` with the stable request unchanged;
5. next: live provider/tool adapters with real credential handling, service
   restart persistence, and an optional OS-isolated transport;
6. terminal output publication that cites the durable action receipt.

The current fake authority performs no network, provider, or tool effect. Its
opaque context keeps credentials out of portable evidence, but does not provide
an OS sandbox, hostile-process security proof, cryptographic origin, or
service-restart persistence. W4b-d adds no new process-death, platform,
performance, or external exactly-once evidence.

Promotion gate: with an adapter that enforces the stable idempotency key and
authoritative status lookup, process termination at every phase never grants an
unsafe retry, never publishes an unverified action as successful, and
preserves enough state to reconcile ambiguity without exposing credentials.

### ModelTxn

Goal: stage a new model or adapter set, validate its semantic and execution
capsules, migrate or pin sessions, then atomically publish the active generation.

First slices:

- immutable active-model generation handle;
- staged load with complete ResourceBank claim;
- compatibility decision for existing continuation/KV objects;
- commit/rollback race tests;
- mixed-generation request rejection;
- evidence-bound retirement and garbage collection.

Promotion gate: no request observes a model/adapter/KV combination that was never
committed, and rollback releases every staged resource.

### Object Fabric

Goal: reuse immutable model, plan, KV-prefix, continuation, adapter, and evidence
objects through content identity while keeping access authority tenant-scoped.

First slices:

- ~~typed object key `(tenant_scope, kind, ABI, digest, length)`;~~
- ~~capability-bounded resolver for `ContinuationCapsule`;~~
- ~~fixed capsule bundle manifest and independent parser;~~
- ~~tenant-scoped immutable fake store with admitted put/get and no ambient I/O;~~
- ~~reference counts, bundle provenance, and quarantine state;~~
- ~~lease/generation fencing and target/reason/source-scoped repair admission;~~
- ~~retained retirement plus exact reachability and dry-run collection evidence;~~
- ~~separately scoped sweep prepare/abort with plan regeneration and no free;~~
- ~~destructive sweep commit with exact allocator/accounting evidence;~~
- ~~fixed sweep body/footer evidence format;~~
- ~~pure anchored recovery classification over record streams;~~
- ~~snapshot-bound sweep writer/repair contract and deterministic crash model;~~
- ~~descriptor-relative POSIX file adapter and subprocess recovery across every
  publication and repair crash point;~~ complete on the macOS host;
- ~~exact pre-mutation receipt preview plus file publication before
  deallocation and idempotent old/new snapshot recovery;~~ complete for the
  in-memory payload store with an injected post-publication boundary failure;
- ~~native durable payload-byte snapshots and process-death recovery across
  reclaim-plan and copy-on-write promotion phases;~~ complete on the macOS host
  with independent Python verification;
- ~~canonical durable ownership plan plus fresh-epoch ResourceBank/LeaseTree
  reacquisition without same-Bank duplication;~~ complete as a model-free
  prototype;
- ~~paged-KV generation and page-map restore under reacquired ownership;~~
  complete as a model-free actual-cache prototype;
- ~~sampler/RNG/output composition and end-to-end visible restart;~~ complete
  as a model-free natural-exit two-process proof;
- ~~atomic whole-checkpoint promotion and crash recovery at every durable
  phase;~~ complete for the model-free seven-phase root-switch campaign;
- uninterrupted/resumed production-model equivalence fixture;
- native Linux filesystem campaigns across evidence and payload transitions;
- trusted replica transport with independently verified fetch evidence;
- optional encrypted storage adapter whose ciphertext identity is separate from
  semantic content identity.

Promotion gate: cross-tenant lookup never follows content equality alone, live
leases survive collection, corrupt objects cannot enter execution, and measured
deduplication savings include metadata and cache overhead.

### Federated Execution Mesh

Goal: assign plan fragments to CPU, accelerator, edge, or remote workers using
capability, resource, deadline, and evidence contracts rather than backend names.

First slices:

1. worker capability capsule and liveness epoch;
2. immutable fragment ownership plan;
3. transfer object with source/destination resource handoff;
4. deterministic timeout and reassignment without duplicate publication;
5. partial-result quarantine and heterogeneous numerical verification;
6. network-credit admission integrated with ResourceBank.

Promotion gate: worker loss, replay, reordering, and partition cannot publish a
token twice or lose ownership accounting; a single-node path remains available
without distributed overhead.

### Local/provider work router

Goal: choose local execution, external execution, or a verified composition under
one request identity, quality policy, latency deadline, privacy grant, and cost/
resource ceiling.

First slices:

- canonical `WorkIntent` shared by local and external paths;
- comparable logical token/work and monetary quote units without converting
  unknown values to zero;
- deterministic fake-route decision and fallback state machine;
- cancellation and ambiguous remote-attempt reconciliation;
- one terminal output authority across all attempted routes;
- paired quality/latency/cost evidence per route envelope.

Promotion gate: retries or fallback never duplicate a user-visible response or
double-count settled cost, and private work cannot cross into a route lacking the
required privacy capability.

### Privacy Budget Capsule

Goal: attach explicit data categories, redaction policy, retention, geographic or
tenant boundary, logging permission, export permission, and expiry to every work
intent and evidence bundle.

First slices:

- closed vocabulary and fail-closed policy intersection;
- hash-only versus payload-bearing evidence classification;
- retention/expiry event wire;
- provider/extension capability matching;
- deletion receipt that distinguishes logical unlink from physical erasure.

Promotion gate: policy downgrade or missing classification rejects before
payload access, and audit output never claims physical deletion from a logical
ledger alone.

### EnergyQoS

Goal: make energy and thermal budgets schedulable resources alongside memory,
queue, and latency—only on platforms with trustworthy measurement.

First slices:

- read-only sensor adapter with present/missing/denied/stale states;
- energy interval bound to accepted tokens and monotonic time;
- conservative admission using a declared upper bound;
- LaneWeave policy simulation under per-tenant energy budgets;
- drift handling and checked fallback when sensors disappear.

Promotion gate: hardware energy values come from documented sensors, intervals
cover the complete charged work, and missing telemetry cannot become an inferred
savings claim.

### TraceTwin and Evidence Registry

Goal: reproduce the causal plan/admit/execute/fallback/publish path from portable
events and allow runtime policy to select only configurations with retained
passing evidence.

First slices:

- versioned causal event vocabulary;
- independent state-machine replay;
- immutable evidence envelope for binary, dependencies, model, workload,
  machine, raw samples, and statistical policy;
- registry query returning exact passing scope, not a transferred general claim;
- expiry/revocation when code, model, driver, or machine policy drifts.

Promotion gate: mutation, truncation, reordering, foreign evidence, and expired
scope reject; replay reaches the same committed roots without requiring private
payload text.

## Research tracks

### Prism progressive precision

Exact bitplane decomposition and scalar oracles exist. Dense progressive layouts
did not meet their feasibility gates, so broader runtime integration is paused.
Only a bounded storage or kernel result that clears the stop rules should reopen
the track. See [Prism Decode](PRISM_DECODE.md).

### Sealed DecodePlan

Static work, layout identities, scratch requirements, and compatibility checks
are moving toward an immutable prepared plan. Current pieces are experimental and
do not yet form a stable public ABI. See [Sealed DecodePlan](SEALED_DECODE_PLAN.md).

## Measurement roadmap

The W5a machine-observation foundation now retains fixed host metric records,
explicit availability, stable source identity, per-event provenance, nonzero
unavailable-reason identity and no present-reason identity, a sample-clock
identity for every observation, a value-clock identity only for present
time-valued metrics, fail-closed
pre-admission, and post-run contamination. Its domain checks require logical
CPU count at least one and allow physical temperature below zero only down to
absolute zero. It does not directly
prove CPU temperature, effective frequency, performance/efficiency core
residency, package energy, or device telemetry on every platform.

The macOS Metal readiness implementation narrows one device gap: its native
hard gate performs one fixed 37x64 INT4 dispatch and checks registry identity,
`currentAllocatedSize`, command-buffer timestamps, ownership, correctness,
fallback, and artifact composition. It is diagnostic-only, with
`recommendedMaxWorkingSetSize` retained as capacity context and all other
utilization/residency/queue/thermal/frequency/power/energy metrics unsupported.
No addressable native result is retained yet, and the self-asserted live report
has composition/corruption verification rather than cryptographic
authentication. W5b remains open.

The Stage-5 device capability slice separately binds stable Metal facts to a
portable capability fingerprint, one local discovery epoch, and the dispatch
device registry identity. Dynamic allocation, residency, queue depth, and
all utilization/thermal/frequency/power/energy fields remain observations and
are not inferred from the fingerprint. The corrected asymmetric tiled FP16
matmul path is CPU-oracle-tested correctness evidence only; it adds no latency,
throughput, utilization, or native support claim. See
[Device Capability and Selection](DEVICE_CAPABILITY_CONTRACT.md).

Priorities:

1. direct read-only platform adapters preserving
   present/missing/denied/unsupported;
2. paired randomized execution with cooldown and load gates;
3. physical memory and device-residency evidence;
4. energy and thermal capture where trustworthy APIs exist;
5. native Linux, Windows, and FreeBSD observation campaigns; and
6. reproducible public artifact bundles with independent verification.

### Fair paired campaign contract

Any paired runtime campaign must hold or explicitly model these variables:

- exact model and tokenizer bytes, prompt/token input, output contract, seed, and
  requested token count;
- compiler optimization, architecture, backend/device policy, thread count,
  affinity, process priority, and memory limits;
- power source, low-power mode, charger state, foreground/background processes,
  warmup, cooldown, and pre-pair system load;
- randomized or balanced pair order in the same machine session;
- correctness/quality, timeout, thermal, load, and telemetry validity gates fixed
  before observing results;
- raw TTFT, prefill, decode, ITL, end-to-end, RSS, device memory, transferred
  bytes, and energy values only when their observers are available;
- rejected pairs with reasons, not silent deletion.

MachineEnvelope v2 work items:

1. host capability report generated before either arm is named;
2. symmetric process-tree observer outside both arms;
3. charger/power and low-power-state adapters;
4. CPU effective-frequency and core-residency adapters where supported;
5. device allocation/residency and unified-memory pressure adapters;
6. signed monotonic interval and observer-loss events;
7. schema validator that prevents a campaign from claiming an unavailable
   physical metric.

Promotion gate: a same-machine result remains scoped to its exact matrix;
multi-platform wording requires independent machines, workloads, and retained
artifacts rather than repeated samples from one host.

## How roadmap work merges

Each pull request should advance one row by one observable step. A roadmap issue
must name:

- the current and target status;
- the smallest mergeable slice;
- success and rejection tests;
- evidence or artifact retained;
- claim boundary;
- rollback or stop condition.

Prepared-text handoff work is intentionally split into contributor-sized
targets: a generation-one source recovery journal, acknowledged sink-progress
generation, independent manifest/selector verifier, native POSIX crash campaign,
Win32 durable-file adapter, GPU residency/device-loss contract, and repeated
handoff/lease-contention/replay workload. Each can merge independently when its
authority boundary and nonclaims are explicit.

See [Contributor projects](PROJECTS.md) for ready-to-split ideas. Contributors are
also welcome to propose new tracks when they fit the north star and can begin with
a bounded, testable slice.
