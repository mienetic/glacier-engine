<p align="center">
  <img src="assets/brand/glacier-engine-logo.png" width="190" alt="Glacier Engine logo">
</p>

<h1 align="center">Glacier Engine</h1>

<p align="center"><strong>A proof-carrying runtime for local and provider-backed AI execution.</strong></p>

<p align="center">
  <a href="https://github.com/mienetic/glacier-engine/actions/workflows/ci.yml"><img src="https://github.com/mienetic/glacier-engine/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
</p>

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
  vision, audio, temporal-video, dense-tensor reranking, normalized embedding,
  generic dense-tensor classification, and fixed-corpus retrieval adapters
  compute into provisional storage, reject candidate drift, and publish
  source- and ownership-bound typed transactions. The generic tensor fixtures
  retain explicit batch identity plus canonical rank, normalization,
  class-score, or retrieval policy and require no model download. Video
  selection gathers strided frames through explicitly charged scratch and
  scrubs it on return.
- **[Tenant-filtered exact retrieval](docs/DENSE_TENSOR_RETRIEVAL.md).** One
  immutable index artifact binds a
  bounded corpus, visibility map, normalized Q30 matrix, and generation. Each
  one-row query filters visibility before a checked `i128` flat scan, publishes
  only deterministic top-k hits, and binds every result to the exact index,
  query, policy, and corpus order. This is a conformance fixture, not an ANN
  engine or relevance claim.
- **Inspectable reference compatibility.** A deterministic read-only command
  renders twelve append-only exact-integer fixture profiles as versioned JSON.
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
- **Exclusive fresh-process prepared-text handoff.** The compatibility archive
  retains its five canonical restart objects; the raw-input path adds a sixth
  object carrying the exact package, prepared representation, tokenizer
  evidence, binding, and UTF-8 bytes without native pointers or JSON sidecars.
  One durable selector advances from source-live to source-exited to terminal;
  an exclusive POSIX lease and one-shot activation grant fence the restored
  target, while a receipt-independent terminal semantic compares it with a
  separately retired uninterrupted oracle.
- **Public prepared-text durability composition.** The experimental
  [`prepared_text_durable_runtime`](docs/PREPARED_TEXT_DURABLE_RUNTIME.md)
  Zig surface creates or exactly recovers generation one, advances one source
  transition, or advances one acknowledged target transition per call. The
  same public entry points now drive all 49 retained prepared-text
  process-death boundaries. Its sink-free direct-terminal entry points also
  drive a separate four-boundary real-process-death smoke with fresh recovery
  and a zero-step audit.
- **Installed durable supervisor checkpoints.** The package-aware acknowledged
  command accepts explicit paired POSIX progress/control descriptors from a
  trusted local parent. Fixed challenge-bound frames expose ready,
  source-advanced, and per-target-advanced boundaries without an internal crash
  action. The installed `N=4` golden path grants a clean control, sends real
  `SIGKILL` after source advance and first target advance, then requires exact
  fresh-process resume and immutable terminal retry. See
  [Experimental Durable CLI Supervisor Protocol](docs/EXPERIMENTAL_DURABLE_SUPERVISOR.md).
- **Checked committed-token text view.** `text-run` keeps exact
  `output_tokens` as the canonical output and adds `output_text` only as a
  derived strict UTF-8 view of verified committed `utf8-byte-v1` token IDs.
  Invalid UTF-8 and undisclosed durable output produce `null`; the command
  never inserts lossy replacement characters. This additive JSON field changes
  neither `output_tokens` nor any retained binary wire ABI. The existing
  `text-runtime-golden-path-test` root exercises the staged installed command
  on the same host; it is not production-model, quality, confidentiality, or
  native multi-OS evidence.
- **Read-only committed-output inspection.** The experimental R1k-b3 inspector
  and public filesystem API join one selected prepared-text checkpoint to its
  selected durable sink without taking either writer lease. They accept only
  aligned state or a nonterminal sink exactly one acknowledgement ahead.
  The payload is omitted by default; an explicit disclosure flag renders exact
  token IDs, byte hex, escaped bytes, and strict UTF-8 text only when valid.
  Exposed lineage metadata is not a confidentiality boundary.
- **Bounded unary lifecycle kernel.** The experimental
  [`prepared_text_unary_service`](docs/PREPARED_TEXT_UNARY_SERVICE.md) keeps one
  package-bound prepared model, Scheduler, and Bank alive across multiple
  fixed-output requests. It provides bounded capacity, exact idempotency
  replay/conflict, private cancellation, generation-fenced handles, retained
  owned responses, fail-stop, and zero-ownership close without introducing a
  second execution state machine. The package-aware process-local fixed-output
  CLI is its first compatibility-checked consumer.
- **Bounded loopback HTTP/1.1.** An experimental serial socket adapter exposes
  the one loaded package-bound model through `GET /v1/models` and maps one
  strict UTF-8 `user` message with `stream=false` and `max_tokens` from 1
  through 64 onto the same unary kernel through
  `POST /v1/chat/completions`. Exact idempotency, tenant, and logical-deadline
  headers enter the retained request identity. A retained bounded client owns
  decoded results and validates the model, request, content, token-count, and
  error correlation without redirects or automatic retries. A managed
  child-process lifecycle now supports exact receive-side and admitted-work
  drain cancellation, an optional 1-millisecond-to-60-second monotonic receive
  deadline for partial headers and bodies, reset-detected cancellation between
  drive quanta, response-ready drain cancellation before the first write,
  bounded interruptible response sends, and an optional full-request timeout
  from accept through response retirement with phase-specific outcome evidence.
  Non-loopback serving, authentication, TLS, streaming, orderly-FIN
  abandonment, model-kernel preemption, peer delivery acknowledgement, durable
  restart, and performance evidence remain open.
- **Bounded concurrent transport.** The Phase F1 runtime
  path adds `ManagedConcurrentLifecycleV1`,
  `serveManagedConcurrentListenerV1`, and
  `requestManagedConcurrentDrainAndWakeV1`. Configuration fixes `1..16`
  workers and a `1..64` accepted-connection FIFO, with at most 80 registered
  connection slots. One lifecycle registry and one shared watchdog own queue,
  phase, counter, receive-deadline, and full-request-deadline decisions.
  Queue wait consumes both accept-origin elapsed budgets. When the accepted
  FIFO is full, the acceptor pauses and leaves later peers in the kernel
  listen backlog; the transport does not synthesize an HTTP 429 or 503 before
  request parsing. On POSIX, the serving call temporarily makes the listener
  nonblocking, polls readiness for at most 100 milliseconds per quantum, and
  revalidates lifecycle state before `accept`. Every accepted socket is
  returned to blocking mode before FIFO or worker handoff. Managed receive
  revalidates lifecycle on every readiness-wait iteration, with each quantum
  capped at 100 milliseconds even when the configured timeout is zero, so
  drain and fatal convergence do not depend on cross-thread `shutdown`
  succeeding. An unexpected shutdown error advances no successful signal
  counter or event for that connection and leaves it unclaimed, allowing
  failure convergence to retry and take over. Ownership moves once from
  acceptor to FIFO to one worker; queued retirement or that worker is the sole
  closer for its socket.
  Response control and socket writes run after the serialized
  model-execution gate is released, but model admission and execution remain
  serialized. FIFO therefore describes accepted-queue dispatch only, not
  completion order, scheduling fairness, parallel model execution, or
  performance. Exact high-water, enqueue/dispatch, pause/resume, queued
  retirement, timeout, and phase counters preserve conservation through drain;
  receipt capture and exact-owner application share the lifecycle lock. On
  POSIX, the exact listener flags captured before serving are restored only
  after workers plus the watchdog join and before a stopped lifecycle may
  report zero transport ownership. Fatal convergence uses
  `transport_failure`, emits a `running_failure` event for each newly claimed
  running lease, and keeps its phase-specific counters separate from drain. The
  passing ReleaseSafe command
  `zig build unary-http-test -Dmetal=false -Doptimize=ReleaseSafe -j2` runs four
  deterministic native-loopback scenarios: sibling liveness beside a partial
  request, one-worker/one-pending FIFO pause/resume, exact queued
  accept-origin full-request timeout, and repeated drain over one running plus
  one queued socket. All finish with exact conservation and zero service/Bank
  ownership. A separate callback-order inversion timestamp regression
  deliberately delivers the dispatch observer callback before the enqueue
  observer callback and proves both event timestamps remain ordered by their
  lifecycle-mutex linearization points; it is not a fifth behavior scenario.

  The existing `unary-server-process-test` root also retains four Phase F1
  profiles in native POSIX child processes over real loopback sockets: a
  queued receive timeout while active terminal work completes, followed by a
  healthy successor; a queued full-request timeout followed by a healthy
  successor; simultaneous drain from two callers over one active receive plus
  one queued socket; and stale-owner rejection after a connection slot is
  reused, followed by fail-closed queued/running cleanup. The stale-owner
  profile deliberately corrupts only the retained owner metadata as a
  white-box fault injection; generation-mismatch rejection and cleanup run
  through the production drain and failure paths. Every profile checks exact
  aggregate event/cause conservation, unique contiguous event ordinals, joined
  threads, and final zero connection, Service, Scheduler, and Bank ownership.
  The same executable also retains a serial four-request application-rejection
  profile covering deadline-infeasible Scheduler rejection, successful work,
  service capacity, and non-observed idempotency conflict. It checks canonical
  request digests, Scheduler event identity, managed connection owners,
  callback counts, unchanged rejected-work sequencing, and zero ownership
  without adding an artifact or compile root. The campaign uses real child
  processes and TCP loopback over a generated synthetic tiny-model fixture. It
  is real child-process/native POSIX loopback correctness evidence, not a
  simulation, performance, GPU, or native foreign-OS result.

  The separate manual `unary-server-native-load-test` target reuses the exact
  process-test artifact and compile root. Its default fixed profile runs one
  real native child for 8 warmup plus 64 measured loopback requests across
  eight flows, two workers, and eight pending slots. The independent verifier
  binds executable and machine/boot identity, exact request/work/transport and
  HTTP-response handles, output/terminal/completion roots,
  lifecycle-linearized timestamps, throughput, outcome mix, and final zero
  ownership. Arrival-to-FIFO accept/enqueue, FIFO-to-worker dispatch, and HTTP
  first-positive-read p99 values are completed-request distributions with
  explicit sample counts: 64 for the default profile, 32 for the capacity
  profile, and 16 for the queued-timeout profile. All 64 measured attempts
  remain represented by terminal/outcome accounting.

  The same target and artifact accept
  `-Dunary-server-native-load-profile=retention-capacity-v1` for a second
  72-record profile. Its 8 warmup requests complete, then the measured cohort
  contains exactly 32 completions and 32 HTTP 429 `service_capacity`
  responses. Each of the eight flows retains four of each outcome. A
  profile-specific sidecar plus the embedded Native Workload Report V1 bind
  completed requests to their response and work handles. For each rejection,
  they bind the exact decoded `(request SHA-256, service_capacity,
  same_request_after_backoff, HTTP 429, response byte count)` tuple,
  transport lifecycle, and absence of service work. The sidecar separately
  retains an opaque, domain-separated producer digest of the raw HTTP response
  and a verifier-recomputed semantic root; raw response bytes are not retained
  or reconstructable offline. Its completion root binds both roots, while the
  embedded W6 output root stays zero because no model output exists. The
  service retains exactly 40 terminal records and closes with zero connection,
  active service, Scheduler, and Bank ownership.

  This second profile proves retained-record capacity saturation for the tiny
  serialized CPU fixture. It does not prove transient or general overload,
  queued-timeout behavior, throughput superiority, a
  production-model result, scheduler fairness, GPU evidence, or cross-OS
  evidence. macOS captures may pass the environment publication gate; Linux
  runs remain diagnostic until external CPU-load attribution is available.

  A third selector,
  `-Dunary-server-native-load-profile=queued-receive-timeout-v1`, reuses the
  same artifact for a deterministic closed-loop queue-pressure profile. After
  8 completed warmups, each of 8 measured epochs holds 2 running controls
  while 6 accepted FIFO peers reach their exact 2-second queued receive
  deadline. The measured result is 16 completed and 48 timed-out attempts,
  rotated so every flow retains `2 completed / 6 timed_out`. The verifier
  requires zero response bytes for every timeout, exact enqueue/lease/timeout
  evidence, bounded client settlement, joined cleanup, and zero connection,
  Service, Scheduler, and Bank ownership. This is not explicit open-loop or
  general overload evidence, a generic queue-latency promise, first-token
  latency, physical parallelism, production-model, GPU, or native foreign-OS
  evidence.

  Phase F1 concurrent serving is explicitly unsupported on Windows today: the
  entrypoint returns
  `ConcurrentListenerModeUnsupported` before worker/watchdog startup because it
  cannot prove and restore the caller's original `FIONBIO` mode. Native Windows
  serving therefore remains pending and unproven.
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
- **Acquired durable-directory authority.** POSIX durability paths preflight a
  descriptor-relative, sync-capable directory handle before namespace
  mutation and retain that one owned handle through commit. Operations use
  non-owning borrowed aliases, so the caller may close its original `Dir` after
  acquisition. A failed commit poisons the authority, after which checked
  borrow and commit calls reject while observation and close remain available.
  Real `fsync` and process-death coverage verifies this host protocol; it is
  not a physical power-loss guarantee.
- **Recoverable runtime-image preparation.** The production `.glrt`
  preparation path writes through one acquired parent-directory authority,
  serializes filesystem aliases through one directory-scoped lock, bounds
  debris to one identity-fenced candidate per directory, validates the
  synchronized candidate before replacement, and converges to the exact
  predecessor or successor after process death. Corrupt targets and unsafe
  reserved entries fail closed instead of being silently replaced.
- **Sealed portable-model conversion.** The `glacier convert` command and
  preferred path now plan bounded pages, reuse one aligned transformation
  workspace, and publish through a private synchronized candidate instead of
  truncating the visible `.glacier` target. Strict reopen validation checks
  exact layout, payload geometry, every CRC, and the full container SHA-256
  before replacement. The compatibility API also uses a same-directory
  candidate and file-atomic replacement, but does not inherit the durable
  publisher's locking, synchronization, or recovery guarantee.
  Source/profile/plan/artifact roots are returned in one receipt, while a native
  macOS/Linux real-`SIGKILL` campaign proves exact predecessor-or-successor
  convergence across all eight publication phases. See
  [Sealed Portable-Model Publication](docs/SEALED_MODEL_CONVERSION.md).
- **Verified raw-text ingress.** The experimental `glacier text-run` command
  restricts admission to one retained fixture/license profile, then binds exact
  UTF-8 bytes, a strict no-fallback byte-tokenizer manifest, canonical token
  IDs, prepared image, and Common execution/residency plans before `SessionV3`
  admission. Its deterministic JSON exports canonical wires for independent
  Python reconstruction of the declared identity and Common-plan plus terminal
  result/state relationships, and retirement returns logical ownership to
  zero. The boundary-snapshot root and publication transcript remain opaque
  bound leaves, and the independent gate does not reconstruct the boundary
  snapshot or replay the publication transcript. Ordinary output remains a
  process-local transaction unless package admission also supplies
  `--durable-dir` and `--request-id`; that opt-in selects the sink-free direct
  route for `--n 1` or acknowledged delivery for fixed counts `2..64`.
  Process-local callers may instead add `--eos-token ID`; `--n` then becomes
  an upper bound and successful early completion requires a canonical evidence
  aggregate. Its completed-early sidecar joins the terminal boundary and
  semantic result to the quota-close event; the enclosing evidence also joins
  the final service receipt. EOS exactly at the bound is distinguished as
  `eos_at_limit` and retires without an early sidecar. Durable early EOS is
  deliberately rejected before state mutation. See
  [Verified Raw-Text Runtime Path](docs/PREPARED_TEXT_RAW_INPUT.md).
- **Stable package and recoverable raw-input identity.** A request-independent
  640-byte model package manifest binds portable provenance, resolved geometry,
  explicit model/tensor-profile identities, tokenizer behavior, and the license
  byte count plus SHA-256 identity. A
  256-byte prepared-representation record binds one platform-specific `.glrt`
  image without changing the package root. The durable raw-input archive
  carries the manifest and representation as distinct records, exact
  tokenizer and prompt wires, the plan binding, and original UTF-8 bytes
  through generation-one replay, restart, acknowledged progress, and terminal
  lineage. A fresh CPU process re-tokenizes those bytes before admission; an
  independent Python verifier rejects component and whole-archive mutations.
  The retained recovery evidence is synthetic and POSIX-hosted, not GPU or
  native multi-OS durability evidence.
- **Ordinary model package production and admission.** The experimental
  `glacier package-model` command joins one supported Safetensors source,
  typed same-process durable conversion receipt, validated portable container,
  prepared CPU image, strict byte-tokenizer profile, and exact license identity
  into an 896-byte `.glpkg`: a 640-byte request-independent manifest followed
  by the 256-byte receipt for that exact prepared container. `text-run
  --package` derives the actual GLRT identity and compares it with the embedded
  receipt before admission. Required `--config FILE` uses bounded stable
  regular-file admission and a complete strict typed contract. Required
  `--experimental-profile ordinary-package-v1` selects the narrow capability
  visibly; a same-descriptor preflight rejects unknown names, dtype/rank/shape
  substitutions, missing layers, biases, and extra tensors before any portable
  output mutation. The manifest binds both profile identity and the canonical
  tensor inventory without changing its fixed size. Canonical resolved values,
  rather than JSON formatting, bind package identity. Another representation
  needs another bundle but can retain the same portable package root. The
  command performs no network access. Without durable options, counts `1..64`
  publish token IDs through the process-local path. With durable options,
  `--n 1` uses a
  sink-free POSIX checkpoint and counts `2..64` use acknowledged delivery with
  capacity `N - 1`; both support deliberate fresh-process continuation and
  selector-rechecked committed output. Without durable options,
  `--eos-token ID` enables bounded early completion while preserving the
  fixed-result default. The bundle proves content integrity, not publisher
  authenticity. See
  [Ordinary Model Package](docs/MODEL_PACKAGE.md).
- **Identity-fenced file publication.** A descriptor-relative POSIX adapter
  adds exclusive locking, no-follow lookup, single-link/private-mode checks,
  acquired directory authority, file and directory sync,
  namespace-replacement detection, and six real subprocess-death boundaries
  without adding payload deletion authority.
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
  preserves a byte-identical outer-only view and can optionally replay an exact
  journal header, cost frame, gateway history, and transport history before
  marking their internal cross-wire composition verified. It renders no prompt,
  payload, response, or credential bytes and never grants authority.
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
  W7b-b4 adds a separate in-flight process-death boundary. A build-isolated
  fault shim commits one real registered INT4 command that signals a private
  `MTLSharedEvent` at `1` and waits for `2`. The victim publishes a verified
  512-byte ready frame only while the command is committed or scheduled,
  completion remains unobserved, and four native buffers, one command, and four
  allocation references remain live. The controller then sends real PID-only
  `SIGKILL`, requires status `-9` and exact EOF, and launches a distinct
  production-linked W6 process that completes 20 CPU-oracle-checked real Metal
  commands. The event barrier is controlled and synthetic; the Metal work,
  process death, and fresh control are real. This does not prove active-kernel
  interruption, victim-output recovery, state preservation, or complete driver
  reclamation.
  W7b-b5 adds two control-plane death boundaries to the 12-segment production
  campaign. After the first worker completes segments 0–5 and exits cleanly,
  its supervisor synchronizes generation six, holds the exclusive store lock,
  and publishes a private pre-ready handoff. The controller validates the
  handoff, proves lock contention, and returns a challenge-bound
  acknowledgement before the supervisor emits its public verified ready
  frame. The controller then sends real `SIGKILL` to that supervisor PID only,
  requires exact `-9` and EOF, derives the resume grant, and starts a fresh
  shared-lock auditor whose generation-six frame binds it. The controller
  withholds that grant from recovery until the audit passes. The authorized
  recovery then resumes at ordinal six through a fresh Metal worker, publishes
  through generation
  eleven, synchronizes the generation-twelve
  immutable objects and 192-byte selector temporary, and pauses before active
  replacement. After that worker exits cleanly, the controller repeats the
  real PID-only kill against the recovery process. Only then does it derive the
  finalizer grant for a second fresh recovery, which may perform only the exact
  `11 -> 12` selector roll-forward before a final fresh audit. The 3,520-byte
  outer report binds both ready frames, kill receipts,
  audits, component identities, and least-authority grants and is independently
  verified in Python and Zig. The 1,200 Metal commands, CPU oracles, process
  kills, locks, file/link/replace operations, and `fsync` calls are real; ready
  barriers, kill timing, the publication pause, and grants are controlled.
  Process RSS is a host observation. Metal `currentAllocatedSize` is retained
  only as device-wide allocation context and is not GPU residency, owned
  memory, utilization, or physical-parallelism evidence. The forced restart is
  post-segment, not an in-flight command or physical-device fault. Remaining
  W7b-b work covers the broader supervisor/recovery interruption matrix,
  active-kernel and adapter faults, physical quota/media/device/driver/power
  faults, and native multi-filesystem replication.
  The first retained native machine result is the
  [2026-07-28 macOS arm64 wire](bench/results/native-metal-workload-report-macos-arm64-2026-07-28.bin)
  with its
  [capture manifest](bench/results/native-metal-workload-report-macos-arm64-2026-07-28.manifest.json);
  it is diagnostic evidence for that exact session, not a performance or
  replication claim. See the
  [Native Workload Report](docs/NATIVE_WORKLOAD_REPORT.md),
  [Native Metal Disruption Report](docs/NATIVE_METAL_DISRUPTION_REPORT.md),
  [Native Metal Cancellation-Storm Report](docs/NATIVE_METAL_CANCELLATION_STORM_REPORT.md),
  [Native Metal Segmented Soak Report](docs/NATIVE_METAL_SOAK_REPORT.md),
  [Native Metal Process-Kill Recovery](docs/NATIVE_METAL_PROCESS_KILL_REPORT.md),
  [Native Metal In-Flight Process-Kill Report](docs/NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md),
  and
  [Native Metal Supervisor and Recovery-Process Death Report](docs/NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md).
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
controlled-disruption, cancellation-storm, segmented-soak,
forced-process-restart, in-flight process-kill, fault-settlement, and
correctness gates serially on macOS with:

```sh
tools/zig-with-ephemeral-cache.sh build native-metal-suite-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j1
```

For affected-path verification, `tools/verify.sh` first runs the compile-only
`native-metal-suite-compile` frontier. That root covers every executable and
test consumed by the serialized suite, the cacheable Metal shader library, and
fault-symbol isolation through one explicit consumer inventory. It does not
pull the wider host-tool or device-profile umbrellas into this frontier;
eleven unrelated artifacts therefore stay deferred. Every retained suite
artifact and static check still completes before the first suite device
process starts.
Only after it passes does the verifier enter the separate `-j1` hardware phase
using the same build graph, temporary caches, Metal output directory, and
install prefix. Shared artifacts are therefore compiled once instead of being
rebuilt by independent cold invocations. The focused command above remains
useful when only the native suite is being run.

The focused soak/process-kill gates and serialized suite require two admitted
AC-power, low-power-off, nominal-thermal snapshots ten seconds apart before
each 60-second campaign. Admission must complete within a 180-second monotonic
deadline; each production environment probe is separately bounded. The
campaign then retains its own before/after environment boundaries and does not
cool down or retry a thermal excursion that occurs during native work.

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

Run the focused W7b-b4 in-flight process-kill gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-inflight-process-kill-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-inflight-process-kill-report-output=PATH
```

The victim's private event barrier is fault-shim-only and controlled. The
registered INT4 command, PID-only `SIGKILL`, exact `-9` wait status, EOF, and
fresh production-linked 20-command W6 control are real. Omit the output option
for an ephemeral verified report. See the
[Native Metal In-Flight Process-Kill Report](docs/NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md).

Run the portable W7b-b5 report codec and bounded host protocol without a GPU:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-supervisor-recovery-death-report-test \
  native-supervisor-recovery-death-host-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile the complete W7b-b5 native frontier without launching a device
process:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-compile \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
```

Run the focused W7b-b5 supervisor and recovery-process death gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-metal-supervisor-recovery-death-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2 \
  -Dnative-metal-supervisor-recovery-death-output-dir=PATH
```

Omit the output option for an ephemeral verified run. The first real PID-only
`SIGKILL` follows the clean first-worker reap and synchronized generation six;
the second follows the clean second-worker reap and synchronized prepared
generation twelve while generation eleven remains active. Fresh processes
audit generation six, perform only the exact `11 -> 12` roll-forward, and
audit the final store. See the
[Native Metal Supervisor and Recovery-Process Death Report](docs/NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md).

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
- macOS for the retained native development-host workflow; hosted Linux x86_64
  also runs native correctness and controlled-fault CI gates, while Linux
  AArch64, Windows, and FreeBSD currently have cross-build evidence only;
- Python 3.10 or newer for the dependency-free quick checks; CPython 3.10–3.12
  for the locked full Python suite;
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
quick profile uses Debug compilation to verify formatting, public-document
policy, package imports, and the Zig/C/C++/Python contract chain. Its
compatible Zig roots share one build DAG instead of starting a compiler
process for each gate. During ordinary branch work, use the path-aware fast
tier:

```sh
tools/verify.sh affected-fast --base origin/main
```

The fast tier also uses Debug compilation. It avoids a generic Zig build for
documentation, workflow-control, verification-policy, shell-only, and ordinary
Python-only plans. Audited contract-only and package-module-only changes select
just their matching host root; mixed changes still share one invocation.
For an isolated `build.zig` or `build.zig.zon` change, it evaluates the graph
with `zig build --help` only and compiles no runtime artifact. A mixed change
still runs any focused runtime roots selected by its other paths. Broad
ReleaseSafe, Python, Metal, and retained-target gates remain manual `affected`,
`full`, `matrix`, or tagged-promotion work.
Focused prepared-text gates remain selected when relevant, and broad host,
Python, and foreign-target work is reported as explicitly deferred. Package
producer, package-aware `text-run`, bounded-input, and
variable-terminal Zig changes reuse the existing
`text-runtime-golden-path-test` DAG. Package/raw-input Python oracle changes
retain that CLI-backed comparison. Changes limited to either exact Python test
run only the two matching unittest modules and start no Zig build.
Complete affected verification cross-compiles those Zig paths through the
existing CLI-only `text-runtime-golden-path-compile` root. Bounded unary-service
changes run only `unary-text-service-test`; retained-target verification uses
its compile-only companion instead of the broad model-forward suite. Unary HTTP
contract, client, and focused acceptance changes run `unary-http-test` once;
complete affected verification cross-compiles only `unary-http-compile`.
Shared server adapter/API changes select `unary-http-test` and
`unary-server-process-test` without the service-only root. Process-acceptance
fixture changes alone run only `unary-server-process-test`, with
`unary-server-process-compile` reserved for retained-target compile evidence.
The Phase B receive-drain, Phase C monotonic
receive-timeout, Phase D admitted-work drain, and Phase E1
reset/response-ready cases reuse that same dual-mode executable and those same
targets; they add no compile root. A unary-kernel implementation change selects
the service, HTTP, and managed-process roots. All selected host roots share one
Zig invocation. When the CLI changes, its selected focused roots likewise
share that invocation. If a change set also needs the generic package/contract
roots, those roots join it. Ordinary pull requests and `main` pushes run only
the bounded Debug `affected-fast` plan. Complete affected, exhaustive,
retained-target, and hardware work remains an explicit manual, tagged-release,
or milestone promotion gate.

Dense-tensor focused verification uses one Zig test artifact behind the
`dense-tensor-family-test` root and its production-only
`dense-tensor-family-compile` companion. The existing reranker, embedding, and
retrieval test, compile, and demo names remain compatibility targets backed by
the shared compiled artifacts; the focused reranker/classifier, embedding, and
retrieval routes keep distinct independent oracles. Adapter-core changes also
select the runtime-support inspector, while Python-test-only tensor, embedding,
and retrieval changes select their exact unittest modules independently.
`affected-fast` selects the family root for embedding, classifier, and
retrieval paths.

Complete affected verification uses the main `install test-compile` closure
for general core, CPU, and model changes. Bulk benchmark staging and the
standalone benchmark consumer closure run when benchmark or build inputs
change and at the deliberate matrix/release gate, rather than on every
main-runtime change. Device diagnostics already owned by `test-compile`
remain in the main closure.
Variable-terminal changes use the text-runtime host DAG, and prepared-session
lifecycle changes run the unary acceptance root in that same invocation, then
select only the CPU, durable, and CLI-only text-runtime portability profiles
when the complete affected tier is requested. In a clean environment, install
the hash-locked binary dependency before selecting the full profile:

```sh
python3 -m pip install --only-binary=:all: --require-hashes \
  -r bench/requirements-test.txt
tools/verify.sh full
```

The full profile switches to ReleaseSafe and adds the broad native and Python
suites plus the optional Rust gate. It compiles the complete host test and
contract frontier through `host-runtime-compile` first; runtime tests start
only after that compile-only gate succeeds, and their compatible roots likewise
share one Zig DAG.

All Zig invocations in one verifier run reuse the same private local and global
caches. Clang, Swift, and Metal compiler module caches are rooted in that same
temporary workspace rather than a user-level cache. The verifier removes those
caches, logs, prefixes, and generated Metal products on handled exit, which
bounds disk growth without giving up reuse between its compile and runtime
phases. Foreign targets remain separate because each target has a distinct
build configuration, but all selected roots for one target are compiled by one
target-specific invocation.

Hosted CI may reuse only the pinned Zig setup action's exact cache path. It
soft-prunes affected-job caches above 900 MiB and exhaustive/Metal caches above
1,800 MiB, before the action's 1,024/2,048 MiB hard limits. This does not enable
a persistent local project cache: contributor runs keep their cache in the
temporary verifier workspace and remove it on exit. A hosted build that
encounters the exact adjacent restored-archive diagnostic for
`.zig-cache/o/<hash>/libcompiler_rt.a` preflights and resets only that validated
cache, then retries the unchanged build once. This recovery belongs to the
affected/exhaustive verifier jobs and is limited to one attempt across their
run; ordinary compiler failures remain final.

Build the portable CLI and run one deterministic, model-free publication demo:

```sh
zig build -Doptimize=ReleaseSafe -Dmetal=false
./zig-out/bin/glacier --version

zig build lane-publication-demo -Doptimize=ReleaseSafe -Dmetal=false
```

For the currently supported experimental ordinary-model profile, package a
local Safetensors source and admit that exact package into the CPU text path:

```sh
./zig-out/bin/glacier package-model \
  source.safetensors out.glacier out.glrt out.glpkg \
  --license LICENSE \
  --config config.json \
  --experimental-profile ordinary-package-v1 \
  --group-size 64

./zig-out/bin/glacier text-run out.glrt \
  --text "Hello" --license LICENSE --package out.glpkg --n 4

mkdir -m 700 /tmp/glacier-package-run
./zig-out/bin/glacier text-run out.glrt \
  --text "Hello" --license LICENSE --package out.glpkg --n 4 \
  --durable-dir /tmp/glacier-package-run \
  --request-id 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

The command performs no network access. The `.glpkg` file is a fixed 896-byte
admission bundle containing a 640-byte portable/request-independent manifest
and the 256-byte receipt for the exact GLRT container. It is not a model archive
or proof of publisher authenticity. Without durable options, counts `1..64`
remain token IDs in a process-local transaction. With durable options, count
one uses the sink-free generation-one-to-two route and counts `2..64` use the
acknowledged route with capacity `N - 1`; both can continue generation one in
a fresh process and render checked committed output. Choose and
externally retain a new request ID for each logical request; reuse it only for
continuation or retry, with one initially empty private state directory per
request. A selected directory has no in-place reset command. Its default report
omits the token payload, but exposed digest metadata is not confidential.
Producer JSON reports `package_bytes=896`,
`package_manifest_bytes=640`, `prepared_representation_bytes=256`,
`prepared_representation_embedded=true`, and
`prepared_representation_separate=false`. It reports the required explicit
profile/config identities, exact admitted tensor inventory, raw config-input
provenance, and canonical resolved-config root. `--config` and
`--experimental-profile ordinary-package-v1` are required; no ambient sidecar
is read. See
[Ordinary Model Package](docs/MODEL_PACKAGE.md) for the exact binding,
safe-input boundary, and current nonclaims.

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

Run the download-free generic classifier through the existing dense-tensor
demo executable:

```sh
zig build dense-tensor-reranker-demo -Dmetal=false -- classify
```

It computes an exact row-major `i16 × i8 → i64` class-score matrix under stable
batch and class maps, no normalization, descending score order, and
class-ordinal tie breaking. The retained profile is bounded to `B <= 64`,
`F <= 4096`, and `C <= 256`. It supplies deterministic contract and lifecycle
evidence, not probabilities, labels, production quality, GPU or native
multi-OS support, performance, or provider-token reduction. See
[Dense-Tensor Classifier](docs/DENSE_TENSOR_CLASSIFIER.md).

Inspect one 712-byte provider evidence join as deterministic JSON without raw
prompt, payload, response, or credential bytes:

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --join path/to/provider.join
```

That outer-only invocation verifies only framing and checksum, preserves the
original byte-identical report, and emits `composition_verified:false`. To
replay every nested record and require exact cross-wire equality, add the
all-or-none composed inputs:

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --join path/to/provider.join \
  --journal-header path/to/provider.journal-header \
  --cost-frame path/to/provider.cost-frame \
  --gateway-events path/to/provider.gateway-events \
  --transport-events path/to/provider.transport-events
```

The header and frame must be exactly 144 and 1,645 bytes. Each variable gateway
or transport file must match the join and is capped at 8 MiB. The stronger route
emits `composition_verified:true` only after nested replay and canonical join
equality. `authority_granted` is always false, and neither mode establishes
authenticity, historical provider execution, billed-usage or billed-cost truth,
confidentiality, or trust. The mode reuses the existing executable, evidence
wire ABI, and focused `provider-evidence-inspector-test` root. See
[Provider Evidence Inspector](docs/PROVIDER_EVIDENCE_INSPECTOR.md).

Inspect one selected prepared-text checkpoint/result-sink view without taking a
writer lease or disclosing output:

```sh
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --directory path/to/prepared-text-state
```

Add `--reveal-output` only when exact token IDs and bytes may be disclosed.
Strict UTF-8 text is emitted only when the visible bytes validate; otherwise
the text field is `null`. Default digest and lineage metadata can still
correlate low-entropy output and is not confidential. This diagnostic command
is separate from ordinary `text-run` and future serving output. See
[Prepared-Text Result Inspector](docs/PREPARED_TEXT_RESULT_INSPECTOR.md).

The C ABI is a narrow verifier and support-query surface, not a stable
inference SDK. See
[Language interop](docs/LANGUAGE_INTEROP.md) for C, Python, and dependency-free
Rust instructions, and
[Runtime Support Registry and Inspector](docs/RUNTIME_SUPPORT_INSPECTOR.md) for
query semantics, fixture authoring, and explicit nonclaims.

Run the broad verification suites when working across the whole repository:

```sh
python3 -m pip install --only-binary=:all: --require-hashes \
  -r bench/requirements-test.txt
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
| Text terminal lifecycle | Fixed-result process-local execution remains the default; opt-in `--eos-token` makes `--n` an upper bound and returns independently checked completed-early evidence on an EOS hit | Carry the same variable terminal semantics through durable recovery and retry, then expose them through unary/streaming serving |
| AI runtime | CPU execution, an optional macOS Metal kernel path, sealed POSIX publication for portable `.glacier` conversion, recoverable POSIX publication for prepared `.glrt` images, typed family/operation contracts, a Common Model Contract bridge for eligible serial text request profiles, an ordinary Safetensors package producer with a fixed 896-byte admission bundle containing a request-independent 640-byte manifest and embedded 256-byte exact prepared-representation identity, exact canonical UTF-8 byte-tokenizer and raw-input binding wires, package-aware user-model admission for process-local output plus checked fixed-output durable `text-run` routes: sink-free direct for count one and acknowledged for counts `2..64`, durable retention and fresh-process re-tokenization of the exact raw-input archive, exact total-versus-request logical claim projection for shared read-only artifact residency, V2 boundary evidence, a single-seal fixed-length terminal `ResultEnvelopeV1`, canonical non-terminal prepared-state capture, same-process exact-current-boundary rebind, canonical successor evidence, receipt-funded restored activation at sequence `N`, an experimental fresh-process source-exit handoff with canonical generation-one replay, one-token-per-target acknowledged progress through an idempotent durable local POSIX sink and generation-five terminal result, public one-step bootstrap/source/target durable-runtime APIs used by the retained 49-boundary campaign, a sink-free direct-terminal generation-one-to-two path for fixed output count one with a separate four-boundary real-process-death smoke and independent decoder, a concrete durable store accepting runtime acknowledgement capacities `0..63` without per-capacity production-runtime monomorphization, public read-only committed-output filesystem APIs, metadata-first R1k-b3 inspection, a bounded transport-neutral unary lifecycle, an experimental bounded loopback JSON HTTP/1.1 adapter and retained client, and R1k-b8 Phases A-D plus Phase E2b managed child-process lifecycle evidence with a completion-admission drain gate, a generation/sequence/handle-fenced active-connection lease, receive-side drain cancellation, a bounded monotonic pre-admission receive deadline with separate timeout evidence, a sequence/full-handle-fenced admitted-work lease with exact drain cancellation and separate work-cancellation evidence, reset-detected cancellation between drive quanta, response-ready drain cancellation before the first write, bounded interruptible response sends, an accept-origin full-request deadline through response retirement with exact timeout evidence, malformed-peer survival, same-child liveness after timeout or reset, same-package fresh restart, and zero-ownership close; the Phase F1 implementation adds a fixed-worker concurrent transport, bounded accepted FIFO, passive accept backpressure, one registry/watchdog, exact queue conservation, and response writes outside the still-serialized model-execution gate, with four deterministic same-process native-loopback scenarios retained in `unary-http-test` and four native POSIX child-process correctness profiles retained in `unary-server-process-test` covering queued receive and full-request deadlines, simultaneous drain, exact slot reuse, stale-owner rejection, fail-closed queued/running cleanup, event/cause conservation, joined threads, and final zero connection, Service, Scheduler, and Bank ownership; exact-cause post-parse application-rejection observations with Service-validated Scheduler event identity and managed owner decoration are retained in the same unary roots; plus a canonical exact-integer dense-tensor reranker, portable exact Q30 L2 dense embeddings, an exact class-score matrix classifier, tenant-filtered exact fixed-corpus retrieval, exact admission/scheduling/publication, continuation, provider and media planes, an experimental allocation-free C verifier, and a deterministic twelve-profile retained-reference compatibility inspector | Run the separate native-load campaign next. Orderly-FIN abandonment requires an explicit policy; model-kernel preemption, crash-aware durable recovery, committed-token streaming, and bounded EOS serving remain open. Extend ownership/accounting and repeated-handoff coverage, add exhaustive storage/power-loss evidence, broaden tokenizer/model/package/GPU profiles, bind exact retrieval candidates to optional reranking, add production fixtures and non-POSIX native evidence, and broaden production device execution |
| Serving | Experimental package-bound process-local unary kernel with fixed capacities, retained idempotency records, hidden partial output, cancellation, stale-handle fencing, fail-stop, and zero-ownership close; a serial loopback-only HTTP/1.1 socket and retained bounded client implement one strict non-streaming JSON profile; R1k-b8 Phases A-D plus E2b add a managed child lifecycle, fenced connection/work leases, receive and full-request monotonic deadlines, drain/reset cancellation, bounded interruptible response writes, exact phase-specific evidence, same-child recovery, and zero-ownership close; Phase F1 adds `1..16` transport workers, a `1..64` FIFO of already accepted connections, passive kernel-backlog backpressure, shared deadline supervision, fenced one-owner handoff, exact snapshot conservation, joined drain, four retained deterministic same-process native-loopback scenarios, and four retained native POSIX child-process profiles covering queued receive and full-request deadlines, simultaneous drain, exact slot reuse, stale-owner rejection, fail-closed queued/running cleanup, event/cause conservation, joined threads, and final zero connection, Service, Scheduler, and Bank ownership, while model execution remains serialized; the same roots retain exact application causes with Service-validated Scheduler event identity, managed owner decoration, and no published HTTP `WorkIdentityV1` | Collect separate native-load evidence next using HTTP first-byte rather than streaming first-token latency. Define orderly-FIN abandonment policy before implementation; forced-death and durable restart campaigns, committed-token streaming, authentication, TLS, quota, GPU serving evidence, and native Windows/FreeBSD serving proof remain open |
| Language interop | Installed experimental C header plus shared/static contract libraries; source and staged-install C consumers; C++ linkage check; standard-library Python `ctypes`; dependency-free Rust `extern "C"` gate; fixed profile enumeration and support-mask queries | Retained symbol/layout gates, native multi-OS consumers, stability policy, packages, then model/session execution bindings |
| Model families | Text-generation prototype, cache-bound vision/audio/temporal-video embedding fixtures, a generic dense-tensor reranker with canonical ranked items, a generic normalized dense-tensor embedding fixture, a generic exact-integer dense-tensor classifier with stable class maps and deterministic winners, tenant-filtered exact fixed-corpus retrieval with authenticated top-k hits, stateful transcript and VFR video restart, exact word/speaker annotations, typed video segments, canonical merge timelines, exact audio/video result links, shared stateless/stateful lifecycles, exact latent continuation, atomic generated-image publication, restartable generated-audio publication, acknowledged generated-video manifests, atomic cross-modality generated-output checkpoints, exact encoded-payload archive composition, bounded multi-output image/audio/video registry continuity, canonical typed producer admission, exact deterministic producer-transition replay, one process-local typed tool transaction, a durable POSIX external-action handoff store, and a same-process generation-fenced fake dispatch/status authority for retained reference profiles | Optional retrieval-to-reranker handoff, durable or approximate indexes, production classification and other model adapters, richer language/punctuation and ambiguous-speaker policy, production generative-media adapters, multimodal fusion, OS-isolated real-credential adapters, live tools and agent loops, time-series, graph/scientific, routed and adapter families |
| State | Token transactions, canonical prepared-text state images with detached materialization, same-process retained-authority rebind, pointer-free successor evidence, receipt-funded restored activation with a global publication sequence base, recoverable generation-one source enrollment, experimental durable source exit, exclusive fresh-process activation, and generation-two-through-five acknowledged local POSIX target progress with semantic oracle comparison; plus capsule, resolver, bundle, tenant store, durable payload recovery, ownership/KV remap, fixed runtime state, model-free two-process resume, and a seven-phase atomic checkpoint root switch | Native Linux recovery, Win32 durable files, remote delivery adapters, device-resident continuation, repeated/cancelled handoff evidence, and durable lifecycle metadata |
| Scheduling | Exact admission, deterministic weighted QoS, one fixed and 32 generated bounded mixed-media open-loop pressure cases, a separately versioned finite-source deterministic closed-loop campaign with FIFO next-step replacement and exact replay, final-quantum image/audio/video media transactions, deterministic exact-signature shrinking, one mixed typed vision/audio/temporal-video workload with typed result publication under the scheduler-owned receipt, and one atomic process-local typed tool transaction profile | Family-aware batching, preemption, multi-device placement, provider/stateful/live-tool workload profiles, and broader multi-tenant campaigns |
| Device runtime | Portable capability selection, Device-loss Observation V1, command-specific Device-loss Dispatch Reconciliation Phase A, callback-safe Dispatch Callback Retirement Phase B, and loss-bound quiesced-resource retirement; canonical present-to-newer-unavailable/lost transitions; fixed 440/240/448-byte Phase A evidence and 464/240/408/504-byte Phase B retention/plan/fence/receipt evidence; native-only production authorization with same-source sticky-loss revalidation; exact active-pin binding without exposing the Bank permit; ARC-owned callback-gate detachment without a callback-exit prerequisite; dedicated zero-output `ownership_retired_after_device_loss`; Bank-first settlement, exact native unlink, replay tombstones, confirmation retry, a production 256-byte identity-bound direct retirement-telemetry snapshot, and additive pin-aware SnapshotV4 with completion headroom; real Metal commands and buffers under CPU-oracle gates; build-isolated synthetic loss/error and held-callback controls with production-symbol isolation; adapter-quoted allocation, exact charge-before-allocate accounting, ChildLease and additive LeaseTree ownership, bounded object-set pins, two isolated async slots with exact replay and out-of-order settlement, sticky quarantine, pre-submit rejection/cancellation, direct Metal length/`allocatedSize` observation, generation-fenced reuse, sibling isolation, and asymmetric FP16 tiled-matmul correctness | Retain requested/removed callback artifacts on removable hardware; add fresh selection and explicit migration policy; then dynamic multi-device queue scheduling, separate physical residency and direct physical telemetry, additional GPU backends, retained native OS/device matrices, and performance evidence under declared campaigns |
| Providers | Context packing, gateway, transport harness, settlement and cost wires, a read-only provider evidence inspector with byte-identical outer-only and optional caller-supplied full-composition modes, and a pointer-free ActionOutbox adapter contract exercised by a same-process fake authority whose portable values contain no credentials or payload bytes | Pluggable live adapters outside the credential-free core, OS-isolated credential handling, and provider export, retention, and operational policy |
| Evidence | Hash-chained events, independent Python verifiers, a scheduled-media execution sidecar with exact receipt/output replay, compact provider evidence join, an experimental read-only provider inspector with optional nested replay and exact cross-wire equality, a generated-media inspector with exact optional format-sidecar validation, independent ActionOutbox dispatch/status model tests with live canonical Zig-report parity, a fixed native-observation contract with availability, stable source identity, per-event provenance, unavailable-reason identity, per-record sample-clock identity, and value-clock identity for present time metrics, a versioned allocation-free W6a raw-record/summary/closure report codec with deterministic reference runner and independent recomputation, a W6b production-native macOS Metal producer with one retained independently verified 20-record machine result after zero-ownership closure, a W7a finite controlled-disruption producer with 250 ordered records and 100 correctness-gated native Metal commands, the W7b-b3 208-record native cancellation-storm profile with 16 correctness-gated controls, the W7b-b4 real PID-kill boundary around one controlled event-blocked registered command plus a fresh 20-command production control, the W7b-a canonical segmented-soak campaign, the W7b-b1 sealed post-segment process-kill profile, the W7b-b2 production-publisher/reference-recovery 81-fault/one-control campaign, and the W7b-b5 exact generation-six supervisor-death plus prepared-generation-twelve recovery-process-death protocol with a dual-verified 3,520-byte report | Token transaction inspector, privacy-safe export and retention policy, retained native campaign matrices, remaining W7b-b active-kernel, broader control-plane interruption, adapter, and physical disruption evidence, direct CPU/GPU utilization, residency, thermal, frequency, power, and energy adapters, and native multi-OS evidence |
| Multimodal | Shared identity/timeline, bounded decode/transforms, scheduler-coupled final-quantum image/audio/video transactions and typed perception results, per-buffer ownership, chunk chains, six-object input checkpoints, post-restore generation three, image processor progress, overlapping audio context plus fresh-process transcript continuation, exact word/speaker annotation restart, explicit VFR windows plus stateful video restart, typed segments and deterministic merge timelines, exact audio/transcript-video result links, synchronized watermark, restore-before-visible cache ownership, generated-image publication, acknowledged generated-PCM/video publication, one atomic generated image/audio/video checkpoint, one exact eight-object encoded-payload archive, a bounded multi-output registry, typed producer/raw-output admission, host replay of exact deterministic source-model/materializer transitions, validated bounded PNG/WAVE/APNG profiles, and an integrated additive format-conformance sidecar with a maximum-entry repeated-modality composed oracle | External video-timeline normalization, production encoder/container adapters and broader profiles, richer language/punctuation and overlapping-speaker policy, native Linux/Windows execution and power-loss campaigns, additional model/materializer profiles, and authorized physical playback/display and quality evidence |
| Platforms | Native macOS development-host evidence, including the 49-death ActionOutbox POSIX recovery campaign, the 27-death/54-injected-error workload-store production-publisher/reference-recovery campaign, the 49-death prepared-text source/target recovery campaign, the four-death direct-terminal prepared-text smoke, and on-demand Metal diagnostic-readiness, allocation-ownership, production workload-report, controlled-disruption, cancellation-storm, segmented-soak, post-segment process-kill, controlled in-flight process-kill, and supervisor/recovery-process death gates; hosted Ubuntu x86_64 ReleaseSafe runtime, interop, process-restart, and controlled-fault CI including the same four-boundary direct-terminal smoke, through acquired descriptor-relative directory authority that preflights before mutation and owns one sync-capable handle through commit; affected-path verification with target-specific core/CPU/durable/device/host-tool compile profiles, a complete consumer compile closure for shared APIs, full per-target fallback, and one shared DAG per selected target; full opt-in production, benchmark/diagnostic, and test-compile gates for Linux x86_64/AArch64 musl, Windows x86_64 GNU, and FreeBSD x86_64; a CLI-only default install plus opt-in benchmark installation; a bounded Linux available-memory adapter implementation with a retained machine envelope still pending; exported package modules; compile-time adapter-availability inventory; read-only POSIX/Windows model-file mapping; portable process-ID and forced-termination fixtures; compile-only core probes for Android and iOS AArch64; real `fsync` and process-death gates do not provide physical power-loss evidence | Retain reproducible Linux machine/filesystem envelopes; move acquired durable POSIX modules behind the final platform boundary and turn verification profiles into distributable products; run native Windows/FreeBSD CPU, observer, mapping, recovery, telemetry, and packaging gates; implement the Windows durable-file adapter; then add mobile and reduced edge profiles |
| Runtime Workload Lab | W0 deterministic mixed-media open-loop conformance, W1 scheduler-coupled media execution, the W2 four-seed/32-case generated corpus, W3 finite-source closed-loop conformance, W4a mixed typed-perception conformance, the W4b-a typed tool transaction, W4b-b ActionOutbox record recovery, the W4b-c durable POSIX store, W4b-d generation-fenced fake dispatch/status, W5a native observation, a bounded Linux host-source implementation, native macOS Metal readiness, pinned-allocation and bounded two-slot pressure gates, the portable W6a raw-record/summary/closure foundation, the W6b production-native 20-request Metal report producer, W7a finite controlled disruption, W7b-b3 paired-thread concurrent-caller cancellation, W7b-b4 controlled event-blocked in-flight process kill with a fresh production control, W7b-a bounded segmented soak, W7b-b1 quiescent-worker process kill, the W7b-b2 production-publisher/reference-recovery campaign-store process-death/error roll-forward, and W7b-b5 generation-six supervisor-death plus prepared-generation-twelve recovery-process-death cover overload, fairness, timeout, cancellation, turnover, typed publication/effect delivery, uncertain external handoff, fenced safe retry, deterministic crash modeling, explicit machine-state availability, fail-closed pre-run admission, retained post-run contamination, strict unavailable-not-zero behavior, independently recomputed workload evidence, correctness-gated accelerator dispatches, clean and forced worker restart, canonical checkpoint publication/offline audit, and controlled recovery without performance or physical-residency claims | Complete W7b-b active-kernel, broader supervisor/recovery interruption, adapter, and physical device/storage/driver/power campaigns; retain native Linux and broader accelerator campaign matrices; add trustworthy direct CPU/GPU metrics where platform sources exist; then W8 multi-OS replication |
| Tooling | Zig build, exported `glacier`/`glacier_core` package modules, deterministic demos, benchmark harnesses, five domain compile profiles plus one complete consumer-closure profile, CLI-only default install, and opt-in benchmark installation | Distributable product profiles, installer, stable library API, and simpler fixture workflow |

The AI-runtime and Serving rows now include three fixed native CPU load
profiles: all-completed, retained-record-capacity, and deterministic
queued-receive-timeout. References to collecting broader native-load evidence
next mean explicit open-loop and transient/general overload campaigns,
production models, repeated machines, publication-eligible native Linux, and
separately declared GPU campaigns.

The R1d Common artifact remains request-specific, while the additive R1k-b2
package manifest supplies a separate request-independent portable identity and
keeps each platform-specific prepared representation distinct. The ordinary
`.glpkg` admission bundle embeds one such representation after the manifest,
pinning one exact GLRT without changing the manifest's package root. Direct R1d
constructors still accept caller-supplied token-domain, configuration, and
license roots; the retained R1k path derives and verifies those identities
from the supplied bytes. Shared read-only residency is logical accounting
rather than physical RSS evidence.
For a completed fixed-length run, `SessionV3` seals one
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

R1i extends only the post-generation-two target path. Each fresh target
computes one token, applies it to an idempotent descriptor-relative POSIX sink,
receives a canonical acknowledgement, and publishes the immediate checkpoint
successor. Generations three through five retain that acknowledgement lineage;
generation five binds the final acknowledgement to the canonical four-token
terminal output. In a compile-once campaign, 19 distinct target processes emit
their gated ready frame and self-raise real `SIGKILL` across model-step, sink,
and checkpoint boundaries. The controller requires the exact signal exit,
permits only previous or exact-successor roots, then independently audits the
three-token acknowledged suffix against the uninterrupted oracle.

R1j closes the retained source availability window without treating a dead
process as having exited cleanly. Generation one stores a canonical,
pointer-free replay contract for the pre-tokenized request, runtime identities,
target ownership, and exact empty sink. A fresh process holding the exclusive
lease may repeat only that unpublished deterministic prefix. The successful
process creates its own real source-exit receipt, and generation two embeds the
byte-identical contract. Before target activation, the runtime reloads the
retained generation-one predecessor, verifies the contract, and admits only
the selected sink's exact empty or one-transaction-ahead replay state while
holding its lock through apply. The compile-once campaign now covers seven
generation-one bootstrap, 23 source-transition, and 19 target-transition
`SIGKILL` boundaries; its
independent decoder admits only the exact state declared at each boundary and
then requires convergence to the uninterrupted four-token oracle.

The writer-side foundation is now exposed through the public experimental Zig
module `prepared_text_durable_runtime`. `bootstrapFileV1`,
`advanceSourceFileV1`, and `advanceTargetFileV1` each perform one bounded
filesystem/runtime transition without retaining process-local model,
allocator, directory, or lease authority. Bootstrap leaves the caller-owned
Scheduler open; successful source and target receipts close their live runtime
ownership. The public
`prepared_text_committed_output_file.inspectDirectoryV1` API separately reads
and reconciles the selected checkpoint and sink without writer authority. The
existing seven bootstrap, 23 source-transition, and 19 target-transition crash
boundaries call these public APIs rather than a second benchmark-only
implementation.

The compatibility durable recovery APIs still accept pre-tokenized input and
do not cover every V1-valid request shape. The additive R1k-b2 path now carries
one strict raw-text tokenizer, the retained fixture license, a stable package
identity, and exact UTF-8 bytes through fresh-process recovery. The retained
49-boundary worker now carries a canonical admitted ordinary-profile bundle;
its independent decoder revalidates the archived conversion, tensor,
tokenizer, package, and prepared-representation identities in every case. This
is synthetic admission/recovery evidence, not a rerun of the package
producer's captured-source preflight. The standalone `text-run` command now
also admits a user-supplied model when `--package`
validates the exact package/config/tokenizer/license/prepared-image
relationship. Without durable options, counts `1..64` use the process-local
token-ID sink. With durable options, the command selects the sink-free
generation-one-to-two POSIX route for count one or the acknowledged
source/target route with capacity `N - 1` for counts `2..64`. The acknowledged
challenge binds exact `--n`.
All fixed and variable process-local reports, plus durable terminal reports,
retain `output_tokens` and their existing wire evidence unchanged.
`output_text` is an additive derived view created only after the reported
byte-token IDs have been verified as committed and decoded as strict UTF-8.
Invalid UTF-8 produces `null`, never replacement text. Durable output that was
not explicitly disclosed also produces `output_text=null`.
R1k-b3 separately adds a read-only join over an acknowledged checkpoint and
durable sink. It accepts only aligned state or a nonterminal sink exactly one
acknowledgement ahead, omits payload by default, and requires
`--reveal-output` for exact token and byte disclosure. Neither route provides
ordinary serving output, and exposed metadata is not confidential.
The durable writer now selects capacity at runtime: one concrete store accepts
acknowledgement capacities `0..63`, so the production durable runtime no longer
instantiates a store per capacity. The current source/target transition protocol
uses capacity `N - 1` for fixed output counts `2..64`; fixed output count one
uses the sink-free direct-terminal generation-one-to-two path. A bounded
four-boundary real-process-death smoke now covers post-step, post-retirement,
selector-rename, and post-generation-two recovery with an independent oracle.
The same focused `text-runtime-golden-path-test` compile root also checks the
direct count-one route plus acknowledged counts `2`, `4`, and `64`: capacities
`1`, `3`, and `63`, a count-four fresh-process continuation, independent full
checkpoint/sink lineage decoding, equality with ordinary output, and an
immutable terminal retry. The same staged `N=4` command is also supervised
through explicit paired POSIX descriptors: an all-grants control reaches the
uninterrupted oracle, while real child-only `SIGKILL` after source advance and
first target advance requires exact fresh-process convergence with no duplicate
acknowledgement or suffix. The gate executes the production CLI staged under
the selected install prefix, not the compiler-cache executable. Its children
run from an empty directory with isolated home/config/cache locations and a
minimal environment; the installed binary and its `bin/` namespace must remain
byte-identical. This is installed-shape, same-host synthetic evidence, not
native multi-OS, physical power-loss, GPU, performance, or production-model
evidence.
The public experimental package producer now covers one Safetensors/INT4/
`utf8-byte-v1`/CPU profile. The checked package CLI covers fixed durable counts
`1..64` and an additive process-local bounded early-EOS profile. Durable early
completion, unary/streaming serving, broader model/tokenizer/GPU profiles, and
exhaustive storage-fault, power-loss, and native multi-OS evidence remain open.
The combined durable work does not support early EOS or fewer-than-admitted
outputs, provide concurrent Session mutation, replay a source prefix after an
external effect, execute the handoff on GPU, or establish production native
performance. The durable adapter for this path is POSIX-only; non-POSIX native
recovery evidence and Windows durable files remain roadmap work. The local sink
prevents repeated visible application for its
exact request/sequence delivery key, but it is not a remote-provider,
distributed, hostile-writer, or physical power-loss exactly-once protocol. Its
acknowledgement codec also relies on the trusted sink-before-progress
transaction order. The detached R1e payload
cannot publish another token by itself; R1f installs it only through the
original address-stable live Session. R1g supplies exact successor evidence,
R1h-a creates a barrier-held target bootstrap, and R1h-b activates it; the
durable selector/lease/grant layer supplies the fresh-process authority
composition. The bound-plan bridge remains an experimental Zig/direct API
without a fixed bound-plan wire, projected C verifier, or `.generate_sequence`
support record; cross-language ABI parity is future work.

Detailed status, acceptance gates, and contributor-sized work items live in the
[roadmap](docs/ROADMAP.md).

## Choose a contribution

You do not need AI kernel experience to contribute. Useful work includes Zig,
Python, device backends, Linux/Windows/mobile portability, property tests, fault
injection, documentation, format tooling, visualizers, examples, and
reproducibility.

Browse the current
[good first issues](https://github.com/mienetic/glacier-engine/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22good%20first%20issue%22),
[help-wanted work](https://github.com/mienetic/glacier-engine/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22help%20wanted%22),
or [all bounded contributor slices](https://github.com/mienetic/glacier-engine/issues?q=is%3Aissue%20state%3Aopen%20label%3Acontribution).

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
- [Dense-tensor classifier](docs/DENSE_TENSOR_CLASSIFIER.md)
- [Normalized dense-tensor embedding](docs/DENSE_TENSOR_EMBEDDING.md)
- [Dense-tensor reranker](docs/DENSE_TENSOR_RERANKER.md)
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
- [Native Metal supervisor and recovery-process death report](docs/NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md)
- [Deterministic workload pressure](docs/WORKLOAD_PRESSURE.md)
- [Scheduled media pressure](docs/SCHEDULED_MEDIA_PRESSURE.md)
- [Generated workload corpus](docs/GENERATED_WORKLOAD_CORPUS.md)
- [Deterministic closed-loop workload](docs/DETERMINISTIC_CLOSED_LOOP.md)
- [Typed workload conformance](docs/TYPED_WORKLOAD_CONFORMANCE.md)
- [Typed tool workload](docs/TYPED_TOOL_WORKLOAD.md)
- [ActionOutbox protocol](docs/ACTION_OUTBOX.md)
- [Runtime Workload Lab](docs/RUNTIME_WORKLOAD_LAB.md)
- [Evidence policy](docs/EVIDENCE_POLICY.md)
- [Ordinary model package](docs/MODEL_PACKAGE.md)
- [Model format](docs/FORMAT_SPEC.md)
- [Native runtime image](docs/RUNTIME_IMAGE.md)
- [Durable runtime-image publication](docs/RUNTIME_IMAGE_DURABLE_PUBLICATION.md)
- [Verified raw-text runtime path](docs/PREPARED_TEXT_RAW_INPUT.md)
- [Prepared text session](docs/PREPARED_TEXT_SESSION.md)
- [Experimental durable CLI supervisor protocol](docs/EXPERIMENTAL_DURABLE_SUPERVISOR.md)
- [Bounded prepared-text unary service](docs/PREPARED_TEXT_UNARY_SERVICE.md)
- [Prepared text checkpoint](docs/PREPARED_TEXT_CHECKPOINT.md)
- [Prepared text successor evidence](docs/PREPARED_TEXT_SUCCESSOR.md)
- [Prepared text restore admission](docs/PREPARED_TEXT_RESTORE_ADMISSION.md)
- [Durable prepared-text handoff](docs/PREPARED_TEXT_DURABLE_HANDOFF.md)
- [Acknowledged prepared-text delivery](docs/PREPARED_TEXT_ACKNOWLEDGED_DELIVERY.md)
- [Prepared-text result inspector](docs/PREPARED_TEXT_RESULT_INSPECTOR.md)
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
